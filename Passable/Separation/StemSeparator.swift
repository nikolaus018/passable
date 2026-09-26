import CoreML
import Accelerate

enum StemKind: String, CaseIterable, Codable, Identifiable {
    // Model output order.
    case drums, bass, other, vocals

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .drums: return "Drums"
        case .bass: return "Bass"
        case .other: return "Melody"
        case .vocals: return "Vocals"
        }
    }

    /// Timeline order: vocals on top, bass at the bottom.
    static let laneOrder: [StemKind] = [.vocals, .other, .drums, .bass]
}

/// Splits a stereo mix into four stems with HTDemucs running under Core ML.
///
/// Mirrors `demucs.apply.apply_model(split=True, overlap=0.25, shifts=1)`:
/// the track is normalised, cut into 7.8 s training-length segments with 25 %
/// overlap, and the per-segment outputs are cross-faded with triangular
/// weights so segment seams don't click.
final class StemSeparator {
    private let model: MLModel
    private let segment: Int
    private let stft: DemucsSTFT
    private static let overlap = 0.25

    init() throws {
        guard let url = Bundle.main.url(forResource: "HTDemucs", withExtension: "mlmodelc") else {
            throw PassableError.message("HTDemucs model is missing from the app bundle. Run tools/convert-demucs/convert.py and rebuild.")
        }
        let config = MLModelConfiguration()
        // The FP32 graph is GPU-resident; FP16 (the Neural Engine's type)
        // overflows in HTDemucs' normalisation and attention layers.
        config.computeUnits = .cpuAndGPU
        model = try MLModel(contentsOf: url, configuration: config)
        let metadata = model.modelDescription.metadata[.creatorDefinedKey] as? [String: String] ?? [:]
        segment = Int(metadata["segment"] ?? "") ?? 343_980
        stft = DemucsSTFT(segment: segment)
    }

    func separate(_ mix: StereoBuffer,
                  progress: (Double) -> Void,
                  isCancelled: () -> Bool = { false }) throws -> [StemKind: StereoBuffer] {
        let length = mix.count
        let frames = stft.frames, bins = DemucsSTFT.bins

        // demucs.separate normalises by the mono reference before the model.
        let mono = mix.mono()
        var mean: Float = 0, std: Float = 0
        vDSP_normalize(mono, 1, nil, 1, &mean, &std, vDSP_Length(length))
        std = max(std, 1e-8)

        let mixArray = try MLMultiArray(shape: [1, 2, NSNumber(value: segment)], dataType: .float32)
        let specArray = try MLMultiArray(shape: [1, 4, NSNumber(value: bins), NSNumber(value: frames)], dataType: .float32)
        let mixPtr = mixArray.dataPointer.assumingMemoryBound(to: Float.self)
        let specPtr = specArray.dataPointer.assumingMemoryBound(to: Float.self)
        let plane = bins * frames

        var outputs = StemKind.allCases.map { _ in StereoBuffer(count: length) }
        var weightSum = [Float](repeating: 0, count: length)
        let weight = Self.transitionWeights(segment)
        let stride = Int((1 - Self.overlap) * Double(segment))
        var scratch = [Float](repeating: 0, count: segment)

        let offsets = Array(Swift.stride(from: 0, to: length, by: stride))
        for (chunkIndex, offset) in offsets.enumerated() {
            if isCancelled() { throw CancellationError() }
            let chunk = min(segment, length - offset)
            // Like demucs' TensorChunk.padded: a short final chunk is centred
            // in a full segment filled with the real audio around it (zeros
            // only past the ends of the track), and the output trimmed back.
            let lead = (segment - chunk) / 2
            let windowStart = offset - lead

            // Normalised segment → model inputs.
            for (c, channel) in [mix.left, mix.right].enumerated() {
                let dst = mixPtr + c * segment
                dst.initialize(repeating: 0, count: segment)
                let lo = max(0, -windowStart), hi = min(segment, length - windowStart)
                if hi > lo {
                    channel.withUnsafeBufferPointer { src in
                        var negMean = -mean, invStd = 1 / std
                        vDSP_vsadd(src.baseAddress! + windowStart + lo, 1, &negMean, dst + lo, 1, vDSP_Length(hi - lo))
                        vDSP_vsmul(dst + lo, 1, &invStd, dst + lo, 1, vDSP_Length(hi - lo))
                    }
                }
                stft.forward(signal: dst, re: specPtr + (2 * c) * plane, im: specPtr + (2 * c + 1) * plane)
            }

            let result = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                "mix": MLFeatureValue(multiArray: mixArray),
                "spec": MLFeatureValue(multiArray: specArray),
            ]))
            guard let wave = result.featureValue(for: "wave")?.multiArrayValue,
                  let spec = result.featureValue(for: "spec_out")?.multiArrayValue
            else { throw PassableError.message("HTDemucs returned no output.") }

            let ws = wave.strides.map(\.intValue), ss = spec.strides.map(\.intValue)
            try Self.withFloats(wave) { wavePtr in
                try Self.withFloats(spec) { specOut in
                    for s in 0..<StemKind.allCases.count {
                        for c in 0..<2 {
                            // time branch
                            let w = wavePtr + s * ws[1] + c * ws[2]
                            for i in 0..<segment { scratch[i] = w[i * ws[3]] }
                            // + frequency branch
                            let reChannel = s * 4 + c * 2
                            scratch.withUnsafeMutableBufferPointer { out in
                                stft.inverse(re: specOut + reChannel * ss[1], im: specOut + (reChannel + 1) * ss[1],
                                             binStride: ss[2], frameStride: ss[3],
                                             output: out.baseAddress!, count: segment)
                            }
                            // weighted overlap-add into the full-length stem
                            let dst = c == 0 ? \StereoBuffer.left : \StereoBuffer.right
                            outputs[s][keyPath: dst].withUnsafeMutableBufferPointer { o in
                                scratch.withUnsafeBufferPointer { sc in
                                    weight.withUnsafeBufferPointer { wt in
                                        vDSP_vma(sc.baseAddress! + lead, 1, wt.baseAddress!, 1, o.baseAddress! + offset, 1,
                                                 o.baseAddress! + offset, 1, vDSP_Length(chunk))
                                    }
                                }
                            }
                        }
                    }
                }
            }
            weightSum.withUnsafeMutableBufferPointer { ws in
                weight.withUnsafeBufferPointer { wt in
                    vDSP_vadd(ws.baseAddress! + offset, 1, wt.baseAddress!, 1, ws.baseAddress! + offset, 1, vDSP_Length(chunk))
                }
            }
            progress(Double(chunkIndex + 1) / Double(offsets.count))
        }

        // Undo the weighting and the normalisation.
        var result: [StemKind: StereoBuffer] = [:]
        for (s, kind) in StemKind.allCases.enumerated() {
            for keyPath in [\StereoBuffer.left, \StereoBuffer.right] {
                outputs[s][keyPath: keyPath].withUnsafeMutableBufferPointer { o in
                    vDSP_vdiv(weightSum, 1, o.baseAddress!, 1, o.baseAddress!, 1, vDSP_Length(length))
                    var m = mean, sd = std
                    vDSP_vsmsa(o.baseAddress!, 1, &sd, &m, o.baseAddress!, 1, vDSP_Length(length))
                }
            }
            result[kind] = outputs[s]
        }
        return result
    }

    /// Triangle peaking mid-segment, as in apply_model (transition_power 1).
    private static func transitionWeights(_ segment: Int) -> [Float] {
        let half = segment / 2
        var w = [Float](repeating: 0, count: segment)
        for i in 0..<half { w[i] = Float(i + 1) }
        for i in half..<segment { w[i] = Float(segment - i) }
        let peak = w.max() ?? 1
        return w.map { $0 / peak }
    }

    private static func withFloats<R>(_ array: MLMultiArray, _ body: (UnsafePointer<Float>) throws -> R) throws -> R {
        guard array.dataType == .float32 else {
            throw PassableError.message("Unexpected HTDemucs output type \(array.dataType.rawValue).")
        }
        return try array.withUnsafeBufferPointer(ofType: Float.self) { try body($0.baseAddress!) }
    }
}
