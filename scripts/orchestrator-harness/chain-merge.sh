#!/usr/bin/env bash
# chain-merge.sh <repo-path> <owner/repo> <issue> <branch>
# Waits for the lane to open its PR, then runs the full review->record->merge chain.
set -u
REPO="$1"; OR="$2"; N="$3"; BR="$4"
O="${O:-$HOME/orchestrator}"; mkdir -p "$O/logs" "$O/state"
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
# ⛔ THE gh SHIM MUST STAY FIRST (#1988). The line above prepends the tool dirs, so a REAL gh in
# either of them outranks the seeded `$O/gh-rest` (Mac REST adapter) / `$O/gh-limit` (cell
# serialiser) — and a shim that is never resolved is an INERT layer: it reports protection and
# provides none. Re-assert both here, adapter last so `$O/gh-rest` (which itself calls the same
# helper) wins where it exists. Guarded by `-d`, so a box that ships neither is unchanged.
if [ -d "$O/gh-limit" ]; then PATH="$O/gh-limit:$PATH"; fi
if [ -d "$O/gh-rest" ]; then PATH="$O/gh-rest:$PATH"; fi
LOG="$O/logs/chain-$N.log"
echo "[chain $N] waiting for PR on $BR $(date)" > "$LOG"
# The instant THIS chain started. It is the epoch every capacity-refusal record is compared
# against, and it is read ONCE so the bound cannot drift while the wait runs.
CHAIN_START="$(date +%s)"

# ── the wait's own bounds — testable, and an operator knob (agent-infra#1909) ────────────────
# These were the literals 90 and 60. They are named because the CAPACITY TRANSFER regression suite
# below the loop has to prove a STALE refusal record does NOT end the wait, and it can only do that
# if it can make a bounded wait short enough to observe. Both are validated here rather than
# trusted: an unreadable value must not turn into a zero-iteration loop that exits as if the lane
# had never produced a PR (which would release the claim under a live lane — duplicate work on
# every peer, the failure R4 exists to prevent).
# `case` and not `is_num`: this script sources only `claims.sh`, and only inside the release
# function, so it has no numeric predicate of its own to borrow (same shape as claims.sh's clamp).
chk_pos_int() { case "${1:-}" in ''|*[!0-9]*|0) return 1 ;; esac; [ "${#1}" -le 9 ]; }
CHAIN_POLLS="${CHAIN_POLLS:-90}"
CHAIN_POLL_SECS="${CHAIN_POLL_SECS:-60}"
chk_pos_int "$CHAIN_POLLS" || { echo "[chain $N] WARN: CHAIN_POLLS='$CHAIN_POLLS' is not a positive integer — using 90" >> "$LOG"; CHAIN_POLLS=90; }
chk_pos_int "$CHAIN_POLL_SECS" || { echo "[chain $N] WARN: CHAIN_POLL_SECS='$CHAIN_POLL_SECS' is not a positive integer — using 60" >> "$LOG"; CHAIN_POLL_SECS=60; }

# ── ORDERING SLACK around the per-dispatch epoch bound (agent-infra#1909, round-1 review P1) ────
# ⛔ A BARE `refused_epoch >= CHAIN_START` DISCARDS REAL REFUSALS. `dispatch-merge.sh` spawns the
# LANE first and the CHAIN second, and the lane writes the record a few ms after ITS spawn while this
# chain reads `CHAIN_START` after its own — so the record is normally written BEFORE this chain reads
# its start, and the two agree only when both land in the same second. Measured: the lane's whole
# refusal path is ~4 ms and this chain reaches `date +%s` ~8-15 ms after its fork, so a second boundary
# falls between them a few percent of the time when idle — and a refusal only happens when the box is
# at capacity, which is exactly when a fork can stall past a second. The failure was SILENT and total:
# the chain logged the ordinary `no PR appeared` timeout and held `refs/claims/issue-<N>` for the whole
# 90 minutes — R8's defect, intact, for that dispatch.
#
# The slack is STRICTLY SHORTER than the RECORD'S OWN yield window (`until - epoch` — see the clamp in
# `cap_refusal_gate`), so it still cannot admit a record from an EARLIER dispatch: the refusing box
# stands down for exactly that window (`orch-loop.sh`'s `capacity_yield_live()`), so it cannot
# re-dispatch the same issue inside it, and a record older than its own window is not this dispatch's.
# ⛔ "STRICTLY" is the load-bearing word: capping the slack AT the window would admit the previous
# dispatch's record at the one second this box may first re-dispatch (round-2 review P2 — it is
# reachable from the knobs alone, e.g. `CAPACITY_YIELD_SECS=60`). 0 restores the strict comparison.
CAPACITY_REFUSAL_GRACE_SECS="${CAPACITY_REFUSAL_GRACE_SECS:-60}"
case "$CAPACITY_REFUSAL_GRACE_SECS" in ''|*[!0-9]*)
  echo "[chain $N] WARN: CAPACITY_REFUSAL_GRACE_SECS='$CAPACITY_REFUSAL_GRACE_SECS' is not a whole number of seconds — using 60" >> "$LOG"
  CAPACITY_REFUSAL_GRACE_SECS=60 ;;
esac

# ── CAPACITY TRANSFER: end a wait that can never succeed (agent-infra#1909) ──────────────────
# `lane.sh` writes `state/capacity-refused-<N>` the moment the spawn gate refuses, and the format is
# `<refused_epoch>\t<yield_until>\t<gate>` (see the writer there; it is the ONE definition).
# This is the reader that turns that refusal into "another box may take this": this chain stops
# waiting, its EXIT trap releases `refs/claims/issue-<N>` with the existing FENCED release, and
# every peer's `claim_issue_preflight` therefore answers CLEAN instead of COLLISION.
#
# ⛔ NOT RELEASING IS WHAT R8 IS ABOUT. The old shape waited 90 minutes for a PR that could not
# appear, and the claim it held made the issue ineligible on every box for those 90 minutes — so a
# per-machine capacity refusal became fleet-wide idleness, exactly the reported 2026-10-17 stall.
#
# ⛔ THE EPOCH BOUND IS THE SAFETY PROPERTY, NOT A NICETY. A record left by an earlier run of the
# same issue must never end a LIVE lane's chain: that would release the claim while the lane is
# still working, and a peer would then open a second lane for the same issue. `refused_epoch >=
# CHAIN_START` (same clock, same box) admits only a refusal from this very dispatch.
cap_refusal_gate() { # -> prints `fork|load|disk|land|capability|skew` and returns 0 iff THIS dispatch was refused by a gate
  local f="$O/state/capacity-refused-${N:-}" ep until gate grace win
  [ -n "${N:-}" ] || return 1
  case "${N:-}" in *[!0-9]*) return 1 ;; esac
  [ -r "$f" ] || return 1
  read -r ep until gate < "$f" 2>/dev/null || return 1
  case "${ep:-}" in ''|*[!0-9]*) return 1 ;; esac
  case "${until:-}" in ''|*[!0-9]*) return 1 ;; esac
  [ "${#ep}" -le 18 ] || return 1
  [ "${#until}" -le 18 ] || return 1
  # The slack is the RECORD's own stand-down window, capped by the operator knob — see above. An
  # incoherent pair (`until <= ep`) buys no slack at all: it is still evidence that a refusal happened
  # (field 1 is what this reader consumes), but it must not widen the admission window.
  win=$(( until - ep ))
  [ "$win" -lt 0 ] && win=0
  grace="$CAPACITY_REFUSAL_GRACE_SECS"
  [ "$grace" -gt "$win" ] && grace="$win"
  # ⛔ THE SLACK MUST STAY STRICTLY SHORTER THAN THE RECORD'S OWN STAND-DOWN (round-2 review P2).
  # `grace == win` does not bound the epoch rule, it CANCELS it: this box may not legitimately
  # re-dispatch the issue before `until`, so every legitimately-arriving chain satisfies
  # `ep <= CHAIN_START - win`, while admission is `ep >= CHAIN_START - grace`. With `grace == win`
  # the single second `ep == CHAIN_START - win` is admitted — an EARLIER dispatch's record ending a
  # LIVE lane's wait, whose EXIT trap then releases the claim under it so a peer opens a second lane
  # for the same issue (R4's duplicate work, the failure this bound exists to prevent).
  # It is reachable from the documented knobs alone, without any corruption: `min()` yields
  # `grace == win` IFF `CAPACITY_REFUSAL_GRACE_SECS >= CAPACITY_YIELD_SECS` — e.g. the plausible
  # `CAPACITY_YIELD_SECS=60` "one minute" tuning under the default 60s slack. So the bound is
  # enforced for EVERY accepted pairing, not only the shipped defaults (60 < 900), and the required
  # relation is stated in README §7.2d at the point a future tuning would change it.
  # `win == 0` (an incoherent `until <= ep` pair) keeps the strict `ep >= CHAIN_START` bound instead
  # of turning the slack negative — it buys no slack, exactly as documented above.
  if [ "$win" -gt 0 ] && [ "$grace" -ge "$win" ]; then grace=$(( win - 1 )); fi
  [ "$ep" -ge "$(( CHAIN_START - grace ))" ] || return 1
  # Field 3 is the REMEDY this chain reports to whoever reads the exit code (71 capability /
  # 73 fork / 74 land-backlog / 75 load / 77 disk), not a gate: an unrecognised value is reported as
  # `load` because the refusal
  # itself is already proven by fields 1-2, and refusing to end the wait over one corrupt byte is the
  # fleet-wide idleness R8 removes. `fork` is named rather than folded into `load` because its remedy is
  # the OPPOSITE of a load wait — the box must be restarted or drained from OUTSIDE (agent-infra#2293) —
  # and a chain that told its caller "load" would send the operator to wait for a retry the box cannot
  # even spawn. Its code is 73, NOT 74: 74 is the land-backlog gate below, and two gates that share a
  # code with opposite remedies make every caller mislabel one of them (measured on this integration
  # branch — the batch's own review caught it as a P0; see also spawn-gate.sh's AGENT_FORK_REFUSED).
  # Field 2 is deliberately NOT consulted here — the yield window is the controller's
  # business (`capacity_yield_live`), and an incoherent window must not make a proven refusal
  # unreadable. README §7.2d states exactly this per-reader split.
  #
  # ⛔ EVERY GATE THIS CHAIN CAN REPORT AN EXIT CODE FOR MUST BE NAMED *HERE*, OR ITS ARM BELOW IS
  # DEAD CODE (follow-up to #2991, P1, measured). This normaliser decides which arm of the loop's
  # `case "$_cap_gate"` runs, so a value it folds into `*` can never reach its own arm — however
  # carefully that arm was written. `capability` was missing here while its arm existed below, so a
  # CAPABILITY refusal exited 75 and the operator was sent to a LOAD reading that cannot explain it:
  # measured on the merged tree with a `gate=capability` record, `exit=75`, log `refused at the load
  # gate`. The arm below and this line are ONE unit; a suite arm now drives each gate through this
  # file and pins the exit code, so the pair cannot drift apart again.
  case "${gate:-}" in
    disk) printf 'disk' ;;
    fork) printf 'fork' ;;
    land) printf 'land' ;;
    capability) printf 'capability' ;;
    skew) printf 'skew' ;;
    *) printf 'load' ;;
  esac
  return 0
}

# ⛔ THE GENERATION IS INHERITED FROM WHOEVER SPAWNED THIS CHAIN, NEVER READ HERE (adversarial review).
# The handover record is keyed on the ISSUE, and the same box can hold the same issue twice while this
# chain is alive (its lease lapsed and the loop re-acquired; this chain is still waiting on a PR). A
# trap that read the record when it FIRED would fence on the newer commit — which IS the ref tip — and
# delete a live claim. Capturing at START fixed that for the trap, but a read at start is still a read
# of shared state: a chain RE-RUN by hand (both this file's own timeout message and
# nonblocking-dispatch.sh invite that) starts *after* a re-acquire, so it would capture a generation
# it never took and release the holder's claim on exit — reproduced.
# So `dispatch-merge.sh`, which spawns this chain in the same loop body that wrote the record
# milliseconds earlier, passes `CHAIN_CLAIM_COMMIT` in the environment. Nothing else sets it: a manual
# re-run has NO generation, and the refusal below then keeps the claim instead of deleting someone
# else's. That is the fail-closed direction, and it costs one lease.
CHAIN_CLAIM_COMMIT="${CHAIN_CLAIM_COMMIT:-}"

# ── release the cross-box ISSUE claim (#1850) ────────────────────────────────────────────────
# `orch-loop.sh` claimed `refs/claims/issue-<N>` when it dispatched this issue, and that claim is
# this box's declaration that the issue is IN FLIGHT. Holding it after the chain is over would keep
# a FREE issue undispatchable by every box until the lease ran out — up to CLAIM_ISSUE_TTL (4h) — so
# it is released on EVERY exit path: a clean merge, a failed one, and the "no PR appeared" timeout.
#
# ⛔ THE RELEASE IS FENCED (`--force-with-lease=<ref>:<own>`), so it refuses to delete a ref that no
# longer points at the commit THIS box pushed: a holder whose lease expired and was reclaimed by a
# peer cannot delete the winner's claim. The recorded commit is read and consumed by
# `claim_issue_release_record` (claims.sh), which is the ONE implementation of that handover — this
# function only owns the TRAP and the log line.
release_issue_claim() {
  local csh="$O/claims.sh" out rc=0
  trap - EXIT INT TERM
  [ -f "$csh" ] || return 0
  # CLAIM_REPO is the repo the claim was pushed to (refs/claims live in the TARGET repo's origin),
  # which is the value orch-loop.sh used when it acquired — a mismatch here would read the WRONG
  # repo's ref and the release would be a no-op. Every git call in claims.sh resolves the repo from
  # CLAIM_REPO itself (it `cd`s into it inside a subshell, 2026-10-18 — a `git -C` there was NOT
  # cwd-independent and returned an empty claim commit on the launchd cells), so THIS file's cwd is
  # irrelevant and no `cd` (a gated shape) is needed here.
  # ⛔ SOURCED INTO THIS SHELL, NOT A SUBSHELL, AND ITS FAILURES ARE LOGGED (2026-10-16 review).
  # `( … ) >/dev/null 2>&1 && echo released` reported SUCCESS ONLY: a refused fence, a network
  # failure, or a registry too old to HAVE the release function left the claim running to its full
  # lease with NOTHING in the chain log to say so — the operator's only signal was a missing
  # "released" line. The reason lives in CLAIM_RESULT, which a subshell discards.
  CLAIM_REPO="$REPO"
  if ! . "$csh" 2>/dev/null; then
    echo "[chain $N] ⚠️ $csh failed to source — the issue claim is NOT released (it runs to its lease, CLAIM_ISSUE_TTL=${CLAIM_ISSUE_TTL:-14400}s)" >> "$LOG"
    return 0
  fi
  if ! declare -f claim_issue_release_record >/dev/null 2>&1; then
    echo "[chain $N] ⚠️ $csh predates the issue-claim RELEASE (no claim_issue_release_record) — the claim is NOT released; fix: bash scripts/orchestrator-harness/deploy-harness.sh --repo . --o ~/orchestrator" >> "$LOG"
    return 0
  fi
  # ⛔ NO CAPTURED GENERATION → DO NOT RELEASE (acceptance-review finding). The capture at chain start
  # is empty when the handover record did not exist yet (the `claim_issue_record` in orch-loop.sh
  # failed — the loop logs that this chain cannot fence the release), when `$O/claims.sh` predates the
  # reader, or when the record exists but is unreadable. `claim_issue_release_record` treats an EMPTY
  # expectation as "read the record now", which is right for dispatch-merge.sh (its release is milliseconds after the write) but wrong
  # HERE: a chain that fires hours later would then fence on whatever generation the record holds —
  # the newer holder's own commit, which IS the ref tip — and delete a live claim. Refusing costs this
  # box one lease; deleting the wrong claim duplicates work on two boxes, so this is the fail-closed
  # side of the same asymmetry as the pre-flight. Loud, and the lease still reaps it.
  if [ -z "${CHAIN_CLAIM_COMMIT:-}" ]; then
    echo "[chain $N] ⚠️ no captured claim generation (the handover record was absent at chain start) — NOT releasing refs/claims/issue-$N: a stale chain must never delete a NEWER claim. It runs to its lease (CLAIM_ISSUE_TTL=${CLAIM_ISSUE_TTL:-14400}s)." >> "$LOG"
    return 0
  fi
  if out="$(claim_issue_release_record "$O" "$REPO" "$N" "${CHAIN_CLAIM_COMMIT:-}")"; then
    echo "[chain $N] released refs/claims/issue-$N" >> "$LOG"
  else
    rc=$?
    echo "[chain $N] ⚠️ the issue claim was NOT released (rc=$rc): ${out:-${CLAIM_RESULT:-no reason given}} — it runs to its lease (CLAIM_ISSUE_TTL=${CLAIM_ISSUE_TTL:-14400}s)" >> "$LOG"
  fi
  return 0
}
# ⛔ INT/TERM ARE SEPARATE AND THEY EXIT. A handler that only RETURNS does not terminate the shell
# for INT/TERM — bash RESUMES the interrupted command loop — so a single `trap f EXIT INT TERM`
# would release the claim and then keep WAITING 90 MINUTES for a PR that will never come. The
# handler clears all three traps on entry, so the `exit` cannot re-enter it (one release, one exit,
# and the exit status matches the signal).
trap 'release_issue_claim' EXIT
trap 'release_issue_claim; exit 130' INT
trap 'release_issue_claim; exit 143' TERM
PR=""

# ⛔ A PR-NUMBER-KEYED MARKER IS NOT PROOF FOR *THIS* REPO (reviewer finding, P1, verified).
# `state/merged-<PR>.done` and `logs/merge-<PR>.log` carry no repo, and `$O/state` is shared by every
# repo on the box, so a merge of `tortoise#<same n>` ended this chain `exit 0` ("nothing left to
# review") — skipping the review AND the merge while the lane read as done. This is the same defect
# `lane-merge.sh` fixed with `merged_confirmed`; the confirmation belongs on BOTH sides of the handoff.
# ⛔ WHILE THE MARKER IS ABSENT THE WAIT MAKES NO GITHUB CALL: a lane that is working costs nothing.
# The read happens only when `state/merged-<PR>.done` APPEARS — once per appearance, AND at most once
# per retry window (`CHAIN_CONFIRM_RETRY`, default 60s). A 15s re-poll must not turn one terminal
# question into ~120 API reads across an 1800s wait (the unguarded inside-the-loop confirmation did
# exactly that: reviewer finding, P2, measured). But asking EXACTLY once per appearance was the other
# error — the marker is never pruned, so a single rate-limited or DNS-failed read was permanent, and
# the chain went on to review and dispatch at a PR the marker said was already merged (reviewer
# finding, P2, measured). The window is the cheap middle: a bounded number of re-asks, and a
# recovered read still ends the chain.
# ⛔ THREE OUTCOMES, NOT TWO — the same contract the lane side now has (reviewer finding, P2,
# verified). "The API answered: not merged" and "the read FAILED" are different facts; collapsed, a
# rate-limited read logged `reports no merged_at` about a read that never happened and then dispatched
# merge-one.sh on a PR the marker says is merged.
#   0 → merged   1 → the API answered: NOT merged   2 → the read FAILED (not established)
chain_merged_confirmed() { # chain_merged_confirmed <pr>
  local mt rc=0
  mt="$(gh api "repos/$OR/pulls/$1" --jq '.merged_at // ""' 2>/dev/null)" || rc=$?
  [ "$rc" -eq 0 ] || return 2
  [ -n "${mt:-}" ] || return 1
  return 0
}
for i in $(seq 1 "$CHAIN_POLLS"); do
  # Checked BEFORE the PR lookup every iteration: the lane's refusal is a local file read, so this
  # costs microseconds, and it caps the transfer latency at one poll interval instead of 90 minutes.
  if _cap_gate="$(cap_refusal_gate)"; then
    case "$_cap_gate" in
      disk) _cap_rc=77 ;;
      # 73 is spawn-gate.sh's AGENT_FORK_REFUSED: the box is out of PROCESSES, so the remedy is a
      # restart or a drain from OUTSIDE — never a wait for load to fall (#2293). ⛔ 73 and not the
      # 74 this PR originally used: 74 is the LAND-BACKLOG code in the arm below, and two gates
      # sharing a code with opposite remedies is exactly the instrument false positive both issues
      # exist to delete (the batch review caught this as a P0 before it could land).
      fork) _cap_rc=73 ;;
      # 74 is spawn-gate.sh's AGENT_LAND_BACKLOG: the lane was refused because the REPO's open-PR
      # backlog is over its own measured landing ceiling (#2409), not because this box is short of
      # anything. The exit code must differ for the same reason 75 and 77 differ from each other —
      # the remedy is different — and it must be a STOP here for the same reason: no PR can appear.
      land) _cap_rc=74 ;;
      # 71 is spawn-gate.sh's AGENT_CAPABILITY_REFUSED (#2935): the box could not complete one model
      # call and RETURN. Distinct from 75 for the usual reason — the remedy differs — and it lands in
      # the SAME yield path as load, deliberately: a capability refusal is a property of THIS box, so
      # handing the issue to a peer box is exactly right (unlike `land`, which follows the item, or a
      # brief refusal, which no peer can clear). Without this arm the chain exited 75 and told the
      # operator to look at a LOAD reading for a refusal that load cannot explain.
      # ⛔ AND IT NEEDS ITS NAME IN `cap_refusal_gate`'s NORMALISER TOO — that function proves the
      # refusal, but its `case` chooses the VALUE this arm dispatches on, so folding `capability` into
      # its `*` arm made this one unreachable and put the load remedy back (follow-up to #2991, P1,
      # measured: `gate=capability` → `exit=75`, "refused at the load gate"). Both halves are pinned
      # by one behavioural table in `spawn-gate.test.sh` ("EVERY REFUSAL CODE …").
      capability) _cap_rc=71 ;;
      # 81 is spawn-gate.sh's AGENT_HARNESS_SKEW_REFUSED (follow-up review of #2991, P2): the probe RAN
      # and either rejected its own arguments (a usage/version skew between the caller and the deployed
      # helper) or died without a verdict (`rc=2` on a corrupt copy). ⛔ IT MUST NOT BE 71: every reader
      # treats 71 as a property of THIS box, so the operator is told to repair the box's pi/extension
      # set or hand the item to a peer — and the peer runs the SAME helper pair and refuses identically.
      # The chain still stops here (no PR can appear), and the EXIT trap still releases
      # refs/claims/issue-$N, because the item is fine and must not stay stranded on one box.
      skew) _cap_rc=81 ;;
      *)    _cap_rc=75 ;;
    esac
    if [ "$_cap_gate" = "land" ]; then
      echo "[chain $N] land-backlog: lane-$N was refused because the repo's open-PR backlog is over its own landing ceiling (#2409), so no PR can appear — exiting now instead of after ${CHAIN_POLLS} x ${CHAIN_POLL_SECS}s. The EXIT trap releases refs/claims/issue-$N. This is NOT a capacity transfer: the backlog is repo-wide, so handing the issue to a peer box would not clear it — the remedy is to LAND the open queue (or dispatch a P0-blocker / base-red repair, which are exempt)" >> "$LOG"
    elif [ "$_cap_gate" = "skew" ]; then
      echo "[chain $N] harness mismatch: lane-$N was refused because the lane's caller and the deployed cell-lane-preflight.sh disagree (a usage/version skew, or a corrupt copy), so the capability probe measured nothing — exiting now instead of after ${CHAIN_POLLS} x ${CHAIN_POLL_SECS}s. The EXIT trap releases refs/claims/issue-$N so the item is not stranded on this box. This is NOT a capacity transfer: every box running the same helper pair refuses identically, so handing the issue to a peer would only circulate it — the remedy is to sync the pair (cp scripts/orchestrator-harness/*.sh \$O/) wherever lanes run" >> "$LOG"
    else
      echo "[chain $N] capacity transfer: lane-$N was refused at the $_cap_gate gate, so no PR can appear — exiting now instead of after ${CHAIN_POLLS} x ${CHAIN_POLL_SECS}s. The EXIT trap releases refs/claims/issue-$N, so a peer with capacity can claim it; this box stands down via state/capacity-refused-$N for the record's yield window (agent-infra#1909)" >> "$LOG"
    fi
    exit "$_cap_rc"
  fi
  # ⛔ A PRESENT-BUT-REJECTED RECORD IS THE ONLY MISS THIS MECHANISM CAN PRODUCE, and it used to be
  # indistinguishable from a lane that simply has not opened its PR yet: the chain logged the ordinary
  # timeout and the operator had no way to tell a discarded refusal from a slow lane. Say it once (the
  # loop runs up to CHAIN_POLLS times; one line is signal, ninety are noise).
  if [ "$i" = "1" ] && [ -r "$O/state/capacity-refused-$N" ]; then
    echo "[chain $N] capacity record state/capacity-refused-$N is present but was NOT admitted as this dispatch's (epoch older than this chain's start by more than the ${CAPACITY_REFUSAL_GRACE_SECS}s slack, or older than its own yield window, unreadable, or malformed) — waiting as before. If this recurs, the lane is refusing with a record this chain cannot attribute; nothing was released (agent-infra#1909)" >> "$LOG"
  fi
  PR="$(gh pr list --repo "$OR" --state open --head "$BR" --json number --jq '.[0].number' 2>/dev/null)"
  [ -n "$PR" ] && [ "$PR" != "null" ] && break
  sleep "$CHAIN_POLL_SECS"
done
if [ -z "${PR:-}" ] || [ "$PR" = "null" ]; then
  echo "[chain $N] no PR appeared for $BR after ${CHAIN_POLLS} min (CHAIN_POLLS=${CHAIN_POLLS} x CHAIN_POLL_SECS=${CHAIN_POLL_SECS}s)" >> "$LOG"; exit 1
fi
echo "[chain $N] PR #$PR found — starting merge chain $(date)" >> "$LOG"

# ── WAIT FOR THE LANE'S MERGE PHASE (lane-owns-merge) ───────────────────────────────────────────
# The lane now OWNS the merge: after opening this PR it drives its own checks to terminal, fixes the
# reds, and supervises the same merge chain we are about to run (`lane-merge.sh` → $O/merge-one.sh).
#
# ⛔ WHY THE CHAIN MUST NOT RACE IT. merge-one.sh records the review against the head it reviewed. If
# this chain reviews at T and the lane pushes a fix at T+1, the record binds a head that is no longer
# the tip: the gate goes RED on an unchanged verdict, the review is paid for twice, and (in a rail
# repo) admin-merge refuses to move a branch with a record bound to it — so the "fix" makes the PR
# LESS mergeable. Waiting costs nothing but wall time and ZERO GitHub calls: every marker below is a
# LOCAL file the lane writes.
#
# ⛔ AND IT MUST NOT DELAY A LANE THAT PREDATES THIS (the fleet is live, old-template lanes are still
# running). So the wait is gated on the PHASE marker: a lane that never enters the merge phase writes
# none, and the chain proceeds after a short grace exactly as it always did.
PR_PHASE="$O/state/lanemerge-$PR.phase"; PR_VERDICT="$O/state/lanemerge-$PR.verdict"
PHASE_GRACE="${LANE_PHASE_GRACE:-90}"; HANDOFF_WAIT="${LANE_HANDOFF_WAIT:-1800}"
# CHAIN_POLL: how often the wait loop looks at the marker/verdict (seconds). Configurable so a suite
# can exercise several ticks without spending minutes; production leaves it at 15.
CHAIN_POLL="${CHAIN_POLL:-15}"
# ⛔ BOTH KNOBS ARE VALIDATED LIKE EVERY OTHER NUMERIC HERE (reviewer finding, P2, measured): a
# non-numeric CHAIN_POLL made `waited` never advance — `$((waited + CHAIN_POLL))` reads it as unset — so
# the HANDOFF_WAIT bound below could never fire, turning the wait into an UNBOUNDED detached process.
# The retry window is floored at the poll: a window shorter than the tick is just "every tick".
case "$CHAIN_POLL" in ''|*[!0-9]*|0[0-9]*) CHAIN_POLL=15 ;; esac
CHAIN_CONFIRM_RETRY="${CHAIN_CONFIRM_RETRY:-60}"
case "$CHAIN_CONFIRM_RETRY" in ''|*[!0-9]*|0[0-9]*) CHAIN_CONFIRM_RETRY=60 ;; esac
# ⛔ `0` PASSES THE GUARD ABOVE (the `0[0-9]*` alternative needs two characters), and a zero poll makes
# `waited` never advance while busy-spinning: an unbounded hand-off wait with no stderr to show for it
# (reviewer finding, P2, measured). `0` is this house's "do not sleep" value elsewhere, so it is
# REJECTED here rather than honoured — this loop has no other clock.
[ "$CHAIN_POLL" -ge 1 ] || CHAIN_POLL=15
[ "$CHAIN_CONFIRM_RETRY" -ge 1 ] || CHAIN_CONFIRM_RETRY=60
[ "$CHAIN_CONFIRM_RETRY" -ge "$CHAIN_POLL" ] || CHAIN_CONFIRM_RETRY="$CHAIN_POLL"
case "$PHASE_GRACE" in ''|*[!0-9]*|0[0-9]*) PHASE_GRACE=90 ;; esac
case "$HANDOFF_WAIT" in ''|*[!0-9]*|0[0-9]*) HANDOFF_WAIT=1800 ;; esac
# Portable mtime: GNU first, then BSD. GNU `stat -f %m` prints a filesystem block BEFORE it errors, so
# the reverse order captures garbage — the same trap report.sh and refresh-candidates.sh document.
_mtime() {
  local m
  m="$(stat -c %Y "$1" 2>/dev/null || true)"; case "$m" in ''|*[!0-9]*) m="" ;; esac
  if [ -z "$m" ]; then m="$(stat -f %m "$1" 2>/dev/null || true)"; case "$m" in ''|*[!0-9]*) m="" ;; esac; fi
  printf '%s' "$m"
}
# ⛔ 0 = "this verdict belongs to the CURRENT merge phase". A verdict older than the phase marker is a
# PREVIOUS attempt's (the same issue re-dispatched, or this PR re-armed after a push): reading it would
# make the chain review instantly for the NEW lane, at the head the new lane is about to change.
_verdict_is_current() {
  local v p
  v="$(_mtime "$PR_VERDICT")"; p="$(_mtime "$PR_PHASE")"
  [ -n "$v" ] || return 1
  [ -n "$p" ] || return 0          # cannot age the phase marker: trust the verdict rather than stall
  [ "$v" -ge "$p" ]
}
waited=0
while [ ! -f "$PR_PHASE" ] && [ "$waited" -lt "$PHASE_GRACE" ]; do
  sleep "$CHAIN_POLL"; waited=$((waited + CHAIN_POLL))
done
# ⛔ A PHASE MARKER IS A CLAIM ABOUT THE PRESENT, AND IT CARRIES ITS OWN CLOCK. lane-merge.sh writes
# "<issue> <epoch>"; testing only `[ -f ]` meant a lane killed at its wall limit left a marker that
# stalled this chain for the FULL HANDOFF_WAIT (30 min) on a PR nobody was working — and that 30
# minutes is exactly what pushes the issue claim past its lease. The epoch is right there: read it.
_phase_age() {
  local e; e="$(awk '{print $2}' "$PR_PHASE" 2>/dev/null)"; case "$e" in ''|*[!0-9]*) e=0 ;; esac
  [ "$e" -gt 0 ] && printf '%s' "$(( $(date +%s) - e ))" || printf '%s' "-1"
}
_PHASE_AGE="$(_phase_age)"
# The lane's own wall clock bounds how long its marker can mean anything (LANE_TIMEOUT, +60s slack).
# ⛔ THAT CLOCK IS `LANE_BACKSTOP_S`, NOT 3300 ANY MORE (agent-infra#2888). The wall stopped being the
# lane's PRIMARY bound — the progress allowance (45 min) is — and the backstop above it is 7200 s. A
# literal 3300 here would declare a still-working lane's merge marker STALE at 56 minutes while the
# lane may legitimately run to its 2 h backstop, and this block's response to a stale marker is to
# DELETE it and review at the tip — i.e. two processes on one PR. `LANE_BACKSTOP_S` is exported by
# `spawn-gate.sh`, so a lane's chain inherits the operator's override; the literal is the fallback for
# a chain started outside a lane shell, and `lane-bound.test.sh` (i0) pins it to that seam.
_PHASE_STALE_AFTER="${LANE_TIMEOUT:-${LANE_BACKSTOP_S:-7200}}"
case "$_PHASE_STALE_AFTER" in ''|*[!0-9]*|0[0-9]*) _PHASE_STALE_AFTER=7200 ;; esac
_PHASE_STALE_AFTER=$(( _PHASE_STALE_AFTER + 60 ))
if [ -f "$PR_PHASE" ] && [ "$_PHASE_AGE" -ge 0 ] && [ "$_PHASE_AGE" -gt "$_PHASE_STALE_AFTER" ]; then
  echo "[chain $N] STALE merge-phase marker (age ${_PHASE_AGE}s > lane wall limit ${_PHASE_STALE_AFTER}s) — the lane is gone; reviewing at the tip now" >> "$LOG"
  rm -f "$PR_PHASE"
fi
if [ -f "$PR_PHASE" ]; then
  echo "[chain $N] the lane is in its merge phase (state/lanemerge-$PR.phase, age ${_PHASE_AGE}s) — waiting for its verdict before reviewing, so the review binds the FINAL head" >> "$LOG"
  waited=0
  MERGED_CONFIRMED=0
  _marker_read=0
  _marker_read_at=0
  while [ "$waited" -lt "$HANDOFF_WAIT" ]; do
    # A lane that merges its PR leaves merge-one's own marker; stop waiting on it, not on our clock —
    # but only once the API CONFIRMS this repo's PR is merged (see chain_merged_confirmed).
    if [ -f "$O/state/merged-$PR.done" ]; then
      # ⛔ ONE QUESTION PER APPEARANCE **OR PER RETRY WINDOW**, WHICHEVER COMES FIRST (reviewer
      # finding, P2, measured). Asking exactly once per appearance made a SINGLE transient read
      # failure permanent: `merged-<PR>.done` is never pruned, so after one rate-limited or
      # DNS-failed read the chain never asked again — it waited out HANDOFF_WAIT and then reviewed
      # and dispatched at a PR the marker said was already merged. Asking on every tick is the
      # defect the gate fixed (~120 reads per wait). A retry window is both.
      _mk_now="$(date +%s)"
      if [ "${_marker_read:-0}" = 0 ] || [ $((_mk_now - ${_marker_read_at:-0})) -ge "$CHAIN_CONFIRM_RETRY" ]; then
        _marker_read=1; _marker_read_at="$_mk_now"   # see the contract at the top
        chain_merged_confirmed "$PR"; _cmc=$?
        case "$_cmc" in
          0) MERGED_CONFIRMED=1; break ;;
          1) echo "[chain $N] state/merged-$PR.done exists but repos/$OR/pulls/$PR reports no merged_at — the marker may belong to another repo's PR #$PR; still waiting" >> "$LOG" ;;
          2) echo "[chain $N] could not READ the merge confirmation for PR #$PR (gh failed) — the marker is not proof either way; still waiting, and re-asking in ${CHAIN_CONFIRM_RETRY:-60}s" >> "$LOG" ;;
        esac
      fi
    else
      _marker_read=0; _marker_read_at=0   # the marker is gone: a NEW appearance is a new question
    fi
    # ⛔ A VERDICT IS NOT NECESSARILY A HANDOFF (reviewer finding, reproduced). lane-merge.sh records
    # EVERY loop outcome, including the mid-loop tokens that TELL THE LANE TO PUSH A FIX. Treating
    # `FIX_REQUIRED` as "the lane handed off" reviewed at the pre-fix head and stranded the
    # attestation — exactly what the wait exists to prevent. Only a BLOCKED_*/terminal verdict hands
    # off; MERGED ends the chain; the rest mean "keep waiting".
    if [ -s "$PR_VERDICT" ] && _verdict_is_current; then
      _tok="$(cut -d' ' -f1 "$PR_VERDICT" 2>/dev/null)"
      case "$_tok" in
        MERGED|BLOCKED|BLOCKED_ATTESTATION|BLOCKED_ATTEMPTS|BLOCKED_CLOSED) break ;;
        *)
          # Anything else means the lane has not finished (FIX_*, WAITING_*): keep waiting, and say
          # so ONCE rather than every 15 seconds.
          if [ "${_said_waiting:-0}" = 0 ]; then
            echo "[chain $N] the lane is still working ($_tok) — not reviewing yet; the review must bind the FINAL head" >> "$LOG"
            _said_waiting=1
          fi ;;
      esac
    fi
    sleep "$CHAIN_POLL"; waited=$((waited + CHAIN_POLL))
  done
  if [ "${MERGED_CONFIRMED:-0}" = 1 ]; then
    echo "[chain $N] PR #$PR is MERGED by the lane's own merge phase — nothing left to review" >> "$LOG"
    # release_issue_claim clears the EXIT/INT/TERM traps itself, so no second `trap -` is needed.
    release_issue_claim
    echo "[chain $N] done $(date)" >> "$LOG"
    exit 0
  fi
  if [ -s "$PR_VERDICT" ]; then
    case "$(cut -d' ' -f1 "$PR_VERDICT" 2>/dev/null)" in
      MERGED)
        # A VERDICT IS A CLAIM TOO: lane-merge writes it, but the API is what says the PR is merged.
        chain_merged_confirmed "$PR"; _vmc=$?
        case "$_vmc" in
          0) echo "[chain $N] the lane's verdict is MERGED and the API confirms it — nothing left to review: $(cat "$PR_VERDICT")" >> "$LOG"
             release_issue_claim
             echo "[chain $N] done $(date)" >> "$LOG"
             exit 0 ;;
          1) echo "[chain $N] the lane's verdict says MERGED but repos/$OR/pulls/$PR reports no merged_at — reviewing at the tip instead: $(cat "$PR_VERDICT")" >> "$LOG" ;;
          # NOT ESTABLISHED: review at the tip too. The chain's product is a REVIEW, and refusing to
          # review on an unreadable API would strand the lane behind a rate limit.
          2) echo "[chain $N] could not READ the merge confirmation for PR #$PR (gh failed) — the MERGED verdict is not established; reviewing at the tip: $(cat "$PR_VERDICT")" >> "$LOG" ;;
        esac ;;
      *)
        echo "[chain $N] the lane handed off ($(cat "$PR_VERDICT")) — reviewing at the head it left behind" >> "$LOG" ;;
    esac
  else
    echo "[chain $N] ⚠️ no verdict after ${HANDOFF_WAIT}s (the lane's wall limit, or it died) — reviewing now; if the lane is still alive its next push re-arms the PR" >> "$LOG"
  fi
else
  echo "[chain $N] no merge-phase marker after ${PHASE_GRACE}s (a pre-merge-phase lane, or it failed before the PR) — reviewing now, as before" >> "$LOG"
fi

bash "$O/merge-one.sh" "$REPO" "$OR" "$PR" "$BR" >> "$LOG" 2>&1
rc=$?
# A load refusal (75) is not a failure of the work: nothing ran and nothing was consumed. Name it
# HERE, in the log the operator reads for this chain — the reviewer's own line is inside
# merge-$PR.log, and on a box with no controller running nothing else would ever re-dispatch it.
echo "[chain $N] merge-one rc=$rc $(date)" >> "$LOG"
if [ "$rc" = "75" ]; then
  echo "[chain $N] reviewer NOT started (load gate) — re-run this chain (or let the controller re-dispatch it) when 1-min load is below MAX_LOAD" >> "$LOG"
fi
echo "[chain $N] done $(date)" >> "$LOG"
# ⛔ EXIT WITH merge-one.sh's STATUS (#1720 review). This script used to end on the `echo …done…`
# above, so `$?` was the STATUS OF `echo` — always 0 — and a caller doing `chain-merge.sh … && next`
# took the success branch whatever happened.
# ⚠️ WHAT THIS DOES NOT YET FIX (review round 2026-10-15): `merge-one.sh` ITSELF still ends on a
# reporting `echo` and contains no `exit 75` / `AGENT_STARTED` (0 hits), so on the paths that reach
# its end — a reviewer that FAILED, and a clean pass — it returns 0, and the refusal branch BELOW is
# FORWARD-LOOKING. Its early guards do exit 1/2/3/4, and those propagate now; the 75 will propagate
# once the blocked `#8521` half lands in merge-one.sh (PR #1769/#1730 hold that file). Until then the
# reporting lines stay truthful about a refusal while the EXIT CODE cannot distinguish a refused
# reviewer from a successful one. Recorded in port-provenance.txt as a residual, not claimed as done.
exit "$rc"
