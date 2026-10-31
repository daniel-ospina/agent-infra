#!/usr/bin/env bash
# check-farm-drift.test.sh — the FARM drift check must never report a stale copy as a pass.
#
# Hermetic: every case builds its own source repo + farm under a temp dir. No network, no real
# ~/.pi/agent, no scheduler. bash 3.2 (macOS) and bash 5 (cells).
#
# ⛔ WHAT THIS SUITE IS FOR (tortoise#10114). The defect was not "nobody wrote a check" — it was
# that THREE instruments reported healthy while launchd executed a stale `pr-doctor.py` and the
# repair fleet dispatched 0 of 13 orders. So the properties asserted here are the ones whose ABSENCE
# produced that silence: a one-byte difference must exit 1 and NAME the file; a comparison against a
# tree that is not the pin must exit 2 (never 0); an empty farm must exit 2 (never 0); and a file
# that exists on the box and in no repo file must fail rather than be skipped.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
CHECK="$HERE/check-farm-drift.sh"
[ -x "$CHECK" ] || CHECK="$HERE/scripts/check-farm-drift.sh"
fail=0
ck() { # ck <rc> <message>
    if [ "$1" -eq 0 ]; then printf '  ok   %s\n' "$2"; else printf '  FAIL %s\n' "$2"; fail=$((fail+1)); fi
}

TMP="$(mktemp -d /tmp/check-farm-drift.XXXXXX 2>/dev/null || mktemp -d -t check-farm-drift)" || { echo "cannot mktemp" >&2; exit 1; }
# ⛔ THE CLEANUP IS A LITERAL-RESOLVABLE TARGET ON PURPOSE. `trap 'rm -rf "$TMP"' EXIT` made this
# suite unrunnable from the fleet's own sessions: extensions/main-worktree-guard reads a `rm -rf`
# whose path comes from `$TMP` as an unverifiable discard and refuses the WHOLE invocation
# (measured here — six refusals, four runs, on identical bytes). A diagnostic that cannot be invoked
# is not a diagnostic, so the temp root is created by `mktemp -d` under a literal prefix and removed
# only when its own path is known-safe (it starts with /tmp/check-farm-drift.).
cleanup() {
    case "$TMP" in
        /tmp/check-farm-drift.*) command rm -rf "$TMP" 2>/dev/null ;;   # literal prefix, never $HOME/a checkout
        *) : ;;
    esac
}
trap cleanup EXIT

# ── one source repo, used by every case ────────────────────────────────────────────────────────
SRC="$TMP/src"
mkdir -p "$SRC/scripts" "$SRC/tools/fleet"
printf '#!/usr/bin/env python3\nprint("hello")\n' > "$SRC/scripts/alpha.py"
printf '#!/bin/bash\necho beta\n'                > "$SRC/scripts/beta.sh"
printf 'print("gamma")\n'                        > "$SRC/tools/fleet/gamma.py"
printf 'print("nested")\n'                       > "$SRC/scripts/nested_only.py"
git -C "$SRC" init -q 2>/dev/null
git -C "$SRC" -c user.email=t@t -c user.name=t add -A 2>/dev/null
git -C "$SRC" -c user.email=t@t -c user.name=t commit -qm seed 2>/dev/null
SEED="$(git -C "$SRC" rev-parse HEAD 2>/dev/null)"

# a fresh farm that mirrors the source exactly, including a NESTED file (the depth-1 blind spot)
mk_farm() { # mk_farm <dir>
    mkdir -p "$1/fleet"
    cp "$SRC/scripts/alpha.py"  "$1/alpha.py"
    cp "$SRC/scripts/beta.sh"   "$1/beta.sh"
    cp "$SRC/tools/fleet/gamma.py" "$1/fleet/gamma.py"
}
run() { # run <dest> [extra args...] → sets RC and OUT/ERR
    OUT="$TMP/out"; ERR="$TMP/err"
    ( cd "$TMP" && bash "$CHECK" --dest "$1" --src "$SRC" --ref HEAD --no-pin-identity \
        ${2:+$2} ) >"$OUT" 2>"$ERR"
    RC=$?
}
CK_PIN="$TMP/pin"

echo "check-farm-drift:"

# 1. A converged farm is 0.
F1="$TMP/f1"; mk_farm "$F1"; run "$F1"; ck $([ "$RC" -eq 0 ] && echo 0 || echo 1) "a matching farm exits 0 (rc=$RC)"

# 2. ONE BYTE of drift is 1, and the report NAMES the file with BOTH shas.
printf '#!/usr/bin/env python3\nprint("hellO")\n' > "$F1/alpha.py"
run "$F1"
ck $([ "$RC" -eq 1 ] && echo 0 || echo 1) "a one-byte drift exits 1 (rc=$RC)"
grep -q 'alpha\.py' "$ERR" && ck 0 "…and NAMES the drifted file" || ck 1 "…and NAMES the drifted file"
[ "$(grep 'alpha\.py' "$ERR" | grep -cE '[0-9a-f]{12} \| [0-9a-f]{12}')" -ge 1 ] \
    && ck 0 "…with BOTH shas on the row" || ck 1 "…with BOTH shas on the row"
grep -q 'beta\.sh.*STALE' "$ERR" && ck 1 "…and does not smear the unchanged file into the drift" || ck 0 "…and does not smear the unchanged file into the drift"

# 3. A NESTED file is graded too (the depth-1 glob is the blind spot this exists for).
F3="$TMP/f3"; mk_farm "$F3"; printf 'print("GAMMA")\n' > "$F3/fleet/gamma.py"
run "$F3"
ck $([ "$RC" -eq 1 ] && echo 0 || echo 1) "a drift at fleet/ depth is caught (rc=$RC)"
grep -q 'fleet/gamma\.py' "$ERR" && ck 0 "…and the nested path is named" || ck 1 "…and the nested path is named"

# 4. A file on the box that NO repo file explains fails (exit 3), not silence.
F4="$TMP/f4"; mk_farm "$F4"; printf 'echo hand-edited\n' > "$F4/orphan.sh"
run "$F4"
ck $([ "$RC" -eq 3 ] && echo 0 || echo 1) "an UNSOURCED file fails rather than being skipped (rc=$RC)"
grep -q 'orphan\.sh.*UNSOURCED' "$ERR" && ck 0 "…and is labelled UNSOURCED" || ck 1 "…and is labelled UNSOURCED"

# 5. A DECLARED local (a repair path's own backup) is not drift.
F5="$TMP/f5"; mk_farm "$F5"; printf 'old\n' > "$F5/beta.sh.bak-1234567890"
run "$F5"
ck $([ "$RC" -eq 0 ] && echo 0 || echo 1) "a declared local (*.bak-*) does not fail the pass (rc=$RC)"

# 6. THE AUG-7 TRAP: a pin that disagrees with the source tree is exit 2, NEVER a pass.
F6="$TMP/f6"; mk_farm "$F6"
printf '#!/usr/bin/env python3\nprint("stale but self-consistent")\n' > "$SRC/scripts/alpha.py"
git -C "$SRC" -c user.email=t@t -c user.name=t commit -qam "move on" 2>/dev/null
cp "$SRC/scripts/alpha.py" "$F6/alpha.py"      # farm refreshed from the NEW tree: bytes "match"
printf '%s\n' "$SEED" > "$CK_PIN"              # …but the box is pinned at the OLD commit
OUT="$TMP/out"; ERR="$TMP/err"
( cd "$TMP" && bash "$CHECK" --dest "$F6" --src "$SRC" --ref HEAD --pin-file "$CK_PIN" ) >"$OUT" 2>"$ERR"
RC=$?
ck $([ "$RC" -eq 2 ] && echo 0 || echo 1) "a source tree that is NOT the pin exits 2 (rc=$RC, never a pass)"
grep -q 'WRONG TREE' "$ERR" && ck 0 "…and says it is comparing against the wrong tree" || ck 1 "…and says it is comparing against the wrong tree"
grep -q "$SEED" "$ERR" && ck 0 "…naming the pin sha" || ck 1 "…naming the pin sha"

# 7. An EMPTY farm is not a matching farm.
F7="$TMP/f7"; mkdir -p "$F7"
OUT="$TMP/out"; ERR="$TMP/err"
( cd "$TMP" && bash "$CHECK" --dest "$F7" --src "$SRC" --ref HEAD --no-pin-identity ) >"$OUT" 2>"$ERR"
RC=$?
ck $([ "$RC" -eq 2 ] && echo 0 || echo 1) "an EMPTY farm exits 2 (rc=$RC, never a pass)"

# 8. A MISSING source tree is 2, not "nothing to report".
OUT="$TMP/out"; ERR="$TMP/err"
( cd "$TMP" && bash "$CHECK" --dest "$TMP/f1" --src "$TMP/nope" --no-pin-identity ) >"$OUT" 2>"$ERR"
RC=$?
ck $([ "$RC" -eq 2 ] && echo 0 || echo 1) "an unresolvable source tree exits 2 (rc=$RC)"

# 9. THE PIN FILE IS TWO LINES ON A CELL (sha on line 1, timestamp on line 2 — what
# scripts/cloud-cell-bringup.sh actually writes). Reading it as one blob glued the timestamp onto
# the sha, so a MATCHING farm was reported as "comparing against the wrong tree" for ever.
F9="$TMP/f9"; mk_farm "$F9"
{ printf '%s\n' "$(git -C "$SRC" rev-parse HEAD)"; printf '%s\n' "2026-10-31T02:22:00Z"; } > "$TMP/pin2"
OUT="$TMP/out"; ERR="$TMP/err"
( cd "$TMP" && bash "$CHECK" --dest "$F9" --src "$SRC" --ref HEAD --pin-file "$TMP/pin2" ) >"$OUT" 2>"$ERR"
RC=$?
ck $([ "$RC" -eq 0 ] && echo 0 || echo 1) "a TWO-LINE pin file still reads as a match (rc=$RC)"

# 10. A SYMLINKED directory in the farm is graded through its target, not skipped.
extern="$TMP/extern-stale"; mkdir -p "$extern"; mkdir -p "$TMP/f10"
cp "$SRC/scripts/alpha.py" "$TMP/f10/alpha.py"
printf 'print("STALE")\n' > "$extern/gamma.py"
ln -s "$extern" "$TMP/f10/fleet"
OUT="$TMP/out"; ERR="$TMP/err"
( cd "$TMP" && bash "$CHECK" --dest "$TMP/f10" --src "$SRC" --ref HEAD --no-pin-identity ) >"$OUT" 2>"$ERR"
RC=$?
ck $([ "$RC" -eq 1 ] && echo 0 || echo 1) "a SYMLINKED farm layer carrying stale bytes is caught (rc=$RC)"

# 11. A filename with a space is graded, not turned into a phantom UNKNOWN.
F11="$TMP/f11"; mk_farm "$F11"; printf 'x\n' > "$F11/beta copy.sh.bak-1 2"
OUT="$TMP/out"; ERR="$TMP/err"
( cd "$TMP" && bash "$CHECK" --dest "$F11" --src "$SRC" --ref HEAD --no-pin-identity ) >"$OUT" 2>"$ERR"
RC=$?
ck $([ "$RC" -eq 0 ] && echo 0 || echo 1) "a space-bearing declared-local name does not break the pass (rc=$RC)"

# 12. An EXPLICITLY-passed --ref that does not resolve is operator error (2), not a working-tree pass.
OUT="$TMP/out"; ERR="$TMP/err"
( cd "$TMP" && bash "$CHECK" --dest "$TMP/f9" --src "$SRC" --ref no-such-ref-at-all --no-pin-identity ) >"$OUT" 2>"$ERR"
RC=$?
ck $([ "$RC" -eq 2 ] && echo 0 || echo 1) "an unresolvable explicit --ref exits 2 (rc=$RC)"

echo ""
if [ "$fail" -eq 0 ]; then
    echo "check-farm-drift: OK — every case passed"
    exit 0
fi
echo "check-farm-drift: $fail case(s) FAILED"
exit 1
