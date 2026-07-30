---
name: experiment-analysis
description: Analyze A/B/n experiment results accounting for mid-experiment fixes, data quality degradation, and issue/PR timelines. Produces a structured analysis report with statistical rigor, data quality tiers, and decision recommendations. Use when asked to "analyze the experiment", "what did the test show", "experiment results", or "should we ship the winner".
allowed-tools: read write edit bash grep find web_search web_fetch todo_write task
version: 1.0.0
---
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

# Experiment Analysis

> **Ontology:** `docs/teams/organisation-design-team/data/ONTOLOGY.md` — canonical entity classes, work vocabulary, domain taxonomy.

Analyzes A/B/n experiment results with explicit accounting for mid-experiment fixes, data quality, and issue/PR timelines. Produces a structured report at `docs/experiments/<key>_analysis.md` and updates the experiment tracker.

## When to Use

- Analyzing an active or completed experiment
- Answering "what did this experiment show?"
- Deciding whether to ship, iterate, or kill a variant
- Mid-experiment health checks (directional readout only)

## When NOT to Use

- Designing a new experiment → use `epic-workflow` or `issue-scoping`
- Fixing bugs discovered during an experiment → use `debug-workflow`
- Writing the experiment layer code → use `executing-plans`

## Prerequisites

Before starting, the agent must have:
- The experiment key (e.g., `claim_friction_v1`)
- Access to Supabase (for analytics data) and GitHub CLI (for issue/PR timelines)
- If Clarity data is relevant, the experiment's date range for session recording filters

---

## Process

### Phase 0 — Gather Experiment Configuration

Read the experiment design from available sources:

1. **Database (preferred):** Query `experiments` and `experiment_variants` tables:
   ```sql
   SELECT e.*, ev.variant_label, ev.config, ev.sort_order
   FROM experiments e
   JOIN experiment_variants ev ON ev.experiment_id = e.id
   WHERE e.experiment_key = '<key>';
   ```

2. **Fallback — docs:** Read `docs/teams/eldato-app-team/growth/experiment_layer.md` for the experiment's design notes.

3. **Fallback — experiment doc:** If a plan doc exists at `docs/plans/*<key>*`, read it.

**Extract from config:**
- Variant labels, weights, and descriptions
- Primary metric (exposure_event → conversion_event)
- Secondary metrics
- Experiment start date, target sample sizes
- Assignment unit (per-user, per-session, per-scan)

### Phase 1 — Gather Analytics Data (4 Sources)

The internal `analytics_events` table is the primary source, but events may only exist in GA4, Meta Pixel, or Clarity. Cross-reference all four to find gaps and corroborate findings.

#### 1.1 Internal Analytics (`analytics_events` — primary)

Query the DB for funnel data:

1. **Via `get_experiment_results` RPC** (preferred, if available):
   ```sql
   SELECT * FROM get_experiment_results('<key>', '<exposure_event>', '<conversion_event>');
   ```

2. **Raw analytics query** (fallback):
   ```sql
   -- Exposure (denominator)
   SELECT params->>'variant' AS variant, COUNT(*) AS exposures
   FROM analytics_events
   WHERE event_name = '<exposure_event>'
     AND params->>'experiment_key' = '<key>'
     AND created_at >= '<start_date>'
   GROUP BY 1;

   -- Conversion (numerator)
   SELECT params->>'variant' AS variant, COUNT(DISTINCT session_id) AS conversions
   FROM analytics_events
   WHERE event_name = '<conversion_event>'
     AND params->>'experiment_key' = '<key>'
     AND created_at >= '<start_date>'
   GROUP BY 1;
   ```

3. **Daily breakdown** (for timeline analysis):
   ```sql
   SELECT DATE(created_at) AS day, params->>'variant' AS variant,
          COUNT(*) FILTER (WHERE event_name = '<exposure>') AS exposures,
          COUNT(DISTINCT session_id) FILTER (WHERE event_name = '<conversion>') AS conversions
   FROM analytics_events
   WHERE params->>'experiment_key' = '<key>'
     AND created_at >= '<start_date>'
   GROUP BY 1, 2
   ORDER BY 1, 2;
   ```

4. **Secondary funnel steps** (if applicable):
   Query each intermediate event broken down by variant.

#### 1.2 GA4 (Google Analytics 4 — gap detection)

GA4 may have events that never reached `analytics_events` (client-side only, DB-persistence gaps, or events not in the DB allowlist). For every funnel step, check:

```bash
# Query GA4 via the analytics API or Looker Studio connection
# Check: does GA4 report the same event counts as analytics_events?
# If GA4 shows N events but analytics_events shows 0 → persistence gap.
```

**Key check:** For each funnel step event, ask:
- Does this event exist in BOTH GA4 and `analytics_events`?
- If GA4-only: note as a **data gap**. The event fires client-side but isn't persisted to DB. Quantify the gap size.
- If counts diverge significantly (>10%): investigate. Could indicate bot filtering differences, consent-gating, or tracking bugs.

**Example from claim_friction_v1:** `claim_modal_opened` had 0 rows in `analytics_events` but existed in GA4 — the Clarity team could see ClaimModal opens, but the DB couldn't. This gap prevented quantifying the ClaimModal drop-off rate.

#### 1.3 Meta Pixel / CAPI (ad-facing experiments only)

If the experiment affects pages that receive paid traffic (deal pages, landing pages, marketplace):

```bash
# Check Meta Events Manager for the experiment period
# Compare conversion counts: Meta Pixel vs analytics_events vs GA4
```

- **Meta Pixel** fires client-side — subject to ad blockers, consent gating, and browser restrictions
- **CAPI** (Conversions API) fires server-side — more reliable but different event model
- **Cross-reference:** If Meta reports conversions the DB doesn't see, the DB may be missing ad-attributed conversions
- **Attribution differences:** Meta uses view-through + click-through attribution; the DB uses session-based attribution. Expect differences — flag them, don't force them to match.

#### 1.4 Cross-Source Reconciliation

For every primary metric, produce a source comparison:

```
| Event | analytics_events | GA4 | Meta Pixel | Clarity | Notes |
|---|---|---|---|---|---|
| view_item | 423 | 445 | — | — | GA4 ~5% higher (bot filtering?) |
| claim_modal_opened | 0 | 87 | — | 89 sessions | DB gap — event not persisted |
| reserve | 31 | 35 | 28 | — | Meta 10% lower (ad blockers) |
```

**Action on gaps:**
- DB-only gap (GA4 has events, DB doesn't): flag as tracking debt. File an issue to add the event to the DB allowlist.
- Source divergence >20%: investigate before concluding. Could indicate variant-specific tracking bugs.
- Meta Pixel present, DB absent: the experiment may have ad-attributed conversions not visible in the DB funnel.

### Phase 2 — Gather Fix Timeline (GitHub Issues & PRs)

This is the **key differentiator** of this skill. Map everything that touched the experiment.

```bash
# Issues and PRs mentioning the experiment key
gh search issues "experiment <key>" --repo $GITHUB_REPO --state closed --limit 30 --json number,title,state,closedAt,labels
gh search prs "<key>" --repo $GITHUB_REPO --state merged --limit 30 --json number,title,mergedAt,labels

# Broaden: issues in date range mentioning affected components
gh issue list --repo $GITHUB_REPO --search "created:>=$(date -d '<start>' +%Y-%m-%d)" --state closed --limit 50 --json number,title,closedAt,labels
```

For each fix found, classify its impact:

| Classification | Criteria | Example |
|---|---|---|
| **Blocking (P0)** | Variant completely broken — users couldn't complete the action | #3822: auth-only mode never wired |
| **Degrading (P1)** | Variant worked but disproportionately affected vs other arms | #3826: DOM manipulation → 80 dead clicks on control only |
| **Symmetric (P2)** | Affected all variants equally | Generic pipeline fix |
| **Irrelevant (P3)** | Unrelated to the experiment surface | Backend refactor |

**Fix timeline table:**

| Date | Issue/PR | Classification | Impact Description | Variants Affected |
|---|---|---|---|---|
| Jun 15 | #3779 P0 | Blocking | 10 events dropped from DB | ALL (control worst) |
| Jun 15 | #3783 P1 | Degrading | QR download broken on mobile | no_claim |
| Jun 16 | #3826 P0 | Blocking | MethodMenu DOM bug → 211 dead clicks | control_timer, control_no_timer |

### Phase 3 — Data Quality Assessment

Cross-reference the fix timeline against the experiment's date range to create per-variant data quality tiers.

**Rules:**

1. **Discard window:** Data from experiment start until the **last Blocking (P0) fix** affecting that variant. If broken until Jun 16, all pre-Jun-16 data is discarded.

2. **Polluted window:** Data between last Blocking fix and last **Degrading (P1) fix**. Use with caveats, downweighted.

3. **Clean window:** Data after all P0 and P1 fixes are merged. Primary decision data.

4. **Variant-specific:** When fixes affect variants unequally, quality windows are per-variant, not global.

**Quality tiers table:**

| Window | Dates | Variants | Quality | Weight | Use |
|---|---|---|---|---|---|
| Pre-fix | Jun 12–14 | ALL | Discard | 0 | Excluded |
| Partial fix | Jun 15–18 | control_timer, control_no_timer | Polluted | 0.3 | Caveated |
| Partial fix | Jun 15–18 | no_claim | Good | 0.7 | Included |
| Clean | Jun 19–22 | ALL | Clean | 1.0 | Primary |

**Weighting:**
- Clean = 1.0 | Good (minor symmetric) = 0.7 | Polluted (disproportionate) = 0.3 | Discard = 0

Weighted conversion = Σ(day_exposures × day_weight × day_rate) / Σ(day_exposures × day_weight)

**Conclusion gating — no fixed N threshold:** Statistical significance (Fisher's Exact / Chi-squared) already accounts for sample size — a 30/35 vs 5/35 split is significant at N=70. The gate is not an arbitrary N but whether the effect is **detectable** given your data:

- **p < 0.05 AND effect size ≥ minimum-practical-difference → CONCLUDE.** Even at small N, if the effect is large enough to be statistically significant AND practically meaningful, you can act.
- **p ≥ 0.05 AND effect size large (>10pp) → DIRECTIONAL.** Worth gathering more data, but the direction is informative for decisions. Flag as "needs more data to confirm."
- **p ≥ 0.05 AND effect size small → INCONCLUSIVE.** Cannot distinguish signal from noise. Extend experiment or redesign.
- **Regardless of N, always report confidence interval width.** A 30/35 vs 5/35 split (p=0.001) is conclusive at any sample size. An 8/35 vs 5/35 split (p=0.54) is not — regardless of whether N=35 or N=350.

**Minimum-practical-difference:** Before the experiment, note what effect size would change a decision. If you'd ship a variant that improves conversion by 5pp, then a 2pp difference at p<0.05 with wide CI is statistically significant but not practically meaningful — flag this tension.

### Phase 4 — Clarity UX Data (always check)

Clarity provides the **qualitative layer** — session recordings, dead clicks, rage clicks — that explains the quantitative funnel data.

Use `mcp__clarity__query-analytics-dashboard` for the experiment period:

```bash
# Query dead clicks, rage clicks, excessive scroll, quick backs
# Filter by URLs matching the experiment surface
```

**Cross-reference with other sources:**
- Dead click on "Claim" button + GA4 shows zero `claim_modal_opened` → the button was broken, not just unused
- Rage clicks on MethodMenu + `analytics_events` shows 0 method selections in control arms → #3826 DOM bug, confirmed
- Quick-back rate 3× higher on variant B → users bounced immediately, explains the low conversion rate

**Map every Clarity finding back to a quantitative source:**

```
| Clarity Signal | Count | Matches DB Event? | Matches GA4? | Root Cause |
|---|---|---|---|---|
| Dead click "Selecciona método" | 80 | method_selected=0 in control | claim_modal_opened=87 in GA4 | #3826 DOM bug |
| Rage click "Descargar QR" | 9 | QR download=0 pre-Jun15 | — | #3783 mobile broken |
```

```
| Clicked Text | Dead Clicks | Rage Clicks | Variant Impact | Root Cause |
|---|---|---|---|---|
| "Selecciona método" | 80 | 0 | control_timer, control_no_timer | #3826 MethodMenu DOM |
```

### Phase 5 — Statistical Analysis

Run on **three slices**: all-time, clean-only, weighted.

#### 5.1 Primary Metric

- Any cell < 5: Fisher's Exact Test (two-tailed)
- All cells ≥ 5: Chi-squared test
- >3 pairwise comparisons: Benjamini-Hochberg FDR correction

```
| Comparison | Rate A | Rate B | Test | p-value | p-adj | Significant? |
|---|---|---|---|---|---|---|
| B vs A | 5.2% vs 2.9% | Fisher | p=0.39 | — | ❌ |
| C vs A | 0% vs 2.9% | Fisher | p=0.009 | — | ✅ |
```

#### 5.2 Minimum Sample Size

For non-significant comparisons (p ≥ 0.05), compute required n at 80% power:

n = 2 × (1.96 + 0.84)² × p̄(1-p̄) / δ²

```
| Comparison | Observed δ | n Required per Arm | Current n | Deficit |
|---|---|---|---|---|
| B vs A | 2.3pp | ~1,100 | 103–212 | ~4× |
```

#### 5.3 Bayesian (optional, n ≥ 100/arm)

Beta(1,1) prior. Compute P(variant > control) and expected loss. Skip if n < 100/arm.

#### 5.4 Secondary Metrics

Report per-variant rates. Flag arm-asymmetry. Do not use for primary conclusion.

### Phase 6 — Generate Analysis Report

Write `docs/experiments/<experiment_key>_analysis.md`:

```markdown
# <Experiment Name> — Experiment Analysis Report

**Date:** YYYY-MM-DD
**Experiment:** `<key>` (status, since start)
**Primary metric:** `<exposure>` → `<conversion>`
**Analysis window:** <full range>, post-fix window <clean range>

---

## 1. Experiment Design

| Variant | Weight | N (assigned) | Behavior |
|---|---|---|---|
| ... | ... | ... | ... |

## 2. Fix Timeline — Data Quality Impact

| Date | Issue | Impact on Data |
|---|---|---|
| ... | ... | ... |

**Data quality tiers:**
- **range:** tier. justification. **action.**

## 3. Funnel Analysis

### 3.1 All-Time Funnel

| Step | variant_a (N=..) | variant_b (N=..) | ... |
|---|---|---|---|
| ... | ... | ... | ... |

## 4. Cross-Source Reconciliation

| Event | analytics_events | GA4 | Meta Pixel | Clarity | Notes |
|---|---|---|---|---|---|
| ... | ... | ... | ... | ... | ... |

**Gaps found:** ...

## 5. Clarity UX Data (if applicable)

| Clarity Signal | Count | Matches DB? | Matches GA4? | Root Cause |
|---|---|---|---|---|
| ... | ... | ... | ... | ... |

## 6. Statistical Assessment

### 6.1 Primary Metric (All-Time)
### 6.2 Primary Metric (Clean Window)
### 6.3 Minimum Required Samples
### 6.4 Bayesian (if applicable)

## 7. Post-Fix Data (<clean range>)

| Step | variant_a (N=..) | variant_b (N=..) | ... |
|---|---|---|---|
| ... | ... | ... | ... |

> ⚠️ If effect is not statistically significant AND effect size is below minimum-practical-difference → inconclusive. If significant at any N → report with confidence interval width noted.

## 8. Conclusions

### Winner: `<variant>`

| Claim | Confidence | Evidence |
|---|---|---|
| ... | High/Directional/Weak | ... |

### Key Tradeoffs

| Variant | Strengths | Weaknesses |
|---|---|---|
| ... | ... | ... |

### Why `<winner>` Wins
1. ...
2. ...

## 9. Recommendations

### Immediate
1. ...

### Short-term
2. ...

### Watch-outs
- ...

## 10. Methodology Notes

- Test choice rationale, metric symmetry, exclusion criteria, weighting, corrections, limitations

## Appendix A: Daily Assignment Volume

| Date | variant_a | variant_b | ... | Total |
|---|---|---|---|---|
| ... | ... | ... | ... | ... |

## Appendix B: Issues Referenced

| Issue | Title | Status | Date |
|---|---|---|---|
| ... | ... | ... | ... |
```

### Phase 7 — Review Cycle

Dispatch **2 reviewers in parallel** via `task`:

#### Reviewer #1 — Statistical Rigor

```
You are reviewing an experiment analysis report for statistical soundness.

Read: docs/experiments/<key>_analysis.md

Check:
1. Test choice appropriate for sample sizes?
2. Multiple comparisons: FDR correction applied when >3 pairwise?
3. Conclusions gated on sufficient n?
4. Weighting logic defensible? Tier boundaries justified per variant?
5. Primary metric symmetric across arms?
6. Missing analyses?
7. Overstatement beyond data support?

Return ISSUE: dimension:statistical-rigor severity:P0|P1|P2 location:<section> description/suggestion
Or: NO ISSUES FOUND
```

#### Reviewer #2 — Data Quality & Causal Coherence

```
You are reviewing an experiment analysis report for data quality and causal reasoning.

Read: docs/experiments/<key>_analysis.md

Check:
1. Fix timeline complete? Run gh search issues/prs for experiment key + date range.
2. Fix-to-variant mapping accurate? Per-variant classification correct?
3. Data quality windows reasonable and per-variant where needed?
4. Confounding factors accounted for (weekday, traffic source, seasonality)?
5. Cross-source reconciliation: Do GA4, Meta Pixel, Clarity, and analytics_events agree? Are gaps flagged?
6. Clarity data corroborates or contradicts quantitative findings?
7. Structural arm asymmetry missed (events firing differently per arm)?
8. Meta Pixel conversions present but DB doesn't see them? Ad-attributed conversions unaccounted for?
9. Recommendations supported by both data AND data quality assessment?

Return ISSUE: dimension:data-quality severity:P0|P1|P2 location:<section> description/suggestion
Or: NO ISSUES FOUND
```

#### Fix Loop

1. Fix issues in the report
2. Re-dispatch BOTH reviewers (fresh `task` sub-agents — no memory of prior cycles)
3. Loop until clean or convergence. **No hard cap.** Quality over cycle count.
4. Stall detection: if ≥80% of issue fingerprints match previous cycle → escalate to user
5. Escalation guard: same issue surviving 3+ cycles → escalate with fix history
6. Safety cap at 10 cycles (runaway loop guard, not a quality gate)

**Exit:** Both reviewers return "NO ISSUES FOUND" in the same cycle, OR convergence detected + user acknowledges remaining issues.

### Phase 8 — Integration

1. **Update experiment tracker** (`docs/teams/eldato-app-team/product/experiments.md`):
   - Move to Completed section. Fill Results, Learnings, Next Action. Link report.

2. **Post summary on analysis issue:**
   ```bash
   gh issue comment <N> --body "Analysis done: docs/experiments/<key>_analysis.md

   **Winner:** <variant> (p=<value>)
   **Recommendation:** <1-line>
   **Data quality:** <clean window summary>"
   ```

3. **Update `docs/teams/eldato-app-team/growth/experiment_layer.md`** if experiment changes layer behavior.

4. **Checkpoint** for cross-session learning.

---

## Quick Reference

### Statistical Methods

| Situation | Method |
|---|---|
| Any cell < 5 | Fisher's Exact (two-tailed) |
| All cells ≥ 5 | Chi-squared |
| >3 pairwise comparisons | Benjamini-Hochberg FDR |
| Sample size planning | Two-proportion z-test power |
| Bayesian (n ≥ 100/arm) | Beta(1,1) prior, Monte Carlo |

### Data Quality Decision Tree

```
Variant broken (action impossible)?
├── YES → Discard (weight 0)
└── NO → Disproportionately affected vs other arms?
    ├── YES → Polluted (weight 0.3)
    └── NO → Any fix during window?
        ├── YES → Good (weight 0.7–0.9)
        └── NO → Clean (weight 1.0)
```

### Output Checklist

- [ ] Experiment design: weights + N per variant
- [ ] Fix timeline: ALL issues/PRs from experiment window
- [ ] Data quality tiers: per-variant, not just global
- [ ] Funnel table: every step with per-variant counts and rates
- [ ] Statistical tests: all-time AND clean-window comparisons
- [ ] Sample size: minimum required n computed for non-significant
- [ ] Clarity data cross-referenced (if applicable)
- [ ] Conclusions gated by data quality (no overstatement)
- [ ] Recommendations: specific, time-bound, data-supported
- [ ] Appendices: daily breakdown + issue reference table
- [ ] Both reviewers: "NO ISSUES FOUND" in final cycle
- [ ] Experiment tracker updated with results/learnings
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
