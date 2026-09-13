/**
 * Layered Termination (L1-L10) — P1
 *
 * 10-condition termination model. L1-L9 should trigger before L10.
 *
 * Review-cycle caps ARE authorised — proportionally. AGENTS.md (Hard Cap)
 * holds the fallback (10) and names the canonical proportional table in
 * `skills/proportional-gates/SKILL.md`: Low → skip, Low-Medium → 3,
 * Medium-High → 5, High → 10.
 * (Pre-#723 wording here claimed "no numeric caps without explicit user
 * authorization", which stopped being true when the proportional table landed.)
 */
export type TerminationLayer =
  | "L1-quality-gate"
  | "L2-convergence"
  | "L3-deadlock"
  | "L4-budget"
  | "L5-diminishing-returns"
  | "L6-timeout"
  | "L7-error-threshold"
  | "L8-output-cap"
  | "L9-external-abort"
  | "L10-max-cycles";

export interface TerminationResult {
  shouldExit: boolean;
  reason: TerminationLayer;
  escalate: boolean;
  message: string;
}

export interface CycleData {
  cycleNumber: number;
  issuesFound: number;
  issuesFixed: number;
  verdict: string;
  fingerprint?: string;
  filesChanged: number;
  wallClockMs: number;
}

/**
 * Canonical proportional review-cycle bounds — the single in-code source.
 *
 * Mirrors the "Review Cycles" table in `skills/proportional-gates/SKILL.md`,
 * which AGENTS.md §Hard Cap names canonical. Keyed by the risk row; each entry
 * is (reviewers → max cycles) in that table.
 *
 * `tier-config-parity.test.ts` parses the skill table and fails when these
 * values — or the TIER_CONFIG mapping below — diverge from it. A comment is
 * not a guard (#723).
 */
export const REVIEW_CYCLE_CAPS = {
  /** Low — 0 reviewers, review skipped. */
  skip: 0,
  /** Low-Medium — 2 reviewers. */
  lowMedium: 3,
  /** Medium-High — 3 reviewers. */
  mediumHigh: 5,
  /** High — 4 reviewers. */
  high: 10,
} as const;

/**
 * Proportional-gates tier mapping → loop V-levels, reviewer count and cap.
 *
 * The risk row is selected by `reviewers` (Low 0 / Low-Medium 2 /
 * Medium-High 3 / High 4) and `maxCycles` MUST equal that row's Max Cycles.
 * The complexity tiers map onto rows 1, 2 and 4: `standard` declares 2
 * reviewers (Low-Medium, 3 cycles) and `complex` declares 4 (High, 10).
 * No tier carries 3 reviewers, so Medium-High has no tier — its bound is
 * declared above for completeness, not applied here.
 * `tier-config-parity.test.ts` enforces the pairing against the skill file.
 *
 * NOTE (scope): this mapping is keyed on `reviewers`, and the tiers' V-levels
 * are descriptive. The only tier derivation in-tree (`index.ts`: V2 → complex,
 * everything else → standard) collapses V3/V4 onto `standard`, which would
 * give those levels the *tightest* non-micro cap. No *production* caller
 * passes `tier` to `evaluateTermination` today (only `termination.test.ts`
 * does, with `"micro"`), so this is latent — but reusing that derivation to
 * drive `tier` needs the V3/V4 case resolved first.
 */
/**
 * L3 fingerprint-stall threshold — the fraction of consecutive cycle pairs whose
 * fingerprint is UNCHANGED that constitutes a stall.
 *
 * Mirrors `stall_threshold` in `skills/code-review/SKILL.md` (§Fingerprint-stall,
 * default `0.8`) and `skills/plan-review/SKILL.md` (same value). Read as a ratio
 * of *recurrence*, not of novelty: 0.8 means "80% of the window repeated the
 * previous fingerprint". The canonical per-issue form is
 * `|current ∩ prev| / |prev|`; with one whole-set digest per cycle the only
 * computable quantity is whether a cycle is an exact repeat, so the ratio is
 * taken over window transitions.
 */
export const STALL_THRESHOLD = 0.8;

export const TIER_CONFIG = {
  micro: { vLevel: null, maxCycles: REVIEW_CYCLE_CAPS.skip, reviewers: 0 },
  standard: { vLevel: "V1", maxCycles: REVIEW_CYCLE_CAPS.lowMedium, reviewers: 2 },
  complex: { vLevel: "V2", maxCycles: REVIEW_CYCLE_CAPS.high, reviewers: 4 },
} as const;

export type Tier = keyof typeof TIER_CONFIG;

/**
 * Check all 10 termination layers in priority order.
 * Returns first matching condition.
 * tier overrides maxCycles from TIER_CONFIG when provided.
 */
export function evaluateTermination(
  cycles: CycleData[],
  maxCycles: number = REVIEW_CYCLE_CAPS.high,
  budgetTokens: number = Infinity,
  startTime: number = Date.now(),
  timeoutMs: number = Infinity,
  verifierFailures: number = 0,
  contextTokens: number = 0,
  contextLimit: number = 100000,
  userAborted: boolean = false,
  tier?: Tier,
): TerminationResult {
  const effectiveMax = tier ? TIER_CONFIG[tier].maxCycles : maxCycles;
  const lastCycle = cycles[cycles.length - 1];
  const n = cycles.length;

  // L1: Quality gate — all indicators green, verifier CLEAN, 0 issues
  if (lastCycle && lastCycle.verdict === "CLEAN" && lastCycle.issuesFound === 0) {
    return { shouldExit: true, reason: "L1-quality-gate", escalate: false, message: "All indicators green, 0 issues." };
  }

  // L2: Convergence — informational only. The loop's only auto-exit is L1 (CLEAN, 0 issues).
  // L2 detects progress (issue count declining) but does NOT trigger exit — the user
  // wants loops to run until a fresh review finds zero issues.
  // (L2 return removed — always continue past this layer.)

  // L3: Deadlock — fingerprint-stall (the same issue set recurring) OR plateau
  // (the issue count is not shrinking). Plateau IS the skills' `honest-stuck`
  // layer: an independent signal, NOT gated on the fingerprint test.
  //
  // ⛔ Direction. `fingerprints` carries ONE whole-set digest per cycle, so the
  // computable recurrence is the fraction of window TRANSITIONS that repeat the
  // previous fingerprint: 1.0 for a full stall, 0.0 when every cycle differs.
  // The form this replaced divided the count of DISTINCT prints by the window
  // size and fired at `>= 0.8` — i.e. it escalated on exactly the cycles that
  // were making progress (novelty, not recurrence) — and its `size >= 2` guard
  // made the canonical stall (all prints equal ⇒ size === 1) unreachable. Both
  // halves were the inversion of the canonical predicate in
  // `skills/code-review/SKILL.md` §Fingerprint-stall: recurrence =
  // `|current ∩ prev| / |prev|`, fire at `>= stall_threshold`.
  //
  // Unpopulated fingerprints carry NO signal ⇒ never fire on them. Fail open
  // for the LOOP: terminating a live loop on absent data is worse than missing
  // a stall, which L10 still bounds. (This is also why the branch is currently
  // unreachable in production — no caller populates `fingerprint` yet.)
  if (n >= 3) {
    const last3 = cycles.slice(-3);
    const fingerprints = last3.map(c => c.fingerprint || "");
    const allSameCount = last3.every(c => c.issuesFound === lastCycle?.issuesFound);

    if (fingerprints.every(f => f !== "")) {
      let recurring = 0;
      for (let i = 1; i < fingerprints.length; i++) {
        if (fingerprints[i] === fingerprints[i - 1]) recurring++;
      }
      const transitions = fingerprints.length - 1;
      const recurrence = transitions === 0 ? 0 : recurring / transitions;
      if (recurrence >= STALL_THRESHOLD) {
        return { shouldExit: true, reason: "L3-deadlock", escalate: true, message: `Fingerprint-stall: ${(recurrence * 100).toFixed(0)}% of cycles repeated the previous fingerprint (threshold ${(STALL_THRESHOLD * 100).toFixed(0)}%).` };
      }
    }

    // Plateau (≡ `honest-stuck`): same issue count for 3 consecutive cycles
    // (not at zero, not at cap).
    if (allSameCount && lastCycle && lastCycle.issuesFound > 0 && n < effectiveMax) {
      return { shouldExit: true, reason: "L3-deadlock", escalate: true, message: `Plateau: ${lastCycle.issuesFound} issues for 3 cycles.` };
    }
  }

  // L4: Budget
  if (budgetTokens <= 0) {
    return { shouldExit: true, reason: "L4-budget", escalate: true, message: "Token budget depleted." };
  }

  // L5: Diminishing returns
  if (n >= 3 && n < effectiveMax) {
    const last3Issues = cycles.slice(-3).map(c => c.issuesFixed || 0);
    if (last3Issues.every(v => v === 0) && lastCycle && lastCycle.verdict !== "CLEAN") {
      return { shouldExit: true, reason: "L5-diminishing-returns", escalate: false, message: "Zero issues fixed for 3 cycles." };
    }
  }

  // L6: Timeout
  if (Date.now() - startTime > timeoutMs) {
    return { shouldExit: true, reason: "L6-timeout", escalate: false, message: "Wall clock exceeded." };
  }

  // L7: Error threshold
  if (verifierFailures >= 3) {
    return { shouldExit: true, reason: "L7-error-threshold", escalate: true, message: `${verifierFailures} consecutive verifier failures.` };
  }

  // L8: Output cap — context near exhaustion
  if (contextTokens > contextLimit * 0.85) {
    return { shouldExit: true, reason: "L8-output-cap", escalate: false, message: "Context near exhaustion." };
  }

  // L9: External abort
  if (userAborted) {
    return { shouldExit: true, reason: "L9-external-abort", escalate: false, message: "User abort." };
  }

  // L10: Max cycles — last resort (checked last so it overrides everything)
  if (n >= effectiveMax) {
    return { shouldExit: true, reason: "L10-max-cycles", escalate: true, message: `Max cycles (${effectiveMax}) reached.` };
  }

  return { shouldExit: false, reason: "L10-max-cycles", escalate: false, message: "Continue." };
}
