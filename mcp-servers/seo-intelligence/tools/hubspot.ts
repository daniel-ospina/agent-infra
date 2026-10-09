import { Client } from "@hubspot/api-client";
import { fetchNames, exactMatch, fuzzyMatch, type CreateResult } from "./dedup.js";
import { PARTNER_TYPES, isPartnerType, type FilterGroup } from "./constants.js";

function getClient(): Client {
  const accessToken = process.env.HUBSPOT_SERVICE_KEY;
  if (!accessToken) throw new Error("HUBSPOT_SERVICE_KEY not configured");
  return new Client({ accessToken });
}

// SEO custom properties that need to exist in HubSpot
const SEO_PROPERTIES = [
  "contact_type",
  "seo_relevance_score",
  "seo_link_type",
  "seo_outreach_status",
  "seo_target_page",
  "seo_anchor_theme",
  "seo_domain_authority",
];

export async function createPartner(params: {
  name: string;
  domain?: string;
  contact_type: string;
  seo_relevance_score?: number;
  seo_link_type?: string;
  seo_outreach_status?: string;
  seo_target_page?: string;
  seo_anchor_theme?: string;
  seo_domain_authority?: number;
  city?: string;
  description?: string;
  force?: boolean;
}): Promise<CreateResult> {
  if (!isPartnerType(params.contact_type)) {
    throw new Error(
      `Invalid contact_type: ${params.contact_type}. Must be one of: ${PARTNER_TYPES.join(", ")}`
    );
  }

  // Tier 1 — always run, cannot be bypassed
  const existing = await fetchNames("partner");
  const tier1 = exactMatch(params.name, existing);
  if (tier1.length > 0) return { status: "blocked", matches: tier1 };

  // Tier 2 — Haiku fuzzy, skipped when force: true
  if (!params.force) {
    const tier2 = await fuzzyMatch(params.name, existing);
    if (tier2.length > 0) return { status: "warning", matches: tier2 };
  }

  const hubspot = getClient();
  const properties: Record<string, string> = {
    name: params.name,
    contact_type: params.contact_type,
    seo_outreach_status: params.seo_outreach_status ?? "not_contacted",
  };

  if (params.domain) properties.domain = params.domain;
  if (params.seo_relevance_score !== undefined) properties.seo_relevance_score = String(params.seo_relevance_score);
  if (params.seo_link_type) properties.seo_link_type = params.seo_link_type;
  if (params.seo_target_page) properties.seo_target_page = params.seo_target_page;
  if (params.seo_anchor_theme) properties.seo_anchor_theme = params.seo_anchor_theme;
  if (params.seo_domain_authority !== undefined) properties.seo_domain_authority = String(params.seo_domain_authority);
  if (params.city) properties.city = params.city;
  if (params.description) properties.description = params.description;

  const response = await hubspot.crm.companies.basicApi.create({ properties });
  return { status: "created", id: response.id, properties: response.properties };
}

export async function updatePartner(
  companyId: string,
  updates: Record<string, string>
) {
  const hubspot = getClient();

  // Verify this is a partner, not a customer
  const existing = await hubspot.crm.companies.basicApi.getById(companyId, ["contact_type"]);
  const contactType = existing.properties.contact_type;
  if (!contactType || !isPartnerType(contactType)) {
    throw new Error(
      `Company ${companyId} is not a partner (contact_type: ${contactType ?? "unset"}). Refusing to modify.`
    );
  }

  const { contact_type: _, ...safeUpdates } = updates;
  const response = await hubspot.crm.companies.basicApi.update(companyId, {
    properties: safeUpdates,
  });
  return { id: response.id, properties: response.properties };
}

export async function listPartners(filters?: {
  outreach_status?: string;
  contact_type?: string;
  link_type?: string;
}) {
  if (filters?.contact_type && !isPartnerType(filters.contact_type)) {
    throw new Error(
      `Invalid contact_type: ${filters.contact_type}. Must be one of: ${PARTNER_TYPES.join(", ")}`
    );
  }

  const hubspot = getClient();

  // Build extra filters (outreach_status, link_type) that AND with each type filter.
  const extraFilters: FilterGroup["filters"] = [];
  if (filters?.outreach_status) {
    extraFilters.push({ propertyName: "seo_outreach_status", operator: "EQ", value: filters.outreach_status });
  }
  if (filters?.link_type) {
    extraFilters.push({ propertyName: "seo_link_type", operator: "EQ", value: filters.link_type });
  }

  // Use EQ per partner type (not CONTAINS_TOKEN) to support both text and enum
  // contact_type properties in HubSpot. Multiple filterGroups = OR semantics.
  const types: string[] = filters?.contact_type
    ? [filters.contact_type]
    : [...PARTNER_TYPES];
  const filterGroups: FilterGroup[] = types.map((pt) => ({
    filters: [
      { propertyName: "contact_type", operator: "EQ", value: pt },
      ...extraFilters,
    ],
  }));

  const listProperties = ["name", "domain", "city", ...SEO_PROPERTIES];
  const partners: { id: string; [key: string]: string | null }[] = [];
  let after: string | undefined;
  let total = 0;

  do {
    const response = await hubspot.crm.companies.searchApi.doSearch({
      filterGroups: filterGroups as any,
      properties: listProperties,
      sorts: [{ propertyName: "seo_relevance_score", direction: "DESCENDING" }] as any[],
      limit: 100,
      ...(after !== undefined && { after }),
    });
    if (total === 0) total = response.total; // capture from first page; HubSpot total is stable across pages
    for (const r of response.results) {
      partners.push({ id: r.id, ...r.properties });
    }
    after = response.paging?.next?.after;
  } while (after);

  return { total, partners };
}

export async function logOutreach(
  companyId: string,
  noteBody: string
) {
  const hubspot = getClient();

  // Verify this is a partner
  const existing = await hubspot.crm.companies.basicApi.getById(companyId, ["contact_type"]);
  const contactType = existing.properties.contact_type;
  if (!contactType || !isPartnerType(contactType)) {
    throw new Error(
      `Company ${companyId} is not a partner (contact_type: ${contactType ?? "unset"}). Refusing to log.`
    );
  }

  // Create a note
  const note = await hubspot.crm.objects.notes.basicApi.create({
    properties: {
      hs_note_body: noteBody,
      hs_timestamp: new Date().toISOString(),
    },
    associations: [],
  });

  // Associate note with company (v4 associations API — v12 client)
  await hubspot.crm.associations.v4.basicApi.createDefault(
    "notes",
    note.id,
    "companies",
    companyId
  );

  return { noteId: note.id, companyId, body: noteBody };
}
