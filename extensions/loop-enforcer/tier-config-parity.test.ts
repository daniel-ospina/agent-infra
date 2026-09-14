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
 * The fixer-loop fence itself is pinned by `l1FenceViolations()` as EXACT TEXT
 * (one approved canonical string, present once). The earlier execution harness —
 * run the markdown in bash, parse its stdout — was removed after three review
 * cycles each found a fresh way to forge the observation (see the
 * `CANONICAL_L1_FENCE` docblock). There is no observation channel left to
 * forge, so the class is closed structurally rather than patched a fourth time.
 *
 * WIRING HONESTY: this suite runs in the per-PR `verify` job (VISIBLE, not
 * merge-blocking — the repo's only required check is `pipeline-compliance`)
 * and in the post-merge ci-main.yml `extension-tests` job (the blocking
 * backstop, same split as the other extension suites).
 *
 * #847 extends the same suite to the stall threshold. `STALL_THRESHOLD` in
 * `termination.ts` is a MIRROR of the skills' `stall_threshold` default, so
 * `stallThresholdViolations()` parses every declared default out of the live
 * skill tree and fails on a divergent value, a de-listed surface, or an
 * undeclared one (the #723 rule applies to this constant too). The predicate
 * it configures was made faithful FIRST — pinning 0.8 while the detector
 * reduced to a boolean would have certified decoration.
 *
 * Run: npx tsx extensions/loop-enforcer/tier-config-parity.test.ts
 */

import { readFileSync, readdirSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { ok, equal, deepEqual } from "node:assert/strict";

import { evaluateTermination, REVIEW_CYCLE_CAPS, STALL_THRESHOLD, TIER_CONFIG, type CycleData } from "./termination.ts";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(HERE, "..", "..");
const SKILL_PATH = join(REPO_ROOT, "skills", "proportional-gates", "SKILL.md");
const INDEX_SRC = readFileSync(join(HERE, "index.ts"), "utf-8");

/** Minimal cycle factory for the behavioural live-cap assertions. */
function cycle(n: number, issues: number, verdict = "NEEDS_FIX", fingerprints?: string[], issuesFixed = 0): CycleData {
  return { cycleNumber: n, issuesFound: issues, issuesFixed, verdict, fingerprints, filesChanged: 0, wallClockMs: 0 };
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
  /** Max Cycles cell; the Low row's em-dash means "no re-review cycles" → 0. */
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

  check("REVIEW_CYCLE_CAPS.skip", caps.skip, 1);
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

/**
 * The declared subject set — the eight surfaces the plan doc (§2.1) says carry
 * the adversarial bound. Deliberately duplicated from `ADVERSARIAL_SURFACES`
 * (same pattern as `CANONICAL_NON_ADVERSARIAL`): the map actually checked is
 * derived from `ADVERSARIAL_SURFACES`, so if a surface silently drops out of
 * *that* list the positive test stays green with one fewer subject and the
 * de-listed surface may drift to any cap (#894, class 9). Set-equality between
 * the two is the guard.
 */
export const DECLARED_ADVERSARIAL_SURFACES: readonly string[] = [
  "AGENTS.md",
  "templates/AGENTS.base.md",
  "skills/proportional-gates/SKILL.md",
  "skills/code-review/SKILL.md",
  "skills/code-review/references/fixer-loop.md",
  "skills/plan-review/SKILL.md",
  "skills/issue-scoping/SKILL.md",
  "skills/task-workflow-standard/SKILL.md",
];

/**
 * Set-equality violations between the checked surface set and the declared
 * one; `[]` means they agree exactly. Pure, so the negative controls below can
 * prove a shrunken set goes red rather than merely never firing.
 */
export function subjectSetViolations(
  checked: readonly string[],
  declared: readonly string[],
): string[] {
  const violations: string[] = [];
  const checkedSet = new Set(checked);
  const declaredSet = new Set(declared);
  for (const p of declaredSet) {
    if (!checkedSet.has(p)) violations.push(`declared adversarial surface "${p}" is not checked`);
  }
  for (const p of checkedSet) {
    if (!declaredSet.has(p)) violations.push(`checked adversarial surface "${p}" is not declared`);
  }
  return violations;
}

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
  // Fail closed on an empty subject set: iterating an empty map would return
  // `[]` — a vacuous pass that reads exactly like "every surface agrees"
  // (#894, class 9). An absent subject is a violation, never a silent pass.
  if (Object.keys(sources).length === 0) {
    return ["no adversarial surfaces checked — an empty source set cannot satisfy the pin"];
  }
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
 * #838 — the ONE approved L1 fixer-loop fence, byte-for-byte.
 *
 * The decisive simplification: this pin is EXACT TEXT. Earlier revisions tried
 * to *observe* the fence by executing the markdown in bash and parsing its
 * stdout — first-match, then last-match, then behind a statement allowlist.
 * Three review cycles found three holes, all of the same family ("pin vacuity",
 * threat class 5):
 *
 *   1. `printf "BOUND=%d\n" 2` forged the marker a first-match regex read
 *      (37/0 green while the real loop executed the 10-cycle cap).
 *   2. The sentinel + last-match fix fell to shadowed `command`/`[`/`builtin`/
 *      `printf`.
 *   3. The allowlist fix fell to an allowlist-clean DECOY block placed earlier:
 *      the selector bound to the first matching block while the aggregator
 *      summed every block, so the real fence was never checked and never
 *      executed — the pin returned `[]` while the fence executed `BOUND=20`.
 *
 * Executing attacker-influenceable text and parsing its output is what made
 * every one of those forgeries possible, so the observation channel is GONE:
 * no bash execution, no stdout parsing, no regex extraction of the bound. The
 * doc must contain this one block, exactly once. Any edit to it — a commented-out
 * branch, `BOUND=10` → `100`, a forged marker — changes the text and fails the
 * pin, and there is nothing left to forge. The harness (`execFileSync`,
 * `BOUND_SENTINEL`, the statement allowlist, the last-match read) is deleted, not
 * kept as dead weight. What this does NOT claim is stated in the LIMIT below:
 * it polices the approved block and the guard's reachability, not arbitrary
 * extra prose elsewhere in the document.
 */
export const CANONICAL_L1_FENCE = [
  "CYCLE=$((CYCLE + 1))",
  '# 10 = the convergence-gated safety cap (SKILL.md "Safety cap at 10 cycles");',
  '# 2 = the adversarial-domain bound (#838, SKILL.md "Adversarial domain — declared',
  '# threat surface"), set ADVERSARIAL_BOUND=1 from the scoping declaration.',
  "# adversarial-bound: cap=2",
  "BOUND=10",
  'if [ "${ADVERSARIAL_BOUND:-0}" = "1" ]; then BOUND=2; fi',
  "if [ $CYCLE -gt $BOUND ]; then",
  '  if [ "${ADVERSARIAL_BOUND:-0}" = "1" ]; then EXIT_REASON="adversarial-capped"; else EXIT_REASON="cycle-cap"; fi',
  "  break",
  "fi",
  `PR_STATE=$(gh pr view $PR_NUMBER --json state --jq '.state' 2>/dev/null || echo "UNKNOWN")`,
  'if [ "$PR_STATE" != "OPEN" ]; then EXIT_REASON="pr-closed"; break; fi',
].join("\n");

/** The `### L1` heading the approved block must be the only instance of. */
const L1_HEADING = "### L1 — Exit conditions";

/** Identifier characters — a word char before `BOUND=` means the token is part of a longer identifier. */
const WORD_CHARS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_";

/** Count occurrences of `token` not preceded by an identifier character. */
function countBareToken(text: string, token: string): number {
  let count = 0;
  let idx = text.indexOf(token);
  while (idx !== -1) {
    const prev = idx > 0 ? text[idx - 1] : "\n";
    if (!WORD_CHARS.includes(prev)) count++;
    idx = text.indexOf(token, idx + 1);
  }
  return count;
}

/**
 * The approved L1 block: its heading, its fences, and the fence body verbatim.
 * Anchoring on the heading too (still pure string concatenation — no parsing) is
 * what keeps `CANONICAL_L1_FENCE` pinned to the `### L1` section: the fence body
 * moved anywhere else stops matching.
 */
export const CANONICAL_L1_BLOCK =
  "### L1 — Exit conditions\n```bash\n" + CANONICAL_L1_FENCE + "\n```";

/**
 * The one approved pre-loop guard-variable setup line, byte-for-byte. The
 * adversarial branch is `[ "${ADVERSARIAL_BOUND:-0}" = "1" ]`, so this line is
 * what makes it reachable at all.
 */
export const ADVERSARIAL_GUARD_SETUP = "ADVERSARIAL_BOUND=${ADVERSARIAL_BOUND:-0}";

/** Count bare `BOUND=<...>` assignments in `text` (identifier-prefixed forms like `ADVERSARIAL_BOUND=` do not count). */
function countBoundAssignments(text: string): number {
  return countBareToken(text, "BOUND=");
}

/**
 * Violations of the exact-text L1 pin; `[]` means the doc carries the approved
 * L1 block verbatim, exactly once, carries exactly one `### L1` heading, and
 * nothing else in the doc assigns `BOUND`.
 *
 * Three structural conditions, all properties of the text itself — no execution
 * and no parsed observation to forge:
 *
 *   1. `CANONICAL_L1_BLOCK` occurs exactly once. A commented-out variant, a
 *      `BOUND=10` → `100` substitution, or a rewritten branch all fail here.
 *   2. The `### L1` heading occurs exactly once — a second L1-shaped section a
 *      fixer could copy instead (the cycle-3 decoy, however its body is spelt)
 *      fails here.
 *   3. No `BOUND=` assignment survives OUTSIDE the approved block. The two
 *      checks are symmetric, so no selector/aggregator asymmetry remains.
 *
 * LIMIT (stated, not hidden): this binds the ONE approved block, its heading,
 * and other `BOUND=` assignments. It does not prove an executing agent ran this
 * text, and it does not scan arbitrary extra prose for a bound computed under
 * some other spelling/variable. Those are documentation-completeness concerns;
 * the class this guard exists to close is pin VACUITY — a pin that observes a
 * forgery.
 */
export function l1FenceViolations(md: string): string[] {
  const violations: string[] = [];
  const occurrences = md.split(CANONICAL_L1_BLOCK).length - 1;
  if (occurrences !== 1) {
    violations.push(
      `fixer-loop: the approved L1 block must appear exactly once, byte-for-byte; found ${occurrences}`,
    );
  }
  const headings = md.split(L1_HEADING).length - 1;
  if (headings !== 1) {
    violations.push(`fixer-loop: expected exactly one \`${L1_HEADING}\` heading, found ${headings}`);
  }
  const outside = md.split(CANONICAL_L1_BLOCK).join("");
  const stray = countBoundAssignments(outside);
  if (stray > 0) {
    violations.push(
      `fixer-loop: ${stray} \`BOUND=\` assignment(s) outside the approved L1 block — a decoy the fixer could copy instead`,
    );
  }
  return violations;
}

/**
 * Reachability of the adversarial branch: the guard variable must be defined by
 * exactly the approved setup line and never touched anywhere else.
 *
 * This restores the layer the deleted execution harness's
 * `adversarialBoundAssignments()` provided — the cycle-3 guard-neutering finding —
 * as EXACT TEXT instead of a scan over extracted fenced blocks. A pre-loop
 * `ADVERSARIAL_BOUND=0` left the canonical L1 fence byte-identical, so the
 * suite stayed 39/0 green while the doc executed the general 10-cycle cap
 * (cycle-1 review). `export ADVERSARIAL_BOUND=0`, `unset ADVERSARIAL_BOUND`,
 * `printf -v ADVERSARIAL_BOUND '%d' 0`, … all leave the branch unreachable and
 * are caught here.
 */
export function adversarialReachabilityViolations(md: string): string[] {
  const violations: string[] = [];
  const setup = md.split(ADVERSARIAL_GUARD_SETUP).length - 1;
  if (setup !== 1) {
    violations.push(
      `fixer-loop: the approved guard setup \`${ADVERSARIAL_GUARD_SETUP}\` must appear exactly once; found ${setup}`,
    );
  }
  const remainder = md.split(CANONICAL_L1_BLOCK).join("").split(ADVERSARIAL_GUARD_SETUP).join("");
  const extra = countBareToken(remainder, "ADVERSARIAL_BOUND");
  if (extra > 0) {
    violations.push(
      `fixer-loop: ${extra} extra \`ADVERSARIAL_BOUND\` reference(s) outside the approved block and setup line — the guard can be neutered`,
    );
  }
  return violations;
}

/**
 * Self-consistency of the approved constant with the declared cap. Separate from
 * `l1FenceViolations` so the constant's own linkage to `ADVERSARIAL_CAP` (and
 * the `adversarial-capped` exit) is asserted directly: moving the cap without
 * moving the fence fails here even before the doc is read.
 */
export function canonicalFenceSelfViolations(fence: string = CANONICAL_L1_FENCE): string[] {
  const violations: string[] = [];
  if (!fence.includes(`then BOUND=${ADVERSARIAL_CAP}; fi`)) {
    violations.push(
      `the approved L1 fence does not set the adversarial branch to the declared cap ${ADVERSARIAL_CAP}`,
    );
  }
  if (!fence.includes("\nBOUND=10\n")) {
    violations.push("the approved L1 fence no longer carries the 10-cycle general default on its own line");
  }
  if (!fence.includes('EXIT_REASON="adversarial-capped"')) {
    violations.push("the approved L1 fence no longer records the bounded exit as `adversarial-capped`");
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
      ["Low", 1, 0],
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

test("the checked subject set is exactly the declared eight (#894 class 9)", () => {
  // Pin both forms: the literal set-equality the reviewer prescribed, and the
  // pure predicate the negative controls exercise.
  deepEqual(
    [...ADVERSARIAL_SURFACES].sort(),
    [...DECLARED_ADVERSARIAL_SURFACES].sort(),
    "ADVERSARIAL_SURFACES drifted from the declared eight — a surface was silently added or dropped",
  );
  deepEqual(
    subjectSetViolations(ADVERSARIAL_SURFACES, DECLARED_ADVERSARIAL_SURFACES),
    [],
    `subject set drifted: ${subjectSetViolations(ADVERSARIAL_SURFACES, DECLARED_ADVERSARIAL_SURFACES).join(" | ")}`,
  );
});

test("rejects a shrunk subject set — de-listing a surface no longer passes vacuously (#894)", () => {
  const dropped = "skills/plan-review/SKILL.md";
  const shrunken = ADVERSARIAL_SURFACES.filter((p) => p !== dropped);
  // Document the residual hole this pin exists to close: the shrunk map alone
  // still satisfies the anchor parity check (all remaining anchors agree at 2).
  const shrunkenSources = Object.fromEntries(
    shrunken.map((p) => [p, readFileSync(join(REPO_ROOT, p), "utf-8")]),
  );
  deepEqual(
    adversarialBoundViolations(shrunkenSources),
    [],
    "expected the shrunk map alone to look clean — that vacuity is what the subject-set pin must catch",
  );
  const v = subjectSetViolations(shrunken, DECLARED_ADVERSARIAL_SURFACES);
  ok(
    v.some((s) => s.includes(dropped) && s.includes("is not checked")),
    `expected a de-listed-surface violation for ${dropped}, got: ${v.join(" | ")}`,
  );
});

test("rejects an empty source set — adversarialBoundViolations({}) fails closed (#894)", () => {
  const v = adversarialBoundViolations({});
  ok(v.length > 0, "an empty subject set must be a violation, not a vacuous []");
  ok(
    v.some((s) => s.includes("empty source set")),
    `expected an empty-source-set violation, got: ${v.join(" | ")}`,
  );
});

test("#838 does not re-cap non-adversarial work (3 / 5 / 10 intact)", () => {
  deepEqual(
    nonAdversarialCapViolations(TABLE),
    [],
    `non-adversarial caps moved: ${nonAdversarialCapViolations(TABLE).join(" | ")}`,
  );
});

const FIXER_LOOP_PATH = "skills/code-review/references/fixer-loop.md";
const FENCE_SRC = ADVERSARIAL_SOURCES[FIXER_LOOP_PATH];

test("the approved L1 fence is present verbatim, exactly once", () => {
  deepEqual(l1FenceViolations(FENCE_SRC), [], `L1 fence drifted: ${l1FenceViolations(FENCE_SRC).join(" | ")}`);
});

test("the approved L1 fence is self-consistent with the declared cap", () => {
  deepEqual(
    canonicalFenceSelfViolations(),
    [],
    `canonical fence ↔ cap drift: ${canonicalFenceSelfViolations().join(" | ")}`,
  );
});

test("the pre-loop setup defines ADVERSARIAL_BOUND exactly once, never reassigned", () => {
  deepEqual(
    adversarialReachabilityViolations(FENCE_SRC),
    [],
    `adversarial reachability drifted: ${adversarialReachabilityViolations(FENCE_SRC).join(" | ")}`,
  );
});

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

test("rejects an ADDED undeclared surface (subject set is capped, not just floored)", () => {
  const v = subjectSetViolations(
    [...ADVERSARIAL_SURFACES, "docs/extra.md"],
    DECLARED_ADVERSARIAL_SURFACES,
  );
  ok(
    v.some((s) => s.includes("docs/extra.md") && s.includes("is not declared")),
    `expected an undeclared-surface violation, got: ${v.join(" | ")}`,
  );
});

// Negative controls — every shape the deleted execution harness was defeated
// by. Each mutates the REAL doc and asserts the exact-text pin goes red, so the
// forgery class is closed structurally rather than by a fourth hardening.

test("rejects a COMMENTED-OUT adversarial branch (cycle-2 counterexample)", () => {
  const commented = FENCE_SRC.replace(
    'if [ "${ADVERSARIAL_BOUND:-0}" = "1" ]; then BOUND=2; fi',
    '# if [ "${ADVERSARIAL_BOUND:-0}" = "1" ]; then BOUND=2; fi',
  );
  ok(commented !== FENCE_SRC, "control did not apply — the adversarial branch was not found");
  ok(l1FenceViolations(commented).length > 0, "a commented-out branch must fail the exact-text pin");
});

test("rejects `BOUND=10` → `BOUND=100` (the old `includes('BOUND=10')` substring hole)", () => {
  const bumped = FENCE_SRC.replace("\nBOUND=10\n", "\nBOUND=100\n");
  ok(bumped !== FENCE_SRC, "control did not apply — the `BOUND=10` default was not found");
  ok(
    bumped.includes("BOUND=10"),
    "`BOUND=100` contains `BOUND=10` — the old substring check stayed green; that is the residual",
  );
  ok(l1FenceViolations(bumped).length > 0, "a bumped default must fail the exact-text pin");
});

test("rejects a DECOY block placed earlier (cycle-3 counterexample)", () => {
  // Allowlist-clean decoy: under the deleted first-match selector this block
  // became "the fence" while the real one went unchecked. The stray-assignment
  // condition is symmetric with the exact-once condition, so it cannot hide.
  const decoy =
    "```bash\n" +
    "BOUND=2\n" +
    'if [ "${ADVERSARIAL_BOUND:-0}" = "1" ]; then BOUND=2; fi\n' +
    "```\n\n";
  const withDecoy = decoy + FENCE_SRC;
  const v = l1FenceViolations(withDecoy);
  ok(
    v.some((s) => s.includes("outside the approved L1 block")),
    `expected a stray-assignment violation, got: ${v.join(" | ")}`,
  );
});

test("rejects a FORGED stdout marker inside the fence (cycle-2 counterexample)", () => {
  const forged = FENCE_SRC.replace(
    'if [ "${ADVERSARIAL_BOUND:-0}" = "1" ]; then BOUND=2; fi',
    'if [ "${ADVERSARIAL_BOUND:-0}" = "1" ]; then BOUND=2; fi\n' +
      '[ "${ADVERSARIAL_BOUND:-0}" = "1" ] && { (( BOUND = 10 )); printf "BOUND=%d\\n" 2; }',
  );
  ok(forged !== FENCE_SRC, "control did not apply — the adversarial branch was not found");
  ok(l1FenceViolations(forged).length > 0, "a forged marker line must fail the exact-text pin");
});

test("rejects a neutered guard variable (`ADVERSARIAL_BOUND=0` injected — cycle-3 counterexample)", () => {
  const neutered = FENCE_SRC.replace("\nBOUND=10\n", "\nADVERSARIAL_BOUND=0\nBOUND=10\n");
  ok(neutered !== FENCE_SRC, "control did not apply — the `BOUND=10` default was not found");
  ok(l1FenceViolations(neutered).length > 0, "an injected guard reassignment must fail the exact-text pin");
});

test("rejects a PRE-LOOP guard neutering that leaves the L1 block byte-identical (cycle-1 regression)", () => {
  // The deleted harness's `adversarialBoundAssignments()` caught this. It is
  // the regression this control pins: the canonical L1 block is untouched, so
  // only the reachability check can see it.
  const neutered = FENCE_SRC.replace(
    ADVERSARIAL_GUARD_SETUP,
    `${ADVERSARIAL_GUARD_SETUP}\nADVERSARIAL_BOUND=0`,
  );
  ok(neutered !== FENCE_SRC, "control did not apply — the guard setup line was not found");
  deepEqual(
    l1FenceViolations(neutered),
    l1FenceViolations(FENCE_SRC),
    "the pre-loop injection must not change the L1 pin (reachability is the only layer that can see it)",
  );
  ok(
    adversarialReachabilityViolations(neutered).length > 0,
    "an extra pre-loop ADVERSARIAL_BOUND assignment must be a violation",
  );
});

test("rejects other pre-loop guard neutering spellings (`export` / `unset` / `printf -v`)", () => {
  const spellings = [
    "export ADVERSARIAL_BOUND=0",
    "ADVERSARIAL_BOUND=",
    "unset ADVERSARIAL_BOUND",
    'printf -v ADVERSARIAL_BOUND "%d" 0',
  ];
  for (const line of spellings) {
    const neutered = FENCE_SRC.replace(ADVERSARIAL_GUARD_SETUP, `${ADVERSARIAL_GUARD_SETUP}\n${line}`);
    ok(neutered !== FENCE_SRC, `control did not apply for: ${line}`);
    ok(
      adversarialReachabilityViolations(neutered).length > 0,
      `\`${line}\` must fail the reachability check`,
    );
  }
});

test("rejects a second L1-shaped section a fixer could copy (renamed-heading decoy, cycle-1)", () => {
  // The decoy bound is spelt without a `BOUND=` token, so only the heading
  // count can see it. `### L1 — Exit conditions (ACTIVE)` still contains the
  // exact heading substring, so it counts as a second heading.
  const decoy =
    "### L1 — Exit conditions (ACTIVE — use this one)\n```bash\nCAP=20\n```\n\n";
  const v = l1FenceViolations(decoy + FENCE_SRC);
  ok(
    v.some((s) => s.includes("heading")),
    `expected a duplicate-heading violation, got: ${v.join(" | ")}`,
  );
});

test("rejects an unconditional adversarial branch (guard removed)", () => {
  const unconditional = FENCE_SRC.replace(
    'if [ "${ADVERSARIAL_BOUND:-0}" = "1" ]; then BOUND=2; fi',
    "if true; then BOUND=2; fi",
  );
  ok(unconditional !== FENCE_SRC, "control did not apply — the adversarial branch was not found");
  ok(l1FenceViolations(unconditional).length > 0, "a rewritten guard must fail the exact-text pin");
});

test("rejects the approved fence moved out of the `### L1` section (heading anchor)", () => {
  // Anchor the mutation on the canonical block itself so the control cannot
  // rewrite some other occurrence (cycle-1 review: a decoy earlier in the doc
  // made the old `.replace` hit the wrong heading).
  const moved = FENCE_SRC.replace(
    CANONICAL_L1_BLOCK,
    CANONICAL_L1_BLOCK.replace("### L1 — Exit conditions", "### L1b — relocated"),
  );
  ok(moved !== FENCE_SRC, "control did not apply — the canonical L1 block was not found");
  ok(l1FenceViolations(moved).length > 0, "a relocated fence must fail the exact-text pin");
});

test("the exact-text pin is not vacuous: an empty / unrelated doc is rejected", () => {
  ok(l1FenceViolations("").length > 0, "an absent fence must be a violation, never a silent pass");
  ok(
    l1FenceViolations("# Fixer Loop\n\nno L1 fence here\n").length > 0,
    "a doc without the approved fence must be a violation",
  );
});

// ── The runtime mapping ─────────────────────────────────────────────────────

section("Stall-threshold parity (#847)");

/**
 * The stall-detector surfaces that declare a numeric `stall_threshold`
 * default. `STALL_THRESHOLD` in `termination.ts` is a MIRROR of these, not the
 * source, so drift BETWEEN them is the failure pinned here — the same class
 * #723 caught for the runtime tiers ("a comment is not a guard").
 *
 * The anchor is the value itself rather than a marker comment: every surface
 * writes a numeric default, so one scan both (a) proves each declared default
 * equals the runtime constant and (b) proves no surface was added or de-listed
 * silently. `ARCHIVE-*` paths are excluded deliberately — an archived skill is
 * a historical record, not a live statement of the rule.
 *
 * Ordering note (#847 review): a parity pin is only worth having once the
 * predicate it configures is faithful. Pinning 0.8 while the detector reduced
 * to a boolean would have certified decoration; the predicate was fixed first.
 */
export const STALL_THRESHOLD_SURFACES: readonly string[] = [
  "skills/carousel-designer/SKILL.md",
  "skills/code-review/SKILL.md",
  "skills/code-review/references/fixer-loop.md",
  "skills/issue-scoping/SKILL.md",
  "skills/plan-review/SKILL.md",
  "skills/test-review/SKILL.md",
  "skills/verification-before-completion/SKILL.md",
];

/**
 * Every `stall_threshold` occurrence followed by a numeric default, as
 * `{path, value}`. Deliberately over-inclusive: a match that captures the
 * WRONG number in a sentence fails the value assertion loudly rather than
 * passing quietly, which is the safe direction for a drift guard.
 */
export function stallThresholdDeclarations(
  files: ReadonlyArray<{ path: string; markdown: string }>,
): Array<{ path: string; value: string }> {
  const out: Array<{ path: string; value: string }> = [];
  for (const file of files) {
    const re = /`?stall_threshold`?/gi;
    let m: RegExpExecArray | null;
    while ((m = re.exec(file.markdown)) !== null) {
      const window = file.markdown.slice(m.index + m[0].length, m.index + m[0].length + 120);
      const numeric = window.match(/(\d+\.\d+)/);
      if (numeric) out.push({ path: file.path, value: numeric[1] });
    }
  }
  return out;
}

/**
 * Violations of the stall-threshold contract: a declared default that differs
 * from `STALL_THRESHOLD`, a declared surface that stopped declaring, an
 * undeclared surface that started, or a scan that found nothing at all (the
 * vacuity hole). An empty array is the only clean result.
 */
export function stallThresholdViolations(
  files: ReadonlyArray<{ path: string; markdown: string }>,
): string[] {
  const declarations = stallThresholdDeclarations(files);
  const violations: string[] = [];
  for (const d of declarations) {
    if (Number(d.value) !== STALL_THRESHOLD) {
      violations.push(`${d.path}: declares stall_threshold ${d.value}, runtime STALL_THRESHOLD is ${STALL_THRESHOLD}`);
    }
  }
  const declaring = new Set(declarations.map((d) => d.path));
  for (const path of STALL_THRESHOLD_SURFACES) {
    if (!declaring.has(path)) {
      violations.push(`${path}: no numeric stall_threshold default found (de-listed, or the declaration was removed)`);
    }
  }
  for (const path of declaring) {
    if (!STALL_THRESHOLD_SURFACES.includes(path)) {
      violations.push(`${path}: declares a stall_threshold default but is not in STALL_THRESHOLD_SURFACES`);
    }
  }
  if (declarations.length === 0) {
    violations.push("no stall_threshold declaration found anywhere — the scan is vacuous");
  }
  return violations;
}

/** Every live skill markdown, minus the archive. */
function skillMarkdownFiles(): Array<{ path: string; markdown: string }> {
  const skillsRoot = join(REPO_ROOT, "skills");
  return (readdirSync(skillsRoot, { recursive: true }) as string[])
    .map((rel) => rel.replace(/\\/g, "/"))
    .filter((rel) => rel.endsWith(".md"))
    .filter((rel) => !rel.split("/").some((seg) => seg.startsWith("ARCHIVE")))
    .sort()
    .map((rel) => ({ path: `skills/${rel}`, markdown: readFileSync(join(skillsRoot, rel), "utf-8") }));
}

test("every declared stall_threshold equals the runtime constant, and the surface set is exact", () => {
  const files = skillMarkdownFiles();
  const declarations = stallThresholdDeclarations(files);
  ok(declarations.length >= STALL_THRESHOLD_SURFACES.length, `expected a declaration per surface, found ${declarations.length}`);
  deepEqual(stallThresholdViolations(files), [], "the live skill tree must agree with STALL_THRESHOLD");
});

test("rejects a divergent declared default (the drift this pins)", () => {
  const v = stallThresholdViolations([
    { path: "skills/plan-review/SKILL.md", markdown: "recurrence ≥ `stall_threshold` (default `0.9`) → escalate" },
  ]);
  ok(v.some((s) => s.includes("0.9")), `expected a value violation, got: ${v.join(" | ")}`);
});

test("rejects a surface that stopped declaring a numeric default", () => {
  const files = skillMarkdownFiles().filter((f) => f.path !== "skills/plan-review/SKILL.md");
  const v = stallThresholdViolations(files);
  ok(
    v.some((s) => s.startsWith("skills/plan-review/SKILL.md")),
    `expected the de-listed surface to be reported, got: ${v.join(" | ")}`,
  );
});

test("rejects an undeclared surface that starts declaring", () => {
  const v = stallThresholdViolations([
    { path: "skills/brand-new/SKILL.md", markdown: "`stall_threshold` defaults to `0.8`" },
  ]);
  ok(v.some((s) => s.includes("brand-new") && s.includes("not in STALL_THRESHOLD_SURFACES")), `expected an undeclared-surface violation, got: ${v.join(" | ")}`);
});

test("rejects an empty scan — a greedy glob must not read as clean", () => {
  ok(stallThresholdViolations([]).some((s) => s.includes("vacuous")), "an empty file list must be a violation, not a pass");
});

test("rejects a surface that mentions stall_threshold without a number", () => {
  const v = stallThresholdViolations([
    { path: "skills/plan-review/SKILL.md", markdown: "recurrence ≥ `stall_threshold` → escalate" },
  ]);
  ok(v.some((s) => s.includes("no numeric stall_threshold default")), `expected a missing-default violation, got: ${v.join(" | ")}`);
});

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
      ["micro", 1, 0],
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
  const bogus = MARKDOWN.replace("| Low | 1 reviewer | — |", "| Low | 1 reviewer | unlimited |");
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
