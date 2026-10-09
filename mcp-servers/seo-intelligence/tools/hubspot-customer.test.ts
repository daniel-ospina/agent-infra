import { describe, it, expect, vi, beforeEach } from "vitest";

// Mock must be declared before imports that use the module
const mockCreate = vi.fn();
const mockGetById = vi.fn();
const mockUpdate = vi.fn();
const mockDoSearch = vi.fn();
const mockNoteCreate = vi.fn();
const mockTaskCreate = vi.fn();
const mockAssocCreate = vi.fn();

vi.mock("@hubspot/api-client", () => ({
  Client: vi.fn().mockImplementation(function () {
    return {
      crm: {
        companies: {
          basicApi: { create: mockCreate, getById: mockGetById, update: mockUpdate },
          searchApi: { doSearch: mockDoSearch },
        },
        objects: {
          notes: { basicApi: { create: mockNoteCreate } },
          tasks: { basicApi: { create: mockTaskCreate } },
        },
        associations: {
          v4: { basicApi: { createDefault: mockAssocCreate } },
        },
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

// Import after mock
const { createCustomer, updateCustomer, listCustomers, logCustomerNote, createTask } =
  await import("./hubspot-customer.js");

beforeEach(() => {
  vi.clearAllMocks();
  process.env.HUBSPOT_SERVICE_KEY = "test-key";
  mockFetchNames.mockResolvedValue([]);
  mockExactMatch.mockReturnValue([]);
  mockFuzzyMatch.mockResolvedValue([]);
});

describe("createCustomer", () => {
  it("always sets contact_type = customer", async () => {
    mockCreate.mockResolvedValue({ id: "123", properties: {} });
    await createCustomer({ name: "Test Biz" });
    expect(mockCreate).toHaveBeenCalledWith({
      properties: expect.objectContaining({ contact_type: "customer" }),
    });
  });

  it("defaults outreach_status to Not Reached", async () => {
    mockCreate.mockResolvedValue({ id: "123", properties: {} });
    await createCustomer({ name: "Test Biz" });
    expect(mockCreate).toHaveBeenCalledWith({
      properties: expect.objectContaining({ outreach_status: "Not Reached" }),
    });
  });

  it("accepts a custom outreach_status", async () => {
    mockCreate.mockResolvedValue({ id: "123", properties: {} });
    await createCustomer({ name: "Test Biz", outreach_status: "Deal Created" });
    expect(mockCreate).toHaveBeenCalledWith({
      properties: expect.objectContaining({ outreach_status: "Deal Created" }),
    });
  });

  it("returns blocked when tier1 finds exact match", async () => {
    mockFetchNames.mockResolvedValue([{ id: "existing-1", name: "Test Biz" }]);
    mockExactMatch.mockReturnValue([{ id: "existing-1", name: "Test Biz", reason: "normalized name match" }]);
    const result = await createCustomer({ name: "Test Biz" });
    expect(result.status).toBe("blocked");
    if (result.status === "blocked") expect(result.matches[0].id).toBe("existing-1");
    expect(mockCreate).not.toHaveBeenCalled();
  });

  it("returns warning when tier2 finds fuzzy match", async () => {
    mockFetchNames.mockResolvedValue([{ id: "existing-2", name: "Azulik Tulum" }]);
    mockExactMatch.mockReturnValue([]);
    mockFuzzyMatch.mockResolvedValue([{ id: "existing-2", name: "Azulik Tulum", reason: "Haiku: likely same venue" }]);
    const result = await createCustomer({ name: "Azulik" });
    expect(result.status).toBe("warning");
    expect(mockCreate).not.toHaveBeenCalled();
  });

  it("creates when force:true bypasses tier2 warning", async () => {
    mockFetchNames.mockResolvedValue([{ id: "existing-2", name: "Azulik Tulum" }]);
    mockExactMatch.mockReturnValue([]);
    mockCreate.mockResolvedValue({ id: "new-1", properties: {} });
    const result = await createCustomer({ name: "Azulik", force: true });
    expect(result.status).toBe("created");
    expect(mockFuzzyMatch).not.toHaveBeenCalled();
    expect(mockCreate).toHaveBeenCalled();
  });

  it("still blocks even with force:true if tier1 matches", async () => {
    mockFetchNames.mockResolvedValue([{ id: "existing-1", name: "Test Biz" }]);
    mockExactMatch.mockReturnValue([{ id: "existing-1", name: "Test Biz", reason: "normalized name match" }]);
    const result = await createCustomer({ name: "Test Biz", force: true });
    expect(result.status).toBe("blocked");
    expect(mockCreate).not.toHaveBeenCalled();
  });

  it("returns created with status field on success", async () => {
    mockFetchNames.mockResolvedValue([]);
    mockExactMatch.mockReturnValue([]);
    mockFuzzyMatch.mockResolvedValue([]);
    mockCreate.mockResolvedValue({ id: "new-1", properties: { name: "Test Biz" } });
    const result = await createCustomer({ name: "Test Biz" });
    expect(result.status).toBe("created");
    if (result.status === "created") expect(result.id).toBe("new-1");
  });
});

describe("updateCustomer", () => {
  it("refuses to update non-customer companies", async () => {
    mockGetById.mockResolvedValue({ properties: { contact_type: "partner_local_biz" } });
    await expect(
      updateCustomer("123", { outreach_status: "Reached" })
    ).rejects.toThrow("not a customer");
  });

  it("refuses to update companies with unset contact_type", async () => {
    mockGetById.mockResolvedValue({ properties: { contact_type: null } });
    await expect(
      updateCustomer("123", { outreach_status: "Reached" })
    ).rejects.toThrow("not a customer");
  });

  it("updates customer companies successfully and strips contact_type", async () => {
    mockGetById.mockResolvedValue({ properties: { contact_type: "customer" } });
    mockUpdate.mockResolvedValue({ id: "123", properties: {} });
    const result = await updateCustomer("123", { outreach_status: "Reached", contact_type: "partner_blog" });
    expect(result.id).toBe("123");
    expect(mockUpdate).toHaveBeenCalledWith("123", {
      properties: { outreach_status: "Reached" }, // contact_type stripped
    });
  });
});

describe("logCustomerNote", () => {
  it("refuses to log on non-customer companies", async () => {
    mockGetById.mockResolvedValue({ properties: { contact_type: "partner_blog" } });
    await expect(logCustomerNote("123", "a note")).rejects.toThrow("not a customer");
  });

  it("creates note and associates it with the customer company", async () => {
    mockGetById.mockResolvedValue({ properties: { contact_type: "customer" } });
    mockNoteCreate.mockResolvedValue({ id: "note-456" });
    mockAssocCreate.mockResolvedValue({});
    const result = await logCustomerNote("123", "follow up call");
    expect(result.noteId).toBe("note-456");
    expect(mockNoteCreate).toHaveBeenCalledWith(expect.objectContaining({ associations: [] }));
    expect(mockAssocCreate).toHaveBeenCalledWith("notes", "note-456", "companies", "123");
  });
});

describe("listCustomers", () => {
  it("always filters by contact_type = customer", async () => {
    mockDoSearch.mockResolvedValue({ total: 0, results: [] });
    await listCustomers();
    expect(mockDoSearch).toHaveBeenCalledWith(
      expect.objectContaining({
        filterGroups: expect.arrayContaining([
          expect.objectContaining({
            filters: expect.arrayContaining([
              expect.objectContaining({ propertyName: "contact_type", value: "customer" }),
            ]),
          }),
        ]),
      })
    );
  });

  it("adds outreach_status filter when provided", async () => {
    mockDoSearch.mockResolvedValue({ total: 0, results: [] });
    await listCustomers({ outreach_status: "Reached" });
    expect(mockDoSearch).toHaveBeenCalledWith(
      expect.objectContaining({
        filterGroups: expect.arrayContaining([
          expect.objectContaining({
            filters: expect.arrayContaining([
              expect.objectContaining({ propertyName: "outreach_status", value: "Reached" }),
            ]),
          }),
        ]),
      })
    );
  });

  it("adds city filter when provided", async () => {
    mockDoSearch.mockResolvedValue({ total: 0, results: [] });
    await listCustomers({ city: "Playa del Carmen" });
    expect(mockDoSearch).toHaveBeenCalledWith(
      expect.objectContaining({
        filterGroups: expect.arrayContaining([
          expect.objectContaining({
            filters: expect.arrayContaining([
              expect.objectContaining({ propertyName: "city", value: "Playa del Carmen" }),
            ]),
          }),
        ]),
      })
    );
  });

  it("paginates across multiple pages", async () => {
    mockDoSearch
      .mockResolvedValueOnce({
        total: 2,
        results: [{ id: "c1", properties: { name: "Biz A" } }],
        paging: { next: { after: "cursor2" } },
      })
      .mockResolvedValueOnce({
        total: 2,
        results: [{ id: "c2", properties: { name: "Biz B" } }],
        paging: undefined,
      });
    const result = await listCustomers();
    expect(result.total).toBe(2);
    expect(result.customers).toHaveLength(2);
    expect(mockDoSearch).toHaveBeenCalledTimes(2);
    expect(mockDoSearch.mock.calls[1][0]).toMatchObject({ after: "cursor2" });
  });
});

describe("createTask", () => {
  it("creates a task linked to the company", async () => {
    mockTaskCreate.mockResolvedValue({ id: "task-789" });
    const result = await createTask("company-1", "Follow up", "Call them", "2026-02-25");
    expect(result.taskId).toBe("task-789");
    expect(result.companyId).toBe("company-1");
    expect(result.subject).toBe("Follow up");
    expect(mockTaskCreate).toHaveBeenCalledWith(
      expect.objectContaining({
        properties: expect.objectContaining({
          hs_task_subject: "Follow up",
          hs_task_body: "Call them",
          hs_task_status: "NOT_STARTED",
        }),
        associations: expect.arrayContaining([
          expect.objectContaining({
            to: { id: "company-1" },
          }),
        ]),
      })
    );
  });

  it("throws a descriptive error for an invalid dueDate", async () => {
    await expect(
      createTask("company-1", "Follow up", "Call them", "not-a-date")
    ).rejects.toThrow('Invalid dueDate: "not-a-date". Expected YYYY-MM-DD.');
  });

  it("throws for calendar roll-over dates like 2026-02-30", async () => {
    await expect(
      createTask("company-1", "Follow up", "Call them", "2026-02-30")
    ).rejects.toThrow('Invalid dueDate: "2026-02-30" is not a real calendar date.');
  });
});
