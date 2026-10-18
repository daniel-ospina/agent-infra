# GitHub API rate limits — detection & fallback runbook

## The harness's guard: `gh-serial` (#1988)

Every `gh` call the harness makes is meant to go through ONE explicit layer,
`scripts/orchestrator-harness/gh-serial/` (`ghs_run` / `ghs_mut` / `ghs_rest` from `lib.sh`). It is
**not** a PATH shim: `gh` is never substituted; the call sites name the layer, so an unwrapped call
is visible as a bare `gh`. (That is a deliberate departure from #1988's original shim plan — recorded
with an `OVERRIDES:` line on the issue. Do not convert it back.)

**Coverage, stated rather than implied.** Wired: `refresh-candidates.sh` (the queue + both listings)
and `orch-loop.sh` (the open-PR count, `pr ready`, both merges). NOT yet wired: `merge-one.sh`,
`fix-one.sh`, `lane.sh`, `chain-merge.sh`, and `orch-loop.sh`'s per-PR `gh pr view` / `gh pr checks` /
`gh run rerun` reads — those still call a bare `gh` and still fail silently when limited. Do not read
"the harness's guard" as "every gh call is guarded".
**The layer must be SHIPPED, or the wiring becomes a 127.** `install.sh` seeds it and **dies** on an
incomplete shipped set (a warning would finish with exit 0 and an `$O` whose every wired call exits 127
— blind, and reporting RUNNING); `cloud-cell-supervisor.sh`'s `seed_and_stamp` and `deploy-crossbox.sh`
seed it into a cell, and `check` refuses a cell whose `$O` lacks it.

| What it does | Why |
|---|---|
| one `gh` in flight per box (`flock`) | the SECONDARY limit is triggered by CONCURRENCY: measured 2026-10-18 with `core` 2948/5000 and `graphql` 4605/5000 free, every GraphQL call still refused with *“API rate limit already exceeded”* |
| `retry-after` → bucket reset → ≥ 60 s doubling | GitHub's documented order; a longer *sleep* between unrelated calls is not the fix — a **queue** is |
| ≤ 4 attempts, `GHS_MAX_WAIT` per call, then exit **75** + `RATE_LIMITED bucket=…` | a bounded end. Continuing to hammer while limited *“may result in the banning of your integration”* |
| `GHS_CALL_TIMEOUT` (120 s) on the child; `GHS_LOCK_TIMEOUT` on the flock | a gh that never returns must not hold the box-wide lock forever (one stuck socket would make the whole box gh-blind); both are named, non-zero, and recorded under their OWN names — never as a rate limit |
| ≥ 1 s between mutating calls | GitHub's stated guidance for `POST`/`PATCH`/`PUT`/`DELETE` |
| `ghs_rest` sends `if-none-match`; a 304 replays the cached body | a 304 costs **no** primary quota (GraphQL has no ETag, so every GraphQL poll is charged) |

The distinction the layer exists to preserve: a refused read is **unreadable**, not **empty**. Before
it, a limit surfaced as `[scope] open=UNKNOWN rc=1` and `queue=UNREADABLE` — a fleet that looks idle
rather than blind. Now the caller sees exit 75 and a named bucket (through its captured stderr:
`.open-err`, `.pool-err`, the merge log), and the durable record is `$GHS_STATE_DIR/last-limit`,
printed **with its age** by `gh-serial state` so a past limit cannot be read as a current one. That
command prints **every** record present (`last-limit`, `last-lock-timeout`, `last-call-timeout`), each
with its own age — printing only the first let a months-old rate limit mask the wedged lock that is
the current reason a cycle is blind.

```bash
# state dir (per box): the lock, the mutative clock, the ETag cache, the last limit
#   ${XDG_CACHE_HOME:-~/.cache}/pi-gh-serial
"${O:-$HOME/orchestrator}/gh-serial/gh-serial" version   # the layer is seeded BESIDE $O, never on PATH
"${O:-$HOME/orchestrator}/gh-serial/gh-serial" state     # last limit/lock/call-timeout WITH AGE
bash scripts/orchestrator-harness/gh-serial.test.sh       # offline contract test (59 checks)
```

Knobs: `GHS_MAX_ATTEMPTS` (4), `GHS_BASE_WAIT` (60), `GHS_MAX_WAIT` (300), `GHS_MUTATIVE_SPACING` (1),
`GHS_LOCK_TIMEOUT` (300), `GHS_CALL_TIMEOUT` (120), `GHS_JITTER` (0.2), `GHS_STATE_DIR`, `GHS_GH`
(pin the real binary).

## Two limits, different behaviour

| Limit | Scope | Symptom |
|---|---|---|
| **Primary** | 5000 req/h (REST + GraphQL separate pools) | `rate limit exceeded`, `gh api rate_limit` shows `remaining: 0` |
| **Secondary** | abuse detection (burst writes) | `API rate limit already exceeded for user ID ...` even with remaining quota — common after bulk issue closes/creates |

## Detect

```bash
gh api rate_limit --jq '.resources | {core: .core, graphql: .graphql}'
```

- `graphql.remaining: 0` → GraphQL pool exhausted; REST (`core`) is usually still fine.
- Secondary limits: transient (typically 1–5 min); sleeping does not always clear them
  for writes — switch transport instead.

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
