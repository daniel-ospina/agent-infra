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
   `securely-using-pull_request_target` doc. This is the missing piece: **a checker the PR cannot
   rewrite.**
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

The content lock is the primary defence here; this is a better error message for the one invariant
that is genuinely a shell-accumulator property.

### 5. `.github/workflows/workflow-lock.yml` — NEW, the checker the PR cannot edit

Uses `pull_request_target` with `permissions: { contents: read, pull-requests: read }` and
`actions/checkout` with **no `ref:`**, so GitHub checks out **main** and runs **main's** copy of the
workflow + script. The step then runs:

```
node scripts/check-pi-pin-lockstep.mjs --head-ref "$HEAD_SHA"
```

with `HEAD_SHA: ${{ github.event.pull_request.head.sha }}` passed through `env:` (injection-proof; the
SHA is hex, but env indirection also keeps actionlint's untrusted-input rule quiet). The workflow header
carries a prominent **security constraint**: `pull_request_target` runs the workflow definition from the
BASE branch (that is the whole point — the PR cannot substitute it); this workflow must therefore
**never check out, execute, or `npm install` PR content**. It reads the PR's files as *data* through the
GitHub Contents API only. Misusing this trigger is a known RCE vector; the header cites GitHub Security
Lab's `pull_request_target` guidance. No `secrets: inherit`; no secret reference (`github.token` with
`contents: read` is the only credential).

### 6. `--head-ref <sha>` mode on `scripts/check-pi-pin-lockstep.mjs` — NEW

- Fetches the three workflow files at that ref via
  `gh api "repos/{owner}/{repo}/contents/<path>?ref=<sha>"` and decodes the base64.
- Runs **only the narrow structural assertions (items 1–6)** against those bytes.
- **Skips the content lock** — otherwise every legitimate workflow change would deadlock against
  `main`'s old lock.
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
| file length | 1 650 lines | 1 692 lines |
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

**Fresh run, 2026-09-11 22:58 EST — every count below is copied from that run, not hand-maintained.**

| Surface | Layer | Command | Result |
|---|---|---|---|
| `(h)` pins | unit + negative + **positive control** | `node scripts/check-pi-pin-lockstep.mjs` | ✅ (2 tests; `pinFindings(wrongPin)` non-empty) |
| `(i)` mirror stamps | unit + negative + **positive control** | same | ✅ (2 tests; `stampFindings(stale)` non-empty) |
| narrow wiring guard (items 1–6) | unit | same | ✅ live trio + 1 baseline + 11 `expectWired` + 18 `expectRed` |
| content lock | unit + CLI | same + `node scripts/check-workflow-lock.mjs` | ✅ 7 lock tests + 4 lock-level bypass tests |
| `--head-ref` mode | unit | same | ✅ runs the structural assertions; proves the lock is not applied |
| `(h)`/`(i)`/`(j)` + lock + reader | integration | `node scripts/check-pi-pin-lockstep.mjs` | ✅ **69 passed, 0 failed** |
| #254 frontmatter validator | integration | `node scripts/check-skill-lint.test.mjs` | ✅ **160 passed, 0 failed** |
| validator oracle (pi parity + fuzz) | integration | `node --test scripts/check-skill-lint.oracle.test.mjs` | ✅ **146 passed, 0 failed, fuzz 0/1000** |
| ci-ref pin-drift unit tests | integration | `node scripts/ci-ref-check.test.mjs` | ✅ **183 passed, 0 failed** |
| workflow YAML validity | static | `bash scripts/check-workflow-actionlint.sh` | ✅ exit 0 (includes the new `workflow-lock.yml`) |

**Case census (fresh run):** 69 tests = 36 plain `test()` + 11 `expectWired` + 18 `expectRed` + 4
`expectLockRedForEdit` (each of which is one `test()`). The 36 plain tests group as 2 `(h)` + 2 `(i)`
+ 1 live wiring + 7 lock + 2 `--head-ref` + 1 fixture-trio baseline + 1 ci-main baseline + 8 ci-main
item-6 (delete, bare accumulator, echo decoy, `if`, `for`, heredoc, `|| true`, `exit 0`) + 12 reader.

## Verification plan — executed (before → after)

| # | Check | Before (design) | After (this revision) |
|---|---|---|---|
| 1 | `node scripts/check-pi-pin-lockstep.mjs` | 71 passed | **69 passed, 0 failed** |
| 2 | `node scripts/check-skill-lint.test.mjs` | 160 passed | **160 passed, 0 failed** |
| 3 | `node --test scripts/check-skill-lint.oracle.test.mjs` | 146 passed | **146 passed, 0 failed** |
| 4 | `node scripts/ci-ref-check.test.mjs` | 183 passed | **183 passed, 0 failed** |
| 5 | `bash scripts/check-workflow-actionlint.sh` | exit 0 | **exit 0** |
| 6 | `node scripts/check-workflow-lock.mjs` (baseline) | n/a (new) | ✅ green (3 files) |
| 7 | change one byte in `.github/workflows/ci.yml` | n/a | ❌ RED — names `.github/workflows/ci.yml`, differs from the locked sha256, prints the `--update-lock` remedy; restored via `cp` from `/tmp` and re-verified green (sha256 identical) |
| 8 | `--head-ref <PR head SHA>` | n/a | ✅ green — fetch through the Contents API, structural assertions only, lock skipped |
| 9 | bypass `shell: 'true {0}'` | ✅ GREEN under the round-1 guard (caught) / round-2 gaps | ❌ **lock RED**, names `node-ci.yml` |
| 10 | bypass `env:` (`NODE_OPTIONS`) | ✅ GREEN under the semantics guard | ❌ **lock RED** |
| 11 | bypass `container:` | ✅ GREEN under the semantics guard | ❌ **lock RED** |
| 12 | bypass `matrix.exclude` covering every combination | ✅ GREEN under the semantics guard | ❌ **lock RED** |

Each live-file mutation in #7 and #9–12 was restored with `cp` from a `/tmp` backup (never a
working-tree discard, #664) and every restore was sha256-verified identical before re-running the lock
green.

## Accepted residual (recorded, not papered over)

- **A PR that edits a locked workflow AND the lock together still passes.** This is the same accepted
  class already recorded for this guard ("a test that reads repo files cannot defend against a commit
  that edits the guard and the guarded thing together"), but it is now **conspicuous**: two files, one
  literally named a lock, and the diff shows the hash change.
- **A content lock asserts *unchanged*, not *correct*.** A pinned workflow can still be wrong; the lock
  says "nobody edited it since the hash was recorded", nothing more.
- **Deliberate-update tax.** Any legitimate edit to `ci.yml`, `node-ci.yml` or `ci-main.yml` requires
  re-running `node scripts/check-workflow-lock.mjs --update-lock` and committing the lock alongside it.
  This is the intended loud behaviour; the cost is one line in the diff.
- **`pull_request_target` is a privileged trigger.** The workflow must never check out or execute PR
  content. The checker reads file bytes through the Contents API only. This constraint is stated in the
  workflow header because misusing this trigger is a well-known RCE vector.
- **The library `templates/.github/workflows/` copy is out of scope for the lock**;
  `workflow-drift` already covers `node-ci.yml`.

## Review & negative-testing log

- **Design** — the #666 architecture decision (posted on the issue) replaced the semantics model after
  two review rounds each found working bypasses; the second round's were created by the first round's
  fixes.
- **negative testing** — 18 `expectRed` structural-bypass fixtures + 4 `expectLockRedForEdit` lock-level
  bypass fixtures (one per round-2 class) + 8 ci-main item-6 fixtures (incl. the three control-flow
  evasions) + 7 lock lifecycle/CLI tests, all in-suite. Plus the live-file mutation round in
  §Verification plan #7–12 (all restored byte-identical via `cp`, #664).
- **positive controls** — `(h)`/`(i)` carry their explicit predicate positive controls (#675 P1-3);
  every one of items 1–6 has a failing fixture and a passing fixture.
- **`MIN_EXPECTED_PASSING` floor** — 71 → **69**, so a wholesale deletion of a rule's test stays red.

## Out of Scope

| Item | Owner / disposition |
|---|---|
| Making the checker a required status check (branch protection) | **#646/#673** — the workflow exists; making it *required* is a branch-protection change needing human sign-off. |
| A separate CI check context for pin drift | **#673** |
| The `@main`-at-PR-time input-resolution seam | accepted, time-limited bound (#637 plan) |
| A nested/root `package.json` walk for extension pins | **#643** |
| Version-specific line refs in the mirror surfaces | **#651** |
| General YAML features outside the reader subset (folding/chomping, multi-line plain scalars, anchors/aliases/tags, merge keys, multi-doc) | documented reader bound; the reader throws rather than guesses |
