import SwiftUI

@main
struct PassableApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @StateObject private var set = SetSession()

    var body: some Scene {
        WindowGroup("Passable") {
            ContentView()
                .environmentObject(set)
                .frame(minWidth: 1100, minHeight: 700)
                .background(WindowFitter())
                .onAppear {
                    set.restore()
                    delegate.open = { set.openSet($0) }
                }
        }
        .defaultSize(width: 1320, height: 860)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Files…") { OpenPanel.chooseMany { set.add($0) } }
                    .keyboardShortcut("o")
                Divider()
                Button("Open Set…") { OpenPanel.chooseSet { set.openSet($0) } }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(set.exportProgress != nil)
                Button("Export Set…") {
                    OpenPanel.save(name: set.suggestedSetName, types: [.passableSet]) { set.exportSet(to: $0) }
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(set.items.isEmpty || set.exportProgress != nil)
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
                Divider()
                Button("Next Transition") { set.skipForward() }
                Button("Back to Song Start") { set.skipBack() }
            }
        }
    }
}

/// Receives `.passable` files opened from Finder, holding any that arrive
/// before the window is up.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var open: ((URL) -> Void)? {
        didSet { pending.forEach { open?($0) }; pending = [] }
    }
    private var pending: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        // One set at a time: the last one wins.
        guard let url = urls.last(where: { $0.pathExtension.lowercased() == "passable" }) else { return }
        if let open { open(url) } else { pending = [url] }
    }
}
