import XCTest
@testable import Passable

/// Not a unit test: how well a measure of two songs' notes clashing tells
/// keys that fit from keys that don't, on real music with the answer known.
/// For every song listed in $PASSABLE_HARMONY (one path per line, already
/// analysed), its melody and bass line over eight bars are set against its
/// own melody eight bars on (the same key, by construction) moved up by
/// 0 to 11 semitones: 0 fits, a semitone or a tritone clashes, and the
/// measures are scored on telling those apart (the share of fitting and
/// clashing pairs they put in the right order; 1 is perfect, 0.5 a coin).
/// Skipped unless the variable is set.
final class HarmonyProbe: XCTestCase {
    func testMeasures() throws {
        guard let listFile = ProcessInfo.processInfo.environment["PASSABLE_HARMONY"],
              let list = try? String(contentsOfFile: listFile, encoding: .utf8) else {
            throw XCTSkip("set PASSABLE_HARMONY")
        }
        var songs: [TrackStructure] = [], keys: [MusicalKey] = []
        for path in list.split(separator: "\n").map(String.init) where !path.isEmpty && !path.hasPrefix("#") {
            guard let directory = try? StemCache.directory(for: URL(fileURLWithPath: path)),
                  let analysis = StemCache.loadAnalysis(from: directory),
                  let s = analysis.structure, s.harmonyChroma != nil, s.melodyChroma != nil
            else { continue }
            songs.append(s)
            keys.append(analysis.key)
        }
        print("HARMONY \(songs.count) songs")
        let measures: [(String, (TrackStructure, Range<Int>, TrackStructure, Range<Int>, Int) -> Float?)] = [
            ("scale, whole stretch", { a, ra, b, rb, shift in
                guard let na = AutoPlacement.notes(a, bars: ra), let nb = AutoPlacement.notes(b, bars: rb, shift: shift, melodyOnly: true)
                else { return nil }
                return Harmony.clash(na, nb)
            }),
            ("scale, bar by bar", { a, ra, b, rb, shift in
                let values = zip(ra, rb).compactMap { x, y -> Float? in
                    guard let na = AutoPlacement.notes(a, bars: x..<(x + 1)),
                          let nb = AutoPlacement.notes(b, bars: y..<(y + 1), shift: shift, melodyOnly: true) else { return nil }
                    return Harmony.clash(na, nb)
                }
                return values.count >= 4 ? values.reduce(0, +) / Float(values.count) : nil
            }),
            ("roughness, bar by bar", { a, ra, b, rb, shift in
                let values = zip(ra, rb).compactMap { x, y -> Float? in
                    guard let na = AutoPlacement.notes(a, bars: x..<(x + 1)),
                          let nb = AutoPlacement.notes(b, bars: y..<(y + 1), shift: shift, melodyOnly: true) else { return nil }
                    return Harmony.roughness(na, nb)
                }
                return values.count >= 4 ? values.reduce(0, +) / Float(values.count) : nil
            }),
            ("roughness, whole stretch", { a, ra, b, rb, shift in
                guard let na = AutoPlacement.notes(a, bars: ra), let nb = AutoPlacement.notes(b, bars: rb, shift: shift, melodyOnly: true)
                else { return nil }
                return Harmony.roughness(na, nb)
            }),
        ]
        // Two different songs: B moved into A's key as the two were read
        // (right for about nine songs in ten), and from there by 0 to 11.
        let across = ProcessInfo.processInfo.environment["PASSABLE_HARMONY_ACROSS"] != nil
        for (name, measure) in measures {
            var byShift = [[Float]](repeating: [], count: 12)
            if across {
                for i in songs.indices {
                    for j in songs.indices where j != i && (i * 31 + j * 17) % 5 == 0 {
                        let a = songs[i], b = songs[j]
                        let home = keys[j].harmonicShift(toMatch: keys[i])
                        for (x, y) in [(a.loudness.count / 2, b.loudness.count / 4), (a.loudness.count * 2 / 3, b.loudness.count / 2)] {
                            let ra = (x / 4 * 4)..<(x / 4 * 4 + 8), rb = (y / 4 * 4)..<(y / 4 * 4 + 8)
                            for shift in 0..<12 {
                                if let v = measure(a, ra, b, rb, home + shift) { byShift[shift].append(v) }
                            }
                        }
                    }
                }
            } else {
                for s in songs {
                    let n = s.loudness.count
                    for x in stride(from: 16, to: n - 24, by: 8) {
                        for shift in 0..<12 {
                            if let v = measure(s, x..<(x + 8), s, (x + 8)..<(x + 16), shift) { byShift[shift].append(v) }
                        }
                    }
                }
            }
            func percentile(_ x: [Float], _ p: Double) -> Float { x.isEmpty ? .nan : x.sorted()[min(x.count - 1, Int(Double(x.count) * p))] }
            /// The share of (fitting, clashing) pairs with the clashing one higher.
            func order(_ fit: [Float], _ clash: [Float]) -> Double {
                let sorted = fit.sorted()
                var right = 0.0
                for c in clash {
                    var lo = 0, hi = sorted.count
                    while lo < hi { let mid = (lo + hi) / 2; if sorted[mid] < c { lo = mid + 1 } else { hi = mid } }
                    right += Double(lo)
                }
                return right / Double(max(1, fit.count * clash.count))
            }
            let fit = byShift[0], clash = byShift[1] + byShift[6] + byShift[11]
            print(String(format: "HARMONY %@: semitone/tritone told from the same key %.3f; a whole tone %.3f; a fifth %.3f  (%d stretches)",
                         name, order(fit, clash), order(fit, byShift[2] + byShift[10]), order(fit, byShift[5] + byShift[7]), fit.count))
            print("   shift:  " + (0..<12).map { String(format: "%6d", $0) }.joined())
            for p in [0.1, 0.5, 0.9] {
                print(String(format: "   p%02.0f:    ", p * 100) + (0..<12).map { String(format: "%6.3f", percentile(byShift[$0], p)) }.joined())
            }
            // The threshold that gets most right, and how many of each it gets wrong.
            let candidates = (fit + clash).sorted()
            var best = (errors: Int.max, at: Float(0))
            for t in stride(from: 0, to: candidates.count, by: max(1, candidates.count / 400)) {
                let at = candidates[t]
                let errors = fit.filter { $0 > at }.count * clash.count + clash.filter { $0 <= at }.count * fit.count
                if errors < best.errors { best = (errors, at) }
            }
            print(String(format: "   best threshold %.3f: %.0f%% of fitting stretches called a clash, %.0f%% of clashing ones missed",
                         best.at, 100 * Double(fit.filter { $0 > best.at }.count) / Double(max(1, fit.count)),
                         100 * Double(clash.filter { $0 <= best.at }.count) / Double(max(1, clash.count))))
        }
    }
}
