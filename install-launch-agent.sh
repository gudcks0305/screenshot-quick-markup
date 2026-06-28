#!/bin/sh
set -eu

cd "$(dirname "$0")"
swift build -c release

PLIST="$HOME/Library/LaunchAgents/com.local.screenshot-quick-markup.plist"
APP="$PWD/dist/Screenshot Quick Markup.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
BIN="$MACOS/screenshot-quick-markup"

rm -rf "$APP"
mkdir -p "$MACOS"
cp "$PWD/.build/release/screenshot-quick-markup" "$BIN"

cat > "$CONTENTS/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>screenshot-quick-markup</string>
  <key>CFBundleIdentifier</key>
  <string>com.local.screenshot-quick-markup</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Screenshot Quick Markup</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
EOF

codesign --force --deep --sign - "$APP" >/dev/null

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.local.screenshot-quick-markup</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BIN</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/tmp/screenshot-quick-markup.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/screenshot-quick-markup.err.log</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/com.local.screenshot-quick-markup" 2>/dev/null || true
launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl kickstart -k "gui/$(id -u)/com.local.screenshot-quick-markup"

echo "Installed com.local.screenshot-quick-markup"
echo "App bundle: $APP"
