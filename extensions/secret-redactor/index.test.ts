/**
 * secret-redactor/index.test.ts — the tool_result guard's behaviour pins (#5109).
 *
 * WHY THIS SUITE EXISTS: the module's own header records that three review rounds
 * found 23 defects (unanchored patterns, the memoised traversal, Map keys, byte
 * payloads, leaf-scoped key matching, the fail-open), and NOTHING enforced any of
 * them — a future edit could silently reintroduce every one. This suite pins the
 * redaction behaviours and, specifically, the shape fixes of review rounds 4–6:
 *
 *   - byte payloads are redacted at BYTE precision and keep their container type
 *     (the old path UTF-8-decoded the whole buffer, turning `ff fe` into `ef bf bd`,
 *     and returned a plain Uint8Array for a Buffer);
 *   - a secret used as a PLAIN-OBJECT key is redacted (it used to be copied through
 *     and the handler then saw no hit at all — the result passed unredacted);
 *   - a TRAVERSAL FAILURE fails CLOSED (it used to return the original result when
 *     no hit had been recorded yet, re-emitting a secret in a later sibling);
 *   - a `*_KEY` leaf is collected while a `public_key`/`ssh_public_key` leaf is not;
 *   - ordinary snake_case `*_key` data (`sort_key`, `foreign_key`, `primary_key`, …)
 *     is NOT collected — the over-redaction the `_key$` widening introduced; and
 *   - a `*_SIGNING_KEY` leaf/env var IS collected (it is a private signing secret,
 *     not public key material — the unanchored `PUBLIC_RE` exempted every one).
 *
 * Hermetic: HOME is redirected to a temp dir BEFORE the module is imported, because
 * AGENT_DIR is computed at module load. Zero runtime deps (the pi import in index.ts
 * is type-only).
 * Run: npx tsx extensions/secret-redactor/index.test.ts
 */
process.env.NODE_ENV = "test";

import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ok, equal, strictEqual } from "node:assert/strict";

const CONFIG_SECRET = "cfgsecretvalue0000000001";
const ENV_SECRET = "envsecretvalue0000000002";
const PATTERN_SECRET = "tt_" + "A".repeat(30);
const KEY_LEAF_SECRET = "underscorekeyvalue00000004";
const SIGNING_KEY_SECRET = "signingkeysecretvalue0005";
const SIGNING_ENV_SECRET = "signingenvironmentsecret06";
const PUBLIC_KEY_MATERIAL = "not-a-secret-public-key-material";
const SSH_PUBLIC_KEY_MATERIAL = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQ public";

const HOME = mkdtempSync(join(tmpdir(), "secret-redactor-test-"));
process.env.HOME = HOME;
const AGENT = join(HOME, ".pi", "agent");
mkdirSync(AGENT, { recursive: true });
writeFileSync(
  join(AGENT, "tortoise-config.json"),
  JSON.stringify({
    apiKey: CONFIG_SECRET,
    // An env REFERENCE template is not a credential and must never be collected —
    // reading a config used to redact `$ZAI_API_KEY` itself (review round 1).
    backupApiKey: "$ZAI_API_KEY",
  }),
);
// A camelCase leaf (`authToken`) must still be collected (review round 3).
writeFileSync(join(AGENT, "camel-config.json"), JSON.stringify({ authToken: "camelcasevalue00000003" }));
// A `*_KEY` leaf must be collected (review round 5) while public-key leaves must NOT —
// the same shape that was missed before, plus the over-redaction trap its fix opens.
// The nested env block is the reviewer's exact reproduction (`.mcp.json`).
// A `*_SIGNING_KEY` leaf is a PRIVATE HMAC/JWT signing secret, not public key
// material — the round-5 `PUBLIC_RE` widening dropped its leading anchor and
// exempted every `*signing_key` leaf, so it was emitted verbatim (review round 6).
writeFileSync(
  join(AGENT, ".mcp.json"),
  JSON.stringify({ mcpServers: { s: { env: { OPENAI_KEY: KEY_LEAF_SECRET, TOKEN_SIGNING_KEY: SIGNING_KEY_SECRET } } } }),
);
writeFileSync(
  join(AGENT, "keys-config.json"),
  JSON.stringify({
    public_key: PUBLIC_KEY_MATERIAL,
    ssh_public_key: SSH_PUBLIC_KEY_MATERIAL,
    // Ordinary camelCase/key-suffix data that a naive `key$` would redact as a secret.
    sortKey: "ordinary-sort-key-value00001",
    monkey: "ordinary-data-not-secret0001",
    // ...and the SNAKE_CASE spelling of the same ordinary relational/identity data.
    // The round-5 `_key$` widening collected every one of these as a secret; a
    // narrow credential suffix would drop the round-5 `*_KEY` fix, so the exclusion
    // is a vocabulary of non-secret key shapes (review round 6).
    sort_key: "ordinary-snake-sort-key-001",
    foreign_key: "ordinary-foreign-key-data02",
    primary_key: "ordinary-primary-key-val03",
    cache_key: "ordinary-cache-key-value04",
    partition_key: "ordinary-partition-key-05",
    dedup_key: "ordinary-dedup-key-value06",
    key: "ordinary-bare-key-value-0007",
  }),
);
process.env.SECRET_REDACTOR_TEST_API_KEY = ENV_SECRET;
// A signing secret in the ENVIRONMENT must be collected too — `PUBLIC_ANY_RE`
// carried the same unanchored `signing_?key` exemption (review round 6).
process.env.JWT_SIGNING_KEY = SIGNING_ENV_SECRET;
delete process.env.ZAI_API_KEY;

let passed = 0;
let failed = 0;
async function test(name: string, fn: () => void | Promise<void>): Promise<void> {
  try {
    await fn();
    passed++;
    console.log(`  ✅ ${name}`);
  } catch (err) {
    failed++;
    console.log(`  ❌ ${name}: ${(err as Error).message}`);
  }
}

async function main(): Promise<void> {
  const { default: secretRedactor } = (await import("./index.js")) as {
    default: (pi: unknown) => void;
  };

  let handler: ((event: unknown) => unknown) | undefined;
  const pi = {
    on: (name: string, fn: (event: unknown) => unknown) => {
      if (name === "tool_result") handler = fn;
    },
  };
  secretRedactor(pi);
  const run = (event: Record<string, unknown>): Promise<any> => Promise.resolve(handler!(event));

  // ── exact-value detection (config store + env) ─────────────────────────────
  await test("exact configured value is redacted from content", async () => {
    const out = await run({ toolName: "bash", content: [{ type: "text", text: `key=${CONFIG_SECRET}` }] });
    ok(out, "a hit must produce a patch");
    ok(!JSON.stringify(out).includes(CONFIG_SECRET), "the secret must not survive");
    ok(JSON.stringify(out).includes("[REDACTED:"), "a marker must be present");
  });

  await test("exact env value is redacted", async () => {
    const out = await run({ toolName: "bash", content: [{ type: "text", text: `token=${ENV_SECRET}` }] });
    ok(out && !JSON.stringify(out).includes(ENV_SECRET), "env secret must be redacted");
  });

  await test("a secret in details alone still produces a patch + warning", async () => {
    const out = await run({ toolName: "read", content: [{ type: "text", text: "ok" }], details: { value: CONFIG_SECRET } });
    ok(out && !JSON.stringify(out).includes(CONFIG_SECRET), "details must be redacted");
    ok(
      out.content.some((p: { text?: string }) => (p.text ?? "").includes("REDACTED from this read result")),
      "the warning part must be appended to content",
    );
  });

  await test("credential PATTERN is redacted (survives rotation)", async () => {
    const out = await run({ toolName: "bash", content: [{ type: "text", text: `export K=${PATTERN_SECRET}` }] });
    ok(out && !JSON.stringify(out).includes(PATTERN_SECRET), "pattern shape must be redacted");
  });

  // ── traversal shapes ───────────────────────────────────────────────────────
  await test("aliased object: both paths see the redacted copy", async () => {
    const leaf = { token: CONFIG_SECRET };
    const out = await run({ toolName: "x", content: [{ type: "text", text: "ok" }], details: { a: leaf, b: leaf } });
    ok(out && !JSON.stringify(out).includes(CONFIG_SECRET), "an alias must not re-emit the original");
  });

  await test("cyclic object terminates and is redacted", async () => {
    const node: Record<string, unknown> = { token: CONFIG_SECRET };
    node.self = node;
    const out = await run({ toolName: "x", content: [{ type: "text", text: "ok" }], details: node });
    ok(out, "a cycle must terminate and produce a patch");
    equal(out.details.self, out.details, "the cycle resolves to the redacted copy, not a hang");
    ok(!String(out.details.token).includes(CONFIG_SECRET), "the secret is redacted on the copy");
  });

  await test("Map string key is redacted", async () => {
    const out = await run({
      toolName: "x",
      content: [{ type: "text", text: "ok" }],
      details: new Map([[CONFIG_SECRET, "v"]]),
    });
    ok(out && !JSON.stringify([...out.details]).includes(CONFIG_SECRET), "Map key must be redacted");
  });

  // ── review round 4, finding 4: plain-object KEY ────────────────────────────
  await test("plain-object KEY holding a secret is redacted (used to pass through untouched)", async () => {
    const out = await run({ toolName: "x", content: [{ type: "text", text: "ok" }], details: { [CONFIG_SECRET]: "v" } });
    ok(out, "a redacted key must produce a patch, not undefined");
    ok(!JSON.stringify(out).includes(CONFIG_SECRET), "the key must not survive");
    equal(Object.keys(out.details).length, 1, "the entry survives under the marker");
    ok(String(Object.keys(out.details)[0]).startsWith("[REDACTED:"), "the key is renamed to the marker");
  });

  // ── review round 4, finding 3: byte payloads ───────────────────────────────
  await test("Buffer payload keeps non-UTF-8 bytes and stays a Buffer", async () => {
    const raw = Buffer.concat([
      Buffer.from([0xff, 0xfe, 0x00]),
      Buffer.from(CONFIG_SECRET, "utf8"),
      Buffer.from([0x80, 0x81]),
    ]);
    const out = await run({ toolName: "x", content: [{ type: "text", text: "ok" }], details: { blob: raw } });
    ok(out, "a secret inside a Buffer must produce a patch");
    const blob: unknown = out.details.blob;
    ok(Buffer.isBuffer(blob), "a Buffer must come back a Buffer");
    const buf = blob as Buffer;
    equal(buf[0], 0xff, "leading 0xff must be preserved byte-for-byte");
    equal(buf[1], 0xfe, "leading 0xfe must be preserved byte-for-byte");
    equal(buf[2], 0x00, "the NUL byte must be preserved");
    equal(buf[buf.length - 2], 0x80, "trailing 0x80 must be preserved");
    equal(buf[buf.length - 1], 0x81, "trailing 0x81 must be preserved");
    ok(!buf.includes(Buffer.from(CONFIG_SECRET, "utf8")), "the secret bytes must be gone");
  });

  await test("an aliased Buffer resolves to ONE redacted copy", async () => {
    const raw = Buffer.from(`x${CONFIG_SECRET}y`, "utf8");
    const out = await run({ toolName: "x", content: [{ type: "text", text: "ok" }], details: { a: raw, b: raw } });
    ok(out && Buffer.isBuffer(out.details.a), "a Buffer must come back a Buffer");
    strictEqual(out.details.a, out.details.b, "an alias must resolve to the same redacted copy");
    ok(!Buffer.from(out.details.a).includes(Buffer.from(CONFIG_SECRET)), "the secret must be gone");
  });

  await test("Uint8Array payload stays a Uint8Array", async () => {
    const raw = new Uint8Array(Buffer.from(`xx${CONFIG_SECRET}yy`, "utf8"));
    const out = await run({ toolName: "x", content: [{ type: "text", text: "ok" }], details: { blob: raw } });
    ok(out, "secret in a Uint8Array must produce a patch");
    ok(out.details.blob instanceof Uint8Array, "the view type must be preserved");
    ok(!Buffer.from(out.details.blob).includes(Buffer.from(CONFIG_SECRET)), "the secret bytes must be gone");
  });

  await test("a secret in a non-8-bit typed array fails CLOSED (withheld, not dropped)", async () => {
    const bytes = Buffer.concat([Buffer.from([0x41, 0x42]), Buffer.from(CONFIG_SECRET, "utf8")]);
    const even = bytes.subarray(0, bytes.length - (bytes.length % 2));
    const nums = new Uint16Array(even.buffer, even.byteOffset, even.byteLength / 2);
    const out = await run({ toolName: "x", content: [{ type: "text", text: "ok" }], details: { nums } });
    ok(out && out.isError === true, "an unredactable byte container must withhold");
    ok(!JSON.stringify(out).includes(CONFIG_SECRET), "the secret must not survive the withheld result");
  });

  // ── review round 4, finding 5: traversal failure must fail CLOSED ──────────
  await test("a traversal throw BEFORE any secret fails closed (used to pass the original through)", async () => {
    const content = [
      { get boom(): string { throw new Error("boom"); } },
      { type: "text", text: CONFIG_SECRET },
    ];
    const out = await run({ toolName: "x", content });
    ok(out, "an incomplete scan is not evidence of absence — it must withhold, not return undefined");
    equal(out.isError, true, "the withheld result is an error");
    ok(!JSON.stringify(out).includes(CONFIG_SECRET), "the unvisited sibling's secret must not be emitted");
    ok(JSON.stringify(out).toLowerCase().includes("withheld"), "the withheld message explains the state");
  });

  await test("a traversal throw AFTER a secret also fails closed", async () => {
    const content = [
      { type: "text", text: CONFIG_SECRET },
      { get boom(): string { throw new Error("boom"); } },
    ];
    const out = await run({ toolName: "x", content });
    ok(out && out.isError === true && !JSON.stringify(out).includes(CONFIG_SECRET), "fail closed");
  });

  // ── review round 5: the `*_KEY` leaf gap + its over-redaction trap ──────────
  await test("exact value under a `*_KEY` leaf is collected (used to emit verbatim)", async () => {
    const out = await run({ toolName: "bash", content: [{ type: "text", text: `OPENAI_KEY=${KEY_LEAF_SECRET}` }] });
    ok(out, "a *_KEY literal in a config store must produce a patch");
    ok(!JSON.stringify(out).includes(KEY_LEAF_SECRET), "the *_KEY secret must not survive");
  });

  await test("public-key leaves are NOT collected (the widened-`key$` trap)", async () => {
    strictEqual(
      await run({ toolName: "x", content: [{ type: "text", text: `public_key=${PUBLIC_KEY_MATERIAL}` }] }),
      undefined,
    );
    strictEqual(
      await run({ toolName: "x", content: [{ type: "text", text: `ssh_public_key=${SSH_PUBLIC_KEY_MATERIAL}` }] }),
      undefined,
    );
  });

  await test("ordinary camelCase `*Key` data is NOT collected (over-redaction guard)", async () => {
    strictEqual(
      await run({ toolName: "x", content: [{ type: "text", text: "sortKey=ordinary-sort-key-value00001" }] }),
      undefined,
    );
    strictEqual(
      await run({ toolName: "x", content: [{ type: "text", text: "monkey=ordinary-data-not-secret0001" }] }),
      undefined,
    );
  });

  // ── review round 6: the `_key$` over-redaction + the `*_SIGNING_KEY` leak ───
  await test("ordinary snake_case `*_key` data is NOT collected (over-redaction guard)", async () => {
    for (const line of [
      "sort_key=ordinary-snake-sort-key-001",
      "foreign_key=ordinary-foreign-key-data02",
      "primary_key=ordinary-primary-key-val03",
      "cache_key=ordinary-cache-key-value04",
      "partition_key=ordinary-partition-key-05",
      "dedup_key=ordinary-dedup-key-value06",
      "key=ordinary-bare-key-value-0007",
    ]) {
      strictEqual(await run({ toolName: "x", content: [{ type: "text", text: line }] }), undefined, line);
    }
  });

  await test("a `*_SIGNING_KEY` store leaf IS collected (private signing secret, not public material)", async () => {
    const out = await run({ toolName: "bash", content: [{ type: "text", text: `TOKEN_SIGNING_KEY=${SIGNING_KEY_SECRET}` }] });
    ok(out, "a *_SIGNING_KEY literal in a config store must produce a patch (used to leak)");
    ok(!JSON.stringify(out).includes(SIGNING_KEY_SECRET), "the signing secret must not survive");
  });

  await test("a `*_SIGNING_KEY` ENV var IS collected (same exemption, env side)", async () => {
    const out = await run({ toolName: "bash", content: [{ type: "text", text: `JWT_SIGNING_KEY=${SIGNING_ENV_SECRET}` }] });
    ok(out, "a *_SIGNING_KEY env value must produce a patch (used to leak)");
    ok(!JSON.stringify(out).includes(SIGNING_ENV_SECRET), "the signing env secret must not survive");
  });

  await test("the marker label does not double its store prefix", async () => {
    const out = await run({ toolName: "bash", content: [{ type: "text", text: `key=${CONFIG_SECRET}` }] });
    ok(
      out && JSON.stringify(out).includes("[REDACTED:tortoise-config:apiKey]"),
      "the label is store:path, not store:store.path",
    );
  });

  // ── negatives: no over-redaction, no touch when clean ──────────────────────
  await test("no secret anywhere → the result is left untouched", async () => {
    strictEqual(await run({ toolName: "x", content: [{ type: "text", text: "nothing to see" }] }), undefined);
  });

  await test("non-array content is not ours to touch", async () => {
    strictEqual(await run({ toolName: "x", content: "a plain string" }), undefined);
  });

  await test("a hyphenated word is not an `sk-` key (left-anchored patterns)", async () => {
    strictEqual(await run({ toolName: "x", content: [{ type: "text", text: "task-management-best-practices" }] }), undefined);
  });

  await test("env REFERENCE templates are not collected as secrets", async () => {
    strictEqual(await run({ toolName: "x", content: [{ type: "text", text: "apiKey: $ZAI_API_KEY" }] }), undefined);
  });

  // ── cleanup + summary ──────────────────────────────────────────────────────
  try { rmSync(HOME, { recursive: true, force: true }); } catch { /* best effort */ }
  console.log(`\n${passed} passed, ${failed} failed`);
  if (failed > 0) process.exit(1);
}

main();
