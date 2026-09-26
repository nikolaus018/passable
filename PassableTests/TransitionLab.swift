import XCTest
@testable import Passable

/// Not a unit test: runs the automatic transition on consecutive pairs from
/// the file at $PASSABLE_LAB (one audio path per line), renders each one to
/// ~/Music/Passable/Lab, and measures bar by bar what a DJ listens for:
/// steady loudness, one kick and one bass line at a time, no two vocals over
/// each other. Skipped unless the variable is set.
@MainActor
final class TransitionLab: XCTestCase {
    func testLab() async throws {
        guard let listFile = ProcessInfo.processInfo.environment["PASSABLE_LAB"],
              let list = try? String(contentsOfFile: listFile, encoding: .utf8) else {
            throw XCTSkip("set PASSABLE_LAB")
        }
        let paths = list.split(separator: "\n").map(String.init).filter { !$0.isEmpty && !$0.hasPrefix("#") }
        let outDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/Passable/Lab")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        var summaries: [String] = []
        for i in 0..<(paths.count - 1) {
            let a = URL(fileURLWithPath: paths[i]), b = URL(fileURLWithPath: paths[i + 1])
            let s = Session()
            s.load(a, into: .a)
            s.load(b, into: .b)
            let deadline = Date().addingTimeInterval(900)
            func settled() -> Bool {
                s.deckA.status == .ready && s.deckB.status == .ready && s.matched != nil && s.matchStatus == nil
            }
            while !settled() {
                if Date() > deadline { XCTFail("timeout \(a.lastPathComponent)"); return }
                if case .failed(let e) = s.deckA.status { XCTFail(e); return }
                if case .failed(let e) = s.deckB.status { XCTFail(e); return }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            try await Task.sleep(nanoseconds: 600_000_000)
            while !settled() { try await Task.sleep(nanoseconds: 100_000_000) }

            let name = String(format: "%02d %@ → %@.wav", i + 1, short(a), short(b))
            let url = outDir.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: url)
            s.export(.transition, to: url)
            while s.exportProgress != nil || !FileManager.default.fileExists(atPath: url.path) {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            summaries.append(report(s, name: name))
        }
        print("\n==== LAB SUMMARY ====")
        summaries.forEach { print($0) }
    }

    private func short(_ url: URL) -> String {
        var t = url.deletingPathExtension().lastPathComponent
        if let r = t.range(of: " [") { t = String(t[..<r.lowerBound]) }
        if let r = t.range(of: " (") { t = String(t[..<r.lowerBound]) }
        return String(t.prefix(30))
    }

    // MARK: - Measurement

    private struct Bars {
        var mix: [Double] = [], a: [Double] = [], b: [Double] = []
        var lowA: [Double] = [], lowB: [Double] = []
        var vocA: [Double] = [], vocB: [Double] = []
        var harmA: [Double] = [], harmB: [Double] = []
    }

    /// dB per bar of a render of the lanes matching `filter`.
    private func levels(_ s: Session, _ from: Double, _ bars: Int, _ barSeconds: Double,
                        lowPass: Bool = false, _ filter: @escaping (Lane) -> Bool) -> [Double] {
        let sr = AudioIO.sampleRate
        let renderer = MixRenderer(snapshot: s.makeSnapshot(including: filter))
        renderer.setPositionImmediately(Int(from * sr))
        var lp = Biquad()
        lp.set(.lowPass(frequency: 150, q: 0.707), sampleRate: sr)
        var out: [Double] = []
        var carry = 0.0
        for _ in 0..<bars {
            let exact = barSeconds * sr + carry
            let n = Int(exact)
            carry = exact - Double(n)
            var l = [Float](repeating: 0, count: n), r = l
            renderer.render(left: &l, right: &r, count: n)
            if lowPass { lp.process(&l, &r, count: n) }
            var e = 0.0
            for k in 0..<n { e += Double(l[k] * l[k] + r[k] * r[k]) }
            out.append(10 * log10(max(1e-12, e / Double(2 * n))))
        }
        return out
    }

    private func report(_ s: Session, name: String) -> String {
        let g = s.masterGrid!
        let pre = 8, post = 8
        let from = g.downbeat(s.entryBar - pre)
        let end = max(s.transitionEnd, s.glideRange?.upperBound ?? s.transitionEnd)
        let bars = Int(((end - from) / g.barSeconds).rounded(.up)) + post
        var m = Bars()
        m.mix = levels(s, from, bars, g.barSeconds) { _ in true }
        m.a = levels(s, from, bars, g.barSeconds) { $0.side == .a }
        m.b = levels(s, from, bars, g.barSeconds) { $0.side == .b }
        m.lowA = levels(s, from, bars, g.barSeconds, lowPass: true) { $0.side == .a }
        m.lowB = levels(s, from, bars, g.barSeconds, lowPass: true) { $0.side == .b }
        m.vocA = levels(s, from, bars, g.barSeconds) { $0.side == .a && $0.stem == .vocals }
        m.vocB = levels(s, from, bars, g.barSeconds) { $0.side == .b && $0.stem == .vocals }
        m.harmA = levels(s, from, bars, g.barSeconds) { $0.side == .a && $0.stem == .other }
        m.harmB = levels(s, from, bars, g.barSeconds) { $0.side == .b && $0.stem == .other }

        func both(_ x: Double, _ y: Double, floor: Double, within: Double) -> Bool {
            x > floor && y > floor && abs(x - y) < within
        }
        print("\n== \(name)")
        let ka = s.deckA.analysis!.key, kb = s.keyAfterShift!
        print(String(format: "A %.2f BPM %@  B %.2f BPM %@ (shift %+d)  rate %.3f  entry A bar %d, B bar %d, %@ %d bars, glide %d bars  %@",
                     g.bpm, ka.camelotCode, s.deckB.analysis!.grid.bpm, kb.camelotCode, s.semitones, s.matchRate,
                     s.entryBar + 1, s.cueBar + 1, s.preset.displayName, s.transitionBars, s.glideBars, s.placementNote ?? ""))
        print("bar   mix     A     B | lowA  lowB | vocA  vocB | othA  othB")
        var doubleLow = 0, doubleVoc = 0, doubleHarm = 0
        for k in 0..<bars {
            let dl = both(m.lowA[k], m.lowB[k], floor: -38, within: 10)
            let dv = both(m.vocA[k], m.vocB[k], floor: -40, within: 12)
            let dh = both(m.harmA[k], m.harmB[k], floor: -40, within: 10)
            if dl { doubleLow += 1 }
            if dv { doubleVoc += 1 }
            if dh { doubleHarm += 1 }
            print(String(format: "%3d %5.1f %5.1f %5.1f | %5.1f %5.1f | %5.1f %5.1f | %5.1f %5.1f %@%@%@",
                         k - pre, m.mix[k], m.a[k], m.b[k], m.lowA[k], m.lowB[k], m.vocA[k], m.vocB[k], m.harmA[k], m.harmB[k],
                         dl ? " LOWx2" : "", dv ? " VOCx2" : "", dh ? " HARMx2" : ""))
        }
        let before = m.mix[0..<pre].reduce(0, +) / Double(pre)
        let after = m.mix[(bars - post)..<bars].reduce(0, +) / Double(post)
        let middle = m.mix[pre..<(bars - post)]
        let bump = (middle.max() ?? 0) - max(before, after)
        let dip = min(before, after) - (middle.min() ?? 0)
        let keyNote = kb.harmonicShift(toMatch: ka, limit: 0) == 0 ? "keys ok" : "KEY CLASH"
        return String(format: "%@\n   A %.1f dB → B %.1f dB (jump %+.1f)  bump %+.1f  dip %.1f  lowx2 %d  vocx2 %d  harmx2 %d  %@  stretch %+.1f%%",
                      name, before, after, after - before, bump, dip, doubleLow, doubleVoc, doubleHarm, keyNote, (s.matchRate - 1) * 100)
    }
}
