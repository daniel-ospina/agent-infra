import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { execSync } from "node:child_process";
import { symlinkSync, readdirSync, existsSync, mkdirSync, unlinkSync, lstatSync, readFileSync } from "node:fs";
import { resolve, join } from "node:path";
import { homedir } from "node:os";

const AGENT_SKILLS = join(homedir(), ".pi", "agent", "skills");

function getProjectRoot(): string {
  try {
    return execSync("git rev-parse --show-toplevel", { encoding: "utf-8" }).trim();
  } catch {
    return process.cwd();
  }
}

function buildRegistry(): Record<string, string> {
  const cachePath = join(homedir(), ".pi", "agent", "skills-registry.json");
  try {
    const root = getProjectRoot();
    execSync(`python3 "${root}/operations/tools/skill_registry.py" --no-cache`, {
      encoding: "utf-8", timeout: 5000, stdio: "pipe"
    });
  } catch {}
  if (existsSync(cachePath)) {
    try { return JSON.parse(readFileSync(cachePath, "utf-8")); } catch {}
  }
  return {};
}

function syncSymlinks(registry: Record<string, string>): number {
  if (!existsSync(AGENT_SKILLS)) mkdirSync(AGENT_SKILLS, { recursive: true });
  for (const entry of readdirSync(AGENT_SKILLS)) {
    try {
      const p = join(AGENT_SKILLS, entry);
      if (lstatSync(p).isSymbolicLink()) unlinkSync(p);
    } catch {}
  }
  let count = 0;
  for (const [name, skillMdPath] of Object.entries(registry)) {
    const skillDir = resolve(skillMdPath, "..");
    const target = join(AGENT_SKILLS, name);
    try { if (!existsSync(target)) { symlinkSync(skillDir, target, "dir"); count++; } } catch {}
  }
  return count;
}

export default function (pi: ExtensionAPI) {
  pi.on("session_start", async () => {
    const registry = buildRegistry();
    if (Object.keys(registry).length === 0) return;
    const count = syncSymlinks(registry);
    console.log(`skill-registry: ${count} skills symlinked (${Object.keys(registry).length} in registry)`);
  });
}
