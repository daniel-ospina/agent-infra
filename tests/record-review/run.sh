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
# section 6 MUTATES the function to prove the clauses it relies on are load-bearing —
# a suite that only proves the acceptance path would let a fail-open land green.
#
# SCOPE OF THAT CLAIM, measured (a reviewer removed EVERY production line and recorded
# which removals the suite caught, so this is enumerated rather than asserted):
#   - COVERED individually: the second-parent rev-parse, the merge-tree rc capture and
#     rc check, the `head -1` tree parse, the tree-equality check (§9), each half of the
#     base shape validation (§8a), the (C2) lane-commit check (§11), the base identity.
#   - DEFENCE-IN-DEPTH, NOT individually covered: the presence checks (A), the
#     forward-move check (B), the second-parent ancestry check, the base `cat-file`,
#     the rev-list rc check, the non-empty-tree/name checks, and the replace-blind
#     export. Removing any ONE of them still refuses, because another clause catches the
#     same case — for §8b specifically, (D) refuses that fixture even with the export
#     gone (measured), so §8b proves the graft is LIVE and that the function still
#     refuses, but it does NOT prove the export is what refuses. A reviewer caught the
#     commit message claiming otherwise. No end-to-end carry that the export ALONE
#     prevents could be constructed, so this is documented rather than asserted.
#   - The CALL SITE (`--force-stale` precedence in the #2982 arm) is NOT driven by this
#     suite; it extracts and calls the function directly. That guard is verified by
#     reading, and a test that runs the real script with --force-stale is a follow-up,
#     not a claim made here.
# An assertion-count floor at the tail exists because a whole section was once deleted
# in an unrelated commit and the suite still reported ALL PASSED.
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
if frm not in code:
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

echo
# AN EXACT PIN, NOT A FLOOR WITH SLACK. $PASS only has to be non-zero for the suite to
# be green, so a whole section can be deleted with no signal — a reviewer deleted one
# and the suite still reported ALL PASSED. A floor of 32 against 35 assertions was tried
# first and MEASURED insufficient: sections 2, 4, 10 and 11 (1–3 assertions each) could
# still be deleted quietly. Equality means ANY loss trips it, and so does ADDING an
# assertion — deliberate, so the number is kept in step on purpose rather than drifting.
MIN_ASSERTIONS=35
if [ "$FAIL" -eq 0 ] && [ "$PASS" -ne "$MIN_ASSERTIONS" ]; then
  echo "❌ $PASS assertion(s) ran but this suite declares $MIN_ASSERTIONS — a section was deleted or skipped, or an assertion was added without updating the pin"
  FAIL=$((FAIL+1))
fi
if [ "$FAIL" -eq 0 ]; then echo "ALL PASSED ($PASS assertion(s))"; exit 0; fi
echo "FAILED: $FAIL of $((PASS+FAIL)) assertion(s)"; exit 1
