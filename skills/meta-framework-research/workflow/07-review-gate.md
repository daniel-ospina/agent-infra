# Phase 7: Review Gate

Dispatch fresh-context reviewer to check the meta-framework output. Fix-loop until clean or convergence.

> **Finding contract — `consequence:` required** (canonical: `proportional-gates` §Findings Must Declare
> Consequence). Every finding from the reviewer this phase dispatches must declare
> `consequence: <what breaks, who observes it>`. Without an adequate one the finding is **advisory:
> non-blocking, not counted toward this gate, and not filed as an issue** (it is still recorded in the
> cycle log). A cycle with ≥1 finding and none adequate is malformed reviewer output, not clean: record
> `⚠️ reviewer returned N consequence-less findings`, re-dispatch once, and exit non-clean. **Where this gate's bound is already spent, record the marker and exit non-clean without the extra dispatch** — the floor never widens a bound. "Clean" is
> this gate's own full clean token, never a count. The reviewer's output block therefore carries the
> `consequence:` field alongside its other fields.

## Steps

### 7.1 Check for Fast Execution Intent
If `execution_intent=fast`: run checklist-only review (skip sub-agent dispatch).

Checklist:
- [ ] All 10 sections present
- [ ] No placeholder text
- [ ] Confidence tags on claims
- [ ] File at correct path

If all pass → done. If any fail → fix, re-check. No sub-agent dispatch.

### 7.2 Prepare Review Prompt
Construct reviewer prompt with the meta-framework output:

```
You are a meta-framework reviewer. Review this output for:

1. COMPLETENESS: Are all 11 sections populated? Any placeholder text? Is section 11 (Recontextualization) present and applied to the top 5-10 frameworks?
2. COHERENCE: Do sections contradict each other? Does the ontology tree match the framework catalog?
3. CONFIDENCE: Is every claim tagged? Are low-confidence claims flagged?
4. GAPS: Did the gap analysis catch real gaps? Are there obvious missing perspectives?
5. ACCURACY: Are factual claims supported by the lens research? Any hallucinations?
6. BOUNDARY: Are boundary conditions falsifiable? For each framework in the catalog, can you identify a scenario where it would be the WRONG choice? Are Context-Fit Matrices present per sub-domain with ≥2 frameworks?
7. CATALOG INTEGRITY: Are there any entries in the Framework Catalog that appear to be agent-synthesized concepts rather than published frameworks? Does every catalog entry have a verifiable source?

META-FRAMEWORK OUTPUT:
[full content of meta-framework.md]

Return ISSUE blocks — each carrying `consequence: <what breaks, who observes it>` — with specific fixes, or "NO ISSUES FOUND".
```

### 7.3 Dispatch Reviewer
Dispatch fresh-context sub-agent via `task`:
```
task(prompt='<review prompt from 7.2>')
```

### 7.4 Process Results
- **NO ISSUES FOUND:** Review complete. Proceed to 7.6.
- **ISSUES found:** Proceed to 7.5.

### 7.5 Fix Loop

**Cycle N:**
1. Read reviewer issues
2. Apply fixes to `meta-framework.md`
3. Write review cycle report to `research/07-review-cycle-N.md`:
   ```markdown
   # Review Cycle N
   **Issues found:** <count>
   **Issues fixed:** <count>
   **Remaining:** <count>
   ```
4. Increment N. If N > 3 → stall (see below)
5. Re-dispatch reviewer with updated output
6. Repeat until NO ISSUES FOUND or stall

**Stall conditions:**
- N > 3 (max cycles reached) → document unresolved issues, proceed to 7.6
- Recurring unresolved issues (≥80% identical across 2 cycles) → document, proceed. **This is this gate's own rule, not the 3-layer stuckness detector** — do not reuse the detector's `fingerprint-stall` name or its escalate-to-human outcome for this continue-and-proceed path.

### 7.6 Completion
Review gate complete. Meta-framework document is ready.

**If stalled:** append to output:
```markdown
---
⚠️ REVIEW STALLED after <N> cycles. <M> issues remain unresolved.
```
