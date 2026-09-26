import SwiftUI

/// The set planner: add songs, Passable orders them and mixes them into one
/// continuous set.
struct SetView: View {
    @EnvironmentObject private var set: SetSession
    @State private var showSearch = false
    @State private var isDropTarget = false

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(12)
            Divider()
            if set.items.isEmpty {
                empty
            } else {
                list
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .dropDestination(for: URL.self) { urls, _ in
            if let file = urls.first(where: { $0.pathExtension.lowercased() == "passable" }) {
                set.openSet(file)
            } else {
                set.add(urls)
            }
            return true
        } isTargeted: { isDropTarget = $0 }
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.deckB, lineWidth: 3).padding(4)
            }
        }
        .sheet(isPresented: $showSearch) {
            SearchSheet().environmentObject(set)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Set").font(.title2.bold())
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let status = set.buildStatus {
                ProgressView().controlSize(.small)
                Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Button { OpenPanel.chooseMany { set.add($0) } } label: {
                Label("Add Files…", systemImage: "folder")
            }
            Button { showSearch = true } label: {
                Label("Find Online…", systemImage: "magnifyingglass")
            }
            Menu {
                Button("Export Set…") {
                    OpenPanel.save(name: set.suggestedSetName, type: .passableSet) { set.exportSet(to: $0) }
                }
                .disabled(set.items.isEmpty)
                Button("Open Set…") { OpenPanel.chooseSet { set.openSet($0) } }
            } label: {
                Label("Set File", systemImage: "shippingbox")
            }
            .menuStyle(.borderedButton)
            .fixedSize()
            .disabled(set.exportProgress != nil)
            .help("Save the set with its songs as one .passable file, or open one")
            Button { set.autoOrder() } label: {
                Label("Auto-Order", systemImage: "wand.and.stars")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!set.isReady || set.items.count < 3)
            .help("Order the songs so every transition flows and the energy keeps building")
        }
    }

    private var subtitle: String {
        let n = set.items.count
        guard n > 0 else { return "Add songs; Passable orders them and mixes them into one set." }
        var text = "\(n) song\(n == 1 ? "" : "s")"
        if set.length > 0 { text += " · \(Theme.time(set.length))" }
        if n > 1 { text += " · drag songs to reorder" }
        return text
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "music.note.list").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("Drop songs here, or add them from disk or online.").foregroundStyle(.secondary)
            Text("Passable splits each into stems, finds tempo, key and structure, puts them in the order that flows best and builds every transition.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        List {
            ForEach(Array(set.items.enumerated()), id: \.element.id) { index, item in
                VStack(alignment: .leading, spacing: 6) {
                    TrackRow(index: index, item: item, isPlaying: set.transport.isPlaying && set.currentIndex == index) {
                        set.remove(item.id)
                    }
                    if index < set.items.count - 1 {
                        TransitionRow(index: index)
                    }
                }
                .padding(.vertical, 2)
            }
            .onMove { set.move(from: $0, to: $1) }
        }
        .listStyle(.inset)
    }
}

private struct TrackRow: View {
    let index: Int
    let item: SetSession.Item
    let isPlaying: Bool
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text("\(index + 1)")
                .font(.system(.callout, design: .rounded).weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(isPlaying ? Theme.deckB : Theme.deckA))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).lineLimit(1).font(.headline)
                status
            }
            Spacer()
            if let a = item.analysis {
                Stat(label: "BPM", value: String(format: "%.1f", a.grid.bpm))
                Stat(label: "Key", value: a.key.camelotCode)
                EnergyMeter(value: SetOrdering.energy(a))
            }
            Button(action: onRemove) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Remove from the set")
        }
    }

    @ViewBuilder private var status: some View {
        switch item.status {
        case .decoding: Text("Decoding…").font(.caption).foregroundStyle(.secondary)
        case .separating(let p): Text("Separating stems \(Int(p * 100))%").font(.caption).foregroundStyle(.secondary)
        case .analyzing: Text("Finding beat grid, key & structure…").font(.caption).foregroundStyle(.secondary)
        case .failed(let m): Text(m).font(.caption).foregroundStyle(.red).lineLimit(1).help(m)
        case .ready, .empty: EmptyView()
        }
    }
}

private struct EnergyMeter: View {
    let value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("ENERGY").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    Capsule().fill(Theme.deckB).frame(width: geo.size.width * max(0.05, min(1, value)))
                }
            }
            .frame(width: 60, height: 6)
            .padding(.top, 5)
        }
    }
}

private struct TransitionRow: View {
    @EnvironmentObject private var set: SetSession
    let index: Int

    private var isFocused: Bool { self.set.focused == index }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down").foregroundStyle(isFocused ? Theme.deckB : .secondary).frame(width: 26)
            if let text = set.summary(from: index) {
                if set.isEdited(from: index) {
                    Text("EDITED").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Capsule().fill(Theme.deckB))
                }
                Text(text).font(.caption).foregroundStyle(isFocused ? .primary : .secondary).lineLimit(1)
                    .help(set.reasoning(from: index) ?? text)
                Spacer()
                Button { set.cue(transitionFrom: index) } label: {
                    Label("Listen", systemImage: "play.circle")
                }
                .help("Play from four bars before this transition")
                Button { set.edit(transitionFrom: index) } label: {
                    Label("Edit", systemImage: "slider.horizontal.3")
                }
                .help("Shape this transition by hand in the Transition tab")
            } else {
                Text(" ").font(.caption)
                Spacer()
            }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.vertical, 3)
        .padding(.trailing, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.deckB.opacity(isFocused ? 0.12 : 0)))
    }
}

/// One transport for the set and the transition editor.
struct SetTransportBar: View {
    @EnvironmentObject private var set: SetSession
    @EnvironmentObject private var transport: Transport

    var body: some View {
        HStack(spacing: 12) {
            Button { set.togglePlay() } label: {
                Image(systemName: transport.isPlaying ? "pause.fill" : "play.fill").frame(width: 22)
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(set.mix == nil)
            .help("Play / Pause (Space)")

            Button { set.skipBack() } label: {
                Image(systemName: "backward.end.fill")
            }
            .keyboardShortcut(.leftArrow, modifiers: [.command])
            .disabled(set.mix == nil)
            .help("Back to the start of this song's transition; twice for the one before (⌘← or ⏮)")

            Button { set.skipForward() } label: {
                Image(systemName: "forward.end.fill")
            }
            .keyboardShortcut(.rightArrow, modifiers: [.command])
            .disabled(set.mix == nil || !set.canSkipForward)
            .help("Jump to just before the next transition (⌘→ or ⏭)")

            Button { set.cueFocused() } label: {
                Label("Cue", systemImage: "arrow.uturn.backward")
            }
            .keyboardShortcut(.return, modifiers: [])
            .disabled(set.focused == nil)
            .help("Play from four bars before the transition in the editor (Return)")

            Text("\(Theme.time(transport.seconds)) / \(Theme.time(set.length))")
                .font(.system(.body, design: .monospaced))
                .fixedSize()

            Slider(value: Binding(get: { transport.seconds }, set: { set.seek(to: $0) }),
                   in: 0...max(1, set.length))
                .disabled(set.mix == nil)

            if let i = set.currentIndex, set.items.indices.contains(i) {
                Text(set.items[i].title)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .frame(maxWidth: 220, alignment: .leading)
            }

            Image(systemName: "speaker.wave.2").foregroundStyle(.secondary)
            Slider(value: $set.masterVolume, in: 0...1).frame(width: 90)

            if let p = set.exportProgress {
                ProgressView(value: p).frame(width: 110)
                Text(set.exportLabel).font(.caption).foregroundStyle(.secondary)
            } else {
                Menu {
                    Button("Whole Set…") {
                        OpenPanel.save(name: "Passable Set.wav") { set.export(.set, to: $0) }
                    }
                    Button("This Transition (±8 bars)…") {
                        OpenPanel.save(name: set.suggestedTransitionName) { set.export(.focusedTransition, to: $0) }
                    }
                    .disabled(set.focused == nil)
                } label: {
                    Label("Render", systemImage: "square.and.arrow.down")
                }
                .menuStyle(.borderedButton)
                .fixedSize()
                .disabled(set.mix == nil)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
