/**
 * secret-redactor — strip configured secrets out of TOOL RESULTS before they are
 * shown to the model and before they are persisted into the artifacts that leaked
 * in #5109 (session transcripts, task-sessions, audit.jsonl, state/).
 *
 * WHY THIS EXISTS (the mechanism, measured 2026-10-04):
 *   The live Tortoise API key was found in 301 files under ~/.pi — 300 of them
 *   mode 0644 — because every artifact that records a tool result records it
 *   VERBATIM. One `cat ~/.pi/agent/tortoise-config.json` (or a script that dumped
 *   the config to "check the API URL") is therefore permanent, world-readable, and
 *   copied into every subsequent log. Nothing anywhere inspected tool output for
 *   the harness's own configured secrets: the config file was 0600 and everything
 *   that READ it was not.
 *
 *   `tool_result` is the one boundary every one of those artifacts passes through,
 *   so redaction here fixes the class rather than the instance. Deleting the leaked
 *   files would not: the exposure is only closed by rotation, and this stops the
 *   next leak from being created at all.
 *
 * Two detectors, deliberately:
 *   1. EXACT — the values themselves, read from the configured secret stores
 *      (so a value is caught even if its format is unknown).
 *   2. PATTERN — well-known credential shapes (tt_, ghp_, sk-, xox…), so a key is
 *      still caught AFTER ROTATION, when the exact-value store is stale.
 * The value is never printed, logged, or returned; only a label and a count.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

type Secret = { label: string; value: string };

const AGENT_DIR = join(homedir(), ".pi", "agent");
const CACHE_MS = 30_000;
const MIN_LEN = 12;

/** Config keys whose value is a credential. */
const SECRET_KEY_RE = /(api[_-]?key|access[_-]?token|refresh[_-]?token|^token$|secret|password|passwd|credential)/i;

/** Credential shapes that survive rotation. */
const PATTERNS: Array<[string, RegExp]> = [
  ["tt_api_key", /tt_[A-Za-z0-9_-]{20,}/g],
  ["github_pat", /github_pat_[A-Za-z0-9_]{20,}/g],
  ["github_token", /gh[pousr]_[A-Za-z0-9]{20,}/g],
  ["openai_key", /sk-[A-Za-z0-9_-]{20,}/g],
  ["slack_token", /xox[baprs]-[A-Za-z0-9-]{10,}/g],
];

function collectFromJson(label: string, file: string, into: Secret[]): void {
  let raw: string;
  try {
    raw = readFileSync(file, "utf8");
  } catch {
    return;
  }
  let obj: unknown;
  try {
    obj = JSON.parse(raw);
  } catch {
    return;
  }
  const walk = (node: unknown, path: string): void => {
    if (typeof node === "string") {
      if (node.length >= MIN_LEN && SECRET_KEY_RE.test(path)) {
        into.push({ label: `${label}:${path}`, value: node });
      }
      return;
    }
    if (node && typeof node === "object") {
      for (const [k, v] of Object.entries(node as Record<string, unknown>)) walk(v, `${path}.${k}`);
    }
  };
  walk(obj, label);
}

function loadSecrets(): Secret[] {
  const out: Secret[] = [];
  // The fleet's known secret stores.
  collectFromJson("tortoise-config", join(AGENT_DIR, "tortoise-config.json"), out);
  // Any other top-level *.json in the agent dir that holds a secret-ish key.
  try {
    for (const fn of readdirSync(AGENT_DIR)) {
      if (!fn.endsWith(".json") || fn === "tortoise-config.json") continue;
      const p = join(AGENT_DIR, fn);
      try {
        if (statSync(p).size > 2_000_000) continue;
      } catch {
        continue;
      }
      collectFromJson(fn.replace(/\.json$/, ""), p, out);
    }
  } catch {
    /* unreadable dir: fine */
  }
  // Configured secrets in the process environment.
  for (const [k, v] of Object.entries(process.env)) {
    if (typeof v === "string" && v.length >= MIN_LEN && /(API_KEY|_TOKEN|_SECRET|PASSWORD)$/i.test(k)) {
      out.push({ label: `env:${k}`, value: v });
    }
  }
  // Longest first: a value that contains another must be replaced first.
  return out.filter((s) => s.value.length >= MIN_LEN).sort((a, b) => b.value.length - a.value.length);
}

let cache: { at: number; secrets: Secret[] } = { at: 0, secrets: [] };
function secrets(): Secret[] {
  if (Date.now() - cache.at > CACHE_MS) cache = { at: Date.now(), secrets: loadSecrets() };
  return cache.secrets;
}

function redactString(text: string, secrets: Secret[], hits: Set<string>): string {
  let out = text;
  for (const s of secrets) {
    if (s.value && out.includes(s.value)) {
      out = out.split(s.value).join(`[REDACTED:${s.label}]`);
      hits.add(s.label);
    }
  }
  for (const [label, re] of PATTERNS) {
    const fresh = new RegExp(re.source, re.flags);
    if (fresh.test(out)) {
      out = out.replace(new RegExp(re.source, re.flags), `[REDACTED:${label}]`);
      hits.add(label);
    }
  }
  return out;
}

/** Redact every string reachable from a value, preserving structure. */
function redactDeep<T>(node: T, secrets: Secret[], hits: Set<string>): T {
  if (typeof node === "string") return redactString(node, secrets, hits) as unknown as T;
  if (Array.isArray(node)) return node.map((n) => redactDeep(n, secrets, hits)) as unknown as T;
  if (node && typeof node === "object") {
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(node as Record<string, unknown>)) out[k] = redactDeep(v, secrets, hits);
    return out as unknown as T;
  }
  return node;
}

export default function (pi: ExtensionAPI): void {
  pi.on("tool_result", async (event) => {
    let hits = new Set<string>();
    try {
      const content = redactDeep((event as { content?: unknown }).content, secrets(), hits);
      const details = redactDeep((event as { details?: unknown }).details, secrets(), hits);
      if (hits.size === 0) return; // nothing to do: do not touch the result

      const labels = [...hits].join(", ");
      const warning =
        `\n[secret-redactor] ${hits.size} secret pattern(s) REDACTED from this ${(event as { toolName?: string }).toolName ?? "tool"} result: ${labels}.` +
        ` The command tried to emit a configured credential; it was replaced with [REDACTED:…] before being shown or persisted.` +
        ` Read the value at its source and pass it directly to the consumer instead of printing it.`;

      // Partial patch: content/details replaced, everything else (isError, usage) kept.
      const patched = { content, details } as { content?: unknown; details?: unknown };
      const parts = Array.isArray(patched.content) ? (patched.content as Array<Record<string, unknown>>) : null;
      if (parts) parts.push({ type: "text", text: warning });
      return patched as never;
    } catch {
      // A guard must never break the tool path; on any error, leave the result alone.
      return;
    }
  });
}
