#!/usr/bin/env bash
# Builds a debug app and runs it attached to this terminal.
#
# Launching the executable directly (instead of `open build/拾穗.app`) makes
# macOS attribute file access to the terminal, so granting Full Disk Access to
# your terminal or editor once is enough during development. An ad-hoc signed
# app launched from Finder would need a fresh grant after every rebuild.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/build-app.sh" debug
pkill -x Gleaner 2>/dev/null || true
exec "$ROOT/build/拾穗.app/Contents/MacOS/Gleaner"
