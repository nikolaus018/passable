import SwiftUI

/// The bar above the library while a mix is loaded: tap to open the player.
struct MiniPlayer: View {
    @Environment(Player.self) private var player
    var open: () -> Void

    var body: some View {
        if let song = player.currentSong {
            HStack(spacing: 12) {
                ArtworkView(seed: song.artworkSeed)
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text(song.artist ?? player.manifest?.title ?? "")
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 22))
                        .frame(width: 44, height: 44)
                        .contentTransition(.symbolEffect(.replace))
                }
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                Button { player.next() } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 19))
                        .frame(width: 40, height: 44)
                }
                .disabled(!player.canGoNext)
                .opacity(player.canGoNext ? 1 : 0.35)
                .accessibilityLabel("Next song")
            }
            .buttonStyle(PressableStyle())
            .foregroundStyle(.white)
            .padding(.leading, 10).padding(.trailing, 6).padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.ultraThinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Theme.hairline))
            )
            .overlay(alignment: .bottom) {
                GeometryReader { g in
                    Capsule().fill(Theme.deck(song.index))
                        .frame(width: g.size.width * (player.duration > 0 ? player.currentTime / player.duration : 0), height: 2)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
                .padding(.horizontal, 22).padding(.bottom, 1)
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
            .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
            .accessibilityElement(children: .contain)
        }
    }
}
