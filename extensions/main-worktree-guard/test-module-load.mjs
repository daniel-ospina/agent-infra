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
import { execSync } from "node:child_process";
import { mkdtempSync, readFileSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { register, registerHooks, stripTypeScriptTypes } from "node:module";

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
  } finally {
    console.warn = realWarn;
  }

  const degradation = warnings.filter((w) => w.includes("[main-worktree-guard]"));
  for (const w of degradation) console.log(`     captured: ${w}`);
  expect(`B1: index.ts loads with no degradation warning (warnings: ${warnings.length})`, degradation.length, 0);
  expect("B2: index.ts default export is the extension factory", typeof mod.default, "function");
  if (typeof mod.default !== "function") return;

  // Drive the factory: it registers exactly session_start + tool_call.
  const handlers = new Map();
  mod.default({ on(name, fn) { if (!handlers.has(name)) handlers.set(name, []); handlers.get(name).push(fn); } });
  const toolCall = handlers.get("tool_call")?.[0];
  expect("B3: factory registered a tool_call handler", typeof toolCall, "function");
  if (typeof toolCall !== "function") return;

  // Hermetic MAIN checkout: clean + on main, so nothing blocks for a reason
  // other than the binding under test.
  // realpath: on macOS tmpdir() is /var/... while git reports /private/var/...
  // (the guard realpaths its toplevel, so a non-realpath'd fixture would look
  // outside the hub and misjudge the carve-out).
  const tmp = realpathSync(mkdtempSync(join(tmpdir(), "guard-module-load-")));
  const repo = join(tmp, "hub");
  const prevCwd = process.cwd();
  try {
    execSync(`git init -q -b main "${repo}"`, { stdio: "ignore" });
    execSync("git config user.email t@t && git config user.name t", { cwd: repo, stdio: "ignore" });
    execSync("printf 'x\\n' > tracked.txt", { cwd: repo, stdio: "ignore" });
    execSync("git add tracked.txt", { cwd: repo, stdio: "ignore" });
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

    // ── B7: write/edit gate on a DISORDERED hub (#1484/#436/#628) ──
    // Pre-#744 the import degraded mid-destructuring, so the later bindings
    // (`resolveTargetTopLevel`, `resolveTargetCheckout`, `classifierLoaded`)
    // were stubbed and the write gate was inert.
    execSync("printf 'wip\\n' > stray.txt", { cwd: repo, stdio: "ignore" });
    const realWarn2 = console.warn;
    console.warn = () => {}; // the #628 banner is chatty; decisions are what matter
    let trackedWrite, firstWrite, capWrite;
    try {
      // B7a: overwriting an EXISTING TRACKED hub file must block.
      trackedWrite = await callWrite(join(repo, "tracked.txt"));
      // B7b/B7c: NEW files take the #436 carve-out (1..25 allowed, 26 blocked).
      firstWrite = await callWrite(join(repo, "docs", "plans", "_new-1.md"));
      for (let i = 2; i <= 25; i++) await callWrite(join(repo, "docs", "plans", `_new-${i}.md`));
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
      `handler returned ${JSON.stringify(capWrite)}`);
  } catch (e) {
    expectTrue("B: part B ran without throwing", false, String(e?.message ?? e).slice(0, 200));
  } finally {
    process.chdir(prevCwd);
    for (const [v, val] of savedHatch) {
      if (val === undefined) delete process.env[v]; else process.env[v] = val;
    }
    try { rmSync(tmp, { recursive: true, force: true }); } catch { /* best-effort */ }
  }
}

await partB();

console.log(`\n${fail === 0 ? "✅" : "❌"} test-module-load: ${pass} passed, ${fail} failed, ${skip} skipped`);
process.exit(fail === 0 ? 0 : 1);
