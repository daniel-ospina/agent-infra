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
 * WIRING HONESTY: this suite runs in the per-PR `verify` job (VISIBLE, not
 * merge-blocking — the repo's only required check is `pipeline-compliance`)
 * and in the post-merge ci-main.yml `extension-tests` job (the blocking
 * backstop, same split as the other extension suites).
 *
 * Run: npx tsx extensions/loop-enforcer/tier-config-parity.test.ts
 */

import { readFileSync } from "node:fs";
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
 * LIMIT (stated, not hidden): this is textual. A deliberately obfuscated form
 * (optional call `f?.(...)`, aliasing `f` and calling the alias, `f.call(...)`)
 * would evade it. Those require contrived code that a reviewer sees in the
 * diff; the tripwire is aimed at an ordinary re-added bound or `tier`.
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
  // Cycle-1 review caught the earlier version of this test for asserting the
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
  // TEXTUAL TRIPWIRE, not a proof: index.ts is a pi extension with
  // module-level side effects, so its call site cannot be exercised from here.
  // The rule is "exactly one argument, no spread". It rejects the re-add forms
  // listed below (NOT "every" conceivable form — a deliberately obfuscated
  // call evades it; see the LIMIT note on liveCallShapeViolations), while
  // accepting a hoisted identifier:
  //   evaluateTermination(cycleData, 20)                            -> 2 args
  //   evaluateTermination(cycleData, 20, // REVIEW_CYCLE_CAPS.high) -> 2 args (comment swallows the ')')
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
