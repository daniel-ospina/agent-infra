// audit-logger.ts — logs every tool call to ~/.pi/agent/audit/audit.jsonl (#5561)
// Enables post-hoc verification: was SKILL.md read before the corresponding operation?

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { appendFileSync, mkdirSync, existsSync } from "node:fs";
import { dirname } from "node:path";
import { homedir } from "node:os";
import { isPrintMode } from "./shared/print-mode.js";

const AUDIT_DIR = `${homedir()}/.pi/agent/audit`;
const AUDIT_FILE = `${AUDIT_DIR}/audit.jsonl`;

function log(entry: Record<string, unknown>) {
  if (!existsSync(AUDIT_DIR)) mkdirSync(AUDIT_DIR, { recursive: true });
  const line = JSON.stringify({ ...entry, ts: new Date().toISOString() }) + "\n";
  appendFileSync(AUDIT_FILE, line);
}

export default function (pi: ExtensionAPI) {
  pi.on("tool_call", async (event, _ctx) => {
    const toolName = (event as any).toolName ?? "unknown";
    const input = (event as any).input ?? {};
    
    // For bash: log the command
    if (toolName === "bash") {
      const cmd = String(input.command ?? "").slice(0, 200);
      log({ type: "tool_call", tool: toolName, command: cmd });
    }
    // For read: log the path (catches SKILL.md reads)
    else if (toolName === "read") {
      const path = String(input.path ?? "");
      log({ type: "tool_call", tool: toolName, path });
    }
    // For write/edit: log the path
    else if (toolName === "write" || toolName === "edit") {
      const path = String(input.path ?? "");
      log({ type: "tool_call", tool: toolName, path });
    }
    // Other tools: log name only
    else {
      log({ type: "tool_call", tool: toolName });
    }
    return undefined;
  });

  pi.on("session_start", async () => {
    log({ type: "session_start" });
  });

  pi.on("session_shutdown", async () => {
    log({ type: "session_shutdown" });
  });

  // #5672: suppress startup banner in print mode (task sub-agent output)
  if (!isPrintMode()) {
    console.log("[audit-logger] ✅ Loaded — logging to ~/.pi/agent/audit/audit.jsonl");
  }
}
