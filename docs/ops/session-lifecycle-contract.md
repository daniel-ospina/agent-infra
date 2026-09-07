---
title: "Session Lifecycle Contract — one-issue-per-session, handoff-size budget, compaction expectation, max-call guidance (#365)"
type: engineering
domain: operations
doc_status: live
subjects.team: organisation-design-team
created: 2026-09-07
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-365, issue-341, issue-373, session-lifecycle, cost-config-policy
---

# Session Lifecycle Contract — the behavioral cap on the marathon class (#365)

The fleet's **session-shape contract**: one issue per session, a handoff-size
budget with a dep-free check, the compaction-trigger expectation, and max-call
guidance that is consistent with the #363 6h sub-agent cap. Delivered by issue
#365 (indicator 1 + 2 ship now; indicator 3's escalation is **pre-committed
with a calibration-pending threshold** — no fabricated numbers). Sibling
policy: `docs/ops/cost-config-policy.md` (the deepseek context clamp + drift
guard). NOTE: this contract states the LIVE clamp regime (300K, since #476's
Compaction fix / PR #511, 2026-09-05); cost-config-policy.md and
fleet-cost-report.sh's prose/constants still carry the pre-dial 400K regime —
tracked as issue #570, not restated here.

**Driver vs amplifier (honest framing):** #341's postmortem named two
different cost problems. The **amplifier** is cold compaction at the 1M
ceiling destroying the cache prefix (~50x re-ingestion) — addressed by the
context clamp (`cost-config-policy.md`; shipped 300K since the #511 dial). The
**driver** this contract owns is
session *shape*: marathon sessions running 1,000–3,800 assistant calls each
(the measured Aug fleet; see #341), recurring handoffs that seeded **100+ KB
of instructions** into a fresh context ("read this entire file, then
continue"), and no discipline anywhere on when a session should end. The
clamp makes a marathon session *cheaper per token*; it does not stop sessions
from being shaped wrong. This contract is the behavioral cap on that class —
and it is deliberately NOT a kill switch (see §5), consistent with the
fleet's detect → surface → pre-committed-human-response philosophy.

---

## 1. One-issue-per-session rule

**A session works ONE issue deliverable from first tool call to handoff.**
"One issue" means one `complexity:*`-tiered unit of work with one closing PR:
for a standard issue that is the full pipeline (scope → plan → implement →
review → merge) in one session — exactly what #363's 6h sub-agent hard cap
sanctions. What the rule forbids is the observed marathon pathology: one
session chewing through several independent issues (or an epic batch) in a
single continuous context, stacking sub-agent fleets for unrelated work, and
carrying the accumulated context across all of them.

Mechanics:

- **Branch = issue.** The issue-workflow Branch Gate already binds a branch to
  one issue number (`feat/N-slug`). A session on `feat/N` finishes N (labels,
  PR, merge) and **starts a NEW session** for the next issue — it does not
  `git checkout -b feat/M` mid-session and keep rolling. The one-issue rule is
  the session-level twin of that gate.
- **Batch work is a batch of sessions, not one marathon.** Epic/batch
  execution (epic-executor, parallel dispatch) intentionally fans out to
  fresh sub-agents/worktrees per issue by design — each sub-agent context
  stays bounded to its issue. A controller session that *co-ordinates* a batch
  is still one deliverable (the batch); the rule bites when a single
  context starts *doing* multiple issues itself.
- **Close the loop at the issue boundary.** When the current issue's PR
  merges (or the issue is closed), stop. The next issue gets a fresh session
  (and, for writes, a fresh worktree). Session resumption after an
  outage/reap is NOT a new issue — it is finishing the same one (the
  offline-resume contract; retry stays at 10000, per cost-config-policy §2).
- **Why not a hard cap?** Marathon sessions within ONE issue are legitimate
  work (full-pipeline standard runs up to the #363 6h cap; measured $2–6
  pre-clamp). The discipline is *scoping*, enforced by review of session
  shape — see the §4 flag band and the §5 escalation rule.

## 2. Handoff-size budget

A **handoff doc** is the resume summary one session leaves for the next — the
`## Completed / ## Files Changed / ## Notes` worker output, the
executing-plans/subagent-driven-development task handoff, or an epic-resume
file opened with "read this entire file, then continue". A handoff exists to
give the next context **enough to continue, not everything it might touch**;
session state (metrics, full transcripts, retrospective detail) belongs in
repo artifacts / the session JSONL / the plan doc, not in the seed.

- **Budget: 16 KiB default** (`HANDOFF_MAX_BYTES`, or `--max-bytes N`).
  ~4–5K tokens — an order of magnitude under any compaction-relevant seed and
  roughly **1/6 of the measured 100+ KB handoff class** that #341 flagged.
  Revisited at the §8 calibration gate once the #373 weekly dataset accrues.
- **Check: `scripts/check-handoff-size.sh`** — a ~10-line dep-free bash + `wc`
  check (no node/python). Run it on the handoff doc at write time, before the
  doc seeds a fresh session:
  ```bash
  bash scripts/check-handoff-size.sh path/to/handoff.md      # exit 1 = over budget
  cat path/to/handoff.md | bash scripts/check-handoff-size.sh # stdin form
  ```
  Exit 0 under budget · 1 over budget (lists the offender + size) · 2 usage.
  Self-check: `bash scripts/check-handoff-size.test.sh`.
- **Fix when it trips:** split the doc — move verbose state into the repo
  artifact it summarizes (plan doc, PR body, retrospective) and keep the
  handoff to next-actions + file pointers. A handoff over budget is a signal
  the session already exceeded the one-issue scope (§1).
- **Wiring note (honest):** handoffs are produced inside pi sessions as text,
  not committed repo files, so there is no pre-commit/CI hook point for them
  today. The check ships standalone + documented here; repos that *do* commit
  handoff-style docs can add it to their pre-commit the same way the #341
  cost-config guard is wired. If a handoff-producer mechanism lands later
  (session-end hooks), this check is the size gate for it.

## 3. Compaction-trigger expectation

Sessions MUST expect compaction, not be surprised by it. The trigger is pi's
`compaction.js`: compaction fires when
`contextTokens > contextWindow − reserveTokens`. With the shipped **300K
clamp** (dialed 400K→300K by #476's Compaction fix / PR #511, 2026-09-05) and
`reserveTokens 16384` (the #341 shipped compaction block), a marathon session
**crosses the trigger at ~283,616 tokens and compacts — that is the design,
not a failure.** Under the clamp the compaction lands in the cache-read area
instead of destroying the prefix at the 1M ceiling.

Expected vs drift:

| Observation | Meaning |
|---|---|
| Compaction at `tokensBefore` in the ~283.6K+ band (at/above the 300K-clamp trigger 283,616) | Normal post-clamp marathon behavior — cache-read area retained |
| Compaction with `tokensBefore ≥ 900K` | **Drift** — a 1M-window session exists (clamp not live). Threshold (a) of the weekly report escalates |
| `stopReason: "length"` on a message | **Ceiling truncation** — the real truncation marker; the watch-truncation.sh leg + the pre-committed rollback trigger (#341 Task C8) |

So the correct mental model: a long session WILL compact around 283.6K; that
fact alone does not justify killing or restarting it. The alarms are the
drift classes (≥900K ceiling records, `length` stops, sustained cache-share
below the fleet-cost-report (b) floor). The lifecycle lever against
compaction cost is *prevention* — smaller handoff seeds (§2) and single-issue
scope (§1) keep
context from reaching the trigger with content that does not need to be
there — not hasty manual compactions.

## 4. Max-call guidance (consistent with the #363 6h cap)

#363 raised the sub-agent hard cap 2h → 6h (`TASK_HARD_CAP_MS`, now
21,600,000) precisely so full-pipeline standard runs are not force-killed
mid-work. This contract does NOT fight that: it does not set a lower call
ceiling, and it never auto-kills a session (a kill loses work AND pays the
compaction anyway — the #340 analysis; the fleet's philosophy is
detect → surface → pre-committed human-executed response, never auto-kill).

Max-call guidance is therefore a **flag band, not a kill line**:

- The measured marathon class ran **1,000–3,800 assistant calls** per session
  pre-clamp (Aug baseline mean 1,867 calls / $2.99 per compacting session —
  the #373 regenerated baseline). The 6h cap is the outer bound on that band.
- **At ~2,000 assistant calls (≈3h of continuous work), pause and check
  session shape:** is this still ONE issue? Are handoffs/reads staying under
  the §2 budget? Has context crossed the ~283.6K compaction trigger more than
  the marathon norm? If the answers are "one issue, bounded handoffs, normal
  compactions" → continue (the #363-sanctioned shape). If a session is
  multi-issue, re-seeding oversized context, or looping review churn without
  convergence → stop, close the current issue boundary (§1), and start fresh
  for the remainder.
- **The weekly report is the fleet-level view of this band:** per-session
  calls + re-read volume vs the regenerated Aug baseline (fleet-cost-report.sh
  `## Compaction + cost vs regenerated Aug baseline`). A per-compacting-session
  call count persistently far above the 1867-call baseline is the fleet-level
  flag that §1 scope discipline slipped.

## 5. Pre-committed escalation (indicator 3 — wiring committed, threshold calibration-pending)

**The behavioral-scoping trigger is committed now; only the threshold number
waits on data.**

- **Data source (live):** #373's weekly cadence — `scripts/fleet-cost-weekly.sh`
  via the `com.eldato.fleet-cost-weekly` launchd plist (Sunday 06:30 local),
  which runs `scripts/fleet-cost-report.sh` + `scripts/watch-truncation.sh`
  and escalates to ONE deduped GitHub issue (`"fleet-cost" in:title` — comment
  on an open issue, else create).
- **Instrument:** fleet-cost-report.sh threshold **(c)** — *output+reasoning
  share over non-cache tokens* — the instrument #341 pre-registered for #365
  (real pre-clamp median **58%, range 0–91%**). (c) is per-session median over
  sessions with usage; it is currently **recorded every run, never escalates**
  — this contract is the escalation rule it feeds.
- **Pre-committed rule:** when (c)'s per-session median exceeds the calibrated
  threshold for **2 CONSECUTIVE weekly reports** → **behavioral scoping
  fires**: the weekly report reader (owner, below) opens/refreshes the
  behavioral-scoping issue (enforcement of §1 one-issue-per-session, §2
  handoff-template shrink, §4 max-call review), naming this contract + the
  two reports as evidence. Two consecutive weeks = sustained trend, not one
  noisy week (aligned with #373's small-n report-not-escalate guard).
- **Threshold VALUE: calibration-pending — NOT fabricated here.** The 58%
  median is a pre-clamp pre-registration; the post-clamp threshold calibrates
  from the **first 4 weeks of #373 weekly data** (accruing since #373 merged;
  gate ~**2026-09-25**, counting from #341's 2026-08-28 close). Until then the
  rule above is documented but the reader records (c) each week without
  firing. Post-calibration, the ~5-line auto-trip addition to
  `fleet-cost-weekly.sh` (reusing its dedup-issue pattern) is the follow-up
  wiring — out of scope for this PR by design.
- **Owner: the weekly report reader** — the role already named in #341 Task
  C8 (the rollback trigger) and #373's escalation dedup. The dedup-issue
  pattern is the filing mechanism; the behavioral-scoping issue is a distinct
  title (e.g. `session-lifecycle: behavioral scoping — N weeks above (c)
  threshold`), NOT the fleet-cost escalation issue, so the two alert classes
  stay separable.
- **Deferred (retry measurement):** #341 Task D10 also assigned #365 the
  retry-storm data-source discovery — no persisted retry records exist to
  analyze yet (cost-config-policy §2). Still deferred; tracked at the §8 gate.

## 6. Relationship to the config clamp and #363

- The **clamp** (300K since the #511 dial) reduces what a marathon session
  *pays*; this contract
  reduces how *bloated* a session *gets*. They are complementary: the clamp's
  savings are measured over compacting sessions only (cost-config-policy §1,
  pre-dial 400K prose — see #570),
  and the cheapest compacting session is the one that never needed the
  context that triggered compaction — which is §1 + §2's job.
- **#363 (6h cap) amplifies the marathon shape** — longer sanctioned runs
  mean more accumulated context, which is exactly why the contract's levers
  are the *seed* (handoff budget) and the *scope* (one issue), not a tighter
  wall-clock cap. This contract's §4 guidance is written to be consistent
  with the 6h cap, not to fight it.

## 7. Owner + calibration summary

| Instrument | Owner | Fires when | Status |
|---|---|---|---|
| Handoff-size check (§2) | The session producing the handoff | Doc > 16 KiB (default) at write time | **SHIPPED** (this PR) |
| One-issue-per-session + max-call guidance (§1, §4) | The session itself; fleet view = weekly report reader | Shape check at ~2,000 calls / issue boundary | **SHIPPED** (this PR, contract only) |
| Escalation (indicator 3, §5) | Weekly report reader | (c) median > **calibrated threshold** for 2 consecutive weekly reports | **Wiring shipped; threshold calibration-pending** |
| Threshold calibration | Weekly report reader | 4 weeks of #373 data accrued | Gate ~**2026-09-25** |

## 8. Calibration gate (~2026-09-25)

At the gate, with 4 weeks of #373 weekly (c) data accrued: set the escalation
threshold (expected to sit near or below the pre-registered 58% median —
do not reuse the pre-clamp number blindly), land the fleet-cost-weekly.sh
auto-trip follow-up, and revisit the §2 handoff budget default against real
session/handoff sizes. Until then this contract's numbers are **defaults
pending data**, never calibrated claims.

---

Provenance: filed from #341 scope-verify (docs/plans/2026-08-28-issue-341-session-lifecycle.md
Task D item 10); issue #365 owns the follow-up so the deferral does not
evaporate. Measured anchors (no new claims): marathon band 1,000–3,800 calls,
100+ KB handoff seeds, 500–800K pre-clamp context — #341 issue body + #340
plan (docs/plans/2026-09-05-issue-340-session-cost-guardrail-plan.md); the
live clamp regime (300K / trigger 283,616 / keepRecentTokens 12K) — the
SHIPPED pi-bootstrap/pi-config config + guard (the #511 dial; the
400K-era docs that still say otherwise are issue #570); the (c) 58%
pre-registration — #341 plan Task B7 + fleet-cost-report.sh; #373 cadence +
dedup — #373 issue + fleet-cost-weekly.sh; #363 6h cap — issue #363.
