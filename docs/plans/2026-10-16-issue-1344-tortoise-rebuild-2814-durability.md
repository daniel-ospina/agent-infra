---
title: "Plan: agent-infra#1344 — tortoise-rebuild runbook for the #2814 config-durability era"
type: engineering
domain: operations
doc_status: live
created: 2026-10-16
subjects.team: organisation-design-team
ownedBy: organisation-design-team
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, tortoise-2814, skill-tortoise-rebuild, pre-wipe-sidecar, config-reset, durability-posture
---

# Plan — agent-infra#1344 → `skills/tortoise-rebuild/SKILL.md`

> Status: docs-only change. Refs: tortoise#2814 (and its landed descendants
> #3044, #3049, #4641, #4653, #5353, #7952), tortoise#1335 (the sibling
> guard-accuracy fix to this same file).
> Classification: **A** — the stale text makes a *false durability claim*
> ("the event log is the source of truth") on the one path an operator reads
> during a data-loss incident, and describes `rebuild_all` as only lossy when
> it now captures authoritative config and refuses before the wipe. Unlike
> agent-infra#757 (closed NOT_PLANNED as category-B drift), the cost of leaving
> this text is a wrong recovery decision, not friction.

## Confirmed problem

`skills/tortoise-rebuild/SKILL.md` is the operator runbook the tortoise runtime
points operators to (`tortoise/__main__.py` prints
`see operations/skills/tortoise-rebuild/SKILL.md`), and `operations/skills/*`
in tortoise are symlinks into this directory — so the file can only be edited
here, never in tortoise's diff.

It became materially wrong after tortoise#2814 and its descendants, in four
sites that the issue names:

1. **Line 19** claimed the JSONL event log *is the source of truth*. The
   durability authority (`tortoise:docs/durability-posture.md`) says the
   opposite — the journal is a reconstruction source, never the durability
   mechanism — and `tortoise/consistency.py::recover_from_log`'s own docstring
   already links it that way. The line is outside
   `tortoise:tests/test_durability_posture.py`'s scan roots, so nothing on the
   tortoise side can catch it.
2. **Health check** omitted the two reachable "not recovered" outcomes: an
   untrustworthy rescue sidecar, and the sticky `config_reset` marker making a
   data-gone graph report `count(n) > 0` ("graph already has nodes — no
   rebuild"), which suppresses auto-recovery.
3. **Lossy fallback** described `rebuild_all` as an unconditional wipe+replay
   with only the #2944 token guard: no pre-wipe refusals, no rescue sidecar,
   no config capture/restore, no `config_reset` marker, no cross-build version
   ordering.
4. **Quick Decision Tree** had no branch for "not recovered", and no
   pending-vs-retired delete rule.

## Considered alternatives

| # | Approach | Verdict |
|---|---|---|
| A | Correct the four sites and link `tortoise:docs/durability-posture.md` for the class map | **Chosen** — the code is the intended design; the document is the defect |
| B | Enumerate the preserved class list in the runbook | **Rejected** — the authority doc's single-source-of-truth rule forbids a rival enumeration, and `test_config_registry_doc_consistency` pins the doc's list bidirectionally; a copy here would drift silently |
| C | Fix the claim in tortoise by widening `test_durability_posture.py`'s roots to the symlinked skill | **Rejected** — out of this repo's diff, and the gate's roots are the owner's (issue #2881 §6) |
| D | Leave the text and file a code issue | **Rejected** — no code defect exists; only the runbook is stale |

## Change

One file, prose only: `skills/tortoise-rebuild/SKILL.md` (this plan doc is the
scoping record; no other file changes). No test file, so no
CI surface registration applies (agent-infra tracks no `config/ci-surfaces.yml`
or `tools/ci_selection.py` — verified absent).

## Verification

- Every new claim was re-measured against tortoise `origin/main` at
  `bc2ef8c` — not against the issue body, which predates #3044/#4641/#4653/
  #5353/#7952. Primary definitions: `tortoise/projection/__init__.py`
  (`rebuild_all`, `_capture_config_snapshot`, `_config_reset_props`,
  `read_config_reset`/`clear_config_reset`, `_load_prewipe_snapshot`,
  `_validate_prewipe_snapshot`, `_PREWIPE_SNAPSHOT_VERSION` = 6,
  `_PREWIPE_SNAPSHOT_MAX_BYTES` = 64 MiB), `tortoise/consistency.py`
  (`recover_from_log`), `tortoise/__main__.py` (the `Config:` line),
  `tortoise/sdk.py::_clear_config_reset`.
- `node scripts/check-skill-lint.mjs` → `124 SKILL.md files checked. 0 issue(s). Clean.`
- `tortoise:docs/durability-posture.md` Open items still carries the
  `agent-infra #1344` entry; it becomes stale on merge and is recorded on
  tortoise#2814 rather than silently rewritten from here.
