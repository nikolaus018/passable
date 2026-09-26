import Accelerate

/// Tempo and pitch matching for one stem, following a `TimeMap`.
///
/// Everything here is sample-exact: an event at source frame `x` is heard at
/// output frame `map.output(x)`, full stop. (AUTimePitch, used before, let the
/// beat wander tens of milliseconds back and forth over a track, which no
/// latency compensation can undo — audible as flamming kicks and a bass that
/// never quite sits.)
///
/// - Tonal stems go through a phase-locked vocoder with a phase reset on
///   note onsets; pitch shifts are a vocoder stretch followed by a sinc
///   resample.
/// - Drums keep their original transients: each hit is copied straight from
///   the source onto its new position, with the vocoder only filling the
///   gaps between hits when B is slowed down (Ableton's "Beats" mode, more
///   or less).
/// - Once a glide back to the original tempo has finished, the source is
///   copied verbatim.
enum TimeStretcher {
    static func process(_ input: StereoBuffer, map: TimeMap, semitones: Int, percussive: Bool) -> StereoBuffer {
        let total = max(0, Int(map.output(Double(input.count)).rounded(.down)))
        if map.isIdentity && semitones == 0 { return input }

        let pitch = pow(2, Double(semitones) / 12)
        // Where the untouched tail takes over, if there is one.
        let fade = 2048
        var tailStart: Int?
        if semitones == 0, map.hasGlide, let _ = map.tailOffset {
            tailStart = min(total, Int(map.rampEnd.rounded(.up)))
        }
        let size = percussive ? 2048 : 4096
        let processed = tailStart.map { min(total, $0 + fade + size) } ?? total

        let mono = input.mono()
        let onsets = Onsets.detect(mono, sensitivity: percussive ? 0.06 : 0.25)

        var out: StereoBuffer
        if pitch == 1 {
            out = PhaseVocoder(size: size).process(input, count: processed, source: map.source, onsets: onsets)
        } else {
            // Stretch by rate/pitch, then play the result `pitch` times
            // faster: tempo as mapped, pitch shifted.
            let taps = Resampler.halfWidth(step: pitch) + 2
            let zCount = Int((Double(processed) * pitch).rounded(.up)) + taps
            let z = PhaseVocoder(size: size).process(input, count: zCount, source: { map.source($0 / pitch) },
                                                     onsets: onsets)
            out = StereoBuffer(left: Resampler.resample(z.left, step: pitch, count: processed),
                               right: Resampler.resample(z.right, step: pitch, count: processed))
        }

        if percussive && semitones == 0 {
            TransientCopy.apply(to: &out, source: input, map: map, onsets: onsets, until: tailStart ?? total)
        }

        if let start = tailStart, let offset = map.tailOffset {
            // Cross-fade into the source itself.
            let missing = [Float](repeating: 0, count: max(0, total - out.count))
            out.left.append(contentsOf: missing)
            out.right.append(contentsOf: missing)
            for y in start..<total {
                let x = y + offset
                let inside = x >= 0 && x < input.count
                let l = inside ? input.left[x] : 0
                let r = inside ? input.right[x] : 0
                let u = y - start
                if u < fade {
                    let g = Float(0.5 - 0.5 * cos(Double.pi * Double(u) / Double(fade)))
                    out.left[y] = out.left[y] * (1 - g) + l * g
                    out.right[y] = out.right[y] * (1 - g) + r * g
                } else {
                    out.left[y] = l
                    out.right[y] = r
                }
            }
        }
        if out.count > total {
            out.left.removeLast(out.count - total)
            out.right.removeLast(out.count - total)
        }
        return out
    }
}

// MARK: - Onsets

enum Onsets {
    /// Onset positions (source frames, ascending) from spectral flux.
    /// `sensitivity` is the fraction of the strongest onset a peak needs.
    static func detect(_ mono: [Float], sensitivity: Float) -> [Int] {
        let flux = TempoEstimator.onsetEnvelopes(mono, sampleRate: AudioIO.sampleRate).all
        guard flux.count > 8 else { return [] }
        let w = 10
        var prefix = [Float](repeating: 0, count: flux.count + 1)
        for i in flux.indices { prefix[i + 1] = prefix[i] + flux[i] }
        let novelty = flux.indices.map { i -> Float in
            let lo = max(0, i - w), hi = min(flux.count, i + w + 1)
            return max(0, flux[i] - 1.2 * (prefix[hi] - prefix[lo]) / Float(hi - lo))
        }
        let threshold = sensitivity * (novelty.max() ?? 0)
        guard threshold > 0 else { return [] }
        var result: [Int] = []
        for i in novelty.indices where novelty[i] > threshold {
            let lo = max(0, i - 3), hi = min(novelty.count - 1, i + 3)
            if (lo...hi).allSatisfy({ novelty[$0] <= novelty[i] }) && (lo..<i).allSatisfy({ novelty[$0] < novelty[i] }) {
                result.append(i * TempoEstimator.hop)
            }
        }
        return result
    }
}

// MARK: - Phase vocoder

/// Phase-locked vocoder (Laroche & Dolson's identity locking) with a
/// variable analysis hop, so any monotonic time map can be followed.
///
/// Stereo is processed with one set of phase rotations, derived from the
/// mid signal and applied to both channels, which keeps the stereo image
/// intact instead of letting each side drift on its own.
final class PhaseVocoder {
    private let n: Int, hop: Int, bins: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private let window: [Float]

    init(size: Int, overlap: Int = 4) {
        n = size
        hop = size / overlap
        bins = size / 2
        log2n = vDSP_Length(log2(Double(size)))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        var w = [Float](repeating: 0, count: size)
        vDSP_hann_window(&w, vDSP_Length(size), Int32(vDSP_HANN_DENORM))
        window = w
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// - Parameters:
    ///   - count: output frames to produce.
    ///   - source: output frame → source frame.
    ///   - onsets: source frames at which phases are reset to the analysis
    ///     phases, which keeps attacks from smearing.
    func process(_ input: StereoBuffer, count: Int, source: (Double) -> Double, onsets: [Int]) -> StereoBuffer {
        let half = n / 2
        var outL = [Float](repeating: 0, count: count + n + hop)
        var outR = outL
        var fl = [Float](repeating: 0, count: n), fr = fl
        var lRe = [Float](repeating: 0, count: bins), lIm = lRe, rRe = lRe, rIm = lRe
        var refRe = lRe, refIm = lRe, mag = lRe, phase = lRe
        var prevPhase = lRe, prevSynth = lRe, synth = lRe, advanced = lRe
        var rot = lRe, cosR = lRe, sinR = lRe
        var isPeak = [Bool](repeating: false, count: bins)
        var prevA: Int?
        var nextOnset = 0
        var sumW2: Float = 0
        vDSP_svesq(window, 1, &sumW2, vDSP_Length(n))
        let norm = Float(hop) / sumW2 / Float(2 * n)
        let twoPi = Float.pi * 2

        var k = -(half / hop) + 1
        while k * hop - half < count {
            let s = k * hop
            let a = Int(source(Double(s)).rounded())
            let ha = prevA.map { a - $0 } ?? hop

            // Analysis frames, zero outside the source.
            load(input.left, centre: a, into: &fl)
            load(input.right, centre: a, into: &fr)
            forward(&fl, &lRe, &lIm)
            forward(&fr, &rRe, &rIm)

            // Reference spectrum for the phase trajectory: the mid signal,
            // or one side where the two nearly cancel.
            for b in 1..<bins {
                let mr = lRe[b] + rRe[b], mi = lIm[b] + rIm[b]
                let el = lRe[b] * lRe[b] + lIm[b] * lIm[b], er = rRe[b] * rRe[b] + rIm[b] * rIm[b]
                if mr * mr + mi * mi >= 0.01 * (el + er) {
                    refRe[b] = mr; refIm[b] = mi
                } else if el >= er {
                    refRe[b] = lRe[b]; refIm[b] = lIm[b]
                } else {
                    refRe[b] = rRe[b]; refIm[b] = rIm[b]
                }
            }
            var c = Int32(bins)
            vvatan2f(&phase, refIm, refRe, &c)
            vDSP_zvabs_wrapper(refRe, refIm, &mag)

            var reset = prevA == nil || ha <= 0
            while nextOnset < onsets.count && onsets[nextOnset] <= a + ha / 2 {
                if onsets[nextOnset] > a - ha / 2 { reset = true }
                nextOnset += 1
            }

            if reset {
                synth = phase
            } else {
                let fha = Float(ha), fhs = Float(hop)
                for b in 1..<bins {
                    let omega = twoPi * Float(b) / Float(n)
                    var d = phase[b] - prevPhase[b] - omega * fha
                    d -= twoPi * (d / twoPi).rounded()
                    advanced[b] = prevSynth[b] + (omega + d / fha) * fhs
                }
                // Identity phase locking: peaks follow their own frequency,
                // every other bin keeps its phase relation to the nearest peak.
                var peakCount = 0
                for b in 1..<bins {
                    let m = mag[b]
                    let p = m > 0 && m > mag[b - 1] && (b + 1 >= bins || m >= mag[b + 1])
                        && (b < 2 || m > mag[b - 2]) && (b + 2 >= bins || m >= mag[b + 2])
                    isPeak[b] = p
                    if p { peakCount += 1 }
                }
                if peakCount == 0 {
                    synth = advanced
                } else {
                    var prevPeak = -1
                    var b = 1
                    while b < bins {
                        // Next peak at or after b.
                        var next = b
                        while next < bins && !isPeak[next] { next += 1 }
                        let end = next < bins ? next : bins - 1
                        for j in b...end {
                            let useNext = next < bins && (prevPeak < 0 || next - j <= j - prevPeak)
                            let p = useNext ? next : prevPeak
                            synth[j] = advanced[p] + phase[j] - phase[p]
                        }
                        prevPeak = next
                        b = end + 1
                    }
                }
                for b in 1..<bins { synth[b] -= twoPi * (synth[b] / twoPi).rounded() }
            }

            vDSP_vsub(phase, 1, synth, 1, &rot, 1, vDSP_Length(bins))
            rot[0] = 0
            vvsincosf(&sinR, &cosR, rot, &c)
            rotate(&lRe, &lIm, cosR, sinR)
            rotate(&rRe, &rIm, cosR, sinR)
            inverse(&lRe, &lIm, &fl)
            inverse(&rRe, &rIm, &fr)
            vDSP_vmul(fl, 1, window, 1, &fl, 1, vDSP_Length(n))
            vDSP_vmul(fr, 1, window, 1, &fr, 1, vDSP_Length(n))

            // Output index `s - half + j` is stored at `s + j` (a half-frame
            // guard in front of frame 0).
            let lo = max(0, -s), hi = min(n, count + half - s)
            if hi > lo {
                outL.withUnsafeMutableBufferPointer { o in
                    vDSP_vadd(o.baseAddress! + s + lo, 1, fl.withUnsafeBufferPointer { $0.baseAddress! + lo }, 1,
                              o.baseAddress! + s + lo, 1, vDSP_Length(hi - lo))
                }
                outR.withUnsafeMutableBufferPointer { o in
                    vDSP_vadd(o.baseAddress! + s + lo, 1, fr.withUnsafeBufferPointer { $0.baseAddress! + lo }, 1,
                              o.baseAddress! + s + lo, 1, vDSP_Length(hi - lo))
                }
            }
            prevPhase = phase
            prevSynth = synth
            prevA = a
            k += 1
        }
        var scale = norm
        var left = Array(outL[half..<(half + count)]), right = Array(outR[half..<(half + count)])
        vDSP_vsmul(left, 1, &scale, &left, 1, vDSP_Length(count))
        vDSP_vsmul(right, 1, &scale, &right, 1, vDSP_Length(count))
        return StereoBuffer(left: left, right: right)
    }

    private func load(_ x: [Float], centre: Int, into frame: inout [Float]) {
        let start = centre - n / 2
        let lo = max(0, -start), hi = min(n, x.count - start)
        frame.withUnsafeMutableBufferPointer { f in
            f.baseAddress!.update(repeating: 0, count: n)
            guard hi > lo else { return }
            x.withUnsafeBufferPointer { src in
                window.withUnsafeBufferPointer { w in
                    vDSP_vmul(src.baseAddress! + start + lo, 1, w.baseAddress! + lo, 1, f.baseAddress! + lo, 1,
                              vDSP_Length(hi - lo))
                }
            }
        }
    }

    private func forward(_ frame: inout [Float], _ re: inout [Float], _ im: inout [Float]) {
        re.withUnsafeMutableBufferPointer { r in
            im.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                frame.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(bins))
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
            }
        }
    }

    private func inverse(_ re: inout [Float], _ im: inout [Float], _ frame: inout [Float]) {
        re.withUnsafeMutableBufferPointer { r in
            im.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_INVERSE))
                frame.withUnsafeMutableBytes { raw in
                    vDSP_ztoc(&split, 1, raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, vDSP_Length(bins))
                }
            }
        }
    }

    /// Rotates bins 1… by (cos, sin); bin 0 packs DC and Nyquist and stays.
    private func rotate(_ re: inout [Float], _ im: inout [Float], _ c: [Float], _ s: [Float]) {
        for b in 1..<bins {
            let x = re[b], y = im[b]
            re[b] = x * c[b] - y * s[b]
            im[b] = x * s[b] + y * c[b]
        }
    }
}

@inline(__always)
private func vDSP_zvabs_wrapper(_ re: [Float], _ im: [Float], _ out: inout [Float]) {
    re.withUnsafeBufferPointer { r in
        im.withUnsafeBufferPointer { i in
            var split = DSPSplitComplex(realp: UnsafeMutablePointer(mutating: r.baseAddress!),
                                        imagp: UnsafeMutablePointer(mutating: i.baseAddress!))
            vDSP_zvabs(&split, 1, &out, 1, vDSP_Length(re.count))
        }
    }
}

// MARK: - Resampling

/// Windowed-sinc resampler: `out[i] = x(i · step)`, zero-phase, so it adds no
/// delay.
enum Resampler {
    private static let zeroCrossings = 16
    private static let phases = 1024

    static func halfWidth(step: Double) -> Int {
        Int((Double(zeroCrossings) / cutoff(step)).rounded(.up))
    }

    private static func cutoff(_ step: Double) -> Double { 0.97 * min(1, 1 / step) }

    static func resample(_ x: [Float], step: Double, count: Int) -> [Float] {
        let fc = cutoff(step)
        let w = halfWidth(step: step)
        let taps = 2 * w
        // table[p][j]: weight of input index (i0 − w + 1 + j) when the read
        // position is i0 + p/phases.
        var table = [Float](repeating: 0, count: (phases + 1) * taps)
        for p in 0...phases {
            let frac = Double(p) / Double(phases)
            for j in 0..<taps {
                let d = Double(j - w + 1) - frac
                let t = d / Double(w)
                guard abs(t) < 1 else { continue }
                let sinc = d == 0 ? 1 : sin(Double.pi * fc * d) / (Double.pi * fc * d)
                let blackman = 0.42 + 0.5 * cos(Double.pi * t) + 0.08 * cos(2 * Double.pi * t)
                table[p * taps + j] = Float(fc * sinc * blackman)
            }
        }
        var padded = [Float](repeating: 0, count: w)
        padded.append(contentsOf: x)
        padded.append(contentsOf: [Float](repeating: 0, count: w + 2))
        var out = [Float](repeating: 0, count: count)
        padded.withUnsafeBufferPointer { src in
            table.withUnsafeBufferPointer { tab in
                for i in 0..<count {
                    let pos = Double(i) * step
                    let i0 = Int(pos)
                    let p = Int(((pos - Double(i0)) * Double(phases)).rounded())
                    let first = i0 - w + 1 + w // into `padded`
                    guard first >= 0, first + taps <= src.count else { continue }
                    var v: Float = 0
                    vDSP_dotpr(src.baseAddress! + first, 1, tab.baseAddress! + p * taps, 1, &v, vDSP_Length(taps))
                    out[i] = v
                }
            }
        }
        return out
    }
}

// MARK: - Transients

/// Copies each drum hit from the source, unprocessed, onto its mapped
/// position. Hits are played at their original speed; when B is slowed the
/// vocoder's output fills the gap before the next hit, when it's sped up the
/// hit's tail is cut short.
enum TransientCopy {
    static func apply(to out: inout StereoBuffer, source: StereoBuffer, map: TimeMap, onsets: [Int], until end: Int) {
        let sr = AudioIO.sampleRate
        let pre = Int(0.015 * sr)     // start this long before the detected onset
        let fadeIn = Int(0.002 * sr)
        let fadeOut = Int(0.005 * sr)
        let limit = min(end, out.count)
        for (i, x) in onsets.enumerated() {
            let nextX = i + 1 < onsets.count ? onsets[i + 1] : source.count + pre + fadeIn
            let y = Int(map.output(Double(x)).rounded())
            let nextY = i + 1 < onsets.count ? Int(map.output(Double(nextX)).rounded()) : limit + pre + fadeIn
            // Output span [start, stop): stop leaves room for the next
            // hit's lead-in, and never reads past the next source onset.
            let start = y - pre - fadeIn
            let stop = min(y + (nextX - x), nextY) - pre - fadeIn
            guard stop - start > fadeIn + fadeOut + 16 else { continue }
            if start >= limit { break }
            let offset = x - y // source index = output index + offset
            for t in max(0, start)..<max(0, min(stop, limit)) {
                let s = t + offset
                guard s >= 0 && s < source.count else { continue }
                let u = t - start, v = stop - t
                var g: Float = 1
                if u < fadeIn { g = Float(u) / Float(fadeIn) }
                if v < fadeOut { g = min(g, Float(v) / Float(fadeOut)) }
                out.left[t] = out.left[t] * (1 - g) + source.left[s] * g
                out.right[t] = out.right[t] * (1 - g) + source.right[s] * g
            }
        }
    }
}
