#!/usr/bin/env bash
# claim-cwd.test.sh — the claim builder must work from a cwd it was never given, and must FAIL
# rather than quietly run in one it was not given either.
#
# THE INCIDENT THIS PINS (2026-10-18, live controller). The launchd cell runs orch-loop.sh with
# WorkingDirectory=$HOME — NOT a repository. `claims.sh` then built every claim commit with
# `git -C "$CLAIM_REPO"`, and CLAIM_REPO defaulted to `.`; the builder returned an EMPTY hash, so
# `_claim_acquire_at` refused EVERY candidate in the queue:
#     [dispatch] #4513 NOT dispatched — could not build claim commit
#     [dispatch] #4622 NOT dispatched — could not build claim commit
#     … six per cycle, every cycle. The controller looked ALIVE (it logged, it polled, it ordered
#     the pool) and dispatched nothing: a total-stall that emits no error of its own.
# After the two-line fix in claims.sh the same cycle logged
#     [dispatch] load=71 lanes=0 -> 4508 4513
# and dispatch resumed. A live patch with no test is how a redeploy reverts it — this file is the
# regression guard, and it was written to be RED on the pre-fix file (measured, see NON-VACUITY).
#
# WHAT IS UNDER TEST — the fix is TWO code hunks, and the suite pins TEN hazard classes (C1–C10);
# each has its OWN discriminator, so reverting any single guard reddens exactly one group:
#   C1 `_git` must put git's cwd RIGHT BEFORE git is exec'd, not merely TELL git about it with `-C`.
#      `git -C <dir>` still STARTS in the caller's cwd and must resolve it; on the affected cells
#      that read is denied (`fatal: Unable to read current working directory: Operation not
#      permitted`). The check runs the SHIPPED builder with its cwd set to a directory that cannot
#      be resolved at all, so a git that must read its inherited cwd dies — exactly as it did live.
#   C2 `CLAIM_REPO` must default to `${REPO:-.}`, not `.`. With only REPO set and a cwd that is not
#      a repository, `.` resolves to nothing and the builder returns empty. [RED→GREEN]
#   C3 an explicit CLAIM_REPO must still WIN over REPO. [PINNED]
#   C4 an unusable CLAIM_REPO must FAIL CLOSED, never run git in the caller's cwd. [PINNED]
#
# ⛔ THE DEFECTS THE `cd` MECHANISM ITSELF INTRODUCED (2026-10-18 reviews, all measured). Turning
# `git -C` into `cd` is not a free swap: `-C` treats its argument literally, while `cd` is a shell
# builtin with its own resolution rules. Each of these was found by a review round of THIS fix.
#   C5 an EMPTY CLAIM_REPO — in BOTH orderings. `cd ""` SUCCEEDS and leaves the cwd alone, so a bare
#      `|| return 1` never fired and a full acquire pushed a claim ref into the CALLER's repo — a
#      repository nobody named. An EMPTY value that is SET before source time must also stay refused
#      rather than being coerced into a default. [RED→GREEN]
#   C6 a RELATIVE $REPO from a caller that already `cd`'d into it (fix-one.sh:49+96,
#      merge-one.sh:52+190 both do exactly this and never set CLAIM_REPO). Resolving `$REPO` from
#      inside `$REPO` names `$REPO/$REPO`, which does not exist, so every claim was refused with the
#      SAME "could not build claim commit" the fix exists to remove. [PINNED — `.` was the pre-fix
#      answer and is still the right one for this caller shape]
#   C7 `$CDPATH` REDIRECTING THE CD. The builtin searches CDPATH for a relative path and a same-named
#      directory there WINS over the local one (measured), which `git -C` never did — so a relative
#      CLAIM_REPO could run every git call, and push the claim, in a repo the caller never named.
#      Now `CDPATH=` is emptied for the `cd`. [PINNED against the pre-fix tree, since `-C` ignored
#      CDPATH — it goes RED on the intermediate `cd`-without-`CDPATH=` form, which is why it exists]
#   C8 THE SAME-NAMED SUBDIRECTORY. C6's shape plus `$REPO/$REPO` existing as its OWN repo: a default
#      keyed on `[ -d "$REPO" ]` said "yes" and acquired in the INNER repo — a wrong-origin claim with
#      `RESULT=acquired`, i.e. the duplicate dispatch this registry exists to prevent, silently. The
#      discriminator is "is the cwd already a work-tree root", and this check is what pins it.
#   C9 A BARE `cd` OPTION. `CLAIM_REPO=-P` is not a path: `cd -P` takes NO operand and SUCCEEDS into
#      $HOME (measured), so without `--` a bare-option value claims into whatever repo $HOME is —
#      while `-C` read it as a directory name and failed. [PINNED — `--` is load-bearing]
#   C10 AN ABSOLUTE $REPO WHILE STANDING IN ANOTHER REPO'S ROOT. The cwd-root test alone answers `.`
#      there, so a caller naming repo B absolutely got `RESULT=acquired` on repo A's origin, silently
#      — C8's class, one shape over. An absolute path needs no resolution, so it is used as named.
#      [RED→GREEN]
#      [PINNED against the pre-fix tree (`.` was already right there); RED on the `-d`-only form]
#
# ⛔ THE ONE STAND-IN, STATED PLAINLY (C1). The live trigger is an OS-level denial of the process's
# cwd (macOS TCC returns EPERM for a launchd agent whose cwd sits under a protected path). That
# denial cannot be constructed hermetically — a deleted cwd reproduces a FAILING getcwd, but REAL
# git chdirs to its -C target first and never performs that read, so real git alone cannot witness
# the defect. C1 therefore puts a `git` SHIM first on PATH whose ONLY behaviour is the read the OS
# denies: it calls `/bin/pwd -P` (getcwd) on the cwd it was STARTED in and dies with the production
# fatal if that fails; otherwise it execs the REAL git with the shim stripped from PATH. The read is
# real, the shipped claims.sh is real, and the assertion is behavioural (a claim commit is produced
# and acquired) — but the DENIAL is modelled. C2 needs no shim and uses real git end to end, so the
# `REPO` default is proven without any substitution at all.
#
# LABELLING (the convention cloud-cell-record-dep.test.sh states): a check marked [RED→GREEN] FAILS
# on the pre-fix tree and passes after; one marked [PINNED] passes both ways and exists so a later
# refactor cannot remove a property the fix must not trade away. NON-VACUITY was measured against
# FOUR baselines, and the middle ones are why the hardening exists (all figures reproduced from the
# scripts in /tmp; the first is `git show <main>:scripts/orchestrator-harness/claims.sh`, which is
# reproducible from this repo without the owner's machine):
#   <pre-fix main>          → C1, C2 and C5 fail and carry the live log line, "could not build
#                             claim commit", out of the real builder path
#   <the two hunks alone>   → C5, C6 and C7 fail: the empty value still pushed a claim into the
#                             CALLER's repo, a relative $REPO restored the SAME stall, and a
#                             relative CLAIM_REPO ran (and claimed) in the $CDPATH DECOY repo
#   <no absolute-REPO branch> → C10 fails alone: an absolute $REPO was ignored for `.`, claiming on
#                             the cwd repo's origin instead of the one the caller named
#   <this file>             → all green. Exact counts are printed in the README section for this
#                             suite rather than quoted here, so they cannot drift apart.
#
# HERMETIC: every check builds its own throwaway origin (`git init --bare`) and work repo, so no
# network, no real origin and nothing outside $T is written — the claim refs die with the temp dir.
# Path comparisons are against `pwd -P` (macOS `/var` -> `/private/var`; `$TMPDIR` ends in `/`).
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# ⛔ OVERRIDABLE so the non-vacuity claim above can be RE-MEASURED rather than believed: this is the
# seam that lets the pre-fix file be fed in. It is also how a reviewer checks the RED direction.
CLAIMS_SH="${CLAIMS_SH:-$HERE/claims.sh}"
[ -f "$CLAIMS_SH" ] || { echo "❌ missing $CLAIMS_SH"; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ❌ $1"; }
# ck <label> <rc> — `[ … ]` first, `$?` passed in; never a pipeline into `grep -q` (SIGPIPE, #841).
ck()  { if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1"; fi; }
# field <captured-output> <KEY> — read one `KEY=value` line back out of a captured subshell run.
field() { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }

T="$(mktemp -d "${TMPDIR:-/tmp}/claim-cwd.XXXXXX")" || exit 2
# ⛔ RESOLVED TO ITS PHYSICAL PATH BEFORE ANY COMPARISON. On macOS `/var` is a symlink to
# `/private/var`, and `$TMPDIR` ends in `/` — so a path this file CONSTRUCTS and a path git
# REPORTS can differ as strings while naming one directory. C3 compares them, so the mismatch has
# to be removed here rather than papered over with a substring match.
T="$(cd "$T" && pwd -P)" || exit 2
trap 'rm -rf "$T"' EXIT INT TERM
REAL_GIT="$(command -v git)" || { echo "❌ git not found"; exit 2; }
BASE_PATH="$PATH"
SHA=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef

# mk_box <name> -> prints the path of a work repo whose `origin` is a fresh bare repo.
# Setup uses "$REAL_GIT" explicitly: it must never be routed through the C1 shim.
mk_box() {
  local d="$T/$1"
  mkdir -p "$d" || return 1
  "$REAL_GIT" init -q --bare "$d/origin.git" || return 1
  "$REAL_GIT" init -q "$d/repo" || return 1
  "$REAL_GIT" -C "$d/repo" remote add origin "$d/origin.git" || return 1
  printf '%s' "$d/repo"
}
# has_ref <repo> <ref> -> 0 when the ref exists on that repo's origin
has_ref() { "$REAL_GIT" -C "$1" ls-remote --exit-code origin "$2" >/dev/null 2>&1; }

echo "── C1: the builder from a cwd that CANNOT BE RESOLVED (the live stall) ──────────────"
# The shim is the OS denial, and nothing else. `/bin/pwd -P` is a real getcwd on the cwd this
# process was started in — it fails for a deleted directory (measured, both macOS 3.2 and Linux).
mkdir -p "$T/bin"
cat > "$T/bin/git" <<'SHIM'
#!/bin/sh
# Stands in for the launchd cell's denied cwd read. Real getcwd on the INHERITED cwd; no fallback
# to $PWD (a shell builtin would fall back, and the point is that the read itself is unavailable).
if ! /bin/pwd -P >/dev/null 2>&1; then
  echo "fatal: Unable to read current working directory: Operation not permitted" >&2
  exit 128
fi
PATH="$CLAIM_CWD_TEST_REAL_PATH"; export PATH
exec "$CLAIM_CWD_TEST_REAL_GIT" "$@"
SHIM
chmod +x "$T/bin/git" || exit 2

R1="$(mk_box c1)" || { echo "❌ could not build the C1 fixture"; exit 2; }
DEAD="$T/deadcwd"; mkdir -p "$DEAD" || exit 2
out1="$(
  cd "$DEAD" || exit 1
  rmdir "$DEAD" || exit 1          # from here the process cwd is genuinely unresolvable
  PATH="$T/bin:$BASE_PATH"; export PATH
  CLAIM_CWD_TEST_REAL_GIT="$REAL_GIT"; export CLAIM_CWD_TEST_REAL_GIT
  CLAIM_CWD_TEST_REAL_PATH="$BASE_PATH"; export CLAIM_CWD_TEST_REAL_PATH
  CLAIM_REPO="$R1"; export CLAIM_REPO       # as orch-loop.sh sets it: the TARGET repo
  . "$CLAIMS_SH"
  # 1) the BUILDER alone — the exact function whose empty output the controller logs.
  printf 'BUILD=%s\n' "$(_claim_commit c1owner 9999999999)"
  # 2) the full acquisition the dispatch path performs.
  claim_acquire "$R1" 4513 "$SHA" >/dev/null 2>&1; printf 'ACQ_RC=%s\n' "$?"
  printf 'ACQ_COMMIT=%s\nACQ_RESULT=%s\n' "${CLAIM_COMMIT:-}" "${CLAIM_RESULT:-}"
)"
BUILD1="$(field "$out1" BUILD)"; ACQ1="$(field "$out1" ACQ_RC)"
COMMIT1="$(field "$out1" ACQ_COMMIT)"; RESULT1="$(field "$out1" ACQ_RESULT)"
[ -n "$BUILD1" ]; ck "C1 [RED→GREEN] _claim_commit produces a commit from an unresolvable cwd (live: empty -> 'could not build claim commit')" $?
[ "$ACQ1" = "0" ]; ck "C1 [RED→GREEN] claim_acquire returns 0 from an unresolvable cwd (got rc='${ACQ1}', result='${RESULT1}')" $?
[ -n "$COMMIT1" ]; ck "C1 [RED→GREEN] the acquisition reports a claim commit (got '${COMMIT1}')" $?
has_ref "$R1" "refs/claims/4513-deadbeefdead"; ck "C1 [RED→GREEN] the claim ref actually LANDED on the target origin (refs/claims/4513-deadbeefdead)" $?
# The unresolvable cwd must not have been silently substituted for any OTHER directory: the claim
# carries the nonce, and the commit exists only in the repo the claim names.
case "$RESULT1" in
  "acquired refs/claims/4513-deadbeefdead"*) ok "C1 [RED→GREEN] the claim was acquired against CLAIM_REPO, not against some other repo" ;;
  *) bad "C1 [RED→GREEN] the claim was acquired against CLAIM_REPO (result='${RESULT1}')" ;;
esac

echo
echo "── C2: REPO alone is a usable default, not '.' ─────────────────────────────────────"
# No shim here: real git, end to end. The cwd is a plain NON-repository directory (readable), so
# `.` resolves to nothing at all — the pre-fix default's second failure, independent of C1's denial.
R2="$(mk_box c2)" || { echo "❌ could not build the C2 fixture"; exit 2; }
PLAIN="$T/plaincwd"; mkdir -p "$PLAIN" || exit 2
out2="$(
  cd "$PLAIN" || exit 1
  unset CLAIM_REPO                 # only REPO is given — a caller that needs no explicit CLAIM_REPO
  REPO="$R2"; export REPO
  . "$CLAIMS_SH"
  printf 'RESOLVED=%s\n' "$CLAIM_REPO"
  printf 'BUILD=%s\n' "$(_claim_commit c2owner 9999999999)"
  claim_acquire "$R2" 4622 "$SHA" >/dev/null 2>&1; printf 'ACQ_RC=%s\n' "$?"
  printf 'ACQ_COMMIT=%s\n' "${CLAIM_COMMIT:-}"
)"
RESOLVED2="$(field "$out2" RESOLVED)"; BUILD2="$(field "$out2" BUILD)"
ACQ2="$(field "$out2" ACQ_RC)"; COMMIT2="$(field "$out2" ACQ_COMMIT)"
[ "$RESOLVED2" = "$R2" ]; ck "C2 [RED→GREEN] CLAIM_REPO unset + REPO set resolves to REPO (got '${RESOLVED2}')" $?
[ -n "$BUILD2" ]; ck "C2 [RED→GREEN] the builder produces a commit with cwd outside the repo and only REPO set" $?
[ "$ACQ2" = "0" ] && [ -n "$COMMIT2" ]; ck "C2 [RED→GREEN] claim_acquire acquires through the REPO-derived CLAIM_REPO (rc='${ACQ2}')" $?
has_ref "$R2" "refs/claims/4622-deadbeefdead"; ck "C2 [RED→GREEN] the claim ref landed on REPO's origin (refs/claims/4622-deadbeefdead)" $?

echo
echo "── C3: an explicit CLAIM_REPO still WINS over REPO ─────────────────────────────────"
# [PINNED]: the new default must not shadow a caller that names the repo explicitly — chain-merge.sh
# and dispatch-merge.sh both set CLAIM_REPO="$REPO", and a future "prefer REPO" refactor would
# silently retarget them at whatever REPO happens to be.
R3="$(mk_box c3)" || { echo "❌ could not build the C3 fixture"; exit 2; }
R3B="$(mk_box c3b)" || { echo "❌ could not build the C3b fixture"; exit 2; }
out3="$(
  cd "$T" || exit 1
  CLAIM_REPO="$R3"; export CLAIM_REPO
  REPO="$R3B"; export REPO
  . "$CLAIMS_SH"
  printf 'RESOLVED=%s\n' "$CLAIM_REPO"
  printf 'GDIR=%s\n' "$(_git rev-parse --absolute-git-dir 2>/dev/null)"
)"
RESOLVED3="$(field "$out3" RESOLVED)"; GDIR3="$(field "$out3" GDIR)"
[ "$RESOLVED3" = "$R3" ]; ck "C3 [PINNED] CLAIM_REPO set + REPO set different: CLAIM_REPO wins (got '${RESOLVED3}')" $?
# The git calls must follow CLAIM_REPO, not just the variable: the resolved git dir is C3's.
case "$GDIR3" in
  "$R3"/*) case "$GDIR3" in
             "$R3B"/*) bad "C3 [PINNED] git runs against CLAIM_REPO, not REPO (git dir '${GDIR3}' is under the REPO box)" ;;
             *) ok "C3 [PINNED] git runs against CLAIM_REPO, not REPO" ;;
           esac ;;
  *) bad "C3 [PINNED] git runs against CLAIM_REPO (git dir '${GDIR3}' is not under '${R3}')" ;;
esac

echo
echo "── C4: an unresolvable CLAIM_REPO FAILS CLOSED (never 'runs anyway') ───────────────"
# [PINNED], and it is the guard for the `|| return 1` half of the fix. The danger a subshell `cd`
# introduces is a silent fall-through: if `cd` failed and git still ran, git would run in the
# CALLER's cwd — resolving `origin` to the wrong repo, i.e. pushing a claim into (or deleting a
# ref from) a repository the caller never named. So the caller's cwd here IS a real repo with a
# real origin, and the check is that nothing lands on it.
out4="$(
  cd "$R3B" || exit 1                       # a REAL repo: the fall-through target
  CLAIM_REPO="$T/does-not-exist"; export CLAIM_REPO
  unset REPO
  . "$CLAIMS_SH"
  _git rev-parse --show-toplevel >/dev/null 2>&1; printf 'GIT_RC=%s\n' "$?"
  claim_acquire "$T/does-not-exist" 4625 "$SHA" >/dev/null 2>&1; printf 'ACQ_RC=%s\n' "$?"
  printf 'RESULT=%s\n' "${CLAIM_RESULT:-}"
)"
GIT_RC4="$(field "$out4" GIT_RC)"; ACQ4="$(field "$out4" ACQ_RC)"; RESULT4="$(field "$out4" RESULT)"
[ "$GIT_RC4" != "0" ]; ck "C4 [PINNED] a git call on an unresolvable CLAIM_REPO fails (rc='${GIT_RC4}', not 0)" $?
[ "$ACQ4" = "2" ]; ck "C4 [PINNED] claim_acquire reports an infra failure (rc='${ACQ4}', want 2)" $?
[ "$RESULT4" = "could not build claim commit" ]; ck "C4 [PINNED] the refusal is the log line the controller emits (got '${RESULT4}')" $?
# The proof that nothing ran in the caller's cwd: no claim ref of ANY name reached that origin.
STRAY="$("$REAL_GIT" -C "$R3B" ls-remote origin 'refs/claims/*' 2>/dev/null)"
[ -z "$STRAY" ]; ck "C4 [PINNED] nothing was pushed to the caller's cwd repo (no silent fall-through)" $?

echo
echo "── C5: an EMPTY CLAIM_REPO fails closed (never 'cd' into the caller instead) ─────────"
# ⛔ `cd ""` SUCCEEDS, so `|| return 1` alone does NOT close this hole — measured on this box before
# the guard was added: a full `claim_acquire` with CLAIM_REPO="" built a commit and pushed
# `refs/claims/…` into the CALLER's repo. The caller's cwd here is therefore a real repo with a real
# origin, and the check is that NOTHING lands on it.
out5="$(
  cd "$R3B" || exit 1                     # a real repo: the fall-through target
  unset REPO
  . "$CLAIMS_SH"
  CLAIM_REPO=""; export CLAIM_REPO        # empty AFTER source time, so the default cannot mask it
  _git rev-parse --show-toplevel >/dev/null 2>&1; printf 'GIT_RC=%s\n' "$?"
  claim_acquire "$R3B" 4628 "$SHA" >/dev/null 2>&1; printf 'ACQ_RC=%s\n' "$?"
)"
GIT_RC5="$(field "$out5" GIT_RC)"; ACQ5="$(field "$out5" ACQ_RC)"
[ "$GIT_RC5" != "0" ]; ck "C5 [RED→GREEN] an EMPTY CLAIM_REPO fails instead of running git in the caller's cwd (rc='${GIT_RC5}')" $?
[ "$ACQ5" = "2" ]; ck "C5 [RED→GREEN] claim_acquire is an infra refusal, not an acquisition (rc='${ACQ5}', want 2)" $?
STRAY5="$("$REAL_GIT" -C "$R3B" ls-remote origin 'refs/claims/*' 2>/dev/null)"
[ -z "$STRAY5" ]; ck "C5 [RED→GREEN] no claim ref was pushed into the caller's repo" $?

# C5b — the SAME hazard in the other ORDERING: an empty CLAIM_REPO that is already SET when the file
# is sourced must stay refused, not be coerced into a default (which is how an empty value became
# `.` and reached the caller's repo). Two orderings, one guarantee.
out5b="$(
  cd "$R3B" || exit 1
  unset REPO
  CLAIM_REPO=""; export CLAIM_REPO        # SET and EMPTY *before* source time
  . "$CLAIMS_SH"
  printf 'RESOLVED_SET=%s\n' "${CLAIM_REPO+set}"
  claim_acquire "$R3B" 4629 "$SHA" >/dev/null 2>&1; printf 'ACQ_RC=%s\n' "$?"
)"
ACQ5B="$(field "$out5b" ACQ_RC)"
[ "$ACQ5B" = "2" ]; ck "C5 [RED→GREEN] an empty CLAIM_REPO present BEFORE source is NOT turned into a default (rc='${ACQ5B}', want 2)" $?
STRAY5B="$("$REAL_GIT" -C "$R3B" ls-remote origin 'refs/claims/*' 2>/dev/null)"
[ -z "$STRAY5B" ]; ck "C5 [RED→GREEN] and still nothing pushed into the caller's repo (pre-set ordering)" $?

echo
echo "── C6: a RELATIVE REPO from a caller that already cd'd into it ───────────────────────"
# The shape fix-one.sh / merge-one.sh / adopt-fix.sh actually have: `cd "$REPO"` FIRST, then source
# this file with no CLAIM_REPO. With a relative $REPO the default must still name a directory that
# EXISTS (`$REPO` resolved from inside `$REPO` is `$REPO/$REPO`), or the caller gets the pre-fix
# stall back. [PINNED] — `.` was the correct pre-fix answer here too.
R6="$(mk_box c6)" || { echo "❌ could not build the C6 fixture"; exit 2; }
out6="$(
  cd "$T/c6" || exit 1          # the PARENT of the repo, as a caller standing outside it
  REPO="repo"; export REPO      # RELATIVE, deliberately
  cd "$REPO" || exit 1          # what the three shipped callers do before sourcing
  unset CLAIM_REPO
  . "$CLAIMS_SH"
  claim_acquire "$REPO" 4643 "$SHA" >/dev/null 2>&1; printf 'ACQ_RC=%s\n' "$?"
  printf 'ACQ_COMMIT=%s\nACQ_RESULT=%s\n' "${CLAIM_COMMIT:-}" "${CLAIM_RESULT:-}"
)"
ACQ6="$(field "$out6" ACQ_RC)"; COMMIT6="$(field "$out6" ACQ_COMMIT)"; RESULT6="$(field "$out6" ACQ_RESULT)"
[ "$ACQ6" = "0" ] && [ -n "$COMMIT6" ]; ck "C6 [PINNED] a relative REPO after 'cd \$REPO' still acquires (rc='${ACQ6}', result='${RESULT6}')" $?
has_ref "$R6" "refs/claims/4643-deadbeefdead"; ck "C6 [PINNED] the claim ref landed on THAT repo's origin" $?

echo
echo "── C7: \$CDPATH must not redirect the claim repo ───────────────────────────────────────"
# The `cd` builtin searches $CDPATH for a relative name, and a same-named directory there WINS over
# the local one (measured) — `git -C` never did that. Both repos below are real, each with its own
# origin, so the assertion is not 'the cd worked' but 'the claim landed in the NAMED repo'.
R7="$(mk_box c7)" || { echo "❌ could not build the C7 fixture"; exit 2; }
R7T="$(mk_box c7trap)" || { echo "❌ could not build the C7 trap fixture"; exit 2; }
out7="$(
  cd "$T/c7" || exit 1                     # here a directory named `repo` exists: the REAL one
  CDPATH="$T/c7trap"; export CDPATH      # ...and here another `repo`: the decoy
  CLAIM_REPO="repo"; export CLAIM_REPO
  . "$CLAIMS_SH"
  printf 'GDIR=%s\n' "$(_git rev-parse --absolute-git-dir 2>/dev/null)"
  claim_acquire "repo" 4625 "$SHA" >/dev/null 2>&1; printf 'ACQ_RC=%s\n' "$?"
)"
GDIR7="$(field "$out7" GDIR)"; ACQ7="$(field "$out7" ACQ_RC)"
case "$GDIR7" in
  "$R7"/*) ok "C7 [PINNED] a relative CLAIM_REPO resolves in the CALLER's cwd, not through \$CDPATH" ;;
  *) bad "C7 [PINNED] a relative CLAIM_REPO resolves in the caller's cwd (git dir '${GDIR7}' is not under '${R7}'; trap is '${R7T}')" ;;
esac
[ "$ACQ7" = "0" ]; ck "C7 [PINNED] the acquisition succeeds against the named repo (rc='${ACQ7}')" $?
has_ref "$R7" "refs/claims/4625-deadbeefdead"; ck "C7 [PINNED] the claim ref landed on the NAMED repo's origin" $?
STRAY7="$("$REAL_GIT" -C "$R7T" ls-remote origin 'refs/claims/*' 2>/dev/null)"
[ -z "$STRAY7" ]; ck "C7 [PINNED] nothing was pushed into the \$CDPATH decoy's origin" $?

echo
echo "── C8: a SAME-NAMED subdirectory that is ITSELF a repo (wrong-origin claim) ─────────"
# The trap C6 does not cover: in that caller shape `$REPO/$REPO` EXISTS as its own repository, so a
# default keyed on `[ -d "$REPO" ]` says "yes" and every git call runs in the INNER repo — acquiring
# with rc=0 and `RESULT=acquired` in a repo nobody named. Nothing errors; the claim is simply
# somewhere else, which is exactly the duplicate dispatch the registry exists to prevent. The
# discriminator has to be "the cwd is already a work-tree root", not "$REPO names a directory".
R8="$(mk_box c8)" || { echo "❌ could not build the C8 fixture"; exit 2; }
"$REAL_GIT" init -q --bare "$T/c8/inner.git" || exit 2
"$REAL_GIT" init -q "$R8/repo" || exit 2                 # $REPO/$REPO — a repo named the same
"$REAL_GIT" -C "$R8/repo" remote add origin "$T/c8/inner.git" || exit 2
out8="$(
  cd "$T/c8" || exit 1
  REPO="repo"; export REPO
  cd "$REPO" || exit 1
  unset CLAIM_REPO
  . "$CLAIMS_SH"
  printf 'GDIR=%s\n' "$(_git rev-parse --absolute-git-dir 2>/dev/null)"
  claim_acquire "$REPO" 4630 "$SHA" >/dev/null 2>&1; printf 'ACQ_RC=%s\n' "$?"
)"
GDIR8="$(field "$out8" GDIR)"
case "$GDIR8" in
  "$R8/repo"/*) bad "C8 [PINNED] the claim repo is the cwd work tree, not the same-named child ('${GDIR8}') is the INNER repo)" ;;
  "$R8"/*) ok "C8 [PINNED] the claim repo is the cwd work tree, not the same-named child repo" ;;
  *) bad "C8 [PINNED] the claim repo resolves inside the NAMED repo (git dir '${GDIR8}')" ;;
esac
has_ref "$R8" "refs/claims/4630-deadbeefdead"; ck "C8 [PINNED] the claim ref landed on the NAMED repo's origin" $?
STRAY8="$("$REAL_GIT" -C "$R8/repo" ls-remote origin 'refs/claims/*' 2>/dev/null)"
[ -z "$STRAY8" ]; ck "C8 [PINNED] NOTHING was pushed to the same-named child repo's origin (no silent wrong-repo claim)" $?

echo
echo "── C9: a BARE cd OPTION must not be read as a directory (pins the `--`) ───────────────"
# `CLAIM_REPO=-P` is not a path: without `--`, `cd -P` takes NO operand and SUCCEEDS into $HOME
# (measured) — so a bare-option value would claim into whatever repo $HOME happens to be. `$HOME`
# here IS such a repo, with its own origin, so the check is behavioural: the claim must be refused
# and $HOME's origin must stay clean. Without `--` this goes RED with acq=0 and a pushed ref.
R9="$(mk_box c9home)" || { echo "❌ could not build the C9 fixture"; exit 2; }
out9="$(
  cd "$T" || exit 1                       # a NON-repo cwd, as the controller has
  HOME="$R9"; export HOME
  unset REPO
  . "$CLAIMS_SH"
  CLAIM_REPO="-P"; export CLAIM_REPO
  _git rev-parse --show-toplevel >/dev/null 2>&1; printf 'GIT_RC=%s\n' "$?"
  claim_acquire "$R9" 4700 "$SHA" >/dev/null 2>&1; printf 'ACQ_RC=%s\n' "$?"
)"
GIT_RC9="$(field "$out9" GIT_RC)"; ACQ9="$(field "$out9" ACQ_RC)"
[ "$GIT_RC9" != "0" ]; ck "C9 [PINNED] a bare-option CLAIM_REPO fails instead of cd'ing to \$HOME (rc='${GIT_RC9}')" $?
[ "$ACQ9" = "2" ]; ck "C9 [PINNED] the acquisition is refused (rc='${ACQ9}', want 2)" $?
STRAY9="$("$REAL_GIT" -C "$R9" ls-remote origin 'refs/claims/*' 2>/dev/null)"
[ -z "$STRAY9" ]; ck "C9 [PINNED] nothing was pushed into \$HOME's repo (the '--' is load-bearing)" $?

echo
echo "── C10: an ABSOLUTE REPO is honoured even when the cwd is ANOTHER repo's root ────────"
# The caller names repo B absolutely while standing in repo A's root. A default that answers `.`
# whenever the cwd is a work-tree root claims on A's origin, silently, with `RESULT=acquired` — the
# C8 failure class one shape over. An absolute path needs no resolution, so it must simply be used.
R10A="$(mk_box c10a)" || { echo "❌ could not build the C10 fixtures"; exit 2; }
R10B="$(mk_box c10b)" || { echo "❌ could not build the C10 fixtures"; exit 2; }
out10="$(
  cd "$R10A" || exit 1                    # inside repo A, at its root
  REPO="$R10B"; export REPO               # ABSOLUTE, naming repo B
  unset CLAIM_REPO
  . "$CLAIMS_SH"
  printf 'RESOLVED=%s\n' "$CLAIM_REPO"
  claim_acquire "$R10B" 4701 "$SHA" >/dev/null 2>&1; printf 'ACQ_RC=%s\n' "$?"
)"
RESOLVED10="$(field "$out10" RESOLVED)"; ACQ10="$(field "$out10" ACQ_RC)"
[ "$RESOLVED10" = "$R10B" ]; ck "C10 [RED→GREEN] an absolute REPO is used as named (got '${RESOLVED10}')" $?
[ "$ACQ10" = "0" ]; ck "C10 [RED→GREEN] the acquisition succeeds (rc='${ACQ10}')" $?
has_ref "$R10B" "refs/claims/4701-deadbeefdead"; ck "C10 [RED→GREEN] the claim ref landed on the NAMED repo's origin" $?
STRAY10="$("$REAL_GIT" -C "$R10A" ls-remote origin 'refs/claims/*' 2>/dev/null)"
[ -z "$STRAY10" ]; ck "C10 [RED→GREEN] nothing was pushed to the CWD repo's origin (no silent wrong-repo claim)" $?

echo
echo "================ RESULT: $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
