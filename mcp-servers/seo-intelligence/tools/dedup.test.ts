import { describe, it, expect, vi, beforeEach } from "vitest";
import { normalize, exactMatch } from "./dedup.js";

describe("normalize", () => {
  it("lowercases", () => {
    expect(normalize("Café TULUM")).toContain("cafe");
  });
  it("strips accents", () => {
    expect(normalize("Café")).toBe("cafe");
    expect(normalize("Cancún")).toBe("cancun");
    expect(normalize("Peña")).toBe("pena");
  });
  it("strips punctuation", () => {
    expect(normalize("L'Italiano")).toBe("litaliano");
    expect(normalize("Maison Oh Lala!")).toBe("maison oh lala");
  });
  it("collapses whitespace", () => {
    expect(normalize("  Rio  Secreto  ")).toBe("rio secreto");
  });
});

describe("exactMatch", () => {
  const existing = [
    { id: "1", name: "Café Tulum" },
    { id: "2", name: "Rio Secreto" },
    { id: "3", name: "L'Italiano" },
  ];

  it("finds accent variant", () => {
    const result = exactMatch("Cafe Tulum", existing);
    expect(result).toHaveLength(1);
    expect(result[0].id).toBe("1");
    expect(result[0].reason).toMatch(/accent/);
  });
  it("finds punctuation variant", () => {
    const result = exactMatch("LItaliano", existing);
    expect(result).toHaveLength(1);
    expect(result[0].id).toBe("3");
  });
  it("finds case variant", () => {
    const result = exactMatch("rio secreto", existing);
    expect(result).toHaveLength(1);
    expect(result[0].id).toBe("2");
  });
  it("returns empty for no match", () => {
    expect(exactMatch("Azulik", existing)).toHaveLength(0);
  });
  it("returns empty when name normalizes to empty string", () => {
    expect(exactMatch("!!!", existing)).toHaveLength(0);
    expect(exactMatch("   ", existing)).toHaveLength(0);
  });
});

// --- Network function tests (mocked) ---

const mockDoSearch = vi.fn();

vi.mock("@hubspot/api-client", () => ({
  Client: vi.fn().mockImplementation(function () {
    return {
      crm: {
        companies: {
          searchApi: { doSearch: mockDoSearch },
        },
      },
    };
  }),
}));

const mockAnthropicCreate = vi.fn();

vi.mock("@anthropic-ai/sdk", () => ({
  default: vi.fn().mockImplementation(function () {
    return {
      messages: { create: mockAnthropicCreate },
    };
  }),
}));

// Re-import after mocks are declared
const { fetchNames, fuzzyMatch } = await import("./dedup.js");

beforeEach(() => {
  vi.clearAllMocks();
  process.env.HUBSPOT_SERVICE_KEY = "test-key";
  process.env.ANTHROPIC_API_KEY = "test-key";
});

describe("fetchNames", () => {
  it("fetches customer names with correct filter", async () => {
    mockDoSearch.mockResolvedValue({ total: 1, results: [{ id: "1", properties: { name: "Azulik" } }], paging: undefined });
    const result = await fetchNames("customer");
    expect(result).toEqual([{ id: "1", name: "Azulik" }]);
    expect(mockDoSearch).toHaveBeenCalledWith(
      expect.objectContaining({
        filterGroups: expect.arrayContaining([
          expect.objectContaining({
            filters: expect.arrayContaining([
              expect.objectContaining({ propertyName: "contact_type", operator: "EQ", value: "customer" }),
            ]),
          }),
        ]),
      })
    );
  });

  it("skips companies with missing name", async () => {
    mockDoSearch.mockResolvedValue({ total: 1, results: [{ id: "1", properties: { name: null } }], paging: undefined });
    const result = await fetchNames("customer");
    expect(result).toHaveLength(0);
  });

  it("fetches 4 filter groups for partner track (4 partner types)", async () => {
    mockDoSearch.mockResolvedValue({ total: 0, results: [], paging: undefined });
    await fetchNames("partner");
    const call = mockDoSearch.mock.calls[0][0];
    expect(call.filterGroups).toHaveLength(4);
  });

  it("fetches 5 filter groups for both track (1 customer + 4 partner types)", async () => {
    mockDoSearch.mockResolvedValue({ total: 0, results: [], paging: undefined });
    await fetchNames("both");
    const call = mockDoSearch.mock.calls[0][0];
    expect(call.filterGroups).toHaveLength(5);
  });

  it("throws on HubSpot API error to prevent partial-corpus false negatives", async () => {
    mockDoSearch.mockRejectedValue(new Error("429 Too Many Requests"));
    await expect(fetchNames("customer")).rejects.toThrow("429 Too Many Requests");
  });

  it("combines results across pages when paging cursor is returned", async () => {
    mockDoSearch
      .mockResolvedValueOnce({
        total: 2,
        results: [{ id: "1", properties: { name: "Azulik" } }],
        paging: { next: { after: "cursor2" } },
      })
      .mockResolvedValueOnce({
        total: 2,
        results: [{ id: "2", properties: { name: "Tulum Beach Club" } }],
        paging: undefined,
      });
    const result = await fetchNames("customer");
    expect(result).toHaveLength(2);
    expect(result[0]).toEqual({ id: "1", name: "Azulik" });
    expect(result[1]).toEqual({ id: "2", name: "Tulum Beach Club" });
    expect(mockDoSearch).toHaveBeenCalledTimes(2);
  });
});

describe("fuzzyMatch", () => {
  it("returns empty array when existing list is empty", async () => {
    const result = await fuzzyMatch("Azulik", []);
    expect(result).toHaveLength(0);
    expect(mockAnthropicCreate).not.toHaveBeenCalled();
  });

  it("calls Haiku and maps response back to IDs", async () => {
    mockAnthropicCreate.mockResolvedValue({
      content: [{ type: "text", text: '[{"name":"Azulik Tulum","reason":"same venue, missing city suffix"}]' }],
    });
    const existing = [{ id: "abc", name: "Azulik Tulum" }];
    const result = await fuzzyMatch("Azulik", existing);
    expect(result).toHaveLength(1);
    expect(result[0].id).toBe("abc");
    expect(result[0].reason).toMatch(/Haiku/);
  });

  it("returns empty array if Haiku returns malformed JSON", async () => {
    mockAnthropicCreate.mockResolvedValue({
      content: [{ type: "text", text: "not json at all" }],
    });
    const existing = [{ id: "1", name: "Azulik" }];
    const result = await fuzzyMatch("Azulik Tulum", existing);
    expect(result).toHaveLength(0);
  });

  it("filters out names Haiku returns that don't exist in the list", async () => {
    mockAnthropicCreate.mockResolvedValue({
      content: [{ type: "text", text: '[{"name":"Hallucinated Name","reason":"test"}]' }],
    });
    const existing = [{ id: "1", name: "Azulik" }];
    const result = await fuzzyMatch("Azulik Tulum", existing);
    expect(result).toHaveLength(0);
  });

  it("returns empty array when Anthropic call throws (network error)", async () => {
    mockAnthropicCreate.mockRejectedValue(new Error("network failure"));
    const existing = [{ id: "1", name: "Azulik" }];
    const result = await fuzzyMatch("Azulik Tulum", existing);
    expect(result).toHaveLength(0);
  });

  it("returns empty array when Haiku returns a non-array JSON value", async () => {
    mockAnthropicCreate.mockResolvedValue({
      content: [{ type: "text", text: '{"name":"Azulik","reason":"test"}' }],
    });
    const existing = [{ id: "1", name: "Azulik" }];
    const result = await fuzzyMatch("Azulik Tulum", existing);
    expect(result).toHaveLength(0);
  });
});
