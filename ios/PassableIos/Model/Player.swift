import AVFoundation
import MediaPlayer
import Observation
import SwiftUI
import UIKit

/// Plays one mix. The whole set is a single audio file, so playback is
/// gapless and every blend is exactly as rendered on the Mac; this class
/// adds the map on top: which song is playing, where Next and Previous go,
/// and what the lock screen, headphones and Control Center show.
@MainActor @Observable
final class Player {
    private(set) var item: MixStore.Item?
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    var errorMessage: String?
    /// Next and Previous land where a song takes over, not where it starts
    /// to blend in: a skip goes straight to the song.
    private let landing = PassableMix.SkipLanding.handover
    /// The song that's playing. Stored (not worked out from `currentTime`), so
    /// a view that shows the song isn't redrawn on every tick of the clock.
    private(set) var songIndex = 0
    private(set) var canGoNext = false

    @ObservationIgnored private var audio: AVAudioPlayer?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var proxy = DelegateProxy()
    @ObservationIgnored private var lastSaved = Date.distantPast
    @ObservationIgnored private var artworkCache: [String: MPMediaItemArtwork] = [:]
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private static let lastMixKey = "lastMix"
    private static func positionKey(_ id: UUID) -> String { "position.\(id.uuidString)" }

    init() {
        proxy.onFinish = { [weak self] in Task { @MainActor in self?.didFinish() } }
        setUpRemoteCommands()
        observeSystem()
    }

    // MARK: - What's playing

    var manifest: PassableMix.Manifest? { item?.manifest }
    var currentSong: PassableMix.Song? {
        guard let m = manifest, m.songs.indices.contains(songIndex) else { return nil }
        return m.songs[songIndex]
    }
    var nextSong: PassableMix.Song? {
        guard let m = manifest, m.songs.indices.contains(songIndex + 1) else { return nil }
        return m.songs[songIndex + 1]
    }
    /// The blend going on right now, with how far through it is (0...1).
    var blend: (transition: PassableMix.Transition, progress: Double)? {
        guard let m = manifest, let t = m.transition(at: currentTime),
              let p = m.transitionProgress(at: currentTime) else { return nil }
        return (t, p)
    }

    /// Where Next goes from here.
    private var nextTarget: Double? { manifest?.nextTarget(from: currentTime, landing) }

    /// Moves the clock, and what follows from it. True if the song changed.
    @discardableResult
    private func setTime(_ time: Double) -> Bool {
        currentTime = time
        let index = manifest?.songIndex(at: time) ?? 0
        let changed = index != songIndex
        if changed { songIndex = index }
        let next = nextTarget != nil
        if next != canGoNext { canGoNext = next }
        return changed
    }

    // MARK: - Loading

    /// Opens `new` (resuming where it was left) and, unless told not to, plays.
    func load(_ new: MixStore.Item, autoplay: Bool = true) {
        if item?.id == new.id {
            if autoplay, !isPlaying { play() }
            return
        }
        savePosition()
        timer?.invalidate()
        do {
            let player = try AVAudioPlayer(contentsOf: new.audioURL)
            player.delegate = proxy
            player.prepareToPlay()
            audio?.stop()
            audio = player
            item = new
            duration = player.duration
            isPlaying = false
            let saved = UserDefaults.standard.double(forKey: Self.positionKey(new.id))
            let start = (saved > 2 && saved < duration - 5) ? saved : 0
            player.currentTime = start
            setTime(start)
            UserDefaults.standard.set(new.id.uuidString, forKey: Self.lastMixKey)
            refreshNowPlaying()
            if autoplay { play() }
        } catch {
            errorMessage = "This mix couldn't be opened: \(error.localizedDescription)"
        }
    }

    /// At launch: have the mix that was playing last ready, paused.
    func restoreLast(from store: MixStore) {
        guard item == nil, let id = UserDefaults.standard.string(forKey: Self.lastMixKey),
              let found = store.items.first(where: { $0.id.uuidString == id }) else { return }
        load(found, autoplay: false)
    }

    /// The mix is being deleted: stop and forget it.
    func unload(_ id: UUID) {
        guard item?.id == id else { return }
        timer?.invalidate()
        audio?.stop()
        audio = nil
        item = nil
        isPlaying = false
        setTime(0)
        duration = 0
        UserDefaults.standard.removeObject(forKey: Self.positionKey(id))
        UserDefaults.standard.removeObject(forKey: Self.lastMixKey)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    // MARK: - Transport

    func play() {
        guard let audio else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
        if audio.currentTime >= duration - 0.3 { audio.currentTime = 0 }
        audio.play()
        isPlaying = true
        startTimer()
        refreshNowPlaying()
    }

    func pause() {
        guard let audio else { return }
        audio.pause()
        isPlaying = false
        timer?.invalidate()
        setTime(audio.currentTime)
        savePosition()
        refreshNowPlaying()
    }

    func toggle() { isPlaying ? pause() : play() }

    func seek(to time: Double) {
        guard let audio else { return }
        let t = min(max(0, time), max(0, duration - 0.1))
        audio.currentTime = t
        setTime(t)
        refreshNowPlaying()
    }

    func next() {
        guard let t = nextTarget else { return }
        Haptics.tap()
        seek(to: t)
    }

    func previous() {
        guard let m = manifest else { return }
        Haptics.tap()
        seek(to: m.previousTarget(from: currentTime, landing))
    }

    /// Straight to a song, from the track list.
    func jump(toSong i: Int) {
        guard let m = manifest, m.songs.indices.contains(i) else { return }
        Haptics.tap()
        seek(to: i == 0 ? 0 : m.landing(of: i, landing))
        if !isPlaying { play() }
    }

    // MARK: - Keeping time

    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        guard let audio, isPlaying else { return }
        if setTime(audio.currentTime) { refreshNowPlaying() }
        if Date().timeIntervalSince(lastSaved) > 5 { savePosition() }
    }

    private func savePosition() {
        guard let item, duration > 0 else { return }
        lastSaved = Date()
        UserDefaults.standard.set(currentTime, forKey: Self.positionKey(item.id))
    }

    private func didFinish() {
        isPlaying = false
        timer?.invalidate()
        if let item { UserDefaults.standard.removeObject(forKey: Self.positionKey(item.id)) }
        audio?.currentTime = 0
        setTime(0)
        refreshNowPlaying()
    }

    // MARK: - Lock screen, headphones, Control Center

    private func setUpRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.play() }; return .success }
        c.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pause() }; return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.toggle() }; return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.next() }; return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.previous() }; return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in
                guard let self, let song = self.currentSong else { return }
                self.seek(to: song.handover + e.positionTime)
            }
            return .success
        }
        c.skipForwardCommand.isEnabled = false
        c.skipBackwardCommand.isEnabled = false
    }

    /// Shows the playing *song* (not the whole set) on the lock screen, with
    /// its own length, so the scrubber there means what it looks like.
    private func refreshNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        guard let m = manifest, let song = m.song(at: currentTime) else {
            center.nowPlayingInfo = nil
            return
        }
        let length = max(1, m.length(ofSong: song.index))
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: song.title,
            MPMediaItemPropertyArtist: song.artist ?? m.title,
            MPMediaItemPropertyAlbumTitle: m.title,
            MPMediaItemPropertyAlbumTrackNumber: song.index + 1,
            MPMediaItemPropertyAlbumTrackCount: m.songs.count,
            MPMediaItemPropertyPlaybackDuration: length,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: min(length, max(0, currentTime - song.handover)),
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
        ]
        if let art = artwork(for: song) { info[MPMediaItemPropertyArtwork] = art }
        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused
    }

    private func artwork(for song: PassableMix.Song) -> MPMediaItemArtwork? {
        if let cached = artworkCache[song.artworkSeed] { return cached }
        let renderer = ImageRenderer(content: ArtworkView(seed: song.artworkSeed).frame(width: 600, height: 600))
        renderer.scale = 1
        guard let image = renderer.uiImage else { return nil }
        let art = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        if artworkCache.count > 40 { artworkCache.removeAll() }
        artworkCache[song.artworkSeed] = art
        return art
    }

    private func observeSystem() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init)
            Task { @MainActor in
                guard let self else { return }
                if type == .began {
                    self.audio?.pause()
                    self.isPlaying = false
                    self.timer?.invalidate()
                    self.savePosition()
                    self.refreshNowPlaying()
                } else if type == .ended, options?.contains(.shouldResume) == true {
                    self.play()
                }
            }
        })
        // Headphones pulled out: stop, don't blast the speaker.
        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init)
            Task { @MainActor in
                if reason == .oldDeviceUnavailable { self?.pause() }
            }
        })
        observers.append(nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.savePosition() }
        })
    }
}

/// `AVAudioPlayer` wants an `NSObject` delegate.
private final class DelegateProxy: NSObject, AVAudioPlayerDelegate {
    var onFinish: (() -> Void)?
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { onFinish?() }
}

extension PassableMix.Song {
    /// What the cover art is made from.
    var artworkSeed: String { "\(artist ?? "")|\(title)" }
}
