import XCTest
@testable import Passable

/// Not a unit test: times each stage of getting a set ready for the songs
/// listed in $PASSABLE_PERF (stems already separated). Skipped unless set.
final class PerfLab: XCTestCase {
    func testStages() async throws {
        guard let listFile = ProcessInfo.processInfo.environment["PASSABLE_PERF"],
              let list = try? String(contentsOfFile: listFile, encoding: .utf8) else {
            throw XCTSkip("set PASSABLE_PERF")
        }
        let urls = list.split(separator: "\n").map(String.init).filter { !$0.isEmpty }.map { URL(fileURLWithPath: $0) }
        let processor = TrackProcessor()
        func clock() -> Double { ProcessInfo.processInfo.systemUptime }

        var t = clock()
        var loaded: [TrackProcessor.Loaded] = []
        for url in urls {
            loaded.append(try await withCheckedThrowingContinuation { c in
                processor.load(url, ticket: .init(), progress: { _ in }) { c.resume(with: $0) }
            })
        }
        print(String(format: "PERF load (cached) %d songs: %.2f s", urls.count, clock() - t))

        t = clock()
        _ = TrackAnalyzer.analyze(stems: loaded[0].stems)
        print(String(format: "PERF analyze one song: %.2f s", clock() - t))
        t = clock()
        _ = TrackStructure.measure(stems: loaded[0].stems, grid: loaded[0].analysis.grid)
        print(String(format: "PERF   of which structure: %.2f s", clock() - t))

        let analyses = loaded.map(\.analysis)
        t = clock()
        let costs = SetOrdering.costMatrix(analyses)
        print(String(format: "PERF cost matrix %dx%d: %.2f s", costs.count, costs.count, clock() - t))
        t = clock()
        _ = SetOrdering.order(costs)
        print(String(format: "PERF order: %.2f s", clock() - t))

        t = clock()
        _ = try await SetBuilder.build(Array(zip(urls, loaded)).map { (url: $0.0, loaded: $0.1) }, processor: processor) { _ in }
        print(String(format: "PERF build set: %.2f s", clock() - t))
        t = clock()
        _ = try await SetBuilder.build(Array(zip(urls, loaded)).map { (url: $0.0, loaded: $0.1) }, processor: processor) { _ in }
        print(String(format: "PERF build set again (renditions cached on disk): %.2f s", clock() - t))
        // A fresh separation of one song.
        let mix = try AudioIO.loadStereo(url: urls[0])
        t = clock()
        _ = try StemSeparator().separate(mix, progress: { _ in })
        print(String(format: "PERF separate one song (%.0f s of audio): %.2f s", Double(mix.count) / AudioIO.sampleRate, clock() - t))
    }
}
