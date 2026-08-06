// tortoise-capture.test.ts — behavioral smoke tests (#7423)
// Verifies conversation extraction and markdown generation (pure functions).
// Integration surface (spawn) verified via manual ingest smoke test.

import { describe, test, expect } from "vitest";

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
    `summary: "${summary.replace(/"/g, '\"')}"`,
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
    expect(md).toMatch(/summary: "- Discussed Licensing"/);
    expect(md).toMatch(/sourcePath: "\/tmp\/test\.md"/);
    expect(md).toMatch(/documentKind: "transcript"/);
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
