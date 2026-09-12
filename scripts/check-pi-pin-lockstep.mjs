#!/usr/bin/env node
/**
 * check-pi-pin-lockstep.mjs — single-purpose CI suite for the #637 pi-pin
 * lockstep tripwires (h)/(i)/(j), plus the #666 narrow wiring guard and the
 * workflow content lock. Extracted from check-skill-lint.test.mjs by #666
 * (plan alternative F) so the pin guards have a home of their own.
 *
 * SCOPE — the three pin-lockstep guards and nothing else:
 *   (h) extension pi-package pins lockstep with PI_VERSION_PIN
 *   (i) hand-synced mirror version stamps match PI_VERSION_PIN
 *   (j) the pin gate is still wired into .github/workflows/ci.yml →
 *       node-ci.yml, and the post-merge pin-suite invocation line is still
 *       PRESENT in ci-main.yml's `test-command` (item 6a — a pure value
 *       assertion, run on BOTH legs). Whether that line can FAIL the step is
 *       item 6b's separate, behavioural, PR-editable claim. Item 6b's stub fails
 *       ONLY the pin suite (#807). A line that is unreachable — swallowed by a
 *       multi-line quoted string, deleted, or repointed — therefore leaves
 *       NOTHING failing, and a guard that is dead — hidden in `if false`, a
 *       never-called function or a never-taken `case` arm, or preceded by an
 *       `exit 0` — lets the step reach its success echo even though the pin
 *       suite failed. Both classes make 6b RED on the committed multi-suite
 *       file, not just on a single-suite fixture. See "WHAT 6b CATCHES".
 * The #254 frontmatter-validator suite stays in scripts/check-skill-lint.test.mjs.
 * This suite does NOT import pi (the dev-machine oracle owns pi parity).
 *
 * Run: node scripts/check-pi-pin-lockstep.mjs
 *
 * ── #666: the content lock replaced execution-semantics modelling ────────────
 * The wiring guard used to answer "will GitHub actually run the pin suite?" by
 * reading GitHub Actions EXECUTION SEMANTICS out of the YAML reader
 * (scripts/workflow-yaml.mjs) with a DENYLIST of neutralisers: `shell:`,
 * step/job/workflow `env:`, `container:`, `services:`, `runs-on:`,
 * `defaults:` (all levels), `strategy.matrix` (emptiness + `exclude`), trigger
 * filters, and block-scalar shell-body reasoning. Two review rounds found six
 * working bypasses and the second round's were created by the first round's
 * fixes. Modelling semantics was the wrong question.
 *
 * THE CONTENT LOCK IS A CONSPICUOUSNESS TRIPWIRE, NOT A PR-UNEDITABLE CONTROL.
 * scripts/check-workflow-lock.mjs hashes `.github/workflows/ci.yml`,
 * `.github/workflows/node-ci.yml` and `.github/workflows/ci-main.yml`
 * byte-for-byte against scripts/workflow-lock.json. Every bypass above requires
 * EDITING one of those files, which changes its hash — there is nothing left to
 * enumerate. But the ONLY call site of `lockFindings()` is THIS script's own
 * copy, run from the PR-EDITABLE `.github/workflows/ci.yml`, so the lock is
 * enforced by PR-editable code. Precisely:
 *   - the lock is a tripwire enforced by PR-EDITABLE code — a PR can delete or
 *     neuter that code, and then the lock is simply not checked;
 *   - the trusted leg (the `pull_request_target` workflow defined on `main`,
 *     .github/workflows/workflow-lock.yml, which runs THIS script's
 *     `--head-ref` mode) provides the VALUE ASSERTIONS ONLY (items 1–5 plus item
 *     6a — ci-main.yml's pin-gate job, its `with:` shape and its invocation
 *     line) and provides
 *     ZERO lock enforcement — it skips the lock by design, because otherwise
 *     every legitimate workflow change would deadlock against `main`'s old lock;
 *   - a PR that edits a workflow AND the lock together therefore passes both
 *     legs. That is the pre-existing accepted same-commit residual, now
 *     conspicuous in the diff (two files, one literally named a lock, and a
 *     visible hash change);
 *   - item 6b (this file's only shell guarantee) is likewise per-PR / post-merge
 *     and PR-editable. The trusted leg does not run it and does not replace it —
 *     see "ITEM 6b IS PER-PR / POST-MERGE ONLY" below.
 * THIS PARAGRAPH IS THE AUTHORITATIVE STATEMENT of the trust split. The workflow
 * header of .github/workflows/workflow-lock.yml and the plan doc reference it
 * instead of restating it, so the three claims cannot drift apart.
 *
 * THE NARROW GUARD IS THE BETTER ERROR MESSAGE. `wiringFindings` asserts six
 * DECLARATIVE facts about the agreed wiring and reasons about VALUES, not about
 * what the runner would do:
 *   (1) ci.yml has a `pull_request` trigger (any valid spelling: bare mapping
 *       key, `on: pull_request` scalar, or a flow sequence containing it — a
 *       decoy line inside a block scalar or a non-`on` mapping is not a node);
 *   (2) the `ci` job's `uses` is exactly `…/node-ci.yml@main`;
 *   (3) the `ci` job has no `if:` and no truthy `continue-on-error:`;
 *   (4) the `ci` job's `with:` key set is exactly `["test-command"]` and its
 *       value is exactly the expected accumulator command;
 *   (5) node-ci.yml still declares the `unit-test` job and the `test-command`
 *       workflow_call input;
 *   (6a) ci-main.yml still declares the `extension-tests` pin-gate job, the
 *       expected `with:` key set (one of them a non-empty `test-command`), and
 *       that `test-command` body still CONTAINS the exact pin-suite invocation
 *       line — a trimmed-line equality check against a pinned constant, on the
 *       value `scripts/workflow-yaml.mjs` parsed, never a grep of the raw file.
 *       A VALUE assertion: it runs on BOTH legs.
 * It deliberately does NOT model `shell:`, `env:`, `container:`, `services:`,
 * `runs-on:`, `defaults:`, `strategy.matrix` (including `exclude`) or trigger
 * filters — the lock covers those, and the narrow guard no longer has to guess
 * at GitHub's surface.
 *
 * ITEM 6a IS A VALUE ASSERTION; ITEM 6b IS THE BEHAVIOURAL ONE (#666, third
 * revision; 6a restored in the final review cycle; #807 changed WHAT 6b's stub
 * fails).
 * Items 1–5 assert VALUES read from parsed nodes. Item 6a does the same for
 * ci-main.yml: the pin-gate job exists with the expected `with:` keys, its
 * `test-command` is a non-empty string, and that body still CONTAINS the exact
 * pin-suite invocation line — a trimmed-line equality check against a pinned
 * constant, on the value `scripts/workflow-yaml.mjs` parsed (never a grep of the
 * raw file). Item 6b asks the question no value assertion can answer — "can the
 * committed post-merge `test-command` actually fail the step?" — and answers it
 * by EXECUTING the committed command: it parses ci-main.yml, takes the pin-gate
 * job's `test-command` body, writes it to a temp dir and runs it under `bash -e`
 * with `node`/`npx`/`npm`/`bash` replaced by stubs first on PATH. The `node` stub
 * exits 1 ONLY when its arguments name scripts/check-pi-pin-lockstep.mjs; every
 * other stubbed invocation exits 0. The assertion is that the step exits
 * NON-ZERO with ONLY the pin suite failing.
 *
 * WHY 6a STILL EXISTS ALONGSIDE 6b. 6b's stub now fails ONLY the pin suite, so
 * on the per-PR / post-merge legs a DELETED or REPOINTED invocation line leaves
 * NOTHING failing and 6b goes RED as well (#807). But 6b has to EXECUTE the
 * command, so it can never run on the trusted `pull_request_target` leg — that
 * would run PR content on a privileged trigger (the well-known RCE vector). 6a is
 * the value assertion the TRUSTED leg runs, and it is therefore the only thing
 * that sees a dropped or repointed invocation line in a PR's workflow bytes.
 * Measured on the revision before 6a was restored: with the invocation line
 * deleted from ci-main.yml the suite reports `0 failed`, exit 0, and the trusted
 * `--head-ref` leg reports ✅.
 *
 * WHY EXECUTION REPLACED THE SCANNER (6b). Four review rounds found bypasses in a
 * hand-written POSIX-shell scanner: `!`/`time` prefix operators, `select`, a
 * quoted `<<` false positive, an invocation inside a multi-line quoted string, a
 * guard inside `if false … fi` or a never-called shell function. Each correction
 * created or revealed another construct. Hand-modelling POSIX shell with a
 * lexical scanner does not converge, so 6b replaced the model with a measurement.
 *
 * WHAT 6b CATCHES, STATED NARROWLY — five review rounds each found a claim the
 * code did not support, so this is the bound the fixture evidence supports: 6b
 * catches any shell construct that makes the STEP'S EXIT STATUS depend on the
 * pin suite's stub failing — bash, not this file, decides that. Two classes are
 * covered: constructs that stop the pin-suite invocation running at all (a
 * deleted or repointed line, a multi-line quoted string around it), and
 * constructs that kill the failure guard while the invocation still fails (a
 * guard moved into a never-called function or a never-taken `case` arm, an
 * `exit 0` before the guard). It does NOT catch a command that merely keys its
 * exit status off the STUB. Reproduced and pinned: a probe that NAMES the pin
 * suite for its own sake —
 * `node scripts/check-pi-pin-lockstep.mjs --version >/dev/null 2>&1 || exit 1` —
 * followed by the guard block and NO suite invocation at all makes 6b GREEN (the
 * stub sees the pin-suite path and exits 1) while the pin gate is dead — the real
 * CI would exit 0. That shape is caught by 6a (the invocation line is absent),
 * not by 6b.
 *
 * WHAT 6b DOES AND DOES NOT PROVE:
 *   - IT PROVES: on this machine, with this shell, with the `node` stub failing
 *     ONLY the pin suite's invocation and every other stub passing, the committed
 *     `test-command` body makes the step exit non-zero. A passing run means the
 *     pin suite's failure IS observable in the step's exit status — on the
 *     committed MULTI-SUITE command as well, where every other suite passes.
 *   - IT DOES NOT PROVE: that the real suites run, that they pass, that the step
 *     fails (or passes) on GitHub's runner (different image, different bash,
 *     network, caches), or that the failing exit status came from the real pin
 *     suite rather than from the stub (see the stub-keyed shape above). It is a
 *     bound, not a proof of correctness.
 *   - PER-SUITE ATTRIBUTION IS BOUNDED BY THE STUB, NOT BY THE SUITE COUNT: the
 *     stub matches `node`'s ARGUMENTS, so an invocation of the pin suite through
 *     an interpreter the stub does not replace (an absolute `node` path) is not
 *     the stubbed failure. The assertion still only requires SOME failure to
 *     reach the guard.
 *   - THREE CONTROLS MAKE IT FALSIFIABLE, and all are tested: a POSITIVE control
 *     (the real command with ONLY the pin suite's stub failing must exit
 *     non-zero), an ALL-PASS control (the same command with every stub passing
 *     must exit 0 — this rejects a pass produced by a missing binary or an
 *     unrelated early failure), and a NEGATIVE control (the committed invocation
 *     wrapped in a multi-line quoted string must make the assertion go RED — the
 *     #807 shape).
 *   - IT FAILS CLOSED ON ITS OWN FAILURES: `bash` is resolved to an absolute path
 *     once and the run THROWS rather than falling back to a bare name the stub
 *     directory could shadow; a spawn failure is RED with its own message; and
 *     the run is bounded by an explicit spawn timeout, which is also RED.
 *
 * ITEM 6b IS PER-PR / POST-MERGE ONLY, AND IS ENFORCED BY PR-EDITABLE CODE.
 * Because it must EXECUTE the command it can only live in the suite (run from
 * the PR-editable `ci.yml`) and in the post-merge `ci-main.yml` leg — never in
 * the trusted `--head-ref` leg, which reads PR bytes as DATA and must never
 * execute them (a `pull_request_target` workflow that executes PR content is
 * the well-known RCE vector). The trusted leg therefore makes NO SHELL claim at
 * all about ci-main.yml; what it does assert about ci-main.yml is item 6a, which
 * is values only. 6b's guarantee sits at exactly the same trust level as the
 * lock: PR-editable code, conspicuous in the diff, and worth nothing against a
 * PR that edits the checker itself.
 *
 * `--head-ref <sha>` MODE (used by .github/workflows/workflow-lock.yml): fetch
 * the recursive git TREE at that ref (`gh api …/git/trees/<sha>?recursive=1`),
 * reject any of the three workflow paths that is not committed as a REGULAR FILE
 * — git mode `100644` or `100755` (a symlink `120000` or submodule `160000` is a
 * broken workflow entry that runs 0 jobs while the Contents API would
 * dereference it; the executable bit is irrelevant to GitHub's workflow loader,
 * so `100755` is accepted rather than made a green-locally / red-in-CI trap),
 * then fetch each remaining path's
 * BLOB by its tree sha (`…/git/blobs/<sha>`) so
 * the bytes parsed are the committed ones and never a dereference, and run ONLY
 * the value assertions (1)–(5) plus item 6a — ci-main.yml's pin-gate job, its
 * `with:` shape and its invocation line — against them. NOTHING here inspects or
 * executes ci-main.yml's shell (it must not: see item 6b above). The decode is
 * fail-closed: only `encoding: "base64"` is trusted (the API returns `none` +
 * empty content for a >1 MB blob) and a lossy decode throws. The content lock is
 * SKIPPED in this mode by design — this leg provides ZERO lock enforcement (see
 * the authoritative trust-split statement above). `--repo <owner/name>` overrides
 * the repo (else it is derived from `git remote get-url origin`).
 *
 * WHY THE ACCUMULATOR, NOT `&&` (#675 P2-2): shell `&&` short-circuits, so a
 * frontmatter-validator failure would skip this suite entirely and its verdict
 * (pin drift, mirror stamps, guard (j) itself) would never be produced for that
 * PR. The `||` form (not `cmd; a=$?;`) is required because GitHub's default
 * Linux shell is `bash -e {0}`: under `set -e` a bare failing `node` aborts the
 * script before `a=$?` runs, which reintroduces exactly the short-circuit.
 * NOTE honestly: both suites still share ONE `ci / unit-test` signal — the split
 * makes the two failure modes distinguishable in that job's log; it does NOT
 * create a separate check context (that is issue #673).
 *
 * READER BOUNDS (the subset reader this guard (j) leans on,
 * scripts/workflow-yaml.mjs — restated here so the suite states its own limits):
 *   - block-scalar chomping/folding is not modelled (`|`/`>` bodies are raw
 *     text, common indentation stripped);
 *   - scalar TYPES are not resolved — every scalar is a string, so `no`/`off`/`0`
 *     are REPORTED as truthy rather than treated as `false` (loud, never silent);
 *   - multi-line plain scalars, anchors/aliases, tags, merge keys, nested inline
 *     sequences (`- - x`) and multi-document streams all THROW;
 *   - a nested or repo-root package.json is not walked for (h) — see #643.
 *
 * PI_VERSION_PIN is imported from scripts/frontmatter-fixtures.mjs — that module
 * stays the single source of truth for the pin (it is probe-derived, see its
 * header). The fixture MATRIX itself is not used here.
 *
 * Repo-convention harness: node:assert + custom test()/section() with ✅/❌
 * markers and process.exit(1) on failure (load-gate.test.mjs pattern). Assertion
 * markers are present so mutation-survival spot-checks (deleting a rule → red
 * test) hold. Guards (h)/(i) additionally carry an explicit POSITIVE CONTROL —
 * a pure `pinFindings`/`stampFindings` predicate fed a deliberately-wrong pin and
 * asserted NON-EMPTY — so neutering the comparison turns a test red instead of
 * silently weakening the suite (#675 P1-3). The suite also asserts a lower bound
 * on the number of passing tests, so wholesale deletion of a rule's test is red.
 */

import { execFileSync, spawnSync } from "node:child_process";
import { strict as assert } from "node:assert";
import { randomBytes } from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { PI_VERSION_PIN } from "./frontmatter-fixtures.mjs";
import { parseWorkflowYaml, WorkflowYamlError } from "./workflow-yaml.mjs";
import {
  LOCKED_FILES,
  UNLOCKED_WORKFLOWS,
  hashLockedFiles,
  lockFindings,
  lockPath,
  readLock,
  workflowCoverageFindings,
  writeLockFile,
} from "./check-workflow-lock.mjs";

// ── the `--head-ref` flag + the exit handler, registered FIRST ──────────────
// #675 P2-h / third revision. The floor + roster (see below) are evaluated on
// EVERY exit path through the `exit` handler, so the handler is registered here —
// as early as the module can legally do it, before EVERY other module-level
// binding and before `runHeadRefMode` can call `process.exit`.
//
// IT MUST FAIL CLOSED. A first attempt at "register it early, the TDZ throw is
// the safe direction" is WRONG and was measured: with `process.exit(0)` pending,
// an UNCAUGHT exception in the handler leaves the exit code at 0 (the explicit
// code from `process.exit` wins). A TDZ `ReferenceError` therefore has to be
// CAUGHT and converted, which is what the catch below does — the early-exit path
// is the path the handler exists for. (`--head-ref` mode is excluded: it decides
// its own findings and exit status, and its success path must still exit 0.)
const ARGS = process.argv.slice(2);
function argValue(flag) {
  const i = ARGS.indexOf(flag);
  return i >= 0 ? (ARGS[i + 1] ?? null) : null;
}
const HEAD_REF = argValue("--head-ref");

process.on("exit", () => {
  if (HEAD_REF !== null) return;
  try {
    finalize();
  } catch (err) {
    // The module aborted before `finalized`/`passed`/`failed`/`REQUIRED_TESTS`
    // were initialized (an early `process.exit`), so `finalize()` hit a TDZ
    // binding. Running off with whatever exit code is pending is a FAIL-OPEN —
    // an early exit must be RED — so force it here. This catch is load-bearing,
    // not defensive.
    process.exitCode = 1;
    console.error(
      "❌ the suite exited before its floor and roster were initialized — an " +
        `early exit is a failure, not a pass (${String(err?.message ?? err)})`
    );
  }
});

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const CI_YML = path.join(REPO_ROOT, ".github", "workflows", "ci.yml");
const NODE_CI_YML = path.join(REPO_ROOT, ".github", "workflows", "node-ci.yml");
const CI_MAIN_YML = path.join(REPO_ROOT, ".github", "workflows", "ci-main.yml");
const CHECK_LOCK = path.join(REPO_ROOT, "scripts", "check-workflow-lock.mjs");

// ── the sticky-failure fixture's skip handshake (declared BEFORE its guard) ───
// #675 final cycle. The recursion guard used to be a bare ambient flag checked
// inside the test: `PIN_STICKY_FIXTURE_DEPTH=1 node scripts/check-pi-pin-lockstep.mjs`
// made a REQUIRED roster test do nothing and reported `105 passed, 0 failed`,
// exit 0 — a "skipped" recorded as "passed", reachable from outside the file with
// a guessable name.
//
// The guard is now a SELF-VALIDATING HANDSHAKE that FAILS CLOSED. The parent
// generates a per-run random token and writes it in TWO places only it can write:
// as a comment baked into the child copy's own source, and into a marker file at
// the child's own REPO_ROOT. The child must show BOTH. Anything else — a forged
// env var, a stale token, the plain repo suite — is RED with an explicit message,
// never a silent pass. Declared ahead of the guard below because the guard runs at
// module-evaluation time, before any other binding exists.
const STICKY_FIXTURE_ENV = "PIN_STICKY_FIXTURE_DEPTH";
const STICKY_FIXTURE_MARKER = ".pin-sticky-fixture.json";
const STICKY_FIXTURE_TOKEN_PREFIX = "PIN_STICKY_FIXTURE_TOKEN=";
// The test's NAME is part of its claim, so it is declared here (ahead of the
// roster in REQUIRED_TESTS and of the registration) and bounded to what the
// fixture proves: sticky against everything registered AFTER the terminal
// decision, i.e. against anything OUTSIDE this file. It is NOT "unflippable" —
// module-level code in the SAME file that registers a listener BEFORE the
// decision can still rewrite `process.exitCode`; that accepted residual is pinned
// by its own fixture. The name used to claim the unbounded version.
const STICKY_TEST_NAME =
  "the failure decision is STICKY against anything registered after it: a later `exit` " +
  "listener cannot flip a failing run (#675 P2, third revision)";

/**
 * What is wrong with THIS run's claim to be the sticky fixture's child?
 * → [] only for a genuine child: the token in the environment must appear BOTH
 * baked into this file (only the parent that generated the token can write it)
 * AND in the marker file at this file's own root (only that parent creates it).
 * Everything else is a non-empty list — fail-closed RED. Kept PURE so the
 * fixtures can pin every branch without spawning a full suite.
 */
function stickyFixtureHandshakeProblems({ claimed, ownSource, repoRoot, markerText }) {
  const problems = [];
  if (typeof claimed !== "string" || claimed === "") {
    problems.push(`${STICKY_FIXTURE_ENV} is set but carries no token`);
    return problems;
  }
  if (
    typeof ownSource !== "string" ||
    !ownSource.includes(`${STICKY_FIXTURE_TOKEN_PREFIX}${claimed}`)
  ) {
    problems.push(
      `the token in ${STICKY_FIXTURE_ENV} is not baked into this file — this run is not a copy ` +
        "written by a parent that generated that token"
    );
  }
  if (typeof markerText !== "string") {
    problems.push(
      `no ${STICKY_FIXTURE_MARKER} at ${repoRoot} — this run is not inside a fixture root`
    );
  } else {
    let markerToken = null;
    try {
      markerToken = JSON.parse(markerText).token ?? null;
    } catch {
      markerToken = null;
    }
    if (markerToken !== claimed) {
      problems.push(
        `${STICKY_FIXTURE_MARKER} at ${repoRoot} does not carry this run's token — the marker ` +
          "and the environment disagree"
      );
    }
  }
  return problems;
}

// ── fail closed on a forged or stale sticky-fixture skip marker ──────────────
// Runs at module-evaluation time, before the suite, so a forged marker can never
// reach the skip branch at all. `process.exit(1)` (rather than a throw) keeps the
// exit handler's floor/roster verdict on the path; either way the run is RED.
if (process.env[STICKY_FIXTURE_ENV] !== undefined) {
  const ownPath = fileURLToPath(import.meta.url);
  let ownSource = "";
  let markerText = null;
  try {
    ownSource = fs.readFileSync(ownPath, "utf8");
  } catch {
    ownSource = "";
  }
  try {
    markerText = fs.readFileSync(path.join(REPO_ROOT, STICKY_FIXTURE_MARKER), "utf8");
  } catch {
    markerText = null;
  }
  const problems = stickyFixtureHandshakeProblems({
    claimed: process.env[STICKY_FIXTURE_ENV],
    ownSource,
    repoRoot: REPO_ROOT,
    markerText,
  });
  if (problems.length > 0) {
    console.error(
      `❌ ${STICKY_FIXTURE_ENV} is set, but this run cannot prove it is the sticky fixture's ` +
        "child. Skipping a required roster test is NOT a pass, so this run fails closed."
    );
    for (const problem of problems) console.error(`   - ${problem}`);
    process.exit(1);
  }
}

// ── #808: what the authenticated sticky child skips ─────────────────────────
// The sticky-failure fixture spawns a full copy of this suite and forces one
// failure to prove the terminal `process.exit(1)` is sticky. That child exists
// ONLY to reach the terminal decision — the parent has already run every
// expensive fixture — so it skips the item-6b real-`bash` runs and the
// `--head-ref` end-to-end fixtures. The skip shortens the single largest cost of
// a run without changing anything the parent asserts; the parent still runs all
// of them.
//
// SAFETY: a skip is recorded as a PASS (the test's body returns early), so it is
// gated on the ONLY thing that can authorise it — the handshake immediately
// above, which proved this run is a copy the parent itself wrote the token into.
// An ambient env var never reaches this line: the module-top guard exits 1 first.
// The child still exits 1 (the fixture appends a forced `failed++`).
const STICKY_CHILD = process.env[STICKY_FIXTURE_ENV] !== undefined;

// ── Constants used by the narrow guard ─────────────────────────────────────
const isMap = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
const EXPECTED_USES = "daniel-ospina/agent-infra/.github/workflows/node-ci.yml@main";
// #675 P2-2 — a FAILURE ACCUMULATOR, not `&&` (see the header for why).
const EXPECTED_TEST_COMMAND =
  "a=0; node scripts/check-skill-lint.test.mjs || a=$?; b=0; node scripts/check-pi-pin-lockstep.mjs " +
  "|| b=$?; [ $a -eq 0 ] && [ $b -eq 0 ]";
// The `with:` keys ci-main.yml's pin-gate job must declare, plus the invocation
// line its `test-command` must still contain (item 6a). VALUE assertions: the
// shell guarantee for this job is item 6b's behavioural assertion, which the
// trusted leg does not (and must not) run.
// NOTE: declared HERE, before the `--head-ref` dispatch below, because
// `ciMainStructuralFindings` is reached from that dispatch at module-evaluation
// time and a `const` in the item-6 section would still be in its TDZ (this is the
// #675 review-fix finding, re-learned).
const CI_MAIN_PIN_JOB = "extension-tests";
const EXPECTED_CI_MAIN_WITH_KEYS = ["node-version", "script-validate", "skill-lint", "test-command"];
// #675 final cycle — item 6a's invocation presence check. The EXACT accumulator
// line ci-main.yml's post-merge `test-command` must still contain, as a whole
// (trimmed) line. Pinned here so a change to either side is a deliberate edit.
//
// DELIBERATELY OVER-STRICT — the comparison is exact trimmed-line equality, so
// ANY edit to that line requires updating THIS constant in the same commit. It
// false-REDs semantically equivalent, legitimate spellings that remove no
// coverage. Measured on the committed ci-main.yml, one finding each. The list
// is ILLUSTRATIVE, NOT EXHAUSTIVE — every one of these is coverage-neutral and
// still REDs:
//   - a trailing comment: `…failures=$((failures+1)) # keep`
//   - a backslash continuation splitting the line across two lines
//   - `node ./scripts/check-pi-pin-lockstep.mjs …` (a `./` prefix)
//   - tabs, or two spaces, instead of one space between the words
//   - a quoted path: `node "scripts/check-pi-pin-lockstep.mjs" …`
//   - `command node …`, or `{ …; }` around the line, or `mjs||` (no spaces)
// — all turn the check RED with the same `no longer contains the pin-suite
// invocation line` message. The over-strictness is intentional: the remedy is
// loud, and the failure message names this constant.
// DO NOT relax it here with comment-stripping or continuation-joining — that is
// shell modelling, which this PR deleted on purpose. If you believe that logic is
// needed, raise it as a recommendation; do not add it.
const EXPECTED_CI_MAIN_INVOCATION =
  "node scripts/check-pi-pin-lockstep.mjs || failures=$((failures+1))";
// The same line as it is INDENTED in ci-main.yml and in the fixture below (the
// block scalar's 8-space content indent). Used as a mutation ANCHOR by fixtures —
// never parsed, never modelled.
const CI_MAIN_INVOCATION_LINE = `        ${EXPECTED_CI_MAIN_INVOCATION}`;
const CI_MAIN_INVOCATION_LINE_NL = `${CI_MAIN_INVOCATION_LINE}\n`;

// ── --head-ref mode (trusted copy validating a PR's workflow bytes) ──────────
// Kept ahead of the suite: in this mode the suite does not run at all (the local
// repo is `main`, whose pins/stamps are not what we are validating), and the
// content lock is deliberately SKIPPED (a legitimate PR workflow edit must not
// deadlock against `main`'s old lock).
const HEAD_REF_FILES = [
  ["ci", ".github/workflows/ci.yml"],
  ["nodeCi", ".github/workflows/node-ci.yml"],
  ["ciMain", ".github/workflows/ci-main.yml"],
];

/** Derive `<owner>/<name>` from `git remote get-url origin`, or null. */
function resolveRepo() {
  try {
    const url = execFileSync("git", ["remote", "get-url", "origin"], {
      cwd: REPO_ROOT,
      encoding: "utf8",
    }).trim();
    const m = url.match(/github\.com[:/]([^/]+)\/([^/]+?)(?:\.git)?$/);
    return m ? `${m[1]}/${m[2]}` : null;
  } catch {
    return null;
  }
}

/**
 * Decode a GitHub API blob payload → utf8 text, failing CLOSED.
 *
 * The same payload shape is returned by `…/contents/<path>` and by
 * `…/git/blobs/<sha>`: `encoding: "base64"` with base64 `content`, or
 * `encoding: "none"` with empty `content` for a blob over 1 MB. Reading
 * `.content` unconditionally (the pre-fix behaviour) turned such a file into "" —
 * and because `parseWorkflowYaml("")` returns null, that silently DISARMED every
 * structural assertion (#675 P1-1). A non-base64 payload is an error, not an
 * empty workflow. `TextDecoder(…, { fatal: true })` rejects a lossy decode for
 * the same reason: a damaged read must never look like a valid workflow.
 */
function decodeBase64Blob(payload, rel) {
  let body;
  try {
    body = JSON.parse(payload);
  } catch (err) {
    throw new Error(`${rel}: the GitHub blob API did not return JSON (${String(err?.message ?? err)})`);
  }
  if (!isMap(body) || body.encoding !== "base64" || typeof body.content !== "string") {
    throw new Error(
      `${rel}: the GitHub blob API returned encoding=${JSON.stringify(body?.encoding ?? null)} — ` +
        'only base64 content is trusted (a >1 MB blob comes back as encoding "none" with empty ' +
        "content, which must never be read as an empty workflow)"
    );
  }
  const bytes = Buffer.from(body.content.replace(/\s+/g, ""), "base64");
  try {
    return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    throw new Error(`${rel}: the GitHub blob API content is not valid UTF-8`);
  }
}

/**
 * The git tree modes that are a WORKFLOW FILE as far as GitHub is concerned.
 *
 * #675 third revision (P2): the executable bit is irrelevant to GitHub's
 * workflow loader — `chmod +x .github/workflows/ci.yml` passes BOTH local legs
 * and failed ONLY in the trusted leg, a green-locally / red-in-CI trap with no
 * local reproduction. `100755` is therefore accepted; `120000` (symlink),
 * `160000` (gitlink/submodule), `040000` (directory) and anything else stay RED.
 */
const TREE_MODES_REGULAR_FILE = Object.freeze(["100644", "100755"]);

/** Human label for a rejected git tree mode. */
function treeModeLabel(mode) {
  if (mode === "120000") return "a symlink";
  if (mode === "160000") return "a submodule (gitlink)";
  if (mode === "040000") return "a directory";
  return "not a regular file";
}

/**
 * Parse a `git/trees/<sha>?recursive=1` payload → `Map<path, {mode, type, sha}>`,
 * failing CLOSED on anything that is not a complete, untruncated tree. A
 * truncated tree would make a missing path look absent for the wrong reason, and
 * a malformed entry would be silently skipped.
 */
function parseRefTree(payload) {
  let body;
  try {
    body = JSON.parse(payload);
  } catch (err) {
    throw new Error(`the git tree API did not return JSON (${String(err?.message ?? err)})`);
  }
  if (!isMap(body)) throw new Error("the git tree payload is not a JSON object");
  if (body.truncated === true) {
    throw new Error("the git tree payload is TRUNCATED — a partial tree must not be read as complete");
  }
  if (!Array.isArray(body.tree)) throw new Error("the git tree payload has no `tree` array");
  const map = new Map();
  for (const entry of body.tree) {
    if (!isMap(entry) || typeof entry.path !== "string" || typeof entry.mode !== "string") {
      throw new Error("the git tree payload contains an entry without `path`/`mode`");
    }
    map.set(entry.path, { mode: entry.mode, type: entry.type, sha: entry.sha });
  }
  return map;
}

/**
 * Every `HEAD_REF_FILES` entry must be present in the tree and committed as a
 * REGULAR FILE (git mode `100644` or `100755`), else a finding.
 *
 * #675 P1-2 — why the tree and not the Contents API: the Contents API
 * DEREFERENCES a symlink (a `120000` entry comes back as `type: "file"` with the
 * target's bytes), so hashing its payload cannot see the link at all. GitHub
 * Actions does NOT dereference it — a symlink under .github/workflows/ is a
 * broken workflow entry that runs 0 jobs — so a PR could replace ci.yml with a
 * symlink, keep every guard green, and unplug the per-PR pin gate with no lock
 * diff. The tree's `mode` is the committed truth, so it is checked before any
 * content is fetched.
 */
function headRefTreeFindings(tree) {
  const findings = [];
  for (const [, rel] of HEAD_REF_FILES) {
    const entry = tree.get(rel);
    if (entry === undefined) {
      findings.push(
        `the git tree at that ref has no ${rel} — it was deleted or moved; the trusted leg ` +
          "cannot validate a workflow that is not committed"
      );
      continue;
    }
    if (!TREE_MODES_REGULAR_FILE.includes(entry.mode)) {
      findings.push(
        `${rel} is committed with git mode ${entry.mode} (${treeModeLabel(entry.mode)}) — the ` +
          "trusted leg requires a workflow file committed as a regular blob, i.e. git mode " +
          `${TREE_MODES_REGULAR_FILE.join(" or ")}; a symlink (120000) or submodule (160000) is a ` +
          "broken workflow entry that GitHub runs as 0 jobs while readers dereference it, so any " +
          "other mode is rejected before content is read (100755 is ACCEPTED: the executable bit " +
          "is irrelevant to GitHub's workflow loader)"
      );
    }
  }
  return findings;
}

/** One `gh api` call, returning the raw JSON text. */
function ghApi(pathAndQuery) {
  return execFileSync(
    "gh",
    ["api", pathAndQuery, "-H", "Accept: application/vnd.github+json"],
    { encoding: "utf8", maxBuffer: 32 * 1024 * 1024 }
  );
}

/** Fetch + parse the recursive git tree at `ref` (fail-closed). */
function fetchRefTree(repo, ref) {
  return parseRefTree(ghApi(`repos/${repo}/git/trees/${ref}?recursive=1`));
}

/**
 * Fetch one blob by its TREE SHA — the committed bytes, never a dereference —
 * and decode it fail-closed.
 */
function fetchRefBlob(repo, sha, rel) {
  return decodeBase64Blob(ghApi(`repos/${repo}/git/blobs/${sha}`), rel);
}

/** The structural assertions, run against already-fetched sources. Never touches the lock. */
function headRefFindings(sources) {
  return wiringFindings(sources.ci, sources.nodeCi, sources.ciMain);
}

function runHeadRefMode(ref, repo) {
  if (!repo) {
    console.error(
      "❌ --head-ref needs a repo: pass --repo <owner/name>, or make " +
        "`git remote get-url origin` resolve to GitHub"
    );
    process.exit(2);
  }
  if (!/^[0-9a-f]{7,40}$/i.test(ref)) {
    console.error(`❌ --head-ref expects a commit SHA, got ${JSON.stringify(ref)}`);
    process.exit(2);
  }
  const findings = [];
  let tree = null;
  try {
    tree = fetchRefTree(repo, ref);
  } catch (err) {
    findings.push(
      `could not fetch the git tree at ${ref} from ${repo}: ${String(err?.message ?? err).trim()}`
    );
  }
  // The tree's committed MODES are checked first: a symlink/submodule entry must
  // be rejected before any content (which the blob API would hand back as the
  // link target) is read.
  if (tree !== null) findings.push(...headRefTreeFindings(tree));
  if (findings.length === 0) {
    const sources = {};
    for (const [key, rel] of HEAD_REF_FILES) {
      const sha = tree.get(rel).sha;
      try {
        sources[key] = fetchRefBlob(repo, sha, rel);
      } catch (err) {
        findings.push(
          `could not fetch ${rel} (blob ${sha}) at ${ref} from ${repo}: ` +
            `${String(err?.message ?? err).trim()}`
        );
      }
    }
    if (findings.length === 0) findings.push(...headRefFindings(sources));
  }
  if (findings.length > 0) {
    console.error(
      `❌ the PR's workflow files no longer satisfy the narrow structural guard ` +
        `(${repo}@${ref.slice(0, 12)}):`
    );
    for (const msg of findings) console.error(`   - ${msg}`);
    process.exit(1);
  }
  console.log(
    `✅ the PR's workflow files still satisfy the narrow structural guard ` +
      `(${repo}@${ref.slice(0, 12)}); the content lock is skipped in --head-ref mode by design`
  );
  process.exit(0);
}

if (HEAD_REF !== null) runHeadRefMode(HEAD_REF, argValue("--repo") ?? resolveRepo());

let passed = 0;
let failed = 0;
// #675 P2-c — a COUNT floor is not an identity: disabling 3 real tests and adding
// 3 `test("filler", () => assert.ok(true))` no-ops kept the total at 69. These
// sets let the run name the specific assertions that must exist and pass, so a
// deleted or renamed test is RED no matter what fills the count. (A required test
// whose BODY is replaced by a same-name no-op body is NOT caught — a same-commit
// residual recorded in the plan's Accepted-residual section, #675 P2-5.)
const ranTests = new Set();
const passedTests = new Set();

function test(name, fn) {
  ranTests.add(name);
  try {
    fn();
    passed++;
    passedTests.add(name);
    console.log(`  ✅ ${name}`);
  } catch (err) {
    failed++;
    console.log(`  ❌ ${name}: ${err.message}`);
  }
}

function section(name) {
  console.log(`\n${name}:`);
}

function setEq(a, b) {
  return a.length === b.length && [...a].sort().join() === [...b].sort().join();
}

// ── the floor + roster ──────────────────────────────────────────────────────
// #675 P2-h — these are evaluated on EVERY exit path. The `exit` handler that
// calls `finalize()` is registered at the very top of this module (right after
// the `--head-ref` flag is computed and before every other module-level binding),
// so an early `process.exit(0)` — anywhere below that point, including the whole
// constants/functions region — can no longer exit 0 with the floor and roster
// never evaluated. `finalize()` is also called explicitly at the end of the
// module body so the summary prints in the normal path too; the `finalized`
// latch keeps it once-only.

// #675 P2-c — REQUIRED TEST NAMES. The count floor is only a net-shrink guard:
// disabling 3 real tests and adding 3 `test("filler", () => assert.ok(true))`
// no-ops kept it at "69 passed". A name is recorded by `test()` only when the
// test RUNS AND PASSES, so a deleted or renamed assertion is RED no matter what
// fills the count (a same-name neutered BODY is a separate, documented
// residual). At minimum: the live-file assertions, every positive control, and
// one per guard section.
const REQUIRED_TESTS = Object.freeze([
  // live-file assertions
  "live ci.yml → node-ci.yml → ci-main.yml: the pin gate is wired (items 1–6)",
  "the live workflow content lock matches the committed workflows (GREEN)",
  "the live .github/workflows directory is fully classified (locked or explicitly unlocked)",
  "the live workflow corpus parses (the subset is adequate for this repo)",
  // positive controls
  "pinFindings flags a drifted pin (positive control for (h))",
  "stampFindings flags a stale stamp (positive control for (i))",
  "lockFindings: a non-object lock is RED with the --update-lock remedy (#675 P2-e)",
  "lockFindings: a version mismatch is RED with the --update-lock remedy (#675 P2-e)",
  "lockFindings: a lock with no `files` mapping is RED (#675 P2-e)",
  "lockFindings: an uncovered expected path is RED (#675 P2-e)",
  "lockFindings: an unexpected extra path is RED (#675 P2-e)",
  // one per guard section
  "extensions/*/package.json @earendil-works/pi-* pins match PI_VERSION_PIN",
  "every version literal in the mirror surfaces is the pin or a listed dep version",
  "prose carrying a 3-component literal is not a pi stamp (#779 GREEN fixtures)",
  "minimal fixture trio satisfies every narrow wiring invariant",
  "the ci-main fixture declares the pin-gate job and its `with:` keys",
  "the lock covers exactly the three pin-gate workflow paths",
  "head-ref mode runs the structural assertions and does NOT apply the content lock",
  "head-ref mode is RED for an empty or comments-only ci.yml / node-ci.yml (#675 P1-1)",
  "the GitHub blob decode fails CLOSED on encoding 'none' or a lossy decode (#675 P1-1)",
  "the lock CLI is not a silent no-op through a symlinked path (#708 class, #675 P2-b)",
  "workflow coverage: an unclassified new workflow is RED (#675 P2-d)",
  "workflow coverage: deleting workflow-lock.yml is RED (#675 P2-d / P2-g)",
  "workflow-lock.yml exists and is wired (pull_request_target + --head-ref) (#675 P2-g)",
  "a deeply nested flow collection raises WorkflowYamlError quickly (#675 P2-6)",
  "a symlinked locked workflow is RED from lockFindings (#675 P1-2)",
  "the lock CLI is RED for a symlinked locked workflow (#675 P1-2)",
  "the lock CLI still runs and fails loudly when argv[1] no longer resolves (#675 P2-f)",
  "workflow coverage: a symlinked workflow is RED (#675 P1-2)",
  "head-ref tree: a workflow committed with mode 120000 (symlink) is RED (#675 P1-2)",
  "head-ref tree: a regular-file tree (mode 100644) produces no tree findings (#675 P1-2)",
  "head-ref tree: a truncated tree payload throws (fail-closed) (#675 P1-2)",
  "--head-ref is RED end-to-end when a workflow is committed as a symlink (mode 120000) (#675 P1-2)",
  "--head-ref is GREEN end-to-end for a regular-file tree (mode 100644) (#675 P1-2)",
  "an early `process.exit(0)` in the suite still exits non-zero (#675 P2-h)",
  // #666 third revision — the ci-main.yml STRUCTURAL shape (value assertions)
  "ci-main structural: losing the `extension-tests` job is RED (#666 third revision)",
  "ci-main structural: an extra `with:` key is RED (#666 third revision)",
  "ci-main structural: dropping the `test-command` `with:` key is RED (#666 third revision)",
  // #666 third revision — item 6, behavioural. #807 changed WHAT the stub
  // fails (only the pin suite), so these names moved with it.
  "item 6b positive control: the live ci-main.yml command exits NON-ZERO with ONLY the pin suite's stub failing (#807)",
  "item 6b all-pass control: the live command exits 0 when every stub passes",
  "item 6 negative control: a guard moved inside `if false; then … fi` makes the assertion go RED",
  "item 6: a guard inside a never-called shell function makes the assertion go RED",
  "item 6: a guard hidden in a heredoc (`if false; then cat <<EOF`) makes the assertion go RED",
  // #807 — the reachability class. Three shapes the deleted scanner covered and
  // the multi-line-quoted negative control: with only the pin suite failing, each
  // leaves the step exiting 0, so each must be RED.
  "item 6b negative control (#807): the committed invocation wrapped in a multi-line quoted string makes the assertion go RED",
  "item 6b: deleting the failure guard makes the assertion go RED",
  "item 6b: an `exit 0` before the failure guard makes the assertion go RED",
  "item 6b: a guard inside a never-taken `case` arm makes the assertion go RED",
  "item 6b BOUND (pinned): a command that only keys its exit status off the STUB is still not caught",
  "item 6: a quoted `<<` no longer arms a phantom heredoc (GREEN, no false RED)",
  // #675 final cycle — item 6a (invocation presence, a VALUE check on both legs)
  // and the item-6b / sticky-fixture hygiene that fails closed on its own
  // failures. These are the assertions this cycle restored or repaired, so their
  // names are pinned: deleting or renaming one is RED regardless of the count.
  "the ci-main fixture contains the post-merge pin-suite invocation line (item 6a)",
  "item 6a: DELETING the invocation line is RED (and 6b is RED for it too under the #807 stub)",
  "item 6b hygiene: an unresolvable bash is RED with the spawn-failure message (never a pass)",
  "item 6b hygiene: a command that cannot finish is RED at the explicit spawn timeout",
  "the sticky fixture's skip handshake fails CLOSED for a forged or stale token (#675 final cycle)",
  "the sticky-fixture forge is RED end-to-end: the ambient env var alone no longer skips anything",
  "RESIDUAL (pinned, not a guarantee): module-level code in THIS file can still flip a failing run to 0 (#675 final cycle)",
  "--head-ref is RED end-to-end for a dropped or altered pin-suite invocation line (item 6a)",
  // #675 third revision — tree modes and the P2 fail-opens
  "head-ref tree: an executable mode (100755) is accepted (#675 P2, third revision)",
  "head-ref tree: a directory / submodule mode (040000 / 160000) is RED (#675 P2, third revision)",
  "workflow coverage: a symlinked .github/workflows DIRECTORY is RED (#675 P2, third revision)",
  "workflow coverage: a `.yaml` workflow is classified, not ignored (#675 P2, third revision)",
  "lockFindings: a symlinked `.github` ancestor is RED (#675 P2, third revision)",
  STICKY_TEST_NAME,
  "--update-lock on a symlinked locked file fails instead of printing an update banner (#675 P2, third revision)",
]);

// A LOWER BOUND on the passing count — a secondary, net-shrink signal. The
// required-name set above is the primary identity check (#675 P2-c). This is a
// floor, not an equality: adding tests never needs an update; deleting one does.
// (#675 final cycle: 105 → 116. #807: 116 → 120 — the three reachability shapes
// the pin-suite-only stub makes observable (a deleted failure guard, an `exit 0`
// before the guard, and a guard inside a never-taken `case` arm), plus the pinned
// stub-keyed bound. All four are in the roster above as well, so deleting one by
// name is RED independently of this floor.)
const MIN_EXPECTED_PASSING = 120;

let finalized = false;
function finalize() {
  if (finalized) return;
  finalized = true;
  console.log(`\ncheck-pi-pin-lockstep.mjs: ${passed} passed, ${failed} failed`);
  if (failed === 0 && passed < MIN_EXPECTED_PASSING) {
    failed++;
    console.error(
      `❌ only ${passed} passing tests — expected at least ${MIN_EXPECTED_PASSING}. ` +
        "A guard's test (or a whole section) was deleted or stopped running; restore it or " +
        "update MIN_EXPECTED_PASSING deliberately."
    );
  }
  const missingRequired = REQUIRED_TESTS.filter((name) => !passedTests.has(name));
  if (missingRequired.length > 0) {
    failed++;
    console.error(
      "❌ required test(s) did not run and pass — a guard's test was deleted or renamed; " +
        "filler no-op tests cannot compensate (#675 P2-c):"
    );
    for (const name of missingRequired) console.error(`   - ${name}`);
  }
  if (failed > 0) {
    console.error("❌ SOME TESTS FAILED");
    process.exitCode = 1;
  } else {
    console.log("✅ ALL TESTS PASSED");
  }
}
// NOTE: the `exit` listener is registered at the TOP of this module (see the
// `--head-ref` flag block), not here — registering it here was #675 P2-h.

// ── (h) pin lockstep (#640 review) ──────────────────────────────────────────
// The pi runtime version is hand-synced across PI_VERSION_PIN + every extension
// pi-package pin; before this tripwire nothing asserted they agree, so a partial
// bump (fixtures updated, one package.json missed) stayed CI-green. Guard the
// CLASS, not just this instance: every @earendil-works/pi-* pin under
// extensions/*/package.json — in `dependencies` OR `devDependencies` OR
// `peerDependencies` / `optionalDependencies` / `overrides` / `resolutions` (a
// plugin runtime pinned in peerDependencies drifts just as silently) — must
// equal PI_VERSION_PIN, and the per-extension PIN COUNT must match the
// expected map (a bare `matched > 0` presence check stayed green when coverage
// collapsed 6 pins → 1, i.e. the guard silently weakened).
//
// Known scope bound: this reads the direct extensions/*/package.json manifests
// only. A nested package.json (e.g. extensions/*/vendor/package.json) and a
// repo-root manifest are NOT walked — see #643.
const PIN_FIELDS = [
  "dependencies",
  "devDependencies",
  "peerDependencies",
  "optionalDependencies",
  "overrides",
  "resolutions",
];

/**
 * Collect every `@earendil-works/pi-*` pin declared by an `extensions/<name>/package.json`.
 * → { entries, pinCounts }: `entries` is the flat (file, field, name, version)
 * list the pure `pinFindings` predicate judges; `pinCounts` is the per-extension
 * coverage map that keeps a coverage collapse (6 pins → 1) red.
 */
function collectExtensionPins(root) {
  const entries = [];
  const pinCounts = {};
  for (const entry of fs.readdirSync(root, { withFileTypes: true })) {
    if (!entry.isDirectory()) continue;
    const pkgPath = path.join(root, entry.name, "package.json");
    if (!fs.existsSync(pkgPath)) continue;
    const pkg = JSON.parse(fs.readFileSync(pkgPath, "utf8"));
    let hits = 0;
    for (const field of PIN_FIELDS) {
      for (const [name, ver] of Object.entries(pkg[field] ?? {})) {
        if (!name.startsWith("@earendil-works/pi-")) continue;
        hits++;
        entries.push({ file: `extensions/${entry.name}/package.json`, field, name, version: ver });
      }
    }
    if (hits > 0) pinCounts[entry.name] = hits;
  }
  return { entries, pinCounts };
}

/**
 * PURE predicate for guard (h): every collected pin whose version is not `pin`.
 * Extracted so the suite can drive it with a deliberately-wrong pin and assert a
 * NON-EMPTY result — the positive control that makes neutering the comparison a
 * RED test instead of a silently weakened suite (#675 P1-3).
 */
function pinFindings(entries, pin) {
  const offenders = [];
  for (const e of entries) {
    if (e.version !== pin) offenders.push(`${e.file} (${e.field}): ${e.name}@${e.version}`);
  }
  return offenders;
}

section("extension pi-package pins lockstep with PI_VERSION_PIN");

test("extensions/*/package.json @earendil-works/pi-* pins match PI_VERSION_PIN", () => {
  const { entries, pinCounts } = collectExtensionPins(path.join(REPO_ROOT, "extensions"));
  // Counts, not just a name roster: the roster alone stayed green when 3 of
  // subagent's 4 pins were deleted (6 pins → 3). Assert the full map so both a
  // lost extension and a lost pin within an extension are red. Update
  // deliberately when the pi-package-pinning set changes.
  assert.deepEqual(
    pinCounts,
    { "review-enforcer": 1, subagent: 4, "verification-gate": 1 },
    "the set (or per-extension count) of @earendil-works/pi-* pins changed — the " +
      "tripwire's coverage moved (update this map only after confirming every pin " +
      "is pinned to PI_VERSION_PIN)"
  );
  const offenders = pinFindings(entries, PI_VERSION_PIN);
  assert.equal(
    offenders.length,
    0,
    `pin drift vs PI_VERSION_PIN=${PI_VERSION_PIN}:\n  ${offenders.join("\n  ")}`
  );
});

// Positive control (#675 P1-3): `if (ver !== pin)` was previously untested, so
// rewriting it to `if (false)` left the suite at 52/52 GREEN. This drives the
// same predicate with a drifted pin and requires a finding.
test("pinFindings flags a drifted pin (positive control for (h))", () => {
  const entry = {
    file: "extensions/x/package.json",
    field: "devDependencies",
    name: "@earendil-works/pi-coding-agent",
    version: "0.0.1-not-the-pin",
  };
  const offenders = pinFindings([entry], PI_VERSION_PIN);
  assert.equal(
    offenders.length,
    1,
    "a pin that is NOT PI_VERSION_PIN must be reported — if this is 0, guard (h)'s " +
      "comparison has been neutered (deleted or short-circuited)"
  );
  assert.match(offenders[0], /@earendil-works\/pi-coding-agent@0\.0\.1-not-the-pin/);
  assert.deepEqual(
    pinFindings([{ ...entry, version: PI_VERSION_PIN }], PI_VERSION_PIN),
    [],
    "a pin that IS PI_VERSION_PIN must not be reported"
  );
});

// ── (i) mirror provenance stamps (#637 escape class) ───────────────────────
// The 2026-08-10 escape was a hand-synced *provenance stamp*, not a pin:
// docs/providers.md and extensions/custom-provider-qwen/index.ts asserted verification against a pi
// release the repo had already moved past while PI_VERSION_PIN had moved on, and the claim stayed
// wrong for 12 days. (h) cannot see those files.
//
// Guard the whole stamp SET, not a phrase. A per-file phrase pattern was tried first and missed 2 of
// the 5 pi stamps (frontmatter-validate's "probe pi X" and ci-main's "devDep pinned X") — the same
// silent-staleness class this guard exists to close. So: every `<major>.<minor>.<patch>` literal on a
// line that NAMES PI of these four hand-synced surfaces must be PI_VERSION_PIN or a listed non-pi
// dependency version.
//
// #675 P1-4 — the sweep is scoped to stamp context and the per-surface assertion is a FLOOR, not an
// exact count. The previous "every version literal in the whole file, exact per-file count" form was
// a false-positive factory: appending `Requires Node 22.11.0 or newer.` to docs/providers.md, or a
// *correct* extra `See also pi 0.85.1 notes.`, or `Runner image 24.04.1 LTS` to a ci-main comment all
// reddened the suite — and because the count check ran first the diagnostic said "a stamp was
// silently dropped" when nothing was. This is the same class as #485 T2 (issue #779).
//
// Known scope bounds: 3-component literals only (a `pi 0.86` stamp is invisible); a literal is only a
// stamp when its own line names pi (a stale stamp reworded onto a pi-free line is invisible — but that
// also drops it from coverage, which trips the floor below loudly); the allowlist is keyed by version
// STRING rather than occurrence; and version-specific LINE REFERENCES are deliberately not asserted —
// they move within a version and must be re-derived by hand (see #651).
section("mirror version stamps match PI_VERSION_PIN");

const MIRROR_FILES = [
  "docs/providers.md",
  "extensions/custom-provider-qwen/index.ts",
  "scripts/frontmatter-validate.mjs",
  ".github/workflows/ci-main.yml",
];
// Non-pi dependency versions legitimately quoted in a surface (so they are not
// mistaken for stamps). Adding an entry here is a deliberate, reviewed act.
const ALLOWED_NON_PI = {
  "scripts/frontmatter-validate.mjs": ["2.9.0"], // yaml
  "docs/providers.md": ["8.9.0"], // undici
};
// #675 P1-5 — EXPLICIT STAMP CONTRACT. A 3-component literal is a pi stamp only on a line that NAMES
// PI (`pi`, `pi-ai`, `pi-coding-agent`, `pi devDep` — a `\bpi\b` token covers all of them). The
// previous pattern also matched the ordinary English words `version`, `parity`, `probe` and `devDep`,
// so unrelated prose carrying a literal was read as a stamp: appending "This setup requires Node
// version 20.11.1 or newer." to docs/providers.md, "See the parity notes for build 24.04.1 LTS.",
// "A probe of the 3.11.4 runtime is pending.", or "// Runner image parity: 22.11.0" all reddened the
// suite — the same incident class as #485 T2 (issue #779, which reddened main twice on 2026-09-10).
// Moving the stamp marker to the pi token itself is the fix: none of those prose lines names pi, while
// every real stamp line on all four surfaces does (the ci-main.yml stamp comments were reworded to
// name pi, which is what they are stamping). A stamp line reworded to drop the pi token falls out of
// coverage and trips the per-surface floor below, loudly, instead of silently weakening the guard.
const PI_STAMP_MARKER_RE = /\bpi\b/i;
const VERSION_LITERAL_RE = /\d+\.\d+\.\d+/g;
// Per-surface FLOOR, not an exact count: coverage may GROW (adding a correct
// stamp is a deliberate act, not a tripwire event) but must never SHRINK below
// the coverage this guard was written against. A shrink is the genuine "a stamp
// was silently dropped" case the old message mis-applied to growth too. Update
// deliberately when a surface gains/loses a stamp.
const STAMP_FLOORS = {
  "docs/providers.md": 1,
  "extensions/custom-provider-qwen/index.ts": 1,
  "scripts/frontmatter-validate.mjs": 3,
  ".github/workflows/ci-main.yml": 2,
};

/** Version literals in stamp context on one surface, minus its allowlisted non-pi versions. */
function collectStampLiterals(file, src) {
  const allowed = ALLOWED_NON_PI[file] ?? [];
  const out = [];
  src.split("\n").forEach((line, idx) => {
    if (!PI_STAMP_MARKER_RE.test(line)) return;
    for (const value of line.match(VERSION_LITERAL_RE) ?? []) {
      if (allowed.includes(value)) continue;
      out.push({ line: idx + 1, value });
    }
  });
  return out;
}

/**
 * PURE predicate for guard (i): every stamp literal that is not `pin`.
 * Extracted so the suite can drive it with a deliberately-wrong pin and assert a
 * NON-EMPTY result — the positive control that makes neutering the comparison a
 * RED test instead of a silently weakened suite (#675 P1-3).
 */
function stampFindings(sources, pin) {
  const offenders = [];
  for (const { file, src } of sources) {
    for (const stamp of collectStampLiterals(file, src)) {
      if (stamp.value !== pin) offenders.push(`${file}:${stamp.line}: ${stamp.value}`);
    }
  }
  return offenders;
}

test("every version literal in the mirror surfaces is the pin or a listed dep version", () => {
  const sources = MIRROR_FILES.map((file) => ({
    file,
    src: fs.readFileSync(path.join(REPO_ROOT, file), "utf8"),
  }));
  // Offenders FIRST so a stale stamp NAMES the offending literal, instead of the
  // count check mis-reporting it as a dropped stamp (#675 P1-4).
  const offenders = stampFindings(sources, PI_VERSION_PIN);
  assert.deepEqual(
    offenders,
    [],
    `version literal(s) in a pi-stamp context do not match PI_VERSION_PIN=${PI_VERSION_PIN} ` +
      `(a stale stamp, or an unrelated version that needs an ALLOWED_NON_PI entry):\n  ${offenders.join("\n  ")}`
  );
  // Floor second: this is the only "a stamp went stale / was dropped" message,
  // and it fires only when coverage actually SHRANK.
  const thin = [];
  for (const { file, src } of sources) {
    const count = collectStampLiterals(file, src).length;
    const floor = STAMP_FLOORS[file] ?? 1;
    if (count < floor) thin.push(`${file}: ${count} stamp(s) in stamp context, floor ${floor}`);
  }
  assert.deepEqual(
    thin,
    [],
    "a mirror surface lost stamp coverage — counts may GROW, never shrink below the floor " +
      `(a stamp was silently dropped or its keyword line was reworded):\n  ${thin.join("\n  ")}`
  );
});

// Positive control (#675 P1-3): deleting the `offenders.push` inside
// `stampFindings` previously left the suite at 52/52 GREEN because the live
// surface is (correctly) clean. This drives the predicate with a stale stamp.
test("stampFindings flags a stale stamp (positive control for (i))", () => {
  const file = "docs/providers.md";
  const stale = "### Verified against pi 0.0.1-not-the-pin internals (Q1)\n";
  const offenders = stampFindings([{ file, src: stale }], PI_VERSION_PIN);
  assert.equal(
    offenders.length,
    1,
    "a pi stamp that is NOT PI_VERSION_PIN must be reported — if this is 0, guard (i)'s " +
      "comparison (or its `offenders.push`) has been neutered"
  );
  assert.match(offenders[0], /^docs\/providers\.md:1: 0\.0\.1$/);
  const fresh = `### Verified against pi ${PI_VERSION_PIN} internals (Q1)\n`;
  assert.deepEqual(
    stampFindings([{ file, src: fresh }], PI_VERSION_PIN),
    [],
    "a stamp that IS PI_VERSION_PIN must not be reported"
  );
});

// #675 P1-5 / #779 — the four reproduced false positives, as GREEN fixtures. None
// of these lines names pi, so none may be read as a pi stamp, regardless of the
// other English words it carries (`version`, `parity`, `probe`) or its surface.
test("prose carrying a 3-component literal is not a pi stamp (#779 GREEN fixtures)", () => {
  const cases = [
    ["docs/providers.md", "This setup requires Node version 20.11.1 or newer.\n"],
    ["docs/providers.md", "See the parity notes for build 24.04.1 LTS.\n"],
    ["docs/providers.md", "A probe of the 3.11.4 runtime is pending.\n"],
    ["scripts/frontmatter-validate.mjs", "// Runner image parity: 22.11.0\n"],
  ];
  for (const [file, line] of cases) {
    assert.deepEqual(
      stampFindings([{ file, src: line }], PI_VERSION_PIN),
      [],
      `${file}: ${JSON.stringify(line.trim())} must NOT be read as a pi stamp`
    );
  }
  // The contract still catches a real stamp on every surface — including the
  // frontmatter-validate stamps, which are now identified by the pi token rather
  // than the bare word `probe`.
  assert.equal(
    stampFindings([{ file: "scripts/frontmatter-validate.mjs", src: "// pi v0.0.1 x\n" }], PI_VERSION_PIN).length,
    1,
    "a pi-naming line with a wrong version must still be reported"
  );
});

// ── (j) the pin gate is still wired — the narrow, declarative guard ─────────
// #637 wires the suites into the PR path with `with: test-command:` → the reusable node-ci.yml, whose
// unit-test job is SKIPPED when that input is empty. #666 replaced the denylist of execution-semantics
// neutralisers with (a) the content lock (a tripwire enforced by PR-editable code — see the
// authoritative trust-split statement in the module header) and (b) this narrow guard (better error
// message). Only six declarative facts are asserted here — see the header. NOT asserted here, because
// the lock covers them: `shell:`, `env:`, `container:`, `services:`, `runs-on:`, `defaults:`,
// `strategy.matrix`, trigger filters, job/step `needs:`, and step predicates.
section("per-PR pin gate is wired (narrow declarative guard)");

/** `continue-on-error` is dangerous only when it can be truthy (literal `false` is a no-op). */
function truthyFlag(map, key) {
  if (!isMap(map) || !Object.hasOwn(map, key)) return false;
  const v = map[key];
  return !(typeof v === "string" && v.toLowerCase() === "false");
}

function readError(label, err) {
  const detail = err instanceof WorkflowYamlError ? err.message : String(err?.message ?? err);
  return (
    `${label} could not be read by the supported YAML subset reader ` +
    `(scripts/workflow-yaml.mjs): ${detail} — extend that reader deliberately; do NOT ` +
    "fall back to text matching (that is the #637 bypass class)"
  );
}

/**
 * A zero-token document (`parseWorkflowYaml` returns null) must be RED, exactly
 * as `ciMainStructuralFindings` treats it. Skipping the assertions instead was a fail-open:
 * an empty/comments-only ci.yml produced ZERO findings and the trusted
 * `--head-ref` leg printed ✅ (#675 P1-1).
 */
function emptyDocFinding(label) {
  return (
    `${label} read as an EMPTY document (zero YAML tokens — an empty file, a comments-only ` +
    "file, or a lone `---`) — that would silently skip every structural assertion, so it is " +
    "rejected rather than read as a valid workflow"
  );
}

/**
 * Evaluate the pin-gate wiring from the three workflow SOURCES.
 * → [] when every narrow invariant holds, else one message per broken invariant.
 * Assertions are VALUES read from parsed nodes: items 1–5, plus item 6a (the
 * ci-main.yml pin-gate job, its `with:` shape and the presence of the pin-suite
 * invocation line). Item 6b — the behavioural "can the step fail?" assertion —
 * is NOT part of this function and is NOT run by the trusted leg; see the
 * module header for what runs where.
 */
function wiringFindings(ciSrc, nodeCiSrc, ciMainSrc) {
  const f = [];
  let caller;
  let callerRead = false;
  let callee;
  let calleeRead = false;
  try {
    caller = parseWorkflowYaml(ciSrc);
    callerRead = true;
  } catch (err) {
    f.push(readError(".github/workflows/ci.yml", err));
  }
  try {
    callee = parseWorkflowYaml(nodeCiSrc);
    calleeRead = true;
  } catch (err) {
    f.push(readError(".github/workflows/node-ci.yml", err));
  }

  if (callerRead) {
    if (!isMap(caller)) {
      f.push(caller === null ? emptyDocFinding("ci.yml") : "ci.yml did not read as a top-level mapping");
    } else {
      // (1) The trigger is present. `on` may be a mapping (`pull_request:`), a
      // scalar (`on: pull_request`) or a flow sequence (`on: [pull_request]`) —
      // all three are valid and GREEN. A `pull_request` token inside a block
      // scalar is not a node and a `pull_request` key under another top-level
      // mapping is not the trigger; both are RED by construction.
      if (!Object.hasOwn(caller, "on")) {
        f.push("ci.yml no longer declares a top-level `on:` trigger");
      } else {
        const on = caller.on;
        let found = false;
        if (typeof on === "string") found = on === "pull_request";
        else if (Array.isArray(on)) found = on.includes("pull_request");
        else if (isMap(on)) found = Object.hasOwn(on, "pull_request");
        else f.push("ci.yml's `on:` is neither a mapping, a flow sequence nor a scalar");
        if (!found) {
          f.push(
            "ci.yml must still run on `pull_request` — otherwise the per-PR pin gate never fires"
          );
        }
      }

      // (2)–(4) The caller job: exact `uses`, no disabling keys, exact binding.
      const callerJob = isMap(caller.jobs) && isMap(caller.jobs.ci) ? caller.jobs.ci : null;
      if (!callerJob) {
        f.push("ci.yml no longer defines a `ci:` job in its `jobs:` mapping");
      } else {
        if (callerJob.uses !== EXPECTED_USES) {
          f.push(
            `the \`ci:\` job in ci.yml must call \`${EXPECTED_USES}\` exactly — found ` +
              `${JSON.stringify(callerJob.uses ?? null)} (a decoy \`uses:\` substring elsewhere on ` +
              "a line does not count)"
          );
        }
        if (Object.hasOwn(callerJob, "if")) {
          f.push(
            "the `ci:` job in ci.yml gained an `if:` — that can skip the reusable-workflow call " +
              "entirely (e.g. on pull_request), leaving every PR green with zero pin check"
          );
        }
        if (truthyFlag(callerJob, "continue-on-error")) {
          f.push(
            "the `ci:` job in ci.yml gained `continue-on-error:` — the pin gate could fail silently"
          );
        }
        const withMap = callerJob.with;
        if (!isMap(withMap)) {
          f.push(
            "the `ci:` job in ci.yml no longer passes a `with:` mapping to the node-ci.yml " +
              "reusable workflow"
          );
        } else {
          const keys = Object.keys(withMap);
          if (keys.length !== 1 || keys[0] !== "test-command") {
            f.push(
              `the \`ci:\` job's \`with:\` key set changed (${JSON.stringify(keys)}) — the pin ` +
                "gate's only input is `test-command` (update deliberately, after confirming both " +
                "suites still run per-PR)"
            );
          }
          const cmd = withMap["test-command"];
          if (typeof cmd !== "string" || cmd.trim() === "") {
            f.push(
              "the node-ci.yml call in ci.yml no longer passes a non-empty `test-command` — the " +
                "input would fall back to '' and the unit-test job would be silently skipped"
            );
          } else if (cmd.trim() !== EXPECTED_TEST_COMMAND) {
            f.push(
              `ci.yml \`test-command\` must be exactly ${JSON.stringify(EXPECTED_TEST_COMMAND)} — a ` +
                "suffix or shell wrapper (e.g. `|| true`) leaves the job green even when a suite " +
                `fails; found ${JSON.stringify(cmd)}`
            );
          }
        }
      }
    }
  }

  if (calleeRead) {
    if (!isMap(callee)) {
      f.push(
        callee === null ? emptyDocFinding("node-ci.yml") : "node-ci.yml did not read as a top-level mapping"
      );
    } else {
      // (5) The callee still declares the `unit-test` job and the `test-command`
      // workflow_call input. (Its steps' execution semantics are the lock's job.)
      const inputs =
        isMap(callee.on) && isMap(callee.on.workflow_call) && isMap(callee.on.workflow_call.inputs)
          ? callee.on.workflow_call.inputs
          : null;
      if (!inputs || !Object.hasOwn(inputs, "test-command")) {
        f.push(
          "node-ci.yml no longer declares a `test-command` workflow_call input — the caller's " +
            "binding would be ignored and the unit-test job skipped"
        );
      }
      if (!(isMap(callee.jobs) && isMap(callee.jobs["unit-test"]))) {
        f.push("node-ci.yml no longer defines a `unit-test:` job");
      }
    }
  }

  // (6a) The ci-main.yml pin-gate job's VALUES — job existence, `with:` shape,
  // non-empty `test-command`, and the pin-suite invocation line inside it. All
  // value assertions, so this trusted leg runs them; item 6b (the behavioural
  // "can the step fail?" assertion) is NOT run here — it would have to EXECUTE
  // PR content, which this leg must never do.
  f.push(...ciMainStructuralFindings(ciMainSrc));
  f.push(...ciMainInvocationFindings(ciMainSrc));
  return f;
}

// ── (j), post-merge half — ci-main.yml's STRUCTURE (item 6a) ─────────────────
//
// ── (j), post-merge half — ci-main.yml's VALUES (item 6a) ───────────────────
//
// VALUE ASSERTIONS, AND NOTHING ELSE. This is what the TRUSTED `--head-ref` leg
// asserts about ci-main.yml: the pin-gate job still exists, still declares the
// expected `with:` keys, one of them a non-empty `test-command`, and that body
// still CONTAINS the exact pin-suite invocation line. It does NOT model, scan or
// reason about the SHELL that job runs — four review rounds of doing exactly that
// produced a new bypass each time (see the module header, "WHY EXECUTION
// REPLACED THE SCANNER").
//
// Item 6b is the behavioural assertion further down. It has to EXECUTE the
// command, so it can only run in the PR-editable suite, and the trusted leg must
// never run it (executing PR content under `pull_request_target` is the RCE
// vector). The trusted leg therefore makes NO claim about ci-main.yml's shell.
//
// THE INVOCATION-PRESENCE CHECK WAS DELETED WITH THE SCANNER AND IS RESTORED
// HERE, as a pure VALUE. The deleted scanner asserted two different things: the
// line is PRESENT, and the step can FAIL. Only the second needed shell modelling.
// Deleting both left a hole with no owner: a ci-main.yml that drops the
// invocation line and updates the lock was caught by NOTHING (measured: the suite
// reports `0 failed`, exit 0, and the trusted `--head-ref` leg reports ✅). The
// check below is a trimmed-line equality against a pinned constant on the value
// the YAML reader parsed — never a grep of the raw file.
//
// WHAT IT PROVES / DOES NOT PROVE, EXACTLY: it proves the LINE EXISTS in the
// committed `test-command` body. It does NOT prove the line is REACHABLE (a line
// inside a multi-line quoted string is textually present but is not a command)
// and it does NOT prove the step can FAIL (item 6b's job).
//
// REACHABILITY IS NOW ALSO CAUGHT BY 6b, ON THE COMMITTED FILE (#807). Item 6b's
// stub fails ONLY the pin suite, so wrapping the invocation in a multi-line
// quoted string leaves NOTHING failing: the step reaches its success echo and
// exits 0, and 6b goes RED. Measured on the committed, MULTI-SUITE ci-main.yml:
// 6a still passes (`ciMainInvocationFindings(mutated).length === 0` — the wrapped
// line is still one trimmed line), while
// `runCiMainTestCommand(mutated, "pin-suite-only-fails")` → status 0 — 6b's RED.
// The fixture is in the item-6b section; with the pre-#807 `all-fail` stub the
// same mutation was status 1, which is what made it invisible.
// It reads already-fetched bytes and executes nothing, so it is safe — and
// REQUIRED — on the privileged trusted leg.

/**
 * Item 6a, second half: the pin-gate `test-command` body still contains the
 * pin-suite invocation line. Returns [] when the doc/job/body is missing, is a
 * non-string or is empty — those shapes already have exactly one owner in
 * `ciMainStructuralFindings`, and a second message would just be noise.
 */
function ciMainInvocationFindings(src) {
  let doc;
  try {
    doc = parseWorkflowYaml(src);
  } catch {
    return [];
  }
  if (!isMap(doc) || !isMap(doc.jobs) || !isMap(doc.jobs[CI_MAIN_PIN_JOB])) return [];
  const withMap = doc.jobs[CI_MAIN_PIN_JOB].with;
  const cmd = isMap(withMap) ? withMap["test-command"] : null;
  if (typeof cmd !== "string" || cmd.trim() === "") return [];
  // TRIMMED-LINE equality, not a substring search: the accumulator line is the
  // unit that must survive, and indentation is the YAML block scalar's business.
  const lines = cmd.split("\n").map((line) => line.trim());
  if (lines.includes(EXPECTED_CI_MAIN_INVOCATION)) return [];
  return [
    `ci-main.yml's \`${CI_MAIN_PIN_JOB}\` \`test-command\` no longer contains the pin-suite ` +
      `invocation line ${JSON.stringify(EXPECTED_CI_MAIN_INVOCATION)} as a whole line — the ` +
      "post-merge half of #637's pin-gate contract would be dropped while the job stays green " +
      "(item 6b cannot run on the trusted `--head-ref` leg, which must never execute PR content). " +
      "Restore " +
      "the line, or change it deliberately and update this constant in the same commit.",
  ];
}

/**
 * Evaluate ci-main.yml's pin-gate STRUCTURE from the source.
 * → [] when the job and its `with:` keys are as agreed, else one message each.
 */
function ciMainStructuralFindings(src) {
  let doc;
  try {
    doc = parseWorkflowYaml(src);
  } catch (err) {
    return [readError(".github/workflows/ci-main.yml", err)];
  }
  if (!isMap(doc)) {
    return [
      doc === null ? emptyDocFinding("ci-main.yml") : "ci-main.yml did not read as a top-level mapping",
    ];
  }
  const job =
    isMap(doc.jobs) && isMap(doc.jobs[CI_MAIN_PIN_JOB]) ? doc.jobs[CI_MAIN_PIN_JOB] : null;
  if (!job) {
    return [
      `ci-main.yml no longer defines the \`${CI_MAIN_PIN_JOB}\` job — the post-merge half of ` +
        "#637's pin-gate contract would be dropped silently",
    ];
  }
  const f = [];
  const withMap = job.with;
  if (!isMap(withMap)) {
    f.push(
      `ci-main.yml's \`${CI_MAIN_PIN_JOB}\` job no longer passes a \`with:\` mapping to the ` +
        "node-ci.yml reusable workflow"
    );
  } else {
    const keys = Object.keys(withMap);
    if (!setEq(keys, EXPECTED_CI_MAIN_WITH_KEYS)) {
      f.push(
        `ci-main.yml's \`${CI_MAIN_PIN_JOB}\` job \`with:\` key set changed ` +
          `(${JSON.stringify(keys)}) — expected exactly ` +
          `${JSON.stringify([...EXPECTED_CI_MAIN_WITH_KEYS])} (update deliberately, after ` +
          "confirming the post-merge pin gate still runs)"
      );
    }
    const cmd = withMap["test-command"];
    if (typeof cmd !== "string" || cmd.trim() === "") {
      f.push(
        `ci-main.yml's \`${CI_MAIN_PIN_JOB}\` job no longer passes a non-empty \`test-command\` — ` +
          "the post-merge pin gate would never run"
      );
    }
  }
  return f;
}

// ── ITEM 6b — BEHAVIOURAL: can the committed command actually fail? ─────────
//
// The whole point of the #666 third revision. Rather than ask "does this shell
// LOOK like a failure accumulator?", EXECUTE the committed command and measure
// the exit status.
//
// WHAT IT CATCHES, EXACTLY (the module header carries the full, authoritative
// statement): any shell construct that makes the STEP'S EXIT STATUS depend on the
// PIN SUITE's stub failing — bash, not this file, decides that. Because the stub
// fails ONLY the pin suite (#807), a construct that stops that invocation from
// running at all (a multi-line quoted string around it, a deleted line, a
// never-called function) leaves NOTHING failing and the assertion goes RED. It
// does NOT catch a command that merely keys its exit status off the stub — a
// probe naming the pin suite for its own sake, followed by the guard and no
// suite invocation, is GREEN here and dead in real CI; item 6a is what catches
// that shape.
//
// WHAT IT PROVES: on this machine, with this shell, with the `node` stub failing
// ONLY the pin suite's invocation and every other stub passing, the committed
// `test-command` body makes the step exit non-zero.
//
// WHAT IT DOES NOT PROVE: that the real suites run or pass, that the step fails
// (or passes) on GitHub's runner, or that the failing exit status came from the
// real pin suite rather than from the stub. The stub matches `node`'s ARGUMENTS,
// so per-suite attribution is bounded by the stub, not by the suite count.
const ITEM6_STUB_NAMES = Object.freeze(["node", "npx", "npm", "bash"]);
/**
 * #807 — WHAT THE STUB FAILS. The pre-#807 stub made every stubbed interpreter
 * exit 1 (`all-fail`), which meant the other suites in the committed MULTI-SUITE
 * command drove the failure guard on their own: an invocation swallowed by a
 * multi-line quoted string (present as text, never executed) still left the step
 * exiting non-zero, so item 6b stayed GREEN while the pin gate was dead.
 *
 * Item 6b now runs with `pin-suite-only-fails`: the `node` stub exits 1 ONLY when
 * its arguments name the pin suite; every other stubbed invocation exits 0. With
 * only the pin suite failing, a swallowed invocation leaves NOTHING failing, the
 * step reaches its success echo and exits 0, and 6b goes RED. No shell structure
 * is modelled anywhere in this file — the stub change IS the fix.
 *
 * `all-fail` is retained ONLY so the suite can demonstrate the pre-#807 behaviour
 * it replaces (its generated stub is byte-identical to the old `exit 1` stub) and
 * `all-pass` is the positive control.
 */
const ITEM6_STUB_MODES = Object.freeze(["all-fail", "pin-suite-only-fails", "all-pass"]);
const ITEM6_PIN_SUITE_NAME = "check-pi-pin-lockstep.mjs";

/**
 * The body of the `name` stub for `mode`.
 *   all-pass               — every stubbed interpreter exits 0.
 *   all-fail               — every stubbed interpreter exits 1 (pre-#807).
 *   pin-suite-only-fails   — the `node` stub exits 1 only when its arguments name
 *                            the pin suite; `npx`/`npm`/`bash` exit 0.
 * The match is on `"$*"` — the arguments as text. It is deliberately NOT an
 * analysis of shell structure, and nothing in this file parses quotes, `if`/`fi`
 * or heredocs.
 */
function item6StubBody(name, mode) {
  if (mode === "all-pass") return "#!/bin/sh\nexit 0\n";
  if (mode === "all-fail") return "#!/bin/sh\nexit 1\n";
  if (name !== "node") return "#!/bin/sh\nexit 0\n";
  return (
    "#!/bin/sh\n" +
    'case "$*" in\n' +
    `  *${ITEM6_PIN_SUITE_NAME}*) exit 1 ;;\n` +
    "  *) exit 0 ;;\n" +
    "esac\n"
  );
}
/** The `extensions/*` directories the committed command `cd`s into before `npm ci`. */
const ITEM6_CWD_DIRS = Object.freeze([
  "extensions/review-enforcer",
  "extensions/verification-gate",
  "extensions/builtin-tools",
  "extensions/subagent",
]);
// `bash -e <script>` is GitHub's default Linux invocation. Resolved to an ABSOLUTE
// path because the stub directory below shadows `bash` on the child's PATH.
//
// THERE IS NO BARE-NAME FALLBACK, BY CONSTRUCTION. The previous `?? "bash"`
// fallback resolved into the PREPENDED stub directory, so the step script was
// replaced by the `bash` stub and the primary assertion printed ✅ while
// executing nothing (reproduced by forcing the fallback). An absolute path that
// does not exist is a spawn failure, which `assertStepCanFail` now reports as RED
// with its own message. Resolved ONCE, here, so no caller can re-derive it.
const BASH_ABS = ["/bin/bash", "/usr/bin/bash"].find((p) => fs.existsSync(p));
if (typeof BASH_ABS !== "string") {
  throw new Error(
    "item 6b needs an ABSOLUTE bash interpreter: neither /bin/bash nor /usr/bin/bash exists on " +
      "this machine. Falling back to a bare `bash` is not an option — item 6b prepends its stub " +
      "directory to the child's PATH, so a bare name would resolve to the stub and the step script " +
      "would be replaced by a script that only exits."
  );
}
// Wall-clock bound for one item-6b execution. The real committed command runs the
// whole post-merge suite set (~40 s on the dev box), so this is generous; it
// exists for the case where the committed command cannot finish at all (a real
// hang, a network wait, or a `node` that is not stubbed because the command
// ignores PATH). A timeout is RED with its own message — never a silent pass and
// never an open-ended wait.
const ITEM6_TIMEOUT_MS = 120_000;

/** The `extension-tests` job's `test-command` body, parsed out — never grepped. */
function ciMainTestCommand(src) {
  const doc = parseWorkflowYaml(src);
  const job =
    isMap(doc) && isMap(doc.jobs) && isMap(doc.jobs[CI_MAIN_PIN_JOB]) ? doc.jobs[CI_MAIN_PIN_JOB] : null;
  // NOT `job.with?.test-command`: `?.test-command` parses as `?.test` minus the
  // identifier `command`, a ReferenceError — not an optional lookup.
  const cmd = job !== null && isMap(job.with) ? job.with["test-command"] : null;
  assert.equal(
    typeof cmd,
    "string",
    `the ci-main source has no \`${CI_MAIN_PIN_JOB}.with.test-command\` string to execute`
  );
  return cmd;
}

/**
 * Run a ci-main `test-command` body the way the runner does — `bash -e <script>`
 * in a throwaway cwd — with `node`/`npx`/`npm`/`bash` replaced by stubs first on
 * PATH. `stubMode` selects what the stubs do (`ITEM6_STUB_MODES`); item 6b uses
 * `pin-suite-only-fails`, under which ONLY the pin suite's `node` invocation
 * fails and everything else passes.
 *
 * The stub is what keeps the run HONEST: every interpreter reachable by BARE NAME
 * on the child's PATH is replaced, so the real suites never re-enter and each
 * suite's verdict is a knob. It does NOT by itself bound the run — a command that
 * ignores PATH (an absolute interpreter path, or its own PATH surgery) can still
 * execute real work — so the run is additionally bounded by an explicit spawn
 * `timeout`. Both bounds are needed and neither is a correctness claim.
 *
 * WHY `pin-suite-only-fails` AND NOT `all-fail` (#807). The pre-#807 stub failed
 * every interpreter, and the committed command is MULTI-SUITE, so the other
 * suites drove the failure guard on their own: an invocation line swallowed by a
 * multi-line quoted string (present as text, never executed) still left the step
 * exiting non-zero and item 6b stayed GREEN. Failing only the pin suite makes the
 * assertion depend on THAT suite's stub actually running: swallow the invocation
 * and nothing fails, so the step reaches its success echo and exits 0 — RED.
 *
 * `opts.timeoutMs` and `opts.bashPath` are seams for the hygiene fixtures below
 * (a real spawn failure, a real timeout); production callers pass neither.
 * Output is captured into the returned buffer and surfaced by the caller's
 * assertion. The temp dir is always removed.
 */
function runCiMainTestCommand(src, stubMode, opts = {}) {
  if (!ITEM6_STUB_MODES.includes(stubMode)) {
    // Loud, not silent: a typo would otherwise fall through to an all-pass stub
    // and turn the positive control into a tautology.
    throw new Error(
      `runCiMainTestCommand: unknown stub mode ${JSON.stringify(stubMode)} — expected one of ` +
        `${JSON.stringify([...ITEM6_STUB_MODES])}`
    );
  }
  const timeoutMs = opts.timeoutMs ?? ITEM6_TIMEOUT_MS;
  const bash = opts.bashPath ?? BASH_ABS;
  const command = ciMainTestCommand(src);
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "pin-item6-"));
  try {
    const stubDir = path.join(dir, "stub");
    fs.mkdirSync(stubDir);
    for (const name of ITEM6_STUB_NAMES) {
      const stub = path.join(stubDir, name);
      fs.writeFileSync(stub, item6StubBody(name, stubMode));
      fs.chmodSync(stub, 0o755);
    }
    // The committed command `cd`s into these before running `npm ci`; without
    // them the install steps would fail at `cd` for an unrelated reason, which is
    // exactly what the positive control below exists to rule out.
    for (const rel of ITEM6_CWD_DIRS) fs.mkdirSync(path.join(dir, rel), { recursive: true });
    const script = path.join(dir, "step.sh");
    fs.writeFileSync(script, command.endsWith("\n") ? command : `${command}\n`);
    const res = spawnSync(bash, ["-e", script], {
      cwd: dir,
      encoding: "utf8",
      env: { ...process.env, PATH: `${stubDir}${path.delimiter}${process.env.PATH ?? ""}` },
      maxBuffer: 16 * 1024 * 1024,
      timeout: timeoutMs,
    });
    return {
      command,
      status: res.status,
      signal: res.signal ?? null,
      output: `${res.stdout ?? ""}${res.stderr ?? ""}`,
      error: res.error ?? null,
    };
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

/** The tail of a captured buffer, for an assertion message that stays readable. */
function tail(text, lines = 12) {
  const rows = text.trimEnd().split("\n");
  return rows.slice(Math.max(0, rows.length - lines)).join("\n");
}

/**
 * The behavioural item-6b assertion: run the committed command with ONLY the pin
 * suite's `node` invocation failing (every other stub passes) and require a
 * NON-ZERO exit. Throws otherwise — that is the RED state.
 *
 * THE SPAWN RESULT IS CHECKED BEFORE THE STATUS IS TRUSTED. The previous version
 * decided with `assert.notEqual(run.status, 0)`, which is TRUE when
 * `run.status === null` — so a spawn failure (bash missing, ENOENT, the child
 * killed) recorded "nothing executed" as "the step exits non-zero = the guarantee
 * holds". Verified: `spawnSync("/nonexistent/bash", …)` → `status: null` and the
 * assertion PASSED. A spawn failure and a timeout are now RED with their own
 * messages, and only a REAL numeric non-zero status counts as evidence.
 */
function assertStepCanFail(label, src, opts = {}) {
  const run = runCiMainTestCommand(src, "pin-suite-only-fails", opts);
  if (run.error !== null) {
    const code = run.error?.code ?? null;
    if (code === "ETIMEDOUT") {
      throw new Error(
        `${label}: the committed post-merge \`test-command\` did not finish within ` +
          `${opts.timeoutMs ?? ITEM6_TIMEOUT_MS} ms and was killed at the spawn timeout. An ` +
          "unfinished run is NOT evidence that the step can fail — it is a RED result with its " +
          `own cause.\n--- command output (tail) ---\n${tail(run.output)}`
      );
    }
    throw new Error(
      `${label}: the committed post-merge \`test-command\` could not be SPAWNED at all ` +
        `(error code ${JSON.stringify(code)}, command ${JSON.stringify(opts.bashPath ?? BASH_ABS)}). ` +
        "A spawn failure means NOTHING RAN, which is not evidence that the step can fail — " +
        `treating \`status: null\` as a non-zero exit was the fail-open this guard closes.\n` +
        `--- command output (tail) ---\n${tail(run.output)}`
    );
  }
  if (typeof run.status !== "number") {
    throw new Error(
      `${label}: the committed post-merge \`test-command\` child ended without an exit status ` +
        `(signal ${JSON.stringify(run.signal)}) — no suite verdict was measured, so this is RED, ` +
        `not a pass.\n--- command output (tail) ---\n${tail(run.output)}`
    );
  }
  assert.notEqual(
    run.status,
    0,
    `${label}: the committed post-merge \`test-command\` exited 0 with ONLY the pin suite's ` +
      "`node` invocation failing (every other stub passed). The step cannot fail when the pin " +
      "suite fails — either the pin gate is dead or its invocation never ran (the #807 shape)." +
      "\n--- command output (tail) ---\n" +
      `${tail(run.output)}`
  );
  return run;
}

/**
 * Assert the behavioural check goes RED for `src` — i.e. the step exits 0 with
 * only the pin suite's stub failing, so `assertStepCanFail` throws. Used by the
 * negative control and by every previously-defeated bypass shape.
 */
function assertStepCannotBeSaved(label, src) {
  // Runs the REAL assertion (not a copy of it) and requires it to throw: that is
  // the claim, and its failure message names the observed exit status.
  assert.throws(
    () => assertStepCanFail(label, src),
    /exited 0/,
    `${label}: the behavioural item-6 assertion must go RED for this shape (the step must be ` +
      "unable to fail), so the fixture proves nothing if it does not"
  );
}

const LIVE_CI = fs.readFileSync(CI_YML, "utf8");
const LIVE_NODE_CI = fs.readFileSync(NODE_CI_YML, "utf8");
const LIVE_CI_MAIN = fs.readFileSync(CI_MAIN_YML, "utf8");

test("live ci.yml → node-ci.yml → ci-main.yml: the pin gate is wired (items 1–6)", () => {
  const findings = wiringFindings(LIVE_CI, LIVE_NODE_CI, LIVE_CI_MAIN);
  assert.equal(
    findings.length,
    0,
    `the pin gate is no longer wired as expected:\n  ${findings.join("\n  ")}`
  );
});

// ── #666 workflow content lock — bytes, not semantics ───────────────────────
// The conspicuousness tripwire (see the header's authoritative trust split),
// NOT a PR-uneditable control. Every execution-semantics bypass found
// across two review rounds requires editing a locked file, which changes its
// hash. These are LOCK-level tests, not semantics tests: they prove a workflow
// edit is caught, not that a semantics model still recognises the shape.
section("workflow content lock — bytes, not semantics (#666)");

/** Build a throwaway root holding the three locked workflow files (live bytes unless overridden). */
function makeLockFixture(overrides = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "wf-lock-"));
  for (const rel of LOCKED_FILES) {
    const abs = path.join(dir, rel);
    fs.mkdirSync(path.dirname(abs), { recursive: true });
    fs.writeFileSync(
      abs,
      Object.hasOwn(overrides, rel)
        ? overrides[rel]
        : fs.readFileSync(path.join(REPO_ROOT, rel))
    );
  }
  return dir;
}

/** Append raw bytes to a file in a lock fixture. */
function bumpBytes(dir, rel, text) {
  const abs = path.join(dir, rel);
  fs.writeFileSync(abs, fs.readFileSync(abs, "utf8") + text);
}

test("the lock covers exactly the three pin-gate workflow paths", () => {
  assert.deepEqual([...LOCKED_FILES].sort(), [
    ".github/workflows/ci-main.yml",
    ".github/workflows/ci.yml",
    ".github/workflows/node-ci.yml",
  ]);
  const hashed = hashLockedFiles(REPO_ROOT);
  assert.deepEqual(Object.keys(hashed).sort(), [...LOCKED_FILES].sort());
  const lock = readLock(REPO_ROOT);
  assert.equal(lock.version, 1, "the committed lock must be version 1");
  assert.deepEqual(
    Object.keys(lock.files).sort(),
    [...LOCKED_FILES].sort(),
    "the committed lock must cover exactly the three pin-gate workflow paths"
  );
});

test("the live workflow content lock matches the committed workflows (GREEN)", () => {
  const findings = lockFindings(REPO_ROOT, readLock(REPO_ROOT));
  assert.deepEqual(
    findings,
    [],
    `the committed workflows no longer match scripts/workflow-lock.json — re-lock a ` +
      `deliberate edit with \`node scripts/check-workflow-lock.mjs --update-lock\`:\n  ` +
      findings.join("\n  ")
  );
});

test("a locked file whose bytes changed is RED, names the file, and prints the --update-lock remedy", () => {
  const dir = makeLockFixture();
  const lock = { version: 1, files: hashLockedFiles(dir) };
  assert.deepEqual(lockFindings(dir, lock), [], "the fixture must start GREEN");
  bumpBytes(dir, ".github/workflows/ci.yml", "\n# one byte\n");
  const findings = lockFindings(dir, lock);
  assert.equal(findings.length, 1, `expected exactly one finding, got ${findings.length}`);
  assert.match(findings[0], /\.github\/workflows\/ci\.yml/);
  assert.match(findings[0], /--update-lock/);
});

test("a missing locked file is RED", () => {
  const dir = makeLockFixture();
  const lock = { version: 1, files: hashLockedFiles(dir) };
  fs.rmSync(path.join(dir, ".github/workflows/node-ci.yml"));
  const findings = lockFindings(dir, lock);
  assert.equal(findings.length, 1, `expected exactly one finding, got ${findings.length}`);
  assert.match(findings[0], /\.github\/workflows\/node-ci\.yml/);
  assert.match(findings[0], /MISSING/);
});

test("--update-lock re-locks a changed file and the lock matches again (GREEN)", () => {
  const dir = makeLockFixture();
  const lock = writeLockFile(dir);
  assert.deepEqual(lockFindings(dir, lock), [], "expected GREEN on the fresh lock");
  bumpBytes(dir, ".github/workflows/ci.yml", "# deliberate edit\n");
  assert.equal(lockFindings(dir, lock).length, 1, "expected RED before re-lock");
  const relocked = writeLockFile(dir);
  assert.deepEqual(lockFindings(dir, relocked), [], "expected GREEN after --update-lock");
});

test("the --update-lock CLI rewrites the lock and exits 0", () => {
  const dir = makeLockFixture();
  const out = execFileSync(process.execPath, [CHECK_LOCK, "--update-lock", "--root", dir], {
    encoding: "utf8",
  });
  assert.match(out, /workflow lock updated/);
  const written = JSON.parse(fs.readFileSync(lockPath(dir), "utf8"));
  assert.deepEqual(Object.keys(written.files).sort(), [...LOCKED_FILES].sort());
  assert.deepEqual(lockFindings(dir, written), []);
});

test("the default CLI exits 1 on a mismatch, naming the file and the remedy", () => {
  const dir = makeLockFixture();
  writeLockFile(dir);
  bumpBytes(dir, ".github/workflows/node-ci.yml", "# changed\n");
  const res = spawnSync(process.execPath, [CHECK_LOCK, "--root", dir], { encoding: "utf8" });
  assert.equal(res.status, 1, `expected exit 1, got ${res.status}`);
  assert.match(res.stderr, /\.github\/workflows\/node-ci\.yml/);
  assert.match(res.stderr, /--update-lock/);
});

// #675 P2-b — a fresh instance of issue #708. `path.resolve(process.argv[1])`
// was compared against Node's realpath-resolved `import.meta.url`, so ANY
// symlinked ancestor (`/tmp` → `/private/tmp` on macOS) made IS_MAIN false:
// main() never ran, nothing printed, exit 0. The symlink below lives under the
// OS temp dir, which is itself symlinked on macOS.
test("the lock CLI is not a silent no-op through a symlinked path (#708 class, #675 P2-b)", () => {
  const dir = makeLockFixture();
  writeLockFile(dir);
  bumpBytes(dir, ".github/workflows/ci.yml", "# changed\n");
  const linkDir = fs.mkdtempSync(path.join(os.tmpdir(), "wf-lock-link-"));
  const link = path.join(linkDir, "check-workflow-lock.mjs");
  fs.symlinkSync(CHECK_LOCK, link);
  const verify = spawnSync(process.execPath, [link, "--root", dir], { encoding: "utf8" });
  assert.equal(
    verify.status,
    1,
    `verify mode through a symlink must RUN (exit 1), not silently exit 0 — got ${verify.status}, ` +
      `stdout=${JSON.stringify(verify.stdout)} stderr=${JSON.stringify(verify.stderr)}`
  );
  assert.match(verify.stderr, /--update-lock/, "the real run must name the remedy");
  const update = spawnSync(process.execPath, [link, "--update-lock", "--root", dir], {
    encoding: "utf8",
  });
  assert.equal(update.status, 0, `expected exit 0, got ${update.status}`);
  assert.match(
    update.stdout,
    /workflow lock updated/,
    "--update-lock through a symlink must actually run and print its output"
  );
  assert.deepEqual(
    lockFindings(dir, readLock(dir)),
    [],
    "the symlinked --update-lock must have rewritten the lock"
  );
});

// #675 P1-2 — a symlink must NOT satisfy the lock by hashing its target.
// `fs.readFileSync` (and GitHub's Contents API) dereference a symlink, so a PR
// that replaces a locked workflow with a symlink to another file kept the sha256
// identical while GitHub Actions saw a broken workflow entry and ran 0 jobs.
test("a symlinked locked workflow is RED from lockFindings (#675 P1-2)", () => {
  const dir = makeLockFixture();
  const lock = { version: 1, files: hashLockedFiles(dir) };
  assert.deepEqual(lockFindings(dir, lock), [], "the fixture must start GREEN");
  const abs = path.join(dir, ".github/workflows/ci.yml");
  const target = path.join(dir, ".github/ci-workflow.yml");
  fs.writeFileSync(target, fs.readFileSync(abs));
  fs.rmSync(abs);
  fs.symlinkSync("../ci-workflow.yml", abs);
  const findings = lockFindings(dir, lock);
  assert.equal(findings.length, 1, `expected exactly one finding, got ${findings.length}`);
  assert.match(findings[0], /ci\.yml/);
  assert.match(findings[0], /symlink/);
  assert.match(findings[0], /regular file/);
});
test("the lock CLI is RED for a symlinked locked workflow (#675 P1-2)", () => {
  const dir = makeLockFixture();
  writeLockFile(dir);
  const abs = path.join(dir, ".github/workflows/ci.yml");
  fs.writeFileSync(path.join(dir, ".github/ci-workflow.yml"), fs.readFileSync(abs));
  fs.rmSync(abs);
  fs.symlinkSync("../ci-workflow.yml", abs);
  const res = spawnSync(process.execPath, [CHECK_LOCK, "--root", dir], { encoding: "utf8" });
  assert.equal(res.status, 1, `expected exit 1, got ${res.status}`);
  assert.match(res.stderr, /regular file/);
});
test("the lock CLI still runs and fails loudly when argv[1] no longer resolves (#675 P2-f)", () => {
  const dir = makeLockFixture();
  writeLockFile(dir);
  bumpBytes(dir, ".github/workflows/ci.yml", "# changed\n");
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "wf-lock-vanish-"));
  const script = path.join(tmp, "check-workflow-lock.mjs");
  const src = fs.readFileSync(CHECK_LOCK, "utf8");
  const anchor = "const IS_MAIN =";
  assert.ok(src.includes(anchor), `self-delete fixture anchor not found: ${JSON.stringify(anchor)}`);
  // Simulate argv[1] having been deleted after the module was read but before the
  // IS_MAIN guard runs: `realpathSync` then throws, and "cannot resolve" must not
  // be read as "a different file" (that made IS_MAIN false, main() never ran, and
  // the process exited 0 silently — the #708 class this comparison closed).
  fs.writeFileSync(script, src.replace(anchor, "fs.rmSync(process.argv[1]);\n" + anchor));
  const res = spawnSync(process.execPath, [script, "--root", dir], { encoding: "utf8" });
  assert.equal(
    res.status,
    1,
    `a vanished argv[1] must still run main() and fail loudly; got status ${res.status}, ` +
      `stdout=${JSON.stringify(res.stdout)} stderr=${JSON.stringify(res.stderr)}`
  );
  assert.match(res.stderr, /--update-lock/, "the real run must name the remedy");
});

// #675 P2-e — one positive control per `lockFindings` schema branch. Neutering
// any branch previously left the suite GREEN because only the happy paths were
// exercised. Each case must produce a non-empty finding naming the --update-lock
// remedy (a malformed lock a developer can act on).
test("lockFindings: a non-object lock is RED with the --update-lock remedy (#675 P2-e)", () => {
  const dir = makeLockFixture();
  for (const bad of [null, [], "x", 42]) {
    const findings = lockFindings(dir, bad);
    assert.equal(findings.length, 1, `${JSON.stringify(bad)} must produce exactly one finding`);
    assert.match(findings[0], /--update-lock/);
  }
});
test("lockFindings: a version mismatch is RED with the --update-lock remedy (#675 P2-e)", () => {
  const dir = makeLockFixture();
  const findings = lockFindings(dir, { version: 2, files: hashLockedFiles(dir) });
  assert.equal(findings.length, 1, `expected one finding, got ${findings.length}`);
  assert.match(findings[0], /version/);
  assert.match(findings[0], /--update-lock/);
});
test("lockFindings: a lock with no `files` mapping is RED (#675 P2-e)", () => {
  const dir = makeLockFixture();
  const findings = lockFindings(dir, { version: 1 });
  assert.equal(findings.length, 1, `expected one finding, got ${findings.length}`);
  assert.match(findings[0], /`files` mapping/);
  assert.match(findings[0], /--update-lock/);
});
test("lockFindings: an uncovered expected path is RED (#675 P2-e)", () => {
  const dir = makeLockFixture();
  const files = hashLockedFiles(dir);
  delete files[".github/workflows/node-ci.yml"];
  const findings = lockFindings(dir, { version: 1, files });
  assert.equal(findings.length, 1, `expected one finding, got ${findings.length}`);
  assert.match(findings[0], /node-ci\.yml/);
  assert.match(findings[0], /--update-lock/);
});
test("lockFindings: an unexpected extra path is RED (#675 P2-e)", () => {
  const dir = makeLockFixture();
  const files = hashLockedFiles(dir);
  files[".github/workflows/extra.yml"] = "0".repeat(64);
  const findings = lockFindings(dir, { version: 1, files });
  assert.equal(findings.length, 1, `expected one finding, got ${findings.length}`);
  assert.match(findings[0], /extra\.yml/);
  assert.match(findings[0], /--update-lock/);
});

// #675 P2-d — a workflow present on disk but absent from BOTH lists must be RED,
// and deleting an allowlisted workflow (workflow-lock.yml included) must be RED.
/** A throwaway root with every allowlisted workflow present. */
function makeCoverageFixture() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "wf-cover-"));
  for (const rel of [...LOCKED_FILES, ...UNLOCKED_WORKFLOWS]) {
    const abs = path.join(dir, rel);
    fs.mkdirSync(path.dirname(abs), { recursive: true });
    fs.writeFileSync(abs, "# fixture\n");
  }
  return dir;
}

test("the live .github/workflows directory is fully classified (locked or explicitly unlocked)", () => {
  assert.deepEqual(
    workflowCoverageFindings(REPO_ROOT),
    [],
    "every committed workflow must be locked or on the explicit unlocked allowlist"
  );
});
test("workflow coverage: an unclassified new workflow is RED (#675 P2-d)", () => {
  const dir = makeCoverageFixture();
  assert.deepEqual(workflowCoverageFindings(dir), [], "the fixture must start GREEN");
  fs.writeFileSync(path.join(dir, ".github", "workflows", "extra.yml"), "# new\n");
  const findings = workflowCoverageFindings(dir);
  assert.equal(findings.length, 1, `expected one finding, got ${findings.length}`);
  assert.match(findings[0], /extra\.yml/);
});
test("workflow coverage: deleting workflow-lock.yml is RED (#675 P2-d / P2-g)", () => {
  const dir = makeCoverageFixture();
  fs.rmSync(path.join(dir, ".github", "workflows", "workflow-lock.yml"));
  const findings = workflowCoverageFindings(dir);
  assert.equal(findings.length, 1, `expected one finding, got ${findings.length}`);
  assert.match(findings[0], /workflow-lock\.yml/);
});
// #675 P1-2 — classification alone is not enough: a symlink NAMED `ci.yml`
// classifies as the locked path while GitHub runs 0 jobs for it.
test("workflow coverage: a symlinked workflow is RED (#675 P1-2)", () => {
  const dir = makeCoverageFixture();
  assert.deepEqual(workflowCoverageFindings(dir), [], "the fixture must start GREEN");
  const abs = path.join(dir, ".github/workflows/ci.yml");
  fs.rmSync(abs);
  fs.writeFileSync(path.join(dir, "target.yml"), "# target\n");
  fs.symlinkSync(path.join(dir, "target.yml"), abs);
  const findings = workflowCoverageFindings(dir);
  assert.ok(
    findings.some((m) => m.includes("regular file")),
    `a symlinked workflow must be RED; got:\n  ${findings.join("\n  ")}`
  );
});

// #675 third revision (P2) — a symlinked `.github/workflows` DIRECTORY was not
// caught. `readdirSync` follows the directory link, so every file inside still
// classified normally and BOTH local legs stayed GREEN while GitHub — which does
// not follow a symlinked directory under `.github/` either — ran 0 jobs.
test("workflow coverage: a symlinked .github/workflows DIRECTORY is RED (#675 P2, third revision)", () => {
  const dir = makeCoverageFixture();
  assert.deepEqual(workflowCoverageFindings(dir), [], "the fixture must start GREEN");
  const real = path.join(dir, "real-workflows");
  fs.renameSync(path.join(dir, ".github", "workflows"), real);
  fs.symlinkSync(real, path.join(dir, ".github", "workflows"));
  const findings = workflowCoverageFindings(dir);
  assert.ok(
    findings.some((m) => m.includes(".github/workflows is a symlink")),
    `a symlinked workflows DIRECTORY must be RED in its own right; got:\n  ${findings.join("\n  ")}`
  );
});

// #675 third revision (P2) — `readdirSync(...).filter((n) => n.endsWith(".yml"))`
// meant a `.yaml` workflow was never classified, never symlink-checked and never
// reported, while GitHub runs `.yaml` workflow files. Both extensions are
// enumerated now.
test("workflow coverage: a `.yaml` workflow is classified, not ignored (#675 P2, third revision)", () => {
  const dir = makeCoverageFixture();
  assert.deepEqual(workflowCoverageFindings(dir), [], "the fixture must start GREEN");
  const evil = path.join(dir, ".github", "workflows", "evil.yaml");
  fs.writeFileSync(evil, "# new\n");
  const findings = workflowCoverageFindings(dir);
  assert.equal(findings.length, 1, `expected one finding, got ${findings.length}`);
  assert.match(findings[0], /evil\.yaml/);
  assert.match(findings[0], /neither locked nor on the explicit unlocked allowlist/);
  // …and symlinking to it is RED as well (the link itself, not just the name).
  fs.rmSync(evil);
  fs.writeFileSync(path.join(dir, "evil-target.yaml"), "# target\n");
  fs.symlinkSync(path.join(dir, "evil-target.yaml"), evil);
  const symlinked = workflowCoverageFindings(dir);
  assert.ok(
    symlinked.some((m) => m.includes("evil.yaml") && m.includes("regular file")),
    `a symlinked \`.yaml\` workflow must be RED; got:\n  ${symlinked.join("\n  ")}`
  );
});

// #675 third revision (P2) — the same ancestor gap in `lockFindings`: an lstat of
// the FILE cannot see that `.github` itself is a link, so every locked path was
// happily hashed through it.
test("lockFindings: a symlinked `.github` ancestor is RED (#675 P2, third revision)", () => {
  const dir = makeLockFixture();
  const lock = { version: 1, files: hashLockedFiles(dir) };
  assert.deepEqual(lockFindings(dir, lock), [], "the fixture must start GREEN");
  const real = path.join(dir, "real-github");
  fs.renameSync(path.join(dir, ".github"), real);
  fs.symlinkSync(real, path.join(dir, ".github"));
  const findings = lockFindings(dir, lock);
  assert.ok(
    findings.some((m) => m.includes(".github is a symlink")),
    `a symlinked .github ancestor must be RED for every locked path; got:\n  ${findings.join("\n  ")}`
  );
});

// #675 third revision (P2) — self-consistency. `--update-lock` hashed through a
// symlinked locked file and printed `✅ workflow lock updated`, while the very
// next verify run was RED (the hash belonged to the link target). It now refuses.
test("--update-lock on a symlinked locked file fails instead of printing an update banner (#675 P2, third revision)", () => {
  const dir = makeLockFixture();
  writeLockFile(dir);
  const abs = path.join(dir, ".github/workflows/ci.yml");
  fs.writeFileSync(path.join(dir, ".github/ci-workflow.yml"), fs.readFileSync(abs));
  fs.rmSync(abs);
  fs.symlinkSync("../ci-workflow.yml", abs);
  const res = spawnSync(process.execPath, [CHECK_LOCK, "--update-lock", "--root", dir], {
    encoding: "utf8",
  });
  assert.equal(
    res.status,
    1,
    `--update-lock must refuse a symlinked locked path rather than claim success; got status ` +
      `${res.status}, stdout=${JSON.stringify(res.stdout)} stderr=${JSON.stringify(res.stderr)}`
  );
  assert.doesNotMatch(
    res.stdout,
    /workflow lock updated/,
    "the success banner must NOT be printed for a run that a verify would call RED"
  );
  assert.match(res.stderr, /refusing to re-lock/);
  assert.match(res.stderr, /symlink/);
});

// #675 P2-g — the trusted leg is bootstrapped by the NEXT PR after it lands
// (pull_request_target resolves from the default branch). Nothing writes
// post-merge evidence, so this is the assertion that deleting/unwiring it is RED.
test("workflow-lock.yml exists and is wired (pull_request_target + --head-ref) (#675 P2-g)", () => {
  const rel = ".github/workflows/workflow-lock.yml";
  const abs = path.join(REPO_ROOT, rel);
  assert.ok(fs.existsSync(abs), `${rel} must exist — it is the trusted structural leg`);
  const text = fs.readFileSync(abs, "utf8");
  const doc = parseWorkflowYaml(text);
  assert.ok(isMap(doc), `${rel} must read as a top-level mapping`);
  assert.ok(
    isMap(doc.on) && Object.hasOwn(doc.on, "pull_request_target"),
    `${rel} must still trigger on \`pull_request_target\` — that is the base-branch trigger`
  );
  assert.match(
    text,
    /node scripts\/check-pi-pin-lockstep\.mjs --head-ref/,
    `${rel} must still invoke the checker with --head-ref`
  );
  assert.ok(
    isMap(doc.permissions) && Object.hasOwn(doc.permissions, "contents"),
    `${rel} must grant \`contents: read\``
  );
  assert.ok(
    !Object.hasOwn(doc.permissions, "pull-requests"),
    `${rel} must not grant the unused \`pull-requests: read\` scope (#675 P2-h)`
  );
});

// One RED fixture per round-2 bypass class, at the LOCK level: the old design
// tried to model each of these as execution semantics and kept losing. Here we
// only prove that editing the workflow file makes the lock mismatch.
function expectLockRedForEdit(label, rel, edit) {
  test(label, () => {
    const dir = makeLockFixture();
    const lock = { version: 1, files: hashLockedFiles(dir) };
    assert.deepEqual(lockFindings(dir, lock), [], "the fixture must start GREEN");
    const live = fs.readFileSync(path.join(REPO_ROOT, rel), "utf8");
    fs.writeFileSync(path.join(dir, rel), edit(live));
    const findings = lockFindings(dir, lock);
    assert.equal(
      findings.length,
      1,
      `expected exactly one lock finding, got ${findings.length}: ${findings.join("; ")}`
    );
    assert.ok(findings[0].includes(rel), `expected the finding to name ${rel}`);
    assert.match(findings[0], /--update-lock/);
  });
}

expectLockRedForEdit(
  "a `shell: 'true {0}'` step edit is RED by the lock (#666 round 2)",
  ".github/workflows/node-ci.yml",
  (src) =>
    mutate(
      src,
      "      - name: Custom test command\n        if: inputs.test-command != ''\n",
      "      - name: Custom test command\n        if: inputs.test-command != ''\n" +
        "        shell: 'true {0}'\n"
    )
);
expectLockRedForEdit(
  "an `env:` step edit (`NODE_OPTIONS`) is RED by the lock (#666 round 2)",
  ".github/workflows/node-ci.yml",
  (src) =>
    mutate(
      src,
      "      - name: Custom test command\n        if: inputs.test-command != ''\n",
      "      - name: Custom test command\n        if: inputs.test-command != ''\n" +
        "        env:\n" +
        "          NODE_OPTIONS: --import=data:text/javascript,export default {}\n"
    )
);
expectLockRedForEdit(
  "a `container:` job edit is RED by the lock (#666 round 2)",
  ".github/workflows/node-ci.yml",
  (src) => mutate(src, "  unit-test:\n", "  unit-test:\n    container: ubuntu:22.04\n")
);
expectLockRedForEdit(
  "a `matrix.exclude` covering every combination is RED by the lock (#666 round 2)",
  ".github/workflows/node-ci.yml",
  (src) =>
    mutate(
      src,
      "  unit-test:\n",
      "  unit-test:\n" +
        "    strategy:\n" +
        "      matrix:\n" +
        "        os: [ubuntu-latest]\n" +
        "        exclude:\n" +
        "          - os: ubuntu-latest\n"
    )
);

// ── guard (j) fixtures ─────────────────────────────────────────────────────
// A minimal but COMPLETE caller/callee/ci-main trio (every narrow invariant
// satisfied) used for the GREEN/RED cases. `${{ … }}` is escaped as `\${{ … }}`
// inside template literals.
const FIXTURE_CALLER = `name: CI
on:
  pull_request:

jobs:
  ci:
    uses: ${EXPECTED_USES}
    secrets: inherit
    with:
      test-command: ${EXPECTED_TEST_COMMAND}
`;

// Only the `unit-test` job + `test-command` input are asserted (item 5); the
// steps are here so the fixture is a realistic workflow, not because the guard
// reads them (their execution semantics are the lock's job).
const FIXTURE_CALLEE = `name: Node.js CI
on:
  workflow_call:
    inputs:
      test-command:
        type: string
        default: ''

jobs:
  unit-test:
    runs-on: ubuntu-latest
    if: inputs.test-command != ''
    steps:
      - uses: actions/checkout@v4
      - name: Custom test command
        if: inputs.test-command != ''
        working-directory: \${{ inputs.working-directory }}
        run: \${{ inputs.test-command }}
`;

// Dedicated fixture for the POST-MERGE half — never the live ci-main.yml for the
// narrow STRUCTURAL assertions, so no verdict depends on the live file's
// spelling. The `echo` line is a deliberate decoy: it mentions the suite name
// without invoking it. The keys mirror the live job's `with:` key set so the same
// fixture also satisfies item (6a).
//
// The trailing `echo "✅ …"` mirrors the live file's shape and is load-bearing
// for the BEHAVIOURAL cases: with it, a command whose failure guard never runs
// exits 0, which is exactly what makes those fixtures RED.
// The fixture's `with:` block, extracted so the structural mutations below stay
// valid YAML (a block-scalar body orphaned from its header is a parse error, not
// the finding under test).
const FIXTURE_CI_MAIN_WITH =
  "    with:\n" +
  "      node-version: '22'\n" +
  "      script-validate: 'false'\n" +
  "      skill-lint: 'false'\n" +
  "      test-command: |\n" +
  "        failures=0\n" +
  '        echo "== scripts/check-pi-pin-lockstep.mjs =="\n' +
  "        node scripts/check-pi-pin-lockstep.mjs || failures=$((failures+1))\n" +
  "        if [ $failures -gt 0 ]; then\n" +
  '          echo "❌ $failures extension test file(s) failed"\n' +
  "          exit 1\n" +
  "        fi\n" +
  '        echo "✅ All extension tests passed"\n';
const FIXTURE_CI_MAIN = `name: CI on main
on:
  push:
    branches: [main]

jobs:
  extension-tests:
    uses: daniel-ospina/agent-infra/.github/workflows/node-ci.yml@main
${FIXTURE_CI_MAIN_WITH}    secrets: inherit
`;

/**
 * Resolve a fixture argument LAZILY. A plain string is the source; a function is
 * a thunk that builds a mutated source. Every mutation is passed as a thunk so it
 * is evaluated INSIDE `test()` — a fixture whose anchor moved then fails as a ❌
 * naming the anchor (via `mutate`'s assertion) instead of throwing an uncaught
 * `AssertionError` at module load and taking the whole suite down with it.
 */
function resolveSource(v) {
  return typeof v === "function" ? v() : v;
}

function expectWired(label, callerSrc, calleeSrc, ciMainSrc = FIXTURE_CI_MAIN) {
  test(label, () => {
    const findings = wiringFindings(
      resolveSource(callerSrc),
      resolveSource(calleeSrc),
      resolveSource(ciMainSrc)
    );
    assert.equal(
      findings.length,
      0,
      `expected GREEN (a semantics-preserving reformat must not false-RED):\n  ${findings.join("\n  ")}`
    );
  });
}

function expectRed(label, callerSrc, calleeSrc, needle, ciMainSrc = FIXTURE_CI_MAIN) {
  test(label, () => {
    const findings = wiringFindings(
      resolveSource(callerSrc),
      resolveSource(calleeSrc),
      resolveSource(ciMainSrc)
    );
    assert.ok(findings.length > 0, "expected the guard to go RED, got no findings");
    assert.ok(
      findings.some((m) => m.includes(needle)),
      `expected a finding mentioning ${JSON.stringify(needle)}; got:\n  ${findings.join("\n  ")}`
    );
  });
}

/** Apply a mutation and fail loudly if it did not apply (a no-op mutation proves nothing). */
function mutate(src, find, replace) {
  assert.ok(src.includes(find), `mutation anchor not found: ${JSON.stringify(find)}`);
  // A REPLACER FUNCTION, not a replacement string: several fixtures insert shell
  // text containing `$`, and `String.replace` would interpret `$$`, `$&`, `$'`
  // etc. as replacement patterns.
  const out = src.replace(find, () => replace);
  assert.notEqual(out, src, `mutation was a no-op: ${JSON.stringify(find)}`);
  return out;
}

/** Prefix every non-blank line with `n` spaces (a whole-file reindent is valid YAML). */
function reindent(src, n) {
  const pad = " ".repeat(n);
  return src
    .split("\n")
    .map((l) => (l.trim() === "" ? l : pad + l))
    .join("\n");
}

// ── #666 --head-ref mode — structural assertions only, never the lock ───────
section("--head-ref mode — structural assertions only, never the lock");

test("head-ref mode runs the structural assertions and does NOT apply the content lock", () => {
  // Structurally valid bytes that deliberately differ from the lock (a name change
  // is exactly the kind of legitimate PR edit the content lock must not deadlock).
  const ci = mutate(FIXTURE_CALLER, "name: CI", "name: CI (a PR edit)");
  const findings = headRefFindings({ ci, nodeCi: FIXTURE_CALLEE, ciMain: FIXTURE_CI_MAIN });
  assert.deepEqual(
    findings,
    [],
    `structurally-valid PR bytes must pass head-ref mode (lock skipped):\n  ${findings.join("\n  ")}`
  );
});

test("head-ref mode still goes RED on a structurally broken PR workflow", () => {
  const ci = mutate(FIXTURE_CALLER, "on:\n  pull_request:", "on:\n  push:\n    branches: [main]");
  const findings = headRefFindings({ ci, nodeCi: FIXTURE_CALLEE, ciMain: FIXTURE_CI_MAIN });
  assert.ok(
    findings.some((m) => m.includes("must still run on `pull_request`")),
    `expected the structural trigger finding, got:\n  ${findings.join("\n  ")}`
  );
});

// #675 P1-1 — the fail-open. `parseWorkflowYaml("")` returns null (empty file,
// comments-only, or a lone `---`), and the assertions were all guarded by
// `if (caller !== null)` — so ZERO findings and the trusted leg printed ✅.
// `ciMainStructuralFindings` already rejected a non-mapping document; the other two now do
// too. RED fixtures, one per reproduced input.
test("head-ref mode is RED for an empty or comments-only ci.yml / node-ci.yml (#675 P1-1)", () => {
  const emptyish = ["", "# just a comment\n", "---\n", "\n\n# nothing here\n"];
  for (const src of emptyish) {
    for (const which of ["ci", "nodeCi"]) {
      const findings = headRefFindings({
        ci: which === "ci" ? src : FIXTURE_CALLER,
        nodeCi: which === "nodeCi" ? src : FIXTURE_CALLEE,
        ciMain: FIXTURE_CI_MAIN,
      });
      assert.ok(
        findings.some((m) => m.includes("EMPTY document")),
        `${which} = ${JSON.stringify(src)} must be RED with the empty-document finding; ` +
          `got:\n  ${findings.join("\n  ")}`
      );
    }
  }
});

// #675 P1-1, compounding defect: the GitHub blob API returns `encoding: "none"`
// with empty `content` for a blob over 1 MB, so reading `.content` blindly
// turned a padded workflow into "" — straight into the fail-open path above.
// The decode is now fail-closed.
test("the GitHub blob decode fails CLOSED on encoding 'none' or a lossy decode (#675 P1-1)", () => {
  assert.equal(
    decodeBase64Blob(
      JSON.stringify({ encoding: "base64", content: Buffer.from("name: CI\n").toString("base64") }),
      ".github/workflows/ci.yml"
    ),
    "name: CI\n",
    "a base64 payload decodes to its utf-8 text"
  );
  assert.throws(
    () =>
      decodeBase64Blob(
        JSON.stringify({ encoding: "none", content: "", size: 2 * 1024 * 1024 }),
        ".github/workflows/ci.yml"
      ),
    /encoding="none"/,
    "a >1 MB blob (encoding 'none') must THROW, never decode to an empty workflow"
  );
  assert.throws(
    () =>
      decodeBase64Blob(
        JSON.stringify({ encoding: "base64", content: Buffer.from([0xff, 0xfe]).toString("base64") }),
        ".github/workflows/ci.yml"
      ),
    /not valid UTF-8/,
    "a lossy decode must THROW rather than look like a valid workflow"
  );
  assert.throws(() => decodeBase64Blob("not json", "x"), /did not return JSON/);
  // A genuinely empty file is base64 "" → "", and wiringFindings turns THAT red
  // (above); the decode itself must not pretend it is an error.
  assert.equal(decodeBase64Blob(JSON.stringify({ encoding: "base64", content: "" }), "x"), "");
});

// #675 P1-2 — the trusted leg reads the git TREE first and rejects any workflow
// path that is not committed as a regular blob. The Contents API dereferences a
// symlink, so a `120000` entry came back as `type: "file"` with the target's
// bytes and the guard passed while GitHub ran 0 jobs.
//
// #675 third revision (P2): `100755` is ACCEPTED. Git's executable bit is
// irrelevant to GitHub's workflow loader, and rejecting it was a
// green-locally / red-in-CI trap with no local reproduction (`chmod +x` passes
// both local legs and failed only here).
test("head-ref tree: a workflow committed with mode 120000 (symlink) is RED (#675 P1-2)", () => {
  const tree = parseRefTree(
    JSON.stringify({
      truncated: false,
      tree: HEAD_REF_FILES.map(([, rel]) => ({
        path: rel,
        mode: rel === ".github/workflows/ci.yml" ? "120000" : "100644",
        type: "blob",
        sha: "0".repeat(40),
      })),
    })
  );
  const findings = headRefTreeFindings(tree);
  assert.equal(findings.length, 1, `expected one finding, got ${findings.length}`);
  assert.match(findings[0], /ci\.yml/);
  assert.match(findings[0], /120000/);
  assert.match(findings[0], /symlink/);
});
test("head-ref tree: a regular-file tree (mode 100644) produces no tree findings (#675 P1-2)", () => {
  const tree = parseRefTree(
    JSON.stringify({
      truncated: false,
      tree: HEAD_REF_FILES.map(([, rel]) => ({
        path: rel,
        mode: "100644",
        type: "blob",
        sha: "0".repeat(40),
      })),
    })
  );
  assert.deepEqual(headRefTreeFindings(tree), [], "a regular-file tree must not false-RED");
});
test("head-ref tree: an executable mode (100755) is accepted (#675 P2, third revision)", () => {
  const tree = parseRefTree(
    JSON.stringify({
      truncated: false,
      tree: HEAD_REF_FILES.map(([, rel]) => ({
        path: rel,
        mode: "100755",
        type: "blob",
        sha: "0".repeat(40),
      })),
    })
  );
  assert.deepEqual(
    headRefTreeFindings(tree),
    [],
    "100755 is a regular blob as far as GitHub's workflow loader is concerned: the executable bit " +
      "is irrelevant, `chmod +x` passes every local leg, and rejecting it only here was a " +
      "green-locally / red-in-CI trap"
  );
});
test("head-ref tree: a directory / submodule mode (040000 / 160000) is RED (#675 P2, third revision)", () => {
  for (const mode of ["040000", "160000"]) {
    const tree = parseRefTree(
      JSON.stringify({
        truncated: false,
        tree: HEAD_REF_FILES.map(([, rel]) => ({
          path: rel,
          mode: rel === ".github/workflows/ci.yml" ? mode : "100644",
          type: rel === ".github/workflows/ci.yml" ? "tree" : "blob",
          sha: "0".repeat(40),
        })),
      })
    );
    const findings = headRefTreeFindings(tree);
    assert.equal(findings.length, 1, `mode ${mode}: expected one finding, got ${findings.length}`);
    assert.match(findings[0], new RegExp(mode));
    assert.match(findings[0], mode === "040000" ? /directory/ : /submodule/);
  }
});
test("head-ref tree: a truncated tree payload throws (fail-closed) (#675 P1-2)", () => {
  assert.throws(
    () => parseRefTree(JSON.stringify({ truncated: true, tree: [] })),
    /TRUNCATED/,
    "a truncated tree must be an error, not a silently partial tree"
  );
});

/** Build a stubbed `gh` (git tree + git blobs) and run the REAL --head-ref CLI against it. */
function runHeadRefWithStub(treeObj, blobMap) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "pin-headref-stub-"));
  const bin = path.join(dir, "bin");
  const blobDir = path.join(dir, "blobs");
  fs.mkdirSync(bin);
  fs.mkdirSync(blobDir);
  for (const [sha, text] of Object.entries(blobMap)) {
    fs.writeFileSync(path.join(blobDir, sha), Buffer.from(text, "utf8"));
  }
  const stub = path.join(bin, "gh");
  fs.writeFileSync(
    stub,
    [
      `#!${process.execPath}`,
      'import fs from "node:fs";',
      'const endpoint = process.argv[3] ?? "";',
      'if (/\\/git\\/trees\\//.test(endpoint)) {',
      '  process.stdout.write(fs.readFileSync(process.env.GH_STUB_TREE, "utf8"));',
      "  process.exit(0);",
      "}",
      'if (/\\/git\\/blobs\\//.test(endpoint)) {',
      '  const sha = endpoint.split("/").pop().split("?")[0];',
      '  const bytes = fs.readFileSync(process.env.GH_STUB_BLOBS + "/" + sha);',
      '  process.stdout.write(JSON.stringify({ encoding: "base64", content: bytes.toString("base64") }));',
      "  process.exit(0);",
      "}",
      'process.stderr.write("gh stub: unexpected endpoint " + endpoint + "\\n");',
      "process.exit(1);",
      "",
    ].join("\n")
  );
  fs.chmodSync(stub, 0o755);
  const treePath = path.join(dir, "tree.json");
  fs.writeFileSync(treePath, JSON.stringify(treeObj));
  return spawnSync(
    process.execPath,
    [
      path.join(REPO_ROOT, "scripts", "check-pi-pin-lockstep.mjs"),
      "--head-ref",
      "a".repeat(40),
      "--repo",
      "owner/repo",
    ],
    {
      encoding: "utf8",
      env: {
        ...process.env,
        PATH: `${bin}${path.delimiter}${process.env.PATH ?? ""}`,
        GH_STUB_TREE: treePath,
        GH_STUB_BLOBS: blobDir,
      },
    }
  );
}
test("--head-ref is RED end-to-end when a workflow is committed as a symlink (mode 120000) (#675 P1-2)", () => {
  if (STICKY_CHILD) return; // #808 — the parent already ran this fixture
  const res = runHeadRefWithStub(
    {
      truncated: false,
      tree: HEAD_REF_FILES.map(([, rel]) => ({
        path: rel,
        mode: rel === ".github/workflows/ci.yml" ? "120000" : "100644",
        type: "blob",
        sha: "0".repeat(40),
      })),
    },
    {}
  );
  assert.equal(
    res.status,
    1,
    `a symlinked workflow must be RED before any content is read; got status ${res.status}, ` +
      `stderr=${JSON.stringify(res.stderr)}`
  );
  assert.match(res.stderr, /120000/);
  assert.match(res.stderr, /symlink/);
});
test("--head-ref is GREEN end-to-end for a regular-file tree (mode 100644) (#675 P1-2)", () => {
  if (STICKY_CHILD) return; // #808 — the parent already ran this fixture
  const res = runHeadRefWithStub(
    {
      truncated: false,
      tree: [
        { path: ".github/workflows/ci.yml", mode: "100644", type: "blob", sha: "c" },
        { path: ".github/workflows/node-ci.yml", mode: "100644", type: "blob", sha: "n" },
        { path: ".github/workflows/ci-main.yml", mode: "100644", type: "blob", sha: "m" },
      ],
    },
    { c: FIXTURE_CALLER, n: FIXTURE_CALLEE, m: FIXTURE_CI_MAIN }
  );
  assert.equal(
    res.status,
    0,
    `a regular-file tree with valid blobs must stay GREEN; got status ${res.status}, ` +
      `stderr=${JSON.stringify(res.stderr)}`
  );
  assert.match(res.stdout, /still satisfy the narrow structural guard/);
});

// #675 final cycle, item 6a — the TRUSTED leg must see a dropped or altered
// pin-suite invocation line. This is the whole point of restoring it as a VALUE
// assertion: the bytes are already fetched, nothing is executed, and the check is
// therefore safe on a `pull_request_target` leg that must never run PR content.
function headRefCiMainTree(ciMain) {
  return {
    truncated: false,
    tree: [
      { path: ".github/workflows/ci.yml", mode: "100644", type: "blob", sha: "c" },
      { path: ".github/workflows/node-ci.yml", mode: "100644", type: "blob", sha: "n" },
      { path: ".github/workflows/ci-main.yml", mode: "100644", type: "blob", sha: "m" },
    ],
  };
}
function runHeadRefCiMain(ciMain) {
  return runHeadRefWithStub(headRefCiMainTree(ciMain), {
    c: FIXTURE_CALLER,
    n: FIXTURE_CALLEE,
    m: ciMain,
  });
}
test("--head-ref is RED end-to-end for a dropped or altered pin-suite invocation line (item 6a)", () => {
  if (STICKY_CHILD) return; // #808 — the parent already ran this fixture
  const variants = [
    ["deleted", mutate(FIXTURE_CI_MAIN, CI_MAIN_INVOCATION_LINE_NL, "")],
    [
      "`|| true`",
      mutate(FIXTURE_CI_MAIN, CI_MAIN_INVOCATION_LINE, "        node scripts/check-pi-pin-lockstep.mjs || true\n"),
    ],
  ];
  for (const [label, ciMain] of variants) {
    const res = runHeadRefCiMain(ciMain);
    assert.equal(
      res.status,
      1,
      `a ${label} invocation line must be RED on the TRUSTED leg (it reads bytes as data and ` +
        `executes nothing); got status ${res.status}, stderr=${JSON.stringify(res.stderr)}`
    );
    assert.match(res.stderr, /no longer contains the pin-suite invocation line/);
  }
});
test("--head-ref stays GREEN end-to-end for a legitimate unrelated ci-main.yml edit (item 6a)", () => {
  if (STICKY_CHILD) return; // #808 — the parent already ran this fixture
  const edited = mutate(FIXTURE_CI_MAIN, "        failures=0\n", "        failures=0\n        :\n");
  const res = runHeadRefCiMain(edited);
  assert.equal(
    res.status,
    0,
    `a legitimate edit elsewhere in the command must not false-RED the trusted leg; got status ` +
      `${res.status}, stderr=${JSON.stringify(res.stderr)}`
  );
});

section("guard (j) — the fixture trio satisfies items 1–6 (baseline for the GREEN/RED cases)");

test("minimal fixture trio satisfies every narrow wiring invariant", () => {
  const findings = wiringFindings(FIXTURE_CALLER, FIXTURE_CALLEE, FIXTURE_CI_MAIN);
  assert.equal(findings.length, 0, `fixture trio must be wired:\n  ${findings.join("\n  ")}`);
});

section("guard (j) — semantics-preserving reformats stay GREEN");

expectWired(
  "flow-style trigger `on: [pull_request]` is accepted",
  () => mutate(FIXTURE_CALLER, "on:\n  pull_request:", "on: [pull_request]"),
  FIXTURE_CALLEE
);
expectWired(
  "scalar trigger `on: pull_request` is accepted",
  () => mutate(FIXTURE_CALLER, "on:\n  pull_request:", "on: pull_request"),
  FIXTURE_CALLEE
);
expectWired(
  "an empty `pull_request: {}` mapping is accepted",
  () => mutate(FIXTURE_CALLER, "  pull_request:", "  pull_request: {}"),
  FIXTURE_CALLEE
);
expectWired(
  "quoted keys are accepted (`\"pull_request\":`, `\"test-command\":`, `\"with\":`, `\"uses\":`)",
  () =>
    mutate(
      mutate(
        mutate(
          mutate(FIXTURE_CALLER, "  pull_request:", '  "pull_request":'),
          "      test-command:",
          '      "test-command":'
        ),
        "    with:",
        '    "with":'
      ),
      "    uses:",
      '    "uses":'
    ),
  FIXTURE_CALLEE
);
expectWired(
  "trailing and full-line comments are accepted",
  () =>
    mutate(
      mutate(FIXTURE_CALLER, "on:", "on: # per-PR only\n# a full-line comment"),
      `      test-command: ${EXPECTED_TEST_COMMAND}`,
      `      test-command: ${EXPECTED_TEST_COMMAND} # the pin gate`
    ),
  FIXTURE_CALLEE
);
expectWired(
  "a whole-file reindent stays GREEN",
  reindent(FIXTURE_CALLER, 2),
  reindent(FIXTURE_CALLEE, 2)
);
expectWired(
  "a `with:` mapping reindented with only its job subtree stays GREEN",
  () => {
    const [head, tail] = FIXTURE_CALLER.split("jobs:");
    return head + "jobs:" + reindent(tail, 2);
  },
  FIXTURE_CALLEE
);
expectWired(
  "a block-scalar `test-command:` binding stays GREEN",
  () =>
    mutate(
      FIXTURE_CALLER,
      `      test-command: ${EXPECTED_TEST_COMMAND}`,
      `      test-command: |\n        ${EXPECTED_TEST_COMMAND}`
    ),
  FIXTURE_CALLEE
);
expectWired(
  "unrelated trigger/inputs keys (`workflow_dispatch.inputs.paths`) stay GREEN",
  () =>
    mutate(
      FIXTURE_CALLER,
      "on:\n  pull_request:",
      "on:\n  pull_request:\n  workflow_dispatch:\n    inputs:\n      paths:\n        description: unrelated\n        type: string"
    ),
  FIXTURE_CALLEE
);
expectWired(
  "`continue-on-error: false` (an explicit no-op) stays GREEN",
  () => mutate(FIXTURE_CALLER, "    uses: ", "    continue-on-error: false\n    uses: "),
  FIXTURE_CALLEE
);
expectWired(
  "a `run-name: |` scalar and a `concurrency:` block stay GREEN",
  () =>
    mutate(
      FIXTURE_CALLER,
      "jobs:",
      "run-name: |\n  CI for \${{ github.ref }}\n\nconcurrency:\n  group: ci-\${{ github.ref }}\n  cancel-in-progress: true\n\njobs:"
    ),
  FIXTURE_CALLEE
);

section("guard (j) — YAML-valid bypass attempts are RED");

expectRed(
  "a `test-command:` line inside a block scalar is RED (a scalar body is not a node)",
  () =>
    mutate(
      mutate(
        FIXTURE_CALLER,
        `      test-command: ${EXPECTED_TEST_COMMAND}`,
        `      test-command: ${EXPECTED_TEST_COMMAND} || true`
      ),
      "jobs:",
      `run-name: |\n  test-command: ${EXPECTED_TEST_COMMAND}\n\njobs:`
    ),
  FIXTURE_CALLEE,
  "`test-command` must be exactly"
);
expectRed(
  "a job-shaped block inside a YAML scalar is RED",
  () =>
    mutate(
      mutate(
        FIXTURE_CALLER,
        `    uses: ${EXPECTED_USES}`,
        `    if: github.event_name == 'push'\n    uses: ${EXPECTED_USES}`
      ),
      "jobs:",
      `run-name: |\n  jobs:\n    ci:\n      uses: ${EXPECTED_USES}\n      with:\n        test-command: ${EXPECTED_TEST_COMMAND}\n\njobs:`
    ),
  FIXTURE_CALLEE,
  "gained an `if:`"
);
expectRed(
  "an unanchored `uses:` substring elsewhere does not satisfy the call check",
  () =>
    mutate(
      mutate(FIXTURE_CALLER, "name: CI", `name: "uses: ${EXPECTED_USES}"`),
      `    uses: ${EXPECTED_USES}`,
      "    uses: daniel-ospina/agent-infra/.github/workflows/node-ci.yml@v0.1.0"
    ),
  FIXTURE_CALLEE,
  "must call"
);
expectRed(
  "the `ci:` job gaining `if:` is RED (item 3)",
  () =>
    mutate(
      FIXTURE_CALLER,
      `    uses: ${EXPECTED_USES}`,
      `    if: github.event_name == 'push'\n    uses: ${EXPECTED_USES}`
    ),
  FIXTURE_CALLEE,
  "gained an `if:`"
);
expectRed(
  "the `ci:` job gaining `continue-on-error :` (space before the colon) is RED (item 3)",
  () =>
    mutate(
      FIXTURE_CALLER,
      `    uses: ${EXPECTED_USES}`,
      `    continue-on-error : true\n    uses: ${EXPECTED_USES}`
    ),
  FIXTURE_CALLEE,
  "gained `continue-on-error:`"
);
expectRed(
  "an emptied `test-command` binding is RED (item 4)",
  () => mutate(FIXTURE_CALLER, `      test-command: ${EXPECTED_TEST_COMMAND}`, '      test-command: ""'),
  FIXTURE_CALLEE,
  "non-empty `test-command`"
);
expectRed(
  "a `|| true` wrapper on the binding is RED (item 4)",
  () =>
    mutate(
      FIXTURE_CALLER,
      `      test-command: ${EXPECTED_TEST_COMMAND}`,
      `      test-command: ${EXPECTED_TEST_COMMAND} || true`
    ),
  FIXTURE_CALLEE,
  "must be exactly"
);
expectRed(
  "an extra `with:` key is RED (item 4)",
  () =>
    mutate(
      FIXTURE_CALLER,
      `      test-command: ${EXPECTED_TEST_COMMAND}`,
      `      test-glob: '*.test.mjs'\n      test-command: ${EXPECTED_TEST_COMMAND}`
    ),
  FIXTURE_CALLEE,
  "`with:` key set changed"
);
expectRed(
  "losing the second suite from `test-command` is RED (item 4)",
  () =>
    mutate(
      FIXTURE_CALLER,
      `      test-command: ${EXPECTED_TEST_COMMAND}`,
      "      test-command: node scripts/check-skill-lint.test.mjs"
    ),
  FIXTURE_CALLEE,
  "must be exactly"
);
expectRed(
  "the trigger no longer being `pull_request` is RED (item 1)",
  () => mutate(FIXTURE_CALLER, "on:\n  pull_request:", "on:\n  push:\n    branches: [main]"),
  FIXTURE_CALLEE,
  "must still run on `pull_request`"
);
// The two decoys the #675 verification reproduced against origin/main's TEXT
// guard: both kept a `pull_request` token in the file while `on:` ran only on
// `push`, and origin/main's guard stayed 163/163 GREEN with the gate unplugged.
// A parsed read must go RED naming the missing trigger.
expectRed(
  "a bare `pull_request:` inside a `run-name: |` scalar is not the trigger (RED, item 1)",
  () =>
    mutate(
      FIXTURE_CALLER,
      "on:\n  pull_request:",
      "on:\n  push:\n    branches: [main]\nrun-name: |\n  pull_request:"
    ),
  FIXTURE_CALLEE,
  "must still run on `pull_request`"
);
expectRed(
  "a `pull_request:` key inside another top-level mapping is not the trigger (RED, item 1)",
  () =>
    mutate(
      FIXTURE_CALLER,
      "on:\n  pull_request:",
      "on:\n  push:\n    branches: [main]\n\nenv:\n  pull_request: decoy"
    ),
  FIXTURE_CALLEE,
  "must still run on `pull_request`"
);
expectRed(
  "`on: [push]` (a flow sequence without pull_request) is RED (item 1)",
  () => mutate(FIXTURE_CALLER, "on:\n  pull_request:", "on: [push]"),
  FIXTURE_CALLEE,
  "must still run on `pull_request`"
);
expectRed(
  "renaming the `test-command` workflow_call input is RED (item 5)",
  FIXTURE_CALLER,
  () =>
    mutate(
      FIXTURE_CALLEE,
      "      test-command:\n        type: string",
      "      test-cmd:\n        type: string"
    ),
  "no longer declares a `test-command`"
);
expectRed(
  "removing the `unit-test` job is RED (item 5)",
  FIXTURE_CALLER,
  () => mutate(FIXTURE_CALLEE, "  unit-test:\n", "  some-other-job:\n"),
  "no longer defines a `unit-test:`"
);
expectRed(
  "the `ci:` job calling the wrong workflow is RED (item 2)",
  () =>
    mutate(
      FIXTURE_CALLER,
      `    uses: ${EXPECTED_USES}`,
      "    uses: daniel-ospina/agent-infra/.github/workflows/node-ci.yml@v1.2.3"
    ),
  FIXTURE_CALLEE,
  "must call"
);
expectRed(
  "a construct outside the reader's subset fails LOUDLY (never silently green)",
  () => mutate(FIXTURE_CALLER, "name: CI", "name: &ci CI"),
  FIXTURE_CALLEE,
  "supported YAML subset reader"
);

// ── #675 P1-1 — YAML escape sequences must not smuggle a guarded key past the guard ──
// The reader previously appended the escaped character LITERALLY, so
// `"i\u0066"` read as the key `iu0066` while GitHub decodes it to `if` — guard
// (j) stayed GREEN with the caller job disabled. The reader decodes the full
// YAML escape set (and THROWS on anything else); this is the surviving narrow
// assertion (item 3) that depends on that decoding.
expectRed(
  'a `"i\\u0066"` key (escaped `if`) on the `ci:` job is RED (escape decoded)',
  () =>
    mutate(
      FIXTURE_CALLER,
      `    uses: ${EXPECTED_USES}`,
      '    "i\\u0066": github.event_name == \'push\'\n' + `    uses: ${EXPECTED_USES}`
    ),
  FIXTURE_CALLEE,
  "gained an `if:`"
);

// ── guard (j), item 6a — ci-main.yml's pin-gate VALUES ───────────────────────
// The value assertions the TRUSTED leg runs: the job, its `with:` keys, the
// non-empty `test-command`, and the presence of the pin-suite invocation line
// inside it. Item 6b (below) is the behavioural one and is PR-editable only —
// see the module header.
section("guard (j), item 6a — the ci-main.yml pin-gate job, its `with:` keys and the invocation line");

test("the ci-main fixture declares the pin-gate job and its `with:` keys", () => {
  const findings = ciMainStructuralFindings(FIXTURE_CI_MAIN);
  assert.deepEqual(findings, [], `fixture must be structurally wired:\n  ${findings.join("\n  ")}`);
});
test("ci-main structural: losing the `extension-tests` job is RED (#666 third revision)", () => {
  const dropped = mutate(FIXTURE_CI_MAIN, "  extension-tests:\n", "  some-other-job:\n");
  const findings = ciMainStructuralFindings(dropped);
  assert.ok(
    findings.some((m) => m.includes("no longer defines the `extension-tests`")),
    `expected the missing-job finding; got:\n  ${findings.join("\n  ")}`
  );
});
test("ci-main structural: an extra `with:` key is RED (#666 third revision)", () => {
  const extra = mutate(
    FIXTURE_CI_MAIN,
    "      test-command: |",
    "      test-glob: '*.test.mjs'\n      test-command: |"
  );
  const findings = ciMainStructuralFindings(extra);
  assert.ok(
    findings.some((m) => m.includes("`with:` key set changed")),
    `expected the with:-key-set finding; got:\n  ${findings.join("\n  ")}`
  );
});
test("ci-main structural: dropping the `test-command` `with:` key is RED (#666 third revision)", () => {
  const noCmd = mutate(
    FIXTURE_CI_MAIN,
    FIXTURE_CI_MAIN_WITH,
    "    with:\n      node-version: '22'\n      script-validate: 'false'\n      skill-lint: 'false'\n"
  );
  const findings = ciMainStructuralFindings(noCmd);
  assert.ok(
    findings.some((m) => m.includes("`with:` key set changed")),
    `expected the with:-key-set finding; got:\n  ${findings.join("\n  ")}`
  );
});
test("ci-main structural: an emptied `test-command` is RED (#666 third revision)", () => {
  const emptied = mutate(
    FIXTURE_CI_MAIN,
    FIXTURE_CI_MAIN_WITH,
    "    with:\n      node-version: '22'\n      script-validate: 'false'\n      skill-lint: 'false'\n" +
      '      test-command: ""\n'
  );
  const findings = ciMainStructuralFindings(emptied);
  assert.ok(
    findings.some((m) => m.includes("non-empty `test-command`")),
    `expected the empty-test-command finding; got:\n  ${findings.join("\n  ")}`
  );
});
test("ci-main structural: a `with:` mapping replaced by a scalar is RED (#666 third revision)", () => {
  const scalar = mutate(FIXTURE_CI_MAIN, FIXTURE_CI_MAIN_WITH, "    with: nope\n");
  const findings = ciMainStructuralFindings(scalar);
  assert.ok(
    findings.some((m) => m.includes("no longer passes a `with:` mapping")),
    "expected the non-mapping `with:` finding; got:\n  " + findings.join("\n  ")
  );
});
test("ci-main structural: an empty ci-main.yml document is RED (#666 third revision)", () => {
  const findings = ciMainStructuralFindings("");
  assert.ok(
    findings.some((m) => m.includes("EMPTY document")),
    `an empty ci-main.yml must be RED, never silently skipped; got:\n  ${findings.join("\n  ")}`
  );
});

// ── item 6a, second half — THE INVOCATION LINE'S PRESENCE (#675 final cycle) ─
// The check the scanner's deletion removed ALONG WITH the shell modelling. It is
// a pure VALUE assertion on the parsed `test-command` body, so it runs on BOTH
// legs (the trusted `--head-ref` leg included) and executes nothing.
//
// WHAT IT PROVES: the exact accumulator line EXISTS as a whole trimmed line in
// the committed body. WHAT IT DOES NOT PROVE: that the line is REACHABLE (a line
// inside a multi-line quoted string is textually present but is not a command) or
// that the step can FAIL (item 6b). #807 made 6b see the reachability shape too —
// its stub fails ONLY the pin suite, so a swallowed invocation leaves nothing
// failing and the step exits 0 — but 6b can only run where the command may be
// EXECUTED, never on the trusted `pull_request_target` leg. 6a is what the
// trusted leg runs, so it remains the owner of the dropped/repointed/unreachable
// line THERE.
// Its unique value is the shape item 6b cannot see on the trusted leg: a deleted
// or repointed line, whose stub-keyed failure would otherwise keep the step green.
test("the ci-main fixture contains the post-merge pin-suite invocation line (item 6a)", () => {
  assert.deepEqual(
    ciMainInvocationFindings(FIXTURE_CI_MAIN),
    [],
    "the fixture must carry the invocation line"
  );
});
test("item 6a: DELETING the invocation line is RED (and 6b is RED for it too under the #807 stub)", () => {
  const dropped = mutate(FIXTURE_CI_MAIN, CI_MAIN_INVOCATION_LINE_NL, "");
  const findings = ciMainInvocationFindings(dropped);
  assert.ok(
    findings.some((m) => m.includes("no longer contains the pin-suite invocation line")),
    `expected the missing-invocation finding; got:\n  ${findings.join("\n  ")}`
  );
  const liveDropped = mutate(LIVE_CI_MAIN, CI_MAIN_INVOCATION_LINE_NL, "");
  assert.ok(
    ciMainInvocationFindings(liveDropped).length > 0,
    "deleting the line from the LIVE file must be RED for item 6a"
  );
  // #807 — the pin-suite-only stub makes 6b sensitive to the dropped line TOO:
  // nothing fails, so the step reaches its success echo and exits 0. 6b can only
  // run where the command may be EXECUTED, and the trusted `--head-ref` leg must
  // never do that (executing PR content under `pull_request_target` is the RCE
  // vector) — which is exactly why 6a, a value assertion, still owns this shape.
  if (!STICKY_CHILD) {
    const run = runCiMainTestCommand(liveDropped, "pin-suite-only-fails");
    assert.equal(run.error, null, `no spawn error expected: ${String(run.error)}`);
    assert.equal(
      run.status,
      0,
      "with only the pin suite failing, a dropped invocation leaves nothing failing and the step " +
        `must exit 0 (item 6b is RED for this shape too, #807).\n${tail(run.output)}`
    );
  }
});
test("item 6a: an ALTERED invocation line is RED (`|| true`, `|| failures=0`, changed path)", () => {
  const variants = [
    ["|| true", "node scripts/check-pi-pin-lockstep.mjs || true"],
    ["|| failures=0", "node scripts/check-pi-pin-lockstep.mjs || failures=0"],
    ["a changed script path", "node scripts/some-other-check.mjs || failures=$((failures+1))"],
  ];
  for (const [label, replacement] of variants) {
    const altered = mutate(
      FIXTURE_CI_MAIN,
      CI_MAIN_INVOCATION_LINE,
      `        ${replacement}\n`
    );
    const findings = ciMainInvocationFindings(altered);
    assert.ok(
      findings.some((m) => m.includes("no longer contains the pin-suite invocation line")),
      `${label}: expected the missing-invocation finding; got:\n  ${findings.join("\n  ")}`
    );
  }
  // #807 — the changed-path variant is invisible to item 6b as before: the
  // `node` stub fails only the PIN suite's path, so `some-other-check.mjs` exits
  // 0, nothing fails and the step exits 0. (So 6b is RED for it too now; 6a
  // remains the only assertion that can run on the trusted leg.) No 6b spawn is
  // repeated here — item 6a's assertion above is the claim under test.
});
test("item 6a: a legitimate unrelated edit elsewhere in the command still passes (GREEN)", () => {
  const edited = mutate(
    FIXTURE_CI_MAIN,
    '        echo "== scripts/check-pi-pin-lockstep.mjs =="\n',
    '        echo "== pin lockstep (relabelled) =="\n        : ""\n'
  );
  assert.deepEqual(
    ciMainInvocationFindings(edited),
    [],
    "an unrelated edit must not false-RED the invocation check"
  );
  // The live triple too: a legitimate edit elsewhere in ci-main.yml's body keeps
  // the whole fixture trio GREEN through `wiringFindings` (item 6a included).
  const liveEdited = mutate(LIVE_CI_MAIN, "        failures=0\n", "        failures=0\n        :\n");
  assert.deepEqual(
    wiringFindings(LIVE_CI, LIVE_NODE_CI, liveEdited),
    [],
    "a legitimate unrelated ci-main.yml edit must stay GREEN through every value assertion"
  );
});

// ── guard (j), item 6b — the committed post-merge step can fail ──────────────
// BEHAVIOURAL. The committed `test-command` is EXECUTED under `bash -e` with
// `node`/`npx`/`npm`/`bash` on PATH replaced by stubs. The `node` stub fails ONLY
// the pin suite (#807); every other stubbed invocation passes. The assertion is
// that the step exits NON-ZERO with ONLY the pin suite failing. What that catches
// is bounded and stated in the module header: any construct that makes the step's
// exit status depend on the pin suite's stub running to its failure — including a
// construct that stops the invocation running at all — NOT a command that merely
// keys its exit status off the stub.
section("guard (j), item 6b — the committed post-merge step can fail (behavioural)");

// #808 — the authenticated sticky child skips every real-`bash` item-6b fixture:
// the parent has already run them, and the child exists only to reach the
// terminal `process.exit(1)` decision with a forced failure. `STICKY_CHILD` is
// true only after the module-top handshake proved this run is a copy the parent
// wrote the token into (see its declaration). The child still exits 1.

// The live guard block, used as a mutation ANCHOR only (mutate() asserts it is
// present, so drift is loud). Nothing in this file parses or models it.
const LIVE_CI_MAIN_GUARD = `        if [ $failures -gt 0 ]; then
          echo "❌ $failures extension test file(s) failed"
          exit 1
        fi`;

// Required fixture 1 — the POSITIVE control: the real `ci-main.yml` with the
// "only the pin suite fails" stub must exit NON-ZERO, i.e. the assertion passes.
test("item 6b positive control: the live ci-main.yml command exits NON-ZERO with ONLY the pin suite's stub failing (#807)", () => {
  if (STICKY_CHILD) return; // #808 — the parent already ran this fixture
  assertStepCanFail("live ci-main.yml", LIVE_CI_MAIN);
});

// Required fixture 2 — the ALL-PASS control: the real `ci-main.yml` with every
// stub exiting 0 must exit 0. Without this the positive control could pass for
// the wrong reason (a missing binary, a `cd` into a non-existent directory, an
// unrelated early failure).
test("item 6b all-pass control: the live command exits 0 when every stub passes", () => {
  if (STICKY_CHILD) return; // #808 — the parent already ran this fixture
  const run = runCiMainTestCommand(LIVE_CI_MAIN, "all-pass");
  // The spawn result is checked FIRST in both directions: a `status` of null (a
  // spawn failure) must never be read as either verdict (#675 final cycle).
  assert.equal(run.error, null, `no spawn error expected: ${String(run.error)}`);
  assert.equal(typeof run.status, "number", "the passing run must report a real exit status");
  assert.equal(
    run.status,
    0,
    "the same command with every stub PASSING must exit 0. If it does not, the positive control " +
      "is passing for an unrelated reason (a missing binary, a `cd` into a directory that does " +
      `not exist, an early abort) rather than because the pin suite's failure propagated:\n` +
      tail(run.output)
  );
  assert.match(
    run.output,
    /All extension tests passed/,
    "with passing stubs the command must reach its success echo"
  );
});

// Required fixture 3 — the NEGATIVE control, and the #807 reproducer: the
// COMMITTED invocation wrapped in a multi-line quoted string. Bash treats the
// wrapped line as string content, so the pin suite never runs — but the line is
// still textually one trimmed line, so item 6a is GREEN (asserted here, so this
// fixture records the division of labour). Under the pre-#807 `all-fail` stub
// every OTHER suite still failed and the step still exited non-zero, so 6b was
// GREEN too (asserted below via the retained legacy mode). Under the #807 stub
// only the pin suite fails, so a swallowed invocation leaves NOTHING failing, the
// step reaches its success echo and exits 0, and 6b goes RED.
test("item 6b negative control (#807): the committed invocation wrapped in a multi-line quoted string makes the assertion go RED", () => {
  if (STICKY_CHILD) return; // #808 — the parent already ran this fixture
  const wrapped = mutate(
    LIVE_CI_MAIN,
    CI_MAIN_INVOCATION_LINE,
    `        echo "start\n${CI_MAIN_INVOCATION_LINE}\n        "`
  );
  assert.deepEqual(
    ciMainInvocationFindings(wrapped),
    [],
    "the wrapped line is still one trimmed line, so item 6a cannot see this shape"
  );
  const legacy = runCiMainTestCommand(wrapped, "all-fail");
  assert.equal(legacy.error, null, `no spawn error expected: ${String(legacy.error)}`);
  assert.notEqual(
    legacy.status,
    0,
    "the pre-#807 all-fail stub cannot see the swallowed invocation — this is the false GREEN " +
      "#807 reported"
  );
  assertStepCannotBeSaved("a live invocation wrapped in a multi-line quoted string", wrapped);
});

test("item 6 negative control: a guard moved inside `if false; then … fi` makes the assertion go RED", () => {
  if (STICKY_CHILD) return; // #808 — the parent already ran this fixture
  const mutated = mutate(
    LIVE_CI_MAIN,
    LIVE_CI_MAIN_GUARD,
    `        if false; then\n${reindent(LIVE_CI_MAIN_GUARD, 2)}\n        fi`
  );
  assertStepCannotBeSaved("a guard inside `if false; then … fi`", mutated);
});

test("item 6: a guard inside a never-called shell function makes the assertion go RED", () => {
  if (STICKY_CHILD) return; // #808 — the parent already ran this fixture
  const mutated = mutate(
    LIVE_CI_MAIN,
    LIVE_CI_MAIN_GUARD,
    `        run_the_guard() {\n${reindent(LIVE_CI_MAIN_GUARD, 2)}\n        }`
  );
  assertStepCannotBeSaved("a guard defined in a never-called function", mutated);
});

test("item 6: a guard hidden in a heredoc (`if false; then cat <<EOF`) makes the assertion go RED", () => {
  if (STICKY_CHILD) return; // #808 — the parent already ran this fixture
  const mutated = mutate(
    LIVE_CI_MAIN,
    LIVE_CI_MAIN_GUARD,
    `        if false; then cat <<EOF\n${LIVE_CI_MAIN_GUARD}\n        EOF\n        fi`
  );
  assertStepCannotBeSaved("a guard swallowed by a heredoc body", mutated);
});

// The three shapes below were covered by the DELETED lexical scanner and never
// had a behavioural fixture. Under "only the pin suite fails" the pin suite DOES
// run and DOES fail (so `failures=1`), but each shape leaves the GUARD dead, so
// the step reaches its success echo and exits 0 — RED.
test("item 6b: deleting the failure guard makes the assertion go RED", () => {
  if (STICKY_CHILD) return; // #808 — the parent already ran this fixture
  const mutated = mutate(LIVE_CI_MAIN, LIVE_CI_MAIN_GUARD, "");
  assertStepCannotBeSaved("a deleted failure guard", mutated);
});

test("item 6b: an `exit 0` before the failure guard makes the assertion go RED", () => {
  if (STICKY_CHILD) return; // #808 — the parent already ran this fixture
  const mutated = mutate(LIVE_CI_MAIN, LIVE_CI_MAIN_GUARD, `        exit 0\n${LIVE_CI_MAIN_GUARD}`);
  assertStepCannotBeSaved("an `exit 0` before the guard", mutated);
});

test("item 6b: a guard inside a never-taken `case` arm makes the assertion go RED", () => {
  if (STICKY_CHILD) return; // #808 — the parent already ran this fixture
  const mutated = mutate(
    LIVE_CI_MAIN,
    LIVE_CI_MAIN_GUARD,
    `        case 0 in\n          1)\n${reindent(LIVE_CI_MAIN_GUARD, 4)}\n            ;;\n        esac`
  );
  assertStepCannotBeSaved("a guard inside a never-taken `case` arm", mutated);
});

// BOUND (pinned): the #807 stub is matched on `node`'s ARGUMENTS, so a command
// that merely KEYS ITS EXIT STATUS OFF THE STUB is still not caught. This fixture
// keeps that bound visible so the module header cannot claim more than the code
// does: the real pin gate is dead (no invocation line), but a probe that names
// the pin suite makes the `node` stub exit 1, `|| exit 1` ends the step, and 6b
// reports GREEN. Item 6a is what catches this shape (the line is absent).
const PROBE_CI_MAIN = `name: CI on main
on:
  push:
    branches: [main]

jobs:
  extension-tests:
    uses: daniel-ospina/agent-infra/.github/workflows/node-ci.yml@main
    with:
      node-version: '22'
      script-validate: 'false'
      skill-lint: 'false'
      test-command: |
        failures=0
        node scripts/check-pi-pin-lockstep.mjs --version >/dev/null 2>&1 || exit 1
        if [ $failures -gt 0 ]; then
          echo "❌ $failures extension test file(s) failed"
          exit 1
        fi
        echo "✅ All extension tests passed"
    secrets: inherit
`;

test("item 6b BOUND (pinned): a command that only keys its exit status off the STUB is still not caught", () => {
  if (STICKY_CHILD) return; // #808 — the parent already ran this fixture
  const run = runCiMainTestCommand(PROBE_CI_MAIN, "pin-suite-only-fails");
  assert.equal(run.error, null, `no spawn error expected: ${String(run.error)}`);
  assert.notEqual(
    run.status,
    0,
    "the stub-keyed probe is expected to keep item 6b GREEN — that is the documented bound, not " +
      "a regression; if this is now RED the bound has been closed and the module header's " +
      "\"WHAT 6b CATCHES\" paragraph must move with it"
  );
  assert.ok(
    ciMainInvocationFindings(PROBE_CI_MAIN).length > 0,
    "item 6a is the assertion that catches this shape, because its invocation line is absent"
  );
});

test("item 6: a quoted `<<` no longer arms a phantom heredoc (GREEN, no false RED)", () => {
  if (STICKY_CHILD) return; // #808 — the parent already ran this fixture
  const mutated = mutate(
    LIVE_CI_MAIN,
    "        failures=0\n",
    '        failures=0\n        echo "a <<x"\n'
  );
  // The DELETED lexical scanner read the `<<x` inside those quotes as a heredoc
  // opener, skipped the rest of the command as heredoc body and RED-ed a
  // legitimate file (measured on the previous revision: `ciMainFindings()` →
  // one "sits inside a heredoc" finding). Executing the command removes the whole
  // class — nothing here models `<<` any more.
  const run = assertStepCanFail('a quoted `echo "a <<x"`', mutated);
  assert.notEqual(run.status, 0, "the pin suite's failure must still trip the guard");
});

// ── item 6b HYGIENE — the assertion must fail CLOSED on its OWN failures ─────
// Three reproduced defects, each of which turned "nothing was measured" into "the
// guarantee holds". These drive the same code path the live assertion uses (the
// seam arguments exist for exactly this); production callers pass neither.
test("item 6b hygiene: an unresolvable bash is RED with the spawn-failure message (never a pass)", () => {
  if (STICKY_CHILD) return; // #808 — the parent already ran this fixture
  // Reproduces the fail-open exactly: spawnSync("/nonexistent/bash", …) returns
  // { status: null, error: ENOENT }, and the old `assert.notEqual(status, 0)`
  // PASSED for it — "nothing executed" recorded as "the step exits non-zero".
  assert.throws(
    () =>
      assertStepCanFail("a missing bash interpreter", LIVE_CI_MAIN, {
        bashPath: "/nonexistent/pin-item6-bash",
      }),
    /could not be SPAWNED at all/,
    "a spawn failure must be RED with its own message, not recorded as a non-zero exit"
  );
});
test("item 6b hygiene: a command that cannot finish is RED at the explicit spawn timeout", () => {
  if (STICKY_CHILD) return; // #808 — the parent already ran this fixture
  const hanging = mutate(
    FIXTURE_CI_MAIN,
    CI_MAIN_INVOCATION_LINE,
    "        sleep 30\n        node scripts/check-pi-pin-lockstep.mjs || failures=$((failures+1))"
  );
  assert.throws(
    () => assertStepCanFail("a hanging command", hanging, { timeoutMs: 1000 }),
    /did not finish within 1000 ms/,
    "an unfinished run is not evidence that the step can fail — it is its own RED result"
  );
});

// ── (k) workflow-yaml reader — subset behaviour & fail-closed bounds ───────
// The reader (scripts/workflow-yaml.mjs) is the only surface the narrow guard
// (j) leans on, so its subset contract is asserted here directly: the constructs
// the guard needs parse, the constructs it does not model THROW (fail-closed),
// and the repo's whole live workflow corpus parses (the subset is adequate today).
section("workflow-yaml reader — subset behaviour and fail-closed bounds");

const throws = (src) => {
  try {
    parseWorkflowYaml(src);
    return false;
  } catch (err) {
    assert.ok(err instanceof WorkflowYamlError, `expected a WorkflowYamlError, got ${err}`);
    return true;
  }
};

test("block mappings, sequences, compact mappings and flow collections parse", () => {
  assert.deepEqual(parseWorkflowYaml("a: 1\nb:\n  c: 2\nd:\n  - x\n  - y: 3\n    z: 4\n"), {
    a: "1",
    b: { c: "2" },
    d: ["x", { y: "3", z: "4" }],
  });
  assert.deepEqual(parseWorkflowYaml("on: [a, b]\nn: {x: 1, y: [2, 3]}\n"), {
    on: ["a", "b"],
    n: { x: "1", y: ["2", "3"] },
  });
});

test("scalars are NOT type-resolved — `on` is a key, `false` is the string", () => {
  const doc = parseWorkflowYaml("on:\n  pull_request:\nflag: false\nn: 12\n");
  assert.ok(Object.hasOwn(doc, "on"), "`on` must stay the key `on` (no YAML-1.1 bool coercion)");
  assert.equal(doc.flag, "false");
  assert.equal(doc.n, "12");
});

test("quoted keys are dequoted, `key :` spacing accepted, `#` in quotes kept", () => {
  assert.deepEqual(parseWorkflowYaml('"a": 1\nb : 2\nc: "x # y" # comment\n'), {
    a: "1",
    b: "2",
    c: "x # y",
  });
});

test("a block-scalar body is never interpreted as structure", () => {
  const doc = parseWorkflowYaml(
    "run-name: |\n  jobs:\n    ci:\n      uses: evil\njobs:\n  ci:\n    uses: good\n"
  );
  assert.deepEqual(Object.keys(doc.jobs), ["ci"]);
  assert.equal(doc.jobs.ci.uses, "good");
  assert.match(doc["run-name"], /jobs:/);
});

test("a sequence at its parent key's column parses (parent-indent steps)", () => {
  assert.deepEqual(parseWorkflowYaml("steps:\n- a: 1\n- b: 2\n"), {
    steps: [{ a: "1" }, { b: "2" }],
  });
});

test("comments (full-line and trailing) are dropped", () => {
  assert.deepEqual(parseWorkflowYaml("# lead\na: 1 # trail\n\n# tail\n"), { a: "1" });
});

test("fail-closed: tab indentation, anchors/aliases/tags, `- - x`, multi-line plain scalars", () => {
  assert.ok(throws("a:\n\tb: 1\n"), "tab indentation");
  assert.ok(throws("a: &x 1\n"), "anchor");
  assert.ok(throws("a: *x\n"), "alias");
  assert.ok(throws("a: !!str x\n"), "tag");
  assert.ok(throws("a:\n  - - x\n"), "nested inline sequence");
  assert.ok(throws("a: one\n  two\n"), "multi-line plain scalar");
});

test("fail-closed: duplicate keys, multi-document streams, invalid block headers", () => {
  assert.ok(throws("a: 1\na: 2\n"), "duplicate key");
  assert.ok(throws("---\na: 1\n---\nb: 2\n"), "multi-document stream");
  assert.ok(throws("a: | extra\n  body\n"), "invalid block header");
});

// #675 P1-1 — escapes. Decoding is a correctness requirement (the guard reads
// KEYS out of quoted scalars), and anything unmodelled must THROW.
test("double-quote escapes are decoded and unmodelled ones THROW (fail-closed)", () => {
  assert.deepEqual(parseWorkflowYaml('"paths\\u002dignore":\n  - "*.md"\n'), {
    "paths-ignore": ["*.md"],
  });
  assert.deepEqual(parseWorkflowYaml('a: "x\\ty"\n'), { a: "x\ty" });
  assert.deepEqual(parseWorkflowYaml('n: {"a\\u002db": 1}\n'), { n: { "a-b": "1" } });
  assert.deepEqual(parseWorkflowYaml('q: "a\\\\b"\n'), { q: "a\\b" });
  assert.deepEqual(parseWorkflowYaml('r: ["p\\u002dignore", x]\n'), { r: ["p-ignore", "x"] });
  assert.ok(throws('a: "x\\qy"\n'), "unmodelled escape");
  assert.ok(throws('a: "x\\u12"\n'), "short \\u escape");
  assert.ok(throws('a: "x\\uZZZZ"\n'), "non-hex \\u escape");
  assert.ok(throws('a: "x\\U00110000"\n'), "out-of-range \\U escape");
  assert.ok(throws('a: ["x\\q"]\n'), "unmodelled escape inside a flow sequence");
});

// #675 P2-4 — block-scalar indentation comes from the FIRST content line.
test("a block scalar dedented below its first content line THROWS", () => {
  assert.ok(throws("run: |\n    a\n  b\n"), "dedent below the first content line");
  assert.deepEqual(parseWorkflowYaml("run: |2\n    a\n  b\n"), { run: "  a\nb" });
});

// #675 P2-3 — the trailing-newline trim was quadratic on a long blank-line run
// (120 KB crafted input → 41 s of CI, PR-controlled). A generous wall-clock
// bound is the only way a unit test can catch a reintroduction; the linear form
// finishes this in single-digit milliseconds.
test("a large interior blank-line run parses in linear time (no quadratic trim)", () => {
  const blankLines = 20000;
  const src =
    "name: X\nrun-name: |\n  content\n" + "\n".repeat(blankLines) + "  content\njobs:\n  ci:\n    uses: x\n";
  const started = Date.now();
  const doc = parseWorkflowYaml(src);
  const elapsed = Date.now() - started;
  assert.equal(doc.name, "X");
  assert.ok(doc["run-name"].startsWith("content"), "body keeps its first content line");
  assert.ok(doc["run-name"].endsWith("content"), "body keeps its last content line");
  assert.ok(
    Object.hasOwn(doc.jobs, "ci"),
    "the mapping after the block scalar is still parsed"
  );
  assert.ok(
    elapsed < 5000,
    `expected a linear parse of ${blankLines} blank lines, took ${elapsed}ms ` +
      "(the removed quadratic trim took ~8s+)"
  );
});

// #675 P2-6 — the flow path was O(depth × length): `key: [[[[…]]]]` measured
// 3.5 s at 10 KB, 14.3 s at 40 KB and 61.5 s at 104 KB, ending in a RangeError.
// The reader is now a single-pass flow parser with a bounded recursion depth, so
// a deeply nested flow document raises WorkflowYamlError FAST — never a
// RangeError, and never minutes of CI on PR-controlled bytes.
test("a deeply nested flow collection raises WorkflowYamlError quickly (#675 P2-6)", () => {
  const deep = "key: " + "[".repeat(20000) + "]".repeat(20000) + "\n";
  const started = Date.now();
  assert.ok(throws(deep), "deep flow nesting must raise WorkflowYamlError");
  const elapsed = Date.now() - started;
  assert.ok(elapsed < 5000, `expected a fast, clean rejection, took ${elapsed}ms`);
  // The 104 KB shape that took 61.5 s pre-fix (also the size that ends in a stack
  // overflow), and a mapping variant.
  const wide = "key: " + "[".repeat(53000) + "]".repeat(53000) + "\n";
  const t2 = Date.now();
  assert.ok(throws(wide), "a 104 KB flow document must also raise WorkflowYamlError");
  assert.ok(Date.now() - t2 < 5000, "104 KB flow nesting must reject fast");
  const map = "key: " + "{".repeat(20000) + "}".repeat(20000) + "\n";
  assert.ok(throws(map), "deep flow mapping nesting must also raise WorkflowYamlError");
});

test("the live workflow corpus parses (the subset is adequate for this repo)", () => {
  // #675 P2-6 — per-directory floors, not one loose total: the live corpus is
  // 9 + 4, and a single `>= 8` total let a 33% shrink (one directory emptied)
  // pass. Growth is fine; a silently emptied directory is not.
  const dirs = [
    { dir: path.join(REPO_ROOT, ".github", "workflows"), min: 8 },
    { dir: path.join(REPO_ROOT, "templates", ".github", "workflows"), min: 4 },
  ];
  const files = [];
  for (const { dir, min } of dirs) {
    // #675 third revision (P2) — `/\.ya?ml$/`, matching the lock's own
    // classification: a `.yaml` workflow is a workflow GitHub runs, so it must be
    // inside the reader's subset too.
    const names = fs.readdirSync(dir).filter((name) => /\.ya?ml$/.test(name));
    assert.ok(
      names.length >= min,
      `expected at least ${min} workflows in ${path.relative(REPO_ROOT, dir)}, found ${names.length}`
    );
    for (const name of names) files.push(path.join(dir, name));
  }
  const failures = [];
  for (const file of files) {
    try {
      const doc = parseWorkflowYaml(fs.readFileSync(file, "utf8"));
      assert.ok(isMap(doc), "reads as a mapping");
    } catch (err) {
      failures.push(`${path.relative(REPO_ROOT, file)}: ${err.message}`);
    }
  }
  assert.deepEqual(failures, [], "every committed workflow must be inside the reader's subset");
});

// #675 P2-h — the floor + roster must run on EVERY exit path. Inserting
// `process.exit(0)` in the suite used to exit 0 with ZERO ✅ lines because the
// floor/roster were evaluated only at the very end of the module body.
//
// The `exit` handler that evaluates them is registered at the TOP of this module
// (immediately after the `--head-ref` flag is computed, before every other
// module-level binding), and it CONVERTS a TDZ failure into a non-zero exit
// rather than letting it escape: an uncaught throw inside an `exit` listener does
// NOT override a pending `process.exit(0)` (measured), so `finalize()` is called
// inside a try/catch that sets `process.exitCode = 1`. Both injection points are
// exercised — mid-suite (the old fixture) and the TOP of the module body, which is
// the earliest point the handler can catch.
test("an early `process.exit(0)` in the suite still exits non-zero (#675 P2-h)", () => {
  const injections = [
    [
      "the middle of the suite (before the first control test)",
      'test("pinFindings flags a drifted pin (positive control for (h))"',
    ],
    ["the TOP of the module body (the earliest catchable point)", "const REPO_ROOT = path.resolve("],
  ];
  for (const [label, anchor] of injections) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "pin-suite-exit-"));
    try {
      for (const rel of [
        "check-pi-pin-lockstep.mjs",
        "frontmatter-fixtures.mjs",
        "workflow-yaml.mjs",
        "check-workflow-lock.mjs",
      ]) {
        fs.copyFileSync(path.join(REPO_ROOT, "scripts", rel), path.join(dir, rel));
      }
      const suite = path.join(dir, "check-pi-pin-lockstep.mjs");
      const src = fs.readFileSync(suite, "utf8");
      assert.ok(src.includes(anchor), `early-exit fixture anchor not found (${label}): ${anchor}`);
      fs.writeFileSync(suite, mutate(src, anchor, `process.exit(0);\n${anchor}`));
      const res = spawnSync(process.execPath, [suite], { encoding: "utf8" });
      assert.equal(
        res.status,
        1,
        `an early process.exit(0) injected at ${label} must still exit non-zero (the floor + ` +
          `roster must run on every exit path); got status ${res.status}, ` +
          `stdout=${JSON.stringify(res.stdout.slice(0, 200))}`
      );
      // Both fail-closed routes are acceptable and both are RED: the roster/floor
      // verdict from `finalize()`, or the TDZ catch in the exit handler.
      assert.match(
        res.stderr,
        /only 0 passing tests|required test\(s\) did not run|exited before its floor and roster/,
        `the exit handler must name why it failed; stderr=${JSON.stringify(res.stderr)}`
      );
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  }
});

// ── the accepted RESIDUAL, PINNED — same-file module code can still flip it ──
// The `exit` handler makes an early exit RED, and the terminal `process.exit(1)`
// makes the decision sticky against anything registered AFTER it. Neither can
// defend against module-level code IN THIS FILE that registers a listener BEFORE
// the decision and rewrites `process.exitCode` (or does
// `process.removeAllListeners("exit")` + `process.exit(0)`, which is fully
// silent). That is the same accepted same-commit class as the lock and the roster
// body-rewrite residual: the file a PR can edit is the file that decides.
//
// This fixture exists so the limitation is PINNED AND VISIBLE: it reproduces the
// flip and fails loudly if the code is ever hardened, so the module header, this
// fixture's name and the plan's accepted-residual section must move together.
test("RESIDUAL (pinned, not a guarantee): module-level code in THIS file can still flip a failing run to 0 (#675 final cycle)", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "pin-suite-residual-"));
  try {
    for (const rel of [
      "check-pi-pin-lockstep.mjs",
      "frontmatter-fixtures.mjs",
      "workflow-yaml.mjs",
      "check-workflow-lock.mjs",
    ]) {
      fs.copyFileSync(path.join(REPO_ROOT, "scripts", rel), path.join(dir, rel));
    }
    const suite = path.join(dir, "check-pi-pin-lockstep.mjs");
    const src = fs.readFileSync(suite, "utf8");
    const anchor = 'test("pinFindings flags a drifted pin (positive control for (h))"';
    assert.ok(src.includes(anchor), `residual fixture anchor not found: ${anchor}`);
    // The listener is registered BEFORE the terminal decision, so it is
    // REACHABLE — this is the distinguishing property. The early exit stands in
    // for a failing run: `finalize()` sees 0 passing and takes the failure path
    // before the listener rewrites the code.
    const mutated = mutate(
      src,
      anchor,
      `process.on("exit", () => { process.exitCode = 0; });\nprocess.exit(0);\n${anchor}`
    );
    fs.writeFileSync(suite, mutated);
    const res = spawnSync(process.execPath, [suite], { encoding: "utf8" });
    assert.equal(
      res.status,
      0,
      "the DOCUMENTED BOUND is that module-level code in the same file can still override the " +
        `verdict; this run exited ${res.status}. If it is now non-zero the verdict has been ` +
        "hardened — upgrade this pinned residual, the module header's trust split and the plan's " +
        "accepted-residual section together."
    );
    assert.match(
      res.stderr,
      /only 0 passing tests|required test\(s\) did not run/,
      "the run must actually have taken the FAILURE path before the listener flipped the code, " +
        `otherwise this fixture proves nothing; stderr=${JSON.stringify(res.stderr)}`
    );
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

// #675 third revision (P2) — the failure decision must be TERMINAL. `finalize()`
// runs eagerly at EOF and sets `process.exitCode = 1`, but `process.exitCode` is
// last-writer-wins across `exit` listeners, so a later-registered listener that
// writes 0 converted a failing run to exit 0 while still printing the failure.
// The EOF path therefore calls `process.exit(1)` when there are failures, which
// terminates before any code appended after that point can register such a
// listener. (If this test's stdout assertion ever fails, `process.exit` truncated
// the summary — that is why the assertion is there.)
//
// ── the sticky fixture's skip handshake — every branch pinned ────────────────
// The forge this closes: `PIN_STICKY_FIXTURE_DEPTH=1 node scripts/check-pi-pin-lockstep.mjs`
// (or any other value) used to print `105 passed, 0 failed`, exit 0, with a
// REQUIRED roster test doing nothing. The guard is now a handshake and it FAILS
// CLOSED: the same command is RED, and RED immediately, because the guard runs at
// module-evaluation time, before any test.
test("the sticky fixture's skip handshake fails CLOSED for a forged or stale token (#675 final cycle)", () => {
  const token = "a".repeat(48);
  const genuine = {
    claimed: token,
    ownSource: `x\n/* PIN_STICKY_FIXTURE_TOKEN=${token} */\n`,
    repoRoot: "/tmp/pin-suite-sticky-x",
    markerText: JSON.stringify({ token }),
  };
  assert.deepEqual(
    stickyFixtureHandshakeProblems(genuine),
    [],
    "a genuine child — the token baked into its own source AND in the marker at its own root — passes"
  );
  const forged = [
    ["a guessed value with no baked token", { ...genuine, claimed: "1" }],
    ["an empty token", { ...genuine, claimed: "" }],
    [
      "a marker carrying a different token",
      { ...genuine, markerText: JSON.stringify({ token: "b".repeat(48) }) },
    ],
    ["no marker at the root at all", { ...genuine, markerText: null }],
    ["a marker that is not JSON", { ...genuine, markerText: "not json" }],
    ["a source with no baked token", { ...genuine, ownSource: "irrelevant" }],
  ];
  for (const [label, view] of forged) {
    assert.notDeepEqual(
      stickyFixtureHandshakeProblems(view),
      [],
      `${label}: the handshake must fail closed — a skipped test is never a passing test`
    );
  }
});
test("the sticky-fixture forge is RED end-to-end: the ambient env var alone no longer skips anything", () => {
  // The EXACT reproducer, against the real file. The guard runs at
  // module-evaluation time, so this exits immediately instead of running the suite.
  const res = spawnSync(
    process.execPath,
    [path.join(REPO_ROOT, "scripts", "check-pi-pin-lockstep.mjs")],
    { encoding: "utf8", timeout: 60_000, env: { ...process.env, [STICKY_FIXTURE_ENV]: "1" } }
  );
  assert.equal(
    res.status,
    1,
    "setting the sticky-fixture marker from outside the file must be RED — never the silent " +
      "`105 passed, 0 failed`, exit 0 it used to produce"
  );
  assert.match(res.stderr, /cannot prove it is the sticky fixture's child/);
  assert.doesNotMatch(`${res.stdout}${res.stderr}`, /✅ ALL TESTS PASSED/);
});

// #675 FINAL CYCLE — the test NAME is part of the claim (see `STICKY_TEST_NAME`
// near the top): sticky against everything registered AFTER the terminal
// decision, i.e. against anything OUTSIDE this file. See the residual fixture for
// the same-file listener that CAN still flip it.
test(STICKY_TEST_NAME, () => {
  if (process.env[STICKY_FIXTURE_ENV] !== undefined) {
    // This run IS the fixture copy — the module-top handshake proved it. Running
    // the fixture inside the fixture would recurse without bound. The copy
    // already proves what it needs to. A forged marker never reaches here: the
    // module-top guard exits 1 first.
    return;
  }
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "pin-suite-sticky-"));
  // The per-run token the child must show in BOTH places. Generated here, so it
  // cannot be pre-guessed from outside; written only into the child copy and the
  // marker, so an ambient env var can never satisfy the handshake.
  const token = randomBytes(24).toString("hex");
  try {
    // The full suite copy must be able to read everything it asserts over, so the
    // fixture root mirrors the repo's READ surface (never the live `.github`, which
    // the ancestor-symlink guard would reject if it were linked rather than copied).
    fs.cpSync(path.join(REPO_ROOT, ".github"), path.join(dir, ".github"), { recursive: true });
    fs.cpSync(path.join(REPO_ROOT, "templates"), path.join(dir, "templates"), { recursive: true });
    fs.cpSync(path.join(REPO_ROOT, "scripts"), path.join(dir, "scripts"), { recursive: true });
    fs.mkdirSync(path.join(dir, "docs"), { recursive: true });
    fs.copyFileSync(
      path.join(REPO_ROOT, "docs/providers.md"),
      path.join(dir, "docs/providers.md")
    );
    for (const entry of fs.readdirSync(path.join(REPO_ROOT, "extensions"), { withFileTypes: true })) {
      if (!entry.isDirectory()) continue;
      const rel = path.join("extensions", entry.name, "package.json");
      const from = path.join(REPO_ROOT, rel);
      if (!fs.existsSync(from)) continue;
      fs.mkdirSync(path.dirname(path.join(dir, rel)), { recursive: true });
      fs.copyFileSync(from, path.join(dir, rel));
    }
    const qwen = path.join("extensions/custom-provider-qwen/index.ts");
    fs.mkdirSync(path.dirname(path.join(dir, qwen)), { recursive: true });
    fs.copyFileSync(path.join(REPO_ROOT, qwen), path.join(dir, qwen));
    const suite = path.join(dir, "scripts", "check-pi-pin-lockstep.mjs");
    const src = fs.readFileSync(suite, "utf8");
    const at = src.lastIndexOf("\nfinalize();");
    assert.ok(at > 0, "the end-of-module `finalize();` call was not found");
    // The handshake, half one: the marker at the child's OWN root.
    fs.writeFileSync(path.join(dir, STICKY_FIXTURE_MARKER), JSON.stringify({ token }));
    // Force a failure, bake the handshake's other half into the child's OWN
    // source, then append exactly what a same-commit edit would use to flip the
    // verdict back to 0.
    const mutated =
      `${src.slice(0, at + 1)}/* ${STICKY_FIXTURE_TOKEN_PREFIX}${token} */\nfailed++;\n` +
      `${src.slice(at + 1)}\n` +
      'process.on("exit", () => { process.exitCode = 0; });\n';
    fs.writeFileSync(suite, mutated);
    const res = spawnSync(process.execPath, [suite], {
      encoding: "utf8",
      maxBuffer: 32 * 1024 * 1024,
      env: { ...process.env, [STICKY_FIXTURE_ENV]: token },
    });
    assert.equal(
      res.status,
      1,
      `a later \`exit\` listener writing process.exitCode = 0 must NOT flip a failing run; got ` +
        `status ${res.status} (stderr tail: ${tail(res.stderr, 4)})`
    );
    assert.match(
      res.stdout,
      /check-pi-pin-lockstep\.mjs: \d+ passed, \d+ failed/,
      "the run summary (stdout) must still be printed in full — a truncated summary would mean " +
        "`process.exit(1)` swallowed it"
    );
    assert.match(
      res.stderr,
      /SOME TESTS FAILED/,
      "the failure verdict must still reach stderr; a truncated verdict would mean " +
        "`process.exit(1)` swallowed it"
    );
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

// #675 P2-h / third revision — the floor + roster live at the top of this file and
// are registered on the `exit` event there; calling `finalize()` here prints the
// summary in the normal path too (the latch inside keeps it once-only). The
// `process.exit(1)` below is the TERMINAL failure decision described above: it
// runs before any code appended after this line can register an `exit` listener.
finalize();
if (failed > 0) process.exit(1);
