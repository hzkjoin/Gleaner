#!/usr/bin/env bash
# Builds a release app and installs it to /Applications, replacing any running copy.
#
# The first launch of the installed app turns on launch at login. Grant it Full Disk Access
# when the panel asks (System Settings → Privacy & Security).
#
# Full Disk Access survives reinstalls when the app is signed with a real identity (see
# build-app.sh). With an ad-hoc signature it has to be granted again after every reinstall.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="/Applications/拾穗.app"
LEGACY="/Applications/Gleaner.app"  # Name used by earlier builds.

"$ROOT/scripts/build-app.sh" release

if pgrep -x Gleaner >/dev/null; then
    pkill -x Gleaner || true
    sleep 1
fi

rm -rf "$TARGET" "$LEGACY"
ditto "$ROOT/build/拾穗.app" "$TARGET"
# Refresh Launch Services so Finder and System Settings pick up the localized name.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$TARGET" || true
open "$TARGET"
echo "Installed $TARGET"
