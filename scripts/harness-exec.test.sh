#!/usr/bin/env bash
# harness-exec.test.sh — the pin-resolution refusals, by NAME, on both platforms.
#
# ⛔ WHAT THIS SUITE IS FOR. `harness-exec.sh` is the runtime half of "the Mac runs from the pin":
# #2271 refuses at INSTALL time (it will not render a plist whose program is not inside the pin), and
# this suite proves the RUNTIME refuses when the pin cannot be resolved — including on a box whose
# harness is a home-dir copy, which is the measured 2026-10-22 state of this Mac.
#
# Every arm asserts rc=78 AND the refusal's own name, because an arm that silently returns a path is
# the divergence #2231 measured: `~/orchestrator/orch-loop.sh` ran for weeks while every instrument
# reported the box as fine.
#
# ⛔ THERE IS NO UNPINNED FALLBACK TO TEST FOR POSITIVELY: the shim has no fallback branch at all, so
# the arm below asserts the ABSENCE (a refusal must not also print `program=`).
#
# PORTABILITY: hermetic — every arm builds its own HOME and pin root under one mktemp dir, so the
# suite runs identically on macOS and Linux. The single arm that needs a scheduler is decided by
# `lib/box.sh` and prints WHY it is skipped.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHIM="$HERE/harness-exec.sh"
BOX="$HERE/lib/box.sh"
PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); printf 'PASS %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf 'FAIL %s\n' "$1"; }

[ -f "$SHIM" ] || { echo "❌ harness-exec.sh missing beside this suite"; exit 1; }
[ -f "$BOX" ]  || { echo "❌ lib/box.sh missing — the shim's portability dependency"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/harness-exec-test-XXXXXX")" || { echo "❌ mktemp"; exit 1; }

# ── fixture: a pin root holding <sha12>/scripts/orchestrator-harness/, i.e. exactly the shape
# `cloud-cell-supervisor.sh apply` materialises (a DETACHED WORKTREE at the pinned commit). It is
# built from this checkout rather than synthesised because the repo's working-tree-discard scanner
# refuses repo-CREATION verbs inside a script payload — and a detached worktree is closer to
# production than a synthesised commit anyway.
SRC="$(cd "$HERE/.." && git rev-parse --show-toplevel)"
SHA="$(git -C "$SRC" rev-parse HEAD)"
SHA12="$(printf '%s' "$SHA" | cut -c1-12)"
PINROOT="$TMP/harness"
TREE="$PINROOT/$SHA12"
HDIR="$TREE/scripts/orchestrator-harness"
mkdir -p "$TREE"
git -C "$SRC" worktree add -q --detach "$TREE" "$SHA" >/dev/null 2>&1
[ -f "$HDIR/orch-loop.sh" ] || { echo "❌ fixture: the pinned tree does not carry scripts/orchestrator-harness/orch-loop.sh"; exit 1; }

# A directory that is NOT a git checkout but holds a copy of the entrypoint: the measured
# `~/orchestrator` shape (the Mac's controller program today).
NOTGIT="$TMP/orchestrator-copy"
mkdir -p "$NOTGIT"
printf 'echo copy\n' > "$NOTGIT/orch-loop.sh"

# ⛔ THE WORKTREE RECORDS ARE REMOVED, NOT JUST THE DIRECTORIES: deleting a registered worktree's
# files leaves a stale record in the source repo's .git/worktrees.
cleanup() {
  for wt in "$TREE" "$TMP/side-pin"; do
    [ -e "$wt" ] || continue
    git -C "$SRC" worktree remove --force "$wt" >/dev/null 2>&1 || true
  done
  git -C "$SRC" worktree prune >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

OUT=""; RC=0
run_shim() {
  local home="$1"; shift
  OUT="$(HOME="$home" HARNESS_PIN_DIR="${PINROOT}" HARNESS_PIN="" HARNESS_PIN_FILE="" bash "$SHIM" "$@" 2>&1)"
  RC=$?
}
# home_with <dir> <sha-line|-> <dir-line|-> — build a hermetic HOME carrying the two pin records.
home_with() {
  local h="$1" sha="$2" dir="$3"
  mkdir -p "$h/.pi/agent/state"
  [ "$sha" = "-" ] || printf '%s\n' "$sha" > "$h/.pi/agent/state/HARNESS-PIN"
  [ "$dir" = "-" ] || printf '%s\n' "$dir" > "$h/.harness-path"
}

# ── arm 1: happy path — the program IS the pinned tree's harness dir.
H="$TMP/home-ok"; home_with "$H" "$SHA" "$HDIR"
run_shim "$H" --print
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -qx "program=$HDIR/orch-loop.sh"; then
  ok "happy: --print resolves to the PINNED tree's harness dir ($SHA12)"
else
  bad "happy: expected rc=0 and program=$HDIR/orch-loop.sh, got rc=$RC out=$OUT"
fi

# ── arm 2: no records at all -> REFUSE. The no-unpinned-fallback invariant.
H2="$TMP/home-nopin"; mkdir -p "$H2"
run_shim "$H2" --print
if [ "$RC" -eq 78 ] && printf '%s' "$OUT" | grep -q 'has no pin'; then
  ok "no-records: rc=78 and names the missing records"
else
  bad "no-records: expected rc=78 'has no pin', got rc=$RC out=$OUT"
fi
if printf '%s' "$OUT" | grep -q '^program='; then
  bad "no-records: printed a program despite refusing — a fallback arm exists"
else
  ok "no-records: refuses WITHOUT printing a program (no unpinned fallback)"
fi

# ── arm 3: the two records disagree (a refresh that wrote one and not the other, #2216).
H3="$TMP/home-wrongsha"; home_with "$H3" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" "$HDIR"
run_shim "$H3" --print
if [ "$RC" -eq 78 ] && printf '%s' "$OUT" | grep -q 'DISAGREE'; then
  ok "sha-vs-dir: the two records disagreeing is REFUSED by name"
else
  bad "sha-vs-dir: expected rc=78 DISAGREE, got rc=$RC out=$OUT"
fi

# ── arm 4: the dir record names a home-dir COPY (not a checkout). The measured Mac shape.
H4="$TMP/home-notgit"; home_with "$H4" "$SHA" "$NOTGIT"
run_shim "$H4" --print
if [ "$RC" -eq 78 ] && printf '%s' "$OUT" | grep -q 'NOT a git checkout'; then
  ok "not-a-checkout: a home-dir COPY is refused (#2231's worst row), never run"
else
  bad "not-a-checkout: expected rc=78 'NOT a git checkout', got rc=$RC out=$OUT"
fi

# ── arm 5: layout — a tree at the right sha but NOT under <pin root>/<sha12>.
H5="$TMP/home-layout"; SIDEWT="$TMP/side-pin"; mkdir -p "$SIDEWT"
git -C "$SRC" worktree add -q --detach "$SIDEWT" "$SHA" >/dev/null 2>&1
home_with "$H5" "$SHA" "$SIDEWT/scripts/orchestrator-harness"
run_shim "$H5" --print
if [ "$RC" -eq 78 ] && printf '%s' "$OUT" | grep -q 'worktree nobody reads'; then
  ok "layout: a correct-sha tree OUTSIDE the pin root is refused (#2216)"
else
  bad "layout: expected rc=78 layout refusal, got rc=$RC out=$OUT"
fi

# ── arm 6: an entrypoint the pin does not carry.
H6="$TMP/home-noentry"; home_with "$H6" "$SHA" "$HDIR"
run_shim "$H6" --print --entry does-not-exist.sh
if [ "$RC" -eq 78 ] && printf '%s' "$OUT" | grep -q 'does NOT carry'; then
  ok "entry-missing: an entrypoint the pin does not carry is refused"
else
  bad "entry-missing: expected rc=78, got rc=$RC out=$OUT"
fi

# ── arm 7: an EMPTY record is unanswerable, not "current".
H7="$TMP/home-empty"; mkdir -p "$H7/.pi/agent/state"; : > "$H7/.pi/agent/state/HARNESS-PIN"
printf '%s\n' "$HDIR" > "$H7/.harness-path"
run_shim "$H7" --print
if [ "$RC" -eq 78 ] && printf '%s' "$OUT" | grep -qi 'EMPTY'; then
  ok "empty-record: an empty pin record is REFUSED (an empty pin is not 'current')"
else
  bad "empty-record: expected rc=78 EMPTY, got rc=$RC out=$OUT"
fi

# ── arm 8: a record holding something that is not a commit id (e.g. a ref name).
H8="$TMP/home-junk"; home_with "$H8" "origin/main" "$HDIR"
run_shim "$H8" --print
if [ "$RC" -eq 78 ] && printf '%s' "$OUT" | grep -q 'not a commit id'; then
  ok "junk-record: a non-sha record is refused, not resolved against a ref"
else
  bad "junk-record: expected rc=78, got rc=$RC out=$OUT"
fi

# ── arm 9: pruned worktree.
H9="$TMP/home-pruned"; home_with "$H9" "$SHA" "$PINROOT/$SHA12-gone/scripts/orchestrator-harness"
run_shim "$H9" --print
if [ "$RC" -eq 78 ] && printf '%s' "$OUT" | grep -q 'not a directory'; then
  ok "pruned: a pin naming a vanished tree is refused"
else
  bad "pruned: expected rc=78, got rc=$RC out=$OUT"
fi

# ── arm 10: THIS BOX's real records. Not a skip: whatever the answer is it must be one of the two
# sanctioned verdicts — resolved (a box with a pin) or a NAMED refusal (a box without one). A third
# answer, "ran something anyway", is the defect this file exists against.
OUT="$(bash "$SHIM" --print 2>&1)"; RC=$?
case "$RC" in
  0)
    if printf '%s' "$OUT" | grep -q '^program='; then
      ok "real-box: this box HAS a pin and the shim resolves $(printf '%s' "$OUT" | sed -n 's/^program=//p') [$(printf '%s' "$OUT" | sed -n 's/^provenance=//p')]"
    else
      bad "real-box: rc=0 but no program printed"
    fi ;;
  78)
    if printf '%s' "$OUT" | grep -q 'REFUSED'; then
      ok "real-box ($(uname -s)): no pin on this box, and the shim REFUSES by name instead of running a copy (live wiring = #2271 + the installer, not a fallback)"
    else
      bad "real-box: rc=78 without a REFUSED line"
    fi ;;
  *)
    bad "real-box: unexpected rc=$RC out=$OUT" ;;
esac

# ── arm 11: the scheduler question, on the platform that has one. The skip names WHY.
case "$(bash "$BOX" --selftest 2>/dev/null | sed -n 's/^box: os=\([a-z]*\).*/\1/p' | head -1)" in
  darwin) SKIP=$((SKIP+1)); printf 'SKIP scheduler-arm: macOS has launchd, but the live job still names a home-dir program (arm 10 asserts the shim REFUSES it); the install-side fix is #2271\n' ;;
  *)      SKIP=$((SKIP+1)); printf 'SKIP scheduler-arm: %s has no launchctl — answered by `bash %s --selftest` instead\n' "$(uname -s)" "scripts/lib/box.sh" ;;
esac

printf '\nharness-exec.test: %d passed, %d failed, %d skipped (%s)\n' "$PASS" "$FAIL" "$SKIP" "$(uname -s)"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
