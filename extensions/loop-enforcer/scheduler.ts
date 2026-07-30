// ── Cron Scheduler for Loop Enforcer ──────────────────────────────
// Scans ~/.pi/agent/loops/ for cron-type manifests and fires them on
// schedule. Uses setInterval with 1-minute granularity (no external
// crontab dependency). PID file locks prevent duplicate triggers.
// Exponential backoff on cap-fired failures (2x up to 24h max).

import {
  readFileSync, writeFileSync, existsSync, mkdirSync, readdirSync, unlinkSync,
} from "node:fs";
import { readManifest } from "./manifest.js";
import { join } from "node:path";
import { homedir } from "node:os";

const LOOPS_DIR = join(homedir(), ".pi", "agent", "loops");

// ── Schedule parsing ─────────────────────────────────────────────

/**
 * Parse a simple schedule string into an interval in milliseconds.
 * Supported: "daily", "hourly", "every Nm", "every Nh".
 * Default: 1 hour.
 */
function parseSchedule(schedule: string): number {
  if (schedule === "daily") return 24 * 60 * 60 * 1000;
  if (schedule === "hourly") return 60 * 60 * 1000;
  const match = schedule.match(/every\s+(\d+)\s*(m|h)/);
  if (match) {
    const n = parseInt(match[1], 10);
    return match[2] === "h" ? n * 60 * 60 * 1000 : n * 60 * 1000;
  }
  return 60 * 60 * 1000; // default: hourly
}

// ── PID file lock ────────────────────────────────────────────────

function lockPath(slug: string): string {
  return join(LOOPS_DIR, `${slug}.pid`);
}

/** Check if a live PID lock exists for this slug. */
function isLocked(slug: string): boolean {
  const p = lockPath(slug);
  if (!existsSync(p)) return false;
  try {
    const pid = parseInt(readFileSync(p, "utf8").trim(), 10);
    // signal 0 = check if process exists
    try { process.kill(pid, 0); return true; } catch { /* stale */ }
  } catch { /* corrupt lock */ }
  // Stale or corrupt — clean up
  try { unlinkSync(p); } catch { /* best effort */ }
  return false;
}

/** Write PID lock file. Call before firing a cron trigger. */
function acquireLock(slug: string): void {
  writeFileSync(lockPath(slug), String(process.pid));
}

/** Release PID lock. Called by agent_end after the cron cycle completes. */
export function releaseCronLock(slug: string): void {
  const p = lockPath(slug);
  try { if (existsSync(p)) unlinkSync(p); } catch { /* best effort */ }
}

// ── Backoff state ────────────────────────────────────────────────

interface BackoffEntry {
  multiplier: number;  // 1x, 2x, 4x, … capped at 24
  until: number;       // epoch ms — don't fire before this
}

// ── Main scheduler ───────────────────────────────────────────────

export function startScheduler(
  sendUserMessage: (msg: string, opts?: { deliverAs?: string }) => void,
): NodeJS.Timeout {
  const backoff = new Map<string, BackoffEntry>();

  mkdirSync(LOOPS_DIR, { recursive: true });

  const scheduler = setInterval(() => {
    let files: string[];
    try {
      files = readdirSync(LOOPS_DIR).filter((f) => f.endsWith(".yaml"));
    } catch {
      return; // dir disappeared or unreadable — skip this tick
    }

    // ponytail: periodic cleanup — every 10 ticks, remove backoff entries for deleted manifests
    if (!(scheduler as any)._tickCount) (scheduler as any)._tickCount = 0;
    (scheduler as any)._tickCount++;
    if ((scheduler as any)._tickCount % 10 === 0) {
      const liveSlugs = new Set(files.map(f => f.replace('.yaml', '')));
      for (const key of backoff.keys()) {
        if (!liveSlugs.has(key)) backoff.delete(key);
      }
    }

    for (const file of files) {
      const slug = file.replace(".yaml", "");
      const manifestPath = join(LOOPS_DIR, file);

      // ── Read manifest ──
      let manifest: Record<string, any>;
      try {
        manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
      } catch {
        continue; // corrupt manifest — skip
      }

      // Only cron-type, running, with a schedule
      if (
        manifest.loop_type !== "cron" ||
        manifest.status !== "running" ||
        !manifest.schedule
      ) {
        continue;
      }

      const now = Date.now();

      // ── Exponential backoff gate ──
      const bs = backoff.get(slug);
      if (bs && now < bs.until) {
        continue;
      }

      // ── Check last cycle result for cap failure ──
      const cycles: Array<Record<string, any>> = manifest.cycles || [];
      if (cycles.length > 0) {
        const last = cycles[cycles.length - 1];
        // Cap fired → apply backoff
        if (last.exit_signal && last.exit_signal.startsWith("cap:")) {
          const intervalMs = parseSchedule(manifest.schedule);
          const prev = backoff.get(slug) || { multiplier: 1, until: 0 };
          const newMult = Math.min(prev.multiplier * 2, 24);
          const delay = Math.min(newMult * intervalMs, 24 * 60 * 60 * 1000);
          backoff.set(slug, { multiplier: newMult, until: now + delay });
          console.log(
            `[loop-enforcer] ⚠️ Cron backoff ${slug}: ` +
            `${newMult}x → ${Math.round(delay / 60_000)}min delay`,
          );
          continue;
        }
        // Clean exit → reset backoff
        if (last.verdict === "CLEAN") {
          if (backoff.has(slug)) {
            console.log(`[loop-enforcer] ✅ Cron backoff cleared: ${slug}`);
          }
          backoff.delete(slug);
        }
      }

      // ── Schedule check ──
      const intervalMs = parseSchedule(manifest.schedule);
      const lastRun: number = manifest.last_cron_trigger_ms || 0;
      if (now - lastRun < intervalMs) {
        continue; // not due yet
      }

      // ── PID lock ──
      if (isLocked(slug)) {
        // Self-healing: if manifest not running, lock is stale — release it
        const m = readManifest(slug);
        if (!m || m.status !== "running") {
          releaseCronLock(slug);
          console.log(`[loop-enforcer] 🔓 Released stale cron lock: ${slug} (status: ${m?.status || "missing"})`);
        } else {
          console.log(`[loop-enforcer] 🔒 Cron locked: ${slug} (agent processing)`);
          continue;
        }
      }

      // ── Fire trigger ──
      acquireLock(slug);
      try {
        const goal: string = manifest.goal || slug;
        sendUserMessage(
          `[loop-enforcer] Cron trigger: ${slug}. Goal: ${goal}. Start working on this goal.`,
          { deliverAs: "followUp" },
        );
        console.log(
          `[loop-enforcer] ⏰ Cron fired: ${slug} (schedule: ${manifest.schedule})`,
        );

        // Update manifest with trigger record
        manifest.last_cron_trigger_ms = now;
        if (!manifest.trigger_history) manifest.trigger_history = [];
        manifest.trigger_history.push({
          trigger_id: `${slug}-${now}`,
          started_at: new Date(now).toISOString(),
          cycles: 0,
          verdict: "fired",
          tokens_consumed: 0,
        });
        writeFileSync(manifestPath, JSON.stringify(manifest, null, 2));
      } catch (err) {
        console.error(`[loop-enforcer] Cron trigger error for ${slug}:`, err);
        releaseCronLock(slug);
      }
      // Lock is NOT released here — agent_end releases it after the cycle
    }
  }, 60_000);
  return scheduler;
}
