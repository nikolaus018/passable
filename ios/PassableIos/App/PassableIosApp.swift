import SwiftUI

@main
struct PassableIosApp: App {
    @State private var store = MixStore()
    @State private var player = Player()
    @State private var receiver = Receiver()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(player)
                .environment(receiver)
                .preferredColorScheme(.dark)
                .tint(Theme.deckA)
                // A .passablemix opened from Files, AirDrop or Mail.
                .onOpenURL { url in store.importMix(from: url) }
                .task {
                    receiver.onReceived = { url in
                        store.importMix(from: url, moveFile: true)
                    }
                    player.restoreLast(from: store)
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
    }
}
