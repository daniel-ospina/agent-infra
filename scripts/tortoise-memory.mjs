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
 *   TORTOISE_API_KEY    hosted API key (tt_... from tortoise.premiselabs.co)
 *   TORTOISE_BASE_URL   default https://tortoise.premiselabs.co
 *
 * Graceful degradation (matches old client): no key → JSON
 * {"error":"tortoise_unavailable",...} and exit 0, so skills "skip the
 * memory step" instead of failing. Test mode: TORTOISE_MOCK=1.
 * Zero dependencies — plain fetch (Node ≥ 18).
 */
const BASE_URL = (process.env.TORTOISE_BASE_URL || "https://tortoise.premiselabs.co").replace(/\/+$/, "");
const API_KEY = process.env.TORTOISE_API_KEY || "";

function out(obj, exitCode = 0) {
  console.log(JSON.stringify(obj, null, 2));
  process.exit(exitCode);
}

async function api(path, opts = {}) {
  const { method = "GET", body, params } = opts;
  if (!API_KEY) {
    out({ error: "tortoise_unavailable", message: "TORTOISE_API_KEY not set — memory system offline (hosted tortoise). Get a key at tortoise.premiselabs.co.", status: "skip" }, 0);
  }
  const url = new URL(`${BASE_URL}${path}`);
  if (params) for (const [k, v] of Object.entries(params)) url.searchParams.set(k, String(v));
  const res = await fetch(url.toString(), {
    method,
    headers: {
      Authorization: `Bearer ${API_KEY}`,
      ...(body ? { "Content-Type": "application/json" } : {}),
    },
    ...(body ? { body: JSON.stringify(body) } : {}),
  });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`tortoise ${method} ${path} → HTTP ${res.status}: ${text.slice(0, 300)}`);
  }
  const ct = res.headers.get("content-type") || "";
  return ct.includes("json") ? res.json() : res.text();
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
      return out({ domain: params.domain || params.query, count: 1, results: [MOCK_POINTS[0]] });
    case "query-strategies":
      return out({ count: 1, results: [MOCK_POINTS[1]] });
    case "query-visions": {
      const kind = params.pointKind || "vision";
      const results = MOCK_POINTS.filter((p) => p.kind === kind);
      return out({ count: results.length, results });
    }
    case "write-points":
      return out({ written: (JSON.parse(params.pointsJson) || []).length, results: [], mock: true });
    case "write-claim":
      return out({ id: "pt_mock_written", content: params.content, kind: params.kind, written: true, mock: true });
    case "status":
      return out({ available: true, base_url: BASE_URL, mock: true, point_count: MOCK_POINTS.length });
    default:
      return out({ error: "unknown_command", name }, 2);
  }
}

async function main() {
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
        if (!domain) { console.error("--domain required"); process.exit(2); }
        if (mocked) return mockCall("query-prior-research", { domain });
        const res = await api("/v1/search", { params: { q: domain, limit: 10 } });
        return out({ domain, count: res.count, results: res.results || [] });
      }
      case "query-strategies": {
        if (mocked) return mockCall("query-strategies");
        const res = await api("/v1/points", { params: { kind: "strategy", limit: 50 } });
        return out({ count: res.count, results: res.points || [] });
      }
      case "query-visions": {
        const kind = opt("--point-kind", "vision");
        if (mocked) return mockCall("query-visions", { pointKind: kind });
        const res = await api("/v1/points", { params: { kind, limit: 50 } });
        return out({ count: res.count, results: res.points || [] });
      }
      case "search": {
        const q = opt("--query");
        const limit = Number(opt("--limit", "10"));
        if (!q) { console.error("--query required"); process.exit(2); }
        if (mocked) return mockCall("search", { query: q });
        const res = await api("/v1/search", { params: { q, limit } });
        return out({ query: q, count: res.count, results: res.results || [] });
      }
      case "write-points": {
        const kind = opt("--kind");
        const pointsJson = opt("--points-json");
        let points;
        try { points = JSON.parse(pointsJson); } catch { console.error("--points-json must be valid JSON"); process.exit(2); }
        if (mocked) return mockCall("write-points", { kind, pointsJson });
        const results = [];
        for (const p of points) {
          const body = { kind, content: p.content };
          if (p.authoredBy) body.authoredBy = p.authoredBy;
          if (p.confidence != null) body.confidence = Number(p.confidence);
          results.push(await api("/v1/points", { method: "POST", body }));
        }
        return out({ written: results.length, results });
      }
      case "write-claim": {
        const content = opt("--content");
        const kind = opt("--kind", "statement");
        const authoredBy = opt("--authored-by", "");
        const confidenceRaw = opt("--confidence", "");
        if (!content) { console.error("--content required"); process.exit(2); }
        if (mocked) return mockCall("write-claim", { content, kind });
        const body = { kind, content };
        if (authoredBy) body.authoredBy = authoredBy;
        if (confidenceRaw) body.confidence = Number(confidenceRaw);
        const created = await api("/v1/points", { method: "POST", body });
        return out({ id: created.id, content: created.content, kind: created.kind, written: true });
      }
      case "status": {
        if (mocked) return mockCall("status");
        const team = await api("/v1/team");
        return out({ available: true, base_url: BASE_URL, point_count: team.point_count, tier: team.tier });
      }
      default:
        console.error(`Usage: node scripts/tortoise-memory.mjs <query-prior-research|query-strategies|query-visions|search|write-points|write-claim|status>
Env: TORTOISE_API_KEY (tt_...), TORTOISE_BASE_URL (default ${BASE_URL})
Mock: TORTOISE_MOCK=1`);
        process.exit(2);
    }
  } catch (e) {
    out({ error: "tortoise_unavailable", message: String(e.message || e), status: "degraded" }, 0);
  }
}

main();
