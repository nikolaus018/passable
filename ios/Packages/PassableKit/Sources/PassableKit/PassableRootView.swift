import SwiftUI

/// The whole Passable player as one view, for the standalone app and the Hub.
public struct PassableRootView: View {
    @State private var store = MixStore()
    @State private var player = Player()
    @State private var receiver = Receiver()
    @Environment(\.scenePhase) private var scenePhase

    public init() {}

    public var body: some View {
        RootView()
            .environment(store)
            .environment(player)
            .environment(receiver)
            .preferredColorScheme(.dark)
            .tint(Theme.deckA)
            .onReceive(NotificationCenter.default.publisher(for: Self.openNotification)) { _ in drainOpened() }
            .task {
                receiver.onReceived = { url in
                    store.importMix(from: url, moveFile: true)
                }
                player.restoreLast(from: store)
                drainOpened()
                if scenePhase == .active { receiver.start() }
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active: receiver.start()
                case .background: receiver.stop()
                default: break
                }
            }
    }

    // MARK: Opening .passablemix files (Files, AirDrop, Mail)

    private static let openNotification = Notification.Name("PassableKit.open")
    @MainActor private static var pending: [URL] = []

    /// Hand a .passablemix the system opened to the player. Safe to call before
    /// the view exists: it's imported as soon as the player is on screen.
    @MainActor public static func open(_ url: URL) {
        pending.append(url)
        NotificationCenter.default.post(name: openNotification, object: nil)
    }

    private func drainOpened() {
        let urls = Self.pending
        Self.pending.removeAll()
        for url in urls { store.importMix(from: url) }
    }
}
