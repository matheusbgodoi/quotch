#!/bin/bash
# Gera Quotch.dmg a partir do app JÁ instalado em /Applications (não recompila,
# pra não trocar o cdhash e invalidar o Full Disk Access concedido). Para forçar
# um build antes, rode ./build.sh você mesmo. Uso: bash build-dmg.sh
set -e
APP="/Applications/Quotch.app"
[ -d "$APP" ] || { echo "erro: $APP não existe — rode ./build.sh primeiro"; exit 1; }
OUT=~/Developer/quotch/dist; mkdir -p "$OUT"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/Quotch.app"
ln -s /Applications "$STAGE/Applications"
DMG="$OUT/Quotch.dmg"; rm -f "$DMG"
hdiutil create -volname "Quotch" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
echo "dmg: $DMG ($(du -h "$DMG" | cut -f1))"
