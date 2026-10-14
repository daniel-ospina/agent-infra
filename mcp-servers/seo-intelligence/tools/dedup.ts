import { Client } from "@hubspot/api-client";
import Anthropic from "@anthropic-ai/sdk";
import { PARTNER_TYPES, type FilterGroup } from "./constants.js";

const HAIKU_MODEL = process.env.ANTHROPIC_MODEL ?? "claude-haiku-4-5-20251001";

export type DuplicateMatch = {
  id: string;
  name: string;
  reason: string;
};

export type CreateResult =
  | { status: "created"; id: string; properties: Record<string, string | null> }
  | { status: "blocked"; matches: DuplicateMatch[] }
  | { status: "warning"; matches: DuplicateMatch[] };

/** Normalize a business name for fuzzy-free comparison.
 *  Steps: NFD decompose → strip combining marks → lowercase → strip punctuation → collapse spaces */
export function normalize(name: string): string {
  return name
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9\s]/g, "")
    .replace(/\s+/g, " ")
    .trim();
}

/** Tier 1: find exact normalized matches in existing list. Never skippable. */
export function exactMatch(
  name: string,
  existing: { id: string; name: string }[]
): DuplicateMatch[] {
  const n = normalize(name);
  // Guard: a name that normalizes to "" (e.g. "!!!" or "   ") matches nothing
  // meaningful, so we skip the check to avoid false blocks against garbage records.
  if (n === "") return [];
  return existing
    .filter((e) => normalize(e.name) === n)
    .map((e) => ({
      id: e.id,
      name: e.name,
      reason: "normalized name match (case/accent/punctuation variant)",
    }));
}

function getHubSpotClient(): Client {
  const accessToken = process.env.HUBSPOT_SERVICE_KEY;
  if (!accessToken) throw new Error("HUBSPOT_SERVICE_KEY not configured");
  return new Client({ accessToken });
}

/** Fetch all company names for a given track from HubSpot (paginated). */
export async function fetchNames(
  track: "customer" | "partner" | "both"
): Promise<{ id: string; name: string }[]> {
  const hubspot = getHubSpotClient();

  const filterGroups: FilterGroup[] = [];
  if (track === "customer" || track === "both") {
    filterGroups.push({
      filters: [{ propertyName: "contact_type", operator: "EQ", value: "customer" }],
    });
  }
  if (track === "partner" || track === "both") {
    for (const pt of PARTNER_TYPES) {
      filterGroups.push({
        filters: [{ propertyName: "contact_type", operator: "EQ", value: pt }],
      });
    }
  }

  const results: { id: string; name: string }[] = [];
  let after: string | undefined;

  do {
    const response = await hubspot.crm.companies.searchApi.doSearch({
      filterGroups: filterGroups as any,
      properties: ["name"],
      limit: 200,
      ...(after !== undefined && { after }),
    });

    for (const r of response.results) {
      if (r.properties.name) {
        results.push({ id: r.id, name: r.properties.name });
      }
    }
    after = response.paging?.next?.after;
  } while (after);

  return results;
}

/** Tier 2: call Haiku to find semantically similar names (spelling errors, abbreviations). */
export async function fuzzyMatch(
  name: string,
  existing: { id: string; name: string }[]
): Promise<DuplicateMatch[]> {
  if (existing.length === 0) return [];
  // Strip newlines to prevent prompt injection via crafted business names.
  const safeName = name.replace(/[\r\n]/g, " ");

  const anthropic = new Anthropic({ apiKey: process.env.ANTHROPIC_API_KEY });
  // NOTE: all existing names are sent in one prompt. At ~500+ companies this will
  // grow large. Consider chunking or a vector-search approach if the directory scales.
  // Sanitize names (new and existing) to prevent prompt injection via newline characters.
  // Deduplicate names before sending — duplicate HubSpot records would otherwise inflate
  // the prompt and could cause Haiku to return the same match twice.
  const seenNames = new Set<string>();
  const existingNames = existing
    .map((e) => e.name.replace(/[\r\n]/g, " "))
    .filter((n) => { if (seenNames.has(n)) return false; seenNames.add(n); return true; })
    .join("\n");

  let response: Awaited<ReturnType<typeof anthropic.messages.create>>;
  try {
    response = await anthropic.messages.create({
      model: HAIKU_MODEL,
      max_tokens: 512,
      system: `You are a duplicate detector for a Mexican tourism business directory.
Given a new business name and a list of existing names, identify existing names that likely refer to the same real-world business.
Respond with a JSON array: [{"name": "<existing name exactly as given>", "reason": "<brief reason>"}].
Only include strong matches: spelling variants, abbreviations, clearly the same business with different punctuation.
Return [] if no strong matches. Return ONLY valid JSON, no other text.`,
      messages: [
        {
          role: "user",
          content: `New business name: "${safeName}"\n\nExisting names:\n${existingNames}`,
        },
      ],
    });
  } catch (err) {
    // Network/API error or missing ANTHROPIC_API_KEY — fail safe, don't block creation.
    // Log so operators can detect silent tier-2 degradation (e.g. missing env var).
    console.error("[dedup] fuzzyMatch failed, skipping tier-2:", err instanceof Error ? err.message : err);
    return [];
  }

  const first = response.content[0];
  const text = first?.type === "text" ? first.text.trim() : "[]";

  let matches: { name: string; reason: string }[];
  try {
    matches = JSON.parse(text);
    if (!Array.isArray(matches)) return [];
  } catch {
    return []; // malformed JSON from Haiku — fail safe, don't block creation
  }

  const nameToRecord = new Map(existing.map((e) => [e.name, e]));
  return matches
    .filter((m) => nameToRecord.has(m.name))
    .map((m) => ({
      id: nameToRecord.get(m.name)!.id,
      name: m.name,
      reason: `Haiku: ${m.reason}`,
    }));
}
