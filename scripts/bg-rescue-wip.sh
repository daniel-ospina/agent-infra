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
# as a commit reachable from `refs/wip/<branch-slug>` on `origin`. It does NOT commit to the branch,
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
#     (the configured token often lacks `Workflows: write` while the keychain credential has it,
#     #2292). The predicate is the refusal TEXT, not the remote host or the snapshot's paths: any host
#     whose pre-receive output matches that wording takes the retry, and a host that words it
#     differently does not. Every other refusal is reported as-is — see section 6.
#
# Exit: 0 = nothing at risk, or rescued and pushed (prints the ref + sha)
#       1 = the path is not the root of a git worktree
#       2 = there was work that could NOT be archived or pushed — printed loudly, it is still at risk,
#           and the printed cause says WHY (workflow scope / auth / network / rejected / unclassified)
set -uo pipefail

WT="${1:?usage: bg-rescue-wip.sh <worktree> [note]}"
NOTE="${2:-a lane hit its cap}"

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
TOP="$(git -C "$WT" rev-parse --show-toplevel 2>/dev/null)" || { echo "bg-rescue-wip: not a worktree: $WT" >&2; exit 1; }
HERE_R="$(cd "$WT" 2>/dev/null && pwd -P)" || { echo "bg-rescue-wip: not a directory: $WT" >&2; exit 1; }
TOP_R="$(cd "$TOP" 2>/dev/null && pwd -P)"
if [ "$HERE_R" != "$TOP_R" ]; then
  echo "bg-rescue-wip: not a worktree root: $WT (that path is inside the worktree at $TOP)" >&2
  exit 1
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
SLUG="$(printf '%s' "$BR" | tr '/' '-')"

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
# The osxkeychain credential carries `workflow` in its scopes, so ONE retry with that helper selected
# publishes the same ref. Three properties this must keep:
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

# push_plain / push_keychain — the SAME refspec, the same bounds, the same no-force. The only difference
# is which credential is consulted, so a retry can never publish something the first push would not.
push_plain() {
  bounded 45 git -C "$WT" -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=20 \
    push -q origin "$C:refs/wip/$SLUG" 2>"$ERRF"
}
push_keychain() {
  bounded 45 git -C "$WT" -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=20 \
    -c credential.helper= -c credential.helper=osxkeychain \
    push -q origin "$C:refs/wip/$SLUG" 2>"$ERRF"
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

RETRIED=0; PUSHED=0; FIRST_CAUSE=""; PUSH_TIMEOUTS=""
if push_plain; then
  PUSHED=1
else
  [ "$BOUNDED_TIMEOUT" -eq 1 ] && PUSH_TIMEOUTS="the first push HIT ITS TIME BOUND and was cut off (the remote is stalled, not refusing)"
  FIRST_CAUSE="$(classify_push_failure "$ERRF")"
  if is_workflow_scope "$ERRF"; then
    RETRIED=1
    # ⛔ NO PROMPT: this runs in the second before a kill, so an absent keychain entry must FAIL rather
    # than wait on a terminal nobody is watching. Exported once here — every later git call in this
    # script is non-interactive too, so there is nothing to restore.
    GIT_TERMINAL_PROMPT=0; export GIT_TERMINAL_PROMPT
    echo "bg-rescue-wip: the push was refused for WORKFLOW SCOPE — retrying ONCE with the osxkeychain credential (no force, no config written)" >&2
    if push_keychain; then
      PUSHED=1
    else
      [ "$BOUNDED_TIMEOUT" -eq 1 ] && PUSH_TIMEOUTS="the keychain retry HIT ITS TIME BOUND and was cut off (the remote is stalled, not refusing)"
    fi
  fi
fi

if [ "$PUSHED" -eq 1 ]; then
  if [ "$RETRIED" -eq 1 ]; then
    echo "bg-rescue-wip: rescued $BR → origin refs/wip/$SLUG ($C) — pushed with the OSXKEYCHAIN credential after the configured one was refused for workflow scope"
  else
    echo "bg-rescue-wip: rescued $BR → origin refs/wip/$SLUG ($C)"
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
  WHY+=("retried ONCE with the osxkeychain credential — it ALSO failed: $(classify_push_failure "$ERRF")")
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
