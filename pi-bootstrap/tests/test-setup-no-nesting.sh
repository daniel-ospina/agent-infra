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
#   * It pins the DECLARED set only. The COMPLETENESS half — "is every producer of this layer
#     delivered by some farm array at all?" — is `check_producer_population` /
#     `check_producer_farm_declared` below, and since #1899 their SUBJECT is DERIVED from the exec
#     sites in the farmed consumers rather than hand-listed: a fresh farm came to carry every
#     CONSUMER without the executable it calls (five producers joined `fleet_srcs` on 2026-10-16
#     for exactly that reason), and a hand list could not contain the producer that had fallen out
#     (fail-open, #1899). Two remain a DECLARED gap, named there with their owning issue.
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
  # ONE reader of the array (see `farm_array_entries`) — a second inline regex here is how the readers
  # diverge, and a reader that stops matching reports a farmed array as empty.
  line="$(farm_array_entries fleet_srcs)"
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
  # ⛔ ORDER MATTERS FOR ONE PAIR (#1872). The farm copies in ARRAY ORDER and `[ -f "$f" ] || continue`
  # skips a missing source, so a farm interrupted between these two files leaves a partial pair —
  # and only ONE direction of that pair is safe: a NEW `pr-doctor.py` beside an OLD `objective.py`
  # is refused at import by the driver's seam (loud), while a NEW beat beside an OLD driver is
  # silent, because the assertion lives in the driver. The array is otherwise unordered, so a
  # future "let's sort this list" edit would restore the silent window with the suite still green.
  # This turns that comment into a gate.
  local idx_driver=0 idx_classifier=0 i=0
  for entry in $line; do
    i=$((i+1))
    [ "$entry" = "pr-doctor.py" ] && idx_driver=$i
    [ "$entry" = "objective.py" ] && idx_classifier=$i
  done
  if [ "$idx_driver" -gt 0 ] && [ "$idx_classifier" -gt 0 ] && [ "$idx_driver" -gt "$idx_classifier" ]; then
    fail "$label: fleet_srcs lists objective.py ($idx_classifier) BEFORE pr-doctor.py ($idx_driver) — the\
 farm copies in array order, and only the driver-first order makes an interrupted farm FAIL LOUDLY\
 (the driver's import seam); the reverse order is silent (#1872)"
  fi
  # ⛔ AND ABSENCE IS NOT A PASS (#1872 review round 4). The order assertion above is VACUOUS when
  # either index is 0, so the pair needs a presence half too — but be honest about WHICH gate is
  # load-bearing here (#1872 review round 13 re-measured this on the merged tree): since #1899 the
  # DERIVED population gate in this same file already fails a deleted `pr-doctor.py`
  # (`producer(s) exec'd by a farmed consumer and DELIVERED BY NOTHING: pr-doctor.py`), because both
  # files are exec'd by farmed consumers. So the unique value of THIS block is the ORDER assertion,
  # which the derived gate does not check; the presence loop below is defence-in-depth for the pair,
  # and it stays because it names the consequence (a NEW beat beside an OLD driver is SILENT) rather
  # than a generic "undelivered producer". (Before the merge this suite was GREEN on that deletion —
  # that measurement is what motivated the block, and #1899 has since closed the same hole from the
  # other direction.)
  #
  # ⛔ AND USE THE SHARED READER, NOT A HAND-WRITTEN MATCH (#1872). `farm_array_entries` returns ONE
  # ENTRY PER LINE (`tr -s ' ' '\n'`), so a `case " $line " in *" $entry "*` test never matches — it
  # reported BOTH files absent while the array declared both, and the reversal run was green only
  # because that assertion is vacuous when either index is 0. `farm_declares` is the whole-word
  # membership idiom the rest of this file uses (a plain `grep -F` is satisfied by `pr-doctor.py.old`),
  # and it REQUIRES the explicit root: its signature is `<array> <entry> [repo-root]` and the body
  # reads `"$3"`, so a two-argument call is an unbound variable under this file's `set -u` (measured:
  # BOTH files were reported absent while the array declared both).
  for entry in pr-doctor.py objective.py; do
    farm_declares fleet_srcs "$entry" "$ROOT" \
      || fail "$label: fleet_srcs no longer declares '$entry' — the PAIR of driver/classifier\
 is undelivered, and its drift is exactly what the import seam refuses at runtime (#1872)"
  done
}

# ---------------------------------------------------------------------------------------------
# #1552 + #1899 — PRODUCER COMPLETENESS, and its population is DERIVED, never hand-listed.
#
# `check_fleet_srcs_farmed` above can only pin whatever the arrays DECLARE, so it reports a clean
# "N/N" for a farm whose CONSUMERS are all present and whose PRODUCERS are all undelivered (measured
# 2026-10-16: the lane layer's producers were in NO farm array, so a fresh `$DEST/scripts` got
# `pr-doctor.py`/`lane-scan-fallback.sh` without the `lane-actions.py` they exec, `cadence-timer.sh`
# without `cadence-nudge.sh`, `live-workspaces-publisher.py` without `publish-live-workspaces.py`, and
# `orchestrator-heartbeat.sh` without `objective.py`). #1552 added this check to close that half.
#
# #1899 — THE SUBJECT WAS THE DEFECT. Until #1899 that check's subject was a HAND-WRITTEN list of
# seven, chosen by measurement rather than by the set of producers actually exec'd, so it could not
# contain the one producer that had already fallen out. Measured on `origin/main` at #1899:
#
#   scripts/orchestrator-heartbeat.sh:636 — a `fleet_srcs` consumer — execs
#     TRV=$(/usr/bin/python3 "$HOME/.pi/agent/state/lane-triage.py" 2>/dev/null) \
#       && eval "$TRV" || log "NOTE triage unavailable -- mechanical verdicts stand"
#
# `lane-triage.py` is no repo file (that exec site is its only reference in a farmed consumer) and is in
# NO farm array, `setup.sh` never creates `$DEST/state/`, and the exec site fails SILENTLY — while the
# gate printed its whole verdict over a SEVEN-name subject:
#   DECLARED-GAP: run1 lane producers in a farm array: 5/7 (2 not carried here, owned by #1553: …) (#1552)
# (`ok: run1 all 7 …` is the same function's clean arm, taken on a tree without those two exemptions.)
# Both lines are truthful ABOUT THE SUBJECT and blind to the 8th producer, which the subject structurally
# could not contain: the gap it disclosed was a gap in the HAND LIST, not in the farm. An instrument
# whose population cannot contain the producer it was written for is fail-open no matter which of its two
# arms it prints (category A, #1899).
#
# THE FIX IS THE POPULATION, NOT ONE MORE NAME. `derive_lane_producers` walks the EXEC SITES: it
# starts from every file a farm array delivers — plus `LAUNCHD_ENTRY_PRODUCERS`, the one production
# entrypoint whose caller is not in this repo — and closes TRANSITIVELY over the producers those
# files exec. Adding an exec site now changes the derived set, and the set is PINNED
# (`LANE_PRODUCERS_CANONICAL`) so the change must be DISPOSITIONED — delivered by a farm array,
# exempted with an owning issue, or named as a `state/` residual with an owning issue — never
# absorbed — into `LANE_PRODUCERS_EXEMPT` (deliverable but withheld), or
# `LANE_PRODUCERS_STATE_RESIDUAL` / `LANE_PRODUCERS_FOREIGN_RESIDUAL` (a class the farm cannot carry) —
# never. A hand list can fall behind the code; a derivation cannot fall behind itself.
#
# ⛔ THE EXTRACTION FORMS ARE THE DECLARED SURFACE, and every one is PROVEN LIVE by the `forms-probe`
# below. A static scan cannot see a syntax it does not know, and that is the one blind spot this
# design keeps — stated here so it is not mistaken for "covers everything":
#   F1  bash sibling     "$SCRIPTS/<n>"  "${SCRIPT_DIR}/<n>"  "${SCRIPTDIR}/<n>"  "$SCRIPTS/lib/<n>"
#   F2  bash self-dir    "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/<n>" and the bare
#       "$(dirname "${BASH_SOURCE[0]}")/lib/<n>" spelling (pi-reap-idle.sh:138)
#   F3  agent-dir path   any `agent/scripts/<n>` (flat farm dest) or `agent/state/<p>` — spelled
#       absolutely, so `"$HOME/.pi/agent/scripts/objective.py"` (cadence-nudge.sh:292) is seen too
#   F3b agent-dir join   the same path as a python join LIST, one segment per argument
#       (`os.path.join(HOME, ".pi", "agent", "scripts", "lane-status.py")`, queue-dispatch.py:56)
#   F4  python scripts   os.path.join(SCRIPTS|SCRIPT_DIR|HERE, "…"[, "…"])  — every alternative probed,
#       and a MULTI-SEGMENT join is re-joined with `/` (`join(SCRIPTS,"lib","x.sh")` -> `lib/x.sh`)
#   F4c python self-dir  os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib", "<n>") — the
#       python counterpart of F2, LIVE at lane-watchdog.py:94-95 and queue-dispatch.py:515
#   F4b python f-string  f"{SCRIPTS|SCRIPT_DIR|HERE}/<n>"  and  f"{STATE|STATE_DIR}/<n>"
#       (turn-classify.py:929, turn-end.py:310) — the SAME destination in a different syntax, and the
#       spelling two consumers already use, so a new exec site beside them is not a theoretical case
#   F5  python state     os.path.join(STATE|STATE_DIR, "<n>")          — every alternative probed
#   F7  python pathlib   Path(SCRIPTS|SCRIPT_DIR|HERE|STATE|STATE_DIR) / "<n>" (8 modules under scripts/
#       already `import pathlib`) — a division expression, not a call, so F4's regex cannot see it
#   F8  bash state       "$STATE/<p>"  "${STATE}/<p>"  "$STATE_DIR/<p>" — the state class's F1
#       (its last LIVE instance was the beat's `$STATE/queues/refresh-queues.py`, retired with the
#       lane-table dispatcher by #1874; the form stays because the class can reappear in any farmed
#       consumer, and the forms-probe below proves the extractor synthetically, not from a live site).
#       It needs its OWN form, not an F1 alternative, because the class must come out `state:`; the sub-path is KEPT
#       (the F5 residual), so `queues/<n>` and a flat `<n>` never collapse into one entry
#   F6  foreign absolute a `/Users|/home/.../<dir>/<n>.py|sh` that is NOT the agent dir: a consumer exec'ing
#       a file from ANOTHER checkout — `session-postmortem.sh:27` (eldato's `scripts/`) and
#       `safe-send.sh:146` (tortoise's `tools/cmux_dispatch.py`), which is WHY this form is
#       directory-agnostic. The farm cannot deliver these, so they are DISCLOSED, never silently absorbed.
#
# ⛔ ONE CLASSIFIER, NOT SIX. Every form whose match is a BARE RELATIVE NAME funnels it through
# `_producer_kind` (F4, F4b, F4c, F5, F7, F8), so `lib/<n>` means `lib:` and `<sub>/<n>` means `other:` in all
# of them. (F3, F3b and F6 classify with `sed`, not through
# the classifier — that is deliberate: they match an ALREADY-qualified shape, and F3's `agent/scripts/<sub>/<n>`
# therefore lands on `script:<sub>/<n>` — with ONE deliberate exception, `agent/scripts/lib/<n>` -> `lib:<n>`,
# which mirrors the classifier so a library path documented in a consumer is not misfiled as an undelivered
# `script:lib/<n>` (live: tools/fleet/lane_liveness.py:99 documents `~/.pi/agent/scripts/lib/pid-identity.sh`). That is why the `script:fleet/<n>` delivery branch exists below, and
# it is probed: do not delete it as unreachable.) The join forms used to hardcode `script:`, which filed
# `os.path.join(SCRIPTS,"lib","x.sh")` under `script:lib/x.sh` — neither delivered nor disclosed, and invisible
# to the pin (which only sees what the scan FINDS), so the SUMMARY stayed `0 undelivered-and-undisclosed`. A `..` the normalization cannot resolve is DROPPED by that classifier,
# never guessed into an entry — the `forms-probe` fixture keeps one and asserts it is absent.
#
# ⚠️ DECLARED RESIDUALS of the extraction — do not describe these as covered:
#   ⛔ THE FIRST ONE HAS A LIVE MEMBER ON THIS TREE, so none of them is hypothetical:
#     `scripts/cloud-cell-quiesce.sh` (farmed) locates `cloud-cell-supervisor.sh` by trying
#     `"$REPO/scripts/…"`, `"$O/…"` and a `/tmp/<repo>/scripts/…` path — a variable-held prefix and a
#     cross-repo path, i.e. residual (1) and residual (4) at once. That producer is in NO farm array, so
#     a fresh farm gets the consumer without it and the quiesce degrades to
#     `supervisor: <none found — will start tmux directly>`. #1938 owns whether it is delivered or stays
#     cell-only; until it is dispositioned, the `0 undelivered-and-undisclosed` line is a statement about
#     the DECLARED SURFACE, not a claim about the farm.
#   (1) a path PREFIX held in a variable set elsewhere (`X="$HOME/foo"; "$X/scripts/y.sh"`),
#   (2) a producer reached through a registry/plugin table,
#   (3) a `..`-relative join that is not `../scripts/` (e.g. the python `os.path.join(here, "..",
#       "..", "scripts", ...)` form) — the producer it reaches is still in the population when any
#       OTHER site names it, which is how `lib:pid-identity.sh` is held today,
#   (4) a cross-repo path NOT spelled `/Users|/home` (e.g. `$HOME/other-repo/scripts/x.sh`),
#   (5) an F5 `state/` producer is keyed on its BASENAME (the join prefix lives in another variable), so
#       two same-named state files reached only that way would collapse to one entry — an F3-spelled one
#       keeps its sub-path and cannot.
# A match inside a COMMENT counts on purpose: a path DOCUMENTED in a consumer is still a path the
# fleet depends on being delivered.
#
# ⚠️ THE `state/` CLASS — `setup.sh` never creates or copies into `$DEST/state/` (no `mkdir`/`cp`
# target there; measured at #1899), so a `state/`-resident producer is undelivered on EVERY fresh
# farm: the consumer is farmed, and broken. The farm cannot close that by copying — the file has to
# exist in the repo first (#1552 is the umbrella). Each one is therefore NAMED with the issue that
# owns it, and an UNNAMED one FAILS, so a new `state/` exec site cannot enter silently.
# `lane-verdict.py` had no owner anywhere until this derivation found it: `lane-actions.py:80,1530`
# loads it as the verdict-key loader and silently degrades to `RULE` without it.
# #1874 retired `claim.py`'s and `queues/refresh-queues.py`'s only consumers (the lane-table
# dispatcher and the beat's refresh step), so both LEFT this class in the same landing: an entry here
# for a producer nobody execs is STALE, and the stale check below FAILS on it.
LANE_PRODUCERS_STATE_RESIDUAL="lane-confirm.py:#1797 lane-triage.py:#1553 lane-verdict.py:#1552"
# ⚠️ THE `foreign/` CLASS — a producer a farmed consumer execs from ANOTHER checkout by absolute
# path. Delivered by that repo's own process, never by this farm, and absent from every box that
# lacks the checkout — so it is DISCLOSED with an owner and an undisclosed one FAILS. Measured
# 2026-10-17: TWO sites, ONE after #1921. `session-postmortem.sh:27` defaulted to the eldato repo's
# `scripts/postmortem.sh`, and that consumer then wrote a postmortem whose transcript-pattern section
# was replaced by a one-line "not found" note, on every box but the owner's (#1921) — #1921 VENDORED
# that producer as `scripts/lib/transcript-patterns.sh` and the consumer now resolves it as a SIBLING,
# so the site is gone and with it the `foreign:postmortem.sh` entry: the producer is `lib:` now, not
# foreign. `safe-send.sh:146` runs a CROSS-CHECKOUT `…/tortoise/tools/cmux_dispatch.py` — and this
# class's first form required the
# parent directory to be `scripts/`, so that one was invisible while the line above claimed the class was
# complete: the widening is #1957's, and it is why the form is directory-agnostic now.
LANE_PRODUCERS_FOREIGN_RESIDUAL="cmux_dispatch.py:#1957"
# ⚠️ DELIVERABLE producers still withheld from every farm array, both owned by #1553 and unchanged
# from #1552/#1795: `lane-status.py`'s DESTINATION copy is AHEAD of the repo (1993 repo / 2005 live
# lines at the 2026-10-15 measurement; the live copy carries the #1777 abstention text), so farming
# the repo copy would OVERWRITE the running classifier; and `heartbeat-loop.sh` is byte-identical but
# held back only because `lane-status.py` is. #1553 declares both in `lane_root_srcs`; when it lands
# both take the membership branch and this list becomes STALE, which the stale check below FAILS —
# delete the entries then, so the exemption cannot outlive its reason.
LANE_PRODUCERS_EXEMPT="lane-status.py:#1553 heartbeat-loop.sh:#1553"
# A ROOT of the derivation rather than a producer found by it: `heartbeat-loop.sh` is run by a launchd job
# on the owner's box (no plist template in this repo names it; the label `com.tortoise.heartbeat-loop`
# appears only in a comment at scripts/lane-status.py:41) and NO farmed consumer execs it (measured at
# #1899: zero exec sites, comments only). Every
# entry here is REPORTED as a producer as well as scanned, because it must be delivered too. Without
# this root the derivation would silently DROP `lane-watchdog.py` — exec'd ONLY by it — i.e. lose two
# producers the old hand list covered; that is the same error in the other direction, and it would
# read as a clean smaller population.
LAUNCHD_ENTRY_PRODUCERS="heartbeat-loop.sh"
# The farm arrays whose DELIVERED files are derivation roots, and the REPO directory each one reads
# its entries from. `fleet_tools` is the odd one: it is farmed from `tools/fleet/` into
# `$DEST/scripts/fleet/`, so its consumers exec producers from a destination neither `fleet_srcs` nor
# `lib_srcs` describes. A `*_srcs`/`fleet_tools` array that setup.sh declares but this list omits FAILS
# the run (`declared_farm_arrays`, below) — the root set is checked, not trusted.
# ⚠️ ROOTS DELIBERATELY OUT OF SCOPE, named so the gap is visible: (a) setup.sh's DIRECTORY-GLOB farm
# into `$DEST/scripts/checkout-hygiene/` (a loop over `scripts/checkout-hygiene/*`, not an array — no
# entry list exists to pin), and (b) `pi-bootstrap/cell-install.sh`'s own `lane_srcs`/`FARM_LAYOUT`,
# which is a DIFFERENT installer with its own destination layout. A producer exec'd only from one of
# those is not in this population; extending here means teaching `farm_source_dir` that destination.
FARM_ARRAYS="fleet_srcs merge_gate_srcs fleet_tools lane_root_srcs lib_srcs"
farm_source_dir() { # <array-name> -> the repo dir its entries are read from
  case "$1" in
    lib_srcs)    printf 'scripts/lib' ;;
    fleet_tools) printf 'tools/fleet' ;;
    *)           printf 'scripts' ;;
  esac
}
# The arrays setup.sh actually declares (a destination-agnostic floor for the list above).
declared_farm_arrays() { # <repo-root>
  # NO end anchor: a declaration WRAPPED across lines is still a declaration, and an anchored regex
  # would miss it — the array would then be invisible here and its consumers unscanned, silently. The
  # one-line requirement itself is enforced by `check_fleet_srcs_farmed`, not by this floor.
  sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=(.*/\1/p' "$1/pi-bootstrap/setup.sh" \
    | grep -E '(_srcs$|^fleet_tools$)' | sort -u
}
# The floor as a FUNCTION so it is probeable on a synthetic tree (a floor no probe exercises is a floor
# nobody knows still fires). Fails when setup.sh declares an array this derivation does not read.
check_farm_arrays() { # <repo-root> <label>
  _FLOOR_RAN=1  # proof-of-wiring sentinel: asserted at the end of the #1899 block (see there)
  local root="$1" label="$2" a miss=""
  for a in $(declared_farm_arrays "$root"); do
    case " $FARM_ARRAYS " in *" $a "*) ;; *) miss="$miss $a" ;; esac
  done
  if [ -n "$miss" ]; then
    fail "$label: farm array(s) declared in setup.sh that the producer derivation does NOT read:$miss — their consumers' producers are invisible; add each array and its source dir to FARM_ARRAYS / farm_source_dir (#1899)"
    return
  fi
  echo "ok: $label the derivation reads every farm array setup.sh declares ($(printf '%s\n' $FARM_ARRAYS | grep -c .) read:$(printf ' %s' $FARM_ARRAYS)) (#1899)"
}
# SNAPSHOT PIN of the derived population — a DRIFT CONTROL on the derivation, never its subject (the
# subject is what `derive_lane_producers` FINDS). It exists because every silent failure of this
# guard is a SILENTLY DIFFERENT population: an extraction regex that stops matching, a consumer whose
# farm entry is renamed, an exec site that moves to a form the scan does not know. The set comparison
# below turns each of those into a FAIL that NAMES the added/removed producer, instead of a quieter
# green over a population that shrank — which is exactly the #1899 defect.
# Format: `kind:name`, kind ∈ script | lib | state | foreign | other.
LANE_PRODUCERS_CANONICAL="
script:ask-owner.py script:beta-progress.py script:disk-reaper.sh script:cadence-nudge.sh script:fleet-cost-report.sh
script:goal-state.py script:heartbeat-loop.sh script:lane-actions.py script:lane-guard.py
script:lane-scan-fallback.sh script:lane-status.py script:lane-watchdog.py script:merge-queue.py
script:objective.py script:orchestrator-heartbeat.sh script:pi-reap-worktrees.sh script:pr-doctor.py
script:publish-live-workspaces.py
script:session-postmortem.sh
script:turn-classify.py script:turn-end.py script:undelivered-answers.py script:watch-truncation.sh
lib:beat-pair.sh lib:bounded.sh lib:diff-normalize.py lib:pid-identity.sh lib:transcript-patterns.sh
state:lane-confirm.py state:lane-triage.py state:lane-verdict.py
foreign:cmux_dispatch.py"
# `lib:transcript-patterns.sh` joined on 2026-10-17 (#1921) and `foreign:postmortem.sh` LEFT in the
# same landing, which is the derivation doing its job: the exec site did not vanish, it CHANGED KIND —
# the consumer now execs a sibling that `lib_srcs` farms, and the old foreign reference is gone. A
# agent-infra#1874 (the lane-table dispatcher's retirement) removed FIVE entries in one landing, and
# each was verified against the CODE rather than accepted from the diff — the pin's own warning:
#   * `script:queue-dispatch.py` — the file MOVED to `scripts/orchestrator-harness/retired/`; it is
#     farmed by nothing and executed by nothing, so it is no longer a producer this farm owes.
#   * `script:queue_verdicts.py` — farmed only as that dispatcher's BY-PATH import (#1937, which
#     landed while the dispatcher was live). It moved beside the dispatcher into `retired/`, so the
#     exec site left live code with it; a farm entry for it left `fleet_srcs` in the same commit.
#   * `state:claim.py` and `state:queues/refresh-queues.py` — their only consumers were that
#     dispatcher's `claim_next()` and the `refresh-queues.py` step in `heartbeat-loop.sh`, both
#     removed in the same landing. The queue FILES stay on disk for the record; nothing reads them.
#   * `script:safe-send.sh` — `safe-send.sh` itself still exists and is still farmed; it LOST its only
#     live invoker (the dispatcher), so no farmed consumer EXECS it any more. It is manual-only now,
#     which is why it leaves the producer population while its farm entry stays.
# A REMOVED entry is normally the "exec site was lost" signal; here it was verified against the CODE
# (`grep -n 'postmortem.sh' scripts/session-postmortem.sh` finds only the `POSTMORTEM_SH` override and
# the sibling default), not against the pin.

# An array's entries, one per line. An ABSENT array (`lane_root_srcs`, until #1553) yields nothing:
# it is the population floor and the pin that refuse an emptied delivery set, never this reader.
# <root> defaults to this checkout; the closure probe passes a synthetic tree.
farm_array_entries() { # <array-name> [repo-root]
  sed -n "s/^$1=(\(.*\))$/\1/p" "${2:-$ROOT}/pi-bootstrap/setup.sh" | tr -s ' ' '\n' | sed '/^$/d'
}
# Whole-word membership, the `ci_runner_gate.test.sh` idiom: a plain `grep -F` for the basename is
# also satisfied by `lane-actions.py.old`, i.e. by the exact rename that leaves the producer
# undelivered. `tr` splits the array on whitespace, `grep -Fxq` requires the whole entry.
farm_declares() { # <array-name> <entry> [repo-root] -> 0 when the array carries the entry as a word
  farm_array_entries "$1" "$3" | grep -Fxq -- "$2"
}
# A repo-relative path as a population entry.
producer_kind_of() { # <scripts/... path>
  case "$1" in
    scripts/lib/*)  printf 'lib:%s' "${1#scripts/lib/}" ;;
    scripts/*/*)    printf 'other:%s' "${1#scripts/}" ;;
    scripts/*)      printf 'script:%s' "${1#scripts/}" ;;
    *)              printf 'other:%s' "$1" ;;
  esac
}
# One consumer's exec sites as population entries. Every form is `|| true`-guarded: a `grep` that
# matches nothing exits 1, and this file runs under `set -e -o pipefail`.
# A path RELATIVE to a scripts dir -> "<kind>:<name>", the single classifier every form funnels through
# (the forms would otherwise disagree about what `lib/<n>` or `<sub>/<n>` means — and the join forms USED
# to hardcode `script:` for anything they matched, so `os.path.join(SCRIPTS, "lib", "x.sh")` and
# `f"{SCRIPTS}/lib/x.sh"` came out as `script:lib/x.sh`: neither delivered nor disclosed, and — worse —
# INVISIBLE, because the pin only sees what the scan FINDS, so a producer reached only that way changed
# nothing and the SUMMARY stayed `0 undelivered-and-undisclosed`. Latent on this tree: no live site names
# a sub-path through a join today.)
_producer_kind() { # <relative-path-or-name> [default-kind]
  case "$1" in
    '')          return ;;
    *..*)        return ;;   # unresolved relative segment: a DECLARED residual (header), never a guess
    lib/*)       printf 'lib:%s\n' "${1#lib/}" ;;
    # A sub-path under a `state/` destination stays `state:` (it is still state-resident); anywhere else
    # it is `other:` so the farm's subdir delivery branches can see it.
    */*)         case "${2:-script}" in
                   state) printf 'state:%s\n' "$1" ;;
                   *)     printf 'other:%s\n' "$1" ;;
                 esac ;;
    *.py|*.sh)   printf '%s:%s\n' "${2:-script}" "$1" ;;
  esac
}
_producer_scan() { # <file> -> "<kind>:<name>" lines
  local f="$1" rel line
  # F1 + F2 — a path anchored at the consumer's OWN directory: $SCRIPTS / $SCRIPT_DIR / `... && pwd)` /
  # a bare `$(dirname "${BASH_SOURCE[0]}")`. Normalized before classification, because `..` segments
  # resolve relative to that directory: `$SCRIPTS/../scripts/x.sh` IS the flat farm destination.
  rel="$(
    { grep -ohE '\$\{?(SCRIPTS|SCRIPT_DIR|SCRIPTDIR)\}?/[A-Za-z0-9_./-]+\.(py|sh)' "$f" 2>/dev/null || true
      grep -ohE 'pwd\)/[A-Za-z0-9_./-]+\.(py|sh)' "$f" 2>/dev/null || true
      grep -ohE '\$\(dirname[^)]*\)/[A-Za-z0-9_./-]+\.(py|sh)' "$f" 2>/dev/null || true
    } | sed -E -e 's|^\$\{?[A-Z_]+\}?/||' -e 's|^pwd\)/||' -e 's|^\$\(dirname[^)]*\)/||' \
        -e 's|^\.\./scripts/||' -e 's|[^/]+/\.\./||' -e 's|[^/]+/\.\./||' -e 's|^scripts/||'
  )"
  # Unresolved `..` after normalization is a DECLARED residual (header), never a guess — the classifier
  # drops it. `lib/` -> lib:, any other sub-path -> other:, a bare name -> script:.
  printf '%s\n' "$rel" | while IFS= read -r line; do _producer_kind "$line"; done
  # F3 — an ABSOLUTE path inside the AGENT DIR, in either of its two homes: `agent/scripts/<n>` is the
  # flat farm destination (cadence-nudge.sh:292 spells it that way, which `$SCRIPTS` alone cannot see)
  # and `agent/state/<p>` is the state class. The state side keeps its SUB-PATH where the source gives
  # one — only the F5 side cannot (its join prefix lives in another variable; header residual), so a
  # new `state/<dir>/<n>` cannot inherit an existing residual's owner.
  { grep -ohE 'agent/(scripts|state)/[A-Za-z0-9_./-]+\.(py|sh)' "$f" 2>/dev/null || true; } \
    | sed -E 's|^agent/scripts/lib/|lib:|; s|^agent/scripts/|script:|; s|^agent/state/|state:|'
  # F3b — the SAME agent-dir path written as a python join LIST, one segment per argument (live at
  # `queue-dispatch.py:56-57` and `turn-classify.py:820`). F3's contiguous-string regex cannot see it,
  # and a consumer that adds an exec next to those lines inherits the spelling — so an unhandled F3b
  # would let a producer no array delivers enter the population as NOTHING, which is #1899 itself.
  { grep -ohE 'os\.path\.join\((HOME|[A-Z_]+), *"[^"]*", *"agent", *"(scripts|state)", *"[A-Za-z0-9_-]+\.(py|sh)"\)' "$f" 2>/dev/null || true; } \
    | sed -E 's|.*"agent", *"scripts", *"([^"]+)"\)|script:\1|; s|.*"agent", *"state", *"([^"]+)"\)|state:\1|'
  # F4 / F5 — python path joins (the `lane-actions.py` / `live-workspaces-publisher.py` shape). The
  # matched name may be a SUB-PATH (`os.path.join(SCRIPTS, "lib", "x.sh")`, and the f-string form
  # `f"{SCRIPTS}/lib/x.sh"` below): F1 already declares `$SCRIPTS/lib/<n>` for bash, so the join forms owe
  # the same destination the same meaning — hence `_producer_kind`, never a hardcoded `script:`.
  # ...and a join may take SEVERAL quoted segments, so EVERY segment is captured and re-joined with `/`
  # (`os.path.join(SCRIPTS, "lib", "x.sh")` -> `lib/x.sh`). A single-segment regex silently missed the
  # sub-path form, which then read as `other:`-shaped garbage or as nothing at all.
  { grep -ohE 'os\.path\.join\((SCRIPTS|SCRIPT_DIR|HERE)(, *"[A-Za-z0-9_./-]*")+' "$f" 2>/dev/null || true; } \
    | sed -E 's|^os\.path\.join\([A-Z_]+,? *||; s|" *, *"|/|g; s|^"||; s|"$||' \
    | while IFS= read -r line; do _producer_kind "$line" script; done
  { grep -ohE 'os\.path\.join\((STATE|STATE_DIR)(, *"[A-Za-z0-9_./-]*")+' "$f" 2>/dev/null || true; } \
    | sed -E 's|^os\.path\.join\([A-Z_]+,? *||; s|" *, *"|/|g; s|^"||; s|"$||' \
    | while IFS= read -r line; do _producer_kind "$line" state; done
  # F4c — the python INLINE SELF-DIR join: `os.path.join(os.path.dirname(os.path.abspath(__file__)),
  # "lib", "<n>")`. This is the python counterpart of F2 (bash self-dir) and it is spelled LIVE twice in
  # this farmed layer — `lane-watchdog.py:94-95` (its `lib_path()`), plus the retired
  # `queue-dispatch.py:515` until #1874 — so a new
  # producer added beside either call is not a theoretical case: no form saw this prefix, and an exec site
  # written that way would have entered the population as NOTHING while the SUMMARY stayed clean.
  { grep -ohE 'os\.path\.join\(os\.path\.dirname\([^)]*__file__[^)]*\)+(, *"[A-Za-z0-9_./-]*")+' "$f" 2>/dev/null || true; } \
    | sed -E -e 's/^.*__file__[^"]*//' -e 's/^[^"]*"//' -e 's/" *, *"/\//g' -e 's/["]+\)*$//' \
    | while IFS= read -r line; do _producer_kind "$line" script; done
  # F4b — the same destination as a python F-STRING (live at `turn-classify.py:929` and
  # `turn-end.py:310`: `f"{SCRIPTS}/lane-status.py"`). A different syntax from F4's literal join, and
  # the spelling TWO consumers already use — so an exec site added beside them would have been derived
  # as NOTHING while both the pin and the disposition stayed green. That is #1899's blindness one
  # syntax down, and the declared surface omitted it.
  { grep -ohE 'f"\{(SCRIPTS|SCRIPT_DIR|HERE)\}/[A-Za-z0-9_./-]+\.(py|sh)"' "$f" 2>/dev/null || true; } \
    | sed -E 's|.*\{.*\}/(.*)"|\1|' | while IFS= read -r line; do _producer_kind "$line" script; done
  { grep -ohE 'f"\{(STATE|STATE_DIR)\}/[A-Za-z0-9_./-]+\.(py|sh)"' "$f" 2>/dev/null || true; } \
    | sed -E 's|.*\{.*\}/(.*)"|\1|' | while IFS= read -r line; do _producer_kind "$line" state; done
  # F7 — pathlib division: `Path(SCRIPTS) / "<n>"` (8 modules under scripts/ already `import pathlib`).
  { grep -ohE '(pathlib\.)?Path\((SCRIPTS|SCRIPT_DIR|HERE|STATE|STATE_DIR)\) */ *"[A-Za-z0-9_./-]+\.(py|sh)"' "$f" 2>/dev/null || true; } \
    | sed -E 's|.*Path\(STATE(_DIR)?\) */ *"(.*)"|state \2|; s|.*Path\([A-Z_]+\) */ *"(.*)"|\1|' \
    | while IFS= read -r line; do
        case "$line" in
          state\ *) _producer_kind "${line#state }" state ;;
          *)         _producer_kind "$line" script ;;
        esac
      done
  # F8 — the bash STATE sibling: `"$STATE/<p>"` / `"${STATE}/<p>"` / `"$STATE_DIR/<p>"`, the state
  # class's equivalent of F1 (STATE="$HOME/.pi/agent/state", set at heartbeat-loop.sh:54). Its last
  # LIVE instance — `$STATE/queues/refresh-queues.py` at :415 — was retired by #1874 with the
  # lane-table dispatcher, so no live site uses F8 today; the form is KEPT because the next
  # `$STATE/<p>` exec site is exactly the blindness #1899 exists to refuse, and this scanner must
  # already see it. It needs its OWN form rather than an F1 alternative:
  # F1's classify strip is generic, so a `$STATE/` line reaching it would file as `other:`, not `state:`.
  # The sub-path is KEPT (the F5 residual): `queues/<n>` and a flat `<n>` are different files.
  { grep -ohE '\$\{?(STATE|STATE_DIR)\}?/[A-Za-z0-9_./-]+\.(py|sh)' "$f" 2>/dev/null || true; } \
    | sed -E 's|^\$\{?[A-Z_]+\}?/||' | while IFS= read -r line; do _producer_kind "$line" state; done
  # F6 — an ABSOLUTE path OUTSIDE the agent dir: another checkout's file. ANY directory, not just `scripts/`:
  # the first version of this form hardcoded `<…>/scripts/<n>` and therefore could not see
  # `scripts/safe-send.sh:146`, which runs `…/tortoise/tools/cmux_dispatch.py` — a producer in a DIFFERENT
  # checkout, in no farm array, undisclosed, while the gate printed `DECLARED-FOREIGN: … 1` as if that were the
  # whole class (#1957). A cross-checkout `tools/`, `bin/` or `lib/` is the same failure as `scripts/`.
  # BOTH agent dirs are excluded — F3 owns `agent/scripts/<n>` and `agent/state/<p>`, so the state producer
  # (`lane-confirm.py`, orchestrator-heartbeat.sh:336) does not also surface here as a duplicate `foreign:`.
  { grep -ohE '/(Users|home)/[A-Za-z0-9_./-]+/[A-Za-z0-9_-]+\.(py|sh)' "$f" 2>/dev/null || true; } \
    | { grep -vE '/agent/(scripts|state)/' || true; } | sed -E 's|.*/||; s|^|foreign:|'
}
# Is this entry the SAME FILE as the one being scanned — a usage line, a docstring example, a
# canonical-location comment — or a DIFFERENT file that merely shares its basename? Basename equality alone
# is too coarse: `scripts/entry.sh` exec'ing `$SCRIPTS/lib/entry.sh` names a DIFFERENT executable, and
# dropping it shrinks the population silently (the pin only pins what the scan FINDS, so nothing notices).
# So a basename match is a SELF edge only when the entry's implied repo path is absent (a state/ or foreign/
# location the file documents about itself) or IS the scanned file.
_self_edge() { # <root> <scanned-rel-path> <entry> -> 0 when the entry IS the scanned file
  local root="$1" p="$2" e="$3" base="${p##*/}" implied
  [ "${e#*:}" = "$base" ] || return 1          # a different basename: never a self edge
  case "${e%%:*}" in
    script) implied="scripts/$base" ;;
    lib)    implied="scripts/lib/$base" ;;
    other)  implied="scripts/${e#other:}" ;;
    # state:/foreign/: a location this repo does not hold, so the file can only be documenting ITSELF
    # there (`map-sessions.py`'s usage block names `~/.pi/agent/state/map-sessions.py`).
    *)      return 0 ;;
  esac
  [ -f "$root/$implied" ] && [ "$implied" != "$p" ] && return 1
  return 0
}
# derive_lane_producers <repo-root> [entrypoint...] -> "<kind>:<name>" lines, sorted, de-duplicated
#
# ROOTS = every file the arrays in `FARM_ARRAYS` deliver (each read from its own source dir — see
# `farm_source_dir`) plus each ENTRYPOINT argument, which is REPORTED as a producer as well as scanned.
# CLOSURE = scan every producer that exists in the repo, to a fixpoint, so a producer's OWN producers
# are in the population — that is how `lane-watchdog.py` is reached from `heartbeat-loop.sh`, and
# `publish-live-workspaces.py` from `live-workspaces-publisher.py`. Each file is scanned ONCE (the
# done-list persists across passes), and the arrays are read from <repo-root>, so the closure probe
# below can drive a synthetic tree instead of this checkout.
derive_lane_producers() {
  local root="$1"; shift
  local scan="$TMP/producer-scan.list" done_list="$TMP/producer-done.list" found="$TMP/producer-found.list"
  local pass=0 n_before n_after a e p
  : > "$scan"; : > "$done_list"; : > "$found"
  for a in $FARM_ARRAYS; do
    farm_array_entries "$a" "$root" | sed "s|^|$(farm_source_dir "$a")/|" >> "$scan"
  done
  for e in "$@"; do printf '%s\n' "$e" >> "$scan"; done
  sort -u -o "$scan" "$scan"
  while :; do
    pass=$((pass+1))
    n_before="$(wc -l < "$scan" | tr -d ' ')"
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      [ -f "$root/$p" ] || continue
      if grep -Fxq -- "$p" "$done_list"; then continue; fi
      printf '%s\n' "$p" >> "$done_list"
      # Drop SELF-edges (see `_self_edge`): a file naming its own deployed path is not a producer of
      # itself, but a file naming a DIFFERENT file that shares its basename IS one.
      _producer_scan "$root/$p" | while IFS= read -r e; do
        _self_edge "$root" "$p" "$e" || printf '%s\n' "$e"
      done >> "$found"
    done < "$scan"
    sort -u -o "$found" "$found"
    # Queue every found producer that EXISTS in the repo, so its own exec sites are scanned next pass.
    while IFS= read -r p; do
      case "$p" in
        script:*) printf 'scripts/%s\n' "${p#script:}" ;;
        lib:*)    printf 'scripts/lib/%s\n' "${p#lib:}" ;;
        # `other:fleet/<n>` is farmed from `tools/fleet/`, NOT from the destination path — enqueueing
        # `scripts/fleet/<n>` would silently make it a leaf and drop its own producers.
        other:fleet/*) printf 'tools/fleet/%s\n' "${p#other:fleet/}" ;;
        other:*)  printf 'scripts/%s\n' "${p#other:}" ;;
      esac
    done < "$found" >> "$scan"
    sort -u -o "$scan" "$scan"
    n_after="$(wc -l < "$scan" | tr -d ' ')"
    [ "$n_after" -eq "$n_before" ] && break
    # A runaway guard, not a bound on quality: the closure is 2–3 passes on this repo.
    [ "$pass" -lt 8 ] || { echo "producer closure did not converge in $pass passes" >&2; return 3; }
  done
  # The ENTRYPOINTS are producers in their own right (they must be delivered too), so report them —
  # one path per argument: a whitespace-joined value here would stop being scanned the moment a second
  # entrypoint joined the list, and report itself as `other:`.
  for e in "$@"; do producer_kind_of "$e"; printf '\n'; done >> "$found"
  sort -u "$found"
}

# _owner_of <"name:#issue ..."> <name> -> prints the owner, non-zero when the name is not listed.
_owner_of() {
  local item
  for item in $1; do
    case "$item" in "$2:"*) printf '%s' "${item#*:}"; return 0 ;; esac
  done
  return 1
}
# The DRIFT CONTROL: the derived population must BE the pinned set, both ways. Every way this guard
# can silently stop seeing a producer shows up here as a set difference that NAMES the entry.
check_producer_population() { # <label> <derived-population>
  local label="$1" derived="$2" added removed
  _PIN_RAN=1   # proof-of-wiring sentinel: asserted at the end of the #1899 block (see there)
  local dset cset
  dset="$(printf '%s\n' $derived | sed '/^$/d' | sort)"
  cset="$(printf '%s\n' $LANE_PRODUCERS_CANONICAL | sed '/^$/d' | sort)"
  if [ -z "$dset" ]; then
    fail "$label: the DERIVED producer population is EMPTY — 0/0 must never read as clean, and a scan that found nothing has verified nothing (#1899)"
    return
  fi
  if [ "$dset" = "$cset" ]; then
    echo "ok: $label derived producer population ($(printf '%s\n' "$dset" | wc -l | tr -d ' ') entries) == the pinned set (#1899)"
    return
  fi
  printf '%s\n' "$cset" > "$TMP/producer.pop.canonical"
  printf '%s\n' "$dset" > "$TMP/producer.pop.derived"
  added="$(comm -13 "$TMP/producer.pop.canonical" "$TMP/producer.pop.derived" | tr '\n' ' ')"
  removed="$(comm -23 "$TMP/producer.pop.canonical" "$TMP/producer.pop.derived" | tr '\n' ' ')"
  fail "$label: the DERIVED producer population is not the pinned set — a producer moved. ADDED: ${added:-none} | REMOVED: ${removed:-none}. An ADDED producer is one a farmed consumer now EXECS: give it a disposition (a farm array; LANE_PRODUCERS_EXEMPT with an owning issue for a deliverable-but-withheld producer; LANE_PRODUCERS_STATE_RESIDUAL or LANE_PRODUCERS_FOREIGN_RESIDUAL with an owning issue for a class the farm cannot carry) and re-pin. A REMOVED producer means an exec site was lost or the extraction stopped seeing a form — verify the CODE, not the pin (#1899)"
}
# The DISPOSITION: every derived producer must be DELIVERED by a farm array, EXEMPTED with an owning
# issue, or DISCLOSED as a `state/`- or `foreign/`-resident residual with an owning issue. Never `ok:`
# while any gap — including a stale disclosure — remains, and the tally is printed either way.
check_producer_farm_declared() { # <label> <derived-population>
  _DISPO_RAN=1  # proof-of-wiring sentinel: asserted at the end of the #1899 block (see there)
  local label="$1" pop="$2" pair kind name owner n=0 delivered=0 missing="" missing_n=0
  local gap="" gap_n=0 residual="" residual_n=0 foreign="" foreign_n=0 stale="" item sub base
  local applied=" "   # kind-qualified names a DISCLOSURE actually did work for THIS run
  local root="${3:-$ROOT}"   # a probe may point the delivery lookup at a synthetic tree
  for pair in $pop; do
    [ -n "$pair" ] || continue
    kind="${pair%%:*}"; name="${pair#*:}"
    n=$((n+1))
    case "$kind" in
      state)
        # The farm cannot deliver this class at all — see the header. Named-and-owned is the only
        # honest state; UNNAMED is a failure, so a new `state/` exec site cannot slip in.
        if owner="$(_owner_of "$LANE_PRODUCERS_STATE_RESIDUAL" "$name")"; then
          residual_n=$((residual_n+1)); residual="$residual $name($owner)"
          applied="$applied state:$name "
        else
          missing="$missing state/$name"; missing_n=$((missing_n+1))
        fi
        continue ;;
      foreign)
        # Outside this repo by absolute path: deliverable by another checkout, never by this farm.
        if owner="$(_owner_of "$LANE_PRODUCERS_FOREIGN_RESIDUAL" "$name")"; then
          foreign_n=$((foreign_n+1)); foreign="$foreign $name($owner)"
          applied="$applied foreign:$name "
        else
          missing="$missing foreign/$name"; missing_n=$((missing_n+1))
        fi
        continue ;;
      lib)
        if farm_declares lib_srcs "$name" "$root"; then delivered=$((delivered+1)); continue; fi ;;
      script)
        # Every FLAT array counts: `lane_root_srcs` is absent on this tree until #1553 (the membership
        # branch simply goes false), and `merge_gate_srcs` also lands in `$DEST/scripts/`.
        if farm_declares fleet_srcs "$name" "$root" || farm_declares lane_root_srcs "$name" "$root" \
           || farm_declares merge_gate_srcs "$name" "$root"; then
          delivered=$((delivered+1)); continue
        fi
        # The fleet directory IS a real deployed location (`setup.sh` mkdirs `$DEST/scripts/fleet/`), so
        # an exec spelled `agent/scripts/fleet/<n>` arrives here as `script:fleet/<n>` and is delivered by
        # `fleet_tools` exactly like the `other:fleet/<n>` spelling. Without this it would be a FALSE BLOCK
        # — and the natural remedy for a false block is to widen the exemption list, i.e. to weaken the gate.
        if [ "${name%%/*}" = "fleet" ] && [ "$name" != "${name##*/}" ] \
           && farm_declares fleet_tools "${name##*/}" "$root"; then
          delivered=$((delivered+1)); continue
        fi ;;
      other)
        # A subdirectory destination has TWO ways to be delivered, and both are checked before the
        # disclosure path — otherwise the check false-blocks a file that IS farmed (and the natural
        # "fix" for a false block is to weaken the list, i.e. to make the gate worse):
        #   * `fleet_tools` farms `tools/fleet/` INTO `$DEST/scripts/fleet/`, so a `$SCRIPTS/fleet/<n>`
        #     exec site is delivered by that array;
        #   * setup.sh also DIRECTORY-GLOB farms `scripts/checkout-hygiene/*` (a loop, not an array), so
        #     any member of that source dir is delivered without appearing in any array. Checked against
        #     the SOURCE dir, which is what the loop iterates.
        sub="${name%%/*}"; base="${name##*/}"
        if [ "$sub" = "fleet" ] && farm_declares fleet_tools "$base" "$root"; then
          delivered=$((delivered+1)); continue
        fi
        # ...and the loop SKIPS some members (`setup.sh`: `*.plist|*.test.*) continue`), so a skipped file
        # is NOT delivered — counting it as delivered is the gate's central false negative.
        case "$base" in
          *.plist|*.test.*) ;;
          *) if [ "$sub" = "checkout-hygiene" ] && [ -f "$root/scripts/$name" ]; then
               delivered=$((delivered+1)); continue
             fi ;;
        esac ;;
      *)
        missing="$missing unknown-kind:$kind"; missing_n=$((missing_n+1))
        continue ;;
    esac
    if owner="$(_owner_of "$LANE_PRODUCERS_EXEMPT" "$name")"; then
      gap_n=$((gap_n+1)); gap="$gap $name($owner)"
      # EXEMPT is `script:`, `lib:` AND `other:` (every kind that falls through the case above), so the
      # applied record carries the kind that ACTUALLY routed here.
      applied="$applied $kind:$name "
    else
      missing="$missing $name"; missing_n=$((missing_n+1))
    fi
  done
  # A disclosure that outlives its reason is its own silent failure — and its reason is that it WAS
  # APPLIED, not that the producer still exists. Testing "is it in the population" is inert in exactly
  # the direction that matters: once #1553 delivers `lane-status.py` the exemption stays "live"
  # forever, and if a later PR drops it from `lane_root_srcs` the leftover exemption absorbs the
  # regression as a DECLARED-GAP line instead of a FAIL. So the test is membership of the APPLIED set
  # (a delivered producer is never in it, and neither is one no longer found at all), and it is
  # KIND-QUALIFIED — a bare-name match would let a `state:` disclosure survive on a same-named
  # `script:` producer, which is what happens when #1552 moves a file into `scripts/` and farms it.
  # EXEMPT spans three kinds (script | lib | other), and each is applied by the case above.
  for item in $LANE_PRODUCERS_EXEMPT; do
    case "$applied" in
      *" script:${item%%:*} "*|*" lib:${item%%:*} "*|*" other:${item%%:*} "*) ;;
      *) stale="$stale ${item%%:*}" ;;
    esac
  done
  for item in $LANE_PRODUCERS_STATE_RESIDUAL; do
    case "$applied" in *" state:${item%%:*} "*) ;; *) stale="$stale state:${item%%:*}" ;; esac
  done
  for item in $LANE_PRODUCERS_FOREIGN_RESIDUAL; do
    case "$applied" in *" foreign:${item%%:*} "*) ;; *) stale="$stale foreign:${item%%:*}" ;; esac
  done
  if [ "$n" -lt 1 ]; then
    fail "$label: the producer population handed to this check is EMPTY — 0/0 must never read as clean (#1899)"
    return
  fi
  [ -z "$stale" ] \
    || fail "$label: STALE disclosure — declared but NOT APPLIED this run (its producer is delivered now, moved, or gone):$stale — delete it from LANE_PRODUCERS_EXEMPT / LANE_PRODUCERS_STATE_RESIDUAL / LANE_PRODUCERS_FOREIGN_RESIDUAL, so an exemption cannot outlive its reason (#1899)"
  [ -z "$missing" ] \
    || fail "$label: producer(s) exec'd by a farmed consumer and DELIVERED BY NOTHING:$missing — a fresh \$DEST/scripts gets the farmed consumer without the executable it calls (#1552/#1899). Remedy: add it to the farm array whose destination it belongs in (see FARM_ARRAYS / farm_source_dir), or — if no array can carry it — to the list for its KIND and the owning issue: LANE_PRODUCERS_EXEMPT (a deliverable producer withheld on purpose), LANE_PRODUCERS_STATE_RESIDUAL (state/-resident) or LANE_PRODUCERS_FOREIGN_RESIDUAL (another checkout) — then re-cut LANE_PRODUCERS_CANONICAL"
  # ALWAYS report the split — a check whose only clean line is unreachable (the state class can never
  # be delivered) leaves a reader unable to tell "nothing is missing" from "this never ran".
  if [ "$gap_n" -gt 0 ]; then
    # Echo the names ACTUALLY exempted THIS run, never the static list: after a partial #1553
    # landing a full-list echo contradicts its own count.
    echo "DECLARED-GAP: $label deliverable lane producers still withheld: $gap_n/$n ($gap) (#1552)"
  fi
  if [ "$residual_n" -gt 0 ]; then
    echo "DECLARED-RESIDUAL: $label state/-resident producers exec'd by a farmed consumer and deliverable by NO farm array: $residual_n ($residual) — those consumers ship broken on a fresh box (#1899)"
  fi
  if [ "$foreign_n" -gt 0 ]; then
    echo "DECLARED-FOREIGN: $label producers exec'd from ANOTHER checkout by absolute path: $foreign_n ($foreign) — absent from every box without that checkout (#1899)"
  fi
  if [ -z "$missing" ] && [ -z "$stale" ] && [ "$gap_n" -eq 0 ] && [ "$residual_n" -eq 0 ] && [ "$foreign_n" -eq 0 ]; then
    echo "ok: $label all $delivered derived lane producers declared in a farm array (#1552/#1899)"
  fi
  echo "SUMMARY: $label $n derived producer(s) = $delivered delivered + $((gap_n+residual_n+foreign_n)) disclosed with an owning issue + $missing_n undelivered-and-undisclosed + $(printf '%s\n' ${stale:-} | grep -c . || true) stale disclosure(s) (#1899)"
}

# ---------------------------------------------------------------------------------------------
# PROBES. Each one runs in a COMMAND SUBSTITUTION, so its FAILURES increments cannot leak into this
# suite's counter (the PR #1855 pattern, generalised) — and each asserts a FAILURE the guard must
# produce, so a guard that stopped firing reads as the defect it is rather than as a green.
# ...and a variant that returns WHAT the probe SAID, for the probes whose point is not "it failed" but
# "it failed for the reason it exists". A probe that only counts FAILURES passes for the wrong reason
# the moment any other defect in the same call also fails — measured: the kind-qualified staleness probe
# was satisfied by an unrelated undelivered-producer failure, so a KIND-BLIND mutation survived it.
producer_probe_msg() { # <check-fn> <label> <population> -> merged output, FAILURES restored
  local fn="$1" saved="$FAILURES" out
  shift
  out="$("$fn" "$@" 2>&1)"
  FAILURES="$saved"
  printf '%s' "$out"
}
producer_probe() { # <check-fn> <label> <population> -> the FAILURES delta, on stdout
  local fn="$1" saved="$FAILURES" delta
  shift
  "$fn" "$@" >/dev/null 2>&1
  delta=$((FAILURES - saved))
  FAILURES="$saved"
  printf '%s' "$delta"
}
# FORMS — every extraction form the header declares, on one synthetic consumer pair (hermetic: no
# repo file is touched). A form dropped from `_producer_scan` without being dropped from the header
# fails HERE, which is what keeps the declared surface and the implemented one the same surface. One
# line per form; a form with no line here is a form nobody proved live.
PROBE_FORMS="$TMP/producer-forms"
mkdir -p "$PROBE_FORMS"
cat > "$PROBE_FORMS/consumer.sh" <<'PROBE_FORMS_EOF'
#!/bin/bash
A=$(/usr/bin/python3 "$SCRIPTS/peer.py" 2>/dev/null)                                    # F1 flat
. "$SCRIPTS/lib/shared.sh"                                                              # F1 lib
NORMALIZER="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/normalize.py"       # F2 pwd)
LIB2="${LIB2:-$(dirname "${BASH_SOURCE[0]}")/lib/second.sh}"                            # F2 dirname
FEED=$(/usr/bin/python3 "$HOME/.pi/agent/scripts/flat-home.py" 2>/dev/null)             # F3 scripts
TRV=$(/usr/bin/python3 "$HOME/.pi/agent/state/lane-triage.py" 2>/dev/null)              # F3 state
SUB=$(/usr/bin/python3 "$HOME/.pi/agent/state/queues/claim.py" 2>/dev/null)             # F3 sub-path
SD=$(/usr/bin/python3 "${SCRIPT_DIR}/f1-scriptdir.py" 2>/dev/null)                  # F1 ${SCRIPT_DIR}
SD2=$(/usr/bin/python3 "${SCRIPTDIR}/f1-scriptdir2.py" 2>/dev/null)                     # F1 ${SCRIPTDIR}
JOINL=$(/usr/bin/python3 "$HOME/.pi/agent/scripts/f3b-flat.py" 2>/dev/null)              # F3b sh join-list
FAR=$(cat /tmp/pm.txt | bash /Users/someone/Documents/GitHub/eldato/scripts/postmortem.sh)  # F6 /Users
FAR2=$(cat /tmp/pm.txt | bash /home/someone/scripts/f6-home.sh)                         # F6 /home
FAR3=$(cat /tmp/pm.txt | bash /Users/someone/Documents/GitHub/otherrepo/tools/f6-tools.py)   # F6 non-scripts dir
EXCL=$(cat /tmp/pm.txt | bash /home/someone/agent/scripts/f6-excluded.py)               # F6 exclusion: DROPPED
NEAR="$SCRIPTS/../scripts/normalized.py"                                                # norm: ^../scripts/
MID="$SCRIPTS/a/../b/../norm-mid.py"                                                    # norm: x/../ twice
PREF="$(dirname "${BASH_SOURCE[0]}")/scripts/norm-prefixed.py"                          # norm: ^scripts/
UP="$SCRIPTS/../elsewhere/unresolved-relative.py"                                       # declared residual: must be DROPPED
S8A=$(/usr/bin/python3 "$STATE/f8-state.py" 2>/dev/null)                                # F8 $STATE
S8B=$(/usr/bin/python3 "${STATE_DIR}/f8-statedir.py" 2>/dev/null)                       # F8 ${STATE_DIR}
S8C=$(/usr/bin/python3 "$STATE/queues/f8-queues.py" --apply)                            # F8 sub-path
(F3b's non-HOME variable is proven on the join-LIST shape in consumer.py — see VB there.)
PROBE_FORMS_EOF
cat > "$PROBE_FORMS/consumer.py" <<'PROBE_FORMS_EOF'
import os, pathlib
from pathlib import Path
HERE = os.path.dirname(os.path.abspath(__file__))
STATE = os.path.join(HERE, os.pardir, "state")
PUBLISH = os.path.join(HERE, "publish-live-workspaces.py")          # F4 HERE
SD = os.path.join(SCRIPT_DIR, "f4-scriptdir.py")                    # F4 SCRIPT_DIR
SC = os.path.join(SCRIPTS, "f4-scripts.py")                         # F4 SCRIPTS
LV = os.path.join(STATE, "lane-verdict.py")                         # F5 STATE
LVD = os.path.join(STATE_DIR, "f5-statedir.py")                     # F5 STATE_DIR
JFLAT = os.path.join(HOME, ".pi", "agent", "scripts", "f3b-flat-py.py")      # F3b (py join list)
JSTATE = os.path.join(HOME, ".pi", "agent", "state", "f3b-state.py")         # F3b (py join list)
FS = f"{SCRIPTS}/f4b-scripts.py"                                            # F4b SCRIPTS
FSD = f"{SCRIPT_DIR}/f4b-scriptdir.py"                                      # F4b SCRIPT_DIR
FSH = f"{HERE}/f4b-here.py"                                                 # F4b HERE
FSS = f"{STATE_DIR}/f5b-state.py"                                           # F5 as an f-string
FSS2 = f"{STATE}/f5b-state2.py"                                             # F5 as an f-string (STATE)
FSL = f"{SCRIPTS}/lib/f4b-lib.sh"                                           # F4b sub-path -> lib:
JL = os.path.join(SCRIPTS, "lib", "f4-lib.sh")                              # F4 sub-path -> lib:
P7 = pathlib.Path(SCRIPTS) / "f7-scripts.py"                                # F7 scripts
P8 = str(pathlib.Path(STATE_DIR) / "f7-state.py")                           # F7 STATE_DIR
P9 = pathlib.Path(SCRIPT_DIR) / "f7-scriptdir.py"                           # F7 SCRIPT_DIR
P10 = pathlib.Path(HERE) / "f7-here.py"                                     # F7 HERE
P11 = pathlib.Path(STATE) / "f7-state2.py"                                  # F7 STATE
P12 = Path(SCRIPTS) / "f7-bare.py"                                          # F7 bare (from pathlib import Path)
VB = os.path.join(PI_AGENT, ".pi", "agent", "scripts", "f3b-var.py")   # F3b: a variable that is not HOME
SDC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "f4c-selfdir.py")     # F4c
SDCL = os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib", "f4c-lib.sh") # F4c lib
PROBE_FORMS_EOF
# Two ABSENCES carry a property each, and they are different properties:
#   * `f6-excluded.py` IS expected as `script:f6-excluded.py` (F3 sees any `agent/scripts/<n>`, absolute or
#     not) and is ABSENT as `foreign:f6-excluded.py` — the F6 `/agent/scripts/` exclusion is what keeps it out
#     of the foreign kind, so deleting that exclusion adds a member and goes red;
#   * `unresolved-relative.py` is ABSENT entirely: a `..` the normalization cannot resolve is a DECLARED
#     residual and must be DROPPED, never guessed into an entry. Deleting the guard adds
#     `other:../elsewhere/...` and goes red.
# ⛔ EVERY NAME BELOW IS UNIQUE TO ITS SPELLING. A name shared by two forms proves neither: mutate one
# alternation and the other form still emits the name, the probe stays green, and the header goes on
# claiming a spelling that is dead. (Reviewer B proved exactly that on the pre-fix probes.)
forms_want="$(printf '%s\n' \
  foreign:f6-home.sh foreign:f6-tools.py foreign:postmortem.sh lib:f4-lib.sh lib:f4b-lib.sh lib:f4c-lib.sh lib:normalize.py \
  lib:second.sh lib:shared.sh \
  script:f1-scriptdir.py script:f1-scriptdir2.py script:f3b-flat-py.py script:f3b-flat.py \
  script:f4-scriptdir.py script:f4-scripts.py script:f4b-here.py script:f4b-scriptdir.py \
  script:f3b-var.py script:f4b-scripts.py script:f4c-selfdir.py script:f6-excluded.py \
  script:f7-bare.py \
  script:f7-here.py script:f7-scriptdir.py script:f7-scripts.py \
  script:flat-home.py script:norm-mid.py script:norm-prefixed.py \
  script:normalized.py script:peer.py script:publish-live-workspaces.py \
  state:f3b-state.py state:f5-statedir.py state:f5b-state.py state:f5b-state2.py \
  state:f7-state.py state:f7-state2.py state:f8-state.py state:f8-statedir.py \
  state:lane-triage.py \
  state:lane-verdict.py state:queues/claim.py state:queues/f8-queues.py | sort)"
forms_got="$({ _producer_scan "$PROBE_FORMS/consumer.sh"; _producer_scan "$PROBE_FORMS/consumer.py"; } | sort -u)"
if [ "$forms_got" = "$forms_want" ]; then
  echo "ok: every declared extraction form AND spelling (F1 \$SCRIPTS/\${SCRIPT_DIR}/\${SCRIPTDIR}/lib, F2 pwd/dirname, F3 + F3b agent-dir, F4 SCRIPTS/SCRIPT_DIR/HERE, F4b f-string for both classes, F7 pathlib, F4c python self-dir, F8 bash \$STATE/\$STATE_DIR (with a sub-path), F5 STATE/STATE_DIR, F6 foreign; joins and f-strings routed through ONE classifier so a sub-path lands on lib:/other:) and ALL THREE normalization rules ('^../scripts/', 'x/../' twice, '^scripts/') are LIVE in _producer_scan (#1899)"
else
  fail "the extraction forms do not match the DECLARED surface — got:$(printf '\n  %s' $forms_got | tr '\n' '|') want:$(printf '\n  %s' $forms_want | tr '\n' '|') (#1899)"
fi
# CLOSURE — the derivation must close TRANSITIVELY (a producer's own producers are in the population)
# and must REPORT an entrypoint handed to it, from a synthetic tree so the probe cannot drift with the
# real repo.
PROBE_CLOSURE="$TMP/producer-closure"
mkdir -p "$PROBE_CLOSURE/scripts" "$PROBE_CLOSURE/scripts/lib" "$PROBE_CLOSURE/pi-bootstrap" \
  "$PROBE_CLOSURE/tools/fleet"
printf 'fleet_srcs=(root.sh)\nlib_srcs=(lib-root.sh)\nmerge_gate_srcs=()\nfleet_tools=(tool-fleet.py)\n' > "$PROBE_CLOSURE/pi-bootstrap/setup.sh"
printf '#!/bin/bash\nY=$(/usr/bin/python3 "$SCRIPTS/hop1.py")\n' > "$PROBE_CLOSURE/scripts/root.sh"
printf '#!/bin/bash\nZ=$(/usr/bin/python3 "$SCRIPTS/hop2.py")\n' > "$PROBE_CLOSURE/scripts/hop1.py"
# A subdirectory dest (`$SCRIPTS/fleet/<n>`) must be followed to its REAL source dir (`tools/fleet/`),
# not to `scripts/fleet/` (which does not exist) — enqueueing the destination path would silently make
# this a leaf and drop `hop-deep.py` from the population.
printf '#!/bin/bash\nW=$(/usr/bin/python3 "$HOME/.pi/agent/state/lane-x.py")\nX=$(/usr/bin/python3 "$SCRIPTS/fleet/other-tool.py")\n' > "$PROBE_CLOSURE/scripts/hop2.py"
printf '#!/bin/bash\nD=$(/usr/bin/python3 "$SCRIPTS/hop-deep.py")\n' > "$PROBE_CLOSURE/tools/fleet/other-tool.py"
# A farm ROOT read from its OWN source dir, not from `scripts/` — proves `farm_source_dir` is applied.
printf '#!/bin/bash\nF=$(/usr/bin/python3 "$SCRIPTS/hop-fleet.py")\n' > "$PROBE_CLOSURE/tools/fleet/tool-fleet.py"
# A lib ROOT: `farm_source_dir lib_srcs` must read it from `scripts/lib/`, not `scripts/`. Its own exec
# site is the proof — with the arm wrong the root is never found, `hop4.py` silently leaves the
# population, and the set comparison stays green because it compares two sets that agree.
printf '#!/bin/bash\nL4=$(/usr/bin/python3 "$SCRIPTS/hop4.py")\n' > "$PROBE_CLOSURE/scripts/lib/lib-root.sh"
printf '#!/bin/bash\nS=$(/usr/bin/python3 "$SCRIPTS/lib/shared.sh")\n' > "$PROBE_CLOSURE/scripts/entry.sh"
# SAME BASENAME, DIFFERENT FILE: `entry3.sh` execs `lib/entry3.sh`. The self-edge filter must keep it —
# a basename-blind filter drops it, the closure never enqueues `scripts/lib/entry3.sh`, and `hop5.py`
# silently leaves the population (the pin stays green because it compares two sets that agree).
printf '#!/bin/bash\nE3=$(/usr/bin/python3 "$SCRIPTS/lib/entry3.sh")\n' > "$PROBE_CLOSURE/scripts/entry3.sh"
printf '#!/bin/bash\nH5=$(/usr/bin/python3 "$SCRIPTS/hop5.py")\n' > "$PROBE_CLOSURE/scripts/lib/entry3.sh"
printf '#!/bin/bash\nS2=$(/usr/bin/python3 "$SCRIPTS/hop3.py")\n' > "$PROBE_CLOSURE/scripts/entry2.sh"
# `root.sh` and `tool-fleet.py` are farm ROOTS, not found producers; `entry.sh`/`entry2.sh` are
# ENTRYPOINTS, so they ARE reported (every one of them — a second entrypoint that went unreported would
# be exactly the hand-list gap this gate exists to close).
closure_want="$(printf '%s\n' \
  lib:entry3.sh lib:shared.sh other:fleet/other-tool.py script:entry.sh script:entry2.sh \
  script:entry3.sh script:hop-deep.py \
  script:hop-fleet.py script:hop1.py script:hop2.py script:hop3.py script:hop4.py \
  script:hop5.py state:lane-x.py | sort)"
closure_got="$(derive_lane_producers "$PROBE_CLOSURE" scripts/entry.sh scripts/entry2.sh scripts/entry3.sh | sort -u)"
if [ "$closure_got" = "$closure_want" ]; then
  echo "ok: the producer closure is TRANSITIVE, follows a subdir dest to its real source dir, reads each root from its own dir, keeps a SAME-BASENAME substrate that is a different file, and reports EVERY entrypoint (5 hops + 3 entrypoints) (#1899)"
else
  fail "the producer closure is not transitive — got:$(printf '\n  %s' $closure_got | tr '\n' '|') want:$(printf '\n  %s' $closure_want | tr '\n' '|') (#1899)"
fi
# FARM-ARRAY FLOOR — an array setup.sh declares but the derivation does not read must FAIL. Without
# this probe the floor could be deleted and the only visible consequence would be a smaller population.
PROBE_FLOOR="$TMP/producer-floor"
mkdir -p "$PROBE_FLOOR/pi-bootstrap"
printf 'fleet_srcs=(a.sh)\nlib_srcs=()\nmerge_gate_srcs=()\nfleet_tools=()\nbrand_new_srcs=(b.sh)\n' > "$PROBE_FLOOR/pi-bootstrap/setup.sh"
if [ "$(producer_probe check_farm_arrays "$PROBE_FLOOR" "floor-probe")" -gt 0 ]; then
  echo "ok: a farm array the derivation does NOT read trips the root-set floor (#1899)"
else
  fail "an unread farm array did NOT trip the root-set floor — an unscanned array means invisible producers (#1899)"
fi
# DRIFT PIN — a population that cannot be built, or that shrank, substituted or GREW, must never read
# as clean. The GROWTH case is #1899's own defect: an exec site no farm array delivers.
#
# The population this run is judged on, derived ONCE. Both checks below consume the SAME value, so the
# population that is PINNED and the population that is DISPOSITIONED can never disagree.
# FIRST: the derivation's ROOT set must cover every farm array setup.sh declares, or a consumer the
# farm delivers is never scanned and its producers are invisible — a silently smaller population, which
# is the #1899 defect one level up. The list of arrays is checked against setup.sh, not trusted.
# The TWO real-tree invocations below are the only detectors of a population that silently SHRANK (a
# form `forms-probe` does not cover) and of an unread farm array. Every probe calls these functions
# directly, so a probe set alone cannot see the wiring: deleting either invocation leaves the suite green.
# They are proven by the SENTINEL assertion at the end of this block, NOT by re-asserting their output —
# an output assertion cannot tell "never ran" from "ran and failed", and reporting a drift failure as
# "its invocation is unproven" sends the reader to the wrong file.
check_farm_arrays "$ROOT" "run1"
LANE_PRODUCERS_DERIVED=""
_ENTRY_ARGS=""
for _e in $LAUNCHD_ENTRY_PRODUCERS; do _ENTRY_ARGS="$_ENTRY_ARGS scripts/$_e"; done
# shellcheck disable=SC2086  # $_ENTRY_ARGS is a deliberate word list of entrypoint paths
if LANE_PRODUCERS_DERIVED="$(derive_lane_producers "$ROOT" $_ENTRY_ARGS)"; then
  :
else
  fail "could not derive the producer population (the exec-site closure did not converge) — refusing to report completeness over a population the guard could not build (#1899)"
fi
check_producer_population "producer-set" "$LANE_PRODUCERS_DERIVED"
# EMPTY — the maximal silent skip: a scan that found nothing has verified nothing, and 0/0 must never
# read as clean (the H1 probe from PR #1855, now against the derivation instead of a hand list).
# Asserted on the MESSAGE, not the count: an empty set ALSO trips the set comparison, so a count-only
# assertion is satisfied with the empty-population branch deleted (mutation-verified).
case "$(producer_probe_msg check_producer_population "pin-probe-empty" "")" in
  *"population is EMPTY"*)
    echo "ok: an EMPTY derived population trips the population floor (0/0 never reads as clean)" ;;
  *) fail "an EMPTY derived population did NOT trip the population floor — the guard read 0/0 as clean" ;;
esac
# UNDERSIZED — one producer dropped, every remaining entry delivered or dispositioned, so ONLY the set
# comparison can catch it: the exact shape of a delivery set that lost an entry.
POP_SHORT="$(printf '%s\n' $LANE_PRODUCERS_CANONICAL | grep -vx 'script:objective.py' | tr '\n' ' ')"
if [ "$(producer_probe check_producer_population "pin-probe-short" "$POP_SHORT")" -gt 0 ]; then
  echo "ok: a DROPPED producer trips the population pin (the set is bound, not merely counted)"
else
  fail "a DROPPED producer did NOT trip the population pin — an undersized population read as clean"
fi
# COUNT-PRESERVING substitution (review H7, PR #1855, carried forward): drop `objective.py` and
# duplicate `lane-actions.py`, so the size is unchanged and only a SET comparison can see it.
POP_SWAP="$(printf '%s\n' $LANE_PRODUCERS_CANONICAL | grep -vx 'script:objective.py' | tr '\n' ' ')"
POP_SWAP="$POP_SWAP script:lane-actions.py"
if [ "$(producer_probe check_producer_population "pin-probe-swap" "$POP_SWAP")" -gt 0 ]; then
  echo "ok: a COUNT-PRESERVING substitution trips the population pin (set binding, not a count floor)"
else
  fail "a COUNT-PRESERVING substitution did NOT trip the population pin — objective.py read as guarded while absent"
fi
# GROWTH — #1899 ITSELF. A producer a farmed consumer has started to exec is an ADDITION to the
# population, and an addition must be dispositioned rather than absorbed: pre-#1899 the gate could not
# see `lane-triage.py` at all and printed `ok: all 7 ...` over it.
POP_ADDED="$(printf '%s\n' $LANE_PRODUCERS_CANONICAL | tr '\n' ' ') script:newly-exec.py"
if [ "$(producer_probe check_producer_population "pin-probe-added" "$POP_ADDED")" -gt 0 ]; then
  echo "ok: a NEWLY EXEC'D producer trips the population pin (never a quieter green — #1899)"
else
  fail "a NEWLY EXEC'D producer did NOT trip the population pin — the derivation can grow silently (#1899)"
fi
# DISPOSITION — the two directions of the `state/` class. A NAMED residual is a disclosed gap (not a
# failure: #1553 owns `lane-triage.py`); an UNNAMED one is a producer no array delivers and no issue
# owns, which must fail rather than join a growing list of silent gaps. The probe population is the
# PINNED set — tree-independent, and complete, so the stale-disclosure rule (which spans BOTH
# disclosure lists) is satisfied inside the probe instead of firing on a deliberately partial one.
POP_PROBE="$(printf '%s\n' $LANE_PRODUCERS_CANONICAL | tr '\n' ' ')"
if [ "$(producer_probe check_producer_farm_declared "dispo-probe-owned-state" "$POP_PROBE")" -gt 0 ]; then
  fail "a NAMED state residual FAILED the disposition check — an owned disclosure must not read as a defect (#1899)"
else
  echo "ok: a NAMED state residual is a disclosed gap, not a failure (no false block)"
fi
if [ "$(producer_probe check_producer_farm_declared "dispo-probe-unowned-state" "$POP_PROBE state:unowned-producer.py")" -gt 0 ]; then
  echo "ok: an UNOWNED state producer trips the disposition check (a new state/ exec site cannot enter silently)"
else
  fail "an UNOWNED state producer did NOT trip the disposition check — a producer no farm delivers read as clean (#1899)"
fi
# THE GATE'S CENTRAL PROPERTY, pinned as a probe: a derived `script:`/`lib:` producer that is in NO
# farm array and in NO disclosure list must FAIL. Without this probe the whole disposition half could
# be reduced to `missing="$missing"` and every other probe would still pass — a green gate with the
# #1899 hole re-opened one line down. (Not hypothetical: reviewer B proved it by mutation on the
# pre-fix tree.)
if [ "$(producer_probe check_producer_farm_declared "dispo-probe-undelivered-script" "$POP_PROBE script:newly-exec.py")" -gt 0 ]; then
  echo "ok: an UNDELIVERED, UNEXEMPTED script producer trips the disposition check (#1899)"
else
  fail "an UNDELIVERED script producer did NOT trip the disposition check — the gate's central property is unproven"
fi
if [ "$(producer_probe check_producer_farm_declared "dispo-probe-undelivered-lib" "$POP_PROBE lib:newly-exec.sh")" -gt 0 ]; then
  echo "ok: an UNDELIVERED, UNEXEMPTED lib producer trips the disposition check (#1899)"
else
  fail "an UNDELIVERED lib producer did NOT trip the disposition check"
fi
# ...and the FOREIGN class the same way: a cross-checkout producer must be disclosed, never absorbed.
if [ "$(producer_probe check_producer_farm_declared "dispo-probe-unowned-foreign" "$POP_PROBE foreign:elsewhere.sh")" -gt 0 ]; then
  echo "ok: an UNDISCLOSED foreign producer trips the disposition check (#1899)"
else
  fail "an UNDISCLOSED foreign producer did NOT trip the disposition check"
fi
# SUBDIRECTORY DEST — both directions. `$SCRIPTS/fleet/<n>` IS delivered (by `fleet_tools`, from
# `tools/fleet/`), so it must not be reported as undelivered; anything else in a subdir has no array and
# must be disclosed. Without the first direction the check would false-block a legitimately farmed file
# and the natural fix would be to widen the exemption list — i.e. to make it weaker.
if [ "$(producer_probe check_producer_farm_declared "dispo-probe-other-delivered" "$POP_PROBE other:fleet/liveness.py")" -gt 0 ]; then
  fail "a subdir dest DELIVERED by fleet_tools FAILED the disposition check — a legitimately farmed file must not read as a gap (#1899)"
else
  echo "ok: a subdir dest carried by fleet_tools is DELIVERED, not a gap (no false block)"
fi
# `fleet/<n>` arrives as EITHER `other:fleet/<n>` or `script:fleet/<n>` depending on the spelling, and
# `setup.sh` mkdirs `$DEST/scripts/fleet/` for the same array — so both must be delivered, or the day
# someone writes the other spelling the gate false-blocks and the fix looks like widening the exemptions.
if [ "$(producer_probe check_producer_farm_declared "dispo-probe-script-fleet" "$POP_PROBE script:fleet/liveness.py")" -gt 0 ]; then
  fail "a fleet/ producer spelled \`script:fleet/<n>\` FAILED the disposition check — the same destination as \`other:fleet/<n>\` must be delivered by fleet_tools (#1899)"
else
  echo "ok: a fleet/ producer is DELIVERED under either spelling (other:fleet/ and script:fleet/)"
fi
# WHOLE-WORD MEMBERSHIP. `farm_declares` matches with `grep -Fxq`, and EVERY delivery decision in this
# check rides on it: weaken it to a substring match and an array entry that was merely RENAMED
# (`lane-actions.py` -> `lane-actions.py.old`) reads as delivering `lane-actions.py`, i.e. the gate
# reports a producer delivered on the strength of a different filename — the #1899 direction exactly.
PROBE_WHOLEWORD="$TMP/producer-wholeword"
mkdir -p "$PROBE_WHOLEWORD/pi-bootstrap"
printf 'fleet_srcs=(lane-actions.py.old)\nlib_srcs=()\nmerge_gate_srcs=()\nlane_root_srcs=()\n' \
  > "$PROBE_WHOLEWORD/pi-bootstrap/setup.sh"
WHOLEWORD_MSG="$(producer_probe_msg check_producer_farm_declared "dispo-probe-wholeword" "script:lane-actions.py" "$PROBE_WHOLEWORD")"
case "$WHOLEWORD_MSG" in
  *"DELIVERED BY NOTHING"*"lane-actions.py"*)
    echo "ok: array membership is WHOLE-WORD — a renamed entry does not count as delivering the original" ;;
  *) fail "a renamed array entry (lane-actions.py.old) counted as delivering lane-actions.py — \`farm_declares\` is matching a SUBSTRING, so a producer can read as delivered while nothing farms it (#1899)" ;;
esac
# ⛔ THE PROBE MUST BE ABLE TO FAIL (review of the head, MEASURED). It used to ask about
# `state:refresh-queues.py`, the flat spelling of the residual `queues/refresh-queues.py` — but that
# entry LEFT `LANE_PRODUCERS_STATE_RESIDUAL` when #1874 retired its only consumer, so from that
# landing on the probe asked about a name NO disclosure covers and passed for the trivial reason
# ("nothing is disclosed"). Measured with a substring-broken `_owner_of`: GREEN before the deletion,
# GREEN after it. The probe now uses a name that PREFIXES a surviving entry —
# `state:lane-confirm` vs the disclosure `state:lane-confirm.py:#1797` — so an exact matcher still
# refuses it (no `lane-confirm:` item exists) and a substring matcher adopts it and REDs. That is
# the property the probe exists to hold, and it is graded by a fixture that can go red.
OWNER_SUB_MSG="$(producer_probe_msg check_producer_farm_declared "dispo-probe-owner-exact" "state:lane-confirm")"
case "$OWNER_SUB_MSG" in
  *"DELIVERED BY NOTHING"*"state/lane-confirm"*)
    echo "ok: a disclosure entry is matched by its WHOLE name — a truncated path does not adopt a producer" ;;
  *) fail "a producer was adopted by a disclosure entry for a DIFFERENT name ($(printf '%s' "$OWNER_SUB_MSG" | head -c 300)) — \`_owner_of\` is matching a substring (#1899)" ;;
esac
if [ "$(producer_probe check_producer_farm_declared "dispo-probe-other-undelivered" "$POP_PROBE other:subnew/x.py")" -gt 0 ]; then
  echo "ok: an UNDELIVERED subdir producer trips the disposition check (#1899)"
else
  fail "an UNDELIVERED subdir producer did NOT trip the disposition check"
fi
# ...and the GLOB-farmed directory is delivered without any array entry, so a member must not be
# reported as a gap. `setup.sh` copies `scripts/checkout-hygiene/*` in a loop; the check asks the
# SOURCE dir, which is what that loop iterates.
if [ "$(producer_probe check_producer_farm_declared "dispo-probe-glob-delivered" "$POP_PROBE other:checkout-hygiene/corruption_canary.py")" -gt 0 ]; then
  fail "a member of the GLOB-farmed dir FAILED the disposition check — a delivered file must not read as a gap (#1899)"
else
  echo "ok: a member of the directory-GLOB farm (scripts/checkout-hygiene/) is DELIVERED, not a gap"
fi
# ...but the loop's own SKIP rules (`*.plist|*.test.*) continue`) mean a member it does NOT copy is not
# delivered. Counting it as delivered is the gate's central false negative: the producer is absent from a
# fresh farm and nothing says so.
GLOB_SKIP_MSG="$(producer_probe_msg check_producer_farm_declared "dispo-probe-glob-skipped" \
  "$POP_PROBE other:checkout-hygiene/deepseek-balance-watch.test.sh")"
case "$GLOB_SKIP_MSG" in
  *"DELIVERED BY NOTHING"*)
    echo "ok: a member the glob loop SKIPS (*.test.*) is NOT counted as delivered" ;;
  *) fail "a file the glob loop SKIPS was counted as delivered — the delivery branch ignores setup.sh's own skip rules (#1899)" ;;
esac
# ...and the FOREIGN list's own remedy must work: a cross-checkout producer disclosed there is a
# DECLARED-FOREIGN line, not a FAIL. (The remedy string used to name only two of the three lists, so
# following it for a `foreign:` producer produced a STALE + DELIVERED-BY-NOTHING pair.)
_FOREIGN_SAVED_LIST="$LANE_PRODUCERS_FOREIGN_RESIDUAL"
LANE_PRODUCERS_FOREIGN_RESIDUAL="$_FOREIGN_SAVED_LIST elsewhere.sh:#1234"
FOREIGN_REMEDY_MSG="$(producer_probe_msg check_producer_farm_declared "dispo-probe-foreign-disclosed" "$POP_PROBE foreign:elsewhere.sh")"
LANE_PRODUCERS_FOREIGN_RESIDUAL="$_FOREIGN_SAVED_LIST"
case "$FOREIGN_REMEDY_MSG" in
  *FAIL*) fail "a foreign producer DISCLOSED in LANE_PRODUCERS_FOREIGN_RESIDUAL was reported as a defect — the remedy its own FAIL prints does not work for foreign: ($(printf '%s' "$FOREIGN_REMEDY_MSG" | head -c 300))" ;;
  *"DECLARED-FOREIGN"*) echo "ok: a foreign producer disclosed in LANE_PRODUCERS_FOREIGN_RESIDUAL is a declared residual, not a failure (the remedy works)" ;;
  *) fail "a disclosed foreign producer produced neither a failure nor a DECLARED-FOREIGN line" ;;
esac
# EXEMPT must be USABLE for the kinds that are routed to it. `lib:` and `other:` producers fall through
# to it (only `state:`/`foreign:` have their own lists), so an exempted one must be a disclosed gap and
# produce NO failure — otherwise the FAIL's own remedy ("add it to LANE_PRODUCERS_EXEMPT") does not
# work for two of the five kinds, and the only guidance printed is the one action that breaks the run.
_EXEMPT_SAVED="$LANE_PRODUCERS_EXEMPT"
LANE_PRODUCERS_EXEMPT="$_EXEMPT_SAVED newlib.sh:#1234"
LIB_EXEMPT_MSG="$(producer_probe_msg check_producer_farm_declared "dispo-probe-lib-exempt" "$POP_PROBE lib:newlib.sh")"
LANE_PRODUCERS_EXEMPT="$_EXEMPT_SAVED subdir/x.py:#1234"
OTHER_EXEMPT_MSG="$(producer_probe_msg check_producer_farm_declared "dispo-probe-other-exempt" "$POP_PROBE other:subdir/x.py")"
LANE_PRODUCERS_EXEMPT="$_EXEMPT_SAVED"
case "$LIB_EXEMPT_MSG" in
  *FAIL*) fail "an EXEMPTED lib producer was still reported as a defect — the FAIL remedy does not work for lib: ($(printf '%s' "$LIB_EXEMPT_MSG" | head -c 300))" ;;
  *) echo "ok: an EXEMPTED lib producer is a disclosed gap, not a failure (the remedy works)" ;;
esac
case "$OTHER_EXEMPT_MSG" in
  *FAIL*) fail "an EXEMPTED subdir producer was still reported as a defect — the FAIL remedy does not work for other: ($(printf '%s' "$OTHER_EXEMPT_MSG" | head -c 300))" ;;
  *) echo "ok: an EXEMPTED subdir producer is a disclosed gap, not a failure (the remedy works)" ;;
esac
# STALE-AFTER-DELIVERY — the direction the whole stale rule exists for, and the one a "is it still in
# the population" test CANNOT see: once #1553 lands, `lane-status.py` is delivered, so its exemption is
# inert — and an inert exemption would absorb a LATER regression (the file dropped back out of
# `lane_root_srcs`) as a harmless DECLARED-GAP line instead of a FAIL. Synthesised here with a tree
# whose `lane_root_srcs` carries it, so the probe does not depend on #1553 having landed.
PROBE_DELIVERED="$TMP/producer-delivered"
mkdir -p "$PROBE_DELIVERED/pi-bootstrap"
printf 'fleet_srcs=(%s)\nlib_srcs=(%s)\nmerge_gate_srcs=(record-review.sh)\nlane_root_srcs=(lane-status.py)\n' \
  "$(farm_array_entries fleet_srcs | tr '\n' ' ')" "$(farm_array_entries lib_srcs | tr '\n' ' ')" \
  > "$PROBE_DELIVERED/pi-bootstrap/setup.sh"
DELIVERED_MSG="$(producer_probe_msg check_producer_farm_declared "dispo-probe-stale-delivered" "$POP_PROBE" "$PROBE_DELIVERED")"
case "$DELIVERED_MSG" in
  *"STALE disclosure"*"lane-status.py"*)
    case "$DELIVERED_MSG" in
      *"DELIVERED BY NOTHING:  lane-status.py"*|*"DELIVERED BY NOTHING: lane-status.py"*)
        fail "the stale-after-delivery probe also reported lane-status.py as undelivered — it is not testing what it claims" ;;
      *) echo "ok: a disclosure whose producer is now DELIVERED is STALE (an exemption cannot outlive its reason)" ;;
    esac ;;
  *) fail "a delivery that makes an exemption inert did NOT trip the stale check — the exemption would silently absorb a later regression (#1899)" ;;
esac
# EMPTY POPULATION at THIS check (the pin has its own empty probe; this one proves the disposition half
# cannot read 0/0 as clean if it is ever called with a population the derivation failed to build).
# Asserted on the MESSAGE: with an empty population the STALE channel also fires (nothing was applied),
# so a count-only assertion is satisfied with the empty-population branch deleted — the same defect cycle
# 3 fixed for the pin. Asserted a second time with every disclosure list EMPTIED, which is the state the
# #1553 cleanup produces: there the stale channel is silent, and the empty-population branch is the ONLY
# thing standing between 0/0 and a clean read.
case "$(producer_probe_msg check_producer_farm_declared "dispo-probe-empty" "")" in
  *"population handed to this check is EMPTY"*)
    echo "ok: an EMPTY population handed to the disposition check trips it (0/0 never reads as clean)" ;;
  *) fail "an EMPTY population passed the disposition check — 0/0 read as clean (#1899)" ;;
esac
_EXEMPT_SAVED2="$LANE_PRODUCERS_EXEMPT"; _STATE_SAVED="$LANE_PRODUCERS_STATE_RESIDUAL"
_FOREIGN_SAVED="$LANE_PRODUCERS_FOREIGN_RESIDUAL"
LANE_PRODUCERS_EXEMPT=""; LANE_PRODUCERS_STATE_RESIDUAL=""; LANE_PRODUCERS_FOREIGN_RESIDUAL=""
case "$(producer_probe_msg check_producer_farm_declared "dispo-probe-empty-bare" "")" in
  *"population handed to this check is EMPTY"*)
    echo "ok: an EMPTY population trips the disposition check with ALL disclosure lists empty (the stale channel cannot mask it)" ;;
  *) fail "0/0 read as clean once the disclosure lists were emptied — the empty-population branch is the only guard and it did not fire (#1899)" ;;
esac
LANE_PRODUCERS_EXEMPT="$_EXEMPT_SAVED2"; LANE_PRODUCERS_STATE_RESIDUAL="$_STATE_SAVED"
LANE_PRODUCERS_FOREIGN_RESIDUAL="$_FOREIGN_SAVED"
# THE REPORT LINES ARE PART OF THE GATE. A SUMMARY that adds up differently, an `ok:` printed beside a
# FAIL, or inverted ADDED/REMOVED labels are all ways the instrument lies while still exiting correctly —
# none of the probes above looks at them.
# The disclosed member of this probe population is `state:lane-confirm.py` (#1797): it has to be a name
# its disclosure list ACTUALLY carries, and it stopped being `state:claim.py` when #1874 retired that
# file's only consumer and the entry left `LANE_PRODUCERS_STATE_RESIDUAL` with it.
DUP_MSG="$(producer_probe_msg check_producer_farm_declared "dispo-probe-report" \
  "state:lane-confirm.py script:heartbeat-loop.sh script:undelivered-demo.py")"
case "$DUP_MSG" in
  *"SUMMARY: dispo-probe-report 3 derived producer(s) = 0 delivered + 2 disclosed with an owning issue + 1 undelivered-and-undisclosed"*)
    echo "ok: the SUMMARY tallies delivered + disclosed + undelivered against the population (3 = 0 + 2 + 1)" ;;
  *) fail "the SUMMARY arithmetic is wrong — it must satisfy n == delivered + disclosed + undelivered: $(printf '%s' "$DUP_MSG" | grep 'SUMMARY:' | head -c 200)" ;;
esac
case "$DUP_MSG" in
  *"ok: dispo-probe-report"*)
    fail "an affirmative \`ok:\` was printed on a run with a FAIL — that is the false-clean read this whole check exists to close (#1552/#1899)" ;;
  *) echo "ok: no \`ok:\` line is printed while a producer is undelivered" ;;
esac
# ADDED vs REMOVED are swapped by `comm -13`/`comm -23`; a population with one of each must name them on the
# right sides, or a reader is sent to the wrong file.
POP_MOVED="$(printf '%s\n' $LANE_PRODUCERS_CANONICAL | grep -vx 'script:objective.py' | tr '\n' ' ') script:moved-in.py"
MOVED_MSG="$(producer_probe_msg check_producer_population "pin-probe-moved" "$POP_MOVED")"
case "$MOVED_MSG" in
  *"ADDED: script:moved-in.py"*"REMOVED: script:objective.py"*)
    echo "ok: an ADDED producer and a REMOVED one are named on the right sides of the pin's report" ;;
  *) fail "the pin's ADDED/REMOVED labels are wrong or missing: $(printf '%s' "$MOVED_MSG" | head -c 300)" ;;
esac
# STALE DISCLOSURE — the reverse direction: a name that is exempted or residual but that the derivation
# no longer finds is describing a world that no longer exists, and must be deleted rather than trusted.
POP_STALE="$(printf '%s\n' $LANE_PRODUCERS_CANONICAL | grep -vx 'script:lane-status.py' | tr '\n' ' ')"
# ...and the STALE column of the SUMMARY (a hardcoded 0 there would misreport one column while the rest
# stays right — the same class of lie the report probes exist to close).
STALE_COL_MSG="$(producer_probe_msg check_producer_farm_declared "dispo-probe-stale-column" "$POP_STALE")"
case "$STALE_COL_MSG" in
  *"+ 1 stale disclosure(s)"*)
    echo "ok: the SUMMARY reports the stale-disclosure count (1 stale, not a hardcoded 0)" ;;
  *) fail "the SUMMARY does not report its stale-disclosure count: $(printf '%s' "$STALE_COL_MSG" | grep 'SUMMARY:' | head -c 200)" ;;
esac
if [ "$(producer_probe check_producer_farm_declared "dispo-probe-stale-exempt" "$POP_STALE")" -gt 0 ]; then
  echo "ok: a STALE exemption trips the disposition check (an exemption cannot outlive its reason)"
else
  fail "a STALE exemption did NOT trip the disposition check — a disclosure whose producer is gone read as clean"
fi
# ...and staleness is KIND-QUALIFIED: `lane-triage.py` as a `script:` producer does NOT keep its
# `state:` residual alive. This is the shape of a #1553 landing that farms the file — without the kind
# in the match, the residual would survive on the strength of a same-named producer in another dir.
POP_STALE_KIND="$(printf '%s\n' $LANE_PRODUCERS_CANONICAL | grep -vx 'state:lane-triage.py' | tr '\n' ' ') script:lane-triage.py"
# ⛔ The probe MUST put a same-named producer into the APPLIED set, or it proves nothing: with
# `script:lane-triage.py` merely present-but-undelivered, `applied` stays empty for it and the stale
# channel fires under a kind-blind matcher too. Exempting it for the duration is what makes the two
# implementations differ — shipped code names `state:lane-triage.py`, a kind-blind one stays silent.
_STALE_KIND_EXEMPT="$LANE_PRODUCERS_EXEMPT"
LANE_PRODUCERS_EXEMPT="$_STALE_KIND_EXEMPT lane-triage.py:#9999"
# Asserted on the MESSAGE, not on the count: `script:lane-triage.py` is (correctly) also reported as
# undelivered here, so a count-only assertion is satisfied by that failure and a KIND-BLIND mutation
# would survive it. This probe is about the STALE channel specifically.
STALE_KIND_MSG="$(producer_probe_msg check_producer_farm_declared "dispo-probe-stale-kind" "$POP_STALE_KIND")"
LANE_PRODUCERS_EXEMPT="$_STALE_KIND_EXEMPT"
# ...and the SAME property for the EXEMPT channel: an exemption whose producer has MOVED to a `state:` slot
# must go stale. Without this probe the EXEMPT matcher can be made kind-blind (`*":${name} "*`) and every
# other probe still passes, because the population above never has the exempted name in a disclosed slot.
POP_STALE_EXEMPT_KIND="$(printf '%s\n' $LANE_PRODUCERS_CANONICAL | grep -vx 'script:lane-status.py' | tr '\n' ' ') state:lane-status.py"
_STATE_RESIDUAL_SAVED="$LANE_PRODUCERS_STATE_RESIDUAL"
LANE_PRODUCERS_STATE_RESIDUAL="$_STATE_RESIDUAL_SAVED lane-status.py:#9999"
STALE_EXEMPT_KIND_MSG="$(producer_probe_msg check_producer_farm_declared "dispo-probe-stale-exempt-kind" "$POP_STALE_EXEMPT_KIND")"
LANE_PRODUCERS_STATE_RESIDUAL="$_STATE_RESIDUAL_SAVED"
case "$STALE_EXEMPT_KIND_MSG" in
  *"STALE disclosure"*"lane-status.py"*)
    echo "ok: an EXEMPTION whose producer moved is STALE under the KIND it moved to (exempt matcher is kind-qualified)" ;;
  *) fail "an exemption survived its producer moving to another kind — the EXEMPT staleness matcher is KIND-BLIND (#1899)" ;;
esac
case "$STALE_KIND_MSG" in
  *"STALE disclosure"*"state:lane-triage.py"*)
    echo "ok: a disclosure is matched by KIND — a same-named producer elsewhere does not keep it alive" ;;
  *)
    fail "a state disclosure survived on the strength of a same-named script producer — the stale check is KIND-BLIND (#1899); probe said: $(printf '%s' "$STALE_KIND_MSG" | head -c 400)" ;;
esac

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
check_producer_farm_declared "run1" "$LANE_PRODUCERS_DERIVED"
# ⛔ THE THREE INVOCATIONS ABOVE ARE THE GATE. Every probe in this block calls these functions directly
# (inside `producer_probe*`, i.e. a command substitution, which cannot set a variable in this shell), so
# the probes prove the FUNCTIONS but never that the suite still CALLS them: before this assertion, all
# three lines could be deleted and the run still printed 196 `ok:` with 0 FAIL while the whole
# disposition gate — the thing #1899 exists for — silently stopped running. The sentinels below can
# only be set by a real invocation, and `SUMMARY`/`DECLARED-*` lines vanishing in a `tee`d transcript is
# not a signal anything reads.
[ "${_FLOOR_RAN:-0}" = 1 ] \
  || fail "run1: the root-set floor NEVER RAN on the real tree — its invocation is missing or was skipped, so an unread farm array would go unnoticed (#1899)"
[ "${_PIN_RAN:-0}" = 1 ] \
  || fail "run1: the population pin NEVER RAN on the real tree — its invocation is missing or was skipped, so a silently SHRUNK population would read as clean (#1899)"
[ "${_DISPO_RAN:-0}" = 1 ] \
  || fail "run1: the DISPOSITION gate NEVER RAN on the real tree — its invocation is missing or was skipped, which is the #1899 defect itself (a green run over an unjudged population)"
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
lib_decl="$(farm_array_entries lib_srcs | tr '\n' ' ')"
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

# --- the pi spawn-point gate (#1884) --------------------------------------
# setup.sh installs spawn-gate.sh AS `pi` in $DEST/bin — first on this fleet's PATH — because the
# gate must sit where `pi` is born, not where a caller remembers to source it. Pinned BY ARTIFACT and
# BY BEHAVIOUR (a byte comparison alone would pass on a copy that cannot run): the INSTALLED file is
# driven as `pi`, with MAX_LOAD=0 as the deterministic refusal lever and a fake real pi behind it.
# The defect this exists for: a hand-written runner that sourced nothing started lanes on a box at
# load 258 against its own ceiling of 100, with no refusal, no log line and no count.
echo "== the pi spawn-point gate (#1884)"
GATE_SRC="$ROOT/scripts/orchestrator-harness/spawn-gate.sh"
GATE_DST="$DEST/bin/pi"
if [ -f "$GATE_DST" ] && cmp -s "$GATE_SRC" "$GATE_DST"; then
  echo "ok: setup.sh installed the spawn-point gate byte-identical at \$DEST/bin/pi"
else
  fail "setup.sh did not install the spawn-point gate at $GATE_DST (missing or stale) — every \`pi\` a hand-written runner starts would be ungated and silent"
fi
if [ -x "$GATE_DST" ]; then
  echo "ok: the installed gate is executable (PATH skips a non-executable entry, silently)"
else
  fail "$GATE_DST is not executable — PATH would resolve past the gate"
fi
mkdir -p "$TMP/gate-real"
printf '#!/usr/bin/env bash\nprintf RAN > "%s"\n' "$TMP/gate-ran" > "$TMP/gate-real/pi"
chmod +x "$TMP/gate-real/pi"
rm -f "$TMP/gate-ran"
HOME="$HOME_DIR" MAX_LOAD=0 PATH="$DEST/bin:$TMP/gate-real:$PATH" pi -p "gate probe" >/dev/null 2>&1 || true
if [ ! -e "$TMP/gate-ran" ]; then
  echo "ok: the installed gate REFUSED a spawn at MAX_LOAD=0 (the real pi never ran)"
else
  fail "the installed gate allowed a spawn at MAX_LOAD=0 — 'spawn nothing' is not enforced"
fi
HOME="$HOME_DIR" MAX_LOAD=999999999 PATH="$DEST/bin:$TMP/gate-real:$PATH" pi -p "gate probe" >/dev/null 2>&1 || true
if [ -e "$TMP/gate-ran" ]; then
  echo "ok: POSITIVE CONTROL — below the ceiling the installed gate EXECs the real pi"
else
  fail "the installed gate blocked a spawn below the ceiling: every refusal above would be vacuous"
fi
# A re-run must REFRESH a mutated copy: a stale gate is worse than a missing one (the missing one is
# loud; the stale one certifies a ceiling it no longer applies).
rm -f "$TMP/gate-ran"
echo "# drift injected by the test" >> "$GATE_DST"
run_setup
if cmp -s "$GATE_SRC" "$GATE_DST"; then
  echo "ok: a mutated spawn-point gate was REFRESHED by the re-run (the repo copy is the copy that runs)"
else
  fail "a cell-local mutation of the spawn-point gate survived the re-run"
fi

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
