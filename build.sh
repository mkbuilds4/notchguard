#!/bin/zsh
# Builds "NotchGuard.app" (signed with the hardened runtime; release.sh makes the notarized DMG). Camera access needs a real bundle with
# NSCameraUsageDescription, so the binary is never run bare.
set -euo pipefail
cd "${0:A:h}"
APP="build/NotchGuard.app"
TMP="build/.staging.app"
mkdir -p build; rm -rf "$TMP"; mkdir -p "$TMP/Contents/MacOS" "$TMP/Contents/Resources"

if ! swift build -c release --product notchguard > build/.swift-build.log 2>&1; then
  grep -E "error" build/.swift-build.log | head -20; echo "build failed"; exit 1
fi
BIN="$(swift build -c release --show-bin-path)/notchguard"
cp "$BIN" "$TMP/Contents/MacOS/NotchGuard"

# The face model isn't in git (InsightFace license). NO_BUNDLED_MODEL=1 builds what a public
# release is: the app downloads and converts the model on first run instead.
if [[ -z "${NO_BUNDLED_MODEL:-}" ]]; then
  [[ -d models/FaceEmbedder.mlpackage ]] || { echo "missing models/FaceEmbedder.mlpackage (see tools/convert_model.py)"; exit 1; }
  xcrun coremlcompiler compile models/FaceEmbedder.mlpackage "$TMP/Contents/Resources" >/dev/null
fi
# Sparkle (updates) ships inside the app; its helpers are signed inside-out before the app itself.
mkdir -p "$TMP/Contents/Frameworks"
ditto "$(swift build -c release --show-bin-path)/Sparkle.framework" "$TMP/Contents/Frameworks/Sparkle.framework"
cp assets/AppIcon.icns "$TMP/Contents/Resources/AppIcon.icns"  # redraw with: swift tools/make_icon.swift

cat > "$TMP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.mkbuilds.notchguard</string>
  <key>CFBundleName</key><string>NotchGuard</string>
  <key>CFBundleExecutable</key><string>NotchGuard</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>${PLOCK_VERSION:-0.1}</string>
  <key>CFBundleVersion</key><string>$(git rev-list --count HEAD)</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>SUFeedURL</key><string>https://github.com/mkbuilds4/notchguard/releases/latest/download/appcast.xml</string>
  <key>SUPublicEDKey</key><string>eAIT0HtSP5EnlW3jVst2WfHzk4x1qn4bPKOPTZFIna8=</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>NSLocationUsageDescription</key><string>NotchGuard can relax at places you save (like home) and tighten everywhere else. Your location never leaves this Mac.</string>
  <key>NSLocationAlwaysAndWhenInUseUsageDescription</key><string>NotchGuard can relax at places you save (like home) and tighten everywhere else. Your location never leaves this Mac.</string>
  <key>NSLocationWhenInUseUsageDescription</key><string>NotchGuard can relax at places you save (like home) and tighten everywhere else. Your location never leaves this Mac.</string>
  <key>NSAppleEventsUsageDescription</key><string>NotchGuard texts you photos of anyone who sits at your Mac, through Messages.</string>
  <key>NSCameraUsageDescription</key><string>NotchGuard checks for your face while you're idle and locks the Mac when you've walked away. Frames never leave this Mac and are never saved.</string>
</dict></plist>
PLIST

# A real identity keeps the code requirement stable, so the camera permission survives rebuilds
# (ad-hoc signatures change every build and macOS asks again).
IDENTITY="${PLOCK_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/{print $2; exit}')}"
# Release builds (Developer ID) also get a secure timestamp, which notarization requires.
TIMESTAMP=(); [[ "$IDENTITY" == "Developer ID"* ]] && TIMESTAMP=(--timestamp)
SPARKLE="$TMP/Contents/Frameworks/Sparkle.framework/Versions/B"
for part in XPCServices/Installer.xpc XPCServices/Downloader.xpc Autoupdate Updater.app; do
  codesign --force --options runtime "${TIMESTAMP[@]}" --preserve-metadata=entitlements --sign "${IDENTITY:--}" "$SPARKLE/$part"
done
codesign --force --options runtime "${TIMESTAMP[@]}" --sign "${IDENTITY:--}" "$TMP/Contents/Frameworks/Sparkle.framework"
codesign --force --options runtime "${TIMESTAMP[@]}" --entitlements NotchGuard.entitlements --sign "${IDENTITY:--}" "$TMP"
# Replace rather than overwrite in place (an in-place rewrite of a signed binary gets killed).
rm -rf "$APP"; mv "$TMP" "$APP"
echo "built $APP"
