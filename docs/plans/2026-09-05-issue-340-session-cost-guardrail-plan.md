---
title: "Plan: #340 session-cost guardrail — daily cost-delta tripwire (research → plan, NO implementation)"
type: engineering
domain: operations
doc_status: plan (research complete — implementation deferred; #340 says file the plan after research)
subjects.team: organisation-design-team
created: 2026-09-06
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-340, session-cost-guardrail, fleet-cost-report, session-postmortem, cost-config-policy
---

<!-- research-path: this doc is the #340 research deliverable. Constraints honored: research + doc-writing only, no code/commit/push/git ops. Sources read: issue #340 body+comment, scripts/session-postmortem.sh, scripts/fleet-cost-report.sh, scripts/fleet-cost-weekly.sh, scripts/watch-truncation.sh, scripts/install-launchd.sh, docs/ops/cost-config-policy.md, docs/plans/2026-08-28-issue-341-session-lifecycle.md, docs/scoping/2026-08-28-issue-341-token-cost-driver-solution-diverge.md, issues #365/#373, tortoise retro corpus (commit b3306e61), 276 real session JSONLs, pi extensions.md (hook semantics), tortoise hosted_api.py SessionRequest, tortoise website dashboard capture contract. -->

# Issue #340 — Session token spend guardrail: daily cost-delta tripwire

> **For Pi:** do NOT implement from this doc yet. #340's mandate is research → plan only. An implementing session files its own O/I/T + issue-scoping (see §6 wiring table). This doc is the plan an implementer executes after issue-creation/scope gates.

**Goal (the gap):** $44/15d (Aug 13–19) was discovered post-hoc because *nothing* reads pi's per-call `cost` field on a cadence faster than the #373 **weekly** report. #340 = the **daily, dollar-denominated** tripwire that catches a spend spike on day 1 — a different detector class than #373's clamp-regime *structural* legs (ceiling-compaction count, cache-share floor over compacting sessions), which only escalate weekly.

**What #373 (PR #491, merged) already covers — do NOT rebuild:**
- The **shared parser** (`session-postmortem.sh --summary`) — per-session aggregation incl. `msg_cost_total`/`msg_cost_cache`/`comp_cost_total`, ceiling classification, `reread_volume`, `genuine_len_stops`. ONE parser for retro/report/watch (parser-sharing contract).
- **Escalation machinery** (`fleet-cost-weekly.sh`): dedup GitHub issue (one OPEN `"fleet-cost" in:title` → comment, else create), launchd farmed copies under `~/.pi/agent/scripts/` (TCC-safe), `cron-quality-gates.sh fleet` repo entry.
- **Structural thresholds** `fleet-cost-report.sh`: (a) ceiling-compaction ≥900K → escalate; (b) cache-share < 0.65 over clamp-regime compacting sessions → escalate; (c) output+reasoning share (#365 trend, never escalates). Weekly cadence, Sunday 06:30 launchd.

**What #340 uniquely adds:** (1) **daily** cadence, (2) **absolute-dollar / delta** legs (fleet day-total vs rolling baseline; per-session outlier), (3) the report *body* needs top-sessions/dir breakdown for triage. Everything else reuses the #373 machinery.

---

## 1. Data survey — cost field shape + aggregation cost (verified on real files)

**Exact field paths (quoted from real session `~/.pi/agent/sessions/--Users-danielospina-Documents-GitHub-tortoise--/2026-08-13T14-59-42-136Z_…jsonl`, 2122 message records + 1 compaction):**

Assistant LLM call (per-call cost in **USD dollars**):
```
record.type == "message", record.message.role == "assistant"
record.message.usage = { "input": 19563, "output": 259, "cacheRead": 3584,
  "cacheWrite": 0, "reasoning": 103, "totalTokens": 23406,
  "cost": { "input": 0.00274, "output": 0.00007, "cacheRead": 0.00001,
            "cacheWrite": 0, "total": 0.00282 } }
```
Compaction record (a DISTINCT LLM call, same usage shape + `tokensBefore`):
```
record.type == "compaction", record.usage = { same keys }, record.tokensBefore = 984253
```
Top-level line keys (non-message): `type: "session"|"model_change"|"thinking_level_change"|"message"|"custom"|"compaction"`.

**Aggregation proof (per-session + per-day, via the EXISTING shared parser):**
- 276/276 session JSONLs under `~/.pi/agent/sessions/` carry a `cost` dict — **100% field coverage**, zero error rows on a full-corpus parse.
- Full-corpus parse (276 files, all projects): **5.0 s wall** → a daily incremental scan (only new files) is sub-second; even worst-case full re-scans cost ~5 s/day. "Cheapest always-on aggregation" is bounded by this: the parser + 5 s is a rounding error.
- Cost-field exact-match validation was already done at #373 (issue body: `cost.total` exact match vs pi's recorded cost).
- Per-day totals recomputed for this plan (tortoise dir, pre-clamp): Aug 10 $0.50 · Aug 11 $1.06 · Aug 12 $2.18 · **Aug 13 $10.80 (15 sessions)** · Aug 14 $6.02 · **Aug 17 $13.62 (9 sessions)** · Aug 18 $6.88 · Aug 19 $4.41 · Aug 25 $6.62. Matches the issue's documented $10.7/$13.4 peak days (delta = corpus scope incl. compaction-call spend). Cache-read share on ALL tortoise days (cheap AND spike): 81–93%.
- Post-clamp current regime (Sep 1–5, whole fleet): daily total $2.03–$8.50; top single session $2.99; median $0.40; max session context ≤ ~406K (per-day tops 396–405K; no ≥900K ceiling compactions in the new regime) → the 400K clamp is live; per-session cacheRead bounded ≤ ~0.75B (vs 1.3–4.1B per-*day* pre-clamp totals; per-session pre-clamp max ~1.8B).

**Tortoise retrospectives** (`docs/retrospectives/` in tortoise, commit `b3306e61`, 9 files): generated by `session-postmortem.sh`; each `.md` = session metrics (LLM calls, input/output/cache-read/reasoning tokens, max context, estimated cost, cache-share %) + postmortem.sh transcript patterns. Format confirmed; not on main — a branch artifact. Not the alert surface (they are post-hoc, per-session, human-read docs).

---

## 2. Cheapest always-on aggregation point — options compared

| Option | Cost | Coverage gap / flaw | Verdict |
|---|---|---|---|
| **(a) pi extension hook on `session_shutdown`** | Low code; pattern proven (task-heartbeat.ts, reflect-hook.ts, session-checks.ts) | Fires only while pi runs AND exits cleanly (`reason: "quit"` gating; `/new`/`/fork`/`/resume`/`/reload` also emit `session_shutdown` — extensions.md:432); a crashed/killed session fires nothing (its JSONL survives — the scan reads it, the hook misses it); the day-delta detector still needs a separate daily accumulator + baseline state; #341's plan explicitly rejected per-session hooks for the postmortem ("rejected C machinery") — fleet design bias documented | **Reject as primary.** Real-time per-session tripwire is the only unique upside; revisit only if daily cadence proves too slow |
| **(b) launchd daily scan of `~/.pi/agent/sessions`** | One small driver reusing the shared parser (5 s full corpus, sub-second incremental); **TCC-safe** — sessions live under `~/.pi/agent`, NOT `~/Documents` (the #427 TCC constraint that moved hub/oracle checks into pi; fleet-cost-weekly already runs from launchd for the same reason) | None material: catches crash-truncated sessions (data on disk regardless of pi state); cadence independent of pi uptime; stateless (baseline recomputed from filename dates, no in-memory state) | **✅ RECOMMENDED** |
| **(c) hosted tortoise `POST /v1/sessions`** | ~zero client work (reflect-hook.ts already posts on session quit) | **Not a cost surface.** `SessionRequest` = `{conversation, session_id ≤256, metadata, harness}` — no usage/cost/token fields (hosted_api.py:6046). It is conversation→knowledge-graph capture. Adding cost = hosted-API contract change (server + dashboard + quota work). Gated on `TORTOISE_API_KEY` which is **not set** (MEMORY.md: tortoise memory offline without it) | **Reject** — wrong layer entirely; cost telemetry is a local-file problem, graph capture is a knowledge problem |
| **(d) piggyback the #373 weekly cadence** | Cheapest possible (zero new scripts — run `fleet-cost-report.sh --days 1` inside the existing weekly driver) | **Up to 7-day detection latency** = the exact failure mode #340 exists to fix (spike discovered days after Aug 13). Weekly legs are structural (ceiling/cache-share over compacting sessions), not dollar deltas | **Reject as the primary cadence; ADOPT its machinery** (dedup-issue escalation, farmed launchd copies, parser contract) for the daily driver |

**Recommendation: (b) riding on (d)'s machinery.** Ship `scripts/fleet-cost-daily.sh` — a daily launchd job (07:30, Weekday 1–7) that shells the **shared parser** (`session-postmortem.sh --summary` over the previous calendar day's files), computes the §3 legs, and escalates through the **same dedup-issue pattern** as `fleet-cost-weekly.sh` (one OPEN `"fleet-cost-daily"` issue → comment, else create). No new parser, no extension, no hosted API change. Rationale: launchd independence from pi uptime + crash coverage + TCC-safe path + the #373 weekly job proves the exact pattern. Extension option (a) stays as a documented future add-on if real-time (minute-scale) alerting is ever wanted; hosted option (c) stays out of scope (see §4).

---

## 3. Alert thresholds — calibrated against real numbers

Pre-clamp tortoise corpus (validated day shapes): cheap days Aug 10–12 = $0.50/$1.06/$2.18; spike days Aug 13 = $10.80, Aug 17 = $13.62; mid Aug 14/18/19 = $4.41–6.88. Post-clamp fleet Sep 1–5: $2.03–8.50/day (whole-fleet totals 8.50/4.01/2.03/3.07/8.49; the \$0.08 day is Aug 31, outside this window); per-session median $0.40, max $2.99.

**Cache-share metric definition (used throughout):** cost-weighted share = (cacheRead + cacheWrite \$)/(total message \$) per the shared parser's cost semantics — NOT token-weighted share, which sits at ~99–100% on every day and would make any share-based alert meaningless. The 89–93% cheap-day figures below hold only under this cost-weighted definition; scope the range claim to the Aug 10–19 spike window (wider pre-clamp windows and the post-clamp regime run 36–78%).

| Leg | Pre-registered trigger | Replay validation (would it have caught Aug 13 day-1?) | False-positive check (today's regime) |
|---|---|---|---|
| **D1 — fleet day-total delta** | day total > **3 × rolling-7-day mean** of prior day totals AND **≥ $5**. Rolling baseline = mean over prior *session-bearing* days within the calendar-7-day window (zero-session days excluded — pinned convention; a calendar-mean over all 7 prior days including zeros gives materially lower baselines and changes trip behavior) | Aug 13: $10.80 vs baseline ~$1.25 = **8.6× → FIRES day 1** ✓. Aug 17: $13.62 vs ~$4.11 = 3.3× → FIRES day 1 of spike 2 ✓ | Sep 1: $8.50 vs 3.75 = 2.3× → no fire ✓ (busy #341/#372-style day, not runaway). Sep 5: $8.49 vs 3.63 = 2.3× → no fire ✓ |
| **D2 — per-session outlier** | any single session > **$5** (post-clamp regime; regenerate from corpus at impl) | Pre-clamp Aug 18's single session $5.94 > $5 → FIRES ✓. Aug 19's single session **$4.41 < $5 → does NOT fire** (only under the regenerated post-clamp threshold would it; D2's purpose is the quiet-day single-session runaway on an otherwise cheap day) | Sep max $2.99 → no fire ✓ |
| **D3 — cache-read VOLUME (not share), CLASS-SCOPED** | sum of cacheRead tokens/day over **1M-window / qwen-ha-class / pre-clamp-regime sessions only** > **1.0B** — the denominator is class-scoped sessions, NOT the raw fleet (raw fleet day-totals run 1.5–2.0B on normal busy days and would false-fire weekly). Requires the parser to emit a per-session `models`/window-class field so the daily driver can classify | Aug 13 = 3.14B, Aug 17 = 4.09B (class-scoped: the spike sessions are the 1M-window marathons) → FIRES ✓; cheap days Aug 10–12 = 0.17–0.70B → silent ✓ | Class-scoped post-clamp: the 400K clamp bounds per-session cacheRead ≤ ~0.75B (vs 1.3–4.1B per-*day* pre-clamp; per-session pre-clamp max ~1.8B), so D3 becomes a **regression/qwen-ha-1M detector**, low frequency by design. Re-validate against Sep 1/Sep 5 (busy-day fixtures) at impl — a raw-fleet D3 fires on both (Sep 1 = 2.01B, Sep 5 = 1.53B whole-fleet; 1.42B/1.13B tortoise-dir-only) |

**Cache-read SHARE > 80% — REJECTED as an alert (validated false alarm).** Real numbers: tortoise cheap days Aug 10–12 were **89–93%** cache-share; only the coupling of share × absolute volume made Aug 13 expensive. Share is a *structure* signal (a marathon session is present), not a *spend* signal. #341's plan already flagged this: "an 80% floor would be a permanent false alarm." The spend-relevant form is D3 (volume), and the fleet-level cache-share floor already exists as #373's (b) leg (0.65, over compacting sessions — small-n guarded).

**Interaction with #373's existing detectors (important scoping note):** ceiling-compaction (a) would ALSO have caught Aug 13–19 — those sessions compacted at 984–996K (≥900K) — but only on the **weekly** cadence. #340's contribution is cadence + dollar legs, not new structural detectors. The **watch-truncation rollback trigger** (>2× baseline re-read/calls over 3 days, or any `stopReason:length`) is the pre-committed *response* once a trip fires — the daily tripwire's alert body should reference it.

**Calibration convention (from #373):** constants above are pre-registered from the real corpus; the implementing session **regenerates them against the post-clamp corpus** (fixtures in `tests/fixtures/`) in the same change, exactly as #373 regenerated the Aug baseline with the fixed parser so the metric change never confounds the treatment.

---

## 4. Adversarial: alerting vs per-session budget cap

**Question:** is detecting-and-escalating the right layer, or should a per-session dollar cap be the default?

**Analysis:**
- **Config caps exist but don't cap spend.** `retry.maxRetries = 10000` caps retries per call (offline-resume contract — #341 explicitly keeps it; a spend cap must NOT touch it); `requestTimeout` caps a single call's duration. Neither bounds cumulative session spend. A runaway *loop* is implicitly bounded today by: the 400K context clamp (amplifier removed), sub-agent hard caps (#363: 2h→6h), and compaction cadence — but that's a set of *structural* bounds with no dollar figure on them.
- **A hard per-session kill is the wrong default for this fleet.** (1) False-positive cost is high: marathon sub-agent sessions (1,000–3,800 calls, $2–6 pre-clamp; #363 now sanctions 6h) are *legitimate* work — a $ cap that kills them mid-task loses work and pays for the compaction anyway. (2) Enforcement is ambiguous: who kills? an extension fighting the offline-resume contract? (3) The fleet's established philosophy (cost-config-policy §7, watch-truncation.sh) is **detect → surface → pre-committed human-executed response** (rollback to 1M is deliberate + committed + re-approved), never auto-kill. (4) The clamp is the standing *de facto* budget cap on the biggest amplifier, and #365's lifecycle contract (one-issue-per-session, handoff-size budget, max-call guidance) is the *behavioral* cap on the marathon class — the data gate #365 needs (4 weeks of #373 cadence) has begun accruing.
- **Where a cap IS defensible:** per-model-class config limits (e.g., a dollar- or call-budget dial on the qwen-ha 1M fallback, the one window #341 excluded from the clamp), as a second-order lever — never a fleet-wide kill.

**Recommendation: alerting-first (legs D1–D3) with the pre-committed response playbook already wired (#373 watch-truncation + #341 policy §7 rollback).** Alerting bounds detection latency (the actual failure: days of silence); the clamp + #365 lifecycle reduce spend; a per-session budget cap is deferred until #365's contract lands and the post-clamp distribution is measured (a cap threshold needs that distribution to avoid killing sanctioned marathons). Revisit in the #365 escalation review.

---

## 5. Where the report lands

**Recommendation: the existing GitHub-issue alert channel + the existing ops policy doc. NO new dashboard.**

- **Escalation = dedup GitHub issue** (one OPEN `"fleet-cost-daily" in:title` → comment, else create) — the identical pattern `fleet-cost-weekly.sh` already ships. ⚠️ **Dedup-key collision (review P3):** the weekly driver's dedup query is the quoted literal `"fleet-cost" in:title`, and `"fleet-cost-daily"` is a textual prefix of it — if GitHub phrase-matches substrings of hyphenated titles, the weekly job could comment on an open daily issue instead of creating its own. Settle at impl: run both `gh issue list --search` queries against a daily-titled fixture issue; if colliding, switch the weekly query to its own exact phrase (e.g. `"fleet-cost-weekly"`). The report has an **owner** (the same weekly-report reader; #341 PR-A's designated escalation recipient) and survives reboots (vs `/tmp/fleet-cost-weekly.log`, which is tmp-cleaned — the daily driver should log to `~/.pi/agent/state/`).
- **Report body** (in the issue) must be triage-ready: day total vs rolling baseline (fold-change), top 3 sessions by cost with dir attribution (parser output + session path → project dir), compaction/ceiling context, and the pre-committed response pointer (watch-truncation.sh rollback procedure). Daily runs are logged PASS quietly; only trips create issues (mirrors the weekly driver's "PASS lines are not issues" rule).
- **Policy home:** append a §"Daily cost-delta guardrail (#340)" to `docs/ops/cost-config-policy.md` — that file is the one place that pins the fleet's token-cost guardrail contract; thresholds + response playbook belong beside the #341 clamp contract, not in a new runbook.
- **Live dashboard — rejected:** the tortoise hosted dashboard (`website/apps/dashboard`) lists captured *sessions* with transcript rows but no cost on the wire (SessionRequest has no cost fields); building cost analytics there = server contract change + hosting + auth for data one person reads ~1×/day. A doc+issue alert is the cheapest surface with an owner. Revisit only if a multi-operator fleet emerges.

---

## 6. Scope/wiring table for the implementing session

**Gate note:** implementation is a NEW issue (file with O/I/T + affiliation per repo convention) → `issue-scoping` MANDATORY before planning → `writing-plans`/`plan-review` → implement under `task-workflow-standard` (complexity: **standard** — multi-file + cadence wiring + calibrated thresholds; NOT micro). Tests + `commit-workflow` (incl. code-review) at PR time. Docs: this file's §1–5 are the research; the implementing plan lives in its own dated plan doc.

| File | Change | Test | Est. |
|---|---|---|---|
| `scripts/fleet-cost-daily.sh` | **NEW** (~150–200 lines, modeled on `fleet-cost-weekly.sh`): resolve previous calendar day's files (filename-date window), shell the SHARED parser (`SPM_SH` seam), compute legs D1/D2/D3 (+ rolling-7d mean from prior day totals recomputed via the same parser — no state file needed for the baseline), escalate via dedup issue (`"fleet-cost-daily" in:title`). Log to `~/.pi/agent/state/` (NOT `/tmp`). Exit 0 clean · 1 trip (issue filed) · 2 env error. Env seams: `PI_SESSIONS_DIR`, `FLEET_DAILY_FACTOR` (3), `FLEET_DAILY_FLOOR` (5), `FLEET_DAILY_SESSION_MAX` (5), `FLEET_LOG`, `GH_BIN`, `FLEET_REPO` | `scripts/fleet-cost-daily.test.sh` mirroring `fleet-cost-weekly.test.sh` (stubbed `GH_BIN`): CLEAN / TRIP / DEDUP / DRY-RUN / rc=2; replay fixtures: Aug-13-shaped series fires, Sep-1/5-shaped series does NOT | ~1 day |
| `scripts/fleet-cost-report.sh` | No structural change (weekly legs stay weekly-semantics). Optional: print a one-line daily-summary hint? **No** — keep the weekly rollback instrument clean; the daily driver is the daily instrument | existing `fleet-cost-report.test.sh` untouched | 0 (none) |
| `templates/launchd/com.eldato.fleet-cost-daily.plist` | **NEW** template (StartCalendarInterval 07:30 daily; farmed copy target `~/.pi/agent/scripts/fleet-cost-daily.sh` — TCC-safe path) | via `install-launchd.test.sh` harness (template renders + installs idempotently) | 0.5 d |
| `scripts/install-launchd.sh` | No change (auto-discovers templates); add `--status` coverage for the new job in its test only if the harness asserts per-job lists | extend `install-launchd.test.sh` | 0.5 d |
| `scripts/cron-quality-gates.sh` | Add `fleet-daily` subcommand (load-gated, mirrors `fleet`) — the repo-tree entry for the same cadence | existing gate test pattern | 0.25 d |
| `scripts/session-postmortem.sh` | **Parser extended**: emit per-session `models` / window-class field (1M vs clamped) — REQUIRED, not optional: D3's class-scoped denominator is unimplementable without it (review P1: raw-fleet D3 false-fires weekly; the §3 FP cell's scoping clause requires session classification) | extend shared-parser tests | +0.25 d |
| `docs/ops/cost-config-policy.md` | Append §"Daily cost-delta guardrail (#340)": D1–D3 constants + regeneration rule + response playbook pointer | frontmatter/affiliation check (`check-doc-affiliation.cjs`) | 0.25 d |
| `tests/fixtures/` | Day-total series fixtures (Aug 13/17 spike shapes, Sep 1/5 busy shapes, quiet 7-day baseline) for the delta legs | consumed by `fleet-cost-daily.test.sh` | 0.5 d |
| Agent-infra session dir | The daily job itself runs on the real `~/.pi/agent/sessions` — no change | — | — |

**Total: ~3–3.5 dev-days** (standard complexity). Key risks to verify at implementation: (1) filename-date window semantics at month/day boundaries (the weekly report's window logic is the reference); (2) D1 rolling-mean warm-up (first 7 days: require ≥3 prior day totals else no-fire with a logged reason — mirrors the weekly report's small-n guard); (3) busy-day triage noise (D1 fires on genuine 2.5–3× batch days → the dedup-issue comment-update model absorbs it; consider 2-strike (2 consecutive days) only if triage noise proves real — pre-registered, not decided here).

## Learnings / open items
- The fleet's spend data is now **fully instrumented but weekly-gated**: the cheapest day-1 detector is a cadence + dollar-legs change over the existing parser — an estimated 3–3.5 days, no new infrastructure.
- The 400K clamp changed the spend distribution structurally (Sep max session $2.99 vs pre-clamp $5.94; no ceiling compactions) — thresholds MUST be regenerated against the post-clamp corpus at implementation, not shipped as the Aug-calibrated constants above.
- `TORTOISE_API_KEY` remains unset; hosted capture is conversation-only — any future hosted cost surface is a tortoise-repo contract change, deliberately out of scope here.
