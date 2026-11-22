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
    /// Feedback per loop pass (~3.8 s RT60 on the mean delay length).
    var feedback: Float = 0.89
    var damp: Float = 0.34

    init(sampleRate: Double) {
        let scale = sampleRate / 44_100
        lines = (0..<Self.channels).map { c in
            let delay = max(16, Int((Double(Self.baseLengths[c]) * scale).rounded()))
            return Line(delay: delay, phase: Float(c) * 0.785398, rate: Self.lfoRates[c], sampleRate: sampleRate)
        }
        // Keep sub-bass out of the tail; a reverbed kick is mud.
        inputFilter.set(.highPass(frequency: 250, q: 0.707), sampleRate: sampleRate)
    }

    mutating func reset() {
        for i in lines.indices { lines[i].clear() }
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
        for i in 0..<count {
            let xl = left[i] * inGain
            let xr = right[i] * inGain
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
            hpCoef = Float(exp(-2 * Double.pi * 350 / sampleRate))
            lpCoef = Float(exp(-2 * Double.pi * 5_000 / sampleRate))
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
    private var delaySamples: Int
    var feedback: Float = 0.55

    init(sampleRate: Double, maxSeconds: Double = 4) {
        let size = Int(sampleRate * maxSeconds)
        bufferL = [Float](repeating: 0, count: size)
        bufferR = [Float](repeating: 0, count: size)
        delaySamples = Int(sampleRate * 0.35)
        toneL = Tone(sampleRate: sampleRate)
        toneR = Tone(sampleRate: sampleRate)
    }

    mutating func reset() {
        bufferL.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
        bufferR.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
        toneL = Tone(hpCoef: toneL.hpCoef, lpCoef: toneL.lpCoef)
        toneR = Tone(hpCoef: toneR.hpCoef, lpCoef: toneR.lpCoef)
    }

    mutating func setTime(seconds: Double, sampleRate: Double) {
        delaySamples = max(1, min(bufferL.count - 1, Int(seconds * sampleRate)))
    }

    /// Replaces the send bus with the wet signal.
    mutating func process(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, count: Int) {
        let size = bufferL.count
        for i in 0..<count {
            var readIndex = writeIndex - delaySamples
            if readIndex < 0 { readIndex += size }
            let dl = toneL.process(bufferL[readIndex])
            let dr = toneR.process(bufferR[readIndex])
            // Mono input into the left line; each line feeds the other.
            let input = (left[i] + right[i]) * 0.5
            bufferL[writeIndex] = input + dr * feedback
            bufferR[writeIndex] = dl * feedback
            left[i] = dl
            right[i] = dr
            writeIndex += 1
            if writeIndex == size { writeIndex = 0 }
        }
    }
}

/// Peak limiter at −0.3 dBFS with `lookahead` frames of look-ahead:
/// it sees a peak coming and lowers the gain smoothly into it (over the
/// look-ahead), instead of jumping the gain on the peak itself (which is
/// heard as a crackle), then lets it back over 150 ms. Stereo-linked. The
/// output runs `lookahead` frames behind the input; `MixRenderer` renders
/// that far ahead, so what plays stays on time. A safety net for summing
/// eight stems, not a mastering tool.
struct Limiter {
    static let lookahead = 88  // 2 ms
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
    private var needed: [Float], least: [Float]
    private var index = 0
    /// Frames in the window that need the gain down.
    private var pending = 0
    private var leastSum: Float
    private var gain: Float = 1
    /// Smoothed gain reduction (0…1) to distinguish isolated transient
    /// spikes (fast recovery, no pumping) from sustained dense limiting
    /// (slower release, no distortion).
    private var sustained: Float = 0

    init(sampleRate: Double, ceiling: Float = Limiter.playbackCeiling) {
        self.ceiling = ceiling
        fastRelease = Float(exp(-1 / (0.04 * sampleRate)))
        slowRelease = Float(exp(-1 / (0.15 * sampleRate)))
        holdAlpha = Float(exp(-1 / (0.03 * sampleRate)))
        let n = Self.lookahead + 1
        delayL = [Float](repeating: 0, count: n)
        delayR = delayL
        needed = [Float](repeating: 1, count: n)
        least = needed
        leastSum = Float(n)
    }

    mutating func reset() {
        let n = Self.lookahead + 1
        for k in 0..<n { delayL[k] = 0; delayR[k] = 0; needed[k] = 1; least[k] = 1 }
        leastSum = Float(n)
        gain = 1
        sustained = 0
        index = 0
        pending = 0
    }

    /// In place: frame `i` out is frame `i - lookahead` in, limited. The
    /// gain on an output frame is the mean, over the window ending there,
    /// of the least gain each frame of the window needed over the window
    /// after it: every term covers the frame itself, so the peak is never
    /// over the ceiling, and the gain glides into it.
    mutating func process(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, count: Int) {
        let n = Self.lookahead + 1
        for i in 0..<count {
            let peak = max(abs(left[i]), abs(right[i]))
            if needed[index] < 1 { pending -= 1 }
            needed[index] = peak > ceiling ? ceiling / peak : 1
            if needed[index] < 1 { pending += 1 }
            // (Nearly always nothing in the window is over: no search.)
            var m: Float = 1
            if pending > 0 { for k in 0..<n where needed[k] < m { m = needed[k] } }
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
            let next = (index + 1) % n
            let outL = delayL[next], outR = delayR[next]
            delayL[index] = left[i]
            delayR[index] = right[i]
            left[i] = outL * gain
            right[i] = outR * gain
            index = next
        }
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
    private var scPrev: Float = 0, scState: Float = 0
    private var subSideState: Float = 0
    private var env: Float = 0
    private var blend: Float = 0

    init(sampleRate: Double) {
        attackCoef = Float(exp(-1.0 / (0.025 * sampleRate)))
        releaseCoef = Float(exp(-1.0 / (0.120 * sampleRate)))
        blendCoef = Float(exp(-1.0 / (0.120 * sampleRate)))
        scHpCoef = Float(exp(-2.0 * Double.pi * 120.0 / sampleRate))
        subLpCoef = Float(exp(-2.0 * Double.pi * 100.0 / sampleRate))
    }

    mutating func reset() {
        scPrev = 0; scState = 0; subSideState = 0; env = 0; blend = 0
    }

    mutating func process(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>,
                          count: Int, active: Bool) {
        let target: Float = active ? 1 : 0
        guard blend > 1e-4 || target > 0, count > 0 else { return }
        let atk = attackCoef, rel = releaseCoef, bCoef = blendCoef, hp = scHpCoef
        let subA = subLpCoef, subB = 1 - subLpCoef
        // Threshold −9 dBFS (~0.355), soft knee 4 dB, ratio 2:1, max −3.5 dB GR.
        let threshDB: Float = -9.0
        let knee: Float = 4.0
        let invRatioDiff: Float = 0.5 // 1 - 1/2
        var curBlend = blend, curEnv = env, curPrev = scPrev, curHp = scState, curSub = subSideState
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
            let applied = min(3.5, grDB) * curBlend
            if applied > 1e-4 {
                let g = powf(10, -applied / 20)
                l *= g
                r *= g
            }
            left[i] = l
            right[i] = r
        }
        blend = curBlend < 1e-4 && !active ? 0 : curBlend
        env = curEnv < 1e-20 ? 0 : curEnv
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

        // Mid-block filter parameters (updated once per 64-sample block = smooth).
        let midP = position + count / 2
        let freq: Double
        let k: Float
        if midP < sw.drop {
            let u = max(0.0, min(1.0, Double(midP - sw.start) / Double(riserSpan)))
            freq = 500.0 * pow(11.0, u * u) // 500 Hz → 5.5 kHz
            k = Float(1.0 / 1.6)
        } else {
            let v = max(0.0, min(1.0, Double(midP - sw.drop) / Double(downSpan)))
            freq = 3_800.0 * pow(320.0 / 3_800.0, pow(v, 0.7)) // 3.8 kHz → 320 Hz
            k = Float(1.0 / 1.1)
        }
        let g = Float(tan(Double.pi * min(freq, sampleRate * 0.42) / sampleRate))
        let a1 = 1 / (1 + g * (g + k))
        let a2 = g * a1
        let a3 = g * a2

        var z1L = s1L, z2L = s2L, z1R = s1R, z2R = s2R
        var wrote = false
        for i in 0..<count {
            let p = position + i
            var env: Float = 0
            if p >= sw.start && p < riserEnd {
                let u = Float(p - sw.start) / Float(riserSpan)
                env = 0.075 * u * u
                let rem = riserEnd - p
                if rem < cutFade {
                    let fu = Float(rem) / Float(cutFade)
                    env *= 0.5 * (1 - cosf(Float.pi * fu))
                }
            } else if p >= sw.drop && p < sw.end {
                let v = Float(p - sw.drop) / Float(downSpan)
                let omv = 1 - v
                env = 0.068 * omv * omv
                let elapsed = p - sw.drop
                if elapsed < attackFade {
                    env *= Float(elapsed) / Float(attackFade)
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
            revL[i] += outL * 0.35
            revR[i] += outR * 0.35
        }
        s1L = abs(z1L) < 1e-20 ? 0 : z1L
        s2L = abs(z2L) < 1e-20 ? 0 : z2L
        s1R = abs(z1R) < 1e-20 ? 0 : z1R
        s2R = abs(z2R) < 1e-20 ? 0 : z2R
        return wrote
    }
}
