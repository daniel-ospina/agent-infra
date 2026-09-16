/**
 * heartbeat-progress-edges.test.ts — the consistency assertion (#1068)
 *
 * WHAT THIS SUITE GUARDS
 * ----------------------
 * `heartbeat-progress-edges.ts` is the ONE declaration of what counts as
 * progress, and `STALL_TERM_REGISTRY` is the ONE registry of stall/liveness
 * bounds. This suite makes the declaration load-bearing in three directions:
 *
 *   1. TABLE ↔ SOURCE PARITY (both ways). The child's clock-advancing call
 *      sites must equal the table's `advancesClock` rows; the parent's
 *      `parseHeartbeatLine` arms must implement exactly the effects their rows
 *      declare. Deleting a `touchActivity(...)` call, adding a `pi.on(edge)`
 *      handler the table does not declare, or moving a parent-side latch turns
 *      this red.
 *   2. REGISTRY ↔ SOURCE (both ways). Forward: every registered term must still
 *      be declared, with the registered value, in EVERY owner file. Reverse:
 *      every in-family declaration found by the scan must be registered or
 *      exempted with a substantive rationale.
 *   3. NON-VACUITY. A scan that read nothing must FAIL, not pass — the
 *      no-op-gate failure mode this whole issue exists to close.
 *
 * WHAT THIS SUITE DOES *NOT* DO
 * -----------------------------
 * It holds no `stall_threshold` value: #847
 * (`extensions/loop-enforcer/tier-config-parity.test.ts`) owns that across skill
 * surfaces, and a boundary check below asserts the split (a pointer exists, no
 * registered term carries a threshold value, and `skills/**` is outside the
 * corpus by construction).
 *
 * NO BEHAVIOUR IS ASSERTED HERE — only that the declarations agree with the
 * code. Every bound keeps its exact current value (see the forward assertion)
 * and no kill clause, clamp, or threshold is changed by this work.
 *
 * ZERO-DEPENDENCY: `node:*` + `./declared-surface.js` + `./heartbeat-progress-edges.js`
 * only — `extensions/builtin-tools/index.ts` is read AS SOURCE, never imported
 * (it pulls @sinclair/typebox, and the per-PR `ci.yml` `verify` job has no
 * `npm ci`).
 *
 * Run: npx tsx extensions/shared/heartbeat-progress-edges.test.ts
 *
 * WIRING HONESTY: per-PR this suite is VISIBLE but NOT merge-blocking (the
 * repo's only required check is `pipeline-compliance`); the blocking backstop is
 * the post-merge `ci-main.yml` `extensions/shared/*.test.ts` glob.
 *
 * Adversarial threat surface (declared in the scoping comment for #1068):
 *   T1 empty/renamed corpus → vacuity failure
 *   T2 exempted term with no rationale → violation
 *   T3 owner-file value changed, registry untouched → forward violation
 *   T4 new stall term under a matched family, unregistered → reverse violation
 *   T5 duplicate `stall_threshold` authority → boundary violation
 *   T6 activity edge removed / parent effect changed → parity violation
 */

import * as fs from "node:fs";
import * as path from "node:path";
import { fileURLToPath } from "node:url";
import { ok, equal } from "node:assert/strict";
import {
  driverViolations,
  forwardViolations,
  reverseViolations,
  scanDeclarations,
  vacuityFindings,
  type ScanResult,
} from "./declared-surface.js";
import {
  ACTIVITY_EDGE_EVENTS,
  CLOCK_RESET_EVENT,
  HEARTBEAT_KILL_REASONS,
  KILL_REASON_BOUNDS,
  LIFECYCLE_EVENTS,
  MARKER_KINDS,
  PROGRESS_DRIVERS,
  PROGRESS_EDGE_TABLE,
  STALL_SCAN_EXEMPTIONS,
  STALL_TERM_REGISTRY,
  childRegisteredEvents,
  stallScanSpec,
} from "./heartbeat-progress-edges.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, "../..");

const CHILD = "extensions/task-heartbeat.ts";
const PARENT = "extensions/builtin-tools/index.ts";
const TIER_CONFIG_PARITY = "extensions/loop-enforcer/tier-config-parity.test.ts";

let passed = 0;
let failed = 0;

function test(name: string, fn: () => void) {
  try {
    fn();
    passed++;
    console.log(`  ✅ ${name}`);
  } catch (err: any) {
    failed++;
    console.log(`  ❌ ${name}: ${err.message}\n${err.stack?.split("\n").slice(0, 4).join("\n")}`);
  }
}

function section(name: string) {
  console.log(`\n${name}:`);
}

function read(rel: string): string {
  return fs.readFileSync(path.join(REPO_ROOT, rel), "utf-8");
}

/** The `case "<kind>":` arms of a top-level switch inside `fnName` (4-space indent). */
function switchArms(src: string, fnName: string): Map<string, string> {
  const start = src.indexOf(`function ${fnName}(`);
  ok(start !== -1, `${fnName} not found in the parent`);
  const rest = src.slice(start);
  const endIdx = rest.indexOf("\n}\n");
  const body = endIdx === -1 ? rest : rest.slice(0, endIdx);
  const arms = new Map<string, string>();
  const re = /\n    case "([a-z_]+)":/g;
  const matches = [...body.matchAll(re)];
  for (let i = 0; i < matches.length; i++) {
    const from = matches[i].index as number;
    const to = i + 1 < matches.length ? (matches[i + 1].index as number) : body.length;
    arms.set(matches[i][1], body.slice(from, to));
  }
  return arms;
}

const childSrc = read(CHILD);
const parentSrc = read(PARENT);
const arms = switchArms(parentSrc, "parseHeartbeatLine");

const clockRows = PROGRESS_EDGE_TABLE.filter((r) => r.advancesClock);
const wireRows = PROGRESS_EDGE_TABLE.filter((r) => r.wireKind !== null);

// ── 1. table ↔ source parity ────────────────────────────────────────────────

section("table ↔ child source (the clock's edge set)");

test("every clock-advancing row has a touchActivity(\"<edge>\") call site, and no others do", () => {
  const sites = new Set<string>();
  const re = /touchActivity\("([a-z_]+)"\)/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(childSrc)) !== null) sites.add(m[1]);
  // The lifecycle reset is written as the named constant, not a bare literal.
  if (childSrc.includes("touchActivity(CLOCK_RESET_EVENT)")) sites.add(CLOCK_RESET_EVENT);

  const declared = new Set(clockRows.map((r) => r.event as string));
  equal(
    [...sites].sort().join(","),
    [...declared].sort().join(","),
    `child clock call sites ${JSON.stringify([...sites].sort())} must equal the table's advancesClock rows ${JSON.stringify([...declared].sort())} — a new pi.on edge with a touchActivity call, or a deleted call, must fail here`,
  );
  // Non-vacuity: the floor is 7 activity edges + the session_start reset.
  ok(sites.size >= ACTIVITY_EDGE_EVENTS.length + 1, `only ${sites.size} clock call sites found — the scan is vacuous`);
});

test("the child re-exports and consumes the shared declaration (not a second copy)", () => {
  ok(
    childSrc.includes('from "./shared/heartbeat-progress-edges.js"'),
    "task-heartbeat.ts must import the shared declaration",
  );
  ok(
    childSrc.includes("export { ACTIVITY_EDGE_EVENTS, LIFECYCLE_EVENTS }"),
    "task-heartbeat.ts must re-export the shared edge declaration it consumes",
  );
  // A restated literal edge set would defeat the structural coupling.
  ok(
    !/const ACTIVITY_EDGE_EVENTS\s*=\s*\[/.test(childSrc),
    "the child must not re-declare ACTIVITY_EDGE_EVENTS as its own array",
  );
});

test("the child's marker formatters emit exactly the declared wire kinds", () => {
  // Both directions: a declared kind with no formatter is dead vocabulary, and a
  // formatter emitting a kind outside the declaration is an UNPARSED wire line
  // (the parent would treat it as foreign stderr and preserve it).
  const emitted = new Set<string>();
  const re = /\$\{HEARTBEAT_MARKER_PREFIX\} ([a-z_]+) /g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(childSrc)) !== null) emitted.add(m[1]);
  equal(
    [...emitted].sort().join(","),
    [...MARKER_KINDS].sort().join(","),
    `child wire kinds ${JSON.stringify([...emitted].sort())} must equal MARKER_KINDS ${JSON.stringify([...MARKER_KINDS].sort())}`,
  );
  ok(emitted.size >= 7, "non-vacuity: the child must expose the full marker vocabulary");
});

test("ACTIVITY_EDGE_EVENTS is exactly the table's non-lifecycle advancing rows", () => {
  const declared = clockRows
    .filter((r) => r.event !== CLOCK_RESET_EVENT)
    .map((r) => r.event as string)
    .sort();
  equal([...ACTIVITY_EDGE_EVENTS].sort().join(","), declared.join(","));
  equal([...LIFECYCLE_EVENTS].sort().join(","), ["session_shutdown", "session_start"].join(","));
  equal(childRegisteredEvents().length, ACTIVITY_EDGE_EVENTS.length + LIFECYCLE_EVENTS.length);
});

section("table ↔ parent source (the parsed-marker effects)");

test("every registered child pi event has a handler in the child emitter", () => {
  // The parent's :2417 handler list is REPLACED by this derived equality: the
  // child registers exactly the activity edges plus the two lifecycle events.
  const handlers = new Set<string>();
  const re = /pi\.on\("([a-z_]+)"/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(childSrc)) !== null) handlers.add(m[1]);
  equal(
    [...handlers].sort().join(","),
    [...childRegisteredEvents()].sort().join(","),
    `registered handlers ${JSON.stringify([...handlers].sort())} must equal ACTIVITY_EDGE_EVENTS ∪ LIFECYCLE_EVENTS`,
  );
});

test("the parent derives KNOWN_MARKER_KINDS from the shared MARKER_KINDS", () => {
  ok(
    /export const KNOWN_MARKER_KINDS = new Set<string>\(MARKER_KINDS\);/.test(parentSrc),
    "KNOWN_MARKER_KINDS must be derived from MARKER_KINDS, not restated as a literal list",
  );
  ok(
    parentSrc.includes('from "../shared/heartbeat-progress-edges.js"'),
    "builtin-tools/index.ts must import the shared declaration",
  );
});

test("parseHeartbeatLine's arms are exactly the declared wire kinds", () => {
  equal(
    [...arms.keys()].sort().join(","),
    [...MARKER_KINDS].sort().join(","),
    `parser arms ${JSON.stringify([...arms.keys()].sort())} must equal MARKER_KINDS ${JSON.stringify([...MARKER_KINDS].sort())}`,
  );
  ok(arms.size >= 7, "non-vacuity: the parser must expose the full marker vocabulary");
});

test("each wire row's declared parent-side effects match its arm, in BOTH directions", () => {
  for (const row of wireRows) {
    const arm = arms.get(row.wireKind as string);
    ok(arm !== undefined, `${row.id}: no case arm for wire kind ${row.wireKind}`);
    equal(arm!.includes("everSawRealActivity = true"), row.realActivity, `${row.id}: realActivity`);
    equal(arm!.includes("everSawWork = true"), row.workOnly, `${row.id}: workOnly (everSawWork is latched only by tool_start/turn_start)`);
    equal(arm!.includes("streamAgeMs = 0"), row.resetsStreamAge, `${row.id}: resetsStreamAge`);
    equal(arm!.includes("toolAgeMaxMs = 0"), row.resetsToolAge, `${row.id}: resetsToolAge`);
    equal(arm!.includes("toolUpdates = v === 1"), row.drivesToolUpdates, `${row.id}: drivesToolUpdates`);
    equal(arm!.includes("toolUpdates = false"), row.resetsToolUpdates, `${row.id}: resetsToolUpdates`);
  }
});

test("forward assertions: each parent-side writing ARM set equals its declared row set", () => {
  // Moves or renames an arm, or changes an effect, must fail — this is the
  // direction the cycle-3 verifier found unasserted when the tick row was
  // excluded from the parity loop.
  const writing = (needle: string) =>
    [...arms.entries()].filter(([, body]) => body.includes(needle)).map(([k]) => k).sort().join(",");
  const declared = (pred: (r: (typeof PROGRESS_EDGE_TABLE)[number]) => boolean) =>
    wireRows.filter(pred).map((r) => r.wireKind as string).sort().join(",");

  equal(writing("everSawRealActivity = true"), declared((r) => r.realActivity), "realActivity writers");
  equal(writing("everSawWork = true"), declared((r) => r.workOnly), "everSawWork writers (workOnly)");
  equal(writing("streamAgeMs = 0"), declared((r) => r.resetsStreamAge), "stream-age reset writers");
  equal(writing("toolAgeMaxMs = 0"), declared((r) => r.resetsToolAge), "tool-age reset writers");
  equal(writing("toolUpdates = v === 1"), declared((r) => r.drivesToolUpdates), "the SOLE wire writer of toolUpdates");
  equal(writing("toolUpdates = false"), declared((r) => r.resetsToolUpdates), "conditional toolUpdates clearers");
});

test("the synthetic tick row declares the parser's real-activity latch, not a wire effect", () => {
  const tick = PROGRESS_EDGE_TABLE.find((r) => r.id === "child-tick");
  ok(tick !== undefined, "the tick row must be declared");
  ok(tick!.synthetic, "the tick row is synthetic (no child pi event)");
  equal(tick!.advancesClock, false, "the tick emits the clock; it does not advance it");
  ok(tick!.realActivityCondition !== undefined, "the tick's conditional latch must be declared");
  const arm = arms.get("tick");
  ok(arm !== undefined, "no case arm for the tick");
  for (const term of ["toolsInFlight > 0", "turnSawMessage", "turnSawTool"]) {
    ok(arm!.includes(term), `the declared tick realActivity condition must reference ${term}`);
  }
  ok(!arm!.includes("everSawRealActivity = true"), "the tick latches conditionally, never unconditionally");
});

test("no row declares a wire effect without a wire kind, or vice versa", () => {
  for (const row of PROGRESS_EDGE_TABLE) {
    if (row.wireKind === null) {
      equal(row.drivesToolUpdates, false, `${row.id}: a row with no wire kind cannot drive a wire-fed field`);
      equal(row.resetsToolUpdates, false, `${row.id}: a row with no wire kind cannot clear a wire-fed field`);
      equal(row.resetsStreamAge, false, `${row.id}: the parent never sees this edge`);
      equal(row.resetsToolAge, false, `${row.id}: the parent never sees this edge`);
      equal(row.realActivity, false, `${row.id}: the parent never sees this edge`);
      equal(row.workOnly, false, `${row.id}: the parent never sees this edge`);
    }
  }
});

// ── 2. the kill-reason clause vocabulary ────────────────────────────────────

section("kill-reason clause set");

test("every HeartbeatKillReason member is registered with its driving bound", () => {
  ok(HEARTBEAT_KILL_REASONS.length >= 8, `expected ≥8 collision-free clauses, found ${HEARTBEAT_KILL_REASONS.length}`);
  for (const r of HEARTBEAT_KILL_REASONS) {
    ok(typeof KILL_REASON_BOUNDS[r] === "string" && KILL_REASON_BOUNDS[r].length > 0, `${r}: no bound declared`);
  }
  equal(
    Object.keys(KILL_REASON_BOUNDS).sort().join(","),
    [...HEARTBEAT_KILL_REASONS].sort().join(","),
    "the clause→bound map must cover exactly the clause set",
  );
  ok(
    KILL_REASON_BOUNDS["tool-silence"].includes("same bound as stream-stall"),
    "stream-stall and tool-silence share ONE constant (S) — the registry must say so rather than implying two bounds",
  );
  ok(parentSrc.includes("HEARTBEAT_KILL_REASONS"), "the parent must consume the declared clause set");
  ok(
    /export type HeartbeatKillReason = HeartbeatKillReasonName;/.test(parentSrc),
    "the parent's union type must be derived from the declared set",
  );
});

// ── 3. registry ↔ source ────────────────────────────────────────────────────

section("registry ↔ source (forward)");

const spec = stallScanSpec(REPO_ROOT);
const scan = scanDeclarations(spec, (f) => fs.readFileSync(path.join(REPO_ROOT, f), "utf-8"));
const FLOORS = { minFiles: 100, minDeclarations: 25 };

test("every registered term is still declared, with its registered value, in every owner", () => {
  const v = forwardViolations(STALL_TERM_REGISTRY, (f) => fs.readFileSync(path.join(REPO_ROOT, f), "utf-8"));
  equal(v.length, 0, `forward violations:\n  - ${v.join("\n  - ")}`);
});

test("the shipped values are the ones the repo actually carries (no behaviour drift)", () => {
  // A literal spot-check of the five bounds this issue exists to make visible,
  // so a simultaneous edit to registry AND owner is still an explicit diff.
  const byName = new Map(STALL_TERM_REGISTRY.map((t) => [t.name, t]));
  equal(byName.get("DEFAULT_STREAM_STALL_MS")?.value, "= 1_200_000;");
  equal(byName.get("DEFAULT_TOOL_STALL_MS")?.value, "= 21_600_000;");
  equal(byName.get("DEFAULT_FIRST_MESSAGE_MS")?.value, "= 300_000;");
  equal(byName.get("TASK_TOOL_STALL_FRACTION")?.value, "= 2 / 3;");
  equal(byName.get("WALL_CLOCK_STALL_MS")?.value, "= 5 * 60 * 1000;");
  equal(byName.get("STALL_THRESHOLD")?.value, null, "STALL_THRESHOLD is a POINTER — #847 owns its value");
});

section("registry ↔ source (reverse)");

test("every in-family declaration is registered or exempted with a rationale", () => {
  const v = reverseViolations(scan, STALL_TERM_REGISTRY, STALL_SCAN_EXEMPTIONS);
  equal(v.length, 0, `reverse violations:\n  - ${v.join("\n  - ")}`);
});

test("non-vacuity: the scan reads the real corpus and finds the real declarations", () => {
  const v = vacuityFindings(scan, FLOORS);
  equal(v.length, 0, `vacuity violations:\n  - ${v.join("\n  - ")}`);
  // The floors must be a real floor, not a number chosen to match today's count.
  const empty: ScanResult = { files: [], filesScanned: 0, declarations: [] };
  ok(vacuityFindings(empty, FLOORS).length > 0, "an empty scan MUST be a violation");
  ok(
    scan.declarations.length >= FLOORS.minDeclarations,
    `found ${scan.declarations.length} declarations against a floor of ${FLOORS.minDeclarations}`,
  );
});

test("a NEW unregistered stall bound fails the reverse scan (fails-if-removed proof)", () => {
  // Drives the real registry/exemption pair against a synthetic corpus that
  // contains a seventh term — proving the assertion can fire.
  const synthetic = scanDeclarations({ ...spec, files: ["extensions/task-heartbeat.ts"] }, () =>
    'export const NEW_STALL_BOUND_MS = 42;\n',
  );
  const v = reverseViolations(synthetic, STALL_TERM_REGISTRY, STALL_SCAN_EXEMPTIONS);
  ok(v.length > 0, "a newly declared stall bound must be a violation");
  ok(v[0].includes("NEW_STALL_BOUND_MS"), v[0]);
});

section("independent drivers");

test("every registered progress driver exists, and a non-sharing one states why", () => {
  const v = driverViolations(PROGRESS_DRIVERS, (f) => fs.readFileSync(path.join(REPO_ROOT, f), "utf-8"));
  equal(v.length, 0, `driver violations:\n  - ${v.join("\n  - ")}`);
  ok(PROGRESS_DRIVERS.length >= 5, `expected ≥5 drivers, found ${PROGRESS_DRIVERS.length}`);
  ok(
    PROGRESS_DRIVERS.some((d) => d.sharesDeclaration),
    "at least one driver must consume the shared declaration",
  );
  ok(
    PROGRESS_DRIVERS.some((d) => !d.sharesDeclaration),
    "the registry must record that some axes are legitimately separate",
  );
});

// ── 4. the #847 boundary (no second authority) ──────────────────────────────

section("#847 boundary — one stall_threshold authority");

test("no registered term carrying a /stall_?threshold/i name holds a value here", () => {
  const offenders = STALL_TERM_REGISTRY.filter((t) => /stall_?threshold/i.test(t.name) && t.value !== null);
  equal(
    offenders.length,
    0,
    `${offenders.map((o) => o.name).join(", ")} — the value is owned by #847; this registry may only POINT at it`,
  );
});

test("#847's declared-surface gate still exists and is non-vacuous", () => {
  const src = read(TIER_CONFIG_PARITY);
  ok(src.includes("STALL_THRESHOLD_SURFACES"), "STALL_THRESHOLD_SURFACES must still exist in tier-config-parity.test.ts");
  const decl = src.slice(src.indexOf("export const STALL_THRESHOLD_SURFACES"));
  const list = decl.slice(0, decl.indexOf("];"));
  const entries = [...list.matchAll(/"[^"]+\.md"/g)];
  ok(
    entries.length >= 7,
    `STALL_THRESHOLD_SURFACES declared ${entries.length} surfaces (< 7) — the sibling gate was emptied or narrowed`,
  );
  ok(src.includes("#1068"), "the sibling gate must record the split that gives this registry its boundary");
});

test("the scan corpus structurally excludes skills/** (where the stall_threshold surfaces live)", () => {
  ok(spec.files.length > 0, "the corpus must not be empty");
  const offenders = spec.files.filter((f) => f.startsWith("skills/"));
  equal(offenders.length, 0, `skills/ is #847's surface and must not be scanned here: ${offenders.join(", ")}`);
});

section("Results");

console.log(`\n=== Results: ${passed} passed, ${failed} failed ===`);
if (failed > 0) {
  console.log("❌ SOME TESTS FAILED");
  process.exit(1);
}
console.log("✅ ALL TESTS PASSED");
