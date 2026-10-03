import Foundation

/// A smart plug or lamp on the network that flashes on the beat of whatever
/// the set is playing. Shelly (Gen1, Gen2 and later) and Tasmota switches
/// are spoken to over plain HTTP on the local network.
///
/// The beats come from the set's own grids, mapped onto the master clock, so
/// the lamp follows tempo glides and transitions exactly as the music does.
/// A timing thread reads the renderer's position and sends each command a
/// little ahead of its beat (`lead`). The lead is measured, not set: it's
/// the network round trip to the device (re-measured on every command) plus
/// its relay, less the time the audio takes to come out of the speakers.
final class BeatLamp: @unchecked Sendable {
    enum Every: String, CaseIterable, Identifiable {
        case beat = "Every beat", other = "Every 2nd beat", bar = "Every bar"
        var id: String { rawValue }
        var step: Int { self == .beat ? 1 : self == .other ? 2 : 4 }
    }

    enum Kind { case shellyGen1, shellyRPC, tasmota }

    struct Beat { let time: Double; let isDownbeat: Bool }

    // MARK: Settings (UserDefaults)

    static let hostKey = "lampHost", everyKey = "lampEvery", enabledKey = "lampOn"
    /// Seconds a relay takes to switch after it has the command.
    private static let relayDelay = 0.015

    // MARK: State (guarded by `lock`)

    private let lock = NSLock()
    private var beats: [Beat] = []
    private var host: String?
    private var kind: Kind?
    private var every = Every.beat
    /// Smoothed round trip to the device, seconds.
    private var roundTrip = 0.03
    private var outputLatency = 0.0
    private var latencyChecked = -1.0
    private var timer: DispatchSourceTimer?
    private var next = 0
    private var lastSeconds = -1.0
    private var offAt: Double?
    private var lampIsOn = false

    private let position: @Sendable () -> Double
    private let isPlaying: @Sendable () -> Bool
    private let audioLatency: @Sendable () -> Double
    private let session: URLSession
    private let queue = DispatchQueue(label: "passable.lamp", qos: .userInteractive)
    private let net = DispatchQueue(label: "passable.lamp.net")

    /// - Parameters:
    ///   - position: the master clock, seconds, as the renderer has it.
    ///   - isPlaying: whether the music is running.
    ///   - audioLatency: seconds between rendering a sample and hearing it.
    init(position: @escaping @Sendable () -> Double, isPlaying: @escaping @Sendable () -> Bool,
         audioLatency: @escaping @Sendable () -> Double = { 0 }) {
        self.position = position
        self.isPlaying = isPlaying
        self.audioLatency = audioLatency
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 1.5
        c.httpMaximumConnectionsPerHost = 1
        c.waitsForConnectivity = false
        session = URLSession(configuration: c)
    }

    deinit { timer?.cancel() }

    // MARK: Beats

    /// The beats of the whole set in master seconds: each song's own grid
    /// while it's the one playing, handing over midway through a blend.
    static func beats(of mix: SetMix) -> [Beat] {
        var out: [Beat] = []
        for (i, track) in mix.tracks.enumerated() {
            let from = i > 0 && mix.transitions.indices.contains(i - 1)
                ? (mix.transitions[i - 1].start + mix.transitions[i - 1].end) / 2 : 0
            let to = i < mix.transitions.count ? (mix.transitions[i].start + mix.transitions[i].end) / 2 : .infinity
            let grid = track.loaded.analysis.grid
            // (Skipped bars of a club edit are never played.)
            for k in 0..<200_000 {
                let own = grid.beat(k)
                if let s = track.skip, own >= s.from, own < s.to { continue }
                let t = track.master(own)
                if t >= to || t > mix.length + 1 { break }
                if t >= from { out.append(Beat(time: t, isDownbeat: k % 4 == 0)) }
            }
        }
        return out.sorted { $0.time < $1.time }
    }

    func setBeats(_ list: [Beat]) {
        lock.withLock { beats = list; next = 0; lastSeconds = -1 }
    }

    // MARK: Configuration

    /// Points the lamp at a device (an IP address, host name or full URL;
    /// nil turns it off), finding out what kind of switch it is.
    func configure(host raw: String?, every: Every, completion: (@Sendable (String) -> Void)? = nil) {
        lock.withLock { self.every = every }
        let cleaned = raw.map(Self.clean) ?? ""
        guard !cleaned.isEmpty else {
            off()
            lock.withLock { host = nil; kind = nil }
            stopTimer()
            completion?("Off")
            return
        }
        if lock.withLock({ host == cleaned && kind != nil }) {
            startTimer()
            completion?("Connected")
            return
        }
        off()
        lock.withLock { host = nil; kind = nil }
        Task {
            let found = await self.detect(cleaned)
            if found != nil { await self.measure(cleaned) }
            self.lock.withLock { self.host = found == nil ? nil : cleaned; self.kind = found }
            if found != nil { self.startTimer() } else { self.stopTimer() }
            completion?(found.map(Self.describe) ?? "No Shelly or Tasmota switch answered at \(cleaned)")
        }
    }

    private static func describe(_ k: Kind) -> String {
        switch k {
        case .shellyGen1: return "Connected · Shelly"
        case .shellyRPC: return "Connected · Shelly"
        case .tasmota: return "Connected · Tasmota"
        }
    }

    /// "192.168.1.20", "http://192.168.1.20/" and "shelly-plug.local:80" all
    /// come down to the host part.
    static func clean(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for p in ["http://", "https://"] where s.lowercased().hasPrefix(p) { s.removeFirst(p.count) }
        if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
        return s
    }

    private func get(_ host: String, _ path: String) async -> Data? {
        guard let url = URL(string: "http://\(host)\(path)") else { return nil }
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    /// How long the device takes to answer, from a few quick requests.
    private func measure(_ host: String) async {
        var times: [Double] = []
        for _ in 0..<5 {
            let t = Date()
            if await get(host, "/shelly") != nil { times.append(Date().timeIntervalSince(t)) }
        }
        // (The first pays for the connection: leave it out.)
        let rest = times.dropFirst().sorted()
        if !rest.isEmpty { lock.withLock { roundTrip = rest[rest.count / 2] } }
    }

    /// Seconds ahead of its beat a command is sent: out to the device and
    /// switched, less what the sound itself takes to come out.
    var lead: Double {
        lock.withLock { max(0, roundTrip / 2 + Self.relayDelay - outputLatency) }
    }

    private func detect(_ host: String) async -> Kind? {
        if let data = await get(host, "/shelly"),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return (json["gen"] as? Int ?? 1) >= 2 ? .shellyRPC : .shellyGen1
        }
        if let data = await get(host, "/cm?cmnd=Power"),
           let text = String(data: data, encoding: .utf8), text.contains("POWER") { return .tasmota }
        return nil
    }

    // MARK: Switching

    private func send(_ on: Bool) {
        let (host, kind) = lock.withLock { (self.host, self.kind) }
        guard let host, let kind else { return }
        let path: String
        switch kind {
        case .shellyGen1: path = "/relay/0?turn=\(on ? "on" : "off")"
        case .shellyRPC: path = "/rpc/Switch.Set?id=0&on=\(on)"
        case .tasmota: path = "/cm?cmnd=Power%20\(on ? "On" : "Off")"
        }
        guard let url = URL(string: "http://\(host)\(path)") else { return }
        lock.withLock { lampIsOn = on }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1
        // One at a time and in order: an "off" must never overtake its "on".
        net.async { [session, weak self] in
            let done = DispatchSemaphore(value: 0)
            let began = Date()
            session.dataTask(with: request) { _, response, _ in
                if (response as? HTTPURLResponse)?.statusCode == 200 {
                    self?.lock.withLock {
                        let rtt = Date().timeIntervalSince(began)
                        self?.roundTrip += 0.2 * (min(rtt, 0.5) - (self?.roundTrip ?? rtt))
                    }
                }
                done.signal()
            }.resume()
            _ = done.wait(timeout: .now() + 1.2)
        }
    }

    /// One short flash, to check the connection.
    func flash() {
        send(true)
        queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.send(false) }
    }

    /// Leaves the lamp dark (`wait`: until the device has been told, for
    /// when the app is quitting).
    func off(wait: Bool = false) {
        let wasOn = lock.withLock { () -> Bool in
            defer { offAt = nil }
            return lampIsOn
        }
        guard wasOn else { return }
        send(false)
        if wait { net.sync {} }
    }

    // MARK: Timing

    private func startTimer() {
        lock.lock(); defer { lock.unlock() }
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(4), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func stopTimer() {
        lock.lock(); defer { lock.unlock() }
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        guard isPlaying() else {
            off()
            lock.withLock { lastSeconds = -1 }
            return
        }
        let now = position()
        // The audio's own delay changes with the output (Bluetooth, cables).
        if now - latencyChecked > 1 || now < latencyChecked {
            let l = audioLatency()
            lock.withLock { outputLatency = min(l, 0.5); latencyChecked = now }
        }
        let lead = self.lead
        var fire = false
        var turnOff = false
        lock.withLock {
            let target = now + lead
            // A seek (or a rebuild) moved the clock: find the beat again.
            if lastSeconds < 0 || now < lastSeconds || now - lastSeconds > 0.5 {
                next = Self.firstIndex(beats, after: target - 0.02)
                offAt = nil
            }
            lastSeconds = now
            while next < beats.count, beats[next].time <= target {
                let b = beats[next]
                let index = next
                next += 1
                // Late for it (a stall): leave it.
                guard b.time > target - 0.15 else { continue }
                let wanted = every.step == 1 || (every.step == 4 ? b.isDownbeat : Self.isEven(index, beats))
                guard wanted else { continue }
                fire = true
                let gap = next < beats.count ? beats[next].time - b.time : 0.5
                // On for the first part of the beat, dark for the rest: a
                // slice of the gap between flashes, so it reads as a pulse.
                let span = every.step == 1 ? gap : every.step == 2 ? gap * 2 : gap * 4
                offAt = b.time + min(0.25, max(0.06, span * 0.35))
            }
            if let o = offAt, target >= o, !fire { turnOff = true; offAt = nil }
        }
        if fire { send(true) } else if turnOff { send(false) }
    }

    /// Every second beat of a bar: the 1 and the 3 (counted from the
    /// downbeat before it, so it stays on the groove across bars).
    private static func isEven(_ index: Int, _ beats: [Beat]) -> Bool {
        var n = 0, i = index
        while i > 0, !beats[i].isDownbeat, n < 4 { i -= 1; n += 1 }
        return beats[i].isDownbeat ? n % 2 == 0 : true
    }

    private static func firstIndex(_ beats: [Beat], after t: Double) -> Int {
        var lo = 0, hi = beats.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if beats[mid].time < t { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}
