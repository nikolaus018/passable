import Foundation

/// How B's own (source) frames map onto the frames it is played at.
///
/// B is held at A's tempo only while the two overlap. Up to `rampStart` it
/// plays at a constant `rate`; from there its tempo glides linearly back to
/// its original over `rampLength`, and after that the source plays untouched.
/// All positions are in frames; output frame 0 is source frame 0.
struct TimeMap: Equatable, Sendable {
    /// Source frames consumed per output frame before the glide.
    let rate: Double
    /// Output frame at which the glide starts (`.infinity`: never).
    let rampStart: Double
    let rampLength: Double

    static func constant(_ rate: Double) -> TimeMap {
        TimeMap(rate: rate, rampStart: .infinity, rampLength: 1)
    }

    /// A glide back to the original tempo. Its length is stretched by a
    /// fraction of a beat so that afterwards output and source differ by a
    /// whole number of frames: the rest of the track can then be copied from
    /// the source bit for bit instead of being processed at all.
    static func glide(rate: Double, rampStart: Double, rampLength: Double) -> TimeMap {
        guard abs(rate - 1) > 1e-9 else { return .constant(1) }
        let y0 = max(0, rampStart)
        // After the glide, source − output = (rate − 1)(y0 + D/2). Round it
        // in the direction that lengthens D rather than shortens it.
        let exact = (rate - 1) * (y0 + rampLength / 2)
        let offset = rate > 1 ? exact.rounded(.up) : exact.rounded(.down)
        let length = 2 * (offset / (rate - 1) - y0)
        return TimeMap(rate: rate, rampStart: y0, rampLength: max(1, length))
    }

    var isIdentity: Bool { rate == 1 }
    var hasGlide: Bool { rampStart.isFinite && !isIdentity }
    var rampEnd: Double { rampStart + rampLength }

    /// Source minus output once the glide is over (a whole number of frames).
    var tailOffset: Int? {
        guard hasGlide else { return isIdentity ? 0 : nil }
        return Int(((rate - 1) * (rampStart + rampLength / 2)).rounded())
    }

    /// Playback rate (source frames per output frame) at output frame `y`.
    func slope(at y: Double) -> Double {
        if y <= rampStart { return rate }
        if y >= rampEnd { return 1 }
        return rate + (1 - rate) * (y - rampStart) / rampLength
    }

    /// Source frame heard at output frame `y`.
    func source(_ y: Double) -> Double {
        if y <= rampStart { return rate * y }
        let u = min(y, rampEnd) - rampStart
        let x = rate * rampStart + rate * u + (1 - rate) * u * u / (2 * rampLength)
        return y > rampEnd ? x + (y - rampEnd) : x
    }

    /// Output frame at which source frame `x` is heard.
    func output(_ x: Double) -> Double {
        let x0 = rate * rampStart
        if !rampStart.isFinite || x <= x0 { return x / rate }
        let x1 = source(rampEnd)
        if x >= x1 { return rampEnd + (x - x1) }
        // (1 − r)/(2D)·u² + r·u − k = 0, in the cancellation-free form.
        let k = x - x0
        let a = (1 - rate) / (2 * rampLength)
        let u = 2 * k / (rate + (rate * rate + 4 * a * k).squareRoot())
        return rampStart + u
    }
}
