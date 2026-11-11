// Regression test for #744 — extensions/main-worktree-guard/index.ts must
// actually LOAD with its real classify-git.mjs bindings.
//
// Why the existing suite missed it: test.mjs imports classify-git.mjs
// directly, so it stays green while index.ts is broken. A 2026-09-10
// regression (#697) shipped a rename-destructuring assignment
// (`extractCodePayload: _extractCodePayload, …`) whose five `_`-prefixed
// targets were declared NOWHERE. Assigning to an undeclared identifier is a
// ReferenceError in ESM (always strict mode), it threw inside the module's
// load `try` block, the catch swallowed it, and every binding at or after the
// undeclared target kept its fail-safe default — silently degrading those gates
// in every session. A single stderr `console.warn` was the only signal:
//
//   [main-worktree-guard] ⚠️ classify-git.mjs failed to load — bash git guard
//   DISABLED: ReferenceError: _extractCodePayload is not defined
//
// This suite has two parts:
//
//   Part A — static scope tripwire (zero-dep, always runs)
//     Every destructuring-ASSIGNMENT target in index.ts must be a declared
//     binding somewhere in the file. Catches the exact #744 bug class in any
//     environment, including CI without node_modules.
//
//   Part B — real module load (Node >= 22.13)
//     index.ts is imported for real through ./module-load-hooks.mjs (type
//     stripping + a stubbed @earendil-works/pi-coding-agent — the same shapes
//     pi's jiti loader produces), then the registered tool_call handler is
//     driven against a hermetic MAIN checkout. The assertions are BEHAVIORAL
//     and hit each of the five rename targets:
//       B5  #627 code-interpreter payload gate  → extractCodePayload +
//           codePayloadGitVerdict (stubbed to allow when the import degrades)
//       B7  #436/#628 new-file carve-out + cap  → classifyUntrackedWip +
//           newFileWriteCollisionFree (gated on classifierLoaded) and
//           hubNewFileVolumeVerdict + HUB_NEW_FILE_BLOCK_CAP
//
// Run: node extensions/main-worktree-guard/test-module-load.mjs
import { execSync, spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync, realpathSync, rmSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { register, registerHooks, stripTypeScriptTypes } from "node:module";
import { reportVerdict } from "../shared/verdict.mjs";

const HERE = fileURLToPath(new URL(".", import.meta.url));
const INDEX_TS = join(HERE, "index.ts");

let pass = 0, fail = 0, skip = 0;
function expect(name, got, expected) {
  const ok = got === expected;
  console.log(`${ok ? "✅" : "❌"} ${name}: ${got}${ok ? "" : ` (expected ${expected})`}`);
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

// ─────────────────────────────────────────────────────────────────────────
// Part A — static tripwire: every destructuring-assignment target must be a
// declared binding somewhere in the file.
// ─────────────────────────────────────────────────────────────────────────

/** Blank block comments in place (newlines preserved → accurate line numbers). */
function blankBlockComments(src) {
  return src.replace(/\/\*[\s\S]*?\*\//g, (m) => m.replace(/[^\n]/g, " "));
}

/** Names introduced by a declaration somewhere in the file.
 *  LIMIT (documented): collects ANY depth, so a name declared only in a nested
 *  scope is not caught here — Part B is the scope-correct proof. This is a
 *  tripwire for "declared nowhere", which is what #697 shipped. */
function declaredNames(src) {
  const names = new Set();
  for (const m of src.matchAll(/^[ \t]*(?:let|const|var|function|class)[ \t]+([A-Za-z_$][\w$]*)/gm)) {
    names.add(m[1]);
  }
  for (const m of src.matchAll(/^[ \t]*import[ \t]+([\s\S]*?)[ \t]*from[ \t]*["'][^"']*["']/gm)) {
    let clause = m[1].replace(/^type[ \t]+/, "");
    const ns = clause.match(/^\*[ \t]+as[ \t]+([A-Za-z_$][\w$]*)/);
    if (ns) { names.add(ns[1]); continue; }
    const braced = clause.match(/\{([\s\S]*)\}/);
    if (braced) {
      for (const part of braced[1].split(",")) {
        const mm = part.trim().match(/^(?:type[ \t]+)?([A-Za-z_$][\w$]*)(?:[ \t]+as[ \t]+([A-Za-z_$][\w$]*))?$/);
        if (mm) names.add(mm[2] ?? mm[1]);
      }
      clause = clause.replace(/\{[\s\S]*\}/, "");
    }
    const def = clause.trim().match(/^([A-Za-z_$][\w$]*)/);
    if (def) names.add(def[1]);
  }
  return names;
}

/** Split `text` on `sep` at nesting depth 0. */
function splitTopLevel(text, sep = ",") {
  const parts = [];
  let depth = 0, cur = "";
  for (const ch of text) {
    if ("{[(".includes(ch)) depth++;
    else if ("}])".includes(ch)) depth--;
    if (ch === sep && depth === 0) { parts.push(cur); cur = ""; continue; }
    cur += ch;
  }
  parts.push(cur);
  return parts;
}

/** Collect assignment targets from an object-destructuring pattern body. */
function collectPatternTargets(pattern, out = []) {
  for (const raw of splitTopLevel(pattern)) {
    const piece = raw.trim();
    if (!piece) continue;
    const rest = piece.match(/^\.\.\.[ \t]*([A-Za-z_$][\w$]*)$/);
    if (rest) { out.push(rest[1]); continue; }
    const renamed = piece.match(/^([A-Za-z_$][\w$]*)[ \t]*:[ \t]*([\s\S]+)$/);
    if (renamed) {
      const value = renamed[2].trim();
      if (value.startsWith("{") || value.startsWith("[")) {
        const inner = value.slice(1, value.lastIndexOf(value.startsWith("{") ? "}" : "]"));
        collectPatternTargets(inner, out);
        continue;
      }
      const beforeDefault = splitTopLevel(value, "=")[0].trim();
      const ident = beforeDefault.match(/^([A-Za-z_$][\w$]*)/);
      if (ident) out.push(ident[1]);
      continue;
    }
    const plain = piece.match(/^([A-Za-z_$][\w$]*)[ \t]*(?:=[\s\S]*)?$/);
    if (plain) out.push(plain[1]);
  }
  return out;
}

/** Every identifier a `({ … } = expr)` ASSIGNMENT (not declaration) assigns
 *  into. Declarations (`const { x } = …`) are skipped — they cannot reference
 *  an undeclared target. */
function assignmentDestructureTargets(src) {
  const targets = [];
  for (let i = 0; i < src.length; i++) {
    if (src[i] !== "(" || src[i + 1] !== "{") continue;
    let depth = 0, j = i + 1;
    for (; j < src.length; j++) {
      if (src[j] === "{") depth++;
      else if (src[j] === "}") { depth--; if (depth === 0) break; }
    }
    if (j >= src.length || depth !== 0) continue;
    if (!/^[ \t]*=[ \t]*[^=]/.test(src.slice(j + 1, j + 12))) continue; // must be `} = value`
    if (/\b(?:let|const|var)[ \t]*$/.test(src.slice(Math.max(0, i - 16), i))) continue; // declaration
    for (const name of collectPatternTargets(src.slice(i + 2, j))) {
      targets.push({ name, line: src.slice(0, src.indexOf(name, i)).split("\n").length });
    }
  }
  return targets;
}

console.log("── Part A: static scope tripwire (index.ts) ──");
const src = blankBlockComments(readFileSync(INDEX_TS, "utf8"));
const declared = declaredNames(src);
const targets = assignmentDestructureTargets(src);
expectTrue("A1: found the module import destructuring assignment", targets.length > 0,
  "no `({ … } = …)` assignment pattern located in index.ts");
for (const t of targets) {
  expectTrue(`A2: destructuring-assignment target ${t.name} (line ${t.line}) is declared`, declared.has(t.name),
    "declared NOWHERE in the file — ESM strict mode throws ReferenceError at module load (#744)");
}
if (targets.length > 0 && targets.every((t) => declared.has(t.name))) {
  console.log(`     (${targets.length} assignment targets checked, all declared)`);
}

// ─────────────────────────────────────────────────────────────────────────
// Part A3 — the branch-ownership member-list invariant (#879), BOTH ways.
//
// #879: `index.ts` validates a hardcoded `_BRANCH_OWNERSHIP_MEMBERS` list
// before calling into the cached `shared/branch-ownership.mjs` namespace, so a
// STALE namespace (one imported by an earlier generation of index.ts, served
// from cache for the life of the host process) degrades to M1/M2/M3-OFF
// instead of throwing `… is not a function` from inside the tool hook — a
// throw that aborts the whole bash tool call and breaks every mutating git
// command.
//
// That protection is only as good as the list. If a call site uses a member
// the list omits, validation passes on the stale namespace and the crash
// returns. So pin it in both directions, statically, at zero cost:
//   A3a — every `branchOwnership.<member>` used in index.ts IS listed.
//   A3b — every listed member IS an exported function of the module.
//
// KNOWN LIMITATIONS (deliberate, documented rather than implied):
//   * A3a pins ONE SYNTACTIC SHAPE. A member reached as
//     `branchOwnership["x"]`, via an alias (`const b = branchOwnership; b.x()`),
//     through optional chaining, or used in ANOTHER FILE would not be caught.
//     Closing that needs a runtime backstop, not a bigger regex.
//   * Both directions are regex-based heuristics, so they can be fooled by
//     unusual comment/string shapes. They are a drift tripwire, not a proof.
// ─────────────────────────────────────────────────────────────────────────
function blankCommentsAndStrings(input) {
  // Strings first (so a `//` or `/*` INSIDE a string cannot corrupt the comment
  // pass), then block comments, then line comments. Templates/escapes are
  // handled crudely on purpose — this feeds a drift tripwire, not a parser.
  let out = input.replace(/(["'`])(?:\\.|(?!\1)[^\\\n])*\1/g, '""');
  out = blankBlockComments(out);
  out = out.replace(/\/\/[^\n]*/g, "");
  return out;
}
const srcCode = blankCommentsAndStrings(src);

const MEMBER_LIST_RE = /_BRANCH_OWNERSHIP_MEMBERS\s*=\s*\[([\s\S]*?)\]\s*as const/;
// NOTE: read the list from `src` (block-comments-blanked only) — the member
// names ARE string literals, so stripping strings would erase the list itself.
const memberListRaw = MEMBER_LIST_RE.exec(src)?.[1] ?? null;
const listedMembers = memberListRaw
  ? [...memberListRaw.matchAll(/["']([A-Za-z0-9_]+)["']/g)].map((m) => m[1])
  : [];
expectTrue("A3: located _BRANCH_OWNERSHIP_MEMBERS in index.ts", listedMembers.length > 0,
  "the validated member list could not be parsed — did it get renamed or reshaped?");

// A3a: every member access in index.ts must be validated before use.
const usedMembers = [...new Set([...srcCode.matchAll(/branchOwnership\s*\.\s*([A-Za-z0-9_]+)/g)].map((m) => m[1]))];
const unlisted = usedMembers.filter((m) => !listedMembers.includes(m));
expectTrue(`A3a: every branchOwnership.<member> used is validated (${usedMembers.length} used)`,
  unlisted.length === 0,
  `used but NOT in _BRANCH_OWNERSHIP_MEMBERS: ${unlisted.join(", ")} — a stale namespace would `
  + "pass validation and throw `is not a function` mid-hook, aborting the bash tool call (#879)");
if (unlisted.length === 0 && usedMembers.length > 0) {
  console.log(`     (${usedMembers.length} members used, all validated)`);
}

// A3b: every validated member must actually exist in the module. A wrong name
// here would silently DISABLE the guard on a healthy namespace — the opposite
// failure (fail-closed as fail-open).
const BO_MJS = join(HERE, "..", "shared", "branch-ownership.mjs");
const boSrc = blankCommentsAndStrings(readFileSync(BO_MJS, "utf8"));
const exportedFns = new Set(
  [...boSrc.matchAll(/export\s+(?:async\s+)?function\s+([A-Za-z0-9_]+)/g)].map((m) => m[1]));
const notExported = listedMembers.filter((m) => !exportedFns.has(m));
expectTrue(`A3b: every validated member is an exported function (${listedMembers.length} listed)`,
  notExported.length === 0,
  `listed but NOT an exported function of shared/branch-ownership.mjs: ${notExported.join(", ")} — `
  + "this would disable M1/M2/M3 on a HEALTHY namespace, failing open");
if (notExported.length === 0 && listedMembers.length > 0) {
  console.log(`     (${listedMembers.length} listed members, all exported)`);
}

// ─────────────────────────────────────────────────────────────────────────
// Part B — real module load + behavioral proof that the classify-git bindings
// are the real imports, not the fail-safe stubs.
// ─────────────────────────────────────────────────────────────────────────
console.log("\n── Part B: real index.ts module load + gate behavior ──");

const HATCH_VARS = ["AGENT_ALLOW_MAIN_EDITS", "ELDATO_ALLOW_MAIN_EDITS"];
const savedHatch = new Map(HATCH_VARS.map((v) => [v, process.env[v]]));

async function partB() {
  if (typeof stripTypeScriptTypes !== "function" ||
      (typeof register !== "function" && typeof registerHooks !== "function")) {
    skipped("B: real index.ts load",
      `node ${process.versions.node} lacks module.stripTypeScriptTypes (needs Node >= 22.13) — ` +
      "Part A still guards the bug class");
    return;
  }

  // ⚠️ test.mjs claims "index.ts is not importable in tests (pi-extension TS)" —
  // that assumption is why this regression shipped. index.ts IS importable; it
  // just needs (a) ES-module output despite the repo's `"type": "commonjs"`,
  // (b) the `.js`→`.ts` sibling mapping the TS sources use, and (c) the pi
  // runtime package. module-load-hooks.mjs supplies all three with zero deps,
  // so the REAL source (not a copy) is under test. registerHooks (>= 22.15) runs
  // in-thread and is preferred; worker-thread register() is the fallback.
  const hooks = await import(new URL("./module-load-hooks.mjs", import.meta.url).href);
  if (typeof registerHooks === "function") {
    registerHooks({ resolve: hooks.resolve, load: hooks.load });
  } else {
    register(new URL("./module-load-hooks.mjs", import.meta.url), import.meta.url);
  }

  // Hermetic HOME (#744 review): the guard's #207 escape marker lives at
  // ~/.pi/agent/.allow-main-edits and is keyed to PI_SESSION_ID. A live marker
  // in the operator's real HOME (the documented recovery step) exempts main
  // checkout mutations, which would make B6b's destructive op ALLOWED and turn
  // this suite falsely red. Point HOME at a throwaway dir before the module
  // loads, so the suite never reads the operator's marker/audit state.
  const prevHome = process.env.HOME;
  const prevCwd = process.cwd();
  let tmp = null;
  const fakeHome = realpathSync(mkdtempSync(join(tmpdir(), "guard-module-load-home-")));
  // Restores the caller's environment and removes the scratch dirs. Defined
  // before the B2/B3 bail-outs so those paths restore HOME/hatches too, not
  // just the main path's finally — a leaked fake HOME would otherwise outlive
  // the harness if this file were ever imported instead of run (#744 review).
  const cleanup = () => {
    process.chdir(prevCwd);
    for (const [v, val] of savedHatch) {
      if (val === undefined) delete process.env[v]; else process.env[v] = val;
    }
    if (prevHome === undefined) delete process.env.HOME; else process.env.HOME = prevHome;
    for (const d of [fakeHome, tmp]) {
      if (!d) continue;
      try { rmSync(d, { recursive: true, force: true }); } catch { /* best-effort */ }
    }
  };
  process.env.HOME = fakeHome;

  // stripTypeScriptTypes emits an ExperimentalWarning; this suite's own
  // pass/fail output is the signal, so drop Node's default warning printer.
  process.removeAllListeners("warning");

  // Load the real module with warnings captured — a clean load emits none.
  const warnings = [];
  const realWarn = console.warn;
  console.warn = (...args) => { warnings.push(args.map(String).join(" ")); };
  let mod;
  try {
    mod = await import(pathToFileURL(INDEX_TS).href);
  } catch (e) {
    // A rejected import must not leak the fake HOME or the env hatches.
    cleanup();
    throw e;
  } finally {
    console.warn = realWarn;
  }

  const degradation = warnings.filter((w) => w.includes("[main-worktree-guard]"));
  for (const w of degradation) console.log(`     captured: ${w}`);
  expect(`B1: index.ts loads with no degradation warning (warnings: ${warnings.length})`, degradation.length, 0);
  expect("B2: index.ts default export is the extension factory", typeof mod.default, "function");
  if (typeof mod.default !== "function") return cleanup();

  // Drive the factory: it registers exactly session_start + tool_call.
  const handlers = new Map();
  mod.default({ on(name, fn) { if (!handlers.has(name)) handlers.set(name, []); handlers.get(name).push(fn); } });
  const toolCall = handlers.get("tool_call")?.[0];
  expect("B3: factory registered a tool_call handler", typeof toolCall, "function");
  if (typeof toolCall !== "function") return cleanup();

  // Hermetic MAIN checkout: clean + on main, so nothing blocks for a reason
  // other than the binding under test.
  // realpath: on macOS tmpdir() is /var/... while git reports /private/var/...
  // (the guard realpaths its toplevel, so a non-realpath'd fixture would look
  // outside the hub and misjudge the carve-out).
  tmp = realpathSync(mkdtempSync(join(tmpdir(), "guard-module-load-")));
  const repo = join(tmp, "hub");
  try {
    execSync(`git init -q -b main "${repo}"`, { stdio: "ignore" });
    execSync("git config user.email t@t && git config user.name t", { cwd: repo, stdio: "ignore" });
    execSync("printf 'x\\n' > tracked.txt", { cwd: repo, stdio: "ignore" });
    // #1144 B9e/B9f: the M3 #376 return-to-original carve-out is AGENT-INFRA-ONLY,
    // so the fixture must FINGERPRINT as agent-infra (manifest.json +
    // pi-bootstrap/setup.sh — isAgentInfraRepo's repo fingerprint) for those
    // cases to reach the carve-out at all. Created BEFORE the init commit so the
    // hub stays CLEAN — untracked files would trip M4 and block every git op.
    execSync("mkdir -p pi-bootstrap", { cwd: repo, stdio: "ignore" });
    writeFileSync(join(repo, "manifest.json"), "{}\n");
    writeFileSync(join(repo, "pi-bootstrap", "setup.sh"), "#!/bin/sh\n");
    execSync("git add tracked.txt manifest.json pi-bootstrap/setup.sh", { cwd: repo, stdio: "ignore" });
    execSync("git commit -qm init", { cwd: repo, stdio: "ignore" });
    const dirty = execSync("git status --porcelain", { cwd: repo, encoding: "utf8" }).trim();
    expect(`B4: hermetic hub is clean on main (stray state: ${JSON.stringify(dirty)})`, dirty, "");

    // The env hatch is a full bypass — remove it for the duration (restored in finally).
    for (const v of HATCH_VARS) delete process.env[v];
    process.chdir(repo);

    const callBash = (command) => toolCall({ toolName: "bash", input: { command } }, undefined);
    const callWrite = (path) => toolCall({ toolName: "write", input: { path } }, undefined);

    // ── B5: #627 code-payload gate (extractCodePayload / codePayloadGitVerdict) ──
    // Pre-#744 the import degraded, so `extractCodePayload` stayed the
    // `() => null` stub and `_backdoorBlock` returned null. The legacy string
    // classifier ALSO misses this spelling (the argv array never contains a
    // literal `git reset --hard` token) — which is exactly the bypass #627
    // was written to close. Clean hub, so nothing else can block it.
    const payload = "require('child_process').execSync(['git','reset','--hard'].join(' '))";
    expect(`B5a: legacy classifier misses the argv-form payload (precondition)`,
      (await import(pathToFileURL(join(HERE, "classify-git.mjs")).href)).classifyGitCommand(`node -e "${payload}"`), "allow");
    const blocked = await callBash(`node -e "${payload}"`);
    expectTrue("B5: #627 gate BLOCKS an inline git payload (extractCodePayload is the real import)",
      !!blocked && blocked.block === true,
      `handler returned ${JSON.stringify(blocked)} — the fail-safe stubs are still bound (module degraded)`);

    // Negative control: the same surface must not blanket-block non-git code.
    const benign = await callBash("node -e \"console.log(1)\"");
    expectTrue("B6: a benign inline payload is still allowed (gate is not blanket-blocking)",
      benign === undefined, `handler returned ${JSON.stringify(benign)}`);

    // Coverage (issue #744 checklist): a destructive op is classified by the
    // LOADED extension end-to-end. Both the full and the degraded path block
    // this one, so it is not a discriminator — it pins that the wiring is live.
    const reset = await callBash("git reset --hard origin/main");
    expectTrue("B6b: `git reset --hard` is blocked by the loaded extension end-to-end",
      !!reset && reset.block === true, `handler returned ${JSON.stringify(reset)}`);

    // ── B9: #1144 — the shared-baseline sync allowance is EFFECT-shaped ──
    // The allowance is BASELINE-keyed, so the session baseline must be
    // recorded exactly as a real session records it: fire the registered
    // session_start handler on this clean hub.
    const sessionStart = handlers.get("session_start")?.[0];
    expect("B9pre: factory registered a session_start handler", typeof sessionStart, "function");
    if (typeof sessionStart === "function") await sessionStart({});

    // B9a — the reported defect, end-to-end through the loaded extension.
    // Before the #1144 fix the allowance consulted the VERB first and returned
    // undefined (ALLOWED): a `rebase` moved the SHARED baseline branch with no
    // hatch, while `reset --hard` (B6b) was refused.
    const rebaseShared = await callBash("git rebase origin/main");
    expectTrue("B9a: `git rebase origin/main` on the SHARED baseline branch is BLOCKED (#1144)",
      !!rebaseShared && rebaseShared.block === true,
      `handler returned ${JSON.stringify(rebaseShared)} — the verb-shaped allowance admitted a branch move`);
    expectTrue("B9a-msg: the refusal names the PERMITTED fast-forward forms, not only the hatch (#1144)",
      !!rebaseShared && /git pull --ff-only/.test(rebaseShared.reason ?? "")
      && /git merge --ff-only/.test(rebaseShared.reason ?? "")
      && /AGENT_ALLOW_MAIN_EDITS=1/.test(rebaseShared.reason ?? ""),
      `reason=${JSON.stringify(rebaseShared?.reason ?? "")}`);
    // #1239 (cross-lane): the env hatch cannot be set on a RUNNING pi process,
    // so the reachable remedy for an already-blocked agent is the TTL'd marker.
    // The refusal must name it (the pre-fix message offered only the unreachable
    // env form, leaving a blocked agent with no discoverable hatch).
    expectTrue("B9a-msg2: the refusal names the REACHABLE hatch (~/.pi/agent/.allow-main-edits) (#1239)",
      !!rebaseShared && /\.allow-main-edits/.test(rebaseShared.reason ?? ""),
      `reason=${JSON.stringify(rebaseShared?.reason ?? "")}`);
    // Print the new refusal verbatim — reviewers should read the text an agent
    // actually sees, not just the assertion name.
    console.log((rebaseShared?.reason ?? "(no reason)").split("\n").map((l) => `     | ${l}`).join("\n"));

    // B9b — per-repo scope: a session whose baseline is THIS hub must not
    // borrow the allowance to move ANOTHER repo's main (the allowance's own
    // comment says "agent-infra main", but it fired repo-agnostically).
    const otherHub = join(tmp, "other-hub");
    execSync(`git init -q -b main "${otherHub}"`, { stdio: "ignore" });
    execSync("git config user.email t@t && git config user.name t", { cwd: otherHub, stdio: "ignore" });
    writeFileSync(join(otherHub, "o.txt"), "o\n");
    execSync("git add o.txt && git commit -qm init", { cwd: otherHub, stdio: "ignore" });
    const crossRepo = await callBash(`git -C ${otherHub} pull --ff-only origin main`);
    expectTrue("B9b: a sync op in ANOTHER repo is not admitted by this session's baseline (#1144 scope)",
      !!crossRepo && crossRepo.block === true, `handler returned ${JSON.stringify(crossRepo)}`);

    // B9c — positive control: the allowance's genuine purpose survives.
    const ffOnly = await callBash("git pull --ff-only");
    expectTrue("B9c: `git pull --ff-only` on the session's own clean baseline stays ALLOWED (the allowance's purpose)",
      ffOnly === undefined, `handler returned ${JSON.stringify(ffOnly)}`);

    // B9d — compound closure. The classifier assigns the verdict from ONE verb
    // while `syncEffect` describes the FIRST sync invocation, so
    // `git pull --ff-only && git rebase origin/main` classifies block:rebase
    // with a fast-forward-looking effect record: an effect predicate that
    // trusts the first sync op would admit the WHOLE compound, rebase included.
    const compound = await callBash("git pull --ff-only && git rebase origin/main");
    expectTrue("B9d: a compound whose SECOND sync invocation rewrites is BLOCKED (#1144)",
      !!compound && compound.block === true && /#1144/.test(compound.reason ?? ""),
      `handler returned ${JSON.stringify(compound)} — the first sync op's effect was trusted for the whole command`);

    // B9e — the same class reached past the M3 carve-out: `checkout main` is the
    // sanctioned #376 return (agent-infra fingerprint on the fixture), and the M3
    // loop used to return undefined for the WHOLE command, so a later rewriting
    // segment rode along. The `#1144` marker in the reason proves the SYNC ARM
    // refused it (not some other arm blocking incidentally).
    const viaReturn = await callBash("git checkout main && git rebase origin/main");
    expectTrue("B9e: `checkout main && rebase` (sanctioned return + rewrite) is BLOCKED by the sync arm (#1144)",
      !!viaReturn && viaReturn.block === true && /#1144/.test(viaReturn.reason ?? ""),
      `handler returned ${JSON.stringify(viaReturn)} — the M3 carve-out swallowed a later rewriting segment`);

    // B9f — the DESTRUCTIVE twin of B9e: a `reset --hard` riding the sanctioned
    // return in an agent-infra hub (the hub this guard most protects). Refused by
    // the legacy destructive arm, so no `#1144` marker — just a hard block.
    const resetViaReturn = await callBash("git checkout main && git reset --hard origin/main");
    expectTrue("B9f: `checkout main && reset --hard` is BLOCKED (carve-out does not launder later segments)",
      !!resetViaReturn && resetViaReturn.block === true,
      `handler returned ${JSON.stringify(resetViaReturn)}`);

    // B9g — #1144 reviewer P0: `eff` is resolved from the state-mutating / first
    // invocation's hints, so a leading `git -C <worktree>` segment made
    // `eff.isWorktree` true and worktree-EXEMPTED a later sync op that actually
    // runs at the shell cwd (the `-C` binds only the first segment).
    const leadWt = join(tmp, "fixa-wt");
    execSync(`git worktree add -q "${leadWt}" -b wt/fixa HEAD`, { cwd: repo, stdio: "ignore" });
    const wtLead = await callBash(`git -C ${leadWt} status && git rebase origin/main`);
    expectTrue("B9g: a leading `-C <worktree>` segment must NOT exempt a later rebase running in the hub (#1144 P0)",
      !!wtLead && wtLead.block === true && /#1144/.test(wtLead.reason ?? ""),
      `handler returned ${JSON.stringify(wtLead)}`);

    // B9h — value-slot red team: `-m --ff-only` sets the merge MESSAGE; real git
    // performs a NON-fast-forward merge (rc 0, 2-parent commit). A presence-only
    // ff check admits it; the slot model must not.
    const msgSlot = await callBash("git merge -m --ff-only origin/main");
    expectTrue("B9h: `merge -m --ff-only` (value slot) is BLOCKED (#1144 value-slot red team)",
      !!msgSlot && msgSlot.block === true && /#1144/.test(msgSlot.reason ?? ""),
      `handler returned ${JSON.stringify(msgSlot)}`);

    // B9i — dynamic-token red team: the shell resolves `$(echo --no-ff)` AFTER the
    // guard's read, so the effective ff flag is unknown at decision time.
    const dyn = await callBash("git pull --ff-only $(echo --no-ff) origin main");
    expectTrue("B9i: a dynamic ff-family token is BLOCKED (`$(echo --no-ff)` — fail closed) (#1144)",
      !!dyn && dyn.block === true && /#1144/.test(dyn.reason ?? ""),
      `handler returned ${JSON.stringify(dyn)}`);

    // B9j — cycle-2 reviewer P0: the LEGACY destructive arm exempts worktrees via
    // `eff.isWorktree`, which one invocation supplies for the whole command. A
    // destructive segment after a leading `-C <worktree>` segment therefore ran
    // with the worktree exemption while moving the SHARED hub
    // (`git -C <wt> status && git reset --hard origin/main`). No `#1144` marker:
    // this is the legacy arm, not the allowance.
    const wtReset = await callBash(`git -C ${leadWt} status && git reset --hard origin/main`);
    expectTrue("B9j: a leading `-C <worktree>` segment must NOT exempt a later `reset --hard` in the hub (#1144 P0)",
      !!wtReset && wtReset.block === true,
      `handler returned ${JSON.stringify(wtReset)} — the whole command was worktree-exempted`);

    // B9j-cont — positive control: a genuinely worktree-isolated destructive op
    // stays exempt (every invocation resolves inside the worktree).
    const wtOnly = await callBash(`git -C ${leadWt} reset --hard origin/main`);
    expectTrue("B9j-cont: a wholly worktree-isolated `reset --hard` stays ALLOWED (exemption preserved)",
      wtOnly === undefined, `handler returned ${JSON.stringify(wtOnly)}`);

    // B9k — cycle-2 reviewer P2 (regression introduced by the value-slot model):
    // git scans a short cluster left-to-right, so `-Xours` carries its value
    // INSIDE the token and `--ff-only` is a real flag — the merge is a provable
    // fast-forward and must stay ALLOWED.
    const attached = await callBash("git merge -Xours --ff-only origin/main");
    expectTrue("B9k: `merge -Xours --ff-only` (attached short value) stays ALLOWED — no false block (#1144)",
      attached === undefined, `handler returned ${JSON.stringify(attached)} — over-consumed the value slot`);

    // B9l — cycle-2 reviewer P1a: `--mess` is an ABBREVIATED `--message`, so
    // real git makes `--ff-only` the merge MESSAGE and performs a
    // NON-fast-forward merge (probe rc 0, 2 parents). A value-option table
    // cannot mirror git's abbreviation parser; unlisted option shapes fail
    // closed instead.
    const abbrev = await callBash("git merge --mess --ff-only origin/main");
    expectTrue("B9l: `merge --mess --ff-only` (abbreviated value option) is BLOCKED (#1144 P1)",
      !!abbrev && abbrev.block === true && /#1144/.test(abbrev.reason ?? ""),
      `handler returned ${JSON.stringify(abbrev)} — an unlisted long option swallowed the ff token`);

    // B9m — cycle-2 reviewer P1b: `--gpg-sign`'s argument is OPTIONAL, so
    // parse-options does NOT consume a `-`-prefixed token; a value-option table
    // swallowed `--no-ff` and read the residual `--ff-only` as the effective
    // flag while real git honoured `--no-ff` (probe rc 0, merge commit).
    const optarg = await callBash("git merge --ff-only --gpg-sign --no-ff origin/main");
    expectTrue("B9m: `merge --ff-only --gpg-sign --no-ff` (optional-argument option) is BLOCKED (#1144 P1)",
      !!optarg && optarg.block === true && /#1144/.test(optarg.reason ?? ""),
      `handler returned ${JSON.stringify(optarg)} — an optional-argument option freed an ff token`);

    // B9n — cycle-2 reviewer P3 (regression introduced by the carve-out closure):
    // a refspec-LESS `git fetch` cannot write refs/heads/*, so the sanctioned
    // `checkout main` return followed by it must not be refused.
    const fetchAfter = await callBash("git checkout main && git fetch origin");
    expectTrue("B9n: `checkout main && git fetch origin` (no refspec) stays ALLOWED — no false block (#1144)",
      fetchAfter === undefined, `handler returned ${JSON.stringify(fetchAfter)} — refspec-less fetch treated as a write`);

    // B9o — the twin that MUST stay blocked: a refspec fetch DOES write refs.
    const fetchRefspec = await callBash("git checkout main && git fetch origin +main:refs/heads/main");
    expectTrue("B9o: `checkout main && fetch <refspec>` (writes refs) is BLOCKED — carve-out stays closed",
      !!fetchRefspec && fetchRefspec.block === true,
      `handler returned ${JSON.stringify(fetchRefspec)}`);

    // ── B9p–B9r: #1144 follow-up closures ────────────────────────────────
    // A second fresh-context adversarial reviewer found three INCOMPLETE
    // closures of classes already declared above (B6/B8/B9d). Each is driven
    // end-to-end here; each genuinely REDs at base 8bc92de (where the guard was
    // verb-shaped and had no hidden-substitution or per-invocation model).

    // B9p — the same class B9d closed, reached through a HIDDEN shell payload.
    // `eval "git rebase origin/main"` contributes no invocation, so the walk
    // saw exactly one (the pull) and `syncOnlyInvocation` claimed true: the
    // sync arm trusted the pull's fast-forward record and returned undefined
    // for the WHOLE command, letting the rebase move the shared branch. The
    // `#1144` marker proves the SYNC ARM (not some incidental arm) refused it.
    const evalRebase = await callBash('git pull --ff-only && eval "git rebase origin/main"');
    expectTrue("B9p: `pull --ff-only && eval \"rebase\"` is BLOCKED by the sync arm (#1144 B9d-hidden)",
      !!evalRebase && evalRebase.block === true && /#1144/.test(evalRebase.reason ?? ""),
      `handler returned ${JSON.stringify(evalRebase)} — the hidden payload rode the visible pull's ff effect`);
    const evalRebaseLead = await callBash('eval "git pull --rebase origin main" && git pull --ff-only');
    expectTrue("B9p2: a hidden rewriting pull BEFORE the ff pull is BLOCKED (#1144 B9d-hidden)",
      !!evalRebaseLead && evalRebaseLead.block === true && /#1144/.test(evalRebaseLead.reason ?? ""),
      `handler returned ${JSON.stringify(evalRebaseLead)}`);
    const evalCheckout = await callBash('git pull --ff-only && eval "git checkout main"');
    expectTrue("B9p3: `pull --ff-only && eval \"checkout main\"` is BLOCKED (#1144 B9d-hidden)",
      !!evalCheckout && evalCheckout.block === true && /#1144/.test(evalCheckout.reason ?? ""),
      `handler returned ${JSON.stringify(evalCheckout)}`);

    // B9q — B6's short value slot. `-o` is pull's `--server-option`, an
    // ARG-TAKER: the old short-option table omitted it, so `--ff-only` was read
    // as a live flag while real git consumed it as -o's VALUE and performed a
    // non-fast-forward pull (probe: rc 0, MERGE COMMIT, branch moved). The long
    // twin already failed closed; only the short letter was open.
    const shortO = await callBash("git pull -o --ff-only origin main");
    expectTrue("B9q: `pull -o --ff-only` is BLOCKED (#1144 B6o value slot)",
      !!shortO && shortO.block === true && /#1144/.test(shortO.reason ?? ""),
      `handler returned ${JSON.stringify(shortO)} — --ff-only was read as a flag instead of -o's value`);
    // …and the general rule behind the entry: an unenumerated short letter may
    // be an arg-taker this table does not know, so the proof fails closed. The
    // short/long asymmetry also self-heals (`-p` refused as `--prune` is).
    const shortUnknown = await callBash("git pull -Z --ff-only origin main");
    expectTrue("B9q2: an unenumerated short letter is BLOCKED (`pull -Z --ff-only`) (#1144 B6o general rule)",
      !!shortUnknown && shortUnknown.block === true && /#1144/.test(shortUnknown.reason ?? ""),
      `handler returned ${JSON.stringify(shortUnknown)}`);
    const shortP = await callBash("git pull --ff-only -p origin main");
    expectTrue("B9q3: `pull --ff-only -p` is BLOCKED (short twin of the refused `--prune`) (#1144 B6o)",
      !!shortP && shortP.block === true && /#1144/.test(shortP.reason ?? ""),
      `handler returned ${JSON.stringify(shortP)}`);

    // B9r — B8's worktree exemption, blinded by a hidden payload. `git -C <wt>
    // status && eval "git reset --hard origin/main"` walks to ONE invocation
    // (the worktree-scoped status), so `_allInvocationsWorktreeScoped` saw a
    // complete worktree-scoped list and the LEGACY arm exempted the whole
    // command — while the eval payload reset the SHARED hub. No `#1144` marker:
    // this is the legacy destructive arm, not the allowance.
    const evalReset = await callBash(`git -C ${leadWt} status && eval "git reset --hard origin/main"`);
    expectTrue("B9r: `-C <wt> status && eval \"reset --hard\"` is BLOCKED (#1144 B8-hidden)",
      !!evalReset && evalReset.block === true,
      `handler returned ${JSON.stringify(evalReset)} — the worktree exemption was blinded by the hidden payload`);
    const substReset = await callBash(`git -C ${leadWt} status && "$(git reset --hard origin/main)"`);
    expectTrue("B9r2: the `$(…)` twin is BLOCKED (#1144 B8-hidden)",
      !!substReset && substReset.block === true,
      `handler returned ${JSON.stringify(substReset)}`);
    // Positive control (re-asserted beside the new cases): a wholly
    // worktree-scoped destructive op still reports no hidden substitution and
    // stays exempt.
    const wtOnlyAgain = await callBash(`git -C ${leadWt} reset --hard origin/main`);
    expectTrue("B9r-cont: a wholly worktree-isolated `reset --hard` stays ALLOWED (#1144 B8-hidden control)",
      wtOnlyAgain === undefined, `handler returned ${JSON.stringify(wtOnlyAgain)}`);

    // ── B9s–B9t: #1144 cycle-3 reviewer closures ─────────────────────────
    // A third fresh-context adversarial reviewer reproduced the declared
    // classes one consumer over: `stateCarveOutClean` (the M3 #376
    // return-to-original carve-out) reasoned "the invocation list is the whole
    // command" WITHOUT consulting `hiddenStateSubst`, so a shell-hidden payload
    // rode the sanctioned return into the shared hub; and its read-only sibling
    // test was verb-only, so pure queries false-blocked the same ceremony.

    // B9s — the hidden payload riding the carve-out. `eval "…"`/`$(…)`
    // contributes NO invocation, so the visible list looked clean and the
    // carve-out closed the WHOLE command while the classifier's own verdict was
    // `block:reset`/`block:clean`/`block:rebase` — i.e. the evidence was
    // detected and the carve-out did not consult it. No `#1144` marker on the
    // reset/clean twins: they are refused by the legacy destructive arm.
    const evalResetReturn = await callBash('git checkout main && eval "git reset --hard origin/main"');
    expectTrue("B9s: `checkout main && eval \"reset --hard\"` is BLOCKED (#1144 B9-carve-out-hidden)",
      !!evalResetReturn && evalResetReturn.block === true,
      `handler returned ${JSON.stringify(evalResetReturn)} — the carve-out laundered a hidden reset`);
    const evalCleanReturn = await callBash('git checkout main && eval "git clean -fdx"');
    expectTrue("B9s2: `checkout main && eval \"clean -fdx\"` is BLOCKED (#1144 B9-carve-out-hidden)",
      !!evalCleanReturn && evalCleanReturn.block === true,
      `handler returned ${JSON.stringify(evalCleanReturn)} — the carve-out laundered a hidden clean`);
    const evalRebaseReturn = await callBash('git checkout main && eval "git rebase origin/main"');
    expectTrue("B9s3: `checkout main && eval \"rebase\"` is BLOCKED (#1144 B9-carve-out-hidden)",
      !!evalRebaseReturn && evalRebaseReturn.block === true,
      `handler returned ${JSON.stringify(evalRebaseReturn)} — the carve-out laundered a hidden branch move`);
    const subResetReturn = await callBash('git checkout main && $(git reset --hard origin/main)');
    expectTrue("B9s4: the `$(…)` twin riding the carve-out is BLOCKED (#1144 B9-carve-out-hidden)",
      !!subResetReturn && subResetReturn.block === true,
      `handler returned ${JSON.stringify(subResetReturn)}`);
    // The own-baseline RENAME arm re-baselines through the same carve-out, so it
    // was blind identically (`git branch -M main tmpname && eval "…"`).
    const renameEvalReset = await callBash('git branch -M main tmpname && eval "git reset --hard origin/main"');
    expectTrue("B9s5: the own-baseline RENAME arm does not launder a hidden payload (#1144 B9-carve-out-hidden)",
      !!renameEvalReset && renameEvalReset.block === true,
      `handler returned ${JSON.stringify(renameEvalReset)} — the rename re-baseline arm was blinded too`);

    // B9t — cycle-3 reviewer P2 (regression introduced by the carve-out
    // closure): `HUB_READONLY_VERBS` is verb-only, so the pure-query forms of
    // mixed verbs false-blocked the sanctioned return. These were ALLOWED at
    // base; the closure must not refuse them.
    const wtList = await callBash("git checkout main && git worktree list");
    expectTrue("B9t: `checkout main && worktree list` stays ALLOWED — no false block (#1144 P2)",
      wtList === undefined, `handler returned ${JSON.stringify(wtList)}`);
    const stashList = await callBash("git checkout main && git stash list");
    expectTrue("B9t2: `checkout main && stash list` stays ALLOWED — no false block (#1144 P2)",
      stashList === undefined, `handler returned ${JSON.stringify(stashList)}`);
    const tagList = await callBash("git checkout main && git tag");
    expectTrue("B9t3: `checkout main && tag` (list form) stays ALLOWED — no false block (#1144 P2)",
      tagList === undefined, `handler returned ${JSON.stringify(tagList)}`);
    const tagListFlag = await callBash("git checkout main && git tag -l");
    expectTrue("B9t4: `checkout main && tag -l` (explicit list flag) stays ALLOWED — no false block (#1144 P2)",
      tagListFlag === undefined, `handler returned ${JSON.stringify(tagListFlag)}`);
    // …while the MUTATING cousins of those same verbs stay gated (the
    // argument-scoped form is the discriminator, not the verb).
    const wtAdd = await callBash(`git checkout main && git worktree add ${join(tmp, "p2-wt")}`);
    expectTrue("B9t-cont: `checkout main && worktree add` stays BLOCKED (#1144 P2 control)",
      !!wtAdd && wtAdd.block === true, `handler returned ${JSON.stringify(wtAdd)}`);
    const tagCreate = await callBash("git checkout main && git tag v1");
    expectTrue("B9t-cont2: `checkout main && tag v1` (create) stays BLOCKED (#1144 P2 control)",
      !!tagCreate && tagCreate.block === true, `handler returned ${JSON.stringify(tagCreate)}`);
    const stashPush = await callBash("git checkout main && git stash");
    expectTrue("B9t-cont3: `checkout main && stash` (bare = push) stays BLOCKED (#1144 P2 control)",
      !!stashPush && stashPush.block === true, `handler returned ${JSON.stringify(stashPush)}`);

    // ── B9u: #1144 cycle-3 reviewer F1 — the carve-out's SIBLINGS ─────────
    // `_isCarveOutReadOnlyInvocation` returned true UNCONDITIONALLY for the
    // whole branch-state verb family (checkout/switch/symbolic-ref/update-ref/
    // branch), and index.ts returns from the whole handler at the first
    // `reBaseline`. So a LATER member of that family rode the sanctioned return:
    // `checkout main && switch -f feat/x` moved the SHARED hub off main and
    // `… && update-ref refs/heads/main HEAD` / `… && branch -M main stolen`
    // moved the BASELINE ref — with no hatch. The carve-out now exempts its OWN
    // invocation by identity and requires every OTHER invocation to be
    // provably read-only (each of these was ALLOWED at this head before the
    // fix, and is ALLOWED at base).
    const switchForce = await callBash("git checkout main && git switch -f feat/x");
    expectTrue("B9u1: `checkout main && switch -f <foreign>` is BLOCKED (carve-out does not admit a later switch) (#1144 F1)",
      !!switchForce && switchForce.block === true,
      `handler returned ${JSON.stringify(switchForce)} — the shared hub was moved off main`);
    const checkoutForce = await callBash("git checkout main && git checkout -f feat/x");
    expectTrue("B9u2: `checkout main && checkout -f <foreign>` is BLOCKED (#1144 F1)",
      !!checkoutForce && checkoutForce.block === true, `handler returned ${JSON.stringify(checkoutForce)}`);
    const checkoutOther = await callBash("git checkout main && git checkout feat/x");
    expectTrue("B9u3: a SECOND `checkout <foreign>` sibling is BLOCKED (#1144 F1)",
      !!checkoutOther && checkoutOther.block === true, `handler returned ${JSON.stringify(checkoutOther)}`);
    const updateRef = await callBash("git checkout main && git update-ref refs/heads/main HEAD");
    expectTrue("B9u4: `checkout main && update-ref refs/heads/main HEAD` is BLOCKED (baseline ref move) (#1144 F1)",
      !!updateRef && updateRef.block === true, `handler returned ${JSON.stringify(updateRef)}`);
    const branchMove = await callBash("git checkout main && git branch -M main stolen");
    expectTrue("B9u5: `checkout main && branch -M main stolen` is BLOCKED (baseline rename) (#1144 F1)",
      !!branchMove && branchMove.block === true, `handler returned ${JSON.stringify(branchMove)}`);
    const symrefWrite = await callBash("git checkout main && git symbolic-ref refs/heads/other HEAD");
    expectTrue("B9u6: `checkout main && symbolic-ref refs/heads/other HEAD` (ref write) is BLOCKED (#1144 F1)",
      !!symrefWrite && symrefWrite.block === true, `handler returned ${JSON.stringify(symrefWrite)}`);
    const branchForce = await callBash("git checkout main && git branch -f victim HEAD");
    expectTrue("B9u7: `checkout main && branch -f <victim> HEAD` is BLOCKED (force-create sibling) (#1144 F1)",
      !!branchForce && branchForce.block === true, `handler returned ${JSON.stringify(branchForce)}`);
    const branchDelete = await callBash("git checkout main && git branch -D victim9");
    expectTrue("B9u8: `checkout main && branch -D <victim>` is BLOCKED (delete sibling) (#1144 F1)",
      !!branchDelete && branchDelete.block === true, `handler returned ${JSON.stringify(branchDelete)}`);
    // Positive controls: the sanctioned return ITSELF and its provably
    // read-only siblings must keep passing (the exemption is identity-scoped,
    // not a blanket refusal of the state-verb family).
    const returnOnly = await callBash("git checkout main");
    expectTrue("B9u-cont1: `checkout main` alone stays ALLOWED (the sanctioned return itself) (#1144 F1 control)",
      returnOnly === undefined, `handler returned ${JSON.stringify(returnOnly)}`);
    const returnStatus = await callBash("git checkout main && git status");
    expectTrue("B9u-cont2: `checkout main && status` stays ALLOWED (read-only sibling) (#1144 F1 control)",
      returnStatus === undefined, `handler returned ${JSON.stringify(returnStatus)}`);
    const returnBranchList = await callBash("git checkout main && git branch");
    expectTrue("B9u-cont3: `checkout main && branch` (list form) stays ALLOWED (#1144 F1 control)",
      returnBranchList === undefined, `handler returned ${JSON.stringify(returnBranchList)}`);
    const returnSymrefQuery = await callBash("git checkout main && git symbolic-ref HEAD");
    expectTrue("B9u-cont4: `checkout main && symbolic-ref HEAD` (query) stays ALLOWED (#1144 F1 control)",
      returnSymrefQuery === undefined, `handler returned ${JSON.stringify(returnSymrefQuery)}`);

    // ── B9v: #1144 cycle-3 reviewer F3 — a REFUSED command must not re-baseline ──
    // `_rebaseline` used to run as soon as decideM3 sanctioned the carve-out,
    // BEFORE the later gates had decided. A refused compound therefore moved
    // `baselines[pid].branch` to the branch the refused checkout never selected,
    // and every later M1/M2/M3 decision keyed on that stale field. The
    // own-baseline RENAME arm is the observable: it re-baselines to the
    // renamed-to name, so a following 1-positional rename — git renames the
    // CURRENT branch, and the harness repo stays on `main` — is admitted iff the
    // recorded baseline is back to `main`.
    const renameOwn = await callBash("git branch -m main renamed");
    expectTrue("B9v-pre: own-baseline rename is ALLOWED and re-baselines to 'renamed' (#1144 F3 precondition)",
      renameOwn === undefined, `handler returned ${JSON.stringify(renameOwn)}`);
    const refusedReturn = await callBash("git checkout main && git reset --hard origin/main");
    expectTrue("B9v1: the refused return-compound is BLOCKED (#1144 F3 precondition)",
      !!refusedReturn && refusedReturn.block === true, `handler returned ${JSON.stringify(refusedReturn)}`);
    const renameAfterRefusal = await callBash("git branch -m renamed2");
    expectTrue("B9v2: a REFUSED compound did NOT re-baseline (baseline is still 'renamed') (#1144 F3)",
      !!renameAfterRefusal && renameAfterRefusal.block === true,
      `handler returned ${JSON.stringify(renameAfterRefusal)} — the refused checkout re-baselined to 'main'`);
    // Positive control: an ADMITTED return DOES apply the re-baseline (the
    // pending closure is deferred, never dropped). `checkout main` alone is the
    // sanctioned return, so the following 1-positional rename (from the current
    // branch `main`) is admitted because the baseline is `main` again.
    const admittedReturn = await callBash("git checkout main");
    expectTrue("B9v-cont1: the sanctioned return itself is ALLOWED (#1144 F3 control)",
      admittedReturn === undefined, `handler returned ${JSON.stringify(admittedReturn)}`);
    const renameAfterAdmitted = await callBash("git branch -m renamed3");
    expectTrue("B9v-cont2: an ADMITTED return DOES apply the re-baseline (rename from 'main' is admitted) (#1144 F3 control)",
      renameAfterAdmitted === undefined,
      `handler returned ${JSON.stringify(renameAfterAdmitted)} — the admitted return's re-baseline was dropped`);
    // Restore the original baseline for the remaining suites.
    const restoreBaseline = await callBash("git checkout main");
    expectTrue("B9v-cont3: baseline restored to the original for the remaining suites (#1144 F3 control)",
      restoreBaseline === undefined, `handler returned ${JSON.stringify(restoreBaseline)}`);

    // ── B9u2x: #601 — an M3-ALLOWED FIRST mutation must not launder a LATER
    // branch-state mutation (the end-to-end twin of the classify-layer pins in
    // test.mjs) ──────────────────────────────────────────────────────────
    // #601 was filed against a tree that predates #1144 (probe baseline
    // 657789f, 2026-09-08) and describes pre-#1144 index.ts exactly: it returned
    // from the WHOLE handler at the first `reBaseline`, so an M3-ALLOWED lead
    // (own-baseline rename / return-to-original / an ownership-allowed delete)
    // blessed every later segment — including a FOREIGN rename / force-create /
    // force-copy, the families with NO legacy verdict, for which M3 is the only
    // gate. #1144 (1ef8abb5d) made that return conditional on every OTHER
    // invocation being provably read-only (`stateCarveOutClean`), which closes
    // it. What is NEW here (review of this PR corrected an earlier "nothing pinned
    // it" claim: main already carries 8 e2e pins on the closure at B9u1–B9u8,
    // including exact launder shapes whose lead is a SWITCH): the own-baseline
    // RENAME lead end-to-end, on two different tail families, each row
    // independently reachable. Each row names the mutant that reddens it
    // (agent-infra#3442, MEASURED per row); #601's indicators 2–4 are NOT repeated
    // here because they are refused by arms that fire before the carve-out can
    // matter (#626's create-new arm; delete → `op "other"` skipped by the M3 loop)
    // — they cannot vary under any mutation of this fix and are already pinned by
    // #626 / #596 r4. The "a refused compound does not re-baseline" property is
    // B9v1/B9v2's, not this block's (see the note below the rows).
    //   M2 = index.ts's `if (det.stateCarveOutClean === true)` → `if (true)`
    //   M5 = `classify-git.mjs`'s carve-out identity exemption deleted
    //   M6 = `decideM3`'s #591 own-force carve-out removed; M7 = its stateOpCount bound deleted
    //   M8 = `decideM3`'s #376 return-to-original arm deleted
    const m601a = await callBash("git branch -Mq main rn601 ; git branch -Mq feat/x rn601b");
    expectTrue("#601 ind1: own-baseline rename + FOREIGN rename is BLOCKED [mutant: M2] — MEASURED: M2 admits it (undefined)",
      !!m601a && m601a.block === true,
      `handler returned ${JSON.stringify(m601a)} — a foreign ref was renamed behind the sanctioned own rename`);
    // ⛔ THE RESTORE IS LOAD-BEARING, not hygiene. Under M2 the row above is ADMITTED and
    // its pending re-baseline is applied, so the session baseline becomes `rn601`; the next
    // block row would then be refused by the FOREIGN-rename arm for the WRONG reason
    // (baseline mismatch) and would stay green under M2 — i.e. it would be a vacuous lock,
    // the exact class agent-infra#3442 forbids. Measured: without this line ind1b survives M2.
    // `git checkout main` returns to `baseline.original` under BOTH the correct code and M2,
    // so every block row below starts from a known baseline.
    // ⚠️ These two rows are PRECONDITIONS, not new closure coverage: `git checkout main →
    // undefined` is already pinned twice on main (B9u-cont1 and B9v-cont1). They are asserted
    // here only so the row that depends on them fails ATTRIBUTABLY (a broken restore must red
    // on the restore, not on the block row that inherits its drift) — do not count them as
    // added coverage of the #601 closure.
    const m601r1 = await callBash("git checkout main");
    expectTrue("#601 harness control: the baseline is re-established between the block rows [mutants: M5, M8]" +
      " — MEASURED: blocked under either (M5 by the legacy checkout-branch arm, M8 by the removed #376 arm)",
      m601r1 === undefined, `handler returned ${JSON.stringify(m601r1)}`);
    const m601b = await callBash("git branch -Mq main rn601b2 ; git branch -fq feat/other main");
    expectTrue("#601 ind1b: own rename + FOREIGN force-create is BLOCKED (a second tail family) [mutant: M2] — MEASURED: M2 admits it",
      !!m601b && m601b.block === true,
      `handler returned ${JSON.stringify(m601b)} — a foreign ref was force-created behind the sanctioned own rename`);
    const m601r2 = await callBash("git checkout main");
    expectTrue("#601 harness control: the baseline is re-established after the second block row [mutants: M5, M8]" +
      " — MEASURED: blocked under either",
      m601r2 === undefined, `handler returned ${JSON.stringify(m601r2)}`);
    // ⛔ NO ROW FOR "the refused compounds above did not re-baseline". An earlier draft had
    // one here; fresh-context review of this PR measured that it could not observe that
    // property (the restores above re-establish the baseline regardless) AND that its
    // claimed mutant could not redden it — under M5 the carve-out simply fails to close and
    // the command is admitted at index.ts's verdict arm (`det.verdict === "allow"` →
    // `admitAfterM3()`, which applies the pending re-baseline), so `undefined` still holds.
    // The property IS pinned, attributably, by the pre-existing B9v1/B9v2 pair
    // (a REFUSED compound leaves the follow-up rename blocked; an ADMITTED return admits it).
    // Citing that pair is the honest form; a duplicate here would be the dead weight #3442
    // forbids.
    const m601g = await callBash("git branch -fq main HEAD");
    expectTrue("#601 control: the single-invocation own-branch force-create carve-out survives (#591) [mutant: M6] — MEASURED: M6 blocks it",
      m601g === undefined, `handler returned ${JSON.stringify(m601g)}`);
    const m601h = await callBash("git branch side601b ; git branch -fq main HEAD");
    expectTrue("#601 control: benign lead + own force-create is still REFUSED (#591 stateOpCount bound holds) [mutant: M7] — MEASURED: M7 admits it",
      !!m601h && m601h.block === true, `handler returned ${JSON.stringify(m601h)}`);

    // ✅ RESIDUAL NOW CLOSED — #607's hidden-payload refusal (`index.ts`
    // `hiddenBranchStateRefusal`, reached through `admitAfterM3`) refuses any
    // UNENUMERABLE branch-state payload, which is exactly what this row recorded as
    // open. A HIDDEN shell tail (`$(…)`, backticks, `eval "…"`) still contributes
    // NO invocation, so `stateMutations` still keeps only the LEAD and the M3 loop
    // still has no second mutation to gate — but the command no longer reaches the
    // verdict arm unexplained: the refusal fires first (#805, fail closed).
    // INVERTED FROM A TRIPWIRE, per this row's own instruction ("invert it and cite
    // the fix; never delete it"). The citation is **#607**, not #656: #607's refusal
    // is what closes this class. #656's ROOT stays open for the
    // interpreter-CONSUMED family (`bash <<'EOF'`, `bash -c "$(…)"`, `$(…) | bash`),
    // which is #694's and is recorded there.
    const m601res = await callBash(`git branch -Mq main rn601res ; echo "$(git branch -Mq feat/601foreign rn601stolen)"`);
    expectTrue("#607 closes #601's #656-residual: a `$()`-hidden FOREIGN rename behind an M3-allowed lead is REFUSED (inverted from the tripwire, cited) [mutant: #607-M1 — `hiddenBranchStateRefusal` returns null] — MEASURED: admitted under M1, which is what this row asserted before #607",
      !!m601res && m601res.block === true,
      `handler returned ${JSON.stringify(m601res)} — a \`$(…)\`-hidden foreign rename behind a sanctioned lead was ADMITTED: the #656 residual is open again`);
    // ⛔ DELETED (#3442, round-6 finding F2): this block used to CREATE
    // `feat/601foreign` and rename it to `rn601stolen` with `execSync`, then assert the
    // ref existed — labelled "…so the admitted command moves a FOREIGN ref". Its whole
    // input was the test's OWN git calls: no guard module runs between the setup and the
    // assertion, so its value could not vary under ANY mutant of this diff, under the
    // pre-fix code, or under #656's eventual fix. By #3442's letter that is dead weight
    // that actively misleads, and its label drew a conclusion (the admitted command moves
    // a foreign ref) the test never demonstrated — it moved the ref itself. The
    // foreign-ness of the hidden tail is a property of the COMMAND SPELLING recorded in
    // the row above (`feat/601foreign` ≠ the baseline), not a measurement this suite has
    // to re-take. No replacement assertion: a real one would have to observe the guard.
    // The residual ROW above is the record; nothing here is #601 coverage.
    // The row above is now REFUSED, so nothing was applied: the guard's baseline was
    // NOT re-based to `rn601res` (that is the #1144 F3 property, on the hidden-payload
    // path). The control stays because the following suites require
    // `baseline.branch === "main"` on exit.
    const m601resR = await callBash("git checkout main");
    expectTrue("#601 ⚠️ RESIDUAL harness control: the fixture is back on main after the (now refused) row [mutants: M5, M8] — MEASURED: blocked under either",
      m601resR === undefined, `handler returned ${JSON.stringify(m601resR)}`);
    // ── FIXTURE HYGIENE PRECONDITION, NOT #601 EVIDENCE (#3442, round-6 finding F2) ──
    // The old row here said "back on main with no stray branch" but read ONLY `HEAD`, so
    // its "no stray branch" half was an unasserted claim sitting on a best-effort
    // `try/catch` delete. It now measures what it says: HEAD *and* the absence of the
    // purpose-made refs. It is deliberately invariant under every mutant of this diff —
    // it observes the FIXTURE the following suites need (`baseline.branch === "main"`),
    // not the guard — so it is labelled a precondition, is the one row in this block with
    // no mutation-attribution entry, and claims nothing about #601.
    const afterResidual = execSync("git rev-parse --abbrev-ref HEAD", { cwd: repo, encoding: "utf8" }).trim();
    const strayResidual = execSync("git branch --list 'rn601*' '601foreign'", { cwd: repo, encoding: "utf8" }).trim();
    expect(`#601 ⚠️ RESIDUAL precondition (fixture hygiene — NOT #601 coverage, no mutant can move it)`, `head=${afterResidual} stray=${strayResidual || "none"}`, "head=main stray=none");

    // ── B9w–B9z: #2277 — a lane rooted ELSEWHERE can advance a hub, but only
    // on a MEASURED fast-forward proof ────────────────────────────────────
    // Measured 2026-10-21 on the agent-infra hub itself: `0 ahead / 76 behind
    // origin/main`, clean, and BOTH lossless recovery verbs refused — so the
    // fleet ran a 76-commit-stale rail (#2264's `--expect-head` absent from the
    // checkout) and no lane rooted outside that repo could advance it. The
    // allowance required baseline.repoKey === the sync op's repoKey, which such
    // a lane can never satisfy; the arm now decides on a live measurement.
    const ffOrigin = join(tmp, "ff-origin.git");
    // #2581 — the bare repo is EMPTY, so the branch the clones below check out is named by
    // `init.defaultBranch` from the box's EFFECTIVE config (this suite replaces HOME before it
    // loads, so only the system/ambient channel reaches it). Where it is unset (a CI runner, a
    // fresh cell) git names it `master`, `git push -q origin main` below fails on the refspec, and
    // the suite reads as a regression. Name the branch in the FIXTURE (`-b main`), not on the box.
    execSync(`git init -q --bare -b main "${ffOrigin}"`, { stdio: "ignore" });
    const ffSeed = join(tmp, "ff-seed");
    execSync(`git clone -q "${ffOrigin}" "${ffSeed}"`, { stdio: "ignore" });
    execSync("git config user.email t@t && git config user.name t", { cwd: ffSeed, stdio: "ignore" });
    writeFileSync(join(ffSeed, "a.txt"), "a\n");
    execSync("git add a.txt && git commit -qm c1 && git push -q origin main", { cwd: ffSeed, stdio: "ignore" });
    const ffHub = join(tmp, "ff-hub");
    execSync(`git clone -q "${ffOrigin}" "${ffHub}"`, { stdio: "ignore" });
    execSync("git config user.email t@t && git config user.name t", { cwd: ffHub, stdio: "ignore" });
    // origin gains a commit the hub has NOT integrated → strictly behind.
    writeFileSync(join(ffSeed, "b.txt"), "b\n");
    execSync("git add b.txt && git commit -qm c2 && git push -q origin main", { cwd: ffSeed, stdio: "ignore" });
    execSync("git fetch -q origin", { cwd: ffHub, stdio: "ignore" });
    const ffBehindCount = execSync("git rev-list --count HEAD..@{upstream}", { cwd: ffHub, encoding: "utf8" }).trim();
    expectTrue(`B9w-pre: the foreign hub fixture is strictly BEHIND its upstream (commits behind: ${ffBehindCount})`,
      ffBehindCount === "1", `rev-list count = ${ffBehindCount}`);

    const ffForeign = await callBash(`git -C ${ffHub} pull --ff-only`);
    expectTrue("B9w: a lane with NO baseline for that repo CAN advance a clean, strictly-behind default branch (`git -C <hub> pull --ff-only`) (#2277)",
      ffForeign === undefined, `handler returned ${JSON.stringify(ffForeign)} — the measured proof was not admitted`);

    const ffExplicit = await callBash(`git -C ${ffHub} pull --ff-only origin main`);
    expectTrue("B9x: an EXPLICIT source ref is REFUSED on the foreign arm (the target must provably BE the upstream) (#2277)",
      !!ffExplicit && ffExplicit.block === true && /#1144/.test(ffExplicit.reason ?? ""),
      `handler returned ${JSON.stringify(ffExplicit)}`);

    const ffNoFf = await callBash(`git -C ${ffHub} pull`);
    expectTrue("B9x2: a bare `pull` on the foreign hub is REFUSED (not a provable fast-forward) (#2277)",
      !!ffNoFf && ffNoFf.block === true, `handler returned ${JSON.stringify(ffNoFf)}`);

    const ffEqual = join(tmp, "ff-equal");
    execSync(`git clone -q "${ffOrigin}" "${ffEqual}"`, { stdio: "ignore" });
    const ffUpToDate = await callBash(`git -C ${ffEqual} pull --ff-only`);
    expectTrue("B9y: an UP-TO-DATE checkout is REFUSED on the foreign arm (nothing to fast-forward — this is not a blanket allowance) (#2277)",
      !!ffUpToDate && ffUpToDate.block === true, `handler returned ${JSON.stringify(ffUpToDate)}`);

    writeFileSync(join(ffHub, "dirty.txt"), "x\n");
    const ffDirty = await callBash(`git -C ${ffHub} pull --ff-only`);
    expectTrue("B9y2: a DIRTY foreign hub is REFUSED (the clean-tree read covers the checkout the op MOVES) (#2277)",
      !!ffDirty && ffDirty.block === true, `handler returned ${JSON.stringify(ffDirty)}`);
    execSync("git clean -qfd", { cwd: ffHub, stdio: "ignore" });

    // A LOCAL branch with an upstream it is strictly behind: the ONLY reason to
    // refuse is that it is not the checkout's default branch (that is the
    // discriminator for the check).
    execSync("git checkout -q -b feat/local", { cwd: ffHub, stdio: "ignore" });
    execSync("git branch -q --set-upstream-to=origin/main feat/local", { cwd: ffHub, stdio: "ignore" });
    const ffBehindBranch = execSync("git rev-list --count HEAD..@{upstream}", { cwd: ffHub, encoding: "utf8" }).trim();
    expectTrue(`B9y3-pre: the non-default branch fixture is behind ITS OWN upstream (commits behind: ${ffBehindBranch})`,
      ffBehindBranch === "1", `rev-list count = ${ffBehindBranch}`);
    const ffOffBranch = await callBash(`git -C ${ffHub} pull --ff-only`);
    expectTrue("B9y3: a foreign hub on a NON-default branch is REFUSED (#2277)",
      !!ffOffBranch && ffOffBranch.block === true, `handler returned ${JSON.stringify(ffOffBranch)}`);
    // Back on the default branch, now DIVERGED (a local commit + one upstream
    // commit the local tip does not contain).
    execSync("git checkout -q main", { cwd: ffHub, stdio: "ignore" });
    writeFileSync(join(ffHub, "local.txt"), "l\n");
    execSync("git add local.txt && git commit -qm local-divergence", { cwd: ffHub, stdio: "ignore" });
    const ffDiverged = await callBash(`git -C ${ffHub} pull --ff-only`);
    expectTrue("B9z: a DIVERGED foreign hub is REFUSED (that is `hub-worktree.sh refresh`'s shape, not this arm) (#2277)",
      !!ffDiverged && ffDiverged.block === true && /#1144/.test(ffDiverged.reason ?? ""),
      `handler returned ${JSON.stringify(ffDiverged)}`);
    console.log((ffDiverged?.reason ?? "(no reason)").split("\n").map((l) => `     | ${l}`).join("\n"));

    // ═════════════════════════════════════════════════════════════════════
    // B607 — #607: (i) a branch-state git invocation hidden inside a shell
    // substitution / eval / alias payload is REFUSED, and (ii) M3 decides each
    // compound segment against the baseline the COMMAND itself has reached.
    // ═════════════════════════════════════════════════════════════════════
    // WHAT WAS MEASURED, at 6f508fc30, before either half was written — the
    // issue's own body is provenance-stale in one direction and too narrow in
    // the other:
    //
    //   (1) The LAUNDER the issue describes (a reBaseline-producing lead
    //       short-circuits M3, so a later foreign clobber rides it) is ALREADY
    //       CLOSED: #1144's `stateCarveOutClean` made that return conditional.
    //       The rows below that re-pin it are regression pins, not new closure —
    //       and they are pinned at the CLASSIFY layer (the 36-compound matrix)
    //       and end-to-end in peer PR #3968; they are repeated here only because
    //       THIS change rewrites the loop they run through, so the launder must
    //       be re-proved against the NEW decision path (that is the risk this
    //       block actually carries).
    //   (2) The HIDDEN-PAYLOAD class was a live category-A bypass, and needs no
    //       lead at all: `echo "$(git branch -Mq main victim)"` was ALLOWED (the
    //       substitution executes and clobbers `victim` rc 0) — and so was the
    //       same payload behind an M3-SANCTIONED lead, via backticks, and via
    //       `eval`. Nothing refused them: the extractor cannot enumerate a
    //       `$(…)`/backtick/`eval` payload, so the M3 loop gates only the VISIBLE
    //       mutations (`hiddenStateSubst` reaches only the #591 carve-out).
    //   (3) The FALSE BLOCK the issue's "Suggested fix" names: every segment was
    //       judged against the SESSION baseline, so the legitimate two-segment
    //       rename ceremony (`git branch -M main tmpA && git branch -M tmpA main`)
    //       was BLOCKED — segment 2's source is not the session baseline.
    //
    // MUTANTS this block was MEASURED against (each row names the one that reddens
    // it):
    //   M1 = index.ts `hiddenBranchStateRefusal`'s first line neutered (`return null`)
    //   M2 = the prospective baseline dropped (`const prospective = undefined`)
    //   M3 = the #607 freed-name relaxation deleted (dst probe as before)
    //   M3i = `renameDstExists: dstExists` → `false` (the pre-#598 decision: no dst
    //         existence check at all) — the non-vacuity arm for the launder rows
    //   M8 = `admitAfterM3` applies `pendingRebaselines` BEFORE the hidden refusal (the
    //         #1144 F3 ordering this diff guarantees) — reddens the baseline-stability row
    //   M9 = the collector WITHOUT single-quote masking (the round-4 quoting false block)
    //         — reddens the two single-quoted rows
    //   M9b = `_stripQuotedHeredocBodies` removed from the precise predicate — reddens
    //         the quoted-heredoc row (MEASURED pre-fix: that row reported true)
    //   M6 = `hiddenStateMutation` recomputed from the CONSERVATIVE
    //         `_hasHiddenStateSubst` (the pre-review head's predicate) — reddens the
    //         read-only rows below, i.e. the false-block class findings 1/2 named
    //   M4 = a WORKTREE EXEMPTION RE-ADDED to `hiddenBranchStateRefusal` — the
    //         non-vacuity arm for the worktree + cross-repo + bought-exemption rows.
    //         MEASURED: every one of them is ADMITTED under it. That mutant is not
    //         hypothetical — TWO exemption designs were measured open by
    //         fresh-context review before this head (session-cwd, then span
    //         attribution); the rows are the pin against a third.
    // Every mutant was APPLIED to a copy of index.ts and the whole suite re-run;
    // the row names state what each one does to them. A row that CANNOT vary under
    // any of them says so and names why (refused by an arm this change only
    // feeds), rather than borrowing a mutant it was measured green under — the
    // fabricated-discriminator failure #3442 exists to stop.
    // The rows run in Part B's OWN hub (`repo`, baseline `main` recorded at B9pre
    // by the registered session_start), NOT in a second fixture. The guard records
    // ONE baseline per pid (`if (state && !baselines.has(pid))`), so a second
    // session_start cannot re-point it at another repo — MEASURED: with a fresh
    // fixture the carve-out refused every row with "this rename runs in a
    // different checkout than the one that recorded this session's baseline"
    // (repoKey mismatch), i.e. each row would have exercised the WRONG arm.
    // PLACEMENT is load-bearing for the same reason: this block sits where the hub
    // is still clean+main — B8h/B8i write untracked files into it, B7 dirties it,
    // and M4 freezes every git op on a disordered hub.
    const g607 = (c, cwd = repo) => execSync(c, { cwd, stdio: "ignore" });
    // FOREIGN branches the adversarial rows rename/force-create onto. `victim` sits
    // at a DISCRIMINATING commit (its own commit, not `main`'s tip), so a clobber
    // would be visible in the repo, not only in the verdict.
    g607("git checkout -q -b tmpVictim607 && printf 'v\\n' > v607.txt && git add v607.txt && git commit -qm victim607 && git checkout -q main && git branch victim tmpVictim607 && git branch -D tmpVictim607");
    g607("git branch feat/other main");
    expect(`#607 fixture: the hub is clean on main (branches: ${execSync("git branch --format='%(refname:short)'", { cwd: repo, encoding: "utf8" }).trim().split("\n").sort().join(",")})`,
      execSync("git status --porcelain", { cwd: repo, encoding: "utf8" }).trim(), "");

    /** Restore the session baseline to `main` between rows that ADMIT a move.
     *  LOAD-BEARING, not hygiene: an admitted ceremony re-baselines the session
     *  (the command is never actually run here), and every later rename row keys
     *  on `baseline.branch` — a stale one would refuse the next row for the WRONG
     *  reason and make it a vacuous lock. `git checkout main` is the #376
     *  return-to-original, which re-baselines on BOTH the correct code and the M2
     *  mutant, so it is the neutral restore. */
    const restore607 = async (after) => {
      const r = await callBash("git checkout main");
      expectTrue(`#607 harness control: the baseline is re-established after ${after}`,
        r === undefined, `handler returned ${JSON.stringify(r)}`);
    };
    const expect607Block = async (name, command, mutant) => {
      const v = await callBash(command);
      expectTrue(name, !!v && v.block === true, `handler returned ${JSON.stringify(v)}` + (mutant ? ` [${mutant}]` : ""));
      return v;
    };
    const expect607Allow = async (name, command) => {
      const v = await callBash(command);
      expectTrue(name, v === undefined, `handler returned ${JSON.stringify(v)}`);
    };

    // ── (2) the hidden-payload class — every row here ALLOWED before the fix ──
    const hidSubst = await expect607Block(
      "#607 hidden: a `$(…)` branch-state payload is REFUSED (no visible mutation in the command) [mutant: M1] — MEASURED: M1 admits it (undefined)",
      'echo "$(git branch -Mq main victim)"', "mutant M1");
    expectTrue("#607 hidden: the refusal names its own issue and the visibility reason (an agent must be able to act on it)",
      !!hidSubst && /#607/.test(hidSubst.reason ?? "") && /hidden|hides/.test(hidSubst.reason ?? "")
      && /using-git-worktrees/.test(hidSubst.reason ?? ""),
      `reason=${JSON.stringify(hidSubst?.reason ?? "")}`);
    await expect607Block(
      "#607 hidden: the BACKTICK spelling is refused [mutant: M1] — MEASURED: M1 admits it",
      'echo "`git branch -Mq main victim`"', "mutant M1");
    await expect607Block(
      "#607 hidden: the `eval` spelling is refused [mutant: M1] — MEASURED: M1 admits it",
      "eval 'git branch -Mq main victim'", "mutant M1");
    await expect607Block(
      "#607 hidden: a hidden SWITCH payload is refused [mutant: M1] — MEASURED: M1 admits it",
      'echo "$(git checkout -q feat/other)"', "mutant M1");
    await expect607Block(
      "#607 hidden: a hidden FORCE-CREATE payload is refused [mutant: M1] — MEASURED: M1 admits it",
      'echo "$(git branch -fq feat/x main)"', "mutant M1");
    // The issue's own spelling: a hidden clobber AFTER an M3-SANCTIONED lead. The
    // lead is allowed on its own (a later row pins that), so only the hidden
    // payload can refuse this compound.
    await expect607Block(
      "#607 hidden: a hidden clobber AFTER a sanctioned own-rename lead is refused [mutant: M1] — MEASURED: M1 admits it",
      'git branch -M main freeL ; echo "$(git branch -Mq freeL victim)"', "mutant M1");
    // ⛔ THE REFUSED COMPOUND DID NOT MOVE THE BASELINE (#1144 F3, re-proved on
    // the new path): the sanctioned lead inside the refused command would have
    // re-baselined to `freeL`. If the refusal had applied it, the source below
    // would no longer be the baseline and this row would block for the WRONG
    // reason — so this row is the control for the one above, and it is
    // MEASURED-discriminating under a mutant that applies pending re-baselines
    // on refusal.
    await expect607Allow(
      "#607 hidden: a REFUSED compound left the baseline untouched (the follow-up own-rename is still the sanctioned carve-out) [mutant: M8 — apply the pending re-baselines BEFORE the hidden refusal in admitAfterM3; MEASURED: it re-baselines the refused lead and this row then blocks as a foreign source]",
      "git branch -M main afterRefusalX");
    await restore607("the refused-compound baseline control (baseline `afterRefusalX` → `main`)");
    // A payload the extractor CAN enumerate is still gated on its own merits (the
    // pre-existing #265/#598 refusal) — this change must not become the only thing
    // standing between an interpreter-inline payload and a foreign ref.
    await expect607Block(
      "#607 hidden: an ENUMERATED `sh -c` payload is still refused by the M3 arm (enumeration is untouched)",
      "git branch -M main free4 ; sh -c 'git branch -Mq free4 victim'");

    // ── (3) mid-command baseline propagation — the false block the issue names ──
    await expect607Allow(
      "#607 ceremony: rename own baseline away and BACK is ALLOWED (the false block this issue names) [mutants: M2, M3] — MEASURED: both block it",
      "git branch -M main tmpA && git branch -M tmpA main");
    await restore607("the rename-back ceremony (baseline `main` → `main`)");
    await expect607Allow(
      "#607 ceremony: rename own baseline away, then to a FREE name, is ALLOWED [mutant: M2] — MEASURED: M2 blocks it (segment 2 is judged against `main`)",
      "git branch -M main tmpB && git branch -M tmpB doneB");
    await restore607("the rename-to-free ceremony (baseline `doneB` → `main`)");
    await expect607Allow(
      "#607 ceremony: a three-segment chain that ends on the original name is ALLOWED [mutants: M2, M3] — MEASURED: both block it",
      "git branch -M main c1 && git branch -M c1 c2 && git branch -M c2 main");
    await restore607("the three-segment ceremony");

    // ── the LAUNDER must stay closed on the NEW path (the risk this change carries) ──
    await expect607Block(
      "#607 launder: own-rename lead + FOREIGN clobber tail is BLOCKED [mutant: M3i] — MEASURED: M3i admits it",
      "git branch -M main freeX && git branch -M freeX victim", "mutant M3i");
    await expect607Block(
      "#607 launder: own-rename lead + FOREIGN rename SOURCE is BLOCKED (regression pin, no single mutant: MEASURED GREEN under M1/M2/M3/M3i — decideM3 refuses the foreign source itself)",
      "git branch -M main tmpC && git branch -M feat/other tmpC");
    await expect607Block(
      "#607 launder: own-rename lead + FOREIGN force-create tail is BLOCKED (regression pin, no single mutant: MEASURED GREEN under M1/M2/M3/M3i — the force arm refuses the foreign target itself)",
      "git branch -M main tmpE && git branch -fq feat/other main");
    await expect607Block(
      "#607 launder: own-rename lead + FOREIGN switch tail is BLOCKED (regression pin, no single mutant: MEASURED GREEN under M1/M2/M3/M3i — the switch arm refuses it itself)",
      "git branch -M main tmpF && git checkout feat/other");
    await expect607Block(
      "#607 launder: a propagated chain that ENDS on a foreign ref is BLOCKED — mid-command freedom is own-lineage only (regression pin, no single mutant: MEASURED GREEN under M1/M2/M3/M3i)",
      "git branch -M main d1 && git branch -M d1 d2 && git branch -M d2 victim");
    // Baseline stability across the BLOCKED launder rows: none of them may have
    // moved the session (they were refused), so a plain own-rename still passes.
    await expect607Allow(
      "#607 launder: the refused launder rows left the baseline untouched (follow-up own-rename still allowed)",
      "git branch -M main afterLaunderX");
    await restore607("the launder baseline control (baseline `afterLaunderX` → `main`)");

    // ── negative controls: the refusal is NOT a blanket substitution block ────
    await expect607Allow("#607 scope: `$(git branch --show-current)` is a READ-ONLY substitution → ALLOWED",
      'echo "$(git branch --show-current)"');
    await expect607Allow("#607 scope: `$(git rev-parse HEAD)` → ALLOWED", 'echo "$(git rev-parse HEAD)"');
    await expect607Allow("#607 scope: `$(git status --porcelain)` → ALLOWED", 'echo "$(git status --porcelain)"');
    // #607 scope, at the PREDICATE (review finding 3): the prose row used to assert
    // ALLOW for `git commit --allow-empty -m "git branch -M main x"`, which rides the
    // M2 commit-ownership arm and cannot vary under ANY mutant of this diff — a
    // control for a path this change does not touch. Assert the flag itself instead
    // (the pure-JS classifier is importable with zero deps, so this needs no fixture).
    const { classifyGitCommandDetailed: classify607 } = await import(pathToFileURL(join(HERE, "classify-git.mjs")).href);
    expectTrue("#607 predicate: prose that merely MENTIONS a rename sets NO hidden-state flag",
      classify607('git commit --allow-empty -m "git branch -M main x"').hiddenStateMutation === false,
      JSON.stringify(classify607('git commit --allow-empty -m "git branch -M main x"').hiddenStateMutation));
    // #607 review finding 1: `symbolic-ref` is argument-aware — one positional is a
    // READ (git-symbolic-ref(1)), two write. Both the flag and the shape are pinned.
    expectTrue("#607 predicate: `$(git symbolic-ref --short HEAD)` (a documented READ) is NOT a hidden mutation",
      classify607('git commit -m "wip on $(git symbolic-ref --short HEAD)"').hiddenStateMutation === false,
      JSON.stringify(classify607('git commit -m "wip on $(git symbolic-ref --short HEAD)"').hiddenStateMutation));
    expectTrue("#607 predicate: a TWO-positional `symbolic-ref` DOES write, so it IS a hidden mutation (the read narrowing is not blanket)",
      classify607('echo "$(git symbolic-ref HEAD refs/heads/main)"').hiddenStateMutation === true,
      JSON.stringify(classify607('echo "$(git symbolic-ref HEAD refs/heads/main)"').hiddenStateMutation));
    expectTrue("#607 predicate: `update-ref <ref>` alone is a USAGE ERROR (rc 129, moves nothing) — not a hidden mutation; `--stdin`/`<ref> <new>` are",
      classify607('echo "$(git update-ref refs/heads/x)"').hiddenStateMutation === false
      && classify607('echo "$(git update-ref --stdin)"').hiddenStateMutation === true
      && classify607('echo "$(git update-ref refs/heads/x HEAD)"').hiddenStateMutation === true,
      "update-ref arity narrowing is wrong");

    // ── NO worktree exemption — and this is the SECOND attempt at one ────────
    // ATTEMPT 1 exempted a session whose cwd resolved to a worktree, on the
    // premise "the payload runs at the shell cwd". ATTEMPT 2 attributed the
    // payload's SPANS instead. Both were measured OPEN by fresh-context review:
    //   1) the premise is false — a payload carries its OWN repo hints, so from a
    //      lane worktree `echo "$(git -C <hub> branch -Mq main victim)"` executed
    //      rc 0 and clobbered the hub's `victim` tip (bfdb30ae -> 4c90be9b);
    //   2) the attribution was BUYABLE — `hiddenStateMutation` also fires from arms
    //      that produce NO span (`__unverifiable__`/`eval $VAR`, `$(<file)`,
    //      `-c alias.x=…`, `GIT_CONFIG_PARAMETERS`), so ONE benign substitution in
    //      the same command paid for an exemption of an unattributable payload:
    //      `echo "$(git rev-parse HEAD)"; eval $PAYLOAD` was ADMITTED from a
    //      worktree.
    // So the exemption is GONE: an unenumerable branch-state mutation is refused in
    // EVERY session, and the remedy is the one that works — run it directly (which
    // in a worktree is a visible mutation and exempt as before). The rows below are
    // the anti-regression pins for both attempts; `M4` = a worktree exemption
    // RE-ADDED (the pre-fix form), which admits them.
    const wt607 = join(tmp, "wt607");
    execSync(`git worktree add -q "${wt607}" -b wt/x607 HEAD`, { cwd: repo, stdio: "ignore" });
    process.chdir(wt607);
    await expect607Block("#607 worktree: a hidden branch-state payload in a WORKTREE session is REFUSED [mutant: M4] — MEASURED: M4 admits it",
      'echo "$(git branch -Mq wt/x607 wt/y607)"', "mutant M4");
    await expect607Allow("#607 worktree: the DIRECT (visible) own-rename in a worktree is still exempt (the remedy the refusal names)",
      "git branch -M wt/x607 wt/y607");
    const xRepo = await expect607Block(
      "#607 cross-repo: a payload carrying its own `-C <hub>` is REFUSED from a WORKTREE session [mutant: M4] — MEASURED pre-attempt-2: ALLOWED, the hub's `victim` clobbered rc 0",
      `echo "$(git -C ${repo} branch -Mq main victim)"`, "mutant M4");
    expectTrue("#607 cross-repo: the refusal NAMES the payload-owns-its-repo reason (not a blanket substitution ban)",
      !!xRepo && /worktree/i.test(xRepo.reason ?? "") && /-C|--git-dir/i.test(xRepo.reason ?? ""),
      `reason=${JSON.stringify(xRepo?.reason ?? "")}`);
    await expect607Block(
      "#607 cross-repo: the same reach via `--git-dir=<hub>/.git` is REFUSED [mutant: M4]",
      `echo "$(git --git-dir=${repo}/.git branch -Mq main victim)"`, "mutant M4");
    await expect607Block(
      "#607 cross-repo: a `cd <hub>` chain inside the payload is REFUSED [mutant: M4] — the payload's own cd, not the session's",
      `echo "$(cd ${repo} && git branch -Mq main victim)"`, "mutant M4");
    await expect607Block(
      "#607 cross-repo: a static `eval` payload naming the hub is REFUSED [mutant: M4]",
      `eval 'git -C ${repo} branch -Mq main victim'`, "mutant M4");
    // ⛔ THE REVIEW'S P1, PINNED THREE WAYS: a benign span must not BUY an
    // exemption for an unattributable payload. Each of these was ADMITTED under
    // attempt 2 (no mutant of THIS head re-admits them — the attribution that could
    // be bought no longer exists; they are the regression pins for its return).
    // ⛔ MEASURED CORRECTION to the review's first example: `eval $PAYLOAD` (and
    // `eval "$PAYLOAD"`, and `$CMD` indirection) does NOT set `hiddenStateMutation`
    // at all on this head — the flag is false for all three, so that spelling was
    // never admitted by a buyable exemption. It is a SEPARATE, PRE-EXISTING gap in
    // `_hasHiddenStateSubst` (filed as its own issue, not claimed fixed here), and
    // pinning it as "refused" would be a fabricated row — so the row is the two
    // spellings that DO fire the flag, above and below.
    await expect607Block(
      "#607 bought-exemption: a benign substitution must not exempt an ALIAS payload in the same command [mutant: M4] — MEASURED: M4 admits it (review P1)",
      `echo "$(git rev-parse HEAD)"; git -c alias.x='git branch -fq victim main' x`);
    await expect607Block(
      "#607 bought-exemption: a benign substitution must not exempt an alias payload in the same command [mutant: M4] — MEASURED: M4 admits it (review P1)",
      `git -c alias.br='git -C ${repo} branch -fq victim main' br; echo "$(git rev-parse HEAD)"`);
    // ⛔ MEASURED again, and this flipped: `$(<file)` is INERT TEXT until something
    // evals it (bash's read optimization), so the precise predicate does not treat
    // it as a branch-state mutation at all — refusing it was one of the false blocks
    // review finding 1 named. It is ALLOWED now, and that is deliberate.
    await expect607Allow(
      "#607 read-only: `$(<file)` (inert file text, no eval) is ALLOWED — refusing it was a false block (review finding 1)",
      'echo "$(< /tmp/not-a-repo-claim.txt)"');
    await expect607Block(
      "#607 bought-exemption: alias indirection with no resolvable span is REFUSED from a worktree (#805) [mutant: M4] — MEASURED: M4 admits it",
      "git -c alias.br='git branch -fq victim main' br");
    // ── PROCESS SUBSTITUTION — read-only bodies are ALLOWED, mutating bodies are not.
    // ⚠️ RECORD CORRECTION: an intermediate revision of this block concluded, from ONE
    // spelling, that the read-only-proc-subst finding was "⛔ DO NOT APPLY". That was
    // over-broad and the next review showed why — a body containing a `)` in quotes or
    // a nested `$(…)` WAS refused. The rows below are the class-level pin, and they are
    // the reason the DO NOT APPLY is gone rather than left standing.
    await expect607Allow(
      "#607 proc-subst: a READ-ONLY proc-subst (`git diff --stat <(git log …)`) is ALLOWED (the paren-free control)",
      "git diff --stat <(git log --oneline -1)");
    await expect607Block(
      "#607 proc-subst: a MUTATING proc-subst (`<(git branch -Mq a b)`) is REFUSED — the flag genuinely fires here",
      "git diff --stat <(git branch -Mq a b)");
    // ⛔ AND the READ-ONLY proc-subst class is `ABSENT HERE`, not "also present
    // elsewhere" (round-2 review's correction, which round 3 answered from ONE
    // spelling). The `procRe` prefix bug made every body containing a `)` in quotes
    // or a nested `$(…)` fire; the precise predicate closes it. Both spellings:
    await expect607Allow(
      "#607 proc-subst: a read-only body containing a `)` in quotes is ALLOWED (the round-3 `DO NOT APPLY` was over-broad — closed now)",
      "git diff --stat <(git log --format='%h (%s)' -1)");
    await expect607Allow(
      "#607 proc-subst: a read-only body with a NESTED `$(…)` is ALLOWED",
      "git log --oneline <(git rev-list --max-count=1 HEAD --not $(git rev-list --all))");
    await expect607Block(
      "#607 proc-subst: executable TEXT fed to a shell (`bash <(echo 'git branch -Mq …')`) is still REFUSED — the broad rule survives where it is the only evidence",
      "bash <(echo 'git branch -Mq victim main')");

    // ⛔ ROUND-5 FINDING (order-dependent fail-open in the PRECISE predicate): its memo
    // used to be keyed on span TEXT alone, so a payload first seen as INERT (`$(…)`)
    // suppressed its later EXECUTABLE (`<(...)`) scan of the same text. MEASURED then:
    // inert-first → false (ADMITTED, and the shell runs it, `victim` clobbered rc 0)
    // while exec-first → true. Both orders are now refused (memo keyed on
    // (context, text)) and the inert half alone is still the ALLOW control.
    // ── ROUND-4 FINDING 1: SINGLE-QUOTED text is INERT — the shell expands nothing
    // inside `'…'`, so a payload being DISCUSSED in a commit message is not a payload.
    // MEASURED before this fix: all three rows below were REFUSED, in a worktree
    // session, on the ordinary `git commit` a lane runs while fixing this very issue.
    // The double-quoted twin is the discriminator (it DOES expand, so it stays refused).
    await expect607Allow(
      "#607 quoting: a payload inside a SINGLE-quoted commit message is ALLOWED (bash expands nothing there) [mutant: M9] — MEASURED: M9 refuses it",
      `git commit -m 'fix(guard): refuse $(git branch -Mq main victim) (#607)'`);
    await expect607Allow(
      "#607 quoting: a payload inside single-quoted BACKTICKS in a message is ALLOWED [mutant: M9] — MEASURED: M9 refuses it",
      "git commit -m 'docs: `git branch -Mq main victim` is now refused'");
    await expect607Allow(
      "#607 quoting: a QUOTED heredoc body fed to `git commit -F -` is ALLOWED (literal to the outer shell) [mutant: M9b — the quoted-heredoc strip removed] — MEASURED pre-fix: refused",
      "git commit -F - <<'EOF'\nfix(guard): refuse $(git branch -Mq main victim) (#607)\nEOF");
    await expect607Block(
      "#607 quoting: the DOUBLE-quoted twin is still REFUSED — it really does expand",
      'git commit -m "fix(guard): refuse $(git branch -Mq main victim) (#607)"');
    await expect607Block(
      "#607 order: same text inert-then-executable is REFUSED (the memo is keyed on context, not text alone) [mutant: M7] — MEASURED: M7 reverts to text-only keying and admits it",
      "y=$(echo 'git branch -Mq victim main'); bash <(echo 'git branch -Mq victim main')");
    await expect607Block(
      "#607 order: the same pair exec-then-inert is REFUSED too (symmetry pin: cannot vary under M7 — with a text-only memo this order was ALREADY true; it varies under M1)",
      "bash <(echo 'git branch -Mq victim main'); y=$(echo 'git branch -Mq victim main')");
    await expect607Allow(
      "#607 order: the inert half ALONE is the control — an echo into a variable mutates nothing",
      "y=$(echo 'git branch -Mq victim main')");

    // ── #607 review finding 1: read-only shapes that must NOT be refused ──────
    // Each of these was ADMITTED on main and REFUSED by the previous head (the
    // conservative `hiddenStateSubst` flags), leaving an unhatched lane blocked
    // with a remedy it had already followed. The precise predicate is what makes
    // them pass, so M6 (consume `hiddenStateSubst` instead) reddens all of them.
    await expect607Allow(
      "#607 read-only: a commit message naming the branch (`$(git symbolic-ref --short HEAD)`) is ALLOWED [mutant: M6] — MEASURED: M6 refuses it",
      'git commit -m "wip on $(git symbolic-ref --short HEAD)"');
    await expect607Allow(
      "#607 read-only: capturing the branch into `$BR` then pushing it is ALLOWED [mutant: M6] — MEASURED: M6 refuses it",
      'BR="$(git symbolic-ref --short HEAD)"; git push origin "$BR"');
    await expect607Allow(
      "#607 read-only: a `$VAR` command word holding a read is ALLOWED [mutant: M6] — MEASURED: M6 refuses it",
      'G="git log --oneline"; $G');
    // The HANDLER refuses this one at the pre-existing #709 discard gate ("alias-shell",
    // effect unverifiable) — not at this PR's refusal — so the honest assertion is the
    // predicate: `#607` must not fire on a shell alias that only READS.
    expectTrue("#607 read-only: a `!`-prefixed shell alias whose value READS is NOT a hidden branch-state mutation [mutant: M6] — MEASURED: M6 fires on it",
      classify607("git -c alias.lg='!git log --graph' lg").hiddenStateMutation === false,
      JSON.stringify(classify607("git -c alias.lg='!git log --graph' lg").hiddenStateMutation));

    // ── #607 round-5 FINDING 1 (P1, category A — FAIL-OPEN): an apostrophe in a `#`
    // COMMENT. bash recognizes comments BEFORE it tracks quotes, so `# don't` is a
    // comment whose apostrophe is LITERAL; the round-4 collector treated it as an
    // opening quote that ran to end of input and swallowed every span after it.
    // MEASURED at `2e0b3ab7d`: the two block rows below were `hiddenStateMutation ===
    // false` → ADMITTED from a worktree, `victim` clobbered / branch switched rc 0 —
    // a category-A bypass of the exact class #607 closes, on the class's own subject
    // matter (an apostrophe any lane writes in `# don't …`).
    // The trailing-comment row is the mirror image: text AFTER `#` is inert, so
    // refusing it was a false block whose printed remedy the command already obeyed.
    await expect607Block(
      "#607 comment: an apostrophe in a `#` comment does not swallow the payload after it (`$(git checkout -q …)` still REFUSED) [mutant: M10 — the comment projection removed] — MEASURED at 2e0b3ab7d: ADMITTED",
      `# it's fine\necho "$(git checkout -q feat/other)"`);
    await expect607Block(
      "#607 comment: same, for a CLOBBER payload after `# don't` [mutant: M10] — MEASURED at 2e0b3ab7d: ADMITTED, `victim` clobbered rc 0",
      `# don't\necho "$(git branch -Mq main victim)"`);
    await expect607Allow(
      "#607 comment: a payload spelled INSIDE a trailing `#` comment is INERT — ALLOWED [mutant: M10 — comment text was scanned] — MEASURED at 2e0b3ab7d: REFUSED",
      "echo ok # $(git branch -Mq main victim)");
    // Predicate-level controls, so neither handler row above can be satisfied by an
    // unrelated arm (the refusal, the M3 gate and the legacy arms all live behind the
    // same return, and only the predicate says WHICH one fired).
    expectTrue("#607 comment: predicate — the post-comment payload still sets `hiddenStateMutation` [mutant: M10] — MEASURED at 2e0b3ab7d: false",
      classify607(`# don't\necho "$(git branch -Mq main victim)"`).hiddenStateMutation === true,
      JSON.stringify(classify607(`# don't\necho "$(git branch -Mq main victim)"`).hiddenStateMutation));
    expectTrue("#607 comment: predicate — comment text sets nothing, apostrophe or not [mutant: M10] — MEASURED at 2e0b3ab7d: true",
      classify607("echo ok # $(git branch -Mq main victim)").hiddenStateMutation === false,
      JSON.stringify(classify607("echo ok # $(git branch -Mq main victim)").hiddenStateMutation));
    expectTrue("#607 comment: predicate — the SAME apostrophe does not excuse an executable `<(...)` payload on the next line [mutant: M10] — MEASURED at 2e0b3ab7d: false",
      classify607(`# don't\nbash <(echo 'git branch -Mq victim main')`).hiddenStateMutation === true,
      JSON.stringify(classify607(`# don't\nbash <(echo 'git branch -Mq victim main')`).hiddenStateMutation));
    // ⛔ FOUND while fixing finding 1, in this fix's OWN first cut: an ANSI-C
    // `$'…'` literal may contain an ESCAPED quote (`$'it\'s …'`). Treated as an
    // ordinary single-quoted region it ended at the escaped quote, so a later `#` on
    // the same line blanked the rest — including a LIVE payload after it. MEASURED:
    // false (ADMITTED) without the ANSI-C arm, true with it. Pinned so the arm cannot
    // be dropped again.
    await expect607Block(
      "#607 comment: an ANSI-C literal's ESCAPED quote does not end the region early — a LIVE payload later on the same line is still REFUSED [mutant: M13 — the ANSI-C arm removed] — MEASURED: ADMITTED without it",
      `echo $'it\\'s # x' ; echo "$(git branch -Mq main victim)"`);

    // ── #607 round-5 FINDING 2 (P2 — over-block): the alias arm judged the VERB and
    // not the args, and the eval/alias passes scanned raw source so SINGLE-QUOTED
    // prose still fired. Both are false blocks on shapes `main` admitted, in a
    // worktree session, with the remedy "run it directly" — which they already did.
    // 2a: a READ value must be judged WITH its call-site args (`_argAwareBranchStateMutation`
    // exists one function above precisely because a verb is not the effect).
    expectTrue("#607 alias: a READ value (`alias.b='branch --list' b`) is NOT a hidden mutation [mutant: M11 — first word alone] — MEASURED at 2e0b3ab7d: true (refused)",
      classify607("git -c alias.b='branch --list' b").hiddenStateMutation === false,
      JSON.stringify(classify607("git -c alias.b='branch --list' b").hiddenStateMutation));
    expectTrue("#607 alias: same for a `symbolic-ref --short` value + a `HEAD` call-site arg [mutant: M11] — MEASURED at 2e0b3ab7d: true (refused)",
      classify607("git -c alias.s='symbolic-ref --short' s HEAD").hiddenStateMutation === false,
      JSON.stringify(classify607("git -c alias.s='symbolic-ref --short' s HEAD").hiddenStateMutation));
    // …and the DISCRIMINATOR that keeps 2a's fix from failing open: git APPENDS the
    // call-site args, so a value that reads on its own can still carry the mutation.
    expectTrue("#607 alias: the call-site args are still APPENDED (`alias.x='branch --no-color' x -Mq victim main` is a mutation) [mutant: M11b — call-site args dropped] — MEASURED: dropping them makes this false",
      classify607("git -c alias.x='branch --no-color' x -Mq victim main").hiddenStateMutation === true,
      JSON.stringify(classify607("git -c alias.x='branch --no-color' x -Mq victim main").hiddenStateMutation));
    // 2b: single-quoted prose DESCRIBING a payload. The `$(…)` twin was closed in
    // round 4; these two spellings were left open because only the collector was
    // masked, not the `eval`/alias passes. The existing `#607 bought-exemption: alias
    // indirection …` row (`alias.br='git branch -fq victim main'`) is the control that
    // stays REFUSED — its match starts OUTSIDE the quotes.
    await expect607Allow(
      "#607 quoting: single-quoted prose DESCRIBING an alias is ALLOWED (the eval/alias passes skip inert regions) [mutant: M12 — raw-source scan] — MEASURED at 2e0b3ab7d: REFUSED",
      `git commit -m 'note: git -c alias.x="branch -fq a b" is the trick'`);
    await expect607Allow(
      "#607 quoting: single-quoted prose DESCRIBING an `eval` is ALLOWED [mutant: M12] — MEASURED at 2e0b3ab7d: REFUSED",
      `git commit -m 'see eval "git branch -Mq a b" in the repro'`);
    expectTrue("#607 quoting: predicate — the alias value is judged even when it is single-quoted at the CALL SITE (the match starts outside the `-c`) [mutant: M12] — MEASURED: `alias.br='branch -fq victim main'` stays true",
      classify607("git -c alias.br='branch -fq victim main' br").hiddenStateMutation === true,
      JSON.stringify(classify607("git -c alias.br='branch -fq victim main' br").hiddenStateMutation));
    process.chdir(repo);

    // ── B8: #967/#1484 script classifier — the EFFECT, not the text ──
    // Drive the REAL `_backdoorBlock` through the loaded extension: a git-FREE
    // script whose only path-shaped content is a markdown code span inside a
    // quoted heredoc must RUN (this is the #967 fleet-wide freeze), and a
    // discard reachable only from another subcommand must not gate THIS
    // invocation — while still blocking its own.
    const BT = String.fromCharCode(96);
    writeFileSync(join(repo, "probe.sh"),
      "python3 - \"$1\" <<'PYEOF'\n# docs: a trailing " + BT + "/" + BT + " normalizes to empty\nPYEOF\n");
    const probeRun = await callBash("bash probe.sh --probe");
    expectTrue("B8a: git-free script w/ docstring backtick runs (#967 probe class)",
      probeRun === undefined, `handler returned ${JSON.stringify(probeRun)}`);
    writeFileSync(join(repo, "dispatch.sh"),
      "case \"$1\" in\n  --reset) git reset --hard ;;\n  --status) git status ;;\nesac\n");
    const dStatus = await callBash("bash dispatch.sh --status");
    const dReset = await callBash("bash dispatch.sh --reset");
    expectTrue("B8b: dispatch --status ALLOWED (discard branch unreachable)",
      dStatus === undefined, `handler returned ${JSON.stringify(dStatus)}`);
    expectTrue("B8c: dispatch --reset BLOCKED (discard reachable)",
      !!dReset && dReset.block === true, `handler returned ${JSON.stringify(dReset)}`);
    expectTrue("B8c-msg: block message drops the dead hub-worktree recovery + old wording",
      !!dReset && /script content contains a blocked git operation/.test(dReset.reason ?? "") &&
      !/git-bearing script in the shared main checkout/.test(dReset.reason ?? "") &&
      !/checkout-hygiene\/hub-worktree\.sh/.test(dReset.reason ?? ""),
      `reason=${JSON.stringify(dReset?.reason ?? "")}`);
    // (c) the documented dodge — write /tmp/x.sh + `bash /tmp/x.sh` — stays closed.
    const dodgePath = join(tmp, "dodge.sh");
    writeFileSync(dodgePath, "#!/bin/bash\ngit reset --hard\n");
    const dodge = await callBash(`bash ${dodgePath}`);
    expectTrue("B8d: /tmp dodge (write + bash <file>) BLOCKED",
      !!dodge && dodge.block === true, `handler returned ${JSON.stringify(dodge)}`);
    // #743: a script OWNED by a linked worktree is labeled as such — the old
    // message called it "the shared main checkout" and offered a recovery
    // (hub-worktree.sh) that cannot lift a hub-rooted session's content gate.
    const wt = join(tmp, "wt");
    execSync(`git worktree add -q "${wt}" -b wt/label HEAD`, { cwd: repo, stdio: "ignore" });
    writeFileSync(join(wt, "wt-discard.sh"), "#!/bin/bash\ngit reset --hard\n");
    const wtBlock = await callBash(`bash ${join(wt, "wt-discard.sh")}`);
    expectTrue("B8e: worktree-owned script labeled a linked worktree (not the main checkout)",
      !!wtBlock && wtBlock.block === true &&
      /script location: a linked worktree/.test(wtBlock.reason ?? "") &&
      !/checkout-hygiene\/hub-worktree\.sh/.test(wtBlock.reason ?? ""),
      `reason=${JSON.stringify(wtBlock?.reason ?? "")}`);


    // ── B8f/B8g/B8h: #1129 sanctioned-framework-script exemption ──
    // The framework's OWN mandated preflight is exempted from the content walk
    // (it false-blocks on pure text shapes: ```bash fences inside a single-
    // quoted test fixture, and a usage heredoc whose prose says "git remote").
    // The exemption is REALPATH-keyed on the guard's own checkout and NAMED —
    // so the SAME content at any other path must still block (the
    // discriminator), and a git-DESTRUCTIVE framework helper must still block
    // (the adversarial-review P0 boundary).
    const sanctioned = join(HERE, "..", "..", "scripts", "check-pipeline-compliance.sh");
    const sanctionedRun = await callBash(`bash ${sanctioned} --help`);
    expectTrue("B8f: the framework's own mandated preflight is exempt (#1129)",
      sanctionedRun === undefined, `handler returned ${JSON.stringify(sanctionedRun)}`);
    const sameContent = join(repo, "check-pipeline-compliance.sh");
    writeFileSync(sameContent, readFileSync(sanctioned, "utf-8"));
    const copyRun = await callBash(`bash ${sameContent} --help`);
    expectTrue("B8h: the SAME content at a non-sanctioned path is still blocked (exemption is path-keyed)",
      !!copyRun && copyRun.block === true &&
      /script content contains a blocked git operation/.test(copyRun.reason ?? ""),
      `handler returned ${JSON.stringify(copyRun)}`);
    const destructive = join(HERE, "..", "..", "scripts", "cleanup-worktree.sh");
    const destructiveRun = await callBash(`bash ${destructive} feat/x --force`);
    expectTrue("B8g: a git-DESTRUCTIVE framework helper is still content-gated (no directory-wide exemption)",
      !!destructiveRun && destructiveRun.block === true &&
      /script content contains a blocked git operation/.test(destructiveRun.reason ?? ""),
      `handler returned ${JSON.stringify(destructiveRun)}`);
    // B8i (#1141): the mandated scratch-checkout helper must be runnable FROM A
    // HUB-ROOTED session — the rule in code-review / test-writing /
    // verification-before-completion tells a hub-rooted reviewer to use it, and
    // its content (worktree add/remove/prune, sparse-checkout, read-tree) would
    // otherwise be content-gated, pushing the reviewer back to the /tmp copy the
    // issue bans.
    const scratch = join(HERE, "..", "..", "scripts", "scratch-worktree.sh");
    const scratchRun = await callBash(`bash ${scratch} --help`);
    expectTrue("B8i: the scratch-checkout helper is exempt from the hub content walk (#1141)",
      scratchRun === undefined, `handler returned ${JSON.stringify(scratchRun)}`);
    const scratchCopy = join(repo, "scratch-worktree.sh");
    writeFileSync(scratchCopy, readFileSync(scratch, "utf-8"));
    const scratchCopyRun = await callBash(`bash ${scratchCopy} --help`);
    expectTrue("B8j: the SAME helper content outside the framework is still blocked (exemption is path-keyed)",
      !!scratchCopyRun && scratchCopyRun.block === true &&
      /script content contains a blocked git operation/.test(scratchCopyRun.reason ?? ""),
      `handler returned ${JSON.stringify(scratchCopyRun)}`);

    // ── B7: write/edit gate on a DISORDERED hub (#1484/#436/#628) ──
    // Pre-#744 the import degraded mid-destructuring, so the later bindings
    // (`resolveTargetTopLevel`, `resolveTargetCheckout`, `classifierLoaded`)
    // were stubbed and the write gate was inert.
    execSync("printf 'wip\\n' > stray.txt", { cwd: repo, stdio: "ignore" });
    const realWarn2 = console.warn;
    console.warn = () => {}; // the #628 banner is chatty; decisions are what matter
    let trackedWrite, firstWrite, capWrite, carveOutBlocked = [];
    try {
      // B7a: overwriting an EXISTING TRACKED hub file must block.
      trackedWrite = await callWrite(join(repo, "tracked.txt"));
      // B7b/B7c: NEW files take the #436 carve-out (1..25 allowed, 26 blocked).
      firstWrite = await callWrite(join(repo, "docs", "plans", "_new-1.md"));
      if (firstWrite !== undefined) carveOutBlocked.push(`_new-1: ${JSON.stringify(firstWrite).slice(0, 120)}`);
      for (let i = 2; i <= 25; i++) {
        const r = await callWrite(join(repo, "docs", "plans", `_new-${i}.md`));
        // A blocked carve-out write is NOT counted toward the #628 volume, so a
        // single transient block inside 1..25 shifts B7c's boundary and shows
        // up as a confusing "write #26 was allowed". Record them so that mode
        // reports itself as this, not as a cap regression. (Observed twice in
        // ~250 runs under load — see #768.)
        if (r !== undefined) carveOutBlocked.push(`_new-${i}: ${JSON.stringify(r).slice(0, 120)}`);
      }
      capWrite = await callWrite(join(repo, "docs", "plans", "_new-26.md"));
    } finally {
      console.warn = realWarn2;
    }
    expectTrue("B7a: tracked-file write in a disordered hub is BLOCKED (write gate is live, not inert)",
      !!trackedWrite && trackedWrite.block === true, `handler returned ${JSON.stringify(trackedWrite)}`);
    expectTrue("B7b: first new-file write is ALLOWED (collision-free carve-out is not the degraded block)",
      firstWrite === undefined, `handler returned ${JSON.stringify(firstWrite)}`);
    expectTrue("B7c: write #26 blocks on the #628 volume cap (hubNewFileVolumeVerdict/HUB_NEW_FILE_BLOCK_CAP are real)",
      !!capWrite && capWrite.block === true && /#628/.test(capWrite.reason ?? ""),
      `handler returned ${JSON.stringify(capWrite)}` +
      (carveOutBlocked.length
        ? ` — but ${carveOutBlocked.length} of writes 1..25 were BLOCKED (${carveOutBlocked.slice(0, 2).join(" | ")}), so this boundary shifted instead of failing (#768)`
        : ""));

  } catch (e) {
    expectTrue("B: part B ran without throwing", false, String(e?.message ?? e).slice(0, 200));
  } finally {
    cleanup();
  }
}

await partB();

// ─────────────────────────────────────────────────────────
// Part C — a DEGRADED classifier load is LOUD and DURABLE (#853)
// ─────────────────────────────────────────────────────────
// Why this Part exists. Part B proves a HEALTHY load binds the real exports,
// and B1 asserts it emits no degradation warning — but nothing asserted what a
// DEGRADED load reports. That was the gap #853 is about: `classifierLoaded`
// false left every gate inert and reported it with one `console.warn`, which no
// gate and no report reads, so the guard was a NO-OP GATE that looked enforced.
//
// A real load failure cannot be produced in-process: Part B has already imported
// `classify-git.mjs`, so the ESM registry serves it from cache and a load hook
// never runs for it. So this Part spawns a CHILD node process with a fresh
// module registry, installs the repo's own loader hooks (module-load-hooks.mjs)
// with ONE wrapper that makes `classify-git.mjs` throw while it evaluates, and
// asserts the degraded session_start reports on the surfaces #853 named —
// banner, error-level notification, and a durable `guard_degraded` gate event.
console.log("\n── Part C: a degraded classifier load is LOUD + DURABLE (#853) ──");

async function partC() {
  if (typeof stripTypeScriptTypes !== "function" || typeof registerHooks !== "function") {
    skipped("C: degraded-load reporting",
      `node ${process.versions.node} lacks module.stripTypeScriptTypes/registerHooks (needs Node >= 22.15) — ` +
      "Part A/B still guard the load path, but the #853 reporting is unproven on this interpreter");
    return;
  }

  const hooksUrl = new URL("./module-load-hooks.mjs", import.meta.url).href;
  const indexUrl = pathToFileURL(INDEX_TS).href;
  const auditLogUrl = new URL("../shared/audit-log.ts", import.meta.url).href;

  // The probe runs in a fresh process so `classify-git.mjs` is genuinely
  // EVALUATED (and throws) instead of being served from a cache. It drives the
  // registered session_start exactly as pi does, with a ctx whose ui.notify is
  // recorded, and prints one JSON line for the parent to assert against.
  const probe = `
import { registerHooks } from "node:module";
const hooks = await import(${JSON.stringify(hooksUrl)});
const realLoad = hooks.load;
// The ONE injection (armed by the parent's env): classify-git.mjs throws while
// evaluating, which is the TOTAL load failure #853 describes (the catch in
// index.ts fires, every binding keeps its fail-safe default, classifierLoaded
// never flips). Disarmed, the SAME probe is the healthy control.
const injectFailure = process.env.PROBE_FAIL_CLASSIFY === "1";
registerHooks({
  resolve: hooks.resolve,
  load(url, context, nextLoad) {
    if (injectFailure && url.endsWith("/main-worktree-guard/classify-git.mjs")) {
      return { format: "module", shortCircuit: true,
        source: 'throw new Error("injected classify-git.mjs load failure (#853 test)");' };
    }
    return realLoad(url, context, nextLoad);
  },
});
const warns = [];
const realWarn = console.warn;
// Kept overridden ACROSS session_start: the #853 report fires there, not at load,
// so restoring the real warn before driving the handler would send the banner to
// stderr and leave this probe unable to see it. Forwarded, not swallowed, so a
// genuine failure elsewhere in the child stays diagnosable.
console.warn = (...a) => { warns.push(a.map(String).join(" ")); realWarn(...a); };
const mod = await import(${JSON.stringify(indexUrl)});
// The DECLARED vocabulary, read from the real module (hooks strip its types), so the parent can
// assert the name this extension actually WRITES is a name the repo DECLARES. A type union is
// invisible at runtime, so without this the two can drift silently — the exact defect the #853
// review measured (deleting the union member reddened nothing).
const auditLog = await import(${JSON.stringify(auditLogUrl)});
const declaredEvents = Array.from(auditLog.GATE_EVENT_NAMES ?? []);
const notified = [];
const handlers = new Map();
mod.default({ on(n, f) { if (!handlers.has(n)) handlers.set(n, []); handlers.get(n).push(f); } });
const start = handlers.get("session_start")?.[0];
// Fire session_start TWICE: the report is once per session process, so a
// /resume must not duplicate the banner or the audit row.
const throwNotify = process.env.PROBE_THROW_NOTIFY === "1";
const ctx = { ui: { notify: (msg, level) => {
  if (throwNotify) throw new Error("injected ui.notify throw (#853 test)");
  notified.push({ msg, level });
} } };
if (typeof start === "function") { await start({}, ctx); await start({}, ctx); }
process.stdout.write(JSON.stringify({ warns, notified, registered: !!start, declaredEvents }) + "\\n");
`;

  // Hermetic HOME per arm: the gate event lands in $HOME/.pi/agent/audit/
  // gate-events.jsonl, so each arm reads only the row it caused.
  const runArm = ({ printMode = false, injectFailure = true, allowMainEdits = false, throwNotify = false } = {}) => {
    const home = realpathSync(mkdtempSync(join(tmpdir(), "guard-degraded-home-")));
    const env = { ...process.env, HOME: home };
    // isPrintMode() reads env.PI_MODE first; argv here carries no -p/--print.
    if (printMode) env.PI_MODE = "print"; else delete env.PI_MODE;
    if (injectFailure) env.PROBE_FAIL_CLASSIFY = "1"; else delete env.PROBE_FAIL_CLASSIFY;
    delete env.AGENT_ALLOW_MAIN_EDITS;
    delete env.ELDATO_ALLOW_MAIN_EDITS;
    // C12's arm: the escape hatch ON, which is the state `session_start` returns
    // early from (`index.ts:5177`). Kept as an ENV seam rather than a ctx stub so
    // the arm exercises the real `_isAllowMainEdits()` the handler consults.
    if (allowMainEdits) env.AGENT_ALLOW_MAIN_EDITS = "1";
    if (throwNotify) env.PROBE_THROW_NOTIFY = "1"; else delete env.PROBE_THROW_NOTIFY;
    const out = spawnSync(process.execPath, ["--input-type=module", "-e", probe], {
      env, encoding: "utf8", timeout: 120_000, cwd: HERE,
    });
    const last = (out.stdout ?? "").trim().split("\n").filter(Boolean).pop();
    let parsed = null;
    try { parsed = JSON.parse(last ?? "null"); } catch { /* asserted below */ }
    const auditFile = join(home, ".pi", "agent", "audit", "gate-events.jsonl");
    const auditRows = existsSync(auditFile)
      ? readFileSync(auditFile, "utf8").trim().split("\n").filter(Boolean).map((l) => {
          try { return JSON.parse(l); } catch { return null; }
        }).filter(Boolean)
      : [];
    rmSync(home, { recursive: true, force: true });
    return { parsed, auditRows, stderr: (out.stderr ?? "").slice(-500), status: out.status };
  };

  const interactive = runArm({ printMode: false });
  if (!interactive.parsed) {
    expectTrue("C0: the degraded-load probe ran and reported (precondition)", false,
      `probe exited ${interactive.status}; stderr tail: ${interactive.stderr}`);
    return;
  }
  expectTrue("C0: the degraded load still registered a session_start handler (precondition)",
    interactive.parsed.registered === true,
    `registered=${JSON.stringify(interactive.parsed.registered)} — the probe never reached the factory`);

  const banner = (interactive.parsed.warns ?? []).find((w) => w.includes("MAIN-WORKTREE GUARD — DEGRADED"));
  expectTrue("C1: a degraded load reports a LOUD state banner at session_start (not a bare ⚠️ line)",
    !!banner, `captured warnings: ${JSON.stringify(interactive.parsed.warns ?? [])}`.slice(0, 400));
  expectTrue("C2: the banner NAMES the consequence (the gates it leaves off)",
    !!banner && /bash git mutations/.test(banner) && /FAILS OPEN/.test(banner),
    `banner missing the consequence sentences: ${String(banner).slice(0, 300)}`);
  expectTrue("C3: the banner NAMES the cause (the injected load error, not a generic message)",
    !!banner && /injected classify-git\.mjs load failure/.test(banner),
    `banner does not carry the cause: ${String(banner).slice(0, 300)}`);
  expectTrue("C4: the banner NAMES a remedy",
    !!banner && /FIX: reinstall/.test(banner), `banner has no remedy: ${String(banner).slice(0, 300)}`);
  expectTrue("C5: session_start fired TWICE but the banner was reported ONCE (once per session process)",
    (interactive.parsed.warns ?? []).filter((w) => w.includes("MAIN-WORKTREE GUARD — DEGRADED")).length === 1,
    `degradation banners: ${(interactive.parsed.warns ?? []).filter((w) => w.includes("DEGRADED")).length}`);

  const notes = interactive.parsed.notified ?? [];
  expectTrue("C6: an INTERACTIVE session also gets an error-level ui.notify (a log line is what nothing reads)",
    notes.length === 1 && notes[0].level === "error" && /DEGRADED/.test(notes[0].msg),
    `notified: ${JSON.stringify(notes).slice(0, 300)}`);

  // ── The DURABLE half: a gate event a report can read without parsing prose.
  const rows = interactive.auditRows.filter((r) => r.event === "guard_degraded");
  expect(`C7: a degraded load appends exactly one \`guard_degraded\` gate event (twice-fired session_start → 1 row)`,
    rows.length, 1);
  expectTrue("C8: the gate event is attribution-complete (extension + reason + cause + cwd)",
    rows.length === 1 &&
      rows[0].extension === "main-worktree-guard" &&
      rows[0].reason === "classifier_load_failed" &&
      /injected classify-git\.mjs load failure/.test(rows[0].error ?? "") &&
      typeof rows[0].session_cwd === "string" && rows[0].session_cwd.length > 0 &&
      typeof rows[0].ts === "string",
    `row: ${JSON.stringify(rows[0] ?? null).slice(0, 400)}`);

  // ── C13: the name the guard WRITES is a name the repo DECLARES (#853 review, issue 1).
  // R6's original "covered" claim cited `audit-log.test.ts`, which never referenced the union —
  // so deleting the union member reddened nothing. `appendJsonl` takes `Record<string, unknown>`,
  // so the type cannot catch this either. This row closes it end-to-end: it reads the emitted
  // event back out of gate-events.jsonl and checks it against the vocabulary the REAL module
  // exports. Delete the `"guard_degraded"` member and this reddens; typo the emit and C7 reddens.
  // (Numbered C13 to leave C12/C12b — the PLACEMENT arm below — as the fixer's commit
  // introduced them; two different assertions on one label is a report that cannot be cited.)
  const declared = interactive.parsed.declaredEvents ?? [];
  expectTrue("C13: the event name the guard WRITES is a DECLARED GateEventName (emit ↔ vocabulary pinned end-to-end)",
    declared.length > 0 && rows.length === 1 && declared.includes(rows[0].event),
    `emitted=${JSON.stringify(rows[0]?.event ?? null)} declared(${declared.length})=${JSON.stringify(declared).slice(0, 300)}`);
  expectTrue("C13b: the vocabulary cross-check is not vacuous (the probe really read GATE_EVENT_NAMES)",
    declared.length >= 10 && declared.includes("gate_bypass"),
    `declared(${declared.length})=${JSON.stringify(declared).slice(0, 200)}`);

  // ── Print mode: the banner + the event must survive, the ui.notify must not fire
  // (a headless lane has no UI; its own log carries the banner — never no surface).
  const headless = runArm({ printMode: true });
  expectTrue("C9: a PRINT-MODE session still delivers the banner and the gate event (never no surface)",
    !!headless.parsed &&
      (headless.parsed.warns ?? []).some((w) => w.includes("MAIN-WORKTREE GUARD — DEGRADED")) &&
      headless.auditRows.some((r) => r.event === "guard_degraded"),
    `parsed=${JSON.stringify(headless.parsed ?? null).slice(0, 200)} audit=${headless.auditRows.length} stderr=${headless.stderr}`);
  expect("C10: print mode does NOT call ui.notify (no ctx surface to call, and the log already carries it)",
    (headless.parsed?.notified ?? []).length, 0);

  // ── The HEALTHY control: the SAME probe with the injection disarmed. Part B's
  // B1 pins "zero degradation warnings" for a good in-process load, but it cannot
  // see the event surface — a report that fired unconditionally would append a
  // `guard_degraded` row for every healthy session and turn the durable signal
  // into noise. This is the arm that proves the report is gated on the STATE.
  const healthy = runArm({ printMode: false, injectFailure: false });
  expectTrue("C11: a HEALTHY load reports nothing (no banner, no notify, no event) — the report is gated on the state",
    !!healthy.parsed &&
      (healthy.parsed.warns ?? []).every((w) => !w.includes("MAIN-WORKTREE GUARD — DEGRADED")) &&
      (healthy.parsed.notified ?? []).length === 0 &&
      healthy.auditRows.filter((r) => r.event === "guard_degraded").length === 0,
    `parsed=${JSON.stringify(healthy.parsed ?? null).slice(0, 300)} audit=${JSON.stringify(healthy.auditRows).slice(0, 200)} stderr=${healthy.stderr}`);
  expectTrue("C11b: the healthy control actually LOADED the classifier (otherwise C11 is vacuous)",
    !!healthy.parsed &&
      (healthy.parsed.warns ?? []).every((w) => !/classify-git\.mjs failed to load/.test(w)),
    `captured: ${JSON.stringify(healthy.parsed?.warns ?? []).slice(0, 300)}`);

  // ── The PLACEMENT arm. The report is the FIRST statement of `session_start`
  // specifically so it cannot sit behind an early return — and the early return
  // that matters most is the ESCAPE HATCH: `if (_isAllowMainEdits()) return;`
  // (`index.ts:5177`) is the natural place a later "don't nag a deliberate solo
  // session" refactor would move it under. Without this arm the ordering is
  // proven only by reading the source, and moving the call reddens nothing —
  // which is the same silent-loss class #853 exists to close, one level down.
  const hatched = runArm({ printMode: false, allowMainEdits: true });
  expectTrue("C12: the degraded report is NOT behind the escape hatch — a hatched session still gets the banner + the event",
    !!hatched.parsed &&
      (hatched.parsed.warns ?? []).some((w) => w.includes("MAIN-WORKTREE GUARD — DEGRADED")) &&
      hatched.auditRows.filter((r) => r.event === "guard_degraded").length === 1,
    `parsed=${JSON.stringify(hatched.parsed ?? null).slice(0, 300)} audit=${JSON.stringify(hatched.auditRows).slice(0, 200)} stderr=${hatched.stderr}`);
  // Its NAME states exactly what its body checks: the source ORDER. That the hatch arm really took
  // the early return is proven BEHAVIOURALLY by C12 (move the call below it and C12 goes red —
  // measured on a copy), not by reading the env back, which would only restate
  // `_isAllowMainEdits()` (`index.ts:506` = `_getEnv("ALLOW_MAIN_EDITS") === "1"`).
  expectTrue("C12b: the call sits ABOVE the escape-hatch return inside the session_start handler (source-order pin)",
    // C12 alone is only conclusive if the hatch was genuinely ON — otherwise it is
    // indistinguishable from the non-hatched arms. Reading the env back would just
    // restate `_isAllowMainEdits()` (`index.ts:506` = `_getEnv("ALLOW_MAIN_EDITS") === "1"`),
    // so the non-vacuous half is a SOURCE-ORDER pin: the report call must precede the
    // `if (_isAllowMainEdits()) return;` inside the registered `session_start` handler.
    (() => {
      const src = readFileSync(INDEX_TS, "utf8");
      const handlerAt = src.indexOf('pi.on("session_start"');
      if (handlerAt < 0) return false;
      const callAt = src.indexOf("_reportClassifierDegradation(ctx", handlerAt);
      const hatchAt = src.indexOf("if (_isAllowMainEdits()) return;", handlerAt);
      return callAt > handlerAt && hatchAt > handlerAt && callAt < hatchAt;
    })(),
    `handler=${INDEX_TS}: pi.on("session_start") / _reportClassifierDegradation / _isAllowMainEdits order — the report must come FIRST, before the escape-hatch return`);

  // ── ORDER-INDEPENDENCE: a PRESENTATION surface that throws must not cost the durable row. ──
  // Numbered C14/C14b: C13/C13b is the emit↔vocabulary pin, and two different assertions on one
  // label is a report that cannot be cited.
  // Before the fix the row was written AFTER `ui.notify` inside ONE try, so a throwing notify skipped
  // it — and the per-pid dedupe made that loss PERMANENT for the process, leaving the machine-readable
  // surface (the whole point of #853) silently absent while the banner implied otherwise.
  const throwingNotify = runArm({ printMode: false, throwNotify: true });
  expectTrue("C14: a THROWING ui.notify still leaves the durable `guard_degraded` row (written first, each surface its own try)",
    !!throwingNotify.parsed &&
      throwingNotify.auditRows.filter((r) => r.event === "guard_degraded").length === 1 &&
      (throwingNotify.parsed.warns ?? []).some((w) => w.includes("MAIN-WORKTREE GUARD — DEGRADED")),
    `parsed=${JSON.stringify(throwingNotify.parsed ?? null).slice(0, 200)} audit=${JSON.stringify(throwingNotify.auditRows).slice(0, 200)} stderr=${throwingNotify.stderr}`);
  expectTrue("C14b: the throwing arm's session_start did NOT propagate the throw (a report never changes a verdict)",
    !!throwingNotify.parsed && throwingNotify.parsed.registered === true && throwingNotify.status === 0,
    `status=${throwingNotify.status} parsed=${JSON.stringify(throwingNotify.parsed ?? null).slice(0, 120)}`);
}

await partC();

// agent-infra#2723 — emit through the shared emitter so the failing arm always
// carries the `runner::test-module-load` identity the merge rail reads.
reportVerdict("test-module-load", pass, fail, { skip });
process.exit(fail === 0 ? 0 : 1);
