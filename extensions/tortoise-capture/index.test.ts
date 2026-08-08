// tortoise-capture.test.ts — behavioral smoke tests (#7423)
// Verifies conversation extraction and markdown generation (pure functions).
// Integration surface (spawn) verified via manual ingest smoke test.
// #312 delta 2: hosted-cloud capture helpers are imported from the real module
// (vitest resolves TS natively now) and exercised with a mocked global fetch.

import { describe, test, expect, vi, beforeEach, afterEach } from "vitest";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  cloudConfig,
  isCloudEnabled,
  writeCloudFallback,
  captureToHosted,
} from "./index";

// Replicate the pure functions inline (cannot import .ts extension in vitest with jiti)
function extractText(content: unknown): string | null {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    const texts = (content as Array<{ type: string; text?: string }>)
      .filter((b) => b.type === "text" && typeof b.text === "string")
      .map((b) => b.text!);
    return texts.length > 0 ? texts.join("\n") : null;
  }
  return null;
}

function extractConversation(
  messages: Array<{ role: string; content?: unknown }>,
): Array<{ role: "user" | "assistant"; content: string }> {
  const result: Array<{ role: "user" | "assistant"; content: string }> = [];
  for (const msg of messages) {
    if (msg.role !== "user" && msg.role !== "assistant") continue;
    const text = extractText(msg.content);
    if (!text) continue;
    result.push({ role: msg.role as "user" | "assistant", content: text });
  }
  return result;
}

function buildMarkdown(
  conversation: Array<{ role: "user" | "assistant"; content: string }>,
  meta: { title: string; date: string; sessionId: string },
  extra: { topics?: string[]; summary?: string; sourcePath?: string } = {},
): string {
  const topics = extra.topics && extra.topics.length ? extra.topics : [];
  const summary = extra.summary || "";
  const sourcePath = extra.sourcePath || "";
  const lines: string[] = [
    "---",
    `title: "${meta.title}"`,
    `sessionId: "${meta.sessionId}"`,
    `type: "conversation"`,
    `documentKind: "transcript"`,
    `documentKnowledgeDomain: "engineering"`,
    `doc_status: "captured"`,
    `created: "${meta.date}"`,
    `roles: "${[...new Set(conversation.map((m) => m.role))].join(",")}"`,
    `message_count: "${conversation.length}"`,
    `topics: "${topics.join(", ")}"`,
    // #167 P1 fix: literal block scalar preserves bullet newlines (YAML 1.2 §7.3.1).
    // `|-` strips the trailing newline so round-trip is byte-exact.
    ...(summary ? [`summary: |-`, ...summary.split("\n").map((l) => `  ${l}`)] : [`summary: ""`]),
    `sourcePath: "${sourcePath.replace(/"/g, '\"')}"`,
    "---",
    "",
  ];

  for (const msg of conversation) {
    const role = msg.role === "assistant" ? "Assistant" : "User";
    lines.push(`## ${role}`);
    lines.push("");
    lines.push(msg.content);
    lines.push("");
  }

  return lines.join("\n");
}

function buildAppendBlock(
  messages: Array<{ role: "user" | "assistant"; content: string }>,
): string {
  const lines: string[] = [];
  for (const msg of messages) {
    const role = msg.role === "assistant" ? "Assistant" : "User";
    lines.push(`## ${role}`);
    lines.push("");
    lines.push(msg.content);
    lines.push("");
  }
  return lines.join("\n");
}

function countMessageBlocks(content: string): number {
  const matches = content.match(/^## (User|Assistant)$/gm);
  return matches ? matches.length : 0;
}

describe("extractConversation", () => {
  test("extracts user and assistant messages", () => {
    const messages = [
      { role: "user", content: "Hello" },
      { role: "assistant", content: "Hi there" },
    ];
    const result = extractConversation(messages);
    expect(result).toHaveLength(2);
    expect(result[0]).toEqual({ role: "user", content: "Hello" });
    expect(result[1]).toEqual({ role: "assistant", content: "Hi there" });
  });

  test("skips non-user/assistant roles", () => {
    const messages = [
      { role: "system", content: "sys msg" },
      { role: "user", content: "Hello" },
      { role: "tool", content: "result" },
    ];
    const result = extractConversation(messages);
    expect(result).toHaveLength(1);
    expect(result[0].role).toBe("user");
  });

  test("handles array content blocks", () => {
    const messages = [
      {
        role: "assistant",
        content: [
          { type: "text", text: "Part one." },
          { type: "text", text: "Part two." },
        ],
      },
    ];
    const result = extractConversation(messages);
    expect(result).toHaveLength(1);
    expect(result[0].content).toBe("Part one.\nPart two.");
  });

  test("skips messages with empty content", () => {
    const messages = [
      { role: "user", content: "" },
      { role: "assistant", content: "Valid" },
    ];
    const result = extractConversation(messages);
    expect(result).toHaveLength(1);
  });
});

describe("buildAppendBlock", () => {
  test("generates message blocks without frontmatter", () => {
    const messages = [
      { role: "user" as const, content: "Hello" },
      { role: "assistant" as const, content: "Hi there" },
    ];
    const result = buildAppendBlock(messages);

    // Should contain message blocks
    expect(result).toContain("## User");
    expect(result).toContain("Hello");
    expect(result).toContain("## Assistant");
    expect(result).toContain("Hi there");

    // Should NOT contain YAML frontmatter
    expect(result).not.toContain("---");
    expect(result).not.toContain('title:');
    expect(result).not.toContain('sessionId:');
    expect(result).not.toContain('type:');
    expect(result).not.toContain('message_count:');
  });

  test("handles empty array", () => {
    const result = buildAppendBlock([]);
    expect(result).toBe("");
  });

  test("handles single message", () => {
    const messages = [
      { role: "user" as const, content: "Solo message" },
    ];
    const result = buildAppendBlock(messages);
    expect(result).toContain("## User");
    expect(result).toContain("Solo message");
    expect(result).not.toContain("## Assistant");
  });

  test("multiple messages produce correct ordering", () => {
    const messages = [
      { role: "user" as const, content: "First" },
      { role: "assistant" as const, content: "Second" },
      { role: "user" as const, content: "Third" },
    ];
    const result = buildAppendBlock(messages);
    const lines = result.split("\n");
    const userIdx = lines.indexOf("## User");
    const assistantIdx = lines.indexOf("## Assistant");
    const secondUserIdx = lines.indexOf("## User", userIdx + 1);

    expect(userIdx).toBeGreaterThan(-1);
    expect(assistantIdx).toBeGreaterThan(userIdx);
    expect(secondUserIdx).toBeGreaterThan(assistantIdx);
  });
});

describe("countMessageBlocks", () => {
  test("counts User and Assistant blocks", () => {
    const content = "## User\n\nHello\n\n## Assistant\n\nWorld\n";
    expect(countMessageBlocks(content)).toBe(2);
  });

  test("returns 0 for empty content", () => {
    expect(countMessageBlocks("")).toBe(0);
  });

  test("ignores other headers", () => {
    const content = "## User\n\nHi\n\n## System\n\nSys\n\n## Assistant\n\nBye\n";
    expect(countMessageBlocks(content)).toBe(2);
  });

  test("returns 0 for content with no blocks", () => {
    const content = "Just some text\nwithout any headers\n";
    expect(countMessageBlocks(content)).toBe(0);
  });
});

describe("buildMarkdown", () => {
  test("generates markdown with frontmatter", () => {
    const conversation = [
      { role: "user", content: "What is Tortoise?" },
      { role: "assistant", content: "An epistemic graph system." },
    ];
    const result = buildMarkdown(conversation, {
      title: "Test",
      date: "2026-07-22",
      sessionId: "abc123",
    });

    expect(result).toContain('title: "Test"');
    expect(result).toContain('sessionId: "abc123"');
    expect(result).toContain('type: "conversation"');
    expect(result).toContain('documentKind: "transcript"');  // #125
    expect(result).toContain('doc_status: "captured"');
    expect(result).toContain('created: "2026-07-22"');
    expect(result).toContain('roles: "user,assistant"');
    expect(result).toContain('message_count: "2"');
    expect(result).toContain("## User");
    expect(result).toContain("What is Tortoise?");
    expect(result).toContain("## Assistant");
    expect(result).toContain("An epistemic graph system.");
  });

  test("deduplicates roles", () => {
    const conversation = [
      { role: "user", content: "a" },
      { role: "user", content: "b" },
    ];
    const result = buildMarkdown(conversation, {
      title: "T", date: "2026-01-01", sessionId: "x",
    });
    expect(result).toContain('roles: "user"');
  });
});

// #125 — topics/summary heuristics (replicated inline per file convention)

const STOPWORDS = new Set([
  "the", "and", "for", "with", "that", "this", "from", "was", "were",
  "have", "has", "had", "not", "but", "are", "you", "your", "our", "its",
]);

function deriveTopics(
  conversation: Array<{ role: "user" | "assistant"; content: string }>,
): string[] {
  const freq = new Map<string, number>();
  const pattern = /[A-Z][a-z]+(?:\s+[A-Z][a-z]+)*/g;
  for (const msg of conversation) {
    if (msg.role !== "user") continue;
    const matches = msg.content.match(pattern) || [];
    for (const phrase of matches) {
      const words = phrase.split(/\s+/);
      if (words.every((w) => w.length >= 3 && !STOPWORDS.has(w.toLowerCase()))) {
        freq.set(phrase, (freq.get(phrase) || 0) + 1);
      }
    }
  }
  return [...freq.entries()]
    .sort((a, b) => b[1] - a[1])
    .slice(0, 10)
    .map(([p]) => p);
}

// #167: story-arch bullet-point recap (replaces first-message truncation)
function deriveStoryArch(
  conversation: Array<{ role: "user" | "assistant"; content: string }>,
): string {
  const bullets: string[] = [];
  for (const msg of conversation) {
    if (msg.role !== "user") continue;
    const firstLine = msg.content.split("\n")[0].trim();
    if (firstLine.length < 5) continue;
    bullets.push(`- ${firstLine.slice(0, 120)}`);
    if (bullets.length >= 10) break;
  }
  return bullets.join("\n");
}

// backward-compat alias
function deriveSummary(
  conversation: Array<{ role: "user" | "assistant"; content: string }>,
): string {
  return deriveStoryArch(conversation);
}

describe("#125/#167 deriveTopics/deriveStoryArch", () => {
  test("deriveTopics extracts repeated Title Case phrases from user messages", () => {
    const conv = [
      { role: "user" as const, content: "We discussed Licensing and Enterprise and Licensing again" },
      { role: "assistant" as const, content: "Licensing has network copyleft" },
    ];
    const topics = deriveTopics(conv);
    expect(topics).toContain("Licensing");
    expect(topics).toContain("Enterprise");
  });

  test("deriveTopics filters stopwords and short words", () => {
    const conv = [
      { role: "user" as const, content: "The Agreement and the Agreement" },
    ];
    const topics = deriveTopics(conv);
    expect(topics).not.toContain("The");
    expect(topics).toContain("Agreement");
  });

  // #167: deriveStoryArch replaces first-message truncation
  test("deriveStoryArch produces multiple bullets for multi-turn", () => {
    const conv = [
      { role: "user" as const, content: "Implement issue #167" },
      { role: "assistant" as const, content: "ok" },
      { role: "user" as const, content: "Now add sourcePath to Document" },
      { role: "assistant" as const, content: "done" },
      { role: "user" as const, content: "Run the tests too" },
    ];
    const arch = deriveStoryArch(conv);
    const lines = arch.split("\n");
    expect(lines.length).toBe(3); // 3 user turns → 3 bullets
    expect(lines[0]).toContain("Implement issue #167");
    expect(lines[1]).toContain("Now add sourcePath to Document");
    expect(lines[2]).toContain("Run the tests too");
  });

  test("deriveStoryArch truncates long lines to ~120 chars", () => {
    const conv = [
      { role: "user" as const, content: "X".repeat(300) },
    ];
    const arch = deriveStoryArch(conv);
    expect(arch.length).toBeLessThanOrEqual(122); // "- " + 120 chars
    expect(arch.startsWith("- ")).toBe(true);
  });

  test("deriveStoryArch empty when no user message", () => {
    expect(deriveStoryArch([{ role: "assistant" as const, content: "hi" }])).toBe("");
  });

  test("deriveStoryArch filters very short bullets (<5 chars)", () => {
    const conv = [
      { role: "user" as const, content: "ok" },
      { role: "user" as const, content: "This is a proper message" },
    ];
    const arch = deriveStoryArch(conv);
    expect(arch).not.toContain("ok");
    expect(arch).toContain("This is a proper message");
  });

  test("deriveStoryArch caps at 10 bullets", () => {
    const conv = Array.from({ length: 15 }, (_, i) => ({
      role: "user" as const,
      content: `Message number ${i + 1}`,
    }));
    const arch = deriveStoryArch(conv);
    const lines = arch.split("\n");
    expect(lines.length).toBe(10);
  });

  test("buildMarkdown includes topics, summary, and sourcePath in frontmatter", () => {
    const conv = [
      { role: "user" as const, content: "Discussed Licensing" },
      { role: "assistant" as const, content: "ok" },
    ];
    const md = buildMarkdown(conv, {
      title: "T", date: "2026-08-05", sessionId: "s1",
    }, { topics: ["Licensing"], summary: "- Discussed Licensing", sourcePath: "/tmp/test.md" });
    expect(md).toMatch(/topics: "Licensing"/);
    // #167 P1: summary is a YAML literal block scalar (preserves bullets)
    expect(md).toMatch(/summary: \|/);
    expect(md).toMatch(/^  - Discussed Licensing$/m);
    expect(md).toMatch(/sourcePath: "\/tmp\/test\.md"/);
    expect(md).toMatch(/documentKind: "transcript"/);
  });

  test("story-arch summary round-trips through YAML parse preserving bullets (#167 P1)", () => {
    const conv = [
      { role: "user" as const, content: "Compare licensing options" },
      { role: "assistant" as const, content: "ok" },
      { role: "user" as const, content: "Decide AGPLv3" },
      { role: "assistant" as const, content: "done" },
    ];
    const arch = deriveStoryArch(conv);
    expect(arch).toContain("\n"); // multi-bullet story arch
    const md = buildMarkdown(conv, {
      title: "T", date: "2026-08-05", sessionId: "s1",
    }, { summary: arch });
    // Extract frontmatter between --- delimiters and parse with YAML
    const m = md.match(/^---\n([\s\S]*?)\n---/);
    expect(m).not.toBeNull();
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    const { createRequire } = require("module");
    // Test file is hardlinked into agent-infra; anchor require to eldato repo
    // where js-yaml is a dependency.
    const eldatoRequire = createRequire(require.resolve("/home/user/eldato/package.json"));
    const yaml = eldatoRequire("js-yaml");
    const parsed = yaml.load(m![1]) as Record<string, unknown>;
    expect(parsed.summary).toBe(arch); // bullets preserved exactly (no line-fold)
  });

  test("buildMarkdown includes empty sourcePath when not provided", () => {
    const conv = [
      { role: "user" as const, content: "hi" },
    ];
    const md = buildMarkdown(conv, {
      title: "T", date: "2026-08-05", sessionId: "s1",
    });
    expect(md).toContain('sourcePath: ""');
  });
});

// #312 delta 2 — hosted-cloud capture path (real module, mocked fetch)

describe("#312 cloudConfig/isCloudEnabled", () => {
  beforeEach(() => {
    delete process.env.TORTOISE_API_KEY;
    delete process.env.TORTOISE_API_URL;
  });

  test("cloud unset/false → NOT enabled (local ingest path unchanged)", () => {
    expect(isCloudEnabled({ autoCapture: true })).toBe(false);
    expect(isCloudEnabled({ autoCapture: true, cloud: false })).toBe(false);
    // even with a key, cloud must be explicitly true to switch paths
    expect(isCloudEnabled({ autoCapture: true, cloud: false, apiKey: "tt_x" })).toBe(false);
  });

  test("cloud:true requires an api key", () => {
    expect(isCloudEnabled({ autoCapture: true, cloud: true })).toBe(false);
    expect(isCloudEnabled({ autoCapture: true, cloud: true, apiKey: "" })).toBe(false);
    expect(isCloudEnabled({ autoCapture: true, cloud: true, apiKey: "  " })).toBe(false);
    expect(isCloudEnabled({ autoCapture: true, cloud: true, apiKey: "tt_x" })).toBe(true);
  });

  test("apiKey is trimmed before the emptiness check", () => {
    expect(isCloudEnabled({ autoCapture: true, cloud: true, apiKey: "  tt_x  " })).toBe(true);
    expect(cloudConfig({ autoCapture: true, apiKey: "  tt_x  " }).apiKey).toBe("tt_x");
  });

  test("apiUrl defaults to premiselabs and strips trailing slashes", () => {
    expect(cloudConfig({ autoCapture: true }).apiUrl).toBe("https://api.premiselabs.co");
    expect(cloudConfig({ autoCapture: true, apiUrl: "https://example.com/" }).apiUrl).toBe("https://example.com");
    expect(cloudConfig({ autoCapture: true, apiUrl: "https://example.com///" }).apiUrl).toBe("https://example.com");
  });

  test("env vars (TORTOISE_API_KEY / TORTOISE_API_URL) win over file config — mirrors reflect-hook", () => {
    const fromFile = cloudConfig({ autoCapture: true, apiUrl: "https://file.example.com", apiKey: "tt_file" });
    expect(fromFile.apiKey).toBe("tt_file");
    expect(fromFile.apiUrl).toBe("https://file.example.com");

    process.env.TORTOISE_API_KEY = "tt_env";
    process.env.TORTOISE_API_URL = "https://env.example.com/";
    try {
      const fromEnv = cloudConfig({ autoCapture: true, apiUrl: "https://file.example.com", apiKey: "tt_file" });
      expect(fromEnv.apiKey).toBe("tt_env");
      expect(fromEnv.apiUrl).toBe("https://env.example.com");
      expect(isCloudEnabled({ autoCapture: true, cloud: true, apiKey: "tt_file" })).toBe(true);
    } finally {
      delete process.env.TORTOISE_API_KEY;
      delete process.env.TORTOISE_API_URL;
    }
  });
});

describe("#312 captureToHosted", () => {
  let originalFetch: typeof fetch;

  beforeEach(() => {
    originalFetch = globalThis.fetch;
  });

  afterEach(() => {
    globalThis.fetch = originalFetch;
    vi.restoreAllMocks();
  });

  test("POSTs {session_id, conversation, metadata} to {apiUrl}/v1/sessions with Bearer auth", async () => {
    const fetchMock = vi.fn(async (url: unknown, init: RequestInit) => {
      expect(url).toBe("https://api.premiselabs.co/v1/sessions");
      expect((init.headers as Record<string, string>).Authorization).toBe("Bearer tt_test");
      expect((init.headers as Record<string, string>)["Content-Type"]).toBe("application/json");
      const body = JSON.parse(String(init.body));
      expect(body.session_id).toBe("sess-1");
      expect(body.conversation).toEqual([{ role: "user", content: "hello" }]);
      expect(body.metadata.source).toBe("pi-agent-end");
      return { ok: true, status: 200 } as Response;
    });
    globalThis.fetch = fetchMock as unknown as typeof fetch;
    const log = vi.spyOn(console, "log").mockImplementation(() => {});

    await captureToHosted(
      "https://api.premiselabs.co",
      "tt_test",
      {
        session_id: "sess-1",
        conversation: [{ role: "user", content: "hello" }],
        metadata: { source: "pi-agent-end", capturedAt: new Date().toISOString() },
      },
      "/tmp/record.jsonl",
    );

    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(log).toHaveBeenCalledWith(expect.stringContaining("Captured session sess-1"));
  });

  test("logs HTTP error detail and does not throw on non-2xx", async () => {
    globalThis.fetch = vi.fn(async () =>
      ({ ok: false, status: 500, json: async () => ({ detail: "boom" }) }) as unknown as Response,
    );
    const err = vi.spyOn(console, "error").mockImplementation(() => {});

    await expect(
      captureToHosted("https://x.example", "tt_test", { session_id: "s", conversation: [], metadata: {} }, "/tmp/r.jsonl"),
    ).resolves.toBeUndefined();
    expect(err).toHaveBeenCalledWith(expect.stringContaining("HTTP 500"));
    expect(err).toHaveBeenCalledWith(expect.stringContaining("boom"));
  });

  test("logs network failure and does not throw", async () => {
    globalThis.fetch = vi.fn(async () => {
      throw new Error("ECONNREFUSED");
    });
    const err = vi.spyOn(console, "error").mockImplementation(() => {});

    await expect(
      captureToHosted("https://x.example", "tt_test", { session_id: "s", conversation: [], metadata: {} }, "/tmp/r.jsonl"),
    ).resolves.toBeUndefined();
    expect(err).toHaveBeenCalledWith(expect.stringContaining("ECONNREFUSED"));
  });
});

describe("#312 writeCloudFallback (JSONL durable record before network attempt)", () => {
  test("appends one JSON object per session to the fallback dir", async () => {
    const dir = mkdtempSync(join(tmpdir(), "tc-fallback-"));
    process.env.TORTOISE_FALLBACK_DIR = dir;
    vi.resetModules();
    const mod = await import("./index");
    try {
      const record = { session_id: "s1", conversation: [{ role: "user", content: "hi" }] };
      const filePath = mod.writeCloudFallback(record);
      expect(filePath.startsWith(dir)).toBe(true);
      const lines = readFileSync(filePath, "utf-8").trim().split("\n");
      expect(lines).toHaveLength(1);
      expect(JSON.parse(lines[0])).toEqual(record);

      // second write appends (JSONL), never overwrites
      mod.writeCloudFallback({ session_id: "s2" });
      expect(readFileSync(filePath, "utf-8").trim().split("\n")).toHaveLength(2);
    } finally {
      delete process.env.TORTOISE_FALLBACK_DIR;
      vi.resetModules();
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
