---
title: "GitHub API rate limits — detection & fallback runbook (#143, #1988)"
type: engineering
domain: operations
doc_status: live
subjects.team: organisation-design-team
created: 2026-08-10
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-143, issue-1762, issue-1988, gh-rate-limits, gh-limit
---

# GitHub API rate limits — detection & fallback runbook

Written after the 2026-08-10 issue audit (48 issue closes + heavy querying in one
session exhausted the GraphQL quota mid-flow). #143

## The layer that owns this now (#1988)

Every harness `gh` call goes through **one** helper, `scripts/orchestrator-harness/gh-limit.py`,
reached from two entry points: the Mac REST adapter (`gh-rest/gh`, first on the daemon PATH) and the
cell wrapper (`gh-limit/gh`, first on the cell's controller PATH). It implements GitHub's own
documented policy, so this file does not restate the numbers — it names where to look.

| Behaviour | Where |
|---|---|
| A **bounded CLIENT BUDGET**: at most `GH_LIMIT_MAX_CONCURRENCY` (default 2; 1 is the strictest) `gh` invocations in flight per box (`flock` on `$GH_LIMIT_DIR/gh.slot.<i>`) — including the `/rate_limit` probe. A waiter is QUEUED and bounded; when its budget runs out the call is **REFUSED** (exit 75, `last-busy` recorded), never released into the burst | `acquire_slot` / `count_held_slots` |
| **A secondary-limit refusal gets its OWN curve**: **2 s doubling** with upward jitter, capped at 60 s, **no `/rate_limit` probe** (the primary counters read healthy and one more request is the burst). It is also retried by `GH_LIMIT_NO_WAIT` callers while the cumulative wait stays inside `GH_LIMIT_SECONDARY_NO_WAIT_S` (8 s) | `SECONDARY_PHRASES` / `plan_wait` / `dispatch` |
| A **primary** refusal: `retry-after`, then the bucket's `x-ratelimit-reset` when remaining is 0, then **≥ 60 s doubling** with upward jitter; **4 attempts**, then fail loudly | `plan_wait` / `dispatch` |
| The failing **bucket** (`core` vs `graphql`) **and the KIND** (`primary` vs `secondary`) are named with the reset — never inferred from whichever counter looks healthy | `bucket_for` / `fail_loudly` |
| **One reader per box** for COLLECTION reads: an opt-in (`GH_LIMIT_SNAPSHOT=1`) single-flight TTL snapshot (default 90 s) so lanes, the controller and the refresh pass share ONE fetch of the same question. A failure is replayed as a failure for a few seconds, never cached as data; mutations are never cached | `snapshot_*` / `_dispatch_snapshotted` |
| The box's health as an INSTRUMENT: `gh-limit.py --status` prints `gh=clients=<held>/<max> waiters=<n> last=<kind>(bucket=… <age>s)` without touching the network, and `orch-loop.sh` puts it on the `[cap]` line | `status_token` / `gh_health_token` |
| **≥ 1 s between mutative calls** (POST/PATCH/PUT/DELETE) | `pace_mutation` |
| Conditional REST for polling: ETag stored per URL (host + path + credential digest), `if-none-match` sent, a **304 replayed from cache** and charged nothing. The cached body is base64 (a 304 replay is byte-exact, binary included) and the cache is bounded in ENTRIES and BYTES (`GH_LIMIT_CACHE_MAX_ENTRIES` 500, `GH_LIMIT_CACHE_MAX_BYTES` 64 MiB) | `conditional_fetch` / `cache_put` / `prune_cache` |
| The shim stays FIRST on PATH even though every gh-calling harness script prepends `/opt/homebrew/bin:/usr/local/bin` | the `$O/gh-limit` / `$O/gh-rest` re-assert in the harness scripts that prepend and invoke `gh` |
| The heartbeat's tooling (`objective.py`, `merge-queue.py`, `beta-progress.py`, `queue-dispatch.py`, `ask-owner.py`, `turn-classify.py`, `turn-end.py`, `undelivered-answers.py`, `pr-doctor.py`) reaches the layer instead of a pinned real binary | each resolver prefers `$O/gh-rest/gh` then `$O/gh-limit/gh` (`$O`-derived, never PATH); the six that HAVE a pinned candidate also hand it through as `GH_REST_REAL_GH`/`GH_LIMIT_REAL_GH` (see the residual below for the three that never pinned) |

Two properties worth knowing before you debug it:

* **A call is never quietened.** SUCCESS and non-limit FAILURE both replay the child's stdout and
  stderr byte for byte (a bare `gh api` body has no trailing newline, and it still has none through
  the layer). This matters most for `gh pr checks`, which prints its whole surface on stdout and
  signals the verdict with the exit code: dropping stdout on a failure would read as an EMPTY surface
  (`NOCHECKS`), i.e. a red PR that is never fixed. Retry
  announcements go to `$GH_LIMIT_DIR/events.log`; only a FINAL failure writes to stderr — callers
  such as `gh-rest/gh` merge stderr into stdout and then parse it.
* **A refused call is never reported as empty data.** The failure names the bucket and the reset,
  and it records itself in `$GH_LIMIT_DIR/last-limit`, which `orch-loop.sh` prints on its cycle line
  as `gh=rate_limited(bucket=graphql reset=<epoch> <age>)` for 15 minutes — or as
  `gh=recovered(bucket=… <age>)` once a later call succeeded, so a limit that has been read past is
  not asserted as a current one. The failure text says `rate limit`, because that is the phrase
  `objective.py`'s transport markers turn into `VERDICT=GH-RATE-LIMITED`.
* **A shim's identity is its own sentinel line, not its helper's presence.** Both seed dirs can be
  on one PATH (`install.sh` + the cell supervisor), and a HALF-INSTALLED box (adapter seeded, helper
  missing) is exactly the fail-open state the shims exist for. Identifying a shim by `../gh-limit.py`
  erased the identity precisely then, so the two shims resolved into each other and the depth guard
  turned that into `127` for EVERY gh call on the box (reproduced). Each entry point now carries
  `harness-gh-shim-marker` and every resolver (both shell walks and `is_harness_shim`) reads it; the
  seeders also DELETE a layer the shipped harness no longer carries, rather than leaving it on PATH.
* **A shim that PATH resolves past is inert, and that had already happened.** Every gh-calling
  harness script starts with `export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH`, which put the
  real `gh` ahead of the seeded shim on any box where gh lives in one of those dirs (on the Mac it
  does). The gh-calling scripts in `scripts/orchestrator-harness/` now re-assert the seeded dirs
  AFTER that prepend. The predicate is exact and asserted: **every `*.sh` in that directory that
  prepends those dirs and invokes `gh` carries BOTH stanzas (`$O/gh-limit` and `$O/gh-rest`), plus
  `nonblocking-dispatch.sh` — which calls no `gh` but spawns a whole worker session in-process, so
  its PATH becomes the worker's; `gh-limit.test.sh` names the file and the missing stanza if one
  does not. A script written outside that directory is not covered by the check. Two paths
  cover the common callers without it: the Mac adapter resolves the layer for every call it serves,
  and the heartbeat's telemetry tools (`objective.py`, `merge-queue.py`, `beta-progress.py`,
  `queue-dispatch.py`) prefer `$O/gh-rest/gh` then `$O/gh-limit/gh` over their pinned real binary —
  `gh-rest` first, matching every shell call site, because the adapter is what serves a GraphQL
  refusal over REST (#1959).

### Known residuals (declared, not papered over)

- **Cross-box concurrency is not serialised.** Boxes cannot see each other; the invariant is at most
  `GH_LIMIT_MAX_CONCURRENCY` calls in flight *per box* (default 2), so four boxes can still present
  eight concurrent requests to the one account.
- **Only calls that REACH THE LAYER are budgeted.** The controller, the cells, the lanes' harness
  scripts and the nine heartbeat tools all resolve `$O/gh-rest/gh` or `$O/gh-limit/gh`, so they are
  covered. A bare `gh` an agent session resolves on PATH goes through the review-enforcer's
  admin-merge guard (`scripts/gh-shim/gh`) and then straight to the real binary — it is NOT in this
  budget. The measured 17 concurrent clients were the harness's own, which is why the budget is the
  fix; wiring the guard as a second seat is the next step if a burst is ever measured that the
  harness did not issue.
- **The SECONDARY curve deliberately refines #1910's "wait ≥ 60 s when `retry-after` is absent".**
  That floor is kept for a PRIMARY refusal. For a secondary one the measured recovery is 0.43 s, so
  a 60 s floor converted a 2 s burst into a 7-minute outage and, under `GH_LIMIT_NO_WAIT`, into no
  retry at all. The owner directed the jittered retry-first behaviour on 2026-10-19 with that
  measurement in hand; the bucket and kind are named so the distinction is legible on the line.
- **A degraded state dir**: if `$GH_LIMIT_DIR`/`$XDG_CACHE_HOME` cannot be created, the fallback is
  a per-user temp dir (`${TMPDIR}/gh-limit-<uid>`), which still shares one lock between that user's
  processes and records the degradation in its own `events.log` — but the controller's heartbeat
  reads the *primary* path, so it will not see that box's `last-limit`.
- **The lock/budget timeout** (`GH_LIMIT_LOCK_TIMEOUT`, 600 s; `GH_LIMIT_NO_WAIT_LOCK_S`, 5 s under
  `NO_WAIT`) now **REFUSES** the call (exit 75) instead of proceeding UNSERIALISED. A refusal is a
  named, non-zero answer the caller reports as `UNREADABLE`; "proceed unserialised" was an unbounded
  burst on the busiest box, which is the defect #1910 is about. The cost is a call that could have
  run late now fails loudly instead.
- **Interactive and streaming `gh`**: output is captured, so a human running `gh` in a harness
  session loses TTY rendering, and a long `--watch`-style command would buffer. The harness itself
  has no streaming call.
- **`--jq` replay uses the external `jq` binary** (gh vendors its own engine); when `jq` is absent
  the call is left unintercepted rather than served by us.
- **A layer that sleeps cannot outlive its caller, so a bounded caller gets no PRIMARY backoff.**
  `GH_LIMIT_NO_WAIT=1` makes the layer record a primary limit and return at once; NINE heartbeat tools set
  it (`objective.py`, `merge-queue.py`, `beta-progress.py`, `queue-dispatch.py`, `ask-owner.py`,
  `turn-classify.py`, `turn-end.py`, `undelivered-answers.py`, `pr-doctor.py`), because each one's own
  bound is a per-CALL timeout in the 60-420 s range (or a `run_bounded` step of 20-90 s) that is
  consumed by the layer's first documented wait of 60 s, or shared with every other call the step
  makes — the outcome is a timeout, and the box then reports `UNKNOWN`/`STALL` instead of the
  `RATE-LIMITED` verdict it can prove. (Two of the nine — `queue-dispatch.py`, `pr-doctor.py` — are
  launched detached by `heartbeat-loop.sh` and reaped by their own locks, so their bound is per call,
  not per pass; the decision is the same.) The shell call sites keep the waits: they have no
  subprocess bound of their own.
- **The layer resolves the REAL gh by walking PATH.** A tool that has a pinned candidate hands it
  through as `GH_REST_REAL_GH`/`GH_LIMIT_REAL_GH` — `objective.py`, `merge-queue.py`,
  `beta-progress.py`, `queue-dispatch.py`, `ask-owner.py` and `pr-doctor.py` (via `objective.py`'s
  resolver) do — so #1872's pin survives for those. `turn-classify.py`, `turn-end.py` and
  `undelivered-answers.py` never had a pin: they resolve the layer through `$O`, and the layer then
  walks PATH. On a box whose PATH puts a refusing wrapper first, any of these gets that wrapper
  (rc 126 at runtime, `os.access` notwithstanding). The pin is the mitigation, not a guarantee.
- **`ask-owner.py`'s bound equals the layer's whole budget.** Its per-call timeout is 420 s and the
  layer's full 4-attempt budget is up to 72+144+288 = 504 s (each wait is `base·2ⁿ` plus up to 20 %
  jitter, plus the requests); it resolves the layer from `$O` and sets
  `GH_LIMIT_NO_WAIT` like the other bounded readers, so a limited scan returns the loud refusal
  instead of being killed mid-backoff. Before #1988 it resolved `gh` with `shutil.which` only, which
  under the heartbeat's PATH never reached the layer at all.
- **`record_limit`/`record_recovery` are read-modify-write outside the attempt lock.** A concurrent
  success can rewrite a snapshot taken just before a limit landed, erasing one `last-limit` record;
  the next refused call writes it again. Small window, no effect on any call path.
- **`exec` ends the RETRY LOOP, not an in-flight request.** A caller's TERM kills the helper (so the
  backoff stops), but the child `gh` it already started finishes on its own — the kernel releases the
  lock at the helper's death, so for those seconds a request is in flight unaccounted for.
- **`GH_LIMIT_NO_WAIT` is set at import time, so it also reaches whoever imports these modules.** All
  of them are heartbeat steps, but the contract is "this process and its descendants", not "children
  only" — `pr-loop.py` imports `objective.py`, so it inherits the flag too.
- **The cache key carries `GH_HOST` as well as `--hostname`.** gh reads the host from the environment
  when the flag is absent, and keying on the flag alone let a 304 replay one host's body for another
  (reproduced).
- **A token the child reads from a keyring is not in the cache key.** The key carries the digest of
  whichever of `GH_TOKEN`, `GITHUB_TOKEN`, `GH_ENTERPRISE_TOKEN`, `GITHUB_ENTERPRISE_TOKEN` is set; a
  keyring-resolved token is invisible here, so two credentials that differ only by keyring could
  share an entry (same box, same user).
- **A `retry-after` below 1 s is floored to 1 s.** Taken verbatim, `retry-after: 0` produced four
  back-to-back requests with zero seconds waited — the burst secondary limits react to.
- **The knob floors are the requirements.** `BASE_WAIT` cannot go below 60 s, `MUTATION_GAP` below
  1 s, `LOCK_TIMEOUT` below 1 s: an environment that could set them to 0 would switch off the three
  guarantees the issue asks for while still looking clamped. Upper bounds are clamped too, and
  `nan`/`inf` fall back to the default.
- **The child `gh` has no timeout.** A hung request holds its slot for its whole duration; other
  callers queue up to `GH_LIMIT_LOCK_TIMEOUT` (600 s) — or `GH_LIMIT_NO_WAIT_LOCK_S` (5 s) when
  `GH_LIMIT_NO_WAIT=1` — and are then REFUSED (exit 75, `last-busy`) rather than run over the budget.
  No timeout is imposed on the child: a legitimate `gh` call's duration is not knowable here.
- **The re-entrancy opt-out is silent.** A gh child that itself runs a harness script is not
  serialised (that would deadlock) and nothing is logged, so an ambient `GH_LIMIT_LOCK_HELD=1`
  would disable serialisation on that box without a trace. It is a documented seam, not a knob.
- **The mutation gap is enforced between SENDS, not between reservations.** The stamp is taken
  immediately BEFORE the child is spawned (so the measured send gap can be a spawn-latency hair under
  the gap — the guarantee is "no two mutative requests are started within 1 s", not "their sends are
  1 s apart"), re-checked under the attempt lock immediately before it, so a competing caller cannot
  compress two mutations below `GH_LIMIT_MUTATION_GAP`. The residual is a stamp from the FUTURE (a
  clock that stepped back), which is now IGNORED with an `events.log` line instead of honoured.
- **A limit that later recovered is reported as recovered, not as current.** `last-limit` gains
  `recovered=<epoch>` on the first success of THAT bucket after the limit (any call that actually
  REACHED THE API — `gh --version`, `gh help`, `gh completion` and `gh auth token` are offline and
  are deliberately not evidence; `bucket_for` labels them anyway, so the record can only be cleared
  by something that could have failed on the limit), and not only this process's own retry, and the cycle token prints
  `gh=recovered(bucket=… <age>)`; the 15-minute age bound still applies to both forms.

`$GH_LIMIT_DIR` defaults to `${XDG_CACHE_HOME:-~/.cache}/gh-limit`. Files you will find there:
`gh.slot.<0..N-1>` (the budget), `waiters/` (queue depth), `snapshot/` (the TTL snapshots and their
per-key single-flight locks), `etag/`, `last-mutation`, `last-limit`, `last-busy`, `events.log`.

Operator knobs (all optional): `GH_LIMIT_MAX_ATTEMPTS` (4 attempts in total), `GH_LIMIT_BASE_WAIT` (60 s),
`GH_LIMIT_MAX_WAIT` (300 s — a reset beyond this fails FAST so the caller's own deferral takes
over), `GH_LIMIT_MAX_CONCURRENCY` (2 clients per box; clamped 1-8),
`GH_LIMIT_SECONDARY_BASE_WAIT` (2 s), `GH_LIMIT_SECONDARY_MAX_WAIT` (60 s),
`GH_LIMIT_SECONDARY_NO_WAIT_S` (8 s of burst retries inside a bounded caller),
`GH_LIMIT_SNAPSHOT=1` (opt a COLLECTION read site in) with `GH_LIMIT_SNAPSHOT_TTL` (90 s) and
`GH_LIMIT_SNAPSHOT_FAIL_TTL` (5 s), `GH_LIMIT_LOCK_TIMEOUT` (600 s), `GH_LIMIT_MUTATION_GAP` (1 s),
`GH_LIMIT_CACHE_MAX_ENTRIES` (500), `GH_LIMIT_CACHE_MAX_BYTES` (67108864 — 64 MiB; the cache is
bounded in entries AND bytes, whichever binds first), `GH_LIMIT_CONDITIONAL=0` (disable the ETag
path), `GH_LIMIT_NO_WAIT=1` (never sleep in-process — set by callers that have their own bound) with
`GH_LIMIT_NO_WAIT_LOCK_S` (5 s — the lock budget under `NO_WAIT`). Every knob
is range-clamped, and `nan`/`inf` fall back to the documented default rather than disabling a bound
(an `inf` lock timeout would be a hang, a `nan` wait a traceback).
`GH_LIMIT_NOW_CMD`/`GH_LIMIT_SLEEP_CMD` are the TEST seams for the fake clock — do not set them
in production.

## Two limits, different behavior

| Limit | Scope | Symptom |
|---|---|---|
| **Primary** | 5000 req/h (REST + GraphQL separate pools) | `rate limit exceeded`, `gh api rate_limit` shows `remaining: 0` |
| **Secondary** | abuse detection (burst writes) | `API rate limit already exceeded for user ID ...` even with remaining quota — common after bulk issue closes/creates |

⛔ **THE SECONDARY LIMIT IS A CONCURRENCY LIMIT, AND IT IS WHAT REFUSED THIS FLEET.** Measured
2026-10-19 00:5xZ while the heartbeat printed `gh=RATE-LIMITED(queue)` and `queue=UNREADABLE`:

| Fact | Value |
|---|---|
| Primary budget | core **1599/5000**, graphql **4612/5000** — untouched |
| ONE REST call, alone | `200` in **0.43 s** |
| Concurrent `gh` clients | **17 on the Mac**, 2 + 1 + 0 on the three cells |
| The refusal | `API rate limit already exceeded for user ID 81560491` (13 clients, earlier the same day) |

So reads were failing on **BURSTS**, not on budget — and `gh api rate_limit` is a **FALSE GREEN** for
this question: it reports headroom, which is the opposite of "the fleet is being refused". The
remedy is pacing and retrying, never raising a quota that was not spent (#1910).

## Detect

**Ask the layer what the box is DOING, not what the counter says.** This is the question the cycle
line and `[cap]` now answer:

```bash
python3 "$O/gh-limit.py" --status
# gh=clients=2/2 waiters=3 last=secondary(bucket=graphql 41s)
```

- `clients=<held>/<max>` is the LIVE budget occupancy (probed from the slots the layer itself
  enforces), and `waiters=` is the queue depth. A box at `2/2` with waiters is a box whose reads are
  being paced — which is the healthy state under load, not a fault.
- `last=secondary(...)` names a refusal that happened with the primary counters healthy; `last=`
  `rate_limited(...)` names a spent bucket, with the reset. Both carry their age, so a past refusal
  is never presented as a current one.
- `last=… busy=Ns` means the box's OWN budget refused a call — a local, non-GitHub event.

For the primary counters (still useful, and still not evidence about the secondary limit):

```bash
gh api rate_limit --jq '.resources | {core: .core, graphql: .graphql}'
```

- `graphql.remaining: 0` → GraphQL pool exhausted; REST (`core`) is usually still fine.
- ⛔ **This counter LIES about its own headroom.** Measured 2026-10-17: `gh api rate_limit` reported
  `4999/5000` while EVERY GraphQL call was refused (`API rate limit already exceeded for user ID
  81560491`). The pools are separate, so a healthy number here is not evidence the GraphQL path
  works. That is why the limit layer names the bucket the FAILING CALL used instead of trusting
  this read (#1988, #1762) — and why `--status` reports the CLIENT COUNT instead.
- Secondary limits: transient (seconds to minutes, measured 0.43 s in the clearest case); the layer
  retries them on a jittered 2 s doubling curve rather than the primary 60 s floor.

## Fallback: REST for the operations gh uses GraphQL for

`gh pr create/view/merge` and `gh issue list` use GraphQL. REST equivalents:

```bash
# Create PR
gh api -X POST repos/{owner}/{repo}/pulls --input - <<< '{"title":"...","head":"branch","base":"main","body":"..."}'

# Merge PR (squash)
gh api -X PUT repos/{owner}/{repo}/pulls/{n}/merge --input - <<< '{"merge_method":"squash","sha":"<head_sha>"}'

# PR metadata (REST — includes mergeable)
gh api repos/{owner}/{repo}/pulls/{n} --jq '{state,mergeable,head:.head.sha}'

# Issue comment
gh api -X POST repos/{owner}/{repo}/issues/{n}/comments --input - <<< '{"body":"..."}'

# Close issue (PATCH state)
gh api -X PATCH repos/{owner}/{repo}/issues/{n} --input - <<< '{"state":"closed"}'

# Head sha without GraphQL: git rev-parse HEAD
```

## Batching guidance

- Bulk closes/comments: insert a short sleep between calls (bulk closing 48 issues in
  one burst is what triggered the secondary limit).
- Prefer one REST call per fact over repeated `gh ... view` calls in loops.
- PR review records, merges, and issue closes are idempotent-safe: check current state
  before retrying after a rate-limit error.
