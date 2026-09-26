import Foundation

/// Freeverb (Jezar's public-domain design): eight parallel damped combs and
/// four series allpasses per channel, the right channel detuned for width.
/// Tuned long and dark — it's for washing out a track's tail, not for rooms.
struct Reverb {
    private struct Comb {
        var buffer: [Float]
        var index = 0
        var store: Float = 0
        init(_ size: Int) { buffer = [Float](repeating: 0, count: size) }

        mutating func clear() {
            buffer.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
            store = 0
        }

        mutating func process(_ x: Float, feedback: Float, damp: Float) -> Float {
            let y = buffer[index]
            store = y * (1 - damp) + store * damp
            buffer[index] = x + store * feedback
            index += 1
            if index == buffer.count { index = 0 }
            return y
        }
    }

    private struct Allpass {
        var buffer: [Float]
        var index = 0
        init(_ size: Int) { buffer = [Float](repeating: 0, count: size) }

        mutating func clear() {
            buffer.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
        }

        mutating func process(_ x: Float) -> Float {
            let b = buffer[index]
            buffer[index] = x + b * 0.5
            index += 1
            if index == buffer.count { index = 0 }
            return b - x
        }
    }

    private var combsL: [Comb]
    private var combsR: [Comb]
    private var allpassL: [Allpass]
    private var allpassR: [Allpass]
    private var inputFilter = Biquad()
    var feedback: Float = 0.9
    var damp: Float = 0.35

    init(sampleRate: Double) {
        let scale = sampleRate / 44_100
        let combs = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617]
        let allpasses = [556, 441, 341, 225]
        let spread = 23
        combsL = combs.map { Comb(Int(Double($0) * scale)) }
        combsR = combs.map { Comb(Int(Double($0 + spread) * scale)) }
        allpassL = allpasses.map { Allpass(Int(Double($0) * scale)) }
        allpassR = allpasses.map { Allpass(Int(Double($0 + spread) * scale)) }
        // Keep sub-bass out of the tail; a reverbed kick is mud.
        inputFilter.set(.highPass(frequency: 250, q: 0.707), sampleRate: sampleRate)
    }

    mutating func reset() {
        for i in combsL.indices {
            combsL[i].clear()
            combsR[i].clear()
        }
        for i in allpassL.indices {
            allpassL[i].clear()
            allpassR[i].clear()
        }
        inputFilter.reset()
    }

    /// Replaces the contents of `left`/`right` (the send bus) with the wet signal.
    mutating func process(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, count: Int) {
        inputFilter.process(left, right, count: count)
        let fb = feedback, dp = damp
        for i in 0..<count {
            let input = (left[i] + right[i]) * 0.015
            var outL: Float = 0, outR: Float = 0
            for c in 0..<combsL.count {
                outL += combsL[c].process(input, feedback: fb, damp: dp)
                outR += combsR[c].process(input, feedback: fb, damp: dp)
            }
            for a in 0..<allpassL.count {
                outL = allpassL[a].process(outL)
                outR = allpassR[a].process(outR)
            }
            left[i] = outL
            right[i] = outR
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

/// Peak limiter at −0.3 dBFS: instant attack, 150 ms release, stereo-linked.
/// A safety net for summing eight stems, not a mastering tool.
struct Limiter {
    private var envelope: Float = 0
    private let release: Float
    private let ceiling: Float = 0.966

    init(sampleRate: Double) {
        release = Float(exp(-1 / (0.15 * sampleRate)))
    }

    mutating func process(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, count: Int) {
        for i in 0..<count {
            let peak = max(abs(left[i]), abs(right[i]))
            envelope = peak > envelope ? peak : envelope * release + peak * (1 - release)
            if envelope > ceiling {
                let g = ceiling / envelope
                left[i] *= g
                right[i] *= g
            }
        }
    }
}
