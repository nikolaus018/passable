import XCTest
@testable import Passable

/// Not a unit test: loads the songs in $PASSABLE_PACK (one path per line),
/// lets Passable order them as the Set tab does, and writes the set, songs and analyses
/// included, to the `.passable` file at $PASSABLE_PACK_OUT. Skipped unless
/// both paths are set.
@MainActor
final class SetPack: XCTestCase {
    func testPack() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let listFile = env["PASSABLE_PACK"], let out = env["PASSABLE_PACK_OUT"],
              let list = try? String(contentsOfFile: listFile, encoding: .utf8) else {
            throw XCTSkip("set PASSABLE_PACK and PASSABLE_PACK_OUT")
        }
        let urls = list.split(separator: "\n").map(String.init).filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .map { URL(fileURLWithPath: $0) }
        let set = SetSession(persists: false)
        set.add(urls)
        let deadline = Date().addingTimeInterval(3600)
        // Until the set is built: the songs are ordered in the background
        // once the last one is ready, and built in that order.
        while set.mix == nil || set.buildStatus != nil {
            if Date() > deadline { XCTFail("timeout"); return }
            if let failed = set.items.first(where: { if case .failed = $0.status { return true } else { return false } }) {
                XCTFail("\(failed.title): \(failed.status)"); return
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        for (i, item) in set.items.enumerated() {
            let a = item.analysis!
            print(String(format: "PACK %2d  %6.2f BPM  %@  %@", i + 1, a.grid.bpm, a.key.camelotCode, item.title))
        }
        try PassableFile.write(songs: set.items.map { ($0.url, $0.analysis) }, transitions: [], masterVolume: 0.85,
                               to: URL(fileURLWithPath: out)) { _ in }
        print("PACK wrote \(out)")
    }
}
