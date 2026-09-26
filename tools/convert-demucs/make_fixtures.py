"""Reference data for PassableTests, produced by the real PyTorch Demucs.

Writes raw little-endian float32 files to fixtures/:
  song.L.f32 / song.R.f32     12 s synthetic song, 124 BPM, first downbeat 0.5 s
  seg.spec.f32                 HTDemucs._magnitude(_spec(segment 0)), [4, 2048, 336]
  ref.<stem>.L.f32 / .R.f32    demucs.apply_model(split=True, overlap=0.25) output
"""

import os

import numpy as np
import torch
from demucs.apply import apply_model
from demucs.pretrained import get_model

SR = 44100
BPM = 124.0
FIRST_DOWNBEAT = 0.5
SECONDS = 12.0
OUT = os.path.join(os.path.dirname(__file__), "fixtures")


def song(bpm=BPM, first=FIRST_DOWNBEAT, seconds=SECONDS, transpose=0, sr=SR, seed=7):
    SR, BPM, FIRST_DOWNBEAT, SECONDS = sr, bpm, first, seconds
    ratio = 2 ** (transpose / 12)
    rng = np.random.default_rng(seed)
    n = int(SR * SECONDS)
    t = np.arange(n) / SR
    beat = 60 / BPM
    L = np.zeros(n)

    def env(start, decay, length):
        i0 = int(start * SR)
        m = min(n - i0, int(length * SR))
        if m <= 0:
            return None, None
        return slice(i0, i0 + m), np.exp(-np.arange(m) / SR / decay)

    k = 0
    while FIRST_DOWNBEAT + k * beat < SECONDS:
        tb = FIRST_DOWNBEAT + k * beat
        # kick: pitch-dropping sine
        s, e = env(tb, 0.08, 0.3)
        if s is not None:
            tt = np.arange(e.size) / SR
            L[s] += 0.9 * e * np.sin(2 * np.pi * (50 + 80 * np.exp(-tt / 0.03)) * tt)
        # offbeat hat: filtered noise burst
        s, e = env(tb + beat / 2, 0.02, 0.08)
        if s is not None:
            L[s] += 0.25 * e * np.diff(rng.standard_normal(e.size + 1))
        # clap on 2 and 4
        if k % 2 == 1:
            s, e = env(tb, 0.05, 0.2)
            if s is not None:
                L[s] += 0.35 * e * rng.standard_normal(e.size)
        k += 1

    # bass: A minor roots, one per bar
    roots = [55.0, 43.65, 65.41, 49.0]
    bar = 4 * beat
    for b in range(int(SECONDS / bar) + 1):
        f = roots[b % 4] * ratio
        s, e = env(FIRST_DOWNBEAT + b * bar, 1.5, bar)
        if s is not None:
            tt = np.arange(e.size) / SR
            L[s] += 0.35 * (0.6 + 0.4 * e) * np.tanh(2 * np.sin(2 * np.pi * f * tt))
    # pads: chords changing on downbeats
    chords = [[220, 261.63, 329.63], [174.61, 220, 261.63], [261.63, 329.63, 392], [196, 246.94, 293.66]]
    for b in range(int(SECONDS / bar) + 1):
        s, e = env(FIRST_DOWNBEAT + b * bar, 3.0, bar)
        if s is not None:
            tt = np.arange(e.size) / SR
            L[s] += 0.08 * sum(np.sin(2 * np.pi * f * ratio * tt) for f in chords[b % 4])
    # "vocal": vibrato tone with formant-ish harmonics, phrases on bars 2-3
    vib = np.sin(2 * np.pi * (440 * ratio * t + 3 * np.sin(2 * np.pi * 5.5 * t)))
    gate = ((t > FIRST_DOWNBEAT + bar) & (t < FIRST_DOWNBEAT + 2.8 * bar)).astype(float)
    L += 0.12 * gate * (vib + 0.5 * np.sin(2 * np.pi * 880 * ratio * t) * vib)

    R = np.roll(L, 30) * 0.95 + 0.03 * rng.standard_normal(n)
    mix = np.stack([L, R]).astype(np.float32)
    return mix / np.abs(mix).max() * 0.8


def main():
    os.makedirs(OUT, exist_ok=True)
    # Two longer songs as audio files for the end-to-end test: different
    # tempo and key, one at 48 kHz to exercise resampling.
    import soundfile as sf
    sf.write(os.path.join(OUT, "songA.wav"), song(124, 0.5, 40).T, SR, subtype="PCM_24")
    sf.write(os.path.join(OUT, "songB.wav"), song(118, 0.3, 40, transpose=2, sr=48000, seed=3).T, 48000, subtype="PCM_24")

    mix = song()
    mix[0].tofile(os.path.join(OUT, "song.L.f32"))
    mix[1].tofile(os.path.join(OUT, "song.R.f32"))

    bag = get_model("htdemucs")
    m = bag.models[0].eval()
    segment = int(m.segment * m.samplerate)
    with torch.no_grad():
        seg = torch.from_numpy(mix[None, :, :segment].copy())
        m._magnitude(m._spec(seg))[0].numpy().astype(np.float32).tofile(os.path.join(OUT, "seg.spec.f32"))

        wav = torch.from_numpy(mix)
        ref = wav.mean(0)
        normed = (wav - ref.mean()) / ref.std()
        # shifts=0: shifts>=1 adds a random 0-0.5 s offset, which would make the
        # reference unreproducible (and the app does not use it).
        out = apply_model(bag, normed[None], shifts=0, split=True, overlap=0.25, progress=False)[0]
        out = out * ref.std() + ref.mean()
    for i, name in enumerate(m.sources):
        out[i, 0].numpy().astype(np.float32).tofile(os.path.join(OUT, f"ref.{name}.L.f32"))
        out[i, 1].numpy().astype(np.float32).tofile(os.path.join(OUT, f"ref.{name}.R.f32"))
    print("wrote fixtures to", os.path.abspath(OUT))


if __name__ == "__main__":
    main()
