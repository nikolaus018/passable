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
    static func process(_ input: StereoBuffer, map: TimeMap, semitones: Int, percussive: Bool,
                        vocal: Bool = false, harmonicPercussive: Bool = false) -> StereoBuffer {
        let total = max(0, Int(map.output(Double(input.count)).rounded(.down)))
        if map.isIdentity && semitones == 0 { return input }

        let pitch = pow(2, Double(semitones) / 12)
        let fade = 2048
        // Shorter window for vocals (~46 ms vs 93 ms) preserves plosives and
        // consonant clarity while keeping ~21.5 Hz harmonic resolution.
        // 8× overlap on vocals and tonal stems cuts STFT pre-echo and phasiness
        // sharply; drums keep 4× since TransientCopy replaces hits directly.
        let size = (percussive || vocal) ? 2048 : 4096
        let overlap = percussive ? 4 : 8
        let onsets = Onsets.detect(input.mono(), sensitivity: percussive ? 0.06 : vocal ? 0.14 : 0.18)
        let preserveLowPhase = !percussive
        let selectiveOnsetReset = harmonicPercussive && !percussive

        if pitch != 1 {
            // Stretch by rate/pitch, then play the result `pitch` times
            // faster: tempo as mapped, pitch shifted. End to end: there is
            // no untouched stretch of a shifted song.
            let taps = Resampler.halfWidth(step: pitch) + 2
            let zCount = Int((Double(total) * pitch).rounded(.up)) + taps
            let z = PhaseVocoder(size: size, overlap: overlap).process(input, count: zCount, source: { map.source($0 / pitch) },
                                                                       onsets: onsets, preserveLowPhase: preserveLowPhase,
                                                                       selectiveOnsetReset: selectiveOnsetReset,
                                                                       formantRatio: vocal ? pitch : 1)
            return StereoBuffer(left: Resampler.resample(z.left, step: pitch, count: total),
                                right: Resampler.resample(z.right, step: pitch, count: total))
        }

        // The stretch of the output that is the source itself, frame for
        // frame: after the glide home (from the start, without one), until
        // any way out.
        var verbatim: (start: Int, end: Int, offset: Int)?
        if let offset = map.tailOffset, map.hasGlide || map.hasExit {
            let start = map.hasGlide ? min(total, Int(map.rampEnd.rounded(.up))) : 0
            let end = map.hasExit ? min(total, Int(map.exitStart.rounded(.down))) : total
            // (Too short a stretch to fade into and out of isn't worth it.)
            if end - start > 2 * fade { verbatim = (start, end, offset) }
        }
        guard let verbatim else {
            var out = PhaseVocoder(size: size, overlap: overlap).process(input, count: total, source: map.source, onsets: onsets,
                                                                         preserveLowPhase: preserveLowPhase,
                                                                         selectiveOnsetReset: selectiveOnsetReset)
            if percussive { TransientCopy.apply(to: &out, source: input, map: map, onsets: onsets, until: total) }
            return out
        }

        var out = StereoBuffer(left: [Float](repeating: 0, count: total), right: [Float](repeating: 0, count: total))
        if verbatim.start > 0 {
            let count = min(total, verbatim.start + fade + size)
            let head = PhaseVocoder(size: size, overlap: overlap).process(input, count: count, source: map.source, onsets: onsets,
                                                                          preserveLowPhase: preserveLowPhase,
                                                                          selectiveOnsetReset: selectiveOnsetReset)
            out.left.replaceSubrange(0..<count, with: head.left)
            out.right.replaceSubrange(0..<count, with: head.right)
            if percussive {
                TransientCopy.apply(to: &out, source: input, map: map, onsets: onsets, until: verbatim.start)
            }
        }
        // Cross-fade into the source itself.
        for y in verbatim.start..<verbatim.end {
            let x = y + verbatim.offset
            let inside = x >= 0 && x < input.count
            let l = inside ? input.left[x] : 0
            let r = inside ? input.right[x] : 0
            let u = y - verbatim.start
            if verbatim.start > 0, u < fade {
                let g = Float(0.5 - 0.5 * cos(Double.pi * Double(u) / Double(fade)))
                out.left[y] = out.left[y] * (1 - g) + l * g
                out.right[y] = out.right[y] * (1 - g) + r * g
            } else {
                out.left[y] = l
                out.right[y] = r
            }
        }
        if map.hasExit, verbatim.end < total {
            // And out of it again, into the way out: the vocoder starts on
            // the source's own phases, so the two are the same sound there.
            let from = max(verbatim.start, verbatim.end - fade)
            let tail = PhaseVocoder(size: size, overlap: overlap).process(input, count: total - from,
                                                                          source: { map.source($0 + Double(from)) }, onsets: onsets,
                                                                          preserveLowPhase: preserveLowPhase,
                                                                          selectiveOnsetReset: selectiveOnsetReset)
            for y in from..<total {
                let u = y - from
                let g = u < fade ? Float(0.5 - 0.5 * cos(Double.pi * Double(u) / Double(fade))) : 1
                out.left[y] = out.left[y] * (1 - g) + tail.left[u] * g
                out.right[y] = out.right[y] * (1 - g) + tail.right[u] * g
            }
            if percussive {
                TransientCopy.apply(to: &out, source: input, map: map, onsets: onsets, from: verbatim.end, until: total)
            }
        }
        return out
    }

    /// A whole stem played along any monotonic map, not a `TimeMap`: what
    /// a song with its bars made even is played as (see `Steadying`).
    /// - Parameters:
    ///   - count: output frames.
    ///   - source: output frame → source frame.
    ///   - output: its inverse, source frame → output frame (where each
    ///     drum hit is copied to).
    static func warp(_ input: StereoBuffer, count: Int, source: (Double) -> Double,
                     output: (Double) -> Double, percussive: Bool, vocal: Bool = false,
                     harmonicPercussive: Bool = false) -> StereoBuffer {
        let size = (percussive || vocal) ? 2048 : 4096
        let overlap = percussive ? 4 : 8
        let onsets = Onsets.detect(input.mono(), sensitivity: percussive ? 0.06 : vocal ? 0.14 : 0.18)
        var out = PhaseVocoder(size: size, overlap: overlap).process(input, count: count, source: source, onsets: onsets,
                                                                     preserveLowPhase: !percussive,
                                                                     selectiveOnsetReset: harmonicPercussive && !percussive)
        if percussive { TransientCopy.apply(to: &out, source: input, output: output, onsets: onsets, until: count) }
        out.left.removeSubrange(min(count, out.left.count)...)
        out.right.removeSubrange(min(count, out.right.count)...)
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
        let globalMax = novelty.max() ?? 0
        guard globalMax > 0 else { return [] }
        // Local adaptive peak over ±2 s (~200 hops) with a global noise floor:
        // one loud crash or drop no longer blinds onset detection across quiet
        // verses, piano plucks, or ghost hi-hats.
        let globalFloor = 0.08 * sensitivity * globalMax
        let localHalf = 200
        let block = 40
        let blockCount = (novelty.count + block - 1) / block
        var blockMax = [Float](repeating: 0, count: blockCount)
        for b in 0..<blockCount {
            let lo = b * block, hi = min(novelty.count, lo + block)
            var m: Float = 0
            for j in lo..<hi where novelty[j] > m { m = novelty[j] }
            blockMax[b] = m
        }
        var result: [Int] = []
        for i in novelty.indices {
            let bLo = max(0, (i - localHalf) / block)
            let bHi = min(blockCount - 1, (i + localHalf) / block)
            var localPeak: Float = 0
            for b in bLo...bHi where blockMax[b] > localPeak { localPeak = blockMax[b] }
            let threshold = max(globalFloor, sensitivity * localPeak)
            guard novelty[i] > threshold else { continue }
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
    ///   - preserveLowPhase: on onset resets, keep sub-250 Hz fundamentals
    ///     phase-continuous to avoid low-end thumps on tonal/vocal stems.
    ///   - selectiveOnsetReset: on tonal stems with mixed sustained chords and
    ///     plucks (`other`), only reset phases of bins that actually spike on
    ///     the onset (`mag[b] > 1.35 * prevMag[b]`), keeping steady harmonic
    ///     partials phase-locked so chords never glitch during plucks.
    ///   - formantRatio: when resampling by `pitch != 1` for a vocal stem,
    ///     pre-warp the spectral envelope so vocal formants stay in place.
    func process(_ input: StereoBuffer, count: Int, source: (Double) -> Double, onsets: [Int],
                 preserveLowPhase: Bool = false, selectiveOnsetReset: Bool = false,
                 formantRatio: Double = 1) -> StereoBuffer {
        let half = n / 2
        var outL = [Float](repeating: 0, count: count + n + hop)
        var outR = outL
        var fl = [Float](repeating: 0, count: n), fr = fl
        var lRe = [Float](repeating: 0, count: bins), lIm = lRe, rRe = lRe, rIm = lRe
        var refRe = lRe, refIm = lRe, mag = lRe, smoothMag = lRe, phase = lRe, phaseExact = lRe
        var prevPhase = lRe, prevSynth = lRe, synth = lRe, advanced = lRe
        var rot = lRe, cosR = lRe, sinR = lRe
        var isPeak = [Bool](repeating: false, count: bins)
        // Liftered real-cepstrum buffers for pitch-shifted vocal formant preservation.
        var cepRe = [Float](repeating: 0, count: bins)
        var cepIm = [Float](repeating: 0, count: bins)
        var cepTime = [Float](repeating: 0, count: n)
        var lifter = [Float](repeating: 0, count: n)
        let minResetBin = preserveLowPhase ? max(1, Int(250 * Double(n) / AudioIO.sampleRate)) : 1
        let preserveFormants = abs(formantRatio - 1) > 1e-4
        if preserveFormants {
            // Smooth raised-cosine low-quefrency lifter keeping vocal-tract
            // formants (<0.80 ms) while attenuating pitch harmonics (>1.25 ms).
            let qFlat = Int((0.00080 * AudioIO.sampleRate).rounded())
            let qCut = Int((0.00125 * AudioIO.sampleRate).rounded())
            let invNorm = 1.0 / Float(2 * n)
            lifter[0] = invNorm
            let maxQ = min(qCut, n / 2 - 1)
            for q in 1...max(1, maxQ) {
                let w: Float = q <= qFlat ? 1.0
                    : 0.5 * (1.0 + cosf(Float.pi * Float(q - qFlat) / Float(max(1, qCut - qFlat))))
                lifter[q] = w * invNorm
                lifter[n - q] = w * invNorm
            }
        }
        var prevExactA: Double?
        var nextOnset = 0
        var sumW2: Float = 0
        vDSP_svesq(window, 1, &sumW2, vDSP_Length(n))
        let norm = Float(hop) / sumW2 / Float(2 * n)
        let twoPi = Float.pi * 2
        let omegaStep = twoPi / Float(n)

        var k = -(half / hop) + 1
        while k * hop - half < count {
            let s = k * hop
            let exactA = source(Double(s))
            let a = Int(exactA.rounded())
            let frac = Float(exactA - Double(a))
            let fha = prevExactA.map { Float(exactA - $0) } ?? Float(hop)

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

            // Fractional-sample phase shift: move analysis phase from integer
            // center `a` to exact continuous center `exactA = a + frac`,
            // eliminating the ±0.5-sample analysis-hop sawtooth jitter.
            phaseExact[0] = phase[0]
            if abs(frac) > 1e-6 {
                for b in 1..<bins {
                    phaseExact[b] = phase[b] + Float(b) * omegaStep * frac
                }
            } else {
                phaseExact = phase
            }

            let fullReset = prevExactA == nil || fha <= 0
            var onsetReset = false
            let halfHa = Int((fha * 0.5).rounded())
            while nextOnset < onsets.count && onsets[nextOnset] <= a + halfHa {
                if onsets[nextOnset] > a - halfHa { onsetReset = true }
                nextOnset += 1
            }

            if fullReset || (onsetReset && minResetBin <= 1) {
                for b in 1..<bins {
                    synth[b] = phaseExact[b] - twoPi * (phaseExact[b] / twoPi).rounded()
                }
            } else {
                let fhs = Float(hop)
                for b in 1..<bins {
                    let omega = Float(b) * omegaStep
                    var d = phaseExact[b] - prevPhase[b] - omega * fha
                    d -= twoPi * (d / twoPi).rounded()
                    advanced[b] = prevSynth[b] + (omega + d / fha) * fhs
                }
                if onsetReset && !selectiveOnsetReset {
                    // Preserve phase continuity below 250 Hz while locking
                    // transients above 250 Hz to analysis phases.
                    for b in 1..<min(minResetBin, bins) {
                        synth[b] = advanced[b] - twoPi * (advanced[b] / twoPi).rounded()
                    }
                    for b in min(minResetBin, bins)..<bins {
                        synth[b] = phaseExact[b] - twoPi * (phaseExact[b] / twoPi).rounded()
                    }
                } else {
                    // Identity phase locking with spectral-valley influence
                    // regions: peaks follow their own frequency, and bins
                    // between adjacent peaks split at the magnitude minimum
                    // rather than the geometric midpoint.
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
                            var next = b
                            while next < bins && !isPeak[next] { next += 1 }
                            let end = next < bins ? next : bins - 1
                            if prevPeak < 0 {
                                for j in b...end {
                                    synth[j] = advanced[next] + phaseExact[j] - phaseExact[next]
                                }
                            } else if next >= bins {
                                for j in b...end {
                                    synth[j] = advanced[prevPeak] + phaseExact[j] - phaseExact[prevPeak]
                                }
                            } else {
                                var valley = prevPeak
                                var minMag = mag[prevPeak]
                                for m in (prevPeak + 1)...next where mag[m] < minMag {
                                    minMag = mag[m]
                                    valley = m
                                }
                                for j in b...end {
                                    let p = j <= valley ? prevPeak : next
                                    synth[j] = advanced[p] + phaseExact[j] - phaseExact[p]
                                }
                            }
                            prevPeak = next
                            b = end + 1
                        }
                    }
                    if onsetReset && selectiveOnsetReset {
                        // Per-bin STFT harmonic-percussive phase preservation:
                        // bins that jump sharply above their temporal harmonic
                        // baseline (`smoothMag`) and sit on a broadband vertical
                        // ridge lock to exact analysis phase for crisp plucks/
                        // attacks, while steady harmonic partials stay phase-locked.
                        for b in min(minResetBin, bins)..<bins {
                            let h = smoothMag[b]
                            guard mag[b] > 1.65 * h else { continue }
                            let lo = max(1, b - 2), hi = min(bins - 1, b + 2)
                            var pSum: Float = 0
                            for fb in lo...hi { pSum += mag[fb] }
                            let pMean = pSum / Float(hi - lo + 1)
                            if mag[b] > 0.5 * pMean {
                                synth[b] = phaseExact[b]
                            }
                        }
                    }
                    for b in 1..<bins { synth[b] -= twoPi * (synth[b] / twoPi).rounded() }
                }
            }

            if preserveFormants {
                // Real liftered cepstrum: extract the smooth vocal-tract log
                // envelope without harmonic ripples, then warp formants back
                // to their unshifted frequencies.
                cepRe[0] = logf(max(mag[1], 1e-6))
                cepIm[0] = logf(max(mag[bins - 1], 1e-6))
                for b in 1..<bins {
                    cepRe[b] = logf(max(mag[b], 1e-6))
                    cepIm[b] = 0
                }
                inverse(&cepRe, &cepIm, &cepTime)
                vDSP_vmul(cepTime, 1, lifter, 1, &cepTime, 1, vDSP_Length(n))
                forward(&cepTime, &cepRe, &cepIm)
                for b in 1..<bins {
                    let target = Double(b) * formantRatio
                    let t0 = min(bins - 1, max(1, Int(target)))
                    let t1 = min(bins - 1, t0 + 1)
                    let f = Float(target - Double(t0))
                    let targetEnv = cepRe[t0] + f * (cepRe[t1] - cepRe[t0])
                    let g = min(4.0, max(0.25, expf(targetEnv - cepRe[b])))
                    lRe[b] *= g; lIm[b] *= g
                    rRe[b] *= g; rIm[b] *= g
                }
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
            if prevExactA == nil {
                smoothMag = mag
            } else {
                for b in 1..<bins { smoothMag[b] = 0.75 * smoothMag[b] + 0.25 * mag[b] }
            }
            prevPhase = phaseExact
            prevSynth = synth
            prevExactA = exactA
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
    /// - Parameters from, end: the output frames to work in (hits that
    ///   land before `from` are left as they are).
    static func apply(to out: inout StereoBuffer, source: StereoBuffer, map: TimeMap, onsets: [Int], from: Int = 0,
                      until end: Int) {
        apply(to: &out, source: source, output: map.output, onsets: onsets, from: from, until: end)
    }

    /// The same along any map: `output` takes a source frame to the output
    /// frame it's heard at.
    static func apply(to out: inout StereoBuffer, source: StereoBuffer, output: (Double) -> Double, onsets: [Int],
                      from: Int = 0, until end: Int) {
        let sr = AudioIO.sampleRate
        let pre = Int(0.015 * sr)     // start this long before the detected onset
        let fadeIn = Int(0.002 * sr)
        let fadeOut = Int(0.005 * sr)
        let limit = min(end, out.count)
        for (i, x) in onsets.enumerated() {
            let nextX = i + 1 < onsets.count ? onsets[i + 1] : source.count + pre + fadeIn
            let y = Int(output(Double(x)).rounded())
            let nextY = i + 1 < onsets.count ? Int(output(Double(nextX)).rounded()) : limit + pre + fadeIn
            // Output span [start, stop): stop leaves room for the next
            // hit's lead-in, and never reads past the next source onset.
            let start = y - pre - fadeIn
            if start < from { continue }
            let stop = min(y + (nextX - x), nextY) - pre - fadeIn
            guard stop - start > fadeIn + fadeOut + 16 else { continue }
            if start >= limit { break }
            let offset = x - y // source index = output index + offset
            for t in max(0, start)..<max(0, min(stop, limit)) {
                let s = t + offset
                guard s >= 0 && s < source.count else { continue }
                let u = t - start, v = stop - t
                var g: Float = 1
                if u < fadeIn {
                    g = 0.5 * (1 - cosf(Float.pi * Float(u) / Float(fadeIn)))
                }
                if v < fadeOut {
                    g = min(g, 0.5 * (1 - cosf(Float.pi * Float(v) / Float(fadeOut))))
                }
                out.left[t] = out.left[t] * (1 - g) + source.left[s] * g
                out.right[t] = out.right[t] * (1 - g) + source.right[s] * g
            }
        }
    }
}
