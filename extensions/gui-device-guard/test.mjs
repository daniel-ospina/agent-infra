// Regression tests for extensions/gui-device-guard (issue #2249).
//
// The suite loads the REAL ./index.ts through ../main-worktree-guard/module-load-hooks.mjs
// (Node type-stripping + a stubbed @earendil-works/pi-coding-agent — the same shapes
// pi's jiti loader produces) and drives the REAL registered `tool_call` handler. That
// is the #744/#697 lesson: a suite that imports only a helper stays green while index.ts
// is broken and the guard is inert in every session.
//
// Every row below is a declared threat-surface entry from the module header. The BLOCK
// rows pin WHICH rule fired, so a row cannot pass for the wrong reason, and each has an
// ALLOW twin so a guard that blocks everything fails as loudly as one that blocks nothing.
//
// Usage:
//   node extensions/gui-device-guard/test.mjs                          # the suite
//   node extensions/gui-device-guard/test.mjs --classify <command…>    # one classification
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { register, registerHooks } from "node:module";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const HERE = fileURLToPath(new URL(".", import.meta.url));
const INDEX_TS = join(HERE, "index.ts");

// ── load the real module (shared with the #744 loader harness) ──────────────
const hooks = await import(new URL("../main-worktree-guard/module-load-hooks.mjs", import.meta.url).href);
if (typeof registerHooks === "function") {
  registerHooks({ resolve: hooks.resolve, load: hooks.load });
} else {
  register(new URL("../main-worktree-guard/module-load-hooks.mjs", import.meta.url), import.meta.url);
}
const mod = await import(pathToFileURL(INDEX_TS).href);
const laneMod = await import(new URL("../shared/headless-lane.ts", import.meta.url).href);
const classify = mod.classifyLaunchCommand;
const FAKE = [mod.FAKE_DEVICE_FLAG, mod.FAKE_UI_FLAG].join(" ");

// ── CLI mode (one classification, for a hand check and for the docs) ────────
if (process.argv[2] === "--classify") {
  const cmd = process.argv.slice(3).join(" ");
  console.log(JSON.stringify(classify(cmd), null, 2));
  process.exit(0);
}

let pass = 0;
let fail = 0;
function check(name, ok, detail = "") {
  console.log(`${ok ? "✅" : "❌"} ${name}${ok || !detail ? "" : ` — ${detail}`}`);
  ok ? pass++ : fail++;
}

// ── hermetic fixture ───────────────────────────────────────────────────────
const FIX = mkdtempSync(join(tmpdir(), "gui-device-guard-"));
const LEDGER = join(FIX, "state", "host-app-launches.jsonl");
const saveEnv = { ...process.env };
function ledgerRows() {
  if (!existsSync(LEDGER)) return [];
  return readFileSync(LEDGER, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l));
}
function resetLedger() {
  rmSync(LEDGER, { force: true });
}

// ── the classifier: the threat table ───────────────────────────────────────
// [name, command, expected finding count, expected rule|null, expected media]
const ROWS = [
  // L1 — THE INCIDENT, verbatim.
  ["L1 incident: npm exec electron .", "npm exec electron .", 1, "electron", true],
  ["L2 npx electron .", "npx electron .", 1, "electron", true],
  ["L3 bare electron", "electron --inspect=0 .", 1, "electron", true],
  ["L4 local node_modules/.bin/electron", "node_modules/.bin/electron .", 1, "electron", true],
  ["L5 Electron bundle binary (argv shape that ps missed)", "/Applications/DMeer.app/Contents/MacOS/DMeer", 1, "electron", true],
  ["L6 npm exec -- electron", "npm exec -- electron .", 1, "electron", true],
  // L7 — an Electron launch behind a prefix-like word / env prefix.
  ["L7 prefixed: sudo -u root electron .", "sudo -u root electron .", 1, "electron", true],
  ["L8 env-prefixed: FOO=1 electron .", "FOO=1 electron .", 1, "electron", true],
  // L9 — macOS open of a named app: RECORDED, never blocked (media=false).
  ["L9a open -a Safari", "open -a Safari", 1, "open", false],
  ["L9b open -a 'Google Chrome'", 'open -a "Google Chrome" https://x.test', 1, "open", false],
  ["L9c open -b bundle id", "open -b com.apple.Safari", 1, "open", false],
  ["L9d open a .app path", "open ./Build/DMeer.app", 1, "open", false],
  // L10 — headed browser runs can present a REAL device picker.
  ["L10a playwright --headed", "npx playwright test --headed", 1, "playwright", true],
  ["L10b PWDEBUG", "PWDEBUG=1 npx playwright test", 1, "playwright", true],
  ["L10c --ui mode", "npx playwright test --ui", 1, "playwright", true],
  // ── ALLOW rows: none of these may be refused ──────────────────────────────
  ["A1 plain grep", "grep -rn TODO src/", 0, null, false],
  ["A2 an ELECTRON MENTION inside quotes is not a launch", 'echo "npm exec electron ."', 0, null, false],
  ["A3 a mention in a commit message", "git commit -F - <<'EOF'\nelectron . is what broke\nEOF", 0, null, false],
  ["A4 headless playwright (the friction row)", "npx playwright test", 0, null, false],
  ["A5 open with no app flag", "open .", 0, null, false],
  ["A6 a path merely NAMING electron", "ls /usr/lib/electron/", 0, null, false],
  ["A7 electron as a non-command argument", "rg electron .", 0, null, false],
  ["A8 npm run of an unrelated script", "npm run build", 0, null, false],
  ["A9 a second, innocent segment after a launch", "true && ls -la", 0, null, false],
];

for (const [name, cmd, count, rule, media] of ROWS) {
  const found = classify(cmd);
  const okCount = found.length === count;
  const okRule = rule === null ? true : found.some((f) => f.rule === rule);
  const okMedia = rule === null ? true : found.some((f) => f.media === media);
  check(
    `classify: ${name}`,
    okCount && okRule && okMedia,
    `count=${found.length} (want ${count}) rules=[${found.map((f) => f.rule)}] media=[${found.map((f) => f.media)}]`,
  );
}

// ── L11 — the fake-capture mitigation is RECOGNISED (both switches required) ─
check(
  "L11a electron WITH both fake switches is classified faked",
  classify(`electron . ${FAKE}`).every((f) => f.faked === true),
);
check(
  "L11b HALF the switches is not a mitigation (one flag is not enough)",
  classify(`electron . ${mod.FAKE_DEVICE_FLAG}`).every((f) => f.faked === false),
);
check(
  "L11c a fake switch in ANOTHER segment does not cover the launch",
  classify(`electron . && echo ${FAKE}`)[0].faked === false,
);
// L12 — a launch embedded after a separator is still a launch.
check(
  "L12 a launch after `&&` is still classified",
  classify("npm ci && npm exec electron .").some((f) => f.rule === "electron"),
);

// ── the registered handler is what actually runs in a session ──────────────
let handler = null;
mod.default({ on: (event, fn) => { if (event === "tool_call") handler = fn; } });
check("registration: tool_call handler installed", typeof handler === "function");

async function drive(command, env = {}) {
  process.env = { ...saveEnv, PI_MODE: "print", GUI_DEVICE_GUARD_RECORD: LEDGER, ...env };
  for (const k of ["GUI_DEVICE_GUARD_DISABLED", "GUI_DEVICE_GUARD_ALLOW_MEDIA"]) {
    if (!(k in env)) delete process.env[k];
  }
  try {
    return await handler({ toolName: "bash", input: { command } }, {});
  } finally {
    process.env = { ...saveEnv };
  }
}

if (handler) {
  // ── H1/H2 — the incident is BLOCKED, with a reason that is actionable ─────
  resetLedger();
  const blocked = await drive("npm exec electron .");
  check("H1 handler: BLOCKS the #2249 incident shape", Boolean(blocked?.block));
  check(
    "H2 the reason names the incident, the remedy flags and the ledger",
    typeof blocked?.reason === "string" &&
      blocked.reason.includes("#2249") &&
      blocked.reason.includes(mod.FAKE_DEVICE_FLAG) &&
      blocked.reason.includes(mod.FAKE_UI_FLAG) &&
      blocked.reason.includes(LEDGER),
    String(blocked?.reason ?? "").slice(0, 200),
  );

  // ── H3 — and it is RECORDED, which is the half that survives a refusal ───
  const rows = ledgerRows();
  check("H3 handler: the blocked launch wrote ONE ledger row", rows.length === 1, `rows=${rows.length}`);
  if (rows.length === 1) {
    const r = rows[0];
    check(
      "H3a the row carries the launch identity (rule/app/argv/cwd/pid/decision)",
      r.event === "host-app-launch" &&
        r.rule === "electron" &&
        r.app === "Electron" &&
        r.argv === "npm exec electron ." &&
        r.cwd === process.cwd() &&
        Number.isInteger(r.pid) &&
        r.decision === "block" &&
        r.issue === 2249,
      JSON.stringify(r).slice(0, 260),
    );
  }

  // ── H4 — a RECORD-ONLY launch: the ledger keeps it, the tool call proceeds ─
  resetLedger();
  const opened = await drive("open -a Safari");
  check("H4 handler: a plain GUI app launch is ALLOWED", opened === undefined);
  const openRows = ledgerRows();
  check(
    "H4a …but RECORDED (this is the row that would have cut #2249 to one lookup)",
    openRows.length === 1 && openRows[0].rule === "open" && openRows[0].app === "Safari" &&
      openRows[0].decision === "record",
    JSON.stringify(openRows).slice(0, 220),
  );

  // ── H5 — the mitigated launch runs and records faked=true ────────────────
  resetLedger();
  const faked = await drive(`npm exec electron . ${FAKE}`);
  check("H5 handler: an Electron launch WITH the fake switches is allowed", faked === undefined);
  const fakedRows = ledgerRows();
  check("H5a …and recorded with faked=true", fakedRows.length === 1 && fakedRows[0].faked === true);

  // ── H6 — nothing GUI: no verdict AND no ledger write (no noise) ──────────
  resetLedger();
  const quiet = await drive("grep -rn TODO src/");
  check("H6 handler: a non-GUI command is allowed", quiet === undefined);
  check("H6a …and writes NO ledger row", ledgerRows().length === 0, `rows=${ledgerRows().length}`);

  // ── H7 — the escape hatch: allowed, and STILL recorded (disclosed) ───────
  resetLedger();
  const allowed = await drive("npm exec electron .", { GUI_DEVICE_GUARD_ALLOW_MEDIA: "1" });
  check("H7 handler: GUI_DEVICE_GUARD_ALLOW_MEDIA=1 permits one real-device run", allowed === undefined);
  const allowedRows = ledgerRows();
  check(
    "H7a …and the permitted launch is recorded with decision=record (not hidden)",
    allowedRows.length === 1 && allowedRows[0].decision === "record",
    JSON.stringify(allowedRows).slice(0, 200),
  );

  // ── H8 — the kill switch is total ────────────────────────────────────────
  resetLedger();
  const killed = await drive("npm exec electron .", { GUI_DEVICE_GUARD_DISABLED: "1" });
  check("H8 handler: GUI_DEVICE_GUARD_DISABLED=1 disables the guard entirely", killed === undefined);
  check("H8a …including the ledger write", ledgerRows().length === 0);

  // ── H9 — an INTERACTIVE session is never guarded. The audience of #2249 is
  //        an unattended run; a human typing `open -a Safari` is not the bug,
  //        and a guard that refuses him is the category-B friction this repo
  //        has already paid for.
  //
  //        `laneContract()` MEMOISES on purpose (a session does not change its
  //        mode mid-run), so the earlier print-mode arms left `lane: true`
  //        cached. Forgetting the memo makes the contract re-derive from THIS
  //        argv/env, which is what an interactive process would have measured.
  resetLedger();
  process.env = { ...saveEnv, GUI_DEVICE_GUARD_RECORD: LEDGER };
  delete process.env.PI_MODE;
  laneMod._resetLaneContractForTest();
  const savedArgv = process.argv;
  process.argv = ["node", "test.mjs"]; // no -p, no --print
  let interactive;
  try {
    interactive = await handler({ toolName: "bash", input: { command: "npm exec electron ." } }, {});
  } finally {
    process.argv = savedArgv;
    process.env = { ...saveEnv };
    laneMod._resetLaneContractForTest();
  }
  check(
    "H9 handler: an INTERACTIVE session is not guarded (only an unattended run is)",
    interactive === undefined,
    "the interactive arm fired — check isUnattended()'s print-mode/lane derivation",
  );
  check("H9a …and wrote no ledger row either", ledgerRows().length === 0, `rows=${ledgerRows().length}`);

  // ── H10 — a non-bash tool is never inspected ────────────────────────────
  process.env = { ...saveEnv, PI_MODE: "print", GUI_DEVICE_GUARD_RECORD: LEDGER };
  const other = await handler({ toolName: "read", input: { path: "x" } }, {});
  process.env = { ...saveEnv };
  check("H10 handler: ignores non-bash tools", other === undefined);

  // ── H11 — an unwritable ledger must be LOUD, never silent, and must not
  //         break the lane over a full disk (#2249: "silence is not an
  //         acceptable answer").
  resetLedger();
  const warned = [];
  const wrote = mod.recordLaunch(
    { event: "host-app-launch", ts: "t", issue: 2249, decision: "record", rule: "open",
      app: "Safari", argv: "open -a Safari", media: false, faked: false, cwd: "/",
      pid: 1, ppid: 0, host: "h", lane: false, tag: null },
    join(FIX, "a-file-not-a-dir"),
    (m) => warned.push(m),
  );
  // The parent path is a regular file, so mkdir must fail.
  const unwritable = join(FIX, "blocker");
  writeFileSync(unwritable, "x");
  const warned2 = [];
  const wrote2 = mod.recordLaunch(
    { event: "host-app-launch", ts: "t", issue: 2249, decision: "record", rule: "open",
      app: "Safari", argv: "open -a Safari", media: false, faked: false, cwd: "/",
      pid: 1, ppid: 0, host: "h", lane: false, tag: null },
    join(unwritable, "nested", "ledger.jsonl"),
    (m) => warned2.push(m),
  );
  check("H11 a failed ledger write returns false and WARNS (never silent)",
    wrote2 === false && warned2.length === 1 && /NOT recorded/.test(warned2[0]),
    `wrote2=${wrote2} warn=${JSON.stringify(warned2).slice(0, 200)} (first probe wrote=${wrote})`);
}

// ── drift pins ─────────────────────────────────────────────────────────────
const source = readFileSync(INDEX_TS, "utf8");
check("drift-pin: imports shared/git-command-parse.js (the ONE quote model)",
  source.includes('from "../shared/git-command-parse.js"'));
check("drift-pin: imports shared/print-mode.js + shared/headless-lane.js (derived, not launcher-set)",
  source.includes('from "../shared/print-mode.js"') && source.includes('from "../shared/headless-lane.js"'));
check("drift-pin: does not re-implement a quote model",
  !/function\s+unquotedMask/.test(source));
check("drift-pin: imports the ONE isToolCallEventType copy (#1330)",
  source.includes('from "../shared/tool-call-event.js"'));

// ── non-vacuity floor: the table is not empty and both polarities ran ──────
check("non-vacuity: the threat table carries >= 20 rows", ROWS.length >= 20, `rows=${ROWS.length}`);
check("non-vacuity: the table holds BLOCK rows and ALLOW rows",
  ROWS.some((r) => r[2] > 0) && ROWS.some((r) => r[2] === 0));
check("non-vacuity: the handler was driven", handler !== null && pass >= 25, `pass=${pass}`);

rmSync(FIX, { recursive: true, force: true });

console.log(`\n${fail === 0 ? "✅" : "❌"} gui-device-guard suite: ${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
