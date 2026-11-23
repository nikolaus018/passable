import Foundation

/// RBJ-cookbook biquad, transposed direct form II, stereo.
///
/// Coefficients may be recomputed every block (automation sweeps); TDF-II
/// keeps its state meaningful across coefficient changes, so sweeps don't
/// zipper or blow up.
struct Biquad {
    private var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
    private var z1L: Float = 0, z2L: Float = 0, z1R: Float = 0, z2R: Float = 0
    private(set) var isBypassed = true

    enum Kind: Equatable {
        case lowPass(frequency: Double, q: Double)
        case highPass(frequency: Double, q: Double)
        case lowShelf(frequency: Double, gainDB: Double)
        case highShelf(frequency: Double, gainDB: Double)
        case peak(frequency: Double, q: Double, gainDB: Double)
    }

    mutating func bypass() {
        if !isBypassed { reset() }
        isBypassed = true
    }

    mutating func reset() {
        z1L = 0; z2L = 0; z1R = 0; z2R = 0
    }

    mutating func set(_ kind: Kind, sampleRate: Double) {
        let nyquistSafe = sampleRate * 0.49
        var c0 = 1.0, c1 = 0.0, c2 = 0.0, d0 = 1.0, d1 = 0.0, d2 = 0.0
        switch kind {
        case let .lowPass(f, q), let .highPass(f, q):
            let w = 2 * Double.pi * min(f, nyquistSafe) / sampleRate
            let cw = cos(w), alpha = sin(w) / (2 * q)
            if case .lowPass = kind {
                c0 = (1 - cw) / 2; c1 = 1 - cw; c2 = (1 - cw) / 2
            } else {
                c0 = (1 + cw) / 2; c1 = -(1 + cw); c2 = (1 + cw) / 2
            }
            d0 = 1 + alpha; d1 = -2 * cw; d2 = 1 - alpha
        case let .lowShelf(f, g), let .highShelf(f, g):
            let a = pow(10, g / 40)
            let w = 2 * Double.pi * min(f, nyquistSafe) / sampleRate
            let cw = cos(w), sw = sin(w)
            let alpha = sw / 2 * sqrt(2) // shelf slope 1
            let sq = 2 * sqrt(a) * alpha
            if case .lowShelf = kind {
                c0 = a * ((a + 1) - (a - 1) * cw + sq)
                c1 = 2 * a * ((a - 1) - (a + 1) * cw)
                c2 = a * ((a + 1) - (a - 1) * cw - sq)
                d0 = (a + 1) + (a - 1) * cw + sq
                d1 = -2 * ((a - 1) + (a + 1) * cw)
                d2 = (a + 1) + (a - 1) * cw - sq
            } else {
                c0 = a * ((a + 1) + (a - 1) * cw + sq)
                c1 = -2 * a * ((a - 1) + (a + 1) * cw)
                c2 = a * ((a + 1) + (a - 1) * cw - sq)
                d0 = (a + 1) - (a - 1) * cw + sq
                d1 = 2 * ((a - 1) - (a + 1) * cw)
                d2 = (a + 1) - (a - 1) * cw - sq
            }
        case let .peak(f, q, g):
            let a = pow(10, g / 40)
            let w = 2 * Double.pi * min(f, nyquistSafe) / sampleRate
            let cw = cos(w), alpha = sin(w) / (2 * q)
            c0 = 1 + alpha * a; c1 = -2 * cw; c2 = 1 - alpha * a
            d0 = 1 + alpha / a; d1 = -2 * cw; d2 = 1 - alpha / a
        }
        b0 = Float(c0 / d0); b1 = Float(c1 / d0); b2 = Float(c2 / d0)
        a1 = Float(d1 / d0); a2 = Float(d2 / d0)
        isBypassed = false
    }

    mutating func process(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, count: Int) {
        guard !isBypassed else { return }
        for i in 0..<count {
            let xl = left[i]
            let yl = b0 * xl + z1L
            z1L = b1 * xl - a1 * yl + z2L
            z2L = b2 * xl - a2 * yl
            left[i] = yl

            let xr = right[i]
            let yr = b0 * xr + z1R
            z1R = b1 * xr - a1 * yr + z2R
            z2R = b2 * xr - a2 * yr
            right[i] = yr
        }
        // Flush denormals that creep in after a lane goes silent.
        if abs(z1L) < 1e-20 { z1L = 0 }
        if abs(z2L) < 1e-20 { z2L = 0 }
        if abs(z1R) < 1e-20 { z1R = 0 }
        if abs(z2R) < 1e-20 { z2R = 0 }
    }
}

/// Cytomic / Zero-Delay Feedback State Variable Filter (trapezoidal
/// integrator), stereo. Unconditionally stable and glitch-free under fast
/// cutoff modulation (DJ filter sweeps and 8 ms switches), with per-sample
/// cutoff interpolation and wet/dry crossfade into and out of bypass.
struct SVF {
    enum Mode: Equatable { case lowPass, highPass }

    private var ic1L: Float = 0, ic2L: Float = 0, ic1R: Float = 0, ic2R: Float = 0
    private var mode: Mode = .lowPass
    private var g: Float = 0, gTarget: Float = 0
    private var k: Float = 1 / 0.85
    private var mix: Float = 0, mixTarget: Float = 0

    var isBypassed: Bool { mix == 0 && mixTarget == 0 }

    mutating func reset() {
        ic1L = 0; ic2L = 0; ic1R = 0; ic2R = 0
        mix = 0; mixTarget = 0
    }

    mutating func setBypass() {
        mixTarget = 0
    }

    mutating func set(_ newMode: Mode, frequency: Double, q: Double = 0.85, sampleRate: Double) {
        let f = max(10, min(frequency, sampleRate * 0.49))
        let newG = Float(tan(Double.pi * f / sampleRate))
        let newK = Float(1.0 / max(0.5, q))
        // When waking from full bypass or changing mode across centre,
        // snap directly to the target cutoff and fade in cleanly.
        if mix == 0 || newMode != mode {
            if newMode != mode && mix > 0 {
                ic1L = 0; ic2L = 0; ic1R = 0; ic2R = 0
            }
            mode = newMode
            g = newG
        }
        gTarget = newG
        k = newK
        mixTarget = 1
    }

    mutating func process(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, count: Int) {
        guard mix > 0 || mixTarget > 0, count > 0 else { return }
        let invN = 1 / Float(count)
        let dg = (gTarget - g) * invN
        let dm = (mixTarget - mix) * invN
        let kk = k
        let isLP = mode == .lowPass
        var curG = g, curM = mix
        var s1L = ic1L, s2L = ic2L, s1R = ic1R, s2R = ic2R

        if dg == 0 && dm == 0 && curM == 1 {
            let a1 = 1 / (1 + curG * (curG + kk))
            let a2 = curG * a1
            let a3 = curG * a2
            for i in 0..<count {
                let xl = left[i]
                let v3L = xl - s2L
                let v1L = a1 * s1L + a2 * v3L
                let v2L = s2L + a2 * s1L + a3 * v3L
                s1L = 2 * v1L - s1L
                s2L = 2 * v2L - s2L
                left[i] = isLP ? v2L : (xl - kk * v1L - v2L)

                let xr = right[i]
                let v3R = xr - s2R
                let v1R = a1 * s1R + a2 * v3R
                let v2R = s2R + a2 * s1R + a3 * v3R
                s1R = 2 * v1R - s1R
                s2R = 2 * v2R - s2R
                right[i] = isLP ? v2R : (xr - kk * v1R - v2R)
            }
        } else {
            for i in 0..<count {
                curG += dg
                curM += dm
                let a1 = 1 / (1 + curG * (curG + kk))
                let a2 = curG * a1
                let a3 = curG * a2

                let xl = left[i]
                let v3L = xl - s2L
                let v1L = a1 * s1L + a2 * v3L
                let v2L = s2L + a2 * s1L + a3 * v3L
                s1L = 2 * v1L - s1L
                s2L = 2 * v2L - s2L
                let yl = isLP ? v2L : (xl - kk * v1L - v2L)
                left[i] = xl + curM * (yl - xl)

                let xr = right[i]
                let v3R = xr - s2R
                let v1R = a1 * s1R + a2 * v3R
                let v2R = s2R + a2 * s1R + a3 * v3R
                s1R = 2 * v1R - s1R
                s2R = 2 * v2R - s2R
                let yr = isLP ? v2R : (xr - kk * v1R - v2R)
                right[i] = xr + curM * (yr - xr)
            }
        }

        g = gTarget
        mix = mixTarget
        if mix == 0 {
            ic1L = 0; ic2L = 0; ic1R = 0; ic2R = 0
        } else {
            ic1L = abs(s1L) < 1e-20 ? 0 : s1L
            ic2L = abs(s2L) < 1e-20 ? 0 : s2L
            ic1R = abs(s1R) < 1e-20 ? 0 : s1R
            ic2R = abs(s2R) < 1e-20 ? 0 : s2R
        }
    }
}

/// 24 dB/oct DJ filter: two cascaded Cytomic ZDF SVFs with gentle dynamic
/// resonance mid-sweep (~+1.6 dB total at cutoff) that flattens cleanly into
/// bypass at the extremes.
struct DJFilter {
    private var stage1 = SVF()
    private var stage2 = SVF()

    var isBypassed: Bool { stage1.isBypassed && stage2.isBypassed }

    mutating func reset() {
        stage1.reset()
        stage2.reset()
    }

    mutating func setBypass() {
        stage1.setBypass()
        stage2.setBypass()
    }

    /// Musical resonance curve: flat Butterworth (0.707) near bypass and at
    /// sub/air extremes, rising to ~0.98 per stage in the sweet spot
    /// (200 Hz–4 kHz) for a Pioneer DJM-style liquid analog sweep bite.
    static func resonance(for frequency: Double, mode: SVF.Mode) -> Double {
        let logF = log2(max(20, min(20_000, frequency)))
        // Peak resonance around 300 Hz–3 kHz (log2 ≈ 8.2–11.5), tapering smoothly
        // to 0.707 near 20 Hz and 18 kHz.
        let lowEdge = mode == .highPass ? 5.0 : 6.0   // ~32 Hz / 64 Hz
        let highEdge = mode == .lowPass ? 13.8 : 13.5 // ~14 kHz / 11.5 kHz
        guard logF > lowEdge, logF < highEdge else { return 0.7071 }
        let u = (logF - lowEdge) / (highEdge - lowEdge)
        let bell = sin(Double.pi * u)
        return 0.7071 + 0.273 * bell * bell
    }

    mutating func set(_ mode: SVF.Mode, frequency: Double, sampleRate: Double) {
        let q = Self.resonance(for: frequency, mode: mode)
        stage1.set(mode, frequency: frequency, q: q, sampleRate: sampleRate)
        stage2.set(mode, frequency: frequency, q: q, sampleRate: sampleRate)
    }

    mutating func process(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, count: Int) {
        guard !isBypassed else { return }
        stage1.process(left, right, count: count)
        stage2.process(left, right, count: count)
    }
}

/// 6th-order Butterworth Cytomic ZDF SVF low-end isolator/shelf (105 Hz).
///
/// Unlike crossfading dry audio against a high-pass filter (which notches out
/// 150–250 Hz via phase cancellation whenever partially cut), every gain from
/// +6 dB down to a −54 dB sub kill is a monotonic, phase-coherent shelf whose
/// transfer function is identically `1.0` (0° phase shift) at 0 dB.
struct LowIsolator {
    static let frequency = 105.0
    static let killDecibels = -54.0
    private static let qs: [Double] = [0.51763809, 0.70710678, 1.93185165]

    private struct Stage {
        let k: Float
        var s1L: Float = 0, s2L: Float = 0, s1R: Float = 0, s2R: Float = 0
        var g: Float = 0, m1: Float = 0, m2: Float = 0
        var gTarget: Float = 0, m1Target: Float = 0, m2Target: Float = 0
        var active = false

        init(q: Double, sampleRate: Double) {
            k = Float(1.0 / q)
            let g0 = Float(tan(Double.pi * LowIsolator.frequency / sampleRate))
            g = g0; gTarget = g0
        }

        mutating func reset(sampleRate: Double) {
            s1L = 0; s2L = 0; s1R = 0; s2R = 0
            let g0 = Float(tan(Double.pi * LowIsolator.frequency / sampleRate))
            g = g0; gTarget = g0
            m1 = 0; m2 = 0; m1Target = 0; m2Target = 0
            active = false
        }

        mutating func set(gainDB: Double, sampleRate: Double) {
            let clamped = max(-20.0, min(6.0, gainDB))
            let a = pow(10.0, clamped / 40.0)
            let newG = Float(tan(Double.pi * LowIsolator.frequency / sampleRate) / sqrt(a))
            let newM1 = k * Float(a - 1.0)
            let newM2 = Float(a * a - 1.0)
            if !active {
                g = newG
                s1L = 0; s2L = 0; s1R = 0; s2R = 0
            }
            gTarget = newG
            m1Target = newM1
            m2Target = newM2
            if abs(newM1) > 1e-6 || abs(newM2) > 1e-6 { active = true }
        }

        mutating func process(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, count: Int) {
            guard active, count > 0 else { return }
            let invN = 1 / Float(count)
            let dg = (gTarget - g) * invN
            let dm1 = (m1Target - m1) * invN
            let dm2 = (m2Target - m2) * invN
            var curG = g, curM1 = m1, curM2 = m2
            let kk = k
            var z1L = s1L, z2L = s2L, z1R = s1R, z2R = s2R

            if dg == 0 && dm1 == 0 && dm2 == 0 {
                let a1 = 1 / (1 + curG * (curG + kk))
                let a2 = curG * a1
                let a3 = curG * a2
                for i in 0..<count {
                    let xl = left[i]
                    let v3L = xl - z2L
                    let v1L = a1 * z1L + a2 * v3L
                    let v2L = z2L + a2 * z1L + a3 * v3L
                    z1L = 2 * v1L - z1L
                    z2L = 2 * v2L - z2L
                    left[i] = xl + curM1 * v1L + curM2 * v2L

                    let xr = right[i]
                    let v3R = xr - z2R
                    let v1R = a1 * z1R + a2 * v3R
                    let v2R = z2R + a2 * z1R + a3 * v3R
                    z1R = 2 * v1R - z1R
                    z2R = 2 * v2R - z2R
                    right[i] = xr + curM1 * v1R + curM2 * v2R
                }
            } else {
                for i in 0..<count {
                    curG += dg
                    curM1 += dm1
                    curM2 += dm2
                    let a1 = 1 / (1 + curG * (curG + kk))
                    let a2 = curG * a1
                    let a3 = curG * a2

                    let xl = left[i]
                    let v3L = xl - z2L
                    let v1L = a1 * z1L + a2 * v3L
                    let v2L = z2L + a2 * z1L + a3 * v3L
                    z1L = 2 * v1L - z1L
                    z2L = 2 * v2L - z2L
                    left[i] = xl + curM1 * v1L + curM2 * v2L

                    let xr = right[i]
                    let v3R = xr - z2R
                    let v1R = a1 * z1R + a2 * v3R
                    let v2R = z2R + a2 * z1R + a3 * v3R
                    z1R = 2 * v1R - z1R
                    z2R = 2 * v2R - z2R
                    right[i] = xr + curM1 * v1R + curM2 * v2R
                }
            }

            g = gTarget; m1 = m1Target; m2 = m2Target
            if abs(m1Target) < 1e-6 && abs(m2Target) < 1e-6 {
                active = false
                s1L = 0; s2L = 0; s1R = 0; s2R = 0
            } else {
                s1L = abs(z1L) < 1e-20 ? 0 : z1L
                s2L = abs(z2L) < 1e-20 ? 0 : z2L
                s1R = abs(z1R) < 1e-20 ? 0 : z1R
                s2R = abs(z2R) < 1e-20 ? 0 : z2R
            }
        }
    }

    private var s0: Stage
    private var s1: Stage
    private var s2: Stage
    private var currentDB = 0.0

    var isBypassed: Bool { !s0.active && !s1.active && !s2.active }

    init(sampleRate: Double = AudioIO.sampleRate) {
        s0 = Stage(q: Self.qs[0], sampleRate: sampleRate)
        s1 = Stage(q: Self.qs[1], sampleRate: sampleRate)
        s2 = Stage(q: Self.qs[2], sampleRate: sampleRate)
    }

    mutating func reset(sampleRate: Double = AudioIO.sampleRate) {
        s0.reset(sampleRate: sampleRate)
        s1.reset(sampleRate: sampleRate)
        s2.reset(sampleRate: sampleRate)
        currentDB = 0
    }

    /// Sets the low band gain in dB (0 = transparent bypass, down to `killDecibels`
    /// for a full sub kill, up to +6 dB for boost).
    mutating func set(gainDB: Double, sampleRate: Double) {
        let target = abs(gainDB) < 0.05 ? 0.0 : gainDB
        guard abs(target - currentDB) > 1e-4 else { return }
        currentDB = target
        let perStage = target / 3.0
        s0.set(gainDB: perStage, sampleRate: sampleRate)
        s1.set(gainDB: perStage, sampleRate: sampleRate)
        s2.set(gainDB: perStage, sampleRate: sampleRate)
    }

    mutating func process(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, count: Int) {
        guard !isBypassed else { return }
        s0.process(left, right, count: count)
        s1.process(left, right, count: count)
        s2.process(left, right, count: count)
    }
}

/// Mid-channel vocal-band dipper: attenuates center-panned 400 Hz–3.5 kHz
/// energy by up to ~4.5 dB while leaving the stereo Side channel completely
/// untouched. Used on an `other` stem during a blend when that song's vocal
/// stem is muted, hiding leftover separation bleed without thinning wide
/// synths or guitars.
struct MidVocalDipper {
    private var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
    private var z1: Float = 0, z2: Float = 0
    private var amount: Float = 0

    init(sampleRate: Double = AudioIO.sampleRate) {
        let a = pow(10.0, -4.5 / 40.0)
        let w = 2 * Double.pi * 1_500 / sampleRate
        let cw = cos(w), alpha = sin(w) / (2 * 0.65)
        let d0 = 1 + alpha / a
        b0 = Float((1 + alpha * a) / d0)
        b1 = Float((-2 * cw) / d0)
        b2 = Float((1 - alpha * a) / d0)
        a1 = Float((-2 * cw) / d0)
        a2 = Float((1 - alpha / a) / d0)
    }

    mutating func reset() {
        z1 = 0; z2 = 0
        amount = 0
    }

    mutating func process(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>,
                          count: Int, target: Float, sampleRate: Double) {
        guard amount > 1e-4 || target > 1e-4, count > 0 else { return }
        let alpha = Float(exp(-Double(count) / (0.04 * sampleRate)))
        let next = target + alpha * (amount - target)
        let slope = (next - amount) / Float(count)
        var cur = amount, s1 = z1, s2 = z2
        for i in 0..<count {
            cur += slope
            let origMid = 0.5 * (left[i] + right[i])
            let y = b0 * origMid + s1
            s1 = b1 * origMid - a1 * y + s2
            s2 = b2 * origMid - a2 * y
            let delta = cur * (y - origMid)
            left[i] += delta
            right[i] += delta
        }
        amount = next < 1e-4 && target == 0 ? 0 : next
        if amount == 0 {
            z1 = 0; z2 = 0
        } else {
            z1 = abs(s1) < 1e-20 ? 0 : s1
            z2 = abs(s2) < 1e-20 ? 0 : s2
        }
    }
}
