/**
 * index.e2e.test.ts — plugin-lifecycle harness for verification-gate (#38)
 *
 * Drives the ACTUAL plugin factory against a fake pi ExtensionAPI and a real
 * temp git repo, reproducing the reported failure sequence:
 *   verify → commit → edit → re-verify (fresh hashes) → attempt commit
 *
 * The incident root cause (2026-08-06/07, tortoise #218/#241): verifier
 * sub-agents return ABSOLUTE paths in verified_files JSON while the gate's
 * block check uses repo-RELATIVE paths from `git diff --cached --name-only`.
 * Registry keys therefore never matched and every commit was blocked as
 * "unverified" despite fresh PASS responses.
 *
 * Run (isolates the bridge file under a temp HOME):
 *   npx tsx index.e2e.test.ts
 */

import { ok, equal } from "node:assert/strict";
import { execSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtempSync, writeFileSync, existsSync, readFileSync, mkdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

// ── Isolation: bridge lives under a temp HOME (never touch the real one) ──
const TEST_ROOT = mkdtempSync(join(tmpdir(), "vgate-e2e-"));
process.env.HOME = TEST_ROOT;

// ── Tiny git + sha helpers ───────────────────────────
function sha(text: string): string {
  return createHash("sha256").update(text).digest("hex");
}
function git(repo: string, args: string): string {
  return execSync(`git ${args}`, { cwd: repo, encoding: "utf-8" }).trim();
}

// ── Fake pi ExtensionAPI ──────────────────────────────
interface Handler { (event: any, ctx: any): any }
const handlers = new Map<string, Handler[]>();
const fakePi: any = {
  on(evt: string, h: Handler) {
    if (!handlers.has(evt)) handlers.set(evt, []);
    handlers.get(evt)!.push(h);
  },
};
async function fire(evt: string, event: any): Promise<any> {
  let result: any = undefined;
  for (const h of handlers.get(evt) ?? []) {
    const r = await h(event, {});
    if (r !== undefined) result = r;
  }
  return result;
}

// ── Test runner (sequential — ordering matters: scenarios build on each other) ──
let passed = 0;
let failed = 0;
const queue: { name: string; fn: () => void | Promise<void> }[] = [];
function test(name: string, fn: () => void | Promise<void>) {
  queue.push({ name, fn });
}
async function runAll() {
  for (const { name, fn } of queue) {
    try {
      await fn();
      passed++;
      console.log(`  ✅ ${name}`);
    } catch (err: any) {
      failed++;
      console.log(`  ❌ ${name}: ${err.message}`);
    }
  }
}

function section(name: string) {
  console.log(`\n${name}:`);
}

async function main() {
  // Load the plugin AFTER HOME is set (BRIDGE_DIR is computed at module load)
  const mod = await import("./index.js");
  const plugin = (mod as any).default as (pi: any) => void;
  plugin(fakePi);

  section("Issue #38 — re-verification must update the registry");

  test("setup: temp git repo with a committed baseline", () => {
    const repo = join(TEST_ROOT, "repo");
    mkdirSync(repo, { recursive: true });
    git(repo, "init -b main");
    git(repo, `config user.email e2e@test`);
    git(repo, `config user.name e2e`);
    writeFileSync(join(repo, "fileA.txt"), "v1\n");
    git(repo, "add fileA.txt");
    git(repo, "commit -m baseline");
    ok(existsSync(join(repo, "fileA.txt")));
  });

  test("scenario 1: unverified staged change is blocked", async () => {
    const repo = join(TEST_ROOT, "repo");
    writeFileSync(join(repo, "fileA.txt"), "v2\n"); // the edited file to commit
    git(repo, "add fileA.txt");
    await fire("session_start", {});
    const res = await fire("tool_call", {
      type: "tool_call",
      toolName: "bash",
      input: { command: "git commit -m 'c1'", cwd: repo },
    });
    ok(res && res.block === true, "commit must be blocked for unverified file");
    ok(res.reason.includes("fileA.txt"), "block reason names the unverified file");
  });

  test("scenario 2 (#38 root cause): ABSOLUTE-path PASS response unblocks the commit", async () => {
    const repo = join(TEST_ROOT, "repo");
    const content = "v2\n";
    const absPath = join(repo, "fileA.txt");
    const passJson = JSON.stringify({
      status: "PASS",
      failures: [],
      verified_files: [{ path: absPath, hash: sha(content) }], // ← absolute path, as verifiers actually return
    });
    await fire("tool_result", {
      toolName: "task",
      input: { prompt: `[VGATE] verify files: fileA.txt. Classification: UI. Project root: ${repo}` },
      content: [{ type: "text", text: "```json\n" + passJson + "\n```" }],
    });
    const res = await fire("tool_call", {
      type: "tool_call",
      toolName: "bash",
      input: { command: "git commit -m 'c1'", cwd: repo },
    });
    equal(res, undefined, "commit must be ALLOWED after absolute-path PASS");
    git(repo, "commit -m c1"); // make the state real (also exercises pendingRehash next op)
  });

  test("scenario 3 (issue repro): edit + fresh re-verify with CURRENT hashes unblocks the next commit", async () => {
    const repo = join(TEST_ROOT, "repo");
    writeFileSync(join(repo, "fileA.txt"), "v3\n"); // corrective edit → new hash H2
    git(repo, "add fileA.txt");
    const passJson = JSON.stringify({
      status: "PASS",
      failures: [],
      verified_files: [{ path: join(repo, "fileA.txt"), hash: sha("v3\n") }],
    });
    await fire("tool_result", {
      toolName: "task",
      input: { prompt: `[VGATE] verify files: fileA.txt. Classification: UI. Project root: ${repo}` },
      content: [{ type: "text", text: passJson }],
    });
    const res = await fire("tool_call", {
      type: "tool_call",
      toolName: "bash",
      input: { command: "git commit -m 'c2'", cwd: repo },
    });
    equal(res, undefined, "commit after re-verification must be ALLOWED");
    git(repo, "commit -m c2");
  });

  test("scenario 4: stale last-blocked list cannot drop a known-path re-verification", async () => {
    const repo = join(TEST_ROOT, "repo");
    // A new file triggers a block whose lastBlockedFiles = [fileB.txt] only
    writeFileSync(join(repo, "fileB.txt"), "b1\n");
    git(repo, "add fileB.txt");
    const blocked = await fire("tool_call", {
      type: "tool_call",
      toolName: "bash",
      input: { command: "git commit -m 'c3'", cwd: repo },
    });
    ok(blocked && blocked.block === true, "fileB commit must be blocked (unverified)");
    // Now edit fileA and re-verify it (KNOWN path) while the stale blocked list is [fileB.txt].
    // The known-path rule must update the registry regardless of the stale filter.
    writeFileSync(join(repo, "fileA.txt"), "v4\n");
    git(repo, "add fileA.txt");
    await fire("tool_result", {
      toolName: "task",
      input: { prompt: `[VGATE] verify files: fileA.txt. Classification: UI. Project root: ${repo}` },
      content: [{ type: "text", text: JSON.stringify({
        status: "PASS", failures: [],
        verified_files: [{ path: join(repo, "fileA.txt"), hash: sha("v4\n") }],
      }) }],
    });
    // Unstage fileB so the next commit's diff is fileA only — proves the registry
    // updated fileA to H4 while the stale lastBlockedFiles=[fileB.txt] was in effect.
    git(repo, "reset fileB.txt");
    const res = await fire("tool_call", {
      type: "tool_call",
      toolName: "bash",
      input: { command: "git commit -m 'c4'", cwd: repo },
    });
    equal(res, undefined, "known-path re-verification must survive a stale lastBlockedFiles list");
    git(repo, "commit -m c4");
  });

  section("#132 — stderr noise, FAIL accounting, reset guard, auto-bypass");

  // Isolation pattern (per scenario): git reset clears staged files from prior
  // blocked scenarios AND pendingRehash; session_start resets vgateFailures /
  // blockAttempts so each scenario is self-contained.

  test("scenario 5 (#132 repro): PASS verdict + gate_bypass noise unblocks the commit", async () => {
    const repo = join(TEST_ROOT, "repo");
    git(repo, "reset -q");
    await fire("session_start", {});
    writeFileSync(join(repo, "fileA.txt"), "v5\n");
    git(repo, "add fileA.txt");
    const blocked = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "git commit -m 'c5'", cwd: repo },
    });
    ok(blocked && blocked.block === true, "must be blocked first");
    const verdict = JSON.stringify({ status: "PASS", failures: [], verified_files: [{ path: join(repo, "fileA.txt"), hash: sha("v5\n") }] });
    const noise = '\n⚠️  REVIEW GATES DISABLED — all quality checks bypassed...\n' +
      '{"event":"gate_bypass","reason":"escape_hatch","timestamp":"2026-08-09T22:48:04.139Z"}';
    await fire("tool_result", {
      toolName: "task",
      input: { prompt: `[VGATE] verify files: fileA.txt. Classification: UI. Project root: ${repo}` },
      content: [{ type: "text", text: verdict + noise }],
    });
    const res = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "git commit -m 'c5'", cwd: repo },
    });
    equal(res, undefined, "commit must be ALLOWED after PASS+noise (O/I/T indicator 1)");
    git(repo, "commit -m c5");
  });

  test("scenario 6 (#132): 3× noise-only dispatches never disable the gate", async () => {
    const repo = join(TEST_ROOT, "repo");
    git(repo, "reset -q");
    await fire("session_start", {});
    writeFileSync(join(repo, "fileB.txt"), "b1\n");
    git(repo, "add fileB.txt");
    const prompt = `[VGATE] verify files: fileB.txt. Classification: UI. Project root: ${repo}`;
    const noise = '{"event":"gate_bypass","reason":"escape_hatch"}';
    // Block first (sets lastBlockedFiles/lastBlockedCwd), then 3 noise dispatches.
    const blocked = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "git commit -m 'c6'", cwd: repo },
    });
    ok(blocked && blocked.block === true, "must be blocked first");
    for (let i = 0; i < 3; i++) {
      await fire("tool_result", { toolName: "task", input: { prompt }, content: [{ type: "text", text: noise }] });
    }
    // Noise-only fails open (#5724): the prompt files merge, the commit is
    // ALLOWED, and the gate is NOT disabled (a disabled gate would also allow
    // a NEW unverified file — prove it stays active with fileB2).
    const res = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "git commit -m 'c6'", cwd: repo },
    });
    equal(res, undefined, "noise-only dispatch fails open: commit allowed, gate not disabled");
    git(repo, "commit -m c6");
    writeFileSync(join(repo, "fileB2.txt"), "b2\n");
    git(repo, "add fileB2.txt");
    const res2 = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "git commit -m 'c6b'", cwd: repo },
    });
    ok(res2 && res2.block === true, "gate must still be ACTIVE after 3 noise dispatches (new file still blocked)");
    await fire("session_start", {});
  });

  test("scenario 7 (#132): 3× FAIL verdicts never disable the gate", async () => {
    const repo = join(TEST_ROOT, "repo");
    git(repo, "reset -q");
    await fire("session_start", {});
    writeFileSync(join(repo, "fileC.txt"), "c1\n");
    git(repo, "add fileC.txt");
    const prompt = `[VGATE] verify files: fileC.txt. Classification: UI. Project root: ${repo}`;
    for (let i = 0; i < 3; i++) {
      await fire("tool_result", {
        toolName: "task", input: { prompt },
        content: [{ type: "text", text: JSON.stringify({ status: "FAIL", failures: ["lint"], verified_files: [] }) }],
      });
    }
    const res = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "git commit -m 'c7'", cwd: repo },
    });
    ok(res && res.block === true, "gate must still be active after 3 FAIL verdicts");
    await fire("session_start", {});
  });

  test("scenario 8 (#132): zero-merge PASS does not mask dispatch failures", async () => {
    const repo = join(TEST_ROOT, "repo");
    git(repo, "reset -q");
    await fire("session_start", {});
    writeFileSync(join(repo, "fileD.txt"), "d1\n");
    git(repo, "add fileD.txt");
    const prompt = `[VGATE] verify files: fileD.txt. Classification: UI. Project root: ${repo}`;
    await fire("tool_result", { toolName: "task", input: { prompt }, content: [] });
    await fire("tool_result", { toolName: "task", input: { prompt }, content: [] });
    await fire("tool_result", {
      toolName: "task", input: { prompt },
      content: [{ type: "text", text: JSON.stringify({ status: "PASS", failures: [], verified_files: [{ path: join(repo, "somewhere-else.txt"), hash: "deadbeef" }] }) }],
    });
    await fire("tool_result", { toolName: "task", input: { prompt }, content: [] });
    const res = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "git commit -m 'c8'", cwd: repo },
    });
    equal(res, undefined, "gate must DISABLE after 3 real failures despite interleaved zero-merge PASS");
    await fire("session_start", {});
  });

  test("scenario 9 (#132 A.3b): schema-incomplete FAIL JSON keeps commit blocked, gate never disables", async () => {
    const repo = join(TEST_ROOT, "repo");
    git(repo, "reset -q");
    await fire("session_start", {});
    writeFileSync(join(repo, "fileE.txt"), "e1\n");
    git(repo, "add fileE.txt");
    const prompt = `[VGATE] verify files: fileE.txt. Classification: UI. Project root: ${repo}`;
    for (let i = 0; i < 3; i++) {
      await fire("tool_result", {
        toolName: "task", input: { prompt },
        content: [{ type: "text", text: JSON.stringify({ status: "FAIL", failures: ["lint error"] }) }],
      });
    }
    const res = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "git commit -m 'c9'", cwd: repo },
    });
    ok(res && res.block === true, "schema-incomplete FAIL must block — never fail open, never disable");
    await fire("session_start", {});
  });

  test("scenario 10 (#132 A.3b): plain-text FAIL line blocks instead of failing open", async () => {
    const repo = join(TEST_ROOT, "repo");
    git(repo, "reset -q");
    await fire("session_start", {});
    writeFileSync(join(repo, "fileF.txt"), "f1\n");
    git(repo, "add fileF.txt");
    const prompt = `[VGATE] verify files: fileF.txt. Classification: UI. Project root: ${repo}`;
    await fire("tool_result", {
      toolName: "task", input: { prompt },
      content: [{ type: "text", text: "❌ FAIL: tests broken" }],
    });
    const res = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "git commit -m 'c10'", cwd: repo },
    });
    ok(res && res.block === true, "plain-text FAIL must block (was fail-open before #132)");
    await fire("session_start", {});
  });

  test("scenario 11 (#132): plain-text PASS + noise merges via prompt files, gate stays active", async () => {
    const repo = join(TEST_ROOT, "repo");
    git(repo, "reset -q");
    await fire("session_start", {});
    writeFileSync(join(repo, "fileG.txt"), "g1\n");
    git(repo, "add fileG.txt");
    const prompt = `[VGATE] verify files: fileG.txt. Classification: UI. Project root: ${repo}`;
    // Block FIRST so lastBlockedFiles/lastBlockedCwd are set for this flow (same
    // pattern as scenario 5) — the plain-text merge is diff-scoped (#5673).
    const blocked = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "git commit -m 'c11'", cwd: repo },
    });
    ok(blocked && blocked.block === true, "must be blocked first");
    await fire("tool_result", {
      toolName: "task", input: { prompt },
      content: [{ type: "text", text: "PASS\n{\"event\":\"gate_bypass\",\"reason\":\"escape_hatch\"}" }],
    });
    const res = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "git commit -m 'c11'", cwd: repo },
    });
    equal(res, undefined, "plain-text PASS + noise must merge prompt files and allow the commit");
    await fire("session_start", {});
  });

  test("scenario 12 (#132 O/I/T): BLOCK_ATTEMPT_THRESHOLD auto-bypass unchanged — 3rd attempt allowed", async () => {
    const repo = join(TEST_ROOT, "repo");
    git(repo, "reset -q");
    await fire("session_start", {});
    writeFileSync(join(repo, "fileH.txt"), "h1\n");
    git(repo, "add fileH.txt");
    for (let i = 0; i < 3; i++) {
      const res = await fire("tool_call", {
        type: "tool_call", toolName: "bash",
        input: { command: "git commit -m 'c12'", cwd: repo },
      });
      if (i < 2) ok(res && res.block === true, `attempt ${i + 1} must block`);
      else equal(res, undefined, `attempt ${i + 1} must auto-bypass (BLOCK_ATTEMPT_THRESHOLD)`);
    }
    await fire("session_start", {});
  });

  test("bridge file stores repo-relative keys (survives session restart)", () => {
    const bridgePath = join(TEST_ROOT, ".pi", "agent", "verification", "latest.json");
    ok(existsSync(bridgePath), "bridge file must exist after PASS merges");
    const bridge = JSON.parse(readFileSync(bridgePath, "utf-8"));
    equal(bridge.status, "PASS");
    const paths = bridge.verified_files.map((vf: any) => vf.path);
    // The bridge holds the MOST RECENT merge — after the #132 scenarios that is
    // scenario 11's plain-text-PASS merge of fileG.txt (fileA.txt was merged in
    // scenarios 2-5 and overwritten). Repo-relative keying is the contract.
    ok(paths.includes("fileG.txt"), `bridge keys must be repo-relative, got: ${JSON.stringify(paths)}`);
    ok(!paths.some((p: string) => p.startsWith("/")), "bridge must not contain absolute keys");
  });
} // main: plugin loaded; tests run sequentially via runAll()

main()
  .then(() => runAll())
  .then(() => {
    console.log(`\n=== Final: ${passed} passed, ${failed} failed ===`);
    rmSync(TEST_ROOT, { recursive: true, force: true });
    if (failed > 0) process.exit(1);
    else console.log("✅ ALL E2E TESTS PASSED");
  })
  .catch((err) => {
    console.error("❌ HARNESS ERROR:", err);
    process.exit(1);
  });
