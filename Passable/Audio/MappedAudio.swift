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

    /// - Parameters:
    ///   - origin: the frame of the file the channel starts at.
    ///   - frames: how many frames it has (the rest of the file, if nil).
    init(url: URL, origin: Int = 0, frames: Int? = nil) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw PassableError.message("Can't open \(url.lastPathComponent).") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw PassableError.message("Can't stat \(url.lastPathComponent).") }
        byteCount = Int(info.st_size)
        let inFile = byteCount / MemoryLayout<Float>.size
        guard origin >= 0, origin + (frames ?? 0) <= inFile else {
            throw PassableError.message("\(url.lastPathComponent) is shorter than its layout says.")
        }
        count = frames ?? max(0, inFile - origin)
        guard count > 0 else {
            mapping = nil
            pointer = UnsafePointer(Self.empty)
            return
        }
        guard let base = mmap(nil, byteCount, PROT_READ, MAP_PRIVATE, fd, 0), base != MAP_FAILED else {
            throw PassableError.message("Can't map \(url.lastPathComponent).")
        }
        mapping = base
        pointer = UnsafePointer(base.assumingMemoryBound(to: Float.self) + origin)
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

    /// A channel that starts `lead` frames before `url`'s first: those
    /// frames are the last ones of `head` (a file of whole pages), mapped
    /// straight before it, so the two read as one run of memory.
    init(head: URL, url: URL, lead: Int, frames: Int) throws {
        let page = Int(getpagesize()), size = MemoryLayout<Float>.size
        func open(_ u: URL) throws -> (fd: Int32, bytes: Int) {
            let fd = Darwin.open(u.path, O_RDONLY)
            guard fd >= 0 else { throw PassableError.message("Can't open \(u.lastPathComponent).") }
            var info = stat()
            guard fstat(fd, &info) == 0 else { close(fd); throw PassableError.message("Can't stat \(u.lastPathComponent).") }
            return (fd, Int(info.st_size))
        }
        let h = try open(head)
        defer { close(h.fd) }
        let f = try open(url)
        defer { close(f.fd) }
        guard h.bytes % page == 0, h.bytes >= lead * size, lead >= 0, frames - lead <= f.bytes / size else {
            throw PassableError.message("\(url.lastPathComponent) is shorter than its layout says.")
        }
        byteCount = h.bytes + f.bytes
        count = frames
        // Room for both, then each file mapped into its part of it.
        guard let base = mmap(nil, byteCount, PROT_NONE, MAP_ANON | MAP_PRIVATE, -1, 0), base != MAP_FAILED else {
            throw PassableError.message("Can't map \(url.lastPathComponent).")
        }
        guard mmap(base, h.bytes, PROT_READ, MAP_PRIVATE | MAP_FIXED, h.fd, 0) != MAP_FAILED,
              f.bytes == 0 || mmap(base + h.bytes, f.bytes, PROT_READ, MAP_PRIVATE | MAP_FIXED, f.fd, 0) != MAP_FAILED else {
            munmap(base, byteCount)
            throw PassableError.message("Can't map \(url.lastPathComponent).")
        }
        mapping = base
        pointer = UnsafePointer((base + h.bytes - lead * size).assumingMemoryBound(to: Float.self))
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
        // (A rendition shares its file with the song: see `saveRendition`.)
        var origin = 0, frames: Int?
        if let text = try? String(contentsOf: directory.appendingPathComponent("\(name).layout"), encoding: .utf8) {
            let numbers = text.split(separator: " ").compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            guard numbers.count == 2 else { throw PassableError.message("\(name).layout is damaged.") }
            (origin, frames) = (numbers[0], numbers[1])
        }
        func channel(_ c: String) throws -> MappedChannel {
            let url = directory.appendingPathComponent("\(name).\(c).f32")
            guard origin < 0, let frames else { return try MappedChannel(url: url, origin: origin, frames: frames) }
            return try MappedChannel(head: directory.appendingPathComponent("\(name).\(c).head.f32"), url: url,
                                     lead: -origin, frames: frames)
        }
        return StemAudio(left: try channel("L"), right: try channel("R"))
    }

    /// Saves a tempo-matched copy of `source` (saved as `sourceName` in
    /// `sourceDirectory`) taking no room for what it plays unchanged.
    ///
    /// A rendition is the song itself, frame for frame, from where its
    /// glide home ends until its way out begins (`TimeStretcher`): output
    /// frame y is source frame y + `offset` there. Each channel file is then
    /// a clone of the song's (APFS: shares its blocks), with the stretched
    /// head and tail written over it at the same shift, and the channel
    /// starts `offset` frames into the file. That run is found on the audio
    /// itself, compared bit for bit, so whatever the stretcher did, the
    /// file plays exactly `buffer`. A copy that can't be laid out that way
    /// (slowed down, so the shift is negative; no long unchanged run; no
    /// clones on this disk) is written whole.
    /// - Returns: whether it shares the song's file.
    @discardableResult
    static func saveRendition(_ buffer: StereoBuffer, source: StemAudio, sourceDirectory: URL, sourceName: String,
                              offset: Int?, directory: URL, name: String) throws -> Bool {
        let total = buffer.count
        guard let offset, total > 0 else { try save(buffer, directory: directory, name: name); return false }
        // Slowed down, the copy starts before the song's first frame: its
        // first frames go in a file of their own, mapped just before.
        let lead = max(0, -offset)
        let page = Int(getpagesize()) / MemoryLayout<Float>.size
        let headFrames = (lead + page - 1) / page * page
        /// The longest run around the middle where the copy is the song.
        func unchanged(_ copy: [Float], _ song: MappedChannel) -> Range<Int>? {
            let inSong = { (y: Int) in y + offset >= 0 && y + offset < song.count && copy[y].bitPattern == song.pointer[y + offset].bitPattern }
            var mid = total / 2
            // (Find one equal frame near the middle first.)
            while mid < total && !inSong(mid) { mid += 1 }
            guard mid < total else { return nil }
            var a = mid, b = mid + 1
            while a > 0 && inSong(a - 1) { a -= 1 }
            while b < total && inSong(b) { b += 1 }
            return a..<b
        }
        guard let runL = unchanged(buffer.left, source.left), let runR = unchanged(buffer.right, source.right) else {
            try save(buffer, directory: directory, name: name); return false
        }
        let run = runL.clamped(to: runR)
        // Worth it only past a few seconds, and after the lead.
        guard run.count > Int(10 * AudioIO.sampleRate), run.lowerBound >= lead else {
            try save(buffer, directory: directory, name: name); return false
        }
        for (channel, samples) in [("L", buffer.left), ("R", buffer.right)] {
            let from = sourceDirectory.appendingPathComponent("\(sourceName).\(channel).f32")
            let to = directory.appendingPathComponent("\(name).\(channel).f32")
            try? FileManager.default.removeItem(at: to)
            guard clonefile(from.path, to.path, 0) == 0 else {
                // No clones here (not APFS): the whole copy.
                for c in ["L", "R"] {
                    try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(name).\(c).f32"))
                    try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(name).\(c).head.f32"))
                }
                try save(buffer, directory: directory, name: name)
                return false
            }
            let fd = open(to.path, O_WRONLY)
            guard fd >= 0 else { throw PassableError.message("Can't write \(to.lastPathComponent).") }
            defer { close(fd) }
            let size = MemoryLayout<Float>.size
            if lead > 0 {
                var head = [Float](repeating: 0, count: headFrames)
                head.replaceSubrange((headFrames - lead)..<headFrames, with: samples[0..<lead])
                try MappedChannel.write(head, to: directory.appendingPathComponent("\(name).\(channel).head.f32"))
            }
            try samples.withUnsafeBytes { raw in
                for part in [lead..<run.lowerBound, run.upperBound..<total] where !part.isEmpty {
                    let bytes = UnsafeRawBufferPointer(rebasing: raw[(part.lowerBound * size)..<(part.upperBound * size)])
                    guard pwrite(fd, bytes.baseAddress, bytes.count, off_t((part.lowerBound + offset) * size)) == bytes.count else {
                        throw PassableError.message("Can't write \(to.lastPathComponent).")
                    }
                }
            }
        }
        try "\(offset) \(total)".write(to: directory.appendingPathComponent("\(name).layout"), atomically: true, encoding: .utf8)
        return true
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
