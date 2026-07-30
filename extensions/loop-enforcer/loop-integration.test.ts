/**
 * loop-integration.test.ts — behavioral integration tests for loop-enforcer
 *
 * Tests goal spec, manifest persistence, and session affinity
 * by exercising the actual module functions against temp directories.
 *
 * Run: npx tsx operations/pi-config/extensions/loop-enforcer/loop-integration.test.ts
 */

import { ok, equal } from "node:assert/strict";
import { existsSync, mkdirSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { randomUUID } from "node:crypto";

// Import functions under test
import { buildGoalSpec, populateGoalFields, decomposeGoal, GOALS_UNVERIFIED_FLAG } from "./goal.js";
import { writeManifest, readManifest } from "./manifest.js";
import { shouldResumeLoop, readSessionContext } from "./index.js";

let passed = 0;
let failed = 0;

function test(name: string, fn: () => void) {
  try { fn(); passed++; console.log(`  ✅ ${name}`); }
  catch (err: any) { failed++; console.log(`  ❌ ${name}: ${err.message}`); }
}

function section(name: string) { console.log(`\n${name}:`); }

// ── Temp dir ───────────────────────────────────────────

const TEST_DIR = join(tmpdir(), `loop-test-${randomUUID()}`);
mkdirSync(TEST_DIR, { recursive: true });
const LOOPS_DIR = join(TEST_DIR, "loops");
mkdirSync(LOOPS_DIR, { recursive: true });

// ── Goal spec ──────────────────────────────────────────

section("Goal spec");

test("buildGoalSpec parses CLI args string", () => {
  const spec = buildGoalSpec("--type completion --max-budget 5 Fix all the bugs");
  ok(typeof spec === "object", "should return an object");
  ok(spec.objective === "Fix all the bugs", `objective should be parsed, got: ${spec.objective}`);
  ok(spec.loop_type === "completion", `loop_type should be 'code', got: ${spec.loop_type}`);
  ok(spec.max_budget === 5, `max_budget should be 5, got: ${spec.max_budget}`);
});

test("populateGoalFields mutates manifest with spec fields", () => {
  const spec = buildGoalSpec("--type cron --max-budget 3 Review the PR");
  const manifest: Record<string, any> = { loop_id: "test-1" };
  populateGoalFields(manifest, spec);
  ok(manifest.objective === "Review the PR", `objective should be set, got: ${manifest.objective}`);
  ok(manifest.loop_type === "cron", `loop_type should be set, got: ${manifest.loop_type}`);
  ok(manifest.max_budget === 3, `max_budget should be set, got: ${manifest.max_budget}`);
  ok(manifest.task_type !== undefined, "task_type should be set");
});

test("decomposeGoal returns child specs", () => {
  const manifest = { loop_id: "parent-1", objective: "Fix bugs", verification_level: "V2" };
  const children = decomposeGoal(manifest, ["task-a", "task-b"]);
  ok(children.length === 2, `should return 2 children, got ${children.length}`);
  ok(children[0].parent_loop_id === "parent-1", "child should reference parent");
  ok(children[0].task === "task-a", `first child task should be 'task-a', got: ${children[0].task}`);
});

test("GOALS_UNVERIFIED_FLAG is non-empty string", () => {
  ok(typeof GOALS_UNVERIFIED_FLAG === "string" && GOALS_UNVERIFIED_FLAG.length > 0);
});

// ── Manifest persistence ───────────────────────────────

section("Manifest persistence");

test("writeManifest creates file, readManifest reads it back", () => {
  const slug = `test-${randomUUID().slice(0, 8)}`;
  const data = {
    loop_id: slug,
    status: "active" as const,
    exit_reason: "",
    task_type: "code" as const,
    tier: "standard" as const,
    cycles: [{ cycle: 1, issuesFound: 3, issuesFixed: 2, verdict: "NEEDS_FIX" as const }],
  };
  writeManifest(slug, data, LOOPS_DIR);
  const read = readManifest(slug, LOOPS_DIR);
  ok(read !== null, "readManifest should return data");
  ok(read!.loop_id === slug, `loop_id should match, got: ${read?.loop_id}`);
  ok(read!.status === "active", `status should be active, got: ${read?.status}`);
});

test("readManifest returns null for unknown slug", () => {
  const result = readManifest("nonexistent-xyz", LOOPS_DIR);
  equal(result, null, "unknown slug should return null");
});

// ── Session affinity ───────────────────────────────────

section("Session affinity");

test("shouldResumeLoop returns true for matching role", () => {
  const manifest = { subject: { role: "developer" } };
  const ctx = { team: null, role: "developer", sessionId: null };
  ok(shouldResumeLoop(manifest, ctx), "matching role should resume");
});

test("shouldResumeLoop returns false for mismatched role", () => {
  const manifest = { subject: { role: "designer", team: "design-team" } };
  const ctx = { team: null, role: "developer", sessionId: null };
  ok(!shouldResumeLoop(manifest, ctx), "mismatched role should not resume");
});

test("shouldResumeLoop returns true for same session_id", () => {
  const manifest = { session_id: "sess-123" };
  const ctx = { team: null, role: null, sessionId: "sess-123" };
  ok(shouldResumeLoop(manifest, ctx), "same session should resume");
});

test("shouldResumeLoop returns false for different session_id", () => {
  const manifest = { session_id: "sess-123" };
  const ctx = { team: null, role: null, sessionId: "sess-456" };
  ok(!shouldResumeLoop(manifest, ctx), "different session should not resume");
});

test("readSessionContext returns team and role (not null)", () => {
  const ctx = readSessionContext();
  ok(typeof ctx === "object" && ctx !== null, "should return an object");
  // Returns { team: string | null, role: string | null } — even if null, the keys exist
  ok("team" in ctx, "should have team key");
  ok("role" in ctx, "should have role key");
});

// ── Cleanup ────────────────────────────────────────────

rmSync(TEST_DIR, { recursive: true, force: true });

console.log(`\n=== Results: ${passed} passed, ${failed} failed ===`);
if (failed > 0) { console.log("❌ SOME TESTS FAILED"); process.exit(1); }
console.log("✅ ALL TESTS PASSED");
