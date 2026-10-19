---
title: "Plan: tortoise#2944 — tortoise-rebuild SKILL.md documents the structural wipe guard"
type: engineering
domain: operations
doc_status: live
subjects.team: organisation-design-team
created: 2026-09-29
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, tortoise-2944, tortoise-2996, skill-tortoise-rebuild, confirm-destructive, issue-757
---

# Plan — tortoise#2944 → `skills/tortoise-rebuild/SKILL.md`

> Status: docs-only change. Supersedes agent-infra #757 (closed NOT_PLANNED as
> category-B doc drift; that classification left the skill guiding an operator to
> a call that now refuses).
> Refs: tortoise#2944, tortoise#2996.

## Confirmed problem

`skills/tortoise-rebuild/SKILL.md`'s destructive-wipe bullets still described the
pre-#2944 guard: it told an operator that **embedded mode's wipe runs
unconditionally**. After tortoise #2944 that is false in the direction that
matters during a data-loss incident — it makes an unsupervised wipe sound safe
instead of supervised.

The claim is stale in four separate ways:

1. `FalkorProjection.rebuild_all()` / `rebuild()` are keyword-only
   `confirm_destructive: bool = False` and **refuse by default — embedded
   included**. A direct Python call must pass the token.
2. The `_skip_guard` bypass attribute is removed.
3. The CLI (`python -m tortoise rebuild --dir … --db …`) is the operator
   authorization point — it passes the token.
4. Embedded mode is exempt from the graph-**name** check (L2) only, never from
   the token; server/URI mode is refused on non-`test_*` names **even when the
   token was passed**.

## Considered alternatives (and why the doc moves, not the code)

| # | Approach | Verdict |
|---|---|---|
| A | Update the skill's guard bullets to the shipped behaviour | **Chosen** — the code is the intended design (#2944); only the documentation is stale |
| B | Re-add an embedded-mode exemption to the code so the old text becomes true again | **Rejected** — reverses a deliberate safety decision; the whole point of #2944 is that an embedded wipe is no longer unsupervised |
| C | Delete the lossy-fallback section entirely | **Rejected** — the recovery path is still real and still lossy; removing it hides a footgun rather than labelling it |
| D | Leave the text and file a code issue | **Rejected** — no code defect exists; the doc is the defect |

## Change

One file, prose only: `skills/tortoise-rebuild/SKILL.md` (+13/−6). The
lossy-fallback bullets now state the structural token guard, the embedded
name-check exemption, and the server/URI defence-in-depth refusal.

## Wiring

| Touch point | Type | Covered by | Status |
|---|---|---|---|
| Operator runbook (`skills/tortoise-rebuild/SKILL.md`) | docs | this PR | ✅ |
| `tortoise` CLI `rebuild` subparser tokens | code (other repo) | tortoise#2996 | ✅ (unchanged) |
| `_skip_guard` references | code (removed) | tortoise#2944 | ✅ (no live references; verified) |
| Skill lint (`scripts/check-skill-lint.mjs`) | CI | `ci / skill-lint` | ✅ |

## Verification

- Every claim in the new text verified against the tortoise source at its
  primary definition (see the code-review record on agent-infra#1335).
- `node scripts/check-skill-lint.mjs` → Clean (frontmatter untouched).
- No test file is added: the diff is Markdown-only, so no CI surface is
  registered and no `config/ci-surfaces.yml` entry applies (agent-infra tracks
  no such file).
