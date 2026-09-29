// skill-enforcer.ts — blocks git/MCP ops unless relevant skill was read.
// AGENTS.md §Skill Reading Protocol enforcement.
//
// ── DEPLOYED LAYOUT (read before changing any path constant) ──────────────
// pi loads global extensions from `~/.pi/agent/extensions/*.ts`, which are
// SYMLINKS into this repo, using jiti (not Node's native loader). jiti keeps
// the SYMLINK path in `__dirname`/`__filename`, so `__dirname`-relative assets
// resolve NEXT TO THE SYMLINK (e.g. `~/.pi/agent/enforcement/dangerous-ops.txt`,
// which nothing creates) while the extension still reports `✅ Loaded` — the
// #1321 fail-open. `realpathSync(__filename)` recovers the real module location
// under jiti AND Node's native loader; use MODULE_DIR/REPO_DIR, never `__dirname`.
//
// ── READ IDENTITY IS A NAME, NOT A PATH FRAGMENT (#1322) ──────────────────
// pi serves skills from `~/.pi/agent/skills/<name>/SKILL.md` (real dirs);
// consumer repos keep them at `operations/skills/` or `.agents/skills/`;
// agent-infra at `skills/`. Keying `readFiles` by a path built from ONE prefix
// meant a read through the path pi actually advertises never registered. The
// key is now the canonical skill NAME, resolved only from a trusted root.

import type { ExtensionAPI, ToolCallEventResult } from "@earendil-works/pi-coding-agent";
import { readFileSync, writeFileSync, existsSync, mkdirSync, realpathSync } from "node:fs";
import { resolve, join, dirname, isAbsolute } from "node:path";
import { homedir } from "node:os";
import { isPrintMode } from "./shared/print-mode.js";
import { register } from "./shared/health.js";

// Inline copy of pi's `isToolCallEventType` (#1321). pi's extension loader
// resolves the runtime package from its own bundled module table, but a suite
// running on a bare checkout has no node_modules — and this extension's gate
// suite must run there. The predicate is one line in pi
// (dist/core/extensions/types.js: `return event.toolName === toolName`) and the
// same inline is already shipped by extensions/sequence-enforcer/index.ts:59.
// Drift guard: if a pi upgrade changes the predicate, the parity pin belongs in
// an SDK-bearing suite (#966) — tracked with the shared-helper extraction.
function isToolCallEventType(toolName: string, event: unknown): boolean {
  return (event as { toolName?: unknown })?.toolName === toolName;
}

// ── Real module location ────────────────────────────
// See the DEPLOYED LAYOUT note at the top of this file. The try/catch keeps a
// deleted/unreadable module from crashing the extension; the manifest guard
// below still fires loudly in that case.
function realModuleDir(): string {
  try {
    return dirname(realpathSync(__filename));
  } catch {
    return __dirname;
  }
}

export const MODULE_DIR = realModuleDir();
export const REPO_DIR = resolve(MODULE_DIR, "..");

// ── Skill read persistence across sessions ──────────
// ponytail: persist readFiles to ~/.pi/agent/skill-reads.json.
// Restore on session_start for reads in the last 24h. Eliminates
// re-read friction after reload (#7416).
const DEFAULT_SKILL_READS_FILE = join(homedir(), ".pi", "agent", "skill-reads.json");
let SKILL_READS_FILE = DEFAULT_SKILL_READS_FILE;
const READ_PERSIST_TTL_MS = 24 * 60 * 60 * 1000; // 24 hours

interface SkillReadEntry {
  file: string;
  readAt: number;
}

// Test seam: redirect BOTH the file and its directory, so a suite can never
// create or write the real ~/.pi/agent (#1321 review — "persistence row").
export function _setSkillReadsFileForTest(path: string | null): void {
  SKILL_READS_FILE = path ?? DEFAULT_SKILL_READS_FILE;
}
export function _skillReadsFile(): string {
  return SKILL_READS_FILE;
}

function persistReadFiles(): void {
  try {
    const now = Date.now();
    const entries: SkillReadEntry[] = [];
    for (const file of readFiles) {
      entries.push({ file, readAt: now });
    }
    // Merge with existing entries, keep only those within TTL. Existing entries
    // may predate the name-keyed format (a path string), so normalise them too.
    let existing: SkillReadEntry[] = [];
    try { existing = JSON.parse(readFileSync(SKILL_READS_FILE, "utf-8")); } catch { /* absent or corrupt — rewritten below */ }
    if (!Array.isArray(existing)) existing = [];
    const merged = new Map<string, number>();
    for (const e of [...existing, ...entries]) {
      if (!e || typeof e.readAt !== "number") continue;
      if (now - e.readAt >= READ_PERSIST_TTL_MS) continue;
      const key = skillNameFromPersistedEntry(String(e.file ?? ""));
      if (!key) continue;
      merged.set(key, Math.max(merged.get(key) ?? 0, e.readAt));
    }
    mkdirSync(dirname(SKILL_READS_FILE), { recursive: true });
    writeFileSync(SKILL_READS_FILE, JSON.stringify([...merged.entries()].map(([file, readAt]) => ({ file, readAt }))));
  } catch { /* best-effort */ }
}

function restorePersistedReads(): number {
  let restored = 0;
  try {
    if (!existsSync(SKILL_READS_FILE)) return 0;
    const parsed = JSON.parse(readFileSync(SKILL_READS_FILE, "utf-8"));
    if (!Array.isArray(parsed)) {
      console.error(`[skill-enforcer] ⚠️  ${SKILL_READS_FILE} is not a JSON array — persisted reads not restored`);
      return 0;
    }
    const now = Date.now();
    for (const e of parsed) {
      if (!e || typeof e.readAt !== "number") continue;
      if (now - e.readAt >= READ_PERSIST_TTL_MS) continue;
      const name = skillNameFromPersistedEntry(String(e.file ?? ""));
      if (!name) {
        console.error(`[skill-enforcer] ⚠️  ignoring unresolvable persisted read ${JSON.stringify(e.file)} in ${SKILL_READS_FILE}`);
        continue;
      }
      readFiles.add(name);
      restored++;
    }
    if (restored > 0) console.log(`[skill-enforcer] 📂 Restored ${restored} skill reads from previous session`);
  } catch (err) {
    console.error(`[skill-enforcer] ⚠️  ${SKILL_READS_FILE} is unreadable or corrupt (${(err as Error).message}) — persisted reads not restored`);
  }
  return restored;
}

/**
 * A persisted entry is either a canonical skill name (current format) or a path
 * that canonicalises to one (legacy format). A bare name is accepted ONLY when a
 * trusted skill root actually holds a `SKILL.md` for it, so a hand-written
 * `skill-reads.json` cannot name an arbitrary skill (#1321 review, T13).
 */
function skillNameFromPersistedEntry(entry: string): string | null {
  if (!entry) return null;
  const name = canonicalSkillName(entry) ?? (/^[^/\\]+$/.test(entry) ? entry : null);
  if (!name) return null;
  // A trusted root must ACTUALLY hold the SKILL.md. Accepting a path-shaped
  // entry on shape alone (canonicalSkillName never touches the filesystem) let
  // `…/skills/<ghost>/SKILL.md` restore silently (#1321 review, T13/P1) — the
  // bare-name branch was the only one guarded.
  return skillFileFor(name) ? name : null;
}

// Dual-support: check AGENT_* first, then ELDATO_* (Phase 1 — #7549)
function _getEnv(name: string): string | undefined {
  return process.env[`AGENT_${name}`] ?? process.env[`ELDATO_${name}`];
}
function _isBypassEnv(): boolean {
  return process.env.SKILL_ENFORCER_DISABLED === "1" || _getEnv("ALLOW_MAIN_EDITS") === "1";
}
// Prefix override (Phase 1 default: operations/skills/). DISPLAY only since
// #1322 — never the source of truth for read-tracking. It may also name an extra
// skill ROOT, but only as a LAYOUT SHAPE resolved under a trusted base, which is
// why an ABSOLUTE value is refused: `resolve(base, "/tmp")` discards the base
// and names a shared directory instead of a shape (#1321 review, T7/P0).
const SKILLS_PREFIX = _getEnv("SKILLS_PREFIX") ?? "operations/skills/";

// ── The SKILLS_PREFIX override: a SHAPE under a base, never a directory ──────
// A prefix names a layout shape such as `operations/skills/`, resolved UNDER a
// trusted base. Three shapes are refused because each widens trust rather than
// describing a shape (#1321 review, T7/P0 + cycle-2 P2):
//   - a BLANK value names nothing;
//   - an ABSOLUTE value discards the base it was resolved against
//     (`resolve(base, "/tmp")` IS `/tmp`), so it names a shared directory — and
//     `resolve(base, "/")` normalises to "", which makes
//     `candidate.startsWith(root + "/")` accept EVERY absolute path;
//   - a RELATIVE value that resolves to the base itself or escapes it
//     (`.`, `..`, `../../../tmp`) widens the root set to a directory that is not
//     a skills shape at all — this is what closed the cycle-2 residual.
// Each refusal is reported from reportManifestState, never silently dropped.
function prefixRefusal(raw: string, base: string): string | null {
  const quoted = JSON.stringify(raw);
  if (raw.trim() === "") return `SKILLS_PREFIX=${quoted} is blank — refused as a trusted skill root: a prefix must name a directory shape such as "operations/skills/".`;
  if (isAbsolute(raw)) return `SKILLS_PREFIX=${quoted} is absolute — refused as a trusted skill root: a prefix names a layout SHAPE resolved UNDER a trusted base, so it may not name a shared directory or the filesystem root.`;
  const resolved = normalizePath(resolve(base, raw));
  const b = normalizePath(base);
  if (resolved === b || !resolved.startsWith(`${b}/`)) {
    return `SKILLS_PREFIX=${quoted} resolves to ${resolved}, which is not a directory UNDER ${b} — refused as a trusted skill root.`;
  }
  return null;
}
const PREFIX_OVERRIDE_RAW = _getEnv("SKILLS_PREFIX") ?? null;
const PREFIX_OVERRIDE_WARNING: string | null = PREFIX_OVERRIDE_RAW ? prefixRefusal(PREFIX_OVERRIDE_RAW, REPO_DIR) : null;
const PREFIX_OVERRIDE: string | null = PREFIX_OVERRIDE_RAW && !PREFIX_OVERRIDE_WARNING ? PREFIX_OVERRIDE_RAW : null;

// ── Skill roots: layout-independent read identity (#1322) ───────────────
// A read is only recognised under a TRUSTED BASE, in one of the KNOWN shapes.
// An unanchored `…/skills/<n>/SKILL.md` match would let any agent-writable
// directory (`/tmp/evil/skills/commit-workflow/SKILL.md`) satisfy every gate.
const SKILL_ROOT_SHAPES: string[][] = [
  ["skills"],             // <repo>/skills                 (agent-infra)
  ["operations", "skills"], // <repo>/operations/skills     (eldato)
  [".agents", "skills"],  // <repo>/.agents/skills         (hard-link farm)
  [".pi", "skills"],      // <repo>/.pi/skills             (pi project skills)
];

function normalizePath(p: string): string {
  return resolve(p).replace(/\\/g, "/").replace(/\/+$/, "");
}

/** Absolute skill-root directories, pi-served first. Recomputed per call (cwd and env can change). */
export function skillRoots(): string[] {
  const roots: string[] = [];
  const add = (p: string) => {
    const n = normalizePath(p);
    // A DEGENERATE root turns the trusted-root check inside out: `resolve(cwd,
    // "/")` normalises to "", and `candidate.startsWith("" + "/")` accepts
    // EVERY absolute path — so a stray override would make
    // `/tmp/evil/skills/<n>/SKILL.md` satisfy every gate (#1321 review, T7/P0).
    // A trusted root must name a real directory, never the filesystem root.
    if (!n || n === "/") return;
    if (!roots.includes(n)) roots.push(n);
  };
  // pi's own roots — the paths it advertises to the model.
  add(join(homedir(), ".pi", "agent", "skills"));
  add(join(homedir(), ".pi", "skills"));
  // Repo-rooted layouts.
  const bases: string[] = [process.cwd(), REPO_DIR];
  const infra = process.env.AGENT_INFRA_PATH ?? process.env.ELDATO_INFRA_PATH;
  if (infra) bases.push(infra);
  for (const base of bases) {
    for (const shape of SKILL_ROOT_SHAPES) add(resolve(base, ...shape));
  }
  // Explicit layout-shape override (`operations/skills/` by default is a
  // FALLBACK, only consulted when the env var is actually set). Re-checked per
  // base here because a prefix can be a legitimate shape under ONE base and
  // escape another; the load-time warning reports the REPO_DIR verdict.
  if (PREFIX_OVERRIDE) {
    for (const base of [process.cwd(), REPO_DIR]) {
      if (!prefixRefusal(PREFIX_OVERRIDE, base)) add(resolve(base, PREFIX_OVERRIDE));
    }
  }
  return roots;
}

/** First existing `<root>/<name>/SKILL.md`, or null. */
export function skillFileFor(name: string): string | null {
  if (!name) return null;
  for (const root of skillRoots()) {
    const candidate = `${root}/${name}/SKILL.md`;
    if (existsSync(candidate)) return candidate;
  }
  return null;
}

const DISPLAY_CACHE = new Map<string, string>();

/**
 * The path to print in a block reason or a nudge. First EXISTING candidate, in
 * the order pi-served → repo → consumer → env prefix; the legacy prefix is the
 * last-resort text so a message is never empty (#1322 review — the old text
 * pointed at `operations/skills/…`, which does not exist in agent-infra).
 */
export function skillDisplayPath(name: string): string {
  const cached = DISPLAY_CACHE.get(name);
  if (cached) return cached;
  const found = skillFileFor(name);
  const chosen = found ?? `${SKILLS_PREFIX}${name}/SKILL.md`;
  DISPLAY_CACHE.set(name, chosen);
  return chosen;
}

/**
 * Canonical skill identity: the directory basename owning the `SKILL.md`, from
 * any trusted root. `null` when the path is not a skill file under a trusted
 * root (or not a `SKILL.md` at all). Both the literal (resolved-against-cwd)
 * path and its realpath are tried, so a consumer's symlinked `skills/` reachable
 * through neither trusted base still registers.
 */
export function canonicalSkillName(rawPath: string): string | null {
  if (!rawPath) return null;
  const candidates: string[] = [];
  const literal = normalizePath(String(rawPath));
  candidates.push(literal);
  try {
    const real = normalizePath(realpathSync(String(rawPath)));
    if (real !== literal) candidates.push(real);
  } catch { /* path does not exist — the literal candidate is enough */ }
  const roots = skillRoots();
  for (const candidate of candidates) {
    if (!candidate.endsWith("/SKILL.md")) continue;
    for (const root of roots) {
      if (!candidate.startsWith(`${root}/`)) continue;
      const parts = candidate.slice(root.length + 1).split("/");
      if (parts[parts.length - 1] !== "SKILL.md") continue;
      const name = parts[parts.length - 2];
      if (name && name !== "." && name !== "..") return name;
    }
  }
  return null;
}

// ── Dangerous-ops manifest (#5558 / #1321) ──────────
// Resolution is against the REAL module location (see the header). The env
// fallback exists only for a COPIED extension with no sibling `enforcement/`;
// it never overrides a manifest that sits next to the module.
export const MANIFEST_RESOLUTION = resolveManifestPath();
export const MANIFEST_PATH = MANIFEST_RESOLUTION.path;

export function resolveManifestPath(
  env: Record<string, string | undefined> = process.env,
): { path: string; source: "module" | "env-fallback" } {
  const sibling = resolve(REPO_DIR, "enforcement", "dangerous-ops.txt");
  if (existsSync(sibling)) return { path: sibling, source: "module" };
  const infra = env.AGENT_INFRA_PATH ?? env.ELDATO_INFRA_PATH;
  if (infra) {
    const candidate = resolve(infra, "enforcement", "dangerous-ops.txt");
    if (existsSync(candidate)) return { path: candidate, source: "env-fallback" };
  }
  return { path: sibling, source: "module" };
}

export interface ManifestRule {
  patterns: RegExp[];
  mode: "hard" | "nudge";
  message?: string;
}

export interface ManifestLoad {
  /** Keyed by skill name; each non-comment manifest line is its OWN rule. */
  rules: Record<string, ManifestRule[]>;
  /** false when the manifest is missing, empty, or carries any unusable line. */
  ok: boolean;
  error?: string;
  warnings: string[];
}

/**
 * Parse the manifest. One rule per non-comment line — a repeated skill name
 * APPENDS (it used to clobber, silently dropping `commit-workflow`'s git gate
 * behind its `gh pr review` line, #1321). Every defect is reported and makes the
 * load `!ok`: a missing/empty/defective manifest must never read as loaded.
 */
export function loadManifest(path: string): ManifestLoad {
  const warnings: string[] = [];
  const rules: Record<string, ManifestRule[]> = {};
  if (!existsSync(path)) return { rules, ok: false, error: `manifest not found at ${path}`, warnings };
  let raw: string;
  try {
    raw = readFileSync(path, "utf-8");
  } catch (err) {
    return { rules, ok: false, error: `manifest unreadable at ${path}: ${(err as Error).message}`, warnings };
  }

  let lineNo = 0;
  let defects = 0;
  for (const line of raw.split("\n")) {
    lineNo += 1;
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const fields = trimmed.split("#");
    if (fields.length > 4) {
      defects += 1;
      warnings.push(`${path}:${lineNo} — malformed line (>4 '#'-separated fields); NOT enforced`);
      continue;
    }
    const skillName = (fields[0] ?? "").trim();
    const patternStr = (fields[1] ?? "").trim();
    const modeField = (fields[2] ?? "").trim();
    const messageField = (fields[3] ?? "").trim();
    if (!skillName) {
      defects += 1;
      warnings.push(`${path}:${lineNo} — line has no skill name; NOT enforced`);
      continue;
    }
    // An unrecognised mode must be a DEFECT, not a silent downgrade to nudge:
    // `HARD` (or a typo) would otherwise make the manifest say "arm this" while
    // the enforcer enforces less — the same class as the duplicate-line bug
    // (#1321 review). The real manifest always spells the mode exactly.
    if (modeField !== "hard" && modeField !== "nudge") {
      defects += 1;
      warnings.push(
        `${path}:${lineNo} — entry "${skillName}" has an unrecognised mode ${JSON.stringify(modeField)} (expected "hard" or "nudge"); NOT enforced`,
      );
      continue;
    }
    let patterns: RegExp[] = [];
    if (!patternStr) {
      defects += 1;
      warnings.push(`${path}:${lineNo} — entry "${skillName}" has no pattern; it can never gate anything and is NOT enforced`);
    } else {
      try {
        patterns = [new RegExp(patternStr, "i")];
      } catch (err) {
        defects += 1;
        warnings.push(`${path}:${lineNo} — entry "${skillName}" has an invalid pattern (${patternStr}): ${(err as Error).message}`);
      }
    }
    if (patterns.length === 0) continue;
    const rule: ManifestRule = {
      patterns,
      mode: modeField,
      message: messageField || undefined,
    };
    (rules[skillName] ??= []).push(rule);
  }

  if (Object.keys(rules).length === 0) {
    return { rules, ok: false, error: `manifest at ${path} has 0 entries`, warnings };
  }
  if (defects > 0) {
    return { rules, ok: false, error: `manifest at ${path} has ${defects} unusable line(s)`, warnings };
  }
  return { rules, ok: true, warnings };
}

export const MANIFEST_LOAD = loadManifest(MANIFEST_PATH);
const MANIFEST = MANIFEST_LOAD.rules;
export const MANIFEST_RULES = MANIFEST;

/** Unique skills (the gate count the issue's Target names) and total rules. */
export function manifestCounts(load: ManifestLoad = MANIFEST_LOAD): { skills: number; rules: number } {
  const rules = Object.values(load.rules).reduce((n, list) => n + list.length, 0);
  return { skills: Object.keys(load.rules).length, rules };
}

/**
 * The banner. A failed load NEVER produces a `✅` line (#1321) — the count is
 * reported as unusable instead of as a healthy 0.
 */
export function manifestBanner(load: ManifestLoad, path: string): string {
  const { skills, rules } = manifestCounts(load);
  if (load.ok) {
    return `[skill-enforcer] ✅ Loaded — enforcing ${skills} skill gates from manifest (${rules} rules) at ${path}`;
  }
  // A defective manifest is NOT the same as an empty one. With usable rules left
  // the gates are still ARMED and still blocking, so `❌ NOT ENFORCING` would
  // tell an operator the opposite of the truth (#1321 cycle-2 review) — it is
  // reserved for the case where nothing at all is enforced.
  if (skills === 0) {
    return `[skill-enforcer] ❌ NOT ENFORCING — ${load.error} (resolved from ${path}); no usable rule — every gate is off`;
  }
  return `[skill-enforcer] ⚠️ DEGRADED — ${load.error} (resolved from ${path}); ${skills} skill gate(s) / ${rules} rule(s) STILL ARMED`;
}

// Emitted UNCONDITIONALLY (never gated by isPrintMode) — headless `pi -p`
// sub-agents are exactly the sessions that run git operations.
export function reportManifestState(): void {
  if (PREFIX_OVERRIDE_WARNING) console.error(`[skill-enforcer] ⚠️  ${PREFIX_OVERRIDE_WARNING}`);
  for (const warning of MANIFEST_LOAD.warnings) console.error(`[skill-enforcer] ⚠️  ${warning}`);
  if (MANIFEST_RESOLUTION.source === "env-fallback") {
    console.error(`[skill-enforcer] ⚠️  manifest resolved from AGENT_INFRA_PATH/ELDATO_INFRA_PATH (${MANIFEST_PATH}) — no manifest sits next to the module; a stale or different checkout may be in force`);
  }
  if (!MANIFEST_LOAD.ok) console.error(manifestBanner(MANIFEST_LOAD, MANIFEST_PATH));
}
reportManifestState();

const readFiles = new Set<string>();

// Per-skill bypass counter — tracks how many times each skill gate has been bypassed this session.
// Key: skill name (e.g. "research"), Value: bypass count.
// Resets at session_start.
const bypassCounts = new Map<string, number>();

// Nudge thresholds
const NUDGE_REMINDER_MAX = 1;    // 0-1 bypasses: tool-result injection
const NUDGE_CONFIRM_MAX = 3;     // 2-3 bypasses: confirmation gate
// 4+ bypasses: hard block

// Nudge messages per skill
const NUDGE_MESSAGES: Record<string, string> = {
  "research": "💡 Per AGENTS.md §Research Discipline, use the research skill for non-trivial investigation. The research skill provides problem reframing, domain detection, adversarial queries, and cost gating.",
  "debug-workflow": "⚠️ debug-workflow/SKILL.md not read. Systematic root-cause diagnosis prevents regressions. Guessing at a fix without structured debugging is the #1 source of rework.",
};

// Track last tool call for tool-result injection.
// Queue-based to handle batched tool calls safely (Pi is sequential today but this guards future parallelism).
const pendingNudges: Array<{ toolName: string; input: Record<string, unknown> }> = [];

// Prerequisite chains (#7198) — reading a routing skill creates a
// contract: the dispatched workflow must also be read before write/edit.
// trackFiles: skill names whose reads this chain needs tracked (#7474) —
// these left the dangerous-ops manifest (they're not dangerous-ops), so
// read-tracking for them lives here instead.
const PREREQUISITES: Record<string, { requiredAny: string[]; blockTools: string[]; trackFiles?: string[] }> = {
  "issue-workflow": {
    requiredAny: ["project-workflow", "task-workflow", "task-workflow-standard", "epic-workflow"],
    blockTools: ["write", "edit"],
    trackFiles: ["project-workflow", "task-workflow", "task-workflow-standard", "epic-workflow"],
  },
  "writing-plans": {
    requiredAny: ["issue-scoping"],
    blockTools: ["write", "edit"],
  },
  "executing-plans": {
    requiredAny: ["writing-plans"],
    blockTools: ["write", "edit"],
  },
};

function isPrereqTracked(name: string): boolean {
  for (const [skillName, prereq] of Object.entries(PREREQUISITES)) {
    if (skillName === name) return true;
    if ((prereq.trackFiles ?? []).includes(name)) return true;
    if (prereq.requiredAny.includes(name)) return true;
  }
  return false;
}

// ── Audit logging ───────────────────────────────────
function logNudgeEvent(type: "fired" | "complied" | "bypassed" | "blocked", skill: string, tool: string, count: number) {
  const event = JSON.stringify({
    event: `nudge_${type}`,
    skill,
    tool,
    level: count <= NUDGE_REMINDER_MAX ? "reminder" : count <= NUDGE_CONFIRM_MAX ? "confirmation" : "hard_block",
    bypassCount: count,
    timestamp: new Date().toISOString(),
  });
  console.log(`[skill-enforcer] 📊 ${event}`);
}

export default function (pi: ExtensionAPI) {
  pi.on("session_start", async (_event, _ctx) => {
    readFiles.clear();
    restorePersistedReads();
    bypassCounts.clear();
    pendingNudges.length = 0;
    // Loud again here: the module-load line may have scrolled out of the log.
    reportManifestState();
    // ponytail: AGENT_ALLOW_MAIN_EDITS / ELDATO_ALLOW_MAIN_EDITS also bypasses skill-enforcer (not just worktree-guard), #7470 / #7549
    if (_isBypassEnv()) {
      console.log(`[skill-enforcer] ⏸️  Disabled`);
    }
  });

  pi.on("session_shutdown", async (_event, _ctx) => { persistReadFiles(); readFiles.clear(); bypassCounts.clear(); pendingNudges.length = 0; });

  // ── before_agent_start: proactive skill nudges ──
  // ponytail: scan the user's prompt for intent keywords and remind them to
  // read the relevant skill BEFORE they hit the gate (#7489). Fires once per
  // user turn — tool-result continuations have empty prompt and are skipped.
  pi.on("before_agent_start", async (event, _ctx) => {
    if (_isBypassEnv()) return;
    const prompt = (event as any).prompt ?? (event as any).userPrompt ?? "";
    if (!prompt) return;

    type Nudge = { keywords: RegExp; skill: string; hint: string };
    const nudges: Nudge[] = [
      { keywords: /worktree|git\s+worktree/i, skill: "using-git-worktrees", hint: "Creating worktrees?" },
      { keywords: /migration|RLS\b|supabase|apply_migration/i, skill: "supabase", hint: "Supabase schema changes?" },
      { keywords: /\bcommit\b|\bpush\b|\bmerge\b|PR\b|pull\s+request/i, skill: "commit-workflow", hint: "Committing or merging?" },
      { keywords: /issue\s+create|github\s+issue/i, skill: "issue-creation", hint: "Creating a GitHub issue?" },
    ];
    for (const { keywords, skill, hint } of nudges) {
      if (!keywords.test(prompt)) continue;
      if (readFiles.has(skill)) continue; // already read this session (canonical name, #1322)
      const file = skillDisplayPath(skill);
      return { message: { customType: "skill-enforcer-nudge", content: `💡 [skill-enforcer] ${hint} Read \`${file}\` first — the skill ensures safe, gated operations.`, display: true } };
    }
  });

  // ── Track reads ────────────────────────────────────
  pi.on("tool_call", async (event, _ctx) => {
    if (!isToolCallEventType("read", event)) return undefined;
    const path = String((event.input as any)?.path ?? "");
    // Canonical identity (#1322): the same skill read through any trusted root
    // registers the SAME key, so the gate is satisfiable by following the
    // instructions the model is actually given.
    const name = canonicalSkillName(path);
    if (!name) return undefined;
    readFiles.add(name);
    if (MANIFEST[name]) console.log(`[skill-enforcer] 📖 ${name} read (manifest)`);
    else if (isPrereqTracked(name)) console.log(`[skill-enforcer] 📖 ${name} read (prereq)`);
    persistReadFiles();
    return undefined;
  });

  // ── Block git/MCP ops ─────────────────────────────
  pi.on("tool_call", async (event, _ctx): Promise<ToolCallEventResult | undefined> => {
    // ponytail: AGENT_ALLOW_MAIN_EDITS / ELDATO_ALLOW_MAIN_EDITS also bypasses skill-enforcer, #7470 / #7549
    if (_isBypassEnv()) {
      return undefined;
    }

    // Prerequisite chains: block write/edit if routing skill read but no dispatch (#7220)
    const toolName = (event as any).toolName ?? "";
    if (toolName === "write" || toolName === "edit") {
      for (const [skillName, prereq] of Object.entries(PREREQUISITES)) {
        if (!prereq.blockTools.includes(toolName)) continue;
        if (!readFiles.has(skillName)) continue;
        const satisfied = prereq.requiredAny.some(name => readFiles.has(name));
        if (satisfied) continue;
        const input = (event.input as Record<string, unknown>) ?? {};
        if (input.confirm === `prereq:${skillName}`) {
          console.log(`[skill-enforcer] 🔓 Prerequisite bypassed: ${skillName}`);
          return undefined;
        }
        const reason = [
          `⛔ Pipeline gate — ${skillName}/SKILL.md was read but no dispatched workflow`,
          `  (${prereq.requiredAny.join("/")}) was read this session.`,
          `  → Re-invoke with confirm="prereq:${skillName}" to bypass.`,
        ].join("\n");
        console.log(`[skill-enforcer] 🚫 Prerequisite block: ${skillName} → ${toolName}`);
        return { block: true, reason };
      }
      return undefined;
    }

    let cmd = "";
    if (isToolCallEventType("bash", event)) {
      cmd = String((event.input as any)?.command ?? "");
    }

    // Match only `hard` rules: a nudge rule must NEVER hard-block (#1321 — the
    // broad `tortoise_` catch-all would otherwise block every read-only
    // `mcp__tortoise__tortoise_search` and any bash text containing `tortoise_`).
    const blockReason = (skillName: string, rule: ManifestRule, verb: string): ToolCallEventResult => {
      const file = skillDisplayPath(skillName);
      const reason = [
        `⛔ Skill gate — ${skillName}/SKILL.md not read this session.`,
        rule.message ? `  ${rule.message}` : "",
        `  Required: read ${file}`,
        `  Verify: check logs for "[skill-enforcer] 📖 ${skillName} read (manifest)"`,
        `  → Or SKILL_ENFORCER_DISABLED=1 to bypass.`,
      ].filter(Boolean).join("\n");
      console.log(`[skill-enforcer] 🚫 Blocked ${verb} (manifest: ${skillName})`);
      return { block: true, reason };
    };

    // Check MCP tool calls
    const mcpTool = (event as any).toolName ?? "";
    if (mcpTool.startsWith("mcp__")) {
      for (const [skillName, rules] of Object.entries(MANIFEST)) {
        for (const rule of rules) {
          if (rule.mode !== "hard") continue;
          for (const p of rule.patterns) {
            if (p.test(mcpTool) && !readFiles.has(skillName)) return blockReason(skillName, rule, mcpTool);
          }
        }
      }
      return undefined;
    }

    // Check bash commands
    if (!cmd) return undefined;

    for (const [skillName, rules] of Object.entries(MANIFEST)) {
      for (const rule of rules) {
        if (rule.mode !== "hard") continue;
        for (const p of rule.patterns) {
          if (p.test(cmd) && !readFiles.has(skillName)) return blockReason(skillName, rule, skillName);
        }
      }
    }
    return undefined;
  });

  // ── Nudge: intercept built-in tools (web_search, write, edit) ──
  pi.on("tool_call", async (event, _ctx): Promise<ToolCallEventResult | undefined> => {
    // ponytail: AGENT_ALLOW_MAIN_EDITS / ELDATO_ALLOW_MAIN_EDITS also bypasses skill-enforcer, #7470 / #7549
    if (_isBypassEnv()) {
      return undefined;
    }

    const toolName = (event as any).toolName ?? "";
    // Skip bash and MCP — already handled by the blocking handler above
    if (toolName === "bash" || toolName.startsWith("mcp__")) return undefined;
    if (!toolName) return undefined;

    // Track last tool call for tool-result injection (only on allow paths — blocked tools don't produce tool_result)
    const shouldTrack = true;

    // Check manifest for nudgable tools
    for (const [skillName, rules] of Object.entries(MANIFEST)) {
      for (const rule of rules) {
        if (rule.mode === "hard") continue; // hard entries don't nudge — preserved by the block gate
        for (const p of rule.patterns) {
          if (p.test(toolName)) {
            if (readFiles.has(skillName)) return undefined; // skill already read

            // Check for confirmKey bypass
            const input = (event.input as Record<string, unknown>) ?? {};
            const confirmKey = `nudge:${skillName}:${toolName}`;
            if (input.confirm === confirmKey) {
              // Agent confirmed — allow, log bypass (no nudge needed — agent chose this path)
              bypassCounts.set(skillName, (bypassCounts.get(skillName) ?? 0) + 1);
              logNudgeEvent("bypassed", skillName, toolName, bypassCounts.get(skillName)!);
              console.log(`[skill-enforcer] 🔓 Nudge bypassed: ${skillName} (count: ${bypassCounts.get(skillName)})`);
              return undefined;
            }

            const count = bypassCounts.get(skillName) ?? 0;

            if (count <= NUDGE_REMINDER_MAX) {
              // Level 1: tool-result injection — allow the tool, nudge injected in tool_result handler
              logNudgeEvent("fired", skillName, toolName, count);
              console.log(`[skill-enforcer] 💡 Nudge reminder: ${skillName} (count: ${count})`);
              return undefined; // pass through, nudge comes later
            }

            if (count <= NUDGE_CONFIRM_MAX) {
              // Level 2: confirmation gate — soft block with escape hatch
              const message = NUDGE_MESSAGES[skillName] ?? `⚠️ ${skillName}/SKILL.md not read this session.`;
              const reason = [
                message,
                `  → To proceed anyway, re-invoke with confirm="${confirmKey}"`,
                `  → Or read ${skillDisplayPath(skillName)}`,
              ].join("\n");
              logNudgeEvent("fired", skillName, toolName, count);
              console.log(`[skill-enforcer] 🛑 Nudge confirmation: ${skillName} (count: ${count + 1})`);
              return { block: true, reason };
            }

            // Level 3: hard block
            const reason = [
              `⛔ Skill gate — ${skillName}/SKILL.md not read this session.`,
              `  Required: read ${skillDisplayPath(skillName)}`,
              `  → Or SKILL_ENFORCER_DISABLED=1 to bypass.`,
            ].join("\n");
            bypassCounts.set(skillName, count + 1);
            logNudgeEvent("blocked", skillName, toolName, count + 1);
            console.log(`[skill-enforcer] 🚫 Hard block: ${skillName} (count: ${count + 1})`);
            return { block: true, reason };
          }
        }
      }
    }
    if (shouldTrack) {
      pendingNudges.push({ toolName, input: (event.input as Record<string, unknown>) ?? {} });
    }
    return undefined;
  });

  pi.on("tool_result", async (event, _ctx) => {
    const pending = pendingNudges.shift();
    if (!pending) return undefined;

    const toolName = pending.toolName;

    // Check if this tool is nudgable and skill not read
    for (const [skillName, rules] of Object.entries(MANIFEST)) {
      for (const rule of rules) {
        if (rule.mode === "hard") continue; // hard entries don't nudge — preserved by the block gate
        for (const p of rule.patterns) {
          if (p.test(toolName)) {
            if (readFiles.has(skillName)) return undefined;

            const count = bypassCounts.get(skillName) ?? 0;
            if (count > NUDGE_REMINDER_MAX) return undefined; // already past reminder level

            // Inject nudge into tool result
            const message = NUDGE_MESSAGES[skillName];
            if (message && event.content && event.content.length > 0) {
              const nudgeBlock = { type: "text" as const, text: `\n\n---\n${message}\n` };
              event.content = [...event.content, nudgeBlock];
              bypassCounts.set(skillName, count + 1);
              logNudgeEvent("complied", skillName, toolName, count + 1);
              console.log(`[skill-enforcer] 💬 Nudge injected: ${skillName} (count: ${count + 1})`);
            }
            return undefined;
          }
        }
      }
    }
    return undefined;
  });

  // Self-register with the SHARED health registry, carrying the manifest error
  // when the load failed (#1321). The module-local map this used to write was
  // read by nothing, and health-check's filesystem discovery would otherwise
  // mark the extension loaded.
  try {
    register("skill-enforcer", MANIFEST_LOAD.ok ? undefined : MANIFEST_LOAD.error);
  } catch { /* fail-open — health-check falls back to filesystem discovery */ }

  // #5672: suppress the success banner in print mode (task sub-agent output).
  // A FAILED load never reaches this branch — its `❌` line is already on stderr
  // from reportManifestState(), which is not print-mode gated.
  if (!isPrintMode() && MANIFEST_LOAD.ok) {
    console.log(manifestBanner(MANIFEST_LOAD, MANIFEST_PATH));
  }
}
