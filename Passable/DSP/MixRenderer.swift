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
        /// Vocal lane: when singing dry (not feeding effects), gently ducks
        /// the shared reverb/delay wet returns so outgoing tails tuck behind
        /// the incoming voice instead of smearing over its first words.
        var isVocal: Bool = false
        /// Track index within a set (−1 in single-lane tests): used to engage
        /// blend-only bus glue, inter-deck kick pocketing, and vocal-bleed
        /// mid-dipping only while two songs overlap, keeping solo playback
        /// bit-exact.
        var trackIndex: Int = -1
        var isOther: Bool = false
        var isDrums: Bool = false
    }

    /// A `Roll` on the master timeline, in frames.
    struct FrameRoll {
        let start: Int, end: Int, anchor: Int, length: Int
        /// Frames over which each repeat of a loop is crossfaded in out of
        /// what the pass before runs on into; 0 for a stutter, whose
        /// repeats start from nothing.
        let crossfade: Int
        /// Vinyl brake / tape stop decelerating to 0 speed across `start..<end`.
        let brake: Bool
        /// Turntable spinback accelerating backward across `start..<end`.
        let spinback: Bool

        /// nil when it's too short to play.
        init?(_ roll: Roll, sampleRate: Double) {
            start = Int((roll.start * sampleRate).rounded())
            end = Int((roll.end * sampleRate).rounded())
            anchor = Int((roll.anchor * sampleRate).rounded())
            length = Int((roll.length * sampleRate).rounded())
            brake = roll.brake == true
            spinback = roll.spinback == true && !brake
            guard end > start, brake || spinback || length >= 2 * MixRenderer.declick else { return nil }
            crossfade = roll.seamless == true && !brake && !spinback ? min(MixRenderer.loopCrossfade, length / 4) : 0
        }
    }

    /// A stereo club air riser, 808 sub-impact boom, and crash downlifter around
    /// a drop moment, in master frames.
    struct FrameSweep {
        let start: Int, drop: Int, end: Int, cutBeforeDrop: Int
        /// Frame until which peak Club PA drop punch stays active after `drop`.
        var punchEnd: Int = 0
        /// 1.0 = subtle club air; 1.35–1.75 = club/stadium riser & sub-impact punch.
        var intensity: Float = 1.0
    }

    let lanes: [LaneData]
    /// Master-timeline length in frames.
    let length: Int
    let delaySeconds: Double
    let masterGain: Float
    /// Echo time changes over a set, since each transition echoes in its own
    /// tempo: (master frame from which it applies, seconds), ascending.
    let delaySchedule: [(from: Int, seconds: Double)]
    /// Drop-moment air sweeps, sorted by start.
    let sweeps: [FrameSweep]
    /// Dynamic Club PA punch engaged during blends and drop landings (0 = bypass).
    let energyPunch: Float

    init(lanes: [LaneData], length: Int, delaySeconds: Double, masterGain: Float,
         delaySchedule: [(from: Int, seconds: Double)] = [], sweeps: [FrameSweep] = [],
         energyPunch: Float = 0) {
        self.lanes = lanes
        self.length = length
        self.delaySeconds = delaySeconds
        self.masterGain = masterGain
        self.delaySchedule = delaySchedule
        self.sweeps = sweeps
        self.energyPunch = energyPunch
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
    /// Frames (~8 ms) over which a loop's repeat is crossfaded in. The
    /// loop is written to turn round that long before its downbeat (see
    /// `TransitionBuilder.loopLead`), so the kick on the one is whole.
    static let loopCrossfade = 352
    let sampleRate = AudioIO.sampleRate

    private struct LaneDSP {
        var filter = DJFilter()
        var lowIsolator = LowIsolator()
        var mid = Biquad(), high = Biquad()
        var midVocalDipper = MidVocalDipper()
        var filterValue = -1.0, lowValue = -1.0, midValue = -1.0, highValue = -1.0
    }

    private var snapshot: MixSnapshot
    private var lanes: [LaneDSP] = []
    private var reverb: Reverb
    private var delay: PingPongDelay
    private var glue: BusGlue
    private var airSweep: AirSweep
    private var exciter: ClubExciter
    private var limiter: Limiter
    private var delaySeconds = 0.0

    private var laneL = [Float](repeating: 0, count: blockSize), laneR = [Float](repeating: 0, count: blockSize)
    private var dryL = [Float](repeating: 0, count: blockSize), dryR = [Float](repeating: 0, count: blockSize)
    private var revL = [Float](repeating: 0, count: blockSize), revR = [Float](repeating: 0, count: blockSize)
    private var dlyL = [Float](repeating: 0, count: blockSize), dlyR = [Float](repeating: 0, count: blockSize)

    /// Render-thread position in master frames: of the mix going into the
    /// limiter, which plays it `Limiter.lookahead` frames later. After a
    /// jump that far is rendered first (`preroll`), so what's heard is on
    /// time.
    private var position = 0
    private var needsPreroll = true
    /// The reverb's and the echo's tails have died away (see `renderBlock`).
    private var reverbIdle = true, delayIdle = true
    /// Minimum frames to keep running reverb/delay after the last fed block
    /// before checking for silence: a short throw (e.g. a 200 ms vocal word)
    /// into a 350 ms delay is still silent at the delay's output when the
    /// send closes, so checking silence immediately would kill the echo
    /// before its first repeat ever arrives.
    private var reverbTailFrames = 0, delayTailFrames = 0
    /// Wet-bus sidechain ducking gain (1 = open, down to 0.5 when a dry
    /// incoming vocal sings over an outgoing effect tail).
    private var wetDuck: Float = 1
    /// Inter-deck kick sidechain state: smooth ducking (up to −2.5 dB) on the
    /// non-low-owning track's melody stem during blends so both tracks breathe
    /// with the active kick.
    private var kickLpState: Float = 0
    private var kickDuck: Float = 1
    private var prevKickDuck: Float = 1
    private var kickOwnerTrack: Int = -1

    /// Nothing over -120 dBFS in the block.
    private static func silent(_ l: UnsafePointer<Float>, _ r: UnsafePointer<Float>, _ n: Int) -> Bool {
        var a: Float = 0, b: Float = 0
        vDSP_maxmgv(l, 1, &a, vDSP_Length(n))
        vDSP_maxmgv(r, 1, &b, vDSP_Length(n))
        return max(a, b) < 1e-6
    }
    private var prerollL = [Float](repeating: 0, count: blockSize), prerollR = [Float](repeating: 0, count: blockSize)

    // Hand-off from the main thread. The render thread only ever *tries* the
    // lock, so it can never block behind the UI.
    private let lock = OSAllocatedUnfairLock()
    private var pendingSnapshot: MixSnapshot?
    private var pendingSeek: Int?
    private var publishedPosition = 0
    private var retired: [MixSnapshot] = []

    init(snapshot: MixSnapshot = .empty, ceiling: Float = Limiter.playbackCeiling) {
        self.snapshot = snapshot
        reverb = Reverb(sampleRate: sampleRate)
        delay = PingPongDelay(sampleRate: sampleRate)
        glue = BusGlue(sampleRate: sampleRate)
        airSweep = AirSweep(sampleRate: sampleRate)
        exciter = ClubExciter(sampleRate: sampleRate)
        limiter = Limiter(sampleRate: sampleRate, ceiling: ceiling)
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
        if needsPreroll { preroll() }

        var done = 0
        while done < count {
            let n = min(Self.blockSize, count - done)
            renderBlock(left: left + done, right: right + done, count: n)
            done += n
            position += n
        }

        if lock.lockIfAvailable() {
            if pendingSeek == nil { publishedPosition = position - Limiter.lookahead }
            lock.unlock()
        }
    }

    /// Offline use: jump straight to a frame with no hand-off.
    func setPositionImmediately(_ frame: Int) {
        position = frame
        resetTails()
    }

    /// The look-ahead's worth of the mix, into the limiter, nothing out.
    private func preroll() {
        needsPreroll = false
        var left = Limiter.lookahead
        prerollL.withUnsafeMutableBufferPointer { l in
            prerollR.withUnsafeMutableBufferPointer { r in
                while left > 0 {
                    let n = min(Self.blockSize, left)
                    renderBlock(left: l.baseAddress!, right: r.baseAddress!, count: n)
                    position += n
                    left -= n
                }
            }
        }
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
        glue.reset()
        airSweep.reset()
        exciter.reset()
        reverbIdle = true
        delayIdle = true
        reverbTailFrames = 0
        delayTailFrames = 0
        wetDuck = 1
        kickLpState = 0
        kickDuck = 1
        prevKickDuck = 1
        kickOwnerTrack = -1
        limiter.reset()
        needsPreroll = true
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

        // Fast zero-allocation pre-scan: detect whether two tracks overlap
        // right now (engaging blend-only glue, kick pocketing, and vocal-bleed
        // de-centering while keeping solo playback bit-exact) and which tracks
        // have their vocals deliberately muted.
        var activeTrack0 = -1, activeTrack1 = -1
        var mutedVocalTrack0 = -1, mutedVocalTrack1 = -1
        for lane in snap.lanes where lane.audible && lane.trackIndex >= 0 {
            guard let audio = lane.audio else { continue }
            let src = position - lane.offset
            let inBounds = src + n > 0 && (src < audio.count || lane.rolls.contains { $0.start - Self.declick < position + n && $0.end + Self.declick > position })
            guard inBounds else { continue }
            let vol = LaneParameter.gain(value(lane.envelopes, .volume, tm))
            if vol > 0.01 {
                if activeTrack0 == -1 || activeTrack0 == lane.trackIndex {
                    activeTrack0 = lane.trackIndex
                } else if activeTrack1 == -1 || activeTrack1 == lane.trackIndex {
                    activeTrack1 = lane.trackIndex
                }
            } else if lane.isVocal {
                if mutedVocalTrack0 == -1 || mutedVocalTrack0 == lane.trackIndex {
                    mutedVocalTrack0 = lane.trackIndex
                } else if mutedVocalTrack1 == -1 || mutedVocalTrack1 == lane.trackIndex {
                    mutedVocalTrack1 = lane.trackIndex
                }
            }
        }
        let isBlending = activeTrack0 >= 0 && activeTrack1 >= 0

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
            var reverbFed = false, delayFed = false
            var dryVocalEnergy: Float = 0
            var kickEnergy: Float = 0
            var newKickOwner = -1

            for (i, lane) in snap.lanes.enumerated() {
                guard lane.audible, let audio = lane.audio else { continue }
                let src = position - lane.offset
                // (A loop plays on past the end of its song's file.)
                let rolling = lane.rolls.contains { $0.start - Self.declick < position + n && $0.end + Self.declick > position }
                guard src + n > 0, src < audio.count || rolling else { continue }

                // Copy the stem's frames for this block, zero outside the file.
                if rolling {
                    Self.copyRolled(lane, audio: audio, from: position, count: n, left: ll, right: lr)
                } else {
                    ll.update(repeating: 0, count: n)
                    lr.update(repeating: 0, count: n)
                    let lo = max(0, -src), hi = min(n, audio.count - src)
                    (ll + lo).update(from: audio.left.pointer + src + lo, count: hi - lo)
                    (lr + lo).update(from: audio.right.pointer + src + lo, count: hi - lo)
                }

                updateFilters(lane: i, envelopes: lane.envelopes, at: tm)
                lanes[i].filter.process(ll, lr, count: n)
                lanes[i].lowIsolator.process(ll, lr, count: n)
                lanes[i].mid.process(ll, lr, count: n)
                lanes[i].high.process(ll, lr, count: n)

                // During a blend, dip the center-panned vocal presence band on
                // an `other` stem whose deck's vocal stem is muted, hiding
                // leftover vocal separation bleed while keeping stereo synths wide.
                // And as an outgoing melody low-passes away (<2 kHz), gently
                // narrow its dry stereo width so it recedes behind the wide reverb.
                if lane.isOther {
                    let vocalMuted = isBlending && lane.trackIndex >= 0
                        && (lane.trackIndex == mutedVocalTrack0 || lane.trackIndex == mutedVocalTrack1)
                    lanes[i].midVocalDipper.process(ll, lr, count: n, target: vocalMuted ? 1 : 0, sampleRate: sampleRate)
                    if isBlending && lanes[i].filterValue < 0.35 && lanes[i].filterValue >= 0 {
                        let depth = Float(max(0, min(1, (0.35 - lanes[i].filterValue) / 0.23)))
                        let sideScale = 1 - 0.30 * depth
                        for j in 0..<n {
                            let m = 0.5 * (ll[j] + lr[j])
                            let s = 0.5 * (ll[j] - lr[j]) * sideScale
                            ll[j] = m + s
                            lr[j] = m - s
                        }
                    }
                }

                // Fader, ramped across the block so fades are sample-smooth.
                var g0 = LaneParameter.gain(value(lane.envelopes, .volume, t0)) * lane.trim
                var step = (LaneParameter.gain(value(lane.envelopes, .volume, t1)) * lane.trim - g0) / Float(n)
                guard g0 > 0 || step != 0 else { continue }
                vDSP_vrampmul2(ll, lr, 1, &g0, &step, ll, lr, 1, vDSP_Length(n))

                // Inter-deck kick sidechain pocketing during blends: measure
                // sub-130 Hz kick energy from whichever deck owns the low end,
                // and subtly groove-pocket the opposing deck's melody (~2.2 dB).
                if isBlending, lane.isDrums, lane.trackIndex >= 0, value(lane.envelopes, .low, tm) >= 0.45 {
                    let lpCoef = Float(exp(-2.0 * Double.pi * 130.0 / sampleRate))
                    var lp = kickLpState, sumSq: Float = 0
                    for j in 0..<n {
                        let m = 0.5 * (ll[j] + lr[j])
                        lp = m + lpCoef * (lp - m)
                        sumSq += lp * lp
                    }
                    kickLpState = abs(lp) < 1e-20 ? 0 : lp
                    let e = sumSq / Float(n)
                    if e >= kickEnergy {
                        kickEnergy = e
                        newKickOwner = lane.trackIndex
                    }
                } else if lane.isOther, lane.trackIndex >= 0, kickOwnerTrack >= 0,
                          lane.trackIndex != kickOwnerTrack, (prevKickDuck < 0.999 || kickDuck < 0.999) {
                    var dk = prevKickDuck
                    var dkStep = (kickDuck - prevKickDuck) / Float(n)
                    vDSP_vrampmul2(ll, lr, 1, &dk, &dkStep, ll, lr, 1, vDSP_Length(n))
                }

                vDSP_vadd(ll, 1, dL.baseAddress!, 1, dL.baseAddress!, 1, vDSP_Length(n))
                vDSP_vadd(lr, 1, dR.baseAddress!, 1, dR.baseAddress!, 1, vDSP_Length(n))

                // The sends, ramped across the block like the fader: a send
                // moved in steps chops what it feeds the effect, and the
                // echo repeats every tick it's given.
                let rev0 = LaneParameter.gain(value(lane.envelopes, .reverb, t0))
                let rev1 = LaneParameter.gain(value(lane.envelopes, .reverb, t1))
                let dly0 = LaneParameter.gain(value(lane.envelopes, .delay, t0))
                let dly1 = LaneParameter.gain(value(lane.envelopes, .delay, t1))
                if Self.send(ll, lr, n, from: rev0, to: rev1, into: rL.baseAddress!, rR.baseAddress!) {
                    reverbFed = true
                }
                if Self.send(ll, lr, n, from: dly0, to: dly1, into: eL.baseAddress!, eR.baseAddress!) {
                    delayFed = true
                }
                // Track dry vocal energy (an active vocal not currently
                // throwing into effects) to gently duck lingering effect
                // tails from the outgoing song.
                if lane.isVocal, max(rev0, rev1, dly0, dly1) < 0.05 {
                    var el: Float = 0, er: Float = 0
                    vDSP_measqv(ll, 1, &el, vDSP_Length(n))
                    vDSP_measqv(lr, 1, &er, vDSP_Length(n))
                    dryVocalEnergy = max(dryVocalEnergy, (el + er) * 0.5)
                }
            }

            // Update inter-deck kick ducking envelope for the next block.
            prevKickDuck = kickDuck
            if isBlending && newKickOwner >= 0 {
                kickOwnerTrack = newKickOwner
                let rms = kickEnergy.squareRoot()
                let depth = min(1, max(0, (rms - 0.05) / 0.22))
                let target: Float = 1 - 0.22 * depth // up to -2.2 dB groove pocket
                let coef: Float = target < kickDuck
                    ? Float(exp(-Double(n) / (0.010 * sampleRate)))
                    : Float(exp(-Double(n) / (0.110 * sampleRate)))
                kickDuck = target + coef * (kickDuck - target)
            } else {
                let rel = Float(exp(-Double(n) / (0.080 * sampleRate)))
                kickDuck = 1 + rel * (kickDuck - 1)
                if kickDuck > 0.9995 { kickDuck = 1; kickOwnerTrack = -1; kickLpState = 0 }
            }

            // Synthesize subtle stereo air riser + downlifter around drop moments.
            if !snap.sweeps.isEmpty,
               airSweep.process(position: position, count: n, sweeps: snap.sweeps,
                                dryL: dL.baseAddress!, dryR: dR.baseAddress!,
                                revL: rL.baseAddress!, revR: rR.baseAddress!) {
                reverbFed = true
            }

            // The reverb and the echo only run while something is sent to
            // them or their tail still sounds: most of a set sends nothing,
            // and they were most of the renderer's work.
            let revActive = reverbFed || !reverbIdle
            let dlyActive = delayFed || !delayIdle
            if reverbFed { reverbTailFrames = Int(0.25 * sampleRate) }
            if delayFed { delayTailFrames = Int((max(delaySeconds, 0.35) * 2 + 0.25) * sampleRate) }
            if revActive {
                reverb.process(rL.baseAddress!, rR.baseAddress!, count: n)
                reverbTailFrames = max(0, reverbTailFrames - n)
                reverbIdle = !reverbFed && reverbTailFrames == 0 && Self.silent(rL.baseAddress!, rR.baseAddress!, n)
            }
            if dlyActive {
                delay.process(eL.baseAddress!, eR.baseAddress!, count: n)
                delayTailFrames = max(0, delayTailFrames - n)
                delayIdle = !delayFed && delayTailFrames == 0 && Self.silent(eL.baseAddress!, eR.baseAddress!, n)
            }
            // Sidechain-duck the wet reverb & delay returns when a dry
            // incoming vocal sings over them, so outgoing tails fill breaths
            // and tuck cleanly behind the new singer's first words.
            if revActive || dlyActive {
                let rms = dryVocalEnergy.squareRoot()
                let depth = min(1, max(0, (rms - 0.03) / 0.12))
                let target: Float = 1 - 0.5 * depth  // down to -6 dB
                let coef: Float = target < wetDuck
                    ? Float(exp(-Double(n) / (0.015 * sampleRate)))
                    : Float(exp(-Double(n) / (0.20 * sampleRate)))
                let nextDuck = target + coef * (wetDuck - target)
                if wetDuck < 0.9999 || nextDuck < 0.9999 {
                    let slope = (nextDuck - wetDuck) / Float(n)
                    if revActive {
                        var g = wetDuck, s = slope
                        vDSP_vrampmul2(rL.baseAddress!, rR.baseAddress!, 1, &g, &s, rL.baseAddress!, rR.baseAddress!, 1, vDSP_Length(n))
                    }
                    if dlyActive {
                        var g = wetDuck, s = slope
                        vDSP_vrampmul2(eL.baseAddress!, eR.baseAddress!, 1, &g, &s, eL.baseAddress!, eR.baseAddress!, 1, vDSP_Length(n))
                    }
                }
                wetDuck = nextDuck
            } else {
                wetDuck = 1
            }

            vDSP_vadd(dL.baseAddress!, 1, rL.baseAddress!, 1, left, 1, vDSP_Length(n))
            vDSP_vadd(left, 1, eL.baseAddress!, 1, left, 1, vDSP_Length(n))
            vDSP_vadd(dR.baseAddress!, 1, rR.baseAddress!, 1, right, 1, vDSP_Length(n))
            vDSP_vadd(right, 1, eR.baseAddress!, 1, right, 1, vDSP_Length(n))
            // Blend-only VCA bus glue: welds overlapping tracks together and
            // eases limiter pumping without touching solo playback.
            glue.process(left, right, count: n, active: isBlending)
            // Dynamic Club PA punch: elevates blends and slams extra hard for
            // 4 bars after every drop landing, while returning bit-exact
            // bypassed during normal solo playback.
            var punchTarget: Float = 0
            if snap.energyPunch > 1e-4 {
                var inDropPunch = false
                for sw in snap.sweeps where sw.punchEnd > sw.drop {
                    if position + n > sw.drop && position < sw.punchEnd { inDropPunch = true; break }
                }
                if inDropPunch {
                    punchTarget = snap.energyPunch
                } else if isBlending {
                    punchTarget = snap.energyPunch * 0.60
                }
            }
            exciter.process(left, right, count: n, amount: punchTarget)
            var master = snap.masterGain
            vDSP_vsmul(left, 1, &master, left, 1, vDSP_Length(n))
            vDSP_vsmul(right, 1, &master, right, 1, vDSP_Length(n))
            limiter.process(left, right, count: n)
        }}}}}}}}
    }

    /// Adds a lane's block to a send bus at a gain going from `g0` to `g1`
    /// across it; false if nothing was sent.
    @inline(__always)
    private static func send(_ l: UnsafePointer<Float>, _ r: UnsafePointer<Float>, _ n: Int, from g0: Float, to g1: Float,
                             into busL: UnsafeMutablePointer<Float>, _ busR: UnsafeMutablePointer<Float>) -> Bool {
        guard g0 > 0 || g1 > 0 else { return false }
        if g0 == g1 {
            var g = g0
            vDSP_vsma(l, 1, &g, busL, 1, busL, 1, vDSP_Length(n))
            vDSP_vsma(r, 1, &g, busR, 1, busR, 1, vDSP_Length(n))
        } else {
            let step = (g1 - g0) / Float(n)
            for j in 0..<n {
                let g = g0 + step * Float(j)
                busL[j] += g * l[j]
                busR[j] += g * r[j]
            }
        }
        return true
    }

    /// A block of a stem that rolls: inside a roll, frames come from its
    /// loop (or decelerating vinyl brake); everywhere else from where the stem
    /// really is. Every jump is faded out and back in over `declick` frames.
    private static func copyRolled(_ lane: MixSnapshot.LaneData, audio: StemAudio, from position: Int, count n: Int,
                                   left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        let xf = Float(declick)
        for j in 0..<n {
            let p = position + j
            var s = p - lane.offset
            var fracPos: Double? = nil
            var g: Float = 1
            // A loop's seam: the frame the pass before would have carried
            // on with, and how much of it is still in (1…0).
            var tail = -1, tailGain: Float = 0
            for r in lane.rolls {
                if r.spinback, p >= r.start && p < r.end {
                    let span = Double(r.end - r.start)
                    let u = Double(p - r.start) / span
                    // Rapid reverse platter whip: speed -(1.5 + 7.5*u) → integrated
                    // backward travel span * (1.5*u + 3.75*u^2).
                    let travelled = span * (1.5 * u + 3.75 * u * u)
                    fracPos = max(0, Double(r.anchor - lane.offset) - travelled)
                    tail = -1
                    if u < 0.05 {
                        let fu = Float(u / 0.05)
                        g = min(g, 0.5 * (1 - cosf(Float.pi * fu)))
                    } else if u > 0.72 {
                        let fu = Float((u - 0.72) / 0.28)
                        g = min(g, 0.5 * (1 + cosf(Float.pi * fu)))
                    }
                } else if r.spinback {
                    // Entry/exit already shaped smoothly inside spinback window.
                } else if r.brake, p >= r.start && p < r.end {
                    let span = Double(r.end - r.start)
                    let u = Double(p - r.start) / span
                    // Speed v(u) = (1 - u)^2 → integrated position D * (1 - (1 - u)^3) / 3.
                    // Starts at speed 1.0 (seamless from normal playback) and coasts to 0.
                    let oneMinusU = 1.0 - u
                    let travelled = span * (1.0 - oneMinusU * oneMinusU * oneMinusU) / 3.0
                    fracPos = Double(r.anchor - lane.offset) + travelled
                    tail = -1
                    if u > 0.82 {
                        let fu = Float((u - 0.82) / 0.18)
                        g = min(g, 0.5 * (1 + cosf(Float.pi * fu)))
                    }
                } else if r.brake {
                    // Seamless start from playback; tail already faded to 0 by r.end.
                } else if p >= r.start && p < r.end, r.crossfade > 0 {
                    let phase = (p - r.start) % r.length
                    // The first pass comes out of the stem where it really
                    // was; the later ones out of the loop's own end.
                    let from = p - r.start < r.length ? s : r.anchor - lane.offset + r.length + phase
                    s = r.anchor - lane.offset + phase
                    if phase < r.crossfade {
                        tail = from
                        // Raised-cosine crossfade: C1-smooth at both ends
                        // (no slope discontinuity) and sums to unity.
                        let u = Float(phase) / Float(r.crossfade)
                        tailGain = 0.5 * (1 + cosf(Float.pi * u))
                    } else {
                        tail = -1
                    }
                    g = min(g, Float(r.end - p) / xf)
                } else if p >= r.start && p < r.end {
                    let phase = (p - r.start) % r.length
                    s = r.anchor - lane.offset + phase
                    tail = -1
                    g = min(g, Float(min(phase, r.length - phase, r.end - p)) / xf)
                } else if r.crossfade > 0 && p < r.start {
                    // Nothing to fade before a loop: it's crossfaded into.
                } else if p >= r.start - declick && p < r.start {
                    g = min(g, Float(r.start - p) / xf)
                } else if p >= r.end && p < r.end + declick {
                    g = min(g, Float(p - r.end) / xf)
                }
            }
            var l: Float = 0, r: Float = 0
            if let fp = fracPos {
                let i0 = Int(floor(fp))
                let frac = Float(fp - Double(i0))
                if i0 >= 0 && i0 + 1 < audio.count {
                    l = audio.left.pointer[i0] + frac * (audio.left.pointer[i0 + 1] - audio.left.pointer[i0])
                    r = audio.right.pointer[i0] + frac * (audio.right.pointer[i0 + 1] - audio.right.pointer[i0])
                } else if i0 >= 0 && i0 < audio.count {
                    l = audio.left.pointer[i0]
                    r = audio.right.pointer[i0]
                }
            } else if s >= 0 && s < audio.count {
                l = audio.left.pointer[s]
                r = audio.right.pointer[s]
            }
            if tail >= 0 && tail < audio.count {
                l = l * (1 - tailGain) + audio.left.pointer[tail] * tailGain
                r = r * (1 - tailGain) + audio.right.pointer[tail] * tailGain
            } else if tail >= 0 {
                l *= 1 - tailGain
                r *= 1 - tailGain
            }
            left[j] = l * g
            right[j] = r * g
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
                dsp.filter.setBypass()
            case .lowPass(let hz):
                dsp.filter.set(.lowPass, frequency: hz, sampleRate: sr)
            case .highPass(let hz):
                dsp.filter.set(.highPass, frequency: hz, sampleRate: sr)
            }
        }
        // 6th-order Butterworth Cytomic ZDF SVF low isolator/shelf: monotonic
        // and phase-coherent across the entire +6 dB to −54 dB kill range with
        // zero dry/wet comb-filtering notch and bit-exact 0° phase at 0 dB.
        let low = value(envelopes, .low, t)
        if abs(low - dsp.lowValue) > 1e-5 {
            dsp.lowValue = low
            let db = LaneParameter.eqDecibels(low)
            let mapped = db < 0 ? max(LowIsolator.killDecibels, db * (LowIsolator.killDecibels / -40.0)) : db
            dsp.lowIsolator.set(gainDB: mapped, sampleRate: sr)
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
