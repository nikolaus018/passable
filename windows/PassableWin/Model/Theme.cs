using Microsoft.UI;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace PassableWin.Model;

/// <summary>
/// The look of Passable: the Mac app's two deck colours (blue, orange) alternate from song to song,
/// so a blend is shown the way the desk does it, as one colour handing over to the other.
/// </summary>
public static class Theme
{
    public readonly record struct Rgb(double R, double G, double B)
    {
        public Rgb MixedWith(Rgb other, double t)
        {
            t = Math.Clamp(t, 0, 1);
            return new(R + (other.R - R) * t, G + (other.G - G) * t, B + (other.B - B) * t);
        }

        public Color Color => Color.FromArgb(255, (byte)Math.Round(R * 255), (byte)Math.Round(G * 255), (byte)Math.Round(B * 255));
        public SolidColorBrush Brush => new(Color);
    }

    public static readonly Rgb DeckA = new(0.36, 0.62, 1.0);
    public static readonly Rgb DeckB = new(1.0, 0.52, 0.32);

    /// <summary>Even songs ride the blue deck, odd songs the orange one.</summary>
    public static Rgb Deck(int songIndex) => songIndex % 2 == 0 ? DeckA : DeckB;

    /// <summary>The colour at <paramref name="time"/>: the playing song's deck, sliding across a blend.</summary>
    public static Rgb ColorAt(PassableMix.Manifest m, double time)
    {
        if (m.TransitionAt(time) is { } t && m.TransitionProgress(time) is { } p)
            return Deck(t.From).MixedWith(Deck(t.To), p);
        return Deck(m.SongIndexAt(time));
    }

    /// <summary>3:07 or 1:02:09.</summary>
    public static string Clock(double seconds)
    {
        var s = Math.Max(0, (int)Math.Floor(seconds));
        int h = s / 3600, m = s % 3600 / 60, sec = s % 60;
        return h > 0 ? $"{h}:{m:00}:{sec:00}" : $"{m}:{sec:00}";
    }

    /// <summary>"58 min" or "1 h 12 min".</summary>
    public static string Length(double seconds)
    {
        var minutes = (int)Math.Round(seconds / 60);
        return minutes >= 60 ? $"{minutes / 60} h {minutes % 60} min" : $"{Math.Max(1, minutes)} min";
    }

    /// <summary>A number that stays the same from launch to launch, so a song keeps its artwork (FNV-1a, as on the phone).</summary>
    public static ulong StableHash(string s)
    {
        var h = 0xcbf29ce484222325UL;
        foreach (var b in System.Text.Encoding.UTF8.GetBytes(s)) { h ^= b; h *= 0x100000001b3UL; }
        return h;
    }

    /// <summary>Cover art made from nothing but the song's name: a gradient from its deck colour.</summary>
    public static LinearGradientBrush Artwork(string seed, int songIndex)
    {
        var h = StableHash(seed);
        var a = Deck(songIndex);
        var shift = (h % 1000) / 1000.0;
        var b = a.MixedWith(shift < 0.5 ? new Rgb(0.55, 0.25, 0.9) : new Rgb(0.1, 0.8, 0.7), 0.35 + (h >> 10) % 40 / 100.0);
        var dark = new Rgb(0.06, 0.06, 0.1);
        var angle = (h >> 20) % 4;
        var (start, end) = angle switch
        {
            0 => (new Windows.Foundation.Point(0, 0), new Windows.Foundation.Point(1, 1)),
            1 => (new Windows.Foundation.Point(1, 0), new Windows.Foundation.Point(0, 1)),
            2 => (new Windows.Foundation.Point(0, 1), new Windows.Foundation.Point(1, 0)),
            _ => (new Windows.Foundation.Point(0.5, 0), new Windows.Foundation.Point(0.5, 1)),
        };
        return new LinearGradientBrush
        {
            StartPoint = start, EndPoint = end,
            GradientStops =
            {
                new GradientStop { Color = a.Color, Offset = 0 },
                new GradientStop { Color = b.Color, Offset = 0.6 },
                new GradientStop { Color = dark.MixedWith(b, 0.25).Color, Offset = 1 },
            },
        };
    }
}
