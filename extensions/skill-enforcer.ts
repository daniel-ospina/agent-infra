// skill-enforcer.ts — blocks git/MCP ops unless relevant skill was read.
// AGENTS.md §Skill Reading Protocol enforcement.

import type { ExtensionAPI, ToolCallEventResult } from "@earendil-works/pi-coding-agent";
import { isToolCallEventType } from "@earendil-works/pi-coding-agent";
import { readFileSync, writeFileSync, existsSync, mkdirSync } from "node:fs";
import { resolve, join } from "node:path";
import { homedir } from "node:os";
import { isPrintMode } from "./shared/print-mode.js";
// ponytail: register inlined — flat extensions CAN resolve ./shared/* (verified 2026-08-13; #5611 constraint stale)
// ── Skill read persistence across sessions ──────────
// ponytail: persist readFiles to ~/.pi/agent/skill-reads.json.
// Restore on session_start for reads in the last 24h. Eliminates
// re-read friction after reload (#7416).
const SKILL_READS_FILE = join(homedir(), ".pi", "agent", "skill-reads.json");
const READ_PERSIST_TTL_MS = 24 * 60 * 60 * 1000; // 24 hours

interface SkillReadEntry {
  file: string;
  readAt: number;
}

function persistReadFiles(): void {
  try {
    const dir = join(homedir(), ".pi", "agent");
    mkdirSync(dir, { recursive: true });
    const now = Date.now();
    const entries: SkillReadEntry[] = [];
    for (const file of readFiles) {
      entries.push({ file, readAt: now });
    }
    // Merge with existing entries, keep only those within TTL
    let existing: SkillReadEntry[] = [];
    try { existing = JSON.parse(readFileSync(SKILL_READS_FILE, "utf-8")); } catch {}
    const merged = new Map<string, number>();
    for (const e of [...existing, ...entries]) {
      if (now - e.readAt < READ_PERSIST_TTL_MS) {
        merged.set(e.file, Math.max(merged.get(e.file) ?? 0, e.readAt));
      }
    }
    writeFileSync(SKILL_READS_FILE, JSON.stringify([...merged.entries()].map(([file, readAt]) => ({ file, readAt }))));
  } catch { /* best-effort */ }
}

function restorePersistedReads(): void {
  try {
    if (!existsSync(SKILL_READS_FILE)) return;
    const entries: SkillReadEntry[] = JSON.parse(readFileSync(SKILL_READS_FILE, "utf-8"));
    const now = Date.now();
    let restored = 0;
    for (const e of entries) {
      if (now - e.readAt < READ_PERSIST_TTL_MS) {
        readFiles.add(e.file);
        restored++;
      }
    }
    if (restored > 0) console.log(`[skill-enforcer] 📂 Restored ${restored} skill reads from previous session`);
  } catch { /* best-effort */ }
}

// Dual-support: check AGENT_* first, then ELDATO_* (Phase 1 — #7549)
function _getEnv(name: string): string | undefined {
  return process.env[`AGENT_${name}`] ?? process.env[`ELDATO_${name}`];
}
function _isBypassEnv(): boolean {
  return process.env.SKILL_ENFORCER_DISABLED === "1" || _getEnv("ALLOW_MAIN_EDITS") === "1";
}
// Parameterized skill file prefix (Phase 1 default: operations/skills/)
const SKILLS_PREFIX = _getEnv("SKILLS_PREFIX") ?? "operations/skills/";

const __skillRegistry = new Map<string, { name: string; loaded: boolean; error?: string; loadedAt: number }>();
function register(name: string, error?: string): void { __skillRegistry.set(name, { name, loaded: !error, error, loadedAt: Date.now() }); }

// Load dangerous-ops manifest (#5558) — fixed: was double "operations/" (#7549)
const MANIFEST_PATH = resolve(__dirname, "..", "enforcement", "dangerous-ops.txt");

interface ManifestEntry {
  patterns: RegExp[];
  mode: "hard" | "nudge";
  message?: string;
}

function loadManifest(): Record<string, ManifestEntry> {
  const map: Record<string, ManifestEntry> = {};
  if (!existsSync(MANIFEST_PATH)) return map;
  for (const line of readFileSync(MANIFEST_PATH, "utf-8").split("\n")) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const fields = trimmed.split("#");
    const skillName = fields[0]!.trim();
    const patternStr = fields[1]?.trim() ?? "";
    const modeField = fields[2]?.trim();
    const messageField = fields[3]?.trim();
    if (skillName) {
      map[skillName] = {
        patterns: patternStr ? [new RegExp(patternStr, "i")] : [],
        mode: modeField === "hard" ? "hard" : "nudge",
        message: messageField || undefined,
      };
    }
  }
  return map;
}
const MANIFEST = loadManifest();


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
    if (!prompt || !existsSync(MANIFEST_PATH)) return;

    const sp = SKILLS_PREFIX;
    type Nudge = { keywords: RegExp; skill: string; file: string; hint: string };
    const nudges: Nudge[] = [
      { keywords: /worktree|git\s+worktree/i, skill: "using-git-worktrees", file: `${sp}using-git-worktrees/SKILL.md`, hint: "Creating worktrees?" },
      { keywords: /migration|RLS\b|supabase|apply_migration/i, skill: "supabase", file: `${sp}supabase/SKILL.md`, hint: "Supabase schema changes?" },
      { keywords: /\bcommit\b|\bpush\b|\bmerge\b|PR\b|pull\s+request/i, skill: "commit-workflow", file: `${sp}commit-workflow/SKILL.md`, hint: "Committing or merging?" },
      { keywords: /issue\s+create|github\s+issue/i, skill: "issue-creation", file: `${sp}issue-creation/SKILL.md`, hint: "Creating a GitHub issue?" },
    ];
    for (const { keywords, skill, file, hint } of nudges) {
      if (!keywords.test(prompt)) continue;
      if (readFiles.has(file)) continue; // already read this session
      return { message: { customType: "skill-enforcer-nudge", content: `💡 [skill-enforcer] ${hint} Read \`${file}\` first — the skill ensures safe, gated operations.`, display: true } };
    }
  });

  // ── Track reads ────────────────────────────────────
  pi.on("tool_call", async (event, _ctx) => {
    if (!isToolCallEventType("read", event)) return undefined;
    const path = String((event.input as any)?.path ?? "");
    // Resolve .agents/skills/ symlinks to operations/skills/ canonical paths
    const canon = path.replace(/(^|\/)\.agents\/skills\//, "$1operations/skills/");
    // Track manifest-driven skills
    for (const skillName of Object.keys(MANIFEST)) {
      const file = `${SKILLS_PREFIX}${skillName}/SKILL.md`;
      if (canon.includes(file) || canon === file) {
        readFiles.add(file);
        console.log(`[skill-enforcer] 📖 ${skillName} read (manifest)`);
        persistReadFiles();
      }
    }
    // Track prerequisite-chain files (#7474) — these left the manifest
    for (const prereq of Object.values(PREREQUISITES)) {
      for (const name of prereq.trackFiles ?? []) {
        const file = `${SKILLS_PREFIX}${name}/SKILL.md`;
        if (canon.includes(file) || canon === file) {
          readFiles.add(file);
          console.log(`[skill-enforcer] 📖 ${name} read (prereq)`);
          persistReadFiles();
        }
      }
    }
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
        const prereqFile = `${SKILLS_PREFIX}${skillName}/SKILL.md`;
        if (!readFiles.has(prereqFile)) continue;
        const satisfied = prereq.requiredAny.some(name => {
          return readFiles.has(`${SKILLS_PREFIX}${name}/SKILL.md`);
        });
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

    // Check MCP tool calls
    const mcpTool = (event as any).toolName ?? "";
    if (mcpTool.startsWith("mcp__")) {
      // Manifest-driven gates — check MCP tool names against manifest patterns
      for (const [skillName, entry] of Object.entries(MANIFEST)) {
        for (const p of entry.patterns) {
          if (p.test(mcpTool)) {
            const file = `${SKILLS_PREFIX}${skillName}/SKILL.md`;
            if (!readFiles.has(file)) {
              const reason = [
                `⛔ Skill gate — ${skillName}/SKILL.md not read this session.`,
                entry.mode === "hard" && entry.message ? `  ${entry.message}` : "",
                `  Fix: read ${file}`,
                `  Verify: check logs for "[skill-enforcer] 📖 ${skillName} read (manifest)"`,
                `  → Or SKILL_ENFORCER_DISABLED=1 to bypass.`,
              ].filter(Boolean).join("\n");
              console.log(`[skill-enforcer] 🚫 Blocked MCP ${mcpTool} (manifest: ${skillName})`);
              return { block: true, reason };
            }
          }
        }
      }
      return undefined;
    }

    // Check bash commands
    if (!cmd) return undefined;



    // Manifest-driven gates — check bash commands against manifest patterns
    for (const [skillName, entry] of Object.entries(MANIFEST)) {
      for (const p of entry.patterns) {
        if (p.test(cmd)) {
          const file = `${SKILLS_PREFIX}${skillName}/SKILL.md`;
          if (!readFiles.has(file)) {
            const reason = [
              `⛔ Skill gate — ${skillName}/SKILL.md not read this session.`,
              entry.mode === "hard" && entry.message ? `  ${entry.message}` : "",
              `  Required: read ${file}`,
              `  Verify: check logs for "[skill-enforcer] 📖 ${skillName} read (manifest)"`,
              `  → Or SKILL_ENFORCER_DISABLED=1 to bypass.`,
            ].filter(Boolean).join("\n");
            console.log(`[skill-enforcer] 🚫 Blocked ${skillName} (manifest)`);
            return { block: true, reason };
          }
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
    for (const [skillName, entry] of Object.entries(MANIFEST)) {
      if (entry.mode === "hard") continue; // hard entries don't nudge — preserved by the block gate
      for (const p of entry.patterns) {
        if (p.test(toolName)) {
          const file = `${SKILLS_PREFIX}${skillName}/SKILL.md`;
          if (readFiles.has(file)) return undefined; // skill already read

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
              `  → Or read ${SKILLS_PREFIX}${skillName}/SKILL.md`,
            ].join("\n");
            logNudgeEvent("fired", skillName, toolName, count);
            console.log(`[skill-enforcer] 🛑 Nudge confirmation: ${skillName} (count: ${count + 1})`);
            return { block: true, reason };
          }

          // Level 3: hard block
          const reason = [
            `⛔ Skill gate — ${skillName}/SKILL.md not read this session.`,
            `  Required: read ${file}`,
            `  → Or SKILL_ENFORCER_DISABLED=1 to bypass.`,
          ].join("\n");
          bypassCounts.set(skillName, count + 1);
          logNudgeEvent("blocked", skillName, toolName, count + 1);
          console.log(`[skill-enforcer] 🚫 Hard block: ${skillName} (count: ${count + 1})`);
          return { block: true, reason };
        }
      }
    }
    if (shouldTrack) {
      pendingNudges.push({ toolName, input: (event.input as Record<string, unknown>) ?? {} });
    }
    return undefined;
  });

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

  pi.on("tool_result", async (event, _ctx) => {
    const pending = pendingNudges.shift();
    if (!pending) return undefined;

    const toolName = pending.toolName;
    const input = pending.input;

    // Check if this tool is nudgable and skill not read
    for (const [skillName, entry] of Object.entries(MANIFEST)) {
      if (entry.mode === "hard") continue; // hard entries don't nudge — preserved by the block gate
      for (const p of entry.patterns) {
        if (p.test(toolName)) {
          const file = `${SKILLS_PREFIX}${skillName}/SKILL.md`;
          if (readFiles.has(file)) return undefined;

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
    return undefined;
  });

  // Self-register with health-check for explicit status reporting (#6129)
  try {
    register("skill-enforcer");
  } catch { /* fail-open — health-check falls back to filesystem discovery */ }

  // #5672: suppress startup banner in print mode (task sub-agent output)
  if (!isPrintMode()) {
    const totalGates = Object.keys(MANIFEST).length;
    console.log(`[skill-enforcer] ✅ Loaded — enforcing ${totalGates} skill gates from manifest`);
  }
}
