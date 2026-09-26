import XCTest
@testable import Passable

/// Not a unit test: packs the songs in $PASSABLE_PACK (one path per line,
/// kept in that order) with their cached analyses into the `.passable` file
/// at $PASSABLE_PACK_OUT. Skipped unless both are set.
final class SetPack: XCTestCase {
    func testPack() throws {
        let env = ProcessInfo.processInfo.environment
        guard let listFile = env["PASSABLE_PACK"], let out = env["PASSABLE_PACK_OUT"],
              let list = try? String(contentsOfFile: listFile, encoding: .utf8) else {
            throw XCTSkip("set PASSABLE_PACK and PASSABLE_PACK_OUT")
        }
        let songs = list.split(separator: "\n").map(String.init).filter { !$0.isEmpty && !$0.hasPrefix("#") }.map { path in
            let url = URL(fileURLWithPath: path)
            return (url: url, analysis: (try? StemCache.directory(for: url)).flatMap(StemCache.loadAnalysis))
        }
        for song in songs where song.analysis == nil { print("PACK no analysis: \(song.url.lastPathComponent)") }
        try PassableFile.write(songs: songs, transitions: [], masterVolume: 0.85, to: URL(fileURLWithPath: out)) { _ in }
        print("PACK wrote \(out)")
    }
}
