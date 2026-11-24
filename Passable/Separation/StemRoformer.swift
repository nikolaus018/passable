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
    /// One STFT per stem, for turning the stems back into sound at once.
    private var inverses: [RoformerSTFT] = []

    static let name = "StemRoformer"
    /// How far each chunk moves on, as a share of a chunk.
    nonisolated(unsafe) static var stepShare = Double(ProcessInfo.processInfo.environment["PASSABLE_STEM_STEP"] ?? "") ?? 0.5

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
        let size = chunk, step = Int(Double(chunk) * Self.stepShare), fade = chunk / 10
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
        // Every stem's two channels in one block (written from several
        // threads at once, each to its own stretch of it).
        let out = UnsafeMutablePointer<Float>.allocate(capacity: count * 2 * total)
        out.initialize(repeating: 0, count: count * 2 * total)
        defer { out.deallocate() }
        var weight = [Float](repeating: 0, count: total)

        let frames = stft.frames, rows = 2 * RoformerSTFT.bins
        let specArray = try MLMultiArray(shape: [1, NSNumber(value: rows), NSNumber(value: frames), 2], dataType: .float32)
        let spec = specArray.dataPointer.assumingMemoryBound(to: Float.self)
        var part = [[Float]](repeating: [Float](repeating: 0, count: size), count: 2)
        var raw: UnsafeMutablePointer<Float>?
        var rawCount = 0
        defer { raw?.deallocate() }
        // Each stem turned back into sound on a core of its own: one STFT
        // (its own scratch), mask and result per stem.
        if inverses.count != count { inverses = (0..<count).map { _ in RoformerSTFT(chunk: chunk, hop: stft.hop) } }
        let jobs = (0..<count).map { _ in InverseJob(maskCount: rows * frames * 2, size: size) }
        let inverses = self.inverses

        let starts = Array(stride(from: 0, to: total, by: step))
        // (With PASSABLE_TIMING: how much of it the model itself takes.)
        var predicting = 0.0
        let looping = Date()
        defer { TrackProcessor.mark("  stem model: \(starts.count) chunks, \(String(format: "%.1f", predicting)) s in the network", since: looping) }
        for (n, start) in starts.enumerated() {
            if isCancelled() { throw CancellationError() }
            let length = min(size, total - start)
            for c in 0..<2 {
                Self.fill(&part[c], from: source[c], start: start, count: length)
                stft.forward(part[c], channel: c, into: spec)
            }
            let asked = Date()
            let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                "spec": MLFeatureValue(multiArray: specArray),
            ]))
            predicting += Date().timeIntervalSince(asked)
            guard let masks = output.featureValue(for: "masks")?.multiArrayValue,
                  masks.dataType == .float32 || masks.dataType == .float16, masks.shape.count == 5 else {
                throw PassableError.message("The stem model returned no masks.")
            }
            // The masks as floats: half-precision ones converted once per
            // chunk (not once per stem).
            let maskCount = zip(masks.shape, masks.strides).reduce(1) { $0 + ($1.0.intValue - 1) * $1.1.intValue }
            if maskCount != rawCount {
                raw?.deallocate()
                raw = .allocate(capacity: maskCount)
                rawCount = maskCount
            }
            if masks.dataType == .float16 {
                var src = vImage_Buffer(data: masks.dataPointer, height: 1, width: vImagePixelCount(maskCount), rowBytes: maskCount * 2)
                var dst = vImage_Buffer(data: raw!, height: 1, width: vImagePixelCount(maskCount), rowBytes: maskCount * 4)
                vImageConvert_Planar16FtoPlanarF(&src, &dst, 0)
            } else {
                raw!.update(from: masks.dataPointer.assumingMemoryBound(to: Float.self), count: maskCount)
            }
            let values = UnsafePointer(raw!), strides = masks.strides.map(\.intValue)
            var w = window
            if n == 0 { for i in 0..<fade { w[i] = 1 } }
            if start + size >= total { for i in 0..<fade { w[size - 1 - i] = 1 } }
            DispatchQueue.concurrentPerform(iterations: count) { s in
                let job = jobs[s]
                Self.stemMask(values, strides: strides, stem: s, frames: frames, rows: rows, into: job.mask)
                for c in 0..<2 {
                    inverses[s].inverse(spec: spec, mask: job.mask, channel: c, into: job.result)
                    let o = out + (s * 2 + c) * total + start
                    vDSP_vma(job.result, 1, w, 1, o, 1, o, 1, vDSP_Length(length))
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
                let o = out + (s * 2 + c) * total
                weight.withUnsafeBufferPointer { wt in
                    vDSP_vdiv(wt.baseAddress! + from, 1, o + from, 1, &v, 1, vDSP_Length(length))
                }
                if c == 0 { buffer.left = v } else { buffer.right = v }
            }
            return buffer
        }
        var named: [String: StereoBuffer] = [:]
        for name in instruments { named[name] = stem(name) }
        return named
    }

    /// A stem's mask and its sound, for one core.
    private final class InverseJob: @unchecked Sendable {
        let mask: UnsafeMutablePointer<Float>, result: UnsafeMutablePointer<Float>
        let maskCount: Int, size: Int
        init(maskCount: Int, size: Int) {
            self.maskCount = maskCount
            self.size = size
            mask = .allocate(capacity: maskCount)
            mask.initialize(repeating: 0, count: maskCount)
            result = .allocate(capacity: size)
            result.initialize(repeating: 0, count: size)
        }
        deinit { mask.deallocate(); result.deallocate() }
    }

    /// Stem `s` of the network's masks [1, stems, frames, rows, 2] as the
    /// STFT takes them: [row][frame][re, im], the DC bin zeroed.
    private static func stemMask(_ m: UnsafePointer<Float>, strides st: [Int], stem s: Int, frames: Int, rows: Int,
                                 into out: UnsafeMutablePointer<Float>) {
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
