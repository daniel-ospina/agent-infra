#!/usr/bin/env node
/**
 * check-pi-pin-lockstep.mjs — single-purpose CI suite for the #637 pi-pin
 * lockstep tripwires (h)/(i)/(j). Extracted from check-skill-lint.test.mjs by
 * #666 (plan alternative F) so the pin guards have a home of their own.
 *
 * SCOPE — the three pin-lockstep guards and nothing else:
 *   (h) extension pi-package pins lockstep with PI_VERSION_PIN
 *   (i) hand-synced mirror version stamps match PI_VERSION_PIN
 *   (j) the per-PR pin gate is still wired into .github/workflows/ci.yml →
 *       node-ci.yml AND the post-merge invocation in ci-main.yml is still there
 * The #254 frontmatter-validator suite stays in scripts/check-skill-lint.test.mjs.
 * This suite does NOT import pi (the dev-machine oracle owns pi parity).
 *
 * Run: node scripts/check-pi-pin-lockstep.mjs
 *
 * WIRING (#675 P1-5): ci.yml passes the failure-accumulator `test-command`
 *   `a=0; node scripts/check-skill-lint.test.mjs || a=$?; b=0; node scripts/check-pi-pin-lockstep.mjs || b=$?; [ $a -eq 0 ] && [ $b -eq 0 ]`
 * to the reusable node-ci.yml (its unit-test job is SKIPPED when that input is
 * empty), and ci-main.yml's post-merge accumulator runs this suite too. Guard (j)
 * asserts BOTH halves: the `ci.yml → node-ci.yml` wiring and the ci-main.yml
 * invocation. The old design had the "cannot be left unwired" property by
 * construction; a guard reading only the per-PR caller could be unwired on main
 * in silence, so the assertion covers both paths rather than the header claiming
 * both while one was unasserted.
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

import { strict as assert } from "node:assert";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { PI_VERSION_PIN } from "./frontmatter-fixtures.mjs";
import { parseWorkflowYaml, WorkflowYamlError } from "./workflow-yaml.mjs";

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const CI_YML = path.join(REPO_ROOT, ".github", "workflows", "ci.yml");
const NODE_CI_YML = path.join(REPO_ROOT, ".github", "workflows", "node-ci.yml");
const CI_MAIN_YML = path.join(REPO_ROOT, ".github", "workflows", "ci-main.yml");

let passed = 0;
let failed = 0;

function test(name, fn) {
  try {
    fn();
    passed++;
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

const isMap = (v) => v !== null && typeof v === "object" && !Array.isArray(v);

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
// STAMP-CONTEXT line of these four hand-synced surfaces must be PI_VERSION_PIN or a listed non-pi
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
// stamp when its own line carries a pi/stamp keyword (a stale stamp reworded onto a keyword-free line
// is invisible); the allowlist is keyed by version STRING rather than occurrence; and version-specific
// LINE REFERENCES are deliberately not asserted — they move within a version and must be re-derived
// by hand (see #651).
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
// A version literal counts as a STAMP only on a line that talks about the pin:
// the version word, a pi package, a probe, a devDep pin, or "verified against".
// This is what keeps an unrelated literal (a Node floor, a runner image tag, a
// changelog fragment) from being read as a pi stamp (#675 P1-4).
const STAMP_CONTEXT_RE = /\bpi\b|pi-ai|pi-coding-agent|probe|devDep|verified against|version|parity/i;
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
    if (!STAMP_CONTEXT_RE.test(line)) return;
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

// ── (j) per-PR wiring is not silently unplugged ────────────────────────────
// #637 wires the suites into the PR path with `with: test-command:` → the reusable node-ci.yml, whose
// unit-test job is SKIPPED when that input is empty. The silently-green paths guarded here are:
//   (1) the `with:` binding on the node-ci.yml call is removed or emptied — the input falls back to
//       '', the job's `if:` is false, and every PR is green with zero pin check;
//   (2) the `unit-test` job or its activation predicate stops consuming `inputs.test-command`;
//   (3) an added conjunct makes a predicate unsatisfiable (`&& false`, or a push-only event guard on a
//       pull_request-only workflow) — the predicate is present but the job never runs;
//   (4) the step runs the input but swallows its failure (`|| true`, `continue-on-error: true`), so
//       the job is green even when the suite fails; and
//   (5) the CALLER job gets its own `if:`/`continue-on-error:` — the most natural way to "temporarily"
//       disable a workflow, and invisible to a callee-only check; and
//   (6) the WORKFLOW TRIGGER gains a filter, or stops being `pull_request` — the outermost bypass:
//       the job block is never evaluated, so every job-level guard above stays green while the gate
//       is skipped for exactly the PRs it guards (`paths-ignore: ['extensions/**']`).
// The `test-command` value must be EXACTLY the suite invocations: a `|| true` suffix would leave every
// assertion in this suite passing while the gate can never go red.
//
// #666 — these assertions read PARSED NODES (scripts/workflow-yaml.mjs), not normalized workflow text.
// Three text-matching generations were defeated by YAML's own syntax and each fix added a hand-rolled
// normalizer; the reproductions were: `"paths-ignore":`/`'paths-ignore':` (quoted keys),
// `continue-on-error :` / `if : false` (space before the colon), `run: ${{ inputs.test-command }} ||
// true`, a decoy `# historical: run: ${{ … }}` comment line carrying the match, an unanchored `uses:`
// substring, a dead `- if: false` step carrying the expected `run:` text, a `test-command:` line
// inside another mapping's block scalar, and an injected fake `ci:` job inside a `run-name: |` scalar.
// With node reads a decoy inside a scalar is not a node, a dead step's `run:` is read as its own step,
// and a `with:` mapping is asserted by its own key set — the reproductions are fixture tests below
// (see "guard (j) — YAML-valid bypass attempts").
//
// NOT guarded, accepted bounds (stated, not claimed closed):
//   * a typo'd/renamed input name fails LOUDLY on GitHub (undeclared workflow_call inputs are
//     rejected), so it needs no static guard;
//   * the callee read here is the BRANCH-LOCAL node-ci.yml while ci.yml executes `@main` — a main-side
//     change to a stale branch is invisible. The real proof of the @main binding is the live per-PR
//     run (`ci / unit-test` must show "run", not "skipping");
//   * a same-commit crafted edit of both the guard and the workflow is out of scope for any test that
//     reads repo files — branch protection is the control (#646);
//   * `continue-on-error` is only treated as harmless when the value is the literal `false`: the
//     reader does not resolve YAML scalar types, so `no`/`off`/`0` are reported (loud, never silent).
//     CONFIRMED SAFE (#675 P3): the reader cannot distinguish the boolean `false` from the quoted
//     string `"false"`, but it does not need to — the canonical workflow schema types
//     `continue-on-error` as a BOOLEAN at both levels (`actions/languageservices`
//     `workflow-parser/src/workflow-v1.0.json`: `boolean-strategy-context` for `job`,
//     `step-continue-on-error` for steps — the older `actions/runner`
//     `src/Sdk/DTPipelines/workflow-v1.0.json` copy likewise), and the runner-side converter asserts
//     it (`PipelineTemplateConverter.ConvertToStepContinueOnError` → `AssertBoolean`). A quoted
//     `"false"` is therefore a workflow-validation ERROR, not a truthy coercion, so the reader's
//     string-typed `"false"` can never be the thing that silently disables the gate.
section("per-PR pin gate is wired (not silently skipped)");

const EXPECTED_USES = "daniel-ospina/agent-infra/.github/workflows/node-ci.yml@main";
// #675 P2-2 — a FAILURE ACCUMULATOR, not `&&`. `&&` short-circuits, so a
// frontmatter-validator failure would skip this suite and its verdict would never
// be produced for that PR. The `||` form (rather than `cmd; a=$?;`) is required
// because GitHub's default Linux shell is `bash -e {0}`: under `set -e` a bare
// failing `node` aborts the script before `a=$?` runs, reintroducing the
// short-circuit. Both suites always run; the step still fails if either did.
const EXPECTED_TEST_COMMAND =
  "a=0; node scripts/check-skill-lint.test.mjs || a=$?; b=0; node scripts/check-pi-pin-lockstep.mjs " +
  "|| b=$?; [ $a -eq 0 ] && [ $b -eq 0 ]";
const EXPECTED_JOB_IF = "inputs.test-command != '' || inputs.test-glob != ''";
const EXPECTED_STEP_IF = "inputs.test-command != ''";
const EXPECTED_RUN_INPUT = "${{ inputs.test-command }}";
const EXPECTED_RUN_GLOB = "node --test ${{ inputs.test-glob }}";
const CALLER_USES_LINE = `    uses: ${EXPECTED_USES}`;
const CUSTOM_STEP_LINE = "      - name: Custom test command\n";
const CUSTOM_STEP_RUN_CLEAN = "        run: ${{ inputs.test-command }}\n";
// #675 P1-2 — the ONLY keys the step that runs `test-command` may carry. Every
// one of these is inert with respect to EXECUTING the command; anything else
// (`uses`, a re-declared `continue-on-error`, …) can no-op the step while its
// `if`/`run` read byte-identical. `shell` is allowed here but its VALUE is
// constrained by ACCEPTABLE_SHELLS below (`true {0}` is not a shell that runs it).
const CUSTOM_STEP_KEYS = new Set(["name", "if", "working-directory", "run", "env", "shell"]);
const ACCEPTABLE_SHELLS = new Set(["bash", "sh"]);
const TRIGGER_FILTERS = ["paths", "paths-ignore", "branches", "branches-ignore", "types"];

/** `continue-on-error` is dangerous only when it can be truthy (literal `false` is a no-op). */
function truthyFlag(map, key) {
  if (!isMap(map) || !Object.hasOwn(map, key)) return false;
  const v = map[key];
  return !(typeof v === "string" && v.toLowerCase() === "false");
}

/**
 * Evaluate the per-PR pin-gate wiring from two workflow SOURCES.
 * → [] when the gate is wired, else one message per broken invariant.
 */
function wiringFindings(callerSrc, calleeSrc) {
  const f = [];
  let caller;
  let callee;
  try {
    caller = parseWorkflowYaml(callerSrc);
    callee = parseWorkflowYaml(calleeSrc);
  } catch (err) {
    const detail = err instanceof WorkflowYamlError ? err.message : String(err.message ?? err);
    return [
      "the workflow could not be read by the supported YAML subset reader " +
        `(scripts/workflow-yaml.mjs): ${detail} — extend that reader deliberately; do NOT ` +
        "fall back to text matching (that is the #637 bypass class)",
    ];
  }
  if (!isMap(caller) || !isMap(callee)) {
    return ["a workflow document did not read as a top-level mapping"];
  }

  // (1) The trigger. The outermost bypass: a filter skips the whole run, so every
  // assertion below would be green while the gate is skipped for exactly the PRs
  // it guards. `on` may be a mapping (`pull_request:`), a scalar (`on: pull_request`)
  // or a flow sequence (`on: [pull_request]`) — all three are valid and GREEN.
  if (!Object.hasOwn(caller, "on")) {
    f.push("ci.yml no longer declares a top-level `on:` trigger");
  } else {
    const on = caller.on;
    let found = false;
    let prNode = null;
    if (typeof on === "string") found = on === "pull_request";
    else if (Array.isArray(on)) found = on.includes("pull_request");
    else if (isMap(on)) {
      found = Object.hasOwn(on, "pull_request");
      prNode = on.pull_request ?? null;
    } else {
      f.push("ci.yml's `on:` is neither a mapping, a flow sequence nor a scalar");
    }
    if (!found) {
      f.push(
        "ci.yml must still run on `pull_request` — otherwise the per-PR pin gate never fires"
      );
    } else if (isMap(prNode)) {
      for (const filter of TRIGGER_FILTERS) {
        if (Object.hasOwn(prNode, filter)) {
          f.push(
            `ci.yml's \`pull_request:\` gained \`${filter}:\` — that skips the whole workflow (and ` +
              "therefore the pin gate) for exactly the PRs it guards (#637)"
          );
        }
      }
    } else if (prNode !== null && typeof prNode !== "string") {
      f.push("ci.yml's `pull_request:` value is neither a mapping nor empty");
    }
  }

  // (2) The caller job and its binding.
  const callerJob = isMap(caller.jobs) && isMap(caller.jobs.ci) ? caller.jobs.ci : null;
  if (!callerJob) {
    f.push("ci.yml no longer defines a `ci:` job in its `jobs:` mapping");
  } else {
    if (callerJob.uses !== EXPECTED_USES) {
      f.push(
        `the \`ci:\` job in ci.yml must call \`${EXPECTED_USES}\` exactly — found ` +
          `${JSON.stringify(callerJob.uses ?? null)} (a decoy \`uses:\` substring elsewhere on a ` +
          "line does not count)"
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
    if (Object.hasOwn(callerJob, "needs")) {
      f.push(
        "the `ci:` job in ci.yml gained `needs:` — a skipped dependency skips this job too, " +
          "silently unplugging the pin gate"
      );
    }
    const withMap = callerJob.with;
    if (!isMap(withMap)) {
      f.push(
        "the `ci:` job in ci.yml no longer passes a `with:` mapping to the node-ci.yml reusable " +
          "workflow"
      );
    } else {
      const keys = Object.keys(withMap);
      if (keys.length !== 1 || keys[0] !== "test-command") {
        f.push(
          `the \`ci:\` job's \`with:\` key set changed (${JSON.stringify(keys)}) — the pin gate's ` +
            "only input is `test-command` (update deliberately, after confirming both suites still " +
            "run per-PR)"
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

  // (3) The callee: the input declaration, the job predicate, the step predicates
  // and the step bodies.
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
  const unitTest = isMap(callee.jobs) && isMap(callee.jobs["unit-test"]) ? callee.jobs["unit-test"] : null;
  if (!unitTest) {
    f.push("node-ci.yml no longer defines a `unit-test:` job");
  } else {
    if (unitTest.if !== EXPECTED_JOB_IF) {
      f.push(
        `the \`unit-test\` JOB's activation predicate must be exactly \`${EXPECTED_JOB_IF}\` — an ` +
          "added conjunct can make the job unsatisfiable while every other check stays green; " +
          `found ${JSON.stringify(unitTest.if ?? null)}`
      );
    }
    if (truthyFlag(unitTest, "continue-on-error")) {
      f.push(
        "the `unit-test` job gained `continue-on-error:` — the suite could fail while the job " +
          "reports success"
      );
    }
    if (Object.hasOwn(unitTest, "needs")) {
      f.push("the `unit-test` job gained `needs:` — a skipped dependency skips the gate");
    }
    // #675 P1-2 — the step's execution SHELL is part of the gate. A custom shell
    // becomes `<shell> <scriptPath>` (actions/runner), so `shell: 'true {0}'` on
    // the step — or `defaults.run.shell` on the job — leaves every guarded key
    // byte-identical while the suites never execute. Reproduced GREEN, 52/52.
    if (Object.hasOwn(unitTest, "defaults")) {
      f.push(
        "the `unit-test` job gained a `defaults:` block — `defaults.run.shell` would override the " +
          "shell of every step, including the one that runs `test-command`, so the pin gate can be " +
          "silently disabled while its `if`/`run` stay identical"
      );
    }
    // #675 P2-5 — an EMPTY matrix expands to zero jobs, so the pin gate never
    // runs while every other check here stays green. (Pre-existing on the pre-PR
    // guard too, but closing silently-green wiring paths is this guard's job.)
    if (Object.hasOwn(unitTest, "strategy")) {
      const strategy = unitTest.strategy;
      if (!isMap(strategy)) {
        f.push("the `unit-test` job's `strategy:` is not a mapping the guard can read");
      } else if (Object.hasOwn(strategy, "matrix")) {
        const matrix = strategy.matrix;
        if (!isMap(matrix)) {
          f.push(
            "the `unit-test` job's `strategy.matrix:` is not a mapping the guard can read — a matrix " +
              "the guard cannot enumerate might expand to zero jobs, skipping the pin gate silently"
          );
        } else {
          const dims = Object.entries(matrix);
          if (dims.length === 0) {
            f.push("the `unit-test` job's `strategy.matrix:` is empty — it expands to ZERO jobs, so the pin gate never runs");
          }
          for (const [dim, val] of dims) {
            if (!Array.isArray(val)) {
              f.push(
                `the \`unit-test\` job's \`strategy.matrix.${dim}\` is not a sequence the guard can ` +
                  "read — a dimension the guard cannot enumerate might be empty, expanding the " +
                  "matrix to zero jobs"
              );
            } else if (val.length === 0 && dim !== "exclude") {
              f.push(
                `the \`unit-test\` job's \`strategy.matrix.${dim}\` is EMPTY — the matrix expands to ` +
                  "ZERO jobs, so the pin gate never runs while every other check stays green"
              );
            }
          }
        }
      }
    }
    const steps = unitTest.steps;
    if (!Array.isArray(steps) || steps.length === 0) {
      f.push("the `unit-test` job no longer declares a non-empty `steps:` sequence");
    } else {
      const maps = steps.filter(isMap);
      if (maps.length !== steps.length) {
        f.push("the `unit-test` job's `steps:` contains a non-mapping entry the guard cannot read");
      }
      for (const step of maps) {
        if (truthyFlag(step, "continue-on-error")) {
          f.push(
            `a \`unit-test\` step (${JSON.stringify(step.name ?? step.uses ?? step.run ?? "unnamed")}) ` +
              "gained `continue-on-error:` — the suite could fail while the job reports success"
          );
        }
        // #675 P1-2 — `shell:` is the step's execution semantics. Absent (the
        // runner default `bash -e {0}`) or an explicit bash/sh are the only safe
        // values; `shell: 'true {0}'` runs `true` and never executes the script.
        if (Object.hasOwn(step, "shell") && !ACCEPTABLE_SHELLS.has(step.shell)) {
          f.push(
            `a \`unit-test\` step (${JSON.stringify(step.name ?? step.uses ?? step.run ?? "unnamed")}) ` +
              `sets \`shell: ${JSON.stringify(step.shell)}\` — a non-bash/sh shell can NO-OP the step ` +
              "(e.g. `true {0}`) while its `if`/`run` stay byte-identical, silently skipping the pin gate"
          );
        }
      }
      // Every step's `run:` is read as its own node, so a dead step carrying the expected
      // `run:` text changes this set (it cannot satisfy the check as a decoy).
      const runs = maps.filter((s) => Object.hasOwn(s, "run")).map((s) => s.run);
      if (!setEq(runs, [EXPECTED_RUN_INPUT, EXPECTED_RUN_GLOB])) {
        f.push(
          "the `unit-test` job's step-level `run:` set changed — the gate's step was altered, or a " +
            "step was added/removed (update this set deliberately, after confirming both suites " +
            `still run): found ${JSON.stringify([...runs].sort())}`
        );
      }
      const custom = maps.find((s) => s.if === EXPECTED_STEP_IF);
      if (!custom) {
        f.push(
          `no \`unit-test\` step has \`if: ${EXPECTED_STEP_IF}\` — the step that runs the input is ` +
            "missing or its predicate changed (a step carrying the expected `run:` under a " +
            "different `if:` does not satisfy this)"
        );
      } else {
        // #675 P1-2 — an ALLOWLIST. The step that runs the pin gate may only
        // carry keys that cannot change whether/how the command executes.
        const extra = Object.keys(custom).filter((k) => !CUSTOM_STEP_KEYS.has(k));
        if (extra.length > 0) {
          f.push(
            `the custom-test step gained key(s) ${JSON.stringify(extra)} — the step that runs the pin ` +
              `gate may only carry ${JSON.stringify([...CUSTOM_STEP_KEYS])} (\`shell\` limited to ` +
              "`bash`/`sh`); any other key can no-op it while `if`/`run` read unchanged"
          );
        }
        if (custom.run !== EXPECTED_RUN_INPUT) {
          f.push(
            `the custom-test step must run exactly \`${EXPECTED_RUN_INPUT}\` — otherwise the job ` +
              `reports green without executing the suites, or runs them and swallows the failure; ` +
              `found ${JSON.stringify(custom.run ?? null)}`
          );
        }
      }
    }
  }
  return f;
}

const LIVE_CALLER = fs.readFileSync(CI_YML, "utf8");
const LIVE_CALLEE = fs.readFileSync(NODE_CI_YML, "utf8");

test("live ci.yml → node-ci.yml: the per-PR pin gate is wired", () => {
  const findings = wiringFindings(LIVE_CALLER, LIVE_CALLEE);
  assert.equal(
    findings.length,
    0,
    `the per-PR pin gate is no longer wired as expected:\n  ${findings.join("\n  ")}`
  );
});

// ── guard (j), post-merge half (#675 P1-5) ──────────────────────────────────
// The old design got "cannot be left unwired" by construction (the guards lived
// inside the suite ci-main.yml already ran). After the #666 split, deleting the
// lines this PR added to ci-main.yml left the suite at 52/52 GREEN — the header
// claimed both wiring paths while only the per-PR one was asserted. The
// post-merge invocation is now asserted here.
const POST_MERGE_INVOCATION_RE = /^node\s+scripts\/check-pi-pin-lockstep\.mjs\b/;

/**
 * Evaluate the post-merge wiring from the ci-main.yml SOURCE.
 * → [] when wired, else one message per broken invariant.
 */
function ciMainFindings(src) {
  let doc;
  try {
    doc = parseWorkflowYaml(src);
  } catch (err) {
    const detail = err instanceof WorkflowYamlError ? err.message : String(err.message ?? err);
    return [
      "ci-main.yml could not be read by the supported YAML subset reader " +
        `(scripts/workflow-yaml.mjs): ${detail} — extend that reader deliberately; do NOT ` +
        "fall back to text matching (that is the #637 bypass class)",
    ];
  }
  if (!isMap(doc)) return ["ci-main.yml did not read as a top-level mapping"];
  const job =
    isMap(doc.jobs) && isMap(doc.jobs["extension-tests"]) ? doc.jobs["extension-tests"] : null;
  if (!job) {
    return [
      "ci-main.yml no longer defines the `extension-tests` job — the post-merge half of #637's " +
        "pin-gate contract would be dropped silently",
    ];
  }
  const cmd = isMap(job.with) ? job.with["test-command"] : null;
  if (typeof cmd !== "string" || cmd.trim() === "") {
    return [
      "ci-main.yml's `extension-tests` job no longer passes a non-empty `test-command` — the " +
        "post-merge pin gate would never run",
    ];
  }
  const invocations = cmd
    .split("\n")
    .map((l) => l.trim())
    .filter((l) => POST_MERGE_INVOCATION_RE.test(l));
  if (invocations.length !== 1) {
    return [
      "ci-main.yml's post-merge `test-command` must invoke scripts/check-pi-pin-lockstep.mjs " +
        `exactly once as its own \`node …\` line — found ${invocations.length} such line(s) ` +
        "(an `echo` line mentioning it is not an invocation, and deleting the line drops the " +
        "post-merge half of the pin gate)",
    ];
  }
  if (!/\|\|\s*failures=\$\(\(failures\+1\)\)/.test(invocations[0])) {
    return [
      "ci-main.yml's check-pi-pin-lockstep.mjs line no longer accumulates its failure " +
        "(`… || failures=$((failures+1))`) — a bare `node …` aborts the accumulator at the first " +
        `failure and hides every later suite's verdict; found ${JSON.stringify(invocations[0])}`,
    ];
  }
  return [];
}

test("live ci-main.yml: the post-merge pin gate is wired", () => {
  const findings = ciMainFindings(fs.readFileSync(CI_MAIN_YML, "utf8"));
  assert.deepEqual(
    findings,
    [],
    `the post-merge pin gate is no longer wired as expected:\n  ${findings.join("\n  ")}`
  );
});

// ── guard (j) fixtures ─────────────────────────────────────────────────────
// A minimal but COMPLETE caller/callee pair (every invariant satisfied) used for
// the reformat/GREEN cases; the RED decoy cases below mutate these fixtures or the
// live files. `${{ … }}` is escaped as `\${{ … }}` inside template literals.
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

const FIXTURE_CALLEE = `name: Node.js CI
on:
  workflow_call:
    inputs:
      test-command:
        type: string
        default: ''

jobs:
  script-validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Validate Node.js scripts
        run: |
          errors=0
          node --check scripts/a.mjs || errors=\$((errors+1))
  unit-test:
    runs-on: ubuntu-latest
    if: ${EXPECTED_JOB_IF}
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: '22'
      - name: Custom test command
        if: ${EXPECTED_STEP_IF}
        working-directory: \${{ inputs.working-directory }}
        run: \${{ inputs.test-command }}
      - name: Glob-based node --test
        if: inputs.test-command == '' && inputs.test-glob != ''
        working-directory: \${{ inputs.working-directory }}
        run: node --test \${{ inputs.test-glob }}
`;

// Dedicated fixture for the POST-MERGE half (#675 P1-5) — never the live
// ci-main.yml, so no verdict depends on the live file's spelling. The `echo`
// line is a deliberate decoy: it mentions the suite name without invoking it.
const FIXTURE_CI_MAIN = `name: CI on main
on:
  push:
    branches: [main]

jobs:
  extension-tests:
    uses: daniel-ospina/agent-infra/.github/workflows/node-ci.yml@main
    with:
      test-command: |
        failures=0
        echo "== scripts/check-pi-pin-lockstep.mjs =="
        node scripts/check-pi-pin-lockstep.mjs || failures=$((failures+1))
        if [ $failures -gt 0 ]; then
          exit 1
        fi
    secrets: inherit
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

function expectWired(label, callerSrc, calleeSrc) {
  test(label, () => {
    const findings = wiringFindings(resolveSource(callerSrc), resolveSource(calleeSrc));
    assert.equal(
      findings.length,
      0,
      `expected GREEN (a semantics-preserving reformat must not false-RED):\n  ${findings.join("\n  ")}`
    );
  });
}

function expectRed(label, callerSrc, calleeSrc, needle) {
  test(label, () => {
    const findings = wiringFindings(resolveSource(callerSrc), resolveSource(calleeSrc));
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
  const out = src.replace(find, replace);
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

section("guard (j) — the fixture pair is wired (baseline for the GREEN/RED cases)");

test("minimal fixture pair satisfies every wiring invariant", () => {
  const findings = wiringFindings(FIXTURE_CALLER, FIXTURE_CALLEE);
  assert.equal(findings.length, 0, `fixture pair must be wired: \n  ${findings.join("\n  ")}`);
});

section("guard (j) — semantics-preserving reformats stay GREEN");

// Every fixture argument is either a dedicated fixture source (FIXTURE_CALLER /
// FIXTURE_CALLEE) or a THUNK that mutates one. Thunks are resolved inside
// `test()`, so a fixture whose anchor moved fails as a ❌ naming the anchor
// instead of throwing an uncaught AssertionError at module load.
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
  "quoted keys are accepted (`\"pull_request\":`, `\"test-command\":`, `\"run\":`, `\"if\":`)",
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
  () =>
    mutate(
      mutate(
        mutate(
          mutate(FIXTURE_CALLEE, "    if: ", '    "if": '),
          "        if: ",
          '        "if": '
        ),
        "        run: ",
        '        "run": '
      ),
      "      test-command:",
      '      "test-command":'
    )
);
expectWired(
  "trailing and full-line comments are accepted",
  () =>
    mutate(
      mutate(FIXTURE_CALLER, "on:", "on: # per-PR only\n# a full-line comment"),
      `      test-command: ${EXPECTED_TEST_COMMAND}`,
      `      test-command: ${EXPECTED_TEST_COMMAND} # the pin gate`
    ),
  () => mutate(FIXTURE_CALLEE, "    if: ", "    # activation predicate\n    if: ")
);
expectWired(
  "a whole-file reindent (with: derived, not hard-coded) stays GREEN",
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
  "a parent-indent step sequence stays GREEN",
  FIXTURE_CALLER,
  () =>
    mutate(
      FIXTURE_CALLEE,
      `    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: '22'
      - name: Custom test command
        if: ${EXPECTED_STEP_IF}
        working-directory: \${{ inputs.working-directory }}
        run: \${{ inputs.test-command }}
      - name: Glob-based node --test
        if: inputs.test-command == '' && inputs.test-glob != ''
        working-directory: \${{ inputs.working-directory }}
        run: node --test \${{ inputs.test-glob }}`,
      `    steps:
    - uses: actions/checkout@v4
    - uses: actions/setup-node@v4
      with:
        node-version: '22'
    - name: Custom test command
      if: ${EXPECTED_STEP_IF}
      working-directory: \${{ inputs.working-directory }}
      run: \${{ inputs.test-command }}
    - name: Glob-based node --test
      if: inputs.test-command == '' && inputs.test-glob != ''
      working-directory: \${{ inputs.working-directory }}
      run: node --test \${{ inputs.test-glob }}`
    )
);
expectWired(
  "a block-scalar `run:` body equal to the command stays GREEN",
  FIXTURE_CALLER,
  () =>
    mutate(
      FIXTURE_CALLEE,
      `        run: \${{ inputs.test-command }}`,
      `        run: |\n          \${{ inputs.test-command }}`
    )
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
expectWired(
  "a NON-empty `strategy.matrix` on `unit-test` stays GREEN (#675 P2-5)",
  FIXTURE_CALLER,
  () =>
    mutate(
      FIXTURE_CALLEE,
      `    if: ${EXPECTED_JOB_IF}`,
      `    if: ${EXPECTED_JOB_IF}\n    strategy:\n      matrix:\n        os: [ubuntu-latest]\n        include:\n          - node: '22'`
    )
);
// Positive control for the #675 P1-2 shell key: an explicit bash/sh is a
// semantics-preserving spelling and must NOT be reddened.
expectWired(
  "an explicit `shell: bash` on the custom-test step stays GREEN (#675 P1-2)",
  FIXTURE_CALLER,
  () =>
    mutate(
      FIXTURE_CALLEE,
      CUSTOM_STEP_RUN_CLEAN,
      "        shell: bash\n" + CUSTOM_STEP_RUN_CLEAN
    )
);

section("guard (j) — YAML-valid bypass attempts are RED");

// Every fixture below is a DEDICATED fixture workflow (FIXTURE_CALLER /
// FIXTURE_CALLEE / FIXTURE_CI_MAIN), never the live files, so no verdict here
// depends on the spelling of `.github/workflows/*.yml`. `LIVE_*` appears in
// exactly two places (the "live ci.yml is correctly wired" and "live ci-main.yml
// post-merge gate" assertions above). Each mutation is a thunk, so a broken
// anchor is a ❌, not an uncaught throw at module load.
expectRed(
  "a decoy dead step carrying the expected `run:` text is RED",
  FIXTURE_CALLER,
  () =>
    mutate(
      mutate(FIXTURE_CALLEE, CUSTOM_STEP_RUN_CLEAN, "        run: ${{ inputs.test-command }} || true\n"),
      CUSTOM_STEP_LINE,
      "      - name: Historical\n        if: false\n        run: ${{ inputs.test-command }}\n" + CUSTOM_STEP_LINE
    ),
  "step-level `run:` set changed"
);
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
        CALLER_USES_LINE,
        `    if: github.event_name == 'push'\n${CALLER_USES_LINE}`
      ),
      "jobs:",
      `run-name: |\n  jobs:\n    ci:\n      uses: ${EXPECTED_USES}\n      with:\n        test-command: ${EXPECTED_TEST_COMMAND}\n\njobs:`
    ),
  FIXTURE_CALLEE,
  "gained an `if:`"
);
expectRed(
  "a decoy comment line carrying the expected `run:` text is RED",
  FIXTURE_CALLER,
  () =>
    mutate(
      mutate(FIXTURE_CALLEE, CUSTOM_STEP_RUN_CLEAN, "        run: ${{ inputs.test-command }} || true\n"),
      CUSTOM_STEP_LINE,
      "      # historical: run: ${{ inputs.test-command }}\n" + CUSTOM_STEP_LINE
    ),
  "step-level `run:` set changed"
);
expectRed(
  "an unanchored `uses:` substring elsewhere does not satisfy the call check",
  () =>
    mutate(
      mutate(FIXTURE_CALLER, "name: CI", `name: "uses: ${EXPECTED_USES}"`),
      CALLER_USES_LINE,
      "    uses: daniel-ospina/agent-infra/.github/workflows/node-ci.yml@v0.1.0"
    ),
  FIXTURE_CALLEE,
  "must call"
);
expectRed(
  "the `ci:` job gaining `if:` is RED",
  () => mutate(FIXTURE_CALLER, CALLER_USES_LINE, `    if: github.event_name == 'push'\n${CALLER_USES_LINE}`),
  FIXTURE_CALLEE,
  "gained an `if:`"
);
expectRed(
  "the `ci:` job gaining `continue-on-error :` (space before the colon) is RED",
  () => mutate(FIXTURE_CALLER, CALLER_USES_LINE, `    continue-on-error : true\n${CALLER_USES_LINE}`),
  FIXTURE_CALLEE,
  "gained `continue-on-error:`"
);
expectRed(
  "the `ci:` job gaining `needs:` is RED",
  () => mutate(FIXTURE_CALLER, CALLER_USES_LINE, `    needs: drift-check\n${CALLER_USES_LINE}`),
  FIXTURE_CALLEE,
  "gained `needs:`"
);
expectRed(
  "an emptied `test-command` binding is RED (the job would be skipped)",
  () => mutate(FIXTURE_CALLER, `      test-command: ${EXPECTED_TEST_COMMAND}`, '      test-command: ""'),
  FIXTURE_CALLEE,
  "non-empty `test-command`"
);
expectRed(
  "a `|| true` wrapper on the binding is RED",
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
  "an extra `with:` key is RED",
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
  "losing the second suite from `test-command` is RED",
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
  "the trigger no longer being `pull_request` is RED",
  () => mutate(FIXTURE_CALLER, "on:\n  pull_request:", "on:\n  push:\n    branches: [main]"),
  FIXTURE_CALLEE,
  "must still run on `pull_request`"
);
// The two decoys the #675 verification reproduced against origin/main's TEXT
// guard: both kept a `pull_request` token in the file while `on:` ran only on
// `push`, and origin/main's guard stayed 163/163 GREEN with the gate unplugged.
// A parsed read must go RED naming the missing trigger.
expectRed(
  "a bare `pull_request:` inside a `run-name: |` scalar is not the trigger (RED)",
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
  "a `pull_request:` key inside another top-level mapping is not the trigger (RED)",
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
  "a quoted `\"paths-ignore\":` filter under `pull_request` is RED",
  () =>
    mutate(
      FIXTURE_CALLER,
      "on:\n  pull_request:",
      "on:\n  pull_request:\n    \"paths-ignore\":\n      - '*.md'"
    ),
  FIXTURE_CALLEE,
  "gained `paths-ignore:`"
);
expectRed(
  "a flow-mapped `pull_request: {paths-ignore: …}` is RED",
  () =>
    mutate(FIXTURE_CALLER, "on:\n  pull_request:", "on:\n  pull_request: {paths-ignore: ['*.md']}"),
  FIXTURE_CALLEE,
  "gained `paths-ignore:`"
);
expectRed(
  "`on: [push]` (a flow sequence without pull_request) is RED",
  () => mutate(FIXTURE_CALLER, "on:\n  pull_request:", "on: [push]"),
  FIXTURE_CALLEE,
  "must still run on `pull_request`"
);
expectRed(
  "an unsatisfiable `unit-test` job predicate (`&& false`) is RED",
  FIXTURE_CALLER,
  () => mutate(FIXTURE_CALLEE, `    if: ${EXPECTED_JOB_IF}`, `    if: ${EXPECTED_JOB_IF} && false`),
  "activation predicate must be exactly"
);
expectRed(
  "a rewired custom-test step predicate is RED",
  FIXTURE_CALLER,
  () =>
    mutate(
      FIXTURE_CALLEE,
      `        if: ${EXPECTED_STEP_IF}\n`,
      "        if: inputs.test-command != '' && false\n"
    ),
  "no `unit-test` step has"
);
expectRed(
  "a `|| true` wrapper inside the step `run:` is RED",
  FIXTURE_CALLER,
  () => mutate(FIXTURE_CALLEE, CUSTOM_STEP_RUN_CLEAN, "        run: ${{ inputs.test-command }} || true\n"),
  "must run exactly"
);
expectRed(
  "`continue-on-error: true` on a `unit-test` step is RED",
  FIXTURE_CALLER,
  () =>
    mutate(
      FIXTURE_CALLEE,
      CUSTOM_STEP_LINE,
      "      - name: Custom test command\n        continue-on-error: true\n"
    ),
  "gained `continue-on-error:`"
);
expectRed(
  "`continue-on-error : true` on the `unit-test` job is RED",
  FIXTURE_CALLER,
  () =>
    mutate(
      FIXTURE_CALLEE,
      `    if: ${EXPECTED_JOB_IF}`,
      `    continue-on-error : true\n    if: ${EXPECTED_JOB_IF}`
    ),
  "job gained `continue-on-error:`"
);
expectRed(
  "`needs:` on the `unit-test` job is RED",
  FIXTURE_CALLER,
  () =>
    mutate(
      FIXTURE_CALLEE,
      `    if: ${EXPECTED_JOB_IF}`,
      `    needs: script-validate\n    if: ${EXPECTED_JOB_IF}`
    ),
  "job gained `needs:`"
);
expectRed(
  "renaming the `test-command` workflow_call input is RED",
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
  "a construct outside the reader's subset fails LOUDLY (never silently green)",
  () => mutate(FIXTURE_CALLER, "name: CI", "name: &ci CI"),
  FIXTURE_CALLEE,
  "supported YAML subset reader"
);

// ── #675 P1-1 — YAML escape sequences must not smuggle a guarded key past the guard ──
// The reader previously appended the escaped character LITERALLY, so
// `"paths\u002dignore"` read as the key `pathsu002dignore` while GitHub decodes
// it to `paths-ignore` — guard (j) stayed GREEN with the per-PR gate unplugged.
// The reader now decodes the full YAML escape set (and THROWS on anything else).
expectRed(
  'a `"paths\\u002dignore"` filter under `pull_request` is RED (escape decoded)',
  () =>
    mutate(
      FIXTURE_CALLER,
      "on:\n  pull_request:",
      'on:\n  pull_request:\n    "paths\\u002dignore":\n      - "*.md"'
    ),
  FIXTURE_CALLEE,
  "gained `paths-ignore:`"
);
expectRed(
  'a `"i\\u0066"` key (escaped `if`) on the `ci:` job is RED (escape decoded)',
  () =>
    mutate(
      FIXTURE_CALLER,
      CALLER_USES_LINE,
      '    "i\\u0066": github.event_name == \'push\'\n' + CALLER_USES_LINE
    ),
  FIXTURE_CALLEE,
  "gained an `if:`"
);
expectRed(
  'a `"continu\\u0075e-on-error"` step key is RED (escape decoded)',
  FIXTURE_CALLER,
  () =>
    mutate(
      FIXTURE_CALLEE,
      CUSTOM_STEP_LINE,
      '      - name: Custom test command\n        "contin\\u0075e-on-error": true\n'
    ),
  "gained `continue-on-error:`"
);

// ── #675 P1-2 — the step's execution shell is part of the gate ──
expectRed(
  "`shell: 'true {0}'` on the custom-test step is RED (#675 P1-2)",
  FIXTURE_CALLER,
  () =>
    mutate(
      FIXTURE_CALLEE,
      CUSTOM_STEP_LINE,
      "      - name: Custom test command\n        shell: 'true {0}'\n"
    ),
  "shell:"
);
expectRed(
  "a job-level `defaults.run.shell` on `unit-test` is RED (#675 P1-2)",
  FIXTURE_CALLER,
  () =>
    mutate(
      FIXTURE_CALLEE,
      `    if: ${EXPECTED_JOB_IF}`,
      `    defaults:\n      run:\n        shell: 'true {0}'\n    if: ${EXPECTED_JOB_IF}`
    ),
  "gained a `defaults:`"
);

// ── #675 P2-5 — an empty matrix expands to ZERO jobs (silently green) ──
expectRed(
  "an empty `strategy.matrix.os` on `unit-test` is RED (#675 P2-5)",
  FIXTURE_CALLER,
  () =>
    mutate(
      FIXTURE_CALLEE,
      `    if: ${EXPECTED_JOB_IF}`,
      `    if: ${EXPECTED_JOB_IF}\n    strategy:\n      matrix:\n        os: []`
    ),
  "strategy.matrix.os` is EMPTY"
);
expectRed(
  "an empty `strategy.matrix.include` on `unit-test` is RED (#675 P2-5)",
  FIXTURE_CALLER,
  () =>
    mutate(
      FIXTURE_CALLEE,
      `    if: ${EXPECTED_JOB_IF}`,
      `    if: ${EXPECTED_JOB_IF}\n    strategy:\n      matrix:\n        include: []`
    ),
  "strategy.matrix.include` is EMPTY"
);

// ── #675 P1-5 — the POST-MERGE invocation must not be droppable in silence ──
test("the ci-main fixture is wired (baseline for the post-merge RED cases)", () => {
  const findings = ciMainFindings(FIXTURE_CI_MAIN);
  assert.deepEqual(findings, [], `fixture must be wired:\n  ${findings.join("\n  ")}`);
});
test("deleting the ci-main post-merge invocation is RED (#675 P1-5)", () => {
  const dropped = mutate(
    FIXTURE_CI_MAIN,
    "        node scripts/check-pi-pin-lockstep.mjs || failures=$((failures+1))\n",
    ""
  );
  const findings = ciMainFindings(dropped);
  assert.ok(findings.length > 0, "expected a finding when the post-merge invocation is deleted");
  assert.ok(
    findings.some((m) => m.includes("check-pi-pin-lockstep.mjs")),
    `expected a finding naming the suite; got:\n  ${findings.join("\n  ")}`
  );
});
test("losing the ci-main failure accumulator is RED (#675 P1-5)", () => {
  const bare = mutate(
    FIXTURE_CI_MAIN,
    "        node scripts/check-pi-pin-lockstep.mjs || failures=$((failures+1))",
    "        node scripts/check-pi-pin-lockstep.mjs"
  );
  const findings = ciMainFindings(bare);
  assert.ok(findings.length > 0, "expected a finding when the accumulator is dropped");
  assert.ok(
    findings.some((m) => m.includes("accumulates its failure")),
    `expected the accumulator finding; got:\n  ${findings.join("\n  ")}`
  );
});
test("a ci-main `echo` mentioning the suite is not an invocation (#675 P1-5)", () => {
  const onlyEcho = mutate(
    FIXTURE_CI_MAIN,
    "        node scripts/check-pi-pin-lockstep.mjs || failures=$((failures+1))\n",
    ""
  );
  // the remaining `echo "== scripts/check-pi-pin-lockstep.mjs =="` line must not
  // satisfy the invocation check
  const findings = ciMainFindings(onlyEcho);
  assert.ok(
    findings.some((m) => m.includes("exactly once")),
    `an echo line must not count as an invocation; got:\n  ${findings.join("\n  ")}`
  );
});

// ── (k) workflow-yaml reader — subset behaviour & fail-closed bounds ───────
// The reader (scripts/workflow-yaml.mjs) is the only new surface guard (j) leans
// on, so its subset contract is asserted here directly: the constructs the guard
// needs parse, the constructs it does not model THROW (fail-closed), and the
// repo's whole live workflow corpus parses (the subset is adequate today).
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

test("the live workflow corpus parses (the subset is adequate for this repo)", () => {
  // #675 P2-6 — per-directory floors, not one loose total: the live corpus is
  // 8 + 4, and a single `>= 8` total let a 33% shrink (one directory emptied)
  // pass. Growth is fine; a silently emptied directory is not.
  const dirs = [
    { dir: path.join(REPO_ROOT, ".github", "workflows"), min: 8 },
    { dir: path.join(REPO_ROOT, "templates", ".github", "workflows"), min: 4 },
  ];
  const files = [];
  for (const { dir, min } of dirs) {
    const names = fs.readdirSync(dir).filter((name) => name.endsWith(".yml"));
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

// #675 P1-3 — a LOWER BOUND on the passing count. Guards (h)/(i) now carry their
// own positive controls, but a wholesale DELETION of a rule's test (the suite
// silently shrinking — 52 → 50 did pre-fix) must also be red. This is a floor,
// not an equality: adding tests never needs an update; deleting one does.
const MIN_EXPECTED_PASSING = 71;
console.log(`\ncheck-pi-pin-lockstep.mjs: ${passed} passed, ${failed} failed`);
if (failed === 0 && passed < MIN_EXPECTED_PASSING) {
  failed++;
  console.error(
    `❌ only ${passed} passing tests — expected at least ${MIN_EXPECTED_PASSING}. ` +
      "A guard's test (or a whole section) was deleted or stopped running; restore it or " +
      "update MIN_EXPECTED_PASSING deliberately."
  );
}
if (failed > 0) {
  console.error("❌ SOME TESTS FAILED");
  process.exit(1);
}
console.log("✅ ALL TESTS PASSED");
