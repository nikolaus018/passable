import Foundation

/// 8-channel modulated Hadamard Feedback Delay Network (FDN) reverb, stereo.
/// Tuned long and dark for washing out vocal and melody tails without the
/// metallic comb ringing of an unmodulated Freeverb.
struct Reverb {
    private static let channels = 8
    /// Mutually prime base delay lengths at 44.1 kHz (~26–73 ms), plus
    /// modulation headroom.
    private static let baseLengths = [1151, 1361, 1597, 1847, 2111, 2437, 2801, 3209]
    /// Slow LFO rates (Hz) per channel, irrational-ish spacing to avoid beating.
    private static let lfoRates: [Float] = [0.31, 0.43, 0.53, 0.61, 0.37, 0.47, 0.59, 0.71]
    private static let modDepth: Float = 6.5

    private struct Line {
        var buffer: [Float]
        let baseDelay: Float
        var write = 0
        var dampState: Float = 0
        var phase: Float
        let phaseStep: Float

        init(delay: Int, phase: Float, rate: Float, sampleRate: Double) {
            let headroom = Int(Reverb.modDepth.rounded(.up)) + 4
            let size = max(16, delay + headroom)
            buffer = [Float](repeating: 0, count: size)
            baseDelay = Float(delay)
            self.phase = phase
            phaseStep = Float(2 * Double.pi * Double(rate) / sampleRate)
        }

        mutating func clear() {
            buffer.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
            dampState = 0
        }

        @inline(__always)
        mutating func read(damp: Float) -> Float {
            phase += phaseStep
            if phase >= Float.pi * 2 { phase -= Float.pi * 2 }
            let d = baseDelay + sinf(phase) * Reverb.modDepth
            let size = buffer.count
            var pos = Float(write) - d
            if pos < 0 { pos += Float(size) }
            let i0 = Int(pos) % size
            let i1 = (i0 + 1) % size
            let frac = pos - floorf(pos)
            let raw = buffer[i0] + frac * (buffer[i1] - buffer[i0])
            dampState = raw * (1 - damp) + dampState * damp
            if abs(dampState) < 1e-20 { dampState = 0 }
            return dampState
        }

        @inline(__always)
        mutating func push(_ x: Float) {
            buffer[write] = abs(x) < 1e-20 ? 0 : x
            write += 1
            if write == buffer.count { write = 0 }
        }
    }

    private var lines: [Line]
    private var inputFilter = Biquad()
    /// 25 ms pre-delay ring buffers so dry vocal/melody attacks stay crisp
    /// while the lush cathedral tail blooms cleanly right behind them.
    private var preL: [Float], preR: [Float]
    private var preWrite = 0
    /// Feedback per loop pass (~3.8 s RT60 on the mean delay length).
    var feedback: Float = 0.89
    var damp: Float = 0.34

    init(sampleRate: Double) {
        let scale = sampleRate / 44_100
        lines = (0..<Self.channels).map { c in
            let delay = max(16, Int((Double(Self.baseLengths[c]) * scale).rounded()))
            return Line(delay: delay, phase: Float(c) * 0.785398, rate: Self.lfoRates[c], sampleRate: sampleRate)
        }
        let preLen = max(1, Int((0.025 * sampleRate).rounded()))
        preL = [Float](repeating: 0, count: preLen)
        preR = [Float](repeating: 0, count: preLen)
        // Keep sub-bass out of the tail; a reverbed kick is mud.
        inputFilter.set(.highPass(frequency: 250, q: 0.707), sampleRate: sampleRate)
    }

    mutating func reset() {
        for i in lines.indices { lines[i].clear() }
        preL.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
        preR.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
        preWrite = 0
        inputFilter.reset()
    }

    /// Replaces the contents of `left`/`right` (the send bus) with the wet signal.
    mutating func process(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, count: Int) {
        inputFilter.process(left, right, count: count)
        let fb = feedback, dp = damp
        // Orthogonal 8x8 Walsh-Hadamard scaling (1 / sqrt(8)).
        let hScale: Float = 0.35355339 * fb
        // Lush enough to bloom visibly on melody dissolves and risers without
        // swamping the dry beat.
        let inGain: Float = 0.27
        let outGain: Float = 0.50
        let preSize = preL.count
        for i in 0..<count {
            let xl = preL[preWrite] * inGain
            let xr = preR[preWrite] * inGain
            preL[preWrite] = abs(left[i]) < 1e-20 ? 0 : left[i]
            preR[preWrite] = abs(right[i]) < 1e-20 ? 0 : right[i]
            preWrite += 1
            if preWrite == preSize { preWrite = 0 }
            let d0 = lines[0].read(damp: dp), d1 = lines[1].read(damp: dp)
            let d2 = lines[2].read(damp: dp), d3 = lines[3].read(damp: dp)
            let d4 = lines[4].read(damp: dp), d5 = lines[5].read(damp: dp)
            let d6 = lines[6].read(damp: dp), d7 = lines[7].read(damp: dp)

            // Fast 8-point Walsh-Hadamard transform (3 butterfly stages).
            let a0 = d0 + d1, a1 = d0 - d1, a2 = d2 + d3, a3 = d2 - d3
            let a4 = d4 + d5, a5 = d4 - d5, a6 = d6 + d7, a7 = d6 - d7
            let b0 = a0 + a2, b1 = a1 + a3, b2 = a0 - a2, b3 = a1 - a3
            let b4 = a4 + a6, b5 = a5 + a7, b6 = a4 - a6, b7 = a5 - a7
            let m0 = (b0 + b4) * hScale, m1 = (b1 + b5) * hScale
            let m2 = (b2 + b6) * hScale, m3 = (b3 + b7) * hScale
            let m4 = (b0 - b4) * hScale, m5 = (b1 - b5) * hScale
            let m6 = (b2 - b6) * hScale, m7 = (b3 - b7) * hScale

            // True-stereo injection with alternating signs for decorrelation.
            lines[0].push(m0 + xl)
            lines[1].push(m1 + xr)
            lines[2].push(m2 - xl)
            lines[3].push(m3 - xr)
            lines[4].push(m4 + xl)
            lines[5].push(m5 - xr)
            lines[6].push(m6 - xl)
            lines[7].push(m7 + xr)

            left[i] = (d0 - d2 + d4 - d6) * outGain
            right[i] = (d1 - d3 - d5 + d7) * outGain
        }
    }
}

/// Tempo-synced ping-pong delay with a band-limited feedback path, so the
/// repeats thin out and darken like a DJ mixer's echo instead of building
/// into a wall of low end.
struct PingPongDelay {
    /// One-pole band-pass (high-pass then low-pass) for a feedback path.
    private struct Tone {
        var hpState: Float = 0, hpPrev: Float = 0, lpState: Float = 0
        let hpCoef: Float, lpCoef: Float

        init(sampleRate: Double) {
            hpCoef = Float(exp(-2 * Double.pi * 320 / sampleRate))
            lpCoef = Float(exp(-2 * Double.pi * 5_800 / sampleRate))
        }

        init(hpCoef: Float, lpCoef: Float) {
            self.hpCoef = hpCoef
            self.lpCoef = lpCoef
        }

        mutating func process(_ x: Float) -> Float {
            hpState = hpCoef * (hpState + x - hpPrev)
            hpPrev = x
            lpState = hpState + lpCoef * (lpState - hpState)
            return lpState
        }
    }

    private var bufferL: [Float]
    private var bufferR: [Float]
    private var writeIndex = 0
    private var toneL: Tone
    private var toneR: Tone
    private var delaySamples: Float
    private var targetDelaySamples: Float
    private let delaySlew: Float
    private var modPhase: Float = 0
    private let modStep: Float
    var feedback: Float = 0.58

    init(sampleRate: Double, maxSeconds: Double = 4) {
        let size = Int(sampleRate * maxSeconds)
        bufferL = [Float](repeating: 0, count: size)
        bufferR = [Float](repeating: 0, count: size)
        let initial = Float(sampleRate * 0.35)
        delaySamples = initial
        targetDelaySamples = initial
        delaySlew = Float(exp(-1.0 / (0.040 * sampleRate)))
        modStep = Float(2 * Double.pi * 0.42 / sampleRate)
        toneL = Tone(sampleRate: sampleRate)
        toneR = Tone(sampleRate: sampleRate)
    }

    mutating func reset() {
        bufferL.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
        bufferR.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
        delaySamples = targetDelaySamples
        modPhase = 0
        toneL = Tone(hpCoef: toneL.hpCoef, lpCoef: toneL.lpCoef)
        toneR = Tone(hpCoef: toneR.hpCoef, lpCoef: toneR.lpCoef)
    }

    mutating func setTime(seconds: Double, sampleRate: Double) {
        targetDelaySamples = Float(max(8.0, min(Double(bufferL.count - 8), seconds * sampleRate)))
    }

    /// Replaces the send bus with the wet tape-echo ping-pong signal.
    mutating func process(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, count: Int) {
        let size = bufferL.count
        let fSize = Float(size)
        let slew = delaySlew, mStep = modStep, fb = feedback
        var curDelay = delaySamples, phase = modPhase
        for i in 0..<count {
            curDelay = targetDelaySamples + slew * (curDelay - targetDelaySamples)
            phase += mStep
            if phase >= Float.pi * 2 { phase -= Float.pi * 2 }
            // Subtle stereo tape wow/chorus (±3.5 samples) for Space Echo shimmer.
            let mod = sinf(phase) * 3.5
            var posL = Float(writeIndex) - (curDelay + mod)
            if posL < 0 { posL += fSize }
            if posL >= fSize { posL -= fSize }
            let i0L = Int(posL) % size
            let i1L = (i0L + 1) % size
            let fracL = posL - floorf(posL)
            let rawL = bufferL[i0L] + fracL * (bufferL[i1L] - bufferL[i0L])

            var posR = Float(writeIndex) - (curDelay - mod)
            if posR < 0 { posR += fSize }
            if posR >= fSize { posR -= fSize }
            let i0R = Int(posR) % size
            let i1R = (i0R + 1) % size
            let fracR = posR - floorf(posR)
            let rawR = bufferR[i0R] + fracR * (bufferR[i1R] - bufferR[i0R])

            let dl = toneL.process(rawL)
            let dr = toneR.process(rawR)
            // Gentle analog tape saturation in the feedback path keeps echoes warm
            // and musical without harsh digital clipping.
            let input = (left[i] + right[i]) * 0.5
            let fbL = tanhf((input + dr * fb) * 1.15) * (1.0 / 1.15)
            let fbR = tanhf((dl * fb) * 1.15) * (1.0 / 1.15)
            bufferL[writeIndex] = abs(fbL) < 1e-20 ? 0 : fbL
            bufferR[writeIndex] = abs(fbR) < 1e-20 ? 0 : fbR
            left[i] = dl
            right[i] = dr
            writeIndex += 1
            if writeIndex == size { writeIndex = 0 }
        }
        delaySamples = curDelay
        modPhase = phase
    }
}

/// Peak limiter at −0.3 dBFS with look-ahead: it sees a peak coming and
/// lowers the gain smoothly into it (over `window` frames), instead of
/// jumping the gain on the peak itself (which is heard as a crackle), then
/// lets it back over 40–150 ms. Stereo-linked. The output runs `lookahead`
/// frames behind the input; `MixRenderer` renders that far ahead, so what
/// plays stays on time. A safety net for summing eight stems, not a
/// mastering tool.
///
/// Peaks are true peaks (ITU-R BS.1770-4's idea): besides each sample, the
/// waveform between it and the next is estimated at three points (4×
/// oversampling by a 12-tap windowed sinc), so what a DAC or a lossy
/// decoder reconstructs between samples stays under the ceiling too, not
/// only the samples themselves.
struct Limiter {
    /// Frames the gain glides into a peak over (2 ms).
    static let window = 88
    /// Taps of the inter-sample interpolator, and the frames it needs
    /// after the one it judges (the second half of its taps).
    private static let taps = 12
    private static let tpDelay = 6
    /// Frames from input to output.
    static let lookahead = window + tpDelay
    private let fastRelease: Float
    private let slowRelease: Float
    private let holdAlpha: Float
    private let ceiling: Float
    /// -0.3 dBFS: for playback.
    static let playbackCeiling: Float = 0.966
    /// -1.2 dBFS: for a file coded lossily (AAC), whose decoder overshoots
    /// the samples it was given (a set's AAC peaked at +0.4 dBFS from
    /// -0.3), the usual -1 dB true-peak margin.
    static let lossyCeiling: Float = 0.871
    private var delayL: [Float], delayR: [Float]
    /// Gain each input frame needs; the least over each window of them;
    /// those averaged (see `process`).
    private var least: [Float]
    private var index = 0
    /// Frames that may yet be the window's least need, oldest first: their
    /// needs (rising) and frame numbers, in rings of `window + 2` (the
    /// window and the frame coming in).
    private var queueValue: [Float], queueFrame: [Int]
    private var queueHead = 0, queueSize = 0
    /// Frames judged so far.
    private var frame = 0
    private var leastSum: Float
    private var gain: Float = 1
    /// Smoothed gain reduction (0…1) to distinguish isolated transient
    /// spikes (fast recovery, no pumping) from sustained dense limiting
    /// (slower release, no distortion).
    private var sustained: Float = 0
    /// The last `taps` input frames, each written twice (`taps` apart) so
    /// they read as one contiguous run, oldest first, from `historyStart`.
    private var historyL: [Float], historyR: [Float]
    private var historyWrite = 0
    /// Interpolator taps for the points ¼, ½ and ¾ of the way from the
    /// judged frame to the next: `taps` each.
    private let phases: [Float]

    init(sampleRate: Double, ceiling: Float = Limiter.playbackCeiling) {
        self.ceiling = ceiling
        fastRelease = Float(exp(-1 / (0.04 * sampleRate)))
        slowRelease = Float(exp(-1 / (0.15 * sampleRate)))
        holdAlpha = Float(exp(-1 / (0.03 * sampleRate)))
        let n = Self.window + 1
        delayL = [Float](repeating: 0, count: n)
        delayR = delayL
        least = [Float](repeating: 1, count: n)
        queueValue = [Float](repeating: 1, count: n + 1)
        queueFrame = [Int](repeating: 0, count: n + 1)
        leastSum = Float(n)
        historyL = [Float](repeating: 0, count: 2 * Self.taps)
        historyR = historyL
        var coefficients: [Float] = []
        let center = Self.taps / 2 - 1
        let halfWidth = Double(Self.taps) / 2 + 0.5
        for f in [0.25, 0.5, 0.75] {
            var row = (0..<Self.taps).map { k -> Double in
                let x = f - Double(k - center)
                let sinc = abs(x) < 1e-12 ? 1 : sin(Double.pi * x) / (Double.pi * x)
                let hann = 0.5 * (1 + cos(Double.pi * x / halfWidth))
                return sinc * hann
            }
            let sum = row.reduce(0, +)
            row = row.map { $0 / sum }
            coefficients += row.map(Float.init)
        }
        phases = coefficients
    }

    mutating func reset() {
        let n = Self.window + 1
        for k in 0..<n { delayL[k] = 0; delayR[k] = 0; least[k] = 1 }
        for k in 0..<(2 * Self.taps) { historyL[k] = 0; historyR[k] = 0 }
        historyWrite = 0
        leastSum = Float(n)
        gain = 1
        sustained = 0
        index = 0
        frame = 0
        queueHead = 0
        queueSize = 0
    }

    /// The largest magnitude of the waveform over the judged frame and the
    /// stretch to the next one, from `x` (the last `taps` frames, oldest
    /// first; the judged one at `taps / 2 - 1`).
    @inline(__always)
    private static func truePeak(_ x: UnsafePointer<Float>, _ c: UnsafePointer<Float>) -> Float {
        var top = abs(x[taps / 2 - 1])
        for p in 0..<3 {
            var v: Float = 0
            let row = c + p * taps
            for k in 0..<taps { v += row[k] * x[k] }
            top = max(top, abs(v))
        }
        return top
    }

    /// In place: frame `i` out is frame `i - lookahead` in, limited. The
    /// gain on an output frame is the mean, over the window ending there,
    /// of the least gain each frame of the window needed over the window
    /// after it: every term covers the frame itself, so the peak is never
    /// over the ceiling, and the gain glides into it.
    ///
    /// The least gain over the window comes from a queue of the frames
    /// that could still be it (each needing less than all after it), so
    /// it costs the same however many frames in the window are over.
    mutating func process(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, count: Int) {
        let n = Self.window + 1, slots = n + 1
        let taps = Self.taps
        let ceiling = self.ceiling, holdAlpha = self.holdAlpha
        let fastRelease = self.fastRelease, slowRelease = self.slowRelease
        var index = self.index, historyWrite = self.historyWrite
        var leastSum = self.leastSum, gain = self.gain, sustained = self.sustained
        var frame = self.frame, head = self.queueHead, size = self.queueSize
        let hl = historyL.withUnsafeMutableBufferPointer { $0.baseAddress! }
        let hr = historyR.withUnsafeMutableBufferPointer { $0.baseAddress! }
        let dl = delayL.withUnsafeMutableBufferPointer { $0.baseAddress! }
        let dr = delayR.withUnsafeMutableBufferPointer { $0.baseAddress! }
        let least = self.least.withUnsafeMutableBufferPointer { $0.baseAddress! }
        let qv = queueValue.withUnsafeMutableBufferPointer { $0.baseAddress! }
        let qf = queueFrame.withUnsafeMutableBufferPointer { $0.baseAddress! }
        let c = phases.withUnsafeBufferPointer { $0.baseAddress! }
        for i in 0..<count {
            // The new frame into the interpolator's history; the frame
            // `tpDelay` back is the one judged and passed on.
            hl[historyWrite] = left[i]; hl[historyWrite + taps] = left[i]
            hr[historyWrite] = right[i]; hr[historyWrite + taps] = right[i]
            historyWrite = historyWrite + 1 == taps ? 0 : historyWrite + 1
            let xl = UnsafePointer(hl + historyWrite), xr = UnsafePointer(hr + historyWrite)
            let inL = xl[taps / 2 - 1], inR = xr[taps / 2 - 1]
            let peak = max(Self.truePeak(xl, c), Self.truePeak(xr, c))
            let need: Float = peak > ceiling ? ceiling / peak : 1
            // The least need over the last `n` frames: frames that need
            // no less than this one can never be it again, and the oldest
            // leaves once it's `n` frames back. (None queued: all 1.)
            while size > 0 && qv[(head + size - 1) % slots] >= need { size -= 1 }
            qv[(head + size) % slots] = need
            qf[(head + size) % slots] = frame
            size += 1
            while qf[head] <= frame - n { head = (head + 1) % slots; size -= 1 }
            frame += 1
            let m: Float = min(1, qv[head])
            leastSum += m - least[index]
            least[index] = m
            let smooth = min(1, leastSum / Float(n))
            // Track sustained limiting density: isolated transient hits stay
            // near 0 (fast 40 ms recovery); continuous dense limiting rises
            // toward 1 (150 ms release).
            let gr = 1 - smooth
            sustained = holdAlpha * sustained + (1 - holdAlpha) * min(1, gr * 4)
            let rel = fastRelease + sustained * (slowRelease - fastRelease)
            gain = min(smooth, gain * rel + (1 - rel))
            // Out: the oldest frame in the delay (the one about to be
            // overwritten).
            let next = index + 1 == n ? 0 : index + 1
            let outL = dl[next], outR = dr[next]
            dl[index] = inL
            dr[index] = inR
            left[i] = outL * gain
            right[i] = outR * gain
            index = next
        }
        self.index = index
        self.historyWrite = historyWrite
        self.leastSum = leastSum
        self.gain = gain
        self.sustained = sustained
        self.frame = frame
        self.queueHead = head
        self.queueSize = size
    }
}

/// Gentle VCA-style bus glue compressor + sub-100 Hz mono-maker engaged only
/// while two songs overlap (`active == true`). Glues layered tops/mids into
/// one cohesive mix, locks sub-bass dead center during swaps, and takes
/// pressure off the peak limiter, while staying bit-exact bypassed during solo
/// playback.
struct BusGlue {
    private let attackCoef: Float
    private let releaseCoef: Float
    private let blendCoef: Float
    private let scHpCoef: Float
    private let subLpCoef: Float
    private let rmsCoef: Float
    private var scPrev: Float = 0, scState: Float = 0
    private var subSideState: Float = 0
    private var rmsSq: Float = 0
    private var env: Float = 0
    private var blend: Float = 0

    init(sampleRate: Double) {
        attackCoef = Float(exp(-1.0 / (0.025 * sampleRate)))
        releaseCoef = Float(exp(-1.0 / (0.120 * sampleRate)))
        blendCoef = Float(exp(-1.0 / (0.120 * sampleRate)))
        scHpCoef = Float(exp(-2.0 * Double.pi * 120.0 / sampleRate))
        subLpCoef = Float(exp(-2.0 * Double.pi * 100.0 / sampleRate))
        rmsCoef = Float(exp(-1.0 / (0.180 * sampleRate)))
    }

    mutating func reset() {
        scPrev = 0; scState = 0; subSideState = 0; rmsSq = 0; env = 0; blend = 0
    }

    mutating func process(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>,
                          count: Int, active: Bool) {
        let target: Float = active ? 1 : 0
        guard blend > 1e-4 || target > 0, count > 0 else { return }
        let atk = attackCoef, rel = releaseCoef, bCoef = blendCoef, hp = scHpCoef
        let subA = subLpCoef, subB = 1 - subLpCoef
        let rA = rmsCoef, rB = 1 - rmsCoef
        // Threshold −9 dBFS (~0.355), soft knee 4 dB, ratio 2:1, max −3.5 dB GR.
        let threshDB: Float = -9.0
        let knee: Float = 4.0
        let invRatioDiff: Float = 0.5 // 1 - 1/2
        // Slow-RMS overlap auto-leveler: tames hot +5–6 dB double-chorus stacks
        // smoothly back toward −10.5 dBFS RMS without touching clean blends.
        let rmsThreshDB: Float = -10.5
        var curBlend = blend, curEnv = env, curPrev = scPrev, curHp = scState
        var curSub = subSideState, curRms = rmsSq
        for i in 0..<count {
            curBlend = target + bCoef * (curBlend - target)
            var l = left[i], r = right[i]
            // Sub-100 Hz mono-maker: tighten Side below 100 Hz by −12 dB while
            // blending, leaving Mid and >100 Hz stereo image completely untouched.
            let side = 0.5 * (l - r)
            curSub = subA * curSub + subB * side
            let tighten = 0.75 * curBlend * curSub
            l -= tighten
            r += tighten

            let mono = 0.5 * (l + r)
            curHp = hp * (curHp + mono - curPrev)
            curPrev = mono
            let det = max(abs(curHp), 0.7 * max(abs(l), abs(r)))
            let c = det > curEnv ? atk : rel
            curEnv = det + c * (curEnv - det)
            let db = 20 * log10f(max(curEnv, 1e-6))
            let over = db - threshDB
            let grDB: Float
            if over <= -knee * 0.5 {
                grDB = 0
            } else if over < knee * 0.5 {
                let x = over + knee * 0.5
                grDB = invRatioDiff * x * x / (2 * knee)
            } else {
                grDB = invRatioDiff * over
            }
            // Slow-RMS overlap leveler (tucks hot double-chorus overlaps smoothly).
            curRms = rA * curRms + rB * (0.5 * (l * l + r * r))
            let rmsDB = 10 * log10f(max(curRms, 1e-12))
            let rmsOver = max(0, rmsDB - rmsThreshDB)
            let rmsGR = min(3.5, rmsOver * 0.65)

            let applied = min(5.5, grDB + rmsGR) * curBlend
            if applied > 1e-4 {
                let g = powf(10, -applied / 20)
                l *= g
                r *= g
            }
            // C∞-smooth analog mixer summing warmth during blends.
            if curBlend > 0.01 {
                let sat = 0.08 * curBlend
                l = l / (1 + sat * l * l)
                r = r / (1 + sat * r * r)
            }
            left[i] = l
            right[i] = r
        }
        blend = curBlend < 1e-4 && !active ? 0 : curBlend
        env = curEnv < 1e-20 ? 0 : curEnv
        rmsSq = curRms < 1e-20 ? 0 : curRms
        scPrev = abs(curPrev) < 1e-20 ? 0 : curPrev
        scState = abs(curHp) < 1e-20 ? 0 : curHp
        subSideState = abs(curSub) < 1e-20 ? 0 : curSub
    }
}

/// Subtle Pioneer-style stereo air riser & drop downlifter synthesized only
/// inside drop-moment windows. Zero-allocation, deterministic, and completely
/// bypassed outside drop sweeps so solo playback stays bit-exact.
struct AirSweep {
    private let sampleRate: Double
    private var rngL: UInt32 = 0x1234_5678
    private var rngR: UInt32 = 0x9E37_79B9
    private var s1L: Float = 0, s2L: Float = 0
    private var s1R: Float = 0, s2R: Float = 0
    private var active = false

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }

    mutating func reset() {
        rngL = 0x1234_5678
        rngR = 0x9E37_79B9
        s1L = 0; s2L = 0; s1R = 0; s2R = 0
        active = false
    }

    @inline(__always)
    private static func nextWhite(_ state: inout UInt32) -> Float {
        var x = state
        x ^= x << 13
        x ^= x >> 17
        x ^= x << 5
        state = x
        return Float(Int32(bitPattern: x)) * (1.0 / 2_147_483_648.0)
    }

    /// Synthesizes any overlapping sweep for frames `position..<(position + count)`
    /// into `dryL/R` and feeds 35 % into `revL/R`. Returns true if audio was added.
    mutating func process(position: Int, count: Int, sweeps: [MixSnapshot.FrameSweep],
                          dryL: UnsafeMutablePointer<Float>, dryR: UnsafeMutablePointer<Float>,
                          revL: UnsafeMutablePointer<Float>, revR: UnsafeMutablePointer<Float>) -> Bool {
        var match: MixSnapshot.FrameSweep?
        for sw in sweeps {
            if sw.end > position && sw.start < position + count { match = sw; break }
        }
        guard let sw = match else {
            if active { s1L = 0; s2L = 0; s1R = 0; s2R = 0; active = false }
            return false
        }
        active = true
        let riserEnd = sw.drop - sw.cutBeforeDrop
        let riserSpan = max(1, riserEnd - sw.start)
        let downSpan = max(1, sw.end - sw.drop)
        let cutFade = max(1, Int(0.012 * sampleRate))
        let attackFade = max(1, Int(0.010 * sampleRate))
        let boomSpan = max(1, Int(0.20 * sampleRate))
        let boomAttack = max(1, Int(0.004 * sampleRate))

        // Mid-block filter parameters (updated once per 64-sample block = smooth).
        let intensity = max(0.5, min(2.2, sw.intensity))
        let midP = position + count / 2
        let freq: Double
        let k: Float
        if midP < sw.drop {
            let u = max(0.0, min(1.0, Double(midP - sw.start) / Double(riserSpan)))
            let topFreq = 6_200.0 + 2_200.0 * Double(max(0, intensity - 1))
            freq = 420.0 * pow(topFreq / 420.0, u * u) // 420 Hz → 6.2–8.4 kHz
            let q = 1.55 + 1.15 * u + 0.35 * Double(max(0, intensity - 1))
            k = Float(1.0 / q)
        } else {
            let v = max(0.0, min(1.0, Double(midP - sw.drop) / Double(downSpan)))
            freq = 6_400.0 * pow(240.0 / 6_400.0, pow(v, 0.65)) // 6.4 kHz → 240 Hz wide crash
            k = Float(1.0 / 1.1)
        }
        let g = Float(tan(Double.pi * min(freq, sampleRate * 0.42) / sampleRate))
        let a1 = 1 / (1 + g * (g + k))
        let a2 = g * a1
        let a3 = g * a2
        let boomSpanDyn = max(boomSpan, Int((0.18 + 0.04 * Double(max(0, intensity - 1))) * sampleRate))
        let boomTopHz = 82.0 + 10.0 * Double(max(0, intensity - 1))
        let boomAmp = 0.075 * Double(min(1.25, intensity))

        var z1L = s1L, z2L = s2L, z1R = s1R, z2R = s2R
        var wrote = false
        for i in 0..<count {
            let p = position + i
            var env: Float = 0
            if p >= sw.start && p < riserEnd {
                let u = Float(p - sw.start) / Float(riserSpan)
                env = 0.060 * intensity * u * u
                let rem = riserEnd - p
                if rem < cutFade {
                    let fu = Float(rem) / Float(cutFade)
                    env *= 0.5 * (1 - cosf(Float.pi * fu))
                }
            } else if p >= sw.drop && p < sw.end {
                let v = Float(p - sw.drop) / Float(downSpan)
                let omv = 1 - v
                env = 0.056 * intensity * omv * omv
                let elapsed = p - sw.drop
                if elapsed < attackFade {
                    env *= Float(elapsed) / Float(attackFade)
                }
                // Tight sub-impact accent (82–92 Hz → 32 Hz over 180–220 ms)
                // right on beat 1 of the drop.
                if elapsed < boomSpanDyn {
                    let tSec = Double(elapsed) / sampleRate
                    let dur = Double(boomSpanDyn) / sampleRate
                    let spanHz = boomTopHz - 32.0
                    let u = tSec / dur
                    let omu = 1.0 - u
                    let phase = 2.0 * Double.pi * (32.0 * tSec + spanHz * dur * (1.0 - omu * omu * omu) / 3.0)
                    var bEnv = Float(boomAmp * omu * omu)
                    if elapsed < boomAttack {
                        let fa = Float(elapsed) / Float(boomAttack)
                        bEnv *= 0.5 * (1 - cosf(Float.pi * fa))
                    }
                    let sub = Float(sin(phase)) * bEnv
                    dryL[i] += sub
                    dryR[i] += sub
                }
            }
            if env <= 1e-6 { continue }
            wrote = true
            let xl = Self.nextWhite(&rngL)
            let v3L = xl - z2L
            let v1L = a1 * z1L + a2 * v3L
            let v2L = z2L + a2 * z1L + a3 * v3L
            z1L = 2 * v1L - z1L
            z2L = 2 * v2L - z2L
            let outL = v1L * env

            let xr = Self.nextWhite(&rngR)
            let v3R = xr - z2R
            let v1R = a1 * z1R + a2 * v3R
            let v2R = z2R + a2 * z1R + a3 * v3R
            z1R = 2 * v1R - z1R
            z2R = 2 * v2R - z2R
            let outR = v1R * env

            dryL[i] += outL
            dryR[i] += outR
            let revSend: Float = p >= sw.drop ? 0.42 : 0.35
            revL[i] += outL * revSend
            revR[i] += outR * revSend
        }
        s1L = abs(z1L) < 1e-20 ? 0 : z1L
        s2L = abs(z2L) < 1e-20 ? 0 : z2L
        s1R = abs(z1R) < 1e-20 ? 0 : z1R
        s2R = abs(z2R) < 1e-20 ? 0 : z2R
        return wrote
    }
}

/// Dynamic Club PA Exciter & Drop Punch: adds chest-felt 105 Hz kick lift,
/// silky 9 kHz club air sheen, and warm parallel harmonic density during
/// transitions and drop landings, while smoothly easing back to bit-exact
/// bypass (`amount == 0`) during solo playback. Zero allocations, audio-thread safe.
struct ClubExciter {
    private let sampleRate: Double
    private let attackCoef: Float
    private let releaseCoef: Float
    private var lowShelf = Biquad()
    private var highShelf = Biquad()
    private var blend: Float = 0

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        attackCoef = Float(exp(-1.0 / (0.015 * sampleRate)))
        releaseCoef = Float(exp(-1.0 / (0.180 * sampleRate)))
        lowShelf.set(.lowShelf(frequency: 105, gainDB: 1.9), sampleRate: sampleRate)
        highShelf.set(.highShelf(frequency: 9_000, gainDB: 1.6), sampleRate: sampleRate)
    }

    mutating func reset() {
        lowShelf.reset()
        highShelf.reset()
        blend = 0
    }

    mutating func process(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>,
                          count: Int, amount: Float) {
        let target = max(0, min(1, amount))
        guard blend > 1e-4 || target > 1e-4, count > 0 else { return }
        let coef = target > blend ? attackCoef : releaseCoef
        var cur = blend
        // Process wet parallel club PA signal smoothly mixed by `cur` on a
        // fixed stack buffer (zero heap allocations) so transitions into and
        // out of solo playback are click-free and bit-exact when `blend == 0`.
        var offset = 0
        var bufL = (Float(0), Float(0), Float(0), Float(0), Float(0), Float(0), Float(0), Float(0),
                    Float(0), Float(0), Float(0), Float(0), Float(0), Float(0), Float(0), Float(0),
                    Float(0), Float(0), Float(0), Float(0), Float(0), Float(0), Float(0), Float(0),
                    Float(0), Float(0), Float(0), Float(0), Float(0), Float(0), Float(0), Float(0),
                    Float(0), Float(0), Float(0), Float(0), Float(0), Float(0), Float(0), Float(0),
                    Float(0), Float(0), Float(0), Float(0), Float(0), Float(0), Float(0), Float(0),
                    Float(0), Float(0), Float(0), Float(0), Float(0), Float(0), Float(0), Float(0),
                    Float(0), Float(0), Float(0), Float(0), Float(0), Float(0), Float(0), Float(0))
        var bufR = bufL
        while offset < count {
            let chunk = min(64, count - offset)
            withUnsafeMutableBytes(of: &bufL) { rawL in
                withUnsafeMutableBytes(of: &bufR) { rawR in
                    let wl = rawL.bindMemory(to: Float.self).baseAddress!
                    let wr = rawR.bindMemory(to: Float.self).baseAddress!
                    for i in 0..<chunk {
                        wl[i] = left[offset + i]
                        wr[i] = right[offset + i]
                    }
                    lowShelf.process(wl, wr, count: chunk)
                    highShelf.process(wl, wr, count: chunk)
                    for i in 0..<chunk {
                        cur = target + coef * (cur - target)
                        let dl = left[offset + i], dr = right[offset + i]
                        let xl = wl[i], xr = wr[i]
                        // Warm analog harmonic density on the wet club bus.
                        let sl = xl * 1.48 / (1 + 0.48 * abs(xl))
                        let sr = xr * 1.48 / (1 + 0.48 * abs(xr))
                        let punchL = (0.72 * xl + 0.28 * sl) * 0.90
                        let punchR = (0.72 * xr + 0.28 * sr) * 0.90
                        left[offset + i] = dl + cur * (punchL - dl)
                        right[offset + i] = dr + cur * (punchR - dr)
                    }
                }
            }
            offset += chunk
        }
        blend = cur < 1e-4 && target == 0 ? 0 : cur
        if blend == 0 {
            lowShelf.reset()
            highShelf.reset()
        }
    }
}
