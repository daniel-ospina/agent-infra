#!/bin/bash
# launchd-controller.sh — the launchd entry point: keep the controller alive INSIDE tmux.
#
# ⛔ WHY THIS EXISTS (measured 2026-10-18, this Mac). A launchd job cannot read the product
# checkout. The repo lives under ~/Documents, which macOS TCC protects, so a launchd-born
# `/bin/bash` gets `Operation not permitted` on the whole tree — not just on its cwd:
#
#   launchd job /bin/bash   -> head -c 12 ~/Documents/GitHub/tortoise/pyproject.toml : EPERM
#   launchd job tmux        -> [project]                                              : OK
#   fresh `tmux -L sock`    -> [project]                                              : OK
#
# So the fix is NOT a better cwd. `cd` into the repo SUCCEEDS and every read inside it still
# fails; `git` then dies with `Unable to read current working directory: Operation not
# permitted`, `_claim_commit` returns "", and every candidate is refused with the misleading
# "[dispatch] #N NOT dispatched — could not build claim commit". install.sh already documents
# this TCC class for the gh shim ("macOS TCC blocks launchd from reading ~/Documents").
#
# The Full Disk Access grant on this box is attached to the **tmux binary**. A process forked by
# a tmux server therefore inherits it, whatever launched that server (the fresh-socket case above
# proves it is the binary's grant, not a particular server's birth lineage). Running the
# controller as a tmux pane command is what gives it a repo it can actually read.
#
# ⛔ THE SESSION NAME MUST NOT COLLIDE WITH THE LANE PREFIXES. orch-loop.sh counts concurrency
# with `tmux ls | grep -c '^lane-'` / '^fix-' / '^merge-' and reaps with '^(merge|lane|fix)-';
# `orch-controller` matches none of those, so it can never be counted as a lane or reaped.
#
# ⛔ THE JOB'S WorkingDirectory MUST NOT BE THE REPO. A launchd job started with a TCC-denied cwd
# cannot even `getcwd` (bash: `getcwd: cannot access parent directories: Operation not
# permitted`), which breaks python3 (`PermissionError`) and therefore the refresh's reap pass —
# that is how the candidate queue froze for six hours. ~/orchestrator is outside TCC.

set -u

TMUX_BIN="${TMUX_BIN:-/opt/homebrew/bin/tmux}"
O="${O:-/Users/danielospina/orchestrator}"
S="${CONTROLLER_SESSION:-orch-controller}"

[ -x "$TMUX_BIN" ] || { echo "launchd-controller: tmux not found at $TMUX_BIN" >&2; exit 78; }

# -A: succeed (and do nothing) when the session already exists, so a KeepAlive kick is idempotent
# and can never start a SECOND controller behind the running one.
"$TMUX_BIN" new-session -A -d -s "$S" "exec /bin/bash '$O/orch-loop.sh'" || exit $?

# Block while the controller's session lives, so KeepAlive gives real supervision: when the
# controller exits, this script exits, and launchd starts a fresh one. Without the block the job
# would exit immediately after creating the session and KeepAlive would spin.
while "$TMUX_BIN" has-session -t "=$S" 2>/dev/null; do sleep 5; done

# Floor the restart rate. orch-loop.sh exits 0 at once when another controller holds the lock
# (a peer in the FDA lineage, or a leftover). launchd already throttles KeepAlive to 10s; this
# keeps the log honest instead of printing a start line every throttle window.
sleep 15
exit 0
