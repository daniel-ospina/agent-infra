> **Step 6/6** | ← requires: Step 1 (mode = incremental update or review secrets) | → next: end (optionally transition to incremental update from review)

# Incremental Update & Review Secrets Modes

> **Read before starting:** `references/protocols.md`, `references/context-management.md`

---

## Incremental Update Mode

### Trigger

User has new data: customer discovery notes, experiment results, outreach learnings, market changes.

### Process

#### I.1 Intake
Read `strategy.md`, `earned_secrets.md`, `experiments.md`. User provides new data.

#### I.2 Add insights to earned_secrets.md
- Field notes for raw observations
- Promoted to secrets if they pass qualification: non-obvious + actionable + earned

#### I.3 Update experiments.md
If results provided. Trigger pivot-or-persevere if warranted.

#### I.4 Research (5-10 queries to contextualize new findings)

#### I.5 Propose strategy updates
For each affected section: current state, what new data suggests, proposed change, confidence level.

#### I.6 Highlight confirms vs contradicts
Which existing claims are strengthened, contradicted, or unaffected.

#### I.7 Human gate
See `references/protocols.md` → Human Gate Protocol.

#### I.8 Apply changes + commit

#### I.9 Scope-triggered coherence check
- If 3+ sections changed → full coherence review (Phase 7 in `05-full-build-experiments.md`)
- If <3 → brief consistency check

#### I.10 Pitch component impact
Flag which components need updating, add to §7.4 update queue.

#### I.11 Commit

---

## Review Secrets Mode

### Trigger

Review accumulated earned secrets for patterns, without new data.

### Process

#### R.1 Read earned_secrets.md + strategy.md headers
Note last review date.

#### R.2 Pattern analysis
- Cluster by tags
- Identify themes (3+ secrets same direction), contradictions, surprises
- Apply qualification test: demote entries that no longer pass (non-obvious + actionable + earned)

#### R.3 Research (3-5 queries to validate emerging patterns)

#### R.4 Present patterns
What each suggests, which strategy sections affected, recommended action.

#### R.5 Human discussion
"What patterns do you see that I might be missing?"

#### R.6 Update review log in earned_secrets.md

#### R.7 Optional: transition to Incremental Update
If patterns warrant strategy changes → run Incremental Update mode above.

#### R.8 Commit
