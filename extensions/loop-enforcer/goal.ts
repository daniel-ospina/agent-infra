/**
 * Goal Setting (O/I/T) + Task Decomposition — P1
 * 
 * Goal verification protocol on /loop start.
 * O/I/T fields in manifest: objective, indicators[], target_ambition.
 * Parent/child loop decomposition with V-level inheritance.
 */
import { writeFileSync, readFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";
import { execFileSync } from "node:child_process";

const LOOPS_DIR = join(homedir(), ".pi", "agent", "loops");

/**
 * Resolve a subject (team or role slug) from the swarm Supabase SOR via the
 * agent-infra helper scripts/swarm-org.mjs (issue #102 — supersedes the dead
 * eldato-era operations/subjects/*.yaml tree).
 * Env: SUPABASE_URL_ORG_DATA + SUPABASE_SERVICE_ROLE_KEY_ORG_DATA (swarm repo).
 * Degrades gracefully: returns null when the helper is missing or creds unset.
 */
function resolveSubject(slug: string): { team: string | null; role?: string } | null {
  try {
    const script = join(process.cwd(), "scripts", "swarm-org.mjs");
    if (!existsSync(script)) {
      console.warn(`[loop-enforcer] ⚠️ scripts/swarm-org.mjs not found in cwd — run from the agent-infra checkout to resolve "--for" subjects (swarm Supabase SOR).`);
      return null;
    }
    const out = execFileSync(
      "node", [script, "resolve-role", slug],
      { encoding: "utf-8", timeout: 5000, stdio: ["ignore", "pipe", "ignore"] },
    );
    const parsed = JSON.parse(out);
    if (!parsed.found) {
      // Fall back: treat slug as a team slug
      const teams = execFileSync(
        "node", [script, "list-teams"],
        { encoding: "utf-8", timeout: 5000, stdio: ["ignore", "pipe", "ignore"] },
      );
      const rows = JSON.parse(teams).teams || [];
      if (rows.some((t: { slug: string }) => t.slug === slug)) return { team: slug };
      return null;
    }
    return { team: parsed.team || null, role: parsed.role };
  } catch (e: any) {
    console.warn(`[loop-enforcer] ⚠️ Subject resolution failed (${e?.message || e}) — --for flag has no effect.`);
    return null;
  }
}



// Discriminated union: check fields only on deterministic variant
export type Indicator =
  | { name: string; type: "deterministic"; check_type: "exec" | "file_exists"; check: string; target: string; invert?: boolean }
  | { name: string; type: "llm_judgment"; target: string }
  | { name: string; type: "human_gate"; target: string };

export type LoopType = "completion" | "cron" | "trigger" | "continuous";

export interface GoalSpec {
  objective: string;
  indicators: Indicator[];
  target_ambition: "baseline" | "1.5x" | "10x" | "100x";
  loop_type: LoopType;
  task_type: string;
  verification_level: string;
  max_budget?: number;
  declared_budget_prediction?: number;
  team?: string;
  role?: string;
}

export function classifyGoal(goal: string): { task_type: string; verification_level: string } {
  const lower = goal.toLowerCase();

  // ── Task type detection (first-match wins) ──
  const taskPatterns: [RegExp, string][] = [
    [/implement|build|code|fix|refactor|deploy|test|migrate|component|function|api|endpoint|schema|query/i, "code"],
    [/write|content|article|blog|editorial|guide|faq|meta|seo|copy|headline/i, "content"],
    [/research|investigate|analyze|study|explore|compare|evaluate|audit|review\s*literature/i, "research"],
    [/strategy|plan|roadmap|positioning|gtm|pricing|competitive|market/i, "strategy"],
    [/design|prototype|mockup|wireframe|layout|css|style|visual/i, "design"],
  ];

  let task_type = "code";
  for (const [pattern, type] of taskPatterns) {
    if (pattern.test(lower)) {
      task_type = type;
      break;
    }
  }

  // ── V-level detection (highest match wins) ──
  let verification_level = "V1";

  if (/critical|production|security|auth|payment|migration|data\s*loss|breaking/i.test(lower)) {
    verification_level = "V2";
  }
  if (/platform|launch|release|enterprise|multi.*feature/i.test(lower)) {
    verification_level = "V3";
  }

  return { task_type, verification_level };
}

export function buildGoalSpec(args: string): GoalSpec {
  const ambition = args.includes("--ambition 10x") ? "10x"
    : args.includes("--ambition 100x") ? "100x"
    : args.includes("--ambition 1.5x") ? "1.5x"
    : "baseline";

  const loop_type: LoopType = args.includes("--type cron") ? "cron"
    : args.includes("--type trigger") ? "trigger"
    : args.includes("--type continuous") ? "continuous"
    : "completion";

  // Parse constraints: --constraint "value" (repeatable)
  const constraints: string[] = [];
  let constraintMatch;
  const constraintRegex = /--constraint\s+"([^"]+)"/g;
  while ((constraintMatch = constraintRegex.exec(args)) !== null) {
    constraints.push(constraintMatch[1]);
  }

  // Parse budget flags: --max-budget 20000 --prediction 5000
  const maxBudgetMatch = args.match(/--max-budget\s+(\d+)/);
  const predictionMatch = args.match(/--prediction\s+(\d+)/);
  const max_budget = maxBudgetMatch ? parseInt(maxBudgetMatch[1]) : undefined;
  const declared_budget_prediction = predictionMatch ? parseInt(predictionMatch[1]) : undefined;

  const { task_type, verification_level } = classifyGoal(args);

  // Parse subject: --for <role-slug> or --for <team-slug>
  const forMatch = args.match(/--for\s+(\S+)/);
  const forSlug = forMatch ? forMatch[1] : undefined;
  const resolved = forSlug ? resolveSubject(forSlug) : null;
  if (forSlug && !resolved) {
    console.warn(`[loop-enforcer] ⚠️ Subject "${forSlug}" not found in swarm Supabase SOR — --for flag has no effect.`);
  }
  const team = resolved?.team;
  const role = resolved?.role;

  return {
    objective: args.replace(/--[\w-]+\s+\S+/g, "").trim() || args.trim(),
    indicators: [],
    target_ambition: ambition,
    loop_type,
    task_type,
    verification_level,
    max_budget,
    declared_budget_prediction,
    team,
    role,
  };
}

export function isGoalAdvisory(): boolean {
  return true; // P1: advisory only — non-blocking, flag goals_unverified
}

export function populateGoalFields(manifest: Record<string, any>, spec: GoalSpec): void {
  manifest.objective = spec.objective;
  manifest.target_ambition = spec.target_ambition;
  manifest.indicators = spec.indicators;
  manifest.loop_type = spec.loop_type;
  manifest.task_type = spec.task_type;
  manifest.verification_level = spec.verification_level;
  manifest.max_budget = spec.max_budget;
  manifest.declared_budget_prediction = spec.declared_budget_prediction;
  if (spec.team || spec.role) {
    manifest.subject = { team: spec.team || "", role: spec.role };
  }
  manifest.goals_unverified = isGoalAdvisory();
}

export interface ChildLoopSpec {
  parent_loop_id: string;
  contribution_statement: string;
  task: string;
  v_level: string;
  subject?: { team: string; role?: string }; // ponytail: #5819 — inherit parent team+role
  session_id?: string; // ponytail: #5830 — inherit from parent
}

export function decomposeGoal(
  parentManifest: Record<string, any>,
  subTasks: string[]
): ChildLoopSpec[] {
  const parentVLevel = parentManifest.verification_level || "V1";
  const childVLevel = parentVLevel === "V3" || parentVLevel === "V4" ? "V2" : parentVLevel;

  return subTasks.map((task, i) => ({
    parent_loop_id: parentManifest.loop_id,
    contribution_statement: `Contributes to: ${parentManifest.objective || parentManifest.goal}`,
    task,
    v_level: childVLevel,
    // ponytail: inherit from parent (#5819, #5830)
    subject: parentManifest.subject || undefined,
    session_id: parentManifest.session_id,
  }));
}

export function spawnChildLoop(child: ChildLoopSpec): string {
  const slug = `${child.parent_loop_id}-child-${Date.now()}`;
  const manifest: Record<string, any> = {
    loop_id: slug,
    goal: child.task,
    parent_loop_id: child.parent_loop_id,
    contribution_statement: child.contribution_statement,
    verification_level: child.v_level,
    status: "running",
    cycles: [],
    goals_unverified: true,
    created_at: new Date().toISOString(),
    // ponytail: inherit team+role+session scoping from parent (#5819, #5830)
    ...(child.subject ? { subject: child.subject } : {}),
    ...(child.session_id ? { session_id: child.session_id } : {}),
  };
  const path = join(LOOPS_DIR, `${slug}.yaml`);
  writeFileSync(path, yamlDump(manifest), "utf-8");
  return slug;
}

function yamlDump(obj: Record<string, any>): string {
  const lines: string[] = [];
  for (const [k, v] of Object.entries(obj)) {
    if (Array.isArray(v)) {
      lines.push(`${k}:`);
      if (v.length === 0) lines.push("  []");
      else v.forEach((item: any) => lines.push(`  - ${JSON.stringify(item)}`));
    } else if (typeof v === "object" && v !== null) {
      lines.push(`${k}:`);
      for (const [sk, sv] of Object.entries(v)) {
        lines.push(`  ${sk}: ${JSON.stringify(sv)}`);
      }
    } else if (typeof v === "string") {
      lines.push(`${k}: "${v.replace(/"/g, '\\"')}"`);
    } else {
      lines.push(`${k}: ${v}`);
    }
  }
  return lines.join("\n") + "\n";
}

// ═══════════════════════════════════════════════════════════════════
// Goodhart's Law Challenge (from PR #4847)
// ═══════════════════════════════════════════════════════════════════

export interface GoalVerificationResult {
  verified: boolean;
  restated_goal: string;
  proposed_indicators: Indicator[];
  challenges: ChallengeFinding[];
  unverified_reason?: string;
}

export interface ChallengeFinding {
  indicator_name: string;
  risk: "goodhart" | "unmeasurable" | "ambiguous" | "gamed" | "narrow";
  description: string;
  mitigation?: string;
}

const GOODHART_PATTERNS: Array<{
  risk: ChallengeFinding["risk"];
  pattern: RegExp;
  description: string;
  mitigation: string;
}> = [
  {
    risk: "goodhart",
    pattern: /\b(count|number|amount|total)\s+of\b/i,
    description: "Counting-based indicator — agent may optimize for quantity over quality",
    mitigation: "Add a quality dimension (e.g., 'and at least 80% pass rate')",
  },
  {
    risk: "narrow",
    pattern: /\b(lines|tokens?|files?)\s+of\s+code\b/i,
    description: "Code-volume indicator — rewards verbosity, punishes simplicity",
    mitigation: "Replace with outcome-based indicator (e.g., 'acceptance criteria met')",
  },
  {
    risk: "ambiguous",
    pattern: /\b(good|better|improved?|enhanced?|nice|clean)\b/i,
    description: "Subjective adjective — not verifiable by independent agent",
    mitigation: "Replace with concrete, observable criterion (e.g., 'zero type errors')",
  },
  {
    risk: "unmeasurable",
    pattern: /\b(understand|learn|know|feel|appreciate)\b/i,
    description: "Internal state indicator — cannot be verified externally",
    mitigation: "Replace with behavioral output (e.g., 'writes summary doc with 3+ evidence sources')",
  },
  {
    risk: "gamed",
    pattern: /\b(all|every|always|never|100%)\b/i,
    description: "Absolute indicator — unreachable in practice, encourages gaming",
    mitigation: "Use threshold (e.g., '95% of cases' or 'no P0 regressions')",
  },
];

export function restateGoal(rawGoal: string): string {
  const goal = rawGoal.trim().replace(/^["']|["']$/g, "");
  return `Build: ${goal}`;
}

export function proposeIndicators(goal: string, taskType = "code"): Indicator[] {
  const base: Indicator[] = [];
  if (taskType === "code") {
    base.push(
      { name: "verifier_clean", type: "llm_judgment", target: "NO ISSUES FOUND from independent-context sub-agent" },
      { name: "typecheck_pass", type: "deterministic", check_type: "exec", check: "tsc --noEmit", target: "exit code 0" },
      { name: "tests_pass", type: "deterministic", check_type: "exec", check: "npm test", target: "exit code 0, no failures" },
    );
  } else if (taskType === "content") {
    base.push(
      { name: "verifier_clean", type: "llm_judgment", target: "NO ISSUES FOUND from independent-context sub-agent" },
    );
  } else {
    base.push({ name: "verifier_clean", type: "llm_judgment", target: "NO ISSUES FOUND from independent-context sub-agent" });
  }
  return base;
}

export function challengeIndicators(indicators: Indicator[], goal: string): ChallengeFinding[] {
  const findings: ChallengeFinding[] = [];
  for (const ind of indicators) {
    const text = `${ind.name} ${ind.target}`;
    for (const gp of GOODHART_PATTERNS) {
      if (gp.pattern.test(text)) {
        findings.push({ indicator_name: ind.name, risk: gp.risk, description: gp.description, mitigation: gp.mitigation });
        break;
      }
    }
  }
  return findings;
}

export function runGoalVerification(goal: string, taskType = "code"): GoalVerificationResult {
  const restated = restateGoal(goal);
  const indicators = proposeIndicators(goal, taskType);
  const challenges = challengeIndicators(indicators, goal);
  const verified = challenges.length === 0;
  return {
    verified,
    restated_goal: restated,
    proposed_indicators: indicators,
    challenges,
    unverified_reason: verified ? undefined : "Indicators flagged by Goodhart's Law challenge — review before proceeding",
  };
}

export function formatVerificationResult(result: GoalVerificationResult): string {
  const lines: string[] = ["## Goal Verification", "", `**Restated:** ${result.restated_goal}`, "", "**Indicators:**"];
  for (const ind of result.proposed_indicators) {
    lines.push(`- ${ind.name} (${ind.type}): ${ind.target}`);
  }
  if (result.challenges.length > 0) {
    lines.push("", "**⚠️ Challenges (Goodhart's Law):**");
    for (const c of result.challenges) {
      lines.push(`- [${c.risk}] ${c.indicator_name}: ${c.description}`);
      if (c.mitigation) lines.push(`  → Mitigation: ${c.mitigation}`);
    }
    lines.push("", "**Status:** goals_unverified (advisory — loop proceeds)");
  } else {
    lines.push("", "**Status:** goals_verified ✅");
  }
  return lines.join("\n");
}

// ═══════════════════════════════════════════════════════════════════
// Async Goal Verification Protocol (from PR #4849)
// ═══════════════════════════════════════════════════════════════════

export const GOALS_UNVERIFIED_FLAG = "goals_unverified";

export interface OIT {
  objective: string;
  indicators: Indicator[];
  target_ambition: string;
}

export interface GoalVerificationState {
  phase: "pending" | "restated" | "challenged" | "confirmed";
  oit: OIT;
  flags: string[];
}

export function goalVerificationPrompt(goal: string): string {
  return [
    "## Goal Verification (advisory)",
    "",
    "The loop enforcer requires goal verification before execution. Please complete both steps:",
    "",
    "### 1. RESTATE the objective",
    "Paraphrase the goal to confirm your understanding. Be specific — what exactly should be accomplished?",
    "",
    "### 2. CHALLENGE the indicators",
    "Propose measurable indicators that will determine success. Consider:",
    "- What must be true for this to be 'done'?",
    "- What would Goodhart's Law predict? (Which indicators could be gamed?)",
    "- Are there blind spots the indicators miss?",
    "",
    "Respond in this format:",
    "",
    "**Objective:** [your restated objective]",
    "",
    "**Indicators:**",
    "- [indicator 1 name]: [what it measures] → target: [pass condition]",
    "- [indicator 2 name]: [what it measures] → target: [pass condition]",
    "",
    "**Challenges:** [what could these indicators miss? Any Goodhart risks?]",
    "",
    "**Target Ambition:** [baseline | 1.5x | 10x | 100x]",
    "",
    `Goal: "${goal}"`,
    "",
    "[loop-enforcer] Goal verification is advisory at P1 — the loop proceeds even if unverified. " +
      'Confirm with "goals confirmed" or refine and re-confirm. Skip with "goals skip".',
  ].join("\n");
}

export function parseOITFromResponse(response: string): OIT | null {
  const objMatch = response.match(/\*\*Objective:\*\*\s*(.+?)(?:\n|$)/i);
  if (!objMatch) return null;
  const objective = objMatch[1].trim();
  const indicators: Indicator[] = [];
  const indRegex = /[-*]\s*(?:`)?(\w[\w\s]*?)(?:`)?\s*:\s*(.+?)\s*→\s*target:\s*(.+?)(?:\n|$)/gi;
  let indMatch;
  while ((indMatch = indRegex.exec(response)) !== null) {
    indicators.push({ name: indMatch[1].trim(), type: "llm_judgment", target: indMatch[3].trim() });
  }
  if (indicators.length === 0) {
    const simpleInd = /[-*]\s*(?:`)?(\w[\w\s]*?)(?:`)?\s*:\s*(.+?)(?:\n|$)/gi;
    while ((indMatch = simpleInd.exec(response)) !== null) {
      const name = indMatch[1].trim();
      if (name === "Challenges" || name === "Target" || name === "Objective") continue;
      indicators.push({ name, type: "llm_judgment", target: indMatch[2].trim() });
    }
  }
  const ambitionMatch = response.match(/\*\*Target Ambition:\*\*\s*(.+?)(?:\n|$)/i);
  const target_ambition = ambitionMatch?.[1]?.trim() ?? "1.5x";
  return { objective, indicators, target_ambition };
}

export function detectUserConfirmation(message: string): "confirmed" | "refine" | "skip" | null {
  const lower = message.toLowerCase().trim();
  if (/^goals?\s*skip$/i.test(lower)) return "skip";
  if (/skip\s+goal\s+verif/i.test(lower)) return "skip";
  if (/^goals?\s*confirmed$/i.test(lower)) return "confirmed";
  if (/^confirmed/i.test(lower) && lower.length < 30) return "confirmed";
  if (/^lgtm/i.test(lower) && lower.length < 10) return "confirmed";
  if (/^looks?\s*good/i.test(lower) && lower.length < 20) return "confirmed";
  if (lower.startsWith("add ") || lower.startsWith("change ") || lower.startsWith("remove ")) return "refine";
  if (lower.includes("should also") || lower.includes("instead of")) return "refine";
  return null;
}

export function detectEndCommand(message: string): boolean {
  // ponytail: co-located message detectors for the input hook
  const trimmed = message.trim();
  return trimmed === "/end" || /^\/end\s/.test(trimmed);
}

export function initialVerificationState(goal: string): GoalVerificationState {
  return {
    phase: "pending",
    oit: { objective: goal, indicators: [], target_ambition: "1.5x" },
    flags: [GOALS_UNVERIFIED_FLAG],
  };
}
