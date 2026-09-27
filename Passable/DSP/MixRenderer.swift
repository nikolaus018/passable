import Accelerate
import os

/// Immutable description of what to render: the audio of each lane, where it
/// sits on the master timeline, and its automation. The UI builds a fresh one
/// on every edit and hands it to the renderer; the audio thread never sees a
/// half-edited mix.
final class MixSnapshot: @unchecked Sendable {
    struct LaneData {
        let audio: StemAudio?
        /// Master-timeline frame at which the stem's frame 0 plays. May be
        /// negative when a track is cued in partway through.
        let offset: Int
        let envelopes: [Envelope]
        let audible: Bool
        /// Static gain in front of the fader: the deck's level match.
        var trim: Float = 1
        /// Beat rolls on this stem, in master frames, sorted by start.
        var rolls: [FrameRoll] = []
    }

    /// A `Roll` on the master timeline, in frames.
    struct FrameRoll {
        let start: Int, end: Int, anchor: Int, length: Int

        /// nil when it's too short to play.
        init?(_ roll: Roll, sampleRate: Double) {
            start = Int((roll.start * sampleRate).rounded())
            end = Int((roll.end * sampleRate).rounded())
            anchor = Int((roll.anchor * sampleRate).rounded())
            length = Int((roll.length * sampleRate).rounded())
            guard end > start, length >= 2 * MixRenderer.declick else { return nil }
        }
    }

    let lanes: [LaneData]
    /// Master-timeline length in frames.
    let length: Int
    let delaySeconds: Double
    let masterGain: Float
    /// Echo time changes over a set, since each transition echoes in its own
    /// tempo: (master frame from which it applies, seconds), ascending.
    let delaySchedule: [(from: Int, seconds: Double)]

    init(lanes: [LaneData], length: Int, delaySeconds: Double, masterGain: Float,
         delaySchedule: [(from: Int, seconds: Double)] = []) {
        self.lanes = lanes
        self.length = length
        self.delaySeconds = delaySeconds
        self.masterGain = masterGain
        self.delaySchedule = delaySchedule
    }

    static let empty = MixSnapshot(lanes: [], length: 0, delaySeconds: 0.35, masterGain: 1)
}

/// The mixer: per-lane filter + 3-band EQ + fader, post-fader sends to a
/// shared reverb and delay, and a safety limiter. One implementation serves
/// both live preview and the offline render, so what you hear is what you get.
final class MixRenderer: @unchecked Sendable {
    static let blockSize = 64
    /// Frames (~2 ms) over which a roll's every jump is faded out and in,
    /// so its repeats don't click.
    static let declick = 96
    let sampleRate = AudioIO.sampleRate

    private struct LaneDSP {
        var hp = Biquad(), lp = Biquad(), low = Biquad(), low2 = Biquad(), low3 = Biquad(), mid = Biquad(), high = Biquad()
        var filterValue = -1.0, lowValue = -1.0, midValue = -1.0, highValue = -1.0
    }

    private var snapshot: MixSnapshot
    private var lanes: [LaneDSP] = []
    private var reverb: Reverb
    private var delay: PingPongDelay
    private var limiter: Limiter
    private var delaySeconds = 0.0

    private var laneL = [Float](repeating: 0, count: blockSize), laneR = [Float](repeating: 0, count: blockSize)
    private var dryL = [Float](repeating: 0, count: blockSize), dryR = [Float](repeating: 0, count: blockSize)
    private var revL = [Float](repeating: 0, count: blockSize), revR = [Float](repeating: 0, count: blockSize)
    private var dlyL = [Float](repeating: 0, count: blockSize), dlyR = [Float](repeating: 0, count: blockSize)

    /// Render-thread position in master frames.
    private var position = 0

    // Hand-off from the main thread. The render thread only ever *tries* the
    // lock, so it can never block behind the UI.
    private let lock = OSAllocatedUnfairLock()
    private var pendingSnapshot: MixSnapshot?
    private var pendingSeek: Int?
    private var publishedPosition = 0
    private var retired: [MixSnapshot] = []

    init(snapshot: MixSnapshot = .empty) {
        self.snapshot = snapshot
        reverb = Reverb(sampleRate: sampleRate)
        delay = PingPongDelay(sampleRate: sampleRate)
        limiter = Limiter(sampleRate: sampleRate)
        retired.reserveCapacity(256)
        // Sized up front (four lanes a song, sets of up to 128 songs) so no
        // real snapshot makes the render thread allocate.
        lanes = Array(repeating: LaneDSP(), count: max(512, snapshot.lanes.count))
        prepare(for: snapshot)
    }

    // MARK: Main-thread API

    func setSnapshot(_ snapshot: MixSnapshot) {
        lock.withLock {
            pendingSnapshot = snapshot
            // Snapshots replaced on the render thread are freed here instead;
            // keeping the capacity means the render thread's append never
            // allocates.
            retired.removeAll(keepingCapacity: true)
        }
    }

    func seek(to frame: Int) {
        lock.withLock {
            pendingSeek = max(0, frame)
            publishedPosition = max(0, frame)
        }
    }

    var currentFrame: Int { lock.withLock { publishedPosition } }

    // MARK: Rendering

    /// Renders `count` frames at the current position and advances it.
    func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, count: Int) {
        if lock.lockIfAvailable() {
            if let next = pendingSnapshot {
                retired.append(snapshot)
                snapshot = next
                pendingSnapshot = nil
                prepare(for: next)
            }
            if let seek = pendingSeek {
                position = seek
                pendingSeek = nil
                resetTails()
            }
            lock.unlock()
        }

        var done = 0
        while done < count {
            let n = min(Self.blockSize, count - done)
            renderBlock(left: left + done, right: right + done, count: n)
            done += n
            position += n
        }

        if lock.lockIfAvailable() {
            if pendingSeek == nil { publishedPosition = position }
            lock.unlock()
        }
    }

    /// Offline use: jump straight to a frame with no hand-off.
    func setPositionImmediately(_ frame: Int) {
        position = frame
        resetTails()
    }

    private func prepare(for snapshot: MixSnapshot) {
        if lanes.count < snapshot.lanes.count {
            lanes = Array(repeating: LaneDSP(), count: snapshot.lanes.count)
        }
        if snapshot.delaySchedule.isEmpty && snapshot.delaySeconds != delaySeconds {
            delaySeconds = snapshot.delaySeconds
            delay.setTime(seconds: delaySeconds, sampleRate: sampleRate)
        }
    }

    /// Silences effect tails and filter state after a jump, in place: this
    /// runs on the render thread, so nothing may be allocated.
    private func resetTails() {
        reverb.reset()
        delay.reset()
        for i in lanes.indices { lanes[i] = LaneDSP() }
    }

    private func renderBlock(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, count n: Int) {
        let snap = snapshot
        if !snap.delaySchedule.isEmpty {
            var seconds = snap.delaySchedule[0].seconds
            for entry in snap.delaySchedule where entry.from <= position { seconds = entry.seconds }
            if seconds != delaySeconds {
                delaySeconds = seconds
                delay.setTime(seconds: seconds, sampleRate: sampleRate)
            }
        }
        let t0 = Double(position) / sampleRate
        let t1 = Double(position + n) / sampleRate
        let tm = (t0 + t1) / 2

        laneL.withUnsafeMutableBufferPointer { lL in
        laneR.withUnsafeMutableBufferPointer { lR in
        dryL.withUnsafeMutableBufferPointer { dL in
        dryR.withUnsafeMutableBufferPointer { dR in
        revL.withUnsafeMutableBufferPointer { rL in
        revR.withUnsafeMutableBufferPointer { rR in
        dlyL.withUnsafeMutableBufferPointer { eL in
        dlyR.withUnsafeMutableBufferPointer { eR in
            let ll = lL.baseAddress!, lr = lR.baseAddress!
            dL.baseAddress!.update(repeating: 0, count: n)
            dR.baseAddress!.update(repeating: 0, count: n)
            rL.baseAddress!.update(repeating: 0, count: n)
            rR.baseAddress!.update(repeating: 0, count: n)
            eL.baseAddress!.update(repeating: 0, count: n)
            eR.baseAddress!.update(repeating: 0, count: n)

            for (i, lane) in snap.lanes.enumerated() {
                guard lane.audible, let audio = lane.audio else { continue }
                let src = position - lane.offset
                guard src + n > 0, src < audio.count else { continue }

                // Copy the stem's frames for this block, zero outside the file.
                if lane.rolls.contains(where: { $0.start - Self.declick < position + n && $0.end + Self.declick > position }) {
                    Self.copyRolled(lane, audio: audio, from: position, count: n, left: ll, right: lr)
                } else {
                    ll.update(repeating: 0, count: n)
                    lr.update(repeating: 0, count: n)
                    let lo = max(0, -src), hi = min(n, audio.count - src)
                    (ll + lo).update(from: audio.left.pointer + src + lo, count: hi - lo)
                    (lr + lo).update(from: audio.right.pointer + src + lo, count: hi - lo)
                }

                updateFilters(lane: i, envelopes: lane.envelopes, at: tm)
                lanes[i].hp.process(ll, lr, count: n)
                lanes[i].lp.process(ll, lr, count: n)
                lanes[i].low.process(ll, lr, count: n)
                lanes[i].low2.process(ll, lr, count: n)
                lanes[i].low3.process(ll, lr, count: n)
                lanes[i].mid.process(ll, lr, count: n)
                lanes[i].high.process(ll, lr, count: n)

                // Fader, ramped across the block so fades are sample-smooth.
                var g0 = LaneParameter.gain(value(lane.envelopes, .volume, t0)) * lane.trim
                var step = (LaneParameter.gain(value(lane.envelopes, .volume, t1)) * lane.trim - g0) / Float(n)
                guard g0 > 0 || step != 0 else { continue }
                vDSP_vrampmul2(ll, lr, 1, &g0, &step, ll, lr, 1, vDSP_Length(n))

                vDSP_vadd(ll, 1, dL.baseAddress!, 1, dL.baseAddress!, 1, vDSP_Length(n))
                vDSP_vadd(lr, 1, dR.baseAddress!, 1, dR.baseAddress!, 1, vDSP_Length(n))

                var rev = LaneParameter.gain(value(lane.envelopes, .reverb, tm))
                if rev > 0 {
                    vDSP_vsma(ll, 1, &rev, rL.baseAddress!, 1, rL.baseAddress!, 1, vDSP_Length(n))
                    vDSP_vsma(lr, 1, &rev, rR.baseAddress!, 1, rR.baseAddress!, 1, vDSP_Length(n))
                }
                var dly = LaneParameter.gain(value(lane.envelopes, .delay, tm))
                if dly > 0 {
                    vDSP_vsma(ll, 1, &dly, eL.baseAddress!, 1, eL.baseAddress!, 1, vDSP_Length(n))
                    vDSP_vsma(lr, 1, &dly, eR.baseAddress!, 1, eR.baseAddress!, 1, vDSP_Length(n))
                }
            }

            reverb.process(rL.baseAddress!, rR.baseAddress!, count: n)
            delay.process(eL.baseAddress!, eR.baseAddress!, count: n)

            vDSP_vadd(dL.baseAddress!, 1, rL.baseAddress!, 1, left, 1, vDSP_Length(n))
            vDSP_vadd(left, 1, eL.baseAddress!, 1, left, 1, vDSP_Length(n))
            vDSP_vadd(dR.baseAddress!, 1, rR.baseAddress!, 1, right, 1, vDSP_Length(n))
            vDSP_vadd(right, 1, eR.baseAddress!, 1, right, 1, vDSP_Length(n))
            var master = snap.masterGain
            vDSP_vsmul(left, 1, &master, left, 1, vDSP_Length(n))
            vDSP_vsmul(right, 1, &master, right, 1, vDSP_Length(n))
            limiter.process(left, right, count: n)
        }}}}}}}}
    }

    /// A block of a stem that rolls: inside a roll, frames come from its
    /// loop; everywhere else from where the stem really is. Every jump is
    /// faded out and back in over `declick` frames.
    private static func copyRolled(_ lane: MixSnapshot.LaneData, audio: StemAudio, from position: Int, count n: Int,
                                   left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        let xf = Float(declick)
        for j in 0..<n {
            let p = position + j
            var s = p - lane.offset
            var g: Float = 1
            for r in lane.rolls {
                if p >= r.start && p < r.end {
                    let phase = (p - r.start) % r.length
                    s = r.anchor - lane.offset + phase
                    g = min(g, Float(min(phase, r.length - phase, r.end - p)) / xf)
                } else if p >= r.start - declick && p < r.start {
                    g = min(g, Float(r.start - p) / xf)
                } else if p >= r.end && p < r.end + declick {
                    g = min(g, Float(p - r.end) / xf)
                }
            }
            if s >= 0 && s < audio.count {
                left[j] = audio.left.pointer[s] * g
                right[j] = audio.right.pointer[s] * g
            } else {
                left[j] = 0
                right[j] = 0
            }
        }
    }

    @inline(__always)
    private func value(_ envelopes: [Envelope], _ p: LaneParameter, _ t: Double) -> Double {
        envelopes[p.rawValue].value(at: t, default: p.defaultValue)
    }

    private func updateFilters(lane i: Int, envelopes: [Envelope], at t: Double) {
        let sr = sampleRate
        // Work on a copy: two inout borrows of `lanes[i]` at once would overlap.
        var dsp = lanes[i]
        defer { lanes[i] = dsp }
        let f = value(envelopes, .filter, t)
        if abs(f - dsp.filterValue) > 1e-5 {
            dsp.filterValue = f
            switch LaneParameter.filter(f) {
            case .bypass:
                dsp.hp.bypass(); dsp.lp.bypass()
            case .lowPass(let hz):
                dsp.hp.bypass()
                dsp.lp.set(.lowPass(frequency: hz, q: 1.0), sampleRate: sr)
            case .highPass(let hz):
                dsp.lp.bypass()
                dsp.hp.set(.highPass(frequency: hz, q: 1.0), sampleRate: sr)
            }
        }
        // Where a DJ mixer's low knob sits: a kill takes the kick and the
        // bass line (what only one song may own at a time) and leaves the
        // body of everything else, so a song under the other still sounds
        // like itself rather than a thin shadow. A shelf deep enough to
        // kill 50 Hz also takes 10 dB off 200 Hz, so a kill is an
        // isolator's steep high-pass instead, at the 150 Hz where the
        // planner splits low from high (6th-order Butterworth: −52 dB at
        // 55, −33 at 80, −21 at 100, −0.6 at 175, −0.1 at 200); cuts
        // short of that and boosts are the shelf.
        let low = value(envelopes, .low, t)
        if abs(low - dsp.lowValue) > 1e-5 {
            dsp.lowValue = low
            let db = LaneParameter.eqDecibels(low)
            if db <= Self.killDB {
                dsp.low.set(.highPass(frequency: 150, q: 0.5176), sampleRate: sr)
                dsp.low2.set(.highPass(frequency: 150, q: 0.7071), sampleRate: sr)
                dsp.low3.set(.highPass(frequency: 150, q: 1.9319), sampleRate: sr)
            } else if abs(db) < 0.05 {
                dsp.low.bypass()
                dsp.low2.bypass()
                dsp.low3.bypass()
            } else {
                dsp.low.set(.lowShelf(frequency: 120, gainDB: db), sampleRate: sr)
                dsp.low2.bypass()
                dsp.low3.bypass()
            }
        }
        Self.updateBand(&dsp.mid, cached: &dsp.midValue, value(envelopes, .mid, t), sr) {
            // Broad, like a DJ mixer's mid: from the low mids to the
            // presence, where a song's body and hooks sit.
            .peak(frequency: 800, q: 0.5, gainDB: $0)
        }
        Self.updateBand(&dsp.high, cached: &dsp.highValue, value(envelopes, .high, t), sr) {
            .highShelf(frequency: 3_500, gainDB: $0)
        }
    }

    /// A low band this far down is a kill (see `updateFilters`).
    static let killDB = -24.0

    @inline(__always)
    private static func updateBand(_ filter: inout Biquad, cached: inout Double, _ v: Double, _ sr: Double,
                                   _ kind: (Double) -> Biquad.Kind) {
        guard abs(v - cached) > 1e-5 else { return }
        cached = v
        let db = LaneParameter.eqDecibels(v)
        if abs(db) < 0.05 {
            filter.bypass()
        } else {
            filter.set(kind(db), sampleRate: sr)
        }
    }
}
