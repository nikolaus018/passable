import XCTest
@testable import Passable

/// Picking files from slskd's search responses: no network.
final class SoulseekTests: XCTestCase {
    private func response(_ user: String, free: Bool = true, queue: Int = 0, _ files: [[String: Any]]) -> [String: Any] {
        ["username": user, "files": files, "hasFreeUploadSlot": free, "queueLength": queue, "uploadSpeed": 2_000_000,
         "fileCount": files.count, "lockedFileCount": 0, "lockedFiles": [], "token": 1]
    }

    private func file(_ name: String, size: Int = 30_000_000, bitRate: Int? = nil, depth: Int? = nil,
                      rate: Int? = nil, length: Int? = 215) -> [String: Any] {
        var f: [String: Any] = ["filename": name, "size": size, "code": 1, "extension": "", "isLocked": false]
        if let bitRate { f["bitRate"] = bitRate }
        if let depth { f["bitDepth"] = depth }
        if let rate { f["sampleRate"] = rate }
        if let length { f["length"] = length }
        return f
    }

    func testLosslessFirstThen320AndNothingWorseThanYouTube() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            response("slow", free: false, queue: 50, [
                file(#"Music\Daft Punk - Discovery (2001)\03 - Daft Punk - Digital Love.flac"#, depth: 16, rate: 44100),
            ]),
            response("fast", [
                file(#"Music\Daft Punk - Discovery (2001)\03 - Daft Punk - Digital Love.flac"#, depth: 16, rate: 44100),
                file(#"mp3\Daft Punk\Digital Love.mp3"#, size: 8_000_000, bitRate: 320),
                file(#"mp3\Daft Punk\Digital Love (128).mp3"#, size: 3_000_000, bitRate: 128),
                file(#"Daft Punk\Digital Love.ogg"#, size: 5_000_000),
                file(#"Daft Punk\Digital Love (Live).wav"#, size: 40_000_000),
                file(#"Daft Punk\Digital Love snippet.flac"#, size: 1_000_000, length: 30),
                file(#"Daft Punk\One More Time.flac"#, size: 31_000_000),
            ]),
        ])
        let results = Soulseek.results(data, query: "daft punk digital love")
        XCTAssertEqual(results.map { $0.soulseek!.filename.components(separatedBy: #"\"#).last! }, [
            "03 - Daft Punk - Digital Love.flac", "Digital Love.mp3", "Digital Love (Live).wav",
        ])
        let top = results[0]
        XCTAssertEqual(top.soulseek?.username, "fast", "the same file from whoever can send it now")
        XCTAssertEqual(top.title, "Digital Love")
        XCTAssertEqual(top.artist, "Daft Punk")
        XCTAssertEqual(top.album, "Daft Punk - Discovery (2001)")
        XCTAssertEqual(top.quality, "FLAC 16/44.1")
        XCTAssertEqual(top.duration, 215)
        XCTAssertEqual(results[1].quality, "MP3 320")
    }

    func testNamesFromPaths() {
        XCTAssertEqual(Soulseek.parse(#"A\Artist - Album\01. Title.flac"#).title, "Title")
        XCTAssertEqual(Soulseek.parse(#"A\Artist - Album\01. Title.flac"#).artist, "Artist")
        XCTAssertEqual(Soulseek.parse("x/2 Chainz - Birthday Song.mp3").artist, "2 Chainz")
        XCTAssertEqual(Soulseek.parse("x/12 Song Name.wav").title, "Song Name")
        XCTAssertNil(Soulseek.parse("Song.flac").artist)
    }

    /// A file's token is stable, eleven characters like a video id, so a
    /// download is found again by name and cleaned out of its title.
    func testTokenLooksLikeAVideoID() {
        let token = Soulseek.token("user\u{0}path\\song.flac")
        XCTAssertEqual(token.count, 11)
        XCTAssertEqual(token, Soulseek.token("user\u{0}path\\song.flac"))
        XCTAssertNotEqual(token, Soulseek.token("user\u{0}path\\song2.flac"))
        XCTAssertEqual(SongTitle.clean("Artist - Title [\(token)]"), "Artist - Title")
    }

    func testFindsTheFinishedFileBySize() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Album"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let since = Date()
        let other = dir.appendingPathComponent("Album/other.flac"), mine = dir.appendingPathComponent("Album/03 Song.flac")
        try Data(count: 10).write(to: other)
        try Data(count: 12).write(to: mine)
        let shared = SoulseekFile(username: "u", filename: #"Music\Album\03 Song.flac"#, size: 12)
        XCTAssertEqual(Soulseek.finished(shared, in: dir, since: since)?.lastPathComponent, "03 Song.flac")
        XCTAssertNil(Soulseek.finished(SoulseekFile(username: "u", filename: "x.flac", size: 99), in: dir, since: since))
    }
}
