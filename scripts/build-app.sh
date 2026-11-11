#!/bin/zsh
# Bundles a menu-bar .app so macOS remembers its Screen Recording / Microphone / Accessibility grants.
# Usage: ./scripts/build-app.sh
# Optional: BS_BUILD_SCRATCH=/tmp/meerkat-build BS_BUILD_DISABLE_SANDBOX=1
set -eu
cd "$(dirname "$0")/.."
NAME=BSDetector ID=dev.meercat.bsdetector MIN=26.0
build_args=(-c release)
if [[ -n "${BS_BUILD_SCRATCH:-}" ]]; then
    build_args+=(--scratch-path "$BS_BUILD_SCRATCH")
fi
if [[ "${BS_BUILD_DISABLE_SANDBOX:-0}" == "1" ]]; then
    build_args+=(--disable-sandbox)
fi
swift build "${build_args[@]}" --product "$NAME"
APP="$PWD/dist/$NAME.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp "$(swift build "${build_args[@]}" --show-bin-path)/$NAME" "$APP/Contents/MacOS/$NAME"
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
<key>LSUIElement</key><false/>
<key>NSMicrophoneUsageDescription</key><string>Transcribes your side of the call on-device.</string>
<key>NSSpeechRecognitionUsageDescription</key><string>Transcribes the call on-device.</string>
</dict></plist>
PLIST
# Documents sync can attach Finder metadata to the newly generated bundle.
for attribute in com.apple.FinderInfo com.apple.ResourceFork; do
    xattr -dr "$attribute" "$APP" 2>/dev/null || true
done
# A real identity keeps the permission grants across rebuilds; ad-hoc (-) loses them every build.
# Without one, a local self-signed "BSDetector Local Signing" cert (see README) also keeps them: TCC pins the cert, not the build.
IDENTITY="${MEERCAT_SIGN_IDENTITY:-$(security find-identity -p codesigning -v | awk -F\" "/Apple Development/{print \$2; exit}")}"
[ -z "$IDENTITY" ] && security find-identity -p codesigning | grep -q "BSDetector Local Signing" && IDENTITY="BSDetector Local Signing"
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $APP"
