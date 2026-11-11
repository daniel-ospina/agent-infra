// Regression tests for #506 — a push-delete spelling in a compound must not
// LAUNDER an unrelated legacy destructive verdict.
//
// THE DEFECT (measured, pre-fix). `classifyGitCommandDetailed`'s push matcher
// detected a delete spelling and then OVERWROTE the verdict unconditionally:
//
//     if (deleteIdx !== -1 || hasColonTargets || legacyVerdict === "block:push-delete") {
//       out.verdict = "block:push-delete";     // ← even when legacyVerdict was block:reset
//
// The legacy string verdict is assigned from the WHOLE command, so a compound
// `git reset --hard && git push origin --delete stale` classified
// `block:reset` in the frozen classifier and `block:push-delete` in the detailed
// one. The full path (index.ts) then handed the command to the #73
// coordinated-delete arm, whose allow-when-no-sibling-checkout return is
// `admitAfterM3()` — a return that SKIPS the LEGACY_BLOCK arm below it. Net
// effect, probe-verified before the fix: the hard reset RAN in the shared hub
// main checkout whenever the delete target happened to be checked out nowhere.
// `block:push-delete` is also the one verdict the ownership allowance would
// admit outright, so the laundering was wider than the #73 arm.
//
// The override predates #443; #443 (clean-hub `-d`/`--del`/`--del`-family parity)
// only extended the same laundering to the new spellings.
//
// THE FIX, in two halves — each pinned INDEPENDENTLY below:
//   (1) classify-git.mjs: a legacy destructive verdict is never overridden by a
//       delete spelling (the push family is unchanged — block:push-delete and
//       block:force-push still resolve to block:push-delete). The delete FACTS
//       (`isPushDelete` + `pushTargets`) are still recorded.
//   (2) index.ts: because the verdict is now the legacy one, the push-family
//       arms below can no longer see the delete targets — so the #73
//       sibling-checked-out block is run on them in an arm of its own, which can
//       only ADD a block and never returns an allow. Without it, part (1) alone
//       would silently WEAKEN #73 inside linked worktrees (where the legacy arm
//       is exempt by design).
//
// Run: node extensions/main-worktree-guard/test-506-legacy-delete-compound.mjs
//      node extensions/main-worktree-guard/test-506-legacy-delete-compound.mjs --mutations
import {
  cpSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { execSync } from "node:child_process";
import { fileURLToPath, pathToFileURL } from "node:url";
import { register, registerHooks, stripTypeScriptTypes } from "node:module";
import { reportVerdict } from "../shared/verdict.mjs";

const HERE = fileURLToPath(new URL(".", import.meta.url));
const INDEX_TS = join(HERE, "index.ts");
const REPO_EXTENSIONS = join(HERE, "..");
const MUTATIONS = process.argv.includes("--mutations");

let pass = 0, fail = 0, skip = 0;
function expectTrue(name, cond, detail = "") {
  console.log(`${cond ? "✅" : "❌"} ${name}${cond || !detail ? "" : ` — ${detail}`}`);
  cond ? pass++ : fail++;
}
function skipped(name, why) {
  console.log(`⏭️  ${name}: SKIPPED — ${why}`);
  skip++;
}
const show = (r) => (r === undefined ? "allowed" : `blocked: ${String(r?.reason ?? "").split("\n")[0]}`);
const blocked = (r) => !!r && r.block === true;

// ─────────────────────────────────────────────────────────────────────────
// Part A — CLASSIFIER: the legacy verdict survives the delete spelling.
// ─────────────────────────────────────────────────────────────────────────
console.log("── Part A: classifyGitCommandDetailed keeps the legacy verdict ──");
const cg = await import(pathToFileURL(join(HERE, "classify-git.mjs")).href);
const { classifyGitCommandDetailed, classifyGitCommand } = cg;

/** [label, command, want.verdict, want.isPushDelete, want.pushTargets?] */
const CLASSIFIER_PINS = [
  // #506 — the laundered compounds. `stale` is a delete target that the classifier
  // must still report (part 2 needs it) while the verdict stays the severe verb.
  ["A1 reset + --delete", "git reset --hard && git push origin --delete stale", "block:reset", true, ["stale"]],
  ["A2 reset + -d (#443 spelling)", "git reset --hard && git push origin -d stale", "block:reset", true, ["stale"]],
  ["A3 reset + :stale (colon spelling)", "git reset --hard && git push origin :stale", "block:reset", true, ["stale"]],
  ["A4 clean -fd + --delete", "git clean -fd && git push origin --delete stale", "block:clean", true, ["stale"]],
  ["A5 stash pop + -d", "git stash pop && git push origin -d stale", "block:stash-pop", true, ["stale"]],
  // The PATTERN-ORDER class: `push-delete` used to sit above force-checkout /
  // checkout-discard-all / checkout-branch / restore / stash-pop in the shared
  // priority list, so a compound LED by one of those five classified
  // `block:push-delete` in BOTH layers — a less severe verdict than the verb it
  // contains, and the #73 arm then returned its allow verdict. Fixed by moving
  // `push-delete` to the END of DESTRUCTIVE_GIT_PATTERNS (the array is a
  // priority list).
  ["A5b stash pop + --delete (pattern-order class)", "git stash pop && git push origin --delete stale", "block:stash-pop", true, ["stale"]],
  ["A6 checkout -f + --delete (pattern-order class)", "git checkout -f && git push origin --delete stale", "block:force-checkout", true, ["stale"]],
  ["A6b restore + --delete (pattern-order class)", "git restore . && git push origin --delete stale", "block:restore", true, ["stale"]],
  ["A6c checkout <branch> + --delete (pattern-order class)", "git checkout main && git push origin --delete stale", "block:checkout-branch", true, ["stale"]],
  ["A7 pull + :stale", "git pull && git push origin :stale", "block:pull", true, ["stale"]],
  // The push family is UNCHANGED by #506 — both push verdicts still resolve to
  // block:push-delete, and the #73 arm still owns them.
  ["A8 plain --delete", "git push origin --delete stale", "block:push-delete", true, ["stale"]],
  ["A9 plain -d", "git push origin -d stale", "block:push-delete", true, ["stale"]],
  ["A10 force-push + --delete", "git push -f origin --delete stale", "block:push-delete", true, ["stale"]],
  // Controls: no delete spelling ⇒ nothing about #506 may change these.
  ["A11 reset alone", "git reset --hard", "block:reset", false, []],
  ["A12 plain push", "git push origin main", "block:push", false, ["main"]],
  ["A13 merge + plain push", "git merge origin/main && git push origin main", "block:merge", false, []],
  // #506 review finding 1: `block:commit` is only produced when the classifier
  // PROVED there is no push invocation, so a delete spelling inside a commit
  // MESSAGE is text only. `hasPush` is the flag the consumer gates on; the
  // extractor's echo/comment over-match is why `pushTargets` stays empty here
  // while the string extractor still finds `main`.
  ["A16 commit message mentioning a -d delete",
    'git commit -m "revert: stop running git push origin -d main"', "block:commit", false, []],
  // A17 is the OTHER half of the same edge, and it is PRE-EXISTING, not #506's:
  // the frozen `push-delete` pattern is string-matched, so a `--delete` inside a
  // commit MESSAGE still yields the legacy verdict `block:push-delete` (the
  // documented echo/comment over-match). The detailed verdict therefore cannot
  // be `block:commit`, and index.ts's push-delete arm needs a non-empty
  // `pushTargets` — empty here, because there is no push invocation — so the
  // command is ALLOWED, matching the `-d` twin (B13/B13b).
  ["A17 commit message mentioning a --delete (pre-existing echo over-match)",
    'git commit -m "revert: stop running git push origin --delete main"', "block:push-delete", false, []],
];
for (const [label, cmd, verdict, isPushDelete, targets] of CLASSIFIER_PINS) {
  const d = classifyGitCommandDetailed(cmd);
  const ok = d.verdict === verdict && d.isPushDelete === isPushDelete &&
    (targets === undefined || JSON.stringify(d.pushTargets) === JSON.stringify(targets));
  expectTrue(`${label} → ${verdict}`, ok,
    `got verdict=${d.verdict} isPushDelete=${d.isPushDelete} pushTargets=${JSON.stringify(d.pushTargets)}`);
}
// `hasPush` — the flag index.ts's #506 arm is gated on (review finding 1). It is
// derived from the INVOCATION WALK, never from the string extractor, so it is
// the only thing that can tell a real push compound from a message that talks
// about one.
for (const [label, cmd, want] of [
  ["A18 hasPush TRUE for a real delete compound", "git reset --hard && git push origin --delete stale", true],
  ["A19 hasPush TRUE for a plain push", "git push origin main", true],
  ["A20 hasPush FALSE for a commit whose MESSAGE names a -d delete",
    'git commit -m "revert: stop running git push origin -d main"', false],
  ["A21 hasPush FALSE for a commit whose MESSAGE names a --delete",
    'git commit -m "revert: stop running git push origin --delete main"', false],
  ["A22 hasPush FALSE for a non-git command", "echo hi", false],
]) {
  const got = classifyGitCommandDetailed(cmd).hasPush === true;
  expectTrue(`${label} (hasPush=${want})`, got === want, `got hasPush=${got}`);
}
// The frozen string classifier — the layer part 2 of the fix DID change (the
// priority list is shared). A14 is a CONTROL, not a pin of that reorder: `reset`
// out-ranks `push-delete` in both orders, so no mutation of this diff can flip
// it. The reorder's real pins are A5b/A6/A6b/A6c and the behavioural B5.
for (const [label, cmd, want] of [
  ["A14 CONTROL (invariant under the reorder): frozen classifier says block:reset for the compound",
    "git reset --hard && git push origin --delete stale", "block:reset"],
  ["A15 frozen classifier still says block:push-delete for a plain delete",
    "git push origin --delete stale", "block:push-delete"],
  ["A15b PIN of the reorder: the frozen classifier names the LEAD verb, not the delete",
    "git stash pop && git push origin --delete stale", "block:stash-pop"],
]) {
  expectTrue(label, classifyGitCommand(cmd) === want, `got ${classifyGitCommand(cmd)}`);
}

// ─────────────────────────────────────────────────────────────────────────
// Part B — BEHAVIORAL: the real index.ts handler against a hermetic hub.
// ─────────────────────────────────────────────────────────────────────────
// The full path is where the laundering lands (a verdict is only a string; the
// harm is the hub command that RUNS), so the fixtures are a real hub, a real
// sibling worktree holding a branch, and a real session worktree.
if (typeof stripTypeScriptTypes !== "function" ||
    (typeof register !== "function" && typeof registerHooks !== "function")) {
  if (MUTATIONS) {
    expectTrue("M: the mutation leg REQUIRES the real index.ts loader", false,
      `node ${process.versions.node} lacks module.stripTypeScriptTypes (needs Node >= 22.13)`);
  } else {
    skipped("Part B/M: real index.ts load",
      `node ${process.versions.node} lacks module.stripTypeScriptTypes (needs Node >= 22.13)`);
  }
} else {
  const hooks = await import(new URL("./module-load-hooks.mjs", import.meta.url).href);
  if (typeof registerHooks === "function") registerHooks({ resolve: hooks.resolve, load: hooks.load });
  else register(new URL("./module-load-hooks.mjs", import.meta.url), import.meta.url);
  process.removeAllListeners("warning");

  const HATCH_VARS = ["AGENT_ALLOW_MAIN_EDITS", "ELDATO_ALLOW_MAIN_EDITS"];
  const savedEnv = new Map([...HATCH_VARS, "AGENT_INFRA_PATH", "AGENT_LOCKS_DIR"]
    .map((v) => [v, process.env[v]]));

  const tmp = realpathSync(mkdtempSync(join(tmpdir(), "guard-506-")));
  const hub = join(tmp, "hub");
  const wtHeld = join(tmp, "wt-held");
  const wtSession = join(tmp, "wt-session");
  const git = (args, cwd) => execSync(`git ${args}`, { cwd, stdio: "ignore" });
  const quiet = async (fn) => { const w = console.warn; console.warn = () => {}; try { return await fn(); } finally { console.warn = w; } };

  /** Load ONE copy of the extension (the real one, or a mutant copy) and return a
   *  `bash(dir, command)` driver. */
  async function loadGuard(indexPath) {
    const warnings = [];
    const realWarn = console.warn;
    console.warn = (...a) => warnings.push(a.map(String).join(" "));
    let mod;
    try { mod = await import(pathToFileURL(indexPath).href); } finally { console.warn = realWarn; }
    const handlers = new Map();
    mod.default({ on(name, fn) { if (!handlers.has(name)) handlers.set(name, []); handlers.get(name).push(fn); } });
    const toolCall = handlers.get("tool_call")?.[0];
    const sessionStart = handlers.get("session_start")?.[0];
    return {
      degradation: warnings.filter((w) => w.includes("[main-worktree-guard]") && w.includes("failed to load")),
      loaded: typeof toolCall === "function" && typeof sessionStart === "function",
      sessionStart: async (dir) => {
        const prev = process.cwd();
        process.chdir(dir);
        try { return await quiet(() => sessionStart({}, undefined)); } finally { process.chdir(prev); }
      },
      bash: async (dir, command) => {
        const prev = process.cwd();
        process.chdir(dir);
        try { return await quiet(() => toolCall({ toolName: "bash", input: { command } }, undefined)); }
        finally { process.chdir(prev); }
      },
    };
  }

  /** The pinned command set. `dir` selects the session's root (the shared hub or
   *  a linked worktree). `marker` is the guard-specific text the refusal must
   *  carry, so each row proves WHICH arm fired (the whole point of #506 — the
   *  legacy verdict and the #73 arm are different guards on the same command). */
  const PINS = [
    // ── the reported defect: hub session, delete target held NOWHERE ──
    { id: "B1", dir: "hub", expect: "block", marker: "(reset)",
      cmd: "git reset --hard && git push origin --delete stale",
      why: "#506: the hard reset must not be laundered by the delete spelling (--delete)" },
    { id: "B2", dir: "hub", expect: "block", marker: "(reset)",
      cmd: "git reset --hard && git push origin -d stale",
      why: "#506: the same laundering through the #443 -d spelling" },
    { id: "B3", dir: "hub", expect: "block", marker: "(reset)",
      cmd: "git reset --hard && git push origin :stale",
      why: "#506: the same laundering through the colon spelling" },
    { id: "B4", dir: "hub", expect: "block", marker: "(clean)",
      cmd: "git clean -fd && git push origin -d stale",
      why: "#506: any legacy destructive, not just reset" },
    { id: "B5", dir: "hub", expect: "block", marker: "(stash-pop)",
      cmd: "git stash pop && git push origin --delete stale",
      why: "#506: the stash family launders identically (pattern-order class)" },
    { id: "B5b", dir: "hub", expect: "block", marker: "(stash-pop)",
      cmd: "git stash pop && git push origin -d stale",
      why: "#506: … and through the #443 -d spelling (verdict-override class)" },
    // ⚠️ DECLARED NON-DISCRIMINATING (review round 3, measured): M3's branch-state
    // arm precedes every push arm and reads no verdict, so this row is INVARIANT
    // under both the override revert and the reorder revert. It is kept as
    // COVERAGE (that arm must keep firing ahead of the push arms) and is
    // deliberately absent from every expectRed list — the reorder's real pins are
    // A15b and B5.
    { id: "B5c", dir: "hub", expect: "block", marker: "Branch-state change blocked",
      cmd: "git checkout -f && git push origin --delete stale",
      why: "coverage: a force-checkout lead is refused by M3 before any push arm is consulted" },
    { id: "B6", dir: "hub", expect: "block", marker: "(reset)",
      cmd: "git reset --hard && git push origin main && git push origin --delete stale",
      why: "#506: the delete in a LATER segment must not launder either (extractor attribution)" },
    // ── controls: the fix must not become a blanket refusal ──
    { id: "B7", dir: "hub", expect: "allow",
      cmd: "git push origin --delete stale",
      why: "control: a delete of a branch held nowhere is still allowed (unchanged #73 semantics)" },
    { id: "B8", dir: "hub", expect: "block", marker: "(reset)",
      cmd: "git reset --hard",
      why: "control: the legacy arm itself is unchanged without a delete spelling" },
    { id: "B9", dir: "wt", expect: "allow",
      cmd: "git reset --hard",
      why: "control: the legacy arm's WORKTREE exemption is unchanged (a worktree is isolated)" },
    // ── part 2: the #73 sibling check survives inside a worktree ──
    { id: "B10", dir: "wt", expect: "block", marker: "checked out in",
      cmd: "git reset --hard && git push origin --delete held",
      why: "part 2: in a worktree the legacy arm is exempt, so the delete half must still hit #73" },
    { id: "B11", dir: "wt", expect: "allow",
      cmd: "git reset --hard && git push origin --delete stale",
      why: "part 2 control: the SAME compound with an unheld target stays allowed (B10 is #73, not a blanket)" },
    // ── review finding 1: a commit MESSAGE must not manufacture delete evidence ──
    { id: "B13", dir: "wt", expect: "allow",
      cmd: 'git commit -m "revert: stop running git push origin -d main"',
      why: "review finding 1: the extractor's only evidence is the MESSAGE text, and there is no push " +
           "invocation (`hasPush` false), so the #73 arm must not fire — and the `--delete` twin must " +
           "behave identically (B13b). CONTROL: B1 is the same session geometry with a REAL delete " +
           "compound and it still blocks, so an allow here is the arm's absence, not a dead guard" },
    { id: "B13b", dir: "wt", expect: "allow",
      cmd: 'git commit -m "revert: stop running git push origin --delete main"',
      why: "review finding 1: the spellings must not split — the `--delete` twin stays allowed too" },
    // ── review round 4: the arm must sit ABOVE the ownership allowance's admit ──
    // A `block:branch-force-delete` compound is admitted by the allowance
    // (targets ⊆ baseline ∪ pid-owned) before any arm below it can run, so while
    // the #506 arm sat lower, the delete half lost #73 entirely. These two rows
    // are the reachable discriminator: the hub session's OWN baseline name is a
    // target the allowance admits, and the hub holding it is exactly what #73
    // exists to refuse.
    { id: "B15", dir: "hub", expect: "block", marker: "checked out in",
      cmd: "git branch -D main; git push origin --delete main",
      why: "ordering pin: the delete half must reach #73 BEFORE the allowance admits the compound " +
           "(pre-hoist this was ADMITTED and the hub's own branch lost its upstream)" },
    { id: "B15b", dir: "hub", expect: "block", marker: "(branch-force-delete)",
      cmd: "git branch -D stale; git push origin --delete stale",
      why: "ordering control: with a target held NOWHERE the #73 check adds nothing and the legacy " +
           "arm still owns the verdict — the hoist did not turn the class into a #73 block" },
    // ── the EXTRACTOR FALLBACK's own pin (mutant 5) ──
    { id: "B14", dir: "wt", expect: "block", marker: "checked out in",
      cmd: "git reset --hard && git push origin main && git push origin --delete held",
      why: "#506: the delete lives in the SECOND push invocation, so `pushTargets` is empty and ONLY " +
           "the whole-command extractor can attribute it — the one row that pins that fallback" },
  ];

  /** The DEGRADED-state pins (#506 review finding 2). The degradation-fallback
   *  arm (`!branchOwnership || !classifierLoaded`) is a DIFFERENT guard with its
   *  own #73 clause, and nothing in the full-path rows above can reach it — so it
   *  gets its own tree (a copy WITHOUT `shared/branch-ownership.mjs`) and its own
   *  rows, and the load MUST report the degradation (asserted, so the rows cannot
   *  silently execute the full path and still read green). */
  const DEGRADED_PINS = [
    { id: "D1", dir: "wt", expect: "block", marker: "checked out in",
      cmd: "git stash pop && git push origin --delete held",
      why: "degraded arm: post-#506 the frozen verdict is block:stash-pop, so the #73 check must be " +
           "run by the new clause instead of the old block:push-delete arm" },
    { id: "D2", dir: "wt", expect: "allow",
      cmd: "git stash pop && git push origin --delete stale",
      why: "degraded arm control: the same compound with an UNHELD target is still worktree-exempt" },
    { id: "D3", dir: "hub", expect: "block", marker: "Destructive git command blocked",
      cmd: "git stash pop && git push origin --delete stale",
      why: "degraded arm control: in the hub the generic legacy block still fires" },
  ];

  const real = await loadGuard(INDEX_TS);
  expectTrue("B0: the real index.ts loads with no degradation warning and registers both handlers",
    real.loaded && real.degradation.length === 0,
    real.degradation.length > 0 ? real.degradation.join(" | ") : "tool_call/session_start handler missing");

  try {
    git(`init -q -b main "${hub}"`, tmp);
    git("config user.email t@t && git config user.name t", hub);
    writeFileSync(join(hub, "tracked.txt"), "x\n");
    git("add -A && git commit -qm init", hub);
    // `stale` is checked out NOWHERE (the laundering precondition: the #73 arm
    // finds no holder and returns its allow verdict).
    git("branch stale", hub);
    // `held` is checked out in a SIBLING worktree — the #73 hazard.
    git(`worktree add -q -b held "${wtHeld}"`, hub);
    // The session's own linked worktree.
    git(`worktree add -q -b feat/session "${wtSession}"`, hub);
    for (const v of HATCH_VARS) delete process.env[v];
    process.env.AGENT_INFRA_PATH = hub;
    process.env.AGENT_LOCKS_DIR = join(tmp, "locks");
    // Hub stays on main and CLEAN — the only legal hub state (M4).
    git("checkout -q main", hub);

    if (real.loaded) {
      await real.sessionStart(hub);       // hub session: baseline = main
      await real.sessionStart(wtSession); // linked-worktree session
    }
    const dirs = { hub, wt: wtSession };

    const results = new Map();
    for (const p of PINS) results.set(p.id, await real.bash(dirs[p.dir], p.cmd));

    for (const p of PINS) {
      const r = results.get(p.id);
      const ok = p.expect === "block" ? blocked(r) : r === undefined;
      expectTrue(`${p.id} ${p.expect === "block" ? "BLOCKED" : "ALLOWED"} — ${p.why}`,
        ok, `${JSON.stringify(p.cmd)} → ${show(r)}`);
      if (p.marker && blocked(r)) {
        expectTrue(`${p.id}: the refusal is the ${p.marker} arm (which guard fired)`,
          String(r.reason ?? "").includes(p.marker), show(r));
      }
    }
    // B10/B11 as a PAIR: same compound, same session, only the target differs —
    // so B10's block cannot be a blanket refusal of the compound.
    expectTrue("B12: B10/B11 differ ONLY by the delete target's checked-out state",
      blocked(results.get("B10")) && results.get("B11") === undefined,
      `B10 → ${show(results.get("B10"))}; B11 → ${show(results.get("B11"))}`);

    // ── the ORDERING implemented above is pinned structurally too ──
    // The behavioural B15 row pins the outcome; this pins the placement that
    // produces it, because a later edit can move one arm without changing any
    // row's answer on the day (the allowance's kind map is the thing that would
    // have to grow first). Read from the source text, not from behaviour.
    {
      const src = readFileSync(INDEX_TS, "utf8");
      const armAt = src.indexOf("// ── #506: delete spelling inside a LEGACY-DESTRUCTIVE compound ──");
      const allowAt = src.indexOf("// ── Ownership allowance (agent-infra main, own baseline branch) ──");
      const admitAt = src.indexOf("return admitAfterM3(); // on-baseline or unverifiable-but-exempt");
      expectTrue("O1: the #506 arm is placed ABOVE the ownership-allowance block (deny-wins order)",
        armAt !== -1 && allowAt !== -1 && armAt < allowAt,
        `arm@${armAt} allowance@${allowAt} — an admit is a RETURN, so anything below it is unreachable`);
      expectTrue("O2: the allowance's admit still sits below both (the pin reads the real arm)",
        admitAt !== -1 && armAt < admitAt, `arm@${armAt} admit@${admitAt}`);
    }

    // ── The DEGRADED path (#506 review finding 2) ──
    // A tree WITHOUT shared/branch-ownership.mjs: `branchOwnership` stays null, so
    // the `!branchOwnership || !classifierLoaded` arm owns the decision and the
    // full-path rows above cannot reach it. The degradation MUST be reported —
    // that assertion is what keeps these rows from silently re-testing the full
    // path (and it is the non-vacuity floor for the whole block).
    console.log("\n── Part D: the degradation-fallback arm (#506 finding 2) ──");

    /** Copy this extension (plus the shared modules index.ts imports) into a
     *  temp tree. `omit` drops a module (the degraded fixtures), `file`+`revert`
     *  applies ONE textual revert (the mutants). */
    function buildTree(label, { omit = [], file = null, revert = null } = {}) {
      const root = realpathSync(mkdtempSync(join(tmpdir(), `legacy-delete-${label}-`)));
      const ext = join(root, "extensions");
      mkdirSync(join(ext, "main-worktree-guard"), { recursive: true });
      mkdirSync(join(ext, "shared"), { recursive: true });
      for (const f of ["index.ts", "classify-git.mjs", "module-load-hooks.mjs"]) {
        cpSync(join(HERE, f), join(ext, "main-worktree-guard", f));
      }
      for (const f of ["print-mode.ts", "audit-log.ts", "tool-call-event.ts", "branch-ownership.mjs"]) {
        if (omit.includes(`shared/${f}`)) continue;
        cpSync(join(REPO_EXTENSIONS, "shared", f), join(ext, "shared", f));
      }
      let applied = false;
      if (file && revert) {
        const target = join(ext, "main-worktree-guard", file);
        const src = readFileSync(target, "utf8");
        const mutated = revert(src);
        applied = mutated !== src;
        writeFileSync(target, mutated);
      }
      return { root, index: join(ext, "main-worktree-guard", "index.ts"), applied };
    }

    /** Drive the DEGRADED_PINS against one tree and report each row. */
    async function runDegradedRows(built, label, { redCheck = null } = {}) {
      const guard = await loadGuard(built.index);
      expectTrue(`D0: [${label}] the tree really IS degraded (an extension warning was reported)`,
        guard.degradation.length > 0 || !guard.loaded,
        "no degradation was reported — the rows below would exercise the FULL path");
      if (!guard.loaded) return false;
      await guard.sessionStart(hub);
      await guard.sessionStart(wtSession);
      let allOk = true;
      for (const p of DEGRADED_PINS) {
        const r = await guard.bash(dirs[p.dir], p.cmd);
        const ok = p.expect === "block" ? blocked(r) : r === undefined;
        if (redCheck) {
          expectTrue(`M: [${label}] ${p.id} goes RED — ${p.why}`, redCheck(r), `under the mutant: ${show(r)}`);
          continue;
        }
        expectTrue(`${p.id} ${p.expect === "block" ? "BLOCKED" : "ALLOWED"} — ${p.why}`,
          ok, `${JSON.stringify(p.cmd)} → ${show(r)}`);
        if (!ok) allOk = false;
        if (p.marker && blocked(r)) {
          expectTrue(`${p.id}: the refusal is the ${p.marker} arm (which guard fired)`,
            String(r.reason ?? "").includes(p.marker), show(r));
        }
      }
      return allOk;
    }
    {
      const plain = buildTree("degraded-no-branch-ownership", { omit: ["shared/branch-ownership.mjs"] });
      try { await runDegradedRows(plain, "no branch-ownership"); }
      finally { rmSync(plain.root, { recursive: true, force: true }); }
    }

    // ── Part M — MUTATION EVIDENCE: each half of the fix is load-bearing ──
    if (MUTATIONS) {
      console.log("\n── Part M: mutation evidence (#506) ──");

      const MUTANT_PAIRS = [
        {
          // (1) the pre-fix override: the delete spelling overwrites ANY legacy
          // verdict again. Every hub pin must go from BLOCKED to allowed.
          label: "pre-fix verdict override",
          file: "classify-git.mjs",
          revert: (src) => src.replace(
            "      if (!legacyIsOtherDestructive) out.verdict = \"block:push-delete\";",
            "      out.verdict = \"block:push-delete\"; // MUTANT: pre-fix unconditional override",
          ),
          expectRed: ["B1", "B2", "B3", "B4", "B5"],
          // RED means "the hub command is ALLOWED again" — the laundering.
          redCheck: (r) => !blocked(r),
          // Measured non-discriminating rows, held here rather than claimed as
          // evidence: B6 (a reset lead out-ranks push-delete in the frozen
          // pattern list, so it never entered the override branch and LEGACY_BLOCK
          // caught it pre-fix too) and B10/B11 (a worktree reach region where the
          // pre-fix `block:push-delete` verdict still ran the #73 arm — that is
          // exactly the protection part 2 must not lose).
          expectGreen: ["B6", "B7", "B8", "B10", "B11", "B13", "B13b", "B14"],
          classifier: ["git reset --hard && git push origin --delete stale", "block:push-delete"],
        },
        {
          // (2) the index.ts arm removed: the legacy pins still block (LEGACY_BLOCK
          // is untouched), and the #73 worktree pin goes RED. Both directions are
          // asserted, so the two halves are shown to be INDEPENDENTLY load-bearing
          // rather than one arm standing in for the other.
          label: "#506 delete-target arm removed",
          file: "index.ts",
          revert: (src) => src.replace(
            '      if (det.hasPush === true &&\n          det.verdict !== "block:push-delete" &&',
            '      if (false && det.hasPush === true &&\n          det.verdict !== "block:push-delete" &&',
          ),
          expectRed: ["B10", "B14"],
          redCheck: (r) => !blocked(r),
          expectGreen: ["B1", "B2", "B3", "B4", "B5", "B6", "B11", "B13", "B13b"],
        },
        {
          // (3) THE REORDER REVERTED: `push-delete` back above `force-checkout` in
          // the shared priority list. This is the half that has no other mutant;
          // its pins are the frozen-layer A15b and the behavioural B5 (a `stash
          // pop` lead, which the old order swallowed into `block:push-delete`).
          label: "push-delete restored above force-checkout",
          file: "classify-git.mjs",
          revert: (src) => {
            const line = '  { name: "push-delete", re: /\\bgit\\s+push\\b[^;&|]*(--delete\\b|\\s:\\S+)/ },';
            const at = src.indexOf(line);
            if (at === -1) return src; // anchor dead → `applied` false, reported as a stale anchor
            const without = src.slice(0, at) + src.slice(at + line.length);
            const anchor = '  { name: "force-checkout", re: /\\bgit\\s+(checkout|switch)\\s+(-f|--force)\\b/ },\n';
            return without.replace(anchor, line + "\n" + anchor); // MUTANT: pre-#506 order
          },
          expectRed: ["B5"],
          redCheck: (r) => !blocked(r),
          expectGreen: ["B1", "B2", "B3", "B4", "B6", "B10", "B11", "B13", "B14"],
          classifier: ["git stash pop && git push origin --delete stale", "block:push-delete"],
        },
        {
          // (4) THE DEGRADED CLAUSE REMOVED (#506 review finding 2). Runs on its
          // OWN tree (no branch-ownership) because the clause only exists in the
          // degradation arm; D1 must go RED — allowed — the moment it is gone.
          label: "degraded #73 clause removed",
          file: "index.ts",
          omit: ["shared/branch-ownership.mjs"],
          revert: (src) => src.replace(
            '          (verdict.startsWith("block:") && rawDeleteNames.length > 0);',
            '          false; // MUTANT: #506 degraded clause removed',
          ),
          expectDegradedRed: ["D1"],
          expectDegradedGreen: ["D2", "D3"],
        },
        {
          // (6) THE hasPush GATE REMOVED (#506 review round 3, finding 2). Without
          // it the arm re-enters for a `block:commit`, the extractor supplies the
          // delete target from the commit MESSAGE, and B13/B13b go RED.
          label: "hasPush gate removed",
          file: "index.ts",
          revert: (src) => src.replace(
            "      if (det.hasPush === true &&\n          det.verdict !== \"block:push-delete\" &&",
            "      if (det.verdict !== \"block:push-delete\" &&",
          ),
          // MEASURED, and it corrects the review's prediction: only B13 (`-d`)
          // reddens. The `--delete` twin (B13b) is INVARIANT under this mutant —
          // the frozen echo over-match returns `block:push-delete` for it, which
          // the arm excludes by family, so the gate was never what kept B13b
          // green. Its partner is the parity assertion, not the gate.
          expectRed: ["B13"],
          // RED here means the commit was REFUSED on message text alone.
          redCheck: (r) => blocked(r) && String(r.reason ?? "").includes("checked out in"),
          expectGreen: ["B1", "B2", "B3", "B4", "B5", "B6", "B10", "B11", "B13b", "B14"],
        },
        {
          // (8) THE HOIST REVERTED (review round 4): the arm is moved back below
          // the ownership-allowance block, i.e. exactly where it sat when the
          // bypass was measured. B15 must go RED — the compound is ADMITTED — and
          // B15b stays green (the legacy arm still blocks it).
          label: "delete arm moved below the ownership allowance",
          file: "index.ts",
          revert: (src) => {
            const H = "      // ── #506: delete spelling inside a LEGACY-DESTRUCTIVE compound ──";
            const E = "      // ── Ownership allowance (agent-infra main, own baseline branch) ──";
            const D = "      // ── push --delete: retained #73 coordinated check (foreign targets) ──";
            const a = src.indexOf(H), b = src.indexOf(E), c = src.indexOf(D);
            if (a === -1 || b === -1 || c === -1 || !(a < b && b < c)) return src;
            const block = src.slice(a, b);
            return src.slice(0, a) + src.slice(b, c) + block + src.slice(c); // MUTANT: below the allowance
          },
          expectRed: ["B15"],
          redCheck: (r) => !blocked(r),
          expectGreen: ["B1", "B2", "B3", "B4", "B5", "B6", "B10", "B11", "B14", "B15b"],
        },
        {
          // (7) THE hasPush FLAG NEVER SET (classifier half of finding 2): the flag
          // is asserted on the mutant MODULE, and the arm it gates goes quiet —
          // which reds the two worktree #73 pins it exists to drive.
          label: "hasPush flag never set",
          file: "classify-git.mjs",
          revert: (src) => src.replace(
            "    out.hasPush = true; // #506: \"a real push invocation exists\" — see the doc block",
            "    // MUTANT: hasPush never set",
          ),
          classifierHasPush: ["git reset --hard && git push origin --delete stale", false],
          expectRed: ["B10", "B14"],
          redCheck: (r) => !blocked(r),
          expectGreen: ["B1", "B2", "B3", "B4", "B5", "B6", "B11", "B13", "B13b"],
        },
        {
          // (5) THE EXTRACTOR FALLBACK DELETED: a delete that lives in a LATER
          // compound segment loses its attribution, so B6 (reset → push main →
          // push --delete) stops running the #73 check. B6 was deliberately NOT
          // discriminating for the override mutant (it blocks either way), so
          // this is the mutant that pins the fallback itself.
          label: "extractor fallback removed",
          file: "index.ts",
          revert: (src) => src.replace(
            "        const legacyDeletes = det.pushTargets.length > 0\n          ? det.pushTargets\n          : (extractPushDeleteBranch(localCommand) ?? []);",
            "        const legacyDeletes = det.pushTargets; // MUTANT: no extractor fallback",
          ),
          // B6 still BLOCKS (LEGACY_BLOCK owns the reset) — the fallback's loss is
          // only visible where the legacy arm exempts, so the pin is B10's
          // later-segment analogue: a worktree compound whose delete is in the
          // SECOND push invocation. That row is B14 below, added for this mutant.
          expectRed: ["B14"],
          redCheck: (r) => !blocked(r),
          expectGreen: ["B6", "B10"],
        },
      ];

      for (const mut of MUTANT_PAIRS) {
        const built = buildTree(mut.label.replace(/[^a-z0-9]+/gi, "-"), mut);
        try {
          expectTrue(`M: [${mut.label}] the revert was actually applied (anchor is live)`, built.applied,
            "the anchor did not match — a stale anchor proves less than it claims");
          if (!built.applied) continue;
          if (mut.classifierHasPush) {
            const mutCg2 = await import(pathToFileURL(join(built.root, "extensions/main-worktree-guard/classify-git.mjs")).href);
            const got = mutCg2.classifyGitCommandDetailed(mut.classifierHasPush[0]).hasPush === true;
            expectTrue(`M: [${mut.label}] the mutant reports hasPush=${mut.classifierHasPush[1]} for a REAL push (defect reintroduced)`,
              got === mut.classifierHasPush[1], `got hasPush=${got}`);
          }
          if (mut.classifier) {
            // The classifier half is asserted on the mutant MODULE (the unit the
            // revert changes), so it holds even if the loader leg is unavailable.
            const mutCg = await import(pathToFileURL(join(built.root, "extensions/main-worktree-guard/classify-git.mjs")).href);
            const got = mutCg.classifyGitCommandDetailed(mut.classifier[0]).verdict;
            expectTrue(`M: [${mut.label}] the mutant classifies the compound ${mut.classifier[1]} (defect reintroduced)`,
              got === mut.classifier[1], `got ${got}`);
          }
          if (mut.expectDegradedRed) {
            const guard = await loadGuard(built.index);
            expectTrue(`M: [${mut.label}] the mutant extension loads ${mut.omit ? "DEGRADED" : "clean"}`,
              guard.loaded && (mut.omit ? guard.degradation.length > 0 : guard.degradation.length === 0),
              guard.degradation.join(" | ") || "no degradation reported");
            if (!guard.loaded) continue;
            await guard.sessionStart(hub);
            await guard.sessionStart(wtSession);
            for (const id of mut.expectDegradedRed) {
              const p = DEGRADED_PINS.find((x) => x.id === id);
              const r = await guard.bash(dirs[p.dir], p.cmd);
              expectTrue(`M: [${mut.label}] ${id} goes RED — ${p.why}`, !blocked(r), `under the mutant: ${show(r)}`);
            }
            for (const id of mut.expectDegradedGreen ?? []) {
              const p = DEGRADED_PINS.find((x) => x.id === id);
              const r = await guard.bash(dirs[p.dir], p.cmd);
              const ok = p.expect === "block" ? blocked(r) : r === undefined;
              expectTrue(`M: [${mut.label}] ${id} is unaffected`, ok, `under the mutant: ${show(r)}`);
            }
            continue;
          }
          const mutant = await loadGuard(built.index);
          expectTrue(`M: [${mut.label}] the mutant extension loads without degradation`,
            mutant.loaded && mutant.degradation.length === 0, mutant.degradation.join(" | "));
          if (!mutant.loaded) continue;
          await mutant.sessionStart(hub);
          await mutant.sessionStart(wtSession);
          for (const id of mut.expectRed) {
            const p = PINS.find((x) => x.id === id);
            const r = await mutant.bash(dirs[p.dir], p.cmd);
            expectTrue(`M: [${mut.label}] ${id} goes RED — ${p.why}`, mut.redCheck(r),
              `under the mutant: ${show(r)}`);
          }
          for (const id of mut.expectGreen ?? []) {
            const p = PINS.find((x) => x.id === id);
            const r = await mutant.bash(dirs[p.dir], p.cmd);
            const ok = p.expect === "block" ? blocked(r) : r === undefined;
            expectTrue(`M: [${mut.label}] ${id} is unaffected (the other half still holds)`, ok,
              `under the mutant: ${show(r)}`);
          }
        } finally {
          rmSync(built.root, { recursive: true, force: true });
        }
      }
    }
  } finally {
    for (const [k, v] of savedEnv) { if (v === undefined) delete process.env[k]; else process.env[k] = v; }
    rmSync(tmp, { recursive: true, force: true });
  }
}

process.removeAllListeners("warning");
reportVerdict("test-506-legacy-delete-compound", pass, fail, { skip });
process.exit(fail === 0 ? 0 : 1);
