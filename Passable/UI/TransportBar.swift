import SwiftUI

struct TransportBar: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var transport: Transport

    var body: some View {
        HStack(spacing: 14) {
            Button { session.togglePlay() } label: {
                Image(systemName: transport.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 22)
            }
            .keyboardShortcut(.space, modifiers: [])
            .help("Play / Pause (Space)")

            Button { session.seekToTransition() } label: {
                Label("Cue Transition", systemImage: "arrow.uturn.backward")
            }
            .keyboardShortcut(.return, modifiers: [])
            .help("Jump to four bars before B enters (Return)")

            Text(position)
                .font(.system(.title3, design: .monospaced))
                .frame(minWidth: 230, alignment: .leading)

            Spacer()

            Image(systemName: "speaker.wave.2").foregroundStyle(.secondary)
            Slider(value: $session.masterVolume, in: 0...1)
                .frame(width: 120)

            if let p = session.exportProgress {
                ProgressView(value: p).frame(width: 120)
                Text("Rendering…").font(.caption).foregroundStyle(.secondary)
            } else {
                Menu {
                    Button("Full Mix…") { export(.full) }
                    Button("Transition Only (±8 bars)…") { export(.transition) }
                } label: {
                    Label("Render WAV", systemImage: "square.and.arrow.down")
                }
                .menuStyle(.borderedButton)
                .fixedSize()
                .disabled(session.deckA.loaded == nil)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var position: String {
        var text = Theme.time(transport.seconds)
        if let g = session.masterGrid {
            let beats = (transport.seconds - g.firstDownbeat) / g.beatSeconds
            let bar = Int((beats / 4).rounded(.down))
            let beat = Int(beats.rounded(.down)) - bar * 4
            text += String(format: "   bar %d.%d", bar + 1, beat + 1)
        }
        return text
    }

    private func export(_ range: Session.ExportRange) {
        OpenPanel.save(name: session.suggestedExportName) { session.export(range, to: $0) }
    }
}
