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

⛔ **Corrected 2026-10-17 (agent-infra#1910): the section below that told you to read
`rate_limit` for the secondary limit was WRONG, and it is the mistake that reopened this
runbook's own incident.** `GET /rate_limit` reports the **primary** budget only; GitHub
documents that it **does not expose proximity to secondary limits**, and a secondary
refusal may carry no `retry-after` at all. A healthy `graphql.remaining` beside a refused
call is therefore the documented blind spot, not a contradiction — measured 2026-10-17
with `used: 541` of 5000 while every GraphQL call was refused.

**Two layers page this file, and they compose rather than compete.** The #1988 helper below
serialises *harness* traffic (one call in flight per box, bucket-named backoff, conditional REST);
the #1910 courtesy gate in `scripts/gh-shim/gh` paces *every* `gh` a pi session calls, bounds
concurrency per machine, and spaces call starts. A harness session resolves the #1988 shim first,
which resolves the next `gh` on PATH — including `gh-shim`, so the argv gate stays in the chain.
Where both pace, the cost of a mutating call is one extra `>= 1 s` gap. Neither layer supersedes
the other; changing one does not change the other's guarantee.

## The layer that owns this now (#1988)

Every harness `gh` call goes through **one** helper, `scripts/orchestrator-harness/gh-limit.py`,
reached from two entry points: the Mac REST adapter (`gh-rest/gh`, first on the daemon PATH) and the
cell wrapper (`gh-limit/gh`, first on the cell's controller PATH). It implements GitHub's own
documented policy, so this file does not restate the numbers — it names where to look.

| Behaviour | Where |
|---|---|
| ONE `gh` call in flight per box (`flock` on `$GH_LIMIT_DIR/gh.lock`) — including the `/rate_limit` probe, which runs while the caller is in backoff | `acquire_lock` |
| **Identical concurrent READS share ONE load** (`#2243`): the key is the normalised request (host + credential digest + cwd repo pin + endpoint + argv), a waiter shares the leader's result **or its failure** under a **bounded** wait, and a waiter past the bound gets a distinct `busy` (exit **75**, holder's age on stderr) instead of an unbounded queue. A leader that died or overran is taken over, so no orphan claim survives | `single_flight` / `flight_key` / `flight_eligible` / `prune_flights` |
| **Never coalesced**: mutations (two merges are two merges), `auth` (its stdout is the credential) and `/rate_limit` (the pass's own meter) | `flight_eligible` |
| A previous answer may be served **while a refresh is in flight** — opt-in only (`GH_LIMIT_FLIGHT_STALE_SERVE=1`, off by default) and then the age goes on stderr; stale is never presented as current | `single_flight` (stale branch) |
| `retry-after`, then the bucket's `x-ratelimit-reset` when remaining is 0, then **≥ 60 s doubling** with upward jitter; **4 attempts**, then fail loudly | `plan_wait` / `dispatch` |
| The failing **bucket** is named (`core` vs `graphql`) with its reset — never inferred from whichever counter looks healthy | `bucket_for` / `fail_loudly` |
| **≥ 1 s between mutative calls** (POST/PATCH/PUT/DELETE) | `pace_mutation` |
| Conditional REST for polling: ETag stored per URL (host + path + credential digest), `if-none-match` sent, a **304 replayed from cache** and charged nothing. The cached body is base64 (a 304 replay is byte-exact, binary included) and the cache is bounded in ENTRIES and BYTES (`GH_LIMIT_CACHE_MAX_ENTRIES` 500, `GH_LIMIT_CACHE_MAX_BYTES` 64 MiB) | `conditional_fetch` / `cache_put` / `prune_cache` |
| The shim stays FIRST on PATH even though every gh-calling harness script prepends `/opt/homebrew/bin:/usr/local/bin` | the `$O/gh-limit` / `$O/gh-rest` re-assert in the harness scripts that prepend and invoke `gh` |
| The heartbeat's tooling (`objective.py`, `merge-queue.py`, `beta-progress.py`, `ask-owner.py`, `turn-classify.py`, `turn-end.py`, `undelivered-answers.py`, `pr-doctor.py`) reaches the layer instead of a pinned real binary | each resolver prefers `$O/gh-rest/gh` then `$O/gh-limit/gh` (`$O`-derived, never PATH); the five that HAVE a pinned candidate also hand it through as `GH_REST_REAL_GH`/`GH_LIMIT_REAL_GH` (see the residual below for the three that never pinned). Was nine/six until agent-infra#1874 retired `retired/queue-dispatch.py` — a retired tool is not in the beat, so it is not counted here |

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
  and the heartbeat's telemetry tools (`objective.py`, `merge-queue.py`, `beta-progress.py`) prefer
  `$O/gh-rest/gh` then `$O/gh-limit/gh` over their pinned real binary —
  `gh-rest` first, matching every shell call site, because the adapter is what serves a GraphQL
  refusal over REST (#1959).

### Known residuals (declared, not papered over)

- **Cross-box concurrency is not serialised.** Boxes cannot see each other; the invariant is one
  call in flight *per box*.
- **Coalescing is per box, and only for requests that are identical RIGHT NOW** (`#2243`). Two lanes
  reading the same PR 10 s apart are two loads (the answer is not cached as current — only a flight
  still in progress is shared), and two boxes reading it are still two loads. What the layer removes
  is the *queued duplicate*: the measured 63 s `gh pr view` at 13 lane processes was ours, not
  GitHub's. `GH_LIMIT_FLIGHT=0` turns it off; `GH_LIMIT_FLIGHT_WAIT` (5 s, Nginx's
  `proxy_cache_lock_timeout` default) is the bound, `GH_LIMIT_FLIGHT_LEADER_MAX_AGE` (120 s,
  `proxy_cache_lock_age`) is when a stalled holder is taken over.
- **A `busy` outcome is a NOT-AN-ANSWER.** Exit **75** with `BUSY single-flight …` on stderr, naming
  the holder's pid and age. It is deliberately not a rate limit and carries no bucket, so a caller
  that classifies failures must retry it rather than record it as quota — and it never inherits the
  wait: the bound is the whole wait.
- **A degraded state dir**: if `$GH_LIMIT_DIR`/`$XDG_CACHE_HOME` cannot be created, the fallback is
  a per-user temp dir (`${TMPDIR}/gh-limit-<uid>`), which still shares one lock between that user's
  processes and records the degradation in its own `events.log` — but the controller's heartbeat
  reads the *primary* path, so it will not see that box's `last-limit`.
- **The lock timeout** (`GH_LIMIT_LOCK_TIMEOUT`, 600 s) proceeds UNSERIALISED and says so in
  `events.log` — one slow gh call must not park a box's merge sweep for ever.
- **Interactive and streaming `gh`**: output is captured, so a human running `gh` in a harness
  session loses TTY rendering, and a long `--watch`-style command would buffer. The harness itself
  has no streaming call.
- **`--jq` replay uses the external `jq` binary** (gh vendors its own engine); when `jq` is absent
  the call is left unintercepted rather than served by us.
- **A layer that sleeps cannot outlive its caller, so a bounded caller gets no backoff.**
  `GH_LIMIT_NO_WAIT=1` makes the layer record the limit and return at once; EIGHT heartbeat tools set
  it (`objective.py`, `merge-queue.py`, `beta-progress.py`, `ask-owner.py`, `turn-classify.py`,
  `turn-end.py`, `undelivered-answers.py`, `pr-doctor.py`), because each one's own
  bound is a per-CALL timeout in the 60-420 s range (or a `run_bounded` step of 20-90 s) that is
  consumed by the layer's first documented wait of 60 s, or shared with every other call the step
  makes — the outcome is a timeout, and the box then reports `UNKNOWN`/`STALL` instead of the
  `RATE-LIMITED` verdict it can prove. (One of the eight — `pr-doctor.py` — is
  launched detached by `heartbeat-loop.sh` and reaped by its own lock, so its bound is per call,
  not per pass; the decision is the same. It was nine while `retired/queue-dispatch.py` was still part
  of the beat — retired in agent-infra#1874, so it is no longer a resolver here.) The shell call sites
  keep the waits: they have no
  subprocess bound of their own.
- **The layer resolves the REAL gh by walking PATH.** A tool that has a pinned candidate hands it
  through as `GH_REST_REAL_GH`/`GH_LIMIT_REAL_GH` — `objective.py`, `merge-queue.py`,
  `beta-progress.py`, `ask-owner.py` and `pr-doctor.py` (via `objective.py`'s
  resolver) do — so #1872's pin survives for those. `turn-classify.py`, `turn-end.py` and
  `undelivered-answers.py` never had a pin: they resolve the layer through `$O`, and the layer then
  walks PATH. (A sixth, `retired/queue-dispatch.py`, did until agent-infra#1874 retired it — it is
  not part of the beat, so it is not counted.) On a box whose PATH puts a refusing wrapper first, any of these gets that wrapper
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
- **The child `gh` has no timeout.** A hung request holds the attempt lock for its whole duration;
  other callers wait up to `GH_LIMIT_LOCK_TIMEOUT` (600 s) — or `GH_LIMIT_NO_WAIT_LOCK_S` (5 s) when
  `GH_LIMIT_NO_WAIT=1` — then proceed UNSERIALISED with an `events.log` line. No timeout is imposed
  on the child: a legitimate `gh` call's duration is not knowable here.
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
`gh.lock`, `etag/`, `flights/` (one `<key>.leader` claim and one `<key>.json` last outcome per
in-flight request — `#2243`), `last-mutation`, `last-limit`, `events.log`.

Operator knobs (all optional): `GH_LIMIT_MAX_ATTEMPTS` (4 attempts in total), `GH_LIMIT_BASE_WAIT` (60 s),
`GH_LIMIT_MAX_WAIT` (300 s — a reset beyond this fails FAST so the caller's own deferral takes
over), `GH_LIMIT_LOCK_TIMEOUT` (600 s), `GH_LIMIT_MUTATION_GAP` (1 s),
`GH_LIMIT_CACHE_MAX_ENTRIES` (500), `GH_LIMIT_CACHE_MAX_BYTES` (67108864 — 64 MiB; the cache is
bounded in entries AND bytes, whichever binds first), `GH_LIMIT_CONDITIONAL=0` (disable the ETag
path), `GH_LIMIT_NO_WAIT=1` (never sleep in-process — set by callers that have their own bound) with
`GH_LIMIT_NO_WAIT_LOCK_S` (5 s — the lock budget under `NO_WAIT`, and the flight budget with it).
Coalescing (`#2243`): `GH_LIMIT_FLIGHT=0` (disable it), `GH_LIMIT_FLIGHT_WAIT` (5 s — Nginx's
`proxy_cache_lock_timeout` default; past it a waiter returns `busy` at exit 75),
`GH_LIMIT_FLIGHT_LEADER_MAX_AGE` (120 s — `proxy_cache_lock_age`; a holder older than this, or one
whose pid is gone, is taken over), `GH_LIMIT_FLIGHT_KEEP_S` (30 s — how long a finished outcome stays
on record), `GH_LIMIT_FLIGHT_STALE_SERVE=1` (serve a previous answer while a refresh is in flight,
WITH its age on stderr; off by default), `GH_LIMIT_FLIGHT_STALE_MAX_AGE` (30 s), and
`GH_LIMIT_FLIGHT_MAX_ENTRY` (4 MiB — a larger outcome is not shared; waiters take the key over).
Every knob
is range-clamped, and `nan`/`inf` fall back to the documented default rather than disabling a bound
(an `inf` lock timeout would be a hang, a `nan` wait a traceback).
`GH_LIMIT_NOW_CMD`/`GH_LIMIT_SLEEP_CMD` are the TEST seams for the fake clock — do not set them
in production. ⛔ The flight ledger deliberately does NOT use them: it measures a LIVE process's age
and an answer's age, and both are safety labels (a stale answer must never read as current), so a
knob must not be able to make one look like the other.

⛔ **Also corrected 2026-10-17 (agent-infra#1910): the section below that told you to read
`rate_limit` for the secondary limit was WRONG, and it is the mistake that reopened this
runbook's own incident.** `GET /rate_limit` reports the **primary** budget only; GitHub
documents that it **does not expose proximity to secondary limits**, and a secondary
refusal may carry no `retry-after` at all. A healthy `graphql.remaining` beside a refused
call is therefore the documented blind spot, not a contradiction — measured 2026-10-17
with `used: 541` of 5000 while every GraphQL call was refused.

## Two limits, different behavior

| Limit | Scope | Symptom |
|---|---|---|
| **Primary** | 5000 req/h (REST + GraphQL separate pools) | `rate limit exceeded`, `gh api rate_limit` shows `remaining: 0` |
| **Secondary** | **concurrency** — no more than ~100 requests in flight, **shared across REST and GraphQL and across every machine on the account**; also burst/abuse detection for writes | `API rate limit already exceeded for user ID ...` while the primary counter reads healthy; may carry `retry-after`, may not |

**The secondary limit is not a budget problem, so spending less is not the fix.** The
harness does not arrive too expensively — it arrives too **concurrently**, and then
retries *into* the burst (`3/3 attempts, identical`, which cannot succeed by
construction). The fix is pacing, and there are two facts that follow from it:

- **The fleet's concurrency cap is a shared resource.** The ceiling on parallelism is
  neither CPU, RAM nor disk, and it is not visible from any box. See the capacity section
  of `scripts/orchestrator-harness/README.md`.
- **`rate_limit` is not a health signal for it.** Do not poll it to decide whether to
  proceed. The authoritative signal is the gate's own in-flight count.

## The gate (do not work around it)

This is the LAST hop before the real binary, and it sits *below* the #1988 helper above rather than
replacing it: `gh-limit`/`gh-rest` apply the policy, then delegate the call through this shim, so a
mutating call passes both layers. ⛔ **Their limits do NOT simply "compound to the tighter one".**
The concurrency cap of 1 (that layer) makes this layer's cap of 2 redundant, and a single wait is
bounded by both — but the RETRY **multiplies**: this gate re-runs the whole command up to 3 times and
that layer up to 4, so one argv can execute up to 12 times, including a non-idempotent create or
comment. A caller that declared its own per-call bound suppresses this layer's sleep
(`GH_LIMIT_NO_WAIT=1` is honoured), which is why the two layers must agree on it. That is also why
the shim must not resolve a harness layer as "the real gh" — see `find_real_gh`.

⛔ **Nothing here writes to a successful call's stderr.** `gh-rest/gh` parses `2>&1` as JSON, so
pacing notes go to `~/.pi/agent/gh-gate/events.log` and are replayed to stderr only when the call
fails. If you are debugging pacing, read the log.

Every `gh` call that goes through the argv-level shim (`scripts/gh-shim/gh`, installed at
`~/.pi/agent/shims/gh`) is paced per machine:

- at most `AGENT_GH_GATE_MAX_INFLIGHT` (default **2**) `gh` processes in flight;
- at least `AGENT_GH_GATE_INTERVAL_MS` (default **250 ms**) between call starts;
- on a rate-limit refusal: honour `retry-after`, else wait `AGENT_GH_GATE_RETRY_BASE`
  (**60 s**), doubling per attempt, and write a **shared cooldown** so the other lanes on
  the box wait instead of walking into the same window. Never an immediate retry.
- state lives in `~/.pi/agent/gh-gate` (`slots/`, `cooldown.*`). A stale slot is reaped by
  PID, so a killed lane cannot wedge the fleet.

⚠️ **A caller that resolves the real `gh` by absolute path, or clears PATH, is not paced.**
The one that did deliberately for read-only queries was the retired
`scripts/orchestrator-harness/retired/queue-dispatch.py` (agent-infra#1874); no live caller does it
today. When you add such a caller, you are adding an unpaced `gh` — say so in the comment, as that
file does.

## Detect

```bash
# Primary budget only. A healthy reading does NOT mean the account is usable.
gh api rate_limit --jq '.resources | {core: .core, graphql: .graphql}'

# What the fleet is actually doing (the gate's own signal):
ls ~/.pi/agent/gh-gate/slots | wc -l          # slots HELD — a stale one is reaped by PID only on
                                              # the next admission, so this can slightly overstate
ls ~/.pi/agent/gh-gate/cooldown.* 2>/dev/null  # an active refusal window
tail -5 ~/.pi/agent/gh-gate/events.log         # what the gate did: paces, waits, fail-open notes
cat "${HOME:-${TMPDIR:-/tmp}}/.pi/agent/gh-gate-degraded.log"  # present only if the gate dir was
                                              # UNUSABLE: every call then ran UNGATED, and this is
                                              # the only place that fact is recorded (it cannot
                                              # live in the gate dir that is unusable). It is in
                                              # the user's own tree, not a predictable name in a
                                              # world-writable TMPDIR.
```

- `graphql.remaining: 0` → GraphQL **primary** pool exhausted; REST (`core`) is usually still fine.
- ⛔ **This counter LIES about its own headroom.** Measured 2026-10-17: `gh api rate_limit` reported
  `4999/5000` while EVERY GraphQL call was refused (`API rate limit already exceeded for user ID
  81560491`). The pools are separate, so a healthy number here is not evidence the GraphQL path
  works. That is why the limit layer names the bucket the FAILING CALL used instead of trusting
  this read (#1988, #1762), and why the gate's health signal is its own in-flight count (#1910).
- `429`, or `403` whose text names a rate limit / abuse detection → secondary. Wait: the shim
  already does. **Do not retry immediately, and do not retry in a loop** — that is what turns
  one refusal into a fleet-wide outage.
- A bare `403` with a permissions message is NOT a rate limit; the shim does not retry it (a
  mutating command must not run twice).

### When it is the merge rail refusing

`scripts/admin-merge.sh` classifies the same refusal: a rate-limited read or merge carries
`[rate_limited]` **beside** the tag it already had (`head_unreadable`,
`merged_precheck_unreadable`, `merge_unreadable`), so existing consumers of those tags keep
working. Do not read that tag as "the PR is unreadable" or "the token is wrong" — MEASURED
2026-10-17 on PR #1934: two rail runs surfaced a burst refusal as `head_unreadable` whose hint
said "check credentials, --repo, and the PR number", the credential was fine, and the operator's
next move was a raw REST merge — a bypass of the rail rather than of the limit. A
`[rate_limited]` refusal is **retryable**: re-run the rail once the window has cleared. The
shim's retries (above) run first and each re-send is bounded by
`AGENT_GH_GATE_MAX_ATTEMPTS` × the gh-limit layer's 4, so a call that exhausted both layers
means the window outlasted that budget.

## The other direction: an EMPTY `core` is served from GraphQL (2026-10-22)

⛔ **The section below is the GraphQL->REST direction. This one is its mirror, and it is the incident
that exhausted a budget in a single hour.**

MEASURED 2026-10-22 14:03Z, on one account, one identity (`daniel-ospina`), every lane and the merge
rail sharing it:

```
core    : 5000 used / 0 remaining,     resets in 12 min
graphql :  255 used / 4745 remaining
```

The REST pool was empty and the GraphQL pool was 95% free. Nothing could use it. `repo-authority.sh`
could not read branch protection, the rail fell back to `REQ_SOURCE=fallback`, every PR was refused
with "the merge contract is UNKNOWN", and `gh auth status` reported **"the token … is invalid"** —
three confident diagnoses, all wrong. A budget our own polling spent is indistinguishable, from inside
a lane, from GitHub being down; the layer's job is to say which one it is.

**Where it lives:** `scripts/orchestrator-harness/gh-limit.py` (the one helper both entry points call)
and `repo-authority.sh` for the reader that was lying.

### 1. Both budgets, at no cost on the hot path

`--budget` spends **one** `GET /rate_limit` — an endpoint that is **exempt from the primary limit**
(measured answering normally with `core` at 0) — and records both pools for `GH_LIMIT_BUDGET_TTL`
(30 s) in `$GH_LIMIT_DIR/budget.json`, under the single-flight lock like every other request. A
dispatcher about to fan out calls it once; every call it then makes reads the shared snapshot.

```bash
python3 scripts/orchestrator-harness/gh-limit.py --budget
# core=0/5000 resets_in=12m graphql=4745/5000 resets_in=22m
```

⛔ **The per-call path never probes.** The first draft read `/rate_limit` from every `core` call; that is
one extra request per call site per box, and it made the layer's cost depend on call frequency. The
layer now learns the budget from exactly two places that already had a reason to ask: the `--budget`
verb, and the refusal path's own `probe_rate_limit` (which now records *both* pools while it is there).
The durable `last-limit` record is the third, free, source — so the **first** refused `core` call on any
lane is the evidence every other lane fails over on, without a request of its own.

### 2. Fail over, only where the answer is EXACT

`graphql_plan()` maps a REST read to a GraphQL query with a **field-for-field REST body encoder**; the
caller's own `--jq` is then applied to that body exactly as it would be to a real one. Admission is
`conditional_plan`'s — a plain GET, one positional, no `--paginate`/`-i`/`-H`/`--template` — so a shape
the layer refuses to intercept can never be failed over either.

| REST read (core) | Served from GraphQL | Notes |
|---|---|---|
| `repos/{o}/{r}/pulls/{n}` | ✅ | state, draft, merged, mergeable, title, **body**, head.sha, head.ref, base.sha, base.ref, changed_files, additions, deletions, comments (count), created_at/updated_at/closed_at/merged_at, user, html_url |
| `repos/{o}/{r}/pulls/{n}/reviews` | ✅ | id, state, body, submitted_at, commit_id, user |
| `repos/{o}/{r}/issues/{n}/comments` | ✅ | id, body, created_at, html_url, user |
| `repos/{o}/{r}/branches/{b}/protection[/…]` | ❌ **no equivalent** | GraphQL has no branch-protection query. Refused with the named state. |
| `repos/{o}/{r}/commits/{sha}/check-runs`, `/status` | ❌ **deliberately absent** | `statusCheckRollup` mixes `CheckRun` and `StatusContext` nodes; a StatusContext has no `check_run` representation, so a synthesized list would silently drop legacy statuses — a red surface that reads green. Fail closed. |
| any mutation (merge, comment, PATCH) | ❌ never | There is no GraphQL equivalent that IS the same write. (`gh api` mutations are refused by name when `core` is empty; `gh pr merge` is GraphQL-bucketed by `bucket_for`, so it is not gated by the core rule at all — a pre-existing heuristic, stated here rather than implied.) |

⛔ **`merge_commit_sha` IS THE FIELD THAT MUST NOT BE REPRODUCED.** For an **unmerged** PR, REST
`merge_commit_sha` is the *tentative* test-merge commit and GraphQL's `mergeCommit` is **null** — the
merge rail's own header says so, and that is precisely why `admin-merge.sh` reads the REST object
instead of `gh pr view --json mergeCommit`. Serving that name from the GraphQL field made the merge ref
read `absent` for every open PR, and the rail then BLOCKS with *"no CI run has evaluated the merge of
this PR into its base"* — a fabricated CI diagnosis, for the whole empty-core window, on the very
merges the failover exists to keep alive. There is no faithful source, so the projection is refused
(tests `(g2)`), and the rail's read fails closed on the NAMED state instead of blaming CI.

⛔ **A `--jq` IS REQUIRED FOR A FAILOVER.** A raw body (no projection) carries no evidence about which
fields the caller will read, and the encoder is a **subset** of a REST pull object — the fleet's own
adapter (`gh-rest/gh`) projects `labels`, `assignees`, `mergeStateStatus`, so a labelled PR read back
as `[]` with rc 0. A read with no `--jq` is therefore refused by name on an empty core, never answered
from a partial body. Serving *a projection we can verify* is the contract; `field-for-field` describes
the listed fields, not the whole REST object.

⛔ **A `--jq` THAT NAMES A FIELD THE ENCODER DOES NOT PRODUCE IS NOT FAILED OVER.** `jq` prints `null`
for an absent field **and exits 0**, so a partly-reproduced body is not a near miss — it is an empty
answer with a success status. Measured in review of this change: `--jq .body` returned `null`/rc 0, and
`record-review.sh` reads `.body` precisely to tell "the GET failed" from "the body is empty" before it
PATCHes a PR description. `_projection_ok()` therefore admits a projection only when every name it
references is reproducible — **dotted, bracketed (`.["body"]`), and with no recursive descent (`..`) or
shape operator (`keys`, `to_entries`, `getpath`, `paths`, `map_values`, `tojson`)** whose output cannot
be shown to stay inside the body. Otherwise the read is **not** failed over, and with the pool empty it
is refused by name. Over-blocking costs a refusal that was coming anyway; under-blocking costs a
confident wrong answer.

**The low-water band is not exhaustion.** `CORE_LOW_WATER` (default 100) moves *reads* to GraphQL so
the tail of the pool is preserved for **writes** — writes are refused ONLY at `remaining == 0`, and no
`gh-core-exhausted` record is written while the pool still has headroom (including on the
failover-FAILURE path, where the honest name is `gh-graphql-unavailable`, not an empty core pool). A
band that refused writes would preserve a reserve no caller could spend, and would assert "EMPTY"
about a pool that is not.

**A refusal we could not DATE is still evidence, for a bounded window.** A core call refused without a
reset (no `--include` framing, and every `GH_LIMIT_NO_WAIT` caller skips the probe) is recorded as
`gh-core-exhausted resets_in=?`, and it is honoured for `GH_LIMIT_HEALTH_UNKNOWN_WINDOW` (900 s) from
its own `at=`. Deriving "healthy" from `reset == 0` made `--health` say `gh-ok` while the pool was
spent and nothing failed over (test `(h2)`).

⛔ **A GAIN, NOT A LAUNDER.** Servings are recorded in `events.log` as
`failover: gh-core-exhausted resets_in=4m (core remaining=0) — serving \`gh api …\` from the GraphQL pool`.
A **live** line from the incident itself, in this repo's own checkout:

```
1792678353 failover: gh-core-exhausted resets_in=4m (core remaining=0) — serving
             `gh api repos/daniel-ospina/tortoise/pulls/9134` from the GraphQL pool
```

Plain `gh api repos/…/pulls/9134 --jq .head.sha` at the same moment: `HTTP 403 API rate limit
exceeded`, rc 1. Through the layer: `8600acf1beefb80389e81541e463575388bccf6b`, rc 0.

### 3. The TTL read cache (a companion to single flight)

Single flight (#2243) collapses **concurrent** duplicates; it shares only a result that completed after
the caller arrived, so N lanes asking one question a minute apart still make N requests. A TTL cache
admitted **per query class** removes those: `pr-state` 10 s, `protection` 60 s, `comments`/`reviews` 15 s,
`checks` 10 s, `pr-list` 5 s, `run-list` 10 s. An **unlisted shape is never cached — there is
deliberately no default**. Only a **success** is stored. `GH_LIMIT_READ_CACHE=0` disables it.

⛔ **`run-list` is in that list because it was MEASURED, not because it seemed reasonable** — see the
budget arithmetic below: 30 of the 41 calls in one merge cycle were a single FIRST-CHECKS poll loop
issuing byte-identical argv 16 times against data that changed zero times.

⛔ **One cache per shape, and the ETag path wins its own.** A `gh api` GET that `conditional_fetch` will
revalidate already has a stronger mechanism: a `304` costs **no quota** and returns a body the server
just confirmed is current, so wrapping a TTL cache over it would hand out an older body where a fresh
one was free — and would break the documented "the second poll SENDS if-none-match" guarantee. The TTL
cache therefore applies exactly where the ETag path cannot reach: **subcommands** (`gh pr view`,
`pr list`, `pr checks` — all GraphQL, which has no ETag at all) and the `gh api` shapes
`conditional_plan` refuses (`--paginate`, `-i`, `-H`, `--template`). That is precisely the traffic
whose only saving today is single flight. Test `(c3)` pins the split.
⛔ **Consequence, stated so the class table is not read as a claim about default traffic:** with
`GH_LIMIT_CONDITIONAL=1` every plain `gh api` GET is ETag-revalidated and therefore never TTL-cached, so
by default the `gh api` classes above are reachable only when the ETag path is off or the shape is one
it refuses (`--paginate`, `-i`, `-H`, `--template`). The default saving is on **subcommands** —
`pr view`/`pr list`/`pr checks`/`run list` — which is also where the measured waste was.

### 4. The named state (what a lane should SAY)

```bash
python3 scripts/orchestrator-harness/gh-limit.py --health
# gh-core-exhausted resets_in=12m     (exit 3)
# gh-ok                              (exit 0)
```

It reads **local state only** — no request, no credentials, no quota — which is what makes it usable at
exactly the moment every `gh` call is being refused, and it is age-bounded by the record's own reset so
a closed window cannot keep asserting itself. `repo-authority.sh` repeats the token verbatim instead of
reporting an unreadable contract as if the repo were broken. A `core` refusion from the helper carries
the same token **and** keeps the words `rate limit`, because `objective.py`'s `TRANSPORT_MARKERS` turn
that phrase into `VERDICT=GH-RATE-LIMITED`.

⛔ **THE SECONDARY LIMIT HAS ITS OWN TOKEN, AND IT IS NOT EXHAUSTION.** A burst/concurrency refusal
arrives as a 403/429 in the same shape as a primary one, but its `x-ratelimit-remaining` is **above
zero** — so it is named `gh-secondary-rate-limited remaining=<n>`, it writes **no** health record, and
it never gates a write. Without that distinction a transient burst froze every merge/comment/PATCH on
the box for up to an hour and told the operator the pool was empty while thousands of requests were
left. The durable `last-limit` record carries `remaining=` for the same reason.

⛔ **DATED EVIDENCE MAY REFUSE; UNDATED EVIDENCE MAY ONLY DIVERT.** A record whose reset is known is a
measurement, and it may refuse a read outright. A record written from a refusal that carried **no**
reset cannot say when the window ends, so it may only *divert* a read to GraphQL — never refuse one —
and it expires on its own after `GH_LIMIT_HEALTH_UNKNOWN_WINDOW` (900 s). Two failures are pinned here:
the window a reader *invents* must never be written back as if it were observed (that turned one
headerless refusal into "core empty until T+15m" with no way to clear it, because the only cure is a
successful core call and none was being attempted), and `--health` must not report `gh-ok` from a
`reset=0` record.

⛔ **THE EVIDENCE IS THREE FILES AND NONE OF THEM MAY BE CLOBBERED BY ANOTHER BUCKET'S NEWS.**
`last-limit` holds ONE record per box (pre-existing design), so a GraphQL refusal overwrites the `core`
observation — and the health record, which is keyed to `core` explicitly, is what keeps the window
alive afterwards (`health_reset()`). Two measured consequences of getting this wrong, both fixed and
pinned by tests `(h)`/`(i)`: a both-pools refusal made `--health` say `gh-ok` (the state vanishing
exactly when it was worst), and a GraphQL-served read annotated the **core** record `recovered=`
(destroying the free evidence the failover runs on, and making the heartbeat print
`gh=recovered(bucket=core …)` for a pool that was still refusing calls). A GraphQL success now records
recovery for `graphql`, and only a real `core` success clears `gh-core-exhausted`.

### What this does NOT fix

- **The secondary (concurrency) limit is shared across REST and GraphQL.** Switching pools moves the
  request, not the refusal. Pacing (`gh-shim`, the box lock) is the answer to that one.
- **Reads are conserved, not free.** A failover read still spends GraphQL quota; if BOTH pools are
  empty the named state is all that is left, and it fails closed (test `(b)`).
- **`check-runs`, branch protection and `merge_commit_sha` still cannot be read from an empty core.**
  They fail closed with the name; they do not degrade.
- **A FRESH meter outranks a durable record.** If `/rate_limit` reports headroom while calls are being
  refused — the measured "lying meter" of #1988 (`4999/5000` beside every GraphQL call refused) — then
  `core_pressure()` trusts the fresh snapshot and does NOT fail over for up to `GH_LIMIT_BUDGET_TTL`.
  The record is deliberately subordinate to a newer measurement; the cost of being wrong is a window of
  refused reads, not a wrong answer.
- **A degraded state dir splits the two readers.** `repo-authority.sh` reads only the primary state
  dir, while `gh-limit.py` falls back to `$TMPDIR/gh-limit-<uid>`; in that state both say nothing rather
  than disagree, and the `--health` verb is the one that still answers.

### Where the budget actually goes (measured, not estimated)

⛔ **One merge cycle, counted end to end** (2026-10-22, PR 9134, `--dry-run`, a counting pass-through in
front of the real `gh`):

| | count |
|---|---|
| total `gh` invocations | **41** |
| `REQ_SOURCE`/core-bucket invocations | **38** |
| GraphQL invocations (`gh pr view`) | 3 |
| `--paginate` invocations (each page is another request, so the true draw is HIGHER) | 16 |
| **of which one FIRST-CHECKS poll loop** (`run list` + `jobs?per_page=100`) | **30 (73 %)** |

That is a **blocked** cycle — the rail stopped at its lane precondition, so the merge itself, the
evidence comment, the CI re-run and the base-suite reads are NOT in it. **41 is a floor.**

The loop is the duplication: 15 iterations at 10 s each, **two** invocations per iteration, and
`run list` ran with byte-identical argv **16 times** against data that had not changed once in 150 s.
The TTL cache now covers `run list` (10 s — the loop's own cadence, so at most one extra poll of
latency); the `--paginate` half is deliberately not cached and remains a per-iteration request.

⛔ **And the merge rail is not the main consumer.** A refresh pass is measured in this repo at **134
core requests**, of which **72 (54 %)** are the same three fleet-wide answers asked once per candidate.
At the shipped 240 s cycle (`CYC:-240`) a single box runs that pass **15×/hour**:

```
134 core/pass × 15 passes/h  = 2,010 core/h  per box
                             → 2 boxes  ≈ 4,020/h   (under 5,000)
                             → 3 boxes  ≈ 6,030/h   (OVER — the pool dies before the hour does)
```

with ~11 live lanes measured on one box (38 core per merge cycle each). So the pool is spent by
**polling**, in two places: the per-candidate refresh fan-out and the per-iteration check poll. The
failover and the cache make that spend survivable; they do not make it free — the duplication in those
two loops is the lever that actually lowers it.

## Fallback: REST for the operations gh uses GraphQL for

⚠️ **REST shares the same concurrency cap.** Switching transport gets you out of an
exhausted GraphQL *primary* pool; it does **not** get you out of a secondary limit, which
is shared across REST and GraphQL. If you are being refused for concurrency, switching to
REST just moves the refusal. The shim's pacing is the answer to that one; REST is the answer
to `graphql.remaining: 0`.

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
  one burst is what triggered the secondary limit). The shim's spacing does this for you
  only if you are going *through* it — a loop that calls the real binary directly is
  unpaced by construction.
- Prefer one REST call per fact over repeated `gh ... view` calls in loops.
- PR review records, merges, and issue closes are idempotent-safe: check current state
  before retrying after a rate-limit error.
