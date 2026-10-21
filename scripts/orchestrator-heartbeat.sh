#!/usr/bin/env bash
# RAISE THE CLI DEADLINE. Measured 2026-10-01: `cmux workspace list` takes 0.2-2s on a
# quiet box but 13.4-15.1s at load 130+, against a fixed 15s CLI deadline — so a slow
# answer is indistinguishable from a hang (`Error: Command timed out`). That made the
# fleet look like "cmux send is dead" when it was a ~1.6s margin at high load.
export CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC="${CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC:-60}"

# orchestrator-heartbeat.sh — wake the orchestrator on a cadence, WITHOUT the owner prompting.
#
# WHY THIS EXISTS
# The orchestrator (the pi session that supervises the fleet) only acts when a human
# types. So a wedged lane sits for hours and finished work waits on a prompt. This is
# the missing clock.
#
# DESIGN RULES (each one is load-bearing, and two of them were BUGS AT FIRST WRITE)
# 1. CONDITIONAL, not periodic-notification: nudges only when ACTIONABLE (a lane stale
#    enough to be a WEDGE SUSPECT, or a lane idle after finishing). An unconditional
#    "wake up" every 5 min would flood the orchestrator overnight.
# 2. OFF BY DEFAULT via a kill file:   touch ~/.pi/agent/state/HEARTBEAT-OFF
# 3. BOUNDED LOG (last 2000 lines).
# 4. IT VERIFIES ITS OWN DELIVERY and records delivered=yes|UNVERIFIED.
# 5. IT DOES NOT READ ~/Documents (macOS TCC denies a launchd-spawned bash that tree —
#    see com.tortoise.worktree-reaper.plist). Everything here is under ~/.pi/agent,
#    which is why a plain `bash` entry point is sound where the reaper needs the
#    checkout's own interpreter.
#
# ⛔ TWO FAILURES THIS SCRIPT WAS BORN WITH — DO NOT REINTRODUCE THEM:
#   (a) IT USED `rg`. ripgrep lives at ~/.pi/agent/bin/rg, which is NOT on launchd's
#       PATH. Every rg call failed silently and the spinner test returned FALSE for
#       every lane — so a genuinely WEDGED lane (A, byte-identical at 1,497,956 bytes)
#       was reported as IDLE. A heartbeat that cannot tell wedged from idle is worse
#       than none, because it reports a green. This version uses grep/awk/case ONLY.
#   (b) IT PINNED SESSION IDS IN THE REGISTRY. Session ids DIE ON RESPAWN, so after a
#       recovery the script measured the lane's DEAD session and called a working lane
#       IDLE(28m). Lanes respawn constantly — this is the fleet's normal recovery path.
#       This version resolves each lane's CURRENT session by scanning for its label,
#       and treats the registry id only as a hint.
#
# EXIT: always 0 (a heartbeat that dies loudly into a log nobody reads is worse than
# one that records its own failure in the line it did write).

set -uo pipefail

DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

STATE="$HOME/.pi/agent/state"
# The classifier lives beside this script. Under launchd there is no ~/.pi
# expansion and no PATH inheritance, so it is addressed absolutely.
SCRIPTS="$HOME/.pi/agent/scripts"
LOG="$STATE/orchestrator-heartbeat.log"
KILL="$STATE/HEARTBEAT-OFF"
REG="$STATE/lane-registry.tsv"
SD="$HOME/.pi/agent/sessions"

ORCH_WS="C2C97E96-0CBC-4DFE-BC91-FEF44F09B5BD"
ORCH_SURFACE="1510BE3B-AFFD-4BDB-80BC-A15BC599D698"
ORCH_MARK="01a102a3"

STALE_MIN=12   # >= this, with a spinner  => WEDGE SUSPECT
IDLE_MIN=9     # >= this, with no spinner => finished/idle
MIN_GAP_MIN=4  # never nudge more often than this (was 8 — it throttled the 5-min pulse)
PULSE_MIN=5           # send the short form anyway if nothing has been said for this long

NOW=$(date +%s); TS=$(date +%H:%M:%S)

log() { printf '%s %s\n' "$(date '+%m-%d %H:%M:%S')" "$*" >> "$LOG" 2>/dev/null; }

# -- bounded log --------------------------------------------------------------
if [ -f "$LOG" ]; then
  L=$(wc -l < "$LOG" 2>/dev/null || echo 0)
  if [ "$L" -gt 2000 ]; then tail -1200 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"; fi
fi

if [ -f "$KILL" ] && [ "$DRY" != "1" ]; then log "SKIP kill-file present"; exit 0; fi
[ -r "$REG" ] || { log "SKIP no lane registry at $REG"; exit 0; }
[ -d "$SD" ]  || { log "SKIP no sessions dir"; exit 0; }

# -- the question gate, run as a safety net ----------------------------------
# A lane's OWN path is to run ask-owner.py itself and label its question. This
# is the net under it: a lane that posts a question and then just waits gets
# swept up here. It is deliberately NOT under the nudge rate limit — a PASS or
# a BOUNCE is a ONE-SHOT event per issue (the labels de-duplicate it, so it can
# never repeat), and it must not be swallowed because a lane nudge went out
# three minutes ago. The scan holds no state of its own: the labels ARE the
# state, which is why a question already sent back is not re-scored, and why a
# lane re-submitting simply removes the label.
#
# Failure is silent on purpose: if gh is unauthenticated or a repo is renamed,
# the heartbeat must still do its ordinary job.
N_ASK=0
ASK_EV=""
# ── run the expensive scan AT MOST ONCE PER INTERVAL ─────────────────────────────────────────
# ask-owner.py --scan costs ~7-9 min of CPU: it pulls up to 1000 open issues WITH ALL COMMENTS
# across 3 repos, then makes a per-answer gh call. Measured: passes of 531s / 448s / 476s / 408s
# against a 540s target, and the log's own "PASS done in 408s ... sleeping 132s" shows the loop
# sleeps target-minus-elapsed — so the cadence is ~9 min, NOT back-to-back (an earlier note in
# this very block claimed "continuous" and was wrong). But each pass still spends ~250-390s inside
# ask-owner, i.e. a ~75% CPU duty cycle, which is what this gate cuts (2026-10-12).
#
# WHY A CACHE AND NOT A NARROWER QUERY: a narrower query (--search updated:>=<ts>) also cuts cost
# but can MISS a question, and a missed question is the one failure this gate exists to prevent.
# Caching cannot miss one: the labels ARE the scan state, so a result stays valid, and the cache
# is refreshed within the interval. Cost is a few minutes of latency on a brand-new question.
#
# FAIL OPEN TOWARD CORRECTNESS: no cache, unreadable cache, non-numeric stamp, or age >=
# SCAN_MAX_AGE_S  =>  RUN THE SCAN. Only a fresh, parseable cache is trusted.
SCAN_INTERVAL_S="${SCAN_INTERVAL_S:-2700}"    # 45 min: reuse a result younger than this
SCAN_MAX_AGE_S="${SCAN_MAX_AGE_S:-10800}"     # 3 h:  never trust a cache older than this
ASK_CACHE="$STATE/ask-scan.cache"
ASK_CACHE_TS="$STATE/ask-scan.cache.ts"
ASK_ALL=""
ASK_FROM_CACHE=0
if [ "$DRY" != "1" ] && [ -s "$ASK_CACHE" ] && [ -s "$ASK_CACHE_TS" ]; then
  ASK_TS=$(cat "$ASK_CACHE_TS" 2>/dev/null || printf '0')
  case "$ASK_TS" in *[!0-9]*|"") ASK_TS=0 ;; esac
  ASK_AGE=$(( $(date +%s) - ASK_TS ))
  if [ "$ASK_AGE" -ge 0 ] && [ "$ASK_AGE" -lt "$SCAN_INTERVAL_S" ]; then
    if ASK_ALL=$(cat "$ASK_CACHE" 2>/dev/null) && grep -q '^ASK ' <<<"$ASK_ALL"; then
      ASK_FROM_CACHE=1
      log "ask| scan REUSED (cache ${ASK_AGE}s old < ${SCAN_INTERVAL_S}s)"
    else
      ASK_ALL=""
    fi
  fi
fi
if [ "$ASK_FROM_CACHE" != "1" ]; then
  ASK_ALL=$(/usr/bin/python3 "$SCRIPTS/ask-owner.py" --scan $([ "$DRY" = "1" ] && printf -- '--dry-run') 2>&1)
  # Cache only a USABLE result — never cache a failure, or the failure becomes sticky for 45 min.
  if grep -q '^ASK ' <<<"$ASK_ALL"; then
    printf '%s' "$ASK_ALL" > "$ASK_CACHE.$$"  && mv "$ASK_CACHE.$$" "$ASK_CACHE"
    date +%s                > "$ASK_CACHE_TS.$$" && mv "$ASK_CACHE_TS.$$" "$ASK_CACHE_TS"
  fi
fi
ASK_RAW=$(printf '%s' "$ASK_ALL" | tail -1)
case "$ASK_RAW" in
  ASK\ *)
    ASK_EV="$ASK_RAW"
    N_SCANFAIL=$(printf '%s' "$ASK_EV" | awk '{for(i=1;i<=NF;i++){if(split($i,a,"=")==2 && a[1]=="scan_failed") s+=a[2]}} END{print s+0}')
    if [ "${N_SCANFAIL:-0}" -gt 0 ]; then
      # An unreadable surface is NOT a clean zero. Force an alert so the
      # failure reaches the orchestrator instead of being rate-limited away.
      log "ALERT ask-gate scan FAILED on ${N_SCANFAIL} repo/label read(s)"
      N_ASK=$((N_ASK + 1))
      ASK_EV="$ASK_EV scan_failed=${N_SCANFAIL}"
    fi
    N_ASK=$(printf '%s' "$ASK_EV" | awk '{for(i=1;i<=NF;i++){if(split($i,a,"=")==2 && (a[1]=="pass" || a[1]=="bounce" || a[1]=="answered")) s+=a[2]}} END{print s+0}')
    # An answer that could not be routed to a lane has to be carried by hand, so the
    # whole scan output is kept: the summary line says HOW MANY, only these lines say
    # WHICH. Without this the failure mode is an answer nobody ever delivers.
    if [ "$N_ASK" -gt 0 ]; then
      printf '%s\n' "$ASK_ALL" | grep -v '^ASK ' | while IFS= read -r ln; do
        [ -n "$ln" ] && log "  ask| $ln"
      done
    fi
    ;;
  *) log "NOTE ask-owner scan produced nothing usable" ;;
esac

# -- safety net: did any OWNER ANSWER strand? ---------------------------------
# ask-owner.py can only see what the labels and events show, and the delivery path
# has several ways to end silently. This is the read-only cross-check that nothing
# stranded — the tool that would have caught the five stranded answers of
# 2026-09-27, and which until now was called by NOTHING (a detector that is not run
# is documentation, not a safety net).
# LOG-ONLY by design: it never notifies a lane and never labels an issue, so it
# cannot make anything worse and cannot spam.
UND=$(/usr/bin/python3 "$SCRIPTS/undelivered-answers.py" 2>/dev/null | tail -1)
case "$UND" in
  *"count=0"*) : ;;                     # nothing stranded
  UNDELIVERED*) log "STRANDED-ANSWERS $UND" ;;
  *) log "NOTE undelivered-answers produced nothing usable: ${UND:-<empty>}" ;;
esac

# -- delivery line: is the BETA moving? --------------------------------------
# The classifier above answers "is a lane wedged", which is almost always no — measured
# 2026-09-27: 44% of that day's nudges carried no alert, and the log contained ZERO
# mentions of P0, blocker, merge-ready, runner or rail. This adds the other half.
# SELF-CACHED to one recompute per hour (the script owns the cache), so a 5-minute
# heartbeat does not pay four API calls every tick.
DELIV=$(/usr/bin/python3 "$SCRIPTS/beta-progress.py" 2>/dev/null | tail -1)
case "$DELIV" in
  DELIVERY*) : ;;
  *) DELIV="" ;;
esac

# -- drain line: is the MERGE QUEUE the constraint? ---------------------------
# The lane classifier answers "is a lane wedged" and the delivery line prints
# "173 open PRs, 8 merged today" -- a BARE STATISTIC. Neither ever says the queue
# is the bottleneck, nor who is on it, nor how many lanes it needs. Measured
# 2026-09-28: 173 open, 24 merged/24h = 7.2 days to drain, ONE merge lane, and the
# one lane reads WAITING-CHILD (a verdict that appears in NEITHER alert nor known,
# so it is named NOWHERE in the message the orchestrator reads).
# merge-queue.py turns those numbers into a verdict and a demand.
QUEUE=$(/usr/bin/python3 "$SCRIPTS/merge-queue.py" 2>/dev/null | tail -1)
case "$QUEUE" in
  QUEUE*) : ;;
  *) QUEUE="" ;;
esac
# A bottleneck is a STANDING condition, so it must not flood: it bypasses the
# short-form suppression only once per RE-ALERT window, mirroring the lane rule
# (a verdict unchanged within the window is reported once, not every tick).
MQ_ALERTFILE="$STATE/merge-queue-alert.last"
MQ_ALERT=0
case "$QUEUE" in
  *VERDICT=BOTTLENECK*|*VERDICT=STALLED*)
    LASTQ=$(cat "$MQ_ALERTFILE" 2>/dev/null || echo 0)
    case "$LASTQ" in ""|*[!0-9]*) LASTQ=0 ;; esac
    if [ "$(( NOW - LASTQ ))" -ge 3600 ]; then MQ_ALERT=1; fi
    ;;
esac

# -- objective line: the QUALITATIVE objective, and whether MAIN IS RED -------------
# The lane classifier answers "is a lane wedged"; the queue line answers "is the merge
# queue the constraint"; neither ever looked at main, and neither stated the objective the
# owner named: DRAIN THE BACKLOG, without discarding useful work, and have a merge system
# that does not let it recur (owner ruling #6792). The numbers below it -- queue depth,
# main health, CI critical path -- are INDICATORS, not pass/fail targets; `waiting < 10`
# is the one real target, and CI time is a guideline that must not outrank the queue.
# NEITHER LOOKED AT MAIN AT ALL. Measured 2026-09-29: hours were spent reading lanes while
# a red main stopped the merge queue, so no PR could drain and every lane verdict was
# beside the point.
# objective.py prints one line and self-caches (900s), so this costs nothing per tick.
OBJ=$(/usr/bin/python3 "$SCRIPTS/objective.py" 2>/dev/null | tail -1)
case "$OBJ" in
  OBJECTIVE*) : ;;
  *) OBJ="" ;;
 esac
# A standing RED must not flood, but it must not be lost either: re-alert once per
# new main sha, so a fix that lands and re-reds is reported again.
OBJ_ALERT=0
case "$OBJ" in
  *VERDICT=FIX-MAIN*|*VERDICT=UNKNOWN*)
    OKEY=$(printf '%s' "$OBJ" | grep -o 'main=[A-Za-z]*@[0-9a-f]*' | head -1)
    OLAST=$(cat "$STATE/objective-alert.last" 2>/dev/null || echo "")
    if [ "${OKEY:-}" != "${OLAST:-}" ]; then
      OBJ_ALERT=1
      printf '%s' "${OKEY:-}" > "$STATE/objective-alert.last" 2>/dev/null
    fi
    ;;
esac

# -- rate limit (grep, not rg) ------------------------------------------------
RL=0
LAST=$(grep -o 'NUDGE at=[0-9]*' "$LOG" 2>/dev/null | tail -1 | cut -d= -f2)
if [ -n "${LAST:-}" ]; then
  GAP=$(( (NOW - LAST) / 60 ))
  if [ "$GAP" -lt "$MIN_GAP_MIN" ] && [ "$DRY" != "1" ]; then
    log "SKIP rate-limited (last nudge ${GAP}m ago)"
    RL=1
  fi
fi
# Rate-limited suppresses the LANE alert only. A question that cleared or failed
# the gate still gets through: it is one-shot and time-sensitive.
# ⛔ THE EXIT MOVED BELOW THE RECAP WRITE (2026-10-05) -- IT USED TO STAND HERE, ABOVE THE CLASSIFIER.
# Because the 5-minute cadence FLOOR nudges first on almost every cycle while this tick's own
# MIN_GAP is LONGER, the tick was rate-limited on most passes and exited BEFORE classifying. So
# state/lane-recap.last was almost never refreshed and the owner's heartbeat carried
# "(no lane-recap.last yet)" instead of lane state -- the exact thing the owner asked for.
# The rate limit is meant to suppress the SEND, not the CLASSIFICATION: classify and persist the
# recap on EVERY pass, then honour the rate limit before the expensive post-classification steps
# (turn-end, queue-dispatch) and before the send.

# -- classify every lane ------------------------------------------------------
# Delegated to lane-status.py, which combines SESSION-file delta + TRANSCRIPT
# + the cmux UI sign + CHILD state. The previous inline rule was stale+spinner,
# which mislabelled a lane WAITING ON A CHILD as WEDGED: a parent writes nothing
# to its own session while a child runs, so HANG sat at 72m stale with a spinner
# and read as wedged while it was working correctly. Two signals were missing —
# is a child in flight, and is that child still writing.
#
# A `task` child persists NO session file (it runs `pi -p`), so the child is
# judged by its on-disk effects and by elapsed time against the harness's own
# 20-minute in-flight bound. A pending child past that bound is CHILD-OVERDUE —
# which is the #5195 regression, visible from outside.
# ── ONE SCAN PER PASS, NOT TWO ────────────────────────────────────────────────
# ⛔ `--no-cache` WAS SELF-INFLICTED CONTENTION, AND IT IS WHY THIS TICK DIED.
#   This call is INLINE, so its cost is fully additive; nothing after it can run until it returns.
#   The detached fallback (heartbeat-loop.sh) runs the SAME `lane-status.py --sample 12` scan and is
#   launched ~1s after a tick dies — ~150s before the next one starts — so two full scans contended
#   for cmux on nearly every pass. cmux serialises internally, so the fallback's own scan measured
#   152-183s against 107s standalone, and the tick spent 210-380s of its 390s KILL TIMER on
#   lane-status plus the ask-owner pre-scan (61-97s): 5 of 6 passes were SIGTERM'd before VERDICTS,
#   the published snapshot stayed whatever the killed run left behind, and `lane-actions.py`
#   correctly refused it — so the loop had NO live fleet view. MEASURED 2026-10-12.
#   Dropping the flag lets the tick CONSUME the snapshot the fallback already published (the cache
#   is keyed on `--only`, TTL 420s, and this call shares that key). A cache MISS still scans for
#   real, so correctness is unchanged; the normal case stops paying twice for one answer.
#   Staleness cost, stated: the fleet view can be one pass old, which for a status report is the
#   right trade against having no view at all.
EV=$(/usr/bin/python3 "$SCRIPTS/lane-status.py" --json --sample 12 2>/dev/null \
  | tee "$STATE/lane-status.last.json.tmp" \
  | /usr/bin/python3 -c '
import json,sys
rows=json.load(sys.stdin)
NURT={"CHILD-OVERDUE":0,"CHILD-STUCK":1,"WEDGED":2,"EMPTY":3,"UNBOUND":3,"WIP-IDLE":4,"DONE-IDLE":5}
# The verdicts built off SINGLE proxies, and therefore the ones that produce false alarms:
# three fired on 2026-09-27 alone (a 119m merge rail, live children, a live code-reviewer).
WEAK={"CHILD-OVERDUE","CHILD-STUCK","WEDGED","WIP-IDLE","DONE-IDLE"}
SCREEN_CAP=[1]   # at most 1 Jev screen per tick; the rest are screened next tick
# KEEP THIS AT 1. I raised it to 2 earlier today (2026-10-05) to cut alert noise, and that was
# BACKWARDS. The tick writes the recap twice -- rich=0 at the early write, rich=1 after the triage --
# and the screens sit between them at roughly 30s each. So every screen added is time added EXACTLY
# where the tick is most likely to be killed at its own bound, i.e. before the rich=1 write. Measured
# consequence of the raise: the recap froze at rich=0 with mtime stuck for over five minutes while a
# tick ran, and the beat stayed [PROVISIONAL] -- the freeze this file exists to prevent. THE ORDERING
# IS THE POINT: a tick that finishes with one screen and publishes rich=1 beats a tick that runs two
# screens and is killed before publishing anything. Alert noise is the cheaper failure -- it is
# visible, harmless, and the next tick clears it; a missing rich=1 is silent and looks like the
# fleet is fine. Fix the noise at the READER (unscreened weak verdicts are not ATTENTION), never by
# spending the budget that lands the enriched write.
# CAP 3 -> 1 (2026-10-05). MEASURED: the tick was killed at its own bound on EVERY pass
# (`STALL orchestrator-heartbeat.sh exceeded 390s`) and died BEFORE the enriched recap write, which
# is why the beat stayed [PROVISIONAL] for ten minutes at a time while its ages froze. The budget
# was not the problem and raising it is not the fix: the pass is 540s and the nudger needs ~150s, so
# the tick has to FIT, not be permitted to overrun. At ~30s each, 3 screens cost 90s of the pass --
# a THIRD of the entire tick budget -- to investigate lanes that are already flagged STALLED and
# will still be stalled next tick. A screen deferred is a screen repeated, never a screen lost.
# The value of a heartbeat is that it ARRIVES; an exhaustive one that is killed every pass and
# reports PROVISIONAL is worth less than a partial one that finishes.

def screened_stalled(label):
    """Ask the evidence scorecard + ONE Jev call whether this lane is really stalled.

    FAILS OPEN, deliberately: any error returns True so the alert still fires. A
    classifier outage must never silence a watchdog. 3 of 3 cases verified
    2026-09-27: HANG (live child) -> WAITING_ON_CHILD suppressed; a working lane
    suppressed; a non-existent lane -> UNKNOWN and the alert passes through.
    """
    if SCREEN_CAP[0] <= 0:
        return True                    # out of budget this tick: alert, do not hide
    SCREEN_CAP[0] -= 1
    try:
        import subprocess
        # ⛔ THE PATH IS OVERRIDABLE SO THE SCREEN CAN BE STUBBED. tests/heartbeat-fleet-advance
        # drives this tick in a sandbox HOME, and a hard-coded absolute path escapes that sandbox:
        # on a box where the file exists the test would call the LIVE Jev screen (~30s, real cost)
        # and its verdict would decide the delivered body. The default is unchanged, so production
        # is unaffected. Separately: rc=2 from a MISSING file is read as "not stalled" here, which
        # inverts this docstring -- that fail-open defect is agent-infra#1797, not this change.
        r=subprocess.run(["/usr/bin/python3",
                          os.environ.get("LANE_CONFIRM") or "/Users/danielospina/.pi/agent/state/lane-confirm.py", label],
                         capture_output=True, text=True, timeout=900)
        return r.returncode == 0       # 0 == STALLED (lettered); anything else == suppress
    except Exception:
        return True                    # fail OPEN

alert=[];known=[];act=0;wait=0
import os,time,json
KF=os.path.expanduser("~/.pi/agent/state/lane-known.json")
try:
    K=json.load(open(KF))
except Exception:
    K={}
now=int(time.time())
for r in rows:
    v=r["verdict"]
    # ⛔ UNATTRIBUTED-WORKING IS PROVEN CPU PROGRESS (#1867): lane-status.py only mints it when a pi
    # in the lane OWN directory advanced CPU, so a lane carrying it is active -- not the old read of
    # neither-active-nor-waiting-child. It is absent from NURT/WEAK on purpose: it prescribes no
    # action, so it must not alert. Counting it keeps N_ACT truthful -- the same misreporting class
    # as the measured active=0 while 12 of 14 lanes were writing.
    if v in ("WORKING", "UNATTRIBUTED-WORKING"): act+=1
    elif v in ("WAITING-CHILD",): wait+=1
    if v in NURT:
        c=r.get("child") or {}
        age=(c.get("age") or 0)//60
        extra=f" child={age}m" if c else ""
        lbl=r["lane"]; key=lbl+"|"+v
        e=K.get(key) or {}
        # Suppress ONLY an UNCHANGED verdict already reported within the re-alert
        # window. A verdict that CHANGES is always a fresh alert, and a lane that
        # stays bad is fully re-reported after an hour, so nothing can hide.
        if e.get("last_alert") and now-e["last_alert"] < 3600:
            known.append(lbl+":"+v+extra)
        elif v in WEAK and not screened_stalled(lbl):
            # Screened as NOT stalled. Kept VISIBLE in the known bucket with the
            # reason, never dropped silently -- surface, do not gate.
            known.append(lbl+":"+v+extra+"[screened-ok]")
        else:
            alert.append(lbl+":"+v+extra)
        K[key]={"last_alert":now,"lane":lbl,"verdict":v}
K={k:v for k,v in K.items() if now-(v.get("last_alert") or 0) < 86400}
try:
    json.dump(K,open(KF,"w"))
except Exception:
    pass
# -- CAPACITY is not an ALERT, and must never be screened away by the stall check --
# An idle lane is the OPPOSITE of a stall, but it was being judged by the stall path:
# screened_stalled() answers "not stalled" for a genuinely idle lane, and the WEAK
# branch then buried it in the `known` bucket as [screened-ok]. So the one signal the
# orchestrator needs in order to keep the fleet busy -- FREE CAPACITY -- could never
# be reported. Measured 2026-09-29: the owner asked "there are idle lanes again"
# while this heartbeat said "0 needing attention"; 2b Extractor and 7 Instrumentation
# had been idle 15h and 13h and neither had ever appeared. Capacity is therefore its
# own field (never counted in N_ALERT -- it is an opportunity, not a fault) and it
# rides BOTH the alert message and the short pulse. The >=20m bound and the no-child
# requirement keep it off a lane that is merely BETWEEN steps, which is the measured
# false positive this classifier already records at 9m.
CAP_IDLE_MIN=20
# ⛔ A LANE WITH NO LIVE pi IS NOT FREE CAPACITY -- IT IS A DEAD PANE, AND THE CLAUSE THAT
# OFFERS IT ("hand each the next unheld item") ORDERS A SEND INTO A BARE LOGIN SHELL.
# MEASURED 2026-10-03 (post-cmux-restart): of the 3 lanes this clause offered as free --
# 2a Projection keys, 6 Durability core, W0 Test substrate -- TWO had no pi process at all;
# only 2a was genuinely idle. A dead pane still carries its LAST session file, so the
# staleness test reads it as idle-forever. The signal is `cmux sessions list` pid record:
# the PROCESS, not the pixels. One call, once, for the whole clause -- not per lane.
import subprocess as _sp
_live=set()
try:
    _o=_sp.run(["cmux","sessions","list"],capture_output=True,text=True,timeout=120).stdout
    for _ln in _o.splitlines():
        if "pid_exists=yes" in _ln and "workspace=" in _ln:
            _live.add(_ln.split("workspace=")[1].split()[0])
except Exception:
    _live=set()
# ⛔ RECORD-ONLY DEAD IS NOT ENOUGH. `pid_exists` is a property of a *pi session record*,
# not of the pane: a pane driven by anything else has no `pid_exists=yes` to find and was
# reported DEAD while actively running. MEASURED 2026-10-04: `DMeer - linkedin outreach`
# (5D17B799) read `pid_exists=no` and was reported "NO pi PROCESS IN THE PANE ... needs a
# RELAUNCH" for 95 minutes -- while its pane was live and running the Slack bridge. THE
# PRESCRIBED REMEDY IS DESTRUCTIVE (respawn-pane REPLACES the pane command), so a
# record-only read can kill a live lane. The pane settles it: a pi TUI always draws a
# footer carrying the context budget (`/300k`) and the model (`-flash • high`), and it
# draws it even when other output interleaves -- the DMeer footer was present, glued to the
# end of a bridge line. Confirm against the pane BEFORE condemning a lane.
def _pane_has_pi(uuid):
    """True if the pane itself shows a pi footer; None if it could not be read.
    Absence is NOT proof of death (a read failure must never condemn a lane).

    TIMEOUT 30s -> 10s (2026-10-05). MEASURED: the tick was killed at its bound on EVERY pass
    (`STALL orchestrator-heartbeat.sh exceeded 390s`), and this read is why. It runs once per lane
    with no live pid record -- 8 to 10 lanes -- so at a 30s timeout the pane section alone could
    consume ~300s of a 540s pass, starving the nudger down to its 20s floor. A pane read that has
    not answered in 10s is not going to, and the fallback is SAFE by construction: unknown falls
    through to cap_occ ("record-stale/unconfirmed"), which withholds rather than condemns."""
    try:
        _p=_sp.run(["cmux","read-screen","--workspace",uuid,"--lines","10"],
                   capture_output=True,text=True,timeout=10).stdout
    except Exception:
        return None
    if not _p.strip():
        return None
    _p=_p.replace("\x1b","")
    for _m in ("/300k","/1M","/2M","(auto)","\u2022 high","\u2022 medium","\u2022 low"):
        if _m in _p:
            return True
    return False

def _shell_visible(uuid):
    """True if the pane shows a shell prompt and nothing else -- the only state in which
    a relaunch is clearly safe. Unknown reads return None, never True."""
    try:
        _p=_sp.run(["cmux","read-screen","--workspace",uuid,"--lines","3"],
                   capture_output=True,text=True,timeout=30).stdout
    except Exception:
        return None
    if not _p.strip():
        return None
    return ("$ " in _p or "% " in _p) and "pi" not in _p

# ⛔ ALREADY-NUDGED LANES MUST NOT BE OFFERED AGAIN (owner ask, 2026-10-05). The nudger has
# already told this lane to continue, so it is working again; listing it invites the orchestrator
# to message it a SECOND time, which is the confusion the owner named. Source of truth is the
# SHARED marker dir, because BOTH nudgers claim there and turn-classify.py does NOT write
# turn-end.log: measured 2026-10-05, that log read "last NUDGE 01:40" while the markers held a
# SENT at 07:53. Matched by SESSION ID (marker and row both carry it), so no lane-name mapping is
# needed. Only SENT/QUEUED count -- a WITHHELD or failed nudge never reached the lane, so that
# lane MUST stay actionable. Age is the marker MTIME (the moment of the nudge); the `last` field
# is the lane staleness AT that moment, so it cannot be used as the nudge age.
NUDGE_SUPPRESS_S=3600
_nudged=set()
try:
    _nd=os.path.expanduser("~/.pi/agent/state/turn-end")
    for _f in os.listdir(_nd):
        if not _f.endswith(".json"): continue
        _p=os.path.join(_nd,_f)
        try:
            if time.time()-os.path.getmtime(_p) > NUDGE_SUPPRESS_S: continue
            _d=json.load(open(_p))
        except Exception:
            continue
        if str(_d.get("result") or "").upper().startswith(("SENT","QUEUED")):
            _nudged.add(_d.get("sid"))
except Exception:
    pass
cap=[];cap_wip=[];cap_busy=[];cap_dead=[];cap_occ=[]
# BOUND THE PANE PROBES PER TICK (2026-10-05). Even at a 10s timeout, an unbounded probe count
# scales with how many lanes lack a live record -- 8 to 10 today -- and that is what turned a
# 540s pass into a 567s one and killed the tick. A lane NOT probed this tick is simply unknown,
# which is not dead and not capacity: it lands in cap_occ as unconfirmed and is probed next tick.
# Same shape as SCREEN_CAP for the stall screens. Never trade a bounded unknown for an unbounded
# pass -- the probe is a courtesy read, the pass is the product.
PANE_PROBE_CAP=2
_pane_probes=0
for r in rows:
    if r["verdict"] not in ("DONE-IDLE","WIP-IDLE"): continue
    if (r.get("child") or {}): continue          # a child in flight is work, not idle
    # Already nudged this hour -> it is working again. COUNT it, do not offer it as an action.
    if r.get("sid") and r.get("sid") in _nudged:
        cap_busy.append("%s[%s]" % (r["lane"], (r.get("ws") or "").upper()[:8]))
        continue
    a=(r.get("stale_s") or 0)//60
    if a<CAP_IDLE_MIN: continue
    _ws=(r.get("ws") or r.get("workspace") or r.get("uuid") or "").upper()
    if _live and _ws and _ws not in _live:
        # No live pi RECORD. Ask the PANE before condemning -- and never let a read
        # failure condemn (None means unknown, and unknown is not dead).
        if _pane_probes < PANE_PROBE_CAP:
            _pane_probes += 1
            _has=_pane_has_pi(_ws)
        else:
            _has=None          # not probed this tick -> UNKNOWN, never read as dead or free
        if _has is True:
            # The pane is drawing pi. The RECORD is stale, not the lane. This is NOT free
            # capacity (no reliable staleness read) and NOT dead (relaunching would kill it).
            cap_occ.append("%s(%dm,record-stale)" % (r["lane"], a))
        elif _shell_visible(_ws) is True:
            cap_dead.append("%s(%dm)" % (r["lane"], a))   # bare shell -> relaunch is safe
        else:
            cap_occ.append("%s(%dm,unconfirmed)" % (r["lane"], a))
        continue
    # ⛔ WIP-IDLE AND DONE-IDLE ARE DIFFERENT ACTIONS AND MUST NEVER SHARE A LIST (2026-10-05).
    # The owner asked the beat for "which lanes need attention, and with what (wedged / idle-next /
    # idle-WIP)" and it COULD NOT ANSWER: the classifier already separates the two verdicts, and
    # this block then merged both into one FREE: list, so a lane holding uncommitted work mid-task
    # read identically to a lane waiting for its next item. They take OPPOSITE actions:
    #   DONE-IDLE -> hand it the next unheld item      (safe: it is not mid-task)
    #   WIP-IDLE  -> ONE instruction: continue          (it has unfinished work in hand)
    # Handing a WIP-IDLE lane a new task is the exact failure the FORBIDDEN column names.
    # ⛔ THE ACTIONABLE HANDLE (owner ask, 2026-10-05): a lane NAME cannot be actioned -- whoever
    # reads the beat still has to look the workspace up before they can send anything, and that
    # lookup is the step the owner asked to remove ("I want to see the cmux name ... I need this
    # to be very actionable"). Append the cmux workspace id, which is exactly what
    # `cmux_dispatch.py --workspace <id>` takes. `ws` is already on the row, so this costs NO
    # extra pane read. Empty brackets if unknown -- never a guess, because a wrong handle types
    # into a different lane pane. NO APOSTROPHE MAY APPEAR IN THIS PYTHON PAYLOAD: it is passed
    # single-quoted, so one apostrophe TERMINATES the string early and the rest of the payload is
    # parsed as bash -- measured 2026-10-05, this very comment broke the tick at
    # `line 490: syntax error near unexpected token ;;` and killed the rich beat. Same hazard as
    # the backtick rule for MSG below, and the same reason: phrase around possessives.
    # (Even a BALANCED pair is unsafe -- bash only tolerates it when the text between them happens
    # to parse, which is luck, not correctness.)
    # `pane-Working` MARKED, NOT DROPPED: it flags a lane whose PANE contradicts the mtime verdict
    # (the decision tree rule: the pane overrides). Measured on W0 2026-10-05 07:43 -- the row said
    # WIP-IDLE at 151m while the pane showed `Working` at 64.9% context, i.e. mid-turn. Dropping it
    # would hide a lane; marking it tells the caller to check before nudging.
    _h = (r.get("ws") or "").upper()[:8]
    _busy = ",pane-Working" if r.get("spinner") else ""
    # PROTECTED LANES ARE NEVER OFFERED AS WORK (2026-10-05). HANG is the owner park lane and
    # every DMeer lane is the owner own work. queue-dispatch.py has carried this denylist for
    # DISPATCHES, but the BEAT had no such filter -- so it kept offering `DMeer - linkedin
    # outreach` and `Design partners website` as IDLE targets to hand work to. An orchestrator
    # lane reads that line, and the only thing standing between it and a hand-off into the
    # owner own lane was the reader remembering an exclusion that lives in another file.
    # Named here too, at the point the list is built. Matched as a SUBSTRING because the
    # workspace title carries a suffix and a prefix (`DMeer - linkedin outreach`).
    # NO APOSTROPHE IN THIS PAYLOAD -- see the note above.
    if any(p in r["lane"] for p in ("DMeer", "DMer", "HANG")):
        continue
    (cap_wip if r["verdict"] == "WIP-IDLE" else cap).append(
        "%s(%dm%s)[%s]" % (r["lane"], a, _busy, _h))
cap.sort(); cap_wip.sort(); cap_busy.sort(); cap_dead.sort(); cap_occ.sort()
# DEAD PANES ARE A SEPARATE SIGNAL, NEVER CAPACITY. Emitted as its own eval line so the
# shell can surface it; a dead lane needs a RELAUNCH, not a dispatch.
if cap_dead:
    print("DEAD=\"" + " | ".join(cap_dead) + "\";N_DEAD=%d" % len(cap_dead))
else:
    print("DEAD=\"\";N_DEAD=0")
# OCCUPIED: no live pid record, but the pane is NOT a bare shell -- so the lane may be
# alive with a stale record. NEVER prescribe a relaunch on this: a read that cannot see
# a bare shell cannot see that a relaunch is safe.
print("OCC=\"" + " | ".join(cap_occ) + "\";N_OCC=%d" % len(cap_occ))
print("ALERTS=\"" + " | ".join(alert).replace("\"", "") + "\";KNOWN=\"" + " | ".join(known).replace("\"", "") + "\";N_ACT=%d;N_WAIT=%d;N_TOTAL=%d;N_ALERT=%d;N_KNOWN=%d;CAP=\"%s\";N_CAP=%d;CAPW=\"%s\";N_CAPW=%d;CAPB=\"%s\";N_CAPB=%d" % (act, wait, len(rows), len(alert), len(known), " | ".join(cap), len(cap), " | ".join(cap_wip), len(cap_wip), " | ".join(cap_busy), len(cap_busy)))
' 2>/dev/null)
# PUBLISH THE SNAPSHOT ONLY WHEN THE SCAN COMPLETED, AND NEVER IN PLACE. `tee` truncates its output
# the instant the pipeline starts, so writing the FINAL name directly left the classifier input EMPTY
# for the whole ~250-390s scan, and a tick killed inside the scan blanked the PREVIOUS pass's snapshot
# too. A .tmp plus a VALIDATED rename means a killed or truncated scan leaves the last good snapshot
# exactly where it was -- the rename is gated on the file actually parsing, because a half-written
# JSON published under the final name would fail lane-actions.py on every pass for 15 minutes.
if /usr/bin/python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$STATE/lane-status.last.json.tmp" 2>/dev/null; then
  mv -f "$STATE/lane-status.last.json.tmp" "$STATE/lane-status.last.json"
else
  rm -f "$STATE/lane-status.last.json.tmp"
fi

if [ -z "$EV" ]; then
  log "NOTE lane-status produced no output"
  N_ACT=0; N_WAIT=0; N_TOTAL=0; N_ALERT=0; N_KNOWN=0; ALERTS=""; KNOWN=""; CAP=""; N_CAP=0; DEAD=""; N_DEAD=0; OCC=""; N_OCC=0
else
  eval "$EV"
  log "VERDICTS known=$N_KNOWN: $KNOWN"
  # A dead lane is logged on EVERY tick, including the ones that exit early below: it is a
  # RELAUNCH queue, and it must be visible in the log even when nothing else is actionable.
  [ "${N_DEAD:-0}" -gt 0 ] && log "DEADLANES no-pi-in-pane count=$N_DEAD: $DEAD"
  # OCCUPIED: no live pid record, but the pane is NOT a bare shell. Never a relaunch --
  # the lane may be alive with a stale record (DMeer measured 2026-10-04).
  [ "${N_OCC:-0}" -gt 0 ] && log "OCCUPIED no-live-record-but-pane-not-bare count=$N_OCC: $OCC"
fi
# -- PERSIST THE LANE RECAP *IMMEDIATELY*, BEFORE THE EXPENSIVE STEPS (ordering fix, 2026-10-05) --
# MEASURED DEFECT: the rich message below (line ~667) NEVER LEFT THE BOX. Every pass was killed at
# its 540s budget by the slow steps that sit BELOW this point -- `turn-end.py exceeded 28s` and
# `queue-dispatch.py exceeded 236s -> rc=143` -- so `cmux send` was never reached, and the owner
# received ONLY the cheap cadence FLOOR (cadence-nudge.sh). The floor is deliberately offline and
# can therefore only carry what is already on disk. Write it HERE, first, so the floor has
# something true to say. This is the same ordering lesson cadence-nudge.sh documents for itself:
# "ask whether a message is DUE before doing anything expensive."
# ⛔ The floor is also the ONLY sender that survives, so this file is the floor's sole lane input.
# Keep it to ONE cheap write -- no subprocesses, no network, nothing that can stall.
{
  printf 'ts=%s\n' "$(date '+%H:%M')"
  printf 'fleet=%sactive %swaiting-child %salert of %s\n' \
    "${N_ACT:-0}" "${N_WAIT:-0}" "${N_ALERT:-0}" "${N_TOTAL:-0}"
  printf 'alerts=%s\n' "${ALERTS:-}"
  printf 'rich=0\n'
  printf 'busy=%s\n' "${CAPB:-}"
  printf 'wip=%s\n' "${CAPW:-}"
  printf 'free=%s\n' "${CAP:-}"
} > "$STATE/lane-recap.last" 2>/dev/null
# ⛔ THE RATE-LIMIT EXIT NOW SITS BELOW THE TRIAGE (2026-10-05) -- IT USED TO SIT HERE, ABOVE IT.
# Measured consequence: the triage therefore ran ONLY on the rare pass that was not rate-limited,
# so the fine action classes (CONTINUE / BLOCKED_HUMAN) were almost never computed and the floor
# could not publish them -- the beat could say "idle 142m" but never "mid-task, say continue".
# The rule this file already states for the classification applies to the triage too: THE RATE
# LIMIT SUPPRESSES THE SEND, NEVER THE CLASSIFICATION. The triage is bounded (~1s) and fail-open
# (`|| log`), so it cannot become the kind of stall the early recap write was moved away from.
# -- JEV TRIAGE: 'idle' is not one state, and the mechanical proxy cannot tell them apart ----
# Measured 2026-09-30: lane-status.py called 15 of 26 lanes DONE-IDLE while the panes showed many
# mid-work (the same failure resolve_session documents: a stale id makes a working lane read
# DONE-IDLE). So the mechanical pass NARROWS the field and JEV reading each lane's OWN LAST WORDS
# decides what the idle MEANS -- one call for the whole idle set, ~$0.006, ~1s.
#
# The four idle states need four DIFFERENT actions, which is why they are reported separately:
#   CONTINUE          mid-task, names a next step   -> tell it to continue (NOT a new task)
#   BLOCKED_HUMAN     needs an owner decision       -> route to the owner
#   BLOCKED_EXTERNAL  waiting on CI/rail/queue      -> report, never nudge
#   DONE_READY        finished, nothing held        -> hand it the next item
#
# ⛔ THE PANE OVERRIDES. JEV judges the last COMPLETED turn, so a lane inside a long tool call looks
# DONE_READY to BOTH classifiers. Measured 2026-09-30: W0 and A read DONE_READY(0.94/0.93) minutes
# after being dispatched new work and verified WORKING by pane. lane-triage.py therefore drops any
# lane whose pane shows a live spinner -- only the pane answers 'busy right now', and a wrong
# DONE_READY re-tasks a lane that is mid-work.
# FAIL-OPEN: any failure leaves the mechanical verdicts untouched.
TRIAGE_READY=""; TRIAGE_CONTINUE=""; TRIAGE_HUMAN=""; TRIAGE_EXT=""; TRIAGE_STALL=""; TRIAGE_HELD=""; N_TRIAGE=0
TRV=$(/usr/bin/python3 "$HOME/.pi/agent/state/lane-triage.py" 2>/dev/null) && eval "$TRV" || log "NOTE triage unavailable -- mechanical verdicts stand"
if [ "${N_TRIAGE:-0}" -gt 0 ]; then
  # JEV's DONE_READY supersedes the stale-mtime CAPACITY list; the screened-out lanes keep theirs.
  CAP="$TRIAGE_READY"
  # Count entries properly. The previous form ran two printf's into a command substitution and
  # took `tail -1`, which always selected the literal 0 -- so N_CAP was permanently 0 and the
  # CAPACITY clause could never fire even when the triage found free lanes. Measured 2026-09-30:
  # log read `TRIAGE ready=[5 lanes]` on the SAME tick as `cap=0`. Count non-empty fields.
  N_CAP=$(printf '%s' "$TRIAGE_READY" | tr '|' '\n' | grep -c '[^[:space:]]' || true)
  case "$N_CAP" in ''|*[!0-9]*) N_CAP=0 ;; esac
  [ -z "$TRIAGE_READY" ] && N_CAP=0
  # ⛔ WIP BEATS READY -- RECONCILE THE TWO LISTS (2026-10-05). CAP is the JEV triage's list;
  # CAPW is the MECHANICAL WIP-IDLE list. Nothing reconciled them, so a lane the triage called
  # DONE_READY while it still held unfinished work appeared in BOTH, and the beat told the reader
  # to say CONTINUE and to hand it a new task IN THE SAME MESSAGE. The decision tree settles the
  # conflict: a WIP lane is mid-task, and re-tasking it is the FORBIDDEN column, so WIP WINS.
  # Pure bash on purpose: the CAPACITY DROP filter below documents that a python+heredoc filter
  # at this exact spot silently reassigned CAP to nothing while still logging that it had worked.
  if [ -n "${CAPW:-}" ] && [ -n "$CAP" ]; then
    _WIPN=$(printf '%s' "$CAPW" | tr '|' '\n' | sed -E 's/\([0-9]+m\)[[:space:]]*$//; s/^[[:space:]]+//; s/[[:space:]]+$//' | grep -v '^$')
    _NEWCAP2=""; _oldIFS2="$IFS"; IFS='
'
    for _e in $(printf '%s' "$CAP" | tr '|' '\n'); do
      _nm=$(printf '%s' "$_e" | sed -E 's/\([0-9.]+m?\)[[:space:]]*$//; s/^[[:space:]]+//; s/[[:space:]]+$//')
      [ -z "$_nm" ] && continue
      if grep -qxF "$_nm" <<<"$_WIPN"; then
        log "DO-DEDUPE: $_nm is WIP-IDLE (unfinished work) -- dropped from READY; CONTINUE it, never hand it a new task"
      else
        _NEWCAP2="${_NEWCAP2}${_NEWCAP2:+ | }$(printf '%s' "$_e" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
      fi
    done
    IFS="$_oldIFS2"
    CAP="$_NEWCAP2"
    N_CAP=$(printf '%s' "$CAP" | tr '|' '\n' | grep -c '[^[:space:]]' || true)
    case "$N_CAP" in ''|*[!0-9]*) N_CAP=0 ;; esac
    [ -z "${CAP// /}" ] && N_CAP=0
  fi
  # THE REVERSE DIRECTION OF THE SAME RECONCILIATION (2026-10-05). A lane the triage placed in an
  # ACTION class (continue / human / ext / stall) must not ALSO sit in the mechanical WIP list, or
  # the beat prints TWO instructions for one lane -- "say CONTINUE" beside "route it to the owner".
  # The triage read the lane's actual last words, so its verdict OUTRANKS the mechanical WIP-IDLE:
  # a lane waiting on the owner cannot usefully be told to continue. (The forward direction -- WIP
  # dropped out of READY -- is the block above.) Lanes the triage did NOT classify keep their WIP
  # verdict, which is why the W0 case still reports correctly.
  if [ -n "${CAPW:-}" ]; then
    _TRIAGED=$(printf '%s | %s | %s | %s' "${TRIAGE_CONTINUE:-}" "${TRIAGE_HUMAN:-}" "${TRIAGE_EXT:-}" "${TRIAGE_STALL:-}" \
      | tr '|' '\n' | sed -E 's/\([0-9.]+\)[[:space:]]*$//; s/^[[:space:]]+//; s/[[:space:]]+$//' | grep -v '^$')
    if [ -n "$_TRIAGED" ]; then
      _NEWWIP=""; _oldIFS3="$IFS"; IFS='
'
      for _e in $(printf '%s' "$CAPW" | tr '|' '\n'); do
        _nm=$(printf '%s' "$_e" | sed -E 's/\([0-9.]+m?\)[[:space:]]*$//; s/^[[:space:]]+//; s/[[:space:]]+$//')
        [ -z "$_nm" ] && continue
        if grep -qxF "$_nm" <<<"$_TRIAGED"; then
          log "DO-DEDUPE: $_nm carries a triage class -- dropped from WIP (action class outranks mechanical)"
        else
          _NEWWIP="${_NEWWIP}${_NEWWIP:+ | }$(printf '%s' "$_e" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
        fi
      done
      IFS="$_oldIFS3"
      CAPW="$_NEWWIP"
    fi
  fi
  log "TRIAGE ready=[$TRIAGE_READY] continue=[$TRIAGE_CONTINUE] human=[$TRIAGE_HUMAN] ext=[$TRIAGE_EXT] stalled=[$TRIAGE_STALL] held_spinning=[$TRIAGE_HELD]"
  # ⛔ DEAD OVERRIDES FREE (2026-10-03). Measured: `6 Durability core` was offered as FREE
  # CAPACITY (idle 0.99) on the SAME tick that DEADLANES listed it `no-pi-in-pane (32m)` --
  # because N_CAP comes from JEV triage and DEAD from a separate pid_exists read, and nothing
  # reconciled them. Dispatching to that lane types into a BARE LOGIN SHELL AND RUNS IT.
  # CAPACITY is an invitation to send, so it must be filtered by the same liveness test that
  # condemns the lane -- not annotated beside it, where a reader can pick the wrong half.
  if [ "${N_DEAD:-0}" -gt 0 ] && [ -n "$CAP" ]; then
    # Pure bash on purpose: the first cut used a python -c + `case` over a heredoc and the CAP::
    # line never reached _NEWCAP -- DROP fired twice, CAP was reassigned to nothing, and the
    # heartbeat went on publishing all four lanes. A filter that logs its verdict and then does
    # not apply it is worse than no filter: it reads as working in the log.
    _DEADN=$(printf '%s' "$DEAD" | tr '|' '\n' | sed -E 's/\([0-9]+m\)[[:space:]]*$//; s/^[[:space:]]+//; s/[[:space:]]+$//' | grep -v '^$')
    _NEWCAP=""; _oldIFS="$IFS"; IFS='
'
    for _e in $(printf '%s' "$CAP" | tr '|' '\n'); do
      _nm=$(printf '%s' "$_e" | sed -E 's/\([0-9.]+\)[[:space:]]*$//; s/^[[:space:]]+//; s/[[:space:]]+$//')
      [ -z "$_nm" ] && continue
      if grep -qxF "$_nm" <<<"$_DEADN"; then
        log "CAPACITY DROP dead lane offered as free: $_nm (no live pi) -- NOT dispatchable"
      else
        _NEWCAP="${_NEWCAP}${_NEWCAP:+ | }$(printf '%s' "$_e" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
      fi
    done
    IFS="$_oldIFS"
    CAP="$_NEWCAP"
    N_CAP=$(printf '%s' "$CAP" | tr '|' '\n' | grep -c '[^[:space:]]' || true)
    case "$N_CAP" in ''|*[!0-9]*) N_CAP=0 ;; esac
    [ -z "${CAP// /}" ] && N_CAP=0
  fi
fi
  # ⛔ BUSY BEATS EVERYTHING -- AND IT MUST RUN LAST (2026-10-05). A lane the nudger already told
  # to continue is WORKING, so it must vanish from EVERY action list, not just the mechanical one.
  # Measured: the first cut filtered only cap/cap_wip, and the JEV triage then re-added the SAME
  # lane to CAP via TRIAGE_READY -- so one beat published `busy=2c Pack compile[...]` AND
  # `free=2c Pack compile(...)` together: one clause saying "do NOT message", the very next saying
  # "hand it work". Placing this filter AFTER the triage is what makes it cover every producer.
  # Same reconciliation family as WIP-beats-READY above; this one is simply last, so it wins.
  if [ -n "${CAPB:-}" ]; then
    _BUSYN=$(printf '%s' "$CAPB" | tr '|' '\n' | sed -E 's/\[[0-9A-Fa-f]*\][[:space:]]*$//; s/^\([0-9.]+m?\)[[:space:]]*$//; s/^[[:space:]]+//; s/[[:space:]]+$//' | grep -v '^$')
    for _v in CAP CAPW TRIAGE_CONTINUE TRIAGE_HUMAN TRIAGE_EXT TRIAGE_STALL; do
      eval "_cur=\"\${$_v:-}\""
      [ -z "$_cur" ] && continue
      _keep=""; _oldIFS4="$IFS"; IFS='
'
      for _e in $(printf '%s' "$_cur" | tr '|' '\n'); do
        _nm=$(printf '%s' "$_e" | sed -E 's/\[[0-9A-Fa-f]*\][[:space:]]*$//; s/\([0-9.]+m?\)[[:space:]]*$//; s/^[[:space:]]+//; s/[[:space:]]+$//')
        [ -z "$_nm" ] && continue
        if grep -qxF "$_nm" <<<"$_BUSYN"; then
          log "DO-DEDUPE: $_nm is BUSY (already nudged) -- dropped from $_v"
        else
          _keep="${_keep}${_keep:+ | }$(printf '%s' "$_e" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
        fi
      done
      IFS="$_oldIFS4"
      eval "$_v=\"\$_keep\""
    done
    N_CAP=$(printf '%s' "${CAP:-}" | tr '|' '\n' | grep -c '[^[:space:]]' || true)
    case "$N_CAP" in ''|*[!0-9]*) N_CAP=0 ;; esac
    [ -z "${CAP// /}" ] && N_CAP=0
  fi
# ⛔ SECOND, ENRICHED RECAP (2026-10-05). The early write above is the SAFETY NET -- it guarantees
# the floor has something true to say even if this pass is killed before reaching this line. THIS
# write only ever REPLACES that fallback with more truth, so keeping both is strictly safe. It
# adds what only the triage can know, which is what lets the floor name the finer ACTION class:
#   continue -> say CONTINUE          (mid-task; handing it a new task is the FORBIDDEN column)
#   human    -> route it to the owner  (an owner decision, NEVER the orchestrator's)
#   ext      -> report only            (waiting on CI/rail/queue; never nudge)
#   stall    -> investigate            (check the pane + CPU time BEFORE acting)
{
  printf 'ts=%s\n' "$(date '+%H:%M')"
  printf 'fleet=%sactive %swaiting-child %salert of %s\n' \
    "${N_ACT:-0}" "${N_WAIT:-0}" "${N_ALERT:-0}" "${N_TOTAL:-0}"
  printf 'alerts=%s\n' "${ALERTS:-}"
  printf 'continue=%s\n' "${TRIAGE_CONTINUE:-}"
  printf 'human=%s\n' "${TRIAGE_HUMAN:-}"
  printf 'ext=%s\n' "${TRIAGE_EXT:-}"
  printf 'stall=%s\n' "${TRIAGE_STALL:-}"
  printf 'busy=%s\n' "${CAPB:-}"
  printf 'rich=1\n'
  printf 'wip=%s\n' "${CAPW:-}"
  printf 'free=%s\n' "${CAP:-}"
} > "$STATE/lane-recap.last" 2>/dev/null
# NOW honour the rate limit: the recap is persisted (twice), so stop before the expensive steps and
# the send. A question that cleared or failed the gate still gets through: it is one-shot and
# time-sensitive.
if [ "$RL" = "1" ] && [ "${N_ASK:-0}" -eq 0 ]; then exit 0; fi
if [ "$RL" = "1" ]; then N_ALERT=0; ALERTS=""; N_KNOWN=0; KNOWN=""; fi
# -- THE PULSE: silence is not the same as health ------------------------------
# Design rule 1 forbids an unconditional wake-up, and that is right. But it was
# implemented as "speak only when something is ACTIONABLE", and the measured result is
# the orchestrator hearing NOTHING for long stretches: the owner asked "is it firing?
# I haven't seen a heartbeat in a while" while the loop ticked every ~5 min and was
# doing nothing wrong. A reminder nobody reads cannot shape behaviour, and the standing
# ROLE/MAP text only reached the pane on alert ticks, i.e. rarely.
# So: keep no-flood, add a bounded pulse. Nothing actionable AND the last message is
# older than PULSE_MIN -> send the short form anyway. Any alert still fires at once.
# ⛔ N_DEAD WAS A REGRESSION HERE (2026-10-03) -- DO NOT PUT IT BACK IN THIS GATE.
# A dead pane is not an ALERT about a lane, which is why it was excluded here -- but the effect
# was the OPPOSITE of the intent: this gate is the ONLY place PULSE_FIRED is set, so excluding
# N_DEAD routed a dead fleet past the pulse and straight into the IDLE GUARD below, where a
# mid-turn orchestrator (and the pane matcher is a literal `grep -q Working`) is always withheld.
# A fleet with 5 dead lanes therefore sent NOTHING and never pulsed: last real message 13:09:30,
# every tick after it SKIP, for 163m. That is the owner's "no heartbeat since...?" exactly.
# Dead lanes keep their own always-on log line (line ~351, every tick) for visibility; they do not
# need to silence the pulse as well.
if [ "${N_ALERT:-0}" -eq 0 ] && [ "$N_ASK" -eq 0 ] && [ "$MQ_ALERT" -eq 0 ] && [ "${OBJ_ALERT:-0}" -eq 0 ]; then
  PGAP="${GAP:-9999}"
  case "$PGAP" in ""|*[!0-9]*) PGAP=9999 ;; esac
  if [ "$PGAP" -lt "$PULSE_MIN" ]; then
    log "OK active=$N_ACT waiting=$N_WAIT cap=${N_CAP:-0} of $N_TOTAL queue=[${QUEUE#QUEUE: }] ${OBJ} no action"; exit 0
  fi
  log "PULSE (nothing actionable; ${PGAP}m since the last message)"
  FORCE_SHORT=1   # a pulse carries no alert, so the verdict legend has nothing to help read
  # ⛔ THE PULSE MUST SURVIVE THE IDLE GUARD (see the IDLE GUARD block below). Without this
  # flag the pulse is computed, logged, and then THROWN AWAY whenever the orchestrator is
  # mid-turn -- which is exactly the busy case the owner asks about.
  # MEASURED 2026-10-01 21:24: the tick logged "PULSE (nothing actionable; 37m since the last
  # message)" and four seconds later "SKIP orchestrator WORKING (mid-turn)". So the owner saw
  # silence for 37 minutes while the loop was healthy AND the pulse was firing. This is the
  # second time the owner has raised it (the first produced the pulse itself), so the bug was
  # never 'no pulse' -- it was 'pulse suppressed'.
  # A pulse is rate-limited BY CONSTRUCTION: it only fires after PULSE_MIN minutes of silence,
  # so letting it through the guard cannot flood the composer.
  PULSE_FIRED=1
fi
if [ "$DRY" = "1" ]; then
  printf 'DRY-RUN  active=%s waiting=%s alerts=%s total=%s ask=%s mq_alert=%s\n  QUEUE: %s\n  ALERTS: %s\n  ASK: %s\n' \
    "$N_ACT" "$N_WAIT" "$N_ALERT" "$N_TOTAL" "$ASK_EV" "$MQ_ALERT" "$QUEUE" "$ALERTS" "$ASK_EV"
  exit 0
fi
# ⛔ NO BACKTICKS IN ANY MSG TEXT. MSG is a DOUBLE-QUOTED assignment, so bash
# command-substitutes anything in backticks AT ASSIGNMENT TIME -- the text silently
# disappears and MSG is sent with a hole in it. Measured 2026-09-25: the WEDGED
# legend read "...measured 2026-09-25:  read WEDGED while mid-task..." with the lane
# name gone, because `W0 Test substrate` was executed as a command that does not
# exist. The file on disk still LOOKS right, which is what makes it hard to spot.
# Same hazard as the commit-message rule in AGENTS.md. Quote plainly, never `like this`.
# -- CAPACITY clause: free lanes are an OPPORTUNITY, not an alert --------------
# Kept separate from N_ALERT on purpose, so surfacing idle capacity can never
# inflate the attention count or be silenced by alert rate-limiting.
# ⛔ CAPTEXT MUST BE INITIALISED OUTSIDE THE BRANCH. It was not, so the DEAD-LANES clause
# below (which APPENDS to it) hit an unbound variable under `set -u` and KILLED THE TICK
# whenever N_DEAD>0 and N_CAP==0 -- i.e. a fleet with dead lanes and no idle ones got NO
# HEARTBEAT AT ALL, which is precisely when it most needed one. Caught 2026-10-03 14:39:44
# as `line 442: CAPTEXT: unbound var`. This is the same silent-death class as the 11h30m
# outage documented in heartbeat-loop.sh: an added clause must never be able to abort the
# whole message. Initialise, then append.
CAPTEXT=""
if [ "${N_CAP:-0}" -gt 0 ]; then
  CAPTEXT="⛔ CAPACITY: ${N_CAP} lane(s) idle >=20m with NO child in flight — free: ${CAP}. Do not leave them waiting: hand each the next unheld item for its lane, reading its last turn first (a lane whose child is still writing is NOT idle)."
fi
# DEAD PANES: NOT CAPACITY, AND NOT A DISPATCH. A dead lane still carries its LAST session
# file, so the staleness test reads it as idle forever -- which is how the CAPACITY clause
# came to offer two dead panes as "free" on 2026-10-03 and order a send into a bare login
# shell. They need a RELAUNCH; the exact mechanism is in ORCHESTRATION-BOARD §72.
if [ "${N_DEAD:-0}" -gt 0 ]; then
  CAPTEXT="${CAPTEXT} ⛔ DEAD LANES — CONFIRMED BARE SHELL, no pi in the pane: ${DEAD}. These are NOT free capacity and are NOT dispatchable: a send into one would be typed into a BARE LOGIN SHELL and executed. They need a RELAUNCH (recover-fleet / relaunch, board §72), not an item."
fi
# ⛔ OCCUPIED IS NOT DEAD, AND MUST NEVER CARRY THE RELAUNCH REMEDY. Measured 2026-10-04:
# `DMeer - linkedin outreach` read `pid_exists=no` and was reported "NO pi PROCESS IN THE
# PANE ... needs a RELAUNCH" for 95 minutes while its pane was live and running the Slack
# bridge -- with its pi footer still drawn, glued to the end of a bridge line. respawn-pane
# REPLACES the pane command, so acting on that would have killed the lane. A lane whose
# RECORD is stale is a records problem, not a work problem.
if [ "${N_OCC:-0}" -gt 0 ]; then
  CAPTEXT="${CAPTEXT} ⚠️ NO LIVE pi RECORD, but the pane is NOT a bare shell: ${OCC}. This is UNKNOWN, not dead — the record is stale, the lane may well be working. Do NOT relaunch and do NOT dispatch: a send could land mid-turn. Confirm the pane first (cmux read-screen --workspace <uuid> --lines 10). The earlier wording here prescribed a RELAUNCH on a record-only read, and it was wrong."
fi
MSG="[HEARTBEAT ${TS}] fleet ${N_ACT}active/${N_WAIT}waiting-child of ${N_TOTAL}, ${N_ALERT} needing attention. ${DELIV} ${QUEUE} ${OBJ} ACT: ${ALERTS} — ${N_KNOWN} further lane(s) carry an UNCHANGED verdict already reported within the last hour; they are listed in the log as VERDICTS known= and are NOT repeated here. Only a CHANGED verdict, or one unreported for over an hour, appears above. CHILD-STUCK = the child's OWN transcript exists and has gone quiet >15m; this is a real candidate, check it. ⚠️ MEASURED TWICE AS A FALSE POSITIVE on 2026-09-27 — Merigng's 119m child was the merge rail (a legitimate 35-65m job), and 1 Capture's 37m stuck child had children writing at 0.0m/0.1m/3.9m when checked. A child working in a NESTED worktree does not update the transcript this check reads. CONFIRM BEFORE ACTING: search recently-modified session files for the issue number (see ORCHESTRATION-BOARD §47). Never reap on this verdict alone. CHILD-OVERDUE = past the 20m bound with NO child transcript found, so the child is UNVERIFIABLE from here -- unknown, not evidence of stuck. WEDGED = no session write for >10m with a spinner. That is NOT proof of a stall: a long tool call writes nothing until it returns, so a lane running a test suite looks identical. Two flat samples do NOT distinguish them -- check the pane and the process CPU before touching it (measured 2026-09-25: the W0 Test substrate lane read WEDGED while mid-task on a box at load 134-240). UNBOUND = the pane advertises no session binding, so this lane's session cannot be attributed from here -- it may be alive, do NOT read it as dead. EMPTY = the pane has no session. DONE-IDLE/WIP-IDLE = no session write for >=9m, no spinner and a completed last turn. ⛔ DO NOT DISPATCH ON THIS VERDICT ALONE: it is a WEAK signal that a lane merely BETWEEN STEPS also produces -- its growth test compares two samples seconds apart, and a lane running a long tool call writes nothing until it returns. MEASURED 2026-09-27 04:15: this classifier read active=0 with 6 DONE-IDLE while 12 of 14 lanes were demonstrably writing (2a 2.8m, 6 Durability 20.8m, 7 3.6m, A 19.9m). Read the pane (a spinner means working) or the session-file mtime BEFORE dispatching, or you will duplicate live work. A lane whose child is still writing is NOT idle -- do NOT message it. Treat every verdict here as an ALERT to investigate, never as a work list."

# -- the role boundary: ORCHESTRATE, and route decisions to the owner --------
# Both halves were missing. The lane nudges already route a LANE's question through
# the protocol, but nothing stated the ORCHESTRATOR's own boundary -- and the
# orchestrator is the session most likely to decide on the owner's behalf, because it
# holds the most context and carries the most apparent authority. Measured 2026-09-29:
# the orchestrator asserted a decided option set ("the graph's ranking put X first")
# when the graph had only RANKED the options for the owner to pick between.
# NO BACKTICKS in this text -- MSG is a double-quoted assignment, so backticks are
# command-substituted at assignment time and silently vanish (see the warning below).
MSG="${MSG} ⛔ ROLE: orchestrate, don't implement — dispatch work and verify the artifact, never do a lane's work here. Owner decisions are never yours: they go through the AGENTS.md protocol to the owner-decision label (ask-owner.py). "

# -- ⛔ FLEET ADVANCE: the standing order the beat had NO half of (owner, 2026-10-18) ---------
# MEASURED BEFORE THIS CLAUSE EXISTED: 12 open non-draft PRs, 8 of them closing a P0/P1 issue,
# ALL 8 blocked, and merged_24h unmoved for over an hour -- while every beat in that window read
# as a healthy fleet. The beat carried ROLE, MAP and PRIORITY (how to behave) and no instruction
# to ADVANCE anything, so a lane could read it, write a paragraph about load and lanes, dispatch
# nothing, and nothing on the line said that was wrong.
# WHY HERE AND NOT AGENTS.md: AGENTS.md holds the standing rules; the beat holds what to do with
# the NEXT TEN MINUTES. The failure was never ignorance of the rules -- it was a beat that read
# like a finished report. HYPOTHESIS (labelled as one on purpose: it is not measured): a rule in a
# document does not change what a report triggers, while an order IN the report does. It sits beside
# ROLE/MAP/PRIORITY because that is the block an agent already reads, and whether it changes lane
# behaviour is the one thing this file cannot measure -- merged_24h is where that shows up.
# ⛔ UNCONDITIONAL, AND IT MUST RIDE THE SHORT FORM TOO (the SHORT FORM block below rebuilds MSG): a
# quiet beat is exactly when the order is needed, and the short form is what a quiet beat receives --
# it REBUILDS MSG from scratch, so an order that lives only in the FULL body is discarded on every
# quiet tick.
# ⛔ ONE ORDER, TWO LENGTHS -- AND THE ORDER ITSELF IS NEVER REPHRASED. FA1..FA4 are the three
# instructions the owner gave plus the closing line, defined ONCE and embedded VERBATIM in both body
# literals; only the (1)(2)(3) numbering and the one elaboration sentence below belong to the alert
# body alone. tests/heartbeat-fleet-advance/run.sh pins each of these sentences in the DELIVERED body
# of SIXTEEN fleet states (no lanes / one working lane / working+waiting-child / a 6-lane fleet, the
# ordinary size / a 12-lane fleet / a 26-lane fleet at the top of the range this file records / idle
# capacity / alert+capacity / dead panes /
# no live pi record / a routed question / an alerting lane / a queue bottleneck / an objective at risk /
# a WARM fleet with a verdict already reported inside the hour / a fleet where the SEND ITSELF FAILS, so
# the recovery branch runs), pins both composed literals to their EXACT documented text (so a reworded
# or padded variant is red), and pins each delivered body to its whole GOLDEN BODY
# (tests/heartbeat-fleet-advance/golden/<state>.txt, byte for byte, so a clause added, removed or
# REPLACED anywhere in a beat is red).
# (Reviewer-driven: round after round of "delete this phrase, suite stays green" mutants, each
# pointing at a different word, were all one defect -- a marker per phrase cannot be exhaustive; a
# shared sentence, a fixed state matrix and an exact delivered body can.)
# ⛔ WHY THE ORDER IS EMBEDDED IN THE LITERALS RATHER THAN APPENDED. Two review rounds measured
# zero-net-line edits that dropped it anyway: wrap an append in an `if` (no count changes, no visited
# state changes) or rewrite the message on its way out (`${MSG:0:400}`, `${MSG/.../}`). So the ORDER
# lives INSIDE the two literals -- there is no append OF THE ORDER left to wrap (the MSG appends that
# remain add other clauses) -- and the suite pins the EGRESS: the two send statements (the message and
# the recovery newline) in their exact shipped forms and positions, the message send required to sit at
# the same block depth as the last composition statement (no balanced wrapper above it), the token
# `send` confined to six known lines of which exactly two spawn cmux, the block depth at the send and
# at the last MSG= statement each pinned to its shipped constant, the block-keyword lines hashed, the
# executable-line count pinned, and -- at RUN TIME, per state -- how many sends the tick actually made
# (the stub counts invocations, so a third egress is red however it is spelled or branched). No slicing or substitution of MSG anywhere here. (Also: an append below
# the short-form rebuild was one deleted line away from losing the order on every quiet tick, which is
# how #1991 was originally mis-fixed.)
# ⛔ THE ONE OWNER-ORDERED SENTENCE THAT IS ALERT-ONLY IS DELIBERATE: order (2)'s "not described in
# a paragraph about load" rides FLEETADV alone. FA2 keeps the normative half ("USE THE CAPACITY, DO
# NOT REPORT IT"), and the short body is where the pulse must stay short. Adding that elaborating
# sentence to the quiet beat is not a ceiling question -- the suite asserts the elaboration ABSENT
# from the quiet body (it is what makes the two bodies distinguishable), so that edit is red until
# the assertion is changed deliberately.
# MEASURED 2026-10-18, IN BYTES (the suite pins LC_ALL=C, and the order carries the characters that
# differ between bytes and chars -- the em dash and the ⛔): the SHORT rendering is 624 and the alert
# body's clause 713, on a base pulse of 980 -- so the order is ~40% of the PLAIN quiet beat and the
# LARGEST clause on it (ROLE 199, MAP 125, PRIORITY 279; the legend-suppression note is 215 bytes
# with the log name expanded). Delivered bodies are pinned by GOLDEN, not by this comment -- the
# figures here are a reading aid and drift; `tests/heartbeat-fleet-advance/golden/*.txt` is the truth.
# ⛔ WHAT THE SUITE ENFORCES, AND WHAT IT DOES NOT. It enforces: the exact delivered text of each of
# the fifteen states (byte for byte against a golden), the four sentences exactly once each, the
# framing ("an ORDER, not a report") in the delivered text, the order LAST in a plain pulse,
# immediately BEFORE the CAPACITY clause in the capacity states, the embedded-not-appended shape, the
# two pinned sends (form, position, block depth, and the EXECUTED count per state), and a coarse lint
# on statements touching the order or MSG. It does NOT enforce: the tick's REACHABILITY of the send
# under an input no state visits, WHICH PANE the beat is typed into, text outside every clause the
# beats carry, or a background job that outlives the tick by more than the recorder's grace window.
# Within those bounds it does not enforce an edit keyed on a COMBINATION of states the fifteen do not
# visit and written without adding a statement or touching the egress -- e.g. text added to a body
# that only differs on that combination. Those are the residuals, and saying them plainly is the
# point: an earlier round called a fixable gap "irreducible" and it stopped a round from closing it.
# ⛔ NOT THE DOMINANT SENDER (stated, not absorbed): scripts/cadence-nudge.sh is the cadence FLOOR and,
# per its own header and this file's note below, the sender that SURVIVES when this tick is killed at
# its budget. It does carry nudges of its own ("CHECK EVERY LANE IS MOVING", "NEXT: ... spend spare
# capacity on P0, then P1") -- what it does NOT carry is #1991's specific order: AUTOPILOT with its
# gloss, the four boxes, the rail by name, cell-2's automation. A separate sender with its own
# constraints (offline, one giant MSG line), it is filed as agent-infra#1993 so #1993's implementer
# adds only what is missing instead of duplicating what is there. This clause is the tick's, which is
# what #1991 names.
# ⛔ NO BACKTICKS, NO DOUBLE QUOTES AND NO $ IN FA1..FA4 -- the same rule as the rest of MSG (see
# the warning above): MSG is a DOUBLE-QUOTED assignment, so a backticked span is command-substituted
# AT ASSIGNMENT TIME and silently vanishes, leaving a hole the file on disk still looks right about.
# The two composed bodies may reference ${FA1}..${FA4}, and ONLY those references -- an added $ or
# backtick there is the same defect, so it is the composed literal that carries the check.
# ⛔ "ALL FOUR BOXES (local + the three cloud VMs)" IS THE OWNER'S OWN WORDING, quoted verbatim: the
# count is a fact about the fleet, not about this code, and nothing in the repo enumerates the VMs
# (pi-cell-2 and pi-cell-3 appear by name, in the cloud-cell scripts; no file enumerates the fleet).
# If a box is added or retired this sentence must be re-issued by
# the owner, not silently edited here -- an order carrying a visibly stale fact teaches the reader
# to skim the order.
# -- the file-backed overnight worklist, appended to the ORDER (owner, 2026-10-21) ------------
# WHY. FLEET ADVANCE is the standing order; the list for TONIGHT is DATA, not code. The owner writes it
# to $STATE/OVERNIGHT-WORKLIST.md as open `- [ ]` boxes, and the beat must CARRY those lines — a beat
# that only says "advance" leaves the orchestrator to re-derive its own priorities, and the list on
# disk is then read by nobody.
# ⛔ FILE-BACKED, NEVER A HARDCODED LIST: this reads the file at tick time. An item added, reworded or
# ticked off needs no edit here, and no copy of the list can go stale inside the script.
# ⛔ IT RIDES THE SHARED TAIL OF THE ORDER, SO BOTH BODY FORMS CARRY IT. The SHORT FORM below REBUILDS
# MSG from its own literal, so an append placed after that rebuild is lost on every quiet beat (the
# #1991 mis-fix). WL_ORDER is interpolated into BOTH composed bodies, and it is EMPTY when the file is
# absent or carries no open box — which keeps every golden body in tests/heartbeat-fleet-advance/
# byte-identical on a box with no worklist.
# BOUNDED: a long list must not turn the 5-minute pulse into a wall of text, and the tail says how many
# more there are rather than dropping them silently.
WL_ORDER=""
if [ -r "$STATE/OVERNIGHT-WORKLIST.md" ]; then
  _wl_n=0; _wl_more=0
  while IFS= read -r _wl_line || [ -n "$_wl_line" ]; do
    case "$_wl_line" in
      '- [ ]'*)
        _wl_item="${_wl_line#- \[ \]}"
        _wl_item="${_wl_item#"${_wl_item%%[![:space:]]*}"}"
        [ -n "$_wl_item" ] || continue
        _wl_n=$((_wl_n + 1))
        if [ "$_wl_n" -le 12 ]; then
          WL_ORDER="${WL_ORDER} (${_wl_n}) ${_wl_item}."
        else
          _wl_more=$((_wl_more + 1))
        fi ;;
    esac
  done < "$STATE/OVERNIGHT-WORKLIST.md"
  if [ -n "$WL_ORDER" ]; then
    WL_ORDER=" ⛔ OVERNIGHT WORKLIST — the owner's OPEN items for tonight, read from ${STATE##*/}/OVERNIGHT-WORKLIST.md (a file, not a list compiled into this script); advance these in THIS beat, and tick an item off only when its artifact exists:${WL_ORDER}"
  fi
  if [ "$_wl_more" -gt 0 ]; then
    WL_ORDER="${WL_ORDER} (+${_wl_more} more open item(s) still in the file.)"
  fi
fi

FA1="CHECK THE cmux LANES AND ALL FOUR BOXES (local + the three cloud VMs) and push each toward AUTOPILOT — dispatching, creating PRs, fixing them, merging them UNATTENDED."
FA2="USE THE CAPACITY, DO NOT REPORT IT: dispatch locally if the local machine has room, on a cloud VM if it is idle."
FA3="DRIVE THE P0/P1 PRs: name the specific PRs that should land this cycle, take each one to the rail via scripts/admin-merge.sh, and advance agent-infra (cell-2 owns it) toward automating dispatch, PR creation, fixing and merging."
FA4="A beat that reports state and dispatches nothing is a WASTED BEAT."
FLEETADV="⛔ FLEET ADVANCE — an ORDER, not a report. (1) ${FA1} (2) ${FA2} Lanes must be running on real work, not described in a paragraph about load. (3) ${FA3} ${FA4}${WL_ORDER} "
FLEETADV_SHORT="⛔ FLEET ADVANCE — an ORDER, not a report. ${FA1} ${FA2} ${FA3} ${FA4}${WL_ORDER} "

# -- the map: read it before you plan, and nurture it --------------------------
# The overview of the WHOLE CI-and-PR-merge problem lives in the Tortoise graph, and
# its entry point is the "connect to the Tortoise graph" comment on #4844 (it states
# the overview, the read recipe, the read-back assertion, the pitfalls, and the
# standing instruction to add findings as you go). The scripts used to cite #4844 only
# as "the read recipe", which framed the map as a manual to consult and not as the
# thing to keep current -- so lanes read it, took the priority stack, and left their
# own measurements in their session, where they died. #4844 is CLOSED; that is
# irrelevant, because the COMMENT is the living map.
MSG="${MSG} ⛔ MAP: the CI-and-merge crisis is the Tortoise graph, entered via the graph comment on #4844 — read it, and keep it current with what you find. "
# -- ⛔ PRIORITY: read the ORDER from the graph before dispatching, every time -----------
# Added 2026-10-01 on the owner's instruction. The stack is a HYPOTHESIS about the work, not a
# statement that it is open: on 2026-10-01 this orchestrator dispatched a lane onto a tier's
# top item (#4776, '74% of the queue' by the stack's own text) WITHOUT checking its state, and
# it was CLOSED -- the same propagation-of-a-dead-entry the stack had already recorded doing
# the day before. So the reminder carries the RULE, not just the pointer.
# ⛔ NO BACKTICKS OR DOLLAR SIGNS IN THIS TEXT. MSG is a double-quoted assignment, so a backtick
# span is COMMAND-SUBSTITUTED at assignment time and silently vanishes, leaving empty parentheses.
# MEASURED 2026-10-01: the first version of this clause wrote `gh issue view <N> --json state` in
# backticks, and the shipped heartbeat read "VERIFY each item's state () before dispatching" -- the
# command ran, its output went nowhere, and the words disappeared. This file already carried the
# warning at :377-379 (a lane name in backticks was executed as a command) and it was repeated
# anyway. Quote plainly, or use the word 'run'.
MSG="${MSG} ⛔ PRIORITY: before dispatching, read the ranked order IN THE GRAPH (the restated PRIORITY STACK + the objective cascade: DRAIN -> BE ABLE TO MERGE -> COMPLETE P0/P1 -> LAUNCH ALPHA -> PILOTS -> REVENUE), then VERIFY each item's state with gh issue view N --json state — a stack entry is a hypothesis about the work, never a statement that it is open. ${FLEETADV}"

if [ -n "${CAPTEXT:-}" ]; then MSG="${MSG} ${CAPTEXT}"; fi

# -- SHORT FORM when there is nothing to act on -------------------------------
# Every nudge measured 2396 chars, 84% of it the verdict LEGEND — so a healthy tick
# arrived as a wall of text and the 5-min pulse was unreadable. With no alerts and no
# routed/delivered answers there is nothing the legend can help you read, so send the
# two lines that matter and keep the full text for ticks that carry an alert.
# The delivery check greps for "HEARTBEAT ${TS}", which both forms contain.
if [ "${FORCE_SHORT:-0}" = "1" ] || { [ "$N_ALERT" -eq 0 ] && [ -z "$ASK_EV" ]; }; then
  MSG="[HEARTBEAT ${TS}] fleet ${N_ACT}active/${N_WAIT}waiting-child of ${N_TOTAL}. ${DELIV} ${QUEUE} ${OBJ} ⛔ ROLE: orchestrate, don't implement — dispatch and verify the artifact; never decide for the owner (their questions go through the AGENTS.md protocol to the owner-decision label, ask-owner.py). ⛔ MAP: the CI-and-merge crisis is the Tortoise graph, entered via the graph comment on #4844 — read it, keep it current. ⛔ PRIORITY: read the ranked order IN THE GRAPH (restated PRIORITY STACK + the cascade DRAIN -> MERGE -> P0/P1 -> ALPHA -> PILOTS -> REVENUE) and VERIFY each item's state (gh issue view N --json state) before dispatching — a stack entry is a hypothesis, not proof it is open. No alerts. (Verdict legend suppressed: CHILD-STUCK / WEDGED / DONE-IDLE / UNBOUND are WEAK signals — confirm against the pane or a content scan before acting. Full legend + VERDICTS known= are in ${LOG##*/}.) ${FLEETADV_SHORT}"
  # ⛔ THE ORDER RIDES THE LITERAL ABOVE, and that is deliberate: the SHORT FORM REBUILDS MSG, so an
  # order appended as a SEPARATE statement below this rebuild is both easily lost (delete one line and
  # every quiet beat loses it) and easily made conditional (wrap it in an `if` and no count changes).
  # Embedded in the literal there is no append statement to wrap, and the capacity clause still comes
  # AFTER it -- the order first, the detail it acts on second, pinned by the suite.
  if [ -n "${CAPTEXT:-}" ]; then MSG="${MSG} ${CAPTEXT}"; fi
fi
# -- the bottleneck clause, when the queue is the constraint -------------------
# This is the only clause that tells the orchestrator to ADD MERGE LANES. It is
# stated as a demand (have vs need) and names the lanes it counted, because the
# misspelling on disk makes any substring count find zero.
if [ "$MQ_ALERT" -eq 1 ]; then
  MSG="${MSG} ⛔ MERGE-QUEUE BOTTLENECK: ${QUEUE#QUEUE: } — the queue is the constraint, not a lane. Draining it is the orchestrator's own job: raise merge-duty lanes from have to need and record each new lane's exact label in state/merge-lanes.txt (an EXPLICIT label list — the standing lane is spelled 'Merigng', so NO filter containing 'merg' finds it; measured: grep -i merg returns zero rows). Unblocking counts as draining: a PR that cannot merge is queue depth until the blocker is named."
fi
if [ "${OBJ_ALERT:-0}" -eq 1 ]; then
  # REFRAMED 2026-10-01 per the OWNER'S RULING (#6792): the key objective is DRAINING the queue,
  # and "the <10min should be more of a guideline than an absolute rule… the objective is more
  # qualitative." The old text asserted a hard target ("under 10 PRs waiting and under 10 min of
  # CI"), which would have kept steering the fleet at a number the owner demoted. CI time is now
  # reported as an INDICATOR beside the queue, never as the thing that makes the verdict.
  MSG="${MSG} ⛔ OBJECTIVE AT RISK: ${OBJ#OBJECTIVE } — the objective is the QUEUE (drain it without discarding useful work); the CI minute figure is an INDICATOR, not a target (owner ruling, #6792). BLOCKED means MAIN IS RED, which stops the merge queue: debug the TREE, not the lanes. Read that sha's check-runs, newest attempt per (app, workflow, job), judged by POLARITY — a missing check is not a green check. CI time is JOB wall time, not a run's created-to-updated span. "
fi
if [ "$N_ASK" -gt 0 ]; then
  MSG="$MSG QUESTIONS: ${ASK_EV} — a question either CLEARED the gate (now labelled owner-decision, i.e. in the owner's queue), was SENT BACK with a template (labelled question-bounced; the lane removes that label to re-submit), or was ANSWERED (labelled owner-answered, and the owning lane has just been told to read the reply). Grow = the lane could not be routed — check the log line ending 'NO LANE ROUTE' and carry the answer to the lane by hand."
fi

# -- ORCHESTRATOR LIVENESS GUARD ------------------------------------------------
# A DEAD orchestrator pane is a BARE LOGIN SHELL, and MSG below is several KB of text
# containing backticks and `$`. Typed into a shell it would be EXECUTED as a command
# line. MEASURED 2026-10-03: the orchestrator session died in the cmux restart while
# this loop kept running for ~20 min, so every tick would have submitted that text into
# whatever shell was in the pane. cmux's own pid record names the PROCESS rather than
# the pixels, so it is the signal to gate on. Withholding costs nothing: the next tick
# re-evaluates, and a pane with no pi cannot act on a nudge anyway.
# NO PIPE INTO THE QUIET GREP. `cmux sessions list | grep workspace | grep -q pid_exists` is
# the #864 class with a non-builtin producer: the quiet grep exits at its first match, the
# upstream grep takes SIGPIPE, and `pipefail` promotes that 141 to the pipeline status — which
# `!` inverts into "no live pi", so a LIVE orchestrator pane would be SKIPPED and never nudged.
# Capture the workspace lines first (a command substitution reads all of its input, so nothing
# upstream can take the signal), then classify the capture. Behaviour is identical.
if ! grep -q "pid_exists=yes" <<<"$(cmux sessions list 2>/dev/null | grep "workspace=$ORCH_WS" || true)"; then
  log "SKIP orchestrator pane has NO live pi (pid_exists != yes) — refusing to type into a bare shell queue=[${QUEUE}] alerts=[${ALERTS}]"
  exit 0
fi

# -- IDLE GUARD: never nudge a pane that is already WORKING --------------------
# A nudge exists to WAKE an idle orchestrator. If the pane already shows a spinner,
# the orchestrator is MID-TURN: the message is transmitted but cannot be consumed
# until that turn ends, so it parks in the composer. Repeated ticks then pile up
# there and silently concatenate with the next message -- the exact "stuck in the box"
# the owner reported on 2026-09-30.
#
# MEASURED 2026-09-30: of 28 nudges in orchestrator-heartbeat.log, 27 logged
# `delivered=UNVERIFIED (not seen in 100s)` and the single `delivered=yes (5s)`
# landed in a moment the pane was idle. The session-file poll below cannot tell
# "not yet consumed" from "not delivered" -- but the PANE can, and it is the only
# signal that distinguishes working from stalled (a long tool call writes nothing
# to the session file, so mtime is blind to it).
#
# Withholding the nudge costs nothing: a working orchestrator does not need waking,
# and the next tick re-evaluates. It only defers a nudge that was never needed.
if cmux read-screen --workspace "$ORCH_WS" --lines 6 2>/dev/null | grep -q "Working"; then
  # still stamp the merge-queue alert, or a busy orchestrator would make the alert
  # re-fire on every subsequent tick.
  if [ "$MQ_ALERT" -eq 1 ]; then printf '%s\n' "$NOW" > "$MQ_ALERTFILE" 2>/dev/null; fi
  if [ "${PULSE_FIRED:-0}" = "1" ]; then
    # ⛔ A PULSE IS NOT A REPEATED TICK. It fires only after PULSE_MIN minutes of silence, so it
    # cannot pile up -- and pi holds a mid-turn send as STEERING rather than dropping it. The
    # composer-parking bug that motivated this guard is ALSO fixed (the send is now one atomic
    # call, see the send block). Withholding it here is what produced the owner's
    # "no heartbeat since...?": the guard silenced the one message whose whole purpose is to
    # break a silence. Alerts still pass through as before.
    log "PULSE THROUGH the idle guard (mid-turn, but ${PGAP:-?}m of silence -- rate-limited, so no pile-up) queue=[${QUEUE}] alerts=[${ALERTS}]"
  else
    log "SKIP orchestrator WORKING (mid-turn) -- nudge withheld so it cannot queue in the composer queue=[${QUEUE}] alerts=[${ALERTS}]"
    exit 0
  fi
fi

# capture the REAL error — the first version discarded stderr and logged only
# "ERR send failed", which made a diagnosable failure undiagnosable for two ticks.
# ⛔ ONE CALL, TEXT + THE LITERAL \n. This is the ONLY form that both writes AND submits.
# A text-only send PARKS in the composer and needs a SECOND call to release it -- and when
# that second call times out (rc=1, which the notes below say happens routinely), the text
# stays sitting in the box, unsent. That is the "written but not sent" the owner reported on
# 2026-10-01: a tick visible in the composer that never arrived. MEASURED across the whole of
# 2026-10-01's dispatch session -- the single-call form "text\n" reliably starts a turn; a bare
# text send parks, and the parking is invisible to every check this script performs.
err=$(cmux send --workspace "$ORCH_WS" --surface "$ORCH_SURFACE" "$MSG\n" 2>&1)
rc=$?
# ⛔ rc != 0 is NOT proof the message failed to land. `cmux send` returns non-zero when
# it gives up waiting for confirmation (`Error: Command timed out`) — and MEASURED
# 2026-09-28 the message arrives anyway: EVERY heartbeat the orchestrator received
# between 06:58 and 08:19 (07:08:39, 07:26:02, 07:41:18, 07:59:52) logged
# `ERR send/enter rc=1` here and was delivered regardless.
#
# The old `exit 0` meant those four never reached the verification poll below, so the
# log recorded a delivery FAILURE for messages that had arrived. That is why NUDGE
# lines (194) are outnumbered by ERR lines (221), and why an 80-minute "silence"
# appeared in a window that was never silent. A delivery log that lies in the
# direction of apparent failure is worse than no log: it manufactures outages.
#
# So: log the rc, then FALL THROUGH and let the poll decide. That poll is the only
# thing that can answer "did it land", and it already carries the correct verdict
# (`delivered=UNVERIFIED ... may still have landed`) — it simply never got to run.
if [ "$rc" -ne 0 ]; then log "WARN send rc=$rc :: $(printf '%s' "$err" | head -1)"; fi
# RECOVERY ONLY -- never the primary path. If the atomic send above reported non-zero there
# may be text parked in the composer (an earlier tick's, or a partial write); a bare \n is the
# only thing that releases it. Harmless when the composer is empty (a no-op), and gating it on
# rc keeps the normal path a single send so a parked composer cannot be CREATED here.
if [ "$rc" -ne 0 ]; then
  e2=$(cmux send --workspace "$ORCH_WS" --surface "$ORCH_SURFACE" '\n' 2>&1)
  r2=$?
  log "WARN enter rc=$r2 :: $(printf '%s' "$e2" | head -1)"
fi

# Poll rather than check once: this session file is ~18 MB and its append is not
# instantaneous, so a single check after a fixed sleep reads a file the message
# has not reached yet and reports delivered=UNVERIFIED on a message that arrived.
# The message was already confirmed present in the file — the 3s sleep was the bug.
of=$(cmux surface resume show --workspace "$ORCH_WS" 2>/dev/null | head -1 \
     | sed -n "s/.*--session' *'\([0-9a-f-]\{36\}\)'.*/\1/p" | head -1)
if [ -n "$of" ]; then of=$(ls -1t "$SD"/*/*"$of"*.jsonl 2>/dev/null | head -1); else of=""; fi
[ -z "$of" ] && of=$(ls -1t "$SD"/*/*"$ORCH_MARK"*.jsonl 2>/dev/null | head -1)
seen=0
i=0
while [ "$i" -lt 20 ]; do
  # grep the WHOLE file, not a tail window: an 18 MB session can append records
  # large enough to push a heartbeat out of any fixed tail, which made this
  # report UNVERIFIED on messages that had demonstrably arrived.
  if [ -n "$of" ] && grep -q "HEARTBEAT ${TS}" "$of" 2>/dev/null; then
    seen=1; break
  fi
  i=$((i+1)); sleep 5
done
if [ "$MQ_ALERT" -eq 1 ]; then printf '%s\n' "$NOW" > "$MQ_ALERTFILE" 2>/dev/null; fi
if [ "$seen" -eq 1 ]; then
  log "NUDGE at=$NOW delivered=yes ($((i*5))s) queue=[${QUEUE}] alerts=[${ALERTS}] ask=[${ASK_EV}]"
else
  # Measured: a message sent at T landed in this session file at T+53s. The
  # orchestrator's session flushes lazily — the file is 18 MB and is written when
  # the process next persists, not on send. So UNVERIFIED here means "not seen
  # within 100s", NOT "not delivered": an immediate re-send would duplicate.
  log "NUDGE at=$NOW delivered=UNVERIFIED (not seen in 100s; may still have landed) queue=[${QUEUE}] alerts=[${ALERTS}] ask=[${ASK_EV}]"
fi
exit 0
