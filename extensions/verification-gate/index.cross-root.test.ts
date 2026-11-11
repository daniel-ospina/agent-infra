/**
 * index.cross-root.test.ts — a record made for the SAME path under a SIBLING worktree root (#2886).
 *
 * WHY THIS FILE EXISTS. Records are keyed on (worktree root + relative path). A rebase re-creates the
 * branch in a NEW worktree, so every record made for it becomes unusable AT ONCE and the next push/commit
 * is refused with "no verification record for this root" against a population nobody touched — measured
 * on a DMeer release branch (daniel-ospina/DMeer#1371): 5 changed files, ~150 demanded, and the only
 * remedies offered were a mass rubber-stamp (verifying files nobody read) or `ELDATO_SKIP_VGATE=1`.
 *
 * The fix this file pins: verification is a judgment about CONTENT — the record IS a digest — so a record
 * for the same relative path under a DIFFERENT root of the SAME repository satisfies the op exactly when
 * its stored digest still matches the bytes at the op's root. Nothing is re-blessed from disk: a digest
 * that does not match is a no-op, and the borrow is audited (`gate_skip`, reason
 * `foreign_root_blob_identical`).
 *
 * WHAT THIS FILE PINS
 *   (a) a record under a sibling worktree root of the same repo, at the CURRENT bytes, allows the op
 *       (in-session record, and a record that exists only in the durable registry from a prior session);
 *   (b) PROTECTION: different bytes under the sibling root still BLOCK (and the block still diagnoses the
 *       root mismatch);
 *   (c) PROTECTION: identical bytes in a DIFFERENT repository are never borrowed (no shared
 *       `--git-common-dir`), and a record whose root no longer exists is never borrowed;
 *   (d) `ELDATO_VGATE_NO_SUBTRACT=1` restores the pre-fix behaviour (the scope-widening escape);
 *   (e) the issue's own shape: N files identical to a verified sibling + 1 genuinely new file ⇒ the block
 *       names ONLY the new file, not the N.
 *
 * MUTATIONS (each was RUN against this file; each reddens the test named beside it):
 *   M1 drop the same-repo (`--git-common-dir`) guard        → (c) "identical bytes in a different
 *                                                              repository are never borrowed" + (c) dead
 *                                                              root + (b) + (d) redden
 *   M2 drop the `matchAndStoredDigest` match (accept any     → (b) "different bytes under the sibling root
 *      foreign record for the path)                             still BLOCK" reddens, and so does (b)
 *                                                              "a sibling root's record for DIFFERENT
 *                                                              bytes" — that leg exists precisely so a
 *                                                              re-blessing mutant is observable
 *   M3 drop the durable-registry read (verifiedSet only)     → (a) "a record only in the durable registry
 *                                                              (a prior session)" reddens — and ONLY
 *                                                              because that leg carries two recorded
 *                                                              sibling roots (see its note)
 *   M4 ignore `subDisabled`                                  → (d) reddens
 *   M5 drop the relative-path equality (match any path)      → (c) "a record for a DIFFERENT path" and
 *                                                              (e) redden
 *
 * Hermetic: HOME is redirected to a temp dir before the plugin is imported (the bridge and the audit log
 * are HOME-derived), and every repo is a throwaway temp checkout.
 *
 * Run: npx tsx extensions/verification-gate/index.cross-root.test.ts
 */

import { ok, equal } from "node:assert/strict";
import { execSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdtempSync, mkdirSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const TEST_ROOT = mkdtempSync(join(tmpdir(), "vgate-cross-root-"));
process.env.HOME = TEST_ROOT;
const TEST_GITCONFIG = join(TEST_ROOT, ".gitconfig");
writeFileSync(TEST_GITCONFIG, "[user]\n\tname = vgate-xroot\n\temail = xroot@test\n");
process.env.GIT_CONFIG_GLOBAL = TEST_GITCONFIG;
process.env.GIT_CONFIG_SYSTEM = "/dev/null";
for (const k of [
  "GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL", "GIT_COMMITTER_NAME", "GIT_COMMITTER_EMAIL",
  "EMAIL", "GIT_AUTHOR_DATE", "GIT_COMMITTER_DATE",
]) delete process.env[k];
delete process.env.ELDATO_SKIP_VGATE;
delete process.env.ELDATO_VGATE_NO_SUBTRACT;
delete process.env.PI_MODE;
delete process.env.TASK_HEARTBEAT;

const sha256 = (t: string) => createHash("sha256").update(t).digest("hex");
const git = (repo: string, args: string) =>
  execSync(`git ${args}`, { cwd: repo, encoding: "utf-8", timeout: 20000 }).trim();

// ── fake pi ExtensionAPI ─────────────────────────────
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

/** A `task` tool_result carrying a [VGATE] verdict recorded against `projectRoot`. */
function vgateResult(projectRoot: string, promptFiles: string, files: { path: string; hash: string }[]) {
  return {
    type: "tool_result",
    toolName: "task",
    isError: false,
    input: { prompt: `[VGATE] verify files: ${promptFiles}. Classification: backend. Project root: ${projectRoot}.` },
    content: [{ type: "text", text: JSON.stringify({ status: "PASS", failures: [], verified_files: files }) }],
  };
}

const auditPath = () => join(TEST_ROOT, ".pi", "agent", "audit", "gate-events.jsonl");
function readAuditLines(): Record<string, any>[] {
  if (!existsSync(auditPath())) return [];
  return readFileSync(auditPath(), "utf8").trim().split("\n").filter(Boolean).map((l) => JSON.parse(l));
}
const borrowRows = () =>
  readAuditLines().filter((l) => l.event === "gate_skip" && l.reason === "foreign_root_blob_identical");

const bridgePath = () => join(TEST_ROOT, ".pi", "agent", "verification", "latest.json");
/** Add entries to the shared registry as a PRIOR session would have (never clobbers existing ones). */
function addRegistryEntries(entries: { path: string; hash: string }[]): void {
  let existing: { path: string; hash: string }[] = [];
  if (existsSync(bridgePath())) {
    try {
      const parsed = JSON.parse(readFileSync(bridgePath(), "utf8"));
      if (Array.isArray(parsed?.verified_files)) existing = parsed.verified_files;
    } catch { /* corrupt — start from the new entries */ }
  }
  mkdirSync(join(TEST_ROOT, ".pi", "agent", "verification"), { recursive: true });
  writeFileSync(
    bridgePath(),
    JSON.stringify({
      status: "PASS",
      verified_files: [...existing.filter((e) => !entries.some((n) => n.path === e.path)), ...entries],
      timestamp: new Date().toISOString(),
    })
  );
}

let passed = 0;
let failed = 0;
const pending: { name: string; fn: () => Promise<void> }[] = [];
function test(name: string, fn: () => Promise<void>) {
  pending.push({ name, fn });
}

/** A hub repo carrying `src/shared.ts` = "s1\n", plus a linked worktree of it on its own branch. */
function hubWithWorktree(label: string): { hub: string; wt: string } {
  const hub = join(TEST_ROOT, label);
  mkdirSync(join(hub, "src"), { recursive: true });
  git(hub, "init -b main");
  writeFileSync(join(hub, "src", "shared.ts"), "s1\n");
  git(hub, "add src/shared.ts");
  git(hub, "commit -m base");
  const wt = join(hub, ".worktrees", "wt");
  git(hub, `worktree add -q ${wt} -b feat`);
  return { hub, wt };
}

/** Block on `rel` at the hub root, then record a PASS via the gate's own merge path. */
async function recordInHub(hub: string, files: { rel: string; bytes: string }[]): Promise<void> {
  process.chdir(hub);
  await fire("session_start", {});
  for (const f of files) {
    mkdirSync(join(hub, f.rel, ".."), { recursive: true });
    writeFileSync(join(hub, f.rel), f.bytes);
    git(hub, `add ${f.rel}`);
  }
  const blocked = await fire("tool_call", commitOp());
  ok(blocked?.block === true, `pre-state: ${files.map((f) => f.rel).join(",")} is unverified in the hub`);
  await fire(
    "tool_result",
    vgateResult(hub, files.map((f) => f.rel).join(" "), files.map((f) => ({ path: f.rel, hash: sha256(f.bytes) })))
  );
}

// ── (a) THE HEADLINE: a rebased branch's unchanged bytes, re-rooted into a new worktree ──
test("(a) a record under a SIBLING worktree root of the same repo, at the current bytes, ALLOWS the op", async () => {
  const { hub, wt } = hubWithWorktree("a-sibling");
  await recordInHub(hub, [{ rel: "src/shared.ts", bytes: "s2\n" }]);
  const before = borrowRows().length;

  // The rebase metaphor: the same bytes now live in a NEW root, where no record exists.
  process.chdir(wt);
  await fire("session_start", {});
  writeFileSync(join(wt, "src/shared.ts"), "s2\n");
  git(wt, "add src/shared.ts");
  const retry = await fire("tool_call", commitOp());

  equal(retry, undefined, "the sibling root's record for the SAME path at the SAME bytes must satisfy this op (#2886)");
  const rows = borrowRows();
  equal(rows.length, before + 1, "the borrow must be audited (gate_skip / foreign_root_blob_identical)");
  const row = rows[rows.length - 1];
  ok((row.files as string[]).includes("src/shared.ts"), "the audit row names the path it satisfied");
  ok((row.from_roots as string[]).includes(realpathSync(hub)), "the audit row names the root it borrowed from");
});

test("(a) a record only in the DURABLE registry (a prior session) is still borrowed", async () => {
  // ⛔ This leg must NOT be satisfiable from memory: `session_start` merges a same-repo sibling's
  // entries into `verifiedSet` for INSPECTION when EXACTLY ONE sibling has them (#1265), and the
  // borrow would then read them from there — a version of this test that left that door open stayed
  // GREEN under the "no durable-registry read" mutant (measured). So the repo carries TWO recorded
  // sibling roots: `pickVerifiedRoot` returns null on ambiguity, the inspection merge never runs, and
  // the only place the record can come from is the bridge itself.
  const { hub, wt } = hubWithWorktree("a-durable");
  const wtTwo = join(hub, ".worktrees", "wt-two");
  git(hub, `worktree add -q ${wtTwo} -b feat-two`);
  mkdirSync(join(wtTwo, "src"), { recursive: true });
  writeFileSync(join(wtTwo, "src", "other.ts"), "o\n");

  writeFileSync(join(hub, "src/shared.ts"), "s3\n");
  addRegistryEntries([
    { path: `${realpathSync(hub)}::src/shared.ts`, hash: sha256("s3\n") },
    { path: `${realpathSync(wtTwo)}::src/other.ts`, hash: sha256("o\n") },
  ]);

  process.chdir(wt);
  await fire("session_start", {});
  writeFileSync(join(wt, "src/shared.ts"), "s3\n");
  git(wt, "add src/shared.ts");
  equal(
    await fire("tool_call", commitOp()),
    undefined,
    "a prior session's registry record must be readable at the new root (the rebase-in-a-fresh-worktree case)"
  );
});

// ── (b) PROTECTION: the bytes must match ──
test("(b) different bytes under the sibling root still BLOCK, and the block still diagnoses the root mismatch", async () => {
  const { hub, wt } = hubWithWorktree("b-different");
  await recordInHub(hub, [{ rel: "src/shared.ts", bytes: "s2\n" }]);

  process.chdir(wt);
  await fire("session_start", {});
  writeFileSync(join(wt, "src/shared.ts"), "s9\n"); // the record is for s2 — never borrowed
  git(wt, "add src/shared.ts");
  const blocked = await fire("tool_call", commitOp());
  ok(blocked?.block === true, "a record for DIFFERENT bytes must not authorize this one");
  ok(/src\/shared\.ts/.test(blocked.reason), "the block names the file");
  ok(/ROOT MISMATCH/.test(blocked.reason), "the block still explains that the record lives under another root");
});

test("(b) an edited-after-verification file at the SAME root still blocks (no re-blessing from disk)", async () => {
  const repo = join(TEST_ROOT, "b-edit-same-root");
  mkdirSync(repo, { recursive: true });
  git(repo, "init -b main");
  writeFileSync(join(repo, "a.txt"), "a1\n");
  git(repo, "add a.txt");
  git(repo, "commit -m base");
  process.chdir(repo);
  await fire("session_start", {});
  writeFileSync(join(repo, "a.txt"), "a2\n");
  git(repo, "add a.txt");
  ok((await fire("tool_call", commitOp()))?.block === true, "pre-state: unverified");
  await fire("tool_result", vgateResult(repo, "a.txt", [{ path: "a.txt", hash: sha256("a2\n") }]));
  writeFileSync(join(repo, "a.txt"), "a3\n"); // edit AFTER the verdict
  git(repo, "add a.txt");
  const blocked = await fire("tool_call", commitOp());
  ok(blocked?.block === true, "an edit after the PASS must still block (content-addressing never re-blesses disk)");
});

// ⛔ The leg above pins #1460's own `hashMatchesDisk` branch, and has NO sibling root at all — so
// `foreignBlobMatch` never has a candidate and the row is green under EVERY mutant of the added
// lines (fresh-context review round 3, finding 2: it read as coverage of "the borrow never
// re-blesses disk" while proving nothing about the borrow). This leg is the discriminating half: a
// same-repo sibling root DOES hold a record for the same path, at DIFFERENT bytes, and the op root
// has no record of its own. A re-blessing mutant (accepting a candidate without the digest test,
// `index.ts:5064`) allows the op and reddens here; the correct code fails the match and blocks.
test("(b) a sibling root's record for DIFFERENT bytes never re-blesses this op's content", async () => {
  const { hub, wt } = hubWithWorktree("b-foreign-stale-bytes");
  // The sibling's record describes src/shared.ts at s1 (the committed bytes it was verified at).
  addRegistryEntries([{ path: `${realpathSync(hub)}::src/shared.ts`, hash: sha256("s1\n") }]);
  process.chdir(wt);
  await fire("session_start", {});
  writeFileSync(join(wt, "src/shared.ts"), "s9\n"); // neither root has a record for THESE bytes
  git(wt, "add src/shared.ts");
  const before = borrowRows().length;
  const blocked = await fire("tool_call", commitOp());
  ok(blocked?.block === true, "a sibling record for other bytes must not authorize this content");
  equal(borrowRows().length, before, "no borrow may be audited when no candidate's digest matches");
});

// ── (c) PROTECTION: same bytes are not enough — the RANGE of what is borrowed is narrow ──
function bareRepo(label: string): string {
  const repo = join(TEST_ROOT, label);
  mkdirSync(repo, { recursive: true });
  git(repo, "init -b main");
  return repo;
}

test("(c) identical bytes in a DIFFERENT repository are never borrowed", async () => {
  const other = bareRepo("c-other-repo");
  writeFileSync(join(other, "src-shared.ts"), "s2\n");
  git(other, "add src-shared.ts");
  git(other, "commit -m base");
  mkdirSync(join(other, "src"), { recursive: true });
  writeFileSync(join(other, "src", "shared.ts"), "s2\n");
  addRegistryEntries([{ path: `${realpathSync(other)}::src/shared.ts`, hash: sha256("s2\n") }]);

  const { wt } = hubWithWorktree("c-foreign-repo");
  process.chdir(wt);
  await fire("session_start", {});
  writeFileSync(join(wt, "src/shared.ts"), "s2\n");
  git(wt, "add src/shared.ts");
  const blocked = await fire("tool_call", commitOp());
  ok(
    blocked?.block === true,
    "another repository's record attests nothing about this tree — no shared --git-common-dir ⇒ no borrow (#3255's predicate)"
  );
});

test("(c) a record for a DIFFERENT path with identical bytes is never borrowed", async () => {
  const { hub, wt } = hubWithWorktree("c-other-path");
  // A record for src/other.ts exists at the hub — same bytes as the wt's src/shared.ts, different path.
  addRegistryEntries([{ path: `${realpathSync(hub)}::src/other.ts`, hash: sha256("s2\n") }]);
  process.chdir(wt);
  await fire("session_start", {});
  writeFileSync(join(wt, "src/shared.ts"), "s2\n");
  git(wt, "add src/shared.ts");
  const blocked = await fire("tool_call", commitOp());
  ok(blocked?.block === true, "the record must describe the SAME relative path — a content match alone is not a verdict about this file");
});

test("(c) a record whose root no longer exists is never borrowed", async () => {
  const { wt } = hubWithWorktree("c-dead-root");
  const deadRoot = join(TEST_ROOT, "c-dead-root-gone");
  addRegistryEntries([{ path: `${deadRoot}::src/shared.ts`, hash: sha256("s2\n") }]);
  process.chdir(wt);
  await fire("session_start", {});
  writeFileSync(join(wt, "src/shared.ts"), "s2\n");
  git(wt, "add src/shared.ts");
  const blocked = await fire("tool_call", commitOp());
  ok(blocked?.block === true, "an unprovable (gone) root is skipped — fail closed");
});

// ── (d) the scope-widening escape covers this narrowing too ──
test("(d) ELDATO_VGATE_NO_SUBTRACT=1 restores the pre-fix behaviour", async () => {
  const { hub, wt } = hubWithWorktree("d-killswitch");
  await recordInHub(hub, [{ rel: "src/shared.ts", bytes: "s2\n" }]);
  process.chdir(wt);
  await fire("session_start", {});
  writeFileSync(join(wt, "src/shared.ts"), "s2\n");
  git(wt, "add src/shared.ts");
  process.env.ELDATO_VGATE_NO_SUBTRACT = "1";
  try {
    const blocked = await fire("tool_call", commitOp());
    ok(blocked?.block === true, "the documented scope-WIDENING escape must cover every narrowing the gate makes");
  } finally {
    delete process.env.ELDATO_VGATE_NO_SUBTRACT;
  }
  // …and with the escape off the same op is allowed, so the assertion above is about the escape alone.
  equal(await fire("tool_call", commitOp()), undefined, "with the escape off the borrow applies again");
});

// ── (e) THE ISSUE'S OWN SHAPE: 150 demanded, 5 changed ──
// ── (f) the index must keep EVERY candidate, and a non-matching one must not shadow a later match ──
// #2886 review round 4, finding 1 replaced the per-file registry SCAN with a per-op INDEX. That is a
// rewrite of the candidate lookup, and the failure it can silently introduce is a candidate LOST by the
// index (a dedupe-by-root, or an early-return on the first candidate) — which would look exactly like
// "no record under any root" and re-open the loop this change closes. So: the same path is recorded
// under an unrelated repo first (bytes that do NOT match) and under a same-repo sibling second (bytes
// that do), in that order, and the op must still be ALLOWED by the second.
test("(f) a non-matching candidate under one root does not shadow a matching one under another", async () => {
  const { hub, wt } = hubWithWorktree("f-candidate-order");
  const unrelated = bareRepo("f-candidate-order-other");
  writeFileSync(join(unrelated, "src-shared.ts"), "zzz\n");
  git(unrelated, "add src-shared.ts");
  git(unrelated, "commit -m base");
  // Order matters: the unrelated root's record comes FIRST in the registry.
  addRegistryEntries([
    { path: `${realpathSync(unrelated)}::src/shared.ts`, hash: sha256("zzz\n") },
    { path: `${realpathSync(hub)}::src/shared.ts`, hash: sha256("s2\n") },
  ]);
  process.chdir(wt);
  await fire("session_start", {});
  writeFileSync(join(wt, "src/shared.ts"), "s2\n");
  git(wt, "add src/shared.ts");
  equal(
    await fire("tool_call", commitOp()),
    undefined,
    "the index must keep every candidate: a non-matching root's record must not shadow the same-repo one"
  );
});

test("(e) N files identical to a verified sibling root + 1 genuinely new file ⇒ the block names ONLY the new file", async () => {
  const { hub, wt } = hubWithWorktree("e-issue-shape");
  const same = [
    { rel: "src/a.ts", bytes: "a\n" },
    { rel: "src/b.ts", bytes: "b\n" },
    { rel: "src/c.ts", bytes: "c\n" },
  ];
  await recordInHub(hub, same);
  process.chdir(wt);
  await fire("session_start", {});
  for (const f of same) {
    writeFileSync(join(wt, f.rel), f.bytes);
    git(wt, `add ${f.rel}`);
  }
  writeFileSync(join(wt, "src/d.ts"), "d-new\n");
  git(wt, "add src/d.ts");

  const blocked = await fire("tool_call", commitOp());
  ok(blocked?.block === true, "the genuinely new bytes must still be verified — the op blocks");
  const unverifiedNames = blocked.reason.split("\n").filter((l: string) => /^ {4}- /.test(l)).map((l: string) => l.trim());
  ok(unverifiedNames.includes("- src/d.ts"), "the block names the new file");
  for (const f of same) {
    ok(
      !unverifiedNames.includes(`- ${f.rel}`),
      `the block must NOT demand re-verification of untouched bytes: ${f.rel} (pre-fix: the whole list)`
    );
  }
});

// ── runner ────────────────────────────────────────────
(async () => {
  const mod = await import("./index.js");
  mod.default(fakePi);
  for (const t of pending) {
    try {
      await t.fn();
      passed++;
      console.log(`  ✅ ${t.name}`);
    } catch (e) {
      failed++;
      console.error(`  ❌ ${t.name}`);
      console.error(`     ${(e as Error).message}`);
    }
  }
  console.log(`\n${passed} passed, ${failed} failed`);
  if (failed > 0) process.exit(1);
})();
