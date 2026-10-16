/**
 * e2e-live-sessions.mjs — end-to-end proof for #1110 with REAL pi sessions.
 *
 * Three concurrent `pi -p` sessions talk to a mock OpenAI-compatible provider
 * sitting behind the (deterministic) load balancer from `lb-harness.mjs`. The
 * edge advertises `Keep-Alive: timeout=3600` but reaps idle connections after
 * 150 ms, and it severs one streaming response mid-flight per session (the
 * `terminated` signature from the issue).
 *
 * Two runs, same workload:
 *   CONTROL  PI_HTTP_POOL_HYGIENE=0  → pi's stock dispatcher (no ceiling)
 *   FIXED    (default)               → PI_HTTP_POOL_KEEPALIVE_MAX_MS=100
 *
 * Asserts the acceptance criteria:
 *   - FIXED: no request is ever written onto a reaped socket; every session
 *     completes; the mid-stream kill is recovered WITHOUT a process restart.
 *   - CONTROL: the edge's reaped sockets DO get reused (the defect) and pi is
 *     forced into connection-error retries that the fix does not need.
 *
 * Scope note on A2: the fixed clamp (100 ms) is SHORTER than the edge's reap
 * (150 ms), so the client drops the idle socket before the edge can reap it and
 * `rstOnReuse === 0` holds by construction. This workload therefore establishes
 * "the clamp prevents dead-socket reuse" but NOT "reuse is preserved on a
 * healthy endpoint" — the two cannot be shown in one workload. The steady-state
 * half is asserted against real undici by `test-pool-hygiene.mjs` P3.8.
 *
 * Run (needs a pi install):  node extensions/http-pool-hygiene/e2e-live-sessions.mjs
 * NOT part of the zero-dep CI glob (deliberately — it spawns pi).
 */

import http from "node:http";
import { once } from "node:events";
import { spawn } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { startLoadBalancer } from "./lb-harness.mjs";

const HERE = fileURLToPath(new URL(".", import.meta.url));
const PI_BIN = process.env.PI_BIN || "pi";
const SESSION_COUNT = 3;
const TOOL_TURNS = 3;
const EDGE_REAP_MS = 150;
const FIX_CLAMP_MS = 100;

let failures = 0;
function expect(name, cond, detail = "") {
  console.log(`${cond ? "✅" : "❌"} ${name}${cond || !detail ? "" : ` — ${detail}`}`);
  if (!cond) failures++;
}

/** Mock OpenAI-compatible SSE provider that also severs a response mid-stream. */
function createMockProvider() {
  const killed = new Set();
  const stats = { requests: 0, kills: 0, perSession: new Map() };

  const server = http.createServer((req, res) => {
    let raw = "";
    req.on("data", (c) => { raw += c; });
    req.on("end", () => {
      stats.requests++;
      let payload = {};
      try { payload = JSON.parse(raw); } catch { /* ignore */ }
      const key = /E2E-SESSION-(\d+)/.exec(raw)?.[1] ?? "unknown";
      stats.perSession.set(key, (stats.perSession.get(key) ?? 0) + 1);
      const toolTurns = Array.isArray(payload.messages)
        ? payload.messages.filter((m) => m?.role === "tool").length
        : 0;

      res.writeHead(200, {
        "content-type": "text/event-stream",
        "cache-control": "no-cache",
      });
      const frame = (delta, finish = null) =>
        `data: ${JSON.stringify({
          id: "chatcmpl-mock", object: "chat.completion.chunk", created: Math.floor(Date.now() / 1000),
          model: payload.model ?? "mock-1", choices: [{ index: 0, delta, finish_reason: finish }],
        })}\n\n`;

      // Mid-stream sever, once per session, on the 2nd assistant turn.
      if (toolTurns === 1 && !killed.has(key)) {
        killed.add(key);
        stats.kills++;
        res.write(frame({ role: "assistant", content: "working" }));
        setTimeout(() => { res.socket?.destroy(); }, 5); // kill mid-stream → "terminated"
        return;
      }

      const wantToolCall = toolTurns < TOOL_TURNS;
      if (wantToolCall) {
        res.write(frame({ role: "assistant", content: null }));
        res.write(frame({
          tool_calls: [{
            index: 0,
            id: `call_${key}_${toolTurns}`,
            type: "function",
            function: { name: "bash", arguments: JSON.stringify({ command: `sleep 0.4; echo tick-${key}-${toolTurns}` }) },
          }],
        }));
        res.write(frame({}, "tool_calls"));
      } else {
        res.write(frame({ role: "assistant", content: "all done" }));
        res.write(frame({}, "stop"));
      }
      res.write("data: [DONE]\n\n");
      res.end();
    });
  });
  server.on("connection", (s) => s.on("error", () => {}));
  return { server, stats, killed };
}

/** Write the throwaway agent dir (models.json points at the edge). */
function writeAgentDir(dir, baseUrl) {
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "models.json"), JSON.stringify({
    providers: {
      mock: {
        baseUrl,
        api: "openai-completions",
        apiKey: "not-needed",
        models: [{
          id: "mock-1",
          name: "Mock 1",
          reasoning: false,
          input: ["text"],
          contextWindow: 128000,
          maxTokens: 4096,
          cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
        }],
      },
    },
  }, null, 2));
  writeFileSync(join(dir, "settings.json"), JSON.stringify({
    defaultProvider: "mock",
    defaultModel: "mock-1",
    httpIdleTimeoutMs: 60000,
    retry: { maxRetries: 5, baseDelayMs: 500, maxDelayMs: 2000 },
    enableAnalytics: false,
  }, null, 2));
  writeFileSync(join(dir, "auth.json"), JSON.stringify({ mock: { type: "api_key", key: "not-needed" } }, null, 2));
}

function runSession({ index, agentDir, sessionDir, env }) {
  const args = [
    "-p", `Reply with the E2E-SESSION-${index} marker if asked. Run the bash tool when told to.`,
    "--provider", "mock",
    "--model", "mock-1",
    "--api-key", "not-needed",
    "--no-extensions",
    "-e", join(HERE, "index.ts"),
    "--no-skills", "--no-prompt-templates", "--no-context-files",
    "--tools", "bash",
    "--session-dir", sessionDir,
    "--no-session",
  ];
  const child = spawn(PI_BIN, args, {
    cwd: tmpdir(),
    env: { ...process.env, ...env, PI_CODING_AGENT_DIR: agentDir },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let out = "";
  let err = "";
  child.stdout.on("data", (d) => { out += d; });
  child.stderr.on("data", (d) => { err += d; });
  const done = new Promise((resolve) => {
    const timer = setTimeout(() => { child.kill("SIGKILL"); resolve({ code: "timeout" }); }, 90_000);
    child.on("close", (code) => { clearTimeout(timer); resolve({ code }); });
  });
  return { done, output: () => `${out}\n${err}` };
}

async function runWorkload(label, env) {
  console.log(`\n──────── ${label} ────────`);
  const mock = createMockProvider();
  mock.server.listen(0, "127.0.0.1");
  await once(mock.server, "listening");
  const upstreamPort = mock.server.address().port;
  const lb = await startLoadBalancer({ upstreamPort, idleReapMs: EDGE_REAP_MS, advertiseKeepAlive: true });
  const baseUrl = `http://127.0.0.1:${lb.port}/v1`;

  const tmp = mkdtempSync(join(tmpdir(), `pool-hygiene-e2e-${label}-`));
  const agentDir = join(tmp, "agent");
  const sessionDir = join(tmp, "sessions");
  mkdirSync(sessionDir, { recursive: true });
  writeAgentDir(agentDir, baseUrl);

  const sessions = [];
  for (let i = 1; i <= SESSION_COUNT; i++) {
    sessions.push(runSession({ index: i, agentDir, sessionDir, env }));
  }
  const results = await Promise.all(sessions.map((s) => s.done));
  const logs = sessions.map((s) => s.output());

  const summary = {
    label,
    exitCodes: results.map((r) => r.code),
    lb: { reaps: lb.stats.reaps, rstOnReuse: lb.stats.rstOnReuse, clientConnections: lb.stats.clientConnections },
    mock: { requests: mock.stats.requests, kills: mock.stats.kills, perSession: [...mock.stats.perSession.entries()] },
    connectionErrorsInLogs: logs.filter((l) => /Connection error|Retrying|terminated/i.test(l)).length,
    // Positive evidence that the message_end policy fired, rather than an
    // inference from a regex that pi's own retry lines also satisfy.
    messageEndFlushes: logs.filter((l) => /rotated connection pool \(message_end/.test(l)).length,
    transparentRetries: logs.filter((l) => /rotated connection pool \(transparent-retry/.test(l)).length,
    hygieneLines: logs.map((l) => /\[http-pool-hygiene\][^\n]*/.exec(l)?.[0] ?? null),
  };
  console.log(`exit codes: ${JSON.stringify(summary.exitCodes)}`);
  console.log(`edge: reaps=${summary.lb.reaps} rstOnReuse=${summary.lb.rstOnReuse} clientConns=${summary.lb.clientConnections}`);
  console.log(`mock: requests=${summary.mock.requests} midStreamKills=${summary.mock.kills} perSession=${JSON.stringify(summary.mock.perSession)}`);
  console.log(`sessions whose log mentions a transport retry: ${summary.connectionErrorsInLogs}`);
  console.log(`message_end pool flushes: ${summary.messageEndFlushes}  transparent retries: ${summary.transparentRetries}`);
  for (const line of summary.hygieneLines) if (line) console.log(`  ${line}`);

  await lb.close();
  await new Promise((r) => mock.server.close(r));
  rmSync(tmp, { recursive: true, force: true });
  return { summary, logs };
}

const control = await runWorkload("CONTROL (hygiene OFF)", { PI_HTTP_POOL_HYGIENE: "0" });
const fixed = await runWorkload("FIXED (hygiene ON)", { PI_HTTP_POOL_KEEPALIVE_MAX_MS: String(FIX_CLAMP_MS) });

console.log("\n──────── acceptance ────────");
expect("A1 control: the edge's reaped sockets ARE reused (defect reproduced)",
  control.summary.lb.rstOnReuse > 0,
  `rstOnReuse=${control.summary.lb.rstOnReuse} reaps=${control.summary.lb.reaps}`);
expect("A2 fixed: no request is ever written onto a reaped socket (by construction: clamp < reap; steady-state reuse is P3.8)",
  fixed.summary.lb.rstOnReuse === 0,
  `rstOnReuse=${fixed.summary.lb.rstOnReuse} reaps=${fixed.summary.lb.reaps}`);
expect("A3 fixed: all sessions complete",
  fixed.summary.exitCodes.every((c) => c === 0),
  `exitCodes=${JSON.stringify(fixed.summary.exitCodes)}`);
expect("A4 fixed: the mid-stream kill happened and was recovered without a restart",
  fixed.summary.mock.kills === SESSION_COUNT && fixed.summary.exitCodes.every((c) => c === 0),
  `kills=${fixed.summary.mock.kills} exitCodes=${JSON.stringify(fixed.summary.exitCodes)}`);
expect("A5 fixed: every session did its full tool loop",
  fixed.summary.mock.perSession.length === SESSION_COUNT && fixed.summary.mock.perSession.every(([, n]) => n >= 4),
  JSON.stringify(fixed.summary.mock.perSession));
expect("A6 fixed: hygiene installed in every session",
  fixed.summary.hygieneLines.every((l) => l && /installed/.test(l)),
  JSON.stringify(fixed.summary.hygieneLines));
expect("A7 fixed: the intentional mid-stream kill surfaced as a recoverable transport error (not a session death)",
  fixed.summary.connectionErrorsInLogs >= SESSION_COUNT && fixed.summary.exitCodes.every((c) => c === 0),
  `mentions=${fixed.summary.connectionErrorsInLogs} exitCodes=${JSON.stringify(fixed.summary.exitCodes)}`);
expect("A9 fixed: the mid-stream kill actually reached the message_end flush policy (positive evidence, not inferred)",
  fixed.summary.messageEndFlushes >= 1,
  `messageEndFlushes=${fixed.summary.messageEndFlushes}`);
expect("A10 control: hygiene OFF means no flush and no retry happened at all",
  control.summary.messageEndFlushes === 0 && control.summary.transparentRetries === 0,
  `controlFlushes=${control.summary.messageEndFlushes} controlRetries=${control.summary.transparentRetries}`);
expect("A8: the fixed run is not merely a quieter control (control hit the same intentional kills)",
  control.summary.mock.kills === SESSION_COUNT && fixed.summary.mock.kills === SESSION_COUNT,
  `controlKills=${control.summary.mock.kills} fixedKills=${fixed.summary.mock.kills}`);

console.log(`\n${failures === 0 ? "✅" : "❌"} e2e-live-sessions: ${failures === 0 ? "all acceptance checks passed" : `${failures} failed`}`);
process.exit(failures === 0 ? 0 : 1);
