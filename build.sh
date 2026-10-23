#!/bin/bash
# Builds ClaudeUsage.app. Pass --install to copy it into /Applications and launch it.
set -euo pipefail

cd "$(dirname "$0")"
APP_NAME="ClaudeUsage"
BUNDLE="build/$APP_NAME.app"
BUNDLE_ID="com.rybchynskyi.claudeusage"
VERSION="1.0"

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

swiftc -O -swift-version 5 \
  -target arm64-apple-macos13 \
  -framework AppKit -framework ServiceManagement -framework IOKit \
  -o "$BUNDLE/Contents/MacOS/$APP_NAME" \
  Sources/Credentials.swift Sources/UsageAPI.swift Sources/Brand.swift Sources/Views.swift Sources/SleepGuard.swift Sources/StatusBarController.swift Sources/main.swift

# The icon is generated rather than checked in, so the repo stays binary-free.
if [[ ! -f build/AppIcon.icns ]]; then
  swiftc -O -swift-version 5 -framework AppKit \
    Sources/Brand.swift Sources/Views.swift Tools/MakeIcon.swift -o build/makeicon
  ./build/makeicon build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$BUNDLE/Contents/Resources/AppIcon.icns"

cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Claude Usage</string>
  <key>CFBundleDisplayName</key><string>Claude Usage</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"

# Ad-hoc signature: keeps the bundle's identity stable so macOS and the keychain
# treat it as the same app across launches.
codesign --force --sign - --identifier "$BUNDLE_ID" "$BUNDLE" >/dev/null
echo "built $BUNDLE"

if [[ "${1:-}" == "--zip" ]]; then
  # ditto, not zip: it keeps the bundle's symlinks and metadata intact.
  mkdir -p dist
  rm -f "dist/$APP_NAME.zip"
  ditto -c -k --sequesterRsrc --keepParent "$BUNDLE" "dist/$APP_NAME.zip"
  echo "packaged dist/$APP_NAME.zip"
fi

if [[ "${1:-}" == "--install" ]]; then
  DEST="/Applications/$APP_NAME.app"
  if [[ ! -w /Applications ]]; then DEST="$HOME/Applications/$APP_NAME.app"; mkdir -p "$HOME/Applications"; fi
  pkill -x "$APP_NAME" 2>/dev/null || true
  sleep 1                      # let the old instance go before its bundle disappears
  rm -rf "$DEST"
  cp -R "$BUNDLE" "$DEST"
  open "$DEST" || { sleep 1; open "$DEST"; }
  echo "installed $DEST"
fi
