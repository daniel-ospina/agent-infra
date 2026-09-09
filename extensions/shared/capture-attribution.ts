// capture-attribution.ts — shared stamp contract for /v1/sessions payload attribution
// (#611) Both pi capture extensions (tortoise-capture, reflect-hook) import this
// module to stamp their POST payloads with:
//   harness="pi"        (server _SESSION_HARNESS_VALUES member, always present)
//   machine_id          (sha256 of hostname+user, derive-only, privacy-safe hex)
//   model               (per-session initial model from first model_change, cached)
//
// Privacy posture: machine_id is DERIVE-ONLY — no config/env override in v1.
// The raw hostname+user never leaves this module (sha256 at source, before any
// payload construction), so the durable JSONL fallback record (copied verbatim)
// can never contain a plaintext identifier.
//
// Documented v1 limitation: hostname changes (DHCP, rename, reimage) rotate the
// machine_id. A future upgrade path could use an opaque persisted UUID under
// ~/.tortoise/machine-id (wx-created, once per install) for stable attribution.
//
// Model: session entry stream is authoritative (first model_change at index 1,
// verified surviving compaction), per-session cache pins the first resolution.
// ctx.model is the last-resort fallback. Mid-session model switches are
// deliberately ignored — the Session row stores the session's initial model.
//
// stdlib-only, no pi-runtime imports (extensions/shared/ convention).

import { createHash } from "node:crypto";
import { hostname as osHostname } from "node:os";
import { userInfo } from "node:os";

// ── Constants ──────────────────────────────────────────────────────────────

/** Server _SESSION_HARNESS_VALUES member — always present in every payload. */
export const HARNESS = "pi" as const;

/** Server max_length for machine_id (defensive ceiling — sha256 hex is 64). */
export const MACHINE_ID_MAX = 256;

/** Server max_length for model (128 chars). */
export const MODEL_MAX = 128;

/** Per-session model cache capacity (FIFO eviction). */
export const MODEL_CACHE_MAX = 512;

// ── Machine identity ────────────────────────────────────────────────────────

/**
 * Produce a privacy-safe hex machine_id from hostname + user.
 *
 * Derive-only: the raw hostname and username NEVER leave this function.
 * sha256 hex output is 64 lowercase chars, control-char-free, ≤ 256 cap.
 * Deterministic: same hostname+user on the same machine → same hash.
 *
 * Exported for testing with injectable parts. Production callers use `machineId()`
 * which reads from the OS at module scope.
 */
export function machineIdFrom(hostname: string, username: string): string {
  return createHash("sha256").update(`${hostname}\u0000${username}`).digest("hex");
}

let _cached: string | undefined;

/**
 * Resolve the machine_id for this process.
 *
 * Memoized per process (module-level cache). First call reads OS hostname + user,
 * derives sha256 hex. Subsequent calls return the cached value.
 *
 * @param parts - Optional test seam (hostname, username). When provided, NOT memoized.
 */
export function machineId(parts?: { hostname: string; username: string }): string {
  if (parts) return machineIdFrom(parts.hostname, parts.username);
  if (_cached) return _cached;
  _cached = machineIdFrom(osHostname(), userInfo().username);
  return _cached;
}

// ── Field sanitization ─────────────────────────────────────────────────────

/**
 * Sanitize an attribution field value for the server contract.
 *
 * - Strips control characters ([\x00-\x1f\x7f])
 * - Trims whitespace
 * - Truncates to `cap` chars
 * - Returns `undefined` when the result is empty (server treats blank as unattributed)
 *
 * This prevents a non-printable or over-cap value from 422ing the entire POST.
 */
export function sanitizeAttribution(raw: string, cap: number): string | undefined {
  const cleaned = raw.replace(/[\x00-\x1f\x7f]/g, "").trim().slice(0, cap);
  return cleaned.length > 0 ? cleaned : undefined;
}

// ── Model resolution ──────────────────────────────────────────────────────

/** Minimal interface matching pi's ModelChangeEntry (type-only, no pi import). */
export interface ModelChangeLike {
  type?: unknown;
  provider?: unknown;
  modelId?: unknown;
}

/**
 * Resolve the initial model from the session entry stream.
 *
 * Scans for the FIRST entry with `type === "model_change"` (verified at index 1
 * in real session files, surviving compaction). Returns the provider-qualified
 * string `"${provider}/${modelId}"`, or bare `modelId` if provider is absent.
 * Returns `null` when no model_change is found.
 *
 * Mid-session model switches (later model_change entries) are deliberately
 * ignored — the Session row records the session's initial model.
 */
export function initialModelFromEntries(entries: readonly ModelChangeLike[]): string | null {
  for (const entry of entries) {
    if (entry.type !== "model_change") continue;
    if (typeof entry.modelId === "string" && entry.modelId.length > 0) {
      return typeof entry.provider === "string" && entry.provider.length > 0
        ? `${entry.provider}/${entry.modelId}`
        : entry.modelId;
    }
  }
  return null;
}

/**
 * Last-resort fallback: resolve a model string from pi's ctx.model object.
 *
 * ctx.model may be undefined → returns null.
 * When available, prefers provider-qualified `${provider}/${id}`, falls back to `id`.
 */
export function modelFromContext(
  model: { provider?: string; id?: string } | undefined,
): string | null {
  if (!model) return null;
  if (typeof model.id === "string" && model.id.length > 0) {
    return typeof model.provider === "string" && model.provider.length > 0
      ? `${model.provider}/${model.id}`
      : model.id;
  }
  return null;
}

// ── Per-session model cache ────────────────────────────────────────────────

/**
 * Per-process cache that pins the FIRST model resolution per session_id.
 *
 * Prevents drift when tortoise-capture re-POSTs the full conversation on
 * every agent_end — the model value is resolved once and cached, so
 * mid-session model switches never leak into the stamped payload.
 *
 * FIFO eviction at MODEL_CACHE_MAX (512) entries. Null values are cached
 * (a session with no model_change will consistently report no model).
 */
export class SessionModelCache {
  private _cache = new Map<string, string | null>();

  /**
   * Resolve the model for `sessionId`.
   *
   * On first call, invokes `entriesFn` to scan the entry stream and caches the
   * result. Subsequent calls return the cached value without re-invoking `entriesFn`.
   */
  resolve(
    sessionId: string,
    entriesFn: () => readonly ModelChangeLike[],
  ): string | null {
    const cached = this._cache.get(sessionId);
    if (cached !== undefined) return cached;

    const model = initialModelFromEntries(entriesFn());

    // FIFO eviction: if at capacity, delete the oldest entry
    if (this._cache.size >= MODEL_CACHE_MAX) {
      const firstKey = this._cache.keys().next().value;
      if (firstKey !== undefined) this._cache.delete(firstKey);
    }

    this._cache.set(sessionId, model);
    return model;
  }

  /** Clear all cached model values (for testing). */
  clear(): void {
    this._cache.clear();
  }
}

// ── Attribution stamping ───────────────────────────────────────────────────

/** The three attribution fields stamped into every /v1/sessions payload. */
export interface SessionAttribution {
  harness: string;
  machine_id: string;
  model?: string;
}

/**
 * Build the attribution object for a session.
 *
 * harness is always "pi". machine_id is always present (resolved from the
 * derive-only source). model is present only when resolvable — otherwise the
 * key is omitted (server treats absent as unattributed, same as blank).
 *
 * @param model - Resolved model string or null. Pass null to omit the model key.
 */
export function resolveAttribution(model: string | null): SessionAttribution {
  const a: SessionAttribution = {
    harness: HARNESS,
    machine_id: machineId(),
  };
  if (model) {
    const sanitized = sanitizeAttribution(model, MODEL_MAX);
    if (sanitized) a.model = sanitized;
  }
  return a;
}

/**
 * Stamp a session payload with attribution fields.
 *
 * Returns a NEW object (input is NEVER mutated). The returned object carries
 * the original keys plus `harness`, `machine_id`, and optionally `model`.
 *
 * Provides the verbatim parity guarantee: hand this object to both
 * writeFallback() and captureToHosted() — the JSONL record and the POST body
 * are byte-identical on the attribution fields by construction.
 */
export function stampSessionPayload<T extends Record<string, unknown>>(
  payload: T,
  attribution: SessionAttribution,
): T & SessionAttribution {
  const result = { ...payload } as T & SessionAttribution;
  result.harness = attribution.harness;
  result.machine_id = attribution.machine_id;
  if (attribution.model !== undefined) {
    result.model = attribution.model;
  }
  return result;
}