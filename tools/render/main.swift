import Foundation
import Accelerate

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
    case "--fidelity", "--exact", "--stretch", "--moves", "--seams", "--report", "--steps", "-v", "--levels", "--renditions", "--stretch-time", "--upgrade-vox", "--upgrade-bass", "--aac-peaks", "--limiter", "--tempos", "--order-only", "--scores", "--measures", "--twins", "--prune-dry", "--prune-now", "--dry", "--as-listed", "--energy", "--club", "--vocals", "--grids", "--shifts", "--word-times", "--breaths", "--clicks", "--parts", "--hooks", "--hook-first": break
    case "--dump-vocals", "--models", "--vocal-step", "--breaths-at", "--phone-mix", "--title", "--bitrate": _ = args.removeFirst()
    case "--order": ordered = true
    case "--detail", "--shakes", "--cut-cost", "--clash-cost", "--arc", "--kick", "--rot", "--exit-back", "--alone-wait", "--under-cap", "--cut-scale", "--hole-scale", "--busy-scale", "--switch-lead", "--drop-penalty", "--opener-weight", "--warm-up", "--relearn": _ = args.removeFirst()
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
func directoryBytes(at root: URL, key: URLResourceKey) -> Int {
    guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [key]) else { return 0 }
    var total = 0
    while let f = en.nextObject() as? URL {
        let v = try? f.resourceValues(forKeys: [key])
        total += (key == .totalFileAllocatedSizeKey ? v?.totalFileAllocatedSize : v?.fileSize) ?? 0
    }
    return total
}

if CommandLine.arguments.contains("--prune-dry") || CommandLine.arguments.contains("--prune-now") {
    // What the app's launch would clear from the cache (nothing is deleted),
    // or, with --prune-now, every folder of a song that's neither in the
    // set nor in the library, however recently used (deleted).
    let now = CommandLine.arguments.contains("--prune-now")
    let paths = UserDefaults(suiteName: "com.nikolausmarek.Passable")?.stringArray(forKey: "setTracks") ?? []
    let keeping = paths.map { URL(fileURLWithPath: $0) } + MusicTools.libraryFiles()
    let gone = StemCache.prune(keeping: keeping, dryRun: true, days: now ? 0 : StemCache.unusedDays)
    var bytes = 0
    for dir in gone {
        bytes += directoryBytes(at: dir, key: .fileSizeKey)
    }
    let kept = Set(keeping.compactMap { try? StemCache.folder(for: $0).lastPathComponent })
    print("keeping \(keeping.count) songs' folders (\(kept.count) found); would clear \(gone.count) folders, \(bytes / 1_000_000_000) GB")
    print("set songs whose folder would go: \(paths.filter { p in gone.contains { (try? StemCache.folder(for: URL(fileURLWithPath: p)).lastPathComponent) == $0.lastPathComponent } }.count)")
    if now, !CommandLine.arguments.contains("--dry") {
        for dir in gone { try? FileManager.default.removeItem(at: dir) }
        print("cleared \(gone.count) folders")
    }
    exit(0)
}
guard songs.count >= 2 else { fputs("need at least two songs\n", stderr); exit(2) }

func seconds(_ since: Date) -> String { String(format: "%.1f s", Date().timeIntervalSince(since)) }

if let k = CommandLine.arguments.firstIndex(of: "--cut-cost") { MixMath.cutCost = Double(CommandLine.arguments[k + 1])! }
if let k = CommandLine.arguments.firstIndex(of: "--clash-cost") { MixMath.clashCost = Double(CommandLine.arguments[k + 1])! }
if let k = CommandLine.arguments.firstIndex(of: "--rot") { SetOrdering.rotationsSettled = Int(CommandLine.arguments[k + 1])! }
if let k = CommandLine.arguments.firstIndex(of: "--kick") { SetOrdering.kickSpan = Int(CommandLine.arguments[k + 1])! }
if let k = CommandLine.arguments.firstIndex(of: "--arc") { SetOrdering.arcPenalty = Double(CommandLine.arguments[k + 1])! }
if let k = CommandLine.arguments.firstIndex(of: "--vocal-step") { VocalSeparator.step = Int(CommandLine.arguments[k + 1])! }
if let k = CommandLine.arguments.firstIndex(of: "--exit-back") { AutoPlacement.exitBack = Double(CommandLine.arguments[k + 1])! }
if let k = CommandLine.arguments.firstIndex(of: "--alone-wait") { AutoPlacement.aloneWait = Double(CommandLine.arguments[k + 1])! }
if let k = CommandLine.arguments.firstIndex(of: "--under-cap") { AutoPlacement.underCap = Double(CommandLine.arguments[k + 1])! }
if let k = CommandLine.arguments.firstIndex(of: "--cut-scale") { AutoPlacement.cutScale = Float(CommandLine.arguments[k + 1])! }
if let k = CommandLine.arguments.firstIndex(of: "--hole-scale") { AutoPlacement.holeScale = Float(CommandLine.arguments[k + 1])! }
if let k = CommandLine.arguments.firstIndex(of: "--busy-scale") { AutoPlacement.busyScale = Float(CommandLine.arguments[k + 1])! }
if let k = CommandLine.arguments.firstIndex(of: "--switch-lead") { TransitionBuilder.switchLead = Double(CommandLine.arguments[k + 1])! }
if let k = CommandLine.arguments.firstIndex(of: "--drop-penalty") { SetOrdering.dropPenalty = Double(CommandLine.arguments[k + 1])! }
if let k = CommandLine.arguments.firstIndex(of: "--opener-weight") { SetOrdering.openerWeight = Double(CommandLine.arguments[k + 1])! }
if CommandLine.arguments.contains("--hook-first") { TrackStructure.hookAtFirstBar = true }
if let k = CommandLine.arguments.firstIndex(of: "--warm-up") { SetOrdering.warmUpShare = Double(CommandLine.arguments[k + 1])! }

// Songs not separated yet need the models: the installed app's.
ModelLocation.directory = URL(fileURLWithPath: CommandLine.arguments.firstIndex(of: "--models").map { CommandLine.arguments[$0 + 1] }
                                 ?? "/Applications/Passable.app/Contents/Resources")
TrackProcessor.renditionFolder = ProcessInfo.processInfo.environment["PASSABLE_RENDITIONS"] ?? "render-matched"
SetMix.Learned.isReadOnly = true
// The tool's renditions are for runs of the same set close together: a
// day after it last made one for a song, they go (they were 39 GB of a
// 134 GB cache, never read by the app).
do {
    let fm = FileManager.default, dayAgo = Date().addingTimeInterval(-86_400)
    for song in (try? fm.contentsOfDirectory(at: StemCache.root, includingPropertiesForKeys: nil)) ?? [] {
        for folder in [song, song.appendingPathComponent(Steadying.folderName)] {
            let renditions = folder.appendingPathComponent(TrackProcessor.renditionFolder)
            let made = ((try? fm.contentsOfDirectory(at: renditions, includingPropertiesForKeys: nil)) ?? [renditions])
                .compactMap { (try? fm.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date }.max()
            if let made, made < dayAgo { try? fm.removeItem(at: renditions) }
        }
    }
}

let clock = Date()
let processor = TrackProcessor()
var tracks: [(url: URL, loaded: TrackProcessor.Loaded)] = []
for url in songs {
    let loaded = try await withCheckedThrowingContinuation { (c: CheckedContinuation<TrackProcessor.Loaded, Error>) in
        processor.load(url, ticket: .init(), progress: { _ in }) { c.resume(with: $0) }
    }
    tracks.append((url, loaded))
    if Date().timeIntervalSince(clock) > 5 { print("  \(tracks.count)/\(songs.count) \(SongTitle.of(url)) (\(seconds(clock)))") }
}
print("loaded \(tracks.count) songs in \(seconds(clock))")

// Copies of songs (PASSABLE_CACHE) given a cleaner voice or bass, to measure
// the planner against them: --upgrade-vox mixes ViperX's BS-RoFormer voice
// (VoxRoformer in --models) half into the voice, --upgrade-bass htdemucs_ft's
// bass (HTDemucsBass) 30 % into the bass; the stems are made to add up again
// and measured again on the next load. Never the app's own cache.
if CommandLine.arguments.contains("--upgrade-vox") || CommandLine.arguments.contains("--upgrade-bass") {
    guard ProcessInfo.processInfo.environment["PASSABLE_CACHE"] != nil else {
        print("--upgrade-vox/--upgrade-bass work on copies only: set PASSABLE_CACHE"); exit(1)
    }
    let vox = CommandLine.arguments.contains("--upgrade-vox")
    let roformer = vox ? try StemRoformer(name: "VoxRoformer") : nil
    let ft = vox ? nil : try StemSeparator(model: ModelLocation.fallback(named: "HTDemucsBass"))
    for t in tracks {
        let dir = try StemCache.directory(for: t.url)
        let marker = dir.appendingPathComponent(vox ? "vocals.vox.1" : "bass.ft.1")
        if FileManager.default.fileExists(atPath: marker.path) { continue }
        let mix = try AudioIO.loadStereo(url: t.url)
        var stems = try StemCache.loadStems(from: dir).mapValues { $0.copyStereo() }
        guard var voice = stems[.vocals], var bass = stems[.bass] else { continue }
        func blend(_ a: inout StereoBuffer, _ b: StereoBuffer, share: Float) {
            guard a.count == b.count else { return }
            var keep = 1 - share, s = share
            let n = vDSP_Length(a.count)
            vDSP_vsmul(a.left, 1, &keep, &a.left, 1, n); vDSP_vsma(b.left, 1, &s, a.left, 1, &a.left, 1, n)
            vDSP_vsmul(a.right, 1, &keep, &a.right, 1, n); vDSP_vsma(b.right, 1, &s, a.right, 1, &a.right, 1, n)
        }
        if let roformer, let other = try roformer.separateNamed(mix, progress: { _ in }).first(where: { $0.key.lowercased() == "vocals" })?.value {
            blend(&voice, other, share: 0.5)
            stems[.vocals] = voice
        }
        if let ft, let other = try ft.separate(mix, progress: { _ in })[.bass] {
            blend(&bass, other, share: 0.3)
            stems[.bass] = bass
        }
        var rest = mix
        vDSP_vsub(voice.left, 1, mix.left, 1, &rest.left, 1, vDSP_Length(mix.count))
        vDSP_vsub(voice.right, 1, mix.right, 1, &rest.right, 1, vDSP_Length(mix.count))
        var others = stems.filter { $0.key != .vocals }
        StemResidual.redistribute(mix: rest, stems: &others)
        others[.vocals] = voice
        FileManager.default.createFile(atPath: marker.path, contents: Data())
        for (kind, buffer) in others { try StemAudio.save(buffer, directory: dir, name: kind.rawValue) }
        StemCache.forgetDerivedAudio(in: dir)
        for steady in [dir.appendingPathComponent(Steadying.folderName)] { try? FileManager.default.removeItem(at: steady) }
        // (Audio derived from the old stems: a mashup's guest voice.)
        for f in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where f.hasPrefix("guest-") {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(f))
        }
        if var analysis = StemCache.loadAnalysis(from: dir) {
            analysis.structure?.stemLevel = nil
            if vox { analysis.structure?.vocalBreaths = nil }
            StemCache.saveAnalysis(analysis, to: dir)
        }
        print("upgraded \(SongTitle.of(t.url))")
    }
    exit(0)
}
if let k = CommandLine.arguments.firstIndex(of: "--dump-vocals") {
    // Each song's vocal stem as Passable separates it, raw 32-bit floats
    // per channel, in a folder named after the song's own folder: what
    // tools/convert-roformer/evaluate.py scores against true stems.
    let out = URL(fileURLWithPath: CommandLine.arguments[k + 1])
    for t in tracks {
        guard let v = t.loaded.stems[.vocals] else { continue }
        let dir = out.appendingPathComponent(t.url.deletingLastPathComponent().lastPathComponent)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, ch) in [("L", v.left), ("R", v.right)] {
            let data = Data(bytes: ch.pointer, count: v.count * MemoryLayout<Float>.size)
            try data.write(to: dir.appendingPathComponent("vocals.\(name).f32"))
        }
    }
    exit(0)
}
// As the app does: a second copy of a song in the set plays once.
do {
    var kept: [(url: URL, loaded: TrackProcessor.Loaded)] = []
    for t in tracks {
        if let twin = kept.first(where: { SetOrdering.sameRecording($0.loaded.analysis, t.loaded.analysis) }) {
            print("left out \(SongTitle.of(t.url)): the same song as \(SongTitle.of(twin.url))")
        } else {
            kept.append(t)
        }
    }
    tracks = kept
}
if CommandLine.arguments.contains("--twins") {
    // Pairs of songs that may be the same recording: tempo, key and the
    // song's chord colour over its whole length.
    let a = tracks.map(\.loaded.analysis)
    func profile(_ t: TrackAnalysis) -> [Float] {
        guard let c = t.structure?.harmonyChroma ?? t.structure?.barChroma, !c.isEmpty else { return [] }
        var p = [Float](repeating: 0, count: 12)
        for bar in c { for k in 0..<min(12, bar.count) { p[k] += bar[k] } }
        let norm = sqrt(p.reduce(0) { $0 + $1 * $1 })
        return norm > 0 ? p.map { $0 / norm } : p
    }
    let profiles = a.map(profile)
    var rows: [(Double, String)] = []
    for i in a.indices { for j in a.indices where j > i {
        guard profiles[i].count == 12, profiles[j].count == 12 else { continue }
        let sim = Double(zip(profiles[i], profiles[j]).reduce(0) { $0 + $1.0 * $1.1 })
        let tempo = abs(a[i].grid.bpm / a[j].grid.bpm - 1)
        rows.append((sim, String(format: "chroma %.4f tempo %.1f%% key %@/%@ length %.0f/%.0f s  %@ | %@", sim, tempo * 100,
                                 a[i].key.camelotCode, a[j].key.camelotCode, a[i].duration, a[j].duration,
                                 SongTitle.of(tracks[i].url), SongTitle.of(tracks[j].url))))
    } }
    for r in rows.sorted(by: { $0.0 > $1.0 }).prefix(12) { print(r.1) }
    exit(0)
}

if CommandLine.arguments.contains("--grids") {
    // How far the beats a trained tracker hears in each song, as it's
    // loaded (a drummer's song steadied), lie off its grid: 90th
    // percentile and median, ms. Steady: within a frame or two (20 ms).
    for t in tracks {
        let stems = t.loaded.stems.values
        let n = stems.map(\.count).max() ?? 0
        var mono = [Float](repeating: 0, count: n)
        for s in stems { for k in 0..<s.count { mono[k] += 0.25 * (s.left.pointer[k] + s.right.pointer[k]) } }
        guard let tracker = BeatTracker.shared, let heard = try? tracker.track(mono) else { print("no tracker"); exit(1) }
        let g = t.loaded.analysis.grid
        let off = heard.beats.map { x in abs(x - g.snapped(x, division: 1)) * 1000 }.sorted()
        print(String(format: "%6.1f BPM%@  off grid p50 %4.0f ms  p90 %4.0f ms  %@", g.bpm, g.isSteady ? " " : "~",
                     off[off.count / 2], off[off.count * 9 / 10], SongTitle.of(t.url)))
    }
    exit(0)
}
if CommandLine.arguments.contains("--energy") {
    // Each song's `SetOrdering.energy` and what it's made of: share of bars
    // with drums and bass both going (activity > 0.5), each alone, tempo.
    for t in tracks.sorted(by: { SetOrdering.energy($0.loaded.analysis) < SetOrdering.energy($1.loaded.analysis) }) {
        let a = t.loaded.analysis
        guard let s = a.structure else { continue }
        let d = s.activity(.drums), b = s.activity(.bass), n = Double(max(1, min(d.count, b.count)))
        func share(_ x: [Double]) -> Double { Double(x.filter { $0 > 0.5 }.count) / Double(max(1, x.count)) }
        let both = Double((0..<Int(n)).filter { d[$0] > 0.5 && b[$0] > 0.5 }.count) / n
        print(String(format: "%.2f  both %.2f drums %.2f bass %.2f  %5.1f BPM  %@", SetOrdering.energy(a), both,
                     share(d.map(Double.init)), share(b.map(Double.init)), a.grid.bpm, SongTitle.of(t.url)))
    }
    exit(0)
}
if CommandLine.arguments.contains("--measures") {
    // The per-bar measures placement scores with, largest value per song:
    // each should stay within about 0…1.
    for t in tracks {
        guard let s = t.loaded.analysis.structure else { continue }
        let b = s.boundaryStrength()
        let hooks = (0..<s.loudness.count).map { s.hook($0) }
        let act = StemKind.allCases.map { k in String(format: "%@ %.1f", k.rawValue, s.activity(k).max() ?? 0) }
        print(String(format: "boundary %.2f hook %.2f  %@  %@", b.max() ?? 0, hooks.max() ?? 0,
                     act.joined(separator: " "), SongTitle.of(t.url)))
    }
    exit(0)
}

if CommandLine.arguments.contains("--scores") {
    // Every pair planned as ordering prices it: the spread of placement
    // scores, and the pairs at the ends.
    let a = tracks.map(\.loaded.analysis)
    let hits = BeatAlign.attacks(of: tracks.map(\.loaded))
    let n = a.count
    var rows = [(score: Float, cost: Double, preset: String, i: Int, j: Int)](repeating: (0, 0, "", 0, 0), count: n * n)
    rows.withUnsafeMutableBufferPointer { out in
        let out = out
        DispatchQueue.concurrentPerform(iterations: n * n) { k in
            let i = k / n, j = k % n
            guard i != j else { return }
            let soloFrom = a[i].grid.barCount(duration: a[i].duration) / 4
            let plan = PairPlan.make(a: a[i], b: a[j], entryRange: (soloFrom + SetBuilder.minimumSoloBars(a[i].grid))...Int.max,
                                     soloFrom: soloFrom, drums: hits[i].flatMap { x in hits[j].map { (a: x, b: $0) } }, loops: false)
            out[k] = (plan.placement.score, plan.cost(a: a[i], b: a[j]), plan.preset.name(bars: plan.bars), i, j)
        }
    }
    let all = rows.filter { $0.i != $0.j }.sorted { $0.score < $1.score }
    func pct(_ p: Double) -> Float { all[Int(Double(all.count - 1) * p)].score }
    print(String(format: "placement score: min %.1f, 1%% %.1f, 10%% %.1f, median %.1f, 90%% %.1f, 99%% %.1f, max %.1f",
                 all.first!.score, pct(0.01), pct(0.1), pct(0.5), pct(0.9), pct(0.99), all.last!.score))
    for r in all.suffix(8).reversed() + all.prefix(4) {
        print(String(format: "  score %6.1f cost %6.2f %@  %@ → %@", r.score, r.cost, r.preset, SongTitle.of(tracks[r.i].url), SongTitle.of(tracks[r.j].url)))
    }
    exit(0)
}

if CommandLine.arguments.contains("--tempos") {
    // Each song's tempo and key, and how many others it can share a beat
    // with (within `maxStretch`, half/double time counted) and a key with.
    let a = tracks.map(\.loaded.analysis)
    for (i, t) in a.enumerated().sorted(by: { $0.1.grid.bpm < $1.1.grid.bpm }) {
        let beat = a.indices.filter { $0 != i && MixMath.preset(t, a[$0]) != .echoOut }
        let key = beat.filter { !MixMath.keysClash(t.key, a[$0].key) }
        print(String(format: "%6.1f BPM %@ %@  beat with %2d, beat+key with %2d  %@", t.grid.bpm, t.key.camelotCode,
                     t.grid.isSteady ? " " : "~", beat.count, key.count, SongTitle.of(tracks[i].url)))
    }
    exit(0)
}
if ordered {
    // As the app's Auto-Order does it.
    let analyses = tracks.map(\.loaded.analysis)
    let t0 = Date()
    let hits = BeatAlign.attacks(of: tracks.map(\.loaded))
    let t1 = Date()
    let costs = SetOrdering.costMatrix(analyses, drums: hits, remembered: true, urls: tracks.map(\.url))
    let t2 = Date()
    let washOuts = SetOrdering.washOuts(analyses), energies = analyses.map(SetOrdering.energy)
    let shakes = CommandLine.arguments.firstIndex(of: "--shakes").map { Int(CommandLine.arguments[$0 + 1])! }
    // --as-listed: price the list's own order instead of searching one.
    let order = CommandLine.arguments.contains("--as-listed") ? Array(analyses.indices)
        : SetOrdering.order(costs, washOuts: washOuts, energies: energies, shakes: shakes)
    print(String(format: "drum hits %.1f s, prices %.1f s, search %.1f s", t1.timeIntervalSince(t0), t2.timeIntervalSince(t1), Date().timeIntervalSince(t2)))
    let pairs = zip(order, order.dropFirst())
    print(String(format: "order cost %.2f (transitions %.2f, Wash Outs/cuts %d, clashing keys %d)",
                 SetOrdering.total(order, costs, washOuts, energies), pairs.reduce(0) { $0 + costs[$1.0][$1.1] },
                 pairs.filter { washOuts[$0][$1] }.count,
                 pairs.filter { MixMath.keysClash(analyses[$0].key, analyses[$1].key) }.count))
    if CommandLine.arguments.contains("-v") {
        let arc = SetOrdering.EnergyArc(energies)
        for (k, i) in order.enumerated() {
            let next = k + 1 < order.count ? order[k + 1] : nil
            print(String(format: "%2d  energy %.2f (off arc cost %.2f)  → next %+.2f%@  %@", k + 1, energies[i],
                         arc.cost(i, place: k, count: order.count),
                         next.map { costs[i][$0] } ?? 0, next.map { washOuts[i][$0] ? " CUT" : "" } ?? "", SongTitle.of(tracks[i].url)))
        }
    }
    tracks = order.map { tracks[$0] }
    // --relearn N: built, what the build learnt from the audio priced in,
    // and ordered again, up to N times (until the order stays).
    if let k = CommandLine.arguments.firstIndex(of: "--relearn") {
        for round in 0..<Int(CommandLine.arguments[k + 1])! {
            let before = tracks.map(\.url)
            let built = try await SetBuilder.build(tracks, moves: ProcessInfo.processInfo.environment["PASSABLE_MOVES"].flatMap(Int.init).map(AutoMoves.init(rawValue:)) ?? .all, processor: processor) { _ in }
            _ = built
            let analyses = tracks.map(\.loaded.analysis)
            let costs = SetOrdering.costMatrix(analyses, drums: BeatAlign.attacks(of: tracks.map(\.loaded)), remembered: true, urls: tracks.map(\.url))
            let washOuts = SetOrdering.washOuts(analyses), energies = analyses.map(SetOrdering.energy)
            let order = SetOrdering.order(costs, washOuts: washOuts, energies: energies, shakes: shakes)
            let l = SetMix.Learned.session
            print(String(format: "relearn %d: learnt %d unlocked, %d clashed, %d locked; order cost %.2f", round + 1, l.unlocked.count, l.clashed.count, l.locked.count,
                         SetOrdering.total(order, costs, washOuts, energies)))
            tracks = order.map { tracks[$0] }
            if tracks.map(\.url) == before { break }
        }
    }
    do {
        // The order as a dance floor gets it (see --club; no audio needed):
        // energy drops over 0.2, tempo jumps over 6 % and over 10 %, the
        // opener's rank among the set's energies, and the distance from
        // the arc.
        let e = tracks.map { SetOrdering.energy($0.loaded.analysis) }
        let bpm = tracks.map { $0.loaded.analysis.grid.bpm }
        let drops = (1..<e.count).filter { e[$0 - 1] - e[$0] > 0.2 }.count
        let st = (1..<bpm.count).map { MixMath.stretch(MixMath.rate(a: bpm[$0 - 1], b: bpm[$0])) }
        let rank = Double(e.sorted().firstIndex(of: e[0]) ?? 0) / Double(max(1, e.count - 1))
        let arc = SetOrdering.EnergyArc(e)
        let off = (e.indices.map { arc.cost($0, place: $0, count: e.count) / (arc.weight * SetOrdering.warmUp(place: $0, count: e.count)) }
            .reduce(0, +) / Double(e.count)).squareRoot()
        print(String(format: "ORDER-CLUB drops %d, jumps >6%% %d, >10%% %d, opener energy %.2f (rank %.0f %%), off the arc %.3f",
                     drops, st.filter { $0 > 0.06 }.count, st.filter { $0 > 0.10 }.count, e[0], rank * 100, off))
    }
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    try? tracks.map(\.url.path).joined(separator: "\n").write(to: outDir.appendingPathComponent("order.txt"), atomically: true, encoding: .utf8)
    if CommandLine.arguments.contains("--order-only") { exit(0) }
    print("ordered in \(seconds(clock))")
}
if CommandLine.arguments.contains("--breaths") {
    // Each song's breaths (see `TrackStructure.breaths`): how many, how
    // long, and how many fall inside a sung line by the recogniser
    // against at its edges (within a beat of a line's start or end).
    for t in tracks {
        guard let v = t.loaded.stems[.vocals] else { continue }
        let b = TrackStructure.breaths(v)
        let spans = stride(from: 0, to: b.count, by: 2).map { (b[$0], b[$0 + 1]) }.filter { $0.1 - $0.0 < 1 }
        let lines = t.loaded.analysis.structure?.vocalLines ?? []
        let beat = t.loaded.analysis.grid.barSeconds / 4
        let edges = lines.flatMap { [$0.start, $0.end] + $0.breaks }
        let atEdge = spans.filter { s in edges.contains { abs($0 - s.0) < beat || abs($0 - s.1) < beat } }.count
        let inLine = spans.filter { s in lines.contains { $0.start + beat < s.0 && s.1 < $0.end - beat } }.count
        let sung = lines.reduce(0.0) { $0 + $1.end - $1.start }
        let lengths = spans.map { $0.1 - $0.0 }.sorted()
        print(String(format: "%4d short breaths (%.1f per sung minute), median %3.0f ms, at a line's edge %3d, inside a line %3d  %@",
                     spans.count, sung > 0 ? Double(spans.count) / sung * 60 : 0, lengths.isEmpty ? 0 : lengths[lengths.count / 2] * 1000,
                     atEdge, inLine, SongTitle.of(t.url)))
        // (On the grid: the song's own sixteenth levels inside its longer
        // breaths, against what it sings at.)
        if let st = t.loaded.analysis.structure, let spans = st.breathSpans, let lv = st.vocalSixteenthLevel, let ref = st.vocalReference {
            var inside: [Float] = [], shifted: [Float] = []
            for i in stride(from: 0, to: spans.count - 1, by: 2) where spans[i + 1] - spans[i] >= 2 && spans[i + 1] - spans[i] < 16 {
                let a = Int(spans[i].rounded(.up)), b = Int(spans[i + 1].rounded(.down))
                for k in a..<max(a, b) where k >= 0 && k < lv.count { inside.append(lv[k] - ref) }
            }
            inside.sort()
            print(String(format: "     grid check: %d sixteenths inside breaths, median %.0f dB vs its level, %.0f%% above -16", inside.count,
                         inside.isEmpty ? 0 : inside[inside.count / 2], inside.isEmpty ? 0 : 100 * Double(inside.filter { $0 > -16 }.count) / Double(inside.count)))
            _ = shifted
        }
        if let k = CommandLine.arguments.firstIndex(of: "--breaths-at"), let at = Double(CommandLine.arguments[k + 1]) {
            print("  near \(at): " + spans.filter { abs($0.0 - at) < 3 }.map { String(format: "%.3f–%.3f", $0.0, $0.1) }.joined(separator: "  "))
        }
    }
    exit(0)
}
if CommandLine.arguments.contains("--word-times") {
    // Where the recogniser puts a word's start and end against where the
    // vocal stem really rises and falls there: the sharpest 10 ms rise
    // (fall) within 250 ms of it, of 8 dB at least. Median and quartiles
    // of (audio - recogniser), ms, per song and over the set.
    func frames(_ s: StemAudio) -> [Float] {
        let len = Int(0.005 * AudioIO.sampleRate)
        return (0..<(s.count / len)).map { f in
            var l: Float = 0, r: Float = 0
            vDSP_measqv(s.left.pointer + f * len, 1, &l, vDSP_Length(len))
            vDSP_measqv(s.right.pointer + f * len, 1, &r, vDSP_Length(len))
            return 10 * log10(max((l + r) / 2, 1e-10))
        }
    }
    func quartiles(_ v: [Double]) -> String {
        guard !v.isEmpty else { return "-" }
        let s = v.sorted()
        return String(format: "%+4.0f [%+4.0f %+4.0f] n=%d", s[s.count / 2], s[s.count / 4], s[s.count * 3 / 4], s.count)
    }
    var allStarts: [Double] = [], allEnds: [Double] = [], allLines: [Double] = []
    for t in tracks {
        guard let v = t.loaded.stems[.vocals], let lines = t.loaded.analysis.structure?.vocalLines else { continue }
        let f = frames(v)
        func mean(_ a: Int, _ b: Int) -> Float { a < 0 || b > f.count || b <= a ? -100 : f[a..<b].reduce(0, +) / Float(b - a) }
        func edge(_ time: Double, rising: Bool) -> Double? {
            let c = Int(time / 0.005)
            var best: (i: Int, d: Float)?
            for i in (c - 50)...(c + 50) {
                let d = rising ? mean(i, i + 2) - mean(i - 2, i) : mean(i - 2, i) - mean(i, i + 2)
                if d > best?.d ?? 8 { best = (i, d) }
            }
            return best.map { (Double($0.i) * 0.005 - time) * 1000 }
        }
        var starts: [Double] = [], ends: [Double] = [], lineStarts: [Double] = []
        for line in lines {
            if let d = edge(line.start, rising: true) { lineStarts.append(d) }
            for w in stride(from: 0, to: line.wordTimes.count - 1, by: 2) {
                if let d = edge(line.wordTimes[w], rising: true) { starts.append(d) }
                if let d = edge(line.wordTimes[w + 1], rising: false) { ends.append(d) }
            }
        }
        allStarts += starts; allEnds += ends; allLines += lineStarts
        print("word starts \(quartiles(starts))  ends \(quartiles(ends))  lines \(quartiles(lineStarts))  \(SongTitle.of(t.url))")
    }
    print("ALL word starts \(quartiles(allStarts))  ends \(quartiles(allEnds))  line starts \(quartiles(allLines))")
    exit(0)
}
let built = Date()
// (PASSABLE_MOVES: which automatic moves are allowed, as `AutoMoves` bits.)
let allowedMoves = ProcessInfo.processInfo.environment["PASSABLE_MOVES"].flatMap(Int.init).map(AutoMoves.init(rawValue:)) ?? .all
let mix = try await SetBuilder.build(tracks, moves: allowedMoves, processor: processor) { _ in }
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
    barLevels(from: from, bars: bars, barSeconds: barSeconds, of: mix.snapshot(masterGain: 1, including: including))
}

/// The same of a snapshot of any mix (another mix's, or one with its
/// automation cleared).
func barLevels(from: Double, bars: Int, barSeconds: Double, of snapshot: MixSnapshot,
               band: (low: Double, high: Double) = (150, 16_000)) -> [Double] {
    let n = 4096, fft = RealFFT(size: n)
    let window = (0..<n).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(n))) }
    let lo = max(1, Int(band.low / sr * Double(n))), hi = Int(band.high / sr * Double(n))
    let renderer = MixRenderer(snapshot: snapshot)
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
    print(String(format: "%@ → %@  %@ %d bars%@, switch %.0f, voice out %@ in %@", SongTitle.of(mix.tracks[t.from].url),
                 SongTitle.of(mix.tracks[t.to].url), t.edit.preset.displayName, t.edit.bars,
                 t.plan.placement.loopBars > 0 ? String(format: " (A's beat looped, %d bars)", t.plan.placement.loopBars) : "",
                 TransitionBuilder.switchBar(t.edit.preset, bars: t.edit.bars, lowSwap: t.plan.placement.lowSwap),
                 t.vocalOut.map { String(format: "%.1f", ($0 - t.start) / t.barSeconds) } ?? "-",
                 t.vocalIn.map { String(format: "%.1f", ($0 - t.start) / t.barSeconds) } ?? "-"))
    print(String(format: "planned: voice in %@ (handoff %d), grooves lock %@, together %d, score %.2f  %@",
                 t.plan.placement.expectedVocalIn.map { String(format: "%.1f", $0) } ?? "-", t.plan.placement.vocalHandoff,
                 t.plan.drumsLock ? "yes" : "no", t.plan.placement.together ?? -1, t.plan.placement.score, t.plan.placement.reason))
    print("bar       " + (0..<n).map { String(format: "%4d", $0 - 4 + Int(((t.begins - t.start) / t.barSeconds).rounded())) }.joined())
    row("mix") { _, _ in true }
    for (side, i) in [("A", t.from), ("B", t.to)] {
        row(side) { k, _ in k == i }
        for stem in StemKind.laneOrder { row("  \(side) \(stem.rawValue)") { k, s in k == i && s == stem } }
    }
    // (Each song as it would play untouched there: its own breaks and
    // builds, against what the blend did to it.)
    var raw = mix
    for k in raw.tracks.indices { raw.tracks[k].envelopes = [:]; raw.tracks[k].rolls = [] }
    for (side, i) in [("A", t.from), ("B", t.to)] {
        for stem in [StemKind.drums, .vocals] {
            let v = barLevels(from: from, bars: n, barSeconds: t.barSeconds, of: raw.snapshot(masterGain: 1) { k, s in k == i && s == stem })
            print("  \(side) own \(stem.rawValue)".padding(toLength: 10, withPad: " ", startingAt: 0) + v.map { $0 < -90 ? "   ." : String(format: "%4.0f", $0) }.joined())
        }
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

if CommandLine.arguments.contains("--aac-peaks") {
    // The set as the phone gets it (AAC 256 kbps), decoded again: samples
    // over full scale are clipped on playback.
    let from = 0.0, seconds = min(mix.length, 900)
    let url = outDir.appendingPathComponent("peaks.m4a")
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    try Exporter.render(snapshot: snapshot, range: Int(from * sr)..<Int((from + seconds) * sr), tail: 0, to: url) { _ in }
    let back = try AudioIO.loadStereo(url: url)
    var over = 0, top: Float = 0
    for k in 0..<back.count {
        let p = max(abs(back.left[k]), abs(back.right[k]))
        top = max(top, p)
        if p > 1 { over += 1 }
    }
    print(String(format: "AAC of %.0f s: peak %.2f dBFS, %d samples over full scale", seconds, 20 * log10(Double(top)), over))
    exit(0)
}

if CommandLine.arguments.contains("--stretch-time") {
    // What each tempo-matched copy costs to make, stem by stem as the app
    // makes it (all four at once), and why: key shift or not.
    var total = 0.0
    for t in mix.tracks where !t.map.isIdentity || (t.matched?.plan.semitones ?? 0) != 0 {
        guard let m = t.matched else { continue }
        let start = Date()
        let kinds = StemKind.allCases
        DispatchQueue.concurrentPerform(iterations: kinds.count) { i in
            let kind = kinds[i]
            _ = TimeStretcher.process(t.loaded.stems[kind]!.copyStereo(), map: m.plan.map,
                                      semitones: kind == .drums ? 0 : m.plan.semitones, percussive: kind == .drums,
                                      vocal: kind == .vocals, harmonicPercussive: kind == .other)
        }
        let s = Date().timeIntervalSince(start)
        total += s
        print(String(format: "%6.2f s  %+d st  exit %@  %@", s, m.plan.semitones, m.plan.map.hasExit ? "y" : "n", SongTitle.of(t.url)))
    }
    print(String(format: "stretching: %.1f s in all", total))
    exit(0)
}

if CommandLine.arguments.contains("--renditions") {
    // Every tempo-matched copy as saved, against the stretcher run again in
    // memory: they must be the same to the bit. And the room they take.
    var same = 0, differ = 0, shared = 0, bytes = 0, full = 0
    for t in mix.tracks {
        guard let m = t.matched, !t.map.isIdentity else { continue }
        for kind in StemKind.allCases {
            let fresh = TimeStretcher.process(t.loaded.stems[kind]!.copyStereo(), map: m.plan.map,
                                              semitones: kind == .drums ? 0 : m.plan.semitones, percussive: kind == .drums,
                                              vocal: kind == .vocals, harmonicPercussive: kind == .other)
            let saved = m.stems[kind]!
            let ok = fresh.count == saved.count && (0..<fresh.count).allSatisfy {
                fresh.left[$0].bitPattern == saved.left.pointer[$0].bitPattern && fresh.right[$0].bitPattern == saved.right.pointer[$0].bitPattern
            }
            if ok { same += 1 } else { differ += 1; print("DIFFERS: \(SongTitle.of(t.url)) \(kind.rawValue)") }
            full += 2 * fresh.count * 4
        }
        let dir = t.loaded.directory.appendingPathComponent(TrackProcessor.renditionFolder).appendingPathComponent(m.plan.cacheName)
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent("drums.layout").path) { shared += 1 }
        bytes += directoryBytes(at: dir, key: .totalFileAllocatedSizeKey)
    }
    print("renditions: \(same) stems identical, \(differ) differ; \(shared) songs share the song's file; on disk \(bytes / 1_000_000) MB of \(full / 1_000_000) MB written whole")
    exit(0)
}

if CommandLine.arguments.contains("--parts") {
    // Would separate guitar and piano let clashing melodies layer? For each
    // transition whose melodies clash: the stem model's guitar and piano of
    // each song (made once, kept under PASSABLE_PARTS), and the planner's
    // own test (`Harmony.clash`, `roughness`, `tolerance`) of A's melody
    // against B's with one part of either left out.
    let partsRoot = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PASSABLE_PARTS"] ?? "render-out/parts")
    let model = try StemRoformer()
    func memory(_ x: StereoBuffer) -> StemAudio {
        StemAudio(left: MappedChannel(samples: x.left), right: MappedChannel(samples: x.right))
    }
    func parts(_ k: Int) throws -> [String: StemAudio] {
        let t = mix.tracks[k]
        let dir = partsRoot.appendingPathComponent(t.loaded.directory.lastPathComponent)
        if !StemAudio.exists(directory: dir, name: "guitar") {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let song = try AudioIO.loadStereo(url: t.url)
            let named = try model.separateNamed(song, progress: { _ in })
            for name in ["guitar", "piano"] { try StemAudio.save(named[name]!, directory: dir, name: name) }
        }
        return ["guitar": try StemAudio.load(directory: dir, name: "guitar"),
                "piano": try StemAudio.load(directory: dir, name: "piano")]
    }
    /// `other` less a part, in memory.
    func without(_ other: StemAudio, _ part: StemAudio) -> StemAudio {
        let n = min(other.count, part.count)
        var x = StereoBuffer(count: n)
        vDSP_vsub(part.left.pointer, 1, other.left.pointer, 1, &x.left, 1, vDSP_Length(n))
        vDSP_vsub(part.right.pointer, 1, other.right.pointer, 1, &x.right, 1, vDSP_Length(n))
        return memory(x)
    }
    func rotated(_ c: [Float], _ semitones: Int) -> [Float] {
        (0..<12).map { c[((($0 - semitones) % 12) + 12) % 12] }
    }
    var clashing = 0, keysApart = 0, helped = 0, partHeard: [String: Int] = [:]
    for (i, t) in mix.transitions.enumerated() where t.melodiesClash && t.edit.preset != .echoOut {
        clashing += 1
        let ta = mix.tracks[t.from], tb = mix.tracks[t.to]
        let keyA = ta.loaded.analysis.key, keyB = tb.loaded.analysis.key.transposed(by: t.edit.semitones)
        let tolerance = Harmony.tolerance(keyA, keyB)
        let title = "\(SongTitle.of(ta.url)) → \(SongTitle.of(tb.url))"
        guard tolerance > -.infinity else {
            keysApart += 1
            print(String(format: "%02d keys %@ / %@ too far apart (any notes clash)  %@", i + 1, "\(keyA)", "\(keyB)", title))
            continue
        }
        let pa = try parts(t.from), pb = try parts(t.to)
        guard let otherA = ta.loaded.stems[.other], let otherB = tb.loaded.stems[.other] else { continue }
        let overlap = AutoPlacement.melodyOverlap(t.edit.preset, bars: t.edit.bars, lowSwap: t.plan.placement.lowSwap)
        // Source seconds of each song over master bars `bars` of the blend.
        func window(_ track: SetMix.Track, _ bars: Range<Int>) -> (Double, Double) {
            let from = t.start + Double(bars.lowerBound) * t.barSeconds, to = t.start + Double(bars.upperBound) * t.barSeconds
            let s = { (m: Double) in track.map.source((m - track.offset) * sr) / sr }
            return (s(from), s(to))
        }
        func fits(_ a: [StemAudio], _ b: [StemAudio]) -> (clash: Float, rough: Float)? {
            var worst: (Float, Float) = (0, 0)
            var any = false
            for (bars, withBassA) in [(overlap.before, true), (overlap.after, false)] where !bars.isEmpty {
                let (a0, a1) = window(ta, bars), (b0, b1) = window(tb, bars)
                let sa = a + (withBassA ? [ta.loaded.stems[.bass]].compactMap { $0 } : [])
                let sb = b + (withBassA ? [] : [tb.loaded.stems[.bass]].compactMap { $0 })
                guard let ca = Harmony.chroma(sa, offset: 0, from: a0, to: a1),
                      let cb = Harmony.chroma(sb, offset: 0, from: b0, to: b1) else { continue }
                let rb = rotated(cb, t.edit.semitones)
                worst = (max(worst.0, Harmony.clash(ca, rb)), max(worst.1, Harmony.roughness(ca, rb)))
                any = true
            }
            return any ? worst : nil
        }
        func ok(_ r: (clash: Float, rough: Float)?) -> Bool {
            r.map { $0.clash <= tolerance && $0.rough <= Harmony.roughTolerance + 0.02 } ?? true
        }
        let full = fits([otherA], [otherB])
        var fixes: [String] = []
        for (name, a, b) in [("A without guitar", [without(otherA, pa["guitar"]!)], [otherB]),
                             ("A without piano", [without(otherA, pa["piano"]!)], [otherB]),
                             ("B without guitar", [otherA], [without(otherB, pb["guitar"]!)]),
                             ("B without piano", [otherA], [without(otherB, pb["piano"]!)])] {
            if ok(fits(a, b)) { fixes.append(name) }
        }
        if !fixes.isEmpty { helped += 1; for f in fixes { partHeard[f, default: 0] += 1 } }
        print(String(format: "%02d clash %.3f rough %.3f (tolerance %.3f)%@  %@", i + 1, full?.clash ?? -1, full?.rough ?? -1,
                     tolerance, fixes.isEmpty ? "  no single part fixes it" : "  FITS: " + fixes.joined(separator: ", "), title))
    }
    print("PARTS \(mix.transitions.count) transitions, melodies clash in \(clashing): keys too far apart \(keysApart), "
          + "one part left out makes them fit \(helped) (" + partHeard.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ") + ")")
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
    var chopped = 0, total = 0, through = 0
    var leads: [Double] = []
    for (i, t) in mix.transitions.enumerated() {
        for (side, k) in [("A", t.from), ("B", t.to)] {
            let track = mix.tracks[k]
            for stem in StemKind.laneOrder {
                guard let env = track.envelopes[stem]?[LaneParameter.volume.rawValue], let audio = track.stems[stem] else { continue }
                let pts = env.points
                for j in pts.indices.dropFirst() {
                    let a = pts[j - 1], b = pts[j]
                    guard b.time - a.time < 0.02, abs(b.value - a.value) > 0.5,
                          a.time > t.begins - t.barSeconds, a.time < t.end + t.barSeconds else { continue }
                    let opening = b.value > a.value
                    // (A switch is a ramp of some milliseconds: an opening
                    // is judged where it's done, a closing where it starts.)
                    let at = opening ? b.time : a.time
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
                    // (Sounding all through the 40 ms looked at: a switch
                    // inside a held note or a sung vowel, not on a hit's
                    // attack. Whether that's heard is what --clicks
                    // measures; it's counted apart.)
                    let held = onset <= -40
                    let bad = !held && (opening ? (onset < 0 && best >= -2) : (onset < 0 && best >= 0))
                    if bad { chopped += 1 }
                    if held && (opening ? best >= -2 : best >= 0) { through += 1 }
                    if CommandLine.arguments.contains("-v") {
                        print(String(format: "%02d %@ %@ %@ at bar %.2f: hit peaks %+d ms, starts %+d ms%@", i + 1, side, stem.rawValue,
                                     opening ? "opens" : "closes", (at - t.start) / t.barSeconds, best, onset,
                                     bad ? "  CHOPPED" : held ? "  (through a held sound)" : ""))
                    }
                }
            }
        }
    }
    leads.sort()
    print(String(format: "steps %d, chopped %d, through a held sound %d; drum/bass hit onsets relative to the step: median %+.0f ms, 10th %+.0f, 90th %+.0f",
                 total, chopped, through, leads.isEmpty ? 0 : leads[leads.count / 2], leads.isEmpty ? 0 : leads[leads.count / 10],
                 leads.isEmpty ? 0 : leads[leads.count * 9 / 10]))
    exit(0)
}

if CommandLine.arguments.contains("--shifts") {
    // How far each transition takes the songs off their own tempo, and
    // which play off their key: a song everyone knows is heard wrong far
    // from either.
    var stretches: [Double] = [], shifted = 0
    for (i, t) in mix.transitions.enumerated() {
        let share = t.plan.shared
        let worst = max(MixMath.stretch(share.a), MixMath.stretch(share.b)) * 100
        if t.edit.preset != .echoOut { stretches.append(worst) }
        if t.edit.semitones != 0 { shifted += 1 }
        if worst > 4 || t.edit.semitones != 0 {
            print(String(format: "%02d %@ %d  A %+.1f%% B %+.1f%%  B %+d st  %@ → %@", i + 1, t.edit.preset.displayName, t.edit.bars,
                         (share.a - 1) * 100, (share.b - 1) * 100, t.edit.semitones,
                         SongTitle.of(mix.tracks[t.from].url), SongTitle.of(mix.tracks[t.to].url)))
        }
    }
    stretches.sort()
    print(String(format: "SHIFTS %d blends: stretch median %.1f%%, 90th %.1f%%, worst %.1f%%, over 4%%: %d | key shifted: %d",
                 stretches.count, stretches.isEmpty ? 0 : stretches[stretches.count / 2],
                 stretches.isEmpty ? 0 : stretches[stretches.count * 9 / 10], stretches.last ?? 0,
                 stretches.filter { $0 > 4 }.count, shifted))
    exit(0)
}
if CommandLine.arguments.contains("--vocals") {
    // How each pair of voices changed hands, as heard: beats both sang at
    // once, the longest silence between them, and where in each song's
    // words the cut fell (mid-sentence for A, mid-part for B).
    func slot(_ k: Int, _ t: Double) -> Int? {
        let track = mix.tracks[k]
        let own = track.map.source((t - track.offset) * sr) / sr
        return Int((track.loaded.analysis.grid.bars(at: own) * Double(VocalPhrasing.slots)).rounded())
    }
    var overlapSum = 0, gapWorst = 0, gaps4 = 0, aMid = 0, bMid = 0, both = 0, steps: [Double] = [], chopsOut = 0, chopsIn = 0, hardOut = 0, hardIn = 0
    for (i, t) in mix.transitions.enumerated() {
        guard let out = t.vocalOut, let inn = t.vocalIn else { continue }
        both += 1
        let beat = t.barSeconds / 4
        let from = min(out, inn) - 4 * t.barSeconds, beats = Int((abs(out - inn) + 8 * t.barSeconds) / beat)
        let la = barLevels(from: from, bars: beats, barSeconds: beat) { k, s in k == t.from && s == .vocals }
        let lb = barLevels(from: from, bars: beats, barSeconds: beat) { k, s in k == t.to && s == .vocals }
        func ref(_ l: [Double]) -> Double { let s = l.sorted(); return s[Int(Double(s.count - 1) * 0.9)] }
        let ra = ref(la), rb = ref(lb)
        // (And above `voiceFloor`: a channel open on a voice that isn't
        // singing yet has a loudest beat too, its noise, and read as
        // bars of both singing at once.)
        let voiceFloor = 25.0
        let ha = la.map { $0 > max(ra - 15, voiceFloor) }, hb = lb.map { $0 > max(rb - 15, voiceFloor) }
        let overlap = ha.indices.filter { ha[$0] && hb[$0] }.count
        // Longest run with neither voice heard where one of the songs,
        // played untouched, would be singing: a hole the transition made
        // (a song's own bars without words are no hole).
        var raw = mix
        for k in raw.tracks.indices { raw.tracks[k].envelopes = [:]; raw.tracks[k].rolls = [] }
        func untouched(_ k: Int) -> [Double] {
            barLevels(from: from, bars: beats, barSeconds: beat, of: raw.snapshot(masterGain: 1, including: { i, s in i == k && s == .vocals }))
        }
        let rawA = untouched(t.from), rawB = untouched(t.to)
        // (A would sing only while it plays: after the blend it's gone, and
        // its voice with it; B only once it has come in. Counted there, a
        // song's own bars on after A had left, B instrumental, read as a
        // hole: ten of 37 on a 117-song set.)
        let ua = rawA.indices.map { rawA[$0] > max(ra - 15, voiceFloor) && from + Double($0) * beat < t.end }
        let ub = rawB.indices.map { rawB[$0] > max(rb - 15, voiceFloor) && from + Double($0 + 1) * beat > t.begins }
        var gap = 0, run = 0, silencedA = 0, heldB = 0
        for k in 0..<beats {
            let hole = !ha[k] && !hb[k] && (ua[k] || ub[k])
            if hole { if ua[k] { silencedA += 1 }; if ub[k] { heldB += 1 } }
            run = hole ? run + 1 : 0; gap = max(gap, run)
        }
        // (Whose voice the hole is: A's taken out while it would sing on,
        // or B's held back while it would already sing; in beats, both
        // where both would.)
        let hole = gap <= 4 || !CommandLine.arguments.contains("-v") ? nil : String(format: "   hole: A silenced %d beats, B held %d beats (out bar %.1f, in bar %.1f of %d, %@, switch %.0f, loop %d, placement expected B at %.1f)", silencedA, heldB,
                         (out - t.start) / t.barSeconds, (inn - t.start) / t.barSeconds, t.edit.bars, t.edit.preset.displayName,
                         TransitionBuilder.switchBar(t.edit.preset, bars: t.edit.bars, lowSwap: t.plan.placement.lowSwap), t.loopBars, t.plan.placement.expectedVocalIn ?? -1)
        // (Inside on both neighbouring sixteenths too: a cut made to the
        // millisecond on a sentence's end rounds to either side of it.)
        // (A comma's clause ending is a way out the planner means to take.
        // Not judged where the song jumps or is counted at half or double
        // time: its own grid isn't the blend's count there.)
        let plain = mix.tracks[t.from].skip == nil && mix.tracks[t.to].skip == nil
            && MixMath.tempoMultiplier(a: mix.tracks[t.from].loaded.analysis.grid.bpm, b: mix.tracks[t.to].loaded.analysis.grid.bpm) == 1
        // (A line's edge by the words within two sixteenths either way
        // counts: the recogniser's times are no closer than that.)
        let sa = plain && (slot(t.from, out).map { k in (k - 1...k + 1).allSatisfy {
            (mix.tracks[t.from].loaded.analysis.structure?.midSentence(at: $0) ?? false) }
            && !(k - 2...k + 2).contains { mix.tracks[t.from].loaded.analysis.structure?.clauseEnd(at: $0) ?? false } } ?? false)
        let sb = plain && slot(t.to, inn).map { k in (k - 1...k + 1).allSatisfy {
            mix.tracks[t.to].loaded.analysis.structure?.midPart(at: $0) ?? false }
            && !(k - 2...k + 2).contains { mix.tracks[t.to].loaded.analysis.structure?.partStart(at: $0) ?? false } } ?? false
        if sa, CommandLine.arguments.contains("-v"), let k = slot(t.from, out) {
            let planned = Double(VocalPhrasing.slots) * (Double(t.edit.entryBar) + (out - t.start) / t.barSeconds)
            print(String(format: "   A cut at sixteenth %d by its grid, %.2f as planned", k, planned))
            if let st = mix.tracks[t.from].loaded.analysis.structure {
                print("   clause ends near: " + ((k - 8)...(k + 8)).filter { st.clauseEnd(at: $0) }.map { String($0 - k) }.joined(separator: " ")
                      + "   breaths near: " + st.breaths(from: Double(k - 8), to: Double(k + 8), origin: Double(k)).map { String(format: "%.2f…%.2f", $0.lowerBound, $0.upperBound) }.joined(separator: " "))
            }
        }
        // The singer's level as heard, A's last 8 sung beats against B's
        // first 8 (median of each, beats where it's heard). Sung: within
        // 10 dB of what that voice sings at here, played untouched (so
        // neither a voice turned down to match nor a stem's breath and
        // leftovers before a singer starts count as its level).
        let singsA = ref(rawA) - 10, singsB = ref(rawB) - 10
        let aSung = ha.indices.filter { ha[$0] && rawA[$0] > singsA }.suffix(8).map { la[$0] }.sorted()
        let bSung = hb.indices.filter { hb[$0] && rawB[$0] > singsB }.prefix(8).map { lb[$0] }.sorted()
        // (A voice that never really sings here, its loud beats down in the
        // noise, has no level to match.)
        let sings = ra > 25 && rb > 25 && aSung.count >= 4 && bSung.count >= 4
        let step = sings ? bSung[bSung.count / 2] - aSung[aSung.count / 2] : 0
        if sings { steps.append(step) }
        // Whether the cut itself fell in a gap, on the audio: the voice as
        // its song sings it (untouched), in 5 ms frames, where the channel
        // shuts (from its release, 30 ms before A's exit, to 20 ms after)
        // and opens (the 40 ms before B's entry), against the loud frames
        // around it. Above `chopLimit` there, a word was cut in two.
        func frames(_ k: Int, from t0: Double, count: Int) -> [Double] {
            let renderer = MixRenderer(snapshot: raw.snapshot(masterGain: 1, including: { i, s in i == k && s == .vocals }))
            renderer.setPositionImmediately(Int(t0 * sr))
            let len = Int(0.005 * sr)
            // (A's beat looped: what its voice would sing from the loop on
            // is the loop's, which never plays, its channel shut first.)
            let silentFrom = k == t.from && t.loopBars > 0 ? t.start : .infinity
            return (0..<count).map { f in
                var l = [Float](repeating: 0, count: len), r = l
                renderer.render(left: &l, right: &r, count: len)
                guard t0 + Double(f) * 0.005 < silentFrom else { return -120 }
                let p = zip(l, r).reduce(0.0) { $0 + Double(0.25 * ($1.0 + $1.1) * ($1.0 + $1.1)) } / Double(len)
                return 10 * log10(p + 1e-12)
            }
        }
        func chopAt(_ k: Int, _ time: Double, before: Double, after: Double) -> Double {
            let around = frames(k, from: time - 2 * t.barSeconds, count: Int(4 * t.barSeconds / 0.005)).sorted()
            let loud = around[around.count * 9 / 10]
            let at = frames(k, from: time - before, count: max(1, Int((before + after) / 0.005)))
            // (No voice around at all: nothing to cut.)
            guard loud > -60 else { return -120 }
            return (at.max() ?? -120) - loud
        }
        // (A's on its own song, where the master time falls in it: past a
        // loop's start what plays is the loop, and a little of it before.)
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
            let around = songFrames(k, from: time - 2 * t.barSeconds, count: Int(4 * t.barSeconds / 0.005)).sorted()
            let loud = around[around.count * 9 / 10]
            let at = songFrames(k, from: time - before, count: max(1, Int((before + after) / 0.005)))
            // (No voice around at all: nothing to cut.)
            guard loud > -60 else { return -120 }
            return (at.max() ?? -120) - loud
        }
        let chopOut = t.vocalOutKind == "bar" ? nil : Optional(chopOwn(t.from, out, before: 0.03, after: 0.02))
        let chopIn = chopAt(t.to, inn, before: 0.04, after: 0)
        let chopLimit = -15.0
        if (chopOut ?? -99) > chopLimit { chopsOut += 1 }
        if chopIn > chopLimit { chopsIn += 1 }
        if (chopOut ?? -99) > -6 { hardOut += 1 }
        if chopIn > -6 { hardIn += 1 }
        if CommandLine.arguments.contains("-v"), (chopOut ?? -99) > chopLimit, let k = slot(t.from, out),
           let st = mix.tracks[t.from].loaded.analysis.structure {
            print("   A exit: clause ends near " + ((k - 8)...(k + 8)).filter { st.clauseEnd(at: $0) }.map { String($0 - k) }.joined(separator: " ")
                  + "   breaths near " + st.breaths(from: Double(k - 8), to: Double(k + 8), origin: Double(k)).map { String(format: "%.1f…%.1f", $0.lowerBound, $0.upperBound) }.joined(separator: " ")
                  + "   own level k-2…k+2: " + ((k - 2)...(k + 2)).map { j in String(format: "%.0f", (st.vocalSixteenthLevel.map { j >= 0 && j < $0.count ? $0[j] : -99 } ?? -99) - (st.vocalReference ?? 0)) }.joined(separator: " ")
                  + String(format: "  skip %@ loop %d start %.3f out %.3f", mix.tracks[t.from].skip.map { "\($0)" } ?? "-", t.loopBars, t.start, out))
        }
        if CommandLine.arguments.contains("-v"), (chopOut ?? -99) > chopLimit || chopIn > chopLimit {
            print(String(format: "   CHOP (out %.3f in %.3f): A at its exit %@, B before its entry %+.0f dB (vs its loud frames)", out, inn,
                         chopOut.map { String(format: "%+.0f dB", $0) } ?? "-", chopIn))
        }
        overlapSum += overlap; gapWorst = max(gapWorst, gap); if gap > 4 { gaps4 += 1 }
        if sa { aMid += 1 }; if sb { bMid += 1 }
        print(String(format: "ROW\t%@\t%@\t%.0f\t%.0f\t%d\t%d\t%d\t%.1f\t%d\t%d", SongTitle.of(mix.tracks[t.from].url), SongTitle.of(mix.tracks[t.to].url),
                     chopOut ?? -99, chopIn, gap, sa ? 1 : 0, sb ? 1 : 0, step, silencedA, heldB))
        print(String(format: "%02d voice %+5.1f dB  overlap %2d beats  gap %2d beats  A out %@%@  B in %@%@  %@ → %@", i + 1, step, overlap, gap,
                     t.vocalOutKind ?? "-", sa ? " MID-SENTENCE" : "", t.vocalInKind ?? "-", sb ? " MID-PART" : "",
                     SongTitle.of(mix.tracks[t.from].url), SongTitle.of(mix.tracks[t.to].url)))
        if let hole { print(hole)
            if let sb = mix.tracks[t.to].loaded.analysis.structure, let sa = mix.tracks[t.from].loaded.analysis.structure {
                let c = t.plan.placement.cueBar, e = t.plan.placement.entryBar
                print("   placement sees A voice " + (0..<t.edit.bars).map { String(format: "%.2f", sa.meanActivity(.vocals, bars: (e + $0)..<(e + $0 + 1))) }.joined(separator: " "))
                print("   placement sees B voice " + (0..<t.edit.bars).map { String(format: "%.2f", sb.meanActivity(.vocals, bars: (c + $0)..<(c + $0 + 1))) }.joined(separator: " "))
            }
        }
    }
    let absSteps = steps.map(abs).sorted()
    print(String(format: "VOICE LEVEL B against A: mean |step| %.1f dB, median %.1f, worst %.1f, over 4 dB: %d",
                 absSteps.reduce(0, +) / Double(max(1, absSteps.count)), absSteps.isEmpty ? 0 : absSteps[absSteps.count / 2],
                 absSteps.last ?? 0, absSteps.filter { $0 > 4 }.count))
    print("VOCALS \(both) handovers: overlap \(overlapSum) beats, longest gap \(gapWorst) beats, gaps over a bar \(gaps4), A cut mid-sentence \(aMid), B in mid-part \(bMid), words cut in two: A \(chopsOut), B \(chopsIn) (at full: A \(hardOut), B \(hardIn))")
    exit(0)
}
if CommandLine.arguments.contains("--club") {
    // The set as a dance floor gets it, start to end, by what a club DJ
    // keeps to: no song pulling the energy far down from the one before;
    // not opening on a peak and falling off it; tempos moving in small
    // steps; no stretch of the set falling well under its own level, nor
    // its kick and bass; songs not outstaying their welcome.
    let analyses = tracks.map(\.loaded.analysis)
    let energies = analyses.map(SetOrdering.energy)
    let drops = (1..<energies.count).filter { energies[$0 - 1] - energies[$0] > 0.2 }
    let rank = Double(energies.sorted().firstIndex(of: energies[0]) ?? 0) / Double(max(1, energies.count - 1))
    let openerHigh = rank > 0.5
    var jumps: [String] = []
    for t in mix.transitions {
        let a = analyses[t.from].grid.bpm, b = analyses[t.to].grid.bpm
        let st = MixMath.stretch(MixMath.rate(a: a, b: b))
        if st > 0.06 { jumps.append(String(format: "%d→%d %.0f→%.0f BPM (%.0f %%)", t.from + 1, t.to + 1, a, b, st * 100)) }
    }
    let window = 30.0, count = Int(mix.length / window)
    let snap = mix.snapshot(masterGain: 1)
    let level = barLevels(from: 0, bars: count, barSeconds: window, of: snap)
    let low = barLevels(from: 0, bars: count, barSeconds: window, of: snap, band: (30, 150))
    func median(_ x: [Double]) -> Double { let s = x.sorted(); return s.isEmpty ? 0 : s[s.count / 2] }
    // (The first two minutes are the set's own start.)
    let holes = level.indices.filter { $0 >= 4 && level[$0] < median(level) - 6 }
    let lowHoles = low.indices.filter { $0 >= 4 && low[$0] < median(low) - 8 }
    var alone: [Double] = []
    for k in mix.tracks.indices {
        let from = k == 0 ? 0 : mix.transitions[k - 1].end
        let to = k < mix.transitions.count ? mix.transitions[k].begins : mix.length
        alone.append(max(0, to - from))
    }
    let arc = SetOrdering.EnergyArc(energies)
    let offArc = energies.indices.map { arc.cost($0, place: $0, count: energies.count) / (arc.weight * SetOrdering.warmUp(place: $0, count: energies.count)) }
    let arcRMS = (offArc.reduce(0, +) / Double(max(1, offArc.count))).squareRoot()
    if CommandLine.arguments.contains("-v") {
        for k in drops { print(String(format: "DROP %2d→%2d energy %.2f → %.2f  %@ → %@", k, k + 1, energies[k - 1], energies[k], SongTitle.of(tracks[k - 1].url), SongTitle.of(tracks[k].url))) }
        for j in jumps { print("JUMP \(j)") }
        for h in holes { print(String(format: "HOLE at %@: %.1f dB under the set", String(format: "%d:%02d", Int(Double(h) * window) / 60, Int(Double(h) * window) % 60), median(level) - level[h])) }
        // (Whose: the song playing there, and whether a transition is.)
        func at(_ time: Double) -> String {
            let k = mix.transitions.filter { $0.end <= time }.count
            let blending = mix.transitions.contains { $0.begins <= time + window && $0.end >= time }
            return SongTitle.of(tracks[min(k, tracks.count - 1)].url) + (blending ? " (in a transition)" : " (on its own)")
        }
        for h in lowHoles { print(String(format: "LOW HOLE at %@: kick and bass %.1f dB under the set, %@", String(format: "%d:%02d", Int(Double(h) * window) / 60, Int(Double(h) * window) % 60), median(low) - low[h], at(Double(h) * window))) }
    }
    // Each song's hooks (its chorus, its drop: what the crowd waits for)
    // the set plays: from the blend into it to the end of the blend out
    // of it, not jumped over. A song whose strongest hook never plays was
    // left before its moment.
    var missed: [String] = [], hooksHeard = 0, hooksAll = 0
    for (k, t) in mix.tracks.enumerated() {
        guard let st = t.loaded.analysis.structure else { continue }
        let grid = t.loaded.analysis.grid
        let from = k == 0 ? -1e9 : mix.transitions[k - 1].begins
        let to = k < mix.transitions.count ? mix.transitions[k].end : 1e9
        let hooks = (0..<st.loudness.count).map { st.hook($0) }
        guard let top = hooks.max(), top >= 0.3 else { continue }
        func plays(_ bar: Int) -> Bool {
            let songTime = grid.downbeat(bar)
            if let skip = t.skip, songTime >= skip.from, songTime < skip.to { return false }
            let at = t.master(songTime)
            return at >= from && at < to
        }
        // (A hook a bar or two from the strongest is the same one.)
        let strong = hooks.indices.filter { hooks[$0] >= 0.5 * top && ($0 == 0 || hooks[$0 - 1] < 0.5 * top) }
        hooksAll += strong.count
        hooksHeard += strong.filter(plays).count
        let best = hooks.firstIndex(of: top)!
        if CommandLine.arguments.contains("--hooks") {
            let bars = (0..<st.loudness.count).filter(plays)
            print(String(format: "%2d plays bars %d-%d of %d; hooks: %@  %@", k + 1, bars.first ?? -1, bars.last ?? -1, st.loudness.count,
                         strong.map { String(format: "%d:%.2f", $0, hooks[$0]) }.joined(separator: " "), SongTitle.of(t.url)))
        }
        if !plays(best) {
            let first = strong.first(where: plays)
            missed.append(String(format: "%2d %@: best hook bar %d (%.2f) not played%@", k + 1, SongTitle.of(t.url), best, top,
                                 first.map { String(format: ", plays one at bar %d (%.2f)", $0, hooks[$0]) } ?? ", NO hook played"))
        }
    }
    if CommandLine.arguments.contains("-v") { for m in missed { print("HOOK " + m) } }
    print(String(format: "HOOKS %d of %d strong hooks played; best hook missed in %d songs, no hook at all in %d",
                 hooksHeard, hooksAll, missed.count, missed.filter { $0.hasSuffix("NO hook played") }.count))
    // (A song's own breakdown before its drop is its moment, not a hole:
    // only holes a transition makes count.)
    let made = lowHoles.filter { h in mix.transitions.contains { $0.begins <= Double(h) * window + window && $0.end >= Double(h) * window } }
    let club = 2.0 * Double(drops.count) + 2.0 * Double(jumps.count) + Double(holes.count) + Double(made.count) + (openerHigh ? 3 : 0) + 20 * arcRMS
    print(String(format: "CLUB %d songs: energy drops %d, tempo jumps %d, holes %d, low-end holes %d, opener %@ (energy %.2f, rank %.0f %%), off the arc %.3f, songs alone median %.0f s (90th %.0f s) | club score %.1f",
                 energies.count, drops.count, jumps.count, holes.count, lowHoles.count, openerHigh ? "HIGH" : "ok", energies[0], rank * 100,
                 arcRMS, median(alone), alone.sorted()[alone.count * 9 / 10], club))
    exit(0)
}
if CommandLine.arguments.contains("--report") {
    // Everything that can be measured about each transition, and the set's
    // totals: what a change to the planner is judged by.
    struct Row { var after = 0.0, dipAt = "", seam = 0.0, excess = 0.0, hole = 0.0, together = 0, bars = 0, dip = 0.0, busy = 0, moves = 0 }
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
        // (A drop moment, the bar of silence before B's drop, is meant:
        // the steps into and out of it aren't counted, nor its level.)
        let silenceBar = t.dropAt.map { Int((($0 - from) / t.barSeconds).rounded()) - 1 }
        // (A fakeout lands a bar later: the slam out of its bare bar is meant too.)
        let slam = t.dropDelayBars > 0 ? silenceBar.map { $0 + Int(t.dropDelayBars.rounded()) } : nil
        let meant = { (j: Int) in (silenceBar.map { j == $0 - 1 || j == $0 } ?? false) || j == slam }
        row.excess = js.indices.filter { !meant($0) }.map { js[$0] - max(ja[$0], jb[$0]) }.max() ?? 0
        row.seam = js.indices.filter { !meant($0) }.map { js[$0] }.max() ?? 0
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
        let heard = barLevels(from: t.begins, bars: n + 2, barSeconds: t.barSeconds) { _, _ in true }
        // (The drop's bar of silence, and a fakeout's bare bar after it,
        // are meant: each reads as the bar before it.)
        let quiet = silenceBar.map { $0 - 2 }
        let bare = quiet.map { $0 + Int(t.dropDelayBars.rounded()) }
        let around = heard.indices.map { j -> Double in
            guard let q = quiet, j >= q, j <= (bare ?? q) else { return heard[j] }
            return heard[max(0, q - 1)]
        }
        row.dip = median - (around.min() ?? median)
        // (Where: bars from B's entry, and whose: A alone, B alone, both.)
        if let low = around.indices.min(by: { around[$0] < around[$1] }) {
            let aa = barLevels(from: t.begins, bars: n + 2, barSeconds: t.barSeconds) { k, _ in k == t.from }
            let bb = barLevels(from: t.begins, bars: n + 2, barSeconds: t.barSeconds) { k, _ in k == t.to }
            row.dipAt = String(format: "bar %d (A %.0f, B %.0f, songs' median %.0f)", low, aa[low], bb[low], median)
        }
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
        // B once A has gone: the 4 bars after the blend, against B's own
        // loud level (both as the set plays B, trims in).
        do {
            let a = t.to == 0 ? 0 : mix.transitions[t.to - 1].end
            let b = t.to < mix.transitions.count ? mix.transitions[t.to].begins : mix.length
            var solo = barLevels(from: a, bars: max(1, Int((b - a) / t.barSeconds) - 1), barSeconds: t.barSeconds) { _, _ in true }
            solo.sort()
            let loud = solo[Int(Double(solo.count - 1) * 0.8)]
            let after = barLevels(from: t.end, bars: 4, barSeconds: t.barSeconds) { _, _ in true }
            row.after = loud - after.reduce(0, +) / Double(max(1, after.count))
        }
        rows.append(row)
        if row.dip > 4 { print("   dip at " + row.dipAt) }
        // (Bars of the blend with no beat to speak of: both kits 15 dB or
        // more under what they play at through it.)
        let kit = barLevels(from: t.begins, bars: max(1, Int(((t.end - t.begins) / t.barSeconds).rounded())), barSeconds: t.barSeconds) { k, s in
            (k == t.from || k == t.to) && s == .drums
        }
        let kitLoud = kit.sorted()[kit.count * 3 / 4]
        let beatless = kit.filter { $0 < kitLoud - 15 }.count
        print(String(format: "RROW\t%@\t%@\t%.2f\t%.2f\t%d\t%.2f\t%d\t%d", SongTitle.of(mix.tracks[t.from].url), SongTitle.of(mix.tracks[t.to].url),
                     row.excess, row.seam, row.together, row.dip, row.busy, beatless))
        let sw = TransitionBuilder.switchBar(t.edit.preset, bars: t.edit.bars, lowSwap: t.plan.placement.lowSwap)
        print(String(format: "%02d %@ → %@  %@ %d  excess %.1f dB  seam %.2f× at %.0f (switch %.0f)  together %d/%d  dip %.1f dB (drop %.1f)  busy %d  at once %d  B after %.1f dB under  predicted together %d%@",
                     i + 1, SongTitle.of(mix.tracks[t.from].url), SongTitle.of(mix.tracks[t.to].url),
                     t.edit.preset.displayName, t.edit.bars, row.excess, row.seam, seamAt, sw, row.together, n, row.dip, row.hole, row.busy, row.moves, row.after, t.plan.placement.together ?? -1,
                     (t.melodiesClash ? "  clash" : "") + (t.dropAt != nil ? "  drop moment" : "")
                        + (t.loopBars > 0 ? "  loop" : t.plan.placement.carry ? "  carry" : "")))
    }
    // How the voices changed hands: A's left on a line end ("line"),
    // between words ("word") or on the downbeat while singing ("bar");
    // B's came in likewise.
    var outKinds: [String: Int] = [:], inKinds: [String: Int] = [:]
    for (i, t) in mix.transitions.enumerated() where CommandLine.arguments.contains("-v")
        && (t.vocalInKind == "word" || t.vocalOutKind == "word" || t.vocalOutKind == "bar") {
        print(String(format: "VOICE %02d out %@ in %@  %@ → %@", i + 1, t.vocalOutKind ?? "none", t.vocalInKind ?? "none",
                     SongTitle.of(mix.tracks[t.from].url), SongTitle.of(mix.tracks[t.to].url)))
    }
    for t in mix.transitions {
        outKinds[t.vocalOutKind ?? "none", default: 0] += 1
        inKinds[t.vocalInKind ?? "none", default: 0] += 1
    }
    print("VOICES A out: " + outKinds.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
          + " | B in: " + inKinds.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
    let m = Double(max(1, rows.count))
    print(String(format: "SET %d transitions: excess mean %.2f dB worst %.2f, over 2 dB: %d | seam mean %.2f× worst %.2f× | together mean %.1f, under 4: %d | dips over 4 dB: %d, bar-to-bar drops over 6 dB: %d | busy bars %d | at once max %d mean %.1f | B after the blend under its loud level: mean %.1f dB, over 4 dB: %d",
                 rows.count, rows.map(\.excess).reduce(0, +) / m, rows.map(\.excess).max() ?? 0, rows.filter { $0.excess > 2 }.count,
                 rows.map(\.seam).reduce(0, +) / m, rows.map(\.seam).max() ?? 0,
                 Double(rows.map(\.together).reduce(0, +)) / m, rows.filter { $0.together < 4 }.count,
                 rows.filter { $0.dip > 4 }.count, rows.filter { $0.hole > 6 }.count, rows.map(\.busy).reduce(0, +), rows.map(\.moves).max() ?? 0,
                 Double(rows.map(\.moves).reduce(0, +)) / m, rows.map(\.after).reduce(0, +) / m, rows.filter { $0.after > 4 }.count))
    // Which automatic moves the set really uses.
    var moveCounts: [String: Int] = [:]
    for t in mix.transitions { for move in t.payoff { moveCounts[move, default: 0] += 1 } }
    for (i, t) in mix.transitions.enumerated() {
        print("PLAN\t\(i + 1)\t\(SongTitle.of(mix.tracks[t.from].url))\t\(SongTitle.of(mix.tracks[t.to].url))\t\(t.payoff.joined(separator: "; "))")
    }
    print("MOVES " + moveCounts.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
    exit(0)
}

if CommandLine.arguments.contains("--clicks") {
    // Every hard switch a transition makes (a stem cut in or out, a filter
    // or the low kill snapping on or off): how much it splatters, against
    // the mix it plays in. A part switched in a millisecond or two, or a
    // filter changed in one step, puts a broadband tick on the mix (the
    // part's low notes chopped mid-wave); switched smoothly it puts none.
    // Measured per lane: the lane as automated against the same lane
    // staying as it was before the switch and as it is after it. Energy
    // in a band at the switch that neither has there (6 dB over the louder)
    // is the switch's own; it's heard if it comes near what the whole mix
    // carries in that band around it (the click-to-mask ratio, dB).
    let n = 256, hop = 32, fft = RealFFT(size: n)
    let window = (0..<n).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(n))) }
    // Octave bands from 500 Hz to 16 kHz.
    let edges = [500.0, 1000, 2000, 4000, 8000, 16000].map { Int($0 / sr * Double(n)) }
    // (A send's switch is heard where the effect gives it back: an echo
    // a dotted eighth on, so rendered from well before that.)
    let lead = 1.2, half = 0.045
    func render(_ snapshot: MixSnapshot, around t: Double) -> [Float] {
        let renderer = MixRenderer(snapshot: snapshot)
        renderer.setPositionImmediately(Int((t - lead) * sr))
        let count = Int((lead + half) * sr)
        var l = [Float](repeating: 0, count: count), r = l
        renderer.render(left: &l, right: &r, count: count)
        let from = Int((lead - half) * sr)
        return (from..<count).map { 0.5 * (l[$0] + r[$0]) }
    }
    /// Power per band, frame by frame.
    func bands(_ x: [Float]) -> [[Double]] {
        var out: [[Double]] = []
        var start = 0
        while start + n <= x.count {
            let mag = fft.magnitudes(of: (0..<n).map { x[start + $0] * window[$0] })
            out.append((0..<(edges.count - 1)).map { b in (edges[b]..<edges[b + 1]).reduce(0.0) { $0 + Double(mag[$1] * mag[$1]) } })
            start += hop
        }
        return out
    }
    struct Step { let track: Int, stem: StemKind, parameter: LaneParameter, arrives: Double, lane: String }
    var all: [(db: Double, text: String)] = []
    var perTransition: [Double] = []
    for (i, t) in mix.transitions.enumerated() {
        var steps: [Step] = []
        for k in [t.from, t.to] {
            for (stem, envelopes) in mix.tracks[k].envelopes {
                for p in LaneParameter.allCases where p.rawValue < envelopes.count {
                    let pts = envelopes[p.rawValue].points
                    for j in pts.indices.dropFirst() where abs(pts[j].value - pts[j - 1].value) > 0.05
                        && (pts[j].time - pts[j - 1].time <= 0.02 || pts[j - 1].curve == .hold)
                        && pts[j].time > t.begins - t.barSeconds && pts[j].time < t.end + t.barSeconds {
                        // (Sends each on their own, as a lane of their own.)
                        let stemKey = p == .delay || p == .reverb ? stem.rawValue + " " + p.shortName : stem.rawValue
                        steps.append(Step(track: k, stem: stem, parameter: p, arrives: pts[j].time, lane: "\(k) \(stemKey)"))
                    }
                }
            }
        }
        // Switches of one lane within 15 ms are one move.
        var worst = -120.0
        let lanes = Set(steps.map(\.lane))
        for lane in lanes.sorted() {
            let mine = steps.filter { $0.lane == lane }.sorted { $0.arrives < $1.arrives }
            var clusters: [[Step]] = []
            for s in mine {
                if let last = clusters.last?.last, s.arrives - last.arrives < 0.015 { clusters[clusters.count - 1].append(s) }
                else { clusters.append([s]) }
            }
            for cluster in clusters {
                let k = cluster[0].track, stem = cluster[0].stem
                let first = cluster.map(\.arrives).min()!, last = cluster.map(\.arrives).max()!
                // (Where it's heard: an echo's send a dotted eighth later,
                // in its first repeat; a reverb's as its combs give it back.)
                let heardAfter = cluster[0].parameter == .delay ? t.barSeconds / 4 * 0.75 : cluster[0].parameter == .reverb ? 0.03 : 0
                let centre = (first + last) / 2 + heardAfter
                func variant(_ keep: (LaneParameter, AutomationPoint) -> Bool) -> MixSnapshot {
                    var m = mix
                    var envelopes = m.tracks[k].envelopes[stem]!
                    for p in Set(cluster.map(\.parameter)) {
                        var e = Envelope()
                        for point in envelopes[p.rawValue].points where keep(p, point) { e.insert(point) }
                        envelopes[p.rawValue] = e
                    }
                    m.tracks[k].envelopes[stem] = envelopes
                    return m.snapshot(masterGain: 1) { j, s in j == k && s == stem }
                }
                let auto = bands(render(mix.snapshot(masterGain: 1) { j, s in j == k && s == stem }, around: centre))
                // (Each switched parameter staying where it was, and being
                // where it ends up all along.)
                let before = bands(render(variant { p, point in
                    point.time < cluster.filter { $0.parameter == p }.map(\.arrives).min()! - 1e-9 }, around: centre))
                let after = bands(render(variant { p, point in
                    point.time >= cluster.filter { $0.parameter == p }.map(\.arrives).max()! - 1e-9 }, around: centre))
                let whole = bands(render(snapshot, around: centre))
                var best = (db: -120.0, band: 0)
                for b in 0..<(edges.count - 1) {
                    let mask = whole.map { $0[b] }.reduce(0, +) / Double(max(1, whole.count)) + 1e-12
                    // (Frames that hold the switch: the 15 ms either side.)
                    let near = auto.indices.filter { abs(Double($0 * hop + n / 2) / sr - half) < 0.015 + (last - first) / 2 }
                    let own = near.map { max(0, auto[$0][b] - 4 * max(before[$0][b], after[$0][b])) }.max() ?? 0
                    let db = 10 * log10(own / mask + 1e-12)
                    if db > best.db { best = (db, b) }
                }
                worst = max(worst, best.db)
                let what = Set(cluster.map { $0.parameter.shortName }).sorted().joined(separator: "+")
                all.append((best.db, String(format: "%+6.1f dB  %02d %@ %@ %@ at bar %.2f (%.0f Hz band)  %@ → %@", best.db, i + 1,
                                            k == t.from ? "A" : "B", stem.rawValue, what, (centre - t.start) / t.barSeconds,
                                            Double(edges[best.band]) * sr / Double(n),
                                            SongTitle.of(mix.tracks[t.from].url), SongTitle.of(mix.tracks[t.to].url))))
            }
        }
        // A loop's seams: each time A's looped beat turns round, the lane
        // against the pass before it running on, and against the bars
        // that lead into the loop's first one played straight through.
        for (ri, roll) in mix.tracks[t.from].rolls.enumerated() where roll.seamless == true && roll.start > t.begins - t.barSeconds
            && roll.start < t.end {
            func variant(_ replace: Roll?) -> MixSnapshot {
                var m = mix
                m.tracks[t.from].rolls.remove(at: ri)
                if let replace { m.tracks[t.from].rolls.append(replace) }
                return m.snapshot(masterGain: 1) { j, s in j == t.from && s == roll.stem }
            }
            var turn = roll.start, pass = 0
            while turn < roll.end - 0.05 {
                let centre = turn + 0.004
                let auto = bands(render(mix.snapshot(masterGain: 1) { j, s in j == t.from && s == roll.stem }, around: centre))
                // (The first pass comes out of the song as it was playing.)
                let before = bands(render(variant(pass == 0 ? nil : Roll(side: .a, stem: roll.stem, start: turn - roll.length, end: roll.end,
                                                                         anchor: roll.anchor, length: 1000, seamless: true)), around: centre))
                let after = bands(render(variant(Roll(side: .a, stem: roll.stem, start: turn - roll.length, end: roll.end,
                                                      anchor: roll.anchor - roll.length, length: 1000, seamless: true)), around: centre))
                let whole = bands(render(snapshot, around: centre))
                var best = (db: -120.0, band: 0)
                for b in 0..<(edges.count - 1) {
                    let mask = whole.map { $0[b] }.reduce(0, +) / Double(max(1, whole.count)) + 1e-12
                    let near = auto.indices.filter { abs(Double($0 * hop + n / 2) / sr - half) < 0.02 }
                    let own = near.map { max(0, auto[$0][b] - 4 * max(before[$0][b], after[$0][b])) }.max() ?? 0
                    let db = 10 * log10(own / mask + 1e-12)
                    if db > best.db { best = (db, b) }
                }
                worst = max(worst, best.db)
                all.append((best.db, String(format: "%+6.1f dB  %02d A %@ LOOP pass %d at bar %.2f (%.0f Hz band)  %@ → %@", best.db, i + 1,
                                            roll.stem.rawValue, pass, (turn - t.start) / t.barSeconds, Double(edges[best.band]) * sr / Double(n),
                                            SongTitle.of(mix.tracks[t.from].url), SongTitle.of(mix.tracks[t.to].url))))
                turn += roll.length
                pass += 1
            }
        }
        perTransition.append(worst)
        print(String(format: "CROW\t%@\t%@\t%.1f", SongTitle.of(mix.tracks[t.from].url), SongTitle.of(mix.tracks[t.to].url), worst))
    }
    if CommandLine.arguments.contains("-v") { for row in all.sorted(by: { $0.db > $1.db }).prefix(40) { print(row.text) } }
    func over(_ x: [Double], _ db: Double) -> Int { x.filter { $0 > db }.count }
    let dbs = all.map(\.db)
    print(String(format: "CLICKS %d switches in %d transitions: over 0 dB %d, over -10 dB %d, over -20 dB %d | transitions whose worst switch is over 0 dB: %d, over -10: %d, over -20: %d",
                 dbs.count, perTransition.count, over(dbs, 0), over(dbs, -10), over(dbs, -20),
                 over(perTransition, 0), over(perTransition, -10), over(perTransition, -20)))
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
        let there = TimeStretcher.process(clip, map: .constant(1.03), semitones: 0, percussive: kind == .drums,
                                          vocal: kind == .vocals, harmonicPercussive: kind == .other)
        let back = TimeStretcher.process(there, map: .constant(1 / 1.03), semitones: 0, percussive: kind == .drums,
                                         vocal: kind == .vocals, harmonicPercussive: kind == .other)
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
// The set as the iPhone app plays it (.passablemix), as the Mac app's
// "Save as File" writes it: its songs and handovers, and the whole mix at
// the app's own volume, 256 kbit/s AAC.
if let k = CommandLine.arguments.firstIndex(of: "--phone-mix") {
    let destination = URL(fileURLWithPath: CommandLine.arguments[k + 1])
    let title = CommandLine.arguments.firstIndex(of: "--title").map { CommandLine.arguments[$0 + 1] } ?? PhoneMix.suggestedTitle()
    if let b = CommandLine.arguments.firstIndex(of: "--bitrate") { AudioWriter.aacBitRate = Int(CommandLine.arguments[b + 1])! }
    var manifest = PhoneMix.manifest(for: mix, titles: tracks.map { SongTitle.of($0.url) }, title: title)
    manifest.audio.bitRate = AudioWriter.aacBitRate
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("phonemix-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }
    let audio = temp.appendingPathComponent("mix.m4a")
    try Exporter.render(snapshot: mix.snapshot(masterGain: 0.85), range: 0..<Int(mix.length * sr), tail: 3, to: audio) { _ in }
    try PassableMix.write(manifest, audio: audio, to: destination)
    print("wrote \(destination.path): \(manifest.songs.count) songs, \(Int(mix.length / 60)) min")
    exit(0)
}
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
