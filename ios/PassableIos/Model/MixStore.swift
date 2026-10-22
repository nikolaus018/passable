import AVFoundation
import Foundation
import Observation

/// The mixes on this phone: one folder each (`manifest.json`, the audio, and
/// the cached waveform), under Application Support.
@MainActor @Observable
final class MixStore {
    struct Item: Identifiable, Equatable {
        let manifest: PassableMix.Manifest
        let folder: URL
        /// Loudness outline; nil until it has been worked out.
        var peaks: [Float]?

        var id: UUID { manifest.id }
        var audioURL: URL { folder.appendingPathComponent("audio.\(manifest.audio.fileExtension)") }
        var songCount: Int { manifest.songs.count }

        static func == (a: Item, b: Item) -> Bool { a.id == b.id && a.peaks?.count == b.peaks?.count }
    }

    /// A file being unpacked right now (shown as a placeholder row).
    struct Incoming: Identifiable, Equatable {
        let id = UUID()
        var name: String
        var progress: Double
    }

    private(set) var items: [Item] = []
    private(set) var incoming: [Incoming] = []
    /// What went wrong with the last import, for an alert.
    var errorMessage: String?

    private let root: URL

    init(root: URL? = nil) {
        self.root = root ?? URL.applicationSupportDirectory.appendingPathComponent("Mixes", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        load()
    }

    // MARK: - Reading what's there

    private func load() {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        var found: [Item] = []
        for folder in folders {
            guard let manifest = Self.readManifest(in: folder) else {
                // Leftovers of an import that never finished.
                if folder.lastPathComponent.hasPrefix("incoming-") { try? FileManager.default.removeItem(at: folder) }
                continue
            }
            var item = Item(manifest: manifest, folder: folder)
            if let data = try? Data(contentsOf: folder.appendingPathComponent("peaks.bin")) {
                item.peaks = Waveform.decode(data)
            }
            found.append(item)
        }
        items = found.sorted { $0.manifest.created > $1.manifest.created }
        for item in items where item.peaks == nil { computePeaks(for: item) }
    }

    nonisolated private static func readManifest(in folder: URL) -> PassableMix.Manifest? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PassableMix.Manifest.self, from: data)
    }

    // MARK: - Importing

    /// Takes a `.passablemix` (from AirDrop, Files, or the Mac over Wi-Fi) into
    /// the library. `moveFile`: the file is ours to move (a received file in
    /// the temp folder), not the user's.
    func importMix(from source: URL, moveFile: Bool = false) {
        let job = Incoming(name: source.deletingPathExtension().lastPathComponent, progress: 0)
        incoming.append(job)
        let root = self.root
        Task.detached(priority: .userInitiated) { [weak self] in
            let scoped = source.startAccessingSecurityScopedResource()
            defer {
                if scoped { source.stopAccessingSecurityScopedResource() }
                if moveFile { try? FileManager.default.removeItem(at: source) }
            }
            do {
                let item = try Self.unpack(source, into: root) { p in
                    Task { @MainActor in self?.setProgress(p, for: job.id) }
                }
                await self?.finishImport(job.id, item: item)
            } catch {
                await self?.failImport(job.id, error: error)
            }
        }
    }

    nonisolated private static func unpack(_ source: URL, into root: URL,
                                           progress: @escaping (Double) -> Void) throws -> Item {
        let fm = FileManager.default
        let manifest = try PassableMix.readManifest(from: source)
        let staging = root.appendingPathComponent("incoming-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            let audio = staging.appendingPathComponent("audio.\(manifest.audio.fileExtension)")
            let full = try PassableMix.extract(from: source, audioTo: audio, progress: progress)

            // Don't keep a mix the phone can't play.
            let duration = (try? AVAudioPlayer(contentsOf: audio))?.duration ?? 0
            guard duration > 1 else { throw PassableMix.FileError.noAudio }

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(full).write(to: staging.appendingPathComponent("manifest.json"))
            var url = audio
            var values = URLResourceValues()
            values.isExcludedFromBackup = true   // it can be sent again from the Mac
            try? url.setResourceValues(values)

            let final = root.appendingPathComponent(full.id.uuidString, isDirectory: true)
            if fm.fileExists(atPath: final.path) { try fm.removeItem(at: final) }
            try fm.moveItem(at: staging, to: final)
            return Item(manifest: full, folder: final)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    private func setProgress(_ p: Double, for id: UUID) {
        guard let i = incoming.firstIndex(where: { $0.id == id }) else { return }
        incoming[i].progress = p
    }

    private func finishImport(_ id: UUID, item: Item) {
        incoming.removeAll { $0.id == id }
        items.removeAll { $0.id == item.id }
        items.insert(item, at: 0)
        computePeaks(for: item)
    }

    private func failImport(_ id: UUID, error: Error) {
        incoming.removeAll { $0.id == id }
        errorMessage = error.localizedDescription
    }

    private func computePeaks(for item: Item) {
        let audio = item.audioURL, folder = item.folder, id = item.id
        Task.detached(priority: .utility) { [weak self] in
            guard let peaks = try? Waveform.peaks(of: audio), !peaks.isEmpty else { return }
            try? Waveform.encode(peaks).write(to: folder.appendingPathComponent("peaks.bin"))
            await self?.setPeaks(peaks, for: id)
        }
    }

    private func setPeaks(_ peaks: [Float], for id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].peaks = peaks
    }

    // MARK: - Removing

    func delete(_ item: Item) {
        items.removeAll { $0.id == item.id }
        try? FileManager.default.removeItem(at: item.folder)
    }

    var totalBytes: Int { items.reduce(0) { $0 + $1.manifest.audio.size } }
}
