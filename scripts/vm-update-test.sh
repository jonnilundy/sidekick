#!/bin/zsh
# Runs inside the VM (through scripts/update-test.sh): the old test app against the local feed.
#   1. A scheduled check finds 0.0.2 with no window and no focus: the badge's state is set.
#   2. The menu item's code path (the install-update test hook) shows Sparkle's window.
#   3. With automatic downloads on, the update downloads silently, and the menu item installs it and
#      relaunches the app on 0.0.2.
# Screenshots and the updater log land in out/. Prints UPDATE TEST PASS or FAIL lines.
cd "$(dirname "$0")/.."
rm -rf out && mkdir -p out
ID=com.jonnilundy.sidekick.updatetest
DIR=~/sk-update-test
APP=$DIR/Sidekick.app
LOG=out/updater.log
passed=0; failed=0
ok() { if eval "$1"; then passed=$((passed + 1)); echo "ok   $2"; else failed=$((failed + 1)); echo "FAIL $2"; fi }
post() {
    osascript -l JavaScript - "$ID.$1" <<'JXA' >/dev/null
function run(argv) {
    ObjC.import('Foundation');
    $.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately(argv[0], $(), $(), true);
}
JXA
}
# Waits up to $2 seconds for the log to contain $1.
wait_log() { for _ in $(seq 1 $(( $2 * 2 ))); do /usr/bin/grep -q -- "$1" $LOG && return 0; sleep 0.5; done; return 1 }
app_pid() { pgrep -f "$APP/Contents/MacOS/Sidekick" | head -1 }
reset_defaults() {
    defaults delete $ID >/dev/null 2>&1
    defaults write $ID didFirstRun -bool YES
    defaults write $ID keepWarm -bool NO
    defaults write $ID SUHasLaunchedBefore -bool YES
    defaults write $ID SUEnableAutomaticChecks -bool YES
    # A last check long ago, so the scheduled check runs right after launch.
    defaults write $ID SULastCheckTime -date "2020-01-01 00:00:00 +0000"
    defaults write $ID SUAutomaticallyUpdate -bool $1
}
cleanup() {
    pkill -f "$APP/Contents/MacOS/Sidekick" 2>/dev/null
    [[ -n "${SERVER:-}" ]] && kill $SERVER 2>/dev/null
    [[ -n "${STREAM:-}" ]] && kill $STREAM 2>/dev/null
    defaults delete $ID >/dev/null 2>&1
}
trap cleanup EXIT

pkill -f "$APP/Contents/MacOS/Sidekick" 2>/dev/null
rm -rf $DIR && mkdir -p $DIR
ditto build/update-test/old/Sidekick.app $APP
python3 -m http.server 8765 --bind 127.0.0.1 --directory build/update-test/feed > out/server.log 2>&1 &
SERVER=$!
/usr/bin/log stream --style compact --predicate 'subsystem == "com.jonnilundy.sidekick"' > $LOG 2>&1 &
STREAM=$!
sleep 2
ok "curl -sf http://127.0.0.1:8765/appcast.xml | /usr/bin/grep -q 0.0.2" "the local feed serves 0.0.2"

echo "--- 1. scheduled check, gentle reminder"
reset_defaults NO
FRONT_BEFORE=$(lsappinfo info -only name "$(lsappinfo front)")
open $APP
ok 'wait_log "sparkle up for 0.0.1" 20' "Sparkle starts in the 0.0.1 test copy"
ok 'wait_log "gentle reminder: 0.0.2" 30' "a scheduled check finds 0.0.2 and keeps it a gentle reminder"
sleep 1
post dump-update-state
ok 'wait_log "state available 0.0.2 build 2 ready false" 10' "the state has 0.0.2, so the badge and the menu item show"
ok '/usr/bin/grep "state available 0.0.2" $LOG | /usr/bin/grep -q "visible windows \[\], active false"' "no window and no focus after the check"
FRONT_AFTER=$(lsappinfo info -only name "$(lsappinfo front)")
ok '[[ "$FRONT_AFTER" == "$FRONT_BEFORE" ]]' "the front app did not change ($FRONT_AFTER)"
screencapture -x out/1-badge.png

echo "--- 2. the menu item opens Sparkle's window"
post install-update
ok 'wait_log "showing the found update in Sparkle" 10' "the menu item's code path asks Sparkle to show the update"
sleep 4
screencapture -x out/2-sparkle-window.png
post dump-update-state
sleep 1
ok '/usr/bin/grep "test hook: state" $LOG | tail -1 | /usr/bin/grep -q "active true"' "Sparkle's window brings the app forward"
/usr/bin/grep "test hook: state" $LOG | tail -1
pkill -f "$APP/Contents/MacOS/Sidekick"; sleep 1

echo "--- 3. automatic download, install from the menu, relaunch"
reset_defaults YES
open $APP
ok 'wait_log "0.0.2 downloaded and ready" 60' "0.0.2 downloads and extracts in the background"
OLD_PID=$(app_pid)
post install-update
ok 'wait_log "installing 0.0.2 now" 10' "the menu item installs at once"
for _ in $(seq 1 60); do
    NEW_PID=$(app_pid)
    VERSION=$(defaults read $APP/Contents/Info.plist CFBundleShortVersionString 2>/dev/null)
    [[ "$VERSION" == "0.0.2" && -n "$NEW_PID" && "$NEW_PID" != "$OLD_PID" ]] && break
    sleep 0.5
done
ok '[[ "$VERSION" == "0.0.2" ]]' "the installed app is 0.0.2 (was 0.0.1)"
ok '[[ -n "$NEW_PID" && "$NEW_PID" != "$OLD_PID" ]]' "the app relaunched (pid $OLD_PID -> ${NEW_PID:-none})"
ok 'codesign --verify --strict $APP' "the installed app's signature is valid"
ok 'wait_log "sparkle up for 0.0.2" 20' "the relaunched app runs 0.0.2"
screencapture -x out/3-after-install.png

if (( failed == 0 )); then echo "UPDATE TEST PASS: $passed checks"; exit 0; fi
echo "UPDATE TEST FAIL: $failed of $((passed + failed)) failed"; exit 1
