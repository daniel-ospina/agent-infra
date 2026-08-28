---
title: "Solution Diverge: #341 — token-cost driver (misconfigured cost engine + invisible feedback loop)"
type: engineering
domain: operations
doc_status: draft
subjects.team: organisation-design-team
created: 2026-08-28
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-341, issue-scoping, session-postmortem, pi-config
---

# Solution Diverge: #341 — token-cost driver

Phase: **solution-diverge** (no winner selection — converge phase picks). Input: confirmed problem from the #341 scoping session. Output: 3 distinct approaches varying across (1) **where the lever lives**, (2) **how feedback closes**, (3) **deliverable boundary**.

## Confirmed problem (summary)

- (a) Pi compaction fires only at the window ceiling (~983,616 = 1M − 16,384). Ceiling compactions destroy the cache prefix (cacheRead≈0, 629–821K fresh input) → ~50x cold re-ingestion. Measured: 9 low-threshold compactions ≈ $0.16 vs 7 ceiling ≈ $0.70.
- (b) The '184K shipped' claim is falsified: no override live or in-repo (deepseek cw=1M). The ~200K threshold was transiently active Aug 25→26 08:13, then reverted by a settings write — proving the feedback loop's absence.
- (c) `scripts/session-postmortem.sh` (PR #335) is wired nowhere AND underreports peaks (skips `type:compaction` records where true 984–996K peaks live).
- (d) Unmeasured multipliers: retry.maxRetries=10000, 100–1,142 friction events/session, fleet costs invisible (kimi-k3 21x flash, v4-pro 3x), defaultThinkingLevel=high, verification-gate/read results 6–45KB p95 (tail ~51–64KB).

Driver: context bloat is cheap when cached (cache-read ≈85–87% of spend); the driver is **cache-miss volume** (cold compaction, TTL resumes, fleet cold starts) + **output-token amplification** across ~27K calls.

Deferred (needs 4 weeks of cadence data): lifecycle-contract discipline levers — pre-committed escalation: output+reasoning share >20–25% → behavioral scoping first.

Out of scope: context-rot quality risk, fleet-wide attribution, per-skill call reduction, new enforcement machinery needing human approval, AGENTS.md throughput-rule changes.

## Ecosystem facts the approaches rely on

- Pi config: `~/.pi/agent/settings.json` (compaction.enabled/reserveTokens/keepRecentTokens; retry; defaultThinkingLevel) + per-model `contextWindow` in models.json; trigger = contextWindow − reserveTokens; lowering contextWindow clamps max generation (contextWindow − context − 4096).
- Cache pricing: flash $0.14/$0.0028 (50x), pro $0.435/$0.003625 (120x), kimi $3/$0.3 (10x). defaultModel = deepseek-v4-flash.
- Existence proof: the Aug 25→26 transient 200K threshold ran 9 compactions at ~196K with cacheRead per call ~200K vs ~1M — sessions stayed lean until a settings write silently reverted it.
- Extension event surface (proven by task-heartbeat/health-check): `session_start`, `session_shutdown`, `turn_start`, `turn_end`; `session_before_compact` exists (custom summarization) — payload (whether it carries tokensBefore/usage) **unverified, must spike-test**. shared/audit-log.ts gives durable JSONL append. The #153 hang-on-exit class constrains session_shutdown hooks.
- Propagation: sync.sh → pi-bootstrap/setup.sh refreshes live config; check-pi-config-extensions.sh pattern exists for config guards; install-launchd.sh + cron-quality-gates.sh are the cadence precedents.

---

## Approach A — "Config Clamp": durable 200K ceiling + engine hygiene (config-only, near-zero new code)

**Description.** Make the transient Aug 25→26 200K threshold permanent, durable, and drift-proof. Lower `contextWindow` 1M → 200K for all deepseek models (flash, pro, and the token-plan aliases) in the shipped models.json; add the `compaction` block to the shipped settings.json (mirror live: reserveTokens 16384, keepRecentTokens 20000); tighten `retry.maxRetries` 10000 → 5 (industry 4–5 + circuit breaker); consider `defaultThinkingLevel` high → low for flash. The single new piece of code is a **drift guard**: a check script asserting the shipped default models stay ≤200K and retry is capped, wired into pre-commit/CI — so the Aug 26 class of regression (a settings write reverting the threshold) fails the gate instead of silently reverting. Everything propagates through the existing sync.sh → setup.sh path.

**Files/mechanisms touched.**
- `pi-bootstrap/pi-config/models.json` — contextWindow 1000000 → 200000 for deepseek-v4-flash, deepseek-v4-pro, deepseek-v4-flash-0731 (miss one alias and a 1M backdoor remains)
- `pi-bootstrap/pi-config/settings.json` — add compaction block; retry.maxRetries 10000 → 5
- `scripts/check-cost-config.sh` (new, ~40 lines) or extend `scripts/check-pi-config-extensions.sh` — CI/pre-commit drift guard; optional live-state check of `~/.pi/agent/models.json` in sync.sh
- `docs/ops/cost-config-policy.md` — one-page rationale + documented override path (escape hatch must be visible, not silent)
- Live `~/.pi/agent/models.json` + `settings.json` — refreshed via setup.sh on next sync

**Architecture.** Config-tree-as-source-of-truth → sync.sh propagates → pi reads at session start. One-way flow; no runtime code, no new hooks. The entire evidence base is the Aug 25→26 existence proof (9 compactions ~196K, cacheRead per call ~200K vs ~1M). Compaction now fires at ~183K; cache prefix stays tiny; cache-read share remains ~85–87% of spend.

**Risks.**
- **Generation clamp.** max generation = contextWindow − context − 4096. At ~190K context in a 200K window, only ~5.7K generation budget → mid-turn truncation risk in long-read sessions (read/verification-gate results 6–45KB p95). Needs keepRecentTokens/reserveTokens tuning so compaction fires ~180–185K with headroom; behavior regression risk must be watched in the first week.
- **Silent local override.** A fleet member with a hand-edited local models.json keeps 1M; the guard checks the repo tree, not live state (unless the live-state check is added). The 08-25 incident was exactly a live-state revert.
- **No measurement.** Deliberately ships without telemetry: win size unverified, output/reasoning amplification invisible, retry storms invisible. The blindness class that caused the drift is only partially mitigated (guard replaces feedback).
- **Alias coverage.** Token-plan model entries in models.json/models-store.json must get the same edit or remain a 1M backdoor.

**Tradeoffs.** Cheapest possible: number edits + one guard script; reversible in minutes; effect instant on next session. Zero runtime behavior beyond the clamp. But it buys the ~50x cache-miss win without knowing it landed, and leaves the (d) multipliers (retry storms, thinking level, fleet cost) untouched except where the same settings edits touch them.

**Best-fit-if.** The team wants the dominant win (cache-miss elimination) immediately with near-zero engineering and no extension approvals; accepts measurement debt and a CI-only drift guard; the 4-week deferred decision starts collecting data from the 200K baseline (A is the natural baseline config for either B or C).

---

## Approach B — "Visible Fleet": fixed metrics + weekly cadence + escalation report (tooling + telemetry)

**Description.** Fix the broken measurement loop end-to-end. Repair `session-postmortem.sh`: include `type:compaction` records (true 984–996K peaks), add per-provider price-awareness from models.json rates (so kimi/pro fleet cost is at least estimated, not just flash), add cache-read share, cold-input volume, output+reasoning share, and retry-storm counts. Regenerate the 9 retrospectives. Wire a weekly cadence (launchd plist via install-launchd.sh, or a cron-quality-gates-style subcommand) that runs a new fleet aggregator: roll all sessions in the window into a cost report with **escalation thresholds** — ceiling-compaction count > 0, cache-read share < 80%, output+reasoning share > 20–25% (the pre-committed escalation from the confirmed problem) — posted to docs/ops and optionally routed to slack-bridge. Measurement only: it makes the 4-week lifecycle-contract decision data-backed without changing session behavior.

**Files/mechanisms touched.**
- `scripts/session-postmortem.sh` — metric fix (compaction records, price-awareness, shares, retry counts); optional `--json` mode for programmatic consumption
- `scripts/fleet-cost-report.sh` (new) — weekly aggregation → markdown report + threshold escalation
- `scripts/install-launchd.sh` — weekly plist (precedent exists) or `scripts/cron-quality-gates.sh` new subcommand
- `docs/retrospectives/` — regenerated 9 retros + weekly reports (a metrics changelog note must explain why peaks jump from 30K–801K to 984–996K, or the regen reads as a regression)
- `docs/ops/cost-dashboard.md` — living report index, thresholds, trend line
- `extensions/slack-bridge` — escalation routing (optional wiring)

**Architecture.** Session JSONL (source of truth) → fixed per-session postmortem → weekly fleet aggregator → report + escalation. Feedback closes on a **schedule** (≤1-week lag), never mid-session. Local parse of a 27K-call session is seconds — no infra. Attribution honesty: parent-JSONL remains the lower bound; fleet costs are estimates.

**Risks.**
- **Cadence gap.** A bad week is discovered post-hoc — bounded to ≤1 week, but the "drifted back unnoticed" class can still recur inside the window.
- **Silent parser breakage.** JSONL schema drift kills the aggregator quietly — needs a parser test and loud-failure mode (the load-gate/cron-quality-gates precedent).
- **Warn-only ceiling.** The report flags; someone must act. If nobody reads it, the loop is still open — escalation without enforcement is a hope, not a control.
- **Attribution mislead.** Fleet costs are estimates with a known lower bound; the report must state the bound or it overstates confidence.
- **Numbers-shift optics.** Regenerated retros jump from 30K–801K to 984–996K peaks — looks like a regression without a changelog explaining the metric fix.

**Tradeoffs.** Medium effort (2 scripts + cadence + regen); zero runtime behavior change — pure measurement. Fixes PR #335's orphaned tooling and its underreporting bug. Produces exactly the 4-week dataset the deferred contract decision needs, with the pre-committed escalation threshold instrumented.

**Best-fit-if.** The decision can wait 4 weeks for data; the team wants cost visibility before any behavior change; a human will actually read the weekly report; fixing broken tooling (PR #335) is itself a deliverable. B is orthogonal to A and C — it can be bolted onto either as the measurement layer.

---

## Approach C — "Live Guard": session-boundary hooks + compaction alarm + read-bounding (runtime/enforcement)

**Description.** Close the loop at session boundaries with a new extension, and bound the worst amplifiers at runtime. New `extensions/cost-guard`:
1. **`session_before_compact` hook** — log tokensBefore vs threshold; when a compaction would destroy a large cache prefix (tokensBefore > ~250K), emit a pre-compaction alarm (console + shared/audit-log + slack-bridge). This is the exact blind spot that let Aug 26 drift unnoticed — now visible in real time.
2. **`session_shutdown` hook** — auto-run the fixed session-postmortem and append to a durable fleet-cost JSONL (reuse shared/audit-log append), closing the loop **per-session** (lag ≈ session length, not a week). Must respect the #153 hang-on-exit class — never hold the event loop (task-heartbeat comments document the discipline).
3. **`turn_end` budget alarm** — rolling-window checks: output+reasoning share, cache-read share, retry-storm count (retry events). Warnings at thresholds instrument the pre-committed escalation contract.
4. **Read-bounding** — cap verification-gate/read tool results at a configurable limit via the tool-interceptor pattern (vision-interceptor / builtin-tools precedent), with a whitelist escape hatch for skills needing full reads and a loud truncation marker.
Plus Approach A's config clamp as the **baseline** (200K ceiling + retry 5) — runtime hooks alone don't fix the misconfigured engine.

**Files/mechanisms touched.**
- `extensions/cost-guard/index.ts` (new) — event hooks + alarms + read cap
- `extensions/shared/audit-log.ts` — reuse for the fleet ledger
- `pi-bootstrap/pi-config/settings.json` — costGuard thresholds (alarmLimit, readCap, share thresholds)
- `scripts/session-postmortem.sh` — metric fix + JSON/exit-code mode for programmatic invocation at session end
- `extensions/slack-bridge` — alarm routing
- `sync.sh` / setup.sh — extension + config propagation

**Architecture.** Live extension inside the pi process → event hooks (`session_before_compact`, `session_shutdown`, `turn_end`) → per-session ledger + alarms; read-bounding interceptor in the tool path. Three feedback loops at different latencies: instant (alarm before cache destruction), per-session (auto postmortem), and optionally the weekly report from B as the durable record.

**Risks.**
- **Event-surface uncertainty.** `session_before_compact` exists for custom summarization, but its payload (does it carry tokensBefore/usage?) is unverified — must spike-test before committing. The out-of-scope note ("pi exposes no mid-session signals") means this works within the events pi DOES emit (session_shutdown/turn_end proven by task-heartbeat) and stays **advisory — alarms, not blocks** (enforcement-mode changes need human approval).
- **Extension maintenance burden** + the #153 hang-on-exit class on session_shutdown hooks.
- **Read-bounding behavior change.** A skill legitimately needing a 60KB read (big configs, check-skill-lint) could silently degrade — needs whitelist + loud truncation marker.
- **Alarm fatigue.** Thresholds too tight → noise, alarms ignored; too loose → same blindness as today.
- **Can't stop an in-flight compaction.** The alarm only precedes it; preventing the spend requires the config clamp (why A is the baseline, not optional).

**Tradeoffs.** Highest effort (new extension + interceptor + config), most behavior change — but closes the loop at the moment it matters and instruments the escalation contract so the 4-week deferred decision has enforcement-ready machinery. Complements A (clamp without alarm drifts silently; alarm without clamp still spends on cold compactions) and feeds B's report.

**Best-fit-if.** The team wants the feedback loop closed per-session, has extension-maintenance appetite, accepts advisory (non-blocking) runtime signals, and the read-bounding of 6–45KB tool results is acceptable with escape hatches.

---

## Dimension coverage

| | A — Config Clamp | B — Visible Fleet | C — Live Guard |
|---|---|---|---|
| **Lever lives in** | config tree (models.json/settings.json) + CI guard | tooling + telemetry (scripts, cadence, report) | runtime extension + tool interceptor + config baseline |
| **Feedback closes via** | commit-time guard (drift = build failure) | weekly cron/launchd report + escalation | live extension: session_before_compact alarm, session_shutdown auto-postmortem, turn_end alarms (per-session) |
| **Deliverable boundary** | config + drift guard only | config-agnostic measurement + cadence + escalation report | config + measurement + read-bounding + escalation contract instrumented (advisory) |
| **New code** | ~1 guard script | 2 scripts + cadence wiring | 1 extension + interceptor + config |
| **Lag to detection** | next commit that violates the guard | ≤1 week | ≈ session length |
| **Cache-miss win** | immediate (~50x on cold compactions) | none (measures only) | immediate via A baseline + alarms |

## Shared baseline note

A's config clamp is not optional for C and is the natural baseline for B's data collection. The three approaches are not mutually exclusive — they are a dimensionally-ordered spectrum (config → measurement → runtime hook), and the converge phase may combine elements (e.g., B's report fed by C's ledger). What differs is scope, effort, and where the feedback loop closes.

## Open questions for converge (not resolved here)

1. Does `session_before_compact` carry tokensBefore/usage data? (spike-test decides C's alarm feasibility)
2. Is the 200K generation clamp acceptable behaviorally in read-heavy sessions? (A's main risk — needs a 1-week pilot)
3. Who owns reading the weekly escalation report? (B dies without an owner)
