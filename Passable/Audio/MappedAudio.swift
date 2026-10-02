import Accelerate
import Foundation

/// A raw little-endian Float32 file mapped read-only into memory.
///
/// Eight stereo stems of two four-minute tracks are close to a gigabyte of
/// floats. Mapping them lets the kernel page in only what the playhead and
/// the waveform are actually touching, and lets the audio thread read samples
/// without ever copying or allocating.
final class MappedChannel: @unchecked Sendable {
    let pointer: UnsafePointer<Float>
    let count: Int
    private let mapping: UnsafeMutableRawPointer?
    private let byteCount: Int
    private var owned: UnsafeMutablePointer<Float>? = nil
    private static let empty = UnsafeMutablePointer<Float>.allocate(capacity: 1)

    init(url: URL) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw PassableError.message("Can't open \(url.lastPathComponent).") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw PassableError.message("Can't stat \(url.lastPathComponent).") }
        byteCount = Int(info.st_size)
        count = byteCount / MemoryLayout<Float>.size
        guard count > 0 else {
            mapping = nil
            pointer = UnsafePointer(Self.empty)
            return
        }
        guard let base = mmap(nil, byteCount, PROT_READ, MAP_PRIVATE, fd, 0), base != MAP_FAILED else {
            throw PassableError.message("Can't map \(url.lastPathComponent).")
        }
        mapping = base
        pointer = UnsafePointer(base.assumingMemoryBound(to: Float.self))
    }

    /// Samples held in memory rather than in a file: a stretch of a stem
    /// as it plays (looped, say), for whatever measures stems.
    init(samples: [Float]) {
        count = samples.count
        byteCount = 0
        mapping = nil
        guard count > 0 else {
            owned = nil
            pointer = UnsafePointer(Self.empty)
            return
        }
        let memory = UnsafeMutablePointer<Float>.allocate(capacity: count)
        memory.initialize(from: samples, count: count)
        owned = memory
        pointer = UnsafePointer(memory)
    }

    deinit {
        if let mapping { munmap(mapping, byteCount) }
        owned?.deallocate()
    }

    static func write(_ samples: [Float], to url: URL) throws {
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        try data.write(to: url, options: .atomic)
    }
}

/// One stereo stem backed by two mapped channel files.
struct StemAudio: @unchecked Sendable {
    let left: MappedChannel
    let right: MappedChannel

    var count: Int { min(left.count, right.count) }

    static func load(directory: URL, name: String) throws -> StemAudio {
        StemAudio(left: try MappedChannel(url: directory.appendingPathComponent("\(name).L.f32")),
                  right: try MappedChannel(url: directory.appendingPathComponent("\(name).R.f32")))
    }

    static func exists(directory: URL, name: String) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: directory.appendingPathComponent("\(name).L.f32").path)
            && fm.fileExists(atPath: directory.appendingPathComponent("\(name).R.f32").path)
    }

    static func save(_ buffer: StereoBuffer, directory: URL, name: String) throws {
        try MappedChannel.write(buffer.left, to: directory.appendingPathComponent("\(name).L.f32"))
        try MappedChannel.write(buffer.right, to: directory.appendingPathComponent("\(name).R.f32"))
    }

    /// Absolute-peak overview, one value per `hop` frames, for waveform drawing.
    func peaks(hop: Int) -> [Float] {
        let n = count
        guard n > 0 else { return [] }
        var out = [Float](repeating: 0, count: (n + hop - 1) / hop)
        for i in 0..<out.count {
            let start = i * hop
            let len = min(hop, n - start)
            var l: Float = 0, r: Float = 0
            vDSPMaxMagnitude(left.pointer + start, len, &l)
            vDSPMaxMagnitude(right.pointer + start, len, &r)
            out[i] = max(l, r)
        }
        return out
    }

    func copyStereo() -> StereoBuffer {
        StereoBuffer(left: Array(UnsafeBufferPointer(start: left.pointer, count: count)),
                     right: Array(UnsafeBufferPointer(start: right.pointer, count: count)))
    }
}

@inline(__always)
private func vDSPMaxMagnitude(_ p: UnsafePointer<Float>, _ n: Int, _ out: inout Float) {
    vDSP_maxmgv(p, 1, &out, vDSP_Length(n))
}
