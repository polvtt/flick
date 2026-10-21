#!/bin/bash
# Compile Flick et l'empaquette en Flick.app (agent barre de menus).
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Flick.app"
MACOS="$APP/Contents/MacOS"
rm -rf "$APP"
mkdir -p "$MACOS"

echo "→ Compilation…"
swiftc -O \
  -framework AppKit -framework ApplicationServices \
  Sources/main.swift \
  -o "$MACOS/Flick"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>            <string>Flick</string>
  <key>CFBundleDisplayName</key>     <string>Flick</string>
  <key>CFBundleIdentifier</key>      <string>local.flick.windowgestures</string>
  <key>CFBundleVersion</key>         <string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleExecutable</key>      <string>Flick</string>
  <key>CFBundlePackageType</key>     <string>APPL</string>
  <key>LSMinimumSystemVersion</key>  <string>12.0</string>
  <key>LSUIElement</key>             <true/>
  <key>NSHumanReadableCopyright</key><string>Usage personnel</string>
</dict>
</plist>
PLIST

echo "→ Nettoyage des attributs étendus…"
xattr -cr "$APP" 2>/dev/null || true
find "$APP" -exec xattr -c {} \; 2>/dev/null || true

# Signature avec l'identité stable « Flick Dev » si elle existe (l'autorisation
# Accessibilité survit alors aux recompilations). Sinon, repli ad-hoc.
KC="$HOME/Library/Keychains/flick-signing.keychain-db"
if security find-identity "$KC" 2>/dev/null | grep -q "Flick Dev"; then
    echo "→ Signature avec l'identité stable « Flick Dev »…"
    security unlock-keychain -p flickpass "$KC" 2>/dev/null || true
    # DR explicite basée sur le CERTIFICAT (stable aux recompilations), au lieu
    # du cdhash par défaut — c'est ce que TCC mémorise pour l'autorisation.
    REQ=$(mktemp)
    echo 'designated => identifier "local.flick.windowgestures" and certificate leaf[subject.CN] = "Flick Dev"' > "$REQ"
    if ! codesign --force --keychain "$KC" --sign "Flick Dev" --requirements "$REQ" "$APP" 2>/dev/null; then
        echo "  (1re tentative échouée — re-nettoyage xattr et nouvelle tentative)"
        find "$APP" -exec xattr -c {} \; 2>/dev/null || true
        codesign --force --keychain "$KC" --sign "Flick Dev" --requirements "$REQ" "$APP"
    fi
    rm -f "$REQ"
else
    echo "→ Signature ad-hoc (identité stable absente ; lance setup_signing.sh)…"
    codesign --force --sign - "$APP"
fi

echo "✓ Construit : $APP"
codesign -dvv "$APP" 2>&1 | grep -E "Authority|CDHash=" | head -2
