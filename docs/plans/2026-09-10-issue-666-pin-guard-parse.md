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
**denylist** of things that can neutralise the step that runs the pin suite. Two review rounds on this
reader each found working bypasses, and the second round's were **created by the first round's fixes**:

| Round | Bypass (reproduced GREEN with the gate unplugged) |
|---|---|
| 1 | `shell: 'true {0}'` on the step; job-level `defaults.run.shell`; YAML escape sequences in quoted keys (`"paths\u002dignore"`, `"i\u0066"`) |
| 2 | workflow-level `defaults.run.shell` in `node-ci.yml`; `env:` on the step (`NODE_OPTIONS=--import=…`, `BASH_ENV`, `PATH`); `container:` / `services:` on `unit-test`; `matrix.exclude` covering every combination |
| 3–5 | three more P1s in the *same* shell scanner: the failure guard hidden in `if false; then … fi`, in a never-called shell function, or in a heredoc; the invocation swallowed by a multi-line quoted string; and one false RED the other way (`echo "a <<x"` arming a phantom heredoc) |

The pattern held for **five** rounds, and round 4's fix introduced a fresh fail-open (an uncaught
`throw` inside the `exit` handler with `process.exit(0)` pending leaves the code at **0**, not 1 —
measured, see §"#666 third revision"). That is the evidence for the conclusion in §4: re-modelling
shell constructs does not converge.

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
  unexpected extra path, and a bad lock schema/version. It `lstat`s **every path component** from the
  repo root down (a symlinked `.github` or `.github/workflows` directory, not just a symlinked file,
  is a finding — `readdirSync` would otherwise follow it).
- CLI: default = report + exit 1 on any mismatch; `--update-lock` = rewrite the lock — **refusing** to
  hash through a symlinked locked path (exit 1, no success banner) so the tool cannot record a hash it
  would immediately reject on the next verify. (`--root <dir>` exists so the suite can drive the CLI
  against a throwaway fixture root.)
- The workflow sweep matches `/\\.ya?ml$/`, so a `.yaml` workflow is classified and covered rather than
  invisible to a `.yml`-only filter.
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
| 6 | **6a (structure, trusted leg + local)** `.github/workflows/ci-main.yml` still declares the `extension-tests` pin-gate job and the `with:` key set `["node-version", "script-validate", "skill-lint", "test-command"]`, the last non-empty | missing job; extra `with:` key; dropped `test-command`; emptied `test-command`; scalar `with:`; empty document |
| **6b** | **(behavioural, local leg only)** the committed post-merge `test-command` **exits non-zero** under `bash -e` with a failing `node` stub | negative control (guard inside `if false … fi`); guard in a never-called function; guard in a heredoc; invocation inside a multi-line quoted string; positive control (passing stubs → exit 0) |

Each item has both a failing fixture and a passing fixture (the fixture trio / spelling reformats).

### 4. Item 6 is a BEHAVIOURAL assertion — execution, not shell modelling

> **Revised in the third cycle (see §"#666 third revision" below).** The first two revisions read
> `ci-main.yml` as a **line** and modelled POSIX shell with a lexical scanner. Five review rounds
> found a fresh bypass each time. That scanner is **deleted**; item 6 now **executes** the committed
> command. The historical description is kept in the second-cycle table below so the deletion is
> legible.

Item 6 asks a question no value assertion can answer — *can the committed post-merge `test-command`
actually fail the step?* — and answers it by running the committed command:

1. parse `ci-main.yml` with `scripts/workflow-yaml.mjs` (never grep) and take the `extension-tests`
   job's `test-command` body;
2. write it to a temp dir and run it as `bash -e <script>` with `node` — plus `npx`, `npm` and
   `bash`, the other interpreters that command shells out to — replaced by stubs that exit 1, first
   on `PATH`;
3. assert the step exits **non-zero**.

The stub bounds the run: it guarantees termination (the real suites can never re-enter) and makes
every suite's verdict a knob. `bash`, not this repo, decides the outcome, so **no shell construct can
fool it**.

**Two controls make it falsifiable**, and both are in-suite:

- a **positive** control — the same command with *passing* stubs must exit 0 (otherwise the assertion
  could pass because of a missing binary, a `cd` into a non-existent directory, or some unrelated
  early failure);
- a **negative** control — the same command with its failure guard moved inside `if false; then … fi`
  must make the assertion go RED (otherwise it is a formality).

**The bound, stated exactly** (the module header is authoritative): the assertion proves that *on this
machine, with this shell, with `node` replaced by a stub that always exits 1, the committed body makes
the step exit non-zero*. It does **not** prove that the real suites run, that they pass, that the
command still contains this suite's invocation, or that the step fails on GitHub's runner. It gives
**no per-suite attribution**: every suite fails under the stub, so a command that dropped only the
pin-suite line still exits non-zero while the others fail (caught by the content lock — a byte
changed — not by this assertion).

**Item 6 is per-PR / post-merge only, and PR-editable.** It has to EXECUTE the command, so it can
only live in the suite, which runs from the PR-editable `ci.yml` (and post-merge via `ci-main.yml`).
The trusted `--head-ref` leg must never run it — executing PR content under `pull_request_target` is
the RCE vector — so the trusted leg makes **no claim at all** about `ci-main.yml`'s shell. Item 6's
shell guarantee therefore sits at exactly the same trust level as the lock: PR-editable code,
conspicuous in the diff, worth nothing against a PR that edits the checker.

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
checked first and any workflow entry that is not a regular blob (`100644`/`100755`) is rejected before
content is read), decoding base64
and failing closed on anything else. Misusing this trigger is a known RCE vector; the header cites
GitHub Security Lab's `pull_request_target` guidance. No `secrets: inherit`; no secret reference
(`github.token` with `contents: read` is the only credential).

### 6. `--head-ref <sha>` mode on `scripts/check-pi-pin-lockstep.mjs` — NEW

- Fetches the recursive git TREE at that ref via
  `gh api "repos/{owner}/{repo}/git/trees/<sha>?recursive=1"`, rejects any of the three workflow paths
  whose committed git `mode` is not a **regular blob** — `100644` or `100755` (a symlink `120000` or
  submodule `160000` is a broken workflow entry that runs 0 jobs, while the Contents API would
  dereference it; the executable bit is irrelevant to GitHub's workflow loader, so `100755` is
  accepted rather than made a green-locally / red-in-CI trap) — then fetches each
  remaining path's BLOB by its **tree sha** (`repos/{owner}/{repo}/git/blobs/<sha>`) so the bytes
  parsed are the committed ones and never a dereference.
- Decodes the blob base64, **fail-closed**: only `encoding: "base64"` is accepted (the API returns
  `encoding: "none"` with empty content for a >1 MB blob) and the decode is fatal on invalid UTF-8, so
  a padded or damaged read cannot masquerade as an empty workflow.
- Runs **only the narrow STRUCTURAL assertions** — items 1–5 plus item 6a (the ci-main.yml pin-gate
  job and its `with:` keys), all value assertions. It does **not** run item 6b (the behavioural
  assertion) and makes **no claim** about `ci-main.yml`'s shell; see §4.
- **Skips the content lock** — otherwise every legitimate workflow change would deadlock against
  `main`'s old lock. This leg therefore provides **zero lock enforcement**; see the authoritative
  trust-split statement in the module header of `scripts/check-pi-pin-lockstep.mjs`.
- `--repo <owner/name>` overrides the repo (else it is derived from `git remote get-url origin`).

## What changed

| File | Change |
|---|---|
| `scripts/check-workflow-lock.mjs` | **NEW** — byte-level content lock; `hashLockedFiles`/`lockFindings` exports; `--update-lock`/`--root` CLI. No YAML parsing, no shell modelling. |
| `scripts/workflow-lock.json` | **NEW** — `version: 1` + sha256 for exactly the three pin-gate workflow paths. |
| `scripts/check-pi-pin-lockstep.mjs` | Execution-semantics modelling deleted (see §Deleted); narrow `wiringFindings` (items 1–5) + ci-main.yml's pin-gate job/`with:` shape kept as value assertions; content-lock section + `--head-ref` mode added. **Third cycle:** item 6's POSIX-shell scanner deleted and replaced by a behavioural test that EXECUTES the committed `test-command`; exit handler registered first and made fail-closed; failure decision made terminal; `100755` accepted on the trusted leg. |
| `.github/workflows/workflow-lock.yml` | **NEW** — `pull_request_target` base-branch checker with the security header. **Third cycle:** header updated — trusted leg = structural value assertions only, `100644` **or** `100755`, and an explicit statement that it makes no claim about `ci-main.yml`'s shell. |
| `scripts/check-workflow-lock.mjs` | **NEW** — byte-level content lock. **Third cycle:** ancestor-symlink walk (`symlinkedAncestor`/`symlinkFinding`), `/\\.ya?ml$/` workflow enumeration, and `--update-lock` refuses to hash through a symlinked locked path. |
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
49 to 79 lines — the item-6 control-flow rejections added there — **and was then deleted entirely in
the third cycle** (see §"#666 third revision"), along with `shellControlContext`, `stripShellQuotes`,
`stripShellComment`, `shellSwallowFinding`, `SHELL_TOKEN_RE`, `FAILURE_GUARD_OPEN_RE`,
`FAILURE_GUARD_CLOSE_RE`, `NONZERO_EXIT_RE`, `POST_MERGE_INVOCATION_RE`, `ACCUMULATOR_SUFFIX_RE`,
`POST_MERGE_INVOCATION` and every fixture that drove them (14 `item 6 RED #N` cases, 2 `item 6 GREEN`
cases and the 9 earlier item-6 fixtures).

## Testing strategy

**Fresh run, 2026-09-12 (third revision, #666 behavioural item 6) — every count below is copied from that run, not hand-maintained.**

| Surface | Layer | Command | Result |
|---|---|---|---|
| `(h)` pins | unit + negative + **positive control** | `node scripts/check-pi-pin-lockstep.mjs` | ✅ (2 tests; `pinFindings(wrongPin)` non-empty) |
| `(i)` mirror stamps | unit + negative + **positive control** + #779 prose fixture | same | ✅ (3 tests; `stampFindings(stale)` non-empty; the four prose lines stay empty) |
| narrow wiring guard (items 1–5 + 6a) | unit | same | ✅ live trio + 1 fixture-trio baseline + 1 empty/comments-only RED + 11 `expectWired` + 18 `expectRed` + 7 ci-main-structural cases |
| item 6b (behavioural) | e2e (real `bash -e`) | same | ✅ live failing-stub → non-zero; passing-stub → 0; 6 mutation fixtures (4 RED, 1 no-false-RED, 1 harness control) |
| content lock | unit + CLI | same + `node scripts/check-workflow-lock.mjs` | ✅ lock lifecycle/schema/coverage + symlink (file, ancestor dir, `.yaml`) + `--update-lock` refusal |
| `--head-ref` mode | unit + e2e | same | ✅ runs the structural assertions; never the lock; never item 6b; git-tree mode rejection (`120000`/`040000`/`160000`) and `100755` acceptance; blob-decode fail-closed |
| `(h)`/`(i)`/`(j)` + lock + reader | integration | `node scripts/check-pi-pin-lockstep.mjs` | ✅ **105 passed, 0 failed** |
| #254 frontmatter validator | integration | `node scripts/check-skill-lint.test.mjs` | ✅ **160 passed, 0 failed** |
| validator oracle (pi parity + fuzz) | integration | `node --test scripts/check-skill-lint.oracle.test.mjs` | ✅ **146 passed, 0 failed** |
| ci-ref pin-drift unit tests | integration | `node scripts/ci-ref-check.test.mjs` | ✅ **183 passed, 0 failed** |
| workflow YAML validity | static | `bash scripts/check-workflow-actionlint.sh` | ✅ exit 0 |
| content lock vs independent hashes | static | `node scripts/check-workflow-lock.mjs` + `shasum -a 256` | ✅ lock green; the three `shasum -a 256` digests match `workflow-lock.json` byte-for-byte; `--update-lock` rewrites byte-identically (idempotent) |
| trusted leg against the live API | e2e | `node scripts/check-pi-pin-lockstep.mjs --head-ref d5e876e… --repo daniel-ospina/agent-infra` | ✅ exit 0 (real git tree + blobs; lock skipped by design) |

**Runtime bound (measured, not claimed):** `node scripts/check-pi-pin-lockstep.mjs` runs in ~48 s on
the 2026-09-12 dev box (it was ~11 s at `d5e876e`). The increase is item 6b's shell round-trips
(6 real `bash -e` runs, ~1.5 s each here because each uses a freshly created temp dir) plus the
sticky-failure fixture, which runs a complete copy of the suite. The ci.yml comment that describes the
per-PR pin gate as "~4s of work" therefore no longer holds; it is left untouched in this PR because
`ci.yml` is a locked file and the comment is not part of the guard's contract.

**Case census (third revision, counted from the file and the run):** 105 tests = 72 plain `test()` +
11 `expectWired` + 18 `expectRed` + 4 `expectLockRedForEdit`. The run also asserts a set of REQUIRED
TEST NAMES (52 entries), so a deleted or renamed assertion is RED regardless of the total; it does NOT
catch a required test whose BODY is replaced by a same-name no-op — a same-commit residual recorded
below.

### Third-cycle count deltas (before → after, this PR)

| Surface | Before (`d5e876e`) | After |
|---|---|---|
| `node scripts/check-pi-pin-lockstep.mjs` | 109 passed, 0 failed | **105 passed, 0 failed** |
| plain `test()` / `expectWired` / `expectRed` / `expectLockRedForEdit` | 76 / 11 / 18 / 4 | 72 / 11 / 18 / 4 |
| item-6 fixtures | 25 (`item 6 RED #1–#14`, 2 `item 6 GREEN`, 9 earlier item-6 cases) | 0 — replaced by 7 behavioural cases |
| `MIN_EXPECTED_PASSING` | 109 | 105 |
| `REQUIRED_TESTS` entries | 51 | 52 |
| deleted symbols (`shellControlContext`, `stripShellQuotes`, `stripShellComment`, `shellSwallowFinding`, `SHELL_TOKEN_RE`, the 3 `FAILURE_GUARD_*`/`NONZERO_EXIT_RE` regexes, `POST_MERGE_INVOCATION*`, `ACCUMULATOR_SUFFIX_RE`, `ciMainFindings`) | present | **0 references in the module** (one comment names `ciMainFindings` to explain the removal) |

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
| 13 | item 6, guard inside `if false; then … fi` | ✅ GREEN (scanner returned `[]`) | ❌ **RED** — item 6b: the command exits 0, assertion fails |
| 14 | item 6, guard inside a never-called shell function | ✅ GREEN (scanner returned `[]`) | ❌ **RED** |
| 15 | item 6, guard buried in `if false; then cat <<EOF` | ✅ GREEN (scanner returned `[]`) | ❌ **RED** |
| 16 | item 6, invocation inside a multi-line quoted string | ✅ GREEN (scanner returned `[]`) | ❌ **RED** on the single-suite fixture (the LIVE file stays green because another suite fails first — stated in the fixture's comment) |
| 17 | item 6, `echo "a <<x"` (phantom heredoc) | ❌ **false RED** on `d5e876e` | ✅ **GREEN** — no heredoc modelling remains |
| 18 | trusted leg, tree mode `100755` | ❌ RED (false) | ✅ **GREEN** — accepted as a regular blob |
| 19 | trusted leg, tree modes `040000` / `160000` | ❌ RED (true but untested) | ❌ **RED**, both, with the mode named |
| 20 | `.github/workflows` is a symlinked directory | ✅ GREEN (`[]`) | ❌ **RED** — `symlinkedAncestor` walks to `.github/workflows` |
| 21 | `.github/workflows/evil.yaml` (and a symlink to it) | ✅ GREEN (`[]`) | ❌ **RED**, both |
| 22 | `process.exit(0)` at the top of the module body | ❌ exit 0 (fail-open) | ❌ **exit 1** — the early handler catches it |
| 23 | failing run + `process.on("exit", () => { process.exitCode = 0; })` at EOF | ❌ exit 0 while printing `SOME TESTS FAILED` | ❌ **exit 1**, summary still printed |
| 24 | uncaught `throw` inside the `exit` handler with `process.exit(0)` pending | ❌ exit 0 (the brief's assumed safe direction is false) | ❌ **exit 1** — the catch sets `process.exitCode = 1` |
| 25 | `--update-lock` with a symlinked locked path | ❌ exit 0 + `✅ workflow lock updated`, next verify RED | ❌ **exit 1**, `❌ refusing to re-lock`, no banner |

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

> **Superseded in part by the third revision below.** P1-1, P2-3 and P2-7 (and the item-6 half of
> P1-2) were all fixes to `shellControlContext`, the POSIX-shell scanner. That scanner was **deleted**
> in the third cycle because a fifth round found yet another bypass inside it. The rows are kept as the
> historical record of why the modelling was abandoned.

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

## #666 third revision (2026-09-12) — item 6 becomes behavioural

A fifth review round found three more P1s **inside the same `shellControlContext` function**, and
round 4's fix had itself introduced a fail-open. Five rounds of evidence now support one conclusion:
**hand-modelling POSIX shell with a lexical scanner does not converge** — every correction creates or
reveals another construct. So the modelling was deleted and replaced by execution.

Each defect below was reproduced with a command against `d5e876e` before the fix, and each fix was
verified by running the named command against the fixed tree.

| # | Defect (reproduced on `d5e876e`) | Fix |
|---|---|---|
| P1 | Item 6's guarantee was unattainable by construction: five shapes left the gate dead while the scanner returned `[]` — the failure guard inside `if false; then … fi`, the guard inside a never-called shell function, the invocation swallowed by a multi-line quoted string, `if false; then cat <<EOF` hiding the guard's `if`, and (a false RED, the other direction) `echo "a <<x"` arming a phantom heredoc. Measured on `d5e876e`: `ciMainFindings()` → `[]` for the first four, and one `sits inside a heredoc` finding for the fifth | `shellControlContext`, `stripShellQuotes`, `stripShellComment`, `shellSwallowFinding`, `SHELL_TOKEN_RE`, `FAILURE_GUARD_OPEN_RE`/`_CLOSE_RE`, `NONZERO_EXIT_RE`, `POST_MERGE_INVOCATION_RE`, `ACCUMULATOR_SUFFIX_RE`, `POST_MERGE_INVOCATION` and `ciMainFindings` DELETED, with all 25 item-6 fixtures. Item 6 is now the behavioural assertion described in §4 (execute the committed command under `bash -e` with failing stubs; assert non-zero), with a positive control, a negative control and one fixture per defeated shape. The trusted `--head-ref` leg no longer examines `ci-main.yml`'s shell at all |
| P2 | A symlinked `.github/workflows` **directory** was not caught: `readdirSync` follows it and `lstat` only refused to follow the last component. Reproduced: `.github/workflows` → `real-workflows` gave `workflowCoverageFindings()` → `[]` and `lockFindings()` → `[]` | `symlinkedAncestor()` walks (and `lstat`s) every component from the repo root down to the file's parent; `symlinkFinding()` shares it between `lockFindings` and `workflowCoverageFindings`, and the workflows directory itself is checked |
| P2 | `.yaml` workflows were invisible: `readdirSync(...).filter((n) => n.endsWith(".yml"))`. Reproduced: adding `.github/workflows/evil.yaml`, and symlinking to it, both gave `[]` | `/\\.ya?ml$/` in `check-workflow-lock.mjs` and in the reader-corpus test; RED fixtures for both the unclassified `.yaml` and the symlinked `.yaml` |
| P2 | Mode `100755` was a green-locally / red-in-CI trap on the trusted leg. Reproduced: the local legs are GREEN under `chmod +x`, and `--head-ref` with tree mode `100755` exits 1 | `TREE_MODES_REGULAR_FILE = ["100644", "100755"]`; `040000`/`160000`/`120000`/anything else stay RED. Re-pointed fixture + a `040000`/`160000` RED fixture |
| P2 | The `exit` handler was registered ~19% into the module. Reproduced: `process.exit(0)` above `FAILURE_GUARD_OPEN_RE` (module line ~179) exits 0 with the floor and roster never evaluated | The handler is registered as early as the module legally can — immediately after the `--head-ref` flag is computed and before every other module-level binding — and the anti-early-exit fixture now injects at **both** the top of the module body and mid-suite |
| P2 | **The brief's suggested fail-closed direction was wrong and was measured.** "Register the handler early; a TDZ throw inside it still exits non-zero" is FALSE: with `process.exit(0)` pending, an *uncaught* exception in an `exit` listener leaves the exit code at **0** (measured on Node v22.23.1; a `throw` in a handler for a *natural* exit does give 1, which is what makes the claim look true) | `finalize()` is called inside a `try`/`catch` that sets `process.exitCode = 1` and prints why. The catch is load-bearing; an uncaught TDZ throw is a fail-open |
| P2 | The failure decision was not sticky: `finalize()` ran eagerly at EOF and set `process.exitCode = 1`, but `process.exitCode` is last-writer-wins across `exit` listeners. Reproduced: a failing run + `process.on("exit", () => { process.exitCode = 0; })` appended at EOF → exit 0 while still printing `❌ SOME TESTS FAILED` | The EOF decision is terminal: `finalize(); if (failed > 0) process.exit(1);`. A fixture appends exactly that listener to a full suite copy and asserts exit 1 **and** that the summary still reaches stdout/stderr (guarding against `process.exit` truncation) |
| P2 | `--update-lock` was self-inconsistent on a symlinked locked file: it hashed the link target, printed `✅ workflow lock updated`, and the next verify run was RED. Reproduced: exit 0 + banner, then verify exit 1 | `--update-lock` refuses first (same `symlinkFinding` rejection), prints `❌ refusing to re-lock …`, exits 1, prints no banner |

**What the trusted `--head-ref` leg no longer does (stated plainly).** It asserts the *structural* wiring
of `ci.yml`/`node-ci.yml` (items 1–5) and, for `ci-main.yml`, only that the pin-gate job exists and
declares the expected `with:` keys with a non-empty `test-command` (item 6a). It runs **no** shell
check on `ci-main.yml`, and it does not replace item 6b. Item 6's shell guarantee is therefore per-PR /
post-merge only, **enforced by PR-editable code** — the same trust level as the lock.

**What item 6 no longer asserts (stated plainly).** The deleted scanner also asserted that the
post-merge command still *contains* this suite's invocation in the exact accumulator form. That is gone.
The behavioural assertion cannot replace it: under the failing stub **every** suite fails, so a command
that dropped only the pin-suite line still exits non-zero. Deleting that line is caught by the content
lock (the byte changed), not by item 6. This is a real reduction in the local leg's coverage and is
recorded here rather than papered over.

## Accepted residual (recorded, not papered over)

- **A required test whose BODY is replaced by a same-name no-op is not caught (#675 P2-5).** The
  roster records test NAMES, not semantics: `test("<required name>", () => assert.ok(true))` passes and
  the suite stays green (`node scripts/check-pi-pin-lockstep.mjs` → `105 passed, 0 failed`, exit 0,
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
- **Item 6 is a bounded BEHAVIOURAL check — it proves the command can fail, not that it works.** It
  runs the committed `test-command` under `bash -e` with this repo's interpreters replaced by stubs
  that exit 1, and asserts the step exits non-zero. It proves, on this machine and this shell, that the
  committed body fails the step. It does NOT prove that the real suites run or pass, that the command
  still contains this suite's invocation, that the step fails on GitHub's runner, or anything about
  per-suite attribution (under failing stubs every suite fails, so a command that dropped only the
  pin-suite line still exits non-zero — the content lock, not item 6, catches that). The module header
  is the authoritative statement.
- **Item 6 is per-PR / post-merge only, and PR-editable.** It must execute the command, so it cannot
  run under `pull_request_target` (executing PR content there is the RCE vector). The trusted
  `--head-ref` leg therefore makes no shell claim about `ci-main.yml` at all; item 6's shell guarantee
  sits at the same trust level as the lock.
- **The behavioural item 6 costs wall-clock time.** The suite went from ~11 s at `d5e876e` to ~48 s
  now: six real `bash -e` round-trips plus one fixture that copies and re-runs the whole suite. Stubbing
  out the shell instead would restore the old speed and the old guessing; the cost is accepted. The
  stale "~4s of work" comment in `ci.yml` is out of scope here (locked file, not part of the contract).
- **An ancestor symlink above the repo root is not walked.** `symlinkedAncestor` starts at the repo
  root and deliberately does not `lstat` it or any directory above it, because `/tmp` itself is a
  symlink on macOS and walking to `/` would make every fixture RED. A symlink in the repo's own path
  prefix is therefore not detected; a symlink at or below the root — including `.github` and
  `.github/workflows` — is.
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
  The **third revision replaced the 25 shell-scanner item-6 fixtures with 7 behavioural ones** (above)
  and added 2 tree-mode, 3 symlink/`.yaml`, and 1 `--update-lock`-refusal fixtures, in-suite; its
  live-file mutation round is §Verification plan #13–25.
- **positive controls** — `(h)`/`(i)` carry their explicit predicate positive controls (#675 P1-3);
  every one of items 1–6 has a failing fixture and a passing fixture; `lockFindings` now has one
  positive control per schema branch (#675 P2-e); **item 6b has an explicit positive control** (the
  same command with passing stubs must exit 0) and an explicit negative control (the guard moved into
  `if false … fi` must go RED).
- **`MIN_EXPECTED_PASSING` floor** — 71 → 91 → 109 → **105** (third revision: the 25 shell-scanner
  fixtures were deleted and 21 fixtures added; the #675 second review-fix cycle had added 18), and it is
  now a SECONDARY signal: the run also asserts a set of required test NAMES (#675 P2-c), so deleting or
  renaming a real test is RED even when the count is unchanged.
  The floor and the roster are evaluated in a `process.on("exit", …)` handler (#675 P2-h), so an early
  `process.exit(0)` cannot skip them — and since the third revision that handler is registered at the
  top of the module, the decision it takes is terminal (`process.exit(1)`), and an uncaught throw inside
  it fails closed rather than open.

## Out of Scope

| Item | Owner / disposition |
|---|---|
| Making the checker a required status check (branch protection) | **#646/#673** — the workflow exists; making it *required* is a branch-protection change needing human sign-off. |
| A separate CI check context for pin drift | **#673** |
| The `@main`-at-PR-time input-resolution seam | accepted, time-limited bound (#637 plan) |
| A nested/root `package.json` walk for extension pins | **#643** |
| Version-specific line refs in the mirror surfaces | **#651** |
| General YAML features outside the reader subset (folding/chomping, multi-line plain scalars, anchors/aliases/tags, merge keys, multi-doc) | documented reader bound; the reader throws rather than guesses |
| Refreshing the now-stale "~4s of work" comment in `ci.yml` | blocked by design — `ci.yml` is a locked file; a comment edit would require an `--update-lock` commit of its own. Not part of the guard's contract |
| Executing the committed command under `pull_request_target` | rejected on security grounds (RCE vector) and recorded as the reason item 6b is local-leg-only |
| Walking symlinks **above** the repo root | deliberate; `/tmp` is a symlink on macOS, so walking to `/` would make every fixture RED |
