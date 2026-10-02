import XCTest
@testable import Passable

/// Not a unit test: builds a set from all but the last of the songs listed
/// in $PASSABLE_REQUEST (one path per line, already separated), puts the
/// playhead in the middle of its second song and requests the last one.
/// Checks that it lands after the song that's playing (or as soon as it
/// fits), that a song already in the set is turned down, and that what
/// plays around the playhead is sample for sample what played before.
/// Skipped unless the variable is set.
@MainActor
final class RequestLab: XCTestCase {
    func testRequest() async throws {
        guard let listFile = ProcessInfo.processInfo.environment["PASSABLE_REQUEST"],
              let list = try? String(contentsOfFile: listFile, encoding: .utf8) else {
            throw XCTSkip("set PASSABLE_REQUEST")
        }
        let urls = list.split(separator: "\n").map(String.init).filter { !$0.isEmpty }.map { URL(fileURLWithPath: $0) }
        let wanted = try XCTUnwrap(urls.last)
        let set = SetSession(persists: false)
        set.add(Array(urls.dropLast()))
        func settle() async throws {
            let deadline = Date().addingTimeInterval(1200)
            repeat {
                try await Task.sleep(nanoseconds: 300_000_000)
                XCTAssertLessThan(Date(), deadline, "timeout")
            } while set.mix == nil || set.buildStatus != nil || !set.requests.isEmpty
                || set.mix?.tracks.count != set.items.count
        }
        try await settle()
        let old = try XCTUnwrap(set.mix)
        let sr = AudioIO.sampleRate

        /// Six seconds of the set from a second before `at`.
        func heard(_ at: Double) -> [Float] {
            let renderer = MixRenderer(snapshot: set.makeSnapshot())
            renderer.setPositionImmediately(Int((at - 1) * sr))
            var l = [Float](repeating: 0, count: Int(6 * sr)), r = l
            renderer.render(left: &l, right: &r, count: l.count)
            return l + r
        }
        for (name, at) in [("mid-song", (old.transitions[0].end + old.transitions[1].cue) / 2 - 15),
                           ("just before its way out", old.transitions[1].cue - 5)] {
            // (The second request is the first set's last song, taken out again.)
            if let i = set.items.firstIndex(where: { $0.url == wanted }) {
                set.remove(set.items[i].id)
                try await settle()
            }
            let before = try XCTUnwrap(set.mix)
            let order = set.items.map(\.url)
            set.seek(to: at)
            let playing = try XCTUnwrap(set.currentIndex)
            let was = heard(at)
            XCTAssertFalse(set.request(order[0]), "a song of the set isn't taken as a request")
            XCTAssertTrue(set.request(wanted))
            XCTAssertFalse(set.request(wanted), "nor one already asked for")
            try await settle()
            let i = try XCTUnwrap(set.items.firstIndex { $0.url == wanted })
            XCTAssertTrue(set.items[i].requested)
            XCTAssertGreaterThan(i, playing, "\(name): after the song that's playing")
            XCTAssertEqual(set.items.map(\.url).filter { $0 != wanted }, order, "\(name): the rest of the set as it was")
            XCTAssertEqual(set.transport.seconds, at, accuracy: 1e-6, "\(name): the playhead stays")
            let now = heard(at)
            var worst: Float = 0
            for k in was.indices { worst = max(worst, abs(was[k] - now[k])) }
            XCTAssertLessThan(worst, 1e-4, "\(name): the music around the playhead changed")
            let after = try XCTUnwrap(set.mix)
            print(String(format: "REQUEST %@ (song %d playing at %@): “%@” is song %d of %d, %@; next transition was at %@, is at %@; heard differs by %.6f",
                         name, playing + 1, Theme.time(at), set.items[i].title, i + 1, set.items.count, set.requestNote ?? "-",
                         Theme.time(before.transitions[playing].start), Theme.time(after.transitions[playing].start), worst))
            print("REQUEST   into it: \(set.summary(from: i - 1) ?? "-")")
            if i < set.items.count - 1 { print("REQUEST   out of it: \(set.summary(from: i) ?? "-")") }
        }
    }
}
