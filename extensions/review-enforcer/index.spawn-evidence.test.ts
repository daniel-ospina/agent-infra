/**
 * index.spawn-evidence.test.ts — a SPAWNED reviewer process satisfies the ≥1-dispatch floor,
 * and NOTHING ELSE does (#2287/#2148).
 *
 * THE WALL THIS REMOVES. The floor counted one thing: an in-session `task`/`subagent`
 * `tool_result`. A `pi -p` lane that obtained its review the documented way — spawn
 * `scripts/review-pr.sh`, which runs a real `pi -p` reviewer, posts the findings as the
 * evidence comment and records the verdict through `record-review.sh` — was refused at its
 * NEXT git op with `🚫 Blocked — no reviewers dispatched` even though a reviewer had run and
 * its verdict was on the record (measured on gate-events.jsonl: 9 such blocks in one
 * evening). The floor was satisfiable exactly one way; the way lanes are told to land was
 * not it.
 *
 * WHAT IS ACCEPTED — a MECHANICAL artifact, never prose: a `record-review.sh` registry
 * record (`~/.pi/agent/reviews/<owner>-<repo>-<pr>.json`) whose `head_sha` is the EXACT head
 * this git op ships. That is the same file the merge registry gate already consumes as the
 * attestation, so this adds no new trust boundary; it makes ONE gate's evidence usable by
 * the other.
 *
 * WHAT IS STILL REFUSED (each pinned below):
 *   • no record at all                        → block + the durable `no_reviewers_dispatch` row
 *   • a record bound to an OLDER head         → block (a review of other bytes is not this op)
 *   • a record belonging to ANOTHER repo      → block (the #426 collision class)
 *   • two records for one head, no repo ctx   → block (ambiguous is not evidence)
 *
 * MUTATIONS (each was RUN against this file; each reddens the test named beside it):
 *   M1 delete the `headBoundReviewEvidence` acceptance block  → §ALLOW
 *   M2 drop the `head_sha` comparison (accept any record)     → §OLD-HEAD (+ 3 siblings)
 *   M3 drop the `repo` filter                                 → §FOREIGN (+ §ALLOW, via ambiguity)
 *   M4 drop the side-branch check in `resolveShippedHeads`     → §side-branch + the unit shape test
 *   M5 drop BOTH repo-null layers (the resolver guard and the  → §REFUSE-no-repo. Either layer
 *      #426 parity line)                                        alone is sufficient, so neither
 *                                                               single deletion reddens — which is
 *                                                               why the pair is pinned together.
 *
 * Hermetic: HOME is a temp dir (the reviews registry and the audit log are HOME-derived),
 * the repo is a throwaway checkout with a fake `origin` URL, and no `gh`/network call is made.
 *
 * Run: NODE_ENV=test npx tsx extensions/review-enforcer/index.spawn-evidence.test.ts
 */

import { ok, equal } from "node:assert/strict";
import { execSync } from "node:child_process";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync, existsSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const TEST_ROOT = mkdtempSync(join(tmpdir(), "review-spawn-"));
process.env.HOME = TEST_ROOT;
const TEST_GITCONFIG = join(TEST_ROOT, ".gitconfig");
writeFileSync(TEST_GITCONFIG, "[user]\n\tname = review-spawn\n\temail = spawn@test\n");
process.env.GIT_CONFIG_GLOBAL = TEST_GITCONFIG;
process.env.GIT_CONFIG_SYSTEM = "/dev/null";
for (const k of [
  "GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL", "GIT_COMMITTER_NAME", "GIT_COMMITTER_EMAIL",
  "EMAIL", "GH_REPO", "AGENT_SKIP_REVIEW_GATE", "ELDATO_SKIP_REVIEW_GATE",
]) delete process.env[k];
delete process.env.PI_MODE;
delete process.env.TASK_HEARTBEAT;

const REPO = "daniel-ospina/agent-infra";
const git = (args: string) => execSync(`git ${args}`, { cwd: repoDir(), encoding: "utf-8", timeout: 20000 }).trim();
const repoDir = () => join(TEST_ROOT, "repo");
const reviewsDir = () => join(TEST_ROOT, ".pi", "agent", "reviews");
const auditFile = () => join(TEST_ROOT, ".pi", "agent", "audit", "gate-events.jsonl");

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

/** The push this suite gates. `ctx.cwd` is the op's checkout, exactly as a real tool_call passes it. */
const pushOp = () => ({ type: "tool_call", toolName: "bash", input: { command: "git push origin main" } });

function writeRecord(file: string, rec: Record<string, unknown>) {
  mkdirSync(reviewsDir(), { recursive: true });
  writeFileSync(join(reviewsDir(), file), JSON.stringify(rec));
}
function auditRows(): Record<string, any>[] {
  if (!existsSync(auditFile())) return [];
  return readFileSync(auditFile(), "utf8").trim().split("\n").filter(Boolean).map((l) => JSON.parse(l));
}
const evidenceRows = () => auditRows().filter((r) => r.reason === "review_record_bound_head");
const blockRows = () => auditRows().filter((r) => r.event === "gate_block" && r.reason === "no_reviewers_dispatch");

let passed = 0;
let failed = 0;
const pending: { name: string; fn: () => Promise<void> }[] = [];
function test(name: string, fn: () => Promise<void>) {
  pending.push({ name, fn });
}

async function main() {
  // A throwaway checkout whose origin resolves to a GitHub repo (no network touched).
  mkdirSync(repoDir(), { recursive: true });
  git("init -b main");
  git(`remote add origin https://github.com/${REPO}.git`);
  writeFileSync(join(repoDir(), "f.txt"), "v1\n");
  git("add f.txt");
  git("commit -m baseline");

  const mod: any = await import("./index.js");
  mod.default(fakePi);
  await fire("session_start", {}, { cwd: repoDir() });
  const head = git("rev-parse HEAD");
  ok(/^[0-9a-f]{40}$/.test(head), `pre-state: a real HEAD to bind to (${head})`);

  test("§REFUSE — no reviewer ran: the floor still blocks and writes the durable block row", async () => {
    const before = blockRows().length;
    const res = await fire("tool_call", pushOp(), { cwd: repoDir() });
    ok(res?.block === true, "a push with no dispatch and no review record must be REFUSED");
    ok(/No reviewers were dispatched/.test(String(res.reason)), "the reason names the missing dispatch");
    equal(evidenceRows().length, 0, "no evidence row may be written when no reviewer evidence exists");
    ok(blockRows().length === before + 1, "the refusal is durably recorded (gate_block / no_reviewers_dispatch)");
  });

  test("§REFUSE — a record bound to an OLDER head is not evidence for this op", async () => {
    writeRecord(`${REPO.replace("/", "-")}-41.json`, {
      pr: 41, head_sha: "0123456789abcdef0123456789abcdef01234567", verdict: "clean", repo: REPO,
    });
    const res = await fire("tool_call", pushOp(), { cwd: repoDir() });
    ok(res?.block === true, "a review of DIFFERENT bytes must not authorize this push");
    equal(evidenceRows().length, 0, "a stale head writes no evidence row");
  });

  test("§REFUSE — a record belonging to ANOTHER repo is inert (#426)", async () => {
    writeRecord("someone-else-repo-42.json", { pr: 42, head_sha: head, verdict: "clean", repo: "someone/else-repo" });
    const res = await fire("tool_call", pushOp(), { cwd: repoDir() });
    ok(res?.block === true, "a foreign repo's record must never satisfy this repo's floor");
    equal(evidenceRows().length, 0, "a foreign record writes no evidence row");
  });

  test("§ALLOW — a spawned reviewer's record bound to THIS head satisfies the floor", async () => {
    // Exactly what `record-review.sh` writes after a spawned `pi -p` reviewer returned clean.
    writeRecord(`${REPO.replace("/", "-")}-77.json`, {
      pr: 77, head_sha: head, verdict: "clean", repo: REPO, reviewed_at: new Date().toISOString(),
    });
    const res = await fire("tool_call", pushOp(), { cwd: repoDir() });
    equal(res, undefined, "a head-bound review record from a reviewer PROCESS must allow the push");
    const rows = evidenceRows();
    equal(rows.length, 1, "the acceptance is recorded as ONE evidence row (the audit stays honest)");
    equal(rows[0].pr, 77);
    equal(rows[0].head_sha, head);
    ok(typeof rows[0].record === "string" && rows[0].record.includes("77.json"), "the row names the record it read");
  });

  // ⛔ #2287 fresh-review P0: HEAD is NOT the shipped object in these shapes. Each of them
  // authorized a git op from a record describing other bytes before this was fixed.
  test("§REFUSE — `git push origin <side branch>` is not covered by a record at HEAD", async () => {
    // A record at HEAD exists (minted by §ALLOW). The pushed BRANCH is a different commit.
    execSync("git checkout -q -b side", { cwd: repoDir(), encoding: "utf8" });
    writeFileSync(join(repoDir(), "side.txt"), "s1\n");
    git("add side.txt");
    git("commit -m side");
    execSync("git checkout -q main", { cwd: repoDir(), encoding: "utf8" });
    const res = await fire("tool_call", { type: "tool_call", toolName: "bash", input: { command: "git push origin side" } }, { cwd: repoDir() });
    ok(res?.block === true, "the record describes main's HEAD, not `side` — this push must refuse");
  });

  test("§REFUSE — `git commit` is never covered: its bytes do not exist yet", async () => {
    writeFileSync(join(repoDir(), "f.txt"), "v2\n");
    git("add f.txt");
    const res = await fire("tool_call", { type: "tool_call", toolName: "bash", input: { command: "git commit -m wip" } }, { cwd: repoDir() });
    ok(res?.block === true, "a review of HEAD cannot authorize committing NEW bytes");
  });

  // ⛔ `git -C <other> push` is OUTSIDE the enforcer's interception surface altogether: `isGitOp`
  // treats a repo-redirecting global as a foreign checkout and does not gate it (the same declared
  // boundary VGATE documents — findGitVerbInvocation's `foreignRedirect: "skip"`). So the evidence
  // path can never be reached for it, which is what this pins; the unit case below pins
  // resolveShippedHeads' own refusal, so a future widening of isGitOp cannot silently open it.
  test("§boundary — a `-C` redirect is not gated at all, and yields no evidence even if it were", async () => {
    const res = await fire("tool_call", { type: "tool_call", toolName: "bash", input: { command: `git -C ${repoDir()} push origin main` } }, { cwd: repoDir() });
    equal(res, undefined, "declared boundary: a foreign-redirect git op is not intercepted (pre-existing, unchanged here)");
    equal(mod.resolveShippedHeads(`git -C ${repoDir()} push origin main`, { cwd: repoDir() }), null,
      "and the evidence resolver refuses it on its own — widening isGitOp later cannot open this path");
  });

  test("§REFUSE — with NO repo resolvable, a repo-naming record is not evidence", async () => {
    const local = join(TEST_ROOT, "local-remote-repo");
    mkdirSync(local, { recursive: true });
    execSync("git init -q -b main", { cwd: local, encoding: "utf8" });
    writeFileSync(join(local, "g.txt"), "g1\n");
    execSync("git add g.txt", { cwd: local, encoding: "utf8" });
    execSync("git commit -q -m base", { cwd: local, encoding: "utf8" });
    execSync("git remote add origin /tmp/local-mirror.git", { cwd: local, encoding: "utf8" }); // not GitHub → repo unresolvable
    const localHead = execSync("git rev-parse HEAD", { cwd: local, encoding: "utf8" }).trim();
    writeRecord("daniel-ospina-agent-infra-501.json", { pr: 501, head_sha: localHead, verdict: "clean", repo: REPO });
    const res = await fire("tool_call", pushOp(), { cwd: local });
    ok(res?.block === true, "an unresolvable repo cannot bind any record — the floor stands (#426 P0-2 parity)");
  });

  test("§unit — resolveShippedHeads: only HEAD-shipping shapes open the evidence path", async () => {
    const okPush = mod.resolveShippedHeads("git push origin main", { cwd: repoDir() });
    ok(okPush !== null && okPush.heads.length === 1 && okPush.heads[0] === head, "a plain push of the current branch ships HEAD");
    equal(mod.resolveShippedHeads("git commit -m x", { cwd: repoDir() }), null, "a commit ships bytes that do not exist yet");
    equal(mod.resolveShippedHeads("git push origin some-other-branch", { cwd: repoDir() }), null, "another branch is not HEAD");
    equal(mod.resolveShippedHeads("git push origin main:refs/heads/x", { cwd: repoDir() }), null, "an explicit refspec is not HEAD");
    equal(mod.resolveShippedHeads("git push --all", { cwd: repoDir() }), null, "--all ships many refs");
    equal(mod.resolveShippedHeads("git push --mirror", { cwd: repoDir() }), null, "--mirror ships everything");
    equal(mod.resolveShippedHeads(`git -C ${repoDir()} push origin main`, { cwd: repoDir() }), null, "-C is unattributable");
    equal(mod.resolveShippedHeads("gh pr create --head other-branch", { cwd: repoDir() }), null, "--head names another branch");
  });

  test("§unit — headBoundReviewEvidence: exact head, repo-scoped, ambiguity is not evidence", async () => {
    const evidence = mod.headBoundReviewEvidence(head, REPO);
    ok(evidence !== null, "a qualifying record is found");
    equal(evidence.head_sha, head);
    equal(mod.headBoundReviewEvidence(head, "other/repo"), null, "repo mismatch → inert");
    equal(mod.headBoundReviewEvidence("ffffffffffffffffffffffffffffffffffffffff", REPO), null, "unknown head → null");
    equal(mod.headBoundReviewEvidence("not-a-sha", REPO), null, "garbage head → null (fail closed)");
    // With NO repo context, a record that NAMES a repo can never be bound (#426 P0-2 parity) —
    // from this PR's fresh review, this was the fail-open: one foreign record used to match.
    writeRecord("a-b-91.json", { pr: 91, head_sha: head, verdict: "clean", repo: "a/b" });
    equal(mod.headBoundReviewEvidence(head, null), null, "a repo-naming record is inert without repo context");
    // Two repo-LESS legacy records at one head are ambiguous → not evidence.
    writeRecord("81.json", { pr: 81, head_sha: head, verdict: "clean" });
    writeRecord("82.json", { pr: 82, head_sha: head, verdict: "clean" });
    equal(mod.headBoundReviewEvidence(head, null), null, "two candidates without repo context → not evidence");
  });

  test("§unit — resolveShippedHeads reads the op's checkout, never the process cwd", async () => {
    const op = mod.resolveShippedHeads("git push origin main", { cwd: repoDir() });
    ok(op !== null, "the HEAD is resolvable from the op cwd");
    equal(op.heads[0], head);
    equal(op.repo, REPO, "the repo comes from the checkout's own origin");
    // A cwd that is not a git checkout yields null → the floor stands (no fail-open).
    const nowhere = join(TEST_ROOT, "not-a-repo");
    mkdirSync(nowhere, { recursive: true });
    equal(mod.resolveShippedHeads("git push origin main", { cwd: nowhere }), null);
  });

  console.log(`\n#2287/#2148 — spawned-reviewer evidence for the dispatch floor (${pending.length} tests)`);
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
  else console.log("✅ ALL SPAWN-EVIDENCE TESTS PASSED");
}

main().catch((err) => {
  console.error("❌ HARNESS ERROR:", err);
  process.exit(1);
});
