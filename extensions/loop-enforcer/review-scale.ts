/**
 * Review-scale rule — DOES THIS ROUND START ANOTHER ROUND? (#1537)
 *
 * The code-review loop had a reviewer-count cap (`#1539`, Step 4's `PANEL_MAX`) and a
 * flat 10-cycle safety cap, but **no rule that scopes a finding to the change** and no
 * ceiling tied to the change's own size/risk. Measured cost: a three-string PR took 9
 * review cycles and 11 commits (`DMeer#1058`), and a follower-read fix took 13 cycles
 * against a brief that permitted 3 (`DMeer#1069`). Both loops spent most of their lives
 * re-reviewing artefacts and prose that no wrong outcome could be attributed to.
 *
 * Two things are decided here, and nowhere else:
 *
 *   1. **DISPOSITION** — which findings BLOCK the landing and which are recorded as
 *      follow-ups. The load-bearing field is the **named wrong outcome**, not the
 *      P-number: "severity is a function of the named consequence; a finding is
 *      non-blocking by default and becomes blocking only when its author states the
 *      wrong outcome it can produce" (the field-evidence rule adopted on #1537 —
 *      `nit:`/`Optional` label classes at Google, GitLab's `(non-blocking:)`,
 *      Homebrew's "request changes is a last resort"). A category ban on prose was
 *      REJECTED by that pass: comment/code inconsistency carries ~1.5× odds of a
 *      bug-introducing commit, so prose *can* block — when it names an outcome.
 *   2. **SCOPE** — a finding must be attributable to the change under review. A
 *      declared `diff` finding whose cited file is NOT in the change's file set is
 *      reclassified as pre-existing (Google's origin-keyed deferral: *pre-existing*
 *      surrounding problem → file a bug; complexity *this change introduced* → resolve
 *      here). Prose about the change's own process/description has no shipped-behaviour
 *      surface and never blocks — the owner's measured pathology was three rounds of
 *      defects in a PR description's prose about its own process.
 *   3. **CEILING** — `decideRound()` applies the class's cap from the canonical
 *      `proportional-gates` §Review Cycles table (via `REVIEW_CYCLE_CAPS`, which
 *      `tier-config-parity.test.ts` pins against that table). At the ceiling: **land if
 *      no blocking finding remains, otherwise ESCALATE naming the blocker.** It never
 *      returns `land` with a blocking finding — that is the invariant this module
 *      exists to hold, and `review-scale.test.ts` drives it directly.
 *
 * ⛔ FAIL-CLOSED BY CONSTRUCTION, never by default. An ABSENT `origin` or an ABSENT `outcome`
 * leaves the finding BLOCKING (`malformed-blocking`), not an implicit nit — the loop only
 * ever gets SHORTER when a finding carries an EXPLICIT, checkable non-blocking declaration.
 * The ONE field whose absence defers is `file`: a `diff` finding that cites no file is not
 * attributable to the change and cannot be verified against it, so it is recorded and
 * reported back as unverifiable (`AGENTS.md` → "a finding that cites nothing is not
 * applicable"), never applied and never blocking. A finding is never dropped either way —
 * a follow-up is still recorded and still filed.
 *
 * What this does NOT do: it does not decide whether a review happens. A landing
 * requires `cyclesUsed >= 1` — at least one round — and the review step, the fresh
 * re-review dispatch and the `ai-review-gate` record are untouched. It bounds the
 * REPEAT, not the review.
 */

import { REVIEW_CYCLE_CAPS } from "./termination.ts";

/** The four `RISK_CLASS` values Step 3.6 resolves before dispatch. */
export type RiskClass = "low" | "low-medium" | "medium-high" | "high";

/**
 * Canonical caps, per `skills/proportional-gates/SKILL.md` §Review Cycles — the single
 * owner of these numbers. This table is a MIRROR of `REVIEW_CYCLE_CAPS`, not a second
 * source: the values are read from `termination.ts`, so a change to the canonical table
 * moves both, and `tier-config-parity.test.ts` fails if either drifts from the skill.
 *
 * Kept on ONE line so the mutation harness in `review-scale.test.ts` can substitute the
 * whole mapping (mutant M2: every class gets the widest cap) and prove the suite is not
 * vacuous about the proportionality it claims.
 */
const CAP_BY_CLASS: Record<RiskClass, number> = { low: REVIEW_CYCLE_CAPS.skip, "low-medium": REVIEW_CYCLE_CAPS.lowMedium, "medium-high": REVIEW_CYCLE_CAPS.mediumHigh, high: REVIEW_CYCLE_CAPS.high };

/** The adversarial domain's bound (`#838`), which can only ever TIGHTEN a class's cap. */
export const ADVERSARIAL_CAP = 2;

/**
 * Where a finding says it came from. `diff` is a claim that the finding is about a file
 * the change modifies — checked against `changedFiles`, never taken on trust.
 */
export type FindingOrigin = "diff" | "process" | "pre-existing" | "unstated";

/**
 * One finding, as a reviewer reports it. `severity` and `origin` are the reviewer's
 * CLAIM; `outcome` is the wrong outcome the finding can produce, or the literal
 * `"none"` when the author states there is none. Absent `outcome` is NOT `"none"` —
 * see `dispositionOf`.
 */
export interface ReviewFinding {
  severity?: string | null;
  origin?: string | null;
  /** The file the finding cites. Required for `origin: "diff"` to be checkable. */
  file?: string | null;
  /**
   * The named wrong outcome ("debts larger than the reported total", "silent wrong
   * result: the second claim is dropped"), or `"none"` when the author states the
   * finding cannot produce one.
   */
  outcome?: string | null;
  /** Human-facing text; never part of the decision. */
  description?: string | null;
  suggestion?: string | null;
}

/**
 * `blocking` — stops the landing and keeps the round alive (or escalates at the ceiling).
 * `follow_up` — recorded and filed as its own issue; never another round.
 * `malformed-blocking` — the finding cannot be dispositioned (an unknown origin, an
 *   absent outcome, a `diff` claim with no file). Treated as BLOCKING and reported, so a
 *   reviewer that omits the fields cannot silently defer its own finding.
 */
export type DispositionVerdict = "blocking" | "follow_up" | "malformed-blocking";

export interface Disposition {
  finding: ReviewFinding;
  verdict: DispositionVerdict;
  /** Why — printed in the review comment and in the cycle record. */
  reason: string;
}

export interface CapResolution {
  cap: number;
  /** Which cap was applied and why — never a bare number in the record. */
  basis: string;
}

export interface RoundInput {
  /** `RISK_CLASS` from Step 3.6. Unrecognised → the widest cap, and `basis` says so. */
  riskClass: string;
  /** Cycles ALREADY spent on this gate. A landing requires at least one. */
  cyclesUsed: number;
  /** This round's findings (the fresh scan's output). */
  findings: readonly ReviewFinding[];
  /** The change's file set (`gh pr diff --name-only`) — the attribution check. */
  changedFiles: readonly string[];
  /** The adversarial domain's `ADVERSARIAL_BOUND` (`#838`). */
  adversarial?: boolean;
}

export interface RoundDecision {
  decision: "continue" | "land" | "escalate";
  cap: number;
  capBasis: string;
  /** Findings that stop the landing; each names its wrong outcome. */
  blocking: Disposition[];
  /** Findings recorded and filed as owned issues; never another round. */
  followUps: Disposition[];
  /** One `[PROPORTIONAL]` line for the PR body when a landing rests on it. */
  disclosure: string | null;
  /** Plain words for the record — the decision is never reported as a bare label. */
  reason: string;
}

/**
 * The cap for a change's risk class, from the canonical table.
 *
 * Unrecognised `RISK_CLASS` takes the WIDEST cap (High) rather than a tight one, and
 * says so in `basis`: guessing small would silently truncate a large change's review,
 * which is the failure direction the repo's `PANEL_MAX` default already refuses. This is
 * a *loose* default, never a passing one — an unclassified change still escalates on any
 * blocking finding, and the basis line makes the omission visible.
 */
export function cycleCapForClass(riskClass: string, adversarial = false): CapResolution {
  const key = (riskClass || "").trim().toLowerCase() as RiskClass;
  const known = Object.prototype.hasOwnProperty.call(CAP_BY_CLASS, key);
  let cap = known ? CAP_BY_CLASS[key] : REVIEW_CYCLE_CAPS.high;
  let basis = known
    ? `proportional-gates §Review Cycles row "${key}" → ${cap} cycle(s)`
    : `RISK_CLASS "${riskClass || ""}" unrecognised — failing safe to the widest cap (high)`;

  if (adversarial) {
    if (cap > ADVERSARIAL_CAP) {
      cap = ADVERSARIAL_CAP;
      basis += `; tightened to the declared-threat-surface bound (${ADVERSARIAL_CAP}, #838)`;
    } else {
      basis += `; the adversarial bound (${ADVERSARIAL_CAP}) does not widen it`;
    }
  }
  return { cap, basis };
}

/**
 * Normalise a path for the attribution check: strip any number of leading `./` GROUPS, then
 * leading `/`, then whitespace. A single-`./` strip (`.replace(/^\.\//, "")`) disagrees with
 * itself on `././x`, and a character-set strip (`lstrip("./")`) also eats a leading dot from
 * a real path (`.github/workflows/ci.yml` → `github/…`). The doc twin in
 * `fixer-loop.md` §L6.1 must produce exactly this function's output — `review-scale.test.ts`
 * executes it and compares.
 */
function normalisePath(p: string): string {
  return p.trim().replace(/^(\.\/)+/, "").replace(/^\/+/, "");
}

/**
 * Decide ONE finding's disposition. First matching rule wins; the order is the rule.
 *
 *  1. `origin` absent/unknown → **malformed-blocking** (fail closed).
 *  2. `origin: "process"` → **follow_up**. The change's own description, commit
 *     message or prose about the review process has no shipped-behaviour surface, so
 *     it cannot name a wrong outcome. Resolved by DELETION (or a pointer to a checkable
 *     artefact), never by another wording round — this is the class that burned
 *     `#1595`'s rounds 3-5 until the passage was deleted.
 *  3. `origin: "pre-existing"` → **follow_up**, filed as an owned issue (origin-keyed
 *     deferral).
 *  4. `origin: "diff"` with no `file`, or a `file` NOT in `changedFiles` →
 *     **follow_up**, reason names the reclassification: a reviewer cannot claim the
 *     change for a file the change does not touch. This is the SCOPE CHECK.
 *  5. `outcome` absent → **malformed-blocking** (an unstaged claim is not a nit).
 *  6. `outcome: "none"` (explicitly) → **follow_up** (a suggestion, recorded).
 *  7. `severity` P3 → **follow_up** (the taxonomy's lowest band; no wrong outcome
 *     class). P0/P1/P2 with a named outcome → **blocking**.
 */
export function dispositionOf(finding: ReviewFinding, changedFiles: readonly string[]): Disposition {
  // Fail closed on an entry the disposition cannot READ. A non-object would otherwise throw (or,
  // worse, be skipped), and a finding that appears in neither list is a silent deferral — the
  // exact fail-open this module exists to prevent (review round 3).
  if (finding === null || typeof finding !== "object") {
    return {
      finding,
      verdict: "malformed-blocking",
      reason: "non-object finding (malformed — treated as blocking)",
    };
  }
  const origin = (finding.origin ?? "").trim().toLowerCase() as FindingOrigin;

  if (!origin) {
    return {
      finding,
      verdict: "malformed-blocking",
      reason: "no `origin` declared — a finding must state whether it is about the diff, the change's own process prose, or pre-existing code; treated as blocking until it does",
    };
  }
  if (origin === "process") {
    return {
      finding,
      verdict: "follow_up",
      reason: "about the change's own description/process prose — no shipped-behaviour surface; resolve by DELETION, not another round",
    };
  }
  if (origin === "pre-existing") {
    return {
      finding,
      verdict: "follow_up",
      reason: "pre-existing code the change does not touch — file as an owned issue (origin-keyed deferral)",
    };
  }
  if (origin !== "diff") {
    return {
      finding,
      verdict: "malformed-blocking",
      reason: `unknown \`origin\` "${finding.origin}" — expected diff|process|pre-existing; treated as blocking`,
    };
  }

  const claimed = (finding.file ?? "").trim();
  if (!claimed) {
    return {
      finding,
      verdict: "follow_up",
      reason: "declared as a diff finding but cites no file — not attributable to the change; file as an issue (a finding that cites nothing cannot be verified)",
    };
  }
  const changed = new Set(changedFiles.map(normalisePath).filter(Boolean));
  if (changed.size === 0) {
    // The attribution check cannot run against no file set, and "not attributable" would then
    // defer EVERY diff finding — a fail-open that defers real blockers (found in review round 2).
    // An empty changed-file set is UNAVAILABLE, not "the change touches nothing".
    return {
      finding,
      verdict: "malformed-blocking",
      reason: "the changed-file set is UNAVAILABLE — attribution cannot be checked, so the finding is treated as blocking (fail closed)",
    };
  }
  if (!changed.has(normalisePath(claimed))) {
    return {
      finding,
      verdict: "follow_up",
      reason: `cites "${claimed}", which this change does not modify — reclassified as pre-existing; file as an owned issue`,
    };
  }

  const outcome = finding.outcome;
  if (outcome === undefined || outcome === null || String(outcome).trim() === "") {
    return {
      finding,
      verdict: "malformed-blocking",
      reason: "no `outcome` declared — state the wrong outcome it can produce, or `outcome: none`; treated as blocking until it does",
    };
  }
  if (String(outcome).trim().toLowerCase() === "none") {
    return {
      finding,
      verdict: "follow_up",
      reason: "`outcome: none` — a suggestion about the change, recorded and filed; it cannot produce a wrong outcome",
    };
  }
  const severity = String(finding.severity ?? "").trim().toUpperCase();
  if (severity === "P3") {
    return {
      finding,
      verdict: "follow_up",
      reason: "P3 (the taxonomy's lowest band) — recorded and filed, never a blocking finding",
    };
  }
  return {
    finding,
    verdict: "blocking",
    reason: `about this change and names a wrong outcome ("${String(outcome).trim()}") — blocks the landing`,
  };
}

/**
 * Decide whether this round starts another round.
 *
 * `land` is returned ONLY when no blocking finding remains AND at least one round has
 * been spent. `cyclesUsed < 1` → `continue`: nothing may land on zero review rounds, so
 * the "a review happens" requirement is structurally outside this function's reach.
 */
export function decideRound(input: RoundInput): RoundDecision {
  const { cap, basis } = cycleCapForClass(input.riskClass, input.adversarial === true);
  const graded = (input.findings ?? []).map((f) => dispositionOf(f, input.changedFiles ?? []));
  const blocking = graded.filter((d) => d.verdict !== "follow_up");
  const followUps = graded.filter((d) => d.verdict === "follow_up");

  if ((input.cyclesUsed ?? 0) < 1) {
    return {
      decision: "continue",
      cap,
      capBasis: basis,
      blocking,
      followUps,
      disclosure: null,
      reason: "no review round has been spent on this gate — a landing cannot rest on zero rounds; dispatch the review",
    };
  }

  if (blocking.length > 0) {
    if ((input.cyclesUsed ?? 0) >= cap) {
      return {
        decision: "escalate",
        cap,
        capBasis: basis,
        blocking,
        followUps,
        disclosure: null,
        reason: `the change's ceiling is spent (${input.cyclesUsed}/${cap}) and ${blocking.length} blocking finding(s) remain — escalate naming them; this exit is NOT a landing and is never reported as clean`,
      };
    }
    return {
      decision: "continue",
      cap,
      capBasis: basis,
      blocking,
      followUps,
      disclosure: null,
      reason: `${blocking.length} blocking finding(s) within the ${cap}-cycle ceiling (${input.cyclesUsed}/${cap}) — fix and re-review with a FRESH reviewer`,
    };
  }

  // ⛔ THE CEILING CHECK — the proportional STOPPING rule. With no blocking finding
  // left, another round is not owed no matter how many non-blocking findings remain:
  // they are filed, not chased (LLVM's "limit the number of iterations … so the author
  // can make all the changes at once"; Chromium's "if there are bigger refactorings,
  // move them to a new CL"; Google's "favour approving once it definitely improves
  // overall code health, even if it isn't perfect"). Delete this branch and every
  // P2-only round loops forever — `review-scale.test.ts` mutant M1 asserts exactly that.
  if (blocking.length === 0 && (input.cyclesUsed ?? 0) >= 1) {
    const refs = followUps.length > 0 ? `<#issue,…|none>` : "none";
    return {
      decision: "land",
      cap,
      capBasis: basis,
      blocking,
      followUps,
      disclosure: `[PROPORTIONAL] cycles=${input.cyclesUsed} cap=${cap} blocking=0 follow-ups=${refs}`,
      reason:
        followUps.length > 0
          ? `no blocking finding remains; ${followUps.length} follow-up(s) recorded and filed as owned issues — the round does NOT start another round (${input.cyclesUsed}/${cap} cycles)`
          : `no blocking finding remains — land (${input.cyclesUsed}/${cap} cycles)`,
    };
  }

  return {
    decision: "continue",
    cap,
    capBasis: basis,
    blocking,
    followUps,
    disclosure: null,
    reason: `unreachable in the intended flow — treated as continue (${input.cyclesUsed}/${cap} cycles)`,
  };
}
