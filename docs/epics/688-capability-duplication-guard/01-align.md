---
title: "Epic 688 — Strategy Alignment (Align stage)"
type: alignment
domain: capability
subjects.team: organisation-design-team
aboutObjects:
- agent-infra
- capability-duplication-guard
status: live
created: 2026-09-10
revision: 3
revision_note: "Cycle 1 (14 issues) + cycle 2 (12 issues). Revision 2 corrected cycle 1 but
  introduced its own errors: the ×6 retraction over-corrected (copies DO exist via
  install-tortoise-skills.sh), the instance-group trio is a pair, the reviewer-boundary
  claim cited the wrong reviewer set, and constraint 4 contradicted the owner-decided
  cross-repo split. VERDICT CHANGED from PROCEED to DEFER — see step 4."
verdict: DEFER (spike-only)
---

# Strategy Alignment Decision — #688

**Feature:** Capability-duplication guard — detect components serving a similar function, force an explicit unify-or-separate decision, and review it architecturally.
**Stage:** epic-workflow step 1 (Align) · **Skill:** `epic-align` · **Review cycles:** 2

---

## Step 1 — Adversarial Strategy Test

### Alternatives considered

| # | Alternative | Assessment |
|---|---|---|
| A1 | **Do nothing** — rely on human judgment and existing review | Rejected: the gap persisted through 11 existing guards (see corrected count below). But this is *not* the same as "add an explicit rule to the authoring path" — that is A6, which the first revision of this doc failed to consider |
| A2 | **Adopt off-the-shelf duplicate detection** (`jscpd` / PMD CPD / Sonar duplication budget in CI) | Accepted as a cheap floor. Catches literal copy-paste at near-zero cost. **Cannot** answer the actual question: token detectors find Type-1/2/3 clones and explicitly do not infer functional equivalence. Our real cases share almost no tokens |
| A3 | **Point-fix the known duplications** (consolidate `define-*`; resolve `find-bugs`/`security-review`) and skip the general guard | Strong. Rejected as a *substitute*: fixes the instances we can see and leaves the generator. **Accepted as parallel, non-blocked work** (was already required; now a binding constraint) |
| A4 | **Build the guard without Tortoise** — manifest + description matching only | Accepted as the **v1 fallback**. The reviewer is source-agnostic so this is a configuration choice. Note: the fallback carries the *same* unmeasured precision risk (K6b), so it does not de-risk the epic |
| A5 | **Redirect to infrastructure** — fix the replicated `.mcp.json` defect (#639) and secret handling (#693/#696) across six repos | **Genuinely in contention.** See displacement analysis below |
| **A6** | **Authoring-time rule** — add "search existing components for similar function; record unify-or-separate" to `skills/writing-skills` + `skills/issue-creation` (plus an optional PR-checklist item) | **Added in revision 2.** The cheapest intervention on this exact axis: no new machinery, no graph dependency, no added reviewer. **Assessed symmetrically (revision 2 flattered it):** its instruction *is* a retrieval step, so **K3 applies** — if retrieval separates on vocabulary rather than function, A6 fails for the same reason the epic does; and **K4 applies** — an unenforced prose rule is the intervention *most* likely to be silently ignored. A6 survives on cost and on covering *new* components (where a human/agent is already reading the corpus); it does **not** escape the precision question, and it does **not** cover the existing corpus |

### Argue against building this

1. **Review capacity, not detection, may be the binding constraint.** The target stages (`epic-plan` per-substep gates + Coherence Review, `issue-scoping` 2.5/5.5) already dispatch multiple reviewers per run, and `skills/reviewers/` alone holds 14. (Revision 2 cited "6 always-on reviewers" — that is the `code-review` PR-time set `Guidance/Bug-Shallow/Bug-Deep/History/PR-Comments/Security`, a **different pipeline** from the one being modified. The objection stands on the target-stage load, not on that number.) Adding a duplication reviewer may convert a *missed-detection* problem into an *alert-fatigue* problem — findings read, shrugged at, ignored. An advisory gate nobody acts on is worse than no gate: it manufactures the appearance of coverage.
2. **Type-4 semantic duplication is unsolved.** No tool does it. If the DISTINCT controls in the fixture set fire as often as the true pairs, the reviewer is wrong as often as right.
3. **Some duplication here is deliberate architecture.** `epic-plan` / `project-workflow` / `task-workflow-standard` implement *the same* six-stage pipeline at different levels. A guard that flags it fights the architecture; one that doesn't is inconsistent. **Cost acknowledged:** if JUSTIFY is the modal verdict, the machinery's normal output is "correctly found nothing" — hard to justify as Important.
4. **Cold start.** No registry, no component vocabulary (`reviewer`/`extension`/…), and validator defect #2839 blocking the intended modeling approach. The doc does not pretend v1 escapes this: the first runs operate with an empty or shallow registry, during which the reviewer is effectively manifest-only with no prior art to compare against.
5. **Advisory-only v1 may not change behaviour at all.** We rejected a blocking gate correctly (a hard dependency on graph availability across six repos is unacceptable). But an advisory reviewer never acted upon does not solve the problem it was created for.

### Corrected evidence base (this is the load-bearing claim — revision 1 stated it wrongly)

Revision 1 claimed "four guards touch adjacent concerns" with none owning duplication. **The audit's own labels contradict that** — three of the four were explicitly marked as *not* duplication-related (`AS2`: "Contradiction ≠ similarity"; `CSD5`: "Document-level redundancy, not component-level"; Agent #6 row: "None of those three reviewers does codebase-wide duplication-vs-existing analysis"). Inflating a weak signal 4× is exactly the post-rationalization the adversarial check exists to catch.

**Accurate count, from the audit's own labels:**

| Category | Count | Members |
|---|---|---|
| **Dedup by purpose**, both partial | **2** | `improvement-opportunities` IO3 (epic-Coherence-Review only) **and** `research-protocol` §1.5 — which is literally titled "Skill deduplication gate" (≥80% coverage → extend vs new), i.e. dedup by purpose too. Revision 2 filed §1.5 as merely "adjacent" and kept IO3 as the sole dedup guard; that split turned on *enforcement timing*, not purpose |
| Overlap / relationship guards (not dedup) | **3** | `epic-decompose` MECE gate (intra-epic issue set); `issue-scoping` Phase 3 `PARTIAL_IMPLEMENTATIONS` (collected, never adjudicated); `ux-verification` component catalog (UI-only) |
| Unrelated to duplication | **6** | `parallel_work_check` C1/C2 (fix/path-level); `code-review` Step 0.9 (file-level overlap, advisory); `architectural-soundness` AS2 (contradiction ≠ similarity); `cross-substep-drift` CSD5 (doc-level); `improvement-opportunities` IO7 (ADR suggestion); `code-review` Agent #6 dispatch set |

Revision 2's revision-note claim to have "corrected the adjacent-guard count" was itself inaccurate — the count was never the problem, only membership. **Total is 11, unchanged.**

**A1 is therefore rejected on ownership and narrowness, not on the guard count.** Revision 2's framing — "the gap persisted through 11 existing guards" — is unsound: 6 of the 11 do not address duplication and so cannot have failed at it. Two guards *do* address it by purpose (IO3, §1.5) and both are partial (epic-review-scoped; advisory-prose-scoped).

**The case therefore rests on ownership, not on count:** *no guard owns capability-level duplication across component classes.* The four adjacent mechanisms each cover one axis (skills only / UI only / one epic's children / unadjudicated) and none spans the repo. That is a real gap — but it is a **narrower** one than revision 1 implied, and A6 covers part of it cheaply.

### Opportunity cost & displacement analysis (A5)

Revision 1 dismissed A5 with "it is being handled on its own issues." **That was an assertion, not evidence.** Checked: #639, #693 and #696 are all **OPEN and unassigned**, all filed the same day. Nothing observable indicates they are in flight.

Honest sequencing decision, stated explicitly rather than assumed:

- **A5 is real, smaller, and has a proven failure record** (it affects every agent session on this machine, not just planning quality).
- **The two do not actually contend for the same scarce resource.** A5 is config/config-plumbing work; #688's next stage is a measurement plus skill prose. Neither requires the other's capacity.
- **Decision:** A5 proceeds on its own issues, unblocked and unsequenced against #688 — *and the burden for that claim is now the fact that no shared owner or shared bottleneck exists*, not the assertion that work is underway.
- If A5 stalls while #688 advances, that is a scheduling failure to surface, not a justification for this epic.

**Withdrawn:** the bespoke component index from #688's first draft — superseded by Tortoise, which already models mechanism Objects.

---

## Step 2 — Eisenhower Matrix

|  | **Urgent** | **Not Urgent** |
|---|---|---|
| **Important** | *(empty)* | **Schedule** |
| **Not Important** | *(empty)* | **Eliminate / Delegate** ← **SELECTED in revision 3** |

**Placement: Not Important / Not Urgent → Delegate (changed in revision 3).**

Revision 2 placed this at Important/Schedule on the grounds that "the gap is structural and compounding" — while the same document retracted the ×6 multiplier that was the sole basis for *compounding*. That is a self-contradiction, and the reviewer was right to flag it. **The word "compounding" is withdrawn with its basis.** Revision 2 also misattributed benefit: the epic's residual is *detection in the existing corpus*, while *prevention* is A6's job.

**Arguing the opposite placement explicitly — Not Important → Delegate:**

- No revenue path (the doc admits this).
- No breakage on slip (the doc admits this).
- The concrete known instances are served by accepted, cheaper alternatives: **A2** (jscpd floor), **A3** (point-fix), and — critically — **A6** (authoring-time rule), none of which needs a complex epic rated complex on two axes.
- The ×6 distribution argument that carried the "compounding" claim is **retracted** below, removing the main reason the gap compounds.
- The residual is an advisory artifact with unmeasured precision and, before revision 2, no decommission criterion.

**Which is more defensible:** revision 1 could not answer this, because it never subtracted A2/A3/A6 from the epic's value proposition. Revision 2 does that subtraction in step 4 and finds a **real but narrow residual**. The placement survives *only* on that residual — semantic near-duplicate detection that survives consolidation of the known instances — and only with a measured precision bar. **If the precision bar fails, this epic belongs in the Delegate cell.**

---

## Step 3 — Profit Growth Alignment

This is internal tooling. There is **no** feature → user behaviour → revenue path, and I will not invent one. Two honest chains, one of which revision 1 got wrong.

### Chain 1 — single-repo divergence (survives)

```
Duplicated agent-facing component (within agent-infra)
  → divergent or conflicting instructions to agents
  → inconsistent outputs on tortoise work
  → rework
  → reduced capacity for the revenue-bearing product
```

**Rough order of magnitude:** tens of dollars per month in avoided rework. No arithmetic supports this and I am not presenting it as more than a qualitative claim.

### Chain 2 — the ×6 distribution multiplier — **RETRACTED, then corrected**

Revision 1 claimed a duplicated component is "synced into six repos → N copies → every change costs ~6×". **That is unsupported.** But revision 2's correction was **also wrong** — it asserted flatly "there are no copies". Both mechanisms exist:

| Mechanism | Reality | Source |
|---|---|---|
| `scripts/link-skills.sh` | **Hard link** (`ln`, same-inode check at `:83-88`) of **top-level `skills/*/SKILL.md` only** (`:57-61`) | Fix lands once; no copies via this path |
| `scripts/install-tortoise-skills.sh` | **Real copies** — `rm -rf "$DEST/$s"; cp -r ...` (`:50-51`) into `.claude/skills`, `.codex/skills`, `.cursor/skills`, `~/.pi/agent/skills` | Copies persist until the installer is re-run |
| `sync.sh` (repo root — not `scripts/sync.sh`) | agent-infra self-update; distributes no skills | — |

Revision 1 also listed agent-infra among the repos things are "synced into" when agent-infra is the **source**.

**What actually survives:** copies exist for the tortoise-skill subset via the installer, and real divergence can arise from (a) per-repo local modifications, (b) deliberate forks, (c) component classes not distributed by either script, and (d) nested `skills/reviewers/*` (not linked). These are worth checking in Research — but they are **not** a mechanical ×6 multiplier and must not be asserted as one. **The duplication risk is located primarily inside agent-infra itself.**

### Cost side — previously an unstated zero

Revision 1 netted avoided cost against **zero** build cost. That is a missing assumption, now recorded as K7 in step 4.

### Faster path to the same outcome?

**Yes, and it should be taken in parallel rather than sequenced behind this epic:** A6 (authoring rule, ~10 lines of prose) + A2 (jscpd floor) + A3 (point-fix the known instances). This is now a binding constraint.

**Honest framing:** defensive maintenance on internal leverage, not a profit initiative. If it competed for the same capacity as revenue-bearing tortoise work it should lose. It is not competing — but nor is its value as large as revision 1 suggested.

---

## Step 4 — Decision Rationale

**Feature:** Capability-duplication guard (#688), with substrate epic tortoise#2835
**Decision:** **DEFER → REDIRECT.** Do A2 + A3 + A6 now. Authorise at most a **time-boxed spike** whose sole output is the precision measurement. Do **not** schedule the epic.

> **Verdict changed in revision 3** (was PROCEED). Reason: after the subtraction below, every assumption bearing on the residual is Low/unmeasured (K1b, K2, K3, K4, K6b, K7), the compounding basis was retracted, and the doc's own criterion was "the placement survives *only* with a measured precision bar" — a bar that does not yet exist. By its own logic the default is Delegate. Revision 2 argued itself into Delegate and then did not move; this revision moves.

### The subtraction (what this epic adds over A2 + A3 + A6)

| Covered cheaply | By | Not this epic |
|---|---|---|
| Literal/near-literal clones | A2 (`jscpd` class) | — |
| The known instance groups | A3 (point-fix) | — |
| New components, authoring time, by a human/agent following a rule | A6 | — |
| **Semantic near-duplicates in the *existing* corpus, undetected by rule-following** | — | ✅ **the residual** |
| **A durable, indexed record of *why* near-duplicates stayed separate** | — | ✅ **the residual** |

The residual is real and narrow. It is also **unmeasured** (K2/K3). The decision to proceed is therefore a decision to *measure first*, not to build first.

**Alternatives considered:** A1 (rejected — 11 guards, concern still unowned) · A2 (partially adopted as a floor) · A3 (**accepted, must ship independently**) · A4 (accepted as fallback, same precision risk, does not de-risk) · A5 (in contention; sequencing stated explicitly, no shared bottleneck) · **A6 (accepted, added in revision 2 — the strongest cheap competitor)**

**Profit impact:** indirect cost avoidance; Chain 1 only. The ×6 multiplier is retracted. Order of magnitude qualitative; not a forecast.

**Eisenhower placement: Not Important / Not Urgent → Delegate (revision 3).** Consistent with step 2. Revision 2 placed it at Important/Schedule *narrowed*; revision 3 moved it after subtracting A2/A3/A6 and retracting the compounding basis (line 88). **The Important / Not Urgent quadrant now carries no entry** — the word `Schedule` in that cell is the quadrant's conventional action label, not a placement of #688.

### Key assumptions

| # | Assumption | Confidence |
|---|---|---|
| K1a | Near-duplicate components **exist** | **High** — instance groups verified in-repo |
| K1b | At least one caused **measurable harm** (rework, conflicting instructions, mis-merged fix) | **Low — unmeasured.** Revision 1 rated K1 High by conflating existence with harm. "Exists" ≠ "worth detecting" ≠ "harmful" |
| K2 | An agent reviewer distinguishes UNIFY from JUSTIFY with usable precision | **Low–medium — unmeasured.** The epic's central risk |
| K3 | Retrieval separates on function, not vocabulary | **Low — unmeasured.** If false, Tortoise is the record layer only |
| K4 | Advisory findings will actually be acted on | **Low — unmeasured.** Alert fatigue is a named failure mode |
| K5 | Duplication propagates across repos | **Low — retracted in both directions.** `link-skills.sh` hard-links (no copies); `install-tortoise-skills.sh` **copies** a subset into 4 harness dirs. Which path dominates, and whether copied skills actually diverge in practice, is unverified |
| K6a | The **design** does not hard-depend on Tortoise | **High — verified structural property** |
| K6b | The **manifest-backed fallback** produces usable precision | **Low — unmeasured.** Revision 1 used K6a to imply the epic was off the unvalidated-risk path; it is not. It trades retrieval risk for reviewer-judgment risk |
| **K7** | Guard **build + ongoing maintenance cost** is small relative to avoided rework | **Low — unstated in revision 1, and the epic is rated complex on two axes.** Costs: fixture sets, retrieval eval, a new reviewer skill, pipeline wiring in 2–3 stages, 6-repo distribution, ongoing false-positive triage |

**Named instance groups — checked against the harm claim.** Three of revision 1's four "concrete instances" do not support K1b, and revision 2 got two of them wrong again:

- **The reviewer overlap is NOT generally boundary-managed.** Revision 2 asserted the quartet carries explicit `> **Boundary:**` declarations. Verified: of the overlapping reviewers named in #688, only `architectural-soundness` and `integration` carry one — `improvement-opportunities` and `cross-substep-drift` carry **none**. The declarations revision 2 cited (`→ risk-completeness`, `→ contract-completeness`, `↔ ux-coverage/e2e-coverage`) belong to a **different, complementary** reviewer set. Revision 2 also labelled six reviewers a "quartet". Correct position: **`improvement-opportunities` vs `cross-substep-drift` / `architectural-soundness` is unmanaged overlap** — the strongest remaining UNIFY candidate in the reviewer set (AS4 "Over-engineering" vs IO2 "Missed simplification", same axis, no boundary).
- The `supabase` pair is **upstream-vendored** with different scopes (products/CLI vs Postgres performance rules).
- **`define-team-strategy` does not belong in the group.** Verified: `type: Bounded` (the other two are `type: Workflow`) and **zero** occurrences of "gap analysis" or "initiatives" anywhere in the file. Revision 2 asserted all three share "gap analysis, initiatives, roadmap" — false.

**Surviving instance groups (two, not three):** `define-strategy` / `define-product-strategy` (both `type: Workflow`; one self-describes as generic, one as role-specialized) and `find-bugs` / `security-review` (both claim "find vulnerabilities"). **Note the open question this raises for A3:** the `define-*` pair is *role-specialization* — the textbook case objection 3 says must be respected. Whether A3's consolidation is a UNIFY or a JUSTIFY is **not resolved**, and K1b (harm) is unmeasured. A3 should not be pre-judged as consolidation.

### Binding constraints for Scope

These constraints bind any future re-entry. **Re-entry is conditional on all seven** (and on the precision bar from constraint 5 being measured — see the re-entry trigger below):

1. **Advisory, non-blocking.** No gate fails because Tortoise is unreachable or stale. Load-bearing: a blocking version revisits A5 as the better use of capacity.
2. **Candidate source is an interface, not a dependency.** Two implementations (repo-manifest, graph-backed), selected by configuration. Keeps the epic off the unvalidated retrieval layer's critical path.
3. **Instrument adoption (K4).** v1 records whether findings are acted on.
4. **Freshness must be owned by #688, not delegated.** ⚠️ The failure mode named as *worse than an outage* is a graph that is **reachable and stale** — answering "no duplicates found" authoritatively while the registry is weeks old. Revision 1's constraint 1 covered only unreachability and pushed the degradation contract to tortoise#2835, which would let the consumer ship **silent stale-authoritative findings** — the manufactured coverage this epic exists to prevent. **v1 must stamp every finding with its source's freshness (revision + age) and emit an explicit low-confidence/stale warning above a defined TTL. A stale registry is reported as degraded, never as evidence of absence.**
5. **Precision bar with a kill condition.** Define a precision threshold against the JUSTIFY fixture set, below which v1 either does not ship or ships explicitly low-confidence. Define a review checkpoint (after N real planning runs) at which adoption + precision data are evaluated, and an explicit **stop/kill condition and owner** if it fails. Constraint 3 alone cannot distinguish an almost-always-right signal from an almost-always-wrong one.
6. **A3 ships independently. #688 is never its prerequisite.** The known instances must not wait on this machinery.
7. **JUSTIFY must be a first-class *output*, not merely a fixture class.** v1 emits a durable, indexed separation record with rationale. **A JUSTIFY verdict with no record is the guard's failure condition** — without it, the guard is a false positive on deliberate architecture (objection 3).

**Recommendation:** **DEFER / REDIRECT.** Ship the cheap interventions now — **A6** (authoring rule in `writing-skills` + `issue-creation`), **A2** (jscpd-class floor), **A3** (resolve the two surviving instance groups, deciding UNIFY vs JUSTIFY on evidence rather than assumption). Authorise at most a **time-boxed spike** whose single deliverable is the precision measurement on the fixture set (tortoise#2835 R1 + a manifest-backed path). The reviewer is built **only if that measurement clears a pre-declared bar**; otherwise this epic is closed.

This is not a retreat from the owner's goal — it is the same goal reached by the cheapest path. The goal ("near-duplicates get detected and explicitly decided") is served by A6+A2+A3 for every case we can currently evidence; the reviewer only adds value for semantic near-duplicates in the **existing** corpus, which is precisely what is unmeasured.

**If PROCEED is nonetheless directed by the owner**, the pipeline must still run the full fix-loop to convergence first — constraints 1–7 in this document are the minimum conditions, and cycle 3 has not been run (this revision is un-reviewed).

### Constraints 4, 5, 7 — corrected per cycle 2

- **Constraint 4 (freshness) — rewritten as a joint interface, not a unilateral re-scope.** Revision 2 claimed freshness "must be owned by #688, not delegated", contradicting the owner-decided split (substrate = #2835) and infeasible as written (#688 cannot stamp a source with a revision/age that #2835 does not expose). **Correct form:** *#2835 must expose source revision + age; #688 must surface it and warn above a TTL.* Freshness **contract** with #2835; **reporting obligation** with #688. The underlying requirement is also not new — the owner comment on #688 already stated "degradation → says so; silent degradation forbidden".
- **Constraint 5 (precision bar) — made binding.** Revision 2 offered "does not ship **or** ships low-confidence" with no threshold, no N, no owner — a disjunction every finding can satisfy by relabelling, making "PROCEED is conditional" vacuous. **Correct form:** the threshold, N and kill-owner are **set in Research with a hard deadline**; the low-confidence path is a **separate, separately-gated route with its own re-measurement date**, so the default failure action is genuinely *do not ship*.
- **Constraint 7 (separation record) — home defined per source.** Revision 2 required a durable indexed record while constraints 1–2 forbid depending on Tortoise availability, leaving the record homeless under the manifest fallback — which contradicts **K6a** ("no hard Tortoise dependency", rated High). **Correct form:** specify where the record lives under *each* candidate source (graph / manifest), and split K6a into design-level (High) vs record-level (unmeasured). Add an assumption for **record retrievability at the next decision point** — a record nobody can find prevents nothing.

### Additional missing assumptions (cycle 2)

- **K8 — a usable, non-circular ground-truth fixture set can be built.** Constraint 5's precision bar needs labelled fixtures; the fixtures must be representative and must **not** be labelled by the same reviewer being measured. Unmeasured. (The three-class fixture set posted to tortoise#2835 is a start, and its labels are explicitly provisional.)
- **K9 — the separation record is retrievable by the next agent.** Folded conceptually into K3, recorded here because constraint 7 depends on it.
