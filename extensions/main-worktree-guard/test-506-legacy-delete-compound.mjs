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
];
for (const [label, cmd, verdict, isPushDelete, targets] of CLASSIFIER_PINS) {
  const d = classifyGitCommandDetailed(cmd);
  const ok = d.verdict === verdict && d.isPushDelete === isPushDelete &&
    (targets === undefined || JSON.stringify(d.pushTargets) === JSON.stringify(targets));
  expectTrue(`${label} → ${verdict}`, ok,
    `got verdict=${d.verdict} isPushDelete=${d.isPushDelete} pushTargets=${JSON.stringify(d.pushTargets)}`);
}
// The frozen string classifier is UNTOUCHED by #506 (it never had the override).
for (const [label, cmd, want] of [
  ["A14 frozen classifier still says block:reset for the compound",
    "git reset --hard && git push origin --delete stale", "block:reset"],
  ["A15 frozen classifier still says block:push-delete for a plain delete",
    "git push origin --delete stale", "block:push-delete"],
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
    { id: "B5c", dir: "hub", expect: "block", marker: "Branch-state change blocked",
      cmd: "git checkout -f && git push origin --delete stale",
      why: "#506: the force-checkout lead must block; the M3 branch-state arm owns it in a hub session " +
           "(pre-fix the laundered verdict never reached M3's verdict-independent arms — it returned allow first)" },
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

    // ── Part M — MUTATION EVIDENCE: each half of the fix is load-bearing ──
    if (MUTATIONS) {
      console.log("\n── Part M: mutation evidence (#506) ──");

      /** Copy this extension (plus the shared modules index.ts imports) into a
       *  temp tree and apply ONE textual revert to ONE file. */
      function buildMutant(label, file, revert) {
        const root = realpathSync(mkdtempSync(join(tmpdir(), `legacy-delete-mut-${label}-`)));
        const ext = join(root, "extensions");
        mkdirSync(join(ext, "main-worktree-guard"), { recursive: true });
        mkdirSync(join(ext, "shared"), { recursive: true });
        for (const f of ["index.ts", "classify-git.mjs", "module-load-hooks.mjs"]) {
          cpSync(join(HERE, f), join(ext, "main-worktree-guard", f));
        }
        for (const f of ["print-mode.ts", "audit-log.ts", "tool-call-event.ts", "branch-ownership.mjs"]) {
          cpSync(join(REPO_EXTENSIONS, "shared", f), join(ext, "shared", f));
        }
        const target = join(ext, "main-worktree-guard", file);
        const src = readFileSync(target, "utf8");
        const mutated = revert(src);
        const applied = mutated !== src;
        writeFileSync(target, mutated);
        return { root, index: join(ext, "main-worktree-guard", "index.ts"), applied };
      }

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
          expectGreen: ["B6", "B7", "B8", "B10", "B11"],
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
            '      if (det.verdict !== "block:push-delete" &&\n          det.verdict !== "block:push" && det.verdict !== "block:force-push") {',
            '      if (false && det.verdict !== "block:push-delete" &&\n          det.verdict !== "block:push" && det.verdict !== "block:force-push") {',
          ),
          expectRed: ["B10"],
          redCheck: (r) => !blocked(r),
          expectGreen: ["B1", "B2", "B3", "B4", "B5", "B6", "B11"],
        },
      ];

      for (const mut of MUTANT_PAIRS) {
        const built = buildMutant(mut.label.replace(/[^a-z0-9]+/gi, "-"), mut.file, mut.revert);
        try {
          expectTrue(`M: [${mut.label}] the revert was actually applied (anchor is live)`, built.applied,
            "the anchor did not match — a stale anchor proves less than it claims");
          if (!built.applied) continue;
          if (mut.classifier) {
            // The classifier half is asserted on the mutant MODULE (the unit the
            // revert changes), so it holds even if the loader leg is unavailable.
            const mutCg = await import(pathToFileURL(join(built.root, "extensions/main-worktree-guard/classify-git.mjs")).href);
            const got = mutCg.classifyGitCommandDetailed(mut.classifier[0]).verdict;
            expectTrue(`M: [${mut.label}] the mutant classifies the compound ${mut.classifier[1]} (defect reintroduced)`,
              got === mut.classifier[1], `got ${got}`);
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
