import Foundation
import Security

/// One file a Soulseek user shares.
struct SoulseekFile: Equatable {
    let username: String
    /// The path as the sharer sent it (usually with backslashes).
    let filename: String
    let size: Int64
}

/// Songs from Soulseek, where people share the files off their own CDs and
/// stores: FLAC, WAV and AIFF, where YouTube only has lossy streams.
///
/// Passable talks to slskd (github.com/slskd/slskd), a Soulseek client
/// that runs in the background with a web API and logs in with the user's
/// own Soulseek account: it asks slskd to search and to download, then
/// copies the finished file into the library.
enum Soulseek {
    struct Settings: Equatable {
        /// Where slskd's web API listens.
        var url: String
        var apiKey: String
        /// slskd's downloads folder as this Mac sees it; empty: ask slskd
        /// (right unless it runs in a container).
        var downloadsFolder: String

        static let defaultURL = "http://localhost:5030"

        var isConfigured: Bool {
            !apiKey.trimmingCharacters(in: .whitespaces).isEmpty && Soulseek.base(url) != nil
        }

        /// The address and folder in the defaults, the key in the keychain.
        static var current: Settings {
            get {
                let d = UserDefaults.standard
                return Settings(url: d.string(forKey: "SoulseekURL") ?? defaultURL, apiKey: Keychain.read() ?? "",
                                downloadsFolder: d.string(forKey: "SoulseekDownloadsFolder") ?? "")
            }
            set {
                let d = UserDefaults.standard
                d.set(newValue.url.trimmingCharacters(in: .whitespaces), forKey: "SoulseekURL")
                d.set(newValue.downloadsFolder.trimmingCharacters(in: .whitespaces), forKey: "SoulseekDownloadsFolder")
                Keychain.write(newValue.apiKey.trimmingCharacters(in: .whitespaces))
            }
        }
    }

    // MARK: - Search

    /// The best files for `query`: lossless first, then 320 kbps MP3s,
    /// from sharers who can send them now.
    static func search(_ query: String, settings: Settings = .current) throws -> [MusicSearchResult] {
        let id = UUID().uuidString.lowercased()
        let body: [String: Any] = ["id": id, "searchText": query, "searchTimeout": 8, "responseLimit": 200,
                                   "fileLimit": 5000, "filterResponses": true]
        try expect(call("POST", ["searches"], body: body, settings: settings), 200, 201)
        defer { _ = try? call("DELETE", ["searches", id], settings: settings) }
        // Answers keep trickling in for a while; a search is done when
        // slskd says so, or after 20 s with what's there by then.
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 1)
            let state = try expect(call("GET", ["searches", id], settings: settings), 200)
            if (try? JSONSerialization.jsonObject(with: state) as? [String: Any])?["isComplete"] as? Bool == true { break }
        }
        _ = try? call("PUT", ["searches", id], settings: settings)
        let responses = try expect(call("GET", ["searches", id, "responses"], settings: settings), 200)
        return results(responses, query: query)
    }

    struct Response: Decodable {
        let username: String
        let files: [File]
        let hasFreeUploadSlot: Bool?
        let queueLength: Int?
        let uploadSpeed: Int?
    }

    struct File: Decodable {
        let filename: String
        let size: Int64
        let bitRate: Int?, bitDepth: Int?, sampleRate: Int?
        /// Seconds.
        let length: Int?
        let isLocked: Bool?
    }

    /// slskd's search responses as results, best first: one per file (the
    /// sharer most likely to send it soonest), only songs that name every
    /// word of the query, only formats that beat YouTube.
    static func results(_ data: Data, query: String, limit: Int = 40) -> [MusicSearchResult] {
        guard let responses = try? JSONDecoder().decode([Response].self, from: data) else { return [] }
        let wanted = words(query)
        let unwanted = ["remix", "live", "instrumental", "karaoke", "acapella", "cappella", "cover", "sped", "slowed",
                        "nightcore", "reverb", "8d", "edit", "bootleg", "mashup", "demo"].filter { !wanted.contains($0) }
        var best: [String: (score: Double, result: MusicSearchResult)] = [:]
        for response in responses {
            for file in response.files where file.isLocked != true {
                guard let grade = quality(file) else { continue }
                if let length = file.length, length < 60 || length > 20 * 60 { continue }
                let path = words(file.filename)
                guard wanted.allSatisfy(path.contains) else { continue }
                var score = Double(grade.tier) * 10
                if unwanted.contains(where: path.contains) { score -= 15 }
                if response.hasFreeUploadSlot == true { score += 3 }
                score -= min(3, Double(response.queueLength ?? 0) / 10)
                score += min(2, Double(response.uploadSpeed ?? 0) / 1_000_000)
                let parsed = parse(file.filename)
                let shared = SoulseekFile(username: response.username, filename: file.filename, size: file.size)
                let result = MusicSearchResult(id: token(shared.username + "\u{0}" + shared.filename), title: parsed.title,
                                               artist: parsed.artist, album: parsed.album,
                                               duration: file.length.map(Double.init), isOfficialAudio: false,
                                               soulseek: shared, quality: grade.label)
                let key = "\(basename(file.filename).lowercased())|\(file.size)"
                if score > best[key]?.score ?? -.infinity { best[key] = (score, result) }
            }
        }
        return best.values.sorted { $0.score != $1.score ? $0.score > $1.score : $0.result.id < $1.result.id }
            .prefix(limit).map { $0.result }
    }

    /// Lossless (2) or a 320 kbps MP3 (1); nil: no better than YouTube.
    static func quality(_ file: File) -> (tier: Int, label: String)? {
        let ext = (basename(file.filename) as NSString).pathExtension.lowercased()
        switch ext {
        case "flac", "wav", "aif", "aiff":
            let format = ext == "aif" ? "AIFF" : ext.uppercased()
            guard let depth = file.bitDepth, let rate = file.sampleRate, rate > 0 else { return (2, format) }
            let khz = rate % 1000 == 0 ? "\(rate / 1000)" : String(format: "%.1f", Double(rate) / 1000)
            return (2, "\(format) \(depth)/\(khz)")
        case "mp3":
            guard let kbps = file.bitRate, kbps >= 300 else { return nil }
            return (1, "MP3 \(min(kbps, 320))")
        default:
            return nil
        }
    }

    /// Artist, title and album from a shared path such as
    /// `Music\Artist - Album (2019)\03 - Artist - Title.flac`.
    static func parse(_ path: String) -> (title: String, artist: String?, album: String?) {
        let parts = components(path)
        var name = ((parts.last ?? path) as NSString).deletingPathExtension
        // A track number: "03 - ", "03. ", "03_", "03 " (two digits or
        // punctuation, so "2 Chainz" keeps its 2).
        name = name.replacingOccurrences(of: #"^\s*(\d{1,3}\s*[-._)]|\d{2,3}\s)\s*"#, with: "", options: .regularExpression)
        let album = parts.count > 1 ? parts[parts.count - 2] : nil
        let pieces = name.components(separatedBy: " - ")
        if pieces.count > 1, !pieces[0].trimmingCharacters(in: .whitespaces).isEmpty {
            return (pieces.dropFirst().joined(separator: " - ").trimmingCharacters(in: .whitespaces),
                    pieces[0].trimmingCharacters(in: .whitespaces), album)
        }
        let artist = album.flatMap { a -> String? in
            let p = a.components(separatedBy: " - ")
            return p.count > 1 ? p[0].trimmingCharacters(in: .whitespaces) : nil
        }
        return (name.trimmingCharacters(in: .whitespaces), artist, album)
    }

    private static func components(_ path: String) -> [String] {
        path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).map(String.init)
    }

    static func basename(_ path: String) -> String { components(path).last ?? path }

    /// Lower-cased letters and digits, diacritics folded, as a set of words.
    private static func words(_ text: String) -> Set<String> {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return Set(folded.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
    }

    /// Eleven characters naming a shared file for good, like a YouTube id,
    /// so a download is recognised by name (and cleaned out of titles).
    static func token(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        return String((0..<11).map { alphabet[Int((hash >> (UInt64($0) * 6)) & 63)] })
    }

    // MARK: - Download

    /// Downloads the file through slskd and copies it into `folder`, named
    /// "Artist - Title [token].flac". Gives up on a sharer who doesn't
    /// start sending within 90 s (a long queue, or gone offline).
    static func download(_ result: MusicSearchResult, folder: URL = MusicTools.libraryFolder,
                         settings: Settings = .current) throws -> URL {
        guard let file = result.soulseek else { throw PassableError.message("Not a Soulseek result.") }
        let ext = (basename(file.filename) as NSString).pathExtension.lowercased()
        let title = [result.artist, result.title].compactMap { $0 }.joined(separator: " - ")
        let safe = String(title.prefix(150)).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let destination = folder.appendingPathComponent("\(safe) [\(result.id)].\(ext)")
        if FileManager.default.fileExists(atPath: destination.path) { return destination }

        let downloads = try downloadsFolder(settings)
        let started = Date()
        let enqueued = try expect(call("POST", ["transfers", "downloads", file.username],
                                       body: [["filename": file.filename, "size": file.size]], settings: settings), 200, 201)
        let reply = try? JSONSerialization.jsonObject(with: enqueued) as? [String: Any]
        let id = ((reply?["enqueued"] as? [[String: Any]])?.first?["id"] as? String)
        if id == nil, let failed = reply?["failed"] as? [Any], !failed.isEmpty {
            throw PassableError.message("\(file.username) can't be asked for this file right now. Try another result.")
        }

        var lastBytes: Int64 = -1, lastProgress = Date()
        while true {
            Thread.sleep(forTimeInterval: 1)
            guard let transfer = try self.transfer(file, id: id, settings: settings) else {
                if Date().timeIntervalSince(started) > 30 { throw PassableError.message("slskd lost the download. Try again.") }
                continue
            }
            let state = transfer["state"] as? String ?? ""
            if state.contains("Succeeded") { break }
            if state.contains("Completed") {
                throw PassableError.message("\(file.username) didn't send the file (\(state)). Try another result.")
            }
            let bytes = (transfer["bytesTransferred"] as? NSNumber)?.int64Value ?? 0
            if bytes != lastBytes { lastBytes = bytes; lastProgress = Date() }
            if Date().timeIntervalSince(lastProgress) > 90 {
                if let tid = transfer["id"] as? String {
                    _ = try? call("DELETE", ["transfers", "downloads", file.username, tid], query: "remove=true",
                                  settings: settings)
                }
                throw PassableError.message(bytes > 0 ? "\(file.username) stopped sending. Try another result."
                                                      : "\(file.username) has a queue. Try another result.")
            }
        }

        // slskd moves the finished file into its downloads folder, in a
        // subfolder its own settings decide: found by size and time.
        var found: URL?
        for _ in 0..<20 {
            found = finished(file, in: downloads, since: started)
            if found != nil { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        guard let source = found else {
            throw PassableError.message("slskd finished the download, but it isn't in \(downloads.path). "
                                        + "If slskd runs in a container, set its downloads folder in Soulseek settings.")
        }
        // Staged next to the library: nothing should ever load a partial file.
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let staging = folder.appendingPathComponent(".downloads/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let staged = staging.appendingPathComponent(destination.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: staged)
        if !FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.moveItem(at: staged, to: destination)
        }
        return destination
    }

    /// The transfer slskd keeps for `file`: by id, or the newest for it.
    private static func transfer(_ file: SoulseekFile, id: String?, settings: Settings) throws -> [String: Any]? {
        if let id {
            let (status, data) = try call("GET", ["transfers", "downloads", file.username, id], settings: settings)
            if status == 200 { return try? JSONSerialization.jsonObject(with: data) as? [String: Any] }
        }
        let (status, data) = try call("GET", ["transfers", "downloads", file.username], settings: settings)
        guard status == 200, let user = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let directories = user["directories"] as? [[String: Any]] else { return nil }
        return directories.flatMap { $0["files"] as? [[String: Any]] ?? [] }
            .filter { $0["filename"] as? String == file.filename }
            .max { ($0["requestedAt"] as? String ?? "") < ($1["requestedAt"] as? String ?? "") }
    }

    /// The newest file in `folder` (at any depth) of the shared file's
    /// size, written since `since`; its own name first.
    static func finished(_ file: SoulseekFile, in folder: URL, since: Date) -> URL? {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return nil }
        let name = basename(file.filename)
        var matches: [(url: URL, date: Date)] = []
        for case let url as URL in walker {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
                  Int64(v.fileSize ?? -1) == file.size, let date = v.contentModificationDate,
                  date >= since.addingTimeInterval(-5) || url.lastPathComponent == name else { continue }
            matches.append((url, date))
        }
        return (matches.first { $0.url.lastPathComponent == name } ?? matches.max { $0.date < $1.date })?.url
    }

    private static func downloadsFolder(_ settings: Settings) throws -> URL {
        var path = settings.downloadsFolder
        if path.isEmpty {
            let options = try expect(call("GET", ["options"], settings: settings), 200)
            let json = try? JSONSerialization.jsonObject(with: options) as? [String: Any]
            path = (json?["directories"] as? [String: Any])?["downloads"] as? String ?? ""
        }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard !path.isEmpty, FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw PassableError.message("slskd saves downloads to \(path.isEmpty ? "a folder it didn't name" : path), "
                                        + "which this Mac can't see. Set its downloads folder in Soulseek settings.")
        }
        return url
    }

    // MARK: - slskd's API

    static func base(_ url: String) -> String? {
        let trimmed = url.trimmingCharacters(in: .whitespaces)
        guard let parsed = URL(string: trimmed), let scheme = parsed.scheme, ["http", "https"].contains(scheme),
              parsed.host != nil else { return nil }
        return trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
    }

    /// One request to slskd: path segments are percent-encoded one by one
    /// (a username or id may hold anything); busy (429) is retried.
    private static func call(_ method: String, _ path: [String], query: String? = nil, body: Any? = nil,
                             settings: Settings) throws -> (status: Int, data: Data) {
        guard settings.isConfigured, let base = base(settings.url) else {
            throw PassableError.message("Set up Soulseek first: slskd's address and API key.")
        }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        let encoded = path.map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0 }.joined(separator: "/")
        guard let url = URL(string: base + "/api/v0/" + encoded + (query.map { "?" + $0 } ?? "")) else {
            throw PassableError.message("slskd's address isn't valid.")
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = method
        request.setValue(settings.apiKey.trimmingCharacters(in: .whitespaces), forHTTPHeaderField: "X-API-Key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        for attempt in 0..<4 {
            var reply: Result<(Int, Data), Error> = .failure(PassableError.message("slskd did not answer."))
            let done = DispatchSemaphore(value: 0)
            URLSession.shared.dataTask(with: request) { data, response, error in
                if let error {
                    reply = .failure(error)
                } else {
                    reply = .success(((response as? HTTPURLResponse)?.statusCode ?? 0, data ?? Data()))
                }
                done.signal()
            }.resume()
            done.wait()
            let answer: (Int, Data)
            do {
                answer = try reply.get()
            } catch {
                throw PassableError.message("Couldn't reach slskd at \(base). Is it running? (\(error.localizedDescription))")
            }
            let (status, data) = answer
            if status == 429, attempt < 3 {
                Thread.sleep(forTimeInterval: 1)
                continue
            }
            if status == 401 || status == 403 {
                throw PassableError.message("slskd refused the API key. Check it in Soulseek settings.")
            }
            return (status, data)
        }
        throw PassableError.message("slskd is busy. Try again.")
    }

    @discardableResult
    private static func expect(_ reply: (status: Int, data: Data), _ ok: Int...) throws -> Data {
        guard ok.contains(reply.status) else {
            let detail = String(data: reply.data.prefix(400), encoding: .utf8) ?? ""
            throw PassableError.message("slskd answered \(reply.status). \(detail)")
        }
        return reply.data
    }

    /// slskd's API key, kept in the login keychain.
    private enum Keychain {
        private static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                                   kSecAttrService as String: "com.nikolausmarek.Passable.slskd",
                                                   kSecAttrAccount as String: "api-key"]

        static func read() -> String? {
            var q = query
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }

        static func write(_ key: String) {
            SecItemDelete(query as CFDictionary)
            guard !key.isEmpty else { return }
            var q = query
            q[kSecValueData as String] = Data(key.utf8)
            SecItemAdd(q as CFDictionary, nil)
        }
    }
}
