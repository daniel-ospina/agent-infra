---
title: "GitHub API rate limits — detection & fallback runbook (#143, #1988)"
type: engineering
domain: operations
doc_status: live
subjects.team: organisation-design-team
created: 2026-08-10
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-143, issue-1762, issue-1988, issue-2227, gh-rate-limits, gh-limit, issue-2139, issue-2143
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

## A serialised call is SLOW, not ABSENT — the readers must say which (#2227)

Serialising per box is the correct remedy for the secondary limit, and it has a cost that is easy to
misread: **latency becomes a function of how many lanes the box is running.** Measured 2026-10-20 on
three cloud cells:

| lanes on box | `gh pr view` |
|---|---|
| 13 | **63.0 s** |
| 3 | 0.676 s |
| — | 0.091 s (raw `curl` to `api.github.com` — network and account fine) |

A reader whose timeout sits under that number does not bound the read, it **manufactures a false
absence** — the beat printed `queue_read=BLIND(14/14 unread)`, `merged_24h=?` and
`VERDICT=UNKNOWN (merge-rate read failed)` roughly hourly for data that was merely not served yet.

The rules that follow from it, and where they live:

- **The read budgets are derived from the measurement, never picked.** `objective.py`'s
  `QUEUE_READ_MAX_S` (100 s) is 1.6x the measured worst case; `merge-queue.py`'s
  `MERGE_RATE_TIMEOUT_S` (100 s) is the same. Changing either without the measurement is the same
  mistake in the other direction.
- **The reader CLIPS its cap to the caller's declared bound** (`OBJECTIVE_CALLER_BOUND_S`, set by
  `heartbeat-loop.sh` and `lane-scan-fallback.sh` as `run_bounded`/`bounded` arguments). The reader
  and the loop deploy separately (`heartbeat-loop.sh` is a declared, withheld farm entry, #1553), so
  a new reader under an old 90 s loop reads for 66 s and still PRINTS. A budget above the caller's
  kill is an inert bound: the process dies and writes no line at all.
- **A slow read is DATA and says so; a failed read says why.** `queue_read=SLOW(waited=63.1s)`
  carries real counts and no caveat; `queue_read=UNREADABLE(waited=100.4s, last_good=812s)` carries
  `what it tried`, the wait, and the AGE of the last good sample, and **no counts at all** (#1869
  still governs: a stale number never stands in for an unread one, and a stale value may be shown
  only labelled with its age — `merge-queue.py` prints `last_good_rate=` and still refuses a
  verdict).
- **`BLIND` keeps its narrow meaning** (the merge state never came back readable), so a word that
  covers "we waited 63 s and got an answer" cannot also cover "we never got an answer".
- Bounds that a busy box can exceed are not bounds: `lane-status.py` caps the WORK it walks
  (session files, pids, activity files) and reports `lane-status: SAMPLED …` when a cap bites.

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
| `retry-after`, then the bucket's `x-ratelimit-reset` when remaining is 0 **and the refusal is PRIMARY**, then **≥ 60 s doubling** with upward jitter; **4 attempts**, then fail loudly. A **secondary/unclassified** refusal never adopts a reset as its wait — the primary counter does not predict a secondary limit | `plan_wait` / `limit_kind` / `dispatch` |
| **The ACCOUNT's budget is partitioned, not the box's** (`#2137`): `5000 × safety ÷ declared fleet ÷ 60` per bucket per window, floored at 1 call/window, taken immediately before each send | `account_share` / `budget_gate` |
| **An UNCLASSIFIED refusal (`status=?`) is its own class** — treated like a secondary one (≥ 1 min, jittered, doubling) and recorded as `kind=unclassified`, because the bucket reset that used to be its only number is not a recovery time | `limit_kind` |
| **The block window is the classification's, not the reset's**, and it is revalidated before it is paid: one exempt `GET /rate_limit` above `GH_LIMIT_GATE_REVALIDATE_S`, `remaining > 0` ⇒ the marker is stale (annotated, age kept) ⇒ the call proceeds. A marker older than the window it recorded, or than `GH_LIMIT_MARKER_MAX_AGE`, blocks nothing | `marker_gate` / `marker_window` / `mark_marker_stale` |
| The failing **bucket** is named (`core` vs `graphql`) with its reset — never inferred from whichever counter looks healthy | `bucket_for` / `fail_loudly` |
| **≥ 1 s between mutative calls** (POST/PATCH/PUT/DELETE) | `pace_mutation` |
| Conditional REST for polling: ETag stored per URL (host + path + credential digest), `if-none-match` sent, a **304 replayed from cache** and charged nothing. The cached body is base64 (a 304 replay is byte-exact, binary included) and the cache is bounded in ENTRIES and BYTES (`GH_LIMIT_CACHE_MAX_ENTRIES` 500, `GH_LIMIT_CACHE_MAX_BYTES` 64 MiB) | `conditional_fetch` / `cache_put` / `prune_cache` |
| The shim stays FIRST on PATH even though every gh-calling harness script prepends `/opt/homebrew/bin:/usr/local/bin` | the `$O/gh-limit` / `$O/gh-rest` re-assert in the harness scripts that prepend and invoke `gh` |
| The heartbeat's tooling (`objective.py`, `merge-queue.py`, `beta-progress.py`, `ask-owner.py`, `turn-classify.py`, `turn-end.py`, `undelivered-answers.py`, `pr-doctor.py`) reaches the layer instead of a pinned real binary — **except `beta-progress.py`'s two PR-list REST reads, which go direct (see "A reader with its OWN REST second source" below and the matching residual)** | each resolver prefers `$O/gh-rest/gh` then `$O/gh-limit/gh` (`$O`-derived, never PATH); the five that HAVE a pinned candidate also hand it through as `GH_REST_REAL_GH`/`GH_LIMIT_REAL_GH` (see the residual below for the three that never pinned). Was nine/six until agent-infra#1874 retired `retired/queue-dispatch.py` — a retired tool is not in the beat, so it is not counted here |
### A reader with its OWN REST second source (#2139)

`beta-progress.py` (the heartbeat's DELIVERY line) reads both PR lists with `gh pr list --json`.
Where a box has the REST adapter (`$O/gh-rest`, #1959) the OPEN read is already served over REST —
`number,title,headRefName` are all in its `PR_FIELDS` — but **`mergedAt` is not**, so the MERGED
read delegates to the real `gh`, i.e. GraphQL. On the cells there is no `$O/gh-rest` (#1978), so
both reads are GraphQL. Under fleet concurrency a SECONDARY-limit refusal then took the line out
entirely (`DELIVERY: unavailable (metrics read failed)`) while `core` read 1599/5000 and a single
REST call answered in 0.43 s — the fleet lost its own progress measurement while a readable source
existed. That reader therefore keeps a REST fallback of its own (`_rest_prs`), and the rules it
follows are the reusable ones:

* **Same source or no metric.** If EITHER GraphQL list fails, BOTH are re-read over REST. A REST
  open-count beside a GraphQL merged-count compares two differently-wrong reads.
* **`limit` bounds ROWS READ, not rows returned.** The loop advances on the rows it FETCHED, so it
  spends the same row budget `gh pr list --limit` spent. In the closed window those rows are then
  filtered to merges, so the merged list holds the merges among the `limit` most-recently-updated
  **closed** PRs and is SHORTER than `limit` when some were closed without merging (measured:
  396/400). This is the bound, not a short read — and it is why the REST read is not
  interchangeable with `gh pr list --state merged --limit 400`. Filling the window with merges
  instead would cost an UNBOUNDED number of requests against the very bucket this fallback exists
  because we are rationing, so the row bound is the deliberate trade: `merged_today` stays exact
  while a day's merges (plus the abandoned rows updated beside them) fit inside it.
* **`state=closed` is not `state=merged`.** REST's closed window carries PRs closed WITHOUT
  merging; only rows with a non-null `merged_at` may count toward `merged_today`.
* **The window is paged, `per_page` never shrinks, and a window that MOVED is refused.** REST
  caps `per_page` at 100, so the
  500/400 windows are `ceil(limit/100)` requests. A page that cannot be read — or the pair
  spending its shared 30 s budget — refuses the WHOLE read instead of returning a short list: a
  silently short window under-counts `merged_today`, which is the one error a fallback must not
  add. `per_page` stays 100 on every page because GitHub derives a request's offset from THAT
  request's `per_page`, so a shrunk final page re-reads an earlier range and leaves a hole; the
  final page is trimmed after it arrives. `updated desc` is a LIVE order read by offset, so a PR
  updated between two requests jumps to offset 0 — INSIDE the page already read — and every row
  below it shifts down by one. One event, two symptoms: the row that sat at the END of the page
  just read is pushed across the boundary and returned a SECOND time, while the mover itself is
  behind the cursor and returned by NO page, so the just-merged PR is precisely what goes missing
  (measured with the shipped loop: #150 bumped after page 1 → `100` repeated, `150` never
  returned; end-to-end, one merge landing mid-read left `merged_today` at 0 where the truth was
  1). Keeping the window would hide the missing row, so a repeat — which can only arise from the
  list changing mid-read — abandons that ATTEMPT; the read is retried **once**, and a second
  repeat REFUSES the whole read (`None` → `unavailable`). The retry exists because on a box
  running ~17 concurrent `gh` clients most movers are churn that has settled by the time the page
  set is re-read, so without it the fallback would spend its requests and still lose the line. It
  is bounded and stated: at most ONE extra page-set (`ceil(limit/100)` requests), spent only on a
  path that was going to print `unavailable` anyway, out of the SAME shared 30 s budget — and a
  retry can never turn two DIFFERENT windows into a number, because a repeat on the second attempt
  refuses. A reorder that leaves
  the identity at every later offset unchanged — a same-second tie-break swap inside one page —
  produces no repeat and costs nothing; anything whose effect crosses a request boundary either
  repeats (an update) or is the removal case below.
  **The detector is one-way, and that is a stated residual:** a row that LEAVES the list mid-read
  (a PR reopened or deleted) shifts every later row UP, nothing repeats, and the row that should
  sit at each later offset is skipped — measured: 250 closed rows with #101 merged today, #5
  reopened after page 1 → the window came back with #101 ABSENT and `merged_today` 0 where the
  truth was 1. Offset paging cannot see that from the rows alone. The successor detector is the
  collection total from the `Link: rel="last"` header compared across the read (an insertion and
  a removal both change it; a pure update does not); it is NOT implemented, so a mid-read removal
  can leave this window short by one row per removal — rare (a reopen inside a ~2 s read), and the
  one path where the fallback under-counts instead of refusing. The window is the 400
  most-recently-updated **closed**
  PRs and unmerged rows are dropped after it is read, so today's updated closed PRs — not today's
  merges alone — must fit in 400 for `merged_today` to be exact. That is a stated bound, not a
  promise.
* **It goes direct (urllib + the token), NOT through the layer — a deliberate, costed trade-off.**
  The layer cannot serve `mergedAt` at all (a `PR_FIELDS` change is its own follow-up), and it does
  not help the cells, which have no adapter; a fallback that queues behind the refusing path is not
  a fallback. The cost is named in the residual below: no single-flight, no ETag/304 replay, and no
  entry in `last-limit`. The token is read from `GH_TOKEN`/`GITHUB_TOKEN`, else the `oauth_token`
  of the **`github.com:` block** in `${GH_CONFIG_DIR:-~/.config/gh}/hosts.yml` (a `hosts.yml` that
  lists another host first must not donate that host's token — it answers 401 against
  `api.github.com`; nor may a token nested under a per-account `users:` map, whose entries belong
  to other accounts and are skipped by depth. The block's own `oauth_token` is what gh itself
  uses — switching accounts moves the active user's token UP to block level — so a config with
  both a `users:` map and a block-level token still answers with the ACTIVE account. With no
  block-level token the fall-through splits in two, and the halves are NOT the same outcome: a
  KEYRING-BACKED config is answered the ACTIVE account by `gh auth token` (an OFFLINE lookup the
  layer does not count as a request), while a file whose tokens are ALL nested under `users:` is
  answered NOTHING (measured, gh 2.102.0: `no oauth token found for github.com`, empty stdout) —
  `_token()` then returns `""` and the read refuses `unavailable`, which is the correct outcome
  rather than a regression). The token is never logged — pinned
  at the finder as well as the transport, since a `print()` inside `_token()` is upstream of the
  value the rest of the file sees — and a box with no credential at all refuses (`unavailable`)
  rather than reading anonymously.

**Not covered by this fallback, stated rather than assumed:** the two `gh issue list` reads (the
P0/P1 tiers) are still GraphQL, so where the adapter is absent a refusal there still takes the
whole line out — after the PR lists were paid for. `merge-queue.py`'s own `--state merged` read is
the same class and is what prints `VERDICT=UNKNOWN (merge-rate read failed)`; #2139 names both as
residuals so the next lane does not read this section as covering them.

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
  as `gh=rate_limited(bucket=graphql reset=<epoch> until=<epoch> <age>)` for 15 minutes — or as
  `gh=recovered(bucket=… <age>)` once a later call succeeded, so a limit that has been read past is
  not asserted as a current one. `until=` is the window this box actually honours (the classification's
  window); `reset=` is the bucket's own reset and stays on the line because readers exist, but a
  secondary/unclassified refusal retries in ~60 s while its reset sits far outside that window — the
  derived figure lives in `docs/ops/cost-config-policy.md` §2, and is not restated here — so only
  `until=` answers "how long is this box blocked". The failure text says `rate limit`, because that is
  the phrase
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
- **Cross-box BURST is not serialised — it is PARTITIONED (#2137).** Boxes cannot see each other, so
  the invariant is still one call in flight *per box*; what bounds the ACCOUNT is a declared share:
  GitHub's primary limit is **per account** (a PAT, an OAuth app and a GitHub App acting for one user
  all draw on the same 5,000/hr bucket), so a per-box budget is ~N times the account's. The layer
  divides that budget by a **declared fleet size** (`GH_LIMIT_ACCOUNT_FLEET_SIZE`, default 4) with a
  safety fraction (`GH_LIMIT_ACCOUNT_SAFETY`, 0.8) and paces this box at that share per window
  (`GH_LIMIT_ACCOUNT_WINDOW_S`, 60 s) — 5000 × 0.8 / 4 / 60 ≈ **16 graphql calls/min** at the
  defaults, whose share is floored at 1 so a conservative setting cannot brick a box. No cross-box
  messaging is needed, which is the point: a partition is testable and does not depend on an
  unreachable peer. What is *still* not bounded: a box whose declaration is wrong (too small a fleet
  ⇒ too generous a share), and **`core`/REST is not paced by default** — the hot reads were
  deliberately moved onto REST (#1962/#2137), so pacing it here would push the fleet back onto the
  bucket that is refusing; opt in with `GH_LIMIT_ACCOUNT_PARTITION_BUCKETS=graphql,core`.
- **A bounded caller proceeds OVER the partition.** `GH_LIMIT_NO_WAIT` callers (the heartbeat's eight
  telemetry tools) cannot be paced without outliving their own subprocess bound, so they take the
  slot check and proceed when it is exhausted, recording the overdraw in `events.log`. Pacing them
  would turn a rate-limit verdict into the timeout that NO_WAIT exists to prevent. The same applies
  to a caller that waited one window and lost the retake to a peer: it sends and records the
  overdraw rather than waiting a second window (which would multiply the in-call bound by the
  attempt count) or falling through silently.
  A caller that *can* wait, and whose next slot is further away than `GH_LIMIT_MAX_WAIT`, is refused
  **locally** instead: the layer prints the share it enforced on stderr, records `last-budget`, sends
  nothing, and exits **75** (`EX_TEMPFAIL`) — the same "retry later" code the give-up path uses, so a
  caller reading only the exit code cannot mistake a partition refusal for a success.
- **A marker blocks only within the window its CLASSIFICATION justifies, and only after
  revalidation (#2137).** `last-limit` now carries `kind=`, `until=` and `remaining=` beside the
  fields it always had. The layer's own gate waits at most `until` — never the bucket `reset=` for an
  `unclassified`/`secondary` refusal, because GitHub documents (and the fleet measured) that the
  primary counter does not predict a secondary limit — never when the marker is older than the window
  it recorded or older than `GH_LIMIT_MARKER_MAX_AGE` (900 s), and never for a `NO_WAIT` caller or a
  request-free command. Before a wait longer than `GH_LIMIT_GATE_REVALIDATE_S` (30 s) it spends one
  exempt `GET /rate_limit`: a bucket reporting headroom marks the marker stale (`stale=`,
  `reval_remaining=`) and the call proceeds — deliberately **not** `recovered=`, because the cycle
  token prints that field as `gh=recovered(…)` and the only honest source of it is a real request that
  succeeded; the exempt endpoint is measured to report 4999/5000 while every call is refused. A marker
  whose window is further away than `GH_LIMIT_MAX_WAIT` is not slept-then-ignored either: the gate
  declines, and the refusal itself (which fails fast) is the cheaper evidence. The annotation is
  written **only onto the record the gate actually read** — identity is `at=`+`bucket=`+`kind=` —
  because `record_limit` writes `last-limit` outside the box lock (a refusal must not queue behind a
  sleeping gate), so a concurrent client can replace the file in between; a blind `stale=` would then
  clear a fresh genuine refusal's window, and since the gate suppresses on `stale=` permanently the
  drop would be silent (fail-open). A replaced record is left alone and the event log says so.
  Residual: a reader
  OUTSIDE this helper that still blocks on `reset=` will over-block — `until=` is the field to read,
  and `reset=` is the bucket's own reset, not a block window.
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
  bound is a per-CALL timeout in the 60-420 s range (or a `run_bounded` step of 20-180 s) that is
  consumed by the layer's first documented wait of 60 s, or shared with every other call the step
  makes — the outcome is a timeout, and the box then reports `UNKNOWN`/`STALL` instead of the
  `RATE-LIMITED` verdict it can prove. (One of the eight — `pr-doctor.py` — is
  launched detached by `heartbeat-loop.sh` and reaped by its own lock, so its bound is per call,
  not per pass; the decision is the same. It was nine while `retired/queue-dispatch.py` was still part
  of the beat — retired in agent-infra#1874, so it is no longer a resolver here.) The shell call sites
  keep the waits: they have no
  subprocess bound of their own.
- **`beta-progress.py`'s REST fallback is OUTSIDE the layer (#2139).** Its two `/pulls`
  reads use urllib + the token directly, so they are not serialised by the box's single-flight
  lock, get no ETag/304 replay, and are invisible to `$GH_LIMIT_DIR/last-limit`. Deliberate: the
  adapter cannot serve `mergedAt` (`PR_FIELDS` omits it, so the merged read delegates to
  GraphQL), and the cells have no adapter at all. The read is bounded (shared 30 s budget, paged,
  refusing rather than truncating) and it runs only after a GraphQL read already failed.
  Follow-up (#2143): model `mergedAt` in `PR_FIELDS` **and map `--state merged` to `state=closed`
  plus a non-null-`merged_at` filter** — the adapter forwards the state verbatim and REST has no
  `merged` state, so sending it as-is is a 4xx, not a list. That fixes `merge-queue.py`'s
  merge-rate read too.
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
in-flight request — `#2243`), `last-mutation`, `last-limit`, `last-budget`, `events.log`, and one
`budget-<bucket>` sliding window per partitioned bucket (newline-separated send timestamps, bounded
by the share; a stamp from the FUTURE is dropped, because a clock that stepped back is not permission
to refuse every call) plus `budget-<bucket>.over`, the window in which the over-share line was last
written — the overdraw is recorded ONCE per window per bucket rather than once per call, because a
~500-call NO_WAIT refresh against a 16-call share would otherwise fill `events.log` with its own
overdraw and evict every refusal and probe decision (that flood is a record-eating defect, not noise).
`last-budget` is written **only** by a LOCAL partition refusal and never into
`last-limit`: the heartbeat prints `last-limit` as `gh=rate_limited(…)`, and publishing our own
budget decision as GitHub's limit is the false attribution the local-refusal rule forbids.

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
`GH_LIMIT_ACCOUNT_FLEET_SIZE` (4 — the DECLARED number of boxes spending one account budget),
`GH_LIMIT_ACCOUNT_BUDGET_PER_HOUR` (5000 — GitHub's per-account, per-bucket primary limit),
`GH_LIMIT_ACCOUNT_SAFETY` (0.8 — headroom kept inside the share),
`GH_LIMIT_ACCOUNT_WINDOW_S` (60 s — the window the share is spent over),
`GH_LIMIT_ACCOUNT_PARTITION_BUCKETS` (`graphql` — which buckets are paced; `graphql,core` opts REST in),
`GH_LIMIT_MARKER_MAX_AGE` (900 s — a marker older than this is not evidence about now) and
`GH_LIMIT_GATE_REVALIDATE_S` (30 s — the wait above which a marker is revalidated before it is paid).
The conditional-GET PASS CACHE has its own three: `GH_LIMIT_PASS_CACHE` (unset/`0` disables it; any
other value enables it — `refresh-candidates.sh` sets it for the sweep), `GH_LIMIT_PASS_CACHE_MAX_ENTRY`
(4 MiB — the largest single `--include` response it will keep) and `GH_LIMIT_PASS_CACHE_MAX_BYTES`
(64 MiB — the whole cache's budget); an entry over either bound is simply not cached.
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
