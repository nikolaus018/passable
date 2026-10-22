import Foundation
import MultipeerConnectivity

/// Finds iPhones running Passable on the same Wi-Fi and sends them a mix.
/// The phone's owner has to accept each one, and it travels encrypted.
@MainActor
final class PhoneLink: NSObject, ObservableObject {
    struct Phone: Identifiable, Hashable {
        let peer: MCPeerID
        var id: MCPeerID { peer }
        var name: String { peer.displayName }
    }

    enum LinkError: LocalizedError {
        case declined, busy
        var errorDescription: String? {
            switch self {
            case .declined: return "The iPhone didn't accept. Keep Passable open on it, and tap Accept when it asks."
            case .busy: return "Already sending to an iPhone."
            }
        }
    }

    @Published private(set) var phones: [Phone] = []
    @Published private(set) var isLooking = false
    /// Set when the Mac won't let Passable see the network.
    @Published private(set) var problem: String?

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
    private var sending = false
    /// The panel closed mid-send: stop looking once the send is over.
    private var stopWhenDone = false

    // MARK: - Looking for phones

    func startLooking() {
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

    /// Asks `phone` and returns once its owner has accepted. The connection
    /// is held (and the phone list kept alive) until `transfer` or `cancel`,
    /// so a set can be rendered after the phone said yes, not before.
    func connect(to phone: Phone, invitation: PassableMix.Invitation) async throws {
        guard !sending else { throw LinkError.busy }
        sending = true
        do {
            let context = try JSONEncoder().encode(invitation)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                waitingForConnection = continuation
                browser.invitePeer(phone.peer, to: session, withContext: context, timeout: 90)
            }
        } catch {
            cancel()
            throw error
        }
    }

    /// Sends `file` over the connection `connect` made. `progress` runs with 0...1.
    func transfer(_ file: URL, to phone: Phone, progress: @escaping @MainActor (Double) -> Void) async throws {
        defer { cancel() }
        let name = file.lastPathComponent
        var observation: NSKeyValueObservation?
        defer { observation?.invalidate() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let transfer = session.sendResource(at: file, withName: name, toPeer: phone.peer) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
            observation = transfer?.observe(\.fractionCompleted, options: [.new]) { p, _ in
                let value = p.fractionCompleted
                Task { @MainActor in progress(value) }
            }
        }
        progress(1)
    }

    /// Lets go of the connection (nothing more will be sent).
    func cancel() {
        guard sending else { return }
        sending = false
        waitingForConnection = nil
        session.disconnect()
        if stopWhenDone { stopWhenDone = false; stopLooking() }
    }

    /// Asks `phone` and, once it accepts, sends `file`.
    func send(_ file: URL, to phone: Phone, invitation: PassableMix.Invitation,
              progress: @escaping @MainActor (Double) -> Void) async throws {
        try await connect(to: phone, invitation: invitation)
        try await transfer(file, to: phone, progress: progress)
    }

    fileprivate func connectionChanged(_ peer: MCPeerID, _ state: MCSessionState) {
        guard let continuation = waitingForConnection else { return }
        switch state {
        case .connected:
            waitingForConnection = nil
            continuation.resume()
        case .notConnected:
            waitingForConnection = nil
            continuation.resume(throwing: LinkError.declined)
        case .connecting:
            break
        @unknown default:
            break
        }
    }

    fileprivate func found(_ peer: MCPeerID) {
        guard peer != peerID, !phones.contains(where: { $0.peer == peer }) else { return }
        phones.append(Phone(peer: peer))
    }

    fileprivate func lost(_ peer: MCPeerID) {
        phones.removeAll { $0.peer == peer }
    }

    fileprivate func browsingFailed() {
        isLooking = false
        problem = "Passable can't look for iPhones. Allow Local Network for Passable in System Settings › Privacy & Security."
    }
}

extension PhoneLink: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor in self.found(peerID) }
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
