import XCTest
@testable import Passable

/// Not a unit test: builds a set from the songs listed in $PASSABLE_LIVE
/// (one path per line, already separated, played in that order) and plays
/// the room on it. Checks that a set built again from the last one (see
/// `SetBuilder.build(previous:)`) is the set built from scratch, sample for
/// sample, also when its songs have changed places; that Hold moves the
/// playing song's way out later and Mix Now brings the next one in sooner;
/// and that what plays around the playhead stays what it was through both.
/// Skipped unless the variable is set.
@MainActor
final class LiveLab: XCTestCase {
    func testPlayingTheRoom() async throws {
        guard let listFile = ProcessInfo.processInfo.environment["PASSABLE_LIVE"],
              let list = try? String(contentsOfFile: listFile, encoding: .utf8) else {
            throw XCTSkip("set PASSABLE_LIVE")
        }
        let urls = list.split(separator: "\n").map(String.init).filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .map { URL(fileURLWithPath: $0) }
        let sr = AudioIO.sampleRate
        func clock() -> Double { ProcessInfo.processInfo.systemUptime }

        // Built again from the last build, and from scratch.
        let processor = TrackProcessor()
        var loaded: [TrackProcessor.Loaded] = []
        for url in urls {
            loaded.append(try await withCheckedThrowingContinuation { c in
                processor.load(url, ticket: .init(), progress: { _ in }) { c.resume(with: $0) }
            })
        }
        let tracks = Array(zip(urls, loaded)).map { (url: $0.0, loaded: $0.1) }
        /// The set's audio around every transition (two seconds every four
        /// bars from eight before it to eight after its end).
        func heard(_ mix: SetMix) -> [Float] {
            var out: [Float] = []
            let renderer = MixRenderer(snapshot: mix.snapshot(masterGain: 1))
            for t in mix.transitions {
                var at = t.start - 8 * t.barSeconds
                while at < t.end + 8 * t.barSeconds {
                    renderer.setPositionImmediately(Int(max(0, at) * sr))
                    var l = [Float](repeating: 0, count: Int(2 * sr)), r = l
                    renderer.render(left: &l, right: &r, count: l.count)
                    out += l
                    out += r
                    at += 4 * t.barSeconds
                }
            }
            return out
        }
        func differ(_ x: [Float], _ y: [Float]) -> Float {
            guard x.count == y.count else { return .infinity }
            var worst: Float = 0
            for k in x.indices { worst = max(worst, abs(x[k] - y[k])) }
            return worst
        }
        var t = clock()
        let fresh = try await SetBuilder.build(tracks, processor: processor) { _ in }
        let first = clock() - t
        t = clock()
        let again = try await SetBuilder.build(tracks, previous: fresh, processor: processor) { _ in }
        print(String(format: "LIVE build %d songs: %.2f s; again from the last build: %.2f s; differs by %.6f", urls.count, first,
                     clock() - t, differ(heard(fresh), heard(again))))
        XCTAssertLessThan(differ(heard(fresh), heard(again)), 1e-5, "built again, the set isn't the set")
        if tracks.count >= 5 {
            // Two songs change places: the transitions around them are new,
            // the rest is taken over, at other times.
            var moved = tracks
            moved.swapAt(1, 2)
            t = clock()
            let taken = try await SetBuilder.build(moved, previous: fresh, processor: processor) { _ in }
            let quick = clock() - t
            let scratch = try await SetBuilder.build(moved, processor: processor) { _ in }
            print(String(format: "LIVE two songs swapped: %.2f s from the last build; differs from scratch by %.6f", quick,
                         differ(heard(taken), heard(scratch))))
            XCTAssertLessThan(differ(heard(taken), heard(scratch)), 1e-5, "taken over, a moved transition isn't what it was")
            // And back, from that build: taken over a second time, moved again.
            let back = try await SetBuilder.build(tracks, previous: taken, processor: processor) { _ in }
            print(String(format: "LIVE and swapped back: differs from the first build by %.6f", differ(heard(back), heard(fresh))))
            XCTAssertLessThan(differ(heard(back), heard(fresh)), 1e-5, "taken over twice, a transition isn't what it was")
        }

        // Hold and Mix Now, with the playhead in the second song.
        let set = SetSession(persists: false)
        set.add(urls, asListed: true)
        func settle() async throws {
            let deadline = Date().addingTimeInterval(1200)
            repeat {
                try await Task.sleep(nanoseconds: 200_000_000)
                XCTAssertLessThan(Date(), deadline, "timeout")
            } while set.mix == nil || set.buildStatus != nil || (set.liveNote?.hasSuffix("…") ?? false)
        }
        try await settle()
        func around(_ at: Double) -> [Float] {
            let renderer = MixRenderer(snapshot: set.makeSnapshot())
            renderer.setPositionImmediately(Int((at - 1) * sr))
            var l = [Float](repeating: 0, count: Int(6 * sr)), r = l
            renderer.render(left: &l, right: &r, count: l.count)
            return l + r
        }
        for name in ["hold", "mix now"] {
            let old = try XCTUnwrap(set.mix)
            let at = old.transitions[0].end + 4
            set.seek(to: at)
            XCTAssertEqual(set.currentIndex, 1)
            XCTAssertTrue(set.canPlayTheRoom, "\(name): nothing to change at \(Theme.time(at))")
            let was = around(at), out = old.transitions[1]
            t = clock()
            if name == "hold" { set.hold() } else { set.mixNow() }
            try await settle()
            let new = try XCTUnwrap(set.mix)
            let now = new.transitions[1]
            print(String(format: "LIVE %@ at %@: song 2's way out was at %@ (its bar %d), is at %@ (its bar %d), after %.2f s; %@; heard differs by %.6f",
                         name, Theme.time(at), Theme.time(out.begins), out.edit.entryBar, Theme.time(now.begins), now.edit.entryBar,
                         clock() - t, set.liveNote ?? "-", differ(was, around(at))))
            print("LIVE   " + (set.summary(from: 1) ?? "-"))
            if name == "hold" {
                XCTAssertGreaterThanOrEqual(now.edit.entryBar, out.edit.entryBar + 16, "held, it leaves no later")
            } else {
                XCTAssertLessThan(now.start, out.start - 1, "brought in now, the next song comes no sooner")
                XCTAssertGreaterThan(now.begins, at + 3, "and not before it can be got ready")
            }
            XCTAssertEqual(new.transitions[0].start, old.transitions[0].start, accuracy: 1e-6, "\(name): what has played changed")
            XCTAssertEqual(set.transport.seconds, at, accuracy: 1e-6, "\(name): the playhead moved")
            XCTAssertLessThan(differ(was, around(at)), 1e-4, "\(name): the music around the playhead changed")
        }
    }
}
