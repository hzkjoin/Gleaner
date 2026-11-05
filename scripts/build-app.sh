#!/usr/bin/env bash
# Builds Gleaner and packages it as build/拾穗.app (the bundle is named for Chinese users,
# who see file names in Finder and System Settings; the executable stays "Gleaner").
#
# Usage: scripts/build-app.sh [debug|release]   (default: release)
#
# Signing: uses $GLEANER_SIGN_IDENTITY if set, otherwise the "Gleaner Self-Signed" certificate
# (see scripts/make-signing-cert.sh), otherwise a "Developer ID Application" or "Apple
# Development" identity, otherwise an ad-hoc signature. A stable identity matters: macOS ties
# privacy permissions such as Full Disk Access to it, and in-app updates must be signed by the
# same identity as the installed app. An ad-hoc signed app counts as a new app after every build.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
APP="$ROOT/build/拾穗.app"

# --disable-dependency-cache works around SwiftPM failing on an existing cached Sparkle archive.
"$ROOT/scripts/swiftw" build -c "$CONFIG" --product Gleaner --disable-dependency-cache
BIN_DIR="$("$ROOT/scripts/swiftw" build -c "$CONFIG" --show-bin-path | tail -1)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/Gleaner" "$APP/Contents/MacOS/Gleaner"
# Sparkle (in-app updates) ships as a framework next to the executable.
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Gleaner" 2>/dev/null || true
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# Localized display names: "拾穗" in Chinese, "Gleaner" in English.
cp -R "$ROOT/Resources/"*.lproj "$APP/Contents/Resources/"

# The Finder extension (问问拾穗 in the right-click menu), built on its own: app extensions
# need their own entry point, which SwiftPM doesn't offer.
APPEX="$APP/Contents/PlugIns/FinderMenu.appex"
mkdir -p "$APPEX/Contents/MacOS"
OPT="-O"; [[ "$CONFIG" == "debug" ]] && OPT="-Onone"
xcrun swiftc $OPT -module-name FinderMenu -target "$(uname -m)-apple-macos14.0" -application-extension \
    -Xlinker -e -Xlinker _NSExtensionMain -framework FinderSync \
    "$ROOT/Extensions/FinderMenu/FinderMenu.swift" "$ROOT/Sources/GleanerCore/Files/ReadableFileTypes.swift" \
    -o "$APPEX/Contents/MacOS/FinderMenu"
cp "$ROOT/Extensions/FinderMenu/Info.plist" "$APPEX/Contents/Info.plist"
for key in CFBundleShortVersionString CFBundleVersion; do
    /usr/libexec/PlistBuddy -c "Set :$key $(/usr/libexec/PlistBuddy -c "Print :$key" "$APP/Contents/Info.plist")" "$APPEX/Contents/Info.plist"
done

IDENTITY="${GLEANER_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
    # Lines look like:  1) <SHA-1> "Apple Development: Name (TEAMID)"
    # The self-signed certificate is not trusted by the system, so it's listed without -v.
    IDENTITY="$(security find-identity -p codesigning 2>/dev/null | awk '/"Gleaner Self-Signed"/ { print $2; exit }')"
fi
if [[ -z "$IDENTITY" ]]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | awk '/"(Developer ID Application|Apple Development):/ { print $2; exit }')"
fi

if [[ -n "$IDENTITY" ]]; then
    # Inside out, as Sparkle's documentation describes: helpers, then the framework, then the app.
    SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
    for part in "$SPARKLE"/XPCServices/*.xpc "$SPARKLE/Autoupdate" "$SPARKLE/Updater.app" "$APP/Contents/Frameworks/Sparkle.framework"; do
        [[ -e "$part" ]] && codesign --force --timestamp=none --sign "$IDENTITY" "$part"
    done
    # Finder only loads sandboxed extensions.
    codesign --force --timestamp=none --sign "$IDENTITY" --entitlements "$ROOT/Extensions/FinderMenu/FinderMenu.entitlements" "$APPEX"
    codesign --force --timestamp=none --sign "$IDENTITY" "$APP"
    echo "Signed with $(codesign -dvv "$APP" 2>&1 | awk -F= '/^Authority=/ { print $2; exit }')"
else
    codesign --force --deep --sign - "$APP"
    codesign --force --sign - --entitlements "$ROOT/Extensions/FinderMenu/FinderMenu.entitlements" "$APPEX"
    codesign --force --sign - "$APP"
    echo "Signed ad-hoc (no signing identity found; privacy permissions reset with every build)"
fi

echo "Built $APP"
