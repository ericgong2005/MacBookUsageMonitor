#!/usr/bin/env bash

set -u

print_help() {
  cat <<'EOF'
Usage: ./Deploy.sh [ build | start | stop | help ]

Commands:
  build  - build the swift executable, move it to the UsageMonitor Directory, set up the LaunchAgent
  start  - Load and Start the LaunchAgent
  stop   - Unload the LaunchAgent
  help   - show this help
EOF
}

BUILD_DEST_DIR="/Users/ericgong/Library/UsageMonitor"
PLIST_DEST="/Users/ericgong/Library/LaunchAgents/com.user.usagemonitor.plist"

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
SWIFT_BIN="$SCRIPT_DIR/../.build/arm64-apple-macosx/debug/UsageMonitor"
XML_SRC="$SCRIPT_DIR/UsageMonitorLaunchAgentCommand.xml"

cmd="${1:-help}"

case "$cmd" in
  help)
    print_help
    ;;

  build)
    echo "Building Swift Executable:"
    if ! swift build; then
      echo "Error: swift build failed." >&2
      exit 1
    fi

    echo "Adding UsageMonitor to $BUILD_DEST_DIR"
    if [ ! -f "$SWIFT_BIN" ]; then
      echo "Error: built executable not found at: $SWIFT_BIN" >&2
      exit 1
    fi
    mkdir -p "$BUILD_DEST_DIR"
    cp "$SWIFT_BIN" "$BUILD_DEST_DIR/UsageMonitor"

    echo "Adding LaunchAgent plist to $PLIST_DEST"
    mkdir -p "$(dirname "$PLIST_DEST")"
    # Create the file first, then copy contents as requested
    : > "$PLIST_DEST"
    if [ ! -f "$XML_SRC" ]; then
      echo "Error: XML source not found at: $XML_SRC" >&2
      exit 1
    fi
    cp "$XML_SRC" "$PLIST_DEST"

    echo "Validating plist format"
    if plutil "$HOME/Library/LaunchAgents/com.user.usagemonitor.plist"; then
      echo "plist validation: OK"
    else
      echo "plist validation: FAILED" >&2
      exit 1
    fi

    echo "Reminder:"
    echo "add /Users/Ericgong/Library/UsageMonitor/UsageMonitor to:"
    echo "System Settings > Privacy & Security > Accessibility"
    echo "System Settings > Privacy & Security > Input Monitoring"
    ;;

  start)
    echo "Loading and starting LaunchAgent"
    launchctl load "$HOME/Library/LaunchAgents/com.user.usagemonitor.plist"
    launchctl start com.user.usagemonitor
    echo "Done"
    ;;

  stop)
    echo "Unloading LaunchAgent"
    launchctl unload "$HOME/Library/LaunchAgents/com.user.usagemonitor.plist"
    echo "Done"
    ;;

  *)
    echo "Unknown command: $cmd"
    print_help
    exit 1
    ;;
esac
