#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")"

echo "==> Building (release)..."
swift build -c release

APP="dist/peaktime.app"
echo "==> Assembling $APP ..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp .build/release/peaktime "$APP/Contents/MacOS/peaktime"
cp Info.plist "$APP/Contents/Info.plist"

# SwiftPM resource bundle (Localizable.xcstrings catalog). Without this
# Bundle.module cannot find the translations inside the .app.
for bundle in .build/release/*.bundle(N); do
  cp -R "$bundle" "$APP/Contents/Resources/"
done

echo "==> Signing (ad-hoc)..."
codesign --force --deep --sign - "$APP"

echo "==> Done: $(pwd)/$APP"
echo "To launch: open dist/peaktime.app"
