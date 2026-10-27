#!/bin/bash
# Builds a universal (Apple Silicon + Intel) "Dialtone.app" and a zip. Needs only the Xcode
# command line tools (swiftc). Output: native/build/
# Version comes from native/VERSION (or the VERSION environment variable).
set -euo pipefail
cd "$(dirname "$0")"

OUT=build
APP="$OUT/Dialtone.app"
rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$OUT/tmp"

for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$arch-apple-macos13.0" Sources/*.swift -o "$OUT/tmp/gv-$arch"
done
lipo -create "$OUT/tmp/gv-arm64" "$OUT/tmp/gv-x86_64" -output "$APP/Contents/MacOS/Dialtone"

VERSION="${VERSION:-$(cat VERSION)}"
cp Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
cp ../packaging/icon.icns "$APP/Contents/Resources/icon.icns"
cp "../assets/trayTemplate@2x.png" "$APP/Contents/Resources/tray.png"

codesign --force --deep --sign - "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/Dialtone.zip"
rm -rf "$OUT/tmp"
echo "Built $APP and $OUT/Dialtone.zip"
