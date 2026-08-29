#!/bin/bash
# Fetch the prebuilt mlx.metallib that StemKit's pinned mlx-swift needs.
#
# WHY THIS EXISTS
#   MLX loads its Metal kernels from a precompiled `mlx.metallib`. SwiftPM can only
#   produce that file when Xcode's `metal` compiler is installed; on a Command Line
#   Tools-only machine `swift build` succeeds but silently emits no metallib, and the
#   first MLX call dies with "Failed to load the default metallib".
#
#   MLX's own Python wheel ships an official prebuilt metallib for exactly the same
#   source revision, so we take it from there. The version MUST match the MLX that
#   mlx-swift vendors, or kernel lookups fail at runtime.
#
#   mlx-swift 0.30.6  ->  vendors MLX 0.30.6  ->  needs mlx==0.30.6
#   (verify with: grep MLX_VERSION .build/checkouts/mlx-swift/Source/Cmlx/mlx/mlx/version.h)
#
#   With Xcode installed this script is unnecessary — SwiftPM builds the metallib itself.
#
# USAGE
#   Scripts/fetch-mlx-metallib.sh [destination-dir]
#
#   destination-dir defaults to .build/release (where `swift build -c release` puts
#   stemtool). MLX looks for `mlx.metallib` next to the running executable, so the
#   metallib must sit beside whichever binary you intend to run — repeat for
#   .build/debug, or for a packaged app's Contents/MacOS.

set -euo pipefail

MLX_VERSION="0.30.6"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DESTINATION="${1:-$REPO_ROOT/.build/release}"

if [ ! -d "$DESTINATION" ]; then
    echo "error: destination directory does not exist: $DESTINATION" >&2
    echo "hint: run 'swift build -c release --product stemtool' first" >&2
    exit 1
fi

TARGET="$DESTINATION/mlx.metallib"
if [ -f "$TARGET" ]; then
    echo "mlx.metallib already present at $TARGET"
    exit 0
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

echo "Creating a throwaway venv to pull mlx==$MLX_VERSION ..."
python3 -m venv "$WORKDIR/venv"
"$WORKDIR/venv/bin/pip" install --quiet "mlx==$MLX_VERSION"

SOURCE="$(find "$WORKDIR/venv" -name mlx.metallib -print -quit)"
if [ -z "$SOURCE" ]; then
    echo "error: mlx==$MLX_VERSION did not contain an mlx.metallib" >&2
    exit 1
fi

cp "$SOURCE" "$TARGET"
echo "Installed $(du -h "$TARGET" | cut -f1) metallib -> $TARGET"
echo "sha256: $(shasum -a 256 "$TARGET" | cut -d' ' -f1)"
