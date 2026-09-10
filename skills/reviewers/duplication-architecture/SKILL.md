---
disable-model-invocation: true
name: duplication-architecture
description: Checks whether a proposed change duplicates something that already exists, and whether the overall architecture is still sound once it lands. Every near-duplicate finding carries a three-valued verdict — unify | keep separate | unify-contract-keep-drivers. Dispatched at the scope and plan review gates for both epics and issues.
domain: capability
subjects.team: organisation-design-team
type: Bounded
status: live
allowed-tools: read bash grep find web_search web_fetch todo_write task
summary: "Reviewer — duplication-with-existing + whole-system architectural soundness, at scope and plan gates (epics and issues)."
created: 2026-09-10
updated: 2026-09-10
---

> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

# Reviewer — Duplication & Architecture

> **Skill type:** Modular — independently invocable, reusable across Workflows.
> **Continuity:** none — fresh session per invocation, no state carried between calls.
> **Boundary:** Checks duplication-with-existing and whole-system soundness. For alignment with a *parent epic* or documented decisions see `reviewers/architectural-soundness`; for integration surfaces and consumers see `reviewers/integration`; for interface contracts see `reviewers/contract-completeness`.

Answers two questions that nothing else in the pipeline asks:

1. **Are we duplicating something that already exists?** — and if so, should it be unified, or kept separate *on purpose*?
2. **Is the overall architecture sound — including this component in context?** Not "is this component well built". Whether the *system* is still coherent once this lands.

Both questions are asked at the **scope** gate (before design commits) and again at the **plan** gate (once design is concrete), because the answer can differ: scope sees intent, plan sees structure.

## When Used

| Workflow | Scope gate | Plan gate |
|---|---|---|
| **Epic** | `epic-scope` review gate | `epic-plan` substep 5 (Architecture) + step 8 (Coherence Review) |
| **Issue** | `issue-scoping` Phase 5.5 (solution-verify) | `plan-review` (Reviewer #5, conditional) |

Also valid on its own: any time a change proposes a **new** component, module, skill, script, reviewer, extension, service, table, or write path.

**Proportionality — read this, it is a trap if misread.** This reviewer is a no-op **only** when the change neither writes shared state nor modifies anything that does. It is **in scope** — and must run — when the change:

- adds or modifies any component, module, skill, script, service, table, or write path
- **extends a field list, a schema, a vocabulary, a status enum, or a validation rule** ← this is the shape most silent divergences take
- **changes any writer of state another component also writes**
- touches anything carrying a claimed invariant ("single source of truth", "can never drift", "the canonical X")

> ⚠️ **An earlier version of this skill said "if the change adds no new component … this reviewer is a no-op." That escape hatch was shaped exactly like the defect it was meant to catch:** appending a field to an existing writer adds no new component, and it is how three successive divergences were introduced. If you are reaching for the no-op clause, first answer: *does this change write state, extend a declaration, or touch a writer?* If yes, it is not a no-op — say so. `NO ISSUES FOUND — no-op` is only valid when you can state which of the four bullets above are all false.

## Inputs Required

- **The proposal** — scope doc, plan doc, epic section, or plan-review plan doc
- **What already exists** — see Sources below. This is the input that makes the check real; without it you can only report that no search was done
- **System context** — architecture docs, ontology, existing component boundaries, and anything describing who owns which state

## Sources — read this before checking

You must search before asserting novelty. Three sources, in order:

1. **The repo itself** — `grep`/`find` for components serving the same function; read adjacent modules; check manifests and indexes. **Always available. Always do this.**
2. **Tortoise** (`tortoise_search`, `tortoise_query`, `tortoise_entity_profile`) — the intended long-term registry of components (`objectKind: skill|tool|agent|workflow`). **One source among several — not the only one, and not a required one.**
3. **Any other index the repo exposes** — manifests, component catalogs, generated indexes.

**Mandatory rules:**

- **Cite which source produced each finding.** A duplication claim with no source is not a finding.
- **A contract that covers a different axis is not a record.** If a live, indexed contract exists but its scope excludes the axis under review, it does not constitute recorded separation — and its presence is a **false negative generator**. See D5.
- **If Tortoise is unreachable or returns nothing, say so explicitly and continue with the other sources.** Do not treat an unavailable or empty source as evidence of absence.
- **Never report a stale source as a clean result.** "No duplicates found" from a registry that has not been refreshed is not a finding — it is a false negative wearing a clean bill of health. If you cannot establish a source's freshness, label the conclusion **low confidence** and say which source was unverifiable.
- **Never block on a source.** Unavailable sources degrade the *confidence* of this review, never its completion.
- **Do not let the tracker do the discovery for you.** The acceptance test that validated this skill was run *with the issue tracker pointing at the right files*. At a real plan gate there is no tracker and no suspicion. If your findings depend on already knowing where the duplication is, you have verified the tracker, not the change.

## Checks to Run

### Duplication

**D1 — P0 — Reimplementation of something that already exists:**
The change builds something whose function is already served by an existing mechanism, and does not acknowledge it. Flag with the existing mechanism's name and path.

> **Mechanism, not just component.** The purest instance of this check is a *general* mechanism reimplemented *inside a file* for one layer while a generic version sits nearby. Do not limit this to "a new component"; look for a function reimplementing its neighbour. Grep for parity/consistency/drift claims in the area and read the functions they name.

**D2 — P1 — Near-duplicate (same function, different implementation):**
Same job, drifted vocabulary or structure. Not an exact copy — that is what makes it dangerous: it will not appear in a clone detector, and the two will diverge silently. **Requires a verdict** (see below).

> ⚠️ **D2 is the hazard this reviewer most often fails to find, because discovery is normally name-keyed.** Write paths that do the same job routinely share **no vocabulary** — a commit endpoint, an extraction path, a projection upsert, a lifecycle stamp, and a demo seeder will all write the same node properties under unrelated names. A search for the new component's name finds siblings that *share its name*, not these.
>
> **Mandatory procedure — search by function, not by name.** For the state or job this change touches:
> 1. Identify **what it writes** and **what it does** — the state, table, resource, file, or contract — independent of any identifier.
> 2. Grep for that state and that verb, **not** for the new component's name.
> 3. **Separate writers from drivers.** A *driver* accepts input and delegates to a writer; a *writer* emits the persistence statement. Drivers legitimately differ in input shape. Count writers. Confusing the two is the most common way to undercount — it produces a tidy list of entry points that misses every writer behind them.
> 4. **Read the whole family for the odd member.** When several components implement the same job, read all of them and look for the one that does it differently — a generic helper called by five siblings and reimplemented closed by the sixth, or a hardcoded list beside a derived one. The asymmetric member is the defect.
> 5. Compare declarations pairwise: field lists, schemas, enums, validation rules, status sets. Divergence lives in the *declarations* and is invisible in the call sites.
> 6. **Check reader gates too, not just writers.** A *reader* that queries on a subset of a vocabulary can silently mis-classify records that every writer produced correctly. Grep the values, not only the writers.
>
> If you cannot state how many writers of this state exist, you have not completed this check — report that as the finding.

**D3 — P1 — Multiple writers of the same state:**
More than one component writes the same data, state, resource, or contract without a shared declaration.

> ⚠️ **This check was previously worded "two components", and that binarization is why it failed its first acceptance test: the real case had five entry points — and twenty writers behind them.** Do not stop at the first second writer you find. **Enumerate the complete set.**
>
> **Completeness is auditable, not assertable.** A number you state is not evidence. Report the **search predicate** you used and the **exclusions** you applied:
> ```
> search:   <the greps/queries run, e.g. 'MATCH|MERGE|SET .*:Point' across tortoise/ tools/ scripts/>
> excluded: <paths/dirs deliberately out of scope, and why — e.g. .worktrees/ (stale copies)>
> asserted: <any pre-existing claim about how many writers exist — and its actual scope>
> ```
> A reviewer who cannot show the predicate has produced a guess with a number attached. Reusable lesson from the acceptance test: the tracker's own framing ("the five doors") **was the exclusion set that hid fifteen more writers** — never adopt the proposal's framing of its own scope.
>
> This is the highest-value check in this reviewer — it is the failure that produces silent field loss, writer divergence, and "we have N components doing the same thing and now we must refactor".

**Required for D3** (add to the output block):
```
writers: [<component> <path:line>, ...]     # ALL of them, not two
shared_contract: <path to the declaration they must share, or NONE — and if NONE, that is the fix>
```
Naming the missing contract is the point of this check. A D3 finding with no `shared_contract` line is incomplete.

**D4 — P1 — Duplicated definition / vocabulary:**
The same concept defined in more than one place, with the definitions free to disagree. Applies to kinds, vocabularies, constants, schemas, status enums, and validation rules.

> **Required per duplicated vocabulary — a consistency assertion.** Eyeballing pairs stops working past a handful, and the dangerous cases are the sets that are *almost* identical. For each duplicated vocabulary, state whether **a test asserts the sets agree**. If none does, **that absence is the finding** — not the divergence you happened to spot.
> ```
> vocabulary: <concept>
> definitions: [<path:line>, ...]   # all of them
> consistency_assertion: <test path | NONE — and if NONE, that is the P1>
> divergences_found: [<which pair differs, and how>]
> ```
> Two divergence shapes to check specifically, both found in the acceptance test:
> - **A value excluded by readers but rejected by writers** — several sets excluding a status the writer refuses to accept, i.e. dead branches guarding states that cannot exist.
> - **A reader set missing one member the writer set has** — silently mis-classifying correctly-written records. This is the higher-severity shape: every writer is correct, and the bug is in the reader.

**D5 — P2 — Unrecorded separation:**
A near-duplicate that legitimately coexists but with **no stated reason** anywhere. The components are fine; the *silence* is the defect. Any future agent will read the pair as an accident, and one of the two will eventually be "cleaned up" or forked further. **Requires a verdict.**

> ⚠️ **Beware the partially-scoped contract — a false negative this check produces.** A live, indexed contract that maintains an explicit divergence register will *look* like recorded separation. In the acceptance test, `docs/INGEST_CONTRACT.md` was live, indexed in `docs/00_index.md`, and carried a "Known non-gated surfaces" register — for the **promotion** axis only. The field-persistence divergence was not on it, and D5 would not have fired. **A contract that covers a different axis does not record this separation.** Read what the register actually covers, not that it exists.

**D6 — P1 — Recurrence after a fix that claimed completeness:**
This defect class has been reported and "fixed" in this area before, and the prior fix's scope was read as complete when it was not.

> **Why this check exists:** the acceptance test's decisive finding. The same divergence class was fixed in this codebase **three times** — and each fix extended a hardcoded list, which is the cause rather than the cure. A prior fix's *claim* of completeness ("single source of truth for X parity — a rebuilt graph can never drift from the applied graph") is exactly what stopped anyone defending the next writer.
>
> **Procedure:** grep the issue tracker and git log for prior fixes touching this state or these declarations. For each, read whether the fix generalised or patched one instance. If a prior fix claimed universality, verify the claim — and if it is false, that false claim is the finding.

**D7 — P1 — Divergence is silent (fail-open):**
Two writers can disagree **without any error, log, or failing test** surfacing it. The harm is not that the writers differ — it is that they differ *inaudibly*.

> **Do not assess this by reading and concluding "it looks silent." Invert the burden — name the mechanism:**
> ```
> divergence_signals:
>   exception: <path:line that raises on an unknown/inconsistent field, or ABSENT>
>   log:       <path:line that warns, or ABSENT>
>   test:      <test that fails on divergence, or ABSENT>
> ```
> If any of the three is `ABSENT`, the divergence is silent and this check fires. Note the trap the acceptance test exposed: **a test named for parity can be structurally blind to its subject** — check that the test's fixtures actually contain the disputed fields. A parity test whose fixtures omit exactly the fields that diverge is a fourth kind of absence, and the most deceptive.
>
> A `unify` verdict that consolidates the declarations today without supplying at least one of the three signals leaves the defect class intact: the next new field is dropped the same silent way. When you return `unify` under D3/D7, name which of {shared declaration, parity test, fail-closed rejection} the fix provides. Unifying the values without one of the three is not a fix — and on re-review, a `unify` verdict with no named mechanism is an open finding, not a closed one.

**D8 — P2 — Measurement path does not exercise the production path:**
A test, benchmark, or harness that measures a different lane than the one users hit, so its green result is not evidence about the real path.

**D9 — P2 — Retrospective audit missing:**
Divergence that has already run implies state that is **already corrupted**. Every check above is forward-looking. If the finding is that two writers have disagreed, require the audit: *which existing data is already wrong, and who fixes it?* A forward-only fix leaves the damage in place.

> **This check needs an obligation, not just a mention — otherwise it is the easiest finding to write and the least likely to cause anything.** Emit it as an explicit action line so it can be tracked:
> ```
> retrofit_audit_required: <what data is already wrong> → <filed as issue? or named owner>
> ```
> If you cannot identify who owns the audit, say so — an unowned corruption audit is itself the finding. Do not downgrade this to a note on D3.

### Architecture

**A1 — P0 — Unsound in context:**
The system is no longer coherent with this component added. Second source of truth; two owners for one resource; a guarantee that only holds if exactly one writer exists.

**A2 — P0 — Boundary or layer bypass:**
The component sits in the wrong layer, reaches across a boundary, or establishes a shortcut that later changes will copy.

**A3 — P1 — Unaccounted ripple:**
Existing components must change for this to work, and the proposal does not say which or how. Flag them.

**A4 — P1 — Component reviewed in isolation:**
The proposal justifies the component on its own terms without describing the system it joins — no statement of what this replaces, what it sits beside, or what it changes globally. The *absence of the system view* is the finding.

**A5 — P2 — Local fix, global cost:**
Solves a local problem by adding system-wide complexity (a new global concept, an extra hop, a new invariant everything must respect).

**A6 — P1 — Claimed invariant is false, partial, or unaudited:**
The area carries an in-code or in-doc guarantee — "single source of truth", "the canonical X", "can never drift", "always preserved" — and it is **not true as stated**.

> **Why this check exists:** a false invariant claim is not documentation drift; it is an active defence-suppressant. In the acceptance test, a docstring asserting parity "so a rebuilt graph can never drift" was scoped to 2 of 5 writers. Anyone who read it concluded the concern was handled, which is why nobody guarded the remaining three. **Every false invariant claim is a P1 regardless of whether it has caused damage yet.**
>
> **Procedure:** grep for the invariant vocabulary (`single source of truth`, `canonical`, `never`, `always`, `guaranteed`, `parity`) in the area and in any doc covering it. For each hit, ask: *is this true universally, or only for the surface it was written against?* State the actual scope.

### Required output for every D2 and D5 finding

A warning is not enough. State a verdict:

```
verdict: unify | keep separate | unify-contract-keep-drivers
reason: <why — and if "keep separate", what makes the two legitimately distinct>
```

> ⚠️ **The binary form was insufficient and is now three-valued.** A binary `unify | keep separate` **cannot express the answer that is usually correct**: *unify the contract, keep the drivers separate*. Two write paths may legitimately take different inputs (one takes caller kwargs, one reads a replay log) while **sharing one field declaration**. Under the old binary, a reviewer could flag all five writers, return two defensible `keep separate` verdicts, and ship the divergence with a clean report. `unify-contract-keep-drivers` exists so that answer is expressible — and it must name the shared declaration.

A **`keep separate`** verdict is a valid, useful outcome — it is the "explicit and intentional" half of this reviewer's purpose. Do not treat it as a non-finding. But `keep separate` on the *contract* is only valid when the drivers genuinely differ in input shape **and** the declaration is still shared; otherwise it is `unify-contract-keep-drivers`.

## Output Format

```
ISSUE #N
Dimension: Duplication | Architecture
Severity: P0 | P1 | P2
Location: [plan/scope section, or component path]
Problem: [what is duplicated or unsound]
Evidence: [source — file path, component name, or `tortoise_search` query. Required.]
Fix: [unify / keep separate / change the design — and if keep separate, state the reason]
Verdict: unify | keep separate | unify-contract-keep-drivers   # required for D2 and D5
Writers: [ALL writers of the state, path:line]                  # required for D3
Shared contract: [path to the declaration they must share, or NONE]  # required for D3
```

End with:

```
DUPLICATION & ARCHITECTURE REVIEW SUMMARY
Sources consulted: [repo search ✓/✗, Tortoise ✓/✗/unavailable, other]
Source freshness: [verified | unverifiable — low confidence]
Duplication findings: [count]  (P0: n, P1: n, P2: n)
Architecture findings: [count]  (P0: n, P1: n, P2: n)
Verdicts: unify: n | keep separate: n | unify-contract-keep-drivers: n
Writers of shared state: [total enumerated — if 0, state which paths you searched]
False invariant claims: [count]
Silent-divergence risk: [yes/no]
Proportionality: [substantive review | no-op — and name which of the four scope bullets are false]
```

If no issues found, return: NO ISSUES FOUND

**If you could not consult any source beyond the repo itself**, append:
```
⚠️ LIMITED SOURCES — registry unavailable; duplication coverage is repo-search only.
```

**If you located a contract but it covers a different axis than the one under review**, append:
```
⚠️ PARTIAL CONTRACT — <path> covers <axis it covers>; it does NOT record the <axis under
review> separation. Do not read its existence as recorded separation.
```

## What Fails If You Skip

| Skip | Consequence |
|------|-------------|
| Duplication check | A second component appears beside the first. They drift. Months later both must be reconciled, and the reconciliation touches every caller |
| Second-writer check (D3) | Silent data loss and writer divergence — each writer maintains its own field list, and nothing errors when they disagree |
| Verdict on near-duplicates | The pair is detected and then nothing happens. Either the duplication survives, or someone "cleans it up" without knowing it was deliberate |
| Architecture check | Locally sensible components accumulate into an incoherent system; boundaries erode one shortcut at a time |
| Source citation | A duplication claim nobody can verify is indistinguishable from a guess, and gets ignored |

---
> Continue following the workflow as mandated by this skill. Do not skip steps.
