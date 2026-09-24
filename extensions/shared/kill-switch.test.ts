/**
 * kill-switch.test.ts — #1419: the documented deadlock escape must actually fire.
 * Run: npx tsx extensions/shared/kill-switch.test.ts
 *
 * ⚠️ SAFETY: `KILL_SWITCH_FILE` is machine-global and disables sequence
 * enforcement for EVERY session on the box. This suite therefore NEVER touches
 * it: every runtime case runs against a path in a private temp dir, and the
 * machine path is only ever asserted as a STRING. An earlier draft saved and
 * restored the real file instead — which a SIGTERM mid-run (or a CI timeout)
 * would have skipped, leaving the fleet silently bypassed. Not touching it at
 * all is the only version of this suite that cannot do that.
 *
 * The AGENT escape, by contrast, is process-local state and touches no file —
 * so these cases also pin the rule that `loopStopEscape` does NOT write the
 * human's machine-global switch (`skills/enforcement/SKILL.md:11`).
 */

import { existsSync, readFileSync, readdirSync, mkdtempSync, rmSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { equal, ok, deepEqual } from "node:assert/strict";

import {
  KILL_SWITCH_FILE,
  isKillSwitchSet,
  killSwitchEnvValue,
  killSwitchStatus,
  setKillSwitch,
  clearKillSwitch,
  loopStopEscape,
  isEnforcementBypassed,
  isSessionEscaped,
  sessionEscapeStatus,
  clearSessionEscape,
  SESSION_ESCAPE_CELL_KEY,
} from "./kill-switch.js";

const scratch = mkdtempSync(join(tmpdir(), "killswitch-"));
const SWITCH = join(scratch, "kill");           // never the machine path

try {
  // ── the contract: the production path must not have moved ───────────────
  // Changing it silently strands every already-running session's escape, and
  // both extensions read this default.
  equal(KILL_SWITCH_FILE, "/tmp/agent-state-machine.kill", "the machine-global path is unchanged");
  equal(isKillSwitchSet({}, SWITCH), false, "clean temp path → not set");
  equal(existsSync(SWITCH), false, "…and nothing was created just by asking");

  // ── the human switch is a FILE, and the write lands ─────────────────────
  const when = new Date("2026-09-24T12:00:00.000Z");
  const wrote = setKillSwitch(when, SWITCH);
  equal(wrote.ok, true, "setKillSwitch reports success");
  equal(wrote.path, SWITCH, "setKillSwitch reports the path it wrote");
  equal(existsSync(SWITCH), true, "the kill-switch file EXISTS on disk (the old write never did)");
  equal(readFileSync(SWITCH, "utf-8"), when.toISOString(), "file carries the timestamp");
  equal(isKillSwitchSet({}, SWITCH), true, "switch reads as set");
  equal(killSwitchStatus({}, SWITCH).set, true, "status.set true");
  equal(killSwitchStatus({}, SWITCH).ts, when.toISOString(), "status exposes the timestamp");
  equal(killSwitchStatus({}, SWITCH).source, "file", "…and attributes it to the file");
  clearKillSwitch(SWITCH);

  // ── #1419 indicator 1: NO active loop, and the escape still fires ───────
  // THE regression: `stop` returned "No active loop to stop." BEFORE reaching
  // the escape, so it refused to fire in the only state a checkpoint-deadlocked
  // session is ever in.
  clearSessionEscape();
  const noLoop = loopStopEscape(null);
  equal(isSessionEscaped(), true, "the escape fires with NO active loop");
  equal(noLoop.text.includes("No active loop to stop."), true, "the no-loop case is reported honestly");
  equal(noLoop.text.includes("bypassed"), true, "…and names the bypass it performed");
  equal(isEnforcementBypassed({}, SWITCH), true, "…and enforcement reads as bypassed for this session");
  equal(sessionEscapeStatus(), noLoop.ts, "the escape's timestamp is readable");

  // ── ⛔ THE HUMAN'S SWITCH IS NOT TOUCHED (skills/enforcement/SKILL.md:11)
  // An agent must never engage the machine-global valve: that bypasses EVERY
  // session on the box.
  equal(existsSync(SWITCH), false, "the agent escape did NOT write the machine-global switch file");
  equal(isKillSwitchSet({}, SWITCH), false, "…so the machine-wide switch still reads as NOT set");

  // ── ⛔ DURABILITY: a sibling session's wipe must NOT revoke the escape ──
  // #7470 has every `session_start` clear the machine-global file for hygiene,
  // and a `task` sub-agent is a separate `pi -p` process — so on a fleet that
  // dispatches sub-agents continuously, a sibling boot cleared the switch
  // within seconds and the blocked session was re-gated before it could spend
  // the escape. The escape is process-local, so no other process can clear it.
  {
    setKillSwitch(new Date(), SWITCH);          // simulate the human's valve open
    clearKillSwitch(SWITCH);                    // simulate a sibling session_start wiping it
    equal(isSessionEscaped(), true, "the escape SURVIVES a sibling session clearing the file");
    equal(isEnforcementBypassed({}, SWITCH), true, "…and the session is still bypassed afterwards");
  }

  // ── the active-loop case still works, and still only escapes the session ─
  clearSessionEscape();
  const withLoop = loopStopEscape("my-loop");
  equal(withLoop.text.includes("my-loop"), true, "names the loop it stopped");
  equal(isEnforcementBypassed({}, SWITCH), true, "bypassed with an active loop too");
  equal(existsSync(SWITCH), false, "still no machine-global write");

  // ── clearance is honourable, and reports the transition ────────────────
  equal(clearSessionEscape(), true, "clear reports a transition when one was set");
  equal(clearSessionEscape(), false, "…and is honest when nothing was set");
  equal(isSessionEscaped(), false, "the escape is gone");
  equal(isEnforcementBypassed({}, SWITCH), false, "…and enforcement is back on");

  // ── the human switch's own clearance (session-start hygiene) ───────────
  setKillSwitch(new Date(), SWITCH);
  equal(clearKillSwitch(SWITCH), true, "clear removes an existing switch");
  equal(clearKillSwitch(SWITCH), false, "clear is honest when nothing was there");
  equal(isKillSwitchSet({}, SWITCH), false, "switch reads as unset");

  // ── an UNREADABLE-but-present switch is still SET ──────────────────────
  // `isKillSwitchSet` goes by existence; `killSwitchStatus` must agree, or
  // `diagnose` would report "NOT SET" while enforcement is bypassed.
  {
    const dirAsSwitch = join(scratch, "as-dir");
    mkdirSync(dirAsSwitch);
    equal(isKillSwitchSet({}, dirAsSwitch), true, "existence sets it");
    equal(killSwitchStatus({}, dirAsSwitch).set, true, "status AGREES with isKillSwitchSet");
    equal(killSwitchStatus({}, dirAsSwitch).ts, null, "…with ts unknown rather than a false 'not set'");
  }

  // ── the env bypass: a SEPARATE switch, and status must NAME it ─────────
  // Reading only the file let `diagnose` print "NOT SET" while
  // AGENT_STATE_MACHINE=1 bypassed every gate — the exact inversion the
  // existence rule above exists to prevent.
  equal(killSwitchEnvValue({ AGENT_STATE_MACHINE: "1" }), "1", "AGENT_ prefix read");
  equal(killSwitchEnvValue({ ELDATO_STATE_MACHINE: "1" }), "1", "ELDATO_ prefix read");
  equal(killSwitchEnvValue({}), undefined, "unset → undefined");
  equal(isKillSwitchSet({ AGENT_STATE_MACHINE: "1" }, SWITCH), true, "env alone sets it");
  equal(isKillSwitchSet({}, SWITCH), false, "…and the file being clear does not");
  equal(killSwitchStatus({ AGENT_STATE_MACHINE: "1" }, SWITCH).set, true,
    "STATUS reports the env bypass even with no file on disk");
  equal(killSwitchStatus({ AGENT_STATE_MACHINE: "1" }, SWITCH).source, "env",
    "…and attributes it to the env, not the file");
  equal(isEnforcementBypassed({ AGENT_STATE_MACHINE: "1" }, SWITCH), true, "and it bypasses enforcement");

  // ── #1419 target: NO path returns success while writing nothing ─────────
  const failed = setKillSwitch(new Date(), join(scratch, "no-such-dir", "kill"));
  equal(failed.ok, false, "an unwritable path reports ok:false, never a silent success");
  equal(typeof failed.error, "string", "…and carries the reason");
} finally {
  clearSessionEscape();
  rmSync(scratch, { recursive: true, force: true });
}

// ── static guards: the defect class, not just its instance (#1419) ─────────
const here = dirname(fileURLToPath(import.meta.url));
const extensionsDir = resolve(here, "..");
const repoRoot = resolve(extensionsDir, "..");
const short = (p: string) => p.replace(repoRoot + "/", "");
const walk = (dir: string): string[] =>
  readdirSync(dir, { withFileTypes: true }).flatMap((e) => {
    const p = join(dir, e.name);
    if (e.isDirectory()) return e.name === "node_modules" ? [] : walk(p);
    return e.isFile() && e.name.endsWith(".ts") ? [p] : [];
  });
const strip = (s: string) => s.replace(/\/\*[\s\S]*?\*\//g, "").replace(/^\s*\/\/.*$/gm, "");
const sources = walk(extensionsDir)
  .filter((f) => !f.endsWith(".test.ts"))
  .map((f) => ({ file: f, code: strip(readFileSync(f, "utf-8")) }));

// 1+2. KILL_SWITCH_FILE: bound wherever used, and declared in EXACTLY one place.
{
  const declarations: string[] = [];
  const offenders: string[] = [];
  for (const { file, code } of sources) {
    if (!code.includes("KILL_SWITCH_FILE")) continue;
    const declares = /(?:const|let|var)\s+KILL_SWITCH_FILE\s*=/.test(code);
    const imports = /import\s*\{[^}]*\bKILL_SWITCH_FILE\b[^}]*\}\s*from/.test(code);
    if (declares) declarations.push(short(file));
    if (!declares && !imports) offenders.push(short(file));
  }
  deepEqual(offenders, [], `these files USE KILL_SWITCH_FILE unbound (#1419): ${offenders.join(", ")}`);
  deepEqual(declarations, ["extensions/shared/kill-switch.ts"],
    `KILL_SWITCH_FILE must be declared in EXACTLY one place; found: ${declarations.join(", ")}`);
}

// 3. THE GENERAL CLASS GUARD — a const declared inside the `if (Type) { … }`
//    block that registers /loop must NOT be read after that block closes.
//    That is precisely #1419 fault 1's shape, found a SECOND time in this file
//    with `MANIFEST_MTIME_WINDOW_MS` (declared in-block, read 100 lines later
//    from the OUT-OF-BLOCK agent_end handler; the ReferenceError was swallowed
//    by `catch { return true; }`, making every manifest look fresh and silently
//    disabling the 7-day zombie filter). A name-specific guard cannot catch its
//    own successors; this one is structural.
//
//    ⛔ IT COUNTS BRACES, NOT INDENTATION. The first version of this guard
//    required a LEADING WHITESPACE RUN before `const`, so it could not fire on
//    the very shape it was written for: the real declaration sat at COLUMN 0
//    inside the block. Falsifying that guard by re-adding an INDENTED const
//    proved nothing — it tested the guard's happy path, not the defect. The
//    fixture cases below pin the column-0 shape for exactly that reason.
function scanEscapedCaps(srcs: { file: string; code: string }[]) {
  const escaped: string[] = [];
  const unterminated: string[] = [];
  // Braces must be counted with string literals and trailing comments REMOVED.
  // Counting raw characters is trivially disarmed: a single `lines.push("{")`
  // earlier in the block leaves the depth one too high for the rest of it, so
  // every later declaration is skipped while the suite stays green — the same
  // silent-no-op failure the missing-terminator branch below exists to prevent.
  const scrubLine = (l: string) => l
    .replace(/'(?:[^'\\]|\\.)*'/g, "''")
    .replace(/"(?:[^"\\]|\\.)*"/g, '""')
    .replace(/`(?:[^`\\]|\\.)*`/g, "``")
    .replace(/\/\/.*$/, "");
  for (const { file, code } of srcs) {
    const lines = code.split("\n");
    const openAt = lines.findIndex((l) => /\bif\s*\(Type\)\s*\{/.test(l));
    if (openAt === -1) continue;
    // Matched on the RAW line — `scrubLine` strips comments.
    const closeAt = lines.findIndex((l, i) => i > openAt && /\}\s*\/\/\s*if\s*\(Type\)/.test(l));
    // A missing terminator must be REPORTED, never skipped: skipping it turns
    // this guard into a no-op for the whole file while the suite stays green.
    if (closeAt === -1) { unterminated.push(short(file)); continue; }

    // ALL_CAPS is the discriminator: this repo's convention is that an ALL_CAPS
    // const is a MODULE constant, so one at block depth 1 is a mis-scoped module
    // constant rather than a deliberate local. Without it, ordinary locals
    // (`files`, `entries`, `slug`) that share a name with a later read match.
    const inBlock: string[] = [];
    let depth = 0;
    for (let i = openAt; i < closeAt; i++) {
      const line = scrubLine(lines[i]!);
      if (i > openAt && depth === 1) {
        const m = /^[ \t]*(?:const|let|var)\s+([A-Z][A-Z0-9_]*)\s*=/.exec(line);
        if (m) inBlock.push(m[1]!);
      }
      for (const ch of line) { if (ch === "{") depth++; else if (ch === "}") depth--; }
    }
    const after = lines.slice(closeAt + 1).join("\n");
    for (const name of inBlock) {
      const re = new RegExp(`(?<![\\w$.])${name}(?![\\w$])`);
      if (re.test(after)) escaped.push(`${short(file)}: '${name}' is declared inside if (Type) but read after it`);
    }
  }
  return { escaped, unterminated };
}

{
  const { escaped, unterminated } = scanEscapedCaps(sources);
  deepEqual(unterminated, [],
    `an \`if (Type) {\` block has no \`} // if (Type)\` terminator, so the structural guard cannot run for it: ${unterminated.join(", ")}`);
  deepEqual(escaped, [],
    `a const declared inside the if (Type) block is read after it closes — the #1419 free-identifier shape. `
      + `Move it to module scope: ${escaped.join(" | ")}`);

  // ── the guard's own fixtures: it MUST fire on the shape that actually
  //    occurred, which was declared at COLUMN 0 (no indentation).
  const columnZero = [{
    file: resolve(repoRoot, "extensions/fixture/column-zero.ts"),
    code: [
      "export default function (pi: any) {",
      "  if (Type) {",
      "const MANIFEST_MTIME_WINDOW_MS = 7 * 24 * 60 * 60 * 1000;",
      "    pi.on(\"session_start\", () => MANIFEST_MTIME_WINDOW_MS);",
      "  } // if (Type)",
      "  pi.on(\"agent_end\", () => Date.now() < MANIFEST_MTIME_WINDOW_MS);",
      "}",
    ].join("\n"),
  }];
  const hit = scanEscapedCaps(columnZero);
  equal(hit.escaped.length, 1,
    "the structural guard FIRES on a COLUMN-0 mis-scoped const — the falsification must use the real shape, not an indented one");
  equal(hit.escaped[0]!.includes("MANIFEST_MTIME_WINDOW_MS"), true, "…and names it");

  const indented = [{ ...columnZero[0]!, code: columnZero[0]!.code.replace("\nconst", "\n  const") }];
  equal(scanEscapedCaps(indented).escaped.length, 1, "…and still fires on the indented variant");

  const correct = [{ ...columnZero[0]!, code: columnZero[0]!.code.replace("\nconst MANIFEST", "\nconst MANIFEST").replace('  if (Type) {\n', '').replace('  } // if (Type)\n', '') }];
  equal(scanEscapedCaps(correct).escaped.length, 0, "…and does NOT fire once the const is at module scope");

  const noTerminator = [{
    file: resolve(repoRoot, "extensions/fixture/none.ts"),
    code: "  if (Type) {\nconst X_CAPS = 1;\n",
  }];
  equal(scanEscapedCaps(noTerminator).unterminated.length, 1,
    "a missing `} // if (Type)` terminator is REPORTED, not silently skipped");

  // A brace inside a STRING earlier in the block must not push the depth out of
  // range and hide every later declaration.
  const braceInString = [{
    file: resolve(repoRoot, "extensions/fixture/brace-in-string.ts"),
    code: [
      "export default function (pi: any) {",
      "  if (Type) {",
      "    const open = \"{\";",
      "const LATER_CAPS = 1;",
      "  } // if (Type)",
      "  pi.on(\"agent_end\", () => LATER_CAPS);",
      "}",
    ].join("\n"),
  }];
  equal(scanEscapedCaps(braceInString).escaped.length, 1,
    "a brace inside a string must not disarm the guard for the rest of the block");
}

// 3b. ⛔ THE P0 CHANNEL GUARD: the escape must live in the process-global
//     registry, NOT in this module's scope.
//     pi's loader gives EVERY extension its own module graph (a fresh jiti with
//     `moduleCache: false` per extension path), so a module-local `let` is
//     instantiated TWICE: `loop-enforcer` would set its own copy while
//     `sequence-enforcer` — the extension that owns the gates — reads a
//     different, always-null one. The escape would be inert again AND `diagnose`
//     would advertise it. That was the shipped state of the first version of
//     this fix, and it is why the two-instance proof at the end of this file
//     exists.
{
  const code = strip(readFileSync(join(extensionsDir, "shared", "kill-switch.ts"), "utf-8"));
  equal(/^let\s+sessionEscape/m.test(code), false,
    "the escape must NOT be module-local `let` state — the loader gives each extension its own module graph (P0)");
  equal(code.includes("globalThis"), true, "…it must live on `globalThis` (per-realm, shared across those graphs)");
  equal(code.includes("Symbol.for("), true, "…under a realm-wide registry key");

  // Prove the CHANNEL, not just the value: mutate the registry out-of-band and
  // confirm this module instance observes it.
  const g = globalThis as unknown as Record<symbol, { ts: string | null } | undefined>;
  delete g[SESSION_ESCAPE_CELL_KEY];
  clearSessionEscape();
  loopStopEscape(null);
  equal(typeof g[SESSION_ESCAPE_CELL_KEY]?.ts, "string",
    "granting the escape writes it into the process-global registry");
  g[SESSION_ESCAPE_CELL_KEY]!.ts = null;
  equal(isSessionEscaped(), false,
    "…and a clear performed ONLY through globalThis is visible to the module — one cell, not a copy");
  clearSessionEscape();
}

// 4. Wiring guard: the escape must run BEFORE the early return. #1419 fault 2
//    was ORDERING, invisible to a unit test of the escape itself.
{
  const src = readFileSync(join(extensionsDir, "loop-enforcer", "index.ts"), "utf-8");
  const start = src.indexOf('if (action === "stop")');
  equal(start >= 0, true, "loop-enforcer still has a `stop` action");
  const rest = src.slice(start + 1);
  const nextAction = rest.indexOf("if (action ===");
  const block = nextAction === -1 ? src.slice(start) : src.slice(start, start + 1 + nextAction);

  const escapeAt = block.indexOf("loopStopEscape(");
  const earlyReturnAt = block.indexOf("if (!slug) return");
  equal(escapeAt >= 0, true, "the stop action calls the escape");
  equal(earlyReturnAt >= 0, true, "the stop action still short-circuits on no active loop");
  equal(escapeAt < earlyReturnAt, true,
    "#1419 regression: the escape MUST run BEFORE the `if (!slug)` early return — otherwise a "
      + "session blocked at a checkpoint (which has no active loop) cannot self-serve");

  // The `/loop stop` COMMAND is the rescue path the guidance and gate messages
  // name, so it must grant the SAME escape — it used to error with "No active
  // loop to stop." in exactly the state a deadlock is in.
  const caseAt = src.indexOf('case "stop":');
  equal(caseAt >= 0, true, "the /loop command still has a stop case");
  const caseBlock = src.slice(caseAt, src.indexOf('case "pause":', caseAt));
  equal(caseBlock.includes("loopStopEscape("), true,
    "`/loop stop` must grant the session escape too — it is the path the guidance names");
}

// 5. ⛔ The AGENT escape must NOT engage the human's machine-global switch
//    (`skills/enforcement/SKILL.md:11`: "agents must NEVER engage it
//    autonomously"). Pinned structurally, because the tempting "fix" for a
//    deadlocked session is to reach for exactly that file.
{
  const code = strip(readFileSync(join(extensionsDir, "shared", "kill-switch.ts"), "utf-8"));
  const at = code.indexOf("export function loopStopEscape");
  equal(at >= 0, true, "loopStopEscape still exists");
  const body = code.slice(at, code.indexOf("\n}", at));
  equal(body.includes("setKillSwitch("), false,
    "loopStopEscape must NOT write the machine-global kill switch — that is the human's valve");
  equal(body.includes("writeFileSync("), false, "…and must not write any file");
  ok(body.includes("markSessionEscaped("), "…it grants the SESSION escape instead");
}

ok(true, "all kill-switch cases pass");

// ── 6. The TWO-INSTANCE proof (the P0, end to end) ─────────────────────────
// `?instance=2` yields a genuinely DISTINCT module instance in the same process —
// the situation the loader creates for every extension (`moduleCache: false`, one
// jiti per path). A module-local `let` cannot pass this; a `globalThis` cell must.
// Wrapped in an IIFE because this file compiles to CJS, which forbids top-level
// await; an unhandled rejection exits the process non-zero.
(async () => {
  const path = join(extensionsDir, "shared", "kill-switch.ts");
  const first = await import(path);
  const second = await import(path + "?instance=2");
  equal(first === second, false, "the two imports really are distinct module instances");

  clearSessionEscape();
  first.loopStopEscape(null);
  equal(second.isSessionEscaped(), true,
    "a SECOND module instance observes the escape — module-local state could NOT (this was the P0)");
  equal(second.isEnforcementBypassed({}, SWITCH), true, "…and the gate predicate sees it too");

  second.clearSessionEscape();
  equal(first.isSessionEscaped(), false, "…and the two instances share ONE cell in both directions");

  console.log("kill-switch.test OK");
})();
