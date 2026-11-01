#!/bin/zsh
# Builds a signed, notarized NotchGuard DMG and its update feed in dist/: ./release.sh 0.2
# One-time setup (an app-specific password from account.apple.com):
#   xcrun notarytool store-credentials notchguard --apple-id <your Apple ID> --team-id 7N3U4G33DU
set -euo pipefail
cd "${0:A:h}"
VERSION="${1:?usage: ./release.sh <version>}"
IDENTITY="Developer ID Application: MK Builds LLC (7N3U4G33DU)"

# Releases never bundle the face model (InsightFace license); the app downloads it during setup.
NO_BUNDLED_MODEL=1 PLOCK_SIGN_IDENTITY="$IDENTITY" PLOCK_VERSION="$VERSION" ./build.sh
codesign --verify --strict --deep build/NotchGuard.app

STAGE=build/dmg; rm -rf "$STAGE"; mkdir -p "$STAGE" dist
ditto build/NotchGuard.app "$STAGE/NotchGuard.app"
ln -s /Applications "$STAGE/Applications"
DMG="dist/NotchGuard-$VERSION.dmg"; rm -f "$DMG"
hdiutil create -quiet -volname NotchGuard -srcfolder "$STAGE" -fs HFS+ -format UDZO "$DMG"
codesign --sign "$IDENTITY" --timestamp "$DMG"

xcrun notarytool submit "$DMG" --keychain-profile notchguard --wait
xcrun stapler staple "$DMG"
spctl -a -t open --context context:primary-signature -v "$DMG"

# The update feed every installed copy checks (SUFeedURL points at the latest release's appcast.xml),
# signed with the Sparkle key in your login keychain.
SIG="$(.build/artifacts/sparkle/Sparkle/bin/sign_update --account notchguard "$DMG")"
cat > dist/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>NotchGuard</title>
    <item>
      <title>NotchGuard $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$(git rev-list --count HEAD)</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <link>https://github.com/mkbuilds4/notchguard/releases/tag/v$VERSION</link>
      <enclosure url="https://github.com/mkbuilds4/notchguard/releases/download/v$VERSION/NotchGuard-$VERSION.dmg" type="application/octet-stream" $SIG/>
    </item>
  </channel>
</rss>
XML
echo "ready: $DMG and dist/appcast.xml. Publish with:"
echo "  gh release create v$VERSION $DMG dist/appcast.xml --repo mkbuilds4/notchguard --title \"NotchGuard $VERSION\" --generate-notes"
