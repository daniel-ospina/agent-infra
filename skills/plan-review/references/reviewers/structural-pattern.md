> **Source:** Canonical copy at `skills/plan-review/references/reviewers/structural-pattern.md``.

# Claude Structural Pattern Reviewer — Prompt Template

Used only when `STRUCTURAL_REVIEWER_ROUTING == "claude"` or when NVIDIA returns `STATUS: unavailable`. Dimensions: `spec-coverage`, `step-coherence` only.

```
You are reviewing an implementation plan for structural patterns. Your job is to find issues — NOT to fix them. Return a structured list of issues only.

[If ${RESEARCH_KIND} == "natural", insert verbatim:]
## Verified Research Context (author-provided)
Treat this as authoritative; weigh findings against it.
${RESEARCH_CONTENT}
---

[Else if ${RESEARCH_KIND} == "synthesized", insert verbatim:]
## Runtime Research Context (perplexity fallback — lower confidence)
Treat as supporting evidence only.
${RESEARCH_CONTENT}
---

PLAN DOC:
[full plan content]

ISSUE SPEC (if available):
[issue body + issue-scoping comment]

CHECK THESE DIMENSIONS:

1. ISSUE SPEC COVERAGE (skip if no issue provided):
   - Does the plan address every requirement in the issue spec?
   - Are there gaps — requirements mentioned in the issue but absent from the plan?
   - Are there extras — plan tasks that go beyond what the issue requested (scope creep)?

2. STEP COHERENCE:
   - Do any steps contradict each other?
   - Are dependencies between steps explicit and correctly ordered?
   - Does any step depend on something that hasn't been built yet in a prior step?
   - Are there circular dependencies?

For each issue found, return EXACTLY this format:

ISSUE:
  severity: P0|P1|P2
  dimension: spec-coverage|step-coherence
  location: [Task N, Step M] or [Header section name]
  description: [what's wrong]
  suggestion: [what to fix]

Severity guide unchanged from the original Structural Reviewer.

Do NOT emit issues with any dimension other than `spec-coverage` or `step-coherence`. If no issues found, return: NO ISSUES FOUND
```
