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
 * ⛔ AND ONLY FOR A COMMAND WITH NO SHELL SYNTAX. Four review rounds proved that modelling the
 * shell by pattern enumeration cannot be completed (quotes, escapes, substitutions, aliases,
 * `pushd`, attached short-flag values, `fetch -u` — each was a live accept). The path is open
 * only for the op AT THE COMMAND POSITION — `git push origin <this-branch>`, `git push origin HEAD`
 * (HEAD is exactly the commit the record is bound to), or a plain `gh pr create` with no head
 * override — only when the push's remote is the one the repo slug is read from (`origin`), and only
 * with NO FLAGS (`-f`, `-d`, `-u`, `-o …` all fall back: a flag changes what the op DOES without
 * moving a positional, and round 5's filter-the-flags-away parse accepted `git push origin main -d`,
 * i.e. a remote-branch DELETE authorized by a record of HEAD). Anything containing
 * `'"`\$(){}<>|&;`, a backslash, a newline, or a pathname-expansion character (`*?[]~!`) falls back
 * to the ordinary ≥1-dispatch floor: an expansion means the TOKENS ARE NOT THE ARGV, which is the
 * only premise a positional read has. A lane that wants the record path runs the push as its own
 * command.
 *
 * WHAT IS STILL REFUSED (each pinned below):
 *   • no record at all                        → block + the durable `no_reviewers_dispatch` row
 *   • a record bound to an OLDER head         → block (a review of other bytes is not this op)
 *   • a record belonging to ANOTHER repo      → block (the #426 collision class)
 *   • two records for one head, no repo ctx   → block (ambiguous is not evidence)
 *
 * MUTATIONS. Each was RUN against this file. The target named is the test that ACTUALLY reddened;
 * rows marked NOT PINNED are recorded because a green run does NOT prove the guard is exercised,
 * which is the class of false claim an earlier revision shipped:
 *   M1 delete the `headBoundReviewEvidence` acceptance block  → §ALLOW
 *   M2 drop the `head_sha` comparison (accept any record)     → §OLD-HEAD (+ 3 siblings)
 *   M3 drop the `repo` filter                                 → §FOREIGN (+ §ALLOW, via ambiguity)
 *   M4 drop the side-branch check in `resolveShippedHeads`     → §side-branch + the unit shape test
 *   M5 drop BOTH repo-null layers (the resolver guard and the  → §REFUSE-no-repo. Either layer
 *      #426 parity line)                                        alone is sufficient, so neither
 *                                                               single deletion reddens — which is
 *                                                               why the pair is pinned together.
 *   M6 drop the `-H`/`--head` refusal                          → §REFUSE--H AND §REFUSE--Hattached
 *                                                                (verified: TWO reds. An earlier
 *                                                                revision listed this same mutation
 *                                                                twice, as M6 and M12)
 *   M7 drop the ref-moving-verb guard                          → NOT PINNED for its `&&` fixtures:
 *                                                                `evidenceCommandIsPlain` closes them
 *                                                                first. Verified: 21 passed / 1
 *                                                                failed, and the red is §unit —
 *                                                                gitVerbs, NOT §REFUSE-ref-moving.
 *                                                                An earlier revision claimed the
 *                                                                latter; that was false.
 *   M8 drop `words.length !== 2` (accept extra positionals)      → §REFUSE-extra-refspec
 *   M9 treat `-c <k>=<v>` as an ordinary global                  → NOT PINNED, and now
 *                                                                UNREACHABLE: a plain command has no
 *                                                                room for a `-c` global before
 *                                                                `push`, so the command-position
 *                                                                ANCHOR refuses `git -c … push`
 *                                                                first. Verified: deleting the guard
 *                                                                changes nothing (25/25 green). Kept
 *                                                                as defence in depth, not as a pin.
 *   M10 do not consume a global option's VALUE in `gitVerbs`      → §unit — gitVerbs (ALONE)
 *   M11 allow shell syntax (`evidenceCommandIsPlain` removed)      → §REFUSE-shell-syntax (+ the
 *                                                                  chained-fetch control)
 *   M12 anchor `isPush`/`isPrCreate` back to free text             → §REFUSE-command-position
 *   M13 drop the `words[0] !== ORIGIN_REMOTE` binding              → §REFUSE-non-origin-remote
 *   M14 refuse `HEAD` again (`words[1] !== branch` only)           → §ALLOW — git push origin HEAD
 *   M15 drop the push-flag refusal (back to FILTERING `-` tokens) → §REFUSE-push-flag. This is the
 *                                                                  round-5 shape: filtering kept the
 *                                                                  positionals intact, so `git push
 *                                                                  origin main -d` (== --delete)
 *                                                                  DELETED the remote branch from a
 *                                                                  record bound to HEAD.
 *   M16 remove `[*?[\]~!]` from `evidenceCommandIsPlain`            → §REFUSE-pathname-expansion
 *                                                                  (`git push origin main -*`; with a
 *                                                                  file named `--tags` in the cwd bash
 *                                                                  expands the flag slot to it and the
 *                                                                  push ships every tag)
 *
 * NOT mutation targets — `evidenceCommandIsPlain` closes these BEFORE the named arm can run, so a
 * green run says nothing about the arm. The list is EXHAUSTIVE, because an earlier revision said
 * "exactly two" and that was false: the ref-moving-verb guard, BOTH `fetch` detectors, the
 * `-c`/`--config` guard, `pushd`/`popd`, and an unattributable `cd`. Every fixture for them needs
 * `&&`, `$` or a quote to reach a push in the same command. They are defence in depth for a future
 * widening of the whitelist. Stated so a reader does not mistake a green mutation for a live guard.
 *
 * REACHABLE arms each decided by ONE guard, so a single deletion reddens: the `-H`/`--head`
 * refusal, the command-position ANCHOR, the `<remote> <ref>` positional parse (extra refspec, `:`,
 * `+`, side branch), the origin-remote binding, the `GIT_DIR=` family (an inline assignment is
 * legal shell with no metacharacter), and both repo-null layers.
 *
 * (An earlier revision of this header claimed `words.length !== 2` was redundant. That was
 * false and a fresh reviewer disproved it: `git push origin main extra` shipped a SECOND
 * refspec and stayed accepted with the check deleted, because `words[1]` still equalled the
 * branch. §REFUSE-extra-refspec now pins it, so the claim cannot rot back.)
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

  // ⛔ Fresh review round 2 (P0/P1/P2) — each of these was a live accept before the fix.
  test("§REFUSE — `gh pr create -H <branch>` (the SHORT --head) is the same shape", async () => {
    const res = await fire("tool_call", { type: "tool_call", toolName: "bash", input: { command: "gh pr create -H other-branch --title x" } }, { cwd: repoDir() });
    ok(res?.block === true, "-H is --head: it opens a PR for another branch and must not use this record");
    equal(mod.resolveShippedHeads("gh pr create -H other-branch", { cwd: repoDir() }), null);
  });

  test("§REFUSE — a ref-MOVING prefix moves what the push ships after HEAD was read", async () => {
    for (const cmd of [
      "git reset --hard side && git push origin main",
      "git branch -f main side && git push origin main",
      "git checkout -B main side && git push origin main",
      "git checkout side && gh pr create -f",
      "git stash pop && git push origin main",
    ]) {
      equal(mod.resolveShippedHeads(cmd, { cwd: repoDir() }), null, `ref-moving prefix must close the evidence path: ${cmd}`);
    }
    const res = await fire("tool_call", { type: "tool_call", toolName: "bash", input: { command: "git reset --hard side && git push origin main" } }, { cwd: repoDir() });
    ok(res?.block === true, "the chained reset+push must fall back to the dispatch floor, not to the record");
  });

  test("§REFUSE — a bare `git push` ships whatever push.default selects", async () => {
    equal(mod.resolveShippedHeads("git push", { cwd: repoDir() }), null, "no refspec named → not necessarily HEAD");
    equal(mod.resolveShippedHeads("git push origin", { cwd: repoDir() }), null, "remote only → push.default decides");
    ok(mod.resolveShippedHeads("git push origin main", { cwd: repoDir() }) !== null, "control: the exact `<remote> <branch>` form is still accepted");
  });

  // ⛔ Fresh review round 3 — the guard set was regex-based and a `git -c` global walked past it.
  test("§REFUSE — `git -c <k>=<v>` prefix: a config global can change what the command DOES", async () => {
    for (const cmd of [
      "git -c user.name=x commit -m evil && git push origin main",
      "git -c core.hooksPath=/dev/null commit -m evil && git push origin main",
      "git -c user.name=x reset --hard side && git push origin main",
      "git -c user.name=x branch -f main side && git push origin main",
    ]) {
      equal(mod.resolveShippedHeads(cmd, { cwd: repoDir() }), null, `a -c global closes the evidence path: ${cmd}`);
    }
    // The PLAIN `git -c … push` shape — no separator, so `evidenceCommandIsPlain` passes. It IS
    // refused, but MEASURED: the command-position ANCHOR decides it (a plain command has no room for
    // a `-c` global before `push`, so `argv[1] !== "push"`), NOT the `-c` guard — deleting that guard
    // leaves this suite green. Asserted as BEHAVIOUR, and the header records the guard as unreachable
    // rather than claiming a pin the mutation does not support.
    equal(mod.resolveShippedHeads("git -c core.hooksPath=/dev/null push origin main", { cwd: repoDir() }), null,
      "a PLAIN `git -c <k>=<v> push` must refuse (decided by the command-position anchor)");
    const res = await fire("tool_call", { type: "tool_call", toolName: "bash", input: { command: "git -c user.name=x commit -m evil && git push origin main" } }, { cwd: repoDir() });
    ok(res?.block === true, "the chained -c commit + push must fall back to the dispatch floor");
  });

  // ⛔ Fresh review round 5 — the record path's SHAPE, the op's POSITION, and the remote its
  // repo slug came from. All three were undisclosed or unenforced; the first is also what made
  // the refusal unsatisftable for a lane that followed the instruction it printed (#2287).
  test("§ALLOW — `git push origin HEAD` ships exactly HEAD, so the record covers it", async () => {
    const r = await fire("tool_call", { type: "tool_call", toolName: "bash", input: { command: "git push origin HEAD" } }, { cwd: repoDir() });
    equal(r, undefined, "HEAD IS the commit the record is bound to — refusing it was a false block");
    ok(mod.resolveShippedHeads("git push origin HEAD", { cwd: repoDir() }) !== null, "…and the resolver agrees");
  });

  test("§REFUSE — the op must be at the COMMAND POSITION, not merely present in the text", async () => {
    for (const cmd of [
      "echo gh pr create",
      "echo git push origin main",
      "git commit -m gh pr create",
    ]) {
      equal(mod.resolveShippedHeads(cmd, { cwd: repoDir() }), null,
        `a MENTION of the op is not the op (free-text matching accepted these): ${cmd}`);
    }
    ok(mod.resolveShippedHeads("gh pr create --title x --body y", { cwd: repoDir() }) !== null,
      "control: the op at the command position still opens the evidence path");
    ok(mod.resolveShippedHeads(`gh --repo ${REPO} pr create --title x`, { cwd: repoDir() }) !== null,
      "control: the gh global --repo form is still read as the op");
  });

  test("§REFUSE — a push to a remote that is not the record's origin is not covered", async () => {
    execSync("git remote add upstream https://github.com/daniel-ospina/somewhere-else.git", { cwd: repoDir(), encoding: "utf8" });
    equal(mod.resolveShippedHeads("git push upstream main", { cwd: repoDir() }), null,
      "the record's repo slug comes from remote.origin.url, so any other remote names a different repo");
    const r = await fire("tool_call", { type: "tool_call", toolName: "bash", input: { command: "git push upstream main" } }, { cwd: repoDir() });
    ok(r?.block === true, "an upstream push must fall back to the ≥1-dispatch floor");
  });

  test("§REFUSE — `git push origin main extra` ships a SECOND refspec", async () => {
    equal(mod.resolveShippedHeads("git push origin main extra", { cwd: repoDir() }),
      null, "an extra positional is a second refspec, not this branch");
    const res = await fire("tool_call", { type: "tool_call", toolName: "bash", input: { command: "git push origin main extra" } }, { cwd: repoDir() });
    ok(res?.block === true, "the extra refspec must refuse");
  });

  test("§REFUSE — an inline `GIT_DIR=` assignment retargets the invocation", async () => {
    equal(mod.resolveShippedHeads("GIT_DIR=/other/.git git push origin main", { cwd: repoDir() }),
      null, "the HEAD/repo read here would describe a different repository");
    equal(mod.resolveShippedHeads("GIT_WORK_TREE=/tmp/x git push origin main", { cwd: repoDir() }), null);
  });

  test("§REFUSE — a `fetch` that retargets the checked-out branch is ref-moving", async () => {
    equal(mod.resolveShippedHeads("git fetch --update-head-ok origin +side:main && git push origin main", { cwd: repoDir() }),
      null, "--update-head-ok + a src:dst refspec advances the branch the push then ships");
    equal(mod.resolveShippedHeads("git fetch origin side:main && git push origin main", { cwd: repoDir() }),
      null, "a dst refspec can write the checked-out branch");
    // ⛔ The control CHANGED with the round-4 whitelist: a chained command is no longer readable
    // as "just a push" at all (any `&&` is shell syntax), so the evidence path is closed there
    // regardless of the fetch. What must still hold is that a plain fetch is not REF-MOVING.
    equal(mod.resolveShippedHeads("git fetch origin && git push origin main", { cwd: repoDir() }), null,
      "chaining closes the path on its own (shell syntax), independent of the fetch");
    equal(mod.commandMovesRefs("git fetch origin"), false,
      "control: a plain fetch moves only remote-tracking refs and is NOT ref-moving");
  });

  test("§unit — gitVerbs skips global options the way the gate's scanner does", async () => {
    equal(mod.gitVerbs("git -c user.name=x commit -m y").join(","), "commit");
    equal(mod.gitVerbs("git -C /x -c a=b push origin main").join(","), "push");
    equal(mod.gitVerbs("git add a && git commit -m x").join(","), "add,commit");
    equal(mod.gitVerbs("echo hi").length, 0);
    equal(mod.commandMovesRefs("git -c user.name=x commit -m y"), true, "a commit behind a global is still a commit");
    equal(mod.commandMovesRefs("git push origin main"), false);
  });

  // ⛔ Fresh review round 4 (P0 ×4): every one of these was a live accept at the previous head.
  // The fix is not another pattern — it is the absence of shell syntax (evidenceCommandIsPlain).
  test("§REFUSE — shell syntax of ANY kind closes the evidence path", async () => {
    for (const cmd of [
      'git "commit" -m evil && git push origin main',
      "git 'commit' -m evil && git push origin main",
      'git c"ommit" -m evil && git push origin main',
      "git \\commit -m evil && git push origin main",
      "git $(printf commit) -m evil && git push origin main",
      "git co -m evil && git push origin main", // alias noun is not the verb that runs
      'git "-c" core.hooksPath=/dev/null commit -m evil && git push origin main',
      "pushd /tmp/elsewhere && git push origin main",
      "cd $OTHER && git push origin main",
      "git fetch && git push origin main",
      "git push origin main 2>&1 | tail -3",
      "GIT_DIR=/other/.git git push origin main",
    ]) {
      equal(mod.resolveShippedHeads(cmd, { cwd: repoDir() }), null, `must refuse (shell syntax or attributability): ${cmd}`);
    }
    // Controls: the plain forms stay accepted; that is what the whitelist is FOR.
    ok(mod.resolveShippedHeads("git push origin main", { cwd: repoDir() }) !== null, "control: a bare push is accepted");
    equal(mod.evidenceCommandIsPlain("git push origin main"), true);
    equal(mod.evidenceCommandIsPlain("git push origin main | tail"), false);
  });

  test("§REFUSE — `gh pr create -Hattached` (value glued to the short flag)", async () => {
    equal(mod.resolveShippedHeads("gh pr create -Hother-branch -f", { cwd: repoDir() }),
      null, "the attached short form is the same flag and must refuse");
    ok(mod.resolveShippedHeads("gh pr create --title x --body-file body.md", { cwd: repoDir() }) !== null,
      "control: a plain create with no head override stays accepted");
  });

  test("§REFUSE — `fetch -u` and a fully-qualified dst still move the checked-out branch", async () => {
    equal(mod.resolveShippedHeads("git fetch -u . +refs/heads/side:refs/heads/main", { cwd: repoDir() }),
      null, "the SHORT -u form is --update-head-ok");
    equal(mod.commandMovesRefs("git fetch -u . +refs/heads/side:refs/heads/main"), true);
    equal(mod.commandMovesRefs("git fetch . refs/heads/side:refs/heads/main"), true,
      "a fully-qualified refs/heads destination is a ref write");
    equal(mod.commandMovesRefs("git fetch origin"), false, "a plain fetch is not ref-moving");
  });

  test("§REFUSE — a push FLAG is not the accepted shape, even when the positionals look right", async () => {
    // ⛔ Fresh review round 6 (P1). Round 5 DROPPED every `-`-prefixed token and then required
    // exactly `<remote> <ref>` — so the SHORT spellings of the flags the long-form guard refuses
    // walked in. Measured at the previous head: `git push origin main -d` was ACCEPTED, and git
    // really acts on it (`! [remote rejected] main (deletion of the current branch prohibited)` on
    // a protected branch — i.e. it IS a refs/heads delete, and it succeeds on any PR branch).
    for (const cmd of [
      "git push origin main -d",
      "git push -d origin main",
      "git push origin main -f",
      "git push -u origin main",
      "git push --force-with-lease origin main",
      "git push -o ci.skip origin main",
      "git push origin main --tags",
      "git push origin main --delete",
    ]) {
      equal(mod.resolveShippedHeads(cmd, { cwd: repoDir() }), null,
        `a flag can change WHAT the op does without moving a positional: ${cmd}`);
    }
    const res = await fire("tool_call", { type: "tool_call", toolName: "bash", input: { command: "git push origin main -d" } }, { cwd: repoDir() });
    ok(res?.block === true, "a remote-branch DELETE must fall back to the ≥1-dispatch floor");
    ok(mod.resolveShippedHeads("git push origin main", { cwd: repoDir() }) !== null,
      "control: the bare shape is still accepted");
    ok(mod.resolveShippedHeads("git push origin HEAD", { cwd: repoDir() }) !== null,
      "control: …and so is the bare HEAD form");
  });

  test("§REFUSE — PATHNAME EXPANSION closes the evidence path: the tokens are then not the argv", async () => {
    // ⛔ Fresh review round 6 (P1). The whitelist rejected quotes, escapes, substitutions and
    // operators but not `*?[]~`, so `git push origin main -*` was ACCEPTED — and in a checkout
    // holding a file named `--tags`, bash expands that flag slot to it, so the push shipped every
    // tag: the exact long form the guard at the top of the resolver refuses. Measured with real
    // git: `* [new tag] unreviewed-tag -> unreviewed-tag` alongside the branch.
    for (const cmd of [
      "git push origin main -*",
      "git push origin main ?",
      "git push origin ma[n]",
      "git push origin ~",
      "git push origin main !",
    ]) {
      equal(mod.evidenceCommandIsPlain(cmd), false, `expansion characters must close the path: ${cmd}`);
      equal(mod.resolveShippedHeads(cmd, { cwd: repoDir() }), null, `…and the resolver must refuse: ${cmd}`);
    }
    const res = await fire("tool_call", { type: "tool_call", toolName: "bash", input: { command: "git push origin main -*" } }, { cwd: repoDir() });
    ok(res?.block === true, "a glob in the flag slot must fall back to the ≥1-dispatch floor");
    // Controls: a refname cannot contain any of these, so nothing legitimate is lost.
    equal(mod.evidenceCommandIsPlain("git push origin main"), true);
    equal(mod.evidenceCommandIsPlain("gh pr create --title x --body-file body.md"), true);
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
