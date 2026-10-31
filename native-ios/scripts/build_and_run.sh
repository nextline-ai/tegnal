#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
case "$MODE" in run|--debug|--logs|--telemetry|--verify) ;; *) echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2; exit 2 ;; esac
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJECT="$ROOT_DIR/native-ios/TEGNAL.xcodeproj"

# This is the iOS app running on Apple silicon, not a Mac Catalyst target.
# Let Xcode stop a paused debugger and create/sign its iOS-on-Mac wrapper.
osascript - "$PROJECT" <<'APPLESCRIPT'
on run argv
    tell application "Xcode"
        open POSIX file (item 1 of argv)
        set projectDoc to workspace document "TEGNAL.xcodeproj"
        repeat 60 times
            if loaded of projectDoc then exit repeat
            delay 0.5
        end repeat
        stop projectDoc
        set active scheme of projectDoc to scheme "TEGNAL" of projectDoc
        set active run destination of projectDoc to first run destination of projectDoc whose name is "My Mac (Designed for iPad)"
    end tell
end run
APPLESCRIPT
pkill -x TEGNAL >/dev/null 2>&1 || true
xcodebuild -project "$PROJECT" -scheme TEGNAL -configuration Debug \
    -destination 'platform=macOS,variant=Designed for iPad' build
osascript - "$PROJECT" <<'APPLESCRIPT'
on run argv
    tell application "Xcode"
        set projectDoc to workspace document "TEGNAL.xcodeproj"
        debug projectDoc scheme "TEGNAL" run destination specifier "platform=macOS,variant=Designed for iPad"
    end tell
end run
APPLESCRIPT
case "$MODE" in
    --logs|--telemetry)
        /usr/bin/log stream --info --style compact --predicate 'process == "TEGNAL"'
        ;;
    --verify)
        for attempt in {1..60}; do
            for app_pid in $(pgrep -x TEGNAL || true); do
                # macOS marks a process being debugged with X; only T/Z mean
                # stopped or defunct. Opening both SQLite files proves startup.
                if ps -o stat= -p "$app_pid" | awk '$1 !~ /[TZ]/ { valid = 1 } END { exit !valid }' &&
                    lsof -p "$app_pid" -Fn | awk '/\/memo\.sqlite$/ { comics = 1 } /\/booru\.sqlite$/ { images = 1 } END { exit !(comics && images) }'; then
                    sleep 3
                    kill -0 "$app_pid"
                    exit 0
                fi
            done
            sleep 1
        done
        echo "TEGNAL did not remain running; inspect the Xcode debug console." >&2
        exit 1
        ;;
esac
