---
title: "#666 — replace execution-semantics modelling with a content lock + a base-branch checker — Scope & Plan"
type: engineering
domain: operations
doc_status: draft
subjects.team: organisation-design-team
created: 2026-09-10
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-666
---

<!-- research-path: inline — the content-lock decision research is §Decision record (each option's feasibility was probed; the authoritative external evidence is cited below). The full decision is posted on issue #666. -->

# #666 — replace execution-semantics modelling with a content lock + a base-branch checker

## Confirmed Problem

Guard `(j)` answered "is the per-PR pin gate still wired?" by reading **GitHub Actions execution
semantics** out of a hand-written YAML-subset reader (`scripts/workflow-yaml.mjs`), using a
**denylist** of things that can neutralise the step that runs the pin suite. Two review rounds each
found working bypasses, and the second round's were **created by the first round's fixes**:

| Round | Bypass (reproduced GREEN with the gate unplugged) |
|---|---|
| 1 | `shell: 'true {0}'` on the step; job-level `defaults.run.shell`; YAML escape sequences in quoted keys (`"paths\u002dignore"`, `"i\u0066"`) |
| 2 | workflow-level `defaults.run.shell` in `node-ci.yml`; `env:` on the step (`NODE_OPTIONS=--import=…`, `BASH_ENV`, `PATH`); `container:` / `services:` on `unit-test`; `matrix.exclude` covering every combination |

Every one of those requires **editing the workflow file**. So the question the guard was asking —
"will GitHub execute this?" — was the wrong question, and modelling the answer kept losing.

**External evidence (authoritative):**

1. **A required status check does not close the class.** GitHub's own "Troubleshooting required
   status checks" table: a job skipped by a conditional reports **"Success"** and does **not** block
   merging; a check that never reports stays **Pending** and blocks. Corroborated by
   `docs.github.com/…/about-protected-branches` ("successful, skipped, or neutral status") and
   `…/reference/status-checks`. So #646/#673 (make the suite required) closes "the job was
   deleted/renamed" and "the trigger was removed", but leaves **"the job ran and lied"** wide open —
   exactly the class the round-2 bypasses live in.
2. **`pull_request_target` runs the workflow file from the BASE branch.** GitHub Security Lab,
   *Keeping your GitHub Actions and workflows secure* Part 4. Corroborated by GitHub's
   `securely-using-pull_request_target` doc. This is the missing piece: **a checker whose
   *structural assertions* the PR cannot rewrite** (the PR can still edit its own copy of the lock and
   the checked-in suite — see the Accepted-residual section).
3. **Hash-pinning a workflow file is not a standard pattern — and that is fine.** Pinning *actions*
   to full commit SHAs is the norm; the workflow file is "usually managed through normal Git history
   and branch protections". The general integrity pattern (record a SHA-256, fail when it changes) is
   well established for CI inputs, and its known drawback applies here too: it does **not** prove the
   pinned content is safe, and it creates **deliberate-update work** on every legitimate edit.

## Decision

**Replace the execution-semantics modelling with a content lock, and run the checker from a
`pull_request_target` workflow defined on `main`.** The full decision is posted on issue #666.

### 1. `scripts/workflow-lock.json` — NEW

```json
{ "version": 1, "files": { ".github/workflows/ci.yml": "<sha256>", ".github/workflows/node-ci.yml": "<sha256>", ".github/workflows/ci-main.yml": "<sha256>" } }
```

The committed hashes are the real current bytes. A `--update-lock` mode rewrites it.

### 2. `scripts/check-workflow-lock.mjs` — NEW

- Exports `hashLockedFiles(root)` and `lockFindings(root, lock)`.
- `lockFindings` **returns findings** (never throws) so the CI suite can aggregate: a missing file, a
  hash mismatch (naming the file and printing the exact
  `node scripts/check-workflow-lock.mjs --update-lock` remedy), an uncovered expected path, an
  unexpected extra path, and a bad lock schema/version.
- CLI: default = report + exit 1 on any mismatch; `--update-lock` = rewrite the lock. (`--root <dir>`
  exists so the suite can drive the CLI against a throwaway fixture root.)
- **No YAML parsing. No shell modelling.** It hashes bytes and compares.

### 3. `scripts/check-pi-pin-lockstep.mjs` — the semantics modelling deleted, the narrow guard kept

**DELETED** — every check that models *execution semantics*: the `shell:` allowlist/rejection, the
`CUSTOM_STEP_KEYS` allowlist concept, `container`, `services`, `runs-on`, `defaults` (all levels),
`strategy.matrix` emptiness/`exclude` logic, block-scalar shell-body reasoning, trigger filters
(`paths`/`paths-ignore`/`branches`/`branches-ignore`/`types`), job/step `needs:`, and the step-level
`if:`/`run:` predicates. Those are all replaced by the content lock. `scripts/workflow-yaml.mjs` stays
as the parser — the narrow assertions still read parsed nodes.

**KEPT** — a narrow structural guard (`wiringFindings`), reading parsed nodes, asserting only *values*:

| # | Assertion | Failure fixture (positive control) |
|---|---|---|
| 1 | `.github/workflows/ci.yml` has a `pull_request` trigger, any valid spelling (bare mapping key, `on: pull_request` scalar, or a flow sequence containing it — not a decoy line inside a block scalar, not a non-`on` mapping) | trigger → `push`; `on: [push]`; `pull_request:` inside a `run-name: \|` scalar; `pull_request:` under `env:` |
| 2 | the `ci` job's `uses` is exactly `daniel-ospina/agent-infra/.github/workflows/node-ci.yml@main` | `@v1.2.3`; an unanchored `uses:` substring elsewhere does not count |
| 3 | the `ci` job has no `if:` and no truthy `continue-on-error:` | `if: github.event_name == 'push'`; `continue-on-error : true`; `"i\u0066"` (escape-decoded) |
| 4 | the `ci` job's `with:` key set is exactly `["test-command"]` and its value is exactly the expected accumulator command | emptied binding; `\|\| true` suffix; extra `with:` key; losing the second suite; a `test-command:` line inside a block scalar |
| 5 | `node-ci.yml` still declares the `unit-test` job and the `test-command` workflow_call input | renamed input; removed `unit-test` job |
| 6 | `.github/workflows/ci-main.yml` still invokes this suite in its failure-accumulating form | see below |

Each item has both a failing fixture and a passing fixture (the fixture trio / spelling reformats).

### 4. Item 6 is the one exception to "no shell modelling"

The `ci-main.yml` invocation is read as a **line**, not a parsed node, because the thing being
asserted is a **shell failure-accumulator** (and a line check produces a better message than "file
changed"). The line check additionally rejects the round-2 **control-flow evasions** a matched line
alone would miss:

- a matched invitation inside `if`/`then`/`fi`, `for`/`while`/`until`/`done`, or a **heredoc** context
  (never executed);
- an `\|\| true` between the invocation and the accumulator (the `true` short-circuits past the
  accumulator on failure);
- an `exit 0` after the invocation and before the `if [ $failures -gt 0 ]` guard (the recorded failure
  is swallowed).

The trust split is stated authoritatively in the module header of
`scripts/check-pi-pin-lockstep.mjs`: the content lock is a conspicuousness tripwire enforced by
PR-editable code, this trusted leg provides the structural assertions only and **zero** lock
enforcement, and a PR that edits a workflow and the lock together passes both legs. Item 6 is therefore
a bounded **lexical** shape check — quoted spans, comments and heredoc bodies are removed, a keyword
counts only in command position, and the failure guard must exist and leave the step non-zero — not an
execution-semantics model. It is a better error message for the one invariant that is genuinely a
shell-accumulator property.

### 5. `.github/workflows/workflow-lock.yml` — NEW, the trusted leg

Uses `pull_request_target` with `permissions: { contents: read }` and `actions/checkout` with **no
`ref:`**, so GitHub checks out **main** and runs **main's** copy of *this workflow* + script. The step
then runs:

```
node scripts/check-pi-pin-lockstep.mjs --head-ref "$HEAD_SHA"
```

with `HEAD_SHA: ${{ github.event.pull_request.head.sha }}` passed through `env:`. The justification for
the `env:` indirection is **not** actionlint — actionlint does not flag `head.sha` (it flags `title`
and `head.ref`) — it is GitHub's script-injection guidance: an expression interpolated straight into
`run:` shell text is the injection pattern, so untrusted values stay in `env:` and the shell only ever
sees a variable reference. The SHA is hex today, so this is defence-in-depth, not a live hole. (An
earlier revision of this plan gave the actionlint reason, which was false.)

**Bootstrap — this file is inert until the next PR.** `pull_request_target` resolves the workflow file
from the **default branch**, so this job does **not** run on the PR that adds it; it takes effect on the
next PR after this file lands on `main`. Because nothing writes post-merge evidence for that, the suite
asserts instead that `workflow-lock.yml` exists and is wired (a `pull_request_target` trigger plus a
step running `--head-ref`), so deleting or unwiring it is RED.

The workflow header carries a prominent **security constraint**: `pull_request_target` runs the
workflow definition from the BASE branch (that is what it buys — the PR cannot substitute *this file*);
this workflow must therefore **never check out, execute, or `npm install` PR content**. It reads the
PR's files as *data* through the GitHub git tree + blob API only (the tree's committed `mode` is
checked first and any non-`100644` workflow entry is rejected before content is read), decoding base64
and failing closed on anything else. Misusing this trigger is a known RCE vector; the header cites
GitHub Security Lab's `pull_request_target` guidance. No `secrets: inherit`; no secret reference
(`github.token` with `contents: read` is the only credential).

### 6. `--head-ref <sha>` mode on `scripts/check-pi-pin-lockstep.mjs` — NEW

- Fetches the recursive git TREE at that ref via
  `gh api "repos/{owner}/{repo}/git/trees/<sha>?recursive=1"`, rejects any of the three workflow paths
  whose committed git `mode` is not `100644` (a symlink `120000` or submodule `160000` is a broken
  workflow entry that runs 0 jobs, while the Contents API would dereference it), then fetches each
  remaining path's BLOB by its **tree sha** (`repos/{owner}/{repo}/git/blobs/<sha>`) so the bytes
  parsed are the committed ones and never a dereference.
- Decodes the blob base64, **fail-closed**: only `encoding: "base64"` is accepted (the API returns
  `encoding: "none"` with empty content for a >1 MB blob) and the decode is fatal on invalid UTF-8, so
  a padded or damaged read cannot masquerade as an empty workflow.
- Runs **only the narrow structural assertions (items 1–6)** against those bytes.
- **Skips the content lock** — otherwise every legitimate workflow change would deadlock against
  `main`'s old lock. This leg therefore provides **zero lock enforcement**; see the authoritative
  trust-split statement in the module header of `scripts/check-pi-pin-lockstep.mjs`.
- `--repo <owner/name>` overrides the repo (else it is derived from `git remote get-url origin`).

## What changed

| File | Change |
|---|---|
| `scripts/check-workflow-lock.mjs` | **NEW** — byte-level content lock; `hashLockedFiles`/`lockFindings` exports; `--update-lock`/`--root` CLI. No YAML parsing, no shell modelling. |
| `scripts/workflow-lock.json` | **NEW** — `version: 1` + sha256 for exactly the three pin-gate workflow paths. |
| `scripts/check-pi-pin-lockstep.mjs` | Execution-semantics modelling deleted (see §Deleted); narrow `wiringFindings` (items 1–6) kept; content-lock section + `--head-ref` mode + item-6 control-flow evasions added. |
| `.github/workflows/workflow-lock.yml` | **NEW** — `pull_request_target` base-branch checker with the security header. |
| `docs/plans/2026-09-10-issue-666-pin-guard-parse.md` | this plan. |

### Deleted from `scripts/check-pi-pin-lockstep.mjs` (semantics modelling)

Measured against the pre-change revision (`676c0d2`):

| Measure | Before (`676c0d2`) | After |
|---|---|---|
| file length | 1 650 lines | 2 364 lines (1 692 after the redesign, +672 in the #675 review-fix cycle) |
| `wiringFindings` function body | 261 lines | 122 lines |
| semantics-only constants (`CUSTOM_STEP_KEYS`, `ACCEPTABLE_SHELLS`, `TRIGGER_FILTERS`) | 3 | 0 |
| semantics test cases (GREEN reformats + RED bypasses whose subject was execution semantics) | 21 | 0 |

The 21 deleted test cases are: the 4 GREEN reformats `a parent-indent step sequence`, `a block-scalar
run: body`, `a NON-empty strategy.matrix`, `an explicit shell: bash`; and the 17 RED bypasses for the
decoy dead step, the decoy comment line, caller/callee `needs:`, the two trigger-filter cases, the
unsatisfiable `unit-test` predicate, the rewired step predicate, the step-run `|| true`, step and
callee `continue-on-error`, the step `shell:`, the job `defaults.run.shell`, the two empty
`strategy.matrix` dimensions, and the two escape-decoded step/filter keys. `ciMainFindings` grew from
49 to 79 lines — the item-6 control-flow rejections added there.

## Testing strategy

**Fresh run, 2026-09-11 23:32 EST (post-#675 review-fix cycle) — every count below is copied from that run, not hand-maintained.**

| Surface | Layer | Command | Result |
|---|---|---|---|
| `(h)` pins | unit + negative + **positive control** | `node scripts/check-pi-pin-lockstep.mjs` | ✅ (2 tests; `pinFindings(wrongPin)` non-empty) |
| `(i)` mirror stamps | unit + negative + **positive control** + #779 prose fixture | same | ✅ (3 tests; `stampFindings(stale)` non-empty; the four prose lines stay empty) |
| narrow wiring guard (items 1–6) | unit | same | ✅ live trio + 1 fixture-trio baseline + 1 empty/comments-only RED + 11 `expectWired` + 18 `expectRed` |
| content lock | unit + CLI | same + `node scripts/check-workflow-lock.mjs` | ✅ 7 lock tests + 4 lock-level bypass tests + 5 `lockFindings` branch controls + 2 coverage + 1 symlinked-CLI + 1 `workflow-lock.yml` wiring |
| `--head-ref` mode | unit + e2e | same | ✅ runs the structural assertions; proves the lock is not applied; RED for empty/comments-only input; git-tree mode rejection (`120000`) and blob-decode fail-closed |
| `(h)`/`(i)`/`(j)` + lock + reader | integration | `node scripts/check-pi-pin-lockstep.mjs` | ✅ **109 passed, 0 failed** |
| #254 frontmatter validator | integration | `node scripts/check-skill-lint.test.mjs` | ✅ **160 passed, 0 failed** |
| validator oracle (pi parity + fuzz) | integration | `node --test scripts/check-skill-lint.oracle.test.mjs` | ✅ **146 passed, 0 failed, fuzz 0/1000** |
| ci-ref pin-drift unit tests | integration | `node scripts/ci-ref-check.test.mjs` | ✅ **183 passed, 0 failed** |
| workflow YAML validity | static | `bash scripts/check-workflow-actionlint.sh` | ✅ exit 0 (includes the new `workflow-lock.yml`) |

**Case census (fresh run, third revision):** 109 tests = 76 plain `test()` + 11 `expectWired` + 18
`expectRed` + 4 `expectLockRedForEdit` (each of which is one `test()`). The 76 plain tests cover
`(h)`, `(i)`, the live wiring trio, the lock lifecycle/schema/coverage/`workflow-lock.yml` tests,
`--head-ref` (unit + stubbed-`gh` e2e), the blob decode guard, the item-6 block, the exit-path floor
and the reader. The run also asserts a set of REQUIRED TEST NAMES (see below), so a deleted or renamed
assertion is RED regardless of the total. It does NOT catch a required test whose BODY is replaced by
a same-name no-op — that is a same-commit residual, recorded explicitly below.

## Verification plan — executed (before → after)

| # | Check | Before (design) | After (this revision) |
|---|---|---|---|
| 1 | `node scripts/check-pi-pin-lockstep.mjs` | 71 passed | **109 passed, 0 failed** |
| 2 | `node scripts/check-skill-lint.test.mjs` | 160 passed | **160 passed, 0 failed** |
| 3 | `node --test scripts/check-skill-lint.oracle.test.mjs` | 146 passed | **146 passed, 0 failed** |
| 4 | `node scripts/ci-ref-check.test.mjs` | 183 passed | **183 passed, 0 failed** |
| 5 | `bash scripts/check-workflow-actionlint.sh` | exit 0 | **exit 0** |
| 6 | `node scripts/check-workflow-lock.mjs` (baseline) | n/a (new) | ✅ green (3 files) |
| 7 | change one byte in `.github/workflows/ci.yml` | n/a | ❌ RED — names `.github/workflows/ci.yml`, differs from the locked sha256, prints the `--update-lock` remedy; restored via `cp` from `/tmp` and re-verified green (sha256 identical) |
| 8 | `--head-ref <PR head SHA>` | n/a | ✅ green — fetch through the git tree + blob API, structural assertions only, lock skipped |
| 9 | bypass `shell: 'true {0}'` | ✅ GREEN under the round-1 guard (caught) / round-2 gaps | ❌ **lock RED**, names `node-ci.yml` |
| 10 | bypass `env:` (`NODE_OPTIONS`) | ✅ GREEN under the semantics guard | ❌ **lock RED** |
| 11 | bypass `container:` | ✅ GREEN under the semantics guard | ❌ **lock RED** |
| 12 | bypass `matrix.exclude` covering every combination | ✅ GREEN under the semantics guard | ❌ **lock RED** |

Each live-file mutation in #7 and #9–12 was restored with `cp` from a `/tmp` backup (never a
working-tree discard, #664) and every restore was sha256-verified identical before re-running the lock
green.

## #675 review-fix cycle (2026-09-11)

A four-agent review of the redesign reproduced the following; the fix cycle is committed on
`refactor/666-pin-guard-parse`. Every item below was verified by RUNNING the named command.

| # | Defect | Fix |
|---|---|---|
| P1-a | `wiringFindings` FAILED OPEN on a zero-token document (`parseWorkflowYaml("")` → null, and every assertion was guarded by `if (caller !== null)`), so an empty `ci.yml` produced zero findings and the trusted leg printed ✅; compounding, the ref-file fetch ignored `encoding` (a >1 MB blob returns `encoding: "none"` + empty content) | `null`/non-mapping parse is now a finding for `ci.yml` and `node-ci.yml` exactly as `ciMainFindings` does; `decodeBase64Blob` accepts only `encoding: "base64"` and decodes with `TextDecoder(…, { fatal: true })` |
| P1-b | The lock was described as “THE PRIMARY DEFENCE … the PR cannot delete or neuter the checker”, but its only call site is the PR's own copy of the script, run from the PR-editable `ci.yml` | Claims corrected, mechanism unchanged. The authoritative trust-split statement is the module header of `scripts/check-pi-pin-lockstep.mjs`; the workflow header and this plan reference it |
| P1-c | The stamp regex keyed on the generic English words `version`, `parity`, `probe` (the #779 class) | The marker is now the pi token (`\bpi\b`) only; the ci-main.yml stamp comments were reworded to name pi; four GREEN prose fixtures added |
| P1-d | `shellControlContext` split lines on non-word characters, so `echo "checking if the suite is wired"` opened an `if` block | Quotes/comments/heredoc bodies are removed and keywords count only in command position; GREEN fixture added for quoted `if`/`for`/`while` prose |
| P2-a | The item-6 rejections were evadable (guard removed, guard body echo, `case` arm, function body, `false && {`, inline `exit 0`, `trap … EXIT`) | The failure guard must EXIST and `exit` non-zero, quotes/comments/heredocs are stripped, keywords count only in command position, and `case`/`esac`, `{ … }`/`( … )` groups, `trap … EXIT` and `exit 0` are all rejected. Seven RED fixtures added |
| P2-b | `check-workflow-lock.mjs` `IS_MAIN` compared a resolved path to a realpath, so a symlinked ancestor made `main()` never run and exit 0 silently (#708) | Realpath on BOTH sides; a symlinked-CLI fixture asserts a real run |
| P2-c | `MIN_EXPECTED_PASSING` was a count, not an identity | A set of required test NAMES is recorded by `test()` on pass; a missing name is RED. The count floor stays as a secondary signal |
| P2-d | A workflow on disk but absent from the lock was silently accepted; deleting `workflow-lock.yml` stayed green | `workflowCoverageFindings` classifies every `.github/workflows/*.yml` against an explicit locked/unlocked allowlist |
| P2-e | The `lockFindings` schema branches had no positive control | One unit test per branch (non-object, version, no `files`, uncovered path, extra path), each asserting a finding naming the `--update-lock` remedy |
| P2-f | `parseFlow` re-scanned the whole remaining text per nesting level: `key: [[[[…]]]]` was O(depth × length) and ended in a RangeError (10 KB 3.5 s, 104 KB 61.5 s) | Single-pass flow parser + a bounded recursion depth (`MAX_FLOW_DEPTH`); a deeply nested flow document now raises `WorkflowYamlError` in milliseconds |
| P2-g | Bootstrap was undocumented: `pull_request_target` resolves from the default branch, so the workflow does not run on this PR | Documented in the workflow header and this plan; the suite asserts `workflow-lock.yml` exists and is wired (trigger + `--head-ref`), so deleting/unwiring it is RED |
| P2-h | `workflow-lock.yml` granted unused `pull-requests: read`; the plan claimed the `env:` indirection kept actionlint quiet (it does not flag `head.sha`) | Scope removed; the plan now gives the real justification (GitHub's script-injection guidance — keep the expression out of `run:` shell text) |

**P2-a choice — extended the check, did not collapse it to a pure literal assertion.** The task offered a
pure value assertion (pin the exact accumulator + guard block) as the alternative. It cannot see five of
the seven required RED cases: a relocated invocation (`case` arm, function body, `false && {`), an inline
`exit 0` and a `trap … EXIT` all leave the literal accumulator line and guard block present and exact
while the gate is dead. Pinning the WHOLE `test-command` string would catch them, but ci-main's
`test-command` legitimately changes for unrelated suites, so that turns every such change into a
false-RED and re-creates the #779 class this PR is fixing. So item 6 remains a bounded LEXICAL check —
quotes/comments/heredoc bodies removed, keywords counted only in command position, and the guard
required to exist and exit non-zero — with the content lock still the tripwire and this only the
better error message (the module header's authoritative trust split).

## #675 second review-fix cycle (2026-09-12)

A re-verification of the first fix cycle found the following. Every one was reproduced with a command
before being fixed, and every fix is covered by a RED or GREEN fixture.

| # | Defect | Fix |
|---|---|---|
| P1-1 | **Regression introduced by the first fix.** The new command-position logic cleared `commandStart` after any non-keyword token, so `!` and `time` (which suppress errexit, keeping the step green) were treated as a consumed command and the `if`/`while`/`for` behind them was never counted. Five such cases were GREEN through the real `--head-ref` path | `!`, `time`, `time -p`, `{`, `}`, `coproc` are command-position neutral (they do not clear it); five RED fixtures + a `time -p` fixture added |
| P1-2 | **Symlink bypass.** Both controls dereferenced a symlinked workflow (`fs.readFileSync`, and the contents API returns the target's bytes) so a symlink kept the lock hash identical and the trusted leg green, while GitHub runs 0 jobs for a symlinked workflow entry. The pre-existing `find -type l` sweep lives in a non-required sibling job of `pipeline-compliance.yml` (on `UNLOCKED_WORKFLOWS`, run from the PR's own copy) | Both guards fail closed on non-regular files: `lockFindings` and `workflowCoverageFindings` `lstat` and reject a non-regular entry; `--head-ref` fetches the git TREE, rejects any `HEAD_REF_FILES` entry whose committed `mode` is not `100644`, and fetches blobs by tree sha so the bytes are never a dereference. RED fixtures for both paths, plus a stubbed-`gh` e2e pair |
| P2-3 | `select` was missing from the loop keyword set, so `select x in a; do <invocation> done` was accepted as top-level while the body never runs with stdin closed | `select` added to the loop set and the label; RED fixture |
| P2-4 | A surviving false claim: a comment still called the lock "THE PRIMARY DEFENCE", contradicting the corrected header; the plan said "a checker the PR cannot rewrite" | Reworded to the conspicuousness tripwire; the plan now says the checker's *structural assertions* cannot be rewritten (the PR can still edit its own lock and the checked-in suite) |
| P2-5 | The roster is names-only: replacing a required test's BODY with `assert.ok(true)` while keeping the name yields a green run, but three comments/plan lines claimed a "neutered" assertion was RED | The three strings now say "deleted or renamed"; the same-name-neutering residual is recorded below |
| P2-6 | `sameRealPath` returned false for ANY `realpathSync` failure, so a vanished `process.argv[1]` made `IS_MAIN` false and the process exited 0 with no output (the #708 symptom this comparison closed) | On failure, fall back to a literal comparison, then to resolved-parent-directory + basename (covers a symlinked ancestor such as `/var` → `/private/var`); a self-deleting-`argv[1]` fixture asserts a non-zero exit |
| P2-7 | `<<<` here-strings matched the heredoc regex starting at index 1, so `grep -q foo <<< bar` before the invocation was a false RED — the #779 class | The heredoc regex requires `<<` not preceded/followed by `<`; GREEN fixture for `cmd <<< word` |
| P2-8 | `process.exit(0)` before the first test (or inside a required test) exited 0 with zero ✅ lines — the floor and roster ran only at the end of the module body | The floor + roster are declared and registered on the `exit` event near the top of the file, and `finalize()` sets `process.exitCode`; a fixture proves an early `process.exit(0)` now exits 1 |

## Accepted residual (recorded, not papered over)

- **A required test whose BODY is replaced by a same-name no-op is not caught (#675 P2-5).** The
  roster records test NAMES, not semantics: `test("<required name>", () => assert.ok(true))` passes and
  the suite stays green (`node scripts/check-pi-pin-lockstep.mjs` → `109 passed, 0 failed`, exit 0,
  measured on a full repo copy). No in-file mechanism can defend against a same-commit body rewrite
  (the roster, the floor and the exit handler are all in the file the PR can edit) — this is the same
  accepted same-commit class as the lock. The roster's claim is therefore bounded to **deleted or
  renamed** tests, and the three strings that claimed otherwise were corrected.
- **GitHub's own 0-jobs behaviour for a symlinked workflow is out of scope (#675 P1-2).** Both guards
  now REJECT a non-regular workflow entry, but a symlink under `.github/workflows/` still makes the
  per-PR `ci.yml` a broken workflow entry that runs 0 jobs, and `ci.yml` is not a required check. Making
  the per-PR pin suite a required status check is the branch-protection work owned by **#646/#673**;
  this PR closes the guard-side bypass (so the symlink is at least RED in both guards) but does not by
  itself block the merge.
- **`--head-ref` trusts the git tree payload.** A truncated tree is an error (fail-closed), and modes
  are read from the API's `mode` field; a future API change to the tree shape would surface as a
  fetch/parse finding, not a silent pass.

- **A PR that edits a locked workflow AND the lock together still passes.** This is the same accepted
  class already recorded for this guard ("a test that reads repo files cannot defend against a commit
  that edits the guard and the guarded thing together"), but it is now **conspicuous**: two files, one
  literally named a lock, and the diff shows the hash change. The authoritative statement of this trust
  split is the module header of `scripts/check-pi-pin-lockstep.mjs`; this section and the workflow
  header reference it rather than restating it, so the three cannot drift apart.
- **The lock is enforced by PR-editable code, and the trusted leg enforces none of it.**
  `lockFindings()`'s only call site is the PR's own copy of the checker, run from the PR-editable
  `ci.yml`; `--head-ref` skips the lock entirely. So a PR that deletes or neuters the lock check in its
  own copy is not caught by the trusted leg, and a PR that edits a workflow together with the lock
  passes both. The lock's real value is conspicuousness — an edit to a locked file cannot be silent.
- **Item 6 is a bounded lexical check, not a shell model.** It removes quoted spans, comments and
  heredoc bodies, counts control-flow keywords only in command position, and requires the exact
  accumulator line plus a failure guard that exits non-zero. It is deliberately not a general shell
  interpreter, and it does not claim to be.
- **A content lock asserts *unchanged*, not *correct*.** A pinned workflow can still be wrong; the lock
  says "nobody edited it since the hash was recorded", nothing more.
- **Deliberate-update tax.** Any legitimate edit to `ci.yml`, `node-ci.yml` or `ci-main.yml` requires
  re-running `node scripts/check-workflow-lock.mjs --update-lock` and committing the lock alongside it.
  This is the intended loud behaviour; the cost is one line in the diff.
- **`pull_request_target` is a privileged trigger.** The workflow must never check out or execute PR
  content. The checker reads file bytes through the git tree + blob API only (never executing them). This constraint is stated in the
  workflow header because misusing this trigger is a well-known RCE vector.
- **The library `templates/.github/workflows/` copy is out of scope for the lock**;
  `workflow-drift` already covers `node-ci.yml`.

## Review & negative-testing log

- **Design** — the #666 architecture decision (posted on the issue) replaced the semantics model after
  two review rounds each found working bypasses; the second round's were created by the first round's
  fixes.
- **negative testing** — 18 `expectRed` structural-bypass fixtures + 4 `expectLockRedForEdit` lock-level
  bypass fixtures (one per round-2 class) + 8 ci-main item-6 fixtures (incl. the three control-flow
  evasions) + 7 lock lifecycle/CLI tests, all in-suite; the #675 review-fix cycle added the 7 P2-a
  item-6 evasions, the empty/comments-only P1-a fixtures, the Contents-API decode guard, the 5
  `lockFindings` branch controls, the symlinked-CLI fixture, the workflow-coverage fixtures, the
  `workflow-lock.yml` wiring assertion, the #779 prose fixtures and the deep-flow-nesting fixture. Plus
  the live-file mutation round in §Verification plan #7–12 (all restored byte-identical via `cp`, #664).
- **positive controls** — `(h)`/`(i)` carry their explicit predicate positive controls (#675 P1-3);
  every one of items 1–6 has a failing fixture and a passing fixture; `lockFindings` now has one
  positive control per schema branch (#675 P2-e).
- **`MIN_EXPECTED_PASSING` floor** — 71 → 91 → **109** (third revision; the #675 second review-fix
  cycle added 18 fixtures), and it is now a SECONDARY signal: the run also asserts a set of required
  test NAMES (#675 P2-c), so deleting or renaming a real test is RED even when the count is unchanged.
  The floor and the roster are evaluated in a `process.on("exit", …)` handler (#675 P2-h), so an early
  `process.exit(0)` cannot skip them.

## Out of Scope

| Item | Owner / disposition |
|---|---|
| Making the checker a required status check (branch protection) | **#646/#673** — the workflow exists; making it *required* is a branch-protection change needing human sign-off. |
| A separate CI check context for pin drift | **#673** |
| The `@main`-at-PR-time input-resolution seam | accepted, time-limited bound (#637 plan) |
| A nested/root `package.json` walk for extension pins | **#643** |
| Version-specific line refs in the mirror surfaces | **#651** |
| General YAML features outside the reader subset (folding/chomping, multi-line plain scalars, anchors/aliases/tags, merge keys, multi-doc) | documented reader bound; the reader throws rather than guesses |
