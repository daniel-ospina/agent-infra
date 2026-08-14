// Never-unbounded nested-pi drift guard (#206) — source assertions only.
//
// Pins Indicators 1–3 of issue #206 across the three launch-path skills:
//   I1 — using-git-worktrees carries the terminal guard-escape one-liner
//   I2 — all three skills carry the never-unbounded rule + bounded markers
//   I3 — every nested/background launch example carries the bounded pattern
//
// Pattern: #178 (test-git-freshness.mjs) — plain node, no deps, reads
// repo-relative skills/<name>/SKILL.md paths. Runs via the CI glob
// extensions/*/test*.mjs — no workflow change needed.
//
// Run: node extensions/shared/test-never-unbounded.mjs
import { readFileSync } from "node:fs";
import { join, resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const PROJECT_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");

let pass = 0, fail = 0;
function check(name, cond, detail = "") {
  console.log(`${cond ? "✅" : "❌"} ${name}${cond || !detail ? "" : ` — ${detail}`}`);
  cond ? pass++ : fail++;
}

const SKILLS = {
  "using-git-worktrees": readFileSync(join(PROJECT_ROOT, "skills/using-git-worktrees/SKILL.md"), "utf8"),
  "parallel-orchestrator": readFileSync(join(PROJECT_ROOT, "skills/parallel-orchestrator/SKILL.md"), "utf8"),
  "subagent-driven-development": readFileSync(join(PROJECT_ROOT, "skills/subagent-driven-development/SKILL.md"), "utf8"),
};

// Normalize: lowercase + strip backticks so a rule written as
// "never launch an unbounded nested `pi`" matches the canonical token.
const norm = (s) => s.toLowerCase().replace(/`/g, "");

// ── I1: terminal guard escape in using-git-worktrees ──────────────────────
// Canonical section names can vary (#218 merged "### Stranded main checkout —
// the ONLY sanctioned recovery is a terminal one-liner (#206)"); pin the
// CONTENT: the one-liner + user-terminal-only framing + "guard escape" or
// "sanctioned" designation.
const ugw = SKILLS["using-git-worktrees"];
check("I1 one-liner present (git checkout main && git pull --ff-only)",
  ugw.includes("git checkout main && git pull --ff-only"));
check("I1 'sanctioned' escape designation present", /sanctioned|guard escape/i.test(ugw));
const escapeSecStart = Math.max(
  ugw.indexOf("Stranded main checkout"),
  ugw.indexOf("Guard Escape (Terminal Recovery)"),
);
const escapeSec = escapeSecStart >= 0 ? ugw.slice(escapeSecStart, ugw.indexOf("## Integration") >= 0 ? ugw.indexOf("## Integration") : undefined) : "";
check("I1 escape section found (Stranded / Guard Escape)",
  escapeSec.length > 100);
check("I1 escape is user-terminal-only (user + terminal in the section)",
  /user/i.test(escapeSec) && /terminal/i.test(escapeSec));

// ── I2: never-unbounded rule + bounded markers in all three skills ────────
const I2_TOKENS = [
  "Never launch an unbounded nested pi",
  "liveness",
  "2>&1",
  "kill -0",
  "sleep 1800",
  "TASK_HEARTBEAT=1",
  "PI_MODE=print",
];
for (const [name, text] of Object.entries(SKILLS)) {
  for (const tok of I2_TOKENS) {
    check(`I2 ${name} contains ${JSON.stringify(tok)}`, norm(text).includes(norm(tok)));
  }
}

// ── I3: deadline-watchdog block in every file + Pre-Warming retrofit ─────
const WATCHDOG_RE = /sleep\s+1800[\s\S]{0,400}kill\s+-0/;
for (const [name, text] of Object.entries(SKILLS)) {
  check(`I3 ${name} carries the deadline-watchdog block`, WATCHDOG_RE.test(text));
}
const po = SKILLS["parallel-orchestrator"];
const prewarm = po.slice(po.indexOf("## Pre-Warming Pattern"), po.indexOf("## Integration"));
check("I3 parallel-orchestrator Pre-Warming retrofit carries the watchdog",
  WATCHDOG_RE.test(prewarm));

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail > 0 ? 1 : 0);
