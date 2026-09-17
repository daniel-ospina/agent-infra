/**
 * heartbeat-progress-edges.test.ts — the consistency assertion (#1068)
 *
 * WHAT THIS SUITE GUARDS
 * ----------------------
 * `heartbeat-progress-edges.ts` is the ONE declaration of what counts as
 * progress, and `STALL_TERM_REGISTRY` is the ONE registry of stall/liveness
 * bounds. This suite makes the declaration load-bearing in four directions:
 *
 *   1. TABLE ↔ SOURCE PARITY (both ways). The child's clock-advancing call
 *      sites must equal the table's `advancesClock` rows; the child's marker
 *      formatters must emit exactly `MARKER_KINDS`; its `updatedToolIds` call
 *      sites must equal the rows declaring `feedsToolUpdates`; and the parent's
 *      `parseHeartbeatLine` arms must implement exactly the effects their rows
 *      declare. Deleting a `touchActivity(...)` call, adding a `pi.on(edge)`
 *      handler the table does not declare, or moving a parent-side latch turns
 *      this red.
 *   2. KILL-CLAUSE ↔ SOURCE. Every `kill("<clause>")` literal in the parent must
 *      be a declared `HEARTBEAT_KILL_REASONS` member and vice versa. A TYPE
 *      alias cannot do this job: the repo has no root tsconfig, so no typecheck
 *      runs in CI.
 *   3. REGISTRY ↔ SOURCE (both ways). Forward: every registered term must still
 *      be declared (declaration-SHAPED, on comment-stripped source), with the
 *      registered value, in EVERY owner file, and a registered term must not be
 *      re-declared in a file the registry does not list as an owner. Reverse:
 *      every in-family declaration found by the scan must be registered or
 *      exempted with a substantive rationale.
 *   4. NON-VACUITY. A scan that read nothing must FAIL, not pass — the
 *      no-op-gate failure mode this whole issue exists to close.
 *
 * SOURCE SCANS RUN ON COMMENT-STRIPPED TEXT. A scan over raw source is
 * satisfied by a COMMENT that names or quotes what it looks for, so it reports
 * agreement between two things that do not exist (`declared-surface.ts`:
 * "a scan that reads comments is a scan that lies").
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
  inFamily,
  isCommentLine,
  langOf,
  reverseViolations,
  scanDeclarations,
  vacuityFindings,
  yieldCommentLines,
  type ScanResult,
} from "./declared-surface.js";
import {
  ACTIVITY_EDGE_EVENTS,
  CLOCK_RESET_EVENT,
  OUT_OF_FAMILY_TERMS,
  HEARTBEAT_KILL_REASONS,
  KILL_REASON_BOUNDS,
  LIFECYCLE_EVENTS,
  MARKER_KINDS,
  PROGRESS_DRIVERS,
  PROGRESS_EDGE_TABLE,
  SCAN_AGE_SUFFIXES,
  SCAN_BOUND_SUFFIXES,
  SCAN_NAME_FAMILIES,
  STALL_AXES,
  STALL_SCAN_EXEMPTIONS,
  STALL_TERM_REGISTRY,
  childRegisteredEvents,
  isActivityEdge,
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

/** Each `pi.on("<event>", async (...) => {` handler's OWN body (up to `\n  });`). */
function childHandlerBodies(src: string): Map<string, string> {
  const bodies = new Map<string, string>();
  for (const m of src.matchAll(/pi\.on\("([a-z_]+)", async \([^)]*\) => \{/g)) {
    const start = (m.index as number) + m[0].length;
    const end = src.indexOf("\n  });", start);
    bodies.set(m[1], src.slice(start, end === -1 ? src.length : end));
  }
  return bodies;
}

const childSrc = read(CHILD);
const parentSrc = read(PARENT);
// Every source scan below runs on the text with comment LINES blanked: a raw
// scan is satisfied by a comment that merely quotes what it looks for. The
// transform is line-local and stateless (see declared-surface.ts), so it can
// only blank a line that begins with a comment marker — a real declaration can
// never be deleted and a comment can never be copied through verbatim.
const childCode = yieldCommentLines(childSrc, "ts");
const parentCode = yieldCommentLines(parentSrc, "ts");
const arms = switchArms(parentCode, "parseHeartbeatLine");

const clockRows = PROGRESS_EDGE_TABLE.filter((r) => r.advancesClock);
const wireRows = PROGRESS_EDGE_TABLE.filter((r) => r.wireKind !== null);

// ── 1. table ↔ source parity ────────────────────────────────────────────────

section("table ↔ child source (the clock's edge set)");

test("every clock-advancing row has a touchActivity(\"<edge>\") call site, and no others do", () => {
  const sites = new Set<string>();
  const re = /touchActivity\("([a-z_]+)"\)/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(childCode)) !== null) sites.add(m[1]);
  // The lifecycle reset is written as the named constant, not a bare literal.
  if (childCode.includes("touchActivity(CLOCK_RESET_EVENT)")) sites.add(CLOCK_RESET_EVENT);

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
    childCode.includes('from "./shared/heartbeat-progress-edges.js"'),
    "task-heartbeat.ts must import the shared declaration",
  );
  ok(
    childCode.includes("export { ACTIVITY_EDGE_EVENTS, LIFECYCLE_EVENTS }"),
    "task-heartbeat.ts must re-export the shared edge declaration it consumes",
  );
  // A restated literal edge set would defeat the structural coupling.
  ok(
    !/const ACTIVITY_EDGE_EVENTS\s*=\s*\[/.test(childCode),
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
  while ((m = re.exec(childCode)) !== null) emitted.add(m[1]);
  equal(
    [...emitted].sort().join(","),
    [...MARKER_KINDS].sort().join(","),
    `child wire kinds ${JSON.stringify([...emitted].sort())} must equal MARKER_KINDS ${JSON.stringify([...MARKER_KINDS].sort())}`,
  );
  ok(emitted.size >= 7, "non-vacuity: the child must expose the full marker vocabulary");
});

test("feedsToolUpdates is derived from the child's real updatedToolIds call sites", () => {
  // The one declared row effect that was previously unasserted: it could drift
  // from `task-heartbeat.ts`'s `updatedToolIds` handling with the suite green.
  const bodies = childHandlerBodies(childCode);
  const feeders = [...bodies.entries()]
    .filter(([, body]) => body.includes("updatedToolIds.add("))
    .map(([event]) => event)
    .sort();
  const declared = PROGRESS_EDGE_TABLE.filter((r) => r.feedsToolUpdates)
    .map((r) => r.event as string)
    .sort();
  equal(
    feeders.join(","),
    declared.join(","),
    `child handlers that feed tool updates ${JSON.stringify(feeders)} must equal the rows declaring feedsToolUpdates ${JSON.stringify(declared)}`,
  );
  ok(declared.length >= 1, "non-vacuity: at least one row must feed the tick's tool_updates");
});

test("ACTIVITY_EDGE_EVENTS is exactly the table's non-lifecycle advancing rows", () => {
  const declared = clockRows
    .filter((r) => r.event !== CLOCK_RESET_EVENT)
    .map((r) => r.event as string)
    .sort();
  equal([...ACTIVITY_EDGE_EVENTS].sort().join(","), declared.join(","));
  equal([...LIFECYCLE_EVENTS].sort().join(","), ["session_shutdown", "session_start"].join(","));
  // `childRegisteredEvents` is the concatenation by construction, so comparing
  // its length to the sum of the two lengths is a tautology — it cannot fire.
  // Assert the property that line LOOKS like it guards: no event is registered
  // twice (which would silently double-count a handler).
  const all = childRegisteredEvents();
  equal(new Set(all).size, all.length, `childRegisteredEvents() contains a duplicate: ${all.join(",")}`);
});

test("isActivityEdge classifies the declared edge set and nothing else", () => {
  for (const e of ACTIVITY_EDGE_EVENTS) ok(isActivityEdge(e), `${e} is a declared activity edge but isActivityEdge says no`);
  for (const e of LIFECYCLE_EVENTS) {
    ok(!isActivityEdge(e), `${e} is a lifecycle event and must NOT classify as an activity edge`);
  }
  ok(!isActivityEdge("not_an_event"), "an undeclared event must not classify as an activity edge");
  equal([...PROGRESS_EDGE_TABLE].filter((r) => !r.synthetic && isActivityEdge(r.event as string)).length, ACTIVITY_EDGE_EVENTS.length);
});

section("table ↔ parent source (the parsed-marker effects)");

test("every registered child pi event has a handler in the child emitter", () => {
  // The parent's :2417 handler list is REPLACED by this derived equality: the
  // child registers exactly the activity edges plus the two lifecycle events.
  const handlers = new Set<string>();
  const re = /pi\.on\("([a-z_]+)"/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(childCode)) !== null) handlers.add(m[1]);
  equal(
    [...handlers].sort().join(","),
    [...childRegisteredEvents()].sort().join(","),
    `registered handlers ${JSON.stringify([...handlers].sort())} must equal ACTIVITY_EDGE_EVENTS ∪ LIFECYCLE_EVENTS`,
  );
});

test("the parent derives KNOWN_MARKER_KINDS from the shared MARKER_KINDS", () => {
  ok(
    /export const KNOWN_MARKER_KINDS = new Set<string>\(MARKER_KINDS\);/.test(parentCode),
    "KNOWN_MARKER_KINDS must be derived from MARKER_KINDS, not restated as a literal list",
  );
  ok(
    parentCode.includes('from "../shared/heartbeat-progress-edges.js"'),
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
    equal(
      arm!.includes("everSawWork = true"),
      row.setsEverSawWork,
      `${row.id}: setsEverSawWork (everSawWork is latched only by tool_start/turn_start)`,
    );
    equal(arm!.includes("streamAgeMs = 0"), row.resetsStreamAge, `${row.id}: resetsStreamAge`);
    equal(arm!.includes("toolAgeMaxMs = 0"), row.resetsToolAge, `${row.id}: resetsToolAge`);
    equal(arm!.includes("toolUpdates = v === 1"), row.drivesToolUpdates, `${row.id}: drivesToolUpdates`);
    equal(arm!.includes("toolUpdates = false"), row.resetsToolUpdates, `${row.id}: resetsToolUpdates`);
  }
});

test("the #279 guard is a real ABSENCE assertion, not just a table flag", () => {
  // The guard is "a turn that started is not real activity": the turn_start arm
  // must NOT latch everSawRealActivity. Asserted as an absence so a future arm
  // edit that adds the latch fails here, not only in the row comparison above.
  const turnStart = arms.get("turn_start");
  ok(turnStart !== undefined, "no turn_start arm");
  ok(!turnStart!.includes("everSawRealActivity = true"), "turn_start must NOT latch everSawRealActivity (#279)");
  ok(turnStart!.includes("everSawWork = true"), "turn_start latches everSawWork");
  const ready = arms.get("ready");
  ok(ready !== undefined, "no ready arm");
  ok(!ready!.includes("everSawRealActivity = true"), "ready must NOT latch everSawRealActivity (#279)");
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
  equal(writing("everSawWork = true"), declared((r) => r.setsEverSawWork), "everSawWork writers (setsEverSawWork)");
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
      equal(row.setsEverSawWork, false, `${row.id}: the parent never sees this edge`);
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
  ok(
    /export type HeartbeatKillReason = HeartbeatKillReasonName;/.test(parentCode),
    "the parent's union type must be derived from the declared set",
  );
  ok(
    KILL_REASON_BOUNDS["tool-stall"].includes("TASK_TOOL_STALL_MS"),
    "the tool-stall clause must record its EFFECTIVE bound (the env override), not only the fraction fallback",
  );
});

test("every kill(\"<clause>\") literal in the parent is a declared clause, and vice versa", () => {
  // The TYPE alias cannot do this job: the repo has no root tsconfig, so no
  // typecheck runs in CI, and a mention check (`source.includes(...)`) is
  // satisfied by the import line alone. Injecting `kill("brand-new-clause")`
  // must fail here.
  const called = new Set<string>();
  // `[a-z-]+` also excludes `proc.kill("SIGTERM")` (uppercase signal names).
  const re = /kill\("([a-z-]+)"\)/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(parentCode)) !== null) called.add(m[1]);
  equal(
    [...called].sort().join(","),
    [...HEARTBEAT_KILL_REASONS].sort().join(","),
    `kill() clauses ${JSON.stringify([...called].sort())} must equal HEARTBEAT_KILL_REASONS ${JSON.stringify([...HEARTBEAT_KILL_REASONS].sort())}`,
  );
  ok(called.size >= 8, `only ${called.size} kill() clauses found — the scan is vacuous`);
});

test("every bound a kill clause NAMES is registered (clause → registry closure)", () => {
  // The kill-clause map records a bound per clause, but a clause string is
  // PROSE — nothing stopped it from naming a bound that is not in the registry
  // (or from a clause naming none at all). Two real instances were invisible to
  // the reverse scan because their NAMES carry no family token:
  // FIRST_OUTPUT_TIMEOUT_MS and DEFAULT_HARD_CAP_MS. This closes that hole for
  // every DECLARED clause: the named bound must resolve to a registry entry.
  //
  // Extraction is deliberately conservative: an ALL-CAPS token containing an
  // underscore (so a tier label like `S` or the word `OFF` cannot match) or a
  // `getXxx` accessor. Env var NAMES are allowed without registration via an
  // explicit allowlist — NOT a `TASK_` prefix rule, which would have silently
  // skipped `TASK_TOOL_STALL_FRACTION`, a real registered CONSTANT that happens
  // to be named like an env var.
  const ENV_ONLY = new Set([
    "TASK_STREAM_STALL_MS",
    "TASK_TOOL_STALL_MS",
    "TASK_FIRST_MESSAGE_MS",
    "TASK_MAX_DISPATCH_MS",
    "TASK_HEARTBEAT_TIMEOUT_MS",
    "TASK_HEARTBEAT_CUT_GAP_MS",
    "TASK_HARD_CAP_MS",
    "TASK_HEARTBEAT_INTERVAL_MS",
  ]);
  const tokenRe = /\b[A-Z][A-Z0-9]*_[A-Z0-9_]+\b|\bget[A-Z][A-Za-z0-9]*\b/g;
  const missing: string[] = [];
  for (const clause of HEARTBEAT_KILL_REASONS) {
    const bound = KILL_REASON_BOUNDS[clause] ?? "";
    const named = [...bound.matchAll(tokenRe)].map((m) => m[0]).filter((t) => !ENV_ONLY.has(t));
    ok(
      named.length > 0,
      `${clause}: the clause names no bound that the registry can resolve — ${JSON.stringify(bound)}`,
    );
    for (const t of named) {
      if (!STALL_TERM_REGISTRY.some((x) => x.name === t)) missing.push(`${clause} → ${t}`);
    }
  }
  equal(
    missing.length,
    0,
    `these clauses name a bound that is NOT in STALL_TERM_REGISTRY (register it, or the declared clause vocabulary is not actually covered): ${missing.join(", ")}`,
  );
});

test("a term whose guardedBy cites a test file is actually referenced by that test", () => {
  // `guardedBy` is metadata that a reader TRUSTS: it says which other pin holds
  // this bound. It is prose, so it can lie (FIRST_OUTPUT_TIMEOUT_MS cited
  // builtin-tools.test.ts, which never mentions it). When the string names a
  // test file, that file must at least reference the term.
  const offenders: string[] = [];
  const cache = new Map<string, string>();
  for (const t of STALL_TERM_REGISTRY) {
    const m = /([A-Za-z0-9_./-]+\.(?:test|spec)\.[a-z]+|[A-Za-z0-9_./-]*tests?\/[A-Za-z0-9_./-]+)/.exec(t.guardedBy);
    if (!m) continue; // NONE, or a free-form attribution with no file to check
    const file = m[1];
    let src = cache.get(file);
    if (src === undefined) {
      try {
        src = yieldCommentLines(read(file), langOf(file));
      } catch {
        src = "";
      }
      cache.set(file, src);
    }
    if (src === "") {
      offenders.push(`${t.name}: cites ${file} as its pin, but that file does not exist`);
      continue;
    }
    const esc = t.name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    if (!new RegExp(`\\b${esc}\\b`).test(src)) {
      offenders.push(`${t.name}: cites ${file} as its pin, but that test never mentions ${t.name}`);
    }
  }
  equal(offenders.length, 0, `guardedBy misattribution:\n  - ${offenders.join("\n  - ")}`);
});

test("every declaration a term models is checked, not just one (the shadowing hole)", () => {
  // Reproduces the #1120 review finding: the forward check used `some()` over the
  // declaration lines, so a SECOND, shadowing declaration of a registered bound
  // left the gate green. It now requires the exact line count AND each override
  // fragment.
  const term = STALL_TERM_REGISTRY.find((t) => t.name === "REAP_IDLE_HOURS");
  ok(term !== undefined, "REAP_IDLE_HOURS must be registered (it is a multi-declaration term)");
  ok((term!.overrides ?? []).length >= 1, "REAP_IDLE_HOURS must record its extra declarations");
  const owner = term!.owners[0];
  const realSrc = read(owner);
  equal(
    forwardViolations([term!], () => realSrc).length,
    0,
    "the real owner file must satisfy the exact declaration-count + override rules",
  );
  // An UNRECORDED extra declaration is a violation...
  const shadowed = `${realSrc}\nREAP_IDLE_HOURS=48\n`;
  const v1 = forwardViolations([term!], () => shadowed);
  ok(v1.length > 0 && v1[0].includes("declares it"), `an extra declaration must be a violation, got ${JSON.stringify(v1)}`);
  // ...and so is a changed registered fragment on an override line.
  const drifted = realSrc.replace('REAP_IDLE_HOURS="$2"', 'REAP_IDLE_HOURS="$9"');
  const v2 = forwardViolations([term!], () => drifted);
  ok(v2.length > 0 && v2[0].includes("override fragment"), `a changed override must be a violation, got ${JSON.stringify(v2)}`);
  // And the default itself is still checked.
  const changedDefault = realSrc.replace("${REAP_IDLE_HOURS:-24}", "${REAP_IDLE_HOURS:-48}");
  const v3 = forwardViolations([term!], () => changedDefault);
  ok(v3.length > 0 && v3[0].includes("registered value"), `a changed default must be a violation, got ${JSON.stringify(v3)}`);
});

test("every registered axis is a declared axis", () => {
  const declared = new Set<string>(STALL_AXES);
  for (const t of STALL_TERM_REGISTRY) {
    ok(declared.has(t.axis), `${t.name}: axis ${JSON.stringify(t.axis)} is not in STALL_AXES ${JSON.stringify([...STALL_AXES])}`);
  }
  ok(STALL_AXES.length >= 7, `expected the declared axis set, found ${STALL_AXES.length}`);
  // Every axis must actually be used, or it is decoration.
  const used = new Set(STALL_TERM_REGISTRY.map((t) => t.axis));
  for (const a of STALL_AXES) ok(used.has(a), `declared axis ${a} has no registered term`);
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
    scan.declarations.filter((d) => d.symbol !== "").length >= FLOORS.minDeclarations,
    `found ${scan.declarations.filter((d) => d.symbol !== "").length} real declarations against a floor of ${FLOORS.minDeclarations}`,
  );
  ok(
    (spec.walkErrors ?? []).length === 0,
    `the corpus walk reported ${(spec.walkErrors ?? []).length} unreadable directories — a dropped subtree hides new bounds`,
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

test("a registered term re-declared in an unregistered file fails the reverse scan", () => {
  const synthetic = scanDeclarations({ ...spec, files: ["extensions/brand-new.ts"] }, (f) =>
    f.endsWith("brand-new.ts") ? "export const DEFAULT_STREAM_STALL_MS = 5;\n" : "",
  );
  const v = reverseViolations(synthetic, STALL_TERM_REGISTRY, STALL_SCAN_EXEMPTIONS);
  ok(v.length > 0, "a second declaration of a registered bound in an unowned file must be a violation");
  ok(v[0].includes("does not list as an owner"), v[0]);
});

test("a value:null term satisfied only by a COMMENT fails the forward scan (no comment-fabricated declaration)", () => {
  const commentOnly = "// STALL_THRESHOLD is owned by #847\n// getSubagentBackstopFreshMs lives elsewhere\n";
  const v = forwardViolations(
    STALL_TERM_REGISTRY.filter((t) => t.value === null && t.owners.length === 1),
    () => commentOnly,
  );
  ok(v.length > 0, "a pointer/derived term must not be satisfied by a comment that merely names it");
});

test("no NON-comment line is ever rewritten (the corpus-wide no-deletion invariant)", () => {
  // The whole safety argument for the line-local transform is that a line may
  // only change when it IS a comment line. That is exactly what this asserts,
  // per line, over the whole corpus — the DELETION direction (a real declaration
  // silently removed, which is how the previous lexer hid two live `FRESH`
  // bounds) is impossible if no non-comment line is touched.
  //
  // The one DISCLOSED residual — a block-comment body line that is flushed left
  // instead of `*`-prefixed reads as code — cannot be detected without cross-line
  // state, so it is pinned as a known shape in declared-surface.test.ts rather
  // than claimed here.
  const offenders: string[] = [];
  let checked = 0;
  let blanked = 0;
  for (const file of spec.files) {
    const lang = langOf(file);
    checked++;
    const lines = read(file).split("\n");
    for (let i = 0; i < lines.length; i++) {
      const out = yieldCommentLines(lines[i], lang);
      if (out === lines[i]) continue;
      blanked++;
      if (!isCommentLine(lines[i], lang)) {
        offenders.push(`${file}:${i + 1}: ${JSON.stringify(lines[i])} -> ${JSON.stringify(out)}`);
      }
    }
  }
  ok(checked >= 100, `only ${checked} corpus files were checked — the invariant is vacuous`);
  ok(blanked >= 100, `only ${blanked} comment lines were seen — the transform is not being exercised`);
  equal(
    offenders.length,
    0,
    `these NON-comment lines were rewritten, i.e. real code (or a declaration) can be deleted by the comment transform: ${offenders.slice(0, 5).join(" | ")}`,
  );
});

test("every registered term is in-family, or explicitly recorded as out-of-family", () => {
  // The reverse scan and the owners check both iterate declarations that
  // `inFamily` matched, so a registered term whose NAME is not in-family escapes
  // both. `OUT_OF_FAMILY_TERMS` must therefore be complete: a new camelCase
  // accessor or a new `*_TIMEOUT_MS`-style constant fails here instead of
  // silently having no scan coverage at all.
  const exempt = new Set<string>(OUT_OF_FAMILY_TERMS);
  for (const t of STALL_TERM_REGISTRY) {
    const inFam = inFamily(t.name, SCAN_NAME_FAMILIES, SCAN_AGE_SUFFIXES, SCAN_BOUND_SUFFIXES);
    ok(
      inFam || exempt.has(t.name),
      `${t.name} is neither in-family (so the scan covers it) nor listed in OUT_OF_FAMILY_TERMS — add it to that list deliberately, with its own value+behaviour pin`,
    );
  }
  for (const name of OUT_OF_FAMILY_TERMS) {
    ok(STALL_TERM_REGISTRY.some((t) => t.name === name), `${name} is listed as out-of-family but is not registered`);
  }
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
