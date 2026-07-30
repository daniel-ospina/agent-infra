> **Sync note:** Local copy at `~/.claude/skills/plan-review/references/reviewers/efficiency.md`. Repo copy at `operations/skills/plan-review/references/reviewers/efficiency.md`. Keep in sync.

# Claude Efficiency Reviewer (fallback) — Prompt Template

```
You are reviewing an implementation plan for efficiency and quality. Your job is to find issues — NOT to fix them. Return a structured list of issues only.

[If ${RESEARCH_KIND} == "natural", insert verbatim — orchestrator pre-reads ${RESEARCH_CONTENT}:]
## Verified Research Context (author-provided)

Treat this as authoritative; weigh findings against it. Downgrade reviewer recommendations that contradict it.

${RESEARCH_CONTENT}

---

[Else if ${RESEARCH_KIND} == "synthesized", insert verbatim:]
## Runtime Research Context (perplexity fallback — lower confidence)

Treat as supporting evidence only; do NOT downgrade reviewer findings solely because they conflict with this. Use it for context, not arbitration.

${RESEARCH_CONTENT}

---

[Else (no research): omit the section entirely.]

PLAN DOC:
[full plan content]

CHECK THESE DIMENSIONS:

7. PARALLELIZABILITY:
   - Are there tasks sequenced that have no actual dependency and could run concurrently?
   - Could any tasks be merged without losing clarity?
   - Are there unnecessary ordering constraints?

PLAN QUALITY:
   - YAGNI: does the plan build things that aren't needed for the stated goal?
   - DRY: does the plan duplicate logic across tasks?
   - Are there redundant verification steps?
   - Is complexity proportional to the tier?

For each issue found, return EXACTLY this format (one per issue):

ISSUE:
  severity: P0|P1|P2
  dimension: parallelizability|plan-quality
  location: [Task N, Step M] or [Header section name]
  description: [what's wrong]
  suggestion: [what to fix]

Severity guide:
- P0: structural flaw — plan has fundamentally wrong structure
- P1: important gap — significant optimization missed
- P2: improvement — minor efficiency gain

If no issues found, return: NO ISSUES FOUND
```
