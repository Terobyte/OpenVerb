#!/usr/bin/env bash
set -euo pipefail

PLIST_NAME="io.openverb.engine"
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST_PATH="$PLIST_DIR/$PLIST_NAME.plist"

if [ ! -f "$PLIST_PATH" ]; then
    echo "plist not found at $PLIST_PATH — nothing to uninstall."
    exit 0
fi

echo "Unloading $PLIST_NAME..."
launchctl unload "$PLIST_PATH" 2>/dev/null || true

echo "Removing $PLIST_PATH..."
rm -f "$PLIST_PATH"

echo "Uninstalled $PLIST_NAME."
