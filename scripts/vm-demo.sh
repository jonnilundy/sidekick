#!/bin/zsh
# Runs inside the VM (through scripts/vm-run.sh): records the README demo take.
#   VM_DIR=sidekick-demo scripts/vm-run.sh 'scripts/vm-demo.sh'
# Plays `Sidekick --demo out` against fake-claude in demo mode, records the whole screen to
# out/demo.mov, and saves full screen stills of the finished answers (out/*.png). out/demo.log has
# the timeline and the card frame of each still. Cropping and encoding happen on the Mac.
#
# The media, on the Mac, from build/vm-out/ (screen 2560x1440 pt; demo.mov is 4096x2304 at 1.6 px
# per pt, the stills 5120x2880 at 2x). Both crops are the same 16:9 box of 800x450 pt at the top
# right: the menu bar, the card (440 pt plus the 12 pt edge gap) and the wallpaper on the left.
# Check the trim against the take first: the card arrives about 1.1 s after the log's "show" time,
# and the last slide out ends about 1.2 s after "esc 2". Keep about 0.4 s of desktop at each end.
# The card must fit in 450 pt: the log's still line has its height (271 pt at y 38 for one answer).
#   CUT="fps=30,trim=start=3.6:end=20.5,setpts=PTS-STARTPTS,crop=1280:720:2816:0"
#   ffmpeg -i build/vm-out/demo.mov -vf "$CUT,fps=20,scale=960:540:flags=lanczos,split[a][b];\
#     [a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" \
#     -loop 0 assets/demo.gif
#   ffmpeg -i build/vm-out/dark-1.png -vf crop=1600:900:3520:0 assets/screenshot-dark.png
cd "$(dirname "$0")/.."
rm -rf out && mkdir -p out
APP=build/Sidekick.app/Contents/MacOS/Sidekick
[[ -x "$APP" ]] || { echo "vm-demo: no $APP"; exit 1; }
# The Resend wallpapers live in ~/Pictures/Resend (downloaded once). 8-c is the desktop for takes:
# dark and calm, with a lit, smooth patch at the top right that sets off a black card.
WALLPAPERS=~/Pictures/Resend
mkdir -p $WALLPAPERS
for n in 1 2 3 4 5 6 7 8; do
  for v in a b c; do
    [[ -s $WALLPAPERS/$n-$v.jpg ]] || curl -sfL -o $WALLPAPERS/$n-$v.jpg "https://cdn.resend.com/wallpapers/$n-$v.jpg" \
      || { rm -f $WALLPAPERS/$n-$v.jpg; echo "vm-demo: could not download wallpaper $n-$v"; }
  done
done
# Set it through NSWorkspace in process (no Apple Events, so no permission prompt). It persists,
# and an unchanged desktop is left alone.
WALLPAPER=$WALLPAPERS/8-c.jpg osascript -l JavaScript -e '
ObjC.import("AppKit");
const path = $.NSProcessInfo.processInfo.environment.objectForKey("WALLPAPER").js;
const url = $.NSURL.fileURLWithPath(path);
const workspace = $.NSWorkspace.sharedWorkspace;
const screens = $.NSScreen.screens;
let changed = 0;
for (let i = 0; i < screens.count; i++) {
  const screen = screens.objectAtIndex(i);
  const current = workspace.desktopImageURLForScreen(screen);
  if (current.isNil() || !current.isEqual(url)) {
    workspace.setDesktopImageURLForScreenOptionsError(url, screen, $(), null);
    changed++;
  }
}
"vm-demo: wallpaper " + path + (changed ? " set" : " already set");
'
# Banners sit in the same top right corner as Sidekick. Stop Notification Center for the take and
# bring it back after, so other suites in this VM still get it.
NC_PLIST=/System/Library/LaunchAgents/com.apple.notificationcenterui.plist
launchctl bootout gui/$(id -u)/com.apple.notificationcenterui.agent 2>/dev/null
trap 'launchctl bootstrap gui/$(id -u) $NC_PLIST 2>/dev/null' EXIT
# A crash dialog left over from another suite would sit on the desktop.
pkill -x "Problem Reporter" 2>/dev/null
sleep 1
screencapture -x -v -V 75 out/demo.mov >/dev/null 2>&1 &
REC=$!
sleep 1
SIDEKICK_CLAUDE_PATH="$PWD/scripts/fake-claude" FAKE_CLAUDE_DEMO=1 "$APP" --demo out > out/demo.log 2>&1
CODE=$?
sleep 1
kill -INT $REC 2>/dev/null; wait $REC 2>/dev/null
cat out/demo.log
exit $CODE
