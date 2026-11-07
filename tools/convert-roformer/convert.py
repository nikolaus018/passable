"""Export Kim's Mel-Band RoFormer (vocals) to Core ML for Passable.

Passable takes its vocal stem from this model and its drums, bass and other
from HTDemucs (see Passable/Separation/VocalSeparator.swift): on the MUSDB18
test excerpts its vocal is 2.9 dB closer to the true one (median SDR 11.5 dB
against HTDemucs' 8.9; better on 49 of 50 songs, evaluate.py).

Core ML has no complex tensors, and the model's mask averaging is a scatter
over complex numbers, so the STFT, the averaging, the masking and the iSTFT
are left to Swift. The exported network takes

  spec  [1, 2050, 801, 2]   torch.stft of an 8 s stereo chunk (352,800
                            samples at 44.1 kHz; n_fft 2048, hop 441, periodic
                            Hann, centred, reflect-padded, not normalised),
                            frequency-major with the channels interleaved
                            (bin*2 + channel), real and imaginary last

and returns

  masks [1, 801, BANDED, 2] the complex mask of every (bin, channel) each
                            mel band covers, bands in order, as
                            `freq_indices` (in the package's metadata) lists
                            them; a bin in several bands gets the mean.

Attention is written out (matmul, softmax) rather than PyTorch's fused op,
which Core ML only takes from macOS 15: the app runs on 14.

Usage:  .venv/bin/python convert.py [--fp32] [--out ../../Passable/Resources]
Weights: MelBandRoformer.ckpt from huggingface.co/KimberleyJSN/melbandroformer
(MIT), code in upstream/ from github.com/KimberleyJensen/Mel-Band-Roformer-Vocal-Model.
"""

import argparse
import os
import sys

import numpy as np
import torch
import torch.nn.functional as F
import yaml
import coremltools as ct

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "upstream"))

from models.mel_band_roformer import MelBandRoformer  # noqa: E402
from models.mel_band_roformer import attend as attend_module  # noqa: E402

CHUNK = 352_800
N_FFT, HOP = 2048, 441


def plain_attention(self, q, k, v):
    scale = q.shape[-1] ** -0.5
    return torch.softmax(torch.matmul(q, k.transpose(-1, -2)) * scale, dim=-1) @ v


class Masks(torch.nn.Module):
    """The model between its STFT and its mask averaging."""

    def __init__(self, model):
        super().__init__()
        self.m = model

    def forward(self, spec):
        m = self.m
        x = spec[:, m.freq_indices]                       # b f t c
        b, f, t, c = x.shape
        x = x.permute(0, 2, 1, 3).reshape(b, t, f * c)    # b t (f c)
        x = m.band_split(x)                               # b t bands d
        for time_transformer, freq_transformer in m.layers:
            bands, d = x.shape[2], x.shape[3]
            x = x.permute(0, 2, 1, 3).reshape(b * bands, t, d)
            x = time_transformer(x)
            x = x.reshape(b, bands, t, d).permute(0, 2, 1, 3).reshape(b * t, bands, d)
            x = freq_transformer(x)
            x = x.reshape(b, t, bands, d)
        masks = m.mask_estimators[0](x)                   # b t (f c)
        return masks.reshape(b, t, f, 2)


def load():
    with open(os.path.join(HERE, "upstream/configs/config_vocals_mel_band_roformer.yaml")) as f:
        config = yaml.load(f, Loader=yaml.FullLoader)
    model = MelBandRoformer(**config["model"])
    model.load_state_dict(torch.load(os.path.join(HERE, "MelBandRoformer.ckpt"), map_location="cpu"))
    return model.eval()


def spectrogram(audio):
    """[2, CHUNK] → [1, 2050, 801, 2], as the model's own forward makes it."""
    s = torch.stft(audio, n_fft=N_FFT, hop_length=HOP, win_length=N_FFT, window=torch.hann_window(N_FFT),
                   normalized=False, return_complex=True)               # 2 f t
    s = torch.view_as_real(s).permute(1, 0, 2, 3)                       # f 2 t c
    return s.reshape(1, -1, s.shape[2], 2)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--fp32", action="store_true")
    p.add_argument("--out", default=os.path.join(HERE, "../../Passable/Resources"))
    args = p.parse_args()

    attend_module.Attend.forward = plain_attention
    model = load()
    net = Masks(model).eval()

    torch.manual_seed(0)
    audio = 0.1 * torch.randn(2, CHUNK)
    spec = spectrogram(audio)
    with torch.no_grad():
        # (Against the model's own forward: masks applied by hand must give
        # what it gives.)
        reference = model(audio.unsqueeze(0))[0]
        traced = torch.jit.trace(net, spec)
        masks = traced(spec)
        mine = apply(model, spec, masks)
    err = (reference - mine).pow(2).sum() / reference.pow(2).sum()
    print(f"wrapper vs model: {10 * np.log10(err.item() + 1e-30):.1f} dB")

    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="spec", shape=spec.shape)],
        outputs=[ct.TensorType(name="masks")],
        compute_precision=ct.precision.FLOAT32 if args.fp32 else ct.precision.FLOAT16,
        compute_units=ct.ComputeUnit.CPU_AND_GPU,
        minimum_deployment_target=ct.target.macOS14,
    )
    mlmodel.short_description = "Mel-Band RoFormer (Kim, vocals): complex masks per mel band"
    mlmodel.user_defined_metadata["freq_indices"] = ",".join(str(i) for i in model.freq_indices.tolist())
    mlmodel.user_defined_metadata["n_fft"] = str(N_FFT)
    mlmodel.user_defined_metadata["hop"] = str(HOP)
    mlmodel.user_defined_metadata["chunk"] = str(CHUNK)
    out = os.path.join(args.out, "VocalRoformer.mlpackage")
    mlmodel.save(out)
    print("saved", out)

    got = torch.from_numpy(mlmodel.predict({"spec": spec.numpy()})["masks"].astype(np.float32))
    mine = apply(model, spec, got)
    err = (reference - mine).pow(2).sum() / reference.pow(2).sum()
    print(f"Core ML vs model: {10 * np.log10(err.item() + 1e-30):.1f} dB")


def apply(model, spec, masks):
    """What Swift does with the masks: average per (bin, channel), multiply,
    inverse STFT. → [2, CHUNK]"""
    idx = model.freq_indices
    total = torch.zeros(spec.shape[1], spec.shape[2], 2)
    total.index_add_(0, idx, masks[0].permute(1, 0, 2))
    count = torch.zeros(spec.shape[1]).index_add_(0, idx, torch.ones(len(idx)))
    mask = torch.view_as_complex(total / count.clamp(min=1)[:, None, None])
    s = torch.view_as_complex(spec[0].contiguous()) * mask                 # (f s) t
    s = s.reshape(-1, 2, s.shape[-1]).permute(1, 0, 2)                    # s f t
    return torch.istft(s, n_fft=N_FFT, hop_length=HOP, win_length=N_FFT, window=torch.hann_window(N_FFT))


if __name__ == "__main__":
    main()
