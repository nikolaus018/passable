import Accelerate
import CoreML
import Foundation

/// Drums, bass and melody from BS-RoFormer SW (six stems) under Core ML.
///
/// On the MUSDB18 test excerpts this model is closer to the true drums, bass
/// and melody than HTDemucs v4 (tools/convert-roformer/evaluate_stems.py):
/// less of the kick in the melody and less of the melody in the bass, which
/// is what every swap and filter of a part in a blend is heard through. It
/// separates vocals, drums, bass, guitar, piano and other; Passable's
/// melody is other, guitar and piano together.
///
/// Mirrors upstream's `demix` (ZFTurbo's Music-Source-Separation-Training):
/// chunks of the model's own length, half overlapping, faded in and out
/// over a tenth of a chunk, the track reflected past both ends. Every
/// frequency bin is in one band (band-split, not mel), so the network's
/// complex masks apply as they are; the DC bin is zeroed, as the model
/// does.
final class StemRoformer {
    private let model: MLModel
    /// The model's stems, in the order of its masks.
    let instruments: [String]
    private let stft: RoformerSTFT
    let chunk: Int
    private var halves: [Float] = []

    static let name = "StemRoformer"

    init(name: String = StemRoformer.name, model modelURL: URL? = nil) throws {
        guard let url = modelURL ?? Bundle.main.url(forResource: name, withExtension: "mlmodelc")
                ?? ModelLocation.fallback(named: name) else {
            throw PassableError.message("The model \(name) is missing. Run tools/convert-roformer/convert_stems.py and rebuild.")
        }
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndGPU
        model = try MLModel(contentsOf: url, configuration: config)
        let metadata = model.modelDescription.metadata[.creatorDefinedKey] as? [String: String] ?? [:]
        instruments = (metadata["instruments"] ?? "").split(separator: ",").map(String.init)
        chunk = Int(metadata["chunk"] ?? "") ?? 588_800
        let hop = Int(metadata["hop"] ?? "") ?? 512
        guard !instruments.isEmpty, chunk > hop, hop > 0 else {
            throw PassableError.message("The model \(name) has no stem layout.")
        }
        stft = RoformerSTFT(chunk: chunk, hop: hop)
    }

    /// Whether the app has the model (without it, HTDemucs separates).
    static var isAvailable: Bool { isAvailable(name) }

    static func isAvailable(_ name: String) -> Bool {
        Bundle.main.url(forResource: name, withExtension: "mlmodelc") != nil || ModelLocation.fallback(named: name) != nil
    }

    /// Drums, bass and melody of `mix` (and its voice, which Passable takes
    /// from the vocal model where it has one).
    func separate(_ mix: StereoBuffer, progress: (Double) -> Void,
                  isCancelled: () -> Bool = { false }) throws -> [StemKind: StereoBuffer] {
        guard ["drums", "bass", "other"].allSatisfy(instruments.contains) else {
            throw PassableError.message("The stem model has no drums, bass and other.")
        }
        let named = try separateNamed(mix, progress: progress, isCancelled: isCancelled)
        let length = mix.count
        var melody = named["other"]!
        for extra in ["guitar", "piano"] {
            guard let part = named[extra] else { continue }
            vDSP_vadd(melody.left, 1, part.left, 1, &melody.left, 1, vDSP_Length(length))
            vDSP_vadd(melody.right, 1, part.right, 1, &melody.right, 1, vDSP_Length(length))
        }
        var stems: [StemKind: StereoBuffer] = [.drums: named["drums"]!, .bass: named["bass"]!, .other: melody]
        stems[.vocals] = named["vocals"]
        return stems
    }

    /// Every stem the model separates, by its name in the model.
    func separateNamed(_ mix: StereoBuffer, progress: (Double) -> Void,
                       isCancelled: () -> Bool = { false }) throws -> [String: StereoBuffer] {
        let size = chunk, step = chunk / 2, fade = chunk / 10
        let length = mix.count
        let border = size - step
        let padded = length > 2 * border
        let source = padded ? [mix.left, mix.right].map { VocalSeparator.reflect($0, by: border) } : [mix.left, mix.right]
        let total = source[0].count

        var window = [Float](repeating: 1, count: size)
        for i in 0..<fade {
            window[i] = Float(i) / Float(fade - 1)
            window[size - 1 - i] = Float(i) / Float(fade - 1)
        }
        let count = instruments.count
        var out = [[[Float]]](repeating: [[Float]](repeating: [Float](repeating: 0, count: total), count: 2), count: count)
        var weight = [Float](repeating: 0, count: total)

        let frames = stft.frames, rows = 2 * RoformerSTFT.bins
        let specArray = try MLMultiArray(shape: [1, NSNumber(value: rows), NSNumber(value: frames), 2], dataType: .float32)
        let spec = specArray.dataPointer.assumingMemoryBound(to: Float.self)
        var part = [[Float]](repeating: [Float](repeating: 0, count: size), count: 2)
        var mask = [Float](repeating: 0, count: rows * frames * 2)
        var result = [Float](repeating: 0, count: size)

        let starts = Array(stride(from: 0, to: total, by: step))
        for (n, start) in starts.enumerated() {
            if isCancelled() { throw CancellationError() }
            let length = min(size, total - start)
            for c in 0..<2 {
                Self.fill(&part[c], from: source[c], start: start, count: length)
                stft.forward(part[c], channel: c, into: spec)
            }
            let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                "spec": MLFeatureValue(multiArray: specArray),
            ]))
            guard let masks = output.featureValue(for: "masks")?.multiArrayValue,
                  masks.dataType == .float32 || masks.dataType == .float16, masks.shape.count == 5 else {
                throw PassableError.message("The stem model returned no masks.")
            }
            var w = window
            if n == 0 { for i in 0..<fade { w[i] = 1 } }
            if start + size >= total { for i in 0..<fade { w[size - 1 - i] = 1 } }
            for s in 0..<count {
                stemMask(masks, stem: s, frames: frames, rows: rows, into: &mask)
                for c in 0..<2 {
                    stft.inverse(spec: spec, mask: mask, channel: c, into: &result)
                    out[s][c].withUnsafeMutableBufferPointer { o in
                        vDSP_vma(result, 1, w, 1, o.baseAddress! + start, 1, o.baseAddress! + start, 1, vDSP_Length(length))
                    }
                }
            }
            weight.withUnsafeMutableBufferPointer { o in
                vDSP_vadd(o.baseAddress! + start, 1, w, 1, o.baseAddress! + start, 1, vDSP_Length(length))
            }
            progress(Double(n + 1) / Double(starts.count))
        }
        let from = padded ? border : 0
        func stem(_ name: String) -> StereoBuffer? {
            guard let s = instruments.firstIndex(of: name) else { return nil }
            var buffer = StereoBuffer(count: length)
            for c in 0..<2 {
                var v = [Float](repeating: 0, count: length)
                out[s][c].withUnsafeBufferPointer { o in
                    weight.withUnsafeBufferPointer { wt in
                        vDSP_vdiv(wt.baseAddress! + from, 1, o.baseAddress! + from, 1, &v, 1, vDSP_Length(length))
                    }
                }
                if c == 0 { buffer.left = v } else { buffer.right = v }
            }
            return buffer
        }
        var named: [String: StereoBuffer] = [:]
        for name in instruments { named[name] = stem(name) }
        return named
    }

    /// Stem `s` of the network's masks [1, stems, frames, rows, 2] as the
    /// STFT takes them: [row][frame][re, im], the DC bin zeroed.
    private func stemMask(_ masks: MLMultiArray, stem s: Int, frames: Int, rows: Int, into mask: inout [Float]) {
        let st = masks.strides.map(\.intValue)
        func copy(_ m: UnsafeBufferPointer<Float>) {
            mask.withUnsafeMutableBufferPointer { out in
                for row in 0..<rows {
                    let base = row * frames * 2
                    if row < 2 {
                        for t in 0..<(2 * frames) { out[base + t] = 0 }
                        continue
                    }
                    var at = s * st[1] + row * st[3]
                    for t in 0..<frames {
                        out[base + 2 * t] = m[at]
                        out[base + 2 * t + 1] = m[at + st[4]]
                        at += st[2]
                    }
                }
            }
        }
        if masks.dataType == .float16 {
            let count = zip(masks.shape, masks.strides).reduce(1) { $0 + ($1.0.intValue - 1) * $1.1.intValue }
            if halves.count != count { halves = [Float](repeating: 0, count: count) }
            halves.withUnsafeMutableBufferPointer { f in
                var src = vImage_Buffer(data: masks.dataPointer, height: 1, width: vImagePixelCount(count), rowBytes: count * 2)
                var dst = vImage_Buffer(data: f.baseAddress!, height: 1, width: vImagePixelCount(count), rowBytes: count * 4)
                vImageConvert_Planar16FtoPlanarF(&src, &dst, 0)
            }
            halves.withUnsafeBufferPointer { copy($0) }
        } else {
            masks.withUnsafeBufferPointer(ofType: Float.self) { copy($0) }
        }
    }

    /// A chunk of `source` from `start`: a short last one reflected out to
    /// a full chunk if it's more than half of one, zeros otherwise.
    private static func fill(_ part: inout [Float], from source: [Float], start: Int, count: Int) {
        let size = part.count
        for i in 0..<count { part[i] = source[start + i] }
        guard count < size else { return }
        if count > size / 2 + 1 {
            for i in count..<size { part[i] = source[start + 2 * (count - 1) - i] }
        } else {
            for i in count..<size { part[i] = 0 }
        }
    }
}
