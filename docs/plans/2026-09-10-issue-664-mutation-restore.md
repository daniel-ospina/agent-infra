---
title: "#664 — safe mutation-testing restore protocol for review-fix loops — Scope & Plan"
type: engineering
domain: operations
doc_status: draft
subjects.team: organisation-design-team
created: 2026-09-10
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-664
---

<!-- research-path: none — root cause pinned by two live in-session incidents during #637/#640 and by a repo-wide sweep of the five review-fix skills (see "Confirmed Problem"); no external research warranted (internal contract-doc change). -->

# #664 — safe mutation-testing restore protocol — Scope & Plan

## Confirmed Problem

The review-fix loops (`code-review`, `issue-scoping`, `plan-review`, `test-review`,
`prototype-review`) routinely include a **deliberate RED mutation** step: an agent
breaks a guard (a lint rule, a CI trigger, a tripwire assertion) to prove the guard
actually fires, then restores it. The skills prescribe the mutation and the re-run,
but **never define the restore**. Agents fill the gap with the most obvious git
command:

```sh
# negative-test a guard, then "restore"
perl -pi -e 's/.../.../' .github/workflows/node-ci.yml
node scripts/check-skill-lint.test.mjs            # confirm RED
git checkout -- .github/workflows/node-ci.yml    # silent: discards ALL uncommitted edits to that file
```

`git checkout -- <path>` / `git restore <path>` restore the file to its **index/HEAD**
state, not to "the state before my mutation". Inside a fix round the file under test
usually carries *uncommitted* work, so the restore deletes exactly the work the
mutation was verifying.

**Two live occurrences during the #637/#640 session** (issue body): the `ci.yml`
`concurrency` group, and the `frontmatter-validate.mjs` 121→122 relabel. Both had to
be re-applied and were nearly lost. **The failure is silent** — the suite still passes
afterwards because it is testing the reverted file against the reverted expectations,
so nothing announces the loss.

This is the same hazard class as the `main-worktree-guard` destructive-op gates
(#615/#625/#654/#658/#663), but its origin is the **skills' prescribed practice**, not
a command an agent improvised mid-task. Fixing only agent behavior leaves the next
session with the same gap.

### Repo sweep (evidence, 2026-09-10)

| Surface | Current state | Action |
|---|---|---|
| `AGENTS.md` + `templates/AGENTS.base.md` | no protocol, no discard phrasing | **add** the protocol (§Editing Rules) |
| `skills/code-review/SKILL.md` | fix loop (`Gate Loop — MANDATORY`) with no restore rule | **point** at the protocol |
| `skills/issue-scoping/SKILL.md` | `Phase 7 — Parallel Review Gates` fix loop, no restore rule | **point** at the protocol |
| `skills/plan-review/SKILL.md` | `Phase 3 — Fix` + `Phase 4 — Gate Loop`, no restore rule | **point** at the protocol |
| `skills/test-review/SKILL.md` | `Phase 3 — Fix` + `Phase 4 — Gate Loop`, no restore rule | **point** at the protocol |
| `skills/prototype-review/SKILL.md` | React `Phase 2 — Fix` + HTML fix step, no restore rule | **point** at the protocol |
| `skills/**` + `AGENTS.md` | **zero** `git checkout -- <path>` / `git restore <path>` occurrences today (so the gap is unguarded, not currently violated) | **guard** with a new check |

The gap is therefore not "a skill says the wrong thing" — it is "**no skill says
anything**, and the destructive command is the path of least resistance." The fix has
to be (1) a citable rule, (2) a pointer where the mutation happens, and (3) a
mechanical check so the rule cannot silently rot back out.

## Plan

### 1. Define the protocol once — `AGENTS.md` §Editing Rules (+ base template)

A new subsection, `### Mutation-Testing Restore Protocol (#664)`, added to
`templates/AGENTS.base.md` (the canonical base — every consumer repo inherits it via
`scripts/materialize-agents.sh --merge`) and mirrored byte-for-byte into this repo's
`AGENTS.md` (dogfood copy). Placed in **§Editing Rules**, deliberately **not** in
§Review Loop Protocol (a parallel PR owns that section).

The rule states:

- **Forbidden:** a working-tree discard of the file under test as the restore
  mechanism (`git checkout -- <path>`, `git restore <path>`, `git checkout .`).
- **In-place edit → file backup:** `cp <file> /tmp/<name>.bak` before mutating,
  `cp /tmp/<name>.bak <file>` to restore, then confirm (`shasum`).
- **Whole-tree probe → isolated copy:**
  `TMP=$(mktemp -d); git archive HEAD | tar -x -C "$TMP"` — the suite runs in the
  copy, never in the working tree.
- **Prefer a harness** that restores from a backup over ad-hoc `perl -pi` + copy-back.
- **Why it matters:** the failure is silent — the suite still passes after a wrong
  restore, so nothing announces the lost work.
- The one allowed use of the forbidden spelling is *naming the hazard* (this rule
  itself), marked with an explicit `<!-- mutation-restore-ok: <reason> -->` pragma.

### 2. Point the five review-fix skills at it

Minimal, surgical: a short note in each skill's fix/gate-loop section (where the
mutation actually happens), stating the cp-backup rule and forbidding the
working-tree discard, with a citation to the AGENTS.md protocol. No restructuring.
`skills/code-review/SKILL.md` additionally carries the **worked example** end to
end (backup → mutate → confirm RED → `cp` back → confirm with `shasum`), satisfying
the issue's indicator (3).

### 3. Mechanical check — `scripts/check-skill-mutation-restore.mjs`

Scans agent-facing instruction surfaces — `AGENTS.md`, `templates/AGENTS.base.md`,
`skills/**/*.md` — and fails on a **working-tree discard in a restore context**:

- **Command matcher:** `git checkout -- <pathspec>`, `git checkout .`,
  `git restore …`. Branch ops (`git checkout main`, `-b`, `--orphan`) do not match.
- **Restore context:** the occurrence's enclosing fenced code block / paragraph /
  ±3-line window must contain a mutation marker (`mutation`, `mutate`,
  `negative test`, `planted`, uppercase `RED`), or the occurrence line itself must.
  **The word alone is not a violation** — this is what keeps
  `using-git-worktrees`-style operational prose and the protocol's own hazard
  description from false-REDding.
- **Escape hatch:** an explicit `<!-- mutation-restore-ok: <reason> -->` pragma on the
  line, or the line directly above. A non-empty reason is required (an empty pragma
  is still RED). This is the auditable exception for “naming the forbidden form”.
- **Exit 1** with GitHub annotation lines (`::error file=…,line=…::…`) on any
  violation; **exit 0** with a one-line summary otherwise.

Fixture suite `scripts/check-skill-mutation-restore.test.mjs` supplies the
non-vacuity proof: planted violations for each discard form (in `AGENTS.md`,
`templates/AGENTS.base.md`, `skills/**`) are RED; a `cp`-based restore, a
non-mutation `git restore`, branch ops, out-of-scope `docs/`, and a properly
pragmad hazard description are GREEN; the **live tree is asserted GREEN**.

> **Filename note (issue open decision 2):** the issue suggested
> `scripts/check-skill-mutation-restore.sh`. Chosen `.mjs` instead — the matcher
> needs fenced-block/paragraph context, the repo's nearest precedent for this check
> class is `scripts/check-skill-lint.mjs` + `.test.mjs`, and `ci-main.yml`'s
> `script-validate` already `node --check`s `scripts/*.mjs` and runs `.test.mjs`
> suites. Same check, better-supported harness; recorded rather than silently
> substituted.

### 4. CI wiring — `ci-main.yml` `script-validate` (post-merge)

```yaml
# script-validate bash accumulator step
node scripts/check-skill-mutation-restore.mjs || errors=$((errors+1))
# extension-tests test-command accumulator
node scripts/check-skill-mutation-restore.test.mjs || failures=$((failures+1))
```

`ci-main.yml` is **not** template-diffed — `pipeline-compliance.yml`'s
`workflow-drift` job diff-checks only `python-ci.yml`, `node-ci.yml`, `docs-ci.yml`
against `templates/.github/workflows/`. So no template workflow edit is required.
`templates/AGENTS.base.md` **is** the template counterpart of `AGENTS.md` and is
edited in lockstep (step 1).

> **Per-PR wiring is deliberately not added here.** `ci.yml`'s `test-command` is
> pinned to *exactly* `node scripts/check-skill-lint.test.mjs` by guard (j) in
> `check-skill-lint.test.mjs` (#637), and adding a per-PR job is separate scope. The
> post-merge leg is the instructed wiring; the per-PR promotion is recorded as an
> out-of-scope follow-up candidate, not absorbed.

## Testing strategy

| Layer | Surface | Command / expectation |
|---|---|---|
| Unit (negative) | new checker fixtures | `node scripts/check-skill-mutation-restore.test.mjs` → planted violations **RED**, clean variants **GREEN**, live tree **GREEN** |
| Unit | agent-facing surfaces | `node scripts/check-skill-mutation-restore.mjs` → exit 0 on the branch tree |
| Unit | frontmatter validator + #637 guards | `node scripts/check-skill-lint.test.mjs` → **163/163** (must not regress) |
| Oracle | validator ↔ real pi loader | `node scripts/check-skill-lint.oracle.test.mjs` → **146/146**, fuzz 0/1000 |
| Workflow | YAML + ref validity | `bash scripts/check-workflow-actionlint.sh`; `node scripts/ci-ref-check.test.mjs` |
| Manual | real mutation + restore under the protocol | mutate a tracked file with uncommitted work present, confirm RED, `cp` back, `shasum` matches the pre-mutation hash → work survives |

## Verification plan

1. Run the Testing-strategy table; capture pass counts.
2. **Non-vacuity (RED):** plant each violation class (mutation context + `git checkout --`,
   `git restore`, `git checkout .`, in `AGENTS.md` / `templates/AGENTS.base.md` /
   `skills/**`) and confirm exit 1 with the right `file:line`. Fixture cases encode
   this permanently; one live-tree planting is done manually as a spot-check.
3. **GREEN:** unplant, confirm the live tree exits 0.
4. **Behavioural proof (#664 checklist row 3):** with uncommitted work present,
   perform a real mutation → `cp` restore → `shasum` equality; work survives.
5. Post-merge: `ci-main` green on `main`.

## Acceptance criteria

- [ ] `AGENTS.md` + `templates/AGENTS.base.md` carry the protocol (§Editing Rules).
- [ ] All five review-fix skills cite the protocol at their fix/gate-loop step.
- [ ] One worked example shows the isolated-copy/backup recipe end to end.
- [ ] `scripts/check-skill-mutation-restore.mjs` fails on a planted violation and
      passes on the branch tree.
- [ ] Wired into `ci-main.yml` `script-validate` + `extension-tests` test-command.
- [ ] `check-skill-lint` 163/163, oracle 146/146, actionlint, ci-ref-check all green.

## Wiring Check

| Touch Point | Type | Covered By | Status |
|---|---|---|---|
| `AGENTS.md` protocol | docs | new check (scans `AGENTS.md`) | ✅ |
| `templates/AGENTS.base.md` protocol | docs | new check (scans the base template) | ✅ |
| Five review-fix skills | docs | new check (scans `skills/**/*.md`); manual citation review | ✅ |
| Discard matcher coverage | test | fixture cases per command form + scope | ✅ |
| Restore-context matcher (false-positive bound) | test | non-mutation `git restore` + branch-op + out-of-scope fixtures | ✅ |
| Pragma escape hatch | test | pragma-with-reason GREEN / empty-reason RED fixtures | ✅ |
| Post-merge wiring | workflow | `ci-main.yml` `script-validate` + `test-command`; actionlint | ✅ |
| Per-PR wiring | workflow | **not added** — `ci.yml` `test-command` is pinned by #637 guard (j); out of scope | ⚠️ follow-up candidate |
| Consumer repos | docs | `materialize-agents.sh --merge` propagates the new base section | ✅ (mechanism exists) |

## Rejected alternatives

| Alternative | Why not chosen |
|---|---|
| Ban the word/command repo-wide in agent-facing docs | False-REDs legitimate operational prose (`using-git-worktrees` M4 notes) and the protocol's own hazard description; the issue explicitly asks for restore-context matching. |
| Only a fixture-based check, no live-tree enforcement | Fixtures prove the matcher; the live scan is what stops the rule rotting. Both shipped. |
| Only prose (no check) | The rule would decay the same way the restore step did — the issue's indicator (2) requires a mechanical assertion. |
| Isolated-copy *only* (drop the backup form) | A tree probe tests committed-at-HEAD content; an in-place edit needs the backup form to preserve uncommitted work. The issue's open decision 1 is resolved as "backup for in-place edits, isolated copy for whole-tree probes" — both documented. |
| Edit §Review Loop Protocol | Parallel PR owns that section; conflict. §Editing Rules is the instructed alternative home. |
| Add the new section to `materialize-agents.sh --check`'s marker list | Would make the authoring-time gate fail-closed on every consumer that has not refreshed its AGENTS.md — an unrelated, breaking coupling for a docs-only addition. Not done; recorded. |

## Complexity

| Domain | Rating |
|---|---|
| Content/Ops (skills, AGENTS.md) | standard |
| Scripting (new check + suite + CI wiring) | standard |

Overall: **standard** (matches the issue label). The change touches agent behavioural
contracts + adds one deterministic script check; no new pattern, no security surface.

## Review Cycle Log

| Gate | Cycle | Result |
|---|---|---|
| issue-scoping ceremony (problem-verify / solution-verify / Phase 7 / second-model) | — | **PENDING** — owned by the controller (the review-fix loops run on `main`; this branch cannot dispatch fresh-context verifiers for a decision already frozen). `pipeline-compliance` check (b) is expected RED until the controller posts the scoping marker. |
| code-review | — | **PENDING** — controller/`commit-workflow` gate. |
| plan-review | — | **PENDING** — controller gate. |
| test-review | — | **PENDING** — controller gate. |

## Out of Scope / Accepted Residual Gaps

- **Per-PR wiring of the new check** — candidate follow-up (see Wiring Check).
- **`materialize-agents.sh --check` marker-list addition** — rejected above.
- **Retroactive rewrite of `docs/plans/*` restore phrasing** — those are archival
  records, not agent-facing instructions; the check does not scan `docs/`.
- **`main-worktree-guard` interaction** — different surface (#615/#625/#654/#658/#663);
  the guard blocks the discard in a main checkout, but review work happens in
  worktrees, which is exactly where the hazard bit.
- **The pragma can be added to silence a real violation** — same accepted bound as
  every in-repo text guard: the pragma is a visible, reviewable diff line with a
  required reason, and blocking the deliberate class is governance (branch
  protection, cf. #646), not a text check.
