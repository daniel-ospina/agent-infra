# Stage 4 — Design (Fork of shared/plan)

> Forks `shared/plan` — replaces UX/prototype/workflow substeps with experiment-specific design concerns.

## Experiment-Specific Substeps

| # | Substep | Description |
|---|---------|-------------|
| 1 | **Power Analysis** | What sample size to detect expected effect at p<0.05? |
| 2 | **Confound Control** | What variables could produce spurious results? How to mitigate? |
|   | **Identification:** List every variable that differs between arms OTHER than the treatment. Ask: if the experiment shows an effect, what ELSE could explain it? | |
|   | **Mitigation:** For each confound, either (a) hold it constant across arms, (b) randomize it, or (c) measure it and control statistically. | |
| 3 | **Control Conditions** | What baselines? What arms? What's held constant? |
| 4 | **Randomization** | How to avoid order/selection effects? |
| 5 | **Pre-Mortem** | What are 3 most likely failure modes? How to detect them? |
| 6 | **Data Model** | What data is collected? Format? Storage? |
| 7 | **Architecture** | Harness design, agent simulation, graph construction |
| 8 | **Coherence Review** | Cross-substep consistency check |

## Power Analysis Template
```markdown
- Expected effect size: [Cohen's d or percentage difference]
- Significance threshold: p < 0.05
- Desired power: 0.80
- Required N per arm: [calculated]
- Target total runs: [N × arms × variants]
```

## Pre-Mortem Template
```markdown
1. [Failure mode 1]: [What would cause this?] → Detection: [How to catch it?]
2. [Failure mode 2]: [What would cause this?] → Detection: [How to catch it?]
3. [Failure mode 3]: [What would cause this?] → Detection: [How to catch it?]
```

## Skipped from shared/plan
- User Journeys (no users)
- Workflows (trivial)
- Prototype (no GUI)
- Interfaces (inline in harness)
