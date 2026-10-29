#!/bin/bash
set -euo pipefail
SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="/private/tmp/radiolinks-build/RadioLinks"
mkdir -p "$BUILD_DIR"
ditto "$SOURCE_DIR/Sources" "$BUILD_DIR/Sources"
cp "$SOURCE_DIR/Package.swift" "$BUILD_DIR/Package.swift"
cp "$SOURCE_DIR/AppIcon.png" "$BUILD_DIR/AppIcon.png"
cd "$BUILD_DIR"
export SDKROOT="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
export SWIFTPM_MODULECACHE_OVERRIDE="$(pwd)/.module-cache"
swift build -c release --scratch-path .build

APP_VERSION="1.0.0"
BUILD_NUMBER_FILE="$SOURCE_DIR/BuildNumber"
CURRENT_BUILD_NUMBER="$(cat "$BUILD_NUMBER_FILE" 2>/dev/null || echo 0)"
if ! [[ "$CURRENT_BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "Invalid build number in $BUILD_NUMBER_FILE: $CURRENT_BUILD_NUMBER" >&2
  exit 1
fi
NEXT_BUILD_NUMBER=$((CURRENT_BUILD_NUMBER + 1))

APP="$(cd "$SOURCE_DIR/.." && pwd)/RadioLinks.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/RadioLinks "$APP/Contents/MacOS/RadioLinks"
rm -rf "$APP/Contents/Helpers"

ICONSET=".build/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for SIZE in 16 32 128 256 512; do
  sips -z "$SIZE" "$SIZE" AppIcon.png --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
  DOUBLE=$((SIZE * 2))
  sips -z "$DOUBLE" "$DOUBLE" AppIcon.png --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>RadioLinks</string>
  <key>CFBundleIdentifier</key><string>com.codex.radiolinks</string>
  <key>CFBundleName</key><string>Radio Links</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
  <key>CFBundleVersion</key><string>$NEXT_BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict>
</plist>
PLIST
touch "$APP"
printf '%s\n' "$NEXT_BUILD_NUMBER" > "$BUILD_NUMBER_FILE"
echo "Built $APP"
echo "Version $APP_VERSION (build $NEXT_BUILD_NUMBER)"
