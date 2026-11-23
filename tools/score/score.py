#!/usr/bin/env python3
"""One number for a set: every defect passable-render can measure, counted
and weighted by how bad it is, so two versions of the planner can be
compared on the same songs instead of by ear.

    tools/score/score.py run  [--bin PATH] [--out DIR] [--fixed] [--models DIR] LIST   measure a set
    tools/score/score.py show DIR                               its score again
    tools/score/score.py diff DIR_A DIR_B                       what changed

LIST is a file of song paths (one per line, `#` comments), as for
`passable-render --list`; the set is ordered by Auto-Order (`--order`), or
with `--fixed` played as listed: two versions then judge the same pairs
(ordered, a change to a price can reshuffle the whole set).
Every song must have been loaded once (stems and analysis cached).

The score is a weighted count of defects (lower is better, 0 is a set
with nothing measurable wrong). It compares versions; it is not a grade.
Each mode's full output is kept in DIR, so a change in the score can be
traced to the transitions that caused it (their ROW/CROW/VOICE lines).
Stdlib only.
"""
import os
import re
import subprocess
import sys
import time

MODES = ["report", "vocals", "clicks", "steps", "shifts"]

# (metric, weight, why). Weights put a defect anyone hears (a click, a
# word cut in two at full volume) far above one only a measurement sees.
WEIGHTS = [
    ("clicks_over_0", 10, "a switch louder than the music around it"),
    ("clicks_over_-10", 3, "a switch within 10 dB of the music"),
    ("steps_chopped", 2, "a hit or note cut at its attack"),
    ("steps_through_held", 0.25, "a hard switch inside a held note (heard only if --clicks says so)"),
    ("vocal_overlap_beats", 1, "beats two singers sing at once"),
    ("vocal_gaps_over_bar", 3, "handovers with over a bar nobody sings"),
    ("a_mid_sentence", 2, "A's voice cut mid-sentence"),
    ("b_mid_part", 2, "B's voice in mid-part"),
    ("words_cut_a", 3, "A's words cut in two"),
    ("words_cut_b", 3, "B's words cut in two"),
    ("words_cut_full_a", 5, "A's words cut in two at full voice"),
    ("words_cut_full_b", 5, "B's words cut in two at full voice"),
    ("voice_steps_over_4db", 2, "a voice level jump over 4 dB at a handover"),
    ("excess_over_2db", 3, "a blend over 2 dB louder than its songs"),
    ("dips_over_4db", 2, "a blend dip over 4 dB"),
    ("drops_over_6db", 3, "a bar-to-bar drop over 6 dB"),
    ("together_under_4", 1, "a blend the two songs share under 4 bars"),
    ("busy_bars", 0.5, "bars with too much going on at once"),
    ("after_under_4db", 2, "B left over 4 dB under its level after the blend"),
    ("stretch_over_4pct", 2, "a song played over 4 % off its tempo"),
    ("key_shifted", 0.5, "a song played off its key"),
]

PATTERNS = {
    "report": [
        (r"^SET (\d+) transitions: .*?over 2 dB: (\d+) \| .*?under 4: (\d+) \| dips over 4 dB: (\d+), "
         r"bar-to-bar drops over 6 dB: (\d+) \| busy bars (\d+) \| .*over 4 dB: (\d+)",
         ["transitions", "excess_over_2db", "together_under_4", "dips_over_4db", "drops_over_6db", "busy_bars",
          "after_under_4db"]),
    ],
    "vocals": [
        (r"^VOICE LEVEL .*over 4 dB: (\d+)", ["voice_steps_over_4db"]),
        (r"^VOCALS (\d+) handovers: overlap (\d+) beats, longest gap (\d+) beats, gaps over a bar (\d+), "
         r"A cut mid-sentence (\d+), B in mid-part (\d+), words cut in two: A (\d+), B (\d+) \(at full: A (\d+), B (\d+)\)",
         ["handovers", "vocal_overlap_beats", "vocal_longest_gap", "vocal_gaps_over_bar", "a_mid_sentence", "b_mid_part",
          "words_cut_a", "words_cut_b", "words_cut_full_a", "words_cut_full_b"]),
    ],
    "clicks": [
        (r"^CLICKS (\d+) switches .*?over 0 dB (\d+), over -10 dB (\d+), over -20 dB (\d+)",
         ["switches", "clicks_over_0", "clicks_over_-10", "clicks_over_-20"]),
    ],
    "steps": [
        (r"^steps (\d+), chopped (\d+)(?:, through a held sound (\d+))?", ["steps", "steps_chopped", "steps_through_held"]),
    ],
    "shifts": [
        (r"^SHIFTS .*over 4%: (\d+) \| key shifted: (\d+)", ["stretch_over_4pct", "key_shifted"]),
    ],
}


def parse(folder):
    metrics = {}
    for mode in MODES:
        path = os.path.join(folder, mode + ".txt")
        if not os.path.exists(path):
            continue
        text = open(path, encoding="utf-8", errors="replace").read().splitlines()
        for pattern, names in PATTERNS[mode]:
            for line in text:
                m = re.search(pattern, line)
                if m:
                    for name, value in zip(names, m.groups()):
                        if value is not None:
                            metrics[name] = float(value)
                    break
    # "over -10 dB" counts those over 0 dB as well: weigh each once.
    if "clicks_over_-10" in metrics and "clicks_over_0" in metrics:
        metrics["clicks_over_-10"] -= metrics["clicks_over_0"]
    return metrics


def score(metrics):
    total, parts = 0.0, []
    for name, weight, why in WEIGHTS:
        value = metrics.get(name)
        if value is None:
            continue
        total += weight * value
        if value:
            parts.append((weight * value, name, value, why))
    return total, sorted(parts, reverse=True)


def show(folder):
    metrics = parse(folder)
    if not metrics:
        sys.exit(f"nothing measured in {folder}")
    total, parts = score(metrics)
    print(f"{folder}: score {total:.1f} over {int(metrics.get('transitions', 0))} transitions")
    for points, name, value, why in parts:
        print(f"  {points:6.1f}  {name:22s} {value:5.0f}  {why}")
    return total, metrics


def run(args):
    binary, out, fixed, models = ".build/release/passable-render", None, False, []
    while args and args[0].startswith("--"):
        flag = args.pop(0)
        if flag == "--bin":
            binary = args.pop(0)
        elif flag == "--out":
            out = args.pop(0)
        elif flag == "--fixed":
            fixed = True
        elif flag == "--models":
            models = ["--models", args.pop(0)]
        else:
            sys.exit(f"unknown option {flag}")
    if len(args) != 1:
        sys.exit(__doc__)
    songs = args[0]
    out = out or os.path.join("render-out", "score-" + time.strftime("%Y%m%d-%H%M%S"))
    os.makedirs(out, exist_ok=True)
    for mode in MODES:
        started = time.time()
        with open(os.path.join(out, mode + ".txt"), "w") as f:
            order = [] if fixed else ["--order"]
            code = subprocess.call([binary, *order, *models, "--list", songs, "--" + mode], stdout=f, stderr=subprocess.STDOUT)
        print(f"  {mode}: {time.time() - started:.0f} s" + ("" if code == 0 else f" (exit {code})"), flush=True)
    show(out)


def diff(a, b):
    ta, ma = show(a)
    tb, mb = show(b)
    print(f"\nscore {ta:.1f} -> {tb:.1f} ({tb - ta:+.1f})")
    for name, weight, why in WEIGHTS:
        va, vb = ma.get(name, 0), mb.get(name, 0)
        if va != vb:
            print(f"  {name:22s} {va:5.0f} -> {vb:5.0f}  ({weight * (vb - va):+6.1f})  {why}")


if __name__ == "__main__":
    argv = sys.argv[1:]
    if not argv:
        sys.exit(__doc__)
    command = argv.pop(0)
    if command == "run":
        run(argv)
    elif command == "show" and len(argv) == 1:
        show(argv[0])
    elif command == "diff" and len(argv) == 2:
        diff(*argv)
    else:
        sys.exit(__doc__)
