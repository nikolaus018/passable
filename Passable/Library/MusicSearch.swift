import Foundation

struct MusicSearchResult: Decodable, Identifiable, Equatable {
    let id: String
    let title: String
    let uploader: String?
    let duration: Double?
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

    static func search(_ query: String) throws -> [MusicSearchResult] {
        let data = try run(["--flat-playlist", "--dump-single-json", "--", "ytsearch8:\(query)"])
        struct Response: Decodable { let entries: [MusicSearchResult] }
        return try JSONDecoder().decode(Response.self, from: data).entries
    }

    /// Downloads the song's audio as YouTube serves it (AAC in M4A), without
    /// re-encoding: YouTube audio is lossy, so WAV would only make it eight
    /// times bigger, never better. Only when no M4A stream exists is the best
    /// stream converted. Returns the file's URL in the library folder.
    static func download(_ result: MusicSearchResult, folder: URL = libraryFolder) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ffmpeg = try executable("ffmpeg")
        // Stage downloads outside the library: nothing should ever load a partial file.
        let staging = folder.appendingPathComponent(".downloads/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        _ = try run(["--no-playlist", "--no-progress", "-f", "bestaudio[ext=m4a]/bestaudio/best", "-x", "--audio-format", "m4a",
                     "--ffmpeg-location", ffmpeg.path, "-P", staging.path,
                     "-o", "%(title).150B [%(id)s].%(ext)s", "--", "https://www.youtube.com/watch?v=\(result.id)"])
        let files = try FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
        guard let audio = files.first(where: { $0.pathExtension.lowercased() == "m4a" }) else {
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
        let audio = urls.filter { ["wav", "aif", "aiff", "caf", "flac", "mp3", "m4a"].contains($0.pathExtension.lowercased()) }
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
