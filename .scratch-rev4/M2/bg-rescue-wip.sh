#!/usr/bin/env bash
# bg-rescue-wip.sh <worktree> [note] — archive a worktree's UNCOMMITTED work to the remote.
#
# ⛔ WHY THIS EXISTS (agent-infra#2045). A lane dies at its cap with its work in the working tree and
# nothing in the object database. Measured on one fleet overnight: 4 of 6 lanes were killed at the cap
# having done 193-342 KB of reading and committed NOTHING, and the disk was the only copy. The one fix
# that survived did so because a sibling lane had committed it by hand minutes earlier. A cap that
# kills work is a data-loss mechanism, not a safety valve — so the kill is preceded by a rescue.
#
# WHAT IT GUARANTEES: after it returns 0, every TRACKED and UNTRACKED byte of the worktree's own files
# (minus ignored paths, and minus the CONTENTS of nested repositories/submodules — see LIMITS) exists
# as a commit reachable from `refs/wip/<slug>` on `origin`, where <slug> CARRIES THE ISSUE
# (`fix/3442-nonvacuity` → `refs/wip/issue-3442-nonvacuity`) — agent-infra#3484: 222 archives existed
# and nothing could map them back to an issue. A branch with no issue in it is still rescued and the
# ref's lack of a link is REPORTED. It does NOT commit to the branch,
# does not touch the working tree, and does not move the branch — a rescuer must never change the
# state it is rescuing.
#
# ⛔ IT IS CALLED TWICE, so the archive must ACCUMULATE. The dispatcher rescues before the TERM and
# again after the 20 s grace period, so the second archive is of a CHANGED tree. Each rescue is
# parented on the previous archive commit (not only on HEAD), which makes every push a
# fast-forward and keeps the earlier snapshot reachable — so nothing is replaced, and two lanes that
# happen to share a slug cannot lose one another's work.
#
# ⛔ WHY commit-tree AND NOT `git stash`: `refs/stash` and its reflog live in the COMMON git dir, so the
# stack is repo-GLOBAL. A peer lane's `git stash push` renumbers your entry, and a bare `git stash pop`
# then applies and DROPS THE PEER'S ENTRY into your worktree — it presents as a success (no conflict,
# no warning, exit 0). That is not hypothetical: it destroyed a verified fix on this fleet on
# 2026-10-21. `commit-tree` + a pushed ref has no shared mutable state at all.
#
# A throwaway index (GIT_INDEX_FILE) is what makes "stage everything without touching anything" safe:
# the real index and `git status` are left exactly as the lane left them, so a rescue can run under a
# live process without disturbing it. Every read-only git call here carries GIT_OPTIONAL_LOCKS=0 —
# a plain `git status` rewrites the real index and takes `.git/index.lock`, which would make the live
# lane's own next git command fail.
#
# LIMITS (true, and deliberately not silent):
#   - ignored paths are NOT archived, and git's ignore rules include `.git/info/exclude` and
#     `core.excludesFile`, not just `.gitignore`;
#   - a nested repository or submodule is archived as a GITLINK, not its contents (a warning names
#     each one). A nested repo with no commit would otherwise abort the whole rescue, so staging
#     falls back to per-path and reports what it had to skip;
#   - commits already on the branch but NOT pushed are out of scope — this tool archives uncommitted
#     work. The clean exit says so rather than implying the lane is safe.
#   - ONE credential retry is attempted, and only when the remote's own refusal says WORKFLOW SCOPE
#     (the configured token often lacks `Workflows: write` while a second credential has it,
#     #2292). The predicate is the refusal TEXT, not the remote host or the snapshot's paths: any host
#     whose pre-receive output matches that wording takes the retry, and a host that words it
#     differently does not. Every other refusal is reported as-is — see section 6.
#   - the retry's credential is chosen PER HOST, and it is chosen to be one the CONFIGURED CHAIN did not
#     just use, where this script can tell, in this order: `BG_RESCUE_PUSH_HELPER=<helper>` (an explicit
#     choice, so it wins everywhere), then `BG_RESCUE_PUSH_UNSHADOW=1` (an explicit request for the STORED
#     credential, which is the only way to reach that candidate on macOS), then the platform default —
#     `osxkeychain` on macOS, else the STORED credential with an ambient `GH_TOKEN`/`GITHUB_TOKEN` removed
#     for that attempt (the cell shape). On a host where none of those can be a DIFFERENT credential, no
#     retry is attempted and the run says so rather than spending 45 s re-sending the same token.
#   - ⛔ DECLARED RESIDUALS: WHAT IT CANNOT TELL. `retry_credential` knows which candidates EXIST, never
#     which credential the configured chain actually returned — so two shapes still retry with the very
#     credential that was just refused, and both are stated rather than implied: (i) a helper that never
#     reads the environment (`store`, `cache`) on a host with an ambient token, and (ii) macOS whose
#     configured helper IS `osxkeychain` with a keychain PAT that lacks `Workflows: write` — candidate 3
#     is then the refused credential. Both are what today's code ships; the messages do not claim
#     otherwise, and `BG_RESCUE_PUSH_HELPER=<a store that can push>` is the escape for either.
#   - a host with NO workflow-scoped credential at all still ends local-only, loudly (cause + a valid
#     `refs/wip-local/<slug>` + exit 2). That is what SHIPS today and the alternatives are OPEN with the
#     owner on #2292 — an off-box channel that keeps the snapshot whole (`git bundle` as a release
#     asset), or item 4. ⛔ The one part that IS decided is that the snapshot stays WHOLE: excluding
#     `.github/workflows/` into a side patch is a recorded refusal, so do not "fix" this case that way.
#
# Exit: 0 = nothing at risk, or rescued and pushed (prints the ref + sha)
#       1 = the path is not the root of a git worktree
#       2 = there was work that could NOT be archived or pushed — printed loudly, it is still at risk,
#           and the printed cause says WHY (workflow scope / auth / network / rejected / unclassified)
#
# `--verdict` ASKS THE SAME QUESTION WITHOUT ARCHIVING ANYTHING (agent-infra#3485). It is the ONE
# classifier, exposed — see §2b. Do not re-implement "is anything at risk" anywhere else: a second
# copy is a second answer, and the whole point of this file is that a FAILED status is never read as
# `clean`. Exit in that mode: 0 = clean, 1 = dirty, 2 = CANNOT VERIFY (unmeasured — never "nothing to
# rescue"), and every path this file cannot resolve is 2 as well, because a worktree it cannot read is
# unmeasured. ⛔ THE USAGE FAILURES ARE 2 TOO, INCLUDING A MISSING ARGUMENT: `1` in this mode already
# means `dirty`, so no refusal of any kind may answer with it — an exit-code reader would otherwise read
# "dirty" (or, worse, 0 = clean) out of an invocation that answered nothing. The ordinary mode keeps its
# shipped codes untouched: a missing argument there is still the shell's own usage failure, exit 1.
#
# `--slug <branch>` and `--verdict` are both READ-ONLY modes that return before any archive work, and
# they are MUTUALLY EXCLUSIVE: combining them is a usage error (2 under `--verdict`), never a silent
# answer to the other question at the wrong exit code.
set -uo pipefail

# Two ADDITIVE read-only modes, each of which returns before any archive work (#3484's `--slug`, and
# #3485's `--verdict`). They are MUTUALLY EXCLUSIVE and each is parsed once, so neither can silently
# answer the other's question. Neither moves the ordinary mode's exit codes.
VERDICT_ONLY=0
case "${1:-}" in
  --verdict) VERDICT_ONLY=1; shift ;;
esac

# A USAGE FAILURE IS 1 IN THE ORDINARY MODE (shipped, must not move) AND 2 UNDER `--verdict`, whose 1
# already means `dirty`. One helper, so no refusal can answer with a verdict code it does not own.
usage_fail() {
  echo "usage: bg-rescue-wip.sh [--verdict] <worktree> [note] | bg-rescue-wip.sh --slug <branch>" >&2
  [ "$VERDICT_ONLY" -eq 1 ] && exit 2
  exit 1
}
[ -n "${1:-}" ] || usage_fail
WT="$1"
NOTE="${2:-a lane hit its cap}"

# ── THE REF SLUG, AND ITS ONE HOME (agent-infra#3484) ───────────────────────────────────
# ⛔ THE MEASURED FAILURE. The rescue worked and the work was unfindable: 222 `refs/wip/*` archives
# existed on origin, named from the BRANCH (`fix-3442`, `ai-3194`), and nothing told the next actor to
# look — a diligent agent could not map a ref to the issue it should check. Slack naming is fine for a
# human who remembers; it is useless as a HANDOVER, which is exactly what a rescue is.
#
# So a branch that follows this fleet's DECLARED convention (`<type>/<N>-<slug>`) gets a ref named after
# the ISSUE: `fix/3442-nonvacuity` → `refs/wip/issue-3442-nonvacuity`. A branch outside it is still
# rescued (losing the work is worse) and the caller REPORTS that the ref carries no issue link.
# ⚠️ NOT a digit scan: `detached-0b1d1ec` and `fix/lane-one` contain digits and hex, and reading an
# issue number out of those would attach a real rescue to the WRONG issue. Only `<type>/<N>` is trusted.
# ⛔ AND THIS IS THE ONLY COPY OF THE RULE. `spawn-gate.sh`'s exit path has to read back
# `refs/wip-local/<slug>` to record what this run wrote, so it asks for the slug here
# (`--slug <branch>`) instead of deriving it again: a second derivation is how a ledger came to name
# `refs/wip-local/fix-4242-x` over an archive this tool had written to
# `refs/wip-local/issue-4242-x` — a handover record pointing at nothing.
# Sets the globals WIP_ISSUE (the issue, or empty) and SLUG (the ref component).
wip_ref_parts() { # wip_ref_parts <branch>
  local br="${1:-}" tail
  WIP_ISSUE=""
  case "$br" in
    */*)
      case "${br%%/*}" in
        fix|rescue|feat|chore|docs|test|hotfix|wip|issue|pr)
          case "${br#*/}" in
            [0-9]*) WIP_ISSUE="${br#*/}"; WIP_ISSUE="${WIP_ISSUE%%[!0-9]*}" ;;
          esac ;;
      esac ;;
  esac
  if [ -n "$WIP_ISSUE" ]; then
    tail="${br#*/}"                 # drop the type prefix
    tail="${tail#"$WIP_ISSUE"}"     # drop the issue number
    tail="${tail#-}"                # and the separator after it
    SLUG="issue-$WIP_ISSUE${tail:+-$tail}"
  else
    SLUG="$br"
  fi
  # A `/` is not legal in a ref name (the original rule), and neither is a space.
  SLUG="$(printf '%s' "$SLUG" | tr '/ ' '--')"
  return 0
}

# `--slug <branch>`: print the ref component for a branch and nothing else — the ONE derivation, so a
# reader cannot disagree with the writer about which ref exists.
if [ "${1:-}" = "--slug" ]; then
  # ⛔ THE MODES ARE EXCLUSIVE. `--verdict --slug x` used to fall through to this branch (the verdict
  # shift left `--slug` as $1), answer the SLUG question, and exit 0 — which in verdict mode means
  # `clean`. A refusal, so it cannot be read as an answer either way.
  [ "$VERDICT_ONLY" -eq 0 ] || usage_fail
  case "${2:-}" in ''|--*) echo "usage: bg-rescue-wip.sh --slug <branch>" >&2; exit 1 ;; esac
  wip_ref_parts "$2"
  printf '%s\n' "$SLUG"
  exit 0
fi

# ⛔ NO `$$` IN A TEMP PATH. A predictable name in /tmp is guessable, so a pre-planted SYMLINK makes
# `2>/tmp/.bgrescue-add.$$` truncate an arbitrary file the running user can write — demonstrated
# destroying a 0600 file with no error. mktemp creates the file exclusively, and one trap owns all
# three so a SIGKILL of the rescue cannot leave them behind.
TMPD="${TMPDIR:-/tmp}"
ERRF="$(mktemp "$TMPD/bg-rescue-err.XXXXXX")" || { echo "bg-rescue-wip: cannot create a temp file in $TMPD" >&2; exit 2; }
IDX=""
cleanup() { rm -f "$ERRF" ${IDX:+"$IDX"}; }
trap cleanup EXIT

# loud <lines...> — the one wording every at-risk exit uses, so a caller/log-grepper cannot miss it.
# bounded <secs> <cmd...> — a portable time bound (macOS has no `timeout`; verified). The rescue runs
# immediately BEFORE a kill, so an unbounded network call delays the kill that the cap exists to make.
BOUNDED_TIMEOUT=0
bounded() {
  local secs="$1"; shift
  BOUNDED_TIMEOUT=0
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"; return $?; fi
  "$@" & local p=$!
  # ⛔ POLL, DO NOT FORK A WATCHDOG. `( sleep N; kill … ) &` leaves an orphaned `sleep` behind on every
  # call because killing the subshell does not kill its child — measured: two rescues added four
  # orphaned timers, in a script that exists to run in the second before a cap kill.
  local waited=0
  while kill -0 "$p" 2>/dev/null && [ "$waited" -lt "$secs" ]; do sleep 1; waited=$((waited+1)); done
  if kill -0 "$p" 2>/dev/null; then
    BOUNDED_TIMEOUT=1
    kill -TERM "$p" 2>/dev/null
  fi
  wait "$p"; local rc=$?
  return "$rc"
}

loud() {
  echo "bg-rescue-wip: ⛔ $1" >&2
  shift
  for l in "$@"; do echo "bg-rescue-wip:    $l" >&2; done
}

# ── 1. The path must be the ROOT of a worktree ───────────────────────────────────────────────────
# `rev-parse --git-dir` succeeds anywhere INSIDE a repo, so a misrouted path would archive the
# enclosing checkout and exit 0 claiming a rescue of work it never looked at.
# ⛔ IN VERDICT MODE THERE IS NO `dirty` HERE, ONLY `UNMEASURED`. A path this tool cannot resolve is
# not a worktree with work in it; reporting it as `dirty` would send a caller to archive nothing and
# reporting it as `clean` is the data-loss answer this file exists to prevent. Exit 2 = cannot verify.
# The ORDINARY mode keeps its documented exit 1 for the same three cases — this helper must not move a
# shipped exit code, so the two modes answer with their own vocabulary.
vunmeasured() { echo "bg-rescue-wip: $*" >&2; [ "$VERDICT_ONLY" -eq 1 ] && { echo 'verdict=cannot-verify'; exit 2; }; exit 1; }

TOP="$(git -C "$WT" rev-parse --show-toplevel 2>/dev/null)" || vunmeasured "not a worktree: $WT"
# ⛔ ONE BRANCH, NOT TWO (#3588 review, cycle 8). The old `not a directory` arm was UNREACHABLE: every
# path that cannot be entered already fails `git -C … rev-parse --show-toplevel` above — a FILE, a missing
# path and a permission-denied dir all die there (verified with /etc/hostname) — so that arm could never
# fire and the mutation pass found no arm that could redden it, i.e. it was dead weight in exactly the way
# an unassertable guard always is. The reachable successor of the same condition is KEPT (and is now
# graded by V10), so a path we cannot enter still answers UNMEASURED rather than `dirty`.
HERE_R="$(cd "$WT" 2>/dev/null && pwd -P)" || vunmeasured "not a worktree root: $WT (that path cannot be entered)"
TOP_R="$(cd "$TOP" 2>/dev/null && pwd -P)"
if [ "$HERE_R" != "$TOP_R" ]; then
  vunmeasured "not a worktree root: $WT (that path is inside the worktree at $TOP)"
fi

# ── 2. Is anything at risk? A FAILED status is not a clean tree ──────────────────────────────────
# ⛔ `[ -z "$(git status ... 2>/dev/null)" ]` reads a status FAILURE (corrupt index, unreadable dir, a
# bare repo) as empty output — i.e. as "clean" — and exits 0 on unrescued work. That is the one
# outcome this script exists to prevent, so a failure is treated as AT RISK and the archive proceeds.
# `-uall` is passed so a `status.showUntrackedFiles=no` preference (which may be set GLOBALLY) cannot
# hide the untracked files that are this fleet's modal case.
# stdout and stderr are captured SEPARATELY: the decision is the exit code, never "did any text appear".
# Conflating them was a measured defect in both directions — a failing status that prints nothing was
# called clean, and a clean tree whose status merely WARNED (permission denied on one directory) was
# called dirty and pushed a ref for a tree with no changes.
# ⛔ A status that SUCCEEDS while warning that it could not read a directory has NOT enumerated the
# worktree, so "empty output" does not mean "clean". Splitting the streams (to stop a mere warning
# dirtying a clean tree) removed the only signal that the listing was incomplete, and a lane that
# chmod'ed a directory — or extracted a tree as another user — then got "nothing at risk", exit 0,
# with its only copy still on disk. The specific incomplete-enumeration warnings are AT RISK; an
# unrelated warning is not.
INCOMPLETE_RE='could not open directory|unable to index file|Permission denied|could not read'
: > "$ERRF"
ST_OUT="$(GIT_OPTIONAL_LOCKS=0 git -C "$WT" status --porcelain -uall 2>"$ERRF")"; ST_RC=$?
ENUM_INCOMPLETE=0
grep -qE "$INCOMPLETE_RE" "$ERRF" 2>/dev/null && ENUM_INCOMPLETE=1

AT_RISK=1
if [ "$ST_RC" -ne 0 ]; then
  echo "bg-rescue-wip: ⚠ could not enumerate $WT (git status exit $ST_RC) — treating the work as AT RISK, not as clean:" >&2
  head -3 "$ERRF" 2>/dev/null | sed 's/^/bg-rescue-wip:    /' >&2
elif [ "$ENUM_INCOMPLETE" -eq 1 ]; then
  echo "bg-rescue-wip: ⚠ the worktree listing is INCOMPLETE — git could not read part of $WT, so an" >&2
  echo "bg-rescue-wip:   empty listing does NOT mean clean. Treating the work as AT RISK:" >&2
  head -3 "$ERRF" 2>/dev/null | sed 's/^/bg-rescue-wip:    /' >&2
elif [ -z "$ST_OUT" ]; then
  AT_RISK=0
fi

HEAD_OK=0
git -C "$WT" rev-parse -q --verify HEAD >/dev/null 2>&1 && HEAD_OK=1

BR="$(git -C "$WT" branch --show-current 2>/dev/null)"
[ -z "$BR" ] && BR="detached-$(git -C "$WT" rev-parse --short HEAD 2>/dev/null || echo unborn)"

wip_ref_parts "$BR"   # sets WIP_ISSUE and SLUG — ONE derivation, shared with the reader

# ── 2b. VERDICT MODE (--verdict): the fact, not the archive ───────────────────────────────────────
# ⛔ WHY THE SWEEP CALLS THIS INSTEAD OF READING `git status` ITSELF (agent-infra#3485). The three
# verdicts below are the whole safety argument of this file: an EMPTY listing is only `clean` when the
# status SUCCEEDED and enumerated everything, and a warning that a directory could not be read is
# `cannot-verify`. A sweeper that re-derived that rule from its own `git status` would be a second
# implementation of it — and the day one of them drifts, the sweeper silently archives nothing and
# reports a clean fleet. So there is exactly one classifier and this is its read-only mode.
# ONE LINE, machine-readable, with the classifier's OWN branch, slug AND ISSUE so a caller never
# re-derives any of them (`SLUG` is the ref component this file actually pushes under, §6, and
# `WIP_ISSUE` is what `wip_ref_parts` read out of the branch — the SAME derivation the ref name came
# from, so the index can never assert a link the ref does not carry). `issue=-` when the branch carries
# none: the caller reports that, and must not invent a number of its own.
#
# `paths=` is deliberately ABSENT on `cannot-verify`: an unenumerated tree has NO path count, and
# printing 0 there is the exact "empty = clean" confusion this mode exists to remove.
if [ "$VERDICT_ONLY" -eq 1 ]; then
  if [ "$AT_RISK" -eq 0 ]; then
    echo "verdict=clean paths=0 branch=$BR slug=$SLUG issue=${WIP_ISSUE:--}"
    exit 0
  fi
  if [ "$ST_RC" -ne 0 ] || [ "$ENUM_INCOMPLETE" -eq 1 ]; then
    echo "verdict=cannot-verify branch=$BR slug=$SLUG issue=${WIP_ISSUE:--}"
    exit 2
  fi
  N_VERDICT_PATHS="$(printf '%s\n' "$ST_OUT" | grep -c '' 2>/dev/null || true)"
  echo "verdict=dirty paths=${N_VERDICT_PATHS:-?} branch=$BR slug=$SLUG issue=${WIP_ISSUE:--}"
  exit 1
fi

if [ "$AT_RISK" -eq 0 ]; then
  # Honest about what is NOT covered: a lane that committed locally but never pushed has a clean tree
  # and unpushed work. Say that instead of a bare "nothing at risk".
  UNPUSHED=0
  if [ "$HEAD_OK" -eq 1 ]; then
    UNPUSHED="$(git -C "$WT" rev-list --count "HEAD" --not --remotes 2>/dev/null || echo 0)"
  fi
  if [ "${UNPUSHED:-0}" -gt 0 ] 2>/dev/null; then
    echo "bg-rescue-wip: clean — no UNCOMMITTED work in $WT" 
    echo "bg-rescue-wip: ⚠ $UNPUSHED commit(s) exist only locally and are NOT archived by this tool" >&2
    exit 0
  fi
  echo "bg-rescue-wip: clean — nothing at risk in $WT"
  exit 0
fi

# ── 3. Build the tree in a throwaway index ───────────────────────────────────────────────────────
IDX="$(mktemp "$TMPD/bg-rescue-idx.XXXXXX")" || {
  loud "cannot create a throwaway index in ${TMPDIR:-/tmp} — the work is STILL ONLY ON THIS DISK." \
       "$WT was NOT archived. Free space / fix TMPDIR and retry."
  exit 2
}

if [ "$HEAD_OK" -eq 1 ]; then
  GIT_INDEX_FILE="$IDX" git -C "$WT" read-tree HEAD 2>/dev/null || {
    loud "cannot read the HEAD tree of $WT — the work is STILL ONLY ON THIS DISK." "Nothing was archived."; exit 2; }
else
  # ⛔ An UNBORN HEAD is not an error: a lane that has not committed yet is exactly the population
  # #2045 was filed for ("4 of 6 lanes ... committed NOTHING"). Archive against an empty tree.
  GIT_INDEX_FILE="$IDX" git -C "$WT" read-tree --empty 2>/dev/null || {
    loud "cannot start a new index in $WT — the work is STILL ONLY ON THIS DISK."; exit 2; }
fi

SKIPPED=()
: > "$ERRF"
if ! GIT_INDEX_FILE="$IDX" git -C "$WT" add -A 2>"$ERRF" ; then
  # ⛔ ONE nested repository with an unborn HEAD ("git init" in a scratch dir, an interrupted clone, a
  # worktree inside the tree) makes `git add -A` fail WHOLESALE — aborting the rescue of every other
  # file too. Fall back to the tracked changes plus untracked paths added one at a time, and NAME
  # whatever could not be staged. A partial rescue that says what it missed beats no rescue at all.
  ERR="$(cat "$ERRF" 2>/dev/null)"
  echo "bg-rescue-wip: ⚠ whole-tree staging failed, archiving per path instead" >&2
  [ -n "$ERR" ] && echo "$ERR" | head -3 | sed 's/^/bg-rescue-wip:    /' >&2
  GIT_INDEX_FILE="$IDX" git -C "$WT" add -u 2>/dev/null
  while IFS= read -r -d '' p; do
    GIT_INDEX_FILE="$IDX" git -C "$WT" add -A -- "$p" 2>/dev/null || SKIPPED+=("$p")
  done < <(GIT_OPTIONAL_LOCKS=0 git -C "$WT" ls-files -o --exclude-standard -z 2>/dev/null)
else
  # The bulk stage SUCCEEDED — but git may still have skipped a path it could not read, and it says so
  # only on stderr. Without this the archive is PARTIAL while the run exits 0 announcing a rescue.
  while IFS= read -r missed; do
    [ -n "$missed" ] && SKIPPED+=("$missed")
  done <<EOF2
$(sed -n "s/.*could not open directory '\([^']*\)'.*/\1/p" "$ERRF" 2>/dev/null | sort -u)
EOF2
fi

if [ "${#SKIPPED[@]}" -gt 0 ]; then
  loud "these paths could NOT be archived (nested repository without a commit, or unreadable):" \
       ${SKIPPED[@]+"${SKIPPED[@]}"} \
       "They are STILL ONLY ON THIS DISK. The rest of the worktree WAS archived."
fi

TREE="$(GIT_INDEX_FILE="$IDX" git -C "$WT" write-tree 2>/dev/null)"; TREE_RC=$?
if [ "$TREE_RC" -ne 0 ] || [ -z "$TREE" ]; then
  loud "cannot write a tree for $WT — the work is STILL ONLY ON THIS DISK." "Nothing was archived."; exit 2
fi

# ── 4. Commit, parented so the archive ACCUMULATES ───────────────────────────────────────────────
# The parents are HEAD *and* the previous archive commit. Without the second parent every rescue is a
# SIBLING of the last one (HEAD never moves), so the second push is a non-fast-forward and is
# REJECTED — which would silently strand everything the lane wrote during the grace period, and would
# strand a whole lane whose branch name a previous lane already used.
PREV="$(git -C "$WT" rev-parse -q --verify "refs/wip-local/$SLUG" 2>/dev/null)"
MSG="wip: $NOTE — uncommitted state of $BR archived by bg-rescue-wip.sh at $(date -u '+%Y-%m-%dT%H:%M:%SZ') from $HERE_R, not for merge"
PARENTS=()
[ "$HEAD_OK" -eq 1 ] && PARENTS+=(-p HEAD)
if [ -n "$PREV" ]; then
  PARENTS+=(-p "$PREV")
else
  echo "bg-rescue-wip: (first rescue for $SLUG in this repo — no previous snapshot to chain)" >&2
fi

# ⛔ bash 3.2 (macOS /bin/bash) treats an EMPTY array as unbound under `set -u`, and an unborn HEAD has
# no parents at all — `${PARENTS[@]+...}` expands to nothing there instead of aborting the rescue.
C="$(git -C "$WT" commit-tree "$TREE" ${PARENTS[@]+"${PARENTS[@]}"} -m "$MSG" 2>/dev/null)"
if [ -z "$C" ]; then
  loud "commit-tree failed for $WT — the work is STILL ONLY ON THIS DISK." "Nothing was archived."; exit 2
fi
if [ "$ST_RC" -ne 0 ]; then
  N_PATHS="unknown (status failed)"
else
  N_PATHS="$(printf '%s\n' "$ST_OUT" | grep -c '' 2>/dev/null || true)"
fi
echo "bg-rescue-wip: archived $BR at $C ($N_PATHS changed/untracked path(s))" >&2

# ── 5. A local ref too, so the work is reachable even if the push is refused ─────────────────────
# Guarded: an unchecked update-ref let the failure message name a ref that was never created (a D/F
# conflict, a stale .lock, ENOSPC), i.e. a durability claim that was false.
LOCAL_OK=0
if git -C "$WT" update-ref "refs/wip-local/$SLUG" "$C" 2>/dev/null \
   && [ "$(git -C "$WT" rev-parse -q --verify "refs/wip-local/$SLUG" 2>/dev/null)" = "$C" ]; then
  LOCAL_OK=1
else
  echo "bg-rescue-wip: ⚠ could not record refs/wip-local/$SLUG" >&2
fi

# ── 6. Push ─────────────────────────────────────────────────────────────────────────────────────
# ⛔ NO FORCE, and the reason is the one case the local chain cannot cover. `refs/wip/<slug>` is keyed
# by branch name only, so a rescue from a DIFFERENT clone — another machine, another lane on a reused
# branch — has no local `refs/wip-local/<slug>` to chain on. A forced push there would REPLACE the
# other clone's snapshot, and a bare remote keeps no reflog, so the overwritten commit is discarded at
# the next gc. That is the single-disk condition #2045 exists to remove, reintroduced by the fix.
# So: fetch the remote's snapshot first and chain onto IT, which makes the push a fast-forward and
# keeps both. If the fetch finds nothing, there is genuinely nothing to overwrite.
FETCHED="refs/wip-remote/$SLUG"
bounded 25 git -C "$WT" fetch -q --no-tags origin "+refs/wip/$SLUG:$FETCHED" 2>/dev/null
REMOTE_TIP="$(git -C "$WT" rev-parse -q --verify "$FETCHED" 2>/dev/null)"
# ⛔ THE GATE IS "is the remote tip already an ancestor of my candidate?", NOT "do I have a local ref?".
# Gating on `-z "$PREV"` fired only on a clone's FIRST rescue: once a peer pushed the same slug, every
# later rescue from a clone that DID have a local ref omitted the remote parent, so the push was a
# permanent non-fast-forward — retries included — and the grace-period work never left the disk.
if [ -n "$REMOTE_TIP" ] && ! git -C "$WT" merge-base --is-ancestor "$REMOTE_TIP" "$C" 2>/dev/null; then
  echo "bg-rescue-wip: chaining onto origin's snapshot $REMOTE_TIP (not an ancestor of this archive)" >&2
  PARENTS+=(-p "$REMOTE_TIP")
  C2="$(git -C "$WT" commit-tree "$TREE" ${PARENTS[@]+"${PARENTS[@]}"} -m "$MSG" 2>/dev/null)"
  if [ -z "$C2" ]; then
    # ⛔ Not "nothing was archived": the FIRST commit exists and refs/wip-local already points at it.
    loud "could not chain the archive onto origin's snapshot — the work is STILL ONLY ON THIS DISK." \
         "$BR → ${LOCAL_OK:+refs/wip-local/$SLUG = }$C (kept locally; the remote copy could not be updated)" \
         "retry: bash '$HERE_R/$(basename "$0")' '$WT' 'rescue retry'"
    exit 2
  fi
  C="$C2"
  if git -C "$WT" update-ref "refs/wip-local/$SLUG" "$C" 2>/dev/null; then LOCAL_OK=1; fi
  echo "bg-rescue-wip: archived $BR at $C ($N_PATHS changed/untracked path(s))" >&2
fi

# ⛔ THE CREDENTIAL THAT CAN PUSH, AND THE PREDICATE THAT TELLS ONE REFUSAL FROM ANOTHER (agent-infra#2292).
# A fine-grained PAT without `Workflows: write` is refused by github.com for ANY snapshot that touches
# `.github/workflows/` — and the rescue then reported "push failed" and exited 2, i.e. the tool that
# exists to survive a killed lane degraded to local-only for exactly the lanes whose work touches CI.
# A second credential that carries `workflow` in its scopes publishes the same ref on ONE retry. Three
# properties this must keep:
#   - the retry is gated on the REFUSAL, not on "the push failed": a network outage, an auth failure, a
#     non-fast-forward or a hook rejection is NOT retried, because a blanket retry can turn a
#     diagnosable failure into a green run and hide the cause;
#   - it is never a force and never a config write: `-c credential.helper=` clears the configured
#     helpers for THIS invocation only, so the repo's credential config is untouched;
#   - it cannot block the kill: GIT_TERMINAL_PROMPT=0 means a keychain entry that is missing FAILS
#     instead of prompting on a terminal nobody is watching.
# ⛔ THE MATCHER IS DELIBERATELY NARROW. `grep workflow` would match this script's own refspec echoed
# back in a rejection (`! [remote rejected] … refs/wip/fix-workflow-scope`), so a branch merely NAMED
# "workflow" would take the retry path on an ordinary rejection. Only GitHub's scope refusal matches.
WORKFLOW_SCOPE_RE='refusing to allow .*(create|update) workflow|without .?workflow.? scope'
is_workflow_scope() { grep -qiE "$WORKFLOW_SCOPE_RE" "$1" 2>/dev/null; }

# push_plain / push_with_helper / push_unshadowed — the SAME refspec, the same bounds, the same
# no-force. The only difference is WHICH CREDENTIAL is consulted, so a retry can never publish
# something the first push would not.
push_plain() {
  bounded 45 git -C "$WT" -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=20 \
    push -q origin "$C:refs/wip/$SLUG" 2>"$ERRF"
}
push_with_helper() {  # push_with_helper <helper-name> — clear the configured helpers, then name ONE
  bounded 45 git -C "$WT" -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=20 \
    -c credential.helper= -c credential.helper="$1" \
    push -q origin "$C:refs/wip/$SLUG" 2>"$ERRF"
}
# ⛔ THE STORED CREDENTIAL, WITH THE AMBIENT TOKEN OUT OF ITS WAY — the ONE retry that needs no new store
# and works on every host. An ambient `GH_TOKEN`/`GITHUB_TOKEN` is consulted by git's configured helper
# chain (gh's helper reads it FIRST, ahead of its own store), so a read-only or scope-less ambient token
# SILENTLY wins over a stored credential that can push — measured on this fleet twice (#3483's shadowed
# env var voiding a review, #3453's dispatcher resolving a read-only PAT) — and nothing in the push
# output says which of the two was used. Removing those two variables for THIS INVOCATION ONLY lets the
# configured helper answer from its store; it is not a config write, it is never a force, and it cannot
# PUBLISH anything the first push would not (same repo, same refspec, same sha) — what it reaches is a
# credential the first push never CONSULTED, which is the point. ⛔ THE PREDICATE IS "an ambient token is
# SET", NOT "the configured helper READS it" (review round 3, P2). On a host whose helper is `store` or
# `cache` — a common setup where `GH_TOKEN` is exported for the `gh` CLI rather than for git — the retry
# removes a variable that helper never read, so it re-sends the SAME credential the remote just
# refused. Detecting "does this helper consult the environment" is not something this script can know
# cheaply, so the predicate stays what it is and the DECLARED RESIDUAL is that shape; the messages below
# are worded for it ("if the configured helper reads them") rather than claiming a shadow that may not
# exist — a false mechanism claim is worse than an imprecise one.
push_unshadowed() {
  bounded 45 env -u GH_TOKEN -u GITHUB_TOKEN \
    git -C "$WT" -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=20 \
    push -q origin "$C:refs/wip/$SLUG" 2>"$ERRF"
}

# ⛔ WHICH CREDENTIAL THE RETRY USES IS A PER-HOST FACT, NOT A CONSTANT (agent-infra#2292, follow-up).
# The retry above is right and load-bearing; the CREDENTIAL it named was not. It hard-coded
# `osxkeychain`, which exists only on macOS — so on a Linux cell (every cell in this fleet, and the
# hosts a lane is most likely to be reaped on) that attempt could never succeed, and because
# `-c credential.helper=` had already cleared the configured helper, the one path to an off-box
# credential the box HAS was structurally closed. The candidates, first one that can be a DIFFERENT
# credential from the one just refused wins:
#   1. `BG_RESCUE_PUSH_HELPER=<name>` — the operator's explicit choice, for a store this script cannot
#      guess (trusted exactly as the caller is: it reaches the shell git would run anyway);
#   2. `BG_RESCUE_PUSH_UNSHADOW=1` — an explicit request for the STORED credential below, which is the
#      only way to reach that candidate on macOS (where the platform default is unconditional). ⛔ IT
#      REQUIRES AN AMBIENT TOKEN TO REMOVE: with none set the retry would be BYTE-IDENTICAL to the one
#      that was just refused, so none is attempted (a reviewer measured exactly that — two identical
#      argv lines, a message claiming a removal that never happened, 45 s spent in the second before a
#      kill). A seam cannot buy a different credential out of nothing;
#   3. `osxkeychain` on Darwin — the proven macOS credential, unchanged behaviour there;
#   4. `unshadow` elsewhere, when an ambient token is actually set to remove;
#   5. nothing — and then NO retry is attempted. A second attempt carrying the same credential cannot
#      succeed, and in the second before a kill it costs 45 s to learn what the first attempt already
#      said; the run reports "no second credential" instead, which is a different operator action from
#      "the retry also failed" (that is what the `unclassified`/`NO USABLE CREDENTIAL HELPER` causes are
#      for, and the message names the seam above rather than leaving the operator to guess).
# ⛔ DECLARED RESIDUAL: on macOS the DEFAULT is `osxkeychain`, so a Mac whose configured helper is gh's
# (ambient token shadowing a keychain-stored one) does not reach the unshadow candidate unless the
# operator asks for it (`BG_RESCUE_PUSH_UNSHADOW=1`). That is deliberate — the keychain path is the one
# measured there, and reordering a PROVEN macOS behaviour to cover a shape this fleet has not measured
# on that platform is a worse trade — and it is reachable, which the previous text got wrong.
RETRY_HELPER="${BG_RESCUE_PUSH_HELPER:-}"
RETRY_UNSHADOW="${BG_RESCUE_PUSH_UNSHADOW:-0}"
retry_credential() {  # echoes "helper <name>" | "unshadow" | "" (nothing that can differ)
  if [ -n "$RETRY_HELPER" ]; then printf 'helper %s' "$RETRY_HELPER"; return 0; fi
  # ⛔ THE SEAM IS CONDITIONAL ON A SHADOW EXISTING (review round 2, P2): asking to remove an ambient
  # token that is not set selects the credential the first push already used — it cannot succeed, and
  # the message would then be LYING about a removal that never happened. Same predicate as the platform
  # default below: one rule, `unshadow` only when there is something to unshadow.
  if [ "$RETRY_UNSHADOW" = "1" ] && [ -n "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]; then printf 'unshadow'; return 0; fi
  if [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then printf 'helper osxkeychain'; return 0; fi
  if [ -n "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]; then printf 'unshadow'; return 0; fi
  printf ''
}

# classify_push_failure <stderr-file> — ONE line naming WHY, because "the push failed" sent a diagnosis
# cycle after the wrong cause (#2292): the workflow refusal and an expired credential print nothing alike
# but both read as "push failed". Order matters — a scope refusal ALSO says "[remote rejected]".
classify_push_failure() {
  local f="$1"
  if is_workflow_scope "$f"; then
    echo "cause: WORKFLOW SCOPE — this credential may not create or update a .github/workflows file."
  elif grep -qiE 'is not a git command|helper .*(not found|does not exist)' "$f" 2>/dev/null; then
    echo "cause: NO USABLE CREDENTIAL HELPER — the helper named for the retry is not installed on this host."
  elif grep -qiE 'authentication failed|could not read (username|password)|terminal prompts disabled|invalid username or password|\b40[13]\b|permission denied' "$f" 2>/dev/null; then
    echo "cause: AUTHENTICATION — the credential was rejected or absent (the remote was reachable)."
  elif grep -qiE 'could not resolve host|connection (refused|timed out)|unable to access|network is unreachable|operation timed out|failed to connect|low-speed' "$f" 2>/dev/null; then
    echo "cause: NETWORK — the remote could not be reached; no credential was consulted."
  elif grep -qiE 'non-fast-forward|fetch first|\[rejected\]|pre-receive hook declined|protected branch' "$f" 2>/dev/null; then
    echo "cause: REMOTE REJECTED THE UPDATE — the ref did not fast-forward or a server policy refused it."
  else
    echo "cause: UNCLASSIFIED — the push output below is the only evidence."
  fi
}

RETRIED=0; PUSHED=0; FIRST_CAUSE=""; PUSH_TIMEOUTS=""; RETRY_GOT=""; NO_SECOND=0
if push_plain; then
  PUSHED=1
else
  [ "$BOUNDED_TIMEOUT" -eq 1 ] && PUSH_TIMEOUTS="the first push HIT ITS TIME BOUND and was cut off (the remote is stalled, not refusing)"
  FIRST_CAUSE="$(classify_push_failure "$ERRF")"
  if is_workflow_scope "$ERRF"; then
    RETRY_PLAN="$(retry_credential)"
    case "$RETRY_PLAN" in
      'helper '*)
        RETRIED=1; RETRY_GOT="the ${RETRY_PLAN#helper } credential"
        # ⛔ NO PROMPT: this runs in the second before a kill, so an absent store entry must FAIL rather
        # than wait on a terminal nobody is watching. Exported once here — every later git call in this
        # script is non-interactive too, so there is nothing to restore.
        GIT_TERMINAL_PROMPT=0; export GIT_TERMINAL_PROMPT
        echo "bg-rescue-wip: the push was refused for WORKFLOW SCOPE — retrying ONCE with the ${RETRY_PLAN#helper } credential (no force, no config written)" >&2
        if push_with_helper "${RETRY_PLAN#helper }"; then
          PUSHED=1
        else
          [ "$BOUNDED_TIMEOUT" -eq 1 ] && PUSH_TIMEOUTS="the ${RETRY_PLAN#helper } retry HIT ITS TIME BOUND and was cut off (the remote is stalled, not refusing)"
        fi
        ;;
      'unshadow')
        RETRIED=1; RETRY_GOT="the STORED credential (the ambient GH_TOKEN/GITHUB_TOKEN was removed for that attempt)"
        GIT_TERMINAL_PROMPT=0; export GIT_TERMINAL_PROMPT
        echo "bg-rescue-wip: the push was refused for WORKFLOW SCOPE — retrying ONCE with the STORED credential (GH_TOKEN/GITHUB_TOKEN removed from THIS attempt only, so if the configured helper reads them the stored credential can answer; no force, no config written)" >&2
        if push_unshadowed; then
          PUSHED=1
        else
          [ "$BOUNDED_TIMEOUT" -eq 1 ] && PUSH_TIMEOUTS="the stored-credential retry HIT ITS TIME BOUND and was cut off (the remote is stalled, not refusing)"
        fi
        ;;
      *)
        # ⛔ NO SECOND CREDENTIAL: attempting anyway would re-send the credential the remote just
        # refused, which cannot succeed. The refusal is still reported in full below (cause + the
        # remote's own first lines); what changes is that the operator is told the fleet has nothing
        # else to try HERE, and how to supply something (#2292's remaining availability gap is this
        # case, and it is an owner decision — accept the loud local-only outcome, or an off-box channel
        # that keeps the snapshot whole. Do not narrow the snapshot instead: the whole-tree commit is
        # what this tool guarantees.)
        # ⛔ AND THE ADVICE NAMES ONLY THE HELPER SEAM (review round 2, P2). `BG_RESCUE_PUSH_UNSHADOW=1`
        # cannot help on the shape that reaches this line — it is reached precisely when there is NO
        # ambient token to unshadow, and the seam is conditional on one existing — so recommending it
        # would send the operator after a guaranteed-useless 45 s retry, the outcome this gate avoids.
        NO_SECOND=1
        ;;
    esac
  fi
fi

if [ "$PUSHED" -eq 1 ]; then
  if [ "$RETRIED" -eq 1 ]; then
    echo "bg-rescue-wip: rescued $BR → origin refs/wip/$SLUG ($C) — pushed with $RETRY_GOT after the configured one was refused for workflow scope"
  else
    echo "bg-rescue-wip: rescued $BR → origin refs/wip/$SLUG ($C)"
  fi
  # ── 7. REPORT AN UNLINKED REF, EVERY TIME IT IS CREATED (agent-infra#3484) ─────────────────────
  # A rescue nobody can find is a rescue that happens twice. This is a REPORT, not a failure: the work
  # is safely on origin either way, so it does not change the exit code — but it says the one thing the
  # next actor cannot get anywhere else, which is that THIS ref has no issue to be mapped to.
  if [ -z "$WIP_ISSUE" ]; then
    echo "bg-rescue-wip: ⚠ refs/wip/$SLUG CARRIES NO ISSUE LINK — branch '$BR' does not follow <type>/<N>-<slug>, so nothing can map this rescue to an issue. Record it by hand (an issue comment naming refs/wip/$SLUG) or rename the branch and re-rescue (#3484)." >&2
  fi
  # A partial archive is a rescue, not a clean one: the skipped paths are still only on this disk.
  if [ "${#SKIPPED[@]}" -gt 0 ]; then
    loud "the rescue above is PARTIAL — these paths are STILL ONLY ON THIS DISK:" ${SKIPPED[@]+"${SKIPPED[@]}"} \
         "Retrieve them before this worktree is reaped."
    exit 2
  fi
  exit 0
fi
PUSH_ERR="$(cat "$ERRF" 2>/dev/null)"
[ -n "$PUSH_TIMEOUTS" ] && loud "$PUSH_TIMEOUTS." "The work is still only on this disk."

# ⛔ THE CAUSE IS PART OF THE MESSAGE (#2292, item 2). "the push failed" is the string that sent a
# diagnosis cycle after the wrong cause; the operator needs to know whether to fix a credential, a
# network path, or a ref. The FIRST attempt's cause is the primary one — a retry that fails for a
# DIFFERENT reason (a missing keychain entry after a scope refusal) is reported separately, never
# allowed to overwrite why the work could not leave in the first place.
WHY=("$FIRST_CAUSE")
if [ "$RETRIED" -eq 1 ]; then
  WHY+=("retried ONCE with $RETRY_GOT — it ALSO failed: $(classify_push_failure "$ERRF")")
fi
if [ "$NO_SECOND" -eq 1 ]; then
  # ⛔ "THE PUSH FAILED" AND "THIS HOST HAS NOTHING ELSE TO TRY" ARE DIFFERENT OPERATOR ACTIONS
  # (agent-infra#2292). Without this line the run looks like a credential that was rejected; with it,
  # the reader knows the rescue had no second credential to select on $(uname -s 2>/dev/null) and that
  # the fix is to supply one. The retry was deliberately NOT attempted — re-sending the same credential
  # cannot succeed, and it is the one attempt that would turn a named cause into a timeout.
  WHY+=("no second credential was tried: on $(uname -s 2>/dev/null), the retry would have re-sent the SAME credential (no ambient GH_TOKEN/GITHUB_TOKEN to unshadow, and no osxkeychain). Supply a workflow-scoped one with BG_RESCUE_PUSH_HELPER=<helper-name>.")
fi

if [ "$LOCAL_OK" -eq 1 ]; then
  loud "RESCUED LOCALLY BUT THE PUSH FAILED — this work is STILL ONLY ON THIS DISK." \
       "$BR → refs/wip-local/$SLUG ($C)" \
       ${WHY[@]+"${WHY[@]}"} \
       "retry: bash '$HERE_R/$(basename "$0")' '$WT' 'rescue retry'  (re-fetches and chains)"
else
  loud "THE PUSH FAILED AND THE LOCAL REF COULD NOT BE WRITTEN — this work is STILL ONLY ON THIS DISK." \
       "$BR → commit $C (unreferenced: run 'git -C $WT update-ref refs/wip-local/$SLUG $C' NOW)" \
       ${WHY[@]+"${WHY[@]}"} \
       "retry: bash '$HERE_R/$(basename "$0")' '$WT' 'rescue retry'  (re-fetches and chains)"
fi
[ -n "$PUSH_ERR" ] && head -5 "$ERRF" 2>/dev/null | sed 's/^/bg-rescue-wip:    /' >&2
exit 2
