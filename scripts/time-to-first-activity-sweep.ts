#!/usr/bin/env npx tsx
/**
 * time-to-first-activity-sweep.ts — #282 deliverable (b): size the
 * slow-thinking tail on successful sub-agent dispatches.
 *
 * Motivation: after #279, every first-message-stall kill is by construction a
 * never-worked (parent-unobservable-activity) session — but "never-worked"
 * conflates "genuinely hung provider" with "slow pre-activity thinking on a
 * startup-heavy dispatch", observationally identical at cut time. The M-cut
 * trade (TASK_FIRST_MESSAGE_MS default 300s) rests on "later-turn hangs are
 * rare" and "0 of 5 recovered cuts were never-worked" — both small samples.
 * This sweep measures time-to-first-activity on SUCCESSFUL dispatches from the
 * session JSONL logs to quantify the slow-thinking tail.
 *
 * Method (session-log forensics, verified against real logs):
 *   - The task tool spawns the child as `pi -p ... --no-session <prompt>`, so
 *     the child's FIRST user message is EXACTLY the parent's
 *     arguments.prompt → exact pairing by prompt hash (sha256).
 *   - T0 = child session spawn ts (session event); time-to-first-message =
 *     first assistant message with content; time-to-first-tool = first
 *     assistant message containing a toolCall.
 *   - Success filter: the parent's matching toolResult has isError=false.
 *
 * Usage (from the repo root):
 *   npx tsx scripts/time-to-first-activity-sweep.ts [--dir <sessions-dir>] [--json <out.json>]
 * Default sessions dir: ~/.pi/agent/sessions (scans only agent-infra* cwd slugs).
 *
 * Read-only — never modifies session logs.
 */

import { createHash } from "node:crypto";
import { readdirSync, readFileSync, writeFileSync, existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

interface TaskCall {
  promptSha: string;
  promptPrefixSha: string;
  ts: number;
  callId: string;
  logFile: string;
}
interface TaskResult {
  ts: number;
  callId: string;
  isError: boolean;
  logFile: string;
}
interface Dispatch {
  call: TaskCall;
  result?: TaskResult;
}
interface SessionLogStats {
  file: string;
  startedAt: number;
  firstUserMsgSha: string;
  firstUserMsgPrefixSha: string;
  firstMsgAt: number; // first assistant message with any content
  firstToolAt: number; // first assistant message with a toolCall
  lastRole: string;
  msgCount: number;
  toolCount: number;
}

const SESSIONS_ROOT = process.argv.includes("--dir")
  ? process.argv[process.argv.indexOf("--dir") + 1]
  : join(homedir(), ".pi", "agent", "sessions");
const JSON_OUT = process.argv.includes("--json")
  ? process.argv[process.argv.indexOf("--json") + 1]
  : null;

const sha = (s: string) => createHash("sha256").update(s).digest("hex");
const toMs = (iso: string) => Date.parse(iso);

function listSessionDirs(): string[] {
  if (!existsSync(SESSIONS_ROOT)) {
    console.error(`sessions dir not found: ${SESSIONS_ROOT}`);
    process.exit(1);
  }
  const all = readdirSync(SESSIONS_ROOT, { withFileTypes: true })
    .filter((d) => d.isDirectory())
    .map((d) => d.name)
    .filter((n) => n.startsWith("--Users-danielospina-Documents-GitHub-agent-infra"))
    .sort();
  return all;
}

function textOfContent(content: unknown[]): string {
  return (content ?? [])
    .filter((c: any) => c && c.type === "text" && typeof c.text === "string")
    .map((c: any) => c.text)
    .join("\n");
}

function scanSessionFile(path: string): { calls: TaskCall[]; results: TaskResult[]; stats?: SessionLogStats } {
  const calls: TaskCall[] = [];
  const results: TaskResult[] = [];
  let stats: SessionLogStats | undefined;
  let firstUserMsg = "";
  let firstUserMsgSeen = false;
  let firstMsgAt = 0;
  let firstToolAt = 0;
  let lastRole = "";
  let msgCount = 0;
  let toolCount = 0;
  const toolResultByCall = new Map<string, TaskResult>();
  try {
    for (const line of readFileSync(path, "utf-8").split("\n")) {
      if (!line.trim()) continue;
      const o = JSON.parse(line);
      const t = o.type;
      if (t === "session") {
        stats = {
          file: path,
          startedAt: toMs(o.timestamp) || 0,
          firstUserMsgSha: "",
          firstUserMsgPrefixSha: "",
          firstMsgAt: 0,
          firstToolAt: 0,
          lastRole: "",
          msgCount: 0,
          toolCount: 0,
        };
        continue;
      }
      if (t !== "message") continue;
      const m = o.message ?? {};
      const role = m.role;
      const content = m.content ?? [];
      if (role === "user" && !firstUserMsgSeen) {
        firstUserMsg = textOfContent(content);
        firstUserMsgSeen = true;
        continue;
      }
      if (role === "assistant") {
        const ts = toMs(o.timestamp) || 0;
        msgCount++;
        if (!firstMsgAt) firstMsgAt = ts;
        const hasToolCall = content.some((c: any) => c && c.type === "toolCall");
        if (hasToolCall && !firstToolAt) {
          firstToolAt = ts;
          toolCount++;
        }
        for (const c of content) {
          if (c && c.type === "toolCall" && c.name === "task") {
            const prompt = typeof c.arguments === "string" ? c.arguments : (c.arguments?.prompt ?? "");
            const p = typeof prompt === "string" ? prompt : JSON.stringify(prompt);
            calls.push({ promptSha: sha(p), promptPrefixSha: sha(p.slice(0, 120)), ts, callId: c.id ?? "", logFile: path });
          }
        }
        lastRole = role;
      } else if (role === "toolResult") {
        const ts = toMs(o.timestamp) || 0;
        lastRole = role;
        if (m.toolName === "task") {
          const r: TaskResult = { ts, callId: m.toolCallId ?? "", isError: !!m.isError, logFile: path };
          results.push(r);
          toolResultByCall.set(r.callId, r);
        }
      }
    }
  } catch (err: any) {
    console.warn(`  ⚠️  unreadable/corrupt ${path.split("/").pop()}: ${err.message}`);
  }
  if (stats) {
    stats.firstUserMsgSha = sha(firstUserMsg);
    stats.firstUserMsgPrefixSha = sha(firstUserMsg.slice(0, 120));
    stats.firstMsgAt = firstMsgAt;
    stats.firstToolAt = firstToolAt;
    stats.lastRole = lastRole;
    stats.msgCount = msgCount;
    stats.toolCount = toolCount;
  }
  return { calls, results, stats };
}

function percentile(sorted: number[], p: number): number {
  if (sorted.length === 0) return NaN;
  const idx = Math.min(sorted.length - 1, Math.max(0, Math.ceil((p / 100) * sorted.length) - 1));
  return sorted[idx];
}

function fmt(ms: number): string {
  if (!isFinite(ms) || ms <= 0) return "-";
  return (ms / 1000).toFixed(0) + "s";
}

function statsLine(label: string, arr: number[]): string {
  if (arr.length === 0) return `${label}: n=0`;
  const sorted = [...arr].sort((a, b) => a - b);
  const avg = arr.reduce((a, b) => a + b, 0) / arr.length;
  const tail = (th: number) => arr.filter((v) => v >= th).length;
  return (
    `${label}: n=${arr.length} mean=${fmt(avg)} p50=${fmt(percentile(sorted, 50))} ` +
    `p90=${fmt(percentile(sorted, 90))} p95=${fmt(percentile(sorted, 95))} p99=${fmt(percentile(sorted, 99))} ` +
    `max=${fmt(sorted[sorted.length - 1])} | tail(≥300s)=${tail(300_000)} ≥600s=${tail(600_000)} ≥1200s=${tail(1_200_000)}`
  );
}

function main(): void {
  const dirs = listSessionDirs();
  console.log(`Scanning ${dirs.length} agent-infra session dirs under ${SESSIONS_ROOT}\n`);

  // Pass 1 — every task dispatch (toolCall) + outcome (toolResult), every log.
  const allCalls: TaskCall[] = [];
  const allResults: TaskResult[] = [];
  const allStats: SessionLogStats[] = [];
  for (const dir of dirs) {
    const full = join(SESSIONS_ROOT, dir);
    for (const f of readdirSync(full).filter((f) => f.endsWith(".jsonl"))) {
      const { calls, results, stats } = scanSessionFile(join(full, f));
      allCalls.push(...calls);
      allResults.push(...results);
      if (stats) allStats.push(stats);
    }
  }
  console.log(`Pass 1: ${allCalls.length} task dispatches, ${allResults.length} task results, ${allStats.length} session logs`);

  // Pair results to calls (same log, same callId).
  const resultByKey = new Map(allResults.map((r) => [`${r.logFile}|${r.callId}`, r]));
  const dispatches: Dispatch[] = allCalls.map((c) => ({ call: c, result: resultByKey.get(`${c.logFile}|${c.callId}`) }));

  // Pass 2 — match child session logs to dispatches by first-user-message hash.
  const callsBySha = new Map<string, TaskCall[]>();
  const callsByPrefix = new Map<string, TaskCall[]>();
  for (const c of allCalls) {
    if (!callsBySha.has(c.promptSha)) callsBySha.set(c.promptSha, []);
    callsBySha.get(c.promptSha)!.push(c);
    if (!callsByPrefix.has(c.promptPrefixSha)) callsByPrefix.set(c.promptPrefixSha, []);
    callsByPrefix.get(c.promptPrefixSha)!.push(c);
  }
  const pickCall = (candidates: TaskCall[], childTs: number): TaskCall | undefined =>
    candidates.reduce<TaskCall | undefined>((best, c) => {
      if (!best) return c;
      return Math.abs(c.ts - childTs) < Math.abs(best.ts - childTs) ? c : best;
    }, undefined);

  const paired: Array<{ child: SessionLogStats; dispatch: Dispatch; timeToFirstMsg: number; timeToFirstTool: number; duration: number }> = [];
  let exact = 0;
  let prefixOnly = 0;
  for (const s of allStats) {
    let call = pickCall(callsBySha.get(s.firstUserMsgSha) ?? [], s.startedAt);
    if (!call) {
      const byPrefix = callsByPrefix.get(s.firstUserMsgPrefixSha) ?? [];
      if (byPrefix.length) {
        call = pickCall(byPrefix, s.startedAt);
        prefixOnly++;
      }
    } else {
      exact++;
    }
    if (!call) continue;
    const dispatch = dispatches.find((d) => d.call === call)!;
    paired.push({
      child: s,
      dispatch,
      timeToFirstMsg: s.firstMsgAt ? s.firstMsgAt - s.startedAt : -1,
      timeToFirstTool: s.firstToolAt ? s.firstToolAt - s.startedAt : -1,
      duration: dispatch.result ? dispatch.result.ts - call.ts : -1,
    });
  }
  console.log(`Pass 2: paired ${paired.length}/${allStats.length} sessions → dispatches (${exact} exact-hash, ${prefixOnly} prefix-hash)`);

  const success = paired.filter((p) => p.dispatch.result && !p.dispatch.result.isError);
  const failed = paired.filter((p) => p.dispatch.result && p.dispatch.result.isError);
  const noResult = paired.filter((p) => !p.dispatch.result);
  const msgLags = success.map((p) => p.timeToFirstMsg).filter((v) => v >= 0);
  const toolLags = success.map((p) => p.timeToFirstTool).filter((v) => v >= 0);
  const durations = success.map((p) => p.duration).filter((v) => v >= 0);

  console.log(`\nOutcomes: ${success.length} successful, ${failed.length} failed/error, ${noResult.length} no-result (killed/aborted)`);
  console.log(statsLine("time-to-first-message (successful)", msgLags));
  console.log(statsLine("time-to-first-tool (successful)", toolLags));
  console.log(statsLine("dispatch duration (successful)", durations));

  // Tail detail — the slow-thinking population this sweep exists to size.
  const slow = success.filter((p) => p.timeToFirstMsg >= 60_000).sort((a, b) => a.timeToFirstMsg - b.timeToFirstMsg);
  if (slow.length) {
    console.log(`\nSlow-think tail (time-to-first-message ≥ 60s, ${slow.length}):`);
    for (const p of slow) {
      console.log(
        `  ${fmt(p.timeToFirstMsg).padStart(8)}  msg→tool ${fmt(p.timeToFirstTool).padStart(8)}  duration ${fmt(p.duration).padStart(8)}  ${p.child.file.split("/").pop()}`,
      );
    }
  } else {
    console.log("\nNo dispatches with time-to-first-message ≥ 60s.");
  }

  if (JSON_OUT) {
    writeFileSync(
      JSON_OUT,
      JSON.stringify(
        {
          scannedDirs: dirs.length,
          dispatches: allCalls.length,
          results: allResults.length,
          sessions: allStats.length,
          paired: paired.length,
          exact, prefixOnly,
          success: success.length,
          failed: failed.length,
          noResult: noResult.length,
          stats: {
            timeToFirstMsg: { n: msgLags.length, mean: msgLags.reduce((a, b) => a + b, 0) / (msgLags.length || 1), sorted: [...msgLags].sort((a, b) => a - b) },
            timeToFirstTool: { n: toolLags.length, mean: toolLags.reduce((a, b) => a + b, 0) / (toolLags.length || 1), sorted: [...toolLags].sort((a, b) => a - b) },
          },
          slowTail: slow.map((p) => ({ file: p.child.file, timeToFirstMsg: p.timeToFirstMsg, timeToFirstTool: p.timeToFirstTool, duration: p.duration })),
        },
        null,
        2,
      ),
    );
    console.log(`\nJSON report → ${JSON_OUT}`);
  }
}

main();
