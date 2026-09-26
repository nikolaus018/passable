# Passable

A native macOS app for building transitions between two tracks, stem by stem.

1. Load **Track A** and **Track B**: open a file, drag one onto a deck, or use **Find Online…**, which downloads a WAV to `~/Music/Passable` via `yt-dlp` and `ffmpeg`.
2. Each track is split into **vocals, melody, drums and bass** by HTDemucs v4, running locally through Core ML. The app then finds its beat grid and key.
3. B is time-stretched to A's tempo and pitch-shifted to a compatible key. Drums are only time-stretched, never pitch-shifted.
4. The 8 stem lanes are automatable: **volume, DJ filter, 3-band EQ (with kill), reverb send, delay send**. The presets are Stem Swap, Drop Swap, Long Blend and Echo Out. Click a lane to add a point and drag to move it; points snap to the beat unless you hold ⌥. Right-click a point to change its curve or delete it. Scroll to pan, and pinch or ⌘-scroll to zoom.
5. **Auto** picks where the transition goes from the stems. It keeps both sides on phrase boundaries with drums under the blend, times B's vocal to come in as A's is echoed out, and caps automatic key shifts at ±2 semitones (it flags clashes instead). **Undo/redo** covers all edits (⌘Z / ⇧⌘Z). If beat detection gets a track wrong, use the **Grid** menu on the deck to halve or double the BPM, shift the downbeat by a beat, or nudge the grid.
6. **Render WAV** exports the full mix or just the transition as a 24-bit, 44.1 kHz file.

## Build

```sh
brew install xcodegen yt-dlp ffmpeg uv
# One-time: export the Core ML model (~200 MB, not checked in)
cd tools/convert-demucs && uv venv --python 3.12 .venv && \
  uv pip install --python .venv/bin/python torch==2.7.0 torchaudio==2.7.0 coremltools demucs numpy soundfile && \
  .venv/bin/python convert.py && .venv/bin/python make_fixtures.py && cd ../..
xcodegen generate && open Passable.xcodeproj
```

## How the model runs

Core ML has no complex tensors, so `convert.py` exports HTDemucs **without** its STFT/iSTFT. `Separation/DemucsSTFT.swift` reimplements those in Accelerate to match torch exactly. `StemSeparator` also reproduces `demucs.apply_model` chunking: 7.8 s segments, 25 % overlap, triangular cross-fades, and context padding for the last chunk.

The tests compare the result against PyTorch: stems match at over 110 dB SNR. The model runs in FP32 on the GPU. An FP16 (Neural Engine) export overflows and drifts badly. A 4-minute track separates in about 20 s on an M5. Stems are cached in `~/Library/Caches/Passable`.

## Layout

| Folder | Contents |
|---|---|
| `Passable/Separation` | Core ML HTDemucs, STFT, stem cache |
| `Passable/Analysis` | beat grid (onset comb search + downbeat), key (Krumhansl chroma) |
| `Passable/Audio` | decoding/resampling, mmap'd stems, AUTimePitch offline matching |
| `Passable/DSP` | mixer, biquads, Freeverb, ping-pong delay, limiter: shared by preview and render |
| `Passable/Model` | automation envelopes, presets, session |
| `Passable/UI` | SwiftUI: decks, transition panel, timeline, search |

To check analysis and placement on your own files, run `PASSABLE_PROBE=list.txt xcodebuild test -only-testing:PassableTests/RealTrackProbe`, where `list.txt` holds one path per line.

Dev shortcut: `Passable.app/Contents/MacOS/Passable -PassableTrackA a.wav -PassableTrackB b.wav` preloads both decks.
