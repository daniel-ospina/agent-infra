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
 *      ⛔ IT READS EVERY WAY THIS REPO INVOKES A HARNESS **BY NAME**, not just
 *      `run: node x` on one line — see `commandTokens()`. Scoping the scan to a
 *      single line was a false PASS over an incomplete corpus (#2723 review,
 *      2026-11-10): the PR-lane invocation lives in `ci.yml`'s `test-command:`
 *      VALUE (executed by `node-ci.yml`'s `run: ${{ inputs.test-command }}`) and
 *      the post-merge ones live INSIDE `run: |` bodies, so
 *      `scripts/check-skill-lint.test.mjs` — the harness on the job a PR actually
 *      sees — was never in the corpus while this pin reported `78 passed, 0
 *      failed`.
 *      ⚠️ THE ONE SHAPE IT DOES NOT READ, declared so that "every way" is true:
 *      `ci-main.yml` runs a `for` loop over the glob `extensions/<ext>/test*.mjs`, a
 *      shape no token scan expands — `extensions/main-worktree-guard/test.mjs`
 *      is outside the corpus for exactly that reason. No PR is left blind by it:
 *      that leg runs on the PUSH lane only (`ci-main.yml:17-24`) and carries the
 *      `mark` → `::error title=extension-tests::FAILED <label>` wrapper
 *      (`ci-main.yml:110-125`), which is attributable for every member.
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
import { dirname, join, posix, resolve } from "node:path";
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
  "check-skill-lint.test.mjs",
  "check-pi-pin-lockstep.mjs",
  "ci-ref-check",
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
  // BOTH shapes go through the REAL parser, because they reach `runner::<label>`
  // by different rules: the vacuous-skip shape is the one that used to vanish
  // (0 failed ⇒ the parser calls it a PASS line), and the ordinary failing shape
  // is the one every migrated harness prints. Round-tripping only the vacuous
  // shape left the ordinary one checked against nothing but the COPY of the
  // regex above — an assertion that can only agree with itself (#2723 review,
  // 2026-11-10: coverage, not a live defect, and one line to close).
  const SHAPES = [
    ["the vacuous-skip shape (0 counted failures, red)", LABELS.map((l) => verdictLine(l, 0, 0, { skip: 1, red: true }))],
    ["the ordinary failing shape (12 passed, 6 failed)", LABELS.map((l) => verdictLine(l, 12, 6))],
  ];
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
    for (const [shape, lines] of SHAPES) {
      writeFileSync(log, lines.join("\n") + "\n");
      const r = spawnSync(pythons[0], [PARSER, "ids", "--log", log], { encoding: "utf8" });
      const out = `${r.stdout ?? ""}${r.stderr ?? ""}`;
      eq(`#2 the parser exits 0 over ${LABELS.length} attributable lines (${shape})`, r.status, 0);
      const missing = LABELS.filter((l) => !out.includes(`runner::${l}`));
      eq(`#2 the parser extracts every runner::<label> (${shape})`, missing, []);
      contains(`#2 the parser drops nothing as unattributable (${shape})`, out, "unattributable=0");
    }
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
  ["scripts/check-skill-lint.mjs",
    "a CHECKER, not a harness (`ci-main.yml`'s skill-lint step): it lints SKILL.md frontmatter and " +
    "prints `N issue(s)` / `Clean.`, so it has no pass/fail aggregate to attribute. Its own " +
    "reference suite, scripts/check-skill-lint.test.mjs, IS migrated and carries the `ci / unit-test` " +
    "identity for that surface"],
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

/** A YAML mapping key, at any depth, with or without a `- ` sequence marker. */
const KEY_LINE = /^(\s*)(?:-\s*)?([A-Za-z0-9_.-]+):\s*(.*)$/;
const BLOCK_SCALAR = /^[|>][+-]?\d*$/;
/** The keys whose BLOCK-SCALAR body is a command. A one-line value still counts
 *  under any key (a `<key>: … node <x>.mjs` value IS the invocation, and the
 *  review asked for it), but a block BODY has no such anchor: a `description: |`
 *  paragraph that happens to name a harness would be pulled into the corpus and
 *  the pin would then demand a migration for a file nothing runs — a false RED,
 *  which is its own kind of damage. So a block body is read only where the key
 *  says "this is a command". */
const COMMAND_KEY = /^(?:run|[A-Za-z0-9_.-]*(?:command|script))$/;

/** Every COMMAND string a workflow file carries, in the three shapes this repo
 *  actually uses. (§3's corpus bug, #2723 review 2026-11-10: the old scan matched
 *  only `^\s*(?:-\s*)?run:` WITH `node` on the SAME line, so two live call sites
 *  were invisible — `ci.yml:52`'s `test-command:` value, run by `node-ci.yml:230`,
 *  and the `run: |` bodies in `ci-main.yml`.)
 *
 *    1. `run: <command>`                     — one line, carries `node`
 *    2. `run: |` / `run: >`                   — a BLOCK SCALAR: the commands are
 *       the following lines indented deeper than the key
 *    3. `<key>: … node <x>.mjs`               — a reusable workflow's input,
 *       e.g. `test-command:` and `test-glob:`
 *
 *  A line only counts when it names `node`, so a shell comment or a stray
 *  `.mjs` in prose cannot pull a harness into the corpus that nothing runs — the
 *  pin would then demand a migration for a file with no call site.
 *  YAML comments can never match at all: `KEY_LINE` requires the line to start
 *  with whitespace (optionally `- `) before the key, and `#` does not.
 */
function commandTokens(body) {
  const lines = body.split("\n");
  const out = [];
  for (let i = 0; i < lines.length; i++) {
    const m = KEY_LINE.exec(lines[i]);
    if (!m) continue;
    const keyCol = lines[i].indexOf(m[2]);
    const value = (m[3] ?? "").trim();
    if (BLOCK_SCALAR.test(value.replace(/\s+#.*$/, ""))) {
      if (!COMMAND_KEY.test(m[2])) continue;
      for (let j = i + 1; j < lines.length; j++) {
        const line = lines[j];
        if (line.trim() === "") continue;
        if (line.length - line.trimStart().length <= keyCol) break; // dedent ends the block
        // A shell COMMENT is not an invocation. Without this, a commented-out
        // `# node scripts/x.mjs` inside a `run: |` body enters the corpus and the
        // pin demands a migration for a file nothing runs — the false RED that
        // COMMAND_KEY already guards against for prose, in the other direction.
        if (/^\s*#/.test(line)) continue;
        if (!/\bnode\b/.test(line)) continue;
        out.push(line);
      }
      continue;
    }
    if (!/\bnode\b/.test(value)) continue;
    out.push(value);
  }
  return out;
}

function workflowNodeHarnesses() {
  const found = new Map(); // repo-relative path -> {wf, token}
  const files = readdirSync(WORKFLOWS).filter((f) => f.endsWith(".yml") || f.endsWith(".yaml"));
  for (const wf of files) {
    const body = readFileSync(join(WORKFLOWS, wf), "utf8");
    for (const command of commandTokens(body)) {
      for (const token of command.match(/[A-Za-z0-9_./-]+\.mjs/g) ?? []) {
        const resolved = resolveHarness(token);
        if (resolved) found.set(resolved, { wf, token });
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

// ⛔ THE SCANNER IS THE HALF THAT GENERALISES, SO THE SCANNER IS ASSERTED HERE.
// In-file because `commandTokens()` is not exported and this suite is its only
// consumer; on SYNTHETIC YAML because three file names cannot pin a grammar.
//
// WHY THIS EXISTS (#2723 review, 2026-11-10 — measured): the corpus floor above
// cannot protect the widening. Reverted to the pre-fix single-line `run:` scan,
// the corpus goes 25 → 21, eleven rows simply VANISH, and the pin still reported
// `83 passed, 0 failed` (rc 0) — the floor is 10, so it never fires. A pin whose
// own header promises it "pins nothing about tomorrow's seventeenth" has to go
// RED when the grammar it reads shrinks, or a future harness wired into a block
// body or a `test-command:` value is invisible again and the #2723 blind refusal
// is back with a green pin.
const TOKEN_SHAPES = [
  {
    label: "a one-line `run:` value",
    yaml: [
      "jobs:",
      "  a:",
      "    steps:",
      "      - run: node scripts/one.test.mjs",
    ].join("\n"),
    want: ["node scripts/one.test.mjs"],
  },
  {
    label: "a `run: |` block body (its key line carries no `node`)",
    yaml: [
      "jobs:",
      "  a:",
      "    steps:",
      "      - name: block",
      "        run: |",
      '          mark "scripts/two.test.mjs"',
      "          node scripts/two.test.mjs || failures=$((failures+1))",
      "        continue-on-error: false",
    ].join("\n"),
    want: ["node scripts/two.test.mjs || failures=$((failures+1))"],
  },
  {
    label: "a `<key>: … node <x>.mjs` VALUE (a reusable workflow's input)",
    yaml: [
      "jobs:",
      "  a:",
      "    with:",
      "      test-command: a=0; node scripts/three.test.mjs || a=$?; [ $a -eq 0 ]",
    ].join("\n"),
    want: ["a=0; node scripts/three.test.mjs || a=$?; [ $a -eq 0 ]"],
  },
  {
    label: "a shell comment in a block body (names `node`, runs nothing)",
    yaml: [
      "jobs:",
      "  a:",
      "    steps:",
      "      - run: |",
      "          # node scripts/commented-out.test.mjs",
      "          node scripts/four.test.mjs",
    ].join("\n"),
    want: ["node scripts/four.test.mjs"],
  },
  {
    label: "a `description: |` paragraph (PROSE must not enter the corpus)",
    yaml: [
      "jobs:",
      "  a:",
      "    steps:",
      "      - name: prose",
      "        description: |",
      "          node scripts/not-a-harness.test.mjs is documented here, not run",
    ].join("\n"),
    want: [],
  },
];
for (const shape of TOKEN_SHAPES) {
  eq(`#3 commandTokens() reads ${shape.label}`,
    commandTokens(shape.yaml).map((t) => t.trim()), shape.want);
}

// CORPUS MEMBERSHIP — BY NAME, for the call sites that motivated the widening.
// The floor above cannot see 25 → 21 either, so the three names the widening was
// FOR are asserted individually: losing one is the regression, and it must be a
// RED with the call site named, not a smaller pass count.
for (const [required, why] of [
  ["scripts/check-skill-lint.test.mjs",
    "`ci.yml`'s `test-command:` VALUE — the harness on the job a PR actually sees (`node-ci.yml:230`)"],
  ["scripts/check-pi-pin-lockstep.mjs",
    "the same `test-command:` value, and `ci-main.yml`'s `run: |` body"],
  ["scripts/ci-ref-check.test.mjs",
    "`ci-main.yml`'s `run: |` body"],
]) {
  if (harnesses.has(required)) ok(`#3 the corpus holds ${required} — ${why}`);
  else
    bad(`#3 the corpus holds ${required}`,
      "it is missing, so a call site the scan was widened for is invisible again and a failing " +
      `run of it yields NO identity (#2723) — ${why}`);
}

const EMITTER_IMPORT = String.raw`(?:^|\n)\s*import\s+\{[^}]*\breportVerdict\b[^}]*\}\s+from\s+["'][./][^"']*verdict\.mjs["']`;

/** A `reportVerdict(` CALL SITE — not the import, and not a mention in a comment.
 *  ⛔ THE IMPORT ALONE EMITS NOTHING (#2723 review 2026-11-10, measured): the row
 *  below used to be labelled "emits through reportVerdict" while its test was a
 *  regex over the IMPORT line, so keeping the import and deleting the call
 *  (`reportVerdict("x", p, f);` → `void reportVerdict;`) left the pin green while
 *  the harness emitted nothing and `ci_exemption.py ids` returned `ids=0 …
 *  runner=0` — the blind refusal, reintroduced by the one mutation that restores
 *  the defect. Comment lines are skipped so a docblock that names the emitter
 *  cannot stand in for a call.
 *  DECLARED RESIDUAL: this is syntactic, so a call that can never be REACHED
 *  (inside `if (false)`) still satisfies it. Proving reachability needs the
 *  harness's own runtime per file; the alternative accepted here is the
 *  per-file run, rejected as the pin's cost on the PR lane (the heavy members of
 *  the corpus are `discard-gate` and `gui-device-guard`). */
function callsEmitter(body) {
  return body.split("\n").some((line) => {
    const t = line.trim();
    if (t.startsWith("//") || t.startsWith("*") || t.startsWith("/*")) return false;
    return /\breportVerdict\s*\(/.test(line);
  });
}

const sorted = [...harnesses.keys()].sort();
for (const path of sorted) {
  const wf = harnesses.get(path).wf;
  if (EXEMPT.has(path)) { ok(`#3 ${path} (${wf}) is exempt — ${EXEMPT.get(path)}`); continue; }
  const body = readFileSync(join(REPO, path), "utf8");
  // Two rows, because the two halves fail differently: an absent import means the
  // harness never had the emitter; an import with no call means it HAD it and lost
  // the emission, which is the shape a "tidy-up" produces.
  if (new RegExp(EMITTER_IMPORT).test(body)) ok(`#3 ${path} (${wf}) imports the shared emitter`);
  else
    bad(`#3 ${path} (${wf}) imports the shared emitter`,
      "it carries no measured exemption, so a failing run of it yields NO identity and the merge " +
      "rail refuses the PR blind (#2723)");
  if (callsEmitter(body)) ok(`#3 ${path} (${wf}) calls reportVerdict — the import alone emits nothing`);
  else
    bad(`#3 ${path} (${wf}) calls reportVerdict — the import alone emits nothing`,
      "it imports the emitter but never CALLS it, so its aggregate is whatever the harness prints " +
      "by hand and `ci_exemption.py ids` finds no `runner::` identity (#2723)");
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

// ── 4. a MATERIALISED harness must ship the imports it makes outside its dir ─
console.log("\n#4 a `$RUNNER_TEMP`-copied harness ships every escaping relative import");

// WHY THIS ARM EXISTS (measured, PR #3896 run 42838546373). `http-pool-hygiene`
// copies only `extensions/http-pool-hygiene/.` into `$RUNNER_TEMP`, so the
// harness's `import … from "../shared/verdict.mjs"` resolved to
// `$RUNNER_TEMP/shared/verdict.mjs` — a path nothing had created. The job died at
// LOAD with `ERR_MODULE_NOT_FOUND` before a single assertion ran, and it reported
// RED for a reason that named no defect in the code under test. ESM resolves a
// relative specifier against the importing module's own URL, so a copy RELOCATES
// the base of every escaping import; the copy step therefore has to be the module
// graph, not the directory. §3 could not see this: it reads the repo file and
// proves the import EXISTS, which it always did — the file was just never copied.

const VAR_ASSIGN = /^\s*([A-Za-z_][A-Za-z0-9_]*)=(?:"([^"]*)"|'([^']*)'|(\S+))\s*$/;

/** Expand the step's own `VAR=…` assignments; leave GitHub-supplied vars literal. */
function expandVars(text, vars) {
  let out = text;
  for (let i = 0; i < 8; i++) {
    const next = out.replace(/\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?/g, (m, name) =>
      vars.has(name) ? vars.get(name) : m);
    if (next === out) break;
    out = next;
  }
  return out;
}

/** Every `cp` in a workflow, as {source, dest, dirMode}. */
function copyMappings(wfBody) {
  const vars = new Map();
  const out = [];
  for (const raw of wfBody.split("\n")) {
    const line = raw.trim();
    const assign = VAR_ASSIGN.exec(line);
    if (assign) {
      vars.set(assign[1], assign[2] ?? assign[3] ?? assign[4] ?? "");
      continue;
    }
    if (!/^cp\s/.test(line)) continue;
    const words = [...line.matchAll(/"([^"]*)"|'([^']*)'|(\S+)/g)].map((m) => m[1] ?? m[2] ?? m[3]);
    const args = words.slice(1).filter((w) => !w.startsWith("-"));
    if (args.length < 2) continue;
    const destRaw = expandVars(args[args.length - 1], vars);
    const destIsDir = /\/$/.test(destRaw) || args.length > 2;
    const dest = destRaw.replace(/\/+$/, "");
    for (const srcRaw of args.slice(0, -1)) {
      const src = expandVars(srcRaw, vars);
      // `cp -R dir/. dst` and `cp -R dir/* dst` both materialise dir's CONTENTS.
      const dirMode = /\/\.[/]?$/.test(src) || /\/\*$/.test(src);
      out.push({
        source: dirMode ? src.replace(/\/(?:\.|\*)\/?$/, "") : src,
        dest,
        destIsDir,
        dirMode,
      });
    }
  }
  return out;
}

/** Relative specifiers in a file that escape the file's OWN directory. */
function escapingImports(body) {
  const specs = new Set();
  const re = /(?:^|\n)\s*(?:import|export)\b[^"'`]*?from\s*["'](\.{1,2}\/[^"']+)["']/g;
  for (const m of body.matchAll(re)) if (m[1].startsWith("../")) specs.add(m[1]);
  return [...specs];
}

const materialised = sorted.filter((p) => !existsSync(join(REPO, harnesses.get(p).token)));
if (materialised.length >= 1)
  ok(`#4 the corpus holds ${materialised.length} workflow-materialised harness(es)`);
else
  bad("#4 the corpus holds a materialised harness",
    "none found — copy-source resolution found only in-place runs, so this arm is INERT");

for (const path of materialised) {
  const { wf, token } = harnesses.get(path);
  const body = readFileSync(join(WORKFLOWS, wf), "utf8");
  const maps = copyMappings(body);
  const ownDir = path.split("/").slice(0, -1).join("/");
  // The mapping that materialises the harness's OWN directory fixes the base the
  // runtime will resolve its relative specifiers against.
  // ⛔ SCOPE, stated: `own` is resolved from the WHOLE workflow file, not from the
  // job/step that runs this harness, so it does not prove the copy happens in the
  // same step that needs it. Only one mapping exists today (`http-pool-hygiene`),
  // so there is no live false PASS; this becomes one the moment a second job
  // copies that directory (#2723 review, 2026-11-10 — recorded, not fixed).
  const own = maps.find((m) => m.dirMode && m.source === ownDir);
  if (!own) {
    bad(`#4 ${path} (${wf}) is copied by a mapping this pin can read`,
      `no \`cp -R ${ownDir}/. <dest>\` found, so the materialised base is unknown`);
    continue;
  }
  ok(`#4 ${path} (${wf}) materialises its own dir at ${own.dest}`);
  for (const spec of escapingImports(readFileSync(join(REPO, path), "utf8"))) {
    const expected = posix.normalize(posix.join(own.dest, spec));
    const provided = maps.some((m) => {
      if (m.dirMode) return posix.normalize(m.dest) === posix.dirname(expected);
      if (!m.destIsDir) return posix.normalize(m.dest) === expected;
      return posix.normalize(posix.join(m.dest, m.source.split("/").pop())) === expected;
    });
    if (provided) ok(`#4 ${path} (${wf}) ships ${spec} at ${expected}`);
    else
      bad(`#4 ${path} (${wf}) ships ${spec} at ${expected}`,
        "the copy step materialises no such file, so the harness dies at LOAD with " +
        "ERR_MODULE_NOT_FOUND and the job reports RED for a reason naming no defect in " +
        "the code under test (#2723 / PR #3896 run 42838546373)");
  }
}

// ── aggregate ───────────────────────────────────────────────────────────────
reportVerdict("test-verdict", pass, fail, { skip });
process.exit(fail === 0 ? 0 : 1);
