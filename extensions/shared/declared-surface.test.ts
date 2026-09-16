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
  isCommentLine,
  isSubstantive,
  inFamily,
  langOf,
  reverseViolations,
  scanDeclarations,
  declaresSymbol,
  vacuityFindings,
  yieldCommentLines,
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

section("comment handling is line-local and stateless");

test("shell comment lines are blanked and shell glob delimiters are inert", () => {
  // A shell file legitimately contains `/*` and `*/` as GLOB/case-pattern
  // characters. Because the transform only blanks `#` comment LINES and carries
  // no state, those characters cannot open anything.
  const sh = [
    'case "$p" in',
    '  /*) echo abs ;;',
    "esac",
    'REAP_IDLE_HOURS="${REAP_IDLE_HOURS:-24}"',
    "echo */bin",
  ].join("\n");
  ok(
    yieldCommentLines(sh, "sh").includes("REAP_IDLE_HOURS"),
    "a shell file containing /* and */ must keep its declarations",
  );
  equal(
    yieldCommentLines("# REAP_IDLE_HOURS is derived\nREAP_IDLE_HOURS=1\n", "sh").split("\n")[0],
    "",
    "a shell comment line is blanked so its prose cannot satisfy a needle",
  );
  equal(langOf("scripts/pi-reap-idle.sh"), "sh");
  equal(langOf("extensions/task-heartbeat.ts"), "ts");
});

test("a comment prefix is stripped repeatedly, so `/* a */ /* b */ code` keeps its code", () => {
  // A single pass left `/* b */ const X = 1;`, whose line-anchored declaration
  // regex no longer matched — an exotic but real miss. The strip now repeats.
  const src = "/* a */ /* b */ const A_STALL_MS = 1;\n*/ */ const B_STALL_MS = 2;\n";
  const scan = scanDeclarations({ ...SPEC, files: ["x.ts"] }, () => src);
  equal(scan.declarations.map((d) => d.symbol).sort().join(","), "A_STALL_MS,B_STALL_MS");
});

test("prose cannot fabricate a declaration (line comments and block-comment body lines)", () => {
  const ts = [
    "// const FAKE_STALL_MS = 1;",
    "/*  HEARTBEAT_HOURS = 2; */",
    " * const FAKE2_STALL_MS = 3;",
    "const REAL_STALL_MS = 3;",
  ].join("\n");
  const scan = scanDeclarations({ ...SPEC, files: ["x.ts"] }, () => ts);
  equal(
    scan.declarations.map((d) => d.symbol).join(","),
    "REAL_STALL_MS",
    "only the real declaration survives — a `//`, a one-line block comment and a `*`-body prose line are all blanked",
  );
});

test("isCommentLine does not mistake a generator method for a block-comment body line", () => {
  ok(!isCommentLine("  *gen() { yield 1; }", "ts"), "`*` followed by an identifier is code");
  ok(isCommentLine(" * prose in a jsdoc block", "ts"), "`* ` is a block-comment body line");
  ok(isCommentLine("  */", "ts"));
  ok(isCommentLine("  //x", "ts"));
  ok(!isCommentLine("  const x = 1;", "ts"));
  ok(!isCommentLine("# not a ts comment", "ts"), "`#` is not a TS comment marker");
  ok(isCommentLine("  # a shell comment", "sh"));
});

test("a `/*` inside a `//` comment is inert (the repo-freshness shape)", () => {
  // The lexer era had to get two comment passes in the right ORDER: stripping
  // block comments first let the glob in a line comment (`"./shared/*"`) open a
  // block whose first closing `*/` was a doc comment far below — deleting every
  // real declaration in between and silently hiding two live bounds. Line-local
  // blanking makes that structurally impossible, and this fixture pins it.
  const src = [
    '// consumers: "./shared/*" and friends',
    "// more prose",
    "export const DEFAULT_FRESHNESS_INTERVAL_MS = 1_200_000;",
    "/** documentation for the floor */",
    "export const MIN_FRESHNESS_INTERVAL_MS = 300_000;",
  ].join("\n");
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

test("a comment that PREFIXES a code line keeps the code", () => {
  // Blanking is per LINE, and only the comment span of a prefixed line goes —
  // otherwise a declaration sharing a line with a comment would be lost.
  const src = [
    "/* leading note */ const A_STALL_MS = 1;",
    "*/",
    "*/ const B_STALL_MS = 2;",
    "/** only a comment */",
    "const C_STALL_MS = 3;",
  ].join("\n");
  const scan = scanDeclarations({ ...SPEC, files: ["x.ts"] }, () => src);
  equal(
    scan.declarations.map((d) => d.symbol).sort().join(","),
    "A_STALL_MS,B_STALL_MS,C_STALL_MS",
    "code sharing a line with a comment prefix must survive",
  );
});

test("regression: every cross-line desync trigger that broke the old lexer is now inert", () => {
  // Each of these made the previous hand-rolled scanner lose track of where it
  // was — after which it either DELETED real declarations or copied comments
  // through verbatim so prose was scanned as code. They are kept as fixtures
  // because they are the exact shapes a future "smarter" rewrite would break on.
  const bodies: [string, string][] = [
    // apostrophe inside a regex literal (`extensions/builtin-tools/index.ts`)
    ["apostrophe in a regex", "const re = /^Warning: No project id '([^']*)'/;"],
    // a `/*` inside a regex character class
    ["/* inside a regex class", "const re = /[/*]/;"],
    // `//` inside a regex
    ["// inside a regex", "const re = /a\\/\\/b/;"],
    // regex in statement position after `)` — the case that defeated the
    // previous-token heuristic
    ["regex after a statement-position )", "if (ready) /a/.test(s);"],
    ["regex after a block", "if (ready) {} /a/.test(s);"],
    // a NESTED template literal, whose inner backtick ended the outer one early
    ["nested template", "const s = `a${`b${`c`}`}d`;"],
    // a quote inside a template interpolation
    ["quote in an interpolation", "const s = `${x}: it's fine`;"],
    // division that a next-char heuristic reads as a regex start
    ["division after ++/--", "const r = a++ / 2;"],
    ["division after postfix !", "const r = x! / 2;"],
    ["division after a keyword-named property", "const r = obj.of / 2;"],
    ["division after a double !", "const r = a!! / 2;"],
  ];
  for (const [name, head] of bodies) {
    const src = `${head}\n// const FAKE_STALL_MS = 1;\nexport const REAL_1_STALL_MS = 2;\n`;
    const scan = scanDeclarations({ ...SPEC, files: ["x.ts"] }, () => src);
    equal(
      scan.declarations.map((d) => d.symbol).join(","),
      "REAL_1_STALL_MS",
      `${name}: the comment must stay blank and the real declaration must survive`,
    );
  }
  // …and the same for a multi-line block comment, whose body is prose: no
  // fragment of a code line is ever removed, so nothing can be merged or lost.
  const multi = ["const A_STALL_MS = 1;", "/*", " * prose", " */", "const B_STALL_MS = 2;"].join("\n");
  const scan = scanDeclarations({ ...SPEC, files: ["x.ts"] }, () => multi);
  equal(scan.declarations.map((d) => d.symbol).join(","), "A_STALL_MS,B_STALL_MS");
});

test("the DOCUMENTED residual: a flush-left block-comment body line IS read as code", () => {
  // Without cross-line state this shape is indistinguishable from code, so it is
  // DISCLOSED rather than covered: no test canary detects it (a flush-left body
  // line is not a comment line, so the transform leaves it alone and the
  // no-deletion invariant sees nothing to report). This test pins the residual's
  // existence so nobody believes the gate covers it, and the corpus is required
  // not to contain the shape.
  const src = ["/*", "const FAKE_STALL_MS = 1;", "*/", "const REAL_STALL_MS = 2;"].join("\n");
  const scan = scanDeclarations({ ...SPEC, files: ["x.ts"] }, () => src);
  ok(
    scan.declarations.some((d) => d.symbol === "FAKE_STALL_MS"),
    "the flush-left form is read as a declaration — this is the disclosed residual, not a covered case",
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

test("an extra declaration of a registered term is a violation, not a passing `some()` match", () => {
  // The value check used to be satisfied by ANY one declaration line, so a
  // second, shadowing declaration left the gate green. The count and the
  // per-override fragments are now both asserted.
  const term: StallTerm = {
    name: "X_IDLE_HOURS",
    owners: ["a.sh"],
    value: "${X_IDLE_HOURS:-24}",
    axis: "reap",
    guardedBy: "none (test)",
    overrides: ['X_IDLE_HOURS="$2"'],
  };
  const good = 'X_IDLE_HOURS="${X_IDLE_HOURS:-24}"\nX_IDLE_HOURS="$2"; shift 2 ;;\n';
  equal(forwardViolations([term], () => good).length, 0, "the modelled pair must pass");
  const extra = `${good}X_IDLE_HOURS=48\n`;
  const v1 = forwardViolations([term], () => extra);
  ok(v1.length > 0 && v1[0].includes("3 time(s)"), `an unrecorded third declaration must fail, got ${JSON.stringify(v1)}`);
  const drift = good.replace('X_IDLE_HOURS="$2"', 'X_IDLE_HOURS="$9"');
  const v2 = forwardViolations([term], () => drift);
  ok(v2.length > 0 && v2[0].includes("override fragment"), `a changed override must fail, got ${JSON.stringify(v2)}`);
  const defaultChange = good.replace("${X_IDLE_HOURS:-24}", "${X_IDLE_HOURS:-48}");
  const v3 = forwardViolations([term], () => defaultChange);
  ok(v3.length > 0 && v3[0].includes("registered value"), `a changed default must fail, got ${JSON.stringify(v3)}`);
  // A term with NO overrides still requires exactly one declaration.
  const bare: StallTerm = { ...term, name: "Y_IDLE_HOURS", value: "${Y_IDLE_HOURS:-3}", overrides: undefined };
  equal(forwardViolations([bare], () => 'Y_IDLE_HOURS="${Y_IDLE_HOURS:-3}"\n').length, 0);
  const v4 = forwardViolations([bare], () => 'Y_IDLE_HOURS="${Y_IDLE_HOURS:-3}"\nY_IDLE_HOURS=9\n');
  ok(v4.length > 0 && v4[0].includes("2 time(s)"), `a second declaration must fail for a 1-declaration term, got ${JSON.stringify(v4)}`);
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
    let linked = true;
    try {
      fs.symlinkSync(path.join(tmp, "real", "keep.ts"), path.join(tmp, "linked.ts"));
    } catch {
      // A platform without symlink permission skips ONLY the symlink assertion —
      // never the depth case, which needs no symlink (an early `return` here
      // silently removed that coverage on those platforms).
      linked = false;
    }
    collectFiles(tmp, ".", (n) => n.endsWith(".ts"), 6, errors);
    if (linked) {
      ok(errors.some((e) => e.includes("symlinked entry")), `a symlink must be reported, got ${JSON.stringify(errors)}`);
    }
    // A depth bound that truncates must report too — asserted on EVERY platform.
    const deep: string[] = [];
    collectFiles(tmp, ".", (n) => n.endsWith(".ts"), 0, deep);
    ok(deep.some((e) => e.includes("depth bound")), `a truncated subtree must be reported, got ${JSON.stringify(deep)}`);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

test("a symlinked node_modules is NOT reported (the exclusion is by name, before the type check)", () => {
  // Regression: `isDirectory()` is false for a symlink, so excluding
  // `node_modules` only inside the directory branch reported a symlinked
  // node_modules — routine under pnpm / npm workspaces / a developer's `ln -s`
  // — as a DROPPED SUBTREE and failed the vacuity check on a healthy checkout.
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "declared-surface-nm-"));
  const errors: string[] = [];
  try {
    fs.mkdirSync(path.join(tmp, "real-nm"), { recursive: true });
    fs.writeFileSync(path.join(tmp, "real-nm", "dep.ts"), "");
    let linked = true;
    try {
      fs.symlinkSync(path.join(tmp, "real-nm"), path.join(tmp, "node_modules"));
    } catch {
      linked = false; // a platform without symlink permission — the name rule below still holds
    }
    const got = collectFiles(tmp, ".", (n) => n.endsWith(".ts"), 6, errors);
    equal(
      got.join(","),
      "./real-nm/dep.ts",
      `only the real directory may be walked (node_modules must not be), got ${JSON.stringify(got)}`,
    );
    if (linked) {
      equal(errors.length, 0, `a symlinked node_modules must NOT be a walk error, got ${JSON.stringify(errors)}`);
    }
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
