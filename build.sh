#!/bin/bash
# Builds Deckswab.app into ./build. Pass --install to copy it to ~/Applications and launch it.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=build/Deckswab.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Deckswab "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
codesign --force --sign - "$APP"

if [ "${1:-}" = "--install" ]; then
	pkill -x Deckswab || true
	mkdir -p ~/Applications
	rm -rf ~/Applications/Deckswab.app
	cp -R "$APP" ~/Applications/
	open ~/Applications/Deckswab.app
fi

echo "Built $APP"
