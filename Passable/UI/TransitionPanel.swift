import SwiftUI

/// Tempo, key, placement and preset of the transition in the editor.
struct TransitionPanel: View {
    @EnvironmentObject private var session: Session

    private var ready: Bool { session.deckA.analysis != nil && session.deckB.analysis != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if ready {
                matching
                Divider()
                alignment
                Divider()
                presetControls
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(session.transitionTitle.map { "Transition \($0)" } ?? "Transition").font(.headline)
            Spacer()
            if let status = session.matchStatus {
                ProgressView().controlSize(.mini)
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            if session.host != nil {
                Toggle("Automatic", isOn: Binding(get: { !session.isEdited }, set: { automatic in
                    if automatic { session.autoArrange() } else { session.keepAsEdited() }
                }))
                .toggleStyle(.checkbox)
                .help(session.isEdited
                      ? "Shaped by hand. Tick to go back to the automatic transition (drops your changes)."
                      : "Planned automatically from the two songs. Any change you make here turns this off.")
            }
        }
    }

    private var matching: some View {
        let a = session.deckA.analysis!, b = session.deckB.analysis!
        let percent = (session.matchRate - 1) * 100
        let own = b.grid.bpm * session.tempoMultiplier
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "metronome").frame(width: 16)
                if session.preset == .echoOut {
                    Text(String(format: "B stays at %.2f BPM", own))
                    Text("no shared beat").foregroundStyle(.secondary)
                } else {
                    Text(String(format: "B %.2f → %.2f BPM", own, a.grid.bpm))
                    Text(String(format: "%+.1f%%", percent))
                        .foregroundStyle(abs(percent) > 8 ? .orange : .secondary)
                }
                Spacer()
            }
            .help(session.preset == .echoOut
                  ? "Wash Out never layers the two beats, so B keeps its own tempo."
                  : "B matches A's tempo only while they overlap, then glides back to its own over \(session.glideBars) bars and plays untouched."
                    + (abs(percent) > 8 ? " That's a big stretch: Wash Out avoids it." : ""))
            HStack(spacing: 6) {
                Image(systemName: "tuningfork").frame(width: 16)
                if session.semitones == 0 {
                    Text("B in \(b.key.camelotCode)")
                } else {
                    Text("B \(b.key.camelotCode) → \(session.keyAfterShift?.camelotCode ?? "–")")
                }
                Text("A in \(a.key.camelotCode)").foregroundStyle(.secondary)
                if session.keysIncompatible {
                    Text("keys clash").font(.caption).foregroundStyle(.orange)
                        .help("The keys don't fit: the melodies are swapped, never layered. Shifting B's key can fix it.")
                } else {
                    Text("keys fit").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Stepper(value: Binding(get: { session.semitones }, set: { session.setSemitones($0) }), in: -6...6) {
                    Text("\(session.semitones > 0 ? "+" : "")\(session.semitones) st")
                        .font(.system(.body, design: .monospaced))
                }
                .help("Shift B's key (for the whole song)")
            }
        }
        .font(.callout)
    }

    /// Where the transition may start: in a set, not before A is back at
    /// its own tempo.
    private var entryRange: ClosedRange<Int> {
        session.entryRange ?? 0...max(0, session.barCountA - 1)
    }

    private var alignment: some View {
        HStack(spacing: 6) {
            Text("B's bar").foregroundStyle(.secondary)
            Stepper("\(session.cueBar + 1)", value: $session.cueBar, in: 0...max(0, session.barCountB - 1))
                .font(.system(.body, design: .monospaced))
            Text("on A's bar").foregroundStyle(.secondary)
            Stepper("\(session.entryBar + 1)", value: $session.entryBar, in: entryRange, step: 1)
                .font(.system(.body, design: .monospaced))
            Spacer()
            ForEach([-4, 4], id: \.self) { d in
                Button(d > 0 ? "+\(d)" : "\(d)") {
                    session.entryBar = max(entryRange.lowerBound, min(entryRange.upperBound, session.entryBar + d))
                }
                .help("Move the transition \(abs(d)) bars \(d > 0 ? "later" : "earlier") in A")
            }
            .controlSize(.small)
        }
        .font(.callout)
    }

    private var presetControls: some View {
        HStack(spacing: 8) {
            Picker("", selection: Binding(get: { session.preset }, set: { session.choosePreset($0) })) {
                ForEach(TransitionPreset.allCases) { Text($0.displayName).tag($0) }
            }
            .labelsHidden()
            .frame(width: 120)
            .help(session.preset.summary)
            Picker("", selection: Binding(get: { session.transitionBars }, set: { session.chooseBars($0) })) {
                ForEach([1, 2, 4, 8, 16, 32, 64], id: \.self) { Text("\($0) bars").tag($0) }
            }
            .labelsHidden()
            .frame(width: 86)
            Spacer()
            Button("Apply") { session.applyPreset() }
                .help("Rewrite the automation with this preset at the current bars")
            Button("Clear") { session.clearAutomation() }
                .help("Remove all automation from this transition")
        }
    }
}
