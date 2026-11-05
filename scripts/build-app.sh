#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ARCH="${1:-$(uname -m)}"
case "$ARCH" in arm64|x86_64) ;; *) printf 'Uso: %s [arm64|x86_64] [diretorio-saida]\n' "$0" >&2; exit 2 ;; esac
OUTPUT="${2:-$PWD/dist}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-cache"
BUILD_ARGS=(--build-system native --disable-sandbox --cache-path "$PWD/.build/cache" --scratch-path "$PWD/.build/build-$ARCH" --triple "$ARCH-apple-macosx13.0" -c release)
swift build "${BUILD_ARGS[@]}"
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
APP="$OUTPUT/MacRar.app"
./scripts/build-icon.sh
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp "$BIN_DIR/MacRar" "$APP/Contents/MacOS/MacRar"
cp scripts/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
touch "$APP"
if [[ "$OUTPUT" == "$PWD/dist" ]]; then
    LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    if [[ -x "$LSREGISTER" ]]; then "$LSREGISTER" -f "$APP"; fi
fi
printf 'Aplicativo criado (%s): %s\n' "$ARCH" "$APP"
