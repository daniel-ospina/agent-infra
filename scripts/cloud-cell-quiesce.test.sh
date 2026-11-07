#!/usr/bin/env bash
# cloud-cell-quiesce.test.sh — the regression contract for the WIP-sweep hook (agent-infra#3485).
#
# ⛔ WHY THIS EXISTS. `cloud-cell-quiesce.sh` is the ONE path in this repo that hands a cell's disk on to
# be reclaimed. The hook added at step 3b is the only thing standing between a lane's uncommitted work and
# total loss on that row of the abandonment matrix, and until this file existed NOTHING asserted it: an
# edit could drop `--apply` (turning the hook into the report-only no-op its own comment rejects), move it
# below the re-seed/restart, or stop propagating the sweep's exit code — and every check would stay green
# while the quiesce printed `DONE` having archived nothing.
#
# WHAT IS PINNED, and each arm says which wrong outcome it catches:
#   A. the sweep is invoked, with `--apply` and an explicit `--repo "$REPO"`  (a report-only hook archives
#      nothing; an ambient repo would sweep a repo nobody asked about)
#   B. it runs AFTER the kill sweep and BEFORE the controller is started  (archiving after the restart
#      rescues a tree that has already been reopened)
#   C. a FAILING sweep does not stop supervision being restored — the controller is started anyway  (a
#      quiesce that aborts leaves the cell with zero controllers, worse than what it exists to fix)
#   D. a failing sweep makes the script exit NON-ZERO and prints `NOT DONE`  (a green exit with unarchived
#      work is the false PASS this hook exists to avoid)
#   E. a MISSING sweep is loud and non-zero, never silence
#
# HOW: every external command the script touches is stubbed on PATH, in a scratch tree, with an event log
# so ORDER is asserted rather than assumed. The fleet is never touched.
#
# ⛔ ONE HOST LIMIT, stated rather than skipped silently: step 7 reads `/proc/<pid>/environ`, which exists
# on the Linux cells this script is for and not on macOS. With no `/proc` the script exits 1 there, so the
# two exit-CODE arms are skipped loudly on such a host; every ordering arm (A-E) still runs, because they
# are asserted from the event log.
#
# Run:  bash scripts/cloud-cell-quiesce.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
Q="$HERE/cloud-cell-quiesce.sh"
[ -f "$Q" ] || { echo "❌ missing $Q"; exit 1; }

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); echo "  ✅ $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  ❌ $1"; }
skip() { SKIP=$((SKIP+1)); echo "  ⏭  SKIP: $1"; }

T="$(mktemp -d "${TMPDIR:-/tmp}/quiesce.XXXXXX")"
trap 'rm -rf "$T"' EXIT
echo "==> cloud-cell-quiesce WIP hook ($HERE)"
echo "    scratch: $T"
HAS_PROC=0; [ -d /proc ] && [ -r "/proc/$$/environ" ] && HAS_PROC=1

# ⛔ REFUSE TO RUN UNLESS THE STUBS ARE REALLY ON PATH (review finding, and it is a SAFETY gate, not
# tidiness). A stub that exists but is not EXECUTABLE is SKIPPED by bash's PATH search, so the REAL
# `tmux`/`pkill`/`ps` further down PATH runs instead — and this suite exercises `tmux kill-server` and
# `pkill -f '[o]rch-loop\.sh'`. A `noexec` /tmp (common on hardened images) reproduces that with every
# `chmod` still returning 0. So the preflight resolves each stub the way the SUT will and refuses to run a
# single arm if any of them lands outside the scratch bin dir.
PREFLIGHT_OK=1
PREBIN="$(mktemp -d "${TMPDIR:-/tmp}/quiesce-bin.XXXXXX")" || PREFLIGHT_OK=0
printf '#!/usr/bin/env bash\nexit 0\n' > "$PREBIN/probe" && chmod +x "$PREBIN/probe"
for _tool in tmux pkill ps pgrep; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$PREBIN/$_tool" && chmod +x "$PREBIN/$_tool" 2>/dev/null \
    || PREFLIGHT_OK=0
  _r="$(PATH="$PREBIN:$PATH" command -v "$_tool" 2>/dev/null)"
  [ "$_r" = "$PREBIN/$_tool" ] || PREFLIGHT_OK=0
done
rm -rf "$PREBIN"
if [ "$PREFLIGHT_OK" -ne 1 ]; then
  echo "  ⛔ REFUSING TO RUN: a stub in ${TMPDIR:-/tmp} is not executable or does not win the PATH lookup,"
  echo "     so the REAL tmux/pkill/ps would run against this host. This suite kills processes; it will not"
  echo "     run where it cannot prove its stubs are the ones resolved. Re-run with TMPDIR set to an"
  echo "     executable location (a noexec /tmp is the usual cause)."
  echo "  PASS=0 FAIL=0 SKIP=0 (refused — nothing was run, and nothing on this host was touched)"
  # ⛔ A REFUSAL IS NOT A PASS (#3588 review). This exited 0, so a shard that could not execute a single
  # arm reported GREEN — the no-op-gate shape: "exits 0, or silently does nothing, when it cannot run".
  # The message already says nothing was run; the exit code now agrees with it. Pinned by arms G1/G2 below.
  exit 1
fi

# mk_world <name> — a REPO with the stub supervisor + sweep, a HARNESS with claims.sh, a log.
mk_world() {
  local n="$1" d="$T/$1"
  mkdir -p "$d/repo/scripts/orchestrator-harness" "$d/repo/scripts" "$d/O" "$d/home" || return 1
  : > "$d/claims.sh" || return 1
  cp "$d/claims.sh" "$d/repo/scripts/orchestrator-harness/claims.sh" || return 1
  # Supervisor: logs stop/start, and toggles the "controller is running" flag the ps stub reads.
  printf '%s\n' '#!/usr/bin/env bash' \
    'echo "supervisor:$1" >> "'"$d"'/events"' \
    'case "$1" in' \
    '  start) : > "'"$d"'/running" ;;' \
    '  stop)  rm -f "'"$d"'/running" ;;' \
    'esac' \
    'exit 0' > "$d/repo/scripts/cloud-cell-supervisor.sh" || return 1
  chmod +x "$d/repo/scripts/cloud-cell-supervisor.sh"
  # The sweep stub: logs its argv, writes the pass record the hook now reads, and exits $SWEEP_RC.
  # ⛔ IT WRITES THE RECORD BECAUSE THE HOOK READS IT (#3588 review, cycle 8): `DONE` now requires a
  # readable `unpushed_worktrees=` count, so a stub that archived nothing and recorded nothing cannot
  # stand in for the real sweep — the real one writes this file LAST on exit 0. `SWEEP_NO_RECORD=1`
  # reproduces "exit 0 and no record", which is the mismatched-tool shape the hook must refuse.
  printf '%s\n' '#!/usr/bin/env bash' \
    'if [ "$1" = "--print-status" ]; then echo "status=never"; echo "rc=3"; echo "detail=no pass record at (stub)"; exit 3; fi' \
    'echo "sweep:$*" >> "'"$d"'/events"' \
    'if [ "${SWEEP_NO_RECORD:-0}" != "1" ]; then' \
    '  _sd="${WIP_SWEEP_STATE_DIR:-'"$d"'/O/state}"; mkdir -p "$_sd" 2>/dev/null' \
    '  printf "unpushed_worktrees=%s\n" "${SWEEP_UNPUSHED:-0}" > "$_sd/wip-sweep.status" 2>/dev/null' \
    'fi' \
    'exit "${SWEEP_RC:-0}"' > "$d/repo/scripts/wip-sweep.sh" || return 1
  chmod +x "$d/repo/scripts/wip-sweep.sh"
  # PATH stubs for the process/tmux surface.
  mkdir -p "$d/bin"
  printf '%s\n' '#!/usr/bin/env bash' \
    'case "$*" in' \
    '  "kill-server"*) echo "tmux:kill-server" >> "'"$d"'/events"; rm -f "'"$d"'/running"; rm -f "'"$d"'/alive" ;;' \
    '  "ls"*) exit 0 ;;' \
    '  *) exit 0 ;;' \
    'esac' \
    'exit 0' > "$d/bin/tmux"
  printf '%s\n' '#!/usr/bin/env bash' \
    'echo "pkill:$*" >> "'"$d"'/events"' \
    'rm -f "'"$d"'/alive"' \
    'exit 0' > "$d/bin/pkill"
  # ps: one orch-loop line while the stub controller is "alive", none after the kill sweep. `$d/survive`
  # makes the line PERSIST past the kill sweep — the "a stray outlived the 2 s + 2 s window" shape the
  # unconditional-archive arm (H) needs, without touching this host's processes.
  printf '%s\n' '#!/usr/bin/env bash' \
    'if [ -f "'"$d"'/survive" ] || [ -f "'"$d"'/running" ]; then echo "bash /tmp/cell/orch-loop.sh"; else echo "bash /tmp/cell/other.sh"; fi' \
    'exit 0' > "$d/bin/ps"
  # pgrep: a pid whose /proc environ carries REPO= (so step 7 verifies it) — the sleeper the caller
  # launches, or a harmless self-reference when there is no /proc.
  printf '%s\n' '#!/usr/bin/env bash' \
    'cat "'"$d"'/sleeper.pid" 2>/dev/null || echo $$' \
    'exit 0' > "$d/bin/pgrep"
  chmod +x "$d/bin/tmux" "$d/bin/pkill" "$d/bin/ps" "$d/bin/pgrep"
  return 0
}

# run_quiesce <name> [sweep-rc] — stubs on PATH, the fleet's own processes never touched.
run_quiesce() {
  local n="$1" rc="${2:-0}" d="$T/$1" sleeper=""
  if [ "$HAS_PROC" = 1 ]; then
    # A live process that carries REPO in its environ, so step 7's read-back finds the right value.
    REPO="$d/repo" OR="daniel-ospina/tortoise" SCOPE=own sleep 120 >/dev/null 2>&1 &
    sleeper=$!
    echo "$sleeper" > "$d/sleeper.pid"
  else
    echo "$$" > "$d/sleeper.pid"
  fi
  : > "$d/events"
# ⛔ HOME IS STUBBED TOO, AND THAT IS NOT TIDINESS (review finding). The script's FOURTH resolution
# candidate is `${HOME}/.pi/agent/scripts/wip-sweep.sh` — the path `pi-bootstrap/setup.sh`'s `fleet_srcs`
# fills on every farmed cell. Without overriding HOME, arm E ("a missing sweep") resolves the REAL farmed
# sweep on such a host: it then runs an unstubbed real tool and reports three false FAILs. This suite is
# green on an unfarmed box either way, which is exactly how that defect would survive — so HOME points
# into the scratch tree.
# ⛔ AND THE ASSIGNMENTS BELOW MUST STAY CONTIGUOUS. A `#` line inserted between a `\`-continued
# assignment and its continuation does not comment out a fragment: it ENDS the logical line, so the
# remaining assignments become a SEPARATE command and the prefix is silently dropped. Measured on a copy:
# `CELL_HOME`/`O`/`HARNESS` were dropped while `bash -n` still returned 0, so the suite ran against the
# wrong roots and reported nonsense instead of failing. Which of them survives a break depends on whether
# it was already exported — an already-exported `PATH` still propagates, a `CELL_HOME` set only here does
# not — so the blast radius varies with position rather than being fixed. The whole env block is therefore
# one block with NO comment inside it.
# ⛔ `HARNESS_PIN_FILE` IS PINNED HERE TOO, AND THAT IS THE SAME CLASS OF BUG (#3588 review, cycle 7). The
# SUT resolves its pinned-tree fallback from `${HARNESS_PIN_FILE:-$CELL_HOME/.harness-path}`, and the FLEET
# EXPORTS `HARNESS_PIN_FILE` on every box it runs on. Inherited, it outranks `$CELL_HOME` — so the two arms
# that exist to grade the pin record (E7/E8) read the HOST's real record instead of the fixture's: E7
# reddened on exactly such a host (`wip-sweep: <none found`), while E8 stayed green for the wrong reason
# (the host record names a tree with no sweep, so "nothing was invoked" proved nothing about the code). A
# fixture an ambient variable can redirect measures the host, not the SUT. This is the pattern every sibling
# suite already uses (`scripts/cloud-cell-supervisor.test.sh:1105` — `HARNESS_PIN_FILE="$P/home/.harness-path"`),
# and arm E7c pins that the fixture record wins over an ambient override.
  PATH="$d/bin:$PATH" HOME="$d/home" \
  REPO="$d/repo" OR="daniel-ospina/tortoise" SCOPE=own MAX_LANES=3 \
  CELL_HOME="$d/home" O="$d/O" HARNESS="$d/repo/scripts/orchestrator-harness" \
  HARNESS_PIN_FILE="$d/home/.harness-path" \
  SWEEP_RC="$rc" SWEEP_UNPUSHED="${SWEEP_UNPUSHED:-0}" SWEEP_NO_RECORD="${SWEEP_NO_RECORD:-0}" \
  bash "$Q" > "$d/out" 2>&1
  local st=$?
  [ -n "$sleeper" ] && kill "$sleeper" 2>/dev/null
  return "$st"
}

# ── A/B: invocation, arming, and ORDER ───────────────────────────────────────────────────────────────
echo; echo "── A/B. the sweep is invoked armed, after the kill and before the restart ──"
mk_world ab || { echo "❌ fixture failed (ab)"; exit 1; }
D="$T/ab"
echo alive > "$D/alive"
run_quiesce ab 0; RC=$?
SWLINE="$(grep -m1 '^sweep:' "$D/events" 2>/dev/null)"
[ -n "$SWLINE" ] && ok "A1 the quiesce INVOKES the sweep (the hook exists at all)" \
  || bad "A1 the quiesce never invoked the sweep — events: $(tr '\n' ' ' < "$D/events")"
case "$SWLINE" in
  *"--apply"*) ok "A2 it is ARMED (--apply) — a report-only hook on the path that destroys the disk archives nothing" ;;
  *) bad "A2 the sweep was invoked WITHOUT --apply: $SWLINE" ;;
esac
case "$SWLINE" in
  *"--repo $D/repo"*) ok "A3 it names --repo \"\$REPO\" explicitly (no ambient repo selection)" ;;
  *) bad "A3 the sweep was not given the intended --repo: $SWLINE" ;;
esac
# ⛔ AND NO PER-PASS CAP ON THIS PATH (review finding). The sweep's default cap is 25 archives; here the
# disk is about to stop existing and nothing re-runs the pass, so a cap is a silent PARTIAL archive — on a
# cell with 40 dirty lane trees, 25 archived and 15 deferred, and the box handed on anyway. Only this
# caller passes `--max 0`; a periodic pass keeps its cap.
case "$SWLINE" in
  *"--max 0"*) ok "A4 it disables the per-pass cap (--max 0) — this pass never gets a second run" ;;
  *) bad "A4 the quiesce leaves the sweep's 25-archive cap in place, so a busy cell archives partially: $SWLINE" ;;
esac
# ORDER, read from the event log: kill sweep -> wip sweep -> controller start.
KILL_AT="$(grep -n 'tmux:kill-server\|^pkill:' "$D/events" | head -1 | cut -d: -f1)"
SWEEP_AT="$(grep -n '^sweep:' "$D/events" | head -1 | cut -d: -f1)"
START_AT="$(grep -n '^supervisor:start' "$D/events" | head -1 | cut -d: -f1)"
[ -n "$KILL_AT" ] && [ -n "$SWEEP_AT" ] && [ -n "$START_AT" ] \
  && [ "$KILL_AT" -lt "$SWEEP_AT" ] && [ "$SWEEP_AT" -lt "$START_AT" ] \
  && ok "B1 the ORDER is kill($KILL_AT) → sweep($SWEEP_AT) → start($START_AT) — archive before the tree is reopened" \
  || bad "B1 wrong order (kill=$KILL_AT sweep=$SWEEP_AT start=$START_AT) in: $(tr '\n' ' ' < "$D/events")"
grep -q '^supervisor:stop' "$D/events" \
  && ok "B2 the supervised controller was stopped first (the sweep runs against final trees)" \
  || bad "B2 the supervisor was never stopped"

# ── C/D: a FAILING sweep still restores supervision, and fails the run ───────────────────────────────
echo; echo "── C/D. a failing sweep does NOT leave the cell with zero controllers ──"
mk_world cd || { echo "❌ fixture failed (cd)"; exit 1; }
D="$T/cd"
echo alive > "$D/alive"
run_quiesce cd 4; RC=$?
grep -q '^supervisor:start' "$D/events" \
  && ok "C1 the controller WAS started despite the failing sweep (aborting here would leave zero controllers)" \
  || bad "C1 the quiesce aborted before restoring supervision — events: $(tr '\n' ' ' < "$D/events")"
[ "$RC" -ne 0 ] && ok "D1 a failing sweep makes the quiesce exit non-zero (rc=$RC)" \
               || bad "D1 a failing sweep exited 0 — unarchived work behind a green exit"
grep -q 'NOT DONE' "$D/out" \
  && ok "D2 it says NOT DONE rather than DONE" \
  || bad "D2 the run did not say NOT DONE: $(tail -2 "$D/out")"
grep -q 'FATAL: wip-sweep' "$D/out" \
  && ok "D3 the failure is LOUD (a FATAL line naming the sweep)" \
  || bad "D3 the failure was silent"

# ── E: a MISSING sweep ──────────────────────────────────────────────────────────────────────────────
echo; echo "── E. a missing sweep is loud and non-zero, never silence ──"
mk_world e || { echo "❌ fixture failed (e)"; exit 1; }
D="$T/e"
rm -f "$D/repo/scripts/wip-sweep.sh"
echo alive > "$D/alive"
run_quiesce e 0; RC=$?
grep -q 'FATAL: wip-sweep' "$D/out" \
  && ok "E1 a missing sweep prints a FATAL naming it" \
  || bad "E1 no FATAL for a missing sweep: $(tail -2 "$D/out")"
grep -q 'WORK ON THIS BOX WILL NOT BE ARCHIVED' "$D/out" \
  && ok "E2 it says the work will NOT be archived — a missing rescuer never reads as 'nothing to rescue'" \
  || bad "E2 the missing-sweep message does not state the consequence"
[ "$RC" -ne 0 ] && ok "E3 a missing sweep exits non-zero (rc=$RC)" || bad "E3 a missing sweep exited 0"
grep -q '^supervisor:start' "$D/events" \
  && ok "E4 supervision is still restored with no sweep present" \
  || bad "E4 the quiesce stopped before restoring supervision"

# ── E5/E6: a sweep that EXISTS BUT CANNOT RUN ──────────────────────────────────────────────────────
# ⛔ EXISTS IS NOT RUNS, AND THE GUARD FOR IT WAS UNPINNED (review finding, cycle 5). `[ -f ]` selected a
# 0-BYTE `wip-sweep.sh`; `bash <empty> --apply` exits 0, so the hook printed "every dirty worktree … is
# archived on origin" and `DONE`, rc=0, having archived NOTHING — the false PASS this hook exists to
# prevent, on the one path where the disk stops existing. The guard now requires `-s` AND `bash -n`, but
# E1-E4 only covered a MISSING candidate, so reverting the guard to `[ -f ]` left this suite at PASS=19
# FAIL=0 (measured). These arms cover PRESENT-BUT-UNUSABLE.
# ⛔ AND A 0-BYTE STUB CANNOT LOG ITS OWN INVOCATION — so "it was never invoked" is NOT observable on it
# (measured: `[ -f ]` reddens E5a/E5b/E5c but leaves any "invocation count" arm green, because the empty
# file does nothing when bash runs it). E5e therefore proves SKIPPING the only way it can be proven: a
# USABLE stubbed candidate further down the list must be the one that runs. Under `[ -f ]` the empty first
# candidate wins, nothing logs, and E5e reddens.
mk_world e5 || { echo "❌ fixture failed (e5)"; exit 1; }
D="$T/e5"
: > "$D/repo/scripts/wip-sweep.sh"          # 0 bytes: the interrupted `cp -f` shape
chmod +x "$D/repo/scripts/wip-sweep.sh"
echo alive > "$D/alive"
run_quiesce e5 0; RC=$?
grep -q 'FATAL: wip-sweep' "$D/out" \
  && ok "E5a a 0-BYTE sweep is refused, with a FATAL naming it" \
  || bad "E5a a 0-byte sweep was accepted: $(tail -2 "$D/out")"
grep -q 'WORK ON THIS BOX WILL NOT BE ARCHIVED' "$D/out" \
  && ok "E5b …and it says the work will NOT be archived" \
  || bad "E5b the 0-byte-sweep message does not state the consequence"
[ "$RC" -ne 0 ] && ok "E5c a 0-byte sweep exits non-zero (rc=$RC)" || bad "E5c a 0-byte sweep exited 0 — a false green over an empty archive"
NINV="$(grep -c '^sweep:' "$D/events" 2>/dev/null || true)"
[ "${NINV:-0}" -eq 0 ] \
  && ok "E5d nothing was invoked on the all-unusable fixture (its only candidate was the empty one)" \
  || bad "E5d a sweep ran on a fixture with no usable candidate (${NINV:-?} invocation(s))"

# E5e: THE SKIP ITSELF, OBSERVABLY. The empty candidate is FIRST; a USABLE logging stub sits later in the
# list (`${HOME}/.pi/agent/scripts/wip-sweep.sh`, with HOME stubbed to `$D/home`). A correct guard skips
# the empty one, reaches the usable one, and IT logs. `[ -f ]` stops at the empty one: nothing logs.
mk_world e5e || { echo "❌ fixture failed (e5e)"; exit 1; }
D="$T/e5e"
: > "$D/repo/scripts/wip-sweep.sh"          # first candidate: 0 bytes — unusable, and it CANNOT log
chmod +x "$D/repo/scripts/wip-sweep.sh"
mkdir -p "$D/home/.pi/agent/scripts"
printf '%s\n' '#!/usr/bin/env bash' \
  'if [ "$1" = "--print-status" ]; then echo "status=never"; echo "rc=3"; echo "detail=no pass record at (stub)"; exit 3; fi' \
  'echo "sweep:$*" >> "'"$D"'/events"' \
  'mkdir -p "'"$D"'/O/state" 2>/dev/null; printf "unpushed_worktrees=0\n" > "'"$D"'/O/state/wip-sweep.status"' \
  'exit 0' > "$D/home/.pi/agent/scripts/wip-sweep.sh"
chmod +x "$D/home/.pi/agent/scripts/wip-sweep.sh"
echo alive > "$D/alive"
run_quiesce e5e 0; RC=$?
grep -q '^sweep:' "$D/events" \
  && ok "E5e a 0-byte FIRST candidate is SKIPPED — the usable candidate after it is the one that runs" \
  || bad "E5e the empty candidate was taken: nothing was invoked (a bare -f guard stops at it)"
[ "$RC" -eq 0 ] \
  && ok "E5e2 …and the run still succeeds, so one truncated farm copy does not disable the hook" \
  || bad "E5e2 the run exited $RC although a usable candidate existed: $(tail -2 "$D/out")"

mk_world e6 || { echo "❌ fixture failed (e6)"; exit 1; }
D="$T/e6"
printf '%s\n' 'if ( then' > "$D/repo/scripts/wip-sweep.sh"   # non-empty, does NOT parse
chmod +x "$D/repo/scripts/wip-sweep.sh"
echo alive > "$D/alive"
run_quiesce e6 0; RC=$?
grep -q 'FATAL: wip-sweep' "$D/out" \
  && ok "E6a a NON-PARSING sweep is refused (non-empty defeats a bare -s)" \
  || bad "E6a a non-parsing sweep was accepted: $(tail -2 "$D/out")"
[ "$RC" -ne 0 ] && ok "E6b a non-parsing sweep exits non-zero (rc=$RC)" || bad "E6b a non-parsing sweep exited 0"
# ⛔ E6c IS THE ARM THAT DISCRIMINATES `-s`-ONLY (a guard that checks the file is non-empty but does not
# parse it). A bare invocation claim CANNOT: bash fails to parse a broken file too, so both guards end at
# FATAL/rc≠0 and "was it invoked" is not observable through a stub that cannot run. What DOES differ is
# whether the candidate was RESOLVED at all: a `-s`-only guard resolves it and the `step` line names the
# path, while a `-s` + `bash -n` guard leaves `SWEEP` empty and the hook says work will NOT be archived —
# which is the load-bearing statement, because it is what a reader acts on.
grep -q 'WORK ON THIS BOX WILL NOT BE ARCHIVED' "$D/out" \
  && ok "E6c the non-parsing candidate was NOT RESOLVED — the hook says the work will not be archived" \
  || bad "E6c the hook resolved a non-parsing candidate: $(grep -m1 'wip-sweep:' "$D/out")"

# ⛔ E7 — THE PINNED-TREE FALLBACK MUST RESOLVE A PATH THAT CAN EXIST (#3588 review, cycle 6).
# `.harness-path` holds the HARNESS DIR (`<pin>/scripts/orchestrator-harness`, written by
# `scripts/cloud-cell-supervisor.sh:2315`). The candidate used to be `"$PINNED_DIR/scripts/wip-sweep.sh"`,
# i.e. `<pin>/scripts/orchestrator-harness/scripts/wip-sweep.sh`, which CANNOT EXIST: in a pinned tree the
# sweep is that dir's SIBLING, at `<pin>/scripts/wip-sweep.sh`. No arm created a `.harness-path` record at
# all, which is exactly how an inert candidate stayed green — so E7 is the missing positive control and E8
# is its negative twin (a record naming an absent tree must still refuse loudly).
echo; echo "── E7. a sweep that exists ONLY in the pinned tree is invoked ──"
mk_world e7 || { echo "❌ fixture failed (e7)"; exit 1; }
D="$T/e7"
rm -f "$D/repo/scripts/wip-sweep.sh"          # nothing beside the clone: the PIN is the only source
PINROOT="$D/pin/0123456789ab"
mkdir -p "$PINROOT/scripts/orchestrator-harness"
printf '%s\n' "$PINROOT/scripts/orchestrator-harness" > "$D/home/.harness-path"
printf '%s\n' '#!/usr/bin/env bash' \
  'if [ "$1" = "--print-status" ]; then echo "status=never"; echo "rc=3"; echo "detail=no pass record at (stub)"; exit 3; fi' \
  'echo "sweep:$*" >> "'"$D"'/events"' \
  'mkdir -p "'"$D"'/O/state" 2>/dev/null; printf "unpushed_worktrees=0\n" > "'"$D"'/O/state/wip-sweep.status"' \
  'exit 0' > "$PINROOT/scripts/wip-sweep.sh"
chmod +x "$PINROOT/scripts/wip-sweep.sh"
echo alive > "$D/alive"
run_quiesce e7 0; RC=$?
grep -q '^sweep:' "$D/events" \
  && ok "E7a a sweep that exists ONLY in the pinned tree is INVOKED (the record holds the harness dir, so its SIBLING is the sweep)" \
  || bad "E7a the pinned-tree sweep was never invoked — the candidate built a CHILD of the harness dir, which cannot exist: $(grep -m1 'wip-sweep:' "$D/out")"
grep -q "wip-sweep: $PINROOT/scripts/wip-sweep.sh" "$D/out" \
  && ok "E7b the step line names the pinned sweep, so the resolution graded is the one that ran" \
  || bad "E7b the step line names something else: $(grep -m1 'wip-sweep:' "$D/out")"

# ⛔ E7c — THE FIXTURE RECORD MUST WIN OVER AN AMBIENT `HARNESS_PIN_FILE` (#3588 review, cycle 7). E7 grades
# the pin record, so a host that exports `HARNESS_PIN_FILE` (the fleet does) would otherwise grade the HOST's
# record: measured at the pre-fix suite, E7 reddened with `wip-sweep: <none found` and E8 stayed green for the
# wrong reason. `run_quiesce` now pins it to the fixture, and this arm proves that precedence instead of
# assuming it: the caller exports a DECOY record naming a second, fully usable sweep that logs elsewhere, and
# the fixture's sweep must be the one invoked. It reddens deterministically if that pin is removed, because
# the decoy is exported and would then resolve (on any host, farmed or not).
mk_world e7c || { echo "❌ fixture failed (e7c)"; exit 1; }
D="$T/e7c"
rm -f "$D/repo/scripts/wip-sweep.sh"
PINROOT="$D/pin/0123456789ab"
mkdir -p "$PINROOT/scripts/orchestrator-harness"
printf '%s\n' "$PINROOT/scripts/orchestrator-harness" > "$D/home/.harness-path"
printf '%s\n' '#!/usr/bin/env bash' \
  'if [ "$1" = "--print-status" ]; then echo "status=never"; echo "rc=3"; echo "detail=no pass record at (pin stub)"; exit 3; fi' \
  'echo "sweep:$*" >> "'"$D"'/events"' \
  'mkdir -p "'"$D"'/O/state" 2>/dev/null; printf "unpushed_worktrees=0\n" > "'"$D"'/O/state/wip-sweep.status"' \
  'exit 0' > "$PINROOT/scripts/wip-sweep.sh"
chmod +x "$PINROOT/scripts/wip-sweep.sh"
DEC="$D/decoy/0123456789ab"
mkdir -p "$DEC/scripts/orchestrator-harness"
printf '%s\n' "$DEC/scripts/orchestrator-harness" > "$D/decoy-record"
printf '%s\n' '#!/usr/bin/env bash' \
  'if [ "$1" = "--print-status" ]; then echo "status=never"; echo "rc=3"; echo "detail=no pass record at (decoy)"; exit 3; fi' \
  'echo "sweep:$*" >> "'"$D"'/decoy-events"' \
  'mkdir -p "'"$D"'/O/state" 2>/dev/null; printf "unpushed_worktrees=0\n" > "'"$D"'/O/state/wip-sweep.status"' \
  'exit 0' > "$DEC/scripts/wip-sweep.sh"
chmod +x "$DEC/scripts/wip-sweep.sh"
echo alive > "$D/alive"
HARNESS_PIN_FILE="$D/decoy-record" run_quiesce e7c 0; RC=$?
[ ! -s "$D/decoy-events" ] \
  && ok "E7c an AMBIENT HARNESS_PIN_FILE does not decide this arm — the fixture's record is the one resolved" \
  || bad "E7c the ambient decoy record won: the suite graded the HOST's pin, not the fixture's ($(tr '\n' ' ' < "$D/decoy-events"))"
grep -q "wip-sweep: $PINROOT/scripts/wip-sweep.sh" "$D/out" \
  && ok "E7c2 …and the FIXTURE's pinned sweep is the one named and invoked" \
  || bad "E7c2 the fixture's pinned sweep was not the one resolved: $(grep -m1 'wip-sweep:' "$D/out")"

mk_world e8 || { echo "❌ fixture failed (e8)"; exit 1; }
D="$T/e8"
rm -f "$D/repo/scripts/wip-sweep.sh"
printf '%s\n' "$D/pin/does-not-exist/scripts/orchestrator-harness" > "$D/home/.harness-path"
echo alive > "$D/alive"
run_quiesce e8 0; RC=$?
NINV8="$(grep -c '^sweep:' "$D/events" 2>/dev/null || true)"
[ "${NINV8:-0}" -eq 0 ] \
  && ok "E8a a record naming an ABSENT tree resolves nothing — no sweep was invoked" \
  || bad "E8a something was invoked for an absent pin: $(grep -m2 '^sweep:' "$D/events")"
grep -q 'WORK ON THIS BOX WILL NOT BE ARCHIVED' "$D/out" \
  && ok "E8b …and the hook still says the work will not be archived (loud, never a false green)" \
  || bad "E8b the absent-pin path did not warn: $(grep -m1 'wip-sweep:' "$D/out")"

# ⛔ E9 — PARSES IS NOT SWEEPS, AND THIS WAS THE LAST FALSE PASS ON THIS HOOK (#3588 review).
# `-s` + `bash -n` accepted a TRUNCATED PREFIX of a real `wip-sweep.sh`. MEASURED on whole-line truncations
# of the shipped sweep at 60/80/100/150 lines: all four PARSE, and `bash <prefix> --apply` exits **0 having
# archived nothing** — so this hook printed "every dirty worktree … is archived on origin", `DONE`, rc=0,
# over a box where NOTHING was archived, on the one path where the disk stops existing. It is mechanically
# producible (`pi-bootstrap/setup.sh` farms with `cp -f`), and no arm covered it, so the `-s` guard itself
# looked sufficient. The candidate must now BEHAVE in the reader mode this hook already relies on.
# E9A is the exact truncation shape — a file that parses, and exits 0 printing nothing.
echo; echo "── E9. a sweep that PARSES but does not ANSWER is not a sweep ──"
mk_world e9 || { echo "❌ fixture failed (e9)"; exit 1; }
D="$T/e9"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$D/repo/scripts/wip-sweep.sh"
chmod +x "$D/repo/scripts/wip-sweep.sh"
echo alive > "$D/alive"
run_quiesce e9 0; RC=$?
# ⛔ THE SELECTION LINE IS WHAT THIS ARM READS, not the later FATAL: with a parse-only guard the inert
# candidate IS selected and produces its own `FATAL: wip-sweep` downstream (an exit-0 pass that wrote no
# record is refused by F6), so a FATAL grep passes for the WRONG reason. Measured on the parse-only mutant:
# E9b/E9e/E9e2 reddened and E9a stayed green until it was pointed at the `wip-sweep: <none found` line.
grep -q 'wip-sweep: <none found' "$D/out" \
  && ok "E9a a PARSING-but-INERT sweep is NOT SELECTED (it parses, so -s + bash -n accepted it before)" \
  || bad "E9a an inert sweep was selected: $(grep -m1 '^  wip-sweep:' "$D/out")"
grep -q 'FATAL: wip-sweep' "$D/out" \
  && ok "E9a2 …and it is refused loudly, with a FATAL naming the sweep" \
  || bad "E9a2 the inert sweep was not refused loudly"
grep -q 'WORK ON THIS BOX WILL NOT BE ARCHIVED' "$D/out" \
  && ok "E9a3 …and the hook says the work will not be archived" \
  || bad "E9a3 the inert-sweep path did not state the consequence"
grep -q 'every dirty worktree' "$D/out" \
  && bad "E9b the hook still claimed the work was archived on origin over an inert sweep" \
  || ok "E9b …and it never claims 'every dirty worktree … is archived on origin' off an inert candidate"
[ "$RC" -ne 0 ] \
  && ok "E9c an inert sweep makes the run non-zero (rc=$RC)" \
  || bad "E9c an inert sweep exited 0 — the false PASS this arm exists for"
grep -q 'DONE — cell has exactly one controller' "$D/out" \
  && bad "E9d it printed DONE over an inert sweep" \
  || ok "E9d …and no DONE line, so the run cannot be read as a completed archive"
# E9e: THE SKIP ITSELF, POSITIVELY. An inert FIRST candidate must not disable the hook — a faithful candidate
# later in the list (the farmed $HOME path) has to be selected and invoked. That proves the probe SKIPS a
# bad candidate instead of refusing the hook outright, which a blanket refusal would also satisfy.
mk_world e9e || { echo "❌ fixture failed (e9e)"; exit 1; }
D="$T/e9e"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$D/repo/scripts/wip-sweep.sh"
chmod +x "$D/repo/scripts/wip-sweep.sh"
mkdir -p "$D/home/.pi/agent/scripts"
printf '%s\n' '#!/usr/bin/env bash' \
  'if [ "$1" = "--print-status" ]; then echo "status=never"; echo "rc=3"; echo "detail=no pass record at (stub)"; exit 3; fi' \
  'echo "sweep:$*" >> "'"$D"'/events"' \
  'mkdir -p "'"$D"'/O/state" 2>/dev/null; printf "unpushed_worktrees=0\n" > "'"$D"'/O/state/wip-sweep.status"' \
  'exit 0' > "$D/home/.pi/agent/scripts/wip-sweep.sh"
chmod +x "$D/home/.pi/agent/scripts/wip-sweep.sh"
echo alive > "$D/alive"
run_quiesce e9e 0; RC=$?
grep -q '^sweep:--apply' "$D/events" \
  && ok "E9e an INERT first candidate is SKIPPED — the faithful candidate after it is the one that is armed" \
  || bad "E9e the inert candidate was taken: nothing was armed (a parse-only guard stops at it)"
[ "$RC" -eq 0 ] \
  && ok "E9e2 …and the run still succeeds, so one truncated farm copy does not disable the hook" \
  || bad "E9e2 the run exited $RC although a usable candidate existed: $(tail -2 "$D/out")"

# ── the success arm (exit code is only judgeable where /proc exists) ─────────────────────────────────
echo; echo "── F. the success path ──"
mk_world f || { echo "❌ fixture failed (f)"; exit 1; }
D="$T/f"
echo alive > "$D/alive"
run_quiesce f 0; RC=$?
grep -q '^supervisor:start' "$D/events" \
  && ok "F1 the controller was started" || bad "F1 the controller was never started"
if [ "$HAS_PROC" = 1 ]; then
  [ "$RC" -eq 0 ] && ok "F2 an armed sweep that succeeded exits 0" || bad "F2 success path exited $RC (want 0): $(tail -3 "$D/out")"
  grep -q 'DONE — cell has exactly one controller' "$D/out" \
    && ok "F3 it says DONE" || bad "F3 no DONE line: $(tail -2 "$D/out")"
else
  skip "F2/F3 the success path's EXIT CODE needs /proc/<pid>/environ (step 7), absent on this host — the ordering arms above still ran"
fi

# ⛔ F4/F5 — EXIT 0 IS NOT "THE WORK IS ON ORIGIN" (#3588 review, cycle 8). The sweep exits 0 when
# `unpushed_worktrees>0`, and that is right for the sweep (it cannot archive commits). The defect was in
# THIS hook: it read only the exit code, so a lane that committed and never pushed has a clean tree —
# nothing dirty, nothing archived, sweep exit 0 — and the quiesce printed DONE and exited 0 over commits
# that then died with the VM. The counter was already in the record; nothing read it. F5 covers the other
# half: a record that cannot be read is UNVERIFIED, never zero.
echo; echo "── F4/F5. exit 0 does not mean the work is on origin — the pass record decides ──"
if [ "$HAS_PROC" = 1 ]; then
  mk_world f4 || { echo "❌ fixture failed (f4)"; exit 1; }
  D="$T/f4"
  echo alive > "$D/alive"
  SWEEP_UNPUSHED=2 run_quiesce f4 0; RC=$?
  [ "$RC" -ne 0 ] \
    && ok "F4 a green sweep whose record says unpushed_worktrees=2 makes the quiesce NOT DONE (rc=$RC)" \
    || bad "F4 the quiesce exited 0 over 2 worktrees whose commits exist ONLY on this disk"
  grep -q 'DONE — cell has exactly one controller' "$D/out" \
    && bad "F5 it still printed DONE over unpushed commits" \
    || ok "F5 …and it never printed the DONE line, so a clean summary cannot be read off it"
  grep -q 'ONLY on this disk' "$D/out" \
    && ok "F5b …and it names the reason: commits that no remote has" \
    || bad "F5b the refusal does not say WHY: $(tail -2 "$D/out")"
  # ⛔ THE COUNT ITSELF, not merely the refusal: F4 alone passes on ANY fail-closed implementation (a
  # missing record also refuses), so it does not discriminate "read the count" from "regard everything as
  # unverifiable". Measured: blanking the record path left F4 AND F5 green and only F5b red. Requiring the
  # number in the message is what proves the count was parsed and carried.
  grep -q '2 worktree(s) hold commit(s)' "$D/out" \
    && ok "F5c …and it carries the COUNT (2), so the record was parsed rather than the whole path refused" \
    || bad "F5c the refusal does not carry the count from the record: $(tail -2 "$D/out")"

  mk_world f6 || { echo "❌ fixture failed (f6)"; exit 1; }
  D="$T/f6"
  echo alive > "$D/alive"
  SWEEP_NO_RECORD=1 run_quiesce f6 0; RC=$?
  [ "$RC" -ne 0 ] \
    && ok "F6 exit 0 with NO pass record is NOT DONE (rc=$RC) — unverified is never read as zero" \
    || bad "F6 an unreadable record was treated as 'nothing unpushed' and the quiesce exited 0"
  grep -q 'CANNOT be verified' "$D/out" \
    && ok "F6b …and it says the archive cannot be verified, so the operator knows what is unknown" \
    || bad "F6b the missing-record refusal does not say the state is unverified: $(tail -2 "$D/out")"

  # ⛔ F7 — A STALE RECORD MUST NOT SATISFY THE CHECK (#3588 review, cycle 8, second pass). F6 used a
  # FRESH world, so it only covered "no record ever existed". The reachable shape is a record left by an
  # EARLIER pass saying `unpushed_worktrees=0`, with the tool resolved for THIS pass writing nothing: the
  # hook would then grade the previous moment and print DONE over commits it never counted. The fixture
  # plants exactly that leftover, and the stub is told not to write — so this reddens if the hook ever
  # stops removing the previous record before invoking the sweep.
  mk_world f7 || { echo "❌ fixture failed (f7)"; exit 1; }
  D="$T/f7"
  mkdir -p "$D/O/state"
  printf 'unpushed_worktrees=0\n' > "$D/O/state/wip-sweep.status"   # the LAST pass's verdict, left behind
  echo alive > "$D/alive"
  SWEEP_NO_RECORD=1 run_quiesce f7 0; RC=$?
  [ "$RC" -ne 0 ] \
    && ok "F7 a LEFTOVER record from an earlier pass does NOT satisfy DONE (rc=$RC) — absence is re-measured, not inherited" \
    || bad "F7 the hook printed DONE off a stale record left by a previous pass, over work this pass never counted"
  grep -q 'CANNOT be verified' "$D/out" \
    && ok "F7b …and it refuses with the unverified message, not the stale pass's verdict" \
    || bad "F7b the stale-record path refused for some other reason: $(tail -2 "$D/out")"
else
  skip "F4/F5/F6 the record arms need the same /proc read-back as F2 — the unconditional-archive arm H still ran"
fi

# ⛔ H — THE ARCHIVE IS UNCONDITIONAL; THE INVARIANT GOVERNS THE RESTART (#3588 review, cycle 8). The
# stray-controller check (`LEFT != 0` → `exit 1`) used to sit BEFORE the archive, so one process whose
# argv contains `orch-loop.sh` — a wind-down after TERM, a `tail -f` of its log, a monitor grepping it —
# made the quiesce exit having archived NOTHING, with a FATAL that named only the stray. Data preservation
# is unconditional; refusing to REOPEN a cell that still has a controller is what the check is for, and it
# still aborts. Nothing pinned `LEFT != 0` (the ps stub always cleared on the kill sweep), which is how the
# ordering stayed wrong. H uses $d/survive to keep the stub reporting an orch-loop past the kill sweep.
echo; echo "── H. the WIP archive runs even when a surviving controller aborts the restart ──"
mk_world habort || { echo "❌ fixture failed (habort)"; exit 1; }
D="$T/habort"
echo alive > "$D/alive"
: > "$D/survive"
run_quiesce habort 0; RC=$?
grep -q '^sweep:' "$D/events" \
  && ok "H1 the WIP archive STILL RAN despite the surviving controller (the abort used to skip it entirely)" \
  || bad "H1 the surviving-controller abort skipped the archive — every dirty worktree on this cell was left local-only: $(tr '\n' ' ' < "$D/events")"
[ "$RC" -ne 0 ] \
  && ok "H2 …and the quiesce still REFUSES (rc=$RC) — the invariant is kept, it just no longer preempts the rescue" \
  || bad "H2 a surviving controller exited 0"
grep -q 'survived the kill sweep' "$D/out" \
  && ok "H3 the abort names the KILL sweep, so it cannot be misread as the WIP sweep" \
  || bad "H3 the abort message still says only 'survived the sweep': $(grep -m1 FATAL "$D/out")"
grep -q '^supervisor:start' "$D/events" \
  && bad "H4 the quiesce restarted supervision with a stray controller alive" \
  || ok "H4 …and supervision was NOT restarted, so the ordering fix did not weaken the invariant"
grep -q 'HAD already run' "$D/out" \
  && ok "H5 the abort states the archive's own verdict, so 'nothing was at risk' cannot be inferred from it" \
  || bad "H5 the abort does not say whether the archive ran: $(grep -m2 'FATAL\|archive' "$D/out")"

# ⛔ G) A REFUSAL IS NOT A PASS, PINNED BY RE-RUNNING THIS SUITE (#3588 review). The stub preflight above
# refuses when $TMPDIR cannot hold executable stubs (a noexec /tmp). It used to `exit 0` there, so a shard
# that ran ZERO arms reported GREEN. Nothing reddened when that was reverted (measured: PASS=17 FAIL=0),
# because the refusal branch is unreachable on a host whose $TMPDIR is healthy — the only way to reach it is
# to re-invoke this file with an unusable TMPDIR, which also proves the preflight cannot be talked past by
# the very environment it exists to detect.
echo; echo "── G. the preflight refuses with a NON-ZERO exit when it cannot prove its stubs ──"
SELFQ="${BASH_SOURCE[0]}"
QG="$(TMPDIR=/nonexistent-quiesce-preflight-probe bash "$SELFQ" 2>&1)"; QRC=$?
[ "$QRC" -ne 0 ] && grep -q 'REFUSING TO RUN' <<<"$QG" \
  && ok "G1 an unusable \$TMPDIR makes the preflight exit NON-ZERO (rc=$QRC) — a shard that ran zero arms is RED, not green" \
  || bad "G1 the preflight answered rc=$QRC with no refusal message when it could not run a single arm: $(tail -3 <<<"$QG")"
grep -q 'PASS=0 FAIL=0 SKIP=0' <<<"$QG" \
  && ok "G2 and it says so plainly (PASS=0 FAIL=0 SKIP=0), so the exit code and the words agree" \
  || bad "G2 the refusal message does not state that nothing ran: $(tail -3 <<<"$QG")"

echo
echo "── summary ──"
echo "  PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
