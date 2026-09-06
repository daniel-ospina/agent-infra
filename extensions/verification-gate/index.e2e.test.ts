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
import { mkdtempSync, writeFileSync, existsSync, readFileSync, mkdirSync, rmSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";

// ── Isolation: bridge lives under a temp HOME (never touch the real one) ──
const TEST_ROOT = mkdtempSync(join(tmpdir(), "vgate-e2e-"));
process.env.HOME = TEST_ROOT;
// The gate under test must be ACTIVE — clear the escape hatch if the parent
// environment inherited it (sub-agent sessions pre-disable extension gates).
delete process.env.ELDATO_SKIP_VGATE;
// #825: likewise clear parent-inherited sub-agent markers — the harness runs
// the plugin in INTERACTIVE mode by default; the #825 scenarios set
// PI_MODE=print + TASK_HEARTBEAT=1 explicitly (builtin-tools' task-child
// markers, #172/#825) to exercise the sub-agent paths, and scenario 24 deletes
// PI_MODE to exercise the interactive (non-print) half of the message split.
delete process.env.PI_MODE;
delete process.env.TASK_HEARTBEAT;

// ── Tiny git + sha helpers ───────────────────────────
function sha(text: string): string {
  return createHash("sha256").update(text).digest("hex");
}
function git(repo: string, args: string): string {
  return execSync(`git ${args}`, { cwd: repo, encoding: "utf-8", timeout: 20000 }).trim();
}

// ── D1 deterministic sentinel bridge (#482) ──────────
// Fixed PASS-shaped bytes planted immediately before an exempt op so the D1 allow-only
// byte-identity assert is ordering-independent (the old null-tolerant both-absent compare
// degraded to null===null whenever prior scenarios hadn't written the bridge). Foreign
// root → inert to every recovery (index.ts drops entries whose root ≠ the worktree root),
// inert to single-slot overwrite, and no post-39 scenario reads pre-38 bridge bytes.
// ⛔ The sentinel occupies the single bridge slot from scenario 38 until scenario 41's
// first real PASS write (Leg-A) — do NOT insert a bridge-READING scenario between 38 and
// 41 without reseeding a real bridge first.
const D1_SENTINEL_ROOT = "/__vgate-e2e-sentinel-root__";
const D1_SENTINEL_JSON = JSON.stringify({
  status: "PASS",
  verified_files: [{ path: `${D1_SENTINEL_ROOT}::sentinel`, hash: "0123456789abcdef".repeat(4) }], // fixed 64-hex
  timestamp: "2026-01-01T00:00:00.000Z", // fixed ISO — never Date.now()
});
function seedD1Sentinel(bridgePath: string): void {
  mkdirSync(dirname(bridgePath), { recursive: true });
  writeFileSync(bridgePath, D1_SENTINEL_JSON, "utf8");
}
function assertD1BridgeUntouched(bridgePath: string, repoRoot: string, label: string): void {
  const after = existsSync(bridgePath) ? readFileSync(bridgePath, "utf8") : null;
  // ORDER: the repo-root scan runs FIRST on FOREIGN content; the throwing byte-equal LAST.
  // Byte-identity remains the AUTHORITATIVE allow-only detector — null / non-JSON /
  // different-shape contamination still reds there with the allow-only message below. The
  // parse+root-scan that precedes it is diagnostics-only, restricted to foreign bytes:
  // when the byte-equal passes, the content IS the sentinel, so a parse loop running AFTER
  // it could only ever see the sentinel's own foreign-root entry (vacuous — contradicting
  // this PR's no-vacuous-tests mandate). Scanning first makes the loop LIVE: the real
  // contamination shape — a self-blessing / real PASS write that carries an entry keyed
  // under the scenario repo root — reds with the precise "would survive recovery"
  // diagnostic instead of a generic byte diff. The try is scoped to JSON.parse ALONE (a
  // non-JSON write must not abort the scan — the byte-equal below owns that red); the
  // shape check and the scan loop run OUTSIDE the try so the scan's ok(false) PROPAGATES
  // instead of being swallowed by the parse guard (a swallowed scan red would degrade the
  // diagnostic back to the generic byte diff). Never drop the byte-equal (it is the gate);
  // never reorder it before the scan (the scan is diagnostic, the equal decides).
  const repoReal = realpathSync(repoRoot);
  if (after !== null && after !== D1_SENTINEL_JSON) {
    let parsed: unknown = null;
    try { parsed = JSON.parse(after); } catch { /* not JSON — the byte-equal below owns the red */ }
    if (parsed !== null && typeof parsed === "object" && Array.isArray((parsed as { verified_files?: unknown }).verified_files)) {
      for (const vf of (parsed as { verified_files: unknown[] }).verified_files) {
        if (typeof vf === "object" && vf !== null && typeof (vf as { path?: unknown }).path === "string") {
          const p = (vf as { path: string }).path;
          const sepIdx = p.indexOf("::");
          ok(sepIdx === -1 || p.slice(0, sepIdx) !== repoReal,
            `${label} — bridge contamination keyed under the scenario repo root (${repoReal}): ${p} would survive recovery`);
        }
      }
    }
  }
  equal(after, D1_SENTINEL_JSON,
    `${label} — exempt op must leave the deterministic D1 sentinel bridge byte-identical (allow-only: no durable bridge write; in-memory verifiedSet contamination is pinned by scenario 41's no-hash-mismatch + still-block asserts)`);
}

// #285: audit-trail reader (HOME is redirected to TEST_ROOT at load, so the
// gate's durable audit log lands under TEST_ROOT/.pi/agent/audit/).
function readAuditLines(): Record<string, any>[] {
  const p = join(TEST_ROOT, ".pi", "agent", "audit", "gate-events.jsonl");
  if (!existsSync(p)) return [];
  return readFileSync(p, "utf8").trim().split("\n").filter(Boolean).map((l) => JSON.parse(l));
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

  test("bridge file stores compound keys (root::rel) for root-isolated recovery (#190)", () => {
    const bridgePath = join(TEST_ROOT, ".pi", "agent", "verification", "latest.json");
    ok(existsSync(bridgePath), "bridge file must exist after PASS merges");
    const bridge = JSON.parse(readFileSync(bridgePath, "utf-8"));
    equal(bridge.status, "PASS");
    const paths = bridge.verified_files.map((vf: any) => vf.path);
    // #190: the bridge now persists FULL compound keys (worktree-root::rel) so
    // recovery can be worktree-isolated (#37) with stored-hash match-or-drop.
    // The bridge holds the MOST RECENT merge — after the #132 scenarios that is
    // scenario 11's plain-text-PASS merge of fileG.txt (fileA.txt was merged in
    // scenarios 2-5 and overwritten). Compound keying is the new contract.
    ok(paths.some((p: string) => p.includes("::") && p.endsWith("fileG.txt")), `bridge keys must be compound (root::rel), got: ${JSON.stringify(paths)}`);
    ok(paths.every((p: string) => p.includes("::")), `bridge must not contain bare repo-relative keys, got: ${JSON.stringify(paths)}`);
  });

  // ── #190: mid-session VGATE merge regression scenarios ──
  // T1–T5 from the scoping doc: a mid-session [VGATE] dispatch whose PASS is
  // registered by the tool_result hook must merge into the committing session's
  // verifiedSet so the next git commit passes WITHOUT the BLOCK_ATTEMPT_THRESHOLD
  // auto-bypass. These run AFTER the bridge-contract test above (which asserts
  // on scenario 11's bridge state) and each fires session_start for isolation.

  test("scenario 13 (#190 T1): mid-session plain-text PASS merges — commit allowed on next attempt, no auto-bypass", async () => {
    const repo = join(TEST_ROOT, "repo");
    git(repo, "reset -q");
    await fire("session_start", {});
    writeFileSync(join(repo, "fileT1.txt"), "t1\n");
    git(repo, "add fileT1.txt");
    const blocked = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "git commit -m 'c13'", cwd: repo },
    });
    ok(blocked && blocked.block === true, "must be blocked first (unverified staged file)");
    // The incident's dispatch #2 format: documented prompt, plain-text line-start PASS.
    await fire("tool_result", {
      toolName: "task",
      input: { prompt: `[VGATE] verify files: fileT1.txt. Classification: UI. Project root: ${repo}` },
      content: [{ type: "text", text: "All checks passed.\nPASS" }],
    });
    const res = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "git commit -m 'c13'", cwd: repo },
    });
    equal(res, undefined, "commit must pass on the FIRST retry after mid-session PASS (no auto-bypass)");
    git(repo, "commit -m c13");
    await fire("session_start", {});
  });

  test("scenario 14 (#190 T2): prompt with \\n\\nClassification (no leading period) still merges", async () => {
    const repo = join(TEST_ROOT, "repo");
    git(repo, "reset -q");
    await fire("session_start", {});
    writeFileSync(join(repo, "fileT2.txt"), "t2\n");
    git(repo, "add fileT2.txt");
    const blocked = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "git commit -m 'c14'", cwd: repo },
    });
    ok(blocked && blocked.block === true, "must be blocked first");
    // Incident dispatch #1's deviant-but-reasonable format: newline separator,
    // no period before Classification (old fileMatch regex parsed ZERO files).
    const prompt = `[VGATE] verify files: fileT2.txt\n\nClassification: backend\nProject root: ${repo}`;
    await fire("tool_result", { toolName: "task", input: { prompt }, content: [{ type: "text", text: "PASS" }] });
    const res = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "git commit -m 'c14'", cwd: repo },
    });
    equal(res, undefined, "newline-separated Classification must still merge (T2)");
    git(repo, "commit -m c14");
    await fire("session_start", {});
  });

  test("scenario 15 (#190 T3): bold/list-marked **PASS** response merges (hasPass parity with hasFail)", async () => {
    const repo = join(TEST_ROOT, "repo");
    git(repo, "reset -q");
    await fire("session_start", {});
    writeFileSync(join(repo, "fileT3.txt"), "t3\n");
    git(repo, "add fileT3.txt");
    const blocked = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "git commit -m 'c15'", cwd: repo },
    });
    ok(blocked && blocked.block === true, "must be blocked first");
    await fire("tool_result", {
      toolName: "task",
      input: { prompt: `[VGATE] verify files: fileT3.txt. Classification: UI. Project root: ${repo}` },
      content: [{ type: "text", text: "- **PASS**" }],
    });
    const res = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "git commit -m 'c15'", cwd: repo },
    });
    equal(res, undefined, "bold PASS marker must merge (T3)");
    git(repo, "commit -m c15");
    await fire("session_start", {});
  });

  test("scenario 16 (#190 T4): mid-session bridge recovery — externally-written bridge unblocks the commit", async () => {
    const repo = join(TEST_ROOT, "repo");
    git(repo, "reset -q");
    await fire("session_start", {});
    writeFileSync(join(repo, "fileT4.txt"), "t4\n");
    git(repo, "add fileT4.txt");
    // Simulate the incident's event-miss class: a sub-agent session merged a PASS
    // and wrote the bridge (compound key + verifier-authoritative hash), but the
    // parent's tool_result hook never saw the dispatch. The next git op must
    // recover the bridge entry mid-session and allow the commit.
    const realRoot = realpathSync(repo);
    const bridgeDir = join(TEST_ROOT, ".pi", "agent", "verification");
    mkdirSync(bridgeDir, { recursive: true });
    writeFileSync(join(bridgeDir, "latest.json"), JSON.stringify({
      status: "PASS",
      verified_files: [{ path: `${realRoot}::fileT4.txt`, hash: sha("t4\n") }],
      timestamp: new Date().toISOString(),
    }));
    const res = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "git commit -m 'c16'", cwd: repo },
    });
    equal(res, undefined, "externally-written bridge must be recovered mid-session (T4)");
    git(repo, "commit -m c16");
    await fire("session_start", {});
  });

  test("scenario 17 (#190 T5): zero-merge PASS does not consume block context — retry dispatch still merges", async () => {
    const repo = join(TEST_ROOT, "repo");
    git(repo, "reset -q");
    await fire("session_start", {});
    writeFileSync(join(repo, "fileT5.txt"), "t5\n");
    git(repo, "add fileT5.txt");
    const blocked = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "git commit -m 'c17'", cwd: repo },
    });
    ok(blocked && blocked.block === true, "must be blocked first");
    // Dispatch #1: PASS but the prompt names a file OUTSIDE the blocked diff →
    // zero-merge. The block context (lastBlockedCwd/lastBlockedFiles) must survive.
    await fire("tool_result", {
      toolName: "task",
      input: { prompt: `[VGATE] verify files: unrelated.txt. Classification: UI. Project root: ${repo}` },
      content: [{ type: "text", text: "PASS" }],
    });
    // Dispatch #2: deviant prompt with ZERO parseable files — the plain-text
    // fallback merges the blocked diff ONLY if context survived dispatch #1.
    const deviantPrompt = `[VGATE] verify files:\n\nClassification: UI\nProject root: ${repo}`;
    await fire("tool_result", {
      toolName: "task", input: { prompt: deviantPrompt },
      content: [{ type: "text", text: "PASS" }],
    });
    const res = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "git commit -m 'c17'", cwd: repo },
    });
    equal(res, undefined, "retry after zero-merge dispatch must still merge (context retained, T5)");
    git(repo, "commit -m c17");
  });

  test("scenario 18 (#190 review): prose PASS ('PASS criteria are met') never triggers the whole-diff fallback", async () => {
    const repo = join(TEST_ROOT, "repo");
    git(repo, "reset -q");
    await fire("session_start", {});
    writeFileSync(join(repo, "fileT6.txt"), "t6\n");
    git(repo, "add fileT6.txt");
    const blocked = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "git commit -m 'c18'", cwd: repo },
    });
    ok(blocked && blocked.block === true, "must be blocked first");
    // Deviant prompt (zero parseable files) + PROSE PASS — the response echoes
    // the format spec ("PASS on its own line") but is not a standalone verdict.
    // The whole-diff fallback must NOT fire: zero merge, context retained.
    const deviantPrompt = `[VGATE] verify files:\n\nClassification: UI\nProject root: ${repo}`;
    await fire("tool_result", {
      toolName: "task", input: { prompt: deviantPrompt },
      content: [{ type: "text", text: "Remember: respond PASS on its own line. PASS criteria are met." }],
    });
    const res = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "git commit -m 'c18b'", cwd: repo },
    });
    ok(res && res.block === true, "prose PASS must NOT merge the blocked diff (still blocked)");
    // A genuine standalone PASS on the retry DOES merge (fallback intact).
    await fire("tool_result", {
      toolName: "task", input: { prompt: deviantPrompt },
      content: [{ type: "text", text: "PASS" }],
    });
    const res2 = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "git commit -m 'c18c'", cwd: repo },
    });
    equal(res2, undefined, "standalone PASS with deviant prompt merges the blocked diff (context retained)");
    git(repo, "commit -m c18c");
  });

  // ── #204: gh pr merge scope — cross-repo skip + same-repo status quo ──
  // The misfire: computeBranchDiff(cwd) computed the session cwd's branch
  // drift for a REMOTE merge (a merge that touches no local files). Each
  // scenario uses a dedicated temp repo with an origin remote + a drift ref so
  // the OLD behavior would block; the new behavior must skip (cross-repo,
  // network-free) or keep status quo (same-repo head-fail → fail-closed).

  test("scenario 19 (#204): cross-repo gh pr merge skips verification (network-free, no block)", async () => {
    const repoA = join(TEST_ROOT, "repo-merge-a");
    mkdirSync(repoA, { recursive: true });
    git(repoA, "init -b main");
    git(repoA, "config user.email e2e@test");
    git(repoA, "config user.name e2e");
    writeFileSync(join(repoA, "base.txt"), "b\n");
    git(repoA, "add base.txt");
    git(repoA, "commit -m base");
    const baseSha = git(repoA, "rev-parse HEAD");
    git(repoA, "remote add origin git@github.com:e2e/self.git");
    // Drift: HEAD moves past origin/main — the old gate would block on this
    // residue for a merge that touches nothing locally.
    writeFileSync(join(repoA, "drift.txt"), "d\n");
    git(repoA, "add drift.txt");
    git(repoA, "commit -m drift");
    git(repoA, `update-ref refs/remotes/origin/main ${baseSha}`);
    await fire("session_start", {});
    // Explicit --repo targets a DIFFERENT repo than the cwd origin → nothing
    // local represents the PR → skip BEFORE computeBranchDiff. Decidable with
    // zero network: no gh call, no verifier dispatch, no bridge writes.
    const res = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "gh pr merge 123 --repo other/owner", cwd: repoA },
    });
    equal(res, undefined, "cross-repo merge must not block on local drift residue");
  });

  test("scenario 20 (#204): same-repo merge with failing head check keeps status quo (fail-closed block)", async () => {
    const repoB = join(TEST_ROOT, "repo-merge-b");
    mkdirSync(repoB, { recursive: true });
    git(repoB, "init -b main");
    git(repoB, "config user.email e2e@test");
    git(repoB, "config user.name e2e");
    writeFileSync(join(repoB, "base.txt"), "b\n");
    git(repoB, "add base.txt");
    git(repoB, "commit -m base");
    const baseSha = git(repoB, "rev-parse HEAD");
    git(repoB, "remote add origin git@github.com:e2e/self.git");
    writeFileSync(join(repoB, "drift.txt"), "d\n");
    git(repoB, "add drift.txt");
    git(repoB, "commit -m drift");
    git(repoB, `update-ref refs/remotes/origin/main ${baseSha}`);
    await fire("session_start", {});
    // No --repo/GH_REPO → same-repo path → the gh head check runs; in this
    // sandbox gh cannot resolve PR 123 (no network/auth, e2e/self is not a
    // real repo) → prHead unknown → fail-closed: computeBranchDiff + block on
    // the drift file, exactly as today.
    const res = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "gh pr merge 123", cwd: repoB },
    });
    ok(res && res.block === true, "same-repo merge with unknown PR head must block on drift (status quo)");
    ok(res.reason.includes("drift.txt"), "block reason names the drift file");
  });

  // ── #825: sub-agent (env PI_MODE=print) commits inherit the parent's bridge ──
  // builtin-tools no longer injects ELDATO_SKIP_VGATE into task sub-agents; the
  // sub-agent's VGATE session recovers the parent's verified-file registry from
  // the bridge file. Scenarios 21-23, 25, 26 set the task-child marker pair
  // (PI_MODE=print + TASK_HEARTBEAT=1, exactly what builtin-tools injects)
  // explicitly — the harness clears them at startup — to exercise the sub-agent
  // paths; scenario 24 deletes both to exercise the interactive (non-print)
  // half of the message split; scenario 27 pins the swarm_daemon case
  // (PI_MODE=print WITHOUT TASK_HEARTBEAT → interactive behavior preserved).
  // Each print-mode scenario's finally restores by deletion when a marker was
  // previously undefined (assignment would leak the string "undefined" into
  // process.env).

  test("scenario 21 (#825): sub-agent inherits the parent's bridge — parent-verified file commits pass without re-dispatch", async () => {
    const repo = join(TEST_ROOT, "repo-subagent");
    mkdirSync(repo, { recursive: true });
    git(repo, "init -b main");
    git(repo, "config user.email e2e@test");
    git(repo, "config user.name e2e");
    writeFileSync(join(repo, "fileS.txt"), "s1\n");
    git(repo, "add fileS.txt");
    git(repo, "commit -m baseline");
    // The parent VGATE-verified the staged edit; the bridge carries the
    // compound key (worktree-root::rel) + verifier-authoritative hash.
    writeFileSync(join(repo, "fileS.txt"), "s2\n");
    git(repo, "add fileS.txt");
    const realRoot = realpathSync(repo);
    const bridgeDir = join(TEST_ROOT, ".pi", "agent", "verification");
    const bridgePath = join(bridgeDir, "latest.json");
    mkdirSync(bridgeDir, { recursive: true });
    const prevMode = process.env.PI_MODE;
    const prevHeartbeat = process.env.TASK_HEARTBEAT;
    process.env.PI_MODE = "print"; // builtin-tools task-child markers (#172/#825)
    process.env.TASK_HEARTBEAT = "1"; // sub-agent session (builtin-tools #172)
    try {
      await fire("session_start", {});
      // Control FIRST: no bridge entry yet → the gate must be ACTIVE in the
      // sub-agent and block the unverified file (proves an allow below is
      // specifically caused by bridge inheritance, not gate inactivity).
      const blocked = await fire("tool_call", {
        type: "tool_call", toolName: "bash",
        input: { command: "git commit -m 'sub1'", cwd: repo },
      });
      ok(blocked && blocked.block === true, "sub-agent must block the file BEFORE the bridge is written (gate active)");
      // Parent VGATE merge writes the bridge → the sub-agent's next git op
      // recovers it mid-session and the commit passes WITHOUT re-dispatch.
      writeFileSync(bridgePath, JSON.stringify({
        status: "PASS",
        verified_files: [{ path: `${realRoot}::fileS.txt`, hash: sha("s2\n") }],
        timestamp: new Date().toISOString(),
      }));
      const res = await fire("tool_call", {
        type: "tool_call", toolName: "bash",
        input: { command: "git commit -m 'sub1'", cwd: repo },
      });
      equal(res, undefined, "parent-verified file must pass in the sub-agent via bridge inheritance (no re-dispatch)");
      git(repo, "commit -m sub1");
    } finally {
      if (prevMode === undefined) delete process.env.PI_MODE; else process.env.PI_MODE = prevMode;
      if (prevHeartbeat === undefined) delete process.env.TASK_HEARTBEAT; else process.env.TASK_HEARTBEAT = prevHeartbeat;
    }
  });

  test("scenario 22 (#825/#264): sub-agent commit on UNVERIFIED files is blocked with a self-verify instruction", async () => {
    const repo = join(TEST_ROOT, "repo-subagent");
    git(repo, "reset -q");
    const prevMode = process.env.PI_MODE;
    const prevHeartbeat = process.env.TASK_HEARTBEAT;
    process.env.PI_MODE = "print"; // builtin-tools task-child markers (#172/#825)
    process.env.TASK_HEARTBEAT = "1";
    try {
      await fire("session_start", {});
      writeFileSync(join(repo, "fileU.txt"), "u1\n");
      git(repo, "add fileU.txt");
      const res = await fire("tool_call", {
        type: "tool_call", toolName: "bash",
        input: { command: "git commit -m 'sub2'", cwd: repo },
      });
      ok(res && res.block === true, "unverified sub-agent commit must be blocked");
      // Discriminating markers: the INTERACTIVE message also contains the bare
      // substring "sub-agent" ("Dispatch the verifier sub-agent"), so assert
      // sub-agent-only phrasing + the in-band self-verify instruction (#264:
      // the child HAS the task tool and self-satisfies VGATE — the old
      // report-to-parent contract is gone).
      ok(res.reason.includes("This session is a task sub-agent"), `block reason must carry the sub-agent marker, got: ${res.reason.slice(0, 200)}`);
      ok(/Dispatch your own VGATE verification/.test(res.reason), "sub-agent block must instruct the child to self-satisfy the gate via its own task-tool dispatch");
      ok(res.reason.includes("task(prompt="), "sub-agent block must show the self-dispatch task(...) template");
      // #483: anchor the file INSIDE the template region (not merely the reasons
      // block, where "- fileU.txt" also appears) — proves the block call site
      // passed allBlocked through, without pinning quoting/layout (exact copy
      // lives in the unit tests).
      const tpl = res.reason.slice(res.reason.indexOf("task(prompt="));
      ok(tpl.includes("verify files:") && tpl.includes("fileU.txt"), "self-dispatch template must name the blocked file in-band (verify files: <file> merge contract)");
      ok(!/Report this block/.test(res.reason), "sub-agent block must NOT tell the child to report back to the parent (dead-end contract removed)");
      ok(!/Dispatch the verifier sub-agent/.test(res.reason), "sub-agent block must NOT carry the parent's verifier-dispatch instruction");
    } finally {
      if (prevMode === undefined) delete process.env.PI_MODE; else process.env.PI_MODE = prevMode;
      if (prevHeartbeat === undefined) delete process.env.TASK_HEARTBEAT; else process.env.TASK_HEARTBEAT = prevHeartbeat;
    }
  });

  test("scenario 23 (#825): sub-agent has NO #7591 auto-bypass — 4th attempt still blocked", async () => {
    const repo = join(TEST_ROOT, "repo-subagent");
    git(repo, "reset -q");
    git(repo, "add fileU.txt"); // re-stage the still-unverified file
    const prevMode = process.env.PI_MODE;
    const prevHeartbeat = process.env.TASK_HEARTBEAT;
    process.env.PI_MODE = "print"; // builtin-tools task-child markers (#172/#825)
    process.env.TASK_HEARTBEAT = "1";
    try {
      await fire("session_start", {});
      for (let i = 0; i < 4; i++) {
        const res = await fire("tool_call", {
          type: "tool_call", toolName: "bash",
          input: { command: "git commit -m 'sub3'", cwd: repo },
        });
        ok(res && res.block === true, `attempt ${i + 1} must block in sub-agent mode (no auto-bypass)`);
      }
    } finally {
      if (prevMode === undefined) delete process.env.PI_MODE; else process.env.PI_MODE = prevMode;
      if (prevHeartbeat === undefined) delete process.env.TASK_HEARTBEAT; else process.env.TASK_HEARTBEAT = prevHeartbeat;
    }
  });

  test("scenario 24 (#825): INTERACTIVE session keeps the original verifier-dispatch block message (message split positive half)", async () => {
    const repo = join(TEST_ROOT, "repo-subagent");
    git(repo, "reset -q");
    git(repo, "add fileU.txt"); // re-stage the still-unverified file
    // Interactive parent session: clear both sub-agent markers explicitly so
    // the scenario is self-contained (not order-dependent on prior finallys).
    delete process.env.PI_MODE;
    delete process.env.TASK_HEARTBEAT;
    await fire("session_start", {});
    const res = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "git commit -m 'par1'", cwd: repo },
    });
    ok(res && res.block === true, "interactive unverified commit must be blocked");
    ok(/Dispatch the verifier sub-agent/.test(res.reason), "interactive block must keep the verifier-dispatch instruction");
    ok(/task\(prompt=/.test(res.reason), "interactive block must show the task(...) dispatch template");
    ok(!/Report this block/.test(res.reason), "sub-agent report-to-parent message must NOT leak into interactive sessions");
  });

  test("scenario 25 (#825/#264): sub-agent editing a parent-verified file (hash mismatch) blocks, then self-satisfies VGATE in-band and commits", async () => {
    const repo = join(TEST_ROOT, "repo-subagent-2");
    mkdirSync(repo, { recursive: true });
    git(repo, "init -b main");
    git(repo, "config user.email e2e@test");
    git(repo, "config user.name e2e");
    writeFileSync(join(repo, "fileM.txt"), "m1\n");
    git(repo, "add fileM.txt");
    git(repo, "commit -m baseline");
    // Parent verified m2; the bridge carries the verifier-authoritative hash.
    writeFileSync(join(repo, "fileM.txt"), "m2\n");
    git(repo, "add fileM.txt");
    const realRoot = realpathSync(repo);
    const bridgePath = join(TEST_ROOT, ".pi", "agent", "verification", "latest.json");
    writeFileSync(bridgePath, JSON.stringify({
      status: "PASS",
      verified_files: [{ path: `${realRoot}::fileM.txt`, hash: sha("m2\n") }],
      timestamp: new Date().toISOString(),
    }));
    const prevMode = process.env.PI_MODE;
    const prevHeartbeat = process.env.TASK_HEARTBEAT;
    process.env.PI_MODE = "print"; // builtin-tools task-child markers (#172/#825)
    process.env.TASK_HEARTBEAT = "1";
    try {
      await fire("session_start", {});
      // A non-commit git op triggers mid-session bridge recovery while the file
      // still matches the stored hash (m2) — the entry enters verifiedSet.
      // (push, not commit: no #7574 pendingRehash re-blessing on the next op.)
      // #487 tier-C-tied: this repo is base-less (no refs/remotes/origin/* — no
      // remote configured, no update-ref) → post-#487 the push resolves tier C
      // (no usable base) → status-quo staged scope; the comment's "push-scope
      // check" wording predates #487's range scoping and stays green unchanged.
      const allowed = await fire("tool_call", {
        type: "tool_call", toolName: "bash",
        input: { command: "git push origin main", cwd: repo },
      });
      equal(allowed, undefined, "parent-verified (hash-matching) file must pass the push-scope check");
      // Sub-agent then edits the parent-verified file (m2 → m3) and stages it:
      // the registry hash no longer matches disk → MISMATCH, fail-closed.
      writeFileSync(join(repo, "fileM.txt"), "m3\n");
      git(repo, "add fileM.txt");
      for (let i = 0; i < 3; i++) {
        const res = await fire("tool_call", {
          type: "tool_call", toolName: "bash",
          input: { command: "git commit -m 'subM'", cwd: repo },
        });
        ok(res && res.block === true, `mismatch attempt ${i + 1} must block in sub-agent mode (no auto-bypass)`);
        if (i === 0) {
          ok(/Hash mismatch/.test(res.reason), "block reason must carry the hash-mismatch diagnostic");
          ok(res.reason.includes("This session is a task sub-agent"), "mismatch block must still carry the sub-agent marker");
          ok(/Dispatch your own VGATE verification/.test(res.reason), "mismatch block must instruct the child to self-satisfy the gate in-band");
          ok(res.reason.includes("task(prompt="), "mismatch block must show the self-dispatch task(...) template");
          // #483: anchor the file INSIDE the template region (not merely the
          // reasons block) — proves allBlocked reached the template, without
          // pinning quoting/layout (exact copy lives in the unit tests).
          const tpl = res.reason.slice(res.reason.indexOf("task(prompt="));
          ok(tpl.includes("verify files:") && tpl.includes("fileM.txt"), "mismatch dispatch template must name the blocked file in-band (verify files: <file> merge contract)");
          ok(!/Report this block/.test(res.reason), "mismatch block must NOT carry the old report-to-parent contract");
        }
      }
      // #264: the child HAS the task tool (builtin-tools registers it
      // unconditionally), so it self-satisfies the gate — dispatches its own
      // [VGATE] verification; the tool_result handler merges the PASS exactly
      // like the parent's (verifier reports the CURRENT disk hash m3).
      const passJson = JSON.stringify({
        status: "PASS",
        failures: [],
        verified_files: [{ path: join(repo, "fileM.txt"), hash: sha("m3\n") }],
      });
      await fire("tool_result", {
        toolName: "task",
        input: { prompt: `[VGATE] verify files: fileM.txt. Classification: backend. Project root: ${repo}` },
        content: [{ type: "text", text: passJson }],
      });
      const passed = await fire("tool_call", {
        type: "tool_call", toolName: "bash",
        input: { command: "git commit -m 'subM'", cwd: repo },
      });
      equal(passed, undefined, "after the child self-dispatches VGATE verification, the commit passes");
      git(repo, "commit -m subM"); // make the state real
    } finally {
      if (prevMode === undefined) delete process.env.PI_MODE; else process.env.PI_MODE = prevMode;
      if (prevHeartbeat === undefined) delete process.env.TASK_HEARTBEAT; else process.env.TASK_HEARTBEAT = prevHeartbeat;
    }
  });

  test("scenario 26 (#825): foreign-worktree bridge entries are NOT inherited by a sub-agent (root isolation)", async () => {
    const repo = join(TEST_ROOT, "repo-subagent-3");
    mkdirSync(repo, { recursive: true });
    git(repo, "init -b main");
    git(repo, "config user.email e2e@test");
    git(repo, "config user.name e2e");
    writeFileSync(join(repo, "fileX.txt"), "x1\n");
    git(repo, "add fileX.txt");
    git(repo, "commit -m baseline");
    writeFileSync(join(repo, "fileX.txt"), "x2\n");
    git(repo, "add fileX.txt");
    // Bridge entry keyed to a DIFFERENT worktree root (compound-key isolation
    // #37/#190): recovery must drop it as inert, so the file stays unverified.
    const bridgePath = join(TEST_ROOT, ".pi", "agent", "verification", "latest.json");
    writeFileSync(bridgePath, JSON.stringify({
      status: "PASS",
      verified_files: [{ path: `/some/other/worktree::fileX.txt`, hash: sha("x2\n") }],
      timestamp: new Date().toISOString(),
    }));
    const prevMode = process.env.PI_MODE;
    const prevHeartbeat = process.env.TASK_HEARTBEAT;
    process.env.PI_MODE = "print"; // builtin-tools task-child markers (#172/#825)
    process.env.TASK_HEARTBEAT = "1";
    try {
      await fire("session_start", {});
      const res = await fire("tool_call", {
        type: "tool_call", toolName: "bash",
        input: { command: "git commit -m 'subX'", cwd: repo },
      });
      ok(res && res.block === true, "foreign-root bridge entry must NOT verify the file in this worktree");
      ok(res.reason.includes("fileX.txt"), "block reason names the file");
    } finally {
      if (prevMode === undefined) delete process.env.PI_MODE; else process.env.PI_MODE = prevMode;
      if (prevHeartbeat === undefined) delete process.env.TASK_HEARTBEAT; else process.env.TASK_HEARTBEAT = prevHeartbeat;
    }
  });

  test("scenario 27 (#825): PI_MODE=print WITHOUT TASK_HEARTBEAT (swarm_daemon worker) keeps interactive behavior", async () => {
    // #825 review: isPrintModeEnv() alone would misclassify swarm_daemon workers
    // (they set PI_MODE=print but are NOT task sub-agents — no parent session to
    // report blocks to). The discriminator is the task-child marker pair
    // PI_MODE=print + TASK_HEARTBEAT=1; a print-mode process WITHOUT the
    // heartbeat marker must keep the interactive message + #7591 auto-bypass.
    const repo = join(TEST_ROOT, "repo-subagent");
    git(repo, "reset -q");
    git(repo, "add fileU.txt"); // re-stage the still-unverified file
    const prevMode = process.env.PI_MODE;
    const prevHeartbeat = process.env.TASK_HEARTBEAT;
    process.env.PI_MODE = "print"; // swarm_daemon-style: PI_MODE only, no TASK_HEARTBEAT
    try {
      await fire("session_start", {});
      const res = await fire("tool_call", {
        type: "tool_call", toolName: "bash",
        input: { command: "git commit -m 'swarm1'", cwd: repo },
      });
      ok(res && res.block === true, "swarm-style print-mode commit must be blocked (unverified)");
      ok(/Dispatch the verifier sub-agent/.test(res.reason), "swarm-style session must keep the interactive verifier-dispatch message");
      ok(!/This session is a task sub-agent/.test(res.reason), "swarm-style session must NOT get the task-sub-agent message");
      // Interactive auto-bypass intact: attempts 1-2 block, attempt 3 auto-bypasses.
      const res2 = await fire("tool_call", {
        type: "tool_call", toolName: "bash",
        input: { command: "git commit -m 'swarm2'", cwd: repo },
      });
      ok(res2 && res2.block === true, "attempt 2 must block");
      const res3 = await fire("tool_call", {
        type: "tool_call", toolName: "bash",
        input: { command: "git commit -m 'swarm3'", cwd: repo },
      });
      equal(res3, undefined, "attempt 3 must auto-bypass (swarm-style keeps #7591)");
    } finally {
      if (prevMode === undefined) delete process.env.PI_MODE; else process.env.PI_MODE = prevMode;
      if (prevHeartbeat === undefined) delete process.env.TASK_HEARTBEAT; else process.env.TASK_HEARTBEAT = prevHeartbeat;
    }
  });

  test("scenario 28 (#264 P2/P3): TASK_HEARTBEAT_DISABLE=1 child still discriminates as a task sub-agent — marker forced by builtin-tools, no auto-bypass", async () => {
    // A parent with TASK_HEARTBEAT_DISABLE=1 must NOT spawn a markerless child:
    // builtin-tools now sets TASK_HEARTBEAT=1 on EVERY task child regardless of
    // the disable flag (DISABLE still flows to the child via the env spread — it
    // only gates the task-heartbeat EMITTER, which that extension checks itself).
    // Without the forced marker the child would hit the interactive path and
    // reach #7591 auto-bypass on unverified commits.
    const repo = join(TEST_ROOT, "repo-subagent-4");
    mkdirSync(repo, { recursive: true });
    git(repo, "init -b main");
    git(repo, "config user.email e2e@test");
    git(repo, "config user.name e2e");
    writeFileSync(join(repo, "fileD.txt"), "d1\n");
    git(repo, "add fileD.txt");
    git(repo, "commit -m baseline");
    writeFileSync(join(repo, "fileD.txt"), "d2\n");
    git(repo, "add fileD.txt");
    const prevMode = process.env.PI_MODE;
    const prevHeartbeat = process.env.TASK_HEARTBEAT;
    const prevDisable = process.env.TASK_HEARTBEAT_DISABLE;
    process.env.PI_MODE = "print";
    process.env.TASK_HEARTBEAT = "1"; // forced by builtin-tools even under DISABLE
    process.env.TASK_HEARTBEAT_DISABLE = "1"; // parent-side opt-out flows to the child
    try {
      await fire("session_start", {});
      for (let i = 0; i < 4; i++) {
        const res = await fire("tool_call", {
          type: "tool_call", toolName: "bash",
          input: { command: "git commit -m 'subD'", cwd: repo },
        });
        ok(res && res.block === true, `DISABLE child attempt ${i + 1} must block in sub-agent mode (no interactive auto-bypass)`);
        if (i === 0) {
          ok(res.reason.includes("This session is a task sub-agent"), "DISABLE child must get the sub-agent block message, not the interactive dispatch message");
          ok(/Dispatch your own VGATE verification/.test(res.reason), "DISABLE child must be told to self-satisfy the gate in-band");
        }
      }
    } finally {
      if (prevMode === undefined) delete process.env.PI_MODE; else process.env.PI_MODE = prevMode;
      if (prevHeartbeat === undefined) delete process.env.TASK_HEARTBEAT; else process.env.TASK_HEARTBEAT = prevHeartbeat;
      if (prevDisable === undefined) delete process.env.TASK_HEARTBEAT_DISABLE; else process.env.TASK_HEARTBEAT_DISABLE = prevDisable;
    }
  });

  test("scenario 29 (#264 P2): sub-agent session with 0 bridge-recovered files logs a startup warning surfaced in the task result", async () => {
    // Bridge-absent/stale sub-agent session: recoverBridgeForRoot returns 0 with
    // no diagnostic, the child's verifiedSet is empty, and every changed-file
    // commit is a block. The fix logs an audible warning in the child's startup
    // output so the parent sees it in the task result instead of discovering the
    // dead-end only via a silent all-block task report. (The harness's own git
    // root — agent-infra — is never in the bridge: prior scenarios only write
    // TEST_ROOT repo entries, so recovery here must be 0.)
    const prevMode = process.env.PI_MODE;
    const prevHeartbeat = process.env.TASK_HEARTBEAT;
    const captured: string[] = [];
    const origLog = console.log;
    const origErr = console.error;
    process.env.PI_MODE = "print"; // builtin-tools task-child markers (#172/#825)
    process.env.TASK_HEARTBEAT = "1";
    try {
      console.log = ((msg: string, ...rest: unknown[]) => { captured.push(String(msg)); origLog(msg, ...rest); }) as typeof console.log;
      console.error = ((msg: string, ...rest: unknown[]) => { captured.push(String(msg)); origErr(msg, ...rest); }) as typeof console.error;
      await fire("session_start", {});
    } finally {
      console.log = origLog;
      console.error = origErr;
      if (prevMode === undefined) delete process.env.PI_MODE; else process.env.PI_MODE = prevMode;
      if (prevHeartbeat === undefined) delete process.env.TASK_HEARTBEAT; else process.env.TASK_HEARTBEAT = prevHeartbeat;
    }
    ok(
      captured.some(l => l.includes("0 bridge-recovered files")),
      `sub-agent startup must warn on empty bridge recovery, got: ${captured.join(" | ")}`
    );
  });

  section("#336 — hash-less PASS records blocked files (one-dispatch loop)");

  test("scenario 30 (#336): JSON PASS with empty verified_files records the blocked files — commit allowed", async () => {
    const repo = join(TEST_ROOT, "repo-336");
    mkdirSync(repo, { recursive: true });
    git(repo, "init -b main");
    git(repo, "config user.email e2e@test");
    git(repo, "config user.name e2e");
    writeFileSync(join(repo, "file336.txt"), "v1\n");
    git(repo, "add file336.txt");
    git(repo, "commit -m baseline");
    await fire("session_start", {});
    writeFileSync(join(repo, "file336.txt"), "v2\n");
    git(repo, "add file336.txt");
    const blocked = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "git commit -m 'c336'", cwd: repo },
    });
    ok(blocked && blocked.block === true, "must be blocked first");
    // Verifier returns a schema-valid PASS with NO per-file hashes — the
    // pre-#336 gate zero-merged this and re-blocked every retry.
    await fire("tool_result", {
      toolName: "task",
      input: { prompt: `[VGATE] verify files: file336.txt. Classification: UI. Project root: ${repo}` },
      content: [{ type: "text", text: JSON.stringify({ status: "PASS", failures: [], verified_files: [] }) }],
    });
    const res = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "git commit -m 'c336'", cwd: repo },
    });
    equal(res, undefined, "empty-verified_files PASS must record blocked files and allow the commit (one dispatch)");
    git(repo, "commit -m c336");
    await fire("session_start", {});
  });

  test("scenario 31 (#336): bare PASS with a prompt lacking the literal 'verify files:' still records blocked files", async () => {
    const repo = join(TEST_ROOT, "repo-336");
    git(repo, "reset -q");
    await fire("session_start", {});
    writeFileSync(join(repo, "file336b.txt"), "w1\n");
    git(repo, "add file336b.txt");
    const blocked = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "git commit -m 'c336b'", cwd: repo },
    });
    ok(blocked && blocked.block === true, "must be blocked first");
    // Verifier dispatched via a NON-standard prompt (no `verify files:` literal,
    // detected only by agent === 'verifier') returns a bare PASS. The pre-#336
    // fallback required the `verify files:` phrase → zero-merge → re-block loop.
    await fire("tool_result", {
      toolName: "subagent",
      input: { agent: "verifier", task: "Please check the staged files" },
      content: [{ type: "text", text: "PASS" }],
    });
    const res = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "git commit -m 'c336b'", cwd: repo },
    });
    equal(res, undefined, "bare PASS with a non-standard prompt must record blocked files (one dispatch)");
    git(repo, "commit -m c336b");
    await fire("session_start", {});
  });

  test("scenario 32 (#336): post-PASS edit of a recorded file re-blocks (fail-closed)", async () => {
    const repo = join(TEST_ROOT, "repo-336");
    git(repo, "reset -q");
    await fire("session_start", {});
    writeFileSync(join(repo, "file336c.txt"), "x1\n");
    git(repo, "add file336c.txt");
    const blocked = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "git commit -m 'c336c'", cwd: repo },
    });
    ok(blocked && blocked.block === true, "must be blocked first");
    await fire("tool_result", {
      toolName: "task",
      input: { prompt: `[VGATE] verify files: file336c.txt. Classification: UI. Project root: ${repo}` },
      content: [{ type: "text", text: "PASS" }],
    });
    // Edit AFTER the PASS, then stage — the recorded hash must no longer match.
    writeFileSync(join(repo, "file336c.txt"), "x2\n");
    git(repo, "add file336c.txt");
    const res = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "git commit -m 'c336c'", cwd: repo },
    });
    ok(res && res.block === true, "post-PASS edit must re-block (hash mismatch, fail-closed)");
    ok(/Hash mismatch/.test(res.reason), "block reason must carry the hash-mismatch diagnostic");
    await fire("session_start", {})
  });

  section("#285 — fail-closed gates for task sub-agents (polluted parent, no auto-disable, no fail-open)");

  test("scenario 33 (#285 Fix B): polluted-parent task sub-agent — ELDATO_SKIP_VGATE=1 refused, gate stays ACTIVE", async () => {
    const repo = join(TEST_ROOT, "repo-285-b");
    mkdirSync(repo, { recursive: true });
    git(repo, "init -b main");
    git(repo, "config user.email e2e@test");
    git(repo, "config user.name e2e");
    writeFileSync(join(repo, "f285b.txt"), "v1\n");
    git(repo, "add f285b.txt");
    git(repo, "commit -m baseline");
    writeFileSync(join(repo, "f285b.txt"), "v2\n");
    git(repo, "add f285b.txt");
    const prevMode = process.env.PI_MODE;
    const prevHeartbeat = process.env.TASK_HEARTBEAT;
    const prevSkip = process.env.ELDATO_SKIP_VGATE;
    const captured: string[] = [];
    const origWarn = console.warn;
    process.env.PI_MODE = "print"; // builtin-tools task-child markers (#172/#825)
    process.env.TASK_HEARTBEAT = "1";
    process.env.ELDATO_SKIP_VGATE = "1"; // polluted parent launch env (swarm daemon M1)
    // #483: the ENTIRE scenario body is wrapped (session_start, the commit
    // tool_call exercising the per-command refusal, and every assertion) so
    // the finally restores the polluted-parent env on ANY mid-body throw —
    // the pre-#483 shape restored PI_MODE/TASK_HEARTBEAT/ELDATO_SKIP_VGATE
    // only at the END of the body (~6 assertions later), leaking child-mode +
    // escape-hatch env into scenarios 34+ (which would take the refused-
    // bypass branch) and misattributing the failure.
    try {
      console.warn = ((msg: string, ...rest: unknown[]) => { captured.push(String(msg)); origWarn(msg, ...rest); }) as typeof console.warn;
      await fire("session_start", {});
      // The per-command bypass branch ALSO runs (ELDATO_SKIP_VGATE still set):
      // refused → falls through → the commit is gated as usual → blocked.
      const res = await fire("tool_call", {
        type: "tool_call", toolName: "bash",
        input: { command: "git commit -m 'b285'", cwd: repo },
      });
      ok(res && res.block === true, "task sub-agent under a polluted parent env must STILL block the unverified commit (no disable, no per-command bypass)");
      ok(captured.some(l => l.includes("Bypass refused for task sub-agent")), "refused-bypass WARN must be emitted at session_start");
      ok(captured.some(l => l.includes("VGATE stays ACTIVE")), "WARN must state VGATE stays ACTIVE");
      const refused = readAuditLines().filter(l => l.event === "gate_bypass_refused");
      ok(refused.length >= 1, "gate_bypass_refused audit event must be written");
      ok(readAuditLines().filter(l => l.event === "gate_bypass" && l.reason === "escape_hatch").length === 0,
         "no escape_hatch gate_bypass record for the task sub-agent");
      git(repo, "reset -q");
    } finally {
      console.warn = origWarn;
      if (prevMode === undefined) delete process.env.PI_MODE; else process.env.PI_MODE = prevMode;
      if (prevHeartbeat === undefined) delete process.env.TASK_HEARTBEAT; else process.env.TASK_HEARTBEAT = prevHeartbeat;
      if (prevSkip === undefined) delete process.env.ELDATO_SKIP_VGATE; else process.env.ELDATO_SKIP_VGATE = prevSkip;
    }
  });

  test("scenario 34 (#285 P1-1): task sub-agent + 3× empty-content VGATE dispatches → gate NEVER auto-disables", async () => {
    const repo = join(TEST_ROOT, "repo-285-p11");
    mkdirSync(repo, { recursive: true });
    git(repo, "init -b main");
    git(repo, "config user.email e2e@test");
    git(repo, "config user.name e2e");
    writeFileSync(join(repo, "f34.txt"), "v1\n");
    git(repo, "add f34.txt");
    git(repo, "commit -m baseline");
    writeFileSync(join(repo, "f34.txt"), "v2\n");
    git(repo, "add f34.txt");
    const prevMode = process.env.PI_MODE;
    const prevHeartbeat = process.env.TASK_HEARTBEAT;
    process.env.PI_MODE = "print";
    process.env.TASK_HEARTBEAT = "1";
    try {
      await fire("session_start", {});
      const blocked = await fire("tool_call", {
        type: "tool_call", toolName: "bash",
        input: { command: "git commit -m 'p11'", cwd: repo },
      });
      ok(blocked && blocked.block === true, "must be blocked first");
      const prompt = `[VGATE] verify files: f34.txt. Classification: UI. Project root: ${repo}`;
      for (let i = 0; i < 3; i++) {
        await fire("tool_result", { toolName: "task", input: { prompt }, content: [] });
      }
      const res = await fire("tool_call", {
        type: "tool_call", toolName: "bash",
        input: { command: "git commit -m 'p11'", cwd: repo },
      });
      ok(res && res.block === true, "gate must STILL block after 3 empty-content dispatch failures in a task sub-agent (threshold disable refused, P1-1)");
      const res2 = await fire("tool_call", {
        type: "tool_call", toolName: "bash",
        input: { command: "git commit -m 'p11'", cwd: repo },
      });
      ok(res2 && res2.block === true, "no delayed auto-bypass: attempt 4 still blocked");
    } finally {
      if (prevMode === undefined) delete process.env.PI_MODE; else process.env.PI_MODE = prevMode;
      if (prevHeartbeat === undefined) delete process.env.TASK_HEARTBEAT; else process.env.TASK_HEARTBEAT = prevHeartbeat;
    }
  });

  test("scenario 35 (#285 P1-1): task sub-agent + 3× unparseable VGATE outputs WITHOUT prompt files → gate NEVER auto-disables", async () => {
    const repo = join(TEST_ROOT, "repo-285-p11b");
    mkdirSync(repo, { recursive: true });
    git(repo, "init -b main");
    git(repo, "config user.email e2e@test");
    git(repo, "config user.name e2e");
    writeFileSync(join(repo, "f35.txt"), "v1\n");
    git(repo, "add f35.txt");
    git(repo, "commit -m baseline");
    writeFileSync(join(repo, "f35.txt"), "v2\n");
    git(repo, "add f35.txt");
    const prevMode = process.env.PI_MODE;
    const prevHeartbeat = process.env.TASK_HEARTBEAT;
    process.env.PI_MODE = "print";
    process.env.TASK_HEARTBEAT = "1";
    try {
      await fire("session_start", {});
      const blocked = await fire("tool_call", {
        type: "tool_call", toolName: "bash",
        input: { command: "git commit -m 'p11b'", cwd: repo },
      });
      ok(blocked && blocked.block === true, "must be blocked first");
      // Prompt WITHOUT the `verify files:` literal → no prompt files → the
      // #5724 fail-open merge is unreachable → pure dispatch failure.
      const prompt = `[VGATE] check the staged changes. Classification: UI. Project root: ${repo}`;
      for (let i = 0; i < 3; i++) {
        await fire("tool_result", {
          toolName: "task",
          input: { prompt },
          content: [{ type: "text", text: "Verifier output was not parseable." }],
        });
      }
      const res = await fire("tool_call", {
        type: "tool_call", toolName: "bash",
        input: { command: "git commit -m 'p11b'", cwd: repo },
      });
      ok(res && res.block === true, "gate must STILL block after 3 unparseable-no-files dispatch failures in a task sub-agent");
    } finally {
      if (prevMode === undefined) delete process.env.PI_MODE; else process.env.PI_MODE = prevMode;
      if (prevHeartbeat === undefined) delete process.env.TASK_HEARTBEAT; else process.env.TASK_HEARTBEAT = prevHeartbeat;
    }
  });

  test("scenario 36 (#285 P2-B): task sub-agent + unparseable output WITH prompt files → fail-open REFUSED, block state preserved for re-dispatch", async () => {
    const repo = join(TEST_ROOT, "repo-285-p2b");
    mkdirSync(repo, { recursive: true });
    git(repo, "init -b main");
    git(repo, "config user.email e2e@test");
    git(repo, "config user.name e2e");
    writeFileSync(join(repo, "f36.txt"), "v1\n");
    git(repo, "add f36.txt");
    git(repo, "commit -m baseline");
    writeFileSync(join(repo, "f36.txt"), "v2\n");
    git(repo, "add f36.txt");
    const prevMode = process.env.PI_MODE;
    const prevHeartbeat = process.env.TASK_HEARTBEAT;
    process.env.PI_MODE = "print";
    process.env.TASK_HEARTBEAT = "1";
    try {
      await fire("session_start", {});
      const blocked = await fire("tool_call", {
        type: "tool_call", toolName: "bash",
        input: { command: "git commit -m 'p2b'", cwd: repo },
      });
      ok(blocked && blocked.block === true, "must be blocked first");
      const prompt = `[VGATE] verify files: f36.txt. Classification: backend. Project root: ${repo}`;
      await fire("tool_result", {
        toolName: "task",
        input: { prompt },
        content: [{ type: "text", text: "Verifier output was not parseable." }],
      });
      const res = await fire("tool_call", {
        type: "tool_call", toolName: "bash",
        input: { command: "git commit -m 'p2b'", cwd: repo },
      });
      ok(res && res.block === true, "unparseable-with-files dispatch must NOT fail open in a task sub-agent (files NOT recorded)");
      const refused = readAuditLines().filter(l => l.event === "gate_bypass_refused" && l.reason === "fail_open_refused");
      ok(refused.length >= 1, "gate_bypass_refused with reason fail_open_refused must be audited");
      // vgateFailures was NOT incremented (the refused branch returns before
      // the counter) and lastBlockedCwd/lastBlockedFiles were NOT consumed —
      // a proper JSON PASS re-dispatch still merges and unblocks:
      await fire("tool_result", {
        toolName: "task",
        input: { prompt },
        content: [{ type: "text", text: JSON.stringify({ status: "PASS", failures: [], verified_files: [{ path: join(repo, "f36.txt"), hash: sha("v2\n") }] }) }],
      });
      const passed = await fire("tool_call", {
        type: "tool_call", toolName: "bash",
        input: { command: "git commit -m 'p2b'", cwd: repo },
      });
      equal(passed, undefined, "valid JSON PASS after the refused dispatch must unblock the commit (block state preserved for re-dispatch)");
    } finally {
      if (prevMode === undefined) delete process.env.PI_MODE; else process.env.PI_MODE = prevMode;
      if (prevHeartbeat === undefined) delete process.env.TASK_HEARTBEAT; else process.env.TASK_HEARTBEAT = prevHeartbeat;
    }
  });

  test("scenario 37 (#285 P1-A): task-RESTRICTED sub-agent block message instructs return-to-parent (no in-band dispatch)", async () => {
    const repo = join(TEST_ROOT, "repo-285-p1a");
    mkdirSync(repo, { recursive: true });
    git(repo, "init -b main");
    git(repo, "config user.email e2e@test");
    git(repo, "config user.name e2e");
    writeFileSync(join(repo, "f37.txt"), "v1\n");
    git(repo, "add f37.txt");
    git(repo, "commit -m baseline");
    writeFileSync(join(repo, "f37.txt"), "v2\n");
    git(repo, "add f37.txt");
    const prevMode = process.env.PI_MODE;
    const prevHeartbeat = process.env.TASK_HEARTBEAT;
    const savedArgv = process.argv;
    process.env.PI_MODE = "print";
    process.env.TASK_HEARTBEAT = "1";
    // argv seam (P1-A): a restricted agent allowlist WITHOUT task. The
    // harness's process.argv has no --tools → task-capable by default; the
    // message builder reads process.argv at block time.
    process.argv = ["pi", "-p", "--tools", "read,bash,edit,write"] as unknown as string[];
    try {
      await fire("session_start", {});
      const res = await fire("tool_call", {
        type: "tool_call", toolName: "bash",
        input: { command: "git commit -m 'p1a'", cwd: repo },
      });
      ok(res && res.block === true, "restricted sub-agent commit must block");
      ok(res.reason.includes("This session is a task sub-agent"), "restricted block must carry the sub-agent marker");
      ok(res.reason.includes("return to the parent"), "restricted block must instruct the child to return to the parent session (semantic)");
      ok(res.reason.includes("block is final"), "restricted block must mark the block final (no in-band self-satisfy) — exact STOP/em-dash phrasing pinned in the unit tests");
      ok(!/Dispatch your own VGATE verification/.test(res.reason), "restricted block must NOT instruct in-band self-dispatch");
      ok(!/This session has the task tool/.test(res.reason), "restricted block must not claim the task tool");
    } finally {
      process.argv = savedArgv;
      if (prevMode === undefined) delete process.env.PI_MODE; else process.env.PI_MODE = prevMode;
      if (prevHeartbeat === undefined) delete process.env.TASK_HEARTBEAT; else process.env.TASK_HEARTBEAT = prevHeartbeat;
    }
  });

  // ── #472: proportionality — content-shape VGATE exemption + delete-push short-circuit ──
  // Mechanism (a): ops whose relevant file set is ENTIRELY docs/CSS/static
  // (no build-output path segment) skip VGATE — audited gate_skip:
  // content_shape_exempt. Allow-only (no verifiedSet/bridge writes) and
  // bare-commit guarded (isBareCommitShape — `-a`/bundles/pathspecs are never
  // exempt, D2). Mechanism (b): delete-shaped pushes ship NO local content and
  // short-circuit before any staged-diff computation — audited gate_skip:
  // delete_push_no_content. Both are additive early-return skips; the
  // unverified loop, #7591 auto-bypass, and sub-agent semantics stay
  // byte-identical. Each scenario uses a dedicated repo dir + session_start
  // (standard isolation); audit assertions use delta-counts over
  // readAuditLines() (records accumulate across scenarios).

  section("#472 — proportionality");

  test("scenario 38 (#472): docs-only commit unblocked (content-shape exemption, allow-only)", async () => {
    const repo = join(TEST_ROOT, "repo-472-38");
    mkdirSync(repo, { recursive: true });
    git(repo, "init -b main");
    git(repo, "config user.email e2e@test");
    git(repo, "config user.name e2e");
    writeFileSync(join(repo, "README.md"), "# demo\n");
    mkdirSync(join(repo, "styles"), { recursive: true });
    writeFileSync(join(repo, "styles", "theme.css"), "body{}\n");
    git(repo, "add README.md styles/theme.css");
    await fire("session_start", {});
    const skipBefore = readAuditLines().filter((l) => l.event === "gate_skip" && l.reason === "content_shape_exempt").length;
    const bypassBefore = readAuditLines().filter((l) => l.event === "gate_bypass").length;
    const bridgePath = join(TEST_ROOT, ".pi", "agent", "verification", "latest.json");
    // #482: seed the deterministic sentinel AFTER session_start and IMMEDIATELY BEFORE
    // the exempt op — byte-identity is then ordering-independent and self-contained (the
    // old pre/post snapshot compare degraded to null===null when prior scenarios never
    // wrote the bridge). This repo NEVER has a verifier dispatch, so a byte change (or a
    // file appearing) across the exempt commit is contamination.
    seedD1Sentinel(bridgePath);
    const res = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "git commit -m docs", cwd: repo },
    });
    equal(res, undefined, "docs-only commit must be ALLOWED (content-shape exemption)");
    const audit = readAuditLines();
    ok(audit.filter((l) => l.event === "gate_skip" && l.reason === "content_shape_exempt").length > skipBefore,
       "audit must record a gate_skip with reason content_shape_exempt");
    ok(audit.filter((l) => l.event === "gate_bypass").length === bypassBefore,
       "the skip must NOT add any gate_bypass entry (allow-only, no self-bless — D1)");
    // Audit deltas alone cannot catch a self-blessing skip (a contamination regression
    // emits gate_skip, not gate_bypass) — assert the durable registry channel directly.
    assertD1BridgeUntouched(bridgePath, repo, "docs-only commit");
  });

  test("scenario 39 (#472): docs-only gh pr create unblocked (branch-diff path)", async () => {
    const repo = join(TEST_ROOT, "repo-472-39");
    mkdirSync(repo, { recursive: true });
    git(repo, "init -b main");
    git(repo, "config user.email e2e@test");
    git(repo, "config user.name e2e");
    writeFileSync(join(repo, "base39.txt"), "b\n");
    git(repo, "add base39.txt");
    git(repo, "commit -m base");
    const baseSha = git(repo, "rev-parse HEAD");
    git(repo, "remote add origin git@github.com:e2e/self.git"); // scenario 19/20 remote/head sandbox
    // Docs-only feature branch ahead of origin/main (which stays at the base):
    git(repo, "checkout -b feat-docs");
    writeFileSync(join(repo, "README.md"), "# docs\n");
    git(repo, "add README.md");
    git(repo, "commit -m docs");
    git(repo, `update-ref refs/remotes/origin/main ${baseSha}`);
    await fire("session_start", {});
    const skipBefore = readAuditLines().filter((l) => l.event === "gate_skip" && l.reason === "content_shape_exempt").length;
    // `gh pr create` is NOT merge-scoped — its diff IS this branch's files
    // (computeBranchDiff). An all-docs branch diff hits mechanism (a).
    const bridgePath = join(TEST_ROOT, ".pi", "agent", "verification", "latest.json");
    // #482: deterministic sentinel seeded AFTER session_start and IMMEDIATELY BEFORE the
    // exempt create — byte-identity ordering-independent (see scenario 38).
    seedD1Sentinel(bridgePath);
    const res = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "gh pr create --title t", cwd: repo },
    });
    equal(res, undefined, "docs-only gh pr create must be ALLOWED (branch diff is all docs)");
    ok(readAuditLines().filter((l) => l.event === "gate_skip" && l.reason === "content_shape_exempt").length > skipBefore,
       "audit must record the content_shape_exempt skip for the create");
    // D1 allow-only on the branch-diff surface: this repo never dispatched, so
    // the sentinel bridge must be byte-identical across the exempt create
    // (scenario 38 pins the staged-diff surface; this pins computeBranchDiff).
    assertD1BridgeUntouched(bridgePath, repo, "docs-only gh pr create");
    // Mixed-branch denial (mechanism (a) on the branch-diff surface): a branch
    // carrying docs AND code must block on `gh pr create` — only an all-docs
    // branch is exempt. Scenarios 40/41/42 pin the staged-diff half, 44-leg4
    // pins an all-code merge diff; this pins the MIXED branch diff for the
    // create verb — a diff-scoping regression that filtered the branch diff
    // down to exempt-typed files would pass 39's all-docs leg but fail here.
    mkdirSync(join(repo, "src"), { recursive: true });
    writeFileSync(join(repo, "src", "app.ts"), "export const a = 1;\n");
    git(repo, "add src/app.ts");
    git(repo, "commit -m code");
    const res2 = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "gh pr create --title t2", cwd: repo },
    });
    ok(res2 && res2.block === true, "mixed docs+code branch must block on gh pr create (never exempt)");
    ok(res2.reason.includes("src/app.ts"), "create block reason names the code file");
  });

  test("scenario 39b (#472): docs-only gh pr merge unblocked (same-repo sandbox — exemption fires AFTER the #204 scope check)", async () => {
    const repo = join(TEST_ROOT, "repo-472-39b");
    mkdirSync(repo, { recursive: true });
    git(repo, "init -b main");
    git(repo, "config user.email e2e@test");
    git(repo, "config user.name e2e");
    writeFileSync(join(repo, "base39b.txt"), "b\n");
    git(repo, "add base39b.txt");
    git(repo, "commit -m base");
    const baseSha = git(repo, "rev-parse HEAD");
    git(repo, "remote add origin git@github.com:e2e/self.git");
    git(repo, "checkout -b feat-docs");
    writeFileSync(join(repo, "README.md"), "# docs\n");
    mkdirSync(join(repo, "styles"), { recursive: true });
    writeFileSync(join(repo, "styles", "theme.css"), "body{}\n");
    git(repo, "add README.md styles/theme.css");
    git(repo, "commit -m docs");
    git(repo, `update-ref refs/remotes/origin/main ${baseSha}`);
    await fire("session_start", {});
    const before = readAuditLines();
    // Same-repo merge (no --repo/-R): gh resolves the cwd origin e2e/self —
    // not a real repo — so the head check fails → same_repo_head_unknown
    // (verify: true — only cross_repo/head_mismatch skip, mirror of scenario
    // 20) → computeBranchDiff runs → the ALL-DOCS branch diff hits mechanism
    // (a). Pins the ordering property: (a) fires only AFTER the #204
    // merge-scope early return (a future move of (a) before GH_PR_PATTERN
    // would exempt cross-repo merges without the scope check).
    const res = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "gh pr merge 123", cwd: repo },
    });
    equal(res, undefined, "docs-only same-repo merge must be ALLOWED via the content-shape exemption");
    const fresh = readAuditLines().slice(before.length);
    ok(fresh.some((l) => l.event === "gate_skip" && l.reason === "content_shape_exempt"),
       "mechanism (a) must fire AFTER the scope check (audited content_shape_exempt)");
    ok(!fresh.some((l) => l.event === "gate_skip" && (l.reason === "cross_repo" || l.reason === "head_mismatch")),
       "the #204 merge-scope skip must NOT be the path taken (head check failed → verify:true, then (a) exempts)");
  });

  test("scenario 40 (#472): mixed docs+code staged set is NEVER exempt — block names both files", async () => {
    const repo = join(TEST_ROOT, "repo-472-40");
    mkdirSync(repo, { recursive: true });
    git(repo, "init -b main");
    git(repo, "config user.email e2e@test");
    git(repo, "config user.name e2e");
    writeFileSync(join(repo, "README.md"), "# mixed\n");
    mkdirSync(join(repo, "src"), { recursive: true });
    writeFileSync(join(repo, "src", "app.ts"), "export const a = 1;\n");
    git(repo, "add README.md src/app.ts");
    await fire("session_start", {});
    const res = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "git commit -m mixed", cwd: repo },
    });
    ok(res && res.block === true, "mixed docs+code staged set must be blocked (never exempt)");
    ok(res.reason.includes("README.md"), "block reason names the docs file");
    ok(res.reason.includes("src/app.ts"), "block reason names the code file");
  });

  test("scenario 41 (#472): docs exemption cannot dodge code verification; -a/-am sweep guard isolation (D2)", async () => {
    const repo = join(TEST_ROOT, "repo-472-41");
    mkdirSync(repo, { recursive: true });
    git(repo, "init -b main");
    git(repo, "config user.email e2e@test");
    git(repo, "config user.name e2e");
    writeFileSync(join(repo, "README.md"), "r1\n");
    mkdirSync(join(repo, "src"), { recursive: true });
    writeFileSync(join(repo, "src", "app.ts"), "a1\n");
    // Leg A — docs-only commit is exempt (allowed), then a CODE commit still
    // blocks; a fresh VGATE PASS (plain-text/JSON merge pattern) unblocks it.
    git(repo, "add README.md");
    await fire("session_start", {});
    const skipBefore = readAuditLines().filter((l) => l.event === "gate_skip" && l.reason === "content_shape_exempt").length;
    const docs = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "git commit -m docs", cwd: repo },
    });
    equal(docs, undefined, "docs-only commit is exempt (allowed)");
    ok(readAuditLines().filter((l) => l.event === "gate_skip" && l.reason === "content_shape_exempt").length > skipBefore,
       "docs commit audited content_shape_exempt");
    git(repo, "commit -m docs"); // make the docs commit real (index clean)
    git(repo, "add src/app.ts");
    const blocked = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "git commit -m code", cwd: repo },
    });
    ok(blocked && blocked.block === true, "a code commit right after a docs commit must STILL block");
    ok(blocked.reason.includes("src/app.ts"), "block reason names the .ts file");
    await fire("tool_result", {
      toolName: "task",
      input: { prompt: `[VGATE] verify files: src/app.ts. Classification: backend. Project root: ${repo}` },
      content: [{ type: "text", text: JSON.stringify({
        status: "PASS", failures: [],
        verified_files: [{ path: join(repo, "src/app.ts"), hash: sha("a1\n") }],
      }) }],
    });
    const allowed = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "git commit -m code", cwd: repo },
    });
    equal(allowed, undefined, "code commit must be ALLOWED after a fresh VGATE PASS (exemption never substitutes for verification)");
    git(repo, "commit -m code"); // make the code commit real
    // Leg B — guard isolation: staged docs ONLY + dirty UNSTAGED code file.
    writeFileSync(join(repo, "README.md"), "r2\n");
    git(repo, "add README.md");
    writeFileSync(join(repo, "src", "app.ts"), "a2\n"); // dirty — NOT staged
    const sweep1 = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: 'git commit -am "x"', cwd: repo },
    });
    ok(sweep1 && sweep1.block === true, "git commit -am with only docs staged must NOT ride the exemption (guard rejects the sweep → VGATE runs)");
    ok(sweep1.reason.includes("README.md"), "-am block reason names the staged docs (unverified)");
    ok(!/Hash mismatch/.test(sweep1.reason),
       "re-edited staged docs must read as UNVERIFIED, never hash-mismatch — if the Leg-A exemption had registered README.md (D1 contamination), the r2 edit would stale-hash against it");
    // #482: the sweep1 porcelain assert is DELETED — it was vacuous-but-green, not
    // provably invariant: a blocked -am never executes, so the assert could only ever pass
    // regardless of verdict (it still guarded the Leg-A exemption/porcelain state at sweep
    // time, but the hook-verdict pins above already prove the sweep is rejected). The real
    // porcelain evidence now lives on the ALLOWED bare commit below (which executes).
    const sweep2 = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: 'git commit -am"x"', cwd: repo }, // attached -am spelling (cycle-3 P1 repro)
    });
    ok(sweep2 && sweep2.block === true, "attached -am\"x\" spelling must also be rejected (never exempt)");
    const bare = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "git commit -m x", cwd: repo },
    });
    equal(bare, undefined, "bare git commit -m over ONLY staged docs is exempt");
    // #482: make the allowed bare docs commit REAL (Leg-A pattern) and pin the exact
    // porcelain — the old post-block porcelain assert was vacuous-but-green: a blocked -am
    // never executes, so it could only ever pass regardless of verdict. The real commit
    // executes the gate-approved docs exemption end-to-end: README.md r2 lands as a commit
    // and the dirty UNSTAGED src/app.ts stays untouched (bare commit -m commits only the
    // index by git invariant — the D2 REJECTION of -a sweeps and bundles is pinned by the
    // sweep1/sweep2 block asserts above, which red first on any such regression).
    git(repo, "commit -m x"); // execute the allowed docs commit for real
    // Raw porcelain read — the git() helper trims, which would eat the leading column
    // space of the two-column status (" M " = worktree-modified, not "M " staged); the
    // exact-porcelain pin needs the RAW bytes: exactly one line, no staged entries, no
    // untracked files.
    const porcelain = execSync("git status --porcelain", { cwd: repo, encoding: "utf-8", timeout: 20000 });
    equal(porcelain, " M src/app.ts\n",
       "real bare docs commit must commit README.md only — raw porcelain exactly ' M src/app.ts' (dirty unstaged src/app.ts untouched — end-to-end outcome of the gate-approved docs commit; D2 sweep rejection is pinned by the sweep1/sweep2 block asserts above)");
  });

  test("scenario 42 (#472): build-template boundary — public/ stays gated, website/ is exempt", async () => {
    const repo = join(TEST_ROOT, "repo-472-42");
    mkdirSync(repo, { recursive: true });
    git(repo, "init -b main");
    git(repo, "config user.email e2e@test");
    git(repo, "config user.name e2e");
    writeFileSync(join(repo, "base42.txt"), "b\n");
    git(repo, "add base42.txt");
    git(repo, "commit -m base");
    // Build-template side of the boundary: public/ is a BUILD_OUTPUT_SEGMENT
    // at any depth → its .html stays gated even though .html is exempt-typed.
    mkdirSync(join(repo, "public"), { recursive: true });
    writeFileSync(join(repo, "public", "index.html"), "<h1>app</h1>\n");
    writeFileSync(join(repo, "README.md"), "r1\n");
    git(repo, "add public/index.html README.md");
    await fire("session_start", {});
    const res = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "git commit -m tpl", cwd: repo },
    });
    ok(res && res.block === true, "public/index.html + docs must block (build template is never exempt, D3)");
    ok(res.reason.includes("public/index.html"), "block reason names the build-template file");
    git(repo, "commit -m tpl"); // make the mixed commit real → index clean
    // Static-site side of the boundary: website/ is NOT a build-output segment.
    mkdirSync(join(repo, "website"), { recursive: true });
    writeFileSync(join(repo, "website", "index.html"), "<h1>site</h1>\n");
    writeFileSync(join(repo, "README.md"), "r2\n");
    git(repo, "add website/index.html README.md");
    const skipBefore = readAuditLines().filter((l) => l.event === "gate_skip" && l.reason === "content_shape_exempt").length;
    const res2 = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "git commit -m static", cwd: repo },
    });
    equal(res2, undefined, "website/index.html + docs must be ALLOWED (website/ is not a build-output segment)");
    ok(readAuditLines().filter((l) => l.event === "gate_skip" && l.reason === "content_shape_exempt").length > skipBefore,
       "static-site commit audited content_shape_exempt");
  });

  test("scenario 43 (#470 repro, #472): 05-cleanup delete push over parked WIP unblocked — blesses nothing", async () => {
    const repo = join(TEST_ROOT, "repo-472-43");
    mkdirSync(repo, { recursive: true });
    git(repo, "init -b main");
    git(repo, "config user.email e2e@test");
    git(repo, "config user.name e2e");
    writeFileSync(join(repo, "wip43.ts"), "wip\n");
    git(repo, "add wip43.ts"); // parked WIP — staged, unverified, never committed
    await fire("session_start", {});
    const delBefore = readAuditLines().filter((l) => l.event === "gate_skip" && l.reason === "delete_push_no_content").length;
    // The #470 cleanup command (05-cleanup.md merged-branch remote delete):
    // multiline backslash continuation + 2>/dev/null redirect + || echo
    // fallback. Must classify as a delete-shaped push (mechanism b) and skip
    // BEFORE any staged-diff computation over the parked WIP.
    const cleanupLiteral = `git push origin --delete "$BRANCH" 2>/dev/null \\
  || echo "remote branch $BRANCH already deleted"`;
    const res = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: cleanupLiteral, cwd: repo },
    });
    equal(res, undefined, "delete push over parked WIP must be ALLOWED (mechanism b short-circuit)");
    ok(readAuditLines().filter((l) => l.event === "gate_skip" && l.reason === "delete_push_no_content").length > delBefore,
       "audit must record delete_push_no_content");
    // The deletion blessed NOTHING: committing the still-parked WIP blocks.
    const commit = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "git commit -m wip", cwd: repo },
    });
    ok(commit && commit.block === true, "parked WIP commit must STILL block after the delete push (nothing blessed)");
    ok(commit.reason.includes("wip43.ts"), "block reason names the parked WIP file");
  });

  test("scenario 44 (#472): content push stays gated — chain, single-& background, and same-repo gh merge", async () => {
    const repo = join(TEST_ROOT, "repo-472-44");
    mkdirSync(repo, { recursive: true });
    git(repo, "init -b main");
    git(repo, "config user.email e2e@test");
    git(repo, "config user.name e2e");
    writeFileSync(join(repo, "base44.txt"), "b\n");
    git(repo, "add base44.txt");
    git(repo, "commit -m base");
    const baseSha = git(repo, "rev-parse HEAD");
    // Origin MATCHES the -R target below so the merge leg is the SAME-REPO
    // path (a cross-repo sandbox would skip on repo grounds, scenario 19).
    git(repo, "remote add origin git@github.com:daniel-ospina/agent-infra.git");
    // Legs 1-3: parked WIP premise (staged unverified file); session_start per
    // leg keeps each block at attempt 1 (#7591 threshold never reached).
    // #487 tier-C-tied: legs 1-3 run BEFORE leg 4's update-ref — no
    // refs/remotes/origin/main exists yet, so post-#487 each push resolves tier C
    // (no usable base) → status-quo staged scope. Legs 2-3 additionally carry a
    // delete segment → the #487 classifier's mixed_delete whole-command rule
    // nulls to tier C staged. Behavior is byte-identical pre/post #487.
    for (let leg = 1; leg <= 3; leg++) {
      await fire("session_start", {});
      writeFileSync(join(repo, "wip44.ts"), `wip leg ${leg}\n`);
      git(repo, "add wip44.ts");
      const cmd = leg === 1 ? "git push origin main"
        : leg === 2 ? "git push origin --delete a && git push origin main"
        : "git push origin --delete a & git push origin main"; // single-& background
      const res = await fire("tool_call", {
        type: "tool_call", toolName: "bash",
        input: { command: cmd, cwd: repo },
      });
      ok(res && res.block === true, `content push leg ${leg} must stay gated: ${cmd}`);
      ok(res.reason.includes("wip44.ts"), `leg ${leg} block reason names the parked WIP`);
    }
    // Leg 4: gh pr merge over parked WIP must run the #204 merge-scope path,
    // NOT short-circuit on mechanism (b). Commit a drift file (real commit,
    // leaving wip44.ts parked) so the branch diff is non-empty, then point
    // origin/main at the base. gh's head check fails deterministically here
    // (PR 5 does not exist on daniel-ospina/agent-infra) → same_repo_head_unknown
    // → computeBranchDiff → block on the drift file (scenario 20 mirror). If a
    // future environment resolves the head, the decision flips to
    // head_mismatch (skip) — assert reality either way.
    writeFileSync(join(repo, "drift44.txt"), "d\n");
    git(repo, "add drift44.txt");
    git(repo, "commit -m drift -- drift44.txt"); // commit ONLY the drift file
    git(repo, `update-ref refs/remotes/origin/main ${baseSha}`);
    await fire("session_start", {});
    const before4 = readAuditLines();
    const res4 = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "gh -R daniel-ospina/agent-infra pr merge 5", cwd: repo },
    });
    const fresh4 = readAuditLines().slice(before4.length);
    ok(!fresh4.some((l) => l.event === "gate_skip" && l.reason === "delete_push_no_content"),
       "mechanism (b) must NOT short-circuit a gh pr merge (no delete_push_no_content skip)");
    if (res4 && res4.block === true) {
      ok(res4.reason.includes("drift44.txt"), "same-repo merge with unknown PR head blocks on the drift file (status quo)");
    } else {
      equal(res4, undefined, "merge was resolved by the #204 scope path (head_mismatch skip)");
      ok(fresh4.some((l) => l.event === "gate_skip" && l.reason === "head_mismatch"),
         "the head_mismatch skip must be audited when the head check succeeds");
    }
  });

  test("scenario 45 (#472): non-interception pins — git branch -D and git worktree remove never gate", async () => {
    const repo = join(TEST_ROOT, "repo-472-45");
    mkdirSync(repo, { recursive: true });
    git(repo, "init -b main");
    git(repo, "config user.email e2e@test");
    git(repo, "config user.name e2e");
    writeFileSync(join(repo, "base45.txt"), "b\n");
    git(repo, "add base45.txt");
    git(repo, "commit -m base");
    git(repo, "branch feat/x"); // realism: the branch exists
    await fire("session_start", {});
    const n0 = readAuditLines().length;
    const r1 = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "git branch -D feat/x", cwd: repo },
    });
    equal(r1, undefined, "git branch -D is not a VGATE-intercepted op");
    equal(readAuditLines().length, n0, "git branch -D must add NO audit entry");
    const r2 = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "git worktree remove feat/x", cwd: repo },
    });
    equal(r2, undefined, "git worktree remove is not a VGATE-intercepted op");
    equal(readAuditLines().length, n0, "git worktree remove must add NO audit entry");
  });

  test("scenario 46 (#472): flag-before-remote delete push unblocked; sub-agent docs commit exempt (deterministic, no bypass channel)", async () => {
    const repo = join(TEST_ROOT, "repo-472-46");
    mkdirSync(repo, { recursive: true });
    git(repo, "init -b main");
    git(repo, "config user.email e2e@test");
    git(repo, "config user.name e2e");
    writeFileSync(join(repo, "base46.txt"), "b\n");
    git(repo, "add base46.txt");
    git(repo, "commit -m base");
    writeFileSync(join(repo, "wip46.ts"), "w\n");
    git(repo, "add wip46.ts"); // parked WIP — must not block a delete push
    await fire("session_start", {});
    // (a) flag-before-remote spelling: git push --delete origin feat/x.
    const delBefore = readAuditLines().filter((l) => l.event === "gate_skip" && l.reason === "delete_push_no_content").length;
    const resA = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "git push --delete origin feat/x", cwd: repo },
    });
    equal(resA, undefined, "flag-before-remote delete push must be ALLOWED (mechanism b)");
    ok(readAuditLines().filter((l) => l.event === "gate_skip" && l.reason === "delete_push_no_content").length > delBefore,
       "audit must record delete_push_no_content for the --delete-first spelling");
    // (b) sub-agent mode (task-child markers, scenario 25 env pattern): a
    // docs-only commit is exempt there too — content-shape is a pure function
    // of the op's file set, so child behavior is uniform (no bypass channel;
    // #825 children still block on CODE).
    git(repo, "reset -q"); // drop the parked WIP from the index
    const prevMode = process.env.PI_MODE;
    const prevHeartbeat = process.env.TASK_HEARTBEAT;
    process.env.PI_MODE = "print"; // builtin-tools task-child markers (#172/#825)
    process.env.TASK_HEARTBEAT = "1";
    try {
      await fire("session_start", {});
      const skipBefore = readAuditLines().filter((l) => l.event === "gate_skip" && l.reason === "content_shape_exempt").length;
      mkdirSync(join(repo, "docs"), { recursive: true });
      writeFileSync(join(repo, "docs", "notes46.md"), "n\n");
      git(repo, "add docs/notes46.md");
      const resB = await fire("tool_call", {
        type: "tool_call", toolName: "bash",
        input: { command: "git commit -m docs46", cwd: repo },
      });
      equal(resB, undefined, "sub-agent docs-only commit must be ALLOWED (content-shape exemption in child mode)");
      ok(readAuditLines().filter((l) => l.event === "gate_skip" && l.reason === "content_shape_exempt").length > skipBefore,
         "child docs skip audited content_shape_exempt");
      // (c) child-mode delete push over parked WIP — mechanism (b) is
      // mode-independent: the short-circuit fires in the sub-agent too (a
      // pure early return — no interaction with the #825 block-message split).
      writeFileSync(join(repo, "wip46.ts"), "w\n");
      git(repo, "add wip46.ts");
      const delChildBefore = readAuditLines().filter((l) => l.event === "gate_skip" && l.reason === "delete_push_no_content").length;
      const resC = await fire("tool_call", {
        type: "tool_call", toolName: "bash",
        input: { command: "git push --delete origin feat/x", cwd: repo },
      });
      equal(resC, undefined, "child-mode delete push must be ALLOWED (mechanism b fires in sub-agent mode too)");
      ok(readAuditLines().filter((l) => l.event === "gate_skip" && l.reason === "delete_push_no_content").length > delChildBefore,
         "child delete push audited delete_push_no_content");
      // (d) child-mode MIXED docs+code staged set — falls through the
      // exemption (never exempt) to the sub-agent block path naming the code
      // file (scenario 40's child half: marker + file list must be right).
      git(repo, "reset -q");
      writeFileSync(join(repo, "README.md"), "# mixed\n");
      mkdirSync(join(repo, "src"), { recursive: true });
      writeFileSync(join(repo, "src", "code46.ts"), "export const c = 1;\n");
      git(repo, "add README.md src/code46.ts");
      const mixedBefore = readAuditLines().filter((l) => l.event === "gate_skip" && l.reason === "content_shape_exempt").length;
      const resD = await fire("tool_call", {
        type: "tool_call", toolName: "bash",
        input: { command: "git commit -m mixed46", cwd: repo },
      });
      ok(resD && resD.block === true, "child-mode mixed docs+code commit must block (never exempt)");
      ok(resD.reason.includes("This session is a task sub-agent"), "child mixed block must carry the sub-agent marker");
      ok(resD.reason.includes("src/code46.ts"), "child mixed block names the code file");
      equal(readAuditLines().filter((l) => l.event === "gate_skip" && l.reason === "content_shape_exempt").length, mixedBefore,
            "child mixed block must NOT add a content_shape_exempt skip");
    } finally {
      if (prevMode === undefined) delete process.env.PI_MODE; else process.env.PI_MODE = prevMode;
      if (prevHeartbeat === undefined) delete process.env.TASK_HEARTBEAT; else process.env.TASK_HEARTBEAT = prevHeartbeat;
    }
  });

  test("scenario 47 (#472): all-docs staged PUSH unblocked (content-shape exemption — push half of commit/push)", async () => {
    // Surface map row 1 covers "(commit/push staged diff)". Scenarios 38/41/42
    // exercise the commit verb and 39/39b the gh branch-diff verbs — never a
    // plain `git push` over an all-docs staged diff. Mechanism (a) must NOT be
    // commit-only: isBareCommitShape("git push …") is vacuously bare (unit-
    // pinned), so a push whose staged set is all-docs is exempt too. This pins
    // that at the hook level with the audit record.
    const repo = join(TEST_ROOT, "repo-472-47");
    mkdirSync(repo, { recursive: true });
    git(repo, "init -b main");
    git(repo, "config user.email e2e@test");
    git(repo, "config user.name e2e");
    writeFileSync(join(repo, "base47.txt"), "b\n");
    git(repo, "add base47.txt");
    git(repo, "commit -m base");
    writeFileSync(join(repo, "README.md"), "# docs\n");
    git(repo, "add README.md");
    // #487 tier-C-tied: this repo is base-less (no refs/remotes/origin/*) →
    // post-#487 the push resolves tier C → staged scope; the content-shape
    // exemption here fires on the STAGED docs set. The RANGE-set docs
    // exemption (committed docs on a real push range) is scenario 56's pin.
    await fire("session_start", {});
    const skipBefore = readAuditLines().filter((l) => l.event === "gate_skip" && l.reason === "content_shape_exempt").length;
    const res = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "git push origin main", cwd: repo },
    });
    equal(res, undefined, "all-docs staged push must be ALLOWED (content-shape exemption applies to pushes)");
    ok(readAuditLines().filter((l) => l.event === "gate_skip" && l.reason === "content_shape_exempt").length > skipBefore,
       "audit must record content_shape_exempt for the push");
  });

  test("scenario 48 (#489): git commit -a / --all sweeps dirty code — working-tree diff scope (HEAD mode)", async () => {
    // The #489 hole: `git commit -a` records the tracked WORKING TREE, not just the
    // index. A gate scoped to `git diff --cached` sees only staged docs, a docs PASS
    // unlocks the commit, and the sweep ships never-verified dirty code. Post-fix the
    // file set comes from `git diff HEAD` (exactly what the sweep records).
    const repo = join(TEST_ROOT, "repo-489-48");
    mkdirSync(repo, { recursive: true });
    git(repo, "init -b main");
    git(repo, "config user.email e2e@test");
    git(repo, "config user.name e2e");
    writeFileSync(join(repo, "README.md"), "r1\n");
    mkdirSync(join(repo, "src"), { recursive: true });
    writeFileSync(join(repo, "src", "app.ts"), "a1\n");
    git(repo, "add README.md src/app.ts");
    git(repo, "commit -m base");
    // Session layout: session_start at the start and before legs B/E/F/G. The
    // B/E/F resets are isolation hygiene (clears verifiedSet + #7591 counters;
    // auto-bypass is unreachable here, app.ts never exceeds attempt 2 under any
    // layout). TWO load-bearing boundaries: (1) NO session_start between Leg B's
    // PASS and Leg C's allow (README registration must survive verifiedSet.clear()
    // into Leg C); (2) Leg G's session_start is REQUIRED, not hygiene — Leg F's
    // fire-time bridge recovery re-registers app.ts sha("a4\n") into the in-memory
    // verifiedSet, and recovery is ADD-ONLY (fire-time match-or-drop can drop a
    // stale bridge entry but never removes an already-merged in-memory key), so
    // without the reset the G discriminator fire would classify app.ts (disk a5)
    // as a HASH MISMATCH, not unverified — reddening the !/Hash mismatch/ assert.
    // Every block-expecting leg edits its file to NEW content first, so the
    // tool_call bridge-recovery match-or-drop drops stale hashes (block
    // expectations stay deterministic).
    await fire("session_start", {});
    // Leg A — staged docs + dirty code, `-am`, both UNVERIFIED: block names BOTH.
    writeFileSync(join(repo, "README.md"), "r2\n");
    git(repo, "add README.md");
    writeFileSync(join(repo, "src", "app.ts"), "a2\n"); // dirty — NOT staged
    const legA = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: 'git commit -am "x"', cwd: repo },
    });
    ok(legA && legA.block === true, "Leg A: -am with staged docs + dirty code must block");
    ok(/Unverified files[\s\S]*README\.md/.test(legA.reason), "Leg A: staged docs read as UNVERIFIED (never hash-mismatch — no prior PASS in this fresh repo root)");
    ok(/Unverified files[\s\S]*src\/app\.ts/.test(legA.reason), "Leg A: the swept dirty code file is VGATE-required — block names src/app.ts (pre-fix: names only README.md)");
    ok(!/Hash mismatch/.test(legA.reason), "Leg A: no hash-mismatch section (both files UNVERIFIED — deterministic for a fresh repo root)");
    // Leg B — hole closer (red pre-fix): a docs-only PASS must NOT unlock the sweep.
    await fire("session_start", {});
    await fire("tool_result", {
      toolName: "task",
      input: { prompt: `[VGATE] verify files: README.md. Classification: backend. Project root: ${repo}` },
      content: [{ type: "text", text: JSON.stringify({
        status: "PASS", failures: [],
        verified_files: [{ path: join(repo, "README.md"), hash: sha("r2\n") }],
      }) }],
    });
    const legB = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: 'git commit -am "x"', cwd: repo },
    });
    ok(legB && legB.block === true, "Leg B: docs-only PASS must NOT unlock the -a sweep — code still blocks (pre-fix: ALLOWED → code ships unverified)");
    ok(legB.reason.includes("src/app.ts"), "Leg B: block names the swept dirty code file (VGATE-required)");
    ok(!legB.reason.includes("README.md"), "Leg B: the verified docs file is NOT re-blocked — the docs PASS is honored (only the swept code blocks)");
    ok(!/Hash mismatch/.test(legB.reason), "Leg B: no hash-mismatch section — README's registration matches disk (deterministic)");
    // Leg C — code PASS → allow → real sweep commits BOTH (both verified).
    await fire("tool_result", {
      toolName: "task",
      input: { prompt: `[VGATE] verify files: src/app.ts. Classification: backend. Project root: ${repo}` },
      content: [{ type: "text", text: JSON.stringify({
        status: "PASS", failures: [],
        verified_files: [{ path: join(repo, "src/app.ts"), hash: sha("a2\n") }],
      }) }],
    });
    const legC = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: 'git commit -am "x"', cwd: repo },
    });
    equal(legC, undefined, "Leg C: -am ALLOWED after both files verified");
    git(repo, 'commit -am "x"'); // execute the allowed sweep for real
    const cCommit = execSync("git diff HEAD^ --name-only", { cwd: repo, encoding: "utf-8", timeout: 20000 });
    ok(cCommit.includes("README.md") && cCommit.includes("src/app.ts"),
       "Leg C: the allowed -a sweep committed BOTH the staged docs and the dirty code (correct — both verified)");
    equal(execSync("git status --porcelain", { cwd: repo, encoding: "utf-8", timeout: 20000 }).trim(), "",
       "Leg C: real -a sweep committed both files — porcelain clean");
    // Leg D — bare docs commit stays shape-exempt (T3); dirty code untouched.
    writeFileSync(join(repo, "README.md"), "r3\n");
    git(repo, "add README.md");
    writeFileSync(join(repo, "src", "app.ts"), "a3\n"); // dirty — NOT staged
    const skipBefore = readAuditLines().filter((l) => l.event === "gate_skip" && l.reason === "content_shape_exempt").length;
    const legD = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "git commit -m x", cwd: repo },
    });
    equal(legD, undefined, "Leg D: bare commit over ONLY staged docs is shape-exempt (unchanged — T2/T3)");
    ok(readAuditLines().filter((l) => l.event === "gate_skip" && l.reason === "content_shape_exempt").length > skipBefore,
       "Leg D: bare docs commit audited content_shape_exempt");
    git(repo, "commit -m x"); // execute the allowed bare docs commit for real
    const porcelainD = execSync("git status --porcelain", { cwd: repo, encoding: "utf-8", timeout: 20000 });
    equal(porcelainD, " M src/app.ts\n",
       "Leg D: bare docs commit committed README.md only — raw porcelain exactly ' M src/app.ts' (dirty code untouched)");
    // Leg E — empty-index sweep (purest variant): dirty code + NOTHING staged blocks.
    await fire("session_start", {});
    writeFileSync(join(repo, "src", "app.ts"), "a4\n"); // dirty — nothing staged
    const legE = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "git commit -a -m sweep", cwd: repo },
    });
    ok(legE && legE.block === true, "Leg E: empty-index -a over dirty code must block (pre-fix: empty staged diff → ALLOWED → code swept unverified)");
    ok(legE.reason.includes("src/app.ts"), "Leg E: block names the dirty code file");
    await fire("tool_result", {
      toolName: "task",
      input: { prompt: `[VGATE] verify files: src/app.ts. Classification: backend. Project root: ${repo}` },
      content: [{ type: "text", text: JSON.stringify({
        status: "PASS", failures: [],
        verified_files: [{ path: join(repo, "src/app.ts"), hash: sha("a4\n") }],
      }) }],
    });
    const legE2 = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "git commit -a -m sweep", cwd: repo },
    });
    equal(legE2, undefined, "Leg E: -a ALLOWED after the code file verified");
    git(repo, "commit -a -m sweep"); // execute for real
    equal(execSync("git status --porcelain", { cwd: repo, encoding: "utf-8", timeout: 20000 }).trim(), "",
       "Leg E: real -a sweep committed the code file — porcelain clean");
    // Leg F — docs-only empty-index -a: fail-closed friction pin (allow→block flip).
    await fire("session_start", {});
    writeFileSync(join(repo, "README.md"), "r5\n"); // dirty docs — NOT staged, no code changes
    const legF = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "git commit -a -m docs", cwd: repo },
    });
    ok(legF && legF.block === true,
       "Leg F: docs-only empty-index -a now blocks as UNVERIFIED docs (post-fix WT scope is non-empty; sweep never exempt (D2) — pre-fix: empty staged diff → ALLOWED). Intentional fail-closed allow→block flip");
    ok(legF.reason.includes("README.md"), "Leg F: block names the docs file");
    // Leg G — MIXED chain (`-m` bare + `-a` sweep in ONE command) → union scope
    // (staged ∪ worktree). Red-under-regression discriminator: an index-only
    // staged file whose disk content equals HEAD is invisible to `git diff HEAD`
    // (a WT-only scope would name only app.ts) and a staged-only scope would
    // name only README — the union names BOTH (the bare half records the staged
    // README; the sweep half records the dirty app.ts). Fresh content r7/r8 is
    // used because the Leg-D rehash + Leg-E PASS blessed README sha("r3\n") into
    // the DURABLE bridge — restoring disk to the old HEAD r3 would re-bless it
    // via bridge recovery at the fire (disk==registered → verified → only the
    // WT file blocks). A raw commit first advances HEAD to never-registered r7,
    // so the disk-restored file's hash matches nothing in the bridge.
    await fire("session_start", {});
    writeFileSync(join(repo, "README.md"), "r7\n");
    git(repo, "add README.md");
    git(repo, 'commit -m "g-base"');            // raw real commit — HEAD README r7 (never PASS-registered)
    writeFileSync(join(repo, "README.md"), "r8\n");
    git(repo, "add README.md");                  // staged r8 — index-only
    writeFileSync(join(repo, "README.md"), "r7\n"); // disk back to HEAD r7 → WT-invisible (never-blessed hash)
    writeFileSync(join(repo, "src", "app.ts"), "a5\n"); // dirty WT code (unverified)
    const legG = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: 'git commit -m "docs" && git commit -am "x"', cwd: repo },
    });
    ok(legG && legG.block === true, "Leg G: mixed bare+sweep chain must block — the union scope names BOTH files");
    ok(/Unverified files[\s\S]*README\.md/.test(legG.reason), "Leg G: the index-only staged docs (disk==HEAD) are VGATE-required via the UNION (a WT-only scope would name only app.ts)");
    ok(/Unverified files[\s\S]*src\/app\.ts/.test(legG.reason), "Leg G: the swept dirty code file is VGATE-required (a staged-only scope would name only README.md)");
    ok(!/Hash mismatch/.test(legG.reason), "Leg G: no hash-mismatch section (both files unverified — deterministic: r7/a5 never registered)");
    // PASS both (README at its DISK content r7 — the staged r8 is never on disk;
    // the union is name-scoped, see the #489 plan) → allow → real mixed chain.
    await fire("tool_result", {
      toolName: "task",
      input: { prompt: `[VGATE] verify files: README.md src/app.ts. Classification: backend. Project root: ${repo}` },
      content: [{ type: "text", text: JSON.stringify({
        status: "PASS", failures: [],
        verified_files: [
          { path: join(repo, "README.md"), hash: sha("r7\n") },
          { path: join(repo, "src/app.ts"), hash: sha("a5\n") },
        ],
      }) }],
    });
    const legG2 = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: 'git commit -m "docs" && git commit -am "x"', cwd: repo },
    });
    equal(legG2, undefined, "Leg G: mixed chain ALLOWED after both files verified (union scope)");
    git(repo, 'commit -m "docs"'); // bare half for real — commits the staged README r8 (docs-only bare → shape-exempt)
    git(repo, 'commit -am "x"');   // sweep half for real — sweeps README disk r7 + app.ts a5
    const gSweep = execSync("git diff HEAD^ --name-only", { cwd: repo, encoding: "utf-8", timeout: 20000 });
    ok(gSweep.includes("README.md") && gSweep.includes("src/app.ts"),
       "Leg G: the real mixed chain committed the bare half (README r8) then swept both files in the -a half");
    equal(execSync("git status --porcelain", { cwd: repo, encoding: "utf-8", timeout: 20000 }).trim(), "",
       "Leg G: real mixed chain committed both halves — porcelain clean");
  });

  test("scenario 49 (#489): unborn-HEAD sweep fallback + deleted-tracked sweep edges", async () => {
    // Sub-case (a): unborn HEAD — `git commit -a` records only the index and `git diff
    // HEAD` errors; the fallback must return the STAGED set (a naive error→[] would
    // under-gate to allow). GREEN pre-fix too (a staged set on unborn already blocks via
    // the staged scope) — this is a fallback REGRESSION GUARD; the red pin for the
    // empty-index sweep is scenario 48 Leg E.
    const repoA = join(TEST_ROOT, "repo-489-49a");
    mkdirSync(repoA, { recursive: true });
    git(repoA, "init -b main");
    git(repoA, "config user.email e2e@test");
    git(repoA, "config user.name e2e");
    writeFileSync(join(repoA, "README.md"), "r\n");
    mkdirSync(join(repoA, "src"), { recursive: true });
    writeFileSync(join(repoA, "src", "app.ts"), "a\n");
    git(repoA, "add README.md src/app.ts"); // staged — NO baseline commit (unborn)
    await fire("session_start", {});
    const resA = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "git commit -a -m first", cwd: repoA },
    });
    ok(resA && resA.block === true, "49a: unborn -a with staged files must block (unborn fallback returns the staged set, not [])");
    ok(resA.reason.includes("README.md") && resA.reason.includes("src/app.ts"), "49a: block names both staged files");
    // PASS both → allowed → real commit creates the first commit.
    await fire("tool_result", {
      toolName: "task",
      input: { prompt: `[VGATE] verify files: README.md src/app.ts. Classification: backend. Project root: ${repoA}` },
      content: [{ type: "text", text: JSON.stringify({
        status: "PASS", failures: [],
        verified_files: [
          { path: join(repoA, "README.md"), hash: sha("r\n") },
          { path: join(repoA, "src/app.ts"), hash: sha("a\n") },
        ],
      }) }],
    });
    const resA2 = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "git commit -a -m first", cwd: repoA },
    });
    equal(resA2, undefined, "49a: -a ALLOWED after both staged files verified");
    git(repoA, "commit -a -m first");
    ok(execSync("git rev-parse HEAD", { cwd: repoA, encoding: "utf-8", timeout: 20000 }).trim().length === 40,
       "49a: real unborn -a commit created");
    // Sub-case (b): staged deletion under -a — deletions are content-free (verify loop
    // skips unhashable/deleted files) and must never name-block or forever-block.
    const repoB = join(TEST_ROOT, "repo-489-49b");
    mkdirSync(repoB, { recursive: true });
    git(repoB, "init -b main");
    git(repoB, "config user.email e2e@test");
    git(repoB, "config user.name e2e");
    writeFileSync(join(repoB, "src.ts"), "s1\n");
    writeFileSync(join(repoB, "notes.txt"), "n\n");
    git(repoB, "add src.ts notes.txt");
    git(repoB, "commit -m base");
    await fire("session_start", {});
    git(repoB, "rm src.ts");          // staged deletion
    writeFileSync(join(repoB, "notes.txt"), "n2\n"); // dirty — NOT staged
    git(repoB, "add notes.txt");      // staged dirty (unverified)
    const resB = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "git commit -a -m del", cwd: repoB },
    });
    ok(resB && resB.block === true, "49b: -a with a staged deletion + dirty staged file must block on the CONTENT file");
    ok(resB.reason.includes("notes.txt"), "49b: block names the dirty content file");
    ok(!resB.reason.includes("src.ts"), "49b: the deleted file is content-free — never named, never forever-blocks (hashFile catch → skip)");
    // Verify the deletion path does not stale-hash: PASS the content file → allowed →
    // real commit removes src.ts and commits notes.txt.
    await fire("tool_result", {
      toolName: "task",
      input: { prompt: `[VGATE] verify files: notes.txt. Classification: backend. Project root: ${repoB}` },
      content: [{ type: "text", text: JSON.stringify({
        status: "PASS", failures: [],
        verified_files: [{ path: join(repoB, "notes.txt"), hash: sha("n2\n") }],
      }) }],
    });
    const resB2 = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "git commit -a -m del", cwd: repoB },
    });
    equal(resB2, undefined, "49b: -a ALLOWED after the content file verified");
    git(repoB, "commit -a -m del");
    const delCommit = execSync("git diff HEAD^ --name-only", { cwd: repoB, encoding: "utf-8", timeout: 20000 });
    ok(delCommit.includes("notes.txt") && !existsSync(join(repoB, "src.ts")),
       "49b: real -a commit deleted src.ts and committed notes.txt");
  });

  // ── #487 — content pushes verify the PUSHED RANGE, not the whole index ──
  // T1/T2/T3 pins. Pre-fix every push below computes git diff --cached (whole-
  // index staged scope) so parked WIP false-blocks a push of already-committed
  // HEAD. Post-fix an eligible content push resolves tier A (2-dot vs the
  // remote-tracking ref) / tier B (3-dot vs the first-push base) / tier C
  // (status-quo staged fallback). Fixtures mirror scenario 44's plumbing
  // (update-ref'd refs/remotes/origin/main as the tier-A/B base; `fire` never
  // runs a real push — interception returns first; git() runs only plumbing +
  // allowed commits).
  section("Issue #487 — push-range scope for content pushes (tiers A/B/C)");

  test("scenario 50 (#487 T3 allow): committed-HEAD push over parked WIP unblocked via range scope — RED pre-fix", async () => {
    const repo = join(TEST_ROOT, "repo-487-50");
    mkdirSync(repo, { recursive: true });
    git(repo, "init -b main");
    git(repo, "config user.email e2e@test");
    git(repo, "config user.name e2e");
    writeFileSync(join(repo, "base50.txt"), "b\n");
    git(repo, "add base50.txt");
    git(repo, "commit -m base");
    const baseSha = git(repo, "rev-parse HEAD");
    // content50.ts: staged → PASS-verified → commit-ALLOWED → REAL commit (HEAD
    // now ahead of the base). Temp repos have no pre-commit hooks and git() is
    // raw execSync → disk == committed == verified hash (no #7574 reliance).
    writeFileSync(join(repo, "content50.ts"), "c50\n");
    git(repo, "add content50.ts");
    await fire("session_start", {});
    await fire("tool_result", {
      toolName: "task",
      input: { prompt: `[VGATE] verify files: content50.ts. Classification: backend. Project root: ${repo}` },
      content: [{ type: "text", text: JSON.stringify({
        status: "PASS", failures: [],
        verified_files: [{ path: join(repo, "content50.ts"), hash: sha("c50\n") }],
      }) }],
    });
    const allowCommit = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "git commit -m c50", cwd: repo },
    });
    equal(allowCommit, undefined, "50: content50.ts commit ALLOWED after the PASS (staged scope)");
    git(repo, "commit -m c50");
    // Parked WIP from another session (staged, unverified, never committed).
    writeFileSync(join(repo, "wip50.ts"), "w\n");
    git(repo, "add wip50.ts");
    // Tier-A base: origin/main at the ANCESTOR base commit.
    git(repo, `update-ref refs/remotes/origin/main ${baseSha}`);
    await fire("session_start", {});
    const auditBefore50 = readAuditLines().filter((l) => l.event === "gate_skip" && l.reason === "delete_push_no_content").length;
    const push = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "git push origin main", cwd: repo },
    });
    equal(push, undefined,
      "50: push of ALREADY-VERIFIED committed HEAD over parked WIP must be ALLOWED post-fix (tier A range [content50.ts]); RED pre-fix: whole-index staged scope [wip50.ts] blocks");
    equal(readAuditLines().filter((l) => l.event === "gate_skip" && l.reason === "delete_push_no_content").length, auditBefore50,
      "50: the allow must NOT ride the delete-push short-circuit (no delete_push_no_content skip — the plan-pinned negative discriminator between a tier-A range allow and a false-green delete bypass)");
    // The push blessed NOTHING: committing the still-parked WIP still blocks.
    const commit = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "git commit -m wip", cwd: repo },
    });
    ok(commit && commit.block === true, "50: parked WIP commit must STILL block after the range-allow (nothing blessed)");
    ok(commit.reason.includes("wip50.ts"), "50: block reason names the parked WIP file");
  });

  test("scenario 51 (#487): range names the pushed file, never the WIP — block + verify→unblock round-trip", async () => {
    const repo = join(TEST_ROOT, "repo-487-51");
    mkdirSync(repo, { recursive: true });
    git(repo, "init -b main");
    git(repo, "config user.email e2e@test");
    git(repo, "config user.name e2e");
    writeFileSync(join(repo, "base51.txt"), "b\n");
    git(repo, "add base51.txt");
    git(repo, "commit -m base");
    const baseSha = git(repo, "rev-parse HEAD");
    // RAW commit (scenario 44-leg-4 precedent): committed-but-NEVER-verified
    // content ahead of the base.
    writeFileSync(join(repo, "content51.ts"), "c51\n");
    git(repo, "add content51.ts");
    git(repo, "commit -m c51 -- content51.ts");
    git(repo, `update-ref refs/remotes/origin/main ${baseSha}`); // ancestor — tier A
    writeFileSync(join(repo, "wip51.ts"), "w\n");
    git(repo, "add wip51.ts"); // parked WIP — staged, unverified, never committed
    await fire("session_start", {});
    const push = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "git push origin main", cwd: repo },
    });
    ok(push && push.block === true, "51: push of unverified committed content must block");
    ok(push.reason.includes("content51.ts"),
       "51: block reason names the PUSHED RANGE file content51.ts (RED pre-fix: staged scope names wip51.ts, never content51.ts)");
    ok(!push.reason.includes("wip51.ts"),
       "51: block reason must NOT name the parked WIP (RED pre-fix: staged scope names wip51.ts)");
    // Verify→unblock round-trip: a PASS naming the committed range file (which
    // NEVER appears in git diff --cached) merges via the block context —
    // lastBlockedFiles = [content51.ts] → scopeFiles' blockedSet path — and
    // unblocks the retry push. This is the merge side's ONLY acceptance path
    // for the committed-range file class the new push-block introduces.
    await fire("tool_result", {
      toolName: "task",
      input: { prompt: `[VGATE] verify files: content51.ts. Classification: backend. Project root: ${repo}` },
      content: [{ type: "text", text: JSON.stringify({
        status: "PASS", failures: [],
        verified_files: [{ path: join(repo, "content51.ts"), hash: sha("c51\n") }],
      }) }],
    });
    const retry = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "git push origin main", cwd: repo },
    });
    equal(retry, undefined,
      "51: retry push ALLOWED after the range file is verified (wip51.ts stays unverified but is OUT of the range)");
  });

  test("scenario 52 (#487 tier B): first push — no tracking ref, origin/main present → 3-dot range", async () => {
    const repo = join(TEST_ROOT, "repo-487-52");
    mkdirSync(repo, { recursive: true });
    git(repo, "init -b main");
    git(repo, "config user.email e2e@test");
    git(repo, "config user.name e2e");
    writeFileSync(join(repo, "base52.txt"), "b\n");
    git(repo, "add base52.txt");
    git(repo, "commit -m base");
    const baseSha = git(repo, "rev-parse HEAD");
    git(repo, `update-ref refs/remotes/origin/main ${baseSha}`);
    git(repo, "checkout -b feat"); // feat == base; NO refs/remotes/origin/feat
    writeFileSync(join(repo, "content52.ts"), "c52\n");
    git(repo, "add content52.ts");
    await fire("session_start", {});
    await fire("tool_result", {
      toolName: "task",
      input: { prompt: `[VGATE] verify files: content52.ts. Classification: backend. Project root: ${repo}` },
      content: [{ type: "text", text: JSON.stringify({
        status: "PASS", failures: [],
        verified_files: [{ path: join(repo, "content52.ts"), hash: sha("c52\n") }],
      }) }],
    });
    const allowCommit = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "git commit -m c52", cwd: repo },
    });
    equal(allowCommit, undefined, "52: content52.ts commit ALLOWED after the PASS");
    git(repo, "commit -m c52");
    writeFileSync(join(repo, "wip52.ts"), "w\n");
    git(repo, "add wip52.ts"); // parked WIP
    await fire("session_start", {});
    const push = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "git push -u origin feat", cwd: repo },
    });
    equal(push, undefined,
      "52: tier-B first push over parked WIP ALLOWED post-fix (3-dot origin/main...feat range [content52.ts] verified); RED pre-fix: staged [wip52.ts] blocks; a tier-C regression would also block → allow proves tier B engaged");
  });

  test("scenario 53 (#487 tier C guard): no usable base keeps the staged check — green pre/post", async () => {
    const repo = join(TEST_ROOT, "repo-487-53");
    mkdirSync(repo, { recursive: true });
    git(repo, "init -b main");
    git(repo, "config user.email e2e@test");
    git(repo, "config user.name e2e");
    writeFileSync(join(repo, "base53.txt"), "b\n");
    git(repo, "add base53.txt");
    git(repo, "commit -m base");
    writeFileSync(join(repo, "wip53.ts"), "w\n");
    git(repo, "add wip53.ts"); // parked WIP — NO remote, NO update-ref anywhere
    await fire("session_start", {});
    const push = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "git push origin main", cwd: repo },
    });
    ok(push && push.block === true,
       "53: base-less push must keep the staged check (tier C, fail-closed) — regression guard: an error→[] resolver bug would flip this to allow");
    ok(push.reason.includes("wip53.ts"), "53: block names the parked WIP (status-quo staged scope)");
  });

  test("scenario 54 (#487): up-to-date push — empty resolved range audited push_range_empty, then allow — RED pre-fix", async () => {
    const repo = join(TEST_ROOT, "repo-487-54");
    mkdirSync(repo, { recursive: true });
    git(repo, "init -b main");
    git(repo, "config user.email e2e@test");
    git(repo, "config user.name e2e");
    writeFileSync(join(repo, "base54.txt"), "b\n");
    git(repo, "add base54.txt");
    git(repo, "commit -m base");
    const baseSha = git(repo, "rev-parse HEAD");
    git(repo, `update-ref refs/remotes/origin/main ${baseSha}`); // AT HEAD — up to date, nothing ships
    writeFileSync(join(repo, "wip54.ts"), "w\n");
    git(repo, "add wip54.ts"); // parked WIP — in NO range
    await fire("session_start", {});
    const before = readAuditLines().length;
    const push = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "git push origin main", cwd: repo },
    });
    equal(push, undefined,
      "54: up-to-date push must ALLOW (resolved range is empty — nothing ships); RED pre-fix: staged [wip54.ts] blocks");
    const fresh = readAuditLines().slice(before);
    ok(fresh.some((l) => l.event === "gate_skip" && l.reason === "push_range_empty"),
       "54: empty resolved range must be audited push_range_empty INSIDE the resolver, before the shared silent empty-allow");
  });

  test("scenario 55 (#487): bare-push upstream ceremony + force-push legs — tier A / tier C fallback / 2-dot D-row", async () => {
    const repo = join(TEST_ROOT, "repo-487-55");
    mkdirSync(repo, { recursive: true });
    git(repo, "init -b main");
    git(repo, "config user.email e2e@test");
    git(repo, "config user.name e2e");
    writeFileSync(join(repo, "base55.txt"), "b\n");
    git(repo, "add base55.txt");
    git(repo, "commit -m base");
    const baseSha = git(repo, "rev-parse HEAD");
    git(repo, `update-ref refs/remotes/origin/main ${baseSha}`);
    git(repo, "config branch.main.remote origin");
    git(repo, "config branch.main.merge refs/heads/main");
    writeFileSync(join(repo, "content55.ts"), "c55\n");
    git(repo, "add content55.ts");
    await fire("session_start", {});
    await fire("tool_result", {
      toolName: "task",
      input: { prompt: `[VGATE] verify files: content55.ts. Classification: backend. Project root: ${repo}` },
      content: [{ type: "text", text: JSON.stringify({
        status: "PASS", failures: [],
        verified_files: [{ path: join(repo, "content55.ts"), hash: sha("c55\n") }],
      }) }],
    });
    const allowCommit = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "git commit -m c55", cwd: repo },
    });
    equal(allowCommit, undefined, "55: content55.ts commit ALLOWED after the PASS");
    git(repo, "commit -m c55");
    writeFileSync(join(repo, "wip55.ts"), "w\n");
    git(repo, "add wip55.ts"); // parked WIP — staged through all three legs
    await fire("session_start", {});
    // Leg (a): the 04-merge-deploy.md ceremony — BARE push with upstream config.
    // This is the ONLY pin on the bare-push config-probe I/O path
    // (branch.<cur>.remote/.merge reads; src = current branch).
    const legA = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "git push --force-with-lease", cwd: repo },
    });
    equal(legA, undefined,
      "55a: bare push of verified committed HEAD over parked WIP ALLOWED (tier A range [content55.ts]); RED pre-fix: staged [wip55.ts] blocks");
    // Leg (b) negative: no upstream merge config → resolver null → tier C
    // staged → the parked WIP blocks again (fail-closed fallback pinned).
    git(repo, "config --unset branch.main.merge");
    const legB = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "git push --force-with-lease", cwd: repo },
    });
    ok(legB && legB.block === true, "55b: bare push WITHOUT upstream merge config keeps the staged check (fail-closed tier C)");
    ok(legB.reason.includes("wip55.ts"), "55b: block names the parked WIP");
    // Leg (c): force-push 2-dot over a DIVERGED origin/main — the D-row comes
    // from the REF tree (a remote-side-only file), never from a local git rm.
    // The sibling commit is PATHSpec-limited (scenario 44-leg-4 precedent) so
    // the still-staged wip55.ts is NOT swept into the sibling tree — a plain
    // add+commit would empty the main index and kill this leg's RED.
    git(repo, `switch -c remote55 ${baseSha}`); // sibling off the ORIGINAL base
    writeFileSync(join(repo, "remote55.ts"), "r\n");
    git(repo, "add remote55.ts");
    git(repo, "commit -m sibling55 -- remote55.ts");
    const siblingSha = git(repo, "rev-parse HEAD");
    git(repo, `update-ref refs/remotes/origin/main ${siblingSha}`); // DIVERGED sibling tree
    git(repo, "switch main"); // wip55.ts still staged in the index (in neither tree)
    const legC = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "git push --force origin main", cwd: repo },
    });
    equal(legC, undefined,
      "55c: force push over diverged origin/main ALLOWED — 2-dot range = content55.ts (A-row, verified from leg a) + remote55.ts (D-row, ENOENT-skipped); wip55.ts is in NEITHER tree; never a forever-block on the deleted row");
  });

  test("scenario 56 (#487): content-shape exemption on the RANGE set — mixed committed range blocks; docs-only committed range exempt — RED pre-fix", async () => {
    // Fixture 1: MIXED committed range (code + docs, both raw-committed and
    // never verified, NOTHING staged) — never exempt: the exemption at the
    // hook is whole-set only; the block names every unverified range file.
    const repo = join(TEST_ROOT, "repo-487-56a");
    mkdirSync(repo, { recursive: true });
    git(repo, "init -b main");
    git(repo, "config user.email e2e@test");
    git(repo, "config user.name e2e");
    writeFileSync(join(repo, "base56.txt"), "b\n");
    git(repo, "add base56.txt");
    git(repo, "commit -m base");
    const baseSha = git(repo, "rev-parse HEAD");
    writeFileSync(join(repo, "code56.ts"), "c56\n");
    git(repo, "add code56.ts");
    git(repo, "commit -m c56 -- code56.ts"); // raw commit — never verified
    writeFileSync(join(repo, "README56.md"), "# docs\n");
    git(repo, "add README56.md");
    git(repo, "commit -m d56 -- README56.md"); // raw commit — never verified
    git(repo, `update-ref refs/remotes/origin/main ${baseSha}`); // ancestor
    await fire("session_start", {});
    const exemptBefore = readAuditLines().filter((l) => l.event === "gate_skip" && l.reason === "content_shape_exempt").length;
    const resA = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "git push origin main", cwd: repo },
    });
    ok(resA && resA.block === true,
       "56a: MIXED committed range must block (never exempt on a mixed set); RED pre-fix: empty staged index silently allows");
    ok(resA.reason.includes("code56.ts") && resA.reason.includes("README56.md"),
       "56a: block names BOTH unverified range files (mirror scenario 40's both-named asserts — the exemption is whole-set only)");
    equal(readAuditLines().filter((l) => l.event === "gate_skip" && l.reason === "content_shape_exempt").length, exemptBefore,
          "56a: mixed range must NOT add a content_shape_exempt skip");
    // Fixture 2: docs-ONLY committed range — the exemption fires on the RANGE
    // set (isBareCommitShape vacuous for pushes; scenario 47 pins only the
    // STAGED-set exemption — this closes the range-set gap).
    const repoB = join(TEST_ROOT, "repo-487-56b");
    mkdirSync(repoB, { recursive: true });
    git(repoB, "init -b main");
    git(repoB, "config user.email e2e@test");
    git(repoB, "config user.name e2e");
    writeFileSync(join(repoB, "baseB.txt"), "b\n");
    git(repoB, "add baseB.txt");
    git(repoB, "commit -m base");
    const baseShaB = git(repoB, "rev-parse HEAD");
    writeFileSync(join(repoB, "docs56.md"), "# docs-only\n");
    git(repoB, "add docs56.md");
    git(repoB, "commit -m d56b -- docs56.md"); // raw commit — never verified
    git(repoB, `update-ref refs/remotes/origin/main ${baseShaB}`);
    await fire("session_start", {});
    const exemptBeforeB = readAuditLines().filter((l) => l.event === "gate_skip" && l.reason === "content_shape_exempt").length;
    const resB = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "git push origin main", cwd: repoB },
    });
    equal(resB, undefined, "56b: docs-only committed range push ALLOWED (content-shape exemption on the RANGE set)");
    ok(readAuditLines().filter((l) => l.event === "gate_skip" && l.reason === "content_shape_exempt").length > exemptBeforeB,
       "56b: audit records content_shape_exempt for the range-scoped docs push (RED pre-fix: silent empty-index allow records nothing)");
  });

  test("scenario 57 (#487 review P1 regression pin): hostile git-state ref names fail closed with NO shell side-effect", async () => {
    // Code-review cycle-1 P1: execSync runs /bin/sh -c and the resolver
    // interpolates git-state-derived values (checked-out branch name, config
    // branch.<cur>.remote VALUE) — git refnames legally allow shell metachars
    // (`;`, `|`, `$`), so without the PUSH_REFNAME/PUSH_REMOTE_NAME guards a
    // hostile branch/config executed arbitrary shell on the first bare push.
    // Guards present → null → tier C staged. Behavioral pin: STAGED block (not
    // allow) + NO marker file — a regression that deletes or reorders either
    // guard ships green on the block assert but reds the marker assert.
    const repo = join(TEST_ROOT, "repo-487-57");
    mkdirSync(repo, { recursive: true });
    git(repo, "init -b main");
    git(repo, "config user.email e2e@test");
    git(repo, "config user.name e2e");
    writeFileSync(join(repo, "base57.txt"), "b\n");
    git(repo, "add base57.txt");
    git(repo, "commit -m base");
    // Vector (a): hostile CHECKED-OUT BRANCH name (metachars are legal git
    // refnames — created via plumbing with quoting so the fixture's own shell
    // never expands them). Guard-less, the branch name is first interpolated
    // into the CONFIG KEY `branch.<current>.remote` — the template's `.remote`
    // suffix completes the payload's touch target to exactly `pwned57a.remote`
    // (`git config --get branch.x` fails, then `touch pwned57a.remote` runs).
    const markerA = join(repo, "pwned57a.remote");
    rmSync(markerA, { force: true });
    const hostileBranch = "x;touch${IFS}pwned57a";
    git(repo, `update-ref 'refs/heads/${hostileBranch}' HEAD`);
    git(repo, `symbolic-ref HEAD 'refs/heads/${hostileBranch}'`);
    writeFileSync(join(repo, "wip57.ts"), "w\n");
    git(repo, "add wip57.ts"); // parked WIP — staged scope is the fail-closed fallback
    await fire("session_start", {});
    const resA = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "git push --force-with-lease", cwd: repo },
    });
    ok(resA && resA.block === true, "57a: bare push on a metachar branch must fall back to the staged check (guard → null → tier C)");
    ok(resA.reason.includes("wip57.ts"), "57a: block names the parked WIP (staged scope)");
    equal(existsSync(markerA), false,
      "57a: NO shell side-effect — the hostile branch name never reached an execSync string (guard fires before interpolation; guard-less, the config-key sink lands pwned57a.remote)");
    // Vector (b): hostile config VALUE branch.<cur>.remote (with the merge
    // config present so a guard-less resolver would reach the refs/remotes/…
    // probe). Guard-less, the value is interpolated into
    // `refs/remotes/${remote}/${dst}` — the template appends `/main`, so the
    // payload's touch target is the FILE pwned57b/main (the dir must pre-exist
    // or the guard-less touch fails and the marker can never exist).
    git(repo, "symbolic-ref HEAD refs/heads/main");
    const markerBDir = join(repo, "pwned57b");
    mkdirSync(markerBDir, { recursive: true }); // fixture pre-creates the landing DIR so the guard-less touch succeeds
    const markerB = join(markerBDir, "main");
    rmSync(markerB, { force: true });
    git(repo, "reset -q"); // drop wip57 from the index (block-state isolation)
    writeFileSync(join(repo, "wip57b.ts"), "w\n");
    git(repo, "add wip57b.ts");
    git(repo, "config branch.main.remote 'origin;touch${IFS}pwned57b'");
    git(repo, "config branch.main.merge refs/heads/main");
    await fire("session_start", {});
    const resB = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "git push --force-with-lease", cwd: repo },
    });
    ok(resB && resB.block === true, "57b: bare push with a hostile config remote must fall back to the staged check (guard → null → tier C)");
    ok(resB.reason.includes("wip57b.ts"), "57b: block names the parked WIP");
    equal(existsSync(markerB), false,
      "57b: NO shell side-effect — the hostile config VALUE never reached an execSync string (guard-less, the refs/remotes/… probe lands pwned57b/main)");
    git(repo, "config --unset branch.main.merge");
    git(repo, "config --unset branch.main.remote");
  });

  test("scenario 58 (#487 second-model gate): non-origin remote — resolver picks the upstream/main tier-B base, not origin/main", async () => {
    const repo = join(TEST_ROOT, "repo-487-58");
    mkdirSync(repo, { recursive: true });
    git(repo, "init -b main");
    git(repo, "config user.email e2e@test");
    git(repo, "config user.name e2e");
    writeFileSync(join(repo, "base58.txt"), "b\n");
    git(repo, "add base58.txt");
    git(repo, "commit -m base");
    const baseSha = git(repo, "rev-parse HEAD");
    // NON-origin upstream tracking ref present; deliberately NO refs/remotes/origin/*
    // at all — a resolver regression that always falls back to origin/main gets
    // a missing base → tier C → staged block (RED), so the allow below proves
    // the non-origin branch of the base-preference code fired.
    git(repo, `update-ref refs/remotes/upstream/main ${baseSha}`);
    git(repo, "checkout -b feat"); // feat == upstream/main
    writeFileSync(join(repo, "content58.ts"), "c58\n");
    git(repo, "add content58.ts");
    await fire("session_start", {});
    await fire("tool_result", {
      toolName: "task",
      input: { prompt: `[VGATE] verify files: content58.ts. Classification: backend. Project root: ${repo}` },
      content: [{ type: "text", text: JSON.stringify({
        status: "PASS", failures: [],
        verified_files: [{ path: join(repo, "content58.ts"), hash: sha("c58\n") }],
      }) }],
    });
    const allowCommit = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "git commit -m c58", cwd: repo },
    });
    equal(allowCommit, undefined, "58: content58.ts commit ALLOWED after the PASS");
    git(repo, "commit -m c58");
    writeFileSync(join(repo, "wip58.ts"), "w\n");
    git(repo, "add wip58.ts"); // parked WIP
    await fire("session_start", {});
    const push = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "git push -u upstream feat", cwd: repo },
    });
    equal(push, undefined,
      "58: non-origin first push ALLOWED post-fix (tier B vs the upstream/main base the resolver must prefer; range [content58.ts]); an origin/main-fallback regression nulls the base → tier C staged block → RED");
    const originMain = join(repo, ".git/refs/remotes/origin/main");
    equal(existsSync(originMain), false, "58: fixture purity — no origin refs were created");
  });

  test("scenario 59 (#487 second-model gate): multi-refspec union names BOTH ranges; an unresolvable refspec nulls the WHOLE command to staged", async () => {
    const repo = join(TEST_ROOT, "repo-487-59");
    mkdirSync(repo, { recursive: true });
    git(repo, "init -b main");
    git(repo, "config user.email e2e@test");
    git(repo, "config user.name e2e");
    writeFileSync(join(repo, "base59.txt"), "b\n");
    git(repo, "add base59.txt");
    git(repo, "commit -m base");
    const baseSha = git(repo, "rev-parse HEAD");
    git(repo, `update-ref refs/remotes/origin/main ${baseSha}`);
    writeFileSync(join(repo, "content59m.ts"), "c59m\n");
    git(repo, "add content59m.ts");
    git(repo, "commit -m c59m"); // raw commits — the gate's commit path is not this scenario's target
    git(repo, "checkout -b feat");
    writeFileSync(join(repo, "content59f.ts"), "c59f\n");
    git(repo, "add content59f.ts");
    git(repo, "commit -m c59f");
    writeFileSync(join(repo, "wip59.ts"), "w\n");
    git(repo, "add wip59.ts"); // parked WIP
    await fire("session_start", {});
    const block = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "git push origin main feat", cwd: repo },
    });
    ok(block && block.block === true, "59: unverified multi-refspec push BLOCKS");
    ok(block.reason.includes("content59m.ts") && block.reason.includes("content59f.ts"),
      "59: the block names BOTH refspec ranges (union of tier-A origin/main...main and tier-B origin/main...feat) — NOT the staged wip (a staged-scope regression would name wip59.ts only)");
    equal(block.reason.includes("wip59.ts"), false, "59: the parked WIP is out of scope for a pure range union");
    // Verify both range files → the same command must now ALLOW.
    await fire("tool_result", {
      toolName: "task",
      input: { prompt: `[VGATE] verify files: content59m.ts content59f.ts. Classification: backend. Project root: ${repo}` },
      content: [{ type: "text", text: JSON.stringify({
        status: "PASS", failures: [],
        verified_files: [
          { path: join(repo, "content59m.ts"), hash: sha("c59m\n") },
          { path: join(repo, "content59f.ts"), hash: sha("c59f\n") },
        ],
      }) }],
    });
    await fire("session_start", {});
    const allow = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "git push origin main feat", cwd: repo },
    });
    equal(allow, undefined, "59: multi-refspec push ALLOWED once BOTH ranges are verified (wip still parked — a tier-C regression would block)");
    // ANY tier-C refspec nulls the WHOLE command → staged scope. `nonexist` has
    // no local ref, so its refspec is unresolvable → null cascades: the command
    // must NOT get the tier-A [content59m] allow (content59m is already verified).
    writeFileSync(join(repo, "wip59b.ts"), "w\n");
    git(repo, "add wip59b.ts");
    await fire("session_start", {});
    const block2 = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "git push origin main nonexist", cwd: repo },
    });
    ok(block2 && block2.block === true, "59b: an unresolvable refspec nulls the whole command → BLOCK");
    ok(block2.reason.includes("wip59b.ts"),
      "59b: the block names the STAGED file (whole-command tier-C null; a per-refspec-union regression would allow via the verified content59m range)");
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
