import AppKit
import SwiftUI

/// Two tabs over one set: the song list, and the transition being played
/// (or picked with Edit) for shaping by hand. One transport serves both.
struct ContentView: View {
    @EnvironmentObject private var set: SetSession
    @State private var keyMonitor: Any?

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $set.tab) {
                ForEach(SetSession.Tab.allCases) { tab in
                    if tab == .transition, let title = set.editor.transitionTitle {
                        Text("Transition \(title)").tag(tab)
                    } else {
                        Text(tab.rawValue).tag(tab)
                    }
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 320)
            .padding(.top, 8)
            switch set.tab {
            case .set:
                SetView()
            case .transition:
                TransitionEditor()
                    .environmentObject(set.editor)
                    .environmentObject(set.editor.transport)
            }
            Divider()
            SetTransportBar()
        }
        .environmentObject(set.transport)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("Passable", isPresented: Binding(get: { set.alert != nil || set.editor.alert != nil },
                                                set: { if !$0 { set.alert = nil; set.editor.alert = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(set.alert ?? set.editor.alert ?? "")
        }
        .onAppear { installKeyMonitor() }
        // A key released while another app has focus never reaches us: let
        // go of a held vocal rather than leave it muted.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            set.holdVocals(solo: false, down: false)
        }
        .onDisappear { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) } }
    }

    /// Holding M mutes the vocal of the song that's playing (let the crowd
    /// sing the chorus), holding S leaves only that vocal: for as long as
    /// the key is down. A live gesture, not an edit, so no undo step.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        let set = self.set
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            guard event.modifierFlags.isDisjoint(with: [.command, .option, .control]),
                  let key = event.charactersIgnoringModifiers?.lowercased(), key == "m" || key == "s" else { return event }
            guard let responder = event.window?.firstResponder, !(responder is NSTextView) else { return event }
            let isDown = event.type == .keyDown
            MainActor.assumeIsolated {
                set.holdVocals(solo: key == "s", down: isDown)
            }
            return nil
        }
    }
}

/// The two songs of one transition of the set, shaped by hand.
struct TransitionEditor: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var set: SetSession

    var body: some View {
        if session.hasPair {
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 12) {
                    DeckCard(side: .a)
                    TransitionPanel()
                        .frame(width: 380)
                    DeckCard(side: .b)
                }
                .padding(12)
                Divider()
                TimelineArea()
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "slider.horizontal.below.square.and.square.filled")
                    .font(.system(size: 34)).foregroundStyle(.secondary)
                Text("Transition Editor").font(.headline)
                Text(set.items.count < 2 ? "Add at least two songs. The transition being played shows up here; press Edit on any transition to shape it by hand."
                                         : (set.buildStatus ?? "Press Edit on a transition to shape it by hand."))
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct DeckCard: View {
    @EnvironmentObject private var session: Session
    let side: DeckSide

    private var deck: Deck { session.deck(side) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(side.rawValue)
                    .font(.system(size: 20, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.color(side)))
                Text(deck.title)
                    .font(.headline)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            if let a = deck.analysis {
                HStack(spacing: 14) {
                    Stat(label: "BPM", value: String(format: "%.2f", a.grid.bpm))
                    Stat(label: "Key", value: "\(a.key.camelotCode) · \(a.key.displayName)")
                    Stat(label: "Trim", value: String(format: "%+.1f dB", session.trimDB(side)))
                    Spacer(minLength: 0)
                    Menu {
                        Button("Halve BPM") { session.adjustGrid(side, .halve) }.disabled(a.grid.bpm / 2 < 60)
                        Button("Double BPM") { session.adjustGrid(side, .double) }.disabled(a.grid.bpm * 2 > 200)
                        Divider()
                        Button("Downbeat One Beat Later") { session.adjustGrid(side, .shiftBeats(1)) }
                        Button("Downbeat One Beat Earlier") { session.adjustGrid(side, .shiftBeats(-1)) }
                        Divider()
                        Button("Nudge Grid +10 ms") { session.adjustGrid(side, .nudge(10)) }
                        Button("Nudge Grid −10 ms") { session.adjustGrid(side, .nudge(-10)) }
                    } label: {
                        Label("Grid", systemImage: "metronome")
                    }
                    .fixedSize()
                    .controlSize(.small)
                    .help("Fix the beat grid if detection got this song wrong (re-plans its transitions)")
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.color(side).opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.color(side).opacity(0.25), lineWidth: 1))
    }
}

struct Stat: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased()).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            Text(value).font(.system(.callout, design: .monospaced))
        }
    }
}
