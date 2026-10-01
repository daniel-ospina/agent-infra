#!/usr/bin/env bash
# tests/record-review/run.sh — the LANE-DIMENSION carry in record-review.sh
#
# `record-review.sh`'s #2982 arm carries a verdict across a head move only when the
# RENDERED patch is byte-identical. A base move breaks that whenever main's landed
# commits OVERLAP the PR's files: the patch's "before" side becomes main's new
# content while the LANE's contribution is unchanged. Measured on three PRs, all
# with ZERO lane commits between the reviewed head and the live head:
#   #6072 (two base merges) record dead;  #6213 (one) ai-review-gate went
#   SUCCESS -> FAILURE 7s after the rail moved the head;  #4823 (one) a replacement
#   record had to be produced — a fresh review paid for work that did not change.
# Counter-example that fixes the boundary: #5421 also moved its head, but a real
# lint fix (cfe2bad0afaa) landed in between — the refusal was CORRECT, a fresh
# review was owed, was produced, and the PR MERGED.
#
# These fixtures reproduce those SHAPES hermetically (no network, no live PRs), and
# section 6 MUTATES the function to prove each clause is load-bearing: a suite that
# only proves the acceptance path would let a fail-open land green.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SRC="$ROOT/scripts/record-review.sh"

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); printf '   ✅ %s\n' "$*"; }
fail() { FAIL=$((FAIL+1)); printf '   ❌ %s\n' "$*"; }

[ -f "$SRC" ] || { echo "no record-review.sh at $SRC"; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
extract_fn() { # <src> <dest>
  awk '/^lane_dimension_carry\(\) \{/,/^\}$/' "$1" > "$2"
  grep -q 'lane_dimension_carry()' "$2" || return 1
}
extract_fn "$SRC" "$TMP/fn.sh" || { echo "could not extract lane_dimension_carry from $SRC"; exit 2; }

# A fake gh: the arm reads the PR's base commit (authoritative) and its base ref.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
for x in "$@"; do
  case "$x" in
    .base.sha) echo "${FIXTURE_BASE_SHA:-}"; exit 0 ;;
    .base.ref) echo "${FIXTURE_BASE_REF:-main}"; exit 0 ;;
  esac
done
exit 1
EOF
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
export REPO="fixture/repo" PR=1

# new_repo <name>: main + a pr branch with one lane commit + origin/main + base sha.
new_repo() {
  local d="$TMP/$1"
  rm -rf "$d"; mkdir -p "$d"; cd "$d" || return 1
  git init -q .; git config user.email t@t; git config user.name t
  printf 'base\n' > shared.txt; printf 'base\n' > other.txt
  git add -A; git commit -qm base; git branch -M main
  git checkout -qb pr
  printf 'lane work\n' > lane.txt; git add -A; git commit -qm "lane work"
  git update-ref refs/remotes/origin/main refs/heads/main
  echo "$d"
}

carry_verdict() { # <repo> <reviewed> <current> -> 0 carry / 1 refuse
  local d="$1" a="$2" b="$3"
  ( cd "$d" || exit 9
    export FIXTURE_BASE_SHA; FIXTURE_BASE_SHA="$(git rev-parse main)"
    source "$TMP/fn.sh"; PR=1
    if lane_dimension_carry "$a" "$b"; then echo 0; else echo 1; fi )
}

# advance_base <repo>: move main forward, publish it, and refresh the local ref
advance_base() {
  local d="$1"
  ( cd "$d" || exit 9
    git checkout -q main && printf 'main advances\n' > other.txt && git add -A && git commit -qm "main advances"
    git update-ref refs/remotes/origin/main refs/heads/main )
}

echo "── 1. a PURE base merge (no lane work): the reviewed artifact is unchanged → CARRY"
D="$(new_repo pure)"; cd "$D" || exit 2
REVIEWED="$(git rev-parse HEAD)"
advance_base "$D"
git checkout -q pr && git merge -q --no-edit main
CURRENT="$(git rev-parse HEAD)"
[ "$(git rev-list --no-merges "$REVIEWED..$CURRENT" --not refs/heads/main | wc -l | tr -d ' ')" = 0 ] \
  && pass "the fixture really has ZERO lane commits between the two heads" \
  || fail "fixture is wrong: lane commits are present in the pure case"
[ "$(carry_verdict "$D" "$REVIEWED" "$CURRENT")" = 0 ] \
  && pass "CARRY (0) — a base-only move no longer destroys the verdict (#6072/#6213/#4823)" \
  || fail "REFUSED a pure base merge — the defect is not fixed"

echo "── 2. a LANE commit in between: the reviewed diff really changed → REFUSE (#5421)"
D="$(new_repo lanework)"; cd "$D" || exit 2
REVIEWED="$(git rev-parse HEAD)"
advance_base "$D"
git checkout -q pr
printf 'a real fix\n' > fix.txt && git add -A && git commit -qm "fix(lint): a real lane commit"
git merge -q --no-edit main
CURRENT="$(git rev-parse HEAD)"
[ "$(carry_verdict "$D" "$REVIEWED" "$CURRENT")" = 1 ] \
  && pass "REFUSE (1) — lane work in between is not carried (the #5421 counter-example)" \
  || fail "CARRIED a head whose lane commits changed — FAIL-OPEN"

echo "── 3. a CONFLICT RESOLUTION inside the merge: (D) must catch what (C2) cannot"
D="$(new_repo conflict)"; cd "$D" || exit 2
printf 'pr version\n' > shared.txt; git add -A; git commit -qm "lane edits shared.txt"
REVIEWED="$(git rev-parse HEAD)"
( cd "$D" && git checkout -q main && printf 'main version\n' > shared.txt && git add -A && git commit -qm "main edits shared.txt" && git update-ref refs/remotes/origin/main refs/heads/main )
git checkout -q pr
git merge main >/dev/null 2>&1
printf 'resolved by hand\n' > shared.txt; git add -A; git commit -qm "Merge branch 'main' into pr"
CURRENT="$(git rev-parse HEAD)"
[ "$(git rev-list --no-merges "$REVIEWED..$CURRENT" --not refs/heads/main | wc -l | tr -d ' ')" = 0 ] \
  && pass "(C2) is satisfied (only the merge is in between), so only (D) can catch it" \
  || fail "fixture is wrong: the conflict case leaks a lane commit"
[ "$(carry_verdict "$D" "$REVIEWED" "$CURRENT")" = 1 ] \
  && pass "REFUSE (1) — a hand resolution is NOT carried" \
  || fail "CARRIED a conflict resolution the review never saw — FAIL-OPEN"

echo "── 4. a REWRITTEN head (rebased/amended) is a different artifact → REFUSE"
D="$(new_repo rewritten)"; cd "$D" || exit 2
REVIEWED="$(git rev-parse HEAD)"
git commit -q --amend -m "lane work (amended)"
CURRENT="$(git rev-parse HEAD)"
[ "$(carry_verdict "$D" "$REVIEWED" "$CURRENT")" = 1 ] \
  && pass "REFUSE (1) — the reviewed head is not an ancestor of the rewritten one" \
  || fail "CARRIED across a rewrite — FAIL-OPEN"

echo "── 5. THE P0 REGRESSION: a local ref that LIES about the base must not be trusted"
# The first cut asked `--not origin/<base>`, trusting the LOCAL remote-tracking ref.
# Pointing it at a branch containing an unreviewed file made (C) come out empty and
# the predicate CARRIED — verified against the first cut. The authoritative base is
# now `.base.sha` from the API, and the head's second parent must be reachable from
# it, so this must REFUSE.
D="$(new_repo liarentry)"; cd "$D" || exit 2
REVIEWED="$(git rev-parse HEAD)"
advance_base "$D"                      # the TRUE base, which the API reports
TRUE_BASE="$(git rev-parse main)"
git update-ref refs/heads/carrier "$REVIEWED"
git checkout -q carrier
printf 'UNREVIEWED\n' > pwn.txt; git add -A; git commit -qm "unreviewed content"
# the lie: point the local origin/main at the carrier branch
git update-ref refs/remotes/origin/main refs/heads/carrier
git checkout -q pr && git merge -q --no-edit --no-ff carrier
CURRENT="$(git rev-parse HEAD)"
# A FAST-FORWARD here would make CURRENT the carrier tip itself: no second parent,
# so BOTH the fixed and the reverted form would refuse at the `current^2` step and
# the mutation below would look "caught" for the wrong reason. --no-ff is required.
[ "$(git rev-parse --verify -q "$CURRENT^2" >/dev/null 2>&1 && echo yes)" = yes ] \
  && pass "the fixture really produced a MERGE commit (has a second parent)" \
  || fail "fixture is wrong: the lie fixture fast-forwarded, so the mutation is vacuous"
( cd "$D" && [ "$(git rev-parse refs/remotes/origin/main)" = "$(git rev-parse refs/heads/carrier)" ] ) \
  && pass "the fixture really has a LYING local origin/main (absent a fetch)" \
  || fail "fixture is wrong: the local ref is not diverged"
( cd "$D" && [ "$(git rev-parse "$TRUE_BASE")" != "$(git rev-parse refs/heads/carrier)" ] ) \
  && pass "true base and the lying ref differ" || fail "fixture is wrong"
[ "$(carry_verdict "$D" "$REVIEWED" "$CURRENT")" = 1 ] \
  && pass "REFUSE (1) — the unreviewed file is NOT carried; the API's base is authoritative (P0 fixed)" \
  || fail "CARRIED unreviewed content via a stale local ref — THE P0 FAIL-OPEN IS BACK"

LIE_REVIEWED="$REVIEWED"; LIE_CURRENT="$CURRENT"

echo "── 6. MUTATION COVERAGE: the base-authority clause must be load-bearing"
# A suite that only proves the ACCEPTANCE path lets a fail-open land green. The P0
# this suite exists to prevent was trusting a LOCAL ref as the base. The fix is TWO
# redundant clauses — the authoritative base in (C2) AND the head's-second-parent
# ancestry check — and measured, removing EITHER ONE ALONE still refuses, because the
# other catches it. That is defence-in-depth, so the mutation must revert BOTH to
# prove the pair is load-bearing. Written out explicitly rather than patched with a
# regex, so the mutation is legible and cannot silently fail to apply.
MUT="$TMP/mut-reverted.sh"
cat > "$MUT" <<'REVERTED'
# The FIRST CUT, reverted: trusts the LOCAL remote-tracking ref and has no
# second-parent ancestry check. This is the P0.
lane_dimension_carry() {
  local reviewed="$1" current="$2" p2="" merged="" ctree=""
  git cat-file -e "$reviewed^{commit}" 2>/dev/null || return 1
  git cat-file -e "$current^{commit}" 2>/dev/null || return 1
  git merge-base --is-ancestor "$reviewed" "$current" 2>/dev/null || return 1
  if [ -n "$(git rev-list --no-merges "$reviewed..$current" --not "origin/main" 2>/dev/null)" ]; then
    return 1
  fi
  p2="$(git rev-parse "$current^2" 2>/dev/null || true)"
  [ -n "$p2" ] || return 1
  merged="$(git merge-tree --write-tree "$reviewed" "$p2" 2>/dev/null | head -1 || true)"
  [ -n "$merged" ] || return 1
  ctree="$(git rev-parse "$current^{tree}" 2>/dev/null || true)"
  [ -n "$ctree" ] || return 1
  [ "$merged" = "$ctree" ] || return 1
  return 0
}
REVERTED
bash -n "$MUT" 2>/dev/null || fail "the reverted mutation does not parse — coverage is blind"
leaked=0
( cd "$TMP/liarentry" || exit 0
  export FIXTURE_BASE_SHA; FIXTURE_BASE_SHA="$(git rev-parse main)"
  source "$MUT"; PR=1
  lane_dimension_carry "$LIE_REVIEWED" "$LIE_CURRENT" && exit 7 || exit 0 ) || leaked=1
[ "$leaked" -eq 1 ] \
  && pass "mutation REVERTED is caught: with the LOCAL-ref form (and no second-parent check) the LYING-REF fixture CARRYs — so the authoritative-base pair IS the load-bearing fix" \
  || fail "mutation REVERTED NOT caught — the authoritative base pair is not what stops the P0 fail-open"

echo
if [ "$FAIL" -eq 0 ]; then echo "ALL PASSED ($PASS assertion(s))"; exit 0; fi
echo "FAILED: $FAIL of $((PASS+FAIL)) assertion(s)"; exit 1
