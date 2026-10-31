#!/bin/zsh
# Builds "Presence Lock.app" (ad-hoc signed). Camera access needs a real bundle with
# NSCameraUsageDescription, so the binary is never run bare.
set -euo pipefail
cd "${0:A:h}"
APP="build/Presence Lock.app"
TMP="build/.staging.app"
mkdir -p build; rm -rf "$TMP"; mkdir -p "$TMP/Contents/MacOS" "$TMP/Contents/Resources"

if ! swift build -c release --product presence-lock > build/.swift-build.log 2>&1; then
  grep -E "error" build/.swift-build.log | head -20; echo "build failed"; exit 1
fi
BIN="$(swift build -c release --show-bin-path)/presence-lock"
cp "$BIN" "$TMP/Contents/MacOS/presence-lock"

# The face model isn't in git (InsightFace license). NO_BUNDLED_MODEL=1 builds what a public
# release is: the app downloads and converts the model on first run instead.
if [[ -z "${NO_BUNDLED_MODEL:-}" ]]; then
  [[ -d models/FaceEmbedder.mlpackage ]] || { echo "missing models/FaceEmbedder.mlpackage (see tools/convert_model.py)"; exit 1; }
  xcrun coremlcompiler compile models/FaceEmbedder.mlpackage "$TMP/Contents/Resources" >/dev/null
fi


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
  <key>NSLocationUsageDescription</key><string>Presence Lock can relax at places you save (like home) and tighten everywhere else. Your location never leaves this Mac.</string>
  <key>NSLocationAlwaysAndWhenInUseUsageDescription</key><string>Presence Lock can relax at places you save (like home) and tighten everywhere else. Your location never leaves this Mac.</string>
  <key>NSLocationWhenInUseUsageDescription</key><string>Presence Lock can relax at places you save (like home) and tighten everywhere else. Your location never leaves this Mac.</string>
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
