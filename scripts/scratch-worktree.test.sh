#!/usr/bin/env bash
# scratch-worktree.test.sh — self-check for scripts/scratch-worktree.sh (#1141).
#
# Run: bash scripts/scratch-worktree.test.sh
# Exits 0 when ALL assertions pass, 1 on any failure.
#
# Hermetic: every fixture is a REAL git repo inside a throwaway temp root, and
# SCRATCH_WORKTREE_ROOT points there, so nothing touches /tmp or the caller's
# repo. Real git drives every probe — the contract IS git semantics.
#
# Coverage:
#   T1  run --full        checked-out ref is right, and NOTHING survives
#   T2  run --paths       sparse checkout is materialised (not empty)
#   T3  footprint         --paths of a narrow path is < 5 MB; --full << the repo
#   T4  exit propagation  wrapped command's non-zero code survives cleanup
#   T5  SIGTERM/SIGINT   killed mid-run => no directory, no admin record
#   T6  create/clean/list lifecycle; --all spares foreign worktrees
#   T7  refusal           non-owned dirs (plain, forged marker, registered but
#                         unmarked) are never removed
#   T8  bad ref           usage error, no worktree registered
#   T9  bad path          --paths of an absent/absolute/'.'/'..' path fails, never
#                         a silent empty checkout; a literal pattern is not
#                         glob-expanded
#   T10 source contract   no clone/copy invocation (with positive controls)
#   T11 process group     SIGTERM kills the group; a TERM-IGNORING child is
#                         SIGKILLed so the worktree is still removed
#   T12 --help            exits 0
#   T13 linked-worktree caller cleans up (owns() via the COMMON git dir)
#   T14 clean --all preserves a scratch worktree a live process holds
#   T15 a straggler DESCENDANT (leader exits first) is SIGKILLed

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SW="$SCRIPT_DIR/scratch-worktree.sh"
FAILS=0
PASS() { printf 'PASS  %s\n' "$1"; }
FAIL() { printf 'FAIL  %s\n' "$1"; FAILS=$((FAILS + 1)); }
ok()   { if [ "$1" = 0 ]; then PASS "$2"; else FAIL "$2"; fi; }

[ -f "$SW" ] || { echo "FAIL  script not found: $SW"; exit 1; }

FIX="$(mktemp -d "${TMPDIR:-/tmp}/swtest-XXXXXX")"
export SCRATCH_WORKTREE_ROOT="$FIX/scratchroot"
mkdir -p "$SCRATCH_WORKTREE_ROOT"
cleanup_fixture() {
  # Tear down every worktree the fixture repo registered, then the fixture.
  if [ -d "$FIX/repo/.git" ]; then
    while IFS= read -r d; do
      case "$d" in "$FIX"/*) rm -rf "$d" ;; esac
    done < <(git -C "$FIX/repo" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')
  fi
  rm -rf "$FIX"
}
trap cleanup_fixture EXIT

# ── fixture repo: two commits, a small dir and a big dir ────────────────────
git init -q "$FIX/repo"
git -C "$FIX/repo" config user.email t@t.t
git -C "$FIX/repo" config user.name t
mkdir -p "$FIX/repo/small" "$FIX/repo/big"
printf 'one\n' > "$FIX/repo/small/a.txt"
for i in $(seq 1 200); do printf 'x%.0s' $(seq 1 2000) > "$FIX/repo/big/f$i.txt"; done
git -C "$FIX/repo" add -A >/dev/null
git -C "$FIX/repo" commit -qm c1
printf 'two\n' > "$FIX/repo/small/b.txt"
git -C "$FIX/repo" add -A >/dev/null
git -C "$FIX/repo" commit -qm c2
C1="$(git -C "$FIX/repo" rev-parse HEAD~1)"
C2="$(git -C "$FIX/repo" rev-parse HEAD)"

# PHYSICAL root: the script canonicalises ROOT (macOS /var -> /private/var), so
# the assertions must compare physical paths too, or they pass vacuously.
ROOT_P="$(cd "$SCRATCH_WORKTREE_ROOT" && pwd -P)"
live_scratch() { bash "$SW" list --repo "$FIX/repo" --root "$SCRATCH_WORKTREE_ROOT" 2>/dev/null | wc -l | tr -d ' '; }
sx() { bash "$SW" "$1" --repo "$FIX/repo" --root "$SCRATCH_WORKTREE_ROOT" "${@:2}"; }

# ── T1: run --full, correct ref, nothing survives ───────────────────────────
OUT="$(sx run --ref "$C1" --full -- bash -c 'echo REF=$(git rev-parse HEAD); echo FILES=$(ls | tr "\n" " ")' 2>/dev/null)"
echo "$OUT" | grep -q "REF=$C1" && ok 0 "T1a run --full checks out the requested ref" || ok 1 "T1a run --full checks out the requested ref ($OUT)"
[ "$(live_scratch)" = 0 ] && ok 0 "T1b run --full leaves no worktree/registration" || ok 1 "T1b run --full leaves no worktree/registration"

# ── T2: run --paths materialises the sparse set ─────────────────────────────
OUT="$(sx run --ref "$C2" --paths small -- bash -c 'ls small | tr "\n" " "' 2>/dev/null)"
echo "$OUT" | grep -q 'a.txt' && echo "$OUT" | grep -q 'b.txt' \
  && ok 0 "T2a run --paths materialises the requested path" || ok 1 "T2a run --paths materialises the requested path ($OUT)"
[ "$(live_scratch)" = 0 ] && ok 0 "T2b run --paths leaves no worktree" || ok 1 "T2b run --paths leaves no worktree"

# ── T3: footprint — sparse narrow < 5 MB, and --full << the repo itself ─────
SPARSE_KB="$(sx run --ref "$C2" --paths small -- du -sk . 2>/dev/null | awk '{print $1}')"
FULL_KB="$(sx run --ref "$C2" --full -- du -sk . 2>/dev/null | awk '{print $1}')"
REPO_KB="$(du -sk "$FIX/repo" | awk '{print $1}')"   # tree + .git, i.e. what a copy costs
[ -n "${SPARSE_KB:-}" ] && [ "$SPARSE_KB" -lt 5120 ] \
  && ok 0 "T3a sparse footprint ${SPARSE_KB}KB < 5MB" || ok 1 "T3a sparse footprint ${SPARSE_KB:-?}KB < 5MB"
if [ -n "${FULL_KB:-}" ] && [ "$FULL_KB" -lt "$REPO_KB" ]; then
  ok 0 "T3b worktree ${FULL_KB}KB < repo copy ${REPO_KB}KB (object store shared)"
else
  ok 1 "T3b worktree ${FULL_KB:-?}KB < repo copy ${REPO_KB}KB"
fi

# ── T4: non-zero exit propagates AND cleans ─────────────────────────────────
sx run --ref "$C2" --full -- bash -c 'exit 7' >/dev/null 2>&1
[ "$?" = 7 ] && ok 0 "T4a wrapped exit code propagates" || ok 1 "T4a wrapped exit code propagates"
[ "$(live_scratch)" = 0 ] && ok 0 "T4b failing command still cleans up" || ok 1 "T4b failing command still cleans up"

# ── T5: SIGTERM / SIGINT mid-run => nothing survives ────────────────────────
P5="$FIX/t5path"
# Invoke the script DIRECTLY (not through the `sx` shell function): `$!` must
# be the script process itself, or the TERM lands on a wrapper subshell and the
# trap never fires.
bash "$SW" run --repo "$FIX/repo" --root "$SCRATCH_WORKTREE_ROOT" --ref "$C2" --full \
  -- bash -c "pwd > '$P5'; sleep 30" >/dev/null 2>&1 &
RUNPID=$!
sleep 2
kill -TERM "$RUNPID" 2>/dev/null
sleep 2
wait "$RUNPID" 2>/dev/null
D5="$(cat "$P5" 2>/dev/null)"
{ [ -n "$D5" ] && [ ! -e "$D5" ]; } && ok 0 "T5a SIGTERM mid-run cleans the checkout" || ok 1 "T5a SIGTERM mid-run cleans the checkout (D5=${D5:-unset})"
[ "$(live_scratch)" = 0 ] && ok 0 "T5b SIGTERM prunes the admin record" || ok 1 "T5b SIGTERM prunes the admin record"

# SIGINT: `cmd &` in a non-interactive shell starts with SIGINT IGNORED, so the
# signal must be un-ignored in a wrapper before it can reach the script's trap.
P5C="$FIX/t5cpath"
bash -c "trap - INT; exec bash '$SW' run --repo '$FIX/repo' --root '$SCRATCH_WORKTREE_ROOT' \
  --ref '$C2' --full -- bash -c \"pwd > '$P5C'; sleep 30\"" >/dev/null 2>&1 &
RUNPID=$!
sleep 2
kill -INT "$RUNPID" 2>/dev/null
sleep 2
wait "$RUNPID" 2>/dev/null
D5C="$(cat "$P5C" 2>/dev/null)"
{ [ -n "$D5C" ] && [ ! -e "$D5C" ]; } && ok 0 "T5c SIGINT mid-run cleans the checkout" || ok 1 "T5c SIGINT mid-run cleans the checkout (D5C=${D5C:-unset})"
[ "$(live_scratch)" = 0 ] && ok 0 "T5d SIGINT prunes the admin record" || ok 1 "T5d SIGINT prunes the admin record"

# ── T6: create / list / clean lifecycle; --all spares foreign worktrees ─────
D6="$(sx create --ref "$C2" --full 2>/dev/null)"
[ -d "$D6" ] && ok 0 "T6a create prints a live path" || ok 1 "T6a create prints a live path"
[ "$(live_scratch)" = 1 ] && ok 0 "T6b list shows the scratch worktree (positive control)" || ok 1 "T6b list shows the scratch worktree (got $(live_scratch))"
FOREIGN="$FIX/foreign-wt"
git -C "$FIX/repo" worktree add --detach "$FOREIGN" "$C2" >/dev/null 2>&1
sx clean --all >/dev/null 2>&1
[ ! -e "$D6" ] && ok 0 "T6c clean --all removes the scratch worktree" || ok 1 "T6c clean --all removes the scratch worktree"
[ -d "$FOREIGN" ] && ok 0 "T6d clean --all spares a non-scratch worktree" || ok 1 "T6d clean --all spares a non-scratch worktree"
git -C "$FIX/repo" worktree remove --force "$FOREIGN" >/dev/null 2>&1
git -C "$FIX/repo" worktree prune >/dev/null 2>&1

# ── T7: refusal — never remove a path this tool did not create ──────────────
DECOY="$ROOT_P/scratch-decoy"
mkdir -p "$DECOY"; printf 'precious\n' > "$DECOY/data"
sx clean "$DECOY" >/dev/null 2>&1
[ -f "$DECOY/data" ] && ok 0 "T7a plain dir is refused" || ok 1 "T7a plain dir is refused"
rm -rf "$DECOY"

FORGED="$ROOT_P/scratch-forged"
mkdir -p "$FORGED"; printf '%s\n' "$FIX/repo" > "$FORGED/.scratch-worktree"; printf 'precious\n' > "$FORGED/data"
sx clean "$FORGED" >/dev/null 2>&1
[ -f "$FORGED/data" ] && ok 0 "T7b forged-marker dir is refused (not a registered worktree)" || ok 1 "T7b forged-marker dir is refused"
rm -rf "$FORGED"

# The reviewer's P1: a REGISTERED worktree under ROOT whose name matches the
# scratch prefix but carries no marker must survive `clean --all`.
UNMARKED="$ROOT_P/scratch-unmarked"
git -C "$FIX/repo" worktree add --detach "$UNMARKED" "$C2" >/dev/null 2>&1
printf 'PRECIOUS UNCOMMITTED\n' > "$UNMARKED/UNRESOLVED.txt"
sx clean --all >/dev/null 2>&1
{ [ -d "$UNMARKED" ] && [ -f "$UNMARKED/UNRESOLVED.txt" ]; } \
  && ok 0 "T7c registered but unowned worktree survives clean --all" \
  || ok 1 "T7c registered but unowned worktree survives clean --all"
git -C "$FIX/repo" worktree remove --force "$UNMARKED" >/dev/null 2>&1
git -C "$FIX/repo" worktree prune >/dev/null 2>&1

# ── T8: bad ref => usage error, nothing registered ──────────────────────────
sx run --ref 'no-such-ref-xyz' --full -- true >/dev/null 2>&1
[ "$?" = 2 ] && ok 0 "T8a bad ref exits 2" || ok 1 "T8a bad ref exits 2"
[ "$(live_scratch)" = 0 ] && ok 0 "T8b bad ref registers nothing" || ok 1 "T8b bad ref registers nothing"

# ── T9: missing / pattern paths must fail, never a silent empty checkout ────
sx run --ref "$C2" --paths no/such/path -- true >/dev/null 2>&1
[ "$?" = 2 ] && ok 0 "T9a absent path exits 2 (no silent empty checkout)" || ok 1 "T9a absent path exits 2"
[ "$(live_scratch)" = 0 ] && ok 0 "T9b absent path registers nothing" || ok 1 "T9b absent path registers nothing"
( cd "$FIX" && sx run --ref "$C2" --paths '*' -- true ) >/dev/null 2>&1
[ "$?" = 2 ] && ok 0 "T9c a glob is treated as a literal path, not expanded" || ok 1 "T9c a glob is treated as a literal path"
# `.`, `..` and `.git` all EXIST ON DISK after an empty materialisation, so a
# filesystem existence test would pass them — the validation must be against
# REF's tree (cycle-2 P1).
for bad in . .. .git; do
  sx run --ref "$C2" --paths "$bad" -- true >/dev/null 2>&1
  [ "$?" = 2 ] && ok 0 "T9d '$bad' is refused (not a filesystem existence test)" || ok 1 "T9d '$bad' is refused (got $?)"
done
sx run --ref "$C2" --paths /etc -- true >/dev/null 2>&1
[ "$?" = 2 ] && ok 0 "T9e an absolute path is refused" || ok 1 "T9e an absolute path is refused"
[ "$(live_scratch)" = 0 ] && ok 0 "T9f no rejected --paths call registered anything" || ok 1 "T9f no rejected --paths call registered anything"

# ── T10: source contract — no clone / copy of the repo ──────────────────────
# Positive control FIRST: a pattern that silently stopped matching would PASS
# vacuously (the cycle-1 vacuity class). Comments are stripped before testing, so
# prose ABOUT the ban cannot satisfy it and a real invocation cannot hide.
BAN_RE='(git[[:space:]]+clone|git[[:space:]]+archive|cp[[:space:]]+-[a-zA-Z]*[rR]|cp[[:space:]]+-a|rsync|tar[[:space:]]+-[a-zA-Z]*x)'
stripped() { sed 's/#.*//' "$1"; }
detects() { printf '%s\n' "$1" | sed 's/#.*//' | grep -qE "$BAN_RE"; }
POS_FAIL=0
for s in 'git clone /x /y' 'cp -R /x /y' 'cp -a /x /y' 'cp -pR /x /y' \
         'rsync -a /x /y' 'git archive HEAD | tar -xf - -C /tmp/z'; do
  detects "$s" || { FAIL "T10a positive control not detected: $s"; POS_FAIL=1; }
done
[ "$POS_FAIL" = 0 ] && PASS "T10a every banned copy shape is detected (positive control)"
NEG_FAIL=0
# Controls run through the SAME stripping the real scan uses. (A banned word
# inside a quoted shell string still matches by design — this is a source lint,
# not a shell parser; the shipped file has no such string.)
for s in '# cp -R is banned' '# rsync -a src dst would be banned' \
         'git worktree add /x /y' 'git read-tree -mu HEAD' 'echo ok'; do
  detects "$s" && { FAIL "T10b false positive: $s"; NEG_FAIL=1; }
done
[ "$NEG_FAIL" = 0 ] && PASS "T10b comments/prose and worktree/read-tree do not trip the scan"
if stripped "$SW" | grep -qE "$BAN_RE"; then
  FAIL "T10c source contains a clone/copy invocation:"
  stripped "$SW" | grep -nE "$BAN_RE" | sed 's/^/      /'
else
  PASS "T10c source contains no clone/copy invocation"
fi

# ── T11: the wrapped process group dies; a TERM-IGNORING child is SIGKILLed ─
ORPHAN="$FIX/orphan-marker"
bash "$SW" run --repo "$FIX/repo" --root "$SCRATCH_WORKTREE_ROOT" --ref "$C2" --full \
  -- bash -c "sleep 3; touch '$ORPHAN'" >/dev/null 2>&1 &
RUNPID=$!
sleep 1
kill -TERM "$RUNPID" 2>/dev/null
sleep 4   # well past the child's `sleep 3`
[ ! -e "$ORPHAN" ] && ok 0 "T11a SIGTERM kills the wrapped process group" || ok 1 "T11a orphaned child kept running"

# A child that IGNORES TERM must not be able to block the trap into an unbounded
# `wait` — that leaks the worktree, the exact class this tool removes.
P11="$FIX/t11path"
SCRATCH_WORKTREE_KILL_GRACE=1 bash "$SW" run --repo "$FIX/repo" --root "$SCRATCH_WORKTREE_ROOT" \
  --ref "$C2" --full -- bash -c "trap '' TERM; pwd > '$P11'; while : ; do sleep 0.5; done" \
  >/dev/null 2>&1 &
RUNPID=$!
sleep 2
kill -TERM "$RUNPID" 2>/dev/null
deadline=$((SECONDS + 12))
while kill -0 "$RUNPID" 2>/dev/null && [ "$SECONDS" -lt "$deadline" ]; do sleep 0.5; done
D11="$(cat "$P11" 2>/dev/null)"
kill -9 "$RUNPID" 2>/dev/null
wait "$RUNPID" 2>/dev/null
if kill -0 "$RUNPID" 2>/dev/null; then
  ok 1 "T11b a TERM-ignoring child does not block cleanup (script still alive)"
else
  { [ -n "$D11" ] && [ ! -e "$D11" ]; } && ok 0 "T11b TERM-ignoring child is SIGKILLed and the worktree removed" \
    || ok 1 "T11b TERM-ignoring child leaked the worktree (D11=${D11:-unset})"
fi
[ "$(live_scratch)" = 0 ] && ok 0 "T11c no admin record survives the TERM-ignoring child" || ok 1 "T11c no admin record survives the TERM-ignoring child"

# ── T14: `clean --all` PRESERVES a scratch worktree a live process holds ─────
D14="$(sx create --ref "$C2" --full 2>/dev/null)"
bash -c "cd '$D14' && sleep 8" >/dev/null 2>&1 &
HOLD=$!
sleep 1
sx clean --all >/dev/null 2>&1
[ -d "$D14" ] && ok 0 "T14a a live-held scratch worktree is PRESERVED" || ok 1 "T14a a live-held scratch worktree is PRESERVED"
kill "$HOLD" 2>/dev/null; wait "$HOLD" 2>/dev/null
pkill -P "$HOLD" 2>/dev/null
sleep 1
sx clean --all >/dev/null 2>&1
[ ! -e "$D14" ] && ok 0 "T14b the released scratch worktree is removed" || ok 1 "T14b the released scratch worktree is removed"

# ── T15: a straggler DESCENDANT (leader exits first) is still SIGKILLed ──────
# The leader exits immediately, so `wait` returns at once; the TERM-ignoring
# descendant stays in the group. If the watchdog were cancelled at that point
# the descendant would outlive the worktree (cycle-3 P1).
P15="$FIX/t15path"; ORPH2="$FIX/orphan2"
SCRATCH_WORKTREE_KILL_GRACE=1 bash "$SW" run --repo "$FIX/repo" --root "$SCRATCH_WORKTREE_ROOT" \
  --ref "$C2" --full -- bash -c "pwd > '$P15'; ( trap '' TERM; sleep 4; touch '$ORPH2' ) & exit 0" \
  >/dev/null 2>&1
RC15=$?
sleep 5
D15="$(cat "$P15" 2>/dev/null)"
[ "$RC15" = 0 ] && ok 0 "T15a leader exit code survives" || ok 1 "T15a leader exit code survives (rc=$RC15)"
[ ! -e "$ORPH2" ] && ok 0 "T15b a TERM-ignoring descendant is SIGKILLed (no orphan)" || ok 1 "T15b a TERM-ignoring descendant survived"
{ [ -n "$D15" ] && [ ! -e "$D15" ]; } && ok 0 "T15c the worktree is removed" || ok 1 "T15c the worktree is removed (D15=${D15:-unset})"
[ "$(live_scratch)" = 0 ] && ok 0 "T15d no admin record survives" || ok 1 "T15d no admin record survives"

# ── T12: --help ─────────────────────────────────────────────────────────────
bash "$SW" --help >/dev/null 2>&1 && ok 0 "T12 --help exits 0" || ok 1 "T12 --help exits 0"

# ── T13: a LINKED-WORKTREE caller cleans up (own-detection via the common git dir)
# The dispatch-child case: --repo is itself a linked worktree, so the scratch
# record lands in the MAIN checkout's .git/worktrees/. Regression guard for the
# `owns()` common-dir bug, which leaked every scratch worktree from a worktree.
LINK="$FIX/linked-caller"
git -C "$FIX/repo" worktree add --detach "$LINK" "$C2" >/dev/null 2>&1
D13="$(bash "$SW" run --repo "$LINK" --root "$SCRATCH_WORKTREE_ROOT" --ref "$C2" --full -- bash -c 'pwd' 2>/dev/null)"
{ [ -n "$D13" ] && [ ! -e "$D13" ]; } && ok 0 "T13a linked-worktree caller cleans its scratch checkout" || ok 1 "T13a linked-worktree caller cleans its scratch checkout (D13=${D13:-unset})"
[ "$(bash "$SW" list --repo "$LINK" --root "$SCRATCH_WORKTREE_ROOT" 2>/dev/null | wc -l | tr -d ' ')" = 0 ] \
  && ok 0 "T13b no admin record survives from a linked-worktree caller" || ok 1 "T13b no admin record survives from a linked-worktree caller"
git -C "$FIX/repo" worktree remove --force "$LINK" >/dev/null 2>&1
git -C "$FIX/repo" worktree prune >/dev/null 2>&1

echo
if [ "$FAILS" = 0 ]; then echo "ALL PASS"; exit 0; else echo "$FAILS FAILURE(S)"; exit 1; fi
