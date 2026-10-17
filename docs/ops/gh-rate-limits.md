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
`scripts/queue-dispatch.py` does that deliberately for read-only queries. When you add such
a caller, you are adding an unpaced `gh` — say so in the comment, as that file does.

## Detect

```bash
# Primary budget only. A healthy reading does NOT mean the account is usable.
gh api rate_limit --jq '.resources | {core: .core, graphql: .graphql}'

# What the fleet is actually doing (the gate's own signal):
ls ~/.pi/agent/gh-gate/slots | wc -l          # in flight right now
ls ~/.pi/agent/gh-gate/cooldown.* 2>/dev/null  # an active refusal window
```

- `graphql.remaining: 0` → GraphQL **primary** pool exhausted; REST (`core`) is usually still fine.
- `429`, or `403` whose text names a rate limit / abuse detection → secondary. Wait: the shim
  already does. **Do not retry immediately, and do not retry in a loop** — that is what turns
  one refusal into a fleet-wide outage.
- A bare `403` with a permissions message is NOT a rate limit; the shim does not retry it (a
  mutating command must not run twice).

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
