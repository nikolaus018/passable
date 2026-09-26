import SwiftUI

@main
struct PassableApp: App {
    @StateObject private var session = Session()

    var body: some Scene {
        WindowGroup("Passable") {
            ContentView()
                .environmentObject(session)
                .environmentObject(session.transport)
                .frame(minWidth: 1100, minHeight: 760)
                .onAppear(perform: loadLaunchTracks)
        }
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Track A…") { OpenPanel.choose { session.load($0, into: .a) } }
                    .keyboardShortcut("1")
                Button("Open Track B…") { OpenPanel.choose { session.load($0, into: .b) } }
                    .keyboardShortcut("2")
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { session.undo() }
                    .keyboardShortcut("z")
                    .disabled(!session.canUndo)
                Button("Redo") { session.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!session.canRedo)
            }
            CommandMenu("Transport") {
                // Space and Return live on the transport buttons instead: as
                // menu key equivalents they'd swallow typing in the search sheet.
                Button("Play / Pause") { session.togglePlay() }
                Button("Cue Transition") { session.seekToTransition() }
            }
        }
    }

    /// `-PassableTrackA <path> -PassableTrackB <path>` preloads decks, for
    /// development and scripting.
    private func loadLaunchTracks() {
        let defaults = UserDefaults.standard
        for (key, side) in [("PassableTrackA", DeckSide.a), ("PassableTrackB", .b)] {
            if let path = defaults.string(forKey: key), session.deck(side).url == nil {
                session.load(URL(fileURLWithPath: path), into: side)
            }
        }
    }
}
