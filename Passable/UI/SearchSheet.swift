import SwiftUI

/// Find a track online (yt-dlp) or pick one already downloaded to
/// ~/Music/Passable, and hand it to a deck or a set.
struct SearchSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let pickLabel: String
    /// Stay open after a pick, for adding several songs to a set.
    var keepOpen = false
    let onPick: @MainActor (URL) -> Void
    @State private var picked: Set<URL> = []

    @State private var query = ""
    @State private var results: [MusicSearchResult] = []
    @State private var library: [URL] = MusicTools.libraryFiles()
    @State private var isSearching = false
    @State private var downloadingID: String?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.title3.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack {
                TextField("Artist or title", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(search)
                Button("Search", action: search)
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || isSearching)
                    .keyboardShortcut(.defaultAction)
            }
            if isSearching {
                HStack { ProgressView().controlSize(.small); Text("Searching…").foregroundStyle(.secondary) }
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(4)
            }

            List {
                if !results.isEmpty {
                    Section("Results") {
                        ForEach(results) { result in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(result.title).lineLimit(1)
                                    Text([result.uploader, result.duration.map { Theme.time($0) }].compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if downloadingID == result.id {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Button("Download & \(pickLabel)") { download(result) }
                                        .disabled(downloadingID != nil)
                                }
                            }
                        }
                    }
                }
                Section("In ~/Music/Passable") {
                    if library.isEmpty {
                        Text("Nothing downloaded yet.").foregroundStyle(.secondary)
                    }
                    ForEach(library, id: \.self) { url in
                        HStack {
                            Text(url.deletingPathExtension().lastPathComponent).lineLimit(1)
                            Spacer()
                            if picked.contains(url) {
                                Label("Added", systemImage: "checkmark").foregroundStyle(.secondary)
                            } else {
                                Button(pickLabel) { pick(url) }
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
        .padding(16)
        .frame(width: 620, height: 520)
    }

    private func pick(_ url: URL) {
        onPick(url)
        picked.insert(url)
        if !keepOpen { dismiss() }
    }

    private func search() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isSearching else { return }
        isSearching = true
        message = nil
        results = []
        Task.detached(priority: .userInitiated) {
            let result = Result { try MusicTools.search(q) }
            await MainActor.run {
                isSearching = false
                switch result {
                case .success(let found):
                    results = found
                    if found.isEmpty { message = "No results. Try another artist or title." }
                case .failure(let error):
                    message = error.localizedDescription
                }
            }
        }
    }

    private func download(_ result: MusicSearchResult) {
        downloadingID = result.id
        message = "Downloading and converting to WAV…"
        Task.detached(priority: .userInitiated) {
            let outcome = Result { try MusicTools.download(result) }
            await MainActor.run {
                downloadingID = nil
                switch outcome {
                case .success(let url):
                    library = MusicTools.libraryFiles()
                    pick(url)
                    if keepOpen { message = "Added \(url.deletingPathExtension().lastPathComponent)." }
                case .failure(let error):
                    message = error.localizedDescription
                }
            }
        }
    }
}
