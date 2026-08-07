/**
 * manifest.ts — Loop Enforcer manifest I/O + lifecycle primitives
 * 
 * Side-effect-free. No `pi` runtime dependency — safe to import from tests.
 * Extracted from index.ts to eliminate writeManifest replica drift (DRY).
 */

import { readFileSync, writeFileSync, existsSync, unlinkSync, mkdirSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { createHash } from "node:crypto";
import { homedir } from "node:os";

// ── Paths ──────────────────────────────────────────────────────────
export const LOOPS_DIR = join(homedir(), ".pi", "agent", "loops");

// ── Types ──────────────────────────────────────────────────────────
import type { Indicator } from "./goal.js";

interface CycleEntry {
  number: number;
  verdict: "CLEAN" | "NEEDS_FIX" | "AWAITING_CONFIRMATION";
  issues_found: number;
  exit_signal: string;
  timestamp: string;
}

interface WriteBack {
  trigger: string;
  action: string;
  target: string;
  format: string;
  condition?: string;
}

type LoopType = "completion" | "cron" | "trigger" | "continuous";

export interface Manifest {
  loop_id: string;
  goal: string;
  objective: string;
  target_ambition: string;
  task_type: string;
  loop_type: LoopType;
  verification_level: string;
  status: "pending" | "running" | "paused" | "blocked" | "complete" | "aborted" | "pending_verification" | "pending_completion_verification";
  indicators: Indicator[];
  cycles: CycleEntry[];
  exit_reason: string | null;
  human_gate_flags: string[];
  write_back: WriteBack[];
  scope: { in_scope: string[]; out_of_scope: string[] };
  subject?: { team: string; role?: string };
  session_id?: string; // #5830: session affinity — cleared on shutdown/reclamation to release to role-level
  resume_from_cycle: number | null;
  parent_loop_id: string | null;
  created_at: string;
  heartbeat_file: string | null;
  schedule?: string;
  trigger_condition?: { type: string; path?: string };
  last_trigger_mtime?: number;
  manifest_hash?: string;
  goals_unverified?: boolean;
  goals_unverified_count?: number;
  verification_prompt?: string;
  verification_prompt_injected_at?: string;
  pending_kg_facts?: Array<{ subject: string; predicate: string; object: string; valid_from: string }>;
  declared_budget_prediction?: number;
  max_budget?: number;
  ci_enabled?: boolean;
  context_resets?: number;
  ralph_loop_attempted?: boolean;
  trigger_history?: Array<{
    trigger_id: string;
    started_at: string;
    cycles: number;
    verdict: string;
    tokens_consumed: number;
  }>;
}

// ── Manifest I/O ───────────────────────────────────────────────────
function manifestPath(slug: string, loopsDir = LOOPS_DIR): string {
  return join(loopsDir, `${slug}.yaml`);
}

export function readManifest(slug: string, loopsDir = LOOPS_DIR): Manifest | null {
  const p = manifestPath(slug, loopsDir);
  if (!existsSync(p)) return null;
  try {
    return JSON.parse(readFileSync(p, "utf8"));
  } catch {
    console.error(`[loop-enforcer] Failed to read manifest: ${slug}`);
    return null;
  }
}

export function writeManifest(slug: string, manifest: Manifest, loopsDir = LOOPS_DIR): void {
  try {
    mkdirSync(loopsDir, { recursive: true });
    const json = JSON.stringify(manifest, null, 2);
    // ponytail: manifest_hash computed but not yet verified by any consumer.
    // Self-excluding checksum: sha256(manifest_without_hash) stored in hash field.
    // To verify: parse JSON, delete manifest_hash, re-stringify, compare.
    manifest.manifest_hash = createHash("sha256").update(json).digest("hex");
    writeFileSync(manifestPath(slug, loopsDir), JSON.stringify(manifest, null, 2));
  } catch (e: any) {
    console.error(`[loop-enforcer] ⚠️ Failed to write manifest ${slug}: ${e.message}`);
  }
}

// ── Lifecycle ──────────────────────────────────────────────────────

export function abortLoop(
  slug: string,
  loopsDir: string,
  reason: string,
): { slug: string; cycles: number } | null {
  // CRITICAL: synchronous — activeLoopSlug=null must happen before next agent_end
  const manifest = readManifest(slug, loopsDir);
  if (!manifest) {
    // Missing or corrupt manifest: best-effort heartbeat cleanup
    const hbPath = join(loopsDir, `${slug}.heartbeat`);
    if (existsSync(hbPath)) unlinkSync(hbPath);
    return null;
  }
  // Guard: only abort running, paused, blocked, or pending_verification
  if (manifest.status === "complete" || manifest.status === "aborted") {
    return null; // idempotent skip
  }
  manifest.status = "aborted";
  manifest.exit_reason = reason;
  manifest.resume_from_cycle = null;
  manifest.heartbeat_file = null;
  writeManifest(slug, manifest, loopsDir);
  // Guarded unlink — heartbeat may have been consumed by before_agent_start
  const hbPath = join(loopsDir, `${slug}.heartbeat`);
  if (existsSync(hbPath)) unlinkSync(hbPath);
  return { slug, cycles: manifest.cycles?.length || 0 };
}

// ── Pause / Block / Resume ─────────────────────────────────────
// ponytail: three status transitions added per tortoise/docs/ONTOLOGY.md §2
// (Procedural layer: status is a derived projection of the event stream).
// Paused = positive state (suspended, will resume). Blocked = negative state (needs intervention).

export function pauseLoop(slug: string, reason: string, loopsDir = LOOPS_DIR): boolean {
  const manifest = readManifest(slug, loopsDir);
  if (!manifest) return false;
  if (manifest.status !== "running") return false; // only pause running loops
  manifest.status = "paused";
  manifest.exit_reason = `paused: ${reason}`;
  writeManifest(slug, manifest, loopsDir);
  return true;
}

export function blockLoop(slug: string, reason: string, dependency: string, loopsDir = LOOPS_DIR): boolean {
  const manifest = readManifest(slug, loopsDir);
  if (!manifest) return false;
  if (manifest.status !== "running" && manifest.status !== "paused") return false;
  manifest.status = "blocked";
  manifest.exit_reason = `blocked on ${dependency}: ${reason}`;
  writeManifest(slug, manifest, loopsDir);
  return true;
}

export function resumeLoop(slug: string, loopsDir = LOOPS_DIR): boolean {
  const manifest = readManifest(slug, loopsDir);
  if (!manifest) return false;
  if (manifest.status !== "paused" && manifest.status !== "blocked") return false;
  manifest.status = "running";
  manifest.exit_reason = null;
  writeManifest(slug, manifest, loopsDir);
  // ponytail: restore heartbeat — abortLoop cleans it, and paused/blocked loops
  // may have had theirs consumed. Without it, the scheduler can't track the loop.
  const hbPath = join(loopsDir, `${slug}.heartbeat`);
  writeFileSync(hbPath, JSON.stringify({
    slug,
    continuation_message: `[loop: ${slug}] Resumed.`,
    timestamp: new Date().toISOString(),
  }));
  return true;
}

export function abortAllLoops(
  loopsDir: string,
  reason: string,
): { slug: string; cycles: number }[] {
  if (!existsSync(loopsDir)) return [];
  const files = readdirSync(loopsDir).filter(
    (f) => f.endsWith(".yaml") && !f.startsWith("."),
  );
  const aborted: { slug: string; cycles: number }[] = [];
  for (const f of files) {
    const slug = f.replace(/\.yaml$/, "");
    const result = abortLoop(slug, loopsDir, reason);
    if (result) aborted.push(result);
  }
  return aborted;
}

export function buildEndSummary(
  aborted: { slug: string; cycles: number }[],
): string {
  if (aborted.length === 0) {
    return "✅ Session ending. No active loops.";
  }
  const names = aborted.map((a) => a.slug).join(", ");
  const count = aborted.length;
  const s = count === 1 ? "" : "s";
  return `✅ Session ending. ${count} loop${s} stopped: ${names}.`;
}
