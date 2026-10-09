export type FilterGroup = {
  filters: Array<{ propertyName: string; operator: string; value: string }>;
};

export const PARTNER_TYPES = [
  "partner_blog",
  "partner_directory",
  "partner_media",
  "partner_local_biz",
] as const;

export type PartnerType = (typeof PARTNER_TYPES)[number];

export function isPartnerType(value: string): value is PartnerType {
  return PARTNER_TYPES.includes(value as PartnerType);
}
