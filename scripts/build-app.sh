#!/bin/bash
# Builds Segue and packages it as build/Segue.app.
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="Segue Local Signing"
APP="build/Segue.app"

swift build -c release
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/Segue" "$APP/Contents/MacOS/Segue"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>io.github.segue.Segue</string>
    <key>CFBundleName</key><string>Segue</string>
    <key>CFBundleExecutable</key><string>Segue</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSAppleEventsUsageDescription</key><string>Segue controls Music to fade and skip songs.</string>
</dict>
</plist>
PLIST

IDENTITIES="$(security find-identity -p codesigning 2>/dev/null || true)"
if [[ "$IDENTITIES" == *"$IDENTITY"* ]] && codesign --force --sign "$IDENTITY" "$APP" 2>/dev/null; then
    echo "Signed with \"$IDENTITY\"."
else
    codesign --force --sign - "$APP"
    echo "Signed ad hoc. macOS will ask for the Automation and Accessibility permissions again"
    echo "after each rebuild. Run scripts/make-signing-cert.sh once to avoid that."
fi
echo "Built $APP"
