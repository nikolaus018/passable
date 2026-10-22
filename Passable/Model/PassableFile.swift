import AVFoundation
import CryptoKit
import Foundation
import UniformTypeIdentifiers

extension UTType {
    /// A whole set in one file, declared in Info.plist.
    static let passableSet = UTType(exportedAs: "com.nikolausmarek.passable.set", conformingTo: .data)
}

/// The `.passable` file: a set that opens anywhere, songs included.
///
/// Layout (all integers big-endian):
///
///     "PASSABLE" 0D 0A 1A 0A     magic; the line-ending and ^Z bytes catch
///                                 text-mode transfers, as in PNG
///     UInt16                      format version
///     chunks, until "END ":
///       4 ASCII bytes             type
///       UInt64                    payload length
///       payload
///
///     "MNFT"  the manifest, JSON (`Manifest`); always the first chunk
///     "AUDI"  UInt32 song index, then that song's audio file, byte for byte
///     "END "  empty
///
/// Unknown chunk types are skipped, so later versions can add chunks that
/// older readers ignore. Songs stored as PCM are re-encoded to Apple Lossless
/// (bit-identical, about half the size); anything else is stored as is, so
/// a lossy file is never transcoded. Each song carries its analysis, so the
/// beat grids the transitions were shaped on come along unchanged.
enum PassableFile {
    static let formatVersion: UInt16 = 1
    private static let magic: [UInt8] = Array("PASSABLE".utf8) + [0x0D, 0x0A, 0x1A, 0x0A]

    struct Manifest: Codable, Equatable {
        var format: Int
        var app: String
        var created: Date
        var masterVolume: Double
        var songs: [Song]
        /// Hand-shaped transitions, by song index; the rest are planned
        /// automatically again.
        var transitions: [Transition]
    }

    struct Song: Codable, Equatable {
        var title: String
        /// The file name it had when exported.
        var fileName: String
        var sourceSize: Int
        var sourceSHA256: String
        /// Extension of the stored audio: "caf" (Apple Lossless) or the source's.
        var audioExtension: String
        var audioSize: Int
        var audioSHA256: String
        var analysis: TrackAnalysis?
    }

    struct Transition: Codable, Equatable {
        var from: Int
        var to: Int
        var edit: TransitionEdit
    }

    struct Opened {
        var manifest: Manifest
        /// Where each song now lives, in set order.
        var urls: [URL]
    }

    // MARK: - Writing

    static func write(songs: [(url: URL, analysis: TrackAnalysis?)], transitions: [Transition], masterVolume: Double,
                      to destination: URL, progress: (Double) -> Void) throws {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("passable-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        // Encoding is most of the work; copying into the file is the rest.
        var entries: [Song] = []
        var payloads: [URL] = []
        for (i, song) in songs.enumerated() {
            let (sourceSize, sourceHash) = try digest(of: song.url)
            let payload: URL
            if let lossless = try encodeLossless(song.url, to: scratch.appendingPathComponent("\(i).caf")) {
                payload = lossless
            } else {
                payload = song.url
            }
            let (audioSize, audioHash) = payload == song.url ? (sourceSize, sourceHash) : try digest(of: payload)
            entries.append(Song(title: SongTitle.of(song.url), fileName: song.url.lastPathComponent,
                                sourceSize: sourceSize, sourceSHA256: sourceHash,
                                audioExtension: payload.pathExtension.lowercased(),
                                audioSize: audioSize, audioSHA256: audioHash, analysis: song.analysis))
            payloads.append(payload)
            progress(Double(i + 1) / Double(songs.count) * 0.8)
        }

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let manifest = Manifest(format: Int(formatVersion), app: "Passable \(version)", created: Date(),
                                masterVolume: masterVolume, songs: entries, transitions: transitions)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        // Written beside the destination, then swapped in: a failed export
        // never leaves half a file where a good one was.
        let partial = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).partial")
        fm.createFile(atPath: partial.path, contents: nil)
        do {
            let out = try FileHandle(forWritingTo: partial)
            defer { try? out.close() }
            try out.write(contentsOf: Data(magic) + bigEndian(formatVersion))
            try writeChunk("MNFT", try encoder.encode(manifest), to: out)
            for (i, payload) in payloads.enumerated() {
                let size = UInt64(entries[i].audioSize)
                try out.write(contentsOf: Data("AUDI".utf8) + bigEndian(size + 4) + bigEndian(UInt32(i)))
                let input = try FileHandle(forReadingFrom: payload)
                defer { try? input.close() }
                var hasher = SHA256()
                try copy(size, from: input, to: out, hasher: &hasher)
                progress(0.8 + Double(i + 1) / Double(payloads.count) * 0.2)
            }
            try writeChunk("END ", Data(), to: out)
            try out.synchronize()
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: partial)
        } else {
            try fm.moveItem(at: partial, to: destination)
        }
    }

    /// Re-encodes integer PCM to Apple Lossless; nil for anything else
    /// (compressed or float sources are stored as they are).
    private static func encodeLossless(_ source: URL, to destination: URL) throws -> URL? {
        let input = try AVAudioFile(forReading: source)
        let description = input.fileFormat.streamDescription.pointee
        let bits = Int(description.mBitsPerChannel)
        // (Not 32-bit integers: Float32, which the samples pass through,
        // holds 24 bits exactly and no more. Such a file is stored as is.)
        guard description.mFormatID == kAudioFormatLinearPCM,
              description.mFormatFlags & kAudioFormatFlagIsFloat == 0,
              [16, 20, 24].contains(bits) else { return nil }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatAppleLossless,
            AVSampleRateKey: input.fileFormat.sampleRate,
            AVNumberOfChannelsKey: input.fileFormat.channelCount,
            AVEncoderBitDepthHintKey: bits,
        ]
        // Float32 holds every 16- and 24-bit sample exactly, so the round
        // trip through the processing format is lossless.
        let output = try AVAudioFile(forWriting: destination, settings: settings,
                                     commonFormat: input.processingFormat.commonFormat,
                                     interleaved: input.processingFormat.isInterleaved)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 1 << 16) else {
            throw PassableError.message("Out of memory encoding \(source.lastPathComponent).")
        }
        while input.framePosition < input.length {
            try input.read(into: buffer)
            if buffer.frameLength == 0 { break }
            try output.write(from: buffer)
        }
        return destination
    }

    // MARK: - Reading

    /// Unpacks a set, putting its songs into `folder` (reusing any copy
    /// already there) and seeding their analyses, so the set comes back
    /// exactly as it was exported.
    static func read(_ url: URL, into folder: URL, progress: (Double) -> Void) throws -> Opened {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let total = max(1, (try? input.seekToEnd()) ?? 1)
        try input.seek(toOffset: 0)

        func read(_ count: Int) throws -> Data {
            let data = try input.read(upToCount: count) ?? Data()
            guard data.count == count else { throw damaged }
            return data
        }
        guard try read(magic.count) == Data(magic) else {
            throw PassableError.message("\(url.lastPathComponent) isn't a Passable set.")
        }
        let version = UInt16(bigEndian: try read(2))
        guard version <= formatVersion else {
            throw PassableError.message("\(url.lastPathComponent) was made by a newer Passable. Update Passable to open it.")
        }

        var manifest: Manifest?
        var urls: [URL?] = []
        while true {
            let type = String(decoding: try read(4), as: UTF8.self)
            let length = UInt64(bigEndian: try read(8))
            switch type {
            case "END ":
                guard let manifest else { throw damaged }
                let missing = zip(manifest.songs, urls).filter { $0.1 == nil }.map(\.0.title)
                guard missing.isEmpty else {
                    throw PassableError.message("\(url.lastPathComponent) is missing the audio of \(missing.joined(separator: ", ")).")
                }
                return Opened(manifest: manifest, urls: urls.compactMap { $0 })
            case "MNFT":
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let decoded = try decoder.decode(Manifest.self, from: try read(Int(length)))
                manifest = decoded
                urls = Array(repeating: nil, count: decoded.songs.count)
            case "AUDI":
                guard let manifest, length >= 4 else { throw damaged }
                let index = Int(UInt32(bigEndian: try read(4)))
                guard manifest.songs.indices.contains(index), UInt64(manifest.songs[index].audioSize) == length - 4 else {
                    throw damaged
                }
                urls[index] = try unpack(manifest.songs[index], from: input, into: folder)
            default:
                try input.seek(toOffset: try input.offset() + length)
            }
            progress(Double(try input.offset()) / Double(total))
        }
    }

    /// Places one song's audio, reusing an identical copy already in the
    /// folder (so its stems don't have to be separated again).
    private static func unpack(_ song: Song, from input: FileHandle, into folder: URL) throws -> URL {
        let fm = FileManager.default
        let base = (song.fileName as NSString).deletingPathExtension
        let stored = song.audioExtension == (song.fileName as NSString).pathExtension.lowercased()
            ? song.fileName : "\(base).\(song.audioExtension)"
        let original = folder.appendingPathComponent(song.fileName)
        let unpacked = folder.appendingPathComponent(stored)
        var destination: URL?
        if matches(original, size: song.sourceSize, hash: song.sourceSHA256) {
            destination = original
        } else if matches(unpacked, size: song.audioSize, hash: song.audioSHA256) {
            destination = unpacked
        }

        if let destination {
            try input.seek(toOffset: try input.offset() + UInt64(song.audioSize))
            seed(song, at: destination)
            return destination
        }

        let partial = folder.appendingPathComponent(".\(UUID().uuidString).partial")
        fm.createFile(atPath: partial.path, contents: nil)
        do {
            let out = try FileHandle(forWritingTo: partial)
            defer { try? out.close() }
            var hasher = SHA256()
            try copy(UInt64(song.audioSize), from: input, to: out, hasher: &hasher)
            guard hex(hasher.finalize()) == song.audioSHA256 else { throw damaged }
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
        // A different file already has the name: keep both.
        var target = unpacked
        var n = 2
        while fm.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent("\(base) \(n).\(song.audioExtension)")
            n += 1
        }
        try fm.moveItem(at: partial, to: target)
        seed(song, at: target)
        return target
    }

    /// The set was shaped on this analysis (grids corrected by hand
    /// included); stale versions are left to be redone.
    private static func seed(_ song: Song, at url: URL) {
        guard let analysis = song.analysis, analysis.version == TrackAnalysis.currentVersion,
              let directory = try? StemCache.directory(for: url) else { return }
        StemCache.saveAnalysis(analysis, to: directory)
    }

    private static func matches(_ url: URL, size: Int, hash: String) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.size] as? Int) == size else { return false }
        return (try? digest(of: url).sha) == hash
    }

    // MARK: - Bytes

    private static let damaged = PassableError.message("This Passable set is damaged or incomplete.")

    private static func writeChunk(_ type: String, _ payload: Data, to out: FileHandle) throws {
        try out.write(contentsOf: Data(type.utf8) + bigEndian(UInt64(payload.count)) + payload)
    }

    private static func copy(_ count: UInt64, from input: FileHandle, to output: FileHandle, hasher: inout SHA256) throws {
        var left = count
        while left > 0 {
            let data = try input.read(upToCount: Int(min(left, 1 << 20))) ?? Data()
            guard !data.isEmpty else { throw damaged }
            hasher.update(data: data)
            try output.write(contentsOf: data)
            left -= UInt64(data.count)
        }
    }

    private static func digest(of url: URL) throws -> (size: Int, sha: String) {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var hasher = SHA256()
        var size = 0
        while let data = try input.read(upToCount: 1 << 20), !data.isEmpty {
            hasher.update(data: data)
            size += data.count
        }
        return (size, hex(hasher.finalize()))
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func bigEndian<T: FixedWidthInteger>(_ value: T) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }
}

private extension FixedWidthInteger {
    init(bigEndian data: Data) {
        self = data.reduce(0) { $0 << 8 | Self($1) }
    }
}
