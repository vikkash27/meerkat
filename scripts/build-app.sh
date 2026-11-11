#!/bin/zsh
# Bundles a menu-bar .app so macOS remembers its Screen Recording / Microphone / Accessibility grants.
# Usage: ./scripts/build-app.sh [Meercat|BSDetector]
set -eu
cd "$(dirname "$0")/.."
NAME="${1:-Meercat}"
case "$NAME" in
  Meercat)    ID=dev.meercat.app;        MIN=14.0 ;;
  BSDetector) ID=dev.meercat.bsdetector; MIN=26.0 ;;
  *) echo "Unknown app: $NAME"; exit 1 ;;
esac
swift build -c release --product "$NAME"
APP="$PWD/dist/$NAME.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/$NAME" "$APP/Contents/MacOS/$NAME"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>$NAME</string>
<key>CFBundleIdentifier</key><string>$ID</string>
<key>CFBundleName</key><string>$NAME</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>LSMinimumSystemVersion</key><string>$MIN</string>
<key>LSUIElement</key><true/>
<key>NSMicrophoneUsageDescription</key><string>Transcribes your side of the call on-device.</string>
<key>NSSpeechRecognitionUsageDescription</key><string>Transcribes the call on-device.</string>
</dict></plist>
PLIST
# A real identity keeps the permission grants across rebuilds; ad-hoc (-) loses them every build.
IDENTITY="${MEERCAT_SIGN_IDENTITY:-$(security find-identity -p codesigning -v | awk -F\" "/Apple Development/{print \$2; exit}")}"
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $APP"
