---
title: "#634 — peak-window instrument, launch gate, and batch-cadence shift (Option A) — Scope & Plan"
type: engineering
domain: operations
doc_status: draft
subjects.team: organisation-design-team
created: 2026-09-11
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-634, issue-782, issue-631, issue-209, issue-685, deepseek, fleet-cost, peak-window
---

<!-- research-path: docs/research/2026-09-09-deepseek-peak-hour-pricing.md -->

# Plan — #634 (Option A): make the peak window visible, avoidable at launch, and out of the batch path

**Issue:** daniel-ospina/agent-infra#634 (Level: task · complexity:standard)
**Branch:** `feat/634-peak-defer-queue` (worktree `.worktrees/feat-634-peak-defer-queue`, base `699ecde`)
**Research:** `docs/research/2026-09-09-deepseek-peak-hour-pricing.md` (live-reverified 2026-09-11 — E11)
**Related:** #782 (deferred mid-flight half — this issue is its precondition) · #631 (rate-card governance — owns the
window *data*) · #209 (load-gate — the gate shape copied here) · #685 (metric (c) double-count — referenced, not absorbed)
**Status:** **draft for plan-review · v5 — after plan-review cycles 1–4 (4 reviewers + advisory #5 each) ·
EXIT REASON `honest-stuck`, escalating to the human (§15)** · see §15 before implementing.

> **Scope note.** Option A only. The mid-flight pause (`before_provider_request`), the watchdog coordination
> protocol, and the cache-aware pause thresholds are **#782 and are not planned here** (§10).

### Revision history & convergence log

*v1* was the initial draft. *v2* applied cycle 1. *v3* applied cycle 2. *v4* applied cycle 3 (including several
defects v3 itself introduced). *v5* applies cycle 4 — **and, per the skill's `honest-stuck` rule, stops and
escalates rather than opening a fifth fix round** (§15).

| Cycle | Reviewers | Findings | Disposition |
|---|---|---|---|
| 1 | 4 (3 proportional + Duplication & Architecture) | ~35, 20 P1-class: post-spawn preflight anchors; an untestable park; the park charged to the **enclosing** bound; the abort signal ignored and no release **while parked**; a forked defer-log contract; a surviving second window truth; the report re-implementing the weekday+hour rule; no extension farm/manifest registration; cost-config fixture breakage; `PEAK_FORCE` leaking into children; an unbalshable reconciliation predicate; compaction spend omitted; indicator (a) requiring a runway that v1 restated away. | **rewritten as v2** |
| 2 | 4 + #5 | 5 P1 + 28 P2. Load-bearing: **(a)** the hourly bucket key `"<Day>-<HH>"` was derived **twice in two languages** — drift yields **0.0% peak with every gate green**; **(b)** the bounded-wait algorithm was re-derived at **4–6 call sites**; **(c)** the new report `rc=2` causes were **misread by `fleet-cost-weekly.sh` as "env failure, no file"**, hiding an instrument refusal; **(d)** the force-marker "one writer" and the window-literal grep-BLOCK were **unenforceable as written**; **(e)** the `PEAK_ENCLOSING_BOUND_MS` contract was undeclared (unset ⇒ `NaN` ⇒ the marquee epic-executor path never parks); plus a zero-division → `rc=1` → bogus weekly issue, non-atomic marker writes destroyed by the poll, per-tick event amplification, `PEAK_DISABLED` leaking, the CI test path resolving from the wrong cwd, and a nine-vs-seven fixture count. | **rewritten as v3** |
| 3 | 4 + #5 | 3 P1 + 9 P2 (R1) · 5 P1 + 5 P2 (R2) · 9 P1 + 3 P2 (R3) · #5: 1 P0 + 4 P1. Load-bearing: **(a)** the tear check was a **TOCTOU on a live corpus** → a weekly **false escalation**; **(b)** the `sessionId` event↔corpus join was **structurally impossible**; **(c)** the `(d)` payload grows to **~0.9 MB vs `ARG_MAX` = 1 MiB** at `--days 30` → `E2BIG` → **rc 126**; **(d)** the new key guard **cannot hold** and is blind to the Mon=0/Sun=0 day base; **(e)** no per-park id; **(f)** a self-contradictory event taxonomy; **(g)** `cron-quality-gates.sh` is a **second** rc-2 consumer; **(h)** the liveness clause is `tool-stall`, not `stream-stall`. | **rewritten as v4** |
| 4 | 4 + #5 | R1: 3 P1 + 7 P2 · R2: 6 P1 + 6 P2 · R3: 8 P1 + 7 P2 · #5: 1 P0 + 2 P1 + 2 P2. Load-bearing: **(a) E10's headline baseline is the *whole* corpus, not the 30-day selection** — so AC2's ±0.5% trust gate would fail on the number the plan tells the implementer to expect (~15.4% vs the stated 17.0%); **(b)** the tear signal **cannot** detect a static boundary truncation (the two counts are equal by construction) — the claim was wrong, and one file's cost inclusion under mid-pass growth was undefined; **(c)** the enclosing **liveness** kill is on **tool *age***, not marker freshness (`effToolAge = toolAgeMaxMs + markerAge`), so AC6's "a park longer than the liveness bound is not cut" was **impossible**; **(d)** `CHILD_STRIPPED_ENV` as an *engine* export is **unimplementable** — `scripts/` cannot be imported from `extensions/` (this plan's own rule); **(e)** the flap guard's quantity ("remaining peak time") is undefined and contradicts its own marquee case; **(f)** 11/346 live session files have **no `type:"session"` record** → a hard cross-check would make the instrument refuse on the healthy fleet; **(g)** the new extension test files run **nowhere** in CI; **(h)** `abort`/`force-release` mid-park have **no terminal event**; **(i)** `NODE_BIN` renames the established `PI_NODE_BIN`; **(j)** my own §14 D-2 evidence was **false** (`SUBAGENT_ATTEMPT` is not in either strip list). | **rewritten as v5, then ESCALATED** |

> **⚠️ Exit reason: `honest-stuck` (not a clean exit).** Four cycles have each produced ~30 findings, and — the
> signature the skill names for `honest-stuck` — **the fingerprints differ every cycle: the fixer is introducing
> new issues faster than it resolves existing ones.** v4's own fixes generated four of cycle 4's P1s (the
> `CHILD_STRIPPED_ENV` placement, the flap-guard quantity, the tear claim, the extension-test CI gap), and v3's
> fixes generated six of cycle 3's. Issue counts by cycle: **35 · 33 · 34 · 31** — not the strict
> three-consecutive-non-decreasing the rule requires, but the substantive condition (new fingerprints each cycle)
> holds and the cost/benefit has inverted: this is a `complexity:standard` issue whose measured ceiling is
> **~$3.7/mo** (E10), and four review cycles have not converged. Per the skill, this is an **escalation exit**:
> v5's remaining issues are documented in §15 and **must be acknowledged by a human before implementation**.
> This plan is **not** reported as clean.

---

## 0. Corrections to the inputs (verified at source, 2026-09-11)

| # | Finding | Evidence | Consequence |
|---|---|---|---|
| **E1** | **`cost.total` carries no time dimension**, so the raw cost dict cannot distinguish peak from off-peak. The split must apply the 2× multiplier itself. | `pi-ai/dist/models.js:530–548` — `calculateCost()` bills `input/output/cacheRead/cacheWrite` from `ModelCostRates` + token-count `tiers` only; `types.d.ts:702–715` — no date/time field. | A naive "sum `cost.total` per hour" **understates the peak share by ~2×**. The single most important Phase-1 constraint. |
| **E2** | The **shared parser drops timestamps.** They *do* exist: a top-level ISO `timestamp` on **every** record, plus an epoch-ms `timestamp` inside `message`. | `scripts/session-postmortem.sh:54–160` (`one()` — no `timestamp` key in the emitted row). | **Deliverable 1 is a parser change**, not a report-only change. |
| **E3** | **Existing fixtures write message records with NO timestamp**, and a compaction record with `"timestamp": "x"`. | `scripts/fleet-cost-report.test.sh:44–52`; `scripts/fleet-cost-weekly.test.sh:53–75`. | An `unknown-timestamp` bucket is **mandatory** and must be **counted in** the reconciliation. |
| **E4** | **#631 owns the window data and its ledger does not exist yet** (#631 OPEN, `scoping`). Its §3.4 contract: missing ledger ⇒ loud failure, never a literal; no competing window table. Its row key is `(provider, model, effectiveFrom)` + optional `periodEnd` — **no `periodKey`**. | `docs/plans/2026-09-10-issue-631-rate-card-governance.md` §3.1, §3.4, §5; `scripts/rates/` absent at `699ecde`. | A defined-precedence resolver + a **non-authoritative, expiring** bootstrap + a real trip (§2.2). |
| **E5** | **No in-repo cadence both spends tokens and is deferrable.** 2 of 5 plists are 15-min monitors, 2 hourly, 1 weekly. The **only token-spending cadence** is `provider-latency-tripwire.sh` (hourly, a real provider request) and it is **non-deferrable by purpose**. `cron-quality-gates.sh`'s four subcommands make **no provider requests**. | `templates/launchd/*.plist`; `scripts/cron-quality-gates.sh:150–330`. | **Deliverable 3 is much smaller than the brief assumes** (§3.3). The local quality gates must not be *parked* (motion without saving) — but they **do** consume the report's rc-2 contract (Task 1.3). |
| **E6** | **Two dispatch surfaces.** `task` = `extensions/builtin-tools/index.ts:3235` (`execute`) → `:3441`/`:3532` (`spawnSubAgent`, defined `:2283`, spawns `:2305`). `subagent` = `extensions/subagent/index.ts:1402` (`execute`) → `:1488`/`:1580`/`:1639` → `runSingleAgent` (`:823`, spawns `:1013`). `epic-executor` uses **`subagent`**. | as cited; `skills/epic-executor/SKILL.md:78–101`. | Two preflights, one engine. Gating only `task` misses the batch path. |
| **E7** | Both surfaces arm their bound timers **after** the spawn, so a preflight at `execute` entry is clean for the child — but the park is charged to the **enclosing** dispatcher. `task` cap 6 h (`DEFAULT_HARD_CAP_MS = 21_600_000`, floor 60 s, timer `:2522`, `startedAt` **`:2542`**); `subagent` default **30 min** (`DEFAULT_TASK_TIMEOUT_MS = 1_800_000`, `:261`). **The enclosing liveness kill is on tool *age*, not marker freshness** — `if (stateFresh && st.toolsInFlight > 0) { bound = turnActive ? toolStallMs : min(toolStallMs, heartbeatTimeoutMs); if (effToolAge > bound) return kill("tool-stall") }` where `effToolAge = st.toolAgeMaxMs + markerAge` (`:2135–2136`, `:2151–2158`). Fresh markers keep `markerAge` small; they **cannot** stop the kill once the in-flight tool's own age exceeds the bound. `stream-stall` is gated `toolsInFlight === 0` (`:2162`) and therefore **cannot fire while parked**. | `extensions/builtin-tools/index.ts:1482` (`DEFAULT_TOOL_STALL_MS = 21_600_000`), `:2135–2136`, `:2127–2129`, `:2151–2158`, `:2162`, `:2522`, `:2542`; `extensions/subagent/index.ts:261, 1059–1067`. | The liveness ceiling **must be propagated as a deadline**, not defended with heartbeats (§2.4). |
| **E8** | Metric (c) double-count **already filed**: #685 (OPEN). | `gh issue view 685`. | Referenced, **not absorbed**. |
| **E9** | **Farm + registration constraints.** `scripts/` is **copied** to `~/.pi/agent/scripts/` from explicit basename allowlists (launchd cannot read the repo under macOS TCC). A new extension needs **two** registrations (a `pi-bootstrap/pi-config/extensions/<name>` symlink **and** a `manifest.json` `files["extensions/"].entries` row). `node` is **not** on launchd's default `PATH`. **The pi/node binary probe order is already established**: `PI_NODE_ROOT` glob → **`PI_NODE_BIN`** → `command -v pi` (`scripts/probe-frontmatter-fixtures.mjs:43–52`, documented `scripts/check-skill-lint.oracle.test.mjs:21`, honoured `scripts/install-launchd.sh:86–87`). | `pi-bootstrap/setup.sh:281–304`; `scripts/check-pi-config-extensions.sh:60–140`; `sync.sh:52–55`. | Decides the architecture (§2.1) and forces an **explicit interpreter resolution** — using the **existing** convention (§2.6). |
| **E10** | **Measured baseline — TWO numbers, previously conflated.** The `fleet-cost-report.sh` window is a **filename-date selection** (`cutoff = today − (days−1)`, `:106–120`), so `--days 30` today selects **335** of the **346** corpus files. **All-corpus** (346 files): recorded **$163.41**, peak **$27.52**, adjusted **28.8%**, premium **$13.76**. **`--days 30` (335 files, what the report actually prints and what AC2's trust gate runs)**: peak **$24.26**, adjusted **26.7%**, premium **$12.13**. The **launch** segmentation is predicate-dependent and was never defined: sessions whose first *cost-bearing* record is in a window = **122** (peak $4.13 → premium ≈$2.07); E10's earlier "133 / $7.40 / $3.70" came from a different, unstated rule and is **withdrawn**. ~84% of the premium is straddler spend under the defined rule (E10's earlier 73% is **withdrawn**). | 30-day and 346-file scans over `~/.pi/agent/sessions`, 2026-09-11; selected predicate now pinned in §6. | Option A's ceiling is ~**$2–4/mo upper bound**, before filtering to the deferrable subset. **Scope caveat:** this is the *session corpus*, ≈14% of the cited $1,151/30 d bill — dispatched children run `--no-session` (ephemeral) and are absent from it (§2.3). **AC2 must compare against the 335-file number.** |
| **E11** | Vendor page re-fetched live 2026-09-11: **windows and multiplier unchanged**; the **absolute card has moved**; the page now says **V4 Pro continues past 2026-09-14 with billing unchanged**. | `https://api-docs.deepseek.com/quick_start/pricing/` fetched 2026-09-11. | (a) The **ratio** is robust; absolute dollars inherit the card drift #631 owns. (b) The Pro reversal affects #631's modelling — a `periodEnd` + re-route, **not** an `expiresOn` tombstone. **Reported, not absorbed** (§10). |
| **E12** | `ci.yml`'s `ci:` job `test-command:` is **pinned exactly** by `check-skill-lint.test.mjs` §(j); §(h)/(i) pin the `extensions/*/package.json` pin map and ci-main stamp counts. `ci-main.yml` runs its script tests in **two** places: **`script-validate`** (`:198–206` — `install-launchd.test.sh`, `pi-reap-idle.test.sh`, `record-review.test.sh`) and the separate **`extension-tests`** job's `test-command:` (`:32–43` — `ci-ref-check.test.mjs`, `check-skill-lint.test.mjs`, `commit-msg-check.test.sh`), which *is* the pinned reusable-workflow input. **None of the fleet-cost/parser suites is wired** — `session-postmortem.test.sh`, `watch-truncation.test.sh`, `fleet-cost-report.test.sh`, `fleet-cost-weekly.test.sh`, and `load-gate.test.mjs` run nowhere. Extension suites are **enumerated line by line** (`:118–158`): the only globs are `extensions/*/test*.mjs` (`:51`) and `extensions/shared/*.test.ts` (`:69–76`), so **a new `.ts` suite in an existing extension dir runs nowhere**. | `scripts/check-skill-lint.test.mjs:373–405`; `.github/workflows/ci.yml:23–37`; `.github/workflows/ci-main.yml:32–43, 51, 69–76, 118–158, 198–206`. | New bash steps go in **`script-validate`**; new extension suites need **explicit lines**; the pinned `test-command` scalar is never edited (Task 1.4/2.3/2.4/2.5). |
| **E13** | `extensions/shared/audit-log.ts`'s `GateEventName` union is **untyped at the write path** (`appendJsonl(entry: Record<string, unknown>)`) and is **already non-exhaustive**. **Two distinct sets**: **7 names observed in the live log** (51,777 lines, 14 distinct values) but absent from the union — `gate_recovery_empty` · `review_gate_parent_enforced` · `gate_recovery` · `m4_worktree_exemption` · `gate_skip` · `gate_bypass_refused` · `gate_block_in_batch_chain` — **plus `gate_block_parse_failure`**, emitted from `extensions/verification-gate/index.ts:3214` but not yet in the log. **A scripts-side writer exists and cannot import the union**: `scripts/vgate.sh:34,47` (a raw python heredoc, second-precision `ts`, event `bridge_clear`). | `extensions/shared/audit-log.ts:16–21, 29–37, 45`; `scripts/vgate.sh:34,47`; live log scan. | Task 2.1 adds a **typed emit helper** + a fixture test over the **producer-emitted** name set, and backfills the 7 log names + `gate_block_parse_failure`. **One JSONL serializer for scripts-side writers** (§2.5). |
| **E14** | **#631 §5 now contradicts this plan in two ways, and the plan never recorded it.** #631 §5 says "**#634 owns everything behavioral:** the defer queue, **pausing**, `[PEAK-PAUSE]`, peak-share and **avoided-premium aggregation**", and "`#634`'s **`shared/peak-window`** must read `peakWindows[]`/`peakMultiplier` from the ledger". Here, (i) pausing / `[PEAK-PAUSE]` / avoided-premium are **#782's** (§9/§10, matching issue #782), and (ii) the interface is realised as **`scripts/peak-window.mjs`** (+ `extensions/shared/peak-park.ts`, `extensions/shared/child-env.ts`) — a relocation forced by E9. | `docs/plans/2026-09-10-issue-631-rate-card-governance.md` §5; issue #782's deliverable list. | **Recorded as a supersession** (§2.1), not silently diverged. A note is owed back to #631 §5. |
| **E15** | **The escape-marker concept already has three dialects, not two.** (1) `extensions/main-worktree-guard/index.ts:289–301` — `~/.pi/agent/.allow-main-edits`, `{session_id, reason, ts}`, mtime-based 15-min TTL, non-atomic `writeFileSync(flag:"w")`; env hatch `AGENT_ALLOW_MAIN_EDITS`. (2) `extensions/sequence-enforcer/index.ts:758–759` — `/tmp/parallel-check-force.json`, **`FORCE_TTL_MS` = 60 min**, content-`ts`, hand-written by the operator and documented in `skills/enforcement/SKILL.md:35` as *the* human escape. (3) **New here**: `~/.pi/agent/peak-force.json`, `{ts, expiresAt, scope, sessionId, actor, cwd}`, 60-min TTL — which **independently re-derives** `FORCE_TTL_MS`. | repo-wide grep (`allow-main-edits`, `FORCE_FILE`, `parallel-check-force`, `peak-force`); `skills/enforcement/SKILL.md:35`. | §2.5 declares the **marker family**, widens the guard to it, and records the deferred unification with a named owner. |
| **E16** | **The two child-env strip lists have NOT diverged.** They are byte-identical (`builtin-tools:3319–3334` = `subagent:974–986`: `ELDATO_SKIP_VGATE`, `ELDATO_SKIP_REVIEW_GATE`, `AGENT_ALLOW_MAIN_EDITS`, `ELDATO_ALLOW_MAIN_EDITS`). **`SUBAGENT_ATTEMPT` is not a strip-list element** — it is a per-level fallback marker set/deleted separately at `subagent/index.ts:1011–1012`. v4's claim that the lists "have already diverged on `SUBAGENT_ATTEMPT`" was **false** and is withdrawn. | repo-wide grep; both regions read. | The de-duplication is justified **prospectively** (the `PEAK_*` family is about to be added to both), not by a past divergence — and the shared list belongs in `extensions/shared/`, not the engine (§2.5). |

---

## 1. Problem statement

DeepSeek bills **2×** during `01:00–04:00` and `06:00–10:00` UTC, Mon–Fri. We do not know **how much** of our
spend lands there, and the tooling that would tell us cannot:

1. **Nothing reports the hour-of-day split.** `fleet-cost-report.sh` reports only time-invariant metrics; the
   parser never reads the timestamps already in every record (E2). #782 is gated on the *measurement* (its
   precondition 1). **This lands first and must be trustworthy** — the multiplier arithmetic (E1), the
   unknown-timestamp bucket (E3), compaction coverage, and an explicit statement of the measurement base (§2.3).
2. **Fresh launches inside the window are not deferred.** A headless batch started at 19:50 local runs 2× for its
   first three hours. Nothing is lost by parking it — no prefix cache exists before the first provider request.
3. **The documented batch path (`epic-executor`) has no peak awareness.**

**Reframing rationale (user-approved 2026-09-11):** ~$1/mo ceiling for agent-infra's own slice; ~80% of even-peak
spend comes from sessions launched ≥6 h earlier, reachable **only** by a mid-flight pause; the cache guardrail may
invert that sign. Option A captures the safe half and builds the instrument that makes #782 decidable.

---

## 2. Decision & architecture

### 2.1 One production definition, invoked — plus one declared independent oracle

**`scripts/peak-window.mjs` is the single *production* source of the window definition, the classification, the
multiplier arithmetic, and the force marker.** It mirrors `scripts/load-gate.mjs`'s shape: pure exported
functions, `run(argv, deps)` with injectable `env`, a CLI dispatcher, exit codes `0 allow / 2 usage / 3 defer`, and
`--force`. Every consumer invokes it as a **subprocess**, never as a cross-directory import (E9; and see the
boundary rule below).

> **#631 §5 supersession (E14).** #631's §5 places pausing, `[PEAK-PAUSE]`, and avoided-premium aggregation in
> #634, and names the interface `shared/peak-window`. This plan **supersedes that**: pausing and
> `[PEAK-PAUSE]` and the avoided-premium aggregate are **#782's** (matching issue #782's own deliverable list and
> §9/§10 here), and the interface is realised as `scripts/peak-window.mjs` plus the loader-skipped helpers
> `extensions/shared/peak-park.ts` and `extensions/shared/child-env.ts`, because `scripts/` is farmed and cannot be
> imported from `extensions/`. **A correction note is owed back to #631 §5** (Task 2.8).

> **The "single source" claim is qualified deliberately.** `scripts/peak-window-oracle.mjs` (§6) is a **second,
> independent** implementation of the window rule — that independence *is* its purpose. It is named in the guard's
> allowlist and constrained by a **key-set equality test** against the engine (a `Σ` tolerance alone cannot see a
> one-day shift falling in a low-traffic hour). "Single *production* source, one declared independent oracle" is the
> invariant; "single source, full stop" was wrong.

**The wait *decision* lives in the engine; the wait *algorithm* lives in exactly one place per language family:**

- `node scripts/peak-window.mjs park` — the canonical bounded wait for **all** script/wrapper callers. **It owns
  the wait loop and therefore owns the `PEAK_NOW`/`PEAK_SLEEP_MS`/`PEAK_POLL_MS` seams.** Its structured return
  (`{verdict, skipReason, terminalReason, parkId, parkMs, resumeAt}`, §2.4) is what the callers turn into events.
- `extensions/shared/peak-park.ts` — an **import-only** helper (loader-skipped, the `audit-log.ts` pattern)
  implementing the *same* algorithm with the extension-only additions (abort-signal race + force poll + synthetic
  activity markers). A parity test drives both over an injected clock/sleep and compares the **chunk sequence and
  bound behaviour** — *not* emitted events (the engine emits nothing, §2.5).

**The boundary rule, stated once and enforced:** `extensions/` may import from `extensions/shared/`; it may
**never** import from `scripts/`, and `scripts/` may never import from `extensions/`. Shared vocabulary that both
trees need therefore lives in **`extensions/shared/`** (which `scripts/` cannot read either) — mitigated by the
engine emitting that vocabulary as **data** on its CLI, never as an import (§2.5, §2.6).

**Hour-of-week keys are integers — but integers do not fix the day *base*.** `classify-keys --json` returns the
peak slot set as **`dow * 24 + hour` integers**, and the parser emits its bucket keys in the same integer form.
Integers have no grammar to diverge on. But Python's `weekday()` is Mon=0 and JS's `getUTCDay()` is Sun=0, and
**both yield values in 0–167, so no set-membership test can see a one-day shift.** The guard is therefore an
**ISO-instant equivalence test** (§6) — one per weekday, both windows, the gap, the weekend, and a non-`Z` offset
timestamp — asserting `parserBucketKey(iso) === engineKey(classify --at iso)` **and** the `inPeak` verdict from
both sides.

### 2.2 Window source — a declared exception with trips that can actually fire

`peak-window.mjs` resolves `{ windows[], multiplier, source }` with defined precedence:

1. `$PEAK_WINDOWS_FILE` / `$PEAK_WINDOWS_JSON` — **operator/test seam, and the only source permitted to be a
   competing table**. Validated (absolute path to a regular file; an invalid value falls through **and is echoed in
   the loud-failure output**; quote the expansion). It is a **fourth source, `source: "env"`**, **inside the
   declared #631 exception**. Report behaviour is **refuse** (rc 2 + token `windows-source: env`): an env override
   may drive the *gate* (tests, an emergency) but must never produce a *published* fleet number. Restricted to
   `NODE_ENV=test` by default (§11 Q10).
2. `$RATE_LEDGER` → **`$AGENT_INFRA_PATH/scripts/rates/deepseek.jsonl`** → the **farmed** copy
   `~/.pi/agent/scripts/rates/deepseek.jsonl`. **Row selection:** rows whose period covers today
   (`effectiveFrom <= now < (periodEnd ?? ∞)`), all of which must **agree** on `peakWindows[]` and
   `peakMultiplier`; disagreement is `unresolved`.
3. **Expiring bootstrap constant** matching the verified vendor page (E11), `source: "builtin-bootstrap"` — used
   **only when no ledger path resolves at all**, and carrying a hard **`BOOTSTRAP_EXPIRES_ON = 2026-12-31`** date.

| Outcome | Gate | Report `(d)` |
|---|---|---|
| `env` (override) | classify | **refuse** — rc 2 + `windows-source: env` |
| `ledger` | classify | split; section line prints the ledger path |
| `builtin-bootstrap` (no ledger path resolves) | classify; log `source` | split; section line prints `windows-source: builtin-bootstrap (EXPIRING — #631, sunset 2026-12-31)` |
| `unresolved` (a ledger path exists but is unparseable / uncovered / rows disagree) | **fail open** — allow, `peak_skip` reason `unresolved` | **refuse** — rc 2 + token `windows-source: unresolved` |

> **⚠️ A dated, deliberate exception to #631 §3.4, not compliance with it.** #631 requires "missing ledger ⇒ loud
> failure, never a literal fallback" and forbids a competing window table. Phase 1 must land standalone (it is
> #782's precondition and #631 is unstarted), so the bootstrap is a **scoped, expiring exception**, labelled on the
> report's own section line, **non-authoritative** (no assertion ties the ledger to it), and retired by **trips that
> can actually fire** (§ below).

#### The single guard: `scripts/check-peak-single-truth.sh`

One guard with **one** both-direction self-test (v3 had three separate guards, each with its own self-test —
cycle 3's proportionality finding; one discriminator is easier to keep honest than three).

- **Allowlist:** the engine, `scripts/peak-window-oracle.mjs` (declared, justified — §2.1), and `docs/**` (#631 AC1
  shape). Sub-rules **1** and **2** are scoped to *this* allowlist; **sub-rule 3** carries its own.
- **Sub-rule 1 — window literals.** The pattern is *not* a bare time: it is a boundary time **co-occurring with a
  weekday list or a `peakWindows`/`startUtc`/`endUtc`/`peakMultiplier` key**. `scripts/pi-reap-idle.test.sh`
  already carries ~10 `01:00` occurrences and would otherwise be a false positive.
- **Sub-rule 2 — no retyped boundaries in tests, WITH an explicit allowlist.** v4 declared this rule with no
  allowlist, which would have reddened the plan's *own* mandated tests (`scripts/peak-window.test.mjs` asserts
  `2026-09-14T00:50:00Z` → `resumeAt === 04:00:00Z`). The rule is therefore scoped: **a test may assert boundary
  *expectations* (a handful of instants), but may not carry a window *table*** (a `{startUtc, endUtc}` list or a
  weekday/hour matrix), which must come from the engine's export. The named allowlist includes the engine's own
  unit test and the oracle's test.
- **Sub-rule 3 — the marker write target, widened to the marker FAMILY (E15).** `peak-force.json` may appear as a
  **write target** only in `scripts/peak-window.mjs` and the explicitly named marker test files (which must write it
  to verify TTL / session / malformed / split-write). Because the repo already has three dialects (§2.5), the
  sub-rule also asserts a **marker inventory** — the set of marker paths, their TTLs, and their reader/writer
  owners — so a fourth dialect cannot appear unnoticed.
- **Both-direction self-test:** a planted literal *outside* the allowlist fires; one *inside* it does not; the
  current tree passes.
- The policy doc's window table is **generated** (`windows --markdown`) and asserted by a re-extract-and-compare
  test.

#### The sunset trips (they can actually fire)

v3's gate — "fails loudly when the ledger exists AND the bootstrap was used in the last report run" — **cannot fire
on its own stated purpose** (by the resolver above, the bootstrap is used only when *no* ledger path resolves, so the
conjunction is satisfiable only by a *farm regression*) **and has no artifact to read** (the report runs weekly under
launchd, persists nothing, and a fresh CI checkout has no such state). v5 replaces it with two mechanical trips:

1. **Absence-once-ledger** — a guard assertion that the bootstrap literal is **absent from
   `scripts/peak-window.mjs`** once a ledger exists **at either location** (repo *or* farmed copy), so a stale farm
   cannot pass the trip while the shipped report still falls back.
2. **`BOOTSTRAP_EXPIRES_ON = 2026-12-31`** — compared in **UTC**; past that date the guard **BLOCKs**. So the
   exception cannot outlive its justification even if #631 slips. **Runtime behaviour after expiry is the same as
   before** for the *gate* (it still resolves and serves the bootstrap, so a batch is never blocked by a date) —
   the trip is a CI/pre-commit gate, not a runtime kill, and that is stated rather than implied.

Both trips are **no-ops when no ledger exists anywhere** (tested), and the absence assertion is **scoped to the
engine file** (not `docs/**`, which legitimately quote the windows).

### 2.3 The split arithmetic

Buckets are **kind-aware** and keyed by **integer hour-of-week**:

```
hourlyUtc[25] = { msg: {cost, calls, input, output, cacheRead, cacheWrite}, comp: {cost, calls} }
ts_unknown    = { msg: {cost, calls}, comp: {cost, calls} }   # missing/unparseable timestamp
session_id, session_id_unverified                              # see below
n_lines, n_bytes, n_bad                                        # see "tear" below
```

Three labelled numbers, never blended: **recorded split** (shape only — time-invariant, E1), **multiplier-adjusted
billed split** (17.0% → 29.0% class of answer), and **peak premium**
(`peak × (multiplier − 1) / multiplier`).

**Reconciliation (double-entry) and the guards:**

```
Σ hourlyUtc[*].msg.cost + Σ hourlyUtc[*].comp.cost + ts_unknown.msg.cost + ts_unknown.comp.cost
    == msg_cost_total + comp_cost_total            (± float epsilon)
Σ hourlyUtc[*].msg.calls + ts_unknown.msg.calls == msg_calls ; likewise comp
```

A mismatch exits 2 with the token `RECONCILIATION MISMATCH`. A **zero or undefined total** is guarded explicitly
(`peak / total` would raise `ZeroDivisionError` → rc 1 → a bogus escalation, since the drivers special-case only
rc 2). **Every failure inside the `(d)`/events computation maps to rc 2** — never rc 1.

**Session identity — and the header-less 3%.** The parser's `session` field is the **full filename**
(`<ts>_<uuid>.jsonl`, `scripts/session-postmortem.sh:77–82`); the pi session id is the **bare uuid suffix**.
**11 of 346 live files (3.2%) have NO `type:"session"` record at all** — their first record is a `type:"message"`
with full `usage.cost`. v4 required asserting `session_id` *against* that record, which would have made those 11
files error rows → `ERR_COUNT > 0` → the #373 fail-closed gate → **rc 2 on the healthy fleet on day one.** Policy:
`session_id` is derived from the **basename unconditionally** (`rsplit("_", 1)`); the `type:"session"` record is a
**cross-check, not a precondition** — if the record exists and disagrees, or if it is absent, the row carries
`session_id_unverified: true` and is **counted in the totals** but **excluded from the join** (and counted in
`unjoined_peak_defer_events`). Fixtures cover both a header-less file and a disagreeing record.

**Tear detection — what it actually detects.** v3/v4 claimed an "independent on-disk count" that surfaces a static
truncation at a record boundary. **That is impossible**: `n_lines` is the parser's count of the same file, so on a
static file the two are equal by construction (and v4's proposed `observed < consumed` comparison would have been
either a no-op or, given `n_lines` counts only **non-blank** lines, a blank-line false-positive generator). The
claim is **withdrawn**. What is implemented and claimed:

- **`n_bad`** — malformed/unparseable records (a real, already-existing signal), plus the parser's existing error
  path (`session-postmortem.sh:148–151`) which feeds the report's fail-closed data-absence gate.
- **Mid-pass mutation** — `stat` the file **before and after** the parse: **grew ⇒ `live-file-skipped`** (a live
  append: **no** tear); **shrank, or changed in place ⇒ tear** → rc 2 + token `TEAR`. This is genuinely
  independent (it compares an *external* observation against the read), and it is the only truncation-class signal
  available.
- **A file's eligibility for the *number*** (v4 left this undefined): a `live-file-skipped` file's parsed rows
  **are** included in the totals (its bytes up to the snapshot boundary are real spend), and the `(d)` section line
  prints `live-file-skipped: N (partial read)` so the total is not presented as complete. A contract test asserts
  the per-hour table still sums to the printed total over those partial rows.
- **Static truncation is caught by `n_bad` and by `scripts/watch-truncation.sh`**, not by the tear line — stated
  explicitly so the failure-mode table does not promise an impossible detection.

**Transport must not be argv.** The `(d)` payload is the largest the parser has ever emitted: the live 30-day
corpus goes from ~197 KB to **~0.85 MB** under this schema, against macOS `ARG_MAX = 1,048,576` (which also counts
the environment), and `scripts/fleet-cost-report.sh:164` passes the summary as a **single argv** to `python3`.
`--days 30` is exactly the run AC2's trust gate mandates, and the corpus grows monotonically. **Decision: stdin.**
The data is piped (`… | python3 -c "$PROG" …`) and read with `sys.stdin.read()`; numeric parameters move to
**flags**, not positional indices (`:132`'s file list keeps its own transport, also not argv). A temp-file fallback
uses a **per-process name** (`peak-summary.$$.tmp`). Because **bash cannot see `errno`** — `E2BIG` surfaces as a
generic exec failure (rc 126/127) — the mapping is a blanket non-zero → rc 2, but with a **dedicated token
`transport-failed`** (distinct from `windows-source`/reconciliation) so the drivers can report an environment fault
rather than an instrument refusal. A concurrent-run test (two reports over one corpus) and a missing-interpreter
test assert both the token and the driver decision.

**An absent instrument must be loud, and it is its own class.** The report's empty-corpus path exits **0 before
`(d)` renders** (`:125–130`), so an emptied corpus makes the instrument and its refusal lines *vanish* while the
driver logs **PASS**. v5 prints `instrument: no-data (0 sessions scanned)` and exits 2 — and, because promoting a
quiet week or a freshly bootstrapped machine to a **filed escalation** would contradict "no new escalation class",
that token is a **declared, non-escalating loud failure**: the drivers print it prominently and do **not** file.
This is a new, explicitly-named handling class (§8 AC9/AC13 updated), not a silent addition.

**Provenance and measurement base (one line):**

`windows-source: <env|ledger|builtin-bootstrap|unresolved> · multiplier: 2 · base: session-corpus (excl. --no-session children) · live-file-skipped: N`

The **base caveat is not optional**: the corpus is ≈14% of the cited bill (E10) because both dispatch surfaces
spawn ephemeral `--no-session` children (`extensions/builtin-tools/index.ts:3440`;
`extensions/subagent/index.ts:876`), so the gate's *own* target traffic is largely outside the instrument. **#690** owns
the unattributed remainder.

**Segmentation predicate — pinned** (E10 withdrew the earlier figures for lack of one): a **launch** is the file's
first `type:"message"` ∧ `role:"assistant"` record carrying a parseable `timestamp`; it is **in-peak** iff that
instant ∈ the window set. This predicate is stated verbatim in the oracle (§6) so AC2's segmentation clause is
reproducible.

**Hand-off to #631 §5.** #631 requires "WS5.3 records the frozen `--usage-rows` schema in #634 itself at
implementation time". Task 1.3 records the frozen field list; Task 2.8 files the arithmetic-switch follow-up as a
**real issue with a number, an owner, and `Depends on: #631 §5 / WS3.1`**.

### 2.4 The gate shape

```
node scripts/peak-window.mjs check [--json] [--force] [--deferrable] [--headless]
                                   [--session <id>] [--at <ISO>]
  exit 0 = allow · 2 = usage · 3 = defer (caller parks / re-invokes)
node scripts/peak-window.mjs park ...   # canonical wait; emits NOTHING
  exit → JSON on stdout: {verdict, terminalReason, skipReason, parkId, parkMs, resumeAt, windowsSource}
subcommands: windows [--markdown] | classify-keys | defaults | plan | park | force | force-clear | status | emit
```

**Precedence** (each rung a *distinct* input):

| Order | Input | Effect |
|---|---|---|
| 0 | `peakQueue.enabled === false` **or** `PEAK_DISABLED=1` | allow, `peak_skip` reason `disabled` |
| 1 | `--force` / `PEAK_FORCE=1` / live marker / per-dispatch **`force: true`** | allow, `peak_bypass` with actor |
| 2 | `PEAK_DEFERRABLE=1` / `=0` | explicit both ways |
| 3 | `--deferrable` | per-dispatch opt-in (`deferrable: true`) |
| 4 | `--headless` | caller-supplied `isPrintMode(env, argv)` verdict |
| 5 | default | interactive parent → allow (D4 banner only) |

Rung 1's per-dispatch `force: true` is a real tool parameter on both `task` and `subagent` (with a test asserting
per-dispatch bypass) — without it, a nested park would be unreleasable, since the whole `PEAK_*` family is stripped
from children (§2.5).

**Runway (indicator (a)).** `minRunwayMin` default **15**: defer also when `now + minRunwayMin >= windowStart`. A
runway defer is a `peak_defer` carrying **`deferReason: short-runway`**, and its **`resumeAt` is the window *end***
(04:00), not the triggering boundary (01:00) — parking "until the boundary that caused the defer" would resume
*inside* the window and pay 2×.

**Flap guard (`minPauseMin`, default 15) — the quantity is defined.** *Park duration* = `resumeAt − now`. Rule:
**park only if `min(remainingPeak, maxParkMin) ≥ minPauseMin`; otherwise proceed and log `peak_skip` reason
`min-pause`.** This resolves v4's undefined "remaining peak time", which under one reading killed the marquee
runway case (10 min to `windowStart`) and under the other could never fire at all. It also fixes the ordering
against the cap: the guard is evaluated on the **effective** duration, so `maxParkMin < minPauseMin` is a
`min-pause` skip rather than a park that immediately cap-expires. Ownership: **#634 owns the pre-dispatch
threshold; #782 owns the mid-flight one.**

**The wait algorithm.** Sleep in ≤60 s chunks, **re-derive** the boundary each tick, race the abort signal and poll
the force marker every `PEAK_POLL_MS` (default 30 s; **injected** so the force-mid-park test is deterministic),
enforce the bound from a **monotonic** elapsed source — bash has none portable, so the named source is
`python3 -c 'import time; print(time.monotonic())'`. **`PEAK_MAX_PARK_MIN=0` ⇒ do not park: proceed + `peak_skip`** —
pinned identically in the engine and the helper, and explicitly **differing** from `wait-for-load.sh`'s `0 = forever`.

**Terminal/transition rules:**

| Situation | Rule |
|---|---|
| **Cap expires inside a window** | the dispatcher proceeds; terminal is **`peak_skip` reason `max-park`**, never `peak_resume`. **Reachable example (v4's was impossible — 05:00 UTC is in the off-peak gap, and a 05:45 runway park resumes at 10:00 = 255 min < the 270 default):** a park started at 05:45 with an operator-set `PEAK_MAX_PARK_MIN=120`, or a park straddling 03:30 → 06:30 across the gap. **At the 270 default this rule is unreachable without a clock step or a lowered cap**, and the test injects one. |
| **Source becomes `unresolved` mid-park** | **the last successfully resolved window is retained for the park's duration**; `unresolved` may not *shorten* an already-started park. Logged; one terminal event. |
| **Forward clock step past `resumeAt` into window 2** | the loop **re-classifies** each chunk and parks to the **new** `resumeAt`. (Backward is the benign direction and must not make the bound unreachable.) |
| **Abort mid-park** | terminal `peak_abort` with `terminalReason: aborted` — see the taxonomy (§2.5). |
| **Force released mid-park** | terminal `peak_bypass` carrying the released **`parkId`** and actor (§2.5). |

**Enclosing-bound headroom — the liveness ceiling is folded into the deadline.** v4 propagated only the wall-clock
deadline and deferred liveness to a test. **E7 proves that cannot work**: the kill is on **tool age**, so a park
longer than the enclosing `tool-stall` bound **is** cut no matter how fresh the markers are — AC6 as written
required a test that must fail. So:

| Field | Meaning |
|---|---|
| Unit | **absolute epoch-ms deadline** |
| Value | `min(enclosing wall-clock deadline, enclosing liveness deadline)`, where the liveness deadline = the enclosing dispatcher's `startedAt + (turnActive ? toolStallMs : min(toolStallMs, heartbeatTimeoutMs))` |
| Sentinels | **absent** = no enclosing bound ⇒ park (bounded by `PEAK_MAX_PARK_MIN`); **`0`** = unbounded and is **excluded from the `min`** (it must not collapse a real inherited deadline to "no bound") |
| Nesting | each level passes down `min(inherited, its own)` |
| Check | park only if `parkMs + workBudget < (deadline − now)`, where `workBudget` is a named fraction of the **remaining** time (`PEAK_HEADROOM_FRACTION`, default 0.25) — the bound is not propagated, so a fraction-of-bound formulation was uncomputable; the default is re-derived so that a 270-min park against the 6 h cap is a **deterministic pass**, not an exact tie |
| Excess | insufficient headroom ⇒ `peak_skip` reason `no-headroom`, proceed loudly (never park past the ceiling) |

Because the ceiling is now a *deadline*, activity markers are a **secondary** defence: the park still emits the
existing nonce-bearing `[task-heartbeat]` ticks (the child's `setInterval` at `task-heartbeat.ts:411` fires
independently of provider calls; the test **asserts** this rather than assuming, and the named fallback is a
synthetic `[task-heartbeat] tick nonce=…` line). The fake `pi` stub must **emit nonced heartbeats on stderr** — the
existing `sleep 120` stubs emit none.

**Marker skew.** A safety escape must not fail closed on clock noise: the marker's `ts`/`expiresAt` are compared
with a **±120 s tolerance** (a marker is rejected as "future" only beyond that), with a same-instant write→poll
test. Default TTL **60 min**.

**`scripts/wait-for-peak.sh` is a pure pass-through** (banner → invoke `park` → forward its structured exit). It
re-decides **nothing** — not force, not the marker, not `PEAK_MAX_PARK_MIN=0` — and it **emits** the events for the
paths it drives (§2.5). A parity test drives it against the engine's `park` for the `0`, force, marker, cap-expiry,
and normal-resume cases, asserting the **exact emitted event** (count + name + `parkId`), not just the sleep
sequence.

### 2.5 Classification, opt-out, and the event contract

**Events join the existing shared contract.** `extensions/shared/audit-log.ts` owns
`~/.pi/agent/audit/gate-events.jsonl`; a `forced` peak bypass *is* a gate bypass, and the file already carries
high-volume operational events (E13).

- Extend `GateEventName` with **`peak_defer | peak_resume | peak_bypass | peak_skip | peak_abort`**, **backfill the
  7 live names + `gate_block_parse_failure`**, and add a **typed emit helper**. The fixture test's sample is the
  **producer-emitted** name set (a grep of `appendJsonl({ event: … })` plus `vgate.sh`), not the live log alone.
- **One JSONL serializer for scripts-side writers.** `scripts/vgate.sh` and `scripts/wait-for-peak.sh` cannot import
  the TS union (E9/E13). Rather than duplicate `vgate.sh`'s raw python heredoc a third time, the engine exposes
  **`emit --json`** and those two scripts **invoke it** — so there is exactly one field-shape definition. Both are
  declared as its scripts-side callers, and the roster test covers all three writer groups.
- **Emission owner: the callers, on transitions only.** The **callers** (the two preflights + `wait-for-peak.sh`)
  write exactly one `peak_defer` at park start and exactly one terminal event at exit; **`park` and `check` write
  nothing.** A test drives a multi-chunk park with a **marker-emitting fake `pi`** and asserts exactly one pair
  with the real `parkMs` and no engine-written rows.
- Fields: **`parkId`** (a uuid, **required** for pairing — two dispatches from one session interleave rows, so
  "the next terminal after a defer" silently mis-assigns durations), **`sessionId`**, `resumeAt`, `parkMs`,
  `window`, `deferrable`, `deferReason`, `skipReason`, `terminalReason`, `source`, `actor`.
- **Orphans.** A `SIGKILL`ed parker leaves an unpaired `peak_defer`: Task 2.7 prints it as
  `unterminated_peak_defer`, **counts it in the defer count**, and **excludes it from the duration distribution**
  (both denominators stated and asserted — v4 defined neither).

**The taxonomy — every path has a row** (v4 left abort and force-release undefined, which broke AC4/AC7):

| Occurred | Event(s) | Fields |
|---|---|---|
| Parked in-window | `peak_defer` → `peak_resume` | — |
| Parked from the runway | `peak_defer` → `peak_resume` | `deferReason: short-runway` |
| Did not park: disabled / unresolved / malformed marker / no headroom / cap-0 / **min-pause** | `peak_skip` | `skipReason` ∈ `disabled` \| `unresolved` \| `marker-malformed` \| `no-headroom` \| `max-park` \| `min-pause` |
| **Aborted mid-park** | `peak_defer` → **`peak_abort`** | `terminalReason: aborted` |
| **Force released mid-park** | `peak_defer` → **`peak_bypass`** | `parkId` (the released one), `actor` |
| Operator bypass, not parked | `peak_bypass` | — |

A park therefore always has exactly **one** terminal event, paired on `parkId` — so AC7 is statable for the paths
the abort/force tests exercise, and a single park contributes to **exactly one** of the defer-duration
distribution or the skip histogram (tested).

**The force marker — one writer, enforced, and part of a declared family.** The engine CLI is the only writer;
`/peak force|off` is a **driver** that shells out (argv-asserted). Enforcement is §2.2's marker sub-rule, now
**family-wide** (E15): the repo has three dialects — `main-worktree-guard`'s `~/.pi/agent/.allow-main-edits`
(15-min, mtime TTL, non-atomic), `sequence-enforcer`'s `/tmp/parallel-check-force.json` (60-min, content `ts`,
hand-written, the operator escape the skills document), and this plan's `~/.pi/agent/peak-force.json` (60-min,
session-scoped, atomic). **v5 declares the inventory in the guard and records the deferred unification with a named
owner** (§14 D-1, §15 R-1) — the unification itself is out of scope here because it would retrofit a shipped,
non-atomic writer.

Marker: `~/.pi/agent/peak-force.json` = `{ ts, expiresAt, scope: "session"|"host", sessionId?, actor, cwd }`,
per-writer temp (`peak-force.<pid>.<rand>.tmp`) + atomic rename, non-destructive reads, **60-min default TTL**.

| Marker failure mode | Behaviour |
|---|---|
| write racing a poll | atomic publish; reader re-reads on parse failure and **never unlinks** |
| two concurrent writers | distinct temp names ⇒ the result is always one complete document |
| malformed after re-read | absent; `peak_skip` reason `marker-malformed` |
| `ts` in the future | rejected **only beyond ±120 s skew** |
| expired | absent |
| `scope:"session"` + foreign `sessionId` | ignored |
| no session id (bash wrapper / engine subprocess) | `scope:"host"` accepted, logged loudly |

Session identity at the callers: `ctx.sessionManager.getSessionId?.()` — **the `task` tool's `execute` gains the
optional 5th `ctx` parameter** (the `ToolDefinition` signature is
`(toolCallId, params, signal, onUpdate, ctx)` and `wrapToolDefinition` injects it; v4 correctly identified that
`:3235` ignores it). Without it a session-scoped `/peak force` cannot release a `task` park (breaking indicator
(c)) and Task 2.7's join drops those rows. The ctx-absent branch is tested by **direct invocation**, since for a
registered tool the runner always injects `ctx`. `PI_SESSION_ID` is **never** used as a fallback — the repo
explicitly treats it as a misattribution channel (`extensions/sequence-enforcer/index.ts:365–372`).

**Child env: nothing may leak — from the right home.** The strip set is declared in
**`extensions/shared/child-env.ts`** (loader-skipped, the `audit-log.ts` pattern), which both strip sites *import*.
v4 placed this in `scripts/peak-window.mjs` as an "engine export", which is **unimplementable** — §2.1 forbids the
cross-tree import, so the implementer would have had to hand-copy the list (the very duplication the change exists
to remove). The engine remains the **reader** of those keys and exposes them as **data** (`defaults --json`) for the
guard's key-set parity test. The set covers the whole `PEAK_*` family (`PEAK_FORCE`, `PEAK_DEFERRABLE`,
`PEAK_DISABLED`, `PEAK_NOW`, `PEAK_SLEEP_MS`, `PEAK_POLL_MS`, `PEAK_WINDOWS_FILE`, `PEAK_WINDOWS_JSON`,
`PEAK_MIN_RUNWAY_MIN`, `PEAK_MAX_PARK_MIN`, `PEAK_MIN_PAUSE_MIN`, `PEAK_HEADROOM_FRACTION`, `PEAK_NOTIFY`,
`PEAK_AUDIT_FILE`), with per-interface additions kept separate (`TASK_HEARTBEAT*` for `subagent`; the forced
`ELDATO_SKIP_VGATE`/`ELDATO_SKIP_REVIEW_GATE` pair) and **`PEAK_ENCLOSING_DEADLINE_MS` the only non-stripped
`PEAK_*`**. A cross-interface test asserts both surfaces produce the same `PEAK_*` key set and that the child env
contains no other `PEAK_*` key. **A strip-time failure fails CLOSED** (a frozen hardcoded fallback list), never
open — an empty strip list would leak the whole family.

**The `bash`-tool child surface.** `builtin-tools` has a **third** child-env surface (the bash tool), which v4 did
not scope. It is handled the same way (same shared list, plus deadline propagation), and a nested test
(`task → bash → pi → task`) asserts no `PEAK_FORCE`/`PEAK_WINDOWS_JSON`/`PEAK_SLEEP_MS` inheritance and a
grandchild headroom computed against `min(grandparent, parent)`. Bare `pi -p` by hand remains the accepted residual
(§7).

### 2.6 Config — behaviour only, never windows

```jsonc
"peakQueue": { "enabled": true, "minPauseMin": 15, "maxParkMin": 270, "minRunwayMin": 15,
               "headroomFraction": 0.25, "notify": "banner" }
```

- **Precedence:** `PEAK_*` env > `~/.pi/agent/settings.json` `peakQueue` > engine defaults; the engine has a
  `--settings`/`PI_SETTINGS` seam. The env↔key map is **complete**, with its one inversion stated: `enabled` ↔
  `PEAK_DISABLED` (inverted), `minPauseMin` ↔ `PEAK_MIN_PAUSE_MIN`, `maxParkMin` ↔ `PEAK_MAX_PARK_MIN`,
  `minRunwayMin` ↔ `PEAK_MIN_RUNWAY_MIN`, `headroomFraction` ↔ `PEAK_HEADROOM_FRACTION`, `notify` ↔ `PEAK_NOTIFY`.
- **`enabled:false` is a legal value — the guard validates *type*, not the boolean.** Rollback is `enabled:false`
  (config edit) **or** `PEAK_DISABLED=1` (env), both legal.
- The guard **BLOCKs a `windows`/`peakMultiplier` key** and asserts **both** that the shipped block's *numeric*
  keys equal the engine's documented defaults **and** that its **key set** matches (`defaults --json`) — key-set
  drift was the uncovered half.
- **The interpreter is the established `PI_NODE_BIN`, not a new `NODE_BIN`.** The probe order
  `PI_NODE_ROOT` glob → `PI_NODE_BIN` → `command -v pi` already exists (`probe-frontmatter-fixtures.mjs:43–52`,
  documented `check-skill-lint.oracle.test.mjs:21`, honoured `install-launchd.sh:86–87`); inventing a second name
  for the same job is the duplication hazard, and an operator who sets `PI_NODE_BIN` would silently get a
  PATH-dependent `node`. **Resolution order and missing-node behaviour are stated:** resolve via `PI_NODE_BIN`,
  else the pi bundle glob, else `command -v node`; if none resolves, the **key-set/type** checks still run and the
  **value parity** check WARNs and is skipped (never BLOCKs pre-commit on a node-less machine) — with a test for
  exactly that (`PI_NODE_BIN` unset + empty `PATH`), plus a value-mismatch test for the node-available path.
- **Guard semantics:** any `settings.json` *content* violation is a **BLOCK on every copy**; only a **missing**
  file WARNs (`scripts/check-cost-config.sh:218–232`).
- **Nine settings fixtures must be regenerated:** `tests/fixtures/cost-config/{clean,clean-minified,missing-models}/settings.json`
  **and all six** `backdoor-{settings,retry,compaction-disabled,store,models,minified}/settings.json`.

### 2.7 Architecture

```
            ┌──────────── scripts/peak-window.mjs  (single PRODUCTION source + CLI) ────────────┐
            │ window resolver (env → ledger → expiring bootstrap; declared exception + trips)    │
            │ integer hour-of-week classification (dow*24+h) · classify-keys · plan(now)         │
            │ premium arithmetic · park (canonical wait; emits NOTHING) · force marker (atomic)  │
            │ defaults --json · emit --json  (data, never a cross-tree import)                   │
            └───┬──────────────┬──────────────────┬──────────────────────┬─────────────────────┘
                │              │                  │                      │
   (1) INSTRUMENT│  (2) LAUNCH GATE │      (3) BATCH PATH        provenance
                │              │                  │                      │
   session-postmortem.sh   builtin-tools task   epic-executor step    fleet-cost-report.sh
   + hourlyUtc (msg/comp)  subagent tool         (deferrable:true)     (d) split + reconcile
   + integer keys          + peak-park.ts        + wait-for-peak.sh    + tear/base/source line
   + session_id (+unverified) + child-env.ts     + engine `emit`       + launch + event segments
   + n_bad/n_lines/n_bytes  + deadline+liveness  + deadline propagation
                │              │                  │                      ▲
                │              └──────────┬───────┴──────────────────────┘
                │                         ▼
                └──────────► ~/.pi/agent/audit/gate-events.jsonl   (shared audit-log contract;
                             CALLERS emit on transitions only, via ONE serializer:
                             peak_defer | peak_resume | peak_bypass | peak_skip | peak_abort)
```

---

## 3. Phases, and the parallelism map

| Task | Depends on | Can run in parallel with |
|---|---|---|
| 1.1 engine | — | 1.2 |
| 1.2 parser | — | 1.1 |
| 1.3 report `(d)` | 1.1, 1.2 | — |
| 1.4 farm + CI wiring | 1.1, 1.3 | 2.1 |
| 2.1 engine `plan()`/marker/guard/park helper | 1.1 | 1.4 |
| 2.2 `wait-for-peak.sh` (+ CI steps) | **2.1, 1.4** | — (owns the CI edits) |
| 2.3 `extensions/peak-gate` + registration | **2.1, 2.2** | 2.4, 2.5 |
| 2.4 `task` preflight | 2.1, 1.4 | 2.3, 2.5 |
| 2.5 `subagent` preflight | 2.1, 1.4 | 2.3, 2.4 |
| 2.6 policy doc | 2.1, 2.4, 2.5 | — |
| 2.7 report event segmentation | 2.1, 1.3, **2.6** | — |
| 2.8 #631 note + sunset trips + follow-up issue | 1.1, 2.1, **2.6** | — |
| 3.1 `epic-executor` opt-in | 2.4, 2.5 | 3.2 |
| 3.2 cadence table | **2.6** | 3.1 |
| 3.3 weekend note (optional) | 3.2 | — |

**Edges that are load-bearing, not cosmetic** (each was a real write-write race or read-before-create found in
cycles 3–4):

- **2.2 owns the CI edits.** v4 had 2.2, 2.3, 2.4 and 2.5 *all* editing `ci.yml`/`ci-main.yml` while declaring
  several of them parallel — the same race §3 said it had fixed. 2.2 now owns the shared CI/farm edits, adds the
  new extension steps on behalf of 2.3/2.4/2.5, and the later tasks' `Files` say so.
- **2.3 depends on 2.2** (the CI step list is written once).
- **2.4/2.5 keep `1.4`** — but with the *correct* rationale (they add test files that `1.4`'s CI wiring must
  include, and they touch the same `ci-main.yml` block), not v4's false claim that they edit `fleet_srcs`.
- **2.6 is not parallel with 2.7** (2.7 edits a subsection of the file 2.6 creates — v4's table still said
  parallel).
- **2.8's `Files` no longer include the policy doc** (2.6 owns it and already documents the trips); 2.8 writes the
  guard only. `Depends on: 2.6`.
- **3.3's parallel list drops 3.2** (it depends on it).
- **`--audit-file` moved from Task 1.3 to Task 2.7** (its only consumer).

Phase 1 lands first and is independently useful: it is the gate for #782 and needs no gate infrastructure.

### 3.1 Phase 1 — the instrument (deliverable 1)

#### Task 1.1: `scripts/peak-window.mjs` — pure engine + CLI

**Intent:** one *production* definition of the window/classification/arithmetic/provenance, plus the declared
independent oracle.
**Acceptance:** `windows --json`; `windows --markdown`; `defaults --json`; `classify-keys --json` (integers);
`classify --at <ISO>`; **all four outcomes** (`env`, `ledger`, `builtin-bootstrap`, `unresolved`) with their
gate/report behaviour; the bootstrap is provably unused when a ledger resolves, is **absent** once a ledger exists
at either location, and `BOOTSTRAP_EXPIRES_ON` BLOCKs past 2026-12-31 (UTC) — all as **no-ops when no ledger
exists anywhere**; `check-peak-single-truth.sh` exists with its allowlist, sub-rules 1–3 (**including the marker
family inventory**), and a **both-direction self-test** that passes on the current tree (including
`pi-reap-idle.test.sh`'s `01:00` occurrences).
**Files:** Create `scripts/peak-window.mjs` · `scripts/peak-window.test.mjs` · `scripts/check-peak-single-truth.sh`.
**Steps:** failing unit tests (membership; both windows; the `04:00–06:00` gap; `resumeAt` across the gap;
**two-window re-entry**; the **Sun-20:00-EST-is-peak / Fri-20:00-EST-is-off-peak** pair; the **pre-window runway**
case `--at 2026-09-14T00:50:00Z` → `resumeAt === 2026-09-14T04:00:00Z`, `minutesUntilOffPeak === 190`; an invalid
`PEAK_WINDOWS_FILE` falling through); implement; add the resolver + the guard + its self-test; commit.

#### Task 1.2: shared parser — integer buckets, `first_ts`, `session_id`, tear signal

**Intent:** make the timestamps survive into the row, cover compaction spend, and give the report its real signals.
**Acceptance:** `--summary` rows gain `hourlyUtc` (kind-aware, integer keys), `first_ts`, `ts_unknown`,
**`session_id` + `session_id_unverified`** (basename-derived, `rsplit("_", 1)`; the `type:"session"` record is a
**cross-check, not a precondition** — 11/346 live files have none, and they must **not** become error rows),
`n_lines`, `n_bytes`, `n_bad`; existing keys unchanged and additive (the other two consumers use named access only
— `scripts/watch-truncation.sh:176`, `scripts/session-postmortem.sh:229–250`); the schema comment (`:44–62`)
documents the new fields; the double-entry identity holds exactly.
**Files:** Modify `scripts/session-postmortem.sh:44–62, 64–160` · Modify `scripts/session-postmortem.test.sh`.
**Steps:** failing tests (buckets across two hours; a straddling boundary; missing/`"x"` timestamp → `ts_unknown`;
`first_ts`; **a realistic `<ts>_<uuid>.jsonl` basename**; **a header-less file whose first record is
`type:"message"`** → usable `session_id`, not error-tagged; **a disagreeing `type:"session"` id** →
`session_id_unverified`; a compaction record bucketed under `comp`; a truncated final line → `n_bad`); implement;
confirm all three consumers pass; commit.

#### Task 1.3: report — "(d) hour-of-day peak/off-peak split"

**Intent:** the go/no-go number for #782, with the arithmetic right (E1) and the base honest.
**Acceptance:** `## (d)` prints the recorded split, the adjusted split, the premium, the launch segmentation (per
the §2.3 predicate), the compaction share, `ts_unknown`, `n_bad`, **`live-file-skipped: N (partial read)`**, a
per-hour UTC table, and the one-line provenance/base token. Classification is **ISO-instant equivalence** with the
engine (§2.1). **Every `(d)`/events failure path maps to rc 2** — including zero/undefined totals, a **zero-session
scan**, and any transport/spawn failure — each with its **own stable token** (`windows-source: <unresolved|env>`,
`RECONCILIATION MISMATCH`, `TEAR`, `transport-failed`, `instrument: no-data`). The payload travels via **stdin**
(§2.3), never argv. A **tear** fires only on shrink/in-place change; growth is `live-file-skipped`. The frozen
`--usage-rows` field list is recorded (#631 §5 / WS5.3).
**Files:** Modify `scripts/fleet-cost-report.sh` (render block, gates, transport, interpreter) ·
`scripts/fleet-cost-report.test.sh` · `scripts/fleet-cost-weekly.test.sh` · **Modify `scripts/fleet-cost-weekly.sh`
*and* `scripts/cron-quality-gates.sh`'s `fleet_gate()`** — both are rc-2 consumers; **every rc-2 producer is
enumerated** and classified: the **instrument** tokens (above) escalate, the **pre-existing environment** rc-2
paths (`:74, :82, :88, :92, :93, :135`, and the `ERR_COUNT > 0` data-absence gate `:144–162`) keep their current
"env" handling, and **`instrument: no-data` is a declared non-escalating loud class**. · Modify
`docs/ops/cost-config-policy.md`.
**Steps:** fixtures for hour/launch/unknown/compaction/**tear (shrink, by mutation between passes)**/
**live-file (grow → skipped, cost included, partial-read line)**/**zero-total**/**zero-session**/**oversized**/
**transport-failure**/**un-tokened env rc 2**; assertions for each number, the reconciliation mismatch, the tear
predicate **both ways**, the tokens, and the driver decision per class; implement; verify no new exit-1 path;
commit.

#### Task 1.4: farm + interpreter + CI wiring

**Intent:** the instrument must run where it runs — under launchd, from the farmed copy (E9) — and be gated in CI.
**Acceptance:** `pi-bootstrap/setup.sh`'s `fleet_srcs` gains **`peak-window.mjs` and
`check-peak-single-truth.sh`** (Phase 1 only — **the `rates` farm is #631's**, referenced not duplicated); the
farmed report resolves the **same `windows-source`** the in-session gate resolves; the interpreter is resolved via
the **existing `PI_NODE_BIN`** convention with empty `PATH` as the fallback contract, asserted in the farm-parity
test; an engine failure maps to **rc 2 with `transport-failed`**; the farm test runs from a farm-shaped dir with
`AGENT_INFRA_PATH` unset. New bash steps land in **`ci-main.yml`'s `script-validate` block** (E12) and
`ci.yml`'s `verify` job — **never** the pinned `test-command` scalar: `node scripts/peak-window.test.mjs`,
`bash scripts/check-peak-single-truth.sh`, `bash scripts/session-postmortem.test.sh`,
`bash scripts/watch-truncation.test.sh`, `bash scripts/fleet-cost-report.test.sh`,
`bash scripts/fleet-cost-weekly.test.sh`, `node scripts/load-gate.test.mjs`.
**Files:** Modify `pi-bootstrap/setup.sh:281–304` · `pi-bootstrap/tests/test-setup-no-nesting.sh` ·
`.github/workflows/ci.yml` · `.github/workflows/ci-main.yml` · `scripts/fleet-cost-report.sh`.
**Steps:** farm basenames + parity assertion; CI steps; run the farm, empty-`PATH`, and `PI_NODE_BIN` tests; `bash
-n` the touched shell files; commit.

**Phase 1 verification (independent):** on a **frozen** corpus copy, run
`--sessions-dir <copy> --days 30` (note: the **335-of-346** filename-date selection, E10) and compare against the
committed oracle (§6): the headline within **±0.5%** **and** the key set **equal**. A live-appending corpus is not
a reproducible oracle.

### 3.2 Phase 2 — the launch gate (deliverable 2)

#### Task 2.1: engine — `plan()`, precedence, flap guard, marker, park helper, shared child-env

**Intent:** extend the engine from *describing* to *deciding* and *waiting*, with one production source and no
cross-tree import.
**Acceptance:** `plan(now, {...})` implements all six rungs (incl. the per-dispatch `force` param), the **defined**
flap guard, and the runway; `park` implements the canonical loop (chunked re-derivation, abort/marker race,
monotonic bound, `PEAK_MAX_PARK_MIN=0`, `/mid-park rules) and returns the **structured exit**; the marker has one
writer, per-writer temp + atomic rename, a 60-min TTL, ±120 s skew tolerance, and non-destructive reads;
`extensions/shared/peak-park.ts` and **`extensions/shared/child-env.ts`** exist (import-only), with parity tests
(chunk/bound sequence vs `park`; cross-interface strip-set equality); `emit --json` and `defaults --json` exist;
the audit-log union is extended, the 7 log names + `gate_block_parse_failure` backfilled; the config guard
validates type, BLOCKs a `windows` key, and asserts numeric **and key-set** parity via `PI_NODE_BIN` with the stated
missing-node behaviour; **all nine** fixtures regenerated.
**Files:** Modify `scripts/peak-window.mjs` · `scripts/peak-window.test.mjs` · Create
`extensions/shared/peak-park.ts` + `peak-park.test.ts` · Create `extensions/shared/child-env.ts` +
`child-env.test.ts` · Modify `extensions/shared/audit-log.ts` · Modify `pi-bootstrap/pi-config/settings.json` ·
Modify `scripts/check-cost-config.sh` + `tests/cost-config/run.sh` · Modify the **nine**
`tests/fixtures/cost-config/*/settings.json` · Modify `scripts/check-peak-single-truth.sh`.
**Steps:** failing unit tests per rung, the flap guard **on the effective duration** (incl. `maxParkMin <
minPauseMin`), the runway boundary **+ the pre-window `resumeAt` = window end**, `PEAK_MAX_PARK_MIN=0`, the
cap-expiry terminal (**with an injected reachable construction**), mid-park `unresolved` retention, the forward
clock step, every marker failure mode (split write; two concurrent writers; TTL boundary; ±120 s skew), the
deadline contract (unset sentinel, `0`-excluded-from-`min`, late dispatch, **the liveness fold**), and
invalid-policy fallback; implement; failing config/audit tests (key-set parity, producer-emitted roster, **strip-set
parity**, **strip-time fail-closed**); regenerate fixtures; run the guard's self-test; commit.

#### Task 2.2: `scripts/wait-for-peak.sh` (pure pass-through) **and the shared CI steps**

**Intent:** give bash batches the canonical park/resume contract without re-deciding anything.
**Acceptance:** exits 0 immediately off-peak; inside a window prints the banner and delegates to
`node … peak-window.mjs park`, **forwarding its structured exit**; re-decides nothing; emits the exact event for
each path it drives via the engine's `emit`; a backward clock step cannot make the bound unreachable and a forward
step into window 2 keeps it parked; `--json` passthrough. **Owns the new CI steps** for 2.3/2.4/2.5 (the shared
`ci.yml`/`ci-main.yml` edits), so those tasks do not race. **No `cron-quality-gates.sh` *parking* change** (E5) —
its **rc-2 consumption** is Task 1.3's concern.
**Files:** Create `scripts/wait-for-peak.sh` · `scripts/wait-for-peak.test.sh` · Modify `pi-bootstrap/setup.sh`
`fleet_srcs` + parity test · Modify `.github/workflows/ci.yml` / `ci-main.yml` (**all** new steps, including 2.3's
`npx tsx extensions/peak-gate/index.test.ts`, 2.4's `peak-gate-integration.test.ts`, and 2.5's subagent park
cases — **explicit lines**, since no glob collects a new `.ts` in an existing dir).
**Steps:** failing tests (`PEAK_NOW`; `PEAK_SLEEP_MS`; `PEAK_POLL_MS`; `PEAK_MAX_PARK_MIN=0`; backward/forward
steps; the **event emission per path**; wrapper↔engine parity); implement; add CI; commit.

#### Task 2.3: `extensions/peak-gate` — `/peak` command, banner, registration

**Intent:** the in-session one-step opt-out (D3) + notification (D4), reaching an actual machine.
**Acceptance:** `pi.registerCommand("peak", …)` — the **bare** name (`registerCommand` stores it verbatim and input
is resolved after `text.slice(1)`; `"/peak"` would be reachable only as `//peak`) with `status|force|off`;
`/peak force` **spawns the engine's `force` subcommand** (argv-asserted), never writes the marker; `status` prints
the window, `windows-source`, and marker TTL; one latched banner per interactive session;
`check-pi-config-extensions.sh` passes.
**Files:** Create `extensions/peak-gate/index.ts` · `index.test.ts` · `package.json` (pin `== PI_VERSION_PIN`) ·
Create `pi-bootstrap/pi-config/extensions/peak-gate` (symlink) · Modify `manifest.json` ·
Modify `pi-bootstrap/tests/test-setup-no-nesting.sh` · Modify `scripts/check-skill-lint.test.mjs` §(h)/(i) if the
pin/stamp maps change. **The CI step is added by Task 2.2** (this task's own `Files` do not touch the workflows).
**Steps:** failing tests (registration + handler effects via a temp `HOME`/audit file; one-banner latch; argv); run
`check-pi-config-extensions.sh` and `check-skill-lint.test.mjs`; commit.

#### Task 2.4: `task` preflight (builtin-tools)

**Intent:** enforce the gate on the primary dispatch surface, with a real escape while parked.
**Acceptance:** preflight at the **task tool's `execute` entry** (`:3235`), before the `spawnSubAgent` call
(`:3441`/`:3532`). A deferrable dispatch inside a window **or its runway** sends **zero provider requests** and
spawns no child pid before `resumeAt`, then resumes automatically; abort mid-park ⇒ `peak_abort`; force mid-park ⇒
`peak_bypass` with the `parkId`; the child's bound anchors are unaffected; the **deadline + folded liveness
ceiling** (§2.4) is honoured with `PEAK_HEADROOM_FRACTION` — **insufficient headroom skips, it does not park past
the ceiling**; the whole `PEAK_*` family is stripped via `extensions/shared/child-env.ts` (failing **closed**),
with `PEAK_ENCLOSING_DEADLINE_MS` the only survivor; **`execute` gains the optional 5th `ctx`** and passes a real
`--session`; the per-dispatch `force` param works; an engine subprocess failure **fails open with a loud event**.
**Files:** Modify `extensions/builtin-tools/index.ts` (`:3235` preflight + `ctx`; strips; deadline injection) ·
Modify `extensions/builtin-tools/builtin-tools.test.ts` · **Create
`extensions/builtin-tools/peak-gate-integration.test.ts`** (a **marker-emitting, nonce-bearing** fake-`pi` stub
modelled on `extensions/subagent/timeout-integration.test.ts:158–175` — *not* `subagent-integration.test.ts`, which
spawns a real `pi`). **CI step added by Task 2.2.**
**Steps:** failing tests (spawn-count 0→1; runway; abort mid-park; force mid-park; deadline unset / `0` / late /
liveness-fold; the full strip set + fail-closed; `--session` non-empty + ctx-absent by direct invocation;
`PEAK_NOTIFY=1` in the parent); implement; re-run the builtin-tools suites; commit.

#### Task 2.5: `subagent` preflight

**Intent:** close the second dispatch surface — the one `epic-executor` uses (E6).
**Acceptance:** preflight at the **subagent tool's `execute` entry** (`:1402`), before the `runSingleAgent` calls
(`:1488`/`:1580`/`:1639`) — **not** inside `runSingleAgent` (`:823`, spawn `:1013`), where it would park once per
task. `subagent({tasks:[…], deferrable:true})` parks **once per batch**; `taskTimeout`/backstop are armed at spawn;
the deadline/liveness contract is honoured; the strip set comes from the shared module and a **cross-interface
parity test** asserts both surfaces agree.
**Files:** Modify `extensions/subagent/index.ts` · **`extensions/subagent/index.test.ts`** (park cases — **CI line
added by Task 2.2**) · `extensions/subagent/timeout-integration.test.ts`.
**Steps:** failing tests (one park per batch; uncharged child bound; headroom skip; strips; cross-interface parity);
implement; run the subagent suites; commit.

#### Task 2.6: policy doc

**Intent:** pin the operator contract (the `load-policy.md` role for the load gate).
**Acceptance:** `docs/ops/peak-queue-policy.md` carries: the **generated** window table + the **four** outcomes with
each one's gate/report behaviour; the split arithmetic + reconciliation identity + the integer-key **and day-base**
note; the tear's **real** scope (mid-pass mutation only; static truncation via `n_bad`/the watch) and the
live-file inclusion rule; the exit-code contract with **every token** and its **escalating / non-escalating**
class; the six-rung precedence table + the flap guard's defined quantity; the **event taxonomy table** (incl.
abort/force-release); the env table with the `enabled`↔`PEAK_DISABLED` inversion and **every key**; the wait
contract (abort, headroom, the folded liveness ceiling, `PEAK_MAX_PARK_MIN=0`, the cap-expiry /
mid-park-`unresolved` / forward-clock rules, the monotonic source, `PEAK_POLL_MS`, the ±120 s skew); the marker
failure-mode table + the **marker-family inventory**; the **sunset trips** (scope, date, clock, post-expiry runtime
behaviour); the **#631 §5 supersession** note; the cadence inventory (E5) incl. why the local quality gates are not
parked; cross-links to #631/#782/#209. Frontmatter passes `check-doc-affiliation.cjs`.
**Files:** Create `docs/ops/peak-queue-policy.md` (owner of every section; Task 2.7 appends only its `(d)`-events
subsection) · Modify `docs/ops/cost-config-policy.md` · Modify `AGENTS.md`.
**Steps:** write; affiliation check; window-table generation test; commit.

#### Task 2.7: report consumes the events — the metric the corpus can actually answer

**Intent:** event-driven segmentation **without** fabricating a saving.
**Acceptance:** `(d)` gains the **`peak_defer` count and `parkMs` distribution, paired on `parkId`** (interleaved
parks and orphans handled explicitly — an orphan is printed as `unterminated_peak_defer`, **counted** in the defer
count, **excluded** from the distribution); the **`peak_skip.skipReason` + `peak_defer.deferReason` histogram**
(one contribution per park); the **deferrable vs unmarked split of *parent-session* peak spend**, joined on
`sessionId` (only rows with `session_id_unverified: false`), asserted to **match a non-zero count** on a fixture
with realistic production shapes, plus a printed `unjoined_peak_defer_events` counter; and the labelled
**non-measurement** ("N dispatches parked X minutes out of peak; their own child spend is not in this corpus
(`--no-session`) — the avoided premium is not measurable here; see #690"). **The `--audit-file`/`PEAK_AUDIT_FILE`
seam is added here.**
**Files:** Modify `scripts/fleet-cost-report.sh` (+ the seam) · `scripts/fleet-cost-report.test.sh` ·
`docs/ops/peak-queue-policy.md` (its subsection only).
**Steps:** failing tests against a synthetic event file + corpus (a malformed/truncated event line; two interleaved
parks; an orphan; a `session_id_unverified` row); implement; commit.

#### Task 2.8: #631 note + sunset trips + the `--usage-rows` follow-up issue

**Intent:** retire the exception mechanically once #631 lands, and pay back the contract divergence.
**Acceptance:** the two trips of §2.2 (absence-once-ledger at **either** location; `BOOTSTRAP_EXPIRES_ON` in UTC)
with their no-op-when-no-ledger test; a **correction note to #631 §5** recording the supersession (E14: pausing /
`[PEAK-PAUSE]` / avoided-premium → #782; the interface path); and the `--usage-rows` arithmetic switch as a **real
follow-up issue with a number, an owner, and `Depends on: #631 §5 / WS3.1`** (v4 said "switches" in one section and
"specified as a follow-up" in another, with no issue, no owner, and no detector).
**Files:** Modify `scripts/check-peak-single-truth.sh`.
**Steps:** implement both trips + tests; post the #631 note; file and link the follow-up issue; commit.

**Phase 2 verification (independent):** with injected clock **and sleep**, confirm across both surfaces and the
wrapper that (a) zero provider requests and zero child pids occur before `resumeAt`, (b) resume is automatic,
(c) `PEAK_FORCE=1`/`/peak force` bypass **including while parked** (via the per-dispatch `force` param for nested
parks), (d) interactive sessions and their unmarked dispatches are untouched, (e) a park is **never** longer than
the folded deadline/liveness ceiling — and one that would be is **skipped loudly**, (f) aborting mid-park spawns
nothing and emits `peak_abort`, (g) exactly one terminal event per `parkId`, (h) the pre-window runway case
resumes at the window **end**. Then a live smoke: one real `--deferrable` dispatch inside a window, watched to
completion.

### 3.3 Phase 3 — batch cadence (deliverable 3) — **smaller than assumed**

**Stated plainly:** E5 shows the repo has **no cron cadence worth moving**, and the local quality gates must not be
*parked* (no provider requests). So this phase is (i) the cadence table, (ii) the gate in the real batch path,
(iii) future cadences gate-first. ~0.5–1 day.

#### Task 3.1: `epic-executor` pre-dispatch gate step **with a real opt-in**
**Acceptance:** `skills/epic-executor/SKILL.md` has a mandatory step before the first `subagent({tasks:[…]})`, and
**the skill's own dispatch passes `deferrable: true`** (without it, an interactive orchestrator — the normal launch
mode — never parks, and indicator (d) holds only for headless launches). The step states that the **session** is not
parked while the **batch dispatch** is. `skill-sync` committed; `check-skill-lint.mjs` green.
**Files:** Modify `skills/epic-executor/SKILL.md`. **Steps:** draft + opt-in; lint; `skill-sync`; commit.

#### Task 3.2: cadence policy table
**Acceptance:** every scheduled entry point, its local time, DST-sensitivity, token spend, and verdict — the
deliberate non-moves as decisions. Names `cron-quality-gates.sh`'s `fleet_gate()` as an rc-2 consumer whose
*instrument* handling changed in Task 1.3 while its *schedule* did not.
**Files:** Modify `docs/ops/peak-queue-policy.md`. **Steps:** transcribe E5 with verdicts; commit.

#### Task 3.3 (conditional): weekend slot for heavy batches
**Acceptance:** a documented recommendation (including the Sun-20:00-local trap). No scheduler is built (§10).
**Files:** Modify `docs/ops/peak-queue-policy.md`.

---

## 4. Integration Surface Map

| Surface | Kind | Test layer | Bug-pattern flag |
|---|---|---|---|
| `scripts/peak-window.mjs` (pure + CLI + `park` + `emit`) | process boundary | unit (injected clock **and sleep**) + contract (exit codes / `--json`) | timezone/boundary; an un-injectable park is untestable |
| hour-of-week integer key **and its day base** | **cross-language vocabulary** | **ISO-instant equivalence** (parser key === engine key, per weekday, **and** the verdict) | a duplicated key grammar **or** a Mon=0/Sun=0 shift yields a wrong peak share with all gates green |
| `scripts/session-postmortem.sh` `--summary` | **shared contract, 3 consumers** | unit + regression (all three) | additive-only; silent consumer breakage; `session_id` derivation (header-less 3.2%) |
| `fleet-cost-report.sh` render + reconciliation + tear + tokens + **transport** | report contract | contract + double-entry + tear **both ways** + zero-total + zero-session + **oversized/`E2BIG`** + token classes | metric drift (E8); rc≠2 → bogus weekly issue; rc=2 → hidden refusal; **`E2BIG` → rc 126**; a live file silently excluded from the *number* |
| **`fleet-cost-weekly.sh` + `cron-quality-gates.sh fleet_gate()`** | **rc-2 consumers (2)** | contract: token→escalate vs env→no-file vs `no-data`→loud-no-file | a hidden instrument refusal **or** a false escalation on a quiet week |
| `extensions/shared/audit-log.ts` `GateEventName` | **shared contract, 17 sites + 2 scripts-side callers** | contract (typed emit + **producer-emitted** roster + field-set agreement) | forking a parallel log; an untyped union; a bash writer re-deriving the shape |
| **`extensions/shared/child-env.ts`** | shared contract (import-only) | unit + **cross-interface parity** + **fail-closed on strip-time failure** | the `PEAK_*` family leaking; an empty strip list failing open |
| `~/.pi/agent/peak-force.json` (**+ the marker family**, E15) | file boundary, TTL + session | unit (TTL/session/malformed/future+skew/split write/two writers) + **guard family inventory** | a fourth dialect; a host-wide force disarming other sessions; torn temp; a fail-closed escape on clock skew |
| settings.json `peakQueue` + **nine** fixtures | config | config guard + **`PI_NODE_BIN` numeric + key-set parity** (with missing-node behaviour) + fixture parity (11/13/14) | drift; the forbidden `windows` key; a second defaults copy; a second interpreter name |
| `scripts/rates/deepseek.jsonl` (#631) | external data | resolver + **sunset trips (either location, dated, UTC)** | two window truths; an unreachable ledger under launchd; a stale farm passing the trip |
| `task` preflight (`:3235`) | dispatch boundary | integration (**marker-emitting** fake `pi`) | bound/liveness charged to the park; abort/force with no terminal; **`PEAK_*` leak**; a missing `--session` |
| `subagent` preflight (`:1402`) | dispatch boundary | integration (**marker-emitting** fake `pi`) | N parks per batch; 30-min bound; strip-list divergence from `task` |
| **`bash`-tool child surface** | dispatch boundary | nested test (`task → bash → pi → task`) | inheriting the whole `PEAK_*` family and a stale deadline |
| `wait-for-peak.sh` | bash subprocess | integration (injected clock/sleep) + **parity against `park`** + **exact emitted event** | unbounded wait; a wall-clock bound; a re-decided `PEAK_MAX_PARK_MIN=0`; a missing/duplicated terminal event |
| `pi-bootstrap/pi-config/extensions/peak-gate` + manifest row | runtime registration | `check-pi-config-extensions.sh` + farm parity | ships on no machine; `sync.sh` BLOCK |
| **`pi-bootstrap/setup.sh` `fleet_srcs` + `PI_NODE_BIN`** | runtime path | farm parity | a farmed report resolving a different source than the session |
| `pi.registerCommand("peak")` | host API | unit (handler + argv) | a leading-slash name registering `//peak` |
| **`skills/epic-executor/SKILL.md`** | skill contract | `check-skill-lint.mjs` + reviewed step | a described step with no `deferrable` opt-in |
| **`docs/ops/peak-queue-policy.md` + `AGENTS.md`** | doc | `check-doc-affiliation.cjs` + the generated-table test | a hand-transcribed window table |
| `scripts/peak-window-oracle.mjs` | **declared independent** verification artifact | the frozen-corpus test + the key-set equality assertion | an undeclared second window writer |

## 5. Journey Test Map

### Journey: a deferrable batch launched just before a peak window
1. **Dispatch at 19:50 local** (00:50 UTC — inside the runway) → banner with window, `resumeAt`, the one-step
   escape; nothing spawned → `peak-window.test.mjs` (runway) + builtin-tools integration.
2. **Wait** → zero provider requests, zero child pids; the parent and **enclosing** deadlines intact; a park longer
   than the ceiling is **skipped**, not cut → fake-`pi` integration + headroom/liveness tests.
3. **Operate releases it** → `PEAK_FORCE=1` **or** `/peak force` frees the already-parked dispatch in one step,
   `peak_bypass` with the actor **and the released `parkId`** → force-mid-park integration.
4. **Window ends** → automatic resume exactly once, `peak_resume` with the real `parkMs` → injected clock/sleep +
   one-terminal-per-`parkId` test.
5. **Weekly report** → `(d)` shows the split, the base caveat, the segmentation, the non-measurement, and
   reconciles double-entry → contract + frozen-corpus test.

### Failure Modes

| Failure | Expected behaviour | Test |
|---|---|---|
| Engine subprocess fails / node unresolvable | preflights **fail open** loudly; the report exits **2** with `transport-failed` | integration (missing binary / `PI_NODE_BIN` unset) |
| Strip-time failure in `child-env` | **fails CLOSED** (frozen fallback list) — no `PEAK_*` reaches the child | unit |
| A ledger exists but is unusable | gate fails **open**; report **refuses** (`windows-source: unresolved`); both drivers escalate | resolver + both driver tests |
| A `PEAK_WINDOWS_FILE/JSON` override is set | gate classifies; report **refuses** (`windows-source: env`) | resolver + report |
| Unknown/no timestamp | `ts_unknown`, **counted in** reconciliation, surfaced | parser + report |
| **A file shrinks / changes in place during the read** | `TEAR` → rc 2 + token | report (mutate-between-passes fixture) |
| **A live file grows during the read** | **no tear**; `live-file-skipped`; its partial rows **included** and the base line says `(partial read)` | report (append-mid-read fixture) |
| **A static truncation at a record boundary** | `n_bad` (and `watch-truncation.sh`) — **explicitly not claimed** as a tear | parser + watch suites |
| Zero/undefined total | guarded → rc 2 + token (never `ZeroDivisionError`/rc 1) | report |
| **Zero sessions scanned** | rc 2 + `instrument: no-data`, **loud and non-escalating** (declared class) | report + both drivers |
| **Corpus too large for argv** | stdin transport; a spawn failure → rc 2 + `transport-failed` (never 126) | report (oversized + missing-interpreter) |
| A header-less session file (3.2% of the fleet) | usable `session_id`, `session_id_unverified`, **not** an error row, **not** rc 2 | parser + report |
| Ledger present at the farm but not the repo (or vice versa) | the absence trip passes; the farmed-source parity test catches a stale farm | guard + farm parity |
| `peakQueue` missing / a `windows` key / a key-set drift | BLOCK on every copy (only *missing* files WARN); `enabled:false` **legal** | config guard |
| Marker malformed / split write / two writers / foreign session / expired / **±120 s skew** | non-destructive re-read; complete-document-or-nothing; ignore; absent; accepted within skew | marker tests |
| **Abort mid-park** | immediate resolve, nothing spawned, terminal **`peak_abort`** | integration |
| **Force released mid-park** | terminal **`peak_bypass`** carrying the released `parkId` | integration |
| Clock step **backward** | named monotonic source → bound reachable | wrapper + preflight |
| Clock step **forward into window 2** | re-classification ⇒ parks again to the new `resumeAt` | wrapper + preflight |
| Runway defer **before** the window | `resumeAt` = the window **end** | unit + integration |
| **Cap expires inside the window** (injected cap) | `peak_skip` reason `max-park`, **one** contribution to the histogram | unit + report |
| **Source becomes `unresolved` mid-park** | retain the last good window; not shortened; one terminal | unit |
| **`minPauseMin` flap guard** (effective duration) | `peak_skip` reason `min-pause`; incl. `maxParkMin < minPauseMin` | unit + histogram |
| Insufficient headroom (incl. the **folded liveness ceiling**) | `peak_skip no-headroom`; **never** park past the ceiling | deadline/liveness tests |
| Reconciliation mismatch | rc 2 + token; no split printed as trustworthy | report contract |
| An orphaned `peak_defer` | printed `unterminated_peak_defer`; **counted** in the defer count, **excluded** from the distribution | report (orphan fixture) |

## 6. Test plan per surface

- **Unit (`scripts/peak-window.test.mjs`).** membership; both windows; the gap; `resumeAt` across the gap;
  **two-window re-entry**; the **pre-window runway** case; **Sun 20:00 EST = peak / Fri 20:00 EST = off-peak**;
  **DST** (`TZ=America/New_York`, 2026-03-08 / 2026-11-01); the flap guard **on the effective duration**; the
  runway boundary; multiplier/premium; all six rungs (incl. the per-dispatch `force`); all four sources (incl. an
  invalid env value); bootstrap-unused-when-ledger-resolves + absent-once-ledger (either location) +
  `BOOTSTRAP_EXPIRES_ON` + the no-ledger no-op; marker TTL/session/malformed/future+skew/split-write/two-writers;
  the deadline contract (unset, `0`-excluded, late, **the liveness fold**); `PEAK_MAX_PARK_MIN=0`; cap-expiry;
  mid-park `unresolved`; the forward clock step.
- **Parity.** `peak-park.test.ts` (chunk sequence + bound behaviour vs `park`); `child-env.test.ts`
  (cross-interface strip-set equality; **fail-closed** on a strip-time failure); **wrapper↔engine** for
  `0`/force/marker/cap-expiry/normal-resume **with the exact emitted event**.
- **Cross-language key + day-base equivalence.** ISO instants — one per weekday, both windows, the gap, the
  weekend, and a **non-`Z` offset** timestamp — assert `parserBucketKey(iso) === engineKey(classify --at iso)`
  **and** the `inPeak` verdict from both sides.
- **Contract (`fleet-cost-report.test.sh`).** every `(d)` number; reconciliation mismatch; tear **both ways**
  (shrink fires, grow does not **and** the partial rows are included with the `(partial read)` line); zero-total;
  zero-session; oversized/`E2BIG`; `transport-failed`; the `windows-source` refusals; every **un-tokened
  pre-existing rc-2 path** classified; `--audit-file`; `parkId` pairing + orphan; no new exit-1 path.
  `fleet-cost-weekly.test.sh` + a `fleet_gate()` case: **token → escalate**, **env → no file**, **no-data → loud,
  no file**.
- **Regression.** `session-postmortem.test.sh` + `watch-truncation.test.sh` green (additive-only), incl.
  `session_id` / `session_id_unverified` and the header-less fixture.
- **Integration.** **marker-emitting, nonce-bearing** fake `pi` on `PATH` for both surfaces; spawn-count 0→1;
  runway; abort mid-park (**`peak_abort`**); force mid-park (**`peak_bypass` + `parkId`**); deadline boundaries +
  the liveness fold; one terminal per `parkId`; `--session` non-empty + ctx-absent (direct invocation);
  `PEAK_NOTIFY=1`; the nested `task → bash → pi → task` case; the full `PEAK_*` strip + cross-interface parity.
- **Config.** guard cases (missing block; `enabled:false` legal; invalid `minPauseMin`; a `windows` key → BLOCK;
  numeric **and key-set** defaults mismatch → BLOCK; missing live file → WARN) + **nine** fixtures; the
  `PI_NODE_BIN`-unset + empty-`PATH` case and the value-mismatch case.
- **Registration/farm.** `check-pi-config-extensions.sh`; `test-setup-no-nesting.sh` (engine + guard + link +
  `PI_NODE_BIN` resolvability; the **#631-dependent** ledger row asserted as `builtin-bootstrap` until it lands);
  `check-skill-lint.test.mjs` incl. (h)/(i).
- **Frozen-corpus reconciliation (trust gate).** Copy a corpus; run `--sessions-dir <copy> --days 30` and compare
  against the committed oracle `scripts/peak-window-oracle.mjs`. **The oracle's method is
  `message.usage.cost.total`** — not a top-level `usage` (0 top-level vs 117,770 `message.usage` records), which is
  why the parser reads `u = o.get("usage") or m.get("usage") or {}` (`session-postmortem.sh:117`) — and it
  **mirrors the parser's full predicate verbatim** (`type=="message"` ∧ `role=="assistant"` ∧
  `u.get("input") is not None` ∧ `isinstance(u.get("cost"), dict)`). Peak = UTC weekday Mon–Fri and hour ∈
  [1,4) ∪ [6,10). **Agreement: ±0.5% AND key-set equality**, on the **335-file** `--days 30` selection (E10).
  The launch predicate is the §2.3 one, stated verbatim in the oracle.

## 7. Wiring check (issue-scoping Phase 6)

| Touch point | Type | Consumer(s) | Status |
|---|---|---|---|
| `scripts/peak-window.mjs` (+ `park`, `classify-keys`, `defaults`, `emit`, `windows --markdown`) | producer (**single production source**) | both preflights · `wait-for-peak.sh` · `fleet-cost-report.sh` · farm · CI | ✅ |
| `scripts/peak-window-oracle.mjs` | **declared independent** verification artifact | the frozen-corpus test + the key-set equality assertion | ✅ |
| `extensions/shared/child-env.ts` | shared contract (import-only) | `task` · `subagent` · the **bash-tool** child surface | ✅ |
| `extensions/shared/peak-park.ts` | producer | both preflights | ✅ |
| `peak-window.mjs` + `check-peak-single-truth.sh` in `fleet_srcs`; `PI_NODE_BIN` | runtime path | farmed report + guard under launchd (E9) | ✅ |
| `scripts/rates/deepseek.jsonl` in `fleet_srcs` | **#631-dependent** | the farmed report's window source | ⚠️ absent at `699ecde` — the farm is **#631's**; the bootstrap covers Phase 1; Task 2.8's trips retire it |
| hour-of-week integer key **+ its day base** | shared vocabulary | parser ↔ engine ↔ report | ✅ |
| `hourlyUtc`/`first_ts`/`ts_unknown`/`session_id`/`session_id_unverified`/`n_lines`/`n_bytes`/`n_bad` | producer | `fleet-cost-report.sh` | ✅ |
| parser non-consumers | regression | `watch-truncation.sh` · retro summary | ✅ |
| `(d)` section, reconciliation, tear, tokens, base line | producer | operator · `fleet-cost-weekly.sh` · **`cron-quality-gates.sh fleet_gate()`** | ✅ |
| `GateEventName` (+5 members, **+7 log names + `gate_block_parse_failure`**, typed emit) | shared contract | **callers** (both preflights + `wait-for-peak.sh`) · `extensions/peak-gate` · report reader · `vgate.sh` | ✅ |
| `~/.pi/agent/peak-force.json` (**marker family**, single writer, atomic) | producer | both preflights · `/peak status` · wait wrapper | ✅ |
| `pi.registerCommand("peak")` | producer | operator (D3) | ✅ |
| `pi-bootstrap/pi-config/extensions/peak-gate` + manifest row + `package.json` pin | registration | `check-pi-config-extensions.sh` · `sync.sh` · farm parity · `check-skill-lint.test.mjs` (h)/(i) | ✅ |
| `settings.json` `peakQueue` + **nine** fixtures | producer | engine · `check-cost-config.sh` · `sync.sh` · tests 11/13/14 | ✅ |
| `PEAK_ENCLOSING_DEADLINE_MS` (wall-clock **and** liveness) | producer (three child surfaces) | the headroom check | ✅ |
| CI steps (`ci.yml` `verify`, `ci-main.yml` **`script-validate`**) | guard | per-PR + post-merge | ✅ |
| `docs/ops/peak-queue-policy.md` (generated table) | doc | `AGENTS.md` routing · `cost-config-policy.md` | ✅ |
| bare `pi -p` by hand | unmitigated | — | ⚠️ accepted residual (no spawner to gate; #782's half) |
| deferred **child** spend (children run `--no-session`) | unmitigated | the report's `(d)` | ⚠️ accepted + **explicitly printed** as a non-measurement; #690 owns the unattributed spend |
| `wait-for-load.sh`'s wall-clock bound **and its two `load_gate_entry()` siblings** (`daily-backup.sh:53–75`, `cron-quality-gates.sh:40–66`) | **adjacent pre-existing defect class** | — | ⚠️ **out of scope; to be filed** (§15 R-4) |
| the 3-dialect **escape-marker family** | **duplication, deferred** | — | ⚠️ recorded + guard-inventoried; unification is §15 R-1 with a named owner |

## 8. Acceptance criteria

1. `(d)` prints the recorded split, the adjusted split, the premium, the launch segmentation (per the pinned
   predicate), the compaction share, `ts_unknown`, `n_bad`, the `live-file-skipped` partial-read line, a per-hour
   UTC table, and the one-line provenance/**base** token — and reconciles double-entry (rc 2 with its **own token**
   on mismatch, on an `unresolved`/`env` source, on a zero/undefined total, on a **zero-session** scan, and on a
   transport failure).
2. On a **frozen** corpus with `--days 30` (**335-of-346** filename-date selection), the instrument reproduces
   **E10's `--days 30` figures** within ±0.5% **and** its key set equals `classify-keys`, both reproducible by the
   committed oracle.
3. A deferrable dispatch started inside a peak window **or its runway** sends zero provider requests and spawns no
   child pid before `resumeAt`, and resumes automatically — on **both** surfaces.
4. `PEAK_FORCE=1`, `/peak force`, and the per-dispatch `force` param bypass in **one step, including while
   parked**; every bypass is a `peak_bypass` event with its actor **and, when it released a park, that `parkId`**.
5. Interactive sessions are never parked; unmarked dispatches from an interactive parent are never parked; the
   **whole `PEAK_*` family** is stripped from **every child surface** (two dispatch tools + the bash tool) via the
   shared module, **failing closed**, with `PEAK_ENCLOSING_DEADLINE_MS` the only survivor.
6. The parked duration is never longer than the enclosing **deadline** — which folds in the **liveness (tool-age)**
   ceiling — **nor charged to the child's** bound; absent/`0` deadlines park; insufficient headroom **skips
   loudly**; the cap-expiry, mid-park-`unresolved`, and forward-clock rules hold.
7. Aborting during a park resolves immediately and spawns nothing. Every park has exactly **one terminal event**,
   paired on `parkId` (`peak_resume` | `peak_abort` | `peak_bypass` | `peak_skip`), and the engine writes **none**.
8. One resolver with **four** declared outcomes; an expiring, non-authoritative bootstrap retired by **two trips
   that can fire** (absent-once-ledger at either location; `BOOTSTRAP_EXPIRES_ON` in UTC); **one** guard script with
   its allowlist, sub-rules 1–3 (incl. the marker-family inventory), and a both-direction self-test; and a config
   guard that BLOCKs a `windows` key while treating `enabled:false` as legal.
9. No new escalation class is introduced **silently**: every rc-2 producer is enumerated and classified
   (instrument → escalate; environment → no file; `instrument: no-data` → **loud, non-escalating**). `(d)`
   classification is ISO-instant equivalence with the engine (key **and** verdict); the parser's three consumers
   pass; `(d)` is transported via **stdin**.
10. Unit tests pass with injected clock **and sleep**, covering DST, the Mon–Fri UTC boundary, the runway (**the
    window end**), two-window re-entry, the flap guard's defined quantity, and the forward clock step.
11. `epic-executor` defers a whole batch once, visibly, with the one-step escape — **including from an interactive
    orchestrator**.
12. `check-pi-config-extensions.sh` passes; the extension is symlinked and manifest-listed; the interpreter is
    resolved via **`PI_NODE_BIN`** (not via `PATH`, and not under a new name); the `task` tool resolves a real
    `--session`; **every new test file has an explicit CI line**.
13. An engine/transport failure, an instrument refusal, a reconciliation/tear failure, a zero-session scan, and
    `E2BIG` all produce rc 2 with their **own** token, and **both** rc-2 consumers (`fleet-cost-weekly.sh` **and**
    `cron-quality-gates.sh fleet_gate()`) make the **declared** decision per class rather than logging "env
    failure".
14. `enabled:false` is a legal config value and the documented rollback seam; all **nine** settings fixtures are
    regenerated and tests 11/13/14 pass.
15. The `sessionId`↔corpus join matches the **production** shapes and a fixture asserts a **non-zero** count, with
    `unjoined_peak_defer_events` printed; header-less and disagreeing-id files are **counted** but flagged
    `session_id_unverified`, never error rows.

## 9. Out of scope (explicitly)

- The **mid-flight pause** (`before_provider_request`), the **watchdog coordination protocol**, `[PEAK-PAUSE]`, the
  **avoided-premium aggregate**, and the **cache-aware pause thresholds** → **#782** (and see E14: this supersedes
  #631 §5's assignment of those to #634).
- **Net-of-re-ingest** premium arithmetic (no cache exists pre-spawn).
- **Slack notification** (D4 optional/off).
- **Spillover/alternate-provider routing during peak** (research doc §5.4).
- **Rate-card correctness** and the **v4-pro continuation** correction (E11) → #631.
- **Metric (c)'s double-count** → #685.
- **Parking the local quality gates** — no token spend (E5).
- **Unifying the three escape-marker dialects** — recorded and guard-inventoried (§15 R-1), not absorbed.
- **Retrofitting `wait-for-load.sh` and its two `load_gate_entry()` siblings** — an adjacent defect class; to be
  filed (§15 R-4).
- A **persisted queue / daemon**.

## 10. Rejected alternatives

| Alternative | Why rejected |
|---|---|
| **Report-only change** | Impossible: the parser discards timestamps (E2); a second parse forks the #373 one-parser contract. |
| **In-process import** across `scripts/`↔`extensions/` | Breaks the farm (E9). Subprocess costs ~40–60 ms per dispatch. Shared vocabulary goes in `extensions/shared/` and is exposed as CLI **data**. |
| **A parallel `peak-defer.jsonl`** | Forks the existing gate-events contract (E13). |
| **String bucket keys `"Mon-01"` in two languages** | A grammar drift yields 0.0% peak with all gates green. |
| **A `keys(parser) ⊆ universe(classify-keys)` subset test** | Cannot hold (off-peak keys are not members) and is blind to the Mon=0/Sun=0 base shift. Replaced by ISO-instant equivalence on key **and** verdict. |
| **An "independent on-disk count" to detect static truncation** | Impossible: the two counts are equal by construction on a static file. The tear is scoped to mid-pass shrink/change; static truncation is `n_bad` + `watch-truncation.sh`. |
| **Defending a long park with heartbeat markers alone** | The liveness kill is on **tool age** (E7), so markers cannot help. The ceiling is propagated as a deadline and the park is capped. |
| **Three separate guard scripts, each with its own self-test** | One discriminator is easier to keep honest than three. |
| **`CHILD_STRIPPED_ENV` exported from the engine** | Unimplementable: `extensions/` cannot import `scripts/` (this plan's own boundary rule). It lives in `extensions/shared/child-env.ts`. |
| **`NODE_BIN` as a new interpreter name** | Duplicates the established `PI_NODE_BIN` probe order; an operator setting `PI_NODE_BIN` would silently get a PATH-dependent `node`. |
| **A hand-typed per-surface child-env strip list** | The `PEAK_*` family would have to be added twice; the shared module + a cross-interface parity test prevent that (the cited *past* divergence was false — E16). |
| **The bootstrap constant as authority** | It is a labelled, expiring, non-authoritative exception with two mechanical trips. |
| **A fabricated per-defer avoided premium** | Not computable: children run `--no-session`, and a pre-spawn park does not change the parent's spend. |
| **Gating `cron-quality-gates.sh`** | E5: no subcommand makes a provider request — "motion without saving". |
| **`windows` in `settings.json`** | Second-truth defect; the guard BLOCKs it. |
| **Using `cost.total` as the billed number** | The cost model has no time dimension (E1) — understates the share ~2×. |
| **`periodKey`-keyed ledger selection** | #631 has no such field. |
| **A cron rescheduler** | E5: nothing worth moving. |
| **A persisted queue / daemon** | A park is a bounded wait loop, not state. |
| **Gating only `task`** | Misses `subagent`, which `epic-executor` uses (E6). |
| **Parking the child at `session_start`** | Needs the watchdog coordination protocol (#782). |
| **A report threshold that escalates** | A ~$2–4/mo metric does not deserve a flappy alert. |
| **`deferred: true` (pi's async handle)** | DeepSeek has no documented native batch/async API. |
| **A fixed-name temp file for the report payload** | The report runs concurrently (`fleet-cost-weekly.sh` under launchd **and** the agent-invoked `fleet_gate()`), so a fixed name can tear. Per-PID name; stdin is preferred. |
| **Promoting a zero-session scan to a filed escalation** | A quiet week or a fresh machine is not an incident; it is a **loud, non-escalating** class. |

## 11. Open questions

| # | Question | Recommended default | Why |
|---|---|---|---|
| **Q1** | **Classification surface** (issue's Research Needed #2) | the six-rung precedence of §2.4, a distinct input per rung, `force` per dispatch | Uses the existing `isPrintMode` predicate; satisfies D1. **Human gate:** a behavioural default for every headless dispatch — confirm before Phase 2 ships. |
| **Q2** | **Enable by default on merge?** | `enabled: true`, with `enabled:false` **and** `PEAK_DISABLED=1` as legal rollbacks | Indicators (a)/(d) need a real park; both rollbacks are one edit. |
| **Q3** | **`minRunwayMin`** | **15 min** | Required for indicator (a); a runway defer is a `peak_defer` with `deferReason: short-runway`. |
| **Q4** | **Force-marker scope + TTL** | session-scoped when the caller has an id; `host` + loud log otherwise; **60-min TTL**; ±120 s skew | A fixed host-wide marker would disarm other sessions; the TTL bounds a `SIGKILL`ed run's force; skew avoids a fail-closed safety escape. |
| **Q5** | **Refuse to park with no headroom, or park and risk a cut?** | **Refuse** (`peak_skip no-headroom`) | A cut is a silent failure of a safety mechanism. |
| **Q6** | **Interactive banner frequency** | one latched banner per session, `[peak-gate]` prefix | Mirrors `[load-gate]`. |
| **Q7** | **Bootstrap sunset** | two mechanical trips: absence-once-ledger (either location) + `BOOTSTRAP_EXPIRES_ON = 2026-12-31` (UTC) | v3's conjunction was unsatisfiable on its own purpose and had no artifact to read. |
| **Q8** | **Committed oracle vs prose method** | commit `scripts/peak-window-oracle.mjs`, allowlisted, constrained by **key-set equality** + ±0.5% | A `Σ` tolerance alone lets a low-traffic-hour base shift through. |
| **Q9** | **Measuring the avoided premium** | do **not** fabricate one; duration + reason histograms + the non-measurement (#690) | The only honest option given `--no-session` children. |
| **Q10** | **Is the `PEAK_WINDOWS_JSON`/`FILE` override production-reachable?** | **No — `NODE_ENV=test` only**; a set override makes the report **refuse** | It is a fourth source outside the bootstrap exception; #631 forbids a competing window table. |
| **Q11** | **`minPauseMin` ownership** | #634 owns the **pre-dispatch** threshold; #782 the **mid-flight** one | #782's deliverable list names a minimum-pause threshold; declaring the seam avoids a duplicate mechanism. |
| **Q12** | **The `task` tool's missing `ctx`** | add the optional 5th `ctx` (the `ToolDefinition` signature supports it) | Without it there is **no** correct session id on the primary surface and AC4/AC15 fail. |
| **Q13** | **Escape-marker family** | **defer** unification; record the inventory + owner (§15 R-1) | Unification would retrofit a shipped, non-atomic writer — out of scope, but the recording is not deferrable. |

## 12. Effort (honest)

| Phase | Scope | Estimate |
|---|---|---|
| **1 — instrument** | engine + **one** guard + oracle; parser (8 new fields, integer keys, `session_id`) with 3-consumer regression; report section + double-entry + tear (**scoped, grow-aware**) + token classes + zero-total/zero-session guards + **stdin transport**; farm/interpreter + explicit CI wiring; **both** rc-2 driver branches | **3 days** |
| **2 — launch gate** | engine `plan()`/precedence/**flap guard**/marker family/park + the two shared helpers + parity tests; audit-log typing + `emit`; `wait-for-peak.sh`; `/peak` extension + **both** registration surfaces; two preflights (**`ctx`**, deadline + **liveness fold**, abort/force terminals, **`PEAK_*`-family** strips, cross-interface parity) **+ the bash-tool surface**; **nine** fixtures; Task 2.7 events; Task 2.8 trips + the #631 note; policy doc; integration tests | **5–6 days** |
| **3 — batch path** | `epic-executor` step + opt-in; cadence table; optional weekend note | **0.5–1 day** |
| **Total** | | **~2 weeks** |

> **Scope discipline.** The tier is `complexity:standard`; the ceiling is **~$2–4/mo** (E10). v4→v5 **cut** where it
> could (three guards → one; `--audit-file` to its consumer; the redundant key-subset test replaced by the
> necessary equivalence test; the `minPauseMin` overlap with #782 declared, not duplicated) and **recorded** what it
> would not fold (the marker family, the `load_gate_entry()` siblings). §15 lists what remains and is **why this is
> an escalation, not a clean exit**.

## 13. Risks

| Risk | Mitigation |
|---|---|
| Split distrusted because the card is stale (#631, E11) | Report the **ratio** + the `windows-source`/multiplier/base token; label absolute dollars as card-dependent. |
| A parked dispatch never resumes, or is cut | Chunked re-derivation + named monotonic bound; abort/marker race; the **folded deadline + liveness ceiling**; fail-open with a loud event. |
| A stale/foreign/malformed marker disarms or destroys the opt-out | Atomic per-writer publish + non-destructive reads + session scope + 60-min TTL + ±120 s skew + every failure mode tested + `peak_bypass` audited with its `parkId`. |
| An env var leaks to the fleet | One shared strip list + cross-interface parity + **fail-closed** on a strip-time failure + a nested bash-child test. |
| Shared-parser change breaks the watch/retro | Additive-only; named-access-only consumers verified; all three suites green in the same commit. |
| Cost-config suite reddens on merge | The nine fixtures are enumerated and regenerated; `PI_NODE_BIN` numeric + key-set parity runs. |
| A wrong headline number with every gate green | Integer keys **+ the ISO-instant day-base equivalence test** + the oracle's key-set equality **and** ±0.5% + the join non-zero assertion. |
| **The trust gate compares against the wrong baseline** (E10) | AC2/§3.1/§6 now name the **335-of-346 `--days 30`** selection and its figures. |
| A healthy live corpus produces a weekly false escalation | The tear predicate is shrink/in-place only; a grown file is `live-file-skipped` and its rows included with a `(partial read)` line. |
| An instrument refusal hides as an env failure **or a quiet week files an issue** | Every rc-2 producer enumerated and classified; `instrument: no-data` is loud and non-escalating. |
| The `(d)` payload hits `E2BIG` | stdin transport + an oversized-corpus test + a distinct `transport-failed` token. |
| A new test file runs nowhere | Task 2.2 owns **explicit** CI lines for every new/changed suite (E12). |
| **The fix loop keeps generating new defects** | **This is the reason for the escalation (§15): stop and get human acknowledgement rather than opening cycle 5.** |

---

## 14. Reviewer #5 (Duplication & Architecture) — record with verdicts

Two passes are recorded. **Cycle-3 pass** (advisory, not merged per the skill's disposition table): six findings.
**Cycle-4 pass** (also advisory): five more. **Five §14 cycle-3 dispositions were independently re-verified in
cycle 4 and TWO were found inaccurate** — corrected below, because a disposition record that is itself wrong is
worse than no record.

| # | Finding | Verdict | v5 disposition |
|---|---|---|---|
| **D-1** | **P0 — the timed session-scoped file-backed escape marker already exists, in TWO dialects.** `main-worktree-guard`'s `~/.pi/agent/.allow-main-edits` (15-min, mtime TTL, **non-atomic** writer) and `sequence-enforcer`'s `/tmp/parallel-check-force.json` (**`FORCE_TTL_MS` = 60 min**, content `ts`, hand-written, the escape the skills document). This plan adds a **third**, independently re-deriving 60 min. | `unify-contract-keep-drivers` | **Recorded, not folded** — unification would retrofit a shipped non-atomic writer. §2.5 declares the family inventory; the guard asserts it; **§15 R-1** names the owner. Cycle 4 verified the count is **three, not two**. |
| **D-2** | The two child-env strip lists "have already diverged"; the plan extends both. | `unify-contract-keep-drivers` | **Fold, with corrected evidence.** Cycle 4 **falsified the divergence claim** (E16 — the lists are identical; `SUBAGENT_ATTEMPT` is not a strip element). v5 keeps the fix (`extensions/shared/child-env.ts`) but justifies it **prospectively**. |
| **D-3** | A scripts-side writer joins `gate-events.jsonl` and cannot import the union. | `unify-contract-keep-drivers` | **Fold.** v5 adds the engine's `emit --json` as the single serializer and names **two** scripts-side callers (`vgate.sh`, `wait-for-peak.sh`) — cycle 4 found the enumeration was off by one. |
| **D-4** | The bounded-wait defect class is fixed only for peak; `wait-for-load.sh` and two near-identical `load_gate_entry()` copies remain. | `unify-contract-keep-drivers` | **Partly folded.** v5 declares the wait contract once and the wrapper is a pass-through with an engine parity test; the retrofits are out of scope and **to be filed** (§15 R-4). |
| **D-5** | The committed oracle is an undeclared second window writer; a `Σ` tolerance cannot see a day shift. | `keep separate` — **an oracle is only an oracle if independently derived** | **Fold.** The oracle is allowlisted, the claim is qualified to "single *production* source", and **key-set equality** is added. |
| **D-6** | Two claimed invariants were unenforced. | `unify-contract-keep-drivers` | **Fold (§2.1) / fix (§2.5).** (i) is now qualified+tested; (ii) is fixed by `emit --json` + the enumerated callers. |
| **D-7** | `NODE_BIN` duplicates the documented `PI_NODE_BIN` probe order; two names for one job cannot drift visibly. | `unify` | **Fold** (§2.6). |
| **D-8** | `CHILD_STRIPPED_ENV` is declared in a tree its consumers may not import (`scripts/`), so the "one list" invariant is false. | `unify-contract-keep-drivers` | **Fold** — moved to `extensions/shared/child-env.ts`. |
| **D-9** | `peakQueue`'s default **key set** lives in the guard beside the engine's schema; only values get a parity assertion. | `unify` | **Fold** (§2.6) — key-set parity added. |
| **D-10** | The `<ts>_<uuid>.jsonl` grammar is expressed twice (parser suffix derivation vs `pi-reap-idle.sh:432`'s reverse glob); no test asserts they agree. | `unify` | **Fold** (§6) — the equivalence test pins both directions. |

## 15. ⚠️ ESCALATION — remaining issues, and why this is not a clean exit

**Exit reason: `honest-stuck`.** Per the plan-review skill this is an **escalation exit**, not a completion: the
remaining issues **must be acknowledged by a human before implementation**, and this plan is **not** to be
presented or handed off as clean or complete.

**Attempted and applied across four cycles:** ~130 findings were re-verified at source and applied — v1→v2
(anchors, testability, the enclosing bound, the abort/release path, the forked log contract, the surviving second
window truth), v2→v3 (the two-language key grammar, the re-derived wait algorithm, the overloaded rc 2, the
unenforceable invariant, the undeclared headroom contract), v3→v4 (the live-corpus TOCTOU tear, the impossible
`sessionId` join, the `E2BIG` argv transport, the non-holding key guard, the missing park correlation, the
self-contradictory taxonomy, the second rc-2 consumer, the `tool-stall`/`stream-stall` error), v4→v5 (the E10
baseline conflation, the impossible static-truncation tear, the tool-**age** liveness ceiling, the unimplementable
`CHILD_STRIPPED_ENV` placement, the undefined flap-guard quantity, the header-less 3.2%, the unwired extension
tests, the missing abort/force terminals, `NODE_BIN`, and my own false D-2 evidence).

### R-1 (P0) — **the escape-marker family is three dialects** (E15). Owner: Task 2.1 author.
Deferred unification: the Good alternative is a shared `extensions/shared/escape-marker.ts` schema
(`{ts, expiresAt|ttlMs, scope, sessionId, actor, reason}`) + atomic publish, with all three readers migrated.
**Cost to do it now:** it forces a change to a **shipped** guard (`main-worktree-guard`'s non-atomic writer), i.e.
out of this issue's scope and risk profile. v5 records the inventory, widens the guard, and names the owner.
**Human decision needed:** accept the deferral, or expand scope to unify.

### R-2 (P1) — **the enclosing **liveness** ceiling is now a hard skip.** Owner: Task 2.4/2.5.
Because the kill is on **tool age** (E7), a park that would exceed the enclosing dispatcher's `tool-stall` (6 h,
or 30 min when `turnActive === false`) is **skipped loudly** rather than performed. Consequence: a **nested**
dispatcher (a `task` child that itself dispatches) has a much smaller parking budget than a top-level one — and
when `turnActive === false` the budget may be **30 min**, below a full window. **Human decision needed:** is a
30-min ceiling on nested parks acceptable (it is a partial win), or does this issue need to raise
`TASK_HEARTBEAT_TIMEOUT_MS` / widen the liveness bound for parked dispatchers?

### R-3 (P1) — **the plan is ~2 weeks for a `complexity:standard` issue with a ~$2–4/mo ceiling.** Owner: human.
Four review cycles have grown a 15-task design for a `-` (minuscule) saving, and each cycle's fixes generate new
defects. Phase 1 alone (the instrument) is ~3 days and is the thing #782 is actually gated on. **Human decision
needed:** ship **Phase 1 only** now (which makes #782 decidable and is independently useful), and re-plan Phase 2/3
only if the instrument shows a worth-it deferrable slice? This is the recommendation; it is a scope decision, not
a technical one.

### R-4 (P2) — **the bounded-wait retrofit.** `wait-for-load.sh`'s wall-clock bound and its two near-identical
`load_gate_entry()` copies (`daily-backup.sh:53–75`, `cron-quality-gates.sh:40–66`) stay broken. To be filed as a
separate issue (owner: whoever picks up the wait-contract extraction).

### R-5 (P2) — **un-tokened pre-existing rc-2 paths.** v5 enumerates them (`:74, :82, :88, :92, :93, :135`, the
`ERR_COUNT` gate) and keeps their current "env" handling, but does not give them tokens. If that is not good
enough, giving them tokens is a small follow-up.

### R-6 (P2) — **the `emit --json` indirection.** It gives scripts-side writers one serializer, at the cost of a
subprocess per emission (≥2 per park). Fine at this volume; noted.

<!-- plan-review: cycles=4, status=escalated, exit_reason=honest-stuck, version=2.3.0 -->
