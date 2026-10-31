#!/bin/zsh
# Builds "Presence Lock.app" (ad-hoc signed). Camera access needs a real bundle with
# NSCameraUsageDescription, so the binary is never run bare.
set -euo pipefail
cd "${0:A:h}"
APP="build/Presence Lock.app"
TMP="build/.staging.app"
rm -rf "$TMP"; mkdir -p "$TMP/Contents/MacOS" "$TMP/Contents/Resources"

swift build -c release --product presence-lock 2>&1 | grep -E "error|warning: unre|Compiling|Build complete" | grep -v "^\[" || true
BIN="$(swift build -c release --show-bin-path)/presence-lock"
[[ -x "$BIN" ]] || { echo "build failed"; exit 1; }
cp "$BIN" "$TMP/Contents/MacOS/presence-lock"

xcrun coremlcompiler compile models/FaceEmbedder.mlpackage "$TMP/Contents/Resources" >/dev/null

cat > "$TMP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.mkbuilds.presence-lock</string>
  <key>CFBundleName</key><string>Presence Lock</string>
  <key>CFBundleExecutable</key><string>presence-lock</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSCameraUsageDescription</key><string>Presence Lock checks for your face while you're idle and locks the Mac when you've walked away. Frames never leave this Mac and are never saved.</string>
</dict></plist>
PLIST

# A real identity keeps the code requirement stable, so the camera permission survives rebuilds
# (ad-hoc signatures change every build and macOS asks again).
IDENTITY="${PLOCK_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/{print $2; exit}')}"
codesign --force --deep --sign "${IDENTITY:--}" "$TMP"
# Replace rather than overwrite in place (an in-place rewrite of a signed binary gets killed).
rm -rf "$APP"; mv "$TMP" "$APP"
echo "built $APP"
