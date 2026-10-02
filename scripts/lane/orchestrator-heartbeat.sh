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
ORCH_MARK="01a0cec8"

STALE_MIN=12   # >= this, with a spinner  => WEDGE SUSPECT
IDLE_MIN=9     # >= this, with no spinner => finished/idle
MIN_GAP_MIN=4  # never nudge more often than this (was 8 — it throttled the 5-min pulse)
PULSE_MIN=20          # send the short form anyway if nothing has been said for this long

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
ASK_ALL=$(/usr/bin/python3 "$SCRIPTS/ask-owner.py" --scan $([ "$DRY" = "1" ] && printf -- '--dry-run') 2>&1)
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
  *VERDICT=BLOCKED*|*VERDICT=UNKNOWN*)
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
if [ "$RL" = "1" ] && [ "$N_ASK" -eq 0 ]; then exit 0; fi

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
EV=$(/usr/bin/python3 "$SCRIPTS/lane-status.py" --json --sample 12 2>/dev/null \
  | /usr/bin/python3 -c '
import json,sys
rows=json.load(sys.stdin)
NURT={"CHILD-OVERDUE":0,"CHILD-STUCK":1,"WEDGED":2,"EMPTY":3,"UNBOUND":3,"WIP-IDLE":4,"DONE-IDLE":5}
# The verdicts built off SINGLE proxies, and therefore the ones that produce false alarms:
# three fired on 2026-09-27 alone (a 119m merge rail, live children, a live code-reviewer).
WEAK={"CHILD-OVERDUE","CHILD-STUCK","WEDGED","WIP-IDLE","DONE-IDLE"}
SCREEN_CAP=[3]   # at most 3 screens per tick (~30s each); the rest are screened next tick

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
        r=subprocess.run(["/usr/bin/python3",
                          "$HOME/.pi/agent/state/lane-confirm.py", label],
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
    if v in ("WORKING",): act+=1
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
cap=[]
for r in rows:
    if r["verdict"] not in ("DONE-IDLE","WIP-IDLE"): continue
    if (r.get("child") or {}): continue          # a child in flight is work, not idle
    a=(r.get("stale_s") or 0)//60
    if a>=CAP_IDLE_MIN: cap.append("%s(%dm)" % (r["lane"], a))
cap.sort()
print("ALERTS=\"" + " | ".join(alert).replace("\"", "") + "\";KNOWN=\"" + " | ".join(known).replace("\"", "") + "\";N_ACT=%d;N_WAIT=%d;N_TOTAL=%d;N_ALERT=%d;N_KNOWN=%d;CAP=\"%s\";N_CAP=%d" % (act, wait, len(rows), len(alert), len(known), " | ".join(cap), len(cap)))
' 2>/dev/null)

if [ -z "$EV" ]; then
  log "NOTE lane-status produced no output"
  N_ACT=0; N_WAIT=0; N_TOTAL=0; N_ALERT=0; N_KNOWN=0; ALERTS=""; KNOWN=""; CAP=""; N_CAP=0
else
  eval "$EV"
  log "VERDICTS known=$N_KNOWN: $KNOWN"
fi
if [ "$RL" = "1" ]; then N_ALERT=0; ALERTS=""; N_KNOWN=0; KNOWN=""; fi
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
  log "TRIAGE ready=[$TRIAGE_READY] continue=[$TRIAGE_CONTINUE] human=[$TRIAGE_HUMAN] ext=[$TRIAGE_EXT] stalled=[$TRIAGE_STALL] held_spinning=[$TRIAGE_HELD]"
fi
# -- THE PULSE: silence is not the same as health ------------------------------
# Design rule 1 forbids an unconditional wake-up, and that is right. But it was
# implemented as "speak only when something is ACTIONABLE", and the measured result is
# the orchestrator hearing NOTHING for long stretches: the owner asked "is it firing?
# I haven't seen a heartbeat in a while" while the loop ticked every ~5 min and was
# doing nothing wrong. A reminder nobody reads cannot shape behaviour, and the standing
# ROLE/MAP text only reached the pane on alert ticks, i.e. rarely.
# So: keep no-flood, add a bounded pulse. Nothing actionable AND the last message is
# older than PULSE_MIN -> send the short form anyway. Any alert still fires at once.
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
if [ "${N_CAP:-0}" -gt 0 ]; then
  CAPTEXT="⛔ CAPACITY: ${N_CAP} lane(s) idle >=20m with NO child in flight — free: ${CAP}. Do not leave them waiting: hand each the next unheld item for its lane, reading its last turn first (a lane whose child is still writing is NOT idle)."
else
  CAPTEXT=""
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
MSG="${MSG} ⛔ PRIORITY: before dispatching, read the ranked order IN THE GRAPH (the restated PRIORITY STACK + the objective cascade: DRAIN -> BE ABLE TO MERGE -> COMPLETE P0/P1 -> LAUNCH ALPHA -> PILOTS -> REVENUE), then VERIFY each item's state with gh issue view N --json state — a stack entry is a hypothesis about the work, never a statement that it is open. "
if [ -n "${CAPTEXT:-}" ]; then MSG="${MSG} ${CAPTEXT}"; fi

# -- SHORT FORM when there is nothing to act on -------------------------------
# Every nudge measured 2396 chars, 84% of it the verdict LEGEND — so a healthy tick
# arrived as a wall of text and the 5-min pulse was unreadable. With no alerts and no
# routed/delivered answers there is nothing the legend can help you read, so send the
# two lines that matter and keep the full text for ticks that carry an alert.
# The delivery check greps for "HEARTBEAT ${TS}", which both forms contain.
if [ "${FORCE_SHORT:-0}" = "1" ] || { [ "$N_ALERT" -eq 0 ] && [ -z "$ASK_EV" ]; }; then
  MSG="[HEARTBEAT ${TS}] fleet ${N_ACT}active/${N_WAIT}waiting-child of ${N_TOTAL}. ${DELIV} ${QUEUE} ${OBJ} ⛔ ROLE: orchestrate, don't implement — dispatch and verify the artifact; never decide for the owner (their questions go through the AGENTS.md protocol to the owner-decision label, ask-owner.py). ⛔ MAP: the CI-and-merge crisis is the Tortoise graph, entered via the graph comment on #4844 — read it, keep it current. ⛔ PRIORITY: read the ranked order IN THE GRAPH (restated PRIORITY STACK + the cascade DRAIN -> MERGE -> P0/P1 -> ALPHA -> PILOTS -> REVENUE) and VERIFY each item's state (gh issue view N --json state) before dispatching — a stack entry is a hypothesis, not proof it is open. No alerts. (Verdict legend suppressed: CHILD-STUCK / WEDGED / DONE-IDLE / UNBOUND are WEAK signals — confirm against the pane or a content scan before acting. Full legend + VERDICTS known= are in ${LOG##*/}.)"
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
