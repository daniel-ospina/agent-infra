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
# ⛔ EXPORTED for the same reason as lane.sh: the SPAWN POINT is a child process (#1884).
KIND=reviewer; TAG="$PR"; export KIND TAG
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
O="${O:-$HOME/orchestrator}"; mkdir -p "$O/logs" "$O/state"
L="$O/logs/merge-$PR"
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
# ⛔ THE gh SHIM MUST STAY FIRST (#1988). The line above prepends the tool dirs, so a REAL gh in
# either of them outranks the seeded `$O/gh-rest` (Mac REST adapter) / `$O/gh-limit` (cell
# serialiser) — and a shim that is never resolved is an INERT layer: it reports protection and
# provides none. Re-assert both here, adapter last so `$O/gh-rest` (which itself calls the same
# helper) wins where it exists. Guarded by `-d`, so a box that ships neither is unchanged.
if [ -d "$O/gh-limit" ]; then PATH="$O/gh-limit:$PATH"; fi
if [ -d "$O/gh-rest" ]; then PATH="$O/gh-rest:$PATH"; fi
# ── THE GATE DECISION IS MEASURED, NOT ASSUMED (agent-infra#2319) — see lane.sh for the full note.
# ⛔ A REVIEWER STILL NEEDS THE GATES OFF? No: the reviewer is the thing that SATISFIES them. It
# commits nothing and merges through `admin-merge.sh` (a shell rail that reads the head-bound record),
# so it does not need — and must not silently inherit — a permanent bypass.
. "$SELF/gate-policy.sh" 2>/dev/null || { echo "[merge $PR] FATAL: $SELF/gate-policy.sh missing — refusing to run a lander that cannot say whether its gates are on" >&2; exit 78; }
apply_gate_policy merge-one
# ⛔ A DIFFERENT HATCH, DELIBERATELY UNTOUCHED: main-edits is a declared escape for writing to a main
# checkout, not a review bypass, and #2319 does not rule on it.
export AGENT_ALLOW_MAIN_EDITS=1 ELDATO_ALLOW_MAIN_EDITS=1
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
# ── AGENT_GH_REAL: pin the ONE real gh this box resolves (agent-infra#2320) ──────────────────────
# This worker is about to make the read the whole merge contract rests on. MEASURED 2026-10-22: the
# wrapper chain resolved to ITSELF on the owner's Mac, every gh call returned EMPTY, protection read
# UNREADABLE and THIS script refused every merge (exit 5) while the reported cause pointed at
# permissions. A pin exported here — per box, DISCOVERED from PATH, never a hardcoded home — is what
# stops the chain re-forming. Best-effort: if it cannot be pinned the read below still fails closed,
# and `bin/harness status` names it. ⛔ Interface-guarded so a pre-#2320 `$O` copy is a no-op rather
# than a 127 in the merge log.
if command -v ensure_agent_gh_real >/dev/null 2>&1; then ensure_agent_gh_real || true; fi

# ── the rail-refusal RECORD (the controller's red-fixer role reads it) ──────────
# Sourced from the SAME two homes as every other shared module here (`$O` is what the daemon
# executes; the directory is the fallback for a box whose $O predates this change). NOT fatal when
# missing: this file's job is to merge, and refusing to merge because the RECORD of a refusal cannot
# be written would turn a new observability path into an outage. The refusal path says so loudly
# instead (see the [railrefusal] block) — a silent degrade is the failure mode that matters here.
if [ -f "$O/rail-refusal.sh" ]; then . "$O/rail-refusal.sh"
elif [ -f "$_M1_HERE/rail-refusal.sh" ]; then . "$_M1_HERE/rail-refusal.sh"
else echo "[merge $PR] ⚠️ rail-refusal.sh not found (looked in $O and ${_M1_HERE:-<unresolved>}) — a rail refusal will NOT be recorded, so no red-fixer can be spawned from it" >> "$L.log"; fi
command -v rail_refusal_record >/dev/null 2>&1 || echo "[merge $PR] ⚠️ rail-refusal.sh is stale/partial (no rail_refusal_record) — a rail refusal will NOT be recorded" >> "$L.log"

# ── the RESEARCH contract for the reviewer's brief (#2258) ───────────────────────────────────────
# This file carries its OWN `run_agent` (see its header), so it also carries its own gate — the SAME
# validator, resolved from the SAME two homes as every other shared module here (`$O` is what the
# daemon executes; the directory is the fallback for a box whose $O predates this change). The rules
# are NOT re-implemented here: this is one `bash brief-gate.sh` call, and the section it splices is
# the same canonical text every other caller splices.
#
# ⛔ WHY THE REVIEWER NEEDS IT TOO, even though a review looks like the opposite of a research pass:
# both measured defects would have passed a reviewer that only checked the diff. A reviewer told to
# judge a change against a PREMISE, without first reading the tracker's record of that premise,
# approves a well-formed diff of the wrong work. The CONTRADICTION TEST line is the same question the
# adoption rule already asks, asked at the one moment the answer is still cheap.
brief_gate_sh=""
for _bg in "$O/brief-gate.sh" "$_M1_HERE/brief-gate.sh" "${AGENT_INFRA_PATH:-}/scripts/orchestrator-harness/brief-gate.sh" "${HOME:-}/.pi/agent/scripts/brief-gate.sh"; do
  [ -n "$_bg" ] && [ -f "$_bg" ] && { brief_gate_sh="$_bg"; break; }
done
if [ -z "$brief_gate_sh" ]; then
  echo "[merge $PR] FATAL: brief-gate.sh not found (looked in $O, ${_M1_HERE:-<unresolved>}, \$AGENT_INFRA_PATH/scripts/orchestrator-harness, ~/.pi/agent/scripts) — refusing to pay for a review whose brief nothing validated (#2258)" >> "$L.log"
  echo "[merge $PR] FATAL: brief-gate.sh missing — no reviewer started" >&2
  exit 78
fi
REVIEW_RESEARCH_BRIEF="$(bash "$brief_gate_sh" --section reviewer)" || {
  echo "[merge $PR] FATAL: brief-gate.sh --section reviewer failed — refusing to pay for a review whose brief omits the research contract (#2258)" >> "$L.log"
  exit 78; }

# Portable wall-clock timeout for the agent invocation. `pi -p` has no internal limit, so one hung
# model call holds a concurrency slot forever — and the caps count SESSIONS, so a single hang
# silently halves throughput. macOS ships no `timeout`/`gtimeout`, so implement it in bash: run the
# agent in the background with a watchdog subshell that kills it after N seconds. The stale-worker
# reaper in orch-loop.sh is the second line of defence.
run_agent() { # run_agent <seconds> <logfile> <promptfile>
  local t="$1" log="$2" prompt="$3" pid w rc start elapsed bgrc
  AGENT_STARTED=0
  # ── THE BRIEF GATE (#2258), first and fail-closed, for the reason spawn-gate.sh gives: a brief
  # refusal is DETERMINISTIC (it will not clear by waiting, and it follows the item to any box), so
  # reporting it after a load/disk reading would send the operator to fix the wrong thing. This file
  # has no load gate of its own (the installed `pi` shim is its load gate), so this is the one gate
  # it owns — and it is the only gate on the FIRST-REVIEW path for every own-lane PR.
  bash "$brief_gate_sh" --check "$prompt" reviewer >> "$log" 2>&1
  bgrc=$?
  if [ "$bgrc" != 0 ]; then
    AGENT_STARTED=0
    echo "[brief-gate] REFUSED reviewer for PR #$PR: the brief was not admitted (exit $bgrc) — no reviewer started, nothing consumed, NO verdict and NO needsfix marker. The brief is GENERATED here, so this is a HARNESS defect, not a capacity refusal." >> "$log"
    return "$bgrc"
  fi
  # `AGENT_STARTED` is the harness's authoritative "an agent ran" flag (spawn-gate.sh sets it for the
  # same reason): a caller must be able to tell a refusal apart from a reviewer that ran and produced
  # nothing, and `pi` shares the 0-255 status namespace with the gate codes.
  AGENT_STARTED=1
  start="$(date +%s)"
  # ⛔ THE SAME RESOLVED MODEL AS spawn-gate.sh's `run_agent` (agent-infra#2208, review P1). This is a
  # SECOND `run_agent` — the `chain-<N>` first-review spawn for every own-lane PR, i.e. the highest-
  # volume model call the harness makes — and it carried the hardcoded `deepseek-v4-flash` the
  # sibling was fixed for. Fixing one and not the other leaves the defect exactly where it costs
  # most, and `spawn-gate.test.sh` already treats both files as one population
  # (`EXPECTED_PI="merge-one.sh spawn-gate.sh"`), so the divergence was invisible to the suite.
  # Keep the two defaults IDENTICAL: a lane must not run a different model than its reviewer.
  local lane_provider="${PI_LANE_PROVIDER:-deepseek}" lane_model="${PI_LANE_MODEL:-deepseek-flash}"
  echo "[agent] provider=$lane_provider model=$lane_model" >> "$log"
  pi -p --provider "$lane_provider" --model "$lane_model" --no-session "$(cat "$prompt")" >> "$log" 2>&1 &
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

# ── cross-box claim (agent-infra#1709 recs 1-3), TWO KEYS (agent-infra#1952) ───
# The noclobber lock above is atomic on ONE box only: three boxes driving this repo are three
# independent filesystems, so it stops nothing between them. The boxes share exactly one
# durable store — the repository — and creating a ref with `git push` is an atomic CAS.
#
# ⛔ TWO REFS, BECAUSE THEY ANSWER TWO QUESTIONS, AND THE LANDING QUESTION IS THE ONE THAT CANNOT
# BE ANSWERED BY THE HEAD. `refs/claims/<PR>-<sha12>` (below) says "another box is working THIS
# HEAD" — the right question for a review, which a pushed update legitimately re-opens. It cannot
# say "another box is landing THIS PR": two boxes that see one PR at two different heads mint two
# distinct keys, each wins its own CAS, and both proceed (agent-infra#1908 measured exactly that as
# row M3). Landing a merge is the ONE operation in #1908's per-operation table that does not
# tolerate at-least-once — a second attempt lands on a MOVED head with evidence bound to the old
# one — so the landing path takes `refs/claims/pr-<N>` FIRST and the per-head claim SECOND. The
# order is fixed so the two locks are totally ordered and cannot be taken in opposite orders by two
# boxes; both are CAS refusals, never blocking waits, so the worst case is one lost cycle.
#
# FAIL-OPEN, ON PURPOSE. If the claim store is unreachable (network blip, a rejected push for
# an unrelated reason) we proceed and SAY SO in the log. #1709's headline finding is that
# no mechanism guarantees two machines never run the same job, so the design must tolerate
# duplicates: every side effect on this path is idempotent per head (one evidence comment, a
# record-review marker keyed on $HEAD, and `gh pr merge` twice is a no-op). Failing CLOSED
# would stall the whole fleet on one transient error — the strictly worse failure. The log
# line makes the fallback visible rather than silent.
# ⛔ The SAME policy governs the landing key, and it costs more there: a fail-open landing claim
# leaves exactly the per-head-only guarantee this change is about, and the log line is the only
# evidence of it. Consistency is chosen deliberately — a landing claim that failed CLOSED would
# stall one PR on every network blip, and `merge-one.sh` already refuses (`exit 5/6/7`) on the
# contract failures that make a landing unsafe, none of which are network blips.
CROSS_OWN=""
CROSS_RC=0
PR_OWN=""
PR_RC=0

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

# release_pr_claim_bounded — the SAME bounded release for the LANDING claim (#1952).
# ⛔ TWO BOUNDED RELEASES ON THE EXIT PATH DOUBLES THE WORST CASE TO ~40s, and that is still the
# right trade: both bounds exist to stop a black-holed `git push` holding the process open (and, on
# a chain ingress, the controller waiting on it), and a release that is TERM'd only leaves a claim
# that expires on its own lease — the accepted direction, since every holder here fails SAFE by
# expiring rather than by deleting a peer's ref. Collapsing the two into one concurrent pair would
# save 20s and make the two releases race each other on one connection; not worth the new failure
# mode.
release_pr_claim_bounded() {
  local p w rc
  # ⛔ FALL BACK TO CLAIM_COMMIT, AND ONLY WHILE THE LANDING ATTEMPT IS UNCLASSIFIED (P2,
  # 2026-10-17 review). `PR_OWN` is assigned immediately after `claim_pr_acquire` returns, so a TERM or
  # INT delivered between the successful CAS push and that assignment left PR_OWN empty — and the
  # widened EXIT trap then no-opped, stranding `pr-<N>` on the REMOTE for the whole lease and making
  # the PR unlandable fleet-wide. claims.sh's contract is precisely that `CLAIM_COMMIT` means "the
  # commit THIS attempt may have pushed" (it is cleared at the top of `_claim_acquire_at`), which is
  # exactly the value a release needs; `--force-with-lease` still fences the push on that sha, so a
  # wrong value is a refusal, never a peer's ref removed.
  # ⛔ BUT ONLY IN THAT WINDOW, which is what `PR_RESOLVED` marks: once the landing `case` arms have
  # run, `PR_OWN` is AUTHORITATIVE, and the HEAD claim runs after them — so an ungated fallback would
  # read a HEAD commit as the landing release fence in the one state where the landing attempt was
  # classified as unowned (rc=2, nothing pushed). The release is then doomed (the lease names a commit
  # belonging to another ref, so `--force-with-lease` refuses), the log line names the WRONG claim,
  # and the operator chasing it is sent to the head ref — the same class of defect as the P2 that
  # added the fallback. Gated, a classified landing attempt releases exactly what it owns and nothing
  # else.
  if [ -z "${PR_OWN:-}" ] && [ "${PR_RESOLVED:-0}" = 0 ]; then PR_OWN="${CLAIM_COMMIT:-}"; fi
  [ -n "${PR_OWN:-}" ] || return 1
  claim_pr_release "$REPO" "$PR" "$PR_OWN" >/dev/null 2>&1 &
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

if [ -f "$O/claims.sh" ]; then
  # shellcheck source=/dev/null
  . "$O/claims.sh"
  # The lease must OUTLIVE a worst-case review, or another box takes over mid-review and we get
  # the duplicate work this exists to prevent: REVIEW_TIMEOUT (default 1800) + the gate wait
  # below (GATE_POLL_TRIES x GATE_POLL_SECS = 30 x 30s = 900 by default) + the merge itself. Derived, not a bare constant — and passed explicitly,
  # because sourcing claims.sh above sets CLAIM_TTL=1800 and would silently win over a default.
  # Overflow-safe by construction: the guard above leaves REVIEW_TIMEOUT <= 999999999, so this sum
  # is < 2**31. claims.sh clamps the ttl a second time at its own arithmetic site, so a future caller
  # that skips this guard still cannot mint a lease the reader is unable to parse.
  # ⛔ SIZED FROM THE EFFECTIVE WAIT, NOT THE DEFAULT (review round 7 P2-3). The wait is a first-class
  # tunable (`GATE_POLL_TRIES` x `GATE_POLL_SECS`), so a box running `GATE_POLL_SECS=60` has a 3600 s
  # worst case — longer than the old fixed 3000 s lease, which would then expire mid-wait and let
  # another box acquire the PR and run a DUPLICATE paid review (#1908, the duplicate this lease exists
  # to prevent). Defaults are unchanged: 1800 + (30 x 30) + 300 = 3000.
  # ⛔ `is_limit`, NOT A `case ''|*[!0-9]*` GUARD: that idiom (this file's own header names it) ACCEPTS
  # a leading zero, and `$(( 08 * 30 ))` is an invalid octal — on bash 5 the assignment aborts the
  # shell before CLAIM_LEASE exists (worker dead before the claim and before step 3); on bash 3.2 the
  # failed assignment aborts the enclosing `if` body and resumes with status 0, silently skipping the
  # cross-box claim. That is the P1 class `test-crossbox.sh` 4b/4c protects for REVIEW_TIMEOUT — and
  # this face of it is new, so it is coerced the same way step 3 coerces: to the default.
  if is_limit "${GATE_POLL_TRIES:-30}" && is_limit "${GATE_POLL_SECS:-30}"; then
    _gw=$(( ${GATE_POLL_TRIES:-30} * ${GATE_POLL_SECS:-30} ))
  else
    _gw=900
  fi
  [ "$_gw" -ge 900 ] || _gw=900
  [ "$_gw" -le 86400 ] || _gw=86400
  CLAIM_LEASE=$(( ${REVIEW_TIMEOUT:-1800} + _gw + 300 ))

  # ── the LANDING claim, FIRST (agent-infra#1952) ───────────────────────────────
  # ⛔ THIS IS THE FENCE THE HEAD KEY CANNOT PROVIDE. `claim_acquire` below is content-addressed on
  # $HEAD, so two boxes that see this PR at two different heads each win their own CAS and both
  # review and merge it (#1908 measured it as row M3). Landing a merge is the one operation that
  # does not tolerate at-least-once: `gh pr merge` is NOT pinned to a sha, so the loser's merge
  # lands whatever the head is by then, with the signed marker bound to a head it did not review.
  # `refs/claims/pr-<N>` is taken before the PAID reviewer runs, so the losing box pays nothing, and
  # released on exit so a moved head is landable again next cycle by whichever box gets it.
  # ⛔ TAKEN BEFORE THE HEAD CLAIM, deliberately: the two keys then have one total order across
  # every ingress, so no two boxes can hold them in opposite orders. This claim does not need
  # $HEAD (a PR has an identity without a head), so it is taken even when the head read came back
  # empty — the head claim below still refuses to run in that case, which is fail-closed on the
  # question of whether we know what we are reviewing.
  # ⛔ AN OLD DEPLOYED claims.sh HAS NO claim_pr_acquire, AND THAT IS A NAMED STATE, NOT A SILENT
  # ONE: it is detected explicitly (not left to "command not found" + rc=127 on the `*)` arm) and
  # logged with the remedy, because a box running a pre-#1952 `$O/claims.sh` is degraded to the
  # per-head-only guarantee and nothing else on the path would say so.
  if command -v claim_pr_acquire >/dev/null 2>&1; then
    # ⛔ THE TRAP IS WIDENED HERE — ABOVE THE ACQUIRE, NOT AFTER THE `case` (P2, 2026-10-17 review).
    # It used to be installed ~28 lines below this point, so for that whole window the EXIT trap in
    # force was still the pre-existing `rm -f "$CLAIM"`: a TERM/INT delivered then ran the OLD trap
    # and left `pr-<N>` — already created on the remote — held until the lease expired (up to ~50
    # min), refusing every box. That is strictly worse than the duplicate it prevents. Installed
    # before the acquire, the widening cannot be raced: `release_pr_claim_bounded` no-ops while
    # nothing has been pushed (an empty PR_OWN/CLAIM_COMMIT), so the old-claims.sh `rc=1` and
    # `*)` paths behave exactly as before.
    trap 'release_pr_claim_bounded; rm -f "$CLAIM"' EXIT
    PR_RESOLVED=0
    claim_pr_acquire "$REPO" "$PR" "$CLAIM_LEASE" >/dev/null
    PR_RC=$?
    # ⛔ OWN WHAT THIS ATTEMPT MAY HAVE PUSHED **BEFORE** BRANCHING ON THE RESULT. A TERM between the
    # acquire returning and the `case` arm assigning PR_OWN would otherwise release nothing (see the
    # fallback in release_pr_claim_bounded). rc=1 is the one case that must NOT own anything: a
    # refusal means a peer holds the ref, so nothing of ours exists to release.
    PR_OWN="${CLAIM_COMMIT:-}"
    case "$PR_RC" in
      0) echo "[merge $PR] landing claim: $CLAIM_RESULT" >> "$L.log" ;;
      1) PR_OWN=""; CLAIM_COMMIT=""
         echo "[merge $PR] landing claim REFUSED: $CLAIM_RESULT — another box is landing this PR (at any head); exiting before the paid review" >> "$L.log"
         exit 0 ;;
      *) echo "[merge $PR] landing claim UNAVAILABLE (rc=$PR_RC: $CLAIM_RESULT) — proceeding WITHOUT the per-PR exclusion (the per-head claim is the only fence)" >> "$L.log"
         # Same orphan handling as the head claim: the create path can LAND on the remote and fail
         # only the read-back, so release the commit claims.sh surfaced rather than leave the PR
         # unlandable for the whole lease.
         if [ -n "${CLAIM_COMMIT:-}" ]; then
           _orphan="$CLAIM_COMMIT"
           if release_pr_claim_bounded; then
             # The release already happened: clear BOTH so the EXIT trap neither retries it nor picks
             # it up again through the CLAIM_COMMIT fallback.
             PR_OWN=""; CLAIM_COMMIT=""
             echo "[merge $PR] landing claim: released the orphaned claim commit ${_orphan:0:12} after the read-back failure" >> "$L.log"
           else
             echo "[merge $PR] landing claim: could not release the orphaned commit ${_orphan:0:12} — the EXIT trap will retry" >> "$L.log"
           fi
         fi ;;
    esac
    # ⛔ FROM HERE ON `PR_OWN` IS AUTHORITATIVE, INCLUDING WHEN IT IS EMPTY. The trap's CLAIM_COMMIT
    # fallback exists only for the signal window ABOVE this line (see release_pr_claim_bounded); the
    # head claim below overwrites CLAIM_COMMIT, and without this mark a landing attempt that pushed
    # nothing would fence its release on the HEAD claim's commit.
    PR_RESOLVED=1
  else
    echo "[merge $PR] landing claim UNAVAILABLE: $O/claims.sh defines no claim_pr_acquire (it predates agent-infra#1952) — proceeding WITHOUT the per-PR exclusion, so a peer landing this PR at another head is NOT excluded. Re-provision $O/claims.sh (install.sh seeds it)" >> "$L.log"
  fi
  # The EXIT trap that releases the LANDING claim was widened ABOVE, before the acquire — see the
  # comment there. Any exit from here on (including the head-claim refusal below and every
  # refusal/park after it) runs it; nothing is installed at this point on purpose.
fi

if [ -n "${HEAD:-}" ] && [ -f "$O/claims.sh" ]; then
  # claims.sh and CLAIM_LEASE were resolved in the landing block above; nothing is re-sourced here.
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
# second worker for the same PR. Release first, drop the lock last. Both claims are released here:
# the head claim that names what this worker reviewed, then the landing claim that names the PR
# (#1952), so the coarser ref — the one every box needs to see free — is the LAST to be dropped.
# ⛔ AND ONE MORE THING RUNS AT EXIT: the review attempt's TERMINAL RECORD (agent-infra#2971). A
# reviewer that spawns and then dies — killed at the cap, a TERM from the reaper, an exit that never
# reaches the verdict arm — used to leave NOTHING behind: no marker, no counter, no reason. To the
# controller that is indistinguishable from a reviewer that was never asked, so it re-dispatched, and
# the pass after that did the same (`merge-10213` spawned, log stops, no CLEAN and no ISSUES — the
# measured 2026-10-28 shape). `review_abandoned_record` writes the failed attempt and its reason
# instead. It is registered on the trap that always runs, and it is named before the claims are
# released so a hung release can never be what swallows it.
trap 'review_abandoned_record; release_claim_bounded; release_pr_claim_bounded; rm -f "$CLAIM"' EXIT

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
  # [railrefusal:begin] (extracted and DRIVEN by red-fixer.test.sh — keep the markers)
  # ⛔ THE RAIL'S OWN WORDS ARE CAPTURED, NOT JUST ITS EXIT CODE (agent-infra — the week the fleet
  # sat on red PRs). This is the ONE place that runs the rail, on EVERY ingress (the controller's
  # `merge-<PR>`, `fix-one.sh`, `chain-merge.sh`), so it is the only place a refusal can be recorded
  # once and seen by all of them. Without the record the controller can only see the CHECK classes,
  # and a refusal the rail makes beyond this repo's required set is invisible there: measured
  # 2026-10-20, 13 rails "running", 0 agent lanes, `merged` flat for a week.
  #
  # ⛔ AN OFFSET, NOT A PIPELINE. The rail's stderr must keep going to $L.log LIVE (an operator reads
  # it while a rail runs 20+ minutes), so it is not captured through `tee`/`$( )`. The byte offset is
  # taken first and the bytes PAST it are the refusal of THIS attempt — the log is append-only and
  # already holds earlier attempts' and earlier heads' words, which must not be re-classified as
  # this one's.
  _rf_off="$(wc -c < "$L.log" 2>/dev/null | tr -d ' ')"
  is_num "${_rf_off:-}" || _rf_off=0
  # ── THE HOLD-PROOF AT THE ACTION SITE (agent-infra#2867) ──
  # The claim registry fences dispatch, not action: the rail (`admin-merge.sh`) merges with
  # `--admin`, and nothing at the merge site verified that the lane that reached it still holds
  # the claim for this PR at this head. So a dead harness whose claim was pruned — or a stale
  # actor whose token a peer superseded — would still run the merge. The claim commit this worker
  # pushed (CROSS_OWN, the fencing token) and the harness's claims.sh travel into the rail's
  # environment; the rail refuses the merge unless `claim_action_proof` holds. An EMPTY token is
  # deliberate: a lane that reached the rail without a head claim cannot prove ownership, and the
  # rail refuses it (the merge is the one operation that cannot tolerate at-least-once, #1908).
  # ⛔ The token is the HEAD claim's commit, not the landing claim's: the head key is the one that
  # binds evidence to the sha being merged (the landing `pr-<N>` key carries no head).
  if ( cd "$REPO" && \
       CLAIM_ACTION_HEAD_TOKEN="${CROSS_OWN:-}" \
       CLAIM_ACTION_CLAIMS_SH="$O/claims.sh" \
       CLAIM_ACTION_REPO="$REPO" \
       bash "$RAIL" "$PR" --repo "$OR" -- --squash ) >> "$L.log" 2>&1; then
    echo "[merge $PR] MERGED via the rail (attempt $RC_N) $(date)" >> "$L.log"
    touch "$O/state/merged-$PR.done"
    # A refusal for an older head must not outlive the merge that superseded it.
    rail_refusal_clear "$O" "$PR" 2>/dev/null || true
    rm -f "$O/state/redfix-$PR" 2>/dev/null || true
    rm -f "$O/state/fixgate-$PR-"* 2>/dev/null || true
  else
    echo "[merge $PR] rail refused (attempt $RC_N/$RAIL_TRIES) at head=${HEAD:-?} — the sweep retries this head until the cap, then PARK" >> "$L.log"
    # ⛔ NO `/dev/null` FALLBACK (review P2, 2026-10-21). The first draft fell back to feeding the
    # classifier `/dev/null` and then ran `rm -f "$_rf_txt"` unconditionally — which DELETES /dev/null
    # on a box whose worker runs as root, breaking every redirect on that machine. If the attempt's
    # text cannot be staged there is nothing to classify, so the record is skipped and SAID.
    _rf_txt="$O/state/.rail-attempt-$PR"; _rf_ok=1
    : > "$_rf_txt" 2>/dev/null || _rf_ok=0
    if [ "$_rf_ok" = "1" ]; then
      tail -c "+$(( _rf_off + 1 ))" "$L.log" > "$_rf_txt" 2>/dev/null || _rf_ok=0
    fi
    # The audited override is read from the ENVIRONMENT THIS RAIL RAN IN, not from the log: the rail
    # never mentions that it was set, and the shim consumes it at the merge call.
    _rf_ovr=0; [ -n "${AGENT_ADMIN_MERGE_OVERRIDE:-}" ] && _rf_ovr=1
    _rf_cls=""
    if [ "$_rf_ok" = "1" ] && command -v rail_refusal_record >/dev/null 2>&1; then
      # ⛔ THE STATUS IS THE WRITE'S (review P2). `rail_refusal_record` returns non-zero when it could
      # NOT write, so this log line can never claim a record the controller will not find.
      _rf_cls="$(rail_refusal_record "$O" "$PR" "${HEAD:-}" "$RC_N" "$_rf_txt" "$_rf_ovr" 2>/dev/null)" || _rf_cls=""
    fi
    if [ -n "${_rf_cls:-}" ]; then
      echo "[merge $PR] refusal recorded: class=$_rf_cls head=${HEAD:-?} attempt=$RC_N override=$_rf_ovr — $(rail_refusal_field "$O" "$PR" reason 2>/dev/null)" >> "$L.log"
    else
      # ⛔ A RECORD THAT CANNOT BE WRITTEN IS SAID, NOT SWALLOWED. The controller's red-fixer role
      # reads this record; without it the refusal produces no work — the exact stall this exists to
      # end — so the degraded box must say so loudly, in the log an operator reads.
      echo "[merge $PR] ⚠️ REFUSAL NOT RECORDED — rail-refusal.sh is missing/unusable in \$O, or \$O/state is unwritable, so NO red-fixer can see this refusal (re-seed: bash scripts/orchestrator-harness/deploy-harness.sh --repo . --o \"$O\"; free space). The rail's words are above." >> "$L.log"
    fi
    # Removed unconditionally: the `/dev/null` fallback that made this unsafe is gone, and a staged
    # temp left behind on the `tail`-failed path is one file per PR, forever (review P3, cycle 4).
    rm -f "$_rf_txt" 2>/dev/null || true
  fi
  # [railrefusal:end]
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
$REVIEW_RESEARCH_BRIEF

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
# ⛔ THE ATTEMPT IS MARKED IN FLIGHT BEFORE THE REVIEWER STARTS (agent-infra#2971). Everything
# below this line can end the process without a verdict — the cap kill, a TERM from the reaper, an
# `exit` on a path this file has not foreseen — and `review_abandoned_record` (EXIT trap) is what
# turns each of those into a COUNTED failed attempt with its reason instead of a log that just stops.
REV_STARTED=1
run_agent "${REVIEW_TIMEOUT:-1800}" "$L.log" "$L-reviewer.txt"
AGENT_RC=$?
# ⛔ A REFUSAL AT THE SPAWN POINT IS NOT A VERDICT (agent-infra#1884). This file carries its OWN
# `run_agent()` with no load gate of its own (the header's named residual), so the installed `pi`
# shim is the only load gate this path has — and its refusal arrives as rc=76. Without this arm the
# empty verdict falls into the `*)` arm below, which — since #2132 — records `needsreview-<PR>-<head>`
# rather than authorising a fixer, but would still spend one of the bounded MAX_REVIEW_TRIES re-reviews
# per REFUSAL even though no review was attempted. So: no marker at all, the harness's own
# AGENT_LOAD_REFUSED code, and the controller re-dispatches when the box quietens (75 is what
# adopt-fix/chain-merge already propagate for this).
if [ "$AGENT_RC" = "${PI_GATE_REFUSED:-76}" ]; then
  # ⛔ REV_STARTED GOES BACK TO 0: NO REVIEWER RAN (agent-infra#2971). The in-flight mark above is for
  # an attempt that STARTED; a refusal at the spawn point is not an attempt, and the EXIT recorder
  # would otherwise spend one of MAX_REVIEW_TRIES for a review this box never ran — the exact
  # over-blocking this arm exists to refuse.
  REV_STARTED=0
  echo "[merge $PR] reviewer NOT started (pi spawn-point load gate) — no verdict, NO marker written (a needsfix marker would authorise a fixer and a needsreview marker would spend one of MAX_REVIEW_TRIES for a review that never started); re-dispatched when 1-min load falls below MAX_LOAD" >> "$L.log"
  exit 75
fi
# ⛔ THE BRIEF REFUSAL IS ITS OWN ARM (#2258), and it must NOT reach the verdict classifier. The
# reviewer's brief is GENERATED by this file, so a refusal here means the splice lost the research
# block or `brief-gate.sh` drifted — a HARNESS defect. Classified as a verdict-less review it would be
# indistinguishable from a reviewer that produced nothing, and the loop would re-dispatch the same
# broken brief until MAX_FIX_TRIES parked a PR that was never reviewed (the #1716/#1720 class). Exit
# 80 names it: no agent ran, no verdict, no marker, and nothing to re-dispatch until the brief's own
# build is fixed.
if [ "$AGENT_RC" = "${AGENT_BRIEF_REFUSED:-80}" ]; then
  # Same reason as the load-gate arm above: no agent ran, so the EXIT recorder must stay inert.
  REV_STARTED=0
  echo "[merge $PR] reviewer NOT started (BRIEF gate) — no verdict, NO needsfix marker; the reviewer brief failed brief-gate.sh, which is a harness defect: fix the brief's build, not the PR" >> "$L.log"
  echo "[merge $PR] brief refused (harness defect) — no reviewer started; see $L.log" >&2
  exit 80
fi
# ⛔ THE EXTRACTOR MUST ADMIT THE SAME SEPARATORS THE CLASSIFIER DOES (review round 8, P2). The
# pattern required a SPACE after the token, so a reviewer whose final line was `ISSUES: 3` produced an
# EMPTY `LAST` — the round-7 tolerance in `verdict_class` was unreachable, the fixer was withheld, up to
# MAX_REVIEW_TRIES paid re-reviews were spent, and the head was parked. A classifier tolerance that the
# producer can never deliver is an inert guard; the suite pinned only the helper, so it stayed green.
# (Both halves are pinned now: this expression is driven by the suite against every accepted form.)
LAST="$(grep -aE '^(CLEAN|ISSUES)([[:space:]]|:|-)' "$L.log" | tail -1 | tr -d '\r')"
echo "[merge $PR] verdict: ${LAST:-<none>}" >> "$L.log"

# ── the VERDICT → STATE mapping (agent-infra#2132) ────────────────────────────────────────────
# ONE place decides which state a reviewer's final line leaves a head in, because the CONTROLLER
# acts on the state and on nothing else:
#   ISSUES     -> needsfix-<PR>-<head>      findings exist, so a FIXER is the remedy
#   NO-VERDICT -> needsreview-<PR>-<head>   nothing was reviewed, so the remedy is another REVIEW
# ⛔ THESE ARE NOT THE SAME REMEDY, AND CONFLATING THEM IS THE LOOP #2132 NAMES. The reviewer cap is
# measured, not hypothetical — the no-search bound above records 43 of 124 reviewer runs ending at
# the cap with no verdict. The single `*)` arm this replaces wrote the FIXER marker for every one of
# those, so the controller spent a MAX_FIX_TRIES attempt on a head nobody had reviewed: the fixer
# pushed, the push invalidated the signed review by design, the gate stayed red, the next cycle did
# it again — and the PR was finally parked "needs a human" having never converged, with the gate's
# `FAILED:ai-review-gate` indistinguishable from a genuine rejection. A fixer cannot act on findings
# that do not exist; only another review can.
verdict_class() {
  local n
  case "${1:-}" in
    CLEAN*)  printf 'CLEAN' ;;
    # ⛔ THE COUNT IS PART OF THE VERDICT (review round 3, P3). "ISSUES" alone does not mean findings
    # exist — `ISSUES 0` says the reviewer found NONE, and a bare prefix match turned that into a fixer
    # authorisation, spending a MAX_FIX_TRIES attempt on a head with nothing to fix.
    # ⛔ AND IT IS PARSED WITHOUT WORD SPLITTING (review round 4, P3). `set -- $n` is unquoted, so the
    # count was GLOB-EXPANDED against merge-one's cwd (the repo): a final line of `ISSUES *` became the
    # repo's first top-level entry, and a repo carrying a top-level all-digit name then yielded class
    # ISSUES with no count — the very authorisation this function exists to refuse. Strip the leading
    # blanks with parameter expansion and keep the leading digit run; no splitting, no globbing, and a
    # 10-digit bound keeps the value away from `-ge` (which errs FALSE on bash 3.2).
    ISSUES*)
      n="${1#ISSUES}"
      while :; do case "$n" in ' '*|'	'*) n="${n#?}" ;; *) break ;; esac; done
      # ⛔ A SEPARATOR BEFORE THE COUNT IS TOLERATED (review round 7, P3). `ISSUES: 3` / `ISSUES - 3`
      # are formatting variants of a verdict that DID report findings; treating them as "no verdict"
      # withheld the fixer and parked the head with a reason telling a human to fix the reviewer's
      # budget. The class decision is "does a count >= 1 exist", not "does the line match the
      # prompt's template" — so strip a leading non-digit run. No splitting and no globbing: a bare
      # `ISSUES *` still has no digit and reads NO-VERDICT.
      n="${n#"${n%%[0-9]*}"}"
      n="${n%%[!0-9]*}"
      case "$n" in ''|*[!0-9]*) printf 'NO-VERDICT' ;; *)
        if [ "${#n}" -le 9 ] && [ "$n" -ge 1 ]; then printf 'ISSUES'; else printf 'NO-VERDICT'; fi ;;
      esac ;;
    *)       printf 'NO-VERDICT' ;;
  esac
}

# [revbudget:begin]
# ── ONE (PR, HEAD) REVIEW BUDGET, SHARED WITH THE CONTROLLER (agent-infra#2971) ────────────────
# `state/reviewdisp-<PR>` = "<head> <n>". It is the SAME record `orch-loop.sh`'s [reviewdisp] block
# keeps: the controller writes it when it dispatches a review ORDER for a (PR, head), and this file
# spends it when a reviewer run produces nothing usable. Two arms, ONE book — before this the
# controller's dispatch budget and this file's retry budget were separate files
# (`reviewdisp-<PR>` / `reviewcount-<PR>`), so "we already tried review twice at this head" was
# visible to neither: the controller could dispatch against a head this file had already given up on,
# and this file could re-open a head the controller had parked.
# ⛔ NO DOUBLE COUNT. A controller dispatch already spends the attempt (`REV_PAID=1` travels in the
# spawn command). Only a path with NOBODY counting above it — `chain-<N>`, `fix-one.sh`, a hand run —
# spends on this side. Counting both would halve a budget that was already measured as tight, which
# is over-blocking dressed as safety.
rev_budget_file() { printf '%s/state/reviewdisp-%s\n' "$O" "$PR"; }
rev_budget_read() { # -> "<head> <n>" (n is coerced: it feeds -ge and $(( + 1 )))
  local f h="" n=0
  f="$(rev_budget_file)"
  if [ -f "$f" ]; then read -r h n < "$f" 2>/dev/null || true; fi
  is_limit "${n:-}" || n=0
  printf '%s %s\n' "${h:-}" "$n"
}
rev_budget_spend() { # -> "<n> already|spent|unwritable"; rc 1 when the write failed
  local rec now_h="" n=0
  rec="$(rev_budget_read)"; n="${rec##* }"; now_h="${rec% *}"
  [ "${now_h:-}" = "${HEAD:-}" ] || n=0
  if [ "${REV_PAID:-0}" = "1" ]; then printf '%s already\n' "$n"; return 0; fi
  n=$(( n + 1 ))
  # ⛔ THE WRITE MUST BE ABLE TO FAIL LOUDLY. A `|| true` here would make the bound best-effort: the
  # count would read 0 for ever and this file would buy a fresh PAID review every cycle with no cap
  # ever reached and no line saying the record failed — the same class orch-loop.sh's [reviewdisp]
  # block refuses at its own write.
  printf '%s %s\n' "${HEAD:-}" "$n" > "$(rev_budget_file)" 2>/dev/null \
    || { printf '%s unwritable\n' "$n"; return 1; }
  printf '%s spent\n' "$n"
}
# [revbudget:end]

# review_abandoned_record — the EXIT recorder for a review attempt that ended with NO verdict
# (agent-infra#2971, requirement 3). Fires from the EXIT trap, so TERM/INT/`exit N`/an unexpected
# death after the reviewer started all reach it; it is INERT unless this process actually ran a
# reviewer (`REV_STARTED`) and never wrote a terminal record for it (`REV_RECORDED`), and it refuses
# when the run DID produce a verdict — a CLEAN that failed to RECORD is its own failure, already
# named by the park paths, and calling it "no verdict" would be a false statement in the reason a
# human reads. Without this, `merge-10213`'s log simply stopped at 23:30 and nothing counted it.
review_abandoned_record() {
  local rc=$? cls spent n mode why
  [ "${REV_STARTED:-0}" = "1" ] || return 0
  [ "${REV_RECORDED:-0}" = "1" ] && return 0
  [ -n "${HEAD:-}" ] || return 0
  cls="$(verdict_class "${LAST:-}")"
  [ "$cls" = "NO-VERDICT" ] || return 0
  why="the reviewer run ENDED WITHOUT a CLEAN/ISSUES marker (exit rc=$rc, last line [${LAST:-<none>}]) — counted as a failed attempt, never as silence"
  spent="$(rev_budget_spend)" || mode=unwritable
  n="${spent%% *}"; mode="${spent##* }"
  is_limit "${n:-}" || n=0
  MAX_REVIEW_TRIES="${MAX_REVIEW_TRIES:-3}"
  is_limit "$MAX_REVIEW_TRIES" || MAX_REVIEW_TRIES=3
  if [ "${mode:-}" = "unwritable" ]; then
    echo "[merge $PR] $why, but $(rev_budget_file) CANNOT BE WRITTEN — the (PR,head) review cap cannot be kept, so this head is PARKED rather than re-reviewed (a counter that cannot be written is not a bound)" >> "$L.log"
    park "$why. state/reviewdisp-$PR could not be written, so MAX_REVIEW_TRIES cannot bound this head: make $O/state writable (rm -rf a stray directory named reviewdisp-$PR), then: rm -f '$O/state/parked-$PR' '$O/state/parkreason-$PR'"
    return 0
  fi
  if [ "$n" -ge "$MAX_REVIEW_TRIES" ]; then
    echo "[merge $PR] NEEDS-REVIEW: $why — review attempts at head=$HEAD are EXHAUSTED ${n}/${MAX_REVIEW_TRIES}, PARKED" >> "$L.log"
    park "$why. Review attempts at head=$HEAD are exhausted (${n}/${MAX_REVIEW_TRIES}, counted once across the controller's dispatch and this run), so nothing was reviewed here and no signed marker can be minted. Fix the reviewer's budget/cap (REVIEW_TIMEOUT) or its output format; a push re-arms it, or: rm -f '$O/state/parked-$PR' '$O/state/parkreason-$PR' '$O/state/reviewdisp-$PR'"
    rm -f "$O/state/needsreview-$PR-"* 2>/dev/null || true
    return 0
  fi
  touch "$O/state/needsreview-$PR-$HEAD" 2>/dev/null || echo "[merge $PR] $why, and needsreview-$PR-$HEAD WAS NOT WRITTEN (the controller reads this head as NEEDS-REVIEW by ABSENCE, so the remedy is unchanged; report.sh under-counts it)" >> "$L.log"
  echo "[merge $PR] NEEDS-REVIEW: $why — attempt ${n}/${MAX_REVIEW_TRIES} spent at this head; the remedy is another REVIEW" >> "$L.log"
  return 0
}

# review_state_record <class> — write the state marker the CONTROLLER acts on, at $HEAD.
# ⛔ NO-VERDICT IS BOUNDED AND KEYED ON THE HEAD. A reviewer that never returns a verdict must not
# buy an unbounded succession of PAID reviews (the #1717 class, one input over): MAX_REVIEW_TRIES
# (default 3) parks the head with a reason that names the truth — nothing was reviewed, so no signed
# marker can be minted and no fixer can help — and a new push re-arms it. The count is per HEAD, the
# same shape fixcount uses, so a push never inherits the previous head's attempts.
review_state_record() {
  local cls="${1:-}" rc_n=0 _spent="" _spmode=""
  [ -n "${HEAD:-}" ] || return 0
  # ⛔ ONE MARKER PER PR, NOT PER (PR, HEAD) (review round 1, P2). An older head's stale-evidence
  # marker is not a fact about THIS head, and nothing swept it: the controller writes one on every red
  # cycle, so with the per-head name alone the `needsreview-*` population only ever GREW — a counter
  # that climbs and never falls is the false instrument report.sh's line would publish ("the count of
  # open PRs stalled on stale evidence stays at 0" could never read 0 again). Prune the PR's other
  # heads here, where the current state is known, so the marker set always describes NOW.
  case "$cls" in
    ISSUES)
      # ⛔ ONE FINDINGS MARKER PER PR, NOT PER HEAD (review round 7, P3). Nothing deleted an old-head
      # `needsfix-*`, so a PR that collected findings at five heads kept five markers for its whole
      # life (inert — both readers are head-keyed — but the docs claim they are replaced, and a state
      # directory that accumulates is how an operator stops trusting it).
      rm -f "$O/state/needsfix-$PR-"* "$O/state/needsreview-$PR-"* "$O/state/reviewdisp-$PR" "$O/state/reviewcount-$PR" 2>/dev/null || true
      # ⛔ AND A FAILED MARKER WRITE IS REPORTED AS WHAT IT IS (kept from main's #8602 port): the
      # controller decides with a FILE TEST (`[ -f $O/state/needsfix-<PR>-<head> ]`), so a marker that
      # did not land sends the PR to the RE-RECORD arm — a fresh review — and never to a fixer. A log
      # line claiming "a fixer is authorised" over a missing file would have an operator believe the
      # findings were handed to a repair lane while the PR sat waiting for another review.
      if touch "$O/state/needsfix-$PR-$HEAD" 2>/dev/null; then
        echo "[merge $PR] NEEDS-FIX: the reviewer reported findings at head=$HEAD — a fixer is authorised" >> "$L.log"
      else
        echo "[merge $PR] NEEDS-FIX at head=$HEAD but the needsfix MARKER WAS NOT WRITTEN — the controller decides by a FILE TEST, so this PR is NOT handed to a fixer: it falls to the re-record arm, i.e. another fresh review" >> "$L.log"
      fi
      # ⛔ A USABLE VERDICT RESETS THE VERDICT-LESS COUNTER (review round 10, P2). The counter bounds
      # CONSECUTIVE runs that produced no verdict; a reviewer that DID produce one — here, findings —
      # restarts the count. Without this, N-1 timeouts before a findings verdict still parked the head
      # on the next timeout, with a reason claiming "a fixer has no findings to act on" at a head that
      # HAD findings (and, after a verified CLEAN, claiming nothing was reviewed at all).
      # ⛔ AND THE SHARED REVIEW BUDGET, ON THE SAME ARGUMENT (agent-infra#2971): a usable verdict —
      # findings here, a verified CLEAN in review_state_clear — is what re-arms the count, because the
      # count bounds CONSECUTIVE verdict-less attempts at a head.
      rm -f "$O/state/reviewcount-$PR" "$O/state/reviewdisp-$PR" 2>/dev/null || true
      return 0 ;;
    NO-VERDICT)
      # ⛔ A VERDICT-LESS RUN DOES NOT SUPERSEDE A FINDINGS VERDICT AT THE SAME HEAD (review round 6,
      # P3). Nothing was pushed, so a run that produced no verdict carries no information about the
      # head — yet this branch used to DELETE `needsfix-<PR>-<head>` and then park with a reason saying
      # "nothing was reviewed at this head", which is false for a PR a reviewer had already reported
      # findings on. Keep NEEDS-FIX (a fixer is still the remedy), spend no re-review budget, and
      # leave exactly one state for the PR.
      if [ -f "$O/state/needsfix-$PR-$HEAD" ]; then
        rm -f "$O/state/needsreview-$PR-"* 2>/dev/null || true
        echo "[merge $PR] no usable verdict at head=$HEAD, but FINDINGS are already recorded here — keeping NEEDS-FIX (a fixer is still the remedy); no re-review budget consumed" >> "$L.log"
        return 0
      fi
      MAX_REVIEW_TRIES="${MAX_REVIEW_TRIES:-3}"
      is_limit "$MAX_REVIEW_TRIES" || MAX_REVIEW_TRIES=3
      # ⛔ THE COUNT IS THE SHARED (PR, HEAD) RECORD, NOT A PRIVATE ONE ([revbudget] above). The
      # controller's dispatch and this run are the same book, so the number in the reason below is the
      # number the controller's own REVIEW-CAP will read.
      _spent="$(rev_budget_spend)"; _spmode="${_spent##* }"; rc_n="${_spent%% *}"
      is_limit "${rc_n:-}" || rc_n=0
      if [ "${_spmode:-}" = "unwritable" ]; then
        # A counter that cannot be written is not a bound. Say so and stop, rather than re-buy.
        park "the reviewer produced NO usable verdict at head=$HEAD (last line was [${LAST:-<empty>}]), and $(rev_budget_file) CANNOT BE WRITTEN — MAX_REVIEW_TRIES cannot bound this head, so it is parked instead of re-reviewed. Make $O/state writable (rm -rf a stray directory named reviewdisp-$PR), then: rm -f '$O/state/parked-$PR' '$O/state/parkreason-$PR'"
        echo "[merge $PR] NEEDS-REVIEW: no usable verdict at head=$HEAD and the (PR,head) review budget CANNOT BE WRITTEN — PARKED (an unwritable counter is not a bound)" >> "$L.log"
        rm -f "$O/state/needsreview-$PR-"* 2>/dev/null || true
        return 0
      fi
      # ⛔ PRUNE EVERY BRANCH, NOT JUST THE WRITE BRANCH (review round 5, P2). The park branch below
      # removed only the marker AT the parked head, so a superseded marker at another head survived and
      # satisfied neither of report.sh's attributions (its head ≠ parked-<PR>, so it was not read as
      # "parked", while the PR was ALSO counted by the `parked (needs a human)` line) — one PR in two
      # queues with two different remedies, the round-3/4 defect one branch over.
      # ⛔ AND THE OTHER HEADS' FINDINGS MARKERS GO WITH IT (review round 9): the same-head marker was
      # already excluded by the early return above, so only INERT old-head ones remain — leaving them is
      # the growth the sibling markers no longer have, and it makes "replaced at a new head" false.
      rm -f "$O/state/needsreview-$PR-"* "$O/state/needsfix-$PR-"* 2>/dev/null || true
      if [ "$rc_n" -ge "$MAX_REVIEW_TRIES" ]; then
        # ⛔ THE REASON NAMES THE LINE IT REJECTED (review round 7, P3). `parkreason-<PR>` is the only
        # ⛔ AND IT NAMES THE SHARED BOOK (agent-infra#2971): the count is the controller's dispatch
        # budget as well as this file's, so "3 times" now means three review attempts at this head by
        # ANY arm — never this file's private tally sitting beside an untouched controller budget.
        # in-band remedial signal a human sees, and "a final line that was neither CLEAN nor ISSUES"
        # cannot distinguish a reviewer hit by its wall clock from one that printed an off-spec line.
        park "the reviewer produced NO usable verdict at head=$HEAD ${rc_n} time(s); last line was [${LAST:-<empty>}]. Nothing was reviewed at this head, so no signed marker can be minted and a fixer has no findings to act on. Fix the reviewer's budget/cap (REVIEW_TIMEOUT) or its output format, then: rm -f '$O/state/parked-$PR' '$O/state/parkreason-$PR'"
        echo "[merge $PR] NEEDS-REVIEW: no usable verdict ${rc_n}/${MAX_REVIEW_TRIES} at head=$HEAD — PARKED (a fixer is never authorised for a head nobody reviewed)" >> "$L.log"
        return 0
      fi
      touch "$O/state/needsreview-$PR-$HEAD" 2>/dev/null || echo "[merge $PR] NEEDS-REVIEW at head=$HEAD but the needsreview MARKER WAS NOT WRITTEN — the controller will read this head as NEEDS-REVIEW by ABSENCE (fail-closed), so the remedy is unchanged; report.sh's stale-evidence count will under-count it" >> "$L.log"
      echo "[merge $PR] NEEDS-REVIEW: no usable verdict at head=$HEAD (${rc_n}/${MAX_REVIEW_TRIES}) — the remedy is another REVIEW; no fixer is authorised" >> "$L.log"
      return 0 ;;
  esac
}

# review_state_clear — the head now carries VERIFIED, signed evidence, so it is no longer in
# stale-evidence state. ⛔ CALL IT ONLY AFTER THE MARKER VERIFIED, never after a bare rc=0 (#2132
# review round 1): `record-review.sh` returning 0 is not evidence — the arm below proves the signed
# marker is in the body before this runs, and the suite pins that ORDER (a clear placed above the
# `marker_ok` guard would let a failed record read as a satisfied head).
review_state_clear() {
  [ -n "${HEAD:-}" ] || return 0
  # ⛔ AND IT CLEARS THE FINDINGS STATE AT THAT HEAD TOO (review round 6, P2). A CLEAN verdict with a
  # verified marker is the LATEST verdict at this head, so a `needsfix-<PR>-<head>` left by an earlier
  # ISSUES run at the SAME head is false — and `review_gate_state()` reads only that marker, so keeping
  # it authorised a fixer for a head whose reviewer had just said CLEAN (reachable whenever the first
  # fixer spawn was blocked by slots/load and the re-record came back CLEAN).
  # ⛔ AND THE SPEND RECORD GOES WITH IT (review round 7, P2). `fixspend-<PR>-<head>` exists for ONE
  # purpose: to authorise `refund_bailed_fixer` to restore the findings state at that head. Once the
  # clear declares that state superseded, keeping the spend record lets a later bail at the same head
  # MINT a `needsfix` marker at a head with a signed CLEAN marker — the exact fixer-without-findings
  # failure this issue exists to close, one round trip later.
  # ⛔ AND THE VERDICT-LESS COUNTER, BECAUSE THAT RUN WAS NOT VERDICT-LESS (review round 10, P2).
  # The SHARED (PR, head) review budget — `reviewdisp-<PR>`, the same record the controller spends on
  # dispatch (agent-infra#2971; it was `reviewcount-<PR>` before the two books became one) — bounds
  # CONSECUTIVE runs that produced no usable verdict; this one produced one (the signed marker just
  # verified), so it restarts. Keeping it parked a head on the next timeout
  # after two earlier timeouts, with a reason claiming nothing had been reviewed at a head whose
  # review had in fact completed — a park (a human) bought by a run that never failed.
  rm -f "$O/state/needsreview-$PR-"* "$O/state/needsfix-$PR-$HEAD" "$O/state/fixspend-$PR-$HEAD" "$O/state/reviewcount-$PR" "$O/state/reviewdisp-$PR" 2>/dev/null || true
  echo "[merge $PR] NEEDS-REVIEW cleared: signed evidence verified at head=$HEAD" >> "$L.log"
  return 0
}

case "$LAST" in
  CLEAN*)
    URL="$(printf '%s' "$LAST" | grep -oE 'https?://[^ ]+' | head -1)"
    CID="$(printf '%s' "$URL" | grep -oE '[0-9]+$')"
    echo "[merge $PR] evidence comment id=${CID:-?} url=$URL" >> "$L.log"
    if [ -z "${CID:-}" ]; then
      # The reviewer said CLEAN but named no comment, so there is no artifact to sign — the gate can
      # NEVER go green at this head. Park it: the pre-fix bare `exit 2` left no marker, so the loop
      # re-paid for a fresh review every cycle (#1717).
      park "reviewer reported CLEAN but posted no comment URL — no evidence artifact to sign, so ai-review-gate can never go green at this head. The comment usually EXISTS (the reviewer posts it before the verdict): find it on PR #$PR and record it by hand (record-review.sh $PR $HEAD clean $OR --evidence comment:<id> --expect-head $HEAD), then: rm -f '$O/state/parked-$PR' '$O/state/parkreason-$PR'"
      echo "[merge $PR] ABORT: no comment id" >> "$L.log"; exit 2
    fi
    # ── 2) record the review (writes the signed marker into the PR body) ──
    # ⛔ #2572 — PIN THE RECORD TO THE HEAD THE REVIEWER READ. The `--expect-head` pin is the
    # recorder's only defence against its #2982 carry arm re-binding a `clean` to the LIVE head when
    # the reviewed diff happens to be unchanged (tortoise#9492). This lane pays for a review of `$HEAD`
    # (up to REVIEW_TIMEOUT, PAID) and every check above is a statement about `$HEAD`; without the pin
    # the one call that MINTS the record could attest a different revision than the one that was read.
    # `$HEAD` is already required to be a full 40-hex sha before the paid step (the #1717 guard above),
    # so the pin is always STATABLE here; the recorder itself fails closed (exit 3) when it cannot
    # CHECK the pin, so an unverifiable pin can never record.
    REC_OUT="$(mktemp "${TMPDIR:-/tmp}/merge-$PR-record.XXXXXX" 2>/dev/null || true)"
    [ -n "$REC_OUT" ] || REC_OUT=/dev/null
    # ⛔ THE FALLBACK ABOVE MAY ALIAS A REAL DEVICE, so every removal goes through ONE guarded point.
    # An unguarded `rm -f "/dev/null"` is reachable here (mktemp fails on a full/unwritable TMPDIR and
    # REC_OUT becomes the sentinel) and as root it DELETES THE DEVICE NODE — measured on Linux — leaving
    # the cell running with no /dev/null; unprivileged it degrades to an unsilenced permission error on
    # the controller's stderr. This is the defect class scripts/orchestrator-harness/refresh-candidates.sh
    # already records for its own sentinel ("an unguarded `rm -f` on an exit path then deletes THE DEVICE
    # NODE (silently refused for an unprivileged user, destructive for root)"), and cells commonly run
    # as root, so the guard lives in the helper rather than at each of the three call sites.
    rec_out_cleanup() {
      case "${REC_OUT:-}" in '' | /dev/null) return 0 ;; esac
      rm -f "$REC_OUT" 2>/dev/null || true
    }
    "$RECORDER" "$PR" "$HEAD" clean "$OR" --evidence "comment:$CID" --expect-head "$HEAD" >"$REC_OUT" 2>&1
    rc=$?
    cat "$REC_OUT" >> "$L.log" 2>/dev/null || true
    echo "[merge $PR] record-review rc=$rc" >> "$L.log"
    if [ $rc -ne 0 ]; then
      # ⛔ THE RECORDER HAS **TWO** EXIT-3 REFUSALS THAT NAME THE PIN, WITH OPPOSITE REMEDIES (P2, fresh
      # review of PR #2988). Keying on the FLAG's presence — `grep -q -- '--expect-head'`, which is
      # what shipped — merges them, because both arms print the flag:
      #   * record-review.sh:2884 `--expect-head: the PR head is <live>, NOT the <pin> you named`
      #     ⇒ the head genuinely MOVED inside the window between the review and the record. The verdict
      #       is intact and its subject moved, so a FRESH review at the new head is owed, and advising a
      #       hand re-record (the generic arm below) would carry a stale verdict onto a head nobody read.
      #   * record-review.sh:3029 `--expect-head: could not verify the PR head against <pin>`
      #     ⇒ the pin could not be CHECKED: a transient gh/API failure (403 secondary rate limit, 5xx,
      #       expired token; the #784 population) left the PR's live head unreadable. THE HEAD DID NOT
      #       MOVE, and the artifact this lane just paid for is still valid AT this head — so the remedy
      #       is to RE-TRY THE RECORD, not to park with a fresh PAID review (REVIEW_TIMEOUT = 1800 s)
      #       owed, which is the #1717 shape this file fights everywhere else.
      # So classify on the PRODUCER'S OWN WORDS. `tests/review-pr/run.sh` §A3(5) greps record-review.sh
      # for both literals, so a reword on either side turns CI RED instead of silently re-grading.
      PIN_MOVED_LIT='--expect-head: the PR head is '
      PIN_UNCHECKABLE_LIT='could not verify the PR head against'
      if [ $rc -eq 3 ] && grep -qF -- "$PIN_MOVED_LIT" "$REC_OUT" 2>/dev/null; then
        rec_out_cleanup
        park "the PR head MOVED between the review and the record at head=$HEAD — record-review.sh REFUSED the --expect-head pin (rc=3) rather than attest a head the reviewer never read; its refusal in the log names both shas. The review artifact exists for the REVIEWED head only, so a FRESH review at the new head is owed (a hand re-record would carry a stale verdict)."
        echo "[merge $PR] ABORT: head moved before the record — refusing to bind a stale verdict" >> "$L.log"; exit 3
      fi
      if [ $rc -eq 3 ] && grep -qF -- "$PIN_UNCHECKABLE_LIT" "$REC_OUT" 2>/dev/null; then
        rec_out_cleanup
        park "record-review.sh could NOT CHECK the --expect-head pin at head=$HEAD (rc=3) — the recorder could not READ the PR's live head, i.e. a gh/API TRANSPORT failure (secondary rate limit, 5xx, expired token), NOT a moved head and NOT a reason to re-review: the review this lane paid for is still the artifact for $HEAD. NOTHING was recorded. Re-run the RECORD once gh is healthy (record-review.sh $PR $HEAD clean $OR --evidence comment:$CID --expect-head $HEAD — idempotent at this head), then: rm -f '$O/state/parked-$PR' '$O/state/parkreason-$PR'"
        echo "[merge $PR] ABORT: pin unverifiable (gh/API) — record retry owed, no re-review" >> "$L.log"; exit 3
      fi
      rec_out_cleanup
      # No signed marker exists, so the gate cannot pass and the PR cannot merge. The pre-fix
      # `exit 3` left no marker at ALL, so the next cycle saw an unmarked FAILED:ai-review-gate and
      # spawned another fresh (paid) review — forever (#1717). Park, and name the failing rc.
      park "record-review.sh failed rc=$rc at head=$HEAD — the signed marker is NOT in the PR body, so the loop would re-pay for a fresh review every cycle. Re-record by hand (record-review.sh $PR $HEAD clean $OR --evidence comment:$CID --expect-head $HEAD), then: rm -f '$O/state/parked-$PR' '$O/state/parkreason-$PR'"
      echo "[merge $PR] ABORT: record failed" >> "$L.log"; exit 3
    fi
    # the recorder's output is already in `$L.log`; the temp file is only here so THIS call's
    # refusal can be classified without a stale match from an earlier cycle.
    rec_out_cleanup
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
      marker_how="the recorder's evidence post is best-effort and skips silently when the body read or PATCH fails, or gh/repo is unavailable, so ai-review-gate can never go green at this head and the loop would re-pay for a fresh review every cycle. If the reviewer's comment exists, record it by hand (record-review.sh $PR $HEAD clean $OR --evidence comment:$CID --expect-head $HEAD), then: rm -f '$O/state/parked-$PR' '$O/state/parkreason-$PR'"
    elif printf '%s\n' "$MARK_CAND" | verify_any_marker "$MARK_KEY"; then
      marker_ok=1
    else
      marker_why="NO marker for head=$LIVE_HEAD in the PR body VERIFIES against its signature — the PR body is not a trust boundary, so a forged, re-keyed or unsigned line is NOT evidence (#784)"
      marker_how="re-record the review at this head so a freshly signed marker is appended (record-review.sh $PR $HEAD clean $OR --evidence comment:$CID --expect-head $HEAD), then: rm -f '$O/state/parked-$PR' '$O/state/parkreason-$PR'"
    fi
    if [ "$marker_ok" -ne 1 ]; then
      park "record-review.sh returned rc=0, but the signed marker ai-review-gate reads is not verifiably there: $marker_why — $marker_how"
      echo "[merge $PR] ABORT: rc=0 but $marker_why" >> "$L.log"; exit 3
    fi
    # The head now carries VERIFIED, signed evidence (the guard above proved the marker is in the
    # body and that its signature verifies), so the controller's stale-evidence state for it is no
    # longer true — and report.sh counts exactly those (agent-infra#2132). This call MUST stay BELOW
    # the guard: a clear above it would let a bare rc=0 read as a satisfied head.
    review_state_clear
    REV_RECORDED=1   # a terminal record exists for this run; the EXIT recorder must stay inert
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
    #
    # ⛔⛔ THREE CONDITIONS, THREE VERDICTS — AND AN EMPTY `gate=` IS NEVER PRINTED (agent-infra#2596).
    # The pre-#2596 loop read `gh pr checks | python3` with BOTH stderr streams sent to /dev/null and
    # printed whatever came back. Three unrelated conditions therefore landed in the log as the same
    # empty string, thirty times, and then as `ABORT: gate= (not green)` after 15 minutes:
    #   (a) the READ FAILED — auth, a non-repo cwd (#2182), the shim chain answering nothing (#2320),
    #       or a rate-limit band whose refusal `gh-limit` names ON STDERR (gh-core-floor /
    #       gh-core-exhausted, #2448). The datum never existed, and `2>/dev/null` deleted the only
    #       line that said why. That is the #2448 defect class, whose scope was orch-loop.sh and
    #       lander.sh — this site was not in it.
    #   (b) the read SUCCEEDED but no row is named `$REVIEW_GATE`. GitHub does not report a
    #       `workflow_call` job under its bare job name: it renders `<caller> / <job>`. MEASURED on
    #       this repo (`gh pr checks 2567 --json name,state`: `ci / lint`, `ci / typecheck`,
    #       `ci / unit-test`, `ci / script-validate`) and on tortoise PR #9827 (`agent-infra-ci / lint`,
    #       `agent-infra-ci / typecheck`). An exact `== n` match can never fire when the GATE's row
    #       carries that prefix, so on such a repo the worker spends the whole window on a green gate.
    #       ⚠️ HONEST SCOPE, measured rather than assumed: in the fleet's CURRENT state the required
    #       gate is reported PLAINLY (tortoise's required set is `pricing-artifact docs test-isolation
    #       license-surface legal-e2e python-ci-gate ai-review-gate`, and `gh pr checks` renders
    #       `ai-review-gate` unprefixed), so this arm is a GUARD for the reusable-workflow shape — it
    #       is NOT the cause of #2596's measured spin, which was the unreadable read in (a). It is
    #       still the right match rule, because a gate moved behind a `workflow_call` would otherwise
    #       be silently unmergeable, and #2596 exists to stop silent — and the normalisation is not
    #       invented: it is the one the rail already applies.
    #   (c) the row exists but is not finished (`QUEUED`/`IN_PROGRESS`), OR does not exist YET because
    #       the run has not started. That is a WAIT. The old loop had no notion of one: it re-read
    #       30 times and called the answer "not green" — the same line a genuinely red gate produced.
    # The three are now classified apart and each ends in its own line; a read that produced nothing
    # says WHY it produced nothing, because this is the one call whose silence is being interpreted.
    #
    # ⛔ THE NAME IS MATCHED THE WAY GITHUB NAMES CHECKS, AND ONLY THAT WAY: verbatim, or (fallback)
    # after stripping a `<caller> / ` prefix with `rsplit(" / ", 1)` — the SAME normalisation
    # `admin-merge.sh` applies to job names at its two re-run/parity sites (`:2431-2433`,
    # `:3269-3271`, "stripped of a reusable-workflow caller prefix (`<caller> / <called>`, which gh
    # renders for a `workflow_call` job)"). It is NOT a substring match: `REVIEW_GATE=compliance`
    # must never select `pipeline-compliance` — the round-12 review recorded exactly that substring
    # behaviour as a §5.1 bypass, and test-gates.sh pins it. `$REVIEW_GATE` can only ever BE the
    # bare job name for such a repo, because a context containing a space is refused outright by
    # `repo-authority.sh::_unrepresentable`, so suffix matching is the only form that can name it.
    #
    # ⛔ AND A WIDENED MATCH IS NEVER DECIDED BY ROW ORDER. Stripping the caller prefix means two
    # rows can canonicalise to the gate, so "the first one that matches" can take a green
    # `ci / unit-test` and discard a RED row explicitly named `unit-test` — a false PASS on the very
    # surface this arm made matchable, decided by the API's row order. EVERY row whose name is the
    # gate counts and the WORST state decides: that is the rule the controller applies in
    # orch-loop.sh (`all(v=="nonred" and c=="success" ...)`), so the two classifiers cannot disagree.
    # ⚠️ THE COST OF THAT, STATED PLAINLY: a SUPERSEDED row keeps the gate refused. When a re-run
    # leaves the earlier FAILURE in the payload (the cell adapter emits every attempt, unsorted and
    # un-deduped) the gate reads RED even though the newest attempt is green; the controller refuses
    # the same PR for the same reason, so this is the fleet's existing behaviour rather than a new
    # one, and the remedy is a new head or a re-run whose row replaces the old one — the verdict names
    # the STATE, so the operator can see which row is red. Supersession-aware reading needs a signal
    # no transport here provides (agent-infra#2625): two earlier attempts at it produced the false
    # PASSes above, so it is a decision, not a detail.
    # ⚠️ KNOWN DIVERGENCE, disclosed rather than hidden: orch-loop.sh's own classifier still matches
    # the gate name EXACTLY, so a `<caller> / <job>` gate reads PENDING/FAILED there and this worker is
    # reached only through the chain/fix/manual paths. Mirroring the normalisation in the controller is
    # a separate change to a separate classifier (filed as agent-infra#2617), not part of this fix.
    #
    # ⛔ A NOT-YET-CREATED CHECK IS A BOUNDED WAIT, NOT A SPIN TO ABORT, AND IT IS TWO CASES. A surface
    # that CARRIES checks but none named the gate is a name mismatch: it never resolves, so it gets its
    # own SMALLER bound (`GATE_ABSENT_TRIES`), and at that bound the verdict says NO-SUCH-CHECK and prints
    # what it WANTED and what the surface actually CARRIED. A surface that is EMPTY (no check row at all
    # for this head) is the CI not having started: that one is charged against the FULL CI window — it
    # resolves on its own, and refusing it early would refuse a gate that appears a minute later, which
    # the pre-#2596 loop did not do. Either reason is logged ONCE, on the first poll and on every change
    # of verdict — never 30 identical lines.
    #
    # ⛔ rc IS NOT A VERDICT (lander.sh's documented lesson): real `gh pr checks` exits 1 when a check
    # FAILED and 8 when checks are pending, while the REST shim exits 0. The PAYLOAD decides; rc is
    # carried into the refusal as a detail, never used to classify. An EMPTY payload is UNREADABLE,
    # never an empty check set (#2569/#2592).
    #
    # ⛔ THE TOTAL WAIT IS UNCHANGED BY DEFAULT: GATE_POLL_TRIES x GATE_POLL_SECS = 30 x 30s = 900s,
    # which is what `CLAIM_LEASE` above is sized for. The absent/unreadable bounds are EARLY EXITS
    # on counters inside that one loop, so raising them can never outlast the poll bound itself.
    # ⛔ ASSIGN THE DEFAULTS BEFORE VALIDATING THEM. `if ! is_limit "${X:-30}"; then X=30; fi` leaves X
    # UNSET when the caller supplied nothing — `is_limit "30"` passes and nothing is assigned — and
    # `set -u` then aborts the worker at the first `$(( X * … ))`. Caught by
    # cloud-cell-record-dep.test.sh (which supplies none of these tunables and reached the merge with
    # no GATE_POLL_SECS at all): a default that only exists inside a `${…:-}` expansion is not a
    # default, it is a bullet for the next reader.
    GATE_POLL_TRIES="${GATE_POLL_TRIES:-30}"
    GATE_POLL_SECS="${GATE_POLL_SECS:-30}"
    GATE_ABSENT_TRIES="${GATE_ABSENT_TRIES:-6}"
    GATE_READ_TRIES="${GATE_READ_TRIES:-3}"
    if ! is_limit "$GATE_POLL_TRIES"; then
      echo "[merge $PR] GATE_POLL_TRIES='${GATE_POLL_TRIES:-}' is not an integer in range — using 30 (the 30 x 30s wait CLAIM_LEASE is sized for)" >> "$L.log"
      GATE_POLL_TRIES=30
    fi
    if ! is_limit "$GATE_POLL_SECS"; then
      echo "[merge $PR] GATE_POLL_SECS='${GATE_POLL_SECS:-}' is not an integer in range (at most 9 digits) — using 30 (is_limit, not is_num: the interval is MULTIPLIED for the log line, so an unbounded value wraps it)" >> "$L.log"
      GATE_POLL_SECS=30
    fi
    if ! is_limit "$GATE_ABSENT_TRIES"; then
      echo "[merge $PR] GATE_ABSENT_TRIES='${GATE_ABSENT_TRIES:-}' is not an integer in range — using 6 (3 min: long enough for a slow workflow to create its row, short enough that a WRONG NAME is not paid for with the whole CI window)" >> "$L.log"
      GATE_ABSENT_TRIES=6
    fi
    if ! is_limit "$GATE_READ_TRIES"; then
      echo "[merge $PR] GATE_READ_TRIES='${GATE_READ_TRIES:-}' is not an integer in range — using 3 (a transient gh failure is retried, a dead transport is named)" >> "$L.log"
      GATE_READ_TRIES=3
    fi
    # A zero/absent poll budget would skip the loop entirely and leave the verdict empty — the exact
    # defect this block exists to remove — and the early-exit bounds are floored at 1 for the same
    # reason (0 would abort on the first poll, before the row could ever appear).
    [ "${GATE_POLL_TRIES:-0}" -ge 1 ] || GATE_POLL_TRIES=30
    [ "${GATE_ABSENT_TRIES:-0}" -ge 1 ] || GATE_ABSENT_TRIES=1
    [ "${GATE_READ_TRIES:-0}" -ge 1 ] || GATE_READ_TRIES=1

    gate_verdict=""; gate_line=""; gate_try=0; gate_absent=0; gate_unread=0; gate_last=""; gate_lastkind=""; gate_seen_empty=0
    gate_wait=$(( GATE_POLL_TRIES * GATE_POLL_SECS ))
    # ⛔ THE FALLBACK IS NOT `/dev/null` (review P2-2). It was, and the cleanup below then ran
    # `rm -f /dev/null` on the boxes where `mktemp` can fail AND the worker is root (a cloud cell with a
    # full/unwritable TMPDIR) — unlinking the device node, after which every later `>/dev/null` in the
    # fleet CREATES a regular file in devtmpfs and the harness runs on a corrupted /dev. A capture that
    # cannot be made is also not "no stderr": the verdict says so instead of claiming gh was silent.
    gate_errf="$(mktemp "${TMPDIR:-/tmp}/merge-$PR-gate.XXXXXX" 2>/dev/null || true)"
    gate_capture=1
    if [ -z "$gate_errf" ]; then
      # One non-mktemp fallback (a pid-suffixed path is unique per worker process); if THAT cannot be
      # written the capture is DEGRADED, and the verdict says so instead of claiming gh was silent.
      gate_errf="${TMPDIR:-/tmp}/merge-$PR-gate.$$"
      if ! : > "$gate_errf" 2>/dev/null; then gate_capture=0; gate_errf="/dev/null"; fi
    fi
    while [ "$gate_try" -lt "$GATE_POLL_TRIES" ]; do
      gate_try=$(( gate_try + 1 ))
      : > "$gate_errf" 2>/dev/null || true
      # ⛔ THE TWO STATEMENTS ARE DELIBERATELY SEPARATE: the payload is captured FIRST and its rc
      # kept, then classified. Feeding gh straight into python would make gh's documented
      # rc(1)=a check failed / rc(8)=checks pending indistinguishable from a broken read, and the
      # classifier would then be reading whatever survived the pipe.
      gate_raw="$(gh pr checks "$PR" --repo "$OR" --json name,state 2>"$gate_errf")"; gate_rc=$?
      gate="$(printf '%s' "$gate_raw" | GATE_NAME="$REVIEW_GATE" python3 -c '
import sys, json, os, re
want = (os.environ.get("GATE_NAME") or "ai-review-gate").strip()
# ⛔ EVERYTHING ECHOED INTO THE LOG GOES THROUGH `clean()` (review round 6 P2). `name` and `state` are
# TRANSPORT-CONTROLLED — a workflow name can be a YAML block scalar, and the cell gh chain (#2320) is
# hand-rolled — so a payload carrying `\n` forges a LINE in the merge log: a refused run logged
# `[merge 7] gate=SUCCESS (try 1)` through `saw=`, i.e. the record a human reads to decide whether to
# intervene positively claimed the gate was green. Control characters are collapsed to a space at this
# boundary, so no field can ever start a new line — and `saw=`/`last=` stay single-line for the same
# reason. (This is the same discipline the exception text below already applied.)
_CTRL = re.compile(r"[\x00-\x1f\x7f]+")
def clean(s):
    return _CTRL.sub(" ", str(s or "")).strip()
def canon(s):
    s = clean(s)
    if " / " in s:
        s = s.rsplit(" / ", 1)[1].strip()
    return s
raw = sys.stdin.read()
if not raw.strip():
    print("UNREADABLE the read produced no payload at all (empty response from gh pr checks)")
    raise SystemExit(0)
try:
    d = json.loads(raw)
except Exception as e:
    print("UNREADABLE the payload is not JSON (%s)" % str(e).replace("\n", " ")[:120])
    raise SystemExit(0)
rows = d if isinstance(d, list) else (d.get("check_runs") if isinstance(d, dict) else None)
if rows is None:
    # ⛔ A SCALAR PAYLOAD IS NOT AN EMPTY CHECK SET (review P2-1). `null` is what any jq-based
    # wrapper prints for a missing key, and a hand-rolled gh shim is exactly the chain #2320 measured —
    # classifying it as ABSENT reported condition (a) as condition (b) and told the operator to fix
    # the gate NAME, against the wrong bound.
    print("UNREADABLE the payload is not a check list (JSON %s)" % type(d).__name__)
    raise SystemExit(0)
if not isinstance(rows, list):
    print("UNREADABLE the payload carries no check list")
    raise SystemExit(0)
# ⛔ AN EMPTY SURFACE IS NOT A WRONG GATE NAME (review P2-1). `[]` means CI has not created a single
# check row for this head YET — the block header calls that a WAIT — so it must be charged against
# the CI window, not against the short "the gate name must be wrong" bound, and it must not inherit
# the remedy "waiting cannot help". The two facts get two tokens.
if not rows:
    print("EMPTY saw=<none: the check surface is empty>")
    raise SystemExit(0)
names = [clean(c.get("name")) for c in rows if isinstance(c, dict)]
# ⛔ A SURFACE WHOSE ROWS CARRY NO USABLE NAME IS MALFORMED, NOT A WRONG GATE NAME (review round 3
# P2-3). `[null]`, `["x","y"]` and `[{"name": null, …}]` all parse as a LIST, so they must not be
# reported as "the surface carried checks, but none is named this gate" — there was no row to name.
# Same class as the scalar payload above, one shape over: it is a TRANSPORT/shape failure.
if not any(names):
    print("UNREADABLE no row in the payload carries a usable name, so the check surface is malformed")
    raise SystemExit(0)
PEND    = ("IN_PROGRESS", "QUEUED", "PENDING", "WAITING", "REQUESTED", "EXPECTED")
NON_RED = ("CANCELLED", "STALE", "NEUTRAL", "SKIPPED")
def state_of(c):
    return clean(c.get("state")).upper()
def rank(s):
    # Allow-list polarity: 0 is the only green, and EVERY other conclusion is red — an unrecognised
    # or empty state must never fall through a gap (the merge-rail rule, applied here).
    if s == "SUCCESS": return 0
    if s in PEND:      return 2
    if s in NON_RED:   return 3
    return 4
cands = [c for c in rows if isinstance(c, dict) and canon(c.get("name")) == want]
if not cands:
    saw = "|".join([n for n in names if n][:12]) or "<none>"
    print("ABSENT want=%s saw=%s" % (want, saw))
    raise SystemExit(0)
# ⛔ NEVER FIRST-MATCH (review P1). Matching after stripping `<caller> / ` widens what can BE the gate,
# so `[{"ci / unit-test": SUCCESS}, {"unit-test": FAILURE}]` must not merge on the first row it sees:
# the explicitly-required `unit-test` row is RED there, and a first-match loop reports SUCCESS while
# discarding it — a FALSE PASS on the one surface this change made matchable at all, decided by the
# payload row order. So: EVERY row naming the gate is a candidate and the WORST one decides — the rule
# the controller applies in orch-loop.sh (`all(v=="nonred" and c=="success" ...)`), so the two cannot
# disagree. (Anything that DEDUPES rows — first-match, newest attempt per name, newest per
# (name, workflow) — was tried and defeated by the transport; see the block below.)
hit = None
for c in cands:
    # ⛔ WORST MATCHED ROW, AND NOTHING ELSE (final rule, review rounds 2-5). Every dedupe this loop
    # tried was defeated by the transport it runs on:
    #   · "first match" merged on a green `ci / unit-test` while a RED row named exactly `unit-test`
    #     was present — the verdict decided by the API row order (round 2);
    #   · "newest attempt per name" needed an orderable `startedAt`, and a QUEUED run carries `null`
    #     through the cell adapter and the Go zero time `0001-01-01...` through real gh, so an older
    #     pass won and the loop merged mid-re-run (round 4);
    #   · keying that on `(name, workflow)` cannot tell two JOBS apart: `workflow` is the app slug
    #     (`github-actions`) for every check run the cell adapter emits, and is EMPTY on real gh for
    #     non-Actions checks, so a green `compliance` row could still speak for a red `ci` one
    #     (round 5). `link`/run-id does separate them — but then the two attempts of one re-run separate too.
    # No row may be discarded, so none of that is needed: every row whose name is the gate counts and
    # the WORST state decides. That is the rule the controller already applies in orch-loop.sh
    # (`all(v=="nonred" and c=="success" ...)`), so the two classifiers cannot disagree, and it is
    # transport-independent — there is no field left to project, dedupe, sort or trust.
    if hit is None or rank(state_of(c)) > rank(state_of(hit)):
        hit = c
st = state_of(hit)
# ⛔ NAMED POLARITY, NOT A DENY-LIST (review P2-3). A non-green state is not automatically a
# FAILURE: `scripts/objective.py` records `NON_RED = {"cancelled", "stale"}` ("not green, but not
# evidence of failure") and neutral/skipped are non-red by the same allow-list rule. Labelling a
# CANCELLED gate "RED" sends an operator hunting a failing test for a superseded run. BOTH buckets
# still refuse — the distinction here is the WORDING of the verdict, never the abort.
if st == "SUCCESS":
    print("SUCCESS")
elif st in PEND:
    print("PENDING state=%s" % st)
elif st in NON_RED:
    print("NOTGREEN state=%s" % st)
elif not st:
    # Its own token: the row WAS found (so this is not a transport failure, and the UNAVAILABLE
    # wording "the read never produced a check surface" would be false here).
    print("ROWUNREADABLE the row named %s was found but carries no state field, so its polarity is unknown" % ("<" + clean(hit.get("name")) + ">"))
else:
    print("RED state=%s" % st)
' 2>>"$gate_errf")"; gate_pyrc=$?
      # The read's own words, for the one call whose silence is being interpreted (#2448). First
      # line only: the refusal this carries is `gh-core-floor remaining=<n> …` / `gh-core-exhausted
      # resets_in=<Nm>`, which is a single line, and a stack trace here would bury it.
      # ⛔ THE STDERR FIELD IS TRANSPORT-CONTROLLED TOO (review round 8 P2-2). Only `\r` used to be
      # dropped, so a shim writing ANSI escapes put `ESC[1A ESC[2K` into the log — `cat`ting it then
      # ERASES the line above and renders `[merge 7] gate=SUCCESS` for a refused merge. Same rule as
      # `clean()` on the payload: strip control characters at the boundary, not at each print site.
      gate_errline="$(head -n 1 "$gate_errf" 2>/dev/null | tr -d '\000-\010\013-\037\177' | tr -d '\r' | cut -c1-200)"
      if [ -n "$gate_errline" ]; then :
      elif [ "${gate_capture:-1}" = 1 ]; then gate_errline="<no stderr>"
      else gate_errline="<capture unavailable: no temp file could be created, so gh's stderr was NOT recorded>"
      fi
      case "$gate" in
        SUCCESS)
          gate_verdict=SUCCESS; gate_line="gate=SUCCESS (try $gate_try)"; break ;;
        RED\ state=*|NOTGREEN\ state=*)
          # ⛔ NOT GREEN DOES NOT ABORT EARLY, DELIBERATELY. The pre-#2596 loop waited the whole window
          # on a non-green gate, and that wait is not pointless: a re-run (a peer lane, `fix-one.sh`,
          # the CI daemon) can flip the same row green mid-window, and aborting on the first sighting
          # would turn that into a re-paid review next cycle. So the observation is RECORDED (and
          # logged once, as a TRANSITION line that says polling continues) while the poll window is
          # unchanged; the terminal verdict is emitted once, after the loop, only if the row never
          # turns green. The abort DIRECTION is identical to the pre-#2596 code.
          # ⛔ THE WORDING CARRIES THE POLARITY (review P2-3): `RED` only for a conclusion the repo's
          # own allow-list calls red; a CANCELLED/STALE/NEUTRAL/SKIPPED row is NON-RED and not
          # evidence of a failing test, so it says NOT GREEN instead of sending an operator hunting one.
          case "$gate" in
            RED\ state=*)      gate_kind=RED ;;
            *)                  gate_kind=NOTGREEN ;;
          esac
          # ⛔ RECORDED, NOT LATCHED (review round 7 P2-1). This used to assign `gate_line` here, and
          # nothing ever cleared it — so a gate RED at try 1 and QUEUED (a re-run in flight) at the
          # bound still ended with "RED … refusing (a red gate does not turn green by being polled
          # longer)", the opposite of the last observation and a contradiction of the transition line
          # printed two lines later. The terminal line is built BELOW from the LAST observation,
          # exactly as the EMPTY/ABSENT arms already required.
          gate_redkind="$gate_kind"; gate_redstate="${gate#* state=}"; gate_redtry="$gate_try"
          if [ "$gate_last" != "$gate_kind-$gate" ]; then
            echo "[merge $PR] gate=${gate#* state=} (${gate_kind} at try $gate_try) — still polling: a re-run can flip this row, so the window is unchanged; the abort is taken when it expires" >> "$L.log"
            gate_last="$gate_kind-$gate"; gate_lastkind="$gate_kind"
          fi
          gate_unread=0; gate_absent=0 ;;
        ABSENT\ want=*)
          gate_unread=0; gate_seen_empty=0
          gate_absent=$(( gate_absent + 1 ))
          if [ "$gate_absent" -ge "$GATE_ABSENT_TRIES" ]; then
            gate_verdict=ABSENT; gate_line="gate=NO-SUCH-CHECK ${gate#ABSENT } (absent on all $gate_absent poll(s), bound ${GATE_ABSENT_TRIES}) — the surface carried checks, but none is named this gate, so waiting cannot help; want= must match a row in saw= (a reusable-workflow job is reported as '<caller> / <job>', and want= must be the job name)"; break
          fi
          if [ "$gate_last" != "$gate" ]; then
            echo "[merge $PR] gate=NOT YET CREATED ${gate#ABSENT } (waiting, $gate_absent/$GATE_ABSENT_TRIES) — a not-yet-created check is a WAIT, not a failure" >> "$L.log"
            gate_last="$gate"; gate_lastkind=ABSENT
          fi ;;
        EMPTY*)
          # ⛔ THE CI HAS NOT STARTED FOR THIS HEAD — a WAIT, so it is the POLL bound that governs it,
          # not the short "your gate name is wrong" bound (review P2-1). The pre-#2596 code waited the
          # whole window here; charging an empty surface against GATE_ABSENT_TRIES would refuse at
          # ~150 s a gate that appears at ~240 s — a refusal this change invented.
          gate_unread=0; gate_absent=0; gate_seen_empty=1
          if [ "$gate_last" != "$gate" ]; then
            echo "[merge $PR] gate=NOT YET CREATED want=$REVIEW_GATE (the check surface is EMPTY at try $gate_try) — CI has created no check row for this head yet; a not-yet-created check is a WAIT, not a failure, so the full $GATE_POLL_TRIES poll(s) / ${gate_wait}s window applies" >> "$L.log"
            gate_last="$gate"; gate_lastkind=EMPTY
          fi ;;
        PENDING\ state=*|UNREADABLE*|ROWUNREADABLE*|CLASSIFIERFAIL*)
          # An unparseable/absent payload counts against its OWN bound; a check that is merely
          # still running counts against the poll bound (it IS the CI wait this loop exists for).
          # Both counters are CONSECUTIVE: a parsed verdict proves the transport works, so a blip
          # before it must not be charged against a later one (#2593's lesson).
          # NOTE: any non-EMPTY verdict proves CI has produced a surface, so `gate_seen_empty` clears.
          gate_seen_empty=0
          case "$gate" in
            PENDING*) gate_kind=PENDING; gate_absent=0; gate_unread=0 ;;
            *) gate_kind=UNREADABLE; gate_unread=$(( gate_unread + 1 )); gate_absent=0 ;;
               # ⛔ THE READ BOUND DOES NOT END THE RUN (review round 7 P2-2). It used to `break`, so
               # three failed reads ended the wait at ~90 s — while the transient it retries is named
               # by this worker's OWN fixture, `gh-core-floor … resets_in=4m`, which clears at ~240 s.
               # The pre-#2596 loop rode that out inside its window; breaking early turned it into a
               # refusal, and step 1 re-runs a PAID review on every re-dispatch. The counter now only
               # drives the wording; if the read is still failing when the window expires, the terminal
               # verdict is UNAVAILABLE (built below).
          esac
          if [ "$gate_last" != "$gate" ] || [ "$gate_kind" != "$gate_lastkind" ]; then
            case "$gate_kind" in
              PENDING) echo "[merge $PR] gate=PENDING ${gate#PENDING } (try $gate_try) — CI is still running; waiting up to $GATE_POLL_TRIES poll(s) / ${gate_wait}s" >> "$L.log" ;;
              *) case "$gate" in
                   ROWUNREADABLE*) echo "[merge $PR] gate=UNREADABLE rc=$gate_rc read='${gate#ROWUNREADABLE }' stderr=$gate_errline (try $gate_try/$GATE_READ_TRIES) — the row was found but has no state to read; retrying" >> "$L.log" ;;
                   *)              echo "[merge $PR] gate=UNREADABLE rc=$gate_rc read='${gate#UNREADABLE }' stderr=$gate_errline (try $gate_try/$GATE_READ_TRIES) — retrying a failed READ; nothing about the repo has been observed yet" >> "$L.log" ;;
                 esac ;;
            esac
            gate_last="$gate"; gate_lastkind="$gate_kind"
          fi ;;
        *)
          # The classifier itself produced nothing (python3 missing/killed). That is a transport
          # failure, and it must never read as `gate=` — say which one it was.
          gate_unread=$(( gate_unread + 1 )); gate_absent=0
          # ⛔ ITS OWN TOKEN (review round 8 P2-1). This arm used to leave `$gate` EMPTY while setting
          # `gate_lastkind=UNREADABLE`, so the terminal line — built from `$gate` — printed `read=''`
          # (an empty datum in the verdict #2596 exists to make legible) AND described the last
          # observation as a failed READ although the read had SUCCEEDED (rc=0, well-formed payload)
          # and it was the CLASSIFIER that died — dropping `pyrc=`, the only datum that names the
          # fault. The token carries both, so the terminal wording (below) can name the classifier.
          gate="CLASSIFIERFAIL pyrc=$gate_pyrc rc=$gate_rc stderr=$gate_errline"
          gate_kind=CLASSIFIERFAIL
          # Same as the read arm: no early break — a window that expires while the classifier cannot
          # run ends in UNAVAILABLE (below), but a classifier that recovers mid-window still wins.
          if [ "$gate_last" != "$gate" ]; then
            echo "[merge $PR] gate=UNREADABLE pyrc=$gate_pyrc rc=$gate_rc read='the classifier produced no verdict' stderr=$gate_errline (try $gate_try) — the watcher itself failed; retrying" >> "$L.log"
            gate_last="$gate"; gate_lastkind=CLASSIFIERFAIL
          fi ;;
      esac
      [ "$gate_try" -lt "$GATE_POLL_TRIES" ] || break
      sleep "$GATE_POLL_SECS"
    done
    # ⛔ THE TERMINAL VERDICT DESCRIBES THE LAST OBSERVATION, NOT THE WORST ONE (review round 7 P2-1).
    # The wait exists because a row can change while it is polled, so a verdict latched at try 1 can be
    # the opposite of what is true at the bound: RED at try 1 then QUEUED (a re-run in flight) at try 3
    # must not say "RED … does not turn green by being polled longer" — that tells the operator not to
    # wait for the exact thing the loop was waiting for — and a read that breaks late must not report a
    # repo STATE (the #2596 misclassification, inverted). `gate_lastkind` is the discriminator: every
    # arm sets it, so it always names the LAST poll's verdict kind.
    if [ -z "$gate_line" ]; then
      case "${gate_lastkind:-}" in
        RED|NOTGREEN)
          if [ "${gate_redkind:-}" = RED ]; then
            gate_verdict=RED; gate_line="gate=${gate_redstate:-<unknown>} (RED, last seen at try ${gate_redtry:-?}/$GATE_POLL_TRIES) — the gate is still not green after the wait; refusing (a red gate does not turn green by being polled longer)"
          else
            gate_verdict=NOTGREEN; gate_line="gate=${gate_redstate:-<unknown>} (NOT GREEN — a NON-RED conclusion that is not evidence of review, last seen at try ${gate_redtry:-?}/$GATE_POLL_TRIES) — refusing after the wait; re-run the check rather than hunting a failure"
          fi ;;
        ABSENT)
          gate_verdict=ABSENT; gate_line="gate=NO-SUCH-CHECK ${gate#ABSENT } (the poll window expired while the surface carried checks and none was named this gate) — want= must match a row in saw= (a reusable-workflow job is reported as '<caller> / <job>', and want= must be the job name)" ;;
        CLASSIFIERFAIL)
          # The read SUCCEEDED; the CLASSIFIER died. Say that, and carry pyrc= — the datum that names it.
          gate_verdict=UNAVAILABLE
          gate_line="gate=UNAVAILABLE ${gate#CLASSIFIERFAIL } (still failing at the end of the $gate_try-poll window) — the check surface was READ but the classifier produced no verdict, so this is a TOOLING failure (python3), not a state of the repo and not transport; nothing about the gate has been observed" ;;
        UNREADABLE|ROWUNREADABLE)
          gate_verdict=UNAVAILABLE
          case "$gate" in
            ROWUNREADABLE*) gate_line="gate=UNAVAILABLE rc=$gate_rc read='${gate#ROWUNREADABLE }' stderr=$gate_errline (still unreadable at the end of the $gate_try-poll window) — the row was FOUND and carries no state, so this is a malformed check surface, not a state of the repo" ;;
            *)              gate_line="gate=UNAVAILABLE rc=$gate_rc read='${gate#UNREADABLE }' stderr=$gate_errline (unreadable on all $gate_unread consecutive poll(s)) — the read never produced a check surface, so this is a TRANSPORT failure, not a state of the repo; the window is unchanged so a transient (gh-core-floor resets_in=…) can clear inside it" ;;
          esac ;;
        ""|EMPTY)
          if [ "${gate_seen_empty:-0}" = 1 ]; then
            gate_line="gate=NOT YET KNOWN want=$REVIEW_GATE last='the check surface was EMPTY' after $gate_try poll(s) / ${gate_wait}s — CI never created a single check row for this head, so the gate was never observable; it needs a completed '$REVIEW_GATE' check in that window"
          else
            gate_line="gate=NOT YET KNOWN want=$REVIEW_GATE last='${gate:-<nothing>}' after $gate_try poll(s) / ${gate_wait}s — the gate was never observed at all in that window"
          fi ;;
        *)
          gate_line="gate=NOT YET KNOWN want=$REVIEW_GATE last='${gate:-<nothing>}' after $gate_try poll(s) / ${gate_wait}s — the gate was still in flight when the wait expired; it needs a completed '$REVIEW_GATE' check, which CI had not produced in that window" ;;
      esac
      [ -n "$gate_verdict" ] || gate_verdict=UNKNOWN
      [ -n "$gate_line" ] || gate_line="gate=NOT YET KNOWN want=$REVIEW_GATE last='${gate:-<nothing>}' after $gate_try poll(s) — unclassified last observation (kind=${gate_lastkind:-none}); this is a gap in the verdict builder, never a pass"
    fi

    # ⛔ EXACTLY ONE terminal `gate=` line per run: every progress line above is a DIFFERENT kind
    # (`NOT YET CREATED` / `PENDING` / `UNREADABLE` / the RED transition), so the terminal verdict is
    # emitted here once and only once.
    echo "[merge $PR] $gate_line" >> "$L.log"
    [ -n "${gate_errf:-}" ] && [ "$gate_errf" != "/dev/null" ] && rm -f "$gate_errf" 2>/dev/null
    # ⛔ NOT parked, deliberately (verified by reading the controller, not assumed): the signed
    # marker IS in the PR body by here (the check above proved it, rather than trusting rc=0), so
    # this head can still merge. A park would make the loop's
    # top-of-cycle parked guard `continue` past a PR whose gate turns green a minute later — a
    # stranded merge, strictly worse than the cost of the retry. A record failure cannot be
    # stranded, which is why THAT is parked.
    if [ "$gate_verdict" != "SUCCESS" ]; then echo "[merge $PR] ABORT: not green — $gate_line (nothing merged, nothing parked)" >> "$L.log"; exit 4; fi
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
    # ⛔ TWO DIFFERENT REMEDIES LIVE HERE, and the reviewer's final line is the only thing that
    # separates them (agent-infra#2132). `ISSUES <n>` means findings exist at this head → a FIXER.
    # An EMPTY or unparseable verdict means the reviewer produced NOTHING (cap hit, kill, empty final
    # message) → there is nothing to fix and the only remedy is another REVIEW. The pre-#2132 arm
    # wrote the FIXER marker unconditionally, so every no-verdict run burned a MAX_FIX_TRIES attempt
    # on an unreviewed head and the PR could never converge.
    echo "[merge $PR] NOT CLEAN or no verdict at head=$HEAD (class=$(verdict_class "$LAST"))" >> "$L.log"
    review_state_record "$(verdict_class "$LAST")"
    REV_RECORDED=1   # either a findings marker or a no-verdict record was written above
    ;;
esac
echo "[merge $PR] end $(date)" >> "$L.log"
