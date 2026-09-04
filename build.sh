#!/bin/bash
set -e
APP="/Applications/Quotch.app"
SRC=~/Developer/quotch/Sources
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Quotch</string>
  <key>CFBundleDisplayName</key><string>Quotch</string>
  <key>CFBundleIdentifier</key><string>com.matheus.quotch</string>
  <key>CFBundleExecutable</key><string>Quotch</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleShortVersionString</key><string>0.4</string>
  <key>CFBundleVersion</key><string>4</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSUIElement</key><true/>
  <key>CFBundleIconFile</key><string>AppIcon</string>
</dict>
</plist>
PLIST
cp ~/Developer/quotch/Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

swiftc -O -target arm64-apple-macos14 -lsqlite3 \
  -o "$APP/Contents/MacOS/Quotch" \
  "$SRC"/Design.swift \
  "$SRC"/Motion.swift \
  "$SRC"/Model.swift \
  "$SRC"/Identity.swift \
  "$SRC"/Stacks.swift \
  "$SRC"/Providers.swift \
  "$SRC"/ChromeCookies.swift \
  "$SRC"/SafariCookies.swift \
  "$SRC"/BrowserAccess.swift \
  "$SRC"/FlowWeb.swift \
  "$SRC"/Vault.swift \
  "$SRC"/NotchGeometry.swift \
  "$SRC"/NotchShape.swift \
  "$SRC"/Glyphs.swift \
  "$SRC"/Spinner.swift \
  "$SRC"/NotchView.swift \
  "$SRC"/HoverCard.swift \
  "$SRC"/Interactions.swift \
  "$SRC"/Config.swift \
  "$SRC"/ConfigBridge.swift \
  "$SRC"/SettingsContent.swift \
  "$SRC"/SettingsWindow.swift \
  "$SRC"/NotchPanel.swift \
  "$SRC"/main.swift
SIGN_ID="${QUOTCH_SIGN_ID:-Evie Dev}"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
  codesign --force --deep --sign "$SIGN_ID" "$APP" && echo "signed with: $SIGN_ID"
else
  codesign --force --sign - "$APP" && echo "signed ad-hoc (Full Disk Access won't persist across rebuilds)"
fi
echo "build ok: $APP"
