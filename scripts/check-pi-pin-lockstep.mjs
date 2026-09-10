#!/usr/bin/env node
/**
 * check-pi-pin-lockstep.mjs — single-purpose CI suite for the #637 pi-pin
 * lockstep tripwires (h)/(i)/(j). Extracted from check-skill-lint.test.mjs by
 * #666 (plan alternative F) so the pin guards have a home of their own and a
 * pin-drift failure no longer shares one red signal (`ci / unit-test`) with a
 * #254 frontmatter-validator regression.
 *
 * SCOPE — the three pin-lockstep guards and nothing else:
 *   (h) extension pi-package pins lockstep with PI_VERSION_PIN
 *   (i) hand-synced mirror version stamps match PI_VERSION_PIN
 *   (j) the per-PR pin gate is still wired into .github/workflows/ci.yml →
 *       node-ci.yml and cannot be silently unplugged
 * The #254 frontmatter-validator suite stays in scripts/check-skill-lint.test.mjs.
 * This suite does NOT import pi (the dev-machine oracle owns pi parity).
 *
 * Run: node scripts/check-pi-pin-lockstep.mjs
 *
 * WIRING: ci.yml passes
 *   `test-command: node scripts/check-skill-lint.test.mjs && node scripts/check-pi-pin-lockstep.mjs`
 * to the reusable node-ci.yml (its unit-test job is SKIPPED when that input is
 * empty — guard (j) asserts the per-PR half of this), and ci-main.yml runs this
 * suite post-merge. Extracting the guards must not leave them unwired on either
 * path; that is guard (j)'s whole job.
 *
 * PI_VERSION_PIN is imported from scripts/frontmatter-fixtures.mjs — that module
 * stays the single source of truth for the pin (it is probe-derived, see its
 * header). The fixture MATRIX itself is not used here.
 *
 * Repo-convention harness: node:assert + custom test()/section() with ✅/❌
 * markers and process.exit(1) on failure (load-gate.test.mjs pattern). Assertion
 * markers are present so mutation-survival spot-checks (deleting a rule → red
 * test) hold.
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
section("extension pi-package pins lockstep with PI_VERSION_PIN");

test("extensions/*/package.json @earendil-works/pi-* pins match PI_VERSION_PIN", () => {
  const extDir = path.join(REPO_ROOT, "extensions");
  const offenders = [];
  const pinCounts = {};
  for (const entry of fs.readdirSync(extDir, { withFileTypes: true })) {
    if (!entry.isDirectory()) continue;
    const pkgPath = path.join(extDir, entry.name, "package.json");
    if (!fs.existsSync(pkgPath)) continue;
    const pkg = JSON.parse(fs.readFileSync(pkgPath, "utf8"));
    let hits = 0;
    for (const field of PIN_FIELDS) {
      for (const [name, ver] of Object.entries(pkg[field] ?? {})) {
        if (!name.startsWith("@earendil-works/pi-")) continue;
        hits++;
        if (ver !== PI_VERSION_PIN) {
          offenders.push(`extensions/${entry.name}/package.json (${field}): ${name}@${ver}`);
        }
      }
    }
    if (hits > 0) pinCounts[entry.name] = hits;
  }
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
  assert.equal(
    offenders.length,
    0,
    `pin drift vs PI_VERSION_PIN=${PI_VERSION_PIN}:\n  ${offenders.join("\n  ")}`
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
// silent-staleness class this guard exists to close. Instead: every `<major>.<minor>.<patch>` literal
// in these four hand-synced surfaces must be either PI_VERSION_PIN or a listed non-pi dependency
// version, and each surface's stamp COUNT must match an expected map so a wholesale rewording OR a
// single dropped stamp is red (a bare `≥1 per file` presence check, like the `matched > 0` variant
// retired in (h), stayed green when a surface lost one of three).
//
// Known scope bounds: 3-component literals only (a `pi 0.86` stamp is invisible), the allowlist is
// keyed by version STRING rather than occurrence, and version-specific LINE REFERENCES are
// deliberately not asserted — they move within a version and must be re-derived by hand (see #651).
section("mirror version stamps match PI_VERSION_PIN");

test("every version literal in the mirror surfaces is the pin or a listed dep version", () => {
  const MIRRORS = [
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
  const offenders = [];
  const stampCounts = {};
  for (const file of MIRRORS) {
    const src = fs.readFileSync(path.join(REPO_ROOT, file), "utf8");
    const allowed = ALLOWED_NON_PI[file] ?? [];
    const stamps = [...src.matchAll(/\d+\.\d+\.\d+/g)]
      .map((m) => m[0])
      .filter((v) => !allowed.includes(v));
    stampCounts[file] = stamps.length;
    for (const v of stamps) if (v !== PI_VERSION_PIN) offenders.push(`${file}: ${v}`);
  }
  // Counts, not just presence: a `≥1 per file` check stayed green when
  // frontmatter-validate.mjs lost one of its 3 stamps. Update deliberately.
  assert.deepEqual(
    stampCounts,
    {
      "docs/providers.md": 1,
      "extensions/custom-provider-qwen/index.ts": 1,
      "scripts/frontmatter-validate.mjs": 3,
      ".github/workflows/ci-main.yml": 2,
    },
    "the set (or per-surface count) of version stamps changed — the tripwire's " +
      "coverage moved, or a stamp was silently dropped (update this map only after " +
      "confirming every stamp is PI_VERSION_PIN)"
  );
  assert.deepEqual(
    offenders,
    [],
    `stale version stamps vs PI_VERSION_PIN=${PI_VERSION_PIN}:\n  ${offenders.join("\n  ")}`
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
section("per-PR pin gate is wired (not silently skipped)");

const EXPECTED_USES = "daniel-ospina/agent-infra/.github/workflows/node-ci.yml@main";
const EXPECTED_TEST_COMMAND =
  "node scripts/check-skill-lint.test.mjs && node scripts/check-pi-pin-lockstep.mjs";
const EXPECTED_JOB_IF = "inputs.test-command != '' || inputs.test-glob != ''";
const EXPECTED_STEP_IF = "inputs.test-command != ''";
const EXPECTED_RUN_INPUT = "${{ inputs.test-command }}";
const EXPECTED_RUN_GLOB = "node --test ${{ inputs.test-glob }}";
const CALLER_USES_LINE = `    uses: ${EXPECTED_USES}`;
const CUSTOM_STEP_LINE = "      - name: Custom test command\n";
const CUSTOM_STEP_RUN_CLEAN = "        run: ${{ inputs.test-command }}\n";
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
      } else if (custom.run !== EXPECTED_RUN_INPUT) {
        f.push(
          `the custom-test step must run exactly \`${EXPECTED_RUN_INPUT}\` — otherwise the job ` +
            `reports green without executing the suites, or runs them and swallows the failure; ` +
            `found ${JSON.stringify(custom.run ?? null)}`
        );
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

function expectWired(label, callerSrc, calleeSrc) {
  test(label, () => {
    const findings = wiringFindings(callerSrc, calleeSrc);
    assert.equal(
      findings.length,
      0,
      `expected GREEN (a semantics-preserving reformat must not false-RED):\n  ${findings.join("\n  ")}`
    );
  });
}

function expectRed(label, callerSrc, calleeSrc, needle) {
  test(label, () => {
    const findings = wiringFindings(callerSrc, calleeSrc);
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

expectWired("flow-style trigger `on: [pull_request]` is accepted", mutate(FIXTURE_CALLER, "on:\n  pull_request:", "on: [pull_request]"), FIXTURE_CALLEE);
expectWired("scalar trigger `on: pull_request` is accepted", mutate(FIXTURE_CALLER, "on:\n  pull_request:", "on: pull_request"), FIXTURE_CALLEE);
expectWired(
  "quoted keys are accepted (`\"pull_request\":`, `\"test-command\":`, `\"run\":`, `\"if\":`)",
  mutate(
    mutate(
      mutate(
        mutate(FIXTURE_CALLER, '  pull_request:', '  "pull_request":'),
        "      test-command:",
        '      "test-command":'
      ),
      "    with:",
      '    "with":'
    ),
    "    uses:",
    '    "uses":'
  ),
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
  mutate(
    mutate(FIXTURE_CALLER, "on:", "on: # per-PR only\n# a full-line comment"),
    `      test-command: ${EXPECTED_TEST_COMMAND}`,
    `      test-command: ${EXPECTED_TEST_COMMAND} # the pin gate`
  ),
  mutate(FIXTURE_CALLEE, "    if: ", "    # activation predicate\n    if: ")
);
expectWired("a whole-file reindent (with: derived, not hard-coded) stays GREEN", reindent(FIXTURE_CALLER, 2), reindent(FIXTURE_CALLEE, 2));
expectWired(
  "a `with:` mapping reindented with only its job subtree stays GREEN",
  (() => {
    const [head, tail] = FIXTURE_CALLER.split("jobs:");
    return head + "jobs:" + reindent(tail, 2);
  })(),
  FIXTURE_CALLEE
);
expectWired(
  "a parent-indent step sequence stays GREEN",
  FIXTURE_CALLER,
  FIXTURE_CALLEE.replace(
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
  mutate(FIXTURE_CALLEE, `        run: \${{ inputs.test-command }}`, `        run: |
          \${{ inputs.test-command }}`)
);
expectWired(
  "a block-scalar `test-command:` binding stays GREEN",
  mutate(FIXTURE_CALLER, `      test-command: ${EXPECTED_TEST_COMMAND}`, `      test-command: |
        ${EXPECTED_TEST_COMMAND}`),
  FIXTURE_CALLEE
);
expectWired(
  "unrelated trigger/inputs keys (`workflow_dispatch.inputs.paths`) stay GREEN",
  mutate(
    FIXTURE_CALLER,
    "on:\n  pull_request:",
    "on:\n  pull_request:\n  workflow_dispatch:\n    inputs:\n      paths:\n        description: unrelated\n        type: string"
  ),
  FIXTURE_CALLEE
);
expectWired(
  "`continue-on-error: false` (an explicit no-op) stays GREEN",
  mutate(FIXTURE_CALLER, "    uses: ", "    continue-on-error: false\n    uses: "),
  FIXTURE_CALLEE
);
expectWired(
  "a `run-name: |` scalar and a `concurrency:` block stay GREEN",
  mutate(FIXTURE_CALLER, "jobs:", "run-name: |\n  CI for \${{ github.ref }}\n\nconcurrency:\n  group: ci-\${{ github.ref }}\n  cancel-in-progress: true\n\njobs:"),
  FIXTURE_CALLEE
);

section("guard (j) — YAML-valid bypass attempts are RED");

// The decoys the #637 review reproduced against the previous text-matching
// generations. Each mutates the LIVE workflow text, so the test proves the real
// bypass class is closed, not a synthetic one.
expectRed(
  "a decoy dead step carrying the expected `run:` text is RED",
  LIVE_CALLER,
  mutate(
    mutate(LIVE_CALLEE, CUSTOM_STEP_RUN_CLEAN, "        run: ${{ inputs.test-command }} || true\n"),
    CUSTOM_STEP_LINE,
    "      - name: Historical\n        if: false\n        run: ${{ inputs.test-command }}\n" + CUSTOM_STEP_LINE
  ),
  "step-level `run:` set changed"
);
expectRed(
  "a `test-command:` line inside another mapping's block scalar is RED",
  mutate(
    mutate(
      LIVE_CALLER,
      `      test-command: ${EXPECTED_TEST_COMMAND}`,
      `      test-command: ${EXPECTED_TEST_COMMAND} || true`
    ),
    "    secrets: inherit\n",
    `    secrets: inherit\n    env:\n      NOTES: |\n        test-command: ${EXPECTED_TEST_COMMAND}\n`
  ),
  LIVE_CALLEE,
  "`test-command` must be exactly"
);
expectRed(
  "a job-shaped block inside a YAML scalar is RED",
  mutate(
    mutate(
      LIVE_CALLER,
      CALLER_USES_LINE,
      `    if: github.event_name == 'push'\n${CALLER_USES_LINE}`
    ),
    "jobs:",
    `run-name: |\n  jobs:\n    ci:\n      uses: ${EXPECTED_USES}\n      with:\n        test-command: ${EXPECTED_TEST_COMMAND}\n\njobs:`
  ),
  LIVE_CALLEE,
  "gained an `if:`"
);
expectRed(
  "a decoy comment line carrying the expected `run:` text is RED",
  LIVE_CALLER,
  mutate(
    mutate(LIVE_CALLEE, CUSTOM_STEP_RUN_CLEAN, "        run: ${{ inputs.test-command }} || true\n"),
    CUSTOM_STEP_LINE,
    "      # historical: run: ${{ inputs.test-command }}\n" + CUSTOM_STEP_LINE
  ),
  "step-level `run:` set changed"
);
expectRed(
  "an unanchored `uses:` substring elsewhere does not satisfy the call check",
  mutate(
    mutate(LIVE_CALLER, "name: CI", `name: "uses: ${EXPECTED_USES}"`),
    CALLER_USES_LINE,
    "    uses: daniel-ospina/agent-infra/.github/workflows/node-ci.yml@v0.1.0"
  ),
  LIVE_CALLEE,
  "must call"
);
expectRed(
  "the `ci:` job gaining `if:` is RED",
  mutate(LIVE_CALLER, CALLER_USES_LINE, `    if: github.event_name == 'push'\n${CALLER_USES_LINE}`),
  LIVE_CALLEE,
  "gained an `if:`"
);
expectRed(
  "the `ci:` job gaining `continue-on-error :` (space before the colon) is RED",
  mutate(LIVE_CALLER, CALLER_USES_LINE, `    continue-on-error : true\n${CALLER_USES_LINE}`),
  LIVE_CALLEE,
  "gained `continue-on-error:`"
);
expectRed(
  "the `ci:` job gaining `needs:` is RED",
  mutate(LIVE_CALLER, CALLER_USES_LINE, `    needs: drift-check\n${CALLER_USES_LINE}`),
  LIVE_CALLEE,
  "gained `needs:`"
);
expectRed(
  "an emptied `test-command` binding is RED (the job would be skipped)",
  mutate(LIVE_CALLER, `      test-command: ${EXPECTED_TEST_COMMAND}`, '      test-command: ""'),
  LIVE_CALLEE,
  "non-empty `test-command`"
);
expectRed(
  "a `|| true` wrapper on the binding is RED",
  mutate(LIVE_CALLER, `      test-command: ${EXPECTED_TEST_COMMAND}`, `      test-command: ${EXPECTED_TEST_COMMAND} || true`),
  LIVE_CALLEE,
  "must be exactly"
);
expectRed(
  "an extra `with:` key is RED",
  mutate(LIVE_CALLER, `      test-command: ${EXPECTED_TEST_COMMAND}`, `      test-glob: '*.test.mjs'\n      test-command: ${EXPECTED_TEST_COMMAND}`),
  LIVE_CALLEE,
  "`with:` key set changed"
);
expectRed(
  "losing the second suite from `test-command` is RED",
  mutate(LIVE_CALLER, `      test-command: ${EXPECTED_TEST_COMMAND}`, "      test-command: node scripts/check-skill-lint.test.mjs"),
  LIVE_CALLEE,
  "must be exactly"
);
expectRed(
  "the trigger no longer being `pull_request` is RED",
  mutate(LIVE_CALLER, "on:\n  pull_request:", "on:\n  push:\n    branches: [main]"),
  LIVE_CALLEE,
  "must still run on `pull_request`"
);
expectRed(
  "a quoted `\"paths-ignore\":` filter under `pull_request` is RED",
  mutate(LIVE_CALLER, "on:\n  pull_request:", "on:\n  pull_request:\n    \"paths-ignore\":\n      - '*.md'"),
  LIVE_CALLEE,
  "gained `paths-ignore:`"
);
expectRed(
  "a flow-mapped `pull_request: {paths-ignore: …}` is RED",
  mutate(LIVE_CALLER, "on:\n  pull_request:", "on:\n  pull_request: {paths-ignore: ['*.md']}"),
  LIVE_CALLEE,
  "gained `paths-ignore:`"
);
expectRed(
  "`on: [push]` (a flow sequence without pull_request) is RED",
  mutate(LIVE_CALLER, "on:\n  pull_request:", "on: [push]"),
  LIVE_CALLEE,
  "must still run on `pull_request`"
);
expectRed(
  "an unsatisfiable `unit-test` job predicate (`&& false`) is RED",
  LIVE_CALLER,
  mutate(LIVE_CALLEE, `    if: ${EXPECTED_JOB_IF}`, `    if: ${EXPECTED_JOB_IF} && false`),
  "activation predicate must be exactly"
);
expectRed(
  "a rewired custom-test step predicate is RED",
  LIVE_CALLER,
  mutate(LIVE_CALLEE, `        if: ${EXPECTED_STEP_IF}\n`, "        if: inputs.test-command != '' && false\n"),
  "no `unit-test` step has"
);
expectRed(
  "a `|| true` wrapper inside the step `run:` is RED",
  LIVE_CALLER,
  mutate(LIVE_CALLEE, CUSTOM_STEP_RUN_CLEAN, "        run: ${{ inputs.test-command }} || true\n"),
  "must run exactly"
);
expectRed(
  "`continue-on-error: true` on a `unit-test` step is RED",
  LIVE_CALLER,
  mutate(LIVE_CALLEE, CUSTOM_STEP_LINE, "      - name: Custom test command\n        continue-on-error: true\n"),
  "gained `continue-on-error:`"
);
expectRed(
  "`continue-on-error : true` on the `unit-test` job is RED",
  LIVE_CALLER,
  mutate(LIVE_CALLEE, `    if: ${EXPECTED_JOB_IF}`, `    continue-on-error : true\n    if: ${EXPECTED_JOB_IF}`),
  "job gained `continue-on-error:`"
);
expectRed(
  "`needs:` on the `unit-test` job is RED",
  LIVE_CALLER,
  mutate(LIVE_CALLEE, `    if: ${EXPECTED_JOB_IF}`, `    needs: script-validate\n    if: ${EXPECTED_JOB_IF}`),
  "job gained `needs:`"
);
expectRed(
  "renaming the `test-command` workflow_call input is RED",
  LIVE_CALLER,
  mutate(LIVE_CALLEE, "      test-command:\n        type: string", "      test-cmd:\n        type: string"),
  "no longer declares a `test-command`"
);
expectRed(
  "a construct outside the reader's subset fails LOUDLY (never silently green)",
  mutate(LIVE_CALLER, "name: CI", "name: &ci CI"),
  LIVE_CALLEE,
  "supported YAML subset reader"
);

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

test("the live workflow corpus parses (the subset is adequate for this repo)", () => {
  const dirs = [
    path.join(REPO_ROOT, ".github", "workflows"),
    path.join(REPO_ROOT, "templates", ".github", "workflows"),
  ];
  const files = [];
  for (const dir of dirs) {
    for (const name of fs.readdirSync(dir)) {
      if (name.endsWith(".yml")) files.push(path.join(dir, name));
    }
  }
  assert.ok(files.length >= 8, `expected the workflow corpus, found ${files.length} files`);
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

console.log(`\ncheck-pi-pin-lockstep.mjs: ${passed} passed, ${failed} failed`);
if (failed > 0) {
  console.error("❌ SOME TESTS FAILED");
  process.exit(1);
}
console.log("✅ ALL TESTS PASSED");
