---
name: experiment-workflow
description: Scientific method for product experiments. 9-stage pipeline with pre-registration, validation gate, and falsification check. Reuses shared/align, research, scope, decompose. Forks shared/plan and shared/verify for experiment-specific needs.
domain: capability
type: Workflow
status: live
tags: [pipeline, experiment, scientific-method, pre-registration]
---

> ⛔ **This skill MUST be read in full — not skimmed.**

# Experiment Workflow

9-stage pipeline for product experiments. Enforces scientific method: pre-registration before data collection, validation before scaling, falsification criteria before analysis.

## Pipeline

```
EXPERIMENT ISSUE (Level: experiment)
      │
      ▼
1. ALIGN ──────── shared/align (reused) — go/no-go
      │
      ▼
2. RESEARCH ───── shared/research (reused) — background + baselines
      │
      ▼
3. HYPOTHESIZE ── NEW — pre-registration gate ⛔
      │
      ▼
4. DESIGN ─────── FORK of shared/plan — power analysis, confounds, pre-mortem
      │
      ▼
5. SCOPE ──────── shared/scope (reused) — boundaries + E2E
      │
      ▼
6. VALIDATE ───── NEW — 1-run gate ⛔ STOP if broken
      │
      ▼
7. SCALE ──────── shared/decompose (reused) — incremental runs
      │
      ▼
8. ANALYZE ────── NEW — statistical tests
      │
      ▼
9. CONCLUDE ───── FORK of shared/verify — falsification check + limitations

Reused: 4 skills. Forked: 2 skills. New: 3 skills.
```

## Hard Gates

| Gate | Stage | Prevents |
|------|-------|----------|
| **Pre-registration** | 3. Hypothesize | HARKing, p-hacking, metric shopping |
| **Validation** | 6. Validate | Scaling broken designs (E013) |
| **Falsification check** | 9. Conclude | Confirmation bias, ignoring nulls |

## Anti-Patterns (from 14 Tortoise experiments)

| Anti-pattern | Example | Prevention |
|-------------|---------|------------|
| Inline test called "experiment" | E009 | Stage 4: formal design required |
| Calculation called "experiment" | E010 | Stage 1: classify correctly |
| Scaling broken design | E013 | Stage 6: validation gate |
| Self-referential data | E006 | Stage 4: independence requirement |
| Metric changed mid-experiment | E008 (38%→51-57%) | Stage 3: pre-registered metrics |
| No falsification criteria | Most experiments | Stage 3: mandatory |
| Limitations after analysis | E001-E014 (retroactive) | Stage 9: from design |

## Integration

- `issue-creation` — `Level: experiment` fractal field
- `issue-workflow` — routes Level=experiment → experiment-workflow
- `commit-workflow` — commits pre-registration before Validate

## References

- Design: `tortoise/docs/experiment-workflow-design.md`
- Epic: `tortoise/docs/experiment-workflow-epic.md`
