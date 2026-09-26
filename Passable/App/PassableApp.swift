import SwiftUI

@main
struct PassableApp: App {
    @StateObject private var set = SetSession()

    var body: some Scene {
        WindowGroup("Passable") {
            ContentView()
                .environmentObject(set)
                .frame(minWidth: 1100, minHeight: 700)
                .background(WindowFitter())
                .onAppear { set.restore() }
        }
        .defaultSize(width: 1320, height: 860)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Files…") { OpenPanel.chooseMany { set.add($0) } }
                    .keyboardShortcut("o")
            }
            // Undo covers edits in the transition editor.
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { set.editor.undo() }
                    .keyboardShortcut("z")
                Button("Redo") { set.editor.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandMenu("Transport") {
                // Space and Return live on the transport buttons instead: as
                // menu key equivalents they'd swallow typing in the search sheet.
                Button("Play / Pause") { set.togglePlay() }
                Button("Cue Transition") { set.cueFocused() }
            }
        }
    }
}
