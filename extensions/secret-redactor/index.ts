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
 * SCOPE, STATED ACCURATELY: this hook covers the RESULT of a tool — the surface that
 * produced all 300 leaked copies. It does NOT cover a secret typed literally into a
 * tool CALL's arguments (persisted as `arguments` on the toolCall entry), the bash
 * tool's full-output temp log, or anything a non-pi process writes (e.g. a script
 * writing /tmp/live.json). Those are open and tracked on #5109.
 *
 * ⛔ KNOWN LIMITATIONS (deliberate, not oversights — read before "fixing" them):
 *   Three review rounds found 23 defects in this file and each round found a shape
 *   the previous one missed. That is the signature of the wrong seam: a perfect
 *   in-process redactor would have to model every value an arbitrary tool can return.
 *   Rather than grow the recognizer, the following are DOCUMENTED and left, with the
 *   residual on #5109:
 *     - a redacted non-plain instance is returned as PLAIN DATA (own enumerable
 *       strings only): `#private` slots and non-enumerable/symbol props cannot be
 *       reproduced, so a rebuild would hand back a half-initialised object whose
 *       methods throw. Losing `instanceof` is the safer of the two failures;
 *     - symbol-keyed and non-enumerable properties are not traversed;
 *     - a secret in a Map KEY is redacted only when the key is a string; an object
 *       key that contains a secret is redacted by value but the key identity changes;
 *     - only exact configured values and the five credential shapes are caught; an
 *       unknown-format secret in a store not under ~/.pi/agent is not.
 *   The durable fix for the class is to redact at the point of PERSISTENCE (one
 *   choke point) rather than recognise values in flight — and, for this incident,
 *   ROTATION, which is what makes the 301 existing copies moot.
 *
 * Two detectors, deliberately:
 *   1. EXACT — the values themselves, read from the configured secret stores.
 *   2. PATTERN — credential shapes (tt_, ghp_, sk-, xox…), so a key is still caught
 *      AFTER ROTATION, when the exact-value store is stale.
 * The value is never printed, logged, or returned; only a label and a count.
 *
 * Over-redaction is itself a harm: a false positive rewrites what the model is
 * reading and, on a read→write round trip, persists the marker into the file. So the
 * patterns are LEFT-ANCHORED, env REFERENCE templates ($VAR / ${VAR}) are never
 * secrets, and a failure with no detected secret leaves the result untouched.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { readFileSync, readdirSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

type Secret = { label: string; value: string };

const AGENT_DIR = join(homedir(), ".pi", "agent");
const CACHE_MS = 30_000;
const MIN_LEN = 12;
/** Read regardless of readdir: the known fleet stores. */
const FALLBACK_STORES = ["tortoise-config.json", "jev-config.json", ".mcp.json", "models.json"];

/** Secret-ish on the LEAF key (`authToken`, `apiKey`, `clientSecret`…) or on the path. */
const SECRET_LEAF_RE = /(api[_-]?key|access[_-]?token|refresh[_-]?token|token$|secret|password|passwd|credential)/i;
const SECRET_PATH_RE = /(^|\.)(secret|secrets|credential|credentials|password|passwd|token|api[_-]?key)/i;
/** PUBLIC values are not secrets. Tested on the LEAF only — a `publicProfile.apiKey`
 *  must still be collected (testing the whole path excluded the subtree). */
const PUBLIC_RE = /^(public|pub[_-]?key|gpg[_-]?key|signing[_-]?key)$/i;
const PUBLIC_ANY_RE = /public|pub_?key|gpg_?key|signing_?key/i;

/** A value that is a REFERENCE to an env var, not a credential (tested trimmed). */
const REFERENCE_RE = /^\$\{?[A-Za-z_][A-Za-z0-9_]*\}?$/;

/** Credential shapes that survive rotation. LEFT-ANCHORED. */
const PATTERNS: Array<[string, RegExp]> = [
  ["tt_api_key", /(?<![A-Za-z0-9_])tt_[A-Za-z0-9_-]{20,}/g],
  ["github_pat", /(?<![A-Za-z0-9_])github_pat_[A-Za-z0-9_]{20,}/g],
  ["github_token", /(?<![A-Za-z0-9_])gh[pousr]_[A-Za-z0-9]{20,}/g],
  ["openai_key", /(?<![A-Za-z0-9_-])sk-[A-Za-z0-9_-]{20,}/g],
  ["slack_token", /(?<![A-Za-z0-9_])xox[baprs]-[A-Za-z0-9-]{10,}/g],
];

const leafOf = (path: string): string => path.split(".").pop() ?? path;
const isReference = (v: string): boolean => REFERENCE_RE.test(v.trim());

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
      const leaf = leafOf(path);
      const secretKey = SECRET_LEAF_RE.test(leaf) || SECRET_PATH_RE.test(path);
      if (node.length >= MIN_LEN && !isReference(node) && secretKey && !PUBLIC_RE.test(leaf)) {
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

/** Every top-level *.json in the agent dir (a store added later is covered), falling
 *  back to the known stores when readdir itself fails — otherwise a readdir error
 *  silently reduced the exact detector to nothing (review finding). Runs OFF the hot
 *  path (see the cache below), which is what makes scanning all of them affordable. */
function loadSecrets(): Secret[] {
  const out: Secret[] = [];
  let names: string[] = [];
  try {
    names = readdirSync(AGENT_DIR).filter((fn) => fn.endsWith(".json"));
  } catch {
    names = [];
  }
  if (names.length === 0) names = FALLBACK_STORES;
  for (const fn of names) {
    const p = join(AGENT_DIR, fn);
    try {
      if (statSync(p).size > 2_000_000) continue;
    } catch {
      continue;
    }
    collectFromJson(fn.replace(/\.json$/, ""), p, out);
  }
  // Configured secrets in the process environment. `_KEY$` is included (SSH_PRIVATE_KEY,
  // ENCRYPTION_KEY, MASTER_KEY… would otherwise be missed); PUBLIC ones are excluded.
  for (const [k, v] of Object.entries(process.env)) {
    if (
      typeof v === "string" &&
      v.length >= MIN_LEN &&
      !isReference(v) &&
      /(API_KEY|_KEY|_TOKEN|_SECRET|_CREDENTIALS?|PASSWORD)$/i.test(k) &&
      !PUBLIC_ANY_RE.test(k)
    ) {
      out.push({ label: `env:${k}`, value: v });
    }
  }
  return out.filter((s) => s.value.length >= MIN_LEN).sort((a, b) => b.value.length - a.value.length);
}

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

/**
 * Redact every string reachable from a value, with a memo so that an aliased or
 * cyclic value cannot re-emit the UNREDACTED original through a second path (it did:
 * `{a: leaf, b: leaf}` redacted only `a`). Each container is seeded into the memo
 * BEFORE its children are visited, so a back-edge resolves to the redacted copy.
 */
function redactDeep<T>(node: T, secrets: Secret[], hits: Set<string>, memo = new WeakMap<object, unknown>()): T {
  if (typeof node === "string") return redactString(node, secrets, hits) as unknown as T;
  if (typeof node !== "object" || node === null) return node;
  const obj = node as object;
  if (memo.has(obj)) return memo.get(obj) as T;

  if (Array.isArray(node)) {
    const out: unknown[] = [];
    memo.set(obj, out);
    let changed = false;
    for (const n of node) {
      const r = redactDeep(n, secrets, hits, memo);
      if (r !== n) changed = true;
      out.push(r);
    }
    if (!changed) {
      memo.set(obj, node);
      return node;
    }
    Object.setPrototypeOf(out, Object.getPrototypeOf(node)); // keep Array subclasses working
    return out as unknown as T;
  }

  // Byte containers: a secret encoded as UTF-8 bytes is data, not a string property.
  if (ArrayBuffer.isView(node) && !(node instanceof DataView)) {
    const bytes = node as unknown as Uint8Array;
    const text = Buffer.from(bytes.buffer, bytes.byteOffset, bytes.byteLength).toString("utf8");
    const redacted = redactString(text, secrets, hits);
    if (redacted === text) {
      memo.set(obj, node);
      return node;
    }
    return new Uint8Array(Buffer.from(redacted, "utf8")) as unknown as T;
  }

  if (node instanceof Map) {
    const out = new Map<unknown, unknown>();
    memo.set(obj, out);
    let changed = false;
    for (const [k, v] of node) {
      const rk = typeof k === "string" ? redactString(k, secrets, hits) : k;
      const rv = redactDeep(v, secrets, hits, memo);
      if (rk !== k || rv !== v) changed = true;
      out.set(rk, rv);
    }
    if (!changed) {
      memo.set(obj, node);
      return node;
    }
    Object.setPrototypeOf(out, Object.getPrototypeOf(node));
    return out as unknown as T;
  }

  if (node instanceof Set) {
    const out = new Set<unknown>();
    memo.set(obj, out);
    let changed = false;
    for (const v of node) {
      const r = redactDeep(v, secrets, hits, memo);
      if (r !== v) changed = true;
      out.add(r);
    }
    if (!changed) {
      memo.set(obj, node);
      return node;
    }
    Object.setPrototypeOf(out, Object.getPrototypeOf(node));
    return out as unknown as T;
  }

  // Every other object shape, including class instances (skipping them entirely was a
  // leak path). A CHANGED non-plain instance becomes plain data — see KNOWN LIMITATIONS.
  const entries = Object.entries(obj as Record<string, unknown>);
  if (entries.length === 0) {
    memo.set(obj, node); // Date, empty typed arrays, objects with only symbol props
    return node;
  }
  const rebuilt: Record<string, unknown> = {};
  memo.set(obj, rebuilt);
  let changed = false;
  for (const [k, v] of entries) {
    const r = redactDeep(v, secrets, hits, memo);
    if (r !== v) changed = true;
    rebuilt[k] = r;
  }
  if (!changed) {
    memo.set(obj, node);
    return node;
  }
  return rebuilt as unknown as T;
}

const WITHHELD =
  "[secret-redactor] Redaction could not complete on a result that contains a configured " +
  "credential, so the output is withheld. Read the value at its source and pass it directly " +
  "to the consumer instead of printing it.";

export default function (pi: ExtensionAPI): void {
  refresh();
  const timer = setInterval(refresh, CACHE_MS);
  (timer as unknown as { unref?: () => void }).unref?.();

  pi.on("tool_result", async (event) => {
    const content = (event as { content?: unknown }).content;
    if (!Array.isArray(content)) return; // not ours to touch; a string here breaks downstream

    const hits = new Set<string>();
    try {
      const redactedContent = redactDeep(content, secrets(), hits, new WeakMap());
      const details = redactDeep((event as { details?: unknown }).details, secrets(), hits, new WeakMap());
      if (hits.size === 0) return; // nothing secret: do not touch the result

      const labels = [...hits].join(", ");
      const name = (event as { toolName?: string }).toolName ?? "tool";
      const warning =
        `\n[secret-redactor] ${hits.size} secret pattern(s) REDACTED from this ${name} result: ${labels}.` +
        ` The command tried to emit a configured credential; it was replaced with [REDACTED:…] before being shown or persisted.` +
        ` Read the value at its source and pass it directly to the consumer instead of printing it.`;

      const parts = (redactedContent as Array<Record<string, unknown>>).slice();
      parts.push({ type: "text", text: warning });
      return { content: parts, details } as never;
    } catch {
      if (hits.size === 0) return; // nothing was detected: a traversal error must not destroy the result
      // A secret WAS detected, so fail closed rather than pass it through. `details` is
      // cleared EXPLICITLY: an omitted field keeps its current value, and details is
      // where tool payloads live.
      return { content: [{ type: "text", text: WITHHELD }], details: {}, isError: true } as never;
    }
  });
}
