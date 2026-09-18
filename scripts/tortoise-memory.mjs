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
 *
 * ── Read-path failure contract (tortoise#3805 / #3832, agent-infra#1182) ──
 * ONE vocabulary, carried in the `status` field of every payload:
 *   "ok"                    — the store answered; an EMPTY store is `ok` + count 0
 *   "not_configured"        — TORTOISE_API_KEY is unset: a SET-UP gap, not an outage
 *   "tortoise_unavailable"  — configured, but the store could not be reached
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

/** A typed degradation: never-configured or unreachable (never a query error). */
class MemoryStateError extends Error {
  constructor(status, message) {
    super(message);
    this.name = "MemoryStateError";
    this.status = status;
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
  const url = new URL(`${BASE_URL}${path}`);
  if (params) for (const [k, v] of Object.entries(params)) url.searchParams.set(k, String(v));
  let res;
  try {
    res = await fetch(url.toString(), {
      method,
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
    throw new Error(`tortoise ${method} ${path} → HTTP ${res.status}: ${text.slice(0, 300)}`);
  }
  const ct = res.headers.get("content-type") || "";
  return ct.includes("json") ? res.json() : res.text();
}

/** The graceful failure payload — ONE vocabulary in `status` and `error`. */
function degradation(status, message) {
  return { status, error: status, message, base_url: BASE_URL };
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
      return out({ status: STATUS_OK, written: (JSON.parse(params.pointsJson) || []).length, results: [], mock: true });
    case "write-claim":
      return out({ status: STATUS_OK, id: "pt_mock_written", content: params.content, kind: params.kind, written: true, mock: true });
    case "status":
      return out({ status: STATUS_OK, available: true, base_url: BASE_URL, mock: true, point_count: MOCK_POINTS.length });
    default:
      return out({ status: STATUS_UNAVAILABLE, error: "unknown_command", name }, EXIT_USAGE);
  }
}

export async function main() {
  const [cmd, ...args] = process.argv.slice(2);
  const opt = (name, dflt = "") => {
    const i = args.indexOf(name);
    return i >= 0 ? args[i + 1] : dflt;
  };

  const mocked = process.env.TORTOISE_MOCK === "1";
  try {
    switch (cmd) {
      case "query-prior-research": {
        const domain = opt("--domain");
        if (!domain) { console.error("--domain required"); process.exit(EXIT_USAGE); }
        if (mocked) return mockCall("query-prior-research", { domain });
        const res = await api("/v1/search", { params: { q: domain, limit: 10 } });
        return out({ status: STATUS_OK, domain, count: res.count, results: res.results || [] });
      }
      case "query-strategies": {
        if (mocked) return mockCall("query-strategies");
        const res = await api("/v1/points", { params: { kind: "strategy", limit: 50 } });
        return out({ status: STATUS_OK, count: res.count, results: res.points || [] });
      }
      case "query-visions": {
        const kind = opt("--point-kind", "vision");
        if (mocked) return mockCall("query-visions", { pointKind: kind });
        const res = await api("/v1/points", { params: { kind, limit: 50 } });
        return out({ status: STATUS_OK, count: res.count, results: res.points || [] });
      }
      case "search": {
        const q = opt("--query");
        const limit = Number(opt("--limit", "10"));
        if (!q) { console.error("--query required"); process.exit(EXIT_USAGE); }
        if (mocked) return mockCall("search", { query: q });
        const res = await api("/v1/search", { params: { q, limit } });
        return out({ status: STATUS_OK, query: q, count: res.count, results: res.results || [] });
      }
      case "write-points": {
        const kind = opt("--kind");
        const pointsJson = opt("--points-json");
        let points;
        try { points = JSON.parse(pointsJson); } catch { console.error("--points-json must be valid JSON"); process.exit(EXIT_USAGE); }
        if (mocked) return mockCall("write-points", { kind, pointsJson });
        const results = [];
        for (const p of points) {
          const body = { kind, content: p.content };
          if (p.authoredBy) body.authoredBy = p.authoredBy;
          if (p.confidence != null) body.confidence = Number(p.confidence);
          results.push(await api("/v1/points", { method: "POST", body }));
        }
        return out({ status: STATUS_OK, written: results.length, results });
      }
      case "write-claim": {
        const content = opt("--content");
        const kind = opt("--kind", "statement");
        const authoredBy = opt("--authored-by", "");
        const confidenceRaw = opt("--confidence", "");
        if (!content) { console.error("--content required"); process.exit(EXIT_USAGE); }
        if (mocked) return mockCall("write-claim", { content, kind });
        const body = { kind, content };
        if (authoredBy) body.authoredBy = authoredBy;
        if (confidenceRaw) body.confidence = Number(confidenceRaw);
        const created = await api("/v1/points", { method: "POST", body });
        return out({ status: STATUS_OK, id: created.id, content: created.content, kind: created.kind, written: true });
      }
      case "status": {
        if (mocked) return mockCall("status");
        const team = await api("/v1/team");
        return out({ status: STATUS_OK, available: true, base_url: BASE_URL, point_count: team.point_count, tier: team.tier });
      }
      default:
        console.error(`Usage: node scripts/tortoise-memory.mjs <query-prior-research|query-strategies|query-visions|search|write-points|write-claim|status>
Env: TORTOISE_API_KEY (tt_...), TORTOISE_BASE_URL (default ${BASE_URL})
Status probe exits: 0 ok · 3 can't reach it · 4 not set up (data subcommands stay exit 0)
Mock: TORTOISE_MOCK=1`);
        process.exit(EXIT_USAGE);
    }
  } catch (e) {
    const status = e instanceof MemoryStateError ? e.status : STATUS_UNAVAILABLE;
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
