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
 * SCOPE, STATED ACCURATELY (a review corrected an earlier overclaim here): this hook
 * covers the RESULT of a tool — the surface that produced all 300 leaked copies. It
 * does NOT cover a secret typed literally into a tool CALL's arguments (those are
 * persisted as `arguments` on the assistant's toolCall entry), nor the bash tool's
 * own full-output temp log, nor anything a non-pi process writes (e.g. a script
 * writing /tmp/live.json). Those remain open and are tracked on #5109.
 *
 * Two detectors, deliberately:
 *   1. EXACT — the values themselves, read from the configured secret stores
 *      (so a value is caught even if its format is unknown).
 *   2. PATTERN — well-known credential shapes (tt_, ghp_, sk-, xox…), so a key is
 *      still caught AFTER ROTATION, when the exact-value store is stale.
 * The value is never printed, logged, or returned; only a label and a count.
 *
 * Over-redaction is a real harm, not a safe default: a false positive rewrites the
 * text the model is reading and, on a read→write round trip, persists the marker
 * into the user's file. So every pattern is LEFT-ANCHORED to a non-identifier
 * boundary, and env-var REFERENCE templates ($VAR / ${VAR}) are never treated as
 * secrets — they are names, not credentials.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

type Secret = { label: string; value: string };

const AGENT_DIR = join(homedir(), ".pi", "agent");
const CACHE_MS = 30_000;
const MIN_LEN = 12;

/** The stores that actually hold fleet secrets. Bounded on purpose: reading every
 *  *.json on the hot path cost a synchronous parse of a ~0.5 MB store per miss. */
const STORES = ["tortoise-config.json", "jev-config.json", ".mcp.json", "models.json"];

/** Config keys whose value is a credential. `(?:^|\.)token$` — the path handed in is
 *  always prefixed with the store label, so a bare `^token$` never matched. */
const SECRET_KEY_RE = /(api[_-]?key|access[_-]?token|refresh[_-]?token|(?:^|\.)token$|secret|password|passwd|credential)/i;

/** Values that are a REFERENCE to an env var, not a credential. */
const REFERENCE_RE = /^\$\{?[A-Za-z_][A-Za-z0-9_]*\}?$/;

/** Credential shapes that survive rotation. LEFT-ANCHORED: an unanchored `sk-`
 *  matched inside ordinary hyphenated words ("ta[sk-]management…") and corrupted them. */
const PATTERNS: Array<[string, RegExp]> = [
  ["tt_api_key", /(?<![A-Za-z0-9_])tt_[A-Za-z0-9_-]{20,}/g],
  ["github_pat", /(?<![A-Za-z0-9_])github_pat_[A-Za-z0-9_]{20,}/g],
  ["github_token", /(?<![A-Za-z0-9_])gh[pousr]_[A-Za-z0-9]{20,}/g],
  ["openai_key", /(?<![A-Za-z0-9_-])sk-[A-Za-z0-9_-]{20,}/g],
  ["slack_token", /(?<![A-Za-z0-9_])xox[baprs]-[A-Za-z0-9-]{10,}/g],
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
      if (node.length >= MIN_LEN && !REFERENCE_RE.test(node) && SECRET_KEY_RE.test(path)) {
        into.push({ label: `${label}:${path.replace(/^\./, "")}`, value: node });
      }
      return;
    }
    if (Array.isArray(node)) {
      node.forEach((v, i) => walk(v, `${path}.${i}`));
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
  for (const fn of STORES) collectFromJson(fn.replace(/\.json$/, ""), join(AGENT_DIR, fn), out);
  // Configured secrets in the process environment.
  for (const [k, v] of Object.entries(process.env)) {
    if (typeof v === "string" && v.length >= MIN_LEN && !REFERENCE_RE.test(v) && /(API_KEY|_KEY|_TOKEN|_SECRET|_CREDENTIALS?|PASSWORD)$/i.test(k)) {
      out.push({ label: `env:${k}`, value: v });
    }
  }
  // Longest first: a value that contains another must be replaced first.
  return out.filter((s) => s.value.length >= MIN_LEN).sort((a, b) => b.value.length - a.value.length);
}

/** Cached so the hot path NEVER does file I/O; the refresh happens off-path. */
let cache: Secret[] = [];
function refresh(): void {
  try {
    cache = loadSecrets();
  } catch {
    /* keep the previous cache */
  }
}
function secrets(): Secret[] {
  return cache;
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
    if (!fresh.test(out)) continue;
    hits.add(label);
    out = out.replace(new RegExp(re.source, re.flags), `[REDACTED:${label}]`);
  }
  return out;
}

/** Redact every string reachable from a value. Returns the ORIGINAL node when
 *  nothing changed, and never rebuilds non-plain values (Date/Buffer/Map/Set/class
 *  instances keep their identity — an earlier version turned them into {}). */
function redactDeep<T>(node: T, secrets: Secret[], hits: Set<string>, seen = new WeakSet<object>()): T {
  if (typeof node === "string") return redactString(node, secrets, hits) as unknown as T;
  if (typeof node !== "object" || node === null) return node;
  const obj = node as unknown as object;
  if (seen.has(obj)) return node; // cyclic details must not throw
  seen.add(obj);
  if (Array.isArray(node)) {
    let changed = false;
    const out = node.map((n) => {
      const r = redactDeep(n, secrets, hits, seen);
      if (r !== n) changed = true;
      return r;
    });
    return (changed ? (out as unknown as T) : node);
  }
  const proto = Object.getPrototypeOf(obj);
  if (proto !== Object.prototype && proto !== null) return node; // Date/Buffer/Map/Set/class instance
  let changed = false;
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(obj as Record<string, unknown>)) {
    const r = redactDeep(v, secrets, hits, seen);
    if (r !== v) changed = true;
    out[k] = r;
  }
  return (changed ? (out as unknown as T) : node);
}

const WITHHELD =
  "[secret-redactor] Redaction FAILED on this tool result, so its output is withheld: " +
  "it may contain a configured credential. Read the value at its source and pass it directly " +
  "to the consumer instead of printing it.";

export default function (pi: ExtensionAPI): void {
  refresh();
  const timer = setInterval(refresh, CACHE_MS);
  // Never hold the process open for the refresh.
  (timer as unknown as { unref?: () => void }).unref?.();

  pi.on("tool_result", async (event) => {
    const content = (event as { content?: unknown }).content;
    // Contract: content is an array of parts. Anything else is not ours to touch —
    // forwarding a redacted string here would break the pipeline downstream.
    if (!Array.isArray(content)) return;

    const hits = new Set<string>();
    try {
      const redactedContent = redactDeep(content, secrets(), hits);
      const details = redactDeep((event as { details?: unknown }).details, secrets(), hits);
      if (hits.size === 0) return; // nothing to do: do not touch the result

      const labels = [...hits].join(", ");
      const name = (event as { toolName?: string }).toolName ?? "tool";
      const warning =
        `\n[secret-redactor] ${hits.size} secret pattern(s) REDACTED from this ${name} result: ${labels}.` +
        ` The command tried to emit a configured credential; it was replaced with [REDACTED:…] before being shown or persisted.` +
        ` Read the value at its source and pass it directly to the consumer instead of printing it.`;

      const parts = (redactedContent as Array<Record<string, unknown>>).slice();
      parts.push({ type: "text", text: warning }); // never mutate the original array in place
      // Partial patch: omitted fields (isError, usage) keep their current values.
      return { content: parts, details } as never;
    } catch {
      // FAIL CLOSED. Returning undefined would mean "no change" and would pass the
      // possibly-unredacted result — the secret — straight through to the model and
      // to disk. Withholding the output is the only safe failure for a redactor.
      return { content: [{ type: "text", text: WITHHELD }], isError: true } as never;
    }
  });
}
