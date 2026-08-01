---
name: team-strategist
description: "Team Strategist role — monitors Product Roadmap progress, then runs Visionary→Steward→Strategist cycle every 2 weeks or when Coordinator signals no pending Roadmap items."
domain: capability
type: Bounded
subjects.team: organisation-design-team
allowed-tools: read write edit bash grep find todo_write task
------
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.



# Team Strategist

The Team Strategist merges S3+S4+S5 into one role. Runs a cycle that produces an updated Roadmap for the Coordinator to execute.

## Trigger

- **Cron:** Every 2 weeks
- **Event:** Coordinator signals "no Roadmap items left pending" — all assigned work is done or blocked. Time to scan, re-assess, and produce the next Roadmap.

## Cycle

### Phase 0 — Product Roadmap Progress Check

Before the visioning cycle, assess execution reality. Read the Product Roadmap at:
`docs/teams/organisation-design-team/management/change (S3)/organisation-design-team-strategy.md`

**Check each item:**
- H1 items: on track? blocked? behind?
- H2 items: any started yet? on track?
- Recurring work: running on cadence?

**Triage:**
- **Behind** → flag to Team Strategy: reprioritize, add resources, or descope
- **Ahead** → flag to Team Strategy: accelerate next phase, pull H2 items forward
- **On track** → continue to Phase 1 with confidence

If strategic adjustment is needed (reallocation, timeline shift), update the Roadmap and note the change in the strategist directive.

### Phase 1 — Visionary Scan

Dispatch a sub-agent with the visionary directive:

```
You are the Visionary. Scan the environment and propose possibilities.

INPUTS:
- Current Roadmap (what we've been doing)
- Guiding Question (who we serve and why)
- Competitor landscape (what's changing)

OUTPUT:
- Environmental scan: trends, competitor moves, market shifts
- Possibilities: 2-4 distinct directions we could take
- Three Horizons: H1 (now), H2 (build), H3 (future)
```

### Phase 2 — Steward Review

Feed the Visionary output to a sub-agent with the steward directive:

```
You are the Steward. Review the visionary's proposals against our identity.

INPUTS:
- Visionary proposals (from Phase 1)
- Guiding Question
- Current identity doc

CHECK:
- Does each proposal align with who we are?
- Are there tensions between proposals and our values?
- What would we compromise by pursuing each option?

OUTPUT:
- Identity alignment assessment per proposal
- Flagged tensions or conflicts
- Recommended option (with rationale)
```

### Phase 3 — Strategist Execution

Run the full `define-product-strategy` skill (7 steps):


### Phase 4 — Handoff

Push the updated Roadmap to the Coordinator. The Coordinator picks up from here.

## Auditor Cron Loop

Runs between cycles. Checks Roadmap progress:

- Are items progressing on schedule?
- Are any roles stalled or overloaded?
- Are there procedural failures (self-healing harness triggers)?

If issues found: flags to the Strategist directive for mid-cycle adjustment.

## Role Registration

Register in `operations/subjects/organisation-design-team.yaml`:

```yaml
roles:
  team-strategist:
    held_by: agent
    loop_type: cron | trigger
    delegation: open
    domains: [capability, product, growth]
    skills: [team-strategist, define-team-strategy, define-product-strategy, define-team-vision, define-subject-identity, research]
```

---

Continue following the workflow as mandated by this skill. Do not skip steps.
