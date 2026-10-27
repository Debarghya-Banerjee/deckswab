#!/bin/bash
# Builds Deckswab and packages it as build/Deckswab-<version>.dmg for other people to install.
set -euo pipefail
cd "$(dirname "$0")/.."

./build.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
DMG="build/Deckswab-$VERSION.dmg"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

cp -R build/Deckswab.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/How to install.txt" <<'TXT'
1. Drag Deckswab onto the Applications folder.
2. Open Deckswab from Applications.

Deckswab isn't notarised by Apple, so the first time you open it macOS says it
can't verify the developer. To open it anyway:

   System Settings › Privacy & Security › scroll down › "Open Anyway" next to Deckswab

You only need to do this once. Deckswab needs macOS 15 or later.
TXT

rm -f "$DMG"
hdiutil create -volname "Deckswab $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 "$DMG" >/dev/null
codesign --force --sign - "$DMG"
echo "Built $DMG"
