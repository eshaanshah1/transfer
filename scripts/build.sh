#!/bin/zsh
# Builds Transfer.app into ./build. Pass --install to copy it to /Applications and launch it.
set -euo pipefail
cd "${0:a:h}/.."

swift build -c release
[[ -f Resources/AppIcon.icns ]] || swift scripts/make-icon.swift Resources/AppIcon.icns

APP=build/Transfer.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Transfer "$APP/Contents/MacOS/Transfer"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Transfer || true
  rm -rf /Applications/Transfer.app
  cp -R "$APP" /Applications/Transfer.app
  open /Applications/Transfer.app
  echo "Installed /Applications/Transfer.app"
fi
