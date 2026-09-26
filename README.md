# Passable

A native macOS app that mixes songs like a DJ, stem by stem. Add songs to a set, and Passable puts them in the order that flows best, builds every transition and plays or renders one continuous mix. Any transition can be opened and shaped by hand.

## Set tab

1. Add songs: drop files onto the window, **Add Files…** (⌘O), or **Find Online…**, which downloads to `~/Music/Passable` via `yt-dlp` and `ffmpeg`. Downloads keep YouTube's own AAC stream as `.m4a`, without re-encoding: YouTube audio is lossy, so WAV would be eight times bigger and no better. The sheet stays open, so you can add several.
2. Each song is split into **vocals, melody, drums and bass** by HTDemucs v4, running locally through Core ML. Passable then finds its tempo, beat 1, key, and bar-by-bar structure and loudness.
3. When all songs are ready, Passable orders them. It minimises tempo stretch, prefers compatible keys, keeps the energy building, and favours pairs whose sections line up. **Auto-Order** re-runs this; drag rows to override.
4. Every transition is planned from the two songs alone:
   - **Where:** B's next section (ideally its chorus or drop) lands as A leaves. Energy stays level, with no chorus into a quiet intro and no breakdown or fade-out inside the blend. Vocals hand over instead of clashing.
   - **How:** exactly one kick and one bass line at a time. B enters with its low end killed, and the lows swap on one downbeat, as late as B's drop when B is still building. Clashing keys swap melodies instead of layering them. Tempos more than 6 % apart use Echo Out.
   - **Levels:** every song's loud sections are matched (trim), so nothing jumps.
   - **Tempo:** B is matched to A only while they overlap, then glides home and plays untouched. Stretching is sample-exact: a phase-locked vocoder for tonal stems, with the original drum hits copied onto their new positions.
5. **Listen** plays from four bars before a transition. **Edit** opens it in the Transition tab.

## Transition tab

Shows the transition that's playing, or the one you picked with **Edit**: both songs' 8 stem lanes with **volume, DJ filter, 3-band EQ (with kill), reverb send and delay send** automation. Click a lane to add a point and drag to move it; points snap to the beat unless you hold ⌥. Right-click a point to change its curve or delete it. Scroll to pan; pinch or ⌘-scroll to zoom. You can also move where the transition sits, switch the preset or length, shift B's key, or fix a song's beat grid from its **Grid** menu.

Any change goes straight into the set and unticks **Automatic**. Tick it again to return to the automatic transition. Undo and redo (⌘Z / ⇧⌘Z) cover your edits. Mute and solo apply to the set's playback.

One transport serves both tabs: **Space** plays or pauses, **Return** cues the open transition, **⌘→** (or the keyboard's ⏭ key) jumps to just before the next transition, **⌘←** (⏮) goes back to the start of the current song's transition, and twice quickly to the one before. The ⏯ ⏮ ⏭ keys, headphone buttons and Control Center work while Passable is in the background. **Render** writes the whole set, or just this transition, as an AAC `.m4a` (256 kbps): the songs are already AAC, so a WAV would be ten times bigger and sound the same. Type a `.wav` name to get a 24-bit, 44.1 kHz WAV for other software. The set and your edits are remembered between launches.

## Set files (.passable)

**Set File → Export Set…** (⇧⌘E) saves the set as one `.passable` file with every song inside it, so it opens on any Mac. **Open Set…** (⇧⌘O), dragging the file onto the set, or double-clicking it in Finder brings it back: songs unpack into `~/Music/Passable` (a copy that's already there is reused), in the saved order, with your hand-shaped transitions and each song's analysis, so beat grids are exactly as they were. Stems are separated again on a new Mac.

The format is a small chunked container: magic `PASSABLE\r\n\x1A\n`, a version, then chunks (`MNFT` JSON manifest, one `AUDI` per song, `END `). PCM songs are stored as Apple Lossless: bit-identical, about half the size. The full layout is documented in `Passable/Model/PassableFile.swift`.

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
| `Passable/Audio` | decoding/resampling, mmap'd stems, time map + sample-exact stretcher (phase vocoder, transient copy, sinc resampler) |
| `Passable/DSP` | mixer, biquads, Freeverb, ping-pong delay, limiter: shared by preview and render |
| `Passable/Model` | automation envelopes, presets, session |
| `Passable/UI` | SwiftUI: decks, transition panel, timeline, search |

Measurement harnesses (skipped unless their variable is set; `xcodebuild` only passes variables prefixed with `TEST_RUNNER_`), each taking a file with one path per line:

- `TEST_RUNNER_PASSABLE_SET=list.txt xcodebuild test -scheme Passable -only-testing:PassableTests/SetLab` builds a set from the songs, prints the order, measures every transition (level change, dips, doubled low end, clashing vocals) and renders `~/Music/Passable/Lab/Set.wav`.
- `TEST_RUNNER_PASSABLE_LAB=list.txt … -only-testing:PassableTests/TransitionLab` does the same for consecutive pairs through the editor's pipeline.
- `TEST_RUNNER_PASSABLE_PACK=list.txt TEST_RUNNER_PASSABLE_PACK_OUT=set.passable … -only-testing:PassableTests/SetPack` orders the songs as the Set tab does and packs them into a `.passable` file.
- `TEST_RUNNER_PASSABLE_PROBE=list.txt … -only-testing:PassableTests/RealTrackProbe` prints analysis and placement.
