/**
 * tool-call-event.test.ts — zero-dependency suite for the shared predicate copy
 * (#1330).
 *
 * Run: npx tsx extensions/shared/tool-call-event.test.ts   (from any checkout)
 *
 * TWO JOBS, both of which must run without the SDK:
 *
 *   A. BEHAVIOUR — pin the copy's semantics (including the malformed-event
 *      cases) so a later "defensive" edit is a RED test rather than a silent
 *      divergence from upstream. Upstream pi 0.85.1 reads `event.toolName`
 *      directly (`dist/core/extensions/types.js:45-47`), so a `null`/`undefined`
 *      event THROWS. An earlier private copy used `event?.toolName`, which
 *      swallowed exactly that case — see the header of ./tool-call-event.ts.
 *
 *   B. SINGLE HOME — assert there is exactly ONE definition of the predicate
 *      under extensions/ and that the extensions which had private copies now
 *      import it. This is the half that makes the SDK-bearing parity pin in
 *      extensions/verification-gate/tool-call-event-parity.test.ts cover every
 *      consumer: re-inlining the predicate anywhere would otherwise recreate the
 *      #1330 failure mode (a copy that drifts while the gate reports `✅ Loaded`)
 *      with the pin still green over a module nobody runs.
 *
 * This file deliberately has no SDK import: `ci.yml`'s `verify` job performs no
 * `npm ci`, so a suite that needs the package cannot run there. The parity
 * assertion against the REAL export is its SDK-bearing counterpart
 * (extensions/verification-gate/tool-call-event-parity.test.ts); that file's
 * presence and wiring are asserted below, so the split is visible rather than
 * looking like an omission.
 */
import { ok, equal, deepEqual, throws } from "node:assert/strict";
import { readFileSync, readdirSync, statSync, existsSync } from "node:fs";
import { join, resolve, extname } from "node:path";
import { isToolCallEventType } from "./tool-call-event.js";

const REPO_ROOT = resolve(import.meta.dirname, "..", "..");
const EXT_ROOT = join(REPO_ROOT, "extensions");

let passed = 0;
let failed = 0;
const failures: string[] = [];
function test(name: string, fn: () => void) {
  try {
    fn();
    passed += 1;
    console.log(`  ✅ ${name}`);
  } catch (err) {
    failed += 1;
    failures.push(name);
    console.log(`  ❌ ${name}\n     ${err instanceof Error ? err.message : String(err)}`);
  }
}
function section(name: string) {
  console.log(`\n${name}`);
}

// ── A. behaviour ─────────────────────────────────────
section("A. behaviour of the shared predicate (upstream pi 0.85.1 semantics)");

test("a matching tool name is true; a different one is false", () => {
  equal(isToolCallEventType("bash", { toolName: "bash", input: { command: "git commit" } }), true);
  equal(isToolCallEventType("read", { toolName: "read", input: { path: "/x" } }), true);
  equal(isToolCallEventType("bash", { toolName: "read", input: {} }), false);
});

test("the match is on the TOP-LEVEL toolName — a relocated name is NOT matched", () => {
  // These are the upgrade shapes the pin exists for: if pi ever moves the tool
  // name, upstream starts returning true for one of these (its body changes) and
  // the parity suite fails. This suite pins that OUR copy does not guess.
  equal(isToolCallEventType("bash", {}), false, "absent toolName");
  equal(isToolCallEventType("bash", { toolCall: { name: "bash" } }), false, "nested under toolCall");
  equal(isToolCallEventType("bash", { name: "bash" }), false, "keyed as `name`");
  equal(isToolCallEventType("bash", { input: { toolName: "bash" } }), false, "nested under input");
});

test("a non-string toolName never matches a string", () => {
  equal(isToolCallEventType("bash", { toolName: undefined }), false);
  equal(isToolCallEventType("bash", { toolName: null }), false);
  equal(isToolCallEventType("bash", { toolName: 5 }), false);
  equal(isToolCallEventType("bash", { toolName: { name: "bash" } }), false);
});

test("the empty tool name matches an empty toolName (no truthiness shortcut)", () => {
  equal(isToolCallEventType("", { toolName: "" }), true);
  equal(isToolCallEventType("", { toolName: "bash" }), false);
});

test("the lookup is a property READ — an inherited toolName still matches", () => {
  const inherited = Object.create({ toolName: "bash" }) as object;
  equal(isToolCallEventType("bash", inherited), true,
    "upstream is `event.toolName === toolName`; switching to hasOwnProperty would change this");
});

test("a malformed event THROWS, exactly as upstream does (no optional chain)", () => {
  throws(() => isToolCallEventType("bash", null), TypeError,
    "upstream reads event.toolName unguarded; `event?.toolName` would return false here instead");
  throws(() => isToolCallEventType("bash", undefined), TypeError);
  // Primitives do not throw — property access on them is defined.
  equal(isToolCallEventType("bash", 5), false);
  equal(isToolCallEventType("bash", "bash"), false);
  equal(isToolCallEventType("bash", []), false);
});

// ── B. single home ───────────────────────────────────
section("B. the predicate has exactly ONE definition under extensions/");

/** Every `.ts`/`.mjs`/`.js` file under extensions/, skipping node_modules + dot-dirs. */
function collectSourceFiles(dir: string, out: string[] = []): string[] {
  for (const entry of readdirSync(dir)) {
    if (entry === "node_modules" || entry.startsWith(".")) continue;
    const p = join(dir, entry);
    if (statSync(p).isDirectory()) collectSourceFiles(p, out);
    else if ([".ts", ".mjs", ".js"].includes(extname(p))) out.push(p);
  }
  return out;
}

/**
 * A DECLARATION of the predicate — `function`/`const`/`let`/`var named
 * isToolCallEventType. Matches an `export function` too. Deliberately not a grep
 * for the bare name: import statements, calls and comments must all be allowed
 * (they are how every consumer uses it).
 *
 * TEST FILES ARE EXCLUDED, and that is not a loophole. Exactly one file is
 * excluded — `*.test.ts` — because a suite legitimately carries the predicate's
 * TEXT inside its own assertions (skill-enforcer.test.ts pins that the module no
 * longer inlines it). Everything else under extensions/ is scanned, including the
 * `test-*.mjs` / `*.test.mjs` suites and the two loader hooks: a stub or helper
 * that declares its own copy is a second PRODUCTION-SHAPED copy, and it is the
 * copy a pi upgrade would silently drift.
 */
const DECL_RE = /\b(?:export\s+)?(?:function|const|let|var)\s+isToolCallEventType\b/;
const isAssertionCarrier = (p: string) => p.endsWith(".test.ts");

const SHARED_PREDICATE = join("extensions", "shared", "tool-call-event.ts");
const allSources = collectSourceFiles(EXT_ROOT);
const scanned = allSources.filter((f) => !isAssertionCarrier(f));
const declarers = scanned
  .filter((f) => DECL_RE.test(readFileSync(f, "utf8")))
  .map((f) => f.slice(REPO_ROOT.length + 1));

test("the walk really saw the tree (a renamed corpus must not read as a clean scan)", () => {
  ok(scanned.length >= 60,
    `expected a real corpus under extensions/, saw ${scanned.length} file(s)`);
  ok(allSources.length > scanned.length,
    "expected the walk to see .test.ts files too (otherwise the exclusion above excludes nothing)");
  ok(declarers.includes(SHARED_PREDICATE),
    `the scan did not find the shared predicate — it is vacuous. Found: ${JSON.stringify(declarers)}`);
});

test("exactly one definition exists, and it is extensions/shared/tool-call-event.ts", () => {
  deepEqual(declarers, [SHARED_PREDICATE],
    "a second definition re-creates #1330: a private copy drifts under a pi upgrade while the " +
      "gate keeps reporting success, and the parity pin stays green over the shared module.\n" +
      "Consumers must import it (./shared/tool-call-event.js, ../shared/tool-call-event.js).\n" +
      "Loader-hook SDK stubs must re-export it, not re-declare it.");
});

test("the consumers import the shared predicate rather than re-declaring it", () => {
  const consumers: Array<[string, string]> = [
    ["extensions/skill-enforcer.ts", 'from "./shared/tool-call-event.js"'],
    ["extensions/sequence-enforcer/index.ts", 'from "../shared/tool-call-event.js"'],
  ];
  for (const [rel, specifier] of consumers) {
    const src = readFileSync(join(REPO_ROOT, rel), "utf8");
    ok(src.includes(`import { isToolCallEventType } ${specifier}`),
      `${rel} must import the shared predicate (${specifier})`);
  }
});

test("the loader-hook SDK stubs re-export the shared predicate (no third copy)", () => {
  for (const rel of [
    "extensions/main-worktree-guard/module-load-hooks.mjs",
    "extensions/task-cwd-guard/loader-hooks.mjs",
  ]) {
    const src = readFileSync(join(REPO_ROOT, rel), "utf8");
    ok(src.includes("export { isToolCallEventType }"),
      `${rel} must re-export the shared predicate — its own copy was an un-pinned second copy of an SDK function`);
    ok(src.includes("shared/tool-call-event.ts"),
      `${rel} must point at extensions/shared/tool-call-event.ts`);
  }
});

test("the shared module stays zero-dependency (the bare-checkout contract)", () => {
  const src = readFileSync(join(REPO_ROOT, SHARED_PREDICATE), "utf8");
  equal(/^\s*import\b/m.test(src), false,
    "an import here would make the zero-dep gate suites require node_modules — the reason the copy exists");
});

test("the SDK-bearing parity suite is present and wired to the same module", () => {
  const rel = join("extensions", "verification-gate", "tool-call-event-parity.test.ts");
  const p = join(REPO_ROOT, rel);
  ok(existsSync(p), `${rel} is missing — the shared copy would then have no pin against the real export`);
  const src = readFileSync(p, "utf8");
  ok(src.includes('from "../shared/tool-call-event.js"'),
    `${rel} must import the shared predicate it pins`);
  ok(src.includes("@earendil-works/pi-coding-agent"),
    `${rel} must import the real SDK export it pins against`);
});

// ── results ──────────────────────────────────────────
console.log(`\n=== Results: ${passed} passed, ${failed} failed ===`);
if (failed > 0) {
  console.log("❌ SOME TESTS FAILED");
  for (const f of failures) console.log(`   - ${f}`);
  process.exit(1);
}
console.log("✅ ALL TESTS PASSED");
