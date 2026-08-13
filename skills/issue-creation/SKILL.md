---
name: issue-creation
description: Use when creating GitHub issues, when epic-decompose generates child issues, or when a standalone feature needs an issue with O/I/T, affiliation, and domain-aware complexity before planning begins.
domain: capability
allowed-tools: read write edit bash grep find web_search web_fetch
version: 2.0.0
---

> ⛔ **This skill MUST be read and followed in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

# Issue Creation

## Overview

Creates GitHub issues with three required sections: **Objective/Indicator/Target (O/I/T)** (what, how measured, bar), **affiliation** (who owns it), and **domain-aware complexity** (how hard, which domains). Everything else is important context.

**Announce at start:** "I'm using the issue-creation skill."

### When to Use

- When `epic-decompose` creates child issues (batch mode)
- When creating a standalone issue (no epic)
- When an issue exists but lacks O/I/T, affiliation, or complexity ratings

### When NOT to Use

- When planning an existing issue for implementation → use `issue-scoping` and the rest of the issue workflow skills.
- When the issue already has all three required sections → skip

---

## Micro Fast-Path

For trivial fixes with zero ambiguity, skip sections 2–4 and create directly:

**Conditions (ALL must be true):**
- 1–5 line change, single file
- No significant UX, ontology, architecture, content, config, research, or org-infra impact
- The fix is obvious from a one-line description
- O/I/T is micro and self-evident (e.g., "Fix typo in README")
- The file being changed has at least one existing test. If the file has zero test coverage and the change touches logic (not pure strings/constants), upgrade to `complexity:standard` — the file needs test infrastructure before adding more code.

```bash
gh issue create --title "fix: <one-liner>" --label "complexity:micro" --body "..."
```

---

## Section 1 — O/I/T (Objective, Indicators, Targets)

Every issue starts with what outcome it achieves, how we know it's done, and what "done" looks like.

### Objective

State in one sentence. Can be either:
- **A problem:** "Users can't reset passwords from the login page"
- **A function:** "Password reset flow for the auth module, needed for self-service account recovery"

**Nudge:** If you can't state the objective in one sentence, the issue isn't ready to be created. Go back and clarify the scope (clarifying questions).

### Indicators

How will we know it's done? At least 2 measurable indicators (single-indicator invites Goodhart's Law gaming):

```
✅ "Login flow passes 3 test scenarios AND TypeScript compiles clean"
✅ "Page loads under 2s (Lighthouse) AND no console errors"
❌ "Code compiles" (single indicator — what about tests? what about behavior?)
```

### Targets

The bar for each indicator:

```
- 0 type errors
- All 3 test scenarios pass
- Lighthouse score ≥ 90
```

---

## Section 2 — Affiliation (Team / Role)

Who owns this work.

### Resolution Order

1. Inherit from parent epic (`**Team:** <slug>` in the epic's issue body)
2. Environment: `AGENT_SESSION_TEAM` / `AGENT_SESSION_ROLE`
3. Org data SOR: swarm Supabase SOR (teams/roles tables) via `node scripts/swarm-org.mjs resolve-role <slug>` or `list-teams` (requires `SUPABASE_URL_ORG_DATA` + `SUPABASE_SERVICE_ROLE_KEY_ORG_DATA`; derived YAML mirror: swarm repo `operations/subjects/*.yaml`)
4. Escalation: if unresolved or SOR unreachable → `**Team:** unknown` (triggers escalation comment)

### Apply Labels

```bash
node scripts/swarm-org.mjs list-teams | grep -q "\"slug\": \"$TEAM\"" && \
  gh issue edit $ISSUE_NUMBER --add-label "team:$TEAM" || \
  echo "[issue-creation] team:$TEAM label skipped — verify team exists in swarm SOR" >&2
```

Fail-open — labeling never blocks creation. (The eldato-era `scripts/subjects-labels.cjs` was never vendored into agent-infra and is superseded by the swarm Supabase SOR — see #102.)

---

## Section 3 — Complexity Rating (Domain-Aware)

Rate only the domains this issue touches. Overall tier = highest rated domain.

### Available Domains

| Domain | What It Covers | Verification Triggered |
|--------|---------------|----------------------|
| **UX** | UI/component changes | ux-verification, test-e2e |
| **Architecture** | System design, integrations, multi-file | test-integration, test-e2e, architecture review |
| **Ontology** | Data/schema changes | schema-correctness review |
| **Content** | Editorial, deals, guides | content-verification → reviewers |
| **Config** | Infra, CI, env, scripts | config-validation → check scripts |
| **Research** | Investigation, analysis | research-verification → adversarial review |
| **Org Infra** | Skills, pipeline, process, conventions | skill lint, conventions check |

### Rating Per Domain

| Rating | Criteria |
|--------|----------|
| **low** | Trivial change within approved patterns. No new decisions needed. |
| **standard** | Moderate change. Some new decisions, but bounded scope. |
| **complex** | New patterns, cross-system, security surface, or uncharted territory. |

### Overall Tier

- All domains low → **micro**
- Any domain standard, none complex → **standard**
- Any domain complex → **complex**

Apply label: `gh issue edit $N --add-label "complexity:<micro|standard|complex>"`

---

## Section 4 — Relevant Context

Pull context from the parent epic or project. Be thorough — missing context causes downstream rework.

### If Epic-Linked

1. Read the epic plan doc (`docs/epics/.../plan.md`)
2. Extract relevant decisions: approved architecture, data model, UX decisions, migration phase
3. Link the epic: `**Epic:** docs/epics/.../plan.md`
4. Link relevant research: `**Research:** docs/epics/.../research-brief.md` (or "none")
5. Note what this issue inherits vs what's new
6. Pull the epic's test-design surface map (epics run the Test-Design Gate before Plan — issue number recorded in the plan doc). Name the surfaces this issue touches and derive the `### Verification Checklist` section from them. If no test-design exists (grandfathered epic or standalone), write "none — no epic test-design" and skip the surface map derivation.

### If Standalone

- Link any related issues: `**Depends on:** #N` or `**Related:** #N`
- Note affected components: `**Components:** auth, payment`
- No inherited context — all decisions are new

### Inheritance Double-Check (epic/project-linked only)

Before creating the issue, verify nothing was forgotten from the parent. This catches what agents otherwise type by hand and miss:

- [ ] **O/I/T alignment** — does this issue's objective trace to the parent's goal?
- [ ] **Decisions** — any UX, data model, or architecture decisions from the parent that constrain this issue?
- [ ] **Team** — inherited correctly? (check parent's `**Team:**` field)
- [ ] **Dependencies** — any sibling issues this must wait for? (check parent's decomposition section)
- [ ] **Phase** — which migration phase or priority order does this belong to?
- [ ] **Research** — does the parent have a research brief with findings relevant here?
- [ ] **Test-design** — does this issue's verification checklist derive from the epic's integration-surface map, covering every surface this issue touches?

### Research
If this issue needs investigation before implementation, note what to research. For standard+complex issues, this feeds into `issue-scoping` Phase 1.5's `### Axis Research` matrix (external best-practice research per axis). For micro issues, skip.

---

## Section 5 — Create Issue

### Template

```markdown
**O/I/T:**
- Objective: <one sentence — problem or function>
- Indicators: <at least 2 measurable indicators>
- Targets: <bar for each indicator>

**Team:** <slug or "unknown">
**Complexity:** <micro|standard|complex>

**Epic:** <path or "standalone">
**Research:** <path or "none">
**Depends on:** <#N or "none">
**Components:** <list or "none">

### Context
<relevant decisions from parent epic, inherited context, or "Standalone — no inherited context">

### Research Needed
<what to investigate before implementation, or "None — scope is clear">

### Verification Checklist
Derived from the epic's test-design surface map — one row per surface this issue touches:
| Surface | Test Layer | Expected Verification |
|---------|-----------|----------------------|
| <integration surface> | <unit|pgTAP|contract|integration|e2e|ux> | <what must pass> |

(Standalone or grandfathered epic: "none — no epic test-design")

### Complexity (domain-aware)
| Domain | Rating | Rationale |
|--------|--------|-----------|
| <domain> | low/standard/complex | <why> |

### Fractal Fields
- **Level:** <epic | project | task>
- **OIT:** <see above — populated at creation>
- **E2E:** TBD — populated by Scope stage
- **Verification:** TBD — populated by Verify stage
- **Wiring:** TBD — populated by Decompose stage
```

### Apply Labels

```bash
gh issue edit $ISSUE_NUMBER --add-label "complexity:<tier>"
# Team label — resolve team from swarm SOR (see §Section 2), then:
gh issue edit $ISSUE_NUMBER --add-label "team:$TEAM" || true
```

---

## Key Principles

- **This skill creates, not plans.** O/I/T says what and why. Implementation planning (how) happens in `issue-scoping`.
- **Org Infra is a first-class domain.** Skills, pipeline changes, and process work need the same rigor as code.
- **Micro fast-path is for trivial fixes only.** If you're writing more than 3 sentences to explain it, use the full pipeline.
- **Affiliation is mandatory.** An unowned issue is an undone issue. Escalate to human if unresolved or unclear.
- **Context is thorough.** Read the parent epic doc, associated research, context of what happened when the issue was identified, etc. Pull relevant decisions. Don't make the implementer rediscover what was already decided.

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| Creating without O/I/T | Every issue needs an objective. If you can't state it, the issue isn't ready. |
| Rating only 3 axes (old system) | Use the 7-domain system. Org Infra changes are real complexity (Capability domain). |
| Skipping context for epic-linked issues | Read the epic doc. Inherited decisions prevent re-litigation. |
| Using micro fast-path for non-trivial work | Fast-path = obvious fix. If you hesitate, use the full pipeline. |
| Planning implementation during creation | Creation = what & why. Planning = how. Don't mix them. |
