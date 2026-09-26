import Accelerate

/// Real-input FFT wrapper around vDSP's split-complex real FFT.
final class RealFFT {
    let size: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private var realp: [Float]
    private var imagp: [Float]

    init(size: Int) {
        precondition(size > 0 && (size & (size - 1)) == 0, "FFT size must be a power of two")
        self.size = size
        self.log2n = vDSP_Length(log2(Double(size)))
        self.setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        self.realp = [Float](repeating: 0, count: size / 2)
        self.imagp = [Float](repeating: 0, count: size / 2)
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }

    /// Magnitude spectrum (size/2 bins) of a windowed real input of length `size`.
    func magnitudes(of input: [Float]) -> [Float] {
        precondition(input.count == size)
        var magnitudes = [Float](repeating: 0, count: size / 2)
        realp.withUnsafeMutableBufferPointer { realPtr in
            imagp.withUnsafeMutableBufferPointer { imagPtr in
                var splitComplex = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                input.withUnsafeBytes { rawPtr in
                    vDSP_ctoz(rawPtr.bindMemory(to: DSPComplex.self).baseAddress!, 2, &splitComplex, 1, vDSP_Length(size / 2))
                }
                vDSP_fft_zrip(setup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&splitComplex, 1, &magnitudes, 1, vDSP_Length(size / 2))
            }
        }
        // vDSP's real FFT returns results scaled by 2.
        var scale: Float = 0.5
        vDSP_vsmul(magnitudes, 1, &scale, &magnitudes, 1, vDSP_Length(size / 2))
        return magnitudes
    }
}
