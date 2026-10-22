import SwiftUI
import UniformTypeIdentifiers

/// The home screen: the mixes on this phone, and whether the phone is
/// ready to take a new one from the Mac.
struct LibraryView: View {
    @Environment(MixStore.self) private var store
    @Environment(Player.self) private var player
    @Environment(Receiver.self) private var receiver
    var openPlayer: () -> Void
    @Binding var showsSettings: Bool

    @State private var showsImporter = false
    @State private var pendingDelete: MixStore.Item?

    var body: some View {
        List {
            ReceiverCard()
                .libraryRow(top: 4, bottom: 10)

            ForEach(store.incoming) { job in
                IncomingRow(job: job)
                    .libraryRow()
            }

            if store.items.isEmpty && store.incoming.isEmpty {
                EmptyLibrary()
                    .libraryRow(top: 24, bottom: 0)
            } else {
                ForEach(store.items) { item in
                    MixCard(item: item, isCurrent: player.item?.id == item.id)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            player.load(item, autoplay: player.item?.id != item.id)
                            openPlayer()
                        }
                        .contextMenu {
                            Button(role: .destructive) { pendingDelete = item } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) { pendingDelete = item } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .libraryRow()
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isButton)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Passable")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { showsImporter = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Open a mix file")
                Button { showsSettings = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("Settings")
            }
        }
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: [mixType], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { for url in urls { store.importMix(from: url) } }
        }
        .sheet(isPresented: $showsSettings) { SettingsView() }
        .confirmationDialog("Delete this mix from your iPhone?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible,
                            presenting: pendingDelete) { item in
            Button("Delete “\(item.manifest.title)”", role: .destructive) {
                player.unload(item.id)
                store.delete(item)
            }
        } message: { _ in
            Text("It stays on your Mac, and you can send it again any time.")
        }
    }

    private var mixType: UTType { UTType(PassableMix.typeIdentifier) ?? .data }
}

private extension View {
    /// A list row that is just its own card on the screen's background.
    func libraryRow(top: CGFloat = 5, bottom: CGFloat = 5) -> some View {
        self
            .listRowInsets(EdgeInsets(top: top, leading: 16, bottom: bottom, trailing: 16))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}

// MARK: - Pieces

private struct MixCard: View {
    let item: MixStore.Item
    let isCurrent: Bool
    @Environment(Player.self) private var player

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                ArtworkView(seed: item.manifest.id.uuidString + item.manifest.title)
                    .frame(width: 78, height: 78)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                if isCurrent {
                    RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.black.opacity(0.4))
                        .frame(width: 78, height: 78)
                    PlayingBars(isPlaying: player.isPlaying)
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(item.manifest.title)
                    .font(.system(size: 18, weight: .bold))
                    .lineLimit(1)
                Text("\(item.songCount) songs · \(Theme.length(item.manifest.duration))")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                WaveformView(manifest: item.manifest, peaks: item.peaks, duration: item.manifest.duration,
                             playhead: nil, barWidth: 2, gap: 1.5, showsMarkers: false)
                    .frame(height: 22)
                    .padding(.top, 2)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.card)
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(isCurrent ? Theme.deckA.opacity(0.5) : Theme.hairline))
        )
    }
}

private struct IncomingRow: View {
    let job: MixStore.Incoming

    var body: some View {
        HStack(spacing: 14) {
            ProgressView().frame(width: 78, height: 78)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.card))
            VStack(alignment: .leading, spacing: 8) {
                Text(job.name).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                ProgressView(value: job.progress).tint(Theme.deckA)
                Text("Adding to your library…").font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.card))
    }
}

private struct EmptyLibrary: View {
    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle().fill(Theme.deckA.opacity(0.18)).frame(width: 92, height: 92).offset(x: -16)
                Circle().fill(Theme.deckB.opacity(0.18)).frame(width: 92, height: 92).offset(x: 16)
                Image(systemName: "waveform").font(.system(size: 36, weight: .semibold))
            }
            .frame(height: 100)
            VStack(spacing: 6) {
                Text("No mixes yet").font(.system(size: 22, weight: .bold))
                Text("Send a set from Passable on your Mac and it plays here, with every transition in place.")
                    .font(.system(size: 15)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            VStack(alignment: .leading, spacing: 14) {
                step(1, "Open Passable on your Mac and build your set.")
                step(2, "Click the iPhone button at the bottom of the window and pick this phone.")
                step(3, "Keep this screen open and tap Accept.")
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.card))
        }
        .frame(maxWidth: .infinity)
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)").font(.system(size: 13, weight: .bold, design: .rounded))
                .frame(width: 24, height: 24)
                .background(Circle().fill(.white.opacity(0.12)))
            Text(text).font(.system(size: 15))
        }
    }
}

/// Whether Macs can find this phone, and how a transfer is going.
struct ReceiverCard: View {
    @Environment(Receiver.self) private var receiver

    var body: some View {
        HStack(spacing: 12) {
            indicator
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(2)
                if case .receiving(_, let progress) = receiver.state {
                    ProgressView(value: progress).tint(Theme.deckB).padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
            if receiver.problem != nil {
                Button("Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .font(.system(size: 14, weight: .semibold))
                .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.card)
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.hairline)))
        .animation(.easeInOut(duration: 0.25), value: receiver.state)
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        if receiver.problem != nil { return "Can't reach your Mac" }
        switch receiver.state {
        case .off: return "Not listening"
        case .ready: return "Ready for your Mac"
        case .receiving(let title, _): return "Receiving “\(title)”"
        }
    }

    private var subtitle: String {
        if let problem = receiver.problem { return problem }
        switch receiver.state {
        case .off: return "Open Passable to listen for sets from your Mac."
        case .ready: return "On your Mac, click the iPhone button and pick “\(receiver.displayName)”."
        case .receiving(_, let p):
            return p < 0.005 ? "Your Mac is rendering the set. Keep this screen open."
                             : "\(Int(p * 100))% · keep this screen open"
        }
    }

    @ViewBuilder private var indicator: some View {
        if receiver.problem != nil {
            Image(systemName: "wifi.exclamationmark").font(.system(size: 20)).foregroundStyle(.orange).frame(width: 28)
        } else if case .receiving = receiver.state {
            Image(systemName: "arrow.down.circle.fill").font(.system(size: 22)).foregroundStyle(Theme.deckB).frame(width: 28)
        } else {
            let on = receiver.state == .ready
            TimelineView(.animation(minimumInterval: 1 / 20, paused: !on)) { tl in
                let pulse = on ? 0.5 + 0.5 * sin(tl.date.timeIntervalSinceReferenceDate * 2.4) : 0
                ZStack {
                    Circle().fill((on ? Color.green : .gray).opacity(0.25 * (1 - pulse))).frame(width: 14 + 14 * pulse)
                    Circle().fill(on ? Color.green : .gray).frame(width: 10, height: 10)
                }
                .frame(width: 28, height: 28)
            }
        }
    }
}
