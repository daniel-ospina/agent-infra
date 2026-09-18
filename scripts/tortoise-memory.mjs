#!/usr/bin/env node
/**
 * tortoise-memory.mjs — hosted Tortoise API client for skill memory ops (#102).
 *
 * SUPERSEDES the dead eldato-era `operations/memory/tortoise_client.py`.
 * Talks to the hosted Tortoise product (the SOR we dogfood) — endpoints
 * defined in tortoise/hosted_api.py: POST /v1/points, GET /v1/points?kind=,
 * GET /v1/search?q=, POST /v1/sessions, GET /v1/team.
 *
 * Subcommands mirror the old tortoise_client.py CLI so skill text stays stable:
 *   node scripts/tortoise-memory.mjs query-prior-research --domain "<domain>"
 *   node scripts/tortoise-memory.mjs query-strategies
 *   node scripts/tortoise-memory.mjs query-visions [--point-kind <kind>]
 *   node scripts/tortoise-memory.mjs search --query "<q>" [--limit N]
 *   node scripts/tortoise-memory.mjs write-points --kind <k> --points-json '<json>'
 *   node scripts/tortoise-memory.mjs write-claim --content "<c>" --kind <k> \
 *       [--authored-by <a>] [--confidence <0-1>]
 *   node scripts/tortoise-memory.mjs status
 *
 * Env:
 *   TORTOISE_API_KEY    hosted API key (tt_...)
 *   TORTOISE_BASE_URL   override of the API host; default https://api.premiselabs.co
 *   TORTOISE_TIMEOUT_MS per-request timeout in ms (default 10000; clamped to 1..600000)
 *
 * ── Read-path failure contract (tortoise#3805 / #3832, agent-infra#1182) ──
 * ONE vocabulary, carried in the `status` field of every payload:
 *   "ok"                    — the store answered; an EMPTY store is `ok` + count 0
 *   "not_configured"        — the key is UNSET *or REJECTED* (401/403): a SET-UP
 *                             gap, not an outage
 *   "tortoise_unavailable"  — configured, but the store could not be reached
 * `ok` requires the REAL API payload for THAT ENDPOINT, asserted at EVERY call
 * site before a payload is built:
 *   · probe  GET /v1/team   → a numeric `point_count`  (`assertTeamPayload`)
 *   · read   GET /v1/search → an integer `count` + a `results` array of that length
 *   · read   GET /v1/points → an integer `count` + a `points`  array of that length
 *     (`assertReadPayload(res, path, key)` — the KEY is per-endpoint. An either-or
 *     `results`/`points` check let `/v1/points` read a foreign envelope; a `count`
 *     that disagrees with the list length is not an envelope either.)
 *   · write  POST /v1/points → a created Point with a NON-EMPTY STRING `id`
 *     (`assertWritePayload` — without it a non-API body was reported as
 *     `{status:"ok",written:true}`, i.e. an agent recorded a write that never
 *     happened)
 * A reachable non-API — a non-JSON *content-type* (a captive portal / proxy / the
 * dashboard host), or any 2xx JSON body that is not the expected shape — degrades
 * to `tortoise_unavailable`, never to a green verdict with `undefined` fields.
 * Every request is bounded so an accept-but-silent host still produces a verdict
 * instead of hanging.
 * An ANSWERED 4xx is never `tortoise_unavailable` — the store WAS reached. 401/403
 * (the credential was refused, or lacks the scope the call needs) folds into
 * `not_configured`; any other 4xx is the API rejecting THIS request and carries
 * NO `status` field (the frozen vocabulary has no true word for it, and a fourth
 * is out of budget). The PROBE exits EXIT_USAGE (2) for it — 2 is the reserved
 * usage code and the probe already owns a distinct exit per store state. DATA
 * subcommands keep the skip-cleanly exit 0 with `{error: "request_rejected", …}`
 * (agent-infra#1182 scope), so a rejected request never hard-fails a skill but is
 * still visible. A 5xx stays `tortoise_unavailable`: the service answered, failing.
 * Arguments are validated from ONE table (`ARG_TYPES` / `COMMANDS`) BEFORE any
 * network call: an unknown flag, a missing value, a wrong type, a
 * whitespace-only string, a `--limit` outside 1..100, or a `--points-json`
 * element that is not a non-null `{content: <non-empty string>}` exits
 * EXIT_USAGE with no `status` field — a usage error must never wear a
 * store-state word. An EMPTY `--points-json` array is a usage error too: it
 * writes nothing, so it must never report `{status:"ok",written:0}`. A nested
 * element is validated through the SAME `ARG_TYPES` entry as the flag of the
 * same name (and normalized there), so the two forms cannot drift — a JSON
 * native such as `confidence: true` is rejected exactly as `--confidence true`
 * is, and the body builder never re-coerces a value with a parallel `Number()`.
 * The `status` PROBE exits 0 (ok) / 3 (can't reach) / 4 (not set up), keeping 2
 * for usage errors; it is the surface a human or an agent harness checks.
 * DATA subcommands (query/search/write) keep the skip-cleanly contract
 * (agent-infra#1182 scope): they report the same vocabulary but stay exit 0, so
 * an absent optional dependency never becomes a hard failure for a skill.
 * This client never raises to the caller. Test mode: TORTOISE_MOCK=1.
 * Zero npm dependencies — plain fetch (Node ≥ 18), plus the sibling
 * `./is-main.mjs` entry-point guard (no symlink-sensitive raw argv compare, #708).
 */
import { isMain } from "./is-main.mjs";

// The API host — NOT the dashboard (tortoise.premiselabs.co). #3805 / #1182.
const DEFAULT_BASE_URL = "https://api.premiselabs.co";

export function resolveBaseUrl(env = process.env) {
  return (env.TORTOISE_BASE_URL || DEFAULT_BASE_URL).replace(/\/+$/, "");
}

// Every request is BOUNDED. A host that accepts TCP but never answers would
// otherwise hang the client for undici's ~5-minute default and produce no
// verdict at all; the abort lands in `api()`'s existing catch and becomes the
// SAME `tortoise_unavailable` payload as an immediate ECONNREFUSED.
// `TORTOISE_TIMEOUT_MS` is a real knob (slow links), but it cannot DISABLE the
// bound: a non-finite, non-integer, or out-of-clamp value falls back to the
// default, so no ambient env turns the timeout off. It must be an INTEGER:
// `AbortSignal.timeout()` throws `delay … must be an integer` on a fractional
// value, and that throw would be mapped to a false `tortoise_unavailable`
// against a perfectly healthy store.
const DEFAULT_REQUEST_TIMEOUT_MS = 10_000;
const MIN_REQUEST_TIMEOUT_MS = 1;
const MAX_REQUEST_TIMEOUT_MS = 600_000;

export function resolveTimeoutMs(env = process.env) {
  const raw = Number(env.TORTOISE_TIMEOUT_MS);
  // `Number.isInteger` (not `Number.isFinite`): a fractional value reaches
  // `AbortSignal.timeout()`, which throws, and the throw lands in `api()`'s
  // catch as a HEALTHY-store false `tortoise_unavailable`.
  return Number.isInteger(raw) && raw >= MIN_REQUEST_TIMEOUT_MS && raw <= MAX_REQUEST_TIMEOUT_MS
    ? raw
    : DEFAULT_REQUEST_TIMEOUT_MS;
}

export const STATUS_OK = "ok";
export const STATUS_NOT_CONFIGURED = "not_configured";
export const STATUS_UNAVAILABLE = "tortoise_unavailable";

// Exit codes (tortoise#3805 / #3832). Only the `status` PROBE emits 3 and 4;
// data subcommands keep the graceful exit-0 contract (agent-infra#1182). 1 is
// the loud query-path failure of the shipped `tortoise-client` CLI; 2 is usage.
export const EXIT_OK = 0;
export const EXIT_USAGE = 2;
export const EXIT_UNAVAILABLE = 3;
export const EXIT_NOT_CONFIGURED = 4;

const BASE_URL = resolveBaseUrl();
const API_KEY = process.env.TORTOISE_API_KEY || "";
const REQUEST_TIMEOUT_MS = resolveTimeoutMs();

/** A typed degradation: never-configured or unreachable (never a query error). */
class MemoryStateError extends Error {
  constructor(status, message) {
    super(message);
    this.name = "MemoryStateError";
    this.status = status;
  }
}

/**
 * The API ANSWERED and REJECTED the request (a 4xx other than 401/403, which
 * folds into `not_configured`). Deliberately NOT a `MemoryStateError`: neither
 * "could not be reached" nor "not_configured" is true, and the frozen vocabulary
 * has no word for it — so it is an invocation-level failure (EXIT_USAGE, no
 * `status` field) rather than a fourth state word. See `main()`'s catch.
 */
class MemoryHttpError extends Error {
  constructor(httpStatus, method, path, text) {
    super(
      `the Tortoise API at ${BASE_URL} answered ${method} ${path} with HTTP ${httpStatus} ` +
        `(the store WAS reached; it rejected this request): ${text.slice(0, 300)}`,
    );
    this.name = "MemoryHttpError";
    this.httpStatus = httpStatus;
  }
}

/**
 * A USAGE error — a bad invocation, never a store state. It carries NO `status`
 * field and exits EXIT_USAGE, so "you typed the argument wrong" can never be
 * read as "the store is down" (`tortoise_unavailable`) or as a set-up gap.
 */
class UsageError extends Error {
  constructor(message) {
    super(message);
    this.name = "UsageError";
  }
}

function out(obj, exitCode = EXIT_OK) {
  console.log(JSON.stringify(obj, null, 2));
  process.exit(exitCode);
}

/** The probe's status word → process exit code. */
export function probeExitCode(status) {
  if (status === STATUS_OK) return EXIT_OK;
  if (status === STATUS_NOT_CONFIGURED) return EXIT_NOT_CONFIGURED;
  return EXIT_UNAVAILABLE;
}

async function api(path, opts = {}) {
  const { method = "GET", body, params } = opts;
  if (!API_KEY) {
    throw new MemoryStateError(
      STATUS_NOT_CONFIGURED,
      "TORTOISE_API_KEY not set — memory was never configured on this machine. " +
        "Set TORTOISE_API_KEY (hosted key, tt_...) to enable it; the API host defaults to " +
        `${DEFAULT_BASE_URL} and can be overridden with TORTOISE_BASE_URL.`,
    );
  }
  // URL CONSTRUCTION is inside its own guard, not left to the caller's fallback.
  // A malformed `TORTOISE_BASE_URL` (`::::`, a scheme-less host) makes `new URL`
  // throw a raw `TypeError`; thrown from OUTSIDE every `MemoryStateError` guard
  // it would fall through `main()`'s `e instanceof MemoryStateError` test to the
  // DEFAULT status — correct only while that default happens to be
  // `STATUS_UNAVAILABLE`, and a green verdict the moment it is not. Mapping it
  // here makes a misconfigured address an explicit, self-describing state error
  // rather than a bare `"Invalid URL"` riding an unasserted default.
  let url;
  try {
    url = new URL(`${BASE_URL}${path}`);
    if (params) for (const [k, v] of Object.entries(params)) url.searchParams.set(k, String(v));
  } catch (e) {
    throw new MemoryStateError(
      STATUS_UNAVAILABLE,
      `TORTOISE_BASE_URL is not a usable API address — "${BASE_URL}" cannot be parsed ` +
        `into a request URL (the store was never reached): ${String(e.message || e)}`,
    );
  }
  let res;
  try {
    res = await fetch(url.toString(), {
      method,
      signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
      headers: {
        Authorization: `Bearer ${API_KEY}`,
        ...(body ? { "Content-Type": "application/json" } : {}),
      },
      ...(body ? { body: JSON.stringify(body) } : {}),
    });
  } catch (e) {
    throw new MemoryStateError(
      STATUS_UNAVAILABLE,
      `cannot reach the Tortoise API at ${BASE_URL} — ${String(e.message || e)}`,
    );
  }
  if (!res.ok) {
    const text = await res.text();
    // The store WAS reached and ANSWERED. 401/403 is a REJECTED CREDENTIAL — a
    // SET-UP gap (`not_configured`), not an outage. Any other 4xx is the API
    // refusing THIS request and must never be reported as `tortoise_unavailable`
    // ("could not be reached"), which sends an operator to check the address
    // when the fault is the key or the request. A 5xx is the service answering
    // that it cannot serve — the one case the outage word is still true of.
    if (res.status === 401 || res.status === 403) {
      throw new MemoryStateError(
        STATUS_NOT_CONFIGURED,
        `the Tortoise API at ${BASE_URL} REFUSED the request (HTTP ${res.status}) — the key was ` +
          `rejected, or it lacks the scope/permission this call needs (403 also covers a suspended ` +
          `org, a graph-bound key, and a missing team membership). Either way it is a SET-UP gap ` +
          `(key or permissions), not an outage: check TORTOISE_API_KEY. Body: ${text.slice(0, 200)}`,
      );
    }
    if (res.status >= 400 && res.status < 500) {
      throw new MemoryHttpError(res.status, method, path, text);
    }
    throw new MemoryStateError(
      STATUS_UNAVAILABLE,
      `the Tortoise API at ${BASE_URL} answered ${method} ${path} with HTTP ${res.status}: ` +
        text.slice(0, 300),
    );
  }
  // The guard keys on CONTENT-TYPE, not on whether the body happens to parse:
  // a JSON-parsable body served under a non-JSON content-type is still NOT the
  // hosted API (a captive portal / proxy / the dashboard host can return exactly
  // that), and reading it as an object yields `undefined` fields that a caller
  // cannot tell from a real empty answer — the false PASS this guard exists to
  // stop. (A JSON content-type with a JSON body is a separate check, per-shape,
  // at the call sites below.)
  const ct = res.headers.get("content-type") || "";
  if (!ct.includes("json")) {
    const text = await res.text();
    throw new MemoryStateError(
      STATUS_UNAVAILABLE,
      `the Tortoise API at ${BASE_URL} answered ${res.status} with a non-JSON body ` +
        `(content-type: ${ct || "none"}) — that is not the hosted API. ` +
        `First bytes: ${text.slice(0, 120)}`,
    );
  }
  return res.json();
}

/**
 * A DATA READ may report `ok` ONLY for the list envelope of the endpoint it
 * called. The content-type guard in `api()` already rejects a non-JSON body, but
 * a stub/proxy answering `200 application/json` with a JSON body that is NOT an
 * envelope (`{"hello": "not the API"}`) yielded `{status: "ok", count:
 * undefined, results: []}` — a healthy-looking EMPTY store, which a skill reads
 * as "first research on this topic".
 *
 * `key` is the endpoint's OWN list field and is REQUIRED: `/v1/search` answers
 * `{count, results}` and `/v1/points` answers `{count, points}` (hosted_api.py
 * `search` / `list_points`, both `count = len(list)`). An either-or check
 * accepted a `results` envelope at `/v1/points` and vice versa; passing the key
 * is what rejects it. `count` must MATCH the list length — a truncated or padded
 * count is not the API's own answer.
 */
export function assertReadPayload(res, path, key) {
  const list = res?.[key];
  const ok = Number.isInteger(res?.count) && Array.isArray(list) && res.count === list.length;
  if (!ok) {
    throw new MemoryStateError(
      STATUS_UNAVAILABLE,
      `the Tortoise API at ${BASE_URL} answered ${path} with a body that is not that ` +
        `endpoint's list envelope (expected an integer count and a \`${key}\` array of exactly ` +
        `that length; got count: ${JSON.stringify(res?.count)}, ${key}: ` +
        `${Array.isArray(list) ? `array of ${list.length}` : JSON.stringify(list)}) — not a real ` +
        `API payload: ${JSON.stringify(res).slice(0, 160)}`,
    );
  }
  return res;
}

/**
 * A WRITE may report `ok` ONLY for a created Point. `POST /v1/points` answers a
 * `PointResponse` whose `id` is a required non-empty string (hosted_api.py
 * `PointResponse`). Without this check a reachable non-API answering
 * `200 application/json` + `{"hello": "not the API"}` was reported as
 * `{status: "ok", written: true}` — an agent records a memory write that never
 * happened.
 */
export function assertWritePayload(res, path) {
  const id = res?.id;
  if (typeof id !== "string" || id.length === 0) {
    throw new MemoryStateError(
      STATUS_UNAVAILABLE,
      `the Tortoise API at ${BASE_URL} answered ${path} with a body that is not a created ` +
        `Point (expected a non-empty string \`id\`; got ${JSON.stringify(id)}) — the create did ` +
        `NOT succeed, so it must never be reported as \`ok\`: ${JSON.stringify(res).slice(0, 160)}`,
    );
  }
  return res;
}

/**
 * The PROBE may report `ok` ONLY for a real team payload: `/v1/team` answers an
 * `OrgInfoResponse` (hosted_api.py) whose `point_count`, `org_id` and `tier` are
 * REQUIRED — a `200 {"point_count": 0}` that carries neither of the other two is
 * a non-API body, and reporting `ok` for it would hand back `tier: undefined`.
 * The content-type guard in `api()` already rejects `200 text/html`; this is the
 * shape half.
 */
export function assertTeamPayload(res, path) {
  const ok =
    typeof res?.point_count === "number" &&
    typeof res?.org_id === "string" &&
    res.org_id.length > 0 &&
    typeof res?.tier === "string" &&
    res.tier.length > 0;
  if (!ok) {
    throw new MemoryStateError(
      STATUS_UNAVAILABLE,
      `the Tortoise API at ${BASE_URL} answered ${path} without a real team payload ` +
        `(expected a numeric point_count plus non-empty string org_id and tier; got point_count: ` +
        `${JSON.stringify(res?.point_count)}, org_id: ${JSON.stringify(res?.org_id)}, tier: ` +
        `${JSON.stringify(res?.tier)}) — not a real team payload: ${JSON.stringify(res).slice(0, 160)}`,
    );
  }
  return res;
}

// ── ONE table-driven argument validator, applied before ANY network call ────
// A usage error is a usage error: EXIT_USAGE, and NO `status` field — so "you
// typed the argument wrong" can never be read as "the store is down"
// (`tortoise_unavailable`) or as a set-up gap (`not_configured`). Three concrete
// defects this replaces, each of which reached the API as a real request:
//   · `--points-json '[null]'` → `Cannot read properties of null (reading
//     'content')` → the catch-all mapped it to `tortoise_unavailable`;
//   · `write-points` with no `--kind` → the literal string "undefined" was sent;
//   · a value-less flag (`query-visions --point-kind`) → "undefined" was sent.
const ARG_TYPES = {
  /** A non-empty string. The check is on `raw.trim()`: `write-claim --content
   * '   '` used to write a blank Point and report `ok`, because `length === 0`
   * did not fire on a whitespace-only value. Class-wide — every string the table
   * validates, top-level OR nested, goes through THIS entry. */
  string(flag, raw) {
    if (typeof raw !== "string" || raw.trim() === "") {
      throw new UsageError(`${flag} requires a non-empty value`);
    }
    return raw;
  },
  /** A finite number (`--confidence`). A BLANK raw is rejected, not coerced:
   * `Number("")` is 0, so an empty value used to become a real number. The
   * NATIVE type is checked too: a JSON native such as `true` (`Number(true)`
   * is 1), `[]` (`0`) or `[0.5]` (`0.5`) used to coerce SILENTLY, while the
   * string flag form rejected the same shape — a nested element and its flag
   * must accept exactly the same set. A flag always arrives as a string; only
   * a nested JSON number may arrive as a number. */
  number(flag, raw) {
    if (typeof raw !== "number" && typeof raw !== "string") {
      throw new UsageError(`${flag} must be a number (got: ${JSON.stringify(raw)})`);
    }
    const blank = typeof raw === "string" && raw.trim() === "";
    const n = Number(raw);
    if (blank || !Number.isFinite(n)) {
      throw new UsageError(`${flag} must be a number (got: ${JSON.stringify(raw)})`);
    }
    return n;
  },
  /** A whole number ≥ 1 (`--limit 0` used to be accepted and sent), and no
   * greater than `max` when the table row sets one — `/v1/search` requires
   * 1..100, so `--limit 5000` passed local validation and then 422'd, which a
   * data subcommand reported as a clean skip (`{error:"request_rejected"}`,
   * exit 0) — a bad invocation indistinguishable from "nothing to do". */
  positiveInteger(flag, raw, max) {
    if (typeof raw !== "number" && typeof raw !== "string") {
      throw new UsageError(`${flag} must be a positive integer (got: ${JSON.stringify(raw)})`);
    }
    const n = Number(raw);
    const bound = max === undefined ? "" : ` no greater than ${max}`;
    if (!Number.isInteger(n) || n < 1 || (max !== undefined && n > max)) {
      throw new UsageError(
        `${flag} must be a positive integer${bound} (got: ${JSON.stringify(raw)})`,
      );
    }
    return n;
  },
  /** A non-empty JSON array of non-null objects with a non-empty string
   * `content` and, when present, a non-empty string `authoredBy` / finite
   * `confidence`. Every element is validated through the SAME `ARG_TYPES` entry
   * as the flag of the same name, and the NORMALIZED values are returned — so
   * the body builder cannot re-coerce them with a parallel `Number(...)`.
   * An EMPTY array is a USAGE error: the old loop never ran and the client still
   * reported `{status:"ok",written:0}` with no key and no reachable store. */
  pointsJson(flag, raw) {
    let parsed;
    try {
      parsed = JSON.parse(raw);
    } catch {
      throw new UsageError(`${flag} must be valid JSON`);
    }
    if (!Array.isArray(parsed)) throw new UsageError(`${flag} must be a JSON array`);
    if (parsed.length === 0) {
      throw new UsageError(`${flag} must be a non-empty JSON array`);
    }
    return parsed.map((p, i) => {
      if (p === null || typeof p !== "object" || Array.isArray(p) || typeof p.content !== "string") {
        throw new UsageError(
          `${flag}[${i}] must be a non-null object with a non-empty string content`,
        );
      }
      // The SAME element-level entries as the flags of the same name: a nested
      // value must not reach the network in a shape the flag form rejects
      // (`confidence: "abc"` used to be sent as `null`, `confidence: true` as
      // `1`). The NORMALIZED result is what the caller sends.
      const point = { content: ARG_TYPES.string(`${flag}[${i}].content`, p.content) };
      if (p.authoredBy !== undefined) {
        point.authoredBy =
          p.authoredBy === null ? null : ARG_TYPES.string(`${flag}[${i}].authoredBy`, p.authoredBy);
      }
      if (p.confidence !== undefined) {
        point.confidence =
          p.confidence === null ? null : ARG_TYPES.number(`${flag}[${i}].confidence`, p.confidence);
      }
      return point;
    });
  },
};

/**
 * THE validator table: command → its accepted flags → {type, required?, default?}.
 * `type` names a row of `ARG_TYPES`, which owns the error message. Every flag the
 * CLI accepts appears here exactly once, and `parseArgs` refuses any token that
 * is not a key of the command's own row — so a flag cannot be silently ignored
 * and a required one cannot be silently absent.
 */
const COMMANDS = {
  "query-prior-research": { "--domain": { type: "string", required: true } },
  "query-strategies": {},
  "query-visions": { "--point-kind": { type: "string", default: "vision" } },
  search: {
    "--query": { type: "string", required: true },
    // `/v1/search` requires 1..100; the cap is part of the flag's own type rule.
    "--limit": { type: "positiveInteger", default: "10", max: 100 },
  },
  "write-points": {
    "--kind": { type: "string", required: true },
    "--points-json": { type: "pointsJson", required: true },
  },
  "write-claim": {
    "--content": { type: "string", required: true },
    "--kind": { type: "string", default: "statement" },
    "--authored-by": { type: "string" },
    "--confidence": { type: "number" },
  },
  status: {},
};

/**
 * Every flag ANY command accepts. `parseArgs` consults this — not the current
 * command's own row — to tell "the next token is a flag, so this one has no
 * value" from "the next token is a value". Using the command's own row instead
 * would let `query-visions --point-kind --limit` send the string "--limit"; using
 * a bare `startsWith("--")` would refuse a legitimate value that merely begins
 * with two dashes (a claim whose text is `--force skips the check`).
 */
const KNOWN_FLAGS = new Set(Object.values(COMMANDS).flatMap((spec) => Object.keys(spec)));

/**
 * Validate argv against `COMMANDS` and return a flag → coerced-value map.
 * Throws `UsageError` for an unknown flag, a flag with no value, a required flag
 * that is absent, or a value the flag's type rejects. Called BEFORE any network
 * call (and identically in mock mode), so no usage error can be observed as a
 * store state.
 */
export function parseArgs(cmd, args) {
  const spec = Object.prototype.hasOwnProperty.call(COMMANDS, cmd) ? COMMANDS[cmd] : null;
  if (!spec) throw new UsageError(`unknown command "${cmd}"`);
  const raw = {};
  for (let i = 0; i < args.length; i += 1) {
    const flag = args[i];
    if (!Object.prototype.hasOwnProperty.call(spec, flag)) {
      throw new UsageError(`unknown argument "${flag}" for \`${cmd}\``);
    }
    const value = args[i + 1];
    // A token that is a KNOWN flag is not a value: `query-visions --point-kind`
    // (nothing after it) and `--limit --kind` both used to send "undefined".
    // Any other token IS a value — including one that starts with `--`.
    if (value === undefined || KNOWN_FLAGS.has(value)) {
      throw new UsageError(`${flag} requires a value`);
    }
    raw[flag] = value;
    i += 1;
  }
  const values = {};
  for (const [flag, row] of Object.entries(spec)) {
    if (Object.prototype.hasOwnProperty.call(raw, flag)) continue;
    if (row.required) throw new UsageError(`${flag} required`);
    if (row.default !== undefined) values[flag] = ARG_TYPES[row.type](flag, row.default, row.max);
  }
  for (const [flag, value] of Object.entries(raw)) {
    values[flag] = ARG_TYPES[spec[flag].type](flag, value, spec[flag].max);
  }
  return values;
}

/** The graceful failure payload — ONE vocabulary in `status` and `error`. */
function degradation(status, message) {
  return { status, error: status, message, base_url: BASE_URL };
}

/**
 * The status word for a caught error. A TYPED state error carries its own; any
 * UNEXPECTED throw (not a `MemoryStateError`) is fail-closed to
 * `STATUS_UNAVAILABLE` — never `ok`. Hoisted out of `main()`'s catch so the
 * fail-closed default is EXECUTED by a test (the malformed-base-URL path is now
 * typed at `api()`, but this is still the backstop for any unforeseen throw).
 */
export function stateStatus(e) {
  return e instanceof MemoryStateError ? e.status : STATUS_UNAVAILABLE;
}

// ── Mock mode (TORTOISE_MOCK=1) — deterministic, no network ──
const MOCK_POINTS = [
  { id: "pt_mock_1", content: "Prior research claim about the domain (mock)", kind: "statement", confidence: 0.8, authoredBy: "research-skill", createdAt: "2026-08-01T00:00:00Z" },
  { id: "pt_mock_2", content: "Existing strategy decision (mock)", kind: "strategy", confidence: 0.9, authoredBy: "define-strategy-skill", createdAt: "2026-08-02T00:00:00Z" },
  { id: "pt_mock_3", content: "Vision H1 claim (mock)", kind: "vision", confidence: 0.7, authoredBy: "define-vision-skill", createdAt: "2026-08-03T00:00:00Z" },
];

function mockCall(name, params = {}) {
  switch (name) {
    case "query-prior-research":
    case "search":
      return out({ status: STATUS_OK, domain: params.domain || params.query, count: 1, results: [MOCK_POINTS[0]] });
    case "query-strategies":
      return out({ status: STATUS_OK, count: 1, results: [MOCK_POINTS[1]] });
    case "query-visions": {
      const kind = params.pointKind || "vision";
      const results = MOCK_POINTS.filter((p) => p.kind === kind);
      return out({ status: STATUS_OK, count: results.length, results });
    }
    case "write-points":
      return out({
        status: STATUS_OK,
        written: params.points.length,
        results: params.points.map((p, i) => ({
          id: `pt_mock_written_${i + 1}`,
          content: p.content,
          kind: params.kind,
        })),
        mock: true,
      });
    case "write-claim":
      return out({ status: STATUS_OK, id: "pt_mock_written", content: params.content, kind: params.kind, written: true, mock: true });
    case "status":
      return out({ status: STATUS_OK, available: true, base_url: BASE_URL, mock: true, point_count: MOCK_POINTS.length });
    default:
      // USAGE error: no `status` field — a store-state word here (the earlier
      // `tortoise_unavailable`) collapsed "bad invocation" into "store down".
      return out({ error: "unknown_command", name }, EXIT_USAGE);
  }
}

export async function main() {
  const [cmd, ...args] = process.argv.slice(2);
  const mocked = process.env.TORTOISE_MOCK === "1";
  try {
    // An unknown command is the SAME usage surface in both modes, so it can
    // never reach a payload that blends a USAGE error with a STORE-STATE word.
    if (!Object.prototype.hasOwnProperty.call(COMMANDS, cmd)) {
      if (mocked) return mockCall(cmd);
      console.error(`Usage: node scripts/tortoise-memory.mjs <query-prior-research|query-strategies|query-visions|search|write-points|write-claim|status>
Env: TORTOISE_API_KEY (tt_...), TORTOISE_BASE_URL (default ${BASE_URL})
Status probe exits: 0 ok · 3 can't reach it · 4 not set up (data subcommands stay exit 0)
Mock: TORTOISE_MOCK=1`);
      process.exit(EXIT_USAGE);
    }
    // EVERY flag is validated here — before any network call, in both modes.
    const v = parseArgs(cmd, args);
    switch (cmd) {
      case "query-prior-research": {
        const domain = v["--domain"];
        if (mocked) return mockCall("query-prior-research", { domain });
        const res = assertReadPayload(
          await api("/v1/search", { params: { q: domain, limit: 10 } }),
          "/v1/search",
          "results",
        );
        return out({ status: STATUS_OK, domain, count: res.count, results: res.results });
      }
      case "query-strategies": {
        if (mocked) return mockCall("query-strategies");
        const res = assertReadPayload(
          await api("/v1/points", { params: { kind: "strategy", limit: 50 } }),
          "/v1/points",
          "points",
        );
        return out({ status: STATUS_OK, count: res.count, results: res.points });
      }
      case "query-visions": {
        const kind = v["--point-kind"];
        if (mocked) return mockCall("query-visions", { pointKind: kind });
        const res = assertReadPayload(
          await api("/v1/points", { params: { kind, limit: 50 } }),
          "/v1/points",
          "points",
        );
        return out({ status: STATUS_OK, count: res.count, results: res.points });
      }
      case "search": {
        const q = v["--query"];
        const limit = v["--limit"];
        if (mocked) return mockCall("search", { query: q });
        const res = assertReadPayload(
          await api("/v1/search", { params: { q, limit } }),
          "/v1/search",
          "results",
        );
        return out({ status: STATUS_OK, query: q, count: res.count, results: res.results });
      }
      case "write-points": {
        const kind = v["--kind"];
        const points = v["--points-json"];
        if (mocked) return mockCall("write-points", { kind, points });
        const results = [];
        for (const p of points) {
          // `p.authoredBy` / `p.confidence` are already NORMALIZED by the
          // table (the same entry the flags use), so there is no parallel
          // `Number(...)` re-coercion at the wire.
          const body = { kind, content: p.content };
          if (p.authoredBy) body.authoredBy = p.authoredBy;
          if (p.confidence != null) body.confidence = p.confidence;
          results.push(
            assertWritePayload(await api("/v1/points", { method: "POST", body }), "/v1/points"),
          );
        }
        return out({ status: STATUS_OK, written: results.length, results });
      }
      case "write-claim": {
        const content = v["--content"];
        const kind = v["--kind"];
        const authoredBy = v["--authored-by"];
        const confidence = v["--confidence"];
        if (mocked) return mockCall("write-claim", { content, kind });
        const body = { kind, content };
        if (authoredBy) body.authoredBy = authoredBy;
        if (confidence !== undefined) body.confidence = confidence;
        const created = assertWritePayload(
          await api("/v1/points", { method: "POST", body }),
          "/v1/points",
        );
        // `content`/`kind` are echoed from the REQUEST (which the id proves was
        // accepted), so a partial non-API body cannot surface `undefined` here.
        return out({ status: STATUS_OK, id: created.id, content, kind, written: true });
      }
      case "status": {
        if (mocked) return mockCall("status");
        const team = assertTeamPayload(await api("/v1/team"), "/v1/team");
        return out({ status: STATUS_OK, available: true, base_url: BASE_URL, point_count: team.point_count, tier: team.tier });
      }
      default:
        // Unreachable (`cmd` is a key of COMMANDS), kept as the fail-closed usage
        // surface so a future edit cannot silently fall through to a green run.
        console.error("Usage: node scripts/tortoise-memory.mjs <query-prior-research|query-strategies|query-visions|search|write-points|write-claim|status>");
        process.exit(EXIT_USAGE);
    }
  } catch (e) {
    if (e instanceof UsageError) {
      // A bad invocation: no `status` field at all (see ARG_TYPES).
      console.error(e.message);
      process.exit(EXIT_USAGE);
    }
    if (e instanceof MemoryHttpError) {
      // The store WAS reached and ANSWERED; a 4xx (other than the 401/403 folded
      // into `not_configured` in `api()`) is the API rejecting THIS request. No
      // frozen status word is true of it, so no `status` field is emitted rather
      // than inventing a fourth word or reusing `tortoise_unavailable`, whose own
      // definition is "could not be reached".
      if (cmd === "status") {
        // The PROBE owns a distinct exit per store state; a rejected request is
        // none of them, so it exits EXIT_USAGE (2) on stderr with no payload.
        console.error(e.message);
        process.exit(EXIT_USAGE);
      }
      // DATA subcommands keep the skip-cleanly exit 0 (agent-infra#1182), but
      // the payload carries NO `status` word — a skill skips, and an operator
      // still sees `error: "request_rejected"` with the HTTP status.
      return out(
        {
          error: "request_rejected",
          http_status: e.httpStatus,
          message: e.message,
          base_url: BASE_URL,
        },
        EXIT_OK,
      );
    }
    const status = stateStatus(e);
    // The PROBE carries the distinct exit code; data subcommands keep skipping
    // cleanly (agent-infra#1182) while reporting the SAME vocabulary.
    const exitCode = cmd === "status" ? probeExitCode(status) : EXIT_OK;
    out(degradation(status, String(e.message || e)), exitCode);
  }
}

// Run only when executed as a CLI (importable for the executable contract tests,
// scripts/tortoise-memory.test.mjs — those tests call the exported resolvers).
//
// scripts/is-main.mjs, not a raw `pathToFileURL(argv[1]).href === import.meta.url`:
// Node resolves the module to its real path while argv[1] keeps the caller's
// spelling, so the raw idiom is FALSE whenever any path component is a symlink —
// the module then loads, skips main(), and exits 0 with NO output, a silent green
// no-op (agent-infra#708; the failure shape tortoise#3805 is about). It is what
// made the reformat leg of tortoise-memory.test.mjs fail under macOS's symlinked
// temp dir.
if (isMain(import.meta.url, process.argv[1])) {
  main();
}
