---
title: "#387 — CI Centralization (unit-test capability + enforcement activation) — Scoping Plan"
type: engineering
domain: operations
doc_status: draft
subjects.team: organisation-design-team
created: 2026-08-30
aboutSubjects: node-ci.yml, drift-check, manifest.json, sync-ci-workflows.sh
aboutObjects: agent-infra, tortoise, premise-labs, issue-387
---

# #387 Implementation Plan — CI centralization: unit-test capability + #303 enforcement activation

> Source: issue-scoping (v5.1 double diamond + verify gates, cycles 1-5) — 2026-08-30
> Issue: https://github.com/daniel-ospina/agent-infra/issues/387 | Research: docs/research/2026-08-30-387-ci-centralization.md | Diverge: docs/scoping/2026-08-30-issue-387-ci-centralization-approaches.md

**Team:** organisation-design-team
**Architecture:** Approach A (diverge doc) — extend node-ci.yml with a 5th `unit-test` job + D4 `'' = skip` input guards + backward-compatible boolean skip inputs `script-validate`/`skill-lint` (**`default: true` explicit — GitHub boolean workflow_call inputs default to `false` when unset; omitting the default would silently disable the #254 fail-closed gate for every existing caller including agent-infra's self-caller**) + dogfood ci-main.yml + fixture co-bump + `_checkCI` sync guard + drift-check.yml:12 doc fix + verified lift-last runbook with an additive verify-before-tag gate. Rejected: B (sibling unit-ci.yml — 3 lockstep edits + scope amendment for no outcome gain), C (composite action — pin-compare blind + drift class persists), D lift-first (invalidates verified sequencing; its real fix is the additive gate).

## Problem statement

agent-infra's #303 pin contract is inactive on the exact repos it exists for: tortoise never wired drift-check, and tortoise + premise-labs sit under `manifest.check.exemptions["templates/.github/workflows/"]` so `_checkCI` (bin/agent-infra.js:727-731) early-returns before the pin compare ever runs. Meanwhile node-ci.yml has no unit-test capability, so tortoise PR #2044 hand-rolled a bespoke inline `dashboard-js-tests` job (origin/main ci.yml:99-113). Indicator 3 (inline-job detection) is deferred to #389; this issue delivers the capability + activates pins+symlinks enforcement.

## Proposed solution (file-by-file)

### agent-infra PR #1 — capability + dogfood + manifest bump + guards (one commit set)

**`templates/.github/workflows/node-ci.yml`** (source of truth; materialize via `scripts/sync-ci-workflows.sh` — do not hand-edit the copy; pipeline-compliance workflow-drift diff-enforces template==materialized):

```yaml
on:
  workflow_call:
    inputs:
      node-version:
        type: string
        default: '22'
      working-directory:
        type: string
        default: '.'
      test-glob:
        type: string
        default: ''          # '' + test-command '' = job skipped
      test-command:
        type: string
        default: ''          # escape hatch: 'npm ci && vitest run' | tsx | failure accumulator.
                            # Overrides test-glob when both set. MUST NOT contain '${{'.
      script-validate:
        type: boolean
        default: true        # backward-compat: existing callers keep the gate. Consumers with a
                             # broken-on-runner scripts/ symlink MUST pass false (tortoise).
                             # Skip observable via the callee run log (job-level if: skip lists the job as skipped).
      skill-lint:
        type: boolean
        default: true        # #254 fail-closed. Consumers without scripts/check-skill-lint.mjs
                             # (un-bootstrapped) MUST pass false. default:true is load-bearing —
                             # boolean workflow_call inputs default to FALSE when unset.
                             # Skip observable via the callee run log (job-level if: skip lists the job as skipped).
jobs:
  script-validate:
    if: inputs.script-validate        # guard added; body unchanged
  skill-lint:
    if: inputs.skill-lint             # guard added; #254 fail-closed LOGIC unchanged,
                                      # message text EXTENDED (see below): distinguish "repo not
                                      # agent-infra-bootstrapped → pass skill-lint: false"
                                      # from "bootstrapped repo missing its gate → real failure".
  typecheck:                          # unchanged (self-skips w/o tsconfig.json)
  lint:                               # unchanged (self-skips w/o eslint config)
  unit-test:                          # NEW 5th job — job-level if: skip + step-level if: branch selection (no shell interpolation)
    runs-on: ubuntu-latest
    if: inputs.test-command != '' || inputs.test-glob != ''
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: ${{ inputs.node-version }}   # block style — flow mapping with ${{ is a YAML parse error
      - name: Custom test command
        if: inputs.test-command != ''
        working-directory: ${{ inputs.working-directory }}
        run: ${{ inputs.test-command }}
      - name: Glob-based node --test
        if: inputs.test-command == '' && inputs.test-glob != ''
        working-directory: ${{ inputs.working-directory }}
        run: node --test ${{ inputs.test-glob }}
```

Header comment: document the new inputs, the skip contract, the skip-input asymmetry boundary (script-validate/skill-lint have skip inputs; typecheck/lint self-skip via missing config, no force-skip — test-only consumers with configs use test-command), and the `${{`-free requirement.

**`.github/workflows/node-ci.yml`** — run `bash scripts/sync-ci-workflows.sh` (3-file loop already covers node-ci; no script edit).

**`.github/workflows/ci-main.yml`** — dogfood: replace the inline `extension-tests` job BODY with a node-ci call, **KEEPING THE JOB NAME `extension-tests`** (co-update rule: `auto-file-on-failure` has `needs: [extension-tests, script-validate, skill-lint, cost-config-guard]` at :116; renaming invalidates the whole workflow at parse — the exact #339 class auto-file exists to backstop):

```yaml
  extension-tests:
    # #387 — dogfood the reusable capability (was: inline failure accumulator).
    # Stack gates skipped: ci-main keeps richer inline copies (bash -n + installer
    # tests #304, --skills-dir skill-lint) whose coverage node-ci jobs lack — keep
    # them; accept the duplicate post-merge minutes.
    uses: daniel-ospina/agent-infra/.github/workflows/node-ci.yml@main
    with:
      node-version: '22'
      script-validate: false
      skill-lint: false
      test-command: |
        failures=0
        echo "== scripts/ci-ref-check.test.mjs =="
        node scripts/ci-ref-check.test.mjs || failures=$((failures+1))
        echo "== scripts/check-skill-lint.test.mjs =="
        node scripts/check-skill-lint.test.mjs || failures=$((failures+1))
        for t in extensions/*/test*.mjs; do
          [ -f "$t" ] || continue
          echo "== $t =="; node "$t" || failures=$((failures+1))
        done
        echo "== extensions/shared/print-mode.test.ts =="
        npx tsx extensions/shared/print-mode.test.ts || failures=$((failures+1))
        echo "== extensions/shared/print-mode-wiring.test.ts =="
        npx tsx extensions/shared/print-mode-wiring.test.ts || failures=$((failures+1))
        echo "== extensions/auto-sync.test.ts =="
        npx tsx extensions/auto-sync.test.ts || failures=$((failures+1))
        echo "== extensions/sequence-enforcer/sequence-enforcer.test.ts =="
        npx tsx extensions/sequence-enforcer/sequence-enforcer.test.ts || failures=$((failures+1))
        if [ $failures -gt 0 ]; then echo "❌ $failures extension test file(s) failed"; exit 1; fi
        echo "✅ All extension tests passed"
    secrets: inherit
```

(The `run: ${{ inputs.test-command }}` step gets the raw multiline string as the run body — byte-identical to today's inline execution. The accumulator contains NO `${{` — verified; `$((failures+1))` is bash arithmetic.)

**`manifest.json`** — same commit: `ci.ref` v0.1.0 → v0.1.1 AND `check.ci.ref` v0.1.0 → v0.1.1 (co-bump — the new sync guard asserts equality); `ci.sha` informational (nothing reads it): set to the STEP-1 MERGE commit sha (the commit v0.1.1 pins) — precedent: v0.1.0's ci.sha is the commit carrying the pinned workflows, not the tag commit. **`version` STAYS 0.1.0** (the `.agent-infra-version` surface is unconditional — bumping would red premise-labs' already-wired drift-check before its pins land).

**`tests/fixtures/drift/current/.github/workflows/docs-ci.yml:11`** — `@v0.1.0` → `@v0.1.1` in the SAME commit (run.sh cases 2/7/8 compare fixture pin vs live manifest ci.ref; without the co-bump the step-1 PR's own drift-check self-test reds). Real committed file, not a symlink. Also fix the stale run.sh:15-18 header ("relative symlink" → real committed file).

**`bin/agent-infra.js`** — sync guard after `const ci = manifest.ci;` (~:748), fail-closed with message (null-safe when manifest.check/check.ci absent — a bare deref would TypeError exit-1 with no message and break case-9's grep):

```js
// #387 sync guard — check.ci.ref is a declared mirror of ci.ref (read nowhere
// in code); keep the two halves on ONE axis so a bump cannot drift them apart.
const checkCi = manifest.check && manifest.check.ci;
if (ci && ci.ref && checkCi && checkCi.ref && checkCi.ref !== ci.ref) {
  issues.push({ type: 'ci-ref', entry: 'manifest.json', tier: 'fail',
    reason: `manifest.check.ci.ref (${checkCi.ref}) ≠ manifest.ci.ref (${ci.ref}) — keep both in sync (#387)` });
  console.log(`   ❌ manifest.json — check.ci.ref ${checkCi.ref} ≠ ci.ref ${ci.ref} (#387 sync guard)`);
}
```

**`tests/drift/run.sh`** — new case 9 (LAST, after case 8): NEGATIVE-path assertion that the guard FIRES. Tamper `manifest.check.ci.ref` → `v9.9.9` via **`node -e` JSON round-trip targeting `manifest.check.ci.ref` explicitly** (NOT sed — `manifest.json` has two identical `"ref": "v0.1.0"` strings; sed-first-occurrence tampers `ci.ref` (wrong scenario), sed-global tampers both (guard never fires)). Run `--ci` on the fixture (repo `current`, never exempted → guard fires), assert exit 1 + guard message. **Restore via cp-back in the EXISTING single `cleanup()` trap — do NOT add a second `trap ... EXIT` (bash semantics: a second trap REPLACES the first, silently dropping the fixture restore).** Extend the uncommitted-changes preflight to include `manifest.json`. Add "9. check.ci.ref ≠ ci.ref sync guard → FAIL, exit 1" to the top-of-file case enumeration (lines 6-13).

**`.github/workflows/drift-check.yml:12`** — doc fix: `manifest.check.ci.ref` → `manifest.ci.ref` (#303 contract; check.ci.ref kept in sync by the _checkCI guard).

### test-glob branch proof (P2)
The dogfood passes only `test-command`; the `test-glob` branch (which tortoise's migration depends on) is NOT exercised before the tag. Accepted: the glob branch is first proven by tortoise's step-4 migration PR running the job via the tag (still exempt → a broken glob branch is a red PR, not an outage; worst case a v0.1.2 re-bump). The gate's claim is scoped accordingly: verify-before-tag proves the `test-command` path only.

### DevOpsNess reconciliation (P2)
Research (DevOpsNess 2026-07) recommends pre-merge central self-test of reusable workflows and warns the tag-per-change ceremony "reintroduces the 60-PR problem" and pushes agents toward inline jobs (the disease this issue fixes). Reconciliation: (a) the tag-per-change ceremony is #303-bound (consumers must pin semver tags; consumer @main is drift) — amending the contract is out of scope, noted as a #389 follow-on (moving-major-tag policy or a bump fast-path script for additive changes); (b) PR-time dogfood via the local-path self-caller flip is out of scope per the verified amendment — the mechanical verify-before-tag gate (below) is the accepted substitute; (c) the recurring-ceremony cost (every future ci.ref bump, incl. #389) is accepted at n=2 consumers and MUST be estimated before #389.

### agent-infra step 2 — tag (verify-before-tag gate)
Merge PR #1 → **WAIT** for the merge commit's ci-main run — asserted MECHANICALLY at JOB level (run-level conclusion aggregates unrelated jobs and cannot name a job): `gh run list --workflow=ci-main.yml --commit <merge-sha> --json databaseId,headSha,status,conclusion` → select the run with `headSha == <merge-sha>` (if multiple, the latest; **empty result = HARD ABORT**, do not tag) → `gh run view <run-id> --json jobs --jq '.jobs[] | select(.name=="extension-tests") | {status,conclusion}'` must be `completed` / `success`. ALSO assert the dogfood EXECUTED (a transcribed-empty accumulator skips the callee `unit-test` job while the caller still succeeds — silent false-green): `gh run view <run-id> --log` must contain the terminal marker `✅ All extension tests passed`. CRITICAL: the capability PR's own ci.yml run SKIPS the dogfood (`unit-test` has no test inputs in that caller) — checking the wrong run is a false-green. Also assert the tag base: `git merge-base --is-ancestor <merge-sha> origin/main` (squash-merge ambiguity) AND `[ "$(git rev-parse origin/main)" = "<merge-sha>" ]` (HARD ABORT otherwise — is-ancestor alone passes even when a later commit landed, and `uses: @main` resolves at run start, so the gate's dogfood could have tested a later template than the tag carries; this is the only residual path to a consumer-broken tag). → THEN `git tag v0.1.1 <merge-sha> && git push origin v0.1.1` → verify `git ls-remote --tags origin` shows v0.1.1 → THEN queue consumer PRs (GitHub resolves `uses:` refs at run start; a missing tag fails loudly, not silently). `manifest.version` unchanged.

### premise-labs PR (step 3)
**`.github/workflows/ci.yml`** — `docs-ci.yml@v0.1.0` → `@v0.1.1`, `python-ci.yml@v0.1.0` → `@v0.1.1`. `drift-check.yml@main` untouched (exempt from pin compare by design). Still exempt → vacuous green. Also reword the drift-check job's now-about-to-go-stale comment ("The pin/CI surfaces are exempted..." — true at step 3, FALSE after the step-5 lift; drop the exemption claim or mark it pending-lift).

### tortoise PR (step 4)
Pre-step (staleness guard — local main is 135 commits behind origin/main; the migration target job exists ONLY on origin/main): `git fetch origin main && git reset --hard origin/main` (or branch from origin/main).

**`.github/workflows/ci.yml`**:
- `agent-infra-ci` job: `python-ci.yml@v0.1.0` → `@v0.1.1`.
- Add drift-check job (premise-labs shape) with a disambiguation comment (distinct from the existing `drift-guard.yml` branch-drift gate, epic #1509):
  ```yaml
  drift-check:
    # agent-infra pin/symlink drift (#387) — distinct from drift-guard.yml branch-drift (#1509).
    # @main is exempt from pin compare by design.
    uses: daniel-ospina/agent-infra/.github/workflows/drift-check.yml@main
    secrets: inherit
  ```
- Replace inline `dashboard-js-tests` (lines 99-113) with:
  ```yaml
  dashboard-js-tests:
    # #387 — migrated from the hand-rolled inline job (#2044) to the reusable capability.
    # Stack gates skipped: tortoise's scripts/ is a broken-on-runner symlink (#254 fail-closed
    # would red every PR otherwise). unit-test runs `node --test src/*.test.js` from
    # website/apps/dashboard — byte-identical to the hand-rolled run.
    uses: daniel-ospina/agent-infra/.github/workflows/node-ci.yml@v0.1.1
    with:
      working-directory: website/apps/dashboard
      test-glob: 'src/*.test.js'
      script-validate: false
      skill-lint: false
    secrets: inherit
  ```
- Correct the stale header comment ("Self-contained CI (fix #555) — no reusable-workflow call": the file already calls python-ci.yml; the #555 failure mode was symlinked workflow FILES, now real).

Local proof before PR: `cd website/apps/dashboard && node --test src/*.test.js` → PASS (proves the capability's default branch executes exactly the hand-rolled command). typecheck/lint self-skip automatically (no root tsconfig/eslint — verified). Still exempt → gate vacuous green; the MIGRATION is proven non-vacuously by the dashboard-js-tests job running green via `uses:` on the tortoise PR's own CI.

### agent-infra commit — exemption lift (step 5, activation moment)
**`manifest.json`** — remove `"templates/.github/workflows/"` from `manifest.check.exemptions` for `tortoise` + `premise-labs` (delete key if array empties); KEEP `eldato-outreach` (pending #389); keep dmer/dmeer/eldato `scripts` exemptions. No ci.ref change. Consumers carry no manifest.json → the lift cannot ride consumer PRs. At merge: consumer pins (v0.1.1) == manifest ci.ref (v0.1.1) → green, non-vacuous on their next PRs. Add a JSON-safe `_note` key per remaining exemption entry (e.g. `"_note": "eldato-outreach: drop when #389 lands"`) — manifest.json is STRICT JSON parsed by loadManifest (bin/agent-infra.js:129) and run.sh require(); `//` or `#` comments crash every consumer drift-check. `_note` is safe: loadManifest does no unknown-key validation. The re-staling failure this issue fixes must not silently recur.

**Lift preflight (mechanical — the lift is LIVE at merge instant because consumer drift-check resolves agent-infra @main):** before pushing the lift commit, assert BOTH consumer PRs are merged: `git fetch <consumer-remote-url> main && git show FETCH_HEAD:.github/workflows/ci.yml | grep @v0.1.1` (the GitHub contents API returns base64 — grepping the raw response never matches; use git show). Do NOT lift if either bump is unmerged — premise-labs would red on every in-flight PR.

### Verify (step 6)
`git ls-remote --tags` shows v0.1.1; premise-labs + tortoise drift-check green NON-VACUOUSLY — assert the lift commit is on agent-infra main AND each consumer's `check --ci` output shows the CI-WORKFLOW-SURFACE lines clean: `✅ ci-ref — all agent-infra pins @v0.1.1` + the D3 symlink-sweep line green, with no `⏭️ exempted` line for `templates/.github/workflows/` (proves BOTH the pin AND symlink halves of the contract are activated — the exemption skip hid both, not just pins). Scope the assertion to the CI surface only: a LOCAL run can emit ⚠️ path-artifact lines for tortoise's machine-local scripts/ symlink (bin/agent-infra.js:500 tier-fail) that are NOT drift — on runners the same symlink is info-tier. Step 8's local sanity check similarly checks the CI surface lines.

## Implementation steps (TDD-ordered)

1. **`_checkCI` sync guard (test-first)**: add run.sh case 9 (tamper check.ci.ref → v9.9.9 → exit 1 + message → trap-based restore) → RED → implement guard (null-safe, fail-closed) → GREEN (cases 1-8 unchanged).
2. **Unit-test capability**: templates/.github/workflows/node-ci.yml → sync-ci-workflows.sh → verify `diff` template==materialized (workflow-drift gate's assertion) AND `python3 -c "import yaml; yaml.safe_load(open('templates/.github/workflows/node-ci.yml'))"` parses clean (block-style with: only — flow mappings containing `${{` are a YAML parse error; this is the exact check run.sh case 1 uses).
3. **Dogfood**: ci-main.yml extension-tests body swap (name kept; needs: untouched); YAML parse check (`python3 -c "import yaml; yaml.safe_load(...)"`); verify no test suite dropped (grep invocation counts before/after).
4. **Release axis (ONE commit)**: manifest ci.ref+check.ci.ref → v0.1.1, fixture docs-ci.yml @v0.1.1, drift-check.yml:12 doc fix, run.sh header fix. Verify `bash tests/drift/run.sh` → 9/9 green; `node scripts/ci-ref-check.test.mjs` green; `grep -q '"version": "0.1.0"' manifest.json` (the release axis changes ci.ref/check.ci.ref ONLY — the unconditional .agent-infra-version surface must not move). → PR #1.
5. **Gate + tag**: merge → wait ci-main green (head_sha match) → tag v0.1.1 → ls-remote verify.
6. **premise-labs bump** → PR (vacuous green).
7. **tortoise**: fetch/reset → pin bump + drift-check wiring + dashboard-js-tests migration + header fixes → local node --test proof → PR (migration proven non-vacuously).
8. **Exemption lift** → agent-infra commit → local pre-merge sanity: `node bin/agent-infra.js check <repo> --ci` shows `✅ ci-ref — all agent-infra pins @v0.1.1` for both consumers.
9. **Non-vacuous verify** (step 6 assertions).

## Testing strategy

- **run.sh fixture approach**: cases 2/7/8 = pin-parity canaries (fixture pin vs live manifest ci.ref) — why the fixture co-bump must land in the ci.ref commit; case 9 (new) = guard negative path.
- **ci-ref-check.test.mjs**: parse-level refs — unaffected (REUSABLE_WORKFLOWS unchanged; A requires no allowlist edit).
- **workflow-drift diff** (pipeline-compliance): template==materialized for the 3 files.
- **Migration equivalence**: unit-test job default branch (`node --test <glob>`) byte-identical to the hand-rolled tortoise job; Task 7 local run proves the suite passes before CI.
- **Dogfood run shape**: `run: ${{ inputs.test-command }}` with the raw multiline accumulator — byte-identical to today's inline execution; empirically verified against the 1722-char accumulator (the shell-interpolated alternative `if [ -n "${{...}}" ]; then ${{...}}` is a guaranteed syntax error).

## Acceptance criteria

1. node-ci.yml (template + materialized) has a `unit-test` job with node-version/working-directory/test-glob/test-command inputs; `''` defaults skip; script-validate/skill-lint skip inputs default true (explicit); existing callers' behavior unchanged.
2. tortoise `dashboard-js-tests` uses `node-ci.yml@v0.1.1` — no inline job.
3. (indicator 3 deferred → #389.)
4. premise-labs + tortoise drift-check gates green non-vacuously post-lift (log assertions).
5. agent-infra dogfoods: ci-main `extension-tests` job green at the step-1 merge commit (verify-before-tag gate).
6. `_checkCI` sync guard enforced (run.sh case 9); drift-check.yml:12 documents `manifest.ci.ref`.
7. v0.1.1 tag exists; `manifest.version` stays 0.1.0; consumers pinned @v0.1.1.

## Rollback
If the exemption lift reds a consumer's drift-check: `git revert <lift-sha>` on agent-infra main — the revert is LIVE immediately (consumer drift-check resolves agent-infra @main). Consumer pin bumps to v0.1.1 stay in place and are harmless (the tag is good; pins are already current for the next lift). ~5 minutes, single commit. Caveats: (a) in-flight PR runs that recorded red stay red; (b) if the red was caused by LATENT drift hidden under the exemption, the revert hides it again — fix the underlying drift before re-lifting. Do NOT revert the tag or consumer bumps.

## Runtime prerequisites

- gh auth + write access on daniel-ospina/agent-infra, /tortoise, /premise-labs; tag-push permission.
- Fresh agent-infra worktree (`.worktrees/feat/387-ci-central` exists, at main, clean).
- tortoise work based on origin/main, not local main (135 commits behind; migration target only remote).
- `tests/fixtures/drift/current` committed-clean before run.sh (P2-5 preflight hard-fails on dirty fixture); manifest.json backup/restore via trap in case 9.
- GitHub Actions on all three repos; node 22 on runners (setup-node; zero-dep suite, no npm ci).

## Risks

| Risk | Impact | Mitigation |
|---|---|---|
| tortoise local-main staleness | migrate nonexistent job | Task 7 pre-step fetch/reset |
| Symlink drag (broken scripts/ on runner → #254 fail-closed red) | every tortoise PR red | skip inputs (skill-lint: false LOAD-BEARING, same commit as capability); header documents contract |
| Fixture co-bump missed | step-1 PR drift-check self-test red | same-commit rule; run.sh 9/9 gate |
| Tag race (broken job pinned by consumers) | broken tag = every consumer uses: fails | verify-before-tag gate (merge → wait green → tag) |
| manifest.version accidentally bumped | premise-labs .agent-infra-version red pre-migration | runbook constant; Task 4 explicitly leaves version 0.1.0 |
| Boolean skip input default omitted | #254 gate silently disabled for ALL callers (default false) | `default: true` explicit in template + descriptions |
| quoting trap in run shape | dogfood guaranteed red | step-level if: shape (no shell interpolation) |
| auto-file needs: rename break | whole ci-main invalid at parse | job name KEPT (body-only change) |
| Lift surprises (latent drift hidden by exemptions) | first post-lift PR red | verified pre-lift: pins == v0.1.1 == ci.ref; no workflow symlinks; scripts/ symlinks info-tier on runners |
| #359 (node-ci template propagation) | materialized copies drift | related-not-blocking: copies inert, workflow-drift + sync guard keep axis honest |

## Rejected alternatives (when they WOULD have been better)

- **B — sibling unit-ci.yml**: better if the fleet were expected to stay heterogeneous (future non-bootstrapped node-ci callers where the skip-input contract is a foot-gun) or capability-per-workflow were the long-term shape. Rejected: 3 lockstep mechanical edits (sync loop, diff loop, allowlist), a 4th file, a 4th pin axis, a scope amendment — for no outcome gain over A + skip inputs.
- **C — composite action**: better if consumers genuinely needed per-repo steps between checkout and test that inputs can't express AND convention-based enforcement (until #389) were acceptable. Rejected: `.github/actions/` refs invisible to checkCiRefs (new allowlist + action branch needed), inline-job drift class persists, #389 becomes harder (job-body analysis).
- **D — enforcement-first (lift-first)**: better if contract liveness hours earlier mattered more than the hardened activation moment. Rejected: invalidates 5 cycles of verified sequencing for marginal gain; its real defect fix (tag race) absorbed additively by verify-before-tag.
- **Local-path self-caller flip** (`uses: ./.github/workflows/node-ci.yml` in agent-infra ci.yml): better if PR-gate dogfood of the new job were in scope (closes the first-run-is-post-merge hole at PR time). Rejected: out of scope per verified amendment; verify-before-tag covers the failure mode.
- **Drop ci-main inline copies** (avoid duplicate post-merge minutes): better if CI budget were the binding constraint. Rejected: inline copies carry coverage node-ci jobs lack (bash -n, installer tests #304, --skills-dir). Keep both.
