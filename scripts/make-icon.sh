#!/usr/bin/env bash
# Regenerates Resources/AppIcon.icns from scripts/make-icon.swift.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/build/icon"
rm -rf "$WORK" && mkdir -p "$WORK/AppIcon.iconset"

swift "$ROOT/scripts/make-icon.swift" "$WORK/AppIcon-1024.png"
for size in 16 32 128 256 512; do
    sips -z $size $size "$WORK/AppIcon-1024.png" --out "$WORK/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z $double $double "$WORK/AppIcon-1024.png" --out "$WORK/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$WORK/AppIcon.iconset" -o "$ROOT/Resources/AppIcon.icns"
echo "Wrote Resources/AppIcon.icns"
