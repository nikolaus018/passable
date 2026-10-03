import AVFoundation
import Foundation
import NaturalLanguage
import Speech

/// One line of a song's vocal, as sung: a sentence, or what's sung between
/// two breaths. Where a DJ takes a voice out or lets one in is between two
/// of these, and the level of a vocal stem alone can't find them: backing
/// voices, ad-libs and reverb fill the gaps, and a rapper leaves none.
struct VocalLine: Codable, Equatable {
    /// Seconds of the song.
    var start: Double, end: Double
    var words: Int
    /// How many other lines of the song say the same (a chorus comes back;
    /// a verse doesn't). The words themselves aren't kept.
    var repeats: Int
    /// Where the line pauses inside (seconds): its commas. The recogniser
    /// writes two lines of a lyric as one sentence as often as not; a
    /// voice can be cut at these as well as at the line's ends.
    var breaks: [Double] = []
}

extension VocalLine {
    /// Lines kept before their pauses were have none.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        start = try c.decode(Double.self, forKey: .start)
        end = try c.decode(Double.self, forKey: .end)
        words = try c.decode(Int.self, forKey: .words)
        repeats = try c.decode(Int.self, forKey: .repeats)
        breaks = try c.decodeIfPresent([Double].self, forKey: .breaks) ?? []
    }
}

/// The lines of a song, heard in its vocal stem by the system's on-device
/// speech recogniser (macOS 26; nothing leaves the Mac). It gets many words
/// of a sung vocal wrong, but not where they start and stop, where a
/// sentence ends, or that a line comes back.
enum Lyrics {
    struct Heard {
        var lines: [VocalLine]
        /// The language they were heard in.
        var locale: String
    }

    /// What listening to a song came to: its lines, none (it has no words
    /// in a language on the Mac), or nothing to go by (the recogniser
    /// failed: the song is listened to again next time).
    enum Outcome {
        case heard(Heard), none, failed
    }

    /// The languages tried, in this order, where their models are on the
    /// Mac (macOS installs them with dictation; the app asks for none).
    static let locales = ["en-US", "de-DE"]

    /// Off for a run that shouldn't wait for it (unit tests of the loader).
    nonisolated(unsafe) static var isEnabled = true

    /// Which of `locales` can be transcribed now, as one string: what an
    /// analysis without lyrics remembers having tried.
    static func available() -> String {
        guard isEnabled, #available(macOS 26.0, *) else { return "" }
        let languages = blocking { await installed().joined(separator: ",") } ?? ""
        return languages.isEmpty ? "" : "\(version)|\(languages)"
    }

    /// Bumped when lines are made differently, so songs are heard again.
    private static let version = 13

    /// The song's lines; nil if no installed language hears words in it
    /// (an instrumental, a language without its model) or there's no
    /// recogniser at all.
    static func lines(vocals: StemAudio) -> Heard? {
        if case .heard(let heard) = listen(vocals: vocals) { return heard }
        return nil
    }

    static func listen(vocals: StemAudio) -> Outcome {
        guard isEnabled, #available(macOS 26.0, *) else { return .failed }
        return heard(vocals) ?? .failed
    }

    @available(macOS 26.0, *)
    private static func heard(_ vocals: StemAudio) -> Outcome? {
        let sr = AudioIO.sampleRate
        let n = vocals.count
        guard n > Int(10 * sr) else { return Outcome.none }
        var mono = [Float](repeating: 0, count: n)
        for i in 0..<n { mono[i] = 0.5 * (vocals.left.pointer[i] + vocals.right.pointer[i]) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("passable-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { return .failed }
        buffer.frameLength = AVAudioFrameCount(n)
        mono.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: n) }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        } catch { return .failed }

        // The language the song is in. A recogniser for another language
        // than English writes an English song down in English words, and a
        // song in its own language in that language: what its words read
        // as says which the song is (the English one writes everything in
        // English words, and Rihanna's "oh na na" reads as German). Each
        // other language is tried first; English if none of them is it.
        // A language the recogniser doesn't have at all comes out as stray
        // words it has little faith in (German heard as English: a
        // confidence of 0.1 to 0.2; English, sung or rapped, sparse or
        // dense: 0.4 to 0.8).
        let candidates = blocking({ await installed() }) ?? []
        let english = candidates.filter { $0.hasPrefix("en") }, others = candidates.filter { !$0.hasPrefix("en") }
        var best: (words: [Word], locale: String, confidence: Double)?
        for locale in others + english {
            guard let words = blocking({ await transcribe(url, locale: locale) }) else { return .failed }
            let confidence = words.reduce(0) { $0 + $1.confidence } / Double(max(1, words.count))
            if !locale.hasPrefix("en") {
                guard words.count >= minimumWords, reads(words, as: locale, among: candidates) else { continue }
            }
            best = (words, locale, confidence)
            break
        }
        guard let best, best.words.count >= minimumWords, best.confidence >= minimumConfidence else { return Outcome.none }
        return .heard(Heard(lines: lines(from: best.words), locale: best.locale))
    }

    /// Whether words read as the language of `locale` (of the languages
    /// tried). With one language there's nothing to tell apart.
    static func reads(_ words: [Word], as locale: String, among locales: [String]) -> Bool {
        guard locales.count > 1 else { return true }
        let recogniser = NLLanguageRecognizer()
        recogniser.languageConstraints = locales.map { NLLanguage(String($0.prefix(2))) }
        recogniser.processString(words.map(\.text).joined(separator: " "))
        return recogniser.dominantLanguage == NLLanguage(String(locale.prefix(2)))
    }

    /// The recogniser's mean confidence in its words (0…1) under which a
    /// transcript isn't one, and the fewest words that make one.
    static let minimumConfidence = 0.3
    static let minimumWords = 30

    struct Word {
        var start: Double, end: Double
        var text: String
        var confidence = 1.0
    }

    /// Words into lines: a line ends where a sentence does, or where the
    /// voice stops for a moment, and never runs longer than a couple of
    /// bars' worth of words. Each then counts the lines that say the same.
    static func lines(from words: [Word]) -> [VocalLine] {
        var lines: [(start: Double, end: Double, tokens: [String], breaks: [Double])] = []
        var current: [Word] = [], breaks: [Double] = []
        for (i, word) in words.enumerated() {
            current.append(word)
            let next = i + 1 < words.count ? words[i + 1] : nil
            let ended = word.text.last.map { ".?!".contains($0) } ?? false
            let paused = next.map { $0.start - word.end > 0.45 } ?? true
            let comma = word.text.last.map { ",;:".contains($0) } ?? false
            let long = current.count >= 14 && comma
            if ended || paused || long {
                lines.append((current[0].start, word.end, current.flatMap { tokens($0.text) }, breaks))
                (current, breaks) = ([], [])
            } else if comma {
                breaks.append(word.end)
            }
        }
        // Where each run of three words is sung: a line comes back as
        // often as most of its runs are sung again elsewhere (eight
        // seconds away or more). Runs, not whole lines: the recogniser
        // cuts a chorus into lines differently each time round.
        var sung: [[String]: [Double]] = [:]
        for line in lines where line.tokens.count >= 3 {
            for k in 0...(line.tokens.count - 3) { sung[Array(line.tokens[k..<(k + 3)]), default: []].append(line.start) }
        }
        return lines.indices.map { i in
            let tokens = lines[i].tokens
            var repeats = lines.indices.filter { j in
                j != i && abs(lines[j].start - lines[i].start) > 8 && same(tokens, lines[j].tokens)
            }.count
            if tokens.count >= 3 {
                let again = (0...(tokens.count - 3)).map { k in
                    Set((sung[Array(tokens[k..<(k + 3)])] ?? []).filter { abs($0 - lines[i].start) > 8 }.map { Int($0) }).count
                }.sorted()
                repeats = max(repeats, again[again.count / 2])
            }
            return VocalLine(start: lines[i].start, end: lines[i].end, words: lines[i].tokens.count, repeats: repeats,
                             breaks: lines[i].breaks)
        }
    }

    private static func tokens(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// Two lines say the same: most of their words are shared (the
    /// recogniser hears "my whistle" as "mine whistle" the next time).
    private static func same(_ a: [String], _ b: [String]) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        if min(a.count, b.count) < 3 { return a == b }
        let x = Set(a), y = Set(b)
        return Double(x.intersection(y).count) / Double(x.union(y).count) >= 0.6
    }

    private final class Box<T>: @unchecked Sendable { var value: T? }

    /// Runs `work` and waits for it. Only ever called off the main thread
    /// (analysis has its own queue).
    private static func blocking<T>(_ work: @escaping @Sendable () async -> T?) -> T? {
        let box = Box<T>()
        let done = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            box.value = await work()
            done.signal()
        }
        done.wait()
        return box.value
    }

    @available(macOS 26.0, *)
    private static func installed() async -> [String] {
        guard SpeechTranscriber.isAvailable else { return [] }
        let installed = Set(await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) })
        return locales.filter { installed.contains($0) }
    }

    @available(macOS 26.0, *)
    private static func transcribe(_ url: URL, locale: String) async -> [Word]? {
        do {
            let language = Locale(identifier: locale)
            // (The recogniser wants its language reserved for the app.)
            if !(await AssetInventory.reservedLocales).contains(where: { $0.identifier(.bcp47) == locale }) {
                try await AssetInventory.reserve(locale: language)
            }
            let transcriber = SpeechTranscriber(locale: language, transcriptionOptions: [],
                                                reportingOptions: [],
                                                attributeOptions: [.audioTimeRange, .transcriptionConfidence])
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let file = try AVAudioFile(forReading: url)
            let collecting = Task { () -> [Word] in
                var words: [Word] = []
                for try await result in transcriber.results {
                    for run in result.text.runs {
                        guard let range = run.audioTimeRange else { continue }
                        let text = String(result.text[run.range].characters).trimmingCharacters(in: .whitespaces)
                        guard !text.isEmpty else { continue }
                        words.append(Word(start: range.start.seconds, end: range.end.seconds, text: text,
                                          confidence: run.transcriptionConfidence ?? 0))
                    }
                }
                return words
            }
            if let last = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
            return try await collecting.value
        } catch {
            return nil
        }
    }
}
