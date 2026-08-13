/**
 * health-check — extension load status reporter.
 *
 * Prints a startup report of which extensions loaded successfully.
 * Extensions opt in by calling health.register("name") in their init.
 * Extensions that don't opt in are discovered from the filesystem and
 * marked as loaded (they were loaded by pi successfully).
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { register, getReport, registerExternal } from "../shared/health.js";
import { readdirSync } from "node:fs";
import { join } from "node:path";
import { isPrintMode } from "../shared/print-mode.js";

const EXTENSIONS_DIR = join(import.meta.dirname || __dirname, "..");

export default function (pi: ExtensionAPI) {
  try {
    // Self-register
    register("health-check");

    pi.on("session_start", async (_event, _ctx) => {
      // Discover extensions from filesystem that didn't self-register.
      // These were loaded successfully by pi (otherwise they wouldn't be here).
      try {
        const entries = readdirSync(EXTENSIONS_DIR, { withFileTypes: true });
        for (const entry of entries) {
          if (!entry.isDirectory() && entry.isFile() && (entry.name.endsWith(".ts") || entry.name.endsWith(".js"))) {
            const name = entry.name.replace(/\.(ts|js)$/, "");
            if (name !== "health-check" && name !== "_runtime-shims") {
              registerExternal(name);
            }
          }
          if (entry.isDirectory()) {
            const subEntries = readdirSync(join(EXTENSIONS_DIR, entry.name), { withFileTypes: true });
            const hasIndex = subEntries.some(e => e.isFile() && (e.name === "index.ts" || e.name === "index.js"));
            if (hasIndex) {
              registerExternal(entry.name);
            }
          }
        }
      } catch {
        // Filesystem discovery failed — report only registered extensions
      }

      const report = getReport();
      console.log(`[health-check] ${report.summary}`);
    });

    // #5672: suppress startup banner in print mode (task sub-agent output)
    if (!isPrintMode()) {
      console.log("[health-check] ✅ Loaded");
    }
  } catch (err: any) {
    console.error("[health-check] ❌ Failed to load:", err.message);
    register("health-check", err.message);
  }
}
