// reflect-hook.ts — wires session reflection to the hosted Tortoise API (#102)
// Fires on session shutdown (quit only).
// NEW SOR: posts the session to hosted Tortoise POST /v1/sessions (episodic Points)
// when TORTOISE_API_KEY is set — the eldato-era operations/memory/reflect.py AAR
// postmortem path is the legacy fallback (eldato checkout or REFLECT_PY).
// Non-blocking: subprocess/fetch detached, session closes regardless.

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { spawn, execSync } from "node:child_process";
import { writeFileSync, mkdtempSync, rmSync, mkdirSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

export default function (pi: ExtensionAPI) {
  pi.on("session_shutdown", async (event, ctx) => {
    // Only fire on actual quit, not on /new, /resume, /fork, or /reload
    if (event.reason !== "quit") return;

    try {
      // Reconstruct session text from entries
      const entries = ctx.sessionManager.getEntries();
      const lines: string[] = [];
      for (const entry of entries) {
        if (entry.type === "message") {
          const msg = entry.message;
          const role = msg.role;
          const content = Array.isArray(msg.content)
            ? msg.content
                .filter((c): c is { type: "text"; text: string } => c.type === "text")
                .map((c) => c.text)
                .join("\n")
            : String(msg.content ?? "");
          if (content) lines.push(`[${role}]: ${content}`);
        }
      }
      const sessionText = lines.join("\n\n");

      if (!sessionText) {
        console.log("[reflect-hook] Skipped — empty session");
        return;
      }

      // ── Capture path (#102): hosted Tortoise API is the NEW SOR ──
      // POST /v1/sessions (tortoise/hosted_api.py) ingests the conversation as
      // episodic Points. Env: TORTOISE_API_KEY (tt_... from tortoise.premiselabs.co),
      // TORTOISE_BASE_URL (default https://tortoise.premiselabs.co).
      const apiKey = process.env.TORTOISE_API_KEY || "";
      const baseUrl = (process.env.TORTOISE_BASE_URL || "https://tortoise.premiselabs.co").replace(/\/+$/, "");
      const conversation = lines.map((line) => {
        const m = line.match(/^\[(user|assistant)\]: ([\s\S]*)$/);
        return m ? { role: m[1] === "assistant" ? "assistant" : "user", content: m[2].slice(0, 5000) } : null;
      }).filter(Boolean) as Array<{ role: string; content: string }>;

      if (apiKey && conversation.length > 0) {
        try {
          const res = await fetch(`${baseUrl}/v1/sessions`, {
            method: "POST",
            headers: { "Content-Type": "application/json", Authorization: `Bearer ${apiKey}` },
            body: JSON.stringify({ conversation, metadata: { agent: "pi" } }),
          });
          if (!res.ok) {
            console.error(`[reflect-hook] tortoise /v1/sessions → HTTP ${res.status} ${(await res.text()).slice(0, 200)}`);
          } else {
            console.log(`[reflect-hook] Captured session to hosted Tortoise (${conversation.length} turns)`);
          }
          return; // hosted path done — no legacy spawn
        } catch (err: any) {
          console.error(`[reflect-hook] tortoise session capture failed: ${err.message}`);
          return;
        }
      }

      // ── Legacy path: eldato repo operations/memory/reflect.py (AAR postmortem) ──
      // Only fires when run from an eldato checkout (or REFLECT_PY is set).
      let reflectScript: string;
      try {
        const projectRoot = execSync("git rev-parse --show-toplevel", {
          encoding: "utf-8",
          cwd: ctx.cwd,
          timeout: 3000,
        }).trim();
        reflectScript = process.env.REFLECT_PY
          || join(projectRoot, "operations", "memory", "reflect.py");
      } catch {
        console.log("[reflect-hook] Skipped — not in a git repo");
        return;
      }

      if (!existsSync(reflectScript)) {
        console.log("[reflect-hook] reflect.py not found (needs eldato checkout or REFLECT_PY). Session capture is superseded by hosted Tortoise POST /v1/sessions (set TORTOISE_API_KEY). See issue #102.");
        return;
      }

      // Extract PR numbers from session text
      const prPattern =
        /(?:created|opened|merged|shipped|PR|pull request)\s*#(\d+)/gi;
      const prs = new Set<string>();
      let match: RegExpExecArray | null;
      while ((match = prPattern.exec(sessionText)) !== null) {
        prs.add(match[1]);
      }

      // Write session text to temp file
      const tmpDir = mkdtempSync(join(tmpdir(), "reflect-"));
      const sessionFile = join(tmpDir, "session.txt");
      writeFileSync(sessionFile, sessionText);

      // Build args for reflect.py
      const args: string[] = [
        reflectScript,
        "--auto",
        "--session-file",
        sessionFile,
        "--team",
        "organisation-design-team",
      ];
      for (const pr of prs) {
        args.push("--pr", pr);
      }

      // Build output path: docs/teams/<team>/operations/<date>-session-postmortem.md
      const dateStr = new Date().toISOString().slice(0, 10);
      const outputRel = join(
        "docs", "teams", "organisation-design-team", "operations",
        `${dateStr}-session-postmortem.md`,
      );
      const outputPath = join(projectRoot, outputRel);
      mkdirSync(join(projectRoot, "docs", "teams", "organisation-design-team", "operations"), { recursive: true });
      args.push("--output", outputPath);

      // Fire and forget — detached subprocess, session closes regardless
      const child = spawn("python3", args, {
        detached: true,
        stdio: ["ignore", "ignore", "pipe"],
        cwd: projectRoot,
      });
      child.stderr?.on("data", (data: Buffer) => {
        console.error(`[reflect-hook] reflect.py error: ${data.toString().trim()}`);
      });
      child.unref();

      console.log(
        `[reflect-hook] Fired reflect.py (${prs.size} PRs, ${sessionText.length} chars)`,
      );

      // Clean up temp file after a delay (subprocess reads it on start)
      setTimeout(() => {
        try {
          rmSync(tmpDir, { recursive: true, force: true });
        } catch {
          // best-effort cleanup
        }
      }, 30_000);
    } catch (err: any) {
      console.error(`[reflect-hook] Failed: ${err.message}`);
    }
  });
}
