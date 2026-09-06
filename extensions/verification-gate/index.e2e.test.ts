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
    `${label} — exempt op must leave the deterministic D1 sentinel bridge byte-identical (allow-only: no verifiedSet/bridge writes)`);
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
    // proves the docs exemption committed README.md ONLY and left the dirty UNSTAGED
    // src/app.ts untouched (D2: -a sweeps and bundles never ride the docs exemption).
    git(repo, "commit -m x"); // execute the allowed docs commit for real
    // Raw porcelain read — the git() helper trims, which would eat the leading column
    // space of the two-column status (" M " = worktree-modified, not "M " staged); the
    // exact-porcelain pin needs the RAW bytes: exactly one line, no staged entries, no
    // untracked files.
    const porcelain = execSync("git status --porcelain", { cwd: repo, encoding: "utf-8", timeout: 20000 });
    equal(porcelain, " M src/app.ts\n",
       "real bare docs commit must commit README.md only — raw porcelain exactly ' M src/app.ts' (dirty unstaged src/app.ts untouched; D2: -a sweeps and bundles never ride the docs exemption)");
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
