// Regression tests for #653 — the #73 coordinated-delete guard matched the
// delete target as TEXT, so whenever the target was produced by the SHELL the
// guard looked up a name no worktree can hold and ALLOWED the delete.
//
//   PR_BRANCH=$(gh pr view 645 --json headRefName -q '.headRefName')
//   git push origin --delete "$PR_BRANCH"
//     → extractor target `$PR_BRANCH`, no such ref, `_coordinatedDeleteBlock` → null
//     → index.ts push-delete arm → `return undefined` (ALLOW), delete runs.
//
// MEASURED on the pre-fix tree (this file's Part A pins the extraction half):
//   `git push origin --delete "$PR_BRANCH"`        → ["$PR_BRANCH"]   → ALLOW
//   `git push origin -d $(echo held/branch)`       → ["$(echo","held/branch)"] → ALLOW
//   `git push origin -d `cat list``                → ["`cat","list`"] → ALLOW
//   `git push origin -d {held,other}`              → ["{held,other}"] → ALLOW (brace expansion → TWO words)
//
// That is #73's protection defeated by ORDINARY shell usage — and the ceremony
// snippets in skills/commit-workflow assigned the branch to a variable first, so
// the documented path was the unmatched one.
//
// THE FIX IS #653's OPTION 2 (the issue names option 1 — resolve simple
// assignments — and option 2 — fail closed). Option 2 is taken because it closes
// the CLASS rather than one spelling of it: `$VAR`, `${X:-y}`, `$(…)`, backticks,
// brace and glob expansion all reach the guard as text, and option 1 would still
// leave every form it cannot resolve. `unresolvableDeleteTargets` (classify-git)
// decides resolvability, and index.ts `_coordinatedDeleteBlock` refuses BEFORE
// the checkout lookup — so the refusal holds in every arm that reaches that seam
// (the degradation arm, the push-delete arm, and the later-segment delete arm)
// and does not depend on a state read that may itself fail.
//
// ⛔ PR #3962 (open) is NOT this fix and must not be read as one: it stops the
// extractor reporting a substitution FRAGMENT (`$(echo`) as a ref name, but the
// arm still ALLOWS because the root is the unresolved TARGET.
//
// Run: node extensions/main-worktree-guard/test-653-delete-target.mjs
//      node extensions/main-worktree-guard/test-653-delete-target.mjs --mutations
import { execSync } from "node:child_process";
import { cpSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { register, registerHooks, stripTypeScriptTypes } from "node:module";
import { reportVerdict } from "../shared/verdict.mjs";

const HERE = fileURLToPath(new URL(".", import.meta.url));
const INDEX_TS = join(HERE, "index.ts");
const MUTATIONS = process.argv.includes("--mutations");

let pass = 0, fail = 0, skip = 0;
// ⛔ THE BEHAVIOURAL HALF IS THIS FILE'S POINT, so its absence is a FAILURE even
// when Part A's pure rows still passed. `skip > 0 && pass === 0` (the sibling
// harnesses' test) is NOT enough here: Part A runs before the loader check, so a
// Node without `stripTypeScriptTypes` would print "23 passed, 1 skipped" and exit
// 0 — green over a run where the shipped gate was never driven at all.
let behaviouralSkipped = false;
function expect(name, got, expected) {
  const ok = JSON.stringify(got) === JSON.stringify(expected);
  console.log(`${ok ? "✅" : "❌"} ${name}: ${JSON.stringify(got)}${ok ? "" : ` (expected ${JSON.stringify(expected)})`}`);
  ok ? pass++ : fail++;
}
function expectTrue(name, cond, detail = "") {
  console.log(`${cond ? "✅" : "❌"} ${name}${cond || !detail ? "" : ` — ${detail}`}`);
  cond ? pass++ : fail++;
}
function skipped(name, why) {
  console.log(`⏭️  ${name}: SKIPPED — ${why}`);
  skip++;
}

// ── Part A — the pure policy seam (classify-git.mjs) ──────────────────────
console.log("── Part A: unresolvableDeleteTargets (classify-git.mjs) ──");
const cg = await import(pathToFileURL(join(HERE, "classify-git.mjs")).href);
const { unresolvableDeleteTargets, isResolvableDeleteTarget, extractPushDeleteBranch } = cg;

// Resolvable = the extracted token IS the word git will be given. Everything the
// shell rewrites is not, and a literal non-empty ref name is.
for (const [name, target, want] of [
  ["literal short ref", "feat/x", true],
  ["literal full ref", "refs/heads/feat/x", true],
  ["literal remote-name over-capture", "origin", true],
  ["a legal comma in a ref name is NOT unresolvable", "release,2026", true],
  ["dots/dashes/underscores", "a-b_c.d", true],
  ["$VAR", "$PR_BRANCH", false],
  ["${VAR}", "${PR_BRANCH}", false],
  ["${VAR:-default}", "${BRANCH:-feat/x}", false],
  ["command-substitution fragment", "$(echo", false],
  ["backtick fragment", "`cat", false],
  ["glob", "feat/*", false],
  ["lone glob star", "*", false],
  ["brace expansion", "{feat/a,feat/b}", false],
  ["tilde", "~/x", false],
  ["backslash escape", "feat/x\\ y", false],
  ["empty", "", false],
]) {
  expect(`A: isResolvableDeleteTarget(${name})`, isResolvableDeleteTarget(target), want);
}
expect("A: the whole set is filtered, deduped", unresolvableDeleteTargets(["$A", "feat/x", "$A", "$(cat"]), ["$A", "$(cat"]);
expect("A: an all-literal set yields nothing to refuse", unresolvableDeleteTargets(["feat/x", "refs/heads/y"]), []);
expect("A: a non-array is inert (never throws into the gate)", unresolvableDeleteTargets(undefined), []);

// The EXTRACTION half — why the lookup never matched. These rows are the
// MEASURED pre-fix attribution, and they must keep showing that a substitution
// reaches the guard as text (a fragment for `$(…)`/backticks, the expansion
// source for `$VAR`). They are the reason the policy layer is needed even after
// #3962's fragment collapse: `null` targets would still ALLOW.
expect("A: $VAR extract", extractPushDeleteBranch(`git push origin --delete "$PR_BRANCH"`), ["$PR_BRANCH"]);
expect("A: $(…) extract (a FRAGMENT, not a ref)", extractPushDeleteBranch("git push origin -d $(echo held/branch)"), ["$(echo", "held/branch)"]);
expect("A: backtick extract (a FRAGMENT, not a ref)", extractPushDeleteBranch("git push origin -d `cat list`"), ["`cat", "list`"]);
expect("A: brace expansion extract (ONE token, shell makes TWO words)", extractPushDeleteBranch("git push origin -d {held,other}"), ["{held,other}"]);

// ── Part B — the SHIPPED gate (real index.ts tool_call handler) ───────────
if (typeof stripTypeScriptTypes !== "function" ||
    (typeof register !== "function" && typeof registerHooks !== "function")) {
  const msg = `node ${process.versions.node} lacks stripTypeScriptTypes (needs Node >= 22.13)`;
  if (MUTATIONS) expectTrue("M: the mutation leg REQUIRES the real index.ts loader", false, msg);
  else { behaviouralSkipped = true; skipped("Part B/M: real index.ts load", msg); }
} else {
  const hooks = await import(new URL("./module-load-hooks.mjs", import.meta.url).href);
  if (typeof registerHooks === "function") registerHooks({ resolve: hooks.resolve, load: hooks.load });
  else register(new URL("./module-load-hooks.mjs", import.meta.url), import.meta.url);
  process.removeAllListeners("warning");

  // HOME IS IN THIS LIST because the fixture REBINDS it (the hermetic ~/.pi/agent), and
  // the `finally` restore branches on `savedEnv.get("HOME")` — leaving it out DELETED the
  // real HOME instead of restoring it (review observation on PR #3978).
  const savedEnv = new Map(["AGENT_ALLOW_MAIN_EDITS", "ELDATO_ALLOW_MAIN_EDITS", "AGENT_INFRA_PATH", "AGENT_LOCKS_DIR", "HOME"]
    .map((v) => [v, process.env[v]]));
  const HATCH = ["AGENT_ALLOW_MAIN_EDITS", "ELDATO_ALLOW_MAIN_EDITS"];

  /** Load ONE copy of the extension (the real one, or a mutant copy) and return a
   *  bash driver bound to `cwd`. */
  async function loadGuard(indexPath, cwd) {
    const warnings = [];
    const realWarn = console.warn;
    console.warn = (...a) => warnings.push(a.map(String).join(" "));
    let mod;
    try { mod = await import(pathToFileURL(indexPath).href); } finally { console.warn = realWarn; }
    const handlers = new Map();
    mod.default({ on(name, fn) { if (!handlers.has(name)) handlers.set(name, []); handlers.get(name).push(fn); } });
    const toolCall = handlers.get("tool_call")?.[0];
    const sessionStart = handlers.get("session_start")?.[0];
    const bash = async (command) => {
      const prev = process.cwd();
      process.chdir(cwd);
      try { return await toolCall({ toolName: "bash", input: { command } }, undefined); }
      finally { process.chdir(prev); }
    };
    const start = async (at) => {
      const prev = process.cwd();
      process.chdir(at);
      try { await sessionStart({}, undefined); } finally { process.chdir(prev); }
    };
    return { bash, start, warnings, loaded: typeof toolCall === "function" };
  }

  const tmp = realpathSync(mkdtempSync(join(tmpdir(), "guard-653-")));
  const home = join(tmp, "home");
  mkdirSync(join(home, ".pi", "agent"), { recursive: true });
  const hub = join(tmp, "hub");
  const wt = join(tmp, "wt");
  const heldDir = join(tmp, "held");
  const quiet = async (fn) => { const w = console.warn; console.warn = () => {}; try { return await fn(); } finally { console.warn = w; } };
  const reasons = (r) => String(r?.reason ?? "");
  // The #653 refusal's OWN text — never a bare `block === true`, so an unrelated
  // gate that happens to refuse the command cannot satisfy these pins.
  const FAIL_CLOSED = "not a literal ref name";
  const HOLDS = "currently checked out";
  const refusedBy = (r, needle) => !!r && r.block === true && reasons(r).includes(needle);

  try {
    mkdirSync(hub, { recursive: true });
    execSync(`git init -q -b main "${hub}"`, { stdio: "ignore" });
    execSync("git config user.email t@t && git config user.name t", { cwd: hub, stdio: "ignore" });
    writeFileSync(join(hub, "tracked.txt"), "x\n");
    // `stale`/`stale2` exist as REAL branches nothing holds; `held` is checked
    // out in a sibling worktree, which is what the #73 check must still see.
    execSync("git add -A && git commit -qm init && git branch stale && git branch stale2 && git branch held",
      { cwd: hub, stdio: "ignore" });
    execSync(`git worktree add -q -b wtmain "${wt}"`, { cwd: hub, stdio: "ignore" });
    execSync(`git worktree add -q "${heldDir}" held`, { cwd: hub, stdio: "ignore" });
    writeFileSync(join(tmp, "branch-file"), "held\n");
    for (const v of HATCH) delete process.env[v];
    process.env.HOME = home;
    process.env.AGENT_INFRA_PATH = hub;
    process.env.AGENT_LOCKS_DIR = join(tmp, "locks");

    // ── Part B: the #653 class is REFUSED (hub-rooted session, on baseline) ──
    console.log("\n── Part B: the #653 class, through the shipped handler ──");
    const real = await loadGuard(INDEX_TS, hub);
    expectTrue("B0: the real index.ts loaded with a tool_call + session_start handler",
      real.loaded, JSON.stringify(real.warnings.filter((w) => w.includes("[main-worktree-guard]"))));
    await quiet(() => real.start(hub));

    // The issue's own repro, verbatim — the ceremony's `PR_BRANCH=$(gh …)` shape.
    expectTrue("B1 #653: the ISSUE REPRO `git push origin --delete \"$PR_BRANCH\"` → REFUSED (was ALLOW)",
      refusedBy(await quiet(() => real.bash(`git push origin --delete "$PR_BRANCH"`)), FAIL_CLOSED));
    // …and the refusal names the target it could not resolve, so the operator can act.
    const b1 = await quiet(() => real.bash(`git push origin --delete "$PR_BRANCH"`));
    expectTrue("B1b: the refusal NAMES the unresolved target (a block with no name is unactionable)",
      reasons(b1).includes("$PR_BRANCH"), reasons(b1).split("\n").slice(0, 3).join(" / "));

    const deny = [
      ["B2 #653: `-d` short spelling of the same form", `git push origin -d "$PR_BRANCH"`],
      ["B3 #653: `${VAR}` braced expansion", `git push origin --delete \${PR_BRANCH}`],
      ["B4 #653: COMMAND SUBSTITUTION `$(echo held/branch)` (a sibling-held ref, written indirectly)", `git push origin -d $(echo held/branch)`],
      ["B5 #653: BACKTICK substitution", "git push origin -d `cat list`"],
      ["B6 #653: substitution from a FILE that names the held branch", `git push origin -d "$(cat ${join(tmp, "branch-file")})"`],
      ["B7 #653: BRACE EXPANSION (the shell makes two words the guard never sees)", `git push origin -d {held,other}`],
      ["B8 #653: GLOB in the target", `git push origin -d 'feat/*'`],
      ["B9 #653: colon (empty-source) spelling carrying a variable", `git push origin :"$PR_BRANCH"`],
      ["B10 #653: an assignment in the SAME command is NOT resolved (the fix judges TEXT, it does not emulate the shell)", `BRANCH=stale && git push origin --delete "$BRANCH"`],
      ["B11 #653: LATER-SEGMENT delete in a compound (the wholeCommandDeleteTargets arm)", `git push origin main && git push origin -d "$PR_BRANCH"`],
      ["B12 #653: a benign lead segment must not launder the delete", `git status && git push origin --delete "$PR_BRANCH"`],
    ];
    for (const [name, cmd] of deny) {
      expectTrue(`${name} → REFUSED`, refusedBy(await quiet(() => real.bash(cmd)), FAIL_CLOSED),
        `handler returned ${JSON.stringify(await quiet(() => real.bash(cmd)))?.slice(0, 200)}`);
    }

    // ── Part C: NO FALSE BLOCK — the literal form is untouched ──────────────
    console.log("\n── Part C: the literal delete path is unchanged ──");
    for (const [name, cmd] of [
      ["C1: `--delete <literal>` of a branch nothing holds", "git push origin --delete stale"],
      ["C2: full-ref literal", "git push origin -d refs/heads/stale"],
      ["C3: colon literal", "git push origin :stale"],
      ["C4: `-d` of a branch nothing holds", "git push origin -d stale2"],
      ["C5: later-segment LITERAL delete in a compound", "git push origin main && git push origin -d stale"],
    ]) {
      const r = await quiet(() => real.bash(cmd));
      expectTrue(`${name} → ALLOWED (fail-closed must not become over-block)`, r === undefined,
        `handler returned ${JSON.stringify(r)?.slice(0, 200)}`);
    }

    // ── Part D: #73 still does its ORIGINAL job (the literal path) ──────────
    console.log("\n── Part D: #73's own protection survives ──");
    expectTrue("D1: a LITERAL delete of a sibling-checked-out branch → #73 BLOCK (its own reason text)",
      refusedBy(await quiet(() => real.bash("git push origin --delete held")), HOLDS));
    expectTrue("D2: the same, colon spelling → #73 BLOCK",
      refusedBy(await quiet(() => real.bash("git push origin :held")), HOLDS));
    expectTrue("D3: an UNRESOLVABLE delete of the same held branch is refused by #653's arm (not silently allowed)",
      refusedBy(await quiet(() => real.bash(`git push origin --delete "$(printf held)"`)), FAIL_CLOSED));

    // ── Part E: a WORKTREE session is NOT exempt ────────────────────────────
    // The #73 arm has never been worktree-exempt, and the fleet's lanes run from
    // worktrees — the case the issue's own ceremony hits first.
    console.log("\n── Part E: worktree-rooted session (the fleet's actual shape) ──");
    await quiet(() => real.start(wt));
    expectTrue("E1 #653: from a WORKTREE, `-d \"$PR_BRANCH\"` → REFUSED (the arm is not worktree-exempt)",
      refusedBy(await quiet(() => real.bash(`git push origin -d "$PR_BRANCH"`)), FAIL_CLOSED));
    expectTrue("E2 #653: from a WORKTREE, a literal delete of an unheld branch stays ALLOWED",
      (await quiet(() => real.bash("git push origin -d stale"))) === undefined);
    await quiet(() => real.start(hub));

    // ── Part F: the escape hatch still works (the remedy the message offers) ─
    console.log("\n── Part F: the documented override ──");
    process.env.AGENT_ALLOW_MAIN_EDITS = "1";
    expectTrue("F1: AGENT_ALLOW_MAIN_EDITS=1 still bypasses (the refusal is a guard, not a lock-out)",
      (await quiet(() => real.bash(`git push origin --delete "$PR_BRANCH"`))) === undefined);
    delete process.env.AGENT_ALLOW_MAIN_EDITS;

    // ── Part M — MUTATION EVIDENCE (--mutations) ────────────────────────────
    // A pin is only a pin if it can FAIL. The mutant reverts EXACTLY #653's
    // decision — `if (unresolved.length > 0)` → `if (false)` — in a TEMP copy, and
    // every Part B row must then be ALLOWED again. The real module must refuse
    // them in the same run, so a mutant that "passes" because the fixture broke
    // cannot be mistaken for evidence.
    if (MUTATIONS) {
      console.log("\n── Part M: mutation evidence (the pin can fail) ──");
      const src = readFileSync(INDEX_TS, "utf-8");
      const NEEDLE = "  if (unresolved.length > 0) {";
      if (!src.includes(NEEDLE)) {
        expectTrue("M1: the mutation target is present in index.ts (a stale anchor is a SKIP, never a green)", false,
          `missing ${JSON.stringify(NEEDLE)}`);
      } else {
        const mutDir = join(tmp, "ext-mutant");
        cpSync(join(HERE, ".."), mutDir, {
          recursive: true,
          filter: (p) => !p.includes("node_modules") && !p.endsWith(".git"),
        });
        const mutIndex = join(mutDir, "main-worktree-guard", "index.ts");
        writeFileSync(mutIndex, src.replace(NEEDLE, "  if (false) {"));
        const mut = await loadGuard(mutIndex, hub);
        expectTrue("M2: the mutant copy loaded (a mutation leg that cannot load proves nothing)", mut.loaded);
        await quiet(() => mut.start(hub));
        for (const [name, cmd] of [
          ["M3", `git push origin --delete "$PR_BRANCH"`],
          ["M4", `git push origin -d $(echo held/branch)`],
          ["M5", `git push origin -d {held,other}`],
          ["M6", `git push origin main && git push origin -d "$PR_BRANCH"`],
        ]) {
          const rm = await quiet(() => mut.bash(cmd));
          const rr = await quiet(() => real.bash(cmd));
          expectTrue(`${name} mutant: "${cmd.slice(0, 46)}" is ALLOWED without the #653 decision (it WENT RED) and REFUSED with it`,
            rm === undefined && refusedBy(rr, FAIL_CLOSED),
            `mutant ${JSON.stringify(rm)?.slice(0, 120)} / real ${JSON.stringify(rr)?.slice(0, 120)}`);
        }
        // The control: the mutant must NOT redden the literal rows — otherwise the
        // "redden exactly the pins it reverts" claim would be false.
        // ── M9/M10 — the SKEW path (review P1 of PR #3978) ──────────────────
        // A stale/short `classify-git.mjs` must leave the fail-safe DEFAULT, never
        // bind `undefined`: a destructuring-target binding did the latter and
        // THREW a TypeError out of `_coordinatedDeleteBlock` on every
        // delete-shaped command (`classifierLoaded` is still true — nothing threw
        // at import). The mutant here is that stale module: the new export is
        // gone, everything else is the shipped file.
        const skewDir = join(tmp, "ext-skew");
        cpSync(join(HERE, ".."), skewDir, {
          recursive: true,
          filter: (p2) => !p2.includes("node_modules") && !p2.endsWith(".git"),
        });
        const skewClassify = join(skewDir, "main-worktree-guard", "classify-git.mjs");
        {
          const cgSrc = readFileSync(skewClassify, "utf-8");
          const start = cgSrc.indexOf("export function unresolvableDeleteTargets(");
          const end = cgSrc.indexOf("\n}\n", start);
          expectTrue("M9: the skew mutant could be built (a stale-module row that cannot be built proves nothing)",
            start !== -1 && end !== -1);
          if (start !== -1 && end !== -1) {
            writeFileSync(skewClassify, cgSrc.slice(0, start) + cgSrc.slice(end + 3));
          }
        }
        const skew = await loadGuard(join(skewDir, "main-worktree-guard", "index.ts"), hub);
        expectTrue("M9b: the skewed module still LOADS (the export's absence must not be an import-time throw)",
          skew.loaded, JSON.stringify(skew.warnings.filter((w) => w.includes("main-worktree-guard"))).slice(0, 200));
        await quiet(() => skew.start(hub));
        let skewThrew = null;
        let skewLiteral = null;
        try {
          skewLiteral = await quiet(() => skew.bash("git push origin --delete held"));
        } catch (e) {
          skewThrew = String(e).slice(0, 160);
        }
        expectTrue("M10 (P1): under module skew a delete-shaped command does NOT throw — the fail-safe default holds",
          skewThrew === null, String(skewThrew));
        expectTrue("M10b (P1): and #73's own literal block still fires from the skewed module",
          refusedBy(skewLiteral, HOLDS), `handler returned ${JSON.stringify(skewLiteral)?.slice(0, 160)}`);
        let skewUnresolvedThrew = null;
        try {
          await quiet(() => skew.bash(`git push origin --delete "$PR_BRANCH"`));
        } catch (e) {
          skewUnresolvedThrew = String(e).slice(0, 160);
        }
        expectTrue("M10c (P1): the unresolvable form also does not throw under skew (it degrades to the pre-#653 ALLOW, which is what a stale module can know)",
          skewUnresolvedThrew === null, String(skewUnresolvedThrew));

        // ── M11 — the SAME skew, with the PRE-FIX BINDING (a destructuring target) ──
        // This is the discriminating half of M10: the absent export is bound as
        // `undefined` (a destructuring assignment overwrites the declared default),
        // so the seam THROWS instead of degrading. If M11 does not throw, M10 is
        // not measuring the binding and the P1 pin is dead weight.
        const skew2Dir = join(tmp, "ext-skew-destructure");
        cpSync(skewDir, skew2Dir, { recursive: true });
        const skew2Index = join(skew2Dir, "main-worktree-guard", "index.ts");
        {
          const iSrc = readFileSync(skew2Index, "utf-8");
          const guardBlock = `  if (typeof _m5.unresolvableDeleteTargets === "function") {\n    unresolvableDeleteTargets = _m5.unresolvableDeleteTargets;\n  }`;
          const destructureAnchor = "     extractPushDeleteBranch, wholeCommandDeleteTargets, getWorktreeBranches, isBranchInMainCheckout,";
          const built = iSrc.includes(guardBlock) && iSrc.includes(destructureAnchor);
          expectTrue("M11: the pre-fix-binding mutant could be built (a stale anchor is a failure, never a green)", built);
          if (built) {
            writeFileSync(skew2Index, iSrc
              .replace(guardBlock, "")
              .replace(destructureAnchor, destructureAnchor + "\n     unresolvableDeleteTargets,"));
          }
        }
        if (skew2Dir) {
          const skew2 = await loadGuard(skew2Index, hub);
          await quiet(() => skew2.start(hub));
          let preFixThrew = null;
          try {
            await quiet(() => skew2.bash("git push origin --delete held"));
          } catch (e) {
            preFixThrew = String(e).slice(0, 120);
          }
          expectTrue("M11 (P1, DISCRIMINATING): the destructuring binding THROWS under module skew — the shipped typeof guard does not",
            preFixThrew !== null, "no throw: the M10 row is not measuring the binding");
        }

        expectTrue("M7 mutant control: the literal delete of an unheld branch stays ALLOWED under the mutant",
          (await quiet(() => mut.bash("git push origin -d stale"))) === undefined);
        expectTrue("M8 mutant control: #73's own literal protection stays BLOCKED under the mutant",
          refusedBy(await quiet(() => mut.bash("git push origin --delete held")), HOLDS));
      }
    }
  } catch (e) {
    expectTrue("#653 suite ran without throwing", false, String(e?.stack ?? e).slice(0, 400));
  } finally {
    if (savedEnv.get("HOME") === undefined) delete process.env.HOME; else process.env.HOME = savedEnv.get("HOME");
    for (const v of ["AGENT_INFRA_PATH", "AGENT_LOCKS_DIR"]) {
      if (savedEnv.get(v) === undefined) delete process.env[v]; else process.env[v] = savedEnv.get(v);
    }
    for (const v of HATCH) {
      if (savedEnv.get(v) === undefined) delete process.env[v]; else process.env[v] = savedEnv.get(v);
    }
    rmSync(tmp, { recursive: true, force: true });
  }
}

// ⛔ THE EXIT CODE IS THE DELIVERABLE, AND IT IS NOT THE AGGREGATE's (review P0 of
// this PR, and it is the category-A shape: a suite that prints `❌` and exits 0).
// `reportVerdict` RETURNS the code — `verdict.mjs:96-98` says so in as many words
// ("the caller still owns `process.exit`") — so a harness that discards it is
// green over every failure, which makes BOTH ci.yml steps over this file inert,
// including the `--mutations` leg whose entire job is to prove the pins can fail.
// Same contract as the two siblings that gate on the same `stripTypeScriptTypes`
// capability (test-m2-compound-ownership.mjs, test-unborn-head.mjs): the 4th
// argument is `{ skip, red }` — NOT the bare `skip` number, whose `opts.skip` /
// `opts.red` reads are `undefined` and silently drop the `, N skipped` tail — and
// a run where the whole behavioural half was SKIPPED (`pass === 0`) is a FAILURE,
// never a clean pass.
const vacuous = (skip > 0 && pass === 0) || behaviouralSkipped;
reportVerdict("test-653-delete-target", pass, fail, { skip, red: vacuous });
if (vacuous) console.log("❌ the suite could not run its behavioral half (or ran NOTHING) — the shipped gate was never driven, so this is not a pass");
process.exit(fail === 0 && !vacuous ? 0 : 1);
