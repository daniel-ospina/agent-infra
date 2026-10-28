#!/usr/bin/env bash
# provision-lane-registry.test.sh — the LANE ROSTER is derived from the box's own population,
# and every arm that cannot MEASURE it refuses instead of writing an empty one.
#
# THE DEFECT THIS PINS (agent-infra#1935). The dispatch pre-flight's holder surface is built FROM
# `$HOME/.pi/agent/state/lane-registry.tsv`, a file only the RETIRED cmux dispatcher wrote. A cell
# that never ran it has no roster, so the board answers `measured=False`, `_board_can_answer`
# refuses, and EVERY candidate is INCOMPLETE:
#     issue assignee/holder  INCOMPLETE  … the roster was NEVER PROVISIONED in this cell
#     [refresh] ABORT: none of the 12 candidate(s) … judged NOTHING
# — a cell that reports RUNNING and dispatches nothing, forever.
#
# WHAT IS UNDER TEST, and the polarity each arm guards:
#   A  DERIVE          the cmux daemon answers ⇒ one row per DEMONSTRABLE fleet worktree. The
#                      owner's own project and the shared checkout get NO row (a row is an
#                      attribution — a manufactured holder is a blocking false COLLISION, #8177),
#                      and they are NAMED as excluded so the roster cannot quietly shrink.
#   B  REFUSED-READ    the daemon answers but the list does not parse ⇒ rc 3 and NOTHING written.
#                      An unreadable read must never become an empty roster: that is the exact
#                      false-CLEAN #8175 exists to prevent.
#   C  REFUSED-LAYOUT  the daemon does not answer but the box HAS a persisted cmux workspace
#                      layout ⇒ rc 3 and nothing written. The box has cmux lanes we could not
#                      enumerate, which is not the same fact as having none.
#   D  NOT-APPLICABLE  the daemon does not answer and no layout was ever persisted (a Linux cell,
#                      measured on cell 1: `cmux-tui daemon binary not found`) ⇒ the truthful
#                      roster is ZERO rows, and it is WRITTEN — because an ABSENT file is what the
#                      board refuses. Idempotent: a second run changes nothing.
#   E  HAND-MAINTAINED a roster without this script's marker is NEVER replaced, even by --apply.
#                      The Mac's 96-row curated roster is better than anything derivable, and a
#                      bring-up step must not overwrite the fleet's attribution to satisfy a form.
#   F  NO SURFACE      no cmux, no tmux, no layout ⇒ rc 3. A box with nothing to run a lane in has
#                      no population to provision from; inventing one would be the fail-open.
#
# Hermetic: a stub `cmux` on PATH, a throwaway HOME, a fixture worktree layout. No network, no git,
# no real cmux, no real tmux.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/orchestrator-harness/provision-lane-registry.py"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL %s\n' "$*"; }
chk() { if eval "$2"; then ok "$1"; else bad "$1 [$2]"; fi; }

T="$(mktemp -d "${TMPDIR:-/tmp}/prov-reg.XXXXXX")"
trap 'rm -rf "$T"' EXIT

[ -f "$SCRIPT" ] || { echo "FAIL the shipped provisioner is missing: $SCRIPT"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP python3 unavailable"; exit 0; }

# ── fixtures ─────────────────────────────────────────────────────────────────────────────────
# A case directory: its own HOME, its own stub PATH, its own roster.
CASE=""
mk_case() {
  CASE="$T/$1"
  rm -rf "$CASE"
  mkdir -p "$CASE/home/.pi/agent/state" "$CASE/bin" "$CASE/repo/.worktrees/lane-77"
  # a REAL linked worktree: the `.git` FILE `git worktree add` writes, pointing into
  # <main>/.git/worktrees/<name> (the reader's own identity test).
  printf 'gitdir: %s\n' "$CASE/repo/.git/worktrees/lane-77" > "$CASE/repo/.worktrees/lane-77/.git"
  mkdir -p "$CASE/repo/.git/worktrees/lane-77"
  # the box's other shapes
  mkdir -p "$CASE/fleet/wt-lane-88"        # a cell's own lane root
  mkdir -p "$CASE/owner/Personal website"  # the OWNER's project — must never be rostered
  mkdir -p "$CASE/repo/.git"               # a main checkout — not a lane either
  ROSTER="$CASE/home/.pi/agent/state/lane-registry.tsv"
}
mk_stub() { # mk_stub <cmux-tree-rc> <list-mode>   list-mode: payload | junk
  cat > "$CASE/bin/cmux" <<SH
#!/bin/sh
case "\$*" in
  "tree --json") exit $1 ;;
  "list-workspaces --json") cat "$CASE/list.json"; exit 0 ;;
esac
exit 1
SH
  chmod +x "$CASE/bin/cmux"
}
mk_payload() { # workspaces from the fixture dirs
  cat > "$CASE/list.json" <<JSON
{"window_ref":"window:1","workspaces":[
 {"id":"c2c97e96-0cbc-4dfe-bc91-fef44f09b5bd","custom_title":"LANE 77","current_directory":"$CASE/repo/.worktrees/lane-77"},
 {"id":"aa11bb22-cc33-dd44-ee55-ff6677889900","custom_title":"LANE 88","current_directory":"$CASE/fleet/wt-lane-88"},
 {"id":"deadbeef-0000-0000-0000-000000000000","custom_title":"Personal website","current_directory":"$CASE/owner/Personal website"},
 {"id":"11112222-3333-4444-5555-666677778888","custom_title":"SHARED","current_directory":"$CASE/repo"},
 {"id":"99990000-1111-2222-3333-444455556666","custom_title":"NO CWD"}
]}
JSON
}
run_it() { # run_it <args...>  — stub PATH + fixture HOME, capture output and rc
  OUT="$(env -u TMUX HOME="$CASE/home" PATH="$CASE/bin:$(dirname "$(command -v python3)"):/usr/bin:/bin" \
        python3 "$SCRIPT" "${@:-}" --roster "$ROSTER" 2>&1)"
  RC=$?
}
no_cmux_no_tmux_path() { # PATH with python3 only — no cmux, no tmux
  mkdir -p "$CASE/onlypy"
  ln -sf "$(command -v python3)" "$CASE/onlypy/python3" 2>/dev/null || cp "$(command -v python3)" "$CASE/onlypy/python3"
}
tmux_path() { # a PATH with a tmux stub but no cmux answer
  printf '#!/bin/sh\nexit 0\n' > "$CASE/bin/tmux"; chmod +x "$CASE/bin/tmux"
}

echo "== A. DERIVE: one row per demonstrable fleet worktree, exclusions NAMED =="
mk_case derive; mk_stub 0 payload; mk_payload
run_it            # report-only by default
chk "A1 --check on an ABSENT roster is ACTION NEEDED (rc 2)" '[ "$RC" -eq 2 ]'
chk "A2 …and it writes NOTHING" '[ ! -e "$ROSTER" ]'
run_it --apply
chk "A3 --apply provisions the roster (rc 0)" '[ "$RC" -eq 0 ]'
chk "A4 the roster EXISTS" '[ -f "$ROSTER" ]'
chk "A5 two fleet lanes are rostered" '[ "$(grep -vc "^#" "$ROSTER")" -eq 2 ]'
chk "A6 the linked worktree row carries label/uuid/lane:77" \
    'grep -q "lane-77	C2C97E96-0CBC-4DFE-BC91-FEF44F09B5BD	lane:77" "$ROSTER"'
chk "A7 the wt- lane row is rostered with the wt- prefix removed" \
    'grep -q "lane-88	AA11BB22-CC33-DD44-EE55-FF6677889900	lane:88" "$ROSTER"'
chk "A8 the OWNER's project is NOT rostered (#8177 attribution)" \
    '! grep -qi "deadbeef" "$ROSTER"'
chk "A9 the shared checkout is NOT rostered" '! grep -q "11112222" "$ROSTER"'
chk "A10 a workspace with no cwd is NOT rostered" '! grep -q "99990000" "$ROSTER"'
chk "A11 each exclusion is NAMED on the report (a vanished window is visible)" \
    'case "$OUT" in *"Personal website"*"not a fleet worktree"*) true;; *) false;; esac'
chk "A12 the file carries the derivation MARKER (so a refresh may replace it)" \
    'grep -qx "# provisioned-by: provision-lane-registry.py" "$ROSTER"'
chk "A13 every row is 3 TAB-separated columns in the reader's grammar" \
    '[ "$(grep -v "^#" "$ROSTER" | awk -F"\t" "NF!=3" | wc -l | tr -d " ")" -eq 0 ]'
cp "$ROSTER" "$T/derive.first"
run_it --apply
chk "A14 a second --apply is CURRENT (rc 0) and changes nothing" \
    '[ "$RC" -eq 0 ] && cmp -s "$ROSTER" "$T/derive.first" && case "$OUT" in *CURRENT*) true;; *) false;; esac'

echo
echo "== B. REFUSED: the daemon answers, the LIST does not parse — nothing is written =="
mk_case junks; mk_stub 0 junk; printf 'cmux: unexpected output\n' > "$CASE/list.json"
run_it --apply
chk "B1 rc 3 (REFUSED), never 0" '[ "$RC" -eq 3 ]'
chk "B2 the refusal NAMES the failed READ" 'case "$OUT" in *"could not be READ"*) true;; *) false;; esac'
chk "B3 NO roster was written — an unreadable read is not an empty fleet" '[ ! -e "$ROSTER" ]'
# …and the same on a box that already HAS a hand-maintained roster: it must be untouched.
mk_case junkh; mk_stub 0 junk; printf 'cmux: nope\n' > "$CASE/list.json"
printf '# hand roster\nSome lane\tAAAAAAAA-0000-0000-0000-000000000000\tlane:1\n' > "$ROSTER"
cp "$ROSTER" "$T/junkh.first"
run_it --apply
chk "B4 a refused read leaves an existing roster byte-identical" \
    '[ "$RC" -eq 3 ] && cmp -s "$ROSTER" "$T/junkh.first"'

echo
echo "== C. REFUSED: no daemon answer but a PERSISTED cmux layout — has lanes we cannot read =="
mk_case layout; mk_stub 1 junk          # `cmux tree --json` fails ⇒ no daemon answer
mkdir -p "$CASE/home/Library/Application Support/cmux"
: > "$CASE/home/Library/Application Support/cmux/session-com.cmuxterm.app.json"
tmux_path
run_it --apply
chk "C1 rc 3 (REFUSED)" '[ "$RC" -eq 3 ]'
chk "C2 the refusal names the persisted layout" 'case "$OUT" in *"persisted workspace layout"*) true;; *) false;; esac'
chk "C3 nothing was written" '[ ! -e "$ROSTER" ]'

echo
echo "== D. NOT-APPLICABLE: no daemon, no layout, tmux — the truthful roster is ZERO ROWS =="
mk_case cell; mk_stub 1 junk; tmux_path
chk "D0 pre-state: no roster" '[ ! -e "$ROSTER" ]'
run_it
chk "D1 --check on an unprovisioned cell is ACTION NEEDED (rc 2)" '[ "$RC" -eq 2 ]'
run_it --apply
chk "D2 --apply provisions it (rc 0)" '[ "$RC" -eq 0 ]'
chk "D3 the roster EXISTS — an absent file is what the board refuses" '[ -f "$ROSTER" ]'
chk "D4 it carries ZERO rows (nothing is fabricated)" '[ "$(grep -vc "^#" "$ROSTER")" -eq 0 ]'
chk "D5 it says WHY an empty roster is the truth here" \
    'case "$OUT" in *"NO cmux-workspace lanes"*) true;; *) false;; esac'
chk "D6 it carries the MARKER" 'grep -qx "# provisioned-by: provision-lane-registry.py" "$ROSTER"'
cp "$ROSTER" "$T/cell.first"
run_it --apply
chk "D7 a second --apply is CURRENT and byte-identical (no churn on every bring-up)" \
    '[ "$RC" -eq 0 ] && cmp -s "$ROSTER" "$T/cell.first" && case "$OUT" in *CURRENT*) true;; *) false;; esac'
# ⛔ NON-VACUITY: the arm must be decided by the LAYOUT'S ABSENCE, not by the daemon's failure
# alone. Adding the layout to the same fixture must flip it to REFUSED (C above is that case);
# here the opposite direction is pinned — deleting the layout from a refused fixture flips it back.
rm -f "$CASE/home/Library/Application Support/cmux/session-com.cmuxterm.app.json"
mk_case cell2; mk_stub 1 junk; tmux_path
run_it --apply
chk "D8 the SAME daemon failure provisions when no layout exists (the discriminator is the layout)" \
    '[ "$RC" -eq 0 ] && [ -f "$ROSTER" ]'

echo
echo "== E. HAND-MAINTAINED: never replaced, not even by --apply =="
mk_case hand; mk_stub 0 payload; mk_payload
printf '# curated by a human\n1 Capture write doors\tFF592476-B4E6-4538-96D9-CC095927C751\tlane:c1-capture\n' > "$ROSTER"
cp "$ROSTER" "$T/hand.first"
run_it --apply
chk "E1 rc 0 — a curated roster is a deliberate state, not a failure" '[ "$RC" -eq 0 ]'
chk "E2 the file is byte-identical (a bring-up must not overwrite attribution)" \
    'cmp -s "$ROSTER" "$T/hand.first"'
chk "E3 the report SAYS it left the authored file alone" \
    'case "$OUT" in *"HAND-MAINTAINED"*) true;; *) false;; esac'
run_it --apply --force
chk "E4 --force replaces it with the derived roster" \
    '[ "$RC" -eq 0 ] && grep -qx "# provisioned-by: provision-lane-registry.py" "$ROSTER" && [ "$(grep -vc "^#" "$ROSTER")" -eq 2 ]'

echo
echo "== F. NO SURFACE: no cmux, no tmux, no layout — refuse, invent nothing =="
mk_case nosurf
no_cmux_no_tmux_path
OUT="$(env -u TMUX HOME="$CASE/home" PATH="$CASE/onlypy" python3 "$SCRIPT" --apply --roster "$ROSTER" 2>&1)"
RC=$?
chk "F1 rc 3 (REFUSED)" '[ "$RC" -eq 3 ]'
chk "F2 the refusal names the missing surface" \
    'case "$OUT" in *"no lane surface at all"*) true;; *) false;; esac'
chk "F3 nothing was written" '[ ! -e "$ROSTER" ]'

echo
echo "== G. WIRING: the bring-up and the supervisor both call it =="
chk "G1 cloud-cell-bringup.sh provisions the roster" \
    'grep -q "provision-lane-registry.py" "$ROOT/scripts/cloud-cell-bringup.sh"'
chk "G2 cloud-cell-supervisor.sh provisions the roster" \
    'grep -q "provision-lane-registry.py" "$ROOT/scripts/cloud-cell-supervisor.sh"'
chk "G3 this suite is WIRED into the shard list (an unwired suite reds bash-suites by design)" \
    'grep -q "provision-lane-registry.test.sh" "$ROOT/scripts/run-bash-shards.sh"'

echo
echo "==> $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
