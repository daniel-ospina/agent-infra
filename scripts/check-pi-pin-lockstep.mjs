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
 *       node-ci.yml AND the post-merge invocation in ci-main.yml is still there
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
 * THE CONTENT LOCK IS THE PRIMARY DEFENCE. scripts/check-workflow-lock.mjs
 * hashes `.github/workflows/ci.yml`, `.github/workflows/node-ci.yml` and
 * `.github/workflows/ci-main.yml` byte-for-byte against
 * scripts/workflow-lock.json. Every bypass above requires EDITING one of those
 * files, which changes its hash — there is nothing left to enumerate. A
 * `pull_request_target` workflow defined on `main`
 * (.github/workflows/workflow-lock.yml) runs THIS script's `--head-ref` mode
 * against a PR's workflow bytes, so the PR cannot delete or neuter the checker.
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
 *   (6) ci-main.yml still invokes this suite in its failure-accumulating form.
 * It deliberately does NOT model `shell:`, `env:`, `container:`, `services:`,
 * `runs-on:`, `defaults:`, `strategy.matrix` (including `exclude`) or trigger
 * filters — the lock covers those, and the narrow guard no longer has to guess
 * at GitHub's surface.
 *
 * ITEM (6) IS THE ONE EXCEPTION to "no shell modelling" (the decision posted on
 * #666): the ci-main.yml invocation is read as a LINE, not a parsed node,
 * because the thing being asserted is a shell failure-accumulator. The line
 * check additionally rejects the round-2 control-flow evasions a matched line
 * alone would miss: the invocation sitting inside `if`/`then`/`fi`/`while`/`for`
 * or a heredoc (never executed), an `|| true` between the invocation and the
 * accumulator (the accumulator never runs), and an `exit 0` after the
 * invocation and before the `if [ $failures -gt 0 ]` guard (the failure is
 * swallowed). The lock is still the primary defence; this is a better message.
 *
 * `--head-ref <sha>` MODE (used by .github/workflows/workflow-lock.yml): fetch
 * the three workflow files at that ref through `gh api …/contents/<path>?ref=`
 * (decode base64) and run ONLY the narrow structural assertions (1)–(6) against
 * those bytes. The content lock is SKIPPED in this mode by design — otherwise
 * every legitimate workflow change would deadlock against `main`'s old lock.
 * `--repo <owner/name>` overrides the repo (else it is derived from
 * `git remote get-url origin`).
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
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { PI_VERSION_PIN } from "./frontmatter-fixtures.mjs";
import { parseWorkflowYaml, WorkflowYamlError } from "./workflow-yaml.mjs";
import {
  LOCKED_FILES,
  hashLockedFiles,
  lockFindings,
  lockPath,
  readLock,
  writeLockFile,
} from "./check-workflow-lock.mjs";

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const CI_YML = path.join(REPO_ROOT, ".github", "workflows", "ci.yml");
const NODE_CI_YML = path.join(REPO_ROOT, ".github", "workflows", "node-ci.yml");
const CI_MAIN_YML = path.join(REPO_ROOT, ".github", "workflows", "ci-main.yml");
const CHECK_LOCK = path.join(REPO_ROOT, "scripts", "check-workflow-lock.mjs");

// ── Constants used by the narrow guard, declared before ANY dispatch ─────────
// The --head-ref dispatch below calls wiringFindings() synchronously, so every
// binding that function reads must already be initialized (TDZ-safe). Function
// declarations are hoisted; these consts and `isMap` are not.
const isMap = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
const EXPECTED_USES = "daniel-ospina/agent-infra/.github/workflows/node-ci.yml@main";
// #675 P2-2 — a FAILURE ACCUMULATOR, not `&&` (see the header for why).
const EXPECTED_TEST_COMMAND =
  "a=0; node scripts/check-skill-lint.test.mjs || a=$?; b=0; node scripts/check-pi-pin-lockstep.mjs " +
  "|| b=$?; [ $a -eq 0 ] && [ $b -eq 0 ]";
const POST_MERGE_INVOCATION_RE = /^node\s+scripts\/check-pi-pin-lockstep\.mjs\b/;
const ACCUMULATOR_SUFFIX_RE = /^\s*\|\|\s*failures=\$\(\(failures\+1\)\)\s*$/;
const FAILURE_GUARD_RE = /^if\s*\[\s*\$failures\s*-gt\s*0\s*\]\s*;?\s*then\s*$/;

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

const ARGS = process.argv.slice(2);
function argValue(flag) {
  const i = ARGS.indexOf(flag);
  return i >= 0 ? (ARGS[i + 1] ?? null) : null;
}
const HEAD_REF = argValue("--head-ref");

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

/** Read one file at a ref through the GitHub Contents API (base64 → utf8). */
function fetchRefFile(repo, ref, rel) {
  const b64 = execFileSync(
    "gh",
    ["api", `repos/${repo}/contents/${rel}?ref=${ref}`, "--jq", ".content"],
    { encoding: "utf8", maxBuffer: 32 * 1024 * 1024 }
  );
  return Buffer.from(b64.replace(/\s+/g, ""), "base64").toString("utf8");
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
  const sources = {};
  const findings = [];
  for (const [key, rel] of HEAD_REF_FILES) {
    try {
      sources[key] = fetchRefFile(repo, ref, rel);
    } catch (err) {
      findings.push(
        `could not fetch ${rel} at ${ref} from ${repo}: ${String(err?.message ?? err).trim()}`
      );
    }
  }
  if (findings.length === 0) findings.push(...headRefFindings(sources));
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

// ── (j) the pin gate is still wired — the narrow, declarative guard ─────────
// #637 wires the suites into the PR path with `with: test-command:` → the reusable node-ci.yml, whose
// unit-test job is SKIPPED when that input is empty. #666 replaced the denylist of execution-semantics
// neutralisers with (a) the content lock (primary defence) and (b) this narrow guard (better error
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
 * Evaluate the pin-gate wiring from the three workflow SOURCES.
 * → [] when every narrow invariant holds, else one message per broken invariant.
 * Assertions are VALUES read from parsed nodes (items 1–5) plus the one
 * line-based check for the ci-main.yml shell accumulator (item 6, see header).
 */
function wiringFindings(ciSrc, nodeCiSrc, ciMainSrc) {
  const f = [];
  let caller = null;
  let callee = null;
  try {
    caller = parseWorkflowYaml(ciSrc);
  } catch (err) {
    f.push(readError(".github/workflows/ci.yml", err));
  }
  try {
    callee = parseWorkflowYaml(nodeCiSrc);
  } catch (err) {
    f.push(readError(".github/workflows/node-ci.yml", err));
  }

  if (caller !== null) {
    if (!isMap(caller)) {
      f.push("ci.yml did not read as a top-level mapping");
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

  if (callee !== null) {
    if (!isMap(callee)) {
      f.push("node-ci.yml did not read as a top-level mapping");
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

  // (6) The one line-based check (see the header's "ITEM (6) IS THE ONE EXCEPTION").
  f.push(...ciMainFindings(ciMainSrc));
  return f;
}

// ── (j), post-merge half — the ci-main.yml shell accumulator (item 6) ───────

/**
 * Which shell control-flow context is open at line index `upto` (exclusive)?
 * → null when top level, else a human label. Comment-only/trailing text is
 * stripped before counting so a comment mentioning `if` cannot fake depth.
 * Heredocs are tracked from `<<`/`<<-` to their delimiter.
 */
function shellControlContext(lines, upto) {
  let ifDepth = 0;
  let loopDepth = 0;
  let heredoc = null;
  for (let i = 0; i < upto; i++) {
    const raw = lines[i];
    if (heredoc !== null) {
      if (raw === heredoc) heredoc = null;
      continue;
    }
    const hd = /<<-?\s*['"]?([A-Za-z_][A-Za-z0-9_]*)['"]?/.exec(raw);
    if (hd) {
      heredoc = hd[1];
      continue;
    }
    const code = raw.replace(/#.*$/, "");
    if (code.trim() === "") continue;
    for (const w of code.split(/[^A-Za-z_]+/)) {
      if (w === "if") ifDepth++;
      else if (w === "fi") ifDepth = Math.max(0, ifDepth - 1);
      else if (w === "for" || w === "while" || w === "until") loopDepth++;
      else if (w === "done") loopDepth = Math.max(0, loopDepth - 1);
    }
  }
  if (heredoc !== null) return "a heredoc";
  if (ifDepth > 0) return "an `if`/`then`/`fi` block";
  if (loopDepth > 0) return "a `for`/`while`/`until` loop";
  return null;
}

/**
 * Evaluate the post-merge wiring (item 6) from the ci-main.yml SOURCE.
 * → [] when wired, else one message per broken invariant.
 */
function ciMainFindings(src) {
  let doc;
  try {
    doc = parseWorkflowYaml(src);
  } catch (err) {
    return [readError(".github/workflows/ci-main.yml", err)];
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
  const lines = cmd.split("\n").map((l) => l.trim());
  const invocations = [];
  lines.forEach((line, i) => {
    if (POST_MERGE_INVOCATION_RE.test(line)) invocations.push({ line, i });
  });
  if (invocations.length !== 1) {
    return [
      "ci-main.yml's post-merge `test-command` must invoke scripts/check-pi-pin-lockstep.mjs " +
        `exactly once as its own \`node …\` line — found ${invocations.length} such line(s) ` +
        "(an `echo` line mentioning it is not an invocation, and deleting the line drops the " +
        "post-merge half of the pin gate)",
    ];
  }
  const { line, i } = invocations[0];
  // Control-flow evasion (round-2 review): a matched line inside a conditional
  // or heredoc is never executed, so the accumulator never counts it.
  const context = shellControlContext(lines, i);
  if (context !== null) {
    return [
      `ci-main.yml's check-pi-pin-lockstep.mjs invocation sits inside ${context} — a matched ` +
        "line there is not executed, so the post-merge pin gate never runs; it must be a " +
        "top-level line in the accumulator",
    ];
  }
  // The invocation must fail INTO the accumulator, with nothing in between: a
  // `node … || true || failures=$((failures+1))` short-circuits past the
  // accumulator on failure, so the gate passes while the suite failed.
  const suffix = line.slice("node scripts/check-pi-pin-lockstep.mjs".length);
  if (!ACCUMULATOR_SUFFIX_RE.test(suffix)) {
    if (/\|\|\s*true\b/.test(suffix)) {
      return [
        "ci-main.yml's check-pi-pin-lockstep.mjs line has an `|| true` between the invocation and " +
          "the failure accumulator — the `true` short-circuits past the accumulator on failure, " +
          `so the post-merge gate can never go red; found ${JSON.stringify(line)}`,
      ];
    }
    return [
      "ci-main.yml's check-pi-pin-lockstep.mjs line no longer accumulates its failure " +
        "(`… || failures=$((failures+1))`) — a bare `node …` aborts the accumulator at the first " +
        `failure and hides every later suite's verdict; found ${JSON.stringify(line)}`,
    ];
  }
  // An `exit 0` after the invocation but before the failure guard swallows the
  // recorded failure and exits the step green.
  for (let j = i + 1; j < lines.length; j++) {
    if (FAILURE_GUARD_RE.test(lines[j])) break;
    if (/^exit\s+0\b/.test(lines[j])) {
      return [
        "ci-main.yml's check-pi-pin-lockstep.mjs line is followed by an `exit 0` before the " +
          "`if [ $failures -gt 0 ]` guard — the recorded failure is swallowed and the step " +
          "exits green",
      ];
    }
  }
  return [];
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
// The PRIMARY defence (see the header). Every execution-semantics bypass found
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

// Dedicated fixture for the POST-MERGE half — never the live ci-main.yml, so no
// verdict depends on the live file's spelling. The `echo` line is a deliberate
// decoy: it mentions the suite name without invoking it.
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

// ── guard (j), item 6 — the ci-main.yml shell accumulator ────────────────────
section("guard (j), item 6 — the ci-main.yml invocation and its control-flow evasions");

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
  const findings = ciMainFindings(onlyEcho);
  assert.ok(
    findings.some((m) => m.includes("exactly once")),
    `an echo line must not count as an invocation; got:\n  ${findings.join("\n  ")}`
  );
});
test("an invocation inside an `if`/`then`/`fi` block is RED (#666 round 2 evasion)", () => {
  const wrapped = mutate(
    FIXTURE_CI_MAIN,
    "        node scripts/check-pi-pin-lockstep.mjs || failures=$((failures+1))\n",
    "        if [ -n \"$CI\" ]; then\n" +
      "        node scripts/check-pi-pin-lockstep.mjs || failures=$((failures+1))\n" +
      "        fi\n"
  );
  const findings = ciMainFindings(wrapped);
  assert.ok(
    findings.some((m) => m.includes("sits inside")),
    `expected the control-flow finding; got:\n  ${findings.join("\n  ")}`
  );
});
test("an invocation inside a `for` loop is RED (#666 round 2 evasion)", () => {
  const wrapped = mutate(
    FIXTURE_CI_MAIN,
    "        node scripts/check-pi-pin-lockstep.mjs || failures=$((failures+1))\n",
    "        for i in 1; do\n" +
      "        node scripts/check-pi-pin-lockstep.mjs || failures=$((failures+1))\n" +
      "        done\n"
  );
  const findings = ciMainFindings(wrapped);
  assert.ok(
    findings.some((m) => m.includes("sits inside")),
    `expected the loop finding; got:\n  ${findings.join("\n  ")}`
  );
});
test("an invocation inside a heredoc is RED (#666 round 2 evasion)", () => {
  const wrapped = mutate(
    FIXTURE_CI_MAIN,
    "        node scripts/check-pi-pin-lockstep.mjs || failures=$((failures+1))\n",
    "        cat <<EOF\n" +
      "        node scripts/check-pi-pin-lockstep.mjs || failures=$((failures+1))\n" +
      "        EOF\n"
  );
  const findings = ciMainFindings(wrapped);
  assert.ok(
    findings.some((m) => m.includes("heredoc")),
    `expected the heredoc finding; got:\n  ${findings.join("\n  ")}`
  );
});
test("an `|| true` between the invocation and the accumulator is RED (#666 round 2 evasion)", () => {
  const swallowed = mutate(
    FIXTURE_CI_MAIN,
    "        node scripts/check-pi-pin-lockstep.mjs || failures=$((failures+1))",
    "        node scripts/check-pi-pin-lockstep.mjs || true || failures=$((failures+1))"
  );
  const findings = ciMainFindings(swallowed);
  assert.ok(
    findings.some((m) => m.includes("`|| true`")),
    `expected the \`|| true\` finding; got:\n  ${findings.join("\n  ")}`
  );
});
test("an `exit 0` after the invocation and before the failure guard is RED (#666 round 2 evasion)", () => {
  const swallowed = mutate(
    FIXTURE_CI_MAIN,
    "        node scripts/check-pi-pin-lockstep.mjs || failures=$((failures+1))\n",
    "        node scripts/check-pi-pin-lockstep.mjs || failures=$((failures+1))\n" + "        exit 0\n"
  );
  const findings = ciMainFindings(swallowed);
  assert.ok(
    findings.some((m) => m.includes("`exit 0`")),
    `expected the \`exit 0\` finding; got:\n  ${findings.join("\n  ")}`
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
const MIN_EXPECTED_PASSING = 69;
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
