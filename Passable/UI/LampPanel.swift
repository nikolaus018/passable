import AppKit
import SwiftUI

/// The settings of the beat lamp (see `BeatLamp`), remembered between launches.
@MainActor
final class LampModel: ObservableObject {
    @Published var host: String
    @Published var every: BeatLamp.Every { didSet { apply(connect: false) } }
    @Published var enabled: Bool { didSet { apply(connect: true) } }
    /// Strobe on rolls and drops (see `BeatLamp.beats`).
    @Published var moments: Bool { didSet { apply(connect: false); setBeats(from: mix) } }
    private var mix: SetMix?
    @Published private(set) var status = "Off"

    let lamp: BeatLamp
    private let persists: Bool

    init(playback: PlaybackEngine, persists: Bool) {
        let d = UserDefaults.standard
        self.persists = persists
        host = persists ? d.string(forKey: BeatLamp.hostKey) ?? "" : ""
        every = persists ? d.string(forKey: BeatLamp.everyKey).flatMap(BeatLamp.Every.init) ?? .beat : .beat
        enabled = persists && d.bool(forKey: BeatLamp.enabledKey)
        moments = !persists || d.object(forKey: BeatLamp.momentsKey) == nil || d.bool(forKey: BeatLamp.momentsKey)
        let renderer = playback.renderer
        lamp = BeatLamp(position: { Double(renderer.currentFrame) / AudioIO.sampleRate },
                        isPlaying: { [unowned playback] in playback.isRunning },
                        audioLatency: { [unowned playback] in playback.outputLatency })
        if persists {
            NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                                   queue: nil) { [lamp] _ in lamp.off(wait: true) }
        }
        apply(connect: true)
    }

    /// Writes the settings down and (re)connects.
    func apply(connect: Bool) {
        if persists {
            let d = UserDefaults.standard
            d.set(host, forKey: BeatLamp.hostKey)
            d.set(every.rawValue, forKey: BeatLamp.everyKey)
            d.set(enabled, forKey: BeatLamp.enabledKey)
            d.set(moments, forKey: BeatLamp.momentsKey)
        }
        let target = enabled && !host.trimmingCharacters(in: .whitespaces).isEmpty ? host : nil
        if target != nil && connect { status = "Connecting…" }
        lamp.configure(host: target, every: every) { [weak self] text in
            Task { @MainActor in self?.status = text }
        }
    }

    func setBeats(from mix: SetMix?) {
        self.mix = mix
        lamp.setBeats(mix.map { BeatLamp.beats(of: $0, moments: moments) } ?? [])
    }

    /// One flash, to point the lamp out or check the connection.
    func test() {
        lamp.flash()
    }
}

/// The lamp button of the transport bar and what it opens.
struct LampButton: View {
    @EnvironmentObject private var set: SetSession
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: set.lamp.enabled ? "lightbulb.fill" : "lightbulb")
                .foregroundStyle(set.lamp.enabled ? Theme.deckB : Color.secondary)
        }
        .help("Flash a Shelly (or Tasmota) plug or lamp on the beat")
        .popover(isPresented: $shown, arrowEdge: .top) { LampPanel(lamp: set.lamp) }
    }
}

private struct LampPanel: View {
    @ObservedObject var lamp: LampModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Beat lamp").font(.headline)
            Text("A Shelly (or Tasmota) plug on your network that switches on the beat of what's playing. "
                 + "Enter its IP address (in your router's device list or the Shelly app). The timing is measured for you.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("IP address, e.g. 192.168.1.42", text: $lamp.host)
                .textFieldStyle(.roundedBorder)
                .onSubmit { lamp.apply(connect: true) }
            Toggle("Flash on the beat", isOn: $lamp.enabled)
                .disabled(lamp.host.trimmingCharacters(in: .whitespaces).isEmpty)
            Picker("Flash", selection: $lamp.every) {
                ForEach(BeatLamp.Every.allCases) { Text($0.rawValue).tag($0) }
            }
            Toggle("Strobe on rolls and drops", isOn: $lamp.moments)
                .help("Flashes with every stutter of a roll, goes dark before a drop and strobes through its first bar. Fast flashing can bother people prone to photosensitive seizures: switch it off if that's you or anyone in the room.")
            HStack {
                Text(lamp.status).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Test") { lamp.test() }
                    .disabled(!lamp.enabled)
            }
            Text("Flashing wears a plug's relay: fine for a night out, not for running all day.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 320)
    }
}
