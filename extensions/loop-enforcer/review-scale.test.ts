/**
 * Self-check: review-scale.test.ts — the review round's SEVERITY / SCOPE / CEILING rule (#1537)
 * Run: npx tsx extensions/loop-enforcer/review-scale.test.ts
 *
 * The four cases the issue names as acceptance, plus the negative controls that keep them
 * from passing for the wrong reason:
 *
 *   (i)   a P2-only round cannot start another round
 *   (ii)  a prose-about-process finding is classified non-blocking
 *   (iii) a correctness finding still blocks
 *   (iv)  removing the ceiling check makes (i) FAIL — non-vacuity, proven by mutation
 *
 * Every case runs through `runSuite(api)`, so the SAME assertions can be replayed against
 * a MUTATED copy of the module. That is how (iv) is proven: mutant M1 deletes the ceiling
 * branch and (i) goes red; mutant M2 flattens the class caps to the widest value and the
 * proportionality cases go red. A suite that stayed green against either mutant would be
 * pinning nothing.
 */

import { readFileSync, writeFileSync, unlinkSync } from "fs";
import { dirname, join } from "path";
import { fileURLToPath, pathToFileURL } from "url";
import * as real from "./review-scale.ts";
import { REVIEW_CYCLE_CAPS } from "./termination.ts";
import type { Disposition, RoundDecision, CapResolution, ReviewFinding } from "./review-scale.ts";

type Api = {
  cycleCapForClass: (riskClass: string, adversarial?: boolean) => CapResolution;
  dispositionOf: (finding: ReviewFinding, changedFiles: readonly string[]) => Disposition;
  decideRound: (input: import("./review-scale.ts").RoundInput) => RoundDecision;
};

export interface CaseResult {
  id: string;
  ok: boolean;
  label: string;
}

const CHANGED = [".github/workflows/ci.yml", "extensions/loop-enforcer/termination.ts", "skills/code-review/SKILL.md"];

/** One finding that blocks: about the change, and it names a wrong outcome. */
const correctness: ReviewFinding = {
  severity: "P2",
  origin: "diff",
  file: "extensions/loop-enforcer/termination.ts",
  outcome: "silent wrong result: a stalled ingest is reported as success",
  description: "the L3 return is dropped on the third cycle",
};

/** One finding the DMeer#1058 pathology produced: comment precision on the change. */
const commentPrecision: ReviewFinding = {
  severity: "P2",
  origin: "diff",
  file: "skills/code-review/SKILL.md",
  outcome: "none",
  description: "the header claims the guard can never false-green while declaring rendering unmodelled",
};

/**
 * The same shape as the measured pathology: a defect in the PR description's prose ABOUT
 * ITS OWN PROCESS. Three review rounds of `DMeer#1069` were this class.
 */
const processProse: ReviewFinding = {
  severity: "P1",
  origin: "process",
  outcome: "none",
  description: "the PR description says the reviewer roster was 3 when the brief said 2",
};

export function runSuite(api: Api): CaseResult[] {
  const results: CaseResult[] = [];
  const expect = (id: string, cond: boolean, label: string) => results.push({ id, ok: cond, label });

  // ── The canonical-table mirror ────────────────────────────────────────────────────
  {
    const r = api.cycleCapForClass("low");
    expect("cap:mirror-termination", r.cap === REVIEW_CYCLE_CAPS.skip,
      "Low's cap is the canonical table's skip sentinel (0 = no re-review loop)");
  }
  {
    const rows: Array<[string, number]> = [
      ["low", REVIEW_CYCLE_CAPS.skip],
      ["low-medium", REVIEW_CYCLE_CAPS.lowMedium],
      ["medium-high", REVIEW_CYCLE_CAPS.mediumHigh],
      ["high", REVIEW_CYCLE_CAPS.high],
    ];
    const wrong = rows.filter(([cls, cap]) => api.cycleCapForClass(cls).cap !== cap);
    expect("cap:row-values", wrong.length === 0,
      `every RISK_CLASS resolves to ITS row's cap (${wrong.map(([c]) => c).join(",") || "none"} wrong)`);
  }
  {
    const r = api.cycleCapForClass("high", true);
    expect("cap:adversarial-tightens", r.cap === 2 && /tightened/.test(r.basis),
      "the adversarial bound tightens a wider class cap to 2 and says so");
  }
  {
    const r = api.cycleCapForClass("low", true);
    expect("cap:adversarial-never-widens", r.cap === REVIEW_CYCLE_CAPS.skip,
      "the adversarial bound never WIDENS a tighter class cap");
  }
  {
    const r = api.cycleCapForClass("bogus");
    expect("cap:unknown-widest", r.cap === REVIEW_CYCLE_CAPS.high && /unrecognised/.test(r.basis),
      "an unrecognised class takes the widest cap AND the basis says the class was unrecognised");
  }

  // ── (ii) scope: prose about the change's own process never blocks ────────────────
  {
    const d = api.dispositionOf(processProse, CHANGED);
    expect("scope:process-prose-non-blocking", d.verdict === "follow_up",
      `(ii) a prose-about-process finding is non-blocking (got ${d.verdict})`);
    expect("scope:process-prose-reason", /DELETION/.test(d.reason),
      "(ii) its disposition names DELETION as the resolution, not another wording round");
  }
  {
    const d = api.dispositionOf({ ...correctness, origin: "pre-existing" }, CHANGED);
    expect("scope:pre-existing-non-blocking", d.verdict === "follow_up",
      "a finding in code the change does not touch is a follow-up (origin-keyed deferral)");
  }
  {
    // The SCOPE CHECK: a finding CLAIMS the diff but cites a file this change never modifies.
    const d = api.dispositionOf({ ...correctness, file: "tortoise/sdk.py" }, CHANGED);
    expect("scope:file-not-in-diff-reclassified", d.verdict === "follow_up" && /reclassified/.test(d.reason),
      "a finding claiming the diff for an UNTOUCHED file is reclassified as pre-existing");
  }
  {
    const d = api.dispositionOf({ ...correctness, file: undefined }, CHANGED);
    expect("scope:no-file-non-blocking", d.verdict === "follow_up",
      "a diff finding that cites no file is not attributable to the change");
  }

  // ── (iii) a correctness finding still blocks ─────────────────────────────────────
  {
    const d = api.dispositionOf(correctness, CHANGED);
    expect("severity:correctness-blocks", d.verdict === "blocking",
      `(iii) a correctness finding attributable to the change still BLOCKS (got ${d.verdict})`);
    expect("severity:correctness-reason", /wrong outcome/.test(d.reason),
      "(iii) the blocking reason names the wrong outcome it is blocking for");
  }
  {
    const d = api.dispositionOf({ ...correctness, severity: "P0", outcome: "data loss: the claim store is truncated" }, CHANGED);
    expect("severity:p0-blocks", d.verdict === "blocking", "a P0 data-loss finding blocks");
  }
  {
    const d = api.dispositionOf({ ...correctness, severity: "P3" }, CHANGED);
    expect("severity:p3-non-blocking", d.verdict === "follow_up",
      "the taxonomy's lowest band (P3) is recorded, never blocking");
  }
  {
    const d = api.dispositionOf(commentPrecision, CHANGED);
    expect("severity:comment-precision-non-blocking", d.verdict === "follow_up",
      "the DMeer#1058 class (comment precision, outcome: none) is a follow-up");
  }

  // ── Fail-closed: an unstated field is never an implicit nit ──────────────────────
  {
    const d = api.dispositionOf(correctness, []);
    expect("failclosed:empty-changed-set", d.verdict === "malformed-blocking",
      "an EMPTY/UNREADABLE changed-file set makes a diff finding BLOCKING, never a silent follow-up");
  }
  {
    const d = api.dispositionOf({ ...correctness, origin: undefined }, CHANGED);
    expect("failclosed:no-origin", d.verdict === "malformed-blocking",
      "an ABSENT origin is malformed and treated as blocking (absence is not 'none')");
  }
  {
    const d = api.dispositionOf({ ...correctness, outcome: undefined }, CHANGED);
    expect("failclosed:no-outcome", d.verdict === "malformed-blocking",
      "an ABSENT outcome is malformed and treated as blocking");
  }
  {
    const d = api.dispositionOf({ ...correctness, origin: "sideways" }, CHANGED);
    expect("failclosed:unknown-origin", d.verdict === "malformed-blocking",
      "an unknown origin is malformed and treated as blocking");
  }

  // ── (i) a P2-only round cannot start another round ───────────────────────────────
  {
    const d = api.decideRound({
      riskClass: "low-medium",
      cyclesUsed: 2,
      findings: [commentPrecision, { ...commentPrecision, description: "second imprecise sentence" }],
      changedFiles: CHANGED,
    });
    expect("round:p2-only-lands", d.decision === "land",
      `(i) a P2-only round does NOT start another round (got ${d.decision})`);
    expect("round:p2-only-follow-ups-filed", d.followUps.length === 2 && d.blocking.length === 0,
      "(i) both P2s are recorded as follow-ups and none is blocking");
    expect("round:p2-only-disclosure", d.disclosure === "[PROPORTIONAL] cycles=2 cap=3 blocking=0 follow-ups=<#issue,…|none>",
      "(i) the landing carries the [PROPORTIONAL] disclosure line for the PR body");
  }
  {
    const d = api.decideRound({ riskClass: "low-medium", cyclesUsed: 1, findings: [processProse], changedFiles: CHANGED });
    expect("round:process-prose-lands", d.decision === "land",
      "(ii) a round whose only finding is process prose lands instead of re-reviewing");
  }
  {
    const d = api.decideRound({ riskClass: "low-medium", cyclesUsed: 1, findings: [], changedFiles: CHANGED });
    expect("round:clean-lands", d.decision === "land" && d.disclosure !== null,
      "a round with no findings at all lands");
  }

  // ── (iii) continued: blocking findings keep the round alive, and never land ──────
  {
    const d = api.decideRound({ riskClass: "low-medium", cyclesUsed: 1, findings: [correctness], changedFiles: CHANGED });
    expect("round:correctness-continues", d.decision === "continue",
      "(iii) a correctness finding within the ceiling continues the loop (fix + fresh re-review)");
  }
  {
    const d = api.decideRound({ riskClass: "low-medium", cyclesUsed: 3, findings: [correctness], changedFiles: CHANGED });
    expect("round:ceiling-escalates-not-lands", d.decision === "escalate",
      "(iii) at the class's ceiling a blocking finding ESCALATES — never land");
    expect("round:ceiling-escalation-names-blocker", d.blocking.length === 1 && /NOT a landing/.test(d.reason),
      "(iii) the escalation names the blocker and states it is not a landing");
    expect("round:ceiling-no-disclosure", d.disclosure === null,
      "(iii) an escalation cannot carry the landing disclosure");
  }
  {
    const d = api.decideRound({ riskClass: "low", cyclesUsed: 1, findings: [correctness], changedFiles: CHANGED });
    expect("round:low-class-escalates-immediately", d.decision === "escalate",
      "Low's row is the skip sentinel: its single pass finding a blocker escalates instead of looping");
  }
  {
    const d = api.decideRound({ riskClass: "high", cyclesUsed: 3, findings: [correctness], changedFiles: CHANGED });
    expect("round:high-keeps-its-budget", d.decision === "continue",
      "High keeps its 10-cycle budget — the same finding at cycle 3 does not escalate there");
  }
  {
    const d = api.decideRound({ riskClass: "low-medium", cyclesUsed: 0, findings: [], changedFiles: CHANGED });
    expect("round:zero-cycles-cannot-land", d.decision === "continue",
      "a landing requires at least ONE review round — zero rounds can never land");
  }
  {
    const d = api.decideRound({
      riskClass: "high",
      cyclesUsed: 2,
      findings: [correctness],
      changedFiles: CHANGED,
      adversarial: true,
    });
    expect("round:adversarial-cap-applies", d.decision === "escalate" && d.cap === 2,
      "the adversarial bound (2) escalates at cycle 2 even though the High row allows 10");
  }

  return results;
}

async function main(): Promise<void> {
  // ── Runner ─────────────────────────────────────────────────────────────────────────
  const base = runSuite(real as unknown as Api);
  let failed = 0;
  for (const r of base) {
    if (r.ok) {
      console.log(`  ✅ [${r.id}] ${r.label}`);
    } else {
      failed++;
      console.error(`  ❌ [${r.id}] ${r.label}`);
    }
  }
  console.log(`\n${base.length - failed} passed, ${failed} failed\n`);

  // ── The DOC TWIN must agree with the module ───────────────────────────────────────
//
// `skills/code-review/references/fixer-loop.md` §L6.1 carries the same disposition as an
// inline python block, because that file is executed in whatever repo the loop runs in and
// cannot import this module. Two copies of one rule drift — the twin was written, and it
// was WRONG within the hour (a missing `verdict, reason = 'blocking', ''` initialiser made
// every attributable finding fall through as a follow-up). So the equivalence is pinned
// here: the doc's helper is EXECUTED against the same fixtures and every verdict must match
// `dispositionOf`. The expected values come from the tested module, never from the doc, so
// this cannot be forged by editing the doc.

const FIXTURES: ReviewFinding[] = [
  { severity: "P2", origin: "diff", file: "skills/code-review/SKILL.md", outcome: "none" },
  { severity: "P2", origin: "diff", file: "extensions/loop-enforcer/termination.ts", outcome: "silent wrong result" },
  { severity: "P1", origin: "process", file: null, outcome: "none" },
  { severity: "P1", origin: "diff", file: "tortoise/sdk.py", outcome: "data loss" },
  { severity: "P1", origin: "diff", file: "skills/code-review/SKILL.md" },
  { severity: "P0", origin: "diff", file: "extensions/loop-enforcer/termination.ts", outcome: "data loss: the store is truncated" },
  { severity: "P3", origin: "diff", file: "skills/code-review/SKILL.md", outcome: "minor wording" },
  { severity: "P2", outcome: "none" },
  // Path-normalisation shapes (#1537 review F4): the twin and the module must agree on
  // every one of these, not only on the tidy spellings.
  { severity: "P1", origin: "diff", file: "././skills/code-review/SKILL.md", outcome: "silent wrong result" },
  { severity: "P1", origin: "diff", file: "/extensions/loop-enforcer/termination.ts", outcome: "data loss" },
  { severity: "P0", origin: "diff", file: "./.github/workflows/ci.yml", outcome: "the gate stops running" },
  { severity: "P1", origin: "diff", file: "../extensions/loop-enforcer/termination.ts", outcome: "data loss" },
];

async function twinEquivalence(): Promise<string[]> {
  const problems: string[] = [];
  const md = readFileSync(join(HERE, "..", "..", "skills", "code-review", "references", "fixer-loop.md"), "utf-8");
  const fnStart = md.indexOf("disposition_json() {");
  if (fnStart === -1) {
    return ["fixer-loop.md no longer carries the `disposition_json()` helper — the loop has no disposition to apply"];
  }
  const fnEnd = md.indexOf("\n}\n", fnStart);
  if (fnEnd === -1) return ["the disposition_json() helper is unterminated"];
  const block = md.slice(fnStart, fnEnd);
  if (!block.includes("verdict, reason = 'blocking', ''")) {
    problems.push(
      "the helper dropped the `verdict, reason = 'blocking', ''` initialiser — every attributable finding then falls through as a follow-up (the bug this pin was written after)",
    );
  }
  const marker = 'python3 -c "';
  const at = block.indexOf(marker);
  if (at === -1) return [...problems, "the disposition helper's python body was not found"];
  const bodyEnd = block.indexOf('\n" "$1" "$2"', at);
  if (bodyEnd === -1) return [...problems, "the disposition helper's python body is unterminated"];
  const code = block.slice(at + marker.length, bodyEnd);
  const { execFileSync } = await import("node:child_process");
  let stdout: string;
  try {
    stdout = execFileSync("python3", ["-c", code, JSON.stringify(FIXTURES), JSON.stringify(CHANGED)], {
      encoding: "utf-8",
    });
  } catch (e) {
    return [...problems, `the L6.1 helper did not run: ${(e as Error).message}`];
  }
  const parsed = JSON.parse(stdout) as { blocking: ReviewFinding[]; follow_ups: ReviewFinding[] };
  // Identity is the four DECISION fields only: the twin echoes the whole finding back
  // plus its own `disposition`/`disposition_reason`, so a whole-object key never matches.
  const keyOf = (f: ReviewFinding) =>
    JSON.stringify([f.severity ?? null, f.origin ?? null, f.file ?? null, f.outcome ?? null]);
  const twinBlocking = new Set((parsed.blocking ?? []).map(keyOf));
  const twinFollow = new Set((parsed.follow_ups ?? []).map(keyOf));
  for (const f of FIXTURES) {
    const expected = real.dispositionOf(f, CHANGED).verdict === "follow_up" ? "follow_up" : "blocking";
    const key = keyOf(f);
    const actual = twinBlocking.has(key) ? "blocking" : twinFollow.has(key) ? "follow_up" : "MISSING";
    if (actual !== expected) {
      problems.push(
        `twin disagrees on ${JSON.stringify({ severity: f.severity, origin: f.origin, file: f.file, outcome: f.outcome })}: module says ${expected}, doc twin says ${actual}`,
      );
    }
  }
  return problems;
}

// ── (iv) NON-VACUITY — mutations of the module must turn the suite red ────────────
  //
  // A case that only proves the acceptance path would let the ceiling be deleted and stay
  // green. Each mutant is a SYNTACTIC edit of the real module (a scratch copy beside the
  // original, so `./termination.ts` still resolves), re-run through the SAME suite.

  const HERE = dirname(fileURLToPath(import.meta.url));
  const SOURCE = readFileSync(join(HERE, "review-scale.ts"), "utf-8");

  interface Mutant {
    id: string;
    description: string;
    from: string;
    to: string;
    /** The cases that MUST go red when this mutant is applied. */
    mustFail: string[];
  }

  const MUTANTS: Mutant[] = [
    {
      id: "M1",
      description: "the ceiling check deleted — nothing stops a non-blocking round from looping",
      from: "  if (blocking.length === 0 && (input.cyclesUsed ?? 0) >= 1) {",
      to: "  if (false) {",
      mustFail: ["round:p2-only-lands", "round:process-prose-lands", "round:clean-lands"],
    },
    {
      id: "M2",
      description: "every class flattened to the widest cap — the ceiling is no longer proportional",
      from:
        'const CAP_BY_CLASS: Record<RiskClass, number> = { low: REVIEW_CYCLE_CAPS.skip, "low-medium": REVIEW_CYCLE_CAPS.lowMedium, "medium-high": REVIEW_CYCLE_CAPS.mediumHigh, high: REVIEW_CYCLE_CAPS.high };',
      to:
        'const CAP_BY_CLASS: Record<RiskClass, number> = { low: 10, "low-medium": 10, "medium-high": 10, high: 10 };',
      mustFail: ["cap:row-values", "cap:adversarial-never-widens", "round:low-class-escalates-immediately"],
    },
    {
      id: "M3",
      description: "the outcome field ignored — every attributable finding blocks (the pre-#1537 treadmill)",
      from: '  if (String(outcome).trim().toLowerCase() === "none") {',
      to: "  if (false) {",
      mustFail: ["severity:comment-precision-non-blocking", "round:p2-only-lands"],
    },
    {
      id: "M4",
      description: "the scope check deleted — a finding may claim the diff for a file it never touches",
      from: "  if (!changed.has(normalisePath(claimed))) {",
      to: "  if (false) {",
      mustFail: ["scope:file-not-in-diff-reclassified"],
    },
    {
      id: "M5",
      description: "fail-open on an absent field — an unstated origin is treated as a nit",
      from: '  if (!origin) {\n    return {\n      finding,\n      verdict: "malformed-blocking",',
      to: '  if (!origin) {\n    return {\n      finding,\n      verdict: "follow_up",',
      mustFail: ["failclosed:no-origin"],
    },
  ];

  const twinProblems = await twinEquivalence();
  if (twinProblems.length > 0) {
    for (const p of twinProblems) console.error(`  ❌ [twin] ${p}`);
  } else {
    console.log("  ✅ [twin] the fixer-loop.md L6.1 helper returns the same disposition as dispositionOf() on every fixture");
  }
  const twinFailures = twinProblems.length;

  let mutantFailures = 0;
  for (const m of MUTANTS) {
    if (!SOURCE.includes(m.from)) {
      mutantFailures++;
      console.error(`  ❌ [${m.id}] MUTATION DID NOT APPLY — the anchor text is gone from review-scale.ts: ${m.from}`);
      continue;
    }
    const mutated = SOURCE.replace(m.from, m.to);
    const file = join(HERE, `.review-scale.mutant-${m.id}.ts`);
    writeFileSync(file, mutated, "utf-8");
    try {
      const mod = (await import(pathToFileURL(file).href)) as Api;
      const results = runSuite(mod);
      const red = new Set(results.filter((r) => !r.ok).map((r) => r.id));
      const missing = m.mustFail.filter((id) => !red.has(id));
      if (missing.length > 0) {
        mutantFailures++;
        console.error(
          `  ❌ [${m.id}] SURVIVED (vacuous test) — ${m.description}; these cases stayed GREEN and should not have: ${missing.join(", ")}`,
        );
      } else {
        console.log(
          `  ✅ [${m.id}] caught: ${m.description} → ${m.mustFail.join(", ")} went RED (${red.size} case(s) red in total)`,
        );
      }
    } finally {
      try {
        unlinkSync(file);
      } catch {
        /* the scratch copy is outside the index either way */
      }
    }
  }

  // The suite's own floor: a silently-shrunk case list would let the mutants "pass" by
  // pinning nothing. Keep this in step with the case list above.
  const EXPECTED_CASES = 32;
  let floorFailures = 0;
  if (base.length !== EXPECTED_CASES) {
    floorFailures++;
    console.error(`  ❌ case-count pin: expected ${EXPECTED_CASES} cases, ran ${base.length} — a case was silently dropped`);
  } else {
    console.log(`  ✅ case-count pin: ${base.length} cases ran`);
  }

  const totalFailed = failed + twinFailures + mutantFailures + floorFailures;
  console.log(
    `\n${base.length - failed} passed, ${failed} failed; ${MUTANTS.length - mutantFailures}/${MUTANTS.length} mutants caught\n`,
  );
  if (totalFailed > 0) {
    console.error(`FAILED (${totalFailed})`);
    process.exit(1);
  }
  console.log("ALL PASSED");
}

main();
