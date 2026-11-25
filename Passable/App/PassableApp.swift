import SwiftUI

@main
struct PassableApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    // Launched to host the unit tests, the app leaves the user's set alone:
    // restoring it loaded (and could separate and reorder) every song of it
    // while the tests ran.
    @StateObject private var set = SetSession(persists: !PassableApp.hostingTests)

    static let hostingTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

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
            // Undo covers edits in the transition editor, except while
            // typing: then it's the text field's own.
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { if !TextUndo.send("undo:") { set.editor.undo() } }
                    .keyboardShortcut("z")
                Button("Redo") { if !TextUndo.send("redo:") { set.editor.redo() } }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandMenu("Transport") {
                // Space lives on the transport button instead: as a menu key
                // equivalent it would swallow typing in the search sheet.
                Button("Play / Pause") { set.togglePlay() }
                Divider()
                Button("Next Transition") { set.skipForward() }
                Button("Back to Song Start") { set.skipBack() }
            }
        }
    }
}

/// Routes Undo and Redo to the text field being typed in, if any.
enum TextUndo {
    @MainActor
    static func send(_ action: String) -> Bool {
        guard NSApp.keyWindow?.firstResponder is NSTextView else { return false }
        return NSApp.sendAction(Selector(action), to: nil, from: nil)
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
