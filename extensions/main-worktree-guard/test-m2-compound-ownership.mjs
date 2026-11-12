// Regression tests for #605 — the M2 commit/push ownership gate resolved ONE
// repo per command (`commitHints`/`pushHints` describe only the FIRST
// EXTRACTOR-VISIBLE commit/push invocation), so a fully-VISIBLE worktree-scoped
// LEAD blanked the gate for the rest of the compound:
//
//   `git -C <wt> commit -m z ; git commit -m x`                    → ALLOW, and
//                       the real OFF-baseline MAIN commit ran rc 0
//   `git -C <wt> push origin wtmain ; git push origin feat/other`  → ALLOW
//
// The control (same mutations, reversed order) BLOCKED, so the outcome depended
// on invocation order. The round-4 M3 fix (#596) had already established the
// rule for branch-state mutations ("a leading `-C <wt>` mutation must not
// blanket-exempt a LATER MAIN mutation"); M2 never got the per-invocation loop.
//
// This suite drives the REAL extensions/main-worktree-guard/index.ts tool_call
// handler against a hermetic git fixture (the same module-load hooks as
// test-module-load.mjs / test-805-push-ownership.mjs), so it pins the SHIPPED
// gate and not a mirror of it. It covers the PUSH half of the compound here,
// and asserts M2's OWN reason text rather than `block === true`, so an
// unrelated gate that happens to refuse the command cannot satisfy the pin.
//
// ⚠️ The COMMIT half cannot be pinned through the handler: the only states in
// which an off-baseline commit is a candidate (`main` checkout switched to a
// foreign branch, hub-rooted session) are refused earlier by M4's hub-state
// gate, which blocks EVERY git command while the session's main checkout is
// off `main` (measured here — the block reason is M4's, and a
// `block === true` pin would pass without M2 ever running). The commit half is
// therefore pinned at the classifier/decideM2 level — M4-free — in
// test.mjs's `#605` group, in the same mirror style as the existing #596 M2
// pins. What this file can and does pin for commits is the NO-FALSE-BLOCK arm:
// an all-worktree compound must stay allowed.
//
// Later review rounds added three more rows here, all handler-level because each
// is a property of the SHIPPED arm ORDER rather than of M2's decision function:
//   S3 (F1) — a `--delete` anywhere in the raw command routed it into the #73 arm,
//             whose early return skipped M2 for every other mutation;
//   S4 (I1) — the ownership allowance closed the WHOLE command on the FIRST
//             push's refspecs (`git push origin main ; git push origin
//             feat/other` was allowed on `main` and the foreign push ran);
//   S5 (I2) — the delete exemption was keyed on the compound's VERDICT path, so a
//             later-segment `-d` was blocked by M2 while the byte-identical
//             `--delete` was allowed.
//
// Run: node extensions/main-worktree-guard/test-m2-compound-ownership.mjs
import { execSync } from "node:child_process";
import { mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { register, registerHooks, stripTypeScriptTypes } from "node:module";
import { reportVerdict } from "../shared/verdict.mjs";

const HERE = fileURLToPath(new URL(".", import.meta.url));
const INDEX_TS = join(HERE, "index.ts");

let pass = 0, fail = 0, skip = 0;
function expectTrue(name, cond, detail = "") {
  console.log(`${cond ? "✅" : "❌"} ${name}${cond || !detail ? "" : ` — ${detail}`}`);
  cond ? pass++ : fail++;
}
function skipped(name, why) {
  console.log(`⏭️  ${name}: SKIPPED — ${why}`);
  skip++;
}

const HATCH_VARS = ["AGENT_ALLOW_MAIN_EDITS", "ELDATO_ALLOW_MAIN_EDITS"];
// decideM2's push refusal text (extensions/shared/branch-ownership.mjs).
const M2_PUSH_REASON = "Push blocked — branch ownership violated";

async function main() {
  if (typeof stripTypeScriptTypes !== "function" ||
      (typeof register !== "function" && typeof registerHooks !== "function")) {
    skipped("#605 integration", `node ${process.versions.node} lacks stripTypeScriptTypes (needs Node >= 22.13) — unit pins still run`);
    return;
  }

  const hooks = await import(new URL("./module-load-hooks.mjs", import.meta.url).href);
  if (typeof registerHooks === "function") registerHooks({ resolve: hooks.resolve, load: hooks.load });
  else register(new URL("./module-load-hooks.mjs", import.meta.url), import.meta.url);
  process.removeAllListeners("warning");

  const warnings = [];
  const realWarn = console.warn;
  console.warn = (...args) => { warnings.push(args.map(String).join(" ")); };
  let mod;
  try {
    mod = await import(pathToFileURL(INDEX_TS).href);
  } finally {
    console.warn = realWarn;
  }
  // ⛔ PREFIX ONLY (review I3). The `&& w.includes("degrad")` this line used to
  // carry made the assertion DEAD: neither load-failure warning contains the
  // substring `degrad` (`index.ts:403` "classify-git.mjs failed to load … DISABLED",
  // `index.ts:488` "branch-ownership.mjs failed to load … DISABLED"), so the
  // filtered set was empty even when the import genuinely degraded and C1 could
  // never go RED. Same filter as test-805-push-ownership.mjs:67.
  const degradation = warnings.filter((w) => w.includes("[main-worktree-guard]"));
  for (const w of degradation) console.log(`     captured: ${w}`);
  expectTrue("C1: index.ts loads with no degradation warning", degradation.length === 0, degradation.join(" | "));

  const handlers = new Map();
  mod.default({ on(name, fn) { if (!handlers.has(name)) handlers.set(name, []); handlers.get(name).push(fn); } });
  const toolCall = handlers.get("tool_call")?.[0];
  const sessionStart = handlers.get("session_start")?.[0];
  expectTrue("C2: tool_call handler registered", typeof toolCall === "function");
  expectTrue("C3: session_start handler registered", typeof sessionStart === "function");
  if (typeof toolCall !== "function" || typeof sessionStart !== "function") return;

  const savedHatch = new Map(HATCH_VARS.map((v) => [v, process.env[v]]));
  const savedAip = process.env.AGENT_INFRA_PATH;
  const savedLocks = process.env.AGENT_LOCKS_DIR;
  const tmp = realpathSync(mkdtempSync(join(tmpdir(), "guard-605-")));
  const prevCwd = process.cwd();
  const hub = join(tmp, "hub");
  const wt = join(tmp, "wt");
  const held = join(tmp, "held");
  const quiet = async (fn) => { const w = console.warn; console.warn = () => {}; try { return await fn(); } finally { console.warn = w; } };
  const callBash = (command) => toolCall({ toolName: "bash", input: { command } }, undefined);
  const refusedBy = (r, needle) => !!r && r.block === true && String(r.reason || "").includes(needle);

  try {
    execSync(`git init -q -b main "${hub}"`, { stdio: "ignore" });
    execSync("git config user.email t@t && git config user.name t", { cwd: hub, stdio: "ignore" });
    writeFileSync(join(hub, "tracked.txt"), "x\n");
    // `stale`/`stale2` exist so the delete rows name REAL branches (nothing holds
    // them); `held` is checked out in a sibling worktree below, which is exactly
    // what the #73 coordinated-delete check must see.
    execSync("git add -A && git commit -qm init && git branch feat/other && git branch stale && git branch stale2 && git branch held",
      { cwd: hub, stdio: "ignore" });
    execSync(`git worktree add -q -b wtmain "${wt}"`, { cwd: hub, stdio: "ignore" });
    for (const v of HATCH_VARS) delete process.env[v];
    process.env.AGENT_INFRA_PATH = hub; // the shared agent-infra checkout
    process.env.AGENT_LOCKS_DIR = join(tmp, "locks");

    // Hub-rooted session on `main` → baseline = main, and the hub stays ON
    // `main` and clean for the whole suite, so M4's hub-state gate is satisfied
    // and every verdict below is M2's own (asserted via the reason text).
    process.chdir(hub);
    await quiet(() => sessionStart({}, undefined));

    // ── Scenario 1: OFF-baseline MAIN push behind a VISIBLE wt-scoped lead ──
    // Before #605 the leading `-C <wt>` push supplied the ONLY resolved repo (a
    // worktree), decideM2 returned null for the whole command, and the real
    // MAIN push of `feat/other` was ALLOWED.
    const s1 = await quiet(() => callBash(`git -C "${wt}" push origin wtmain ; git push origin feat/other`));
    expectTrue("S1 #605: visible wt-scoped push LEAD + off-baseline MAIN push → M2 BLOCK",
      refusedBy(s1, M2_PUSH_REASON), `handler returned ${JSON.stringify(s1)?.slice(0, 200)}`);
    // The control (same two mutations, reversed order) blocked BEFORE the fix
    // too: the gate outcome must not depend on invocation order (#605).
    const s1ctl = await quiet(() => callBash(`git push origin feat/other ; git -C "${wt}" push origin wtmain`));
    expectTrue("S1 #605: control — off-baseline MAIN push BEFORE the wt lead still BLOCKS",
      refusedBy(s1ctl, M2_PUSH_REASON), `handler returned ${JSON.stringify(s1ctl)?.slice(0, 200)}`);
    // …and the residual the FIRST-push-only target attribution left open: the
    // LEAD naming the SESSION's branch must not launder the MAIN push of a
    // foreign one (pre-fix the lead's `main` was the only target set read).
    const s1launder = await quiet(() => callBash(`git -C "${wt}" push origin main ; git push origin feat/other`));
    expectTrue("S1 #605: leading wt push naming the BASELINE branch cannot launder a MAIN push of a foreign one",
      refusedBy(s1launder, M2_PUSH_REASON), `handler returned ${JSON.stringify(s1launder)?.slice(0, 200)}`);

    // ── Scenario 2: NO FALSE BLOCK (the other half of the same loop) ──
    // The MAIN push below is ON-baseline (its OWN refspec is the session's
    // branch), so it must stay ALLOWED even though the LEAD's refspec names a
    // different branch — gating it with the first push's targets, or with the
    // lead's repo, would refuse legitimate work.
    const s2 = await quiet(() => callBash(`git -C "${wt}" push origin wtmain ; git push origin main`));
    expectTrue("S2 #605: wt lead + ON-baseline MAIN push (own refspec) → ALLOWED (targets are per-invocation)",
      s2 === undefined, `handler returned ${JSON.stringify(s2)?.slice(0, 200)}`);
    const s2own = await quiet(() => callBash(`git -C "${wt}" push origin feat/other`));
    expectTrue("S2 #605: ordinary worktree push of a foreign branch stays ALLOWED (worktree-scoped)",
      s2own === undefined, `handler returned ${JSON.stringify(s2own)?.slice(0, 200)}`);
    // ⛔ NO all-worktree COMMIT row here (review round-3 F2; agent-infra#3442
    // rule 3). Such a row cannot go RED under ANY edit this change can make: in
    // this fixture the hub is ON `main` and `main` is the session baseline, so
    // every way the commit leg can break still lands on an allowed decision —
    // dropping the per-mutation worktree exemption leaves decideM2's own
    // `isWorktree -> null`, nulling the hints resolves to the hub on its baseline
    // branch, and pointing the hints at the hub does the same. The property is
    // real and reachable at the classifier level, where it IS pinned: `test.mjs`
    // "#605: ALL-wt compound ... -> wt-exempt" (m2l) reddens under exactly those
    // mutants. A row here would be a pin that cannot fail — worse than no row.

    // ── Scenario 3 (review F1): a `--delete` anywhere used to exempt the rest ──
    // The push-delete verdict is set from the WHOLE raw command, and that arm
    // returned without running M2 — so an UNRELATED delete segment exempted
    // every other mutation in the compound (the same class, one level above the
    // hints): `git push origin feat/other ; git push origin --delete stale`
    // reached the #73 arm, found no sibling holding `stale`, and let the
    // off-baseline MAIN push run. The delete arm now gates the compound's
    // NON-delete mutations first.
    const s3 = await quiet(() => callBash(`git push origin feat/other ; git push origin --delete stale`));
    expectTrue("S3 F1: off-baseline MAIN push + an unrelated --delete segment → M2 BLOCK (delete no longer exempts)",
      refusedBy(s3, M2_PUSH_REASON), `handler returned ${JSON.stringify(s3)?.slice(0, 200)}`);
    // The no-false-block controls for the same arm: a delete-only command is
    // unchanged, and an ON-baseline push beside a delete stays allowed.
    const s3only = await quiet(() => callBash(`git push origin --delete stale`));
    expectTrue("S3 F1 control: delete-only command → ALLOWED (unchanged #73 behavior)",
      s3only === undefined, `handler returned ${JSON.stringify(s3only)?.slice(0, 200)}`);
    const s3own = await quiet(() => callBash(`git push origin main ; git push origin --delete stale`));
    expectTrue("S3 F1 control: ON-baseline MAIN push + a --delete segment → ALLOWED (no false block)",
      s3own === undefined, `handler returned ${JSON.stringify(s3own)?.slice(0, 200)}`);

    // ── Scenario 4 (review I1): the OWNERSHIP ALLOWANCE closed the whole
    // command on the FIRST push's refspecs, so the plain-MAIN twin of #605's own
    // class stayed open — `git push origin main ; git push origin feat/other`
    // (baseline main) was allowed on `main` and the FOREIGN push ran. The
    // allowance's admit path now gates the compound's remaining mutations first.
    const s4 = await quiet(() => callBash(`git push origin main ; git push origin feat/other`));
    expectTrue("S4 I1: on-baseline MAIN push + a FOREIGN MAIN push in one compound → M2 BLOCK (allowance no longer closes the command)",
      refusedBy(s4, M2_PUSH_REASON), `handler returned ${JSON.stringify(s4)?.slice(0, 200)}`);

    // ── Scenario 5 (review I2): the delete exemption must key on the MUTATION's
    // own spelling, not on the compound's verdict path — verdict-keyed, it held
    // only when the delete was the FIRST push, so the `-d` short form in a later
    // segment was BLOCKED while the byte-identical `--delete` was allowed.
    const s5 = await quiet(() => callBash(`git push origin main && git push origin -d stale`));
    expectTrue("S5 I2: later-segment `-d` remote-branch delete → ALLOWED (same verdict as the `--delete` spelling)",
      s5 === undefined, `handler returned ${JSON.stringify(s5)?.slice(0, 200)}`);
    const s5b = await quiet(() => callBash(`git push origin -d stale`));
    expectTrue("S5 I2 control: lone `-d` delete → ALLOWED", s5b === undefined, `handler returned ${JSON.stringify(s5b)?.slice(0, 200)}`);
    const s5c = await quiet(() => callBash(`git -C "${wt}" push origin wtmain && git push origin -d stale`));
    expectTrue("S5 I2 control: wt lead + later-segment `-d` delete → ALLOWED (no false block)",
      s5c === undefined, `handler returned ${JSON.stringify(s5c)?.slice(0, 200)}`);

    // ── Scenario 6 (review round-3 F1): the #73 arm's TARGET-COUNT precondition
    // and the M2 leg were ONE guard, so a delete spelling that resolves to no
    // refspec (`git push --delete` — a git error: "--delete doesn't make sense
    // without any refs") skipped the whole arm and exempted the compound. The
    // guards are split: the target-count precondition still belongs to #73, the
    // M2 leg runs on the VERDICT.
    const s6 = await quiet(() => callBash(`git push origin feat/other && git push --delete`));
    expectTrue("S6 F1: off-baseline MAIN push + a no-refspec `git push --delete` segment → M2 BLOCK",
      refusedBy(s6, M2_PUSH_REASON), `handler returned ${JSON.stringify(s6)?.slice(0, 200)}`);
    const s6semi = await quiet(() => callBash(`git push origin feat/other ; git push --delete`));
    expectTrue("S6 F1: same, `;`-compound spelling → M2 BLOCK",
      refusedBy(s6semi, M2_PUSH_REASON), `handler returned ${JSON.stringify(s6semi)?.slice(0, 200)}`);
    // It is a git ERROR, not a delete: alone it must stay allowed.
    const s6only = await quiet(() => callBash(`git push --delete`));
    expectTrue("S6 F1 control: lone no-refspec `git push --delete` → ALLOWED (a git error, not a delete)",
      s6only === undefined, `handler returned ${JSON.stringify(s6only)?.slice(0, 200)}`);

    // ── Scenario 7 (review round-3 F3): the #73 check saw only the FIRST delete
    // invocation's targets, so a SECOND delete segment aimed at a
    // sibling-checked-out branch was never looked up — the protection held for
    // one spelling and vanished when the delete was split in two.
    execSync(`git worktree add -q "${held}" held`, { cwd: hub, stdio: "ignore" });
    const s7 = await quiet(() => callBash(`git push origin --delete stale && git push origin --delete held`));
    expectTrue("S7 F3: second delete segment aimed at a sibling-checked-out branch → #73 BLOCK (targets are unioned)",
      !!s7 && s7.block === true && String(s7.reason || "").includes("Cannot delete"),
      `handler returned ${JSON.stringify(s7)?.slice(0, 200)}`);
    const s7only = await quiet(() => callBash(`git push origin --delete held`));
    expectTrue("S7 F3 control: the same delete ALONE is still blocked (this row is not the union's only witness)",
      !!s7only && s7only.block === true, `handler returned ${JSON.stringify(s7only)?.slice(0, 200)}`);
    const s7free = await quiet(() => callBash(`git push origin --delete stale && git push origin --delete stale2`));
    expectTrue("S7 F3 control: two deletes of unheld branches → ALLOWED (no false block)",
      s7free === undefined, `handler returned ${JSON.stringify(s7free)?.slice(0, 200)}`);

    // ── Scenario 8 (review round-5 F1): the mutation list must contain only
    // invocations the command ACTUALLY contains. It used to synthesize one from
    // `det.commitHints`/`det.pushHints` when the classifier saw none, which is
    // unreachable at the M2 arm (the verdict implies the invocation) but NOT at
    // the arms that gate without such a verdict: a `git pull --ff-only` got a
    // phantom push whose null hints resolved at the session cwd, so #2277's own
    // recovery shape — a lane rooted OUTSIDE any git repo syncing a clean hub —
    // was refused with "⛔ git commit/push blocked — could not verify repo
    // ownership" on a command containing no commit and no push (MEASURED).
    //
    // This scenario needs a real upstream, because #2277's allowance admits only a
    // PROVEN fast-forward onto the checkout's own upstream: a bare origin, the hub
    // one commit behind it, and a session rooted in a NON-git directory.
    const ffOrigin = join(tmp, "origin.git");
    const ffClone = join(tmp, "ff-clone");
    const outside = join(tmp, "outside-any-repo");
    execSync(`git init -q --bare "${ffOrigin}"`, { stdio: "ignore" });
    execSync("git symbolic-ref HEAD refs/heads/main", { cwd: ffOrigin, stdio: "ignore" });
    execSync(`git remote add fforigin "${ffOrigin}"`, { cwd: hub, stdio: "ignore" });
    execSync("git push -q fforigin main", { cwd: hub, stdio: "ignore" });
    execSync(`git clone -q -b main "${ffOrigin}" "${ffClone}"`, { stdio: "ignore" });
    execSync("git config user.email t@t && git config user.name t", { cwd: ffClone, stdio: "ignore" });
    writeFileSync(join(ffClone, "second.txt"), "y\n");
    execSync("git add -A && git commit -qm second && git push -q origin main", { cwd: ffClone, stdio: "ignore" });
    execSync("git remote set-head fforigin main", { cwd: hub, stdio: "ignore" });
    execSync("git fetch -q fforigin", { cwd: hub, stdio: "ignore" });
    execSync(`mkdir -p "${outside}"`);
    process.chdir(outside); // session rooted OUTSIDE any git repo (#2277's shape)
    const s8 = await quiet(() => callBash(`cd "${hub}" && git pull --ff-only`));
    expectTrue("S8 F1-r5: a `git pull --ff-only` compound (no commit, no push) is NOT refused — no phantom mutation is gated",
      s8 === undefined, `handler returned ${JSON.stringify(s8)?.slice(0, 240)}`);
    const s8c = await quiet(() => callBash(`git -C "${hub}" pull --ff-only`));
    expectTrue("S8 F1-r5: same, `-C` spelling → not refused",
      s8c === undefined, `handler returned ${JSON.stringify(s8c)?.slice(0, 240)}`);

    // ── Scenario 9 (review round-6 F1): a push verdict the extractor could NOT
    // SEE still has a referent, and an EMPTY mutation list under it is an
    // UNRESOLVABLE TARGET — #805 refuses it — not "nothing to gate". The
    // classifier's zero-invocation early return sets `block:force-push` /
    // `block:push-delete` from the RAW text and returns BEFORE
    // commitMutations/pushMutations are populated, so round 5's phantom removal
    // (correct for `git pull --ff-only`, whose verdict implies no push) left
    // `gateMutations([])` → undefined → ADMIT. MEASURED regression: on main the
    // same inputs were refused by the null-resolution arm, so a #2277 lane —
    // rooted OUTSIDE any git repo, which is exactly this cwd — went
    // BLOCK → ALLOW on the force-push it could not see.
    const s9var = await quiet(() => callBash(`EV="cd ${hub} && git push -f origin feat/other"; eval $EV`));
    expectTrue("S9 F1-r6: an opaque `eval $VAR` force-push (zero mutations) is FAIL-CLOSED, not admitted",
      refusedBy(s9var, "could not verify repo ownership"),
      `handler returned ${JSON.stringify(s9var)?.slice(0, 240)}`);
    const s9eval = await quiet(() => callBash(`eval "cd ${hub} && git push -f origin feat/other"`));
    expectTrue("S9 F1-r6: same, literal `eval \"…\"` spelling → FAIL-CLOSED",
      refusedBy(s9eval, "could not verify repo ownership"),
      `handler returned ${JSON.stringify(s9eval)?.slice(0, 240)}`);
    // The same class on the delete verdict — the identical zero-mutation shape,
    // and the identical fail-open when the list was empty.
    const s9del = await quiet(() => callBash(`eval "git push origin --delete stale"`));
    expectTrue("S9 F1-r6: an opaque `eval` --delete push (zero mutations) → FAIL-CLOSED (same class)",
      refusedBy(s9del, "could not verify repo ownership"),
      `handler returned ${JSON.stringify(s9del)?.slice(0, 240)}`);
    // ⛔ SCOPE CONTROL (no new false block): the arm refuses only when the
    // session's own repo is UNRESOLVABLE. With the cwd back in the hub — on
    // `main`, the recorded baseline — the arm does not fire and main's behaviour
    // is unchanged, so this is a restoration, not an extension.
    process.chdir(hub);
    const s9ctl = await quiet(() => callBash(`EV="cd ${hub} && git push -f origin feat/other"; eval $EV`));
    expectTrue("S9 F1-r6 control: the #265 refusal is scoped to an UNRESOLVABLE cwd — a hub-rooted on-baseline session is unchanged",
      s9ctl === undefined, `handler returned ${JSON.stringify(s9ctl)?.slice(0, 240)}`);

    // ── Scenario 10 (#608): the pid-owned set is a statement about the refs the
    // session CURRENTLY holds, not an append-only memory. #598 lets a forced
    // rename overwrite a dst in this pid's ownedBranches (the session
    // consolidating its OWN refs) and #543/#376 lets a LOCAL `git branch -D`
    // delete one — so a stale entry is a live authorization against a ref the
    // session no longer holds, and a sibling that RE-CREATES the freed name
    // inherits it: `git branch -M main <that name>` clobbers the sibling's branch
    // rc 0 (its commits with it), and `git branch -D <that name>` destroys it.
    //
    // ⛔ FIXTURE SHAPE (measured, and it is why these rows are decision-level like
    // every other row in this suite): driving the REAL hub through a ceremony
    // shows the guard's in-memory baseline never returns to `main` — the recovery
    // `git checkout main` is admitted by M4's hub-state window BEFORE M3's #376
    // arm can re-baseline, so `baseline.branch` stays on the renamed branch for
    // the rest of the session and BOTH ownership allowances (which require
    // `currentBranch === baselineBranch`) then deny. That is a SEPARATE defect
    // (reported with this PR's measurement), so it cannot be used to reach these
    // arms. What this section therefore pins is the arms' own decision surface
    // with a REAL ref behind the claim (the soft `-d` arm probes git for whether
    // the delete will succeed, so the ref must exist), i.e. exactly the state
    // each arm reads.
    const mainSha = () => execSync("git rev-parse refs/heads/main", { cwd: hub, encoding: "utf-8" }).trim();
    const callBashSafe = async (command) => {
      try { return await quiet(() => callBash(command)); }
      catch (e) { return { block: true, reason: `THREW ${String(e?.message ?? e).slice(0, 160)}` }; }
    };
    // A command the guard ADMITS is really executed, so a row can assert the
    // delete actually happened (and that git's own refusal is distinguishable
    // from the guard's).
    const callRun = async (command) => {
      const v = await callBashSafe(command);
      if (v !== undefined) return v; // refused → git never ran
      try {
        execSync(command, { cwd: hub, stdio: "ignore" });
        return undefined;
      } catch (e) {
        return { gitRefused: true, reason: String(e?.message ?? e).split("\n")[0].slice(0, 160) };
      }
    };
    // The #376 ceremony as the GUARD sees it: an admitted own-baseline rename
    // (which marks the new name owned and re-baselines the session) followed by
    // the sanctioned return. `unmerged` gives the claim a REAL ref that is NOT an
    // ancestor of HEAD, which is the state a soft `-d` refuses.
    const ceremony = async (to, { unmerged = false } = {}) => {
      const base = mainSha();
      let sha = base;
      if (unmerged) {
        // A commit that exists but is not on main — `git commit-tree` never moves
        // a ref, so the fixture's tracked tree is untouched.
        sha = execSync(`git commit-tree $(git write-tree) -p HEAD -m diverge-608`, { cwd: hub, encoding: "utf-8" }).trim();
      }
      const renamed = await callBashSafe(`git branch -M main ${to}`);
      if (renamed !== undefined) return { renamed };
      execSync(`git branch ${to} ${sha}`, { cwd: hub, stdio: "ignore" }); // the ref the claim is about
      const back = await callBashSafe("git checkout main");
      return { renamed, back };
    };
    const CLAIM_SPENT = "already exists as a branch this session does not";
    const branchExists = (b) =>
      execSync("git branch --format='%(refname:short)'", { cwd: hub, encoding: "utf-8" })
        .trim().split("\n").includes(b);

    // R0 — the issue's other named channel, pinned at DECISION level: the
    // session's own-baseline rename AWAY from a name it owned. M4's hub-state
    // window makes the rename-away unreachable through the gate while the hub is
    // off `main` (measured — see the fixture note above), so this row asserts the
    // bookkeeping itself: the renamed-away name must leave the owned set, or a
    // sibling that re-creates it is clobbered by the next own-baseline rename.
    const r0a = await callBashSafe("git branch -M main feat/608r0a");
    expectTrue("R0 #608: own-baseline rename onto a FREE name → ALLOW", r0a === undefined, `handler returned ${JSON.stringify(r0a)?.slice(0, 240)}`);
    const r0b = await callBashSafe("git branch -M feat/608r0a feat/608r0b");
    expectTrue("R0 #608: rename AWAY from the owned name → ALLOW", r0b === undefined, `handler returned ${JSON.stringify(r0b)?.slice(0, 240)}`);
    const r0c = await callBashSafe("git checkout main");
    expectTrue("R0 #608: sanctioned return to the original baseline → ALLOW", r0c === undefined, `handler returned ${JSON.stringify(r0c)?.slice(0, 240)}`);
    execSync(`git branch feat/608r0a ${mainSha()}`, { cwd: hub, stdio: "ignore" }); // sibling re-creates the FREED name
    const r0d = await callBashSafe("git branch -M main feat/608r0a");
    expectTrue("R0 #608: rename onto the sibling's RE-CREATED name → BLOCK (the renamed-away name is no longer owned)",
      !!r0d && r0d.block === true && String(r0d.reason || "").includes(CLAIM_SPENT),
      `handler returned ${JSON.stringify(r0d)?.slice(0, 240)}`);

    // R1 — the LIVE destructive channel: the #543/#376 allowance. `-D` of the
    // session's own post-ceremony branch is admitted (that is what the allowance
    // is FOR) and must spend the claim, so a sibling that re-creates the name is
    // not ours to clobber or delete. Pre-fix this row ALSO pins a crash:
    // `ownershipAllowed` called `.filter` on the `Set` the caller passes, so the
    // handler threw and pi BLOCKS a tool on a handler failure.
    const r1 = await ceremony("feat/608r1");
    expectTrue("R1 #608: ceremony (own-baseline rename + sanctioned return) → both ALLOW",
      r1.renamed === undefined && r1.back === undefined, JSON.stringify(r1)?.slice(0, 200));
    const r1del = await callRun("git branch -D feat/608r1");
    expectTrue("R1 #608: post-return LOCAL delete of the pid's OWN branch → ALLOW and it really runs (Set/array contract)",
      r1del === undefined && branchExists("feat/608r1") === false,
      `handler returned ${JSON.stringify(r1del)?.slice(0, 240)}`);
    execSync("git branch feat/608r1", { cwd: hub, stdio: "ignore" }); // a sibling re-creates the freed name
    const r1stale = await callBashSafe("git branch -M main feat/608r1");
    expectTrue("R1 #608: rename onto a sibling's RE-CREATED name → BLOCK (the delete spent the claim)",
      !!r1stale && r1stale.block === true && String(r1stale.reason || "").includes(CLAIM_SPENT),
      `handler returned ${JSON.stringify(r1stale)?.slice(0, 240)}`);
    const r1del2 = await callBashSafe("git branch -D feat/608r1");
    expectTrue("R1 #608: …and the same name is not local-deletable either (one claim, both destructive arms)",
      !!r1del2 && r1del2.block === true, `handler returned ${JSON.stringify(r1del2)?.slice(0, 240)}`);

    // R2 — the SOFT `-d` channel: an ALLOW verdict (git's merged-only delete is
    // self-enforcing), so it never reaches the ownership-allowance arm — yet it
    // deletes the ref. Staleness-only witness: no TypeError is involved.
    const r2 = await ceremony("feat/608r2");
    expectTrue("R2 #608: ceremony → ALLOW", r2.renamed === undefined && r2.back === undefined, JSON.stringify(r2)?.slice(0, 200));
    const r2del = await callRun("git branch -d feat/608r2");
    expectTrue("R2 #608: SOFT `-d` of the pid's own (merged) branch → ALLOW and git really deletes it",
      r2del === undefined && branchExists("feat/608r2") === false,
      `handler returned ${JSON.stringify(r2del)?.slice(0, 240)}`);
    execSync("git branch feat/608r2", { cwd: hub, stdio: "ignore" });
    const r2stale = await callBashSafe("git branch -M main feat/608r2");
    expectTrue("R2 #608: rename onto a sibling's RE-CREATED name after a SOFT delete → BLOCK (the soft delete spent the claim)",
      !!r2stale && r2stale.block === true && String(r2stale.reason || "").includes(CLAIM_SPENT),
      `handler returned ${JSON.stringify(r2stale)?.slice(0, 240)}`);

    // R3 — the WORKTREE-scoped channel: exempt from every gate by design, but it
    // deletes the SAME repo's refs/heads (a linked worktree shares the git dir —
    // the repoKeys are identical, measured), so the claim must still be spent.
    const r3 = await ceremony("feat/608r3");
    expectTrue("R3 #608: ceremony → ALLOW", r3.renamed === undefined && r3.back === undefined, JSON.stringify(r3)?.slice(0, 200));
    const r3del = await callRun(`git -C "${wt}" branch -D feat/608r3`);
    expectTrue("R3 #608: WORKTREE-scoped `-D` of the pid's own branch → ALLOW and it really runs (exemption intact)",
      r3del === undefined && branchExists("feat/608r3") === false,
      `handler returned ${JSON.stringify(r3del)?.slice(0, 240)}`);
    execSync("git branch feat/608r3", { cwd: hub, stdio: "ignore" });
    const r3stale = await callBashSafe("git branch -M main feat/608r3");
    expectTrue("R3 #608: rename onto a sibling's RE-CREATED name after a worktree-scoped delete → BLOCK (the exempt delete spent the claim)",
      !!r3stale && r3stale.block === true && String(r3stale.reason || "").includes(CLAIM_SPENT),
      `handler returned ${JSON.stringify(r3stale)?.slice(0, 240)}`);

    // R4 (review P1a) — ONE command, TWO local deletes: the classifier's
    // `deleteTargets` describes the FIRST mutating invocation only, so a compound
    // spent only the first claim and left the second stale.
    const r4a = await ceremony("feat/608r4a");
    const r4b = await ceremony("feat/608r4b");
    expectTrue("R4 #608: two ceremonies → ALLOW each",
      r4a.renamed === undefined && r4a.back === undefined && r4b.renamed === undefined && r4b.back === undefined,
      JSON.stringify([r4a, r4b])?.slice(0, 240));
    const r4del = await callRun("git branch -D feat/608r4a && git branch -D feat/608r4b");
    expectTrue("R4 #608: a compound naming TWO owned deletes → ALLOW and both refs really go",
      r4del === undefined && branchExists("feat/608r4a") === false && branchExists("feat/608r4b") === false,
      `handler returned ${JSON.stringify(r4del)?.slice(0, 240)}`);
    execSync("git branch feat/608r4b", { cwd: hub, stdio: "ignore" }); // sibling re-creates the SECOND name
    const r4stale = await callBashSafe("git branch -M main feat/608r4b");
    expectTrue("R4 #608: the SECOND delete's name is spent too → rename onto the sibling's branch BLOCKS",
      !!r4stale && r4stale.block === true && String(r4stale.reason || "").includes(CLAIM_SPENT),
      `handler returned ${JSON.stringify(r4stale)?.slice(0, 240)}`);

    // R5/R6 (review P1b) — a local delete CO-SPELLED with another operation is
    // admitted by a DIFFERENT arm (`block:push-delete`, `block:commit`/`push`),
    // which used to return without spending anything. The spend now sits at the
    // ONE admission funnel, so an arm added later cannot skip it.
    const r5 = await ceremony("feat/608r5");
    expectTrue("R5 #608: ceremony → ALLOW", r5.renamed === undefined && r5.back === undefined, JSON.stringify(r5)?.slice(0, 200));
    const r5del = await callRun("git push origin --delete feat/608r5 ; git branch -D feat/608r5");
    expectTrue("R5 #608: `git push --delete … ; git branch -D …` (the ordinary remote+local cleanup) → ALLOW, local delete runs",
      r5del === undefined && branchExists("feat/608r5") === false,
      `handler returned ${JSON.stringify(r5del)?.slice(0, 240)}`);
    execSync("git branch feat/608r5", { cwd: hub, stdio: "ignore" });
    const r5stale = await callBashSafe("git branch -M main feat/608r5");
    expectTrue("R5 #608: the push-delete arm spent the co-spelled local delete's claim → rename BLOCKS",
      !!r5stale && r5stale.block === true && String(r5stale.reason || "").includes(CLAIM_SPENT),
      `handler returned ${JSON.stringify(r5stale)?.slice(0, 240)}`);

    const r6 = await ceremony("feat/608r6");
    expectTrue("R6 #608: ceremony → ALLOW", r6.renamed === undefined && r6.back === undefined, JSON.stringify(r6)?.slice(0, 200));
    const r6del = await callRun("git commit --allow-empty -qm fixture-commit ; git branch -D feat/608r6");
    expectTrue("R6 #608: `git commit … ; git branch -D …` → ALLOW, local delete runs",
      r6del === undefined && branchExists("feat/608r6") === false,
      `handler returned ${JSON.stringify(r6del)?.slice(0, 240)}`);
    execSync("git branch feat/608r6", { cwd: hub, stdio: "ignore" });
    const r6stale = await callBashSafe("git branch -M main feat/608r6");
    expectTrue("R6 #608: the push/commit arm spent the co-spelled local delete's claim → rename BLOCKS",
      !!r6stale && r6stale.block === true && String(r6stale.reason || "").includes(CLAIM_SPENT),
      `handler returned ${JSON.stringify(r6stale)?.slice(0, 240)}`);

    // R7 (review P2) — a soft `-d` git REFUSES (the branch is not fully merged)
    // must NOT spend the claim: the standard `-d` → `-D` escalation on the
    // session's OWN branch has to keep working, and it did before this change.
    const r7 = await ceremony("feat/608r7", { unmerged: true });
    expectTrue("R7 #608: ceremony with a diverged (unmerged) branch → ALLOW",
      r7.renamed === undefined && r7.back === undefined, JSON.stringify(r7)?.slice(0, 200));
    const r7soft = await callRun("git branch -d feat/608r7");
    expectTrue("R7 #608: soft `-d` of an UNMERGED own branch → ADMITTED, git refuses it (rc 1) and the ref survives",
      !!r7soft && r7soft.gitRefused === true && branchExists("feat/608r7") === true,
      `handler returned ${JSON.stringify(r7soft)?.slice(0, 240)}`);
    const r7hard = await callRun("git branch -D feat/608r7");
    expectTrue("R7 #608: …the `-d` → `-D` escalation still works (a REFUSED `-d` spends nothing)",
      r7hard === undefined && branchExists("feat/608r7") === false,
      `handler returned ${JSON.stringify(r7hard)?.slice(0, 240)}`);
    execSync("git branch feat/608r7", { cwd: hub, stdio: "ignore" });
    const r7stale = await callBashSafe("git branch -M main feat/608r7");
    expectTrue("R7 #608: control — the successful `-D` DID spend the claim (rename onto the sibling's branch blocks)",
      !!r7stale && r7stale.block === true && String(r7stale.reason || "").includes(CLAIM_SPENT),
      `handler returned ${JSON.stringify(r7stale)?.slice(0, 240)}`);

    // R8 — NO-FALSE-BLOCK controls: unmarking must not spend a claim the session
    // still holds, and the spend must not widen what `-D` may delete.
    const r8 = await ceremony("feat/608r8");
    expectTrue("R8 #608 control: ceremony → ALLOW", r8.renamed === undefined && r8.back === undefined, JSON.stringify(r8)?.slice(0, 200));
    const r8own = await callBashSafe("git branch -M main feat/608r8");
    expectTrue("R8 #608 control: re-rename onto the session's STILL-OWNED ref → ALLOW (#598 own-refs consolidation intact)",
      r8own === undefined, `handler returned ${JSON.stringify(r8own)?.slice(0, 240)}`);
    // R8's re-rename onto the still-owned ref RE-BASELINES the session to that
    // name; the control that follows is refused, so the baseline never moves
    // back on its own. Restore it before the R9 fixture (a rename is only
    // admissible from the session's own baseline).
    const r8back = await callBashSafe("git checkout main");
    expectTrue("R8 #608 control: sanctioned return after the own-ref rename → ALLOW",
      r8back === undefined, `handler returned ${JSON.stringify(r8back)?.slice(0, 240)}`);
    const r8foreign = await callBashSafe("git branch -D feat/other");
    expectTrue("R8 #608 control: deleting a NEVER-owned branch stays BLOCKED (the spend does not widen `-D`)",
      !!r8foreign && r8foreign.block === true, `handler returned ${JSON.stringify(r8foreign)?.slice(0, 240)}`);

    // R9 (review P2, UPSTREAM leg) — git's soft-delete predicate is "fully merged
    // in its UPSTREAM, or in HEAD when no upstream is set", so a branch merged
    // into local HEAD but NOT into its configured upstream is REFUSED by git.
    // A HEAD-only probe reads that as "the delete will happen" and spends the
    // claim, which turns the legitimate `-d` → `-D` escalation on the session's
    // OWN branch into a block — the same false block R7 pins for the unmerged
    // case, reached through the upstream leg instead.
    const r9 = await ceremony("feat/608r9");
    expectTrue("R9 #608: ceremony → ALLOW", r9.renamed === undefined && r9.back === undefined, JSON.stringify(r9)?.slice(0, 200));
    const r9c0 = mainSha();
    const r9tip = execSync(`git commit-tree $(git write-tree) -p ${r9c0} -m r9-branch-tip`, { cwd: hub, encoding: "utf-8" }).trim();
    const r9merged = execSync(`git commit-tree $(git write-tree) -p ${r9c0} -p ${r9tip} -m r9-merge`, { cwd: hub, encoding: "utf-8" }).trim();
    // `%(upstream)` resolves through the REMOTE's fetch refspec, so git must
    // have a remote named `origin` configured at all — without it git reports
    // no upstream and `-d` falls back to the HEAD leg (measured: probe-verified).
    execSync(`git remote add origin "${hub}"`, { cwd: hub, stdio: "ignore" });
    execSync(`git update-ref refs/heads/feat/608r9 ${r9tip}`, { cwd: hub, stdio: "ignore" }); // the branch's real tip
    execSync(`git update-ref refs/remotes/origin/main ${r9c0}`, { cwd: hub, stdio: "ignore" }); // upstream WITHOUT that tip
    execSync(`git update-ref refs/heads/main ${r9merged}`, { cwd: hub, stdio: "ignore" }); // HEAD DOES contain it
    execSync("git config branch.feat/608r9.remote origin && git config branch.feat/608r9.merge refs/heads/main",
      { cwd: hub, stdio: "ignore" });
    const r9soft = await callRun("git branch -d feat/608r9");
    expectTrue("R9 #608: soft `-d` merged in HEAD but NOT in its upstream → ADMITTED, git refuses it and the ref survives",
      !!r9soft && r9soft.gitRefused === true && branchExists("feat/608r9") === true,
      `handler returned ${JSON.stringify(r9soft)?.slice(0, 240)}`);
    const r9hard = await callRun("git branch -D feat/608r9");
    expectTrue("R9 #608: …the `-d` → `-D` escalation still works (the UPSTREAM leg also spends nothing when git refuses)",
      r9hard === undefined && branchExists("feat/608r9") === false,
      `handler returned ${JSON.stringify(r9hard)?.slice(0, 240)}`);
    // R10 (review round-2 P1, the FAIL-OPEN leg) — an upstream that is
    // CONFIGURED but GONE (`[gone]` after `git fetch --prune`). `%(upstream)`
    // still prints the refname, but git's `branch_merged()` cannot resolve it and
    // falls back to HEAD — so git DELETES the merged branch. A probe that trusts
    // the refname returns "refused" and KEEPS the claim: a stale authorization
    // for a ref this session no longer holds, the #608 destruction itself.
    const r10 = await ceremony("feat/608r10");
    expectTrue("R10 #608: ceremony → ALLOW", r10.renamed === undefined && r10.back === undefined, JSON.stringify(r10)?.slice(0, 200));
    execSync("git config branch.feat/608r10.remote origin && git config branch.feat/608r10.merge refs/heads/main",
      { cwd: hub, stdio: "ignore" });
    execSync("git update-ref -d refs/remotes/origin/main", { cwd: hub, stdio: "ignore" }); // `--prune` took it
    const r10up = execSync("git for-each-ref --format='%(upstream)' refs/heads/feat/608r10",
      { cwd: hub, encoding: "utf-8" }).trim();
    expectTrue("R10 #608 fixture: the upstream is configured but does NOT resolve, yet %(upstream) still prints a refname",
      r10up !== "" && r10up.includes("origin"),
      `%(upstream) printed ${JSON.stringify(r10up)}`);
    const r10soft = await callRun("git branch -d feat/608r10");
    expectTrue("R10 #608: soft `-d` with a GONE upstream → ADMITTED and git really DELETES it (falls back to HEAD)",
      r10soft === undefined && branchExists("feat/608r10") === false,
      `handler returned ${JSON.stringify(r10soft)?.slice(0, 240)}`);
    execSync(`git branch feat/608r10 ${mainSha()}`, { cwd: hub, stdio: "ignore" }); // sibling re-creates
    const r10stale = await callBashSafe("git branch -M main feat/608r10");
    expectTrue("R10 #608: that delete SPENT the claim (the probe tracks git, not the refname) → rename BLOCKS",
      !!r10stale && r10stale.block === true && String(r10stale.reason || "").includes(CLAIM_SPENT),
      `handler returned ${JSON.stringify(r10stale)?.slice(0, 240)}`);

    // R11 (review round-2 P2) — the M4 hub-disorder arm is an ADMISSION too, and
    // it sits ~200 lines BEFORE the M3 funnel. With the hub disordered, M4 routes
    // `git branch -D <non-checked-out>` through the #436 (B) carve-out and answers
    // "allowed", so a spend wired only to the funnel leaves the claim intact.
    const r11 = await ceremony("feat/608r11");
    expectTrue("R11 #608: ceremony → ALLOW", r11.renamed === undefined && r11.back === undefined, JSON.stringify(r11)?.slice(0, 200));
    writeFileSync(join(hub, "dirt-608.txt"), "untracked dirt → the hub reads disordered\n"); // M4 engages
    const r11del = await callBashSafe("git branch -D feat/608r11");
    expectTrue("R11 #608: with the hub disordered, `-D` of the pid's own branch is ADMITTED by M4's #436 carve-out",
      r11del === undefined, `handler returned ${JSON.stringify(r11del)?.slice(0, 240)}`);
    try { execSync("git branch -D feat/608r11", { cwd: hub, stdio: "ignore" }); } catch { /* the admitted command runs */ }
    rmSync(join(hub, "dirt-608.txt"), { force: true }); // back to a healthy hub before asserting
    execSync(`git branch feat/608r11 ${mainSha()}`, { cwd: hub, stdio: "ignore" }); // sibling re-creates
    const r11stale = await callBashSafe("git branch -M main feat/608r11");
    expectTrue("R11 #608: that admission spent the claim → rename onto the sibling's branch BLOCKS",
      !!r11stale && r11stale.block === true && String(r11stale.reason || "").includes(CLAIM_SPENT),
      `handler returned ${JSON.stringify(r11stale)?.slice(0, 240)}`);
  } catch (e) {
    expectTrue("#605 integration ran without throwing", false, String(e?.stack ?? e).slice(0, 400));
  } finally {
    process.chdir(prevCwd);
    if (savedAip === undefined) delete process.env.AGENT_INFRA_PATH; else process.env.AGENT_INFRA_PATH = savedAip;
    if (savedLocks === undefined) delete process.env.AGENT_LOCKS_DIR; else process.env.AGENT_LOCKS_DIR = savedLocks;
    for (const [v, val] of savedHatch) { if (val === undefined) delete process.env[v]; else process.env[v] = val; }
    try { rmSync(tmp, { recursive: true, force: true }); } catch { /* best-effort */ }
  }
}

await main();
// ⛔ THE AGGREGATE IS THE SHARED EMITTER'S (agent-infra#2723), never hand-rolled
// here. `extensions/shared/test-verdict.mjs` §3 reads the workflows the runner
// reads and, for every harness named there, requires the shared `reportVerdict`
// import AND call and refuses a hand-rolled `passed`/`failed` aggregate — which
// is how the merge rail attributes a red lane (`runner::<label>`) instead of
// failing the PR blind. WIRING THIS FILE INTO `ci.yml` is what brings it into
// that corpus (review round-4 F-1: the wiring landed and the aggregate stayed
// hand-rolled, reddening `test-verdict` on the PR lane).
// `vacuous` reports the whole-suite SKIP (a Node without
// stripTypeScriptTypes) as the failure it is — otherwise "nothing ran" exits 0
// and reads as green, the shape `test-unborn-head.mjs` refuses.
const vacuous = skip > 0 && pass === 0;
reportVerdict("test-m2-compound-ownership", pass, fail, { skip, red: vacuous });
if (vacuous) console.log("❌ the whole suite was SKIPPED — zero assertions ran, so this is not a pass");
process.exit(fail === 0 && !vacuous ? 0 : 1);
