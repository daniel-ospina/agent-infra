// auto-sync.ts — Level-1 machine sync for agent-infra (session_start)
//
// On session start, if AGENT_INFRA_PATH is set:
//   - fetch origin and compare HEAD vs origin/main
//   - behind → AGENT_SYNC_MODE=auto  : run sync.sh (pull --ff-only + refresh config)
//   - behind → AGENT_SYNC_MODE=warn  : print a hint to run `cd "$AGENT_INFRA_PATH" && ./sync.sh`
//   - ahead  → report unpushed commits + push hint (informational; never pushes)
//   - diverged → surface git status/log guidance + next step (ff blocked)
//   - current → silent
//
// Safety: only ever pulls (never pushes). sync.sh fails loudly on divergence.
// Secrets never sync: auth.json and env vars stay machine-local by design.

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { existsSync } from "node:fs";
import { execSync } from "node:child_process";

export function shortHead(repo: string, ref = "HEAD"): string {
  try {
    return execSync(`git -C "${repo}" rev-parse --short ${ref}`, { encoding: "utf-8" }).trim();
  } catch {
    return "?";
  }
}

/** Commits HEAD is ahead of origin/main (0 when undetermined). */
export function aheadCount(repo: string): number {
  try {
    const out = execSync(`git -C "${repo}" rev-list --count origin/main..HEAD`, { encoding: "utf-8" }).trim();
    const n = Number(out);
    return Number.isInteger(n) ? n : 0;
  } catch {
    return 0;
  }
}

/**
 * Sync state of the repo vs origin/main (call after `git fetch`):
 *   "current"   HEAD === origin/main
 *   "behind"    origin/main has commits HEAD lacks (ff pull possible)
 *   "ahead"     HEAD has unpushed commits origin/main lacks (ff pull is a no-op)
 *   "diverged"  neither side is an ancestor of the other (ff pull blocked)
 */
export function syncState(repo: string): "current" | "behind" | "ahead" | "diverged" {
  let head: string, remote: string;
  try {
    head = execSync(`git -C "${repo}" rev-parse HEAD`, { encoding: "utf-8" }).trim();
    remote = execSync(`git -C "${repo}" rev-parse origin/main`, { encoding: "utf-8" }).trim();
  } catch {
    return "current"; // can't determine — don't act
  }
  if (head === remote) return "current";
  // HEAD is an ancestor of origin/main → local is behind (equality excluded above).
  try {
    execSync(`git -C "${repo}" merge-base --is-ancestor HEAD origin/main`, { stdio: "ignore" });
    return "behind";
  } catch {
    /* not behind */
  }
  // origin/main is an ancestor of HEAD → local has unpushed commits.
  try {
    execSync(`git -C "${repo}" merge-base --is-ancestor origin/main HEAD`, { stdio: "ignore" });
    return "ahead";
  } catch {
    /* neither is an ancestor → true divergence */
  }
  return "diverged";
}

export default function (pi: ExtensionAPI) {
  pi.on("session_start", async () => {
    const infraPath = process.env.AGENT_INFRA_PATH;
    if (!infraPath) return;          // not configured — silent
    if (!existsSync(infraPath)) return;
    if (process.env.PI_MODE === "print") return; // sub-agents: no pulls, no noise

    try {
      execSync(`git -C "${infraPath}" fetch origin --quiet`, { timeout: 30_000, stdio: "ignore" });
    } catch {
      return; // offline — silent
    }

    const state = syncState(infraPath);
    const syncHint = `cd "${infraPath}" && ./sync.sh`;

    // ahead → nothing to fetch; report unpushed commits so they're not silently skipped.
    if (state === "ahead") {
      const n = aheadCount(infraPath);
      console.log(
        `[auto-sync] ℹ️  agent-infra is ahead of origin/main (local ${shortHead(infraPath)}) — ` +
        (n > 0 ? `${n} unpushed commit(s) on main` : "unpushed local commit(s)")
      );
      console.log(`    Push when ready: git -C "${infraPath}" push origin main`);
      return;
    }

    // diverged → ff pull is blocked; surface guidance instead of a doomed pull.
    if (state === "diverged") {
      console.log(`[auto-sync] ⚠️  agent-infra has diverged from origin/main — fast-forward sync blocked:`);
      console.log(`    Local : ${shortHead(infraPath)}`);
      console.log(`    Remote: ${shortHead(infraPath, "origin/main")}`);
      console.log(`    Inspect: git -C "${infraPath}" status`);
      console.log(`    History: git -C "${infraPath}" log --oneline --left-right HEAD...origin/main`);
      console.log(`    Next: stash or commit local work, then re-run sync:`);
      console.log(`        ${syncHint}`);
      return;
    }

    if (state !== "behind") return; // current — silent

    if ((process.env.AGENT_SYNC_MODE || "warn") === "auto") {
      try {
        const out = execSync(`bash "${infraPath}/sync.sh" 2>&1`, { timeout: 180_000, encoding: "utf-8" });
        console.log(`[auto-sync] ✅ agent-infra updated to ${shortHead(infraPath)} — config refreshed`);
        const lines = out.trim().split("\n").filter(l => l.includes("warning") || l.includes("⚠"));
        if (lines.length) console.log(lines.slice(0, 3).map(l => `    ${l}`).join("\n"));
      } catch (e: any) {
        const err = e as { stdout?: Buffer | string; message?: string };
        const detail = (err.stdout ? err.stdout.toString() : err.message || "unknown error")
          .split("\n").filter(Boolean).slice(0, 4).join("\n    ");
        console.log(`[auto-sync] ⚠️  update available but auto-sync failed:`);
        console.log(`    ${detail}`);
        console.log(`[auto-sync]    Run manually: ${syncHint}`);
      }
      return;
    }

    console.log(`[auto-sync] ⚠️  agent-infra update available — run: ${syncHint}`);
  });
}
