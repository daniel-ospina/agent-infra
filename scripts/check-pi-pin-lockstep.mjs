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
 *     `--head-ref` mode) provides the STRUCTURAL ASSERTIONS ONLY and provides
 *     ZERO lock enforcement — it skips the lock by design, because otherwise
 *     every legitimate workflow change would deadlock against `main`'s old lock;
 *   - a PR that edits a workflow AND the lock together therefore passes both
 *     legs. That is the pre-existing accepted same-commit residual, now
 *     conspicuous in the diff (two files, one literally named a lock, and a
 *     visible hash change).
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
 *   (6) ci-main.yml still invokes this suite in its failure-accumulating form.
 * It deliberately does NOT model `shell:`, `env:`, `container:`, `services:`,
 * `runs-on:`, `defaults:`, `strategy.matrix` (including `exclude`) or trigger
 * filters — the lock covers those, and the narrow guard no longer has to guess
 * at GitHub's surface.
 *
 * ITEM (6) IS THE ONE EXCEPTION to "no shell modelling" (the decision posted on
 * #666): the ci-main.yml invocation is read as a LINE, not a parsed node,
 * because the thing being asserted is a shell failure-accumulator. It is a
 * BOUNDED LEXICAL check, not an execution-semantics model: quoted spans,
 * comments and heredoc bodies are removed, a control-flow keyword counts only in
 * COMMAND POSITION, and the check then requires (a) the EXACT accumulator line
 * `node scripts/check-pi-pin-lockstep.mjs || failures=$((failures+1))`, (b) a
 * `failures=0` initialisation before it, and (c) a failure guard
 * `if [ $failures -gt 0 ] … fi` after it whose body exits NON-ZERO. Relocation
 * evasions a matched line alone would miss are rejected: the invocation inside
 * `if`/`then`/`fi`, a loop, a heredoc, a `case`/`esac` block, a function body or
 * a `{ … }`/`( … )` group (including one short-circuited by `false &&`), an
 * `|| true` before the accumulator, and an `exit 0` or `trap … EXIT` anywhere in
 * the command. The lock is the tripwire; this is a better message. See the
 * authoritative trust-split statement above.
 *
 * `--head-ref <sha>` MODE (used by .github/workflows/workflow-lock.yml): fetch
 * the three workflow files at that ref through `gh api …/contents/<path>?ref=`
 * and run ONLY the narrow structural assertions (1)–(6) against those bytes. The
 * decode is fail-closed: only `encoding: "base64"` is trusted (the API returns
 * `none` + empty content for a >1 MB blob) and a lossy decode throws. The
 * content lock is SKIPPED in this mode by design — this leg provides ZERO lock
 * enforcement (see the authoritative trust-split statement above).
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
  UNLOCKED_WORKFLOWS,
  hashLockedFiles,
  lockFindings,
  lockPath,
  readLock,
  workflowCoverageFindings,
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
// Shell token scanner used by the item-6 lexical check. Declared HERE (before the
// --head-ref dispatch below) because `wiringFindings` is reached from that
// dispatch at module-evaluation time, and a `const` in the item-6 section would
// still be in its temporal dead zone (#675 review-fix e2e finding).
const SHELL_TOKEN_RE = /&&|\|\||[;&|(){}]|[^\s;&|(){}]+/g;
const EXPECTED_USES = "daniel-ospina/agent-infra/.github/workflows/node-ci.yml@main";
// #675 P2-2 — a FAILURE ACCUMULATOR, not `&&` (see the header for why).
const EXPECTED_TEST_COMMAND =
  "a=0; node scripts/check-skill-lint.test.mjs || a=$?; b=0; node scripts/check-pi-pin-lockstep.mjs " +
  "|| b=$?; [ $a -eq 0 ] && [ $b -eq 0 ]";
const POST_MERGE_INVOCATION_RE = /^node\s+scripts\/check-pi-pin-lockstep\.mjs\b/;
const ACCUMULATOR_SUFFIX_RE = /^\s*\|\|\s*failures=\$\(\(failures\+1\)\)\s*$/;
// The exact, required accumulator line (the invocation must be exactly this).
const POST_MERGE_INVOCATION =
  "node scripts/check-pi-pin-lockstep.mjs || failures=$((failures+1))";
const FAILURE_GUARD_OPEN_RE = /^if\s*\[\s*\$failures\s*-gt\s*0\s*\]\s*;?\s*then$/;
const FAILURE_GUARD_CLOSE_RE = /^fi$/;
const NONZERO_EXIT_RE = /^exit\s+[1-9][0-9]*$/;

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

/**
 * Decode a GitHub Contents API JSON payload → utf8 text, failing CLOSED.
 *
 * The API returns `encoding: "none"` with an empty `content` for a blob over
 * 1 MB. Reading `.content` unconditionally (the pre-fix behaviour) turned such a
 * file into "" — and because `parseWorkflowYaml("")` returns null, that silently
 * DISARMED every structural assertion (#675 P1-1). A non-base64 payload is an
 * error, not an empty workflow. `TextDecoder(…, { fatal: true })` rejects a
 * lossy decode for the same reason: a damaged read must never look like a valid
 * workflow.
 */
function decodeContentsApi(payload, rel) {
  let body;
  try {
    body = JSON.parse(payload);
  } catch (err) {
    throw new Error(`${rel}: Contents API did not return JSON (${String(err?.message ?? err)})`);
  }
  if (!isMap(body) || body.encoding !== "base64" || typeof body.content !== "string") {
    throw new Error(
      `${rel}: Contents API returned encoding=${JSON.stringify(body?.encoding ?? null)} — only ` +
        'base64 content is trusted (a >1 MB blob comes back as encoding "none" with empty ' +
        "content, which must never be read as an empty workflow)"
    );
  }
  const bytes = Buffer.from(body.content.replace(/\s+/g, ""), "base64");
  try {
    return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    throw new Error(`${rel}: Contents API content is not valid UTF-8`);
  }
}

/** Read one file at a ref through the GitHub Contents API (fail-closed decode). */
function fetchRefFile(repo, ref, rel) {
  const json = execFileSync(
    "gh",
    [
      "api",
      `repos/${repo}/contents/${rel}?ref=${ref}`,
      "-H",
      "Accept: application/vnd.github+json",
    ],
    { encoding: "utf8", maxBuffer: 32 * 1024 * 1024 }
  );
  return decodeContentsApi(json, rel);
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
// #675 P2-c — a COUNT floor is not an identity: disabling 3 real tests and adding
// 3 `test("filler", () => assert.ok(true))` no-ops kept the total at 69. These
// sets let the run name the specific assertions that must exist and pass, so a
// deleted/renamed/neutered one is RED no matter what fills the count.
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
 * as `ciMainFindings` treats it. Skipping the assertions instead was a fail-open:
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
 * Assertions are VALUES read from parsed nodes (items 1–5) plus the one
 * line-based check for the ci-main.yml shell accumulator (item 6, see header).
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

  // (6) The one line-based check (see the header's "ITEM (6) IS THE ONE EXCEPTION").
  f.push(...ciMainFindings(ciMainSrc));
  return f;
}

// ── (j), post-merge half — the ci-main.yml shell accumulator (item 6) ───────
//
// BOUNDED LEXICAL CHECK, NOT A SHELL MODEL (#675 P1-6 + P2-a). The invariant is
// a shell failure-accumulator, so a pure presence check is not enough: an
// invocation inside `case`, a function body, a `{ … }` group short-circuited by
// `false &&`, an inline `if …; then exit 0; fi`, or a `trap … EXIT` all leave the
// literal line present while the gate is dead. Rather than model execution
// semantics (the class this PR deleted), this REMOVES quoted spans, comments and
// heredoc bodies, counts control-flow keywords ONLY in command position, and
// requires the exact accumulator line plus a failure guard that exists and exits
// non-zero. The lock is the tripwire; this is the better error message (see the
// authoritative trust-split statement in the module header).

/** Remove a shell `#` comment (quote-aware). Quotes are PRESERVED so a heredoc
 * delimiter such as `<<'EOF'` survives for heredoc detection. */
function stripShellComment(raw) {
  let q = null;
  for (let i = 0; i < raw.length; i++) {
    const c = raw[i];
    if (q === '"') { if (c === "\\") { i++; continue; } if (c === '"') q = null; continue; }
    if (q === "'") { if (c === "'") q = null; continue; }
    if (c === '"' || c === "'") { q = c; continue; }
    if (c === "#" && (i === 0 || /[\s;&|(]/.test(raw[i - 1]))) return raw.slice(0, i);
  }
  return raw;
}

/** Blank out single/double-quoted spans (double-quote escapes respected). This
 * is what makes `echo "checking if the suite is wired"` keyword-inert (#675
 * P1-6 / #779): the word `if` is inside a string, not command position. */
function stripShellQuotes(raw) {
  let out = "";
  let q = null;
  for (let i = 0; i < raw.length; i++) {
    const c = raw[i];
    if (q === null) {
      if (c === "'" || c === '"') { q = c; out += " "; continue; }
      out += c;
    } else if (q === "'") {
      if (c === "'") q = null;
      out += " ";
    } else {
      if (c === "\\") { i++; out += "  "; continue; }
      if (c === '"') q = null;
      out += " ";
    }
  }
  return out;
}

/**
 * Which shell control-flow context is lexically open at line index `upto`
 * (exclusive)? → null when top level, else a human label.
 *
 * Quoted spans, comments and heredoc bodies are removed first, and a bracket
 * keyword only counts in COMMAND POSITION (start of line, or straight after
 * `;` `&&` `||` `|` `&` `(` `)` `{` `}`, or after `then`/`do`/`else`/`elif`).
 * Heredocs are tracked from `<<`/`<<-` to their delimiter.
 */
function shellControlContext(lines, upto) {
  const d = { ifDepth: 0, loopDepth: 0, caseDepth: 0, groupDepth: 0 };
  let heredoc = null;
  let trapExit = false;
  for (let i = 0; i < upto; i++) {
    const noComment = stripShellComment(lines[i]);
    if (heredoc !== null) {
      if (noComment.trim() === heredoc) heredoc = null;
      continue;
    }
    const hd = /<<-?\s*['"]?([A-Za-z_][A-Za-z0-9_]*)['"]?/.exec(noComment);
    if (hd) { heredoc = hd[1]; continue; }
    const code = stripShellQuotes(noComment);
    const tokens = code.match(SHELL_TOKEN_RE) ?? [];
    if (tokens.includes("trap") && tokens.includes("EXIT")) trapExit = true;
    let commandStart = true;
    for (const tok of tokens) {
      if (/^(?:&&|\|\||[;&|(){}])$/.test(tok)) {
        if (tok === "{" || tok === "(") d.groupDepth++;
        else if (tok === "}" || tok === ")") d.groupDepth = Math.max(0, d.groupDepth - 1);
        commandStart = true;
        continue;
      }
      if (!commandStart) {
        // `then`/`do`/`else`/`elif` introduce the next command inside a clause.
        if (tok === "then" || tok === "do" || tok === "else" || tok === "elif") {
          commandStart = true;
        }
        continue;
      }
      if (tok === "if") d.ifDepth++;
      else if (tok === "fi") d.ifDepth = Math.max(0, d.ifDepth - 1);
      else if (tok === "for" || tok === "while" || tok === "until") d.loopDepth++;
      else if (tok === "done") d.loopDepth = Math.max(0, d.loopDepth - 1);
      else if (tok === "case") d.caseDepth++;
      else if (tok === "esac") d.caseDepth = Math.max(0, d.caseDepth - 1);
      else if (tok === "then" || tok === "do" || tok === "else" || tok === "elif" || tok === "in") {
        commandStart = true;
        continue;
      }
      commandStart = false;
    }
  }
  if (heredoc !== null) return "a heredoc";
  if (trapExit) return "a `trap … EXIT`";
  if (d.ifDepth > 0) return "an `if`/`then`/`fi` block";
  if (d.loopDepth > 0) return "a `for`/`while`/`until` loop";
  if (d.caseDepth > 0) return "a `case`/`esac` block";
  if (d.groupDepth > 0) return "a `{ … }` / `( … )` group";
  return null;
}

/**
 * Any `exit 0` or `trap … EXIT` ANYWHERE in the command? Both can leave the
 * step green with the failure recorded but not fatal, so neither is allowed —
 * before OR after the invocation (`exit 0` before it means the accumulator is
 * never even reached). Quotes/comments are stripped so an `echo "exit 0"` is
 * inert.
 */
function shellSwallowFinding(lines) {
  const tokens = [];
  for (const raw of lines) {
    const code = stripShellQuotes(stripShellComment(raw));
    tokens.push(...(code.match(SHELL_TOKEN_RE) ?? []));
  }
  if (tokens.includes("trap") && tokens.includes("EXIT")) {
    return (
      "ci-main.yml's post-merge `test-command` contains a `trap … EXIT` — it overrides the " +
      "step's exit status, so the recorded failure can be swallowed and the step still exits green"
    );
  }
  for (let k = 0; k + 1 < tokens.length; k++) {
    if (tokens[k] === "exit" && tokens[k + 1] === "0") {
      return (
        "ci-main.yml's post-merge `test-command` contains an `exit 0` — the step would exit green " +
        "regardless of the accumulator (including an inline `if …; then exit 0; fi`)"
      );
    }
  }
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
  // The invocation must be the EXACT accumulator line. A `node … || true ||
  // failures=$((failures+1))` short-circuits past the accumulator on failure, so
  // the gate passes while the suite failed.
  if (line !== POST_MERGE_INVOCATION) {
    if (/\|\|\s*true\b/.test(line)) {
      return [
        "ci-main.yml's check-pi-pin-lockstep.mjs line has an `|| true` between the invocation and " +
          "the failure accumulator — the `true` short-circuits past the accumulator on failure, " +
          `so the post-merge gate can never go red; found ${JSON.stringify(line)}`,
      ];
    }
    if (ACCUMULATOR_SUFFIX_RE.test(line.slice("node scripts/check-pi-pin-lockstep.mjs".length))) {
      return [
        `ci-main.yml's check-pi-pin-lockstep.mjs line has unexpected text before the accumulator; ` +
          `required exactly ${JSON.stringify(POST_MERGE_INVOCATION)}; found ${JSON.stringify(line)}`,
      ];
    }
    return [
      "ci-main.yml's check-pi-pin-lockstep.mjs line no longer accumulates its failure " +
        "(`… || failures=$((failures+1))`) — a bare `node …` aborts the accumulator at the first " +
        `failure and hides every later suite's verdict; found ${JSON.stringify(line)}`,
    ];
  }
  // `failures` must be initialised before the accumulator reads/increments it.
  if (!lines.slice(0, i).includes("failures=0")) {
    return [
      "ci-main.yml's post-merge `test-command` does not initialise `failures=0` before the " +
        "check-pi-pin-lockstep.mjs line — the accumulator has no starting value",
    ];
  }
  // Relocation evasion: a matched line inside `case`, a function body, a `{ … }`
  // short-circuited by `false &&`, a loop or a heredoc is not executed, so the
  // accumulator never counts it.
  const context = shellControlContext(lines, i);
  if (context !== null) {
    return [
      `ci-main.yml's check-pi-pin-lockstep.mjs invocation sits inside ${context} — a matched ` +
        "line there is not executed, so the post-merge pin gate never runs; it must be a " +
        "top-level line in the accumulator",
    ];
  }
  // `exit 0` / `trap … EXIT` anywhere in the command swallows the recorded failure.
  const swallow = shellSwallowFinding(lines);
  if (swallow !== null) return [swallow];
  // The failure guard must EXIST and leave the step non-zero: an `exit 0` scan that
  // runs off the end when no guard is present returned [] (P2-a).
  let open = -1;
  for (let j = i + 1; j < lines.length; j++) {
    if (FAILURE_GUARD_OPEN_RE.test(lines[j])) { open = j; break; }
  }
  if (open === -1) {
    return [
      "ci-main.yml's post-merge `test-command` has no `if [ $failures -gt 0 ]` failure guard after " +
        "the check-pi-pin-lockstep.mjs line — without it the step exits green even when the pin " +
        "suite failed; the exact guard block is required",
    ];
  }
  let close = -1;
  let nonZeroExit = false;
  for (let j = open + 1; j < lines.length; j++) {
    if (FAILURE_GUARD_CLOSE_RE.test(lines[j])) { close = j; break; }
    if (NONZERO_EXIT_RE.test(lines[j])) nonZeroExit = true;
  }
  if (close === -1) {
    return [
      "ci-main.yml's `if [ $failures -gt 0 ]` failure guard is never closed by a `fi` line — the " +
        "accumulator's failure has no exit path",
    ];
  }
  if (!nonZeroExit) {
    return [
      "ci-main.yml's failure guard does not `exit` non-zero (its body may have been replaced by an " +
        "`echo`) — the step would finish green with the failure recorded only in text; the guard " +
        "must exit non-zero",
    ];
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

// #675 P1-1 — the fail-open. `parseWorkflowYaml("")` returns null (empty file,
// comments-only, or a lone `---`), and the assertions were all guarded by
// `if (caller !== null)` — so ZERO findings and the trusted leg printed ✅.
// `ciMainFindings` already rejected a non-mapping document; the other two now do
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

// #675 P1-1, compounding defect: the Contents API returns `encoding: "none"`
// with empty `content` for a blob over 1 MB, so reading `.content` blindly
// turned a padded workflow into "" — straight into the fail-open path above.
// The decode is now fail-closed.
test("the Contents API decode fails CLOSED on encoding 'none' or a lossy decode (#675 P1-1)", () => {
  assert.equal(
    decodeContentsApi(
      JSON.stringify({ encoding: "base64", content: Buffer.from("name: CI\n").toString("base64") }),
      ".github/workflows/ci.yml"
    ),
    "name: CI\n",
    "a base64 payload decodes to its utf-8 text"
  );
  assert.throws(
    () =>
      decodeContentsApi(
        JSON.stringify({ encoding: "none", content: "", size: 2 * 1024 * 1024 }),
        ".github/workflows/ci.yml"
      ),
    /encoding="none"/,
    "a >1 MB blob (encoding 'none') must THROW, never decode to an empty workflow"
  );
  assert.throws(
    () =>
      decodeContentsApi(
        JSON.stringify({ encoding: "base64", content: Buffer.from([0xff, 0xfe]).toString("base64") }),
        ".github/workflows/ci.yml"
      ),
    /not valid UTF-8/,
    "a lossy decode must THROW rather than look like a valid workflow"
  );
  assert.throws(() => decodeContentsApi("not json", "x"), /did not return JSON/);
  // A genuinely empty file is base64 "" → "", and wiringFindings turns THAT red
  // (above); the decode itself must not pretend it is an error.
  assert.equal(decodeContentsApi(JSON.stringify({ encoding: "base64", content: "" }), "x"), "");
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

// ── #675 P1-6 + P2-a — the seven reproduced item-6 evasions ───────────────
// Each of these left BOTH legs GREEN before the fix: the invocation line was
// still present and exact, but the gate was dead (never executed, or its recorded
// failure swallowed). Two are value assertions (the guard must exist and exit
// non-zero); five are the quote/heredoc/command-position-aware relocation check.
// See the "BOUNDED LEXICAL CHECK, NOT A SHELL MODEL" comment above for why this
// is not a general shell model, and the module header for the trust split.
test("item 6 RED #1: the failure guard removed entirely (#675 P2-a)", () => {
  const src = mutate(FIXTURE_CI_MAIN, "        if [ $failures -gt 0 ]; then\n          exit 1\n        fi\n", "");
  const findings = ciMainFindings(src);
  assert.ok(
    findings.some((m) => m.includes("no `if [ $failures -gt 0 ]` failure guard")),
    `expected the missing-guard finding; got:\n  ${findings.join("\n  ")}`
  );
});
test("item 6 RED #2: the guard body replaced by an `echo` (#675 P2-a)", () => {
  const src = mutate(FIXTURE_CI_MAIN, "          exit 1", '          echo "failed"');
  const findings = ciMainFindings(src);
  assert.ok(
    findings.some((m) => m.includes("does not `exit` non-zero")),
    `expected the non-zero-exit finding; got:\n  ${findings.join("\n  ")}`
  );
});
test("item 6 RED #3: the invocation moved into a `case` arm (#675 P2-a)", () => {
  const src = mutate(
    FIXTURE_CI_MAIN,
    "        node scripts/check-pi-pin-lockstep.mjs || failures=$((failures+1))\n",
    '        case "$CI" in\n' +
      "        true)\n" +
      "        node scripts/check-pi-pin-lockstep.mjs || failures=$((failures+1))\n" +
      "        ;;\n" +
      "        esac\n"
  );
  const findings = ciMainFindings(src);
  assert.ok(
    findings.some((m) => m.includes("sits inside a `case`/`esac` block")),
    `expected the case finding; got:\n  ${findings.join("\n  ")}`
  );
});
test("item 6 RED #4: the invocation inside a never-called shell function (#675 P2-a)", () => {
  const src = mutate(
    FIXTURE_CI_MAIN,
    "        node scripts/check-pi-pin-lockstep.mjs || failures=$((failures+1))\n",
    "        run_it() {\n" +
      "        node scripts/check-pi-pin-lockstep.mjs || failures=$((failures+1))\n" +
      "        }\n"
  );
  const findings = ciMainFindings(src);
  assert.ok(
    findings.some((m) => m.includes("sits inside") && m.includes("group")),
    "expected the function-body ({ … } group) finding; got:\n  " + findings.join("\n  ")
  );
});
test("item 6 RED #5: `false && {` before the invocation (#675 P2-a)", () => {
  const src = mutate(
    FIXTURE_CI_MAIN,
    "        node scripts/check-pi-pin-lockstep.mjs || failures=$((failures+1))\n",
    "        false && {\n" +
      "        node scripts/check-pi-pin-lockstep.mjs || failures=$((failures+1))\n" +
      "        }\n"
  );
  const findings = ciMainFindings(src);
  assert.ok(
    findings.some((m) => m.includes("sits inside") && m.includes("group")),
    `expected the short-circuit group finding; got:\n  ${findings.join("\n  ")}`
  );
});
test("item 6 RED #6: an inline `if …; then exit 0; fi` swallows the failure (#675 P2-a)", () => {
  const src = mutate(
    FIXTURE_CI_MAIN,
    "        if [ $failures -gt 0 ]; then\n",
    '        if [ "$CI" = "true" ]; then exit 0; fi\n' + "        if [ $failures -gt 0 ]; then\n"
  );
  const findings = ciMainFindings(src);
  assert.ok(
    findings.some((m) => m.includes("`exit 0`")),
    `expected the inline-exit-0 finding; got:\n  ${findings.join("\n  ")}`
  );
});
test("item 6 RED #7: `trap 'exit 0' EXIT` swallows the failure (#675 P2-a)", () => {
  const src = mutate(
    FIXTURE_CI_MAIN,
    "        node scripts/check-pi-pin-lockstep.mjs || failures=$((failures+1))\n",
    "        node scripts/check-pi-pin-lockstep.mjs || failures=$((failures+1))\n" +
      "        trap 'exit 0' EXIT\n"
  );
  const findings = ciMainFindings(src);
  assert.ok(
    findings.some((m) => m.includes("`trap … EXIT`")),
    `expected the trap finding; got:\n  ${findings.join("\n  ")}`
  );
});

// #675 P1-6 / #779 — a quoted keyword in ordinary prose must NOT open a block.
// The pre-fix detector split each line on non-word characters, so `echo
// "checking if the suite is wired"` before the invocation reddened BOTH legs.
test("item 6 GREEN: quoted `if`/`for`/`while` prose before the invocation is inert (#675 P1-6)", () => {
  const lines = [
    '        echo "checking if the suite is wired"',
    '        echo "for the record the pin suite is wired"',
    '        echo "while you wait the pin suite is wired"',
    "        # if/for/while notes live in this comment",
  ];
  for (const inserted of lines) {
    const src = mutate(
      FIXTURE_CI_MAIN,
      "        failures=0\n",
      `        failures=0\n${inserted}\n`
    );
    const findings = ciMainFindings(src);
    assert.deepEqual(
      findings,
      [],
      `${inserted.trim()} must stay GREEN (a quoted/comment keyword is not control flow):\n  ` +
        findings.join("\n  ")
    );
  }
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

// #675 P2-c — REQUIRED TEST NAMES. The count floor below is only a net-shrink
// guard: disabling 3 real tests and adding 3 `test("filler", () =>
// assert.ok(true))` no-ops kept it at "69 passed". A name is recorded by `test()`
// only when the test RUNS AND PASSES, so a deleted, renamed or neutered assertion
// is RED no matter what fills the count. At minimum: the two live-file
// assertions, every positive control, and one per guard section.
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
  "the ci-main fixture is wired (baseline for the post-merge RED cases)",
  "the lock covers exactly the three pin-gate workflow paths",
  "head-ref mode runs the structural assertions and does NOT apply the content lock",
  "head-ref mode is RED for an empty or comments-only ci.yml / node-ci.yml (#675 P1-1)",
  "the Contents API decode fails CLOSED on encoding 'none' or a lossy decode (#675 P1-1)",
  // regression fixtures added by the #675 review-fix cycle
  "the lock CLI is not a silent no-op through a symlinked path (#708 class, #675 P2-b)",
  "workflow coverage: an unclassified new workflow is RED (#675 P2-d)",
  "workflow coverage: deleting workflow-lock.yml is RED (#675 P2-d / P2-g)",
  "workflow-lock.yml exists and is wired (pull_request_target + --head-ref) (#675 P2-g)",
  "item 6 RED #1: the failure guard removed entirely (#675 P2-a)",
  "item 6 RED #2: the guard body replaced by an `echo` (#675 P2-a)",
  "item 6 RED #3: the invocation moved into a `case` arm (#675 P2-a)",
  "item 6 RED #4: the invocation inside a never-called shell function (#675 P2-a)",
  "item 6 RED #5: `false && {` before the invocation (#675 P2-a)",
  "item 6 RED #6: an inline `if …; then exit 0; fi` swallows the failure (#675 P2-a)",
  "item 6 RED #7: `trap 'exit 0' EXIT` swallows the failure (#675 P2-a)",
  "item 6 GREEN: quoted `if`/`for`/`while` prose before the invocation is inert (#675 P1-6)",
  "a deeply nested flow collection raises WorkflowYamlError quickly (#675 P2-6)",
]);

// A LOWER BOUND on the passing count — a secondary, net-shrink signal. The
// required-name set above is the primary identity check (#675 P2-c). This is a
// floor, not an equality: adding tests never needs an update; deleting one does.
const MIN_EXPECTED_PASSING = 91;
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
    "❌ required test(s) did not run and pass — a guard's test was deleted, renamed or " +
      "neutered; filler no-op tests cannot compensate (#675 P2-c):"
  );
  for (const name of missingRequired) console.error(`   - ${name}`);
}
if (failed > 0) {
  console.error("❌ SOME TESTS FAILED");
  process.exit(1);
}
console.log("✅ ALL TESTS PASSED");
