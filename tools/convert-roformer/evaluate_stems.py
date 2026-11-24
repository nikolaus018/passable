"""Score four-stem separations against the true stems (MUSDB18 test excerpts).

Each model separates every test excerpt (the 7-second MUSDB18 sample set,
`musdb.DB(download=True)`); each of drums, bass, other and vocals is scored
by its SDR against the true stem: 10 log10 of the true stem's energy over
the error's, over the whole excerpt, both channels (as evaluate.py does for
the voice). Excerpts where a true stem is near silent are left out for that
stem. Prints the median per stem and model, and how often each model wins.

Models:
  htdemucs   HTDemucs v4 (what Passable's drums, bass and other come from)
  sw         BS-RoFormer SW (6 stems; its guitar and piano added to other)
  kim        Kim's Mel-Band RoFormer (vocals only: Passable's voice)

Usage:  .venv/bin/python evaluate_stems.py [--root ~/MUSDB18-7] [--models htdemucs,sw]
"""

import argparse
import os
import sys

import numpy as np
import torch
import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
STEMS = ["drums", "bass", "other", "vocals"]


def sdr(true, est):
    n = min(true.shape[-1], est.shape[-1])
    true, est = true[..., :n], est[..., :n]
    return 10 * np.log10((np.sum(true ** 2) + 1e-9) / (np.sum((true - est) ** 2) + 1e-9))


def device():
    # (EVAL_CPU=1: the CPU, when the Mac's GPU memory is taken.)
    if os.environ.get("EVAL_CPU"):
        return torch.device("cpu")
    return torch.device("mps") if torch.backends.mps.is_available() else torch.device("cpu")


class HTDemucs:
    def __init__(self):
        from demucs.pretrained import get_model
        self.model = get_model("htdemucs").eval()

    def __call__(self, mix):
        from demucs.apply import apply_model
        x = torch.from_numpy(mix).float()
        ref = x.mean(0)
        x = (x - ref.mean()) / ref.std()
        with torch.no_grad():
            out = apply_model(self.model, x[None], split=True, overlap=0.25, device=device())[0].cpu()
        out = out * ref.std() + ref.mean()
        return {name: out[i].numpy() for i, name in enumerate(self.model.sources)}


class SW:
    def __init__(self, ckpt="BS-Rofo-SW-Fixed.ckpt", config="BS-Rofo-SW-Fixed.yaml"):
        sys.path.insert(0, os.path.join(HERE, "msst"))
        from models.bs_roformer.bs_roformer import BSRoformer
        with open(os.path.join(HERE, config)) as f:
            cfg = yaml.load(f, Loader=yaml.FullLoader)
        self.instruments = cfg["training"]["instruments"]
        self.model = BSRoformer(**cfg["model"])
        state = torch.load(os.path.join(HERE, ckpt), map_location="cpu", weights_only=False)
        if "state_dict" in state:
            state = state["state_dict"]
        self.model.load_state_dict(state)
        self.model.eval().to(device())

    def __call__(self, mix):
        with torch.no_grad():
            out = self.model(torch.from_numpy(mix).float()[None].to(device()))[0].cpu().numpy()
        stems = {name: out[i] for i, name in enumerate(self.instruments)}
        stems["other"] = stems["other"] + stems.get("guitar", 0) + stems.get("piano", 0)
        return stems


class Kim:
    """Kim's Mel-Band RoFormer (vocals only): what Passable's voice is now."""

    def __init__(self):
        sys.path.insert(0, os.path.join(HERE, "upstream"))
        from models.mel_band_roformer import MelBandRoformer
        with open(os.path.join(HERE, "upstream/configs/config_vocals_mel_band_roformer.yaml")) as f:
            cfg = yaml.load(f, Loader=yaml.FullLoader)
        self.model = MelBandRoformer(**cfg["model"])
        self.model.load_state_dict(torch.load(os.path.join(HERE, "MelBandRoformer.ckpt"), map_location="cpu"))
        self.model.eval()

    def __call__(self, mix):
        with torch.no_grad():
            v = self.model(torch.from_numpy(mix).float()[None])[0].numpy()
        nan = np.full_like(mix, np.nan)
        return {"vocals": v, "drums": nan, "bass": nan, "other": nan}


class HTDemucsFTBass:
    """HTDemucs' fine-tuned bass model (htdemucs_ft's bass member): bass only."""

    def __init__(self):
        from demucs.states import load_model
        pkg = torch.load(os.path.join(HERE, "vox", "htdemucs_ft_bass.th"), map_location="cpu", weights_only=False)
        self.model = load_model(pkg).eval()

    def __call__(self, mix):
        from demucs.apply import apply_model
        x = torch.from_numpy(mix).float()
        ref = x.mean(0)
        x = (x - ref.mean()) / ref.std()
        with torch.no_grad():
            out = apply_model(self.model, x[None], split=True, overlap=0.25, device=device())[0].cpu()
        out = out * ref.std() + ref.mean()
        stems = {name: out[i].numpy() for i, name in enumerate(self.model.sources)}
        nan = np.full_like(mix, np.nan)
        return {"bass": stems["bass"], "drums": nan, "other": nan, "vocals": nan}


class SCNet:
    """SCNet XL IHF (ZFTurbo, trained on MUSDB18HQ's training songs), with the
    framework's own chunked inference."""

    def __init__(self):
        sys.path.insert(0, os.path.join(HERE, "msst"))
        from utils.settings import get_model_from_config
        self.model, self.config = get_model_from_config("scnet", os.environ.get("SCNET_CONFIG") or os.path.join(HERE, "vox", "scnet_xl_ihf.yaml"))
        state = torch.load(os.path.join(HERE, "vox", "scnet_xl_ihf.ckpt"), map_location="cpu", weights_only=True)
        self.model.load_state_dict(state.get("state_dict", state))
        self.model.eval().to(device())

    def __call__(self, mix):
        from utils.model_utils import demix
        out = demix(self.config, self.model, torch.from_numpy(mix), device(), model_type="scnet", pbar=False)
        return {k: out[k] for k in ["drums", "bass", "other", "vocals"]}


class VocalModel:
    """A one-stem vocal model from vox/ (weights only: nothing in the file runs)."""

    def __init__(self, ckpt, config, mel):
        sys.path.insert(0, os.path.join(HERE, "msst"))
        if mel:
            from models.bs_roformer.mel_band_roformer import MelBandRoformer as Model
        else:
            from models.bs_roformer.bs_roformer import BSRoformer as Model
        with open(os.path.join(HERE, "vox", config)) as f:
            cfg = yaml.load(f, Loader=yaml.FullLoader)
        self.model = Model(**cfg["model"])
        state = torch.load(os.path.join(HERE, "vox", ckpt), map_location="cpu", weights_only=True)
        if "state_dict" in state:
            state = state["state_dict"]
        self.model.load_state_dict(state)
        # (Metal has no complex scatter, which the Mel models use.)
        self.device = torch.device("cpu") if mel else device()
        self.model.eval().to(self.device)

    def __call__(self, mix):
        with torch.no_grad():
            v = self.model(torch.from_numpy(mix).float()[None].to(self.device))[0].cpu().numpy()
        if v.ndim == 3:
            v = v[0]
        nan = np.full_like(mix, np.nan)
        return {"vocals": v, "drums": nan, "bass": nan, "other": nan}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=os.path.expanduser("~/MUSDB18-7"))
    parser.add_argument("--models", default="htdemucs,sw")
    parser.add_argument("--limit", type=int, default=0)
    parser.add_argument("--dump", default="", help="save each model's vocals per excerpt here (for blends)")
    args = parser.parse_args()
    import musdb
    db = musdb.DB(root=args.root, subsets="test")
    tracks = list(db)[: args.limit or None]
    makers = {"htdemucs": HTDemucs, "sw": SW, "kim": Kim,
              "viperx": lambda: VocalModel("viperx.ckpt", "viperx.yaml", mel=False),
              "bigbeta": lambda: VocalModel("bigbeta.ckpt", "bigbeta.yaml", mel=True),
              "scnet": SCNet, "htft_bass": HTDemucsFTBass}
    names = args.models.split(",")
    scores = {m: {s: [] for s in STEMS} for m in names}
    for m in names:
        model = makers[m]()
        for k, track in enumerate(tracks):
            mix = track.audio.T.astype(np.float32)
            est = model(mix)
            if args.dump:
                os.makedirs(args.dump, exist_ok=True)
                np.save(os.path.join(args.dump, f"{m}-{k}.npy"), est["vocals"].astype(np.float32))
                np.save(os.path.join(args.dump, f"true-{k}.npy"), track.targets["vocals"].audio.T.astype(np.float32))
                for st in ["drums", "bass", "other"]:
                    if not np.isnan(est[st]).any():
                        np.save(os.path.join(args.dump, f"{m}.{st}-{k}.npy"), est[st].astype(np.float32))
                        np.save(os.path.join(args.dump, f"true.{st}-{k}.npy"), track.targets[st].audio.T.astype(np.float32))
            for s in STEMS:
                true = track.targets[s].audio.T.astype(np.float32)
                ok = np.sqrt(np.mean(true ** 2)) > 1e-3 and not np.isnan(est[s]).any()
                scores[m][s].append(sdr(true, est[s]) if ok else np.nan)
            print(f"{m} {k + 1}/{len(tracks)} {track.name}: "
                  + " ".join(f"{s} {scores[m][s][-1]:.1f}" for s in STEMS), flush=True)
        del model
    print()
    for s in STEMS:
        line = f"{s:7s}"
        for m in names:
            line += f"  {m} median {np.nanmedian(scores[m][s]):5.2f} mean {np.nanmean(scores[m][s]):5.2f}"
        if len(names) == 2:
            a, b = np.array(scores[names[0]][s]), np.array(scores[names[1]][s])
            ok = ~np.isnan(a) & ~np.isnan(b)
            line += f"  {names[1]} better on {int(np.sum(b[ok] > a[ok]))}/{int(np.sum(ok))}"
        print(line)


if __name__ == "__main__":
    main()
