#!/bin/bash
# Builds MacFast.app and the macfast CLI into ./build.
#
# SwiftPM produces a bare executable; SwiftUI needs a real .app bundle to get a
# Dock icon, a menu bar and normal window activation, so the binary is wrapped
# by hand here.
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG=release
BUILD_DIR="build"
APP="$BUILD_DIR/MacFast.app"

# Binário universal. O runner de CI (e boa parte dos Macs novos) é arm64, mas
# quem mais precisa deste app são os Macs Intel antigos rodando OCLP — um
# binário só arm64 simplesmente não abre neles.
ARCH_ARGS="--arch arm64 --arch x86_64"

echo "==> Compilando ($CONFIG, universal)…"
if ! swift build -c "$CONFIG" $ARCH_ARGS 2>/dev/null; then
    echo "aviso: build universal indisponível nesta toolchain; usando a arquitetura nativa."
    ARCH_ARGS=""
    swift build -c "$CONFIG"
fi

BIN_PATH="$(swift build -c "$CONFIG" $ARCH_ARGS --show-bin-path)"

echo "==> Montando $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_PATH/MacFast" "$APP/Contents/MacOS/MacFast"
cp "$BIN_PATH/macfast" "$BUILD_DIR/macfast"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>MacFast</string>
    <key>CFBundleDisplayName</key>
    <string>MacFast</string>
    <key>CFBundleExecutable</key>
    <string>MacFast</string>
    <key>CFBundleIdentifier</key>
    <string>app.macfast.MacFast</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>11.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

# Ad-hoc signature: enough for the app to launch locally. A real release needs
# a Developer ID identity and notarisation.
codesign --force --deep --sign - "$APP" 2>/dev/null || \
    echo "aviso: não foi possível assinar; o app ainda abre pelo menu Abrir do Finder."

echo
echo "Arquiteturas do app: $(lipo -archs "$APP/Contents/MacOS/MacFast" 2>/dev/null || echo desconhecidas)"
echo
echo "Pronto:"
echo "  app: $APP"
echo "  cli: $BUILD_DIR/macfast"
echo
echo "Para testar sem alterar nada:  $BUILD_DIR/macfast --dry-run apply oclp"
