---
name: writing-skills
description: How to create, structure, and maintain agent skills following project conventions. Reference skill — not a workflow. Covers frontmatter schema, mandatory blocks, naming rules, structure patterns, and pi compliance.
domain: capability
type: reference
status: live
tags: [skill-authoring, conventions, reference]
created: 2026-07-07
updated: 2026-07-07
---

> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

# Writing Skills

Reference for creating skills that follow project conventions. All 99 project skills follow these rules — this document encodes them as process.

> **Ontology:** `docs/teams/organisation-design-team/data/ONTOLOGY.md` — canonical entity classes, work vocabulary, domain taxonomy.

## Frontmatter Schema

Every SKILL.md starts with YAML frontmatter. Required and optional fields:

```yaml
---
name: my-skill              # Required. Must match [a-z0-9-]+ (no underscores, no slashes).
description: "..."          # Required. Pi shows this in available_skills. Quote if it contains colons.
domain: capability          # Required. Canonical domains: capability, engineering, operations, planning.
subjects.team: ""           # REQUIRED — from issue `**Team:**` → AGENT_SESSION_TEAM → fallback organisation-design-team
subjects.role: ""           # Optional — from AGENT_SESSION_ROLE, omit if unavailable
type: Bounded               # Optional. Bounded (single-file), Workflow (index+workflow/), reference.
                            #   type: reference — exempt from steps: declaration.
                            #   Reference skills document conventions, not execution workflows.
steps:                      # Optional. List of workflow steps (YAML DAG). Omit for single-step skills.
  - name: preflight         #   Auto-default: single-step skills get implicit Step(name="execute").
    type: skill             #   See skill_declaration.py for full Step schema.
    skill: my-skill.preflight
status: live                # Optional. live, draft, deprecated.
allowed-tools: ...          # Required for Bounded/Workflow. Tools the skill needs.
tags: [pipeline, ...]       # Optional. For search/discovery.
summary: "..."              # Optional. One-line description for indexes.
created: 2026-07-07         # Optional.
updated: 2026-07-07         # Optional.
---
```

**Naming rules:**
- Only lowercase letters, numbers, and hyphens (`[a-z0-9-]+`)
- No underscores (`_`), no slashes (`/`), no uppercase
- Pi derives names from file paths — if your path is `reviewers/my-skill/SKILL.md`, use `name: my-skill` (not `name: reviewers/my-skill`)
- Multi-word skills use hyphens: `ux-design-review`, `shared-verify`

## Mandatory Blocks

Every SKILL.md MUST include two blocks — no exceptions. Validate with:

```bash
grep -c 'MUST be read in full' SKILL.md  # must be >= 1
grep -c 'Continue following the workflow' SKILL.md  # must be >= 1
```

### Gate Warning (after frontmatter, before content)

```markdown
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.
```

### Continuity Directive (at bottom)

```markdown
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
```

## Structure Patterns

### Bounded Skill (single file)
One SKILL.md, no subdirectory. Self-contained. Used for pipeline stages and focused tasks.
- Example: `shared-verify` at `../planning/shared/verify/SKILL.md`
- When to use: the skill does one thing, no multi-step workflow


### When to Choose Each Type

| Type | Use When | Don't Use When |
|------|----------|---------------|
| **Bounded** | Single-file skill, under ~200 lines. Self-contained process with no sub-steps needing independent navigation. | Multi-step pipeline where each step needs its own review gates, commit points, or independent execution. |
| **Workflow** | Multi-step pipeline, over ~200 lines total. Each step benefits from independent navigation headers, review gates, and the `workflow/` sub-file pattern. | Single atomic action with no internal steps. |
| **reference** | Conventions, patterns, or documentation consumed by other skills. No execution process. | Anything with an execution process — use Bounded or Workflow. |

**Split threshold:** When a Bounded skill exceeds ~200 lines, refactor to Workflow with `workflow/` sub-files. Each sub-file gets navigation headers (`> **Step X/N** | ...`). The SKILL.md becomes the index with "What you are missing" checklist and "What fails if you skip" table.

### Workflow Skill (index + workflow/)
A SKILL.md index that describes the pipeline, plus `workflow/*.md` files with step-by-step instructions.
- Example: `commit-workflow` at `../commit-workflow/SKILL.md` + 5 workflow files
- When to use: the skill has multiple sequential steps, each with its own gates

### Reference Skill (this one)
Single SKILL.md, no workflow. Documents conventions or patterns consumed by other skills.
- Example: `parallel-orchestrator`, `question-format`, `human-input-framework`

## Creation vs Extension

**Create a new skill when:**
- The topic is a distinct domain (new pipeline stage, new capability)
- No existing skill covers this workflow
- The skill will be invoked independently by agents

**Extend an existing skill when:**
- Adding a variant or edge case to an existing workflow
- The change is proportional (e.g., adding depth rules to a shared skill)
- A reference document is growing — add sections, not new files

**Anti-pattern:** Creating a new skill for every micro task. Skills are capabilities, not task lists.

## Pi Compliance

### Discovery
Pi loads skills from paths in `~/.pi/agent/settings.json` under `skills: [...]`. The canonical path is `$AGENT_INFRA_PATH/skills`. Pi scans this directory recursively for `SKILL.md` files.

### Naming Collisions
If two sources have a skill with the same name, the project version wins. Pi logs a warning. To check for collisions: `rg '^name:' skills/*/SKILL.md | sort | uniq -d`

### Available Tools
The `allowed-tools` field maps to Pi tool names: `read write edit bash grep find web_search web_fetch todo_write task`. Do NOT use Claude-specific names like `WebSearch`, `WebFetch`, `Skill`.

## Quick Checklist

Before committing a new skill, verify:

- [ ] Name matches `[a-z0-9-]+` (no `_`, no `/`, no uppercase)
- [ ] Description is quoted if it contains `:`
- [ ] Gate warning present after frontmatter
- [ ] Continuity directive at bottom
- [ ] `allowed-tools` uses Pi tool names
- [ ] `domain` is a canonical domain
- [ ] Structure matches the skill type (Bounded/Workflow/reference)
- [ ] No duplicate name with existing skills
- [ ] References `skill-sync` for version control after creation
- [ ] ONTOLOGY reference present (if applicable)

## Integration

After creating or editing a skill:
1. Run `skill-sync` to commit and push the repo copy
2. If the change is non-trivial (new skill, restructure), route through `issue-workflow` — do NOT direct-commit

---
> Continue following the workflow as mandated by this skill. Do not skip steps.
