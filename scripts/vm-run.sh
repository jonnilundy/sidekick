#!/bin/bash
# Run a command on Sidekick inside the Tart VM on iris-agi, never on this Mac.
#   vm-run.sh                  sync the repo and build/Sidekick.app, then run scripts/vm-test.sh in the VM
#   vm-run.sh '<command>'      sync, then run <command> in the VM's ~/sidekick folder
# VM_DIR=sidekick-<task> syncs into ~/$VM_DIR instead (staging on iris-agi too), so parallel
# worktrees do not overwrite each other. Default: sidekick.
# Build on this Mac first (scripts/build-app.sh): the built build/Sidekick.app is synced in as is.
# The default command needs it. A custom command runs without that check.
# The command runs in the VM's logged in GUI session (launchctl asuser), as a file, so windows work
# there and no quoted command string crosses two ssh hops. Modeled on deck/scripts/vm-run.sh.
# If the VM is not running, the script starts it (headless, no audio) and waits for its IP.
# After the command, the VM's ~/$VM_DIR/out/ folder (if any) is copied back to build/vm-out/ on this Mac.
# The script exits with the exit code of the command, not of the copy back.
# Runs are serialized with a lock on iris-agi (~/vm-sync/.vm-gui.lock), shared with Deck: window tests
# share one VM screen, so parallel runs steal focus and clicks from each other. The lock covers only
# the VM command. A run waits; a lock older than 15 minutes is stale.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
DEFAULT_CMD="scripts/vm-test.sh"
CMD="${*:-$DEFAULT_CMD}"
VM_DIR="${VM_DIR:-sidekick}"
[[ "$VM_DIR" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "vm-run: VM_DIR must be a plain folder name" >&2; exit 1; }
if [[ "$CMD" == "$DEFAULT_CMD" && ! -d "$REPO/build/Sidekick.app" ]]; then
  echo "vm-run: no build/Sidekick.app, run scripts/build-app.sh first" >&2; exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
printf '#!/bin/zsh -l\ncd ~/%s || exit 1\n%s\n' "$VM_DIR" "$CMD" > "$TMP/vm-cmd.sh"

rsync -az --delete --exclude .git --exclude .build --exclude /build/vm-out "$REPO/" "iris-agi:vm-sync/$VM_DIR/"
rsync -az "$TMP/vm-cmd.sh" "iris-agi:vm-sync/$VM_DIR-cmd.sh"

rc=0
ssh -o BatchMode=yes iris-agi VM_DIR="$VM_DIR" bash -s <<'REMOTE' || rc=$?
set -uo pipefail
TART=~/tools/tart.app/Contents/MacOS/tart
if ! IP=$($TART ip main-thing-box --wait 5 2>/dev/null); then
  echo "vm-run: starting main-thing-box" >&2
  mkdir -p ~/tools/logs
  nohup $TART run --no-graphics --no-audio main-thing-box >> ~/tools/logs/tart-run.log 2>&1 &
  IP=$($TART ip main-thing-box --wait 90) || { echo "vm-run: VM did not come up in 90s" >&2; exit 1; }
fi
KEY=(-o BatchMode=yes -o StrictHostKeyChecking=no -i ~/.ssh/tart-vm)
set -e
rsync -az --delete -e "ssh ${KEY[*]}" ~/vm-sync/$VM_DIR/ "admin@$IP:$VM_DIR/"
rsync -az -e "ssh ${KEY[*]}" ~/vm-sync/$VM_DIR-cmd.sh "admin@$IP:$VM_DIR-cmd.sh"
LOCK=~/vm-sync/.vm-gui.lock
waited=0
until mkdir "$LOCK" 2>/dev/null; do
  age=$(( $(date +%s) - $(stat -f %m "$LOCK" 2>/dev/null || date +%s) ))
  if (( age > 900 )); then echo "vm-run: clearing stale lock ($(cat "$LOCK/owner" 2>/dev/null))" >&2; rm -rf "$LOCK"; continue; fi
  (( waited == 0 )) && echo "vm-run: waiting for another VM run ($(cat "$LOCK/owner" 2>/dev/null))" >&2
  waited=1; sleep 3
done
echo "$VM_DIR $(date +%H:%M:%S)" > "$LOCK/owner"
trap 'rm -rf "$LOCK"' EXIT
set +e
ssh -n "${KEY[@]}" "admin@$IP" "chmod +x ~/$VM_DIR-cmd.sh && sudo launchctl asuser 501 sudo -u admin ~/$VM_DIR-cmd.sh"
rc=$?
rm -rf "$LOCK"
OUT=~/vm-sync/$VM_DIR-out
rm -rf "$OUT"; mkdir -p "$OUT"
rsync -az -e "ssh ${KEY[*]}" "admin@$IP:$VM_DIR/out/" "$OUT/" 2>/dev/null || true
exit $rc
REMOTE

rm -rf "$REPO/build/vm-out"
mkdir -p "$REPO/build/vm-out"
rsync -az "iris-agi:vm-sync/$VM_DIR-out/" "$REPO/build/vm-out/" || echo "vm-run: could not copy build/vm-out back" >&2
exit $rc
