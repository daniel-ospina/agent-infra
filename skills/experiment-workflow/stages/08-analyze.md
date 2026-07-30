# Stage 8 — Analyze

## Purpose
Run only the pre-registered statistical tests. No post-hoc exploration until pre-registered analysis is complete and reported.

## Pre-Registered Analysis (from Stage 3)

Run the tests specified in the pre-registration. Do NOT add new tests based on what you see in the data.

### Required Outputs
1. **Primary metric result** — with p-value, effect size, confidence interval
2. **Per-hypothesis result** — confirmed or falsified?
3. **Falsification check** — did any hypothesis meet its falsification criterion?
4. **Power check** — was the sample size sufficient to detect the pre-registered minimum effect?

### Post-Hoc Exploration (clearly labeled)
After pre-registered analysis is complete, you MAY run exploratory analysis. This must be:
- Clearly labeled as "EXPLORATORY — NOT PRE-REGISTERED"
- Not used to claim confirmation of hypotheses
- Used only to generate hypotheses for the NEXT experiment

## Statistical Tests Reference

| Data type | Test | When to use |
|-----------|------|------------|
| Binary outcome (correct/incorrect) | χ² or Fisher's exact | Comparing accuracy between arms |
| Continuous outcome (posterior scores) | t-test (2 arms) or ANOVA (3+) | Comparing means |
| Order sensitivity | Cohen's κ or Fleiss' κ | Agreement across order variants |
| Correlation | Pearson r or Spearman ρ | Anchoring effects |
| Variance comparison | F-test or Levene's | Consistency across runs |
| Extraction survival | Binomial test | Fraction of runs showing improvement |

## Output Format
```markdown
## Analysis Report

### Pre-Registered Analysis
**H1: [Name]**
- Metric: [value]
- Test: [name], p = [value], effect size = [value]
- Result: CONFIRMED / FALSIFIED / INCONCLUSIVE

### Falsification Check
- [ ] H0 null hypothesis: [result]
- [ ] Any hypothesis met falsification criterion: [yes/no]

### Power Check
- Target N: [value], Actual N: [value]
- Minimum detectable effect: [value]
- Sufficient power: YES / NO
- **If NO:** Report results as INCONCLUSIVE. Do not claim confirmation or falsification. State required N for future experiment.

### Null Result Handling
A null result (p > 0.05) is NOT a failure. It is data. Report it honestly:
- "The experiment did not find evidence for H1 at p < 0.05"
- NOT: "The experiment failed" or "H1 was disproven" (disproof requires falsification criterion, not null p)

### Exploratory (not pre-registered)
- [Any post-hoc findings, clearly labeled]
```
