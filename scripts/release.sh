#!/usr/bin/env bash
# Publishes a release on GitHub: bumps the version, builds and signs the app, packages a disk
# image, writes the Sparkle update feed and uploads both to a GitHub release.
#
# Usage: scripts/release.sh <version> [notes-file]      e.g. scripts/release.sh 0.2.0
#
# Needs: the "Gleaner Self-Signed" certificate (scripts/make-signing-cert.sh), the Sparkle
# update key in the keychain (account "gleaner"), Sparkle's tools in .tools/, and `gh` logged
# in to the account that owns the repository. The repository is $GLEANER_REPO ("owner/name")
# or the `origin` remote.
#
# Installed copies check https://github.com/<repo>/releases/latest/download/appcast.xml, so
# every release uploads its own appcast.xml and the newest one wins.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:?usage: scripts/release.sh <version> [notes-file]}"
NOTES="${2:-}"
SPARKLE_BIN="$ROOT/.tools/sparkle-2.10.0/bin"
PLIST="$ROOT/Resources/Info.plist"

REPO="${GLEANER_REPO:-$(git -C "$ROOT" remote get-url origin 2>/dev/null | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')}"
[[ "$REPO" == */* ]] || { echo "Set GLEANER_REPO=owner/name or add a GitHub origin remote" >&2; exit 1; }
[[ -x "$SPARKLE_BIN/generate_appcast" ]] || { echo "Missing Sparkle tools in $SPARKLE_BIN" >&2; exit 1; }
security find-identity -p codesigning | grep -q '"Gleaner Self-Signed"' \
    || { echo "Missing the \"Gleaner Self-Signed\" certificate" >&2; exit 1; }
LOGIN="$(gh api user --jq .login)"
[[ "${REPO%%/*}" == "$LOGIN" ]] || { echo "gh is logged in as $LOGIN, not ${REPO%%/*} (gh auth switch)" >&2; exit 1; }
gh release view "v$VERSION" --repo "$REPO" >/dev/null 2>&1 && { echo "v$VERSION already exists" >&2; exit 1; }

# 1. Version and update feed.
BUILD="$(( $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST") + 1 ))"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :SUFeedURL https://github.com/$REPO/releases/latest/download/appcast.xml" "$PLIST"

# 2. Build, sign and package.
GLEANER_SIGN_IDENTITY="Gleaner Self-Signed" "$ROOT/scripts/build-app.sh" release
"$ROOT/scripts/make-dmg.sh"
DMG="$ROOT/build/Gleaner-$VERSION.dmg"

# 3. Update feed, signed with the Sparkle key; downloads point at this release's assets.
FEED="$ROOT/build/updates"
rm -rf "$FEED" && mkdir -p "$FEED"
cp "$DMG" "$FEED/"
[[ -n "$NOTES" ]] && cp "$NOTES" "$FEED/Gleaner-$VERSION.md"
"$SPARKLE_BIN/generate_appcast" --account gleaner \
    --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
    --embed-release-notes "$FEED"

# 4. Commit the version, then publish.
git -C "$ROOT" add -A
git -C "$ROOT" commit -m "Release $VERSION" >/dev/null || true
git -C "$ROOT" push origin HEAD
NOTES_ARGS=(--generate-notes)
[[ -n "$NOTES" ]] && NOTES_ARGS=(--notes-file "$NOTES")
gh release create "v$VERSION" "$DMG" "$FEED/appcast.xml" --repo "$REPO" --title "拾穗 $VERSION" "${NOTES_ARGS[@]}"
echo "Released v$VERSION"
