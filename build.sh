#!/bin/zsh
# Build ClaudeSiri.app.
#   ./build.sh               build, install into ~/Applications and launch
#   ./build.sh --dist [DIR]  build a universal (arm64 + x86_64) app into DIR (default: dist) without
#                            installing it; used by the release workflow
set -e
cd "$(dirname "$0")"

DIST=""
if [[ "$1" == "--dist" ]]; then DIST="${2:-dist}"; fi

VERSION=$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')
VERSION=${VERSION:-0.0.0}
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)

if [[ -n $DIST ]]; then
  swift build -c release --arch arm64 --arch x86_64
  BIN=.build/apple/Products/Release/ClaudeSiri
  mkdir -p "$DIST"
  APP="$DIST/ClaudeSiri.app"
else
  swift build -c release
  BIN=.build/release/ClaudeSiri
  APP=~/Applications/ClaudeSiri.app
  pkill -x ClaudeSiri 2>/dev/null || true
fi

rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ClaudeSiri"
cp assets/AppIcon.icns "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>id.zerodev.claudesiri</string>
<key>CFBundleName</key><string>ClaudeSiri</string>
<key>CFBundleExecutable</key><string>ClaudeSiri</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSAppleEventsUsageDescription</key><string>Open a Claude session in Terminal.</string>
<key>NSMicrophoneUsageDescription</key><string>Ask Claude with your voice.</string>
<key>NSSpeechRecognitionUsageDescription</key><string>Turn your voice into the question text.</string>
</dict></plist>
PL

# Sign with an Apple Development certificate so macOS permissions (Accessibility, Screen Recording,
# Microphone) survive rebuilds. Falls back to ad-hoc signing when no certificate is found.
# Release builds are ad-hoc signed unless SIGN_IDENTITY is set.
if [[ -n $DIST ]]; then
  IDENT="${SIGN_IDENTITY:--}"
else
  IDENT=$(security find-identity -p codesigning -v | awk '/Apple Development/{print $2; exit}')
  IDENT="${IDENT:--}"
fi
codesign --force --timestamp=none -s "$IDENT" "$APP"

if [[ -n $DIST ]]; then
  echo "Built: $APP ($VERSION, build $BUILD)"
else
  open "$APP"
  echo "Installed: $APP"
fi
