import Foundation

/// A `.passablemix` file: one rendered set (a single continuous AAC file, with
/// every transition already inside it) plus the map of where each song sits.
/// Passable on the Mac writes it, the Passable app on the iPhone plays it.
///
/// The iPhone app (`ios/`) compiles this same file: one format, one source.
///
/// Layout, all integers little-endian:
///
///     11 bytes    magic: "PASSMIX" 0D 0A 1A 0A
///     UInt16      format version
///     chunks, each:
///       4 ASCII bytes   type
///       UInt64          payload length
///       payload
///
///     "MNFT"  the manifest, JSON (`Manifest`); always the first chunk
///     "AUDI"  the audio file, byte for byte (`Manifest.audio.fileExtension`)
///     "END "  empty
///
/// Unknown chunk types are skipped, so later versions can add chunks (cover
/// art, lyrics) that older readers ignore.
enum PassableMix {
    static let formatVersion: UInt16 = 1
    static let fileExtension = "passablemix"
    /// The Multipeer / Bonjour service name both apps use to find each other.
    static let serviceType = "passablemix"
    static let typeIdentifier = "com.nikolausmarek.passable.mix"
    private static let magic: [UInt8] = Array("PASSMIX".utf8) + [0x0D, 0x0A, 0x1A, 0x0A]

    // MARK: - The map

    struct Manifest: Codable, Equatable, Identifiable {
        var format: Int = Int(PassableMix.formatVersion)
        /// Identifies the mix across exports, so sending the same set twice
        /// replaces it on the phone instead of piling up copies.
        var id: UUID = UUID()
        var title: String
        var created: Date = Date()
        /// Which app and machine wrote it.
        var source: String = ""
        /// Seconds of music; the audio file rings out a few seconds longer.
        var duration: Double
        var audio: Audio
        var songs: [Song]
        var transitions: [Transition]
    }

    struct Audio: Codable, Equatable {
        var fileExtension: String = "m4a"
        var codec: String = "aac"
        var sampleRate: Double = 44_100
        var bitRate: Int = 256_000
        var size: Int
    }

    /// One song of the set. All times are seconds into the audio file.
    struct Song: Codable, Equatable, Identifiable {
        var id: Int { index }
        var index: Int
        var title: String
        var artist: String?
        /// First moment the song is audible: where the blend into it begins.
        var start: Double
        /// Where it takes over from the song before (its first bar, or its
        /// drop): from here on it is "the song that's playing".
        var handover: Double
        /// Where the blend into it is over and it plays on alone.
        var solo: Double
        /// Where it is gone (the blend out of it is over, or the set ends).
        var end: Double
        var bpm: Double?
        var key: String?
    }

    /// The blend from `from` into `to` (song indexes).
    struct Transition: Codable, Equatable {
        var from: Int
        var to: Int
        var begins: Double
        var handover: Double
        var end: Double
        /// "Drop Swap", "Long Blend", ...
        var style: String
        /// What makes it more than a crossfade, in words.
        var notes: [String] = []
    }

    /// What the Mac tells the phone before sending a mix over Wi-Fi, so the
    /// phone can ask its owner (it's sent as the Multipeer invitation context).
    struct Invitation: Codable, Equatable {
        var title: String
        var songs: Int
        var bytes: Int
        var minutes: Int
    }

    // MARK: - Reading the map

    /// What "Next" and "Previous" jump to.
    enum SkipLanding: String, Codable, CaseIterable, Identifiable {
        /// The new song as it starts to blend in: the transition plays.
        case blend
        /// The new song as it takes over: straight to the good part.
        case handover
        var id: String { rawValue }
    }

}

extension PassableMix.Manifest {
    /// The song that's playing at `time`: the one that last took over.
    func songIndex(at time: Double) -> Int {
        songs.lastIndex(where: { $0.handover <= time + 0.001 }) ?? 0
    }

    func song(at time: Double) -> PassableMix.Song? {
        songs.isEmpty ? nil : songs[songIndex(at: time)]
    }

    /// The blend that's going on at `time`, if any.
    func transition(at time: Double) -> PassableMix.Transition? {
        transitions.first { $0.begins <= time && time < $0.end }
    }

    /// 0...1 through the blend at `time`.
    func transitionProgress(at time: Double) -> Double? {
        guard let t = transition(at: time), t.end > t.begins else { return nil }
        return (time - t.begins) / (t.end - t.begins)
    }

    /// Seconds the song's own stretch of the set lasts, from its takeover to
    /// the next song's.
    func length(ofSong i: Int) -> Double {
        guard songs.indices.contains(i) else { return 0 }
        let next = songs.indices.contains(i + 1) ? songs[i + 1].handover : duration
        return max(0, next - songs[i].handover)
    }

    func landing(of i: Int, _ mode: PassableMix.SkipLanding) -> Double {
        let s = songs[i]
        return mode == .blend ? s.start : s.handover
    }

    /// Where Next lands from `time`: the first later song start that's
    /// really ahead (never back into the blend that's already playing).
    func nextTarget(from time: Double, _ mode: PassableMix.SkipLanding) -> Double? {
        let current = songIndex(at: time)
        for i in songs.indices where i > current {
            let t = landing(of: i, mode)
            if t > time + 0.5 { return t }
        }
        return nil
    }

    /// Where Previous lands: the start of the song that's playing, or, in
    /// its first seconds, the start of the one before.
    func previousTarget(from time: Double, _ mode: PassableMix.SkipLanding) -> Double {
        let current = songIndex(at: time)
        guard songs.indices.contains(current) else { return 0 }
        let own = current == 0 ? 0 : landing(of: current, mode)
        if time - own > 3 || current == 0 { return own }
        return current - 1 == 0 ? 0 : landing(of: current - 1, mode)
    }
}

// MARK: - The file

extension PassableMix {
    enum FileError: LocalizedError {
        case notAMix, newerVersion(Int), truncated, noAudio, noManifest

        var errorDescription: String? {
            switch self {
            case .notAMix: return "This isn't a Passable mix."
            case .newerVersion(let v): return "This mix was made by a newer Passable (format \(v)). Update the app to open it."
            case .truncated: return "The mix file is cut short. Try sending it again."
            case .noAudio: return "The mix has no audio in it."
            case .noManifest: return "The mix has no song list in it."
            }
        }
    }

    private static let chunkHeader = 12
    private static let copyBlock = 1 << 20

    /// Writes `manifest` and the audio file at `audio` into one `.passablemix`.
    /// `manifest.audio.size` is set from the file.
    static func write(_ manifest: Manifest, audio: URL, to destination: URL) throws {
        var manifest = manifest
        let size = (try FileManager.default.attributesOfItem(atPath: audio.path)[.size] as? NSNumber)?.intValue ?? 0
        manifest.audio.size = size
        manifest.audio.fileExtension = audio.pathExtension.lowercased()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let json = try encoder.encode(manifest)

        let temp = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).part")
        FileManager.default.createFile(atPath: temp.path, contents: nil)
        let out = try FileHandle(forWritingTo: temp)
        do {
            var head = Data(magic)
            head.append(le(formatVersion))
            try out.write(contentsOf: head)
            try out.write(contentsOf: chunk("MNFT", length: json.count))
            try out.write(contentsOf: json)
            try out.write(contentsOf: chunk("AUDI", length: size))
            let input = try FileHandle(forReadingFrom: audio)
            defer { try? input.close() }
            while let block = try input.read(upToCount: copyBlock), !block.isEmpty {
                try out.write(contentsOf: block)
            }
            try out.write(contentsOf: chunk("END ", length: 0))
            try out.close()
        } catch {
            try? out.close()
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: temp)
    }

    /// Reads just the manifest (cheap: the audio isn't touched).
    static func readManifest(from url: URL) throws -> Manifest {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        try readHeader(input)
        guard let (tag, length) = try readChunkHeader(input), tag == "MNFT" else { throw FileError.noManifest }
        return try decodeManifest(try readExactly(input, Int(length)))
    }

    /// Reads the manifest and writes the audio out to `audioDestination`
    /// (a file, not loaded into memory). `progress` runs with 0...1.
    static func extract(from url: URL, audioTo audioDestination: URL,
                        progress: ((Double) -> Void)? = nil) throws -> Manifest {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        try readHeader(input)
        var manifest: Manifest?
        var wroteAudio = false
        while let (tag, length) = try readChunkHeader(input) {
            switch tag {
            case "MNFT":
                manifest = try decodeManifest(try readExactly(input, Int(length)))
            case "AUDI":
                FileManager.default.createFile(atPath: audioDestination.path, contents: nil)
                let out = try FileHandle(forWritingTo: audioDestination)
                defer { try? out.close() }
                var left = Int(length)
                while left > 0 {
                    guard let block = try input.read(upToCount: min(copyBlock, left)), !block.isEmpty else {
                        throw FileError.truncated
                    }
                    try out.write(contentsOf: block)
                    left -= block.count
                    if length > 0 { progress?(Double(Int(length) - left) / Double(length)) }
                }
                wroteAudio = true
            case "END ":
                break
            default:
                try input.seek(toOffset: try input.offset() + length)
            }
            if tag == "END " { break }
        }
        guard let manifest else { throw FileError.noManifest }
        guard wroteAudio else { throw FileError.noAudio }
        return manifest
    }

    // MARK: Plumbing

    private static func decodeManifest(_ data: Data) throws -> Manifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(Manifest.self, from: data)
        if manifest.format > Int(formatVersion) { throw FileError.newerVersion(manifest.format) }
        return manifest
    }

    private static func readHeader(_ input: FileHandle) throws {
        guard let head = try input.read(upToCount: magic.count + 2), head.count == magic.count + 2 else {
            throw FileError.notAMix
        }
        guard Array(head.prefix(magic.count)) == magic else { throw FileError.notAMix }
        let version = UInt16(head[magic.count]) | UInt16(head[magic.count + 1]) << 8
        if version > formatVersion { throw FileError.newerVersion(Int(version)) }
    }

    private static func readChunkHeader(_ input: FileHandle) throws -> (String, UInt64)? {
        guard let head = try input.read(upToCount: chunkHeader), !head.isEmpty else { return nil }
        guard head.count == chunkHeader else { throw FileError.truncated }
        let tag = String(decoding: head.prefix(4), as: UTF8.self)
        var length: UInt64 = 0
        for (i, byte) in head.suffix(8).enumerated() { length |= UInt64(byte) << (8 * UInt64(i)) }
        return (tag, length)
    }

    private static func readExactly(_ input: FileHandle, _ count: Int) throws -> Data {
        guard count >= 0, count < 64 << 20 else { throw FileError.truncated }
        guard let data = try input.read(upToCount: count), data.count == count else { throw FileError.truncated }
        return data
    }

    private static func chunk(_ tag: String, length: Int) -> Data {
        var d = Data(tag.utf8)
        d.append(le(UInt64(length)))
        return d
    }

    private static func le<T: FixedWidthInteger>(_ value: T) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
}
