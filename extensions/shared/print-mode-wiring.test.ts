/**
 * print-mode-wiring.test.ts — repo-wide wiring gate for the isPrintMode refactor (#228).
 * Run: npx tsx extensions/shared/print-mode-wiring.test.ts
 *
 * Enforces the issue's "0 raw PI_MODE env checks outside the helper" acceptance
 * as a CI-able assertion (review P2): every production extension that references
 * isPrintMode must import it, and no production .ts may read process.env.PI_MODE
 * raw. A future extension (or a revert) reintroducing a raw check fails here.
 */

import { readFileSync, readdirSync, statSync } from "node:fs";
import { join, resolve, extname } from "node:path";
import { ok, equal } from "node:assert/strict";

const EXT_ROOT = resolve(import.meta.dirname, "..");
const SHARED = join(EXT_ROOT, "shared");

function collectTsFiles(dir: string): string[] {
  const out: string[] = [];
  for (const entry of readdirSync(dir)) {
    const p = join(dir, entry);
    if (entry === "node_modules") continue;
    if (statSync(p).isDirectory()) out.push(...collectTsFiles(p));
    else if (extname(p) === ".ts") out.push(p);
  }
  return out;
}

const productionFiles = collectTsFiles(EXT_ROOT).filter(
  (f) => !f.includes(".test.") && !f.endsWith(".test.ts"),
);

// 1. No raw process.env.PI_MODE reads in production extensions (excluding the
//    helper itself, which reads env via its params; and task-heartbeat's
//    env-param read, the documented exclusion).
let rawReads: string[] = [];
for (const f of productionFiles) {
  const src = readFileSync(f, "utf8");
  if (src.includes("process.env.PI_MODE")) {
    rawReads.push(f.replace(EXT_ROOT + "/", ""));
  }
}
equal(rawReads.length, 0, `raw process.env.PI_MODE reads remain: ${rawReads.join(", ")}`);

// 2. Every production file that calls isPrintMode() imports it.
const refactored = [
  "audit-logger.ts", "auto-sync.ts", "builtin-tools/index.ts",
  "health-check/index.ts", "loop-enforcer/index.ts", "main-worktree-guard/index.ts",
  "mcp-client/index.ts", "repo-freshness.ts", "review-enforcer/index.ts",
  "sequence-enforcer/index.ts", "skill-enforcer.ts", "slack-bridge/index.ts",
  "verification-gate/index.ts",
];
for (const rel of refactored) {
  const f = join(EXT_ROOT, rel);
  const src = readFileSync(f, "utf8");
  ok(src.includes("isPrintMode"), `${rel} should use isPrintMode`);
  ok(/import \{[^}]*isPrintMode[^}]*\} from "\.\.?\/shared\/print-mode\.js"/.test(src),
     `${rel} is missing the print-mode import`);
}

console.log(`print-mode-wiring.test OK (${refactored.length} files, 0 raw reads)`);
