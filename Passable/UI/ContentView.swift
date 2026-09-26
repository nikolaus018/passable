import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var session: Session
    @State private var searchTarget: DeckSide?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                DeckCard(side: .a, onSearch: { searchTarget = .a })
                TransitionPanel()
                    .frame(width: 360)
                DeckCard(side: .b, onSearch: { searchTarget = .b })
            }
            .padding(12)
            Divider()
            TimelineArea()
            Divider()
            TransportBar()
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $searchTarget) { side in
            SearchSheet(side: side)
        }
        .alert("Passable", isPresented: Binding(get: { session.alert != nil }, set: { if !$0 { session.alert = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(session.alert ?? "")
        }
    }
}

struct DeckCard: View {
    @EnvironmentObject private var session: Session
    let side: DeckSide
    let onSearch: () -> Void
    @State private var isDropTarget = false

    private var deck: Deck { session.deck(side) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(side.rawValue)
                    .font(.system(size: 20, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.color(side)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(deck.title)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    statusLine
                }
                Spacer(minLength: 0)
            }
            if let a = deck.analysis {
                HStack(spacing: 14) {
                    Stat(label: "BPM", value: String(format: "%.2f", a.grid.bpm))
                    Stat(label: "Key", value: "\(a.key.camelotCode) · \(a.key.displayName)")
                    Stat(label: "Length", value: Theme.time(a.duration))
                }
            }
            HStack {
                Button { OpenPanel.choose { session.load($0, into: side) } } label: {
                    Label("Open File…", systemImage: "folder")
                }
                Button(action: onSearch) {
                    Label("Find Online…", systemImage: "magnifyingglass")
                }
                Spacer()
                if deck.analysis != nil {
                    Menu {
                        Button("Halve BPM") { session.adjustGrid(side, .halve) }
                        Button("Double BPM") { session.adjustGrid(side, .double) }
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
                    .help("Fix the beat grid if detection got it wrong")
                }
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Theme.color(side).opacity(isDropTarget ? 0.18 : 0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Theme.color(side).opacity(isDropTarget ? 0.9 : 0.25), lineWidth: isDropTarget ? 2 : 1)
        )
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            session.load(url, into: side)
            return true
        } isTargeted: { isDropTarget = $0 }
    }

    @ViewBuilder private var statusLine: some View {
        switch deck.status {
        case .empty:
            Text("Drop a WAV here, open a file, or search online")
                .font(.caption).foregroundStyle(.secondary)
        case .decoding:
            ProgressLine(text: "Decoding…", value: nil)
        case .separating(let p):
            ProgressLine(text: "Separating stems \(Int(p * 100))%", value: p)
        case .analyzing:
            ProgressLine(text: "Finding beat grid & key…", value: nil)
        case .ready:
            Text("4 stems ready").font(.caption).foregroundStyle(.secondary)
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.red).lineLimit(2)
        }
    }
}

private struct ProgressLine: View {
    let text: String
    let value: Double?

    var body: some View {
        HStack(spacing: 6) {
            if let value {
                ProgressView(value: value).frame(width: 90)
            } else {
                ProgressView().controlSize(.mini)
            }
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
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
