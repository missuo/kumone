#!/usr/bin/env bash
# Fetch and convert the BS-RoFormer four-stem checkpoint StemKit's 4-lane
# separator wants (drums / bass / other / vocals).
#
# Kumone ships a manifest, never weights: the binary carries an upstream URL and
# a hardcoded SHA-256, and the file is pulled from its original host on first
# use (see Sources/StemKit/Weights/ModelStore.swift). The vocals checkpoint is
# safetensors and `ModelStore` fetches it by itself. This one is not — upstream
# publishes a PyTorch `.ckpt` and nobody has published a converted one — so the
# fetch and the conversion happen here, on your machine, with your torch.
#
# Everything is checked at both ends. If either digest does not match, nothing
# is installed.
#
#   Scripts/fetch-4stem-checkpoint.sh [models-dir]
#
# Default models-dir: ~/Library/Application Support/Kumone/Models
#
# Licence: the checkpoint is MIT, from
# ZFTurbo/Music-Source-Separation-Training. Kumone itself is LGPL-3.0-only and
# the weights are not part of it — they are downloaded, not distributed.

set -euo pipefail

MODELS_DIR="${1:-$HOME/Library/Application Support/Kumone/Models}"
TARGET="$MODELS_DIR/bs_roformer_4stem.safetensors"

UPSTREAM_URL="https://github.com/ZFTurbo/Music-Source-Separation-Training/releases/download/v1.0.12/model_bs_roformer_ep_17_sdr_9.6568.ckpt"
UPSTREAM_SHA="3e9daecd70aaed5b5a0d1f861cc4d77eaa45afb3fc6301b1cf32c1be0f5868fb"
UPSTREAM_BYTES=527385512
CONVERTED_SHA="bc21feafc525b7431d9ad1006c4030b6ea953d0af05b0b5da4ba961eb41da141"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "$TARGET" ]; then
    if [ "$(shasum -a 256 "$TARGET" | cut -d' ' -f1)" = "$CONVERTED_SHA" ]; then
        echo "already installed: $TARGET"
        exit 0
    fi
    echo "existing $TARGET fails its digest; replacing it."
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "==> downloading $(basename "$UPSTREAM_URL") ($((UPSTREAM_BYTES / 1024 / 1024)) MiB)"
curl -L --fail --progress-bar -o "$work/upstream.ckpt" "$UPSTREAM_URL"

actual="$(shasum -a 256 "$work/upstream.ckpt" | cut -d' ' -f1)"
if [ "$actual" != "$UPSTREAM_SHA" ]; then
    echo "error: downloaded checkpoint SHA-256 mismatch" >&2
    echo "  expected $UPSTREAM_SHA" >&2
    echo "  actual   $actual" >&2
    exit 1
fi
echo "    digest ok"

# torch is a build-time-only dependency of this script and has no business
# being installed globally, so it lives in a throwaway venv unless the caller
# already has one (ROFORMER_PYTHON).
PYTHON="${ROFORMER_PYTHON:-}"
if [ -z "$PYTHON" ]; then
    echo "==> preparing a temporary python environment (torch + safetensors)"
    python3 -m venv "$work/venv"
    "$work/venv/bin/pip" -q install --upgrade pip
    "$work/venv/bin/pip" -q install torch safetensors
    PYTHON="$work/venv/bin/python"
fi

echo "==> converting"
"$PYTHON" "$here/convert-roformer-checkpoint.py" "$work/upstream.ckpt" "$work/converted.safetensors"

actual="$(shasum -a 256 "$work/converted.safetensors" | cut -d' ' -f1)"
if [ "$actual" != "$CONVERTED_SHA" ]; then
    echo "error: converted file SHA-256 mismatch — this is the digest StemKit pins." >&2
    echo "  expected $CONVERTED_SHA" >&2
    echo "  actual   $actual" >&2
    echo "  (a torch version whose fp32->fp16 rounding differs would do this.)" >&2
    exit 1
fi

mkdir -p "$MODELS_DIR"
mv "$work/converted.safetensors" "$TARGET"
echo "installed $TARGET"
