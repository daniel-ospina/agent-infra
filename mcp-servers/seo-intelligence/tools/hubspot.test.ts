import { describe, it, expect, vi, beforeEach } from "vitest";

const mockCreate = vi.fn();
const mockGetById = vi.fn();
const mockUpdate = vi.fn();
const mockDoSearch = vi.fn();
const mockNoteCreate = vi.fn();
const mockAssocCreate = vi.fn();

vi.mock("@hubspot/api-client", () => ({
  Client: vi.fn().mockImplementation(function () {
    return {
      crm: {
        companies: {
          basicApi: { create: mockCreate, getById: mockGetById, update: mockUpdate },
          searchApi: { doSearch: mockDoSearch },
        },
        objects: { notes: { basicApi: { create: mockNoteCreate } } },
        associations: { v4: { basicApi: { createDefault: mockAssocCreate } } },
      },
    };
  }),
}));

const mockFetchNames = vi.fn();
const mockExactMatch = vi.fn();
const mockFuzzyMatch = vi.fn();

vi.mock("./dedup.js", () => ({
  fetchNames: mockFetchNames,
  exactMatch: mockExactMatch,
  fuzzyMatch: mockFuzzyMatch,
}));

const { createPartner, updatePartner, listPartners, logOutreach } = await import("./hubspot.js");

beforeEach(() => {
  vi.clearAllMocks();
  process.env.HUBSPOT_SERVICE_KEY = "test-key";
  mockFetchNames.mockResolvedValue([]);
  mockExactMatch.mockReturnValue([]);
  mockFuzzyMatch.mockResolvedValue([]);
});

describe("createPartner dedup", () => {
  it("returns blocked when tier1 finds exact match", async () => {
    mockFetchNames.mockResolvedValue([{ id: "p1", name: "Playa Blog" }]);
    mockExactMatch.mockReturnValue([{ id: "p1", name: "Playa Blog", reason: "normalized name match" }]);
    const result = await createPartner({ name: "Playa Blog", contact_type: "partner_blog" });
    expect(result.status).toBe("blocked");
    if (result.status === "blocked") expect(result.matches[0].id).toBe("p1");
    expect(mockCreate).not.toHaveBeenCalled();
  });

  it("returns warning when tier2 finds fuzzy match", async () => {
    mockFetchNames.mockResolvedValue([{ id: "p2", name: "Cancun Food Blog" }]);
    mockExactMatch.mockReturnValue([]);
    mockFuzzyMatch.mockResolvedValue([{ id: "p2", name: "Cancun Food Blog", reason: "Haiku: likely same blog" }]);
    const result = await createPartner({ name: "Cancun Foood Blog", contact_type: "partner_blog" });
    expect(result.status).toBe("warning");
    expect(mockCreate).not.toHaveBeenCalled();
  });

  it("creates when force:true bypasses tier2 warning", async () => {
    mockFetchNames.mockResolvedValue([{ id: "p2", name: "Cancun Food Blog" }]);
    mockExactMatch.mockReturnValue([]);
    mockCreate.mockResolvedValue({ id: "new-p", properties: {} });
    const result = await createPartner({ name: "Cancun Foood Blog", contact_type: "partner_blog", force: true });
    expect(result.status).toBe("created");
    expect(mockFuzzyMatch).not.toHaveBeenCalled();
    expect(mockCreate).toHaveBeenCalled();
  });

  it("still blocks even with force:true when tier1 matches", async () => {
    mockFetchNames.mockResolvedValue([{ id: "p1", name: "Playa Blog" }]);
    mockExactMatch.mockReturnValue([{ id: "p1", name: "Playa Blog", reason: "normalized name match" }]);
    const result = await createPartner({ name: "Playa Blog", contact_type: "partner_blog", force: true });
    expect(result.status).toBe("blocked");
    expect(mockCreate).not.toHaveBeenCalled();
  });

  it("returns created with status field on success", async () => {
    mockCreate.mockResolvedValue({ id: "new-p", properties: { name: "My Blog" } });
    const result = await createPartner({ name: "My Blog", contact_type: "partner_blog" });
    expect(result.status).toBe("created");
    if (result.status === "created") expect(result.id).toBe("new-p");
    expect(mockCreate).toHaveBeenCalled();
  });

  it("still rejects invalid contact_type", async () => {
    await expect(
      createPartner({ name: "Bad", contact_type: "customer" as any })
    ).rejects.toThrow("Invalid contact_type");
  });
});

describe("updatePartner", () => {
  it("refuses to update a non-partner company", async () => {
    mockGetById.mockResolvedValue({ properties: { contact_type: "customer" } });
    await expect(updatePartner("123", { seo_outreach_status: "contacted" })).rejects.toThrow("not a partner");
  });

  it("refuses to update a company with unset contact_type", async () => {
    mockGetById.mockResolvedValue({ properties: { contact_type: null } });
    await expect(updatePartner("123", { seo_outreach_status: "contacted" })).rejects.toThrow("not a partner");
  });

  it("updates partner successfully and strips contact_type from payload", async () => {
    mockGetById.mockResolvedValue({ properties: { contact_type: "partner_blog" } });
    mockUpdate.mockResolvedValue({ id: "123", properties: {} });
    const result = await updatePartner("123", { seo_outreach_status: "contacted", contact_type: "customer" });
    expect(result.id).toBe("123");
    expect(mockUpdate).toHaveBeenCalledWith("123", {
      properties: { seo_outreach_status: "contacted" },
    });
  });
});

describe("listPartners", () => {
  it("uses EQ per partner type (4 filterGroups) when no contact_type filter provided", async () => {
    mockDoSearch.mockResolvedValue({ total: 0, results: [], paging: undefined });
    await listPartners();
    const call = mockDoSearch.mock.calls[0][0];
    expect(call.filterGroups).toHaveLength(4);
    const types = call.filterGroups.map((fg: any) =>
      fg.filters.find((f: any) => f.propertyName === "contact_type")?.value
    );
    expect(types).toEqual(
      expect.arrayContaining(["partner_blog", "partner_directory", "partner_media", "partner_local_biz"])
    );
  });

  it("adds outreach_status filter when provided", async () => {
    mockDoSearch.mockResolvedValue({ total: 0, results: [], paging: undefined });
    await listPartners({ outreach_status: "contacted" });
    expect(mockDoSearch).toHaveBeenCalledWith(
      expect.objectContaining({
        filterGroups: expect.arrayContaining([
          expect.objectContaining({
            filters: expect.arrayContaining([
              expect.objectContaining({ propertyName: "seo_outreach_status", value: "contacted" }),
            ]),
          }),
        ]),
      })
    );
  });

  it("paginates across multiple pages and forwards cursor", async () => {
    mockDoSearch
      .mockResolvedValueOnce({
        total: 2,
        results: [{ id: "p1", properties: { name: "Blog A" } }],
        paging: { next: { after: "cursor2" } },
      })
      .mockResolvedValueOnce({
        total: 2,
        results: [{ id: "p2", properties: { name: "Blog B" } }],
        paging: undefined,
      });
    const result = await listPartners();
    expect(result.total).toBe(2);
    expect(result.partners).toHaveLength(2);
    expect(mockDoSearch).toHaveBeenCalledTimes(2);
    expect(mockDoSearch.mock.calls[1][0]).toMatchObject({ after: "cursor2" });
  });

  it("produces 1 filterGroup when contact_type filter is specified", async () => {
    mockDoSearch.mockResolvedValue({ total: 0, results: [], paging: undefined });
    await listPartners({ contact_type: "partner_blog" });
    const call = mockDoSearch.mock.calls[0][0];
    expect(call.filterGroups).toHaveLength(1);
    expect(call.filterGroups[0].filters).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ propertyName: "contact_type", operator: "EQ", value: "partner_blog" }),
      ])
    );
  });

  it("throws for invalid contact_type in listPartners", async () => {
    await expect(listPartners({ contact_type: "customer" })).rejects.toThrow("Invalid contact_type");
  });
});

describe("logOutreach", () => {
  it("refuses to log on a non-partner company", async () => {
    mockGetById.mockResolvedValue({ properties: { contact_type: "customer" } });
    await expect(logOutreach("123", "hello")).rejects.toThrow("not a partner");
  });

  it("creates note and associates it with the partner company", async () => {
    mockGetById.mockResolvedValue({ properties: { contact_type: "partner_blog" } });
    mockNoteCreate.mockResolvedValue({ id: "note-789" });
    mockAssocCreate.mockResolvedValue({});
    const result = await logOutreach("123", "sent pitch email");
    expect(result.noteId).toBe("note-789");
    expect(mockNoteCreate).toHaveBeenCalledWith(expect.objectContaining({ associations: [] }));
    expect(mockAssocCreate).toHaveBeenCalledWith("notes", "note-789", "companies", "123");
  });
});
