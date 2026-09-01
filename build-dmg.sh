#!/bin/bash
# Gera Quotch.dmg (app ad-hoc + atalho para Applications). Uso: bash build-dmg.sh
set -e
bash "$(dirname "$0")/build.sh"
APP="/Applications/Quotch.app"
OUT=~/Developer/quotch/dist; mkdir -p "$OUT"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/Quotch.app"
ln -s /Applications "$STAGE/Applications"
DMG="$OUT/Quotch.dmg"; rm -f "$DMG"
hdiutil create -volname "Quotch" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
echo "dmg: $DMG ($(du -h "$DMG" | cut -f1))"
