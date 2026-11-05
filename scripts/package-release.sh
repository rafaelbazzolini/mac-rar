#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' scripts/Info.plist)"
RELEASE="$PWD/dist/release"
mkdir -p "$RELEASE"
for ARCH in arm64 x86_64; do
    ./scripts/build-app.sh "$ARCH" "$PWD/dist/$ARCH"
    APP="$PWD/dist/$ARCH/MacRar.app"
    lipo -verify_arch "$ARCH" "$APP/Contents/MacOS/MacRar"
    codesign --verify --deep --strict "$APP"
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$RELEASE/MacRar-$VERSION-$ARCH.zip"
done
(cd "$RELEASE" && shasum -a 256 "MacRar-$VERSION-arm64.zip" "MacRar-$VERSION-x86_64.zip" > SHA256SUMS.txt)
printf 'Release %s gerada em %s\n' "$VERSION" "$RELEASE"
