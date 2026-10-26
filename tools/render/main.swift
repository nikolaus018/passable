import Foundation

// passable-render: builds a set from songs already loaded once in the app
// (stems and analysis cached) and writes it, or just its transitions, as WAV.
//
//   passable-render [--out DIR] [--whole] SONG SONG [SONG …]
//
// Songs play in the order given. Without --whole, each transition is written
// on its own with 8 bars either side.

var args = Array(CommandLine.arguments.dropFirst())
var outDir = URL(fileURLWithPath: "render-out")
var whole = false
var ordered = false
var songs: [URL] = []
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--out": outDir = URL(fileURLWithPath: args.removeFirst())
    case "--whole": whole = true
    case "--fidelity", "--exact", "--stretch", "--moves", "--seams", "--report", "--steps", "-v", "--levels", "--limiter": break
    case "--order": ordered = true
    case "--detail": _ = args.removeFirst()
    case "--list":
        let text = try String(contentsOfFile: args.removeFirst(), encoding: .utf8)
        songs += text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .map { URL(fileURLWithPath: $0) }
    case "--help", "-h":
        print("passable-render [--out DIR] [--whole] [--order] [--list FILE] [--report|--moves|--seams|--fidelity] SONG SONG [SONG …]")
        exit(0)
    default: songs.append(URL(fileURLWithPath: a))
    }
}
guard songs.count >= 2 else { fputs("need at least two songs\n", stderr); exit(2) }

func seconds(_ since: Date) -> String { String(format: "%.1f s", Date().timeIntervalSince(since)) }

let clock = Date()
let processor = TrackProcessor()
var tracks: [(url: URL, loaded: TrackProcessor.Loaded)] = []
for url in songs {
    let loaded = try await withCheckedThrowingContinuation { (c: CheckedContinuation<TrackProcessor.Loaded, Error>) in
        processor.load(url, ticket: .init(), progress: { _ in }) { c.resume(with: $0) }
    }
    tracks.append((url, loaded))
}
print("loaded \(tracks.count) songs in \(seconds(clock))")
if ordered {
    // As the app's Auto-Order does it.
    let analyses = tracks.map(\.loaded.analysis)
    let costs = SetOrdering.costMatrix(analyses, drums: BeatAlign.attacks(of: tracks.map(\.loaded)), remembered: true)
    let order = SetOrdering.order(costs, washOuts: SetOrdering.washOuts(analyses), energies: analyses.map(SetOrdering.energy))
    tracks = order.map { tracks[$0] }
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    try? tracks.map(\.url.path).joined(separator: "\n").write(to: outDir.appendingPathComponent("order.txt"), atomically: true, encoding: .utf8)
    print("ordered in \(seconds(clock))")
}
let built = Date()
let mix = try await SetBuilder.build(tracks, processor: processor) { _ in }
print("built in \(seconds(built))")

try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let sr = AudioIO.sampleRate
let snapshot = mix.snapshot(masterGain: 1)

/// How close `y` is to the best-scaled, best-aligned (±`lag` frames) `x`, dB.
func snr(_ x: [Float], _ y: [Float], lag: Int = 256) -> (db: Double, lag: Int) {
    let n = min(x.count, y.count) - 2 * lag
    guard n > 0 else { return (.nan, 0) }
    var best = (db: -Double.infinity, lag: 0)
    for d in stride(from: -lag, through: lag, by: 1) {
        var xy = 0.0, xx = 0.0, yy = 0.0
        for k in lag..<(lag + n) {
            let a = Double(x[k + d]), b = Double(y[k])
            xy += a * b; xx += a * a; yy += b * b
        }
        guard xx > 0 else { continue }
        let g = xy / xx, err = yy - 2 * g * xy + g * g * xx
        let db = 10 * log10(g * g * xx / max(err, 1e-20))
        if db > best.db { best = (db, d) }
    }
    return best
}

/// Mean absolute difference of two signals' log spectra (dB, 2048-point
/// frames, bins 40 Hz–16 kHz, frames where `x` is within 50 dB of its peak).
func spectralDistance(_ x: [Float], _ y: [Float]) -> Double {
    let n = 2048, fft = RealFFT(size: n)
    let window = (0..<n).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(n))) }
    let lo = Int(40.0 / sr * Double(n)), hi = Int(16_000.0 / sr * Double(n))
    var frames: [(a: [Float], b: [Float], e: Float)] = []
    var start = 0
    while start + n <= min(x.count, y.count) {
        let a = fft.magnitudes(of: (0..<n).map { x[start + $0] * window[$0] })
        let b = fft.magnitudes(of: (0..<n).map { y[start + $0] * window[$0] })
        frames.append((a, b, a[lo..<hi].reduce(0) { $0 + $1 * $1 }))
        start += n / 2
    }
    let top = frames.map(\.e).max() ?? 0
    var sum = 0.0, count = 0
    for f in frames where f.e > top * 1e-5 {
        for k in lo..<hi {
            sum += abs(20 * log10(Double(f.a[k]) + 1e-6) - 20 * log10(Double(f.b[k]) + 1e-6)); count += 1
        }
    }
    return count > 0 ? sum / Double(count) : .nan
}

/// The mix's spectrum bar by bar (24 bands, 40 Hz–16 kHz, dB) from `from`.
/// The set with every song playing untouched (no automation, no rolls):
/// what each song does by itself at each moment.
func barSpectra(from: Double, bars: Int, barSeconds: Double, of source: MixSnapshot? = nil) -> [[Double]] {
    let snapshot = source ?? snapshot
    let n = 4096, fft = RealFFT(size: n)
    let window = (0..<n).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(n))) }
    let edges = (0...24).map { Int(40 * pow(16_000.0 / 40, Double($0) / 24) / sr * Double(n)) }
    let renderer = MixRenderer(snapshot: snapshot)
    renderer.setPositionImmediately(Int(from * sr))
    var out: [[Double]] = []
    for _ in 0..<bars {
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

/// Mean absolute dB change across bands between consecutive bars.
func jumps(_ s: [[Double]]) -> [Double] {
    zip(s, s.dropFirst()).map { a, b in zip(a, b).map { abs($0 - $1) }.reduce(0, +) / Double(a.count) }
}

/// Power per bar above 150 Hz (dB) of what `including` lets through.
func barLevels(from: Double, bars: Int, barSeconds: Double, including: @escaping (Int, StemKind) -> Bool) -> [Double] {
    let n = 4096, fft = RealFFT(size: n)
    let window = (0..<n).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(n))) }
    let lo = Int(150 / sr * Double(n)), hi = Int(16_000 / sr * Double(n))
    let renderer = MixRenderer(snapshot: mix.snapshot(masterGain: 1, including: including))
    renderer.setPositionImmediately(Int(from * sr))
    var out: [Double] = []
    for _ in 0..<bars {
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

/// Changes (a lane leaving a value) starting within the same eighth of a bar.
func simultaneousMoves(_ t: SetMix.Transition) -> Int {
    var starts: [Double] = []
    for track in [mix.tracks[t.from], mix.tracks[t.to]] {
        for (_, envelopes) in track.envelopes {
            for p in LaneParameter.allCases where p != .reverb && p != .delay && p.rawValue < envelopes.count {
                let pts = envelopes[p.rawValue].points
                for k in pts.indices.dropFirst() where abs(pts[k].value - pts[k - 1].value) > 0.01
                    && pts[k - 1].time >= t.begins - t.barSeconds && pts[k - 1].time <= t.end + t.barSeconds {
                    starts.append(pts[k - 1].time)
                }
            }
        }
    }
    let window = t.barSeconds / 8
    return starts.map { s in starts.filter { $0 >= s && $0 < s + window }.count }.max() ?? 0
}

if let k = CommandLine.arguments.firstIndex(of: "--detail"), let which = Int(CommandLine.arguments[k + 1]) {
    // One transition bar by bar: each part's level above 150 Hz (dB).
    let t = mix.transitions[which - 1]
    let from = t.begins - 4 * t.barSeconds
    let n = Int(((t.end - from) / t.barSeconds).rounded()) + 4
    func row(_ name: String, _ f: @escaping (Int, StemKind) -> Bool) {
        let v = barLevels(from: from, bars: n, barSeconds: t.barSeconds, including: f)
        print(name.padding(toLength: 10, withPad: " ", startingAt: 0) + v.map { $0 < -90 ? "   ." : String(format: "%4.0f", $0) }.joined())
    }
    print(String(format: "%@ → %@  %@ %d bars, switch %.0f, voice out %@ in %@", SongTitle.of(mix.tracks[t.from].url),
                 SongTitle.of(mix.tracks[t.to].url), t.edit.preset.displayName, t.edit.bars,
                 TransitionBuilder.switchBar(t.edit.preset, bars: t.edit.bars, lowSwap: t.plan.placement.lowSwap),
                 t.vocalOut.map { String(format: "%.1f", ($0 - t.start) / t.barSeconds) } ?? "-",
                 t.vocalIn.map { String(format: "%.1f", ($0 - t.start) / t.barSeconds) } ?? "-"))
    print("bar       " + (0..<n).map { String(format: "%4d", $0 - 4 + Int(((t.begins - t.start) / t.barSeconds).rounded())) }.joined())
    row("mix") { _, _ in true }
    for (side, i) in [("A", t.from), ("B", t.to)] {
        row(side) { k, _ in k == i }
        for stem in StemKind.laneOrder { row("  \(side) \(stem.rawValue)") { k, s in k == i && s == stem } }
    }
    exit(0)
}

if CommandLine.arguments.contains("--limiter") {
    // How hard the master limiter works: the set rendered 12 dB down (the
    // limiter idle), then the limiter's own gain computed on it at full
    // level. Share of time it pulls the level down, inside transitions and
    // outside.
    let n = Int(mix.length * sr)
    let quiet = mix.snapshot(masterGain: 0.25)
    let renderer = MixRenderer(snapshot: quiet)
    renderer.setPositionImmediately(0)
    let block = 1 << 16
    var l = [Float](repeating: 0, count: block), r = l
    let ceiling: Float = 0.966, release = Float(exp(-1 / (0.15 * sr)))
    var envelope: Float = 0
    var counts = [[Int]](repeating: [0, 0, 0, 0], count: 2)  // [inside/outside][total, >0.5 dB, >1 dB, >3 dB]
    var worst = [0.0, 0.0]
    var done = 0
    var spans = mix.transitions.map { (Int(($0.begins - $0.barSeconds) * sr), Int(($0.end + $0.barSeconds) * sr)) }
    spans.sort { $0.0 < $1.0 }
    while done < n {
        let count = min(block, n - done)
        renderer.render(left: &l, right: &r, count: count)
        for k in 0..<count {
            let peak = 4 * max(abs(l[k]), abs(r[k]))
            envelope = peak > envelope ? peak : envelope * release + peak * (1 - release)
            let gr = envelope > ceiling ? 20 * log10(Double(envelope / ceiling)) : 0
            let f = done + k
            let side = spans.contains { f >= $0.0 && f < $0.1 } ? 0 : 1
            counts[side][0] += 1
            if gr > 0.5 { counts[side][1] += 1 }
            if gr > 1 { counts[side][2] += 1 }
            if gr > 3 { counts[side][3] += 1 }
            worst[side] = max(worst[side], gr)
        }
        done += count
    }
    for (side, name) in [(0, "in transitions"), (1, "elsewhere")] {
        let c = counts[side], t = Double(max(1, c[0]))
        print(String(format: "%@: limiting over 0.5 dB %.1f %% of the time, over 1 dB %.1f %%, over 3 dB %.2f %%, most %.1f dB",
                     name, 100 * Double(c[1]) / t, 100 * Double(c[2]) / t, 100 * Double(c[3]) / t, worst[side]))
    }
    exit(0)
}

if CommandLine.arguments.contains("--levels") {
    // Each song where it plays alone, as heard: K-weighted (BS.1770) and
    // plain, 400 ms blocks, the 80th percentile of its loud blocks.
    var heard: [Double] = [], plain: [Double] = []
    for (i, t) in mix.tracks.enumerated() {
        let a = i == 0 ? max(0, t.offset) : mix.transitions[i - 1].end
        let b = i < mix.transitions.count ? mix.transitions[i].begins : mix.length
        guard b - a > 8 else { continue }
        let n = Int((b - a) * sr)
        let renderer = MixRenderer(snapshot: snapshot)
        renderer.setPositionImmediately(Int(a * sr))
        var l = [Float](repeating: 0, count: n), r = l
        renderer.render(left: &l, right: &r, count: n)
        var kl = l, kr = r
        var shelf = Biquad(), pass = Biquad()
        shelf.set(.highShelf(frequency: 1681.97, gainDB: 4.0), sampleRate: sr)
        pass.set(.highPass(frequency: 38.135, q: 0.5003), sampleRate: sr)
        kl.withUnsafeMutableBufferPointer { lp in kr.withUnsafeMutableBufferPointer { rp in
            shelf.process(lp.baseAddress!, rp.baseAddress!, count: n)
            pass.process(lp.baseAddress!, rp.baseAddress!, count: n)
        } }
        func blocks(_ x: [Float], _ y: [Float]) -> Double {
            let size = Int(0.4 * sr)
            var out: [Double] = []
            for s in stride(from: 0, to: n - size, by: size / 4) {
                var e = 0.0
                for k in s..<(s + size) { e += Double(x[k] * x[k] + y[k] * y[k]) }
                out.append(10 * log10(e / Double(size) + 1e-12) - 0.691)
            }
            out = out.filter { $0 > -50 }.sorted()
            return out.isEmpty ? -99 : out[Int(Double(out.count - 1) * 0.8)]
        }
        let k = blocks(kl, kr), p = blocks(l, r)
        heard.append(k); plain.append(p)
        let st = t.loaded.analysis.structure
        print(String(format: "%5.1f LUFS-ish  %5.1f dB plain  (refs: plain %.1f, heard %.1f)  %@", k, p,
                     st?.referenceLoudness ?? .nan, st?.heardReference ?? .nan, SongTitle.of(t.url)))
    }
    func spread(_ x: [Double]) -> String {
        let m = x.reduce(0, +) / Double(x.count)
        let sd = (x.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(x.count)).squareRoot()
        let steps = zip(x, x.dropFirst()).map { abs($0 - $1) }
        return String(format: "range %.1f dB, sd %.1f, song to song mean %.1f max %.1f", (x.max() ?? 0) - (x.min() ?? 0), sd,
                      steps.reduce(0, +) / Double(max(1, steps.count)), steps.max() ?? 0)
    }
    print("heard (K-weighted): " + spread(heard))
    print("plain:              " + spread(plain))
    exit(0)
}

if CommandLine.arguments.contains("--steps") {
    // Every hard on/off of a part (a volume step under 10 ms) in a
    // transition, against the part's own audio there: how much of a hit
    // or note an opening leaves out before it (chopped attack: a click and
    // a weak first hit) and how much a closing cuts off after it.
    var chopped = 0, total = 0
    var leads: [Double] = []
    for (i, t) in mix.transitions.enumerated() {
        for (side, k) in [("A", t.from), ("B", t.to)] {
            let track = mix.tracks[k]
            for stem in StemKind.laneOrder {
                guard let env = track.envelopes[stem]?[LaneParameter.volume.rawValue], let audio = track.stems[stem] else { continue }
                let pts = env.points
                for j in pts.indices.dropFirst() {
                    let a = pts[j - 1], b = pts[j]
                    guard b.time - a.time < 0.01, abs(b.value - a.value) > 0.5,
                          a.time > t.begins - t.barSeconds, a.time < t.end + t.barSeconds else { continue }
                    let opening = b.value > a.value
                    let at = a.time
                    let frame = Int(((at - track.stemOffset(at: at)) * sr).rounded())
                    func rms(_ from: Int, _ to: Int) -> Double {
                        var e = 0.0, n = 0
                        let lo = max(0, from), hi = min(audio.count, to)
                        guard lo < hi else { return 0 }
                        for f in lo..<hi {
                            let v = Double(audio.left.pointer[f] + audio.right.pointer[f]) * 0.5
                            e += v * v; n += 1
                        }
                        return n > 0 ? sqrt(e / Double(n)) : 0
                    }
                    let ms = Int(sr / 1000)
                    // The loudest 5 ms window from 30 ms before to 30 ms
                    // after: where the hit is.
                    var best = -30, bestE = -1.0
                    for d in stride(from: -30, through: 30, by: 1) {
                        let e = rms(frame + d * ms, frame + (d + 5) * ms)
                        if e > bestE { bestE = e; best = d }
                    }
                    // Its onset: first window, going back, under a quarter of the peak.
                    var onset = best
                    while onset > -40 && rms(frame + (onset - 1) * ms, frame + (onset + 4) * ms) > bestE * 0.25 { onset -= 1 }
                    total += 1
                    if stem == .drums || stem == .bass { leads.append(Double(onset)) }
                    let bad = opening ? (onset < 0 && best >= -2) : (onset < 0 && best >= 0)
                    if bad { chopped += 1 }
                    if CommandLine.arguments.contains("-v") {
                        print(String(format: "%02d %@ %@ %@ at bar %.2f: hit peaks %+d ms, starts %+d ms%@", i + 1, side, stem.rawValue,
                                     opening ? "opens" : "closes", (at - t.start) / t.barSeconds, best, onset, bad ? "  CHOPPED" : ""))
                    }
                }
            }
        }
    }
    leads.sort()
    print(String(format: "steps %d, chopped %d; drum/bass hit onsets relative to the step: median %+.0f ms, 10th %+.0f, 90th %+.0f",
                 total, chopped, leads.isEmpty ? 0 : leads[leads.count / 2], leads.isEmpty ? 0 : leads[leads.count / 10],
                 leads.isEmpty ? 0 : leads[leads.count * 9 / 10]))
    exit(0)
}

if CommandLine.arguments.contains("--report") {
    // Everything that can be measured about each transition, and the set's
    // totals: what a change to the planner is judged by.
    struct Row { var seam = 0.0, excess = 0.0, hole = 0.0, together = 0, bars = 0, dip = 0.0, busy = 0, moves = 0 }
    var rows: [Row] = []
    for (i, t) in mix.transitions.enumerated() {
        var row = Row()
        let from = t.begins - 2 * t.barSeconds
        let bars = Int(((t.end - from) / t.barSeconds).rounded(.up)) + 2
        let js = jumps(barSpectra(from: from, bars: bars, barSeconds: t.barSeconds))
        // What the transition adds: the mix's step less the bigger of the
        // two songs' own steps there, each playing untouched.
        func alone(_ k: Int) -> [Double] {
            var raw = mix
            for i in raw.tracks.indices { raw.tracks[i].envelopes = [:]; raw.tracks[i].rolls = [] }
            return jumps(barSpectra(from: from, bars: bars, barSeconds: t.barSeconds,
                                    of: raw.snapshot(masterGain: 1) { i, _ in i == k }))
        }
        let ja = alone(t.from), jb = alone(t.to)
        row.excess = js.indices.map { js[$0] - max(ja[$0], jb[$0]) }.max() ?? 0
        row.seam = js.max() ?? 0
        // (Bar of B's entry the biggest step lands on: the step from the
        // bar before into this one.)
        let seamAt = Double(js.firstIndex(of: row.seam) ?? 0) + 1 + (from - t.start) / t.barSeconds
        var own: [Double] = [], ownLevel: [Double] = []
        for k in [t.from, t.to] {
            let a = k == 0 ? max(0, mix.tracks[0].offset) : mix.transitions[k - 1].end
            let b = k < mix.transitions.count ? mix.transitions[k].begins : mix.length
            let count = Int((b - a) / t.barSeconds) - 1
            if count > 4 {
                own += jumps(barSpectra(from: a, bars: count, barSeconds: t.barSeconds))
                ownLevel += barLevels(from: a, bars: count, barSeconds: t.barSeconds) { _, _ in true }
            }
        }
        own.sort(); ownLevel.sort()
        let p90 = own.isEmpty ? 1 : own[Int(Double(own.count - 1) * 0.9)]
        let median = ownLevel.isEmpty ? 0 : ownLevel[ownLevel.count / 2]
        row.seam /= p90
        // Both songs heard: each within 8 dB of the mix, above 150 Hz.
        let n = Int(((t.end - t.begins) / t.barSeconds).rounded())
        row.bars = n
        let all = barLevels(from: t.begins, bars: n, barSeconds: t.barSeconds) { _, _ in true }
        let a = barLevels(from: t.begins, bars: n, barSeconds: t.barSeconds) { k, _ in k == t.from }
        let b = barLevels(from: t.begins, bars: n, barSeconds: t.barSeconds) { k, _ in k == t.to }
        row.together = (0..<n).filter { a[$0] > all[$0] - 8 && b[$0] > all[$0] - 8 }.count
        // (Through two bars past the end: a swap lands on the blend's last
        // downbeat.)
        let around = barLevels(from: t.begins, bars: n + 2, barSeconds: t.barSeconds) { _, _ in true }
        row.dip = median - (around.min() ?? median)
        row.hole = zip(around, around.dropFirst()).map { $0 - $1 }.max() ?? 0
        // Busy: three or more of the two melodies and two voices heard
        // (within 12 dB of the loudest of them).
        let leads = [(t.from, StemKind.other), (t.from, .vocals), (t.to, .other), (t.to, .vocals)].map { part in
            barLevels(from: t.begins, bars: n, barSeconds: t.barSeconds) { k, s in k == part.0 && s == part.1 }
        }
        row.busy = (0..<n).filter { g in
            let top = leads.map { $0[g] }.max()!
            return leads.filter { $0[g] > top - 12 && $0[g] > -70 }.count >= 3
        }.count
        row.moves = simultaneousMoves(t)
        rows.append(row)
        let sw = TransitionBuilder.switchBar(t.edit.preset, bars: t.edit.bars, lowSwap: t.plan.placement.lowSwap)
        print(String(format: "%02d %@ → %@  %@ %d  excess %.1f dB  seam %.2f× at %.0f (switch %.0f)  together %d/%d  dip %.1f dB (drop %.1f)  busy %d  at once %d%@",
                     i + 1, SongTitle.of(mix.tracks[t.from].url), SongTitle.of(mix.tracks[t.to].url),
                     t.edit.preset.displayName, t.edit.bars, row.excess, row.seam, seamAt, sw, row.together, n, row.dip, row.hole, row.busy, row.moves,
                     t.melodiesClash ? "  clash" : ""))
    }
    let m = Double(max(1, rows.count))
    print(String(format: "SET %d transitions: excess mean %.2f dB worst %.2f, over 2 dB: %d | seam mean %.2f× worst %.2f× | together mean %.1f, under 4: %d | dips over 4 dB: %d, bar-to-bar drops over 6 dB: %d | busy bars %d | at once max %d mean %.1f",
                 rows.count, rows.map(\.excess).reduce(0, +) / m, rows.map(\.excess).max() ?? 0, rows.filter { $0.excess > 2 }.count,
                 rows.map(\.seam).reduce(0, +) / m, rows.map(\.seam).max() ?? 0,
                 Double(rows.map(\.together).reduce(0, +)) / m, rows.filter { $0.together < 4 }.count,
                 rows.filter { $0.dip > 4 }.count, rows.filter { $0.hole > 6 }.count, rows.map(\.busy).reduce(0, +), rows.map(\.moves).max() ?? 0,
                 Double(rows.map(\.moves).reduce(0, +)) / m))
    exit(0)
}

if CommandLine.arguments.contains("--seams") {
    // How big a change a transition's biggest bar-to-bar step is, against
    // the songs' own biggest (verse to chorus, into a drop): a blend whose
    // seam is no bigger than a song's own changes plays as one piece.
    var ratios: [Double] = []
    for (i, t) in mix.transitions.enumerated() {
        let from = t.begins - 2 * t.barSeconds
        let bars = Int(((t.end - from) / t.barSeconds).rounded(.up)) + 2
        let seam = jumps(barSpectra(from: from, bars: bars, barSeconds: t.barSeconds)).max() ?? 0
        // The songs' own: their solo stretches.
        var own: [Double] = []
        for k in [t.from, t.to] {
            let a = k == 0 ? max(0, mix.tracks[0].offset) : mix.transitions[k - 1].end
            let b = k < mix.transitions.count ? mix.transitions[k].begins : mix.length
            let bars = Int((b - a) / t.barSeconds) - 1
            if bars > 4 { own += jumps(barSpectra(from: a, bars: bars, barSeconds: t.barSeconds)) }
        }
        own.sort()
        let p90 = own.isEmpty ? 1 : own[Int(Double(own.count - 1) * 0.9)]
        ratios.append(seam / p90)
        print(String(format: "%02d %@ → %@  seam %.1f dB, songs' own: 90th %.1f, max %.1f  → %.2f×", i + 1,
                     SongTitle.of(mix.tracks[t.from].url), SongTitle.of(mix.tracks[t.to].url), seam, p90, own.last ?? 0, seam / p90))
    }
    print(String(format: "mean %.2f×, worst %.2f×", ratios.reduce(0, +) / Double(max(1, ratios.count)), ratios.max() ?? 0))
    exit(0)
}

if CommandLine.arguments.contains("--moves") {
    // Every automated change in each transition, bar by bar from B's first
    // bar: what a DJ's hands would have to do.
    for (i, t) in mix.transitions.enumerated() {
        let from = t.begins - t.barSeconds, to = t.end + t.barSeconds
        var moves = 0
        print(String(format: "%02d %@ → %@  %@ %d bars, rolls %d", i + 1, SongTitle.of(mix.tracks[t.from].url),
                     SongTitle.of(mix.tracks[t.to].url), t.edit.preset.displayName, t.edit.bars,
                     (mix.tracks[t.from].rolls + mix.tracks[t.to].rolls).filter { $0.start < to && $0.end > from }.count))
        for (side, track) in [("A", mix.tracks[t.from]), ("B", mix.tracks[t.to])] {
            for stem in StemKind.laneOrder {
                guard let envelopes = track.envelopes[stem] else { continue }
                for p in LaneParameter.allCases where p.rawValue < envelopes.count {
                    let pts = envelopes[p.rawValue].points
                    var line: [String] = []
                    for k in pts.indices.dropFirst() where pts[k].time > from && pts[k - 1].time < to
                        && abs(pts[k].value - pts[k - 1].value) > 0.01 {
                        line.append(String(format: "%.1f→%.1f: %.2f→%.2f", (pts[k - 1].time - t.start) / t.barSeconds,
                                           (pts[k].time - t.start) / t.barSeconds, pts[k - 1].value, pts[k].value))
                    }
                    if !line.isEmpty {
                        moves += line.count
                        print("   \(side) \(stem.rawValue.padding(toLength: 6, withPad: " ", startingAt: 0)) \(p.displayName.padding(toLength: 11, withPad: " ", startingAt: 0)) " + line.joined(separator: "  "))
                    }
                }
            }
        }
        print("   moves: \(moves)")
    }
    exit(0)
}

if CommandLine.arguments.contains("--stretch") {
    // Each stem stretched by 3 % and back, against itself: the stretcher's
    // own damage, twice over.
    let t = mix.tracks[0]
    let n = Int(30 * sr), a = t.loaded.stems[.drums]!.count / 3
    for kind in StemKind.allCases {
        let s = t.loaded.stems[kind]!
        let clip = StereoBuffer(left: Array(UnsafeBufferPointer(start: s.left.pointer + a, count: n)),
                                right: Array(UnsafeBufferPointer(start: s.right.pointer + a, count: n)))
        let clock = Date()
        let there = TimeStretcher.process(clip, map: .constant(1.03), semitones: 0, percussive: kind == .drums)
        let back = TimeStretcher.process(there, map: .constant(1 / 1.03), semitones: 0, percussive: kind == .drums)
        let x = clip.mono(), y = back.mono()
        let edge = Int(sr)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        try MappedChannel.write(x, to: outDir.appendingPathComponent("\(kind.rawValue).orig.f32"))
        try MappedChannel.write(y, to: outDir.appendingPathComponent("\(kind.rawValue).trip.f32"))
        print(String(format: "%@ %@: round trip %.1f dB waveform, %.2f dB spectral (%@)", SongTitle.of(t.url), kind.rawValue,
                     snr(Array(x[edge..<(n - edge)]), Array(y[edge..<(n - edge)]), lag: 64).db,
                     spectralDistance(Array(x[edge..<(n - edge)]), Array(y[edge..<(n - edge)])), seconds(clock)))
    }
    exit(0)
}

if CommandLine.arguments.contains("--exact") {
    // What handing the separation's loss back to the stems does, in memory.
    for t in mix.tracks.prefix(1) {
        let clock = Date()
        let original = try AudioIO.loadStereo(url: t.url)
        var stems = t.loaded.stems.mapValues { $0.copyStereo() }
        let before = stems
        StemResidual.redistribute(mix: original, stems: &stems)
        let n = 44_100 * 20, a = original.count / 3
        let x = Array(original.left[a..<(a + n)])
        func sum(_ s: [StemKind: StereoBuffer]) -> [Float] {
            var y = [Float](repeating: 0, count: n)
            for b in s.values { for k in 0..<n { y[k] += b.left[a + k] } }
            return y
        }
        print(String(format: "%@ (%@): summed stems vs file %.1f dB → %.1f dB", SongTitle.of(t.url), seconds(clock),
                     snr(x, sum(before), lag: 0).db, snr(x, sum(stems), lag: 0).db))
        for kind in StemKind.allCases {
            let old = Array(before[kind]!.left[a..<(a + n)]), new = Array(stems[kind]!.left[a..<(a + n)])
            print(String(format: "  %@ changed by %.1f dB under itself", kind.rawValue, -snr(old, new, lag: 0).db))
        }
    }
    exit(0)
}

if CommandLine.arguments.contains("--fidelity") {
    // Where a song plays alone at its own tempo, how close the set is to the
    // file itself, and how close the four stems summed are.
    for (i, t) in mix.tracks.enumerated() {
        let from = i == 0 ? max(0, t.offset) : mix.transitions[i - 1].settled + 1
        var to = i < mix.transitions.count ? mix.transitions[i].begins - 1 : mix.length - 1
        if let at = t.skipAt { to = min(to, at - 1) }
        guard to - from > 10 else { print("\(SongTitle.of(t.url)): no solo stretch"); continue }
        let mid = (from + to) / 2, span = min(20.0, to - from) / 2
        let a = mid - span, n = Int(2 * span * sr)
        let original = try AudioIO.loadStereo(url: t.url)
        let source = Int((t.map.source((a - t.offset) * sr)).rounded())
        guard source >= 0, source + n <= original.count else { continue }
        let x = Array(original.mono()[source..<(source + n)])
        var stems = [Float](repeating: 0, count: n)
        for stem in t.loaded.stems.values {
            for k in 0..<n where source + k < stem.count {
                stems[k] += 0.5 * (stem.left.pointer[source + k] + stem.right.pointer[source + k])
            }
        }
        let renderer = MixRenderer(snapshot: snapshot)
        renderer.setPositionImmediately(Int(a * sr))
        var l = [Float](repeating: 0, count: n), r = l
        renderer.render(left: &l, right: &r, count: n)
        let y = zip(l, r).map { 0.5 * ($0 + $1) }
        let s = snr(x, stems, lag: 4), p = snr(x, y, lag: 4)
        print(String(format: "%@: stems summed %.1f dB (lag %d), as the set plays it %.1f dB (lag %d)  %@", SongTitle.of(t.url), s.db, s.lag, p.db, p.lag, t.loaded.directory.path))
    }
    exit(0)
}
let rendered = Date()
if whole {
    let url = outDir.appendingPathComponent("set.wav")
    try Exporter.render(snapshot: snapshot, range: 0..<Int(mix.length * sr), tail: 2, to: url) { _ in }
    print("wrote \(url.path)")
} else {
    for (i, t) in mix.transitions.enumerated() {
        let from = max(0, t.begins - 8 * t.barSeconds), to = min(mix.length, t.end + 8 * t.barSeconds)
        let name = String(format: "%02d %@ → %@.wav", i + 1, SongTitle.of(tracks[t.from].url), SongTitle.of(tracks[t.to].url))
            .replacingOccurrences(of: "/", with: "-")
        let url = outDir.appendingPathComponent(name)
        try Exporter.render(snapshot: snapshot, range: Int(from * sr)..<Int(to * sr), tail: 0, to: url) { _ in }
        print(String(format: "%@  %@ %d bars", name, t.edit.preset.displayName, t.edit.bars))
    }
}
print("rendered in \(seconds(rendered))")
