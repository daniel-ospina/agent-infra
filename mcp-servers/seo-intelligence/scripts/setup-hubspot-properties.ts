import { config } from "dotenv";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { Client } from "@hubspot/api-client";

const __dirname = dirname(fileURLToPath(import.meta.url));
config({ path: resolve(__dirname, "../.env") });

const hubspot = new Client({ accessToken: process.env.HUBSPOT_SERVICE_KEY! });

const PROPERTIES = [
  {
    name: "contact_type",
    label: "Contact Type",
    type: "enumeration",
    fieldType: "select",
    groupName: "companyinformation",
    options: [
      { label: "Customer", value: "customer" },
      { label: "Partner - Blog", value: "partner_blog" },
      { label: "Partner - Directory", value: "partner_directory" },
      { label: "Partner - Media", value: "partner_media" },
      { label: "Partner - Local Business", value: "partner_local_biz" },
    ],
  },
  {
    name: "seo_relevance_score",
    label: "SEO Relevance Score",
    type: "number",
    fieldType: "number",
    groupName: "companyinformation",
    description: "1-5 score of SEO relevance to El Dato",
  },
  {
    name: "seo_link_type",
    label: "SEO Link Type",
    type: "enumeration",
    fieldType: "select",
    groupName: "companyinformation",
    options: [
      { label: "Guest Post", value: "guest_post" },
      { label: "Citation", value: "citation" },
      { label: "Directory Listing", value: "directory_listing" },
      { label: "Co-Marketing", value: "co_marketing" },
      { label: "Editorial Mention", value: "editorial_mention" },
    ],
  },
  {
    name: "seo_outreach_status",
    label: "SEO Outreach Status",
    type: "enumeration",
    fieldType: "select",
    groupName: "companyinformation",
    options: [
      { label: "Not Contacted", value: "not_contacted" },
      { label: "Contacted", value: "contacted" },
      { label: "Responded", value: "responded" },
      { label: "Link Acquired", value: "link_acquired" },
      { label: "Rejected", value: "rejected" },
    ],
  },
  {
    name: "seo_target_page",
    label: "SEO Target Page",
    type: "string",
    fieldType: "text",
    groupName: "companyinformation",
    description: "Which El Dato page this backlink supports",
  },
  {
    name: "seo_anchor_theme",
    label: "SEO Anchor Theme",
    type: "string",
    fieldType: "text",
    groupName: "companyinformation",
    description: "Suggested anchor text theme",
  },
  {
    name: "seo_domain_authority",
    label: "SEO Domain Authority",
    type: "number",
    fieldType: "number",
    groupName: "companyinformation",
    description: "Domain authority score if known",
  },
  {
    name: "outreach_status",
    label: "Outreach Status",
    type: "enumeration",
    fieldType: "select",
    groupName: "companyinformation",
    options: [
      { label: "Not Reached", value: "Not Reached" },
      { label: "Reached", value: "Reached" },
      { label: "Reached questioned local deal", value: "Reached questioned local deal" },
      { label: "Reached- No Response", value: "Reached- No Response" },
      { label: "Internal Review", value: "Internal Review" },
      { label: "Will Add Deal", value: "Will Add Deal" },
      { label: "Business Created", value: "Business Created" },
      { label: "Deal Created", value: "Deal Created" },
      { label: "Not Interested", value: "Not Interested" },
      { label: "Unsubscribed", value: "Unsubscribed" },
    ],
  },
  {
    name: "outreach_channels_used",
    label: "Outreach Channels Used",
    type: "enumeration",
    fieldType: "checkbox",
    groupName: "companyinformation",
    options: [
      { label: "Email", value: "email" },
      { label: "LinkedIn", value: "linkedin" },
      { label: "Instagram", value: "instagram" },
      { label: "WhatsApp", value: "whatsapp" },
    ],
  },
  {
    name: "outreach_campaign_id",
    label: "Outreach Campaign ID",
    type: "string",
    fieldType: "text",
    groupName: "companyinformation",
    description: "Links to campaign in outreach DB",
  },
  {
    name: "lead_magnet_delivered",
    label: "Lead Magnet Delivered",
    type: "string",
    fieldType: "text",
    groupName: "companyinformation",
    description: "Comma-appended free-form lead magnet history",
  },
];

async function main() {
  for (const prop of PROPERTIES) {
    try {
      await hubspot.crm.properties.coreApi.create("companies", prop as any);
      console.log(`Created: ${prop.name}`);
    } catch (error: any) {
      if (error.body?.message?.includes("already exists")) {
        // For enum properties, update to ensure all options are present
        if (prop.type === "enumeration" && prop.options) {
          try {
            await hubspot.crm.properties.coreApi.update("companies", prop.name, {
              label: prop.label,
              type: prop.type,
              fieldType: prop.fieldType,
              options: prop.options,
            } as any);
            console.log(`Updated options: ${prop.name}`);
          } catch (updateError: any) {
            console.error(
              `Failed to update ${prop.name}:`,
              updateError.body?.message ?? updateError.message
            );
          }
        } else {
          console.log(`Already exists: ${prop.name}`);
        }
      } else {
        console.error(
          `Failed to create ${prop.name}:`,
          error.body?.message ?? error.message
        );
      }
    }
  }
  console.log("\nDone.");
}

main();
