/**
 * secret-redactor/index.test.ts — the tool_result guard's behaviour pins (#5109).
 *
 * WHY THIS SUITE EXISTS: the module's own header records that three review rounds
 * found 23 defects (unanchored patterns, the memoised traversal, Map keys, byte
 * payloads, leaf-scoped key matching, the fail-open), and NOTHING enforced any of
 * them — a future edit could silently reintroduce every one. This suite pins the
 * redaction behaviours and, specifically, the shape fixes of review rounds 4–9:
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
 *     not public key material — the unanchored `PUBLIC_RE` exempted every one);
 *   - a secret under a secret-marked PATH (`credentials.key`, `secrets.primary_key`,
 *     `apiKeys.key`) IS collected, while a path SEGMENT that merely STARTS with
 *     `token`/`secret` (`tokenizer`, `secretary`) is NOT a secret store;
 *   - a PREFIXED public-key leaf (`gpg_public_key`, `rsa_public_key`) is NOT
 *     collected, and an env name the relational veto used to drop (`PRIMARY_KEY`,
 *     `SECONDARY_KEY`, `CACHE_KEY`, `ID_KEY`) IS collected; and
 *   - an own `__proto__` key survives redaction and does not reparent the result
 *     (it was dropped by the prototype setter and its value became the prototype);
 *   - a config KEY that is itself a secret is scrubbed out of the redaction LABEL, so
 *     the marker and the warning cannot re-emit it (the label embedded the raw path);
 *   - a credential WORD in a leaf name must be a WHOLE segment, a camelCase SUFFIX, or a
 *     camelCase PREFIX compound whose following words are also credential vocabulary:
 *     `clientSecret`/`secret_key`/`dbPassword`/`credentials` AND
 *     `secretKey`/`secretAccessKey`/`passwordHash`/`secretPassphrase` are collected, while
 *     `secretary`/`credentialsFile`/`passwordPolicy`/`secretariatOffice` are NOT; and
 *   - the redaction LABEL is POSITION-INDEPENDENT of the store's contents (`store#N`): a
 *     secret that appears ONLY as a config KEY — never as a collected value — must not be
 *     re-emitted in the marker or the warning (the old pin was vacuous: its key secret was
 *     also a collected value, so it was scrubbed for the wrong reason); and
 *   - a configured store that EXISTS but cannot be read or parsed FAILS CLOSED (the exact
 *     detector is incomplete), naming the store — it used to be dropped silently; and
 *   - a NUMERIC store value is collected and redacted (only `typeof === "string"` was
 *     collected, so `{"apiKey": 123456789012345}` was emitted by a `cat` of its own
 *     store); a NON-ASCII secret is redacted in its `\uXXXX`-escaped spelling too (what
 *     `json.dumps`' `ensure_ascii`/`jq -a` emit); a REFERENCE template with a DEFAULT
 *     (`${VAR:-d}`) is NOT collected (it is a template, not a credential); a
 *     credential-SHAPED store FILE NAME yields a single, non-nested marker; and a NAMED
 *     own property of an Array/Map/Set is SCANNED and carried onto a rebuild (the arms
 *     iterate `for…of`, i.e. indices/entries only, so it was neither) (review round 13); and
 *   - an ENV secret's JSON-escaped spelling is redacted exactly like a store value's; a
 *     NUMERIC leaf is collected by its LEAF name only (a timestamp under a `credentials`
 *     path is not a secret); and a reference template is never a secret while its LITERAL
 *     default is collected on its own, including the nested `${A:-${B}}` spelling that a
 *     `[^}]*` matcher read as a literal (review round 14); and
 *   - a secret containing `&`/`<`/`>` is redacted in the `\u0026`/`\u003c`/`\u003e` spelling
 *     Go's `encoding/json` emits by default, and a numeric credential under a secret-marked
 *     path (`credentials.key`, `tokens.access`) is still collected while a numeric TIMESTAMP
 *     (`credentials.expires_at`) is not (review round 15); and
 *   - an own ENUMERABLE ACCESSOR (a getter) is MATERIALISED, never returned by reference:
 *     the walk read it ONCE, so a getter that answered clean to the guard and the
 *     configured secret to the serializer leaked with no patch and no notice. A clean
 *     accessor still yields a patch, and the materialisation is announced rather than
 *     silently rewriting the model's input (review round 12).
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
// Review round 7: the relational veto cancelled a secret-marked PATH; the path
// matcher was unanchored (over-redaction); the public-key exemption was leaf-anchored.
const CREDENTIALS_PATH_SECRET = "credentialspathsecretvalue1";
const SECRETS_PATH_SECRET = "secretspathprimarykeyvalue2";
const API_KEYS_PATH_SECRET = "apikeyspathkeyvalue000003";
const TOKENIZER_MODEL = "meta-llama/Llama-3-8B-Instruct";
const SECRETARY_NAME = "meeting-notes-document-value";
const GPG_PUBLIC_KEY_MATERIAL = "gpg-public-key-material-not-secret";
const RSA_PUBLIC_KEY_MATERIAL = "rsa-public-key-material-not-secret";
const APP_PUBLIC_KEY_MATERIAL = "app-public-key-material-not-secret";
const STRIPE_PUBLIC_KEY_MATERIAL = "stripe-public-key-material-notsecre";
const PRIMARY_ENV_SECRET = "primaryenvsecretvalue0001";
const SECONDARY_ENV_SECRET = "secondaryenvsecretvalue02";
const CACHE_ENV_SECRET = "cacheenvsecretvalue00003";
const ID_ENV_SECRET = "idenvsecretvalue000000004";
// Review round 8: the label embedded the traversal PATH (built from object KEYS, and a
// key can itself BE a secret); the LEAF matcher matched credential WORDS as substrings.
const AUTH_CONFIG_LEAF_SECRET = "authconfigleafsecret0008";
const CLIENT_SECRET_VALUE = "clientsecretvalue00000009";
const SECRET_KEY_LEAF_VALUE = "snakesecretvalue0000010";
const DB_PASSWORD_VALUE = "dbpasswordvalue0000011";
const CREDENTIALS_LEAF_VALUE = "credentialsvalue0000012";
const CREDENTIALS_FILE_VALUE = "/home/user/credentials-store.json";
const PASSWORD_POLICY_VALUE = "min-length-12-chars";
const SECRETARIAT_VALUE = "room-204-floor-3";
const TOKENIZER_PATH_VALUE = "/models/tokenizer-llama3";
// Review round 9: the round-8 anchoring dropped the camelCase-PREFIX compound leaves
// (credential word first, credential vocabulary after). Every one of these was collected
// before round 8 and emitted verbatim after it — a configured secret under an ordinary
// credential field name, which the pattern detector cannot catch.
const SECRET_KEY_LEAF_CAMEL_VALUE = "camelsecretkeyvalue000013";
const SECRET_ACCESS_KEY_VALUE = "camelsecretaccesskey0014";
const AWS_SECRET_ACCESS_KEY_VALUE = "awssecretaccesskeyvalue15";
const MY_SECRET_KEY_VALUE = "mysecretkeyvalue00000016";
const CLIENT_SECRET_KEY_VALUE = "clientsecretkeyvalue0017";
const CREDENTIALS_KEY_VALUE = "credentialskeyvalue00018";
const SECRET_VALUE_VALUE = "secretvaluevalue00000019";
const PASSWORD_HASH_VALUE = "passwordhashvalue0000020";
const PASSWORD_VALUE_VALUE = "passwordvaluevalue00021";
const CREDENTIAL_ID_VALUE = "credentialidvalue0000022";
// Review round 10 / backlog-land review: the label embedded the traversal PATH, so a
// secret used ONLY as a config KEY (never a collected value) was re-emitted in the
// marker and the warning; `secretPassphrase` was dropped by the round-8 anchoring; a
// camelCase `privateKey`/`signingKey` store leaf was emitted verbatim (the env collector
// caught `JWT_SIGNING_KEY`); and an unreadable/unparseable store silently removed its
// secrets from the exact-value detector.
const KEY_ONLY_SECRET = "keyonlyconfigsecret0000030";
const SECRET_PASSPHRASE_VALUE = "secretpassphrasevalue000031";
const PRIVATE_KEY_VALUE = "privatekeymaterialvalue0032";
const SIGNING_KEY_VALUE = "signingkeymaterialvalue0033";
// Review round 13 (fresh-context review at ce0d6200): five shapes the suite missed.
//  · a NUMERIC store value was never collected → a `cat` of its own store emitted it;
//  · a `\uXXXX`-escaped dump (Python `json.dumps` default / `jq -a`) of a NON-ASCII
//    secret never matched, so the dump passed while the literal was redacted;
//  · a store FILE NAME that is itself credential-shaped produced a marker INSIDE a
//    marker (`[REDACTED:[REDACTED:openai_key]#1]`) in the marker and the warning;
//  · a named own property of an Array/Map/Set was neither SCANNED nor carried onto a
//    rebuild (the arms iterate `for…of`, i.e. indices/entries only); and
//  · a shell/Compose reference template with a DEFAULT (`${VAR:-d}`) was collected as a
//    secret, contradicting "env REFERENCE templates are never secrets".
const NUMERIC_KEY_VALUE = 123456789012345;
const UNICODE_SECRET = "p@ssé123456789";
const UNICODE_ESCAPED_SECRET = "p@ss\\u00e9123456789";
// A SHORT literal default: the whole TEMPLATE is >= MIN_LEN (so a whole-value collector
// redacts it — the round-13 finding), while the default itself is below the floor, so a
// correct collector sees no secret here at all.
const REFERENCE_WITH_DEFAULT = "${OPENAI_API_KEY:-x}";
// ...and a LONG literal default: the template is not a secret, but the default IS the
// credential used when the variable is unset, so it must be collected on its own.
const REFERENCE_LITERAL_DEFAULT = "literaldefaultsecret999";
const REFERENCE_WITH_LITERAL_DEFAULT = "${UNSET_OPENAI_KEY:-" + REFERENCE_LITERAL_DEFAULT + "}";
// A NESTED reference (Compose/shell): not a reference under a `[^}]*` matcher, so the
// whole template was collected as a secret and redacted out of ordinary output.
const REFERENCE_NESTED = "${A_API_KEY:-${B_API_KEY}}";
// An ordinary NUMBER under a secret-marked PATH: a credential/OAuth cache timestamp.
// A number has no credential semantics of its own — the leaf name does.
const CREDENTIALS_EXPIRES_AT = 1712345678901;
// The OTHER direction of that rule (round 15): a numeric value under a secret-marked path
// whose leaf is NOT an ordinary-numeric field name is still a credential (`credentials.key`
// was lost when the path rescue was dropped for numbers entirely).
const CREDENTIALS_KEY_NUMERIC = 987654321098765;
const TOKENS_ACCESS_NUMERIC = 444444444444444;
// Go's `encoding/json` escapes `&`/`<`/`>` to `\u0026`/`\u003c`/`\u003e` (SetEscapeHTML
// is ON by default: every `gh api`/`go run` dump), so a secret containing one passed
// through such a dump while the `\uXXXX` spelling was claimed to be covered.
const HTML_ESCAPE_SECRET = "cfg&secret1234567890";
const HTML_ESCAPED_SECRET = "cfg\\u0026secret1234567890";
// An ENV secret containing a quote: the escaped spelling a JSON dump renders must be
// redacted too (only the store arm registered the escaped forms).
const ENV_QUOTED_SECRET = 'pass"phrase-with-quote-1234';
process.env.PROBE_QUOTED_API_KEY = ENV_QUOTED_SECRET;
const SHAPED_STORE_NAME = "sk-" + "Q7w8E9r0T1y2U3i4O5p6A7s8D9f0G1h2J3k4L5";
const SHAPED_STORE_SECRET = "shapedstorenamevalue000050";
const STORE_NAME_SECRET = "storenamescrubvalue000051";
const STORE_NAME_SECRET_2 = "otherstorevalue000000052";

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
    // The camelCase spelling of public material must stay exempt from the new
    // `(private|signing)key$` alternative (review round 10).
    publicKey: PUBLIC_KEY_MATERIAL,
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
    // A secret under a secret-marked PATH must be collected even when its leaf is a
    // relational word (`key`, `primary_key`) — the veto used to cancel the PATH match
    // and these were emitted verbatim (review round 7).
    credentials: { key: CREDENTIALS_PATH_SECRET },
    secrets: { primary_key: SECRETS_PATH_SECRET },
    apiKeys: { key: API_KEYS_PATH_SECRET },
    // ...and a segment that merely STARTS with a secret word is NOT a secret store:
    // the unanchored path matcher redacted ordinary config data (review round 7).
    tokenizer: { model: TOKENIZER_MODEL },
    secretary: { name: SECRETARY_NAME },
    // Prefixed public-key leaves are public material, not credentials — the
    // leaf-anchored exemption collected all of them (review round 7).
    gpg_public_key: GPG_PUBLIC_KEY_MATERIAL,
    rsa_public_key: RSA_PUBLIC_KEY_MATERIAL,
    app_public_key: APP_PUBLIC_KEY_MATERIAL,
    stripe_public_key: STRIPE_PUBLIC_KEY_MATERIAL,
  }),
);
// Review round 8, finding 1: a config KEY that is itself a secret. The marker and the
// appended warning are built from the traversal path, so the label re-emitted the
// secret it had just redacted.
writeFileSync(
  join(AGENT, "auth-config.json"),
  JSON.stringify({
    auths: {
      // KEY_ONLY: appears ONLY as a key, never as a value anywhere — the case the old pin
      // missed because its key secret was also apiKey's collected value.
      [KEY_ONLY_SECRET]: { password: AUTH_CONFIG_LEAF_SECRET },
      [CONFIG_SECRET]: { password: AUTH_CONFIG_LEAF_SECRET },
    },
  }),
);
// Review round 8, finding 2: ordinary STRING-valued leaves whose name merely CONTAINS a
// credential word were collected as secrets and rewritten out of tool results.
writeFileSync(
  join(AGENT, "app-config.json"),
  JSON.stringify({
    secretary: SECRETARY_NAME,
    credentialsFile: CREDENTIALS_FILE_VALUE,
    passwordPolicy: PASSWORD_POLICY_VALUE,
    secretariatOffice: SECRETARIAT_VALUE,
    tokenizerPath: TOKENIZER_PATH_VALUE,
  }),
);
// ...and the ANCHORED forms that must STILL be collected, so the anchoring cannot
// silently over-narrow (guard the fix in the other direction).
writeFileSync(
  join(AGENT, "wordkeys-config.json"),
  JSON.stringify({
    clientSecret: CLIENT_SECRET_VALUE,
    secret_key: SECRET_KEY_LEAF_VALUE,
    dbPassword: DB_PASSWORD_VALUE,
    credentials: CREDENTIALS_LEAF_VALUE,
    // Review round 9: a camelCase-PREFIX compound leaf must be collected too. The
    // round-8 anchoring kept the negatives below green while dropping every one of
    // these, so the fix is pinned in BOTH directions.
    secretKey: SECRET_KEY_LEAF_CAMEL_VALUE,
    secretAccessKey: SECRET_ACCESS_KEY_VALUE,
    awsSecretAccessKey: AWS_SECRET_ACCESS_KEY_VALUE,
    mySecretKey: MY_SECRET_KEY_VALUE,
    clientSecretKey: CLIENT_SECRET_KEY_VALUE,
    credentialsKey: CREDENTIALS_KEY_VALUE,
    secretValue: SECRET_VALUE_VALUE,
    passwordHash: PASSWORD_HASH_VALUE,
    passwordValue: PASSWORD_VALUE_VALUE,
    credentialId: CREDENTIAL_ID_VALUE,
    // Review round 10: `passphrase` is credential vocabulary, and a camelCase
    // `privateKey`/`signingKey` is private key material / a private signing secret.
    secretPassphrase: SECRET_PASSPHRASE_VALUE,
    privateKey: PRIVATE_KEY_VALUE,
    signingKey: SIGNING_KEY_VALUE,
  }),
);
process.env.SECRET_REDACTOR_TEST_API_KEY = ENV_SECRET;
// ...and the round-13 stores. Each one is the fixture for exactly one pin below.
writeFileSync(join(AGENT, "numeric-config.json"), JSON.stringify({ apiKey: NUMERIC_KEY_VALUE }));
writeFileSync(join(AGENT, "unicode-config.json"), JSON.stringify({ apiKey: UNICODE_SECRET }));
writeFileSync(join(AGENT, "reference-default-config.json"), JSON.stringify({ apiKey: REFERENCE_WITH_DEFAULT }));
writeFileSync(
  join(AGENT, "reference-literal-config.json"),
  JSON.stringify({ apiKey: REFERENCE_WITH_LITERAL_DEFAULT, backupApiKey: REFERENCE_NESTED }),
);
writeFileSync(
  join(AGENT, "credentials-cache.json"),
  JSON.stringify({ credentials: { expires_at: CREDENTIALS_EXPIRES_AT, key: CREDENTIALS_KEY_NUMERIC } }),
);
writeFileSync(join(AGENT, "tokens-config.json"), JSON.stringify({ tokens: { access: TOKENS_ACCESS_NUMERIC } }));
writeFileSync(join(AGENT, "html-escape-config.json"), JSON.stringify({ apiKey: HTML_ESCAPE_SECRET }));
// A store FILE NAME that is credential-shaped: the label is `store#N`, so this went into
// the marker and the warning as a nested marker after the pattern scrub ran inside it.
writeFileSync(join(AGENT, `${SHAPED_STORE_NAME}.json`), JSON.stringify({ apiKey: SHAPED_STORE_SECRET }));
// A store FILE NAME that IS a collected value — the one case the name scrub can see.
writeFileSync(join(AGENT, "storename-config.json"), JSON.stringify({ apiKey: STORE_NAME_SECRET }));
writeFileSync(join(AGENT, `${STORE_NAME_SECRET}.json`), JSON.stringify({ apiKey: STORE_NAME_SECRET_2 }));
// A signing secret in the ENVIRONMENT must be collected too — `PUBLIC_ANY_RE`
// carried the same unanchored `signing_?key` exemption (review round 6).
process.env.JWT_SIGNING_KEY = SIGNING_ENV_SECRET;
// A relational `*_KEY` env name is a credential signal, not a JSON column: the veto
// dropped these four from the env set entirely (review round 7).
process.env.PRIMARY_KEY = PRIMARY_ENV_SECRET;
process.env.SECONDARY_KEY = SECONDARY_ENV_SECRET;
process.env.CACHE_KEY = CACHE_ENV_SECRET;
process.env.ID_KEY = ID_ENV_SECRET;
delete process.env.ZAI_API_KEY;

// Review round 10: a store that EXISTS but cannot be parsed. Written BEFORE the module
// is imported so the handler's fail-closed path is exercised for real; the first test
// repairs it and re-loads, and the rest of the suite runs on a complete set.
writeFileSync(join(AGENT, "broken-store.json"), "{ this is not json");

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
  const { default: secretRedactor, refreshSecrets } = (await import("./index.js")) as {
    default: (pi: unknown) => void;
    refreshSecrets: () => void;
  };

  let handler: ((event: unknown) => unknown) | undefined;
  const pi = {
    on: (name: string, fn: (event: unknown) => unknown) => {
      if (name === "tool_result") handler = fn;
    },
  };
  secretRedactor(pi);
  const run = (event: Record<string, unknown>): Promise<any> => Promise.resolve(handler!(event));

  // ── review round 10: an unreadable store fails CLOSED, it is not dropped silently ──
  // FIRST, because the broken store must be present when the module loads its cache.
  await test("a store that EXISTS but cannot be parsed fails closed and names the store", async () => {
    const out = await run({ toolName: "read", content: [{ type: "text", text: "hello" }] });
    ok(out, "an incomplete exact detector must not pass a result through (it used to be silent)");
    equal((out as { isError?: boolean }).isError, true, "the withheld result is an error");
    ok(
      JSON.stringify(out).includes("broken-store"),
      "the message NAMES the unreadable store so the degradation is not silent",
    );
    ok(JSON.stringify(out).toLowerCase().includes("withheld"), "the message explains the state");
    // Repair the store and re-load: the rest of the suite runs against a complete set.
    writeFileSync(join(AGENT, "broken-store.json"), "{}");
    refreshSecrets();
  });

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
    strictEqual(
      await run({ toolName: "x", content: [{ type: "text", text: `publicKey=${PUBLIC_KEY_MATERIAL}` }] }),
      undefined,
      "camelCase public material must not be collected by the private/signing widening",
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
    ok(out, "patch expected");
    // The label is POSITION-INDEPENDENT of the store's contents: `store#N`, never
    // `store:path` (review round 10 — the path could carry a key-only secret).
    ok(
      JSON.stringify(out).includes("[REDACTED:tortoise-config#"),
      "the label is store#N",
    );
    ok(!JSON.stringify(out).includes("[REDACTED:tortoise-config:"), "the label must not embed a path");
  });

  // ── review round 7: path matcher (both directions) + env veto + `__proto__` ──
  await test("a secret under a secret-marked PATH is collected (the veto cancelled the path match)", async () => {
    for (const [line, value] of [
      [`credentials.key=${CREDENTIALS_PATH_SECRET}`, CREDENTIALS_PATH_SECRET],
      [`secrets.primary_key=${SECRETS_PATH_SECRET}`, SECRETS_PATH_SECRET],
      [`apiKeys.key=${API_KEYS_PATH_SECRET}`, API_KEYS_PATH_SECRET],
    ] as const) {
      const out = await run({ toolName: "bash", content: [{ type: "text", text: line }] });
      ok(out && !JSON.stringify(out).includes(value), `${line} must be redacted (used to leak)`);
    }
  });

  await test("a path SEGMENT that merely STARTS with a secret word is NOT a secret store", async () => {
    strictEqual(await run({ toolName: "x", content: [{ type: "text", text: `model=${TOKENIZER_MODEL}` }] }), undefined);
    strictEqual(await run({ toolName: "x", content: [{ type: "text", text: `name=${SECRETARY_NAME}` }] }), undefined);
  });

  await test("prefixed public-key leaves are NOT collected (over-redaction guard)", async () => {
    for (const line of [
      `gpg_public_key=${GPG_PUBLIC_KEY_MATERIAL}`,
      `rsa_public_key=${RSA_PUBLIC_KEY_MATERIAL}`,
      `app_public_key=${APP_PUBLIC_KEY_MATERIAL}`,
      `stripe_public_key=${STRIPE_PUBLIC_KEY_MATERIAL}`,
    ]) {
      strictEqual(await run({ toolName: "x", content: [{ type: "text", text: line }] }), undefined, line);
    }
  });

  await test("an env name the relational veto used to drop is still collected", async () => {
    for (const [name, value] of [
      ["PRIMARY_KEY", PRIMARY_ENV_SECRET],
      ["SECONDARY_KEY", SECONDARY_ENV_SECRET],
      ["CACHE_KEY", CACHE_ENV_SECRET],
      ["ID_KEY", ID_ENV_SECRET],
    ] as const) {
      const out = await run({ toolName: "bash", content: [{ type: "text", text: `${name}=${value}` }] });
      ok(out && !JSON.stringify(out).includes(value), `${name} env value must be redacted (used to leak)`);
    }
  });

  await test("an own `__proto__` key survives redaction and does not reparent the result", async () => {
    const details = JSON.parse('{"keep":"v","__proto__":{"x":"' + CONFIG_SECRET + '"}}') as Record<string, unknown>;
    equal(Object.getPrototypeOf(details), Object.prototype, "sanity: JSON.parse does not reparent");
    const out = await run({ toolName: "x", content: [{ type: "text", text: "no-secret" }], details });
    ok(out, "the secret under __proto__ must produce a patch");
    equal(Object.getPrototypeOf(out.details), Object.prototype, "the rebuilt object must not be reparented");
    ok(Object.prototype.hasOwnProperty.call(out.details, "__proto__"), "the __proto__ entry must survive");
    ok(!JSON.stringify(out.details).includes(CONFIG_SECRET), "the secret must be redacted");
  });

  // ── review round 8: label path leakage + unanchored credential WORDS ──────
  await test("a secret used as a config KEY is not re-emitted in the marker or warning", async () => {
    const out = await run({ toolName: "bash", content: [{ type: "text", text: `password=${AUTH_CONFIG_LEAF_SECRET}` }] });
    ok(out, "the leaf secret under a secret-named KEY must still be redacted");
    ok(!JSON.stringify(out).includes(AUTH_CONFIG_LEAF_SECRET), "the leaf secret must not survive");
    ok(
      !JSON.stringify(out).includes(KEY_ONLY_SECRET),
      "a KEY-ONLY secret (never a collected VALUE) must not be re-emitted in the marker or the warning",
    );
    ok(
      !JSON.stringify(out).includes(CONFIG_SECRET),
      "the secret in KEY position must not be re-emitted in the marker or the warning",
    );
  });

  await test("ordinary string-valued leaves containing a credential WORD are NOT collected", async () => {
    for (const line of [
      `secretary=${SECRETARY_NAME}`,
      `credentialsFile=${CREDENTIALS_FILE_VALUE}`,
      `passwordPolicy=${PASSWORD_POLICY_VALUE}`,
      `secretariatOffice=${SECRETARIAT_VALUE}`,
      `tokenizerPath=${TOKENIZER_PATH_VALUE}`,
    ]) {
      strictEqual(await run({ toolName: "x", content: [{ type: "text", text: line }] }), undefined, line);
    }
  });

  await test("anchored credential WORD leaves are still collected", async () => {
    for (const [leaf, value] of [
      ["clientSecret", CLIENT_SECRET_VALUE],
      ["secret_key", SECRET_KEY_LEAF_VALUE],
      ["dbPassword", DB_PASSWORD_VALUE],
      ["credentials", CREDENTIALS_LEAF_VALUE],
    ] as const) {
      const out = await run({ toolName: "bash", content: [{ type: "text", text: `${leaf}=${value}` }] });
      ok(out && !JSON.stringify(out).includes(value), `${leaf} must still be collected`);
    }
  });

  // ── review round 9: camelCase-PREFIX compound credential leaves ─────────────
  await test("camelCase-PREFIX credential leaves are still collected (round-8 narrowing guard)", async () => {
    for (const [leaf, value] of [
      ["secretKey", SECRET_KEY_LEAF_CAMEL_VALUE],
      ["secretAccessKey", SECRET_ACCESS_KEY_VALUE],
      ["awsSecretAccessKey", AWS_SECRET_ACCESS_KEY_VALUE],
      ["mySecretKey", MY_SECRET_KEY_VALUE],
      ["clientSecretKey", CLIENT_SECRET_KEY_VALUE],
      ["credentialsKey", CREDENTIALS_KEY_VALUE],
      ["secretValue", SECRET_VALUE_VALUE],
      ["passwordHash", PASSWORD_HASH_VALUE],
      ["passwordValue", PASSWORD_VALUE_VALUE],
      ["credentialId", CREDENTIAL_ID_VALUE],
      ["secretPassphrase", SECRET_PASSPHRASE_VALUE],
    ] as const) {
      const out = await run({ toolName: "bash", content: [{ type: "text", text: `${leaf}=${value}` }] });
      ok(out && !JSON.stringify(out).includes(value), `${leaf} must be collected (was emitted verbatim)`);
    }
  });

  await test("camelCase `privateKey`/`signingKey` store leaves ARE collected (env/store asymmetry)", async () => {
    for (const [leaf, value] of [
      ["privateKey", PRIVATE_KEY_VALUE],
      ["signingKey", SIGNING_KEY_VALUE],
    ] as const) {
      const out = await run({ toolName: "bash", content: [{ type: "text", text: `${leaf}=${value}` }] });
      ok(out && !JSON.stringify(out).includes(value), `${leaf} must be collected (was emitted verbatim)`);
    }
  });

  // ── negatives: no over-redaction, no touch when clean ──────────────────────
  await test("no secret anywhere → the result is left untouched", async () => {
    strictEqual(await run({ toolName: "x", content: [{ type: "text", text: "nothing to see" }] }), undefined);
  });

  await test("non-array, non-string content is not ours to touch", async () => {
    strictEqual(await run({ toolName: "x", content: 42 }), undefined);
  });

  // ⛔ review round 11: a BARE-STRING content was skipped outright, so
  // `content: "key=<secret>"` reached the model with no patch and no notice. The
  // sibling boundary converts to an ARRAY patch for exactly this reason (a bare-string
  // patch breaks downstream image normalization; an array of one text part does not).
  await test("a bare-string content carrying a secret IS redacted, as an array patch", async () => {
    const out = await run({ toolName: "bash", content: `cfg=${CONFIG_SECRET} trailing` });
    ok(out, "a string payload must not be skipped (it used to pass unredacted)");
    ok(Array.isArray(out.content), "the patch must be an ARRAY of content parts, not a bare string");
    ok(
      !JSON.stringify(out.content).includes(CONFIG_SECRET),
      "the secret must be gone from the patched string content",
    );
  });

  await test("a clean bare-string content is left untouched", async () => {
    strictEqual(await run({ toolName: "x", content: "a plain string" }), undefined);
  });

  // ⛔ review round 11: the store dump is this extension's headline scenario, and it
  // renders a value containing `"` or `\` JSON-ESCAPED. Only the literal form was
  // registered, so the escaped text reached the model while the literal was redacted.
  await test("a secret containing a quote/backslash is redacted from its ESCAPED form", async () => {
    const raw = 'p@ss"word\\123456';
    writeFileSync(join(AGENT, "escaped-store.json"), JSON.stringify({ password: raw }));
    // The secret set is CACHED (CACHE_MS) and loaded at import, so the new store must be
    // re-read — writing the fixture alone would test nothing (the first draft of this test
    // "failed" for exactly that reason, not because the fix was missing).
    refreshSecrets();
    const dump = JSON.stringify({ password: raw });
    const out = await run({ toolName: "bash", content: [{ type: "text", text: dump }] });
    ok(out, "the escaped form of a configured secret must be redacted (it used to pass)");
    ok(
      !JSON.stringify(out.content).includes(JSON.stringify(raw).slice(1, -1)),
      "the JSON-escaped encoding must not survive into the result",
    );
    // ONE secret in two encodings must still be ONE marker: a second `ordinal` advance
    // would emit `escaped-store#1` AND `escaped-store#2`, and the warning would
    // over-report the count.
    const flat = JSON.stringify(out.content);
    ok(
      new Set(flat.match(/escaped-store#\d+/g) ?? []).size <= 1,
      "the escaped variant must not mint a DISTINCT second label for the same secret",
    );
    ok(/1 secret pattern\(s\) REDACTED/.test(flat), "the count must be 1, not 2");
  });

  // ⛔ review round 11: `sk-`/`tt_` were unbounded and allowed `-`, so ordinary slugs
  // were redacted — and on a read→write round trip the MARKER is what gets persisted.
  // ⛔ review round 11, P0: a store larger than the scan cap hit a bare `continue`, so it
  // was dropped with NO degradation entry — "no hit" was reported over an UNSCANNED store
  // and its secrets passed through unredacted, while every sibling failure arm (EACCES,
  // truncated JSON) withheld. The cap is reachable (models-store.json is ~240 KB).
  await test("a store over the scan cap WITHHOLDS and names itself, it is not silently skipped", async () => {
    const big = join(AGENT, "oversized-store.json");
    writeFileSync(big, JSON.stringify({ apiKey: "oversizedsecretvalue0007", pad: "x".repeat(2_200_000) }));
    refreshSecrets();
    const out = await run({ toolName: "read", content: [{ type: "text", text: "hello" }] });
    ok(out, "an unscannable store must not report 'no secret' over its own contents");
    equal((out as { isError?: boolean }).isError, true, "the result is withheld as an error");
    ok(JSON.stringify(out).includes("oversized-store"), "the degradation NAMES the store");
    // Drop it and reload so the rest of the suite runs against a complete, scannable set.
    rmSync(big, { force: true });
    refreshSecrets();
    strictEqual(await run({ toolName: "x", content: [{ type: "text", text: "clean again" }] }), undefined);
  });

  // ⛔ review round 11: `sk-`/`tt_` were unbounded and allowed `-`, so ordinary slugs
  // were redacted — and on a read→write round trip the MARKER is what gets persisted.
  // The first attempt at this fix (an alnum-only, bounded tail) was a FAIL-OPEN: it lost
  // `sk-proj-`, `sk-or-v1-` and `sk-ant-`, the key families this fleet actually ships,
  // and a `{20,64}` cap TRUNCATED a long key instead of replacing it. Both directions are
  // pinned below: the slug stays out, every real family stays in, and the whole key goes.
  await test("an ordinary `sk-`/`tt_` prefixed slug is NOT redacted", async () => {
    strictEqual(
      await run({ toolName: "x", content: [{ type: "text", text: "sk-learn-machine-learning-course-notes" }] }),
      undefined,
      "a hyphenated slug is not an OpenAI key",
    );
    strictEqual(
      await run({ toolName: "x", content: [{ type: "text", text: "tt_2026_10_19_incident_review_notes" }] }),
      undefined,
      "a dated notes slug is not a tt_ key",
    );
  });

  await test("every real `sk-` key FAMILY is still redacted (proj / or-v1 / ant / base62)", async () => {
    for (const key of [
      "sk-proj-" + "a1b2c3d4e5f6g7h8i9j0".repeat(2) + "-tail",
      "sk-or-v1-" + "0123456789abcdef".repeat(4),
      "sk-ant-api03-" + "Xy9z".repeat(12),
      "sk-" + "A1b2C3d4E5f6".repeat(4),
    ]) {
      const out = await run({ toolName: "bash", content: [{ type: "text", text: `launch with ${key} now` }] });
      ok(out, `${key.slice(0, 12)}… must be redacted (a rotated key has no other guard)`);
      ok(!JSON.stringify(out.content).includes(key), "no fragment of the key may survive");
    }
  });

  await test("a long key is redacted WHOLE, not truncated, by the pattern", async () => {
    const longKey = "sk-" + "Z".repeat(200);
    const out = await run({ toolName: "bash", content: [{ type: "text", text: `k=${longKey}` }] });
    ok(out, "a >64-char key must still be redacted");
    ok(
      !JSON.stringify(out.content).includes("Z".repeat(20)),
      "a bounded tail truncates the key and leaves the remainder behind — the whole value must go",
    );
  });

  await test("a hyphenated word is not an `sk-` key (left-anchored patterns)", async () => {
    strictEqual(await run({ toolName: "x", content: [{ type: "text", text: "task-management-best-practices" }] }), undefined);
  });

  await test("env REFERENCE templates are not collected as secrets", async () => {
    strictEqual(await run({ toolName: "x", content: [{ type: "text", text: "apiKey: $ZAI_API_KEY" }] }), undefined);
  });

  // ⛔ review round 12 (the residual the round-11 review recorded and did not fix): a node
  // the walk read as UNCHANGED was returned BY REFERENCE, so a value that materialises only
  // at serialization time — an own enumerable getter — was never scanned. The walk read the
  // getter ONCE, saw a clean value, and memoised the ORIGINAL node; `JSON.stringify` then
  // read it AGAIN and got the configured secret. Every pin below FAILS on the pre-fix code:
  // that code returned `undefined` (no patch, no notice) for each of them.
  await test("an own enumerable accessor is MATERIALISED — a second read cannot surface a secret", async () => {
    let reads = 0;
    const details: Record<string, unknown> = { note: "ok" };
    Object.defineProperty(details, "token", {
      enumerable: true,
      configurable: true,
      get() {
        reads++;
        // Clean to the guard, the stored credential to the serializer — the hostile shape.
        return reads === 1 ? "clean-first-read" : CONFIG_SECRET;
      },
    });
    const out = await run({ toolName: "read", content: [{ type: "text", text: "ok" }], details });
    ok(
      out,
      "an accessor-backed value must produce a patch; returning the original by reference leaves the live read in place",
    );
    equal(reads, 1, "the getter is invoked EXACTLY ONCE, so the value scanned is the value emitted");
    equal(
      Object.getOwnPropertyDescriptor(out.details, "token")?.get,
      undefined,
      "the accessor is replaced by a DATA property in the rebuild",
    );
    equal(out.details.token, "clean-first-read", "the materialised value is the one that was scanned");
    ok(
      !JSON.stringify(out.details).includes(CONFIG_SECRET),
      "serializing the patched details must not surface the secret (this is the leak path)",
    );
    // Sanity that the fixture really is hostile: the ORIGINAL still answers with the secret
    // on a later read, so the pre-fix pass-through was a genuine leak, not a test artifact.
    ok(JSON.stringify(details).includes(CONFIG_SECRET), "sanity: the original getter does return the secret on re-read");
  });

  await test("a secret read from a getter is redacted (the positive direction)", async () => {
    const details: Record<string, unknown> = {};
    Object.defineProperty(details, "apiKey", { enumerable: true, configurable: true, get: () => CONFIG_SECRET });
    const out = await run({ toolName: "read", content: [{ type: "text", text: "ok" }], details });
    ok(out, "a hit must produce a patch");
    ok(!JSON.stringify(out).includes(CONFIG_SECRET), "the getter-read secret must not survive");
    ok(JSON.stringify(out).includes("1 secret pattern(s) REDACTED"), "the redaction is reported as a redaction");
  });

  await test("an accessor on a nested node (and on an array INDEX) is materialised too", async () => {
    let reads = 0;
    const inner: Record<string, unknown> = {};
    Object.defineProperty(inner, "token", {
      enumerable: true,
      configurable: true,
      get() {
        reads++;
        return reads === 1 ? "nested-clean" : CONFIG_SECRET;
      },
    });
    const arr: unknown[] = [];
    arr.length = 1;
    Object.defineProperty(arr, "0", {
      enumerable: true,
      configurable: true,
      get() {
        reads++;
        return reads === 1 || reads === 2 ? "arr-clean" : CONFIG_SECRET;
      },
    });
    const out = await run({
      toolName: "read",
      content: [{ type: "text", text: "ok" }],
      details: { deep: { inner }, arr },
    });
    ok(out, "a nested accessor must produce a patch");
    equal(
      Object.getOwnPropertyDescriptor(out.details.deep.inner, "token")?.get,
      undefined,
      "the nested accessor is materialised",
    );
    equal(Object.getOwnPropertyDescriptor(out.details.arr, "0")?.get, undefined, "the array INDEX accessor is materialised");
    ok(!JSON.stringify(out.details).includes(CONFIG_SECRET), "no serialization read may surface the secret");
  });

  await test("a clean, deterministic accessor is materialised and ANNOUNCED (not silently rewritten)", async () => {
    const details: Record<string, unknown> = {};
    Object.defineProperty(details, "label", { enumerable: true, configurable: true, get: () => "plain-label" });
    const out = await run({ toolName: "read", content: [{ type: "text", text: "ok" }], details });
    ok(out, "a clean accessor still produces a patch (it is materialised, and that is not a redaction)");
    equal(out.details.label, "plain-label", "the materialised value is preserved");
    ok(
      out.content.some((p: { text?: string }) => (p.text ?? "").includes("resolved to plain data")),
      "the rewrite is announced, so the model's input is not silently changed",
    );
    ok(
      !JSON.stringify(out.content).includes("secret pattern(s) REDACTED"),
      "no false 'secret REDACTED' claim when nothing was redacted",
    );
  });

  await test("an accessor on a Map/Set container FAILS CLOSED (it cannot be materialised)", async () => {
    const map = new Map<string, unknown>([["k", "v"]]);
    Object.defineProperty(map, "token", { enumerable: true, configurable: true, get: () => CONFIG_SECRET });
    const out = await run({ toolName: "read", content: [{ type: "text", text: "ok" }], details: map });
    ok(out, "an accessor the rebuild cannot carry must withhold, not pass the original through");
    equal((out as { isError?: boolean }).isError, true, "the result is withheld as an error");
    ok(JSON.stringify(out).toLowerCase().includes("withheld"), "the state is announced");
    ok(!JSON.stringify(out).includes(CONFIG_SECRET), "nothing from the container is emitted");
  });

  // ⛔ review round 13: the Array/Map/Set arms iterate the CONTAINER (`for…of`), so a
  // NAMED own property was never scanned — and was dropped whenever the container was
  // rebuilt. Both directions are pinned; each FAILS on the pre-fix code (which returned
  // `undefined` for the first, and lost the property in the second).
  await test("a secret in a container's NAMED own property is SCANNED (indices/entries unchanged)", async () => {
    const arr: unknown[] = ["clean-member"];
    (arr as unknown as Record<string, unknown>).token = CONFIG_SECRET;
    const map = new Map<string, unknown>([["k", "v"]]);
    (map as unknown as Record<string, unknown>).token = CONFIG_SECRET;
    const set = new Set<unknown>(["member"]);
    (set as unknown as Record<string, unknown>).token = CONFIG_SECRET;
    const out = await run({ toolName: "read", content: [{ type: "text", text: "ok" }], details: { arr, map, set } });
    ok(out, "a secret in a container's NAMED property must produce a patch (it was returned by reference)");
    for (const name of ["arr", "map", "set"] as const) {
      const node = out.details[name] as Record<string, unknown>;
      ok(
        typeof node.token === "string" && node.token.startsWith("[REDACTED:"),
        `the named property of the ${name} is scanned and redacted like any other value`,
      );
    }
  });

  await test("an unchanged NAMED own property SURVIVES a container rebuild", async () => {
    const arr: unknown[] = [CONFIG_SECRET];
    (arr as unknown as Record<string, unknown>).note = "keep-this-array-note";
    const map = new Map<string, unknown>([["k", CONFIG_SECRET]]);
    (map as unknown as Record<string, unknown>).meta = "keep-this-map-meta";
    const set = new Set<unknown>([CONFIG_SECRET]);
    (set as unknown as Record<string, unknown>).label = "keep-this-set-label";
    class Row extends Array {
      batch = "keep-this-subclass-field";
    }
    const row = new Row();
    row.push(CONFIG_SECRET);
    const out = await run({ toolName: "read", content: [{ type: "text", text: "ok" }], details: { arr, map, set, row } });
    ok(out, "a hit in the container forces a rebuild");
    ok(!JSON.stringify(out).includes(CONFIG_SECRET), "the container's secret does not survive");
    equal((out.details.arr as unknown as Record<string, unknown>).note, "keep-this-array-note", "the array's named property survives");
    equal((out.details.map as unknown as Record<string, unknown>).meta, "keep-this-map-meta", "the Map's named property survives");
    equal((out.details.set as unknown as Record<string, unknown>).label, "keep-this-set-label", "the Set's named property survives");
    equal((out.details.row as unknown as Record<string, unknown>).batch, "keep-this-subclass-field", "an Array-subclass field survives");
    ok(out.details.row instanceof Row, "the Array subclass is preserved");
  });

  await test("a `\\uXXXX`-escaped (ensure_ascii) spelling of a secret is redacted", async () => {
    const out = await run({ toolName: "bash", content: [{ type: "text", text: `dump={"apiKey":"${UNICODE_ESCAPED_SECRET}"}` }] });
    ok(out, "an ASCII-escaping serializer's spelling of a NON-ASCII secret must be redacted");
    ok(!JSON.stringify(out).includes(UNICODE_ESCAPED_SECRET), "the escaped form must not survive");
    // The literal form is still covered (and is the same secret, not a second hit).
    const literal = await run({ toolName: "bash", content: [{ type: "text", text: `dump=${UNICODE_SECRET}` }] });
    ok(literal && !JSON.stringify(literal).includes(UNICODE_SECRET), "the literal spelling is still redacted");
  });

  await test("a NUMERIC store value is collected and redacted", async () => {
    const out = await run({ toolName: "bash", content: [{ type: "text", text: `apiKey=${NUMERIC_KEY_VALUE}` }] });
    ok(out, "a numeric configured secret must be collected (it used to be skipped by " + "typeof node === 'string')");
    ok(!JSON.stringify(out).includes(String(NUMERIC_KEY_VALUE)), "the numeric value must not survive");
  });

  await test("a REFERENCE template (bare, with a short default, or NESTED) is not collected", async () => {
    strictEqual(
      await run({ toolName: "x", content: [{ type: "text", text: `apiKey: ${REFERENCE_WITH_DEFAULT}` }] }),
      undefined,
      "a template that names a variable is not the credential, even when it carries a short default",
    );
    // The bare forms stay skipped too (the round-1 negative must not regress).
    strictEqual(await run({ toolName: "x", content: [{ type: "text", text: "apiKey: $ZAI_API_KEY" }] }), undefined);
    strictEqual(await run({ toolName: "x", content: [{ type: "text", text: "apiKey: ${ZAI_API_KEY}" }] }), undefined);
    // A NESTED `${A:-${B}}` is still a template, not a literal (a `[^}]*` matcher stopped
    // at the first `}` and collected the whole thing as a secret).
    strictEqual(
      await run({ toolName: "x", content: [{ type: "text", text: `apiKey: ${REFERENCE_NESTED}` }] }),
      undefined,
      "a nested reference is a template too — it is not the credential",
    );
  });

  await test("the literal DEFAULT of a reference template IS collected", async () => {
    const out = await run({ toolName: "bash", content: [{ type: "text", text: `k=${REFERENCE_LITERAL_DEFAULT}` }] });
    ok(out, "the literal default is the value used when the variable is unset — it must be collected");
    ok(!JSON.stringify(out).includes(REFERENCE_LITERAL_DEFAULT), "the literal default must not survive");
  });

  await test("a NUMERIC value is collected by its LEAF name, never by a secret-marked PATH", async () => {
    // The path alone is not a credential signal for a NUMBER: a credential cache's
    // `expires_at` timestamp was redacted out of every result that mentioned it.
    strictEqual(
      await run({ toolName: "x", content: [{ type: "text", text: `expires ${CREDENTIALS_EXPIRES_AT}` }] }),
      undefined,
      "a numeric timestamp under a `credentials` path is ordinary data, not a secret",
    );
    // ...but the exemption is the ordinary-numeric VOCABULARY, not every number: a numeric
    // credential whose only signal is the secret-marked path must still be collected.
    for (const [name, value] of [
      ["credentials.key", CREDENTIALS_KEY_NUMERIC],
      ["tokens.access", TOKENS_ACCESS_NUMERIC],
    ] as const) {
      const out = await run({ toolName: "bash", content: [{ type: "text", text: `v=${value}` }] });
      ok(out, `a numeric credential under \`${name}\` must still be collected (round 7's rule)`);
      ok(!JSON.stringify(out).includes(String(value)), `${name}: the numeric credential must not survive`);
    }
  });

  await test("a `\\u00XX` HTML-escape (Go `SetEscapeHTML`) spelling of a secret is redacted", async () => {
    const out = await run({ toolName: "bash", content: [{ type: "text", text: `k=${HTML_ESCAPED_SECRET}` }] });
    ok(out, "`&`/`<`/`>` are `\\u00XX`-escaped by Go's encoder, so that spelling must be redacted too");
    ok(!JSON.stringify(out).includes(HTML_ESCAPED_SECRET), "the HTML-escaped form must not survive");
    const literal = await run({ toolName: "bash", content: [{ type: "text", text: `k=${HTML_ESCAPE_SECRET}` }] });
    ok(literal && !JSON.stringify(literal).includes(HTML_ESCAPE_SECRET), "the literal spelling is still redacted");
  });

  await test("an ENV secret's JSON-ESCAPED spelling is redacted (the store arm's rule)", async () => {
    const escaped = JSON.stringify(ENV_QUOTED_SECRET).slice(1, -1);
    const out = await run({ toolName: "bash", content: [{ type: "text", text: `k=${escaped}` }] });
    ok(out, "the escaped spelling of an env secret must be redacted, exactly like a store's");
    ok(!JSON.stringify(out).includes(escaped), "the escaped form must not survive");
    const literal = await run({ toolName: "bash", content: [{ type: "text", text: `k=${ENV_QUOTED_SECRET}` }] });
    ok(literal && !JSON.stringify(literal).includes(ENV_QUOTED_SECRET), "the literal spelling is still redacted");
  });

  await test("a credential-SHAPED store file name cannot nest a marker inside a marker", async () => {
    const out = await run({ toolName: "bash", content: [{ type: "text", text: `k=${SHAPED_STORE_SECRET}` }] });
    ok(out, "the shaped store's secret is still redacted");
    const serialized = JSON.stringify(out);
    ok(!serialized.includes(SHAPED_STORE_SECRET), "the store's secret must not survive");
    ok(
      !serialized.includes("[REDACTED:[REDACTED:"),
      "the label scrub replaces with a bare word, so a credential-shaped store NAME cannot produce a marker inside a marker",
    );
    ok(!serialized.includes(SHAPED_STORE_NAME), "the raw store name is not emitted");
  });

  await test("a store file NAME that is a collected secret is scrubbed out of the label", async () => {
    const out = await run({ toolName: "bash", content: [{ type: "text", text: `v=${STORE_NAME_SECRET}` }] });
    ok(out, "the store's secret is redacted");
    ok(
      !JSON.stringify(out).includes(STORE_NAME_SECRET),
      "a store whose FILE NAME is itself a secret must not re-emit it in the marker or the warning",
    );
  });

  // ⛔ review round 11: an agent dir that EXISTS but cannot be ENUMERATED fell back to
  // the four FALLBACK_STORES and reported "no hit" over every store it never named — the
  // same silent-skip class the >2 MB arm closed. ENOTDIR is used rather than `chmod 000`
  // so the pin holds when the suite runs as root. An ABSENT dir stays a pass-through:
  // nothing exists to lose, and making it degrade would withhold every result on a fresh box.
  await test("an agent dir that cannot be ENUMERATED degrades; an ABSENT one does not", async () => {
    rmSync(AGENT, { recursive: true, force: true });
    mkdirSync(AGENT, { recursive: true });
    writeFileSync(join(AGENT, "plain.json"), "{}");
    refreshSecrets();
    strictEqual(
      await run({ toolName: "x", content: [{ type: "text", text: "clean" }] }),
      undefined,
      "a readable agent dir is not a degradation",
    );
    rmSync(AGENT, { recursive: true, force: true });
    writeFileSync(AGENT, "not a directory");
    refreshSecrets();
    const out = await run({ toolName: "read", content: [{ type: "text", text: "hi" }] });
    ok(out, "an unenumerable agent dir must withhold — it used to fall back silently");
    equal((out as { isError?: boolean }).isError, true, "the result is withheld as an error");
    ok(JSON.stringify(out).includes("agent-dir-unreadable"), "the degradation is NAMED");
    rmSync(AGENT, { force: true });
    refreshSecrets();
    strictEqual(
      await run({ toolName: "x", content: [{ type: "text", text: "clean" }] }),
      undefined,
      "an ABSENT agent dir is not a degradation (a fresh box must not withhold everything)",
    );
  });

  // ── cleanup + summary ──────────────────────────────────────────────────────
  try { rmSync(HOME, { recursive: true, force: true }); } catch { /* best effort */ }
  console.log(`\n${passed} passed, ${failed} failed`);
  if (failed > 0) process.exit(1);
}

main();
