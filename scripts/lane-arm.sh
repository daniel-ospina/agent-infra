#!/bin/bash
# lane-arm.sh -- the SCHEDULED arm for the lane classifier, on both platforms.
#
# WHY THIS EXISTS (measured 2026-10-31, agent-infra)
# -------------------------------------------------
# The classifier is real and the two lists are real:
#   scripts/lane-status.py   WORKING / WAITING-CHILD / WIP-IDLE / DONE-IDLE / WEDGED / EMPTY /
#                            UNKNOWN / UNBOUND, from identity -> process -> CPU-TIME DELTA -> child
#                            -> tool age (never mtime, never `ps -o pcpu`).
#   scripts/lane-actions.py  turns that into LIST 1 (idle, needs a dispatch), LIST 2 (wedged, to
#                            unblock, WITH WHY) and state/NEEDS-ACTION.md.
#
# WHAT WAS MISSING IS A PRODUCER THAT DOES NOT DEPEND ON THE THING IT WATCHES.
#   state/NEEDS-ACTION.md is written by `lane-actions.py`, whose ONLY live callers are the heartbeat
#   tick (`heartbeat-loop.sh:585`) and its detached fallback (`lane-scan-fallback.sh:105`) -- and the
#   fallback is itself launched BY the tick (`heartbeat-loop.sh:613`). So when the heartbeat dies, the
#   classifier's input freezes: measured on this box, the heartbeat log stopped 2026-10-26T01:47 and
#   FOUR artefacts froze together (`NEEDS-ACTION.md` 6810 min, `lane-status.last.json` 6816 min,
#   `NEEDS-ACTION.beat` 6812 min, the heartbeat log 6802 min). That is the same defect class #1178
#   removed for `lane_liveness.py`: *"a pull tool is silent in exactly that scenario."*
#   The one instrument that kept running (`com.eldato.lane-liveness`) is a DIFFERENT program with a
#   different state model (dead / idle / running-quiet) and no CPU-delta arm, so it cannot see a
#   wedge at all.
#
# AND ON THE CELLS THERE IS NO PRODUCER AT ALL. Measured 2026-10-31 on all three cells: `lane-actions.py`
#   and `scripts/fleet/` are deployed, but `scripts/lane-status.py` (the classifier it shells out to)
#   is ABSENT, so the only thing that exists is the half that already failed:
#     lane-actions: lane-status.py failed after 0.0s of a 60.0s budget ...; there is NO previous
#     snapshot on this box -- nothing has ever been read here
#
# WHAT THIS SCRIPT IS: the bound, the honesty, and the handoff -- nothing else.
#   * it TAKES THE MEASUREMENT (bounded `lane-status.py --json`) and PUBLISHES it atomically;
#   * it RENDERS THE LISTS (`lane-actions.py --stdin <snapshot>`, cache-aware, so it never re-samples);
#   * it writes state/LANE-QUEUE.tsv -- ONE machine-readable line per WEDGED lane, the handoff a
#     consumer drains (the .md is for a human; a program should not parse prose);
#   * it REFUSES A STALE SNAPSHOT: a frozen input is not a current verdict, so it says so and exits
#     non-zero. A pass that cannot measure is NEVER exit 0 -- that is the no-op-gate class
#     (AGENTS.md "Product Over Process": a gate that exits 0 when it cannot run), and the cell
#     measurement above is exactly that shape today.
#
# ⛔ REPORT-ONLY BY DESIGN, AND THAT IS A RECORDED DECISION, NOT AN OVERSIGHT.
#   state/LANE-STATE-DECISION-TREE.md rules: *"ambiguous -> report, do not act. A false DONE_READY
#   re-tasks a mid-work lane; a false STALLED wakes an expensive session for nothing. Reporting costs
#   nothing."* And docs/ops/fleet-liveness.md fixes reaping at THREE GATES (zero CPU delta with a
#   stated tolerance; ancestry walked to the top so a human's terminal is never touched; progress
#   judged against the process's own expected distribution). This script computes NONE of them as an
#   action: it emits the WHY line and the queue, and the ACT is a controller's
#   (`scripts/unblock-lane.sh <child> <sid>` for a parked child -- deliberately still uncalled by
#   anything, because the decision that it is safe is a human/controller judgement, not a timer's).
#   WHAT WOULD MAKE THIS ACT: a consumer that owns session ancestry (see below) draining
#   state/LANE-QUEUE.tsv and running `unblock-lane.sh` on a row whose WHY names a PARKED CHILD, with
#   the three gates re-measured at the moment of action. Nothing in this file may decide that.
#
# ⛔ THE ANCESTRY CONSTRAINT, WHICH IS WHY THIS IS NOT A SEND.
#   cmux authorises by ancestry -- `cmux workspace list`/`send` refuse a caller that was not started
#   inside cmux ("Access denied - only processes started inside cmux can connect"), measured by
#   running the launchd job. So a launchd job / systemd unit can never ACT on a pane, however healthy
#   it is. The arm therefore stops at the FILE, and the file's consumer must be a process that is a
#   legitimate ancestor: the controller loop / the tmux-resident doctor. `cloud-cell-doctor.sh`'s
#   `lanes` role calls this script on the cells for exactly that reason; `cloud-cell-supervisor.sh
#   status` reads the per-role record it writes.
#
# PORTABILITY: bash 3.2 (macOS) and bash 5 (Linux). No `timeout(1)` (macOS does not ship it -- hence
# `bounded()`), no /proc, no `free`, no GNU-only flags. `python3` is the only dependency, which both
# platforms already need for the classifier itself.
#
# EXIT: 0 published a fresh verdict (lists + queue)
#       4 could not measure, or the snapshot is stale, or the lists failed -- NOTHING is published
#         as current, and the previous artifacts are left standing (nothing is lost).
#
# USAGE:
#   lane-arm.sh                     # sample + publish (the scheduled form)
#   lane-arm.sh --max-snapshot-age 3600   # refuse a snapshot older than this (default: 900 s)
#   lane-arm.sh --print             # also print the first 40 lines of the recap
#   lane-arm.sh --budget 240        # hard bound for the sampler (default: 240 s)

set -u

SC="${LANE_ARM_SCRIPTS:-$HOME/.pi/agent/scripts}"
STATE="${LANE_ARM_STATE:-$HOME/.pi/agent/state}"
PY="${LANE_ARM_PYTHON:-}"
if [ -z "$PY" ]; then
  if [ -x /usr/bin/python3 ]; then PY=/usr/bin/python3
  elif command -v python3 >/dev/null 2>&1; then PY="$(command -v python3)"
  else echo "lane-arm: no python3 (and the classifier needs it)" >&2; exit 4; fi
fi

SNAP="$STATE/lane-status.last.json"
RECAP="$STATE/NEEDS-ACTION.md"
QUEUE="$STATE/LANE-QUEUE.tsv"
LOG="$STATE/lane-arm.log"
LOCK="$STATE/lane-arm.lock"
STALE_LOCK_S=900
BUDGET=240
MAX_AGE=900
SHOW=0

while [ $# -gt 0 ]; do
  case "$1" in
    --budget)            [ $# -ge 2 ] || { echo "lane-arm: --budget needs a value" >&2; exit 2; }
                         BUDGET="$2"; shift 2 ;;
    --max-snapshot-age)  [ $# -ge 2 ] || { echo "lane-arm: --max-snapshot-age needs a value" >&2; exit 2; }
                         MAX_AGE="$2"; shift 2 ;;
    --print)             SHOW=1; shift ;;
    -h|--help)           sed -n '2,80p' "$0"; exit 0 ;;
    *) echo "lane-arm: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

mkdir -p "$STATE" 2>/dev/null || { echo "lane-arm: cannot create $STATE" >&2; exit 4; }

log() { printf '%s LANE-ARM %s\n' "$(date '+%m-%d %H:%M:%S')" "$1" >>"$LOG" 2>/dev/null || true; }

# Run "$@" with a hard bound. macOS has no timeout(1); this is the same SHAPE
# lane-scan-fallback.sh uses, deliberately, so there is one pattern on the box -- but NOT its bug:
# there, `kill "$wd"` kills only the wrapper subshell and the `sleep` it forked survives, reparented
# to init, to fire its `kill -TERM/-KILL` at the deadline against a pid that has long since exited
# (and may have been REUSED). On a healthy pass that happens twice, every 30 minutes: a destructive
# action taken from a stale measurement, which is the class this repo names. So: keep the sleeper's
# pid, kill it, and re-prove the child's identity before signalling it.
bounded() {
  local secs="$1"; shift
  "$@" & local pid=$!
  local me=$$
  # ⛔ THE OWNERSHIP PREDICATE IS `ppid == me`, NOT AN IMAGE COMPARISON. An image/`lstart` comparison
  # looks safer and is WRONG here: `/usr/bin/python3` on macOS is a shim that RE-EXECS the framework
  # python, so the command line and even the image change microseconds after the fork -- and a
  # re-proof that compares the image therefore declines to kill the very process this bound exists
  # for. Measured: a 30 s `python3` child under a 2 s bound ran the full 30 s and the arm reported
  # success. `ppid` survives exec, and it is exactly the question being asked -- is this still MY
  # child? -- while a RECYCLED pid answers no (its parent is some other process, or it is gone).
  # ⛔ THE WATCHDOG OWNS ITS OWN SLEEPER: the first version forked the sleeper in the MAIN shell and
  # `wait`ed on it from inside a subshell, which cannot work ("pid N is not a child of this shell"),
  # so the watchdog exited at once and the bound killed nothing, ever.
  ( sleep "$secs" || exit 0
    [ "$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')" = "$me" ] || exit 0
    kill -TERM "$pid" 2>/dev/null
    sleep 5
    [ "$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')" = "$me" ] || exit 0
    kill -KILL "$pid" 2>/dev/null ) 2>/dev/null & local wd=$!
  wait "$pid" 2>/dev/null; local rc=$?
  kill "$wd" 2>/dev/null; wait "$wd" 2>/dev/null
  return $rc
}

age_s() {  # <file> -> seconds since mtime, or empty when absent
  [ -e "$1" ] || return 1
  "$PY" -c 'import os,sys,time
try: print(int(time.time()-os.stat(sys.argv[1]).st_mtime))
except OSError: raise SystemExit(1)' "$1" 2>/dev/null
}

fail() { echo "lane-arm: $1" >&2; log "FAIL $1"; exit 4; }

# ── lock: one arm at a time; break a stale one (a SIGKILLed run cannot clean up) ────────────────
if [ -e "$LOCK" ]; then
  # ⛔ DROP THE `|| la=0`. With it, an UNREADABLE stamp became 0, which is `-lt STALE_LOCK_S`, so the
  # pass skipped with exit 0 and the `''` arm of the case below was UNREACHABLE — the "unreadable is
  # maximally stale" half of this rule was described but not implemented. Leaving `la` empty lets the
  # case see it.
  la="$(age_s "$LOCK")"
  # ⛔ A NEGATIVE AGE IS NOT A FRESH LOCK. A backward clock step, a copied file or `touch -t` puts the
  # mtime in the future, and a negative number satisfies `-lt STALE_LOCK_S` — so the pass would skip
  # with exit 0 forever and the stale-break below would be unreachable until real time passed
  # mtime+900. Under `Type=oneshot` that exit 0 reads as SUCCESS: a healthy timer with nothing
  # produced, which is the no-op-gate class this whole arm exists to refuse. An UNREADABLE or FUTURE
  # stamp is MAXIMALLY stale (break it), never a fresh lock.
  case "$la" in ''|-*) la=$STALE_LOCK_S ;; esac
  if [ "$la" -lt "$STALE_LOCK_S" ]; then
    echo "lane-arm: another pass holds $LOCK (${la}s) -- skipping" >&2
    log "SKIP lock held ${la}s"
    exit 0
  fi
  rm -f "$LOCK" 2>/dev/null || true
fi
( set -C; : >"$LOCK" ) 2>/dev/null || { echo "lane-arm: cannot create $LOCK in $STATE (read-only or full?)" >&2; log "FAIL cannot create lock"; exit 4; }
trap 'rm -f "$LOCK" 2>/dev/null || true' EXIT INT TERM

# ── 1. THE MEASUREMENT (never mtime, never ps -o pcpu -- that is lane-status.py's own rule) ─────
[ -f "$SC/lane-status.py" ] || fail "classifier ABSENT at $SC/lane-status.py -- install it before scheduling this arm (on the cells it was missing entirely on 2026-10-31, which made lane-actions.py fail on every pass)"

TMP="$SNAP.arm.$$"
# ⛔ `--no-cache` IS NOT AN OPTIMISATION, IT IS THE POINT. `lane-status.py --json` serves a cached
# snapshot (state/lane-status.cache, keyed on --only, 420 s TTL) unless asked not to, and the cache key
# is the same `[null]` for this arm as for the heartbeat tick — so without this flag the arm happily
# REPUBLISHES the tick's snapshot and calls it a fresh measurement. Worse, the freshness guard below
# measures the mtime of the file this script just wrote, so a cached read would print `snapshot_age=0s`
# no matter how old the data was and `--max-snapshot-age` could never fire. The clock exists to produce
# a CURRENT verdict; a cached one is the measurement-artifact-as-state failure it is meant to remove.
# ⛔ A BOUND MUST REPORT AS A BOUND. `bounded()` returns the child's OWN exit status, so a classifier
# that dies instantly with a real error and a classifier killed at the watchog bound both land here.
# Reporting the second for both sends the reader to tune a budget instead of to the actual error —
# which is exactly the misreport this script's header quotes from the cells ("failed after 0.0s of a
# 60.0s budget", where nothing timed out at all).
bounded "$BUDGET" "$PY" "$SC/lane-status.py" --json --no-cache >"$TMP" 2>"$STATE/lane-arm.status.err"
rc=$?
if [ "$rc" -ne 0 ]; then
  rm -f "$TMP"
  case "$rc" in
    137|143) fail "classifier KILLED at the ${BUDGET}s bound (see $STATE/lane-arm.status.err); previous snapshot left standing" ;;
    *)     fail "classifier EXITED $rc — not a timeout (see $STATE/lane-arm.status.err); previous snapshot left standing" ;;
  esac
fi
# A partial/half-written snapshot must never be published, and neither must an empty one.
if ! "$PY" -c 'import json,sys
d=json.load(open(sys.argv[1]))
lanes=d.get("lanes") if isinstance(d,dict) else d
if lanes is None or not isinstance(lanes,list): raise SystemExit(1)' "$TMP" 2>/dev/null; then
  rm -f "$TMP"
  fail "classifier output did not parse as a snapshot; not publishing it"
fi

# ── 2. FRESHNESS IS PART OF THE VERDICT (a measurement artifact is not a state) ─────────────────
# Measured on the TEMP file -- the bytes this pass actually produced. Measuring $SNAP here would be a
# tautology (its mtime is microseconds old whatever the data age), which is how an earlier revision
# came to advertise a refusal it could never perform.
sa="$(age_s "$TMP")" || fail "the temp snapshot vanished before the freshness check"
if [ "${sa:-999999}" -gt "$MAX_AGE" ]; then
  rm -f "$TMP"
  fail "snapshot is ${sa}s old (> ${MAX_AGE}s) -- refusing to present it as current"
fi

# ── 3. THE LISTS (cache-aware: --stdin never re-samples, so this cannot double the cost) ───────
[ -f "$SC/lane-actions.py" ] || fail "lane-actions.py ABSENT at $SC/lane-actions.py"
if ! bounded "$BUDGET" "$PY" "$SC/lane-actions.py" --stdin "$TMP" >"$STATE/lane-arm.actions.out" 2>"$STATE/lane-arm.actions.err"; then
  rm -f "$TMP"
  fail "lane-actions.py failed (see $STATE/lane-arm.actions.err); previous snapshot AND recap left standing"
fi
# ⛔ THE LISTS ARE RENDERED *BEFORE* THE SNAPSHOT IS PUBLISHED, so this file's own promise -- "a pass
# that cannot measure publishes nothing and the previous artifacts are left standing" -- is TRUE. The
# other order destroys the last good fleet view in a pass that then abstains: a degraded read is still
# valid JSON with a list, so it would replace the good snapshot and only then be refused by
# lane-actions.py. `--stdin <path>` does not re-sample, and lane-actions derives its age from that
# file's mtime, so rendering against the temp file changes nothing it reports.
# ⛔ AND THIS IS THE ONLY `mv` TO $SNAP IN THIS FILE. An earlier revision left the old publish in
# place as well, so the temp file was already gone when the renderer ran: every pass exited 4 AND the
# snapshot had been replaced -- the exact failure this ordering exists to prevent, twice over.
mv "$TMP" "$SNAP" || { rm -f "$TMP"; fail "cannot publish $SNAP"; }

# ── 4. THE HANDOFF: one machine-readable line per WEDGED lane ─────────────────────────────────
# The .md is prose for a human; a consumer should not have to parse it. This is the contract.
# Columns: verdict <TAB> lane <TAB> workspace <TAB> session <TAB> why
# The WHY is BUILT FROM THE SNAPSHOT FIELDS, never parsed out of the prose recap: the recap is for a
# human, and a consumer that regex-scrapes it is one wording edit away from silently matching nothing
# (the "a gate that cannot answer its own question" class). Every number a human needs to judge the
# row -- the CPU delta, the child, the tool and its own declared bound, how long it has been quiet --
# is on the line, so the reader never has to go and re-measure to decide whether it is a wedge.
QTMP="$QUEUE.arm.$$"
# The pass marker the queue header carries (see the comment at the header). With --no-cache above this
# age is a REAL measurement age; exporting it rather than letting the renderer guess keeps the stamp
# honest.
export LANE_ARM_SNAPSHOT_AGE="${sa:-?}"
if ! "$PY" - "$SNAP" >"$QTMP" <<'PYEOF'
import json, os, sys, time
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit(1)
lanes = d.get("lanes") if isinstance(d, dict) else d
if not isinstance(lanes, list):
    raise SystemExit(1)
print("# verdict\tlane\tworkspace\tsession\twhy")
# ⛔ THE PASS MARKER IS NOT DECORATION. The queue is deliberately LEFT STANDING when a pass abstains,
# so without a stamp a consumer cannot tell "measured now, zero wedged" from "a three-day-old verdict,
# nothing has measured since" — which is the exact failure this clock exists to remove (a 6,810-minute
# stale NEEDS-ACTION.md still announcing `IDLE (0)`). The age a consumer trusts is ON the row, not
# inferred from the file's mtime, because a consumer that has to stat the file has to trust the same
# layer that froze.
print("# generated\t%s\tsnapshot_age=%ss" % (time.strftime("%Y-%m-%dT%H:%M:%S%z"), os.environ.get("LANE_ARM_SNAPSHOT_AGE", "?")))
print("# consumer: a process that HOLDS SESSION ANCESTRY (controller loop / tmux-resident doctor)")
print("# drains a PARKED-CHILD row with scripts/unblock-lane.sh <child> <sid>; report-only until then.")
n = 0
for ev in lanes:
    if not isinstance(ev, dict):
        continue
    st = str(ev.get("state") or ev.get("verdict") or "").upper().replace("-", "_")
    # ⛔ THE QUEUE IS THE MACHINE FORM OF LIST 2, SO IT MUST USE LIST 2'S RULE — not a WEDGED-only
    # filter. `lane-actions.py` puts STALLED, DEAD and CHILD-STUCK in its `wedged` bucket (the same
    # rows a human sees under "TO UNBLOCK"), and it renders a raw WEDGED row through the words layer,
    # which can land it in LIST 1 or REPORT instead. So `st != "WEDGED"` disagreed with the recap in
    # BOTH directions: a fleet of parked children rendered `wedged=0` / exit 0 here while the human
    # list showed them as to-unblock, and a WEDGED row could be queued after the words layer had
    # already dispositioned it. Match the bucket, and keep the split-token form because the verdict
    # arrives hyphenated.
    if st not in ("WEDGED", "STALLED", "DEAD", "CHILD_STUCK", "CHILD_STUCK_PARKED"):
        continue
    lane = str(ev.get("lane") or ev.get("name") or "-")
    ws = str(ev.get("ws") or ev.get("workspace") or ev.get("workspaceId") or "-")
    sid = str(ev.get("sid") or ev.get("session") or ev.get("sessionId") or "-")
    tool = ev.get("tool") if isinstance(ev.get("tool"), dict) else {}
    child = ev.get("child")
    cpid = child.get("pid") if isinstance(child, dict) else child
    parts = []
    cpu = ev.get("cpu")
    parts.append("cpu_delta=%s" % ("UNREAD (no exact pid<->lane attribution)" if cpu is None else cpu))
    parts.append("child=%s" % (cpid if cpid else "none"))
    if tool:
        parts.append("tool=%s age=%ss bound=%ss" % (tool.get("name") or "?", tool.get("age"), tool.get("timeout")))
    else:
        parts.append("tool=none")
    if ev.get("stale_s") is not None:
        parts.append("quiet=%ss" % ev.get("stale_s"))
    if ev.get("degraded"):
        parts.append("DEGRADED")
    declared = ev.get("why") or ev.get("reason") or ev.get("detail")
    if declared:
        if isinstance(declared, list):
            declared = " | ".join(str(x) for x in declared)
        parts.insert(0, str(declared))
    why = "; ".join(parts)
    print("WEDGED\t%s\t%s\t%s\t%s" % (lane, ws, sid, why.replace("\t", " ").replace("\n", " ")))
    n += 1
sys.stderr.write("wedged=%d\n" % n)
PYEOF
then
  rm -f "$QTMP"
  fail "could not render the wedged queue from the snapshot"
fi
mv "$QTMP" "$QUEUE" || { rm -f "$QTMP"; fail "cannot publish $QUEUE"; }

WEDGED="$(grep -c '^WEDGED' "$QUEUE" 2>/dev/null || true)"
WEDGED="${WEDGED:-0}"
LANES="$("$PY" -c 'import json,sys
d=json.load(open(sys.argv[1])); l=d.get("lanes") if isinstance(d,dict) else d
print(len(l) if isinstance(l,list) else 0)' "$SNAP" 2>/dev/null || echo '?')"

echo "lane-arm: lanes=$LANES wedged=$WEDGED snapshot_age=${sa}s recap=$RECAP queue=$QUEUE"
log "OK lanes=$LANES wedged=$WEDGED age=${sa}s"
if [ "$SHOW" = "1" ]; then
  echo "---- LIST 1 / LIST 2 (first 40 lines) ----"
  head -40 "$RECAP" 2>/dev/null
fi
if [ "$WEDGED" -gt 0 ]; then
  echo "lane-arm: WEDGED lanes needing a HUMAN-ACTIONABLE look:"
  grep '^WEDGED' "$QUEUE" | while IFS="$(printf '\t')" read -r _v lane ws sid why; do
    echo "  WEDGED  $lane  [$ws]"
    echo "     why: $why"
    echo "     act: scripts/unblock-lane.sh <child> <sid>  (only if why names a PARKED child; otherwise report)"
  done
fi
exit 0
