#!/bin/zsh
# Bundles Meercat as a menu-bar .app so macOS remembers Screen Recording + Accessibility grants.
set -eu
cd "$(dirname "$0")/.."
swift build -c release
APP="$PWD/dist/Meercat.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/Meercat" "$APP/Contents/MacOS/Meercat"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Meercat</string>
<key>CFBundleIdentifier</key><string>dev.meercat.app</string>
<key>CFBundleName</key><string>Meercat</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
# A real identity keeps Screen Recording / Accessibility grants across rebuilds; ad-hoc (-) loses them every build.
IDENTITY="${MEERCAT_SIGN_IDENTITY:-$(security find-identity -p codesigning -v | awk -F\" "/Apple Development/{print \$2; exit}")}"
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $APP"
