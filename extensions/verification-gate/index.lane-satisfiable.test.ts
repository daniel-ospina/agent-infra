/**
 * index.lane-satisfiable.test.ts — the gates must be SATISFIABLE by an honest lane (#1460, #540).
 *
 * WHY THIS FILE EXISTS. Measured on a `pi -p` lane (2026-10-22), three refusals that no
 * honest action could clear:
 *
 *   [verification-gate] 🚫 Blocked: 0 unverified, 3 mismatched   ← a verifier that ran `md5sum`
 *   [verification-gate] 🚫 Blocked: 1 unverified, 0 mismatched   ← (converging; covered below)
 *   [verification-gate] 🚫 Blocked — in-batch mutation chain     ← right verdict, no split form
 *
 * The md5 case is the unsatisfiable one: `hashMatchesDisk` accepted only sha1/sha256 and
 * compared every other length AS sha256, so a 32-hex digest could NEVER match. Re-verifying
 * did not help — the same verifier keeps producing md5 — and the printed remedy asked an LLM
 * to hand-transcribe a 64-hex digest, which is how the class reproduces itself.
 *
 * WHAT THIS FILE PINS
 *   (a) edit + re-verify + commit PASSES, for a sha256, a sha1, an md5, and a digest-free PASS.
 *   (b) a digest that does NOT match the bytes still BLOCKS (the protection), and a value that
 *       is not a digest at all still blocks (fail closed — never "compared as sha256").
 *   (c) an edit AFTER the verdict still blocks until the bytes are re-verified (protection).
 *   (d) the in-batch mutation chain still REFUSES, and its text names the exact two commands;
 *       running them as two separate tool_calls is accepted.
 *
 * MUTATIONS (each was RUN against this file; each reddens the test named beside it):
 *   M1 delete `DIGEST_ALGO_BY_HEX_LENGTH`'s md5 entry       → (a) md5 case + the digest unit test
 *   M2 make `storedDigestFor` return `supplied` verbatim    → (a) md5's "stored as the gate's
 *                                                              sha256" assertion
 *   M3 delete the in-batch refusal                          → (d) refusal + split-form tests
 *   M4 make the split non-byte-faithful (append a space)    → the split unit test (pipe/redirect)
 *   M5 make bridge recovery store the supplied digest        → the bridge-recovery test (the commit's
 *      verbatim instead of the gate's sha256                    pendingRehash would mask it, so that
 *                                                              test observes the bridge WITHOUT one)
 *   M6 un-widen the heredoc detector (`<<\EOF`)            → the split unit test
 *   M7 drop the `$'…'` ANSI-C state                          → the split unit test
 *
 * NOT mutation-pinned, and stated rather than implied: bridge recovery now answers "matched?" and
 * "what to store?" from ONE read (`matchAndStoredDigest`, shared with the merge path) instead of
 * `hashMatchesDisk` then `storedDigestFor`. That closes a RACE WINDOW — a writer landing between
 * the two reads — which no test can observe deterministically, so a green run says nothing about
 * it. It failed closed before and it fails closed now; what changed is that the invariant
 * `storedDigestFor`'s comment claims is a property of the code rather than of one call site.
 *
 * Hermetic: HOME is redirected to a temp dir before the plugin is imported (the bridge and
 * audit log are HOME-derived), and every repo is a throwaway temp checkout.
 *
 * Run: npx tsx extensions/verification-gate/index.lane-satisfiable.test.ts
 */

import { ok, equal } from "node:assert/strict";
import { execSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync, readFileSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const TEST_ROOT = mkdtempSync(join(tmpdir(), "vgate-lane-"));
process.env.HOME = TEST_ROOT;
const TEST_GITCONFIG = join(TEST_ROOT, ".gitconfig");
writeFileSync(TEST_GITCONFIG, "[user]\n\tname = vgate-lane\n\temail = lane@test\n");
process.env.GIT_CONFIG_GLOBAL = TEST_GITCONFIG;
process.env.GIT_CONFIG_SYSTEM = "/dev/null";
for (const k of [
  "GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL", "GIT_COMMITTER_NAME", "GIT_COMMITTER_EMAIL",
  "EMAIL", "GIT_AUTHOR_DATE", "GIT_COMMITTER_DATE",
]) delete process.env[k];
delete process.env.ELDATO_SKIP_VGATE;
delete process.env.PI_MODE;
delete process.env.TASK_HEARTBEAT;

const sha256 = (t: string) => createHash("sha256").update(t).digest("hex");
const sha1 = (t: string) => createHash("sha1").update(t).digest("hex");
const md5 = (t: string) => createHash("md5").update(t).digest("hex");
const git = (repo: string, args: string) =>
  execSync(`git ${args}`, { cwd: repo, encoding: "utf-8", timeout: 20000 }).trim();

// ── fake pi ExtensionAPI + fire ──────────────────────
type Handler = (event: any, ctx: any) => any;
const handlers = new Map<string, Handler[]>();
const fakePi: any = {
  on(evt: string, h: Handler) {
    if (!handlers.has(evt)) handlers.set(evt, []);
    handlers.get(evt)!.push(h);
  },
};
async function fire(evt: string, event: any, ctx: any = {}): Promise<any> {
  let result: any = undefined;
  for (const h of handlers.get(evt) ?? []) {
    const r = await h(event, ctx);
    if (r !== undefined) result = r;
  }
  return result;
}
const commitOp = () => ({ type: "tool_call", toolName: "bash", input: { command: "git commit -m wip" } });

/** A `task` tool_result carrying a [VGATE] verdict (the in-band dispatch a pi -p lane can make). */
function vgateResult(projectRoot: string, promptFiles: string, body: unknown) {
  return {
    type: "tool_result",
    toolName: "task",
    isError: false,
    input: { prompt: `[VGATE] verify files: ${promptFiles}. Classification: backend. Project root: ${projectRoot}.` },
    content: [{ type: "text", text: typeof body === "string" ? body : JSON.stringify(body) }],
  };
}
const hashResult = (root: string, path: string, hash: string) =>
  vgateResult(root, path, { status: "PASS", failures: [], verified_files: [{ path, hash }] });

let passed = 0;
let failed = 0;
const pending: { name: string; fn: () => Promise<void> }[] = [];
function test(name: string, fn: () => Promise<void>) {
  pending.push({ name, fn });
}

/** A fresh repo with `a.txt` committed at "a1\n", session started, cwd set to it. */
async function freshRepo(label: string): Promise<string> {
  const repo = join(TEST_ROOT, label);
  mkdirSync(repo, { recursive: true });
  git(repo, "init -b main");
  writeFileSync(join(repo, "a.txt"), "a1\n");
  git(repo, "add a.txt");
  git(repo, "commit -m baseline");
  process.chdir(repo);
  await fire("session_start", {});
  return repo;
}

test("(a) edit + re-verify + commit PASSES — sha256 digest", async () => {
  const repo = await freshRepo("a-sha256");
  writeFileSync(join(repo, "a.txt"), "a2\n");
  git(repo, "add a.txt");
  const blocked = await fire("tool_call", commitOp());
  ok(blocked?.block === true, "pre-state: an unverified staged edit is refused");

  await fire("tool_result", hashResult(repo, "a.txt", sha256("a2\n")));
  const retry = await fire("tool_call", commitOp());
  equal(retry, undefined, "a fresh PASS carrying sha256 of the current bytes must allow the commit");
});

test("(a) edit + re-verify + commit PASSES — sha1 digest", async () => {
  const repo = await freshRepo("a-sha1");
  writeFileSync(join(repo, "a.txt"), "a2\n");
  git(repo, "add a.txt");
  ok((await fire("tool_call", commitOp()))?.block === true, "pre-state: the edit is refused before any PASS");
  await fire("tool_result", hashResult(repo, "a.txt", sha1("a2\n")));
  equal(await fire("tool_call", commitOp()), undefined, "sha1 is accepted as the record's digest (#320)");
});

// ⛔ #1460 — THE UNSATISFIABLE CASE. Before the fix this was a BLOCK, twice in a row:
// `hashMatchesDisk` read length 32 as "not 40 → sha256", so it could never match, and a
// re-verify produced the same 32-hex value again. This is the (b) half of "0 mismatched"
// measured on the lane, and the reason it could not be cleared.
test("(a) edit + re-verify + commit PASSES — md5 digest (a verifier that ran md5sum)", async () => {
  const repo = await freshRepo("a-md5");
  writeFileSync(join(repo, "a.txt"), "a2\n");
  git(repo, "add a.txt");
  await fire("tool_result", hashResult(repo, "a.txt", md5("a2\n")));
  // The record must be upgraded to the GATE's sha256 of the matched bytes: a collision-broken
  // md5 must never be the standing identity a later check trusts (M2 mutation target).
  const bridge = JSON.parse(readFileSync(join(TEST_ROOT, ".pi", "agent", "verification", "latest.json"), "utf8"));
  const entry = (bridge.verified_files as { path: string; hash: string }[]).find((e) => e.path === `${realpathSync(repo)}::a.txt`);
  ok(entry !== undefined, "the PASS was recorded for a.txt");
  equal(entry!.hash, sha256("a2\n"), "a matched md5 is stored as the gate's sha256, never as the md5");
  equal(
    await fire("tool_call", commitOp()),
    undefined,
    "md5 OF THE CURRENT BYTES is evidence — refusing it makes the gate unsatisfiable (#1460)",
  );
});

test("(a) edit + re-verify + commit PASSES — digest-free PASS (the converging remedy)", async () => {
  const repo = await freshRepo("a-nohash");
  writeFileSync(join(repo, "a.txt"), "a2\n");
  git(repo, "add a.txt");
  await fire("tool_result", vgateResult(repo, "a.txt", { status: "PASS", failures: [], verified_files: [] }));
  equal(
    await fire("tool_call", commitOp()),
    undefined,
    "a PASS with no per-file hashes records the bytes on disk at merge time (#336) — the remedy the refusal names",
  );
});

test("(b) PROTECTION: a digest that does NOT match the bytes still blocks", async () => {
  const repo = await freshRepo("b-stale");
  writeFileSync(join(repo, "a.txt"), "a2\n");
  git(repo, "add a.txt");
  // The verifier read the OLD bytes: a genuine disagreement, not a transcription artefact.
  await fire("tool_result", hashResult(repo, "a.txt", sha256("a1\n")));
  const res = await fire("tool_call", commitOp());
  ok(res?.block === true, "a recorded digest that disagrees with disk must block");
  ok(/Hash mismatch/.test(String(res.reason)), `reason names the mismatch class: ${String(res.reason).slice(0, 120)}`);
  // And the refusal must name the SATISFIABLE route (#1460) — a lane that re-verifies the
  // current bytes (or returns a digest-free PASS) clears it; a hand-typed digest is not required.
  ok(/verified_files: \[\]/.test(String(res.reason)), "the refusal names the digest-free remedy");
});

test("(b) PROTECTION: a value that is not a digest at all fails CLOSED", async () => {
  const repo = await freshRepo("b-notdigest");
  writeFileSync(join(repo, "a.txt"), "a2\n");
  git(repo, "add a.txt");
  await fire("tool_result", hashResult(repo, "a.txt", "deadbeef"));
  const res = await fire("tool_call", commitOp());
  ok(res?.block === true, "an unparseable digest must never authorize a commit");
});

test("(c) PROTECTION: a digest upgrade never blesses different bytes", async () => {
  // md5 of OTHER content must not be accepted just because the algorithm is now supported.
  const repo = await freshRepo("c-upgrade");
  writeFileSync(join(repo, "a.txt"), "a2\n");
  git(repo, "add a.txt");
  await fire("tool_result", hashResult(repo, "a.txt", md5("a1\n")));
  const res = await fire("tool_call", commitOp());
  ok(res?.block === true, "md5 of the PRE-edit bytes is a disagreement and must still block");
});

test("(c) PROTECTION: an edit AFTER the verdict blocks until re-verified", async () => {
  const repo = await freshRepo("c-postedit");
  writeFileSync(join(repo, "a.txt"), "a2\n");
  git(repo, "add a.txt");
  await fire("tool_result", hashResult(repo, "a.txt", sha256("a2\n")));
  // The lane edits again before committing: the verdict is now about bytes that no longer exist.
  writeFileSync(join(repo, "a.txt"), "a3\n");
  const res = await fire("tool_call", commitOp());
  ok(res?.block === true, "bytes edited after the PASS are not covered by it");
  // Re-verify the CURRENT bytes → satisfiable.
  await fire("tool_result", hashResult(repo, "a.txt", sha256("a3\n")));
  equal(await fire("tool_call", commitOp()), undefined, "re-verifying the current bytes clears it");
});

test("(c) PROTECTION: a partial PASS leaves the un-named file blocked, and re-verify converges", async () => {
  const repo = await freshRepo("c-partial");
  writeFileSync(join(repo, "a.txt"), "a2\n");
  writeFileSync(join(repo, "b.txt"), "b2\n");
  git(repo, "add a.txt b.txt");
  await fire("tool_result", hashResult(repo, "a.txt", sha256("a2\n")));
  const res = await fire("tool_call", commitOp());
  ok(res?.block === true, "a PASS naming only a.txt must not bless b.txt");
  ok(/b\.txt/.test(String(res.reason)), "the refusal names the unverified file");
  await fire("tool_result", hashResult(repo, "b.txt", sha256("b2\n")));
  equal(await fire("tool_call", commitOp()), undefined, "naming the missing file converges (one extra cycle, not a loop)");
});

// ── (d) the in-batch mutation chain — RIGHT verdict, unsatisfiable TEXT ──
const CHAINED = "printf 'x\\n' > a.txt && git add a.txt && git commit -m x";

test("(d) PROTECTION: the in-batch mutation chain is still REFUSED", async () => {
  const repo = await freshRepo("d-chain");
  const res = await fire("tool_call", { type: "tool_call", toolName: "bash", input: { command: CHAINED } });
  ok(res?.block === true, "a command that mutates and commits in one tool_call must still be refused");
  ok(/in-batch mutation chain/.test(String(res.reason)), "the refusal names the class");
});

test("(d) the refusal names the EXACT two commands, and the split form is ACCEPTED", async () => {
  const repo = await freshRepo("d-split");
  const res = await fire("tool_call", { type: "tool_call", toolName: "bash", input: { command: CHAINED } });
  const reason = String(res?.reason ?? "");
  ok(/TWO separate bash tool_calls/.test(reason), "the refusal tells the lane the shape to use");
  ok(/1\) printf 'x\\n' > a\.txt && git add a\.txt/.test(reason), `command 1 is the mutation arm — got:\n${reason}`);
  ok(/2\) git commit -m x/.test(reason), `command 2 is the commit arm — got:\n${reason}`);

  // Now run them as two separate tool_calls, exactly as printed.
  equal(
    await fire("tool_call", { type: "tool_call", toolName: "bash", input: { command: "printf 'x\\n' > a.txt && git add a.txt" } }),
    undefined,
    "the mutation alone is not gated (it commits nothing)",
  );
  // The hook gates; the shell is ours to run — execute command 1 exactly as printed.
  execSync("printf 'x\\n' > a.txt && git add a.txt", { cwd: repo, shell: "/bin/bash", timeout: 20000 });
  const commit = await fire("tool_call", commitOp());
  ok(commit?.block === true, "the pure commit is then gated on the REAL state, not silently allowed");
  await fire("tool_result", hashResult(repo, "a.txt", sha256("x\n")));
  equal(await fire("tool_call", commitOp()), undefined, "verified → the split form lands");
});

test("(a) bridge recovery re-installs the gate's sha256, not the verifier's md5 (#1460)", async () => {
  const repo = await freshRepo("a-recovery");
  const bridgeDir = join(TEST_ROOT, ".pi", "agent", "verification");
  mkdirSync(bridgeDir, { recursive: true });
  // Hand-written bridge entry: exactly what a verifier's md5 PASS would have persisted.
  writeFileSync(join(bridgeDir, "latest.json"), JSON.stringify({
    status: "PASS",
    verified_files: [{ path: `${realpathSync(repo)}::a.txt`, hash: md5("a1\n") }],
    timestamp: new Date().toISOString(),
  }));
  // Recovery runs on session_start AND before every git op; a blocked op still recovers first.
  await fire("session_shutdown", {});
  await fire("session_start", {});
  // Make the recovered registry OBSERVABLE without a commit (a commit's pendingRehash would
  // re-hash from disk and mask what recovery stored): a PASS for a second, staged file writes
  // the bridge from the whole registry.
  writeFileSync(join(repo, "b.txt"), "b1\n");
  git(repo, "add b.txt");
  await fire("tool_result", hashResult(repo, "b.txt", sha256("b1\n")));
  const bridge = JSON.parse(readFileSync(join(bridgeDir, "latest.json"), "utf8"));
  const entry = (bridge.verified_files as { path: string; hash: string }[]).find((e) => e.path === `${realpathSync(repo)}::a.txt`);
  ok(entry !== undefined, "the recovered entry is still in the registry (recovery did not drop it)");
  equal(entry!.hash, sha256("a1\n"), "recovery stored the gate's sha256 of the matched bytes, not the verifier's md5");
});

// ── direct unit pins (no plugin) ─────────────────────
test("unit: digestAlgoForRecord classifies md5/sha1/sha256 and rejects everything else", async () => {
  const mod = await import("./index.js");
  equal(mod.digestAlgoForRecord(md5("x")), "md5");
  equal(mod.digestAlgoForRecord(sha1("x")), "sha1");
  equal(mod.digestAlgoForRecord(sha256("x")), "sha256");
  equal(mod.digestAlgoForRecord(sha256("x").toUpperCase()), "sha256", "case-insensitive");
  equal(mod.digestAlgoForRecord("deadbeef"), null, "not a digest → fail closed");
  equal(mod.digestAlgoForRecord(""), null);
  // Length alone is not a digest (fresh review, P2): 32 non-hex chars are NOT an md5.
  equal(mod.digestAlgoForRecord("z".repeat(32)), null, "32 non-hex characters are not a digest");
  equal(mod.digestAlgoForRecord("g".repeat(64)), null, "64 non-hex characters are not a digest");
});

test("unit: splitMutationFromCommit splits at the commit arm, and is null without one", async () => {
  const mod = await import("./index.js");
  const split = mod.splitMutationFromCommit(CHAINED);
  equal(split?.mutation, "printf 'x\\n' > a.txt && git add a.txt");
  equal(split?.commit, "git commit -m x");
  equal(mod.splitMutationFromCommit("git commit -m x"), null, "no mutation arm → nothing to split");
  equal(mod.splitMutationFromCommit("git add a.txt"), null, "no commit arm → not this class");

  // ⛔ The split must be the ORIGINAL text sliced, never the segments rejoined (fresh review, P1).
  const piped = "echo hi | tee a.txt && git commit -m x";
  const pipedSplit = mod.splitMutationFromCommit(piped);
  equal(pipedSplit?.mutation, "echo hi | tee a.txt", "a PIPE must survive the split (rejoining dropped it)");
  equal(pipedSplit?.commit, "git commit -m x");

  const redirect = 'echo "x" > f.ts && git add f.ts && git commit -m y';
  const redirectSplit = mod.splitMutationFromCommit(redirect);
  equal(redirectSplit?.mutation, 'echo "x" > f.ts && git add f.ts', "the redirect survives verbatim");
  equal(redirectSplit?.commit, "git commit -m y");

  // Unfaithful shapes get NO printed split — a bad remedy is worse than the generic sentence.
  equal(mod.splitMutationFromCommit("git add a && (cd sub && git commit -m x)"), null,
    "a subshell puts the commit INSIDE a construct — slicing would print invalid bash");
  equal(mod.splitMutationFromCommit("bash -c 'git add a && git commit -m x'"), null,
    "an executing wrapper would re-classify as the same in-batch chain — a looping remedy");
  equal(mod.splitMutationFromCommit("git add a && echo $(date) && git commit -m x"), null,
    "a command substitution is not slice-safe");
  equal(mod.splitMutationFromCommit("cat <<'EOT' > f.md\nbody\nEOT\ngit add f.md && git commit -m x"), null,
    "a heredoc is not slice-safe");

  // ⛔ A CANDIDATE INSIDE A QUOTE IS A MENTION, NOT AN INVOCATION (fresh review round 5, P1).
  // `findGitVerbInvocation` scans a bare `\bgit\b`, so `git commit` INSIDE a quoted string was
  // taken as the commit arm and the cut landed mid-quote — printing `1) printf '` / `2) git commit
  // -m x\n' > msg.txt && …`, whose first arm bash cannot parse. Writing a file whose CONTENT
  // mentions `git commit` is an ordinary lane shape, so the cut must also be at a command START.
  equal(mod.splitMutationFromCommit("printf 'git commit -m x\\n' > msg.txt && git add msg.txt && git commit -F msg.txt"),
    null, "a quoted MENTION of `git commit` must not become the cut point (it printed unparseable bash)");
  equal(mod.splitMutationFromCommit('echo "run git commit now" > note.md && git add note.md && git commit -m x'),
    null, "the same for a double-quoted mention");
  const afterQuote = mod.splitMutationFromCommit("git add a.txt && git commit -m 'a && b'");
  equal(afterQuote?.mutation, "git add a.txt", "control: a quote AFTER the cut point does not disturb the split");
  equal(afterQuote?.commit, "git commit -m 'a && b'", "control: the commit arm keeps its quoted argument verbatim");

  // ⛔ `$'…'` IS ANSI-C QUOTING — `\'` is ESCAPED there (fresh review round 6, P2). The scan closed
  // the single-quote state at `\'`, believed it was outside a quote, and cut inside a MENTION:
  // arm 1 = `printf $'x\'` (bash: "unexpected EOF while looking for matching '"), arm 2 = the rest
  // of the quoted string plus the real commit. A remedy that cannot run is worse than none.
  equal(
    mod.splitMutationFromCommit(String.raw`printf $'x\' && git commit -m y' > m.txt && git add m.txt && git commit -F m.txt`),
    null,
    "ANSI-C quoting hides the invocation the same way a plain quote does"
  );
  // Control: `$'…'` CLOSED before the commit arm is not a mention, so the split still stands.
  const afterAnsiC = mod.splitMutationFromCommit(String.raw`printf $'a\'b' > m.txt && git add m.txt && git commit -F m.txt`);
  equal(afterAnsiC?.mutation, String.raw`printf $'a\'b' > m.txt && git add m.txt`,
    "control: ANSI-C quoting BEFORE the cut point is preserved and does not close the split");

  // ⛔ `<<\EOF` IS A HEREDOC (fresh review round 6, P2). `['"]?\w` did not match the standard
  // no-expansion spelling, so a body line containing `git commit` was cut as if it were a command:
  // arm 1 truncated the heredoc and arm 2 started with the rest of the BODY, i.e. the printed
  // remedy committed the wrong message.
  equal(mod.splitMutationFromCommit("cat <<\\EOF > m.txt\nx &&\ngit commit -m y\nEOF\ngit commit -F m.txt"),
    null, "a backslash-quoted heredoc delimiter is still a heredoc");
});

// ── runner ────────────────────────────────────────────
async function main() {
  const mod = await import("./index.js");
  ((mod as any).default as (pi: any) => void)(fakePi);
  console.log(`\n#1460/#540 — lane-satisfiable verification gate (${pending.length} tests)`);
  for (const { name, fn } of pending) {
    try {
      await fn();
      passed++;
      console.log(`  ✅ ${name}`);
    } catch (err: any) {
      failed++;
      console.log(`  ❌ ${name}: ${err.message}`);
    }
  }
  console.log(`\n=== Final: ${passed} passed, ${failed} failed ===`);
  rmSync(TEST_ROOT, { recursive: true, force: true });
  if (failed > 0) process.exit(1);
  else console.log("✅ ALL LANE-SATISFIABLE TESTS PASSED");
}

main().catch((err) => {
  console.error("❌ HARNESS ERROR:", err);
  process.exit(1);
});
