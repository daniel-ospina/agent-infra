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

# ⛔ THE TEMP ROOT IS A FIXED LITERAL PATH, AND NOTHING IS `rm -rf`'d FROM A VARIABLE. Both previous
# forms made this suite unrunnable from the fleet's own sessions: `trap 'rm -rf "$TMP"' EXIT`, and then
# a `case` guard on `$TMP`, are both read by extensions/main-worktree-guard as unverifiable discards,
# so the WHOLE invocation was refused (measured: 6 refusals / 4 runs on identical bytes; a second
# review round reproduced 2 refusals from the checkout AND from a /tmp copy). A suite that cannot be
# invoked cannot guard anything, and a red case then becomes invisible locally.
# The run clears its own literal tree; a crashed run leaves it for /tmp's reaper — the cheap direction.
TMP=/tmp/check-farm-drift.selfcheck
if [ -e "$TMP" ]; then
    find "$TMP" -mindepth 1 -delete 2>/dev/null || { echo "cannot clear $TMP" >&2; exit 1; }
fi
mkdir -p "$TMP" || { echo "cannot create $TMP" >&2; exit 1; }

# ── one source repo, used by every case ────────────────────────────────────────────────────────
SRC="$TMP/src"
mkdir -p "$SRC/scripts" "$SRC/tools/fleet"
printf '#!/usr/bin/env python3\nprint("hello")\n' > "$SRC/scripts/alpha.py"
chmod 755 "$SRC/scripts/alpha.py"
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

# 13. THE POPULATION IS NOT JUST "WHAT IS ON THE BOX". A file the farm DECLARES and never landed (a
# failed cp, a partial farm, a hand-deletion) used to be invisible: launchd executing an ABSENT script
# is the same silent no-op class as #10114. The declaration is read from $DEST/../state/farm-declared.txt.
C13="$TMP/c13"; mk_farm "$C13/scripts"; mkdir -p "$C13/state"
printf 'scripts/alpha.py\nscripts/beta.sh\n' > "$C13/state/farm-declared.txt"
OUT="$TMP/out"; ERR="$TMP/err"
( cd "$TMP" && bash "$CHECK" --dest "$C13/scripts" --src "$SRC" --ref HEAD --no-pin-identity ) >"$OUT" 2>"$ERR"
RC=$?
ck $([ "$RC" -eq 0 ] && echo 0 || echo 1) "a farm that landed its whole declaration is OK (rc=$RC)"
command rm -f "$C13/scripts/beta.sh"
OUT="$TMP/out"; ERR="$TMP/err"
( cd "$TMP" && bash "$CHECK" --dest "$C13/scripts" --src "$SRC" --ref HEAD --no-pin-identity ) >"$OUT" 2>"$ERR"
RC=$?
ck $([ "$RC" -eq 1 ] && echo 0 || echo 1) "a DECLARED-BUT-ABSENT file is drift (rc=$RC)"
grep -q 'DECLARED-BUT-ABSENT' "$ERR" && ck 0 "…and is named as such" || ck 1 "…and is named as such"

# 14. An ALL-DECLARED-LOCAL farm is UNKNOWN, never OK (the loop used to `continue` past every row).
F14="$TMP/f14"; mkdir -p "$F14"; printf 'x\n' > "$F14/beta.sh.bak-1"
OUT="$TMP/out"; ERR="$TMP/err"
( cd "$TMP" && bash "$CHECK" --dest "$F14" --src "$SRC" --ref HEAD --no-pin-identity ) >"$OUT" 2>"$ERR"
RC=$?
ck $([ "$RC" -eq 2 ] && echo 0 || echo 1) "an all-declared-local farm is UNKNOWN, not OK (rc=$RC)"

# 15. --src-mode worktree grades the BYTES ON DISK — what a farm leg actually copied — so a deploy
# verifying its own result is not reddened by its own uncommitted edit (the false-CRASH direction).
printf 'print("dirty")\n' > "$SRC/scripts/nested_only.py"
F15="$TMP/f15"; mk_farm "$F15"; cp "$SRC/scripts/nested_only.py" "$F15/nested_only.py"
OUT="$TMP/out"; ERR="$TMP/err"
( cd "$TMP" && bash "$CHECK" --dest "$F15" --src "$SRC" --ref HEAD --src-mode worktree --no-pin-identity ) >"$OUT" 2>"$ERR"
RC=$?
ck $([ "$RC" -eq 0 ] && echo 0 || echo 1) "worktree mode matches a copy of the worktree bytes (rc=$RC)"
OUT="$TMP/out"; ERR="$TMP/err"
( cd "$TMP" && bash "$CHECK" --dest "$F15" --src "$SRC" --ref HEAD --no-pin-identity ) >"$OUT" 2>"$ERR"
RC=$?
ck $([ "$RC" -eq 1 ] && echo 0 || echo 1) "ref mode still calls that same copy STALE (rc=$RC)"

# 16. A PRESENT-BUT-EMPTY declaration is UNKNOWN (a recording that failed is not a farm that owes nothing).
C16="$TMP/c16"; mk_farm "$C16/scripts"; mkdir -p "$C16/state"; : > "$C16/state/farm-declared.txt"
OUT="$TMP/out"; ERR="$TMP/err"
( cd "$TMP" && bash "$CHECK" --dest "$C16/scripts" --src "$SRC" --ref HEAD --no-pin-identity ) >"$OUT" 2>"$ERR"
RC=$?
ck $([ "$RC" -eq 2 ] && echo 0 || echo 1) "an EMPTY farm declaration is UNKNOWN, not a pass (rc=$RC)"

# 17. A link name that is a REGEX METACHARACTER must not let an empty layer through.
C17="$TMP/c17"; mk_farm "$C17/scripts"; mkdir -p "$C17/scripts/lib" "$C17/empty"
printf 'print("lib")\n' > "$C17/scripts/lib/x.py"
mkdir -p "$TMP/c17src"; cp -r "$SRC/scripts/." "$TMP/c17src/" 2>/dev/null
ln -s "$C17/empty" "$C17/scripts/li."
OUT="$TMP/out"; ERR="$TMP/err"
( cd "$TMP" && bash "$CHECK" --dest "$C17/scripts" --src "$SRC" --ref HEAD --no-pin-identity ) >"$OUT" 2>"$ERR"
RC=$?
ck $([ "$RC" -eq 2 ] && echo 0 || echo 1) "a metachar link name cannot hide an EMPTY symlinked layer (rc=$RC)"

# 18. A byte-identical copy that CANNOT BE EXECUTED is drift, not ok.
F18="$TMP/f18"; mk_farm "$F18"; chmod 644 "$F18/alpha.py"   # source is 755 in the repo
OUT="$TMP/out"; ERR="$TMP/err"
( cd "$TMP" && bash "$CHECK" --dest "$F18" --src "$SRC" --ref HEAD --no-pin-identity ) >"$OUT" 2>"$ERR"
RC=$?
ck $([ "$RC" -eq 1 ] && echo 0 || echo 1) "a non-executable copy of an executable script is drift (rc=$RC)"
grep -q 'NOT-EXECUTABLE' "$ERR" && ck 0 "...and is labelled NOT-EXECUTABLE" || ck 1 "...and is labelled NOT-EXECUTABLE"

# 19. --src-mode worktree must STILL refuse an explicit --ref that does not resolve.
OUT="$TMP/out"; ERR="$TMP/err"
( cd "$TMP" && bash "$CHECK" --dest "$F18" --src "$SRC" --ref no-such-ref --src-mode worktree --no-pin-identity ) >"$OUT" 2>"$ERR"
RC=$?
ck $([ "$RC" -eq 2 ] && echo 0 || echo 1) "worktree mode still refuses an unresolvable explicit --ref (rc=$RC)"

# 20. An ABSENT pin record is NOTED (pin identity not verified), not silently skipped.
# ⛔ CELL_HOME IS SET EXPLICITLY: the checker reads the pin's SECOND record from
# `${CELL_HOME:-$HOME}/.harness-path`, so without it this case graded the AMBIENT box — on a box
# that has a `.harness-path` (every cell does) the case asserted a first-install state it had not
# built. Hermetic input, not the host's.
F20="$TMP/f20"; mk_farm "$F20"; mkdir -p "$TMP/first-install"
OUT="$TMP/out"; ERR="$TMP/err"
( cd "$TMP" && CELL_HOME="$TMP/first-install" bash "$CHECK" --dest "$F20" --src "$SRC" --ref HEAD --pin-file "$TMP/no-such-pin" ) >"$OUT" 2>"$ERR"
RC=$?
ck $([ "$RC" -eq 0 ] && echo 0 || echo 1) "an absent pin record on a FIRST INSTALL leaves the pass at 0 (rc=$RC)"
grep -qi 'pin identity NOT verified' "$ERR" && ck 0 "...but says pin identity was NOT verified" || ck 1 "...but says pin identity was NOT verified"

# 21. ⛔ A LOST PIN IS NOT A FIRST INSTALL. `.harness-path` is the pin's SECOND record
# (harness-apply-pass.sh's header): a pin is the sha in HARNESS-PIN *and* the tree in .harness-path.
# So `.harness-path` present + HARNESS-PIN absent is a pin that was LOST — and the wrong-tree trap
# arm is off. It must be UNKNOWN (2), never the 0 that reads as "OK".
F21="$TMP/f21"; mk_farm "$F21"; mkdir -p "$TMP/pinlost"
printf '%s\n' "$SRC" > "$TMP/pinlost/.harness-path"
OUT="$TMP/out"; ERR="$TMP/err"
( cd "$TMP" && CELL_HOME="$TMP/pinlost" bash "$CHECK" --dest "$F21" --src "$SRC" --ref HEAD --pin-file "$TMP/pinlost/state/HARNESS-PIN" ) >"$OUT" 2>"$ERR"
RC=$?
ck $([ "$RC" -eq 2 ] && echo 0 || echo 1) "a LOST pin (.harness-path present, HARNESS-PIN absent) is UNKNOWN, not a pass (rc=$RC)"
ck $(grep -q 'OK — ' "$OUT" && echo 1 || echo 0) "...and prints no OK verdict at all"

# 21b. ⛔ A DANGLING-SYMLINK pin record is the SAME false PASS, because `[ -e ]` FOLLOWS the link: it
# read as ABSENT and fell into the first-install arm (rc=0 + `OK`) while pin identity was
# unverified. `[ -L ]` is the only test that sees the link itself.
F21B="$TMP/f21b"; mk_farm "$F21B"; mkdir -p "$TMP/pinlink"
ln -s "$TMP/does-not-exist/HARNESS-PIN" "$TMP/pinlink/HARNESS-PIN"
OUT="$TMP/out"; ERR="$TMP/err"
( cd "$TMP" && CELL_HOME="$TMP/pinlink" bash "$CHECK" --dest "$F21B" --src "$SRC" --ref HEAD --pin-file "$TMP/pinlink/HARNESS-PIN" ) >"$OUT" 2>"$ERR"
RC=$?
ck $([ "$RC" -eq 2 ] && echo 0 || echo 1) "a DANGLING-SYMLINK pin record is UNKNOWN, not a pass (rc=$RC)"
ck $(grep -q 'OK — ' "$OUT" && echo 1 || echo 0) "...and prints no OK verdict at all"

# 22. ⛔ A STALE FILE NO FARM ARRAY DELIVERS IS NOT FATAL. `admin-merge.sh`, `heartbeat-loop.sh` and
# the declared #1553 gap live on the box and are delivered by NO farm array (measured: grep count 0 in
# pi-bootstrap/setup.sh), so setup.sh's rc=1 arm fired on a file its own printed remedy could never
# fix — and sync.sh (set -euo pipefail) died every run. Same split the author already made for
# UNSOURCED: a deploy cannot fix it, a human must → 3, loud and never a pass.
# The declaration lists ONLY beta.sh, so alpha.py's drift is outside what the farm owes.
C22="$TMP/c22"; mk_farm "$C22/scripts"; mkdir -p "$C22/state"
printf 'scripts/beta.sh\n' > "$C22/state/farm-declared.txt"
printf '#!/usr/bin/env python3\nprint("hellO")\n' > "$C22/scripts/alpha.py"
OUT="$TMP/out"; ERR="$TMP/err"
( cd "$TMP" && CELL_HOME="$C22" bash "$CHECK" --dest "$C22/scripts" --src "$SRC" --ref HEAD --no-pin-identity ) >"$OUT" 2>"$ERR"
RC=$?
ck $([ "$RC" -eq 3 ] && echo 0 || echo 1) "a STALE file OUTSIDE the farm declaration is 3, not fatal (rc=$RC)"
ck $(grep -q 'NOT farm-declared' "$ERR" && echo 0 || echo 1) "...and is labelled as outside the farm declaration"

# 23. ⛔ BUT DRIFT THE FARM *DOES* OWE STAYS FATAL (tortoise#10114 unchanged). Same bytes as case 22,
# same declaration — only the declaration now NAMES alpha.py, i.e. the farm delivers it and did not
# converge it. That is the defect the check exists for and it must exit 1.
C23="$TMP/c23"; mk_farm "$C23/scripts"; mkdir -p "$C23/state"
printf 'scripts/alpha.py\nscripts/beta.sh\n' > "$C23/state/farm-declared.txt"
printf '#!/usr/bin/env python3\nprint("hellO")\n' > "$C23/scripts/alpha.py"
OUT="$TMP/out"; ERR="$TMP/err"
( cd "$TMP" && CELL_HOME="$C23" bash "$CHECK" --dest "$C23/scripts" --src "$SRC" --ref HEAD --no-pin-identity ) >"$OUT" 2>"$ERR"
RC=$?
ck $([ "$RC" -eq 1 ] && echo 0 || echo 1) "a STALE file the farm DECLARES is still fatal #10114 drift (rc=$RC)"

echo ""
if [ "$fail" -eq 0 ]; then
    echo "check-farm-drift: OK — every case passed"
    exit 0
fi
echo "check-farm-drift: $fail case(s) FAILED"
exit 1
