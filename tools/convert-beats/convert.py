"""Export the Beat This! beat and downbeat tracker (Foscarin, Schlüter and
Widmer, ISMIR 2024; MIT) to a Core ML package for Passable.

Core ML has no complex tensors, so the STFT is done in Swift (Accelerate,
see Passable/Analysis/BeatTracker.swift). The exported network takes

  spect [1, 1500, 513]   30 s of magnitude spectrogram frames at 50 per
                         second: 22.05 kHz mono, 1024-sample periodic Hann
                         window, hop 441, centred (reflect padding),
                         magnitudes divided by 32 (the square root of the window length)

applies the mel filterbank and log scaling the model was trained with, and
returns

  beat     [1, 1500]     logits: a beat in this frame
  downbeat [1, 1500]     logits: a downbeat in this frame

Usage:  .venv/bin/python convert.py [--checkpoint final0] [--out ../../Passable/Resources]
        (writes fixtures for the Swift tests to ./fixtures as well)
"""

import argparse
import os

import numpy as np
import torch
import torchaudio
import coremltools as ct
from beat_this.inference import load_model, split_predict_aggregate
from beat_this.preprocessing import LogMelSpect

CHUNK = 1500
BINS = 513


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


class Wrapped(torch.nn.Module):
    """Magnitude spectrogram in, logits out: the mel filterbank and the log
    scaling live in the graph, so Swift only has to get an STFT right."""

    def __init__(self, model):
        super().__init__()
        self.model = model
        fbank = torchaudio.functional.melscale_fbanks(
            n_freqs=BINS, f_min=30, f_max=11000, n_mels=128, sample_rate=22050, norm=None, mel_scale="slaney")
        self.register_buffer("fbank", fbank)

    def forward(self, spect):
        mel = torch.log1p(1000 * torch.matmul(spect, self.fbank))
        out = self.model(mel)
        return out["beat"], out["downbeat"]


def magnitudes(signal):
    """What Swift computes: |STFT| / sqrt(1024), frames first."""
    stft = torch.stft(signal, n_fft=1024, hop_length=441, window=torch.hann_window(1024), center=True,
                      pad_mode="reflect", return_complex=True)
    return (stft.abs() / 32).T


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--checkpoint", default="final0")
    parser.add_argument("--out", default="../../Passable/Resources")
    args = parser.parse_args()

    patch_coremltools_cast()
    model = Wrapped(load_model(args.checkpoint, "cpu")).eval()

    # A test signal with a beat: clicks at 120 BPM over a quiet tone.
    sr = 22050
    t = torch.arange(CHUNK * 441 - 1) / sr
    signal = 0.05 * torch.sin(2 * torch.pi * 220 * t)
    for k in range(60):
        i = int(k * 0.5 * sr) + 2000
        signal[i:i + 400] += torch.hann_window(400) * torch.sin(2 * torch.pi * (80 if k % 4 == 0 else 160) * t[:400]) * 0.8
        signal[i:i + 60] += torch.randn(60) * 0.3
    spect = magnitudes(signal)[:CHUNK].unsqueeze(0)
    assert spect.shape == (1, CHUNK, BINS), spect.shape

    # The wrapper has to agree with the library's own preprocessing.
    with torch.no_grad():
        reference = model.model(LogMelSpect()(signal)[:CHUNK].unsqueeze(0))
        beat, downbeat = model(spect)
    print("wrapper vs library, max logit difference:", float((reference["beat"] - beat).abs().max()))

    with torch.no_grad():
        traced = torch.jit.trace(model, spect, check_trace=False)
        again = traced(spect)
    print("traced vs eager, max logit difference:", float((again[0] - beat).abs().max()))

    ml = ct.convert(
        traced,
        inputs=[ct.TensorType(name="spect", shape=spect.shape, dtype=np.float32)],
        outputs=[ct.TensorType(name="beat"), ct.TensorType(name="downbeat")],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT32,
        minimum_deployment_target=ct.target.macOS14,
    )
    ml.short_description = "Beat This! beat and downbeat tracker (CPJKU, MIT), mel filterbank included"
    ml.user_defined_metadata["chunk"] = str(CHUNK)
    os.makedirs(args.out, exist_ok=True)
    path = os.path.join(args.out, "BeatThis.mlpackage")
    ml.save(path)
    print("saved", path)

    predicted = ml.predict({"spect": spect.numpy()})
    print("Core ML vs torch, max logit difference: beat",
          float(np.abs(predicted["beat"] - beat.numpy()).max()),
          "downbeat", float(np.abs(predicted["downbeat"] - downbeat.numpy()).max()))

    # For the Swift tests: the signal (resampling aside, at the model's own
    # rate), and what the library makes of it, chunked as it chunks a song.
    with torch.no_grad():
        whole = split_predict_aggregate(LogMelSpect()(signal), chunk_size=CHUNK, border_size=6,
                                        overlap_mode="keep_first", model=model.model)
    os.makedirs("fixtures", exist_ok=True)
    signal.numpy().astype("<f4").tofile("fixtures/signal22k.f32")
    spect[0].numpy().astype("<f4").tofile("fixtures/spect.f32")
    whole["beat"].numpy().astype("<f4").tofile("fixtures/beat.f32")
    whole["downbeat"].numpy().astype("<f4").tofile("fixtures/downbeat.f32")
    print("beats in the fixture (frames):", torch.nonzero(whole["beat"] > 0).flatten().tolist()[:24])


if __name__ == "__main__":
    main()
