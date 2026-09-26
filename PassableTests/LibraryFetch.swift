import XCTest
@testable import Passable

/// Not a unit test: downloads the songs named in $PASSABLE_FETCH (one
/// "Artist - Title" per line) through the app's own search and download,
/// picking the cleanest upload of each. Skipped unless the variable is set.
final class LibraryFetch: XCTestCase {
    func testFetch() throws {
        guard let listFile = ProcessInfo.processInfo.environment["PASSABLE_FETCH"],
              let list = try? String(contentsOfFile: listFile, encoding: .utf8) else {
            throw XCTSkip("set PASSABLE_FETCH")
        }
        for query in list.split(separator: "\n").map(String.init) where !query.isEmpty {
            do {
                let results = try MusicTools.search(query)
                guard let pick = best(results) else { print("FETCH none: \(query)"); continue }
                let url = try MusicTools.download(pick)
                print("FETCH ok: \(query) → \(url.lastPathComponent)")
            } catch {
                print("FETCH failed: \(query): \(error.localizedDescription)")
            }
        }
    }

    /// The studio version: official audio beats a lyric upload beats a music
    /// video (spoken intros, skits); never live, remixed, sped up or covered.
    private func best(_ results: [MusicSearchResult]) -> MusicSearchResult? {
        let banned = ["live", "remix", "slowed", "sped up", "speed up", "nightcore", "8d", "karaoke", "instrumental",
                      "reaction", "cover", "acoustic", "extended", "1 hour", "mashup", "bass boosted", "tutorial"]
        func score(_ r: MusicSearchResult) -> Int? {
            let t = r.title.lowercased()
            if banned.contains(where: { t.contains($0) }) { return nil }
            if let d = r.duration, d < 140 || d > 360 { return nil }
            var s = 0
            if t.contains("official audio") { s += 30 } else if t.contains("audio") { s += 20 }
            if t.contains("lyric") { s += 10 }
            if t.contains("official") { s += 5 }
            if t.contains("video") { s -= 5 }
            return s
        }
        return results.enumerated().compactMap { i, r in score(r).map { (r, $0 - i) } }.max { $0.1 < $1.1 }?.0
    }
}
