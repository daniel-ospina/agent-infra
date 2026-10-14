#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { config } from "dotenv";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { searchSerp, getUsage } from "./tools/serp-router.js";
import { placesTextSearch, placeDetails } from "./tools/google-places.js";
import {
  queryAnalytics,
  getNearRankingKeywords,
  getLowCtrQueries,
  getPageOpportunities,
  inspectUrl,
} from "./tools/search-console.js";
import {
  createPartner,
  updatePartner,
  listPartners,
  logOutreach,
} from "./tools/hubspot.js";
import {
  createCustomer,
  updateCustomer,
  listCustomers,
  logCustomerNote,
  createTask,
} from "./tools/hubspot-customer.js";
import { sendEmail, getEmail } from "./tools/resend.js";
import { perplexitySearch, perplexityResearch } from "./tools/perplexity.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
config({ path: resolve(__dirname, ".env") });

const server = new McpServer({
  name: "seo-intelligence",
  version: "1.0.0",
});

// ── Ping tool (smoke test) ─────────────────────────────────────────
server.tool("ping", "Check if the SEO intelligence server is running", {}, async () => {
  return {
    content: [{ type: "text", text: "SEO Intelligence MCP server is running." }],
  };
});

// ── SERP tools ───────────────────────────────────────────────────────
server.tool(
  "search_serp",
  "Search Google via SERP scraping. Auto-routes to cheapest available provider (Oxylabs → Serper → SerpAPI). Returns organic results, snippets, related searches.",
  {
    query: z.string().describe("The search query"),
    geo_location: z.string().optional().describe("Geographic location, e.g. 'Quintana Roo,Mexico'"),
    num_results: z.number().optional().default(10).describe("Number of results to return"),
  },
  async ({ query, geo_location, num_results }) => {
    try {
      const result = await searchSerp(query, geo_location);
      const trimmed = {
        ...result,
        organic_results: result.organic_results.slice(0, num_results),
      };
      return { content: [{ type: "text", text: JSON.stringify(trimmed, null, 2) }] };
    } catch (error) {
      return {
        content: [{ type: "text", text: `SERP search failed: ${error instanceof Error ? error.message : String(error)}` }],
        isError: true,
      };
    }
  }
);

server.tool(
  "search_serp_local",
  "Search Google with geo_location preset to Riviera Maya. Use for discovering local blogs, publishers, directories.",
  {
    query: z.string().describe("The search query"),
    num_results: z.number().optional().default(10).describe("Number of results to return"),
  },
  async ({ query, num_results }) => {
    try {
      const geoLocation = process.env.DEFAULT_GEO_LOCATION ?? "Quintana Roo,Mexico";
      const result = await searchSerp(query, geoLocation);
      const trimmed = {
        ...result,
        organic_results: result.organic_results.slice(0, num_results),
      };
      return { content: [{ type: "text", text: JSON.stringify(trimmed, null, 2) }] };
    } catch (error) {
      return {
        content: [{ type: "text", text: `Local SERP search failed: ${error instanceof Error ? error.message : String(error)}` }],
        isError: true,
      };
    }
  }
);

server.tool(
  "serp_usage",
  "Show current SERP API usage across all providers. Use to check remaining quota.",
  {},
  async () => {
    const usage = getUsage();
    return { content: [{ type: "text", text: JSON.stringify(usage, null, 2) }] };
  }
);

// ── Perplexity Search Tools ──────────────────────────────────────────
server.tool(
  "perplexity_search",
  "Search the web via Perplexity and get real content snippets from each result page — not just brief Google excerpts. Use for content research, understanding what a page actually covers. Returns title, URL, full snippet, date.",
  {
    query: z.string().describe("The search query"),
    max_results: z.number().optional().default(5).describe("Number of results (1–20, default 5)"),
  },
  async ({ query, max_results }) => {
    try {
      const result = await perplexitySearch(query, max_results);
      return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
    } catch (error) {
      return {
        content: [{ type: "text", text: `Perplexity search failed: ${error instanceof Error ? error.message : String(error)}` }],
        isError: true,
      };
    }
  }
);

server.tool(
  "perplexity_research",
  "Deep web research via Perplexity with advanced filtering. Supports multi-query (up to 5 queries at once), domain allowlist/denylist, language filter, and country targeting. Multi-query results are grouped per query. Use for competitor content analysis, backlink prospecting, multilingual research.",
  {
    query: z.union([z.string(), z.array(z.string()).max(5)]).describe("Single query or array of up to 5 queries for batch research"),
    max_results: z.number().optional().default(5).describe("Results per query (1–20, default 5)"),
    country: z.string().optional().describe("ISO 3166-1 alpha-2 country code to bias results, e.g. 'MX', 'US'"),
    search_domain_filter: z.array(z.string()).optional().describe("Allowlist domains (['site.com']) or denylist (['-site.com']). Max 20. Cannot mix modes."),
    search_language_filter: z.array(z.string()).optional().describe("ISO 639-1 language codes, e.g. ['es', 'en']. Max 10."),
    max_tokens_per_page: z.number().optional().describe("Content extracted per page in tokens (default API 4096, lower = faster)"),
  },
  async ({ query, max_results, country, search_domain_filter, search_language_filter, max_tokens_per_page }) => {
    try {
      const result = await perplexityResearch({
        query,
        maxResults: max_results,
        country,
        searchDomainFilter: search_domain_filter,
        searchLanguageFilter: search_language_filter,
        maxTokensPerPage: max_tokens_per_page,
      });
      return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
    } catch (error) {
      return {
        content: [{ type: "text", text: `Perplexity research failed: ${error instanceof Error ? error.message : String(error)}` }],
        isError: true,
      };
    }
  }
);

// ── Google Places Tools ─────────────────────────────────────────────
server.tool(
  "places_search",
  "Search Google Places for businesses/organizations by query. Returns name, address, website, rating, types. Use for finding local authority nodes, directories, event venues.",
  {
    query: z.string().describe("Search query, e.g. 'Playa del Carmen blog' or 'Riviera Maya tourism company'"),
    location: z.string().optional().describe("Lat,lng to bias results, e.g. '20.6296,-87.0739' for Playa del Carmen"),
  },
  async ({ query, location }) => {
    try {
      const results = await placesTextSearch(query, location);
      return { content: [{ type: "text", text: JSON.stringify(results, null, 2) }] };
    } catch (error) {
      return {
        content: [{ type: "text", text: `Places search failed: ${error instanceof Error ? error.message : String(error)}` }],
        isError: true,
      };
    }
  }
);

server.tool(
  "places_details",
  "Get detailed info for a specific Google Place: reviews, website, hours, phone. Use place_id from places_search results.",
  {
    place_id: z.string().describe("The Google Place ID from a places_search result"),
  },
  async ({ place_id }) => {
    try {
      const details = await placeDetails(place_id);
      return { content: [{ type: "text", text: JSON.stringify(details, null, 2) }] };
    } catch (error) {
      return {
        content: [{ type: "text", text: `Places details failed: ${error instanceof Error ? error.message : String(error)}` }],
        isError: true,
      };
    }
  }
);

// ── Google Search Console Tools ─────────────────────────────────────
server.tool(
  "gsc_query_analytics",
  "Query Google Search Console analytics data. Returns queries, pages, clicks, impressions, CTR, position. Default site: eldato.com.mx.",
  {
    start_date: z.string().describe("Start date YYYY-MM-DD"),
    end_date: z.string().describe("End date YYYY-MM-DD"),
    dimensions: z.array(z.string()).optional().default(["query", "page"]).describe("Dimensions: query, page, country, device, date"),
    row_limit: z.number().optional().default(100).describe("Max rows to return (up to 25000)"),
    site_url: z.string().optional().describe("Site URL. Defaults to https://eldato.com.mx"),
  },
  async ({ start_date, end_date, dimensions, row_limit, site_url }) => {
    try {
      const data = await queryAnalytics({
        siteUrl: site_url,
        startDate: start_date,
        endDate: end_date,
        dimensions,
        rowLimit: row_limit,
      });
      return { content: [{ type: "text", text: JSON.stringify(data, null, 2) }] };
    } catch (error) {
      return {
        content: [{ type: "text", text: `GSC query failed: ${error instanceof Error ? error.message : String(error)}` }],
        isError: true,
      };
    }
  }
);

server.tool(
  "gsc_near_ranking",
  "Find 'almost page 1' keywords: position 8-20 with decent impressions. These are prime backlink targets — a few links could push them to page 1.",
  {
    min_impressions: z.number().optional().default(20).describe("Minimum impressions threshold"),
    start_date: z.string().optional().describe("Start date YYYY-MM-DD. Defaults to 30 days ago."),
    end_date: z.string().optional().describe("End date YYYY-MM-DD. Defaults to 3 days ago."),
    site_url: z.string().optional().describe("Site URL. Defaults to https://eldato.com.mx"),
  },
  async ({ min_impressions, start_date, end_date, site_url }) => {
    try {
      const data = await getNearRankingKeywords(site_url, start_date, end_date, min_impressions);
      return { content: [{ type: "text", text: JSON.stringify(data, null, 2) }] };
    } catch (error) {
      return {
        content: [{ type: "text", text: `GSC near-ranking query failed: ${error instanceof Error ? error.message : String(error)}` }],
        isError: true,
      };
    }
  }
);

server.tool(
  "gsc_low_ctr",
  "Find queries ranking in top 10 but with CTR below site average. These need title/meta optimization, not backlinks.",
  {
    start_date: z.string().optional().describe("Start date YYYY-MM-DD. Defaults to 30 days ago."),
    end_date: z.string().optional().describe("End date YYYY-MM-DD. Defaults to 3 days ago."),
    site_url: z.string().optional().describe("Site URL. Defaults to https://eldato.com.mx"),
  },
  async ({ start_date, end_date, site_url }) => {
    try {
      const data = await getLowCtrQueries(site_url, start_date, end_date);
      return { content: [{ type: "text", text: JSON.stringify(data, null, 2) }] };
    } catch (error) {
      return {
        content: [{ type: "text", text: `GSC low-CTR query failed: ${error instanceof Error ? error.message : String(error)}` }],
        isError: true,
      };
    }
  }
);

server.tool(
  "gsc_page_opportunities",
  "Score pages by backlink opportunity. Ranks by: near-ranking query count, total impressions, position improvement potential. Use to prioritize which pages deserve backlinks.",
  {
    start_date: z.string().optional().describe("Start date YYYY-MM-DD. Defaults to 30 days ago."),
    end_date: z.string().optional().describe("End date YYYY-MM-DD. Defaults to 3 days ago."),
    site_url: z.string().optional().describe("Site URL. Defaults to https://eldato.com.mx"),
  },
  async ({ start_date, end_date, site_url }) => {
    try {
      const data = await getPageOpportunities(site_url, start_date, end_date);
      return { content: [{ type: "text", text: JSON.stringify(data, null, 2) }] };
    } catch (error) {
      return {
        content: [{ type: "text", text: `GSC page opportunities query failed: ${error instanceof Error ? error.message : String(error)}` }],
        isError: true,
      };
    }
  }
);

server.tool(
  "gsc_inspect_url",
  "Inspect a URL in Google Search Console: indexing status, crawl info, mobile usability.",
  {
    url: z.string().describe("The full URL to inspect"),
    site_url: z.string().optional().describe("Site URL. Defaults to https://eldato.com.mx"),
  },
  async ({ url, site_url }) => {
    try {
      const data = await inspectUrl(url, site_url);
      return { content: [{ type: "text", text: JSON.stringify(data, null, 2) }] };
    } catch (error) {
      return {
        content: [{ type: "text", text: `URL inspection failed: ${error instanceof Error ? error.message : String(error)}` }],
        isError: true,
      };
    }
  }
);

// ── HubSpot Partner Tools ───────────────────────────────────────────
server.tool(
  "hubspot_create_partner",
  "Create a backlink/partnership prospect as a Company in HubSpot. Only creates partner records — never touches customer data. Sets contact_type, SEO properties.",
  {
    name: z.string().describe("Company/blog name"),
    domain: z.string().optional().describe("Website domain, e.g. 'playadelcarmen.blog'"),
    contact_type: z.enum(["partner_blog", "partner_directory", "partner_media", "partner_local_biz"]).describe("Type of partner"),
    seo_relevance_score: z.number().min(1).max(5).optional().describe("How relevant to El Dato SEO goals (1-5)"),
    seo_link_type: z.enum(["guest_post", "citation", "directory_listing", "co_marketing", "editorial_mention"]).optional().describe("Expected backlink type"),
    seo_outreach_status: z.enum(["not_contacted", "contacted", "responded", "link_acquired", "rejected"]).optional().describe("Initial outreach status (default: not_contacted)"),
    seo_domain_authority: z.number().min(0).max(100).optional().describe("Domain authority score (0-100)"),
    seo_target_page: z.string().optional().describe("Which El Dato page this backlink would support"),
    seo_anchor_theme: z.string().optional().describe("Suggested anchor text theme"),
    city: z.string().optional().describe("City, e.g. 'Playa del Carmen'"),
    description: z.string().optional().describe("Notes about this prospect"),
    force: z.boolean().optional().describe(
      "Skip the fuzzy duplicate check if user confirmed this is a new partner. Does NOT bypass exact-match blocking."
    ),
  },
  async (params) => {
    try {
      const result = await createPartner(params);
      if (result.status === "blocked") {
        const lines = result.matches
          .map((m) => `• "${m.name}" (ID: ${m.id}) — ${m.reason}`)
          .join("\n");
        return {
          content: [{
            type: "text",
            text: `⛔ Exact duplicate detected — not created:\n${lines}`,
          }],
          isError: true,
        };
      }
      if (result.status === "warning") {
        const lines = result.matches
          .map((m) => `• "${m.name}" (ID: ${m.id}) — ${m.reason}`)
          .join("\n");
        // Intentionally no isError:true — warning is a user-facing question,
        // not a tool failure. The agent surfaces it to the user and retries
        // with force:true if confirmed.
        return {
          content: [{
            type: "text",
            text: `⚠️ Possible duplicate(s) found — confirm with user before proceeding:\n${lines}\n\nIf user confirms this is a different business, retry with force: true.`,
          }],
        };
      }
      return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
    } catch (error) {
      return {
        content: [{ type: "text", text: `HubSpot create failed: ${error instanceof Error ? error.message : String(error)}` }],
        isError: true,
      };
    }
  }
);

server.tool(
  "hubspot_update_partner",
  "Update a partner company's SEO properties or outreach status. Safety: refuses to modify non-partner records.",
  {
    company_id: z.string().describe("HubSpot company ID"),
    seo_outreach_status: z.enum(["not_contacted", "contacted", "responded", "link_acquired", "rejected"]).optional().describe("Outreach status"),
    seo_relevance_score: z.string().optional().describe("Relevance score (1-5)"),
    seo_link_type: z.string().optional().describe("Link type"),
    seo_target_page: z.string().optional().describe("Target page URL"),
    seo_anchor_theme: z.string().optional().describe("Anchor theme"),
    seo_domain_authority: z.string().optional().describe("Domain authority"),
  },
  async ({ company_id, ...updates }) => {
    try {
      const cleanUpdates: Record<string, string> = {};
      for (const [key, value] of Object.entries(updates)) {
        if (value !== undefined) cleanUpdates[key] = value;
      }
      const result = await updatePartner(company_id, cleanUpdates);
      return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
    } catch (error) {
      return {
        content: [{ type: "text", text: `HubSpot update failed: ${error instanceof Error ? error.message : String(error)}` }],
        isError: true,
      };
    }
  }
);

server.tool(
  "hubspot_list_partners",
  "List backlink/partnership prospects from HubSpot. Only shows partner companies — never customer data. Supports filtering by outreach status, partner type, link type.",
  {
    outreach_status: z.enum(["not_contacted", "contacted", "responded", "link_acquired", "rejected"]).optional().describe("Filter by outreach status"),
    contact_type: z.enum(["partner_blog", "partner_directory", "partner_media", "partner_local_biz"]).optional().describe("Filter by partner type"),
    link_type: z.enum(["guest_post", "citation", "directory_listing", "co_marketing", "editorial_mention"]).optional().describe("Filter by link type"),
  },
  async ({ outreach_status, contact_type, link_type }) => {
    try {
      const result = await listPartners({ outreach_status, contact_type, link_type });
      return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
    } catch (error) {
      return {
        content: [{ type: "text", text: `HubSpot list failed: ${error instanceof Error ? error.message : String(error)}` }],
        isError: true,
      };
    }
  }
);

server.tool(
  "hubspot_log_outreach",
  "Log an outreach activity note on a partner company. Safety: refuses to log on non-partner records.",
  {
    company_id: z.string().describe("HubSpot company ID"),
    note: z.string().describe("Outreach note, e.g. 'Sent initial pitch email about guest post on local restaurant deals'"),
  },
  async ({ company_id, note }) => {
    try {
      const result = await logOutreach(company_id, note);
      return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
    } catch (error) {
      return {
        content: [{ type: "text", text: `HubSpot log failed: ${error instanceof Error ? error.message : String(error)}` }],
        isError: true,
      };
    }
  }
);

// ── HubSpot Customer Tools ──────────────────────────────────────────
server.tool(
  "hubspot_create_customer",
  "Create an El Dato business customer in HubSpot. Always sets contact_type=customer. Use for any business that has or could have a deal on El Dato. Never use for SEO backlink prospects — use hubspot_create_partner for those.",
  {
    name: z.string().describe("Business name"),
    outreach_status: z.enum([
      "Not Reached",
      "Reached",
      "Reached questioned local deal",
      "Reached- No Response",
      "Internal Review",
      "Will Add Deal",
      "Business Created",
      "Deal Created",
      "Not Interested",
    ]).optional().default("Not Reached").describe("Outreach pipeline stage (default: Not Reached)"),
    city: z.string().optional().describe("City, e.g. 'Playa del Carmen'"),
    domain: z.string().optional().describe("Website domain"),
    phone: z.string().optional(),
    instagram_url: z.string().optional(),
    facebook_company_page: z.string().optional(),
    website: z.string().optional(),
    description: z.string().optional().describe("Notes about this business"),
    local_deal_status: z.enum([
      "Existing Local Discount",
      "No Local Discount",
      "Previous Local Discount",
    ]).optional(),
    deal_type: z.enum([
      "Local Discount- City",
      "Local Discount- State",
      "Local Discount- 2+ States",
    ]).optional(),
    eldato_deal_page: z.string().optional().describe("URL to their El Dato deal page"),
    price_tier: z.string().optional().describe("$ to $$$$$"),
    rating: z.number().optional(),
    interview_status: z.enum([
      "Not Interviewd", // intentional: matches HubSpot property value verbatim
      "Interview Pending",
      "Interviewed",
    ]).optional(),
    force: z.boolean().optional().describe(
      "Skip the fuzzy duplicate check if the user has confirmed this is a new business. Does NOT bypass exact-match blocking."
    ),
  },
  async (params) => {
    try {
      const result = await createCustomer(params);
      if (result.status === "blocked") {
        const lines = result.matches
          .map((m) => `• "${m.name}" (ID: ${m.id}) — ${m.reason}`)
          .join("\n");
        return {
          content: [{
            type: "text",
            text: `⛔ Exact duplicate detected — not created:\n${lines}`,
          }],
          isError: true,
        };
      }
      if (result.status === "warning") {
        const lines = result.matches
          .map((m) => `• "${m.name}" (ID: ${m.id}) — ${m.reason}`)
          .join("\n");
        // Intentionally no isError:true — warning is a user-facing question,
        // not a tool failure. The agent surfaces it to the user and retries
        // with force:true if confirmed.
        return {
          content: [{
            type: "text",
            text: `⚠️ Possible duplicate(s) found — confirm with user before proceeding:\n${lines}\n\nIf user confirms this is a different business, retry with force: true.`,
          }],
        };
      }
      return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
    } catch (error) {
      return {
        content: [{ type: "text", text: `HubSpot create customer failed: ${error instanceof Error ? error.message : String(error)}` }],
        isError: true,
      };
    }
  }
);

server.tool(
  "hubspot_update_customer",
  "Update an El Dato customer company's properties. Safety: refuses to modify any company that is not contact_type=customer.",
  {
    company_id: z.string().describe("HubSpot company ID"),
    outreach_status: z.enum([
      "Not Reached",
      "Reached",
      "Reached questioned local deal",
      "Reached- No Response",
      "Internal Review",
      "Will Add Deal",
      "Business Created",
      "Deal Created",
      "Not Interested",
    ]).optional(),
    local_deal_status: z.enum([
      "Existing Local Discount",
      "No Local Discount",
      "Previous Local Discount",
    ]).optional(),
    deal_type: z.enum([
      "Local Discount- City",
      "Local Discount- State",
      "Local Discount- 2+ States",
    ]).optional(),
    eldato_deal_page: z.string().optional(),
    rating: z.number().optional(),
    price_tier: z.string().optional().describe("$ to $$$$$"),
    interview_status: z.enum([
      "Not Interviewd", // intentional: matches HubSpot property value verbatim
      "Interview Pending",
      "Interviewed",
    ]).optional(),
    description: z.string().optional(),
  },
  async ({ company_id, ...rest }) => {
    try {
      const updates: Record<string, string> = {};
      for (const [k, v] of Object.entries(rest)) {
        if (v !== undefined) updates[k] = String(v);
      }
      const result = await updateCustomer(company_id, updates);
      return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
    } catch (error) {
      return {
        content: [{ type: "text", text: `HubSpot update customer failed: ${error instanceof Error ? error.message : String(error)}` }],
        isError: true,
      };
    }
  }
);

server.tool(
  "hubspot_list_customers",
  "List El Dato business customers from HubSpot. Only returns contact_type=customer records. Use to find businesses to follow up with.",
  {
    outreach_status: z.enum([
      "Not Reached",
      "Reached",
      "Reached questioned local deal",
      "Reached- No Response",
      "Internal Review",
      "Will Add Deal",
      "Business Created",
      "Deal Created",
      "Not Interested",
    ]).optional().describe("Filter by pipeline stage"),
    city: z.string().optional().describe("Filter by city"),
  },
  async ({ outreach_status, city }) => {
    try {
      const result = await listCustomers({ outreach_status, city });
      return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
    } catch (error) {
      return {
        content: [{ type: "text", text: `HubSpot list customers failed: ${error instanceof Error ? error.message : String(error)}` }],
        isError: true,
      };
    }
  }
);

server.tool(
  "hubspot_log_customer_note",
  "Add a note to an El Dato customer company. Safety: refuses to log on non-customer records.",
  {
    company_id: z.string().describe("HubSpot company ID"),
    note: z.string().describe("Note body, e.g. 'Called, spoke with manager. Will review proposal next week.'"),
  },
  async ({ company_id, note }) => {
    try {
      const result = await logCustomerNote(company_id, note);
      return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
    } catch (error) {
      return {
        content: [{ type: "text", text: `HubSpot log note failed: ${error instanceof Error ? error.message : String(error)}` }],
        isError: true,
      };
    }
  }
);

server.tool(
  "hubspot_create_task",
  "Create a follow-up task in HubSpot linked to a company. Works for both customers and partners. Use for scheduling callbacks, demos, follow-ups.",
  {
    company_id: z.string().describe("HubSpot company ID to link the task to"),
    subject: z.string().describe("Task subject, e.g. 'Follow up with Fragata Beach Club'"),
    body: z.string().optional().default("").describe("Task notes/body"),
    due_date: z.string().describe("Due date in YYYY-MM-DD format"),
  },
  async ({ company_id, subject, body, due_date }) => {
    try {
      const result = await createTask(company_id, subject, body, due_date);
      return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
    } catch (error) {
      return {
        content: [{ type: "text", text: `HubSpot create task failed: ${error instanceof Error ? error.message : String(error)}` }],
        isError: true,
      };
    }
  }
);

// ── Resend Email Tools ───────────────────────────────────────────────
server.tool(
  "send_email",
  "Send an outreach email via Resend. Use for backlink pitches, guest post proposals, partnership outreach. Always draft manually — this just sends.",
  {
    to: z.array(z.string()).describe("Recipient email addresses"),
    subject: z.string().describe("Email subject line"),
    html: z.string().optional().describe("HTML body content"),
    text: z.string().optional().describe("Plain text body (fallback)"),
    from: z.string().optional().describe("From address. Defaults to RESEND_FROM_EMAIL env var."),
    reply_to: z.string().optional().describe("Reply-to address"),
    cc: z.array(z.string()).optional().describe("CC recipients"),
    bcc: z.array(z.string()).optional().describe("BCC recipients"),
  },
  async (params) => {
    try {
      const result = await sendEmail(params);
      return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
    } catch (error) {
      return {
        content: [{ type: "text", text: `Email send failed: ${error instanceof Error ? error.message : String(error)}` }],
        isError: true,
      };
    }
  }
);

server.tool(
  "get_email_status",
  "Check the delivery status of a previously sent email by ID.",
  {
    email_id: z.string().describe("The email ID returned from send_email"),
  },
  async ({ email_id }) => {
    try {
      const result = await getEmail(email_id);
      return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
    } catch (error) {
      return {
        content: [{ type: "text", text: `Email status check failed: ${error instanceof Error ? error.message : String(error)}` }],
        isError: true,
      };
    }
  }
);

// ── Start server ────────────────────────────────────────────────────
async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error("SEO Intelligence MCP server running on stdio");
}

main().catch((error) => {
  console.error("Fatal error:", error);
  process.exit(1);
});
