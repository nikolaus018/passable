import Accelerate
import Foundation

/// Makes the four stems add up to the song again.
///
/// HTDemucs' stems summed miss the file by 23–29 dB in every band (measured
/// on real songs: ~7 % of the 150–500 Hz body), and since a song plays from
/// its stems end to end, that loss was heard everywhere, not only in the
/// blends. Here the part the model lost is handed back, bin by bin of a
/// short-time spectrum, to the stems in proportion to their power there: a
/// stem gets back what sounds where it already sounds, so no stem picks up
/// another's sound, and the four sum to the decoded file to rounding.
///
/// (Exact because the transform is linear and reconstructs perfectly: the
/// stems gain inverse(weights × residual), and the weights sum to one in
/// every bin, so the sum gains inverse(residual) = file − stems.)
enum StemResidual {
    static let size = 4096
    static let hop = 1024

    static func redistribute(mix: StereoBuffer, stems: inout [StemKind: StereoBuffer]) {
        let kinds = StemKind.allCases.filter { stems[$0] != nil }
        guard !kinds.isEmpty else { return }
        let count = min(mix.count, kinds.map { stems[$0]!.count }.min()!)
        for channel in 0..<2 {
            let x = channel == 0 ? mix.left : mix.right
            let parts = kinds.map { channel == 0 ? stems[$0]!.left : stems[$0]!.right }
            let added = residualShares(x, parts, count: count)
            for (k, kind) in kinds.enumerated() {
                var buffer = stems[kind]!
                added[k].withUnsafeBufferPointer { add in
                    if channel == 0 {
                        vDSP_vadd(buffer.left, 1, add.baseAddress!, 1, &buffer.left, 1, vDSP_Length(count))
                    } else {
                        vDSP_vadd(buffer.right, 1, add.baseAddress!, 1, &buffer.right, 1, vDSP_Length(count))
                    }
                }
                stems[kind] = buffer
            }
        }
    }

    /// What each part gets of `x` − Σ`parts`, over the first `count` frames.
    private static func residualShares(_ x: [Float], _ parts: [[Float]], count: Int) -> [[Float]] {
        let n = size, half = n / 2, log2n = vDSP_Length(log2(Double(n)))
        let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        defer { vDSP_destroy_fftsetup(setup) }
        // sqrt-Hann in and out: Hann overlap-added at a quarter hop sums
        // to 2, and the forward and inverse transforms scale by 2n between
        // them.
        let window = (0..<n).map { Float(sin(Double.pi * Double($0) / Double(n))) }
        let scale = 1 / (Float(2 * n) * 2)
        let m = parts.count
        var out = [[Float]](repeating: [Float](repeating: 0, count: count), count: m)
        var frame = [Float](repeating: 0, count: n)
        var re = [[Float]](repeating: [Float](repeating: 0, count: half), count: m + 1)
        var im = re
        var weights = [Float](repeating: 0, count: half)

        func forward(_ signal: [Float], at start: Int, into slot: Int) {
            for i in 0..<n {
                let j = start + i
                frame[i] = j >= 0 && j < count ? signal[j] * window[i] : 0
            }
            re[slot].withUnsafeMutableBufferPointer { r in
                im[slot].withUnsafeMutableBufferPointer { i in
                    var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                    frame.withUnsafeBytes { raw in
                        vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(half))
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                }
            }
        }

        var start = -n
        while start < count {
            forward(x, at: start, into: m)
            for k in 0..<m { forward(parts[k], at: start, into: k) }
            // Residual into slot m.
            for k in 0..<m {
                vDSP_vsub(re[k], 1, re[m], 1, &re[m], 1, vDSP_Length(half))
                vDSP_vsub(im[k], 1, im[m], 1, &im[m], 1, vDSP_Length(half))
            }
            // Power of each part per bin (bin 0 packs DC in re, Nyquist in
            // im: each real, weighed on its own).
            var power = [[Float]](repeating: [Float](repeating: 0, count: half), count: m)
            var nyquist = [Float](repeating: 0, count: m)
            var total = [Float](repeating: 1e-20, count: half)
            var nyquistTotal: Float = 1e-20
            for k in 0..<m {
                for b in 0..<half { power[k][b] = re[k][b] * re[k][b] + im[k][b] * im[k][b] }
                power[k][0] = re[k][0] * re[k][0]
                nyquist[k] = im[k][0] * im[k][0]
                vDSP_vadd(power[k], 1, total, 1, &total, 1, vDSP_Length(half))
                nyquistTotal += nyquist[k]
            }
            for k in 0..<m {
                // Silent everywhere: an equal share.
                for b in 0..<half {
                    weights[b] = total[b] > 1e-18 ? power[k][b] / total[b] : 1 / Float(m)
                }
                let wn = nyquistTotal > 1e-18 ? nyquist[k] / nyquistTotal : 1 / Float(m)
                var r = [Float](repeating: 0, count: half), i = r
                vDSP_vmul(re[m], 1, weights, 1, &r, 1, vDSP_Length(half))
                vDSP_vmul(im[m], 1, weights, 1, &i, 1, vDSP_Length(half))
                i[0] = im[m][0] * wn
                r.withUnsafeMutableBufferPointer { rp in
                    i.withUnsafeMutableBufferPointer { ip in
                        var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_INVERSE))
                        frame.withUnsafeMutableBytes { raw in
                            vDSP_ztoc(&split, 1, raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, vDSP_Length(half))
                        }
                    }
                }
                for s in 0..<n {
                    let j = start + s
                    if j >= 0 && j < count { out[k][j] += frame[s] * window[s] * scale }
                }
            }
            start += hop
        }
        return out
    }
}
