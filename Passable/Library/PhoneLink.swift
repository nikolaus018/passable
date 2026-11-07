import Foundation
import MultipeerConnectivity

/// Finds iPhones running Passable on the same Wi-Fi and sends them a mix.
/// The phone's owner has to accept each one, and it travels encrypted.
@MainActor
final class PhoneLink: NSObject, ObservableObject {
    struct Phone: Identifiable, Hashable {
        let peer: MCPeerID
        /// The phone's own install id (from its discovery info): the same
        /// phone under a new peer identity, never another phone of the same name.
        let installID: String?
        var id: MCPeerID { peer }
        var name: String { peer.displayName }
    }

    enum LinkError: LocalizedError {
        case declined, noAnswer, couldNotConnect, lost, busy
        var errorDescription: String? {
            switch self {
            case .declined: return "The iPhone declined the set."
            case .noAnswer: return "The iPhone didn't answer. Keep Passable open on it, and tap Accept when it asks."
            case .couldNotConnect: return "Couldn't connect to the iPhone. If you tapped Accept, send it again."
            case .lost: return "The iPhone went away before the set arrived. Keep Passable open on it while the Mac renders, then send it again."
            case .busy: return "Already sending to an iPhone."
            }
        }
    }

    /// How long a phone has to answer. The phone gives up a little earlier
    /// (the iPhone app's `Receiver` drops the question after 85 s).
    static let inviteTimeout: TimeInterval = 90

    @Published private(set) var phones: [Phone] = []
    @Published private(set) var isLooking = false
    /// Set when the Mac won't let Passable see the network.
    @Published private(set) var problem: String?
    /// Runs on the main actor when the connected phone drops mid-send
    /// (before or during the transfer), so whoever is rendering can stop.
    var onLost: (() -> Void)?

    private let peerID = MCPeerID(displayName: Host.current().localizedName ?? "Mac")
    private lazy var session: MCSession = {
        let s = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        s.delegate = self
        return s
    }()
    private lazy var browser: MCNearbyServiceBrowser = {
        let b = MCNearbyServiceBrowser(peer: peerID, serviceType: PassableMix.serviceType)
        b.delegate = self
        return b
    }()
    private var waitingForConnection: CheckedContinuation<Void, Error>?
    private var invitedAt = Date.distantPast
    private var sawConnecting = false
    /// The phone this send is connected to, once it accepted.
    private var connectedPeer: MCPeerID?
    /// The connected phone dropped before `cancel`.
    private(set) var connectionLost = false
    private var sending = false
    /// The panel closed mid-send: stop looking once the send is over.
    private var stopWhenDone = false

    // MARK: - Looking for phones

    func startLooking() {
        // (Reopened mid-send: keep the list once that send is over.)
        stopWhenDone = false
        guard !isLooking else { return }
        problem = nil
        isLooking = true
        browser.startBrowsingForPeers()
    }

    func stopLooking() {
        guard isLooking else { return }
        if sending { stopWhenDone = true; return }
        browser.stopBrowsingForPeers()
        isLooking = false
        phones = []
    }

    // MARK: - Sending

    /// Claims the link for one send, synchronously, so closing the panel
    /// right after Send doesn't stop looking before the phone is asked.
    /// Every successful `hold` ends with `cancel` (which `transfer` does too).
    func hold() throws {
        guard !sending else { throw LinkError.busy }
        sending = true
        connectionLost = false
        connectedPeer = nil
    }

    /// Asks `phone` and returns once its owner has accepted. The connection
    /// is held (and the phone list kept alive) until `transfer` or `cancel`,
    /// so a set can be rendered after the phone said yes, not before.
    /// Call `hold` first.
    func connect(to phone: Phone, invitation: PassableMix.Invitation) async throws {
        precondition(sending, "PhoneLink.connect without hold()")
        do {
            try Task.checkCancellation()
            let context = try JSONEncoder().encode(invitation)
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    waitingForConnection = continuation
                    invitedAt = Date()
                    sawConnecting = false
                    browser.invitePeer(phone.peer, to: session, withContext: context, timeout: Self.inviteTimeout)
                }
            } onCancel: {
                Task { @MainActor in self.stopWaiting(throwing: CancellationError()) }
            }
            connectedPeer = phone.peer
        } catch {
            cancel()
            throw error
        }
    }

    /// Sends `file` over the connection `connect` made. `progress` runs with 0...1.
    func transfer(_ file: URL, to phone: Phone, progress: @escaping @MainActor (Double) -> Void) async throws {
        defer { cancel() }
        if connectionLost { throw LinkError.lost }
        try Task.checkCancellation()
        let name = file.lastPathComponent
        var observation: NSKeyValueObservation?
        defer { observation?.invalidate() }
        // Progress hops to the main actor on its own; none may land after the end.
        let over = Box(false)
        let sent = Box<Progress?>(nil)
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let transfer = session.sendResource(at: file, withName: name, toPeer: phone.peer) { error in
                        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                    }
                    sent.value = transfer
                    observation = transfer?.observe(\.fractionCompleted, options: [.new]) { p, _ in
                        let value = p.fractionCompleted
                        Task { @MainActor in if !over.value { progress(value) } }
                    }
                }
            } onCancel: {
                // Cancelling the Progress cancels the transfer; its handler then runs.
                Task { @MainActor in sent.value?.cancel() }
            }
        } catch {
            over.value = true
            if Task.isCancelled { throw CancellationError() }
            throw connectionLost ? LinkError.lost : error
        }
        over.value = true
        progress(1)
    }

    /// Lets go of the connection (nothing more will be sent).
    func cancel() {
        guard sending else { return }
        sending = false
        stopWaiting(throwing: CancellationError())
        connectedPeer = nil
        session.disconnect()
        if stopWhenDone { stopWhenDone = false; stopLooking() }
    }

    /// Asks `phone` and, once it accepts, sends `file`.
    func send(_ file: URL, to phone: Phone, invitation: PassableMix.Invitation,
              progress: @escaping @MainActor (Double) -> Void) async throws {
        try hold()
        try await connect(to: phone, invitation: invitation)
        try await transfer(file, to: phone, progress: progress)
    }

    private func stopWaiting(throwing error: Error) {
        guard let continuation = waitingForConnection else { return }
        waitingForConnection = nil
        continuation.resume(throwing: error)
    }

    fileprivate func connectionChanged(_ peer: MCPeerID, _ state: MCSessionState) {
        if let continuation = waitingForConnection {
            switch state {
            case .connected:
                waitingForConnection = nil
                continuation.resume()
            case .notConnected:
                // Multipeer says only "not connected": tell apart what we can.
                let waited = Date().timeIntervalSince(invitedAt)
                if waited >= Self.inviteTimeout - 10 { stopWaiting(throwing: LinkError.noAnswer) }
                else if sawConnecting { stopWaiting(throwing: LinkError.couldNotConnect) }
                else { stopWaiting(throwing: LinkError.declined) }
            case .connecting:
                sawConnecting = true
            @unknown default:
                break
            }
            return
        }
        // Accepted earlier, and gone now: the set is rendering (or on its way)
        // for a phone that can't take it.
        if state == .notConnected, sending, peer == connectedPeer, !connectionLost {
            connectionLost = true
            onLost?()
        }
    }

    fileprivate func found(_ peer: MCPeerID, info: [String: String]?) {
        guard peer != peerID, !phones.contains(where: { $0.peer == peer }) else { return }
        let installID = info?["id"]
        // A phone that relaunched Passable can show up under a new identity
        // while its old one lingers until Multipeer times it out. Its install
        // id says it's the same phone; two phones may well share a name.
        if let installID { phones.removeAll { $0.installID == installID } }
        phones.append(Phone(peer: peer, installID: installID))
    }

    fileprivate func lost(_ peer: MCPeerID) {
        phones.removeAll { $0.peer == peer }
    }

    fileprivate func browsingFailed() {
        isLooking = false
        problem = "Passable can't look for iPhones. Allow Local Network for Passable in System Settings › Privacy & Security."
    }
}

/// A value shared between a transfer and its hops to the main actor
/// (read and written there only).
private final class Box<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}

extension PhoneLink: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor in self.found(peerID, info: info) }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in self.lost(peerID) }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        Task { @MainActor in self.browsingFailed() }
    }
}

extension PhoneLink: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in self.connectionChanged(peerID, state) }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}
