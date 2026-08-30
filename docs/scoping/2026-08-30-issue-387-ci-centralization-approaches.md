---
title: "#387 — CI Centralization (unit-test capability + enforcement activation) — Solution Approaches"
type: engineering
domain: operations
doc_status: draft
subjects.team: organisation-design-team
created: 2026-08-30
aboutSubjects: node-ci.yml, unit-ci.yml, composite-actions, drift-check, sync-ci-workflows.sh
aboutObjects: agent-infra, tortoise, premise-labs, issue-387
---

# Approaches: #387 — unit-test capability + enforcement activation

> Issue: https://github.com/daniel-ospina/agent-infra/issues/387
> Research: `docs/research/2026-08-30-387-ci-centralization.md`
> Phase: issue-scoping solution divergence. **No winner selected in this document.**

## Confirmed problem (one line)

agent-infra's #303 pin contract is inactive on the exact repos it exists for (tortoise unwired; tortoise + premise-labs stale-exempted → `_checkCI` early-returns before the pin compare ever runs, `bin/agent-infra.js:727-731`), **and** node-ci.yml has no unit-test capability, so tortoise PR #2044 hand-rolled a `dashboard-js-tests` job inline (`tortoise/.github/workflows/ci.yml:99-113`) — the exact drift class the contract is meant to prevent.

## Shared mechanics (every approach must touch these; listed once)

These are release-runbook constants regardless of architecture. Each approach below lists only its **deltas**:

1. **Tag axis:** `manifest.ci.ref` is the release axis. `manifest.version` STAYS 0.1.0 through consumer migration (the `.agent-infra-version` surface is unconditional → bumping `version` makes premise-labs' already-wired drift-check red before consumer pins land).
2. **Fixture co-bump:** any commit that bumps `ci.ref` must co-bump `tests/fixtures/drift/current/.github/workflows/docs-ci.yml` `@v0.1.0 → @v0.1.1` in the SAME commit — `tests/drift/run.sh` #2/#7/#8 compare the fixture against live manifest `ci.ref` (verified: fixture is a real file, not the symlink).
3. **Sync guard:** `_checkCI` gains an assertion `manifest.ci.ref === manifest.check.ci.ref` after `const ci = manifest.ci;` (`bin/agent-infra.js:~748`) — `check.ci.ref` is dead in code today (only `manifest.ci.ref` is read at :755-758).
4. **Doc fix:** `drift-check.yml` header comment (~line 12) per issue runbook.
5. **Exemption lift (step 5, agent-infra-side only):** remove `templates/.github/workflows/` from `manifest.check.exemptions` for tortoise + premise-labs (keep eldato-outreach pending #389). Consumers carry no manifest.json → the lift cannot ride consumer PRs. This is the activation moment in the runbook ordering.
6. **drift-check.yml refs stay @main** — not in `REUSABLE_WORKFLOWS` (`scripts/ci-ref-check.cjs`), exempt from pin compare by design.

---

## Approach A — Extend node-ci.yml with a unit-test job (issue-committed shape)

**Architecture:** one reusable workflow per stack. node-ci.yml gains a 5th job (`unit-test`) alongside script-validate / skill-lint / typecheck / lint, using the D4 python-ci pattern: command-style inputs with `'' = skip` + job-level `if:` guard. Additive inputs with empty defaults → **backward-compatible**: agent-infra's own `ci.yml` self-caller and any existing node-ci caller pass no test inputs → job skipped.

```yaml
# node-ci.yml — new inputs + job (added to templates/, then sync-ci-workflows.sh)
on:
  workflow_call:
    inputs:
      node-version:      { type: string, default: '22' }
      working-directory: { type: string, default: '.' }
      test-glob:         { type: string, default: '' }    # '' + test-command '' = skip
      test-command:      { type: string, default: '' }    # escape hatch (tsx, failure-accumulator, npm ci && vitest)
jobs:
  # ... existing 4 jobs unchanged ...
  unit-test:
    runs-on: ubuntu-latest
    if: inputs.test-command != '' || inputs.test-glob != ''
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: ${{ inputs.node-version }} }
      - name: Unit tests
        working-directory: ${{ inputs.working-directory }}
        run: |
          if [ -n "${{ inputs.test-command }}" ]; then ${{ inputs.test-command }}
          else node --test ${{ inputs.test-glob }}; fi
```

tortoise migration (dashboard job collapses to a call — note it also drags in the 4 stack jobs, see Risks):

```yaml
  dashboard-js-tests:
    uses: daniel-ospina/agent-infra/.github/workflows/node-ci.yml@v0.1.1
    with:
      working-directory: website/apps/dashboard
      test-glob: 'src/*.test.js'   # → node --test src/*.test.js — byte-identical to the hand-rolled run
    secrets: inherit
```

**Files touched (deltas):**
- agent-infra: `templates/.github/workflows/node-ci.yml` + `.github/workflows/node-ci.yml` (materialize via `scripts/sync-ci-workflows.sh` — template-only edit gets reverted by pipeline-compliance `workflow-drift`), `.github/workflows/ci-main.yml` (dogfood), `manifest.json` (ci.ref + check.ci.ref), `tests/fixtures/drift/current/.github/workflows/docs-ci.yml` (co-bump), `bin/agent-infra.js` (sync guard), `.github/workflows/drift-check.yml` (doc fix). Tag **v0.1.1** at the merge commit.
- tortoise: `.github/workflows/ci.yml` — python-ci `@v0.1.0 → @v0.1.1`, add `drift-check` job (`uses: ...drift-check.yml@main` + `secrets: inherit`), replace inline `dashboard-js-tests` body with the node-ci call.
- premise-labs: `.github/workflows/ci.yml` — docs-ci + python-ci `@v0.1.0 → @v0.1.1` (drift-check@main untouched).

**Enforcement-activation choice (lift-last runbook):** tag → consumer bumps (still exempt → vacuous green) → tortoise wires drift-check → step-5 exemption lift = the activation moment (pins == ci.ref → non-vacuous green on first PR after the lift commit). Matches issue O/I/T verbatim (indicator 1 satisfied literally: "in node-ci.yml").

**Dogfooding choice (folded into step 1, same commit):** ci-main.yml's inline `extension-tests` job is replaced by a `unit-tests:` job calling `node-ci.yml@main` with `test-command` = the failure-accumulator + tsx suites. Post-merge only (ci-main is push:main). Two real costs: (a) the call re-runs script-validate + skill-lint + typecheck + lint post-merge, duplicating ci-main's inline copies (or drop the inline copies → lose ci-main's bash-validation + `--skills-dir` coverage); (b) the first real run of the new job is the step-1 **merge commit's** ci-main run, which **races the tag** — v0.1.1 is cut at that commit per the runbook, so a broken unit-test job = broken tag consumers pin before dogfood ever proves green.

**Risks:**
- **Stack-job inheritance (the big one):** tortoise's migration isn't surgical — it becomes a node-ci caller, so script-validate + skill-lint run on every tortoise PR. Verified: tortoise's `scripts/` and `skills/` are **symlinks into agent-infra** (`scripts -> ~/Documents/GitHub/agent-infra/scripts`), so these jobs re-run agent-infra's own gates against agent-infra content on tortoise — coupling tortoise CI to agent-infra script health. skill-lint's fail-closed #254 gate trips on ANY future consumer that calls node-ci without `scripts/check-skill-lint.mjs` (tortoise has it via symlink only). typecheck/lint self-skip (no root tsconfig / eslint config — verified).
- **Tag races dogfood** (above) — needs an explicit verify-before-tag gate in the runbook.
- Fixture co-bump must land in the same commit as the ci.ref bump or the step-1 PR's own drift-check self-test is red.
- Requires no REUSABLE_WORKFLOWS change (node-ci.yml already allowlisted) — cheapest enforcement surface change of the three.

**Tradeoffs:** single pin per stack (least ceremony for consumers); capability inherits stack semantics (right for homogeneous fleet, wrong for surgical migrations); most faithful to the issue as written.

**Best-fit-if:** the fleet is uniformly agent-infra-bootstrapped (symlinked scripts/skills → stack jobs are safe/cheap); one pin per stack is the desired contract; willingness to amend the runbook with a verify-before-tag gate.

---

## Approach B — Sibling unit-ci.yml workflow (workflow-per-capability)

**Architecture:** new standalone reusable workflow `unit-ci.yml` with the same input contract (node-version / working-directory / test-glob / test-command, `'' = skip` + `if:` guard), a sibling of node-ci.yml. Consumers call it as an additional job — tortoise's migration is **surgical** (only the test job runs; no script-validate/skill-lint inheritance):

```yaml
  dashboard-js-tests:
    uses: daniel-ospina/agent-infra/.github/workflows/unit-ci.yml@v0.1.1
    with:
      working-directory: website/apps/dashboard
      test-glob: 'src/*.test.js'
    secrets: inherit
```

**Files touched (deltas):**
- agent-infra: `templates/.github/workflows/unit-ci.yml` (new) + `.github/workflows/unit-ci.yml` (new, materialized); **three hardcoded surfaces extended in lockstep**: `scripts/sync-ci-workflows.sh` (existence guard + copy loop, 3→4 files), `.github/workflows/pipeline-compliance.yml` `workflow-drift` (diff loop, 3→4), `scripts/ci-ref-check.cjs` (`REUSABLE_WORKFLOWS` + `'unit-ci.yml'` — this is what makes the new pin **enforced**); `scripts/ci-ref-check.test.mjs` (allowlist test co-bump); ci-main.yml (dogfood); manifest.json (ci.ref bump + sync guard); fixture co-bump; drift-check.yml doc fix. Tag v0.1.1.
- tortoise: ci.yml — python-ci pin bump + drift-check job + dashboard → unit-ci call (above).
- premise-labs: pin bumps (no new call — no JS tests).

**Enforcement-activation choice:** same lift-last runbook; the pin-compare now has a **second pin axis** (unit-ci.yml) — one more surface per release that can drift stale.

**Dogfooding choice:** folded into step 1, but **cleaner than A** — ci-main's `unit-tests:` job calls `unit-ci.yml@main`, which runs ONLY the test job. No duplicated script-validate/skill-lint post-merge runs. (Same post-merge-only + tag-race limitation as A.)

**Risks:**
- **Three lockstep mechanical edits** (sync script + pipeline-compliance diff + REUSABLE_WORKFLOWS) — miss any one and you get either a silent enforcement hole (workflow exists but not pin-compared) or a sync/pipeline failure. A parametrization refactor (drive the list from one source) fixes this but is scope creep beyond #387.
- **Indicator deviation:** satisfies the OBJECTIVE ("generic test jobs live in reusable workflows with inputs") but not indicator 1's literal "in node-ci.yml" — the issue's scope doc needs amending (O/I/T edit, not just implementation).
- Naming/org drift: python-ci / node-ci / docs-ci / unit-ci mixes stack and capability axes; where does a future `coverage-ci` or `matrix-ci` go?
- Another tag-bump axis for consumers to maintain.

**Tradeoffs:** surgical consumer migration (no stack-job inheritance — matters if any future node-ci caller is NOT agent-infra-bootstrapped, since fail-closed skill-lint would red it); isolated dogfood; but 4th workflow file + 3 extension points + scope-doc amendment.

**Best-fit-if:** fleet heterogeneity is expected (some repos need tests without the node stack's other gates); capability-per-workflow is the intended long-term shape; indicator-1 literal wording is amendable.

---

## Approach C — Composite action + thin per-repo inline job (partial centralization)

**Architecture:** ship `node-unit-tests` as a **composite action** (`uses: daniel-ospina/agent-infra/.github/actions/node-unit-tests@v0.1.1`), not a workflow. Composite actions give **step-level reuse** where reusable workflows give job-level reuse — a consumer can wrap the action with per-repo steps (e.g. `npm ci` between checkout and test, which a workflow_call cannot express without an install-command input). The job shell stays in the consumer:

```yaml
  dashboard-js-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: daniel-ospina/agent-infra/.github/actions/node-unit-tests@v0.1.1
        with:
          node-version: '22'
          working-directory: website/apps/dashboard
          test-command: 'node --test src/*.test.js'
```

**Files touched (deltas):**
- agent-infra: `.github/actions/node-unit-tests/action.yml` (new) + `templates/.github/actions/node-unit-tests/action.yml` (new) + sync extension (`scripts/sync-ci-workflows.sh` copy list or a new `sync-actions.sh`); **`scripts/ci-ref-check.cjs` must gain a `REUSABLE_ACTIONS` allowlist + action branch in `checkCiRefs`** — today `agentInfraUses()` filters by `AGENT_INFRA_WORKFLOW_PREFIX` (`.github/workflows/`), so `.github/actions/` refs are **invisible to the pin compare** (unenforced, zero drift detection); `scripts/ci-ref-check.test.mjs` co-bump; `ci-main.yml` (dogfood wrapper); manifest.json (ci.ref bump); fixture co-bump. Tag v0.1.1. `.github/workflows/pipeline-compliance.yml` needs a new actions-drift check (workflow-drift only diffs the 3 workflow files — actions dir is uncovered).
- tortoise: ci.yml — dashboard job keeps its shell, body collapses to the action call; python-ci pin bump; drift-check wiring.
- premise-labs: pin bumps only.

**Enforcement-activation choice:** same runbook, but the enforcement story is **structurally weaker**: even after the checker learns action refs, the line-regex model cannot verify "this job is nothing but the action wrapper" — a repo can grow bespoke steps around the call and drift-check stays green. The #389 inline-jobs rule becomes **harder** (needs job-body analysis, not uses:-line parsing). The drift class this issue exists for (bespoke inline jobs) **persists**.

**Dogfooding choice:** migrate the ci-main extension-tests BODY into the action; ci-main keeps its inline job shell calling it. Post-merge only (same limitation as A/B).

**Risks:** composite actions don't support `permissions`/`concurrency`/`env` at workflow level (fine for this shape, a ceiling for future needs); a second ref class (actions) to tag-pin and enforce; actions dir uncovered by pipeline-compliance until a new drift check; two centralization mechanisms (workflows + actions) to maintain and document.

**Tradeoffs:** best partial-reuse story (per-repo pre/post steps around shared test logic — directly answers the issue's "eldato uses vitest, needs npm ci" research gap without an install-command input); smallest semantic change to tortoise's existing job (shell stays, body shrinks); but leaves the inline-job drift class open and makes #389 harder.

**Best-fit-if:** the fleet needs install/extra steps between checkout and test (vitest repos); step-level reuse without job-level fan-out is the goal; convention-based enforcement (until #389) is acceptable.

---

## Approach D — Enforcement-first activation (genuinely different sequencing + wiring; composes with A/B/C)

**Architecture:** decouple the two deliverables. The issue's Context laments the contract being "inactive on the exact repos it exists for" — so activate it **first, tag-free**, then ship the capability at leisure:

1. **agent-infra commit (activation, ci.ref UNCHANGED v0.1.0):** lift the tortoise + premise-labs `templates/.github/workflows/` exemptions, add the `ci.ref === check.ci.ref` sync guard, drift-check.yml doc fix. No tag, no fixture co-bump (ci.ref unchanged → tests #2/#7/#8 unaffected). At this commit the #303 pin compare goes **live non-vacuously** on premise-labs' very next PR (its pins @v0.1.0 == ci.ref → green) — the "activation moment" happens here, on a no-op commit, zero consumer coordination.
2. **tortoise PR (wiring):** add the `drift-check` job (no pin bump needed — python-ci@v0.1.0 still == ci.ref; drift-check.yml@main is exempt). Enforcement surface live + proven on both consumer repos BEFORE any capability change.
3. **agent-infra PR (capability):** ship the unit-test capability in the A/B/C architecture of choice + dogfood + bump ci.ref → v0.1.1 + fixture co-bump + **verify-before-tag gate**: cut the tag only after the step-1-merge ci-main run of the new job is green (kills A's tag-race risk).
4. **Consumer PRs:** premise-labs + tortoise pin bumps + tortoise dashboard migration (the lift is already live, so these PRs must land on correct pins — the gate catches mistakes rather than being vacuous).
5. **Verify:** ls-remote shows v0.1.1; both drift-checks green non-vacuously.

**Dogfooding choice (separate + verify-before-tag, with an optional PR-gate variant):** dogfood is its own step, gated before the tag. Variant worth considering: flip agent-infra's **self-caller** from the cross-repo `@main` ref to a **local-path ref** (`uses: ./.github/workflows/node-ci.yml`) — GitHub resolves local-path refs from the caller's checked-out files, so the capability PR's OWN `ci.yml` runs the new job **at PR time** (closing the "post-merge-only dogfood" hole). SelfRepo is exempt from pin compare, so D2's @main contract is untouched for consumers; the flip is self-repo-only.

**Wiring choice (targeted, with universal option):** wire drift-check into tortoise only (premise-labs already wired). Rationale: the pin-compare surface only has teeth where pins exist — eldato/dmer/dmeer are #555 self-contained (zero agent-infra `uses:` refs → pin compare trivially green, symlink sweep green), so universal wiring runs a vacuous-green check on repos with nothing to drift: ceremony without signal. Universal wiring remains available (one drift-check job per repo ci.yml) if fleet-wide contract visibility is the goal; eldato-outreach stays exempt pending #389 either way.

**Risks:** two extra landing cycles before the capability (activation commit + tortoise wiring PR must merge first); activation surfaces **latent** drift on premise-labs/tortoise immediately (their first PR post-lift could fail on a pre-existing stale symlink/pin not visible under the old exemption — actually a feature: clean early attribution, but it can surprise an unrelated PR); the release runbook gains a human gate; intermediate state (contract live, violation class still undetectable — inline jobs await #389) is unchanged from the issue's own plan, so no regression.

**Tradeoffs:** smallest blast radius per change; activation is fixture-neutral + tag-free + consumer-coordination-free; enforcement is proven before the capability exists; but two-phase delivery with more merge ceremony, and the single "activation moment" the issue celebrates at step 5 is split into an earlier silent activation + later capability.

**Best-fit-if:** the priority is actually fixing the "inactive on the exact repos it exists for" failure (the issue's own opening lament) rather than the capability; teams that want each phase independently verifiable; the runbook can absorb an extra cycle.

---

## Comparison matrix

| Dimension | A — extend node-ci | B — sibling unit-ci.yml | C — composite action | D — enforcement-first |
|---|---|---|---|---|
| Capability location | node-ci.yml job | new unit-ci.yml workflow | shared action, job in consumer | (wraps A/B/C) |
| tortoise migration surface | full stack inherited | surgical (test job only) | job shell + action call | depends on wrapped arch |
| New enforcement surfaces | none (already allowlisted) | 3 lockstep edits + new pin axis | REUSABLE_ACTIONS + action pin axis + actions-drift check | none at activation (ci.ref unchanged) |
| Inline-job drift class closed? | yes (migration = uses:) | yes | **no — job shell persists** | via wrapped arch |
| Dogfood | same-commit, post-merge, duplicates stack jobs, races tag | same-commit, isolated, still races tag | same-commit, post-merge | separate step + verify-before-tag (+ optional local-path PR-gate variant) |
| Indicator-1 literal compliance | yes | **no (scope amendment)** | no (it's an action, not a job in node-ci) | via wrapped arch |
| Fixture co-bump needed | yes (with ci.ref bump) | yes | yes | **no at activation** (yes at capability step) |
| Consumer ceremony | 1 pin per stack | 1 more pin per release | 1 action pin per release | same as wrapped arch |
| Best-fit | homogeneous bootstrapped fleet, literal issue compliance | heterogeneous fleet, capability-per-workflow long-term | install-steps/partial-reuse needs, accept weaker enforcement | activation risk is the priority; phased delivery OK |

## Considered, not developed

- **Single combined ci.yml caller** (merge python-ci + node-ci + docs-ci into one mega-workflow, consumer calls once with per-stack skip inputs): fewer pins, one caller line — but breaks all wired consumers (premise-labs' two calls → input remap), contradicts the D4 per-stack precedent, and is a fleet-wide restructure to deliver ONE job. Defensible only as a post-#389 v2 consolidation, not as the #387 vehicle.
- **`install-command` 5th input on A/B:** python-ci's `install-extras` precedent exists; the test-command escape hatch already covers `npm ci && vitest run` for eldato-class repos. Add only if a real consumer demands it.
- **Parametrize the sync/pipeline/allowlist lists** (single source of truth instead of 3 hardcoded 3-entry lists): fixes B's lockstep risk but is its own refactor — note as follow-on, not part of #387.
- **Wiring drift-check into ALL consumers:** analyzed in D — vacuous-green ceremony on #555 self-contained repos; targeted (tortoise) is the right-sized surface.

**No winner selected.** This document diverges solutions for the scoping gate; convergence happens after review.
