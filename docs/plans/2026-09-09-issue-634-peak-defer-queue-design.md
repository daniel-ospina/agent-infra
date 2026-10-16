---
title: "Design: #634 — peak-window defer queue (DeepSeek 2x windows)"
type: design
domain: operations
doc_status: superseded
subjects.team: organisation-design-team
created: 2026-09-09
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-634, deepseek, fleet-cost, peak-window
---

# Design: #634 — peak-window defer queue

> **⚠️ SUPERSEDED (2026-09-11) — HISTORICAL, DO NOT IMPLEMENT.**
> #634 was reframed to **Option A (instrument-first)**: the scoping diamond
> measured a ~$1–4/mo prize and found the risky half could be net-negative, so
> only the measurement ships. The current plan is
> **`docs/plans/2026-09-11-issue-634-peak-window-option-a.md`**. The mid-flight
> pause described below is **#782**; the launch gate and batch path are
> **#795**. Kept for the reasoning trail.

> Source: brainstorming (2026-09-09) + external validation research
> (`docs/research/2026-09-09-deepseek-peak-hour-pricing.md`). Issue: #634.
> Branch: `feat/634-peak-defer-queue` (worktree `.worktrees/feat-634-peak-defer-queue`).

## 1. Problem

DeepSeek bills **2× during peak hours** — `01:00–04:00` and `06:00–10:00` UTC, Mon–Fri
(Beijing business hours). At UTC−5 that is **Sun–Thu 8–11 PM** and **Mon–Fri 1–5 AM
local** — exactly the "launch an overnight batch and walk away" window. Long-running
autonomous jobs cross both windows and pay 2× across the whole crossing. The user's
request: launch at e.g. 19:50, have the work **park until 23:00**, auto-resume, show a
visible pause notice, and allow an **urgent opt-out**.

## 2. External validation (is this state of the art?)

| Finding | Source class | Verdict |
|---|---|---|
| Tag calls `deferrable`; use a **queue rather than cron**; add a **deadline escape**; alert on peak spend; keep scheduling in **UTC**; batch to weekends | practitioner guides on off-peak API pricing | **Design confirmed** — matches D1–D4 almost line-for-line |
| Split workloads **Immediate vs Deferred**; async queueing layer for deferred; monitor/report savings | DeepSeek pricing analysis | confirmed |
| Carbon-aware scheduling: **temporal shifting** of deferrable jobs; **configurable max-delay** for semi-critical work; weekend shifting ≈20% savings ("Let's wait a while") | mature research field (K8s schedulers) | closest mature analog; our "urgent opt-out" = their max-delay escape |
| Prefix-cache reuse vs eviction under memory pressure; prefix-aware scheduling | LLM serving literature | confirms the **cache-eviction trap** — mid-flight pause must be cache-aware |
| No off-the-shelf **turn-level** agent pause for cost windows (existing schedulers are job-level) | absence of evidence across searches | **mid-flight pause is novel** → higher risk → ship behind the dispatch gate (PR-B) |

**Conclusion:** the design is sound and matches state of the art; the dispatch gate is
standard practice, the mid-flight pause is a novel extension requiring the cache-aware
guardrails below.

## 3. Architecture

```
        ┌──────────────────────── shared/peak-window.ts (pure) ───────────────────────┐
        │ isPeak(t) · nextOffPeak(t) · nextPeak(t) · remainingPeakMs(t) · plan(t)     │
        │ injectable clock · UTC-authoritative · DST-safe local display · CLI         │
        └───────────────┬─────────────────────────────────────┬───────────────────────┘
                        │                                     │
      (A) dispatch gate │                     (B) mid-flight pause
   extensions/builtin-tools task tool      extensions/peak-gate before_provider_request
   deferrable → park until off-peak        session reaches boundary → await until off-peak
   no provider request, no cache risk      emits [PEAK-PAUSE] marker (watchdog-safe)
                        │                                     │
                        └──────────────► events ◄─────────────┘
                                 pause/resume + avoided-premium
                                            │
                                 scripts/fleet-cost-report.sh (#631)
```

**Policy (config, `settings.json` → `peakQueue`):** `enabled`, `windows` (UTC),
`deferrable` (default headless/batch), `minPauseMin` (default 15), `cacheAware` (default
on), `urgentOverride` (`PEAK_FORCE=1`), `notify` (banner|log).

**Data flow:** a deferrable dispatch or turn checks `plan(now)` → if `park`, print the
banner and wait until `nextOffPeak`; on resume, emit a resume event with duration and the
estimated premium avoided (`tokens × (peak−offpeak) rate`, from session usage). Interactive
sessions bypass the gate entirely.

## 4. Decisions (user-approved 2026-09-09)

| # | Decision | Choice |
|---|---|---|
| D1 | Deferrable by default | headless/`pi -p`/cron/launchd/epic-executor = deferrable; interactive = never paused; explicit overrides both ways |
| D2 | Mid-flight policy | pause at **both** windows, `minPauseMin` flap guard, cache-aware skip |
| D3 | Urgent opt-out | `PEAK_FORCE=1` at launch + `/peak force` in-session (one step) |
| D4 | Notification | terminal banner + log line (Slack optional, off by default) |

**Derived (design decisions, >80% confidence, noted not gated):** UTC-authoritative
windows; `load-gate.mjs`-shaped CLI contract (exit 0 proceed / 3 deferred / `--force`);
pre-dispatch deferral always preferred over mid-flight pause; events feed the weekly cost
report; PR-A/PR-B phasing per #341 precedent.

## 5. Cache-aware guardrail (the trap this design must avoid)

DeepSeek prefix cache is best-effort, cleared *"usually within a few hours to a few days."*
Cache-hit input ≈ 1/30th of miss; a resume cache-miss on a 383K clamped prefix ≈ **$0.08
one-time**, while the peak premium is ≈ **$0.01/turn**. Therefore mid-flight pause is
**only net-positive for jobs that would otherwise grind through many turns of peak**.

Rule: pause mid-flight only if `remainingPeakMs ≥ minPauseMin` **and**
`estimatedPeakPremium(turns × tokens) > cacheEvictionPenalty(prefixTokens)`; otherwise keep
running (and log the skip). Dispatch-time deferral has no cache to lose and is always
preferred. Defaults are tunable from real session data (open item 1).

## 6. Error handling & edge cases

- **Watchdog:** a paused session looks like a stall → `[PEAK-PAUSE until=<ISO>]` marker +
  parent-side bound extension keyed on intentional pause (must not defeat #279's real-stall
  detection). Failure mode: a pause must never be silently converted into a cut.
- **Crash/restart while paused:** pause is a wait loop, not a daemon → a killed session
  loses the wait; on resume the gate re-evaluates `now` and re-parks if still peak
  (idempotent, no persisted queue needed).
- **Clock/DST:** windows defined in UTC; local display via tz-aware formatting; tests pin a
  DST transition.
- **Flapping:** `minPauseMin` prevents a pause when the boundary is seconds away; resume
  never fires early.
- **Opt-out precedence:** `PEAK_FORCE=1` > per-dispatch `--urgent` > session `/peak force`
  > default. Every bypass is logged with the actor and an estimated cost delta.
- **Non-deferrable safety:** interactive sessions and non-DeepSeek providers are untouched.

## 7. Testing strategy

- **Unit (fake clock):** window membership, next-boundary, DST, Mon–Fri UTC boundary,
  `minPauseMin`, cache-aware skip threshold.
- **Integration:** deferrable dispatch sends 0 provider requests in-window; auto-resume at
  boundary; `PEAK_FORCE=1` bypass; interactive unaffected; paused session not cut by the
  watchdog; `[PEAK-PAUSE]` marker present.
- **Contract:** `fleet-cost-report.sh` reports peak-window spend share + avoided premium.
- **Config:** drift guard covers the `peakQueue` block.

## 8. Phasing

- **PR-A (this issue's first deliverable):** `shared/peak-window` + dispatch gate + banner /
  opt-out + observability + tests + `docs/ops/peak-queue-policy.md`.
- **PR-B:** mid-flight pause (`before_provider_request`) + watchdog coordination —
  the novel/risky half; gated on PR-A's window engine and cache-aware policy.

## 9. Open items (Scope stage)

1. Cache-aware thresholds from real session usage (tokens, cache-hit ratio, turns/window).
2. Deferrable classification surface + precedence (`PEAK_DEFERRABLE` vs headless auto-detect).
3. Watchdog coordination contract (marker + bound extension vs heartbeat).
4. Dispatch-gate placement + exit-code contract (`task` preflight vs `scripts/peak-gate.mjs`).
5. Observability schema + avoided-premium estimate feeding `fleet-cost-report.sh` / #631.

## 10. Risks

| Risk | Mitigation |
|---|---|
| Pause evicts cache → costs more than peak | cache-aware skip + dispatch-first + min-pause |
| Watchdog cuts paused session | explicit marker + bound extension + integration test |
| Flapping at boundaries | `minPauseMin` + no early resume |
| Over-deferral delays urgent work | one-step opt-out, logged |
| Config drift | guard + weekly report |
