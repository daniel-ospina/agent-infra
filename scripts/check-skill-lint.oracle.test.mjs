#!/usr/bin/env node
/**
 * check-skill-lint.oracle.test.mjs — dev-machine oracle test for #254.
 *
 * The drift lock: imports pi's REAL bundle and asserts the validator's net
 * consequence matches pi's on the enumerated fixture matrix + the live
 * 121-file corpus + deterministic fuzz. NOT wired into CI (dev machine /
 * cron only — scripts/cron-quality-gates.sh oracle).
 *
 * Run: node scripts/check-skill-lint.oracle.test.mjs
 *      node scripts/check-skill-lint.oracle.test.mjs --write-append <id> <relation> <content-file>
 *
 * Exit: 0 clean / 1 drift (incl. version mismatch) / 2 pi not found or env
 * problem. Blocking legs: fixture parity, live-corpus parity (shadowing-aware
 * loaded set), extraction parity (BOM fixture excluded per D11), adversarial
 * fuzz (FUZZ_SEED=254, N=1000). Consumer sweep (tortoise/eldato when
 * checkouts exist) is REPORT-ONLY — never exit-1 (Task 10 e, #359 sequencing).
 *
 * Version pin: bundle VERSION must equal PI_VERSION_PIN (re-probe
 * deliberately, never soft-skip). PI resolution: PI_NODE_ROOT glob
 * node-v* glob … dist/bundle/index.js → PI_NODE_BIN → command -v pi (probe
 * precedent). Standardized on dist/bundle/index.js — if the bundle path
 * vanishes in a pi upgrade and only dist/index.js survives → hard-fail exit 2
 * with a re-probe message, never silently fall back.
 */

import { strict as assert } from "node:assert";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import {
  extractFrontmatter,
  validateFrontmatter,
} from "./frontmatter-validate.mjs";
import { FIXTURES, PI_VERSION_PIN, FUZZ_SEED } from "./frontmatter-fixtures.mjs";
import { resolvePiBundle } from "./probe-frontmatter-fixtures.mjs";

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const SKILLS_DIR = path.join(REPO_ROOT, "skills");
const FIXTURES_FILE = path.join(REPO_ROOT, "scripts", "frontmatter-fixtures.mjs");

let passed = 0;
let failed = 0;
const reports = [];

function test(name, fn) {
  try {
    fn();
    passed++;
    console.log(`  ✅ ${name}`);
  } catch (err) {
    failed++;
    console.log(`  ❌ ${name}: ${err.message}`);
  }
}
function section(name) {
  console.log(`\n${name}:`);
}
const setEq = (a, b) => a.length === b.length && [...a].sort().join() === [...b].sort().join();

// ── pi bundle ───────────────────────────────────────────────────────────────
let pi;
try {
  const bundlePath = resolvePiBundle();
  if (!/dist[\\/]bundle[\\/]index\.js$/.test(bundlePath)) {
    console.error(`❌ expected the production bundle entry (dist/bundle/index.js), resolved ${bundlePath}`);
    process.exit(2);
  }
  pi = await import(bundlePath);
} catch (e) {
  console.error(`❌ pi not found: ${e.message}`);
  process.exit(2);
}

const piVersion = pi.VERSION;
if (piVersion !== PI_VERSION_PIN) {
  console.error(`❌ pi version drift: live ${piVersion} vs pinned ${PI_VERSION_PIN} — re-probe deliberately (scripts/probe-frontmatter-fixtures.mjs --write), never soft-skip`);
  process.exit(1);
}
console.log(`pi ${piVersion} (bundle) — version pin OK`);

/** pi's net consequence for a full SKILL.md content (real loader, real gate). */
function piConsequence(content) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "oracle-probe-"));
  const skillDir = path.join(dir, "x");
  fs.mkdirSync(skillDir, { recursive: true });
  const full = content.endsWith("\n") ? content : `${content}\n`;
  fs.writeFileSync(path.join(skillDir, "SKILL.md"), full);
  let parseErr = null;
  try {
    pi.parseFrontmatter(full);
  } catch (e) {
    parseErr = e.message.split("\n")[0];
  }
  const r = pi.loadSkillsFromDir({ dir, source: "oracle" });
  const s = r.skills[0] ?? null;
  return { loaded: !!s, name: s ? s.name : null, description: s ? s.description : null, parseErr };
}

// ack-drift classes — validator flags, pi loads (R2 name gates, R5 BOM, R3)
const ACK_DRIFT_P0 = new Set([
  "gate-name-nonstring",
  "gate-name-empty",
  "gate-name-absent",
  "bom-prefixed-frontmatter",
]);
const ACK_DRIFT_P1 = new Set(["truncate-fm-continuation"]);

/** Assert validator verdict vs pi net consequence (D12 semantics). */
function assertParity(verdict, consequence, ctx, { ackDrift = false } = {}) {
  const p0s = verdict.findings.filter((f) => f.severity === "P0").map((f) => f.class);
  const p1s = verdict.findings.filter((f) => f.severity === "P1").map((f) => f.class);
  const hasHardP0 = p0s.some((c) => !ACK_DRIFT_P0.has(c));
  const hasAckP1 = p1s.some((c) => ACK_DRIFT_P1.has(c));
  const hasTruncateP1 = p1s.some((c) => !ACK_DRIFT_P1.has(c));

  if (ackDrift && verdict.findings.length > 0) {
    // fixture-declared divergence — pi must load
    assert.ok(consequence.loaded, `${ctx}: ack-drift fixture must still load in pi (loaded=${consequence.loaded})`);
    return;
  }
  if (hasHardP0) {
    assert.ok(!consequence.loaded, `${ctx}: P0 ${p0s.join(",")} but pi loaded (parseErr=${consequence.parseErr ?? "none"})`);
    return;
  }
  if (hasTruncateP1) {
    // P1 truncate → pi loads with the truncated value
    assert.ok(consequence.loaded, `${ctx}: P1 truncate but pi did not load`);
    return;
  }
  if (hasAckP1) {
    assert.ok(consequence.loaded, `${ctx}: R3 warning but pi did not load`);
    return;
  }
  if (verdict.findings.length === 0) {
    assert.ok(consequence.loaded, `${ctx}: validator clean but pi dropped the skill`);
    return;
  }
  // only ack-drift P0s
  assert.ok(consequence.loaded, `${ctx}: only ack-drift findings but pi did not load`);
}

// ── (a) fixture parity ──────────────────────────────────────────────────────
section("fixture parity — validator verdict + derived data vs pi live consequence");

for (const fx of FIXTURES) {
  test(`fixture ${fx.id} (${fx.expectedRelation})`, () => {
    const verdict = validateFrontmatter(fx.content);
    assert.ok(
      setEq(verdict.findings.map((f) => f.class), fx.expected),
      `validator [${verdict.findings.map((f) => f.class).join(", ")}] != expected [${fx.expected.join(", ")}]`
    );
    const con = piConsequence(fx.content);
    assertParity(verdict, con, `fixture ${fx.id}`, { ackDrift: fx.expectedRelation === "ack-drift-flagged" });
    // description parity for load/load-with-truncation fixtures. Single-line
    // values must match exactly; multi-line/block values (quote-span folding,
    // block-scalar chomp) are a canonical representation, so assert direction
    // (both non-empty strings) instead of byte equality.
    if ((fx.expectedRelation === "load" || fx.expectedRelation === "load-with-truncation") && con.loaded) {
      const derived = String(verdict.data.description);
      const loaded = String(con.description);
      if (fx.content.includes("\n  ") || fx.content.includes("\n    ")) {
        assert.ok(derived.trim() !== "" && loaded.trim() !== "", `fixture ${fx.id}: multi-line description must stay a non-empty string on both sides`);
      } else {
        assert.equal(derived, loaded, `fixture ${fx.id}: derived description != pi loaded description`);
      }
    }
  });
}

// ── (b) live-corpus parity (shadowing-aware) ────────────────────────────────
section("live-corpus parity — validator verdict vs pi net consequence per file");

const corpusFiles = [];
const walk = (d) => {
  for (const e of fs.readdirSync(d, { withFileTypes: true })) {
    if (e.name.startsWith("_") || e.name.startsWith(".") || e.name === "node_modules") continue;
    const full = path.join(d, e.name);
    if (e.isDirectory()) walk(full);
    else if (e.name === "SKILL.md") corpusFiles.push(full);
  }
};
walk(SKILLS_DIR);

/** pi's shadowing-aware loaded set: a dir with its own SKILL.md shadows
 *  nested SKILL.md files (the loader returns on the first SKILL.md hit). */
function piLoadedSet() {
  const loaded = new Set();
  const diag = [];
  const loadDir = (d) => {
    let entries;
    try {
      entries = fs.readdirSync(d, { withFileTypes: true });
    } catch {
      return;
    }
    const skill = entries.find((e) => e.name === "SKILL.md" && e.isFile());
    if (skill) {
      const full = path.join(d, skill.name);
      const r = pi.loadSkillsFromDir({ dir: d, source: "oracle-corpus" });
      for (const s of r.skills) loaded.add(fs.realpathSync(s.filePath));
      diag.push(...r.diagnostics);
      return; // shadowed: nested SKILL.md files are never loaded
    }
    for (const e of entries) {
      if (!e.isDirectory() || e.name.startsWith(".") || e.name === "node_modules") continue;
      loadDir(path.join(d, e.name));
    }
  };
  loadDir(SKILLS_DIR);
  return { loaded, diag };
}

// checkout currency — a stale checkout would give parity against a stale corpus
let checkoutStale = false;
try {
  const head = execFileSync("git", ["rev-parse", "HEAD"], { cwd: REPO_ROOT, encoding: "utf8" }).trim();
  let originMain;
  try {
    originMain = execFileSync("git", ["rev-parse", "origin/main"], { cwd: REPO_ROOT, encoding: "utf8" }).trim();
  } catch {
    originMain = null;
  }
  if (originMain && head !== originMain) {
    checkoutStale = true;
    console.log(`⚠️  checkout is not at origin/main (HEAD ${head.slice(0, 8)} vs origin/main ${originMain.slice(0, 8)}) — corpus parity runs against a possibly-stale skills/ tree`);
  }
} catch {
  /* not a git checkout — skip currency check */
}

test("live corpus: validator verdict matches pi net consequence (shadowing-aware)", () => {
  const { loaded } = piLoadedSet();
  const overFlags = [];
  let checked = 0;
  for (const file of corpusFiles) {
    const content = fs.readFileSync(file, "utf8");
    const verdict = validateFrontmatter(content);
    const con = piConsequence(content);
    const isPiLoaded = loaded.has(fs.realpathSync(file));
    if (isPiLoaded) {
      assertParity(verdict, con, path.relative(REPO_ROOT, file));
      checked++;
    } else {
      // pi skipped the file (shadowed or otherwise) — a validator pass is
      // vacuously consistent; a finding is an over-flag candidate for triage
      if (verdict.findings.length > 0) overFlags.push(`${path.relative(REPO_ROOT, file)}: [${verdict.findings.map((f) => f.class).join(", ")}]`);
      else checked++;
    }
  }
  assert.ok(corpusFiles.length >= 120, `corpus has ${corpusFiles.length} files`);
  assert.ok(checked > 0, "at least one corpus file checked for parity");
  reports.push(`corpus: ${corpusFiles.length} files, ${checked} parity-checked, over-flag candidates: ${overFlags.length}`);
  if (overFlags.length > 0) {
    console.log(`   ⚠️  over-flag candidates (pi-skipped files the validator flags — triage, not parity failures):\n      ${overFlags.join("\n      ")}`);
  }
  if (checkoutStale) {
    console.log("   (corpus leg ran against a stale checkout — re-run after fetching origin/main)");
  }
});

// ── (c) extraction parity ───────────────────────────────────────────────────
section("extraction parity — extractFrontmatter vs pi parseFrontmatter extraction");

const extractionEdges = FIXTURES.filter(
  (f) => f.id.startsWith("extract-") && f.id !== "extract-bom" // D11: BOM fixture excluded
);
for (const fx of extractionEdges) {
  test(`extraction ${fx.id}`, () => {
    const ours = extractFrontmatter(fx.content);
    let theirs = null;
    let parseThrew = false;
    try {
      theirs = pi.parseFrontmatter(fx.content); // returns {frontmatter, body} — no yamlString
    } catch {
      parseThrew = true; // extraction succeeded; the yaml PARSE threw downstream
    }
    if (parseThrew) {
      assert.ok(ours.yamlString !== null, `${fx.id}: pi's parse threw — extraction must have produced a non-null yamlString`);
    } else {
      // body is exposed by both; yamlString shape is inferred from pi's
      // frontmatter (non-empty frontmatter ⟺ non-empty yamlString)
      assert.equal(ours.body, theirs.body, `${fx.id}: body mismatch`);
      const piHasContent = Object.keys(theirs.frontmatter).length > 0;
      const oursHasContent = ours.yamlString !== null && ours.yamlString !== '';
      assert.equal(oursHasContent, piHasContent, `${fx.id}: extraction shape mismatch (pi frontmatter ${JSON.stringify(theirs.frontmatter)})`);
    }
  });
}

// ── (d) adversarial fuzz leg ────────────────────────────────────────────────
section(`adversarial fuzz — deterministic (FUZZ_SEED=${FUZZ_SEED}, N=1000)`);

function mulberry32(seed) {
  let a = seed >>> 0;
  return () => {
    a += 0x6d2b79f5;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const VALUE_POOL = [
  "test value",
  "foo: bar",
  "foo:",
  "foo:bar",
  "https://x.com/a",
  '"quoted value"',
  "'single quoted'",
  "42",
  "-42",
  "1e3",
  "true",
  "yes",
  "2026-08-28",
  "1_000",
  "foo # truncated",
  "foo {a: b} bar",
  "foo [a, b] bar",
  "{a: b}",
  "[a, b]",
  "{a: b} trailing",
  '"x" trailing',
  "l'intention",
  "@at-start",
  "`backtick`",
  "|",
  "|-",
  ">",
  "- item",
  "-item",
  "190:20:30",
  "*nope",
  "&anchor",
  "~",
  "null",
  '"a\n  b"',
  '"a\nb"',
  "continued",
  "sub-key: value",
];
const KEY_POOL = ["name", "description", "steps", "other", "key", "subjects.team"];

function fuzzCase(rand) {
  const lines = [];
  const n = 1 + Math.floor(rand() * 5);
  let usedDesc = false;
  let usedName = false;
  for (let i = 0; i < n; i++) {
    const indent = rand() < 0.25 ? "  " : "";
    const isList = rand() < 0.3;
    const key = KEY_POOL[Math.floor(rand() * KEY_POOL.length)];
    const value = VALUE_POOL[Math.floor(rand() * VALUE_POOL.length)];
    if (key === "name") usedName = true;
    if (key === "description") usedDesc = true;
    if (isList) {
      lines.push(`${indent}- ${key}: ${value}`);
      if (rand() < 0.4) lines.push(`${indent}  extra: line`);
    } else {
      lines.push(`${indent}${key}: ${value}`);
    }
    if (rand() < 0.2) lines.push("");
  }
  if (!usedName) lines.push("name: x");
  if (!usedDesc) lines.push("description: filler");
  return `---\n${lines.join("\n")}\n---\nbody\n`;
}

test(`fuzz N=1000: validator verdict ↔ pi net consequence (seed ${FUZZ_SEED})`, () => {
  const rand = mulberry32(FUZZ_SEED);
  let divergences = 0;
  const firstDivergences = [];
  for (let i = 0; i < 1000; i++) {
    const content = fuzzCase(rand);
    const verdict = validateFrontmatter(content);
    const con = piConsequence(content);
    try {
      assertParity(verdict, con, `fuzz #${i}`);
    } catch (e) {
      divergences++;
      if (firstDivergences.length < 5) {
        firstDivergences.push(`#${i} ${JSON.stringify(content.split("\n").slice(1, -2))} → ${e.message}`);
      }
    }
  }
  reports.push(`fuzz: ${divergences} divergences / 1000`);
  if (divergences > 0) {
    throw new Error(
      `${divergences} fuzz divergences. Triage: node scripts/check-skill-lint.oracle.test.mjs --write-append <id> <relation> <content-file> (or copy the case into scripts/probe-frontmatter-fixtures.mjs FIXTURE_DEFS and re-run --write). First cases:\n      ${firstDivergences.join("\n      ")}`
    );
  }
});

// ── (e) consumer sweep — report-only (Task 10 e, #359 sequencing) ───────────
section("consumer sweep — report-only pre-warning (tortoise/eldato when present)");

for (const name of ["tortoise", "eldato"]) {
  const candidate = path.join(os.homedir(), "Documents", "GitHub", name);
  const sweepDir = fs.existsSync(candidate) && fs.existsSync(path.join(candidate, "skills"))
    ? path.join(candidate, "skills")
    : null;
  if (!sweepDir) {
    console.log(`  ⚠️  ${name} checkout not present — documented skip`);
    continue;
  }
  test(`sweep ${name}/skills (report-only, never exit-1)`, () => {
    const files = [];
    const walkS = (d) => {
      for (const e of fs.readdirSync(d, { withFileTypes: true })) {
        if (e.name.startsWith("_") || e.name.startsWith(".") || e.name === "node_modules") continue;
        const full = path.join(d, e.name);
        if (e.isDirectory()) walkS(full);
        else if (e.name === "SKILL.md") files.push(full);
      }
    };
    walkS(sweepDir);
    const divergences = [];
    for (const file of files) {
      const content = fs.readFileSync(file, "utf8");
      const verdict = validateFrontmatter(content);
      const con = piConsequence(content);
      const p0s = verdict.findings.filter((f) => f.severity === "P0").map((f) => f.class);
      const hasHardP0 = p0s.some((c) => !ACK_DRIFT_P0.has(c));
      if (hasHardP0 && con.loaded) divergences.push(`${path.relative(candidate, file)}: P0 [${p0s.join(",")}] but pi loads`);
      if (!hasHardP0 && verdict.findings.length === 0 && !con.loaded) divergences.push(`${path.relative(candidate, file)}: validator clean but pi drops`);
    }
    reports.push(`consumer-sweep ${name}: ${files.length} files, ${divergences.length} divergences (register for #359 propagation)`);
    if (divergences.length > 0) {
      console.log(`   ⚠️  ${name} divergences (report-only — fixing is #359's propagation work):\n      ${divergences.slice(0, 10).join("\n      ")}`);
    }
  });
}

// ── --write-append triage path ──────────────────────────────────────────────
const appendIdx = process.argv.indexOf("--write-append");
if (appendIdx >= 0) {
  const id = process.argv[appendIdx + 1];
  const relation = process.argv[appendIdx + 2];
  const contentFile = process.argv[appendIdx + 3];
  if (!id || !relation || !contentFile || !fs.existsSync(contentFile)) {
    console.error("Usage: node scripts/check-skill-lint.oracle.test.mjs --write-append <id> <relation> <content-file>");
    process.exit(2);
  }
  const content = fs.readFileSync(contentFile, "utf8");
  const verdict = validateFrontmatter(content);
  const con = piConsequence(content);
  const entry = {
    id,
    class: "fuzz-triage",
    expected: verdict.findings.map((f) => f.class).sort(),
    expectedRelation: relation,
    content,
    piConsequence: { parseErr: con.parseErr, loaded: con.loaded, name: con.name, description: con.description, diagnostics: [] },
    _appended: true,
  };
  const fixtureSrc = fs.readFileSync(FIXTURES_FILE, "utf8");
  const marker = "// ── fuzz-triage append region (--write-append; regenerate via probe --write) ──";
  let next;
  const entries = fixtureSrc.indexOf(marker) >= 0
    ? fixtureSrc.slice(0, fixtureSrc.indexOf(marker))
    : fixtureSrc.replace(/export const FIXTURES = (\[[\s\S]*?\]);\s*$/, "export const FIXTURES = $1;");
  if (fixtureSrc.indexOf(marker) < 0) {
    next = fixtureSrc.replace(/\n\s*\];\s*$/, ",\n  ];\n\n") + "\n" + marker + "\n";
  }
  const body = fixtureSrc.indexOf(marker) >= 0 ? fixtureSrc : next;
  const updated = body.endsWith(marker + "\n")
    ? body + JSON.stringify(entry, null, 2) + ",\n"
    : body.replace(new RegExp(marker + "\\n"), marker + "\n" + JSON.stringify(entry, null, 2) + ",\n");
  fs.writeFileSync(FIXTURES_FILE, updated);
  console.log(`✅ appended ${id} (${relation}) to ${FIXTURES_FILE} — review, then regenerate with probe --write after moving it into FIXTURE_DEFS`);
  process.exit(0);
}

// ── summary ─────────────────────────────────────────────────────────────────
console.log(`\nreports:`);
for (const r of reports) console.log(`  - ${r}`);
console.log(`\ncheck-skill-lint.oracle.test.mjs: ${passed} passed, ${failed} failed`);
if (failed > 0) {
  console.error("❌ ORACLE DRIFT DETECTED");
  process.exit(1);
}
console.log("✅ ORACLE CLEAN — linter verdicts match pi's loader on fixtures + corpus + fuzz");
process.exit(0);
