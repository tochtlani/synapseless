#!/bin/zsh
# Builds Synapseless.app (universal: Intel + Apple silicon) next to this script.
set -euo pipefail
cd "${0:A:h}"

APP="build/Synapseless.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/obj

for arch in x86_64 arm64; do
  swiftc -O -parse-as-library -target "$arch-apple-macos14.0" \
    Sources/*.swift -o "build/obj/Synapseless-$arch" \
    -framework IOKit -framework ServiceManagement
done
lipo -create build/obj/Synapseless-* -output "$APP/Contents/MacOS/Synapseless"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/*.png "$APP/Contents/Resources/"
cp -R Resources/devices "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "Built $APP"
