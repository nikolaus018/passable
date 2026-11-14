using Microsoft.UI.Dispatching;
using Windows.Media;
using Windows.Media.Core;
using Windows.Media.Playback;
using Windows.Storage;
using static PassableWin.Model.PassableMix;

namespace PassableWin.Model;

/// <summary>
/// Plays one mix. The whole set is a single audio file, so playback is gapless and every blend is
/// exactly as rendered on the Mac; this class adds the map on top: which song is playing, where Next
/// and Previous go, and what the media keys and the Windows volume flyout show.
/// </summary>
public sealed class Player : IDisposable
{
    readonly MediaPlayer _media = new() { AutoPlay = false, AudioCategory = MediaPlayerAudioCategory.Media };
    readonly DispatcherQueue _ui = DispatcherQueue.GetForCurrentThread();
    readonly DispatcherQueueTimer _timer;
    readonly StateStore _state;
    SystemMediaTransportControls? _smtc;
    DateTime _lastSaved = DateTime.MinValue;

    public MixItem? Item { get; private set; }
    public bool IsPlaying { get; private set; }
    public double CurrentTime { get; private set; }
    public double Duration { get; private set; }
    /// <summary>The song that's playing.</summary>
    public int SongIndex { get; private set; }
    public bool CanGoNext { get; private set; }
    /// <summary>Next and Previous land a few bars before the blend into a song, never after it.</summary>
    public SkipLanding Landing { get; } = SkipLanding.Lead;

    /// <summary>The mix, the song, or play/pause changed.</summary>
    public event Action? Changed;
    /// <summary>The clock moved (about 20 times a second while playing).</summary>
    public event Action? Ticked;
    public event Action<string>? Error;

    public Player(StateStore state)
    {
        _state = state;
        _timer = _ui.CreateTimer();
        _timer.Interval = TimeSpan.FromMilliseconds(50);
        _timer.Tick += (_, _) => Tick();
        _media.MediaEnded += (_, _) => _ui.TryEnqueue(DidFinish);
        _media.MediaFailed += (_, e) => _ui.TryEnqueue(() => Error?.Invoke("This mix couldn't be played: " + e.ErrorMessage));
        SetUpTransportControls();
    }

    public Manifest? Manifest => Item?.Manifest;
    public Song? CurrentSong => Manifest is { } m && m.Songs.Count > SongIndex ? m.Songs[SongIndex] : null;
    public Song? NextSong => Manifest is { } m && m.Songs.Count > SongIndex + 1 ? m.Songs[SongIndex + 1] : null;

    /// <summary>The blend going on right now, with how far through it is (0...1).</summary>
    public (Transition Transition, double Progress)? Blend =>
        Manifest is { } m && m.TransitionAt(CurrentTime) is { } t && m.TransitionProgress(CurrentTime) is { } p ? (t, p) : null;

    double? NextTarget => Manifest?.NextTarget(CurrentTime, Landing);

    /// <summary>Moves the clock, and what follows from it. True if the song changed.</summary>
    bool SetTime(double time)
    {
        CurrentTime = time;
        var index = Manifest?.SongIndexAt(time) ?? 0;
        var changed = index != SongIndex;
        if (changed) SongIndex = index;
        CanGoNext = NextTarget is not null;
        return changed;
    }

    // MARK: - Loading

    /// <summary>Opens <paramref name="item"/> (resuming where it was left) and, unless told not to, plays.</summary>
    public async Task LoadAsync(MixItem item, bool autoplay = true)
    {
        if (Item?.Id == item.Id)
        {
            if (autoplay && !IsPlaying) Play();
            return;
        }
        SavePosition();
        _timer.Stop();
        try
        {
            var file = await StorageFile.GetFileFromPathAsync(item.AudioPath);
            var opened = new TaskCompletionSource();
            void OnOpened(MediaPlayer s, object a) => opened.TrySetResult();
            void OnFailed(MediaPlayer s, MediaPlayerFailedEventArgs e) => opened.TrySetException(new IOException(e.ErrorMessage));
            _media.MediaOpened += OnOpened;
            _media.MediaFailed += OnFailed;
            try
            {
                _media.Pause();
                _media.Source = MediaSource.CreateFromStorageFile(file);
                await opened.Task.WaitAsync(TimeSpan.FromSeconds(15));
            }
            finally
            {
                _media.MediaOpened -= OnOpened;
                _media.MediaFailed -= OnFailed;
            }

            Item = item;
            IsPlaying = false;
            Duration = _media.PlaybackSession.NaturalDuration.TotalSeconds;
            var saved = _state.PositionOf(item.Id);
            var start = saved > 2 && saved < Duration - 5 ? saved : 0;
            _media.PlaybackSession.Position = TimeSpan.FromSeconds(start);
            SongIndex = 0;
            SetTime(start);
            _state.LastMix = item.Id;
            RefreshNowPlaying();
            Changed?.Invoke();
            Ticked?.Invoke();
            if (autoplay) Play();
        }
        catch (Exception e)
        {
            Error?.Invoke($"This mix couldn't be opened: {e.Message}");
        }
    }

    /// <summary>At launch: have the mix that was playing last ready, paused.</summary>
    public async Task RestoreLastAsync(MixStore store)
    {
        if (Item is not null || _state.LastMix is not { } id) return;
        if (store.Items.FirstOrDefault(i => i.Id == id) is { } found) await LoadAsync(found, autoplay: false);
    }

    /// <summary>The mix is being deleted (or replaced): stop and let go of its file.</summary>
    public void Unload(Guid id)
    {
        if (Item?.Id != id) return;
        _timer.Stop();
        _media.Pause();
        _media.Source = null;
        Item = null;
        IsPlaying = false;
        Duration = 0;
        SongIndex = 0;
        SetTime(0);
        _state.Forget(id);
        if (_smtc is not null) { _smtc.PlaybackStatus = MediaPlaybackStatus.Stopped; _smtc.DisplayUpdater.ClearAll(); _smtc.DisplayUpdater.Update(); }
        Changed?.Invoke();
        Ticked?.Invoke();
    }

    // MARK: - Transport

    public void Play()
    {
        if (Item is null) return;
        if (_media.PlaybackSession.Position.TotalSeconds >= Duration - 0.3) Seek(0);
        _media.Play();
        IsPlaying = true;
        _timer.Start();
        RefreshNowPlaying();
        Changed?.Invoke();
    }

    public void Pause()
    {
        if (Item is null) return;
        _media.Pause();
        IsPlaying = false;
        _timer.Stop();
        SetTime(_media.PlaybackSession.Position.TotalSeconds);
        SavePosition();
        RefreshNowPlaying();
        Changed?.Invoke();
        Ticked?.Invoke();
    }

    public void Toggle() { if (IsPlaying) Pause(); else Play(); }

    public void Seek(double time)
    {
        if (Item is null) return;
        var t = Math.Min(Math.Max(0, time), Math.Max(0, Duration - 0.1));
        _media.PlaybackSession.Position = TimeSpan.FromSeconds(t);
        var changed = SetTime(t);
        RefreshNowPlaying();
        if (changed) Changed?.Invoke();
        Ticked?.Invoke();
    }

    public void Next()
    {
        if (NextTarget is { } t) Seek(t);
    }

    public void Previous()
    {
        if (Manifest is { } m) Seek(m.PreviousTarget(CurrentTime, Landing));
    }

    /// <summary>To a song, from the track list: its lead-in, so its transition plays.</summary>
    public void JumpToSong(int i)
    {
        if (Manifest is not { } m || i < 0 || i >= m.Songs.Count) return;
        Seek(i == 0 ? 0 : m.Landing(i, Landing));
        if (!IsPlaying) Play();
    }

    // MARK: - Keeping time

    void Tick()
    {
        if (!IsPlaying) return;
        var changed = SetTime(_media.PlaybackSession.Position.TotalSeconds);
        if (changed) { RefreshNowPlaying(); Changed?.Invoke(); }
        Ticked?.Invoke();
        if (DateTime.UtcNow - _lastSaved > TimeSpan.FromSeconds(5)) SavePosition();
    }

    public void SavePosition()
    {
        if (Item is null || Duration <= 0) return;
        _lastSaved = DateTime.UtcNow;
        _state.SetPosition(Item.Id, CurrentTime);
    }

    void DidFinish()
    {
        IsPlaying = false;
        _timer.Stop();
        if (Item is not null) _state.SetPosition(Item.Id, 0);
        _media.PlaybackSession.Position = TimeSpan.Zero;
        SongIndex = 0;
        SetTime(0);
        RefreshNowPlaying();
        Changed?.Invoke();
        Ticked?.Invoke();
    }

    // MARK: - Media keys and the volume flyout

    void SetUpTransportControls()
    {
        try
        {
            // Take the controls over from MediaPlayer, so Next/Previous mean songs, not "end of file".
            _media.CommandManager.IsEnabled = false;
            _smtc = _media.SystemMediaTransportControls;
            _smtc.IsEnabled = true;
            _smtc.IsPlayEnabled = _smtc.IsPauseEnabled = true;
            _smtc.IsNextEnabled = _smtc.IsPreviousEnabled = true;
            _smtc.ButtonPressed += (_, e) => _ui.TryEnqueue(() =>
            {
                switch (e.Button)
                {
                    case SystemMediaTransportControlsButton.Play: Play(); break;
                    case SystemMediaTransportControlsButton.Pause: Pause(); break;
                    case SystemMediaTransportControlsButton.Next: Next(); break;
                    case SystemMediaTransportControlsButton.Previous: Previous(); break;
                }
            });
            _smtc.PlaybackPositionChangeRequested += (_, e) => _ui.TryEnqueue(() =>
            {
                if (CurrentSong is { } song) Seek(song.Handover + e.RequestedPlaybackPosition.TotalSeconds);
            });
        }
        catch { _smtc = null; /* media keys are a nicety; playback doesn't depend on them */ }
    }

    /// <summary>Shows the playing *song* (not the whole set), with its own length, so the scrubber there means what it looks like.</summary>
    void RefreshNowPlaying()
    {
        if (_smtc is null) return;
        try
        {
            if (Manifest is not { } m || m.SongAt(CurrentTime) is not { } song)
            {
                _smtc.DisplayUpdater.ClearAll();
                _smtc.DisplayUpdater.Update();
                return;
            }
            var length = Math.Max(1, m.LengthOfSong(song.Index));
            var d = _smtc.DisplayUpdater;
            d.Type = MediaPlaybackType.Music;
            d.MusicProperties.Title = song.Title;
            d.MusicProperties.Artist = song.Artist ?? m.Title;
            d.MusicProperties.AlbumTitle = m.Title;
            d.MusicProperties.TrackNumber = (uint)song.Index + 1;
            d.MusicProperties.AlbumTrackCount = (uint)m.Songs.Count;
            d.Update();
            _smtc.PlaybackStatus = IsPlaying ? MediaPlaybackStatus.Playing : MediaPlaybackStatus.Paused;
            _smtc.IsNextEnabled = CanGoNext;
            var timeline = new SystemMediaTransportControlsTimelineProperties
            {
                StartTime = TimeSpan.Zero,
                MinSeekTime = TimeSpan.Zero,
                EndTime = TimeSpan.FromSeconds(length),
                MaxSeekTime = TimeSpan.FromSeconds(length),
                Position = TimeSpan.FromSeconds(Math.Min(length, Math.Max(0, CurrentTime - song.Handover))),
            };
            _smtc.UpdateTimelineProperties(timeline);
        }
        catch { /* ignore: the system can refuse while shutting down */ }
    }

    public void Dispose()
    {
        _timer.Stop();
        SavePosition();
        _media.Dispose();
    }
}
