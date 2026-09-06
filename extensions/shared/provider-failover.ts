/**
 * extensions/shared/provider-failover.ts — shared provider-exhaustion latch +
 * alias-family chain table (#476).
 *
 * NOT an extension (extensions/shared has no index.ts → pi's loader skips the
 * directory; see shared/audit-log.ts header). Imported by:
 *   - extensions/builtin-tools (parent dispatch-time resolution + marker parse)
 *   - extensions/provider-failover (child send-side latch + notices)
 *   - scripts/checkout-hygiene/deepseek-balance-watch.sh (via a small tsx
 *     bridge — the poller is the single restore authority)
 *
 * Design contract (from the #476 scoping plan, Phase 1):
 *   - ZERO top-level I/O — every fs access happens inside a function call
 *     (env- and path-seam driven), so importing the module is side-effect free.
 *   - NEVER throws. Every exported function degrades to a safe default and
 *     reports via a structured result; write failures are swallowed with an
 *     audit-only console.warn (auditing must never break dispatch).
 *
 * Latch file: <agentDir>/state/provider-exhaustion.json where agentDir =
 * PI_CODING_AGENT_DIR (E2E isolation) else ~/.pi/agent. Same resolution rule
 * as pi's own config (mirrors builtin-tools getModelsJsonPath).
 *
 * Write discipline (A15/A26 + plan):
 *   - writers serialize on an O_EXCL pidfile lock (<file>.lock) — the ONLY
 *     O_EXCL use in the module (plan: "O_EXCL only for pidfile lock")
 *   - content written to a tmp sibling, fsync'd, then rename()d into place
 *     (atomic — readers never observe a torn file)
 *   - epoch-stamped CAS: every successful write bumps `epoch`; a writer whose
 *     mutation is based on a stale read re-reads (up to N attempts)
 *   - once-per-process-per-epoch write cap: a process that already durably
 *     wrote the current epoch/content does not re-write redundant state
 *   - corrupt files are renamed to provider-exhaustion.json.corrupt-<ts> and
 *     treated as empty (self-heal); stale (TTL-expired) entries are treated
 *     as clear by resolution so a machine without the poller still recovers
 *
 * Env gates:
 *   PROVIDER_FAILOVER_DISABLE=1  — whole-failover kill switch (default off;
 *                                 consequence is documented + warned)
 *   PI_FAILOVER_NO_HOP=1         — per-dispatch must-stay: resolution returns
 *                                 the requested leg even when latched
 *   TASK_EXHAUSTION_BLOCK=1      — fail-fast: a dispatch that WOULD hop fails
 *                                 instead (not default)
 *   PROVIDER_EXHAUSTION_TTL_MS   — latch TTL (default DEFAULT_LATCH_TTL_MS)
 *   PROVIDER_FAILOVER_BLOCKED    — comma list of provider ids excluded as
 *                                 hop legs (default "qwen-tp": 401-blocked;
 *                                 config-only re-enable = remove from list)
 *
 * Chain model: alias families. A "family" is one logical model served by
 * multiple (provider, model) legs with identical behavior on different
 * balances. deepseek-v4-flash → qwen-tp/deepseek-v4-flash-0731 (flash RENAMED
 * on the token plan — same id family, distinct model id) → openrouter slug
 * openrouter/deepseek/deepseek-v4-flash. deepseek-v4-pro → qwen-tp identity
 * deepseek-v4-pro → openrouter/deepseek/deepseek-v4-pro. All legs of a family
 * latched/blocked → the structured HALT class (never a silent fallthrough to
 * a latched default).
 *
 * Exhaustion signature (text classifier — s2: message_end errorMessage is text
 * only; after_provider_response never fires on 402 for the SDK transport):
 *   - canonical: "402" + "insufficient balance" / bare "insufficient balance"
 *   - observed variant: "credit balance too low"
 *   - permanent auth class (NOT exhaustion): 401/403 + invalid/blocked key
 *     wording → drives excluded-with-alert, never the exhaustion latch
 *   - anything else → audit-only (no latch, no hop)
 */

import * as fs from "node:fs";
import * as path from "node:path";
import { homedir } from "node:os";
import { createHash } from "node:crypto";
import { fileURLToPath } from "node:url";

// ── Env gates ───────────────────────────────────────────────────────────────

export const PROVIDER_FAILOVER_DISABLE = "PROVIDER_FAILOVER_DISABLE";
export const PI_FAILOVER_NO_HOP = "PI_FAILOVER_NO_HOP";
export const TASK_EXHAUSTION_BLOCK = "TASK_EXHAUSTION_BLOCK";
export const PROVIDER_EXHAUSTION_TTL_MS = "PROVIDER_EXHAUSTION_TTL_MS";
/** Comma list of provider ids that must never serve as hop legs. */
export const PROVIDER_FAILOVER_BLOCKED = "PROVIDER_FAILOVER_BLOCKED";

/** Default providers excluded as hop legs (401-blocked keys — sC2; re-enable
 * = config-only: drop from the env list / default below). */
export const DEFAULT_BLOCKED_PROVIDERS = ["qwen-tp"];

/** Default latch TTL — 24h. The poller is the restore authority and clears on
 * verified balance; without it, a stale latch self-heals in one TTL so the
 * primary is re-tried at most once per TTL (bounded churn). */
export const DEFAULT_LATCH_TTL_MS = 24 * 60 * 60 * 1000;

/** Env override seam for tests. */
export function failoverDisabled(env: Record<string, string | undefined> = process.env): boolean {
  return env[PROVIDER_FAILOVER_DISABLE] === "1";
}

/** Per-dispatch must-stay: resolution keeps the requested leg even when the
 * family/primary is latched. */
export function noHop(env: Record<string, string | undefined> = process.env): boolean {
  return env[PI_FAILOVER_NO_HOP] === "1";
}

/** Fail-fast: a dispatch that WOULD hop returns the halt class instead. */
export function blockOnExhaustion(env: Record<string, string | undefined> = process.env): boolean {
  return env[TASK_EXHAUSTION_BLOCK] === "1";
}

export function latchTtlMs(env: Record<string, string | undefined> = process.env): number {
  const raw = Number(env[PROVIDER_EXHAUSTION_TTL_MS]);
  return Number.isFinite(raw) && raw > 0 ? raw : DEFAULT_LATCH_TTL_MS;
}

/** Blocked (excluded-with-alert) provider ids. The env var, when PRESENT
 * (even empty), is the full list — config-only re-enable of qwen-tp = export
 * PROVIDER_FAILOVER_BLOCKED="". When ABSENT, the default 401-blocked set
 * (["qwen-tp"]) applies. */
export function blockedProviders(env: Record<string, string | undefined> = process.env): string[] {
  const raw = env[PROVIDER_FAILOVER_BLOCKED];
  if (raw === undefined) return [...DEFAULT_BLOCKED_PROVIDERS];
  return raw.split(",").map((s) => s.trim()).filter(Boolean);
}

// ── State types ─────────────────────────────────────────────────────────────

export type LatchStatus = "exhausted" | "halt";
export type LatchReason = "402" | "low_balance" | "poller" | "manual";
export type LatchSource = "marker" | "poller" | "interactive" | "manual";

export interface LegRef {
  provider: string;
  model: string;
}

export interface FamilyLatch {
  /** The leg currently serving this family (null = the primary is serving). */
  activeLeg: LegRef | null;
  /** Number of marker-driven chain re-advances recorded for this family in
   * the CURRENT latch record (each marker from the serving leg that moves the
   * active leg counts; the very first marker that SETS the active leg counts
   * 1, re-advances increment). Inert today — no read site — but part of the
   * durable JSON contract mirrored by deepseek-balance-latch.py. */
  hopCount: number;
  /** Last exhaustion reason observed on the CURRENT leg. */
  lastReason: string | null;
  /** True when the whole chain was exhausted at latch time — resolution must
   * HALT (never re-walk from the primary past known-exhausted legs). */
  terminal?: boolean;
}

export interface PrimaryLatch {
  /** Account-level status — the primary provider's balance is exhausted.
   * NOTE (deep-review, qualified): a drain records under the family ROOT only
   * when it continues an IN-FLIGHT root exhaustion (root latch FRESH at write
   * time) or IS the root leg; a hop-leg drain with the root stale/absent
   * records under the DRAINED provider's own entry (see setExhausted — a
   * healthy root must not be re-latched on another account's evidence). The
   * root record's per-family state is authoritative for chain resolution;
   * resolution HALTS the family only when the root record itself is fresh and
   * terminal/chain-exhausted (the conservative direction — re-dispatching a
   * dead hop leg is strictly worse than a bounded halt). */
  status: LatchStatus;
  reason: LatchReason;
  source: LatchSource;
  latchedAt: string; // ISO
  expiresAt: string; // ISO
  /** Per alias-family chain-advance state. */
  families: Record<string, FamilyLatch>;
  /** First-class notice (interactive footer/ledger); null = no notice. */
  notice: { title: string; body: string } | null;
}

export interface LatchState {
  version: 1;
  epoch: number;
  updatedAt: string;
  primaries: Record<string, PrimaryLatch>;
  /** Provider-level runtime auth-blocks (401/403 markers/probes) — top-level
   * so a primary clear (balance restore) never wipes a still-true auth block
   * (review P2). Blocks are READ-SIDE TTL-bounded at exclusion time (see
   * blockedLegSet): an unrenewed block stops excluding its provider after one
   * latch TTL (self-heal on key remediation); a still-blocked provider is
   * re-stamped fresh by the next real 401/403 observation (markLegBlocked
   * re-arms stale blocks). The env-list (PROVIDER_FAILOVER_BLOCKED) is the
   * config-permanent mechanism — durable blocks are runtime evidence with a
   * self-heal bound, not a config lockout. */
  blockedLegs: Record<string, { reason: string; at: string }>;
}

export const EMPTY_LATCH: LatchState = {
  version: 1,
  epoch: 0,
  updatedAt: "",
  primaries: {},
  blockedLegs: {},
};

// ── Agent-dir / path resolution ─────────────────────────────────────────────

export function agentDir(env: Record<string, string | undefined> = process.env): string {
  return env.PI_CODING_AGENT_DIR || path.join(homedir(), ".pi", "agent");
}

export function latchStateFile(env: Record<string, string | undefined> = process.env): string {
  return path.join(agentDir(env), "state", "provider-exhaustion.json");
}

export function latchLockFile(env: Record<string, string | undefined> = process.env): string {
  return path.join(agentDir(env), "state", "provider-exhaustion.json.lock");
}

export function auditLedgerFile(env: Record<string, string | undefined> = process.env): string {
  return path.join(agentDir(env), "audit", "provider-failover.jsonl");
}

// ── Alias-family chain table ────────────────────────────────────────────────

export interface AliasFamily {
  /** Canonical family key (model id normalized). */
  family: string;
  /** Fully-qualified ordered legs: index 0 is the primary (official) leg. */
  legs: LegRef[];
}

/**
 * The per-model alias-family CHAIN TABLE. A family's ordered legs are the hop
 * path when the primary balance exhausts. qwen-tp legs are present but gated
 * by blockedProviders() while the keys are 401-blocked (sC2); openrouter
 * slugs are the active secondary. Canonical addressing for slash-id legs is
 * provider/model (s7: bare slugs resolve to the deepseek provider).
 *
 * Config-only re-enable of a blocked provider = removing it from
 * PROVIDER_FAILOVER_BLOCKED / DEFAULT_BLOCKED_PROVIDERS — no code change.
 */
export const ALIAS_FAMILIES: Record<string, AliasFamily> = {
  "deepseek-v4-flash": {
    family: "deepseek-v4-flash",
    legs: [
      { provider: "deepseek", model: "deepseek-v4-flash" },
      { provider: "qwen-tp", model: "deepseek-v4-flash-0731" },
      { provider: "openrouter", model: "deepseek/deepseek-v4-flash" },
    ],
  },
  "deepseek-v4-pro": {
    family: "deepseek-v4-pro",
    legs: [
      { provider: "deepseek", model: "deepseek-v4-pro" },
      { provider: "qwen-tp", model: "deepseek-v4-pro" },
      { provider: "openrouter", model: "deepseek/deepseek-v4-pro" },
    ],
  },
};

/** Normalize a (provider, model) onto its alias-family key. Unknown model ids
 * return undefined (no chain → no hop for that model). The -0731 rename and
 * the openrouter BASE slugs normalize onto the flash/pro families.
 *
 * Deliberately EXACT (review R4 P2): prefix rules would silently map variants
 * (deepseek-v4-flash-vision-exp, deepseek-v4-pro-0813) onto the base family
 * and resolution would SUBSTITUTE the base hop slug for the requested variant
 * under a latch. Variants resolve to no family → must-stay passthrough → an
 * exhaustion marker on the variant still latches the account (family absent). */
export function familyOf(modelId: string | null | undefined, provider?: string | null): string | undefined {
  if (!modelId) return undefined;
  const id = modelId.trim();
  if (!id) return undefined;
  if (ALIAS_FAMILIES[id]) return id;
  if (id === "deepseek-v4-flash-0731") return "deepseek-v4-flash";
  // openrouter slugs arrive as "deepseek/deepseek-v4-flash" (slash id). Only
  // the BASE slug names hop (never -vision-exp / -0813 variants — see above).
  if (provider === "openrouter" || id.includes("/")) {
    const slug = id.includes("/") ? id.slice(id.lastIndexOf("/") + 1) : id;
    if (slug === "deepseek-v4-flash") return "deepseek-v4-flash";
    if (slug === "deepseek-v4-pro") return "deepseek-v4-pro";
  }
  return undefined;
}

export function familyLegs(family: string): LegRef[] | undefined {
  return ALIAS_FAMILIES[family]?.legs;
}

/** Is `provider` a member of the family's chain table (root + hop legs)?
 * Providers NOT in the table are INDEPENDENT accounts for that family
 * (#512): a request for them is an explicit per-dispatch choice (the cold-
 * class venice seam), not a chain hop — so their resolution and exhaustion
 * records must never be absorbed by the family root's latch state (no
 * root-shadow; own-account write placement).
 *
 * The discriminator is used identically on BOTH the read side
 * (resolveWithChain) and the write side (setExhausted) so the root-shadow
 * and the account-of-record placement cannot disagree. A provider in
 * ({root} ∪ family legs) keeps the #476 semantics byte-for-byte — this
 * helper returns true for every existing table leg (deepseek/qwen-tp/
 * openrouter), so existing pins are the byte-parity proof. */
export function legIsFamilyMember(family: string | undefined, provider: string): boolean {
  if (!family) return false;
  const legs = familyLegs(family);
  return legs !== undefined && legs.some((l) => l.provider === provider);
}

// ── Exhaustion signature (text classifier) ──────────────────────────────────

export type ExhaustionKind = "exhaustion" | "auth_permanent" | "audit_only" | null;

export interface ExhaustionClass {
  kind: ExhaustionKind;
  /** 402 | low_balance | blocked | null */
  reason: LatchReason | "blocked" | null;
  /** Which signature pattern matched (for tests/audit). */
  matched: string | null;
}

const SIG_EXHAUST_402 = /\b402\b/;
const SIG_INSUFFICIENT_BALANCE = /(insufficient\s+balance|balance\s+insufficient)/i;
/** Credit-exhaustion variants: "credit balance too low" (observed) and
 * OpenRouter's actual 402 body text "Insufficient credits. Add more using
 * https://openrouter.ai/credits" (SDK path omits the status — review P2). */
const SIG_CREDIT_LOW = /(credit\s+balance\s+(?:is\s+)?too\s+low|insufficient\s+credit)/i;
/** 402 co-occurring with a credit-exhaustion phrase within a bounded
 * line-local window (review P2 — a distant balance/credit word on another
 * line must not pair with an unrelated 402 token). Bare `credit`, bare
 * `balance`, and bare `quota` are EXCLUDED (review R2 — "402 credit card
 * declined" is payment-method text; "402 … quota report" is not balance
 * exhaustion; genuine "Insufficient credits…" is caught by SIG_CREDIT_LOW
 * earlier). `insufficient` alone is kept: SDK-wrapped OpenAI-style bodies
 * carry the literal type `insufficient_quota` next to the status. */
const SIG_402_CREDIT = /402[^\n]{0,160}(insufficient|credit\s+balance|too\s+low|exhausted)|(insufficient|credit\s+balance|too\s+low|exhausted)[^\n]{0,160}402/i;
/** Fuzzy billing wording WITHOUT 402 → audit-only (never latches). */
const SIG_FUZZY = /(insufficient_quota|insufficient quota|billing|usage limit reached|monthly usage|quota exceeded|credit balance)/i;
const SIG_AUTH_KEY = /(invalid\s+x-api-key|invalid\s+api[_-]?key|api[_-]?key.{0,40}(invalid|incorrect|blocked)|api\s+key.{0,40}(invalid|incorrect|blocked)|incorrect\s+api\s+key|invalid_api_key|apikey-error)/i;
/** Venice 402/exhaustion patterns (#512, docs-anchored — docs.venice.ai
 * /api-reference/error-codes; amendment-3 P1). The published schema:
 *   - error.code INSUFFICIENT_BALANCE, message "Insufficient USD or Diem
 *     balance to complete request…" — the "USD or Diem" interjection breaks
 *     SIG_INSUFFICIENT_BALANCE (contiguous "insufficient balance" only); no
 *     credit/402 token → every pre-extension signature missed it → null →
 *     no marker → no latch → the exact event #512 exists for silently fails
 *     reviews.
 *   - error.code API_KEY_DIEM_SPEND_LIMIT_EXCEEDED /
 *     API_KEY_USD_SPEND_LIMIT_EXCEEDED, message "…spend limit exceeded…" —
 *     contains NO (insufficient|credit|too low|exhausted) token, so the
 *     spend-limit wording alone must not classify; the snake-case CODE token
 *     is the anchor (OpenAI-compatible bodies carry code next to message).
 *   - 401-class: AUTHENTICATION_FAILED bodies carry key wording ("API key …
 *     invalid") → SIG_AUTH_KEY above fires first; PRO_ONLY_MODEL is a
 *     model-tier error (NOT balance/auth) → stays null (audit-only).
 * NOTE (residual, #512 P1-4/0b): fixtures are docs-anchored/assumed — the
 * classifier link is MECHANISM-verified via the mock-endpoint test; a REAL
 * venice 402 body is an OPEN operator gate until a drained second account
 * or go-live capture lands. If a real body later misses, extend these
 * signatures (same route as OpenRouter's body forcing SIG_CREDIT_LOW). */
const SIG_VENICE_INSUFFICIENT = /insufficient\s+USD\s+or\s+Diem\s+balance/i;
/** Snake-case balance/spend code tokens (OpenAI-compatible error.code field). */
const SIG_VENICE_BALANCE_CODE = /\b(?:INSUFFICIENT_BALANCE|API_KEY_(?:USD|DIEM)_SPEND_LIMIT_EXCEEDED)\b/;
/** Spend-limit prose co-occurring with the code token (prose alone never
 * classifies — no balance/credit semantic without the code). */
const SIG_SPEND_LIMIT_PROSE = /spend\s+limit\s+exceeded/i;

/**
 * Classify a provider error/status text against the exhaustion signature.
 *
 * Falsification pins (must hold):
 *   - canonical 402 Insufficient Balance → exhaustion/402
 *   - "credit balance too low" variant  → exhaustion/low_balance
 *   - 401-invalid-key, healthy exits, and output that merely QUOTES the
 *     402 payload → NEVER exhaustion (auth_permanent / audit_only / null)
 *
 * NOTE the classifier sees real provider errorMessage text (message_end
 * payload) or real HTTP status text — never assistant content (the caller
 * anchors the source; see sB1 — content-quoting is excluded by anchoring on
 * the stderr channel / errorMessage, not content text).
 */
export function classifyExhaustionText(text: string | null | undefined): ExhaustionClass {
  if (!text) return { kind: null, reason: null, matched: null };
  const t = text.slice(0, 2000); // bounded — status bodies are short

  // Permanent auth class FIRST (401/403 + key wording, OR key wording alone —
  // real 401 bodies often omit the status number in the message text, e.g.
  // DeepSeek's `Authentication Fails, Your api key: **** is invalid` and
  // Aliyun's `Incorrect API key provided ... apikey-error`). Never exhaustion.
  if (SIG_AUTH_KEY.test(t)) {
    return { kind: "auth_permanent", reason: "blocked", matched: "auth-key-wording" };
  }

  const has402 = SIG_EXHAUST_402.test(t);
  if (SIG_INSUFFICIENT_BALANCE.test(t)) {
    return {
      kind: "exhaustion",
      reason: has402 ? "402" : "low_balance",
      matched: "insufficient-balance",
    };
  }
  // Venice (#512, amendment-3 P1): the published "Insufficient USD or Diem
  // balance" message — the "USD or Diem" interjection sits between
  // "insufficient" and "balance", so the contiguous signature above cannot
  // match it. Classified AFTER the canonical contiguous form (exact-match
  // precedence), with the same 402/low_balance reason split on the status.
  if (SIG_VENICE_INSUFFICIENT.test(t)) {
    return {
      kind: "exhaustion",
      reason: has402 ? "402" : "low_balance",
      matched: "venice-insufficient-usd-or-diem",
    };
  }
  // Venice spend-limit class: the code token (INSUFFICIENT_BALANCE /
  // API_KEY_*_SPEND_LIMIT_EXCEEDED) is the anchor — the prose alone
  // ("spend limit exceeded") carries no balance/credit semantic and must not
  // classify. An OpenAI-compatible 402 body ships the snake code next to the
  // message, so code-token co-occurrence with the prose (or the code token
  // alone — the message may not repeat it) is the exhaustion signal.
  if (SIG_VENICE_BALANCE_CODE.test(t)) {
    return {
      kind: "exhaustion",
      reason: has402 ? "402" : "low_balance",
      matched: SIG_SPEND_LIMIT_PROSE.test(t) ? "venice-spend-limit-code" : "venice-balance-code",
    };
  }
  if (SIG_CREDIT_LOW.test(t)) {
    return {
      kind: "exhaustion",
      reason: has402 ? "402" : "low_balance",
      matched: /insufficient\s+credit/i.test(t) ? "insufficient-credit" : "credit-balance-too-low",
    };
  }
  if (SIG_402_CREDIT.test(t)) {
    // 402 co-occurring with credit semantics within a line-local window — the
    // SDK-wrapped status shape. Line-local + credit-scoped so "billing: 402
    // invoices pending" (audit-only) can never latch (review P3).
    return { kind: "exhaustion", reason: "402", matched: "402+credit-near" };
  }
  if (SIG_FUZZY.test(t)) {
    // fuzzy billing wording without 402 — audit-only (never latch) per plan
    return { kind: "audit_only", reason: null, matched: "billing-fuzzy" };
  }
  return { kind: null, reason: null, matched: null };
}

// ── Marker format ([provider-exhaustion] kind — sB1 SPEC) ───────────────────

export const EXHAUSTION_MARKER_PREFIX = "[provider-exhaustion]";

export interface ExhaustionMarker {
  kind: "provider-exhaustion";
  hop: string; // "deepseek->qwen-tp"
  model: string; // the leg model that failed
  reason: string; // 402 | low_balance | blocked
  provider: string; // the provider whose balance/account exhausted
  nonce: string; // TASK_HEARTBEAT_NONCE when the parent authenticates
}

/** Render the marker line (sB1 SPEC): single line, ASCII key=value tokens,
 * \n-terminated, no spaces in values, charset [A-Za-z0-9_.:/\->+=-]. */
export function renderExhaustionMarker(m: ExhaustionMarker): string {
  return (
    `${EXHAUSTION_MARKER_PREFIX} hop=${m.hop} model=${m.model} reason=${m.reason} ` +
    `provider=${m.provider} nonce=${m.nonce}\n`
  );
}

const MARKER_LINE = /^\[provider-exhaustion\]\s+hop=(\S+)\s+model=(\S+)\s+reason=(\S+)\s+provider=(\S+)(?:\s+nonce=(\S+))?/;

/** Parse a marker line. Returns null for anything that is not an exhaustion
 * marker. The CALLER decides nonce policy (authenticate when the child was
 * spawned with TASK_HEARTBEAT=1). */
export function parseExhaustionMarker(line: string): ExhaustionMarker | null {
  const m = MARKER_LINE.exec(line.trim());
  if (!m) return null;
  return {
    kind: "provider-exhaustion",
    hop: m[1],
    model: m[2],
    reason: m[3],
    provider: m[4],
    nonce: m[5] ?? "",
  };
}

/** Scan a stderr blob for the exhaustion marker, line-anchored (sB1: never
 * match content text; anchor on the stderr channel). Returns the LAST
 * occurrence's parsed marker (or null). */
export function scanStderrForExhaustion(
  stderr: string | undefined | null,
  expectedNonce?: string,
  opts: { requireNonce?: boolean } = {},
): ExhaustionMarker | null {
  if (!stderr) return null;
  let found: ExhaustionMarker | null = null;
  for (const raw of stderr.split("\n")) {
    const line = raw.replace(/\x1b\[[0-9;]*[a-zA-Z]/g, "").trim();
    const marker = parseExhaustionMarker(line);
    if (!marker) continue;
    if (opts.requireNonce) {
      // FAIL CLOSED: with nonce enforcement on, a marker without a matching
      // expected nonce is rejected — including when NO expected nonce is
      // available (a child spawned without TASK_HEARTBEAT=1 must not be able
      // to forge a latch; sB1 finding 4).
      if (expectedNonce === undefined || marker.nonce !== expectedNonce) {
        continue;
      }
    }
    found = marker;
  }
  return found;
}

// ── Latch I/O (atomic, CAS, self-heal, never throws) ────────────────────────

const MAX_STATE_BYTES = 1 << 20; // refuse to parse > 1 MB
const CAS_ATTEMPTS = 3;

/** Lock tuning (rare-path — latch writes only). Env-tunable for tests. */
export const PF_LOCK_WAIT_MS = "PROVIDER_FAILOVER_LOCK_WAIT_MS";
export const DEFAULT_LOCK_WAIT_MS = 12_000; // > stale threshold → reclaim mid-wait
const LOCK_STALE_MS = 8_000;

/** Read + parse the latch state. Corrupt file → renamed aside + empty state.
 * Stale entries are NOT pruned here — resolution treats them as clear. */
export function readLatchState(env: Record<string, string | undefined> = process.env): LatchState {
  try {
    const file = latchStateFile(env);
    if (!fs.existsSync(file)) return { ...EMPTY_LATCH };
    const stat = fs.statSync(file);
    if (stat.size > MAX_STATE_BYTES) {
      selfHealCorrupt(file, "size");
      return { ...EMPTY_LATCH };
    }
    const data = JSON.parse(fs.readFileSync(file, "utf-8")) as Partial<LatchState>;
    if (!data || typeof data !== "object" || !data.primaries || typeof data.primaries !== "object") {
      selfHealCorrupt(file, "schema");
      return { ...EMPTY_LATCH };
    }
    return {
      version: 1,
      epoch: typeof data.epoch === "number" && data.epoch >= 0 ? data.epoch : 0,
      updatedAt: typeof data.updatedAt === "string" ? data.updatedAt : "",
      primaries: data.primaries as Record<string, PrimaryLatch>,
      blockedLegs:
        data.blockedLegs && typeof data.blockedLegs === "object"
          ? (data.blockedLegs as LatchState["blockedLegs"])
          : {},
    };
  } catch (err) {
    const file = latchStateFile(env);
    try {
      selfHealCorrupt(file, "parse");
    } catch {
      /* double fault — still never throw */
    }
    return { ...EMPTY_LATCH };
  }
}

function selfHealCorrupt(file: string, why: string): void {
  try {
    const backup = `${file}.corrupt-${Date.now()}`;
    fs.renameSync(file, backup);
    console.warn(`[provider-failover] corrupt latch state moved to ${backup} (${why})`);
  } catch {
    try {
      fs.rmSync(file, { force: true });
    } catch {
      /* never throw */
    }
  }
}

// module-level once-per-process-per-epoch cap
let lastWrittenEpoch = -1;
let lastWrittenHash = "";

/** Remove orphaned .tmp-* siblings older than one hour (crash between fsync
 * and rename). Best-effort; never throws. */
function sweepStaleTmp(dir: string): void {
  try {
    const now = Date.now();
    for (const f of fs.readdirSync(dir)) {
      if (!f.includes(".tmp-")) continue;
      try {
        const st = fs.statSync(path.join(dir, f));
        if (now - st.mtimeMs > 60 * 60 * 1000) fs.rmSync(path.join(dir, f), { force: true });
      } catch {
        /* raced */
      }
    }
  } catch {
    /* dir missing */
  }
}

function contentHash(state: LatchState): string {
  return createHash("sha1").update(JSON.stringify(state)).digest("hex");
}

/** Acquire the O_EXCL writer lock (pidfile). Returns a release fn or null if
 * the lock could not be acquired within the wait budget (degraded — proceed
 * unlocked; the atomic rename + readback CAS still prevent torn files and
 * converge lost updates).
 *
 * Staleness = holder PID dead (crashed writer — reclaimed immediately) OR
 * lock age > LOCK_STALE_MS (wedged-holder recovery: a live holder stuck past
 * the stale threshold is presumed deadlocked — real holders hold for
 * microseconds, so an 8s+ hold is pathological). */
function acquireLock(lockFile: string, env: Record<string, string | undefined>): (() => void) | null {
  const rawWait = Number(env[PF_LOCK_WAIT_MS]);
  const waitMs = Number.isFinite(rawWait) && rawWait > 0 ? rawWait : DEFAULT_LOCK_WAIT_MS;
  const deadline = Date.now() + waitMs;
  let owned = false;
  for (;;) {
    try {
      const fd = fs.openSync(lockFile, "wx", 0o600);
      fs.writeSync(fd, String(process.pid));
      fs.closeSync(fd);
      owned = true;
      return () => {
        if (!owned) return; // never delete a lock we do not own
        try {
          // ownership check before unlink — a stale-reclaim cycle must not
          // delete a lock a THIRD process now holds
          const cur = fs.readFileSync(lockFile, "utf-8").trim();
          if (cur === String(process.pid)) fs.rmSync(lockFile, { force: true });
        } catch {
          /* already gone */
        }
      };
    } catch (err: any) {
      if (err?.code !== "EEXIST") {
        // read-only dir / permissions — degrade unlocked
        return null;
      }
      // stale-lock self-heal: dead holder PID or age past the stale threshold
      let stale = false;
      try {
        const holder = fs.readFileSync(lockFile, "utf-8").trim();
        const holderPid = Number(holder);
        if (Number.isInteger(holderPid) && holderPid > 0) {
          try {
            process.kill(holderPid, 0);
            // holder alive → not stale (age backstop below)
          } catch {
            stale = true; // ESRCH — holder is dead
          }
        } else {
          stale = true; // unreadable/empty lock → stale
        }
      } catch {
        /* lock vanished — retry */
        continue;
      }
      if (!stale) {
        try {
          const st = fs.statSync(lockFile);
          stale = Date.now() - st.mtimeMs > LOCK_STALE_MS;
        } catch {
          /* vanished — retry */
          continue;
        }
      }
      if (stale) {
        try {
          fs.rmSync(lockFile, { force: true });
        } catch {
          /* raced — retry */
        }
        continue;
      }
      if (Date.now() >= deadline) return null;
      // busy-wait briefly (writers are microsecond-scale)
      const waitUntil = Date.now() + 15;
      while (Date.now() < waitUntil) { /* spin */ }
    }
  }
}

/** CAS write of `next` — requires next.epoch === cur.epoch + 1 (callers use
 * updateLatchState, which re-reads). Returns true when a durable write
 * happened. Honors the once-per-process-per-epoch cap. Never throws. */
function tryWriteLatchState(next: LatchState, env: Record<string, string | undefined>): boolean {
  try {
    const file = latchStateFile(env);
    const cur = readLatchState(env);
    if (next.epoch !== cur.epoch + 1) return false; // lost CAS — caller re-reads
    const hash = contentHash(next);
    if (lastWrittenEpoch === next.epoch && lastWrittenHash === hash) {
      // once-per-process-per-epoch cap — only reachable after a corrupt-file
      // self-heal reset the durable epoch backward. Verify on-disk before
      // returning true: a reset between our write and now means the durable
      // file no longer carries this state (review P2 — never report a durable
      // write that a self-heal since erased).
      try {
        const onDisk = fs.readFileSync(file, "utf-8");
        if (onDisk.trim() === JSON.stringify(next, null, 2)) return true;
      } catch {
        return false; // file gone/reset → fall through to a real write
      }
      // fall through: on-disk diverged → write again below
    }
    const dir = path.dirname(file);
    fs.mkdirSync(dir, { recursive: true });
    const tmp = `${file}.tmp-${process.pid}-${Date.now()}`;
    const fd = fs.openSync(tmp, "w", 0o600);
    try {
      fs.writeSync(fd, JSON.stringify(next, null, 2) + "\n");
      fs.fsyncSync(fd);
    } finally {
      fs.closeSync(fd);
    }
    fs.renameSync(tmp, file);
    // readback verification — a racing unlocked writer that renamed after us
    // makes the readback mismatch → false → the CAS loop merges + retries
    try {
      const onDisk = fs.readFileSync(file, "utf-8");
      if (onDisk.trim() !== JSON.stringify(next, null, 2)) return false;
    } catch {
      return false;
    }
    lastWrittenEpoch = next.epoch;
    lastWrittenHash = hash;
    return true;
  } catch (err: any) {
    // Header contract: write failures are surfaced with an audit-only warn
    // (never thrown — dispatch must not break on a state-dir problem). The
    // caller degrades to an in-memory decision; the next process/write retries.
    console.warn(`[provider-failover] latch write failed — ${err?.message ?? String(err)}`);
    return false; // never throw; callers degrade to in-memory decision
  }
}

/** Read → mutate (with CAS re-read) → atomic write. The mutator receives the
 * current state and returns the next state (epoch is bumped here). Returns
 * the resulting state (the caller re-reads what is durable). Never throws. */
export function updateLatchState(
  mutate: (cur: LatchState) => LatchState,
  env: Record<string, string | undefined> = process.env,
): LatchState {
  const lockFile = latchLockFile(env);
  // mkdir BEFORE the lock so the very first write on a fresh install takes
  // the O_EXCL path (review P3: openSync wx on a missing dir ENOENTs and
  // silently degrades to unlocked).
  try {
    fs.mkdirSync(path.dirname(lockFile), { recursive: true });
  } catch {
    /* never throw */
  }
  const release = acquireLock(lockFile, env);
  try {
    // sweep stale tmp litter (crash between fsync and rename orphans a tmp
    // file forever — the lock self-heals, the tmp never did; review P2)
    sweepStaleTmp(path.dirname(lockFile));
    for (let attempt = 0; attempt < CAS_ATTEMPTS; attempt++) {
      const cur = readLatchState(env);
      const next = mutate(cur);
      if (next === cur) return cur; // no-op mutation
      next.epoch = cur.epoch + 1;
      next.updatedAt = new Date().toISOString();
      if (tryWriteLatchState(next, env)) return readLatchState(env);
    }
    // CAS exhausted (contended) — return what's durable now
    return readLatchState(env);
  } finally {
    release?.();
  }
}

// ── Latch mutations ─────────────────────────────────────────────────────────

export interface LatchInput {
  primaryProvider: string;
  reason: LatchReason;
  source: LatchSource;
  /** The family that exhausted, when known (per-model chain advance). */
  family?: string;
  /** The leg that was serving and exhausted (its next hop is computed). */
  fromLeg?: LegRef;
  notice?: { title: string; body: string } | null;
  /** Override the computed expiry (tests). */
  ttlMs?: number;
  env?: Record<string, string | undefined>;
}

/** Whether the primary currently has a FRESH (non-stale) latch. Freshness is
 * latchedAt + the CURRENT env TTL (so shortening PROVIDER_EXHAUSTION_TTL_MS
 * takes effect immediately); the stamped expiresAt is the fallback when
 * latchedAt is missing. Missing both → latched (fail-closed). */
export function isLatched(
  primaryProvider: string,
  state: LatchState,
  opts: { now?: number; env?: Record<string, string | undefined>; ttlMs?: number } = {},
): boolean {
  const p = state.primaries[primaryProvider];
  if (!p) return false;
  const env = opts.env ?? process.env;
  const now = opts.now ?? Date.now();
  const ttl = opts.ttlMs ?? latchTtlMs(env);
  return recordFresh(p, now, ttl);
}

function blockedLegSet(state: LatchState, env: Record<string, string | undefined>, now: number, ttl: number): Set<string> {
  const s = new Set<string>(blockedProviders(env));
  // Durable auth-blocks (blockedLegs) are read-side TTL-bounded: a block
  // older than one latch TTL stops excluding its provider from hop candidates
  // (self-heal — a remediated key/leg becomes retryable without a manual
  // unblock; a still-blocked leg is re-recorded fresh by the next real 401/403
  // marker or probe). Without this bound a FALSE block (e.g. a transient
  // gateway body misclassified pre-narrowing) would exclude a healthy hop
  // provider forever (review P2).
  for (const [id, rec] of Object.entries(state.blockedLegs ?? {})) {
    const at = rec && typeof rec.at === "string" ? Date.parse(rec.at) : NaN;
    if (Number.isFinite(at) && now - at > ttl) continue;
    s.add(id);
  }
  return s;
}

/** Is this latch record FRESH at (now, ttl)? Shared by isLatched + resolution
 * + the hop-candidate availability check. */
function recordFresh(p: PrimaryLatch, now: number, ttl: number): boolean {
  const from = p.latchedAt ? Date.parse(p.latchedAt) : NaN;
  const expiry = Number.isFinite(from) ? from + ttl : p.expiresAt ? Date.parse(p.expiresAt) : NaN;
  if (!Number.isFinite(expiry)) return true; // no timestamps → fail closed
  return now < expiry;
}

/** Providers that must NOT serve as hop candidates right now: env-blocked ∪
 * durable auth blocks ∪ providers holding a FRESH own exhaustion record
 * (their own account drained — review R2 finding 1: the advance path and the
 * active-leg serve must never hop into a freshly-exhausted provider). */
function unavailableProviders(
  state: LatchState,
  env: Record<string, string | undefined>,
  now: number,
  ttl: number,
): Set<string> {
  const s = blockedLegSet(state, env, now, ttl);
  for (const [prov, rec] of Object.entries(state.primaries)) {
    if (rec.status === "exhausted" && recordFresh(rec, now, ttl)) s.add(prov);
  }
  return s;
}

/** The ROOT (account-of-record) provider of an alias family — the provider
 * whose balance drain the chain hop recovers from. Every family's root is its
 * first (primary official) leg's provider. DRAIN ACCOUNT-OF-RECORD (deep-*re-
 * view): a drain is recorded under the root only when it continues an IN-FLIGHT
 * root exhaustion (root latch FRESH at write time) or IS the root leg; a hop-
 * leg drain with the root stale/absent records under the drained provider's
 * OWN entry (see setExhausted) so a healthy root is never re-latched on
 * another account's evidence — and a primaries["openrouter"] own record IS
 * consulted: unavailableProviders() excludes the drained provider from hop
 * candidates, and resolution's root-ask reads the (absent) root record as
 * clear. */
export function rootPrimaryOfFamily(family: string | undefined): string | undefined {
  if (!family) return undefined;
  return familyLegs(family)?.[0]?.provider;
}

/** The next un-blocked leg after `after` within a family's ordered chain.
 * Returns the leg, or the HALT sentinel when every later leg is blocked/
 * absent. Pure. */
export interface ChainStep {
  leg: LegRef | null;
  halted: boolean;
  skipped: LegRef[]; // blocked legs skipped on the way (excluded-with-alert)
}

export function nextLegAfter(
  family: string,
  after: LegRef,
  state: LatchState,
  opts: { env?: Record<string, string | undefined>; now?: number; ttlMs?: number } = {},
): ChainStep {
  const env = opts.env ?? process.env;
  const now = opts.now ?? Date.now();
  const ttl = opts.ttlMs ?? latchTtlMs(env);
  const legs = familyLegs(family);
  if (!legs) return { leg: null, halted: true, skipped: [] };
  // Hop candidates = legs after `after`, minus: env-blocked ∪ durable auth
  // blocks ∪ providers holding a FRESH own exhaustion record (review R2 —
  // never advance INTO a freshly-exhausted provider).
  const unavailable = unavailableProviders(state, env, now, ttl);
  const startIdx = legs.findIndex((l) => l.provider === after.provider && l.model === after.model);
  const skipped: LegRef[] = [];
  for (let i = startIdx + 1; i < legs.length; i++) {
    const leg = legs[i];
    if (unavailable.has(leg.provider)) {
      skipped.push(leg);
      continue;
    }
    return { leg, halted: false, skipped };
  }
  return { leg: null, halted: true, skipped };
}

/**
 * Resolve the leg a dispatch should use for (family, requestedLeg):
 *   - failover disabled / no-hop / no fresh latch / family unknown →
 *     the requested leg (must-stay)
 *   - fresh latch + family activeLeg set → the activeLeg (if not blocked)
 *   - fresh latch + no activeLeg → the next un-blocked leg after the
 *     requested (primary) leg
 *   - nothing left → HALT (structured class — caller fails the dispatch
 *     with the halt class, never silently reusing a latched default)
 *
 * NOTE (review R4 P2, accepted residual): advance walks from the REQUESTED
 * leg. A hop-ask for the FINAL chain leg while a fresh account-level latch
 * carries no per-family state halts (nothing after the final leg) where the
 * same state from a root-ask resolves the final leg — conservative direction
 * (halt, never a wrong dispatch); the primary dispatch path always requests
 * the primary or the leg just used, so the disagreement is unreachable there.
 */
export interface ResolveOutcome {
  leg: LegRef | null;
  halted: boolean;
  reason: "clear" | "no-hop" | "disabled" | "latched-active" | "latched-advance" | "halt" | "unknown-family";
  hop: string | null; // "deepseek->qwen-tp" style when hopping
}

export function resolveWithChain(
  family: string | undefined,
  requested: LegRef,
  state: LatchState,
  opts: { env?: Record<string, string | undefined>; now?: number; ttlMs?: number } = {},
): ResolveOutcome {
  const env = opts.env ?? process.env;
  const now = opts.now ?? Date.now();
  const ttl = opts.ttlMs ?? latchTtlMs(env);
  if (failoverDisabled(env)) return { leg: requested, halted: false, reason: "disabled", hop: null };
  if (noHop(env)) return { leg: requested, halted: false, reason: "no-hop", hop: null };
  if (!family) return { leg: requested, halted: false, reason: "unknown-family", hop: null };

  const rootPrimary = family ? rootPrimaryOfFamily(family) : undefined;
  // READ-side root preference (reviews P2 + R2 finding 1): for a HOP-leg ask
  // the family ROOT record is authoritative when fresh (family chain state
  // lives there); a stale own record at the hop provider must NOT shadow the
  // fresh root into a 'clear' re-dispatch of a terminal-halted leg. When no
  // root record exists (or it is stale), a fresh OWN record at the hop
  // provider still blocks the direct ask (its own account drained).
  const own = state.primaries[requested.provider];
  const rootRec = rootPrimary ? state.primaries[rootPrimary] : undefined;
  const isRootAsk = rootPrimary === undefined || requested.provider === rootPrimary;
  // #512 independent-provider rule (read side): a requested provider that is
  // NOT a member of the family chain table (e.g. venice — the cold-class
  // per-dispatch seam) is its OWN account. Its resolution must NEVER consult
  // the family root record — while the deepseek root is freshly latched
  // (in-flight exhaustion), an off-table venice ask must still resolve to
  // venice ("clear" when venice has no own record), not get root-shadowed
  // onto the root's active leg (openrouter) or halted. Table-leg asks
  // (deepseek root / qwen-tp / openrouter hops) keep the #476 root-shadow
  // semantics byte-for-byte (legIsFamilyMember is true for every table leg).
  const independentAsk = !isRootAsk && !legIsFamilyMember(family, requested.provider);
  let primary: PrimaryLatch | undefined;
  if (isRootAsk) {
    primary = own ?? rootRec;
  } else if (independentAsk) {
    primary = own;
  } else {
    const rootFresh = rootRec ? recordFresh(rootRec, now, ttl) : false;
    const ownFresh = own ? recordFresh(own, now, ttl) : false;
    primary = rootFresh ? rootRec : ownFresh ? own : (rootRec ?? own);
  }
  const fresh = primary !== undefined && recordFresh(primary, now, ttl);

  if (!fresh || !primary) return { leg: requested, halted: false, reason: "clear", hop: null };

  // TASK_EXHAUSTION_BLOCK=1 (fail-fast, not default): a dispatch that WOULD
  // hop fails with the halt class instead of silently moving legs.
  if (blockOnExhaustion(env)) {
    return { leg: null, halted: true, reason: "halt", hop: null };
  }

  const fam = primary.families?.[family];
  const unavailable = unavailableProviders(state, env, now, ttl);
  if (fam?.terminal) {
    return { leg: null, halted: true, reason: "halt", hop: null };
  }
  if (fam?.activeLeg && !unavailable.has(fam.activeLeg.provider)) {
    const hop = activeHop(requested, fam.activeLeg);
    return { leg: fam.activeLeg, halted: false, reason: "latched-active", hop };
  }
  // advance from the requested leg along the chain
  const step = nextLegAfter(family, requested, state, { env, now, ttlMs: ttl });
  if (step.halted) return { leg: null, halted: true, reason: "halt", hop: null };
  const hop = activeHop(requested, step.leg!);
  return { leg: step.leg, halted: false, reason: "latched-advance", hop };
}

function activeHop(from: LegRef, to: LegRef): string {
  return `${from.provider}->${to.provider}`;
}

function freshExpiry(ttlMs: number, now: number): string {
  return new Date(now + ttlMs).toISOString();
}

/**
 * Latch a primary provider as exhausted and advance the family's active leg.
 * Called with reason 402/low_balance from the send-side marker (child),
 * the interactive latch, or the poller. This is the sync-write-before-retry
 * durable write — dispatch must not retry until this returns.
 */
export function setExhausted(input: LatchInput): LatchState {
  const env = input.env ?? process.env;
  const now = Date.now();
  const ttl = input.ttlMs ?? latchTtlMs(env);
  const expiry = freshExpiry(ttl, now);
  return updateLatchState((cur) => {
    // ACCOUNT-OF-RECORD selection (review P2 + deep-review fix): a drain is
    // recorded under the family ROOT only when it is a continuation of an
    // IN-FLIGHT root exhaustion (the root record is FRESH at write time — the
    // hop-leg drain happened under an active root latch) or the drain IS the
    // root leg itself (first exhaustion of the primary). A hop-leg drain
    // observed while the root record is stale/absent is the HOP PROVIDER's own
    // account event (its credits drained — e.g. openrouter's independent
    // balance), NOT evidence about the root balance: recording it under the
    // root would re-latch a possibly-healthy primary for a full TTL and mark
    // the family terminal on evidence about the wrong account (deep finding
    // P2). Such drains record under the drained provider's own primaries
    // entry — unavailableProviders() then excludes that provider from hop
    // candidates (fresh own record) while the root family stays resolvable on
    // the primary.
    const root = input.family ? rootPrimaryOfFamily(input.family) : undefined;
    const fromIsRoot = input.fromLeg ? root !== undefined && input.fromLeg.provider === root : input.primaryProvider === root;
    const rootRec = root ? cur.primaries?.[root] : undefined;
    const rootFresh = rootRec ? recordFresh(rootRec, now, ttl) : false;
    // #512 independent-provider rule (write side): a drain on an OFF-TABLE
    // leg (provider not in the family chain — e.g. venice) is that provider's
    // OWN account event ALWAYS. Even under a FRESH root latch (in-flight
    // deepseek exhaustion), venice's drain evidence must record under
    // primaries["venice"] — never re-latch/advance the deepseek root on
    // another account's evidence — so the next cold dispatch resolves the
    // fresh venice record and hops off venice itself. Mirrors the read side
    // (resolveWithChain independentAsk): the discriminator is identical, so
    // root-shadow and write placement cannot disagree. Table-leg drains keep
    // the #476 account-of-record placement (root when in-flight/root leg).
    const fromIsIndependent =
      input.fromLeg !== undefined &&
      !legIsFamilyMember(input.family, input.fromLeg.provider);
    const primaryProvider = fromIsIndependent
      ? input.primaryProvider
      : root && (fromIsRoot || rootFresh)
        ? root
        : input.primaryProvider;
    const existing = cur.primaries[primaryProvider];
    const fam = input.family;
    const families: Record<string, FamilyLatch> = { ...(existing?.families ?? {}) };
    if (fam && input.fromLeg) {
      const step = nextLegAfter(fam, input.fromLeg, cur, { env, now, ttlMs: ttl });
      const prev = families[fam];
      if (!step.halted && step.leg) {
        // Chain (re-)engagement: a marker-driven write that SETS an active
        // leg counts 1 when the family record didn't exist or had no active
        // leg (first latch, or re-arm after a terminal/cleared record), and
        // re-advances count when the marker came from the CURRENT active leg.
        // A stale marker from a NON-active leg (out-of-band drain) does not
        // advance the count — the chain did not move from its position.
        const noActiveLeg = !prev?.activeLeg;
        const fromCurrentActive =
          !!prev?.activeLeg && prev.activeLeg.provider === input.fromLeg.provider && prev.activeLeg.model === input.fromLeg.model;
        const hopCount = (prev?.hopCount ?? 0) + (noActiveLeg || fromCurrentActive ? 1 : 0);
        families[fam] = {
          activeLeg: step.leg,
          hopCount,
          lastReason: input.reason,
          terminal: false,
        };
      } else {
        // every leg blocked → explicit halt class for this family (terminal:
        // resolution must not re-walk from the primary past these legs)
        families[fam] = {
          activeLeg: null,
          hopCount: prev?.hopCount ?? 0,
          lastReason: input.reason,
          terminal: true,
        };
      }
    } else if (fam && !input.fromLeg) {
      const prev = families[fam];
      families[fam] = {
        activeLeg: prev?.activeLeg ?? null,
        hopCount: prev?.hopCount ?? 0,
        lastReason: prev?.lastReason ?? input.reason,
        terminal: prev?.terminal ?? false,
      };
    }
    const notice = input.notice !== undefined ? input.notice : existing?.notice ?? null;
    const next: LatchState = {
      ...cur,
      primaries: {
        ...cur.primaries,
        [primaryProvider]: {
          status: "exhausted",
          reason: input.reason,
          source: input.source,
          latchedAt: new Date(now).toISOString(),
          expiresAt: expiry,
          families,
          notice,
        },
      },
    };
    return next;
  }, env);
}

/** Mark a leg/provider auth-blocked (401/403) — excluded-with-alert; NOT
 * exhaustion (never latches the balance). Blocks are TOP-LEVEL state
 * (provider-level), so a primary balance-restore clear never wipes a
 * still-true auth block (review P2).
 *
 * DURATION: blocks exclude at read time while FRESH (blockedLegSet bounds
 * them at one latch TTL — self-heal on key remediation). Re-observed 401/403
 * evidence re-arms a stale block (below), so a still-broken key stays
 * excluded without a manual unblock; a remediated key silently returns to
 * hop-candidate rotation once its block ages past the TTL.
 *
 * SCOPE (review R4 P2): blocking filters HOP CANDIDATES only — resolution's
 * 'clear' path still dispatches a requested leg that is itself blocked (no
 * exhaustion latch). Callers dispatching a provider that holds a durable auth
 * block must pre-check state.blockedLegs / blockedProviders() themselves. */
export function markLegBlocked(providerId: string, reason: string, opts: { env?: Record<string, string | undefined> } = {}): LatchState {
  const env = opts.env ?? process.env;
  const nowMs = Date.now();
  const now = new Date(nowMs).toISOString();
  return updateLatchState((cur) => {
    const existing = cur.blockedLegs?.[providerId];
    if (existing) {
      // Fresh double-block = no-op (byte-identical parity with the python
      // mirror op_block — the poller parity contract). A STALE block (older
      // than one latch TTL — read-side bound in blockedLegSet already stopped
      // excluding it) re-arms on fresh evidence: a re-observed 401/403 means
      // the key is STILL broken, so the block must exclude for another TTL;
      // without the re-stamp a still-blocked leg churns one doomed dispatch
      // per TTL forever after its first expiry.
      const at = typeof existing.at === "string" ? Date.parse(existing.at) : NaN;
      if (Number.isFinite(at) && nowMs - at <= latchTtlMs(env)) return cur;
    }
    return { ...cur, blockedLegs: { ...(cur.blockedLegs ?? {}), [providerId]: { reason, at: now } } };
  }, env);
}

/** Clear a blocked leg (poller found it healthy / key remediated). */
export function clearLegBlocked(providerId: string, opts: { env?: Record<string, string | undefined> } = {}): LatchState {
  const env = opts.env ?? process.env;
  return updateLatchState((cur) => {
    if (!cur.blockedLegs?.[providerId]) return cur;
    const blockedLegs = { ...cur.blockedLegs };
    delete blockedLegs[providerId];
    return { ...cur, blockedLegs };
  }, env);
}

/** Clear a primary's exhaustion latch (poller restore / interim manual
 * clear). Clears the whole primary (all families — one balance). */
export function clearExhaustion(
  primaryProvider: string,
  opts: { reason?: string; env?: Record<string, string | undefined> } = {},
): LatchState {
  const env = opts.env ?? process.env;
  const reason = opts.reason ?? "manual";
  return updateLatchState((cur) => {
    if (!cur.primaries[primaryProvider]) return cur;
    const primaries = { ...cur.primaries };
    delete primaries[primaryProvider];
    if (Object.keys(primaries).length === 0) {
      // keep epoch-tracked cur + TOP-LEVEL blockedLegs (review P2 — a balance
      // restore must not wipe still-true auth blocks); only primaries reset
      return { ...cur, primaries: {} };
    }
    return { ...cur, primaries };
  }, env);
}

/** Interim manual-clear helper (ships with Phases 1/2): clears the named
 * primary or EVERYTHING when '*' is passed. Returns the resulting state. */
export function manualClear(primaryOrAll: string, env: Record<string, string | undefined> = process.env): LatchState {
  const cur = readLatchState(env);
  if (primaryOrAll === "*") {
    return updateLatchState(() => ({ ...EMPTY_LATCH }), env);
  }
  return clearExhaustion(primaryOrAll, { reason: "manual", env });
}

/** Ledger append (durable JSONL audit — same fail-safe semantics as
 * shared/audit-log.ts). Never throws. */
export function appendLedger(entry: Record<string, unknown>, env: Record<string, string | undefined> = process.env): void {
  try {
    const file = auditLedgerFile(env);
    fs.mkdirSync(path.dirname(file), { recursive: true });
    const line = JSON.stringify({ ts: new Date().toISOString(), event: "provider-failover", ...entry }) + "\n";
    fs.appendFileSync(file, line);
  } catch {
    /* audit must never break the gate path */
  }
}

// ── Direct-execution CLI: interim manual clear ──────────────────────────────

/**
 * `npx tsx extensions/shared/provider-failover.ts --clear [primary|*]`
 *   --clear deepseek   clear the deepseek exhaustion latch
 *   --clear *          clear ALL latch state (factory reset)
 *   --status           print current latch state as JSON
 *
 * Zero top-level I/O: the guard runs only when this file is the entry point.
 */
function runCli(argv: string[]): void {
  const cmd = argv[2];
  const arg = argv[3];
  if (cmd === "--clear" && arg) {
    const state = manualClear(arg);
    console.log(`[provider-failover] cleared primary="${arg}" — remaining primaries: ${Object.keys(state.primaries).join(",") || "none"}`);
    return;
  }
  if (cmd === "--status") {
    console.log(JSON.stringify(readLatchState(), null, 2));
    return;
  }
  console.error("usage: npx tsx extensions/shared/provider-failover.ts --clear <primary|*> | --status");
  process.exitCode = 2;
}

const isDirectEntry = (() => {
  try {
    const entry = process.argv[1];
    if (!entry) return false;
    return path.resolve(entry) === fileURLToPath(import.meta.url);
  } catch {
    return false;
  }
})();

if (isDirectEntry) {
  runCli(process.argv);
}

