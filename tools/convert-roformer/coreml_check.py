"""The exported VocalRoformer.mlpackage on real songs: vocal SDR against the
true stems (MUSDB18 excerpts), as evaluate.py scores PyTorch, and the time
Core ML takes per 8 s chunk.

Usage: .venv/bin/python coreml_check.py --truth DIR --model PATH.mlpackage
"""

import argparse
import os
import time

import numpy as np
import soundfile as sf
import torch
import coremltools as ct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from convert import CHUNK, spectrogram, apply, load
from evaluate import sdr


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--truth", required=True)
    p.add_argument("--model", required=True)
    args = p.parse_args()
    ml = ct.models.MLModel(args.model, compute_units=ct.ComputeUnit.CPU_AND_GPU)
    model = load()
    scores, times = [], []
    for name in sorted(os.listdir(args.truth)):
        folder = os.path.join(args.truth, name)
        if not os.path.isdir(folder):
            continue
        true, _ = sf.read(os.path.join(folder, "vocals.wav"), dtype="float32", always_2d=True)
        if np.sqrt(np.mean(true ** 2)) < 1e-3:
            continue
        mix, _ = sf.read(os.path.join(folder, "mixture.wav"), dtype="float32", always_2d=True)
        x = torch.from_numpy(mix.T.copy())
        n = x.shape[1]
        x = torch.nn.functional.pad(x, (0, CHUNK - n), mode="reflect")   # one chunk: the excerpts are 7 s
        spec = spectrogram(x)
        t = time.time()
        masks = ml.predict({"spec": spec.numpy()})["masks"]
        times.append(time.time() - t)
        with torch.no_grad():
            est = apply(model, spec, torch.from_numpy(masks.astype(np.float32)))[:, :n].numpy()
        scores.append(sdr(true.T, est))
        print(f"{scores[-1]:6.2f}  {times[-1] * 1000:5.0f} ms  {name}", flush=True)
    print(f"\nCore ML vocal SDR median {np.median(scores):.2f} dB (mean {np.mean(scores):.2f}), "
          f"{np.median(times[1:]) * 1000:.0f} ms per 8 s chunk")


if __name__ == "__main__":
    main()
