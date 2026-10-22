import SwiftUI

/// Every song of the mix in order, with the blend between each pair. Tap a
/// song to jump to it.
struct TrackListView: View {
    @Environment(Player.self) private var player

    var body: some View {
        if let manifest = player.manifest {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(manifest.songs) { song in
                            row(song, in: manifest)
                                .id(song.index)
                            if let t = manifest.transitions.first(where: { $0.from == song.index }) {
                                connector(t)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                .scrollIndicators(.hidden)
                .onAppear { proxy.scrollTo(player.songIndex, anchor: .center) }
                .onChange(of: player.songIndex) { _, index in
                    withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(index, anchor: .center) }
                }
            }
            .mask(
                LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.04),
                                       .init(color: .black, location: 0.94), .init(color: .clear, location: 1)],
                               startPoint: .top, endPoint: .bottom)
            )
        }
    }

    private func row(_ song: PassableMix.Song, in manifest: PassableMix.Manifest) -> some View {
        let isCurrent = song.index == player.songIndex
        return Button { player.jump(toSong: song.index) } label: {
            HStack(spacing: 12) {
                ZStack {
                    ArtworkView(seed: song.artworkSeed)
                        .frame(width: 46, height: 46)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    if isCurrent {
                        RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.black.opacity(0.45))
                            .frame(width: 46, height: 46)
                        PlayingBars(isPlaying: player.isPlaying)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title)
                        .font(.system(size: 16, weight: isCurrent ? .bold : .semibold))
                        .foregroundStyle(isCurrent ? Theme.deck(song.index) : .white)
                        .lineLimit(1)
                    if let artist = song.artist {
                        Text(artist).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Text(Theme.clock(song.handover))
                    .font(.system(size: 13, weight: .medium)).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isCurrent ? Color.white.opacity(0.09) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(song.title)\(song.artist.map { ", \($0)" } ?? ""), starts at \(Theme.clock(song.handover))")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    /// The blend between two songs: a line from one deck colour to the next.
    private func connector(_ t: PassableMix.Transition) -> some View {
        HStack(spacing: 12) {
            Capsule()
                .fill(LinearGradient(colors: [Theme.deck(t.from), Theme.deck(t.to)], startPoint: .top, endPoint: .bottom))
                .frame(width: 3, height: 26)
                .frame(width: 46)
            Text("\(t.style) · \(Theme.clock(max(0, t.end - t.begins)))")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 10)
        .accessibilityLabel("\(t.style) blend, \(Int(max(0, t.end - t.begins))) seconds")
    }
}
