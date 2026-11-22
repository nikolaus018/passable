# Converting All-In-One Structure Segmentation to Core ML

Exports Taejun Kim & Juhan Nam's [All-In-One](https://github.com/mir-aidj/all-in-one) (MIT) 4-stem functional structure segmentation model to `Passable/Resources/Structure.mlpackage` (~5 MB FP16).

## Setup

```bash
cd tools/convert-structure
git clone --depth 1 https://github.com/mir-aidj/all-in-one upstream
uv venv .venv
uv pip install --python .venv/bin/python torch==2.5.1 "numpy<2" coremltools==8.1 huggingface_hub omegaconf hydra-core timm
.venv/bin/python convert.py
```

When `Structure.mlpackage` is bundled into the app, `StructureAnalyzer.shared` automatically segments loaded songs into `intro`, `verse`, `chorus`, `bridge`, `break`, `inst`, `solo`, and `outro` using Passable's existing 4 stems, feeding neural section edges and chorus payoffs into `AutoPlacement`. When absent, Passable falls back cleanly to its heuristic structure measures.
