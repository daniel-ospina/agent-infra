#!/bin/bash
# launchd-controller.sh — the launchd ENTRY POINT for the orchestrator: it supervises the controller
# as a tmux session, and BLOCKS while that session lives so `KeepAlive` is real supervision.
#
# It is what the plist's `ProgramArguments` must point at on a macOS box — the INSTALLED plist on the
# Mac that carried this defect does point here (`/bin/bash $O/launchd-controller.sh`), while main's
# `launchd.plist.template` still renders `__O__/orch-loop.sh`; flipping the shipped template is PR
# #2020's hunk, deliberately not duplicated here. It is shipped from HERE
# (`scripts/orchestrator-harness/`) and it is the only place that knows how a Mac starts a
# controller. ⛔ SO ON A FRESH `install.sh` RENDER THIS FILE IS INSTALLED BUT NOT YET SELECTED.
#
# ⛔ WHY THIS FILE IS IN THE REPO AT ALL (agent-infra#2098, the live-only-overlay class).
# It lived ONLY in `~/orchestrator` on the Mac for weeks: `git grep -l launchd-controller` found
# nothing but two `docs/ops/*.md` paragraphs. That is the same class that already reverted other
# fixes once (#2020), and it is a *silent* one: `deploy-harness.sh` mirrors this directory from the
# repo, so a redeploy installs whatever main carries and the job's own ProgramArguments goes back to
# whatever that is; and `check-deployed-drift.sh` compares only files the repo ships, so it could not
# say "the job's entry point is missing" — it could only call the hand-placed copy "present in $O but
# NOT shipped by the repo". A file a deploy does not know about is a file that will be re-broken.
# Shipping it here is what makes its bytes knowable and its absence a reported DRIFT (both
# directions are pinned: shipped-but-missing, and present-but-unshipped).
#
# ⛔ WHY THE CONTROLLER RUNS INSIDE TMUX — macOS TCC, measured 2026-10-18 on the Mac.
# The product checkout lives under ~/Documents, which TCC protects. A launchd-born `/bin/bash` cannot
# read the tree at all — and the denial is on the CONTENT, not merely on the job's cwd, so "give it a
# better WorkingDirectory" does not fix it:
#
#   launchd job /bin/bash  -> head -c 12 ~/Documents/GitHub/tortoise/pyproject.toml : EPERM
#   launchd job tmux       -> [project]                                             : OK
#   fresh `tmux -L sock`   -> [project]                                             : OK
#
# `cd` into the repo SUCCEEDS and every read inside it still fails; `git` then dies with `Unable to
# read current working directory: Operation not permitted`, `_claim_commit` returns "", and EVERY
# candidate is refused with the misleading `could not build claim commit` while `gh` reads (cwd-blind)
# look healthy and `launchctl print` says `running`. The Full Disk Access grant on this class of box
# is attached to the **tmux binary**, so a process forked by a tmux server inherits it whatever
# launched that server — that is why running the controller as a tmux pane command is the fix.
#
# ⛔ THE SESSION NAME MUST NOT COLLIDE WITH THE LANE PREFIXES. `orch-loop.sh` counts concurrency with
# `tmux ls | grep -c '^lane-'` / '^fix-' / '^merge-' and reaps with '^(merge|lane|fix)-'.
# `orch-controller` matches none of them, so it can never be counted as a lane or reaped as one. The
# `lane-*|fix-*|merge-*` refusal below makes that a checked property instead of a comment.
#
# ⛔ THE JOB'S `WorkingDirectory` MUST NOT BE THE REPO. A launchd job started with a TCC-denied cwd
# cannot even `getcwd()` (bash: `getcwd: cannot access parent directories: Operation not permitted`),
# which breaks python3 (`PermissionError`) and therefore the refresh's reap pass — that is how one
# candidate queue froze for six hours while reporting `queue=READ(237)(6h)`. `$O` is outside the
# protected tree, so the job's `WorkingDirectory` must be `$O` — and NOTE that main's template does
# not render that key at all (a launchd job with no WorkingDirectory inherits `/`, the #1996 class);
# PR #2020 adds it, and this file is correct either way because it never assumes a cwd.
#
# ⛔ `-A` IS NOT AN IDEMPOTENT NO-OP WHEN THERE IS NO TERMINAL — THE 7,633-LAUNCH DEFECT.
# The entry point used to be one line:
#
#     "$TMUX_BIN" new-session -A -d -s "$S" "exec /bin/bash '$O/orch-loop.sh'" || exit $?
#
# `-A` is documented as "makes new-session behave like attach-session if session-name already
# exists" (tmux(1)). ATTACHING NEEDS A CLIENT, and a launchd job has no terminal, so on every
# KeepAlive kick with the controller session already present tmux printed
#     open terminal failed: not a terminal
# and exited 1 — `|| exit $?` then turned every relaunch into an immediate failure. Measured
# 2026-10-23 15:08Z on the Mac: `launchctl print` reported the job `state=failing` with `runs=8107`,
# and `~/orchestrator/logs/launchd.err` was 616,522 bytes, mtime LIVE, repeating that one line every
# ~10 s (the supervisor had been failing this way for 7,633 launches). It reproduced exactly:
# `has-session -t =orch-controller` returned 0 (the session exists) while that same line returned 1,
# and the identical command with a CLEAN env and NO existing session returned 0 — which is why this
# looked environmental for weeks. It reproduces on Linux/tmux 3.4 too, so `launchd-controller.test.sh`
# pins it (case C is a positive control: the OLD form must still fail there).
#
# THE FIX IS TO BRANCH ON `has-session` INSTEAD OF `-A`, which enforces `-A`'s documented purpose —
# "succeed and do nothing when the session already exists … can never start a SECOND controller" —
# by a guard rather than by an attach path that cannot work. And the wait loop is OUTSIDE the guard on
# purpose: whether this process created the session or found it, this process stays as its supervisor
# until it ends, so `KeepAlive` supervises the CONTROLLER rather than a one-shot launcher that exits
# immediately after starting one.
#
# ⛔ THE PANE DOES NOT INHERIT THIS JOB'S ENVIRONMENT, SO IT IS FORWARDED EXPLICITLY.
# tmux gives a NEW session the SERVER's environment, not the client's (measured 2026-10-18, tmux 3.8,
# isolated socket: a variable present only in the creating client does not cross). When the server was
# born from an operator's terminal — the normal case on a box whose lanes are attached by hand — the
# controller pane starts with NO `REPO`, `orch-loop.sh` refuses that by design (`FATAL REPO is not
# set`, exit 78), the session dies, and KeepAlive restarts the job: a silent restart loop that reads
# exactly like an idle box. So every name the plist renders under `EnvironmentVariables` is passed on
# the command line (`new-session -e` needs tmux >= 3.2; the command line works everywhere).
# ⛔ THE LIST MUST EQUAL THE PLIST'S KEY SET, and that is TESTED, not promised: a key rendered into
# the job but not forwarded here is a limit `install.sh` validates and the loop silently uses its
# DEFAULT for (a pinned `MAX_RED_FIX_TRIES=0` becoming 2, a widened `MERGE_PRIORITY_MAX_AGE_MIN`
# silently narrowing). `launchd-controller.test.sh` derives both sides and asserts set equality.
#
# ⛔ KNOWN RESIDUAL — A SUPERVISED RESTART DOES NOT REPLACE A LIVE SESSION. Because the guard is a
# no-op when the session exists, a job restart (`launchctl kickstart -k`, `install.sh --restart`)
# re-attaches a supervisor to the session that is already running, so a CHANGED value in the plist
# (a new `MAX_LANES`) is not applied until the controller ends by itself. That is deliberately the
# minimal behaviour — the alternative (kill the session on every job start) churns a healthy
# controller — but it must be said, not discovered. To apply a config change NOW, end the session
# first, then let KeepAlive rebuild it:
#     tmux kill-session -t =orch-controller     # the controller exits, .orch.lock is released
# (PR #2020 solves the same restart-race in the other direction by replacing the session; whichever
# of the two lands, the file must be ONE — see #2020's review.)

set -u

# The restart-rate floor, in seconds (see the comment where it is applied). It is a variable so a
# test can drive it — `launchd-controller.test.sh` sets 0 to stay fast AND sets 2 to prove the floor
# is real. A non-numeric value is refused rather than silently arithmetic-erroring at exit time.
RESTART_FLOOR="${CONTROLLER_RESTART_FLOOR:-15}"
case "$RESTART_FLOOR" in ''|*[!0-9]*) printf 'launchd-controller: CONTROLLER_RESTART_FLOOR must be a non-negative integer, got %s\n' "$RESTART_FLOOR" >&2; exit 78 ;; esac

# ⛔ NO MACHINE-SPECIFIC PATHS. `O` is the same expression every other entry point uses —
# `$HOME/orchestrator`, exactly as install.sh and orch-loop.sh default it — not one developer's
# absolute home. A lifted `O=/Users/<someone>/orchestrator` works on the box it was copied from and
# nowhere else: it reads a candidates.txt that does not exist, which is indistinguishable from an
# empty backlog, so the controller reports health over a queue it never opened (#2094).
O="${O:-$HOME/orchestrator}"
S="${CONTROLLER_SESSION:-orch-controller}"

_lc_err() { printf 'launchd-controller: %s\n' "$*" >&2; }

# A session name that matches a lane prefix would be counted and reaped as a LANE by orch-loop.sh.
case "$S" in
  lane-*|fix-*|merge-*)
    _lc_err "refusing session name '$S' — it matches a lane prefix (lane-/fix-/merge-), so orch-loop.sh would count it as a worker and may reap it"
    exit 78 ;;
esac

# tmux is RESOLVED, not assumed at one Apple-Silicon path. `/opt/homebrew/bin` is Homebrew on arm64
# and `/usr/local/bin` on Intel, and either can be absent or elsewhere. A hardcoded miss exits 78 on a
# box where tmux IS installed — a refusal that names the wrong cause.
TMUX_BIN="${TMUX_BIN:-}"
if [ -z "$TMUX_BIN" ]; then
  for _c in "$(command -v tmux 2>/dev/null)" /opt/homebrew/bin/tmux /usr/local/bin/tmux; do
    if [ -n "$_c" ] && [ -x "$_c" ]; then TMUX_BIN="$_c"; break; fi
  done
fi
[ -n "$TMUX_BIN" ] && [ -x "$TMUX_BIN" ] \
  || { _lc_err "tmux not found (looked on PATH, /opt/homebrew/bin, /usr/local/bin) — set TMUX_BIN"; exit 78; }

# shq — POSIX single-quote a word for the `sh -c` string tmux runs. `'\''` escaping is POSIX for
# every byte; bash's `printf %q` emits `$'…'`, which is NOT a quoting form in POSIX sh, so on a
# dash-based box that quoting is LOST and the remainder re-parsed as commands (#1988's class).
# ⛔ IT IS A DELIBERATE TWIN of `orch-loop.sh`'s `shq()`, not a copy that should have been sourced:
# sourcing that file would EXECUTE the controller, which is the thing this file is here to launch.
_shq() { local s="${1:-}" q="'"; printf "'%s'" "${s//$q/$q\\$q$q}"; }

# THE PLIST'S KEY SET, VERBATIM. Keep it equal to `EnvironmentVariables` in launchd.plist.template —
# `launchd-controller.test.sh` asserts that equality in both directions, so a key added to the
# template cannot silently fail to reach the controller.
CONTROLLER_ENV="PATH HOME OR REPO O HARNESS_PIN HARNESS_PIN_FILE HARNESS_PIN_DIR HARNESS_REPO HARNESS_MATERIALISER SCOPE MAX_LOAD MAX_LANES MAX_REVIEW MERGE_PRIORITY_AT MERGE_PRIORITY_MAX_AGE_MIN FUNNEL_MAX_AGE_MIN MAX_FIX MAX_FIX_TRIES MAX_RED_FIX MAX_RED_FIX_TRIES MIN_SWAP_FREE MIN_MEM_FREE_MB BATCH PRODUCT_FLOOR CYC"

# ⛔ THE PIN KEYS ARE HERE BECAUSE THE JOB'S CYCLE READS THEM (agent-infra#2215 / #2231). `harness-refresh.sh`
# runs INSIDE this controller's cycle and decides from `HARNESS_PIN` / `HARNESS_PIN_FILE` / `HARNESS_REPO`
# whether this box is current and what to materialise if it is behind; `HARNESS_PIN_DIR` is the root the
# materialiser it launches puts the per-commit worktrees under (`cloud-cell-supervisor.sh`), so it is read
# one hop downstream but still inside this cycle. They are rendered into the plist by
# `launchd.plist.template` and would otherwise be dropped on the floor at this hop, which pins a Mac to
# `behind … pin NOT advanced` (exit 25) forever — the pane would inherit them only by accident from the
# tmux SERVER. Case E asserts this list and the plist's EnvironmentVariables dict agree in BOTH
# directions, so a key added to one side and not the other is a red, not a silent gap.

# ⛔ FORWARD ON PRESENCE, NEVER ON NON-EMPTINESS (review P1). An EMPTY value in the plist is a
# MEANING, not an absence: `install.sh` deliberately renders `OR` empty (#2040), which tells
# `orch-loop.sh` to DERIVE the repo slug from `$REPO`'s origin instead of using a literal. Skip an
# empty value and the pane inherits `OR` from the tmux SERVER — an operator's shell, or an earlier
# controller — and the box silently grades one repo's PR queue while dispatching into another, which
# is #2040's exact measured symptom. `${_v+x}` distinguishes "set to empty" (forward it) from
# "absent from this job" (leave it to the server), and only the first is ours to decide.
ENV_PREFIX=""
for _v in $CONTROLLER_ENV; do
  eval "_set=\${$_v+x}"
  if [ -n "${_set:-}" ]; then
    eval "_val=\${$_v-}"
    ENV_PREFIX="$ENV_PREFIX $_v=$(_shq "$_val")"
  fi
  unset _set _val
done

# ── the guard: create ONLY when there is no session, never attach ────────────────────────────────
if ! "$TMUX_BIN" has-session -t "=$S" 2>/dev/null; then
  # Fail CLOSED and by name: without this, a missing/unreadable loop is an exit-127 crash loop that
  # reads as "the controller keeps dying" instead of "the entry point cannot find its program".
  if [ ! -r "$O/orch-loop.sh" ]; then
    _lc_err "no readable controller at $O/orch-loop.sh — refusing to create a session that would die at once (check \$O; install.sh --start refuses the same way)"
    exit 78
  fi
  # /usr/bin/env is absolute: the pane's shell resolves it BEFORE the forwarded PATH is in effect.
  "$TMUX_BIN" new-session -d -s "$S" \
    "exec /usr/bin/env$ENV_PREFIX /bin/bash $(_shq "$O/orch-loop.sh")" || exit $?
  # ⛔ A CREATE THAT "SUCCEEDED" IS NOT A CONTROLLER, AND THE TWO WAYS THIS LIES ARE OPPOSITE.
  # (a) A DEAD PANE'S SESSION LINGERS: tmux tears it down a beat later, not synchronously —
  #     `new-session -d -s S "exec /bin/bash -c 'exit 7'"` returns 0 and `has-session -t =S` is TRUE
  #     right after, FALSE ~300 ms later (measured 2026-10-18, tmux 3.8, isolated socket). So ONE
  #     immediate check proves nothing.
  # (b) A COLD SERVER IS NOT VISIBLE YET: against a tmux server that is still booting, `new-session -d`
  #     returns 0 and `has-session` can MISS for a moment — so "not listed yet" must not be read as
  #     "died", or a healthy cold start is a false failure (measured: an exit 69 at the first 200 ms
  #     check while the session appeared right after).
  # Hence: wait for APPEARANCE (bounded), then require it to STILL be there after a settle window (a).
  _w=0
  while [ "$_w" -lt 100 ]; do
    "$TMUX_BIN" has-session -t "=$S" 2>/dev/null && break
    sleep 0.1
    _w=$(( _w + 1 ))
  done
  if ! "$TMUX_BIN" has-session -t "=$S" 2>/dev/null; then
    _lc_err "'$S' did not come up within 10s of new-session — see the pane output above"
    exit 69
  fi
  sleep 2
  if ! "$TMUX_BIN" has-session -t "=$S" 2>/dev/null; then
    _lc_err "'$S' died within 2s of starting — see the pane output above"
    exit 69
  fi
fi

# ── the supervisor: block while the session lives ────────────────────────────────────────────────
# This is why KeepAlive is real supervision instead of decoration: while the controller runs, this
# process runs; when the controller ends, this process exits and launchd starts a fresh one. Placing
# the loop OUTSIDE the guard is what makes that true for a session this process did NOT create.
_STARTED="$(date +%s)"
while "$TMUX_BIN" has-session -t "=$S" 2>/dev/null; do sleep 5; done
_LIVED=$(( $(date +%s) - _STARTED ))

# ⛔ FLOOR THE RESTART RATE. `orch-loop.sh` exits 0 at once when another controller holds
# `.orch.lock`, and a session whose loop refuses to start dies in milliseconds. launchd already
# throttles KeepAlive to `ThrottleInterval` (10 s, rendered in the plist); this keeps the wrapper's
# own restart interval from ever being shorter than that, so a genuinely broken controller produces
# ONE line per window instead of a wall of them. It is a floor, not a fixed delay: a controller that
# ran for an hour exits immediately.
if [ "$_LIVED" -lt "$RESTART_FLOOR" ]; then sleep $(( RESTART_FLOOR - _LIVED )); fi

# ⛔ SAY HOW LONG IT RAN. Exiting 0 after a controller that died in two seconds is indistinguishable
# in launchd.err from an idle box; the lifetime is the one datum that separates them. It stays exit 0
# because a controller that exits AT ONCE is a legitimate state (`orch-loop.sh` exits 0 when another
# controller holds the lock), so this is a diagnostic, not a verdict.
_lc_err "the '$S' controller session ended after ${_LIVED}s (exit 0)"
exit 0
