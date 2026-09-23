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
#   destination-dir defaults to .build/release (where `swift build -c release
#   --product Kumone` puts the app binary). MLX looks for `mlx.metallib` next to the
#   running executable, so the metallib must sit beside whichever binary you intend
#   to run — repeat for .build/debug, or for a packaged app's Contents/MacOS.
#   Scripts/build-app.sh copies the first one it finds under .build into the app.
#
#   The extracted file is checked against MLX_METALLIB_SHA256 below (also when it
#   is already present); a mismatch is an error. Bump both together.

set -euo pipefail

MLX_VERSION="0.30.6"
# sha256 of mlx.metallib from the mlx-metal==0.30.6 macosx_15_0_arm64 wheel.
MLX_METALLIB_SHA256="62c797721583d990428b197434b4d6c5126c1b8212bc6caf5cd74ca7e0ac1829"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DESTINATION="${1:-$REPO_ROOT/.build/release}"

if [ ! -d "$DESTINATION" ]; then
    echo "error: destination directory does not exist: $DESTINATION" >&2
    echo "hint: run 'swift build -c release --product Kumone' first" >&2
    exit 1
fi

verify_sha256() {
    local actual
    actual="$(shasum -a 256 "$1" | cut -d' ' -f1)"
    if [ "$actual" != "$MLX_METALLIB_SHA256" ]; then
        echo "error: mlx.metallib sha256 mismatch at $1" >&2
        echo "       expected $MLX_METALLIB_SHA256" >&2
        echo "       actual   $actual" >&2
        return 1
    fi
    echo "sha256 OK: $actual"
}

TARGET="$DESTINATION/mlx.metallib"
if [ -f "$TARGET" ]; then
    echo "mlx.metallib already present at $TARGET"
    verify_sha256 "$TARGET" || exit 1
    exit 0
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

echo "Creating a throwaway venv to pull mlx==$MLX_VERSION ..."
python3 -m venv "$WORKDIR/venv"
# The metallib lives in the `mlx-metal` wheel, and MLX publishes one per
# macOS target. pip would pick the wheel for *this* machine — on macOS 26 that
# is a metallib stamped for macOS 26, which macOS 15 refuses to load ("compiled
# with Metal 4.0"). The app's minimum is macOS 15, so ask for that wheel
# explicitly; it is the same kernels from the same compiler, only the target
# OS field differs, and it loads on 15 and 26 alike.
"$WORKDIR/venv/bin/pip" download --quiet --no-deps --only-binary=:all: \
    --platform macosx_15_0_arm64 --python-version 3.13 \
    -d "$WORKDIR/wheel" "mlx-metal==$MLX_VERSION"
"$WORKDIR/venv/bin/python" -m zipfile -e "$WORKDIR"/wheel/mlx_metal-*.whl "$WORKDIR/unpacked"

SOURCE="$(find "$WORKDIR/unpacked" -name mlx.metallib -print -quit)"
if [ -z "$SOURCE" ]; then
    echo "error: mlx==$MLX_VERSION did not contain an mlx.metallib" >&2
    exit 1
fi

verify_sha256 "$SOURCE" || exit 1
cp "$SOURCE" "$TARGET"
echo "Installed $(du -h "$TARGET" | cut -f1) metallib -> $TARGET"
