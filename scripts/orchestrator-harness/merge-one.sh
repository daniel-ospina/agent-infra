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
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
export AGENT_SKIP_REVIEW_GATE=1 ELDATO_SKIP_VGATE=1 AGENT_ALLOW_MAIN_EDITS=1 ELDATO_ALLOW_MAIN_EDITS=1
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

# Portable wall-clock timeout for the agent invocation. `pi -p` has no internal limit, so one hung
# model call holds a concurrency slot forever — and the caps count SESSIONS, so a single hang
# silently halves throughput. macOS ships no `timeout`/`gtimeout`, so implement it in bash: run the
# agent in the background with a watchdog subshell that kills it after N seconds. The stale-worker
# reaper in orch-loop.sh is the second line of defence.
run_agent() { # run_agent <seconds> <logfile> <promptfile>
  local t="$1" log="$2" prompt="$3" pid w rc start elapsed
  start="$(date +%s)"
  pi -p --provider deepseek --model deepseek-v4-flash --no-session "$(cat "$prompt")" >> "$log" 2>&1 &
  pid=$!
  ( sleep "$t"; kill -TERM "$pid" 2>/dev/null; sleep 15; kill -KILL "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  w=$!
  wait "$pid" 2>/dev/null; rc=$?
  kill "$w" 2>/dev/null
  # agent-infra#1709 item 3: wall_limit is the CAP, not the cost. elapsed is the measured
  # reviewer wall-time — the load-bearing number for fleet capacity (it was unmeasured).
  elapsed=$(( $(date +%s) - start ))
  echo "[timeout] agent pid=$pid wall_limit=${t}s elapsed=${elapsed}s rc=$rc" >> "$log"
  # DURABLE time series (agent-infra#1709 item 3). The per-run log above is TRUNCATED whenever
  # the same PR is re-run (`> "$L.log"`), so a single log line erases its own history: measured,
  # three real reviewer samples (885s/963s/1142s) disappeared within minutes. #1709 needs a DAY
  # of data, which is only possible append-only. Tab-separated, one row per agent invocation.
  mkdir -p "$O/state"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "${KIND:-agent}" "${TAG:-}" "$t" "$elapsed" "$rc" >> "$O/state/walltime.tsv"
  return "$rc"
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
trap 'rm -f "$CLAIM"' EXIT

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
trap 'release_claim_bounded; rm -f "$CLAIM"' EXIT

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

# record_at_head — true iff the LOCAL review store already holds a record for this PR at this head.
#
# The store (`~/.pi/agent/reviews/`, written by record-review.sh, read by
# extensions/review-enforcer) is the one head-bound artifact this box owns that the PR itself
# cannot rewrite — a record is a FILE with a `head_sha`, not prose in a body. Rail mode uses it to
# decide whether evidence has to be minted before the rail may run (agent-infra#1825).
#
# ⛔ CHECK EVERY CANDIDATE, NOT THE FIRST THAT EXISTS. The producer writes a REPO-QUALIFIED file
# (`<owner>-<repo>-<pr>.json`) and keeps the legacy `<pr>.json` until a qualified record for the
# same repo migrates it; reading only the first existing name would let a stale legacy record
# beside a fresh qualified one read as "no evidence" (the trap atomic-land.sh's carry guard
# documents). A record whose head cannot be read is NOT evidence — it simply fails to match.
record_at_head() {
  local dir="$HOME/.pi/agent/reviews" f sha
  [ -n "${OR:-}" ] && [ -n "${PR:-}" ] && [ -n "${HEAD:-}" ] || return 1
  for f in "$dir/${OR%/*}-${OR#*/}-$PR.json" "$dir/$PR.json"; do
    [ -f "$f" ] || continue
    sha="$(sed -n 's/.*"head_sha":"\([^"]*\)".*/\1/p' "$f" 2>/dev/null | command head -1)"
    [ -n "$sha" ] && [ "$sha" = "$HEAD" ] && return 0
  done
  return 1
}

# rail_attempt — hand this PR to the repo's OWN rail, with a retry budget keyed on the HEAD.
#
# A rail refusal is head-specific (it blocks on THIS tree), so a later push re-arms it; the SAME
# head is retried at most RAIL_TRIES times so a permanently blocked PR is not re-analysed every
# cycle — the API burn #1764 reports. At the cap the head is PARKED, which the sweep already
# honours (`parked-$PR` == the current head).
# ⚠️ review round 5 — P1: `RAIL_TRIES` must be DEFAULTED, not merely tested. The guard below
# only assigns it in the INVALID branch, so with the variable unset (the production default:
# nothing in install.sh, the launchd plist, the README or a cell keys.env sets it) the cap
# comparison expanded it bare under `set -u` and the worker died `unbound variable` BEFORE
# `bash "$RAIL"` was ever reached — rail mode was dead on arrival, no agent-infra PR could
# drain, the retry cap could never park, and the sweep re-spawned a worker every cycle. That
# is #1764's own deadlock, reintroduced on the new path. The default is assigned HERE so every
# later expansion is safe.
# ⛔ `exit`, not `return`, is deliberate: every caller's NEXT act is to end the worker, and the
# pre-refactor code exited on exactly these paths. A `return` would let a caller fall through to
# the review path AFTER the rail was invoked, paying for a review of a head that already merged.
rail_attempt() {
  RAIL_TRIES="${RAIL_TRIES:-3}"
  if ! is_limit "$RAIL_TRIES"; then
    echo "[merge $PR] RAIL_TRIES='$RAIL_TRIES' is not an integer in range — using 3" >> "$L.log"
    RAIL_TRIES=3
  fi
  local RC_F="$O/state/railcount-$PR" RC_H="" RC_N=0
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
}

if [ "$MERGE_AUTHORITY" = "rail" ]; then
  # RAIL MODE — the rail is the MERGE authority, and since agent-infra#1825 it is no longer an
  # excuse to skip the REVIEW authority.
  #
  # ⛔ THE SKIP USED TO REST ON A FALSE PREMISE, and the premise is quoted here so it cannot be
  # reinstated as if it were reasoning: "a review comment / signed record marker is the TORTOISE
  # contract and is consumed by nothing on this repo, so minting one would only edit a PR body for
  # no gate". Something on this repo consumes it: `pipeline-compliance` check (c) — the ONLY
  # required check here — reads exactly that record marker, bound to this PR at this head. So on
  # the skip, every agent-infra PR reached that required check with NO artifact and could only go
  # green by TYPING a phrase into the body (the defect #1825 files), which is why lanes reported
  # the process as "simultaneously satisfiable by prose and never satisfiable by the harness that
  # owns the dispatch".
  #
  # The rule now:
  #   * evidence ALREADY at this head (a head-bound record in the store) → go straight to the rail.
  #     Unchanged behaviour and no second review: this is the normal case, because the lane's own
  #     review pass records one.
  #   * NO evidence at this head → do NOT merge blind. Fall through to the review path below and
  #     hand the merge back to the rail at step 4, so a rail repo gets the same head-bound
  #     evidence a gate repo gets.
  # ⛔ A MISSING RAIL REFUSES. It never degrades to `gh pr merge`: that is the bypass this branch
  # exists to prevent, and a silent downgrade is exactly how a guard becomes decorative.
  RAIL="$REPO/scripts/admin-merge.sh"
  if [ ! -f "$RAIL" ]; then
    echo "[merge $PR] REFUSED: merge authority for $OR is its rail, but $RAIL does not exist — refusing to fall back to a raw gh pr merge (agent-infra#1764)" >> "$L.log"
    exit 6
  fi
  # ⛔ REFUSE ON AN EMPTY HEAD (review round 6, P2). The retry budget is HEAD-KEYED, so without a
  # head it cannot be kept: `printf '%s %s' "" "$RC_N"` writes " 1", `read -r RC_H RC_N` strips the
  # leading blank (RC_H=1, RC_N=""), `is_limit ""` fails and RC_N resets to 0 on EVERY pass — the
  # cap is unreachable, no park is ever written, and the sweep re-runs the rail every cycle: the
  # per-cycle API burn RAIL_TRIES exists to close. A transient head-read failure is retried next
  # cycle, which is the fail-closed direction. Checked BEFORE the evidence test: evidence is keyed
  # on the head too, so without one there is nothing to look up.
  if [ -z "${HEAD:-}" ]; then
    echo "[merge $PR] REFUSED: the PR head could not be read (empty) — a head-keyed retry budget cannot be kept without it, and an un-keyed rail retry is the per-cycle API burn RAIL_TRIES exists to close" >> "$L.log"
    exit 7
  fi
  if record_at_head; then
    rail_attempt
  fi
  # NO EVIDENCE AT THIS HEAD (agent-infra#1825): fall through to the review path below, which posts
  # the review comment, records the verdict at this head and re-triggers `pipeline-compliance` via
  # the body edit — and then hands the merge back to the rail at step 4. MERGE_VIA is what step 4
  # reads; it is set here and nowhere else, so a gate repo can never reach the rail by accident.
  echo "[merge $PR] rail mode: NO head-bound review record at head=$HEAD — running the review path so the required check (c) has an artifact, then handing the merge to the rail (agent-infra#1825)" >> "$L.log"
  MERGE_VIA=rail
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

# ── 1) fresh-context review, POSTED as a PR comment (the audit artifact) ──────
# ⛔ agent-infra-SPECIFIC, and NOT in the tortoise original: the NO-SEARCH bound inside this prompt.
# The reviewer's cwd is the MAIN checkout, which has no `.venv`, so a prompt that only says "run
# .venv/bin/python" sends the agent hunting for an interpreter — and a `find` over $HOME blocks for
# minutes (measured >120s cold, ~25 min under load), burning the whole 30-minute budget with NO
# verdict (measured incidence: 43 of 124 reviewer runs ended at the cap, and 7 of 7 cap-hits in one
# window produced nothing). Tortoise #8484/#8589 gives the reviewer its own DETACHED checkout and
# removes the cause; that commit is NOT ported here yet. Until it is, this bound is what protects the
# box, and it stays as defence in depth afterwards — do NOT drop it in a re-port from tortoise.
cat > "$L-reviewer.txt" <<EOF
You are a FRESH-CONTEXT code reviewer for $OR. Review PR #$PR (branch $BR). Report only — do not fix code.
    cd $REPO && git fetch origin main --quiet
    gh pr view $PR --repo $OR --json title,body,files
    gh pr diff $PR --repo $OR
Read the changed files IN FULL at the PR head (\`git show origin/$BR:<path>\`), not just the diff hunks. Read skills/code-review/SKILL.md for the discipline.
Report ONLY HIGH-confidence real issues: correctness bugs; security (injection/auth bypass/secrets); VACUOUS tests (would pass on the pre-fix code — prove it); scope/claim mismatch; regressions; fail-open paths; repo-rule violations — especially a NEW test file missing from config/ci-surfaces.yml (the manifest-integrity leg fails and the file is never selected).
TEST EXECUTION IS NOT AVAILABLE TO YOU. Your cwd is the main checkout and it has NO \`.venv\`. Do NOT go looking for an interpreter:
  ⛔ NEVER run \`find\`, \`rg\`, \`du\`, \`mdfind\` or a recursive \`ls\` outside the repository root — above all never under \`$HOME\`, \`/Users\`, \`/private/tmp\`. A \`find\` over the home directory BLOCKS for many minutes (measured: >120s cold, ~25 min under load) and has burned entire 30-minute review budgets, returning NO verdict at all.
  ⛔ Do not run \`uv sync\`, and do not create a virtualenv.
If a point can only be settled by EXECUTING code, report it as \`UNVERIFIED\` and name the exact command that would settle it — the fixer runs tests, not you. Reasoning from the source is expected and is sufficient for everything else.
Bound every command: explicit paths, \`-maxdepth\`, and never run the whole suite.

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
run_agent "${REVIEW_TIMEOUT:-1800}" "$L.log" "$L-reviewer.txt"
LAST="$(grep -aE '^(CLEAN|ISSUES) ' "$L.log" | tail -1 | tr -d '\r')"
echo "[merge $PR] verdict: ${LAST:-<none>}" >> "$L.log"

case "$LAST" in
  CLEAN*)
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
    # ── 3a) RAIL MODE: there is no review gate to wait for (agent-infra#1825) ──
    # This repo's merge authority is its rail, which is WHY we dropped out of the rail branch to
    # mint the evidence: polling `$REVIEW_GATE` here would wait 15 minutes for a check that does
    # not exist on this repo and then abort at exit 4 for a head whose evidence is now in place.
    # The rail asserts safety itself — it re-reads the head's WHOLE check surface, including the
    # `pipeline-compliance` run the record's body edit just re-triggered — and refuses on a
    # genuine failure, which is the same guarantee a gate wait would give, plus the rail's tree
    # analysis. So hand over without the wait.
    if [ "${MERGE_VIA:-gate}" = "rail" ]; then
      echo "[merge $PR] evidence minted at head=$HEAD — handing the merge to the rail rather than waiting on a review gate this repo does not require (agent-infra#1825)" >> "$L.log"
      rail_attempt
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
    # ⛔ UNREACHABLE IN RAIL MODE, BY CONSTRUCTION. Rail mode leaves step 3a via rail_attempt,
    # which exits — so a raw `gh pr merge` cannot land a rail repo's PR on its required checks
    # alone (the #1764 bypass). The guard below is the belt to that brace: it turns a future
    # edit that returns from rail_attempt instead of exiting into a loud abort rather than a
    # silent downgrade of the merge authority.
    if [ "${MERGE_VIA:-gate}" = "rail" ]; then
      echo "[merge $PR] ABORT: rail mode reached the raw merge step — the merge authority must not be downgraded to gh pr merge (agent-infra#1825/#1764)" >> "$L.log"
      exit 8
    fi
    if gh pr merge "$PR" --repo "$OR" --squash >> "$L.log" 2>&1; then
      echo "[merge $PR] MERGED $(date)" >> "$L.log"
      touch "$O/state/merged-$PR.done"
    else
      echo "[merge $PR] merge command failed" >> "$L.log"
    fi
    ;;
  *)
    # The reviewer found real issues (or the reviewer failed) at this exact head. Leave a
    # marker so the loop knows to spawn a FIXER (not another re-record) on its next cycle.
    echo "[merge $PR] NOT CLEAN or reviewer failed — needs a fixer at head=$HEAD" >> "$L.log"
    [ -n "${HEAD:-}" ] && touch "$O/state/needsfix-$PR-$HEAD"
    ;;
esac
echo "[merge $PR] end $(date)" >> "$L.log"
