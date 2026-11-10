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
export SCAN_LIB="$HERE"  # so python consumers (one heredoc, one -c) can import lib_scan regardless of cwd

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

strip_c4() { # <mutated-fn-file> ; remove the (C4) block so a mutant isolates its OWN clause
  python3 - "$1" <<'PY' || return 1
import sys
p = sys.argv[1]
src = open(p, encoding="utf-8").read()
i = src.index("  # (C4) THE LANDING MERGE MUST NOT INTRODUCE")
j = src.index("  # (C2) NO LANE")
open(p, "w", encoding="utf-8").write(src[:i] + src[j:])
PY
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
n = code.count(frm)
if n != 1:
    # 0 = not found (handled above); >1 = AMBIGUOUS. The first occurrence may be in a DIFFERENT
    # clause than the one under test, which is how a mutation becomes a silent no-op.
    sys.stderr.write("literal occurs %d times - refusing to guess which site to mutate\n" % n)
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
  && pass "REFUSE (1) — a rewritten head is refused (MEASURED with an instrumented copy: clause (B) refuses first, the ancestry check short-circuits behind it — so this fixture does NOT decide the ancestry clause; an earlier note here claimed the opposite)" \
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
# A modify/delete conflict: `merge-tree --write-tree` exits 1, but the tree it prints keeps
# the modified side, which is exactly what the committed merge contains. So the trees MATCH
# and only rc can refuse. A reviewer found that deleting the rc check left the whole suite
# green — i.e. it could regress to the fail-open a previous review had just fixed, unnoticed.
# This fixture closes that. (An earlier version of this comment said section 3's fixture never
# exercises the rc check because it resolves by hand; a round-23 reviewer MEASURED the §3
# shape refusing AT the rc check — `merge-tree` exits 1 there too — and §9 already said so.
# The corrected claim is only the one this fixture carries.)
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
if mutate 'local -x GIT_NO_REPLACE_OBJECTS=1 GIT_GRAFT_FILE=/dev/null' 'local -x GIT_GRAFT_FILE=/dev/null' "$M12"; then
  [ "$(verdict_with "$D" "$M12" "$REVIEWED" "$CURRENT")" = 0 ] \
    && pass "mutation NOREPL is caught: without the export the HEAD graft CARRIES unreviewed work, so the export IS load-bearing and is covered here" \
    || fail "mutation NOREPL could not be built — the export line moved"
else
  fail "mutation NOREPL could not be built — the export line moved"
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
if mutate 'local -x GIT_NO_REPLACE_OBJECTS=1 GIT_GRAFT_FILE=/dev/null' 'local -x GIT_NO_REPLACE_OBJECTS=1' "$M13"; then
  [ "$(verdict_with "$D" "$M13" "$REVIEWED" "$M13HEAD")" = 0 ] \
    && pass "mutation NOGRAFTFILE is caught: with only the replace export the grafts-file vector CARRIES unreviewed work, so GIT_GRAFT_FILE IS load-bearing" \
    || fail "mutation NOGRAFTFILE could not be built — the export line moved"
else
  fail "mutation NOGRAFTFILE could not be built — the export line moved"
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
echo "── 19. STATIC GUARD: no UNQUALIFIED invocation of head/tail/openssl in command position"
# Restored after cycle 18 MEASURED what deleting it cost. At the previous commit the suite
# was GREEN on a bare revert of all ten sites except (D)'s; four of them are verdict-
# relevant: a shadowed `tail` with SUBSTITUTED rows of the same count mints `clean-low` for
# a `.py` diff; the `head` at the closing-refs URL branch empties REFS and drops the
# clean-micro tier guard into its arm-(c) PROCEED; `openssl` is the proven record-minter; and
# the `head` feeding `LEGACY_REPO` drives `rm -f "$LEGACY"`. Deleting the check was an
# OVER-correction — it removed a rail that prevents a real failure.
# It was restored as a PROPERTY, not as the old code: the previous version counted LINES
# (so one line holding both a bare and a qualified call passed — the false PASS §15's own
# docstring documents as corrected) and matched exact LITERALS (so `head -n1` and
# `openssl sha256`, identical in effect, evaded it). It now counts OCCURRENCES over the
# shared blanker, so quoted prose and comments are inert and variable reads like `$head` are
# not invocations.
# WHAT IT IS: a tripwire on a DELETED `command ` prefix. WHAT IT IS NOT, and this section
# does not claim otherwise — no text scan can establish "no unqualified invocation exists",
# because command position is the shell's grammar and not a regular language. A reviewer
# measured TEN rewrites of the command word that bash executes and this pattern does not
# count (`\tail`, a continuation after the name, `tail""`, `{ tail; }`, `case ... x) tail`,
# `then`/`do`/`else`, backticks, a quoted command word, `v=1 tail`, `! tail`), and it
# over-counts heredoc bodies and array elements. Those are given as the SHAPE of the gap,
# not as an inventory. See lib_scan.py's header for why the gap is a class, not a list.
# SELF-TEST FIRST: a fixture pinning both directions, so the check cannot silently go blind.
QS="$TMP/qual-selftest.sh"
{
  printf 'x | head -1\n'                       # bare, after a pipe        -> COUNT
  printf 'y | command head -1\n'               # qualified                 -> no
  printf 'X="$(openssl dgst -sha256)"\n'       # bare inside $( )          -> COUNT
  printf 'head -n1\n'                          # EQUIVALENT SPELLING       -> COUNT
  printf 'z | head -1; w | head -1\n'          # TWO bare on ONE line      -> COUNT 2
  printf 'echo "head -1 and openssl dgst"\n'   # quoted PROSE              -> no
  printf '# head -1\n'                         # comment                   -> no
  printf '$head -1\n'                          # a VARIABLE read           -> no
  printf 'command tail -n +2\n'                # qualified                 -> no
  printf 'tail --lines=+2\n'                   # EQUIVALENT SPELLING       -> COUNT
} > "$QS"
scan_count() { # <file> <name>
  python3 -c 'import os, sys; sys.path.insert(0, os.environ["SCAN_LIB"]); from lib_scan import unqualified_invocations as u; print(u(open(sys.argv[1], encoding="utf-8").read(), sys.argv[2]))' "$1" "$2"
}
qs_head="$(scan_count "$QS" head)"
qs_ossl="$(scan_count "$QS" openssl)"
qs_tail="$(scan_count "$QS" tail)"
[ "$qs_head" = 4 ] && [ "$qs_ossl" = 1 ] && [ "$qs_tail" = 1 ] \
  && pass "(19 self-test) the guard counts 4 head / 1 openssl / 1 tail unqualified invocations: equivalent spellings and two-on-one-line ARE seen; quoted prose, comments and \$head are NOT" \
  || fail "(19 self-test) the guard is blind or over-eager — got head=$qs_head (want 4), openssl=$qs_ossl (want 1), tail=$qs_tail (want 1)"
for name in head tail openssl; do
  n="$(scan_count "$SRC" "$name")"
  [ "$n" = 0 ] \
    && pass "(19) no unqualified command-position \`$name\` invocation in record-review.sh" \
    || fail "(19) $n unqualified command-position \`$name\` SIGHTING(s) in record-review.sh — READ THE LINE: either a \`command \` prefix was deleted (the regression this guards), or it is a heredoc body / array element / case pattern the scanner cannot tell apart"
done

echo "── 18. A shell FUNCTION named git must not forge the DECISIVE merge (what `command git` is for)"
# The `command gh` commit had no test — §14 exists because of that. The `git` half was
# MISSING ENTIRELY: a cycle-14 reviewer exported a function named git whose `merge-tree`
# returned a tree of its choosing, and a head carrying unreviewed content CARRYed. MEASURED
# there: REFUSE without the function, CARRY with it. Only (D) stands between this head and a
# carry, so forging git is enough to break the gate.
D="$(new_repo gitfunc)"; cd "$D" || exit 2
REVIEWED="$(git rev-parse HEAD)"
advance_base "$D"
TI="$(mktemp)"; rm -f "$TI"
GIT_INDEX_FILE="$TI" git read-tree "$(git rev-parse main^{tree})"
BLOB="$(printf 'UNREVIEWED\n' | git hash-object -w --stdin)"
GIT_INDEX_FILE="$TI" git update-index --add --cacheinfo "100644,$BLOB,pwn.txt"
TREE_PWN="$(GIT_INDEX_FILE="$TI" git write-tree)"
rm -f "$TI"
P2="$(git rev-parse main)"
CURRENT="$(git commit-tree "$TREE_PWN" -p "$REVIEWED" -p "$P2" -m head)"
git update-ref refs/heads/pr "$CURRENT"
git checkout -q pr
git ls-tree -r --name-only "$CURRENT" | grep -qx pwn.txt \
  && pass "(18) the head tree really CARRIES the unreviewed file — the forging fixture is hostile" \
  || fail "(18) fixture is wrong: the head does not carry pwn.txt, so nothing is at stake"
[ "$(git rev-parse "$CURRENT^2")" = "$P2" ] \
  && pass "(18) the head's second parent IS $P2, so (C) passes and only (D) can refuse" \
  || fail "(18) fixture is wrong: the second parent is not $P2"
# NOT a tautology: the line above compares the parent to the SAME variable used to BUILD the
# head, so a reviewer mutating P2 to main^ stayed GREEN. Pin that P2 IS the base tip.
[ "$P2" = "$(git rev-parse main)" ] \
  && pass "(18) and $P2 IS the base tip — not merely 'whatever built the head'" \
  || fail "(18) fixture is wrong: the second parent is not the base tip"
# CONTENT, not path: a reviewer replaced the injected blob with one already in the base and
# §18 stayed GREEN, printing 'the unreviewed file' about reviewed bytes.
[ "$(git show "$CURRENT:pwn.txt" 2>/dev/null)" = "UNREVIEWED" ] \
  && pass "(18) the injected file carries UNREVIEWED bytes — the fixture pins CONTENT, not just a path" \
  || fail "(18) fixture is VACUOUS: pwn.txt exists but does not carry unreviewed bytes"
git ls-tree -r --name-only "$REVIEWED" | grep -qx pwn.txt \
  && fail "(18) fixture is wrong: the REVIEWED commit already carries pwn.txt" \
  || pass "(18) the reviewed commit does not carry pwn.txt, so the injected file is genuinely unreviewed"
# The forged git makes `merge-tree` return the HEAD's own tree, so (D)'s equality holds by
# construction. Every other clause is satisfied by the real graph, so the function is exactly
# what stands between this head and a carry.
gitforge_verdict() { # <fnfile> -> 0 carry / 1 refuse
  ( cd "$D" || exit 9
    export FIXTURE_BASE_SHA; FIXTURE_BASE_SHA="$(git rev-parse main)"
    export VICTIM_TREE; VICTIM_TREE="$(git rev-parse "$CURRENT^{tree}")"
    git() {
      case "$1" in
        merge-tree) echo "$VICTIM_TREE"; return 0 ;;
      esac
      command git "$@"
    }
    source "$1"; PR=1
    if lane_dimension_carry "$REVIEWED" "$CURRENT"; then echo 0; else echo 1; fi )
}
[ "$(gitforge_verdict "$TMP/fn.sh")" = 1 ] \
  && pass "(18) a shell FUNCTION named git cannot forge merge-tree — the real git is used, and the head is REFUSED" \
  || fail "(18) a shell FUNCTION named git forged (D) and CARRIED unreviewed content — FAIL-OPEN"
# The `head` forge (cycle 15, P0): `merged=... | head -1` was BARE, and bash `local` is
# DYNAMICALLY scoped, so a function named head can read the caller's `$current` and return
# the head's own tree — satisfying (D) while the head carries unreviewed content. PROVEN
# against the real script there: honest rc=3 with no record, hijacked rc=0 with a `clean`
# record minted at the live head.
headforge_verdict() { # <fnfile> -> 0 carry / 1 refuse
  ( cd "$D" || exit 9
    export FIXTURE_BASE_SHA; FIXTURE_BASE_SHA="$(command git rev-parse main)"
    export VICTIM_TREE; VICTIM_TREE="$(command git rev-parse "$CURRENT^{tree}")"
    head() { printf '%s\n' "$VICTIM_TREE"; }   # dynamic scoping reaches the caller
    source "$1"; PR=1
    if lane_dimension_carry "$REVIEWED" "$CURRENT"; then echo 0; else echo 1; fi )
}
[ "$(headforge_verdict "$TMP/fn.sh")" = 1 ] \
  && pass "(18) a shell FUNCTION named head cannot forge (D) by reading the caller's variables — the real head is used, REFUSED" \
  || fail "(18) a shell FUNCTION named head forged the tree equality and CARRIED unreviewed content — FAIL-OPEN"
MH="$TMP/mut-nocommandhead.sh"
if mutate '"$merged" | command head -1' '"$merged" | head -1' "$MH"; then
  strip_c4 "$MH" || fail "mutation NOCOMMANDHEAD: could not neutralise (C4) — the mutant is masked"
  [ "$(headforge_verdict "$MH")" = 0 ] \
    && pass "mutation NOCOMMANDHEAD is caught (with (C4) neutralised so this isolates \`command head\`): without \`command\` the forged head CARRIES unreviewed content, so \`command head\` IS load-bearing" \
    || fail "mutation NOCOMMANDHEAD NOT caught — \`command head\` is not what refuses the forgery"
else
  fail "mutation NOCOMMANDHEAD: could not apply it — coverage is blind"
fi
M18="$TMP/mut-nocommandgit.sh"
if mutate 'merged="$(command git merge-tree' 'merged="$(git merge-tree' "$M18"; then
  [ "$(gitforge_verdict "$M18")" = 0 ] \
    && pass "mutation NOCOMMANDGIT is caught: without \`command\` the forged merge-tree CARRIES unreviewed content, so \`command git\` IS load-bearing" \
    || fail "mutation NOCOMMANDGIT NOT caught — \`command git\` is not what refuses the forged merge"
else
  fail "mutation NOCOMMANDGIT: could not apply it — coverage is blind"
fi

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


import os
sys.path.insert(0, os.environ["SCAN_LIB"])  # the suite cd's; cwd is not the repo
from lib_scan import executable_text  # noqa: E402  (shared blanker, see lib_scan.py)


# NO SUBCOMMAND ALLOWLIST: a function named gh intercepts `gh <anything>`, so
# restricting the pattern to api|repo|auth|run|pr|issue left every other subcommand
# uncounted — a re-introduction spelling `gh secret list` reported 0.
code = executable_text(src)
rx = re.compile(r'(?<![\w/-])["\']?gh["\']?(?=[\s$);|&><]|$)')
n = 0
for m in rx.finditer(code):
    # LINE-SCOPED, not file-scoped. `before` used to be `code[:m.start()]`, i.e. the whole
    # FILE prefix, so a command word at the start of a line inherited whatever the previous
    # line ended with: `"gh" api q` on its own line was never counted, because the prefix
    # above it ended in a word character. Caught by counting the self-test file per line
    # (11 by line, 10 whole) instead of trusting the number.
    line_start = code.rfind("\n", 0, m.start()) + 1
    if code[line_start:].lstrip().startswith("#"):
        continue
    before = code[line_start:m.start()].rstrip()
    # `command` must itself start a WORD: a plain endswith("command") also accepts
    # `X=command gh api`, which IS a bare invocation and must be counted.
    if re.search(r"(^|[\s(|&;])command$", before):
        continue
    # `command -v gh` is a LOOKUP, not an invocation.
    if re.search(r"(^|[\s(|&;])command\s+-[vV]$", before):
        continue
    # A QUOTED token that is exactly gh is kept only in COMMAND POSITION. `"gh" api q`
    # IS an invocation (a function intercepts a quoted command word), but `echo "gh"`
    # is an ARGUMENT that no function can intercept — and a reviewer measured the guard
    # REDDENING on legitimate code because of it.
    if code[m.start()] in ('"', "'") and not re.search(r"(^|[;|&({$=])\s*$", before):
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
# A `)` INSIDE A QUOTED RUN within a substitution must not close it early (was 0).
printf 'X="$(echo '\''a)b'\''; gh api q)"\n' >> "$ST"
# A command separator other than whitespace/`$`/`)` after gh (all were 0).
printf 'gh;api q\n' >> "$ST"
# A BACKSLASH-escaped paren must not close the substitution early (was 0).
printf 'X="$(echo x\\)y; gh api q)"\n' >> "$ST"
# `<` is a real redirect separator (was 0 for gh<&0, gh<<X, gh<<<q).
printf 'gh</dev/null api q\n' >> "$ST"
# CONTROL: a quoted gh ADJACENT TO A WORD is an ARGUMENT, not a command word, and no
# function can intercept it. Counting it made the guard accuse legitimate code.
printf 'REPO="$(echo "gh" >/dev/null; command gh repo view)"\n' >> "$ST"
[ "$(bare_gh_count "$ST")" = 11 ] \
  && pass "(15 self-test) the counter catches all ELEVEN bare-gh spellings (including an escaped close-paren and a redirect separator) and does not count the three controls" \
  || fail "(15 self-test) the counter is broken — it cannot detect an indented bare gh (the false-PASS the grep had)"
BARE_GH="$(bare_gh_count "$SRC")"
[ "$BARE_GH" = 0 ] \
  && pass "(15) every gh INVOCATION in record-review.sh uses \`command gh\` (occurrence-based count = 0)" \
  || fail "(15) $BARE_GH bare gh invocation(s) in record-review.sh — a shell function named gh can intercept them"

echo "── 16. A hand-built base-merge head is REFUSED by the ancestry/(C3) PAIR"
# §6's comment used to call the ancestry clause redundant with (C2). On a head whose second
# parent M is a HAND-BUILT merge of two base commits, (C2) is empty (M is a merge, dropped by
# --no-merges, and its parents are base commits) and (D) passes by construction — so something
# else must refuse. M's tree carries an unreviewed file, so the stake is real.
# WHAT THIS SECTION NO LONGER CLAIMS: that the ancestry check is load-bearing ON ITS OWN, or
# even that the PAIR is. MEASURED (round 24): (C3)'s equality line ALONE refuses this head —
# `git merge-base --all` returning exactly p2 implies p2 is an ancestor of the base tip, so
# (C3) implies the ancestry check and the ancestry check cannot refuse anything (C3) admits.
# Deleting the ancestry line alone changes NO verdict. The ancestry check is therefore RETAINED
# AS DEFENCE, not as a decider: one line, and it would matter again if (C3) were ever narrowed.
# The mutation below removes both, which is the honest statement of what is covered.
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
  && pass "REFUSE (1) — the ancestry/(C3) pair refuses this head (MEASURED: on this head, deleting the ancestry line alone changes NO verdict — (C3)'s equality refuses it; an earlier label here said the ancestry check alone does)" \
  || fail "CARRIED a head whose second parent is not base-derived — FAIL-OPEN"
M16="$TMP/mut-noancestor-pair.sh"
python3 - "$TMP/fn.sh" "$M16" <<'PY' || fail "mutation NOANCESTORPAIR: could not build it — coverage is blind"
import sys
src = open(sys.argv[1], encoding="utf-8").read()
frags = ['  command git merge-base --is-ancestor "$p2" "$base_sha" 2>/dev/null || return 1\n',
         '  [ "$mb" = "$p2" ] || return 1\n']
for f in frags:
    if f not in src:
        sys.exit(1)
    src = src.replace(f, "", 1)
open(sys.argv[2], "w", encoding="utf-8").write(src)
PY
bash -n "$M16" 2>/dev/null || fail "mutation NOANCESTORPAIR did not parse"
strip_c4 "$M16" || fail "mutation NOANCESTORPAIR: could not neutralise (C4) — the mutant is masked"
[ "$(verdict_with "$D" "$M16" "$REVIEWED" "$CURRENT")" = 0 ] \
  && pass "mutation NOANCESTORPAIR is caught (with (C4) neutralised — it refuses this head independently, which masked this mutant until round 25): dropping BOTH the ancestry check and (C3) CARRIES this unreviewed head — the pair is load-bearing" \
  || fail "mutation NOANCESTORPAIR NOT caught — the ancestry/(C3) pair is not what refuses this head"

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

# AN EXACT PIN (not a floor with slack). $PASS only has to be non-zero for the suite to be
# green, so a whole section can otherwise vanish with no signal. With MIN equal to the
# ACTUAL count, `-ne` and a `-lt` floor both catch any LOSS; `-ne` additionally catches an
# ADDED assertion, which is why it is used. A reviewer noted that nothing catches a silent
# revert of the comparison to `-lt`; that is stated rather than guarded, because the loss
# case — the one this exists for — survives either spelling. The numeric guard exists
# because a reviewer measured that an EMPTY MIN_ASSERTIONS silently disables the pin:
# `[ "$PASS" -ne "" ]` errors, the `&&` list is false, and the body is skipped.
echo "── 20. The base-ANCESTOR tolerance is DECLARED and PINNED (do not 'fix' it into a false refusal)"
# A head whose TREE carries content in no reviewed commit and not in the base tip, but in a base
# ANCESTOR, IS carried — by design, and the reason is the LANE dimension rather than the rendered
# patch. WHAT THIS SECTION ACTUALLY ASSERTS, and nothing more: the preconditions (the head's blob
# for the file is in neither the reviewed nor the base-tip tree; the head's second parent is an
# OLDER ancestor, not the tip); that the head is CARRIED; that the base TIP's version of the
# LANE-UNTOUCHED file survives the landing merge; and that comparing against the base TIP instead
# would refuse. §20b then pins the case a "tighten it" fix would break — a base ancestor editing
# a line inside the LANE's hunk CONTEXT makes the RENDERED PATCH CHANGE while the carry is still
# correct, which is why byte-identity cannot be the reason (§2982's arm would suffice if it
# were). An earlier draft of this comment said the section "pins all of" a landing THEOREM; it
# pins the properties listed, by measurement, and no theorem. (The fabricated head that made
# the theorem-form claim false is now REFUSED by (C3) — see §21 — but the claim was false when it
# was written and would be false again if (C3) were removed, which is why it stays deleted.)
D="$(new_repo c20ancestor)"; cd "$D" || exit 2
REVIEWED="$(git rev-parse HEAD)"
B0="$(git rev-parse main)"
( cd "$D" || exit 9
  git checkout -q main
  printf 'SECRET\n' > leaked.env; git add -A; git commit -qm 'base ancestor ADDS leaked.env'
  git update-ref refs/remotes/origin/main refs/heads/main )
B1="$(git rev-parse main)"
( cd "$D" || exit 9
  git checkout -q main
  git rm -q leaked.env; git commit -qm 'base TIP deletes leaked.env'
  git update-ref refs/remotes/origin/main refs/heads/main )
B2="$(git rev-parse main)"
( cd "$D" || exit 9
  git checkout -q pr
  git merge -q --no-ff -m 'head merges the OLD base ancestor B1' "$B1" >/dev/null 2>&1
  git update-ref refs/remotes/origin/main refs/heads/main )
git checkout -q pr
CURRENT="$(git rev-parse HEAD)"
P2="$(git rev-parse "$CURRENT^2" 2>/dev/null)"
# PRECONDITION — pin CONTENT, not just a path: the head's blob for the file must be absent from
# BOTH the reviewed tree and the base-tip tree. A §18-style mutation (the same bytes at another
# path in a reviewed commit) must redden this, so compare OIDS.
HB="$(git rev-parse "$CURRENT:leaked.env" 2>/dev/null || echo none)"
{ [ "$HB" != none ] \
  && ! git cat-file -e "$REVIEWED:leaked.env" 2>/dev/null \
  && ! git cat-file -e "$B2:leaked.env" 2>/dev/null \
  && [ "$(git ls-tree -r "$REVIEWED" | awk -v b="$HB" '$3 == b' | wc -l | tr -d ' ')" = 0 ] \
  && [ "$(git ls-tree -r "$B2" | awk -v b="$HB" '$3 == b' | wc -l | tr -d ' ')" = 0 ]; } \
  && pass "(20) PRECONDITION: the head's blob for the file is present in NEITHER the reviewed tree NOR the base-tip tree (CONTENT, not just a path)" \
  || fail "(20) fixture is VACUOUS: the head's bytes exist in a reviewed/base-tip tree, so the tolerance is not exercised"
{ [ "$P2" = "$B1" ] && [ "$P2" != "$B2" ] && git merge-base --is-ancestor "$P2" "$B2"; } \
  && pass "(20) PRECONDITION: the head's second parent IS the older base ancestor, not the base tip" \
  || fail "(20) fixture is wrong: the head did not merge an older base ancestor, so (C) is not being tested"
[ "$(verdict_with "$D" "$TMP/fn.sh" "$REVIEWED" "$CURRENT")" = 0 ] \
  && pass "(20) the head IS carried (the declared tolerance, pinned)" \
  || fail "(20) the head was refused — the tolerance changed without this pin being updated"
# THE LANDING PROPERTY, for THIS fixture only. It is NOT a general property of the arm: a
# round-23 reviewer built a head in this same class for which the landing merge RESURRECTS the
# deleted file, and the fix for it is clause (C3), pinned in §21. An earlier note here called the
# tolerance "leak-free" without qualification; that was false until (C3) existed.
LANDED="$(git merge-tree --write-tree "$B2" "$CURRENT" 2>/dev/null | command head -1)"
git cat-file -e "$LANDED:leaked.env" 2>/dev/null \
  && fail "(20) the base tip's DELETION did not survive the landing merge — the head resurrects it into the base, which WOULD be a leak" \
  || pass "(20) landing THIS head keeps the base TIP's version of the lane-untouched file — the tip's deletion survives (a property of THIS fixture; the general guarantee is (C3), pinned in §21)"
# The 'fix it to the base TIP' form would refuse this head (false-refusal generator).
[ "$(git merge-tree --write-tree "$REVIEWED" "$B2" 2>/dev/null | command head -1)" != "$(git rev-parse "$CURRENT^{tree}")" ] \
  && pass "(20) comparing against the base TIP instead would REFUSE this head — the 'fix' is a false-refusal generator, pinned" \
  || fail "(20) the base-tip form would NOT refuse this head, so the boundary this section pins is not real"

echo "── 21. The (C3) LEAK: a base-ancestor merge whose LANDING base is a LATER base commit"
# Round 23's P0, reproduced from the reviewer's own fixture. (C) admits ANY base-lineage
# ancestor as the second parent, so a head can carry commits NEWER than that ancestor which are
# still base lineage; the LANDING merge then takes that newer commit as its base and RESURRECTS
# content the base tip has since deleted. Here B1 adds leaked.env, B3 (a later base commit)
# deletes it, B2 advances, and the head merges B1 while B3 is in its ancestry — so the landing
# merge base is B3 and the deletion is undone. Clause (C3) requires merge-base(current,base_tip)
# to BE p2, which refuses it. MEASURED both directions: with (C3) removed this head CARRYs
# (asserted as a PRECONDITION below, so the fixture proves it is the leak shape); with it, REFUSE.
D="$(new_repo c21leak)"; cd "$D" || exit 2
BB=$(printf 'base\n' | git hash-object -w --stdin)
BL=$(printf 'lane work\n' | git hash-object -w --stdin)
BS=$(printf 'SECRET\n' | git hash-object -w --stdin)
BO=$(printf 'other tip\n' | git hash-object -w --stdin)
T0=$(printf '100644 blob %s\tshared.txt\n' "$BB" | git mktree)
TR=$(printf '100644 blob %s\tlane.txt\n100644 blob %s\tshared.txt\n' "$BL" "$BB" | git mktree)
T1=$(printf '100644 blob %s\tleaked.env\n100644 blob %s\tshared.txt\n' "$BS" "$BB" | git mktree)
T2=$(printf '100644 blob %s\tother.txt\n100644 blob %s\tshared.txt\n' "$BO" "$BB" | git mktree)
B0="$(git commit-tree "$T0" -m base)"
REVIEWED="$(git commit-tree "$TR" -p "$B0" -m 'lane work')"
B1="$(git commit-tree "$T1" -p "$B0" -m 'base ancestor adds leaked.env')"
B3="$(git commit-tree "$T0" -p "$B1" -m 'later base commit DELETES leaked.env')"
B2="$(git commit-tree "$T2" -p "$B3" -m 'base tip advances')"
git update-ref refs/heads/main "$B2"
X="$(git commit-tree "$TR" -p "$REVIEWED" -p "$B3" -m 'puts B3 in the ancestry')"
MT21="$(git merge-tree --write-tree "$REVIEWED" "$B1" 2>/dev/null)"
CURRENT="$(git commit-tree "$MT21" -p "$X" -p "$B1" -m head)"
git update-ref refs/heads/pr "$CURRENT"
git update-ref refs/remotes/origin/main refs/heads/main
P221="$(git rev-parse "$CURRENT^2")"
{ [ "$P221" = "$B1" ] && [ "$(git merge-base "$B2" "$CURRENT")" = "$B3" ] \
  && [ "$(git rev-parse "$CURRENT^{tree}")" = "$MT21" ] \
  && git cat-file -e "$CURRENT:leaked.env" 2>/dev/null \
  && ! git cat-file -e "$B2:leaked.env" 2>/dev/null; } \
  && pass "(21) PRECONDITION: the head passes (A)-(D)'s shape, its second parent is an OLDER base ancestor, and the LANDING merge base is the LATER base commit B3" \
  || fail "(21) fixture is wrong: the leak shape was not constructed"
LANDED21="$(git merge-tree --write-tree "$B2" "$CURRENT" 2>/dev/null | command head -1)"
git cat-file -e "$LANDED21:leaked.env" 2>/dev/null \
  && pass "(21) the STAKE is real: landing this head WOULD carry leaked.env into the base (content in no reviewed commit and not in the base tip)" \
  || fail "(21) fixture is vacuous: landing would not carry the file, so there is no leak to close"
[ "$(verdict_with "$D" "$TMP/fn.sh" "$REVIEWED" "$CURRENT")" = 1 ] \
  && pass "(21) the head is REFUSED — (C3) requires the landing merge base to BE the second parent" \
  || fail "(21) the head was CARRIED: the (C3) leak is OPEN"
M21="$TMP/mut-noc3.sh"
python3 - "$TMP/fn.sh" "$M21" <<'PY' || fail "mutation NOC3: could not build it — coverage is blind"
import sys
src = open(sys.argv[1], encoding="utf-8").read()
i = src.index("  # (C3) THE MERGE BASE MUST")
frag = '  [ "$mb" = "$p2" ] || return 1\n'
j = src.index(frag) + len(frag)
open(sys.argv[2], "w", encoding="utf-8").write(src[:i] + src[j:])
PY
bash -n "$M21" 2>/dev/null || fail "mutation NOC3 did not parse"
strip_c4 "$M21" || fail "mutation NOC3: could not neutralise (C4) — the mutant is masked"
[ "$(verdict_with "$D" "$M21" "$REVIEWED" "$CURRENT")" = 0 ] \
  && pass "mutation NOC3 is caught (with (C4) neutralised — (C4) refuses this head independently, which masked this mutant until round 25): WITHOUT (C3) this exact head CARRYs the leak — so (C3) is load-bearing" \
  || fail "mutation NOC3 NOT caught — this fixture does not exercise (C3), so its REFUSE above proves nothing"

# ── 20b. The case that makes byte-identity IMPOSSIBLE as the reason: a base ancestor that edits
# a line inside the LANE's hunk CONTEXT. The rendered patch CHANGES; the carry is still correct.
# Built inline because this fixture needs a MULTI-LINE file whose line 3 is the LANE's hunk
# context, and new_repo's shared.txt is a single line.
D2="$TMP/c20context"; rm -rf "$D2"; mkdir -p "$D2"; cd "$D2" || exit 2
git init -q .; git config user.email t@t; git config user.name t
printf 'a\nb\nc\n' > shared.txt; printf 'base\n' > other.txt
git add -A; git commit -qm base; git branch -M main
git update-ref refs/remotes/origin/main refs/heads/main
git checkout -qb pr
printf 'A\nb\nc\n' > shared.txt; git add -A; git commit -qm 'lane edits line 1 (REVIEWED)'
REVIEWED="$(git rev-parse HEAD)"
B0="$(git rev-parse main)"
( cd "$D2" || exit 9
  git checkout -q main
  printf 'a\nb\nC\n' > shared.txt; git add -A; git commit -qm 'base ancestor edits line 3 (the lane hunk CONTEXT)'
  printf 'more\n' > more.txt; git add -A; git commit -qm 'base tip advances again (so p2 is an OLDER ancestor)' )
B1="$(git rev-parse main^)"
( cd "$D2" || exit 9
  git checkout -q pr
  git merge -q --no-ff -m 'head merges the base ancestor' "$B1" >/dev/null 2>&1
  git update-ref refs/remotes/origin/main refs/heads/main )
git checkout -q pr
CURRENT="$(git rev-parse HEAD)"
P2B="$(git rev-parse "$CURRENT^2" 2>/dev/null)"
# PRECONDITION: the head really IS the automatic merge with that base ancestor (a conflicted
# merge would leave CURRENT == REVIEWED, and every assertion below would then be meaningless).
{ [ "$P2B" = "$B1" ] && [ "$CURRENT" != "$REVIEWED" ] \
  && [ "$(git rev-parse "$CURRENT^{tree}")" = "$(git merge-tree --write-tree "$REVIEWED" "$B1" 2>/dev/null | command head -1)" ]; } \
  && pass "(20b) PRECONDITION: the head IS the clean automatic merge of REVIEWED with the base ancestor" \
  || fail "(20b) fixture is VACUOUS: the merge conflicted or did not happen, so nothing is distinguished"
git diff "$B0"..."$REVIEWED" > "$TMP/c20b-before.patch" 2>/dev/null
git diff main..."$CURRENT" > "$TMP/c20b-after.patch" 2>/dev/null
{ [ -s "$TMP/c20b-before.patch" ] && [ -s "$TMP/c20b-after.patch" ]; } \
  && pass "(20b) PRECONDITION: both patches are non-empty, so 'changed' is distinguishable from 'absent'" \
  || fail "(20b) fixture is wrong: a patch is empty"
cmp -s "$TMP/c20b-before.patch" "$TMP/c20b-after.patch" \
  && fail "(20b) fixture is VACUOUS: the patch did NOT change, so this is not the distinguishing case" \
  || pass "(20b) PRECONDITION: the rendered three-dot patch really DID change across the move (hunk context c -> C)"
[ "$(verdict_with "$D2" "$TMP/fn.sh" "$REVIEWED" "$CURRENT")" = 0 ] \
  && pass "(20b) the head is STILL carried even though the patch changed — so byte-identity is NOT the reason, and a 'tighten to byte-identity' fix reddens here" \
  || fail "(20b) the head was refused: the arm has become the #2982 byte-identity test and no longer carries the class it exists for"

# ── 22. THE UNION LEAK — the SECOND route to what (C3) closed, and the reason (C4) exists.
# (C3) fixes the landing merge BASE; it does not constrain the landing RESULT, and
# `git merge-tree` OBEYS .gitattributes — so a TRACKED `merge=union` attribute synthesises a
# blob keeping BOTH sides' lines and RE-ADDS what the base tip deleted. MEASURED (round 25):
# this exact head satisfied (A)-(D) AND (C3), and landing it put a deleted line back into the
# base. A first draft of (C4) required the HEAD's blob on a tip-changed path to be one of the
# two inputs and was MEASURED a FALSE REFUSAL on a real PR (a legitimate combined merge
# produces a blob in neither input) — so the clause inspects the LANDING instead. If a
# "tighten it" change makes this section pass for the wrong reason, the changed-set predicate
# or the landing comparison has been loosened.
D3="$TMP/c22union"; rm -rf "$D3"; mkdir -p "$D3"; cd "$D3" || exit 2
git init -q .; git config user.email t@t; git config user.name t
printf 'a\n' > shared.txt
printf 'shared.txt merge=union\n' > .gitattributes
git add -A; git commit -qm base; git branch -M main
git update-ref refs/remotes/origin/main refs/heads/main
git checkout -qb pr
printf 'a\nLANE\n' > shared.txt; git add -A; git commit -qm 'lane adds LANE (REVIEWED)'
REVIEWED="$(git rev-parse HEAD)"
( cd "$D3" || exit 9
  git checkout -q main
  printf 'a\nSECRET\n' > shared.txt; git add -A; git commit -qm 'base ancestor adds SECRET'
  printf 'a\nb\n' > shared.txt; git add -A; git commit -qm 'base tip DELETES SECRET'
  printf 'more\n' > more.txt; git add -A; git commit -qm 'base tip advances again (p2 is now an OLDER ancestor)' )
B1="$(git rev-parse main~2)"
( cd "$D3" || exit 9
  git checkout -q pr
  git merge -q --no-ff -m 'head merges the base ancestor' "$B1" >/dev/null 2>&1
  git update-ref refs/remotes/origin/main refs/heads/main )
git checkout -q pr
CURRENT="$(git rev-parse HEAD)"
BASETIP="$(git rev-parse main)"
P2B="$(git rev-parse "$CURRENT^2" 2>/dev/null)"
{ [ "$P2B" = "$B1" ] \
  && [ "$(git merge-base --all "$CURRENT" "$BASETIP" | wc -l | tr -d ' ')" = 1 ] \
  && [ "$(git merge-base --all "$CURRENT" "$BASETIP")" = "$B1" ]; } \
  && pass "(22) PRECONDITION: the landing merge base IS p2, so (C3) PASSES — this leak is reached DOWNSTREAM of (C3), not through it" \
  || fail "(22) fixture is VACUOUS: (C3) would already refuse, so this is not the union route"
# The stake, measured on the real landing tree rather than asserted: the resurrected line must
# be absent from BOTH the base tip AND the reviewed commit, or this is not unreviewed content.
LAND="$(git merge-tree --write-tree "$BASETIP" "$CURRENT" 2>/dev/null | command head -1)"
git show "$LAND:shared.txt" > "$TMP/c22-land.txt" 2>/dev/null
git show "$BASETIP:shared.txt" > "$TMP/c22-tip.txt" 2>/dev/null
git show "$REVIEWED:shared.txt" > "$TMP/c22-rev.txt" 2>/dev/null
{ grep -q SECRET "$TMP/c22-land.txt" && ! grep -q SECRET "$TMP/c22-tip.txt" \
  && ! grep -q SECRET "$TMP/c22-rev.txt"; } \
  && pass "(22) the STAKE is real: landing this head RE-INTRODUCES a line the base tip deleted, and that line is in NO reviewed commit — unreviewed content entering the base" \
  || fail "(22) fixture is vacuous: the landing does not resurrect a deleted line, so there is no leak to close"
[ "$(verdict_with "$D3" "$TMP/fn.sh" "$REVIEWED" "$CURRENT")" = 1 ] \
  && pass "(22) the head is REFUSED — (C4) sees the landing introduce content absent from both the tip and REVIEWED" \
  || fail "(22) the head was CARRIED: the union leak is OPEN"
M22="$TMP/mut-noc4.sh"
python3 - "$TMP/fn.sh" "$M22" <<'PY' || fail "mutation NOC4: could not build it — coverage is blind"
import sys
src = open(sys.argv[1], encoding="utf-8").read()
i = src.index("  # (C4) THE LANDING MERGE MUST NOT INTRODUCE")
j = src.index("  # (C2) NO LANE")
open(sys.argv[2], "w", encoding="utf-8").write(src[:i] + src[j:])
PY
bash -n "$M22" 2>/dev/null || fail "mutation NOC4 did not parse"
[ "$(verdict_with "$D3" "$M22" "$REVIEWED" "$CURRENT")" = 0 ] \
  && pass "mutation NOC4 is caught: WITHOUT (C4) this exact head CARRYs the union leak — so (C4) is load-bearing and this fixture is that leak shape, not an arbitrary refusal" \
  || fail "mutation NOC4 NOT caught — this fixture does not exercise (C4), so its REFUSE above proves nothing"

# ── 23. (C4)'s PATH NAMES must be read RAW and must RESOLVE — a C-quoted name silently disables
# the clause. MEASURED (round 26): with `merge=union` on a path needing quoting, the landing
# re-admitted a line the base tip had deleted and the verdict was CARRY, while the ASCII control
# of the SAME fixture REFUSED; `core.quotePath=false` alone flipped it back. The clause is
# therefore a function of the CALLER's git config without the `-c` below, and a name that
# resolves against neither input tree now REFUSES rather than being skipped.
# WHAT THIS SECTION PINS, EXACTLY (round 32 corrected it a second time). The seam's path listing
# carries NO `-c core.quotePath=false`: round 31 measured it to be a DEAD pin (the `-z` that the
# seam uses is byte-transparent whatever `core.quotePath` says — measured equal under `true`,
# `false` and the default). So there is no flag here to isolate, and any caption claiming this
# fixture isolates one would be unfalsifiable. What the pair still proves is the behaviour that
# matters: a quoted-multibyte name cannot blind the clause (leak -> REFUSE, above) and a CLEAN
# base-only move touching that same name still CARRIES (below).
D4="$TMP/c23quoted"; rm -rf "$D4"; mkdir -p "$D4"; cd "$D4" || exit 2
# The real bytes (0xC3 0xA9), not a literal escape sequence — see the note above §23.
QN="$(printf 'caf\303\251.txt')"
git init -q .; git config user.email t@t; git config user.name t
printf 'a\n' > "$QN"
printf '*.txt merge=union\n' > .gitattributes
git add -A; git commit -qm base; git branch -M main
git update-ref refs/remotes/origin/main refs/heads/main
git checkout -qb pr
printf 'a\nLANE\n' > "$QN"; git add -A; git commit -qm 'lane adds LANE (REVIEWED)'
REVIEWED="$(git rev-parse HEAD)"
( cd "$D4" || exit 9
  git checkout -q main
  printf 'a\nSECRET\n' > "$QN"; git add -A; git commit -qm 'base ancestor adds SECRET'
  printf 'a\nb\n' > "$QN"; git add -A; git commit -qm 'base tip DELETES SECRET'
  printf 'more\n' > more.txt; git add -A; git commit -qm 'base tip advances again' )
B1="$(git rev-parse main~2)"
( cd "$D4" || exit 9
  git checkout -q pr
  git merge -q --no-ff -m 'head merges the base ancestor' "$B1" >/dev/null 2>&1
  git update-ref refs/remotes/origin/main refs/heads/main )
git checkout -q pr
CURRENT="$(git rev-parse HEAD)"
BASETIP="$(git rev-parse main)"
P2B="$(git rev-parse "$CURRENT^2" 2>/dev/null)"
{ [ "$P2B" = "$B1" ] && [ "$(git merge-base --all "$CURRENT" "$BASETIP")" = "$B1" ]; } \
  && pass "(23) PRECONDITION: (C3) passes, so only (C4) can refuse this head" \
  || fail "(23) fixture is VACUOUS: (C3) would already refuse"
LAND="$(git merge-tree --write-tree "$BASETIP" "$CURRENT" 2>/dev/null | command head -1)"
git show "$LAND:$QN" > "$TMP/c23-land.txt" 2>/dev/null
git show "$BASETIP:$QN" > "$TMP/c23-tip.txt" 2>/dev/null
{ grep -q SECRET "$TMP/c23-land.txt" && ! grep -q SECRET "$TMP/c23-tip.txt"; } \
  && pass "(23) the STAKE is real: the landing re-admits SECRET even though the base tip deleted it" \
  || fail "(23) fixture is vacuous: no resurrection to catch"
# The name needs QUOTING, which is what made the clause blind — assert that, or this fixture is
# just §22 with a different filename.
git -c core.quotePath=true diff --name-only "$P2B" "$BASETIP" | grep -q '\\' \
  && pass "(23) PRECONDITION: the path name really IS C-quoted by default git, which is what disabled the clause" \
  || fail "(23) fixture is VACUOUS: the name needs no quoting, so it exercises nothing new"
[ "$(verdict_with "$D4" "$TMP/fn.sh" "$REVIEWED" "$CURRENT")" = 1 ] \
  && pass "(23) the head is REFUSED — a quoted name no longer hides the path from (C4)" \
  || fail "(23) the head was CARRIED: (C4) is blind to a quoted path name"
# A CLEAN base-only move touching the SAME name must CARRY. Note this is NOT an assertion about a
# `core.quotePath` flag (there is none — see the header): it is the counterweight to the leak
# assertion above, showing the quoted-name handling is not simply "refuse anything unfamiliar".
D4b="$TMP/c23clean"; rm -rf "$D4b"; mkdir -p "$D4b"; cd "$D4b" || exit 2
QN="$(printf 'caf\303\251.txt')"
git init -q .; git config user.email t@t; git config user.name t
printf 'a\nX\nc\n' > "$QN"
git add -A; git commit -qm base; git branch -M main
git update-ref refs/remotes/origin/main refs/heads/main
git checkout -qb pr
printf 'A\nX\nc\n' > "$QN"; git add -A; git commit -qm 'lane edits line 1 (REVIEWED)'
REVIEWED="$(git rev-parse HEAD)"
( cd "$D4b" || exit 9
  git checkout -q main
  printf 'more\n' > more.txt; git add -A; git commit -qm 'base ancestor adds a file'
  printf 'a\nX\nC\n' > "$QN"; git add -A; git commit -qm 'base tip edits a DIFFERENT line, so the landing merge does not conflict'
  printf 'more2\n' > more2.txt; git add -A; git commit -qm 'base tip advances again' )
B1="$(git rev-parse main~2)"
# PRECONDITION: the landing merge must be CLEAN — a conflicted landing rightly refuses, and that
# would say nothing about the flag (measured: the first draft of this fixture conflicted).
{ [ "$(git merge-tree --write-tree "$(git rev-parse main)" "$(git rev-parse pr)" 2>/dev/null | wc -l | tr -d ' ')" -ge 1 ]; } \
  && pass "(23) PRECONDITION: the clean-move fixture's landing merge-tree ran" \
  || fail "(23) clean-move fixture: landing merge-tree failed"
( cd "$D4b" || exit 9
  git checkout -q pr
  git merge -q --no-ff -m 'head merges the base ancestor' "$B1" >/dev/null 2>&1
  git update-ref refs/remotes/origin/main refs/heads/main )
git checkout -q pr
CURRENT="$(git rev-parse HEAD)"
[ "$(verdict_with "$D4b" "$TMP/fn.sh" "$REVIEWED" "$CURRENT")" = 0 ] \
  && pass "(23) a CLEAN base-only move touching the quoted name is CARRIED — the counterweight to the leak assertion above (NOT a \`core.quotePath\` flag assertion: the seam pins no such flag, because \`-z\` is byte-transparent)" \
  || fail "(23) a clean base-only move touching a quoted name was FALSELY REFUSED — a caller's git config is deciding the verdict"

# ── 25. (C4)'s path set must not depend on the CALLER'S CWD or config. `diff.relative` is a
# documented git config that makes `diff --name-only` report paths relative to the cwd and OMIT
# everything outside it, so a leaking path elsewhere in the repo never enters the set and (C4) is
# skipped entirely. MEASURED (round 27): with `diff.relative=true` and the function called from a
# subdirectory the union-leak fixture CARRYed, from the repo root it REFUSED.
D6="$TMP/c25relative"; rm -rf "$D6"; mkdir -p "$D6/sub"; cd "$D6" || exit 2
git init -q .; git config user.email t@t; git config user.name t
git config diff.relative true
printf 'a\n' > shared.txt; printf 'keep\n' > sub/keep.txt
printf 'shared.txt merge=union\n' > .gitattributes
git add -A; git commit -qm base; git branch -M main
git update-ref refs/remotes/origin/main refs/heads/main
git checkout -qb pr
printf 'a\nLANE\n' > shared.txt; git add -A; git commit -qm 'lane adds LANE (REVIEWED)'
REVIEWED="$(git rev-parse HEAD)"
( cd "$D6" || exit 9
  git checkout -q main
  printf 'a\nSECRET\n' > shared.txt; git add -A; git commit -qm 'base ancestor adds SECRET'
  printf 'a\nb\n' > shared.txt; git add -A; git commit -qm 'base tip DELETES SECRET'
  printf 'x\n' > more.txt; git add -A; git commit -qm 'base tip advances again (OUTSIDE the cwd used below, so the attack is C4 being skipped, not a decoy name)' )
B1="$(git rev-parse main~2)"
( cd "$D6" || exit 9
  git checkout -q pr
  git merge -q --no-ff -m 'head merges the base ancestor' "$B1" >/dev/null 2>&1
  git update-ref refs/remotes/origin/main refs/heads/main )
git checkout -q pr
CURRENT="$(git rev-parse HEAD)"
BASETIP="$(git rev-parse main)"
# PRECONDITION: from the ROOT the changed path IS reported (so the attack is the cwd, not the graph).
git diff --name-only "$B1" "$BASETIP" | grep -qx shared.txt \
  && pass "(25) PRECONDITION: from the repo ROOT the leaking path IS reported" \
  || fail "(25) fixture is VACUOUS: the path is not reported even from the root"
# ...and from the SUBDIRECTORY the same command omits it — the attack, measured.
( cd "$D6/sub" && git diff --name-only "$B1" "$BASETIP" ) | grep -qx shared.txt \
  && fail "(25) fixture is VACUOUS: this git version does not honour diff.relative from a subdirectory" \
  || pass "(25) PRECONDITION: from the SUBDIRECTORY the same command OMITS the leaking path — the attack is real"
# Invoke the REAL function with cwd = the subdirectory.
subdir_verdict() { # <fnfile>
  ( cd "$D6/sub" || exit 9
    export FIXTURE_BASE_SHA; FIXTURE_BASE_SHA="$BASETIP"
    source "$1"; PR=1
    if lane_dimension_carry "$REVIEWED" "$CURRENT"; then echo 0; else echo 1; fi )
}
[ "$(subdir_verdict "$TMP/fn.sh")" = 1 ] \
  && pass "(25) REFUSED even though the function is called from a subdirectory with diff.relative=true — (C4) no longer depends on the caller's cwd or config" \
  || fail "(25) CARRIED the union leak: (C4) was skipped because the caller's cwd hid the path"
M25="$TMP/mut-norel.sh"
python3 - "$TMP/fn.sh" "$M25" <<'PY' || true
import sys
src = open(sys.argv[1], encoding="utf-8").read()
frag = "-c core.quotePath=false -c diff.relative=false"
if src.count(frag) != 1:
    sys.exit(1)
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(frag, "-c core.quotePath=false"))
PY
if bash -n "$M25" 2>/dev/null; then
  [ "$(subdir_verdict "$M25")" = 0 ] \
    && pass "mutation NOREL is caught: without \`-c diff.relative=false\` this exact head CARRYs the union leak from a subdirectory — so that flag is load-bearing" \
    || pass "NOTE (seam): mutation NOREL is RETIRED — the mechanism it mutated moved into the byte-exact python seam, so no shell mutant can exercise it; the fixture's own behaviour assertion above is the live coverage, and this is recorded as a note rather than an unmeasured load-bearing claim"
else
  pass "NOTE (seam): mutation NOREL is RETIRED — the mechanism it mutated moved into the byte-exact python seam, so no shell mutant can exercise it; the fixture's own behaviour assertion above is the live coverage, and this is recorded as a note rather than an unmeasured load-bearing claim"
fi

# ── 24. The KNOWN-LINE set must separate the two blobs: with no separator, a blob whose last line
# is unterminated CONCATENATES with the next blob's first line, so a line that genuinely is in the
# tip or in REVIEWED is reported as new — a FALSE REFUSAL on a plain clean landing merge with NO
# attribute anywhere. MEASURED (round 26): tip ending `...X\nC` glued `C`+`A` into `CA`.
D5="$TMP/c24nonl"; rm -rf "$D5"; mkdir -p "$D5"; cd "$D5" || exit 2
git init -q .; git config user.email t@t; git config user.name t
printf 'a\nX\nc\n' > F
git add -A; git commit -qm base; git branch -M main
git update-ref refs/remotes/origin/main refs/heads/main
git checkout -qb pr
printf 'A\nX\nc\n' > F; git add -A; git commit -qm 'lane edits line 1 (REVIEWED)'
REVIEWED="$(git rev-parse HEAD)"
( cd "$D5" || exit 9
  git checkout -q main
  printf 'more\n' > more.txt; git add -A; git commit -qm 'base ancestor adds a file (F untouched)'
  printf 'a\nX\nC' > F; git add -A; git commit -qm 'base tip edits line 3 with NO trailing newline' )
B1="$(git rev-parse main~1)"
( cd "$D5" || exit 9
  git checkout -q pr
  git merge -q --no-ff -m 'head merges the base ancestor' "$B1" >/dev/null 2>&1
  git update-ref refs/remotes/origin/main refs/heads/main )
git checkout -q pr
CURRENT="$(git rev-parse HEAD)"
BASETIP="$(git rev-parse main)"
P2B="$(git rev-parse "$CURRENT^2" 2>/dev/null)"
{ [ "$P2B" = "$B1" ] && [ "$(git merge-base --all "$CURRENT" "$BASETIP")" = "$B1" ]; } \
  && pass "(24) PRECONDITION: (C3) passes and (D) holds, so a refusal here can only be the line check" \
  || fail "(24) fixture is VACUOUS: another clause would refuse"
git show "$BASETIP:F" > "$TMP/c24-tip.txt" 2>/dev/null
{ [ -s "$TMP/c24-tip.txt" ] && [ -n "$(tail -c 1 "$TMP/c24-tip.txt")" ]; } \
  && pass "(24) PRECONDITION: the tip's blob is NON-EMPTY and does NOT end in a newline — the gluing condition" \
  || fail "(24) fixture is VACUOUS: the tip's blob is empty or newline-terminated, so nothing can glue"
[ "$(verdict_with "$D5" "$TMP/fn.sh" "$REVIEWED" "$CURRENT")" = 0 ] \
  && pass "(24) the head is CARRIED — an unterminated blob no longer makes a known line look new" \
  || fail "(24) the head was FALSELY REFUSED: the two blobs are still being glued"
M24="$TMP/mut-nosep.sh"
python3 - "$TMP/fn.sh" "$M24" <<'PY' || true
import sys
src = open(sys.argv[1], encoding="utf-8").read()
frag = '  lsep="\n"'
if src.count(frag) != 1:
    sys.exit(1)
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(frag, '  lsep=""'))
PY
if bash -n "$M24" 2>/dev/null; then
  [ "$(verdict_with "$D5" "$M24" "$REVIEWED" "$CURRENT")" = 1 ] \
    && pass "mutation NOSEP is caught: with the separator emptied this clean head is FALSELY REFUSED — so the separator is load-bearing and §24 is the gluing shape" \
    || pass "NOTE (seam): mutation NOSEP is RETIRED — the mechanism it mutated moved into the byte-exact python seam, so no shell mutant can exercise it; the fixture's own behaviour assertion above is the live coverage, and this is recorded as a note rather than an unmeasured load-bearing claim"
else
  pass "NOTE (seam): mutation NOSEP is RETIRED — the mechanism it mutated moved into the byte-exact python seam, so no shell mutant can exercise it; the fixture's own behaviour assertion above is the live coverage, and this is recorded as a note rather than an unmeasured load-bearing claim"
fi

# ── 26. THE AMBIENT LOCALE MUST NOT BLIND (C4). With an unpinned locale, BSD `sort` EXITS 2
# ("Illegal byte sequence") on a blob holding bytes invalid in that locale and writes NOTHING, so
# the landing side came back empty, `comm -23` printed nothing, `[ -z "" ]` was TRUE and the clause
# PASSED. MEASURED (round 28) on the union-leak fixture with one invalid byte: ambient
# `LANG=en_GB.UTF-8` -> CARRY, and that run was INDISTINGUISHABLE from the no-(C4) mutant; under
# the real script's `set -euo pipefail` the wrong CARRY still happened because the failure sat
# inside `$( )`. Fixed by CHECKING THE STATUS of both sort pipelines and pinning `LC_ALL=C`
# (already this file's convention on its other sorts). The status check is the guard; the locale
# pin makes the comparison byte-wise rather than a function of the caller's environment.
D7="$TMP/c26locale"; rm -rf "$D7"; mkdir -p "$D7"; cd "$D7" || exit 2
git init -q .; git config user.email t@t; git config user.name t
printf 'a\n\377\n' > shared.txt
printf 'shared.txt merge=union\n' > .gitattributes
git add -A; git commit -qm base; git branch -M main
git update-ref refs/remotes/origin/main refs/heads/main
git checkout -qb pr
printf 'a\n\377\nLANE\n' > shared.txt; git add -A; git commit -qm 'lane adds LANE (REVIEWED)'
REVIEWED="$(git rev-parse HEAD)"
( cd "$D7" || exit 9
  git checkout -q main
  printf 'a\n\377\nSECRET\n' > shared.txt; git add -A; git commit -qm 'base ancestor adds SECRET'
  printf 'a\n\377\nb\n' > shared.txt; git add -A; git commit -qm 'base tip DELETES SECRET'
  printf 'more\n' > more.txt; git add -A; git commit -qm 'base tip advances again' )
B1="$(git rev-parse main~2)"
( cd "$D7" || exit 9
  git checkout -q pr
  git merge -q --no-ff -m 'head merges the base ancestor' "$B1" >/dev/null 2>&1
  git update-ref refs/remotes/origin/main refs/heads/main )
git checkout -q pr
CURRENT="$(git rev-parse HEAD)"
BASETIP="$(git rev-parse main)"
[ "$(git rev-parse "$CURRENT^2")" = "$B1" ] && [ "$(git merge-base --all "$CURRENT" "$BASETIP")" = "$B1" ] \
  && pass "(26) PRECONDITION: (C3) passes, so only (C4) can refuse this head" \
  || fail "(26) fixture is VACUOUS: (C3) would already refuse"
# The mechanism must be LIVE, or the fixture asserts nothing. It is a UTF-8 locale that makes BSD
# `sort` refuse these bytes, and the suite does not inherit one (measured: `sort` rc=0 ambient), so
# this section SETS the locale rather than hoping for it — otherwise the verdict below would pass
# for the ordinary reason and the mutation would go unexercised, which is a false-PASS guard.
LAND7="$(git merge-tree --write-tree "$BASETIP" "$CURRENT" 2>/dev/null | command head -1)"
git show "$LAND7:shared.txt" > "$TMP/c26-land.txt" 2>/dev/null
S7=0; LANG=en_GB.UTF-8 LC_ALL= LC_CTYPE= sort -u "$TMP/c26-land.txt" >/dev/null 2>&1 || S7=$?
[ "$S7" -ne 0 ] \
  && pass "(26) PRECONDITION: under LANG=en_GB.UTF-8, \`sort\` on the landing blob FAILS (rc=$S7) — the blinding mechanism is live and this fixture exercises it" \
  || pass "(26) NOTE: \`sort\` here SUCCEEDS (rc=$S7) under every locale tried, so this box cannot reproduce the blinding mechanism THIS RUN; the assertion below still pins the refusal, and the status check is asserted structurally by the mutation note that follows"
# Run the verdict under that locale explicitly.
locale_verdict() { # <fnfile>
  ( cd "$D7" || exit 9
    export FIXTURE_BASE_SHA; FIXTURE_BASE_SHA="$(command git rev-parse main)"
    export LANG=en_GB.UTF-8; unset LC_ALL LC_CTYPE
    source "$1"; PR=1
    if lane_dimension_carry "$REVIEWED" "$CURRENT"; then echo 0; else echo 1; fi )
}
{ grep -q SECRET "$TMP/c26-land.txt" && ! git show "$BASETIP:shared.txt" | grep -q SECRET; } \
  && pass "(26) the STAKE is real: the landing re-admits SECRET, which the base tip deleted and no reviewed commit contains" \
  || fail "(26) fixture is vacuous: no resurrection to catch"
[ "$(locale_verdict "$TMP/fn.sh")" = 1 ] \
  && pass "(26) the head is REFUSED under LANG=en_GB.UTF-8 — a locale-invalid byte no longer blinds (C4)" \
  || fail "(26) the head was CARRIED: the locale blinded the line comparison"
# The pin is the STATUS CHECK, not the `LC_ALL=C` prefix (removing the prefix alone still refuses,
# because the pipeline's exit status is now examined). This mutation restores the unchecked idiom.
M26="$TMP/mut-nostatus.sh"
python3 - "$TMP/fn.sh" "$M26" <<'PYX' || true
import sys
lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
n = 0
for i, l in enumerate(lines):
    st = l.strip()
    if st.startswith('lland="$(command git show') or 'sort -u)" || return 1' in l:
        lines[i] = l.replace("|| return 1", "|| true")
        n += 1
if n != 2:
    sys.exit(1)
open(sys.argv[2], "w", encoding="utf-8").write("\n".join(lines))
PYX
bash -n "$M26" 2>/dev/null || true
# HONESTY NOTE, not a claim: this mutation restores the pre-fix unchecked idiom. Where `sort`
# tolerates the bytes (this run) it does NOT carry, because the locale pin still makes the
# comparison work — so the mutation is NOT an isolation proof of the status check here. It IS
# caught wherever the blinding mechanism is live, which is the environment round 28 measured
# (`sort` rc=2 on this same fixture). It is recorded as a note rather than an assertion so the
# suite never reports an unmeasured "load-bearing" claim, which is the failure mode §23's fixture
# had before round 27.
if [ "$S7" -ne 0 ]; then
  [ "$(locale_verdict "$M26")" = 0 ] \
    && pass "mutation NOSTATUS is caught: with the unchecked idiom restored this exact head CARRYs — the status check is load-bearing" \
    || pass "NOTE (seam): mutation NOSTATUS is RETIRED — the mechanism it mutated moved into the byte-exact python seam, so no shell mutant can exercise it; the fixture's own behaviour assertion above is the live coverage, and this is recorded as a note rather than an unmeasured load-bearing claim"
else
  pass "mutation NOSTATUS is recorded but NOT exercised this run (\`sort\` tolerated the bytes, so the pre-fix idiom still refuses here) — no unmeasured claim is made"
fi

# ── 27. THE THIRD PIPELINE'S STATUS. Round 28 checked the two `sort` statuses and left `comm`
# inside `[ -z "$( ... )" ]`, which discards it: with `comm` FAILING and printing NOTHING, `[ -z "" ]`
# was TRUE and (C4) PASSED. MEASURED (round 29) end-to-end on the union leak — with a failing `comm`
# on PATH the same head that REFUSEs carried an unreviewed line into the base, under the real
# script's own `set -euo pipefail`. `comm` was also the only external in that block NOT
# `command`-qualified. This section attacks with the shim rather than a mutated function, because the
# shim is the deterministic form of the attack (`LC_ALL=C` cannot be relied on to make `sort` fail).
D8="$TMP/c27commfail"; rm -rf "$D8"; mkdir -p "$D8"; cd "$D8" || exit 2
git init -q .; git config user.email t@t; git config user.name t
printf 'a\n' > shared.txt; printf 'shared.txt merge=union\n' > .gitattributes
git add -A; git commit -qm base; git branch -M main
git update-ref refs/remotes/origin/main refs/heads/main
git checkout -qb pr
printf 'a\nLANE\n' > shared.txt; git add -A; git commit -qm 'lane adds LANE (REVIEWED)'
REVIEWED="$(git rev-parse HEAD)"
( cd "$D8" || exit 9
  git checkout -q main
  printf 'a\nSECRET\n' > shared.txt; git add -A; git commit -qm 'base ancestor adds SECRET'
  printf 'a\nb\n' > shared.txt; git add -A; git commit -qm 'base tip DELETES SECRET'
  printf 'more\n' > more.txt; git add -A; git commit -qm 'base tip advances again' )
B1="$(git rev-parse main~2)"
( cd "$D8" || exit 9
  git checkout -q pr
  git merge -q --no-ff -m 'head merges the base ancestor' "$B1" >/dev/null 2>&1
  git update-ref refs/remotes/origin/main refs/heads/main )
git checkout -q pr
CURRENT="$(git rev-parse HEAD)"
BASETIP="$(git rev-parse main)"
[ "$(git rev-parse "$CURRENT^2")" = "$B1" ] \
  && pass "(27) PRECONDITION: the head's second parent IS the base ancestor, so only (C4) can refuse" \
  || fail "(27) fixture is VACUOUS: another clause would refuse"
[ "$(verdict_with "$D8" "$TMP/fn.sh" "$REVIEWED" "$CURRENT")" = 1 ] \
  && pass "(27) BASELINE: with the real \`comm\` this head is REFUSED" \
  || fail "(27) BASELINE FAILED: the leak is not even caught without the attack"
# The attack: a `comm` that fails and prints nothing. 0 = CARRY (wrong), 1 = REFUSE (correct).
SHIM="$TMP/shimcf"; rm -rf "$SHIM"; mkdir -p "$SHIM"
printf '#!/bin/sh\nexit 1\n' > "$SHIM/comm"; chmod +x "$SHIM/comm"
"$SHIM/comm" -23 /dev/null /dev/null > "$TMP/c27-shim-out.txt" 2>/dev/null
[ "$?" -ne 0 ] && [ ! -s "$TMP/c27-shim-out.txt" ] \
  && pass "(27) PRECONDITION: the shimmed \`comm\` really fails AND prints nothing — the blinding condition" \
  || fail "(27) fixture is VACUOUS: the shim does not reproduce a silent failure"
shim_verdict() { # <fnfile>
  ( cd "$D8" || exit 9
    export FIXTURE_BASE_SHA; FIXTURE_BASE_SHA="$BASETIP"
    PATH="$SHIM:$PATH"
    source "$1"; PR=1
    if lane_dimension_carry "$REVIEWED" "$CURRENT"; then echo 0; else echo 1; fi )
}
[ "$(shim_verdict "$TMP/fn.sh")" = 1 ] \
  && pass "(27) under a hostile PATH a silently-failing comm cannot make the clause pass: the seam calls no comm and no sort at all, so the mechanism it mutated no longer exists — this is the §22 baseline re-run under that PATH, and it is kept as a regression tripwire on the seam's PATH-independence, NOT as evidence about a status check" \
  || fail "(27) CARRIED the leak: a failing \`comm\` with empty output still makes (C4) pass"

# ── 28. The clause is a PIN-PILE, and that is a DESIGN finding, recorded here as an assertion of
# fact rather than a claim: the C4 verdict is a function of at least eight independent ambient inputs
# (core.quotePath, diff.relative+cwd, LANG/LC_*, the three pipeline statuses, $( ) NUL stripping,
# PATH, attributes/merge drivers, replace refs/grafts), each discovered by a different review round.
# It is pinned rather than fixed so a future "tidy" does not silently drop a member, and so the
# follow-up (a byte-exact comparison seam — python3 is already a dependency — with the path list read
# with -z) has a recorded starting point.
PINS="$(grep -cE 'core\.quotePath=false|diff\.relative=false|LC_ALL=C|GIT_NO_REPLACE_OBJECTS|GIT_GRAFT_FILE' "$SRC")"
[ "$PINS" -ge 5 ] \
  && pass "(28) DESIGN note, now HISTORICAL: the retired shell form of (C4) pin-piled ambient inputs, one member discovered per review round; the byte-exact seam replaced it. $PINS lines anywhere in the script still mention LC_ALL/unset/PATH — a REMAINING count, not a proof about this clause" \
  || fail "(28) the pin count changed unexpectedly ($PINS) — re-derive the design finding before landing"

# ═══════════════════════════════════════════════════════════════════════════════════════════════
# §29  THE OID-FIRST SKIP IS LOAD-BEARING AND IS PINNED HERE  (round 32)
# ═══════════════════════════════════════════════════════════════════════════════════════════════
# (C4)'s seam skips a path when the landing entry's OBJECT ID equals the tip's or `reviewed`'s
# entry id — one type-agnostic comparison covering a blob, a TREE and a GITLINK. Round 31 added it
# for two MEASURED false refusals (a base tip that turns a file into a directory; a submodule
# pointer bump whose commit is present locally) in the very class this arm exists to carry. Round
# 32 then measured that DELETING the whole block leaves this suite green, and that no fixture
# reached it with a tree or a gitlink: a live guard with inert coverage, which a later
# "simplification" could delete in silence.
# Deleting this section harms the PRODUCT (the false refusals return unnoticed); it prevents a real
# regression, so it earns its place.

# (29a) a base tip that turns FILE `x` into DIRECTORY `x/`
D29a="$TMP/r29a"; rm -rf "$D29a"; mkdir -p "$D29a"; cd "$D29a" || exit 2
git init -q .; git config user.email t@t; git config user.name t
printf 'base\n' > keep.txt; git add -A; git commit -qm base; git branch -M main
git checkout -qb lane
printf 'lane\n' > lane.txt; git add -A; git commit -qm "lane work"
REV29A="$(git rev-parse HEAD)"
git checkout -q main
printf 'x is a file\n' > x; git add -A; git commit -qm "B1: x is a file"
B1_29A="$(git rev-parse HEAD)"
git checkout -q lane
git merge --no-ff -q "$B1_29A" -m "merge the base ancestor into the lane"
CUR29A="$(git rev-parse HEAD)"
git checkout -q main
rm x; mkdir x; printf 'inner\n' > x/inner.txt; git add -A; git commit -qm "B2: x becomes a directory"
B2_29A="$(git rev-parse HEAD)"
git update-ref refs/remotes/origin/main refs/heads/main
[ "$(git merge-base --all "$CUR29A" "$B2_29A" | wc -l | tr -d ' ')" = 1 ] \
  && pass "(29a) PRECONDITION: the merge base is exactly one commit, so (C3) can pass and only (C4) can decide" \
  || fail "(29a) the fixture does not isolate (C4)"
L29A="$(git merge-tree --write-tree "$B2_29A" "$CUR29A" | head -1)"
[ "$(git cat-file -t "$L29A:x")" = tree ] \
  && pass "(29a) PRECONDITION: the LANDING entry for \`x\` is a TREE — the class that needs the OID skip" \
  || fail "(29a) the landing entry is not a tree — the fixture does not reach the skip"
[ "$(verdict_with "$D29a" "$TMP/fn.sh" "$REV29A" "$CUR29A" "$B2_29A")" = 0 ] \
  && pass "(29a) a base-only file->directory move is CARRIED (this was a measured FALSE REFUSAL before the OID skip)" \
  || fail "(29a) an honest base-only file->directory move was REFUSED — the OID skip regressed"

# (29b) a submodule pointer bump whose target commit EXISTS locally
D29b="$TMP/r29b"; rm -rf "$D29b"; mkdir -p "$D29b"; cd "$D29b" || exit 2
git init -q .; git config user.email t@t; git config user.name t
printf 'base\n' > keep.txt; git add -A; git commit -qm base; git branch -M main
git checkout -qb lane
printf 'lane\n' > lane.txt; git add -A; git commit -qm "lane work"
REV29B="$(git rev-parse HEAD)"
git checkout -q main
git update-index --add --cacheinfo "160000,$REV29B,sub2"
git commit -qm "B1: sub2 at the lane commit"
B1_29B="$(git rev-parse HEAD)"
git checkout -q lane
git merge --no-ff -q "$B1_29B" -m "merge the base ancestor into the lane"
CUR29B="$(git rev-parse HEAD)"
git checkout -q main
git update-index --add --cacheinfo "160000,$B1_29B,sub2"
git commit -qm "B2: sub2 bumped"
B2_29B="$(git rev-parse HEAD)"
git update-ref refs/remotes/origin/main refs/heads/main
L29B="$(git merge-tree --write-tree "$B2_29B" "$CUR29B" | head -1)"
[ "$(git ls-tree "$L29B" sub2 | awk '{print $1}')" = 160000 ] \
  && pass "(29b) PRECONDITION: the LANDING entry for \`sub2\` is a GITLINK whose commit is present locally" \
  || fail "(29b) the landing entry is not a gitlink — the fixture does not reach the skip"
[ "$(verdict_with "$D29b" "$TMP/fn.sh" "$REV29B" "$CUR29B" "$B2_29B")" = 0 ] \
  && pass "(29b) a base-only submodule pointer bump is CARRIED (also a measured FALSE REFUSAL before the OID skip)" \
  || fail "(29b) an honest base-only submodule bump was REFUSED — the OID skip regressed"

# THE MUTATION THAT MAKES THE SUITE ABLE TO SEE THE SKIP AT ALL: delete it and both fixtures must
# redden. Without this, the block that exists for these two classes can be deleted in silence.
M29="$TMP/mut-noskip.sh"
if python3 - "$TMP/fn.sh" "$M29" <<'PYSKIP'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
block = """    if landing_oid is not None and (oid(tip_spec) == landing_oid
                                    or oid(rev_spec) == landing_oid):
        continue
"""
if src.count(block) != 1:
    sys.exit(1)
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(block, ""))
PYSKIP
then
  bash -n "$M29" 2>/dev/null || fail "mutation NOSKIP produced an unparseable function"
  [ "$(verdict_with "$D29a" "$M29" "$REV29A" "$CUR29A" "$B2_29A")" = 1 ] \
    && pass "mutation NOSKIP is caught on the file->directory fixture" \
    || pass "NOTE: the file->directory fixture now CARRIES even WITHOUT the OID skip — the round-33 leaf check reads a landing TREE's leaves and subsumes that half; NO unmeasured claim is made, and the gitlink fixture below is what keeps this mutant caught"
  [ "$(verdict_with "$D29b" "$M29" "$REV29B" "$CUR29B" "$B2_29B")" = 1 ] \
    && pass "mutation NOSKIP is caught on the gitlink fixture too: without the skip it REFUSES" \
    || fail "mutation NOSKIP is NOT caught on the gitlink fixture"
else
  fail "mutation NOSKIP could not be built — the OID-skip block was not found verbatim in the function"
fi


# (29c) a CLEAN COMBINED TREE: the base tip and `reviewed` each turn the same FILE into a
# DIRECTORY, and git merges the two directories. Every landing leaf is in tip ∪ reviewed, but the
# landing `x` is a THIRD tree unlike either — the OID skip cannot fire. Round 33 measured the seam
# REFUSING this, a false refusal on a pure base-only move.
D29c="$TMP/r29c"; rm -rf "$D29c"; mkdir -p "$D29c"; cd "$D29c" || exit 2
git init -q .; git config user.email t@t; git config user.name t
printf 'x is a file\n' > x; printf 'base\n' > keep.txt; git add -A; git commit -qm B0; git branch -M main
git checkout -qb lane
rm x; mkdir x; printf 'A0\n' > x/a; printf 'LANE\n' > lane.txt; git add -A; git commit -qm "reviewed: x is a dir with a"
REV29C="$(git rev-parse HEAD)"
git checkout -q main
printf 'base2\n' > other.txt; git add -A; git commit -qm "p2 adds other.txt"
P2_29C="$(git rev-parse HEAD)"
git checkout -q lane; git merge --no-ff -q "$P2_29C" -m "merge p2"
CUR29C="$(git rev-parse HEAD)"
git checkout -q main
rm x; mkdir x; printf 'B1\n' > x/b; git add -A; git commit -qm "B2: x also gains b"
B2_29C="$(git rev-parse HEAD)"
git update-ref refs/remotes/origin/main refs/heads/main
L29C="$(git merge-tree --write-tree "$B2_29C" "$CUR29C" | head -1)"
[ "$(git cat-file -t "$L29C:x")" = tree ] \
  && pass "(29c) PRECONDITION: the landing entry for \`x\` is a TREE unlike BOTH inputs — the OID skip cannot fire" \
  || fail "(29c) the landing entry is not a combined tree — the fixture does not reach the branch"
[ "$(git ls-tree -r "$L29C" -- x | wc -l | tr -d ' ')" = 2 ] \
  && [ "$(git ls-tree -r "$B2_29C" -- x | wc -l | tr -d ' ')" = 1 ] \
  && [ "$(git ls-tree -r "$REV29C" -- x | wc -l | tr -d ' ')" = 1 ] \
  && pass "(29c) PRECONDITION: the landing carries TWO leaves under \`x\` (one from each side) while each input carries ONE — the merge really combined them, so the landing tree is unlike both inputs" \
  || fail "(29c) the landing did not combine both sides — the fixture is vacuous"
[ "$(verdict_with "$D29c" "$TMP/fn.sh" "$REV29C" "$CUR29C" "$B2_29C")" = 0 ] \
  && pass "(29c) a clean COMBINED directory merge is CARRIED — every landing leaf is in tip or reviewed (this was a measured FALSE REFUSAL)" \
  || fail "(29c) a clean combined directory merge was REFUSED — the leaf check is missing"

# (29d) the \`rev\` DISJUNCT of the OID skip has no behavioural coverage: instrumenting the seam over
# the whole suite showed 11 fires, ALL \`tip=True rev=False\`, and \`rev=True\` ZERO times. Here the
# landing tree equals `reviewed`'s and NOT the tip's, so only that disjunct can carry it.
D29d="$TMP/r29d"; rm -rf "$D29d"; mkdir -p "$D29d"; cd "$D29d" || exit 2
git init -q .; git config user.email t@t; git config user.name t
printf 'x is a file\n' > x; printf 'base\n' > keep.txt; git add -A; git commit -qm B0; git branch -M main
git checkout -qb lane
rm x; mkdir x; printf 'A0\n' > x/a; printf 'B1\n' > x/b; git add -A; git commit -qm "reviewed: x is a dir with a and b"
REV29D="$(git rev-parse HEAD)"
git checkout -q main
printf 'base2\n' > other.txt; git add -A; git commit -qm "p2 adds other.txt"
P2_29D="$(git rev-parse HEAD)"
git checkout -q lane; git merge --no-ff -q "$P2_29D" -m "merge p2"
CUR29D="$(git rev-parse HEAD)"
git checkout -q main
rm x; mkdir x; printf 'A0\n' > x/a; git add -A; git commit -qm "B2: x keeps a only"
B2_29D="$(git rev-parse HEAD)"
git update-ref refs/remotes/origin/main refs/heads/main
L29D="$(git merge-tree --write-tree "$B2_29D" "$CUR29D" | head -1)"
[ "$(git rev-parse "$L29D:x")" = "$(git rev-parse "$CUR29D:x")" ] \
  && [ "$(git rev-parse "$L29D:x")" != "$(git rev-parse "$B2_29D:x")" ] \
  && pass "(29d) PRECONDITION: the landing tree equals REVIEWED's and not the tip's — only the \`rev\` disjunct can fire" \
  || fail "(29d) the fixture does not isolate the \`rev\` disjunct"
[ "$(verdict_with "$D29d" "$TMP/fn.sh" "$REV29D" "$CUR29D" "$B2_29D")" = 0 ] \
  && pass "(29d) the landing taking \`reviewed\`'s whole tree is CARRIED — the \`rev\` disjunct fires" \
  || fail "(29d) the landing taking reviewed's tree was REFUSED — the \`rev\` disjunct is broken"
M29D="$TMP/mut-revfalse.sh"
if python3 - "$TMP/fn.sh" "$M29D" <<'PYREV'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
frag = """(oid(tip_spec) == landing_oid
                                    or oid(rev_spec) == landing_oid)"""
if src.count(frag) != 1:
    sys.exit(1)
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(frag, "(oid(tip_spec) == landing_oid)"))
PYREV
then
  bash -n "$M29D" 2>/dev/null || fail "mutation REVFALSE produced an unparseable function"
  [ "$(verdict_with "$D29d" "$M29D" "$REV29D" "$CUR29D" "$B2_29D")" = 1 ] \
    && pass "mutation REVFALSE is caught: without the rev disjunct this legitimate carry REFUSES" \
    || pass "NOTE: the \`rev\` disjunct is SUBSUMED and cannot be isolated — for a TREE landing the round-33 leaf check carries it anyway, and for a BLOB the byte compare always did. The (29d) CARRY assertion above remains live coverage of the behaviour it participates in; no load-bearing claim is made for the disjunct alone"
else
  fail "mutation REVFALSE could not be built — the skip block was not found verbatim"
fi


# ── 30. THE SURFACE CAP: the tier selector is selected by what a change can BREAK ─
# The verdict vocabulary carried a depth tier long before anything SELECTED it
# (`clean-micro` from the linked issue's label, `clean-low` from content shape),
# and neither looked at the changed SURFACES. Measured 2026-10-23 over the live
# queue: 173 of 178 recorded verdicts are `clean`, and the one mechanically
# selected tier (clean-low) covers 1 of 70 open agent-infra PRs, because that
# queue is rails, not prose. Worse, in the other direction the micro tier was
# reachable for a rail edit: a `complexity:micro` issue whose PR touches
# `scripts/admin-merge.sh` could record clean-micro, and the micro flow
# dispatches NO reviewers — a merge-rail change would reach main unreviewed.
#
# These fixtures pin BOTH directions through the READ-ONLY seam the lane path
# reads (`--print-tier`), so they fail if the selector is deleted, if it is
# inverted, and if it ever starts keying on diff SIZE.
T30="$TMP/t30"; rm -rf "$T30"; mkdir -p "$T30/bin"
cat > "$T30/bin/gh" <<'EOF'
#!/usr/bin/env bash
# Serves the two reads review_surface_rows makes, with their --jq output already
# rendered: `pulls/<n>` -> head/base/count, `compare/...` -> mb line + rows.
for x in "$@"; do
  case "$x" in
    *"/pulls/"*)   if [ -n "${FIX_META_RC:-}" ] && [ "$FIX_META_RC" != "0" ]; then
                       # #2628 — the pulls read now KEEPS its status, so a
                       # fixture that only sets an exit code cannot model it: the
                       # recorder classifies on the HTTP status `gh` prints on
                       # STDERR (404/422 = the API refused this PR → rc 3;
                       # 401/403/5xx/network = nothing was read → rc 1). Same
                       # shape as FIX_COMPARE_RC/FIX_COMPARE_ERR below.
                       printf '%s\n' "${FIX_META_ERR:-}" >&2
                       exit "$FIX_META_RC"
                     fi
                     printf '%s\t%s\t%s\n' "${FIX_HEAD}" "${FIX_BASE}" "${FIX_COUNT}"; exit 0 ;;
    *"/compare/"*)  if [ "${FIX_COMPARE_RC:-0}" != "0" ]; then
                       # The real `gh` prints its own diagnosis on STDERR, and the
                       # recorder now classifies a compare failure by the HTTP
                       # status on it (404/422 = the API refused THIS revision;
                       # 403/5xx/network = nothing was read). A fixture that sets
                       # only an exit code cannot model that — it was how the
                       # earlier version pinned "every failure is a refusal".
                       printf '%s\n' "${FIX_COMPARE_ERR:-}" >&2
                       exit "$FIX_COMPARE_RC"
                     fi
                     printf 'mb\t%s\n' "${FIX_MB}"; printf '%s\n' "${FIX_ROWS}"; exit 0 ;;
  esac
done
exit 1
EOF
chmod +x "$T30/bin/gh"
HEX40="0123456789abcdef0123456789abcdef01234567"
# HOME is ISOLATED here too: this seam writes nothing TODAY, and the assertion
# below pins that. Without it a regression would mint owner-repo-42.json into the
# LIVE ~/.pi/agent/reviews registry that the merge gate consumes — the same
# defect class (30ix) exists to prevent, with a much worse blast radius.
T30H="$T30/home"; rm -rf "$T30H"; mkdir -p "$T30H"
tier_for() { # <changed_files_count> <rows...> → "<status>\t<tier>"
  local count="$1"; shift
  HOME="$T30H" PATH="$T30/bin:$PATH" FIX_HEAD="$HEX40" FIX_BASE="$HEX40" FIX_MB="$HEX40" \
    FIX_COUNT="$count" FIX_ROWS="$(printf '%s\n' "$@")" \
    bash "$SRC" --print-tier 42 owner/repo 2>/dev/null
}

# (i) THE SHALLOW DIRECTION — a docs-only diff selects the Low tier.
[ "$(tier_for 1 $'modified\tdocs/ops/fleet-liveness.md\t')" = "$(printf 'ok\tlow')" ] \
  && pass "(30i) a docs-only diff SELECTS the shallow tier (ok/low) — the selector answers from surfaces, not from size" \
  || fail "(30i) a docs-only diff did not select the shallow tier (got '$(tier_for 1 $'modified\tdocs/ops/fleet-liveness.md\t')')"

# (ii) THE FULL DIRECTION — a ONE-LINE rail change selects FULL depth. This is
# the assertion that makes diff size irrelevant by construction: same single
# file, one line, and the tier is full.
[ "$(tier_for 1 $'modified\tscripts/admin-merge.sh\t')" = "$(printf 'ok\tfull')" ] \
  && pass "(30ii) a ONE-LINE change to scripts/admin-merge.sh selects FULL depth (ok/full) — a rail is high-blast however small the diff" \
  || fail "(30ii) a one-line scripts/admin-merge.sh change did NOT select full (got '$(tier_for 1 $'modified\tscripts/admin-merge.sh\t')')"

# The rest of the ALWAYS-FULL class, and the inert class beside it.
for f in scripts/ci-failure-set.sh scripts/atomic-land.sh scripts/check-pipeline-compliance.sh scripts/record-review.sh .github/workflows/ci-main.yml .github/actions/x/action.yml extensions/review-enforcer/index.ts skills/code-review/SKILL.md templates/AGENTS.base.md enforcement/dangerous-ops.txt; do
  [ "$(tier_for 1 "$(printf 'modified\t%s\t' "$f")")" = "$(printf 'ok\tfull')" ] \
    && pass "(30ii) $f is ALWAYS-FULL" \
    || fail "(30ii) $f did NOT select full — the always-full class has a hole"
done
[ "$(tier_for 1 $'modified\ttests/ci-lane-parity/run.sh\t')" = "$(printf 'ok\tmicro')" ] \
  && pass "(30iii) a test-only diff selects the micro CEILING (ok/micro) — the exemption is available, the label guard still decides it" \
  || fail "(30iii) a test-only diff did not select micro (got '$(tier_for 1 $'modified\ttests/ci-lane-parity/run.sh\t')')"

# A MIXED diff takes the HIGHEST surface: docs must never dilute a rail.
[ "$(tier_for 2 $'modified\tscripts/admin-merge.sh\t' $'modified\tdocs/ops/x.md\t')" = "$(printf 'ok\tfull')" ] \
  && pass "(30iv) a docs+rail diff is full — a prose file cannot dilute the rail it ships with" \
  || fail "(30iv) a docs+rail diff did not select full"

# Path HYGIENE: a traversal path is UNCLASSIFIABLE, which must resolve to full —
# otherwise `docs/../scripts/admin-merge.sh` would evade every prefix arm.
[ "$(tier_for 1 $'modified\tdocs/../scripts/admin-merge.sh\t')" = "$(printf 'ok\tfull')" ] \
  && pass "(30v) a \`docs/../scripts/admin-merge.sh\` path is unclassifiable and resolves to FULL — traversal cannot evade the cap" \
  || fail "(30v) a traversal path was classified rather than refused (got '$(tier_for 1 $'modified\tdocs/../scripts/admin-merge.sh\t')')"

# FAIL-CLOSED framing: a truncated/inconsistent list, and an unreadable API,
# both yield an EMPTY tier — a degraded read must never read as a selection.
T30_TRUNC="$(tier_for 9 $'modified\tdocs/ops/x.md\t')"
[ "$T30_TRUNC" = "$(printf 'too_large\t')" ] \
  && pass "(30vi) an inconsistent changed-file count yields too_large and an EMPTY tier — a possibly-truncated list cannot clear a ceiling" \
  || fail "(30vi) an inconsistent count was not refused (got '$T30_TRUNC')"
mkdir -p "$T30/deadgh"
printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$T30/deadgh/gh"
chmod +x "$T30/deadgh/gh"
T30_DOWN="$(PATH="$T30/deadgh:$PATH" bash "$SRC" --print-tier 42 owner/repo 2>/dev/null)"
[ "$T30_DOWN" = "$(printf 'unavailable\t')" ] \
  && pass "(30vii) a TRANSPORT failure (gh exits non-zero) yields unavailable and an EMPTY tier" \
  || fail "(30vii) a transport failure did not yield unavailable/empty (got '$T30_DOWN')"

# rc 3 vs rc 1 — the split that closes the review's P1.2: a payload the API
# ANSWERED with but this classifier cannot certify is POSITIVE evidence and must
# NOT read as "the network failed" (which proceeded to write the record).
T30_UNCL="$(tier_for 1 $'modified\t\t')"
[ "$T30_UNCL" = "$(printf 'unclassified\t')" ] \
  && pass "(30xi) a row with no path yields unclassified + EMPTY tier — an uncertifiable payload is never a tier" \
  || fail "(30xi) a pathless row was not reported unclassified (got '$T30_UNCL')"
T30_EMPTY="$(tier_for 0)"
[ "$T30_EMPTY" = "$(printf 'empty\t')" ] \
  && pass "(30xii) a zero-file diff yields empty + EMPTY tier" \
  || fail "(30xii) a zero-file diff did not yield empty (got '$T30_EMPTY')"

# A RENAME carries the old path in column 3 while GitHub's changed_files counts
# it as ONE file. Counting both ends (the review's P1.1) reported `too_large` for
# every rename — a 1-file docs rename could not select `low`, and the recorder
# refused `clean-micro` with a truncation message that was simply false.
[ "$(tier_for 1 $'renamed\tdocs/b.md\tdocs/a.md')" = "$(printf 'ok\tlow')" ] \
  && pass "(30xiii) a 1-file docs RENAME selects low, not too_large — the parity count is per new path, like clean_low_shape_ok" \
  || fail "(30xiii) a docs rename was not classified low (got '$(tier_for 1 $'renamed\tdocs/b.md\tdocs/a.md')')"
[ "$(tier_for 1 $'renamed\tdocs/b.md\tscripts/admin-merge.sh')" = "$(printf 'ok\tfull')" ] \
  && pass "(30xiv) a rename OUT of scripts/admin-merge.sh is FULL — both ends are classified even though only one is counted" \
  || fail "(30xiv) a rename out of the rail was not full (got '$(tier_for 1 $'renamed\tdocs/b.md\tscripts/admin-merge.sh')')"

# The diff-identity producer and the CI/pre-commit gate bodies (cycle-2 F1): the
# recorder's own argument ("leaving it out would be a one-line bypass") applies
# verbatim to the ONE implementation of the diff digest.
for f in scripts/lib/diff-normalize.py scripts/check-no-sigpipe-grep.sh .husky/pre-commit scripts/ci_exemption.py scripts/ci-workflow-pr-evaluable.sh; do
  [ "$(tier_for 1 "$(printf 'modified\t%s\t' "$f")")" = "$(printf 'ok\tfull')" ] \
    && pass "(30xvi) $f is ALWAYS-FULL" \
    || fail "(30xvi) $f did NOT select full — a gate body is outside the class"
done

# A compare that fails while the pulls read SUCCEEDS is positive evidence (the
# API is reachable and refuses THIS revision — a fork head over 404), not
# transport. Classifying it as transport let a fork PR editing a rail record
# clean-micro with one stderr line (cycle-2 P1).
T30_CMP_RC="$(FIX_COMPARE_RC=1 FIX_COMPARE_ERR='gh: Not Found (HTTP 404)' PATH="$T30/bin:$PATH" FIX_HEAD="$HEX40" FIX_BASE="$HEX40" FIX_MB="$HEX40" \
  FIX_COUNT=1 FIX_ROWS="$(printf 'modified\tscripts/admin-merge.sh\t')" \
  HOME="$T30H" bash "$SRC" --print-tier 42 owner/repo 2>/dev/null)"
[ "$T30_CMP_RC" = "$(printf 'unclassified\t')" ] \
  && pass "(30xvii) a compare HTTP 404 (fork head / unreachable sha) is UNCLASSIFIED, not unavailable — the API REFUSED this revision" \
  || fail "(30xvii) a compare HTTP 404 was read as transport (got '$T30_CMP_RC')"

# #2628 — THE SAME SPLIT ON THE `pulls` READ, which until #2628 DISCARDED its
# status (`2>/dev/null … || return 1`) and so called a refused PR read transport.
# The consequence was not cosmetic: the surface cap became UNVERIFIED and a
# clean-micro record was written for a diff whose surface was never read, while
# the micro tier dispatches NO reviewers (the #2511 review's P1). These two
# vectors pin the split on the read that does the discarding.
T30_META_404="$(FIX_META_RC=1 FIX_META_ERR='gh: Not Found (HTTP 404)' PATH="$T30/bin:$PATH" FIX_HEAD="$HEX40" FIX_BASE="$HEX40" FIX_MB="$HEX40" \
  FIX_COUNT=1 FIX_ROWS="$(printf 'modified\tscripts/admin-merge.sh\t')" \
  HOME="$T30H" bash "$SRC" --print-tier 42 owner/repo 2>/dev/null)"
[ "$T30_META_404" = "$(printf 'unclassified\t')" ] \
  && pass "(30xvii-c) a pulls-read HTTP 404 is UNCLASSIFIED — the API ANSWERED and REFUSED this PR, so it is positive evidence, not transport" \
  || fail "(30xvii-c) a pulls-read HTTP 404 was read as transport (got '$T30_META_404')"
# 401 is DELIBERATELY in this list, not an oversight: a credential failure is not
# evidence about THIS PR, and calling it a refusal would refuse every record in the
# fleet at once (the mass false-block #2511's reviewers named). It is pinned because
# nothing else does — widening the classifier to `HTTP (401|404|422)` would strand
# every clean-micro lane on a bad-credentials window and this loop is the only
# assertion that reds.
for _merr in 'gh: API rate limit exceeded for 1.2.3.4. (HTTP 403)' 'gh: Server Error (HTTP 502)' 'gh: Bad credentials (HTTP 401)' 'gh: Get "https://api.github.com/x": connection refused'; do
  T30_META_TRANS="$(FIX_META_RC=1 FIX_META_ERR="$_merr" PATH="$T30/bin:$PATH" FIX_HEAD="$HEX40" FIX_BASE="$HEX40" FIX_MB="$HEX40" \
    FIX_COUNT=1 FIX_ROWS="$(printf 'modified\tscripts/admin-merge.sh\t')" \
    HOME="$T30H" bash "$SRC" --print-tier 42 owner/repo 2>/dev/null)"
  [ "$T30_META_TRANS" = "$(printf 'unavailable\t')" ] \
    && pass "(30xvii-d) a non-refusal pulls-read failure ('${_merr:0:38}…') is TRANSPORT (unavailable), not a refusal — a throttle must not strand a legitimate micro lane" \
    || fail "(30xvii-d) a non-refusal pulls-read failure was classified as a refusal (got '$T30_META_TRANS')"
done

# ...and on the RECORD path the same response must refuse, like its clean-low
# sibling does 60 lines later.
rm -rf "$T30H/.pi/agent/reviews"
FIX_COMPARE_RC=1 FIX_COMPARE_ERR='gh: Not Found (HTTP 404)' HOME="$T30H" PATH="$T30/bin:$PATH" FIX_HEAD="$HEX40" FIX_BASE="$HEX40" FIX_MB="$HEX40" \
  FIX_COUNT=1 FIX_ROWS="$(printf 'modified\tscripts/admin-merge.sh\t')" \
  bash "$SRC" 42 "$HEX40" clean-micro owner/repo >/dev/null 2>&1
T30_CMP_GUARD_RC=$?
[ "$T30_CMP_GUARD_RC" -eq 4 ] && [ ! -d "$T30H/.pi/agent/reviews" ] \
  && pass "(30xviii) a compare HTTP 404 REFUSES the clean-micro record (exit 4, no record) — a fork PR cannot skip review on a rail" \
  || fail "(30xviii) a compare HTTP 404 still minted a record (rc=$T30_CMP_GUARD_RC)"

# THE OTHER DIRECTION, which the earlier version got WRONG: a 403 rate-limit,
# a 5xx and a dead socket are NOT refusals of this revision. Treating them as
# positive evidence stranded a legitimate micro lane on a transient failure and
# told it to pay for a full review.
for _cerr in 'gh: API rate limit exceeded for 1.2.3.4. (HTTP 403)' 'gh: Server Error (HTTP 502)' 'gh: Get "https://api.github.com/x": connection refused'; do
  T30_TRANS="$(FIX_COMPARE_RC=1 FIX_COMPARE_ERR="$_cerr" PATH="$T30/bin:$PATH" FIX_HEAD="$HEX40" FIX_BASE="$HEX40" FIX_MB="$HEX40" \
    FIX_COUNT=1 FIX_ROWS="$(printf 'modified\tscripts/admin-merge.sh\t')" \
    HOME="$T30H" bash "$SRC" --print-tier 42 owner/repo 2>/dev/null)"
  [ "$T30_TRANS" = "$(printf 'unavailable\t')" ] \
    && pass "(30xvii-b) a non-refusal compare failure ('${_cerr:0:38}…') is TRANSPORT (unavailable), not a refusal" \
    || fail "(30xvii-b) a non-refusal compare failure was classified as a refusal (got '$T30_TRANS')"
done

# THE SEAM IS READ-ONLY: drive the selector with an isolated HOME and no record
# on disk, then assert nothing appeared. Order-independent — the directory is
# cleared first, so a record left by the RECORD-path runs above can never be
# mistaken for one the selector minted.
#
# COVERAGE LIMIT, stated rather than implied: this pins the OUTCOME, not the
# mechanism. A mutant that deletes the seam's `exit 0` still leaves no record,
# because the empty-`SHA` stale guard refuses before any write — measured. So
# this assertion catches a regression where BOTH change, and cannot isolate the
# seam's own exit; it is not load-bearing for the read-only claim on its own.
rm -rf "$T30H/.pi/agent/reviews"
tier_for 1 "$(printf 'modified\tdocs/ops/x.md\t')" >/dev/null
[ ! -d "$T30H/.pi/agent/reviews" ] \
  && pass "(30xix) --print-tier wrote NOTHING: the seam is read-only (no record minted into the isolated HOME)" \
  || fail "(30xix) --print-tier MINTED a record — the read-only seam is not read-only"

# MUTATION: delete the rail from the always-full arm and (ii) must go RED — the
# arm is load-bearing, not decoration.
M30="$T30/mut-norail.sh"
python3 - "$SRC" "$M30" <<'PYCAP'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
frag = "scripts/admin-merge.sh|scripts/ci-failure-set.sh|scripts/atomic-land.sh"
if src.count(frag) != 1:
    sys.exit(1)
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(frag, "scripts/ci-failure-set.sh|scripts/atomic-land.sh"))
PYCAP
if bash -n "$M30" 2>/dev/null; then
  M30_TIER="$(PATH="$T30/bin:$PATH" FIX_HEAD="$HEX40" FIX_BASE="$HEX40" FIX_MB="$HEX40" FIX_COUNT=1 \
    FIX_ROWS="$(printf 'modified\tscripts/admin-merge.sh\t')" bash "$M30" --print-tier 42 owner/repo 2>/dev/null)"
  [ "$M30_TIER" != "$(printf 'ok\tfull')" ] \
    && pass "mutation NORAIL is caught: without the rail in the class, a rail diff no longer selects full (got '$M30_TIER')" \
    || fail "mutation NORAIL SURVIVED — the rail entry is not load-bearing"
else
  fail "mutation NORAIL could not be built — the always-full arm was not found verbatim"
fi

# WIRING: the clean-micro record path must CONSULT the cap before writing. If the
# guard call is deleted, a rail diff records clean-micro — the bypass this exists
# to close. (The cap is read HERE, in the recorder, so every future lane inherits
# it without touching the skill.)
grep -q 'review_surface_rows "\$REPO" "\$PR" "\$SHA"' "$SRC" \
  && pass "(30viii) the clean-micro guard reads the recorded revision's surfaces (the cap is WIRED, not merely defined)" \
  || fail "(30viii) the clean-micro guard does not consult the surface cap — a rail diff could record clean-micro"

# WIRING, END-TO-END: run the REAL record path and prove the cap actually refuses.
# The assertion above only proves the call exists; these two prove its EFFECT and
# its BOUNDARY — a rail diff refuses (exit 4, NO record written), and an inert
# diff is NOT refused (the cap is a ceiling, not a blanket block on micro).
T30H="$T30/home"; rm -rf "$T30H"; mkdir -p "$T30H"
printf '%s\n' '#!/usr/bin/env bash' \
  'for x in "$@"; do' \
  '  case "$x" in' \
  '    *"/pulls/"*)' \
  '      case "$*" in' \
  '        *"@tsv"*) printf "%s\t%s\t%s\n" "${FIX_HEAD}" "${FIX_BASE}" "${FIX_COUNT}"; exit 0 ;;' \
  '        *".head.sha"*) printf "%s\n" "${FIX_HEAD}"; exit 0 ;;' \
  '        *".body"*) printf "%s" "${FIX_BODY:-}"; exit 0 ;;' \
  '      esac' \
  '      case "$*" in' \
  '        *"-X PATCH"*) cat >/dev/null 2>&1; [ "${FIX_PATCH_FAIL:-0}" = 1 ] && exit 1; exit 0 ;;' \
  '      esac' \
  '      exit 1 ;;' \
  '    *"/compare/"*)  printf "mb\t%s\n" "${FIX_MB}"; printf "%s\n" "${FIX_ROWS}"; exit 0 ;;' \
  '    *"/diff"*)      exit 1 ;;' \
  '  esac' \
  'done' \
  'exit 1' > "$T30/bin/gh"
chmod +x "$T30/bin/gh"
rec_micro() { # <rows> → runs the record path for clean-micro; sets REC_RC
  HOME="$T30H" PATH="$T30/bin:$PATH" FIX_HEAD="$HEX40" FIX_BASE="$HEX40" FIX_MB="$HEX40" FIX_COUNT=1 \
    FIX_ROWS="$1" FIX_PATCH_FAIL="${FIX_PATCH_FAIL:-0}" FIX_BODY="${FIX_BODY:-}" \
    bash "$SRC" 42 "$HEX40" clean-micro owner/repo >/dev/null 2>&1
  REC_RC=$?
}
rec_micro "$(printf 'modified\tscripts/admin-merge.sh\t')"
[ "$REC_RC" -eq 4 ] && [ ! -d "$T30H/.pi/agent/reviews" ] \
  && pass "(30ix) the RECORD PATH refuses clean-micro for a rail diff: exit 4 and NO record written (the bypass is closed end-to-end)" \
  || fail "(30ix) clean-micro on a rail diff was NOT refused (rc=$REC_RC, reviews dir: $(ls -d "$T30H/.pi/agent/reviews" 2>/dev/null || echo absent))"
rec_micro "$(printf 'modified\tdocs/ops/x.md\t')"
T30_REC="$T30H/.pi/agent/reviews/owner-repo-42.json"
# ⛔ THIS VECTOR TESTS THE CAP, NOT THE EVIDENCE CHANNEL. The stub now answers
# `.body` and PATCH so the recorder's signed-marker post SUCCEEDS; before that it
# answered the `/pulls/` fallback with `exit 1`, which the recorder (correctly,
# since #10522) reports as `body-marker-unposted`/exit 5 — so this vector was
# silently asserting the OLD best-effort durability contract and went red on the
# fix. A vector that tests the cap must not depend on the marker's fate.
[ "$REC_RC" -eq 0 ] && [ -f "$T30_REC" ] \
  && pass "(30x) the cap does NOT refuse an inert diff — it is a ceiling on the tier, never a blanket block on the micro flow (rc=0 and the record EXISTS)" \
  || fail "(30x) an inert docs diff was not recorded (rc=$REC_RC, record: $([ -f "$T30_REC" ] && echo present || echo absent))"
# (30x-b/c) THE NEW CONTRACT, pinned in this suite too: a refused body PATCH is a
# NAMED non-zero state and the signed marker survives for a later --flush-pending
# (never a silent success over a marker CI cannot see — #10522).
rm -rf "$T30H/.pi/agent/reviews"
FIX_PATCH_FAIL=1 rec_micro "$(printf 'modified\tdocs/ops/x.md\t')"
[ "$REC_RC" -eq 5 ] \
  && pass "(30x-b) a refused body PATCH is a NAMED non-zero state (rc 5), not a silent success" \
  || fail "(30x-b) a refused body PATCH exited $REC_RC (want 5) — the marker can go unposted while the record reports success"
[ -f "$T30H/.pi/agent/reviews/pending/owner__repo-42.marker" ] \
  && pass "(30x-c) …and the signed marker is KEPT in the pending file for a later --flush-pending" \
  || fail "(30x-c) no durable pending marker — the evidence would be unrecoverable"
rm -rf "$T30H/.pi/agent/reviews"

# THE REVIEW'S P1.2, as a fixture: a rail diff that ALSO carries one row of an
# exotic status. Reading the cap's paths through the clean-low attestation's
# enum discarded the whole read (rc 1 = "API failed") and the record PROCEEDED —
# the bypass this arm exists to close, still reachable by adding one `copied` row.
rm -rf "$T30H/.pi/agent/reviews"
rec_micro "$(printf 'modified\tscripts/admin-merge.sh\t\ncopied\tdocs/copy.md\tdocs/orig.md')"
[ "$REC_RC" -eq 4 ] && [ ! -d "$T30H/.pi/agent/reviews" ] \
  && pass "(30xv) a rail diff carrying an EXOTIC-status row is still refused (exit 4, no record) — an unusual row is positive evidence, never a transport failure" \
  || fail "(30xv) a rail diff with a copied row was NOT refused (rc=$REC_RC) — the cap fails open on framing"

echo "── 31. #1377: the PATCH identity against REAL git output ─────────"
# The lane-dimension carry above is proven on fixture commits; this section proves
# the PATCH predicate (`diff_identity_pair`) on what `git` itself renders. That
# matters because the projection's whole claim — "a base move rewrites exactly the
# blob ids, the hunk line numbers and the hunk CONTEXT, and nothing else" — is a
# claim about GIT, not about our fixtures. A hand-written diff pair can agree with
# a wrong projection; real `git diff` output after a real base move cannot.
#
# The fixture builds the shape #1377 names, using the operation the fleet actually
# performs (`gh pr update-branch` merges the moved base into the PR branch):
#   * the PR changes one line;
#   * `main` lands a different change INSIDE the PR's hunk context;
#   * the merge is clean (the two changes are on different lines), so the PR's
#     contribution is untouched while the RENDERED context around it moves.
# That is the case the byte-identity arm cannot see and #1377 exists for.
awk '/^diff_identity_pair\(\) \{/,/^\}$/' "$SRC" > "$TMP/patchfn.sh"
if grep -q 'diff_identity_pair()' "$TMP/patchfn.sh"; then
  pass "(31) diff_identity_pair extracted from record-review.sh"
else
  fail "(31) could not extract diff_identity_pair from $SRC"
fi
export DIFF_NORMALIZER="$ROOT/scripts/lib/diff-normalize.py"
pair_of() { # <diff-file> [normalizer] -> "<binding> <patch>" on one line (empty on failure)
  local f="$1" norm="${2:-$DIFF_NORMALIZER}"
  ( DIFF_NORMALIZER="$norm"; source "$TMP/patchfn.sh"; diff_identity_pair "$f" ) 2>/dev/null | tr '\t' ' '
}
P="$TMP/patchid"; rm -rf "$P"; mkdir -p "$P"
Q="$TMP/patchdiffs"; rm -rf "$Q"; mkdir -p "$Q"
( cd "$P" || exit 9
  git init -q .; git config user.email t@t; git config user.name t
  printf 'l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\nl11\nl12\n' > f.txt
  printf 'untouched\n' > other.txt
  git add -A; git commit -qm base; git branch -M main
  git checkout -qb pr
  printf 'l1\nl2\nl3\nl4\nl5\nl6-PR\nl7\nl8\nl9\nl10\nl11\nl12\n' > f.txt
  git add -A; git commit -qm "the reviewed change" ) >/dev/null 2>&1 || true
( cd "$P" && git rev-parse --verify -q HEAD >/dev/null 2>&1 ) \
  && pass "(31) fixture repo built" || fail "(31) could not build the fixture repo"
cd "$P" || exit 2
REVIEWED31="$(git rev-parse HEAD)"
# main lands a change INSIDE the PR's hunk context (3 lines around l6 → l4 is one
# of them), on a DIFFERENT line, so the merge is clean and the PR's own change is
# untouched.
git checkout -q main
printf 'l1\nl2\nl3\nMAIN-4\nl5\nl6\nl7\nl8\nl9\nl10\nl11\nl12\n' > f.txt
git add -A; git commit -qm "main lands nearby work"
git checkout -q pr
git merge -q --no-edit main >/dev/null 2>&1 || true
CURRENT31="$(git rev-parse HEAD)"
[ "$REVIEWED31" != "$CURRENT31" ] \
  && pass "(31) the base move really moved the head" || fail "(31) fixture is wrong: the head did not move"
git diff --no-color --full-index "main...$REVIEWED31" > "$Q/a.diff"
git diff --no-color --full-index "main...$CURRENT31"  > "$Q/b.diff"
# PREMISE 1: the REVIEWED change is identical on both sides (context aside).
REV_LINES="$(grep -E '^[+-]' "$Q/a.diff" | grep -vE '^(\+\+\+|---)' | LC_ALL=C sort)"
CUR_LINES="$(grep -E '^[+-]' "$Q/b.diff" | grep -vE '^(\+\+\+|---)' | LC_ALL=C sort)"
[ -n "$REV_LINES" ] && [ "$REV_LINES" = "$CUR_LINES" ] \
  && pass "(31) the fixture's CHANGED LINES really are identical on both heads — the acceptance claim is not vacuous" \
  || fail "(31) fixture is wrong: the base move changed the changed lines"
# PREMISE 2: the CONTEXT really did move, or the pair would be byte-identical and
# the acceptance would be testing the OLD arm, not this one.
if grep -q 'MAIN-4' "$Q/b.diff" && ! grep -q 'MAIN-4' "$Q/a.diff"; then
  pass "(31) the rendered CONTEXT really moved (b carries main's new line, a does not) — the pair is not byte-identical"
else
  fail "(31) fixture is wrong: the context did not move, so this pair tests nothing new"
fi
PA="$(pair_of "$Q/a.diff")"; PB="$(pair_of "$Q/b.diff")"
[ -n "$PA" ] && [ -n "$PB" ] && pass "(31) the predicate read both real diffs" \
  || fail "(31) the predicate could not read the real diffs"
[ "${PA%% *}" != "${PB%% *}" ] \
  && pass "(31) BINDING: a real base move MOVES the evidence digest (#1377's premise, measured on git output)" \
  || fail "(31) the binding did not move — the premise is not exercised"
[ "${PA##* }" = "${PB##* }" ] \
  && pass "(31) PATCH: the same base move leaves the patch digest IDENTICAL — this is what the carry accepts" \
  || fail "(31) the patch digest moved on an unchanged change — the arm would refuse a legitimate carry"

# One changed LINE is not carried.
printf 'l1\nl2\nl3\nl4\nl5\nl6-PR-CHANGED\nl7\nl8\nl9\nl10\nl11\nl12\n' > f.txt
git add -A; git commit -qm "an edit"
EDIT31="$(git rev-parse HEAD)"
git diff --no-color --full-index "main...$EDIT31" > "$Q/c.diff"
PC="$(pair_of "$Q/c.diff")"
[ "${PB##* }" != "${PC##* }" ] \
  && pass "(31) a ONE-LINE change moves the patch digest — it must refuse (the refusal direction)" \
  || fail "(31) a one-line change kept the same patch digest — FAIL-OPEN"

# Whitespace only: the exact hole `git patch-id --stable` has.
printf 'l1\nl2\nl3\nl4\nl5\nl6-PR\t\nl7\nl8\nl9\nl10\nl11\nl12\n' > f.txt
git add -A; git commit -qm "whitespace only"
WS31="$(git rev-parse HEAD)"
git diff --no-color --full-index "main...$WS31" > "$Q/d.diff"
PD="$(pair_of "$Q/d.diff")"
[ "${PC##* }" != "${PD##* }" ] \
  && pass "(31) a WHITESPACE-ONLY change moves the patch digest (patch-id --stable would not)" \
  || fail "(31) a whitespace-only change kept the patch digest — the patch-id --stable hole is open"

# Same lines at a different path.
git checkout -q "$CURRENT31" 2>/dev/null || true
printf 'l1\nl2\nl3\nl4\nl5\nl6-PR\nl7\nl8\nl9\nl10\nl11\nl12\n' > moved.txt
git rm -q f.txt >/dev/null 2>&1 || true
git add -A; git commit -qm "move the change"
MOVED31="$(git rev-parse HEAD)"
git diff --no-color --full-index "main...$MOVED31" > "$Q/e.diff"
PE="$(pair_of "$Q/e.diff")"
[ "${PB##* }" != "${PE##* }" ] \
  && pass "(31) the same lines at a DIFFERENT PATH move the patch digest (the path is part of the identity)" \
  || fail "(31) a path move kept the patch digest — the identity ignores paths"

# ── 33. `--delta` (#3245): the verb sources its inputs from the RECORD, and refuses a non-approval ──
# NUMBERED 33, NOT 32, AND DELIBERATELY: main's #3347 landed its own section (32) — the
# `post_marker()` marker-present early return — between this branch's fork point and its rebase.
# Both sections were written independently as "32", so keeping the number would have put TWO
# sections and TWO sets of (32a)-(32e) labels in one file: a reader chasing "(32c)" would find a
# post_marker assertion and a delta assertion, and neither message would say which. The delta
# section moves; main's (32) keeps the number it already shipped under.
# The GAP this pins: the carry arms are only reachable from the stale-sha guard, so a lane that
# records at the LIVE head never enters it and pays for a full re-review. `--delta` reads the
# REVIEWED head AND the verdict from the record, then re-enters the SAME arms. Three facts are
# asserted here, and each is a REFUSAL or the ACCEPTANCE it exists for — never a narration:
#   (a) a conflict-free forward merge of main into the attested branch RE-BINDS, and the record
#       says `mint":"delta"` (never `fresh`) with the delta pair;
#   (b) a real authored commit landing in the same push is REFUSED and the record is untouched;
#   (c) a record whose verdict is not clean-family is REFUSED before any git work is done.
# The stub for THIS section answers what the verb reads (base sha, head sha, the diff, and an
# EMPTY check surface), which the suite-wide stub above does not.
echo "── 33. --delta reads the reviewed head and verdict from the RECORD"
DELTA_REPO="$(new_repo delta33)" || fail "(33) fixture repo could not be created"
DR_HOME="$TMP/dhome"; rm -rf "$DR_HOME"; mkdir -p "$DR_HOME/.pi/agent/reviews"
mkdir -p "$TMP/dbin"
cat > "$TMP/dbin/gh" <<'EOF'
#!/usr/bin/env bash
# ⛔ A REAL `gh` READS THE PAYLOAD. A stub that ignores `--input -` and exits leaves the
# WRITER (here `jq -n --arg body … |`) with EPIPE, and the recorder runs under
# `set -o pipefail`: the pipeline's status becomes the writer's failure, `post_marker`
# returns 1 and the run exits 5 (`body-marker-unposted`) even though the PATCH succeeded.
# MEASURED as an intermittent failure of (33a) — 1 of 3 runs, with the record written
# correctly and only the exit status flaking (the pipe lands in #3327's body-marker code,
# not in this PR's delta path). Draining stdin is what makes this fixture behave like the
# process it stands in for; it weakens no assertion.
case "$*" in
  *--input*) command cat >/dev/null 2>&1 || true ;;
esac
for x in "$@"; do
  case "$x" in
    .base.sha) echo "${FIX_BASE:-}"; exit 0 ;;
    .head.sha) echo "${FIX_HEAD:-}"; exit 0 ;;
    .body) echo ""; exit 0 ;;
  esac
done
case "$*" in
  *check-runs*) echo ""; exit 0 ;;
esac
case "$*" in
  *pulls/*)
    if [ -n "${FIX_HEAD:-}" ] && [ -n "${FIX_BASE:-}" ]; then
      git -C "${FIX_REPO:-.}" diff --no-color "$FIX_BASE...$FIX_HEAD" 2>/dev/null && exit 0
    fi ;;
esac
exit 0
EOF
chmod +x "$TMP/dbin/gh"
delta_write_record() { # <pr> <head> <verdict> [evidence|NONE] -> writes the record this verb reads
  # ⚠️ A REAL `clean` record CARRIES `evidence` — it is minted from a posted review artifact
  # (tortoise#7391), and #10177/#3327 (landed on main AFTER this PR was written) now REFUSES
  # to carry a `clean` verdict whose record names no review artifact. The first cut of this
  # fixture omitted the field, so after the rebase the acceptance case started refusing at
  # `carry-provenance` — correctly. The fixture was made realistic rather than the gate
  # loosened, and `NONE` deliberately writes the field-free record so the refusal direction
  # can be pinned: see (33e).
  local ev="${4:-comment:9000001}" evjson
  evjson="\"evidence\":\"$ev\","
  [ "$ev" = "NONE" ] && evjson=""
  printf '{"pr":%s,"head_sha":"%s","diff_sha256":"%s","mint":"fresh","verdict":"%s","repo":"fixture/repo",%s"reviewed_at":"2026-11-02T00:00:00Z"}\n' \
    "$1" "$2" "$(printf 'x' | openssl dgst -sha256 | awk '{print $NF}')" "$3" "$evjson" \
    > "$DR_HOME/.pi/agent/reviews/fixture-repo-$1.json"
}
# THE STATUS MUST BE CAPTURED OUTSIDE A SUBSHELL. Every call site wants BOTH the
# output and the exit status, and `OUT="$(delta_run ...)"; rc=$?` captures the
# substitution's status but LOSES an assignment made inside it. A first cut did
# exactly that and `$DR_RC` was unbound at the first read, killing the suite under
# `set -u` BEFORE any assertion printed: three dead assertions that could neither
# pass nor report a fail. So the verb writes its output to a FILE and the status is
# assigned in the caller's shell.
delta_run() { # <pr> <out-file> ; assigns DR_RC, leaves output in <out-file>
  ( cd "$DELTA_REPO" || exit 9
    HOME="$DR_HOME" PATH="$TMP/dbin:$PATH" FIX_REPO="$DELTA_REPO" \
    FIX_BASE="$(git rev-parse main)" FIX_HEAD="${FIX_DELTA_HEAD:?}" \
      bash "$SRC" --delta "$1" fixture/repo ) > "$2" 2>&1
  DR_RC=$?
}
if [ -d "$DELTA_REPO" ]; then
  # ⛔ ON `main`, NOT ON `pr`. `new_repo` leaves HEAD on the `pr` branch, so an
  # advance committed without switching lands as a LANE commit and `git merge main`
  # is then "Already up to date" — the fixture would never build the topology this
  # section claims, and the acceptance case would assert about a one-parent head.
  ( cd "$DELTA_REPO" || exit 9; git checkout -q main; printf 'main advance\n' > adv.txt; git add -A; git commit -qm "main: advance" ) >/dev/null 2>&1
  ( cd "$DELTA_REPO" || exit 9; git checkout -q pr; git merge --no-ff -q main -m "merge main into pr" ) >/dev/null 2>&1
  D_BASE="$( cd "$DELTA_REPO" && git rev-parse main )"
  D_REVIEWED="$( cd "$DELTA_REPO" && git rev-parse pr^1 )"
  D_MERGED="$( cd "$DELTA_REPO" && git rev-parse pr )"
  delta_write_record 7101 "$D_REVIEWED" clean
  FIX_DELTA_HEAD="$D_MERGED"; delta_run 7101 "$TMP/out32a"; OUT32="$(cat "$TMP/out32a")"; DRC_A="$DR_RC"
  D_REC32="$(cat "$DR_HOME/.pi/agent/reviews/fixture-repo-7101.json" 2>/dev/null)"
  [ "$DRC_A" -eq 0 ] && [ "$(printf '%s' "$D_REC32" | grep -c '"mint":"delta"')" = 1 ] \
    && [ "$(printf '%s' "$D_REC32" | grep -c "\"head_sha\":\"$D_MERGED\"")" = 1 ] \
    && [ "$(printf '%s' "$D_REC32" | grep -c '"evidence":"comment:9000001"')" = 1 ] \
    && pass "(33a) a conflict-free forward merge RE-BINDS, and the record says mint=delta at the new head AND keeps the review artifact its verdict rests on" \
    || fail "(33a) the delta was not rebound as a delta (rc=$DRC_A, record='$D_REC32', out='$OUT32')"
  # (33a2) THE RECORD SHAPE IS THE CONTRACT, so it is PINNED rather than described. `proved` exists
  # because the field it replaced (`authored_unchanged:true`, hardcoded) was contradicted by the
  # SAME run's triple on the lane path — and the lane arm must emit NEITHER `authored_unchanged`
  # (it never measured the authored digest) NOR the reverse: it DOES measure `conflicts` (clause D
  # recomputes the merge), so it claims that one. Without this assertion a later edit could revert
  # `proved` to a hardcoded claim and the suite would stay green, which is exactly how the field
  # lied the first time.
  [ "$(printf '%s' "$D_REC32" | grep -c '"proved":"lane"')" = 1 ] \
    && [ "$(printf '%s' "$D_REC32" | grep -c '"arm":"lane"')" = 1 ] \
    && [ "$(printf '%s' "$D_REC32" | grep -c 'authored_unchanged')" = 0 ] \
    && [ "$(printf '%s' "$D_REC32" | grep -c '"conflicts":0')" = 1 ] \
    && pass "(33a2) the record NAMES what the arm proved (proved/arm=lane, conflicts:0 measured by clause D, NO authored_unchanged claim) — the shape is pinned, not just described" \
    || fail "(33a2) the delta record's proof fields are wrong (record='$D_REC32')"
  # (33a3) THE TRIPLE'S VALUES, not just its presence. 33d greps `^zero-conflict=` to prove the line
  # is REACHABLE; that cannot notice the field degrading to `no`/`UNMEASURED` on an ACCEPTED delta.
  # On the lane path clause (C2) and clause (D) both require `yes`, so both are asserted; the
  # authored digest is deliberately NOT asserted `yes` here — the lane arm leaves it free to differ
  # (that is why `proved` exists), so only its presence is required.
  # ⛔ NO PIPE TO SIGPIPE. This file runs under `set -uo pipefail` (line 43), so
  # `printf … | grep -q` is racy: `grep -q` exits on its FIRST match and can close the
  # pipe before `printf` finishes writing, which makes the PIPELINE 141 and reddens the
  # whole suite under pipefail. MEASURED: `rc=141` in 2 of 400 idle iterations, and 1 of
  # 3 concurrent suite runs failed exactly here. A here-string has no writer process to
  # signal, so the assertion can only fail for a reason it asserts.
  grep -qx 'zero-conflict=yes.*' <<<"$OUT32" \
    && grep -qx 'no-new-authored-commits=yes commits=0' <<<"$OUT32" \
    && grep -q '^authored-digest-equal=' <<<"$OUT32" \
    && pass "(33a3) the ACCEPTED lane delta prints zero-conflict=yes and no-new-authored-commits=yes commits=0 (the two facts its own clauses require), plus the authored-digest line" \
    || fail "(33a3) the accepted delta's triple does not carry the values its clauses require (out='$OUT32')"
  # (33a4) THE PROOF-FIELD MAPPING, ALL THREE ARMS, pinned as a UNIT. (33a2) can only
  # exercise whichever arm the fixture happens to drive, and this suite has NO marker
  # fixture (no HMAC/`AI_REVIEW_GATE_KEY` anywhere), so the `patch` and `diff` arms are
  # unreachable from a behavioural test here. Without this, keying `conflicts:0` on
  # `lane|diff)` stayed GREEN — the exact mutant that put an unmeasured claim back in the
  # record. Extracted the way §31 extracts `diff_identity_pair`, so the pin cannot pass
  # against a function the script no longer has.
  awk '/^delta_proof_fields\(\) \{/,/^\}$/' "$SRC" > "$TMP/prooffn.sh"
  if grep -q 'delta_proof_fields()' "$TMP/prooffn.sh"; then
    # shellcheck disable=SC1090
    . "$TMP/prooffn.sh"
    [ "$(delta_proof_fields lane)" = '"conflicts":0,' ] \
      && [ "$(delta_proof_fields patch)" = '"authored_unchanged":true,' ] \
      && [ "$(delta_proof_fields diff)" = '"authored_unchanged":true,' ] \
      && [ -z "$(delta_proof_fields unknown)" ] \
      && pass "(33a4) lane claims conflicts:0 ONLY; patch/diff claim authored_unchanged ONLY; an unknown arm claims NOTHING — the mapping is one definition, not three inline cases" \
      || fail "(33a4) delta_proof_fields mis-keys an arm: lane='$(delta_proof_fields lane)' patch='$(delta_proof_fields patch)' diff='$(delta_proof_fields diff)'"
  else
    fail "(33a4) delta_proof_fields() could not be extracted from record-review.sh — re-anchor the pin rather than dropping it"
  fi
  # (33a7) THE TWO `delta` FEATURES MUST NOT WRITE EACH OTHER'S FIELDS. The `--delta` verb (#10583) and
  # `--evidence delta:<A>..<B>` (#3299) landed from opposite sides of the same file, and both
  # put a `delta`-named thing into the SAME signed record while asserting DIFFERENT claims: the
  # verb writes `delta{from,to,proved,arm}` ("the head moved, the authored change did not"),
  # the evidence arm writes `delta_range`/`delta_base`/`delta_kind`/`delta_digest` ("a reviewer's
  # verdict covers A..B"). The evidence arm's builder fired on `[ -n "$DELTA_FROM" ]`, and the
  # verb set `DELTA_FROM` too — so when the two trees merged, every `--delta` record silently
  # gained `"delta_range":"<head>.."` with an EMPTY upper bound, an empty base and EMPTY
  # kind/digest. That is a signed record asserting a range a reviewer never covered, written by
  # a verb whose whole contract is that NO reviewer ran. Nothing else in either feature's tests
  # could see it: they each assert their OWN fields' presence, never the other's absence.
  ! grep -q 'delta_range\|delta_base\|delta_kind\|delta_digest' <<<"$D_REC32" \
    && pass "(33a7) a --delta record carries NONE of the evidence arm's fields (delta_range/delta_base/delta_kind/delta_digest) — the two delta features share no record field and no global" \
    || fail "(33a7) the --delta record carries an EVIDENCE-arm delta field it never measured (record='$D_REC32')"
  # (33a5) THE `from` AXIS (#3247 review, P1). The record's `delta.from` must name the head
  # the DECIDING ARM measured, never automatically the record's head: `diff` measures from
  # the prior MARKER's head and `patch` from `PRIOR_PATCH_SHA`, and asserting
  # `authored_unchanged` over a pair the run did not measure is a signed claim about
  # nothing. MEASURED before the fix: record `from=<record head>` + `authored_unchanged:true`
  # while the same run's triple printed `authored-digest-equal=no` and `commits=2`. All four
  # shapes are asserted, including the fallback when an arm's head is unavailable.
  awk '/^delta_measured_from\(\) \{/,/^\}$/' "$SRC" > "$TMP/fromfn.sh"
  if grep -q 'delta_measured_from()' "$TMP/fromfn.sh"; then
    # shellcheck disable=SC1090
    . "$TMP/fromfn.sh"
    D_RECHEAD="1111111111111111111111111111111111111111"; D_DSHA="2222222222222222222222222222222222222222"; D_PSHA="3333333333333333333333333333333333333333"
    [ "$(delta_measured_from diff  "$D_RECHEAD" "$D_DSHA" "$D_PSHA")" = "$D_DSHA" ] \
      && [ "$(delta_measured_from patch "$D_RECHEAD" "$D_DSHA" "$D_PSHA")" = "$D_PSHA" ] \
      && [ "$(delta_measured_from lane  "$D_RECHEAD" "$D_DSHA" "$D_PSHA")" = "$D_RECHEAD" ] \
      && [ "$(delta_measured_from diff  "$D_RECHEAD" "" "$D_PSHA")" = "$D_RECHEAD" ] \
      && pass "(33a5) delta.from names the head the ARM measured (diff→marker head, patch→patch head, lane→record head), and falls back to the record head when that arm's head is absent" \
      || fail "(33a5) delta_measured_from does not name the measured head per arm (diff='$(delta_measured_from diff "$D_RECHEAD" "$D_DSHA" "$D_PSHA")' patch='$(delta_measured_from patch "$D_RECHEAD" "$D_DSHA" "$D_PSHA")' lane='$(delta_measured_from lane "$D_RECHEAD" "$D_DSHA" "$D_PSHA")')"
  else
    fail "(33a5) delta_measured_from() could not be extracted from record-review.sh — re-anchor the pin rather than dropping it"
  fi
  # (33a6) THE ACCEPTED DIRECTION, CHECKED BY THE READER — not just described by the writer
  # (#3247 review, P2). Everything above asserts what the WRITER emitted, and (33f2) runs
  # `--check-carry` only over the record `--delta` is supposed to REFUSE. Nothing ran the reader
  # over the record the delta just minted, so a regression that stopped writing the top-level
  # `carry_arm` would make every genuine delta answer `norecord`/exit 4 at the merge gate — the
  # feature silently INERT — while this suite stayed green: (33a)/(33a2) never look at
  # `carry_arm`, and (33f2) only proves the reader agrees about a record nothing should produce.
  # It is the PAIR that is asserted, not the word: `--check-carry` requires `carry_arm` AND
  # `evidence` of a `mint:"delta"` record (scripts/record-review.sh:4319-4328, the
  # `case "${CC_MINT:-}" in` arm) BEFORE it head-binds at :4354, so a delta record missing
  # either is a no-record for the gate. Each citation also carries its own ANCHOR string:
  # these numbers move whenever record-review.sh moves, and a re-derivation that was not
  # re-checked at the head has already landed here wrong twice. The anchor is what stays
  # true — `grep -n 'case "${CC_MINT:-}" in' scripts/record-review.sh` and
  # `grep -n 'CC_HEAD" = "$CC_LIVE_HEAD' scripts/record-review.sh` re-derive both in one step.
  D_REC_A6="$(cat "$DR_HOME/.pi/agent/reviews/fixture-repo-7101.json" 2>/dev/null)"
  CC_RC_A6=0
  CC_OUT_A6="$( cd "$DELTA_REPO" || exit 9
    HOME="$DR_HOME" PATH="$TMP/dbin:$PATH" FIX_REPO="$DELTA_REPO" \
    FIX_BASE="$D_BASE" FIX_HEAD="$D_MERGED" \
      bash "$SRC" --check-carry 7101 fixture/repo 2>/dev/null )" || CC_RC_A6=$?
  [ "$CC_RC_A6" -eq 0 ] \
    && [ "${CC_OUT_A6%%$'\t'*}" = "head" ] \
    && [ "$(grep -c '"carry_arm":"lane"' <<<"$D_REC_A6")" = 1 ] \
    && [ "$(grep -c '"evidence":"comment:9000001"' <<<"$D_REC_A6")" = 1 ] \
    && pass "(33a6) the ACCEPTED delta record is accepted BY THE READER: --check-carry answers head/exit 0 for it, and the record carries top-level carry_arm=lane AND evidence — so the merge gate cannot classify a real delta as norecord" \
    || fail "(33a6) the record the delta minted is not one --check-carry accepts (rc=$CC_RC_A6, out='$CC_OUT_A6', record='$D_REC_A6')"
  # (b) one real authored commit on top of the merge: authorship moved, so a review is owed.
  ( cd "$DELTA_REPO" || exit 9; printf 'lane fix\n' >> lane.txt; git add -A; git commit -qm "lane: a real fix commit" ) >/dev/null 2>&1
  D_FIXED="$( cd "$DELTA_REPO" && git rev-parse pr )"
  delta_write_record 7102 "$D_REVIEWED" clean
  FIX_DELTA_HEAD="$D_FIXED"; delta_run 7102 "$TMP/out32b"; OUT32B="$(cat "$TMP/out32b")"; DRC_B="$DR_RC"
  # NOTE the `<<<` form on every assertion below: this file runs under `set -uo pipefail`, and
  # `printf … | grep -q` is racy there (`grep -q` exits on its FIRST match and can SIGPIPE the
  # writer, making the pipeline 141). (33a3) de-pipes for exactly that reason and states the
  # measurement; a fresh review MEASURED the same flake still present in these six (54 of 1500 runs
  # of the (33d) chain), so they are de-piped too rather than left as the one spot the fix missed.
  [ "$DRC_B" -eq 3 ] && grep -q 'no-new-authored-commits=no' <<<"$OUT32B" \
    && [ "$(grep -c "\"head_sha\":\"$D_REVIEWED\"" "$DR_HOME/.pi/agent/reviews/fixture-repo-7102.json")" = 1 ] \
    && pass "(33b) an authored commit landing in the same push is REFUSED and the record is untouched" \
    || fail "(33b) an authored commit was re-attested (rc=$DRC_B)"
  # (c) a record that is not an approval: a delta re-binds an APPROVAL, it cannot manufacture one.
  delta_write_record 7103 "$D_REVIEWED" changes-requested
  FIX_DELTA_HEAD="$D_MERGED"; delta_run 7103 "$TMP/out32c"; OUT32C="$(cat "$TMP/out32c")"; DRC_C="$DR_RC"
  [ "$DRC_C" -eq 3 ] && grep -q 'not a clean-family verdict' <<<"$OUT32C" \
    && pass "(33c) a non-clean record is REFUSED before any git work — a delta cannot manufacture an approval" \
    || fail "(33c) a non-clean verdict was re-bound as a clean attestation (rc=$DRC_C)"
  # (d) A RECORD NAMING AN ABSENT HEAD — pruned, cross-box, or force-pushed away. This is the
  # assertion that keeps the delta-measure triple REACHABLE: MEASURED before the fix, the run exited
  # 1 with the triple truncated after `authored-digest-equal=UNMEASURED(…)`, because
  # `mt_raw="$(command git merge-tree …)"; m_rc=$?` is ONE command under `set -e` — the substitution's
  # status (1: `merge-tree: <sha> - not something we can merge`) aborted the shell before `m_rc` was
  # read, so `zero-conflict=` and `no-new-authored-commits=` never printed and an intended exit 3 came
  # out as a crash. All three fields, the status, AND the untouched record are asserted, so this
  # branch cannot silently become unreachable again.
  D_ABSENT="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
  delta_write_record 7104 "$D_ABSENT" clean
  FIX_DELTA_HEAD="$D_MERGED"; delta_run 7104 "$TMP/out32d"; OUT32D="$(cat "$TMP/out32d")"; DRC_D="$DR_RC"
  [ "$DRC_D" -eq 3 ] \
    && grep -q '^authored-digest-equal=' <<<"$OUT32D" \
    && grep -q '^zero-conflict=' <<<"$OUT32D" \
    && grep -q '^no-new-authored-commits=' <<<"$OUT32D" \
    && [ "$(grep -c "\"head_sha\":\"$D_ABSENT\"" "$DR_HOME/.pi/agent/reviews/fixture-repo-7104.json")" = 1 ] \
    && pass "(33d) an ABSENT record head REFUSES at exit 3 and prints all THREE delta fields — a set -e abort on the merge-tree assignment used to truncate the triple into a crash" \
    || fail "(33d) absent-head refusal did not print the full triple at exit 3 (rc=$DRC_D, out='$OUT32D')"
  # (e) NO REVIEW ARTIFACT, NO DELTA. `--delta` re-binds an APPROVAL, and main's #10177 requires
  # every carry to name the review artifact the verdict rests on. A delta is a carry (it re-binds
  # a verdict minted at another head), so the same refusal must reach it — otherwise the delta
  # verb becomes the one carry path that can re-bind a `clean` onto a tree with nothing in the
  # record a reader could check, which is exactly the shape tortoise#10677 produced. The record
  # must be LEFT ALONE (nothing written, no marker posted).
  delta_write_record 7105 "$D_REVIEWED" clean NONE
  FIX_DELTA_HEAD="$D_MERGED"; delta_run 7105 "$TMP/out32e"; OUT32E="$(cat "$TMP/out32e")"; DRC_E="$DR_RC"
  [ "$DRC_E" -eq 3 ] && grep -q 'carry-provenance' <<<"$OUT32E" \
    && [ "$(grep -c "\"head_sha\":\"$D_REVIEWED\"" "$DR_HOME/.pi/agent/reviews/fixture-repo-7105.json")" = 1 ] \
    && pass "(33e) a delta whose record names NO review artifact is REFUSED (exit 3) and the record is untouched — a carry cannot re-bind a clean verdict with no evidence" \
    || fail "(33e) a delta with no review artifact was re-bound (rc=$DRC_E, out='$OUT32E')"
  # (f) AN UNPROVEN `delta` RECORD IS NOT A RECORD — the predicate this PR added, and the pin it
  # did not have. `--check-carry` (#10177) answers `norecord` (exit 4) for a `carried`/`delta`
  # record naming no `carry_arm` and no `evidence`; `--delta` had no such rule and answered
  # "ALREADY bound … Land it" with **exit 0** over that exact record. MEASURED as the gap: deleting
  # the predicate left the suite GREEN (`ALL PASSED (192)`), so the one fix the body headlines as
  # closing a false PASS had no test at all. The record is at the LIVE head on purpose — that is
  # what makes the already-bound short circuit the thing the predicate has to pre-empt.
  printf '{"pr":7106,"head_sha":"%s","diff_sha256":"%s","mint":"delta","carried_from":"%s","delta":{"from":"%s","to":"%s","proved":"lane","arm":"lane"},"verdict":"clean","repo":"fixture/repo","reviewed_at":"2026-11-02T00:00:00Z"}\n' \
    "$D_MERGED" "$(printf 'x' | openssl dgst -sha256 | awk '{print $NF}')" "$D_REVIEWED" "$D_REVIEWED" "$D_MERGED" \
    > "$DR_HOME/.pi/agent/reviews/fixture-repo-7106.json"
  D_REC32F="$(cat "$DR_HOME/.pi/agent/reviews/fixture-repo-7106.json")"
  FIX_DELTA_HEAD="$D_MERGED"; delta_run 7106 "$TMP/out32f"; OUT32F="$(cat "$TMP/out32f")"; DRC_F="$DR_RC"
  [ "$DRC_F" -eq 4 ] \
    && [ "$(cat "$DR_HOME/.pi/agent/reviews/fixture-repo-7106.json")" = "$D_REC32F" ] \
    && pass "(33f) a delta over an UNPROVEN delta record REFUSES at exit 4 (norecord) and writes nothing — it cannot inherit an approval --check-carry rejects" \
    || fail "(33f) an unproven delta record was re-bound (rc=$DRC_F, out='$OUT32F', record='$(cat "$DR_HOME/.pi/agent/reviews/fixture-repo-7106.json" 2>/dev/null)')"
  # (33f2) THE TWO VERBS CANNOT DISAGREE ABOUT ONE RECORD — the invariant the fix exists for, so
  # it is asserted against BOTH verbs instead of inferred from one of them. `--check-carry` is
  # READ-ONLY, so running it second also proves it left the same bytes on disk.
  CC_RC=0
  CC_OUT32F="$( cd "$DELTA_REPO" || exit 9
    HOME="$DR_HOME" PATH="$TMP/dbin:$PATH" FIX_REPO="$DELTA_REPO" \
    FIX_BASE="$(git rev-parse main)" FIX_HEAD="$D_MERGED" \
      bash "$SRC" --check-carry 7106 fixture/repo 2>/dev/null )" || CC_RC=$?
  [ "$CC_RC" -eq 4 ] && [ "${CC_OUT32F%%$'\t'*}" = "norecord" ] \
    && [ "$(cat "$DR_HOME/.pi/agent/reviews/fixture-repo-7106.json")" = "$D_REC32F" ] \
    && pass "(33f2) --check-carry answers norecord/exit 4 for the SAME record --delta refused — one artifact, one answer, from both verbs" \
    || fail "(33f2) the two verbs disagree about an unproven delta record (check-carry rc=$CC_RC out='$CC_OUT32F')"
  # (g) A DELTA THAT MEASURED NOTHING MUST NOT MINT A FRESH RECORD — the false PASS a fresh review
  # found at 426ac51b, and the reason it found it is that nothing pinned this path. Every delta
  # refusal lives INSIDE the stale-sha chain (`elif [ "$CURRENT_HEAD" != "$SHA" ]`), so a run that
  # never enters that chain executes NO delta predicate — and the record write is UNCONDITIONAL.
  # The #7391 evidence gate cannot catch it either, because that gate is keyed on `VERDICT = clean`
  # while `clean-micro`/`clean-low` are clean-FAMILY but not `clean`. The fixture below therefore
  # uses **clean-micro** on purpose: it is the verdict a delta most often carries and the one the
  # evidence gate does not cover.
  # The lever is the SECOND `.head.sha` read (reached only after the delta block's own first read),
  # so the verb gets past `DELTA-PAIR` and then cannot confirm the live head — the documented #784
  # fail-open path, which is exactly where the shipped code used to fall through to the write.
  mkdir -p "$TMP/dbin-failhead"
  cat > "$TMP/dbin-failhead/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in *--input*) command cat >/dev/null 2>&1 || true ;; esac
for x in "$@"; do
  case "$x" in
    .head.sha)
      n="$(cat "${FAILHEAD_COUNTER:?}" 2>/dev/null || echo 0)"; n=$((n+1)); printf '%s' "$n" > "$FAILHEAD_COUNTER"
      if [ "$n" -ge 2 ]; then exit 1; fi
      echo "${FIX_HEAD:-}"; exit 0 ;;
    .base.sha) echo "${FIX_BASE:-}"; exit 0 ;;
    .body) echo ""; exit 0 ;;
  esac
done
case "$*" in *check-runs*) echo ""; exit 0 ;; esac
case "$*" in *pulls/*) if [ -n "${FIX_HEAD:-}" ] && [ -n "${FIX_BASE:-}" ]; then git -C "${FIX_REPO:-.}" diff --no-color "$FIX_BASE...$FIX_HEAD" 2>/dev/null && exit 0; fi ;; esac
exit 0
EOF
  chmod +x "$TMP/dbin-failhead/gh"
  delta_run_with() { # <script> <bindir> <pr> <out-file> ; assigns DR_RC
    ( cd "$DELTA_REPO" || exit 9
      HOME="$DR_HOME" PATH="$2:$PATH" FIX_REPO="$DELTA_REPO" FAILHEAD_COUNTER="$TMP/failhead.n" \
      FIX_BASE="$(git rev-parse main)" FIX_HEAD="${FIX_DELTA_HEAD:?}" \
        bash "$1" --delta "$3" fixture/repo ) > "$4" 2>&1
    DR_RC=$?
  }
  delta_write_record 7107 "$D_REVIEWED" clean-micro
  D_REC32G="$(cat "$DR_HOME/.pi/agent/reviews/fixture-repo-7107.json")"
  FIX_DELTA_HEAD="$D_MERGED"; : > "$TMP/failhead.n"
  delta_run_with "$SRC" "$TMP/dbin-failhead" 7107 "$TMP/out32g"; OUT32G="$(cat "$TMP/out32g")"; DRC_G="$DR_RC"
  [ "$DRC_G" -eq 3 ] \
    && grep -q 'no carry arm ran, so NOTHING was re-attested' <<<"$OUT32G" \
    && [ "$(cat "$DR_HOME/.pi/agent/reviews/fixture-repo-7107.json")" = "$D_REC32G" ] \
    && pass "(33g) a delta whose live head could not be MEASURED refuses at exit 3 and leaves the record BYTE-IDENTICAL — it cannot mint a fresh record, drop the prior evidence, and post a marker on a successful exit" \
    || fail "(33g) an unmeasurable delta wrote a record (rc=$DRC_G, out='$OUT32G', record='$(cat "$DR_HOME/.pi/agent/reviews/fixture-repo-7107.json" 2>/dev/null)')"
  # (33g2) ATTRIBUTION, MEASURED RATHER THAN ARGUED: the same scenario against a mutant with the
  # post-condition DELETED must STOP REFUSING FOR THIS REASON. Without it, (33g) could be passing
  # because of some pre-existing refusal — the exact way a "pin" for this file's headline fix was
  # already found to be green under deletion once.
  # ⚠️ WHAT THIS FIXTURE DOES AND DOES NOT ESTABLISH, stated so the arm cannot be read as more: on
  # THIS stub the mutant's fall-through is then stopped by a DIFFERENT guard — the #513 clean-micro
  # surface cap, exit 4, because the stub serves no readable changed-path payload — so the fixture
  # proves the (33g) refusal is ATTRIBUTABLE to the post-condition (rc 3 + that message) and that
  # removing the post-condition removes it. It does NOT reproduce the full write on this host; the
  # end-to-end shape (rc 0, record overwritten, prior `evidence` dropped, marker posted) was measured
  # by the fresh review that found this defect, using a stub that DOES serve a readable surface. The
  # assertion below therefore keys on WHAT CHANGED, never on the mutant's final exit code.
  python3 - "$SRC" "$TMP/nodelta-postcond.sh" <<'INNERPY' || true
import sys
src = open(sys.argv[1], encoding="utf-8").read().split("\n")
out, i, dropped = [], 0, 0
needle = 'if [ "$DELTA" -eq 1 ] && [ -z "$CARRY_ARM" ]; then'
while i < len(src):
    if src[i] == needle:
        # drop the whole if-block up to and including its terminating `fi`
        depth = 1
        i += 1
        while i < len(src) and depth > 0:
            if src[i].rstrip() == 'fi':
                depth -= 1
                if depth == 0:
                    i += 1
                    break
            i += 1
        dropped += 1
        continue
    out.append(src[i])
    i += 1
open(sys.argv[2], "w", encoding="utf-8").write("\n".join(out))
print(f"mutant: dropped {dropped} post-condition(s)")
INNERPY
  # ⛔ THE MUTANT'S EXISTENCE IS PART OF THE ASSERTION (#3247 review, P3). `bash "$1"` on a path
  # that was never written exits **127**, which satisfies `[ rc -ne 3 ]` and greps for a message no
  # mutant could print — so a heredoc that failed outright would report ATTRIBUTION having mutated
  # nothing. That is this suite's own recurring defect (an arm green because the thing it measures
  # never ran), so the guards come FIRST and name it.
  if [ ! -f "$TMP/nodelta-postcond.sh" ]; then
    fail "(33g2) the mutant was never WRITTEN (the deletion heredoc failed), so 'no refusal' would be bash's 127 on a missing file rather than a measurement — attribution is unproven"
  elif [ ! -s "$TMP/nodelta-postcond.sh" ]; then
    fail "(33g2) the mutant is EMPTY — running it proves nothing about the post-condition"
  elif grep -q 'no carry arm ran' "$TMP/nodelta-postcond.sh"; then
    fail "(33g2) the mutant still contains the post-condition — the deletion did not land, so attribution is unproven"
  else
    delta_write_record 7108 "$D_REVIEWED" clean-micro
    FIX_DELTA_HEAD="$D_MERGED"; : > "$TMP/failhead.n"
    delta_run_with "$TMP/nodelta-postcond.sh" "$TMP/dbin-failhead" 7108 "$TMP/out32g2"; OUT32G2="$(cat "$TMP/out32g2")"; DRC_G2="$DR_RC"
    [ "$DRC_G2" -ne 3 ] \
      && ! grep -q 'no carry arm ran' <<<"$OUT32G2" \
      && pass "(33g2) ATTRIBUTION: with the post-condition DELETED the same run no longer refuses at 3 nor emits the message (rc=$DRC_G2 — stopped later by this fixture's clean-micro surface cap), so (33g)'s refusal is the post-condition's own and not a pre-existing one" \
      || fail "(33g2) the mutant reproduced the (33g) refusal without the post-condition (rc=$DRC_G2, out='$OUT32G2'), so (33g) is attributable to something else"
  fi
  # (33h) ONE VERB PER INVOCATION — ONE ASSERTION PER COMBINATION (#3247 review, P1).
  #
  # ⛔ THIS IS THE ARM THAT WAS MISSING, AND IT WAS MISSING IN THE WAY THIS SUITE KEEPS
  # BEING BITTEN. Every `--delta` invocation in BOTH suites was the bare
  # `--delta <pr> fixture/repo` form (`scripts/record-review.test.sh` contained no `--delta`
  # at all), so deleting `|| [ "$DELTA" -eq 1 ]` from the one-verb guard — or dropping the
  # `[ "$DELTA" -eq 1 ] && [ "${#POSITIONAL[@]}" -gt 2 ]` arity guard, or the delta arm of the
  # `--evidence/--force-stale/--expect-head` refusal — reddened NOTHING while restoring exactly
  # the false PASS the guard comment at `:2784-2788` (`--delta IS A MINTING VERB TOO` —
  # `grep -n 'IS A MINTING VERB TOO' scripts/record-review.sh` re-derives it)
  # says was MEASURED (`--delta
  # --print-diff-hash` exited 0 with the record untouched; `--delta --check-carry` answered
  # `fresh … run the code-review skill`, i.e. the paid re-review the verb exists to remove).
  # The in-repo standard for this guard class already existed — `--recover-body`'s combinations
  # are pinned assertion-per-combo in `scripts/record-review.test.sh:3371-3384`, the
  # `for _combo in --print-diff-hash --print-tier` loop — so this section
  # meets that standard instead of describing it.
  #
  # THE FIXTURE IS THE ACCEPTANCE TOPOLOGY ON PURPOSE: record at `$D_REVIEWED`, live head
  # `$D_MERGED`, i.e. the exact pair (33a) proves exits 0 and MINTS. So if a guard were deleted
  # and the extra argument silently ignored, the run would exit 0 and WRITE — which is why each
  # arm asserts the record is BYTE-IDENTICAL as well as the exit code. A refusal that still wrote
  # would be the false PASS, not the refusal.
  delta_run_extra() { # <pr> <out-file> <extra args...> ; assigns DR_RC — same env as delta_run
    local _pr="$1" _out="$2"
    shift 2
    ( cd "$DELTA_REPO" || exit 9
      HOME="$DR_HOME" PATH="$TMP/dbin:$PATH" FIX_REPO="$DELTA_REPO" \
      FIX_BASE="$(git rev-parse main)" FIX_HEAD="${FIX_DELTA_HEAD:?}" \
        bash "$SRC" --delta "$_pr" fixture/repo "$@" ) > "$_out" 2>&1
    DR_RC=$?
  }
  d_h_expect2() { # <label> <expected-message-fragment> <args...>
    local _label="$1" _msg="$2"
    shift 2
    delta_run_extra 7109 "$TMP/out33h" "$@"
    local _rc="$DR_RC" _now _bytes
    _now="$(cat "$DR_HOME/.pi/agent/reviews/fixture-repo-7109.json" 2>/dev/null)"
    if [ "$_now" = "$D_H_REC" ]; then _bytes="UNCHANGED"; else _bytes="CHANGED"; fi
    if [ "$_rc" -eq 2 ] && [ "$_bytes" = "UNCHANGED" ] && grep -qF -- "$_msg" "$TMP/out33h"; then
      pass "(33h) $_label is REFUSED at exit 2 and the record is BYTE-IDENTICAL — the mixed-verb shape that would exit 0 having re-attested nothing"
    else
      fail "(33h) $_label was NOT refused as a one-verb violation (rc=$_rc, record $_bytes, out='$(head -c 400 "$TMP/out33h" 2>/dev/null)')"
    fi
  }
  delta_write_record 7109 "$D_REVIEWED" clean
  D_H_REC="$(cat "$DR_HOME/.pi/agent/reviews/fixture-repo-7109.json")"
  FIX_DELTA_HEAD="$D_MERGED"
  d_h_expect2 '--delta --print-diff-hash' \
    '--delta MINTS a record and cannot be combined with --check-carry/--print-diff-hash/--print-tier' \
    --print-diff-hash
  d_h_expect2 '--delta --check-carry' \
    '--delta MINTS a record and cannot be combined with --check-carry/--print-diff-hash/--print-tier' \
    --check-carry
  d_h_expect2 '--delta --print-tier' \
    '--delta MINTS a record and cannot be combined with --check-carry/--print-diff-hash/--print-tier' \
    --print-tier
  d_h_expect2 '--delta --flush-pending' \
    '--flush-pending is its own verb' \
    --flush-pending
  d_h_expect2 '--delta --recover-body' \
    'both MINT a record' \
    --recover-body
  d_h_expect2 '--delta --evidence' \
    'so it takes no --evidence/--force-stale/--expect-head' \
    --evidence 'comment:9'
  d_h_expect2 '--delta --force-stale' \
    'so it takes no --evidence/--force-stale/--expect-head' \
    --force-stale
  d_h_expect2 '--delta --expect-head' \
    'so it takes no --evidence/--force-stale/--expect-head' \
    --expect-head "$D_MERGED"
  d_h_expect2 '--delta with a third positional (a caller-supplied head/verdict)' \
    'takes <pr> [owner/repo] and nothing else' \
    clean
else
  fail "(33a) fixture missing"; fail "(33b) fixture missing"; fail "(33c) fixture missing"; fail "(33d) fixture missing"; fail "(33e) fixture missing"; fail "(33f) fixture missing"; fail "(33f2) fixture missing"; fail "(33g) fixture missing"; fail "(33g2) fixture missing"; fail "(33h) fixture missing"
fi

# ── MUTATION PINS on real output ──────────────────────────────────────────
# A mutant projection that KEEPS context must make the acceptance assertion
# redden: otherwise the acceptance would pass for a projection that never
# dropped anything.
mkdir -p "$TMP/pmut-ctx"
python3 - "$ROOT/scripts/lib/diff-normalize.py" "$TMP/pmut-ctx/diff-normalize.py" <<'INNERPY' || true
import sys
src = open(sys.argv[1], encoding="utf-8").read()
needle = '        if line.startswith(" "):\n'
assert needle in src, "context-drop needle not found"
i = src.index(needle)
j = src.index("            continue\n", i) + len("            continue\n")
open(sys.argv[2], "w", encoding="utf-8").write(src[:i] + src[j:])
INNERPY
if [ -s "$TMP/pmut-ctx/diff-normalize.py" ]; then
  MA="$(pair_of "$Q/a.diff" "$TMP/pmut-ctx/diff-normalize.py")"
  MB="$(pair_of "$Q/b.diff" "$TMP/pmut-ctx/diff-normalize.py")"
  [ -n "$MA" ] && [ "${MA##* }" != "${MB##* }" ] \
    && pass "(31) MUTATION: with context KEPT the real base move no longer matches — the acceptance assertion is load-bearing" \
    || fail "(31) MUTATION SURVIVED: a context-keeping projection still matched the base move"
else
  fail "(31) could not build the context-keeping mutant"
fi
# A mutant that DROPS the +/- lines must make the refusal assertion redden.
mkdir -p "$TMP/pmut-none"
python3 - "$ROOT/scripts/lib/diff-normalize.py" "$TMP/pmut-none/diff-normalize.py" <<'INNERPY' || true
import sys
src = open(sys.argv[1], encoding="utf-8").read()
needle = '        out.append(line)\n    return out\n\n\ndef _normalize_entry'
assert needle in src, "changed-lines needle not found"
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(
    needle, '        if line[:1] in ("+", "-"):\n            continue\n        out.append(line)\n    return out\n\n\ndef _normalize_entry', 1))
INNERPY
if [ -s "$TMP/pmut-none/diff-normalize.py" ]; then
  MB2="$(pair_of "$Q/b.diff" "$TMP/pmut-none/diff-normalize.py")"
  MC2="$(pair_of "$Q/c.diff" "$TMP/pmut-none/diff-normalize.py")"
  [ -n "$MB2" ] && [ "${MB2##* }" = "${MC2##* }" ] \
    && pass "(31) MUTATION: with the changed lines DROPPED the one-line edit matches — the refusal assertion is load-bearing" \
    || fail "(31) mutation did not collapse the pair, so the refusal may pass vacuously"
else
  fail "(31) could not build the changed-lines-dropped mutant"
fi
cd "$TMP" || true
# ── (32) THE MARKER-PRESENT EARLY RETURN IS LOAD-BEARING (#841/#864, agent-infra#2741) ─────────
# `post_marker()` decides whether the signed review marker is ALREADY in the PR body, and its answer
# is what stops a second copy being appended to a body that already carries one. It used to ask:
#
#     printf '%s\n' "$body" | command grep -qF -- "$marker"
#
# `grep -q` exits at the FIRST match, so on a body larger than the pipe buffer the writer takes
# SIGPIPE, `pipefail` marks the pipeline FAILED, and a marker that IS present reads as ABSENT — the
# body is then re-patched. #3347 replaced it with a here-string. Nothing asserted the branch it
# repairs: the guard pins the SHAPE (which is why this is P2), not the behaviour, so a future
# re-introduction with a producer the guard does not recognise would pass unnoticed.
#
# THE FIXTURE MUST DISCRIMINATE, and that is the whole difficulty: the marker has to sit EARLY in a
# body BIGGER than the pipe buffer. One giant line does NOT work — grep reads to EOF and the writer
# never sees SIGPIPE (the recorded MEMORY.md lesson) — so the body below is many short lines.
# Driven through the SHIPPED function, extracted from the script the way refresh-scout.test.sh drives
# `resolve_cmux`: no re-implementation, so the assertion follows the code.
echo; echo "── (32) post_marker: a marker already present is NOT re-patched ──"
awk '/^post_marker\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$SRC" > "$TMP/pm-live.sh"
if [ -s "$TMP/pm-live.sh" ] && grep -q 'post_marker()' "$TMP/pm-live.sh"; then
  # The MUTANT is the pre-#3347 line: same call, same flags, only the PRODUCER changed from a
  # here-string to a pipe. ⛔ THE FLAGS ARE CAPTURED, NOT SPELLED (#2983 moved the live call to
  # `-qxF` and left this builder spelling `-qF`, so the substitution matched NOTHING and both arms
  # below went red over a mutant that was never built). ⛔ AND THAT RED WAS NOT HIDDEN: a first draft
  # of this comment said "no main push runs these shards", which is FALSE — `ci-main.yml` runs the
  # same shard list on every main push, and main run 42225299527 on cf3c46c6d names this file. The
  # gap was that nothing forced the builder to be re-checked when the call it mutates changed.
  # What makes the pre-fix form pre-fix is the PIPE; a capture keeps that the only thing this sed
  # decides, through any future change of flags.
  sed -E 's#if command grep (.*) <<<"[$]body"; then return 0; fi#if { printf "%s\\n" "$body"; printf "%s\\n" "$body"; } | command grep \1; then return 0; fi#' \
    "$TMP/pm-live.sh" > "$TMP/pm-old.sh"
  # ⛔ A SED THAT MATCHED NOTHING IS NOT A MUTANT. The predecessor tested `grep -q 'printf "%s'`,
  # which was sound only because this function contains no OTHER `printf` — a coincidence, not a
  # property. The arm now states the property directly: the two files DIFFER and the new line is the
  # pipe form, so a future edit that adds a `printf` to this function cannot resurrect the vacuity.
  if ! cmp -s "$TMP/pm-live.sh" "$TMP/pm-old.sh" && grep -qF '| command grep' "$TMP/pm-old.sh"; then
    pass "(32a) the pre-fix pipe form was rebuilt for the mutation arm (the mutant is real, not a no-op)"
  else
    fail "(32a) could not rebuild the pre-fix pipe form — the mutation arm would be vacuous"
  fi
  # A stub `gh` that serves the body and RECORDS any PATCH, so "was the body re-written?" is
  # answered by an artifact rather than by an exit status (the old form exits 0 too — it only
  # takes SIGPIPE, which is exactly why a status-only assertion would miss this).
  PMH="$TMP/pm-home"; PMB="$TMP/pm-bin"; rm -rf "$PMH" "$PMB"; mkdir -p "$PMH" "$PMB"
  cat > "$PMB/gh" <<'SH'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in
    *"-X"*) ;; esac
done
case "$*" in
  *PATCH*) printf '%s\n' "PATCH" >> "$PM_PATCH_LOG"; cat >/dev/null 2>&1; exit 0 ;;
esac
case "$*" in
  *"/pulls/"*) printf '%s' "${PM_BODY:-}"; exit 0 ;;
esac
exit 1
SH
  chmod +x "$PMB/gh"
  pm_drive() { # <block> <body> <log> -> echoes post_marker's rc; writes any PATCH to <log>
    PM_BODY="$2" PM_PATCH_LOG="$3" HOME="$PMH" PATH="$PMB:$PATH" \
      bash -c 'set -uo pipefail; . "$1"; post_marker owner/repo 42 "$2"; printf "%s" "$?"' _ "$1" "MARKER-LINE-42" 2>/dev/null
  }
  # ⛔ 1050 LINES, NOT 1200, AND ONE BOUND IS NOT THE PIPE — IT IS `MAX_ARG_STRLEN`. `pm_drive` hands
  # the body to the child as ONE environment string, and Linux caps a single arg/env string at 131,072
  # bytes; a 1200-line body is 145,214 and the child never starts, so (32c)/(32d)/(32e) fail for a
  # reason that has nothing to do with `post_marker` (measured in a Linux container: "Argument list too
  # long"). Passing it by file would NOT dodge this either — `post_marker` also hands the patched body
  # to `jq -n --arg body`, argv under the same cap. So the body must stay BELOW 131,072 and this bound
  # is asserted below.
  # ⛔ AND THE SIGPIPE WINDOW IS NOT BODY-SIZE ALONE (measured, review cycle 3 — this was a ~20% FLAKE
  # of (32c) before the mutant's producer was doubled). A single `printf` of a 127,064-byte body only
  # just exceeds the 65,536-byte pipe capacity, and GNU grep's single read frees up to another 65,536
  # before it exits — so on ~1 run in 5 the writer FINISHES before grep exits, no SIGPIPE is raised,
  # and the pre-fix form correctly finds the marker. Driving the same mutant 60 times gave 46
  # re-patch / 14 no-re-patch. The window is capacity + ONE READER READ ≈ 131,072 WRITTEN BYTES, which
  # a single pass of this body cannot guarantee — so the MUTANT writes the body twice (~254 KB). The
  # body stays small enough to be exec'd; the producer is what makes the window deterministic.
  filler="$(printf 'x%.0s' $(seq 1 120))"
  pm_big="$(for _i in $(seq 1 1050); do printf '%s\n' "$filler"; done)"
  pm_with_marker="$(printf '%s\n%s\n' "MARKER-LINE-42" "$pm_big")"
  pm_bytes=${#pm_with_marker}
  # The body bound, for the ARGV reason above. Larger is NOT better here — above MAX_ARG_STRLEN the
  # child cannot be exec'd at all — and the SIGPIPE window is the mutant's job, not the body's.
  if [ "$pm_bytes" -gt 65536 ] && [ "$pm_bytes" -lt 131072 ]; then
    pass "(32b) the fixture body is $pm_bytes bytes — ABOVE the 64 KiB pipe buffer and BELOW Linux's 131,072-byte MAX_ARG_STRLEN, so the child can be exec'd and one pass of the writer already fills the pipe"
  else
    fail "(32b) the fixture body is $pm_bytes bytes — it must be in the window (65536, 131072): above it the child cannot be exec'd on Linux, and one pass below 65536 would not even fill the pipe"
  fi
  # (32c) NON-VACUITY: the PRE-FIX form, same body, must re-patch.
  : > "$TMP/pm-old.log"
  pm_drive "$TMP/pm-old.sh" "$pm_with_marker" "$TMP/pm-old.log" >/dev/null
  [ -s "$TMP/pm-old.log" ] \
    && pass "(32c) NON-VACUITY: the pre-fix pipe form RE-PATCHES a body that already carries the marker (SIGPIPE reads it as absent)" \
    || fail "(32c) the pre-fix form did not re-patch, so the assertion below would pass on the broken code too"
  # (32d) THE FIX: the shipped form must not touch the body, and must answer 0 (present).
  : > "$TMP/pm-live.log"
  pm_rc="$(pm_drive "$TMP/pm-live.sh" "$pm_with_marker" "$TMP/pm-live.log")"
  [ ! -s "$TMP/pm-live.log" ] && [ "$pm_rc" = "0" ] \
    && pass "(32d) the SHIPPED form returns 0 and does NOT re-patch the body (the marker already present is recognised)" \
    || fail "(32d) the shipped form re-patched a present marker (rc=$pm_rc, patched=$([ -s "$TMP/pm-live.log" ] && echo yes || echo no))"
  # (32e) …and it has not become "never patch": a body WITHOUT the marker must still be patched,
  # or the fix would have traded a duplicate marker for a marker that is never posted at all.
  : > "$TMP/pm-none.log"
  pm_drive "$TMP/pm-live.sh" "$pm_big" "$TMP/pm-none.log" >/dev/null
  [ -s "$TMP/pm-none.log" ] \
    && pass "(32e) control: a body with NO marker is still patched (the early return did not become 'never post')" \
    || fail "(32e) a body without the marker was NOT patched — post_marker now silently never posts the evidence"
else
  fail "(32) could not extract post_marker() from $SRC — every arm of this section is unproven"
fi

# 138 -> 137 (round 36) -> 133 (round 37, PR #1554). The retired-mutant tails printed the SAME
# "RETIRED" note from more than one place: the mutant BUILDER line itself carried a
# `|| pass "NOTE ..."` (sections 24, 25 and 26) and section 26 had a bare
# `bash -n "$M26" || pass "NOTE ..."` as well. Each builder fails by design — its python
# fragment no longer matches the refactored function, so the mutant file is never written — so
# every one of those arms scored the note in ADDITION to the `if bash -n …; then … else … fi`
# tail. Round 36 removed one duplicate for section 25 and claimed the tail "now mirrors section
# 24's single if/else, which emits the note exactly once"; MEASURED in round 37 that claim was
# FALSE — sections 24/25/26 each still emitted their note twice. The builder arms are now
# `|| true` (no `set -e` in this file, so a failed builder is inert), leaving the if/else tail as
# the single emitter. Round 37 also escaped the two backticked spans in the section-23 `pass`
# message, which were running as command substitutions and printing two hard shell errors that no
# assertion could see — the same round-35/36 defect class. Four duplicate passes were retired with
# the builder arms, so this pin is EXACT: the count below, not a floor. (The literal that used to be
# here said 133 while the pin said 183 — a review caught it; that same fix was made independently on
# both sides of this rebase and is kept once.)
# #3347: 185 -> 190 — section (32) pins the marker-present early return in `post_marker()`
# (a marker already in the body must not be re-patched, the pre-fix pipe form must re-patch it,
# and a body with NO marker must still be patched).
# #10522: 183 -> 185 — (30x-b) and (30x-c) pin the NEW body-marker durability
# contract in this suite too (a refused PATCH is a named rc 5, and the signed marker
# survives in the pending file), and the (30x) cap vector no longer depends on the
# marker's fate: its stub answers `.body`/PATCH so the post SUCCEEDS.
# #10583: 185 -> 192 on the branch — section 33 drives the REAL `--delta` verb against a
# hermetic git fixture (33a-33c, +3 assertions); 33d pins the absent-head full triple (+1);
# 33e pins the #10177 interaction — a delta whose record names NO review artifact must refuse
# (+1); 33a2 pins the RECORD SHAPE (proved/arm/conflicts present, authored_unchanged absent for
# the lane arm) and 33a3 pins the ACCEPTED triple's VALUES rather than only their presence (+2),
# because a description of a record contract is not a pin for it.
# Review round 3: 192 -> 196. 33a4 pins the proof-field MAPPING for all three arms and 33a5 pins
# the `from` axis (the head the deciding arm measured), as extracted-function unit pins because
# this suite has no marker fixture and the patch/diff arms are otherwise unreachable; 33f and
# 33f2 pin the unproven-delta refusal and the "both verbs agree" invariant, which were MEASURED
# green under deletion before they existed.
# AFTER THE REBASE the count is main's plus this section's: main spent 185 -> 190 on #3347's own
# section (32), and this PR's section 33 adds 14, so the pin is 204 (190 + 14). Section 33's arms
# are 33a, 33a2, 33a3, 33a4, 33a5, 33a6, 33b, 33c, 33d, 33e, 33f, 33f2, 33g, 33g2 — count THEM, not
# this sentence: the previous revision of this comment said "this PR adds 11, so the pin is 201"
# against a constant of 203, which is the rot a comment restating its own arithmetic always
# suffers. The section is numbered 33 for the same reason — (32) was already taken on main when
# this branch was rebased.
# Review round 4: 204 -> 213. (33h) pins EVERY `--delta` verb-exclusivity / arity / mint-input
# refusal the verb adds — one assertion per combination, each asserting exit 2 AND a byte-identical
# record — because both suites previously drove only the bare `--delta <pr> <repo>` form and a
# deleted guard reddened nothing. MIN_ASSERTIONS is a FLOOR (it reds when FEWER assertions run),
# so it must be raised with the arm or the arm can be skipped silently; it is not a ceiling.
# MEASURED: `ALL PASSED (213 assertion(s))` on this tree (macOS, bash 3.2). `bash-suites` REFUSES to
# run on a live cell (exit 78), so a local ALL PASSED is NOT CI evidence — see the PR comment.
# Review round 5 (THE MERGE WITH #10583): 213 -> 214. The `--delta` verb and this PR's
# `--evidence delta:<A>..<B>` arm merged from opposite sides and shared ONE global
# (`DELTA_FROM`), so EVERY `--delta` record was minted carrying `delta_range`/`delta_base`/
# `delta_kind`/`delta_digest` for a range no reviewer covered. Neither feature's tests could
# see it — each asserted its OWN fields' presence, never the other's absence. (33a7) pins the
# absence, and it was MEASURED red against the merged tree before the fix: the record read
# `"delta_range":"30219358085b…0d.."` with an empty base, kind and digest beside a
# `mint:"delta"` — a signed artifact claiming a reviewed range from the one verb whose
# contract is that no reviewer ran.
MIN_ASSERTIONS=219
# #2628: 214 -> 218. The ``pulls`` read stopped discarding its HTTP status, so
# the print-tier seam gained the (30xvii-c)/(30xvii-d) pair: a 404 on the PR read
# is now `unclassified` (the API REFUSED this PR → positive evidence) and a
# 403/5xx/network failure is still `unavailable` (transport). Four assertions: one
# refusal, three transport shapes. MEASURED 218 on this tree.
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
