#!/bin/bash
# Builds Kumone with SwiftPM and wraps the product into a .app bundle.
# Usage: Scripts/build-app.sh [debug|release]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

CONF="${1:-debug}"
APP_NAME="Kumone"
BUNDLE_ID="im.missuo.Kumone"
# Version resolution: environment > version.env > defaults.
ENV_MARKETING_VERSION="${MARKETING_VERSION:-}"
ENV_BUILD_NUMBER="${BUILD_NUMBER:-}"
MARKETING_VERSION="0.1.0"
BUILD_NUMBER="1"
[ -f "$ROOT/version.env" ] && source "$ROOT/version.env"
[ -n "$ENV_MARKETING_VERSION" ] && MARKETING_VERSION="$ENV_MARKETING_VERSION"
[ -n "$ENV_BUILD_NUMBER" ] && BUILD_NUMBER="$ENV_BUILD_NUMBER"

SPARKLE_FEED_URL="https://github.com/missuo/kumone/releases/latest/download/appcast.xml"
SPARKLE_PUBLIC_ED_KEY="RHEhllstUuuVrVDCPGrbhg/8LivSzpuZB9X3u3xdV5o="

BUILD_DIR="$ROOT/.build/app"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

# ARCHES="arm64 x86_64" builds a universal binary (CI release); default is
# the host architecture for fast dev loops. Each architecture is built on its
# own and the slices are joined with lipo: a multi-`--arch` SwiftPM build
# switches to XCBuild, which compiles mlx-swift's .metal sources and so needs
# a Metal Toolchain that GitHub's runners do not reliably provide. The
# kernels come from the pinned, sha-checked fetch below instead.

# Extra SwiftPM flags from the environment, e.g. on a Command-Line-Tools-only
# macOS 27 machine: SWIFT_BUILD_FLAGS="--build-system native" together with
# SDKROOT=…/MacOSX26.5.sdk (the Swift Build backend wants a `metal` compiler
# CLT does not ship, and the 27 SDK's SwiftUI macros need a plugin it lacks).
EXTRA_FLAGS=()
for flag in ${SWIFT_BUILD_FLAGS:-}; do
  EXTRA_FLAGS+=("$flag")
done

# ${arr[@]+...} keeps macOS's bash 3.2 happy under set -u with empty arrays
build_slice() { # [triple] — prints nothing; sets SLICE_BIN_PATH
  local triple_flags=()
  [ -n "${1:-}" ] && triple_flags=(--triple "$1")
  swift build -c "$CONF" ${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"} \
    ${triple_flags[@]+"${triple_flags[@]}"} --product "$APP_NAME"
  SLICE_BIN_PATH="$(swift build -c "$CONF" ${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"} \
    ${triple_flags[@]+"${triple_flags[@]}"} --show-bin-path)"
}

SLICE_BINARIES=()
if [ -n "${ARCHES:-}" ]; then
  for arch in $ARCHES; do
    build_slice "$arch-apple-macosx"
    SLICE_BINARIES+=("$SLICE_BIN_PATH/$APP_NAME")
    # Resources and the metallib search below use the first slice's tree;
    # every slice carries the same resources.
    BIN_PATH="${BIN_PATH:-$SLICE_BIN_PATH}"
  done
else
  build_slice ""
  BIN_PATH="$SLICE_BIN_PATH"
  SLICE_BINARIES+=("$BIN_PATH/$APP_NAME")
fi

rm -rf "$BUILD_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

if [ "${#SLICE_BINARIES[@]}" -gt 1 ]; then
  lipo -create "${SLICE_BINARIES[@]}" -output "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
else
  cp "${SLICE_BINARIES[0]}" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
fi
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Embed Sparkle.framework (SwiftPM binary artifact) into Contents/Frameworks.
SPARKLE_FW="$(find "$ROOT/.build/artifacts" -type d -name 'Sparkle.framework' -path '*macos*' 2>/dev/null | head -n1)"
if [ -z "$SPARKLE_FW" ]; then
  echo "ERROR: Sparkle.framework not found under .build/artifacts" >&2
  exit 1
fi
mkdir -p "$APP_BUNDLE/Contents/Frameworks"
cp -a "$SPARKLE_FW" "$APP_BUNDLE/Contents/Frameworks/"

# MLX's Metal kernels, for AutoMix stem transitions. MLX loads `mlx.metallib`
# from beside the running binary first, so the app always gets one there.
# Sources, most specific first:
#   1. $BIN_PATH/mlx.metallib — placed beside this very configuration's binary
#      by Scripts/fetch-mlx-metallib.sh (Command Line Tools builds).
#   2. The kernels SwiftPM compiled in this build — with Xcode (and its Metal
#      Toolchain) mlx-swift's sources become
#      $BIN_PATH/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib and
#      no file named mlx.metallib exists. Built from the pinned sources by
#      this same invocation, so it cannot be stale.
#   3. Any other mlx.metallib under .build (e.g. fetched into another
#      configuration's directory) — fetch-mlx-metallib.sh sha-checks what it
#      installs, so this is still the pinned MLX version.
# Without any of them the app would never pre-render stem hand-overs
# (StemKit.ResidentStemSeparator.isRunnable says no).
CMLX_METALLIB="$BIN_PATH/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"
if [ -f "$BIN_PATH/mlx.metallib" ]; then
  METALLIB="$BIN_PATH/mlx.metallib"
elif [ -f "$CMLX_METALLIB" ]; then
  METALLIB="$CMLX_METALLIB"
else
  METALLIB="$(find "$ROOT/.build" -name 'mlx.metallib' -not -path "$BUILD_DIR/*" -print -quit 2>/dev/null || true)"
fi
if [ -z "$METALLIB" ] && [ "${FETCH_MLX_METALLIB:-0}" = "1" ]; then
  # CI: fetch the pinned, sha-verified kernels rather than compile them.
  "$SCRIPT_DIR/fetch-mlx-metallib.sh" "$BIN_PATH"
  METALLIB="$BIN_PATH/mlx.metallib"
fi
if [ -n "$METALLIB" ]; then
  echo "mlx.metallib <- $METALLIB"
  cp "$METALLIB" "$APP_BUNDLE/Contents/MacOS/mlx.metallib"
else
  # Shipping without the kernels silently disables every stem hand-over and
  # is indistinguishable from a planner bug in the field (2026-08-31: a day
  # of "everything falls to stagedEQ" traced back to exactly this). Fail
  # loudly instead; a clean of .build eats the metallib, and the fix is one
  # command.
  echo "error: no mlx.metallib under .build and no compiled Cmlx kernels at" >&2
  echo "       $CMLX_METALLIB —" >&2
  echo "       the app would ship with stem separation disabled. Run" >&2
  echo "       Scripts/fetch-mlx-metallib.sh (after 'swift build -c release" >&2
  echo "       --product Kumone') first, or with Xcode install the Metal" >&2
  echo "       Toolchain (xcodebuild -downloadComponent MetalToolchain)." >&2
  exit 1
fi

# Localization tables → Bundle.main
cp "$ROOT/Sources/Kumone/Resources/PrivacyInfo.xcprivacy" "$APP_BUNDLE/Contents/Resources/"
for lproj in "$ROOT"/Sources/Kumone/Resources/*.lproj; do
  [ -d "$lproj" ] && cp -R "$lproj" "$APP_BUNDLE/Contents/Resources/"
done

# SwiftPM resource bundles (if any). mlx-swift_Cmlx.bundle only carries the
# kernels already copied to Contents/MacOS/mlx.metallib above (~100 MB), and
# MLX finds the colocated copy first, so it is left out.
find "$BIN_PATH" -maxdepth 1 -name '*.bundle' -not -name '*Tests*' \
  -not -name 'mlx-swift_Cmlx.bundle' -print0 |
  while IFS= read -r -d '' bundle; do
    cp -R "$bundle" "$APP_BUNDLE/Contents/Resources/"
  done

# App icon: compile the Icon Composer bundle into Assets.car and keep the
# source bundle alongside for Liquid Glass light/dark rendering on macOS 26.
ICON_SOURCE="$ROOT/AppIcon.icon"
if [ -d "$ICON_SOURCE" ]; then
  cp -R "$ICON_SOURCE" "$APP_BUNDLE/Contents/Resources/AppIcon.icon"
  xcrun actool "$ICON_SOURCE" \
    --compile "$APP_BUNDLE/Contents/Resources" \
    --notices --warnings --errors \
    --output-partial-info-plist "$BUILD_DIR/icon-partial.plist" \
    --app-icon AppIcon \
    --enable-on-demand-resources NO \
    --development-region zh-Hans \
    --target-device mac \
    --minimum-deployment-target 15.0 \
    --platform macosx >/dev/null
  if [ ! -f "$APP_BUNDLE/Contents/Resources/Assets.car" ]; then
    echo "ERROR: actool did not produce Assets.car" >&2
    exit 1
  fi
fi

printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

GIT_COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>zh-Hans</string>
        <string>en</string>
    </array>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>CFBundleIcons</key>
    <dict>
        <key>CFBundlePrimaryIcon</key>
        <dict>
            <key>CFBundleIconName</key><string>AppIcon</string>
        </dict>
    </dict>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$MARKETING_VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHumanReadableCopyright</key><string>© 2026 missuo</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key><true/>
    </dict>
    <key>KumoneGitCommit</key><string>$GIT_COMMIT</string>
    <key>SUFeedURL</key><string>$SPARKLE_FEED_URL</string>
    <key>SUPublicEDKey</key><string>$SPARKLE_PUBLIC_ED_KEY</string>
    <key>SUEnableAutomaticChecks</key><true/>
</dict>
</plist>
PLIST

if [ -n "${ARCHES:-}" ]; then
  echo "Binary architectures: $(lipo -archs "$APP_BUNDLE/Contents/MacOS/$APP_NAME")"
fi

xattr -cr "$APP_BUNDLE" 2>/dev/null || true
codesign --force --sign - "$APP_BUNDLE" >/dev/null 2>&1 || true

echo "Built $APP_BUNDLE ($CONF, $GIT_COMMIT)"
