#!/bin/bash
# Сборка PuntoLite.app (+ PuntoLite.zip и PuntoLite.dmg при --package)
#   VERSION=1.2.0 GITHUB_REPO=owner/repo SIGN_ID="PuntoLite Signing" scripts/build.sh --package
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.0.0-dev}"
GITHUB_REPO="${GITHUB_REPO:-}"
SIGN_ID="${SIGN_ID:--}"          # «-» = ad-hoc подпись (локальная сборка)
OUT=build
APP="$OUT/PuntoLite.app"

rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
bash scripts/make-icons.sh
cp Resources/AppIcon.icns Resources/MenuIcon.pdf "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.puntolite</string>
  <key>CFBundleName</key><string>PuntoLite</string>
  <key>CFBundleDisplayName</key><string>PuntoLite</string>
  <key>CFBundleExecutable</key><string>PuntoLite</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>PLGitHubRepo</key><string>${GITHUB_REPO}</string>
</dict></plist>
PLIST

FRAMEWORKS=(-framework Cocoa -framework Carbon -framework ApplicationServices -framework ServiceManagement)
for ARCH in arm64 x86_64; do
  swiftc -O -target "$ARCH-apple-macos13.0" Sources/*.swift -o "$OUT/PuntoLite-$ARCH" "${FRAMEWORKS[@]}"
done
lipo -create "$OUT/PuntoLite-arm64" "$OUT/PuntoLite-x86_64" -output "$APP/Contents/MacOS/PuntoLite"
rm "$OUT"/PuntoLite-arm64 "$OUT"/PuntoLite-x86_64

# Постоянный сертификат => одинаковая подпись у всех версий =>
# macOS не сбрасывает разрешение Accessibility после обновления.
codesign --force --deep --sign "$SIGN_ID" "$APP"
codesign --verify --deep --strict "$APP"
echo "Собрано: $APP ($VERSION)"

if [[ "${1:-}" == "--package" ]]; then
  ditto -c -k --keepParent "$APP" "$OUT/PuntoLite.zip"
  STAGE="$OUT/dmg"
  mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "PuntoLite" -srcfolder "$STAGE" -ov -format UDZO "$OUT/PuntoLite.dmg"
  rm -rf "$STAGE"
  echo "Пакеты: $OUT/PuntoLite.zip, $OUT/PuntoLite.dmg"
fi
