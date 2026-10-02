import Foundation

/// How B's own (source) frames map onto the frames it is played at.
///
/// B is held at A's tempo only while the two overlap. Up to `rampStart` it
/// plays at a constant `rate`; from there its tempo glides linearly back to
/// its original over `rampLength`, and after that the source plays untouched.
/// All positions are in frames; output frame 0 is source frame 0.
///
/// A track that is itself mixed out of at another tempo than its own (the
/// two songs of a blend meet half-way, see `MixMath.shared`) has a way out
/// too: from `exitStart`, well after the glide home, its tempo glides over
/// `exitLength` to `exitRate` and stays there to its end.
struct TimeMap: Equatable, Sendable {
    /// Source frames consumed per output frame before the glide.
    let rate: Double
    /// Output frame at which the glide starts (`.infinity`: never).
    let rampStart: Double
    let rampLength: Double
    /// Output frame at which the way out starts (`.infinity`: none), the
    /// output frames its glide takes, and the rate it glides to.
    var exitStart = Double.infinity
    var exitLength = 1.0
    var exitRate = 1.0

    static func constant(_ rate: Double) -> TimeMap {
        TimeMap(rate: rate, rampStart: .infinity, rampLength: 1)
    }

    /// Rates closer to 1 than this are the same tempo: under a millisecond
    /// over minutes of music. Aligning a glide to whole frames lengthens it
    /// by up to 2 / |rate − 1| frames, which for tempos this close would be
    /// longer than the song (120.00017 against 120.00018 BPM: 230 bars).
    static let sameTempo = 1e-5

    /// A glide back to the original tempo. Its length is stretched by a
    /// fraction of a beat so that afterwards output and source differ by a
    /// whole number of frames: the rest of the track can then be copied from
    /// the source bit for bit instead of being processed at all.
    static func glide(rate: Double, rampStart: Double, rampLength: Double) -> TimeMap {
        guard abs(rate - 1) >= sameTempo else { return .constant(1) }
        let y0 = max(0, rampStart)
        // After the glide, source − output = (rate − 1)(y0 + D/2). Round it
        // in the direction that lengthens D rather than shortens it.
        let exact = (rate - 1) * (y0 + rampLength / 2)
        let offset = rate > 1 ? exact.rounded(.up) : exact.rounded(.down)
        let length = 2 * (offset / (rate - 1) - y0)
        return TimeMap(rate: rate, rampStart: y0, rampLength: max(1, length))
    }

    /// The same map with a way out: from output frame `start` (where the
    /// track plays at its own tempo) the tempo glides over `length` output
    /// frames to `rate`.
    func exiting(at start: Double, length: Double, rate: Double) -> TimeMap {
        guard abs(rate - 1) >= Self.sameTempo else { return self }
        var map = self
        map.exitStart = max(start, hasGlide ? rampEnd : 0)
        map.exitLength = max(1, length)
        map.exitRate = rate
        return map
    }

    var hasExit: Bool { exitStart.isFinite && exitRate != 1 }
    var exitEnd: Double { exitStart + exitLength }
    var isIdentity: Bool { rate == 1 && !hasExit }
    var hasGlide: Bool { rampStart.isFinite && rate != 1 }
    var rampEnd: Double { rampStart + rampLength }

    /// Source minus output once the glide is over, until any way out (a
    /// whole number of frames).
    var tailOffset: Int? {
        guard hasGlide else { return rate == 1 ? 0 : nil }
        return Int(((rate - 1) * (rampStart + rampLength / 2)).rounded())
    }

    /// Playback rate (source frames per output frame) at output frame `y`.
    func slope(at y: Double) -> Double {
        if hasExit, y > exitStart {
            return y >= exitEnd ? exitRate : 1 + (exitRate - 1) * (y - exitStart) / exitLength
        }
        if y <= rampStart { return rate }
        if y >= rampEnd { return 1 }
        return rate + (1 - rate) * (y - rampStart) / rampLength
    }

    /// Source frame heard at output frame `y`.
    func source(_ y: Double) -> Double {
        guard hasExit, y > exitStart else { return entrySource(y) }
        let u = min(y, exitEnd) - exitStart
        let x = entrySource(exitStart) + u + (exitRate - 1) * u * u / (2 * exitLength)
        return y > exitEnd ? x + exitRate * (y - exitEnd) : x
    }

    /// Output frame at which source frame `x` is heard.
    func output(_ x: Double) -> Double {
        guard hasExit else { return entryOutput(x) }
        let x0 = entrySource(exitStart)
        if x <= x0 { return entryOutput(x) }
        // u + a·u² = k through the glide, then a constant rate.
        let k = x - x0
        let a = (exitRate - 1) / (2 * exitLength)
        let glided = exitLength + a * exitLength * exitLength
        if k >= glided { return exitEnd + (k - glided) / exitRate }
        return exitStart + 2 * k / (1 + (1 + 4 * a * k).squareRoot())
    }

    /// `source` and `output` of the way in alone.
    private func entrySource(_ y: Double) -> Double {
        if y <= rampStart { return rate * y }
        let u = min(y, rampEnd) - rampStart
        let x = rate * rampStart + rate * u + (1 - rate) * u * u / (2 * rampLength)
        return y > rampEnd ? x + (y - rampEnd) : x
    }

    private func entryOutput(_ x: Double) -> Double {
        let x0 = rate * rampStart
        if !rampStart.isFinite || x <= x0 { return x / rate }
        let x1 = entrySource(rampEnd)
        if x >= x1 { return rampEnd + (x - x1) }
        // (1 − r)/(2D)·u² + r·u − k = 0, in the cancellation-free form.
        let k = x - x0
        let a = (1 - rate) / (2 * rampLength)
        let u = 2 * k / (rate + (rate * rate + 4 * a * k).squareRoot())
        return rampStart + u
    }
}
