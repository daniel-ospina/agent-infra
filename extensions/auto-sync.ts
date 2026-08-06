// auto-sync.ts — Level-1 machine sync for agent-infra (session_start)
//
// On session start, if AGENT_INFRA_PATH is set:
//   - fetch origin and compare HEAD vs origin/main
//   - behind → AGENT_SYNC_MODE=auto  : run sync.sh (pull --ff-only + refresh config)
//   - behind → AGENT_SYNC_MODE=warn  : print a hint to run `~/agent-infra/sync.sh`
//   - current → silent
//
// Safety: only ever pulls (never pushes). sync.sh fails loudly on divergence.
// Secrets never sync: auth.json and env vars stay machine-local by design.

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { existsSync } from "node:fs";
import { execSync } from "node:child_process";

function shortHead(repo: string): string {
  try {
    return execSync(`git -C "${repo}" rev-parse --short HEAD`, { encoding: "utf-8" }).trim();
  } catch {
    return "?";
  }
}

/** "current" | "behind" | "diverged" vs origin/main */
function syncState(repo: string): "current" | "behind" | "diverged" {
  try {
    const head = execSync(`git -C "${repo}" rev-parse HEAD`, { encoding: "utf-8" }).trim();
    const remote = execSync(`git -C "${repo}" rev-parse origin/main`, { encoding: "utf-8" }).trim();
    if (head === remote) return "current";
  } catch {
    return "current"; // can't determine — don't act
  }
  try {
    execSync(`git -C "${repo}" merge-base --is-ancestor HEAD origin/main`, { stdio: "ignore" });
    return "behind"; // HEAD is ancestor of origin/main but not equal
  } catch {
    return "diverged"; // not an ancestor — ahead or diverged; leave it alone
  }
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

    if (syncState(infraPath) !== "behind") return; // current or diverged — silent

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
        console.log(`[auto-sync]    Run manually: cd ~/agent-infra && ./sync.sh`);
      }
      return;
    }

    console.log(`[auto-sync] ⚠️  agent-infra update available — run: cd ~/agent-infra && ./sync.sh`);
  });
}
