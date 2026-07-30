# Stage 3 — Hypothesize (Pre-Registration Gate)

> ⛔ **HARD GATE:** Pre-registration must be committed to the repo BEFORE Stage 6 (Validate). No pre-registration = no experiment.

## Purpose
State hypotheses, falsification criteria, and metrics BEFORE collecting any data. This prevents HARKing (hypothesizing after results are known), p-hacking, and metric shopping.

## Pre-Registration Template

```markdown
## Pre-Registered Hypotheses

### H1: [Name]
**Hypothesis:** [What do you predict?]
**Falsification:** [What result would DISPROVE this? Be specific.]
**Metric:** [How will you measure it?]
**Statistical test:** [What test? At what threshold?]
**Minimum effect size:** [What difference is meaningful?]

### H0: Null hypothesis (negative control)
**Hypothesis:** [When should the experiment show NO difference?]
**Falsification:** [What result would suggest a design flaw?]

## Pre-Registered Analysis Plan
- Primary metric: [name]
- Statistical test: [name, threshold]
- Sample size target: [N per arm]
- Stopping rule: [when to stop scaling]
- Confound checks: [what variables will you verify?]

## Pre-Registration Hash
[git commit hash of this document]
```

## Gate Check
Before Stage 6 (Validate), verify:
- [ ] Pre-registration committed to repo (`experiments/E0XX-preregistration.md`)
- [ ] Every hypothesis has a falsification criterion
- [ ] Primary metric is specified
- [ ] Statistical test is named
- [ ] Sample size target is set

**If any unchecked → STOP. Do not pass go.**

## Pre-Registration Commit
Commit the filled template to `experiments/E0XX-preregistration.md` BEFORE the Validate stage. The commit hash is the pre-registration hash. This proves the hypotheses existed before data collection.
