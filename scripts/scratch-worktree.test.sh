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
#   T14 clean --all --force-all preserves a live-held scratch worktree
#   T15 a straggler DESCENDANT (leader exits first) is SIGKILLed
#   T16 a BARE clean --all refuses to sweep (fail-closed); --force-all sweeps
#   T17 cleanup does not depend on the in-worktree marker (identity removal)
#   T18 cleanup deregisters ONLY its own record (never an unrelated sibling)
#   T19 --paths is anchored (a same-named nested dir is not materialised)
#   T20 run is silent on stderr when it succeeds (20 samples)
#   T21 a wrapped command that deletes `.git` still deregisters the record
#   T22 a wrapped command that replaces `$D` with a DANGLING symlink still cleans
#   T23 a forged marker+gitdir cannot deregister a real sibling (back-link proof)
#   T24 a mode-000 leftover is made removable and removed (retry path)
#   T25 a truly UNDELETABLE leftover stays registered so `list` shows it
#   T26 the orphan reclaim is TARGET-SPECIFIC (a foreign path stays rc 1 even
#       when an unrelated orphan record exists, and that orphan is NOT silently
#       reclaimed as a side effect)

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
grep -q "REF=$C1" <<<"$OUT" && ok 0 "T1a run --full checks out the requested ref" || ok 1 "T1a run --full checks out the requested ref ($OUT)"
[ "$(live_scratch)" = 0 ] && ok 0 "T1b run --full leaves no worktree/registration" || ok 1 "T1b run --full leaves no worktree/registration"

# ── T2: run --paths materialises the sparse set ─────────────────────────────
OUT="$(sx run --ref "$C2" --paths small -- bash -c 'ls small | tr "\n" " "' 2>/dev/null)"
grep -q 'a.txt' <<<"$OUT" && grep -q 'b.txt' <<<"$OUT" \
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
D6="$(sx create --ref "$C2" --full 2>"$FIX/t6err")"
[ -d "$D6" ] && ok 0 "T6a create prints a live path" || ok 1 "T6a create prints a live path"
# The remediation create prints must be runnable verbatim: `owns()` needs the path
# under the CURRENT root and the marker to name the CURRENT repo, so a bare
# `clean <path>` is unsatisfiable when defaults differ (cycle-12 P2).
if grep -q -- '--repo' "$FIX/t6err" && grep -q -- '--root' "$FIX/t6err"; then
  ok 0 "T6e the printed cleanup command carries --repo and --root"
else
  ok 1 "T6e the printed cleanup command is not self-contained: $(tr '\n' '|' < "$FIX/t6err")"
fi
sx clean "$D6" >/dev/null 2>&1
[ ! -e "$D6" ] && ok 0 "T6f the created path is cleanable with the matching --repo/--root" \
  || ok 1 "T6f the created path is cleanable with the matching --repo/--root"
D6="$(sx create --ref "$C2" --full 2>/dev/null)"
[ "$(live_scratch)" = 1 ] && ok 0 "T6b list shows the scratch worktree (positive control)" || ok 1 "T6b list shows the scratch worktree (got $(live_scratch))"
FOREIGN="$FIX/foreign-wt"
git -C "$FIX/repo" worktree add --detach "$FOREIGN" "$C2" >/dev/null 2>&1
sx clean --all --force-all >/dev/null 2>&1
[ ! -e "$D6" ] && ok 0 "T6c clean --all --force-all removes the scratch worktree" || ok 1 "T6c clean --all --force-all removes the scratch worktree"
[ -d "$FOREIGN" ] && ok 0 "T6d clean --all --force-all spares a non-scratch worktree" || ok 1 "T6d clean --all --force-all spares a non-scratch worktree"
git -C "$FIX/repo" worktree remove --force "$FOREIGN" >/dev/null 2>&1
git -C "$FIX/repo" worktree prune >/dev/null 2>&1

# ── T7: refusal — never remove a path this tool did not create ──────────────
DECOY="$ROOT_P/scratch-decoy"
mkdir -p "$DECOY"; printf 'precious\n' > "$DECOY/data"
sx clean "$DECOY" >/dev/null 2>&1
RC7A=$?
{ [ "$RC7A" != 0 ] && [ -f "$DECOY/data" ]; } && ok 0 "T7a plain dir is refused (rc=$RC7A)" \
  || ok 1 "T7a plain dir is refused (rc=$RC7A)"
rm -rf "$DECOY"

FORGED="$ROOT_P/scratch-forged"
mkdir -p "$FORGED"; printf '%s\n' "$FIX/repo" > "$FORGED/.scratch-worktree"; printf 'precious\n' > "$FORGED/data"
sx clean "$FORGED" >/dev/null 2>&1
RC7B=$?
{ [ "$RC7B" != 0 ] && [ -f "$FORGED/data" ]; } && ok 0 "T7b forged-marker dir is refused (rc=$RC7B)" \
  || ok 1 "T7b forged-marker dir is refused (rc=$RC7B)"
rm -rf "$FORGED"

# The reviewer's P1: a REGISTERED worktree under ROOT whose name matches the
# scratch prefix but carries no marker must survive `clean --all --force-all`.
UNMARKED="$ROOT_P/scratch-unmarked"
git -C "$FIX/repo" worktree add --detach "$UNMARKED" "$C2" >/dev/null 2>&1
printf 'PRECIOUS UNCOMMITTED\n' > "$UNMARKED/UNRESOLVED.txt"
sx clean --all --force-all >/dev/null 2>&1
{ [ -d "$UNMARKED" ] && [ -f "$UNMARKED/UNRESOLVED.txt" ]; } \
  && ok 0 "T7c registered but unowned worktree survives clean --all --force-all" \
  || ok 1 "T7c registered but unowned worktree survives clean --all --force-all"
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
BAN_RE='(git[[:space:]]+clone|git[[:space:]]+archive|cp[[:space:]]+(-[a-zA-Z]*[rR]|-a|--recursive|--archive|-[a-zA-Z]*[aA][a-zA-Z]*)|rsync|tar[[:space:]]+(x|-x|-?[a-zA-Z]*x))'
stripped() { sed -E 's/(^|[[:space:]])#.*$/\1/' "$1"; }
# Strip only WORD-BOUNDARY comments: a bare `s/#.*//` also deletes `#` inside a
# token, so `echo a#b; cp -R /x /y` would strip to `echo a` and the real scan
# would report clean (cycle-4 P2).
detects() { printf '%s\n' "$1" | sed -E 's/(^|[[:space:]])#.*$/\1/' | grep -qE "$BAN_RE"; }
POS_FAIL=0
for s in 'git clone /x /y' 'cp -R /x /y' 'cp -a /x /y' 'cp -pR /x /y' \
         'rsync -a /x /y' 'git archive HEAD | tar -xf - -C /tmp/z' \
         'cp --recursive /x /y' 'cp --archive /x /y' 'tar xf a.tar' \
         'echo a#b; cp -R /x /y'; do
  detects "$s" || { FAIL "T10a positive control not detected: $s"; POS_FAIL=1; }
done
# The long forms are equivalent spellings, not near-misses: `cp --recursive` is
# `cp -r` and `tar xf` is `tar -xf`, so missing them was a false PASS in the very
# check that exists to stop this file reintroducing the copy (cycle-5 P2).
[ "$POS_FAIL" = 0 ] && PASS "T10a every banned copy shape is detected (positive control)"
NEG_FAIL=0
# Controls run through the SAME stripping the real scan uses. (A banned word
# inside a quoted shell string still matches by design — this is a source lint,
# not a shell parser; the shipped file has no such string.)
for s in '# cp -R is banned' '# rsync -a src dst would be banned' \
         'git worktree add /x /y' 'git read-tree -mu HEAD' 'echo ok' \
         'cp -p /x /y' 'tar -czf out.tgz src' 'git worktree prune'; do
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

# ── T16: a BARE `clean --all` refuses to sweep (fail-closed) ────────────────
# The argv liveness probe fails OPEN for a cwd-only holder, so the bare sweep
# must not run at all; `--force-all` is the deliberate opt-in.
D16="$(sx create --ref "$C2" --full 2>/dev/null)"
sx clean --all 2>"$FIX/t16err" >/dev/null
[ -d "$D16" ] && ok 0 "T16a a bare clean --all removes nothing" || ok 1 "T16a a bare clean --all removed a worktree"
# The refusal message is the ONLY explanation of why the gate fired; a backtick
# inside a double-quoted printf payload ran `clean` as a command substitution and
# deleted the guidance (cycle-5 P2).
if grep -q 'refusing to sweep' "$FIX/t16err" && ! grep -q 'command not found' "$FIX/t16err"; then
  ok 0 "T16c the refusal message renders and runs no external command"
else
  ok 1 "T16c the refusal message is corrupt or executed a command: $(tr '\n' '|' < "$FIX/t16err")"
fi
sx clean --all --force-all >/dev/null 2>&1
[ ! -e "$D16" ] && ok 0 "T16b clean --all --force-all removes it" || ok 1 "T16b clean --all --force-all removes it"

# ── T17: cleanup does not depend on the in-worktree marker ──────────────────
# A wrapped command may delete untracked files, which removes `.scratch-worktree`.
# `run` knows the path by identity, so it must still remove the worktree and its
# admin record (cycle-4 P1).
P17="$FIX/t17path"
bash "$SW" run --repo "$FIX/repo" --root "$SCRATCH_WORKTREE_ROOT" --ref "$C2" --full \
  -- bash -c "pwd > '$P17'; rm -f .scratch-worktree; test -e .scratch-worktree && echo MARKER || echo NOMARKER" \
  >/dev/null 2>&1
RP="$(cat "$P17" 2>/dev/null)"
if [ -n "$RP" ] && [ ! -e "$RP" ]; then
  ok 0 "T17a a marker-destroying command still cleans the checkout"
else
  ok 1 "T17a a marker-destroying command still cleans the checkout (path=${RP:-unset})"
fi
[ "$(live_scratch)" = 0 ] && ok 0 "T17b the admin record is reclaimed too" || ok 1 "T17b the admin record is reclaimed too"

# ── T14: `clean --all --force-all` PRESERVES a live-held scratch worktree ────
D14="$(sx create --ref "$C2" --full 2>/dev/null)"
bash -c "cd '$D14' && sleep 8" >/dev/null 2>&1 &
HOLD=$!
sleep 1
sx clean --all --force-all >/dev/null 2>&1
[ -d "$D14" ] && ok 0 "T14a a live-held scratch worktree is PRESERVED" || ok 1 "T14a a live-held scratch worktree is PRESERVED"
kill "$HOLD" 2>/dev/null; wait "$HOLD" 2>/dev/null
pkill -P "$HOLD" 2>/dev/null
sleep 1
sx clean --all --force-all >/dev/null 2>&1
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

# ── T18: deregistration is TARGETED — an unrelated sibling is never pruned ──
# A blanket `git worktree prune` deregisters any record whose directory is not
# currently stat-able (unmounted volume, permission blip, stale NFS). Since `run`
# is the mandated path for every review cycle, that would silently destroy an
# unrelated sibling's checkout on a routine probe (cycle-5 P1).
T18PAR="$FIX/hidden"
mkdir -p "$T18PAR"
git -C "$FIX/repo" worktree add --detach "$T18PAR/sibling" "$C2" >/dev/null 2>&1
printf 'wip\n' > "$T18PAR/sibling/UNCOMMITTED.txt"
chmod 000 "$T18PAR"                      # parent exists but is not stat-able
sx run --ref "$C2" --full -- true >/dev/null 2>&1
chmod 755 "$T18PAR"
if git -C "$T18PAR/sibling" rev-parse --git-dir >/dev/null 2>&1; then
  ok 0 "T18a an unstat-able sibling worktree survives a run"
else
  ok 1 "T18a a routine run PRUNED an unrelated sibling worktree"
fi
[ -f "$T18PAR/sibling/UNCOMMITTED.txt" ] && ok 0 "T18b the sibling's files are intact" \
  || ok 1 "T18b the sibling's files are intact"
git -C "$FIX/repo" worktree remove --force "$T18PAR/sibling" >/dev/null 2>&1
rm -rf "$T18PAR"

# ── T19: --paths is ANCHORED, not a gitignore pattern matching at any depth ─
# `--no-cone` treats each element as a patternspec, so a bare `small` also
# materialises `nested/small/`. Single-component paths are the common case, so
# the documented "exactly these paths / literal, not patterns" contract was
# misleading for most calls (cycle-5 P2).
git -C "$FIX/repo" checkout -q --detach "$C2"
mkdir -p "$FIX/repo/nested/small"
printf 'n\n' > "$FIX/repo/nested/small/n.txt"
git -C "$FIX/repo" add nested/small/n.txt >/dev/null 2>&1
git -C "$FIX/repo" commit -qm nest >/dev/null 2>&1
NEST="$(git -C "$FIX/repo" rev-parse HEAD)"
sx run --ref "$NEST" --paths small -- bash -c 'ls small 2>/dev/null; echo --; ls nested/small 2>/dev/null' \
  >"$FIX/t19out" 2>&1
if grep -q 'a.txt' "$FIX/t19out"; then ok 0 "T19a the requested path is materialised" \
  ; else ok 1 "T19a the requested path is materialised: $(cat "$FIX/t19out")"; fi
grep -q 'n.txt' "$FIX/t19out" && ok 1 "T19b a same-named NESTED dir was materialised (unanchored pattern)" \
  || ok 0 "T19b a same-named nested dir is not materialised (anchored)"

# ── T20: a SUCCESSFUL run is silent on stderr ──────────────────────────────
# Two distinct bash-3.2 races produce stderr on success: `run_pending_traps: bad
# value in trap_list` from the watchdog subshell (TERMed while parked in `sleep`)
# and `child setpgid (PID): Operation not permitted` from the `set -m` launch
# window (~1%). Both read to an agent as tool failure, and the second made a
# 3-sample T20 flake. The group is normally established in the child (perl or
# python3 setpgrp + exec) so there is no parent-side race; the `set -m` branch is
# the last resort and CAN still emit that line — a declared residual, not silence.
# 20 samples; the FIRST failing buffer is preserved.
ERR20=0; ERRMSG=""
for _ in $(seq 1 20); do
  bash "$SW" run --repo "$FIX/repo" --root "$SCRATCH_WORKTREE_ROOT" --ref "$C2" --full -- true \
    >/dev/null 2>"$FIX/t20err" || true
  if [ -s "$FIX/t20err" ]; then
    ERR20=$((ERR20 + 1))
    [ -z "$ERRMSG" ] && ERRMSG="$(head -2 "$FIX/t20err")"
  fi
done
[ "$ERR20" = 0 ] && ok 0 "T20 a successful run writes nothing to stderr (20 samples)" \
  || ok 1 "T20 a successful run wrote stderr $ERR20/20 times: $ERRMSG"
[ "$(live_scratch)" = 0 ] && ok 0 "T20b the 20 runs left no record" || ok 1 "T20b the 20 runs left a record"

# ── T21: a wrapped command that deletes `.git` still deregisters the record ──
# The admin dir cannot be re-derived from `$D/.git` after the probe removed it, so
# `run` captures it at creation. Without that, the fallback rm's the directory,
# keeps the registration, and exits 0 over a phantom record it cannot prove it
# owns (cycle-6 P2).
P21="$FIX/t21path"
bash "$SW" run --repo "$FIX/repo" --root "$SCRATCH_WORKTREE_ROOT" --ref "$C2" --full \
  -- bash -c "pwd > '$P21'; rm -rf .git" >/dev/null 2>&1
RC21=$?
D21="$(cat "$P21" 2>/dev/null)"
[ "$RC21" = 0 ] && ok 0 "T21a the probe's exit code survives" || ok 1 "T21a the probe's exit code survives (rc=$RC21)"
{ [ -n "$D21" ] && [ ! -e "$D21" ]; } && ok 0 "T21b the directory is gone" || ok 1 "T21b the directory is gone (D21=${D21:-unset})"
[ "$(live_scratch)" = 0 ] && ok 0 "T21c no phantom registration survives" || ok 1 "T21c a phantom registration survived"
if [ -n "$D21" ] && git -C "$FIX/repo" worktree list --porcelain 2>/dev/null | grep -qF "$D21"; then
  ok 1 "T21d a stale entry remains in git worktree list"
else
  ok 0 "T21d no stale entry in git worktree list"
fi

# ── T22: a DANGLING SYMLINK left at $D is still removed ─────────────────────
# `[ -e ]` follows the link, so a link to a nonexistent path read as "already
# gone": the record was deregistered, `list` reported clean, and the symlink sat
# under the scratch root forever (cycle-8 P2). `[ -L ]` closes it.
P22="$FIX/t22path"
bash "$SW" run --repo "$FIX/repo" --root "$SCRATCH_WORKTREE_ROOT" --ref "$C2" --full \
  -- bash -c "pwd > '$P22'; cd /; rm -rf \"\$(cat '$P22')\"; ln -s /nonexistent-target \"\$(cat '$P22')\"" \
  >/dev/null 2>&1
RC22=$?
D22="$(cat "$P22" 2>/dev/null)"
[ "$RC22" = 0 ] && ok 0 "T22a the probe's exit code survives" || ok 1 "T22a the probe's exit code survives (rc=$RC22)"
{ [ -n "$D22" ] && [ ! -e "$D22" ] && [ ! -L "$D22" ]; } \
  && ok 0 "T22b a dangling symlink left at the scratch path is removed" \
  || ok 1 "T22b a dangling symlink survived at ${D22:-unset}"
[ "$(live_scratch)" = 0 ] && ok 0 "T22c no record survives" || ok 1 "T22c a record survived"

# ── T23: ownership cannot be FORGED to deregister a real sibling ────────────
# The marker is trivially derivable and `gitdir:` is just a path, so a directory
# under the scratch root carrying both could name an unrelated sibling's admin dir
# and have `clean <path>` rm -rf it (cycle-9 P1). `owns()` now also requires the
# admin dir's own `gitdir` BACK-LINK to name this worktree's `.git` — written by
# git, so a forger cannot produce it for a worktree they do not control.
SIB="$FIX/sibling-owned"
git -C "$FIX/repo" worktree add --detach "$SIB" "$C2" >/dev/null 2>&1
printf 'precious\n' > "$SIB/WIP.txt"
SIB_ADMIN="$(sed -n 's/^gitdir: //p' "$SIB/.git" 2>/dev/null | head -1)"
EVIL="$SCRATCH_WORKTREE_ROOT/scratch-evil"
mkdir -p "$EVIL"
printf '%s\n' "$(cd "$FIX/repo" && pwd -P)" > "$EVIL/.scratch-worktree"
printf 'gitdir: %s\n' "$SIB_ADMIN" > "$EVIL/.git"
sx clean "$EVIL" >/dev/null 2>&1
RC23=$?
[ "$RC23" != 0 ] && ok 0 "T23a a forged ownership pair is refused (rc=$RC23)" || ok 1 "T23a a forged ownership pair was accepted (rc=$RC23)"
if git -C "$SIB" rev-parse --git-dir >/dev/null 2>&1; then
  ok 0 "T23b the sibling worktree is still a repository"
else
  ok 1 "T23b a forged marker DEREGISTERED an unrelated sibling"
fi
[ -f "$SIB/WIP.txt" ] && ok 0 "T23c the sibling's files are intact" || ok 1 "T23c the sibling's files are intact"
rm -rf "$EVIL"
git -C "$FIX/repo" worktree remove --force "$SIB" >/dev/null 2>&1

# ── T24: an UNREMOVABLE leftover must stay visible, never become an orphan ───
# If the probe leaves something `rm` cannot delete, pruning the record anyway
# would hide it from `list` (the documented completion check), from `clean
# <path>` (no marker to prove ownership) and from the reaper (which enumerates
# registered worktrees) — a leak that every check reports as clean (cycle-9 P2).
P24="$FIX/t24path"
bash "$SW" run --repo "$FIX/repo" --root "$SCRATCH_WORKTREE_ROOT" --ref "$C2" --full \
  -- bash -c "pwd > '$P24'; mkdir blocker; : > blocker/f; chmod 000 blocker; exit 0" \
  >/dev/null 2>&1
RC24=$?
D24="$(cat "$P24" 2>/dev/null)"
[ "$RC24" = 0 ] && ok 0 "T24a the probe's exit code survives" || ok 1 "T24a the probe's exit code survives (rc=$RC24)"
if [ -e "$D24" ]; then
  [ "$(live_scratch)" != 0 ] && ok 0 "T24b an unremovable leftover stays visible to list" \
    || ok 1 "T24b an unremovable leftover became an invisible orphan"
else
  ok 0 "T24b the leftover was made removable and removed"
fi
chmod -R u+rwX "$D24" 2>/dev/null || true
rm -rf "$D24" 2>/dev/null || true
sx clean --all --force-all >/dev/null 2>&1
[ "$(live_scratch)" = 0 ] && ok 0 "T24c fixture reclaimed" || ok 1 "T24c fixture reclaimed"

# ── T25: a genuinely UNDELETABLE leftover must stay registered ──────────────
# The invariant T24 cannot reach: `chmod -R u+rwX` repairs a mode-000 subtree, so
# that path always removes. An IMMUTABLE file (macOS `chflags uchg`) cannot be
# removed even then — and the record must NOT be deregistered, or the survivor is
# invisible to `list`, to a second `clean <path>` and to the reaper (cycle-10 P1).
if command -v chflags >/dev/null 2>&1 && [ "$(uname -s)" = Darwin ]; then
  P25="$FIX/t25path"
  bash "$SW" run --repo "$FIX/repo" --root "$SCRATCH_WORKTREE_ROOT" --ref "$C2" --full \
    -- bash -c "pwd > '$P25'; mkdir blocker; : > blocker/f; chflags uchg blocker/f; exit 0" \
    >/dev/null 2>&1
  RC25=$?
  D25="$(cat "$P25" 2>/dev/null)"
  [ "$RC25" = 0 ] && ok 0 "T25a the probe's exit code survives" || ok 1 "T25a the probe's exit code survives (rc=$RC25)"
  if [ -e "$D25" ]; then
    [ "$(live_scratch)" != 0 ] && ok 0 "T25b an undeletable leftover stays registered and visible" \
      || ok 1 "T25b an undeletable leftover became an invisible orphan"
    [ "$(sx clean "$D25" >/dev/null 2>&1; echo $?)" != 0 ] \
      && ok 0 "T25c clean <path> reports the failure (rc != 0)" \
      || ok 1 "T25c clean <path> reported success for a failed removal"
  else
    ok 1 "T25b the immutable fixture was removed — the invariant was not exercised"
    ok 1 "T25c (not reached)"
  fi
  chflags -R nouchg "$D25" 2>/dev/null || true
  chmod -R u+rwX "$D25" 2>/dev/null || true
  rm -rf "$D25" 2>/dev/null || true
  sx clean --all --force-all >/dev/null 2>&1
  [ "$(live_scratch)" = 0 ] && ok 0 "T25d fixture reclaimed" || ok 1 "T25d fixture reclaimed"
else
  ok 0 "T25 skipped (no chflags / not Darwin) — the mode-000 retry path is T24"
fi

# ── T26: the orphan reclaim is TARGET-SPECIFIC ─────────────────────────────
# `clean <path>` must report ITS OWN outcome. Counting any reclaimed record made
# it exit 0 because an UNRELATED orphan happened to be swept in the same repo —
# a false PASS, reachable in normal use since the tool itself creates orphans
# (a probe that deletes its own directory). Cycle-11 P1.
D26="$(sx create --ref "$C2" --full 2>/dev/null)"
rm -rf "$D26"
[ "$(live_scratch)" = 1 ] && ok 0 "T26a an orphan record is set up" || ok 1 "T26a an orphan record is set up ($(live_scratch))"
FOREIGN26="$FIX/foreign26"
mkdir -p "$FOREIGN26"
sx clean "$FOREIGN26" >/dev/null 2>&1
RC26=$?
[ "$RC26" != 0 ] && ok 0 "T26b a foreign path is still refused (rc=$RC26)" \
  || ok 1 "T26b a foreign path reported success (rc=$RC26)"
[ "$(live_scratch)" = 1 ] && ok 0 "T26c the unrelated orphan is not silently reclaimed" \
  || ok 1 "T26c the unrelated orphan was swept as a side effect"
sx clean "$D26" >/dev/null 2>&1
RC26b=$?
[ "$RC26b" = 0 ] && ok 0 "T26d cleaning the gone path reclaims ITS record (rc=$RC26b)" \
  || ok 1 "T26d cleaning the gone path did not reclaim its record (rc=$RC26b)"
[ "$(live_scratch)" = 0 ] && ok 0 "T26e no record survives" || ok 1 "T26e a record survives"
rm -rf "$FOREIGN26"

echo
if [ "$FAILS" = 0 ]; then echo "ALL PASS"; exit 0; else echo "$FAILS FAILURE(S)"; exit 1; fi
