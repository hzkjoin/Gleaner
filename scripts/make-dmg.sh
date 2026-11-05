#!/usr/bin/env bash
# Packages build/拾穗.app as a drag-to-install disk image: build/Gleaner-<version>.dmg.
#
# Usage: scripts/make-dmg.sh   (run scripts/build-app.sh first)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/拾穗.app"
[[ -d "$APP" ]] || { echo "Missing $APP; run scripts/build-app.sh first" >&2; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
DMG="$ROOT/build/Gleaner-$VERSION.dmg"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/拾穗.app"
ln -s /Applications "$STAGE/应用程序"

rm -f "$DMG"
hdiutil create -volname "拾穗" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" 2>&1 >/dev/null | grep -v deprecated >&2 || true
echo "Packaged $DMG"
