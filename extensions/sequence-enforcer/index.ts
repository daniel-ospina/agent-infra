// sequence-enforcer — blocks tool calls that violate skill step sequences.
// Epics #6944/#6948. Hooks tool_call, validates against YAML step declarations.
// 3 modes: warn (log) | gate (block destructive) | strict (block all non-expected).
// Kill switch: /tmp/agent-state-machine.kill or AGENT_STATE_MACHINE env var.
//
// ── WHY THIS EXISTS (READ BEFORE DISABLING) ──
// Workflow enforcement is the CORE of our agent system, not a hindrance.
// Every skill defines a step sequence (scope → plan → implement → verify with
// gates). Agents that skip steps introduced real bugs that human time had to
// fix. This enforcer exists to make skipping impossible — it is INTENTIONAL.
//
// It is designed to apply to BOTH top-level agents AND nested sub-agents.
// Sub-agents dispatched via task() inherit the same enforcement because they
// do the same work and are held to the same standard. Do NOT disable this for
// sub-agents to "fix" timeouts — that removes workflow enforcement and lets
// lazy agents bypass gates. Fix the root cause instead (gate-advance logic,
// timeout mismatches, untimed git calls).
//
// If a sub-agent appears stuck at a verifier gate, the bug is in gate
// advancement or the silence threshold vs provider timeout — not the
// enforcement itself.

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { homedir } from "node:os";
import { isToolCallEventType } from "@earendil-works/pi-coding-agent";
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, writeFileSync, appendFileSync, mkdirSync, unlinkSync, renameSync } from "node:fs";
import { resolve, join, dirname } from "node:path";

// Dual-support: check AGENT_* first, then ELDATO_* (Phase 1 — #7549)
function _getEnv(name: string): string | undefined {
  return process.env[`AGENT_${name}`] ?? process.env[`ELDATO_${name}`];
}
// Namespaced files (Phase 1 — #7549)
const KILL_SWITCH_FILE = "/tmp/agent-state-machine.kill";
const MODE_FILE = "/tmp/agent-sequence-mode";

// ── Types ────────────────────────────────────────────

interface Step {
  name: string;
  type: string;
  skill: string;
  requires: string[];
  produces: string[];
  gate: string;
  retry: number;
  timeout_seconds: number;
}

type Mode = "warn" | "gate" | "strict";

// ── Loop bridge (#7040) ────────────────────────────

const BRIDGE_DIR = join(homedir(), ".pi", "agent", "bridge");
const BRIDGE_FILE = join(BRIDGE_DIR, "loop-sequence.json");

function writeBridgeState() {
  const top = topSkill();
  if (!top) return;
  const step = top.steps[top.stepIndex];
  // P2-3: guard against OOB stepIndex
  if (!step) return;
  try {
    mkdirSync(BRIDGE_DIR, { recursive: true });
    const payload = JSON.stringify({
      skill: top.path,
      stepIndex: top.stepIndex,
      stepCount: top.steps.length,
      stepName: step.name ?? null,
      gate: step.gate ?? "auto",
      startedAt: new Date(top.stepStartedAt).toISOString(),
      // ponytail: store startedAt only — loop-enforcer computes elapsed on read (P2-1)
      updatedAt: new Date().toISOString(),
    });
    // P0-1: atomic write via temp + rename to prevent truncated reads
    const tmp = BRIDGE_FILE + ".tmp";
    writeFileSync(tmp, payload);
    renameSync(tmp, BRIDGE_FILE);
  } catch (e) {
    console.log("[sequence-enforcer] bridge write failed:", (e as Error).message);
  }
}

function clearBridgeState() {
  try { if (existsSync(BRIDGE_FILE)) unlinkSync(BRIDGE_FILE); } catch { /* best-effort */ }
}

// ── State ────────────────────────────────────────────
// ponytail: skill stack replaces single activeSkill (#7265).
// Sub-skill reads during verifier gates push onto stack instead of
// replacing the parent, preserving dispatchedReviewers counters.
// When a skill completes all steps, it's popped to restore parent.

interface SkillState {
  path: string;
  steps: Step[];
  stepIndex: number;
  stepStartedAt: number;
  reviewers: Map<number, number>; // dispatched reviewer count per step
}

const stepCache = new Map<string, Step[] | null>();
let skillStack: SkillState[] = [];

function topSkill(): SkillState | undefined {
  return skillStack[skillStack.length - 1];
}

// ponytail: walk stack top-down to find the skill that owns the active
// verifier gate. Sub-skills pushed during a verifier gate should not
// intercept the parent's reviewer tracking (#7274, #7275).
function findVerifierGateOwner(): SkillState | undefined {
  for (let i = skillStack.length - 1; i >= 0; i--) {
    const skill = skillStack[i]!;
    const step = skill.steps[skill.stepIndex];
    if (step?.gate === "verifier") return skill;
  }
  return undefined;
}

// ── Sequence timeout — auto-clear stale sequences ─────

let sequenceTimeout: ReturnType<typeof setTimeout> | null = null;
const SEQUENCE_TIMEOUT_MS = 10 * 60 * 1000;

function resetSequenceTimeout() {
  if (sequenceTimeout) clearTimeout(sequenceTimeout);
  sequenceTimeout = setTimeout(() => {
    const top = topSkill();
    if (top) {
      console.log(`[sequence-enforcer] ⏰ Sequence timeout — popping stale "${top.path}" (10min no tool calls)`);
      // ponytail: pop only the stale skill, preserve parent (#7276)
      skillStack.pop();
      const parent = topSkill();
      if (parent) {
        console.log(`[sequence-enforcer] ↩ Restored parent: ${parent.path} (step ${parent.stepIndex}/${parent.steps.length})`);
        writeBridgeState();
      } else {
        clearBridgeState();
      }
    }
  }, SEQUENCE_TIMEOUT_MS);
}


// ── Kill switch ──────────────────────────────────────

function isKillSwitchActive(): boolean {
  if (_getEnv("STATE_MACHINE")) return true;
  try { return existsSync(KILL_SWITCH_FILE); } catch { return false; }
}

// ── Mode ─────────────────────────────────────────────

function resolveMode(): Mode {
  const env = _getEnv("SEQUENCE_MODE") || process.env.PI_ENFORCER_MODE;
  if (env === "warn" || env === "gate" || env === "strict") return env;
  // ponytail: mode override via dedicated file (decoupled from kill switch)
  try {
    const line = readFileSync(MODE_FILE, "utf-8").split("\n")[0]!.trim();
    if (line === "warn" || line === "gate" || line === "strict") return line;
  } catch { /* file doesn't exist or unreadable */ }
  return "gate";
}
// ── Audit logging ──────────────────────────────────

function auditLog(entry: Record<string, unknown>) {
  const auditPath = join(homedir(), ".pi", "agent", "audit", "enforcement.jsonl");
  try {
    mkdirSync(dirname(auditPath), { recursive: true });
    appendFileSync(auditPath, JSON.stringify(entry) + "\n");
  } catch { /* fail silently — audit is best-effort */ }
}


// ── Python bridge ────────────────────────────────────

function loadSteps(skillPath: string): Step[] | null {
  if (stepCache.has(skillPath)) return stepCache.get(skillPath)!;

  const absPath = resolve(skillPath);
  if (!existsSync(absPath)) { stepCache.set(skillPath, null); return null; }

  try {
    // ponytail: execFileSync bypasses shell — absPath via argv, no injection vector
    //
    // skill_declaration.py is an eldato-era tool that was never vendored into
    // agent-infra (extension extracted in #7549 without its Python dep). Rather
    // than fail-closed on the phantom module, the bridge tries it first (in case
    // a repo vendors operations/tools/), then falls back to parsing the `steps:`
    // list from the SKILL.md frontmatter directly — same Step schema, no missing
    // module dependency. This eliminates the boot-time ModuleNotFoundError
    // noise in sub-agent stderr (#489 class).
    const json = execFileSync(process.env.AGENT_PYTHON3 || "python3", [
      "-c",
      [
        "import sys, os, json",
        "def _find_tools_dir():",
        "    candidates = [",
        "        os.environ.get('AGENT_TOOLS_PATH',''),",
        "        os.environ.get('PYTHONPATH',''),",
        "        os.path.join(os.environ.get('AGENT_INFRA_PATH',''), 'operations', 'tools'),",
        "    ]",
        "    for c in candidates:",
        "        for part in c.split(os.pathsep):",
        "            if part and os.path.isfile(os.path.join(part, 'skill_declaration.py')):",
        "                return part",
        "    return ''",
        "def _try_module(path):",
        "    _tools = _find_tools_dir()",
        "    if _tools: sys.path.insert(0, _tools)",
        "    try:",
        "        from skill_declaration import extract_steps_from_skill",
        "        steps = extract_steps_from_skill(path)",
        "        return [{k: v for k, v in s.__dict__.items() if not k.startswith('_')} for s in (steps or [])]",
        "    except ImportError:",
        "        return None  # module not vendored — fall back to frontmatter parse",
        "def _try_frontmatter(path):",
        "    import re",
        "    try:",
        "        import yaml",
        "    except ImportError:",
        "        return []",
        "    try:",
        "        text = open(path, encoding='utf-8').read()",
        "    except OSError:",
        "        return []",
        "    m = re.match(r'\\A---\\n(.*?)\\n---', text, re.DOTALL)",
        "    if not m:",
        "        return []",
        "    try:",
        "        fm = yaml.safe_load(m.group(1)) or {}",
        "    except yaml.YAMLError:",
        "        return []",
        "    steps = fm.get('steps') or []",
        "    if not isinstance(steps, list):",
        "        return []",
        "    out = []",
        "    for s in steps:",
        "        if not isinstance(s, dict):",
        "            continue",
        "        out.append({",
        "            'name': s.get('name', ''),",
        "            'type': s.get('type', 'skill'),",
        "            'skill': s.get('skill', ''),",
        "            'requires': s.get('requires', []) or [],",
        "            'produces': s.get('produces', []) or [],",
        "            'gate': s.get('gate', 'auto'),",
        "            'retry': s.get('retry', 1),",
        "            'timeout_seconds': s.get('timeout_seconds', 0),",
        "        })",
        "    return out",
        "_steps = _try_module(sys.argv[1])",
        "if _steps is None:",
        "    _steps = _try_frontmatter(sys.argv[1])",
        "print(json.dumps(_steps))",
      ].join("\n"),
      absPath,
    ], {
      encoding: "utf-8",
      timeout: 5000,  // ponytail: 5s for cold Python import (yaml)
    }).trim();
    const steps: Step[] = JSON.parse(json);
    stepCache.set(skillPath, steps.length > 0 ? steps : null);
    return steps.length > 0 ? steps : null;
  } catch {
    stepCache.set(skillPath, null);
    return null;
  }
}

// ── Tool validation ──────────────────────────────────

const GIT_OP = /(^|\s)(git\s+(commit|push|merge|add)|gh\s+pr\s+(create|merge))/;
const DESTRUCTIVE_MCP = /\b(?:delete|remove|reset|revoke|drop|truncate|merge|rebase|purge|destroy|invalidate)\b/i;

// Constructive guidance for blocked tools — tells the agent what IS allowed
// so they don't spin in circles after hitting a gate (#7459 follow-up).
function gateGuidance(step: Step): string {
  const { allow } = getExpectedToolsForStep(step);
  if (allow.length === 0) return "";
  const gate = step.gate || "";
  const tools = allow.join(", ");
  if (gate === "verifier" || gate === "ai_review") {
    return `→ Allowed tools: ${tools}
→ To proceed: dispatch a task sub-agent to review this stage, or read the sub-skill SKILL.md`;
  }
  if (gate === "human_approval" || gate === "human_review") {
    return `→ Allowed tools: ${tools}
→ To proceed: present findings to the user for approval
→ Or: end your turn to auto-advance this gate, or use /loop stop`;
  }
  return "";
}

// Proactive gate announcement — tells the agent the rules BEFORE they hit the gate.
// Called at every step transition so agents never need to guess what's allowed.
function announceGate(step: Step): void {
  const gate = step.gate || "";
  if (gate === "auto" || !gate) return;
  const guid = gateGuidance(step);
  if (!guid) return;
  console.log(`[sequence-enforcer] 🔒 Gate: ${gate} — ${guid.replace(/\n→ /g, ' | ')}`);
}

function getExpectedToolsForStep(step: Step): { allow: string[]; block: RegExp[] } {
  const gate = step.gate || "";

  // auto: allow everything, block nothing
  // ponytail: empty allow = skip allow-check (RegExp here broke strict mode + types, #7470)
  if (gate === "auto") {
    return { allow: [], block: [] };
  }
  // verifier (also matches legacy "ai_review"): only task/subagent during review
  // loop_enforcer always allowed — the gate must never block its own escape hatch (#7470)
  if (gate === "verifier" || gate === "ai_review") {
    return { allow: ["task", "subagent", "read", "loop_enforcer"], block: [/.*/] };
  }
  // human_approval (also matches legacy "human_review"): only read/search/fetch during approval
  if (gate === "human_approval" || gate === "human_review") {
    return { allow: ["read", "web_search", "web_fetch", "loop_enforcer"], block: [/.*/] };
  }
  // No gate or unknown — standard work phase. Block destructive ops.
  return { allow: [], block: [GIT_OP, DESTRUCTIVE_MCP] };
}

function validateToolCall(
  toolName: string, command: string, step: Step, mode: Mode,
): { block: boolean; reason?: string } {
  if (mode === "warn") {
    console.log(
      `[sequence-enforcer] ⚠️ warn: ${toolName} | step="${step.name}" gate="${step.gate || "none"}"`,
    );
    return { block: false };
  }

  const expected = getExpectedToolsForStep(step);

  if (mode === "strict") {
    // strict = gate's destructive blocking + allow-list enforcement for gated steps
    for (const pattern of expected.block) {
      const target = command || toolName;
      if (pattern.test(target)) {
        return {
          block: true,
          reason: `⛔ strict — step "${step.name}" (gate: ${step.gate}) blocks this operation`,
        };
      }
    }
    if (expected.allow.length > 0 && !expected.allow.includes(toolName)) {
      const reason = `⛔ strict — step "${step.name}" (gate: ${step.gate}) only allows: ${expected.allow.join(", ")}`;
      auditLog({ ts: new Date().toISOString(), event: "blocked", skill: topSkill()?.path, step: step?.name, tool: toolName, mode, reason });
      return {
        block: true,
        reason,
      };
    }
    return { block: false };
  }

  // gate mode: check allow-list first, then block destructive ops
  // allow-list takes precedence — prevents deadlock when gate blocks its own resolution tools
  if (expected.allow.length > 0 && expected.allow.includes(toolName)) {
    return { block: false };
  }
  for (const pattern of expected.block) {
    const target = command || toolName;
    if (pattern.test(target)) {
      const reason = `⛔ gate — step "${step.name}" (gate: ${step.gate}) blocks this operation`;
      auditLog({ ts: new Date().toISOString(), event: "blocked", skill: topSkill()?.path, step: step?.name, tool: toolName, mode, reason });
      return {
        block: true,
        reason,
      };
    }
  }

  return { block: false };
}

// ── Extension ────────────────────────────────────────

export default function (pi: ExtensionAPI) {
  // ── session_start ──────────────────────────────
  pi.on("session_start", async (_event, _ctx) => {
    stepCache.clear();
    skillStack = [];
    // ponytail: kill switch is a single-session escape — clear stale switches so new
    // sessions don't start silently bypassed (#7470). Env var bypass is unaffected.
    try {
      if (existsSync(KILL_SWITCH_FILE)) {
        unlinkSync(KILL_SWITCH_FILE);
        console.log("[sequence-enforcer] 🧹 Cleared stale kill switch from previous session");
      }
    } catch { /* best-effort */ }
    if (isKillSwitchActive()) {
      console.log("[sequence-enforcer] ⏸️  Kill switch active — all enforcement bypassed");
    } else {
      auditLog({ ts: new Date().toISOString(), event: "startup", mode: resolveMode() });
  console.log(`[sequence-enforcer] ✅ Loaded — mode: ${resolveMode()}`);
    }
  });

  // ── session_shutdown ───────────────────────────
  pi.on("session_shutdown", async (_event, _ctx) => {
    stepCache.clear();
    skillStack = [];
    clearBridgeState();
  });

  // ── agent_end ──────────────────────────────────
  // ponytail: advance past human_review gates (resolved between turns), preserve state
  pi.on("agent_end", async (_event, _ctx) => {
    const top = topSkill();
    if (!top) return;
    const step = top.steps[top.stepIndex];
    // ponytail: human_approval and human_review are aliases everywhere else — advance both (#7470)
    if (step?.gate === "human_review" || step?.gate === "human_approval") {
      const next = top.stepIndex + 1;
      if (next < top.steps.length) {
        top.stepIndex = next;
        top.stepStartedAt = Date.now();
        console.log(
          `[sequence-enforcer] ⏩ Advanced past human_review → step ${next}/${top.steps.length}: ${top.steps[next]!.name}`,
        );
        announceGate(top.steps[next]!);
        writeBridgeState();
      } else {
        console.log(
          `[sequence-enforcer] ✅ All ${top.steps.length} steps completed`,
        );
        // ponytail: pop completed skill, restore parent (#7265)
        skillStack.pop();
        const parent = topSkill();
        if (parent) {
          console.log(`[sequence-enforcer] ↩ Restored parent: ${parent.path}`);
          writeBridgeState();
        } else {
          clearBridgeState();
        }
      }
    }
  });

  // ── tool_call: track skill reads ───────────────
  pi.on("tool_call", async (event, _ctx) => {
    if (!isToolCallEventType("read", event)) return undefined;
    const path = String((event.input as any)?.path ?? "");
    if (!path.includes("SKILL.md")) return undefined;

    const top = topSkill();
    // ponytail: if same skill is already on top, preserve state (human_review advancement across turns)
    if (top && top.path === path) return undefined;

    // Auto-advance current top past remaining auto-gated steps (#7222)
    if (top) {
      let advanced = 0;
      for (let i = top.stepIndex; i < top.steps.length; i++) {
        if (top.steps[i]!.gate === "auto") {
          advanced++;
        } else {
          break; // stop at first non-auto gate
        }
      }
      if (advanced > 0) {
        top.stepIndex += advanced;
        // If all steps are now completed (past last step):
        if (top.stepIndex >= top.steps.length) {
          console.log(
            `[sequence-enforcer] ⏩ Auto-advanced ${advanced} step(s) → completed "${top.path}"`,
          );
          skillStack.pop();
          const parent = topSkill();
          if (parent) {
            console.log(`[sequence-enforcer] ↩ Restored parent: ${parent.path}`);
            writeBridgeState();
          } else {
            clearBridgeState();
          }
        } else {
          console.log(
            `[sequence-enforcer] ⏩ Auto-advanced ${advanced} step(s) → now at step ${top.stepIndex}/${top.steps.length}: ${top.steps[top.stepIndex]!.name}`,
          );
          announceGate(top.steps[top.stepIndex]!);
          writeBridgeState();
        }
      }
    }

    const steps = loadSteps(path);
    // ponytail: skills with no steps are reference docs — don't affect stack (#7265)
    if (!steps) { writeBridgeState(); return undefined; }

    // ponytail: in main checkout, track the read but don't activate the pipeline.
    // Skill maintainers reading a SKILL.md are editing, not executing (#7487).
    // Detection: in a worktree, git-common-dir is the shared .git; the
    // worktree's top/.git is a separate file — they differ. In main they match.
    const inWorktree = (() => {
      try {
        const top = execFileSync("git", ["rev-parse", "--show-toplevel"], { encoding: "utf-8", timeout: 5000 }).trim();
        const common = resolve(execFileSync("git", ["rev-parse", "--git-common-dir"], { encoding: "utf-8", timeout: 5000 }).trim());
        return `${top}/.git` !== common;
      } catch { return true; } // if git fails, assume worktree (safer: let pipeline run)
    })();
    if (!inWorktree) {
      console.log(`[sequence-enforcer] 📖 Read ${path} (main checkout — pipeline not activated)`);
      writeBridgeState();
      return undefined;
    }

    // Push new skill onto stack (replace if top was completed & popped above)
    skillStack.push({ path, steps, stepIndex: 0, stepStartedAt: Date.now(), reviewers: new Map() });
    console.log(
      `[sequence-enforcer] 📖 Activated: ${path} (${steps.length} steps: ${steps.map(s => s.name).join(" → ")})`,
    );
    if (steps.length > 0) announceGate(steps[0]!);
    writeBridgeState();
    return undefined;
  });

  // ── tool_call: enforce step sequence ───────────
  pi.on("tool_call", async (event, _ctx) => {
    const top = topSkill();
    const toolName = (event as any).toolName ?? event.toolName ?? "";
    if (isKillSwitchActive()) {
      auditLog({ ts: new Date().toISOString(), event: "bypassed", reason: "kill_switch", tool: toolName });
      return undefined;
    }
    if (!top) return undefined;
    resetSequenceTimeout();

    const step = top.steps[top.stepIndex];
    if (!step) return undefined;
    const command = isToolCallEventType("bash", event)
      ? String((event.input as any)?.command ?? "")
      : "";

    const mode = resolveMode();
    const result = validateToolCall(toolName, command, step, mode);

    if (result.block) {
      const trail = top.steps
        .map((s, i) => i === top.stepIndex ? `[${s.name}]` : s.name)
        .join(" → ");
      console.log(`[sequence-enforcer] 🚫 Blocked ${toolName}: ${result.reason}`);
      auditLog({ ts: new Date().toISOString(), event: "blocked", skill: top.path, step: step.name, tool: toolName, mode, reason: result.reason });
      const guidance = gateGuidance(step);
      return {
        block: true,
        reason: `${result.reason}\n  → Sequence: ${trail}${guidance ? "\n" + guidance : ""}`,
      };
    }

    // Track verifier dispatches: count task/subagent calls for verifier gate.
    // Must use findVerifierGateOwner() — not top — because a sub-skill read
    // by a sub-agent sits above the verifier gate on the stack. top's step
    // would be auto-gated, causing the dispatch to never be counted (#66).
    if (toolName === "task" || toolName === "subagent") {
      const gateOwner = findVerifierGateOwner();
      if (gateOwner) {
        const current = gateOwner.reviewers.get(gateOwner.stepIndex) || 0;
        gateOwner.reviewers.set(gateOwner.stepIndex, current + 1);
      }
    }

    auditLog({ ts: new Date().toISOString(), event: "allowed", skill: top.path, step: step.name, tool: toolName, mode });
    return undefined;
  });

  // ── tool_result: advance step on gate fulfillment ──
  pi.on("tool_result", async (event, _ctx) => {
    const top = topSkill();
    if (isKillSwitchActive()) {
      auditLog({ ts: new Date().toISOString(), event: "bypassed", reason: "kill_switch", tool: event.toolName });
      return undefined;
    }
    if (!top) return undefined;
    resetSequenceTimeout();

    // ponytail: find gate owner for verifier advancement (#7274, #7275).
    // Task results must advance the skill that owns the verifier gate,
    // not necessarily the top of the stack.
    const gateOwner = findVerifierGateOwner();
    const step = gateOwner
      ? gateOwner.steps[gateOwner.stepIndex]!
      : top.steps[top.stepIndex];
    if (!step) return undefined;

    const targetSkill = gateOwner ?? top;

    // Count dispatched reviewers for verifier gate
    if (
      step.gate === "verifier" &&
      (event.toolName === "task" || event.toolName === "subagent")
    ) {
      const current = targetSkill.reviewers.get(targetSkill.stepIndex) || 0;
      if (current > 0) {
        const count = current - 1;
        if (count > 0) {
          targetSkill.reviewers.set(targetSkill.stepIndex, count);
          return undefined; // Still waiting for other reviewers
        }
        targetSkill.reviewers.delete(targetSkill.stepIndex);
        
        const next = targetSkill.stepIndex + 1;
        if (next < targetSkill.steps.length) {
          targetSkill.stepIndex = next;
          targetSkill.stepStartedAt = Date.now();
          console.log(
            `[sequence-enforcer] ⏩ Step ${next}/${targetSkill.steps.length}: ${targetSkill.steps[next]!.name}`,
          );
          announceGate(targetSkill.steps[next]!);
          writeBridgeState();
        } else {
          console.log(
            `[sequence-enforcer] ✅ All ${targetSkill.steps.length} steps completed`,
          );
          // ponytail: pop completed skill, restore parent (#7265)
          // Remove targetSkill from stack (may not be top if sub-skills above)
          const idx = skillStack.indexOf(targetSkill);
          if (idx >= 0) {
            // Remove targetSkill and everything above it (sub-skills)
            skillStack.splice(idx);
          }
          const parent = topSkill();
          if (parent) {
            console.log(`[sequence-enforcer] ↩ Restored parent: ${parent.path} (step ${parent.stepIndex}/${parent.steps.length})`);
            writeBridgeState();
          } else {
            clearBridgeState();
          }
        }
      }
    }

    return undefined;
  });

  // #5672: suppress banner in print mode (task sub-agent output)
  if (process.env.PI_MODE !== "print") {
    if (isKillSwitchActive()) {
      console.log("[sequence-enforcer] ⏸️  Loaded — kill switch active, all enforcement bypassed");
    } else {
      console.log(`[sequence-enforcer] ✅ Loaded — mode: ${resolveMode()} — enforcing step sequences`);
    }
  }
}
