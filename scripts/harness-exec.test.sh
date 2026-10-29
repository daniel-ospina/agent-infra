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
# ⛔ `skip()` MUST EXIST FOR THE PLATFORM-DEPENDENT ARMS (review, P2). Arm 17 calls it on a root/container
# runner — the exact box its own comment says the branch was MEASURED on — where it used to print
# `skip: command not found`, leave `SKIP` unincremented and report a shell error instead of the named
# SKIP the summary line counts. Latent on the ubuntu CI runner (arm 17 takes its real branch there),
# so it could only ever appear on the platform where the fail-closed branch is unexercised.
skip() { SKIP=$((SKIP+1)); printf 'SKIP %s\n' "$1"; }

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
  for wt in "$TREE" "$TMP/side-pin" "$TMP/harness-dirty/$SHA12" "$TMP/named-root/$SHA12" "$TMP/plainwt"; do
    [ -e "$wt" ] || continue
    git -C "$SRC" worktree remove --force "$wt" >/dev/null 2>&1 || true
  done
  # ⛔ NO BARE `worktree prune` HERE. It has no path filter and deregisters EVERY record whose working
  # directory is momentarily missing — unrelated siblings included — and for a DETACHED worktree the admin
  # HEAD is the commit's last durable handle (cloud-cell-supervisor.sh:1246, #1141). Removing each fixture
  # BY PATH above already deregisters its own record.
  rm -rf "$TMP"
}
trap cleanup EXIT

OUT=""; RC=0
run_shim() {
  local home="$1"; shift
  OUT="$(HOME="$home" HARNESS_PIN_DIR="${GP_TEST_ROOT:-$PINROOT}" HARNESS_PIN="" HARNESS_PIN_FILE="" bash "$SHIM" "$@" 2>&1)"
  RC=$?
}
# run_shim_noroot — the DEFAULT on a Mac: nothing exports HARNESS_PIN_DIR, so containment must be
# proven from the records' own layout instead of being skipped (a review caught that the check was
# conditional, which made #2216's "worktree nobody reads" untestable on the default path).
run_shim_noroot() {
  local home="$1"; shift
  OUT="$(HOME="$home" HARNESS_PIN="" HARNESS_PIN_FILE="" bash "$SHIM" "$@" 2>&1)"
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
if [ "$RC" -eq 0 ] && grep -qx "program=$HDIR/orch-loop.sh" <<<"$OUT"; then
  ok "happy: --print resolves to the PINNED tree's harness dir ($SHA12)"
else
  bad "happy: expected rc=0 and program=$HDIR/orch-loop.sh, got rc=$RC out=$OUT"
fi

# ── arm 2: no records at all -> REFUSE. The no-unpinned-fallback invariant.
H2="$TMP/home-nopin"; mkdir -p "$H2"
run_shim "$H2" --print
if [ "$RC" -eq 78 ] && grep -q 'has no pin' <<<"$OUT"; then
  ok "no-records: rc=78 and names the missing records"
else
  bad "no-records: expected rc=78 'has no pin', got rc=$RC out=$OUT"
fi
if grep -q '^program=' <<<"$OUT"; then
  bad "no-records: printed a program despite refusing — a fallback arm exists"
else
  ok "no-records: refuses WITHOUT printing a program (no unpinned fallback)"
fi

# ── arm 3: the two records disagree (a refresh that wrote one and not the other, #2216).
H3="$TMP/home-wrongsha"; home_with "$H3" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" "$HDIR"
run_shim "$H3" --print
if [ "$RC" -eq 78 ] && grep -q 'DISAGREE' <<<"$OUT"; then
  ok "sha-vs-dir: the two records disagreeing is REFUSED by name"
else
  bad "sha-vs-dir: expected rc=78 DISAGREE, got rc=$RC out=$OUT"
fi

# ── arm 4: the dir record names a home-dir COPY (not a checkout). The measured Mac shape.
H4="$TMP/home-notgit"; home_with "$H4" "$SHA" "$NOTGIT"
run_shim "$H4" --print
if [ "$RC" -eq 78 ] && grep -q 'NOT a git checkout' <<<"$OUT"; then
  ok "not-a-checkout: a home-dir COPY is refused (#2231's worst row), never run"
else
  bad "not-a-checkout: expected rc=78 'NOT a git checkout', got rc=$RC out=$OUT"
fi

# ── arm 5: layout — a tree at the right sha but NOT under <pin root>/<sha12>.
H5="$TMP/home-layout"; SIDEWT="$TMP/side-pin"; mkdir -p "$SIDEWT"
git -C "$SRC" worktree add -q --detach "$SIDEWT" "$SHA" >/dev/null 2>&1
home_with "$H5" "$SHA" "$SIDEWT/scripts/orchestrator-harness"
run_shim "$H5" --print
if [ "$RC" -eq 78 ] && grep -q 'worktree nobody reads' <<<"$OUT"; then
  ok "layout: a correct-sha tree OUTSIDE the pin root is refused (#2216)"
else
  bad "layout: expected rc=78 layout refusal, got rc=$RC out=$OUT"
fi

# ── arm 6: an entrypoint the pin does not carry.
H6="$TMP/home-noentry"; home_with "$H6" "$SHA" "$HDIR"
run_shim "$H6" --print --entry does-not-exist.sh
if [ "$RC" -eq 78 ] && grep -q 'does NOT carry' <<<"$OUT"; then
  ok "entry-missing: an entrypoint the pin does not carry is refused"
else
  bad "entry-missing: expected rc=78, got rc=$RC out=$OUT"
fi

# ── arm 7: an EMPTY record is unanswerable, not "current".
H7="$TMP/home-empty"; mkdir -p "$H7/.pi/agent/state"; : > "$H7/.pi/agent/state/HARNESS-PIN"
printf '%s\n' "$HDIR" > "$H7/.harness-path"
run_shim "$H7" --print
if [ "$RC" -eq 78 ] && grep -qi 'EMPTY' <<<"$OUT"; then
  ok "empty-record: an empty pin record is REFUSED (an empty pin is not 'current')"
else
  bad "empty-record: expected rc=78 EMPTY, got rc=$RC out=$OUT"
fi

# ── arm 8: a record holding something that is not a commit id (e.g. a ref name).
H8="$TMP/home-junk"; home_with "$H8" "origin/main" "$HDIR"
run_shim "$H8" --print
if [ "$RC" -eq 78 ] && grep -q 'not a commit id' <<<"$OUT"; then
  ok "junk-record: a non-sha record is refused, not resolved against a ref"
else
  bad "junk-record: expected rc=78, got rc=$RC out=$OUT"
fi

# ── arm 9: pruned worktree.
H9="$TMP/home-pruned"; home_with "$H9" "$SHA" "$PINROOT/$SHA12-gone/scripts/orchestrator-harness"
run_shim "$H9" --print
if [ "$RC" -eq 78 ] && grep -q 'not a directory' <<<"$OUT"; then
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
    if grep -q '^program=' <<<"$OUT"; then
      ok "real-box: this box HAS a pin and the shim resolves $(printf '%s' "$OUT" | sed -n 's/^program=//p') [$(printf '%s' "$OUT" | sed -n 's/^provenance=//p')]"
    else
      bad "real-box: rc=0 but no program printed"
    fi ;;
  78)
    if grep -q 'REFUSED' <<<"$OUT"; then
      ok "real-box ($(uname -s)): no pin on this box, and the shim REFUSES by name instead of running a copy (live wiring = #2271 + the installer, not a fallback)"
    else
      bad "real-box: rc=78 without a REFUSED line"
    fi ;;
  *)
    bad "real-box: unexpected rc=$RC out=$OUT" ;;
esac

# ── arm 11: the scheduler question, on the platform that has one. The skip names WHY.
case "$(bash "$BOX" --selftest 2>/dev/null | sed -n 's/^box: os=\([a-z]*\).*/\1/p' | head -1)" in
  darwin) skip "scheduler-arm: macOS has launchd, but the live job still names a home-dir program (arm 10 asserts the shim REFUSES it); the install-side fix is #2271" ;;
  *)      skip "scheduler-arm: $(uname -s) has no launchctl — answered by \`bash scripts/lib/box.sh --selftest\` instead" ;;
esac

# ── arm 12: the ENTRY may not walk out of the pin (found by review: `--entry ../../../evil.sh` was
# accepted and reported as a program under the harness dir).
H12="$TMP/home-entry-escape"; home_with "$H12" "$SHA" "$HDIR"
run_shim "$H12" --print --entry ../../../evil.sh
if [ "$RC" -eq 78 ] && grep -q "'..' segment" <<<"$OUT"; then
  ok "entry-escape: a '..' entry is refused (an entrypoint that leaves the pin is not the pin)"
else
  bad "entry-escape: expected rc=78 '..' refusal, got rc=$RC out=$OUT"
fi

# ── arm 13: a SYMLINK inside the harness dir that points outside the pin (realpath containment).
H13="$TMP/home-symlink"; home_with "$H13" "$SHA" "$HDIR"
printf 'echo evil\n' > "$TMP/evil.sh"
ln -sf "$TMP/evil.sh" "$HDIR/linked-entry.sh" 2>/dev/null
run_shim "$H13" --print --entry linked-entry.sh
if [ "$RC" -eq 78 ] && grep -q 'OUTSIDE the pinned tree' <<<"$OUT"; then
  ok "symlink-escape: an entry that RESOLVES outside the pin is refused"
else
  bad "symlink-escape: expected rc=78 OUTSIDE, got rc=$RC out=$OUT"
fi
rm -f "$HDIR/linked-entry.sh"

# ── arm 14: a DIRTY pin is not the pin — uncommitted bytes inside the harness dir would run while the
# record still claimed commit $SHA12 (#2231's own failure mode, one layer in).
# ⛔ ITS OWN WORKTREE: dirtying the shared fixture would make every later arm report "dirty" instead of
# the condition it exists to test (found the first time this arm was written).
DROOT="$TMP/harness-dirty"; DW="$DROOT/$SHA12"; WD="$DW/scripts/orchestrator-harness"; mkdir -p "$DROOT"
git -C "$SRC" worktree add -q --detach "$DW" "$SHA" >/dev/null 2>&1
H14="$TMP/home-dirty"; home_with "$H14" "$SHA" "$WD"
printf '\n# local hotfix never committed\n' >> "$WD/orch-loop.sh"
GP_TEST_ROOT="$DROOT" run_shim "$H14" --print
if [ "$RC" -eq 78 ] && grep -q 'UNCOMMITTED CHANGES' <<<"$OUT"; then
  ok "dirty-pin: uncommitted changes in the pinned harness dir are REFUSED"
else
  bad "dirty-pin: expected rc=78 UNCOMMITTED, got rc=$RC out=$OUT"
fi
# ⛔ NO RESTORE HERE: the fixture worktree is removed wholesale in cleanup, so an in-place revert would
# be a discard this suite neither needs nor should perform.

# ── arm 19: ONE PREDICATE. The pin's cleanliness is read by this resolver AND by the cell supervisor's
# DRIFT check AND by the installer's provenance stamp. A review round found them reading DIFFERENT
# predicates: `check` certified a pin CLEAN that this resolver refused, and `apply` then took
# "unchanged" over a tree the controller would not start. Parity is asserted in
# cloud-cell-supervisor.test.sh §(p3); the SEMANTICS live here.
# A gitignored hotfix is refused (arm 18). The tolerance that must NOT be reversed: the pin-root guard
# already ruled that one Finder visit must not brick a cell, so `.DS_Store`/`._*` REGULAR droppings are
# tolerated one level down too — a dropping is not an execution vector.
H19="$TMP/home-droppings"; home_with "$H19" "$SHA" "$HDIR"
printf 'x\n' > "$HDIR/.DS_Store"
run_shim "$H19" --print
DROP_RC=$RC; DROP_OUT="$OUT"
rm -f "$HDIR/.DS_Store"
if [ "$DROP_RC" -eq 0 ] && grep -q '^pin_sha=' <<<"$DROP_OUT"; then
  ok "droppings: a .DS_Store in the pinned harness dir does NOT refuse the pin (one Finder visit must not brick a cell)"
else
  bad "droppings: a .DS_Store refused a legitimate pin (rc=$DROP_RC out=$DROP_OUT)"
fi

# ── arm 18: a GITIGNORED file inside the pinned harness dir. It cannot be committed, so it is never part
# of the pin — and it is exactly where a local hotfix lives (`tmp/`, `dist/`, `*.log` are all ignored by
# this repo). Plain `git status --porcelain` reports nothing for it, so it passed every check and could
# be exec'd via `--entry tmp/x.sh` (found by review). `status --ignored=matching` is what surfaces it.
H18="$TMP/home-ignored"; home_with "$H18" "$SHA" "$HDIR"
mkdir -p "$HDIR/tmp"
printf 'echo hotfix\n' > "$HDIR/tmp/x.sh"
run_shim "$H18" --print --entry tmp/x.sh
IGN_RC=$RC; IGN_OUT="$OUT"
rm -rf "$HDIR/tmp"
if [ "$IGN_RC" -eq 78 ] && grep -q 'UNCOMMITTED CHANGES' <<<"$IGN_OUT"; then
  ok "ignored-entry: a gitignored hotfix inside the pinned harness dir is REFUSED (it is not part of the pin)"
else
  bad "ignored-entry: a gitignored entrypoint was accepted (rc=$IGN_RC out=$IGN_OUT)"
fi

# ── arm 17: the dirty check must FAIL CLOSED when git status itself cannot run (the fail-open shape a
# review caught: empty stdout was read as "clean"). A locked/unreadable index makes status exit 128
# while rev-parse still answers, so it fires after the earlier gates.
# The dirty fixture tree ($DW) is reused: it is already registered and already has a dirty file, which
# is irrelevant here — this arm needs a tree whose INDEX cannot be read.
H17="$TMP/home-statusfail"; home_with "$H17" "$SHA" "$WD"
IDX="$(git -C "$DW" rev-parse --git-path index 2>/dev/null)"
case "$IDX" in /*) : ;; *) IDX="$DW/$IDX" ;; esac
# ⛔ EFFECTIVENESS, not just success: chmod SUCCEEDS as root and root still READS the index, so the guard
# must be `[ ! -r ]` or this arm is a `bad` (not a skip) on any root runner — measured in a container.
if [ -f "$IDX" ] && chmod 000 "$IDX" 2>/dev/null && [ ! -r "$IDX" ]; then
  GP_TEST_ROOT="$DROOT" run_shim "$H17" --print
  chmod 644 "$IDX" 2>/dev/null || true
  if [ "$RC" -eq 78 ] && grep -q 'git status failed' <<<"$OUT"; then
    ok "status-failure: an unverifiable clean/dirty state REFUSES (cannot-verify is not a pass)"
  else
    bad "status-failure: expected rc=78 'git status failed', got rc=$RC out=$OUT"
  fi
else
  skip "status-failure: could not make $IDX unreadable on this platform — the fail-closed branch is unexercised here"
fi

# ── arm 15/16: containment with NO pin root exported (the Mac default). A tree NOT named <sha12> is
# refused; the SAME shape named <sha12> resolves — so the derived rule is a CHECK, not a blanket no.
PLAIN="$TMP/plainwt"; mkdir -p "$TMP"
git -C "$SRC" worktree add -q --detach "$PLAIN" "$SHA" >/dev/null 2>&1
H15="$TMP/home-noroot-bad"; home_with "$H15" "$SHA" "$PLAIN/scripts/orchestrator-harness"
run_shim_noroot "$H15" --print
if [ "$RC" -eq 78 ] && grep -q 'worktree nobody reads' <<<"$OUT"; then
  ok "no-root-layout: with HARNESS_PIN_DIR unset, a tree not named <sha12> is still refused (#2216)"
else
  bad "no-root-layout: expected rc=78 layout refusal, got rc=$RC out=$OUT"
fi
NAMED="$TMP/named-root/$SHA12"; mkdir -p "$(dirname "$NAMED")"
git -C "$SRC" worktree add -q --detach "$NAMED" "$SHA" >/dev/null 2>&1
H16="$TMP/home-noroot-ok"; home_with "$H16" "$SHA" "$NAMED/scripts/orchestrator-harness"
run_shim_noroot "$H16" --print
if [ "$RC" -eq 0 ] && grep -qx "program=$NAMED/scripts/orchestrator-harness/orch-loop.sh" <<<"$OUT"; then
  ok "no-root-layout: the SAME shape named <sha12> resolves — containment proves, it does not blanket-refuse"
else
  bad "no-root-layout: expected rc=0 for a <sha12>-named tree, got rc=$RC out=$OUT"
fi
git -C "$SRC" worktree remove --force "$NAMED" >/dev/null 2>&1 || true

printf '\nharness-exec.test: %d passed, %d failed, %d skipped (%s)\n' "$PASS" "$FAIL" "$SKIP" "$(uname -s)"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
