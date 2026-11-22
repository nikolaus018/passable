"""Export mir-aidj/all-in-one (MIT) music structure analyzer to Core ML.

All-In-One jointly predicts frame-level section boundaries and 10 functional
section labels (start, end, intro, outro, break, bridge, inst, solo, verse,
chorus) at 100 FPS directly from the 4 stems Passable already separates
(bass, drums, other, vocals).

Because Core ML has no native `natten` (Neighborhood Attention) op, this script
replaces `natten1dqkrpb`/`natten1dav` and `natten2dqkrpb`/`natten2dav` with
exact pure-PyTorch traceable dilated local attention before exporting to
macOS 14 FP16 Core ML (`Structure.mlpackage`, ~5 MB).

Usage:
  uv venv .venv && uv pip install --python .venv/bin/python torch==2.5.1 "numpy<2" coremltools==8.1 huggingface_hub omegaconf hydra-core timm
  .venv/bin/python convert.py [--model harmonix-fold0] [--frames 42000] [--out ../../Passable/Resources]
"""

import argparse
import os
import sys

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
import coremltools as ct

HERE = os.path.dirname(os.path.abspath(__file__))

HARMONIX_LABELS = [
    "start", "end", "intro", "outro", "break",
    "bridge", "inst", "solo", "verse", "chorus",
]


def _window(length: int, kernel_size: int, dilation: int, device):
    """NATTEN's neighbourhood of every query: positions [L, K] and their
    relative-position-bias index [L, K].

    Queries are split by residue class mod `dilation`; within each class the
    K-wide window is centred on the query and shifted inward at the ends, so
    a neighbour is always in the query's own class."""
    # (In NumPy: the export's shapes are fixed, so these trace as constants
    # instead of integer ops Core ML can't type.)
    length = int(length)
    nh = kernel_size // 2
    i = np.arange(length)
    r = i % dilation
    g = i // dilation
    group_len = (length - r + dilation - 1) // dilation
    start = np.minimum(np.maximum(g - nh, 0), np.maximum(group_len - kernel_size, 0))
    j = np.arange(kernel_size)
    slot = start[:, None] + j[None, :]                      # index inside the class
    pos = np.minimum(r[:, None] + slot * dilation, length - 1)
    bias = np.clip(slot - g[:, None] + kernel_size - 1, 0, 2 * kernel_size - 2)
    return torch.as_tensor(pos, device=device), torch.as_tensor(bias, device=device)


def _take(x, dim: int, index):
    """`x.index_select(dim, index)` from slices and repeats wherever `index`
    runs on or stands still (almost everywhere: only a window's ends jump),
    so a 42000-frame export doesn't store a table per neighbour."""
    idx = index.cpu().numpy()
    if len(idx) < 64:
        return x.index_select(dim, index)
    steps = np.diff(idx)
    cuts = np.flatnonzero((steps[1:] != steps[:-1]) | ~np.isin(steps[1:], [0, 1])) + 2
    cuts = np.concatenate([[0], cuts[cuts < len(idx)], [len(idx)]])
    parts, loose = [], []
    def flush():
        if loose:
            parts.append(x.index_select(dim, torch.as_tensor(loose, device=index.device)))
            loose.clear()
    for lo, hi in zip(cuts[:-1], cuts[1:]):
        lo, hi = int(lo), int(hi)
        run = idx[lo:hi]
        if hi - lo >= 8 and (run == run[0]).all():
            flush()
            one = x.narrow(dim, int(run[0]), 1)
            parts.append(one.repeat(*[hi - lo if d == dim else 1 for d in range(x.dim())]))
        elif hi - lo >= 8 and (np.diff(run) == 1).all():
            flush()
            parts.append(x.narrow(dim, int(run[0]), hi - lo))
        else:
            loose.extend(int(v) for v in run)
    flush()
    return parts[0] if len(parts) == 1 else torch.cat(parts, dim=dim)


def _live(rpb, q):
    """The bias table, tied to the input by a zero: Core ML folds anything
    built from weights alone into a stored constant, and this one expanded
    over 42000 frames per layer is what made the model 250 MB."""
    return rpb + 0 * q.flatten()[0]


def natten1d_qk_rpb(q, k, rpb, kernel_size: int, dilation: int):
    """`natten1dqkrpb`: q, k [B, H, L, D], rpb [H, 2K-1] -> [B, H, L, K]."""
    pos, bias = _window(q.shape[2], kernel_size, dilation, q.device)
    rpb = _live(rpb, q)
    scores = [(q * _take(k, 2, pos[:, a])).sum(dim=-1) + _take(rpb, 1, bias[:, a]).unsqueeze(0)
              for a in range(kernel_size)]
    return torch.stack(scores, dim=-1)


def natten1d_av(attn, v, kernel_size: int, dilation: int):
    """`natten1dav`: attn [B, H, L, K], v [B, H, L, D] -> [B, H, L, D]."""
    pos, _ = _window(v.shape[2], kernel_size, dilation, v.device)
    out = 0
    for a in range(kernel_size):
        out = out + attn[:, :, :, a].unsqueeze(-1) * _take(v, 2, pos[:, a])
    return out


def natten2d_qk_rpb(q, k, rpb, kernel_size: int, dilation: int):
    """`natten2dqkrpb`: q, k [B, H, X, Y, D], rpb [H, 2K-1, 2K-1] -> [B, H, X, Y, K*K]
    (neighbours row-major: X offset outer, Y offset inner). One neighbour at a
    time: Core ML stops at rank 5."""
    px, bx = _window(q.shape[2], kernel_size, dilation, q.device)
    py, by = _window(q.shape[3], kernel_size, dilation, q.device)
    rpb = _live(rpb, q)
    scores = []
    for a in range(kernel_size):
        along_x = _take(k, 2, px[:, a])
        bias_x = _take(rpb, 1, bx[:, a])
        for b in range(kernel_size):
            bias = _take(bias_x, 2, by[:, b])                # [H, X, Y]
            scores.append((q * _take(along_x, 3, py[:, b])).sum(dim=-1) + bias.unsqueeze(0))
    return torch.stack(scores, dim=-1)


def natten2d_av(attn, v, kernel_size: int, dilation: int):
    px, _ = _window(v.shape[2], kernel_size, dilation, v.device)
    py, _ = _window(v.shape[3], kernel_size, dilation, v.device)
    out = 0
    for a in range(kernel_size):
        along_x = _take(v, 2, px[:, a])
        for b in range(kernel_size):
            weight = attn[:, :, :, :, a * kernel_size + b].unsqueeze(-1)
            out = out + weight * _take(along_x, 3, py[:, b])
    return out


class StructureWrapper(nn.Module):
    """Wraps AllInOne to emit sigmoid section boundaries `[1, T]` and softmax
    functional label probabilities `[1, 10, T]`."""

    def __init__(self, model: nn.Module):
        super().__init__()
        self.model = model

    def forward(self, spec: torch.Tensor):
        out = self.model(spec)
        section = torch.sigmoid(out.logits_section)
        function = torch.softmax(out.logits_function, dim=1)
        return section, function


def patch_natten():
    """Install a pure-PyTorch `natten.functional` shim before importing allin1."""
    import types
    natten = types.ModuleType("natten")
    functional = types.ModuleType("natten.functional")
    functional.natten1dqkrpb = natten1d_qk_rpb
    functional.natten1dav = natten1d_av
    functional.natten2dqkrpb = natten2d_qk_rpb
    functional.natten2dav = natten2d_av
    natten.functional = functional
    sys.modules["natten"] = natten
    sys.modules["natten.functional"] = functional


NAME_TO_FILE = {
    "harmonix-fold0": "harmonix-fold0-0vra4ys2.pth",
    "harmonix-fold1": "harmonix-fold1-3ozjhtsj.pth",
    "harmonix-fold2": "harmonix-fold2-gmgo0nsy.pth",
    "harmonix-fold3": "harmonix-fold3-i92b7m8p.pth",
    "harmonix-fold4": "harmonix-fold4-1bql5qo0.pth",
    "harmonix-fold5": "harmonix-fold5-x4z5zeef.pth",
    "harmonix-fold6": "harmonix-fold6-x7t226rq.pth",
    "harmonix-fold7": "harmonix-fold7-qwwskhg6.pth",
}


def load_allinone(model_name: str):
    pkg = os.path.join(HERE, "upstream", "src", "allin1")
    if not os.path.isdir(pkg):
        raise SystemExit(
            f"Missing {pkg}. Clone https://github.com/mir-aidj/all-in-one into {os.path.join(HERE, 'upstream')} first."
        )
    patch_natten()
    # The package's __init__ pulls in demucs and madmom for its own pipeline;
    # only the model is needed, so the package is registered without it.
    import types
    allin1 = types.ModuleType("allin1")
    allin1.__path__ = [pkg]
    sys.modules["allin1"] = allin1
    from huggingface_hub import hf_hub_download
    from omegaconf import OmegaConf
    from allin1.models.allinone import AllInOne

    path = hf_hub_download(repo_id="taejunkim/allinone", filename=NAME_TO_FILE[model_name])
    # (Weights only: a checkpoint is a pickle, and a full load can run code.)
    ckpt = torch.load(path, map_location="cpu", weights_only=True)
    model = AllInOne(OmegaConf.create(ckpt["config"]))
    model.load_state_dict(ckpt["state_dict"])
    return model.eval()


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--model", default="harmonix-fold0", help="All-In-One checkpoint name on taejunkim/allinone")
    p.add_argument("--frames", type=int, default=42000, help="Fixed time frames (42000 = 420 s at 100 FPS)")
    p.add_argument("--fp32", action="store_true")
    p.add_argument("--out", default=os.path.join(HERE, "../../Passable/Resources"))
    args = p.parse_args()

    model = load_allinone(args.model)
    wrapper = StructureWrapper(model).eval()

    torch.manual_seed(0)
    sample = torch.rand(1, 4, args.frames, 81)
    with torch.no_grad():
        ref_sec, ref_fn = wrapper(sample)
        traced = torch.jit.trace(wrapper, sample)

    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="spec", shape=sample.shape)],
        outputs=[ct.TensorType(name="section"), ct.TensorType(name="function")],
        compute_precision=ct.precision.FLOAT32 if args.fp32 else ct.precision.FLOAT16,
        compute_units=ct.ComputeUnit.CPU_AND_GPU,
        minimum_deployment_target=ct.target.macOS14,
    )
    mlmodel.short_description = f"All-In-One ({args.model}, MIT): 4-stem music structure segmentation"
    mlmodel.user_defined_metadata["labels"] = ",".join(HARMONIX_LABELS)
    mlmodel.user_defined_metadata["stems"] = "bass,drums,other,vocals"
    mlmodel.user_defined_metadata["fps"] = "100"
    mlmodel.user_defined_metadata["n_fft"] = "2048"
    mlmodel.user_defined_metadata["hop"] = "441"
    mlmodel.user_defined_metadata["fixed_frames"] = str(args.frames)
    os.makedirs(args.out, exist_ok=True)
    out = os.path.join(args.out, "Structure.mlpackage")
    mlmodel.save(out)
    print("saved", out)

    got = mlmodel.predict({"spec": sample.numpy()})
    sec_err = np.abs(ref_sec.numpy() - got["section"]).max()
    fn_err = np.abs(ref_fn.numpy() - got["function"]).max()
    print(f"Core ML max abs diff: section={sec_err:.4f}, function={fn_err:.4f}")


if __name__ == "__main__":
    main()
