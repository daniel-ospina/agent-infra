/**
 * subagent-parity.test.ts — #783 Task 7.3 parity pin for extensions/subagent/
 *
 * WHY THIS EXISTS: #783 Task 5 split the builtin-tools tool-stall constant. The
 * TASK path now resolves its own bound — since #783 §6.6 a 2/3-of-effective-cap
 * DERIVATION (`TASK_TOOL_STALL_FRACTION`, unexported, env
 * `TASK_TOOL_STALL_MS`) rather than a fixed 2 h literal — while
 * `DEFAULT_TOOL_STALL_MS` stays FROZEN at 6 h
 * precisely BECAUSE extensions/subagent/index.ts imports it and derives its own
 * backstop from it. The regression this pins: lowering the frozen export to the
 * task bound would silently drag the SUBAGENT backstop below the hard cap. This
 * suite proves the subagent extension was not dragged along and still owns its
 * own timeout/stall semantics.
 *
 * WHY A SOURCE PIN, NOT AN IMPORT: importing `./index.js` pulls four
 * `@earendil-works/*` runtime packages (so it requires `npm ci` in
 * extensions/subagent) AND registers the subagent tool on the pi extension API
 * at module load. `readFileSync` over the two source files is hermetic,
 * zero-dependency (`node:*` only) and side-effect free, so it runs anywhere —
 * the same form the plan sanctions for the no-`npm ci` surface (see
 * extensions/shared/default-coverage.test.ts). The runtime behaviour of this
 * package is separately covered by index.test.ts / timeout-integration.test.ts.
 *
 * ⚠️ This is deliberately NOT a repo-wide "`--no-session` appears nowhere" grep:
 * subagent/index.ts LEGITIMATELY retains `--no-session` (its children are
 * ephemeral by design). This pin asserts it is STILL there, at the documented
 * arg vector — removing it would be the regression, not keeping it.
 *
 * WIRING HONESTY: run by ci-main.yml's extension-tests job (post-merge, in the
 * block that runs `npm ci` in extensions/subagent), NOT ci.yml's `verify` job —
 * that job deliberately performs no `npm ci`. Like every suite in that job this
 * is post-merge only; the per-PR gate is ci.yml's `verify`.
 *
 * Run: npx tsx extensions/subagent/subagent-parity.test.ts
 */

import * as fs from "node:fs";
import * as path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, "../..");

const SUBAGENT_SRC = path.join(REPO_ROOT, "extensions/subagent/index.ts");
const BUILTIN_SRC = path.join(REPO_ROOT, "extensions/builtin-tools/index.ts");

const subagent = fs.readFileSync(SUBAGENT_SRC, "utf-8");
const builtin = fs.readFileSync(BUILTIN_SRC, "utf-8");

let passed = 0;
let failed = 0;
let positiveChecks = 0;

function test(name: string, fn: () => void) {
  try {
    fn();
    passed++;
    console.log(`  ✅ ${name}`);
  } catch (err: any) {
    failed++;
    console.log(`  ❌ ${name}: ${err.message}`);
  }
}

function section(name: string) {
  console.log(`\n${name}:`);
}

function count(haystack: string, needle: string): number {
  return haystack.split(needle).length - 1;
}

/** Assert the anchor is present (≥1). `positiveChecks` is the non-vacuity
 * guard: 0 means every assertion was a negative and the parse proved nothing. */
function has(src: string, needle: string, label: string) {
  positiveChecks++;
  if (count(src, needle) < 1) throw new Error(`missing: ${label} — «${needle}»`);
}

/** Assert the anchor is present EXACTLY once — guards against an ambiguous
 * copy-paste target (a second arg vector, a duplicated getter). */
function hasOnce(src: string, needle: string, label: string) {
  positiveChecks++;
  const n = count(src, needle);
  if (n !== 1) throw new Error(`expected exactly 1 «${label}», got ${n}`);
}

/** Assert the anchor is absent. */
function lacks(src: string, needle: string, label: string) {
  if (count(src, needle) !== 0) throw new Error(`unexpected: ${label} — «${needle}»`);
}

section("Shared seam (import from builtin-tools)");

test("imports the FROZEN tool-stall export by name (the split's whole reason)", () => {
  hasOnce(
    subagent,
    `import { getSubAgentPath, DEFAULT_TOOL_STALL_MS, resolveProviderModel } from "../builtin-tools/index.js";`,
    "builtin-tools import seam",
  );
});

section("The extension's OWN timeout/stall semantics are intact");

test("keeps its own local margins", () => {
  hasOnce(subagent, `const DEFAULT_BACKSTOP_MARGIN_MS = 1_800_000;`, "30-min local margin");
  hasOnce(subagent, `const DEFAULT_EXIT_SETTLE_GRACE_MS = 2_000;`, "exit-settle grace");
  hasOnce(
    subagent,
    `export const DEFAULT_SUBAGENT_BACKSTOP_MARGIN_MS = 900_000;`,
    "#208 15-min subagent margin",
  );
});

test("getSubagentBackstopMs keeps BOTH of its own branches", () => {
  hasOnce(
    subagent,
    `if (taskTimeoutMs > 0) return taskTimeoutMs + DEFAULT_SUBAGENT_BACKSTOP_MARGIN_MS;`,
    "taskTimeout>0 branch",
  );
  hasOnce(
    subagent,
    `return DEFAULT_TOOL_STALL_MS + DEFAULT_BACKSTOP_MARGIN_MS;`,
    "timeout-opt-out branch uses the FROZEN 6h export",
  );
});

test("keeps its own env-tunable timeout bounds", () => {
  has(subagent, `SUBAGENT_TASK_TIMEOUT_MS`, "SUBAGENT_TASK_TIMEOUT_MS");
  has(subagent, `SUBAGENT_BACKSTOP_MS`, "SUBAGENT_BACKSTOP_MS");
  has(subagent, `SUBAGENT_BACKSTOP_FRESH_MS`, "SUBAGENT_BACKSTOP_FRESH_MS");
});

test("--no-session is RETAINED at the documented arg vector (ephemeral children by design)", () => {
  hasOnce(
    subagent,
    `const args: string[] = ["--mode", "json", "-p", "--no-session"];`,
    "subagent arg vector",
  );
});

section("NOT dragged along by #783 Task 5's constant split");

test("subagent never references the task-path bound or its resolver", () => {
  lacks(subagent, `DEFAULT_TASK_TOOL_STALL_MS`, "task-path bound (the removed fixed-2h constant)");
  lacks(subagent, `TASK_TOOL_STALL_FRACTION`, "task-path bound (its 2/3-of-cap derivation)");
  lacks(subagent, `TASK_TOOL_STALL_MS`, "task-path env override");
  lacks(subagent, `getToolStallMs`, "task-path resolver");
  lacks(subagent, `getTaskHardCapMs`, "task hard cap resolver");
  lacks(subagent, `DEFAULT_HARD_CAP_MS`, "task hard cap constant");
});

test("the frozen export is still 6h and still exported", () => {
  positiveChecks++;
  if (!/^export const DEFAULT_TOOL_STALL_MS = 21_600_000;/m.test(builtin)) {
    throw new Error("builtin-tools DEFAULT_TOOL_STALL_MS is no longer exported at 6h");
  }
});

test("the task-path bound is real, is TASK-LOCAL (unexported), and cannot drag the subagent down", () => {
  positiveChecks++;
  // #783 §6.6 (P2): the task-path bound is now DERIVED from the effective hard
  // cap (2/3 → 4h at the 6h default) instead of a fixed 2h literal, so the
  // symbol changed. The PROPERTY this guards is unchanged — the subagent path
  // must not be dragged along — so pin the derivation instead of the literal.
  if (!/^const TASK_TOOL_STALL_FRACTION = 2 \/ 3;/m.test(builtin)) {
    throw new Error("builtin-tools TASK_TOOL_STALL_FRACTION is not the 2/3 task-local derivation");
  }
  lacks(
    builtin,
    `export const TASK_TOOL_STALL_FRACTION`,
    "task-local derivation must stay unexported (subagent must not import it)",
  );
  // The old fixed constant must be GONE, not merely unused: leaving it behind
  // is how a fixed default silently outlives the derivation that replaced it.
  lacks(
    builtin,
    `export const DEFAULT_TASK_TOOL_STALL_MS`,
    "task-local constant must stay unexported (subagent must not import it)",
  );
});

section("Non-vacuity");

test("both sources were really read (non-empty, positive checks ran)", () => {
  if (subagent.length < 10_000) throw new Error(`subagent/index.ts looks truncated (${subagent.length} bytes)`);
  if (builtin.length < 10_000) throw new Error(`builtin-tools/index.ts looks truncated (${builtin.length} bytes)`);
  if (positiveChecks < 10) throw new Error(`only ${positiveChecks} positive checks — parse proved too little`);
});

console.log(`\n=== Results: ${passed} passed, ${failed} failed ===`);
if (failed > 0) {
  console.log("❌ SOME TESTS FAILED");
  process.exit(1);
}
console.log("✅ ALL TESTS PASSED");
