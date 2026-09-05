#!/bin/sh
set -eu

cd "$(dirname "$0")"
swift build -c release
MARKUP_BUILD_DIR="$(swift build -c release --show-bin-path)"
MARKUP_SOURCE_BIN="$MARKUP_BUILD_DIR/screenshot-quick-markup"
if [ ! -x "$MARKUP_SOURCE_BIN" ]; then
  echo "Built executable not found: $MARKUP_SOURCE_BIN" >&2
  exit 1
fi

PLIST="$HOME/Library/LaunchAgents/com.local.screenshot-quick-markup.plist"
APP="/Applications/Screenshot Quick Markup.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
BIN="$MACOS/screenshot-quick-markup"
SIGNING_IDENTITY="${SCREENSHOT_QUICK_MARKUP_SIGNING_IDENTITY:--}"

if [ -e "$APP" ]; then
  MARKUP_INSTALLED_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null || true)"
  if [ "$MARKUP_INSTALLED_ID" != "com.local.screenshot-quick-markup" ]; then
    echo "Refusing to replace a different application at $APP" >&2
    exit 1
  fi
fi

rm -rf "$APP"
mkdir -p "$MACOS"
cp "$MARKUP_SOURCE_BIN" "$BIN"

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
  <string>0.3.0</string>
  <key>CFBundleVersion</key>
  <string>3</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
EOF

codesign --force --deep --sign "$SIGNING_IDENTITY" "$APP" >/dev/null
if [ "$SIGNING_IDENTITY" = "-" ]; then
  echo "Note: ad-hoc signing may require Screen Recording permission again after rebuilds."
  echo "Set SCREENSHOT_QUICK_MARKUP_SIGNING_IDENTITY to a stable code-signing identity to preserve TCC access."
fi

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
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
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
