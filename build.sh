#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")"

echo "==> Compilando (release)..."
swift build -c release

APP="dist/peaktime.app"
echo "==> Armando $APP ..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp .build/release/peaktime "$APP/Contents/MacOS/peaktime"
cp Info.plist "$APP/Contents/Info.plist"

# Bundle de recursos de SwiftPM (catálogo Localizable.xcstrings). Sin esto
# Bundle.module no encuentra las traducciones dentro de la .app.
for bundle in .build/release/*.bundle(N); do
  cp -R "$bundle" "$APP/Contents/Resources/"
done

echo "==> Firmando (ad-hoc)..."
codesign --force --deep --sign - "$APP"

echo "==> Listo: $(pwd)/$APP"
echo "Para abrirla: open dist/peaktime.app"
