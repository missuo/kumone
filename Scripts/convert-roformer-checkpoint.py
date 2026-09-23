#!/usr/bin/env python3
"""Convert a ZFTurbo BS-/Mel-Band RoFormer `.ckpt` into StemKit's safetensors layout.

**Why this script exists at all.** StemKit loads safetensors through MLX, and
every published four-stem RoFormer checkpoint is a PyTorch pickle — there is, as
of this writing, no four-stem conversion on Hugging Face for anyone to point a
URL at. Kumone never redistributes weights (LGPL-3.0-only: the binary carries a
manifest, not a model), so the file is fetched from its original host by
`Scripts/fetch-4stem-checkpoint.sh` and converted *here*, on the user's machine,
by their own torch.

Two transformations, both of which `StemKit.WeightLoader` cannot do itself
because MLX has no notion of them:

  - `to_qkv.weight [3·dim_inner, dim]` is split into `to_q/to_k/to_v.weight`.
    lucidrains packs the three projections into one Linear; the Swift model has
    three, because splitting once at conversion time is free and splitting on
    every forward pass is not.
  - fp32 → fp16. The checkpoint trains in fp32 and the parity work behind
    `RoFormerConfiguration.halfPrecisionCompute` established that fp16 *storage*
    with fp32 compute is where this architecture's accuracy actually sits.

`to_out.0.weight` is deliberately left wrapped: `WeightLoader.sanitize` unwraps
it at load, and doing it twice would be two places to keep in step.

Usage:
    python3 Scripts/convert-roformer-checkpoint.py IN.ckpt OUT.safetensors
"""

import sys
from collections import OrderedDict

try:
    import torch
    from safetensors.torch import save_file
except ImportError:
    sys.exit(
        "error: this script needs torch and safetensors.\n"
        "  python3 -m venv /tmp/roformer && /tmp/roformer/bin/pip install torch safetensors\n"
        "  /tmp/roformer/bin/python Scripts/convert-roformer-checkpoint.py ..."
    )


def convert(source: str, destination: str) -> None:
    state = torch.load(source, map_location="cpu", weights_only=True)
    # ZFTurbo release checkpoints are a bare OrderedDict; fine-tunes from other
    # hands sometimes wrap it. Accept both rather than making the caller look.
    for wrapper in ("state_dict", "model", "model_state_dict"):
        if isinstance(state, dict) and wrapper in state and isinstance(state[wrapper], dict):
            state = state[wrapper]
            break
    if not isinstance(state, (dict, OrderedDict)):
        sys.exit(f"error: {source} does not hold a state dict (got {type(state)})")

    out = {}
    for key, tensor in state.items():
        tensor = tensor.detach().to(torch.float16).contiguous()
        if key.endswith("to_qkv.weight"):
            stem = key[: -len("to_qkv.weight")]
            third = tensor.shape[0] // 3
            if third * 3 != tensor.shape[0]:
                sys.exit(f"error: {key} has shape {tuple(tensor.shape)}, not divisible by 3")
            q, k, v = tensor[:third], tensor[third : 2 * third], tensor[2 * third :]
            out[stem + "to_q.weight"] = q.contiguous()
            out[stem + "to_k.weight"] = k.contiguous()
            out[stem + "to_v.weight"] = v.contiguous()
        else:
            out[key] = tensor

    save_file(out, destination, metadata={"format": "pt"})

    stems = sorted({k.split(".")[1] for k in out if k.startswith("mask_estimators.")}, key=int)
    bands = len({k.split(".")[2] for k in out if k.startswith("band_split.to_features.")})
    print(f"wrote   {destination}")
    print(f"keys    {len(out)} (from {len(state)})")
    print(f"stems   {len(stems)}   bands {bands}")
    print(f"final_norm present: {'final_norm.gamma' in out}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    convert(sys.argv[1], sys.argv[2])
