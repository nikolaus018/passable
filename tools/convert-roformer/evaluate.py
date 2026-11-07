"""Score vocal stems against true ones (MUSDB18 test excerpts).

For each song folder in --truth (mixture.wav, vocals.wav at 44.1 kHz):
  - Passable's vocal stem as it separates it today (`passable-render
    --dump-vocals DIR`: vocals.L.f32 / vocals.R.f32 per song folder),
  - Mel-Band RoFormer's, in PyTorch (or another dump with --other),
and the SDR of each against the true vocal: 10 log10 of the true vocal's
energy over the error's, over the whole excerpt, both channels. Songs
whose true vocal is near silent are left out (no voice to separate).

Usage:
  .venv/bin/python evaluate.py --truth DIR --passable DIR [--other DIR]
"""

import argparse
import os
import sys

import numpy as np
import soundfile as sf
import torch
import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "upstream"))


def sdr(true, est):
    n = min(true.shape[-1], est.shape[-1])
    true, est = true[..., :n], est[..., :n]
    return 10 * np.log10((np.sum(true ** 2) + 1e-9) / (np.sum((true - est) ** 2) + 1e-9))


def load_roformer(device):
    from models.mel_band_roformer import MelBandRoformer

    with open(os.path.join(HERE, "upstream/configs/config_vocals_mel_band_roformer.yaml")) as f:
        config = yaml.load(f, Loader=yaml.FullLoader)
    model = MelBandRoformer(**config["model"])
    state = torch.load(os.path.join(HERE, "MelBandRoformer.ckpt"), map_location="cpu")
    model.load_state_dict(state)
    return model.eval().to(device), config["inference"]


def roformer_vocals(model, inference, mix, device):
    """Upstream's demix_track: chunks of 8 s, half overlapping, faded."""
    size, step = inference["chunk_size"], inference["chunk_size"] // inference["num_overlap"]
    fade = size // 10
    total = mix.shape[1]
    window = torch.ones(size)
    window[:fade] = torch.linspace(0, 1, fade)
    window[-fade:] = torch.linspace(1, 0, fade)
    out = torch.zeros_like(mix)
    weight = torch.zeros(total)
    with torch.no_grad():
        i = 0
        while i < total:
            part = mix[:, i:i + size]
            length = part.shape[-1]
            if length < size:
                mode = "reflect" if length > size // 2 + 1 else "constant"
                part = torch.nn.functional.pad(part, (0, size - length), mode=mode)
            y = model(part.unsqueeze(0).to(device))[0].cpu()
            w = window.clone()
            if i == 0:
                w[:fade] = 1
            if i + size >= total:
                w[-fade:] = 1
            out[:, i:i + length] += y[:, :length] * w[:length]
            weight[i:i + length] += w[:length]
            i += step
    return (out / weight.clamp(min=1e-8)).numpy()


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--truth", required=True)
    p.add_argument("--passable", required=True)
    p.add_argument("--other", help="another dump to score instead of running the RoFormer")
    args = p.parse_args()

    device = "cpu"  # (MPS has no complex scatter, which the model's mask averaging needs)
    model = inference = None
    if not args.other:
        model, inference = load_roformer(device)

    def dump(root, name):
        d = os.path.join(root, name)
        return np.stack([np.fromfile(os.path.join(d, f"vocals.{c}.f32"), dtype=np.float32) for c in "LR"])

    rows = []
    for name in sorted(os.listdir(args.truth)):
        folder = os.path.join(args.truth, name)
        if not os.path.isdir(folder) or not os.path.isdir(os.path.join(args.passable, name)):
            continue
        true, rate = sf.read(os.path.join(folder, "vocals.wav"), dtype="float32", always_2d=True)
        true = true.T
        if np.sqrt(np.mean(true ** 2)) < 1e-3:
            continue
        mine = dump(args.passable, name)
        if args.other:
            theirs = dump(args.other, name)
        else:
            mix, _ = sf.read(os.path.join(folder, "mixture.wav"), dtype="float32", always_2d=True)
            theirs = roformer_vocals(model, inference, torch.from_numpy(mix.T.copy()), device)
        rows.append((name, sdr(true, mine), sdr(true, theirs)))
        print(f"{rows[-1][1]:6.2f} {rows[-1][2]:6.2f}  {name}", flush=True)

    a = np.array([r[1] for r in rows]); b = np.array([r[2] for r in rows])
    print(f"\n{len(rows)} songs with a voice. Vocal SDR, median (mean):")
    print(f"  Passable today  {np.median(a):6.2f} dB ({a.mean():.2f})")
    print(f"  {'other' if args.other else 'Mel-RoFormer':15s} {np.median(b):6.2f} dB ({b.mean():.2f})")
    print(f"  better on {int(np.sum(b > a))} of {len(rows)}, median gain {np.median(b - a):+.2f} dB")


if __name__ == "__main__":
    main()
