/**
 * Self-check: chunker.test.ts
 * Run: npx tsx operations/pi-config/extensions/slack-bridge/chunker.test.ts
 *
 * Matches test conventions:
 * assert-based, process.exit(1) on failure.
 */

import { chunk, MAX_CHUNK } from "./chunker.ts";

let passed = 0;
let failed = 0;

function assert(condition: boolean, label: string): void {
  if (condition) {
    passed++;
  } else {
    failed++;
    console.error(`❌ FAIL: ${label}`);
  }
}

function stripPrefix(s: string): string {
  return s.replace(/^\(part \d+\/\d+\)\n/, "");
}

// ── Short text (single chunk, no prefix) ──
{
  const r = chunk("x".repeat(100));
  assert(r.length === 1, "short: 1 chunk");
  assert(!r[0].includes("(part"), "short: no prefix");
  assert(r[0] === "x".repeat(100), "short: content intact");
}

// ── Exactly MAX_CHUNK (boundary, single chunk) ──
{
  const r = chunk("x".repeat(MAX_CHUNK));
  assert(r.length === 1, "boundary-3000: 1 chunk");
  assert(!r[0].includes("(part"), "boundary-3000: no prefix");
}

// ── Exactly MAX_CHUNK + 1 (split) ──
{
  const r = chunk("x".repeat(MAX_CHUNK + 1));
  assert(r.length === 2, "3001: 2 chunks");
  assert(r[0].startsWith("(part 1/2)"), "3001: chunk 0 has prefix");
  assert(r[1].startsWith("(part 2/2)"), "3001: chunk 1 has prefix");
  // Each chunk (including prefix) must be <= MAX_CHUNK
  assert(r.every((c) => c.length <= MAX_CHUNK), "3001: all chunks <= MAX_CHUNK");
  assert(
    r.map(stripPrefix).join("") === "x".repeat(MAX_CHUNK + 1),
    "3001: reconstructs original",
  );
}

// ── 6000 chars (2 chunks) ──
{
  const original = "x".repeat(6000);
  const r = chunk(original);
  assert(r.length === 3, "6000: 3 chunks (2986+2986+28 with reserve)");
  assert(r.every((c) => c.length <= MAX_CHUNK), "6000: all chunks <= MAX_CHUNK");
  assert(r.map(stripPrefix).join("") === original, "6000: reconstructs original");
}

// ── Fence straddling boundary ──
{
  // a's till 2990, then a newline + code block, then b's — total > 3000.
  // The \n before the fence ensures it's a fence LINE, matching markdown reality.
  const original = "a".repeat(2990) + "\n```js\nconsole.log('hi');\n```\n" + "b".repeat(50);
  const r = chunk(original);
  assert(
    r.every((c) => {
      // no chunk should have an odd number of fences (unclosed block)
      const fences = (c.match(/^```/gm) || []).length;
      return fences % 2 === 0;
    }),
    "fence-straddle: no chunk has unclosed fence",
  );
  assert(r.map(stripPrefix).join("") === original, "fence-straddle: reconstructs original");
}

// ── Empty string ──
{
  const r = chunk("");
  assert(r.length === 0, "empty: 0 chunks");
}

// ── Inline ``` in prose (should NOT toggle fence parity) ──
{
  // "use ``` to denote" repeated enough to exceed MAX_CHUNK
  const line = "use ``` to denote code blocks.\n";
  const original = line.repeat(Math.ceil((MAX_CHUNK + 100) / line.length));
  const r = chunk(original);
  assert(r.every((c) => c.length <= MAX_CHUNK), "inline-fence: all chunks <= MAX_CHUNK");
  assert(
    r.map(stripPrefix).join("") === original,
    "inline-fence: reconstructs original",
  );
}

// ── Code fence opens exactly at a chunk boundary ──
{
  // a's at 2990, then a long code block that spans past 3000
  const block = "\n```\n" + "x".repeat(500) + "\n```\n" + "y".repeat(10);
  const original = "a".repeat(2990) + block;
  const r = chunk(original);
  // The code block should stay intact (both ``` marks in the same chunk)
  let foundBlock = false;
  for (const c of r) {
    const stripped = stripPrefix(c);
    if (stripped.includes(block)) {
      foundBlock = true;
      break;
    }
  }
  assert(foundBlock, "fence-at-boundary: code block stays in one chunk");
  assert(r.every((c) => c.length <= MAX_CHUNK), "fence-at-boundary: all chunks <= MAX_CHUNK");
  assert(r.map(stripPrefix).join("") === original, "fence-at-boundary: reconstructs original");
}

// ── Summary ──
console.log(`\nchunker.test.ts: ${passed} passed, ${failed} failed`);
if (failed > 0) {
  console.error("❌ SOME TESTS FAILED");
  process.exit(1);
}
console.log("✅ ALL TESTS PASSED");
