#!/usr/bin/env bash
set -euo pipefail

PLIST_NAME="io.openverb.engine"
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST_PATH="$PLIST_DIR/$PLIST_NAME.plist"
LOG_DIR="$HOME/.openverb/logs"

ENGINE_BIN="${OPENVERB_ENGINE_PATH:-/usr/local/bin/openverb-engine}"

mkdir -p "$PLIST_DIR" "$LOG_DIR"

if [ -f "$PLIST_PATH" ]; then
    echo "Unloading existing $PLIST_NAME..."
    launchctl unload "$PLIST_PATH" 2>/dev/null || true
fi

cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$PLIST_NAME</string>
    <key>ProgramArguments</key>
    <array>
        <string>$ENGINE_BIN</string>
        <string>--listen</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/engine-launchd.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin</string>
    </dict>
</dict>
</plist>
EOF

launchctl load "$PLIST_PATH"
echo "Installed and loaded $PLIST_NAME."
echo "  plist: $PLIST_PATH"
echo "  log:   $LOG_DIR/engine-launchd.log"
