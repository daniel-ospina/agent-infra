/**
 * Layered Termination (L1-L10) — P1
 * 
 * 10-condition termination model. L1-L9 should trigger before L10.
 * Per AGENTS.md: no numeric caps without explicit user authorization.
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

/** Proportional-gates tier mapping → loop V-levels and max cycles. */
export const TIER_CONFIG = {
  micro: { vLevel: null, maxCycles: 0, reviewers: 0 },
  standard: { vLevel: "V1", maxCycles: 10, reviewers: 2 },
  complex: { vLevel: "V2", maxCycles: 20, reviewers: 4 },
} as const;

export type Tier = keyof typeof TIER_CONFIG;

/**
 * Check all 10 termination layers in priority order.
 * Returns first matching condition.
 * tier overrides maxCycles from TIER_CONFIG when provided.
 */
export function evaluateTermination(
  cycles: CycleData[],
  maxCycles: number = 10,
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

  // L3: Deadlock — identical-issue-fingerprint-stall OR plateau (same count 3 cycles).
  // Fingerprint comparison is skipped when fingerprints are not populated (the common case).
  if (n >= 3) {
    const last3 = cycles.slice(-3);
    const fingerprints = last3.map(c => c.fingerprint || "");
    const uniquePrints = new Set(fingerprints.filter(f => f));
    const allSameCount = last3.every(c => c.issuesFound === lastCycle?.issuesFound);

    // Only fire fingerprint-stall when fingerprints ARE populated (≥2 distinct populated)
    if (uniquePrints.size >= 2 && fingerprints.every(f => f)) {
      const uniqueness = uniquePrints.size / fingerprints.length;
      if (uniqueness >= 0.8) {
        return { shouldExit: true, reason: "L3-deadlock", escalate: true, message: `Fingerprint-stall: ${(uniqueness * 100).toFixed(0)}% unique fingerprints (≤20% expected).` };
      }
    }

    // Plateau: same issue count for 3 consecutive cycles (not at zero, not at cap)
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
