"""Export HTDemucs (4 stems) to a Core ML package for Passable.

Core ML has no complex tensors, so the STFT/iSTFT that wrap HTDemucs are
stripped out and done in Swift (Accelerate). The exported network takes:

  mix  [1, 2, SEGMENT]            raw stereo segment at 44.1 kHz
  spec [1, 4, 2048, FRAMES]       CaC spectrogram: channels = (L.re, L.im, R.re, R.im)

and returns

  wave [1, 4, 2, SEGMENT]         time-branch output per stem
  spec_out [1, 16, 2048, FRAMES]  frequency-branch output, CaC per stem
                                  (stem-major: stem*4 + chan*2 + re/im)

The stem waveform is  wave + istft(spec_out). Swift must reproduce
`HTDemucs._spec` / `_ispec` exactly (see Passable/Separation/STFT.swift).

The network runs in FP16 on the GPU: twice as fast as FP32, with stems within
48 dB of it (the difference at least 58 dB under the mix) and the same beat
grids to the millisecond (PassableTests/PrecisionLab). Keeping the
normalisation or the convolutions in FP32 buys back almost nothing: the
difference is spread over the whole network. The Neural Engine's compiler
rejects the graph at any precision. --fp32 exports the exact one.

Usage:  .venv/bin/python convert.py [--fp32] [--out ../../Passable/Resources]
Test fixtures: .venv/bin/python make_fixtures.py
"""

import argparse
import math
import os

import numpy as np
import torch
import coremltools as ct
from demucs.pretrained import get_model

SOURCES = ["drums", "bass", "other", "vocals"]


def patch_coremltools_cast():
    """coremltools' int()/bool() cast calls int(ndarray) on shape-(1,) consts,
    which NumPy 2 rejects. Unwrap single-element arrays first."""
    from coremltools.converters.mil.frontend.torch import ops
    original = ops._cast

    def _cast(context, node, dtype, dtype_name):
        x = ops._get_inputs(context, node, expected=1)[0]
        if x.can_be_folded_to_const() and isinstance(x.val, np.ndarray) and x.val.size == 1:
            context.add(ops.mb.const(val=dtype(x.val.reshape(()).item()), name=node.name), node.name)
            return
        original(context, node, dtype, dtype_name)

    ops._cast = _cast


def freeze_positional_embeddings():
    """The transformer builds its sin/cos embeddings from tensor shapes at run
    time, which traces into shape arithmetic Core ML can't convert. Shapes are
    fixed for a fixed segment, so cache each embedding from the eager warm-up
    run and hand the tracer the cached tensor, which becomes a constant."""
    from demucs import transformer as tr
    cache = {}

    def wrap(fn):
        def inner(*args, **kwargs):
            key = (fn.__name__,) + tuple(int(a) if isinstance(a, (int, torch.Tensor)) else a
                                         for a in args if not isinstance(a, torch.device))
            if key not in cache:
                cache[key] = fn(*[int(a) if isinstance(a, torch.Tensor) else a for a in args], **kwargs).detach()
            return cache[key]
        return inner

    for name in ("create_2d_sin_embedding", "create_sin_embedding", "create_sin_embedding_cape"):
        setattr(tr, name, wrap(getattr(tr, name)))


class Core(torch.nn.Module):
    """HTDemucs.forward minus _spec/_magnitude/_mask/_ispec."""

    def __init__(self, m):
        super().__init__()
        self.m = m

    def forward(self, mix, mag):
        m = self.m
        x = mag
        B, C, Fq, T = x.shape
        mean = x.mean(dim=(1, 2, 3), keepdim=True)
        std = x.std(dim=(1, 2, 3), keepdim=True)
        x = (x - mean) / (1e-5 + std)

        xt = mix
        meant = xt.mean(dim=(1, 2), keepdim=True)
        stdt = xt.std(dim=(1, 2), keepdim=True)
        xt = (xt - meant) / (1e-5 + stdt)

        saved, saved_t, lengths, lengths_t = [], [], [], []
        for idx, encode in enumerate(m.encoder):
            lengths.append(x.shape[-1])
            inject = None
            if idx < len(m.tencoder):
                lengths_t.append(xt.shape[-1])
                tenc = m.tencoder[idx]
                xt = tenc(xt)
                if not tenc.empty:
                    saved_t.append(xt)
                else:
                    inject = xt
            x = encode(x, inject)
            if idx == 0 and m.freq_emb is not None:
                frs = torch.arange(x.shape[-2], device=x.device)
                emb = m.freq_emb(frs).t()[None, :, :, None].expand_as(x)
                x = x + m.freq_emb_scale * emb
            saved.append(x)

        if m.crosstransformer:
            if m.bottom_channels:
                b, c, f, t = x.shape
                x = x.reshape(b, c, f * t)
                x = m.channel_upsampler(x)
                x = x.reshape(b, -1, f, t)
                xt = m.channel_upsampler_t(xt)
            x, xt = m.crosstransformer(x, xt)
            if m.bottom_channels:
                b, c, f, t = x.shape
                x = x.reshape(b, c, f * t)
                x = m.channel_downsampler(x)
                x = x.reshape(b, -1, f, t)
                xt = m.channel_downsampler_t(xt)

        for idx, decode in enumerate(m.decoder):
            skip = saved.pop(-1)
            x, pre = decode(x, skip, lengths.pop(-1))
            offset = m.depth - len(m.tdecoder)
            if idx >= offset:
                tdec = m.tdecoder[idx - offset]
                length_t = lengths_t.pop(-1)
                if tdec.empty:
                    pre = pre[:, :, 0]
                    xt, _ = tdec(pre, None, length_t)
                else:
                    skip = saved_t.pop(-1)
                    xt, _ = tdec(xt, skip, length_t)

        S = len(m.sources)
        x = x.view(B, S, -1, Fq, T)
        x = x * std[:, None] + mean[:, None]
        x = x.reshape(B, S * 4, Fq, T)
        xt = xt.view(B, S, -1, mix.shape[-1])
        xt = xt * stdt[:, None] + meant[:, None]
        return xt, x


def reference_split(m, mix):
    """The pieces of HTDemucs.forward that Swift reimplements, for checking."""
    z = m._spec(mix)
    mag = m._magnitude(z)
    return z, mag


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fp32", action="store_true")
    ap.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "..", "..", "Passable", "Resources"))
    args = ap.parse_args()

    freeze_positional_embeddings()
    patch_coremltools_cast()
    # The fused attention kernel has no Core ML mapping; the plain path does.
    torch.backends.mha.set_fastpath_enabled(False)
    bag = get_model("htdemucs")
    m = bag.models[0].eval()
    assert list(m.sources) == SOURCES, m.sources
    segment = int(m.segment * m.samplerate)
    frames = int(math.ceil(segment / m.hop_length))
    print(f"segment={segment} samples, frames={frames}, nfft={m.nfft}")

    torch.manual_seed(0)
    mix = torch.randn(1, 2, segment) * 0.1
    with torch.no_grad():
        _, mag = reference_split(m, mix)
        core = Core(m).eval()
        # Sanity: wrapper + torch STFT == original forward.
        wave, spec = core(mix, mag)
        z = torch.view_as_complex(spec.view(1, 4, 2, 2, m.nfft // 2, frames).permute(0, 1, 2, 4, 5, 3).contiguous())
        full = wave + m._ispec(z, segment)
        ref = m(mix)
        print("wrapper vs original max err:", (full - ref).abs().max().item())

        traced = torch.jit.trace(core, (mix, mag), check_trace=False)

    precision = ct.precision.FLOAT32 if args.fp32 else ct.precision.FLOAT16
    ml = ct.convert(
        traced,
        inputs=[ct.TensorType(name="mix", shape=mix.shape, dtype=np.float32),
                ct.TensorType(name="spec", shape=mag.shape, dtype=np.float32)],
        outputs=[ct.TensorType(name="wave", dtype=np.float32),
                 ct.TensorType(name="spec_out", dtype=np.float32)],
        convert_to="mlprogram",
        compute_precision=precision,
        minimum_deployment_target=ct.target.macOS14,
    )
    ml.short_description = "HTDemucs v4 core (4 stems: drums, bass, other, vocals). STFT done by host."
    ml.user_defined_metadata.update({
        "sources": ",".join(SOURCES), "samplerate": str(m.samplerate),
        "segment": str(segment), "frames": str(frames),
        "nfft": str(m.nfft), "hop": str(m.hop_length),
    })

    out = ml.predict({"mix": mix.numpy(), "spec": mag.numpy()})
    print("coreml wave err:", np.abs(out["wave"] - wave.numpy()).max(),
          "spec err:", np.abs(out["spec_out"] - spec.numpy()).max())

    os.makedirs(args.out, exist_ok=True)
    path = os.path.join(args.out, "HTDemucs.mlpackage")
    ml.save(path)
    print("saved", os.path.abspath(path))


if __name__ == "__main__":
    main()
