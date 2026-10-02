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
# These fixtures reproduce those SHAPES hermetically (no network, no live PRs), and the
# mutation guards below assert that the clauses the work most depends on are load-bearing —
# a suite that only proves the acceptance path would let a fail-open land green.
#
# SCOPE OF THAT CLAIM, and why there is NO line-by-line list here. This header used to
# enumerate which clauses the suite catches individually and which are defence-in-depth.
# That enumeration was WRONG FIVE TIMES: a verifier or reviewer deleted the lines and
# caught it on every attempt (the p2 check, the argument check, `return 0`, the rev-list rc
# check listed as individually covered while being GREEN — and simultaneously listed as
# defence-in-depth, i.e. self-contradictory — and the primary `local` declaration named by
# nothing while being RED). A claim about which of our own guards works re-stales every time
# it is re-worded, so it is DELETED rather than re-worded a sixth time. The gate is the
# MEASUREMENT, and it is one command: delete each non-comment interior line of
# lane_dimension_carry in a scratch copy, run this suite, and the lines whose removal turns
# it RED are the individually-covered set. Two caveats that are NOT exhaustive lists but
# ARE named because reviewers found them: the `rev-list` rc check has NO fixture and no
# other clause covers its arm (a failed walk leaves `extra` empty and the next line passes),
# so it is kept as fail-closed defence and is KNOWN-UNCOVERED; and the function's final
# `return 0` is not "covered", it is redundant.
#   - The CALL SITE (`--force-stale` precedence in the #2982 arm) is NOT driven by this
#     suite; it extracts and calls the function directly. That guard is verified by
#     reading, and a test that runs the real script with --force-stale is a follow-up,
#     not a claim made here.
# An assertion-count PIN at the tail exists because a whole section was once deleted
# in an unrelated commit and the suite still reported ALL PASSED. It is a tripwire for
# section loss — it cannot guard its own deletion, and that limit is stated here rather
# than implied to be stronger.
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

# verdict_with <repo> <fnfile> <reviewed> <current> [base-value] — run ANY function file
# against a fixture, so a MUTATED copy can be compared with the real one on the same
# inputs. `mutate <perl-expr> <dest>` applies an edit that must parse and must actually
# change the file, so a mutation can never silently no-op and fake coverage.
verdict_with() {
  local d="$1" f="$2" a="$3" b="$4" v="${5:-}"
  ( cd "$d" || exit 9
    export FIXTURE_BASE_SHA; FIXTURE_BASE_SHA="${v:-$(git rev-parse main)}"
    source "$f"; PR=1
    if lane_dimension_carry "$a" "$b"; then echo 0; else echo 1; fi )
}
mutate() { # <literal-from> <literal-to> <dest> ; 0 only if applied, changed, parses
  python3 - "$TMP/fn.sh" "$1" "$2" "$3" <<'PY' || return 1
import sys
src, frm, to, dst = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
code = open(src).read()
i = code.find(frm)
if i < 0:
    sys.exit(1)
# A literal that matches only inside a COMMENT satisfies every other check and would be a
# semantic no-op reported as a successful mutation (a reviewer demonstrated this). Refuse
# when the first match sits on a comment line; the clauses mutated here are all code.
line = code[code.rfind('\n', 0, i) + 1:code.find('\n', i)]
if line.lstrip().startswith('#'):
    sys.exit(1)
# A TRAILING comment counts too: a reviewer showed that a literal occurring only after a
# ` #` was accepted as an applied mutation (the check above covers only line-leading ones).
hashpos = line.find(' #')
if hashpos >= 0 and (i - (code.rfind('\n', 0, i) + 1)) > hashpos:
    sys.exit(1)
open(dst, 'w').write(code.replace(frm, to, 1))
PY
  cmp -s "$3" "$TMP/fn.sh" && return 1
  bash -n "$3" 2>/dev/null || return 1
  return 0
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
# A reviewer made the base advance an EMPTY commit and this acceptance fixture stayed
# green — "zero lane commits" still held, so nothing was actually being accepted. Assert
# the base really moved CONTENT (the shape of the reported defect: #6072 two base merges).
[ -n "$(git diff-tree --no-commit-id --name-only -r "$(git rev-parse main)")" ] \
  && pass "(1) the base advance really carries CONTENT — the acceptance fixture's premise" \
  || fail "(1) fixture is wrong: the base advanced by an EMPTY commit, so nothing is being accepted"
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
# The premise is stated in the caption, so it is ENFORCED: a reviewer made this commit
# empty and the suite stayed green, meaning the caption's claim was untested.
[ -n "$(git diff --name-only "$REVIEWED" "$CURRENT^1")" ] \
  && pass "(2) the lane commit really CHANGED content — the caption's premise holds" \
  || fail "(2) fixture is wrong: the lane commit is empty, so the premise is unenforced"
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
[ "$(git show "$CURRENT:shared.txt")" = "resolved by hand" ] \
  && pass "PRECONDITION: the head really CARRIES the hand resolution (not git's conflict markers), so (D) refuses for that reason" \
  || fail "fixture is VACUOUS: the head does not carry the resolution — the refusal would come from conflict markers"
[ "$(carry_verdict "$D" "$REVIEWED" "$CURRENT")" = 1 ] \
  && pass "REFUSE (1) — a hand resolution is NOT carried" \
  || fail "CARRIED a conflict resolution the review never saw — FAIL-OPEN"

echo "── 4. a REWRITTEN head (rebased/amended) is a different artifact → REFUSE"
D="$(new_repo rewritten)"; cd "$D" || exit 2
REVIEWED="$(git rev-parse HEAD)"
git commit -q --amend -m "lane work (amended)"
CURRENT="$(git rev-parse HEAD)"
# A reviewer mutated this fixture's SETUP (a descendant commit instead of a rewrite) and
# the suite stayed green, so the assertion was not exercising a rewrite at all. Without
# these two the caption is a claim, not a test.
[ "$REVIEWED" != "$CURRENT" ] \
  && pass "(4) the amend really produced a DIFFERENT head" \
  || fail "(4) fixture is wrong: the head did not change, so this tests the same-sha check instead"
if git merge-base --is-ancestor "$REVIEWED" "$CURRENT" 2>/dev/null; then
  fail "(4) fixture is wrong: the new head DESCENDS from the reviewed one — it is not a rewrite"
else
  pass "(4) the new head is NOT a descendant of the reviewed one — it is genuinely a rewrite"
fi
[ "$(carry_verdict "$D" "$REVIEWED" "$CURRENT")" = 1 ] \
  && pass "REFUSE (1) — a rewritten head is refused (MEASURED: by the absent second parent, not by the ancestry clause — deleting (B) alone leaves the suite green, so this fixture does not decide (B))" \
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
# A reviewer emptied this fixture's hostile commit and the suite stayed green, so the pass
# text below ("the unreviewed file is NOT carried") was unenforced. Check the stake exists.
git ls-tree -r --name-only "$CURRENT" | grep -qx pwn.txt \
  && pass "(5) the head tree really CARRIES the unreviewed file — the refusal claim is enforced" \
  || fail "(5) fixture is wrong: the head tree does not carry pwn.txt, so the refusal says nothing"
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
# A suite that only proves the ACCEPTANCE path lets a fail-open land green. The P0 this
# suite exists to prevent was trusting a LOCAL ref as the base, and the fix has two parts:
# the authoritative base in (C2) and the head's-second-parent ancestry check. An earlier
# version of this comment called them "TWO redundant clauses" and said removing EITHER
# ALONE still refuses — a reviewer FALSIFIED that: the ancestry check is LOAD-BEARING on a
# head whose second parent is a hand-built merge of two base commits, which only that check
# refuses (§16). So this mutation reverts the LOCAL-REF spelling of (C2) TOGETHER WITH the
# ancestry check, and §16 covers the ancestry check on its own. Written out explicitly
# rather than patched with a regex, so the mutation is legible and cannot silently fail.
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

echo "── 7. (D)'s rc check must be load-bearing on its own: a CONFLICT whose tree EQUALS the head"
# The failure of section 3's fixture: it resolves the conflict BY HAND, so the automatic
# tree differs from the committed one and the TREE INEQUALITY catches it — the rc check
# is never exercised. A modify/delete conflict is different: `merge-tree --write-tree`
# exits 1, but the tree it prints keeps the modified side, which is exactly what the
# committed merge contains. So the trees MATCH and only rc can refuse. A reviewer found
# that deleting the rc check left the whole suite green — i.e. it could regress to the
# fail-open a previous review had just fixed, unnoticed. This fixture closes that.
D="$(new_repo moddel)"; cd "$D" || exit 2
printf 'pr version\n' > shared.txt; git add -A; git commit -qm "lane edits shared.txt"
REVIEWED="$(git rev-parse HEAD)"
( cd "$D" && git checkout -q main && git rm -q shared.txt && git commit -qm "main deletes shared.txt" \
    && git update-ref refs/remotes/origin/main refs/heads/main )
git checkout -q pr
git merge main >/dev/null 2>&1     # modify/delete conflict: expected, and left unresolved
printf 'pr version\n' > shared.txt; git add -A; git commit -qm "Merge branch 'main' into pr"
CURRENT="$(git rev-parse HEAD)"
P2="$(git rev-parse "$CURRENT^2")"
[ "$(git rev-list --no-merges "$REVIEWED..$CURRENT" --not refs/heads/main | wc -l | tr -d ' ')" = 0 ] \
  && pass "(C2) is satisfied (only the merge is in between), so only (D) can catch it" \
  || fail "fixture is wrong: the modify/delete case leaks a lane commit"
git merge-tree --write-tree "$REVIEWED" "$P2" > "$TMP/mt.out" 2>/dev/null; MT_RC=$?
MT_TREE="$(head -1 "$TMP/mt.out")"
CTREE="$(git rev-parse "$CURRENT^{tree}")"
[ "$MT_RC" -ne 0 ] && pass "merge-tree really reports a CONFLICT here (rc=$MT_RC)" \
  || fail "fixture is wrong: merge-tree did not conflict, so the rc check is not exercised"
[ "$MT_TREE" = "$CTREE" ] && pass "AND its conflicted tree EQUALS the committed head tree — so the tree inequality alone would CARRY, and only rc refuses" \
  || fail "fixture is wrong: the trees differ, so the tree inequality catches this and rc is still not covered"
[ "$(carry_verdict "$D" "$REVIEWED" "$CURRENT")" = 1 ] \
  && pass "REFUSE (1) — a modify/delete conflict resolution is NOT carried" \
  || fail "CARRIED a conflicted merge — FAIL-OPEN"

MD_REVIEWED="$REVIEWED"; MD_CURRENT="$CURRENT"
MUT2="$TMP/mut-norc.sh"
perl -0pe 's/\[ "\$mrc" -eq 0 \] \|\| return 1/:/' "$TMP/fn.sh" > "$MUT2"
if bash -n "$MUT2" 2>/dev/null && ! cmp -s "$MUT2" "$TMP/fn.sh"; then
  leaked=0
  ( cd "$TMP/moddel" || exit 0
    export FIXTURE_BASE_SHA; FIXTURE_BASE_SHA="$(git rev-parse main)"
    source "$MUT2"; PR=1
    lane_dimension_carry "$MD_REVIEWED" "$MD_CURRENT" && exit 7 || exit 0 ) || leaked=1
  [ "$leaked" -eq 1 ] \
    && pass "mutation NORC is caught: dropping the rc check CARRIES the conflicted merge, so rc IS load-bearing on its own" \
    || fail "mutation NORC NOT caught — the rc check is not what refuses the conflicted merge"
else
  fail "mutation NORC: could not apply it (reformatting the rc check?) — coverage is blind"
fi

echo "── 8. HARDENING: the base must be a SHA (not a name), and grafts must not rewrite the graph"
# (8a) A reviewer measured that any non-empty string resolving as a LOCAL revision was
# accepted as "the authoritative base" (`gh` returning the literal `branch` carried).
# A name is not an authority, so the shape check must refuse it.
base_verdict() { # <repo> <reviewed> <current> <fake-base-value> -> 0 carry / 1 refuse
  local d="$1" a="$2" b="$3" v="$4"
  ( cd "$d" || exit 9
    export FIXTURE_BASE_SHA; FIXTURE_BASE_SHA="$v"
    source "$TMP/fn.sh"; PR=1
    if lane_dimension_carry "$a" "$b"; then echo 0; else echo 1; fi )
}
D="$TMP/pure"
PURE_REVIEWED="$(cd "$D" && git rev-parse 'HEAD^1')"   # the pr tip before the base merge
PURE_CURRENT="$(cd "$D" && git rev-parse HEAD)"
PURE_BASE="$(cd "$D" && git rev-parse main)"
# The control matters: with the TRUE 40-hex sha this fixture CARRIES, so 8a is testing
# the SHAPE check and not some other clause refusing for an unrelated reason.
[ "$(base_verdict "$D" "$PURE_REVIEWED" "$PURE_CURRENT" "$PURE_BASE")" = 0 ] \
  && pass "(8a control) with the true 40-hex sha this fixture DOES carry, so 8a isolates the shape check" \
  || fail "(8a) control failed — the fixture does not reach the carry path, so 8a proves nothing"
# Each HALF of the validation must be covered on its own. A reviewer measured that each
# removal alone left the suite green, because the two probes masked each other: "main"
# (4 chars) is caught by the LENGTH check, and "deadbeef" (8 hex) fails only because no
# such object exists. So each probe below is a name that EXISTS as a local ref and fails
# exactly ONE half.
( cd "$D" && git branch "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz" "$PURE_BASE" ) \
  && ( cd "$D" && git branch deadbeef "$PURE_BASE" ) \
  && pass "(8a) fixture refs created: a 40-char NON-hex name and a short all-hex name" \
  || fail "(8a) could not create the isolating refs"
FORTYZ="zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"
[ "$(base_verdict "$D" "$PURE_REVIEWED" "$PURE_CURRENT" "$FORTYZ")" = 1 ] \
  && pass "(8a) a 40-char NON-hex base is refused — the SHAPE half is load-bearing" \
  || fail "(8a) a 40-char non-hex base was ACCEPTED — the shape half is absent"
[ "$(base_verdict "$D" "$PURE_REVIEWED" "$PURE_CURRENT" "deadbeef")" = 1 ] \
  && pass "(8a) a short all-hex base is refused — the LENGTH half is load-bearing" \
  || fail "(8a) a short all-hex base was ACCEPTED — the length half is absent"
for _half in shape length; do
  MH="$TMP/mut-$_half.sh"
  if [ "$_half" = shape ]; then
    mutate '  case "$base_sha" in *[!0-9a-f]*|"") return 1 ;; esac' '  :' "$MH" \
      || { fail "mutation SHAPE: could not apply it (reformatting the case clause?)"; continue; }
    probe="$FORTYZ"; label="SHAPE"
  else
    mutate '  [ "${#base_sha}" -eq 40 ] || return 1' '  :' "$MH" \
      || { fail "mutation LENGTH: could not apply it (reformatting the length test?)"; continue; }
    probe="deadbeef"; label="LENGTH"
  fi
  [ "$(verdict_with "$D" "$MH" "$PURE_REVIEWED" "$PURE_CURRENT" "$probe")" = 0 ] \
    && pass "mutation $label is caught: dropping it CARRIES its probe, so that half IS load-bearing" \
    || fail "mutation $label NOT caught — that half is not what refuses its probe"
done

# (8b) `refs/replace/*` rewrites what rev-list and rev-parse SEE. A reviewer grafted the
# base so the lane commit looked reachable from it, turning a REFUSE into a CARRY.
D="$(new_repo graft)"; cd "$D" || exit 2
REVIEWED="$(git rev-parse HEAD)"
advance_base "$D"
git checkout -q pr
printf 'a real fix\n' > fix.txt && git add -A && git commit -qm "fix(lint): a real lane commit"
LANE="$(git rev-parse HEAD)"
git merge -q --no-edit main
CURRENT="$(git rev-parse HEAD)"
TRUE_BASE="$(git rev-parse main)"
[ "$(carry_verdict "$D" "$REVIEWED" "$CURRENT")" = 1 ] \
  && pass "(8b control) without the graft this is REFUSED (lane work in between)" \
  || fail "(8b) control failed: the graft fixture is not refusing to begin with"
# the graft: replace the base commit with one that also has the LANE commit as a parent,
# so the lane commit becomes reachable from "the base" and (C2) empties.
GRAFT="$(git commit-tree "$(git rev-parse "$TRUE_BASE^{tree}")" -p "$TRUE_BASE" -p "$LANE" -m graft)"
git replace "$TRUE_BASE" "$GRAFT"
[ "$(git rev-list --no-merges "$REVIEWED..$CURRENT" --not "$TRUE_BASE" | wc -l | tr -d ' ')" = 0 ] \
  && pass "(8b) the graft really hides the lane commit from the walk (the vector is live)" \
  || fail "(8b) the graft did not take — this assertion would be vacuous"
[ "$(carry_verdict "$D" "$REVIEWED" "$CURRENT")" = 1 ] \
  && pass "(8b) WITH the graft installed the function still REFUSES (note: (D) also refuses this fixture, so this alone does not prove the export is the clause refusing)" \
  || fail "(8b) a local graft CARRIED lane work the review never saw — FAIL-OPEN"

echo "── 9. (D)'s TREE EQUALITY must be load-bearing on its own: rc=0 AND the tree differs"
# Sections 3 and 7 both assert REFUSE, but BOTH refuse via merge-tree's EXIT STATUS —
# `mrc != 0` short-circuits BEFORE the equality check. So the clause (D) exists for
# ("recompute the merge and compare TREES") was never exercised: a reviewer deleted it
# and the suite stayed 22/22 green, while it IS the only defence against a CLEAN merge
# whose commit was staged with extra unreviewed content.
D="$(new_repo cleanmerge)"; cd "$D" || exit 2
REVIEWED="$(git rev-parse HEAD)"
advance_base "$D"
git checkout -q pr
git merge -q --no-edit main                 # a CLEAN merge: no conflict at all
printf 'UNREVIEWED\n' > pwn.txt; git add pwn.txt
git commit -q --amend --no-edit            # the merge commit now carries extra content
CURRENT="$(git rev-parse HEAD)"
P2="$(git rev-parse "$CURRENT^2")"
git merge-tree --write-tree "$REVIEWED" "$P2" > "$TMP/mt9.out" 2>/dev/null; RC9=$?
TREE9="$(head -1 "$TMP/mt9.out")"
CTREE9="$(git rev-parse "$CURRENT^{tree}")"
[ "$RC9" -eq 0 ] \
  && pass "(9) merge-tree SUCCEEDS here (rc=0), so the rc check cannot be what refuses" \
  || fail "(9) fixture is wrong: merge-tree conflicted, so this does not isolate the equality check"
[ "$TREE9" != "$CTREE9" ] \
  && pass "(9) and its clean tree DIFFERS from the committed head tree — only the equality check refuses" \
  || fail "(9) fixture is wrong: the trees match, so the equality check is still not exercised"
[ "$(verdict_with "$D" "$TMP/fn.sh" "$REVIEWED" "$CURRENT")" = 1 ] \
  && pass "REFUSE (1) — a clean merge carrying extra unreviewed content is NOT carried" \
  || fail "CARRIED unreviewed content in a merge commit — FAIL-OPEN"
MUT9="$TMP/mut-noeq.sh"
if mutate '  [ "$merged" = "$ctree" ] || return 1' '  :' "$MUT9"; then
  [ "$(verdict_with "$D" "$MUT9" "$REVIEWED" "$CURRENT")" = 0 ] \
    && pass "mutation NOEQ is caught: dropping the tree equality CARRIES the extra content, so it IS load-bearing" \
    || fail "mutation NOEQ NOT caught — the equality check is not what refuses the extra content"
else
  fail "mutation NOEQ: could not apply it (reformatting the equality?) — coverage is blind"
fi

echo "── 10. FAIL-CLOSED ON DOUBT (these fixtures were dropped by an earlier commit)"
D="$(new_repo doubt)"; cd "$D" || exit 2
REVIEWED="$(git rev-parse HEAD)"
advance_base "$D"
git checkout -q pr && git merge -q --no-edit main
CURRENT="$(git rev-parse HEAD)"
[ "$(verdict_with "$D" "$TMP/fn.sh" "$CURRENT" "$CURRENT")" = 1 ] \
  && pass "same sha (no move) → REFUSE" || fail "a no-move pair was CARRIED"
[ "$(verdict_with "$D" "$TMP/fn.sh" "0000000000000000000000000000000000000000" "$CURRENT")" = 1 ] \
  && pass "an object absent from the repo → REFUSE" || fail "an absent object was CARRIED"
[ "$(verdict_with "$D" "$TMP/fn.sh" "$REVIEWED" "$CURRENT" "1111111111111111111111111111111111111111")" = 1 ] \
  && pass "an unresolvable base sha → REFUSE" || fail "an unresolvable base was CARRIED"

echo "── 11. (C2) must refuse a LANE commit that (D) would ACCEPT: an EMPTY lane commit"
# Section 2 is captioned as testing (C2)/#5421, but with (C2) deleted it still refuses —
# via (D)'s tree inequality, because the lane's file is absent from the recomputed
# merge. So (C2) had no effective test. An EMPTY lane commit isolates it: it changes no
# tree, so the clean merge EQUALS the head tree and (D) passes, leaving only (C2).
D="$(new_repo emptycommit)"; cd "$D" || exit 2
REVIEWED="$(git rev-parse HEAD)"
advance_base "$D"
git checkout -q pr
git commit -q --allow-empty -m "an empty lane commit"
git merge -q --no-edit main
CURRENT="$(git rev-parse HEAD)"
P2="$(git rev-parse "$CURRENT^2")"
TREE11="$(git merge-tree --write-tree "$REVIEWED" "$P2" 2>/dev/null | head -1)"
[ "$TREE11" = "$(git rev-parse "$CURRENT^{tree}")" ] \
  && pass "(11) (D) would ACCEPT this head, so only (C2) can refuse it" \
  || fail "(11) fixture is wrong: (D) refuses it, so (C2) is still not isolated"
[ "$(verdict_with "$D" "$TMP/fn.sh" "$REVIEWED" "$CURRENT")" = 1 ] \
  && pass "REFUSE (1) — a lane commit in between is refused by (C2) ALONE" \
  || fail "CARRIED a lane commit — FAIL-OPEN"
MUT11="$TMP/mut-noc2.sh"
if mutate '  [ -z "$extra" ] || return 1' '  :' "$MUT11"; then
  [ "$(verdict_with "$D" "$MUT11" "$REVIEWED" "$CURRENT")" = 0 ] \
    && pass "mutation NOC2 is caught: dropping (C2) CARRIES the empty lane commit, so (C2) IS load-bearing" \
    || fail "mutation NOC2 NOT caught — (C2) is not what refuses the lane commit"
else
  fail "mutation NOC2: could not apply it (reformatting (C2)?) — coverage is blind"
fi

echo "── 12. A HEAD graft: the replace-blind export is the SOLE defence and must be covered"
# §8b grafts the BASE, and (D) catches that. Grafting the CURRENT HEAD is a DIFFERENT
# vector: `git replace` changes what rev-parse and rev-list SEE, while the tree that
# merge-tree recomputes is unchanged — so a fake head whose tree IS merge-tree(reviewed,
# base) satisfies every other clause, and neither (D) nor the tree equality can catch it.
# Only GIT_NO_REPLACE_OBJECTS=1 does. An earlier commit of mine claimed "no end-to-end
# carry that the export ALONE prevents could be constructed"; a reviewer constructed
# exactly this, so that claim was FALSE. This fixture replaces it: without the export a
# signed verdict is minted for a revision carrying an unreviewed lane commit.
D="$(new_repo headgraft)"; cd "$D" || exit 2
REVIEWED="$(git rev-parse HEAD)"
advance_base "$D"
git checkout -q pr
printf 'UNREVIEWED LANE WORK\n' > pwn.txt; git add -A; git commit -qm "unreviewed lane work"
git merge -q --no-edit main
CURRENT="$(git rev-parse HEAD)"
BASE="$(git rev-parse main)"
# A reviewer emptied this fixture's hostile commit and the suite stayed green (§12/§13 same
# gap), so assert the stake before asserting the refusal.
git ls-tree -r --name-only "$CURRENT" | grep -qx pwn.txt \
  && pass "(12) the head tree really CARRIES the unreviewed file" \
  || fail "(12) fixture is wrong: the head does not carry pwn.txt, so the refusal says nothing"
[ "$(verdict_with "$D" "$TMP/fn.sh" "$REVIEWED" "$CURRENT")" = 1 ] \
  && pass "(12 control) without any graft this is REFUSED — the lane commit is seen" \
  || fail "(12) control failed: the fixture does not refuse to begin with"
MT12="$(git merge-tree --write-tree "$REVIEWED" "$BASE" | head -1)"
FAKE="$(git commit-tree "$MT12" -p "$REVIEWED" -p "$BASE" -m grafted)"
git replace "$CURRENT" "$FAKE"
[ "$(git rev-parse "$CURRENT^{tree}")" = "$MT12" ] \
  && pass "(12) the graft is LIVE: the replaced head's tree IS the recomputed merge tree, so the tree equality cannot catch it" \
  || fail "(12) the graft did not take — the fixture is vacuous"
[ "$(verdict_with "$D" "$TMP/fn.sh" "$REVIEWED" "$CURRENT")" = 1 ] \
  && pass "(12) WITH the export the grafted head is still REFUSED" \
  || fail "(12) a HEAD graft CARRIED unreviewed lane work — FAIL-OPEN"
M12="$TMP/mut-norepl.sh"
if mutate '  local -x GIT_NO_REPLACE_OBJECTS=1' '  :' "$M12"; then
  [ "$(verdict_with "$D" "$M12" "$REVIEWED" "$CURRENT")" = 0 ] \
    && pass "mutation NOREPL is caught: without the export the HEAD graft CARRIES unreviewed work, so the export IS load-bearing and is covered here" \
    || fail "mutation NOREPL NOT caught — the export is not what refuses the HEAD graft"
else
  fail "mutation NOREPL: could not apply it — coverage is blind"
fi

echo "── 13. The GRAFTS FILE is a DIFFERENT mechanism from replace refs: cover both"
# A reviewer built this and it is the reason the export line changed. A head whose tree
# carries an unreviewed file, with a `.git/info/grafts` line making the base reachable
# from the lane commit. Under GIT_NO_REPLACE_OBJECTS=1 ALONE the (C2) walk emptied and the
# verdict CARRIED — the grafts file is NOT covered by that variable. Reproduced
# independently before the fix: `GIT_GRAFT_FILE=/dev/null` is what disables it, so BOTH
# variables are now set. This fixture is the regression guard for that.
D="$(new_repo graftfile)"; cd "$D" || exit 2
REVIEWED="$(git rev-parse HEAD)"
advance_base "$D"
BASE="$(git rev-parse main)"
git checkout -q pr
printf 'UNREVIEWED\n' > pwn.txt; git add -A; git commit -qm "unreviewed lane work"
LANE="$(git rev-parse HEAD)"
# the head: its tree is LANE's (it carries pwn.txt), and its second parent IS LANE.
M13HEAD="$(git commit-tree "$(git rev-parse "$LANE^{tree}")" -p "$REVIEWED" -p "$LANE" -m head)"
git update-ref refs/heads/pr "$M13HEAD"
git checkout -q pr
git ls-tree -r --name-only "$M13HEAD" | grep -qx pwn.txt \
  && pass "(13) the head tree really CARRIES the unreviewed file" \
  || fail "(13) fixture is wrong: the head does not carry pwn.txt, so the refusal says nothing"
[ "$(verdict_with "$D" "$TMP/fn.sh" "$REVIEWED" "$M13HEAD")" = 1 ] \
  && pass "(13 control) without any graft this is REFUSED — the lane commit is seen" \
  || fail "(13) control failed: the fixture does not refuse to begin with"
printf '%s %s\n' "$BASE" "$LANE" > .git/info/grafts
if git merge-base --is-ancestor "$LANE" "$BASE" 2>/dev/null; then
  pass "(13) the grafts FILE is live: it makes the lane commit reachable from the base, emptying the (C2) walk"
else
  fail "(13) the grafts file did not take — the fixture is vacuous"
fi
[ "$(verdict_with "$D" "$TMP/fn.sh" "$REVIEWED" "$M13HEAD")" = 1 ] \
  && pass "(13) WITH GIT_GRAFT_FILE set the grafted head is still REFUSED" \
  || fail "(13) a grafts-file graft CARRIED unreviewed lane work — FAIL-OPEN"
M13="$TMP/mut-nograftfile.sh"
if mutate ' GIT_NO_REPLACE_OBJECTS=1 GIT_GRAFT_FILE=/dev/null' ' GIT_NO_REPLACE_OBJECTS=1' "$M13"; then
  [ "$(verdict_with "$D" "$M13" "$REVIEWED" "$M13HEAD")" = 0 ] \
    && pass "mutation NOGRAFTFILE is caught: with only the replace export the grafts-file vector CARRIES unreviewed work, so GIT_GRAFT_FILE IS load-bearing" \
    || fail "mutation NOGRAFTFILE NOT caught — the grafts-file export is not what refuses this"
else
  fail "mutation NOGRAFTFILE: could not apply it — coverage is blind"
fi

echo "── 14. A shell FUNCTION named gh must not nominate the base (what \`command gh\` is for)"
# The commit that added `command gh` HAD NO TEST: a reviewer deleted the `command ` and the
# suite stayed green, so the exact fail-open that commit fixed could be reintroduced by
# removing nine characters. This is that regression test. It uses a SIBLING unreviewed commit
# so that forging the base to it satisfies (C), empties (C2) and leaves (D) intact — a shim
# can emit 40 hex, so the shape check cannot stop it.
D="$(new_repo ghfunc)"; cd "$D" || exit 2
REVIEWED="$(git rev-parse HEAD)"
advance_base "$D"
# The unreviewed work goes on its OWN branch: committing it on main would make it the TRUE
# base and the fixture would then carry legitimately, proving nothing.
git checkout -qb unreviewed main
printf 'UNREVIEWED\n' > pwn.txt; git add -A; git commit -qm "unreviewed work beside the lane"
U="$(git rev-parse HEAD)"
git checkout -q pr
git merge -q --no-edit --no-ff "$U"
CURRENT="$(git rev-parse HEAD)"
git ls-tree -r --name-only "$CURRENT" | grep -qx pwn.txt \
  && pass "(14) the head tree really CARRIES the unreviewed file — the forging fixture is hostile" \
  || fail "(14) fixture is wrong: the head does not carry pwn.txt, so nothing is at stake"
[ "$(git rev-parse "$CURRENT^2")" = "$U" ] \
  && pass "(14) the unreviewed commit really IS the second parent — forging the base to it is coherent" \
  || fail "(14) fixture is wrong: the second parent is not the unreviewed commit"
ghforge_verdict() { # <fnfile> -> 0 carry / 1 refuse
  ( cd "$D" || exit 9
    export FIXTURE_BASE_SHA; FIXTURE_BASE_SHA="$(git rev-parse main)"
    gh() { case "$*" in *".base.sha"*) echo "$U"; return 0 ;; esac; return 1; }
    source "$1"; PR=1
    if lane_dimension_carry "$REVIEWED" "$CURRENT"; then echo 0; else echo 1; fi )
}
[ "$(ghforge_verdict "$TMP/fn.sh")" = 1 ] \
  && pass "(14) a shell FUNCTION named gh cannot nominate the base — the real gh is used, and it refuses" \
  || fail "(14) a shell FUNCTION named gh nominated the base and CARRIED unreviewed work — FAIL-OPEN"
M14="$TMP/mut-nocommand.sh"
if mutate 'command gh api' 'gh api' "$M14"; then
  [ "$(ghforge_verdict "$M14")" = 0 ] \
    && pass "mutation NOCOMMAND is caught: without \`command\` the forged base CARRIES unreviewed work, so \`command gh\` IS load-bearing" \
    || fail "mutation NOCOMMAND NOT caught — \`command gh\` is not what refuses the forged base"
else
  fail "mutation NOCOMMAND: could not apply it — coverage is blind"
fi

echo
# AN EXACT PIN (not a floor with slack). $PASS only has to be non-zero for the suite to be
# green, so a whole section can otherwise vanish with no signal. With MIN equal to the
# ACTUAL count, `-ne` and a `-lt` floor both catch any LOSS; `-ne` additionally catches an
# ADDED assertion, which is why it is used. A reviewer noted that nothing catches a silent
# revert of the comparison to `-lt`; that is stated rather than guarded, because the loss
# case — the one this exists for — survives either spelling. The numeric guard exists
# because a reviewer measured that an EMPTY MIN_ASSERTIONS silently disables the pin:
# `[ "$PASS" -ne "" ]` errors, the `&&` list is false, and the body is skipped.
echo "── 15. STATIC GUARD: no bare \`gh\` invocation may be reintroduced"
# A reviewer found the HEAD read still calling bare `gh`, which let an exported bash
# FUNCTION named gh make CURRENT_HEAD == SHA and skip the stale-sha guard, minting a signed
# `@ <stale> diff=<live>` pair. Every gh call now uses `command gh`. This is a TEXT check,
# not a behavioural one, and it is labelled as such — the alternative is an integration
# harness driving the whole script, which is far more machinery for the same property.
# What it prevents: the nine-character regression that reintroduces the vector in a file
# nobody re-reads.
# IT IS OCCURRENCE-BASED, NOT LINE-BASED, and that is a correction: the first version was a
# grep that a verifier MEASURED blind to an INDENTED `if gh api` (so the diff-fetch site
# could regress with the guard green) and that filtered whole LINES, suppressing a line
# holding both a bare and a `command gh` call. It was a false-PASS guard.
bare_gh_count() { # <file> -> number of gh INVOCATIONS not using `command `
  python3 - "$1" <<'PY'
import re, sys

src = open(sys.argv[1], encoding="utf-8", errors="replace").read()
# Join \-continuations first: a reviewer reintroduced the exact HEAD read as `gh \` +
# newline + `api`, and the `command` look-behind used to miss it.
src = src.replace("\\\n", " ")


def executable_text(s):
    """Blank every character the shell does NOT execute as a command word.

    WHOLE-FILE, not per-line. A reviewer measured the per-line version going blind on a
    MULTI-LINE string, and the earlier quote-blanking version blind to `"$(gh api ...)"`
    — which is the exact shape of the head read this guard exists to protect: deleting
    `command ` from that one line left the counter at 0. So `$( ... )` and backticks are
    KEPT, even inside double quotes, because they ARE executed.

    Also kept: a quoted token that is EXACTLY gh (`"gh" api q`, `'gh' api q`) — a shell
    FUNCTION intercepts a quoted command word, so that is a real invocation.

    Comments are cut, so prose ABOUT gh is not counted. CAVEAT, named rather than
    implied: a HEREDOC BODY is treated as code, so a bare `gh` line inside one would be
    counted though it is only data — a FALSE POSITIVE, i.e. loud and fail-closed. The
    file's own heredoc bodies contain no `gh`, and the counter is asserted to be 0."""
    out, i, n = [], 0, len(s)
    while i < n:
        c = s[i]
        if c == "#" and (i == 0 or s[i - 1] in " \t\n"):
            while i < n and s[i] != "\n":
                i += 1
            continue
        if c == "'":
            j = s.find("'", i + 1)
            if j == -1:
                j = n - 1
            out.append("'gh'" if s[i:j + 1] == "'gh'" else " " * (j + 1 - i))
            i = j + 1
            continue
        if c == '"':
            parts, k = ['"'], i + 1
            while k < n:
                if s[k] == "\\" and k + 1 < n:
                    parts.append("  ")
                    k += 2
                    continue
                if s[k] == '"':
                    break
                if s.startswith("$(", k):
                    k0, depth, k = k, 0, k + 2
                    while k < n:
                        if s[k] == "(":
                            depth += 1
                        elif s[k] == ")":
                            if depth == 0:
                                break
                            depth -= 1
                        k += 1
                    parts.append(s[k0:k + 1])
                    k += 1
                    continue
                if s[k] == "`":
                    k2 = s.find("`", k + 1)
                    if k2 == -1:
                        k2 = n - 1
                    parts.append(s[k:k2 + 1])
                    k = k2 + 1
                    continue
                parts.append(s[k] if s[k] == "$" else " ")
                k += 1
            out.append('"gh"' if s[i:k + 1] == '"gh"' else "".join(parts) + '"')
            i = k + 1
            continue
        out.append(c)
        i += 1
    return "".join(out)


# NO SUBCOMMAND ALLOWLIST: a function named gh intercepts `gh <anything>`, so
# restricting the pattern to api|repo|auth|run|pr|issue left every other subcommand
# uncounted — a re-introduction spelling `gh secret list` reported 0.
code = executable_text(src)
rx = re.compile(r'(?<![\w/-])["\']?gh["\']?(?=[\s$)])')
n = 0
for m in rx.finditer(code):
    line_start = code.rfind("\n", 0, m.start()) + 1
    if code[line_start:].lstrip().startswith("#"):
        continue
    before = code[:m.start()].rstrip()
    # `command` must itself start a WORD: a plain endswith("command") also accepts
    # `X=command gh api`, which IS a bare invocation and must be counted.
    if re.search(r"(^|[\s(|&;])command$", before):
        continue
    # `command -v gh` is a LOOKUP, not an invocation.
    if re.search(r"(^|[\s(|&;])command\s+-[vV]$", before):
        continue
    n += 1
print(n)
PY
}
# Self-test the guard's own mechanism, so it cannot silently stop detecting: an INDENTED
# bare `if gh api` must be counted (the case the grep missed) and `command gh` must not.
ST="$TMP/bare-gh-selftest.sh"
printf '  if gh api x\n    | command gh api y\nX=command gh api z\n' > "$ST"
printf '"gh" api q\n' >> "$ST"
printf 'gh \\\n    api r\n' >> "$ST"
# A `#` inside a STRING is not a comment, so this is a REAL bare gh; the old cut stripped
# from the `#` and never saw it. And a subcommand OUTSIDE the old allowlist must count.
printf 'X="a # b"; gh api q\n' >> "$ST"
printf '  gh secret list\n' >> "$ST"
# CONTROLS — these must NOT count. The reviewer measured that the previous self-test
# pinned a fixed number and therefore could not see the counter go blind OR go over-eager:
# quoted PROSE that names gh, and the `command -v gh` LOOKUP, are not invocations.
printf 'echo "gh missing"\n' >> "$ST"
printf 'command -v gh >/dev/null 2>&1\n' >> "$ST"
# The EXACT shape of the head read this guard protects, and the spelling the previous
# version was blind to: `$( )` inside double quotes IS executed. Must COUNT.
printf 'CURRENT_HEAD="$(gh api q)"\n' >> "$ST"
[ "$(bare_gh_count "$ST")" = 7 ] \
  && pass "(15 self-test) the counter catches all SEVEN bare-gh spellings, including a command substitution INSIDE double quotes (the head read's exact shape), and does not count the two controls" \
  || fail "(15 self-test) the counter is broken — it cannot detect an indented bare gh (the false-PASS the grep had)"
BARE_GH="$(bare_gh_count "$SRC")"
[ "$BARE_GH" = 0 ] \
  && pass "(15) every gh INVOCATION in record-review.sh uses \`command gh\` (occurrence-based count = 0)" \
  || fail "(15) $BARE_GH bare gh invocation(s) in record-review.sh — a shell function named gh can intercept them"

echo "── 16. The SECOND-PARENT ANCESTRY check is load-bearing on its own (NOT redundant)"
# §6's comment used to call this clause redundant with (C2) and say removing either alone
# still refuses. A reviewer FALSIFIED that: on a head whose second parent M is a HAND-BUILT
# merge of two base commits, (C2) is empty (M is a merge, dropped by --no-merges, and its
# parents are base commits) and (D) passes by construction — only the ancestry check
# refuses. M's tree carries an unreviewed file, so the stake is real.
D="$(new_repo c2ancestor)"; cd "$D" || exit 2
REVIEWED="$(git rev-parse HEAD)"
advance_base "$D"
B2="$(git rev-parse main)"
B1="$(git rev-parse main^)"
TI="$(mktemp)"; rm -f "$TI"
GIT_INDEX_FILE="$TI" git read-tree "$B2^{tree}"
BLOB="$(printf 'UNREVIEWED\n' | git hash-object -w --stdin)"
GIT_INDEX_FILE="$TI" git update-index --add --cacheinfo "100644,$BLOB,pwn.txt"
TREE_PWN="$(GIT_INDEX_FILE="$TI" git write-tree)"
rm -f "$TI"
M="$(git commit-tree "$TREE_PWN" -p "$B1" -p "$B2" -m 'hand-built merge of two base commits')"
MT="$(git merge-tree --write-tree "$REVIEWED" "$M" | head -1)"
CURRENT="$(git commit-tree "$MT" -p "$REVIEWED" -p "$M" -m head)"
git update-ref refs/heads/pr "$CURRENT"
git checkout -q pr
git ls-tree -r --name-only "$CURRENT" | grep -qx pwn.txt \
  && pass "(16) the head tree really CARRIES the unreviewed file" \
  || fail "(16) fixture is wrong: the head does not carry pwn.txt, so nothing is at stake"
[ "$(git rev-list --no-merges "$REVIEWED..$CURRENT" --not refs/heads/main | wc -l | tr -d ' ')" = 0 ] \
  && pass "(16) (C2) is EMPTY here, so it cannot be what refuses" \
  || fail "(16) fixture is wrong: (C2) is not empty, so the ancestry check is still not isolated"
[ "$(git rev-parse "$CURRENT^{tree}")" = "$MT" ] \
  && pass "(16) (D) passes by construction — the head tree IS the recomputed merge tree" \
  || fail "(16) fixture is wrong: (D) would refuse, so the ancestry check is not isolated"
[ "$(verdict_with "$D" "$TMP/fn.sh" "$REVIEWED" "$CURRENT")" = 1 ] \
  && pass "REFUSE (1) — only the second-parent ancestry check can refuse this head" \
  || fail "CARRIED a head whose second parent is not base-derived — FAIL-OPEN"
M16="$TMP/mut-noancestor.sh"
if mutate 'git merge-base --is-ancestor "$p2" "$base_sha" 2>/dev/null || return 1' ':' "$M16"; then
  [ "$(verdict_with "$D" "$M16" "$REVIEWED" "$CURRENT")" = 0 ] \
    && pass "mutation NOANCESTOR is caught: dropping the ancestry check CARRIES unreviewed content, so it IS load-bearing on its own" \
    || fail "mutation NOANCESTOR NOT caught — the ancestry check is not what refuses this head"
else
  fail "mutation NOANCESTOR: could not apply it — coverage is blind"
fi

echo "── 17. A UNION-MERGED head is TOLERATED (a RECORDED DECISION, pinned against a wrong 'fix')"
# (D) compares `merge-tree(reviewed, p2)` to the head's tree, and `git merge-tree` OBEYS
# .gitattributes — so the arm inherits the repo's DECLARED merge semantics. tortoise#5373
# deliberately sets `merge=union` on config/ci-surfaces.yml and config/surface-manifest.yml
# (44 of 130 open PRs conflicted; 25 on ci-surfaces.yml alone) and the SAME file REJECTS a
# custom driver. A cycle-10 reviewer found that a merge DRIVER can make merge-tree emit a blob
# present in NEITHER input, and proposed requiring every merged blob to be a verbatim copy of
# an input. MEASURED: that guard would REFUSE a legitimately union-merged head — break the
# carry on exactly the two append-only registries most lanes touch — so the "fix" would be
# worse than the vector. This section pins the tolerance: add the blob check and it reddens.
# The inventing case needs a write to git's LOCAL CONFIGURATION (.git/config,
# .git/info/attributes, or the user's GLOBAL config -- a config entry can SHADOW a built-in
# name), which is this script's OWN trust surface: a local writer can forge the review body it
# reads. The built-ins, AS BUILT IN, cannot invent a LINE. NOTE the attribute SOURCE, measured
# by a cycle-11 reviewer: `git merge-tree` reads .gitattributes from the WORKING TREE, not from
# the merged trees -- this fixture still passes with .gitattributes left UNTRACKED, which is why
# the wording here says working-tree, not "tracked". Both facts are recorded in the script.
D="$(new_repo c17union)"; cd "$D" || exit 2
printf 'f.txt merge=union\n' > .gitattributes
printf 'top\n  lane\n' > f.txt
git add -A; git commit -qm "union for f.txt, plus the lane's change"
REVIEWED="$(git rev-parse HEAD)"
# The base changes the SAME region — under a NORMAL merge this CONFLICTS.
( cd "$D" || exit 9
  git checkout -q main
  printf 'f.txt merge=union\n' > .gitattributes
  printf 'top\n  base\n' > f.txt
  git add -A; git commit -qm "base changes the same region"
  git update-ref refs/remotes/origin/main refs/heads/main )
git checkout -q pr
P2="$(git rev-parse main)"
MT="$(git merge-tree --write-tree "$REVIEWED" "$P2" 2>/dev/null)"; MTRC=$?
CURRENT="$(git commit-tree "$MT" -p "$REVIEWED" -p "$P2" -m head 2>/dev/null)"
git update-ref refs/heads/pr "$CURRENT"
git checkout -q pr
UB="$(git rev-parse "$MT:f.txt" 2>/dev/null)"
{ [ "$MTRC" = 0 ] && [ -n "$UB" ] && [ "$UB" != "$(git rev-parse "$REVIEWED:f.txt")" ] && [ "$UB" != "$(git rev-parse "$P2:f.txt")" ]; } \
  && pass "(17) PRECONDITION: merge-tree ran CLEAN and emitted a blob that is NEITHER input's — union really synthesised it" \
  || fail "(17) fixture is VACUOUS: no synthesis happened (rc=$MTRC), so union tolerance is not being tested"
[ "$(git rev-parse "$CURRENT^{tree}" 2>/dev/null)" = "$MT" ] \
  && pass "(17) (D) passes by construction — the head tree IS the union merge tree" \
  || fail "(17) fixture is wrong: (D) would refuse, so the tolerance is not isolated"
[ "$(git rev-list --no-merges "$REVIEWED..$CURRENT" --not refs/heads/main | wc -l | tr -d ' ')" = 0 ] \
  && pass "(17) (C2) is EMPTY — the head has no lane commits, so the arm's other clauses hold too" \
  || fail "(17) fixture is wrong: (C2) is not empty"
[ "$(verdict_with "$D" "$TMP/fn.sh" "$REVIEWED" "$CURRENT")" = 0 ] \
  && pass "CARRY (0) — a union-merged base move is carried, per tortoise#5373's declared semantics" \
  || fail "REFUSED a legitimately union-merged head — a blob-level purity check here would break the append-only registries"

MIN_ASSERTIONS=66
case "$MIN_ASSERTIONS" in
  ''|*[!0-9]*)
    echo "❌ MIN_ASSERTIONS is not a non-negative integer ('$MIN_ASSERTIONS') — the pin is deactivated, which is itself a failure"
    FAIL=$((FAIL+1)) ;;
  *)
    if [ "$FAIL" -eq 0 ] && [ "$PASS" -ne "$MIN_ASSERTIONS" ]; then
      echo "❌ $PASS assertion(s) ran but this suite declares $MIN_ASSERTIONS — a section was deleted or skipped, or an assertion was added without updating the pin"
      FAIL=$((FAIL+1))
    fi ;;
esac
if [ "$FAIL" -eq 0 ]; then echo "ALL PASSED ($PASS assertion(s))"; exit 0; fi
echo "FAILED: $FAIL of $((PASS+FAIL)) assertion(s)"; exit 1
