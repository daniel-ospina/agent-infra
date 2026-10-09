import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import type { SerpResponse, UsageData } from "../lib/types.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const USAGE_FILE = resolve(__dirname, "../.usage.json");

function loadUsage(): UsageData {
  if (existsSync(USAGE_FILE)) {
    return JSON.parse(readFileSync(USAGE_FILE, "utf-8"));
  }
  return {
    oxylabs: { used: 0, limit: 2500 },
    serper: { used: 0, limit: 2500 },
    serpapi: { used: 0, limit: 250, resets: "monthly" },
  };
}

function saveUsage(usage: UsageData): void {
  writeFileSync(USAGE_FILE, JSON.stringify(usage, null, 2));
}

async function searchOxylabs(query: string, geoLocation?: string): Promise<SerpResponse> {
  const username = process.env.OXYLABS_USERNAME;
  const password = process.env.OXYLABS_PASSWORD;
  if (!username || !password) throw new Error("OXYLABS credentials not configured");

  const body: Record<string, unknown> = {
    source: "google_search",
    query,
    parse: true,
  };
  if (geoLocation) body.geo_location = geoLocation;

  const response = await fetch("https://realtime.oxylabs.io/v1/queries", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: "Basic " + Buffer.from(`${username}:${password}`).toString("base64"),
    },
    body: JSON.stringify(body),
  });

  if (!response.ok) {
    const text = await response.text();
    throw new Error(`Oxylabs HTTP ${response.status}: ${text}`);
  }

  const data = await response.json();
  const results = data.results?.[0]?.content?.results?.organic ?? [];

  return {
    provider: "oxylabs",
    query,
    organic_results: results.map((r: any, i: number) => ({
      title: r.title ?? "",
      link: r.url ?? "",
      snippet: r.desc ?? "",
      position: i + 1,
    })),
    related_searches: data.results?.[0]?.content?.results?.related_searches?.map(
      (rs: any) => rs.query
    ),
  };
}

async function searchSerper(query: string, geoLocation?: string): Promise<SerpResponse> {
  const apiKey = process.env.SERPER_API_KEY;
  if (!apiKey) throw new Error("SERPER_API_KEY not configured");

  const body: Record<string, unknown> = { q: query };
  if (geoLocation) body.location = geoLocation;

  const response = await fetch("https://google.serper.dev/search", {
    method: "POST",
    headers: {
      "X-API-KEY": apiKey,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  });

  if (!response.ok) {
    const text = await response.text();
    throw new Error(`Serper HTTP ${response.status}: ${text}`);
  }

  const data = await response.json();

  return {
    provider: "serper",
    query,
    organic_results: (data.organic ?? []).map((r: any, i: number) => ({
      title: r.title ?? "",
      link: r.link ?? "",
      snippet: r.snippet ?? "",
      position: r.position ?? i + 1,
    })),
    related_searches: data.relatedSearches?.map((rs: any) => rs.query),
    knowledge_graph: data.knowledgeGraph,
  };
}

async function searchSerpApi(query: string, geoLocation?: string): Promise<SerpResponse> {
  const apiKey = process.env.SERPAPI_KEY;
  if (!apiKey) throw new Error("SERPAPI_KEY not configured");

  const params = new URLSearchParams({
    engine: "google",
    q: query,
    api_key: apiKey,
  });
  if (geoLocation) params.set("location", geoLocation);

  const response = await fetch(`https://serpapi.com/search?${params}`);

  if (!response.ok) {
    const text = await response.text();
    throw new Error(`SerpAPI HTTP ${response.status}: ${text}`);
  }

  const data = await response.json();

  return {
    provider: "serpapi",
    query,
    organic_results: (data.organic_results ?? []).map((r: any) => ({
      title: r.title ?? "",
      link: r.link ?? "",
      snippet: r.snippet ?? "",
      position: r.position ?? 0,
    })),
    related_searches: data.related_searches?.map((rs: any) => rs.query),
    knowledge_graph: data.knowledge_graph,
  };
}

export async function searchSerp(query: string, geoLocation?: string): Promise<SerpResponse> {
  const usage = loadUsage();
  const errors: string[] = [];

  if (usage.oxylabs.used < usage.oxylabs.limit) {
    try {
      const result = await searchOxylabs(query, geoLocation);
      usage.oxylabs.used++;
      saveUsage(usage);
      return result;
    } catch (e) {
      errors.push(`Oxylabs: ${e instanceof Error ? e.message : String(e)}`);
    }
  }

  if (usage.serper.used < usage.serper.limit) {
    try {
      const result = await searchSerper(query, geoLocation);
      usage.serper.used++;
      saveUsage(usage);
      return result;
    } catch (e) {
      errors.push(`Serper: ${e instanceof Error ? e.message : String(e)}`);
    }
  }

  if (usage.serpapi.used < usage.serpapi.limit) {
    try {
      const result = await searchSerpApi(query, geoLocation);
      usage.serpapi.used++;
      saveUsage(usage);
      return result;
    } catch (e) {
      errors.push(`SerpAPI: ${e instanceof Error ? e.message : String(e)}`);
    }
  }

  throw new Error(
    `All SERP providers exhausted or failed.\nUsage: Oxylabs ${usage.oxylabs.used}/${usage.oxylabs.limit}, Serper ${usage.serper.used}/${usage.serper.limit}, SerpAPI ${usage.serpapi.used}/${usage.serpapi.limit}\nErrors: ${errors.join("; ")}`
  );
}

export function getUsage(): UsageData {
  return loadUsage();
}
