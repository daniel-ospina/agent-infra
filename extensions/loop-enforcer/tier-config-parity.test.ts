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

import { REVIEW_CYCLE_CAPS, TIER_CONFIG } from "./termination.ts";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(HERE, "..", "..");
const SKILL_PATH = join(REPO_ROOT, "skills", "proportional-gates", "SKILL.md");

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
    const reviewers = Number((cells[1].match(/\d+/) || ["0"])[0]);
    // "—" (review skipped) parses as 0; anything else must be a plain integer.
    const maxCycles = /^\d+$/.test(cells[2]) ? Number(cells[2]) : 0;
    rows.push({ risk: cells[0].replace(/\s*\(.*\)\s*$/, ""), reviewers, maxCycles });
  }
  if (rows.length === 0) {
    throw new Error(`${SKILL_PATH}: "### Review Cycles" present but no table row parsed`);
  }
  return rows;
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
  // actual defect — complex at 20 against a max of 10).
  const governanceMax = Math.max(...Object.values(caps));
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
  ok(v.some((s) => s.includes("TIER_CONFIG.complex")), `expected the tier check to fire too, got: ${v.join(" | ")}`);
});

test("rejects a reviewer count with no canonical row", () => {
  const v = mappingViolations(CAPS, { ...TIERS, standard: { maxCycles: 5, reviewers: 7 } }, TABLE);
  ok(v.some((s) => s.includes("standard") && s.includes("no canonical risk row")), `expected a no-row violation, got: ${v.join(" | ")}`);
});

test("rejects when the canonical table loses a row (parser is bound to content)", () => {
  const v = mappingViolations(CAPS, TIERS, TABLE.filter((r) => r.reviewers !== 2));
  ok(v.some((s) => s.includes("standard")), `expected standard to be unbacked, got: ${v.join(" | ")}`);
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
