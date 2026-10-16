export interface SerpResult {
  title: string;
  link: string;
  snippet: string;
  position: number;
}

export interface SerpResponse {
  provider: string;
  query: string;
  organic_results: SerpResult[];
  related_searches?: string[];
  knowledge_graph?: Record<string, unknown>;
}

export interface UsageData {
  oxylabs: { used: number; limit: number };
  serper: { used: number; limit: number };
  serpapi: { used: number; limit: number; resets: string };
}

export interface PerplexityResult {
  title: string;
  url: string;
  snippet: string;
  date?: string;
  last_updated?: string;
}

export interface PerplexityResponse {
  id: string;
  results: PerplexityResult[];
}

export interface PerplexityMultiResponse {
  id: string;
  results: PerplexityResult[][];
}
