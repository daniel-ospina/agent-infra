---
title: "#389 — drift-check FAIL on inline generic test jobs — Scoping Plan (rev 5 — interleaved preprocessing pipeline)"
type: engineering
domain: operations
doc_status: draft
subjects.team: organisation-design-team
created: 2026-08-31
aboutSubjects: ci-ref-check.cjs, bin/agent-infra.js, drift-check.yml, manifest.json, node-ci.yml
aboutObjects: agent-infra, tortoise, premise-labs, eldato-outreach, issue-389, issue-403
---

# #389 Implementation Plan — inline generic test jobs fail drift-check

> Source: issue-scoping (v5.1 double diamond + verify gates) — 2026-08-31
> Issue: https://github.com/daniel-ospina/agent-infra/issues/389 | Prior art: docs/scoping/2026-08-30-issue-387-ci-centralization-plan.md | Follow-on: #403 (pytest dir-suite extension)

**Team:** organisation-design-team
**Level:** task | **Complexity:** standard | **Depends on:** #387 (merged — capability + exemption lift live)

## Confirmed problem

After #387, a consumer repo CAN call the reusable unit-test capability (`node-ci.yml` unit-test job with `test-glob`/`test-command` inputs) and tortoise's inline `dashboard-js-tests` job is migrated. **Nothing prevents regression**: the drift-check gate (`agent-infra check --ci`, live on tortoise + premise-labs post-#387) checks pins, symlinks, version drift — but has NO rule against re-introducing a bespoke inline generic test job. Violating population ~1 today; the #387 research (DevOpsNess 60-PR problem) documents WHY agents hand-roll inline jobs (tag-bump ceremony). This issue ships the prevention rule.

**The rule:** a consumer workflow file (any YAML under `.github/workflows/`) carrying an **inline generic test job** — a job whose run steps invoke `node --test` / `vitest` / `npx tsx --test` **suite runners** over a static source glob/directory — FAILS drift-check with remediation naming `node-ci.yml@<manifest.ci.ref>` (the ref `_checkCI` actually passes; the #387 sync guard guarantees `check.ci.ref` equality).

**Boundary (the hard part):** repo-specific gates are NOT generic and MUST NOT trip: file-specific runs, migration guards, pricing parity, client-build (artifact-test suites), e2e harnesses, packaging smokes, service-container jobs, matrix/container jobs, dynamic-target (`${{ }}`/`$VAR`) runs, changed-files loops, reusable calls.

### Problem diamond (diverge → converge)

Framings explored: (1) original "checker rule + pattern set" — valid root cause; (2) manifest allowlist — rejected (manifest becomes CI-design authority + approval bottleneck); (3) block ALL inline test jobs — rejected (kills repo-specific gates; violates locked D4 "repo-specific stays LOCAL"); (4) **capability-expressibility test (converged)** — a job is generic iff its test step is a suite invocation the `node-ci.yml` unit-test job can express (`test-glob` → `node --test <glob>`, `test-command` → arbitrary plain shell) AND the job carries no repo-specific structure. Falsification: exemplar shape must flag; every live repo-specific tortoise job must not.

## Solution approaches

- **A. Minimal YAML job model in ci-ref-check.cjs (zero-dep indentation-aware parser) + precise pattern set + segment-level suite classification.** **Chosen.**
- **B. js-yaml full model.** Rejected: breaks zero-dep scripts/ convention; indentation suffices; vendored dep = new supply-chain surface.
- **C. External linter.** Rejected: actionlint (#398) already covers YAML syntax; the rule is semantic (knows the #387 capability contract) — belongs in the drift checker.
- **D. Pure line-regex over `run:` lines.** Rejected: cannot express job-vs-step `uses:`, services/strategy/container suppression, or segment-level guards — the fragile heuristic the issue forbids.

## File-by-file plan

### `scripts/ci-ref-check.cjs` — the rule (zero new deps)

**Parser (`parseWorkflowJobs`)** — indentation-aware, scalar-state tracked:
- `jobs:` (top-level) → job blocks (indent-2 keys). Comment lines and `---` skipped.
- **Scalar opacity:** any `key: |` / `key: >` (incl. `|-`/`>-`) block is opaque *command/script text* — its content lines are consumed by scalar state and NEVER re-parsed for `jobs:`/`steps:`/`run:` structure. Scalar termination per YAML: content indent = FIRST content line's indent; blank lines inside a scalar do NOT terminate; the scalar ends at the first non-blank line with indent < content indent. Content dedented to content-relative indentation; `>` blocks fold-joined with spaces.
- **Step-scoped run-key resolution:** `run:` is read only as a sub-key of the current step item (`- run:` or `run:` under `- name:`/`- uses:`), never a bare key inside a `uses:` action's `with:` block.
- Known non-targets: flow-style `jobs: {...}` maps, YAML anchors/aliases (`&x`/`*x`) — line parser doesn't resolve them (documented limitation, negative-tested).

**Segment classifier (`matchGenericSuite(command)`)** → `null | { pattern, command }`.

**Interleaved preprocessing pipeline (the exact order, implemented as one fixpoint pass):**

1. **Heredoc span detection on RAW lines (first):** scan for `<<[-]?['"]?TERM` openers — **quote-aware** (a `<<` inside an unclosed quote string is not an opener; a `<<` preceded on the same line by an unquoted `#` is a comment, not an opener). A span = opener line through the first line matching `^[ \t]*TERM[ \t]*$` (bash semantics: `<<-` tolerates leading tabs only; trailing blanks on the terminator line are tolerated by the checker for robustness — a deliberate trade-off, documented). **Unterminated opener → NOT a heredoc** (opener line treated as plain command text — bash itself would fail such a script; the checker must not cascade-swallow the rest of the command). Opener regex must allow flags between a shell interpreter and `<<` (`bash -s <<`, `bash -e <<`, `sh -eu <<`).
2. **Opaque-span replacement:** each heredoc span is replaced with a single neutral placeholder token (`__HEREDOC_N__`). Executed-heredoc classification happens HERE: if the heredoc is fed to a shell interpreter (`bash|sh|zsh|ksh`, flag-tolerant, i.e. `bash\s+(?:-[a-zA-Z]+\s+)*<<`) OR piped into one (`<cmd> <<'EOF' | bash`) → the dedented body is retained as a SEPARATE command string and classified through the **same recursive pipeline** (heredoc detection INCLUDED — a writing heredoc inside an executed body is opaque; a nested executed heredoc is classified). Writing heredocs (`cat > file <<`, `tee file <<` — no shell receiver) → body fully opaque, dropped.
3. **Line-continuation join** (`\` + newline → space) — applied ONLY outside heredoc spans (spans are already placeholder-replaced).
4. **Comment stripping (quote-aware + `$(`-depth-aware):** `#` starts a comment only when unquoted at a word boundary (single/double-quote state AND `$(`-substitution depth tracked). `echo 'a # b'`, `git commit -m "closes #42"`, `echo $(echo '# x')` all preserve content.
5. **Segment split** at newlines (post-continuation-join — the dominant multi-line `run: |` shape is `npm ci\nnode --test tests/`), `;` `&&` `||` `|` `&` boundaries — quote-opaque, `$(`-depth-opaque, and `[0-9]?>&?[0-9]?` redirects (`2>&1`, `>&`) opaque (not split).
6. **Per-segment-head wrapper + shell-control strip (fixpoint until stable, token-stream with quote state):** leading `VAR=value` tokens (bare form AND `env VAR=…` chains — `NODE_OPTIONS=… node --test src/` skips the prefix and reaches the runner); `set -e;`/`set -o pipefail;`/`set -x;`/`set +e;`/`set -u;`/`set -euo pipefail;` chains; `bash -c "…"`/`sh -c '…'` (flag-tolerant: `bash -lc`, `bash -e -c`) — **the inner content is extracted and re-run through the FULL pipeline recursively** (comment strip → segment split → head strip → classify), so `bash -c "npm ci && node --test tests/"` and `bash -c "cd tests && node --test ."` reach the suite; `timeout`/`gtimeout <n>` with GNU suffix `<n> = [0-9]+[smhd]?` (BEFORE the `time` word strip — `timeout 300 …` must not become `out 300 …`); `env` command form; `sudo -E`; `nohup`; `nice`; `stdbuf`; single-command subshell parens `( … )`; shell-control words `if|elif|else|then|fi|do|done|case|esac|in` (exact word-boundary, leading-only) + `!` + `time` + `exec`; **`case <expr> in` consumed as a unit** (bounded regex `case\b[^;{}]*?\bin\b`, subject included, quote-safe; a `;` INSIDE the case expression — `case $(a; b) in` — is a documented miss, negative-tested) + case labels (`a)`, not followed by `(`).

*Per surviving segment:*

- **Primary-target rule (shared):** the suite's *target* = the first token after the runner (for node/tsx: after `--test`; for vitest: after the subcommand) that is neither a leading-`-` flag nor the value of a **per-runner value-taking flag**:
  - node/tsx: `--import`, `--loader`, `-r`, `--env-file`, `--test-name-pattern`, `--test-reporter`, `--test-reporter-destination`, `--test-shard`, `--test-concurrency`, `--test-timeout`, `--test-isolation`, `--test-skip-pattern`, `--test-coverage-lines|branches|functions|statements`.
  - vitest: `-t`, `--testNamePattern`, `-c`, `--config`, `-r`, `--root`, `--dir`, `--environment`, `--pool`, `--include`, `--exclude`.
  - `--flag=value` forms are single tokens. Value-taking flags apply to BOTH the runner-detection pass and target extraction.
- **Dynamic-target exemption:** iff the primary target token CONTAINS `${{`, `$(`, `$VAR`, `${VAR}` (incl. `${VAR:-def}`, `$@`, `$1`) → **neutral**. Dynamics in flag values / env prefixes / secondary positionals do NOT exempt (`node --test src/*.test.js --env ${{ inputs.env }}` → suite). Keeps node-ci.yml's own `node --test ${{ inputs.test-glob }}` exempt.
- **Target classes (node/tsx/vitest, evaluated in this order):** (1) **artifact-output path** — ANY path segment is `dist|build|out|.next` (leading `./` normalized, `..` collapsed) → **neutral** (client-build class — name-keyed boundary, NOT expressibility: test-command could express build+test; the exclusion is the issue-named client-build precision choice); (2) concrete file (`.js/.mjs/.cjs/.ts/.mts/.cts/.jsx/.tsx` ending) → file-specific → neutral; (3) glob (`*?[`) → suite; (4) directory (no source ext) / bare → suite. First-target-wins: `node --test a.test.js tests/` and `node --test dist/ tests/` → neutral (documented semantics).
- **Runner detection:**
  - **node --test:** after skipping the leading runner token (`node`), suite mode iff exact token `--test` appears before the first non-flag non-value token; flags/loaders between `node` and `--test` tolerated (`node --experimental-strip-types --test tests/`, `node --import tsx --test tests/`, `node --env-file .env --test tests/`). `--test-reporter` etc. are distinct flag tokens — exact `--test` equality. `--help`/`--version` with NO primary target → probe → neutral (`node --test --help`); with a target → suite (`node --test tests/ --help`).
  - **vitest:** first token `vitest` or runner prefix `npx|yarn|pnpm|bun|bunx|npm exec` + optional flags/subcommands between (`npx --yes vitest run`, `yarn workspace x vitest`) + `vitest`. Subcommand tokens consumed before target extraction: `run`, `watch`, `related`, `bench` (`npx vitest run tests/single.test.ts` → target `tests/single.test.ts` → file-specific → neutral). `--version` → probe → neutral.
  - **npx tsx --test / bare `tsx --test`:** exact `--test` before first non-flag non-value token → suite (target classes as node). `npx tsx scripts/build.ts --test` (flag after script path) → neutral.
- **Loop suites — COMMAND-START-ANCHORED (resolves the 12-pin contradiction):** loop detection applies only when the full pre-split, post-heredoc-replacement command STARTS with `for`/`while`. An anchored loop is an atomic unit classified wholly by the loop rule: iterable/src is STATIC test-looking (`tests?/` | `__tests__` | `.test.` | `.spec.` — substring match wins, so `*.test.js` qualifies; bare `*?` globs alone do NOT qualify) AND artifact-free (any `dist|build|out|.next` segment → neutral, consistent with the direct form) AND the loop body contains a suite-runner invocation **reusing the full runner classification** (help/version neutrality, flag lists, exact `--test`; **target dynamics in the body are IGNORED** — the iterable's staticness IS the dynamic decision, so `node --test "$f"` in a static-iterable loop is a suite) → SUITE. Any other anchored loop (dynamic iterable `$(…)`/`${{ }}`/`$VAR`/`git diff`, bare glob, artifact, non-test iterable, non-suite body) → the whole span is opaque neutral. **Loops NOT at command start (embedded after `&&`/`;`/newline — e.g. `npm ci && for …`) are NOT loop constructs:** ordinary text — `do`/`done` stripped per segment, body per-segment classified, so a static suite inside an embedded loop flags (`npm ci && for f in $DIRS; do node --test tests/; done` → 1). Documented miss: an embedded loop whose body target is the loop var (`cd x && for f in tests/*.test.js; do node --test "$f"; done` → `$f` dynamic per-segment → miss). Executed-heredoc bodies inside an anchored loop: their suite verdict is OR'd into the loop's body check. Body check examples: `for f in tests/*.js; do node --check "$f"; done` → 0 (body not a suite); `for f in tests/*.js; do node --test --help; done` → 0 (probe); `for f in tests/*.test.js; do (node --test "$f") & done` → 1; `for f in dist/*.test.js; do node --test "$f"; done` → 0 (artifact iterable).
- **Known misses (documented, precision-first):** `cat list | xargs node --test` (xargs indirection — dynamic-ish); shell-var target indirection (`VAR='src/*.test.js'; node --test $VAR` — a deliberate evasion; the node-ci exemption itself uses `${{ }}` which IS caught); `;` inside a case expression (`case $(a; b) in`) breaks the `case <expr> in` unit regex; embedded loops with loop-var body targets (`cd x && for f in tests/*.test.js; do node --test "$f"; done` — anchored rule misses them); a suite on the SAME line after a writing-heredoc opener (`cat > f <<'EOF' && node --test tests/` — line-based span swallows it). All negative-tested.

**Job decision (`findInlineGenericTestJobs(content)`)** → `[{ job, pattern, command }]`:
1. Skip job if job-level `uses:` (reusable call), `services:`, `strategy:`, or `container:` (capability-inexpressible structure).
2. Classify every run command → suite segments (above). **Suite-first:** a suite segment is NEVER downgraded by repo-local paths or other segments — repo-local commands are simply non-suite. A source suite after a build step (`npm run build && node --test tests/`) flags.
3. Flag iff ≥1 suite segment survives → one finding per job (the first suite segment by source order; loop findings take precedence at their span's start position).

**`checkInlineGenericJobs(targetDir, ciRef)`** → `[{ file, job, pattern, command }]` — scans ALL workflow YAML files (same discovery as `checkCiRefs`; mirrors the pin-check precedent — the disease can land in any workflow surface). Carries `ciRef` for remediation.

### `bin/agent-infra.js` — `_checkCI` wiring

After the pin-compare block (non-self, `ci.ref`-present branch): `ciRefCheck.checkInlineGenericJobs(targetDir, ci.ref)`. Findings → `{ type: 'ci-inline', tier: 'fail', reason: "inline generic test job '<job>' (<pattern>) — expressible via the reusable unit-test capability; call node-ci.yml@<ref> with test-glob/test-command instead" }` + console `❌`. Clean → `ok++` + `✅ inline test jobs — no generic dir-suite runners`. **Per-pattern remediation mapping:** `node --test <glob>` → "use test-glob"; vitest/tsx/loop → "use test-command". **Self-carve-out:** `selfRepo` branch untouched (source repo = authority, @main parallel to the pin exemption). **Old-manifest gating (documented):** consumers without `ci.ref` keep the existing "old manifest" warning and skip the inline rule (progressive rollout — the version gate already FAILs those repos); stated in the code comment. Doc comment update listing the new surface.

### `manifest.json` — exemption population decision (eldato-outreach)

Verified wiring: eldato-outreach's workflows = `ci.yml` (single `uses: daniel-ospina/shared-workflows/.github/workflows/ci.yml@v1` — a DIFFERENT workflow repo; job-level `uses:` suppressed by the rule anyway) + `deploy.yml` (pure deploy: checkout/setup-node/npm ci/npm run deploy — no test shapes). Zero agent-infra refs, drift-check NOT wired, no `.agent-infra-version`. #387 plan: "KEEP eldato-outreach (pending #389)". **Decision: LIFT** — remove `"eldato-outreach"` from `manifest.check.exemptions` (exemption inert; surface verifiably passes every check it gates). `dmer`/`dmeer`/`eldato` `scripts` exemptions untouched.

### `.github/workflows/drift-check.yml` — contract doc

FAIL-list comment: add inline generic test jobs (#389) to the structural-drift enumeration + the documented non-targets table (below).

### `scripts/ci-ref-check.test.mjs` — unit tests

New section "inline generic test jobs (#389)" — one test per spec claim:

*Must flag (suite):*
- `node --test src/*.test.js`; `node --test tests/`; `node --test ./tests/`; `node --test .`; bare `node --test`; `NODE_OPTIONS=… node --test src/` (bare env prefix); `node --experimental-strip-types --test tests/`; `node --import tsx --test tests/`; `node --env-file .env --test tests/`; `node --test > log`; `node --test tests/ > log`; `node --test tests/ --help` (target present → suite); `timeout 300 node --test tests/`; `gtimeout 300 node --test tests/`; `timeout 5m node --test tests/` (GNU suffix); `gtimeout 30s vitest run`; `time node --test tests/`; `bash -c "node --test tests/"`; `bash -lc "node --test tests/"`; `bash -c "set -e; node --test tests/"` (nested fixpoint); `bash -c "npm ci && node --test tests/"` (inner full pipeline); `bash -c "cd tests && node --test ."`; `set -e; node --test src/`; `set -euo pipefail` + suite on next line; `set +e; node --test src/ || failures=$((failures+1))`; `env A=1 node --test src/`; `sudo -E node --test tests/`; `nohup node --test tests/`; `(cd tests && node --test .)`; `if git diff --quiet; then node --test tests/; fi`; `if ! node --test tests/; then exit 1; fi`; `if node --test tests/ >/dev/null; then echo ok; fi` (suite in condition runs it); **multi-line `npm ci\nnode --test tests/`**; **multi-line `set -e\nnode --test tests/`**; `case "$RUNNER_OS" in linux) node --test tests/;; esac`; `case $PATH in *foo*) node --test tests/;; esac` (control word inside expr); `npm ci && npx vitest run`; `npm ci && node --test tests/`; `npx --yes vitest run`; `yarn workspace x vitest`; `npm exec vitest run`; bare `vitest run tests/`; `node --test src/*.test.js --env ${{ inputs.env }}` (flag-value dynamics don't exempt); `node --test tests/ 2>&1 | tee results.log` (redirect opacity); `node scripts/prepare-fixtures.mjs && node --test tests/`; loop `for f in tests/*.test.js; do node --test "$f"; done`; `for f in *.test.js; do node --test "$f"; done`; `for f in tests/*.test.js; do (node --test "$f") & done`; `while read f; do node --test "$f"; done < tests/list.txt`; `npm ci && for f in $DIRS; do node --test tests/; done` (mixed: loop neutral span, direct suite flags); `echo 'a # b' && node --test tests/`; `git commit -m "closes #42" && npx vitest run`; `node --test tests/ # trailing comment`; `echo $(echo '# x') && node --test tests/` ($(-depth-aware comments); `node --test \⏎tests/` (continuation); `node --test tests/ | tee results.log`; `node --test tests/ & wait`; `mkdir -p dist && node --test tests/` (P0 regression pin); `npm run build && node --test tests/` (source suite after build); executed heredoc `bash <<'EOF'` body containing `node --test tests/` → 1; `bash -s <<'EOF'` → 1; `bash -e <<'EOF'` → 1; `cat <<'EOF' | bash` → 1; executed-heredoc body with `#` comment lines + suite → 1; opaque heredoc with unbalanced `'` + subsequent real suite step → 1; executed-heredoc body with a nested WRITING heredoc containing suite text → 0; executed-heredoc body with a nested executed heredoc + suite → 1.

*Must NOT flag (non-suite / repo-specific):*
- file-specific: `node --experimental-strip-types tests/test_waitlist_subscribe.mjs`; `node --test tests/foo.test.mjs`; `node --test --experimental-strip-types tests/foo.test.mjs`; `node --test --test-name-pattern foo tests/foo.test.mjs`; `node --test --test-name-pattern="a b" tests/foo.test.mjs`; `node --test --test-isolation process tests/foo.test.mjs`; `npx vitest run tests/single.test.ts`; `npx vitest watch tests/single.test.ts`; `vitest run -t foo tests/single.test.ts`; `vitest run --dir . tests/single.test.ts`; `node --test a.test.js tests/`
- artifact-target: `node --test dist/`; `node --test build/`; `node --test ./dist/`; `node --test dist/*.test.js`; `node --test dist/**/*.test.js`; `node --test packages/web/dist/` (any-segment); `node --test dist/ tests/` (first-target-wins); `npm run build && node --test dist/`; `for f in dist/*.test.js; do node --test "$f"; done` (artifact iterable)
- dynamic: `node --test ${{ inputs.test-glob }}`; `node --test tests/${{ matrix.dir }}`; `node --test "${{ inputs.dir }}/tests/"`; `node --test $TEST_GLOB`; `node --test ${TEST_DIR}`; `node --test ${VAR:-default}`; `for f in $(git diff --name-only …); do node --test "$f"; done`; `while read f; do node --test "$f"; done < <(git diff …)`; `for f in $DIRS; do node --test; done` (dynamic iterable, whole span neutral); `for f in */; do (cd "$f" && node --test); done` (bare glob iterable, whole span neutral)
- probes / non-suite: `node --test-reporter=spec tests/`; `node --test --help`; `npx vitest --version`; `npx tsx scripts/build.ts --test`; `bash .github/scripts/check-migration-append-only prefix`; `uv run pytest tests/`; `npm test`; `npx jest tests/`; `echo vitest`; `echo 'node --test tests/'`; `echo then node --test tests/` (head-only strip); `echo 'a) node --test tests/'` (quote-safe label strip); `yarn workspace x build`; `exec npm run deploy`; comment `# node --test src/*.test.js`; `cat > file <<'EOF'` writing-heredoc with suite text → 0; `tee -a file <<'EOF'` → 0; `python <<'EOF'` opaque body with suite text → 0; `cat list.txt | xargs node --test` (documented miss); `for f in tests/*.js; do node --check "$f"; done` (non-suite body); `for f in tests/*.js; do node --test --help; done` (probe body); `for f in docs/*.md; do node --test --help; done`; `echo $(node --test tests/)` (documented miss)

*Workflow shapes:*
- exemplar job → 1; welcome-e2e-shaped job (file-specific node runs) → 0; migration-guard job → 0; `services:` job → 0; `strategy.matrix` job → 0; `container:` job → 0; job with repo-local prep step + generic suite step → 1; job with repo-local prep + suite in ONE command → 1; `uses:` job → 0; heredoc-YAML scaffold inside a run block → 0; heredoc with `\`-before-terminator + subsequent real suite step → 1; heredoc with indented terminator + subsequent real suite step → 1; `run: |` block with blank lines then next step → 1; step `uses:` action with `with: { run: … }` input → not a run command; folded `run: >` split (`npx`⏎`vitest run`) → 1; over-indented first content line → correct termination; flow-style `jobs: {…}` → 0; anchor/alias job → 0; terminator line with trailing blank + suite content below → pinned behavior.
- **Self-assertion:** `findInlineGenericTestJobs` over agent-infra's own `.github/workflows/*.yml` → 0 findings (expression exemption keeps node-ci.yml's `node --test ${{ inputs.test-glob }}` exempt; drift-check.yml's `node "$AGENT_INFRA_PATH/bin/agent-infra.js" …` non-suite; `bash -n` loops non-suite bodies; script-validate `node --check` loop iterable is a glob but body non-suite). **Re-verified at PR time against the final implementation.**
- Dir-level: `checkInlineGenericJobs` on a tmp repo with an inline file → 1 finding `{file, job, pattern}` + remediationRef carried.

### `tests/drift/run.sh` — fixture suite (cases 10–11)

- Case 10: write `$FIX/.github/workflows/inline-generic-test.yml` (tortoise exemplar shape) → `run_check 1 "inline generic test job (--ci)" --ci`; assert `status: FAIL` + remediation greps `node-ci.yml` + `@$REF` where **`REF` derives from `manifest.ci.ref`** (same source `_checkCI` passes). Assert the FULL remediation line (disambiguated from the fixture's docs-ci.yml pin). Write version pin in-case. rm file in-case + in `cleanup()`.
- Case 11: write `$FIX/.github/workflows/repo-specific-tests.yml` (migration-guard `bash .github/scripts/…` + file-specific `node --experimental-strip-types tests/test_waitlist_subscribe.mjs` jobs) → `run_check 0 "repo-specific inline jobs not flagged (--ci)" --ci`; assert `status: CLEAN` + `inline test jobs — no generic` line. Write version pin in-case. rm in-case + cleanup.
- Case enumeration comment updated (10/11).

## Known non-targets (documented boundary — deliberate)

| Shape | Why non-target | Mechanism |
|---|---|---|
| `npm test` / `npm run test` | package.json indirection — runner unknowable statically; flagging = the fragile heuristic Indicator 1 forbids | pattern set omits |
| jest / mocha / bun / deno | outside the #387 capability's documented input surface; precision wins per the issue's explicit list | pattern set omits |
| repo-local test-wrapper scripts (`node scripts/run-tests.mjs`) | file indirection — suite invocation unknowable statically | non-suite by default |
| shell-var target indirection (`VAR='src/*.test.js'; node --test $VAR`) | deliberate evasion — the price of not flagging legitimately dynamic targets; node-ci's self-caller uses `${{ }}` which IS caught | documented limitation + test |
| command-substitution-wrapped suite (`echo $(node --test tests/)`) | `$(`-depth opacity protects splitting, not detection — same evasion class as xargs | documented miss + test |
| **artifact-output targets (`dist|build|out|.next`, any path segment)** | issue-named client-build boundary — name-keyed precision choice (NOT expressibility: test-command could express build+test). Checked-in-`dist/` source tests are the accepted false-negative | artifact class + tests |
| pytest / `uv run pytest` dir-suites | python-ci.yml is the separate python capability (#303 D4); ~6 legitimate tortoise pytest jobs. **Tracked as follow-on #403** | pattern set omits |
| YAML flow-style `jobs: {...}`, anchors/aliases | line parser doesn't resolve them | documented limitation + negative test |

## Self-carve-out decision

The rule skips agent-infra itself (source repo) — the drift surface runs in CONSUMERS; agent-infra's own workflows are the authority (richer inline copies by design). Mirrors the locked @main pin exemption (D2). **Made load-bearing:** the unit suite asserts `findInlineGenericTestJobs` over agent-infra's own workflows → 0 findings, re-verified at PR time.

## Verification strategy (per issue checklist)

| Surface | Layer | Expected |
|---|---|---|
| rule detection | unit | inline `node --test` dir-suite → FAIL; file-specific/artifact/dynamic/services/matrix → pass |
| false-positive guard | unit | repo-specific shapes + hardening vectors (heredoc, wrappers, folded, flags, quotes, if/case, pipes) → zero flags |
| exemption population | manifest | eldato-outreach lifted (verified clean surface) |
| live surface | e2e (run.sh cases 10–11) | inline → exit 1 + remediation; repo-specific → exit 0 CLEAN |
| self-carve-out | unit assertion + PR-time re-verify | agent-infra own workflows → 0 findings |
| acceptance gate | live fetch | `findInlineGenericTestJobs` over tortoise (17) + premise-labs (1) + eldato-outreach (2) + agent-infra self (8) → zero findings |

## Scope-verify cycles

- Cycle 1: P1×3 fixed (per-step suppression; heredoc/scalar opacity; expression-target exemption).
- Cycle 2: P1×2 fixed (suppression-vs-suite precedence; same-command bypass → segment-level).
- Cycle 3: **P0 fixed** (job-level build-coupling → artifact-target suppression) + P1×5 (shell-control strip; quote-aware comments; primary-target definition; `${VAR}` forms; loop-before-split ordering).
- Cycle 4: **P0 fixed** (preprocessing pipeline self-contradiction → interleaved fixpoint: heredoc-first, opaque-span placeholder replacement, continuation-join outside spans, split-then-head-strip, `case <expr> in` unit) + P1×4 (executed-heredoc flag tolerance `bash -s <<`; pipe-to-shell heredoc `cat << | bash`; artifact `./`/glob precedence + any-segment matching; per-runner value-taking-flag lists) + P2×3 (artifact class in non-targets table; quote-aware wrapper strip; loop-body reuses full runner classification + loop-span opacity) + P3/P4 test additions (pipes/`&`/`2>&1` split tests, `mkdir -p dist` pin promoted, vitest subcommand tokens, prefix adjacency, exact-token strip matching, `--watch`, terminator trailing-blank pin, `$(`-aware comments).
- Cycle 5: **P0 fixed** (loop-rule contradiction → COMMAND-START-ANCHORED loop detection, satisfying all 12 loop pins; embedded loops are ordinary text with `do`-strip) + P1×3 (newline as a segment-split boundary — the dominant multi-line `run: |` shape; bare `VAR=value` prefix skip; `bash -c` inner content re-runs the FULL pipeline recursively) + P2×3 (executed-heredoc body = same recursive pipeline incl. heredoc detection; loop × heredoc ordering — loop detection post-heredoc-replacement with executed-heredoc verdicts OR'd in; loop iterable artifact class) + P3×4 (quote-aware heredoc opener + unterminated fallback; `timeout` GNU suffix; `;`-in-case-expr documented miss; `set -euo pipefail`) + ~15 test pins.
- Cycle 6: scope-verify converged at the 4-cycle-per-reviewer cap with all P0/P1s resolved in rev 6 — remaining items are the enumerated test pins (the executable contract), enforced mechanically by the unit suite during implementation. Plan-verify folded into the code-review gate + unit-suite contract (proportional-gates: 10 prior verifier dispatches on this document; marginal review value lies in the implemented code, not another text pass).

## Complexity

| Domain | Rating | Rationale |
|---|---|---|
| Config | standard | checker contract + rule surface, parser decision |
| Org Infra | standard | governance rule across consumer repos |
