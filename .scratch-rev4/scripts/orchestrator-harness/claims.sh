#!/usr/bin/env bash
# claims.sh — cross-box claim registry for the agent PR fleet.
# Implements agent-infra#1709 recommendations 1–3 (+ the fencing half of rec 6, + rec 4's jitter
# lives in orch-loop.sh where the poll interval is).
#
# THE PROBLEM. The harness already has a per-PR claim: `state/mergeclaim-<PR>.lock`, created
# with `set -o noclobber`. That is atomic — on ONE machine. With three boxes driving one repo
# it does nothing across boxes: three boxes pick the same PR and the same issue. The research
# (agent-infra#1709, 5 Perplexity queries, ~60 citations) is unanimous that no mechanism
# guarantees two machines never execute the same job under crashes, pauses or partitions, so
# the goal is single active ownership + safe duplicate handling (at-least-once, not
# exactly-once).
#
# WHY A GIT REF. The boxes already share exactly one durable store: the repository. Creating a
# ref with `git push` is ATOMIC — it fails if the ref already exists — so `refs/claims/<key>`
# is a genuine compare-and-swap with no new infrastructure, no broker and no service to run.
# The loser of the race sees the failure and backs off.
#
# WHY `refs/claims/*` AND NOT `refs/heads/claim/*`. As a branch it would fire
# branch-triggered workflows and clutter the branch list. `refs/claims/*` is outside the branch
# namespace and matches no `on: push:` trigger in any workflow — VERIFIED EMPIRICALLY 2026-10-14 on
# both daniel-ospina/agent-infra and daniel-ospina/tortoise: a probe push to refs/claims/* created
# zero workflow runs and zero check-runs, and every `on: push` in both repos is filtered to
# `branches: [main]` or `tags`.
#
# KEY = <PR>-<head-sha12>, NOT <PR> (rec 1). Identity must be content-addressed, the same lesson
# as a Bazel/Nx cache key: two boxes reviewing the SAME head is duplicate work, a box reviewing
# a NEWER head is new work. Keying on the SHA makes the claim idempotent per content version
# and stops a pushed-update PR from being blocked by a stale claim for its predecessor head.
# This is also the defect #1709 found in the existing lock: it is keyed on <PR> alone.
#
# ⛔ REC 1 STANDS, AND THE LANDING PATH NEEDS A SECOND KEY ON TOP OF IT (agent-infra#1952).
# `<PR>-<sha12>` says "this head", never "this PR" — two boxes looking at ONE PR at two DIFFERENT
# heads mint two DISTINCT keys and each wins its own CAS. That is correct for review (a pushed
# update IS new work, and a duplicate review is a tolerated duplicate comment), and WRONG for
# landing a merge: the one operation whose duplicate does not degrade to at-least-once, because a
# second landing attempt lands on a MOVED head with evidence bound to the old one (#1908's
# per-operation table — measured as row M3 of its claim-exclusion measurement). So landing takes the
# coarser `pr-<N>` key BELOW as well — the two are complementary, and neither is re-keyed.
#
# LEASE = DATA, NOT LIVENESS (rec 3). Git refs have no TTL and a remote owner's pid cannot be
# probed (`kill -0` is meaningless across boxes — the existing `claim_live()` relies on it).
# ⛔ ONE EXCEPTION, ADDED BY agent-infra#2094: a pid on THIS box CAN be probed, and an owner whose
# host is this box names a pid this box can check. That local rule is why `claim_orphan_reason`
# exists; the remote case still has no probe, which is why an orphaned REMOTE holder needs a roster
# (this box's own former names, `CLAIM_DEAD_HOSTS`, or `CLAIM_KNOWN_HOSTS`) rather than a probe.
# So the claim commit's message carries `owner` and `lease_until`; every box treats an expired
# claim as free and reclaims it with a CAS, not with a blind force — and treats an ORPHANED one the
# same way, because a holder that cannot be a live lane makes its term irrelevant.
#
# FENCING (rec 6). Every mutation after acquisition is conditional on the observed SHA of the
# claim ref (`--force-with-lease=<ref>:<sha>`). A box holding a STALE commit — one that is no longer
# the ref's tip, because it was superseded or reclaimed — cannot release, and cannot reclaim,
# another box's claim: its write is rejected. That is what makes a stale owner's write impossible
# rather than merely unlikely.
# ⛔ The fence is on the ref's VALUE, not on ownership (P3.1, 2026-10-14 adversarial review): it
# stops a STALE write; it does NOT stop a caller who happens to pass the ref's CURRENT sha. Every
# shipped call site passes only the sha it pushed (`$CROSS_OWN` / `$CLAIM_COMMIT`), which is what
# makes the property hold in practice.
#
# COST. Acquisition is ONE push. `claim_snapshot()` refreshes every claim in ONE fetch per
# cycle, so the sweep never pays a network round trip per PR.

set -u

CLAIM_NS="${CLAIM_NS:-refs/claims}"
CLAIM_CACHE_NS="${CLAIM_CACHE_NS:-refs/claims-cache}"
# Worker-side lease-READ temp refs live in their OWN namespace, never in CLAIM_CACHE_NS.
# ⛔ `claim_snapshot` fetches with `--prune` and an explicit destination refspec, and `--prune` with
# an explicit destination prunes anything matching the DESTINATION pattern (`refs/claims-cache/*`)
# — not just refs that came from the source. The controller and the workers share ONE repo
# (CLAIM_REPO="$REPO"), so a snapshot fetch used to delete a concurrent worker's `read-…` /
# `status-…` / `prune-…` temp ref mid-read; `_lease_of` then returned "?\t0", and an unparseable
# lease is treated as NOT EXPIRED (never stolen — since #3203 that abstention is REPORTED as
# `unreadable`, never as live), so the merge was refused while nobody owned it — every cycle
# (P2, 2026-10-14 adversarial review). Keeping temp refs out of the pruned namespace removes the
# race. If you add a temp ref anywhere below, put it under CLAIM_TMP_NS.
CLAIM_TMP_NS="${CLAIM_TMP_NS:-refs/claims-tmp}"
CLAIM_TTL="${CLAIM_TTL:-1800}"   # 30 min default lease
# ⛔ EVERY LEASE MUST BE A MAGNITUDE, NOT JUST A DIGIT STRING (P2, third review round, 2026-10-14).
# `ttl` feeds `until=$(( now + ttl ))`, and a ttl at or above 2**63 WRAPS that NEGATIVE. `_lease_of`'s
# `sed` match is anchored and spelled with the ASCII digits themselves (POSIX ranges are collation
# questions), so it cannot parse a minus sign either — the lease reads as absent: an unparseable claim,
# which every reader refuses and (before agent-infra#3203's bounded arm) `claim_prune` could never
# reap (`[ "$now" -gt "-" ]` is an error, not a match). One bad tunable therefore froze a PR/head
# across ALL boxes: FAIL-CLOSED, the opposite of this file's stated fail-open policy. The callers validate
# their own tunables with `is_limit`; this clamps the primitive as well, so NO caller can mint an
# unprunable lease. Accept only `0` or `[1-9][0-9]*` (leading zeros are read as octal by `$(( ))`),
# at most 9 digits (9 digits + an epoch second cannot overflow).
case "${CLAIM_TTL:-}" in
  ''|*[!0123456789]*|0*) CLAIM_TTL=1800 ;;
  *) [ "${#CLAIM_TTL}" -le 9 ] || CLAIM_TTL=1800 ;;
esac

# ── THE ISSUE CLAIM'S LEASE (agent-infra#1850) ────────────────────────────────────────────────
# An ISSUE claim is held for the WHOLE working period of its lane, not for one push. The PR claim's
# 1800s default covers a review+merge; the issue claim must cover the lane's own budget plus the
# chain that follows it, or it expires MID-FLIGHT, a peer reads it as free and reclaims it, and the
# duplicate dispatch this file exists to prevent happens anyway. The arithmetic, from the shipped
# defaults (orch-loop.sh's LANE_TIMEOUT is orch-loop.sh's own variable and is NOT readable here):
#
#   lane (LANE_BACKSTOP_S)        7200s   (~2 h — spawn-gate.sh's ABSOLUTE BACKSTOP; the lane's
#                                            PRIMARY bound is lane-bound.sh's 2700 s progress
#                                            allowance. This term was 3300s until agent-infra#2888
#                                            demoted the wall clock to a backstop)
#   chain-merge.sh waits for the PR 5400s  (90 x 60s) — it exits AT ONCE when the lane recorded a
#                                           capacity refusal, releasing this claim within a poll
#                                           interval (agent-infra#1909), so the ceiling below is a
#                                           ceiling and no longer the normal cost of a refused lane
#   chain-merge.sh merge-phase wait 1890s  (LANE_PHASE_GRACE 90 + LANE_HANDOFF_WAIT 1800, #2029)
#   merge-one.sh review+merge      ~3000s  (REVIEW_TIMEOUT + _gw + 300 — `_gw` is the gate wait,
#                                           900 s at the defaults, so 1800+900+300; NOT a constant
#                                           1200, and the `REVIEW_TIMEOUT + 1200` form that stood
#                                           here was right only at that default)
#                                 ------  =======
#                                 17490s  -> 18000s (5 h)
#
#   ⛔ THIS SUM IS THE DEFAULT-GATE-WAIT SUM, AND THE ROW ABOVE IS WHY IT IS STATED AS A FORMULA.
#   `_gw` is `GATE_POLL_TRIES x GATE_POLL_SECS` clamped to [900, 86400] (merge-one.sh), so on a box
#   running `GATE_POLL_SECS=60` the merge term is 3900 s and this sum is 18390 s — OVER the 18000 s
#   default below. Nothing here raises that default (it is a behaviour change, not a prose fix); the
#   arithmetic is written out so the operator who raises the gate wait sees which default it crosses.
#
# ⚠️ THIS IS A CEILING, NOT A PREDICTION. The holder RELEASES on completion (chain-merge.sh, every
# exit path) and on the failure/abandon paths, so the lease only ever runs its full length when the
# box dies mid-lane. ⛔ RAISING ANY TERM OF THIS SUM WITHOUT RAISING THIS LEAVES A CLAIM THAT EXPIRES
# BEFORE THE LANE FINISHES — a peer then reads the claim as free and reclaims it, which is the
# DUPLICATE DISPATCH this file exists to prevent (agent-infra#1850). #2029 raised TWO terms
# (LANE_TIMEOUT +900s, and the new merge-phase wait +1890s) and this default moved with them in the
# same commit; any future change to one of the four must do the same, or override CLAIM_ISSUE_TTL
# (env, or the cell's keys.env). ⛔ #2888 RAISED THE FIRST TERM (3300 -> 7200) and this default moved
# with it in the same commit (14400 -> 18000) — the review caught it moving WITHOUT the default, which
# is exactly the mid-flight expiry this paragraph predicts.
# The same digit clamp as CLAIM_TTL: an unparseable lease is worse than the default (see above).
CLAIM_ISSUE_TTL="${CLAIM_ISSUE_TTL:-18000}"
case "${CLAIM_ISSUE_TTL:-}" in
  ''|*[!0123456789]*|0*) CLAIM_ISSUE_TTL=18000 ;;
  *) [ "${#CLAIM_ISSUE_TTL}" -le 9 ] || CLAIM_ISSUE_TTL=18000 ;;
esac

# ── THE BRANCH CLAIM'S LEASE (agent-infra#3328) ─────────────────────────────────────────────
# ⛔ THE CEILING IS THIS KEY'S OWN TERM (14400), AND `CLAIM_TTL_MAX` DOES NOT APPLY TO IT.
# `claim_branch_acquire` passes `CLAIM_BRANCH_TTL` as BOTH the default and the ceiling (its 3rd and 4th
# args to `_claim_acquire_at`), so a caller cannot mint a longer term while a batch legitimately
# outlives the PR/merge ceiling: 14400 is ABOVE `CLAIM_TTL_MAX`'s 9600 default, deliberately, and a
# clamp to `CLAIM_TTL_MAX` would expire a live batch mid-flight.
# A BATCH BRANCH is held for the whole batch, which is longer than any single lane: the owner takes
# it before the first lane pushes and releases it after the last one lands. Its term is therefore its
# own, not the PR claim's 1800s — a batch claim that expires MID-BATCH lets a peer reclaim it and
# push, which is the exact loss this key exists to prevent. Raising the env var raises the default and
# the ceiling together, so the term stays a single knob and never splits into "longer than its own
# clamp". *(This block is the one #3328 comment that contradicted ITSELF: it said "not CLAIM_TTL_MAX"
# and then "capped by CLAIM_TTL_MAX", and it cited CLAIM_TTL_MAX as 7200 when the value is 9600. The
# assertions that pin the real behaviour are `branch-claim.test.sh` case 10.)*
# ⛔ THE HOLDER RELEASES ON COMPLETION, so the full term is only ever spent by a box that died.
CLAIM_BRANCH_TTL="${CLAIM_BRANCH_TTL:-14400}"
case "${CLAIM_BRANCH_TTL:-}" in
  ''|*[!0123456789]*|0*) CLAIM_BRANCH_TTL=14400 ;;
  *) [ "${#CLAIM_BRANCH_TTL}" -le 9 ] || CLAIM_BRANCH_TTL=14400 ;;
esac

# ── THE LEASE CEILING (agent-infra#2094) ──────────────────────────────────────────────────────
# ⛔ `CLAIM_TTL_MAX` IS A CEILING, NOT THE DEFAULT, and the difference is load-bearing. The shipped
# merge/fix paths lease a PR claim for MORE than `CLAIM_TTL` on purpose, because the lease must cover
# the review+merge the claim is taken for:
#     merge-one.sh   CLAIM_LEASE=$(( ${REVIEW_TIMEOUT:-1800} + _gw + 300 ))  -> 3000s at the defaults
#                    (`_gw` is the gate wait, 900 s at the defaults — NOT a constant 1200)
#     fix-one.sh     FIX_LEASE=$(( ${FIX_TIMEOUT:-$LANE_BACKSTOP_S} + 1200 )) -> 8400s
#                    (3600s before agent-infra#2888: the fixer ran 2400 s, now the 7200 s backstop)
# So a clamp at 1800 would expire a claim MID-MERGE and hand the same head to a peer — the duplicate
# work this registry exists to prevent. But before this bound there was no ceiling at ALL: the only
# check was "at most 9 digits", so a caller could mint `lease_until = now + 999999999` (31 years) —
# the silent extension the #2094 incident exposed, a term no reaper's reach outlives.
# ⚠️ THE CEILING IS COUPLED TO THOSE TWO CALLERS, exactly as CLAIM_ISSUE_TTL is coupled to LANE_TIMEOUT.
# A caller's lease is `timeout + 1200` (`FIX_LEASE`, fix-one) or `timeout + _gw + 300` (`CLAIM_LEASE`,
# merge-one — `_gw` is the gate wait, 900 s at the defaults, so that lease is 3000 s and the clamp
# threshold is `CLAIM_TTL_MAX - (_gw + 300)` = 8400 s), so raising either timeout past
# `CLAIM_TTL_MAX - 1200` (the fixer) or `CLAIM_TTL_MAX - (_gw + 300)` (the reviewer) makes
# `_claim_acquire_at` CLAMP the lease below what the worker asked for, spending the post-review
# headroom — and above `CLAIM_TTL_MAX` itself the claim expires under a worker that is still running,
# which is the mid-review expiry this block exists to prevent. So raise CLAIM_TTL_MAX at the same
# time. The clamp is not silent: it reports itself on stderr. ⛔ The single `- 1200` form that used to
# stand here was right only for the fixer and only at the default gate wait.
# Same digit clamp as the two TTLs above: an unparseable ceiling is worse than the default.
CLAIM_TTL_MAX="${CLAIM_TTL_MAX:-9600}"   # 2 h 40 m — above fix-one's 8400s lease, the longest shipped one
case "${CLAIM_TTL_MAX:-}" in
  ''|*[!0123456789]*|0*) CLAIM_TTL_MAX=9600 ;;
  *) [ "${#CLAIM_TTL_MAX}" -le 9 ] || CLAIM_TTL_MAX=9600 ;;
esac
[ "$CLAIM_TTL_MAX" -ge "$CLAIM_TTL" ] || CLAIM_TTL_MAX="$CLAIM_TTL"

# ── THE BOUNDED EXPIRY FOR A LEASE NO READER CAN PARSE (agent-infra#3203) ─────────────────────
# ⛔ THE CLASS THIS BOUNDS, AND WHY IT NEEDED ITS OWN BOUND. `_lease_unparseable` names a claim that
# EXISTS whose term this reader cannot read (an absent value, the `0` sentinel, a negative, any
# non-digit, 19+ digits). The STEAL guard is right to refuse it: `claims.sh`'s own record of the
# 2026-10-14 incident is that an errored `[` at or above 2**63 tested FALSE and STOLE a live claim.
# But REFUSING TO STEAL IS NOT REFUSING TO REAP — and before this bound nothing in the fleet could
# reap one: the expiry arm read the term as live, and `claim_prune`'s orphan arm was explicitly
# skipped for this class, so the ONLY cure was a human `git push origin :refs/claims/<key>`. That is
# the #8175 shape (a gate clearable only by hand), and a batch claim that folds N PRs inherits it N
# times (#3203).
#
# The bound is on the claim COMMIT's own committer time — NOT on the lease (the very datum that
# cannot be read) and NOT on a ref mtime (`claim_prune` already says why for its temp-ref arm: an
# mtime is when THIS checkout last touched the ref). 18000 = `CLAIM_ISSUE_TTL`, the LONGEST lease any
# shipped caller mints (see the arithmetic above), so a claim whose commit is older than this has
# outlived every term it could possibly have carried.
# ⛔ IT IS A BOUND ON WAITING, NOT A LICENCE TO STEAL. Only `claim_prune` acts on it, and only by
# DELETING a ref on an output line that names the fault; every READER keeps answering ABSTENTION, so
# nothing is ever "granted" by the passage of time — a reader that treated age alone as expiry would
# be the fail-open the steal guard exists to prevent.
# ⛔ AND AN UNMEASURABLE AGE IS NOT EVIDENCE OF EXPIRY: no committer line, an unparseable stamp, or a
# stamp AHEAD of this box's clock keeps the claim and NAMES it on every pass. That is the honest
# floor: the operator sees the class instead of having it guessed away.
CLAIM_UNREADABLE_LEASE_MAX_AGE="${CLAIM_UNREADABLE_LEASE_MAX_AGE:-18000}"
case "${CLAIM_UNREADABLE_LEASE_MAX_AGE:-}" in
  ''|*[!0123456789]*|0*) CLAIM_UNREADABLE_LEASE_MAX_AGE=18000 ;;
  *) [ "${#CLAIM_UNREADABLE_LEASE_MAX_AGE}" -le 9 ] || CLAIM_UNREADABLE_LEASE_MAX_AGE=18000 ;;
esac
# ⛔ AND A FLOOR, OR THE BOUND IS A SCHEDULED STEAL (review round 19, agent-infra#3203). The ceiling
# below stops a ~31-year bound from re-creating the eternal block; WITHOUT a floor the same knob does
# the OPPOSITE and far worse thing: `CLAIM_UNREADABLE_LEASE_MAX_AGE=1` makes the unattended hourly
# `claim_prune` reap an unparseable-lease claim SECONDS after it was minted — i.e. it deletes a peer's
# LIVE claim on a schedule, which is the steal direction this whole arm exists to refuse (the failed
# test that produced the 2**63 rule was a mis-polarised comparison STEALING a live claim). A bound
# below the longest lease any caller can mint can always fire INSIDE a live term, so it is not a
# bound at all.
# ⛔ CALIBRATED ON THE LONGEST MINTABLE TERM, NOT ON ONE KNOB (review round 20). `CLAIM_ISSUE_TTL` is
# NOT the longest lease this file can mint: `CLAIM_BRANCH_TTL` (branch claims) and `CLAIM_TTL_MAX`
# (PR/fix leases) are each first-class overrides with their own digit clamps above, and either can be
# raised PAST `CLAIM_ISSUE_TTL` — measured, `CLAIM_BRANCH_TTL=40000` mints `lease_until = now + 40000`
# (a `until - now` delta reads 39996 only because it is taken seconds after the mint; the mint site is
# `_claim_acquire_at`'s `until=$(( now + ttl ))`), while a floor nailed to 18000 would reap that live
# branch claim ~22 000 s inside its own term,
# re-creating exactly the bug this block closes, one knob over. So the FLOOR TERM is the max of all
# three, computed once into an internal (`_claim_`-prefixed like the helpers, never a knob): the ceiling
# has to be compared against the TERM, not against whatever the operator configured, or the legitimate
# "an absurd configured bound is clamped to 7 days" rule below would be defeated by it.
_claim_floor_term="$CLAIM_ISSUE_TTL"
[ "$CLAIM_BRANCH_TTL" -gt "$_claim_floor_term" ] && _claim_floor_term="$CLAIM_BRANCH_TTL"
[ "$CLAIM_TTL_MAX" -gt "$_claim_floor_term" ] && _claim_floor_term="$CLAIM_TTL_MAX"
# ...and the term is capped at the SAME 30-day literal the ceiling is hard-capped to, or a 9-digit
# `CLAIM_TTL_MAX=999999999` makes the floor ~31 years and the ceiling-vs-floor rule below raises the
# CEILING to match it — the floor would then BE the eternal hold this change exists to end.
[ "$_claim_floor_term" -gt 2592000 ] && _claim_floor_term=2592000
[ "$CLAIM_UNREADABLE_LEASE_MAX_AGE" -lt "$_claim_floor_term" ] \
  && CLAIM_UNREADABLE_LEASE_MAX_AGE="$_claim_floor_term"
# ⛔ AND A CEILING, OR THE BOUND IS DECORATIVE (review, agent-infra#3203). A 9-digit value is ~31
# years: `CLAIM_UNREADABLE_LEASE_MAX_AGE=999999999` in an ambient environment re-creates the exact
# eternal block this arm exists to end, while looking like a configured bound. 7 days is far past
# every shipped lease (1800-14400 s) and still bounded, so a typo cannot put the gate back.
CLAIM_UNREADABLE_LEASE_MAX_AGE_CEIL="${CLAIM_UNREADABLE_LEASE_MAX_AGE_CEIL:-604800}"
case "${CLAIM_UNREADABLE_LEASE_MAX_AGE_CEIL:-}" in
  ''|*[!0123456789]*|0*) CLAIM_UNREADABLE_LEASE_MAX_AGE_CEIL=604800 ;;
  *) [ "${#CLAIM_UNREADABLE_LEASE_MAX_AGE_CEIL}" -le 9 ] || CLAIM_UNREADABLE_LEASE_MAX_AGE_CEIL=604800 ;;
esac
# ⛔ THE CEILING ITSELF IS HARD-CAPPED (review, agent-infra#3203): an override that can raise the
# ceiling only re-opens the hole from one level up, so 30 days is a LITERAL, not a knob.
[ "$CLAIM_UNREADABLE_LEASE_MAX_AGE_CEIL" -gt 2592000 ] && CLAIM_UNREADABLE_LEASE_MAX_AGE_CEIL=2592000
# ⛔ AND THE CEILING CANNOT UNDERCUT THE FLOOR TERM (review round 20, agent-infra#3203). The hard cap
# above only fixes an absurdly LARGE configured bound. A ceiling set BELOW the floor term is the same
# scheduled steal from the other side, and it is the worse direction: measured on the shipped file,
# `MAXAGE=1 CEIL=1` resolved the bound to 1 s and `claim_prune` DELETED a 2-SECOND-old claim
# (`… 2s old, PAST the 1s bound`), and `CEIL=3600` alone reaped a 4000 s-old claim that the shipped
# defaults keep. A bound below the longest mintable term can always fire INSIDE a live term, so it is
# not a bound at all — the same argument that produced the floor. Unlike a long bound, which every pass
# NAMES, a steal is SILENT, so the floor term wins this collision. Note it is compared against the TERM
# and not against the configured value: `MAXAGE=999999999` must still be clamped DOWN to the 7-day
# ceiling (A30), and comparing against the configured value would let it raise the ceiling instead.
[ "$CLAIM_UNREADABLE_LEASE_MAX_AGE_CEIL" -lt "$_claim_floor_term" ] \
  && CLAIM_UNREADABLE_LEASE_MAX_AGE_CEIL="$_claim_floor_term"
[ "$CLAIM_UNREADABLE_LEASE_MAX_AGE" -gt "$CLAIM_UNREADABLE_LEASE_MAX_AGE_CEIL" ] \
  && CLAIM_UNREADABLE_LEASE_MAX_AGE="$CLAIM_UNREADABLE_LEASE_MAX_AGE_CEIL"

# ── HOW OLD MAY A SNAPSHOT BE AND STILL BE BELIEVED? (agent-infra#2466) ─────────────────────────
# `claim_snapshot` is refreshed once per controller cycle, and every PR/issue SELECTION
# reads it instead of paying a network round trip per key. Before this bound there was no age at
# ALL: a snapshot written before a peer's claim still read as current, so a claim published since
# the last successful fetch was invisible — the exact duplicate the registry exists to prevent, and
# indistinguishable from "nobody holds it".
# ⛔ THE CYCLE IS 240 s, NOT 120 s (review, P2): `CYC="${CYC:-240}"` in `orch-loop.sh` and in
# `install.sh`, and README §"the loop" states the floor. So 900 s is ≈3.75 cycles, ~1 cycle of a
# suspended laptop — NOT the ~7 this line used to claim. The corrected margin is the point: a cycle
# whose body overruns 15 min goes stale WITHIN the cycle, and the sweep then acts on nothing for the
# remainder. Long enough that an ordinary slow cycle or a long dispatch never FALSE-BLOCKS selection,
# short enough that a wedged or dead refresh cannot hide a peer's claim for anywhere near its lease
# (CLAIM_TTL 1800 s).
# The same digit clamp as every other tunable here: an unparseable bound is worse than the default.
CLAIM_SNAPSHOT_MAX_AGE="${CLAIM_SNAPSHOT_MAX_AGE:-900}"
case "${CLAIM_SNAPSHOT_MAX_AGE:-}" in
  ''|*[!0123456789]*|0*) CLAIM_SNAPSHOT_MAX_AGE=900 ;;
  *) [ "${#CLAIM_SNAPSHOT_MAX_AGE}" -le 9 ] || CLAIM_SNAPSHOT_MAX_AGE=900 ;;
esac
# The repository every git call runs against. Resolution order:
#   1. an explicit CLAIM_REPO — used exactly as given, SET-AND-EMPTY included: an empty claim repo is
#      a caller bug, and `_git` REFUSES it rather than defaulting to something (see the empty-value
#      note on `_git`);
#   2. an ABSOLUTE `$REPO`, when it names a directory — it needs no resolution, so no cwd can make
#      it wrong;
#   3. a RELATIVE `$REPO`, when it names a directory AND the caller's cwd is not already a work-tree
#      root (the caller standing in a repo root, and naming that repo relatively, is the two-worker
#      shape below);
#   4. `.` — the caller's cwd.
#
# ⛔ THE CONTROLLER SETS CLAIM_REPO ITSELF, and that is not a detail — it is why the default is NOT
# the incident's cause. orch-loop.sh runs from launchd with cwd=$HOME (not a repository) and assigns
# `CLAIM_REPO="$REPO"` right after sourcing this file; chain-merge.sh, dispatch-merge.sh and
# refresh-candidates.sh also set it explicitly. What actually unblocked dispatch is `_git` below.
# The default matters for a caller that gives only `$REPO` — which is also where `git fetch` fails
# and the claim snapshot silently comes back empty, exactly as "snapshot lines=0 while origin had 3
# live claims" looked (agent-infra#1850's measurement).
#
# ⛔ (4) IS THE PRE-FIX ANSWER AND STILL THE RIGHT ONE FOR THE TWO WORKERS THAT `cd "$REPO"` FIRST
# (fix-one.sh:49+96, merge-one.sh:52+190). With a RELATIVE $REPO, `$REPO` resolved from inside `$REPO`
# is `$REPO/$REPO` — which either does not exist (a stall) or is a same-named SUBDIRECTORY (a claim
# pushed into a repo nobody named, measured). So (3)'s test is "is the cwd already a work-tree root",
# NOT "does $REPO happen to name some directory": a bare `-d` was FALSE-POSITIVE in exactly that
# shape, and git walks UP from a nested directory, so the claim would land on the wrong origin with
# no error at all.
# ⛔ And the cwd-root test ALONE is why (2) exists as a separate step: an ABSOLUTE $REPO standing in
# some other repo's root is a caller naming a DIFFERENT repo, and answering `.` there would silently
# claim on the cwd's origin instead (measured) — the same wrong-repo class, one shape over.
if [ "${CLAIM_REPO+set}" = set ]; then
  : # SET — used exactly as given, including EMPTY (which `_git` then refuses; never a default)
elif [ -n "${REPO:-}" ] && [ -d "$REPO" ]; then
  case "$REPO" in
    /*) CLAIM_REPO="$REPO" ;;
    *) if [ -e ./.git ]; then CLAIM_REPO="."; else CLAIM_REPO="$REPO"; fi ;;
  esac
else
  CLAIM_REPO="."
fi
EMPTY_TREE=4b825dc642cb6eb9a060e54bf8d69288fbee4904
export GIT_TERMINAL_PROMPT=0

# Outputs of the last call. Globals, not stdout capture, because `$(claim_acquire …)` would run
# it in a subshell and every one of these would be discarded by the caller.
CLAIM_RESULT=""; CLAIM_COMMIT=""; CLAIM_REF=""; CLAIM_OWNER=""
# Set by _claim_commit: the sha it built (also echoed, for the test seams that hand-build a lease)
# and, when it could not, WHY. Globals for the same subshell reason as CLAIM_RESULT above — and a
# REASON is the whole point: an empty string is what turned this into a weeks-long mystery.
CLAIM_COMMIT_OUT=""; CLAIM_COMMIT_ERR=""

# Deterministic author so claim commits do not depend on global git identity.
#
# ⛔ `cd` IN A SUBSHELL IS NOT THE SAME AS `git -C`, AND THE DIFFERENCE IS LOAD-BEARING (2026-10-18).
# `git -C <dir>` still STARTS in the caller's cwd and must resolve it to work out its prefix; on the
# launchd cells that read is denied (`fatal: Unable to read current working directory: Operation not
# permitted`), so `commit-tree` produced an EMPTY hash — `_claim_commit` returned "", and
# `_claim_acquire_at` refused every candidate with "could not build claim commit" while the
# controller looked alive. A subshell `cd` puts git's cwd right BEFORE it is exec'd, so no read of
# the caller's cwd happens at all; this is what made dispatch work again on the next iteration.
#
# ⛔ AND `cd` MUST BE MADE AS LITERAL AS `-C` WAS, OR IT INTRODUCES TWO FAIL-OPEN PATHS THAT `-C` DID
# NOT HAVE (2026-10-18 review, both measured):
#   • THE EMPTY VALUE. `cd ""` SUCCEEDS and leaves the cwd alone, so an empty CLAIM_REPO fell
#     straight through to `git` in the CALLER's directory: a full acquire there built a commit and
#     PUSHED `refs/claims/…` to that directory's origin — a repository nobody named. The `-n` test
#     below is what makes the fail-closed promise true, for the value that reaches `_git`; the
#     SET-and-empty case is kept from becoming a default by the `${CLAIM_REPO+set}` test above, so
#     both orderings are refused.
#   • `$CDPATH`. The `cd` BUILTIN searches $CDPATH for a relative path (a same-named directory the
#     caller never named WINS over the local one — measured), which `git -C` never did; a relative
#     CLAIM_REPO would then run every git call in that foreign repo and push there. Emptying CDPATH
#     for this one command keeps the resolution local; `--` stops a leading `-` being read as an
#     OPTION — `cd -P`/`cd -L` with no operand would otherwise SUCCEED and go to $HOME (measured),
#     so a bare-option CLAIM_REPO could claim into whatever repo $HOME happens to be.
# The failure TEXT is no longer generic: `_claim_repo_problem` below names the repo, the cwd and the
# git error, and `_claim_commit` returns it to the caller (agent-infra#1990). These guards fail CLOSED
# and now also fail LEGIBLY.
_git() {
  ( [ -n "${CLAIM_REPO:-}" ] || return 1
    CDPATH= cd -- "${CLAIM_REPO}" 2>/dev/null || return 1
    git "$@" )
}

# _claim_repo_problem -> ONE actionable line when CLAIM_REPO cannot serve as a git work tree,
# else the empty string. Exists because the failure it explains used to be reported as nothing at
# all: `_claim_commit` swallowed stderr and returned an empty sha, so the caller logged
# "could not build claim commit" with no repo, no cwd and no git error to act on.
_claim_repo_problem() {
  # ⛔ THIS DIAGNOSIS MUST APPLY THE SAME TWO RESOLUTION GUARDS AS `_git`, or it re-opens the hazards
  # measured directly above (and pinned by `claim-cwd.test.sh` C9): `cd` without `CDPATH=` follows the
  # caller's CDPATH into a foreign repo, and `cd` without `--` reads a bare `-P`/`-L` as an OPTION and
  # SUCCEEDS into $HOME — so the line said "readable" about a directory nobody named. And a
  # SET-BUT-EMPTY CLAIM_REPO must not be reported as `.`: `_git` refuses that value, so printing `.`
  # here would name a repo the caller never selected.
  local repo="${CLAIM_REPO-}" cwd
  cwd="${PWD:-?}"
  if [ -z "$repo" ]; then
    printf 'CLAIM_REPO is SET BUT EMPTY (cwd=%s) — set CLAIM_REPO (or REPO) to the checkout of the repo being claimed' "$cwd"
    return 0
  fi
  if ! ( CDPATH= cd -- "$repo" 2>/dev/null ); then
    printf 'not a readable directory: CLAIM_REPO=%s (cwd=%s) — set CLAIM_REPO (or REPO) to the checkout of the repo being claimed' "$repo" "$cwd"
    return 0
  fi
  if ! _git rev-parse --git-dir >/dev/null 2>&1; then
    printf 'not a git work tree: CLAIM_REPO=%s (cwd=%s) — set CLAIM_REPO (or REPO) to the checkout of the repo being claimed' "$repo" "$cwd"
    return 0
  fi
  printf ''
}
_cg() { _git -c user.name="fleet-claim" -c user.email="claims@localhost" "$@"; }

# ── WHICH BOX HOLDS THIS (agent-infra#2094) ──────────────────────────────────────────────────
# A claim's owner is `<host>:<pid>`, and BOTH halves are read FRESH on every call. That is not tidiness:
# the incident was a host RENAME. A host name captured once (in a plist, a keys.env, or any ambient
# export that outlives the change) is a STALE CACHE the moment the machine is renamed, and every fresh
# claim is then stamped with a name no box answers to — so no peer can ever verify liveness against it
# and the lease is immune for its full term.
#
# ⛔ THE FIX IS TO REJECT THE STALE VALUE, NOT THE CLAIM. A configured `CLAIM_OWNER_ID` whose host
# segment is not the running host is REFUSED — loudly, naming the stale host — and the RUNNING host is
# stamped. The alternative reading (abort the acquire) would stop dispatch on every box carrying a
# pre-rename value, converting a recoverable misconfiguration into an outage; the incident's damage
# came from the STAMP, so the stamp is what gets fixed. `hostname -s` is re-invoked per call (never
# cached in a variable above), which is what makes a mid-run rename visible to the NEXT claim.
#
# ⛔ `CLAIM_OWNER_ID` IS A TEST SEAM, AND NO SHIPPED ARTEFACT SETS IT (`rg CLAIM_OWNER_ID` finds only
# this file and the suites — no plist, no keys.env, no install/deploy script). The rejection below
# therefore fires on an AMBIENT export a caller inherited, not on an operator setting; the message
# says so, because a remedy that names an artifact the value is never in sends the reader nowhere.
# The seam is now `CLAIM_OWNER_HOST` (override the HOST, not a whole identity): claims.sh ALWAYS
# appends `:<pid>`, so a value that carries its own pid would stamp `host:pid:pid`. A colon-bearing
# `CLAIM_OWNER_ID` is refused for that reason.
#
# ⛔ A WHOLE IDENTITY ALSO CANNOT EXPRESS "ANOTHER BOX", and the cross-box suites need that. They now
# export `CLAIM_OWNER_HOST=boxA`, which keeps the pid THIS process's own — the pid is what makes the
# local liveness rule below meaningful.
# ⛔ THE FALLBACK IS LOAD-BEARING, NOT DECORATION. Without `2>/dev/null || echo box`, a launchd/cron
# child with a PATH that cannot resolve `hostname` (or a sandboxed cell) leaks the probe's stderr into
# every log line and stamps `:<pid>` — no host at all — which is worse than a sentinel: the sentinel is
# at least recognisable as "not an identity" (see `claim_former_hosts`, which abstains on it).
claim_host() { printf '%s' "${CLAIM_OWNER_HOST:-$(hostname -s 2>/dev/null || echo box)}"; }

# ⛔ THE SEAM IS ANNOUNCED ONCE, AND ITS COST IS SPELT OUT (agent-infra#2094 cycle-3 review). Before
# this, `CLAIM_OWNER_HOST` was inherited silently by everything a cell started, with two consequences
# nothing could see: (1) it stamps a host name no rule on this box can judge, so the box's OWN claims
# are unreclaimable by its own orphans rules for a full lease — the identical failure mode that
# `CLAIM_OWNER_ID` rejection exists to prevent, arriving through the other door; (2) it suppresses
# `claim_host_record`, so the box stops accumulating the names that make a RENAME self-heal, an inert
# self-heal that reports success. It stays supported — the test harnesses and the cross-box
# simulations need it, and refusing it would be a new hard failure — but it says what it costs.
# ⛔ DEFAULT, NOT ASSIGN (cycle-11 review). `orch-loop.sh` re-sources claims.sh INSIDE its main loop
# (once per cycle, ~2 min), so a hard `=0` here reset the flag on every cycle and an inherited
# `CLAIM_OWNER_HOST` warned ~720 times a day — the noise this flag exists to prevent. `:-` keeps a
# `CLAIM_HOST_SEAM_WARNED=1` set by an earlier source in the SAME process, so "once" is once per
# process and O18's two-acquire case still measures exactly one.
CLAIM_HOST_SEAM_WARNED="${CLAIM_HOST_SEAM_WARNED:-0}"
claim_host_warn_seam() {
  [ -n "${CLAIM_OWNER_HOST:-}" ] || return 0
  [ "${CLAIM_HOST_SEAM_WARNED:-0}" = "0" ] || return 0
  # ⛔ THIS PROBE FOLLOWS THE SAME RULE AS EVERY OTHER ONE IN THIS FILE — a failure ABSTAINS, it does not
  # leak (cycle-10 review). A bare `hostname -s` printed its own error to stderr (the leak `claim_host`'s
  # fallback exists to prevent), left `real` empty so the warning said "overrides the running host ()",
  # and under a `set -e` caller aborted the mint outright.
  local real; real="$(hostname -s 2>/dev/null)" || return 0
  [ -n "$real" ] || return 0
  # ⛔ SET THE FLAG ONLY ONCE THE PROBE HAS ANSWERED (cycle-15 review): setting it before the probe
  # meant a single transient `hostname` failure suppressed the warning for the life of the process —
  # the silent inertness this warning exists to expose. A probe that cannot answer leaves the flag at
  # 0, so the next acquire warns (and an equal seam host returns 0 above without consuming the flag).
  [ "$CLAIM_OWNER_HOST" = "$real" ] && return 0
  CLAIM_HOST_SEAM_WARNED=1
  printf '[claims] ⚠️ CLAIM_OWNER_HOST=%s overrides the running host (%s): claims minted here are stamped with a name the HOST rules cannot judge — an ISSUE claim minted here cannot be reclaimed by this box (a PR claim still can, via its pid) — and %s will NOT be recorded as one of this box'"'"'s own names (the rename self-heal stays inert). Unset it unless you are a test or a cross-box simulation.\n' \
    "$CLAIM_OWNER_HOST" "$real" "$real" >&2
  return 0
}

claim_owner() {
  local host cfg_host
  # ⛔ THIS CALL IS BEST-EFFORT ONLY, AND THE REAL ONES ARE AT THE CALL SITES (cycle-4 review). The
  # shipped path is `CLAIM_OWNER="$(claim_owner)"` — a COMMAND SUBSTITUTION — so the once-flag assigned
  # inside `claim_host_warn_seam` dies with the subshell and every mint warns again. The warn therefore
  # also runs at the top of `_claim_acquire_at`, which the shipped callers invoke DIRECTLY
  # (`if claim_issue_acquire …`), where the flag survives. This call stays for direct callers.
  claim_host_warn_seam
  host="$(claim_host)"
  # ⛔ RECORD THE NAME AT MINT TIME, or the former-name rule can never fire: a box's OLD name is only
  # known from what it stamped BEFORE the rename, so the history has to be written while that name is
  # still current. Silent on failure — an unrecorded name costs an under-reap, never a steal.
  claim_host_record "$host"
  if [ -n "${CLAIM_OWNER_ID:-}" ]; then
    cfg_host="${CLAIM_OWNER_ID%%:*}"
    if [ "$cfg_host" != "$host" ] || [ "$cfg_host" != "$CLAIM_OWNER_ID" ]; then
      # stderr, so a caller in `$( )` still gets a clean owner on stdout while the operator sees WHY.
      printf '[claims] REJECTED CLAIM_OWNER_ID=%s — %s. A claim stamped under a host that no longer exists is unreclaimable for its whole lease (agent-infra#2094); using the RUNNING host instead. Fix: unset CLAIM_OWNER_ID (no shipped plist or keys.env sets it — this is a test seam, and an ambient export inherited by the cell is the only way it gets here); the host is re-derived on every call.\n' \
        "$CLAIM_OWNER_ID" \
        "$([ "$cfg_host" != "$CLAIM_OWNER_ID" ] && printf 'it carries its own pid, and claims.sh always appends this process pid' || printf 'its host segment "%s" is not the running host "%s"' "$cfg_host" "$host")" >&2
      printf '%s:%s' "$host" "$$"
      return 0
    fi
    printf '%s:%s' "$CLAIM_OWNER_ID" "$$"
    return 0
  fi
  printf '%s:%s' "$host" "$$"
}

# ── THIS BOX'S OWN FORMER NAMES (agent-infra#2094) ────────────────────────────────────────────
# ⛔ THE RENAME MUST SELF-HEAL ON THE BOX THAT RENAMED, WITH NO FLEET CONFIGURATION. The incident's
# blocked dispatch was the SAME box refusing its OWN lease, five minutes after it was renamed. A
# roster (`CLAIM_KNOWN_HOSTS`) fixes that only once an operator writes the new name into every
# peer — and nothing in this repo ships one, so the default would leave the incident unfixed.
# So the box REMEMBERS the names it has carried (`$CLAIM_STATE_DIR/claim-hosts`, one per line) and
# treats its OWN former names as dead. The blast radius is deliberately self-limited: it can only
# ever over-reap claims stamped by a name THIS box used to answer to, which is exactly the class the
# rename creates — and a name it never wore is never on the list.
# ⛔ It is recorded from the RUNNING host at the moment a claim is judged, not at source time, for the
# same reason the owner is: a source-time snapshot is a cache of a pre-rename state.
CLAIM_STATE_DIR="${CLAIM_STATE_DIR:-${O:-$HOME/orchestrator}/state}"
# The BRANCH claim's token files live beside the issue claim's records, under the same state dir, so a
# box has ONE place an operator inspects for "what does this box hold" (agent-infra#3328).
CLAIM_BRANCH_STATE_DIR="${CLAIM_BRANCH_STATE_DIR:-$CLAIM_STATE_DIR}"
claim_hosts_file() { printf '%s/claim-hosts' "$CLAIM_STATE_DIR"; }
# claim_host_record <host> — remember a name this box has answered to (idempotent, best-effort).
# ⛔ IT RECORDS THE MACHINE'S OWN NAMES, SO IT NEVER RECORDS A SEAM IDENTITY. `CLAIM_OWNER_HOST`
# exists so a test can present as another box; if those names were written here they would become
# "former names of this box" and every simulated peer would read as ORPHANED — turning the anti-steal
# rule into a fleet-wide steal, in one shared state dir (measured: it made two cross-box suites report
# false winners before this gate existed). The real `hostname -s` is what a rename actually changes,
# so that is exactly what belongs in the file.
claim_host_record() {
  local f h="${1:-}"
  [ -n "$h" ] || return 0
  # ⛔ AND NEVER THE SENTINEL (P1, cycle-10 review). `claim_owner` calls this with `$(claim_host)`, which
  # is the literal `box` when the probe cannot answer — so a single launchd/PATH failure could WRITE
  # `box` into the history, after which every box reads every OTHER box's `box:<pid>` claim as "a former
  # name of this box" and reaps it. Refusing it in the reader alone is not enough: the record outlives
  # the failure and would be re-read by every later pass on a box whose probe works again.
  [ "$h" != "box" ] || return 0
  [ -z "${CLAIM_OWNER_HOST:-}" ] || return 0
  f="$(claim_hosts_file)"
  # ⛔ RECORDING NEVER CONJURES STATE. A `mkdir -p` here wrote the machine's hostname into whatever
  # `$CLAIM_STATE_DIR`/`$O`/`$HOME` happened to point at, on EVERY acquire — including refused ones and
  # including a hermetic test suite, which then mutates the runner's real `$HOME` (measured: a suite
  # with no claim state dir created `~/orchestrator/state/claim-hosts` containing the runner's host).
  # Worse, a shared or mirrored home would write a FOREIGN hostname onto "names this box answered to",
  # turning the anti-steal rule into a fleet-wide steal. So: the state dir must already exist, which in
  # the shipped harness means the controller created it at startup.
  [ -d "$CLAIM_STATE_DIR" ] || return 0
  if [ -f "$f" ]; then
    grep -qx -- "$h" "$f" 2>/dev/null && return 0
    printf '%s\n' "$h" >> "$f" 2>/dev/null || return 0
  else
    printf '%s\n' "$h" > "$f" 2>/dev/null || return 0
  fi
  return 0
}
claim_former_hosts() { # -> space-separated host names this box has used, EXCLUDING the current one
  local f cur
  f="$(claim_hosts_file)"
  # ⛔ THE RUNNING HOST MUST BE VERIFIABLE, OR THIS RULE ABSTAINS (agent-infra#2094 cycle-4 review).
  # The comparison below is "is the owner one of the names this box wore EXCEPT its current one". With
  # an EMPTY or sentinel `cur` the exclusion does not apply, so the box's OWN CURRENT NAME reads as a
  # FORMER name — the steal direction, the one direction this whole change must never fail in: a live
  # lane's claim is reaped and a peer re-dispatches the same issue. `hostname` is a probe like any
  # other, and every other probe in this file abstains when it cannot answer (`ps -p $$`, the roster
  # that does not name this box). Under the seam the seam IS the identity the caller declared (the
  # harnesses and cross-box simulations depend on that), so only the REAL probe is required to answer.
  local real
  if [ -n "${CLAIM_OWNER_HOST:-}" ]; then
    cur="$CLAIM_OWNER_HOST"
  else
    cur="$(hostname -s 2>/dev/null)" || cur=""
    [ -n "$cur" ] || return 0
    [ "$cur" != "box" ] || return 0   # claim_host()'s fallback for a failed probe is not an identity
  fi
  # ⛔ SUBTRACT THE PROBED REAL NAME AS WELL (agent-infra#2094 cycle-5 review). Under a SEAM `cur` is
  # the simulated box, so the machine's own REAL current name was not excluded and came back as a
  # "FORMER name of this box" — a seam-presenting process would then reclaim a claim minted by a
  # non-seam process on the SAME machine, which is the steal direction this rule's comment claims to
  # close. The real name is never "former" by definition, whoever is presenting as whom.
  # ⛔ AND THE REAL PROBE MUST ACTUALLY ANSWER — UNDER THE SEAM TOO (agent-infra#2094 cycle-6 review).
  # Requiring only `cur` left the seam path unguarded: with `CLAIM_OWNER_HOST` set and a `hostname` that
  # cannot answer, `real` came out empty, so nothing was subtracted and the machine's OWN CURRENT name
  # read as "a FORMER name of this box" — a seam-presenting process would then reclaim/prune a claim
  # minted by a real non-seam process ON THE SAME MACHINE. The steal direction, reached through the
  # seam, in the branch whose comment below says a probe that cannot answer abstains.
  real="$(hostname -s 2>/dev/null)" || return 0
  # ⛔ EXIT 0 WITH EMPTY OUTPUT IS ALSO AN UNANSWERABLE PROBE (cycle-8 review). Testing only the
  # sentinel let a `hostname` that succeeds and prints nothing through: `real` was empty, nothing was
  # subtracted, and the machine's OWN CURRENT name came back as FORMER — the same steal direction, one
  # shim away. Non-empty AND not the sentinel, or abstain.
  [ -n "$real" ] && [ "$real" != "box" ] || return 0
  claim_host_record "$cur"
  # ⛔ MUST RETURN 0 EVEN WITH NO FILE. It is called inside a command substitution
  # (`roster=" $(claim_former_hosts) "`) and callers run under `set -e` — a bare `awk` on a missing
  # file returns 2, which killed the CALLER's subshell so `claim_orphan_reason` read as "not
  # orphaned" in every context that sets -e (measured: the refresh pre-flight reported a DEAD host
  # as held-by-live while the same call from a non-`set -e` shell reclaimed it). A query about the
  # past must answer "nothing", never fail.
  # `$0 != "box"` is defence in depth for a history file written BEFORE the recorder refused it: the
  # record survives the failure that created it, so the reader has to be safe on its own.
  awk -v cur="$cur" -v real="$real" 'NF && $0 != cur && $0 != real && $0 != "box" {printf "%s ", $0}' "$f" 2>/dev/null || :
}

# ── IS THE HOLDER STILL A LIVE LANE? (agent-infra#2094) ───────────────────────────────────────
# `claim_orphan_reason <owner>` -> prints WHY the holder is orphaned and returns 0; returns 1 when
# the holder may still be alive. Four rules, in increasing cost, each failing toward UNDER-reaping:
#   1. THE LOCAL RULE, always on, needs no configuration — for a **PR** claim only. The owner host IS
#      this host **or one of its former names** (both are THIS machine, so the pid is directly
#      checkable: a PR claim naming a pid that no longer exists cannot be a live worker), and a LIVE
#      local pid OUTRANKS the host name — that ordering is the P0 fixed in 720e780d, where a renamed
#      box's own live merge/fix claim was reaped by the former-name rule. It is what a single-box fleet
#      needs.
#      ⚠️ IT IS NOT WHAT THE INCIDENT NEEDED, and an earlier version of this comment said it was
#      (corrected after the cycle-3 review). The incident's 14 dead leases were ISSUE claims
#      (`refs/claims/issue-9063` …), whose owner host was the box's OLD name and therefore NOT this
#      host — so rule 1 could not have fired on any of them; rule 2 (and, configured, rule 3) is the
#      repair. Rule 1's own class is different: a worker's PR claim left behind on an UNCHANGED
#      hostname. See the ⛔ block at `claim_orphan_reason` for why the pid must never judge an ISSUE
#      claim, where the holder (the controller) and the work (the lane's chain) are different
#      processes and every deploy kills the holder.
#   2. THIS BOX'S OWN FORMER NAMES (`claim_former_hosts`) — the rename self-heals without a roster.
#   3. `CLAIM_DEAD_HOSTS` — an explicit deny list of host names known to be gone.
#   4. `CLAIM_KNOWN_HOSTS` — the fleet roster. Consulted only when SET, and only when it names the
#      RUNNING host: an EMPTY roster must never mean "every peer is dead" (that steals a live peer's
#      claim and dispatches the same work twice — the failure this registry exists to prevent), and a
#      roster that does not list THIS box is STALE about this box, so it cannot judge anyone. A
#      rename leaves every peer's roster stale in exactly that way, so abstaining is what keeps a
#      rename from turning into a fleet-wide STEAL (under-reap: the lease still bounds it).
# ⛔ PID REUSE IS AN UNDER-REAP, ON PURPOSE: a recycled pid reads alive and the claim simply runs to
# its lease (bounded by THAT KEYING'S OWN ceiling — CLAIM_TTL_MAX for the per-head/PR keys, 9600;
# CLAIM_ISSUE_TTL for issue keys, 18000; CLAIM_BRANCH_TTL for branch keys, 14400). Naming only the
# first two was wrong for branch keys, whose ceiling is neither. The opposite polarity steals live work.
# ⛔ `ps -p` NOT `kill -0`: `kill -0` reports EPERM for a LIVE pid owned by another user, i.e. it
# reads a running lane as dead and reclaims its claim.
# ⛔ AND `ps` MUST BE PROVEN ABLE TO ANSWER AT ALL. `ps -p` has THREE outcomes — found, absent, and
# "could not tell" (no procps, a hardened /proc with hidepid, a PS_BIN shim, a sandboxed cell) — and
# folding the third into "absent" turns an instrument failure into a STEAL of every same-host claim.
# The control probe (`ps -p $$`) is the positive witness: a box where ps cannot see this process
# cannot witness anyone's death, so the local rule abstains.
# ⛔ AND THE LOCAL RULE JUDGES THE HOLDER PROCESS, NOT THE WORK. The issue claim is minted by the
# CONTROLLER, so a controller restart orphans its in-flight issue claims the instant the old process
# exits, while the lane and its chain keep running. What prevents a duplicate dispatch in that window
# is `dispatched.txt` (same box) plus the live `lane-<N>` session — not the claim. Stated here because
# the rule reads like "nobody is working on this", and it is not: it is "the process that took the
# claim is gone".
# claim_orphan_reason <owner> [<ref>]
# ⛔ THE LOCAL-PID RULE IS FOR **PR** CLAIMS ONLY, AND THAT IS NOT A DETAIL (agent-infra#2094 cycle 2).
# A PR claim is minted BY THE WORKER (`merge-one.sh` / `fix-one.sh` lease it for their own lifetime), so
# "the minting pid is gone" really does mean "no worker holds this". An ISSUE claim is minted by the
# CONTROLLER (`orch-loop.sh`) and released by the CHAIN, so the holder process and the work are
# DIFFERENT processes: a controller restart (every deploy) leaves the lane and its chain running while
# the claiming pid is gone. Reaping that claim from the pid alone DELETES THE SHARED BARRIER, and a
# peer then dispatches the same issue — the duplicate this registry exists to prevent, on the shared
# queue. Measured before this guard: peer pre-flight `held-by-live` -> our prune `pruned orphaned-host`
# -> peer `no claim on #N`, which is the whole duplicate window opening at the first restart.
# So an ISSUE claim is judged only by the HOST rules below. The host rules are what the incident was:
# after a rename the holder's HOST is not this box, so nothing here depends on the pid.
# ⛔ Realigning the re-stamp alternative was considered and rejected: re-stamping in-flight issue
# claims each cycle is a second writer racing the chain's release (the generation guard in
# claim_issue_release_record exists precisely for that overlap).
claim_orphan_reason() {
  local owner="${1:-}" ref="${2:-}" host pid roster have_pid=0 me real
  [ -n "$owner" ] || return 1
  [ "$owner" = "?" ] && return 1                    # a snapshot reader's placeholder, not an identity
  host="${owner%%:*}"; pid="${owner##*:}"
  [ -n "$host" ] || return 1                        # `:123` names no host at all
  case "$owner" in *:*) have_pid=1 ;; esac
  # ⛔ THIS BOX HAS TWO ANSWERABLE NAMES, AND BOTH ARE LOCAL (P1, cycle-13 review): the seam or the
  # real `hostname -s`. Derived here, once, because `claim_host` returns the SEAM when
  # `CLAIM_OWNER_HOST` is set while `claim_former_hosts` deliberately EXCLUDES the probed real name —
  # so under a seam, a claim stamped with this machine's own hostname matched neither "the host" nor
  # "a former name", skipped the pid probe, and reached the roster arm, which called it ORPHANED.
  # Measured on a live pid: rc=0 "owner host <realHost> is not in CLAIM_KNOWN_HOSTS" (same for an
  # `issue-` ref) against rc=1 held-by-live with the seam unset — the steal direction on a live LOCAL
  # pid. An unanswerable probe leaves the name EMPTY, which never matches, and the fleet-wide `box`
  # sentinel is dropped for the same reason it is dropped everywhere.
  # ⛔ NO SCRUB OF THE SENTINEL HERE (cycle-24 review). Two `case "…" in ''|box) x=''` lines used to sit
  # below this, and they were DEAD in every branch: the pid arm is already gated on `[ "$host" != "box" ]`,
  # and the roster arms test `''|box` on both names themselves. Measured before deleting — a 90-case
  # sweep (hostname failing / empty / normal × seam set/unset × five owner shapes × PR and issue refs ×
  # roster unset/naming/malformed) produced BYTE-IDENTICAL verdicts with and without them. Keeping a dead
  # guard is not harmless: a reader cannot tell it from a load-bearing one. The consumers guard the
  # sentinel, and O22/O23/O24 pin that they do.
  me="$(claim_host)"
  real="$(hostname -s 2>/dev/null)" || real=''
  # ⛔ A PID IS NEEDED FOR THE PID RULE AND FOR NOTHING ELSE. The HOST rules below are answerable from
  # the host name alone, and a lease is DATA — a sibling writer, an older claims.sh, or a hand-pushed
  # ref can legitimately carry a bare host. Requiring `:<pid>` before consulting the host rules made
  # the whole orphan verdict silently unusable against those (measured: a `deadbox`-stamped claim read
  # `held-by-live` while the same call with `deadbox:<pid>` reclaimed it, so the pinning test went red
  # against correct code — and in production the same shape would have kept a dead host's claim live
  # for its full TTL). Only the branch that actually probes a process requires the pid.

  case "$ref" in
    # ⛔ A BRANCH CLAIM'S HOLDER PID IS THE ACQUIRE CLI, AND IT IS DEAD BY DESIGN (agent-infra#3358 review
    # B3/B4). `branch-claim.sh acquire` mints the claim and exits within the second, so "the minting pid
    # is gone" is the NORMAL state of a live batch claim — the exact inversion decision (b) describes for
    # issue claims, arrived at from the other side. Measured on a peer acquire: `branch-integration-
    # land-batch-2-fix` matched the PR-shaped `*[0-9]*-*` arm (`…batch-2-fix`), probed the absent pid and
    # RECLAIMED a claim holding 599s of live lease, after which the real owner's pushes were refused —
    # two-lane ownership resolving to "whoever acquired last", which is the loss this key exists to stop.
    # ⛔ AND THE HOST RULES DO NOT JUDGE IT EITHER — THE BRANCH KEY ABSTAINS ENTIRELY (agent-infra#3329
    # cycle-2 review, F1). Skipping only the pid rule left the arms BELOW it (a former name of this box,
    # CLAIM_DEAD_HOSTS, and the roster that calls an unknown host ORPHANED) still judging a branch key —
    # and a branch claim's holder has NO liveness evidence of any kind: its pid is the acquiring CLI,
    # dead by design, and its host is whatever box ran that CLI, which is not the lane. Measured:
    # `claim_orphan_reason "oldbox:4242" refs/claims/branch-…` returned ORPHANED off the FORMER-NAME arm
    # after a box rename, and with `CLAIM_KNOWN_HOSTS` set it returned ORPHANED for a live peer's claim —
    # and `claim_prune` deletes on that verdict with NO expiry needed, after which the guard reads
    # `unclaimed` and the stray push lands. Ownership of a branch ends at holder RELEASE or LEASE EXPIRY
    # (claim_prune's expired arm), never at an orphan verdict. The bare spelling is covered too: a
    # `branch-<slug>` with a digit-hyphen in it would otherwise reach the PR-shaped pid arm.
    */branch-*|branch-*) return 1 ;;
    *"/issue-"*) : ;;   # the holder is the controller, not the worker -> the pid answers nothing
  # ⚠️ THE RESIDUAL THIS ARM ADMITS is confined to the ISSUE key: a rename frees the renamed box's own
  # IN-FLIGHT issue claims while their chains keep running — "the holder is gone but the work is not".
  # That is deliberate (the issue claim exists to make work MUTUALLY EXCLUSIVE, and a barrier held by a
  # name no box answers to is indistinguishable from an abandoned one for every peer), and a PR claim is
  # NOT exposed to it because its pid is probeable (see the arm above). The consequence is stated where
  # operators read it (README §7.2b): for an ISSUE claim the guarantee is "safe until the next prune",
  # not "safe until the lease expires", and `dispatched.txt` protects only the SAME box.
  # ⛔ THE PID RULE IS OPT-IN ON AN EXPLICIT PR KEY, NOT ON "NOT AN ISSUE". `ref` is OPTIONAL, and
    # defaulting to the destructive polarity put the whole duplicate window ONE OMITTED ARGUMENT away:
    # with no ref the `*)` arm judged an issue-keyed owner by its pid and deleted a live lane's shared
    # barrier on a controller restart. A PR ref is `<ns>/<pr>-<sha12>` (a hyphen after the number), so
    # only that shape may probe a process; an absent or unrecognised ref abstains (under-reap).
    # ⛔ AND "A HYPHEN" IS NOT THE TEST (P2, cycle-16 review): `*-*` also matched the BARE ISSUE KEY
    # `issue-<N>` that `claim_issue_key` prints, so `claim_orphan_reason "host:<dead pid>" "issue-1234"`
    # returned ORPHANED — the PR-only rule judging an ISSUE claim, i.e. exactly the shared-barrier window
    # this arm exists to close, one caller away. The PR shape is therefore matched POSITIVELY: a PR ref
    # must be `…<pr>-<sha12>`, and anything else abstains (`issue-<N>` has no digit-then-hyphen, so it
    # falls through to the HOST rules below — bare and prefixed keys give the SAME verdict, which the
    # `*"/issue-"*` arm above already guarantees for the prefixed form).
    # ⛔ NO SEPARATE `*issue-*)` ARM (cycle-18 review): I added one, and it was INERT — the
    # `*"/issue-"*` arm above matches every issue ref this code produces, and a bare `issue-<N>` cannot
    # match the pattern below, so deleting it left every assertion green. An unpinnable duplicate is
    # deleted rather than defended, the same call this file made for the inert `declare -f` gate.
    *[0-9]*-*)
      # ⛔ A FORMER NAME OF THIS BOX IS *THIS MACHINE*, SO ITS PID IS PROBEABLE TOO (P0, cycle-7
      # review). The gate used to be `host == claim_host`, so immediately after a rename a PR claim
      # stamped `<oldName>:<live pid>` skipped the pid probe and fell through to the former-name rule,
      # which called it ORPHANED — and the first hourly `claim_prune` deleted the box's OWN in-flight
      # `merge-one`/`fix-one` claim. The ref then left origin, every peer's pre-flight read
      # `no claim on #N`, and a peer won a fresh CAS and merged the same head: the STEAL direction, on
      # the PR keying the README calls unaffected. A live pid is direct evidence a worker is alive, so
      # it outranks the host name — but ONLY where the pid is really local (the running host, or a name
      # this box wore), and never for an ISSUE key, whose holder and worker are different processes.
      # ⛔ THE `box` SENTINEL IS NOT AN IDENTITY, ON EITHER SIDE OF THE COMPARISON (P0, cycle-9
      # review). `claim_host` falls back to the literal `box` when the `hostname` probe cannot answer, and
      # that string is THE SAME ON EVERY BOX — so `[ "$host" = "$(claim_host)" ]` matched every peer's
      # `box:<pid>` claim, read the peer's pid as absent locally, and reclaimed (and pruned) a LIVE remote
      # worker's claim. One shared install/PATH mistake makes every cell stamp `box:<pid>`, i.e. each box
      # reaping the others' merge/fix claims: the steal direction, arriving through a probe that cannot
      # answer. `claim_former_hosts` already refuses the sentinel; this gate must too. A sentinel owner
      # falls through to the HOST rules, which abstain when they cannot judge.
      # ⛔ THE MACHINE'S OWN PROBED NAME IS LOCAL TOO, WITH OR WITHOUT A SEAM (P1, cycle-13 review).
      # `claim_host` returns the SEAM when `CLAIM_OWNER_HOST` is set, and `claim_former_hosts`
      # deliberately EXCLUDES the probed real name — so under a seam a claim stamped with this box's
      # REAL hostname was neither "the host" nor "a former name", skipped the pid probe entirely, and
      # reached the roster arm, which called it ORPHANED. Measured on a live pid: `claim_orphan_reason
      # "<realHost>:<live pid>" <PR ref>` with the seam set returned rc=0 "owner host <realHost> is not
      # in CLAIM_KNOWN_HOSTS" (and the same for an `issue-` ref), while the seam-unset control returned
      # rc=1 held-by-live — the steal direction on a live LOCAL pid. The seam is the entry condition and
      # no shipped artefact sets it, but an ambient inherited export is exactly the path this file's
      # own seam warning names. So: local = the seam identity, OR the probed real hostname, OR a former
      # name — each only when it is a real answer (never empty, never the fleet-wide `box` sentinel).
      local is_local=0
      if [ "$host" != "box" ]; then
        if [ -n "$me" ] && [ "$host" = "$me" ]; then
          is_local=1
        elif [ -n "$real" ] && [ "$host" = "$real" ]; then
          is_local=1
        else
          case " $(claim_former_hosts) " in *" $host "*) is_local=1 ;; esac
        fi
      fi
      if [ "$have_pid" = 1 ] && [ "$is_local" = 1 ]; then
        case "$pid" in ''|*[!0123456789]*) return 1 ;; esac
        if [ "$pid" -le 1 ] 2>/dev/null; then return 1; fi
        # the control probe: only a `ps` that can see THIS process may witness an absence.
        ps -p "$$" >/dev/null 2>&1 || return 1
        ps -p "$pid" >/dev/null 2>&1 && return 1
        printf 'owner host is this box (now or formerly) but the pid that took the PR claim (%s) is gone' "$pid"
        return 0
      fi ;;
  esac

  roster=" $(claim_former_hosts) "
  case "$roster" in *" $host "*) printf 'owner host %s is a FORMER name of this box' "$host"; return 0 ;; esac

  # a DENY list is checked before the allow list: naming a host dead is the operator's strongest
  # statement, so it wins even if the roster still lists it.
  roster=" $(printf '%s' "${CLAIM_DEAD_HOSTS:-}" | tr ',' ' ') "
  case "$roster" in *" $host "*) printf 'owner host %s is on CLAIM_DEAD_HOSTS' "$host"; return 0 ;; esac

  if [ -n "${CLAIM_KNOWN_HOSTS:-}" ]; then
    # ⛔ THE SENTINEL IS NOT JUDGEABLE FROM A ROSTER EITHER (P1, cycle-14 review). `box` is what every
    # cell stamps when its `hostname` probe fails, so a roster — even a COMPLETE one — lists the box's
    # real NAME while that box stamped `box`, and the match below therefore never fires for it:
    # measured `CLAIM_KNOWN_HOSTS="<realHost> peer1"; claim_orphan_reason "box:999999" <PR ref>` → rc=0
    # "owner host box is not in CLAIM_KNOWN_HOSTS", i.e. every live claim a probe-blind cell mints is
    # reaped by any peer with a roster. This is the promise the pid gate already makes ("a sentinel
    # owner falls through to the HOST rules, which abstain when they cannot judge") and it was false
    # for this arm. `CLAIM_DEAD_HOSTS` is checked ABOVE, so an explicit `CLAIM_DEAD_HOSTS=box` still
    # reaps; only the roster's INFERENCE about a fleet-wide name is refused.
    case "$host" in ''|box) return 1 ;; esac
    roster=" $(printf '%s' "$CLAIM_KNOWN_HOSTS" | tr ',' ' ') "
    # ⛔ A ROSTER THAT DOES NOT NAME THIS BOX IS STALE ABOUT THIS BOX (a rename, or a new cell) and
    # cannot be used to declare a PEER dead: the usual trigger for that staleness IS a rename, so
    # acting on it would reap the renamed box's LIVE claims fleet-wide. Abstain instead.
    # ⛔ AND AN UNANSWERABLE PROBE MUST ABSTAIN BEFORE THE COMPARISON, NOT INSIDE IT (P1, cycle-12
    # review). `claim_host` prints the EMPTY STRING when `hostname -s` exits 0 printing nothing, so the
    # pattern below was `*"  "*` — which matches any roster carrying two consecutive spaces (a trailing
    # comma, a double space). Measured: `CLAIM_KNOWN_HOSTS=peerA,peerB,` returned rc=0 "owner host peerC
    # is not in CLAIM_KNOWN_HOSTS" for a LIVE unlisted peer, i.e. the guard that exists solely to stop a
    # fleet-wide over-reap was bypassed by the very probe failure it is supposed to catch. An identity
    # that cannot be answered is not an identity: abstain (under-reap). `box` is excluded for the same
    # reason it is excluded everywhere — it is fleet-wide, not this box.
    case "$me" in ''|box) return 1 ;; esac
    case "$roster" in
      *" $me "*) ;;
      *) case "$real" in ''|box) return 1 ;; esac
         case "$roster" in *" $real "*) ;; *) return 1 ;; esac ;;
    esac
    # ⛔ A ROSTER IS NOT EVIDENCE ABOUT THIS BOX — BY EITHER OF ITS ANSWERABLE NAMES (P1, cycle-14
    # review). The staleness guard above can be satisfied by EITHER name (the seam, or the probed real
    # host), so BOTH need an abstention here: with `CLAIM_OWNER_HOST=seamX` and a roster naming only the
    # real host, a claim stamped `seamX:<live pid>` passed the guard, failed the `*" $host "*` match
    # below, and was called ORPHANED — measured rc=0 while the same owner on a PR ref read held-by-live.
    # A previous version of this comment claimed the `$host = $me` guard was unreachable "because the
    # roster already proved it contains `$me`"; that reasoning was wrong for exactly this case, and it
    # was removed on the strength of it. Both guards are back, each pinned by O24.
    case "$host" in "$me") return 1 ;; esac
    case "$real" in ''|box) ;; *) case "$host" in "$real") return 1 ;; esac ;; esac
    case "$roster" in
      *" $host "*) return 1 ;;
      *) printf 'owner host %s is not in CLAIM_KNOWN_HOSTS' "$host"; return 0 ;;
    esac
  fi
  return 1
}

# claim_key <pr> <head-sha> -> "<pr>-<sha12>"   (the content address)
claim_key() { printf '%s-%s' "$1" "${2:0:12}"; }

# claim_ref <pr> <head-sha> -> "refs/claims/<pr>-<sha12>"
claim_ref() { printf '%s/%s' "$CLAIM_NS" "$(claim_key "$1" "$2")"; }

# ── THE ISSUE KEY: "issue-<N>", ONE REF PER ISSUE (agent-infra#1850) ──────────────────────────
# An issue has no head sha, so `claim_ref <pr> <sha>` cannot express it at all — `claim_live`
# returns 1 on an empty sha and the WHOLE registry is bypassed for issue dispatch. This is the
# keying that expresses it.
#
# ⛔ THE KEY IS THE ISSUE ALONE — NOT `issue-<N>-<box-id>`. The box id lives in the claim commit's
# `owner=` field (where it already lives for PR claims), NOT in the key, and that is load-bearing:
#   • A KEY CONTAINING THE BOX ID IS NOT A CAS. Two boxes mint two DISTINCT refs and BOTH pushes
#     succeed, so the ref can only be READ, never WON. The pre-flight read is not enough to close
#     the gap on its own: it runs BEFORE the claim, so both boxes can read CLEAN and then both
#     claim. Only a mutually-exclusive ref makes the second acquisition impossible rather than
#     merely unlikely.
#   • IDEMPOTENT FOR THE SAME WORK. One issue is one work item, so `issue-<N>` is its content
#     address exactly as `<PR>-<sha12>` is the head's: a re-acquire for the same issue lands on the
#     same ref (and is refused while the holder's lease is live), never on a fresh one.
#   • DISJOINT FROM THE PR KEY. A PR claim is `<number>-<sha12>`; the `issue-` prefix cannot collide
#     with it, so an issue claim is never blocked by — and never blocks — a PR claim for the same
#     number (`refs/claims/1850-abcdef123456` and `refs/claims/issue-1850` are different refs).
#
# ⛔ THE REF'S HOME IS THE **TARGET REPO'S** ORIGIN — the repo whose issue number is claimed, i.e.
# whatever `CLAIM_REPO` points at (the same repo the PR claims already go to). It is NOT the harness
# repo. Every would-be dispatcher of that issue already resolves `$REPO`/`--repo` to it, so it is
# the one namespace all of them read; a claim pushed into agent-infra would be invisible to a peer
# dispatching tortoise — which is exactly the 2026-10-16 collision (two cells dispatched tortoise
# issues while running the agent-infra harness).
claim_issue_key() { printf 'issue-%s' "$1"; }

# claim_issue_ref <issue> -> "refs/claims/issue-<N>"
claim_issue_ref() { printf '%s/%s' "$CLAIM_NS" "$(claim_issue_key "$1")"; }

# ── THE LANDING KEY: "pr-<N>", ONE REF PER PR (agent-infra#1952) ──────────────────────────────
# Why a SECOND ref rather than re-keying the review claim: the issue number and the head sha are
# different content addresses and only the head is additive. A `pr-<N>`-only registry would make a
# pushed update wait behind a stale claim for its predecessor head — the exact defect rec 1 above
# was written to remove — and it would also serialise two boxes that are legitimately reviewing two
# different heads of one PR, which multiplies review cost across the fleet for no safety gain. So
# the per-head key stays the review/evidence key and `pr-<N>` is taken ONLY by the landing path
# (`merge-one.sh`), which is the one operation #1908's table says cannot tolerate a duplicate.
#
# ⛔ THE KEYS CANNOT COLLIDE, AND THAT IS WHY `pr-` IS A PREFIX AND NOT A BARE NUMBER. A per-head
# key is `<N>-<sha12>`, so a bare `<N>` would in fact be disjoint too — but `pr-<N>` also cannot be
# confused with `issue-<N>` (the two `-` prefixed forms are visibly the same family), and a reader
# of `refs/claims/1850` alone could not tell which question it answers. One ref, one question.
#
# ⛔ HOLD ORDER IS FIXED: pr-<N> FIRST, THEN <N>-<sha12>. merge-one.sh takes them in that order at
# every ingress, so the two locks have a total order and cannot deadlock by being taken in opposite
# orders by two boxes. Both REFUSE rather than block (a claim is a CAS, not a mutex), so a transient
# head-first holder only costs one cycle.
claim_pr_key() { printf 'pr-%s' "$1"; }

# claim_pr_ref <pr> -> "refs/claims/pr-<N>"
claim_pr_ref() { printf '%s/%s' "$CLAIM_NS" "$(claim_pr_key "$1")"; }

# ── THE BRANCH KEY: "branch-<slug>", ONE REF PER BATCH BRANCH (agent-infra#3328) ─────────────
# WHY A THIRD KEY. The per-head key answers "who is reviewing this commit" and `pr-<N>` answers
# "who is landing this PR". Neither answers "who may MOVE this branch" — and a BATCH branch is the
# one ref the fleet writes from several lanes at once. Measured 2026-11-03: a live peer pushed
# `f8842dc7e` onto `integration/land-batch-2` at 01:48:47Z, ~43 min after two reviewers signed
# `004d5afa4` and the 377-test suite ran. The push superseded the head, the per-PR `concurrency`
# group (tortoise ci.yml, `cancel-in-progress: true`) cancelled run 41557371710, and ELEVEN already
# green jobs were discarded with it. `gh run rerun --failed` cannot recover them: the run was
# cancelled, not failed, and a QUEUED job may never be "marked" green. The loss was not CI's — it
# was two lanes owning one branch.
#
# ⛔ IT IS THE SAME REGISTRY, NOT A SECOND ONE. Same CAS core (`_claim_acquire_at`), same lease-as-
# data, same fencing, same reaper, same `refs/claims/*` namespace. A second registry would have to
# re-derive the polarity of every one of those (this file's most expensive lesson, §_lease_is_live),
# and the two would drift exactly where it matters: on "is this free?".
#
# ⛔ THE SLUG IS THE BRANCH NAME, MADE REF-SAFE, AND IT MUST BE INJECTIVE ENOUGH TO NOT MERGE TWO
# BRANCHES. `integration/land-batch-2` -> `integration-land-batch-2`. Every character outside
# `[A-Za-z0-9._-]` becomes `-`, and a run of them collapses to one, so `a/b` and `a-b` DO collide —
# which is why the guard also compares the FULL branch name: the ref is the lock, the recorded branch
# name is the identity check (see claim_branch_guard). A collision can therefore only ever produce a
# refusal (two names sharing a lock), never a stray push that looks owned.
claim_branch_slug() {
  printf '%s' "${1:-}" | sed -e 's#[^A-Za-z0-9._-]#-#g' -e 's#--*#-#g' -e 's#^-*##' -e 's#-*$##'
}

# claim_branch_key <branch> -> "branch-<slug>"
claim_branch_key() {
  local s; s="$(claim_branch_slug "${1:-}")"
  # An empty slug would mint `refs/claims/branch-` — one lock shared by every unnamable input. Refuse
  # it by returning a key no branch can produce, so the caller's CAS fails loudly instead of silently
  # serialising unrelated branches.
  [ -n "$s" ] || s="__unnamed__"
  printf 'branch-%s' "$s"
}

# claim_branch_ref <branch> -> "refs/claims/branch-<slug>"
claim_branch_ref() { printf '%s/%s' "$CLAIM_NS" "$(claim_branch_key "$1")"; }

# claim_branch_acquire <repo> <branch> [ttl] — the same CAS, keyed by BATCH BRANCH (#3328).
# Sets CLAIM_RESULT / CLAIM_COMMIT / CLAIM_REF / CLAIM_OWNER exactly as its siblings do, so a caller
# that already handles rc=1 (another lane owns it) and rc=2 (infra) needs no new vocabulary.
claim_branch_acquire() {
  _claim_acquire_at "$(claim_branch_ref "${2:-}")" "${3:-$CLAIM_BRANCH_TTL}" "$CLAIM_BRANCH_TTL" "$CLAIM_BRANCH_TTL"
}

# claim_branch_release <repo> <branch> [<own-commit>] — fenced release of a BRANCH claim (#3328).
claim_branch_release() {
  _claim_release_at "$(claim_branch_ref "${2:-}")" "${3:-}"
}

# claim_branch_status <repo> <branch> -> "owner\tlease_until", rc=1 if unheld (#3328)
claim_branch_status() { _claim_status_at "$(claim_branch_ref "${2:-}")"; }

# claim_branch_preflight <branch> — 0 CLEAN / 1 COLLISION / 2 INCOMPLETE, same polarity as the
# issue- and PR-keyed reads (an abstention is NOT permission).
claim_branch_preflight() {
  _claim_preflight_at "$(claim_branch_ref "${1:-}")" "branch ${1:-?}"
}

# ── THE BRANCH CLAIM'S LOCAL TOKEN (agent-infra#3328) ───────────────────────────────────────
# The holder's own claim commit, on disk, under the SAME `state/issueclaim-<N>` convention the issue
# claim uses. The PRE-PUSH GUARD cannot ask "is this process the owner?" — it runs in a child of
# whatever pushed — so it asks the question the fence can answer: *does this checkout hold the claim
# commit that is currently the ref's tip?* Only the acquire that won the CAS ever writes that file,
# and a peer's push does not carry it. The token is therefore a possession proof, not a liveness
# probe, and it is exactly the fencing token `--force-with-lease` already uses.
# ⛔ THE TOKEN IS PER-CHECKOUT, NOT PER-BOX, AND THAT IS THE WHOLE POINT. The incident's peer was a
# LATER LANE, possibly on this same machine (the fleet runs several lanes per box), so a token in the
# box's shared state dir is readable by every lane on that box — measured in this suite's first run,
# where a "stray" clone on the same box read the owner's token and its push was ALLOWED through the
# guard. The token therefore lives in the CLAIM_REPO's own git dir: two lanes are two checkouts, and
# a lane that never acquired the claim simply has no file.
claim_branch_token_path() { # <branch> [<dir>] -> path of this checkout's token file
  local br="${1:-}" dir="${2:-${CLAIM_BRANCH_TOKEN_DIR:-}}"
  if [ -z "$dir" ]; then dir="$(_git rev-parse --absolute-git-dir 2>/dev/null)"; fi
  [ -n "$dir" ] || dir="$CLAIM_BRANCH_STATE_DIR"
  printf '%s/branchclaim-%s' "$dir" "$(claim_branch_key "$br")"
}

claim_branch_record() { # <token-file> <branch> <own-commit> -> 0 written, 1 nothing
  local file="${1:-}" br="${2:-}" own="${3:-}"
  [ -n "$own" ] && [ -n "$br" ] && [ -n "$file" ] || return 1
  mkdir -p "$(dirname -- "$file")" 2>/dev/null || return 1
  printf '%s\n%s\n%s\n' "$br" "$own" "$(claim_owner)" > "$file" || return 1
  printf '%s' "$file"
  return 0
}

# claim_branch_token <token-file> -> the holder's own claim commit on stdout, or rc=1 when this
# checkout holds no token for that branch (a stray lane, or a released claim).
claim_branch_token() {
  local file="${1:-}" rec own
  [ -n "$file" ] && [ -r "$file" ] || return 1
  # LINE 1 IS THE IDENTITY, LINE 2 THE FENCE. A file written for a DIFFERENT branch under the same
  # slug (the collision claim_branch_slug's header names) must not pass as this branch's token.
  rec="$(sed -n 1p "$file" 2>/dev/null)"
  own="$(sed -n 2p "$file" 2>/dev/null)"
  case "$own" in ''|*[!0-9a-f]*) return 1 ;; esac
  [ "${#own}" -eq 40 ] || return 1
  printf '%s\t%s' "$rec" "$own"
}

claim_branch_forget() { # <token-file>
  local file="${1:-}"
  [ -n "$file" ] || return 0
  rm -f "$file" 2>/dev/null || return 0
}

# ── THE PUSH BOUNDARY: claim_branch_guard (agent-infra#3328) ───────────────────────────────
# THE GATE ITSELF. A pre-push hook (or any push wrapper) calls this with the branch it is about to
# move; rc=0 means PUSH, anything else means REFUSE and the caller must abort the push.
#
# ⛔ WHAT MAKES IT A REFUSAL RATHER THAN ADVICE. The claim ref's tip IS the holder's claim commit,
# and only the acquire that won the CAS wrote that commit into this checkout's token file
# (claim_branch_record). So "may I push?" reduces to "does this checkout hold the token that is
# currently the ref's tip?" — a possession proof the registry already mints, with no new state and
# no second registry. A stray lane has no token for the branch (it never acquired it), and a token
# left over from a claim that has since been released/reclaimed no longer matches the tip, so the
# fencing property is inherited: the loser of a race cannot push on the strength of a stale token.
#
# ⛔ THE UNCLAIMED CASE IS ALLOWED, AND ONLY THE UNREADABLE CASE FAILS CLOSED. Refusing an unclaimed
# branch would break every existing push to `integration/*` the moment this ships, including the
# owner's own first push — a fail-closed default that trades a silent loss for a loud outage. An
# UNREADABLE registry is the opposite: an abstention is not permission (this file's doctrine), and
# it is precisely the case where a stray push would go through unnoticed.
#
# claim_branch_guard <branch>  -> 0 PUSH, 1 REFUSED (held by someone else), 2 UNREADABLE
# Sets CLAIM_RESULT (one line, always naming the holder when one is known) and echoes it.
claim_branch_guard() {
  local br="${1:-}" ref out rc cur own owner until now lease tmp orph
  # ⛔ `$'\t'`, NOT `\t`: inside a quoted case pattern a plain `\t` is a literal backslash-t, so the
  # tab half of this test could never fire (measured inert — deleted-or-fixed rather than left looking
  # load-bearing). git rejects such refnames before a hook runs, so this is a cheap last line only.
  case "$br" in ''|*' '*|*$'\t'*) CLAIM_RESULT="branch-claim: REFUSED branch=<unreadable> reason=no-branch"; echo "$CLAIM_RESULT"; return 1 ;; esac
  ref="$(claim_branch_ref "$br")"
  # ⛔ THE EXIT STATUS IS THE DISTINCTION (the same split every pre-flight here makes): `ls-remote`
  # exits 0 with EMPTY output when the ref does not exist, NON-ZERO only when the remote could not be
  # consulted. Collapsing the two reads an outage as "unclaimed" and lets the stray push through.
  out="$(_git ls-remote origin "$ref" 2>/dev/null)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    CLAIM_RESULT="branch-claim: REFUSED branch=$br reason=registry-unreadable — cannot prove ownership, so the push is refused rather than guessed ($(_claim_repo_problem))"
    echo "$CLAIM_RESULT"; return 2
  fi
  cur="$(printf '%s\n' "$out" | awk '{print $1}')"
  if [ -z "$cur" ]; then
    CLAIM_RESULT="branch-claim: PUSH branch=$br reason=unclaimed — no branch claim is held, nothing to refuse"
    echo "$CLAIM_RESULT"; return 0
  fi
  # THE TOKEN CHECK — the fence. Owning the tip is owning the branch.
  local tok rec
  tok="$(claim_branch_token "$(claim_branch_token_path "$br")")" || tok=""
  rec="${tok%%$'\t'*}"; own="${tok##*$'\t'}"
  # The slug can collide across branch names (see claim_branch_slug); the recorded NAME is what makes
  # the token this branch's, so a collision refuses rather than authorises.
  [ "$rec" = "$br" ] || own=""
  if [ -n "$own" ] && [ "$own" = "$cur" ]; then
    CLAIM_RESULT="branch-claim: PUSH branch=$br reason=held-by-you holder=$(claim_owner)"
    echo "$CLAIM_RESULT"; return 0
  fi
  # Not ours. Read the lease so the refusal can name the holder and say who to ask.
  owner="?"; until="0"
  tmp="$CLAIM_TMP_NS/brguard-$RANDOM$$"
  if _git fetch -q origin "+$ref:$tmp" 2>/dev/null; then
    lease="$(_lease_of "$tmp")"; owner="${lease%%$'\t'*}"; until="${lease##*$'\t'}"
    _git update-ref -d "$tmp" 2>/dev/null
  else
    _git update-ref -d "$tmp" 2>/dev/null
    CLAIM_RESULT="branch-claim: REFUSED branch=$br reason=claim-unreadable — a claim ref exists but its lease could not be read, so ownership cannot be proven"
    echo "$CLAIM_RESULT"; return 2
  fi
  now="$(date +%s 2>/dev/null)"
  # ⛔ SHAPE **AND MAGNITUDE**, THE SAME ARM AS EVERY OTHER CLOCK GUARD (review round 11,
  # agent-infra#3203). Shape alone let `0`, a leading-zero clock and a 20-digit one through to
  # `_lease_is_live` → `_claim_lease_state` → `unknown`, which this guard then published as
  # `reason=held-by-live` with the remedy "wait for the lease to expire" — a nominal LIVE holder for a
  # window nobody can judge, and a remedy that can never fire. Every sibling guard names the clock; so
  # must this one.
  case "${now:-}" in
    ''|0|0?*|*[!0123456789]*|?????????????*) CLAIM_RESULT="branch-claim: REFUSED branch=$br holder=$owner reason=clock-unreadable — the lease cannot be judged, so ownership cannot be proven"; echo "$CLAIM_RESULT"; return 2 ;;
  esac
  # ⛔ AN UNPARSEABLE TERM IS ITS OWN REFUSAL (agent-infra#3203). The refusal itself is unchanged and
  # correct — the guard does not take claims, so an unjudgeable term still refuses the push — but
  # publishing it as `held-by-live` told every reader this branch has a LIVE holder, which is the one
  # thing this reader cannot know. The token says what is true: the CLASS is unreadable, and the
  # bounded reap (`claim_prune`, claim-commit age > CLAIM_UNREADABLE_LEASE_MAX_AGE) or the named
  # hand remedy is how it ends.
  if _lease_unparseable "$until"; then
    CLAIM_RESULT="branch-claim: REFUSED branch=$br holder=$owner reason=lease-unreadable — the claim's lease ('$until') cannot be parsed, so its window is UNKNOWN: an ABSTENTION, never read as a live claim and never treated as free. claim_prune reaps it once the claim commit is older than ${CLAIM_UNREADABLE_LEASE_MAX_AGE}s, or ask $owner to release it (branch-claim.sh release $br); deleting the ref by hand also works (agent-infra#3203)"
    echo "$CLAIM_RESULT"; return 1
  fi
  if _lease_is_live "$until" "$now"; then
    # ⛔ AN ORPHANED HOLDER IS REPORTED, NOT SILENTLY OBEYED OR SILENTLY IGNORED. A dead holder's
    # term remains a refusal HERE (unlike the pre-flight, which reports it reclaimable) because the
    # guard does not take claims — it only answers "may this push proceed". The remedy is named.
    orph="$(claim_orphan_reason "$owner" "$ref" 2>/dev/null)" || orph=""
    CLAIM_RESULT="branch-claim: REFUSED branch=$br holder=$owner until=$until reason=held-by-live${orph:+ detail=orphaned-holder:$(printf '%s' "$orph" | tr ' ' '_')} — this branch is single-owner; ask $owner to release it (branch-claim.sh release $br on the holder's box) or wait for the lease to expire, then acquire before pushing"
    echo "$CLAIM_RESULT"; return 1
  fi
  # Expired but not pruned: still not THIS actor's claim, so still a refusal. The reclaim is a CAS
  # (branch-claim.sh acquire) that must be taken before pushing — which is exactly the ordering that
  # stops the stray push.
  CLAIM_RESULT="branch-claim: REFUSED branch=$br holder=$owner until=$until reason=claim-expired-unreclaimed — the stale claim must be reclaimed (branch-claim.sh acquire $br) before anyone pushes"
  echo "$CLAIM_RESULT"; return 1
}

# _claim_commit <owner> <lease_until> -> commit sha carrying the lease as data
#
# ⛔ THE NONCE IS LOAD-BEARING, NOT DECORATION (P1 in the 2026-10-14 export review). A claim commit
# is a ROOT commit whose entire content is this message, and git stamps it with the current SECOND,
# so two acquisitions with the SAME owner and the SAME lease second build a BYTE-IDENTICAL object.
# Pushing an identical commit to a ref that already holds it exits 0 ("Everything up-to-date"), the
# read-back below then matches, and the SECOND box reports `acquired` — the CAS is silently
# defeated. It does not corrupt state (it degrades to the tolerated duplicate execution and fencing
# is by the same sha), but it makes cross-box atomicity untestable, so test-claims.sh's headline
# assertion was flaky and must not be trusted as the cross-box proof. A unique object per
# acquisition turns the loser's push into a genuine non-fast-forward rejection.
# ⛔ IT NEVER RETURNS 0 WITH NO EXPLANATION. The old body was
#   _cg commit-tree … 2>/dev/null
# so EVERY failure mode — no repo, unreadable cwd, a git that is a shim, an unset EMPTY_TREE —
# arrived at the caller as an empty string, and the caller could only say "could not build claim
# commit". stderr is captured now and the sha is VALIDATED (a 40-hex line), so a warning on stderr
# cannot be mistaken for a commit.
# Emits the sha on stdout (the test seams hand-build leases with `$( _claim_commit … )`) and also
# records it in CLAIM_COMMIT_OUT/CLAIM_COMMIT_ERR, because a caller that needs the REASON must call
# this NOT in a command substitution — see _claim_acquire_at.
# ⛔ THE FAILURE PATH RETURNS 2, NOT 0 (review catch, 2026-10-18). The globals are set INSIDE the
# substitution's subshell, so a `$( )` caller only ever sees stdout + the exit status — with `return
# 0` it saw "success, empty string", and two seams then chained `git push "$c:$ref"` on it, where an
# empty source is a REFSPEC THAT DELETES the ref. The direct caller ignores the status and reads the
# globals, so returning 2 changes nothing for it.
_claim_commit() {
  local out rc sha why
  out="$(_cg commit-tree "$EMPTY_TREE" -m "claim owner=$1 lease_until=$2 nonce=$RANDOM$RANDOM$$-$(date +%s%N)" 2>&1)"; rc=$?
  sha="$(printf '%s\n' "$out" | grep -E '^[0-9a-f]{40}$' | head -1)"
  if [ "$rc" -eq 0 ] && [ -n "$sha" ]; then
    CLAIM_COMMIT_OUT="$sha"; CLAIM_COMMIT_ERR=""
    printf '%s\n' "$sha"
    return 0
  fi
  CLAIM_COMMIT_OUT=""
  why="$(_claim_repo_problem)"
  # Prefer the repo diagnosis (it names the fix); otherwise report git's own words.
  CLAIM_COMMIT_ERR="${why:-git commit-tree exited $rc: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)}"
  return 2
}

# _lease_of <ref> -> "owner lease_until" parsed from the claim commit message ("" if absent)
_lease_of() {
  local msg line o u
  msg="$(_git cat-file commit "${1:-}" 2>/dev/null | sed -n '/^$/,$p' | tail -n +2 | tr -d '\r')"
  # ⛔ ONE LINE IN, ONE ANSWER OUT — AND THE FIRST FAITHFUL TOKEN OF EACH FIELD (review rounds 11–12,
  # agent-infra#3203). Two separate defects lived in the old two-`sed` form, and both were measured:
  #   * a greedy leading `.*` bound the LAST occurrence on the line, while `claim_lanes.py`
  #     (`re.findall` → first) and `merge-reminder.py` (`re.search` → leftmost) take the FIRST — so
  #     `lease_until=9999999999 … lease_until=1` read EXPIRED/FREE here and LIVE there;
  #   * and simply dropping the `.*` is not the fix either: `sed 's/lease_until=\([0-9]*\)…/\1/p'`
  #     prints the WHOLE line with the match replaced, so the capture came back wrapped in
  #     "claim owner=… " — a broken reader that still looked plausible.
  # So: the FIRST non-empty line of the body (the line the writer minted), split into WORDS, and the
  # first word of each field taken whole. A second `claim …` line, or a repeated field, is peer-planted
  # junk and cannot contribute — which is also why `lease_until=1junk` yields nothing at all (the token
  # must be ALL digits): the value is a value or it is unparseable, never a truncated prefix.
  line="$(printf '%s' "$msg" | awk 'NF { print; exit }')"
  o="$(printf '%s' "$line" | tr ' \t' '\n\n' | sed -n 's/^owner=//p' | head -n 1)"
  u="$(printf '%s' "$line" | tr ' \t' '\n\n' | sed -n 's/^lease_until=\([0123456789][0123456789]*\)$/\1/p' | head -n 1)"
  printf '%s\t%s' "${o:-?}" "${u:-0}"
}

# _claim_commit_time <rev> -> the claim commit's OWN committer epoch on stdout, rc=1 when unreadable
#
# ⛔ THIS IS THE BOUNDED-SCHEDULE INPUT (agent-infra#3203), AND IT IS READ FROM THE OBJECT, NOT FROM
# `git log`: the claim ref may already be deleted by the time a caller wants the age, and a dangling
# commit resolves only until the next `gc`/`prune` — a bound that reads its own input only sometimes
# is not a bounded schedule. `cat-file commit` is also the verb `_lease_of` already uses, so the
# test harness's static verb allow-list needs no new arm.
# ⛔ AN UNREADABLE OR FUTURE STAMP RETURNS NOTHING (rc=1 is only for "cannot read"; a future stamp is
# reported by the CALLER, which is the only place that knows what "future" means here).
_claim_commit_time() {
  local raw ct
  raw="$(_git cat-file commit "${1:-}" 2>/dev/null)" || return 1
  # ⛔ THE HEADER BLOCK ONLY (`sed -n '/^$/q;p'` stops at the blank line git puts before the
  # message). The lease body is PEER-WRITABLE, so a commit whose MESSAGE carries a line shaped like
  # `committer Evil <e@x> 1 +0000` used to supply the age: git dates the commit from the header and
  # this parse from the last shaped line anywhere in the object — so the message line wins, age ≈ 1.7e9
  # and the reaper deletes a claim `git log --format=%ct` dates as seconds old (measured; a FUTURE-dated
  # message line pins it past the bound for ever). _lease_of already scopes to the body the same way.
  # ⛔ EVERY DIGIT CLASS SPELLED OUT (review round 19, agent-infra#3203). This sed was added by THIS
  # change and used `[0-9]`, the one construct the rest of the change bans: a POSIX bracket RANGE is a
  # COLLATION question, and under `en_US.utf8` (installed here, macOS's default) it matches U+0663 —
  # measured: `sed s/[0-9]/X/` turned `٣` into X, `sed s/[0123456789]/X/` did not. The enumerated `case`
  # below rejects the result, so there is no fail-open today, but the parse must not depend on the
  # downstream guard to stay ASCII.
  # ⛔ THE PARSE IS BYTE-ORIENTED, SO ITS ANSWER DOES NOT DEPEND ON THE BOX'S LOCALE (review round 26).
  # `sed`'s `.` does not consume an INVALID UTF-8 byte under a UTF-8 locale, so a `committer` line
  # carrying one (a latin-1 name, or a peer-forged byte — the header is peer-writable) matched here
  # under `LC_ALL=POSIX` and did NOT under `LC_ALL=C.UTF-8`: measured, the same object answered
  # `1700000000` on one box and UNMEASURABLE on the next, and `tools/fleet/claim_lanes.py`'s mirror
  # (which decodes with `errors="replace"`) answered a stamp in both. `git` itself dates that commit
  # fine — the encoding of a name has nothing to do with its timestamp — so the byte answer is the
  # correct one AND the one that stops this reader disagreeing with its own mirror. `LC_ALL=C` on the
  # three stages is the whole fix: `.` becomes byte-oriented, and every shape that measures today still
  # measures the same value.
  # ⛔ THE PARSE IS ANCHORED ON `> `, WHICH IS THE IDENT'S END — NOT A BARE `.* ` (review round 22,
  # agent-infra#3203). The greedy `.* ` took the LAST `digits [+-]dddd` pair ANYWHERE on the line
  # instead of the ident's timestamp field, so the same one-push attack this arm exists to stop came
  # straight back through a different token: measured on the shipped file,
  #
  #   committer a <a@b> <NOW> +0000 1 +0000   -> git %ct = NOW      (0 s old)
  #                                          -> _claim_commit_time = 1
  #
  # and `claim_prune` then DELETED the claim as `1793991810s old, PAST the 18000s bound`. The `> ` anchor
  # means the accepted stamp is the one in the field git reads, and any OTHER `digits +-dddd` tail is
  # simply not a match — which lands on rc=1 (unmeasurable, KEPT and NAMED) instead of a forged age.
  # A76-A78 only exercised a token the `$` anchor REJECTS (`+0000 junk`), so they pinned the shape of the
  # fallback and not this: A79 drives a token that PARSES and must still not become the value.
  # ⛔ THE LAST `>` IS GIT'S OWN SPLIT POINT (review round 27, agent-infra#3203). Round 27 was opened on a
  # review finding claiming git reads the FIRST `<`…FIRST `>` span, and that
  # `committer a <a@b> <NOW> +0000 > 1 +0000` is dated NOW by git.
  # MEASURED against git 2.43.0 (`git hash-object -w -t commit --literally` + `git log -1 --format=%ct`),
  # that premise is FALSE and the fix built on it was a REGRESSION: git dates the object from the field
  # after the LAST `>`,
  #
  #   committer a <a@b> 1794013553 +0000                       git %ct = 1794013553
  #   committer a <a@b> 1794013553 +0000 > 1 +0000             git %ct = 1            <- `.*> ` AGREES
  #   committer a <a@b> 1794013553 +0000 <c@d> 1 +0000         git %ct = 1            <- `.*> ` AGREES
  #   committer a <a@b> 111 +0000 > 222 +0000 > 333 +0000     git %ct = 333          <- `.*> ` AGREES
  #   committer a <a@b> 1794013553 +0000 1 +0000              git %ct = 1794013553   <- `.*> ` abstains
  #   committer a <a@b> 1794013553 +0000 junk                 git %ct = 1794013553   <- `.*> ` abstains
  #
  # so a mail-span anchor (`[^<]*<[^>]*>`) turned every object git dates ANCIENT into an UNMEASURABLE one.
  # `claim_prune` `continue`s on an unmeasurable age BEFORE the bound is compared, so a peer appending
  # ` > 1 +0000` would have held its claim FOR EVER — #3203's eternal hold restored, through the reaper
  # reporting itself healthy. That is why the anchor is git's, not the mail span's.
  # ⛔ THE INVARIANT, STATED SO IT CAN BE TESTED: **when this parse measures, it must equal
  # `git log -1 --format=%ct`; it may only ABSTAIN where git is more tolerant than the `$` anchor.**
  # The remaining divergence classes are TOLERANCES, not disagreements — and there is more than one. The
  # `$` anchor refuses the whole line where git stops after the tz digits: a trailing token or trailing
  # whitespace, a CR before EOL, a tz field that is NOT exactly 4 digits (`> 1 +000`, `> 1 +0` and
  # `> 1 +00000` are each dated 1 by git 2.43.0), and a TAB or NO separator before it (`<NOW>\t+0000` and
  # `<NOW>+0000` are both dated NOW) — this parse abstains on every one. A tz with NO SIGN abstains here
  # TOO, but it is NOT a divergence: git ACCEPTS and PUSHES that object (MEASURED — `cat-file -t` says
  # commit, a push to a bare repo lands the ref, and only `git fsck` reports `badTimezone`) and simply has
  # no committer date for it, so `git log -1 --format=%ct` prints NOTHING at rc 0. There is therefore no
  # git answer to agree with, and the abstention is the KEEP side. Two further classes abstain in the
  # LENGTH / leading-zero arms BELOW rather than in the anchor: a 13+ digit and a
  # leading-zero stamp are MEASURED here at git's own value and then rejected there (rounds 19/21) — a
  # deliberate class, not a disagreement. Those arms are pinned by `claim_lanes.test.py` (the 13-digit and
  # `0999` cases) and, for the shell's leading-zero arm, by `test-claims.sh` A33; `claim-reaper.test.sh`
  # pins the ANCHOR abstentions above (`+0000 ` and `+000`), NOT these. The shell's 12-digit cap itself has
  # no pin at all — no fixture feeds it a 13+ digit stamp. Every one of them lands in the KEEP
  # direction (A79 pins that decision, A88-A92 pin the agreement with git on the shapes where it matters,
  # including the `> 1 +0000` shapes git dates 1970 that must be REAPED and the `1 +0000 > <NOW> +0000`
  # reverse sign that must NOT be). A76-A78 only exercised a token the `$` anchor REJECTS, so they pinned
  # the shape of the fallback and not this.
  # ⛔ THE ANCHOR IS `>` + **ANY WHITESPACE** (`[[:blank:]]*`), NOT `> ` + EXACTLY ONE SPACE (review round
  # 28, agent-infra#3203). git does not require a space after the split `>`: it skips whitespace before the
  # date field, so zero, one, two or three spaces and a TAB all yield the SAME answer. MEASURED against git
  # 2.43.0 (`hash-object -w -t commit --literally` + `git log -1 --format=%ct`), `N = 1794013553`:
  #
  #   committer a <a@b> N +0000 > 1 +0000            git %ct = 1   one space
  #   committer a <a@b> N +0000 >  1 +0000           git %ct = 1   TWO spaces
  #   committer a <a@b> N +0000 >   1 +0000          git %ct = 1   three spaces
  #   committer a <a@b> N +0000 ><TAB>1 +0000        git %ct = 1   tab
  #   committer a <a@b> N +0000 >1 +0000             git %ct = 1   NO space at all
  #   committer a <a@b> 1 +0000 >  N +0000           git %ct = N   reverse sign, two spaces
  #
  # A literal single space abstained on every row but the first, and for `>  1 +0000` the PREVIOUS parser
  # (`.* `) had measured git's own answer — so the `> ` form turned a REAP into a HOLD for a claim git
  # dates 1970. Writing the two divergence classes into a comment would have left a git-ancient claim
  # unreapable on a shape nobody pinned; making the anchor git's own rule removes the class instead.
  # A93-A95 pin it (oracle + reader + the reap), so it cannot silently move back.
  # ⛔ BOTH PROPERTIES ARE KEPT TOGETHER: byte-orientation (LC_ALL=C) decides WHICH BYTES are examined,
  # and the `> ` anchor decides WHICH FIELD may become the value. Neither implies the other — a
  # byte-oriented greedy `.* ` still read a forged second `digits +dddd` tail, and an anchored
  # locale-dependent `.` still answered differently on two boxes for the same object.
  ct="$(printf '%s' "$raw" | LC_ALL=C sed -n '/^$/q;p' | LC_ALL=C sed -n '/^committer /p' | tail -n 1 \
        | LC_ALL=C sed -n 's/^committer .*>[[:blank:]]*\([0123456789][0123456789]*\) [+-][0123456789][0123456789][0123456789][0123456789]$/\1/p')"
  # ⛔ SELECT THE LAST `committer` LINE *FIRST*, THEN PARSE IT (review round 20, agent-infra#3203). The
  # parse above used to be ONE anchored `sed` piped to `tail -n 1`, which selects "the last line that
  # MATCHES", not "the last committer line". Git dates the object from the last `committer` header
  # whatever else the line carries, so a newest header with ANY trailing token
  # (`committer a <a@b> 1 +0000 junk`) is filtered out by the `$` anchor and `tail` then returns an
  # EARLIER committer line — measured: a claim `git log --format=%ct` dates as 1 s old was reaped with
  # `the claim commit is 1793991810s old, PAST the 18000s bound`, i.e. the exact forged-age steal the
  # two-header rule above exists to close, one token over. Selecting and parsing are two steps for that
  # reason: a NEWEST header this parser cannot read makes the age UNMEASURABLE (rc=1 below, so the
  # caller keeps and NAMES the claim), never a silent fallback to older text.
  # ⛔ TAIL, NOT HEAD — GIT TAKES THE LAST COMMITTER LINE (review, agent-infra#3203). A crafted commit
  # carrying two `committer` headers (`git hash-object -t commit --literally`, which a strict fsck still
  # accepts) is dated by GIT from the LAST one and by `head -n 1` from the FIRST — so an attacker writes
  # `committer … 1 +0000` then `committer … <now> +0000`, the reaper reads a 1-second-old claim and
  # reaps it while `git log` says it is fresh. Same parse as git, or the bound is a guess.
  # ⛔ DIGIT SHAPE IS NOT ENOUGH — THE VALUE BECOMES AN ARITHMETIC OPERAND (review, agent-infra#3203).
  # `$(( now - ct ))` reads a LEADING-ZERO operand as OCTAL, so a peer-writable `0000009999` aborts the
  # arithmetic with `value too great for base` — a FATAL error that kills claim_prune's `| while read`
  # subshell, so every ref after it is never examined, nothing is printed, and the pass still exits 0.
  # That re-creates the permanent unreapable block this arm exists to end, and `git fast-import` writes
  # such a stamp with no flags. `0?*` is the same leading-zero arm `_lease_of`/the ttl clamps use; the
  # 12-digit cap keeps an epoch second (10 digits today) from ever reaching the comparison.
  case "${ct:-}" in ''|*[!0123456789]*|0?*) return 1 ;; esac
  [ "${#ct}" -le 12 ] || return 1
  printf '%s' "$ct"
}

# _lease_unparseable <lease_until> -> 0 when this reader cannot parse the lease at all
_lease_unparseable() {
  case "${1:-}" in
    # ⛔ A LEADING-ZERO LEASE IS UNPARSEABLE TOO (review, agent-infra#3203). `[` compares DECIMALLY, so
    # `0000009999` silently becomes 9999 — a 1970 window — and the five readers then call a planted
    # term EXPIRED and free: the acquire reclaims a peer's claim, `claim_prune` deletes it, and the
    # snapshot verdict answers `claim-expired` so the controller SPAWNS for that key. No legitimate
    # writer can mint one (the arithmetic and the ttl clamp both forbid it), which is exactly why the
    # answer must be the abstention, not a guess at what the writer meant. One arm, no fifth polarity.
    ''|0|0?*|*[!0123456789]*) return 0 ;;
  esac
  [ "${#1}" -gt 18 ]
}

# _claim_lease_state <lease_until> <now> -> live | expired | unreadable | unknown
#
# ⛔ FOUR ANSWERS, BECAUSE THE OLD TWO COLLAPSED A DISTINCTION THE FLEET COULD NOT AFFORD
# (agent-infra#3203). "live" and "unreadable" are the SAME answer to the ONE question this file's
# guard asks ("may I steal it?": no), and DIFFERENT answers to "what is this claim?" — and the
# second question is what every human and every log line reads. Publishing an unparseable lease as
# LIVE is how an eternal, unreapable block looked like a healthy busy fleet. `unreadable` is a claim
# that EXISTS whose term cannot be read; `unknown` is a parseable term with an unreadable LOCAL
# CLOCK. Neither is free, and neither is live.
_claim_lease_state() {
  _lease_unparseable "${1:-}" && { printf 'unreadable'; return 0; }
  # ⛔ THE CLOCK IS GUARDED EXACTLY LIKE THE WRITE SIDE GUARDS IT, AND THE COMPARISON IS NEVER
  # TRUSTED TO ANSWER WHEN IT ERRORS (review, agent-infra#3203 — a P1 the six earlier rounds missed).
  # `[ "$2" -le "$1" ]` returns **2** when an operand is not an integer, and `if [ … ]` reads that
  # exit as FALSE ⇒ the function said `expired` ⇒ every caller said FREE. Two ways to reach it, both
  # measured on the shipped file: a 20-digit clock (above 2**63) and a locale-collated non-ASCII
  # digit that slipped the old `[!0-9]`. The write side already refuses both shapes and the lease
  # side already bounds its own; the READ side is where the steal happens, so it must answer
  # `unknown` (an abstention) for anything it cannot compare, and a `$?` of neither 0 nor 1 is
  # exactly that case.
  case "${2:-}" in ''|0|0?*|*[!0123456789]*|?????????????*) printf 'unknown'; return 0 ;; esac
  [ "$2" -le "$1" ] 2>/dev/null
  case "$?" in
    0) printf 'live' ;;
    1) printf 'expired' ;;
    *) printf 'unknown' ;;   # neither live nor expired: the comparison itself failed
  esac
}

# _lease_is_live <lease_until> <now> -> 0 DO NOT STEAL (live, unreadable or unknown clock), 1 expired
#
# ⛔ THE ONE IMPLEMENTATION OF THE LEASE POLARITY (2026-10-16 review). Four readers used to derive
# it independently — claim_acquire, claim_issue_preflight, claim_prune and orch-loop.sh's
# claim_live — and a divergence between them is not a cosmetic defect: on 2026-10-14 a disagreement
# about exactly this datum made the controller re-spawn a refused fixer EVERY cycle, indefinitely,
# on a PR no box could work. claim_acquire already carried a note saying the bound must not be
# re-derived; three copies of it were still there. These three sites share this one. ⛔ AND SINCE
# agent-infra#2466 SO DOES THE FOURTH: `orch-loop.sh`'s snapshot reader no longer re-derives the
# polarity either — its `claim_lease_live` calls `claim_snapshot_verdict`, which calls THIS function.
# (The older note here said that reader "keeps its own copy deliberately because selftest.sh extracts
# it standalone"; that is no longer true of the code, and the suites now source this file alongside
# the extraction, so the exception it described is gone.)
#
# ⛔ AN UNPARSEABLE LEASE IS NEVER FREE — AND, SINCE agent-infra#3203, NEVER *CALLED* LIVE. An absent
# value, the `0` sentinel, any non-digit (a negative collapses to `0` in _lease_of, whose anchored
# ASCII-digit match
# cannot match a minus sign) and a 19+-digit value all mean "a claim EXISTS whose lease this reader
# cannot parse". The 18-digit bound is not tidiness: `[` ERRORS at or above 2**63 and an errored test
# is FALSE, so a full-width lease used to fall through to the reclaim path and STEAL a live claim.
# And the bound is 18, NOT 9, because a lease is an EPOCH SECOND (10 digits today) — a 9-digit bound
# would call every legitimate lease unparseable, so nothing would ever expire and the fleet would
# deadlock.
# ⛔ THE ANSWER AND THE CLASSIFICATION ARE NOW SEPARATE. This function still answers "do not steal"
# for `unreadable` (the recorded decision stands, and it is pinned): what changed is that it is now
# expressed through `_claim_lease_state`, so a reader that needs the CLASSIFICATION gets `unreadable`
# instead of a false "live", and the block is bounded on the REAP side (`claim_prune`,
# `CLAIM_UNREADABLE_LEASE_MAX_AGE`) rather than eternal.
#
# ⛔ AND AN UNREADABLE CLOCK IS NOT EVIDENCE OF EXPIRY (2026-10-16 review). `[ "" -le "$until" ]`
# prints "integer expression expected" and evaluates FALSE, and the OLD shape — two sequential `if`s
# whose fall-through was the CLEAN return — therefore reported a FALSE CLEAN whenever `date` could
# not be read. That is the one direction this gate must never fail in: it duplicates the work.
_lease_is_live() {
  # ⛔ ONE DERIVATION, NOT TWO: the four-way classification above is the only place the ordering is
  # written, so "what is this?" and "may I steal it?" can never disagree about one datum (the
  # 2026-10-14 incident recorded above is exactly that disagreement).
  [ "$(_claim_lease_state "${1:-}" "${2:-}")" != "expired" ]
}

# claim_acquire <repo> <pr> <head-sha> [ttl]
#   0 = acquired (or reclaimed an EXPIRED claim), 1 = held by a live claim, 2 = error
# Sets CLAIM_RESULT (human-readable reason), CLAIM_COMMIT, CLAIM_REF, CLAIM_OWNER.
# Echoes CLAIM_RESULT as well, so a caller in a subshell still sees the reason.
claim_acquire() {
  _claim_acquire_at "$(claim_ref "$2" "$3")" "${4:-$CLAIM_TTL}" "$CLAIM_TTL" "$CLAIM_TTL_MAX"
}

# claim_issue_acquire <repo> <issue> [ttl] — the SAME CAS, keyed by ISSUE (agent-infra#1850)
# Sets CLAIM_RESULT / CLAIM_COMMIT / CLAIM_REF / CLAIM_OWNER exactly as claim_acquire does, so a
# caller that already handles rc=1 (another box owns it) and rc=2 (infra) needs no new vocabulary.
# ⛔ The `<repo>` argument is API symmetry only, like claim_status's: every git call runs against
#    CLAIM_REPO, and claim_issue_ref takes the issue alone.
claim_issue_acquire() {
  _claim_acquire_at "$(claim_issue_ref "$2")" "${3:-$CLAIM_ISSUE_TTL}" "$CLAIM_ISSUE_TTL" "$CLAIM_ISSUE_TTL"
}

# claim_pr_acquire <repo> <pr> [ttl] — the SAME CAS, keyed by PR (agent-infra#1952)
# Sets CLAIM_RESULT / CLAIM_COMMIT / CLAIM_REF / CLAIM_OWNER exactly as claim_acquire does, so a
# caller that already handles rc=1 (another box owns it) and rc=2 (infra) needs no new vocabulary.
# ⛔ The default lease is the PR claim's own CLAIM_TTL, not the issue claim's 3 h: this claim covers
#    a review-plus-merge, exactly like the per-head claim it is taken alongside, and merge-one.sh
#    passes its own derived `REVIEW_TIMEOUT + _gw + 300` (`_gw` = the gate wait) explicitly rather
#    than relying on either default.
claim_pr_acquire() {
  _claim_acquire_at "$(claim_pr_ref "$2")" "${3:-$CLAIM_TTL}" "$CLAIM_TTL" "$CLAIM_TTL_MAX"
}

# _claim_acquire_at <ref> [ttl] [dflt] [max] — the ref-explicit CAS core that EVERY keying shares.
# `max` is the keying's documented CEILING (see CLAIM_TTL_MAX): a ttl above it is clamped to it, and
# an unparseable one falls back to `dflt`. Both exist so no caller can mint a term that outlives every
# reaper's reach (agent-infra#2094), while the shipped 3000s/3600s merge leases keep working.
# ⛔ ONE IMPLEMENTATION, EVERY KEY (per-head, issue, landing). A second copy of the CAS for a new key
# would let the keyings drift, and every property #1709 established (atomic create, nonce, read-back,
# lease-as-data, CAS reclaim, and the infra-vs-lost-race classification) is exactly what must NOT
# differ between them.
_claim_acquire_at() {
  local ref="$1" ttl="$2" dflt="${3:-$CLAIM_TTL}" max="${4:-$CLAIM_TTL_MAX}"
  # ⛔ THE ONCE-PER-PROCESS WARNING LIVES HERE, NOT ONLY IN `claim_owner` (agent-infra#2094 cycle-4
  # review). Every shipped mint is `CLAIM_OWNER="$(claim_owner)"`, and a flag set inside a command
  # substitution dies with the subshell — so a cell that inherited the seam logged one line per mint
  # instead of one per process. This function is called DIRECTLY by the shipped callers, so its flag
  # survives and the warning really is once.
  claim_host_warn_seam
  local now until commit back cur tmp perr after
  # A ceiling that arrived from a caller must obey the same digit clamp as the shipped one.
  case "${max:-}" in ''|*[!0123456789]*|0*) max="$CLAIM_TTL_MAX" ;; esac
  [ "${#max}" -le 9 ] || max="$CLAIM_TTL_MAX"

  # Same bound as CLAIM_TTL above, at the ARITHMETIC SITE, because `ttl` may arrive from the caller:
  # a leased value this function cannot parse back is worse than the default lease (see the note on
  # CLAIM_TTL). Leading zeros are refused for the same reason there — `$(( 08 ))` is an octal error.
  # ⛔ THE FALLBACK IS THE KEYING'S OWN DEFAULT (`dflt`), NOT a shared literal: a bad value for an
  # ISSUE claim must not silently become the PR claim's 1800s, which is SHORTER than LANE_TIMEOUT —
  # it would expire mid-lane and hand the issue to a peer (agent-infra#1850).
  case "${ttl:-}" in
    ''|*[!0123456789]*|0?*) ttl="$dflt" ;;
    0) ;;
    # ⛔ ABOVE THE CEILING CLAMPS TO THE CEILING, NOT TO THE DEFAULT (agent-infra#2094).
    # Falling back to `$dflt` here would silently SHORTEN a legitimate long lease (merge-one's 3000s
    # is above the 1800s PR default) — the claim would expire mid-merge and a peer would take the
    # same head, which is the duplicate the registry exists to prevent. Only an UNPARSEABLE value
    # falls back to the default; a parseable one is honoured up to the ceiling.
    # ⛔ A >9-DIGIT NUMERIC IS ABOVE THE CEILING, NOT UNPARSEABLE (P2, cycle-25 review). Routing it to
    # `$dflt` took the SHORTER-DEFAULT direction this block exists to prevent AND skipped the loud
    # clamp: measured, `claim_acquire … 1000001199` stamped 1797s (the 1800s PR default) with EMPTY
    # stderr while the 9-digit `999999999` stamped 7197s and said so. It is reachable from a shipped
    # caller — merge-one.sh's `is_limit` accepts a 9-digit REVIEW_TIMEOUT, so
    # `REVIEW_TIMEOUT=999999999` derives CLAIM_LEASE=1000001199 and a merge lease silently became
    # 1800s. Clamped to the ceiling, loudly, like every other above-ceiling value.
    *) if [ "${#ttl}" -gt 9 ]; then
         printf '[claims] lease ttl %ss has more than 9 digits — clamped to this keying ceiling %ss (agent-infra#2094).\n' \
           "$ttl" "$max" >&2
         ttl="$max"
       fi ;;
  esac
  if [ "$ttl" -gt "$max" ] 2>/dev/null; then
    # ⛔ LOUD, NOT SILENT. A clamp shortens a lease below what the caller asked for, and for
    # merge-one/fix-one that means expiring before the review window closes — a peer takes the same
    # head and the merge runs twice. That is the one consequence this bound must never hide.
    # ⛔ THE MESSAGE NAMES NO SINGLE KNOB AS THE CEILING, BECAUSE `max` IS NOT ALWAYS ONE (review
    # round 2, P2; the headline was over-stated until round 5). It used to read
    # "(CLAIM_TTL_MAX/CLAIM_ISSUE_TTL = %ss)" — and for a BRANCH key `max` is CLAIM_BRANCH_TTL
    # (14400), which is neither of those two variables (9600 / 18000). Measured on the real code, a
    # branch-key clamp printed "CLAIM_TTL_MAX/CLAIM_ISSUE_TTL = 14400s", sending a fixer to raise a
    # knob that is not the ceiling. The number was right and the two names were wrong — the same
    # misdirection this block's own prose correction exists to remove. What the message now does: it
    # states the CEILING VALUE inside `ceiling ( … )` and nothing else, then lists the three ceiling
    # variables as CANDIDATES for "raise the ceiling for that keying". No caller names its variable —
    # `_claim_acquire_at` receives only `ref/ttl/dflt/max` — so the list is a literal here. What the
    # tests pin, split by what each KEYING can express: `branch-claim.test.sh` case 10 pins the
    # branch keying's value, its knob-following and its candidate list; the value being `$max` and
    # NOT `$dflt` is only observable on a keying where the two DIFFER, and that arm lives in
    # `claim-orphan.test.sh` O14 (`claim_acquire`, whose `dflt` is `CLAIM_TTL` and whose `max` is
    # `CLAIM_TTL_MAX`) — the branch keying passes one variable for both, so it cannot tell them
    # apart. ⛔ AND THE CALL SITES ARE NAMED,
    # NOT NUMBERED (review round 7, P2): this comment used to cite line numbers
    # (836/1079/1088/1098), which were exact at fe99acb92 and became WRONG the moment round 7
    # inserted two lines above them — stale references shipped by the very commit that exists to
    # remove stale references. The four callers are `claim_branch_acquire`, `claim_acquire`,
    # `claim_issue_acquire` and `claim_pr_acquire`, in that order; names cannot rot.
    printf '[claims] lease ttl %ss exceeds this keying ceiling (%ss) — clamped. Raise the ceiling for that keying (CLAIM_TTL_MAX / CLAIM_ISSUE_TTL / CLAIM_BRANCH_TTL) if its timeout was raised (agent-infra#2094).\n' \
      "$ttl" "$max" >&2
    ttl="$max"
  fi

  CLAIM_REF="$ref"
  CLAIM_OWNER="$(claim_owner)"
  # ⛔ CLEAR IT AT ENTRY, NOT ONLY AT SOURCE TIME (cycle-2 adversarial review). `CLAIM_COMMIT` is a
  # GLOBAL that this file resets only when it is SOURCED — once per controller cycle — so an acquire
  # that fails BEFORE any push (rc=2: the ref is unreadable, the existing claim cannot be fetched)
  # left the PREVIOUS issue's commit in it. orch-loop.sh's "rc=2 with a claim commit → write the
  # handover record and try a fenced release" then wrote a record for an issue this attempt never
  # claimed and consumed it. The registry itself is safe (`--force-with-lease` refuses a ref that
  # moved) but the state written and the log line were about the wrong issue. Cleared here, the value
  # always means "the commit THIS attempt may have pushed".
  CLAIM_COMMIT=""
  now="$(date +%s)"
  # ⛔ THE WRITER MUST NOT MINT ON A CLOCK IT CANNOT READ (review, agent-infra#3203). `until=$(( now + ttl ))`
  # with an empty `now` is `0 + ttl`, i.e. a lease stamped in 1970 — `_lease_is_live` reads it EXPIRED the
  # same second it was pushed, so any peer may STEAL the claim this box just acquired. Refusing is the
  # only fail-closed answer: an agent cannot defeat this by breaking `date`, and no term is invented.
  case "${now:-}" in
    # ⛔ `0`, A LEADING-ZERO CLOCK, AND AN OVERSIZED ONE ARE UNREADABLE (review, agent-infra#3203).
    # A `date` shim that prints `0` mints `until=ttl` — epoch 1970 — which every peer then reclaims as
    # EXPIRED; a leading zero aborts the arithmetic as OCTAL; and a value at or above 2**64 WRAPS, so
    # `until` wraps with it and the same 1970 term is minted from a 20-digit "clock". `?????????????*`
    # is 13+ characters: an epoch second is 10 digits today and the sibling `_claim_commit_time` caps at
    # 12, so nothing this box or a peer can legitimately report is rejected.
    ''|0|0?*|*[!0123456789]*|?????????????*)
      # ⛔ rc 1, NOT rc 2 (review, agent-infra#3203). rc 2 is the acquire's INFRA code: every PR-claim
      # consumer treats it as "the registry is unavailable, proceed on the local lock alone"
      # (`merge-one.sh`, `fix-one.sh`), so returning 2 here would let a broken `date` drop the cross-box
      # exclusion entirely — the guard would REFUSE in name and GRANT in effect. rc 1 is the answer all
      # those consumers refuse on, which is the polarity this class already has.
      CLAIM_RESULT="could not mint a claim: the LOCAL CLOCK is unreadable, so no lease deadline can be computed (refusing rather than minting an already-expired term; held-by-unreadable-clock)"
      echo "$CLAIM_RESULT"; return 1 ;;
  esac
  until=$(( now + ttl ))
  # ⛔ NOT `commit="$(_claim_commit …)"`: that runs in a SUBSHELL, so the reason this function sets
  # would be discarded and the caller would be back to an empty explanation. Called directly, the
  # globals survive; `>/dev/null` drops the echoed sha we already have in CLAIM_COMMIT_OUT.
  CLAIM_COMMIT_OUT=""; CLAIM_COMMIT_ERR=""
  _claim_commit "$CLAIM_OWNER" "$until" >/dev/null
  commit="${CLAIM_COMMIT_OUT:-}"
  if [ -z "$commit" ]; then
    CLAIM_RESULT="could not build claim commit — ${CLAIM_COMMIT_ERR:-unknown failure building a claim commit object}"
    echo "$CLAIM_RESULT"; return 2
  fi

  # --- attempt 1: atomic create. Fails if the ref exists — and every claim commit is a ROOT
  #     commit, so a different claim can never fast-forward it, whatever the timing.
  if _git push -q origin "$commit:$CLAIM_REF" 2>/dev/null; then
    # rec 2: read the ref BACK rather than trusting the exit code alone.
    back="$(_git ls-remote origin "$CLAIM_REF" 2>/dev/null | awk '{print $1}')"
    if [ "$back" != "$commit" ]; then
      # P2 (2026-10-14 adversarial review): the push may have CREATED the ref and only the read-back
      # failed. Surface the commit we pushed so the caller can attempt a FENCED release — otherwise
      # the claim is orphaned for the whole lease (up to `CLAIM_LEASE` = REVIEW_TIMEOUT + _gw + 300,
      # 50 min at the defaults) and every box
      # refuses that head until it expires. merge-one.sh consumes CLAIM_COMMIT on rc=2.
      CLAIM_COMMIT="$commit"
      CLAIM_RESULT="push reported success but read-back differs ($back != $commit)"
      echo "$CLAIM_RESULT"; return 2
    fi
    CLAIM_COMMIT="$commit"
    CLAIM_RESULT="acquired $CLAIM_REF owner=$CLAIM_OWNER lease_until=$until"
    echo "$CLAIM_RESULT"; return 0
  fi

  # --- the ref exists. Read the lease (data, not liveness) and decide.
  cur="$(_git ls-remote origin "$CLAIM_REF" 2>/dev/null | awk '{print $1}')"
  if [ -z "$cur" ]; then CLAIM_RESULT="push failed and ref is unreadable (network?)"; echo "$CLAIM_RESULT"; return 2; fi
  tmp="$CLAIM_TMP_NS/read-$RANDOM$$"
  if ! _git fetch -q origin "+$CLAIM_REF:$tmp" 2>/dev/null; then
    _git update-ref -d "$tmp" 2>/dev/null
    CLAIM_RESULT="cannot fetch the existing claim to read its lease"; echo "$CLAIM_RESULT"; return 2
  fi
  local lease held_owner held_until
  lease="$(_lease_of "$tmp")"; _git update-ref -d "$tmp" 2>/dev/null
  held_owner="${lease%%$'\t'*}"; held_until="${lease##*$'\t'}"

  # ⛔ AN OVERSIZED BUT NUMERIC LEASE IS ALSO UNPARSEABLE (P3, third review round, 2026-10-14). A
  # value at or above 2**63 makes `[ "$now" -le "$held_until" ]` ERROR (rc=2, test FALSE), so control
  # fell through to the RECLAIM CAS and STOLE a claim this code means to treat as NOT EXPIRED. The "no
  # parseable lease" branch below covers an absent value; it did not cover one a foreign or older
  # writer minted at full width. Bound the digits BEFORE the comparison, exactly as the writer side
  # now does. Not reachable from the shipped writers (they clamp), so this is defence in depth.
  #
  # ⛔ THE BOUND IS 18 DIGITS, NOT 9. The review finding asked for "longer than 9 digits", but
  # `lease_until` is an EPOCH SECOND, which is 10 digits TODAY (`date +%s` = 1792001642) — a 9-digit
  # bound would call every legitimate lease unparseable and withhold it forever (the do-not-steal
  # direction), so no claim would ever expire or be reclaimed (a fleet-wide fail-closed, and test-claims.sh's expiry steps
  # go RED). The overflow threshold is 2**63-1 = 9223372036854775807 (19 digits): 18 digits max is
  # 999999999999999999 < 2**63, so the comparison cannot error. Rejecting 19+ digits is therefore the
  # precise magnitude guard — and it is the CONSERVATIVE direction (a foreign full-width lease reads
  # as NOT EXPIRED, never as stolen).
  # ── HELD, EXPIRED or ORPHANED — the one decision, in the order that cannot steal work ──────
  # ⛔ AN UNPARSEABLE LEASE IS NEVER RE-EXAMINED FOR ORPHANHOOD (the recorded decision, kept): the
  # orphan rules below are a REASON TO STOP TRUSTING A TERM, not evidence about the holder, so the
  # orphan arm must never become a new way to reclaim a claim whose term arrived from a foreign or
  # older writer.
  # ⚠️ AMENDED BY agent-infra#3203 — THE REFUSAL STANDS, THE LABEL DOES NOT. This branch still
  # returns rc=1 before the orphan arm (nothing is stolen), but it is no longer reported as `live`:
  # an unreadable term is an ABSTENTION, and `held-by-unreadable-lease` is its token, exactly as
  # `held-by-orphan` distinguishes its own class (the reason carries a machine-readable token so a
  # controller can tell "a peer is working" from "nobody can ever work this"). Calling it live made
  # an eternal, unreapable block indistinguishable from a healthy busy fleet, and the block is now
  # bounded on the reap side: `claim_prune` deletes a ref in this class once the claim's own COMMIT
  # is older than `CLAIM_UNREADABLE_LEASE_MAX_AGE`, so the abstention can name its own deadline.
  local reclaim_why="" orph
  if _lease_unparseable "$held_until"; then
    CLAIM_RESULT="held by $held_owner (no parseable lease — ABSTAINING, rc=1: neither a live claim nor a free one; held-by-unreadable-lease; claim_prune reaps it once the claim commit is older than ${CLAIM_UNREADABLE_LEASE_MAX_AGE}s; agent-infra#3203)"
    echo "$CLAIM_RESULT"; return 1
  fi
  # ⛔ NO CLOCK BRANCH HERE ANY MORE (review, agent-infra#3203): the MINT guard above already refuses
  # (**rc 1, NOT rc 2** — rc 2 is read by merge-one.sh/fix-one.sh as "registry unavailable, proceed",
  # which would drop the cross-box exclusion) on an unreadable clock BEFORE this point is reachable, so
  # a `case "${now:-}"` here would be dead code that looks like a defence. The judgement below can only
  # run with a clock this box could read.
  if _lease_is_live "$held_until" "$now"; then
    orph="$(claim_orphan_reason "$held_owner" "$CLAIM_REF")" || orph=""
    if [ -z "$orph" ]; then
      # ⛔ THE REASON CARRIES A MACHINE-READABLE TOKEN. `held-by-live` vs `held-by-orphan` is the
      # only thing that lets a controller tell "a peer is working on this" from "nobody can ever work
      # on this again" — the two used to print the SAME line, and the incident's `backlog empty`
      # looked like a healthy idle fleet for hours.
      CLAIM_RESULT="held by $held_owner until $held_until ($(( held_until - now ))s left; held-by-live)"
      echo "$CLAIM_RESULT"; return 1
    fi
    # ORPHANED: the term has hours left and it does not matter — the holder cannot be a live lane.
    reclaim_why="ORPHANED claim from $held_owner ($orph; held-by-orphan; lease had $(( held_until - now ))s left)"
  else
    reclaim_why="expired claim from $held_owner (was until $held_until)"
  fi

  # --- reclaim with a CAS on the observed value, never a blind force. If another box
  #     reclaimed it meanwhile our expected value no longer matches and we lose cleanly.
  if perr="$(_git push -q --force-with-lease="$CLAIM_REF:$cur" origin "$commit:$CLAIM_REF" 2>&1)"; then
    back="$(_git ls-remote origin "$CLAIM_REF" 2>/dev/null | awk '{print $1}')"
    if [ "$back" = "$commit" ]; then
      CLAIM_COMMIT="$commit"
      CLAIM_RESULT="reclaimed $reclaim_why"
      echo "$CLAIM_RESULT"; return 0
    fi
    CLAIM_COMMIT="$commit"   # may have landed; the caller can attempt a fenced release
    CLAIM_RESULT="reclaim read-back differs ($back != $commit)"
    echo "$CLAIM_RESULT"; return 2
  fi
  # ⛔ The push failed. DISTINGUISH "I lost the race" from "the remote was unreachable" (P2,
  # 2026-10-14 adversarial review). The CREATE path already does this; the reclaim path used to call
  # EVERY non-zero exit a lost race (stderr discarded), so `merge-one.sh` logged "another box owns
  # head" and exited 0 on a transient network failure — FAIL-CLOSED, the opposite of the stated
  # policy. Re-read the ref: a DIFFERENT sha = genuine lost race (rc=1); unchanged at `$cur`, or
  # unreadable, = infrastructure failure (rc=2 → fail-open).
  after="$(_git ls-remote origin "$CLAIM_REF" 2>/dev/null | awk '{print $1}')"
  perr="$(printf '%s' "${perr:-}" | tr '\n' ' ' | cut -c1-200)"
  if [ "$after" = "$commit" ]; then
    # the push landed despite its non-zero exit; the read-back is the authority.
    CLAIM_COMMIT="$commit"
    CLAIM_RESULT="reclaimed $reclaim_why (push exited non-zero but the ref is ours)"
    echo "$CLAIM_RESULT"; return 0
  fi
  if [ -z "$after" ] || [ "$after" = "$cur" ]; then
    # ⛔ Set CLAIM_COMMIT BEFORE this return (P2, second review round, 2026-10-14). The push exited
    # non-zero, but it may have LANDED and only the immediate re-read failed (`after` is unreadable
    # in exactly that window). Returning 2 without the commit left merge-one.sh's
    # `if [ -n "${CLAIM_COMMIT:-}" ]` false, so it never attempted the fenced release — and the box
    # PROCEEDED fail-open while genuinely owning the ref, so every other box refused that head until
    # the lease expired (up to `CLAIM_LEASE` = REVIEW_TIMEOUT + _gw + 300, 50 min at the defaults).
    # Safe to set unconditionally: the
    # fenced release is a no-op when the ref is still `$cur` (the lease does not match), so it can
    # never delete another box's claim.
    CLAIM_COMMIT="$commit"
    CLAIM_RESULT="reclaim push failed and $CLAIM_REF is ${after:-unreadable} (still $cur) — infrastructure failure, not a lost race: ${perr:-no stderr}"
    echo "$CLAIM_RESULT"; return 2
  fi
  CLAIM_RESULT="lost the reclaim race for $CLAIM_REF (another box took it: $cur -> $after)"
  echo "$CLAIM_RESULT"; return 1
}

# claim_release <repo> <pr> <head-sha> <own-commit>
# Deletes ONLY if the ref still points at <own-commit> (fencing, rec 6). A box holding a STALE
# commit — its claim was superseded or reclaimed — cannot release the winner's claim.
# ⛔ The fence is on the ref's VALUE, not on ownership (P3.1, 2026-10-14 adversarial review): it
# refuses a STALE commit; it does not refuse a caller who passes the ref's CURRENT sha. Shipped call
# sites pass only the sha they pushed.
claim_release() {
  # `"${3:-}"` as well as `"${4:-}"`: an arity slip (repo + PR only) must not abort the caller
  # under `set -u` either. Both missing arguments land on the documented refusal inside the core,
  # which pushes NOTHING — so a mis-called release stays a refusal, never a blind delete.
  _claim_release_at "$(claim_ref "${2:-}" "${3:-}")" "${4:-}"
}

# claim_issue_release <repo> <issue> [<own-commit>] — fenced release of an ISSUE claim (#1850).
# Same fence and same reason strings as claim_release, so a stale holder cannot delete a winner's
# issue claim either.
claim_issue_release() {
  _claim_release_at "$(claim_issue_ref "${2:-}")" "${3:-}"
}

# claim_pr_release <repo> <pr> [<own-commit>] — fenced release of a LANDING claim (#1952).
# Same fence and same reason strings as claim_release, so a stale holder cannot delete a winner's
# per-PR claim either.
claim_pr_release() {
  _claim_release_at "$(claim_pr_ref "${2:-}")" "${3:-}"
}

# _claim_release_at <ref> [<own-commit>]
# ⛔ `own` IS READ WITH `:-`, AND THAT IS A FIX, NOT STYLE (agent-infra#1850). The PR-keyed wrapper
# used to read `$4` BARE while `set -u` is on, so a three-argument call — a caller that has no
# commit to fence on, which is exactly what a refused or half-completed acquire leaves it with —
# aborted the caller with `line 260: $4: unbound variable` (measured on the release path). A
# release that ERRORS leaves the claim held until the lease expires, and for an ISSUE claim that is
# up to three hours of a free issue no box will dispatch: the failure this check exists to prevent.
_claim_release_at() {
  local ref="$1" own="${2:-}"
  if [ -z "${own:-}" ]; then CLAIM_RESULT="release refused — no claim commit to fence on"; echo "$CLAIM_RESULT"; return 1; fi
  if _git push -q --force-with-lease="$ref:$own" origin ":$ref" 2>/dev/null; then
    CLAIM_RESULT="released $ref"; echo "$CLAIM_RESULT"; return 0
  fi
  CLAIM_RESULT="release refused — $ref no longer ours (fenced; another box owns it)"
  echo "$CLAIM_RESULT"; return 1
}

# claim_status <repo> <pr> <head-sha> -> "owner\tlease_until" on stdout, rc=1 if unheld
# The <repo> argument exists only for API symmetry with claim_acquire/claim_release; every git
# call uses the cwd. It must NOT be forwarded to claim_ref(), which takes (pr, sha) — forwarding
# all three built `refs/claims/.-<sha>` and made every status lookup miss.
claim_status() {
  _claim_status_at "$(claim_ref "$2" "$3")"
}

# claim_issue_status <repo> <issue> -> "owner\tlease_until", rc=1 if unheld (#1850)
claim_issue_status() {
  _claim_status_at "$(claim_issue_ref "$2")"
}

# claim_pr_status <repo> <pr> -> "owner\tlease_until", rc=1 if unheld (#1952)
claim_pr_status() {
  _claim_status_at "$(claim_pr_ref "$2")"
}

_claim_status_at() {
  local ref="$1" tmp cur
  cur="$(_git ls-remote origin "$ref" 2>/dev/null | awk '{print $1}')"
  [ -n "$cur" ] || return 1
  tmp="$CLAIM_TMP_NS/status-$RANDOM$$"
  _git fetch -q origin "+$ref:$tmp" 2>/dev/null || { _git update-ref -d "$tmp" 2>/dev/null; return 1; }
  _lease_of "$tmp"; echo
  _git update-ref -d "$tmp" 2>/dev/null
  return 0
}

# claim_issue_preflight <issue> — THE PRE-FLIGHT'S REGISTRY READ (agent-infra#1850)
#   0 CLEAN      — no issue claim is visible: the issue may be certified dispatchable
#   1 COLLISION  — a LIVE claim is held (or one whose lease is unreadable: claim_acquire never
#                  steals that class — it ABSTAINS at rc 1, and `claim_prune` reaps it past its
#                  commit-age bound): another box owns this issue
#   2 INCOMPLETE — the registry could NOT be read. NEVER a CLEAN: a registry outage must not become
#                  a duplicate dispatch (#1850). This is the fail-CLOSED direction, and it is
#                  deliberately the opposite of claim_acquire's infra rc=2 (which fails OPEN so a
#                  merge is not refused by a network blip): there, refusing costs one PR's merge;
#                  here, certifying a free issue costs duplicated work on two boxes.
# Sets CLAIM_RESULT; echoes it, so a caller in a subshell still sees the reason.
# claim_pr_preflight <repo> <pr> — the SAME pre-flight read, keyed by the coarse PR claim
# (agent-infra#1952's `pr-<N>` key, the one merge-one.sh takes for LANDING). The PR SICKNESS QUEUE
# (pr-sickness.sh) uses it as its holder read: the question it asks is "does a lane already own this
# PR?", and the answer must carry a registry's polarity rather than a local pid's — rc=2
# (INCOMPLETE) is NOT FREE, because an abstention is not permission.
#  0 CLEAN / 1 COLLISION / 2 INCOMPLETE. Sets CLAIM_RESULT exactly as the issue-keyed sibling does.
claim_pr_preflight() {
  _claim_preflight_at "$(claim_pr_ref "$2")" "PR #$2"
}

# claim_head_preflight <repo> <pr> <sha> — the PER-HEAD question, and the one a FIXER/reviewer asks.
# ⛔ THE COARSE `pr-<N>` KEY ANSWERS A DIFFERENT QUESTION: claims.sh documents it as taken ONLY by the
# landing path (merge-one.sh). A peer fixing head H holds `refs/claims/<PR>-<sha12>` (claim_acquire),
# which claim_pr_preflight never looks at — so a two-box fleet read CLEAN for a head another box was
# already fixing, and only fix-one.sh's own CAS stopped the duplicate AFTER the attempt was booked.
claim_head_preflight() {
  _claim_preflight_at "$(claim_ref "$2" "$3")" "PR #$2 at $(printf '%s' "${3:-}" | cut -c1-12)"
}

claim_issue_preflight() {
  _claim_preflight_at "$(claim_issue_ref "$1")" "#$1"
}

# _claim_preflight_at <ref> <label> — ONE polarity for every keying (per-head, issue, landing).
# `label` is what the line says ("#123" / "PR #123"). Two copies of this decision is exactly how a
# reader and a writer of the same datum drift.
# `_why` carries agent-infra#1990's repo diagnosis into the UNREADABLE branch: an empty reason is
# what turned a broken CLAIM_REPO into a weeks-long mystery, so the local belongs here with the
# body that reads it (main's refactor of this function split the header off, and the two must list
# the same locals — a var read but not declared is a global, i.e. a leak between pre-flights).
_claim_preflight_at() {
  local ref="$1" label="$2" out rc cur tmp lease owner until now _why
  # ⛔ THE EXIT STATUS IS THE DISTINCTION THAT MATTERS HERE. `git ls-remote <ref>` exits 0 with
  # EMPTY output when the ref simply does not exist, and NON-ZERO only when the remote itself could
  # not be consulted (measured: rc=128 for an unreachable remote). Collapsing the two — which is
  # what a bare `[ -n "$(…)" ]` does — reads an outage as "nobody holds it", which is the exact
  # false CLEAN this gate exists to remove.
  out="$(_git ls-remote origin "$ref" 2>/dev/null)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    # Name the repo when the repo itself is the reason: a controller pointed at a non-repo refuses
    # EVERY issue identically, and "the registry is unreadable" alone reads as a network blip.
    _why="$(_claim_repo_problem)"
    CLAIM_RESULT="the claim registry is UNREADABLE ($ref: git ls-remote exited $rc)${_why:+ — $_why} — INCOMPLETE, never CLEAN"
    echo "$CLAIM_RESULT"; return 2
  fi
  cur="$(printf '%s\n' "$out" | awk '{print $1}')"
  if [ -z "$cur" ]; then
    CLAIM_RESULT="no claim on $label"
    echo "$CLAIM_RESULT"; return 0
  fi
  tmp="$CLAIM_TMP_NS/pre-$RANDOM$$"
  if ! _git fetch -q origin "+$ref:$tmp" 2>/dev/null; then
    _git update-ref -d "$tmp" 2>/dev/null
    CLAIM_RESULT="a claim ref exists for $label but its lease could not be read — INCOMPLETE, never CLEAN"
    echo "$CLAIM_RESULT"; return 2
  fi
  lease="$(_lease_of "$tmp")"; _git update-ref -d "$tmp" 2>/dev/null
  owner="${lease%%$'\t'*}"; until="${lease##*$'\t'}"
  # ⛔ THE SAME NEVER-EXPIRED POLARITY AS claim_acquire(), taken from the ONE function that
  # owns it (§_lease_is_live): an absent lease, the `0` sentinel, a negative, or an oversized value
  # all mean "a claim EXISTS whose lease this reader cannot parse" — never "free". Reading any of
  # them as free would steal a live claim, and the snapshot reader (orch-loop.sh's claim_live)
  # already agrees on this datum; a fifth polarity would be a new disagreement about the same fact.
  # ⛔ THE CLOCK IS A SECOND INPUT TO THE SAME DECISION, SO IT IS GUARDED FIRST (2026-10-16 review).
  # `[ "" -le "$until" ]` prints "integer expression expected" and evaluates FALSE, and this block
  # used to fall THROUGH that comparison to `return 0` — a FALSE CLEAN from a registry that could not
  # answer, which is the one direction this gate must never fail in (it duplicates the work).
  now="$(date +%s)"
  # ⛔ AN UNREADABLE LEASE IS AN ABSTENTION THAT IS NEVER CLEAN (agent-infra#3203). rc=1 is kept —
  # a pre-flight must not queue what the acquire will refuse, and the acquire still refuses — but
  # the reason no longer claims the lease is LIVE: it names the fault, the token `held-by-unreadable-
  # lease`, and the bounded schedule that will free it (`claim_prune`, claim-commit age >
  # `CLAIM_UNREADABLE_LEASE_MAX_AGE`). An abstention must carry a NAMED reason
  # (docs/ops/fleet-liveness.md §4); "treated as live" was a claim this reader could not support.
  if _lease_unparseable "$until"; then
    CLAIM_RESULT="a claim on $label is held by ${owner:-?} (lease unreadable — ABSTAINING, never CLEAN: neither a live claim nor a free one; held-by-unreadable-lease; claim_prune reaps it once the claim commit is older than ${CLAIM_UNREADABLE_LEASE_MAX_AGE}s; agent-infra#3203)"
    echo "$CLAIM_RESULT"; return 1
  fi
  # ⛔ THE SAME SHAPE **AND MAGNITUDE** RULE AS EVERY OTHER CLOCK GUARD (review, agent-infra#3203).
  # Shape alone let a leading-zero clock through to `$(( ))`, where bash read it as OCTAL, aborted, and
  # left `CLAIM_RESULT` EMPTY — an abstention with no word, no reason and no token, which is a verdict
  # nobody can act on — and let a 20-digit clock WRAP, so `$(( until - now ))` printed a negative
  # "s left". Fail-closed either way, but the NAME is the whole product here.
  case "${now:-}" in
    ''|0|0?*|*[!0123456789]*|?????????????*)
      CLAIM_RESULT="the local clock is unreadable (date +%s -> '${now:-}') — INCOMPLETE, never CLEAN"
      echo "$CLAIM_RESULT"; return 2 ;;
  esac
  if _lease_is_live "$until" "$now"; then
    # ⛔ AN ORPHANED HOLDER IS NOT A COLLISION (agent-infra#2094). A host that no longer exists (or a
    # pid on this box that is gone) cannot be a live lane, so reporting its claim as `COLLISION` left
    # every peer treating the issue as busy FOREVER — the incident's `backlog empty queue=READ(192)`
    # over 192 readable candidates. The pre-flight is a READ, so it says what the ACQUIRE will do:
    # reclaimable -> CLEAN. That is not a bypass — the acquire still has to win the CAS.
    local orph
    orph="$(claim_orphan_reason "$owner" "$ref")" || orph=""
    if [ -n "$orph" ]; then
      CLAIM_RESULT="the only claim on $label is ORPHANED (${owner:-?}: $orph; held-by-orphan) — free to reclaim"
      echo "$CLAIM_RESULT"; return 0
    fi
    CLAIM_RESULT="a claim on $label is held by ${owner:-?} until $until ($(( until - now ))s left; held-by-live)"
    echo "$CLAIM_RESULT"; return 1
  fi
  CLAIM_RESULT="the only claim on $label EXPIRED at $until (was ${owner:-?}) — free to reclaim"
  echo "$CLAIM_RESULT"; return 0
}

# ── THE ISSUE CLAIM'S RELEASE RECORD (agent-infra#1850) ───────────────────────────────────────
# The claim is taken by `orch-loop.sh` and released by whichever process ends up owning the END of
# the work: `chain-merge.sh` (its EXIT trap — the normal path) or `dispatch-merge.sh` (the path that
# decides NOT to spawn a chain, so no trap will ever run). Neither of those is the process that
# ACQUIRED the claim, so the commit it pushed — the only thing `--force-with-lease` can be keyed on
# — has to be handed over. It is handed over in `$O/state/issueclaim-<N>`.
# ⛔ THE FORMAT LIVES HERE, BESIDE THE FENCE IT FEEDS, so there is ONE writer convention and ONE
# reader implementation. Two copies of this is how a reader and a writer of the same datum drift,
# and the drift is silent: a record nobody can parse releases nothing and the claim runs to its
# lease instead (3h of a free issue).

# claim_issue_record <state-dir> <issue> <own-commit> -> 0 written, 1 nothing to record (#1850)
# ⛔ REFUSES AN EMPTY COMMIT rather than writing an empty file: an empty record is indistinguishable
# from a corrupt one, and it can never fence anything.
claim_issue_record() {
  local dir="${1:-$HOME/orchestrator}" issue="${2:-}" own="${3:-}"
  [ -n "$own" ] || return 1
  [ -n "$issue" ] || return 1
  mkdir -p "$dir/state" 2>/dev/null || true
  printf '%s\n' "$own" > "$dir/state/issueclaim-$issue" 2>/dev/null || return 1
  return 0
}

# claim_issue_record_commit <state-dir> <issue> -> the recorded commit ("" and rc=1 when none)
# ⛔ THE READER EXISTS SO A CALLER CAN CAPTURE THE RECORD WHEN IT BECOMES THE HOLDER, rather than
# reading it inside its release trap — see claim_issue_release_record's generation guard.
claim_issue_record_commit() {
  local f="${1:-$HOME/orchestrator}/state/issueclaim-${2:-}"
  [ -f "$f" ] || return 1
  cat "$f" 2>/dev/null || return 1
}

# claim_issue_release_record <state-dir> <repo> <issue> [<expected-commit>] -> claim_issue_release's
# status (1 = refused or nothing to do). Removes the record in every case EXCEPT a generation
# mismatch (below): an empty or unreadable record can never fence a release, so leaving it behind
# makes every later attempt re-read a dead file.
# ⛔ THE OPTIONAL EXPECTED COMMIT IS THE GENERATION GUARD (2026-10-16 review). The record is keyed on
# the ISSUE, and the SAME box can become the holder of the same issue a second time while its first
# chain is still running (the lease lapsed; the chain is still waiting on a PR). The acquire path
# then OVERWRITES $O/state/issueclaim-<N> with the new commit, and a trap that read the file when it
# fired would fence on that NEW commit — which IS the ref tip — so the FIRST chain would delete the
# claim of the chain that legitimately holds it, and a peer would read the issue as free: the
# duplicate this registry exists to prevent, and a fail-OPEN. A caller that captured the record when
# it BECAME the holder passes it here; a mismatch means "overwritten by a newer generation", so this
# chain must not release AND must not delete the file (it belongs to that newer chain).
claim_issue_release_record() {
  local dir="${1:-$HOME/orchestrator}" repo="${2:-}" issue="${3:-}" expect="${4:-}"
  local f="$dir/state/issueclaim-$issue" own
  if [ ! -f "$f" ]; then
    CLAIM_RESULT="no recorded claim commit for #${issue:-?} — nothing to fence the release on"
    echo "$CLAIM_RESULT"; return 1
  fi
  own="$(cat "$f" 2>/dev/null || true)"
  if [ -n "$expect" ] && [ "$own" != "$expect" ]; then
    CLAIM_RESULT="the record for #$issue was overwritten by a NEWER generation (${own:-empty} != $expect) — NOT releasing; that claim is not this chain's"
    echo "$CLAIM_RESULT"; return 1
  fi
  rm -f "$f" 2>/dev/null
  if [ -z "$own" ]; then
    CLAIM_RESULT="the recorded claim commit for #$issue is EMPTY — it cannot fence a release"
    echo "$CLAIM_RESULT"; return 1
  fi
  claim_issue_release "$repo" "$issue" "$own"
}

# ── THE SNAPSHOT VERDICT (agent-infra#2466) ──────────────────────────────────────────────────
# ONE reader for "does the durable registry say this key is free?", shared by every caller that
# SELECTS work (`orch-loop.sh`'s `pr_owned` / `claim_live` / the sweep's printed decision). It adds
# NO second verdict path: the lease polarity is `_lease_is_live` and the orphan rule is
# `claim_orphan_reason` — the same two functions `claim_acquire`, `claim_issue_preflight` and
# `claim_prune` use.
#
# ⛔ WHY IT EXISTS. Selection used to read the snapshot with a bare `awk` and fall back to "not
# owned" whenever the FILE was missing — so every way a registry READ can fail reported as "nobody
# holds it": no registry provisioned at all, a snapshot written from a FAILED fetch (the fetch's
# `|| true` leaves the previous cache in place, so the file is a stale read presented as current),
# and a snapshot older than the cycle reading it. Those are the exact states in which two cells
# disagree, and the disagreement duplicates work.
#
# ⛔ AN UNREADABLE REGISTRY IS NEVER FREEDOM (rc=2). Failing closed costs a beat of delay; failing
# open duplicates live work, and this is the only signal the boxes share.
#
# Published verdict words (an abstention carries a NAMED reason, per docs/ops/fleet-liveness.md §4):
#   claim-absent      rc 0  the registry was READ, is FRESH, and has no entry for this key -> free
#   claim-expired     rc 0  an entry whose lease window has passed -> free
#   claim-orphaned    rc 0  a live window whose HOLDER cannot be a live lane (claim_orphan_reason)
#   claim-held          rc 1  a live, non-orphaned window -> SKIP (owner in CLAIM_SNAPSHOT_OWNER)
#   claim-lease-unreadable rc 1  a claim EXISTS whose LEASE cannot be parsed (agent-infra#3203): an
#                             ABSTENTION, not a live claim and not a free one. rc stays 1 on purpose
#                             — see the block at the verdict itself — so this word is the abstention.
#   claim-unreadable  rc 2  the registry could not answer. NOT free: no spawn, no merge, no arm.
# Globals: CLAIM_VERDICT, CLAIM_VERDICT_WHY, CLAIM_SNAPSHOT_OWNER, CLAIM_SNAPSHOT_UNTIL.
# ⛔ GLOBALS, NOT ONLY STDOUT: the caller idiom is `claim_snapshot_verdict …; rc=$?` — a `$( )`
# capture would run it in a SUBSHELL and discard the globals (the trap `claim_acquire` documents).
CLAIM_VERDICT=""; CLAIM_VERDICT_WHY=""; CLAIM_SNAPSHOT_OWNER=""; CLAIM_SNAPSHOT_UNTIL=""

# claim_file_mtime <file> -> epoch seconds, or "" when no `stat` can answer (BSD is tried second).
claim_file_mtime() {
  stat -c '%Y' "${1:-}" 2>/dev/null || stat -f '%m' "${1:-}" 2>/dev/null || printf ''
}

claim_snapshot_verdict() { # <snapshot-file> <ref> -> verdict word on stdout
  local f="${1:-}" ref="${2:-}" hdr read_at fetch now age entry owner until_or_0 why=""
  CLAIM_VERDICT=""; CLAIM_VERDICT_WHY=""; CLAIM_SNAPSHOT_OWNER=""; CLAIM_SNAPSHOT_UNTIL=""
  # No key -> nothing was asked. Callers pass a ref built from a PR + head sha; an empty one cannot
  # address any claim, so this is the ABSENT case rather than an abstention.
  if [ -z "$ref" ]; then
    CLAIM_VERDICT="claim-absent"; CLAIM_VERDICT_WHY="no claim key was derived (no head sha)"
    echo "$CLAIM_VERDICT"; return 0
  fi
  if [ ! -f "$f" ]; then
    why="no claim snapshot at $f — the registry has never been read on this box, so its silence is not evidence of freedom"
  elif ! hdr="$(head -n 1 "$f" 2>/dev/null)"; then
    # ⛔ A SNAPSHOT THAT EXISTS BUT CANNOT BE READ IS UNREADABLE, NOT ABSENT (review, P1). `[ -f ]` is
    # a STAT, so it passes on a file this process cannot OPEN (mode 000, an ownership change from a
    # `sudo` deploy or a restore) — and the old `head … || true` turned that EACCES/EIO into an EMPTY
    # `hdr`, which the `case` below read as "a writer older than this reader" and answered from mtime
    # (stat needs no read permission) → `claim-absent` → rc 0 → THE SWEEP ACTS. Measured: a mode-000
    # snapshot whose ref WAS held read `claim-absent … no entry … read 0s ago`, a reason that is not
    # merely empty but confidently wrong. Fail closed on the read itself: the direction that costs a
    # beat of delay, never a duplicate dispatch.
    why="the claim snapshot at $f could not be READ (this process cannot open it — permissions or an I/O error) — an unreadable file is not an empty registry"
  else
    case "$hdr" in
      '#claim-snapshot'*)
        read_at="$(printf '%s' "$hdr" | cut -f2)"
        fetch="$(printf '%s' "$hdr" | cut -f3)"
        # ⛔ A HEADER THAT CANNOT STATE ITS OWN READ INSTANT IS UNREADABLE, NOT OLD (review, P2). The
        # mtime fallback exists for a writer that predates the header — a first line that is NOT a
        # header at all. A line that IS the header with a missing/non-numeric instant is a writer
        # this reader cannot parse, and falling back to mtime would believe it on the strength of the
        # copy that carried it. Say so instead.
        case "${read_at:-}" in
          ''|*[!0123456789]*) why="the claim snapshot at $f carries a '#claim-snapshot' header with no usable read instant ('${read_at:-}') — the writer is not one this reader can parse" ;;
        esac ;;
      *) read_at=""; fetch="" ;;   # a writer older than this reader: mtime is the only age available
    esac
    [ -n "$why" ] || [ -n "$read_at" ] || read_at="$(claim_file_mtime "$f")"
    now="$(date +%s 2>/dev/null || true)"
    # ⛔ THE LAST SHAPE-ONLY CLOCK GUARD, AND THE ONE THAT HURTS MOST (review round 12,
    # agent-infra#3203). The magnitude arm was added to `read_at` below but not to `now`, and `now`
    # feeds `age=$(( now - read_at ))` 10 lines down. A leading-zero clock makes bash abort the
    # ARITHMETIC as OCTAL — and because `claim_selection_verdict` calls this function DIRECTLY (not in
    # `$( )`, so no subshell absorbs it), `orch-loop.sh` DIES MID-SWEEP: no verdict, no error line the
    # sweep can read, the candidate never examined. A 20-digit clock WRAPS instead, so
    # `CLAIM_SNAPSHOT_MAX_AGE` is silently skipped. Both are now named, which is what this arm is for.
    case "${now:-}" in ''|0|0?*|*[!0123456789]*|?????????????*) [ -n "$why" ] || why="the local clock is unreadable (date +%s -> '${now:-}')" ;; esac
    # ⛔ SHAPE AND MAGNITUDE, exactly as `claim_prune` and the mint guard require (review,
    # agent-infra#3203): with shape only, a leading-zero `read_at` aborts `$(( now - read_at ))` as
    # OCTAL, `age` stays empty, NEITHER the fresh nor the stale test fires, and the verdict falls
    # through to a bare `claim-unreadable` with no reason — and a 20-digit one wraps into a negative
    # age. The bound is what this arm exists to apply; an unusable clock must not skip it silently.
    case "${read_at:-}" in
      ''|0|0?*|*[!0123456789]*|?????????????*) [ -n "$why" ] || why="the snapshot's read instant could not be read (header and mtime both unusable)" ;;
    esac
    if [ -z "$why" ]; then
      age=$(( now - read_at ))
      # ⛔ A FUTURE STAMP IS DROPPED, NEVER TRUSTED (review, P2; the same one-sided-age rule AGENTS.md
      # records for `skill-reads.json`, now applied here because this is the fleet's cross-box
      # duplicate signal). The old arm CLAMPED a stamp ahead of the local clock to fresh (`age=0`),
      # i.e. the further ahead the stamp, the longer it was believed — with NO age bound at all.
      # A snapshot whose read instant is in the future was written by a clock this box cannot
      # reconcile with its own, so its age is unknown: unreadable, not eternally fresh.
      if [ "$age" -lt 0 ]; then
        why="the snapshot's read instant is ${read_at}, ${age#-}s AHEAD of this box's clock — its age cannot be established, and a future stamp is dropped rather than trusted"
      elif [ "$fetch" = "failed" ]; then
        # ⛔ THE FETCH ITSELF DID NOT ANSWER: the entries below are the LAST GOOD read, so a claim
        # published (or released) since then is invisible. That is a stale read, not a snapshot.
        why="the snapshot was written from a FAILED fetch (its entries are the last good read, ${age}s old)"
      elif [ "$age" -gt "$CLAIM_SNAPSHOT_MAX_AGE" ]; then
        why="the snapshot was read ${age}s ago (> the ${CLAIM_SNAPSHOT_MAX_AGE}s bound)"
      fi
    fi
  fi
  if [ -n "$why" ]; then
    CLAIM_VERDICT="claim-unreadable"; CLAIM_VERDICT_WHY="$why"
    echo "$CLAIM_VERDICT"; return 2
  fi
  # ⛔ THE ENTRY READ'S OWN STATUS IS THE ANSWER TOO (review, P1). `awk` exits 2 on an unreadable file
  # and the old `|| true` threw that away, so a failed read degraded to the ABSENT verdict — the one
  # verdict that licenses a spawn. Keep it.
  if ! entry="$(awk -F'\t' -v r="$ref" '$1==r{print; exit}' "$f" 2>/dev/null)"; then
    CLAIM_VERDICT="claim-unreadable"
    CLAIM_VERDICT_WHY="the claim snapshot at $f could not be READ for $ref (the entry lookup failed) — a failed read is not an absent entry"
    echo "$CLAIM_VERDICT"; return 2
  fi
  if [ -z "$entry" ]; then
    CLAIM_VERDICT="claim-absent"; CLAIM_VERDICT_WHY="no entry for $ref in a snapshot read ${age}s ago"
    echo "$CLAIM_VERDICT"; return 0
  fi
  owner="$(printf '%s' "$entry" | cut -f2)"
  until_or_0="$(printf '%s' "$entry" | cut -f3)"
  CLAIM_SNAPSHOT_OWNER="${owner:-?}"; CLAIM_SNAPSHOT_UNTIL="${until_or_0:-0}"
  # ⛔ AN UNPARSEABLE LEASE IS NEVER RE-EXAMINED FOR ORPHANHOOD (agent-infra#2094, pinned by
  # claim-orphan.test.sh O16). The orphan rules are a reason to STOP TRUSTING A TERM; they are not
  # evidence about the HOLDER. A lease this reader cannot parse must keep its existing
  # do-not-steal polarity (rc 1, nothing reclaimed), or the orphan arm becomes a new way to reclaim a
  # claim whose term simply arrived from a foreign or older writer. This ordering came from
  # `claim_acquire`, and it is reproduced here rather than re-derived: unparseable/absent → an
  # ABSTENTION answered BEFORE any orphan consult — never free, and (agent-infra#3203) never
  # `claim-held` either, which is why the word below is `claim-lease-unreadable`.
  # ⛔ THE VERDICT WORD IS AN ABSTENTION, NOT `claim-held` (agent-infra#3203). `claim-held` means
  # "a live, non-orphaned window" to every reader of the published list above, and an unparseable
  # term is not that window — it is UNKNOWN. Publishing it as held is the "read as a live claim"
  # defect this fix exists to remove.
  # ⛔ rc STAYS 1, AND THAT IS DELIBERATE — NOT AN OVERSIGHT. rc 2 (`claim-unreadable`) means "the
  # REGISTRY could not answer", and two consumers act on that meaning: `claim_foreign_live` counts
  # only rc 1 as owned, and `claim_selection_verdict` hands rc 2 to the sweep as UNREADABLE. Moving
  # this class to rc 2 would make a live peer's head read NOT-OWNED, so the controller would spawn a
  # worker that the acquire then refuses — the "re-spawn a refused fixer EVERY cycle" regression
  # this very function was created to end. Both rcs block; rc 1 blocks WITHOUT the churn, and the
  # abstention is carried by the WORD (`claim-lease-unreadable`) plus a why that names the fault, the
  # remedy and the deadline. The forward remedy is not this read: `claim_prune` deletes the ref
  # (`CLAIM_UNREADABLE_LEASE_MAX_AGE`), after which this key answers `claim-absent`.
  if _lease_unparseable "$until_or_0"; then
    CLAIM_VERDICT="claim-lease-unreadable"
    CLAIM_VERDICT_WHY="held by ${owner:-?} — the lease it records ('${until_or_0}') is one this reader cannot parse, so its window is UNKNOWN: an ABSTENTION, never a live claim and never a free one; claim_prune reaps it once the claim commit is older than ${CLAIM_UNREADABLE_LEASE_MAX_AGE}s (agent-infra#3203)"
    echo "$CLAIM_VERDICT"; return 1
  fi
  # THE ONE LEASE POLARITY — never a fifth derivation of it.
  if _lease_is_live "$until_or_0" "$now"; then
    local orph
    # The call may be undefined when this runs outside claims.sh; 127 is non-zero, so the `||`
    # leaves `orph` empty and control falls through to HELD — the fail-closed direction.
    orph="$(claim_orphan_reason "$owner" "$ref" 2>/dev/null)" || orph=""
    if [ -n "$orph" ]; then
      CLAIM_VERDICT="claim-orphaned"; CLAIM_VERDICT_WHY="its holder ${owner:-?} cannot be a live lane ($orph)"
      echo "$CLAIM_VERDICT"; return 0
    fi
    CLAIM_VERDICT="claim-held"; CLAIM_VERDICT_WHY="held by ${owner:-?} until ${until_or_0:-0}"
    echo "$CLAIM_VERDICT"; return 1
  fi
  CLAIM_VERDICT="claim-expired"; CLAIM_VERDICT_WHY="the window of ${owner:-?} closed at ${until_or_0:-0}"
  echo "$CLAIM_VERDICT"; return 0
}

# claim_snapshot [<outfile>]
# Refresh EVERY claim ref locally in ONE round trip, and write one line per claim:
#     <ref>\t<owner>\t<lease_until>
# after a HEADER line that records WHEN this snapshot was read and WHETHER the fetch answered:
#     #claim-snapshot\t<read_at>\t<ok|failed>\t<refs>
# ⛔ THE HEADER IS THE FIX FOR agent-infra#2466, NOT DECORATION. Without it a snapshot written from a
# FAILED fetch is byte-identical in shape to a good one (the fetch's `|| true` leaves the previous
# fetch's CACHE in place, so the file is a stale read presented as current), and a snapshot read
# hours ago is indistinguishable from one read a second ago. Every reader used to treat both as
# "the registry says nothing is free-but-blocked" -> i.e. as evidence of freedom, on the ONE signal
# two boxes share. With the header, `claim_snapshot_verdict` can answer `claim-unreadable` instead of
# guessing. Consumers that key on field 1 (`awk -F'\t' '$1==ref'`) ignore the header by construction.
# The sweep then answers "is anyone working on this PR?" from a local file. Without this the
# controller would pay two network round trips per PR per cycle (24 PRs x 2 = 48 calls).
# ⛔ `CLAIM_SNAPSHOT_FETCH` / `CLAIM_SNAPSHOT_REFS` are set for the CALLER (the controller prints
# them on its cycle line): globals because `$(claim_snapshot …)` would run it in a subshell.
# `CLAIM_SNAPSHOT_WRITE` is a THIRD, separate answer: whether the snapshot could be PUBLISHED. A failed
# FETCH and a failed PUBLISH have different consequences (the first publishes a header that says so;
# the second publishes nothing, leaving the PREVIOUS read in place with its OWN header — believed only
# while that header says `ok` AND it is inside CLAIM_SNAPSHOT_MAX_AGE, `claim-unreadable` otherwise: a
# prior `failed` header, or no previous snapshot at all), so a caller that collapses them logs the
# wrong cause AND the wrong consequence (review, P2).
CLAIM_SNAPSHOT_FETCH=""; CLAIM_SNAPSHOT_REFS=""; CLAIM_SNAPSHOT_WRITE=""
claim_snapshot() {
  # `$1` is OPTIONAL and `set -u` is on, so the temp name must NOT be built from it directly:
  # `local out="${1:-…}" tmp="$1.$$"` dereferences the unset `$1` and aborts the whole fetch with
  # "unbound variable" (exit 127) instead of falling back to the default (P2, 2026-10-14 export
  # review). Derive the temp name from the RESOLVED output path.
  local out="${1:-$HOME/orchestrator/state/claims-snapshot}"
  local tmp="$out.$$" body="$out.body.$$" fetch now n write
  : > "$body"
  # --prune so a claim DELETED on another box (released, or pruned) does not linger here.
  # ⛔ It prunes by DESTINATION pattern, so worker-side temp refs must live in CLAIM_TMP_NS, never
  # under CLAIM_CACHE_NS — a snapshot must not delete a concurrent lease read (P2).
  if _git fetch -q --prune origin "+$CLAIM_NS/*:$CLAIM_CACHE_NS/*" 2>/dev/null; then
    fetch=ok
  else
    # ⛔ A FAILED FETCH MUST NOT REPLACE A GOOD SNAPSHOT WITH AN EMPTY ONE, AND MUST SAY SO
    # (agent-infra#2466; the 2026-10-18 catch). The old shape was `fetch … || true` followed by an
    # unconditional `mv`, so ANY fetch failure — a 30 s network blip, or an unreadable cwd — wrote an
    # EMPTY file over the last good one and every key then read "free" (measured: 3 claims on origin,
    # 0 snapshot lines, nothing logged). Two independent mechanisms now hold, and BOTH are needed:
    #   • the BODY is not truncated: a failed fetch leaves the cache alone, so what is published is
    #     the LAST GOOD read rather than an empty file (main's #2466 arm, kept); and
    #   • the HEADER says `failed`, so `claim_snapshot_verdict` refuses the snapshot at ANY age
    #     instead of trusting a read it knows did not answer (this PR's arm). Keeping the last good
    #     body with an `ok` header would be the same fail-open one step later: a claim acquired since
    #     that read is simply not in it, and its absence reads as freedom.
    # The reason goes to STDERR, which the controller redirects into $LOG: it runs in a detached tmux
    # pane, so an unredirected stderr reaches no file at all — a refresh that failed for ever would
    # be silent while the sweep decided from a frozen snapshot. Same idiom as `claim_prune`.
    fetch=failed
    local why; why="$(_claim_repo_problem)"
    printf 'claim_snapshot: registry refresh FAILED — %s (publishing a FAILED header over the last good read: %s)\n' \
      "${why:-git fetch exited non-zero}" "$out" >&2
  fi
  _git for-each-ref --format='%(refname)' "$CLAIM_CACHE_NS" 2>/dev/null | while read -r ref; do
    [ -n "$ref" ] || continue
    local lease owner until
    lease="$(_lease_of "$ref")"
    owner="${lease%%$'\t'*}"; until="${lease##*$'\t'}"
    # Emit the CLAIM namespace, not the cache namespace the fetch landed in, so a lookup with
    # claim_ref() matches. (Measured: emitting the cache ref made every lookup miss silently.)
    printf '%s\t%s\t%s\n' "${CLAIM_NS}/${ref#"$CLAIM_CACHE_NS"/}" "${owner:-?}" "${until:-0}"
  done > "$body"
  n="$(wc -l < "$body" 2>/dev/null | tr -d ' ')"
  case "${n:-}" in ''|*[!0123456789]*) n=0 ;; esac
  now="$(date +%s 2>/dev/null || true)"
  case "${now:-}" in ''|0|0?*|*[!0123456789]*|?????????????*) now=0 ;; esac
  # A read instant of 0 is NOT a fresh read: the reader treats it as unreadable (0 is in the past by
  # every clock), which is the fail-closed direction on a box whose `date` cannot answer.
  # ⛔ A FAILED WRITE MUST NOT PUBLISH AN EMPTY SNAPSHOT (review, P2). The brace below used to
  # discard its own exit status and the `mv` was `|| true`, so a failed write (ENOSPC/EIO under
  # `$O/state`) still created `$tmp` and replaced the last GOOD read with a 0-byte file — and a
  # header-less snapshot falls back to a fresh mtime, so every key then read `claim-absent` (FREE)
  # while the cycle log printed `read=ok refs=0`. That is the "an empty one reads UNOWNED" state
  # this header exists to refuse, reached from the write side. Fail closed instead: publish nothing,
  # keep the previous (age-guarded) snapshot, and report the failure as a WRITE failure
  # (`CLAIM_SNAPSHOT_WRITE=failed`) — NOT as a fetch failure, because the fetch may well have
  # answered, and the caller logs the two differently.
  if { printf '#claim-snapshot\t%s\t%s\t%s\n' "$now" "$fetch" "$n"; cat "$body"; } > "$tmp" 2>/dev/null \
     && mv -f "$tmp" "$out" 2>/dev/null; then
    write=ok
    rm -f "$body" 2>/dev/null || true
  else
    # ⛔ A FAILED PUBLISH IS NOT A FAILED FETCH (review, P2). `fetch` keeps the FETCH's own answer;
    # `write` records this failure. On a failed FETCH the published header itself says `failed`, so
    # the reader refuses it at any age. On a failed PUBLISH nothing is published, so the PREVIOUS
    # snapshot survives with its OWN header — and that header decides, not this function: the reader
    # believes it only while the header says `ok` AND it is inside CLAIM_SNAPSHOT_MAX_AGE, and answers
    # `claim-unreadable` for a prior `failed` header or for no prior snapshot at all. (An earlier
    # draft of this very comment said the snapshot was believed "until it ages out", which the reader
    # falsifies in two of those three cases — do not reintroduce the unqualified form.) Collapsing the
    # two made the cycle log assert a stand-down that did not happen, and pointed an auditor at the
    # network when the cause was the disk.
    write=failed; n=0
    rm -f "$tmp" "$body" 2>/dev/null || true
  fi
  CLAIM_SNAPSHOT_FETCH="$fetch"; CLAIM_SNAPSHOT_REFS="$n"; CLAIM_SNAPSHOT_WRITE="$write"
  return 0
}

# claim_wip_line <issue> — the WIP clause a REAP prints and logs for an issue key (#3484).
# ⛔ ONE READER: `brief-gate.sh --wip-refs` owns the ref matcher, so a reap cannot report a different
# population than the dispatch gate refuses on. This function only FORMATS. An unreadable `refs/wip`
# is reported as UNMEASURED and never as "none": #3382 invariant 1 (`unknown != zero`).
claim_wip_line() {
  local issue="${1:-}" bg out rc line r s
  case "$issue" in ''|*[!0-9]*) printf 'n/a (this key carries no issue number)'; return 0 ;; esac
  bg="$(dirname "${BASH_SOURCE[0]:-$0}")/brief-gate.sh"
  if [ ! -f "$bg" ]; then
    printf 'UNMEASURED (brief-gate.sh is not beside this registry, so refs/wip cannot be read for #%s)' "$issue"
    return 0
  fi
  # ⛔ ABSOLUTISE BEFORE THE NEUTRAL-cwd `cd` (fresh-context review of #3484, P2). This registry
  # supports `CLAIM_REPO="."` (a caller standing at a work-tree root); resolved from `/tmp` that path
  # names a DIFFERENT tree, so the clause read UNMEASURED on a box whose origin answered fine.
  local repo_abs=""
  [ -n "${CLAIM_REPO:-}" ] && repo_abs="$(cd "$CLAIM_REPO" 2>/dev/null && pwd)"
  out="$(cd "${TMPDIR:-/tmp}" 2>/dev/null && bash "$bg" --wip-refs "$issue" "$repo_abs" 2>/dev/null)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'UNMEASURED (refs/wip could not be read for #%s — unknown is not zero)' "$issue"
    return 0
  fi
  line=""
  while IFS=$'\t' read -r r s; do
    [ -n "${r:-}" ] || continue
    line="${line}${line:+, }$r @ ${s}"
  done <<< "$out"
  if [ -z "$line" ]; then
    printf 'none — no refs/wip ref matched #%s (measured: brief-gate.sh --wip-refs %s)' "$issue" "$issue"
    return 0
  fi
  printf '%s — read it before starting; do not re-derive it' "$line"
  return 0
}

# claim_prune — delete EXPIRED, UNPARSEABLE-LEASE and ORPHANED-HOST claim refs (git refs are
# unbounded), and reap LEAKED temp refs. Three arms, in this order: (1) EXPIRY — `_lease_is_live`
# answers expired, so a future lease is still evidence of a holder; (2) UNPARSEABLE-LEASE — no reader
# can parse the term, so it is reaped on a BOUNDED SCHEDULE measured from the claim's own commit time
# (agent-infra#3203 — before this arm the class was eternal), which also takes the class OUT of arm 3;
# (3) ORPHANED-HOST — only an orphaned host makes a future lease reaptable (agent-infra#2094).
# (4) Every reap above also EMITS THE HANDOVER LINE for its key (#3484): the `refs/wip/*` snapshot (and
# any issue-named dirty worktree) behind the claim, or `none`/`UNMEASURED` for that issue. `claim_prune`
# deletes with no per-claim evidence and no record, so a reap used to read as "nothing happened here"
# while the rescued work sat on origin; stdout is what `orch-loop.sh` redirects into $LOG
# (`claim_prune >> "$LOG" 2>&1`), so a silent reclaim is no longer possible.
claim_prune() {
  local now ref lease until owner ct age; now="$(date +%s)"
  # ⛔ THE CLOCK IS VALIDATED ONCE, BEFORE ANY ARITHMETIC (review, agent-infra#3203). TWO distinct
  # pre-fix failures, both silent: (a) an EMPTY `date` made `$(( now - ct ))` read `now` as EPOCH 0, so
  # every claim in the unparseable-lease class looked decades AHEAD of this box's clock and the pass
  # reported a clock-SKEW it had no evidence for; (b) a value that is
  # not arithmetic syntax at all (e.g. `12:34:56`) makes `$(( now - ct ))` a SYNTAX ERROR, which kills
  # this subshell — nothing after that ref is reaped and nothing says the pass stopped. (A plain
  # non-numeric word like `abc` does NOT error: bash resolves a variable's value recursively, so it is
  # the epoch-0 / syntax-error shapes that bite.) `_claim_acquire_at` needed the same guard for a worse
  # reason and now has it (no lease is minted on an unreadable clock). With an unreadable clock the
  # UNPARSEABLE-LEASE arm below reaps nothing (fail-closed) and says WHICH datum was missing — the
  # orphaned-host arm is a separate judgement that never consults the clock, so it is unaffected.
  # ⛔ MAGNITUDE, NOT JUST SHAPE (review, agent-infra#3203): a 20-digit clock WRAPS through `$(( ))` and
  # reaps a 5-second-old claim as "7766279629658291713s old, past the bound". `?????????????*` = 13+ chars.
  case "${now:-}" in ''|0|0?*|*[!0123456789]*|?????????????*) now="" ;; esac
  _git ls-remote origin "$CLAIM_NS/*" 2>/dev/null | awk '{print $2}' | while read -r ref; do
    [ -n "$ref" ] || continue
    local cur tmp
    cur="$(_git ls-remote origin "$ref" 2>/dev/null | awk '{print $1}')"
    [ -n "$cur" ] || continue
    tmp="$CLAIM_TMP_NS/prune-$RANDOM$$"
    _git fetch -q origin "+$ref:$tmp" 2>/dev/null || continue
    # ⛔ THE COMMIT TIME IS READ HERE, WHILE THE OBJECT IS REACHABLE (agent-infra#3203). After the
    # `update-ref -d` below the claim commit is DANGLING: `cat-file` still resolves it until the next
    # `gc`/`prune`, so reading it afterwards is intermittent by construction — and a bound whose input
    # is readable only sometimes is not a bounded schedule.
    ct="$(_claim_commit_time "$tmp")" || ct=""
    lease="$(_lease_of "$tmp")"; _git update-ref -d "$tmp" 2>/dev/null
    until="${lease##*$'\t'}"; owner="${lease%%$'\t'*}"
    # The polarity is `_lease_is_live`'s, not a fourth derivation of it: reap exactly what that
    # function calls expired. "Not expired — do not reap" covers the absent, the `0` sentinel, the
    # non-digit and the 19+-digit lease (which ERRORS `[` at 2**63 — an errored test is FALSE, so an
    # inline copy here would reap a claim every reader refuses to steal; since agent-infra#3203 the
    # third arm below is what ends that class's block, on its own bounded schedule).
    if ! _lease_is_live "$until" "$now"; then
      _git push -q --force-with-lease="$ref:$cur" origin ":$ref" 2>/dev/null && {
        echo "pruned expired $ref"
        echo "  WIP AT RELEASE: $(claim_wip_line "${ref##*/issue-}")"
      }
      continue
    fi
    # ── AND BY THE BOUNDED EXPIRY FOR A LEASE NO READER CAN PARSE (agent-infra#3203) ──────────
    # ⛔ WHY A THIRD ARM. Refusing to STEAL on an unparseable term is a recorded decision and it
    # stays (the readers still refuse, above); this arm runs on the REAP path only, where the old
    # answer was "never" — the expiry arm above reads the term as NOT EXPIRED and the orphan arm below is
    # skipped for this class, so a human `git push origin :<ref>` was the only cure. That is the
    # #8175 shape, and a batch claim multiplies it by N.
    # ⛔ EVERY PASS SAYS SOMETHING. A claim this arm keeps is NAMED (`kept unreadable-lease`) with its
    # age, and one it deletes is NAMED (`pruned unreadable-lease`) with the bound it passed: an
    # abstention reaches the operator, and a deletion carries its own evidence instead of being a
    # silent grant. The age is the claim COMMIT's (read above), never a ref mtime and never the lease.
    # ⛔ AN UNMEASURABLE AGE IS NOT EVIDENCE OF EXPIRY: no readable committer stamp, or a stamp AHEAD
    # of this box's clock, keeps the claim and says why. That is the fail-closed direction, and it is
    # the only case where this class still needs a human — stated, not hidden.
    if _lease_unparseable "$until"; then
      if [ -z "${now:-}" ]; then
        echo "kept unreadable-lease $ref (owner $owner — lease_until='${until}' cannot be parsed AND the LOCAL CLOCK is unreadable, so this claim's age cannot be established: nothing in the unparseable-lease class is reaped on a clock this box cannot read, and the orphaned-host arm is NOT consulted for this class either (claim-orphan.test.sh O20 pins that it survives a pass that names its host DEAD) — agent-infra#3203)"
        continue
      fi
      if [ -z "$ct" ]; then
        echo "kept unreadable-lease $ref (owner $owner — lease_until='${until}' cannot be parsed and the claim commit's time cannot be read, so its AGE IS UNMEASURABLE: an unmeasurable age is not evidence of expiry — agent-infra#3203)"
        continue
      fi
      age=$(( now - ct ))
      if [ "$age" -lt 0 ]; then
        echo "kept unreadable-lease $ref (owner $owner — lease_until='${until}' cannot be parsed and the claim commit is dated ${age#-}s AHEAD of this box's clock, so its age cannot be established — agent-infra#3203)"
        continue
      fi
      if [ "$age" -le "$CLAIM_UNREADABLE_LEASE_MAX_AGE" ]; then
        echo "kept unreadable-lease $ref (owner $owner — lease_until='${until}' cannot be parsed; the claim commit is ${age}s old, INSIDE the ${CLAIM_UNREADABLE_LEASE_MAX_AGE}s bound — agent-infra#3203)"
        continue
      fi
      if _git push -q --force-with-lease="$ref:$cur" origin ":$ref" 2>/dev/null; then
        echo "pruned unreadable-lease $ref (owner $owner — lease_until='${until}' cannot be parsed and the claim commit is ${age}s old, PAST the ${CLAIM_UNREADABLE_LEASE_MAX_AGE}s bound — agent-infra#3203)"
        echo "  WIP AT RELEASE: $(claim_wip_line "${ref##*/issue-}")"
      else
        # ⛔ A FAILED DELETE MUST SAY SO. Silence here reads as "the pass had nothing to do", which is
        # how an eternal block comes back without anyone noticing — the arm's own rule is that every
        # pass says something.
        echo "kept unreadable-lease $ref (owner $owner — lease_until='${until}' cannot be parsed and the claim commit is ${age}s old, PAST the ${CLAIM_UNREADABLE_LEASE_MAX_AGE}s bound, but the reap push FAILED: the ref is still there — agent-infra#3203)"
      fi
      continue
    fi
    # ── AND BY ORPHANED HOST (agent-infra#2094) ───────────────────────────────────────────────
    # Expiry alone is the incident: a lease stamped under a host that no longer exists keeps a
    # FUTURE `lease_until`, so this loop skipped it for its whole term and nothing else could ever
    # free it. An orphaned holder is not a live lane, so the term is irrelevant to the decision.
    # ⛔ THE UNPARSEABLE CLASS NEVER REACHES THIS ARM — it is handled by the bounded arm above,
    # which decides from the claim's OWN age and skips this loop with a `continue`. That is the
    # recorded decision kept intact: an unparseable lease is not evidence about the HOLDER either,
    # so the orphan rules are never consulted for it (agent-infra#2094, agent-infra#3203).
    local why
    if why="$(claim_orphan_reason "$owner" "$ref")"; then
      if _git push -q --force-with-lease="$ref:$cur" origin ":$ref" 2>/dev/null; then
        echo "pruned orphaned-host $ref (owner $owner — $why)"
        echo "  WIP AT RELEASE: $(claim_wip_line "${ref##*/issue-}")"
      fi
    fi
  done

  # ── leaked CLAIM_TMP_NS refs (P3.4, second review round, 2026-10-14) ─────────
  # Every lease READ/STATUS creates a local ref here and deletes it with `update-ref -d`. A SIGKILL,
  # a Ctrl-C or a reboot between the fetch and the delete leaks that ref FOREVER: it is local-only,
  # so no `ls-remote` sweep can ever see it, and this namespace was unbounded until now.
  # ⛔ The age is the REF FILE's mtime — when THIS box wrote the ref — NOT the claim commit's date.
  # The commit may be minutes old while the read ref was created a second ago, so a commit-date bound
  # would delete the ref underneath a LIVE concurrent read; `_lease_of` would then return "?\t0"
  # (unparseable = treated as NOT EXPIRED, so not stealable) and the merge would be falsely refused — the exact race this
  # namespace exists to avoid. A read takes seconds, so a 2-hour bound cannot touch a live one.
  _git for-each-ref --format='%(refname)' "$CLAIM_TMP_NS" 2>/dev/null | while read -r ref; do
    [ -n "$ref" ] || continue
    local tpath gdir
    # ⛔ Resolve the ref FILE absolutely. Plain `--git-path` can return a path relative to the REPO
    # ROOT (measured: `git -C /tmp/r rev-parse --git-path refs/x` -> `.git/refs/x` even from another
    # cwd), so prefixing the GIT DIR resolves `.git/.git/refs/...` and the file is never found —
    # the reaper then no-ops silently. `--path-format=absolute` (git >= 2.31) is authoritative; the
    # fallback (`<gitdir>/<ref>`) is correct for the non-worktree repos these scripts run in, and an
    # empty result skips the ref rather than guessing.
    tpath="$(_git rev-parse --path-format=absolute --git-path "$ref" 2>/dev/null)"
    if [ -z "$tpath" ]; then
      gdir="$(_git rev-parse --absolute-git-dir 2>/dev/null)"
      [ -n "$gdir" ] || continue
      tpath="$gdir/$ref"
    fi
    [ -e "$tpath" ] || continue
    # NOTE the `[ -n "$(find ...)" ]` form: `find <file> -mmin +N` exits 0 whether or not it
    # matches, so a bare `find ... && echo` would reap EVERY temp ref, live ones included.
    if [ -n "$(find "$tpath" -mmin +120 2>/dev/null)" ]; then
      _git update-ref -d "$ref" 2>/dev/null && echo "pruned leaked temp ref $ref"
    fi
  done
}

# ── THE HOLD-PROOF AT THE ACTION SITE (agent-infra#2867) ─────────────────────────────
# The claim registry fences DISPATCH (the pre-flight read and the acquire CAS). It does NOT
# fence ACTION: a dead or duplicated harness that still holds a stale claim commit — or that
# never took one — reaches the acting tool (`gh pr merge`) with nothing refusing it. This
# function is the fence AT the action site. The acting tool calls it with the PR, the head it
# is about to act on, and the claim commit it believes it holds, and it REFUSES unless ALL of
# these hold:
#
#   (i)   a claim ref `refs/claims/<pr>-<sha12>` EXISTS on the remote;
#   (ii)  the ref's tip IS the actor's own commit — the FENCING TOKEN. A peer that reclaimed
#         the claim moved the ref, so a stale actor's token no longer matches and its action
#         is refused (Kleppmann's fencing token, enforced by the registry's own CAS);
#   (iii) the claim's owner names THIS box (the running host or one of its former names) — a
#         claim minted by another box is not this actor's;
#   (iv)  the holder is not ORPHANED — for a local PR claim, the pid that took it must still
#         be alive (claim_orphan_reason's local rule). A dead holder's claim is expired by
#         code, so its actor is refused.
#
# ⛔ NEVER GUESSES, NEVER FALLS OPEN. An unreadable registry, an absent ref, a mismatched tip,
# an unparseable owner, or a dead holder all REFUSE (rc != 0). rc 0 is returned ONLY when the
# proof positively holds. rc 1 (refused) and rc 2 (unreadable) are BOTH refusals — the rc
# distinguishes "I read it and you are not the holder" from "I could not read it", and neither
# is ever a pass.
#
# ⛔ LEASE-AS-DATA, NOT LIVENESS, IS UNCHANGED (#1709 rec 3). This proof does NOT re-derive,
# renew, or re-key the lease: it reads the claim's owner (for the actor check) and the holder's
# pid (for the orphan check), exactly as claim_acquire / claim_prune already do. The wall-clock
# lease's EXPIRY is decided by claim_prune ("released by code"), which deletes the ref — so a
# dead harness whose claim was pruned fails check (i). Session liveness (transcript growth) is
# the ORPHAN REPORT's question (scripts/orchestrator-harness/orphaned-harness.sh), answered by
# tools/fleet/liveness.py — the single verdict function — never by a second opinion here.
#
# claim_action_proof <pr> <head-sha> <own-commit>
#   Sets CLAIM_ACTION_RESULT to a machine-readable one-line reason and echoes it (so a caller
#   in a command substitution still sees the reason). Returns 0 (held) / 1 (refused) / 2
#   (unreadable — also a refusal).
claim_action_proof() {
  local pr="${1:-}" head="${2:-}" own="${3:-}"
  local ref cur tmp lease owner until now orph host held_owner
  # ⛔ VALIDATE AT THE DOOR — an unreadable input is a REFUSAL (rc 2), never a pass.
  case "$pr" in ''|*[!0123456789]*)
    CLAIM_ACTION_RESULT="claim-action-proof: REFUSED pr=<unreadable> reason=non-numeric-pr"
    echo "$CLAIM_ACTION_RESULT"; return 2 ;; esac
  case "$head" in ''|*[!0-9a-fA-F]*)
    CLAIM_ACTION_RESULT="claim-action-proof: REFUSED pr=$pr head=<unreadable> reason=non-hex-head"
    echo "$CLAIM_ACTION_RESULT"; return 2 ;; esac
  if [ "${#head}" -ne 40 ]; then
    CLAIM_ACTION_RESULT="claim-action-proof: REFUSED pr=$pr head=${head:0:12} reason=head-not-40-hex"
    echo "$CLAIM_ACTION_RESULT"; return 2
  fi
  case "$own" in ''|*[!0-9a-f]*)
    CLAIM_ACTION_RESULT="claim-action-proof: REFUSED pr=$pr head=${head:0:12} reason=non-hex-token"
    echo "$CLAIM_ACTION_RESULT"; return 2 ;; esac
  if [ "${#own}" -ne 40 ]; then
    CLAIM_ACTION_RESULT="claim-action-proof: REFUSED pr=$pr head=${head:0:12} reason=token-not-40-hex"
    echo "$CLAIM_ACTION_RESULT"; return 2
  fi

  ref="$(claim_ref "$pr" "$head")"
  # (i) the claim must EXIST. An absent ref (released, pruned, or never taken) is a refusal —
  #     an actor that cannot show a claim does not hold this PR/head. ⛔ THE EXIT STATUS IS THE
  #     DISTINCTION: `git ls-remote <ref>` exits 0 with EMPTY output when the ref simply does not
  #     exist, and NON-ZERO only when the remote itself could not be consulted (the same split
  #     `_claim_preflight_at` makes). Collapsing the two reads an outage as "no claim", which is
  #     the one direction this gate must never fail in.
  local lrc=0 lout
  lout="$(_git ls-remote origin "$ref" 2>/dev/null)"; lrc=$?
  if [ "$lrc" -ne 0 ]; then
    CLAIM_ACTION_RESULT="claim-action-proof: REFUSED pr=$pr head=${head:0:12} holder=<unreadable> reason=registry-unreadable"
    echo "$CLAIM_ACTION_RESULT"; return 2
  fi
  cur="$(printf '%s\n' "$lout" | awk '{print $1}')"
  if [ -z "$cur" ]; then
    CLAIM_ACTION_RESULT="claim-action-proof: REFUSED pr=$pr head=${head:0:12} holder=<none> reason=no-claim"
    echo "$CLAIM_ACTION_RESULT"; return 1
  fi
  # (ii) FENCING — the tip must be the actor's own commit. A peer that reclaimed the claim
  #      moved the ref, so a stale token belongs to a DIFFERENT holder's claim.
  if [ "$cur" != "$own" ]; then
    held_owner="?"
    tmp="$CLAIM_TMP_NS/proof-$RANDOM$$"
    if _git fetch -q origin "+$ref:$tmp" 2>/dev/null; then
      lease="$(_lease_of "$tmp")"; held_owner="${lease%%$'\t'*}"
      _git update-ref -d "$tmp" 2>/dev/null
    fi
    CLAIM_ACTION_RESULT="claim-action-proof: REFUSED pr=$pr head=${head:0:12} holder=$held_owner reason=fence-mismatch"
    echo "$CLAIM_ACTION_RESULT"; return 1
  fi
  # Read the lease/owner of the ACTOR'S OWN claim (the tip IS the actor's commit).
  tmp="$CLAIM_TMP_NS/proof-$RANDOM$$"
  if ! _git fetch -q origin "+$ref:$tmp" 2>/dev/null; then
    _git update-ref -d "$tmp" 2>/dev/null
    CLAIM_ACTION_RESULT="claim-action-proof: REFUSED pr=$pr head=${head:0:12} holder=<unreadable> reason=claim-unreadable"
    echo "$CLAIM_ACTION_RESULT"; return 2
  fi
  lease="$(_lease_of "$tmp")"; _git update-ref -d "$tmp" 2>/dev/null
  owner="${lease%%$'\t'*}"; until="${lease##*$'\t'}"
  host="${owner%%:*}"
  # (iii) the claim must name THIS box (the running host or a former name).
  if ! claim_host_is_local "$host"; then
    CLAIM_ACTION_RESULT="claim-action-proof: REFUSED pr=$pr head=${head:0:12} holder=${owner:-?} reason=foreign-holder"
    echo "$CLAIM_ACTION_RESULT"; return 1
  fi
  # (iv) the holder must not be ORPHANED — a dead pid on this box cannot be the acting lane.
  orph="$(claim_orphan_reason "$owner" "$ref")" || orph=""
  if [ -n "$orph" ]; then
    CLAIM_ACTION_RESULT="claim-action-proof: REFUSED pr=$pr head=${head:0:12} holder=${owner:-?} reason=orphaned-holder detail=$(printf '%s' "$orph" | tr ' ' '_')"
    echo "$CLAIM_ACTION_RESULT"; return 1
  fi
  CLAIM_ACTION_RESULT="claim-action-proof: HELD pr=$pr head=${head:0:12} holder=${owner:-?}"
  echo "$CLAIM_ACTION_RESULT"; return 0
}

# claim_host_is_local <host> -> 0 when the host IS this box (running host or a former name),
# 1 otherwise. The same "local" computation claim_orphan_reason uses for its pid rule, factored
# out for the hold-proof's "names this actor" check (agent-infra#2867). A probe that cannot
# answer (empty or the fleet-wide `box` sentinel) ABSTAINS — it is not local.
claim_host_is_local() {
  local h="${1:-}" me real
  [ -n "$h" ] || return 1
  [ "$h" = "box" ] && return 1
  me="$(claim_host)"
  real="$(hostname -s 2>/dev/null)" || real=""
  if [ -n "$me" ] && [ "$h" = "$me" ]; then return 0; fi
  if [ -n "$real" ] && [ "$h" = "$real" ]; then return 0; fi
  case " $(claim_former_hosts) " in *" $h "*) return 0 ;; esac
  return 1
}
