#!/bin/zsh
# Builds DiskBro.app into ./build. Pass --install to copy it to /Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
APP=build/DiskBro.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/DiskBro "$APP/Contents/MacOS/DiskBro"
cp Resources/Info.plist "$APP/Contents/Info.plist"

ICONSET=build/AppIcon.iconset
if [[ ! -f build/AppIcon.icns ]]; then
  swift scripts/make_icon.swift "$ICONSET"
  iconutil -c icns "$ICONSET" -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --deep --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  rm -rf /Applications/DiskBro.app
  cp -R "$APP" /Applications/DiskBro.app
  echo "Installed to /Applications/DiskBro.app"
fi
