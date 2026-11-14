using System.ComponentModel;
using Microsoft.UI;
using Microsoft.UI.Input;
using Microsoft.UI.Text;
using Path = System.IO.Path;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using PassableWin.Model;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;
using Windows.Storage.Pickers;
using Windows.System;
using WinRT.Interop;

namespace PassableWin;

/// <summary>One line of the track list.</summary>
public sealed class TrackRow(PassableMix.Manifest m, PassableMix.Song song) : INotifyPropertyChanged
{
    public int Index { get; } = song.Index;
    public string Number { get; } = (song.Index + 1).ToString();
    public string Title { get; } = song.Title;
    public string Length { get; } = Theme.Clock(m.LengthOfSong(song.Index));
    public Brush Deck { get; } = Theme.Deck(song.Index).Brush;

    /// <summary>Artist, then the blend into it: its type and length.</summary>
    public string Detail { get; } = string.Join(" · ", new[]
    {
        song.Artist,
        m.Transitions.FirstOrDefault(t => t.To == song.Index) is { } t
            ? $"{t.Style} · {Math.Round(t.End - t.Begins)} s blend" : null,
    }.Where(s => !string.IsNullOrEmpty(s)));

    bool _current;
    public bool IsCurrent
    {
        get => _current;
        set
        {
            if (_current == value) return;
            _current = value;
            PropertyChanged?.Invoke(this, new(nameof(BarOpacity)));
            PropertyChanged?.Invoke(this, new(nameof(Weight)));
        }
    }
    public double BarOpacity => _current ? 1 : 0.35;
    public Windows.UI.Text.FontWeight Weight => _current ? FontWeights.Bold : FontWeights.SemiBold;

    public event PropertyChangedEventHandler? PropertyChanged;
}

public sealed partial class MainWindow : Window
{
    readonly MixStore _store = new();
    readonly StateStore _state = new();
    readonly Player _player;
    readonly List<Rectangle> _bars = [];
    List<TrackRow> _rows = [];
    MixItem? _drawn;
    double _drawnWidth;
    double? _scrub;
    int _shownSong = -1;

    public MainWindow()
    {
        InitializeComponent();
        Title = "Passable";
        try
        {
            AppWindow.Resize(new(1120, 780));
            AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "Passable.ico"));
        }
        catch { /* cosmetic */ }

        _player = new Player(_state);
        _player.Changed += OnPlayerChanged;
        _player.Ticked += OnPlayerTicked;
        _player.Error += ShowError;
        _store.PeaksReady += item => DispatcherQueue.TryEnqueue(() => { if (_player.Item?.Id == item.Id) DrawWaveform(force: true); });
        Closed += (_, _) => _player.Dispose();

        _store.Load();
        LibraryList.ItemsSource = _store.Items;
        _store.Items.CollectionChanged += (_, _) => RefreshLibrary();
        RefreshLibrary();
        OnPlayerChanged();
    }

    /// <summary>Files named on the command line (a double-click in Explorer); otherwise resume the last mix, paused.</summary>
    public async void OpenAtLaunch(IEnumerable<string> files)
    {
        var list = files.ToList();
        if (list.Count > 0) await ImportAsync(list);
        else await _player.RestoreLastAsync(_store);
    }

    // MARK: - Library

    void RefreshLibrary()
    {
        EmptyLibrary.Visibility = _store.Items.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        LibraryFooter.Text = _store.Items.Count == 0 ? "" :
            $"{_store.Items.Count} {(_store.Items.Count == 1 ? "mix" : "mixes")} · {_store.TotalBytes / 1_000_000} MB";
    }

    async void OnLibraryItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is MixItem item) await _player.LoadAsync(item);
    }

    void OnRemoveClick(object sender, RoutedEventArgs e)
    {
        if (sender is not FrameworkElement { Tag: Guid id }) return;
        if (_store.Items.FirstOrDefault(i => i.Id == id) is not { } item) return;
        _player.Unload(id);
        _store.Delete(item);
    }

    void OnRevealClick(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: string folder })
            System.Diagnostics.Process.Start("explorer.exe", folder);
    }

    // MARK: - Importing

    async void OnOpenClick(object sender, RoutedEventArgs e) => await PickAndImportAsync();

    async Task PickAndImportAsync()
    {
        var picker = new FileOpenPicker { SuggestedStartLocation = PickerLocationId.Downloads };
        picker.FileTypeFilter.Add("." + PassableMix.FileExtension);
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
        var files = await picker.PickMultipleFilesAsync();
        if (files is { Count: > 0 }) await ImportAsync(files.Select(f => f.Path));
    }

    async Task ImportAsync(IEnumerable<string> paths)
    {
        MixItem? last = null;
        foreach (var path in paths)
        {
            ImportBar.Value = 0;
            ImportBar.Visibility = Visibility.Visible;
            try
            {
                // The same mix sent again replaces its old copy, which can't happen while it's playing.
                var id = PassableMix.ReadManifest(path).Id;
                _player.Unload(id);
                var progress = new Progress<double>(p => ImportBar.Value = p);
                last = await _store.ImportAsync(path, progress);
            }
            catch (Exception e)
            {
                ShowError($"{Path.GetFileName(path)}: {e.Message}");
            }
        }
        ImportBar.Visibility = Visibility.Collapsed;
        if (last is not null) await _player.LoadAsync(last);
    }

    void OnDragOver(object sender, DragEventArgs e)
    {
        if (e.DataView.Contains(StandardDataFormats.StorageItems))
        {
            e.AcceptedOperation = DataPackageOperation.Copy;
            e.DragUIOverride.Caption = "Add to Passable";
        }
    }

    async void OnDrop(object sender, DragEventArgs e)
    {
        if (!e.DataView.Contains(StandardDataFormats.StorageItems)) return;
        var items = await e.DataView.GetStorageItemsAsync();
        var mixes = items.OfType<StorageFile>()
            .Where(f => f.FileType.Equals("." + PassableMix.FileExtension, StringComparison.OrdinalIgnoreCase))
            .Select(f => f.Path).ToList();
        if (mixes.Count == 0) ShowError("Only .passablemix files can be added.");
        else await ImportAsync(mixes);
    }

    void ShowError(string message)
    {
        Notice.Title = "";
        Notice.Message = message;
        Notice.IsOpen = true;
    }

    // MARK: - Keys

    void OnPreviewKeyDown(object sender, KeyRoutedEventArgs e)
    {
        var ctrl = InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Control).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
        switch (e.Key)
        {
            case VirtualKey.Space: _player.Toggle(); e.Handled = true; break;
            case VirtualKey.Right when ctrl: _player.Next(); e.Handled = true; break;
            case VirtualKey.Left when ctrl: _player.Previous(); e.Handled = true; break;
            case VirtualKey.O when ctrl: _ = PickAndImportAsync(); e.Handled = true; break;
        }
    }

    // MARK: - Transport

    void OnPlayClick(object sender, RoutedEventArgs e) => _player.Toggle();
    void OnNextClick(object sender, RoutedEventArgs e) => _player.Next();
    void OnPrevClick(object sender, RoutedEventArgs e) => _player.Previous();
    void OnTrackClick(object sender, ItemClickEventArgs e) { if (e.ClickedItem is TrackRow row) _player.JumpToSong(row.Index); }

    // MARK: - Showing the player

    /// <summary>The mix, the song, or play/pause changed.</summary>
    void OnPlayerChanged()
    {
        var m = _player.Manifest;
        var has = m is not null;
        EmptyPlayer.Visibility = has ? Visibility.Collapsed : Visibility.Visible;
        NowPlaying.Visibility = Transport.Visibility = Buttons.Visibility = has ? Visibility.Visible : Visibility.Collapsed;
        PlayIcon.Glyph = _player.IsPlaying ? "" : "";
        if (m is null) { _drawn = null; _rows = []; TrackList.ItemsSource = null; _shownSong = -1; return; }

        if (_player.Item != _drawn)
        {
            _rows = m.Songs.Select(s => new TrackRow(m, s)).ToList();
            TrackList.ItemsSource = _rows;
            LibraryList.SelectedItem = _player.Item;
            MixTitle.Text = m.Title;
            _shownSong = -1;
            DrawWaveform(force: true);
        }

        if (_player.SongIndex != _shownSong && _player.CurrentSong is { } song)
        {
            _shownSong = _player.SongIndex;
            SongTitle.Text = song.Title;
            SongArtist.Text = song.Artist ?? "";
            SongArtist.Visibility = song.Artist is null ? Visibility.Collapsed : Visibility.Visible;
            Art.Background = Theme.Artwork(song.ArtworkSeed, song.Index);
            ArtLetter.Text = song.Title.Length > 0 ? song.Title[..1].ToUpperInvariant() : "";
            BpmChip.Visibility = song.Bpm is > 0 ? Visibility.Visible : Visibility.Collapsed;
            BpmText.Text = song.Bpm is { } bpm ? $"{Math.Round(bpm)} BPM" : "";
            KeyChip.Visibility = string.IsNullOrEmpty(song.Key) ? Visibility.Collapsed : Visibility.Visible;
            KeyText.Text = song.Key ?? "";
            PositionText.Text = $"Song {song.Index + 1} of {m.Songs.Count}";
            foreach (var row in _rows) row.IsCurrent = row.Index == song.Index;
        }
        PrevButton.IsEnabled = true;
        NextButton.IsEnabled = _player.CanGoNext;
        TotalText.Text = Theme.Clock(_player.Duration);
    }

    /// <summary>The clock moved.</summary>
    void OnPlayerTicked()
    {
        if (_player.Manifest is not { } m) return;
        var time = _scrub ?? _player.CurrentTime;
        ElapsedText.Text = Theme.Clock(time);
        MovePlayhead(time);

        if (_scrub is { } s)
        {
            ScrubName.Text = m.SongAt(s)?.Title ?? "";
        }
        else
        {
            ScrubName.Text = "";
        }

        if (_player.Blend is { } blend && _player.NextSong is { } next)
        {
            BlendStrip.Visibility = Visibility.Visible;
            BlendTitle.Text = $"Mixing into {next.Title}";
            BlendStyle.Text = blend.Transition.Style;
            BlendBar.Value = blend.Progress;
            BlendNotes.Text = string.Join(" · ", blend.Transition.Notes);
            BlendNotes.Visibility = blend.Transition.Notes.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        }
        else
        {
            BlendStrip.Visibility = Visibility.Collapsed;
        }
    }

    // MARK: - Waveform

    void OnWaveSizeChanged(object sender, SizeChangedEventArgs e) => DrawWaveform(force: false);

    void DrawWaveform(bool force)
    {
        var item = _player.Item;
        var width = WaveHost.ActualWidth;
        if (item is null || width < 10) { WaveCanvas.Children.Clear(); _bars.Clear(); return; }
        if (!force && item == _drawn && Math.Abs(width - _drawnWidth) < 1) return;
        _drawn = item;
        _drawnWidth = width;

        var m = item.Manifest;
        var height = WaveHost.Height;
        var count = Math.Max(1, (int)(width / 4));
        WaveCanvas.Children.Clear();
        _bars.Clear();
        var peaks = item.Peaks;
        var duration = Math.Max(1, _player.Duration);
        for (var i = 0; i < count; i++)
        {
            var t0 = duration * i / count;
            var t1 = duration * (i + 1) / count;
            float peak = 0.04f;
            if (peaks is { Length: > 0 })
            {
                var from = Math.Min(peaks.Length - 1, (int)(t0 * Waveform.PeaksPerSecond));
                var to = Math.Min(peaks.Length - 1, Math.Max(from, (int)(t1 * Waveform.PeaksPerSecond)));
                for (var k = from; k <= to; k++) peak = Math.Max(peak, peaks[k]);
            }
            var h = Math.Max(3, peak * height);
            var bar = new Rectangle
            {
                Width = Math.Max(1, width / count - 1.5),
                Height = h,
                RadiusX = 1.5, RadiusY = 1.5,
                Fill = Theme.ColorAt(m, (t0 + t1) / 2).Brush,
            };
            Canvas.SetLeft(bar, width * i / count);
            Canvas.SetTop(bar, (height - h) / 2);
            WaveCanvas.Children.Add(bar);
            _bars.Add(bar);
        }
        MovePlayhead(_scrub ?? _player.CurrentTime);
    }

    void MovePlayhead(double time)
    {
        var duration = Math.Max(1, _player.Duration);
        var x = Math.Clamp(time / duration, 0, 1) * Math.Max(0, WaveHost.ActualWidth - 2);
        Playhead.Margin = new Thickness(x, 0, 0, 0);
        // Played part bright, the rest dimmed.
        var played = (int)(Math.Clamp(time / duration, 0, 1) * _bars.Count);
        for (var i = 0; i < _bars.Count; i++) _bars[i].Opacity = i <= played ? 1 : 0.4;
    }

    double TimeAt(PointerRoutedEventArgs e)
    {
        var x = e.GetCurrentPoint(WaveHost).Position.X;
        return Math.Clamp(x / Math.Max(1, WaveHost.ActualWidth), 0, 1) * _player.Duration;
    }

    void OnWavePressed(object sender, PointerRoutedEventArgs e)
    {
        if (_player.Item is null) return;
        WaveHost.CapturePointer(e.Pointer);
        _scrub = TimeAt(e);
        OnPlayerTicked();
    }

    void OnWaveMoved(object sender, PointerRoutedEventArgs e)
    {
        if (_scrub is null) return;
        _scrub = TimeAt(e);
        OnPlayerTicked();
    }

    void OnWaveReleased(object sender, PointerRoutedEventArgs e)
    {
        if (_scrub is not { } t) return;
        _scrub = null;
        WaveHost.ReleasePointerCapture(e.Pointer);
        _player.Seek(t);
    }
}
