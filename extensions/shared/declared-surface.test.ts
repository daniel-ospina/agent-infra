/**
 * declared-surface.test.ts — unit tests for the declared-surface instrument (#1068)
 *
 * Run: npx tsx extensions/shared/declared-surface.test.ts
 *
 * WHY THIS SUITE EXISTS SEPARATELY
 * --------------------------------
 * `heartbeat-progress-edges.test.ts` uses the instrument against the REAL repo.
 * This suite proves the instrument itself is not a no-op gate: every
 * fails-if-removed direction is driven through synthetic fixtures, including the
 * two that are hardest to see in a green run — a silently-empty corpus
 * (`vacuityFindings`) and an exemption with no rationale.
 *
 * ZERO-DEPENDENCY: `node:*` + `./declared-surface.js` only. The per-PR
 * `ci.yml` `verify` job runs this with NO `npm ci`.
 *
 * WIRING HONESTY: per-PR this suite is VISIBLE but NOT merge-blocking (the
 * repo's only required check is `pipeline-compliance`); the blocking backstop is
 * the post-merge `ci-main.yml` `extensions/shared/*.test.ts` glob.
 */

import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { fileURLToPath } from "node:url";
import { ok, equal } from "node:assert/strict";
import {
  collectFiles,
  declarationLines,
  driverViolations,
  forwardViolations,
  isSubstantive,
  inFamily,
  langOf,
  reverseViolations,
  scanDeclarations,
  declaresSymbol,
  stripComments,
  vacuityFindings,
  type ScanResult,
  type ScanSpec,
  type StallTerm,
} from "./declared-surface.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, "../..");

let passed = 0;
let failed = 0;

function test(name: string, fn: () => void) {
  try {
    fn();
    passed++;
    console.log(`  ✅ ${name}`);
  } catch (err: any) {
    failed++;
    console.log(`  ❌ ${name}: ${err.message}\n${err.stack?.split("\n").slice(0, 4).join("\n")}`);
  }
}

function section(name: string) {
  console.log(`\n${name}:`);
}

const FAMILIES = ["STALL", "REAP", "IDLE", "HEARTBEAT"];
const BOUNDS = ["_MS", "_HOURS"];
const AGES = ["_AGE", "_AGE_DAYS"];

const SPEC: ScanSpec = { files: [], families: FAMILIES, boundSuffixes: BOUNDS, ageSuffixes: AGES };

section("comment handling is language-aware");

test("shell sources are NOT block-comment stripped (glob delimiters must not eat the file)", () => {
  // A `case` pattern matching absolute paths opens a `/*`; a later glob closes
  // it with `*/`. A naive block-comment pass therefore deletes everything in
  // between — including the declaration below.
  const sh = [
    'case "$p" in',
    '  /*) echo abs ;;',
    "esac",
    'REAP_IDLE_HOURS="${REAP_IDLE_HOURS:-24}"',
    "echo */bin",
  ].join("\n");
  ok(
    stripComments(sh, "sh").includes("REAP_IDLE_HOURS"),
    "a shell file containing /* and */ must keep its later declarations",
  );
  // …while the naive TS pass would have lost it — pin the divergence so a future
  // "simplification" to one code path fails here.
  ok(
    !stripComments(sh, "ts").includes("REAP_IDLE_HOURS"),
    "the ts pass (block comments) IS expected to lose that shell text — that is why langOf exists",
  );
  equal(langOf("scripts/pi-reap-idle.sh"), "sh");
  equal(langOf("extensions/task-heartbeat.ts"), "ts");
});

test("comments are stripped so prose cannot fabricate a declaration", () => {
  const ts = ['// const FAKE_STALL_MS = 1;', "/* HEARTBEAT_HOURS = 2; */", "const REAL_STALL_MS = 3;"].join("\n");
  const scan = scanDeclarations({ ...SPEC, files: ["x.ts"] }, () => ts);
  equal(scan.declarations.length, 1, "only the real declaration survives");
  equal(scan.declarations[0].symbol, "REAL_STALL_MS");
});

test("a `/*` inside a `//` comment does NOT open a block comment (the repo-freshness shape)", () => {
  // The ordering of the two comment passes is a correctness property. Stripping
  // block comments first let a glob in a line comment (`"./shared/*"`) open a
  // block whose first closing `*/` was a doc comment far below — deleting every
  // real declaration in between. That silently hid two live bounds.
  const src = [
    '// consumers: "./shared/*" and friends',
    "// more prose",
    "export const DEFAULT_FRESHNESS_INTERVAL_MS = 1_200_000;",
    "/** documentation for the floor */",
    "export const MIN_FRESHNESS_INTERVAL_MS = 300_000;",
  ].join("\n");
  const stripped = stripComments(src, "ts");
  ok(stripped.includes("DEFAULT_FRESHNESS_INTERVAL_MS"), "a /* inside a // comment must not open a block");
  ok(stripped.includes("MIN_FRESHNESS_INTERVAL_MS"), "declarations after the comment survive");
  const scan = scanDeclarations(
    { ...SPEC, families: [...FAMILIES, "FRESH"], files: ["extensions/repo-freshness.ts"] },
    () => src,
  );
  equal(
    scan.declarations.map((d) => d.symbol).sort().join(","),
    "DEFAULT_FRESHNESS_INTERVAL_MS,MIN_FRESHNESS_INTERVAL_MS",
    "both FRESH bounds must be visible to the scan",
  );
});

test("a removed block comment keeps its newlines, so a following declaration stays line-anchored", () => {
  const src = ["const A_STALL_MS = 1;", "/*", " span", "*/ const B_STALL_MS = 2;"].join("\n");
  const scan = scanDeclarations({ ...SPEC, files: ["x.ts"] }, () => src);
  equal(
    scan.declarations.map((d) => d.symbol).sort().join(","),
    "A_STALL_MS,B_STALL_MS",
    "removing a multi-line comment must not merge two lines into one",
  );
});

test("REGEX literals do not desynchronize the scan (both failure directions)", () => {
  // A scanner that tracks only quotes desyncs on an apostrophe inside a regex
  // literal and copies the rest of the file verbatim — so every later assertion
  // scans PROSE, and a comment can fabricate a declaration. This is not
  // hypothetical: extensions/builtin-tools/index.ts holds
  // /^Warning: No project session found with id '[^']*'/. The `/[/*]/` case is
  // the opposite direction: a `/` inside a regex character class read as a
  // block-comment opener DELETES the real declarations after it.
  const cases: [string, string, string[]][] = [
    ["apostrophe inside a regex", "const re = /id '([^']*)'/;\n", ["BOGUS_STALL_MS", "REAL_ONE_STALL_MS"]],
    ["`/*` inside a regex character class", "const re = /[/*]/;\n", ["REAL_TWO_STALL_MS"]],
    ["`//` inside a regex", "const re = /a\\/\\/b/;\n", ["REAL_THREE_STALL_MS"]],
  ];
  for (const [name, head, decls] of cases) {
    const body = decls.map((d, i) => (i === 0 && name.startsWith("apostrophe") ? `// ${d} = 0;` : `export const ${d} = ${i + 1};`)).join("\n");
    const stripped = stripComments(`${head}${body}\n`, "ts");
    for (const d of decls) {
      if (d.startsWith("BOGUS")) {
        ok(!stripped.includes(d), `${name}: a comment must not survive stripping (would fabricate ${d})`);
      } else {
        ok(stripped.includes(d), `${name}: the real declaration ${d} must survive stripping`);
      }
    }
  }
  // Division must NOT be mistaken for a regex start (it would swallow code).
  // The postfix/property cases are the ones a next-character-only heuristic gets
  // wrong: `a++`, `x!` (non-null) and `obj.of` all END a value.
  for (const expr of [
    "const r = a / b;",
    "const r = (x) / 2;",
    "const r = arr[0] / 3;",
    "const r = obj.k / 4;",
    "const r = a++ / 2;",
    "const r = a-- / 2;",
    "const r = x! / 2;",
    "const r = obj.of / 2;",
    "const r = obj.in / 2;",
    "const r = obj.delete / 2;",
    'const r = "s" / 2;',
  ]) {
    const s = stripComments(`${expr}\n// const FAKE_STALL_MS = 1;\nexport const OK_STALL_MS = 2;\n`, "ts");
    ok(
      s.includes("OK_STALL_MS") && !s.includes("FAKE_STALL_MS"),
      `a division must not open a regex literal: ${expr}`,
    );
  }
  // …and a keyword before the slash must still be read as a regex (`return /re/`
  // includes the backtick case that first exposed the whitespace bug).
  for (const expr of ["function f(){ return /[$`]/.test(s); }", "function f(){ return  /re/.test(s); }", "switch (x) { case /re/: break; }"]) {
    const s = stripComments(`${expr}\n// const FAKE2_STALL_MS = 1;\nexport const OK2_STALL_MS = 2;\n`, "ts");
    ok(s.includes("OK2_STALL_MS") && !s.includes("FAKE2_STALL_MS"), `a keyword must open a regex: ${expr}`);
  }
  // The escalation: a misread division on a line that also holds a
  // `/`-containing string desynchronizes the rest of the file, and a leaked
  // line-start comment then FABRICATES a declaration.
  const esc = 'const ratio = a++ / 2; const p = "a/b";\n// const BOGUS_STALL_MS = 0;\nexport const REAL_STALL_MS = 1;\n';
  const escScan = scanDeclarations({ ...SPEC, files: ["x.ts"] }, () => esc);
  equal(
    escScan.declarations.map((d) => d.symbol).join(","),
    "REAL_STALL_MS",
    "a leaked comment must not be able to fabricate a declaration",
  );
});

section("declaresSymbol — a mention is not a declaration");

test("a comment that merely names the term does not satisfy the presence check", () => {
  ok(!declaresSymbol("// REAP_STUCK_HOURS is derived at runtime\n", "REAP_STUCK_HOURS"), "a comment mention is not a declaration");
  ok(!declaresSymbol('const msg = "getSubagentBackstopFreshMs is documented elsewhere";\n', "getSubagentBackstopFreshMs"), "a string-literal mention is not a declaration");
  ok(declaresSymbol("export function getSubagentBackstopFreshMs(): number {}\n", "getSubagentBackstopFreshMs"));
  ok(declaresSymbol("export const STALL_THRESHOLD = 0.8;\n", "STALL_THRESHOLD"));
  ok(declaresSymbol('REAP_STUCK_HOURS="$(expr $REAP_IDLE_HOURS \\* 3)"\n', "REAP_STUCK_HOURS", "sh"), "a shell assignment counts");
  ok(!declaresSymbol("# REAP_STUCK_HOURS is derived\n", "REAP_STUCK_HOURS", "sh"), "a shell comment mention does not");
});

section("inFamily — the two-part rule");

test("a family token alone is not enough; a bound shape is required", () => {
  ok(inFamily("REAP_IDLE_HOURS", FAMILIES, AGES, BOUNDS), "token + bound shape");
  ok(!inFamily("REAP_WT_STATUS_TIMEOUT", FAMILIES, AGES, BOUNDS), "token without bound shape is out");
  ok(!inFamily("IDLE_TIMEOUT_ENV", FAMILIES, AGES, BOUNDS), "env-var NAME is out");
  ok(inFamily("MAX_AGE", FAMILIES, AGES, BOUNDS), "age-shaped bound, no family token");
  ok(inFamily("MAX_AGE_DAYS", FAMILIES, AGES, BOUNDS), "age+unit bound, no family token");
  ok(inFamily("STALL_MARGIN_MS", FAMILIES, AGES, BOUNDS), "bare STALL_*_MS is caught");
  ok(inFamily("IDLE_TIMEOUT_MS", FAMILIES, AGES, BOUNDS), "bare IDLE_*_MS is caught");
});

section("forward violations");

test("a value change in the owner file is a violation", () => {
  const term: StallTerm = {
    name: "DEFAULT_STREAM_STALL_MS",
    owners: ["a.ts"],
    value: "= 1_200_000;",
    axis: "kill",
    guardedBy: "test",
  };
  equal(forwardViolations([term], () => "export const DEFAULT_STREAM_STALL_MS = 1_200_000;").length, 0);
  const v = forwardViolations([term], () => "export const DEFAULT_STREAM_STALL_MS = 600_000;");
  equal(v.length, 1);
  ok(v[0].includes("does not carry the registered value"), v[0]);
});

test("a de-listed (renamed/removed) owner is a violation", () => {
  const term: StallTerm = { name: "GONE_MS", owners: ["a.ts"], value: null, axis: "kill", guardedBy: "test" };
  const v = forwardViolations([term], () => "export const SOMETHING_ELSE_MS = 1;");
  equal(v.length, 1);
  ok(v[0].includes("no longer declares it"), v[0]);
});

test("a missing owner file is a violation, and a value:null term may be function-shaped", () => {
  const missing: StallTerm = { name: "X_MS", owners: ["nope.ts"], value: null, axis: "kill", guardedBy: "test" };
  const v = forwardViolations([missing], () => {
    throw new Error("ENOENT");
  });
  equal(v.length, 1);
  ok(v[0].includes("does not exist"), v[0]);

  const fnTerm: StallTerm = {
    name: "getSubagentBackstopFreshMs",
    owners: ["a.ts"],
    value: null,
    axis: "kill",
    guardedBy: "test",
  };
  equal(forwardViolations([fnTerm], () => "export function getSubagentBackstopFreshMs(): number { return 1; }").length, 0);
});

test("every owner of a multi-owner term is checked", () => {
  const term: StallTerm = {
    name: "HEARTBEAT_MS",
    owners: ["a.ts", "b.ts"],
    value: "= 30_000;",
    axis: "kill",
    guardedBy: "test",
  };
  const files: Record<string, string> = { "a.ts": "const HEARTBEAT_MS = 30_000;", "b.ts": "const HEARTBEAT_MS = 99_000;" };
  const v = forwardViolations([term], (f) => files[f]);
  equal(v.length, 1, "the second owner's drift is caught");
  ok(v[0].startsWith("HEARTBEAT_MS: b.ts"), v[0]);
});

section("reverse violations");

test("an unregistered in-family declaration is a violation", () => {
  const scan = scanDeclarations({ ...SPEC, files: ["x.ts"] }, () => "const NEW_STALL_MS = 5;");
  const v = reverseViolations(scan, [], []);
  equal(v.length, 1);
  ok(v[0].includes("NEW_STALL_MS"), v[0]);
  ok(v[0].includes("not in the registry"), v[0]);
});

test("an exemption with no rationale is itself a violation", () => {
  const scan = scanDeclarations({ ...SPEC, files: ["x.ts"] }, () => "const NEW_STALL_MS = 5;");
  const withEmpty = reverseViolations(scan, [], [{ symbol: "NEW_STALL_MS", rationale: "   ", owner: "#1" }]);
  equal(withEmpty.length, 1);
  ok(withEmpty[0].includes("rationale"), withEmpty[0]);
  const withShort = reverseViolations(scan, [], [{ symbol: "NEW_STALL_MS", rationale: "not a bound", owner: "#1" }]);
  equal(withShort.length, 1);
  const withReason = reverseViolations(scan, [], [
    { symbol: "NEW_STALL_MS", rationale: "a socket-close delay in a test harness, not a liveness bound", owner: "#1" },
  ]);
  equal(withReason.length, 0, "a substantive rationale clears it");
  ok(isSubstantive("a socket-close delay in a test harness"));
  ok(!isSubstantive("short"));
});

test("a registered term declared in an unowned file is a violation", () => {
  const scan = scanDeclarations({ ...SPEC, files: ["elsewhere.ts"] }, () => "const HEARTBEAT_MS = 30_000;");
  const term: StallTerm = { name: "HEARTBEAT_MS", owners: ["owner.ts"], value: null, axis: "kill", guardedBy: "t" };
  const v = reverseViolations(scan, [term], []);
  equal(v.length, 1, "a second copy of a registered bound must be caught");
  ok(v[0].includes("does not list as an owner"), v[0]);
  // …and the same declaration in a LISTED owner is fine.
  const okScan = scanDeclarations({ ...SPEC, files: ["owner.ts"] }, () => "const HEARTBEAT_MS = 30_000;");
  equal(reverseViolations(okScan, [term], []).length, 0);
});

test("an unreadable corpus file is a violation, never a silent skip", () => {
  const scan = scanDeclarations({ ...SPEC, files: ["gone.ts"] }, () => {
    throw new Error("ENOENT");
  });
  equal(scan.filesScanned, 0);
  const v = reverseViolations(scan, [], []);
  equal(v.length, 1);
  ok(v[0].includes("UNREADABLE CORPUS FILE"), v[0]);
});

test("a failed directory walk is reported, surfaced, and never counted toward the floor", () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "declared-surface-walk-"));
  const locked = path.join(tmp, "locked");
  let errors: string[] = [];
  try {
    fs.mkdirSync(locked, { recursive: true });
    fs.writeFileSync(path.join(locked, "hidden.ts"), "const X_STALL_MS = 1;\n");
    fs.writeFileSync(path.join(tmp, "readable.ts"), "// nothing in-family\n");
    fs.chmodSync(locked, 0o000);
    errors = [];
    collectFiles(tmp, ".", (n) => n.endsWith(".ts"), 6, errors);
  } finally {
    fs.chmodSync(locked, 0o700);
    fs.rmSync(tmp, { recursive: true, force: true });
  }
  equal(errors.length, 1, `an unreadable directory must be reported, got ${JSON.stringify(errors)}`);
  const scan = scanDeclarations({ ...SPEC, files: [], walkErrors: errors }, () => "");
  ok(reverseViolations(scan, [], []).length === 1, "the walk failure is surfaced through the violation channel");
  const v = vacuityFindings(scan, { minFiles: 1, minDeclarations: 1 });
  ok(v.length > 0, "a walk failure must not be able to satisfy the vacuity floor");
});

section("vacuity — a green run over nothing is a failure");

test("an empty or truncated scan fails the floors", () => {
  const empty: ScanResult = { files: [], filesScanned: 0, declarations: [] };
  equal(vacuityFindings(empty, { minFiles: 4, minDeclarations: 10 }).length, 2, "both floors fire");

  const truncated: ScanResult = {
    files: ["a", "b", "c", "d"],
    filesScanned: 4,
    declarations: [{ file: "a", symbol: "X_MS", raw: "X_MS=1" }],
  };
  const v = vacuityFindings(truncated, { minFiles: 4, minDeclarations: 10 });
  equal(v.length, 1);
  ok(v[0].includes("in-family declarations found"), v[0]);
  ok(v[0].includes("proves nothing"), v[0]);

  // Sentinels for unreadable files/walk failures must NOT inflate the floor.
  const sentinels: ScanResult = {
    files: ["a", "b", "c", "d"],
    filesScanned: 4,
    declarations: Array.from({ length: 10 }, () => ({ file: "a", symbol: "", raw: "UNREADABLE CORPUS FILE: a" })),
  };
  ok(
    vacuityFindings(sentinels, { minFiles: 4, minDeclarations: 10 }).length > 0,
    "error sentinels must not satisfy the declaration floor",
  );

  const healthy: ScanResult = {
    files: ["a", "b", "c", "d"],
    filesScanned: 4,
    declarations: Array.from({ length: 10 }, (_, i) => ({ file: "a", symbol: `X_${i}_MS`, raw: "x" })),
  };
  equal(vacuityFindings(healthy, { minFiles: 4, minDeclarations: 10 }).length, 0);
});

section("drivers — a non-sharing driver must say why");

test("a driver that does not share the declaration needs a substantive reason", () => {
  const files: Record<string, string> = { "a.ts": "// driver" };
  const v = driverViolations(
    [{ id: "d1", owner: "a.ts", mechanism: "m", sharesDeclaration: false, reason: "because" }],
    (f) => files[f],
  );
  equal(v.length, 1);
  ok(v[0].includes("requires a substantive reason"), v[0]);

  equal(
    driverViolations(
      [
        {
          id: "d1",
          owner: "a.ts",
          mechanism: "m",
          sharesDeclaration: false,
          reason: "measurement lane: a different input shape from the in-process edge stream",
        },
      ],
      (f) => files[f],
    ).length,
    0,
  );

  const stale = driverViolations([{ id: "d2", owner: "gone.ts", mechanism: "m", sharesDeclaration: true }], (f) => {
    throw new Error("ENOENT");
  });
  equal(stale.length, 1);
  ok(stale[0].includes("does not exist"), stale[0]);
});

section("declarationLines — order and multiplicity");

test("all declarations of a symbol are returned, not just the first", () => {
  const sh = ['X_STALL_HOURS="${X_STALL_HOURS:-1}"', "wrap() {", '  X_STALL_HOURS="$2"', "}"].join("\n");
  const lines = declarationLines(sh, "X_STALL_HOURS", "sh");
  equal(lines.length, 2);
  ok(lines[0].includes(":-1}"), lines[0]);
  ok(lines[1].includes('"$2"'), lines[1]);
});

section("collectFiles — bounded, explicit corpus");

test("excludes node_modules/_deprecated/hidden and honours the keep predicate", () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "declared-surface-"));
  try {
    fs.mkdirSync(path.join(tmp, "node_modules"), { recursive: true });
    fs.writeFileSync(path.join(tmp, "node_modules", "skip.ts"), "");
    fs.mkdirSync(path.join(tmp, "_deprecated"), { recursive: true });
    fs.writeFileSync(path.join(tmp, "_deprecated", "skip.ts"), "");
    fs.mkdirSync(path.join(tmp, ".hidden"), { recursive: true });
    fs.writeFileSync(path.join(tmp, ".hidden", "skip.ts"), "");
    fs.mkdirSync(path.join(tmp, "sub"), { recursive: true });
    fs.writeFileSync(path.join(tmp, "sub", "keep.ts"), "");
    fs.writeFileSync(path.join(tmp, "skip.test.ts"), "");
    const errors: string[] = [];
    const got = collectFiles(tmp, ".", (n) => n.endsWith(".ts") && !n.includes(".test."), 6, errors);
    equal(got.length, 1, `expected only sub/keep.ts, got ${JSON.stringify(got)}`);
    ok(got[0].endsWith("sub/keep.ts"), got[0]);
    equal(errors.length, 0, `a readable tree must report no walk errors, got ${JSON.stringify(errors)}`);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

test("a symlinked entry and a depth-truncated subtree are reported, never silently dropped", () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "declared-surface-link-"));
  const errors: string[] = [];
  try {
    fs.mkdirSync(path.join(tmp, "real"), { recursive: true });
    fs.writeFileSync(path.join(tmp, "real", "keep.ts"), "");
    try {
      fs.symlinkSync(path.join(tmp, "real", "keep.ts"), path.join(tmp, "linked.ts"));
    } catch {
      return; // a platform without symlink permission — skip, the depth case still runs below
    }
    collectFiles(tmp, ".", (n) => n.endsWith(".ts"), 6, errors);
    ok(errors.some((e) => e.includes("symlinked entry")), `a symlink must be reported, got ${JSON.stringify(errors)}`);
    // A depth bound that truncates must report too.
    const deep: string[] = [];
    collectFiles(tmp, ".", (n) => n.endsWith(".ts"), 0, deep);
    ok(deep.some((e) => e.includes("depth bound")), `a truncated subtree must be reported, got ${JSON.stringify(deep)}`);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

section("Results");

console.log(`\n=== Results: ${passed} passed, ${failed} failed ===`);
if (failed > 0) {
  console.log("❌ SOME TESTS FAILED");
  process.exit(1);
}
console.log("✅ ALL TESTS PASSED");
