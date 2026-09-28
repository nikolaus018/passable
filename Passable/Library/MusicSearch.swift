import Foundation

struct MusicSearchResult: Identifiable, Equatable {
    let id: String
    let title: String
    let artist: String?
    let album: String?
    let duration: Double?
    /// A YouTube Music song: the label-delivered album master, as opposed
    /// to a video upload (edits, skits, re-uploads).
    let isOfficialAudio: Bool
    /// A file shared on Soulseek (nil: YouTube).
    var soulseek: SoulseekFile? = nil
    /// What the file is, where that's known ("FLAC 16/44.1", "MP3 320").
    var quality: String? = nil
}

/// Where songs are found online.
enum MusicSource: String, CaseIterable, Identifiable {
    case youtube, soulseek
    var id: String { rawValue }
    var displayName: String { self == .youtube ? "YouTube" : "Soulseek" }
}

/// Search and download via yt-dlp + ffmpeg (Homebrew), ported from SyncUp.
/// Tools run directly, never through a shell, with isolated configuration.
enum MusicTools {
    static let libraryFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Music/Passable", isDirectory: true)

    static func executable(_ name: String) throws -> URL {
        let paths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        guard let path = paths.map({ "\($0)/\(name)" }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw PassableError.message("\(name) is missing. Install it with `brew install \(name)`, then try again.")
        }
        return URL(fileURLWithPath: path)
    }

    static func run(_ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = try executable("yt-dlp")
        process.arguments = ["--ignore-config", "--no-plugin-dirs", "--socket-timeout", "20", "--retries", "2"] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        process.environment = environment
        // Files avoid filling a stderr pipe while stdout is being read.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("output")
        let errors = directory.appendingPathComponent("errors")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        FileManager.default.createFile(atPath: errors.path, contents: nil)
        let outHandle = try FileHandle(forWritingTo: output)
        let errHandle = try FileHandle(forWritingTo: errors)
        defer { try? outHandle.close(); try? errHandle.close() }
        process.standardOutput = outHandle
        process.standardError = errHandle
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = (try? String(contentsOf: errors, encoding: .utf8)) ?? "Search or download failed. Try again."
            throw PassableError.message(String(detail.suffix(1200)))
        }
        return try Data(contentsOf: output)
    }

    /// YouTube Music songs first (official album audio), then the top
    /// YouTube videos for remixes and edits that only exist as uploads.
    static func search(_ query: String) throws -> [MusicSearchResult] {
        var songs: Result<[MusicSearchResult], Error> = .success([])
        var videos: Result<[MusicSearchResult], Error> = .success([])
        DispatchQueue.concurrentPerform(iterations: 2) { i in
            if i == 0 { songs = Result { try songSearch(query) } } else { videos = Result { try videoSearch(query) } }
        }
        let found = Array(((try? songs.get()) ?? []).prefix(10))
        guard let more = try? videos.get() else {
            if found.isEmpty { _ = try videos.get() }
            return found
        }
        let ids = Set(found.map(\.id))
        return found + more.filter { !ids.contains($0.id) }.prefix(found.isEmpty ? 8 : 4)
    }

    private static func videoSearch(_ query: String) throws -> [MusicSearchResult] {
        let data = try run(["--flat-playlist", "--dump-single-json", "--", "ytsearch8:\(query)"])
        struct Entry: Decodable { let id: String; let title: String; let uploader: String?; let duration: Double? }
        struct Response: Decodable { let entries: [Entry] }
        return try JSONDecoder().decode(Response.self, from: data).entries.map {
            MusicSearchResult(id: $0.id, title: $0.title, artist: $0.uploader, album: nil, duration: $0.duration, isOfficialAudio: false)
        }
    }

    /// YouTube Music's own search, filtered to songs. yt-dlp's version of it
    /// returns titles only, so this asks the web client's API directly.
    private static func songSearch(_ query: String) throws -> [MusicSearchResult] {
        var request = URLRequest(url: URL(string: "https://music.youtube.com/youtubei/v1/search?prettyPrint=false")!, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://music.youtube.com", forHTTPHeaderField: "Origin")
        let body: [String: Any] = [
            "context": ["client": ["clientName": "WEB_REMIX", "clientVersion": "1.20250101.01.00", "hl": "en"]],
            "query": query,
            "params": "EgWKAQIIAWoKEAkQBRAKEAMQBA%3D%3D",  // filter: songs
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        var reply: Result<Data, Error> = .failure(PassableError.message("YouTube Music did not answer."))
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let data, (response as? HTTPURLResponse)?.statusCode == 200 {
                reply = .success(data)
            } else if let error {
                reply = .failure(error)
            }
            done.signal()
        }.resume()
        done.wait()
        return parseSongs(try JSONSerialization.jsonObject(with: try reply.get()))
    }

    /// Each song row is a `musicResponsiveListItemRenderer`: column one is
    /// the title, column two "Artist • Album • 3:20".
    static func parseSongs(_ json: Any) -> [MusicSearchResult] {
        var rows: [[String: Any]] = []
        func walk(_ node: Any) {
            if let dict = node as? [String: Any] {
                if let row = dict["musicResponsiveListItemRenderer"] as? [String: Any] { rows.append(row); return }
                dict.values.forEach(walk)
            } else if let list = node as? [Any] {
                list.forEach(walk)
            }
        }
        walk(json)
        return rows.compactMap { row in
            guard let id = (row["playlistItemData"] as? [String: Any])?["videoId"] as? String,
                  let columns = row["flexColumns"] as? [[String: Any]], columns.count >= 2 else { return nil }
            let text = columns.map { column -> String in
                let renderer = column["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any]
                let runs = (renderer?["text"] as? [String: Any])?["runs"] as? [[String: Any]] ?? []
                return runs.compactMap { $0["text"] as? String }.joined()
            }
            var parts = text[1].components(separatedBy: " • ")
            var duration: Double?
            if let last = parts.last, let seconds = seconds(last) { duration = seconds; parts.removeLast() }
            guard !text[0].isEmpty, !parts.isEmpty else { return nil }
            return MusicSearchResult(id: id, title: text[0], artist: parts[0], album: parts.count > 1 ? parts[1] : nil,
                                     duration: duration, isOfficialAudio: true)
        }
    }

    private static func seconds(_ clock: String) -> Double? {
        let fields = clock.split(separator: ":").map { Int($0) }
        guard (2...3).contains(fields.count), !fields.contains(nil) else { return nil }
        return Double(fields.reduce(0) { $0 * 60 + $1! })
    }

    /// Downloads the song exactly as YouTube stores it, never re-encoded:
    /// the Opus stream (itag 251, the best YouTube offers without Premium)
    /// saved as an Ogg `.opus` file, which Core Audio decodes natively and
    /// with its peaks above full scale intact. "drc" streams are YouTube's
    /// dynamic-range-compressed copies and are never picked. If YouTube
    /// refuses Opus twice, its AAC stream (itag 140) is kept as it is.
    static func download(_ result: MusicSearchResult, folder: URL = libraryFolder) throws -> URL {
        if result.soulseek != nil { return try Soulseek.download(result, folder: folder) }
        let opus = "251/bestaudio[acodec=opus][format_id!*=drc]"
        let aac = "140/bestaudio[ext=m4a][format_id!*=drc]"
        var lastError: Error?
        for format in [opus, opus, aac] {
            do {
                return try download(result, format: format, folder: folder)
            } catch {
                lastError = error
            }
        }
        throw lastError!
    }

    private static func download(_ result: MusicSearchResult, format: String, folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ffmpeg = try executable("ffmpeg")
        // Stage downloads outside the library: nothing should ever load a partial file.
        let staging = folder.appendingPathComponent(".downloads/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        // Songs are named "Artist - Title"; a video's title already says who it is.
        var name = "%(title).150B [%(id)s].%(ext)s"
        if result.isOfficialAudio, let artist = result.artist {
            let literal = String(artist.prefix(80)).replacingOccurrences(of: "%", with: "%%")
                .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            name = "\(literal) - \(name)"
        }
        // -x without --audio-format keeps the codec and only swaps the container.
        _ = try run(["--no-playlist", "--no-progress", "-f", format, "-x",
                     "--ffmpeg-location", ffmpeg.path, "-P", staging.path,
                     "-o", name, "--", "https://www.youtube.com/watch?v=\(result.id)"])
        let files = try FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
        guard let audio = files.first(where: { ["opus", "m4a"].contains($0.pathExtension.lowercased()) }) else {
            throw PassableError.message("The download did not produce an audio file.")
        }
        let destination = folder.appendingPathComponent(audio.lastPathComponent)
        if !FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.moveItem(at: audio, to: destination)
        }
        return destination
    }

    /// Audio files already in the library folder, newest first.
    static func libraryFiles() -> [URL] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: libraryFolder, includingPropertiesForKeys: [.contentModificationDateKey],
                                                     options: [.skipsHiddenFiles]) else { return [] }
        let audio = urls.filter { ["wav", "aif", "aiff", "caf", "flac", "mp3", "m4a", "opus"].contains($0.pathExtension.lowercased()) }
        func date(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        return audio.sorted { date($0) > date($1) }
    }
}

/// Song names as people say them: file and upload names minus the noise
/// ("(Official Audio)", "| Lyrics", "[dQw4w9WgXcQ]", underscores).
enum SongTitle {
    static func of(_ url: URL) -> String { clean(url.deletingPathExtension().lastPathComponent) }

    static func clean(_ raw: String) -> String {
        var t = raw
        if !t.contains(" "), t.contains("_") { t = t.replacingOccurrences(of: "_", with: " ") }
        let patterns = [
            #"\s*\[[A-Za-z0-9_-]{11}\]\s*$"#,                                     // video id
            #"\s*[\(\[][^\)\]]*(official|video|audio|lyric|visuali[sz]er|\bhd\b|\bhq\b|\b4k\b)[^\)\]]*[\)\]]"#,
            #"\s*[|｜].*$"#,                                                        // "| Lyrics", "| Channel"
            #"\s+(official\s+)?(music\s+)?(video|audio|lyrics?|visuali[sz]er)\s*$"#,
        ]
        for p in patterns {
            t = t.replacingOccurrences(of: p, with: "", options: [.regularExpression, .caseInsensitive])
        }
        t = t.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespaces).isEmpty ? raw : t.trimmingCharacters(in: .whitespaces)
    }
}
