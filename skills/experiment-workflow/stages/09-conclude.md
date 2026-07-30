# Stage 9 — Conclude (Fork of shared/verify)

> Forks `shared/verify` — replaces deployment/coherence checks with falsification, limitations, and next-step decisions.

## Falsification Check (replaces deployment verification)

| Pre-registered hypothesis | Falsification criterion | Met? | Conclusion |
|--------------------------|------------------------|------|------------|
| H1: [name] | [criterion] | YES/NO | CONFIRMED / FALSIFIED |
| H0: null | [criterion] | YES/NO | Design valid / Design flaw |

## Limitations (replaces domain verification)

Must be documented BEFORE concluding. Cannot be added retroactively.

| Limitation | Why it matters | Can it be addressed? |
|-----------|---------------|---------------------|
| [Limitation 1] | [Impact on conclusions] | [Yes, by... / No, inherent] |

### Required Limitations Checklist
- [ ] Task difficulty ceiling (was the task too easy/hard to discriminate?)
- [ ] Domain specificity (does this generalize beyond the tested domain?)
- [ ] Model specificity (was only one model tested?)
- [ ] Sample size (was N sufficient for the claimed effect?)
- [ ] Confound residual (did any confounds survive design?)
- [ ] Operator quality (for graph experiments: known vs extracted operators?)

## Next Steps
Based on results:
- **If confirmed:** What follow-up experiment would strengthen the finding?
- **If falsified:** What did we learn? What should the next experiment test instead?
- **If inconclusive:** What would increase statistical power? Is the effect too small to matter, or was the sample insufficient? Consider: is an inconclusive result still useful (e.g., "we proved the effect is smaller than X")?

## Decision
- **Ship:** Finding is robust. Move to production or next phase.
- **Iterate:** Finding is directionally promising but needs stronger evidence. Design E0XX+1.
- **Pivot:** Finding falsified the hypothesis. Change direction.
- **Document:** Finding is inconclusive but informative. Document the ceiling and move on.

## Output
```markdown
## Conclusion

### What Was Proven
- [Hypothesis that survived falsification]

### What Was Disproven
- [Hypothesis that met its falsification criterion]

### Limitations
- [Structured limitations per checklist above]

### Next Experiment
- [What should E0XX test?]
```
