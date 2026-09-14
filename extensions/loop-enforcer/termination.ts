/**
 * Layered Termination (L1-L10) — P1
 *
 * 10-condition termination model. L1-L9 should trigger before L10.
 *
 * Review-cycle caps ARE authorised — proportionally. AGENTS.md (Hard Cap)
 * holds the fallback (10) and names the canonical proportional table in
 * `skills/proportional-gates/SKILL.md`: Low → no re-review (—), Low-Medium → 3,
 * Medium-High → 5, High → 10.
 * (Pre-#723 wording here claimed "no numeric caps without explicit user
 * authorization", which stopped being true when the proportional table landed.)
 *
 * L3 implements two of the skills' three stuckness detectors — `fingerprint-stall`
 * (`|current ∩ prev| / |prev|` over the last cycle pair) and `honest-stuck`
 * (count non-decreasing across 3 cycles), per `skills/code-review/SKILL.md`
 * §Stuckness detection. The third, `zero-progress`, is deliberately unported and
 * says why at the site. ⚠️ Of the two implemented, only `honest-stuck` is LIVE:
 * `fingerprints` has no producer yet (#954), so `fingerprint-stall` is latent by
 * construction — the arms' comments say so at the site. `termination.test.ts`
 * pins the predicates; `tier-config-parity.test.ts` pins `STALL_THRESHOLD`
 * against the skill declarations.
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
  /**
   * Which stuckness detector fired, in the skills' vocabulary. The two NAMES are
   * `skills/code-review/SKILL.md` §Stuckness detection (`:888` / `:890`); the
   * PERSISTED FIELD `detector_fired` and its never-empty rule live in the same
   * file's Step 6 cycle-status YAML (`:929` / `:934`), not in §Stuckness
   * detection. `reason` names the LAYER (L3); this names the DETECTOR, so a
   * persisted exit can say *why* the loop stopped rather than leaving the
   * discriminator in free-text `message`. Only the L3 arms set it, and the skills
   * require a detector exit never to leave it empty.
   */
  detector?: "fingerprint-stall" | "honest-stuck";
}

export interface CycleData {
  cycleNumber: number;
  issuesFound: number;
  issuesFixed: number;
  verdict: string;
  /**
   * Stable-identity digests of the issues this cycle ended with — ONE HASH PER
   * DEFECT, `sha256(location + ":" + severity)`, which is the skills'
   * fingerprint definition (`skills/code-review/SKILL.md` §Stuckness detection;
   * `references/fixer-loop.md`). The SET is required, not a convenience: L3's
   * recurrence is `|current ∩ prev| / |prev|`, and an intersection is not
   * computable from a single whole-set digest. A whole-set digest may still be
   * supplied as a one-element array, at the cost of detecting exact repeats
   * only — a superset recurrence then scores 0.0 instead of the canonical 1.0.
   *
   * Absent or empty ⇒ no signal ⇒ the fingerprint-stall detector never fires.
   */
  fingerprints?: string[];
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
  /** Low — 1 reviewer dispatch, 0 loop cycles (this cap counts TOTAL cycles, so 0 = no loop ever runs). Never 0 *reviewers*: #485 blocks every tier at 0 dispatches. */
  skip: 0,
  /** Low-Medium — 2 reviewers. */
  lowMedium: 3,
  /** Medium-High — 3 reviewers. */
  mediumHigh: 5,
  /** High — 4 reviewers. */
  high: 10,
} as const;

/**
 * L3 fingerprint-stall threshold — the recurrence ratio at which a loop counts
 * as stalled: fire when `|current ∩ prev| / |prev| >= STALL_THRESHOLD`.
 *
 * Mirrors the `stall_threshold` default of `0.8` declared in
 * `skills/code-review/SKILL.md` (the fixer configuration under "Step 6 — Filter
 * & Fix"; the §Stuckness detection prose there names the value but declares no
 * default) and `skills/plan-review/SKILL.md`, and the `STALL_THRESHOLD` env
 * default in `skills/code-review/references/fixer-loop.md`.
 * `tier-config-parity.test.ts` parses EVERY surface that declares a numeric
 * default (`STALL_THRESHOLD_SURFACES` — currently seven) and fails when this
 * value diverges from any of them, when a surface stops declaring, or when an
 * undeclared surface starts — a comment is not a guard (#723). This constant is
 * a *mirror*, not the source: the skills are canonical.
 */
export const STALL_THRESHOLD = 0.8;

/**
 * Proportional-gates tier mapping → loop V-levels, reviewer count and cap.
 *
 * The risk row is selected by `reviewers` (Low 1 / Low-Medium 2 /
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
export const TIER_CONFIG = {
  micro: { vLevel: null, maxCycles: REVIEW_CYCLE_CAPS.skip, reviewers: 1 },
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

  // L3: Stuckness — two INDEPENDENT detectors. Either is sufficient on its own
  // (`skills/code-review/SKILL.md` §Stuckness detection; executable form in
  // `skills/code-review/references/fixer-loop.md`). ⚠️ That SKILL.md contradicts
  // itself on the denominator — :888 forbids the symmetric form, :938 calls this
  // canonical `|prev|` form "old" (leftover from a squash that kept a superseded
  // revision's message). `fixer-loop.md` and this file agree with :888; the
  // contradiction is tracked by #953 — do NOT "fix" the denominator toward
  // `max(|curr|, |prev|)` on the strength of #884's commit message.
  //
  //   a. FINGERPRINT-STALL — recurrence = `|current ∩ prev| / |prev|`, fired at
  //      `>= STALL_THRESHOLD`. The denominator is LAST cycle's issue set and
  //      nothing else: it answers "what fraction of the issues we already had
  //      came back?". A cycle that repeats all 10 prior issues *plus* 5 new ones
  //      must therefore score 10/10 = 1.0 — the skills' own worked example.
  //      A symmetric `max(|current|, |prev|)` scores that cycle 0.67, below
  //      threshold, i.e. a total non-resolution read as ordinary churn; that is
  //      why both skills forbid it. It is also why `CycleData.fingerprints`
  //      carries one digest PER ISSUE: an intersection is not computable from a
  //      single whole-set digest, and a digest-only field scores the superset
  //      case 0.0 — worse than the forbidden symmetric form.
  //   b. HONEST-STUCK — `issuesFound` NON-DECREASING across 3 consecutive
  //      cycles, regardless of recurrence. Independent by design: a loop that
  //      churns one-for-one (every issue fixed, a new one appearing in its
  //      place) has LOW recurrence but is not converging.
  //
  // The skills' third layer, `zero-progress` (`filesChanged === 0` for 2
  // consecutive cycles), is deliberately NOT ported: nothing populates
  // `CycleData.filesChanged` — `index.ts` hardcodes `0` for every cycle — so a
  // naive port would fire on every window. Port it only when per-cycle
  // `filesChanged` is actually tracked (#954 tracks the missing transport).
  //
  // The predicate's own history, precisely (one INVERSION, one MISCOMPUTATION, #847):
  //   - The ORIGINAL form (`1e038c4`) fired on NOVELTY — the fraction of DISTINCT
  //     prints — i.e. it escalated on exactly the cycles that were making
  //     progress, and its `size >= 2` guard excluded the canonical stall (all
  //     prints equal ⇒ size 1).
  //   - The form immediately replaced here (`5612d07`) had the direction right
  //     but computed recurrence over a 3-cycle window of whole-set digests, so
  //     only 0 / 0.5 / 1.0 were reachable, the 0.8 threshold did no work, and a
  //     superset recurrence — nothing resolved, new issues added — scored 0.0
  //     against the canonical 1.0.
  //
  // Reachability, stated precisely (the two detectors differ): on absent input
  // detector (a) never fires — fail open for the LOOP, because terminating a live
  // loop on missing data is worse than missing a stall, which L10 still bounds —
  // and nothing populates `fingerprints` today (`index.ts` maps a cycle without
  // it — the transport is tracked by #954), so (a) is a latent trap rather than
  // an active mis-fire. Detector (b) is
  // NOT latent: `issuesFound` is populated in production, and widening it from
  // the old equal-count test to non-decreasing is a LIVE behaviour change — a
  // 3→4→5 churn now terminates and escalates where it previously ran to the cap.
  if (n >= 2) {
    const currCycle = cycles[n - 1];
    const prevCycle = cycles[n - 2];

    // (a) recurrence over the LAST PAIR — one transition. That is the skills'
    // per-cycle recurrence; they do not aggregate a window.
    //
    // Both sides are SETS, as the canonical form is (`len(current_fps & prev_fps)
    // / len(prev_fps)` over Python sets): a repeated digest must not count twice
    // in the numerator nor twice in the denominator. Computing either side as a
    // list breaks the ratio in both directions — `prev=[a,a],curr=[a]` scores 0.5
    // where the canon scores 1.0 (a missed stall), and `prev=[a],curr=[a,a,a]`
    // scores 3.0, printing "300%" and escalating a loop the canon reads at 1.0.
    // Duplicates are reachable: the fingerprint is `sha256(location + ":" +
    // severity)`, so two defects sharing a location and severity collapse to one
    // digest. A falsy entry is dropped — `filter(Boolean)`, so `""` (the legacy
    // "no fingerprint" sentinel) and any other falsy value are treated as "this
    // cycle carries no identity for that issue" rather than as a
    // maximally-recurring digest.
    const prevFps = (prevCycle.fingerprints ?? []).filter(Boolean);
    const currFps = (currCycle.fingerprints ?? []).filter(Boolean);
    let recurrence: number | null = null;
    if (prevFps.length > 0 && currFps.length > 0) {
      const prevSet = new Set(prevFps);
      const currSet = new Set(currFps);
      let recurring = 0;
      for (const fp of currSet) if (prevSet.has(fp)) recurring++;
      recurrence = recurring / prevSet.size;
    }

    // (b) non-decreasing count across the last 3 cycles (needs 3 counts).
    const last3 = cycles.slice(-3);
    const countNotShrinking = last3.length === 3
      && last3.every((c, i) => i === 0 || c.issuesFound >= last3[i - 1].issuesFound);

    const fingerprintStalled = recurrence !== null && recurrence >= STALL_THRESHOLD;

    // Both signals are computed BEFORE returning, so the label follows the
    // canonical precedence — `honest-stuck` when the count is not shrinking,
    // else `fingerprint-stall` (`fixer-loop.md`:
    // `print('honest-stuck' if honest else 'fingerprint-stall')`).
    //
    // `currCycle.issuesFound > 0` and `n < effectiveMax` are deliberate
    // delegations, NOT part of either canonical predicate: an all-zero count is
    // L1/L5's to report, and the cap is L10's (which also escalates). Reporting
    // a stall at the cap as L3 would consume an extra Ralph-loop recovery.
    if ((fingerprintStalled || countNotShrinking) && currCycle.issuesFound > 0 && n < effectiveMax) {
      const detector = countNotShrinking ? "honest-stuck" : "fingerprint-stall";
      const detail = countNotShrinking
        ? `issue count non-decreasing for 3 cycles (${last3.map(c => c.issuesFound).join("→")}).`
        : `recurrence ${((recurrence as number) * 100).toFixed(0)}% of the previous cycle's issues recurred (threshold ${(STALL_THRESHOLD * 100).toFixed(0)}%).`;
      return { shouldExit: true, reason: "L3-deadlock", escalate: true, detector, message: `${detector}: ${detail}` };
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
