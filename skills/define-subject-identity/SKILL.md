---
name: define-subject-identity
description: "Defines S5 (Identity) artifacts — guiding question and policy table — for any function, team, or role."
domain: capability
type: Bounded
subjects.team: organisation-design-team
allowed-tools: read write edit bash grep find todo_write task
------
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.



# Define Subject Identity (S5)

Produces the S5 Identity artifact for any function/team/role. The identity is a Guiding Question (what this function exists to explore) and a Policy Table (operational edges, filled as needed over time).

## Process

### 1. Identify Stakeholders
Who depends on this function? List who1, who2, whoN — each stakeholder the function serves.

### 2. Define Needs
For each stakeholder: what do they need from this function? Be specific. This is the why.

### 3. Synthesize Guiding Question
Combine all stakeholders and needs into one question this function exists to explore. The question should:
- Acknowledge the core tension/paradox
- Be open-ended — explored, not answered
- Be honest about trade-offs
- Serve as the north star for all downstream S4/S3/S1 work

### 4. Create Policy Table
Empty table with columns: Policy | What It Means | How Enforced Today. Policies are added as needed over time — not pre-populated during identity creation.

### 5. AI Review Gate

Before the human gate, run an automated review to catch issues early.

**Dispatch a fresh `task` sub-agent reviewer:**

```
You are reviewing an S5 Identity artifact for quality and completeness.

IDENTITY DRAFT:
- Guiding Question: <question>
- Policy Table: <table content>
- Stakeholders: <list>
- Needs: <per-stakeholder need list>

CHECK:
1. Is the guiding question honest about tensions and trade-offs? Does it acknowledge paradox rather than paper over it?
2. Are all stakeholders identified? Are there missing stakeholders who depend on or are affected by this function?
3. Are stakeholder needs accurately captured? Are they specific (not generic) and traceable to real requirements?

For each issue:
ISSUE:
  severity: P0|P1|P2
  description: <what's wrong>
  suggestion: <how to fix>

P0=fundamental flaw in identity, P1=important gap, P2=improvement
If no issues: NO ISSUES FOUND
```

**Review loop:**
1. Dispatch reviewer via `task` tool (fresh `pi -p` session)
2. "NO ISSUES FOUND" → exit clean. Issues found → step 3.
3. Apply fixes to the guiding question, stakeholder list, or needs
4. Re-dispatch reviewer → repeat until clean

### 6. Human Approval Gate
Identity is S5 — the seat of taste, values, and purpose. The guiding question and policy table MUST be reviewed and approved by a human before filing. No exceptions. This is an algedonic boundary: identity defines what the system IS. An agent cannot decide that alone.

### 7. File
Write the identity document to `management/identity (S5)/<name>-identity.md`.

## Output Format

```yaml
---
title: "<Name> — Identity (S5)"
type: identity
domain: capability
ownedBy: <persona>
status: draft
created: <date>
---
```

### Guiding Question
> <question>

### Stakeholders
| Who | Need |
|-----|------|
| ... | ... |

### Policy Table
| Policy | What It Means | How Enforced Today |
|--------|---------------|-------------------|
| (empty — fill as needed) | | |
```

---

Continue following the workflow as mandated by this skill. Do not skip steps.
