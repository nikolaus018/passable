import MultipeerConnectivity
import Observation
import UIKit

/// Waits for Passable on a Mac in the same Wi-Fi to offer a mix. Nothing
/// arrives without the phone's owner saying yes to that exact offer, and
/// everything is encrypted on the way.
@MainActor @Observable
final class Receiver {
    enum State: Equatable {
        case off
        /// Visible to Macs, waiting.
        case ready
        case receiving(title: String, progress: Double)
    }

    struct Offer: Identifiable, Equatable {
        let id = UUID()
        let macName: String
        let invitation: PassableMix.Invitation
    }

    private(set) var state: State = .off {
        // The Mac renders for minutes after the phone says yes: don't let
        // the screen lock (and the connection die) in the meantime.
        didSet {
            if case .receiving = state { UIApplication.shared.isIdleTimerDisabled = true }
            else if case .receiving = oldValue { UIApplication.shared.isIdleTimerDisabled = false }
        }
    }
    /// A Mac is asking to send this: show it, then `accept()` or `decline()`.
    private(set) var offer: Offer?
    var errorMessage: String?
    /// Why the phone can't be found by a Mac (usually: local network access is off).
    private(set) var problem: String?
    /// Runs with the received file, in a temp folder the receiver owns.
    @ObservationIgnored var onReceived: ((URL) -> Void)?

    let displayName: String
    @ObservationIgnored private let peerID: MCPeerID
    @ObservationIgnored private let session: MCSession
    @ObservationIgnored private let advertiser: MCNearbyServiceAdvertiser
    @ObservationIgnored private let proxy = Proxy()
    @ObservationIgnored private var pendingHandler: ((Bool, MCSession?) -> Void)?
    @ObservationIgnored private var progressObservation: NSKeyValueObservation?
    @ObservationIgnored private var title = "Mix"
    /// Asked to stop (the app went to the background) while a mix was on
    /// its way: it stops once that has arrived, not by dropping it.
    @ObservationIgnored private var stopWhenDone = false
    /// The Mac gives up on an unanswered invitation after this long; so does the phone.
    @ObservationIgnored private var offerExpiry: Task<Void, Never>?

    init() {
        displayName = UIDevice.current.name
        // The same identity every launch, so a Mac doesn't see a new phone
        // each time (and keep the old one listed for a while).
        let key = "peerID.\(displayName)"
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? NSKeyedUnarchiver.unarchivedObject(ofClass: MCPeerID.self, from: data) {
            peerID = saved
        } else {
            let fresh = MCPeerID(displayName: displayName)
            if let data = try? NSKeyedArchiver.archivedData(withRootObject: fresh, requiringSecureCoding: true) {
                UserDefaults.standard.set(data, forKey: key)
            }
            peerID = fresh
        }
        session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        advertiser = MCNearbyServiceAdvertiser(peer: peerID, discoveryInfo: nil, serviceType: PassableMix.serviceType)
        proxy.owner = self
        session.delegate = proxy
        advertiser.delegate = proxy
    }

    func start() {
        stopWhenDone = false
        guard state == .off else { return }
        problem = nil
        advertiser.startAdvertisingPeer()
        state = .ready
    }

    func stop() {
        if case .receiving = state {
            stopWhenDone = true
            return
        }
        advertiser.stopAdvertisingPeer()
        session.disconnect()
        declinePending()
        progressObservation = nil
        state = .off
    }

    func accept() {
        guard let handler = pendingHandler, let offer else { return }
        pendingHandler = nil
        offerExpiry?.cancel()
        title = offer.invitation.title
        self.offer = nil
        state = .receiving(title: title, progress: 0)
        handler(true, session)
    }

    func decline() {
        declinePending()
        offer = nil
    }

    private func declinePending() {
        offerExpiry?.cancel()
        pendingHandler?(false, nil)
        pendingHandler = nil
    }

    // MARK: - Events (arrive on Multipeer's queues; the proxy hops to main)

    fileprivate func invited(by peer: MCPeerID, context: Data?, handler: @escaping (Bool, MCSession?) -> Void) {
        // One offer at a time: answer a second Mac with no.
        guard offer == nil, case .ready = state else { handler(false, nil); return }
        let invitation = context.flatMap { try? JSONDecoder().decode(PassableMix.Invitation.self, from: $0) }
            ?? PassableMix.Invitation(title: "A mix", songs: 0, bytes: 0, minutes: 0)
        pendingHandler = handler
        let shown = Offer(macName: peer.displayName, invitation: invitation)
        offer = shown
        Haptics.tap()
        // The Mac can't tell the phone it stopped asking, so a question left
        // unanswered would stay on screen for an offer that no longer exists.
        offerExpiry?.cancel()
        offerExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(85))
            guard !Task.isCancelled, let self, self.offer?.id == shown.id else { return }
            self.decline()
        }
    }

    fileprivate func started(_ progress: Progress) {
        state = .receiving(title: title, progress: 0)
        progressObservation = progress.observe(\.fractionCompleted, options: [.new]) { [weak self] p, _ in
            let value = p.fractionCompleted
            Task { @MainActor in
                guard let self, case .receiving(let t, _) = self.state else { return }
                self.state = .receiving(title: t, progress: value)
            }
        }
    }

    fileprivate func finished(file: URL?, error: Error?) {
        progressObservation = nil
        state = .ready
        session.disconnect()
        if let file {
            Haptics.success()
            onReceived?(file)
        } else if let error {
            errorMessage = "The mix didn't arrive: \(error.localizedDescription)"
            Haptics.warning()
        }
        if stopWhenDone {
            stopWhenDone = false
            stop()
        }
    }

    fileprivate func advertisingFailed(_ error: Error) {
        advertiser.stopAdvertisingPeer()
        state = .off
        problem = "Passable can't see your Wi-Fi. Turn on Local Network for Passable in Settings."
    }

    fileprivate func dropped() {
        // The Mac went away before sending anything (or it said no).
        if case .receiving(_, let p) = state, p == 0 { state = .ready }
        if offer != nil, pendingHandler == nil { offer = nil }
        // (Asked to stop meanwhile: nothing is on its way any more.)
        if stopWhenDone, state == .ready {
            stopWhenDone = false
            stop()
        }
    }
}

/// Multipeer's delegates, forwarded to the receiver on the main actor.
private final class Proxy: NSObject, MCSessionDelegate, MCNearbyServiceAdvertiserDelegate {
    weak var owner: Receiver?

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        nonisolated(unsafe) let handler = invitationHandler
        Task { @MainActor in
            guard let owner = self.owner else { handler(false, nil); return }
            owner.invited(by: peerID, context: context, handler: handler)
        }
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        Task { @MainActor in self.owner?.advertisingFailed(error) }
    }

    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        if state == .notConnected { Task { @MainActor in self.owner?.dropped() } }
    }

    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID,
                 with progress: Progress) {
        Task { @MainActor in self.owner?.started(progress) }
    }

    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID,
                 at localURL: URL?, withError error: Error?) {
        // The system deletes its copy when this returns: take it now.
        var kept: URL?
        if let localURL, error == nil {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("received-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let name = (resourceName as NSString).lastPathComponent
            let target = dir.appendingPathComponent(name.isEmpty ? "mix.\(PassableMix.fileExtension)" : name)
            if (try? FileManager.default.moveItem(at: localURL, to: target)) != nil { kept = target }
        }
        let file = kept
        Task { @MainActor in self.owner?.finished(file: file, error: error ?? (file == nil ? CocoaError(.fileWriteUnknown) : nil)) }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
}
