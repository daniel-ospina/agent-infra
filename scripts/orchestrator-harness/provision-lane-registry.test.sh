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
  # the box's other shapes. ⛔ THE `wt-` LANE ROOT IS A REAL LINKED WORKTREE UNDER A FLEET ROOT
  # (HOME here): a name-only `wt-*` directory must NOT be rostered (review finding 1).
  mkdir -p "$CASE/home/wt-lane-88" "$CASE/repo/.git/worktrees/wt-lane-88"
  printf 'gitdir: %s\n' "$CASE/repo/.git/worktrees/wt-lane-88" > "$CASE/home/wt-lane-88/.git"
  mkdir -p "$CASE/home/wt-notaworktree"  # a NAME-only wt- root — must never be rostered
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
 {"id":"aa11bb22-cc33-dd44-ee55-ff6677889900","custom_title":"LANE 88","current_directory":"$CASE/home/wt-lane-88"},
 {"id":"bbbb0000-0000-0000-0000-00000000000b","custom_title":"NAME ONLY","current_directory":"$CASE/home/wt-notaworktree"},
 {"id":"deadbeef-0000-0000-0000-000000000000","custom_title":"Personal website","current_directory":"$CASE/owner/Personal website"},
 {"id":"11112222-3333-4444-5555-666677778888","custom_title":"SHARED","current_directory":"$CASE/repo"},
 {"id":"99990000-1111-2222-3333-444455556666","custom_title":"NO CWD"}
]}
JSON
}
run_it() { # run_it <args...>  — stub PATH + fixture HOME, capture output and rc
  OUT="$(env -u TMUX HOME="$CASE/home" PATH="$CASE/bin:$(dirname "$(command -v python3)"):/usr/bin:/bin" \
        python3 "$SCRIPT" "$@" --roster "$ROSTER" 2>&1)"
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
run_it --check    # report-only (explicit: an empty argument would be argparse rc 2)
chk "A1 --check on an ABSENT roster is ACTION NEEDED (rc 2)" \
    '[ "$RC" -eq 2 ] && case "$OUT" in *"ACTION NEEDED"*) true;; *) false;; esac'
chk "A2 …and it writes NOTHING" '[ ! -e "$ROSTER" ]'
run_it --apply
chk "A3 --apply provisions the roster (rc 0)" '[ "$RC" -eq 0 ]'
chk "A4 the roster EXISTS" '[ -f "$ROSTER" ]'
chk "A5 two fleet lanes are rostered" '[ "$(grep -vc "^#" "$ROSTER")" -eq 2 ]'
chk "A6 the linked worktree row carries label/uuid" \
    'grep -q "lane-77	C2C97E96-0CBC-4DFE-BC91-FEF44F09B5BD" "$ROSTER"'
chk "A7 the wt- lane row is rostered with the wt- prefix removed" \
    'grep -q "lane-88	AA11BB22-CC33-DD44-EE55-FF6677889900" "$ROSTER"'
# ⛔ #3032 review F4: the third column used to be `lane:<first digit run in the lane name>`, which
# published `lane:2026` for a worktree named `docs-2026-10-17` — a REAL (closed) issue number. The
# fleet's grammar is a SLUG (`lane:c1-capture`, `lane:c5-9-mcp-sdk`) and zero `lane:<digits>` labels
# exist in either repo, while `turn-end.py` hands this column to the lane as
# `gh issue list --label <it>`. So the column is EMPTY unless something actually knows the label,
# and nothing in a cwd does.
chk "A16 no row carries a FABRICATED lane:<digits> label (#3032 F4)" \
    '! grep -v "^#" "$ROSTER" | grep -q "lane:"'
chk "A8 the OWNER's project is NOT rostered (#8177 attribution)" \
    '! grep -qi "deadbeef" "$ROSTER"'
chk "A9 the shared checkout is NOT rostered" '! grep -q "11112222" "$ROSTER"'
chk "A10 a workspace with no cwd is NOT rostered" '! grep -q "99990000" "$ROSTER"'
chk "A12 a NAME-only wt- directory is NOT rostered (the name is not the evidence, #8177)" \
    '! grep -qi "bbbb0000" "$ROSTER"'
chk "A11 each exclusion is NAMED on the report (a vanished window is visible)" \
    'case "$OUT" in *"Personal website"*"not a fleet worktree"*) true;; *) false;; esac'
chk "A15 the file carries the derivation MARKER (so a refresh may replace it)" \
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
run_it --check
chk "D1 --check on an unprovisioned cell is ACTION NEEDED (rc 2)" \
    '[ "$RC" -eq 2 ] && case "$OUT" in *"ACTION NEEDED"*) true;; *) false;; esac'
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
# alone. This drives the SAME fixture twice — with the layout, then with ONLY the layout removed —
# so it cannot pass vacuously (the previous version re-created a fresh case and `rm`'d a file that
# case never made, which made it a duplicate of D2 rather than the control its comment claimed).
mk_case cell; mk_stub 1 junk; tmux_path
mkdir -p "$CASE/home/Library/Application Support/cmux"
: > "$CASE/home/Library/Application Support/cmux/session-com.cmuxterm.app.json"
run_it --apply
chk "D8a pre-state: the SAME fixture WITH a persisted layout is REFUSED (rc 3)" '[ "$RC" -eq 3 ]'
rm -f "$CASE/home/Library/Application Support/cmux/session-com.cmuxterm.app.json"
run_it --apply
chk "D8 the SAME daemon failure provisions once ONLY the layout is gone (the discriminator is the layout)" \
    '[ "$RC" -eq 0 ] && [ -f "$ROSTER" ]'
# ⛔ #3032 review F1: this arm is decided from the CURRENT probe alone (daemon silent + no layout),
# and one 45 s daemon timeout lands here. Its zero rows are therefore an UNMEASURED population —
# the same datum the refuse arm calls "not an empty fleet" — so it must never overwrite a roster
# this very script already filled. `rows_now` is evidence the tool holds; refusing beats
# publishing "0 cmux lanes" for a box that HAS lanes (the board reads that as measured fact).
mk_case shrink; mk_stub 1 junk; tmux_path
printf '%s\n' "# provisioned-by: provision-lane-registry.py" "# arm: derive" \
    "lane-77	C2C97E96-0CBC-4DFE-BC91-FEF44F09B5BD	" > "$ROSTER"
cp "$ROSTER" "$T/shrink.first"
run_it --apply
chk "D9 an arm that MEASURED NOTHING refuses to shrink a derived roster to zero (rc 3)" \
    '[ "$RC" -eq 3 ]'
chk "D10 …the roster is byte-identical afterwards (nothing was written)" \
    'cmp -s "$ROSTER" "$T/shrink.first"'
chk "D11 …and the refusal names the disagreement, not a generic error" \
    'case "$OUT" in *"measured NO population"*) true;; *) false;; esac'
run_it --apply --force
chk "D12 --force is how an operator declares those rows stale (rc 0, zero rows)" \
    '[ "$RC" -eq 0 ] && [ "$(grep -vc "^#" "$ROSTER")" -eq 0 ]'

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
# ⛔ #3032 review F2: `--force` used to imply `--apply`, so these two invocations — a bare
# `--force`, and `--check --force` (the "report, but with force armed" an operator reaches for) —
# REPLACED the curated roster and returned 0. `--force` is a MODIFIER; a call that never said
# "write" must not write.
run_it --force
chk "E5 --force WITHOUT --apply is a usage error (rc 2), never a write" '[ "$RC" -eq 2 ]'
chk "E6 …and the curated roster is byte-identical (#3032 F2)" 'cmp -s "$ROSTER" "$T/hand.first"'
chk "E7 …and it says --force is a modifier, never a substitute" \
    'case "$OUT" in *"MODIFIER of --apply"*) true;; *) false;; esac'
run_it --check --force
chk "E8 --check --force writes NOTHING either (a report never mutates) (#3032 F2)" \
    '[ "$RC" -ne 0 ] && cmp -s "$ROSTER" "$T/hand.first"'
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
echo "== H. RELATIVE CWD: refused by NAME, never resolved against the caller's own directory =="
# ⛔ THE GUARD THIS PINS (review finding 3). `os.path.realpath` ABSOLUTISES a relative argument
# against the caller's cwd, so a resolution-first test can never fail and a relative
# `current_directory` is silently placed wherever the bring-up (or an operator's shell) happened to
# be. The caller here IS the fixture home, so the relative spelling `wt-lane-88` would resolve onto
# a real linked worktree under a fleet root — which is why H2 is non-vacuous, and why H4 is the
# control that proves the fixture path really is a lane.
mk_case rel; mk_stub 0 payload
cat > "$CASE/list.json" <<JSON
{"window_ref":"window:1","workspaces":[
 {"id":"aaaa1111-2222-3333-4444-555566667777","custom_title":"RELATIVE","current_directory":"wt-lane-88"}
]}
JSON
(
  cd "$CASE/home" || exit 1
  env -u TMUX HOME="$CASE/home" PATH="$CASE/bin:$(dirname "$(command -v python3)"):/usr/bin:/bin" \
      python3 "$SCRIPT" --apply --roster "$ROSTER" >"$T/rel.out" 2>&1
)
RC=$?
chk "H1 rc 0 — the population IS measurable; only the one window is unplaceable" '[ "$RC" -eq 0 ]'
chk "H2 a RELATIVE cwd gets NO row (its identity would come from the caller's directory)" \
    '! grep -qi "aaaa1111" "$ROSTER"'
chk "H3 the exclusion NAMES it as a relative spelling, not as a generic non-lane" \
    'grep -q "RELATIVE (wt-lane-88): the cwd is RELATIVE" "$T/rel.out"'
# NON-VACUITY: the SAME directory, spelled ABSOLUTELY, IS a fleet lane.
cat > "$CASE/list.json" <<JSON
{"window_ref":"window:1","workspaces":[
 {"id":"aaaa1111-2222-3333-4444-555566667777","custom_title":"ABSOLUTE","current_directory":"$CASE/home/wt-lane-88"}
]}
JSON
(
  cd "$CASE/home" || exit 1
  env -u TMUX HOME="$CASE/home" PATH="$CASE/bin:$(dirname "$(command -v python3)"):/usr/bin:/bin" \
      python3 "$SCRIPT" --apply --roster "$ROSTER" >"$T/abs.out" 2>&1
)
chk "H4 …while the SAME directory spelled absolutely IS rostered (the discriminator is the SPELLING)" \
    'grep -q "lane-88	AAAA1111-2222-3333-4444-555566667777" "$ROSTER"'

echo
echo "== I. EMPTY WORKSPACE LIST: a live daemon's zero is an UNREAD population, not an empty fleet =="
# ⛔ `parse_workspaces` returns [] for a READABLE empty list, not None, so `derive` used to accept it
# as a measured population and write a ZERO-ROW roster — the write the `not-applicable` arm needs
# TWO measurements to justify (review finding 4).
mk_case empty; mk_stub 0 payload
printf '{"window_ref":"window:1","workspaces":[]}\n' > "$CASE/list.json"
run_it --apply
chk "I1 rc 3 (REFUSED) — a live daemon's zero never becomes a zero-row roster" '[ "$RC" -eq 3 ]'
chk "I2 nothing was written" '[ ! -e "$ROSTER" ]'
chk "I3 the refusal names the empty list as an unread population" \
    'case "$OUT" in *"ZERO workspaces"*) true;; *) false;; esac'
mk_case empty2; mk_stub 0 payload; printf '[]\n' > "$CASE/list.json"
run_it --apply
chk "I4 the BARE-LIST shape refuses the same way (both arrive through parse_workspaces)" \
    '[ "$RC" -eq 3 ] && [ ! -e "$ROSTER" ]'
# NON-VACUITY: one real window in the same fixture IS provisioned, so I1 is about the ZERO.
mk_case empty3; mk_stub 0 payload
printf '{"window_ref":"window:1","workspaces":[{"id":"c2c97e96-0cbc-4dfe-bc91-fef44f09b5bd","custom_title":"LANE 77","current_directory":"%s"}]}\n' \
    "$CASE/repo/.worktrees/lane-77" > "$CASE/list.json"
run_it --apply
chk "I5 control: a ONE-window list IS provisioned (rc 0), so I1 is not the fixture refusing everything" \
    '[ "$RC" -eq 0 ] && [ -f "$ROSTER" ]'

echo
echo "== J. UNREADABLE ROSTER: 'exists and could not be read' is never 'absent' =="
# ⛔ `existing()` collapsed every OSError into (present=False), so `--apply` replaced a roster whose
# content it never saw — defeating the one non-destructive rule this tool is built around (review
# finding 5). A DIRECTORY at the roster path is the unreadable case that needs no uid assumption:
# `open()` fails with EISDIR for root as well as for a normal user.
mk_case unread; mk_stub 0 payload; mk_payload
mkdir -p "$ROSTER"
run_it --apply
chk "J1 rc 3 (REFUSED) — --apply never replaces a roster it could not READ" '[ "$RC" -eq 3 ]'
chk "J2 the refusal says the path EXISTS and could not be read" \
    'case "$OUT" in *"EXISTS and could not be READ"*) true;; *) false;; esac'
chk "J3 the path was not replaced (the directory is still a directory)" '[ -d "$ROSTER" ]'
chk "J4 no temp file was left behind beside it" \
    '[ -z "$(ls -A "$CASE/home/.pi/agent/state" | grep -v "^lane-registry.tsv$")" ]'
# …and the per-file case the reviewer named (a roster this process may not read). Mode 000 is
# unreadable only to a NON-root process, so it is skipped where the suite runs as root.
if [ "$(id -u)" -ne 0 ]; then
  mk_case unread2; mk_stub 0 payload; mk_payload
  printf '# curated by a human\n1 Capture write doors\tFF592476-B4E6-4538-96D9-CC095927C751\tlane:c1-capture\n' > "$ROSTER"
  cp "$ROSTER" "$T/unread2.first"
  chmod 000 "$ROSTER"
  run_it --apply
  chk "J5 a mode-000 roster is REFUSED, not overwritten" '[ "$RC" -eq 3 ]'
  chmod 644 "$ROSTER"
  chk "J6 …and it is byte-identical afterwards" 'cmp -s "$ROSTER" "$T/unread2.first"'
else
  echo "skip J5-J6 (running as root: mode 000 is unreadable only to a non-root process)"
fi

echo
echo
echo "== G. WIRING: the bring-up and the supervisor both call it, and classify its rc =="
# ⛔ #3032 review F6: these two used to grep for the FILENAME only, which a COMMENT satisfies. They
# now require the actual `--apply` invocation, so deleting the call and leaving the prose behind
# reds the suite.
chk "G1 cloud-cell-bringup.sh PROVISIONS the roster (the --apply call, not a mention)" \
    'grep -qF "provision-lane-registry.py\" --apply" "$ROOT/scripts/cloud-cell-bringup.sh"'
chk "G2 cloud-cell-supervisor.sh PROVISIONS the roster (the --apply call, not a mention)" \
    'grep -qF "provision-lane-registry.py\" --apply" "$ROOT/scripts/cloud-cell-supervisor.sh"'
# The rc arms are the highest-stakes part of the change and used to be pinned by nothing. A
# regression to `die` on rc 3 would false-block EVERY cell, and it would pass the rest of this
# suite; a regression that fell through to the `ok` arm on rc 1 is the false-PASS the call sites'
# own comments say they fix. These are STRUCTURAL pins (the branch shape), which is weaker than
# driving the functions: that would need the callers to be sourceable, and they run `main` on
# source. Stated plainly rather than dressed up as behavioural coverage.
chk "G4 the bring-up treats rc 3 as a WARNING, not a die (a die would false-block every cell)" \
    'grep -qE "elif \[ .*provrc.*-ne 0" "$ROOT/scripts/cloud-cell-bringup.sh"'
chk "G5 the supervisor treats rc 3 as a WARNING, not a die" \
    'grep -qE "elif \[ .*rvrc.*-ne 0" "$ROOT/scripts/cloud-cell-supervisor.sh"'
chk "G6 the supervisor reports ok ONLY in the rc-0 arm (rc 1/127 is never provisioned)" \
    'grep -qF "ok: lane roster" "$ROOT/scripts/cloud-cell-supervisor.sh"'
chk "G3 this suite is WIRED into the shard list (an unwired suite reds bash-suites by design)" \
    'bash "$ROOT/scripts/run-bash-shards.sh" --list | grep -qx "scripts/orchestrator-harness/provision-lane-registry.test.sh"'

echo
echo "== K. ONE LANE, TWO CHECKOUTS: a duplicate LABEL is excluded and NAMED =="
# ⛔ #3032 review F5: dedupe was keyed on the workspace uuid only, so two checkouts of the SAME
# lane rostered TWO rows for one label — which the reader then collapses silently (`by_title`,
# last-non-empty-wins). The second row's attribution would win with nothing said.
mk_case dup
mkdir -p "$CASE/repo2/.worktrees/lane-77" "$CASE/repo2/.git/worktrees/lane-77"
printf 'gitdir: %s\n' "$CASE/repo2/.git/worktrees/lane-77" > "$CASE/repo2/.worktrees/lane-77/.git"
mk_stub 0 payload
cat > "$CASE/list.json" <<JSON
{"window_ref":"window:1","workspaces":[
 {"id":"c2c97e96-0cbc-4dfe-bc91-fef44f09b5bd","custom_title":"LANE 77 A","current_directory":"$CASE/repo/.worktrees/lane-77"},
 {"id":"d3d3d3d3-0cbc-4dfe-bc91-fef44f09b5bd","custom_title":"LANE 77 B","current_directory":"$CASE/repo2/.worktrees/lane-77"}
]}
JSON
run_it --apply
chk "K1 only ONE row is rostered for the shared label" '[ "$(grep -vc "^#" "$ROSTER")" -eq 1 ]'
chk "K2 the duplicate is NAMED as excluded, never silently collapsed" \
    'case "$OUT" in *"duplicate row for lane"*) true;; *) false;; esac'

echo
echo "==> $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
