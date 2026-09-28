import SwiftUI

/// Find songs on YouTube Music and YouTube (yt-dlp), or lossless files on
/// Soulseek (through slskd), and add them to the set. Downloads run in the
/// background, several at once, and land in ~/Music/Passable; a song
/// downloaded before is added straight away.
struct SearchSheet: View {
    @EnvironmentObject private var set: SetSession
    @Environment(\.dismiss) private var dismiss

    private enum RowState: Equatable {
        case downloading
        case failed(String)
    }

    @State private var query = ""
    @State private var results: [MusicSearchResult] = []
    @State private var isSearching = false
    @State private var message: String?
    @State private var states: [String: RowState] = [:]
    @AppStorage("SearchSource") private var source: MusicSource = .youtube
    @State private var soulseek = Soulseek.Settings.current
    @State private var showSettings = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Find Songs Online").font(.title3.bold())
                    Text(source == .youtube
                         ? "Search YouTube Music and add songs to your set. Downloads are saved to ~/Music/Passable."
                         : "Lossless files (FLAC, WAV, AIFF) and 320 kbps MP3s shared on Soulseek, through slskd. "
                           + "Downloads are saved to ~/Music/Passable.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Picker("", selection: $source) {
                    ForEach(MusicSource.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 170)
                .onChange(of: source) { _, _ in
                    results = []
                    message = nil
                    showSettings = false
                }
                if source == .soulseek {
                    Button {
                        showSettings.toggle()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .help("Soulseek settings")
                }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack {
                TextField("Artist and song title", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .focused($fieldFocused)
                    .onSubmit(search)
                Button("Search", action: search)
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || isSearching)
                    .keyboardShortcut(.defaultAction)
            }
            content
        }
        .padding(16)
        .frame(width: 620, height: 520)
        .onAppear { fieldFocused = true }
    }

    @ViewBuilder private var content: some View {
        if source == .soulseek && (showSettings || !soulseek.isConfigured) {
            soulseekSettings
        } else if isSearching {
            centered { ProgressView("Searching…") }
        } else if let message {
            centered { Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center) }
        } else if results.isEmpty {
            centered {
                VStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 28)).foregroundStyle(.secondary)
                    Text("Type a song and press Return.").foregroundStyle(.secondary)
                }
            }
        } else {
            List(results) { result in
                row(result)
            }
            .listStyle(.inset)
        }
    }

    /// Where slskd listens and its API key. slskd itself holds the
    /// Soulseek account.
    private var soulseekSettings: some View {
        Form {
            Section {
                TextField("slskd address", text: $soulseek.url, prompt: Text(Soulseek.Settings.defaultURL))
                SecureField("API key", text: $soulseek.apiKey)
                TextField("Downloads folder", text: $soulseek.downloadsFolder, prompt: Text("Ask slskd"))
            } footer: {
                Text("""
                    Soulseek needs slskd running on this Mac with your Soulseek account. Download it from \
                    github.com/slskd/slskd/releases and start it with an API key of your own (16 characters or more):
                    slskd --slsk-username NAME --slsk-password PASSWORD --api-key KEY
                    Leave the downloads folder empty unless slskd runs in Docker: then give the folder its downloads \
                    are mounted from.
                    """)
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Save") {
                    Soulseek.Settings.current = soulseek
                    soulseek = Soulseek.Settings.current
                    showSettings = false
                    fieldFocused = true
                }
                .disabled(!soulseek.isConfigured)
            }
        }
        .formStyle(.grouped)
    }

    private func centered<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        content().frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ result: MusicSearchResult) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(SongTitle.clean(result.title)).lineLimit(1)
                Text(([result.artist, result.album, result.duration.map { Theme.time($0) }]
                        + (result.soulseek.map { [result.quality, $0.username] }
                           ?? [result.isOfficialAudio ? nil : "YouTube video"])).compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            trailing(result)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private func trailing(_ result: MusicSearchResult) -> some View {
        if isInSet(result) {
            Label("In set", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.secondary)
        } else if states[result.id] == .downloading {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Downloading…").font(.caption).foregroundStyle(.secondary)
            }
        } else if case .failed(let error) = states[result.id] {
            Button("Retry") { add(result) }
                .help(error)
                .foregroundStyle(.red)
        } else {
            Button {
                add(result)
            } label: {
                Label("Add", systemImage: "plus")
            }
        }
    }

    // MARK: - Actions

    /// A download is recognised by the id in its name: the video's, or a
    /// Soulseek file's token.
    private func downloadedFile(_ result: MusicSearchResult) -> URL? {
        MusicTools.libraryFiles().first { $0.lastPathComponent.contains("[\(result.id)]") }
    }

    private func isInSet(_ result: MusicSearchResult) -> Bool {
        set.items.contains { $0.url.lastPathComponent.contains("[\(result.id)]") }
    }

    private func search() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isSearching else { return }
        isSearching = true
        message = nil
        results = []
        let from = source, soulseek = soulseek
        Task.detached(priority: .userInitiated) {
            let result = Result<[MusicSearchResult], Error> {
                if from == .soulseek { return try Soulseek.search(q, settings: soulseek) }
                return try MusicTools.search(q)
            }
            await MainActor.run {
                isSearching = false
                // Switched source while it searched: not these results.
                guard source == from else { return }
                switch result {
                case .success(let found):
                    results = found
                    if found.isEmpty {
                        message = from == .soulseek
                            ? "Nothing lossless or 320 kbps found. Try the artist and title, or YouTube."
                            : "Nothing found. Try the artist and title."
                    }
                case .failure(let error):
                    message = error.localizedDescription
                }
            }
        }
    }

    private func add(_ result: MusicSearchResult) {
        if let file = downloadedFile(result) {
            set.add([file])
            return
        }
        states[result.id] = .downloading
        Task.detached(priority: .userInitiated) {
            let outcome = Result { try MusicTools.download(result) }
            await MainActor.run {
                switch outcome {
                case .success(let url):
                    states[result.id] = nil
                    set.add([url])
                case .failure(let error):
                    states[result.id] = .failed(error.localizedDescription)
                }
            }
        }
    }
}
