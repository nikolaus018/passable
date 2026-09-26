import SwiftUI

struct TransitionPanel: View {
    @EnvironmentObject private var session: Session

    private var ready: Bool { session.deckA.analysis != nil && session.deckB.analysis != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Transition").font(.headline)
                Spacer()
                if let status = session.matchStatus {
                    ProgressView().controlSize(.mini)
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }
            if ready {
                matching
                Divider()
                alignment
                Divider()
                presetControls
            } else {
                Text("Load both tracks. Passable separates each into vocals, melody, drums and bass, finds the beat grid and key, then matches B to A's tempo and key.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
    }

    private var matching: some View {
        let a = session.deckA.analysis!, b = session.deckB.analysis!
        let percent = (session.rate - 1) * 100
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "metronome").frame(width: 16)
                Text(String(format: "B %.2f → %.2f BPM", b.grid.bpm * session.tempoMultiplier, a.grid.bpm))
                Text(String(format: "(%+.1f%%)", percent))
                    .foregroundStyle(abs(percent) > 8 ? .orange : .secondary)
                if session.tempoMultiplier != 1 {
                    Text(session.tempoMultiplier > 1 ? "double-time" : "half-time")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Image(systemName: "tuningfork").frame(width: 16)
                Text("\(b.key.camelotCode) → \(session.keyAfterShift?.camelotCode ?? "–")")
                Text("vs A \(a.key.camelotCode)").foregroundStyle(.secondary)
                Spacer()
                Stepper(value: Binding(get: { session.semitones }, set: { session.setSemitones($0) }), in: -6...6) {
                    Text("\(session.semitones > 0 ? "+" : "")\(session.semitones) st")
                        .font(.system(.body, design: .monospaced))
                }
                Toggle("Auto", isOn: Binding(get: { session.autoKey }, set: { session.setSemitones(session.semitones, auto: $0) }))
                    .toggleStyle(.checkbox)
            }
            if let clash = session.keyClash {
                Text(clash).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.callout)
    }

    private var alignment: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("B's bar").frame(width: 70, alignment: .leading)
                Stepper("\(session.cueBar + 1)", value: $session.cueBar, in: 0...max(0, session.barCountB - 1))
                    .font(.system(.body, design: .monospaced))
                Text("lands on A's bar").foregroundStyle(.secondary)
                Stepper("\(session.entryBar + 1)", value: $session.entryBar, in: 0...max(0, session.barCountA - 1), step: 1)
                    .font(.system(.body, design: .monospaced))
            }
            HStack(spacing: 6) {
                Text("Nudge entry").foregroundStyle(.secondary)
                ForEach([-8, -4, 4, 8], id: \.self) { d in
                    Button(d > 0 ? "+\(d)" : "\(d)") {
                        session.entryBar = max(0, min(session.barCountA - 1, session.entryBar + d))
                    }
                }
                Text("bars").foregroundStyle(.secondary)
            }
            .controlSize(.small)
        }
        .font(.callout)
    }

    private var presetControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("", selection: $session.preset) {
                    ForEach(TransitionPreset.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .frame(width: 130)
                .onChange(of: session.preset) { _, p in session.transitionBars = p.defaultBars }
                Picker("", selection: $session.transitionBars) {
                    ForEach([1, 2, 4, 8, 16, 32, 64], id: \.self) { Text("\($0) bars").tag($0) }
                }
                .labelsHidden()
                .frame(width: 90)
                Spacer()
            }
            HStack {
                Button {
                    session.autoArrange()
                } label: {
                    Label("Auto", systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderedProminent)
                .help("Pick entry and cue bars from the stems, then apply the preset")
                Button("Apply") { session.applyPreset() }
                    .help("Apply the preset at the current entry bar")
                Button("Clear") { session.clearAutomation() }
            }
            if let note = session.placementNote {
                Label(note, systemImage: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(session.preset.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
