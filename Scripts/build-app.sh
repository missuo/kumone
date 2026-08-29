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

# ARCHES="arm64 x86_64" builds a universal binary (CI release);
# default is the host architecture for fast dev loops.
ARCH_FLAGS=()
for arch in ${ARCHES:-}; do
  ARCH_FLAGS+=(--arch "$arch")
done

# ${arr[@]+...} keeps macOS's bash 3.2 happy under set -u with empty arrays
swift build -c "$CONF" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --product "$APP_NAME"
BIN_PATH="$(swift build -c "$CONF" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

rm -rf "$BUILD_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

cp "$BIN_PATH/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
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
# from beside the running binary, and a Command Line Tools-only build cannot
# produce one — Scripts/fetch-mlx-metallib.sh installs it into .build. Copy it
# in when it is there; without it the app simply never pre-renders stem
# hand-overs (StemKit.ResidentStemSeparator.isRunnable says no).
METALLIB="$(find "$ROOT/.build" -name 'mlx.metallib' -print -quit 2>/dev/null || true)"
if [ -n "$METALLIB" ]; then
  cp "$METALLIB" "$APP_BUNDLE/Contents/MacOS/mlx.metallib"
fi

# Localization tables → Bundle.main
for lproj in "$ROOT"/Sources/Kumone/Resources/*.lproj; do
  [ -d "$lproj" ] && cp -R "$lproj" "$APP_BUNDLE/Contents/Resources/"
done

# SwiftPM resource bundles (if any)
find "$BIN_PATH" -maxdepth 1 -name '*.bundle' -not -name '*Tests*' -print0 |
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
