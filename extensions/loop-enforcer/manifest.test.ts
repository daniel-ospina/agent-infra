/**
 * manifest.test.ts — self-check for manifest.ts abortLoop/abortAllLoops/buildEndSummary.
 * 
 * Uses the REAL writeManifest/readManifest from manifest.ts (no replica drift).
 * Run: npx tsx extensions/loop-enforcer/manifest.test.ts
 */

import { readManifest, writeManifest, abortLoop, abortAllLoops, buildEndSummary, pauseLoop, blockLoop, resumeLoop, Manifest } from "./manifest.js";
import { existsSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { randomUUID } from "node:crypto";

const TEST_DIR = join("/tmp", `loop-enforcer-test-${randomUUID()}`);

function makeManifest(slug: string, overrides: Partial<Manifest> = {}): Manifest {
  const base: Manifest = {
    loop_id: slug,
    goal: "test goal",
    objective: "test objective",
    target_ambition: "1x",
    task_type: "code",
    loop_type: "completion",
    verification_level: "standard",
    status: "running",
    indicators: [],
    cycles: [{ number: 1, verdict: "CLEAN", issues_found: 0, exit_signal: "clean", timestamp: new Date().toISOString() }],
    exit_reason: null,
    human_gate_flags: [],
    write_back: [],
    scope: { in_scope: [], out_of_scope: [] },
    resume_from_cycle: null,
    parent_loop_id: null,
    created_at: new Date().toISOString(),
    heartbeat_file: join(TEST_DIR, `${slug}.heartbeat`),
  };
  return { ...base, ...overrides };
}

function createHeartbeat(slug: string): void {
  const hbPath = join(TEST_DIR, `${slug}.heartbeat`);
  writeFileSync(hbPath, JSON.stringify({ slug, ts: new Date().toISOString() }));
}

let failed = 0;
function assert(cond: boolean, msg: string): void {
  if (!cond) { console.error(`❌ FAIL: ${msg}`); failed++; }
  else { console.log(`  ✅ ${msg}`); }
}

// ── Setup ─────────────────────────────────────────────────────
mkdirSync(TEST_DIR, { recursive: true });

try {

// ── Tests ─────────────────────────────────────────────────────
console.log("manifest.test.ts — self-check\n");

// 1. abortLoop: running → aborted
const slug1 = "test-running";
writeManifest(slug1, makeManifest(slug1, { status: "running" }), TEST_DIR);
createHeartbeat(slug1);
const r1 = abortLoop(slug1, TEST_DIR, "test_abort");
assert(r1 !== null, "running → aborted returns result");
assert(r1!.slug === slug1, "  slug matches");
assert(r1!.cycles === 1, "  cycles count = 1");
const m1 = readManifest(slug1, TEST_DIR);
assert(m1!.status === "aborted", "  status = aborted");
assert(m1!.exit_reason === "test_abort", "  exit_reason set");
assert(m1!.resume_from_cycle === null, "  resume_from_cycle nulled");
assert(m1!.heartbeat_file === null, "  heartbeat_file nulled");
assert(!existsSync(join(TEST_DIR, `${slug1}.heartbeat`)), "  .heartbeat removed");

// 2. abortLoop: pending_verification → aborted
const slug2 = "test-pending";
writeManifest(slug2, makeManifest(slug2, { status: "pending_verification" }), TEST_DIR);
const r2 = abortLoop(slug2, TEST_DIR, "test_pending_abort");
assert(r2 !== null, "pending_verification → aborted");
const m2 = readManifest(slug2, TEST_DIR);
assert(m2!.status === "aborted", "  status = aborted");

// 3. abortLoop: complete → idempotent skip
const slug3 = "test-complete";
writeManifest(slug3, makeManifest(slug3, { status: "complete" }), TEST_DIR);
const r3 = abortLoop(slug3, TEST_DIR, "should_not_apply");
assert(r3 === null, "complete → returns null (idempotent skip)");
const m3 = readManifest(slug3, TEST_DIR);
assert(m3!.status === "complete", "  status still complete");
assert(m3!.exit_reason === null, "  exit_reason unchanged");

// 4. abortLoop: aborted → idempotent skip
const slug4 = "test-aborted";
writeManifest(slug4, makeManifest(slug4, { status: "aborted", exit_reason: "prior" }), TEST_DIR);
const r4 = abortLoop(slug4, TEST_DIR, "should_not_apply");
assert(r4 === null, "aborted → returns null");
const m4 = readManifest(slug4, TEST_DIR);
assert(m4!.exit_reason === "prior", "  exit_reason unchanged");

// 5. abortLoop: heartbeat not present → no throw
const slug5 = "test-no-heartbeat";
writeManifest(slug5, makeManifest(slug5, { status: "running", heartbeat_file: null }), TEST_DIR);
const r5 = abortLoop(slug5, TEST_DIR, "test_no_hb");
assert(r5 !== null, "no heartbeat → still aborts (no throw)");

// 6. abortLoop: corrupt JSON manifest → no throw, returns null
const slug6 = "test-corrupt";
const corruptPath = join(TEST_DIR, `${slug6}.yaml`);
writeFileSync(corruptPath, "not valid json {{{");
createHeartbeat(slug6);
const r6 = abortLoop(slug6, TEST_DIR, "test_corrupt");
assert(r6 === null, "corrupt JSON → returns null (no throw)");
assert(!existsSync(join(TEST_DIR, `${slug6}.heartbeat`)), "  heartbeat still cleaned");

// 7. abortLoop: missing manifest → returns null
const r7 = abortLoop("nonexistent", TEST_DIR, "test_missing");
assert(r7 === null, "missing manifest → returns null");

// 8. abortAllLoops: counts correctly
const slug8a = "test-all-a";
const slug8b = "test-all-b";
writeManifest(slug8a, makeManifest(slug8a, { status: "running" }), TEST_DIR);
writeManifest(slug8b, makeManifest(slug8b, { status: "running" }), TEST_DIR);
// also put a .heartbeat file to ensure it's filtered out
writeFileSync(join(TEST_DIR, "orphan.heartbeat"), "{}");
const all = abortAllLoops(TEST_DIR, "test_all");
assert(all.length === 2, "abortAllLoops: 2 loops aborted");
assert(all.find(a => a.slug === slug8a) !== undefined, `  includes ${slug8a}`);
assert(all.find(a => a.slug === slug8b) !== undefined, `  includes ${slug8b}`);
// verify .heartbeat files excluded from scan
const ma = readManifest(slug8a, TEST_DIR);
assert(ma!.status === "aborted", "  manifest actually aborted");

// 9. abortAllLoops: empty dir (no yaml files) → returns []
const emptyDir = join(TEST_DIR, "empty-subdir");
mkdirSync(emptyDir, { recursive: true });
const allEmpty = abortAllLoops(emptyDir, "test_empty");
assert(allEmpty.length === 0, "abortAllLoops empty dir → []");

// 10. abortAllLoops: non-existent dir → returns []
const allNone = abortAllLoops(join(TEST_DIR, "nonexistent-subdir"), "test_none");
assert(allNone.length === 0, "abortAllLoops non-existent dir → []");

// 11. buildEndSummary: formatting
assert(buildEndSummary([]) === "✅ Session ending. No active loops.", "buildEndSummary 0 loops");
assert(buildEndSummary([{ slug: "a", cycles: 3 }]) === "✅ Session ending. 1 loop stopped: a.", "buildEndSummary 1 loop");
assert(
  buildEndSummary([{ slug: "a", cycles: 1 }, { slug: "b", cycles: 2 }]) === "✅ Session ending. 2 loops stopped: a, b.",
  "buildEndSummary 2 loops"
);

// 12. pauseLoop: running → paused
const slug12 = "test-pause";
writeManifest(slug12, makeManifest(slug12, { status: "running" }), TEST_DIR);
const ok12 = pauseLoop(slug12, "test pause reason", TEST_DIR);
assert(ok12, "pauseLoop returns true");
const m12 = readManifest(slug12, TEST_DIR);
assert(m12!.status === "paused", "  status = paused");
assert(m12!.exit_reason === "paused: test pause reason", "  exit_reason set");

// 13. pauseLoop: complete → false (invalid transition)
const slug13 = "test-pause-complete";
writeManifest(slug13, makeManifest(slug13, { status: "complete" }), TEST_DIR);
const ok13 = pauseLoop(slug13, "should fail", TEST_DIR);
assert(!ok13, "pauseLoop complete → returns false");
const m13 = readManifest(slug13, TEST_DIR);
assert(m13!.status === "complete", "  status unchanged");

// 14. blockLoop: running → blocked
const slug14 = "test-block";
writeManifest(slug14, makeManifest(slug14, { status: "running" }), TEST_DIR);
const ok14 = blockLoop(slug14, "dep failed", "issue-#9999", TEST_DIR);
assert(ok14, "blockLoop returns true");
const m14 = readManifest(slug14, TEST_DIR);
assert(m14!.status === "blocked", "  status = blocked");
assert(m14!.exit_reason === "blocked on issue-#9999: dep failed", "  exit_reason set");

// 15. blockLoop: paused → blocked
const slug15 = "test-block-paused";
writeManifest(slug15, makeManifest(slug15, { status: "paused" }), TEST_DIR);
const ok15 = blockLoop(slug15, "dependency", "dep", TEST_DIR);
assert(ok15, "blockLoop paused → returns true");
const m15 = readManifest(slug15, TEST_DIR);
assert(m15!.status === "blocked", "  status = blocked");

// 16. resumeLoop: paused → running
const slug16 = "test-resume-paused";
writeManifest(slug16, makeManifest(slug16, { status: "paused", exit_reason: "paused: test" }), TEST_DIR);
const ok16 = resumeLoop(slug16, TEST_DIR);
assert(ok16, "resumeLoop returns true");
const m16 = readManifest(slug16, TEST_DIR);
assert(m16!.status === "running", "  status = running");
assert(m16!.exit_reason === null, "  exit_reason cleared");
assert(existsSync(join(TEST_DIR, `${slug16}.heartbeat`)), "  heartbeat restored");

// 17. resumeLoop: blocked → running
const slug17 = "test-resume-blocked";
writeManifest(slug17, makeManifest(slug17, { status: "blocked", exit_reason: "blocked on X: y" }), TEST_DIR);
const ok17 = resumeLoop(slug17, TEST_DIR);
assert(ok17, "resumeLoop blocked → returns true");
const m17 = readManifest(slug17, TEST_DIR);
assert(m17!.status === "running", "  status = running");

// 18. resumeLoop: complete → false
const slug18 = "test-resume-complete";
writeManifest(slug18, makeManifest(slug18, { status: "complete" }), TEST_DIR);
const ok18 = resumeLoop(slug18, TEST_DIR);
assert(!ok18, "resumeLoop complete → returns false");
const m18 = readManifest(slug18, TEST_DIR);
assert(m18!.status === "complete", "  status unchanged");

// 19. abortLoop: paused → aborted
const slug19 = "test-abort-paused";
writeManifest(slug19, makeManifest(slug19, { status: "paused" }), TEST_DIR);
const r19 = abortLoop(slug19, TEST_DIR, "test_abort_paused");
assert(r19 !== null, "abortLoop paused → returns result");
const m19 = readManifest(slug19, TEST_DIR);
assert(m19!.status === "aborted", "  status = aborted");

// 20. abortLoop: blocked → aborted
const slug20 = "test-abort-blocked";
writeManifest(slug20, makeManifest(slug20, { status: "blocked" }), TEST_DIR);
const r20 = abortLoop(slug20, TEST_DIR, "test_abort_blocked");
assert(r20 !== null, "abortLoop blocked → returns result");
const m20 = readManifest(slug20, TEST_DIR);
assert(m20!.status === "aborted", "  status = aborted");

// ── Teardown ──────────────────────────────────────────────────
} finally {
  rmSync(TEST_DIR, { recursive: true, force: true });
}

console.log(`\n${failed === 0 ? "✅ All tests passed" : `❌ ${failed} test(s) failed`}`);
process.exit(failed === 0 ? 0 : 1);
