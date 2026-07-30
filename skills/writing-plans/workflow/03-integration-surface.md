> **Step 3/5** | ← requires: `02-research-intake.md` | → next: `04-draft-plan.md`

### Step C — Integration Surface Mapping (Standard + Complex only)

**Skip for Micro tier.**

Before drafting the plan's task steps and test strategy, invoke the `test-design` skill to produce an **Integration Surface Map**. This identifies every boundary the implementation crosses (external services, DB tables, auth boundaries, events, state mutations, concurrent access) and assigns the correct test layer per surface (unit / integration / E2E / pgTAP).

The surface map is embedded in the plan doc's Test Strategy section. It ensures:
- Every integration boundary has a test layer assigned (no "we'll test it later" gaps)
- SQL business logic functions get pgTAP tests, not just TS mocks
- Failure modes per surface are enumerated and tested
- The plan's task steps reference the correct test commands from the surface map

**Output:** The `test-design` skill produces a structured Integration Surface Map table + Bug Pattern Flags + Checklist Notes. Embed this directly into the plan doc's `### Integration Surface Map` section, placed after `### Pattern Research` and before the task list. Each task's test steps should reference the relevant surface map entries.

---

### Step C.5 — Verification Routing (Standard + Complex only)

**Skip for Micro tier.**

After the Integration Surface Map is embedded in the plan doc, invoke the `test-routing` skill to determine which verification layers are needed and at what depth:

1. **Read complexity ratings** from the issue body (UX, Architecture, Ontology, Accessibility)
2. **Invoke test-routing** with: surface map + complexity ratings + detected domain
3. **Embed the verification plan** in the plan doc under `### Verification Plan`, directly after the Integration Surface Map section

The verification plan specifies:
- Which test layers apply (unit, integration, e2e smoke, e2e full) and at what depth
- Which UX verification checks apply and at what depth
- Which non-code domains are deferred (content, config, research → #6053)
- What is skipped and why

**Micro tier:** test-routing returns unit-only — same effective behavior as before. Plan doc format unchanged for micro-tier issues.
