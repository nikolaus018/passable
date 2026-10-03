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

final class BeatLampTests: XCTestCase {
    func testCleansTheAddress() {
        XCTAssertEqual(BeatLamp.clean(" http://192.168.1.20/ "), "192.168.1.20")
        XCTAssertEqual(BeatLamp.clean("shelly.local:80/rpc"), "shelly.local:80")
    }

    /// Flashes land on the beats, early by the lead, each "on" followed by its "off".
    func testFlashesOnTheBeats() async throws {
        let server = FakeShelly()
        server.start()
        let start = Date()
        let lamp = BeatLamp(position: { Date().timeIntervalSince(start) }, isPlaying: { true })
        // 120 BPM from 1 s: beats every 0.5 s, a downbeat every fourth.
        lamp.setBeats((0..<16).map { .init(time: 1 + 0.5 * Double($0), isDownbeat: $0 % 4 == 0) })
        let connected = expectation(description: "connected")
        lamp.configure(host: "127.0.0.1:\(server.port)", every: .beat) { text in
            if text.hasPrefix("Connected") { connected.fulfill() }
        }
        await fulfillment(of: [connected], timeout: 5)
        try await Task.sleep(nanoseconds: 4_500_000_000)
        lamp.off()
        let ons = server.log.filter(\.on)
        XCTAssertGreaterThanOrEqual(ons.count, 6)
        // A local device answers in a millisecond or two: the lead is the relay's.
        XCTAssertEqual(lamp.lead, 0.015, accuracy: 0.015)
        // Compare against the beat the flash belongs to, on the clock the lamp read.
        let t0 = start.timeIntervalSince(server.origin)
        for (i, e) in ons.prefix(6).enumerated() {
            let beat = 1 + 0.5 * Double(i)
            let early = beat - (e.time - t0)
            XCTAssertEqual(early, lamp.lead, accuracy: 0.03, "flash \(i)")
        }
        // Strictly alternating on/off.
        let all = server.log
        for (a, b) in zip(all, all.dropFirst()) where a.on == b.on { XCTFail("\(a) then \(b)") }
    }

    func testBarsOnlyFlashesDownbeats() async throws {
        let server = FakeShelly()
        server.start()
        let start = Date()
        let lamp = BeatLamp(position: { Date().timeIntervalSince(start) }, isPlaying: { true })
        lamp.setBeats((0..<16).map { .init(time: 0.5 + 0.25 * Double($0), isDownbeat: $0 % 4 == 0) })
        let connected = expectation(description: "connected")
        lamp.configure(host: "127.0.0.1:\(server.port)", every: .bar) { if $0.hasPrefix("Connected") { connected.fulfill() } }
        await fulfillment(of: [connected], timeout: 5)
        try await Task.sleep(nanoseconds: 4_500_000_000)
        lamp.off()
        XCTAssertEqual(server.log.filter(\.on).count, 4)
    }
}
