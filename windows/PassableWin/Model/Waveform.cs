using NAudio.Wave;

namespace PassableWin.Model;

/// <summary>The loudness outline of a mix: one peak per quarter second, cached beside the audio.</summary>
public static class Waveform
{
    public const int PeaksPerSecond = 4;

    /// <summary>Decodes <paramref name="path"/> with Media Foundation (AAC included) and takes peaks, scaled so the loudest is 1.</summary>
    public static float[] Peaks(string path, CancellationToken cancel = default)
    {
        using var reader = new MediaFoundationReader(path);
        var samples = reader.ToSampleProvider();
        var window = samples.WaveFormat.SampleRate * samples.WaveFormat.Channels / PeaksPerSecond;
        var buffer = new float[window];
        var peaks = new List<float>();
        int n;
        while ((n = samples.Read(buffer, 0, buffer.Length)) > 0)
        {
            cancel.ThrowIfCancellationRequested();
            var peak = 0f;
            for (var i = 0; i < n; i++) peak = Math.Max(peak, Math.Abs(buffer[i]));
            peaks.Add(peak);
        }
        var max = peaks.Count == 0 ? 0 : peaks.Max();
        if (max > 0) for (var i = 0; i < peaks.Count; i++) peaks[i] /= max;
        return [.. peaks];
    }

    public static byte[] Encode(float[] peaks)
    {
        var bytes = new byte[peaks.Length * 4];
        Buffer.BlockCopy(peaks, 0, bytes, 0, bytes.Length);
        return bytes;
    }

    public static float[] Decode(byte[] bytes)
    {
        var peaks = new float[bytes.Length / 4];
        Buffer.BlockCopy(bytes, 0, peaks, 0, peaks.Length * 4);
        return peaks;
    }
}
