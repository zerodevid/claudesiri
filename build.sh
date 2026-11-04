#!/bin/zsh
# Build ClaudeSiri.app lalu pasang ke ~/Applications
set -e
cd "$(dirname "$0")"
swift build -c release
APP=~/Applications/ClaudeSiri.app
pkill -x ClaudeSiri 2>/dev/null || true
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp .build/release/ClaudeSiri "$APP/Contents/MacOS/"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>id.zerodev.claudesiri</string>
<key>CFBundleName</key><string>ClaudeSiri</string>
<key>CFBundleExecutable</key><string>ClaudeSiri</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSAppleEventsUsageDescription</key><string>Buka sesi Claude di Terminal.</string>
<key>NSMicrophoneUsageDescription</key><string>Untuk bertanya ke Claude dengan suara.</string>
<key>NSSpeechRecognitionUsageDescription</key><string>Mengubah suaramu jadi teks pertanyaan.</string>
</dict></plist>
PL
# Tanda tangan dengan sertifikat Apple Development supaya izin macOS (Aksesibilitas, Screen Recording,
# Mikrofon) tetap tersimpan antar build. Fallback ad-hoc kalau sertifikat tak ada.
IDENT=$(security find-identity -p codesigning -v | awk '/Apple Development/{print $2; exit}')
codesign --force --timestamp=none -s "${IDENT:--}" "$APP"
open "$APP"
echo "Terpasang: $APP"
