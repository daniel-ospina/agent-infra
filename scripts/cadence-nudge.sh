#!/usr/bin/env bash
# cadence-nudge.sh -- GUARANTEE the heartbeat message cadence, independent of the tick.
#
# WHY THIS EXISTS (measured 2026-10-04).
#   The owner's requirement is that the MESSAGES RECEIVED land in a 5-9 min band, not merely that
#   the loop passes. Measured over the last 14 delivered nudges: in-band 1/13, worst gap 353 min.
#   The loop was passing every ~9 min the whole time -- the messages were not.
#
#   Two independent gates were eating the message:
#     (a) step 1 (`orchestrator-heartbeat.sh`) s     bounded at TARGET-DISPATCH_BUDGET = 300s, and it
#         is killed (rc=143) under load BEFORE it reaches its `cmux send` at line 674. The slow reads
#         (`lane-status.py` 167-273s, `beta-progress.py`) all sit ABOVE the send in that file, so a
#         kill removes the message while the pass still logs `PASS done in 540s`.
#     (b) even when it gets there, the `Working` guard withholds the nudge unless PULSE_FIRED is set.
#
#   Both gates are defensible individually and jointly fatal to the promise: the cadence is held
#   hostage by expensive work whose completion is not guaranteed. THE CURE IS ORDERING -- ask whether a
#   message is DUE before doing anything expensive, and if it is, send a CHEAP one now. A message that
#   has already left cannot be killed by a later timeout.
#
# WHAT IT DOES. Reads the last DELIVERED nudge from the log (cheap, local). If one is not due, exits
# immediately (the common case -- a few ms, so it never costs the pass anything). If one IS due, builds
# a minimal heartbeat from CACHED/local state only -- NO network, NO `gh`, NO lane classification, so it
# cannot be slow and cannot be killed -- and sends it as one atomic `text\n` call, then logs a NUDGE
# line so the next pass sees it.
#
# It deliberately does NOT try to be as informative as the tick. The tick still runs, still classifies
# lanes, still feeds the queue, and still sends its own richer message when it survives. This is the
# FLOOR: a low-information heartbeat on time beats a rich one that never arrives.
set -uo pipefail

SCRIPTS="$HOME/.pi/agent/scripts"
STATE="$HOME/.pi/agent/state"
LOG="$STATE/orchestrator-heartbeat.log"
PULSE_MIN="${PULSE_MIN:-5}"
# A small grace so this cannot race the tick it protects: if the tick is about to deliver, we do not
# want to pre-empt it and then have BOTH in flight.
# ⛔ THE GRACE WAS WRONG AND IT PUT THE HEARTBEAT OUTSIDE THE BAND IN THE OTHER DIRECTION.
# It was `due = PULSE_MIN - GRACE` with GRACE=1, i.e. fire once 4 minutes have elapsed -- BELOW the
# owner's 5-min floor. Combined with the pass ALSO nudging, the measured gaps came out at 4m: too
# frequent, and just as out-of-band as the 54m failure in the other direction. The band is 5-9 and the
# floor matters as much as the ceiling.
# `due = PULSE_MIN` with no grace is correct now that the nudge has exactly ONE driver (cadence-timer.sh);
# the grace existed only to avoid racing a second caller, and that second caller has been removed.
GRACE=0

[ -f "$STATE/HEARTBEAT-OFF" ] && exit 0

# ⛔ ONE NUDGE AT A TIME. The timer is now fire-and-forget (see cadence-timer.sh: it must never wait on a
# send), so a slow cmux can leave one nudge in flight when the next tick fires. Without a lock, both
# would read the same "is it due?" answer from the log and both would send -- two messages seconds apart,
# which is out-of-band in the over-frequent direction. The loser exits silently; the next tick retries.
# A STALE lock (older than the interval, so a killed nudge cannot wedge the floor) is taken over -- that
# is the same failure that stranded the loop on a dead pid file earlier today, so it is handled here.
LOCK="$STATE/cadence-nudge.lock"
if [ -d "$LOCK" ] && [ -n "$(find "$LOCK" -maxdepth 0 -mmin +6 2>/dev/null)" ]; then
  rmdir "$LOCK" 2>/dev/null
fi
mkdir "$LOCK" 2>/dev/null || exit 0
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

now=$(date +%s)
# ⛔ THE FIRST VERSION OF THIS LINE WAS WRONG AND SILENTLY SO. It read:
#     last=$(grep -o 'NUDGE at=[0-9]* delivered=yes' "$LOG" | tail -1 | grep -o '[0-9]*$')
# The second grep is `[0-9]*$`, which matches the EMPTY STRING at the end of `...delivered=yes` --
# `*` allows zero digits -- so `last` was always empty -> 0, and the very first run logged
# `gap=29852468m` (56 years) while still delivering. A check that computes a nonsense number and
# proceeds anyway is the same shape as the gates this file exists to catch. Capture the digits with
# an ANCHORED pattern that cannot match empty (`[0-9]\{1,\}` / `[0-9]+`), or not at all.
last=$(sed -n 's/.*NUDGE at=\([0-9][0-9]*\) delivered=yes.*/\1/p' "$LOG" 2>/dev/null | tail -1)
# Fail LOUD on an unparseable timestamp rather than treating it as epoch 0: if the log format
# changes, a silent 0 means "due" on EVERY pass and the floor turns into a flood.
if ! printf '%s' "${last:-}" | grep -qE '^[0-9]{9,}$'; then
  printf '%s CADENCE-NUDGE: could not parse a previous NUDGE timestamp from %s -- not sending\n' \
    "$(date '+%m-%d %H:%M:%S')" "$LOG" >> "$LOG"
  exit 0
fi
gap_min=$(( (now - last) / 60 ))
due=$(( PULSE_MIN - GRACE ))
[ "$gap_min" -lt "$due" ] && exit 0     # not due -- the cheap, common path

# ---- build the message from cached/local state ONLY (no network) ----
OBJ="$STATE/objective.last"
q=""
if [ -f "$OBJ" ]; then
  q=$(grep -oE '(open|drafts|nondraft|blocked|conflicting)=[^ ,}]*' "$OBJ" 2>/dev/null | tr '\n' ' ' | cut -c1-160)
fi
qcount=$(printf '%s' "$q" | grep -oE 'open=[0-9]+' | head -1)
nq=$(awk 'END{print NR}' "$STATE/queues/LANDABLE.tsv" 2>/dev/null || echo 0)
nrem=$(awk 'END{print NR}' "$STATE/queues/REMEDY.tsv" 2>/dev/null || echo 0)

# ---- GOAL + LANE STATE: the two things the owner named as missing -----------------------------
# The owner's requirement (2026-10-05): the heartbeat must carry THE GOAL, the CONTEXT (the graph),
# and the STATE (a lane recap) -- not a meta-note about which sender fired. The floor previously
# announced only its own cadence, which told the orchestrator nothing it could act on.
# GOAL is a persisted one-liner (no network); LANES comes from state/lane-recap.last, which
# orchestrator-heartbeat.sh now writes BEFORE its slow steps (that file exists because the rich
# tick was being killed at its 540s budget and never reached its own cmux send).
# ⛔ THE GOAL MAP IS QUERIED FROM THE GRAPH, LIVE — THERE IS NO DOCUMENT (owner directive, 2026-10-09).
# This used to read `state/GOAL.last`. That file was still a DOCUMENT: regenerated on a schedule, it
# drifts the moment its writer stops, and it asserts state it did not itself compute — the same class of
# bug as the static stage string it had replaced. The owner's correction: "you're now reading a goals doc,
# but that goals doc is not the graph's goals... why not use tortoise directly as a live map?" So the beat
# asks the graph. `goal-state.py --line` writes nothing.
# BOUNDED + FAIL-LOUD. FalkorDB is a LOCAL socket (127.0.0.1:16379), but a socket can fail where a plain
# file read cannot — so an unreadable graph is reported AS UNREADABLE and NEVER falls back to a stale line.
# A stale line reads as current state, which is precisely the failure this whole rework exists to remove.
# Measured cost: ~0.7s — one small Cypher query, well inside the beat's budget.
goal=""
_goalc="$HOME/Documents/GitHub/tortoise/.venv/bin/python"
if [ -x "$_goalc" ]; then
  ( "$_goalc" "$SCRIPTS/goal-state.py" --line ) >"$STATE/.goal-line.$$" 2>/dev/null & _gp=$!
  ( sleep 20; kill -TERM "$_gp" 2>/dev/null; sleep 3; kill -KILL "$_gp" 2>/dev/null ) 2>/dev/null & _gw=$!
  wait "$_gp" 2>/dev/null
  kill "$_gw" 2>/dev/null; wait "$_gw" 2>/dev/null
  goal=$(sed -n '1p' "$STATE/.goal-line.$$" 2>/dev/null | cut -c1-150)
  rm -f "$STATE/.goal-line.$$"
else
  goal="(no repo venv at tortoise/.venv — the graph cannot be queried from here)"
fi
[ -n "${goal//[[:space:]]/}" ] || goal="(GRAPH UNREADABLE — the goal map was NOT read; this is not 'all met')"
# ⛔ PARSE PER LINE, NOT WITH GREEDY SEDS (2026-10-05). The recap holds one field per line, and the
# previous `.*key=\(.*\) other=.*` form breaks the moment a key is inserted between two others:
# `\(.*\)` is greedy, so it swallows every field between the one it was aiming at and the last
# match. Inserting `continue=` between `alerts=` and `wip=` would have silently folded three fields
# into `alerts`. A per-line extractor cannot have that failure mode and needs no format migration.
_rec(){ sed -n "s/^$1=//p" "$STATE/lane-recap.last" 2>/dev/null | head -1; }
# Initialised OUTSIDE the branch: the nudge is the one sender that must never fail under `set -u`,
# so a missing recap must leave these defined (empty) rather than unbound.
act=""; actfull=0
if [ -f "$STATE/lane-recap.last" ]; then
  fleet=$(_rec fleet | cut -c1-70)
  # ⛔ THESE CAPS WERE SILENTLY CUTTING THE ACTION LIST (owner-reported "it is not showing the
  # list", diagnosed 2026-10-05). Every field was capped at 120-150 chars, and adding the
  # workspace handle costs ~11 chars per lane -- so a list of 5-6 lanes ran past the cap and was
  # SLICED MID-TOKEN (the beat read `...| π - tortoise(147m)[E` with GOAL immediately after). A
  # truncated list is worse than a short one: it silently drops lanes while looking complete. The
  # cap is now generous enough for every realistic list, and it stays as a guard against a
  # runaway field, not as a design limit.
  alerts=$(_rec alerts | cut -c1-300)
  cont=$(_rec continue | cut -c1-400)
  wip=$(_rec wip | cut -c1-400)
  free=$(_rec free | cut -c1-400)
  human=$(_rec human | cut -c1-400)
  ext=$(_rec ext | cut -c1-300)
  stall=$(_rec stall | cut -c1-300)
  # ⛔ LANES ALREADY AUTO-NUDGED (2026-10-05). They are published as a COUNT + names and NEVER as
  # an action, because the nudger has already told them to continue and they are working again.
  # Offering them as "say CONTINUE" is exactly what makes the orchestrator message a lane twice --
  # the confusion the owner named. Their split is deliberate: "[#] are busy is fine, but which are
  # the actionable ones".
  busy=$(_rec busy | cut -c1-400)
  # ⛔ THE AUTOMATIC CLASSIFIER'S ACTION CLAUSE (2026-10-05). Written by lane-actions.py from the
  # decision tree (state/LANE-STATE-DECISION-TREE.md), which is the ONLY action input here produced
  # by an automatic process that reads EVERY lane: Steps 0-4 in deterministic code, Step 5 in one
  # batched Jev call. The full lists -- idle / say-continue / wedged, each entry carrying the lane
  # LAST MESSAGE and the WHY -- are in state/NEEDS-ACTION.md; only this short pointer clause rides
  # the beat, because the beat must stay ONE line and is already near its display limit.
  # READ FROM THE SIDECAR, NOT FROM THE RECAP. The classifier runs in heartbeat-loop.sh AFTER the
  # tick, precisely because the tick is killed at its own bound before it could ever write this -- so
  # there is nothing in the recap to read, and the floor is the only sender that survives.
  # FRESHNESS-GATED: a stale sidecar (over 20 min, i.e. more than two passes) is not current state
  # and must not be published as if it were; the beat then falls back to its previous clauses.
  # `actfull=1` means the words layer was READ, and only then does this clause SUPERSEDE the weaker
  # mechanical/Jev-triage clauses (wip/continue/free/stall) -- otherwise one lane would be named
  # twice with two different instructions. When the words layer was NOT read, the older clauses
  # stand, so a Jev outage degrades to the previous beat instead of publishing an empty list.
  act=""; actfull=0
  B="$STATE/NEEDS-ACTION.beat"
  if [ -s "$B" ] && [ -z "$(find "$B" -maxdepth 0 -mmin +20 2>/dev/null)" ]; then
    act=$(sed -n 's/^act=//p' "$B" | head -1 | cut -c1-420)
    actfull=$(sed -n 's/^actfull=//p' "$B" | head -1)
  fi
  case "$actfull" in 1) actfull=1 ;; *) actfull=0 ;; esac
  # ⛔ IS THIS THE ENRICHED RECAP OR THE EARLY FALLBACK? (2026-10-05) The tick writes the recap
  # TWICE: a cheap fallback immediately after classification, then an enriched one after the JEV
  # triage. When a tick is slow the fallback is what survives -- and it carries the MECHANICAL
  # lane list with no action classes, so the beat silently loses WIP / ASK-USER / STALL with no
  # sign that anything is missing. Measured 2026-10-05 08:13: a beat showed only IDLE with `(Nm)`
  # ages and no other clause, which reads as "nothing needs attention" when the truth was "the
  # triage has not run yet". The flag makes that visible instead of misleading.
  # ⛔ DEFAULT TO NOT-CRYING-WOLF (2026-10-05). A recap written by a tick that predates this key has
  # NO `rich=` line, and the first cut treated that absence as `0` -- so the floor stamped
  # [PROVISIONAL] on a perfectly ENRICHED recap that carried every triage class (measured 08:18: a
  # beat showed the banner AND `continue=A(0.50) | W0 Test substrate(0.46)` together, which the
  # banner says is impossible). Only an EXPLICIT `rich=0` means the fallback write; absence means
  # unknown, and unknown must not accuse. A banner that fires when nothing is wrong stops being
  # read, which would cost us the real case it exists for.
  rich=$(_rec rich)
  case "$rich" in 0) rich=0 ;; *) rich=1 ;; esac
  [ -n "$fleet" ] || fleet="UNKNOWN"
  recap="$free"
else
  fleet="UNKNOWN (tick has not completed a classification pass)"
  alerts="UNKNOWN -- do NOT read absence as idle"
  cont=""; wip=""; human=""; ext=""; stall=""; busy=""; rich="0"
  free="UNKNOWN"
  recap="$free"
fi
# Friday's shape carries the OBJECTIVE verdict, which objective.py caches here. Read it, do not recompute:
# the floor must stay offline (its whole reason to exist is that it cannot be killed by a slow call).
# ⛔ PUT THE AGE IN THE LINE (2026-10-10, #7871). A reader could not tell a 900s-old line from a
# 5h-old one, and objective.py SKIPS the write when a read is blind -- so the 2026-10-03 change turned
# a BOUNDED staleness into an UNBOUNDED one. This file reads the cache directly, so it inherits neither
# the serve window (VERDICT_SERVE_MAX_S=120) nor the head-liveness check. Measured four times.
# The age is NOT a new invention: `objective.last` line 1 is the write STAMP and carries the age of the
# READING (not of the file), and turn-classify.py has rendered it as `cache_age=` since 2026-10-06
# (OBJECTIVE_FRESH_S=900, tested). SAME NAME, SAME UNIT, SAME WINDOW -- deliberately. A second name for
# one quantity on one line is how one contract becomes two (tortoise/status_vocabulary.py, roadmap
# §7.9 ADOPTED 2026-09-17), and the convergent convention for exposing a cached value's age is a
# delta in seconds compared against a window with the value still PUBLISHED, not omitted (HTTP `Age`,
# RFC 9111 §5.1; k8s `observedGeneration`/`lastTransitionTime`). This whole term is one hunk
# because its only novel part is on the gate below.
# Do NOT shorten the TTL (burns `gh` calls); do NOT make it live on every read without measuring cost.
_cache_age_s() {
  /usr/bin/python3 - "$STATE/objective.last" <<'PYAGE'
import sys, datetime
try:
    with open(sys.argv[1]) as fh:
        first = fh.readline().strip()
    dt = datetime.datetime.fromisoformat(first.replace("Z", "+00:00"))
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=datetime.timezone.utc)
    print(max(0, int((datetime.datetime.now(datetime.timezone.utc) - dt).total_seconds())))
except Exception:
    print("")
PYAGE
}
# R8-- the DO: tokens now NAME their PRs, so the old 150-char cut severed exactly the part
# that makes them actionable (it is how `fix-ci=` was already being truncated). Raised to
# cover the whole DO segment; the RES: line is separate and needs no cut.
obj=$(sed -n '2p' "$STATE/objective.last" 2>/dev/null | cut -c1-400)

# ── RES: the system-resource segment, on its OWN line (objective.last line 3) ──────────
# Its own line because the objective line is ALREADY past the 150 chars it is read with, so
# appending this would cut it off mid-token -- which is what truncates `fix-ci=` today.
# It is NOT truncated: the line is short and every field is load-bearing.
# ⛔ FRESH EVERY BEAT, NEVER FROM THE CACHE. Reading line 3 of `objective.last` inherited that
# file's 900 s TTL: two beats 7m33s apart printed BYTE-IDENTICAL values, including `runq=79`
# and a `top=` consumer at exactly 157.6% -- which cannot repeat on a live box. A resource
# reading is valid for SECONDS and this line AUTHORISES CONCURRENCY, so a stale LOW dispatches
# into a saturated box. `--res` is local-only (no network), so freshness costs nothing.
res=$(/usr/bin/python3 "$HOME/.pi/agent/scripts/objective.py" --res 2>/dev/null)
[ -n "$res" ] && res="· $res"
_age=""; _age_h=""
if [ -n "$obj" ]; then
  _age=$(_cache_age_s)
  if [ -n "$_age" ]; then
    _age_h="$(( _age / 60 ))m"
    obj="$obj cache_age=${_age_h}"
    [ "$_age" -gt 900 ] && obj="$obj STALE(>900s)"
  else
    obj="$obj cache_age=?"
  fi
else
  obj="OBJECTIVE: cache absent"
fi
hms=$(date '+%H:%M:%S')

ts=$(date '+%Y-%m-%dT%H:%M:%S%z')

# ---- resolve the orchestrator pane (same two fallbacks the tick uses) ----
# ⛔ DO NOT HARDCODE A SECOND COPY OF THE PANE. The tick hardcodes ORCH_WS/ORCH_SURFACE in
# orchestrator-heartbeat.sh, and a copy here would silently rot into a DIFFERENT pane the day that
# line changes -- sending heartbeats to the wrong terminal, which is worse than not sending them.
# Read the same single source instead: whatever the tick will send to, this sends to.
TICK="$SCRIPTS/orchestrator-heartbeat.sh"
ORCH_WS="$(grep -m1 '^ORCH_WS=' "$TICK" 2>/dev/null | cut -d'"' -f2)"
ORCH_SURFACE="$(grep -m1 '^ORCH_SURFACE=' "$TICK" 2>/dev/null | cut -d'"' -f2)"
if [ -z "$ORCH_WS" ] || [ -z "$ORCH_SURFACE" ]; then
  printf '%s CADENCE-NUDGE skipped: could not resolve the orchestrator pane from %s\n' \
    "$(date '+%m-%d %H:%M:%S')" "$TICK" >> "$LOG"
  exit 0
fi
# ⛔ NO REACHABILITY PROBE BEFORE THE SEND. The first version probed with `cmux read-screen` and only sent
# if it answered -- a slow-but-working cmux then consumed the budget BEFORE the message went out, which is
# the same ordering defect as the tick's. THE SEND IS THE TEST: `cmux send` already tells us whether it
# worked, so probing first only adds a way to fail without having tried. On failure we log and exit; the
# next pass retries, and the lock in heartbeat-loop.sh prevents a pile-up.

# ⛔ ONE MESSAGE, ONE LINE -- NO EMBEDDED NEWLINES (2026-10-05, owner report).
# MEASURED DEFECT: the multi-line form of this message arrived as 5-6 SEPARATE turns in the pane.
# `cmux send "$MSG\n"` SUBMITS EACH NEWLINE AS ITS OWN TURN, so a body of N lines is N messages.
# The owner's report: "it's a mess... many individual messages, creating massive noise and
# distraction." The tick's own message is a single long line for precisely this reason.
# SO: every section below is joined with a ' · ' separator and the body MUST NOT CONTAIN A NEWLINE.
# ⛔ FRIDAY'S SHAPE, RESTORED (owner instruction, 2026-10-05). The owner's ask was an explicit
# ROLLBACK: "roll back to the heartbeat version we had friday that gave a heartbeat on the lanes
# and a message but not many individual messages" -- Friday's version WORKED FOR AUTONOMY because
# it carried the per-lane verdicts (ACT:) and the objective verdict, i.e. THE STATE OF THE CMUX
# SESSIONS. My one-line rewrite kept the goal and the free list but DROPPED `ACT:`, which is the
# field the orchestrator actually acts on. Restored field-for-field from the tick's own template
# (orchestrator-heartbeat.sh line 577), which was never changed -- it simply never delivers,
# because this floor pre-empts it. So the floor must speak Friday's language.
# STILL ONE MESSAGE, ONE LINE: `cmux send` submits every newline as its own turn (that was the
# noise defect). Friday's shape was always a single line; it is reproduced as one.
# ⛔ WHICH LANES, AND WITH WHAT (owner ask, 2026-10-05): the beat reported a COUNT + a bare
# capacity list, so acting on it still meant opening 29 panes to learn what each lane needed.
# Every class now ships with the action the decision tree prescribes for it, in the order they
# should be worked: WIP lanes first (they are mid-task and cheapest to unblock -- one instruction),
# then truly idle lanes (need work selected), then anything needing investigation.
# ⛔ `do` is a bash RESERVED WORD -- the variable must not be named that.
doact=""
# The automatic classifier's clause goes FIRST, and when its words layer was read it SUPERSEDES the
# four clauses it covers (wip / continue / free / stall). It is the decision-tree-authoritative one
# and it carries the lane last message in the file, so the older lines are duplicates with a second
# instruction rather than extra information. human / ext / busy / alerts are NOT covered by it and
# stay: ASK-USER routing must survive a classifier that emits only the two dispatch lists.
if [ -n "${act:-}" ]; then
  doact="${act} | "
  if [ "$actfull" = "1" ]; then
    wip=""; cont=""; free=""; stall=""
  fi
fi
# WIP and CONTINUE are the SAME action (say continue) reported by two different classifiers -- the
# mechanical one and the JEV triage -- so they are merged into ONE clause rather than naming a lane
# twice with the same instruction. They cannot contradict each other: the tick's DO-DEDUPE drops
# every WIP-IDLE lane out of the READY list before writing this recap.
_cont="${wip:-}"
[ -n "${cont:-}" ] && _cont="${_cont}${_cont:+ | }${cont}"
[ -n "$_cont" ] && doact="${doact}WIP->say CONTINUE (unfinished work in hand; do NOT hand a new task): ${_cont} | "
[ -n "${free:-}" ] && doact="${doact}IDLE->hand the next unheld item: ${free} | "
[ -n "${human:-}" ] && doact="${doact}ASK-USER->raise a user question: ${human} | "
[ -n "${ext:-}" ] && doact="${doact}BLOCKED-EXTERNAL->report only, never nudge: ${ext} | "
[ -n "${stall:-}" ] && doact="${doact}STALL->investigate (pane + CPU time first): ${stall} | "
[ -n "${busy:-}" ] && doact="${doact}BUSY(auto-nudged, now working -- do NOT message): ${busy} | "
[ -n "${alerts:-}" ] && doact="${doact}ATTENTION->check the pane AND CPU-time delta BEFORE acting: ${alerts} | "
[ -n "$doact" ] || doact="(none classified -- do NOT read that as all-idle) "
# ⛔ A PROVISIONAL RECAP MUST ANNOUNCE ITSELF (2026-10-05). The fallback carries the MECHANICAL
# lane list and NO action classes, so its silence reads as "nothing needs attention" while the
# truth is "the JEV triage has not run yet". Measured 2026-10-05 08:13: a beat showed only IDLE
# with (Nm) ages and no WIP / ASK-USER / STALL clause at all -- indistinguishable from a clean
# fleet, and the reason the owner reported the list looking wrong.
# ⛔ NET-GROWTH FREEZE (owner escalation 2026-10-05 19:2x). Measured over 3h: 9 PRs MERGED but 13 were
# OPENED, so open went 21 -> 27 and the queue grew WHILE landings succeeded. A queue cannot drain while
# intake matches outflow, and no CI repair changes that arithmetic. Deterministic + local: compares this
# beat's `open=` to the previous beat's. No network, no gh (the beat must stay network-free).
#
# ⛔ BUT NET-GROWTH ALONE IS NOT THE FREEZE — IT IS THE SYMPTOM, AND IT INVERTS ONCE THE QUEUE IS DRAINED
# (owner correction 2026-10-09, via #6792). The owner's predicate for INTAKE-FROZEN is `waiting >=
# TARGET_PRS(10)`; the freeze is DERIVED, never decided, and a SATISFIED PRECONDITION IS NOT A LIVE
# ⛔ THE DERIVED TRIGGER, AND THE ONLY ONE: `waiting >= TARGET_PRS` (objective.py:66 — "queue depth at
# target: fewer than 10 non-draft PRs waiting to land"). Both the constant and `waiting` are read from
# their owner, objective.py, so there is no second source of truth and no state file.
#
# THREE PROXIES REMOVED HERE, each caught asserting a freeze its own numbers denied:
#   (1) `open_now >= open_prev` alone — held FOREVER once the queue was drained and stable (`5 >= 5`),
#       so the beat emitted INTAKE-FROZEN while its own instrument said AT-TARGET in the SAME message.
#   (2) `... && verdict != AT-TARGET` — a better proxy, still a proxy. Measured 2026-10-09T15:35 it
#       emitted `INTAKE-FROZEN(5->7)` while `waiting=5` sat at HALF the stated trigger of 10. A queue
#       that lands one and opens one is "non-decreasing" on EVERY beat, so growth cannot distinguish a
#       ballooning queue from a healthy one — it can only ever fire, which is why it inverted.
#   (3) `$STATE/.open-prev` — a cross-tick state file: a second source of truth that goes stale.
# The freeze is DERIVED, not decided. Read the trigger; do not infer one from an arithmetic that cannot
# express it. If a future reader wants a flow-based rule, it must be a NEW recorded decision, not this.
_waiting=$(sed -n 's/.*[[:space:]]waiting=\([0-9][0-9]*\).*/\1/p' "$STATE/objective.last" 2>/dev/null | head -1)
_target=$(sed -n 's/^TARGET_PRS[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$SCRIPTS/objective.py" 2>/dev/null | head -1)
# ⛔ THE GATE IS DERIVED FROM THE SAME CACHE, SO IT INHERITS THE SAME AGE (2026-10-10, #7871).
# `waiting` is read from the file, never recomputed -- and the file can be hours old. Measured
# 2026-10-10T12:19 the cache was 13,059s (3.63h) old and said `waiting=11`; one recompute said 9.
# TARGET_PRS=10, so the stale term ASSERTED A FREEZE live truth says had lifted -- the mirror of the
# owner's reproduction, where a stale `waiting=4` DENIED a freeze that was real at 14. Both directions,
# one mechanism. INTAKE-FROZEN decides whether EVERY lane may open a PR, so an age-free freeze is a
# gate asserting a queue that may no longer exist. NOT omitted; no second threshold -- the same
# `cache_age=` the line above carries, rendered where the reader needs it.
_frozen_age=""
if [ -n "$_age" ]; then
  _frozen_age=" cache_age=${_age_h}"
  [ "$_age" -gt 900 ] && _frozen_age=" cache_age=${_age_h} STALE(>900s)"
fi
if [ -n "$_waiting" ] && [ -n "$_target" ] && [ "$_waiting" -ge "$_target" ] 2>/dev/null; then
  doact="${doact}INTAKE-FROZEN(waiting=${_waiting}>=${_target}${_frozen_age})->do NOT open a new PR; land or fix an EXISTING one | "
fi
prov=""
[ "${rich:-0}" = "1" ] || prov="[PROVISIONAL -- triage pending, classes may be MISSING not absent] "
# ── THE RESOURCE VERDICT GATES THE LANE VERDICT (one action per line) ────────────────────
# `RES: ... | DO: RECLAIM` beside `DO: IDLE->2 need dispatch` is TWO OPPOSITE IMPERATIVES with
# no way to reconcile them -- worse than a missing line, because it costs a dispatch cycle and
# teaches the reader to ignore BOTH tokens. Where two subsystems disagree, the MORE RESTRICTIVE
# one wins and says why. (`hold` is included: it also means "add nothing".)
_ract=$(printf '%s' "$res" | sed -n 's/.*| DO: \([A-Za-z-]*\).*/\1/p')
# ⛔ UNCONDITIONAL AND STRUCTURAL. This was a `case` match on the literal phrase `need dispatch`,
# so when an emitter switched to `IDLE->hand the next unheld item` the gate stopped matching and
# FOUR lanes were offered for dispatch while `DO: RECLAIM` said add nothing. EVERY clause is now
# piped through the gate, which decides for itself whether the clause asks for a lane. Fail-open
# (keep the clause) if the gate itself cannot run: losing the whole DO line is worse.
_g=$(printf '%s' "$doact" | /usr/bin/python3 "$HOME/.pi/agent/scripts/objective.py" --gate-clause "$res" 2>/dev/null)
[ -n "$_g" ] && doact="$_g"
MSG="[HEARTBEAT ${hms}] fleet ${fleet}. ${obj} ${res} ${prov}DO: ${doact} GOAL: ${goal} · GRAPH: strategy+decisions live in the TORTOISE GRAPH (read before deriving, write findings back) · ROLE: orchestrate — dispatch + verify the ARTIFACT, never implement, never decide for the owner · classify lanes by the decision tree (CPU-delta > child > tool-age > words; spinner is WEAK) · PR state from artifacts, never a queue row"

# DRY MODE (2026-10-05): print the message and send NOTHING. Added so this file can be verified
# against live state without typing into the orchestrator pane. Off by default and read from the
# environment only, so no production path changes; PULSE_MIN=0 forces the due check open.
if [ "${NUDGE_DRY:-}" = "1" ]; then
  printf '%s\n' "$MSG"
  exit 0
fi
err=$(cmux send --workspace "$ORCH_WS" --surface "$ORCH_SURFACE" "$MSG\n" 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
  cmux send --workspace "$ORCH_WS" --surface "$ORCH_SURFACE" '\n' >/dev/null 2>&1
  # rc != 0 is NOT proof it failed to land (the tick documents four nudges that logged rc=1 and arrived),
  # so record the attempt either way -- but say which it was, so the log cannot manufacture an outage.
  printf '%s CADENCE-NUDGE rc=%s (may still have landed) gap=%sm\n' \
    "$(date '+%m-%d %H:%M:%S')" "$rc" "$gap_min" >> "$LOG"
fi
printf '%s NUDGE at=%s delivered=yes (cadence-floor) gap=%sm queue=[%s] alerts=[] ask=[]\n' \
  "$(date '+%m-%d %H:%M:%S')" "$now" "$gap_min" "$q" >> "$LOG"
exit 0
