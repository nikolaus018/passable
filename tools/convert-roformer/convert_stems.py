"""Export BS-RoFormer SW (six stems) to Core ML for Passable.

Passable's drums, bass and melody came from HTDemucs v4; on the MUSDB18 test
excerpts this model is closer to the true stems (evaluate_stems.py). It
separates vocals, drums, bass, guitar, piano and other: Passable keeps
drums and bass, and its melody is other, guitar and piano together.

Like convert.py, the STFT, the masking and the inverse STFT are left to
Swift (Core ML has no complex tensors). Every frequency bin belongs to one
band here (band-split, not mel), so the masks need no averaging. The
exported network takes

  spec  [1, 2050, FRAMES, 2]   torch.stft of a stereo chunk (n_fft 2048,
                               hop 512, periodic Hann, centred,
                               reflect-padded, not normalised), frequency-
                               major with the channels interleaved
                               (bin*2 + channel), real and imaginary last

and returns

  masks [1, 6, FRAMES, 2050, 2] the complex mask of every (bin, channel),
                               per stem in `instruments` order (metadata)

The model zeroes the DC bin after masking; Swift does too.

Usage:  .venv/bin/python convert_stems.py [--chunk 588800] [--fp32] [--out ../../Passable/Resources]
        [--ckpt FILE --config FILE --name NAME]   another band-split RoFormer the
        same way (a one-stem model gives its target instrument). A lead-vocal
        (karaoke) and a de-reverb model were tried as voices to place cuts by:
        the set measured worse with them (cuts on the lead's breaths went
        through backing voices and reverb still sounding), so they're unused.
        So was DrumSep (MDX23C, kick apart from the kit so B's whole kit could
        layer under A's beat): blends came out louder, the set scored worse
        (tools/score/score.py, 15 songs, both orders), at ~37 s more a song.
Weights: BS-Rofo-SW-Fixed.ckpt and .yaml (jarredou's BS-RoFormer SW, as
mirrored at huggingface.co/ChanTrail/BS-RoFormer); code in msst/ from
github.com/ZFTurbo/Music-Source-Separation-Training (MIT).
"""

import argparse
import os
import sys
import time

import numpy as np
import torch
import yaml
import coremltools as ct

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "msst"))

from models.bs_roformer.bs_roformer import BSRoformer  # noqa: E402
from models.bs_roformer import attend as attend_module  # noqa: E402

N_FFT, HOP = 2048, 512


def plain_attention(self, q, k, v):
    scale = q.shape[-1] ** -0.5
    return torch.softmax(torch.matmul(q, k.transpose(-1, -2)) * scale, dim=-1) @ v


class Masks(torch.nn.Module):
    """The model between its STFT and its masking."""

    def __init__(self, model):
        super().__init__()
        self.m = model

    def forward(self, spec):
        m = self.m
        b, f, t, c = spec.shape
        x = spec.permute(0, 2, 1, 3).reshape(b, t, f * c)    # b t (f c)
        x = m.band_split(x)                                   # b t bands d
        for time_transformer, freq_transformer in m.layers:
            bands, d = x.shape[2], x.shape[3]
            x = x.permute(0, 2, 1, 3).reshape(b * bands, t, d)
            x = time_transformer(x)
            x = x.reshape(b, bands, t, d).permute(0, 2, 1, 3).reshape(b * t, bands, d)
            x = freq_transformer(x)
            x = x.reshape(b, t, bands, d)
        x = m.final_norm(x)
        masks = torch.stack([fn(x) for fn in m.mask_estimators], dim=1)   # b n t (f c)
        return masks.reshape(b, len(m.mask_estimators), t, f, 2)


def load(ckpt, config_path):
    with open(os.path.join(HERE, config_path)) as f:
        config = yaml.load(f, Loader=yaml.FullLoader)
    model = BSRoformer(**config["model"])
    state = torch.load(os.path.join(HERE, ckpt), map_location="cpu", weights_only=False)
    model.load_state_dict(state.get("state_dict", state))
    training = config["training"]
    # (A one-stem model separates its target instrument.)
    stems = training["instruments"] if config["model"].get("num_stems", 1) > 1 else [training["target_instrument"]]
    return model.eval(), stems, config["model"].get("stft_hop_length", 512)


def spectrogram(audio):
    """[2, chunk] → [1, 2050, frames, 2], as the model's own forward makes it."""
    s = torch.stft(audio, n_fft=N_FFT, hop_length=HOP, win_length=N_FFT, window=torch.hann_window(N_FFT),
                   normalized=False, return_complex=True)               # 2 f t
    s = torch.view_as_real(s).permute(1, 0, 2, 3)                       # f 2 t c
    return s.reshape(1, -1, s.shape[2], 2)


def apply(spec, masks, length):
    """What Swift does with the masks: multiply, zero DC, inverse STFT. → [n, 2, length]"""
    s = torch.view_as_complex(spec[0].contiguous())                      # (f s) t
    out = []
    for n in range(masks.shape[1]):
        m = torch.view_as_complex(masks[0, n].permute(1, 0, 2).contiguous())   # (f s) t
        y = (s * m).reshape(-1, 2, s.shape[-1]).permute(1, 0, 2).clone()       # s f t
        y[:, 0] = 0
        out.append(torch.istft(y, n_fft=N_FFT, hop_length=HOP, win_length=N_FFT,
                               window=torch.hann_window(N_FFT), length=length))
    return torch.stack(out)


def db(err, ref):
    return 10 * np.log10((err.pow(2).sum() / ref.pow(2).sum()).item() + 1e-30)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--chunk", type=int, default=588_800)
    p.add_argument("--ckpt", default="BS-Rofo-SW-Fixed.ckpt")
    p.add_argument("--config", default="BS-Rofo-SW-Fixed.yaml")
    p.add_argument("--name", default="StemRoformer")
    p.add_argument("--fp32", action="store_true")
    p.add_argument("--out", default=os.path.join(HERE, "../../Passable/Resources"))
    args = p.parse_args()

    attend_module.Attend.forward = plain_attention
    global HOP
    model, instruments, HOP = load(args.ckpt, args.config)
    net = Masks(model).eval()

    torch.manual_seed(0)
    audio = 0.1 * torch.randn(2, args.chunk)
    spec = spectrogram(audio)
    with torch.no_grad():
        reference = model(audio.unsqueeze(0))[0]                         # n 2 t
        traced = torch.jit.trace(net, spec)
        mine = apply(spec, traced(spec), args.chunk)
    print(f"wrapper vs model: {db(reference - mine, reference):.1f} dB")

    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="spec", shape=spec.shape)],
        outputs=[ct.TensorType(name="masks")],
        compute_precision=ct.precision.FLOAT32 if args.fp32 else ct.precision.FLOAT16,
        compute_units=ct.ComputeUnit.CPU_AND_GPU,
        minimum_deployment_target=ct.target.macOS14,
    )
    mlmodel.short_description = f"BS-RoFormer ({args.name}): complex masks per (bin, channel) for {', '.join(instruments)}"
    mlmodel.user_defined_metadata["instruments"] = ",".join(instruments)
    mlmodel.user_defined_metadata["n_fft"] = str(N_FFT)
    mlmodel.user_defined_metadata["hop"] = str(HOP)
    mlmodel.user_defined_metadata["chunk"] = str(args.chunk)
    out = os.path.join(args.out, f"{args.name}.mlpackage")
    mlmodel.save(out)
    print("saved", out)

    started = time.time()
    got = mlmodel.predict({"spec": spec.numpy()})["masks"]
    print(f"Core ML prediction: {time.time() - started:.1f} s for {args.chunk / 44100:.1f} s of audio")
    mine = apply(spec, torch.from_numpy(got.astype(np.float32)), args.chunk)
    for n, name in enumerate(instruments):
        print(f"Core ML vs model, {name}: {db(reference[n] - mine[n], reference[n]):.1f} dB")


if __name__ == "__main__":
    main()
