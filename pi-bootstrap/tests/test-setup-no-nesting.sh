#!/bin/bash
# ============================================================
# test-setup-no-nesting.sh — regression test for issue #93
#
# Verifies that pi-bootstrap/setup.sh:
#   (a) never NESTS cp -R copies into existing destination dirs
#       (BSD `cp -R SRC DEST` with an existing DEST creates
#        dest/agents/agents/... and never updates the active files);
#   (b) refreshes the ACTIVE ~/.pi/agent files on re-runs (repo
#       updates flow in, dest mutations get overwritten by source);
#   (c) preserves the extension/skills symlink farm regardless of
#       the repo's clone path (realpath comparison, not a
#       "/agent-infra" path substring).
#
# Runs the REAL setup.sh against a temp HOME. npm is stubbed so the
# test is hermetic and needs no network. The repo itself is only read
# (a single temporary marker file is added to pi-config and removed
# on exit via trap).
#
# Usage:  bash pi-bootstrap/tests/test-setup-no-nesting.sh
# Exit:   0 = all assertions passed, 1 = at least one failure.
# ============================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/pi-setup-test.XXXXXX")"
HOME_DIR="$TMP/home"
CLONE="$TMP/repos/clone"          # symlink alias of the repo — no "agent-infra" in path
DEST="$HOME_DIR/.pi/agent"
RUNS_LOG="$TMP/runs.log"
FAILURES=0
SRC_MARKER=""                     # set later; guarded in cleanup

cleanup() {
  [ -n "$SRC_MARKER" ] && rm -f "$SRC_MARKER"
  rm -rf "$TMP"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $1" >&2
  FAILURES=$((FAILURES + 1))
}

# --- hermetic environment -------------------------------------------------
mkdir -p "$HOME_DIR" "$TMP/bin" "$TMP/repos"
cat > "$TMP/bin/npm" <<'EOF'
#!/bin/bash
# Stub: setup.sh runs `npm install` per extension; keep the test offline.
exit 0
EOF
chmod +x "$TMP/bin/npm"
# #446 regression: this test runs the REAL setup.sh under a temp HOME, and
# setup.sh invokes scripts/install-launchd.sh (real launchd, real gui domain).
# Pre-fix, install-launchd bootstrapped the REAL domain with temp-home plists
# whose paths die with this test's TMP dir — observed: provider-latency-
# tripwire registered to a deleted pi-setup-test.*/home path, runs=0 (#446).
# Two-layer defense: (1) this shim shadows the real launchctl so ANY call is
# recorded (exit 99 — a call is a test failure by definition); (2) the
# installer's own temp-HOME guard refuses before calling launchctl, so the
# shim log stays empty. A non-empty log or a missing guard message fails the
# test. The installer happy-path stays covered hermetically by
# scripts/install-launchd.test.sh (fake HOME + shim + ELDATO_ALLOW_TEST_HOME=1).
cat > "$TMP/bin/launchctl" <<'EOF'
#!/bin/bash
# #446: real launchctl must NEVER be reachable from this temp-HOME setup test.
echo "UNEXPECTED launchctl call: $*" >> "${LAUNCHCTL_LOG:?}"
exit 99
EOF
chmod +x "$TMP/bin/launchctl"
export LAUNCHCTL_LOG="$TMP/launchctl.log"
: > "$LAUNCHCTL_LOG"
export PATH="$TMP/bin:$PATH"
export HOME="$HOME_DIR"

# Run setup.sh from a clone path that does NOT contain "agent-infra", proving
# farm-link recognition is realpath-based, not substring-based.
ln -s "$ROOT" "$CLONE"

# Pre-created farm links, both spellings:
#   1. target via the clone path (no "agent-infra" substring) — old code missed this
#   2. target via the physical repo path (like the live farm) — old code passed by luck
mkdir -p "$DEST/extensions"
ln -s "$CLONE/extensions/mcp-client" "$DEST/extensions/mcp-client"
ln -s "$ROOT/extensions/shared"      "$DEST/extensions/shared"

# --- helpers --------------------------------------------------------------
# Assert no directory exists whose basename equals its parent's basename
# (the `dest/agents/agents` nesting signature) under $1.
check_no_nesting() {
  local base="$1" label="$2" found d
  found="$(find "$base" -type d -print 2>/dev/null | while IFS= read -r d; do
    if [ "$(basename "$(dirname "$d")")" = "$(basename "$d")" ]; then
      echo "$d"
    fi
  done)"
  if [ -n "$found" ]; then
    fail "$label: self-nesting directories found under $base:"
    echo "$found" >&2
  else
    echo "ok: no self-nesting under $base"
  fi
}

# Assert every materialized extension under $1 matches extensions/ byte-for-byte
# (single source of truth, issue #95). Entries named after $2... are skipped
# (they are farm symlinks in this run, not materialized copies). Test files are
# never shipped (pi-config wires only real extensions).
check_content_matches() {
  local dest_ext="$1" label="$2" base e s
  shift 2
  for e in "$ROOT"/extensions/*; do
    [ -e "$e" ] || continue
    base="$(basename "$e")"
    case "$base" in
      *.test.ts) continue ;;
    esac
    for s in "$@"; do
      [ "$s" = "$base" ] && continue 2
    done
    [ -e "$dest_ext/$base" ] || { fail "$label: installed $base missing"; continue; }
    if diff -rq "$e" "$dest_ext/$base" >/dev/null 2>&1; then
      echo "ok: $label installed $base == extensions/$base"
    else
      fail "$label: installed $base differs from extensions/$base (stale copy!)"
    fi
  done
}

# Assert the #36/#101 fixes are present in the INSTALLED code (the exact drift
# issue #95 caught: fresh machines shipping pre-fix extensions).
check_fix_markers() {
  local ext="$1" label="$2"
  grep -q "getSubAgentPath" "$ext/subagent/index.ts" \
    || fail "$label: installed subagent missing getSubAgentPath (#101 fix not shipped)"
  grep -q "#36" "$ext/builtin-tools/index.ts" \
    || fail "$label: installed builtin-tools missing #36 PATH augmentation"
}

# #562 — merge-gate scripts farm parity: record-review.sh must be farmed to
# $DEST/scripts/ and byte-match the repo copy (the repo copy is CI-tested;
# production mints execute the ~/.pi copy — drift is a silent partial
# deployment of an enforcement-critical script).
check_record_review_farmed() {
  local label="$1"
  local dest="$DEST/scripts/record-review.sh"
  [ -f "$dest" ] \
    || { fail "$label: record-review.sh not farmed into scripts/ (merge-gate farm missing)"; return; }
  if diff -q "$ROOT/scripts/record-review.sh" "$dest" >/dev/null 2>&1; then
    echo "ok: $label farmed record-review.sh == repo copy (#562)"
  else
    fail "$label: farmed record-review.sh differs from scripts/record-review.sh (stale copy!)"
  fi
  # #1362 D1 — record-review.sh resolves its diff normalizer from a SIBLING
  # directory (`<script dir>/lib/diff-normalize.py`). Farming the producer
  # without the normalizer degrades it to the raw pre-#1362 digest, so the
  # sibling must be farmed too and byte-match the repo copy.
  local norm="$DEST/scripts/lib/diff-normalize.py"
  [ -f "$norm" ] \
    || { fail "$label: lib/diff-normalize.py not farmed into scripts/lib/ (#1362 normalizer farm missing)"; return; }
  if diff -q "$ROOT/scripts/lib/diff-normalize.py" "$norm" >/dev/null 2>&1; then
    echo "ok: $label farmed lib/diff-normalize.py == repo copy (#1362)"
  else
    fail "$label: farmed lib/diff-normalize.py differs from scripts/lib/diff-normalize.py (stale copy!)"
  fi
}

# #1719 — the runner-label gate is the FALLBACK when GitHub-hosted CI is unhealthy: the launchd
# job com.tortoise.ci-runner-gate executes $DEST/scripts/ci_runner_gate.sh. Farming is what makes
# the REPO copy the copy that runs — without it the box keeps executing a hand-made duplicate (a
# merged fix never reaches it) and a second box has no fallback gate at all.
check_ci_runner_gate_farmed() {
  local label="$1"
  local dest="$DEST/scripts/ci_runner_gate.sh"
  [ -f "$dest" ] \
    || { fail "$label: ci_runner_gate.sh not farmed into scripts/ — the launchd job would execute a hand-made duplicate (#1719)"; return; }
  if diff -q "$ROOT/scripts/ci_runner_gate.sh" "$dest" >/dev/null 2>&1; then
    echo "ok: $label farmed ci_runner_gate.sh == repo copy (#1719)"
  else
    fail "$label: farmed ci_runner_gate.sh differs from scripts/ci_runner_gate.sh (stale copy!)"
  fi
}

# #1552 — pin the `fleet_srcs` farm's DECLARED list, because "the array says it" and "the box has
# it" are different claims and nothing sat between them. The loop that consumes the array SKIPS an
# entry whose repo file is absent (`[ -f "$f" ] || continue`), so a declared-but-unlanded entry fails
# SILENT; and the farm's whole purpose is that the REPO copy is the copy that RUNS, so a stale
# destination is the failure it exists against. 27 of the 36 entries joined in #1552 (the laptop-only
# lane layer: ask-owner.py, lane-guard.py, safe-send.sh, turn-classify.py, orchestrator-heartbeat.sh
# and the rest).
#
# ⚠️ SCOPE — what this guard does NOT cover, stated so nobody over-reads the green:
#   * It pins the DECLARED set only. The COMPLETENESS half — "is every producer of this layer in some
#     farm array at all?" — is `check_producer_farm_declared` below, added because this function
#     cannot see a producer that NO array declares: a fresh farm came to carry every CONSUMER without
#     the executable it calls (five producers joined `fleet_srcs` on 2026-10-16 for exactly that
#     reason). Two remain a DECLARED gap, named there.
#   * It cannot see a stale DEPLOYED copy or an un-restarted long-lived process: it diffs repo bytes
#     against a $DEST that THIS run just populated. #1738 is the NEAR-MISS that prompted looking for
#     this gap, NOT an instance of it: #1738's own evidence records the deployed file as
#     BYTE-IDENTICAL to origin/main, so the DEPLOYED COPY WAS CURRENT (delivered by some path other
#     than this farm — `lane-watchdog.py` was in no farm array when #1738 was diagnosed; it joined
#     `fleet_srcs` in #1552) — what failed there was the
#     INVOCATION. (The mechanism WAS found, in a later comment on #1738 titled "Root cause — found,
#     and fixed in production": bash's parse-once semantics — the running loop had already parsed its
#     body, so the edited launch block was never reached. That is a DIFFERENT mechanism from
#     repo↔live identity, which is the point: #1738's deployed bytes were correct.) So #1738 must not
#     be cited as a repo↔live identity failure; that instrument is #1760/#1759's, not this one.
check_fleet_srcs_farmed() {
  local label="$1"
  local line entry dest checked=0 declared=0
  line="$(sed -n 's/^fleet_srcs=(\(.*\))$/\1/p' "$ROOT/pi-bootstrap/setup.sh")"
  [ -n "$line" ] \
    || { fail "$label: could not read the fleet_srcs array from setup.sh (wrapped across lines? — ci_runner_gate.test.sh reads it the same way)"; return; }
  for entry in $line; do
    declared=$((declared+1))
    [ -f "$ROOT/scripts/$entry" ] \
      || { fail "$label: fleet_srcs declares '$entry' but scripts/$entry does not exist — the farm skips it SILENTLY"; continue; }
    dest="$DEST/scripts/$entry"
    [ -f "$dest" ] \
      || { fail "$label: fleet_srcs entry '$entry' was NOT farmed into scripts/ (silent skip)"; continue; }
    if diff -q "$ROOT/scripts/$entry" "$dest" >/dev/null 2>&1; then
      checked=$((checked+1))
    else
      fail "$label: farmed $entry differs from scripts/$entry (stale copy!)"
    fi
  done
  # The summary must never print `ok:` on a run that failed entries (review: an `ok:` beside a
  # FAIL is the same false-clean read this whole function exists to close), so the prefix is
  # decided by the count, not printed unconditionally. `declared -gt 0` is required too: a
  # whitespace-only array (`fleet_srcs=( )`) makes the anchored sed capture " ", runs the loop
  # zero times, and would otherwise satisfy `0 -eq 0` and report a clean 0/0 — the maximal
  # silent skip reported as green (review finding, mutation-verified).
  if [ "$declared" -gt 0 ] && [ "$checked" -eq "$declared" ]; then
    echo "ok: $label fleet_srcs farm byte-identical for $checked/$declared declared entries (#1552)"
  else
    echo "PARTIAL: $label fleet_srcs farm verified only $checked/$declared declared entries (#1552)"
    # `PARTIAL:` is a summary line, not a failure token — so on its own the guard would still exit 0
    # on a zero-declared array (a sibling assertion catches it today only incidentally). Make the
    # summary authoritative: zero declared entries IS the failure.
    [ "$declared" -gt 0 ] \
      || fail "$label: fleet_srcs declared ZERO entries — array empty or unreadable, and 0/0 must never read as clean"
  fi
}

# #1552 — PRODUCER COMPLETENESS, the half `check_fleet_srcs_farmed` cannot do. That function pins
# whatever the array DECLARES and therefore reports a clean "N/N" for a farm whose CONSUMERS are all
# present and whose PRODUCERS are all undelivered. Measured 2026-10-16: the layer's seven versioned
# producers were in NO farm array, so a fresh `$DEST/scripts` got `pr-doctor.py`/`lane-scan-fallback.sh`
# without the `lane-actions.py` they exec, `cadence-timer.sh` without `cadence-nudge.sh`,
# `live-workspaces-publisher.py` without `publish-live-workspaces.py`, and `orchestrator-heartbeat.sh`
# without `objective.py`. Five were then added to `fleet_srcs` (the fifth, `lane-watchdog.py`, AHEAD of
# #1553 rather than for a farmed caller — its only caller `heartbeat-loop.sh` is the withheld file);
# this check is what keeps a producer from silently falling out again.
#
# ⚠️ DECLARED GAP (2 of 7) — deliberate, and named so it cannot go quiet:
#   * `lane-status.py` — the DESTINATION copy is AHEAD (repo 1993 lines / live 2005 at the 2026-10-15
#     measurement; the live copy carries the #1777 abstention text, in flight in #1784), so farming
#     the repo copy would regress the running classifier.
#   * `heartbeat-loop.sh` — byte-identical repo↔live, held back only because `lane-status.py` is.
# #1553 declares both in `lane_root_srcs`. Once it lands, both take the membership branch below and
# `LANE_PRODUCERS_EXEMPT` becomes inert — delete it then, so this check covers all seven with no gap.
LANE_PRODUCERS="lane-status.py lane-actions.py lane-watchdog.py objective.py heartbeat-loop.sh cadence-nudge.sh publish-live-workspaces.py"
# The published population, on its own line because the list above is the guard's SUBJECT: a shrunk (or
# emptied) list makes the loop below run fewer (or zero) times and leaves `missing` empty, so the
# summary would otherwise report a clean 0/0 — the maximal silent skip, read as green. This pins the
# count the list must carry, so DROPPING a producer is a failure, not a quieter green.
LANE_PRODUCERS_EXPECTED=7
# ...and the CANONICAL SET, because the count alone is not the claim. A count-preserving substitution —
# DROP `objective.py` and DUPLICATE `lane-actions.py`, still seven entries — keeps `considered` at 7 and
# `missing` empty, so it passed every check while `objective.py` went unguarded and printed the
# byte-identical `DECLARED-GAP` line (review H7, PR #1855). The membership check below compares the
# sorted names against this set, so a drop, a duplicate, an addition and a rename all fail alike.
LANE_PRODUCERS_CANONICAL="lane-status.py lane-actions.py lane-watchdog.py objective.py heartbeat-loop.sh cadence-nudge.sh publish-live-workspaces.py"
LANE_PRODUCERS_EXEMPT="lane-status.py heartbeat-loop.sh"
# Whole-word membership, the `ci_runner_gate.test.sh` idiom: a plain `grep -F` for the basename is
# also satisfied by `lane-actions.py.old`, i.e. by the exact rename that leaves the producer
# undelivered. `tr` splits the array on whitespace, `grep -Fxq` requires the whole entry.
farm_declares() { # <array-name> <entry> [<setup.sh>] -> 0 when the array carries the entry as a whole word
  local arr="$1" entry="$2" file="${3:-$ROOT/pi-bootstrap/setup.sh}" line
  line="$(sed -n "s/^${arr}=(\(.*\))$/\1/p" "$file")"
  [ -n "$line" ] || return 1
  printf '%s\n' "$line" | tr -s ' ' '\n' | grep -Fxq -- "$entry"
}
check_producer_farm_declared() {
  local label="$1" p covered=0 exempted=0 missing="" considered=0 floor_ok=1 exempted_names=""
  for p in $LANE_PRODUCERS; do
    considered=$((considered+1))
    # `lane_root_srcs` absent on this tree is not a failure: #1553 declares it, and the membership
    # branch simply goes false until then.
    if farm_declares fleet_srcs "$p" || farm_declares lane_root_srcs "$p"; then
      covered=$((covered+1)); continue
    fi
    case " $LANE_PRODUCERS_EXEMPT " in
      *" $p "*) exempted=$((exempted+1)); exempted_names="$exempted_names $p"; continue ;;
    esac
    missing="$missing $p"
  done
  # POPULATION FLOOR — the sibling `check_fleet_srcs_farmed` pins `declared -gt 0` for the same
  # reason: with a shrunk or emptied list the loop runs fewer (or zero) times, `missing` stays empty,
  # and `0/0` reads exactly like full coverage. Assert the published count, so a DROPPED producer
  # fails rather than reporting a quieter green.
  if [ "$considered" -lt 1 ] || [ "$considered" -ne "$LANE_PRODUCERS_EXPECTED" ]; then
    fail "$label: LANE_PRODUCERS carries $considered of $LANE_PRODUCERS_EXPECTED producers — an empty or undersized list must never read as clean (#1552)"
    floor_ok=0
  fi
  # SET BINDING (review H7) — the count floor above is blind to a COUNT-PRESERVING substitution, which
  # is the shape a producer can actually be lost in (the shape the H7 probe exercises). Compare the
  # sorted names to the canonical set so the guard's SUBJECT is bound, not merely its size.
  local actual_set canonical_set
  actual_set="$(printf '%s\n' $LANE_PRODUCERS | sort)"
  canonical_set="$(printf '%s\n' $LANE_PRODUCERS_CANONICAL | sort)"
  if [ "$actual_set" != "$canonical_set" ]; then
    fail "$label: LANE_PRODUCERS is not the canonical producer set — a dropped, duplicated, added or renamed producer must never read as clean (got:$(printf ' %s' $LANE_PRODUCERS)) (#1552)"
    floor_ok=0
  fi
  [ -z "$missing" ] \
    || fail "$label: lane producer(s) declared by NO farm array:$missing — a fresh \$DEST/scripts gets the farmed consumer without the executable it calls (#1552)"
  if [ "$floor_ok" -eq 1 ] && [ -z "$missing" ] && [ "$exempted" -gt 0 ]; then
    # Never `ok:` while a declared gap remains: the two are separately delivered by #1553, and a
    # reader must not read 5/7 as full cover. Echo the names ACTUALLY exempted THIS run, never the
    # static list: after a partial #1553 landing a full-list echo contradicts its own count.
    echo "DECLARED-GAP: $label lane producers in a farm array: $covered/$((covered+exempted)) ($exempted not carried here, owned by #1553:$exempted_names) (#1552)"
  elif [ "$floor_ok" -eq 1 ] && [ -z "$missing" ]; then
    echo "ok: $label all $((covered+exempted)) lane producers declared in a farm array (#1552)"
  fi
}

# #1863 × #1552 merge — the orphan reaper's farm membership is the OTHER half of the same
# `fleet_srcs` line, and it cannot be inferred from the producers above. The branch's
# `pi-reap-orphans.sh` entry and main's five producers were added on OPPOSITE sides of that one
# line, so a merge resolution that takes either side whole silently keeps one and drops the other
# — and `check_fleet_srcs_farmed` cannot see the drop: it iterates WHATEVER the array declares, so
# a missing reaper is a SMALLER GREEN (N/N of N), never a FAIL. That is the false-clean shape
# #1552's producer floor closes, applied to #1862's fix: the launchd job com.eldato.pi-reap-orphans
# execs `$DEST/scripts/pi-reap-orphans.sh`, so a farm that does not carry it schedules a job whose
# script is absent — the reaper dead at the destination, the exact defect #1862 exists to fix.
check_orphan_reaper_farmed() { # [<label>] [<setup.sh>]
  local label="${1:-run1}" setup_file="${2:-$ROOT/pi-bootstrap/setup.sh}" entry="pi-reap-orphans.sh"
  if ! farm_declares fleet_srcs "$entry" "$setup_file"; then
    fail "$label: '$entry' is declared by NO farm array — the com.eldato.pi-reap-orphans job execs \$DEST/scripts/$entry, so the farm would schedule a job whose script is missing (#1862/#1863)"
    return
  fi
  [ -f "$ROOT/scripts/$entry" ] \
    || { fail "$label: fleet_srcs declares '$entry' but scripts/$entry does not exist — the farm skips it SILENTLY"; return; }
  [ -f "$DEST/scripts/$entry" ] \
    || { fail "$label: '$entry' is declared but was NOT farmed into \$DEST/scripts (silent skip) — the scheduled job would find no script"; return; }
  echo "ok: $label the orphan reaper is DECLARED in fleet_srcs and farmed (#1862/#1863)"
}

# NON-VACUITY PROBE for the check above: it must FIRE on an array that lacks the reaper. Runs against
# a THROWAWAY copy of setup.sh with `pi-reap-orphans.sh` removed, so the real file is never
# perturbed; FAILURES is restored exactly as in `producer_floor_probe`.
orphan_probe() { # <probe-label> <setup-copy> -> prints the FAILURES delta
  local saved_failures="$FAILURES" delta
  check_orphan_reaper_farmed "$1" "$2" >/dev/null 2>&1
  delta=$((FAILURES - saved_failures))
  FAILURES="$saved_failures"
  printf '%s' "$delta"
}
PROBE_SETUP_NO_REAPER="$TMP/setup-no-reaper.sh"
sed 's/ pi-reap-orphans\.sh//' "$ROOT/pi-bootstrap/setup.sh" > "$PROBE_SETUP_NO_REAPER"
# Test the ARRAY, not the whole file: `pi-reap-orphans.sh` also appears in setup.sh's comments, so a
# whole-file grep would refuse a correctly-built fixture.
if sed -n 's/^fleet_srcs=(\(.*\))$/\1/p' "$PROBE_SETUP_NO_REAPER" | tr -s ' ' '\n' | grep -Fxq -- 'pi-reap-orphans.sh'; then
  fail "probe fixture's fleet_srcs still carries pi-reap-orphans.sh — the reaper-membership non-vacuity probe cannot run"
elif [ "$(orphan_probe "reaper-probe-absent" "$PROBE_SETUP_NO_REAPER")" -gt 0 ]; then
  echo "ok: the reaper-membership guard FIRES when pi-reap-orphans.sh is absent from fleet_srcs (non-vacuous)"
else
  fail "the reaper-membership guard did NOT fire on an array without pi-reap-orphans.sh — it reads absent as clean"
fi

# H1 (review, PR #1855) — pin that the POPULATION FLOOR above actually FIRES. The guard's whole
# subject is "a producer no array declares", so an emptied or shrunk `LANE_PRODUCERS` is the maximal
# silent skip; without the floor it reports a clean 0/0 (or N/N). Each probe runs in a SUBSHELL with a
# stderr-suppressed call, so it can read the FAILURES delta without perturbing this suite's counter.
producer_floor_probe() { # <probe-label> <producer-list> -> prints the FAILURES delta
  local saved_list="$LANE_PRODUCERS" saved_failures="$FAILURES" delta
  LANE_PRODUCERS="$2"
  check_producer_farm_declared "$1" >/dev/null 2>&1
  delta=$((FAILURES - saved_failures))
  FAILURES="$saved_failures"
  LANE_PRODUCERS="$saved_list"
  printf '%s' "$delta"
}
if [ "$(producer_floor_probe "floor-probe-empty" "")" -gt 0 ]; then
  echo "ok: an EMPTY LANE_PRODUCERS trips the population floor (0/0 never reads as clean)"
else
  fail "an EMPTY LANE_PRODUCERS did NOT trip the population floor — the guard read 0/0 as clean"
fi
# Undersized: six of the seven, every one declared or exempt, so `missing` stays EMPTY and ONLY the
# floor can catch it — this is the exact shape a dropped producer takes.
if [ "$(producer_floor_probe "floor-probe-short" "lane-actions.py lane-watchdog.py objective.py heartbeat-loop.sh cadence-nudge.sh publish-live-workspaces.py")" -gt 0 ]; then
  echo "ok: an UNDERSIZED LANE_PRODUCERS (6/7) trips the population floor"
else
  fail "an UNDERSIZED LANE_PRODUCERS (6/7) did NOT trip the population floor — a dropped producer read as clean"
fi
# H7 (review, PR #1855) — COUNT-PRESERVING substitution: drop `objective.py` and duplicate
# `lane-actions.py`, so the list still carries seven entries, every one declared or exempt. The count
# floor cannot see this (`considered` is still 7) and `missing` stays empty, so ONLY the set binding
# catches it; pre-fix it printed the byte-identical `DECLARED-GAP 5/7` line.
if [ "$(producer_floor_probe "set-probe-swap" "lane-status.py lane-actions.py lane-watchdog.py lane-actions.py heartbeat-loop.sh cadence-nudge.sh publish-live-workspaces.py")" -gt 0 ]; then
  echo "ok: a COUNT-PRESERVING substitution (objective.py dropped, lane-actions.py duplicated) trips the set binding"
else
  fail "a COUNT-PRESERVING substitution did NOT trip the set binding — objective.py read as guarded while absent"
fi

# #1178 — shared-library farm: scripts/lib/pid-identity.sh must land at
# $DEST/scripts/lib/pid-identity.sh, byte-identical to the repo copy, and the
# farmed reaper (which resolves the library from its OWN sibling directory) must
# actually load it. Farming the reaper without the library re-arms the hourly
# com.eldato.pi-session-reaper job with a fail-closed exit-3 abort on every pass.
check_identity_lib_farmed() {
  local label="$1"
  local dest="$DEST/scripts/lib/pid-identity.sh"
  local reaper="$DEST/scripts/pi-reap-idle.sh"
  [ -f "$dest" ] \
    || { fail "$label: lib/pid-identity.sh not farmed into scripts/lib/ (#1178 lib farm missing)"; return; }
  if diff -q "$ROOT/scripts/lib/pid-identity.sh" "$dest" >/dev/null 2>&1; then
    echo "ok: $label farmed lib/pid-identity.sh == repo copy (#1178)"
  else
    fail "$label: farmed lib/pid-identity.sh differs from scripts/lib/pid-identity.sh (stale copy!)"
  fi
  [ -f "$reaper" ] \
    || { fail "$label: pi-reap-idle.sh missing from the farm — cannot test its library resolution"; return; }
  # The farmed reaper sources the library BEFORE it parses argv, so a missing or
  # broken library IS the exit-3 "identity library missing" abort. `--help` is
  # the read-only mode: it signals nothing and touches no store.
  local out rc
  out="$(bash "$reaper" --help 2>&1)" && rc=0 || rc=$?
  if [ "$rc" -eq 0 ] && ! grep -q "identity library missing" <<<"$out"; then
    echo "ok: $label farmed reaper resolves sibling lib/pid-identity.sh (--help rc=0)"
  else
    fail "$label: farmed reaper could not load its library (rc=$rc): $(head -1 <<<"$out")"
  fi
}

# #1178 unit 3 — fleet-tools farm: the scheduled lane-liveness report driver
# (tools/fleet/lane_liveness.py in the REPO) and its sibling classifier
# (tools/fleet/liveness.py) must land under $DEST/scripts/fleet/, byte-identical
# to the repo copies, in the layout that makes liveness.lib_path() resolve to the
# FARMED library (scripts/fleet/ <-> scripts/lib/ preserved). Farming the driver
# without the classifier is the driver's loud exit-2 "cannot import" abort on
# every 30-minute pass; farming either into a repo symlink is the #427 TCC
# failure (launchd cannot read ~/Documents).
#
# #1277: the farmed destination is scripts/fleet/, NEVER tools/fleet/. Repo
# copies stay in the repo's tools/fleet/ (pi's scan only looks at
# ~/.pi/agent/tools/) — do not rename the source directory.
check_fleet_tools_farmed() {
  local label="$1"
  local driver="$DEST/scripts/fleet/lane_liveness.py"
  local classifier="$DEST/scripts/fleet/liveness.py"
  [ -f "$driver" ] \
    || { fail "$label: lane_liveness.py not farmed into scripts/fleet/ (#1178 unit 3 farm missing)"; return; }
  [ -f "$classifier" ] \
    || { fail "$label: liveness.py not farmed beside the driver (the import would exit 2)"; return; }
  if diff -q "$ROOT/tools/fleet/lane_liveness.py" "$driver" >/dev/null 2>&1; then
    echo "ok: $label farmed lane_liveness.py == repo copy (#1178)"
  else
    fail "$label: farmed lane_liveness.py differs from tools/fleet/lane_liveness.py (stale copy!)"
  fi
  if diff -q "$ROOT/tools/fleet/liveness.py" "$classifier" >/dev/null 2>&1; then
    echo "ok: $label farmed liveness.py == repo copy (#1178)"
  else
    fail "$label: farmed liveness.py differs from tools/fleet/liveness.py (stale copy!)"
  fi
  # #1178 unit 4 — the two tools that lived ONLY as untracked files in
  # ~/.pi/agent/state/: the recovery primitive and the dead-lane reader.
  if diff -q "$ROOT/tools/fleet/fleet-health.py" "$DEST/scripts/fleet/fleet-health.py" >/dev/null 2>&1; then
    echo "ok: $label farmed fleet-health.py == repo copy (#1178 unit 4)"
  else
    fail "$label: farmed fleet-health.py differs from (or is missing vs) tools/fleet/fleet-health.py"
  fi
  if diff -q "$ROOT/tools/fleet/map-sessions.py" "$DEST/scripts/fleet/map-sessions.py" >/dev/null 2>&1; then
    echo "ok: $label farmed map-sessions.py == repo copy (#1178 unit 4)"
  else
    fail "$label: farmed map-sessions.py differs from (or is missing vs) tools/fleet/map-sessions.py"
  fi
  # The farmed driver must actually start from the farmed layout: it imports its
  # sibling classifier and forks the shared identity library. `--help` is the
  # read-only mode (no cmux call, no store read, no issue); the pinned
  # PI_PID_IDENTITY_LIB is the farmed library, never the repo's.
  local out rc
  out="$(cd "$TMP" && env HOME="$HOME_DIR" \
         PI_PID_IDENTITY_LIB="$DEST/scripts/lib/pid-identity.sh" \
         python3 "$driver" --help 2>&1)" && rc=0 || rc=$?
  if [ "$rc" -eq 0 ] && ! grep -q "cannot import" <<<"$out"; then
    echo "ok: $label farmed driver imports its classifier (--help rc=0)"
  else
    fail "$label: farmed lane-liveness driver failed to start (rc=$rc): $(head -1 <<<"$out")"
  fi
}

# #1277 — the DURABLE regression guard. pi's startup scan
# (dist/migrations.js checkDeprecatedExtensionDirs) treats ANY entry in
# ~/.pi/agent/tools/ other than fd/rg/fd.exe/rg.exe as a legacy "custom tools"
# directory. On a hit it prints a deprecation notice and then BLOCKS in an
# untimed keypress wait (showDeprecationWarnings: stdin.once("data") with no
# timeout and no end/error handler) — so one stray entry there hangs EVERY
# fresh interactive pi boot, which is the entire fleet's dispatch path. This
# asserts the FINAL state independently of setup.sh's own guard, so removing
# that guard still leaves the regression caught.
check_tools_dir_clean() {
  local label="$1" stray="" entry
  [ -d "$DEST/tools" ] \
    || { echo "ok: $label no $DEST/tools/ at all (nothing for pi's scan to reject)"; return; }
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    case "$(printf '%s' "$entry" | tr '[:upper:]' '[:lower:]')" in
      fd|rg|fd.exe|rg.exe) ;;   # pi's own auto-extracted binaries — permitted
      .*) ;;                    # hidden entries are ignored by pi's check too
      *) stray="$stray $entry" ;;
    esac
  done <<< "$(ls -A "$DEST/tools" 2>/dev/null)"
  if [ -n "$stray" ]; then
    fail "$label: $DEST/tools/ has non-fd/rg entries:$stray — pi blocks interactive boot on these (#1277)"
  else
    echo "ok: $label \$DEST/tools/ has no non-fd/rg entry (pi's startup scan stays quiet)"
  fi
}

# #1277 migration — a machine that ALREADY has the deprecated farm must end up
# without it, or the freeze persists (the farm re-created the directory within
# minutes of a local workaround, which is why the repo had to change).
check_legacy_tools_farm_removed() {
  local label="$1"
  if [ -e "$DEST/tools/fleet" ]; then
    fail "$label: deprecated $DEST/tools/fleet/ still present (the pi boot-blocker survives the migration)"
  else
    echo "ok: $label deprecated tools/fleet/ is gone (#1277 migration)"
  fi
}

# #1178 unit 4 — the PROMOTED liveness read in tools/fleet/fleet-health.py.
#
# Its `PID DEAD` used to come from `_alive(pid)` = a bare `os.kill(pid, 0)`: no
# start-time fence, no zombie rule. It now reads through the FARMED
# scripts/lib/pid-identity.sh via its sibling classifier's probe boundary (the
# same library the kill-path reaper sources). These controls pin both directions:
#
#   * the dead witness still FIRES — an absent pid, and a ZOMBIE. A zombie is the
#     crisp pre-fix failure: `os.kill(zombie, 0)` SUCCEEDS, so the bare existence
#     check read a defunct process as a live lane (no flag at all).
#   * an unresolvable read ABSTAINS as `PID ? (...)`, never `PID DEAD` — for pid
#     REUSE (off-fence), for a broken `ps`, for an unusable recorded start, and
#     when the canonical library is ABSENT. That last leg is the NEGATIVE control:
#     a "promotion" that fell back to a bare existence check prints `PID DEAD`
#     with no library on disk, and this test fails.
#   * an ABSTENTION must not SUPPRESS the quiet/CPU suspect ladder (#1178 A-class):
#     a stale lane whose identity could not be read is still a SUSPECT, never a
#     clean `✅ no suspects`. The same holds one level up: an unreadable or
#     shape-drifted HOOK STORE reports the scan INCOMPLETE with exit 1, and still
#     lists any suspect the ladder found.
#
# The positive legs are HERMETIC about the environment (see `run_promotion`), so a
# green pin also proves the scripts/fleet/ <-> scripts/lib/ RELATIVE layout survived
# the farm: move the farmed library and they degrade to `PID ? (unreadable)`.
check_fleet_health_promotion() {
  local label="$1"
  local tool="$DEST/scripts/fleet/fleet-health.py"
  local lib="$DEST/scripts/lib/pid-identity.sh"
  local phome="$TMP/prom-home"
  local sid="01a08ca6-3539-71ed-a0d7-7cee52feee03"   # lane B1 (the LANES hardcode)
  local store="$phome/.cmuxterm/pi-hook-sessions.json"
  local zpid_file="$TMP/zombie.pid" zparent="" zpid="" zstat="" out rc=0

  [ -f "$tool" ] || { fail "$label: farmed fleet-health.py missing — the promotion is unpinnable"; return; }
  [ -f "$lib" ]  || { fail "$label: farmed lib/pid-identity.sh missing — the promotion cannot load the rule"; return; }
  # fleet-health.py writes its CPU-delta cache to ~/.pi/agent/state/fleet-health-prev.json
  # and RAISES FileNotFoundError when that directory is absent (it does not create it).
  # A fresh HOME has no state/, so create the three directories the tool reads/writes.
  mkdir -p "$phome/.cmuxterm" "$phome/.pi/agent/state" "$phome/.pi/agent/sessions"
  rm -f "$zpid_file"

  # A ZOMBIE fixture: a child that exited and was never reaped, held by a live
  # parent for the duration of the checks. `os.kill(zpid, 0)` succeeds on it.
  python3 -c 'import os,sys,time
p = os.fork()
if p == 0:
    os._exit(0)
open(sys.argv[1], "w").write(str(p))
time.sleep(60)' "$zpid_file" &
  zparent=$!
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    [ -s "$zpid_file" ] && { zpid="$(cat "$zpid_file")"; break; }
    sleep 0.2
  done
  # Pin the fixture's IDENTITY, not just its pid: a zombie that gets reaped before the
  # assertion degrades to plain `absent`, and the leg below would then pass for the wrong
  # reason (`PID DEAD` from absence, not from the zombie rule).
  [ -n "$zpid" ] && zstat="$(ps -o stat= -p "$zpid" 2>/dev/null | tr -d ' ')"

  # write_prom_store <pid> [startSeconds|__absent__] — one lane record. A start of
  # 1000000000 is deliberately far from any real start: it is only reached AFTER a
  # presence check, so an absent pid is still absent and a live pid is off-fence.
  write_prom_store() {
    local pid="$1" start="${2:-1000000000}"
    if [ "$start" = "__absent__" ]; then
      printf '{"sessions":{"%s":{"sessionId":"%s","pid":%s,"agentLifecycle":"running"}}}' \
        "$sid" "$sid" "$pid" > "$store"
    else
      printf '{"sessions":{"%s":{"sessionId":"%s","pid":%s,"pidStartSeconds":%s,"agentLifecycle":"running"}}}' \
        "$sid" "$sid" "$pid" "$start" > "$store"
    fi
  }
  # run_promotion [NAME=value ...] — HERMETIC by construction. PI_PID_IDENTITY_LIB,
  # PS_BIN and DATE_BIN are UNSET so the tool must resolve the FARMED library by
  # RELATIVE position (scripts/fleet/ <-> scripts/lib/): liveness.lib_path() prefers the
  # env var, so an exported value (the lane-liveness plist pins it) would silently
  # replace the farmed library and make the whole layout pin vacuous. Extra NAME=value
  # arguments are applied on top — leg (d) uses that for its explicit override.
  run_promotion() {
    env -u PI_PID_IDENTITY_LIB -u PS_BIN -u DATE_BIN HOME="$phome" "$@" python3 "$tool" 2>&1
  }

  # (a) absent pid → the dead witness still fires.
  write_prom_store 999999
  out="$(run_promotion)"
  if grep -q "PID DEAD" <<<"$out"; then
    echo "ok: $label absent pid reads PID DEAD through the farmed library"
  else
    fail "$label: absent pid did NOT read PID DEAD — the promotion disabled the witness: $(grep -E '^B1 ' <<<"$out")"
  fi

  # (b) pid REUSE: a live pid whose recorded start is off-fence → abstain.
  write_prom_store "$$"
  out="$(run_promotion)"
  if grep -q "PID DEAD" <<<"$out"; then
    fail "$label: a LIVE pid with an off-fence start read PID DEAD (fence bypass)"
  elif grep -q "PID ? (off-fence)" <<<"$out"; then
    echo "ok: $label live-but-off-fence pid ABSTAINS as PID ? (off-fence), never PID DEAD"
  else
    fail "$label: off-fence pid neither abstained nor read dead: $(grep -E '^B1 ' <<<"$out")"
  fi

  # (c) zombie → PID DEAD. The pre-fix bare existence check could not, and the probe
  # detail must be the ZOMBIE rule, not plain absence.
  if [[ "$zstat" == Z* ]]; then
    write_prom_store "$zpid"
    out="$(run_promotion)"
    if grep -q "PID DEAD" <<<"$out"; then
      echo "ok: $label zombie pid ($zpid, stat=$zstat) reads PID DEAD (no bare-existence read is possible)"
    else
      fail "$label: zombie pid read neither PID DEAD nor an abstention: $(grep -E '^B1 ' <<<"$out")"
    fi
  else
    fail "$label: the zombie fixture is not a zombie (stat='${zstat:-none}') — the A4 pin did not run"
  fi
  [ -n "$zparent" ] && kill "$zparent" 2>/dev/null || true

  # (d) NEGATIVE control — the canonical library absent.
  write_prom_store 999999
  out="$(run_promotion "PI_PID_IDENTITY_LIB=/nonexistent/pid-identity.sh")"
  if grep -q "PID DEAD" <<<"$out"; then
    fail "$label: NEGATIVE CONTROL FAILED — with the canonical library absent fleet-health.py still printed PID DEAD (bare-existence fallback)"
  elif grep -q "PID ? (unreadable)" <<<"$out"; then
    echo "ok: $label NEGATIVE CONTROL — library absent ⇒ PID ? (unreadable), never PID DEAD"
  else
    fail "$label: NEGATIVE CONTROL inconclusive — library absent yielded neither PID DEAD nor an abstention: $(grep -E '^B1 ' <<<"$out")"
  fi

  # (e) the `ps` READ fails (live pid, valid start) → abstain, never PID DEAD.
  # `PS_BIN` is the library's own documented injection point for exactly this shape.
  write_prom_store "$$"
  out="$(run_promotion PS_BIN=/nonexistent/ps)"
  if grep -q "PID DEAD" <<<"$out"; then
    fail "$label: a failed ps read rendered PID DEAD (a read that did not happen is not a death witness)"
  elif grep -q "PID ? (unreadable)" <<<"$out"; then
    echo "ok: $label broken ps read ABSTAINS as PID ? (unreadable), never PID DEAD"
  else
    fail "$label: broken ps read neither abstained nor read dead: $(grep -E '^B1 ' <<<"$out")"
  fi

  # (f)+(g) an UNUSABLE recorded start (absent / negative) with a LIVE pid → abstain.
  write_prom_store "$$" __absent__
  out="$(run_promotion)"
  if grep -q "PID DEAD" <<<"$out"; then
    fail "$label: a record with NO pidStartSeconds read PID DEAD (an unfenceable start must abstain)"
  elif grep -q "PID ? (unreadable)" <<<"$out"; then
    echo "ok: $label missing pidStartSeconds ABSTAINS as PID ? (unreadable), never PID DEAD"
  else
    fail "$label: missing pidStartSeconds neither abstained nor read dead: $(grep -E '^B1 ' <<<"$out")"
  fi
  write_prom_store "$$" -1
  out="$(run_promotion)"
  if grep -q "PID DEAD" <<<"$out"; then
    fail "$label: pidStartSeconds=-1 read PID DEAD (an unusable start must abstain)"
  elif grep -q "PID ? (unreadable)" <<<"$out"; then
    echo "ok: $label pidStartSeconds=-1 ABSTAINS as PID ? (unreadable), never PID DEAD"
  else
    fail "$label: pidStartSeconds=-1 neither abstained nor read dead: $(grep -E '^B1 ' <<<"$out")"
  fi

  # (h) an ABSTENTION must not SUPPRESS the suspect ladder: off-fence + a STALE
  # transcript is still a suspect, never a clean report. The stale transcript is reused by
  # leg (i), which needs a lane to remain suspect while the STORE is unusable.
  local tfile="$phome/.pi/agent/sessions/--stale--/x_$sid.jsonl"
  mkdir -p "$(dirname "$tfile")"
  python3 -c 'import os,sys,time
open(sys.argv[1], "a").close()
os.utime(sys.argv[1], (time.time() - 1200, time.time() - 1200))' "$tfile"
  write_prom_store "$$"
  out="$(run_promotion)"
  if grep -q "PID DEAD" <<<"$out"; then
    fail "$label: off-fence + stale transcript read PID DEAD"
  elif grep -q "PID ? (off-fence)" <<<"$out" && grep -q "suspect(s)" <<<"$out"; then
    echo "ok: $label an abstaining lane with a stale transcript stays a SUSPECT (the abstention does not suppress the ladder)"
  else
    fail "$label: abstention SUPPRESSED the suspect ladder — a stale lane read as clean: $(grep -E '^B1 |no suspects' <<<"$out")"
  fi

  # (i) the DATA SOURCE abstains: an unreadable store and a shape-drifted store must each
  # report the scan INCOMPLETE with exit 1 — never `no suspects` — AND must still list a
  # suspect the ladder found (a failed read may not suppress it either). The exit code is
  # captured with `|| rc=$?` because `out="$(cmd)"; rc=$?` aborts the suite under `set -e`.
  printf '{"sessions":{' > "$store"
  rc=0; out="$(run_promotion)" || rc=$?
  if [ "$rc" -eq 1 ] && grep -q "INCOMPLETE" <<<"$out" && grep -q "suspect(s)" <<<"$out"; then
    echo "ok: $label unreadable hook store ⇒ INCOMPLETE (exit 1) and the stale lane is still a SUSPECT"
  else
    fail "$label: unreadable hook store did not abstain (rc=$rc): $(grep -E '^B1 |no suspects|INCOMPLETE' <<<"$out")"
  fi
  printf '{"sessions":{"drift":{"pid":%s}}}' "$$" > "$store"
  rc=0; out="$(run_promotion)" || rc=$?
  if [ "$rc" -eq 1 ] && grep -q "INCOMPLETE" <<<"$out"; then
    echo "ok: $label shape-drifted hook store ⇒ INCOMPLETE (exit 1), never 'no suspects'"
  else
    fail "$label: shape-drifted hook store did not abstain (rc=$rc): $(grep -E '^B1 |no suspects|INCOMPLETE' <<<"$out")"
  fi
  write_prom_store 999999
  rm -f "$tfile"
}

run_setup() {
  echo "---- setup.sh run (HOME=$HOME_DIR) ----" >> "$RUNS_LOG"
  bash "$CLONE/pi-bootstrap/setup.sh" >> "$RUNS_LOG" 2>&1
}

# #1277 — a setup run that is EXPECTED to be refused by the tools/ guard. The
# log header deliberately does NOT match '^---- setup.sh run', so it stays out
# of the #446 setup-run count (a guard-refused run never reaches
# install-launchd and so never prints the temp-HOME refusal). Prints the exit
# code on stdout for the caller to assert on.
run_setup_expect_guard_fail() {
  echo "---- guard probe: setup.sh with a stray \$DEST/tools/ entry (HOME=$HOME_DIR) ----" >> "$RUNS_LOG"
  local rc=0
  bash "$CLONE/pi-bootstrap/setup.sh" >> "$RUNS_LOG" 2>&1 || rc=$?
  echo "$rc"
}

# --- run 1: fresh install -------------------------------------------------
echo "== run 1: fresh install"
run_setup

[ -f "$DEST/agents/verifier.md" ] \
  || fail "agents not materialized (verifier.md missing)"
[ -f "$DEST/behavior-control/config.json" ] \
  || fail "behavior-control not materialized (config.json missing)"
if [ -d "$DEST/skills" ] && [ ! -L "$DEST/skills" ]; then
  echo "ok: skills is a real folder"
else
  fail "skills should be a real folder after fresh install"
fi
[ -f "$DEST/extensions/subagent/index.ts" ] \
  || fail "subagent extension not materialized at top level"
[ -f "$DEST/extensions/audit-logger.ts" ] \
  || fail "single-file extension not copied (audit-logger.ts missing)"
check_no_nesting "$DEST" "dest"
check_no_nesting "$ROOT/extensions" "repo-extensions"
if [ -L "$DEST/extensions/mcp-client" ]; then
  echo "ok: farm link mcp-client kept"
else
  fail "farm link mcp-client was replaced by a materialized copy"
fi
if [ -L "$DEST/extensions/shared" ]; then
  echo "ok: farm link shared kept"
else
  fail "farm link shared was replaced by a materialized copy"
fi
[ "$(readlink "$DEST/extensions/mcp-client")" = "$CLONE/extensions/mcp-client" ] \
  || fail "mcp-client link target changed (now: $(readlink "$DEST/extensions/mcp-client" 2>/dev/null))"
[ "$(readlink "$DEST/extensions/shared")" = "$ROOT/extensions/shared" ] \
  || fail "shared link target changed (now: $(readlink "$DEST/extensions/shared" 2>/dev/null))"
grep -q "farm symlinks kept" "$RUNS_LOG" \
  || fail "run 1 did not report kept farm links"
check_content_matches "$DEST/extensions" "run1" mcp-client shared
check_fix_markers "$DEST/extensions" "run1"
check_record_review_farmed "run1"
check_ci_runner_gate_farmed "run1"
check_fleet_srcs_farmed "run1"
check_producer_farm_declared "run1"
check_orphan_reaper_farmed "run1"
check_identity_lib_farmed "run1"
check_fleet_tools_farmed "run1"
check_fleet_health_promotion "run1"
grep -q "scripts merge-gate farm: 1 copied (record-review.sh, #562)" "$RUNS_LOG" \
  || fail "run 1 did not report the merge-gate scripts farm copy (#562)"
# ⛔ DERIVED FROM `lib_srcs`, NOT HARD-CODED (#1897). This used to pin the literal string `2 copied
# (pid-identity.sh + diff-normalize.py)` — so adding a legitimate THIRD lib (beat-pair.sh, the
# recap/beat rule both readers share) turned a correct farm into a CI red. Read the expected count and
# names FROM the array, so the assertion fails for the reason it exists (a sibling that landed
# undeclared, or a summary that lies about what was farmed) instead of on every addition.
lib_decl="$(sed -n 's/^lib_srcs=(\(.*\))$/\1/p' "$ROOT/pi-bootstrap/setup.sh")"
lib_n="$(printf '%s\n' "$lib_decl" | wc -w | tr -d ' ')"
if [ -z "${lib_n:-}" ] || [ "$lib_n" -eq 0 ]; then
  fail "run 1: could not read the lib_srcs array from setup.sh — the lib-farm assertion cannot be derived"
else
  lib_line="$(grep -m1 'scripts lib farm: [0-9][0-9]* copied' "$RUNS_LOG")"
  case "$lib_line" in
    *"scripts lib farm: $lib_n copied"*) ;;
    *) fail "run 1 did not report the shared-library farm copies (expected $lib_n copied, #1178/#1362): ${lib_line:-<no lib-farm line at all>}" ;;
  esac
  for lib_base in $lib_decl; do
    case "$lib_line" in
      *"$lib_base"*) ;;
      *) fail "run 1: the lib-farm summary does not NAME the declared lib '$lib_base' — a summary that omits a lib it farmed misreports the farm (#1897)" ;;
    esac
  done
fi
grep -q "scripts/fleet farm: 4 copied (lane-liveness + fleet-health + map-sessions, #1178)" "$RUNS_LOG" \
  || fail "run 1 did not report the fleet-tools farm copy (4 files, #1178)"
check_tools_dir_clean "run1-final"

# --- run 1b: #1277 legacy migration + durable regression guard -----------------
# The defect: the farm used to write $DEST/tools/fleet/, which is pi's RETIRED
# custom-tools namespace. pi's startup scan rejects ANY non-fd/rg entry there and
# then waits for a keypress with no timeout, so a farmed host cannot boot an
# interactive pi at all — and the farm re-created the directory within minutes,
# so a machine-local workaround was not durable. Both halves are pinned here:
# the migration that REMOVES a pre-existing legacy farm, and the guard that makes
# the farm FAIL LOUD rather than recreate one.
echo "== run 1b: legacy tools/fleet migration + tools/ regression guard (#1277)"
mkdir -p "$DEST/tools/fleet"
for f in lane_liveness.py liveness.py fleet-health.py map-sessions.py; do
  echo "# legacy farm replica (the pi boot-blocker)" > "$DEST/tools/fleet/$f"
done
if [ -f "$DEST/tools/fleet/lane_liveness.py" ]; then
  echo "ok: legacy tools/fleet/ fixture staged"
else
  fail "legacy tools/fleet/ fixture was not staged — the migration cannot be tested"
fi
run_setup
check_legacy_tools_farm_removed "run1b"
check_tools_dir_clean "run1b"
if [ -d "$DEST/tools" ]; then
  fail "legacy run left $DEST/tools/ behind (it was empty after fleet/ was removed)"
else
  echo "ok: empty \$DEST/tools/ removed once the legacy farm was migrated out (#1277)"
fi
check_fleet_tools_farmed "run1b"
check_ci_runner_gate_farmed "run1b"

# The guard must FAIL, not warn, when a non-fd/rg entry reappears — the exact
# re-introduction path the farm itself took. fd/rg stay permitted (pi extracts
# those binaries there), so the stray is a differently-named file.
mkdir -p "$DEST/tools"
echo "# a re-introduced non-pi tool" > "$DEST/tools/custom-fleet-tool.py"
guard_rc="$(run_setup_expect_guard_fail)"
if [ "$guard_rc" -ne 0 ]; then
  echo "ok: setup.sh exits $guard_rc on a non-fd/rg entry in \$DEST/tools/ (#1277 guard)"
else
  fail "setup.sh exited 0 with a stray entry in \$DEST/tools/ — the guard does not fail on re-introduction"
fi
if grep -q "non-fd/rg entries" "$RUNS_LOG"; then
  echo "ok: the guard names the non-fd/rg entry and refuses (#1277)"
else
  fail "the guard did not name the non-fd/rg entry in its output"
fi
if grep -q "custom-fleet-tool.py" "$RUNS_LOG"; then
  echo "ok: the guard names the offending entry"
else
  fail "the guard did not name the offending entry (custom-fleet-tool.py)"
fi
# fd/rg alone must NOT trip the guard, and must survive the migration.
rm -f "$DEST/tools/custom-fleet-tool.py"
for b in fd rg; do echo '#!/bin/sh' > "$DEST/tools/$b"; done
run_setup
check_tools_dir_clean "run1b-fd-rg"
if [ -f "$DEST/tools/fd" ] && [ -f "$DEST/tools/rg" ]; then
  echo "ok: fd/rg alone keep \$DEST/tools/ intact and the guard silent (pi's own binaries survive)"
else
  fail "fd/rg were removed from \$DEST/tools/ — the migration must touch fleet/ only"
fi
rm -rf "$DEST/tools"

# --- run 2: re-run must refresh the ACTIVE files --------------------------
# (a) a dest mutation must be overwritten by the source (content-merge);
# (b) a NEW source file must propagate to the active dir.
echo "== run 2: re-run refresh"
echo "# machine-local mutation" >> "$DEST/agents/verifier.md"
echo "# stale farm mutation" >> "$DEST/scripts/record-review.sh"   # #562 farm refresh
if [ -f "$DEST/scripts/ci_runner_gate.sh" ]; then
  echo "# stale farm mutation" >> "$DEST/scripts/ci_runner_gate.sh"  # #1719 farm refresh
fi
if [ -f "$DEST/scripts/lane-guard.py" ]; then
  echo "# stale farm mutation" >> "$DEST/scripts/lane-guard.py"  # #1552 farm refresh (lane layer)
fi
if [ -f "$DEST/scripts/lib/pid-identity.sh" ]; then
  echo "# stale farm mutation" >> "$DEST/scripts/lib/pid-identity.sh"  # #1178 farm refresh
fi
if [ -f "$DEST/scripts/lib/diff-normalize.py" ]; then
  echo "# stale farm mutation" >> "$DEST/scripts/lib/diff-normalize.py"  # #1362 farm refresh
fi
if [ -f "$DEST/scripts/fleet/lane_liveness.py" ]; then
  echo "# stale farm mutation" >> "$DEST/scripts/fleet/lane_liveness.py"   # #1178 unit 3 farm refresh
fi
if [ -f "$DEST/scripts/fleet/liveness.py" ]; then
  echo "# stale farm mutation" >> "$DEST/scripts/fleet/liveness.py"        # #1178 unit 3 farm refresh
fi
if [ -f "$DEST/scripts/fleet/fleet-health.py" ]; then
  echo "# stale farm mutation" >> "$DEST/scripts/fleet/fleet-health.py"     # #1178 unit 4 farm refresh
fi
if [ -f "$DEST/scripts/fleet/map-sessions.py" ]; then
  echo "# stale farm mutation" >> "$DEST/scripts/fleet/map-sessions.py"     # #1178 unit 4 farm refresh
fi
SRC_MARKER="$ROOT/pi-bootstrap/pi-config/agents/zz-setup-test-marker.md"
echo "# issue-93 test marker" > "$SRC_MARKER"

run_setup

if [ -f "$DEST/agents/zz-setup-test-marker.md" ]; then
  echo "ok: new source file propagated to active dir on re-run"
else
  fail "new source file did not propagate to active dir on re-run"
fi
if grep -q "machine-local mutation" "$DEST/agents/verifier.md"; then
  fail "dest mutation survived re-run (active file was not refreshed)"
else
  echo "ok: dest mutation reverted by source on re-run"
fi
check_record_review_farmed "run2"
check_ci_runner_gate_farmed "run2"
if [ ! -f "$DEST/scripts/ci_runner_gate.sh" ]; then
  : # already reported by check_ci_runner_gate_farmed "run2" (a missing file is not "refreshed")
elif grep -q "stale farm mutation" "$DEST/scripts/ci_runner_gate.sh"; then
  fail "stale farm mutation survived re-run (farmed ci_runner_gate.sh was not refreshed)"
else
  echo "ok: farmed ci_runner_gate.sh refreshed on re-run (#1719)"
fi
check_identity_lib_farmed "run2"
check_fleet_tools_farmed "run2"
# #1552 — the refresh half, not just the membership half. run1 pins "the declared list landed";
# run2 re-runs check_fleet_srcs_farmed over ALL 36 declared entries against a mutated destination,
# so every mutated entry must be overwritten by the repo copy. That is the property the farm exists
# for and the one #1552 measured drift against (a stale destination cannot be seen from run1's
# freshly-populated $DEST). The representative-entry sentinel on lane-guard.py below is a SECOND,
# independent assertion that the mutation is really gone.
check_fleet_srcs_farmed "run2"
if [ ! -f "$DEST/scripts/lane-guard.py" ]; then
  : # already reported by check_fleet_srcs_farmed "run2" (a missing file is not "refreshed")
elif grep -q "stale farm mutation" "$DEST/scripts/lane-guard.py"; then
  fail "stale farm mutation survived re-run (farmed lane-guard.py was not refreshed)"
else
  echo "ok: farmed lane-guard.py refreshed on re-run (#1552)"
fi
if grep -q "stale farm mutation" "$DEST/scripts/fleet/lane_liveness.py" 2>/dev/null; then
  fail "stale farm mutation survived re-run (farmed lane_liveness.py was not refreshed)"
else
  echo "ok: farmed lane_liveness.py refreshed on re-run (#1178)"
fi
if grep -q "stale farm mutation" "$DEST/scripts/fleet/liveness.py" 2>/dev/null; then
  fail "stale farm mutation survived re-run (farmed liveness.py was not refreshed)"
else
  echo "ok: farmed liveness.py refreshed on re-run (#1178)"
fi
if grep -q "stale farm mutation" "$DEST/scripts/fleet/fleet-health.py" 2>/dev/null; then
  fail "stale farm mutation survived re-run (farmed fleet-health.py was not refreshed)"
else
  echo "ok: farmed fleet-health.py refreshed on re-run (#1178 unit 4)"
fi
if grep -q "stale farm mutation" "$DEST/scripts/fleet/map-sessions.py" 2>/dev/null; then
  fail "stale farm mutation survived re-run (farmed map-sessions.py was not refreshed)"
else
  echo "ok: farmed map-sessions.py refreshed on re-run (#1178 unit 4)"
fi
check_tools_dir_clean "run2"
if grep -q "stale farm mutation" "$DEST/scripts/record-review.sh"; then
  fail "stale farm mutation survived re-run (farmed record-review.sh was not refreshed)"
else
  echo "ok: farmed record-review.sh refreshed on re-run (#562)"
fi
if [ ! -f "$DEST/scripts/lib/pid-identity.sh" ]; then
  : # already reported by check_identity_lib_farmed "run2" (missing file is not "refreshed")
elif grep -q "stale farm mutation" "$DEST/scripts/lib/pid-identity.sh"; then
  fail "stale farm mutation survived re-run (farmed lib/pid-identity.sh was not refreshed)"
else
  echo "ok: farmed lib/pid-identity.sh refreshed on re-run (#1178)"
fi
if [ ! -f "$DEST/scripts/lib/diff-normalize.py" ]; then
  : # already reported by check_record_review_farmed "run2" (missing file is not "refreshed")
elif grep -q "stale farm mutation" "$DEST/scripts/lib/diff-normalize.py"; then
  fail "stale farm mutation survived re-run (farmed lib/diff-normalize.py was not refreshed)"
else
  echo "ok: farmed lib/diff-normalize.py refreshed on re-run (#1362)"
fi
[ ! -d "$DEST/agents/agents" ] || fail "nesting appeared after re-run"
check_no_nesting "$DEST" "dest-after-rerun"
check_no_nesting "$ROOT/extensions" "repo-extensions-after-rerun"
if [ -L "$DEST/extensions/mcp-client" ] && [ -L "$DEST/extensions/shared" ]; then
  echo "ok: farm links survived re-run"
else
  fail "farm links lost on re-run"
fi

# --- run 3: stale/foreign links are replaced, not followed -----------------
echo "== run 3: stale/foreign symlink replacement"
ln -s "/nonexistent/pi-93-target" "$DEST/extensions/tortoise-capture"   # broken
ln -s "$TMP/foreign-checkout/extensions" "$DEST/extensions/slack-bridge" # foreign

run_setup

if [ -d "$DEST/extensions/tortoise-capture" ] && [ ! -L "$DEST/extensions/tortoise-capture" ]; then
  echo "ok: broken symlink tortoise-capture replaced with a real folder"
else
  fail "broken symlink tortoise-capture was not replaced (still a link or missing)"
fi
if [ -d "$DEST/extensions/slack-bridge" ] && [ ! -L "$DEST/extensions/slack-bridge" ]; then
  echo "ok: foreign symlink slack-bridge replaced with a real folder"
else
  fail "foreign symlink slack-bridge was not replaced"
fi
[ -f "$DEST/extensions/tortoise-capture/index.ts" ] \
  || fail "replaced tortoise-capture is missing content"
check_no_nesting "$DEST" "dest-after-run3"
if [ -L "$DEST/extensions/mcp-client" ] && [ -L "$DEST/extensions/shared" ]; then
  echo "ok: good farm links still kept after run 3"
else
  fail "good farm links lost during stale-link replacement"
fi

# --- run 4: skills farm symlink preservation ---------------------------------
echo "== run 4: skills farm"
# Point the skills farm into this repo via the clone path (no "agent-infra") —
# the realpath comparison must keep it; the old substring grep would miss it.
rm -rf "$DEST/skills"
ln -s "$CLONE/skills" "$DEST/skills"

run_setup

if [ -L "$DEST/skills" ] && [ "$(readlink "$DEST/skills")" = "$CLONE/skills" ]; then
  echo "ok: skills farm symlink kept (clone-path target)"
else
  fail "skills farm symlink was not kept (now: $(readlink "$DEST/skills" 2>/dev/null || echo 'not a link'))"
fi

# Foreign skills symlink → must be replaced with a real folder.
rm -rf "$DEST/skills"
ln -s "$TMP/foreign-skills" "$DEST/skills"

run_setup

if [ -d "$DEST/skills" ] && [ ! -L "$DEST/skills" ]; then
  echo "ok: foreign skills symlink replaced with a real folder"
else
  fail "foreign skills symlink was not replaced with a real folder"
fi
[ -d "$DEST/skills" ] && [ -n "$(ls -A "$DEST/skills" | head -1)" ] \
  || fail "replaced skills folder is empty"

# --- run 5: completely fresh extensions install (no pre-existing farm) --------
# The exact issue #95 acceptance: a machine with NO prior state must receive the
# CURRENT extension code, as real materialized copies (not links to a clone).
echo "== run 5: fresh extensions install, zero pre-existing links"
rm -rf "$DEST/extensions"
run_setup

links_found="$(find "$DEST/extensions" -maxdepth 1 -type l 2>/dev/null | wc -l | tr -d ' ')"
if [ "$links_found" -eq 0 ]; then
  echo "ok: fresh install materialized real copies (no symlinks)"
else
  fail "fresh install left $links_found symlink(s) in $DEST/extensions"
fi
check_content_matches "$DEST/extensions" "run5"
check_fix_markers "$DEST/extensions" "run5"
check_no_nesting "$DEST" "dest-after-run5"

# --- run 6: stale materialized copies self-heal on re-run ---------------------
# A previously-bootstrapped machine has real copies (possibly stale). Re-running
# setup.sh must refresh them to CURRENT extensions/ content.
echo "== run 6: stale DEST copies refreshed to current extensions/ content"
echo "# stale mutation" >> "$DEST/extensions/subagent/index.ts"
echo "# stale mutation" >> "$DEST/extensions/builtin-tools/index.ts"
run_setup
check_content_matches "$DEST/extensions" "run6"
check_fix_markers "$DEST/extensions" "run6"

# --- done -----------------------------------------------------------------
# #446: every setup.sh run happened under the temp HOME; the launchctl shim
# must be SILENT (no call escaped to any launchctl) and the installer's
# temp-HOME guard must have refused every time (message present per run).
# Darwin-only in practice (setup.sh reaches install-launchd only on Darwin);
# guarded so a hypothetical Linux CI run can't fail on these assertions.
if [[ "$(uname)" == "Darwin" ]]; then
  setup_runs="$(grep -c '^---- setup.sh run' "$RUNS_LOG")"
  if [ -s "$LAUNCHCTL_LOG" ]; then
    fail "launchctl was called $setup_runs setup-run(s) in: $(cat "$LAUNCHCTL_LOG" | head -1)"
  elif [ "$setup_runs" -ge 1 ]; then
    echo "ok: zero launchctl calls across $setup_runs setup runs (real domain untouched)"
  else
    fail "no setup.sh runs recorded — cannot verify launchctl isolation"
  fi
  guard_hits="$(grep -c 'refusing to manage launchd jobs' "$RUNS_LOG" || true)"
  if [ "$guard_hits" -eq "$setup_runs" ] && [ "$setup_runs" -ge 1 ]; then
    echo "ok: temp-HOME guard fired on all $setup_runs runs"
  else
    fail "temp-HOME guard fired $guard_hits/$setup_runs runs (expected every run)"
  fi
else
  echo "ok: launchctl-isolation assertions skipped (non-Darwin)"
fi
if [ "$FAILURES" -gt 0 ]; then
  echo ""
  echo "FAILURES: $FAILURES — full output: $RUNS_LOG" >&2
  echo "---- last run log ----" >&2
  tail -40 "$RUNS_LOG" >&2 || true
  exit 1
fi
echo ""
echo "OK: no nesting, active files refreshed, farm links preserved (clone path: $CLONE)"
