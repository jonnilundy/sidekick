#!/bin/zsh
# Runs inside the VM (through scripts/vm-run.sh): the window probe against fake-claude, recorded to
# out/probe.mov so the motion can be reviewed frame by frame. Screenshots of each state land in out/.
cd "$(dirname "$0")/.."
rm -rf out && mkdir -p out
# Clear banners and stale dialogs so the recording shows only Sidekick.
killall NotificationCenter UserNotificationCenter 2>/dev/null
APP=build/Sidekick.app/Contents/MacOS/Sidekick
[[ -x "$APP" ]] || { echo "vm-test: no $APP"; exit 1; }
screencapture -x -v -V 40 out/probe.mov >/dev/null 2>&1 &
REC=$!
sleep 1
SIDEKICK_DEBUG=${SIDEKICK_DEBUG:-} SIDEKICK_CLAUDE_PATH="$PWD/scripts/fake-claude" FAKE_CLAUDE_DELAY=1 "$APP" --probe out > out/probe.log 2>&1
CODE=$?
sleep 1
kill -INT $REC 2>/dev/null; wait $REC 2>/dev/null
cat out/probe.log | tail -40
exit $CODE
