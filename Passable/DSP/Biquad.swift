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
