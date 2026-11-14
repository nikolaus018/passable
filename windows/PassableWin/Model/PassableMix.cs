using System.Text.Json;
using System.Text.Json.Serialization;

namespace PassableWin.Model;

/// <summary>
/// A <c>.passablemix</c> file: one rendered set (a single continuous AAC file, with every
/// transition already inside it) plus the map of where each song sits. A C# port of
/// <c>Passable/Model/PassableMix.swift</c>, which the iPhone app compiles; keep the two in step.
///
/// Layout, all integers little-endian:
///
///     11 bytes    magic: "PASSMIX" 0D 0A 1A 0A
///     UInt16      format version
///     chunks, each:
///       4 ASCII bytes   type
///       UInt64          payload length
///       payload
///
///     "MNFT"  the manifest, JSON (<see cref="Manifest"/>); always the first chunk
///     "AUDI"  the audio file, byte for byte (<c>Manifest.Audio.FileExtension</c>)
///     "END "  empty
///
/// Unknown chunk types are skipped, so later versions can add chunks that older readers ignore.
/// </summary>
public static class PassableMix
{
    public const ushort FormatVersion = 1;
    public const string FileExtension = "passablemix";

    static readonly byte[] Magic = [.. "PASSMIX"u8.ToArray(), 0x0D, 0x0A, 0x1A, 0x0A];
    const int ChunkHeader = 12;
    const int CopyBlock = 1 << 20;
    const long MaxManifest = 64L << 20;

    /// <summary>Same wire format as Swift's JSONEncoder: camelCase keys, ISO-8601 dates.</summary>
    public static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web)
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    // MARK: - The map

    public sealed class Manifest
    {
        public int Format { get; set; } = FormatVersion;
        /// <summary>Identifies the mix across exports, so sending the same set twice replaces it.</summary>
        public Guid Id { get; set; } = Guid.NewGuid();
        public string Title { get; set; } = "";
        public DateTimeOffset Created { get; set; } = DateTimeOffset.UtcNow;
        public string Source { get; set; } = "";
        /// <summary>Seconds of music; the audio file rings out a few seconds longer.</summary>
        public double Duration { get; set; }
        public AudioInfo Audio { get; set; } = new();
        public List<Song> Songs { get; set; } = [];
        public List<Transition> Transitions { get; set; } = [];
    }

    public sealed class AudioInfo
    {
        public string FileExtension { get; set; } = "m4a";
        public string Codec { get; set; } = "aac";
        public double SampleRate { get; set; } = 44_100;
        public int BitRate { get; set; } = 256_000;
        public long Size { get; set; }
    }

    /// <summary>One song of the set. All times are seconds into the audio file.</summary>
    public sealed class Song
    {
        public int Index { get; set; }
        public string Title { get; set; } = "";
        public string? Artist { get; set; }
        /// <summary>First moment the song is audible: where the blend into it begins.</summary>
        public double Start { get; set; }
        /// <summary>Where it takes over from the song before: from here on it is "the song that's playing".</summary>
        public double Handover { get; set; }
        /// <summary>Where the blend into it is over and it plays on alone.</summary>
        public double Solo { get; set; }
        /// <summary>Where it is gone (the blend out of it is over, or the set ends).</summary>
        public double End { get; set; }
        public double? Bpm { get; set; }
        public string? Key { get; set; }

        /// <summary>What the cover art is made from.</summary>
        [JsonIgnore] public string ArtworkSeed => $"{Artist ?? ""}|{Title}";
    }

    /// <summary>The blend from <see cref="From"/> into <see cref="To"/> (song indexes).</summary>
    public sealed class Transition
    {
        public int From { get; set; }
        public int To { get; set; }
        public double Begins { get; set; }
        public double Handover { get; set; }
        public double End { get; set; }
        /// <summary>"Drop Swap", "Long Blend", ...</summary>
        public string Style { get; set; } = "";
        /// <summary>What makes it more than a crossfade, in words.</summary>
        public List<string> Notes { get; set; } = [];
        /// <summary>Four bars before anything happens: where a skip lands so the whole transition is heard.</summary>
        public double? Cue { get; set; }
    }

    // MARK: - Reading the map

    /// <summary>What "Next" and "Previous" jump to.</summary>
    public enum SkipLanding
    {
        /// <summary>A few bars before the blend into the new song, so the mix is heard from its lead-in.</summary>
        Lead,
        /// <summary>The new song as it starts to blend in: the transition plays.</summary>
        Blend,
        /// <summary>The new song as it takes over: straight to the good part.</summary>
        Handover,
    }

    /// <summary>The song that's playing at <paramref name="time"/>: the one that last took over.</summary>
    public static int SongIndexAt(this Manifest m, double time)
    {
        for (var i = m.Songs.Count - 1; i >= 0; i--)
            if (m.Songs[i].Handover <= time + 0.001) return i;
        return 0;
    }

    public static Song? SongAt(this Manifest m, double time) =>
        m.Songs.Count == 0 ? null : m.Songs[m.SongIndexAt(time)];

    /// <summary>The blend that's going on at <paramref name="time"/>, if any.</summary>
    public static Transition? TransitionAt(this Manifest m, double time) =>
        m.Transitions.FirstOrDefault(t => t.Begins <= time && time < t.End);

    /// <summary>0...1 through the blend at <paramref name="time"/>.</summary>
    public static double? TransitionProgress(this Manifest m, double time)
    {
        var t = m.TransitionAt(time);
        if (t is null || t.End <= t.Begins) return null;
        return (time - t.Begins) / (t.End - t.Begins);
    }

    /// <summary>Seconds the song's own stretch of the set lasts, from its takeover to the next song's.</summary>
    public static double LengthOfSong(this Manifest m, int i)
    {
        if (i < 0 || i >= m.Songs.Count) return 0;
        var next = i + 1 < m.Songs.Count ? m.Songs[i + 1].Handover : m.Duration;
        return Math.Max(0, next - m.Songs[i].Handover);
    }

    /// <summary>Where a skip to song <paramref name="i"/> lands.</summary>
    public static double Landing(this Manifest m, int i, SkipLanding mode)
    {
        var s = m.Songs[i];
        switch (mode)
        {
            case SkipLanding.Lead:
                var t = m.Transitions.FirstOrDefault(x => x.To == i);
                return t is null ? s.Start : m.LeadIn(t);
            case SkipLanding.Blend: return s.Start;
            default: return s.Handover;
        }
    }

    /// <summary>Where listening to <paramref name="t"/> starts: its stored cue, else four bars of the song going out.</summary>
    public static double LeadIn(this Manifest m, Transition t)
    {
        var from = t.From >= 0 && t.From < m.Songs.Count ? m.Songs[t.From] : null;
        var bar = from?.Bpm is > 0 ? 240 / from.Bpm.Value : 2;
        var cue = t.Cue ?? t.Begins - 4 * bar;
        return Math.Min(t.Begins, Math.Max(cue, Math.Max(from?.Handover ?? 0, 0)));
    }

    /// <summary>Where Next lands from <paramref name="time"/>: the first later song start that's really ahead.</summary>
    public static double? NextTarget(this Manifest m, double time, SkipLanding mode)
    {
        var current = m.SongIndexAt(time);
        for (var i = current + 1; i < m.Songs.Count; i++)
        {
            var t = m.Landing(i, mode);
            if (t > time + 0.5) return t;
        }
        return null;
    }

    /// <summary>Where Previous lands: the start of the song that's playing, or, in its first seconds, the one before.</summary>
    public static double PreviousTarget(this Manifest m, double time, SkipLanding mode)
    {
        if (mode == SkipLanding.Lead)
        {
            // Like a CD player: the lead-in being heard restarts; pressed again right away it goes to the one before.
            var best = 0.0;
            for (var i = 1; i < m.Songs.Count; i++)
            {
                var start = m.Landing(i, SkipLanding.Lead);
                if (start < time - 3) best = start;
            }
            return best;
        }
        var current = m.SongIndexAt(time);
        if (current < 0 || current >= m.Songs.Count) return 0;
        var own = current == 0 ? 0 : m.Landing(current, mode);
        if (time - own > 3 || current == 0) return own;
        return current - 1 == 0 ? 0 : m.Landing(current - 1, mode);
    }

    // MARK: - The file

    public sealed class FileException(string message) : Exception(message)
    {
        public static FileException NotAMix => new("This isn't a Passable mix.");
        public static FileException NewerVersion(int v) =>
            new($"This mix was made by a newer Passable (format {v}). Update the app to open it.");
        public static FileException Truncated => new("The mix file is cut short. Try sending it again.");
        public static FileException NoAudio => new("The mix has no audio in it.");
        public static FileException NoManifest => new("The mix has no song list in it.");
    }

    /// <summary>Writes <paramref name="manifest"/> and the audio file at <paramref name="audioPath"/> into one <c>.passablemix</c>.</summary>
    public static void Write(Manifest manifest, string audioPath, string destination)
    {
        var size = new FileInfo(audioPath).Length;
        manifest.Audio.Size = size;
        manifest.Audio.FileExtension = Path.GetExtension(audioPath).TrimStart('.').ToLowerInvariant();
        var json = JsonSerializer.SerializeToUtf8Bytes(manifest, Json);

        var temp = destination + ".part";
        try
        {
            using (var output = File.Create(temp))
            {
                output.Write(Magic);
                Span<byte> version = stackalloc byte[2];
                System.Buffers.Binary.BinaryPrimitives.WriteUInt16LittleEndian(version, FormatVersion);
                output.Write(version);
                WriteChunkHeader(output, "MNFT", json.Length);
                output.Write(json);
                WriteChunkHeader(output, "AUDI", size);
                using (var input = File.OpenRead(audioPath)) input.CopyTo(output, CopyBlock);
                WriteChunkHeader(output, "END ", 0);
            }
            File.Move(temp, destination, overwrite: true);
        }
        finally { if (File.Exists(temp)) File.Delete(temp); }
    }

    /// <summary>Reads just the manifest (cheap: the audio isn't touched).</summary>
    public static Manifest ReadManifest(string path)
    {
        using var input = File.OpenRead(path);
        ReadHeader(input);
        var chunk = ReadChunkHeader(input);
        if (chunk is not ("MNFT", var length)) throw FileException.NoManifest;
        return DecodeManifest(ReadExactly(input, length));
    }

    /// <summary>Reads the manifest and writes the audio out to <paramref name="audioDestination"/>.</summary>
    public static Manifest Extract(string path, string audioDestination, Action<double>? progress = null)
    {
        using var input = File.OpenRead(path);
        ReadHeader(input);
        Manifest? manifest = null;
        var wroteAudio = false;
        while (ReadChunkHeader(input) is { } header)
        {
            var (tag, length) = header;
            if (tag == "END ") break;
            switch (tag)
            {
                case "MNFT":
                    manifest = DecodeManifest(ReadExactly(input, length));
                    break;
                case "AUDI":
                    using (var output = File.Create(audioDestination))
                    {
                        var buffer = new byte[CopyBlock];
                        var left = length;
                        while (left > 0)
                        {
                            var n = input.Read(buffer, 0, (int)Math.Min(CopyBlock, left));
                            if (n <= 0) throw FileException.Truncated;
                            output.Write(buffer, 0, n);
                            left -= (ulong)n;
                            if (length > 0) progress?.Invoke((double)(length - left) / length);
                        }
                    }
                    wroteAudio = true;
                    break;
                default:
                    input.Seek((long)length, SeekOrigin.Current);
                    break;
            }
        }
        if (manifest is null) throw FileException.NoManifest;
        if (!wroteAudio) throw FileException.NoAudio;
        return manifest;
    }

    // MARK: Plumbing

    static Manifest DecodeManifest(byte[] data)
    {
        Manifest? manifest;
        try { manifest = JsonSerializer.Deserialize<Manifest>(data, Json); }
        catch (JsonException) { throw FileException.NoManifest; }
        if (manifest is null) throw FileException.NoManifest;
        if (manifest.Format > FormatVersion) throw FileException.NewerVersion(manifest.Format);
        return manifest;
    }

    static void ReadHeader(Stream input)
    {
        var head = new byte[Magic.Length + 2];
        if (input.Read(head, 0, head.Length) != head.Length) throw FileException.NotAMix;
        if (!head.AsSpan(0, Magic.Length).SequenceEqual(Magic)) throw FileException.NotAMix;
        int version = head[Magic.Length] | head[Magic.Length + 1] << 8;
        if (version > FormatVersion) throw FileException.NewerVersion(version);
    }

    static (string Tag, ulong Length)? ReadChunkHeader(Stream input)
    {
        var head = new byte[ChunkHeader];
        var n = input.Read(head, 0, head.Length);
        if (n == 0) return null;
        if (n != ChunkHeader) throw FileException.Truncated;
        var tag = System.Text.Encoding.UTF8.GetString(head, 0, 4);
        return (tag, BitConverter.ToUInt64(head, 4)); // Windows is little-endian, as is the file.
    }

    static byte[] ReadExactly(Stream input, ulong count)
    {
        if (count >= (ulong)MaxManifest) throw FileException.Truncated;
        var data = new byte[count];
        var read = 0;
        while (read < data.Length)
        {
            var n = input.Read(data, read, data.Length - read);
            if (n <= 0) throw FileException.Truncated;
            read += n;
        }
        return data;
    }

    static void WriteChunkHeader(Stream output, string tag, long length)
    {
        output.Write(System.Text.Encoding.ASCII.GetBytes(tag));
        output.Write(BitConverter.GetBytes((ulong)length));
    }
}
