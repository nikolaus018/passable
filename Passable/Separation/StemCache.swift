import CryptoKit
import Foundation

/// On-disk home for everything derived from one source file: its four stems,
/// its analysis, and any tempo/pitch-matched renditions of the stems.
///
/// Keyed by path, size and modification date, so re-importing an unchanged
/// file skips the minute of separation, while editing it invalidates the cache.
enum StemCache {
    /// Bump when the model or the stem format changes.
    private static let version = 1

    static let root: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("Passable/tracks", isDirectory: true)
    }()

    static func directory(for url: URL) throws -> URL {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let identity = "\(version)|\(url.standardizedFileURL.path)|\(values.fileSize ?? 0)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        let digest = SHA256.hash(data: Data(identity.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        let dir = root.appendingPathComponent(digest, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func hasStems(in directory: URL) -> Bool {
        StemKind.allCases.allSatisfy { StemAudio.exists(directory: directory, name: $0.rawValue) }
    }

    static func loadStems(from directory: URL) throws -> [StemKind: StemAudio] {
        var stems: [StemKind: StemAudio] = [:]
        for kind in StemKind.allCases {
            stems[kind] = try StemAudio.load(directory: directory, name: kind.rawValue)
        }
        return stems
    }

    /// Tempo-matched stems from before matching was sample-exact.
    static func removeLegacyMatches(in directory: URL) {
        let items = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for item in items where item.lastPathComponent.hasPrefix("matched-") {
            try? FileManager.default.removeItem(at: item)
        }
    }

    static func loadAnalysis(from directory: URL) -> TrackAnalysis? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("analysis.json")) else { return nil }
        return try? JSONDecoder().decode(TrackAnalysis.self, from: data)
    }

    static func saveAnalysis(_ analysis: TrackAnalysis, to directory: URL) {
        guard let data = try? JSONEncoder().encode(analysis) else { return }
        try? data.write(to: directory.appendingPathComponent("analysis.json"), options: .atomic)
    }
}
