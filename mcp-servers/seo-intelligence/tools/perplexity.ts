import type { PerplexityResponse, PerplexityMultiResponse } from "../lib/types.js";

const BASE_URL = "https://api.perplexity.ai/search";

function getApiKey(): string {
  const key = process.env.PERPLEXITY_API_KEY;
  if (!key) throw new Error("PERPLEXITY_API_KEY not configured");
  return key;
}

export async function perplexitySearch(
  query: string,
  maxResults = 5
): Promise<PerplexityResponse> {
  const response = await fetch(BASE_URL, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${getApiKey()}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      query,
      max_results: maxResults,
    }),
    signal: AbortSignal.timeout(30_000),
  });

  if (!response.ok) {
    const text = await response.text();
    throw new Error(`Perplexity HTTP ${response.status}: ${text}`);
  }

  return response.json() as Promise<PerplexityResponse>;
}

export interface ResearchParams {
  query: string | string[];
  maxResults?: number;
  country?: string;
  searchDomainFilter?: string[];
  searchLanguageFilter?: string[];
  maxTokensPerPage?: number;
}

export async function perplexityResearch(
  params: ResearchParams
): Promise<PerplexityResponse | PerplexityMultiResponse> {
  const body: Record<string, unknown> = {
    query: params.query,
    max_results: params.maxResults ?? 5,
  };

  if (params.maxTokensPerPage !== undefined) body.max_tokens_per_page = params.maxTokensPerPage;
  if (params.country) body.country = params.country;
  if (params.searchDomainFilter?.length) body.search_domain_filter = params.searchDomainFilter;
  if (params.searchLanguageFilter?.length) body.search_language_filter = params.searchLanguageFilter;

  const response = await fetch(BASE_URL, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${getApiKey()}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(30_000),
  });

  if (!response.ok) {
    const text = await response.text();
    throw new Error(`Perplexity HTTP ${response.status}: ${text}`);
  }

  return response.json() as Promise<PerplexityResponse | PerplexityMultiResponse>;
}
