import Foundation

/// Turns a planned set into the map the phone plays from (see `PassableMix`).
enum PhoneMix {
    /// `titles` are the songs' names in set order. Times are master seconds,
    /// which are also seconds into the rendered file (it starts at 0).
    static func manifest(for mix: SetMix, titles: [String], title: String) -> PassableMix.Manifest {
        let length = mix.length
        var songs: [PassableMix.Song] = []
        var previousHandover = 0.0
        for (i, track) in mix.tracks.enumerated() {
            let into = mix.transitions.first { $0.to == i }
            let outOf = mix.transitions.first { $0.from == i }

            // Keep every time inside the set and in order, whatever the plan did.
            func clamp(_ t: Double, from low: Double = 0) -> Double { min(length, max(low, t)) }
            let handover = clamp(into?.start ?? 0, from: previousHandover)
            let start = min(handover, clamp(into?.begins ?? 0))
            let solo = clamp(into?.end ?? 0, from: handover)
            let end = clamp(outOf?.end ?? length, from: solo)
            previousHandover = handover

            let name = i < titles.count ? titles[i] : "Song \(i + 1)"
            let (artist, song) = split(name)
            let analysis = track.loaded.analysis
            songs.append(.init(index: i, title: song, artist: artist,
                               start: start, handover: handover, solo: solo, end: end,
                               bpm: analysis.grid.bpm.rounded(),
                               key: analysis.key.camelotCode))
        }

        let transitions = mix.transitions.map { t in
            PassableMix.Transition(from: t.from, to: t.to,
                                   begins: min(length, max(0, t.begins)), handover: min(length, max(0, t.start)),
                                   end: min(length, max(0, t.end)),
                                   style: t.edit.preset.displayName, notes: t.payoff)
        }

        return PassableMix.Manifest(
            title: title,
            created: Date(),
            source: "Passable on \(Host.current().localizedName ?? "a Mac")",
            duration: length,
            audio: .init(size: 0),
            songs: songs,
            transitions: transitions)
    }

    /// "Artist - Title" (how most downloads are named) into its two parts.
    static func split(_ name: String) -> (artist: String?, title: String) {
        for separator in [" - ", " – ", " — "] {
            let parts = name.components(separatedBy: separator)
            if parts.count >= 2 {
                let artist = parts[0].trimmingCharacters(in: .whitespaces)
                let title = parts.dropFirst().joined(separator: separator).trimmingCharacters(in: .whitespaces)
                if !artist.isEmpty, !title.isEmpty { return (artist, title) }
            }
        }
        return (nil, name)
    }

    static func suggestedTitle(date: Date = Date()) -> String {
        "Set · \(date.formatted(.dateTime.month(.abbreviated).day()))"
    }

    static func suggestedFileName(_ title: String) -> String {
        let safe = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return "\(safe).\(PassableMix.fileExtension)"
    }
}
