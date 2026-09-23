#!/usr/bin/env bash
# Publish the two separation checkpoints as assets of the `stem-models-v1`
# GitHub release — the route the app itself downloads from.
#
# Kumone still does not *distribute* weights inside its own LGPL-3.0-only
# build: this is a release of two MIT-licensed, upstream-derived files that the
# app pulls on demand, with the same hardcoded SHA-256 checked on arrival that
# `Sources/StemKit/Weights/ModelStore.swift` has always pinned. What the release
# buys is the two failures a user cannot fix themselves — no torch for the
# four-stem conversion, and a Hugging Face that is slow or blocked where they
# live.
#
#   Scripts/publish-stem-models.sh [models-dir]
#
# Default models-dir: ~/Library/Application Support/Kumone/Models
#
# Prerequisites: `gh` authenticated with write access to XerWandeRer/kumone, and
# both files already built locally (Scripts/fetch-4stem-checkpoint.sh for the
# four-stem one). Nothing is uploaded whose digest does not match the manifest.
#
# Maintainer-only. The app never runs this.

set -euo pipefail

REPO="XerWandeRer/kumone"
TAG="stem-models-v1"
MODELS_DIR="${1:-$HOME/Library/Application Support/Kumone/Models}"

VOCALS="$MODELS_DIR/mel_roformer_vocals.safetensors"
FOUR_STEM="$MODELS_DIR/bs_roformer_4stem.safetensors"

# Must match ModelDescriptor in Sources/StemKit/Weights/ModelStore.swift and
# StemModelSpec in Sources/Kumone/Core/Stems/StemModelDownloader.swift.
VOCALS_SHA="ef4aa052845a868cfaff93611477bd8f54d8081bc32f2742a9b3c738f0821191"
VOCALS_BYTES=67402202
FOUR_STEM_SHA="bc21feafc525b7431d9ad1006c4030b6ea953d0af05b0b5da4ba961eb41da141"
FOUR_STEM_BYTES=263558304

NOTES="Stem separation checkpoints for Kumone's AutoMix 增强过渡.

- mel_roformer_vocals.safetensors — Mel-Band RoFormer vocals v1 (ZFTurbo, MIT), fp16 safetensors, 67,402,202 B
  sha256 $VOCALS_SHA
- bs_roformer_4stem.safetensors — BS-RoFormer four-stem (ZFTurbo v1.0.12, MIT), converted to fp16 safetensors, 263,558,304 B
  sha256 $FOUR_STEM_SHA

Both digests are hardcoded in the app; a file that does not match is deleted rather than used.
Weights are MIT and belong to their upstream authors; Kumone itself is LGPL-3.0-only."

command -v gh >/dev/null || { echo "gh not found — install the GitHub CLI" >&2; exit 1; }

check() {
    local path="$1" want_sha="$2" want_bytes="$3"
    [ -f "$path" ] || { echo "missing: $path" >&2; exit 1; }

    local bytes sha
    bytes=$(stat -f%z "$path")
    sha=$(shasum -a 256 "$path" | cut -d' ' -f1)

    echo "$(basename "$path")"
    echo "  bytes  $bytes"
    echo "  sha256 $sha"

    if [ "$bytes" != "$want_bytes" ] || [ "$sha" != "$want_sha" ]; then
        echo "  MISMATCH — expected $want_bytes B / $want_sha" >&2
        echo "  Refusing to publish a file the app would reject on arrival." >&2
        exit 1
    fi
}

check "$VOCALS" "$VOCALS_SHA" "$VOCALS_BYTES"
check "$FOUR_STEM" "$FOUR_STEM_SHA" "$FOUR_STEM_BYTES"

if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    echo "release $TAG exists — re-uploading assets with --clobber"
    gh release upload "$TAG" --repo "$REPO" --clobber "$VOCALS" "$FOUR_STEM"
else
    gh release create "$TAG" --repo "$REPO" \
        --title "Stem models v1" \
        --notes "$NOTES" \
        "$VOCALS" "$FOUR_STEM"
fi

echo
echo "Published to https://github.com/$REPO/releases/tag/$TAG"
echo "The app downloads from:"
echo "  https://github.com/$REPO/releases/download/$TAG/$(basename "$VOCALS")"
echo "  https://github.com/$REPO/releases/download/$TAG/$(basename "$FOUR_STEM")"
