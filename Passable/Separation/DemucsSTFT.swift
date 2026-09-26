import Accelerate

/// Bit-for-bit port (to float rounding) of `HTDemucs._spec` / `_ispec`.
///
/// The Core ML export leaves the STFT out because Core ML has no complex
/// tensors, so this has to match torch exactly or the frequency branch sees
/// spectrograms it was never trained on. The torch path is:
///
///     reflect-pad by 3·hop/2 (+ tail to a whole number of hops)
///     torch.stft(n_fft 4096, hop 1024, periodic Hann, normalized, center)
///     drop the Nyquist bin and the two edge frames on each side
///
/// Working that through, output frame `j` is simply the windowed DFT of
/// `x[j·hop − 1536 ..< j·hop + 2560]`, with out-of-range indices reflected
/// about the ends of the (zero-padded) segment and a 1/√n_fft scale. The
/// inverse is overlap-add of the same frames; with a periodic Hann at 75 %
/// overlap the squared-window sum is a constant 1.5 over every sample kept.
final class DemucsSTFT {
    static let nfft = 4096
    static let hop = 1024
    static let bins = nfft / 2
    private static let log2n = vDSP_Length(12)
    private static let leftReach = hop / 2 * 3 // 1536

    let segment: Int
    let frames: Int
    private let setup: FFTSetup
    private var window = [Float](repeating: 0, count: nfft)
    private var frame = [Float](repeating: 0, count: nfft)
    private var realp = [Float](repeating: 0, count: bins)
    private var imagp = [Float](repeating: 0, count: bins)

    init(segment: Int) {
        self.segment = segment
        frames = (segment + Self.hop - 1) / Self.hop
        setup = vDSP_create_fftsetup(Self.log2n, FFTRadix(kFFTRadix2))!
        for n in 0..<Self.nfft {
            // torch.hann_window is periodic by default.
            window[n] = Float(0.5 - 0.5 * cos(2 * Double.pi * Double(n) / Double(Self.nfft)))
        }
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// Forward transform of one channel. `signal` must hold exactly
    /// `segment` samples (zero-pad a short final chunk first, as HTDemucs does).
    /// Writes real/imag planes laid out `[bin][frame]`.
    func forward(signal: UnsafePointer<Float>, re: UnsafeMutablePointer<Float>, im: UnsafeMutablePointer<Float>) {
        let n = Self.nfft, bins = Self.bins, length = segment
        let scale: Float = 0.5 / Float(n).squareRoot() // vDSP's forward is 2× the DFT
        for j in 0..<frames {
            let start = j * Self.hop - Self.leftReach
            if start >= 0 && start + n <= length {
                vDSP_vmul(signal + start, 1, window, 1, &frame, 1, vDSP_Length(n))
            } else {
                for k in 0..<n {
                    var i = start + k
                    if i < 0 { i = -i }
                    if i >= length { i = 2 * (length - 1) - i }
                    frame[k] = signal[i] * window[k]
                }
            }
            realp.withUnsafeMutableBufferPointer { rp in
                imagp.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    frame.withUnsafeBytes {
                        vDSP_ctoz($0.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(bins))
                    }
                    vDSP_fft_zrip(setup, &split, 1, Self.log2n, FFTDirection(FFT_FORWARD))
                }
            }
            // Packed format: imagp[0] holds the Nyquist bin, which HTDemucs drops.
            re[j] = realp[0] * scale
            im[j] = 0
            for f in 1..<bins {
                re[f * frames + j] = realp[f] * scale
                im[f * frames + j] = imagp[f] * scale
            }
        }
    }

    /// Inverse transform of one channel, accumulated (`+=`) into `output`,
    /// which receives `min(count, segment)` samples. Spectrogram planes are
    /// addressed as `re[f * binStride + j * frameStride]`.
    func inverse(re: UnsafePointer<Float>, im: UnsafePointer<Float>, binStride: Int, frameStride: Int,
                 output: UnsafeMutablePointer<Float>, count: Int) {
        let n = Self.nfft, bins = Self.bins
        // vDSP's inverse real FFT returns N × the true inverse; torch's
        // normalized istft wants √N × it, then ÷1.5 for the window-sum.
        let scale: Float = 1 / (Float(n).squareRoot() * 1.5)
        let count = min(count, segment)
        for j in 0..<frames {
            realp[0] = re[j * frameStride]
            imagp[0] = 0 // Nyquist, re-padded with zero by _ispec
            for f in 1..<bins {
                realp[f] = re[f * binStride + j * frameStride]
                imagp[f] = im[f * binStride + j * frameStride]
            }
            realp.withUnsafeMutableBufferPointer { rp in
                imagp.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    vDSP_fft_zrip(setup, &split, 1, Self.log2n, FFTDirection(FFT_INVERSE))
                    frame.withUnsafeMutableBytes {
                        vDSP_ztoc(&split, 1, $0.bindMemory(to: DSPComplex.self).baseAddress!, 2, vDSP_Length(bins))
                    }
                }
            }
            vDSP_vmul(frame, 1, window, 1, &frame, 1, vDSP_Length(n))
            let start = j * Self.hop - Self.leftReach
            let lo = max(0, -start), hi = min(n, count - start)
            guard hi > lo else { continue }
            var s = scale
            frame.withUnsafeBufferPointer { f in
                vDSP_vsma(f.baseAddress! + lo, 1, &s, output + start + lo, 1, output + start + lo, 1, vDSP_Length(hi - lo))
            }
        }
    }
}
