#!/bin/bash
# Builds ClaudeUsage.app.
#
#   ./build.sh                  build into ./build
#   ./build.sh --install        build and put it in /Applications
#   ./build.sh --notarize       build, send to Apple and staple the ticket
#   ./build.sh --zip            build and pack dist/ClaudeUsage.zip for a release
#   ./build.sh --notarize --zip --install
#
# The signature picks itself: if the keychain holds a Developer ID certificate
# it is used, otherwise ad-hoc. Override with CLAUDE_USAGE_SIGN_IDENTITY.
# The notarisation credentials come from a notarytool keychain profile —
# CLAUDE_USAGE_NOTARY_PROFILE, "keyflip" by default (one Apple account, one
# profile; it is not tied to a single app).
set -euo pipefail

cd "$(dirname "$0")"
APP_NAME="ClaudeUsage"
BUNDLE="build/$APP_NAME.app"
BUNDLE_ID="com.rybchynskyi.claudeusage"
VERSION="1.2"
NOTARY_PROFILE="${CLAUDE_USAGE_NOTARY_PROFILE:-keyflip}"

DO_INSTALL=0
DO_NOTARIZE=0
DO_ZIP=0
for arg in "$@"; do
  case "$arg" in
    --install)  DO_INSTALL=1 ;;
    --notarize) DO_NOTARIZE=1 ;;
    --zip)      DO_ZIP=1 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

# --- Which certificate ------------------------------------------------------
IDENTITY="${CLAUDE_USAGE_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  AVAILABLE="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  # sed -n '1p' drains the stream; head -1 would close the pipe and, under
  # pipefail, fail the whole script depending on how buffering falls.
  IDENTITY="$(printf '%s\n' "$AVAILABLE" \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' \
    | sed -n '1p')"
fi

if [[ -n "$IDENTITY" ]]; then
  # A secure timestamp is required for notarisation, and it lets signed builds
  # outlive the certificate they were signed with.
  TIMESTAMP_FLAG="--timestamp"
  echo "signing as: $IDENTITY"
else
  IDENTITY="-"
  TIMESTAMP_FLAG="--timestamp=none"
  echo "no Developer ID certificate, signing ad-hoc (cannot be notarized)"
  if [[ "$DO_NOTARIZE" == "1" ]]; then
    echo "error: notarisation needs a Developer ID certificate" >&2
    exit 1
  fi
fi

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

# --- Signing ----------------------------------------------------------------
# --options runtime turns on the hardened runtime. For this app that is not a
# formality: without it any process of the same user could inject a library
# (DYLD_INSERT_LIBRARIES) into a process that holds a cached administrator
# authorisation. It is also required for notarisation.
codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" --options runtime \
  $TIMESTAMP_FLAG "$BUNDLE"

# Collect the output in a variable rather than piping into grep -q: grep exits
# on the first match, codesign gets SIGPIPE, and with pipefail the script dies —
# intermittently, depending on buffering.
SIGNATURE="$(codesign -dv "$BUNDLE" 2>&1 || true)"
case "$SIGNATURE" in
  *runtime*) ;;
  *) echo "error: the hardened runtime did not take" >&2; exit 1 ;;
esac
ENTITLEMENTS="$(codesign -d --entitlements - "$BUNDLE" 2>/dev/null || true)"
case "$ENTITLEMENTS" in
  *get-task-allow*)
    echo "error: get-task-allow is in the signature — another process could attach" >&2
    exit 1 ;;
esac
codesign --verify --strict "$BUNDLE"
echo "built $BUNDLE"

# --- Notarisation -----------------------------------------------------------
if [[ "$DO_NOTARIZE" == "1" ]]; then
  SUBMIT_ZIP="build/$APP_NAME-notarize.zip"
  rm -f "$SUBMIT_ZIP"
  ditto -c -k --keepParent "$BUNDLE" "$SUBMIT_ZIP"

  echo "sending to Apple (a few minutes)…"
  xcrun notarytool submit "$SUBMIT_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  rm -f "$SUBMIT_ZIP"

  # Without the stapled ticket the first launch needs the network, and offline
  # it walks straight into Gatekeeper.
  xcrun stapler staple "$BUNDLE"
  echo "checking through Gatekeeper's eyes…"
  spctl -a -vvv -t install "$BUNDLE"
fi

# --- Packaging --------------------------------------------------------------
# After stapling, not before: the ticket lives inside the bundle, and the point
# of the zip is that whoever downloads it never sees a warning.
if [[ "$DO_ZIP" == "1" ]]; then
  # ditto, not zip: it keeps the bundle's symlinks and metadata intact.
  mkdir -p dist
  rm -f "dist/$APP_NAME.zip"
  ditto -c -k --sequesterRsrc --keepParent "$BUNDLE" "dist/$APP_NAME.zip"
  echo "packaged dist/$APP_NAME.zip"
fi

if [[ "$DO_INSTALL" == "1" ]]; then
  DEST="/Applications/$APP_NAME.app"
  if [[ ! -w /Applications ]]; then DEST="$HOME/Applications/$APP_NAME.app"; mkdir -p "$HOME/Applications"; fi
  # Quit politely first: a kill signal leaves no chance to undo disablesleep.
  if pgrep -x "$APP_NAME" >/dev/null; then
    osascript -e "quit app id \"$BUNDLE_ID\"" >/dev/null 2>&1 || pkill -x "$APP_NAME" || true
    sleep 1                    # let the old instance go before its bundle disappears
  fi
  rm -rf "$DEST"
  cp -R "$BUNDLE" "$DEST"
  open "$DEST" || { sleep 1; open "$DEST"; }
  echo "installed $DEST"
fi
