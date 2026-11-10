#!/usr/bin/env node
/**
 * test-verdict.mjs — the pin for the shared verdict emitter (agent-infra#2723).
 *
 * WHY A SUITE FOR A THREE-LINE EMITTER. The defect it closes is not "a line was
 * written wrong"; it is that SIXTEEN harnesses each wrote the line themselves, in
 * five shapes, and only one of those shapes was readable by the merge rail. Fixing
 * sixteen files closes today's sixteen and pins nothing about tomorrow's
 * seventeenth — which is exactly how the gap moved from
 * `check-pipeline-compliance.sh` (#1185) to the `verify` job (#2723) in the first
 * place. So this suite pins TWO things, and the second is the one that matters:
 *
 *   1. the emitter's output IS parseable — proved by running the rail's OWN
 *      parser (`scripts/ci_exemption.py ids`) over the emitter's output, not by
 *      matching a string this file also owns. A test that re-states the format can
 *      only agree with itself;
 *   2. every zero-dep `node` harness a workflow runs goes through the emitter, so
 *      a new harness cannot reintroduce an unattributable aggregate. This is the
 *      drift pin, and it reads the SAME workflow files the runner reads rather
 *      than a list kept here (a hand-kept list IS the drift it would be pinning).
 *
 * ZERO-DEPENDENCY: `node:*` + the repo's own `extensions/shared/verdict.mjs`.
 * Usable in the `verify` job with no `npm ci`. It shells out to
 * `python3.12` for (1); when that interpreter is absent the round-trip is a NAMED
 * skip, reported in the aggregate, never a silent pass.
 *
 * WIRING HONESTY: per-PR this suite is VISIBLE but NOT merge-blocking (the repo's
 * only required check is `pipeline-compliance`), the same disclosure its sibling
 * post-merge suites carry.
 *
 * Run: node extensions/shared/test-verdict.mjs
 */

import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { reportVerdict, verdictLine } from "./verdict.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(HERE, "..", "..");
const WORKFLOWS = join(REPO, ".github", "workflows");
const PARSER = join(REPO, "scripts", "ci_exemption.py");

let pass = 0;
let fail = 0;
let skip = 0;

function ok(name) {
  pass++;
  console.log(`  ✅ ${name}`);
}
function bad(name, detail) {
  fail++;
  console.log(`  ❌ ${name}${detail ? `\n     ${detail}` : ""}`);
}
function eq(name, got, want) {
  if (JSON.stringify(got) === JSON.stringify(want)) ok(name);
  else bad(name, `got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`);
}
function contains(name, hay, needle) {
  if (hay.includes(needle)) ok(name);
  else bad(name, `missing ${JSON.stringify(needle)} in:\n${hay}`);
}

// ── 1. the emitter's own format ─────────────────────────────────────────────
console.log("\n#1 the attributable form");

// The parser's family, restated as the CONTRACT the emitter must satisfy. This is
// deliberately the rail's regex and not a friendlier one: an emitter that only
// agrees with a test-local pattern is the "fix that never fires" class.
const RAIL_AGG =
  /^(?:❌|✗)\s*\*{0,2}\s*([A-Za-z0-9_][A-Za-z0-9_.-]*?)\s*\*{0,2}:\s*(\d+)\s+passed,\s+(\d+)\s+failed/;

eq("a failing verdict is `❌ <label>: N passed, M failed`",
  verdictLine("test-x", 12, 6), "❌ test-x: 12 passed, 6 failed");
eq("a green verdict is `✅ <label>: N passed, 0 failed`",
  verdictLine("test-x", 12, 0), "✅ test-x: 12 passed, 0 failed");
eq("skips render only when non-zero",
  verdictLine("test-x", 12, 0, { skip: 3 }), "✅ test-x: 12 passed, 0 failed, 3 skipped");
eq("a zero skip adds no `, 0 skipped` tail",
  verdictLine("test-x", 12, 1, { skip: 0 }), "❌ test-x: 12 passed, 1 failed");

const m = RAIL_AGG.exec(verdictLine("test-x", 12, 6));
if (m && m[1] === "test-x") ok("the line matches the rail's runner-aggregate family, labelled `test-x`");
else bad("the line matches the rail's runner-aggregate family", `match=${JSON.stringify(m && m.slice(0, 3))}`);

// `red` — a whole-suite skip must not report `0 failed`, because the parser
// treats a 0-failed aggregate as a PASS line and the identity would vanish.
eq("`red` over zero counted failures still reports one failure",
  verdictLine("test-x", 0, 0, { skip: 1, red: true }), "❌ test-x: 0 passed, 1 failed, 1 skipped");
eq("`red` over an already-failing suite does not inflate the count",
  verdictLine("test-x", 3, 4, { red: true }), "❌ test-x: 3 passed, 4 failed");

// A label the parser cannot read IS the defect. It must throw at the PRODUCER,
// where the stack names the harness, instead of vanishing into the log.
for (const badLabel of ["", "with space", "slash/here", "#755 tripwire", "(d2)"]) {
  let threw = false;
  try { verdictLine(badLabel, 1, 1); } catch { threw = true; }
  if (threw) ok(`an unattributable label ${JSON.stringify(badLabel)} throws at the producer`);
  else bad(`an unattributable label ${JSON.stringify(badLabel)} throws at the producer`, "it returned a line");
}

// ── 2. round-trip through the RAIL'S OWN parser ─────────────────────────────
console.log("\n#2 the rail's parser reads it (scripts/ci_exemption.py)");

const LABELS = [
  "command-position",
  "sanctioned-identity",
  "sanctioned-pin-merge-base",
  "script-backdoor",
  "test-nested-worktree",
  "test-unborn-head",
  "test-hub-sweep",
  "test-discard-gate",
  "test-remote-context",
  "test-m4-recovery-window",
  "test-module-load",
  "test-infra-verify-scan",
  "test-is-main",
  "test-cwd-guard",
  "test-subtract-scope",
  "search-guard-suite",
  "gui-device-guard-suite",
  "test-pool-hygiene",
];

const tmp = mkdtempSync(join(tmpdir(), "verdict-pin-"));
try {
  const log = join(tmp, "capture.log");
  // The vacuous-skip shape, which is the one that used to vanish (0 failed). If
  // this shape round-trips, the ordinary failing shape does too — it is the
  // strictly easier case, and it is asserted directly in #1.
  writeFileSync(log, LABELS.map((l) => verdictLine(l, 0, 0, { skip: 1, red: true })).join("\n") + "\n");
  const pythons = ["python3.12", "python3"].filter(
    (py) => spawnSync(py, ["--version"], { encoding: "utf8" }).status === 0
  );
  if (pythons.length === 0) {
    // Declared, not silent: #1 still pinned the format, and the aggregate below
    // reports the clip so a reader can see the coverage was reduced.
    skip++;
    console.log("  ⏭️  SKIPPED (#2): no python3.12/python3 on PATH, so the rail's parser was not executed.");
    console.log("      Only the parser ROUND-TRIP is unmeasured here; the emitter's format is pinned in #1.");
  } else if (!existsSync(PARSER)) {
    bad("#2 the rail's parser is present", `missing ${PARSER}`);
  } else {
    const r = spawnSync(pythons[0], [PARSER, "ids", "--log", log], { encoding: "utf8" });
    const out = `${r.stdout ?? ""}${r.stderr ?? ""}`;
    eq(`#2 the parser exits 0 over ${LABELS.length} attributable lines`, r.status, 0);
    for (const l of LABELS) contains(`#2 the parser extracts runner::${l}`, out, `runner::${l}`);
    contains("#2 the parser drops nothing as unattributable", out, "unattributable=0");
  }
} finally {
  rmSync(tmp, { recursive: true, force: true });
}

// ── 3. THE DRIFT PIN — every workflow-run node harness uses the emitter ─────
console.log("\n#3 no workflow-run harness hand-rolls its own aggregate");

// Harnesses that are NOT in this family, each with a reason. A name here is a
// MEASURED exemption, not a convenience: `node --test` prints TAP (`not ok`,
// `# fail N`), which is a different identity family and has to be solved there,
// not by this emitter. They are listed explicitly so a third name cannot appear
// silently — the pin fails for anything neither using the emitter nor exempt.
const EXEMPT = new Map([
  ["scripts/check-version-stamp.test.mjs",
    "run via `node --test`: TAP output (`not ok`, `# fail N`) — a different identity family"],
  ["scripts/tortoise-memory.test.mjs",
    "run via `node --test`: TAP output (`not ok`, `# fail N`) — a different identity family"],
]);

// Where a workflow materialises a harness from somewhere else (a `$RUNNER_TEMP`
// copy step), the repo file of the same basename is the source of truth.
const COPY_SOURCE_DIRS = [
  "extensions/http-pool-hygiene",
  "extensions/shared",
  "extensions/main-worktree-guard",
  "extensions/verification-gate",
];

function resolveHarness(token) {
  if (existsSync(join(REPO, token))) return token;
  const base = token.split("/").pop();
  for (const dir of COPY_SOURCE_DIRS) {
    const p = join(dir, base);
    if (existsSync(join(REPO, p))) return p;
  }
  return null;
}

function workflowNodeHarnesses() {
  const found = new Map(); // repo-relative path -> the workflow that runs it
  const files = readdirSync(WORKFLOWS).filter((f) => f.endsWith(".yml") || f.endsWith(".yaml"));
  for (const wf of files) {
    const body = readFileSync(join(WORKFLOWS, wf), "utf8");
    for (const line of body.split("\n")) {
      if (!/^\s*(?:-\s*)?run:/.test(line) || !/\bnode\b/.test(line)) continue;
      for (const token of line.match(/[A-Za-z0-9_./-]+\.mjs/g) ?? []) {
        const resolved = resolveHarness(token);
        if (resolved) found.set(resolved, wf);
      }
    }
  }
  return found;
}

const harnesses = workflowNodeHarnesses();
// VACUITY GUARD: an enumeration that finds nothing makes every assertion below
// pass over an empty set — the false-PASS shape this whole issue is about.
if (harnesses.size >= 10) ok(`#3 the enumeration found ${harnesses.size} workflow-run node harnesses (a non-empty corpus)`);
else bad("#3 the enumeration found a non-empty corpus", `only ${harnesses.size} — the scan itself is broken`);

const sorted = [...harnesses.keys()].sort();
for (const path of sorted) {
  const wf = harnesses.get(path);
  const body = readFileSync(join(REPO, path), "utf8");
  const emitterImport = String.raw`(?:^|\n)\s*import\s+\{[^}]*\breportVerdict\b[^}]*\}\s+from\s+["'][./][^"']*verdict\.mjs["']`;
  if (new RegExp(emitterImport).test(body)) { ok(`#3 ${path} (${wf}) emits through reportVerdict`); continue; }
  if (EXEMPT.has(path)) { ok(`#3 ${path} (${wf}) is exempt — ${EXEMPT.get(path)}`); continue; }
  bad(`#3 ${path} (${wf}) emits through reportVerdict`,
    "it neither imports the shared emitter nor carries a measured exemption, so a failing run of it " +
    "yields NO identity and the merge rail refuses the PR blind (#2723)");
}

// The complementary half: none may ALSO keep a hand-rolled aggregate BESIDE the
// emitter. A second, unlabelled `console.log` aggregate is worse than none — it is
// the line a reader (and a future parser) is most likely to trust.
for (const path of sorted) {
  const offenders = readFileSync(join(REPO, path), "utf8")
    .split("\n")
    .map((line, i) => [i + 1, line])
    .filter(([, line]) => /console\.(?:log|error|warn)\(/.test(line))
    .filter(([, line]) => /passed, /.test(line));
  if (offenders.length === 0) ok(`#3 ${path} prints no hand-rolled aggregate`);
  else bad(`#3 ${path} prints no hand-rolled aggregate`,
    offenders.map(([n, l]) => `line ${n}: ${l.trim()}`).join("\n     "));
}

// ── aggregate ───────────────────────────────────────────────────────────────
reportVerdict("test-verdict", pass, fail, { skip });
process.exit(fail === 0 ? 0 : 1);
