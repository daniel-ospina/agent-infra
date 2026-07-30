/**
 * builtin-tools.test.ts — unit tests for builtin-tools/index.ts
 *
 * Covers: HTML stripping, Perplexity key resolution, timeout constants,
 * regression tests for known bugs (#5838, #5526, #5954, #5955).
 *
 * Run: npx tsx operations/pi-config/extensions/builtin-tools/builtin-tools.test.ts
 *
 * NOTE: Requires mocks at node_modules/@mariozechner/pi-coding-agent and
 * node_modules/typebox. Created by CI setup or manually.
 */

import { stripHtml, getPerplexityKey } from "./index.js";
import { ok, equal } from "node:assert/strict";
import { readFileSync, renameSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const source = readFileSync(resolve(__dirname, "index.ts"), "utf-8");

let passed = 0;
let failed = 0;

function test(name: string, fn: () => void) {
  try {
    fn();
    passed++;
    console.log(`  ✅ ${name}`);
  } catch (err: any) {
    failed++;
    console.log(`  ❌ ${name}: ${err.message}`);
  }
}

function section(name: string) {
  console.log(`\n${name}:`);
}

// ── stripHtml ─────────────────────────────────────────

section("stripHtml — basic");

test("removes simple tags", () => {
  equal(stripHtml("<p>Hello</p>"), "Hello");
});

test("removes nested tags", () => {
  equal(stripHtml("<div><p>Hello <b>World</b></p></div>"), "Hello World");
});

test("handles self-closing tags", () => {
  equal(stripHtml("Line 1<br>Line 2"), "Line 1 Line 2");
});

test("handles empty input", () => {
  equal(stripHtml(""), "");
});

test("handles text without HTML", () => {
  equal(stripHtml("Plain text"), "Plain text");
});

section("stripHtml — script/style removal");

test("removes script tags with content", () => {
  equal(stripHtml('<script>alert("xss")</script>Hello'), "Hello");
});

test("removes style tags with content", () => {
  equal(stripHtml("<style>body { color: red; }</style>Hello"), "Hello");
});

test("removes multiline script blocks", () => {
  // stripHtml collapses whitespace, so leading space after script removal is trimmed
  equal(stripHtml("<script>\nconsole.log('hi');\n</script>\nWorld"), "World");
});

section("stripHtml — HTML entities");

test("decodes &amp;", () => {
  equal(stripHtml("A &amp; B"), "A & B");
});

test("decodes &lt; and &gt;", () => {
  equal(stripHtml("&lt;tag&gt;"), "<tag>");
});

test("decodes &quot;", () => {
  equal(stripHtml('&quot;hello&quot;'), '"hello"');
});

test("decodes &#39;", () => {
  equal(stripHtml("&#39;hello&#39;"), "'hello'");
});

section("stripHtml — whitespace");

test("collapses multiple spaces", () => {
  equal(stripHtml("Hello    World"), "Hello World");
});

test("trims leading/trailing whitespace", () => {
  equal(stripHtml("  Hello World  "), "Hello World");
});

test("collapses newlines and tabs", () => {
  equal(stripHtml("Hello\n\tWorld"), "Hello World");
});

// ── getPerplexityKey ──────────────────────────────────

section("getPerplexityKey");

test("reads from PERPLEXITY_API_KEY env var", () => {
  process.env.PERPLEXITY_API_KEY = "test-key-123";
  equal(getPerplexityKey(), "test-key-123");
  delete process.env.PERPLEXITY_API_KEY;
});

test("returns undefined when no key configured", () => {
  const saved = process.env.PERPLEXITY_API_KEY;
  // Clear env var — but getPerplexityKey also reads operations/mcp-server/.env
  // as a fallback. Move the .env file aside during the test.
  const envPath = resolve(process.cwd(), "operations/mcp-server/.env");
  const bakPath = envPath + '.bak';
  if (existsSync(envPath)) renameSync(envPath, bakPath);
  try {
    delete process.env.PERPLEXITY_API_KEY;
    equal(getPerplexityKey(), undefined);
  } finally {
    if (saved) process.env.PERPLEXITY_API_KEY = saved;
    if (existsSync(bakPath)) renameSync(bakPath, envPath);
  }
});

// ── Timeout constants (regression) ────────────────────

section("Timeout constants (#5954, #5955 regression)");

test("heartbeat timeout is 480s (#6539)", () => {
  ok(source.includes("HEARTBEAT_TIMEOUT_MS = 480_000"), "heartbeat timeout should be 480000ms (480s)");
});

// ── Module load regression ────────────────────────────

section("Module load regression");

test("imports builtin-tools without errors (#5622 pattern)", () => {
  // If the module loaded (we're running this test), imports work.
  ok(true, "module loaded successfully");
});

test("stripHtml is callable (#5527 pattern)", () => {
  ok(typeof stripHtml === "function");
  stripHtml("<p>test</p>"); // should not throw
  ok(true, "stripHtml callable without errors");
});

test("getPerplexityKey is callable", () => {
  ok(typeof getPerplexityKey === "function");
  getPerplexityKey(); // should not throw
  ok(true, "getPerplexityKey callable without errors");
});

// ── MCP inheritance (#5838 regression) ────────────────

section("MCP inheritance (#5838 regression)");

test("PI_MCP_SERVERS is inherited from parent env", () => {
  ok(source.includes("...process.env"), "sub-agent env should spread parent env (#5838)");
  ok(source.includes("PI_MCP_SERVERS"), "PI_MCP_SERVERS should be in source");
});

// ── Banner suppression (#5526, #5672 regression) ──────

section("Banner suppression (#5526, #5672 regression)");

test("startup banner suppressed in print mode", () => {
  ok(source.includes("PI_MODE !== 'print'"), "banner suppression for print mode should exist (#5526 #5672)");
});

// ── Results ───────────────────────────────────────────

console.log(`\n=== Results: ${passed} passed, ${failed} failed ===`);
if (failed > 0) {
  console.log("❌ SOME TESTS FAILED");
  process.exit(1);
}
console.log("✅ ALL TESTS PASSED");
