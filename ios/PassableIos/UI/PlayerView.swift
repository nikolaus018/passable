import SwiftUI

/// The full-screen player. Only the pieces that follow the clock (the blend
/// strip and the timeline) read `player.currentTime`; the rest is redrawn
/// when the song changes, not twenty times a second.
struct PlayerView: View {
    @Environment(Player.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var showsTracks = false
    /// How far a finger has pulled the artwork.
    @GestureState private var pull: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            ZStack {
                backdrop
                VStack(spacing: 0) {
                    header
                    ZStack {
                        if showsTracks {
                            TrackListView()
                                .transition(.opacity.combined(with: .scale(scale: 0.97)))
                        } else {
                            nowPlaying(width: geo.size.width, height: geo.size.height)
                                .transition(.opacity.combined(with: .scale(scale: 0.97)))
                        }
                    }
                    .frame(maxHeight: .infinity)

                    BlendStrip()
                        .padding(.horizontal, 24)
                        .padding(.bottom, 14)
                    PlayerTimeline()
                        .padding(.horizontal, 24)
                    TransportControls()
                        .padding(.top, 12)
                        .padding(.bottom, 20)
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDragIndicator(.hidden)
    }

    // MARK: Pieces

    private var song: PassableMix.Song? { player.currentSong }

    private var backdrop: some View {
        ZStack {
            Theme.background
            if let song {
                ArtworkView(seed: song.artworkSeed)
                    .scaleEffect(2.4)
                    .blur(radius: 60)
                    .opacity(0.55)
                    .id(song.artworkSeed)
                    .transition(.opacity)
            }
            LinearGradient(colors: [.black.opacity(0.25), Theme.background.opacity(0.92)],
                           startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.8), value: song?.artworkSeed)
    }

    private var header: some View {
        ZStack {
            VStack(spacing: 2) {
                Text(showsTracks ? "TRACK LIST" : "PLAYING FROM")
                    .font(.system(size: 11, weight: .semibold)).tracking(1.2)
                    .foregroundStyle(.secondary)
                Text(player.manifest?.title ?? "")
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 56)
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Close player")
                Spacer()
                Button {
                    Haptics.select()
                    withAnimation(.easeInOut(duration: 0.3)) { showsTracks.toggle() }
                } label: {
                    Image(systemName: showsTracks ? "photo.fill" : "list.bullet")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(showsTracks ? "Show artwork" : "Show track list")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 16).onEnded { value in
            if value.translation.height > 60 { dismiss() }
        })
    }

    private func nowPlaying(width: CGFloat, height: CGFloat) -> some View {
        let side = min(width - 56, height * 0.38)
        return VStack(spacing: 0) {
            Spacer(minLength: 8)
            ArtworkView(seed: song?.artworkSeed ?? "")
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                .shadow(color: .black.opacity(0.45), radius: 28, y: 14)
                .scaleEffect(player.isPlaying ? 1 : 0.86)
                .animation(.spring(response: 0.5, dampingFraction: 0.72), value: player.isPlaying)
                .id(song?.artworkSeed)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.5), value: song?.artworkSeed)
                .offset(x: pull.width * 0.45, y: max(0, pull.height) * 0.45)
                .animation(.spring(response: 0.35, dampingFraction: 0.75), value: pull)
            Spacer(minLength: 16)
            titleBlock
                .padding(.horizontal, 28)
            Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        // Pull down to close, flick sideways to change song.
        .gesture(
            DragGesture(minimumDistance: 16)
                .updating($pull) { value, state, _ in state = value.translation }
                .onEnded { value in
                    let t = value.translation
                    if t.height > 90, t.height > abs(t.width) { dismiss() }
                    else if t.width < -70, abs(t.width) > abs(t.height) { player.next() }
                    else if t.width > 70, abs(t.width) > abs(t.height) { player.previous() }
                }
        )
        .accessibilityAction(.escape) { dismiss() }
    }

    private var titleBlock: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(song?.title ?? "—")
                    .font(.system(size: 24, weight: .bold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .contentTransition(.opacity)
                Text(song?.artist ?? player.manifest?.title ?? "")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let song {
                VStack(alignment: .trailing, spacing: 6) {
                    if let bpm = song.bpm { chip("\(Int(bpm.rounded())) BPM") }
                    if let key = song.key { chip(key) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.3), value: song?.index)
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(.white.opacity(0.12)))
    }
}

// MARK: - Following the clock

/// One line that says what the set is doing: mixing, or what's next.
private struct BlendStrip: View {
    @Environment(Player.self) private var player

    var body: some View {
        Group {
            if let blend = player.blend, let m = player.manifest, m.songs.indices.contains(blend.transition.to),
               m.songs.indices.contains(blend.transition.from) {
                let to = m.songs[blend.transition.to]
                let from = m.songs[blend.transition.from]
                // Before the takeover the strip looks ahead; after it, back.
                let tookOver = player.songIndex == blend.transition.to
                VStack(spacing: 7) {
                    HStack(spacing: 6) {
                        Image(systemName: "waveform.path")
                        if tookOver {
                            Text("Taking over from ").foregroundStyle(.secondary) + Text(from.title).bold()
                        } else {
                            Text("Mixing into ").foregroundStyle(.secondary) + Text(to.title).bold()
                        }
                        Spacer(minLength: 4)
                        Text(blend.transition.style).foregroundStyle(.secondary)
                    }
                    .font(.system(size: 13))
                    .lineLimit(1)
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.12))
                            Capsule()
                                .fill(LinearGradient(colors: [Theme.deck(blend.transition.from), Theme.deck(blend.transition.to)],
                                                     startPoint: .leading, endPoint: .trailing))
                                .frame(width: max(4, g.size.width * blend.progress))
                        }
                    }
                    .frame(height: 4)
                }
                .accessibilityElement(children: .combine)
            } else if let next = player.nextSong {
                let until = max(0, next.start - player.currentTime)
                HStack(spacing: 6) {
                    Image(systemName: "forward.end.fill").font(.system(size: 10))
                    Text("Next ").foregroundStyle(.secondary) + Text(next.title).bold()
                    Spacer(minLength: 4)
                    Text("in \(Theme.clock(until))").foregroundStyle(.secondary).monospacedDigit()
                }
                .font(.system(size: 13))
                .lineLimit(1)
                .accessibilityElement(children: .combine)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "flag.checkered").font(.system(size: 11))
                    Text("Last song").foregroundStyle(.secondary)
                    Spacer()
                }
                .font(.system(size: 13))
            }
        }
        .frame(height: 34)
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.07)))
        .animation(.easeInOut(duration: 0.25), value: player.blend != nil)
    }
}

/// The scrubbable waveform and the clocks under it.
private struct PlayerTimeline: View {
    @Environment(Player.self) private var player
    /// Where a finger on the waveform points (nil: not touching it).
    @State private var scrubTime: Double?
    @State private var scrubSong = 0

    var body: some View {
        VStack(spacing: 6) {
            if let manifest = player.manifest {
                GeometryReader { geo in
                    let shown = scrubTime ?? player.currentTime
                    ZStack(alignment: .topLeading) {
                        WaveformView(manifest: manifest, peaks: player.item?.peaks, duration: player.duration,
                                     playhead: shown)
                        if let t = scrubTime {
                            scrubBubble(time: t, manifest: manifest, width: geo.size.width)
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let t = min(1, max(0, value.location.x / geo.size.width)) * player.duration
                                let song = manifest.songIndex(at: t)
                                if scrubTime == nil { scrubSong = song }
                                else if song != scrubSong { scrubSong = song; Haptics.select() }
                                scrubTime = t
                            }
                            .onEnded { _ in
                                if let t = scrubTime { player.seek(to: t) }
                                scrubTime = nil
                            }
                    )
                }
                .frame(height: 64)
                .accessibilityElement()
                .accessibilityLabel("Timeline")
                .accessibilityValue("\(Theme.clock(player.currentTime)) of \(Theme.clock(player.duration))")
                .accessibilityAdjustableAction { direction in
                    player.seek(to: player.currentTime + (direction == .increment ? 15 : -15))
                }
            }
            HStack {
                Text(Theme.clock(scrubTime ?? player.currentTime))
                    .frame(width: 70, alignment: .leading)
                Spacer()
                Text("Song \(player.songIndex + 1) of \(player.manifest?.songs.count ?? 0)")
                Spacer()
                Text("-" + Theme.clock(player.duration - (scrubTime ?? player.currentTime)))
                    .frame(width: 70, alignment: .trailing)
            }
            .font(.system(size: 12, weight: .medium)).monospacedDigit()
            .foregroundStyle(.secondary)
        }
    }

    private func scrubBubble(time: Double, manifest: PassableMix.Manifest, width: CGFloat) -> some View {
        let song = manifest.songs[manifest.songIndex(at: time)]
        let x = min(max(CGFloat(time / max(1, player.duration)) * width, 90), width - 90)
        return Text("\(Theme.clock(time))  ·  \(song.title)")
            .font(.system(size: 12, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(.black.opacity(0.78)))
            .overlay(Capsule().stroke(Theme.hairline))
            .frame(maxWidth: 180)
            .position(x: x, y: -14)
    }
}

private struct TransportControls: View {
    @Environment(Player.self) private var player

    var body: some View {
        HStack(spacing: 28) {
            Button { player.previous() } label: {
                Image(systemName: "backward.fill").font(.system(size: 30))
                    .frame(width: 64, height: 64)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Previous")

            Button { player.toggle() } label: {
                ZStack {
                    Circle().fill(.white)
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(.black)
                        .offset(x: player.isPlaying ? 0 : 2)
                        .contentTransition(.symbolEffect(.replace))
                }
                .frame(width: 76, height: 76)
            }
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

            Button { player.next() } label: {
                Image(systemName: "forward.fill").font(.system(size: 30))
                    .frame(width: 64, height: 64)
                    .contentShape(Rectangle())
            }
            .disabled(!player.canGoNext)
            .opacity(player.canGoNext ? 1 : 0.35)
            .accessibilityLabel("Next transition")
        }
        .buttonStyle(PressableStyle())
        .foregroundStyle(.white)
    }
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}
