# Stage 6 — Validate (1-Run Gate)

> ⛔ **HARD GATE:** Run exactly 1 trial. If the design is broken, STOP. Fix before scaling.

## Purpose
Catch design flaws before investing in 20+ runs. E013 would have been caught here — the graph wasn't differentiating and we would have stopped at 1 run instead of discovering it after building the full harness.

## Validation Checklist

Run exactly 1 trial. Then verify:

### 1. Data Production
- [ ] Did the experiment produce data? (no crashes, timeouts, empty outputs)
- [ ] Are all arms producing results? (no arm with 0 data points)
- [ ] Are agents/models responding? (no API errors, no blank responses)

### 2. Metric Integrity
- [ ] Do the pre-registered metrics produce values? (no NaN, no constants)
- [ ] Is there any variation in the data? (not all identical values)
- [ ] For graph experiments: are posteriors differentiated? (range > 0.05, not all 0.500)

### 3. Confound Check
- [ ] Are there obvious confounds not anticipated in design?
- [ ] Is the control arm producing expected baseline behavior?
- [ ] Is there any evidence the treatment is measuring something other than intended?

### 4. Broken-Design Thresholds (specific values that indicate failure)
- [ ] Graph experiments: posterior range < 0.05 or all posteriors = 0.500 → graph not differentiating
- [ ] Agent experiments: all agents produce identical output → no variation to measure
- [ ] Classification experiments: accuracy = random baseline (±5%) → model not engaging with task
- [ ] Extraction experiments: 0 operators across all runs → extraction pipeline broken

### 5. Gate Decision

**PASS** → All checks pass. Proceed to Scale.

**FAIL** → Any check fails.
- Document the failure
- Diagnose root cause
- Fix the design
- Re-run Validate (max 3 attempts)
- On 3rd failure: escalate to human

## Output
```markdown
## Validation Report
**Result:** PASS / FAIL
**Issues found:** [list]
**Fixes applied:** [list]
**Decision:** PROCEED to Scale / STOP and fix
```
