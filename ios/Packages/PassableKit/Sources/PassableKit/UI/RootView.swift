import SwiftUI

struct RootView: View {
    @State private var showsPlayer = false
    @State private var showsSettings = false

    var body: some View {
        NavigationStack {
            LibraryView(openPlayer: { showsPlayer = true }, showsSettings: $showsSettings)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            MiniPlayer(open: { showsPlayer = true })
        }
        .fullScreenCover(isPresented: $showsPlayer) {
            PlayerView()
                .incomingAlerts()
        }
        .incomingAlerts(isFront: !showsPlayer && !showsSettings)
    }
}
