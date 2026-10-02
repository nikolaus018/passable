"""Second opinion on a set's transitions, from a beat tracker that knows
nothing of Passable's own beat grids.

SetLab (with PASSABLE_SET_AUDIT=<folder>) writes every transition as two
files (the outgoing song alone and the incoming one alone, as they play
through it) and a list of where each song's own time lands in the set.
This runs Beat This! on the songs themselves, places the beats it hears in
the set, and says whether the two songs' beats coincide through each blend,
whether their bars do (the incoming song's one on the outgoing song's one),
and whether either drifts. It tracks the two rendered files as well: what
the tracker hears in the audio that plays. A transition is objected to when
neither way of listening finds the two songs on one beat (through a blend
one song is filtered and thinned, and now and then the tracker loses it
there; a song it follows poorly as a whole it may still follow there).

Usage:  ../convert-beats/.venv/bin/python audit.py <folder>
"""

import json
import os
import subprocess
import sys
import tempfile

import numpy as np
import soundfile as sf
import torch
from beat_this.inference import Audio2Beats


def grid(beats):
    """Period and phase of the steady pulse through `beats` (a line through
    beat number against time, outliers dropped), or None."""
    if len(beats) < 6:
        return None
    gaps = np.diff(beats)
    period = np.median(gaps)
    index = np.cumsum(np.concatenate([[0], np.round(gaps / period)]))
    keep = np.ones(len(beats), bool)
    slope = intercept = None
    for _ in range(3):
        if keep.sum() < 4:
            return None
        slope, intercept = np.polyfit(index[keep], beats[keep], 1)
        keep = np.abs(beats - (slope * index + intercept)) < 0.06
    return slope, intercept


def compare(a, da, b, db, t):
    """How song B's beats sit on song A's through the blend: (text, flags)."""
    bar, start, end = t["barSeconds"], t["start"], t["end"]
    ga = grid(a[(a > start - bar) & (a < end)])
    inside = b[(b >= start - 0.05) & (b <= end + 0.05)]
    gb = grid(inside)
    if ga is None or gb is None:
        return "no beat heard in " + ("A" if ga is None else "B"), ["NO BEAT HEARD"]
    (pa, ia), (pb, _) = ga, gb
    ratio = pb / pa
    unit = pa / 2 if ratio < 0.75 else pa
    offsets = ((inside - ia) / unit + 0.5) % 1.0 - 0.5
    middle = np.median(offsets)
    median, spread = middle * unit * 1000, np.median(np.abs(offsets - middle)) * unit * 1000
    half = len(offsets) // 2
    drift = (np.median(offsets[half:]) - np.median(offsets[:half])) * unit * 1000 if half >= 3 else 0.0
    flags = []
    if not any(abs(np.log2(ratio * k)) < 0.03 for k in (0.5, 1, 2)):
        flags.append(f"TWO TEMPOS ({60 / pa:.1f} against {60 / pb:.1f})")
    else:
        if abs(median) > 35:
            flags.append("BEATS APART")
        if spread > 45:
            flags.append("NO COMMON PULSE")
        if abs(drift) > 40:
            flags.append("DRIFTING")

    def ones(downbeats, lo, hi):
        d = downbeats[(downbeats > lo) & (downbeats < hi)]
        return np.bincount(np.round((d - ia) / pa).astype(int) % 4, minlength=4)

    ca, cb = ones(da, start - 8 * bar, start + t["switch"] * bar + 0.1), ones(db, start - 0.1, end + 0.1)
    bars = ""
    if ca.sum() >= 2 and cb.sum() >= 2:
        oa, ob = int(np.argmax(ca)), int(np.argmax(cb))
        if oa != ob and ca[oa] >= 0.6 * ca.sum() and cb[ob] >= 0.6 * cb.sum():
            flags.append(f"BARS OFF BY {(ob - oa) % 4} BEATS")
        bars = f", ones on A's beats {list(map(int, ca))} / {list(map(int, cb))}"
    return f"{median:+4.0f} ms ±{spread:.0f}, drift {drift:+.0f}, {60 / pa:.1f}/{60 / pb:.1f} BPM{bars}", flags


def main(folder):
    # (The CPU is quick enough for this, and never short of memory.)
    device = os.environ.get("AUDIT_DEVICE", "cpu")
    tracker = Audio2Beats(checkpoint_path="final0", device=device, dbn=False)
    transitions = json.load(open(os.path.join(folder, "transitions.json")))

    songs = {}

    def song(path):
        """Beats and downbeats of a whole song file, in its own seconds."""
        if path not in songs:
            with tempfile.TemporaryDirectory() as tmp:
                wav = os.path.join(tmp, "song.wav")
                subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", path, "-ac", "1", "-ar", "22050", wav], check=True)
                audio, rate = sf.read(wav, dtype="float32")
            beats, downbeats = tracker(audio, rate)
            songs[path] = (np.asarray(beats), np.asarray(downbeats))
        return songs[path]

    def placed(path, warp):
        """A song's beats where they play in the set."""
        warp = np.asarray(warp)
        out = []
        for times in song(path):
            inside = times[(times >= warp[0, 0]) & (times <= warp[-1, 0])]
            out.append(np.interp(inside, warp[:, 0], warp[:, 1]))
        return out

    flagged = 0
    for t in transitions:
        bar, start, end = t["barSeconds"], t["start"], t["end"]
        head = f"{t['index']:2d} {t['at']:>6}  {t['preset']:<10} {t['bars']:2d} bars  {t['a'][:26]:26} → {t['b'][:26]:26}"
        a, da = placed(t["pathA"], t["warpA"])
        b, db = placed(t["pathB"], t["warpB"])
        if end - start < bar:
            # A Wash Out: nothing overlaps. The incoming song's first bar
            # should start where the transition says it does.
            near = db[np.abs(db - start) < 0.5 * bar]
            off = (near[np.argmin(np.abs(near - start))] - start) * 1000 if len(near) else None
            bad = off is None or abs(off) > 80
            flagged += bad
            print(f"{head}\n      no overlap; B's nearest one {'%+.0f ms' % off if off is not None else 'not found'}"
                  + ("  B'S ONE NOT ON ITS ENTRY" if bad else ""))
            continue
        text, flags = compare(a, da, b, db, t)
        heard = {}
        for side in "ab":
            audio, rate = sf.read(os.path.join(folder, f"{t['index']:02d}-{side}.wav"), dtype="float32")
            beats, downbeats = tracker(audio, rate)
            heard[side] = (np.asarray(beats) + t["from"], np.asarray(downbeats) + t["from"])
        text2, flags2 = compare(*heard["a"], *heard["b"], t)
        bad = bool(flags) and bool(flags2)
        flagged += bad
        print(f"{head}" + ("  <<< " + ", ".join(flags) if bad else "")
              + f"\n      songs' beats placed in the set: {text}" + ("  (" + ", ".join(flags).lower() + ")" if flags else "")
              + f"\n      heard in the rendered blend:    {text2}" + ("  (" + ", ".join(flags2).lower() + ")" if flags2 else ""))
    print(f"Transitions the tracker objects to: {flagged} of {len(transitions)}")


if __name__ == "__main__":
    main(sys.argv[1])
