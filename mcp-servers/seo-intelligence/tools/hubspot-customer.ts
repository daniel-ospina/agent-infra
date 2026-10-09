import { Client } from "@hubspot/api-client";
import { fetchNames, exactMatch, fuzzyMatch, type CreateResult } from "./dedup.js";
import { type FilterGroup } from "./constants.js";

function getClient(): Client {
  const accessToken = process.env.HUBSPOT_SERVICE_KEY;
  if (!accessToken) throw new Error("HUBSPOT_SERVICE_KEY not configured");
  return new Client({ accessToken });
}

export type OutreachStatus =
  | "Not Reached"
  | "Reached"
  | "Reached questioned local deal"
  | "Reached- No Response"
  | "Internal Review"
  | "Will Add Deal"
  | "Business Created"
  | "Deal Created"
  | "Not Interested";

const CUSTOMER_PROPERTIES = [
  "name", "domain", "city", "phone",
  "instagram_url", "facebook_company_page", "website", "description",
  "outreach_status", "local_deal_status", "deal_type",
  "eldato_deal_page", "price_tier", "rating",
  "interview_status", "id_requirements",
];

export async function createCustomer(params: {
  name: string;
  force?: boolean;
  outreach_status?: OutreachStatus;
  city?: string;
  domain?: string;
  phone?: string;
  instagram_url?: string;
  facebook_company_page?: string;
  website?: string;
  description?: string;
  local_deal_status?: string;
  deal_type?: string;
  eldato_deal_page?: string;
  price_tier?: string;
  rating?: number;
  interview_status?: string;
}): Promise<CreateResult> {
  // Tier 1 — always run, cannot be bypassed
  const existing = await fetchNames("customer");
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
    contact_type: "customer",
    outreach_status: params.outreach_status ?? "Not Reached",
  };

  if (params.city) properties.city = params.city;
  if (params.domain) properties.domain = params.domain;
  if (params.phone) properties.phone = params.phone;
  if (params.instagram_url) properties.instagram_url = params.instagram_url;
  if (params.facebook_company_page) properties.facebook_company_page = params.facebook_company_page;
  if (params.website) properties.website = params.website;
  if (params.description) properties.description = params.description;
  if (params.local_deal_status) properties.local_deal_status = params.local_deal_status;
  if (params.deal_type) properties.deal_type = params.deal_type;
  if (params.eldato_deal_page) properties.eldato_deal_page = params.eldato_deal_page;
  if (params.price_tier) properties.price_tier = params.price_tier;
  if (params.rating !== undefined) properties.rating = String(params.rating);
  if (params.interview_status) properties.interview_status = params.interview_status;

  const response = await hubspot.crm.companies.basicApi.create({ properties });
  return { status: "created", id: response.id, properties: response.properties };
}

export async function updateCustomer(
  companyId: string,
  updates: Record<string, string>
) {
  const hubspot = getClient();
  const existing = await hubspot.crm.companies.basicApi.getById(companyId, [
    "contact_type",
  ]);
  const contactType = existing.properties.contact_type;
  if (contactType !== "customer") {
    throw new Error(
      `Company ${companyId} is not a customer (contact_type: ${contactType ?? "unset"}). Refusing to modify.`
    );
  }
  // Prevent accidental cross-track reclassification
  const { contact_type: _, ...safeUpdates } = updates;
  const response = await hubspot.crm.companies.basicApi.update(companyId, {
    properties: safeUpdates,
  });
  return { id: response.id, properties: response.properties };
}

export async function listCustomers(filters?: {
  outreach_status?: string;
  city?: string;
}) {
  const hubspot = getClient();
  const baseFilters: FilterGroup["filters"] = [
    { propertyName: "contact_type", operator: "EQ", value: "customer" },
  ];

  if (filters?.outreach_status) {
    baseFilters.push({
      propertyName: "outreach_status",
      operator: "EQ",
      value: filters.outreach_status,
    });
  }
  if (filters?.city) {
    baseFilters.push({
      propertyName: "city",
      operator: "EQ",
      value: filters.city,
    });
  }

  const customers: { id: string; [key: string]: string | null }[] = [];
  let after: string | undefined;
  let total = 0;

  do {
    const response = await hubspot.crm.companies.searchApi.doSearch({
      filterGroups: [{ filters: baseFilters }] as any,
      properties: CUSTOMER_PROPERTIES,
      sorts: [{ propertyName: "name", direction: "ASCENDING" }] as any[],
      limit: 100,
      ...(after !== undefined && { after }),
    });
    if (total === 0) total = response.total; // capture from first page; HubSpot total is stable across pages
    for (const r of response.results) {
      customers.push({ id: r.id, ...r.properties });
    }
    after = response.paging?.next?.after;
  } while (after);

  return { total, customers };
}

export async function logCustomerNote(companyId: string, noteBody: string) {
  const hubspot = getClient();
  const existing = await hubspot.crm.companies.basicApi.getById(companyId, [
    "contact_type",
  ]);
  const contactType = existing.properties.contact_type;
  if (contactType !== "customer") {
    throw new Error(
      `Company ${companyId} is not a customer (contact_type: ${contactType ?? "unset"}). Refusing to log.`
    );
  }

  const note = await hubspot.crm.objects.notes.basicApi.create({
    properties: {
      hs_note_body: noteBody,
      hs_timestamp: new Date().toISOString(),
    },
    associations: [],
  } as any);

  await hubspot.crm.associations.v4.basicApi.createDefault(
    "notes",
    note.id,
    "companies",
    companyId
  );

  return { noteId: note.id, companyId, body: noteBody };
}

export async function createTask(
  companyId: string,
  subject: string,
  body: string,
  dueDate: string // YYYY-MM-DD
) {
  const hubspot = getClient();
  const ts = new Date(dueDate + "T09:00:00Z");
  if (isNaN(ts.getTime())) throw new Error(`Invalid dueDate: "${dueDate}". Expected YYYY-MM-DD.`);
  // Guard against calendar roll-over (e.g. "2026-02-30" → V8 silently yields March 2)
  if (ts.toISOString().slice(0, 10) !== dueDate) throw new Error(`Invalid dueDate: "${dueDate}" is not a real calendar date.`);
  const response = await hubspot.crm.objects.tasks.basicApi.create({
    properties: {
      hs_timestamp: ts.toISOString(),
      hs_task_subject: subject,
      hs_task_body: body,
      hs_task_status: "NOT_STARTED",
    },
    associations: [
      {
        to: { id: companyId },
        types: [
          {
            associationCategory: "HUBSPOT_DEFINED" as any,
            associationTypeId: 192, // task-to-company
          },
        ],
      },
    ],
  });
  return { taskId: response.id, companyId, subject };
}
