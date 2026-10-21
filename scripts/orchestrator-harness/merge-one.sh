#!/usr/bin/env bash
# merge-one.sh <repo-path> <owner/repo> <pr> <branch>
# merge-one.sh --argv <file>            (4 lines: repo, owner/repo, pr, branch)
# Full chain for ONE PR: fresh-context review -> evidence comment -> record-review -> wait green -> merge.
# This box holds the AI_REVIEW_GATE_KEY, so it owns the merge authority for its own PRs.
#
# ⛔ TERMINAL STATE (#1717). Every failure that leaves the signed marker absent — the record step
# cannot run, the reviewer posted no evidence comment, the record itself failed — writes
# `$O/state/parked-<PR>` (the head a human must look at) BEFORE exiting, instead of exiting
# silently. That file is what the controller's parked guard reads, so the loop stops instead of
# spawning another review; and this script refuses to re-review an already-parked head itself, so
# the chain-<N> and fix-one.sh paths (which never consult the controller) cannot re-pay either.
# A later push changes the head and re-arms the PR by construction.
set -u
# --argv exists because these values are attacker-influenced (a PR branch name may contain quotes,
# semicolons, $ and backticks) and the controller must launch us from a tmux `sh -c` string.
# Passing them through a file keeps every PR-derived value out of that string entirely.
if [ "${1:-}" = "--argv" ]; then
  ARGV="${2:-}"
  [ -f "$ARGV" ] || { echo "[merge] missing argv file: $ARGV" >&2; exit 1; }
  { read -r REPO; read -r OR; read -r PR; read -r BR; } < "$ARGV"
  rm -f "$ARGV"
else
  REPO="$1"; OR="$2"; PR="$3"; BR="$4"
fi
case "${PR:-}" in ''|*[!0-9]*) echo "[merge] refusing non-numeric PR: ${PR:-<empty>}" >&2; exit 1 ;; esac
# Guard-before-use for env tunables. Every OTHER limit in this file is validated before it is
# used; `REVIEW_TIMEOUT` was the lone exception and it fed ARITHMETIC (P1, 2026-10-14 adversarial
# review — see the coercion note at the claim block).
# ⛔ REJECT LEADING ZEROS (P2, second review round, 2026-10-14): the first fix used
# `''|*[!0-9]*`, which ACCEPTS `08` — so `CLAIM_LEASE=$(( 08 + 1200 ))` still reached the arithmetic.
# On /bin/bash 3.2.57 `$(( ))` parses base 0, where a leading 0 means OCTAL, and `08`/`09` are not
# octal; the failed assignment ABORTS the rest of the enclosing `if` body and resumes after `fi`
# with status 0, so claim_acquire never ran and the worker reported success. Accept only `0` or
# `[1-9][0-9]*`.
is_num() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; 0) return 0 ;; 0*) return 1 ;; *) return 0 ;; esac; }
# ⛔ MAGNITUDE, NOT JUST SHAPE (P2, third review round, 2026-10-14). `is_num` is UNBOUNDED, so it
# accepted `9223372036854775807`; `CLAIM_LEASE=$(( REVIEW_TIMEOUT + 1200 ))` then wrapped NEGATIVE,
# `claims.sh`'s `until=$(( now + ttl ))` was negative, `_lease_of`'s `[0-9]*` could not parse the minus
# sign, and an unparseable lease is read as LIVE — so that PR/head was frozen across ALL boxes with
# no automatic recovery (`claim_prune` can never reap it). FAIL-CLOSED, the opposite of the design's
# fail-open policy. `is_limit` (is_num AND at most 9 digits) is the predicate orch-loop.sh applies to
# every other tunable for exactly this reason, and 9 digits cannot overflow the sum below.
is_limit() { is_num "${1:-}" && [ "${#1}" -le 9 ]; }
KIND=reviewer; TAG="$PR"
O="${O:-$HOME/orchestrator}"; mkdir -p "$O/logs" "$O/state"
L="$O/logs/merge-$PR"
# The wall-clock limit AND the load gate both live in the shared helper, so this script has no
# `pi` invocation of its own to forget to gate (agent-infra#1720, tortoise 80db43882 #8521).
# ⛔ SOURCED AFTER THE PATH EXPORT — a deliberate agent-infra departure (D1). The tortoise original
# sources the helper BEFORE its PATH export, and spawn-gate.sh derives `_NCPU` at SOURCE time via
# sysctl/nproc/getconf — so sourcing it first pins _NCPU=4 / MAX_LOAD=40 on every cell (#1702).
# NB: `L` above is a LOG PATH, not a load reading — the gate takes its reading as an argument for
# exactly that reason. Fail LOUD if the helper is missing: an unsourced helper leaves `run_agent`
# undefined, and that must never degrade into a verdict (see README §9 on syncing $O).
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF/spawn-gate.sh" || { echo "[merge $PR] FATAL: $SELF/spawn-gate.sh missing — refusing to run an ungated reviewer" >&2; exit 78; }
# ⛔ THE MAIN-EDITS HATCH IS DELIBERATELY *NOT* EXPORTED HERE (#8484). It used to be: this script
# exported the hatch AND skipped VGATE, and then ran the reviewer with cwd = the shared checkout
# — i.e. it switched OFF the one control that would have refused a write there, and left
# "do not touch the main checkout" as a prompt written to a model with shell access. The reviewer
# now gets its own checkout (see review_sandbox below), so the hatch buys nothing and its absence
# is the SECOND layer: a reviewer that wanders back into the shared checkout is REFUSED by
# main-worktree-guard instead of obeyed. fix-one.sh keeps the hatch — a fixer writing to the tree
# IS its job.
export AGENT_SKIP_REVIEW_GATE=1 ELDATO_SKIP_VGATE=1
# ⛔ NOT EXPORTING IS NOT ENOUGH — the hatch is UNSET here, not merely omitted. An exported variable
# is inherited across `bash <script>`, and fix-one.sh exports the hatch and then runs THIS script as
# a child, so on the re-review that follows EVERY fixer run the reviewer started with the hatch OPEN
# and main-worktree-guard OBEYED it — the containment this script advertises was inert on its most
# common path (PR #8589 review). The property must belong to this script, not to a caller that
# happens to be clean.
unset AGENT_ALLOW_MAIN_EDITS ELDATO_ALLOW_MAIN_EDITS 2>/dev/null || true
export PI_MCP_SERVERS=none   # headless reviewer uses no MCP servers — saves ~25 processes/run
export PI_SKIP_VERSION_CHECK=1 SKILL_ENFORCER_DISABLED=1 LOOP_ENFORCER_DISABLED=1 SLACK_BRIDGE_DISABLE=1 VISION_INTERCEPTOR_DISABLED=1
cd "$REPO" || exit 1

# ── the per-repo merge contract (agent-infra#1764) ─────────────────────────────
# The SAME home orch-loop.sh uses, so the two cannot disagree about what this repo requires or
# which merge authority it has. REQ in the environment is an operator override; capture it ONCE
# (REQ is overwritten below with the resolved value).
_M1_HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
if [ -f "$O/repo-authority.sh" ]; then . "$O/repo-authority.sh"
elif [ -f "$_M1_HERE/repo-authority.sh" ]; then . "$_M1_HERE/repo-authority.sh"
else echo "[merge $PR] FATAL repo-authority.sh not found (looked in $O and ${_M1_HERE:-<unresolved>}) — refusing to run without the per-repo merge contract" >> "$L.log"; exit 1; fi
# ⚠️ review round 3: a PRESENT but stale/partial repo-authority.sh sources cleanly, yields
# REQ="" (read as `rail`), and the refusal below never fires — the resolver must actually exist.
command -v resolve_required_checks >/dev/null 2>&1 && command -v merge_authority >/dev/null 2>&1 \
  || { echo "[merge $PR] FATAL repo-authority.sh is stale (no resolve_required_checks/merge_authority) — refusing to run without the per-repo merge contract" >> "$L.log"; exit 1; }
REQ_OVERRIDE="${REQ:-}"
REQ=""

# The agent invocation (wall-clock bound + load gate + the #1709 wall-time telemetry) lives in
# `spawn-gate.sh`, sourced above — this script no longer carries its own `run_agent()`. It was the
# last of the three duplicate `pi` call sites (agent-infra#1720), and a private ungated copy here
# meant the reviewer launched onto whatever load existed when it got there — exactly the spike the
# gate exists to prevent. The #1709 telemetry is NOT lost by the move: the helper's run_agent() is
# agent-infra's canonical one (elapsed=, walltime.tsv) PLUS the gate, so this is a merge, not a copy.
#
# ── review_helpers: the reviewer's OWN checkout (#8484, tortoise 10563490a) ────
# #8484 measured what prompt-only containment costs: a fresh-context reviewer that mutated the tree
# it was reading, COMMITTED, merged origin/main and PUSHED — all unprompted — and absorbed the
# controller's unstaged edits on the way. Nothing in that flow asked for a ref move, and the only
# thing guarding it had been a sentence in the prompt.
#
# The reviewer now runs in a DETACHED worktree at the exact head under review. Detached is the point:
# a commit made there moves NO branch, so the worst a runaway reviewer can do to the reviewed ref is
# nothing. The tree is created OUTSIDE the repo so nothing it writes lands under the checkout as even
# an ignored path, and it is removed on exit so a leaked mutation is discarded WITH the tree instead
# of being swept into someone's commit. The containment is the mount, not the prompt.
# The ADMIN RECORD that git keeps for OUR sandbox — and never a scan of anyone else's. Two ways to
# find it: (a) the tree is still on disk and its `.git` file names the record outright; (b) the
# directory is gone but the record survived, and git names the record after the sandbox basename.
sandbox_record() { # sandbox_record <sandbox-dir> — print the admin dir, or nothing
  local d="${1:-}" g gcd
  [ -n "$d" ] || return 0
  g="$(sed -n 's/^gitdir: //p' "$d/.git" 2>/dev/null)"
  if [ -n "$g" ]; then printf '%s' "$g"; return 0; fi
  gcd="$(git -C "${REPO:-.}" rev-parse --git-common-dir 2>/dev/null)"
  case "$gcd" in ''|'.') gcd="${REPO:-.}/.git" ;; /*) ;; *) gcd="${REPO:-.}/$gcd" ;; esac
  [ -d "$gcd/worktrees/${d##*/}" ] && printf '%s' "$gcd/worktrees/${d##*/}"
  return 0
}

# Deregister exactly ONE record — OURS — and only after its own `gitdir` file names our sandbox.
# ⛔ A bare `git worktree prune` is BANNED here (agent-infra docs/ops/load-policy.md:491; repo-wide
# pruning is the #1095 reaper's job, and skills/code-review/SKILL.md forbids the shape for exactly
# this reason): it deregisters EVERY record whose directory is not stat-able at that instant
# (unmounted volume, permission blip, stale network mount), so a routine probe silently orphans an
# unrelated sibling lane's checkout while its files sit on disk. It is also unnecessary here — the
# record is ours by name, so it can be removed by name.
drop_sandbox_record() { # drop_sandbox_record <sandbox-dir>
  local d="${1:-}" rec g
  [ -n "$d" ] || return 0
  rec="$(sandbox_record "$d")"
  case "$rec" in */worktrees/*) ;; *) return 0 ;; esac
  # NB: the record's own `gitdir` file holds the path PLAIN (no `gitdir: ` prefix, unlike the
  # worktree's `.git` file); strip the prefix too in case a future git adds it.
  g="$(sed -n '1{s/^gitdir: //;p;}' "$rec/gitdir" 2>/dev/null)"
  [ -n "$g" ] || return 0
  case "$g" in "$d"/.git|*/"${d##*/}"/.git) ;; *) return 0 ;; esac
  # (the alternative is `*/<basename>/.git`, byte-identical to tortoise origin/main:92 — a stray
  #  extra `/` here makes the basename fallback unmatchable and re-bricks the head; the driven
  #  witness is selftest.sh §21b.)
  rm -rf "$rec"
  return 0
}

review_sandbox() { # review_sandbox <ref|sha> — print the sandbox path, or nothing on failure
  [ -n "${1:-}" ] || return 1
  local base slug dir
  # Name the sandbox from digits plus a SANITIZED slug only: the path is `rm -rf`d below, so no
  # caller-supplied text may reach it as a separator, a `..` or a leading `-`.
  # ⛔ 40 CHARS IS FOR THE *SLUG*, NOT THE REVISION (review P2, this pass). `refs/heads/` is 11
  # characters, so `cut -c1-40` truncates any branch name longer than 29 — and the fallback call
  # site passes exactly that (`review_sandbox "${HEAD:-refs/heads/$BR}"`). The add then dies
  # `fatal: invalid reference: refs/heads/<cut>`, SANDBOX stays empty and merge-one.sh exits 6.
  # Keep the revision whole; only the directory name is truncated.
  base="$(printf '%s' "$1" | cut -c1-40)"
  slug="$(printf '%s' "$base" | tr -c 'A-Za-z0-9._-' '_')"
  [ -n "$slug" ] || return 1
  dir="$O/review/$PR-$slug"
  case "$dir" in "$O"/review/*) ;; *) return 1 ;; esac
  mkdir -p "$O/review" 2>/dev/null || return 1
  # A sandbox at the SAME head is stale by construction (the head names it): a crashed run's leftover
  # is REMOVED, never reused — a reused tree could still carry the previous reviewer's mutant.
  if [ -e "$dir" ]; then
    git -C "$REPO" worktree remove --force "$dir" >/dev/null 2>&1 || rm -rf "$dir"
  fi
  # ⛔ A RECORD WITHOUT ITS TREE BRICKS THIS HEAD FOREVER. A registration keyed to this same sandbox
  # name survives a crashed run, and with the directory gone `worktree add` refuses ("missing but
  # already registered worktree") — measured with the shipped helper. review_sandbox then prints
  # nothing, merge-one.sh exits 6, and exit 6 writes NO needsfix marker, so the controller
  # re-dispatches a PR that can never be reviewed, every cycle, with no terminal state. Clear OUR OWN
  # record first — by name, never a repo-wide prune (see drop_sandbox_record).
  drop_sandbox_record "$dir"
  git -C "$REPO" worktree add --detach "$dir" "$1" >/dev/null 2>&1 || { rm -rf "$dir"; drop_sandbox_record "$dir"; return 1; }
  printf '%s' "$dir"
}

# The reviewer's checkout must never outlive this run. `worktree remove` drops git's admin entry AND
# the tree, but its exit status is NOT trusted and neither step is conditional on the other: a
# sandbox that survives the run is the leak this exists to prevent, whatever git reported. (A tree
# the reviewer deleted or damaged makes `remove` refuse — hence the rm + the TARGETED deregistration
# behind it.) It runs in the EXIT trap of a script that fires on every merge, on the shared checkout,
# so it may not touch any record that is not its own: a bare `git worktree prune` here was a P1
# finding and is BANNED (agent-infra docs/ops/load-policy.md:491, skills/code-review/SKILL.md).
review_cleanup() {
  [ -n "${SANDBOX:-}" ] || return 0
  git -C "${REPO:-.}" worktree remove --force "$SANDBOX" >/dev/null 2>&1
  [ -e "$SANDBOX" ] && rm -rf "$SANDBOX"
  # `remove` drops the admin entry when it succeeds. When it refused (a damaged tree) the record
  # survives the rm -rf above and would brick the next provisioning at this head — so drop OURS, by
  # name. Never a repo-wide prune: see drop_sandbox_record.
  drop_sandbox_record "$SANDBOX"
  return 0
}

# The reviewed branch's local + remote shas. Sampled BEFORE and AFTER the reviewer, so a ref move
# the controller did not request is LOUD instead of absorbed — and a review is never recorded
# against a head that is no longer the branch tip.
ref_shas() { # ref_shas <branch> — "<local> <remote>", "-" for an absent ref
  printf '%s %s' \
    "$(git -C "$REPO" rev-parse -q --verify "refs/heads/$1" 2>/dev/null || echo -)" \
    "$(git -C "$REPO" rev-parse -q --verify "refs/remotes/origin/$1" 2>/dev/null || echo -)"
}

# WHICH of the two sampled refs actually moved, and its sha. Taking the LOCAL field first (the
# pre-#8589 shape) mis-attributes the mover: a reviewer that pushes updates
# `refs/remotes/origin/<br>` but NOT `refs/heads/<br>`, so the local field is the UNCHANGED tip that
# was already under review — the log then named the wrong commit and the wrong actor. Diagnostic
# only (the refusal itself was right), but a mis-attribution is worse than none when the whole point
# is to name who moved the branch.
mover_of() { # mover_of <pre "<local> <remote>"> <post> <branch> — "<ref> <sha>"
  local pre_l pre_r post_l post_r
  pre_l="${1%% *}"; pre_r="${1##* }"
  post_l="${2%% *}"; post_r="${2##* }"
  if [ "$post_l" != "$pre_l" ]; then printf 'refs/heads/%s %s' "$3" "$post_l"; return 0; fi
  printf 'refs/remotes/origin/%s %s' "$3" "$post_r"
}

# ── the reviewer's verdict, and what it authorises (#8612, tortoise f5823a6a4) ─
# Classify the reviewer's FINAL message. A function rather than an inline `case` so the self-test
# EXECUTES the shipped rule: a `grep` for its text stays green when an arm is deleted or reworded.
# `none` means there was NO verdict — the reviewer timed out, crashed, or was killed at
# $REVIEW_TIMEOUT. It is NOT "the reviewer found issues", and the two must never share a caller
# arm: that conflation is what turned a stall into a false park (#8602, agent-infra#1741).
verdict_kind() {
  case "${1:-}" in
    CLEAN*)  echo clean ;;
    ISSUES*) echo issues ;;
    *)       echo none ;;
  esac
  return 0
}

# Apply the reviewer's outcome marker. `needsfix-<PR>-<head>` is the ONLY thing that authorises
# orch-loop.sh to spawn a FIXER at this head, so it is written for a real `ISSUES` verdict and for
# nothing else. A verdict-less run writes NO marker: with one, a pure stall consumes one of
# MAX_FIX_TRIES, and three stalls park the PR "needs a human" with the reviewer's findings never
# addressed (measured: 7 PRs at fixcount==3, 4 false-parked — #8602 indicator (c)).
# Echoes the marker path when it wrote one.
apply_verdict_marker() {
  local kind="${1:-}" head="${2:-}" m
  [ "$kind" = "issues" ] || return 0
  [ -n "$head" ] || return 0
  m="$O/state/needsfix-$PR-$head"
  touch "$m" 2>/dev/null && printf '%s' "$m"
  return 0
}

git fetch origin "$BR" --quiet 2>/dev/null || true   # external (other-machine) branches may not be fetched locally

# HEAD is resolved BEFORE the claim: the cross-box claim key is <PR>-<head-sha12> (claim_key()
# truncates the sha to 12), not <PR>
# (agent-infra#1709 rec 1). It is also the key record-review/needsfix already use.
HEAD="$(gh pr view "$PR" --repo "$OR" --json headRefOid --jq .headRefOid 2>/dev/null)"

# ── single-owner claim: local lock, then the cross-box git-ref claim ──────────
# Three paths reach this script: chain-<N> (waits for a lane's PR), fix-<PR>, and the
# controller's merge sweep. Only the last two are visible to the controller by session name,
# so without a shared claim a freshly opened PR gets TWO concurrent reviewers racing the same
# head: duplicate evidence comments, duplicate record-review writes, and an
# ISSUES/CLEAN interleaving where one worker's needsfix marker lands after the other merged.
# Atomic noclobber create is the lock; the controller also tests this file.
# ⛔ THE LOCK MUST BE TAKEN BEFORE THE LOG IS TRUNCATED. The loser below appends its refusal to
# the winner's log; if the truncation ran first, the loser would wipe the live worker's log (and
# the "cross-box claim: acquired …" evidence this ordering exists to protect) on its way to
# discovering it does not own the PR. (P2, 2026-10-14 review round.)
CLAIM="$O/state/mergeclaim-$PR.lock"
claim() { ( set -o noclobber; echo $$ > "$CLAIM" ) 2>/dev/null; }
if ! claim; then
  OPID="$(cat "$CLAIM" 2>/dev/null || echo 0)"
  if [ "${OPID:-0}" -gt 0 ] && kill -0 "$OPID" 2>/dev/null; then echo "[merge $PR] pid $OPID already owns this PR — exiting" >> "$L.log"; exit 0; fi
  rm -f "$CLAIM"
  claim || { echo "[merge $PR] claim race — exiting" >> "$L.log"; exit 0; }
fi
# ⛔ Same defect as orch-loop.sh, on the per-PR claim (§5.1b): a RETURNING INT/TERM handler
# resumes the interrupted command loop, so a TERM removed the claim while this worker kept
# reviewing and merging, and the controller could spawn a second worker for the same head. The
# handlers TERMINATE; the claim is released by the EXIT trap alone. Measured on /bin/bash 3.2.57:
# `exit 143` from a TERM handler still runs the EXIT trap (rc=143); an untrapped INT is ignored
# outright (still alive after 3s), so INT is trapped rather than dropped. (agent-infra#1715)
trap 'exit 143' TERM
trap 'exit 130' INT
trap 'rm -f "$CLAIM"; review_cleanup' EXIT

# The log is TRUNCATED here — AFTER the local lock, so a losing duplicate never touches it, and
# BEFORE any cross-box claim evidence is appended, so the "cross-box claim: acquired …" line
# survives. Truncating at the end of the claim block silently deleted that evidence on every run.
echo "[merge $PR] start $(date) head=$HEAD branch=$BR" > "$L.log"

# ── cross-box claim (agent-infra#1709 recs 1-3) ───────────────────────────────
# The noclobber lock above is atomic on ONE box only: three boxes driving this repo are three
# independent filesystems, so it stops nothing between them. The boxes share exactly one
# durable store — the repository — and creating a ref with `git push` is an atomic CAS.
#
# FAIL-OPEN, ON PURPOSE. If the claim store is unreachable (network blip, a rejected push for
# an unrelated reason) we proceed and SAY SO in the log. #1709's headline finding is that
# no mechanism guarantees two machines never run the same job, so the design must tolerate
# duplicates: every side effect on this path is idempotent per head (one evidence comment, a
# record-review marker keyed on $HEAD, and `gh pr merge` twice is a no-op). Failing CLOSED
# would stall the whole fleet on one transient error — the strictly worse failure. The log
# line makes the fallback visible rather than silent.
CROSS_OWN=""
CROSS_RC=0

# Release the cross-box claim, BOUNDED to ~20s. `claim_release` is one network push and a
# black-holed connection can hang for minutes; this runs on the EXIT path, so it must not hold the
# process open (P3, 2026-10-14 adversarial review). Returns claim_release's status (1 = nothing to
# release), so a caller can tell a fenced release from a refusal.
# ⛔ THE 20s BOUND IS A DELIBERATE TRADE (P3, second review round, 2026-10-14): it CAN kill a
# release that would eventually have succeeded — a `git push` slower than 20s is TERM'd, the fenced
# push leaves the ref intact, and every box then refuses that head until the lease expires (up to
# REVIEW_TIMEOUT+1200 = 50 min). That is accepted because the alternative is strictly worse: an
# UNBOUNDED exit path (and, before the ordering fix above, one that dropped the local lock FIRST)
# lets the controller spawn a second worker for the same head. DO NOT remove the bound — the
# ordering defect it fixes is real. A future improvement is to move the release OFF the exit path
# (a detached retry), not to wait longer here.
release_claim_bounded() {
  local p w rc
  [ -n "${CROSS_OWN:-}" ] || return 1
  claim_release "$REPO" "$PR" "$HEAD" "$CROSS_OWN" >/dev/null 2>&1 &
  p=$!
  ( sleep 20; kill -TERM "$p" 2>/dev/null; sleep 5; kill -KILL "$p" 2>/dev/null ) >/dev/null 2>&1 &
  w=$!
  wait "$p" 2>/dev/null; rc=$?
  kill "$w" 2>/dev/null
  return "$rc"
}

# ⛔ Coerce REVIEW_TIMEOUT BEFORE the arithmetic below (P1, 2026-10-14 adversarial review). On
# /bin/bash 3.2.57 — what the launchd plist invokes — a FAILED arithmetic assignment aborts the
# remainder of the enclosing `if` body and resumes after `fi` with status 0. Reproduced with the
# real merge-one.sh and REVIEW_TIMEOUT=30m: `CLAIM_LEASE=$(( 30m + 1200 ))` aborted the claim block,
# claim_acquire was NEVER called, the log carried NO "cross-box claim" line at all, and the worker
# still reported success. The trigger is plausible because `30m`/`1800s` are VALID for `sleep`, so
# the operator's intended timeout works while the claim silently vanishes. Coerce rather than
# reject: a bad tunable must not cost the fleet its cross-box safety.
if ! is_limit "${REVIEW_TIMEOUT:-1800}"; then
  echo "[merge $PR] REVIEW_TIMEOUT='${REVIEW_TIMEOUT:-}' is not an integer in range (at most 9 digits) — using 1800 (the cross-box lease needs a number that cannot overflow)" >> "$L.log"
  REVIEW_TIMEOUT=1800
fi

if [ -n "${HEAD:-}" ] && [ -f "$O/claims.sh" ]; then
  # shellcheck source=/dev/null
  . "$O/claims.sh"
  # The lease must OUTLIVE a worst-case review, or another box takes over mid-review and we get
  # the duplicate work this exists to prevent: REVIEW_TIMEOUT (default 1800) + the 30x30s gate
  # wait below (900) + the merge itself. Derived, not a bare constant — and passed explicitly,
  # because sourcing claims.sh above sets CLAIM_TTL=1800 and would silently win over a default.
  # Overflow-safe by construction: the guard above leaves REVIEW_TIMEOUT <= 999999999, so this sum
  # is < 2**31. claims.sh clamps the ttl a second time at its own arithmetic site, so a future caller
  # that skips this guard still cannot mint a lease the reader is unable to parse.
  CLAIM_LEASE=$(( ${REVIEW_TIMEOUT:-1800} + 1200 ))
  claim_acquire "$REPO" "$PR" "$HEAD" "$CLAIM_LEASE" >/dev/null
  CROSS_RC=$?
  case "$CROSS_RC" in
    0) CROSS_OWN="$CLAIM_COMMIT"
       echo "[merge $PR] cross-box claim: $CLAIM_RESULT" >> "$L.log" ;;
    1) echo "[merge $PR] cross-box claim REFUSED: $CLAIM_RESULT — another box owns head $HEAD; exiting" >> "$L.log"
       rm -f "$CLAIM"; exit 0 ;;
    *) echo "[merge $PR] cross-box claim UNAVAILABLE (rc=$CROSS_RC: $CLAIM_RESULT) — proceeding on the local lock alone" >> "$L.log"
       # P2 (2026-10-14 adversarial review): the CREATE path can SUCCEED on the remote and fail only
       # the read-back. claims.sh surfaces the commit it pushed; release it, fenced, so the PR is not
       # stalled fleet-wide until the lease expires (up to REVIEW_TIMEOUT+1200 = 50 min of every box
       # refusing to review it). CROSS_OWN stays set only when this fenced release FAILS, so the EXIT
       # trap retries it.
       if [ -n "${CLAIM_COMMIT:-}" ]; then
         CROSS_OWN="$CLAIM_COMMIT"
         if release_claim_bounded; then
           CROSS_OWN=""
           echo "[merge $PR] cross-box claim: released the orphaned claim commit ${CLAIM_COMMIT:0:12} after the read-back failure" >> "$L.log"
         else
           echo "[merge $PR] cross-box claim: could not release the orphaned commit ${CLAIM_COMMIT:0:12} — the EXIT trap will retry" >> "$L.log"
         fi
       fi ;;
  esac
fi
# agent-infra's TERM/INT handlers above only TERMINATE (the #1715 fix); each `exit` runs this
# EXIT trap, so the cross-box release folds in here rather than into a returning handler.
# ⛔ ORDER (P3, 2026-10-14 adversarial review): the release runs FIRST and is BOUNDED. The old trap
# did `rm -f "$CLAIM"` first and then an UNTIMED `claim_release` push — a black-holed connection hung
# the exit path for minutes with the local pid lock already gone, so the controller could spawn a
# second worker for the same PR. Release first, drop the lock last.
trap 'release_claim_bounded; rm -f "$CLAIM"; review_cleanup' EXIT

# ── the repo's merge authority (agent-infra#1764) ─────────────────────────────
# Resolved HERE, from branch protection, not assumed. On a repo that requires the review gate the
# chain below is exactly what it always was (wait for the gate, then squash). On a repo that does
# NOT require it, `gh pr merge` would land the PR on the required checks alone with no head-bound
# evidence — the bypass agent-infra's AGENTS.md forbids — so the repo's OWN rail is the authority.
# ⛔ resolve_required_checks, NOT a command substitution around it: `REQ="$(resolve_required_checks …)"`
# subshells the resolver and REQ_SOURCE cannot survive it (the log line below would print source=?).
resolve_required_checks "$OR"
MERGE_AUTHORITY="$(merge_authority "$REQ")"
echo "[merge $PR] repo-authority: required=[$REQ] source=${REQ_SOURCE:-?} authority=$MERGE_AUTHORITY" >> "$L.log"

# ⛔ AUTHORITY-UNKNOWN REFUSAL (review P1, round 2). The CONTROLLER's AUTHORITY_UNKNOWN guard
# covers only its own sweep — this script is ALSO invoked directly by chain-merge.sh and
# fix-one.sh, and a worker whose OWN protection read failed fell back to FALLBACK_REQ (gate
# authority, because the fallback carries the gate name) and could reach the raw merge below on a
# rail repo whose gate row happened to read green — and always burned a full fresh-context
# reviewer first. The guard therefore lives HERE, at the point of consequence: EVERY ingress is
# covered, whatever spawned it. A controller-spawned `merge-<PR>` worker IS handed a frozen
# contract: its spawn carries REQ/REVIEW_GATE, which arrive here as REQ_OVERRIDE and short-circuit
# the read below — one resolution, one authority, so the worker cannot disagree with the controller
# that classified the PR. The `chain-<N>` and `fix-one.sh` ingresses are the ones that are NOT
# handed one and re-read branch protection themselves, and a chain worker can wait up to 90 minutes
# after that read; a fresh read that refuses beats a stale one that merges.
# ⛔ ALLOW-LIST POLARITY (round-11 review, P2). This guard used to be a DENY list — `-z REQ`,
# `= unknown`, `fallback`-with-no-override — so ANY value that was not one of those fell through to
# the rail-only test below and then into the review path, which ends in a raw `gh pr merge`. An
# authority the worker does not recognise must refuse exactly like `unknown` (the same polarity the
# controller's GREEN arm now uses).
if [ -z "${REQ:-}" ] \
   || { [ "$MERGE_AUTHORITY" != "gate" ] && [ "$MERGE_AUTHORITY" != "rail" ]; } \
   || { [ "${REQ_SOURCE:-}" = "fallback" ] && [ -z "${REQ_OVERRIDE:-}" ]; }; then
  # ⛔ round-12 review, P3: this named ONE cause (an unreadable protection read) for ALL the
  # refusal causes, so the allow-list refusal — reached with a READABLE contract and a valid
  # override — told the operator to chase a gh fault that did not exist, and the line contradicted
  # its own REQ_SOURCE. Name the actual cause.
  _wr=""
  if [ -z "${REQ:-}" ]; then _wr="REQ is EMPTY"; fi
  if [ "$MERGE_AUTHORITY" != "gate" ] && [ "$MERGE_AUTHORITY" != "rail" ]; then
    _wr="${_wr:+$_wr; }the merge authority is '${MERGE_AUTHORITY:-<unset>}' (neither gate nor rail)"
  fi
  if [ "${REQ_SOURCE:-}" = "fallback" ] && [ -z "${REQ_OVERRIDE:-}" ]; then
    _wr="${_wr:+$_wr; }branch protection was UNREADABLE (REQ_SOURCE=fallback) and no override was supplied"
  fi
  echo "[merge $PR] REFUSED: the merge contract is UNKNOWN — ${_wr:-no cause recorded}. This worker merges nothing (agent-infra#1764)." >> "$L.log"
  exit 5
fi

if [ "$MERGE_AUTHORITY" = "rail" ]; then
  # RAIL MODE. The reviewer is deliberately SKIPPED here: this repo's merge authority is the rail,
  # which posts its OWN head-bound evidence and merges — a review comment / signed record marker is
  # the TORTOISE contract and is consumed by nothing on this repo, so minting one would only edit a
  # PR body for no gate.
  # ⛔ A MISSING RAIL REFUSES. It never degrades to `gh pr merge`: that is the bypass this branch
  # exists to prevent, and a silent downgrade is exactly how a guard becomes decorative.
  RAIL="$REPO/scripts/admin-merge.sh"
  if [ ! -f "$RAIL" ]; then
    echo "[merge $PR] REFUSED: merge authority for $OR is its rail, but $RAIL does not exist — refusing to fall back to a raw gh pr merge (agent-infra#1764)" >> "$L.log"
    exit 6
  fi
  # BOUNDED RETRY, keyed on the head. A rail refusal is head-specific (it blocks on THIS tree), so
  # a later push re-arms it; the SAME head is retried at most RAIL_TRIES times so a permanently
  # blocked PR is not re-analysed every cycle — the API burn #1764 reports. At the cap the head is
  # PARKED, which the sweep already honours (`parked-$PR` == the current head).
  # ⚠️ review round 5 — P1: `RAIL_TRIES` must be DEFAULTED, not merely tested. The guard below
  # only assigns it in the INVALID branch, so with the variable unset (the production default:
  # nothing in install.sh, the launchd plist, the README or a cell keys.env sets it) lines 276
  # and 294 expanded it bare under `set -u` and the worker died `unbound variable` BEFORE
  # `bash "$RAIL"` was ever reached — rail mode was dead on arrival, no agent-infra PR could
  # drain, the retry cap could never park, and the sweep re-spawned a worker every cycle. That
  # is #1764's own deadlock, reintroduced on the new path. The default is assigned HERE so every
  # later expansion is safe.
  # ⛔ REFUSE ON AN EMPTY HEAD (review round 6, P2). The retry budget is HEAD-KEYED, so without a
  # head it cannot be kept: `printf '%s %s' "" "$RC_N"` writes " 1", `read -r RC_H RC_N` strips the
  # leading blank (RC_H=1, RC_N=""), `is_limit ""` fails and RC_N resets to 0 on EVERY pass — the
  # cap is unreachable, no park is ever written, and the sweep re-runs the rail every cycle: the
  # per-cycle API burn RAIL_TRIES exists to close. A transient head-read failure is retried next
  # cycle, which is the fail-closed direction.
  if [ -z "${HEAD:-}" ]; then
    echo "[merge $PR] REFUSED: the PR head could not be read (empty) — a head-keyed retry budget cannot be kept without it, and an un-keyed rail retry is the per-cycle API burn RAIL_TRIES exists to close" >> "$L.log"
    exit 7
  fi
  RAIL_TRIES="${RAIL_TRIES:-3}"
  if ! is_limit "$RAIL_TRIES"; then
    echo "[merge $PR] RAIL_TRIES='$RAIL_TRIES' is not an integer in range — using 3" >> "$L.log"
    RAIL_TRIES=3
  fi
  RC_F="$O/state/railcount-$PR"; RC_H=""; RC_N=0
  if [ -f "$RC_F" ]; then read -r RC_H RC_N < "$RC_F" 2>/dev/null || true; fi
  # is_limit, not is_num (review P2, round 1): the value feeds `[ -ge ]` and `$(( + 1 ))`, so a
  # huge digit string must be rejected here, exactly like RAIL_TRIES/REVIEW_TIMEOUT above —
  # `[ 99999999999999999999 -ge 3 ]` errors FALSE on bash 3.2 and the cap is silently missed.
  is_limit "${RC_N:-}" || RC_N=0
  # A head we have not seen before resets the count — the retry budget belongs to the HEAD.
  [ "${RC_H:-}" = "${HEAD:-}" ] || RC_N=0
  if [ "$RC_N" -ge "$RAIL_TRIES" ]; then
    printf '%s %s\n' "${HEAD:-}" "$RC_N" > "$RC_F"
    # Write the park UNCONDITIONALLY (review P1, round 1): the guarded write left a park from a
    # PREVIOUS head in place forever. A new head then reached the cap, saw the stale file, never
    # recorded itself, and exit 0'd — and the sweep (which honours a park only when its CONTENT
    # matches the current head) re-spawned a rail worker every cycle forever, the exact burn the
    # cap exists to close. The LOG line stays novel-only (per head) so the log does not repeat.
    if [ "$(cat "$O/state/parked-$PR" 2>/dev/null)" != "${HEAD:-}" ]; then
      echo "[merge $PR] PARKED — the rail refused $RC_N time(s) at head=${HEAD:-?}; a new push re-arms it" >> "$L.log"
    fi
    echo "${HEAD:-}" > "$O/state/parked-$PR"
    exit 0
  fi
  RC_N=$((RC_N + 1)); printf '%s %s\n' "${HEAD:-}" "$RC_N" > "$RC_F"
  if ( cd "$REPO" && bash "$RAIL" "$PR" --repo "$OR" -- --squash ) >> "$L.log" 2>&1; then
    echo "[merge $PR] MERGED via the rail (attempt $RC_N) $(date)" >> "$L.log"
    touch "$O/state/merged-$PR.done"
  else
    echo "[merge $PR] rail refused (attempt $RC_N/$RAIL_TRIES) at head=${HEAD:-?} — the sweep retries this head until the cap, then PARK" >> "$L.log"
  fi
  exit 0
fi

# ── 0) terminal state and the record dependency — BEFORE the paid review (#1717) ──────────────
# `park` records the terminal state at the head that was reviewed. It is deliberately the SAME
# marker the controller's own park paths write (`parked-<PR>` = the head, so a new push re-arms),
# plus a `parkreason-<PR>` that names WHY — the controller cannot say why, and "PARKED" with no
# reason is a state nobody can act on.
park() { # park <reason…>
  local why="$*"
  # ⛔ THE REASON BELONGS TO THE HEAD THIS PARK IS KEYED TO. An EMPTY HEAD means the
  # unresolvable-head branch below (a transient `gh` blip) reached park() while an earlier park at a
  # real head is still in place: it writes no marker, and re-writing the reason there would replace
  # the real, actionable cause with the transient one — so when gh recovers the worker matches the
  # park, exits 5, and the exit-5 log (the only in-band remedy on the chain-<N>/fix-one.sh paths)
  # would name the wrong cause. With no head there is no new park to describe, so the first reason
  # wins. A NON-EMPTY HEAD is a fresh park — a moved head re-arms the PR and the already-parked
  # guard cannot have fired for it — so its reason must REPLACE a stale one from an earlier head.
  if [ -n "${HEAD:-}" ] || [ ! -s "$O/state/parked-$PR" ]; then
    printf '%s\n' "$why" > "$O/state/parkreason-$PR"
  fi
  [ -n "${HEAD:-}" ] && printf '%s\n' "$HEAD" > "$O/state/parked-$PR"
  echo "[merge $PR] PARKED head=${HEAD:-?} — $why" >> "$L.log"
}

# ⛔ THE HEAD IS THE SAME CLASS OF PRE-REVIEW DEPENDENCY AS THE RECORDER (#1717). The `gh pr view`
# above swallows its own failure (2>/dev/null), so one transient API/network/rate-limit blip leaves
# HEAD empty — and the PRE-FIX flow still ran the WHOLE fresh-context review (up to REVIEW_TIMEOUT =
# 1800 s, PAID), only for record-review.sh to refuse an empty sha ("head_sha must be a full 40-char
# hex sha — refusing to record"). park() then could not write `parked-<PR>` AT ALL (there is no head
# to key it to, and the controller's guard requires a non-empty head too), so the controller saw no
# park at its HEAD_N, re-spawned a worker, and paid again every cycle — the exact unbounded paid
# loop #1717 removes. Refuse BEFORE the paid step, against the same 40-char hex shape
# record-review.sh enforces, and leave the actionable terminal reason.
head_ok=0
case "${HEAD:-}" in '' | *[!0-9a-f]*) head_ok=1 ;; esac
[ "${#HEAD}" -eq 40 ] || head_ok=1
if [ "$head_ok" -ne 0 ]; then
  park "could not resolve PR #$PR head (gh pr view returned '${HEAD:-<empty>}') — the record step needs a full 40-char hex sha, so a review paid for here could never be recorded or merged. Re-run once gh is reachable, then: rm -f '$O/state/parked-$PR' '$O/state/parkreason-$PR'"
  echo "[merge $PR] ABORT: unresolvable head '${HEAD:-<empty>}' — not paying for a review whose record step could never sign" >> "$L.log"
  exit 3
fi

# Honour the park HERE, not only in the controller. chain-<N> and fix-one.sh invoke this script
# directly, and the controller's parked guard is invisible to them; without this the park would
# hold only the path that was already fixed. Exit 5 = "refused, already parked at this head".
if [ -n "${HEAD:-}" ] && [ "$(cat "$O/state/parked-$PR" 2>/dev/null)" = "$HEAD" ]; then
  echo "[merge $PR] PARKED at head=$HEAD — refusing to re-review (reason: $(cat "$O/state/parkreason-$PR" 2>/dev/null)). A push re-arms it, or: rm -f '$O/state/parked-$PR' '$O/state/parkreason-$PR'" >> "$L.log"
  exit 5
fi

# ⛔ THE RECORD STEP IS THE ONLY MERGE PATH, AND IT USED TO BE PAID TO DISCOVER IT WAS MISSING
# (#1717). record-review.sh mints the signed marker ai-review-gate verifies; on a fresh cell the
# file is absent. The pre-fix flow ran the WHOLE fresh-context review (up to REVIEW_TIMEOUT = 1800 s,
# PAID) and only then failed — and its `exit 3` skipped the `*)` arm that writes the fixer marker,
# so the next cycle saw an unmarked FAILED:ai-review-gate and spawned another review. One paid
# review per cycle, forever. Refuse BEFORE the paid step, and leave the terminal marker.
# The probe must require a NON-EMPTY REGULAR FILE, not merely presence + executability: `[ -x ]` is
# true for a directory (the paid review is then bought, and the record step fails 126), and an EMPTY
# file is executable and exits 0 WITHOUT minting the marker — so nothing is parked and the loop
# re-pays, which is the #1717 loop one input over. Same shape cmd_check enforces.
RECORDER="$HOME/.pi/agent/scripts/record-review.sh"
if [ ! -e "$RECORDER" ]; then
  park "record-review.sh MISSING at $RECORDER — the record step cannot run, so this PR can never be signed or merged. Provision it (cp it into \$HOME/.pi/agent/scripts/ and chmod +x), then: rm -f '$O/state/parked-$PR' '$O/state/parkreason-$PR'"
  echo "[merge $PR] ABORT: $RECORDER missing — not paying for a review whose record step cannot run" >> "$L.log"
  exit 3
fi
if [ ! -f "$RECORDER" ]; then
  park "record-review.sh at $RECORDER is NOT A REGULAR FILE — merge-one.sh runs it directly, so a directory (or any other non-regular file) fails (126) after a PAID review. Remove it and re-provision (start, or cp into \$HOME/.pi/agent/scripts/ and chmod +x), then: rm -f '$O/state/parked-$PR' '$O/state/parkreason-$PR'"
  echo "[merge $PR] ABORT: $RECORDER not a regular file — not paying for a review whose record step cannot run" >> "$L.log"
  exit 3
fi
if [ ! -s "$RECORDER" ]; then
  park "record-review.sh at $RECORDER is EMPTY (0 bytes) — an empty file is executable and exits 0 WITHOUT minting the signed marker, so ai-review-gate can never go green and the loop would re-pay for a fresh review every cycle. Re-provision it (start, or cp into \$HOME/.pi/agent/scripts/ and chmod +x), then: rm -f '$O/state/parked-$PR' '$O/state/parkreason-$PR'"
  echo "[merge $PR] ABORT: $RECORDER is empty — not paying for a review whose record step cannot sign" >> "$L.log"
  exit 3
fi
if [ ! -x "$RECORDER" ]; then
  park "record-review.sh at $RECORDER is NOT EXECUTABLE — the record step would fail (126) after a PAID review. Fix: chmod +x '$RECORDER', then: rm -f '$O/state/parked-$PR' '$O/state/parkreason-$PR'"
  echo "[merge $PR] ABORT: $RECORDER not executable — not paying for a review whose record step cannot run" >> "$L.log"
  exit 3
fi

# ── the load gate, consulted BEFORE any work (#8484) ─────────────────────────
# run_agent() applies this same predicate moments before it spawns — but it spawns AFTER the
# sandbox is provisioned, and a `git worktree add` is a full checkout of the repo. Doing that on a
# box the gate is about to refuse is real work (and a real `.git/worktrees` entry, and real disk)
# for a review that never happens, on the machine least able to afford it. Same shared predicate,
# same exit code, same log shape, so the operator cannot tell the two refusal sites apart; run_agent
# still re-reads load at the spawn, because that is the reading that governs. Placed AFTER the
# rail-mode early exit on purpose: rail mode runs no reviewer, so a reviewer load gate must not
# hold a rail merge back (agent-infra#1764).
_load="$(load1)"
if ! can_spawn "$_load"; then
  echo "[load-gate] REFUSED reviewer for PR #$PR: load=$_load >= max_load=$MAX_LOAD — no agent started, no review sandbox created (the cross-box claim taken above is released by the EXIT trap)" >> "$L.log"
  exit "$AGENT_LOAD_REFUSED"
fi

# ⛔ THE HEAD OID MAY NOT EXIST IN THE LOCAL OBJECT STORE. A FORK PR's branch is not on `origin` at
# all, so the tolerant `git fetch origin "$BR"` above cannot find it and `worktree add <oid>` then
# fails hard (`fatal: invalid reference`). Not fetched = this PR can NEVER be reviewed: exit 6 writes
# no needsfix marker, so broad mode re-dispatches it every cycle, forever (PR #8589 review).
# `refs/pull/<N>/head` is where GitHub publishes a fork PR's head, and fetching it is the one call
# that makes the oid present.
[ -n "${HEAD:-}" ] && git -C "$REPO" fetch origin "refs/pull/$PR/head" --quiet 2>/dev/null || true

# The reviewer's cwd: an ISOLATED, detached checkout of the head being reviewed (#8484). A failure
# to provision is NOT fallen back to the shared checkout — that fallback would restore exactly the
# write surface this removes. No sandbox, no review.
SANDBOX="$(review_sandbox "${HEAD:-refs/heads/$BR}")"
if [ -z "$SANDBOX" ]; then
  echo "[merge $PR] ABORT: could not provision an isolated review checkout for ${HEAD:-refs/heads/$BR} — refusing to run the reviewer in the shared checkout (#8484)" >> "$L.log"
  # ⛔ AN UNREVIEWABLE HEAD MUST NOT BE AN UNBOUNDED PER-CYCLE RE-DISPATCH. A bare exit 6 writes no
  # marker, so the controller falls through to the re-record branch every cycle with no terminal
  # state and no escalation. When the head oid genuinely is not in the local store even after the
  # `refs/pull/<N>/head` fetch above, PARK it at this head: orch-loop.sh skips a PR whose
  # `parked-<PR>` equals its head, and a later push re-arms it (the marker is head-bound). park()
  # also writes `parkreason-<PR>`, so the operator sees WHY (the #1717 contract). The head-shape
  # guard above guarantees a non-empty 40-hex HEAD here, so this park is always keyed.
  if ! git -C "$REPO" cat-file -e "${HEAD}^{commit}" 2>/dev/null; then
    park "the head object ${HEAD:-?} is not in the local object store even after fetching refs/pull/$PR/head — no isolated review checkout could be provisioned and no verdict was recorded; a human must push or fetch the head, or a new push re-arms it"
    echo "[merge $PR] ⛔ PARKED at head=${HEAD:-?}: the head object is not in the local object store even after fetching refs/pull/$PR/head — a human must push or fetch it; no verdict was recorded" >> "$L.log"
  fi
  exit 6
fi
echo "[merge $PR] review sandbox=$SANDBOX (detached at ${HEAD:-refs/heads/$BR})" >> "$L.log"

# ── 1) fresh-context review, POSTED as a PR comment (the audit artifact) ──────
# The prompt is a FUNCTION so the self-test can EXECUTE it and assert on the text the reviewer
# actually receives (the #8602 check reads this function's output, not a grep of this file — a
# reflow of the heredoc would otherwise silently restore the deleted sentence).
reviewer_prompt() {
cat <<EOF
You are a FRESH-CONTEXT code reviewer for $OR. Review PR #$PR (branch $BR). Report only — do not fix code.
Your cwd is a DISPOSABLE checkout of this PR's head, created for you by the harness, on a DETACHED
HEAD: nothing you do in it can move a branch. Stay in it. Do NOT enter the shared checkout
($REPO) — that write is refused, not merely discouraged.
    git fetch origin main --quiet
    gh pr view $PR --repo $OR --json title,body,files
    gh pr diff $PR --repo $OR
Read the changed files IN FULL at the PR head (\`git show origin/$BR:<path>\`), not just the diff hunks. Read skills/code-review/SKILL.md for the discipline.
Report ONLY HIGH-confidence real issues: correctness bugs; security (injection/auth bypass/secrets); VACUOUS tests (would pass on the pre-fix code — prove it); scope/claim mismatch; regressions; fail-open paths; repo-rule violations — especially a NEW test file missing from config/ci-surfaces.yml (the manifest-integrity leg fails and the file is never selected).
DO NOT RUN THE TEST SUITE AND DO NOT PROVISION AN ENVIRONMENT HERE. This checkout is DISPOSABLE and has NO interpreter environment of its own; provisioning one, or searching the filesystem for an existing one, can burn the whole review budget in a single blocking call and the review then ends with no verdict at all (#8602: 35% of reviewer runs hit the 1800s cap, 7/7 in one window). Executing tests is the FIXER's job and CI's job, not yours. To argue a test is VACUOUS, read the test against the PRE-FIX code (\`git show origin/main:<path>\`) and show the assertion cannot tell the two apart. Bound every command; never walk \`\$HOME\` or \`/\`.

## REQUIRED: post your review as a PR comment (this is the merge-gate audit artifact)
Write your review to a file, then:
    gh pr comment $PR --repo $OR --body-file <your-review-file>
Your comment MUST state the outcome plainly and MUST NOT contain an unresolved assertion. Forbidden phrases in a CLEAN comment: "issues remain", "NOT CLEAN", "requires human attention", "auto-fix stalled/failed/reached cap".

## FINAL MESSAGE — exactly one line:
    CLEAN <the comment URL that gh pr comment printed>
  or, if you found real issues:
    ISSUES <n>
Do NOT modify code, commit, or merge.
EOF
}
reviewer_prompt > "$L-reviewer.txt"
# The reviewed refs, sampled immediately before the reviewer starts. `cd` into the sandbox FIRST so
# the agent's cwd is the sandbox — run_agent spawns `pi` without a cwd argument, so it inherits this
# shell's directory.
PRE_REFS="$(ref_shas "$BR")"
cd "$SANDBOX" || { echo "[merge $PR] ABORT: review sandbox $SANDBOX vanished before the reviewer started" >> "$L.log"; exit 6; }
run_agent "${REVIEW_TIMEOUT:-1800}" "$L.log" "$L-reviewer.txt" "reviewer for PR #$PR"
# ── did the reviewed branch move while the reviewer ran? (#8484) ──────────────
# Sampled around the agent. A review marker is HEAD-BOUND, so a CLEAN verdict recorded against a head
# that moved would authorise a merge on a diff nobody reviewed. This is the "make an unexpected ref
# move LOUD" half: it names the mover and refuses to record, instead of absorbing the move; the
# controller re-dispatches on the new head.
POST_REFS="$(ref_shas "$BR")"
if [ "$POST_REFS" != "$PRE_REFS" ]; then
  echo "[merge $PR] ⛔ UNREQUESTED REF MOVE while the reviewer ran: refs/heads/$BR + refs/remotes/origin/$BR were '$PRE_REFS' before it started, now '$POST_REFS'" >> "$L.log"
  # Name the field that ACTUALLY moved (mover_of): a push from the sandbox moves only the
  # remote-tracking ref, so a local-first pick logged the unchanged, already-reviewed head.
  mover_info="$(mover_of "$PRE_REFS" "$POST_REFS" "$BR")"
  moved="${mover_info%% *}"; mover="${mover_info##* }"
  echo "[merge $PR] ⛔ the moved ref is $moved" >> "$L.log"
  [ "$mover" != "-" ] && git -C "$REPO" log --no-walk --format="[merge $PR] mover: author=%an <%ae> committer=%cn <%ce> %h %s" "$mover" >> "$L.log" 2>&1
  echo "[merge $PR] ⛔ NOT recording a verdict — the reviewed head is gone; the controller re-dispatches on the new head" >> "$L.log"
  exit 5
fi
cd "$REPO" || exit 1
# A gate refusal (AGENT_LOAD_REFUSED) means NO agent ran. AGENT_STARTED is authoritative rather than
# the exit code, because `pi` shares the 0–255 status namespace: a pi that exited 75 itself must not
# be read as a refusal (that would skip recording a real verdict). (#1720 advisory)
if [ "$AGENT_STARTED" = "0" ]; then
  # A load refusal is NOT a verdict. Falling through would write `needsfix-<PR>-<head>`, which
  # authorises a fixer for a review that never happened, consumes a MAX_FIX_TRIES attempt and can
  # park the PR. Exit now; the claim is released by the EXIT trap and the controller's next cycle
  # re-dispatches this PR when load has fallen.
  echo "[merge $PR] reviewer NOT started (load gate) — no verdict recorded, none consumed" >> "$L.log"
  exit "$AGENT_LOAD_REFUSED"
fi
LAST="$(grep -aE '^(CLEAN|ISSUES) ' "$L.log" | tail -1 | tr -d '\r')"
echo "[merge $PR] verdict: ${LAST:-<none>}" >> "$L.log"

case "$(verdict_kind "$LAST")" in
  clean)
    URL="$(printf '%s' "$LAST" | grep -oE 'https?://[^ ]+' | head -1)"
    CID="$(printf '%s' "$URL" | grep -oE '[0-9]+$')"
    echo "[merge $PR] evidence comment id=${CID:-?} url=$URL" >> "$L.log"
    if [ -z "${CID:-}" ]; then
      # The reviewer said CLEAN but named no comment, so there is no artifact to sign — the gate can
      # NEVER go green at this head. Park it: the pre-fix bare `exit 2` left no marker, so the loop
      # re-paid for a fresh review every cycle (#1717).
      park "reviewer reported CLEAN but posted no comment URL — no evidence artifact to sign, so ai-review-gate can never go green at this head. The comment usually EXISTS (the reviewer posts it before the verdict): find it on PR #$PR and record it by hand (record-review.sh $PR $HEAD clean $OR --evidence comment:<id>), then: rm -f '$O/state/parked-$PR' '$O/state/parkreason-$PR'"
      echo "[merge $PR] ABORT: no comment id" >> "$L.log"; exit 2
    fi
    # ── 2) record the review (writes the signed marker into the PR body) ──
    "$RECORDER" "$PR" "$HEAD" clean "$OR" --evidence "comment:$CID" >> "$L.log" 2>&1
    rc=$?
    echo "[merge $PR] record-review rc=$rc" >> "$L.log"
    if [ $rc -ne 0 ]; then
      # No signed marker exists, so the gate cannot pass and the PR cannot merge. The pre-fix
      # `exit 3` left no marker at ALL, so the next cycle saw an unmarked FAILED:ai-review-gate and
      # spawned another fresh (paid) review — forever (#1717). Park, and name the failing rc.
      park "record-review.sh failed rc=$rc at head=$HEAD — the signed marker is NOT in the PR body, so the loop would re-pay for a fresh review every cycle. Re-record by hand (record-review.sh $PR $HEAD clean $OR --evidence comment:$CID), then: rm -f '$O/state/parked-$PR' '$O/state/parkreason-$PR'"
      echo "[merge $PR] ABORT: record failed" >> "$L.log"; exit 3
    fi
    # ⛔ `rc=0` IS NOT PROOF THE SIGNED MARKER REACHED THE PR BODY (#1717, fail-open).
    # record-review.sh posts the marker into the PR body BEST-EFFORT and never fails the record, so
    # it has reachable rc=0 paths with NO post at all: the body GET failed ("evidence post skipped;
    # record still saved"), the body PATCH failed ("could not post review evidence … record still
    # saved"), or gh is missing / the repo is undetectable ("the ai-review-gate required check will
    # fail until evidence is posted manually"). Trusting rc=0 there means the gate can NEVER go
    # green, the `gate != SUCCESS` arm below exits 4 WITHOUT a park, and the controller re-spawns a
    # fresh PAID review every cycle — the exact #1717 loop, one state over. So verify the artifact
    # the gate actually reads: the SIGNED marker for THIS head in the PR body. Absence (or an
    # unsigned marker, which the gate also rejects) is the same terminal failure as a non-zero rc.
    # ⛔ AND THE SHAPE IS NOT EVIDENCE EITHER — THE SIGNATURE MUST BE VERIFIED (#784, same class).
    # The PR body is ATTACKER-WRITABLE, so `sig=[0-9a-f]{64}` on its own is satisfied by a forged
    # `sig=<64 hex>` line: this check would read green while no signed marker exists, the gate could
    # never go green at this head, and the `gate != SUCCESS` arm below would exit 4 WITHOUT a park —
    # the #1717 paid loop, reopened by the very artifact the check reads. A PR or an agent can defeat
    # it, which is a category-A bypass by this repo's own A/B test. record-review.sh made exactly
    # this argument for its own carry-forward arm (:1174-1180) and verifies the HMAC over the marker
    # text; this is the SAME computation, duplicated for the reason `cloud-cell-bringup.sh:57` gives
    # for its own duplication — these are cell scripts pushed standalone onto a cell, with no library
    # to source (that citation is deliberate: the rationale is NOT in record-review.sh).
    LIVE_HEAD="$(gh pr view "$PR" --repo "$OR" --json headRefOid --jq .headRefOid 2>/dev/null)"
    # record-review.sh re-binds a carried record to the LIVE head, so the artifact is keyed to the
    # head the gate will judge; fall back to the reviewed head when that read itself fails.
    [ -n "$LIVE_HEAD" ] || LIVE_HEAD="$HEAD"
    BODY="$(gh pr view "$PR" --repo "$OR" --json body --jq .body 2>/dev/null)"
    # The signing KEY is resolved exactly as record-review.sh resolves it (env first, then the key
    # file). An ABSENT key is its OWN terminal cause, not a missing post: with no key the recorder
    # posts an UNSIGNED marker, which the gate also rejects — so the park must say so rather than
    # blame the post.
    MARK_KEY="${AI_REVIEW_GATE_KEY:-}"
    if [ -z "$MARK_KEY" ] && [ -f "$HOME/.pi/agent/.ai-review-gate-key" ]; then
      MARK_KEY="$(cat "$HOME/.pi/agent/.ai-review-gate-key" 2>/dev/null || true)"
    fi
    MARK_KEY="$(printf '%s' "$MARK_KEY" | tr -d '[:space:]')"
    # The pattern is ANCHORED to the WHOLE line, and that is what makes the matched line exactly the
    # text the signer signed: grep returns the ENTIRE line, so an unanchored pattern would return any
    # prefix or suffix around the marker as well and the HMAC would be computed over the wrong string
    # (a false park). The anchors are about the BOUNDARIES OF THE SIGNED TEXT — not about straddling:
    # grep is line-oriented and can never match across two body lines.
    MARK_CAND="$(printf '%s\n' "$BODY" \
      | grep -E "^review recorded: reviews/${PR}[.]json verdict=clean @ ${LIVE_HEAD} .*sig=[0-9a-f]{64}$" || true)"
    # ⛔ EVERY candidate line is verified, and ANY one may satisfy the guard — NOT just the first.
    # record-review.sh APPENDS its marker, so a body can carry an EARLIER shape-matching line for
    # this same head (one signed under a key that has since rotated, or left by a body edit) sitting
    # BEFORE the line that is valid now. First-match-wins would reject the body on that stale line
    # and PARK a head `ai-review-gate` itself reads GREEN: fail-closed, but a stranded merge whose
    # printed remedy (unpark, re-record, retry) parks identically, because the recorder appends
    # rather than replaces. Widening the SEARCH cannot admit a forgery — a forged line simply fails
    # every check — so this restores the pre-hardening width without weakening the property.
    # A pipeline's exit status is the FUNCTION's own status, so this needs no subshell-safe state.
    verify_any_marker() { # verify_any_marker <key> — candidate lines on stdin
      local line txt sig exp
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        # The signer signs the marker text UP TO (excluding) ` sig=`, and `${line% sig=*}` strips
        # from the LAST occurrence — which the `sig=[0-9a-f]{64}$` anchor guarantees is the
        # signature separator. `command openssl` bypasses an exported shell function, exactly as
        # record-review.sh does.
        txt="${line% sig=*}"; sig="${line##* sig=}"
        exp="$(printf '%s' "$txt" | command openssl dgst -sha256 -hmac "$1" 2>/dev/null | awk '{print $NF}' || true)"
        if [ -n "$exp" ] && [ "$sig" = "$exp" ]; then return 0; fi
      done
      return 1
    }
    marker_ok=0; marker_why=""; marker_how=""
    # ⛔ THE KEY AND THE TOOL ARE CHECKED BEFORE THE CANDIDATE LIST, because on the box this park is
    # for they are what is actually broken. With no key, or with no openssl, the local recorder
    # cannot SIGN — record-review.sh posts an UNSIGNED marker (no `sig=` at all) and exits 0 — so the
    # anchored pattern finds NOTHING, and a candidate-first order would report that absence as a
    # failed EVIDENCE POST. That names the wrong cause and prescribes a remedy that cannot work.
    # ⛔ AND EACH ARM CARRIES ITS OWN REMEDY (`marker_how`), for the same reason. The recorder
    # resolves the key and the tool exactly as this worker does, so "record it by hand" cannot fix
    # either of the first two arms — it re-posts an unsigned marker from the same box and parks
    # identically. `parkreason-<PR>` is the only remedy a human sees in-band.
    if [ -z "$MARK_KEY" ]; then
      marker_why="NO AI_REVIEW_GATE_KEY is available here (env or \$HOME/.pi/agent/.ai-review-gate-key), so no marker on this PR body can be verified — and the recorder on this box could not have signed one either, because an unsigned marker is one ai-review-gate rejects"
      marker_how="Provision the key for the WORKER's environment (a cell sources keys.env with 'set -a', so check it survives into the tmux environment the worker runs in), then: rm -f '$O/state/parked-$PR' '$O/state/parkreason-$PR'"
    elif ! command -v openssl >/dev/null 2>&1; then
      # The recorder signs with the same `command openssl`, so on this box the marker is unsigned
      # (or was signed on ANOTHER box); either way THIS box cannot verify it.
      marker_why="openssl IS NOT INSTALLED on this box, so the recorder here could not have signed a marker and no marker on this PR body can be verified"
      marker_how="Install openssl (a hard dependency of this path — the recorder signs with it and this worker verifies with it), then: rm -f '$O/state/parked-$PR' '$O/state/parkreason-$PR'"
    elif [ -z "$MARK_CAND" ]; then
      marker_why="NO signed marker for head=$LIVE_HEAD is in the PR body"
      marker_how="the recorder's evidence post is best-effort and skips silently when the body read or PATCH fails, or gh/repo is unavailable, so ai-review-gate can never go green at this head and the loop would re-pay for a fresh review every cycle. If the reviewer's comment exists, record it by hand (record-review.sh $PR $HEAD clean $OR --evidence comment:$CID), then: rm -f '$O/state/parked-$PR' '$O/state/parkreason-$PR'"
    elif printf '%s\n' "$MARK_CAND" | verify_any_marker "$MARK_KEY"; then
      marker_ok=1
    else
      marker_why="NO marker for head=$LIVE_HEAD in the PR body VERIFIES against its signature — the PR body is not a trust boundary, so a forged, re-keyed or unsigned line is NOT evidence (#784)"
      marker_how="re-record the review at this head so a freshly signed marker is appended (record-review.sh $PR $HEAD clean $OR --evidence comment:$CID), then: rm -f '$O/state/parked-$PR' '$O/state/parkreason-$PR'"
    fi
    if [ "$marker_ok" -ne 1 ]; then
      park "record-review.sh returned rc=0, but the signed marker ai-review-gate reads is not verifiably there: $marker_why — $marker_how"
      echo "[merge $PR] ABORT: rc=0 but $marker_why" >> "$L.log"; exit 3
    fi
    # ── 3) wait for the REPO'S review gate to go green (read the LATEST check row) ──
    # Reached only in `gate` mode, so this repo DOES require the gate. The NAME is an input
    # (agent-infra#1764): it was the literal `ai-review-gate`, which is tortoise's name. The jq
    # filter previously hardcoded it inside a single-quoted expression; gh's --jq takes no --arg,
    # so the name travels via the environment and is selected in python (never spliced into a jq
    # program, where a name containing a quote would change the program).
    gate=""
    for i in $(seq 1 30); do
      gate="$(gh pr checks "$PR" --repo "$OR" --json name,state 2>/dev/null | GATE_NAME="$REVIEW_GATE" python3 -c "
import sys,json,os
n=os.environ.get('GATE_NAME') or 'ai-review-gate'
try: d=json.load(sys.stdin)
except Exception: raise SystemExit
rows=d if isinstance(d,list) else (d.get('check_runs') or [])
for c in rows:
    if isinstance(c,dict) and str(c.get('name') or '')==n:
        print(str(c.get('state') or '').upper()); break
" 2>/dev/null)"
      echo "[merge $PR] gate=$gate (try $i)" >> "$L.log"
      [ "$gate" = "SUCCESS" ] && break
      sleep 30
    done
    # ⛔ NOT parked, deliberately (verified by reading the controller, not assumed): the signed
    # marker IS in the PR body by here (the check above proved it, rather than trusting rc=0), so
    # this head can still merge. A park would make the loop's
    # top-of-cycle parked guard `continue` past a PR whose gate turns green a minute later — a
    # stranded merge, strictly worse than the cost of the retry. A record failure cannot be
    # stranded, which is why THAT is parked.
    if [ "$gate" != "SUCCESS" ]; then echo "[merge $PR] ABORT: gate=$gate (not green)" >> "$L.log"; exit 4; fi
    # ── 4) merge ──
    if gh pr merge "$PR" --repo "$OR" --squash >> "$L.log" 2>&1; then
      echo "[merge $PR] MERGED $(date)" >> "$L.log"
      touch "$O/state/merged-$PR.done"
    else
      echo "[merge $PR] merge command failed" >> "$L.log"
    fi
    ;;
  issues)
    # The reviewer found real issues at this exact head. Leave a marker so the loop knows to
    # spawn a FIXER (not another re-record) on its next cycle.
    echo "[merge $PR] ISSUES at head=$HEAD — needs a fixer" >> "$L.log"
    apply_verdict_marker issues "$HEAD" >/dev/null
    ;;
  *)
    # ⛔ A VERDICT-LESS RUN IS NOT A VERDICT (#8602, agent-infra#1741). An empty LAST means the
    # reviewer produced no `CLEAN`/`ISSUES` line — it timed out, crashed, or was killed at the
    # wall limit. Writing `needsfix` for it authorises a fixer for a review that never happened,
    # spends one of MAX_FIX_TRIES on it, and ends by parking the PR "needs a human" with the
    # reviewer's findings never addressed. Report the stall AS a stall (the `[timeout]` line
    # run_agent wrote above carries the wall limit and rc) and leave NO marker: the loop's next
    # cycle re-records — a fresh review at this head — instead of inventing a fixer task.
    echo "[merge $PR] NO VERDICT (no CLEAN/ISSUES line — reviewer stalled or failed) at head=$HEAD; NOT authorising a fixer" >> "$L.log"
    ;;
esac
echo "[merge $PR] end $(date)" >> "$L.log"
