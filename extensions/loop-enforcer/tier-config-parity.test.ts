/**
 * tier-config-parity.test.ts — drift guard for the runtime review-cycle bounds (#723)
 *
 * The silent-failure mode this guards: `TIER_CONFIG.complex.maxCycles` sat at
 * **20** — 2× the canonical High-tier bound — in runtime code, under a comment
 * claiming to be the proportional-gates mapping. Nothing failed, because the
 * `tier` parameter of `evaluateTermination` is not passed by any production
 * caller yet: a latent bound that would have silently doubled the governance
 * maximum the day a caller started passing `tier: "complex"`.
 *
 * A comment is not a guard, so this suite parses the canonical "Review Cycles"
 * table out of `skills/proportional-gates/SKILL.md` (the table AGENTS.md
 * §Hard Cap names canonical) and fails when the runtime mapping diverges from
 * it — in EITHER column. The risk row is selected by `reviewers`; `maxCycles`
 * must equal that row's Max Cycles. This means editing a tier's reviewer count
 * without re-deriving its cap (or vice versa) is a test failure, not a silent
 * drift.
 *
 * Non-vacuity: the parser is asserted against the known table shape, and
 * `mappingViolations()` is exercised with deliberately mutated inputs so a
 * silently-empty parse or an always-pass check cannot make this suite green.
 * The suite also **pins the tier → risk-row assignment** as a fixture: the
 * pair check alone would accept a coordinated re-point (e.g. `standard` moved
 * to Medium-High, { reviewers: 3, maxCycles: 5 }), and the coordinated-re-point
 * control documents that blind spot rather than pretending it does not exist.
 *
 * #838 extends the same suite to the adversarial-domain bound. Gate/enforcement
 * code has no natural bottom, so "the reviewer returns NO ISSUES FOUND" is an
 * unbounded acceptance criterion there — the budget is a DECLARED threat
 * surface, capped at 2 cycles, acceptance = threat-list coverage + green CI.
 * That cap is stated on eight surfaces; `adversarialBoundViolations()` pins them
 * to one value (an absent anchor is a violation, never a silent pass) and
 * `nonAdversarialCapViolations()` pins the risk rows #838 must NOT touch.
 *
 * WIRING HONESTY: this suite runs in the per-PR `verify` job (VISIBLE, not
 * merge-blocking — the repo's only required check is `pipeline-compliance`)
 * and in the post-merge ci-main.yml `extension-tests` job (the blocking
 * backstop, same split as the other extension suites).
 *
 * Run: npx tsx extensions/loop-enforcer/tier-config-parity.test.ts
 */

import { readFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { ok, equal, deepEqual } from "node:assert/strict";

import { evaluateTermination, REVIEW_CYCLE_CAPS, TIER_CONFIG, type CycleData } from "./termination.ts";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(HERE, "..", "..");
const SKILL_PATH = join(REPO_ROOT, "skills", "proportional-gates", "SKILL.md");
const INDEX_SRC = readFileSync(join(HERE, "index.ts"), "utf-8");

/** Minimal cycle factory for the behavioural live-cap assertions. */
function cycle(n: number, issues: number, verdict = "NEEDS_FIX", fingerprint?: string, issuesFixed = 0): CycleData {
  return { cycleNumber: n, issuesFound: issues, issuesFixed, verdict, fingerprint, filesChanged: 0, wallClockMs: 0 };
}

let passed = 0;
let failed = 0;
function test(name: string, fn: () => void) {
  try {
    fn();
    passed++;
    console.log(`  ✅ ${name}`);
  } catch (err: any) {
    failed++;
    console.log(`  ❌ ${name}: ${err.message}`);
  }
}
function section(name: string) {
  console.log(`\n${name}:`);
}

// ── Parser: canonical table → rows ──────────────────────────────────────────

export interface RiskRow {
  /** Risk label as written in the table (parentheticals stripped). */
  risk: string;
  /** Reviewer count parsed from the Reviewers cell. */
  reviewers: number;
  /** Max Cycles cell; the Low row's em-dash means "review skipped" → 0. */
  maxCycles: number;
}

/**
 * Parse the "### Review Cycles" table from the canonical skill markdown.
 * Throws when the section or its rows are missing — a parse that silently
 * yields nothing would make every downstream assertion vacuous.
 */
export function parseReviewCycleTable(markdown: string): RiskRow[] {
  const lines = markdown.split("\n");
  const start = lines.findIndex((l) => /^###\s+Review Cycles\s*$/.test(l.trim()));
  if (start === -1) {
    throw new Error(`${SKILL_PATH}: no "### Review Cycles" heading — the canonical table moved or was renamed`);
  }
  const rows: RiskRow[] = [];
  for (let i = start + 1; i < lines.length; i++) {
    const line = lines[i].trim();
    if (!line.startsWith("|")) {
      if (rows.length > 0) break; // table ended
      continue; // prose between heading and table
    }
    const cells = line.replace(/^\|/, "").replace(/\|$/, "").split("|").map((c) => c.trim());
    if (cells.length < 3) continue;
    if (/^-{2,}$/.test(cells[0].replace(/[:\s]/g, ""))) continue; // separator row
    if (/^risk$/i.test(cells[0])) continue; // header row
    const reviewerMatch = cells[1].match(/^\d+/);
    if (!reviewerMatch) {
      throw new Error(`${SKILL_PATH}: unrecognised Reviewers cell "${cells[1]}" on risk row "${cells[0]}"`);
    }
    const reviewers = Number(reviewerMatch[0]);
    // The Max Cycles cell must be an integer or an explicit skip marker.
    // Coercing anything else to 0 would let a bogus cell parse as "skip" —
    // silent fabrication of exactly the kind this suite exists to catch
    // (cycle-4 review).
    const cell = cells[2];
    let maxCycles: number;
    if (/^\d+$/.test(cell)) {
      maxCycles = Number(cell);
    } else if (/^(\u2014|\u2013|-|n\/a|none|skip)$/i.test(cell)) {
      maxCycles = 0;
    } else {
      throw new Error(`${SKILL_PATH}: unrecognised Max Cycles cell "${cell}" on risk row "${cells[0]}"`);
    }
    rows.push({ risk: cells[0].replace(/\s*\(.*\)\s*$/, ""), reviewers, maxCycles });
  }
  if (rows.length === 0) {
    throw new Error(`${SKILL_PATH}: "### Review Cycles" present but no table row parsed`);
  }
  return rows;
}

/**
 * Extract the top-level argument list of every `fnName(` call in `src`.
 * Comment-aware and paren/bracket/brace-balanced, so a trailing `//`-comment or
 * a nested call inside an argument cannot shorten the argument list. Textual by
 * construction — see the tripwire test's own LIMIT note for what it does and
 * does not prove.
 */
export function extractCallArgs(src: string, fnName: string): string[][] {
  const calls: string[][] = [];
  const re = new RegExp(`\\b${fnName}\\s*\\(`, "g");
  let m: RegExpExecArray | null;
  while ((m = re.exec(src)) !== null) {
    let i = m.index + m[0].length; // first char after '('
    let depth = 1;
    let current = "";
    const args: string[] = [];
    for (; i < src.length && depth > 0; i++) {
      const ch = src[i];
      const next = src[i + 1];
      if (ch === "/" && next === "/") {
        while (i < src.length && src[i] !== "\n") i++;
        continue;
      }
      if (ch === "/" && next === "*") {
        i += 2;
        while (i < src.length && !(src[i] === "*" && src[i + 1] === "/")) i++;
        i++;
        continue;
      }
      if (ch === "(" || ch === "[" || ch === "{") depth++;
      else if (ch === ")" || ch === "]" || ch === "}") {
        depth--;
        if (depth === 0) break;
      } else if (ch === "," && depth === 1) {
        args.push(current.trim());
        current = "";
        continue;
      }
      current += ch;
    }
    args.push(current.trim());
    calls.push(args.length === 1 && args[0] === "" ? [] : args);
    re.lastIndex = i;
  }
  return calls;
}

/** Trailing commas yield a final empty argument — drop them. */
export function normalizeArgs(args: string[]): string[] {
  const out = [...args];
  while (out.length > 0 && out[out.length - 1] === "") out.pop();
  return out;
}

/**
 * The production call must pass exactly ONE argument — the cycle list. No
 * explicit bound and no `tier` (a tier silently overrides the pinned bound).
 * A second argument and a spread (`...([cycleData, 20])`) both fail; a hoisted
 * identifier (`evaluateTermination(d)`) and a trailing comma pass. Rejecting
 * spread is what closes the cycle-4 bypass of a pure argument-count check.
 *
 * LIMIT (stated, not hidden): this is textual. The call site lives inside the
 * `agent_end` hook handler, so driving it needs a fake ExtensionAPI and a
 * manifest on disk — the shape check stands in for that (the module body itself
 * IS executed: `loop-integration.test.ts` and `session-affinity.test.ts` import
 * `./index.js`). A call form the extractor cannot match — optional call
 * `f?.(...)`, an alias calling it, `f.call(...)` — is treated as "no call
 * found" and therefore fails CLOSED (red), not silently green, when it replaces
 * the production call. Only a decoy call left in place alongside one of those
 * forms would evade.
 */
export function liveCallShapeViolations(src: string): string[] {
  const calls = extractCallArgs(src, "evaluateTermination");
  if (calls.length === 0) return ["no evaluateTermination call found in index.ts — update this pin"];
  const violations: string[] = [];
  for (const raw of calls) {
    const args = normalizeArgs(raw);
    if (args.length !== 1) {
      violations.push(
        `live call must pass exactly 1 argument (the cycle list — no bound, no tier); got ${JSON.stringify(args)}`,
      );
      continue;
    }
    if (args[0].includes("...")) {
      violations.push(
        `live call must not spread — a bound can ride in that way; got ${JSON.stringify(args[0])}`,
      );
    }
  }
  return violations;
}

// ── Pure check: declared mapping vs canonical table ─────────────────────────

export interface TierLike {
  maxCycles: number;
  reviewers: number;
}

/**
 * Returns a human-readable violation per divergence; `[]` means the mapping is
 * canonical. Pure so the negative-control tests below can prove it rejects
 * drift rather than merely never firing.
 */
export function mappingViolations(
  caps: Record<string, number>,
  tiers: Record<string, TierLike>,
  table: RiskRow[],
): string[] {
  const violations: string[] = [];
  const byReviewers = new Map<number, RiskRow>();
  for (const row of table) byReviewers.set(row.reviewers, row);

  const check = (label: string, declared: number, reviewers: number) => {
    const row = byReviewers.get(reviewers);
    if (!row) {
      violations.push(`${label}: no canonical risk row with ${reviewers} reviewer(s)`);
      return;
    }
    if (row.maxCycles !== declared) {
      violations.push(
        `${label}: maxCycles ${declared} ≠ canonical ${row.maxCycles} for the ${row.risk} row (${reviewers} reviewers)`,
      );
    }
  };

  check("REVIEW_CYCLE_CAPS.skip", caps.skip, 0);
  check("REVIEW_CYCLE_CAPS.lowMedium", caps.lowMedium, 2);
  check("REVIEW_CYCLE_CAPS.mediumHigh", caps.mediumHigh, 3);
  check("REVIEW_CYCLE_CAPS.high", caps.high, 4);

  for (const [tier, cfg] of Object.entries(tiers)) {
    check(`TIER_CONFIG.${tier}`, cfg.maxCycles, cfg.reviewers);
  }

  // Governance ceiling: no tier may exceed the largest canonical bound (#723's
  // actual defect — complex at 20 against a max of 10). Computed from the
  // CANONICAL TABLE, never from `caps` — deriving it from `caps` would let an
  // unbacked extra key inflate the ceiling the guard trusts.
  const governanceMax = Math.max(...table.map((r) => r.maxCycles));
  for (const [tier, cfg] of Object.entries(tiers)) {
    if (cfg.maxCycles > governanceMax) {
      violations.push(
        `TIER_CONFIG.${tier}.maxCycles ${cfg.maxCycles} exceeds the governance maximum ${governanceMax}`,
      );
    }
  }
  return violations;
}

// ── Adversarial-domain bound (#838) ─────────────────────────────────────────

/**
 * Surfaces that must all declare the SAME adversarial-domain cycle bound.
 *
 * #838: on gate/enforcement code there is no natural bottom, so "the reviewer
 * returns NO ISSUES FOUND" is an unbounded acceptance criterion and a
 * count-cap is indistinguishable from failure. The bound is instead a
 * DECLARED threat surface — capped at 2 cycles, acceptance = every declared
 * threat class covered by a test + green CI, residuals filed not chased.
 *
 * The cap is stated on several surfaces (protocol of record, canonical table,
 * each consuming skill), so drift BETWEEN them is the failure pinned here —
 * the same class #723 caught for the runtime tiers. The anchor is
 * machine-readable (`adversarial-bound: cap=N`) rather than prose because the
 * surrounding text legitimately names the general 10-cycle cap.
 */
export const ADVERSARIAL_CAP = 2;
export const ADVERSARIAL_SURFACES = [
  "AGENTS.md",
  "templates/AGENTS.base.md",
  "skills/proportional-gates/SKILL.md",
  "skills/code-review/SKILL.md",
  "skills/code-review/references/fixer-loop.md",
  "skills/plan-review/SKILL.md",
  "skills/issue-scoping/SKILL.md",
  "skills/task-workflow-standard/SKILL.md",
] as const;

const ADVERSARIAL_ANCHOR_RE = /adversarial-bound: cap=(\d+)/g;

/** Cap values declared by anchors in `src`, in file order. */
export function declaredAdversarialCaps(src: string): number[] {
  const out: number[] = [];
  for (const m of src.matchAll(ADVERSARIAL_ANCHOR_RE)) out.push(Number(m[1]));
  return out;
}

/**
 * A violation per unanchored / divergent surface; `[]` means every surface
 * declares the same adversarial cap. Pure, so the negative controls below can
 * prove it rejects drift rather than merely never firing. Exactly ONE anchor
 * per surface is required: a missing anchor is what a naive grep reads as
 * clean, and it must be a violation, never a silent pass.
 */
export function adversarialBoundViolations(sources: Record<string, string>): string[] {
  const violations: string[] = [];
  const declared = new Map<string, number>();
  for (const [path, src] of Object.entries(sources)) {
    const caps = declaredAdversarialCaps(src);
    if (caps.length !== 1) {
      violations.push(
        `${path}: expected exactly 1 \`adversarial-bound: cap=N\` anchor, found ${caps.length}`,
      );
      continue;
    }
    if (caps[0] !== ADVERSARIAL_CAP) {
      violations.push(`${path}: adversarial cap ${caps[0]} ≠ ${ADVERSARIAL_CAP}`);
    }
    declared.set(path, caps[0]);
  }
  if (new Set(declared.values()).size > 1) {
    violations.push(
      `adversarial cap differs across surfaces: ${[...declared.entries()].map(([p, c]) => `${p}=${c}`).join(", ")}`,
    );
  }
  return violations;
}

/**
 * The canonical NON-adversarial bounds a change may not silently move.
 * Deliberately duplicated from the table assertions above: this is the
 * "silent re-cap" threat class's own test, and it also fails closed when a
 * risk row disappears rather than treating the absence as "no divergence".
 */
export const CANONICAL_NON_ADVERSARIAL: ReadonlyArray<[string, number]> = [
  ["Low", 0],
  ["Low-Medium", 3],
  ["Medium-High", 5],
  ["High", 10],
];

/** Violations of the non-adversarial caps; `[]` means untouched. Pure. */
export function nonAdversarialCapViolations(table: RiskRow[]): string[] {
  const violations: string[] = [];
  for (const [risk, cap] of CANONICAL_NON_ADVERSARIAL) {
    const row = table.find((r) => r.risk === risk);
    if (!row) {
      violations.push(`canonical table lost the "${risk}" risk row`);
      continue;
    }
    if (row.maxCycles !== cap) {
      violations.push(
        `${risk} row cap ${row.maxCycles} ≠ ${cap} — the adversarial bound must not re-cap non-adversarial work`,
      );
    }
  }
  return violations;
}

/**
 * Extract the fenced ```bash blocks from the fixer-loop doc. The loop is
 * instructions an agent copies and runs, so "what executes" is the code inside
 * the fences — not the surrounding prose, and not a commented-out line.
 */
export function executableBashBlocks(md: string): string[] {
  const out: string[] = [];
  for (const m of md.matchAll(/```bash\n([\s\S]*?)```/g)) out.push(m[1]);
  return out;
}

/**
 * Strip shell comments from a line so a commented-out statement can never
 * satisfy a pin. `#` is a comment only at the start of a word (line start or
 * after whitespace) and only outside single/double quotes — so `"${VAR#pfx}"`
 * and `${ADVERSARIAL_BOUND:-0}` are left intact.
 */
function stripLineComment(line: string): string {
  let quote = "";
  for (let i = 0; i < line.length; i++) {
    const ch = line[i];
    if (quote) {
      if (ch === quote) quote = "";
      continue;
    }
    if (ch === "'" || ch === '"') {
      quote = ch;
      continue;
    }
    if (ch === "#" && (i === 0 || /\s/.test(line[i - 1]))) return line.slice(0, i);
  }
  return line;
}

/** Comment-stripped copy of shell code. */
export function stripShellComments(code: string): string {
  return code.split("\n").map(stripLineComment).join("\n");
}

/**
 * The `BOUND=<N>` assignments the fixer loop declares, in source order: the
 * pre-loop general default (10) and the adversarial branch (the declared cap).
 * Parsed from fenced bash with comments stripped. `${ADVERSARIAL_BOUND:-0}` is
 * not matched — `\b` before `BOUND` fails after `_`, and there is no `=`.
 *
 * This is a SHAPE check only. `effectiveAdversarialBound()` below is
 * authoritative: assignment text cannot see a neutered guard variable (the
 * cycle-3 finding — `ADVERSARIAL_BOUND=0` injected before an intact branch), so
 * the suite EXECUTES the fence to learn the bound.
 */
export function executableBoundAssignments(src: string): number[] {
  const out: number[] = [];
  for (const block of executableBashBlocks(src)) {
    for (const m of stripShellComments(block).matchAll(/\bBOUND=(\d+)\b/g)) out.push(Number(m[1]));
  }
  return out;
}

/**
 * Every assignment to `ADVERSARIAL_BOUND` in the fenced, comment-stripped code,
 * as its raw value. The setup line (`ADVERSARIAL_BOUND=${ADVERSARIAL_BOUND:-0}`)
 * is the ONLY legitimate assignment: a literal reassignment (`ADVERSARIAL_BOUND=0`
 * placed before the branch) neuters the guard while leaving the branch text
 * byte-for-byte intact, so it must be a violation on its own.
 */
export function adversarialBoundAssignments(src: string): string[] {
  const out: string[] = [];
  for (const block of executableBashBlocks(src)) {
    for (const m of stripShellComments(block).matchAll(/\bADVERSARIAL_BOUND=(\S*)/g)) out.push(m[1]);
  }
  return out;
}

/** The general (non-adversarial) safety cap the executable loop must default to. */
export const EXECUTABLE_DEFAULT_BOUND = 10;

/**
 * The private execution marker the harness prints AFTER the fenced body.
 *
 * The body is attacker-influenced text; a marker the fence could also produce
 * (`BOUND=<N>`) is forgeable — a decoy `printf "BOUND=%d\n" 2` was read by the
 * old FIRST-match parse while the real loop executed 10 (cycle-2 residual
 * #874). The sentinel is not in the documented fence, so the fence cannot print
 * it, and the harness reads the LAST occurrence — its own trailing echo, which
 * runs after the body. Emission uses `command`, so a function the body defines
 * cannot shadow it.
 */
export const BOUND_SENTINEL = "__PIN_BOUND__";

/**
 * The fenced L1 block the executable pin runs: the one that assigns `BOUND` and
 * references `ADVERSARIAL_BOUND`.
 */
export function fixerLoopBlock(src: string): string {
  const block = executableBashBlocks(src).find(
    (b) => /^\s*BOUND=\d+\s*$/m.test(stripShellComments(b)) && b.includes("ADVERSARIAL_BOUND"),
  );
  if (!block) throw new Error("no fenced bash block assigns BOUND and references ADVERSARIAL_BOUND");
  return block;
}

/**
 * The ONLY statement shapes the documented L1 fence may contain — fully anchored
 * (comment-stripped, trimmed lines). This is an ALLOWLIST, and it fails closed:
 * any statement that does not match one of these is a violation, so the
 * executable body cannot define a function, set a trap, background a writer,
 * reassign a builtin (`command`/`printf`/`builtin`/`[`), or otherwise touch the
 * reporting channel. That is what makes the stdout read-back unforgeable — a
 * decoy, a shadowed builtin, or `exec 1>&2` is simply not an allowed statement
 * (cycle-2 finding on the executable pin).
 */
const L1_ALLOWED_STATEMENTS: RegExp[] = [
  /^CYCLE=\$\(\(CYCLE \+ 1\)\)$/,
  /^BOUND=\d+$/,
  /^if \[ "\$\{ADVERSARIAL_BOUND:-0\}" = "1" \]; then BOUND=\d+; fi$/,
  /^if \[ \$CYCLE -gt \$BOUND \]; then$/,
  /^if \[ "\$\{ADVERSARIAL_BOUND:-0\}" = "1" \]; then EXIT_REASON="adversarial-capped"; else EXIT_REASON="cycle-cap"; fi$/,
  /^break$/,
  /^fi$/,
  /^PR_STATE=\$\(gh pr view \$PR_NUMBER --json state --jq '\.state' 2>\/dev\/null \|\| echo "UNKNOWN"\)$/,
  /^if \[ "\$PR_STATE" != "OPEN" \]; then EXIT_REASON="pr-closed"; break; fi$/,
];

/** Statements in the fenced L1 block that are not part of the documented fence. */
export function unallowedL1Statements(block: string): string[] {
  const bad: string[] = [];
  for (const raw of stripShellComments(block).split("\n")) {
    const line = raw.trim();
    if (line === "") continue;
    if (!L1_ALLOWED_STATEMENTS.some((re) => re.test(line))) bad.push(line);
  }
  return bad;
}

/**
 * The bound the fence ACTUALLY produces, obtained by RUNNING it. The fenced L1
 * block is executed under bash with `ADVERSARIAL_BOUND` set to 1 (adversarial)
 * or 0 (general), `gh` stubbed to report OPEN, and the loop variables seeded —
 * then `BOUND` is read back. This is the only check that binds to what
 * EXECUTES: a commented-out branch, a reassigned guard variable, an
 * unconditional branch, or a rewritten condition all change the observed value
 * while leaving assignment text untouched. `break` is neutralised (the block is
 * a loop body, not a loop) and cannot affect the bound. The bound is reported by
 * the harness's OWN trailing `BOUND_SENTINEL` echo and read as the LAST
 * occurrence, so a forged marker the body prints can never be the value read.
 *
 * LIMIT (stated, not hidden): it executes the DOCUMENTED fence, which is what a
 * fixer agent copies; it cannot prove an agent ran something else.
 */
export function effectiveAdversarialBound(src: string, adversarial: boolean): number {
  const block = fixerLoopBlock(src);
  const unallowed = unallowedL1Statements(block);
  if (unallowed.length > 0) {
    throw new Error(
      `the fixer-loop fence contains statements the harness refuses to execute: ${unallowed.join(" | ")}`,
    );
  }
  const body = stripShellComments(block).replace(/\bbreak\b/g, "true");
  const script = [
    'gh() { echo "OPEN"; }',
    "CYCLE=0",
    "PR_NUMBER=1",
    'EXIT_REASON=""',
    `ADVERSARIAL_BOUND=${adversarial ? 1 : 0}`,
    body,
    // `command` skips a function the body may define, so the sentinel cannot be
    // shadowed; the sentinel itself is private to this harness.
    `command echo "${BOUND_SENTINEL}=\${BOUND}"`,
    'echo "EXIT_REASON=${EXIT_REASON}"',
  ].join("\n");
  let out: string;
  try {
    out = execFileSync("bash", ["-c", script], { encoding: "utf-8", timeout: 10_000 });
  } catch (err: any) {
    throw new Error(`executing the fixer-loop fence failed: ${err?.message ?? err}`);
  }
  // LAST occurrence: the harness's own trailing echo is the final sentinel line,
  // so a decoy the body printed earlier can never win (cycle-2 residual #874).
  const re = new RegExp(`^${BOUND_SENTINEL}=(\\d+)\\s*$`, "gm");
  let last: string | undefined;
  for (const m of out.matchAll(re)) last = m[1];
  if (last === undefined) {
    throw new Error(`the fixer-loop fence did not report ${BOUND_SENTINEL}; output: ${out}`);
  }
  return Number(last);
}

/**
 * Violations when the fixer loop's EFFECTIVE bounds diverge from the declared
 * contract. Three layers, weakest first: shape (exactly two `BOUND=<N>`
 * assignments, 10 then the declared cap), guard integrity (no literal
 * reassignment of `ADVERSARIAL_BOUND`), and EXECUTION (the fence run with the
 * guard set must produce 2 adversarial / 10 general). The execution layer is
 * what closes both cycle-2 residuals and the cycle-3 guard-neutering bypass.
 */
export function executableBoundViolations(src: string): string[] {
  const violations: string[] = [];
  // Layer 0 — the fail-closed statement allowlist. Anything the documented
  // fence would not contain is refused BEFORE execution, so it cannot shadow a
  // builtin or forge the report (cycle-2 finding).
  try {
    for (const line of unallowedL1Statements(fixerLoopBlock(src))) {
      violations.push(
        `fixer-loop: \`${line}\` is not part of the documented L1 fence — refusing to execute it`,
      );
    }
  } catch {
    // A missing block is reported by the shape/execution layers below.
  }
  const bounds = executableBoundAssignments(src);
  if (bounds.length !== 2) {
    violations.push(
      `fixer-loop: expected exactly 2 executable \`BOUND=<N>\` assignments (the general default + the adversarial branch), found ${bounds.length}`,
    );
  } else {
    if (bounds[0] !== EXECUTABLE_DEFAULT_BOUND) {
      violations.push(
        `fixer-loop: the EXECUTED general default bound is ${bounds[0]}, expected ${EXECUTABLE_DEFAULT_BOUND}`,
      );
    }
    if (bounds[1] !== ADVERSARIAL_CAP) {
      violations.push(
        `fixer-loop: the EXECUTED adversarial bound is ${bounds[1]}, but the declared cap is ${ADVERSARIAL_CAP}`,
      );
    }
  }
  for (const value of adversarialBoundAssignments(src)) {
    if (value !== "${ADVERSARIAL_BOUND:-0}") {
      violations.push(
        `fixer-loop: \`ADVERSARIAL_BOUND=${value}\` reassigns the guard variable (only the \`\${ADVERSARIAL_BOUND:-0}\` default setup is allowed) — a literal reassignment neuters the bound`,
      );
    }
  }
  try {
    const adversarial = effectiveAdversarialBound(src, true);
    if (adversarial !== ADVERSARIAL_CAP) {
      violations.push(
        `fixer-loop: EXECUTING the fence with ADVERSARIAL_BOUND=1 yields BOUND=${adversarial}, expected ${ADVERSARIAL_CAP}`,
      );
    }
    const general = effectiveAdversarialBound(src, false);
    if (general !== EXECUTABLE_DEFAULT_BOUND) {
      violations.push(
        `fixer-loop: EXECUTING the fence with ADVERSARIAL_BOUND=0 yields BOUND=${general}, expected ${EXECUTABLE_DEFAULT_BOUND}`,
      );
    }
  } catch (err: any) {
    violations.push(`fixer-loop: could not execute the fence: ${err?.message ?? err}`);
  }
  return violations;
}

// ── Fixtures ────────────────────────────────────────────────────────────────

const MARKDOWN = readFileSync(SKILL_PATH, "utf-8");
const TABLE = parseReviewCycleTable(MARKDOWN);
const TIERS: Record<string, TierLike> = TIER_CONFIG;
const CAPS: Record<string, number> = REVIEW_CYCLE_CAPS;

// ── The canonical table itself ──────────────────────────────────────────────

section("Canonical table parse (skills/proportional-gates/SKILL.md)");

test("Review Cycles table parses to the four proportional rows", () => {
  deepEqual(
    TABLE.map((r) => [r.risk, r.reviewers, r.maxCycles]),
    [
      ["Low", 0, 0],
      ["Low-Medium", 2, 3],
      ["Medium-High", 3, 5],
      ["High", 4, 10],
    ],
  );
});

test("High-tier canonical bound is 10 (post-#705)", () => {
  equal(TABLE.find((r) => r.risk === "High")?.maxCycles, 10);
});

// ── Adversarial-domain bound (#838) ─────────────────────────────────────────

section("Adversarial-domain bound parity (#838)");

const ADVERSARIAL_SOURCES: Record<string, string> = Object.fromEntries(
  ADVERSARIAL_SURFACES.map((p) => [p, readFileSync(join(REPO_ROOT, p), "utf-8")]),
);

function violationsOf(sources: Record<string, string>): string {
  return adversarialBoundViolations(sources).join(" | ");
}

test("every adversarial surface declares exactly one cap anchor, and all agree at 2", () => {
  deepEqual(
    adversarialBoundViolations(ADVERSARIAL_SOURCES),
    [],
    `adversarial bound drifted: ${violationsOf(ADVERSARIAL_SOURCES)}`,
  );
});

test("#838 does not re-cap non-adversarial work (3 / 5 / 10 intact)", () => {
  deepEqual(
    nonAdversarialCapViolations(TABLE),
    [],
    `non-adversarial caps moved: ${nonAdversarialCapViolations(TABLE).join(" | ")}`,
  );
});

test("the executable fixer loop keeps the 10-cycle default and adds the adversarial branch", () => {
  const src = ADVERSARIAL_SOURCES["skills/code-review/references/fixer-loop.md"];
  // Exact numeric parity on the parsed executable — never `includes("BOUND=10")`,
  // which `BOUND=100` satisfies (cycle-2 residual #874).
  deepEqual(
    executableBoundAssignments(src),
    [EXECUTABLE_DEFAULT_BOUND, ADVERSARIAL_CAP],
    "the executable loop must assign exactly the general default then the adversarial cap",
  );
  ok(src.includes("ADVERSARIAL_BOUND"), "the executable loop must honour the declared adversarial domain");
  ok(
    src.includes('EXIT_REASON="adversarial-capped"'),
    "a bounded adversarial exit must be recorded under its own exit_reason",
  );
  ok(
    src.includes("ADVERSARIAL_BOUND=${ADVERSARIAL_BOUND:-0}"),
    "the pre-loop setup must define ADVERSARIAL_BOUND, or the branch is unreachable",
  );
});

test("the EXECUTED adversarial bound equals the declared cap (anchor ↔ code)", () => {
  const src = ADVERSARIAL_SOURCES["skills/code-review/references/fixer-loop.md"];
  deepEqual(executableBoundViolations(src), [], `executable bound drifted: ${executableBoundViolations(src).join(" | ")}`);
});

// Negative controls — the guard must actually reject drift.

test("rejects a divergent adversarial cap on one surface", () => {
  const path = "skills/plan-review/SKILL.md";
  const mutated = { ...ADVERSARIAL_SOURCES, [path]: ADVERSARIAL_SOURCES[path].replace("cap=2", "cap=3") };
  ok(mutated[path] !== ADVERSARIAL_SOURCES[path], "control did not apply — the anchor text moved");
  const v = adversarialBoundViolations(mutated);
  ok(v.some((s) => s.includes(path)), `expected a ${path} violation, got: ${v.join(" | ")}`);
  ok(v.some((s) => s.includes("differs across surfaces")), `expected a cross-surface violation, got: ${v.join(" | ")}`);
});

test("rejects a MISSING anchor (the vacuity hole a naive grep reads as clean)", () => {
  const path = "AGENTS.md";
  const stripped = ADVERSARIAL_SOURCES[path].replace(/ ?<!-- adversarial-bound: cap=2 -->/, "");
  ok(stripped !== ADVERSARIAL_SOURCES[path], "control did not apply — the AGENTS.md anchor was not found");
  const v = adversarialBoundViolations({ ...ADVERSARIAL_SOURCES, [path]: stripped });
  ok(v.some((s) => s.includes(path) && s.includes("found 0")), `expected found-0, got: ${v.join(" | ")}`);
});

test("rejects a DUPLICATED anchor (two declarations in one file)", () => {
  const path = "AGENTS.md";
  const dup = `${ADVERSARIAL_SOURCES[path]}\n<!-- adversarial-bound: cap=2 -->\n`;
  const v = adversarialBoundViolations({ ...ADVERSARIAL_SOURCES, [path]: dup });
  ok(v.some((s) => s.includes(path) && s.includes("found 2")), `expected found-2, got: ${v.join(" | ")}`);
});

test("rejects a re-capped canonical table (the non-adversarial guard is not vacuous)", () => {
  const recapped = TABLE.map((r) => (r.risk === "High" ? { ...r, maxCycles: 5 } : r));
  const v = nonAdversarialCapViolations(recapped);
  ok(v.some((s) => s.includes("High")), `expected a High violation, got: ${v.join(" | ")}`);
});

test("rejects a canonical table that lost a risk row", () => {
  const v = nonAdversarialCapViolations(TABLE.filter((r) => r.risk !== "Low-Medium"));
  ok(v.some((s) => s.includes("Low-Medium")), `expected a Low-Medium violation, got: ${v.join(" | ")}`);
});

test("rejects an executable bound that drifted from the declared cap (BOUND=3, anchor intact)", () => {
  const path = "skills/code-review/references/fixer-loop.md";
  const src = ADVERSARIAL_SOURCES[path];
  const mutated = src.replace("then BOUND=2; fi", "then BOUND=3; fi");
  ok(mutated !== src, "control did not apply — the `then BOUND=2; fi` branch was not found");
  // The anchor is untouched, so anchor parity alone stays green — this is the
  // bypass the executable-bound check exists to close.
  deepEqual(adversarialBoundViolations({ ...ADVERSARIAL_SOURCES, [path]: mutated }), [], "anchor parity is expected to stay green");
  const v = executableBoundViolations(mutated);
  ok(v.some((s) => s.includes("EXECUTED adversarial bound is 3")), `expected an executed-bound violation, got: ${v.join(" | ")}`);
});

test("rejects a COMMENTED-OUT adversarial branch (executed default stays 10 — cycle-2 residual #874)", () => {
  const path = "skills/code-review/references/fixer-loop.md";
  const src = ADVERSARIAL_SOURCES[path];
  const commented = src.replace(
    'if [ "${ADVERSARIAL_BOUND:-0}" = "1" ]; then BOUND=2; fi',
    '# if [ "${ADVERSARIAL_BOUND:-0}" = "1" ]; then BOUND=2; fi',
  );
  ok(commented !== src, "control did not apply — the adversarial BOUND branch was not found");
  // The anchor is untouched and the old `then BOUND=<N>; fi` regex still
  // matched the comment, so anchor parity AND the old text match stayed green —
  // this is the bypass the comment stripper exists to close.
  deepEqual(
    adversarialBoundViolations({ ...ADVERSARIAL_SOURCES, [path]: commented }),
    [],
    "anchor parity is expected to stay green",
  );
  const v = executableBoundViolations(commented);
  ok(v.some((s) => s.includes("found 1")), `expected found-1 (only the default executes), got: ${v.join(" | ")}`);
});

test("rejects a mutated general default that `includes('BOUND=10')` would miss (BOUND=100 — cycle-2 residual #875)", () => {
  const path = "skills/code-review/references/fixer-loop.md";
  const src = ADVERSARIAL_SOURCES[path];
  const bumped = src.replace("\nBOUND=10\n", "\nBOUND=100\n");
  ok(bumped !== src, "control did not apply — the `BOUND=10` default was not found");
  ok(
    bumped.includes("BOUND=10"),
    "`BOUND=100` contains `BOUND=10` — the old substring check stayed green; that is the residual",
  );
  const v = executableBoundViolations(bumped);
  ok(
    v.some((s) => s.includes("general default bound is 100")),
    `expected a general-default violation, got: ${v.join(" | ")}`,
  );
});

test("rejects a dropped adversarial branch (one assignment, not two)", () => {
  const dropped = ADVERSARIAL_SOURCES["skills/code-review/references/fixer-loop.md"].replace(
    /if \[ "\$\{ADVERSARIAL_BOUND:-0\}" = "1" \]; then BOUND=2; fi\n/,
    "",
  );
  ok(
    dropped !== ADVERSARIAL_SOURCES["skills/code-review/references/fixer-loop.md"],
    "control did not apply — the adversarial BOUND branch was not found",
  );
  const v = executableBoundViolations(dropped);
  ok(v.some((s) => s.includes("found 1")), `expected found-1, got: ${v.join(" | ")}`);
});

test("the fence EXECUTES to the declared bounds (2 adversarial / 10 general)", () => {
  const src = ADVERSARIAL_SOURCES["skills/code-review/references/fixer-loop.md"];
  equal(effectiveAdversarialBound(src, true), ADVERSARIAL_CAP, "adversarial mode must execute BOUND=2");
  equal(
    effectiveAdversarialBound(src, false),
    EXECUTABLE_DEFAULT_BOUND,
    "general mode must execute BOUND=10",
  );
});

test("rejects a neutered guard variable (`ADVERSARIAL_BOUND=0` before the intact branch — cycle-3 finding)", () => {
  const path = "skills/code-review/references/fixer-loop.md";
  const src = ADVERSARIAL_SOURCES[path];
  const neutered = src.replace(
    'BOUND=10\nif [ "${ADVERSARIAL_BOUND:-0}" = "1" ]; then BOUND=2; fi',
    'ADVERSARIAL_BOUND=0\nBOUND=10\nif [ "${ADVERSARIAL_BOUND:-0}" = "1" ]; then BOUND=2; fi',
  );
  ok(neutered !== src, "control did not apply — the BOUND=10 + branch anchor was not found");
  // The assignment SHAPE is untouched — a text-only check stayed green.
  deepEqual(
    executableBoundAssignments(neutered),
    [EXECUTABLE_DEFAULT_BOUND, ADVERSARIAL_CAP],
    "the assignment shape is expected to stay green",
  );
  const v = executableBoundViolations(neutered);
  ok(
    v.some((s) => s.includes("reassigns the guard variable")),
    `expected a guard-reassignment violation, got: ${v.join(" | ")}`,
  );
  // The allowlist also refuses the injected statement, so the execution layer
  // fails closed instead of observing the neutered bound.
  ok(
    v.some((s) => s.includes("not part of the documented L1 fence")),
    `expected the allowlist to refuse the injected reassignment, got: ${v.join(" | ")}`,
  );
});

test("rejects an unconditional adversarial branch (guard removed, assignment intact — execution layer)", () => {
  const path = "skills/code-review/references/fixer-loop.md";
  const src = ADVERSARIAL_SOURCES[path];
  const unconditional = src.replace(
    'if [ "${ADVERSARIAL_BOUND:-0}" = "1" ]; then BOUND=2; fi',
    "if true; then BOUND=2; fi",
  );
  ok(unconditional !== src, "control did not apply — the adversarial branch was not found");
  // Shape still parses as two numeric assignments; only EXECUTION sees the drift.
  deepEqual(executableBoundAssignments(unconditional), [EXECUTABLE_DEFAULT_BOUND, ADVERSARIAL_CAP]);
  const v = executableBoundViolations(unconditional);
  ok(
    v.some((s) => s.includes("not part of the documented L1 fence")),
    `expected the allowlist to refuse the rewritten guard, got: ${v.join(" | ")}`,
  );
});

test("rejects a FORGED stdout marker (decoy `printf \"BOUND=%d\\n\" 2` + real `(( BOUND = 10 ))` — cycle-2 residual #874)", () => {
  const path = "skills/code-review/references/fixer-loop.md";
  const src = ADVERSARIAL_SOURCES[path];
  const forged = src.replace(
    'if [ "${ADVERSARIAL_BOUND:-0}" = "1" ]; then BOUND=2; fi',
    'if [ "${ADVERSARIAL_BOUND:-0}" = "1" ]; then BOUND=2; fi\n' +
      '[ "${ADVERSARIAL_BOUND:-0}" = "1" ] && { (( BOUND = 10 )); printf "BOUND=%d\\n" 2; }',
  );
  ok(forged !== src, "control did not apply — the adversarial BOUND branch was not found");
  // Shape and guard checks stay green: `(( BOUND = 10 ))` has spaces around
  // `=`, and `%d` is not a digit, so the source-text pins cannot see the decoy.
  deepEqual(
    executableBoundAssignments(forged),
    [EXECUTABLE_DEFAULT_BOUND, ADVERSARIAL_CAP],
    "the assignment shape is expected to stay green",
  );
  // The decoy is not part of the documented fence, so the allowlist refuses to
  // execute it — the pin goes red and the forged marker is never even reached.
  // (The sentinel + last-match read in `effectiveAdversarialBound` remains as
  // the layer beneath this, for any body that is allowlist-clean.)
  const v = executableBoundViolations(forged);
  ok(
    v.some((s) => s.includes("not part of the documented L1 fence")),
    `expected the unknown decoy statement to be refused, got: ${v.join(" | ")}`,
  );
  ok(v.length > 0, "the forged fence must be a violation");
});

test("rejects a body that shadows a builtin to forge the marker (function definition — cycle-2 finding)", () => {
  const path = "skills/code-review/references/fixer-loop.md";
  const src = ADVERSARIAL_SOURCES[path];
  const shadowed = src.replace(
    "\nBOUND=10\n",
    '\n[() { return 1; }\ncommand() { if (( ADVERSARIAL_BOUND )); then echo "__PIN_BOUND__=2"; else echo "__PIN_BOUND__=10"; fi; }\nBOUND=10\n',
  );
  ok(shadowed !== src, "control did not apply — the `BOUND=10` default was not found");
  // Anchor parity and the numeric shape stay green; only the allowlist sees the
  // injected function definitions.
  deepEqual(
    adversarialBoundViolations({ ...ADVERSARIAL_SOURCES, [path]: shadowed }),
    [],
    "anchor parity is expected to stay green",
  );
  deepEqual(
    executableBoundAssignments(shadowed),
    [EXECUTABLE_DEFAULT_BOUND, ADVERSARIAL_CAP],
    "the assignment shape is expected to stay green",
  );
  const v = executableBoundViolations(shadowed);
  ok(
    v.some((s) => s.includes("not part of the documented L1 fence")),
    `expected the function definitions to be refused, got: ${v.join(" | ")}`,
  );
});

// ── The runtime mapping ─────────────────────────────────────────────────────

section("Runtime mapping parity");

test("REVIEW_CYCLE_CAPS + TIER_CONFIG match the canonical table", () => {
  deepEqual(
    mappingViolations(CAPS, TIERS, TABLE),
    [],
    `runtime mapping diverged from the canonical skill table:\n    ${mappingViolations(CAPS, TIERS, TABLE).join("\n    ")}`,
  );
});

test("#723 regression: TIER_CONFIG.complex.maxCycles is the canonical High bound (10)", () => {
  const high = TABLE.find((r) => r.risk === "High")!;
  equal(TIER_CONFIG.complex.maxCycles, high.maxCycles);
  equal(TIER_CONFIG.complex.maxCycles, 10);
});

test("#723 regression: no tier exceeds the governance maximum", () => {
  const governanceMax = Math.max(...TABLE.map((r) => r.maxCycles));
  for (const [tier, cfg] of Object.entries(TIERS)) {
    ok(cfg.maxCycles <= governanceMax, `TIER_CONFIG.${tier}.maxCycles ${cfg.maxCycles} > governance max ${governanceMax}`);
  }
});

test("every tier's maxCycles equals its own risk row (reviewers is the key)", () => {
  for (const [tier, cfg] of Object.entries(TIERS)) {
    const row = TABLE.find((r) => r.reviewers === cfg.reviewers);
    ok(row, `TIER_CONFIG.${tier} declares ${cfg.reviewers} reviewers — no canonical row matches`);
    equal(
      cfg.maxCycles,
      row!.maxCycles,
      `TIER_CONFIG.${tier}: ${cfg.reviewers} reviewers canonically pairs with ${row!.maxCycles} cycles, not ${cfg.maxCycles}`,
    );
  }
});

test("TIER_CONFIG pins the tier → risk-row assignment, not just the pair", () => {
  // The pair check above accepts any canonical (reviewers, maxCycles) pair, so
  // a **coordinated** re-point — e.g. `standard` moved to the Medium-High row
  // ({ reviewers: 3, maxCycles: 5 }) — satisfies it while moving the standard
  // bound. That is exactly the Low-Medium-vs-Medium-High ambiguity this PR
  // resolves in favour of Low-Medium, so the resolution itself is pinned here:
  // re-pointing a tier now requires a deliberate fixture edit.
  deepEqual(
    Object.entries(TIER_CONFIG).map(([tier, cfg]) => [tier, cfg.reviewers, cfg.maxCycles]),
    [
      ["micro", 0, 0],
      ["standard", 2, 3],
      ["complex", 4, 10],
    ],
  );
});

test("the LIVE cap: with no explicit bound the exit lands at the canonical High bound", () => {
  // Cycle-2 review caught the earlier version of this test for asserting the
  // constant against itself while claiming to pin the live cap. It is a real
  // live-cap pin now that index.ts passes NO second argument (commit 0ced953
  // follow-up): the default is the only bound in play on the production path.
  //
  // LIMIT (stated, not hidden): this pins the VALUE, not the derivation. A
  // default reverted to a bare `10` still passes while the canonical bound is
  // 10 — it only fails once the canonical bound moves. The call-site tripwire
  // below covers the other half.
  const canonical = TABLE.find((r) => r.risk === "High")!.maxCycles;
  const atCap = Array.from({ length: canonical }, (_, i) => cycle(i + 1, 2, "NEEDS_FIX", undefined, 1));
  const r = evaluateTermination(atCap);
  equal(r.reason, "L10-max-cycles", `default cap should fire L10 at ${canonical} cycles`);
  ok(r.shouldExit, "default cap must exit at the canonical bound");

  const belowCap = Array.from({ length: canonical - 1 }, (_, i) => cycle(i + 1, canonical - i, "NEEDS_FIX", undefined, 1));
  ok(!evaluateTermination(belowCap).shouldExit, "must not exit below the canonical bound");
});

test("index.ts's live call site takes the default cap (one plain argument)", () => {
  // TEXTUAL TRIPWIRE, not a proof: the call site sits inside the `agent_end`
  // hook handler, so it is checked by shape here rather than driven through a
  // fake ExtensionAPI. An unmatched call form fails CLOSED via the "no call
  // found" branch (see the LIMIT note on liveCallShapeViolations). The rule is
  // "exactly one argument, no spread"; it rejects the forms listed below while
  // accepting a hoisted identifier:
  //   evaluateTermination(cycleData, 20)                            -> 2 args
  //   evaluateTermination(cycleData, 20, // REVIEW_CYCLE_CAPS.high) -> 2 args (trailing empty element dropped by normalizeArgs)
  //   evaluateTermination(cycleData, REVIEW_CYCLE_CAPS.high + 10)   -> 2 args
  //   evaluateTermination(..., "standard")                          -> 10 args
  //   evaluateTermination(...([cycleData, 20] as any))              -> spread
  // The behavioural test above pins the value; this catches a re-added bound
  // or a tier override at the production call site.
  deepEqual(liveCallShapeViolations(INDEX_SRC), [], "live call shape drifted");
});

test("tripwire control: re-added bound / tier / spread are caught", () => {
  const variants: Array<[string, string]> = [
    ["explicit bound", "evaluateTermination(cycleData, 20)"],
    ["tier override", 'evaluateTermination(cycleData, 10, Infinity, 0, 0, 0, 0, 0, false, "complex")'],
    ["constant expression bound", "evaluateTermination(cycleData, REVIEW_CYCLE_CAPS.high + 10)"],
    ["trailing comment naming the constant", "evaluateTermination(cycleData, 20, // REVIEW_CYCLE_CAPS.high\n    )"],
    ["spread", "evaluateTermination(...([cycleData, 20] as any))"],
  ];
  for (const [label, replacement] of variants) {
    const mutated = INDEX_SRC.replace("evaluateTermination(cycleData)", replacement);
    // Anchor on the REAL call text: if index.ts's call moves, this control says
    // so instead of failing with a misleading "must be caught" (cycle-4).
    ok(mutated !== INDEX_SRC, `control "${label}" did not apply — index.ts's call text moved; update this control`);
    ok(liveCallShapeViolations(mutated).length > 0, `"${label}" must be caught`);
  }
});

test("tripwire control: legitimate refactors still pass", () => {
  const legitimate: Array<[string, string]> = [
    ["trailing comma", "evaluateTermination(\n  cycleData,\n)"],
    ["hoisted identifier", "evaluateTermination(d)"],
    ["nested comma inside a call", "evaluateTermination(cycleData.slice(0, 10))"],
    ["chained map with a comma", "evaluateTermination(cycleData.map((c, i) => c))"],
  ];
  for (const [label, replacement] of legitimate) {
    const mutated = INDEX_SRC.replace("evaluateTermination(cycleData)", replacement);
    ok(mutated !== INDEX_SRC, `control "${label}" did not apply — update this control`);
    deepEqual(liveCallShapeViolations(mutated), [], `"${label}" is a legitimate refactor`);
  }
});

test("rejects a non-numeric Reviewers cell (same strictness as Max Cycles)", () => {
  const bogus = MARKDOWN.replace(
    "| Low-Medium (small plan, existing patterns) | 2 reviewers (Structural + Integration) | 3 |",
    "| Low-Medium (small plan, existing patterns) | many reviewers | 3 |",
  );
  ok(bogus !== MARKDOWN, "control did not apply — the Low-Medium row text moved; update this control");
  let threw = false;
  try {
    parseReviewCycleTable(bogus);
  } catch {
    threw = true;
  }
  ok(threw, "a non-numeric Reviewers cell must throw, not coerce to 0");
});

test("rejects a non-numeric, non-skip Max Cycles cell (no silent 0)", () => {
  const bogus = MARKDOWN.replace("| Low | 0 (skip review) | — |", "| Low | 0 (skip review) | unlimited |");
  ok(bogus !== MARKDOWN, "control did not apply — the Low row text moved; update this control");
  let threw = false;
  try {
    parseReviewCycleTable(bogus);
  } catch {
    threw = true;
  }
  ok(threw, "a bogus Max Cycles cell must throw, not coerce to 0");
});

test("REVIEW_CYCLE_CAPS declares exactly the canonical keys", () => {
  // Without this, an unbacked extra key rides along unnoticed (it is never
  // read by TIER_CONFIG) and — before the ceiling fix — would have raised the
  // governance max the guard compares against.
  deepEqual(Object.keys(REVIEW_CYCLE_CAPS).sort(), ["high", "lowMedium", "mediumHigh", "skip"]);
  deepEqual(
    Object.keys(REVIEW_CYCLE_CAPS).length,
    TABLE.length,
    "one REVIEW_CYCLE_CAPS entry per canonical risk row",
  );
});

// ── Negative controls: the check must actually reject drift ─────────────────

section("Negative controls (the guard is not vacuous)");

test("rejects a cap above the canonical bound for its reviewer count (#723's original shape)", () => {
  const drifted = { ...TIERS, complex: { maxCycles: 20, reviewers: 4 } };
  const v = mappingViolations(CAPS, drifted, TABLE);
  ok(v.length > 0, "20 against the High row must be rejected");
  ok(v.some((s) => s.includes("complex") && s.includes("20")), `expected a complex/20 violation, got: ${v.join(" | ")}`);
});

test("rejects REVIEW_CYCLE_CAPS drifting from the table (pre-#705 stale 8)", () => {
  const v = mappingViolations({ ...CAPS, high: 8 }, TIERS, TABLE);
  ok(v.some((s) => s.includes("REVIEW_CYCLE_CAPS.high")), `expected a caps violation, got: ${v.join(" | ")}`);
  // The governance ceiling is computed from the TABLE (canonical), so a
  // caps-only mutation does NOT trip it — it trips the caps↔table check. The
  // ceiling branch has its own control below.
  ok(
    !v.some((s) => s.includes("governance maximum")),
    `caps-only drift must not be reported as a ceiling breach, got: ${v.join(" | ")}`,
  );
});

test("rejects a tier above the table-derived governance ceiling", () => {
  // Lower the CANONICAL table (High 10 -> 5) and keep the runtime tier at 10:
  // now the ceiling branch is the one that must fire.
  const lowered = TABLE.map((r) => (r.risk === "High" ? { ...r, maxCycles: 5 } : r));
  const v = mappingViolations(CAPS, TIERS, lowered);
  ok(
    v.some((s) => s.includes("exceeds the governance maximum 5")),
    `expected a governance-ceiling violation, got: ${v.join(" | ")}`,
  );
});

test("LIMIT: a coordinated re-point passes the pair check (why the fixture pin exists)", () => {
  // Documents the pair check's blind spot rather than pretending it has none:
  // moving `standard` to the Medium-High row keeps every pair canonical, so
  // only the explicit TIER_CONFIG fixture pin above catches it.
  const repointed = { ...TIERS, standard: { maxCycles: 5, reviewers: 3 } };
  deepEqual(
    mappingViolations(CAPS, repointed, TABLE),
    [],
    "the pair check alone is expected to accept this — the fixture pin is the real guard",
  );
});

test("rejects a reviewer count with no canonical row", () => {
  const v = mappingViolations(CAPS, { ...TIERS, standard: { maxCycles: 5, reviewers: 7 } }, TABLE);
  ok(v.some((s) => s.includes("standard") && s.includes("no canonical risk row")), `expected a no-row violation, got: ${v.join(" | ")}`);
});

test("rejects when the canonical table loses a row (parser is bound to content)", () => {
  // Anchor on the CAPS label, not on a tier name: a legitimate re-point of
  // `standard` to another row would otherwise make this control fail for an
  // unrelated reason (cycle-5 review).
  const v = mappingViolations(CAPS, TIERS, TABLE.filter((r) => r.reviewers !== 2));
  ok(
    v.some((s) => s.includes("REVIEW_CYCLE_CAPS.lowMedium")),
    `expected REVIEW_CYCLE_CAPS.lowMedium to be unbacked, got: ${v.join(" | ")}`,
  );
});

test("throws when the canonical table disappears", () => {
  let threw = false;
  try {
    parseReviewCycleTable("# Proportional Gates\n\nno review-cycles section here\n");
  } catch {
    threw = true;
  }
  ok(threw, "a missing canonical table must throw, not return []");
});

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed > 0 ? 1 : 0);
