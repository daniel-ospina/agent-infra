// auto-sync.ts — version drift detection on session_start
// Checks .agent-infra-version against $AGENT_INFRA_PATH/manifest.json.
// Warns if behind; silent if current. Does NOT auto-apply changes.

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { readFileSync, existsSync } from "node:fs";
import { join } from "node:path";

function getProjectRoot(): string {
  // Best-effort: rely on cwd being the project root (pi sessions start there).
  // Falls back to cwd for non-git directories.
  try {
    const { execSync } = require("node:child_process");
    return execSync("git rev-parse --show-toplevel", { encoding: "utf-8" }).trim();
  } catch {
    return process.cwd();
  }
}

export default function (pi: ExtensionAPI) {
  pi.on("session_start", async () => {
    const infraPath = process.env.AGENT_INFRA_PATH;
    if (!infraPath) return; // No agent-infra configured — silent

    const manifestPath = join(infraPath, "manifest.json");
    if (!existsSync(manifestPath)) return; // manifest missing — silent

    const projectRoot = getProjectRoot();
    const versionFile = join(projectRoot, ".agent-infra-version");
    if (!existsSync(versionFile)) return; // First-time bootstrap — silent

    let pinned: string;
    let current: string;

    try {
      pinned = readFileSync(versionFile, "utf-8").trim();
      current = JSON.parse(readFileSync(manifestPath, "utf-8")).version;
    } catch {
      return; // Parse failure — silent (already failing in pre-commit)
    }

    if (!pinned || !current) return;

    if (pinned !== current) {
      // #5672: suppress in print mode (task sub-agent output)
      if (process.env.PI_MODE !== 'print') {
        console.error(
          `[auto-sync] ⚠️  agent-infra v${current} available (you're on v${pinned}). ` +
          `Run \`agent-infra update\`.`
        );
      }
    }
    // Current: silent
  });
}
