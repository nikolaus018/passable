using System.Collections.ObjectModel;
using System.Text.Json;

namespace PassableWin.Model;

/// <summary>One mix on this PC: a folder with <c>manifest.json</c>, the audio, and the cached waveform.</summary>
public sealed class MixItem(PassableMix.Manifest manifest, string folder)
{
    public PassableMix.Manifest Manifest { get; } = manifest;
    public string Folder { get; } = folder;
    public Guid Id => Manifest.Id;
    public string AudioPath => Path.Combine(Folder, "audio." + Manifest.Audio.FileExtension);
    /// <summary>Loudness outline; null until it has been worked out.</summary>
    public float[]? Peaks { get; set; }

    public string Title => Manifest.Title;
    public string Subtitle => $"{Manifest.Songs.Count} songs · {Theme.Length(Manifest.Duration)}";
}

/// <summary>The mixes on this PC, under %LOCALAPPDATA%\Passable\Mixes (one folder each).</summary>
public sealed class MixStore
{
    public ObservableCollection<MixItem> Items { get; } = [];

    /// <summary>Raised on whichever thread finishes the work; subscribers marshal to the UI themselves.</summary>
    public event Action<MixItem>? PeaksReady;

    public static string AppFolder { get; } =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Passable");

    readonly string _root;

    public MixStore(string? root = null)
    {
        _root = root ?? Path.Combine(AppFolder, "Mixes");
        Directory.CreateDirectory(_root);
    }

    public string RootFolder => _root;

    /// <summary>Reads what's on disk. Call once, on the UI thread, at launch.</summary>
    public void Load()
    {
        var found = new List<MixItem>();
        foreach (var folder in Directory.EnumerateDirectories(_root))
        {
            var manifest = ReadManifest(folder);
            if (manifest is null)
            {
                // Leftovers of an import that never finished.
                if (Path.GetFileName(folder).StartsWith("incoming-")) TryDelete(folder);
                continue;
            }
            var item = new MixItem(manifest, folder);
            try
            {
                var peaks = Path.Combine(folder, "peaks.bin");
                if (File.Exists(peaks)) item.Peaks = Waveform.Decode(File.ReadAllBytes(peaks));
            }
            catch { /* recomputed below */ }
            found.Add(item);
        }
        foreach (var item in found.OrderByDescending(i => i.Manifest.Created)) Items.Add(item);
        foreach (var item in Items.Where(i => i.Peaks is null)) ComputePeaks(item);
    }

    static PassableMix.Manifest? ReadManifest(string folder)
    {
        try
        {
            var data = File.ReadAllBytes(Path.Combine(folder, "manifest.json"));
            return JsonSerializer.Deserialize<PassableMix.Manifest>(data, PassableMix.Json);
        }
        catch { return null; }
    }

    /// <summary>Takes a <c>.passablemix</c> into the library (off the UI thread). Throws a readable error if it can't.</summary>
    public async Task<MixItem> ImportAsync(string source, IProgress<double>? progress = null)
    {
        var item = await Task.Run(() => Unpack(source, progress));
        // Same mix sent again: replaces the old copy instead of piling up.
        var old = Items.FirstOrDefault(i => i.Id == item.Id);
        if (old is not null) Items.Remove(old);
        Items.Insert(0, item);
        ComputePeaks(item);
        return item;
    }

    MixItem Unpack(string source, IProgress<double>? progress)
    {
        var manifest = PassableMix.ReadManifest(source);
        var staging = Path.Combine(_root, "incoming-" + Guid.NewGuid());
        Directory.CreateDirectory(staging);
        try
        {
            var audio = Path.Combine(staging, "audio." + manifest.Audio.FileExtension);
            var full = PassableMix.Extract(source, audio, p => progress?.Report(p));
            if (new FileInfo(audio).Length == 0) throw PassableMix.FileException.NoAudio;
            File.WriteAllBytes(Path.Combine(staging, "manifest.json"), JsonSerializer.SerializeToUtf8Bytes(full, PassableMix.Json));

            var final = Path.Combine(_root, full.Id.ToString());
            // The playing copy may be locked; the caller unloads it first, but don't leave a half-swap behind if not.
            if (Directory.Exists(final)) Directory.Delete(final, true);
            Directory.Move(staging, final);
            return new MixItem(full, final);
        }
        catch
        {
            TryDelete(staging);
            throw;
        }
    }

    void ComputePeaks(MixItem item)
    {
        _ = Task.Run(() =>
        {
            try
            {
                var peaks = Waveform.Peaks(item.AudioPath);
                if (peaks.Length == 0) return;
                File.WriteAllBytes(Path.Combine(item.Folder, "peaks.bin"), Waveform.Encode(peaks));
                item.Peaks = peaks;
                PeaksReady?.Invoke(item);
            }
            catch { /* the mix still plays, just without an outline */ }
        });
    }

    public void Delete(MixItem item)
    {
        Items.Remove(item);
        TryDelete(item.Folder);
    }

    public long TotalBytes => Items.Sum(i => i.Manifest.Audio.Size);

    static void TryDelete(string folder) { try { Directory.Delete(folder, true); } catch { } }
}

/// <summary>What to remember between launches: the mix that was playing, and where each one was left.</summary>
public sealed class StateStore
{
    sealed class Data
    {
        public Guid? LastMix { get; set; }
        public Dictionary<string, double> Positions { get; set; } = [];
    }

    readonly string _path = Path.Combine(MixStore.AppFolder, "state.json");
    Data _data = new();

    public StateStore()
    {
        try { _data = JsonSerializer.Deserialize<Data>(File.ReadAllText(_path), PassableMix.Json) ?? new(); }
        catch { _data = new(); }
    }

    public Guid? LastMix { get => _data.LastMix; set { _data.LastMix = value; Save(); } }

    public double PositionOf(Guid id) => _data.Positions.GetValueOrDefault(id.ToString());

    public void SetPosition(Guid id, double seconds) { _data.Positions[id.ToString()] = seconds; Save(); }

    public void Forget(Guid id)
    {
        _data.Positions.Remove(id.ToString());
        if (_data.LastMix == id) _data.LastMix = null;
        Save();
    }

    void Save()
    {
        try
        {
            Directory.CreateDirectory(MixStore.AppFolder);
            File.WriteAllText(_path, JsonSerializer.Serialize(_data, PassableMix.Json));
        }
        catch { /* not worth interrupting the music */ }
    }
}
