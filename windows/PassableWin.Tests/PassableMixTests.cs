using PassableWin.Model;
using Xunit;
using static PassableWin.Model.PassableMix;

namespace PassableWin.Tests;

public class PassableMixTests : IDisposable
{
    readonly string _dir = Directory.CreateTempSubdirectory("passablewin-").FullName;

    public void Dispose() { try { Directory.Delete(_dir, true); } catch { } }

    static string SamplePath()
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir != null; dir = dir.Parent)
        {
            var candidate = Path.Combine(dir.FullName, "ios", "Samples", "Sample Set.passablemix");
            if (File.Exists(candidate)) return candidate;
        }
        throw new FileNotFoundException("ios/Samples/Sample Set.passablemix not found above the test folder");
    }

    /// <summary>A three-song map: blends 10-20 s and 40-50 s, 120 bpm (2-second bars).</summary>
    static Manifest ThreeSongs() => new()
    {
        Title = "Test", Duration = 80,
        Songs =
        [
            new Song { Index = 0, Title = "A", Start = 0,  Handover = 0,  Solo = 0,  End = 20, Bpm = 120 },
            new Song { Index = 1, Title = "B", Start = 10, Handover = 20, Solo = 30, End = 50, Bpm = 120 },
            new Song { Index = 2, Title = "C", Start = 40, Handover = 50, Solo = 60, End = 80, Bpm = 120 },
        ],
        Transitions =
        [
            new Transition { From = 0, To = 1, Begins = 10, Handover = 20, End = 30, Style = "Long Blend" },
            new Transition { From = 1, To = 2, Begins = 40, Handover = 50, End = 60, Style = "Drop Swap", Cue = 33 },
        ],
    };

    [Fact]
    public void ReadsTheSampleSetTheMacApp_MadeFor_The_iPhone()
    {
        var path = SamplePath();
        var manifest = ReadManifest(path);
        Assert.NotEmpty(manifest.Songs);
        Assert.True(manifest.Duration > 0);
        Assert.NotEqual(Guid.Empty, manifest.Id);

        var audio = Path.Combine(_dir, "audio." + manifest.Audio.FileExtension);
        var full = Extract(path, audio);
        Assert.Equal(manifest.Id, full.Id);
        Assert.Equal(manifest.Audio.Size, new FileInfo(audio).Length);
        // An AAC file in an MP4 container: "ftyp" at byte 4.
        var head = new byte[8];
        using (var f = File.OpenRead(audio)) f.ReadExactly(head);
        Assert.Equal("ftyp", System.Text.Encoding.ASCII.GetString(head, 4, 4));
    }

    [Fact]
    public void WritingAndReadingBackKeepsTheMap()
    {
        var audio = Path.Combine(_dir, "a.m4a");
        File.WriteAllBytes(audio, [1, 2, 3, 4, 5, 6, 7, 8, 9]);
        var original = ThreeSongs();
        var file = Path.Combine(_dir, "t.passablemix");
        Write(original, audio, file);

        var back = Extract(file, Path.Combine(_dir, "out.m4a"));
        Assert.Equal(original.Id, back.Id);
        Assert.Equal(3, back.Songs.Count);
        Assert.Equal("Drop Swap", back.Transitions[1].Style);
        Assert.Equal(33, back.Transitions[1].Cue);
        Assert.Null(back.Transitions[0].Cue);
        Assert.Equal(9, back.Audio.Size);
        Assert.Equal([1, 2, 3, 4, 5, 6, 7, 8, 9], File.ReadAllBytes(Path.Combine(_dir, "out.m4a")));
    }

    [Fact]
    public void RejectsFilesThatAreNotMixes()
    {
        var file = Path.Combine(_dir, "x.passablemix");
        File.WriteAllText(file, "this is not a mix at all");
        Assert.Equal("This isn't a Passable mix.", Assert.Throws<FileException>(() => ReadManifest(file)).Message);
    }

    [Fact]
    public void RejectsTruncatedFiles()
    {
        var audio = Path.Combine(_dir, "a.m4a");
        File.WriteAllBytes(audio, new byte[10_000]);
        var file = Path.Combine(_dir, "t.passablemix");
        Write(ThreeSongs(), audio, file);
        var bytes = File.ReadAllBytes(file);
        File.WriteAllBytes(file, bytes[..(bytes.Length - 5_000)]);
        Assert.Throws<FileException>(() => Extract(file, Path.Combine(_dir, "o.m4a")));
    }

    [Fact]
    public void RejectsNewerFormats()
    {
        var audio = Path.Combine(_dir, "a.m4a");
        File.WriteAllBytes(audio, [1]);
        var file = Path.Combine(_dir, "t.passablemix");
        Write(ThreeSongs(), audio, file);
        var bytes = File.ReadAllBytes(file);
        bytes[11] = 9; // version, little-endian, right after the 11-byte magic
        File.WriteAllBytes(file, bytes);
        Assert.Contains("newer Passable", Assert.Throws<FileException>(() => ReadManifest(file)).Message);
    }

    [Fact]
    public void SkipsUnknownChunks()
    {
        var audio = Path.Combine(_dir, "a.m4a");
        File.WriteAllBytes(audio, [7, 7, 7]);
        var file = Path.Combine(_dir, "t.passablemix");
        Write(ThreeSongs(), audio, file);
        var bytes = File.ReadAllBytes(file).ToList();
        // Splice a "COVR" chunk in after the manifest (magic 11 + version 2 + header 12 + json).
        var json = ReadManifest(file); _ = json;
        var manifestLength = (int)BitConverter.ToUInt64(bytes.ToArray(), 13 + 4);
        var at = 13 + 12 + manifestLength;
        var extra = new List<byte>("COVR"u8.ToArray());
        extra.AddRange(BitConverter.GetBytes(4UL));
        extra.AddRange([9, 9, 9, 9]);
        bytes.InsertRange(at, extra);
        File.WriteAllBytes(file, [.. bytes]);

        var back = Extract(file, Path.Combine(_dir, "o.m4a"));
        Assert.Equal(3, back.Songs.Count);
        Assert.Equal([7, 7, 7], File.ReadAllBytes(Path.Combine(_dir, "o.m4a")));
    }

    // MARK: - The map

    [Fact]
    public void TheSongThatIsPlayingIsTheOneThatLastTookOver()
    {
        var m = ThreeSongs();
        Assert.Equal(0, m.SongIndexAt(0));
        Assert.Equal(0, m.SongIndexAt(15));   // blending into B, A still "playing"
        Assert.Equal(1, m.SongIndexAt(20));
        Assert.Equal(1, m.SongIndexAt(45));
        Assert.Equal(2, m.SongIndexAt(70));
    }

    [Fact]
    public void KnowsWhereABlendIsAndHowFarThroughIt()
    {
        var m = ThreeSongs();
        Assert.Null(m.TransitionAt(5));
        Assert.Equal("Long Blend", m.TransitionAt(15)!.Style);
        Assert.Equal(0.25, m.TransitionProgress(15)!.Value, 6);
        Assert.Null(m.TransitionAt(30));       // the end is exclusive
        Assert.Equal(30, m.LengthOfSong(1));
        Assert.Equal(30, m.LengthOfSong(2));   // to the end of the set
    }

    [Fact]
    public void LeadInIsTheStoredCueOrFourBarsBefore_NeverInsideTheBlend()
    {
        var m = ThreeSongs();
        Assert.Equal(2, m.LeadIn(m.Transitions[0]));   // 10 - 4 bars * 2 s
        Assert.Equal(33, m.LeadIn(m.Transitions[1]));  // the stored cue
        m.Transitions[1].Cue = 99;                     // a cue after the blend begins is clamped
        Assert.Equal(40, m.LeadIn(m.Transitions[1]));
    }

    [Fact]
    public void NextLandsOnTheLeadInOfTheNextBlend()
    {
        var m = ThreeSongs();
        Assert.Equal(2, m.NextTarget(0, SkipLanding.Lead));
        Assert.Equal(33, m.NextTarget(25, SkipLanding.Lead));
        Assert.Null(m.NextTarget(70, SkipLanding.Lead));
        Assert.Equal(20, m.NextTarget(0, SkipLanding.Handover));
    }

    [Fact]
    public void PreviousRestartsTheLeadInThenGoesBack()
    {
        var m = ThreeSongs();
        Assert.Equal(33, m.PreviousTarget(40, SkipLanding.Lead));   // heard the lead-in for a while: restart it
        Assert.Equal(2, m.PreviousTarget(34, SkipLanding.Lead));    // pressed again right away: the one before
        Assert.Equal(0, m.PreviousTarget(3, SkipLanding.Lead));
        Assert.Equal(20, m.PreviousTarget(40, SkipLanding.Handover));
        Assert.Equal(0, m.PreviousTarget(21, SkipLanding.Handover));
    }
}
