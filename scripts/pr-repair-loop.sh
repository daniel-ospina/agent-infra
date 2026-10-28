#!/usr/bin/env bash
# pr-repair-loop.sh — the cell's REPAIR half, as a thing a service manager can own (agent-infra#2716,
# #2700 C5, #2709).
#
# WHY THIS EXISTS. Two capabilities the fleet needs are separate and were being installed as one:
# `eldato-orchestrator` DISPATCHES lanes (`orch-loop.sh`), and a repair loop DRIVES THE OPEN PR QUEUE
# toward `merged` (`pr-doctor.py` reaps, classifies and spawns repair workers). A cell can have the
# first and be unable to do the second — measured on `pi-cell-3` at 2026-10-24T17:15Z, before this
# file existed there:
#
#     $ pgrep -f '[p]r-doctor.py' | wc -l          -> 0
#     $ tmux ls                                    -> no server running on /tmp/tmux-1000/default
#     $ systemctl list-unit-files | grep repair    -> (nothing)
#     $ tail -1 ~/.pi/agent/state/pr-doctor.log    -> 2026-10-22T21:54:33Z   (2 days stale)
#
# Every surface read healthy — `eldato-orchestrator` was `active` — while the box had no actor that
# repairs, reaps or lands anything. That is the ALIVE / REFUSING / IDLE confusion of `#2700` §1.2,
# and the pair-of-units split is the fix: `eldato-orchestrator` dispatches, `eldato-pr-repair`
# repairs, and the installer for one must never install the other (#2716's own scope line).
#
# WHAT A PASS DOES, IN ORDER (each step's verdict is journalled, because a pass that prints nothing
# is indistinguishable from a pass that could not run):
#   1. MEASURE the machine — free MB on the checkout's filesystem, `nproc`, `load1`. These are the
#      inputs to the cap; none of them is a private literal (#2409's "bounded concurrency, from the
#      machine" rule, and the owner's 8–10x `load1/nproc` ceiling in `docs/ops/fleet-capacity.md`).
#   2. REFUSE or DEFER — below the disk floor, above the load ceiling, or with a derived cap of 0,
#      print the number that decided it and exit 6 (`deferred`). ⛔ This is what keeps a repair loop
#      off a box that cannot afford it: `pi-cell-4` measured ~3.4 GB free on 2026-10-24 (#2721), and
#      a repair worker materialises a worktree WITH its own dependency tree. Deferring is a verdict,
#      not a silence — the same vocabulary `eldato-disk-reaper.service` uses (6 = a delegate deferred,
#      green; 3/4 = fail-closed, red).
#   3. REAP worktrees through the SHIPPED reaper (`pi-reap-worktrees.sh --apply`), never a second
#      worktree-policy implementation. Its own rows (`preserve <path> reason=…`, `REMOVED`) ARE the
#      evidence that a decision was taken, which is the property #2700's contract asks of every
#      capability.
#   4. DISPATCH through the fleet's ONE classifier/dispatcher pair — `pr-doctor.py`, which calls
#      `objective.classify_one()` — with the cap derived above, and with the target repo supplied
#      through the env seams (`PR_DOCTOR_REPO`, `PR_DOCTOR_REPO_DIR`, `OBJECTIVE_REPO`). A cell whose
#      checkout is `/tmp/cell-t3` cannot use `pr-doctor`'s macOS default path, and pointing it at one
#      is #1974's exact defect.
#   5. RECORD one status row (`$O/state/pr-repair.status.json`) that a reader can act on: the
#      measurement, the cap, the decision and the rc of every step. `systemctl is-active` is a
#      HINT; this row is the answer to "did it do anything, and if not, why not".
#
# ⛔ THE UNIT MUST SET `KillMode=process` (#2716). `pr-doctor.py` backgrounds every worker through
# `nonblocking-dispatch.sh` and returns immediately; under systemd's default `KillMode=control-group`
# the end of a pass SIGTERMs every process left in the cgroup — the workers it spawned moments
# earlier. Measured on `pi-cell-4` 2026-10-24T15:19Z: two workers "launched, running", both with a
# 0-byte `.log` and no `.rc`, 290 MB of worktrees left behind, while `is-active=active` and
# `dispatched=2`. The template carries the property and its installer FAILS CLOSED without it.
#
# Usage:
#   pr-repair-loop.sh                 # one pass (the default)
#   pr-repair-loop.sh --loop          # the service's main process: pass, sleep, repeat
#   pr-repair-loop.sh --trigger       # the service's EVENT-DRIVEN main process: run a pass when the
#                                     # PR surface moves (pr-doctor-trigger.py), with --loop's
#                                     # interval demoted to a backstop. See TRIGGER below
#   pr-repair-loop.sh --dry-run       # measure, derive the cap, dispatch nothing
#   pr-repair-loop.sh --print-capacity  # the derived numbers only (pure; what the test asserts)
#   pr-repair-loop.sh --status        # the last recorded pass, verbatim
#
# TRIGGER — THE EVENT-DRIVEN FRONT END (#2700 C5). `--loop` is a TIMER: a pass, then `sleep
# $REPAIR_INTERVAL_S`. A scheduled pass only sees the fleet at the instant it fires, so a PR that
# turns red one second after one waited out the whole interval with nobody on it — measured on the
# Mac as `StartInterval 1800`, i.e. a mean 900 s of dead time for a repair whose own cost is one
# pass. `--trigger` replaces the timer with a front end that reads the PR surface (ONE `gh pr list`
# per poll) and runs a pass only when the fingerprint changes, keeping the interval as a BACKSTOP
# for the work only a clock can see (a check that never reports, a worker that dies silently).
# ⛔ THE TRIGGER IS A FRONT END AND NOTHING ELSE: its child is THIS script's one-pass mode, so every
# gate below (disk floor, load ceiling, derived cap, reap, credential source, status row) still
# decides what happens. A front end that ran `pr-doctor.py` directly would dispatch credential-less
# workers past the #2721 wedge guard while reading healthy — the #2700 §1.2 shape, one level up.
#
# Environment (all optional; the service renders them):
#   CELL_HOME              default /tmp/cell-home
#   ENV_FILE               the credential file this pass sources with `set -a` before dispatching,
#                          default $CELL_HOME/keys.env. ⛔ A UNIT DOES NOT INHERIT THE TMUX SERVER'S
#                          ENVIRONMENT: without this every worker spawns credential-less and dies
#                          (#1852), while the pass reads `dispatched` (#2716's false PASS, one up).
#                          A supplied-but-unreadable file REFUSES rather than running blind.
#   O                      the orchestrator state dir, default $CELL_HOME/orchestrator
#   PR_DOCTOR_REPO / GH_REPO        the repo slug to repair, default daniel-ospina/tortoise
#   PR_DOCTOR_REPO_DIR     the checkout, default /tmp/cell-t3
#   REPAIR_INTERVAL_S      seconds between passes in --loop, default 900
#   REPAIR_TRIGGER_POLL_S      --trigger: the lead, in seconds (default 60)
#   REPAIR_TRIGGER_DEBOUNCE_S  --trigger: the coalescing window, in seconds (default 90)
#   REPAIR_TRIGGER_BACKSTOP_S  --trigger: the demoted timer, in seconds (default 1800)
#   REPAIR_TRIGGER_RETRY_MIN_S --trigger: floor between retries of a FAILED pass (default 300)
#   REPAIR_DISK_FLOOR_MB   headroom below which a pass DEFERS, default 4096
#   REPAIR_DISK_PER_WORKER_MB  what one repair worker costs on disk, default 1024
#   REPAIR_LOAD_CEILING_MULT   the owner's ceiling on load1/nproc, default 8
#   REPAIR_MAX_WORKERS     absolute cap regardless of the machine, default 6
#
# Exit codes (the `pr-doctor`/`disk-reaper` vocabulary, kept identical on purpose):
#   0  a pass completed — it dispatched, or there was genuinely nothing to do
#   2  REFUSING — a read a pass needs could not be taken (a miss is never "nothing to do")
#   3  UNDELIVERED — legible work, NONE of it out: the work was placed and no worker took it, OR a
#      durable refusal (a dirty worktree, an order the transport will not take) stopped it before
#      delivery (agent-infra#2710). pr-doctor's own 3, kept verbatim: a monitor keyed on this pass
#      must not read green over work nobody accepted
#   4  PASS-FAILED — the dispatcher CRASHED (or exited with a code that is not a verdict above).
#      ⛔ NEVER RECORDED AS `refusing` (ai#2922): a crash and a refusal are DIFFERENT facts with
#      different remedies, and this loop used to write both into the same `decision` and return 2,
#      so a dispatcher that died (an unreadable cwd under launchd, `EXIT_CRASH=4`) read exactly like
#      "I could not read the world". 2 is a VERDICT — see `docs/ops/pr-repair-service.md`, "the
#      pass's exit codes are the trigger's vocabulary" — so a laundered crash consumed the backstop
#      window instead of retrying. 4 is the same code `pr-doctor` uses for an uncaught exception.
#   6  DEFERRED — the machine said not now; the status row carries which measurement said so
set -uo pipefail

CELL_HOME="${CELL_HOME:-/tmp/cell-home}"
O="${O:-$CELL_HOME/orchestrator}"
SCRIPTS="${PR_REPAIR_SCRIPTS:-$CELL_HOME/.pi/agent/scripts}"
REPO_SLUG="${PR_DOCTOR_REPO:-${GH_REPO:-daniel-ospina/tortoise}}"
REPO_PATH="${PR_DOCTOR_REPO_DIR:-/tmp/cell-t3}"
INTERVAL_S="${REPAIR_INTERVAL_S:-900}"
DISK_FLOOR_MB="${REPAIR_DISK_FLOOR_MB:-4096}"
PER_WORKER_MB="${REPAIR_DISK_PER_WORKER_MB:-1024}"
LOAD_MULT="${REPAIR_LOAD_CEILING_MULT:-8}"
MAX_WORKERS="${REPAIR_MAX_WORKERS:-6}"
# ⛔ SUPPLIED vs DEFAULTED IS THE DIFFERENCE BETWEEN A CONFIGURATION FAULT AND A MANUAL RUN. A unit
# that names a credential file which does not exist must REFUSE (its workers would spawn
# credential-less — #1852); an operator running the loop by hand inherits their own shell and needs no
# file. Only the supplied case can refuse, so the distinction is captured before the default applies.
ENV_FILE_SUPPLIED="${ENV_FILE:+1}"
ENV_FILE="${ENV_FILE:-$CELL_HOME/keys.env}"
# The `--trigger` front end's knobs. `POLL` is the lead (a change is noticed within one poll),
# `DEBOUNCE` is the coalescing window (a push fires several `updatedAt` moves; they must produce ONE
# pass), `BACKSTOP` is the demoted timer, and `RETRY_MIN` bounds the retries of a FAILED pass so a
# box that cannot deliver does not re-read the whole PR surface every poll.
TRIGGER_POLL_S="${REPAIR_TRIGGER_POLL_S:-60}"
TRIGGER_DEBOUNCE_S="${REPAIR_TRIGGER_DEBOUNCE_S:-90}"
TRIGGER_BACKSTOP_S="${REPAIR_TRIGGER_BACKSTOP_S:-1800}"
TRIGGER_RETRY_MIN_S="${REPAIR_TRIGGER_RETRY_MIN_S:-300}"
STATE_DIR="$O/state"
STATUS="$STATE_DIR/pr-repair.status.json"

EXIT_OK=0
EXIT_REFUSING=2
EXIT_UNDELIVERED=3   # legible work, NONE of it out -- no worker took the order that was placed, or a
                     # durable refusal stopped it before delivery (#2710). pr-doctor's own 3, kept verbatim
EXIT_CRASH=4         # the dispatcher crashed / returned a non-verdict -- pr-doctor's own 4
EXIT_DEFERRED=6

log_line() { printf '[%s] pr-repair: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
err() { log_line "⛔ $*" >&2; }

# ── measurement ──────────────────────────────────────────────────────────────────────────────────
# ⛔ `df` ON THE CHECKOUT, NOT ON `/`. A cell's checkout can be on a different filesystem (a bind
# mount, a second volume), and the question this guard answers is "can THIS repo grow a worktree",
# not "does the root filesystem have room". ⛔ And it is `df -Pm` (POSIX, megabytes): `df -h` prints
# a human string that a comparison would have to parse back into a number.
measure_free_mb() {
    local out
    out="$(df -Pm "$1" 2>/dev/null | awk 'NR==2 {print $4}')" || return 1
    case "$out" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s\n' "$out"
}

measure_used_pct() {
    local out
    out="$(df -Pm "$1" 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}')" || return 1
    case "$out" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s\n' "$out"
}

measure_load1() {
    local out
    out="$(awk '{print $1}' /proc/loadavg 2>/dev/null)" || return 1
    case "$out" in ''|*[!0-9.]*) return 1 ;; esac
    printf '%s\n' "$out"
}

# ── the cap: DERIVED, never a literal ────────────────────────────────────────────────────────────
# Three terms, and the smallest one wins. Each is a fact about the box, and each is printed by
# `--print-capacity` so a reader can see WHY a cell runs 2 workers and not 8:
#   cpu   — half the cores, floored at 1 and ceilinged by REPAIR_MAX_WORKERS. A repair worker is a
#           `pi` agent PLUS the test suite it runs, so one worker per two cores leaves the
#           controller, the lanes and the box's own CI some headroom. The owner's 8–10x ceiling is
#           the OUTER bound (see `load_ceiling`), not the worker count: a box at 8x is busy by
#           ruling, and `spawn-gate.sh` refuses each individual spawn against it anyway (#1873).
#   disk  — what is left after the floor, at PER_WORKER_MB each. On a cell with 24 GB free this is
#           not binding; on `pi-cell-4` (3.4 GB free, #2721) it is the term that says "not yet".
#   max   — REPAIR_MAX_WORKERS, the operator's own ceiling.
# `load1` is NOT a term here: it gates the whole PASS (`load_ceiling`), because a box already past
# 8x should not start a new repair at all rather than start fewer of them.
derive_cap() { # <nproc> <free_mb>
    local nproc_="$1" free_mb="$2"
    local cpu_cap disk_cap cap
    cpu_cap=$(( nproc_ / 2 ))
    [ "$cpu_cap" -lt 1 ] && cpu_cap=1
    [ "$cpu_cap" -gt "$MAX_WORKERS" ] && cpu_cap="$MAX_WORKERS"
    disk_cap=$(( (free_mb - DISK_FLOOR_MB) / PER_WORKER_MB ))
    [ "$disk_cap" -lt 0 ] && disk_cap=0
    cap="$cpu_cap"
    [ "$disk_cap" -lt "$cap" ] && cap="$disk_cap"
    printf '%s\n' "$cap"
}

load_ceiling() { # <nproc> -> the load1 value at or above which a pass defers
    awk -v n="$1" -v m="$LOAD_MULT" 'BEGIN { printf "%d\n", n * m }'
}

# ── one pass ─────────────────────────────────────────────────────────────────────────────────────
write_status() { # <decision> <cap> <free_mb> <load1> <rc_reap> <rc_dispatch> <reason>
    mkdir -p "$STATE_DIR" 2>/dev/null
    PR_REPAIR_STATUS="$STATUS" python3 - \
        "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$REPO_SLUG" "$REPO_PATH" >/dev/null 2>&1 <<'PY'
import json, os, sys, time
decision, cap, free_mb, load1, rc_reap, rc_dispatch, reason, slug, path = sys.argv[1:10]
row = {
    "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "epoch": int(time.time()),
    # dispatched | idle(dry-run) | deferred | refusing | placed-undelivered | pass-failed
    # | skipped(own file)
    "decision": decision,
    "reason": reason,
    "cap": int(cap) if cap.isdigit() else cap,
    "free_mb": int(free_mb) if free_mb.isdigit() else free_mb,
    "load1": float(load1) if load1.replace(".", "", 1).isdigit() else load1,
    "rc_reap": rc_reap,
    "rc_dispatch": rc_dispatch,
    "repo": slug,
    "repo_dir": path,
}
# ⛔ THE TEMP PATH IS WRITER-UNIQUE (round-3 review). The holder of the pass lock and a SKIPPING pass
# are two processes by construction, and a shared `$STATUS.tmp` let the skipper truncate the holder's
# in-flight temp file and then `os.replace` it — a real pass's verdict replaced by a "nothing happened".
tmp = "%s.tmp.%d" % (os.environ["PR_REPAIR_STATUS"], os.getpid())
with open(tmp, "w") as fh:
    json.dump(row, fh, indent=2, sort_keys=True)
    fh.write("\n")
os.replace(tmp, os.environ["PR_REPAIR_STATUS"])
PY
}

# ⛔ THE SKIP ARTIFACT IS SEPARATE ON PURPOSE (round-3 review): it is written by a process that does NOT
# hold the lock, so it must never be able to displace the holder's row. `--status' prints both.
SKIP_STATUS="$STATE_DIR/pr-repair.skip.json"
write_skip_row() { # <reason>
    mkdir -p "$STATE_DIR" 2>/dev/null
    PR_REPAIR_SKIP="$SKIP_STATUS" python3 - "$1" >/dev/null 2>&1 <<'PY'
import json, os, sys, time
row = {
    "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "epoch": int(time.time()),
    "decision": "skipped",
    "reason": sys.argv[1],
}
tmp = "%s.tmp.%d" % (os.environ["PR_REPAIR_SKIP"], os.getpid())
with open(tmp, "w") as fh:
    json.dump(row, fh, indent=2, sort_keys=True)
    fh.write("\n")
os.replace(tmp, os.environ["PR_REPAIR_SKIP"])
PY
}

one_pass() { # <dry-run:0|1>
    local dry="$1"
    local free_mb used_pct load1 nproc_ ceiling cap rc_reap=- rc_dispatch=-

    # ⛔ ONE PASS AT A TIME, IN BOTH MODES (#2700: two repair loops on one cell against one repo
    # double-claim work). The lock lives here rather than in the `once` arm because the UNIT runs
    # `--loop`: a guard the service never takes is a guard that protects nothing, and a manual
    # `--once` beside a running unit would run a second dispatcher on one checkout.
    # ⛔ A MISSING `flock` IS A REFUSAL, NOT A SKIP (round-2 review): without the binary every pass
    # would take the "someone else holds it" branch for ever, `is-active` would read `active`, and the
    # status row would keep showing the last real pass — the exact false PASS this file removes. A
    # real CONTENTION is the only case that is a benign skip, and it is RECORDED as one.
    if ! command -v flock >/dev/null 2>&1; then
        err "REFUSING: flock is not on PATH — the pass lock cannot be taken, so this box cannot prove it is the only repair pass."
        write_status refusing 0 - - - - "flock-missing"
        return "$EXIT_REFUSING"
    fi
    mkdir -p "$STATE_DIR" 2>/dev/null
    exec 9>"$STATE_DIR/pr-repair.lock" || {
        err "REFUSING: cannot open the pass lock under $STATE_DIR — an unlocked pass could double-claim work."
        write_status refusing 0 - - - - "lock-unopenable:$STATE_DIR"
        return "$EXIT_REFUSING"
    }
    if ! flock -n 9; then
        # ⛔ A SKIP IS RECORDED IN ITS OWN FILE (round-3 review). Writing it into the shared status row
        # would let a skipping pass replace the LOCK HOLDER's verdict — and the holder is the only actor
        # that did any work. `--status` prints both, so nothing is hidden and nothing is overwritten.
        log_line "SKIPPED — another repair pass holds $STATE_DIR/pr-repair.lock; not starting a second one."
        write_skip_row "lock-held:$STATE_DIR/pr-repair.lock"
        return "$EXIT_OK"
    fi

    # ⛔ A NAMED CREDENTIAL FILE THAT CANNOT BE READ IS A CONFIGURATION FAULT (#1852). Without it every
    # worker spawns without its provider credential and dies, and the pass would read "dispatched".
    if [ "${ENV_FILE_SUPPLIED:-0}" = 1 ] && [ "${ENV_SOURCED:-0}" != 1 ]; then
        err "REFUSING: ENV_FILE=$ENV_FILE was supplied but could not be read — every repair worker would spawn without its provider credential and die (#1852), while this pass reads healthy."
        write_status refusing 0 - - - - "env-file-unreadable:$ENV_FILE"
        return "$EXIT_REFUSING"
    fi

    if [ ! -d "$REPO_PATH" ]; then
        err "REFUSING: the checkout $REPO_PATH does not exist — a repair pass with no checkout would read nothing and report it as an empty queue (#1974)."
        write_status refusing 0 - - - - "checkout-missing:$REPO_PATH"
        return "$EXIT_REFUSING"
    fi
    free_mb="$(measure_free_mb "$REPO_PATH")" || {
        err "REFUSING: could not measure free space on $REPO_PATH (df unreadable) — an unmeasured disk is not a healthy disk."
        write_status refusing 0 UNREADABLE - - - "df-unreadable:$REPO_PATH"
        return "$EXIT_REFUSING"
    }
    used_pct="$(measure_used_pct "$REPO_PATH")" || used_pct=UNREADABLE
    load1="$(measure_load1)" || {
        err "REFUSING: could not read /proc/loadavg — an unmeasured load is not an idle box."
        write_status refusing 0 "$free_mb" UNREADABLE - - "loadavg-unreadable"
        return "$EXIT_REFUSING"
    }
    nproc_="$(nproc 2>/dev/null)" || nproc_=1
    ceiling="$(load_ceiling "$nproc_")"
    cap="$(derive_cap "$nproc_" "$free_mb")"

    # The headroom line is a DECISION RECORD, not decoration: it is what an operator reads to know
    # why the box did or did not repair anything this pass, and it is the number #2721 turns on.
    local wt_count
    wt_count="$(find "$REPO_PATH/.worktrees" -maxdepth 1 -name 'prd-*' 2>/dev/null | wc -l | tr -d ' ')"
    log_line "disk: ${free_mb}MB free (${used_pct}% used) worktrees: ${wt_count} prd-*  load1: ${load1}/${ceiling} (nproc=${nproc_})  cap: ${cap}"

    if [ "$free_mb" -lt "$DISK_FLOOR_MB" ]; then
        log_line "DEFERRED — ${free_mb}MB free is below the ${DISK_FLOOR_MB}MB floor; a repair worker materialises a worktree WITH its dependency tree (#2721), so a pass here would wedge the box instead of repairing it."
        write_status deferred "$cap" "$free_mb" "$load1" - - "disk-floor:${free_mb}<${DISK_FLOOR_MB}"
        return "$EXIT_DEFERRED"
    fi
    if awk -v l="$load1" -v c="$ceiling" 'BEGIN { exit !(l + 0 >= c + 0) }'; then
        log_line "DEFERRED — load1 ${load1} is at or above the ${ceiling} ceiling (${LOAD_MULT}x nproc=${nproc_}); the box is busy by the owner's own ruling and a new repair would compete with it."
        write_status deferred "$cap" "$free_mb" "$load1" - - "load-ceiling:${load1}>=${ceiling}"
        return "$EXIT_DEFERRED"
    fi
    if [ "$cap" -lt 1 ]; then
        log_line "DEFERRED — the derived cap is 0 (${free_mb}MB free, ${DISK_FLOOR_MB}MB floor, ${PER_WORKER_MB}MB per worker): there is no room for even one repair worker."
        write_status deferred 0 "$free_mb" "$load1" - - "cap-zero"
        return "$EXIT_DEFERRED"
    fi

    # ── REAP (the shipped reaper; its rows are the evidence) ────────────────────────────────────
    if [ -x "$SCRIPTS/pi-reap-worktrees.sh" ]; then
        if [ "$dry" = 1 ]; then
            log_line "reap: DRY-RUN (would run $SCRIPTS/pi-reap-worktrees.sh --apply --repo $REPO_PATH)"
        else
            log_line "reap: pass over $REPO_PATH/.worktrees via the shipped reaper"
            REAP_WT_GH_TIMEOUT="${REAP_WT_GH_TIMEOUT:-120}" \
                timeout "${REPAIR_REAP_TIMEOUT_S:-600}" \
                "$SCRIPTS/pi-reap-worktrees.sh" --apply --repo "$REPO_PATH"
            rc_reap=$?
            case "$rc_reap" in
                0) log_line "reap: pass completed (rc=0)" ;;
                3) err "reap: FAILED CLOSED (rc=3) — a read the reaper needs could not be taken; it removed nothing it could not prove. Repair continues." ;;
                4) err "reap: completed with at least one FAILED removal (rc=4). Repair continues." ;;
                *) err "reap: unexpected rc=$rc_reap from the reaper. Repair continues." ;;
            esac
        fi
    else
        err "reap: the shipped reaper is missing at $SCRIPTS/pi-reap-worktrees.sh — reaping is SKIPPED this pass (a missing tool is not 'nothing to reap')."
        rc_reap=missing
    fi

    # ── DISPATCH (the shipped classifier/dispatcher; one seam, no second predicate) ──────────────
    local doctor="$SCRIPTS/pr-doctor.py"
    if [ ! -f "$doctor" ]; then
        err "REFUSING: $doctor is missing — the repair dispatcher is not installed on this box."
        write_status refusing "$cap" "$free_mb" "$load1" "${rc_reap:--}" missing "pr-doctor-missing"
        return "$EXIT_REFUSING"
    fi
    if [ "$dry" = 1 ]; then
        log_line "dispatch: DRY-RUN (would run pr-doctor.py --max $cap for $REPO_SLUG at $REPO_PATH)"
        write_status idle "$cap" "$free_mb" "$load1" "${rc_reap:--}" dry-run "dry-run"
        return "$EXIT_OK"
    fi
    log_line "dispatch: pr-doctor --max ${cap} for ${REPO_SLUG} at ${REPO_PATH}"
    PR_DOCTOR_REPO="$REPO_SLUG" \
    PR_DOCTOR_REPO_DIR="$REPO_PATH" \
    OBJECTIVE_REPO="$REPO_SLUG" \
    MAX_FIX="$cap" \
    MAX_REVIEW="$cap" \
    O="$O" \
        timeout "${REPAIR_DOCTOR_TIMEOUT_S:-1800}" python3 "$doctor" --max "$cap"
    rc_dispatch=$?
    case "$rc_dispatch" in
        0) log_line "dispatch: pass completed (rc=0)" ;;
        2) err "dispatch: REFUSING (rc=2) — pr-doctor could not read the world or could not deliver; this is NOT an empty queue." ;;
        3) err "dispatch: NOT DELIVERED (rc=3) — legible work, none of it out: no worker took an order that was placed, or a refusal stopped one before delivery. NOT an empty queue." ;;
        # ⛔ A NON-VERDICT IS A FAILURE, AND IT IS NAMED AS ONE (ai#2922). `timeout` alone gives 124,
        # a signal gives 128+n, and `pr-doctor` gives 4 for an uncaught exception -- the code an
        # unreadable cwd produced under launchd. Calling any of them "a refusal" told an operator to
        # look for a broken read while the dispatcher was dead. `pr-doctor` returns no `6` today, so
        # this catch-all cannot swallow the DEFERRED code a sibling adds; when one lands, its `6)`
        # arm matches before this one.
        *) err "dispatch: PASS-FAILED (rc=$rc_dispatch) — the dispatcher did not return a verdict; this is a CRASH to diagnose, not a refusal and not an empty queue." ;;
    esac
    # ⛔ THE RECORD FOLLOWS THE DISPATCHER'S OWN VERDICT, not the fact that it returned. A pass whose
    # dispatcher REFUSED (rc=2, "could not read the world") recorded as `dispatched` is the exact
    # false PASS #2700 §1.2 describes: an operator reading the row would see a completed pass over a
    # queue nobody could read. The exit code carries the same verdict the row does.
    case "$rc_dispatch" in
        0) write_status dispatched "$cap" "$free_mb" "$load1" "${rc_reap:--}" "$rc_dispatch" "pass-complete"; return "$EXIT_OK" ;;
        # ⚠️ THE TOKEN `no-worker-took-it` IS KEPT AND ITS CAUSE IS NOT (agent-infra#2710): rc=3 now
        # covers a durable refusal BEFORE delivery as well, so the token under-describes its own row.
        # It is not renamed here because it is a shipped monitor vocabulary (`pr-repair-loop.test.sh`
        # pins it) and renaming it mid-change would break a reader this lane cannot verify. The
        # KIND (`placed-undelivered`) is accurate for both, and the human line above names both.
        3) write_status placed-undelivered "$cap" "$free_mb" "$load1" "${rc_reap:--}" "$rc_dispatch" "no-worker-took-it"; return "$EXIT_UNDELIVERED" ;;
        # ⛔ 2 IS WRITTEN EXPLICITLY, NOT VIA `*)` (ai#2922). The record arm never had a `2)` case: it
        # reached `refusing` through the catch-all, so the moment a catch-all had to mean "a crash"
        # (below), a genuine REFUSAL would have been recorded as `pass-failed` and returned 4 —
        # collapsing the two facts from the other side. Named here, the refusal keeps its own row and
        # its own verdict code, and the catch-all is free to mean only what it says.
        2) write_status refusing "$cap" "$free_mb" "$load1" "${rc_reap:--}" "$rc_dispatch" "dispatcher-refused"; return "$EXIT_REFUSING" ;;
        # ⛔ THE ROW AND THE EXIT CODE BOTH SAY `pass-failed` (ai#2922). This arm used to write
        # `refusing` / `dispatcher-refused` and return 2 -- the VERDICT code -- so a crashed
        # dispatcher produced a row and an exit byte-identical to a genuine "could not read the
        # world" (measured: rc=4 and rc=2 both gave `decision='refusing' reason='dispatcher-refused'`,
        # LOOP-EXIT=2). 2 is a verdict a caller acts on; 4 is not, so a later tick retries instead
        # of waiting out the backstop window on a crash.
        *) write_status pass-failed "$cap" "$free_mb" "$load1" "${rc_reap:--}" "$rc_dispatch" "dispatcher-crashed"; return "$EXIT_CRASH" ;;
    esac
}

# ── verbs ────────────────────────────────────────────────────────────────────────────────────────
print_capacity() {
    # A monitor parses this line, so a bad knob must say so instead of printing an empty `cap=`.
    validate_knobs >/dev/null 2>&1 || { printf 'cap=INVALID (see stderr)\n'; validate_knobs >&2; return "$EXIT_REFUSING"; }
    local nproc_="${PR_REPAIR_FAKE_NPROC:-$(nproc 2>/dev/null || echo 1)}"
    local free_mb="${PR_REPAIR_FAKE_FREE_MB:-$(measure_free_mb "$REPO_PATH" 2>/dev/null || echo 0)}"
    local load1="${PR_REPAIR_FAKE_LOAD1:-$(measure_load1 2>/dev/null || echo 0)}"
    printf 'nproc=%s free_mb=%s floor_mb=%s per_worker_mb=%s load1=%s load_ceiling=%s cap=%s\n' \
        "$nproc_" "$free_mb" "$DISK_FLOOR_MB" "$PER_WORKER_MB" "$load1" \
        "$(load_ceiling "$nproc_")" "$(derive_cap "$nproc_" "$free_mb")"
}

show_status() {
    if [ ! -f "$STATUS" ]; then
        log_line "no pass has been recorded yet ($STATUS absent) — NOT INSTALLED or never run, which is a different verdict from idle."
        # ⛔ A SKIP RECORD IS THE ONLY EXPLANATION OF THIS STATE (round-4 review): returning here hid
        # `pr-repair.skip.json` exactly when it was the one artifact that said why nothing was recorded.
        if [ -f "$SKIP_STATUS" ]; then
            log_line "a skip WAS recorded (another pass holds the lock; no pass has completed since):"
            sed 's/^/  /' "$SKIP_STATUS"
        fi
        return "$EXIT_REFUSING"
    fi
    cat "$STATUS"
    if [ -f "$SKIP_STATUS" ]; then
        log_line "last skip (another pass held the lock; no work attempted):"
        sed 's/^/  /' "$SKIP_STATUS"
    fi
}

MODE=once
DRY=0

# ── the credential env (#1852, found in review of this change) ──────────────────────────────────
# ⛔ A UNIT DOES NOT INHERIT THE TMUX SERVER'S ENVIRONMENT, and the fleet's credentials live in
# `keys.env` — sourced with `set -a` into the tmux server, which is why every lane and every
# supervisor-spawned worker has `DEEPSEEK_API_KEY`/`GH_TOKEN`/`PATH`. This loop is started by systemd,
# so it has none of that: without this block every worker would spawn credential-less and die with
# `No API key found`, while the pass reads `dispatched` and the unit reads `active` — the #2716 false
# PASS one level up, and the measured #1852 shape ("all three cells": every review and fixer died).
# ⛔ THE LOCALS ABOVE WIN, AND THAT NEEDS MORE THAN "ASSIGNED BEFORE THE SOURCE". `. file` runs in THIS
# shell, so a `keys.env` line `export O=/somewhere` ASSIGNS `O` — the variable this file dispatches
# with. The state dirs computed above stay put, so the pass would record its verdict in one directory
# while `pr-doctor` resolved `$O/nonblocking-dispatch.sh` in another: a dispatch through a foreign
# state dir, or a permanent "dispatcher missing" (round-2 review; `docs/ops/controller-service.md:157`
# already records `keys.env O=` as the live shape that moves a controller's state dir). So the unit's
# contract is captured under names the file cannot collide with, and RE-ASSERTED after the source.
# `keys.env` remains authoritative for CREDENTIALS (`DEEPSEEK_API_KEY`, `GH_TOKEN`, `PATH`), which is
# what #1852 needs it for; it may not move WHAT this box repairs or WHERE it records that.
_C_O="$O"
_C_CELL_HOME="$CELL_HOME"
_C_REPO_SLUG="$REPO_SLUG"
_C_REPO_PATH="$REPO_PATH"
_C_ENV_FILE="$ENV_FILE"
# ⛔ READABILITY IS THE TEST, NOT THE SOURCE COMMAND'S EXIT STATUS (round-2 review). A readable
# `keys.env` whose LAST line is conditional (`[ -f x ] && . x`) returns non-zero from `.` — measuring
# that as "unreadable" made every pass refuse forever with a false diagnosis, and `2>/dev/null` hid
# the reason. Readability decides the refusal; a non-zero source status is surfaced as a warning.
ENV_SOURCED=0
if [ -r "$ENV_FILE" ]; then
    ENV_SOURCED=1
    set -a
    # shellcheck disable=SC1090  # a machine-local credential file, by design
    if ! . "$ENV_FILE" 2>/dev/null; then
        err "env: $ENV_FILE is readable but its last command returned non-zero (sourced anyway; credentials above that line are in effect)."
    fi
    set +a
fi
# ⛔ THE TUNABLES ARE RE-DERIVED AFTER THE SOURCE (round-5 review). The five `REPAIR_*` knobs were
# captured BEFORE the source, so a `keys.env` export of e.g. `REPAIR_DISK_PER_WORKER_MB` was silently
# ignored while this file claimed the file could set them — a documented-looking config path that does
# nothing. The rule is now the one the comment states: `keys.env` is authoritative for TUNABLES and
# credentials, the unit's `Environment=` is authoritative for WHO/WHERE (re-asserted just below).
INTERVAL_S="${REPAIR_INTERVAL_S:-$INTERVAL_S}"
DISK_FLOOR_MB="${REPAIR_DISK_FLOOR_MB:-$DISK_FLOOR_MB}"
PER_WORKER_MB="${REPAIR_DISK_PER_WORKER_MB:-$PER_WORKER_MB}"
LOAD_MULT="${REPAIR_LOAD_CEILING_MULT:-$LOAD_MULT}"
MAX_WORKERS="${REPAIR_MAX_WORKERS:-$MAX_WORKERS}"
O="$_C_O"
CELL_HOME="$_C_CELL_HOME"
REPO_SLUG="$_C_REPO_SLUG"
REPO_PATH="$_C_REPO_PATH"
ENV_FILE="$_C_ENV_FILE"

# ── the knobs are INPUTS, so they are validated once (#2716, round-2 review) ─────────────────────
# ⛔ A ZERO PER-WORKER COST DIVIDES BY ZERO: `derive_cap` leaves `cap` empty, `[ "$cap" -lt 1 ]`
# fails with "integer expression expected", and the pass proceeds to `pr-doctor --max ''` with an empty
# `MAX_FIX` — a repair loop whose cap is a shell error message. Validated AFTER the source, because
# `keys.env` is allowed to set these, and a bad value must be a NAMED refusal rather than an accident.
validate_knobs() {
    local name val
    for name in INTERVAL_S DISK_FLOOR_MB PER_WORKER_MB LOAD_MULT MAX_WORKERS; do
        val="${!name}"
        case "$val" in
            ''|*[!0-9]*)
                err "REFUSING: $name='$val' is not a non-negative integer — this box's capacity arithmetic would be undefined."
                return 1 ;;
        esac
    done
    [ "$PER_WORKER_MB" -ge 1 ] || {
        err "REFUSING: REPAIR_DISK_PER_WORKER_MB=$PER_WORKER_MB — a per-worker cost of 0 divides by zero and leaves the cap undefined."
        return 1
    }
    [ "$MAX_WORKERS" -ge 1 ] || {
        err "REFUSING: REPAIR_MAX_WORKERS=$MAX_WORKERS — a cap of 0 is a loop that can never repair anything; defer on disk or load instead."
        return 1
    }
    [ "$INTERVAL_S" -ge 30 ] || {
        err "REFUSING: REPAIR_INTERVAL_S=$INTERVAL_S — below 30 s this is a spin loop, not a cadence."
        return 1
    }
    return 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --once) MODE=once ;;
        --loop) MODE=loop ;;
        --trigger) MODE=trigger ;;
        --dry-run) DRY=1 ;;
        --print-capacity) MODE=capacity ;;
        --status) MODE=status ;;
        -h|--help) awk 'NR>1 && /^set -uo pipefail/ {exit} NR>1 {sub(/^# ?/,""); print}' "$0"; exit 0 ;;
        *) echo "usage: $0 [--once|--loop|--trigger|--dry-run|--print-capacity|--status]" >&2; exit "$EXIT_REFUSING" ;;
    esac
    shift
done

case "$MODE" in
    capacity) print_capacity ;;
    status) show_status ;;
    once)
        validate_knobs || { write_status refusing 0 - - - - "invalid-knob"; exit "$EXIT_REFUSING"; }
        one_pass "$DRY"
        ;;
    loop)
        validate_knobs || { write_status refusing 0 - - - - "invalid-knob"; exit "$EXIT_REFUSING"; }
        log_line "loop: interval ${INTERVAL_S}s, repo ${REPO_SLUG} at ${REPO_PATH}, checkout ${CELL_HOME}"
        # ⛔ THE LOOP NEVER DIES ON A BAD PASS. A deferred or refusing pass is a VERDICT, and the next
        # pass may be the one that works (the disk is reclaimed, the load falls). Exiting would make
        # systemd's Restart=always a crash-loop that repairs nothing — the #2700 §1.2 shape. The PASS
        # LOCK is taken inside `one_pass`, so it covers this mode too (a manual `--once` beside the
        # unit is a second dispatcher on one checkout, and is skipped with a named reason).
        while :; do
            # ⛔ THE DRY-RUN FLAG REACHES THE LOOP ARM TOO (round-3 review). It was threaded into the
            # `once` arm only, so `--loop --dry-run` — the natural way to preview what the unit will do
            # — reaped worktrees and spawned repair workers for real: a flag that reads safe and acts.
            ( one_pass "$DRY" ) || true
            sleep "$INTERVAL_S"
        done
        ;;
    trigger)
        # ── the event-driven front end (#2700 C5) ─────────────────────────────────────────────
        # ⛔ ONE ACTUATOR, TWO CLOCKS. This arm does not repair anything itself: it `exec`s the
        # trigger, whose child is THIS script in its one-pass mode. So there is one unit, one
        # installer, one queue — and every gate above still decides every pass.
        TRIGGER="$SCRIPTS/pr-doctor-trigger.py"
        if [ ! -f "$TRIGGER" ]; then
            err "REFUSING: $TRIGGER is absent — the trigger is this unit's front end, and a unit whose ExecStart cannot resolve its own front end is not activation."
            write_status refusing 0 - - - - "trigger-missing:$TRIGGER"
            exit "$EXIT_REFUSING"
        fi
        # ⛔ A MISSING INTERPRETER IS A REFUSAL, NOT A CRASH LOOP (the `flock` rule one seam over):
        # systemd would restart an exec that cannot start, for ever, with the reason only in a journal.
        PYTHON="${PYTHON_BIN:-$(command -v python3 2>/dev/null || true)}"
        if [ -z "$PYTHON" ]; then
            err "REFUSING: no python3 on PATH — the trigger cannot be exec'd, so this box cannot run its repair front end."
            write_status refusing 0 - - - - "python3-missing"
            exit "$EXIT_REFUSING"
        fi
        validate_knobs || { write_status refusing 0 - - - - "invalid-knob"; exit "$EXIT_REFUSING"; }
        log_line "trigger: ${REPO_SLUG} at ${REPO_PATH}; poll ${TRIGGER_POLL_S}s debounce ${TRIGGER_DEBOUNCE_S}s backstop ${TRIGGER_BACKSTOP_S}s retry_min ${TRIGGER_RETRY_MIN_S}s"
        # ⛔ `exec`, not a subprocess: the trigger must BE the unit's main process, so `Restart=always`
        # and `KillMode=process` describe the thing that decides WHEN a pass runs. The repo/dir pair is
        # passed explicitly (the loop's own resolution, not a second default), and `--state-dir` keeps
        # the lock and the remembered fingerprint beside this unit's status row.
        exec "$PYTHON" "$TRIGGER" --repo "$REPO_SLUG" --repo-dir "$REPO_PATH" \
            --poll "$TRIGGER_POLL_S" --debounce "$TRIGGER_DEBOUNCE_S" \
            --backstop "$TRIGGER_BACKSTOP_S" --retry-min "$TRIGGER_RETRY_MIN_S" \
            --state-dir "$STATE_DIR"
        ;;
esac
