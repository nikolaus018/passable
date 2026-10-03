import Network
import XCTest
@testable import Passable

/// A stand-in for a Shelly Gen2 plug: answers /shelly and logs each switch.
private final class FakeShelly: @unchecked Sendable {
    private let listener = try! NWListener(using: .tcp, on: .any)
    private let lock = NSLock()
    private(set) var events: [(time: Double, on: Bool)] = []
    let origin = Date()

    var port: UInt16 { listener.port?.rawValue ?? 0 }

    func start() {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [self] c in
            c.start(queue: .global())
            c.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                let line = String(data: data ?? Data(), encoding: .utf8)?.components(separatedBy: "\r\n").first ?? ""
                var body = "{}"
                if line.contains("/rpc/Switch.Set") {
                    lock.withLock { events.append((Date().timeIntervalSince(origin), line.contains("on=true"))) }
                    if line.contains("toggle_after") {
                        // A pulse: the plug switches itself off again.
                        let at = Date().timeIntervalSince(origin) + 0.05
                        lock.withLock { events.append((at, false)) }
                    }
                    body = "{\"was_on\":false}"
                } else if line.contains("/shelly") {
                    body = "{\"id\":\"shellyplus1-aa\",\"gen\":2}"
                }
                let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                c.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in c.cancel() })
            }
        }
        listener.start(queue: .global())
        ready.wait()
    }

    var log: [(time: Double, on: Bool)] { lock.withLock { events } }
}

/// A clock that starts when told to (the music starts once the lamp is connected).
private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var origin = Date()
    func restart() { lock.withLock { origin = Date() } }
    var seconds: Double { lock.withLock { Date().timeIntervalSince(origin) } }
    var started: Date { lock.withLock { origin } }
}

final class BeatLampTests: XCTestCase {
    func testCleansTheAddress() {
        XCTAssertEqual(BeatLamp.clean(" http://192.168.1.20/ "), "192.168.1.20")
        XCTAssertEqual(BeatLamp.clean("shelly.local:80/rpc"), "shelly.local:80")
    }

    /// Flashes land on the beats, early by the lead, each "on" followed by its "off".
    func testFlashesOnTheBeats() async throws {
        let server = FakeShelly()
        server.start()
        let clock = Clock()
        let lamp = BeatLamp(position: { clock.seconds }, isPlaying: { true })
        // 120 BPM from 1 s: beats every 0.5 s, a downbeat every fourth.
        lamp.setBeats((0..<16).map { .init(time: 1 + 0.5 * Double($0), inBar: $0 % 4) })
        let connected = expectation(description: "connected")
        lamp.configure(host: "127.0.0.1:\(server.port)", every: .beat) { text in
            if text.hasPrefix("Connected") { connected.fulfill() }
        }
        await fulfillment(of: [connected], timeout: 5)
        clock.restart()
        try await Task.sleep(nanoseconds: 4_500_000_000)
        lamp.off()
        lamp.configure(host: nil, every: .beat)
        let ons = server.log.filter(\.on)
        XCTAssertGreaterThanOrEqual(ons.count, 6)
        // A local device answers in a millisecond or two: the lead is the relay's.
        XCTAssertEqual(lamp.lead, 0.015, accuracy: 0.015)
        // Compare against the beat the flash belongs to, on the clock the lamp read.
        let t0 = clock.started.timeIntervalSince(server.origin)
        for (i, e) in ons.prefix(6).enumerated() {
            let beat = 1 + 0.5 * Double(i)
            let early = beat - (e.time - t0)
            XCTAssertEqual(early, lamp.lead, accuracy: 0.03, "flash \(i)")
        }
        // An "on" is always followed by an "off" before the next "on".
        let all = server.log
        for (a, b) in zip(all, all.dropFirst()) where a.on && b.on { XCTFail("two ons in a row: \(a) then \(b)") }
    }

    func testBarsOnlyFlashesDownbeats() async throws {
        let server = FakeShelly()
        server.start()
        let clock = Clock()
        let lamp = BeatLamp(position: { clock.seconds }, isPlaying: { true })
        lamp.setBeats((0..<16).map { .init(time: 0.5 + 0.25 * Double($0), inBar: $0 % 4) })
        let connected = expectation(description: "connected")
        lamp.configure(host: "127.0.0.1:\(server.port)", every: .bar) { if $0.hasPrefix("Connected") { connected.fulfill() } }
        await fulfillment(of: [connected], timeout: 5)
        clock.restart()
        try await Task.sleep(nanoseconds: 4_500_000_000)
        lamp.off()
        lamp.configure(host: nil, every: .beat)
        XCTAssertEqual(server.log.filter(\.on).count, 4)
    }

    /// A drop at 20 s, 128 BPM: the build speeds up into a dark beat, then eight flashes.
    func testBuildAndDropStrobes() {
        let bar = 60.0 / 128 * 4
        let (quiet, accents) = BeatLamp.strobes(stutters: [], drops: [(at: 20, bar: bar)])
        let a = accents.sorted()
        let gaps = zip(a, a.dropFirst()).map { $1 - $0 }
        XCTAssertGreaterThanOrEqual(gaps.min() ?? 0, BeatLamp.fastest * 0.95 - 1e-9, "never faster than the relay")
        let beat = bar / 4
        let build = a.filter { $0 < 20 - beat }
        XCTAssertGreaterThan(build.count, 8, "builds up over two bars")
        // Speeding up: each gap in the build no longer than the one before.
        let buildGaps = zip(build, build.dropFirst()).map { $1 - $0 }
        for (x, y) in zip(buildGaps, buildGaps.dropFirst()) { XCTAssertLessThanOrEqual(y, x + 1e-9) }
        XCTAssertTrue(a.allSatisfy { !($0 > 20 - beat + 1e-6 && $0 < 20 - 1e-6) }, "dark beat before the drop")
        XCTAssertEqual(a.filter { $0 >= 20 - 1e-6 }.count, 8)
        XCTAssertTrue(quiet.contains { $0.contains(20 - beat / 2) })
    }

    /// A roll in the middle of a build can't push flashes past the relay's pace.
    func testOverlappingStrobesStayAtTheRelayPace() {
        let bar = 60.0 / 128 * 4
        let s = BeatLamp.strobes(stutters: [(start: 20 - 2 * bar, end: 20 - bar / 4, length: 0.06)], drops: [(at: 20, bar: bar)])
        let a = s.accents
        XCTAssertGreaterThan(a.count, 10)
        XCTAssertGreaterThanOrEqual(zip(a, a.dropFirst()).map { $1 - $0 }.min() ?? 1, BeatLamp.fastest * 0.95 - 1e-9)
    }

    /// Strobe accents fire whatever the flash setting, and are cut short.
    func testAccentsAlwaysFlash() async throws {
        let server = FakeShelly()
        server.start()
        let clock = Clock()
        let lamp = BeatLamp(position: { clock.seconds }, isPlaying: { true })
        var list = (0..<8).map { BeatLamp.Beat(time: 1.5 + 0.25 * Double($0), inBar: $0 % 4) }
        list += [2.1, 2.3, 2.7].map(BeatLamp.Beat.accent)
        lamp.setBeats(list.sorted { $0.time < $1.time })
        let connected = expectation(description: "connected")
        lamp.configure(host: "127.0.0.1:\(server.port)", every: .bar) { if $0.hasPrefix("Connected") { connected.fulfill() } }
        await fulfillment(of: [connected], timeout: 5)
        clock.restart()
        try await Task.sleep(nanoseconds: 4_000_000_000)
        lamp.off()
        lamp.configure(host: nil, every: .beat)
        // Two downbeats plus the three accents.
        XCTAssertEqual(server.log.filter(\.on).count, 5)
    }
}
