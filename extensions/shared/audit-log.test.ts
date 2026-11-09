/**
 * shared/audit-log.test.ts — unit tests for the durable gate-event audit log (#60)
 * Run: npx tsx extensions/shared/audit-log.test.ts
 */

import { appendJsonl, gateEventsFile, GATE_EVENT_NAMES } from "./audit-log.js";
import { ok, equal } from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import { dirname, join, resolve as resolvePath } from "node:path";

let passed = 0;
let failed = 0;

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

function readLines(file: string): Record<string, any>[] {
  return fs
    .readFileSync(file, "utf8")
    .trim()
    .split("\n")
    .filter(Boolean)
    .map((l) => JSON.parse(l));
}

// ── gateEventsFile ────────────────────────────────────

section("gateEventsFile — default log location");

test("resolves to ~/.pi/agent/audit/gate-events.jsonl via os.homedir()", () => {
  equal(gateEventsFile(), join(os.homedir(), ".pi", "agent", "audit", "gate-events.jsonl"));
  // The path must be DERIVED from os.homedir() (never a hardcoded user dir).
  ok(gateEventsFile().startsWith(os.homedir()), "derived from os.homedir()");
});

// ── appendJsonl ───────────────────────────────────────

section("appendJsonl — fail-safe durable append");

test("creates the audit dir on demand and appends one JSONL line", () => {
  const file = resolvePath(fs.mkdtempSync(resolvePath(os.tmpdir(), "audit-log-")), "nested", "gate-events.jsonl");
  appendJsonl({ event: "gate_bypass", extension: "test" }, file);
  const [e] = readLines(file);
  ok(typeof e.ts === "string" && !isNaN(Date.parse(e.ts)), "ts is an ISO timestamp");
  equal(e.event, "gate_bypass");
  equal(e.extension, "test");
});

test("default target honors $HOME (lazy resolution — no module-load snapshot)", () => {
  const dir = fs.mkdtempSync(resolvePath(os.tmpdir(), "audit-home-"));
  const prevHome = process.env.HOME;
  process.env.HOME = dir;
  try {
    appendJsonl({ event: "review_dispatch", extension: "test" });
    const file = join(dir, ".pi", "agent", "audit", "gate-events.jsonl");
    ok(fs.existsSync(file), "wrote under temp $HOME");
    equal(readLines(file).length, 1);
  } finally {
    process.env.HOME = prevHome;
  }
});

test("never throws on write failure (fail-safe: audit cannot break the gate path)", () => {
  // Target is an existing DIRECTORY → appendFileSync throws EISDIR; must be swallowed.
  const dir = fs.mkdtempSync(resolvePath(os.tmpdir(), "audit-fail-"));
  appendJsonl({ event: "merge_gate_block", extension: "test", pr: 1 }, dir);
  ok(true, "no throw on unwritable target");
  // And a second append still does not throw (no wedged state).
  appendJsonl({ event: "merge_gate_pass", extension: "test", pr: 1 }, dir);
  ok(true, "no throw on subsequent append");
});

test("appends multiple entries sequentially (append-only)", () => {
  const file = resolvePath(fs.mkdtempSync(resolvePath(os.tmpdir(), "audit-log-")), "gate-events.jsonl");
  appendJsonl({ event: "gate_bypass", extension: "test" }, file);
  appendJsonl({ event: "review_dispatch", extension: "test", dispatch_count: 1 }, file);
  const lines = readLines(file);
  equal(lines.length, 2);
  equal(lines[0].event, "gate_bypass");
  equal(lines[1].dispatch_count, 1);
});

// ── GATE_EVENT_NAMES — the declared event vocabulary (#853 review) ────────
// ⛔ WHY THIS SECTION EXISTS. `GateEventName` was a bare type union, and a TYPE IS
// INVISIBLE AT RUNTIME: `appendJsonl` takes `Record<string, unknown>`, so a name this repo
// never declared (a typo, or a member someone deleted) writes fine and a report reading it
// finds nothing. The #853 review measured exactly that: deleting a union member reddened NO
// test. The type now derives from this array, so membership is assertable and the control is
// real instead of claimed.
test("GATE_EVENT_NAMES is non-empty and every member is a lowercase snake_case token", () => {
  ok(GATE_EVENT_NAMES.length > 0, "the vocabulary is empty — no event could be declared");
  const bad = GATE_EVENT_NAMES.filter((n) => !/^[a-z][a-z0-9]*(_[a-z0-9]+)*$/.test(n));
  equal(bad.length, 0, `non-conforming event name(s): ${bad.join(", ")}`);
});

test("GATE_EVENT_NAMES has no duplicates (a duplicate is a rename that half-landed)", () => {
  const seen = new Set<string>();
  const dupes: string[] = [];
  for (const n of GATE_EVENT_NAMES) {
    if (seen.has(n)) dupes.push(n);
    seen.add(n);
  }
  equal(dupes.length, 0, `duplicate event name(s): ${dupes.join(", ")}`);
});

// The degradation events are the ones an OPERATOR report has to be able to find. Naming them
// here is deliberate: an enforcement layer that is degraded silently is the defect both
// events exist for (#3297, #853), so their absence from the vocabulary must be a test failure
// rather than a code-reading exercise.
test("the two degraded-enforcement events are declared (guard_degraded #853, gh_shim_degraded #3297)", () => {
  for (const name of ["guard_degraded", "gh_shim_degraded"]) {
    ok(
      (GATE_EVENT_NAMES as readonly string[]).includes(name),
      `"${name}" is not a declared GateEventName — a report reading it would find nothing`
    );
  }
});

// ── Summary ───────────────────────────────────────────

console.log(`\n${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
