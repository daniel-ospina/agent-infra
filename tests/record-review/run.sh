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
# These fixtures reproduce those SHAPES hermetically (no network, no live PRs), so
# the arm is pinned by its behaviour and not by whatever the fleet happens to look
# like today.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SRC="$ROOT/scripts/record-review.sh"

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); printf '   ✅ %s\n' "$*"; }
fail() { FAIL=$((FAIL+1)); printf '   ❌ %s\n' "$*"; }

[ -f "$SRC" ] || { echo "no record-review.sh at $SRC"; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# Extract the function VERBATIM from the producer, so the test cannot drift from it.
awk '/^lane_dimension_carry\(\) \{/,/^\}$/' "$SRC" > "$TMP/fn.sh"
if ! grep -q 'lane_dimension_carry()' "$TMP/fn.sh"; then
  echo "could not extract lane_dimension_carry from $SRC"; exit 2
fi

# A fake gh: the arm reads only the PR's base branch.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
for x in "$@"; do [ "$x" = ".base.ref" ] && { echo "${BASE_REF:-main}"; exit 0; }; done
exit 1
EOF
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
export REPO="fixture/repo" PR=1

# ── fixture builder ───────────────────────────────────────────────────────
# new_repo: main with a base file, a pr branch with one lane commit, and
# refs/remotes/origin/main so the arm's `origin/<base>` resolution works.
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

# carry_verdict <repo> <reviewed> <current> -> echoes 0 (carry) or 1 (refuse)
carry_verdict() {
  local d="$1" a="$2" b="$3"
  ( cd "$d" && source "$TMP/fn.sh"; PR=1; if lane_dimension_carry "$a" "$b"; then echo 0; else echo 1; fi )
}

echo "── 1. a PURE base merge (no lane work): the reviewed artifact is unchanged → CARRY"
D="$(new_repo pure)"; cd "$D" || exit 2
REVIEWED="$(git rev-parse HEAD)"
git checkout -q main && printf 'main advances\n' > other.txt && git add -A && git commit -qm "main advances"
git update-ref refs/remotes/origin/main refs/heads/main
git checkout -q pr && git merge -q --no-edit main
CURRENT="$(git rev-parse HEAD)"
[ "$(git rev-list --no-merges "$REVIEWED..$CURRENT" --not refs/remotes/origin/main | wc -l | tr -d ' ')" = 0 ] \
  && pass "the fixture really has ZERO lane commits between the two heads" \
  || fail "fixture is wrong: lane commits are present in the pure case"
[ "$(carry_verdict "$D" "$REVIEWED" "$CURRENT")" = 0 ] \
  && pass "CARRY (0) — a base-only move no longer destroys the verdict (#6072/#6213/#4823)" \
  || fail "REFUSED a pure base merge — the defect is not fixed"

echo "── 2. a LANE commit in between: the reviewed diff really changed → REFUSE (#5421)"
D="$(new_repo lanework)"; cd "$D" || exit 2
REVIEWED="$(git rev-parse HEAD)"
git checkout -q main && printf 'main advances\n' > other.txt && git add -A && git commit -qm "main advances"
git update-ref refs/remotes/origin/main refs/heads/main
git checkout -q pr
printf 'a real fix\n' > fix.txt && git add -A && git commit -qm "fix(lint): a real lane commit"
git merge -q --no-edit main
CURRENT="$(git rev-parse HEAD)"
[ "$(carry_verdict "$D" "$REVIEWED" "$CURRENT")" = 1 ] \
  && pass "REFUSE (1) — lane work in between is not carried (the #5421 counter-example)" \
  || fail "CARRIED a head whose lane commits changed — FAIL-OPEN"

echo "── 3. a CONFLICT RESOLUTION inside the merge: clause (D) must catch what (C) cannot"
D="$(new_repo conflict)"; cd "$D" || exit 2
printf 'pr version\n' > shared.txt; git add -A; git commit -qm "lane edits shared.txt"
REVIEWED="$(git rev-parse HEAD)"
git checkout -q main && printf 'main version\n' > shared.txt && git add -A && git commit -qm "main edits shared.txt"
git update-ref refs/remotes/origin/main refs/heads/main
git checkout -q pr
git merge main >/dev/null 2>&1            # conflicts — resolve by hand
printf 'resolved by hand\n' > shared.txt; git add -A; git commit -qm "Merge branch 'main' into pr"
CURRENT="$(git rev-parse HEAD)"
[ "$(git rev-list --no-merges "$REVIEWED..$CURRENT" --not refs/remotes/origin/main | wc -l | tr -d ' ')" = 0 ] \
  && pass "clause (C) is satisfied (only the merge is in between), so only (D) can catch it" \
  || fail "fixture is wrong: the conflict case leaks a lane commit"
[ "$(carry_verdict "$D" "$REVIEWED" "$CURRENT")" = 1 ] \
  && pass "REFUSE (1) — a hand resolution is NOT carried; (D) compares trees, not patch text" \
  || fail "CARRIED a conflict resolution the review never saw — FAIL-OPEN"

echo "── 4. a REWRITTEN head (rebased/amended) is a different artifact → REFUSE"
D="$(new_repo rewritten)"; cd "$D" || exit 2
REVIEWED="$(git rev-parse HEAD)"
git commit -q --amend -m "lane work (amended)"
CURRENT="$(git rev-parse HEAD)"
git update-ref refs/remotes/origin/main refs/heads/main
[ "$(carry_verdict "$D" "$REVIEWED" "$CURRENT")" = 1 ] \
  && pass "REFUSE (1) — the reviewed head is not an ancestor of the rewritten one" \
  || fail "CARRIED across a rewrite — FAIL-OPEN"

echo "── 5. fail-closed on doubt: same sha, unknown sha, unreadable base"
[ "$(carry_verdict "$D" "$CURRENT" "$CURRENT")" = 1 ] && pass "same sha (no move) → REFUSE" || fail "carried on no move"
[ "$(carry_verdict "$D" deadbeefdeadbeefdeadbeefdeadbeefdeadbeef "$CURRENT")" = 1 ] \
  && pass "an object absent from the repo → REFUSE" || fail "carried on a missing object"
( cd "$D" && source "$TMP/fn.sh"; PR=1; BASE_REF=no-such-branch; export BASE_REF
  if lane_dimension_carry "$REVIEWED" "$CURRENT" 2>/dev/null; then exit 0; else exit 1; fi ) \
  && fail "carried with an unresolvable base branch" || pass "an unresolvable base branch → REFUSE"

echo
if [ "$FAIL" -eq 0 ]; then echo "ALL PASSED ($PASS assertion(s))"; exit 0; fi
echo "FAILED: $FAIL of $((PASS+FAIL)) assertion(s)"; exit 1
