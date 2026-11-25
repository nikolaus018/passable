import Accelerate
import Foundation

/// What a built transition measures on its audio, as one number: the
/// defects `tools/score/score.py` weighs that belong to the blend itself
/// (a step it adds to the mix, the two songs barely heard together, a dip
/// in level, bars with too much going on, a stretch nobody sings, a voice
/// cut mid-sentence or brought in mid-part, a jump in the singer's level,
/// words cut in two). The same measures as passable-render's `--report`
/// and `--vocals`, weighted as the score weighs them.
///
/// A pair measures nearly the same whatever order it sits in (132 pairs
/// measured in three or more orders of an 86-song set: 83 alike in all),
/// while the planner's price foresees it loosely (r = 0.17): so what a
/// pair has measured is remembered (`SetMix.Measured`) and priced in.
enum TransitionMeasure {
    struct Points: Equatable {
        var excess = 0.0, together = 0, dip = 0.0, busy = 0
        var gap = 0, aMidSentence = false, bMidPart = false, step = 0.0, chopOut: Double?, chopIn: Double?

        /// The score's weights (see tools/score/score.py).
        var total: Double {
            var p = 0.0
            if excess > 2 { p += 3 }
            if together < 4 { p += 1 }
            if dip > 4 { p += 2 }
            p += 0.5 * Double(busy)
            if gap > 4 { p += 3 }
            if aMidSentence { p += 2 }
            if bMidPart { p += 2 }
            if abs(step) > 4 { p += 2 }
            for chop in [chopOut, chopIn].compactMap({ $0 }) { p += chop > -6 ? 5 : chop > -15 ? 3 : 0 }
            return p
        }
    }

    private static var sr: Double { AudioIO.sampleRate }

    /// Power per bar above 150 Hz (dB).
    static func barLevels(from: Double, bars: Int, barSeconds: Double, of snapshot: MixSnapshot) -> [Double] {
        let n = 4096, fft = RealFFT(size: n)
        let window = (0..<n).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(n))) }
        let lo = max(1, Int(150 / sr * Double(n))), hi = Int(16_000 / sr * Double(n))
        let renderer = MixRenderer(snapshot: snapshot)
        renderer.setPositionImmediately(Int(from * sr))
        var out: [Double] = []
        for _ in 0..<max(0, bars) {
            let count = Int(barSeconds * sr)
            var l = [Float](repeating: 0, count: count), r = l
            renderer.render(left: &l, right: &r, count: count)
            let m = zip(l, r).map { 0.5 * ($0 + $1) }
            var power = 0.0, frames = 0
            var start = 0
            while start + n <= count {
                let mag = fft.magnitudes(of: (0..<n).map { m[start + $0] * window[$0] })
                for k in lo..<hi { power += Double(mag[k] * mag[k]) }
                frames += 1
                start += n / 2
            }
            out.append(10 * log10(power / Double(max(1, frames)) + 1e-12))
        }
        return out
    }

    /// 24 log-spaced bands, 40 Hz to 16 kHz, per bar (dB).
    static func barSpectra(from: Double, bars: Int, barSeconds: Double, of snapshot: MixSnapshot) -> [[Double]] {
        let n = 4096, fft = RealFFT(size: n)
        let window = (0..<n).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(n))) }
        let edges = (0...24).map { Int(40 * pow(16_000.0 / 40, Double($0) / 24) / sr * Double(n)) }
        let renderer = MixRenderer(snapshot: snapshot)
        renderer.setPositionImmediately(Int(from * sr))
        var out: [[Double]] = []
        for _ in 0..<max(0, bars) {
            let count = Int(barSeconds * sr)
            var l = [Float](repeating: 0, count: count), r = l
            renderer.render(left: &l, right: &r, count: count)
            let m = zip(l, r).map { 0.5 * ($0 + $1) }
            var bands = [Double](repeating: 0, count: 24)
            var start = 0
            while start + n <= count {
                let mag = fft.magnitudes(of: (0..<n).map { m[start + $0] * window[$0] })
                for b in 0..<24 { for k in edges[b]..<max(edges[b] + 1, edges[b + 1]) { bands[b] += Double(mag[k] * mag[k]) } }
                start += n / 2
            }
            out.append(bands.map { 10 * log10($0 + 1e-9) })
        }
        return out
    }

    static func jumps(_ s: [[Double]]) -> [Double] {
        zip(s, s.dropFirst()).map { a, b in zip(a, b).map { abs($0 - $1) }.reduce(0, +) / Double(a.count) }
    }

    /// Transition `i` of `mix`, measured.
    static func measure(_ mix: SetMix, _ i: Int) -> Points {
        var p = Points()
        let t = mix.transitions[i]
        func levels(from: Double, bars: Int, barSeconds: Double, _ including: @escaping (Int, StemKind) -> Bool) -> [Double] {
            barLevels(from: from, bars: bars, barSeconds: barSeconds, of: mix.snapshot(masterGain: 1, including: including))
        }
        var raw = mix
        for k in raw.tracks.indices { raw.tracks[k].envelopes = [:]; raw.tracks[k].rolls = [] }

        // The step the transition adds (`--report`'s excess).
        let from = t.begins - 2 * t.barSeconds
        let bars = Int(((t.end - from) / t.barSeconds).rounded(.up)) + 2
        let js = jumps(barSpectra(from: from, bars: bars, barSeconds: t.barSeconds, of: mix.snapshot(masterGain: 1)))
        func alone(_ k: Int) -> [Double] {
            jumps(barSpectra(from: from, bars: bars, barSeconds: t.barSeconds, of: raw.snapshot(masterGain: 1) { i, _ in i == k }))
        }
        let ja = alone(t.from), jb = alone(t.to)
        let silenceBar = t.dropAt.map { Int((($0 - from) / t.barSeconds).rounded()) - 1 }
        let slam = t.dropDelayBars > 0 ? silenceBar.map { $0 + Int(t.dropDelayBars.rounded()) } : nil
        let meant = { (j: Int) in (silenceBar.map { j == $0 - 1 || j == $0 } ?? false) || j == slam }
        p.excess = js.indices.filter { !meant($0) }.map { js[$0] - max(ja[$0], jb[$0]) }.max() ?? 0

        // The songs' own level where each plays alone, for the dip.
        var ownLevel: [Double] = []
        for k in [t.from, t.to] {
            let a = k == 0 ? max(0, mix.tracks[0].offset) : mix.transitions[k - 1].end
            let b = k < mix.transitions.count ? mix.transitions[k].begins : mix.length
            let count = Int((b - a) / t.barSeconds) - 1
            if count > 4 { ownLevel += levels(from: a, bars: count, barSeconds: t.barSeconds) { _, _ in true } }
        }
        ownLevel.sort()
        let median = ownLevel.isEmpty ? 0 : ownLevel[ownLevel.count / 2]
        let n = Int(((t.end - t.begins) / t.barSeconds).rounded())
        let all = levels(from: t.begins, bars: n, barSeconds: t.barSeconds) { _, _ in true }
        let a = levels(from: t.begins, bars: n, barSeconds: t.barSeconds) { k, _ in k == t.from }
        let b = levels(from: t.begins, bars: n, barSeconds: t.barSeconds) { k, _ in k == t.to }
        p.together = (0..<n).filter { a[$0] > all[$0] - 8 && b[$0] > all[$0] - 8 }.count
        let heard = levels(from: t.begins, bars: n + 2, barSeconds: t.barSeconds) { _, _ in true }
        let quiet = silenceBar.map { $0 - 2 }
        let bare = quiet.map { $0 + Int(t.dropDelayBars.rounded()) }
        let around = heard.indices.map { j -> Double in
            guard let q = quiet, j >= q, j <= (bare ?? q) else { return heard[j] }
            return heard[max(0, q - 1)]
        }
        p.dip = median - (around.min() ?? median)
        let leads = [(t.from, StemKind.other), (t.from, .vocals), (t.to, .other), (t.to, .vocals)].map { part in
            levels(from: t.begins, bars: n, barSeconds: t.barSeconds) { k, s in k == part.0 && s == part.1 }
        }
        p.busy = (0..<n).filter { g in
            let top = leads.map { $0[g] }.max()!
            return leads.filter { $0[g] > top - 12 && $0[g] > -70 }.count >= 3
        }.count

        // The voices' handover (`--vocals`).
        guard let out = t.vocalOut, let inn = t.vocalIn else { return p }
        func slot(_ k: Int, _ time: Double) -> Int? {
            let track = mix.tracks[k]
            let own = track.map.source((time - track.offset) * sr) / sr
            return Int((track.loaded.analysis.grid.bars(at: own) * Double(VocalPhrasing.slots)).rounded())
        }
        let beat = t.barSeconds / 4
        let vFrom = min(out, inn) - 4 * t.barSeconds, beats = Int((abs(out - inn) + 8 * t.barSeconds) / beat)
        let la = levels(from: vFrom, bars: beats, barSeconds: beat) { k, s in k == t.from && s == .vocals }
        let lb = levels(from: vFrom, bars: beats, barSeconds: beat) { k, s in k == t.to && s == .vocals }
        func ref(_ l: [Double]) -> Double { let s = l.sorted(); return s.isEmpty ? -120 : s[Int(Double(s.count - 1) * 0.9)] }
        let ra = ref(la), rb = ref(lb)
        let voiceFloor = 25.0
        let ha = la.map { $0 > max(ra - 15, voiceFloor) }, hb = lb.map { $0 > max(rb - 15, voiceFloor) }
        func untouched(_ k: Int) -> [Double] {
            barLevels(from: vFrom, bars: beats, barSeconds: beat, of: raw.snapshot(masterGain: 1, including: { i, s in i == k && s == .vocals }))
        }
        let rawA = untouched(t.from), rawB = untouched(t.to)
        let ua = rawA.indices.map { rawA[$0] > max(ra - 15, voiceFloor) && vFrom + Double($0) * beat < t.end }
        let ub = rawB.indices.map { rawB[$0] > max(rb - 15, voiceFloor) && vFrom + Double($0 + 1) * beat > t.begins }
        var run = 0
        for k in 0..<beats {
            let hole = !ha[k] && !hb[k] && (ua[k] || ub[k])
            run = hole ? run + 1 : 0; p.gap = max(p.gap, run)
        }
        let sa = mix.tracks[t.from].loaded.analysis.structure, sb = mix.tracks[t.to].loaded.analysis.structure
        let plain = mix.tracks[t.from].skip == nil && mix.tracks[t.to].skip == nil
            && MixMath.tempoMultiplier(a: mix.tracks[t.from].loaded.analysis.grid.bpm, b: mix.tracks[t.to].loaded.analysis.grid.bpm) == 1
        p.aMidSentence = plain && (slot(t.from, out).map { k in (k - 1...k + 1).allSatisfy { sa?.midSentence(at: $0) ?? false }
            && !(k - 2...k + 2).contains { sa?.clauseEnd(at: $0) ?? false } } ?? false)
        p.bMidPart = plain && (slot(t.to, inn).map { k in (k - 1...k + 1).allSatisfy { sb?.midPart(at: $0) ?? false }
            && !(k - 2...k + 2).contains { sb?.partStart(at: $0) ?? false } } ?? false)
        let singsA = ref(rawA) - 10, singsB = ref(rawB) - 10
        let aSung = ha.indices.filter { ha[$0] && rawA[$0] > singsA }.suffix(8).map { la[$0] }.sorted()
        let bSung = hb.indices.filter { hb[$0] && rawB[$0] > singsB }.prefix(8).map { lb[$0] }.sorted()
        if ra > 25, rb > 25, aSung.count >= 4, bSung.count >= 4 { p.step = bSung[bSung.count / 2] - aSung[aSung.count / 2] }

        // Words cut in two where the channels shut and open.
        func frames(_ k: Int, from t0: Double, count: Int) -> [Double] {
            let renderer = MixRenderer(snapshot: raw.snapshot(masterGain: 1, including: { i, s in i == k && s == .vocals }))
            renderer.setPositionImmediately(Int(t0 * sr))
            let len = Int(0.005 * sr)
            let silentFrom = k == t.from && t.loopBars > 0 ? t.start : .infinity
            return (0..<count).map { f in
                var l = [Float](repeating: 0, count: len), r = l
                renderer.render(left: &l, right: &r, count: len)
                guard t0 + Double(f) * 0.005 < silentFrom else { return -120 }
                let pw = zip(l, r).reduce(0.0) { $0 + Double(0.25 * ($1.0 + $1.1) * ($1.0 + $1.1)) } / Double(len)
                return 10 * log10(pw + 1e-12)
            }
        }
        func chopAt(_ k: Int, _ time: Double, before: Double, after: Double) -> Double {
            let aroundFrames = frames(k, from: time - 2 * t.barSeconds, count: Int(4 * t.barSeconds / 0.005)).sorted()
            let loud = aroundFrames[aroundFrames.count * 9 / 10]
            let at = frames(k, from: time - before, count: max(1, Int((before + after) / 0.005)))
            guard loud > -60 else { return -120 }
            return (at.max() ?? -120) - loud
        }
        func songFrames(_ k: Int, from t0: Double, count: Int) -> [Double] {
            let track = mix.tracks[k]
            guard let v = track.loaded.stems[.vocals] else { return [] }
            let len = Int(0.005 * sr)
            return (0..<count).map { f in
                let at = t0 + Double(f) * 0.005
                let own = Int(track.map.source((at - track.stemOffset(at: at)) * sr))
                guard own >= 0, own + len <= v.count else { return -120 }
                var l: Float = 0, r: Float = 0
                vDSP_measqv(v.left.pointer + own, 1, &l, vDSP_Length(len))
                vDSP_measqv(v.right.pointer + own, 1, &r, vDSP_Length(len))
                return Double(10 * log10(max((l + r) / 2, 1e-12)))
            }
        }
        func chopOwn(_ k: Int, _ time: Double, before: Double, after: Double) -> Double {
            let aroundFrames = songFrames(k, from: time - 2 * t.barSeconds, count: Int(4 * t.barSeconds / 0.005)).sorted()
            guard !aroundFrames.isEmpty else { return -120 }
            let loud = aroundFrames[aroundFrames.count * 9 / 10]
            let at = songFrames(k, from: time - before, count: max(1, Int((before + after) / 0.005)))
            guard loud > -60 else { return -120 }
            return (at.max() ?? -120) - loud
        }
        p.chopOut = t.vocalOutKind == "bar" ? nil : chopOwn(t.from, out, before: 0.03, after: 0.02)
        p.chopIn = chopAt(t.to, inn, before: 0.04, after: 0)
        return p
    }
}
