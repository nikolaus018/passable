import XCTest
@testable import Passable

/// Not a unit test: loads the songs listed in the file at $PASSABLE_LYRICS
/// (one path per line), which hears their words once (see `Lyrics`), and
/// prints what was heard: how many lines, how much of the song comes back
/// (its chorus), and bar by bar what the words make of each phrase's
/// edge. Skipped unless the variable is set.
final class LyricsProbe: XCTestCase {
    func testLyrics() throws {
        guard let listFile = ProcessInfo.processInfo.environment["PASSABLE_LYRICS"],
              let list = try? String(contentsOfFile: listFile, encoding: .utf8) else {
            throw XCTSkip("set PASSABLE_LYRICS")
        }
        let processor = TrackProcessor()
        print("languages on this Mac: \(Lyrics.available())")
        var heard = 0, total = 0
        for path in list.split(separator: "\n").map(String.init) where !path.isEmpty && !path.hasPrefix("#") {
            let done = expectation(description: path)
            let t0 = Date()
            processor.load(URL(fileURLWithPath: path), ticket: .init(), progress: { _ in }) { result in
                defer { done.fulfill() }
                guard case .success(let loaded) = result, let s = loaded.analysis.structure else {
                    print("LYRICS FAIL \(path)")
                    return
                }
                total += 1
                let lines = s.vocalLines ?? []
                if !lines.isEmpty { heard += 1 }
                let words = lines.reduce(0) { $0 + $1.words }
                let back = lines.filter { $0.repeats >= 2 }.count
                print(String(format: "LYRICS %3d lines %4d words, %3d lines come back  (%.1fs)  %@%@", lines.count, words, back,
                             Date().timeIntervalSince(t0), SongTitle.of(URL(fileURLWithPath: path)),
                             loaded.analysis.grid.isSteady ? "" : "  [no steady tempo: its own bars]"))
                let grid = loaded.analysis.grid
                if let doubtful = grid.doubtful {
                    print("   bars in doubt: " + doubtful.map { "\(Theme.time($0.lowerBound))–\(Theme.time($0.upperBound))" }.joined(separator: ", "))
                }
                if grid.isSteady, let d = grid.downbeats {
                    let odd = (0..<(d.count - 1)).filter { !grid.isRegular($0..<($0 + 1)) }
                    print("   odd bars: " + odd.map { String(format: "bar %d at %@ (%.0f beats)", $0, Theme.time(d[$0]), (d[$0 + 1] - d[$0]) / grid.beatSeconds) }.joined(separator: ", "))
                }
                guard !lines.isEmpty else { return }
                var plain = s
                plain.setLines([], tried: nil, grid: loaded.analysis.grid)
                let boundary = s.boundaryStrength()
                let with = AutoPlacement.phrases(s, boundary: boundary), without = AutoPlacement.phrases(plain, boundary: boundary)
                func row(_ edge: [Float], _ starts: [Bool]) -> String {
                    edge.indices.map { starts[$0] ? String(Int((edge[$0] * 9).rounded())) : "·" }.joined()
                }
                print("   edges by sound:  " + row(without.edge, without.starts))
                print("   with the words:  " + row(with.edge, with.starts))
                print("   comes back:      " + (s.lyricRepeat ?? []).map { $0 < 0 ? " " : $0 >= 0.5 ? "#" : "-" }.joined())
                let phrases = with.starts.indices.filter { with.starts[$0] }
                print("   phrase starts a line is sung through: \(phrases.filter { with.edge[$0] <= 0.1 && without.edge[$0] > 0.1 }.count) of \(phrases.count)")
            }
            wait(for: [done], timeout: 600)
        }
        print("words heard in \(heard) of \(total) songs")
    }
}
