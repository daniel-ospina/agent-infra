/**
 * secret-redactor — strip configured secrets out of TOOL RESULTS before they are
 * shown to the model and before they are persisted into the artifacts that leaked
 * in #5109 (session transcripts, task-sessions, audit.jsonl, state/).
 *
 * WHY THIS EXISTS (the mechanism, measured 2026-10-04):
 *   The live Tortoise API key was found in 301 files under ~/.pi — 300 of them
 *   mode 0644 — because every artifact that records a tool result records it
 *   VERBATIM. One `cat ~/.pi/agent/tortoise-config.json` (or a script that dumped
 *   the config to "check the API URL") is therefore permanent, world-readable, and
 *   copied into every subsequent log. Nothing anywhere inspected tool output for
 *   the harness's own configured secrets: the config file was 0600 and everything
 *   that READ it was not.
 *
 * SCOPE, STATED ACCURATELY: this hook covers the RESULT of a tool — the surface that
 * produced all 300 leaked copies. It does NOT cover a secret typed literally into a
 * tool CALL's arguments (persisted as `arguments` on the toolCall entry), the bash
 * tool's full-output temp log, or anything a non-pi process writes (e.g. a script
 * writing /tmp/live.json). Those are open and tracked on #5109.
 *
 * ⛔ KNOWN LIMITATIONS (deliberate, not oversights — read before "fixing" them):
 *   Three review rounds found 23 defects in this file and each round found a shape
 *   the previous one missed. That is the signature of the wrong seam: a perfect
 *   in-process redactor would have to model every value an arbitrary tool can return.
 *   Rather than grow the recognizer, the following are DOCUMENTED and left, with the
 *   residual on #5109:
 *     - a redacted non-plain instance is returned as PLAIN DATA (own enumerable
 *       strings only): `#private` slots and non-enumerable/symbol props cannot be
 *       reproduced, so a rebuild would hand back a half-initialised object whose
 *       methods throw. Losing `instanceof` is the safer of the two failures;
 *     - symbol-keyed and non-enumerable properties are not traversed (so a secret in
 *       one is not redacted);
 *     - a secret used as a STRING key (Map or plain object) is redacted, which renames
 *       the key — the entry remains, under `[REDACTED:…]`;
 *     - a non-8-bit typed array (Uint16Array, Float64Array, …) cannot hold a redacted
 *       byte sequence of a different length without changing its element count, so a
 *       secret found in one FAILS CLOSED rather than being silently dropped;
 *     - a secret in a `DataView`, a raw `ArrayBuffer`, or a NON-STRING `Map` key is
 *       not scanned: the byte branch excludes `DataView`, a raw `ArrayBuffer` has no
 *       enumerable entries, and only string `Map` keys are redacted (they are passed
 *       through untouched, not withheld);
 *     - only exact configured values and the five credential shapes are caught; an
 *       unknown-format secret in a store not under ~/.pi/agent is not;
 *     - camelCase credential-key leaves are collected only for the shapes the LEAF
 *       matcher names (`apiKey`, `secretKey`, `secretPassphrase`, `privateKey`,
 *       `signingKey`, …). An unlisted camelCase spelling (`encryptionKey`,
 *       `accessKey`) is not collected from a STORE, while the env collector accepts
 *       any `*_KEY` name; that asymmetry is this one (review P2);
 *     - a store that EXISTS but cannot be read or parsed (EACCES, truncated JSON) is
 *       NOT silently dropped: the exact detector is then incomplete, so the handler
 *       FAILS CLOSED and names the store. A store that is simply ABSENT is not a
 *       degradation — there are no values to lose — so a fresh machine is unaffected.
 *       ⛔ SCOPE OF THAT FAIL-CLOSED, stated because it is wider than "a secret
 *       store": EVERY top-level `*.json` in ~/.pi/agent is scanned (so a store added
 *       later is covered), which includes files that cannot hold secrets —
 *       `settings.json`, `skill-reads.json`, `models-store.json`. So ONE malformed or
 *       mid-write file there withholds EVERY tool result for the whole 30 s cache
 *       window, not just results that could contain a secret. That is the deliberate
 *       over-block side of the trade (an incomplete exact detector must not report
 *       "no hit" as "no secret"), and the notice NAMES the store so the cause is
 *       visible. It is over-blocking, never a leak. Narrowing the scanned set to
 *       secret-bearing stores is the open question on #5109, and it reduces coverage,
 *       so it is not done silently here;
 *     - a store larger than 2 MB is SKIPPED (`statSync(p).size > 2_000_000`) without
 *       being recorded as a degradation: too large to scan affordably, so its values
 *       are simply not collected. `models-store.json` is already ~240 KB in this
 *       fleet, so the cap is reachable as the provider catalogue grows;
 *     - MIN_LEN (12) FLOORS EVERY COLLECTION SITE, so a configured credential SHORTER
 *       THAN 12 CHARACTERS IS NOT REDACTED. The floor exists because redacting short
 *       strings over-redacts ordinary tool output; it is the reason "a configured
 *       secret is caught" is true only at or above 12 characters;
 *     - this is the SECOND redactor at the `tool_result` boundary. `extensions/secret-echo-guard.ts`
 *       is default-ON (`SECRET_ECHO_GUARD !== "0"`) and already redacts
 *       `content`/`details` there, with a min-length floor, a hooks registry and
 *       `.env` harvesting. This one adds EXACT-value matching from the stores/env on
 *       top, and the two compose: pi chains patches, so a result the echo-guard has
 *       already redacted is re-scanned (and, on a degraded store, replaced wholesale
 *       by the WITHHELD notice — see the scope bullet above). Which guard owns the
 *       boundary is deliberately left open on #5109 rather than decided by this file.
 *   The durable fix for the class is to redact at the point of PERSISTENCE (one
 *   choke point) rather than recognise values in flight — and, for this incident,
 *   ROTATION, which is what makes the 301 existing copies moot.
 *
 * Two detectors, deliberately:
 *   1. EXACT — the values themselves, read from the configured secret stores.
 *   2. PATTERN — credential shapes (tt_, ghp_, sk-, xox…), so a key is still caught
 *      AFTER ROTATION, when the exact-value store is stale.
 * The value is never printed, logged, or returned; only a label and a count.
 *
 * Over-redaction is itself a harm: a false positive rewrites what the model is
 * reading and, on a read→write round trip, persists the marker into the file. So the
 * patterns are LEFT-ANCHORED, env REFERENCE templates ($VAR / ${VAR}) are never
 * secrets, and a result in which NO secret is found is returned untouched. A
 * TRAVERSAL FAILURE is treated separately and FAILS CLOSED: an incomplete scan is not
 * evidence of absence, so "no hit recorded yet" is not the same statement as "no
 * secret present" (the earlier code returned the original result on any throw, which
 * re-emitted a secret sitting in a later, unvisited sibling). For the same reason, a
 * configured store that exists but cannot be read or parsed also fails closed: the
 * exact-value set is then partial and the handler withholds, naming the store.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { readFileSync, readdirSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

type Secret = { label: string; value: string };

const AGENT_DIR = join(homedir(), ".pi", "agent");
const CACHE_MS = 30_000;
const MIN_LEN = 12;
/** Read regardless of readdir: the known fleet stores. */
const FALLBACK_STORES = ["tortoise-config.json", "jev-config.json", ".mcp.json", "models.json"];

const SECRET_WORD = "(secret|password|passwd|credentials?)";

/** Secret-ish on the LEAF key (`authToken`, `apiKey`, `clientSecret`, `OPENAI_KEY`…)
 *  or on the path. The `(^|[_-])key$` alternative mirrors the env collector's `_KEY`
 *  suffix so a SCREAMING_SNAKE literal in a config store (`OPENAI_KEY`, `MASTER_KEY`,
 *  `PRIVATE_KEY`…) is collected too; without it the SAME value was redacted from the
 *  environment and emitted verbatim from `.mcp.json` (review round 5). Camel-case
 *  `*Key` is deliberately NOT included: a bare `key$` would also match `monkey`/
 *  `sortKey`/`foreignKey` and redact ordinary data (over-redaction is a harm) EXCEPT
 *  for the unambiguous credential adjectives, which are matched explicitly
 *  (`(private|signing)[_-]?key$`): `privateKey` / `signingKey` are private key material
 *  and a private HMAC/JWT signing secret, and they are the ONE camelCase `*Key` family
 *  the env collector caught (`JWT_SIGNING_KEY`) while a store leaf did not — a configured
 *  secret emitted verbatim (review P2).
 *  `NON_SECRET_KEY_RE` is the snake_case half of that same guard: `_key$` accepts
 *  EVERY `*_key` leaf, so `sort_key`/`foreign_key`/`primary_key` — the snake_case
 *  spelling of the very words above — were redacted too (review round 6). The env
 *  collector's `_KEY` suffix names a CREDENTIAL shape; it is not a licence to treat
 *  every `_key` field as one.
 *  Each credential WORD in `SECRET_WORD` must be a WHOLE segment (`secret`, `secret_key`,
 *  `my_secret`, `credentials_file`) or a camelCase SUFFIX (`clientSecret`, `dbPassword`),
 *  never an arbitrary substring: the unanchored form matched ordinary data — `secretary`,
 *  `credentialsFile`, `passwordPolicy`, `secretariatOffice` were collected and rewritten
 *  out of tool results (review round 8). `token` was already anchored this way.
 *  That anchoring then under-narrowed the OTHER direction: a camelCase PREFIX compound
 *  (`secretKey`, `secretAccessKey`, `passwordHash`, `credentialId`) puts the credential
 *  word neither in a whole `_`/`-` segment nor at the leaf END, so those leaves were
 *  emitted verbatim — a configured secret under an ordinary credential field name, which
 *  no pattern catches. `SECRET_COMPOUND_RE` re-admits the prefix family, but only when
 *  EVERY following word is itself credential vocabulary; that is what keeps round 8's
 *  negatives negative (`credentialsFile` → `File`, `passwordPolicy` → `Policy`,
 *  `secretary` → `ary`, `secretariatOffice` → `ariatOffice` — none is a compound word)
 *  (review round 9). `passphrase` is credential vocabulary too: `secretPassphrase` was
 *  collected before the round-8 anchoring and emitted verbatim after it (review P2). */
const SECRET_COMPOUND_WORD = "(key|value|hash|id|token|secret|access|passphrase)";
const SECRET_COMPOUND_RE = `${SECRET_WORD}([_-]?${SECRET_COMPOUND_WORD})+$`;
const SECRET_LEAF_RE = new RegExp(
  `(api[_-]?key|access[_-]?token|refresh[_-]?token|token$|(^|[_-])${SECRET_WORD}([_-]|$)|${SECRET_WORD}$|${SECRET_COMPOUND_RE}|(private|signing)[_-]?key$|(^|[_-])key$)`,
  "i",
);
/** Leaves that END in `key` but hold ordinary relational/identity data, not a
 *  credential (`sort_key`, `foreign_key`, `primary_key`, `cache_key`, `partition_key`,
 *  `dedup_key`, …) plus the bare, ambiguous `key`. Vetoed from `SECRET_LEAF_RE`'s
 *  `_key$` alternative ONLY — never from a `SECRET_PATH_RE` match and never from
 *  the env collector: a relational vocabulary describes JSON columns, not env var
 *  names or an explicitly secret-marked path. Applying it to the whole disjunction
 *  emitted `secrets.primary_key` / `credentials.key` / `apiKeys.key` verbatim and
 *  dropped `PRIMARY_KEY` / `SECONDARY_KEY` / `CACHE_KEY` / `ID_KEY` from the env
 *  set entirely (review round 7). */
const NON_SECRET_KEY_RE = /(^key$|^(foreign|primary|secondary|sort|cache|partition|dedup|shard|id)[_-]?key$)/i;
/** A path SEGMENT that names a secret store. Anchored at the segment END
 *  (`(\.|$)`) so the word must be the WHOLE segment: the unanchored form also
 *  matched `tokenizer` / `secretary` and redacted ordinary config data (review
 *  round 7). */
const SECRET_PATH_RE = /(^|\.)(secret|secrets|credential|credentials|password|passwd|token|tokens|api[_-]?keys?)(\.|$)/i;
/** PUBLIC values are not secrets. Tested on the LEAF only — a `publicProfile.apiKey`
 *  must still be collected (testing the whole path excluded the subtree). The
 *  `*_key` forms are widened here because `SECRET_LEAF_RE` now collects `_KEY`
 *  leaves: without this, `public_key` / `ssh_public_key` would be redacted as if
 *  they were credentials (review round 5). The exemption is a SUFFIX test
 *  (`(^|[_-])(public|pub|gpg)[_-]?key$`), so a PREFIXED spelling —
 *  `gpg_public_key`, `rsa_public_key`, `app_public_key`, `stripe_public_key` — is
 *  exempt too (the leaf-anchored form collected all of them as credentials; review
 *  round 7). `signing` is deliberately NOT a public-key word: the round-5 form
 *  dropped its leading `^`, so ANY leaf *ending* in `signing_key` was exempted — and
 *  `TOKEN_SIGNING_KEY` / `JWT_SIGNING_KEY` is a PRIVATE HMAC/JWT signing secret,
 *  not public key material, so it was emitted verbatim (review round 6). */
const PUBLIC_RE = /(^public$|(^|[_-])(public|pub|gpg)[_-]?key$)/i;
const PUBLIC_ANY_RE = /public|pub_?key|gpg_?key/i;

/** A value that is a REFERENCE to an env var, not a credential (tested trimmed). */
const REFERENCE_RE = /^\$\{?[A-Za-z_][A-Za-z0-9_]*\}?$/;

/** Credential shapes that survive rotation. LEFT-ANCHORED. */
const PATTERNS: Array<[string, RegExp]> = [
  ["tt_api_key", /(?<![A-Za-z0-9_])tt_[A-Za-z0-9_-]{20,}/g],
  ["github_pat", /(?<![A-Za-z0-9_])github_pat_[A-Za-z0-9_]{20,}/g],
  ["github_token", /(?<![A-Za-z0-9_])gh[pousr]_[A-Za-z0-9]{20,}/g],
  ["openai_key", /(?<![A-Za-z0-9_-])sk-[A-Za-z0-9_-]{20,}/g],
  ["slack_token", /(?<![A-Za-z0-9_])xox[baprs]-[A-Za-z0-9-]{10,}/g],
];

const leafOf = (path: string): string => path.split(".").pop() ?? path;
const isReference = (v: string): boolean => REFERENCE_RE.test(v.trim());

function collectFromJson(label: string, file: string, into: Secret[], degraded: string[]): void {
  let raw: string;
  try {
    raw = readFileSync(file, "utf8");
  } catch (err) {
    // A store that is simply ABSENT has no values to lose and is not a degradation;
    // one that EXISTS but cannot be read IS — the exact detector would otherwise
    // report "no secret" over an incomplete set (fail-closed contract; see below).
    if ((err as { code?: string }).code !== "ENOENT") degraded.push(label);
    return;
  }
  let obj: unknown;
  try {
    obj = JSON.parse(raw);
  } catch {
    // A truncated / hand-edited store is the same incomplete-scan case as EACCES.
    degraded.push(label);
    return;
  }
  let ordinal = 0;
  const walk = (node: unknown, path: string): void => {
    if (typeof node === "string") {
      const leaf = leafOf(path);
      // The relational veto applies to the widened `_key$` LEAF rule only: a path
      // match is an explicit secret marker and must not be cancelled by a leaf name
      // (`secrets.primary_key`, `credentials.key`, `apiKeys.key` were emitted
      // verbatim when the veto covered the whole disjunction; review round 7).
      const secretKey =
        (SECRET_LEAF_RE.test(leaf) && !NON_SECRET_KEY_RE.test(leaf)) || SECRET_PATH_RE.test(path);
      if (node.length >= MIN_LEN && !isReference(node) && secretKey && !PUBLIC_RE.test(leaf)) {
        // The label is POSITION-INDEPENDENT of the store's contents (`store#N`), never
        // `store:path`. The path is built from the store's KEYS and a key can itself BE
        // a secret that is never a collected VALUE (`{"auths": {"<secret>": {…}}}`), so
        // embedding the path re-emitted that secret in the marker AND in the appended
        // warning — the class this extension closes. `scrubLabels` could only scrub a key
        // that ALSO happened to be a value, which is why the old pin was vacuous (review
        // finding). The store NAME is kept (it says where the leak came from) and is
        // itself scrubbed; the ordinal keeps two secrets from the same store distinct.
        ordinal += 1;
        into.push({ label: `${label}#${ordinal}`, value: node });
      }
      return;
    }
    if (Array.isArray(node)) {
      node.forEach((v, i) => walk(v, `${path}.${i}`));
      return;
    }
    if (node && typeof node === "object") {
      for (const [k, v] of Object.entries(node as Record<string, unknown>)) walk(v, `${path}.${k}`);
    }
  };
  walk(obj, label);
}

/** The one substitution both a label and the degraded-store notice go through: the
 *  STORE NAME is filesystem-derived, so a file named after a secret (`<apiKey>.json`)
 *  must not reach the marker or the warning either. Runs over the already-length-sorted
 *  list, so a longer secret is replaced before its shorter substring. */
function scrubWith(text: string, secrets: Secret[]): string {
  let out = text;
  for (const s of secrets) {
    if (s.value && out.includes(s.value)) out = out.split(s.value).join("[REDACTED]");
  }
  for (const [label, re] of PATTERNS) {
    out = out.replace(new RegExp(re.source, re.flags), `[REDACTED:${label}]`);
  }
  return out;
}

/** A label is `store#N`, and the STORE NAME is filesystem-derived — a file named after
 *  a secret (`<apiKey>.json`) would put it in the marker and the warning. The path is no
 *  longer embedded at all (a path is built from the store's KEYS and a key can itself BE
 *  a secret that is never a collected value; review round 10), so this scrub is the
 *  belt-and-braces for the name. */
function scrubLabels(secrets: Secret[]): void {
  for (const s of secrets) s.label = scrubWith(s.label, secrets);
}

/** Every top-level *.json in the agent dir (a store added later is covered), falling
 *  back to the known stores when readdir itself fails — otherwise a readdir error
 *  silently reduced the exact detector to nothing (review finding). Runs OFF the hot
 *  path (see the cache below), which is what makes scanning all of them affordable. */
function loadSecrets(): { secrets: Secret[]; degraded: string[] } {
  const out: Secret[] = [];
  const degraded: string[] = [];
  let names: string[] = [];
  try {
    names = readdirSync(AGENT_DIR).filter((fn) => fn.endsWith(".json"));
  } catch {
    names = [];
  }
  if (names.length === 0) names = FALLBACK_STORES;
  for (const fn of names) {
    const p = join(AGENT_DIR, fn);
    const label = fn.replace(/\.json$/, "");
    try {
      if (statSync(p).size > 2_000_000) continue;
    } catch (err) {
      if ((err as { code?: string }).code !== "ENOENT") degraded.push(label);
      continue;
    }
    collectFromJson(label, p, out, degraded);
  }
  // Configured secrets in the process environment. `_KEY$` is included (SSH_PRIVATE_KEY,
  // ENCRYPTION_KEY, MASTER_KEY… would otherwise be missed); PUBLIC ones are excluded.
  for (const [k, v] of Object.entries(process.env)) {
    if (
      typeof v === "string" &&
      v.length >= MIN_LEN &&
      !isReference(v) &&
      /(API_KEY|_KEY|_TOKEN|_SECRET|_CREDENTIALS?|PASSWORD)$/i.test(k) &&
      // The relational veto is NOT applied here: it is a JSON-column vocabulary, and
      // on a variable name the `_KEY$` shape is itself the credential signal — the
      // veto dropped `PRIMARY_KEY`/`SECONDARY_KEY`/`CACHE_KEY`/`ID_KEY` from the env
      // set entirely (review round 7).
      !PUBLIC_ANY_RE.test(k)
    ) {
      out.push({ label: `env:${k}`, value: v });
    }
  }
  const result = out.filter((s) => s.value.length >= MIN_LEN).sort((a, b) => b.value.length - a.value.length);
  scrubLabels(result);
  // The degraded names go into a message too, so scrub them the same way as a label.
  return { secrets: result, degraded: degraded.map((d) => scrubWith(d, result)) };
}

let cache: Secret[] = [];
/** Stores that EXIST but could not be read or parsed. Non-empty ⇒ the exact detector is
 *  incomplete ⇒ the handler fails closed and names them (it used to be silent). */
let degradedStores: string[] = [];
function refresh(): void {
  try {
    const loaded = loadSecrets();
    cache = loaded.secrets;
    degradedStores = loaded.degraded;
  } catch {
    /* keep the previous cache */
  }
}

/** Re-read the configured stores immediately (the 30s timer does the same). Exported so
 *  the suite can re-load after it repairs a deliberately-broken store. */
export function refreshSecrets(): void {
  refresh();
}
function secrets(): Secret[] {
  return cache;
}

function redactString(text: string, secrets: Secret[], hits: Set<string>): string {
  let out = text;
  for (const s of secrets) {
    if (s.value && out.includes(s.value)) {
      out = out.split(s.value).join(`[REDACTED:${s.label}]`);
      hits.add(s.label);
    }
  }
  for (const [label, re] of PATTERNS) {
    const fresh = new RegExp(re.source, re.flags);
    if (!fresh.test(out)) continue;
    hits.add(label);
    out = out.replace(new RegExp(re.source, re.flags), `[REDACTED:${label}]`);
  }
  return out;
}

/**
 * Byte-precise redaction of a view's bytes. Returns a Buffer carrying the
 * replacements, or null when nothing matched (so the caller returns the original).
 *
 * Both directions are byte-preserving: exact secrets are matched as BYTE SEQUENCES
 * (a non-ASCII secret survives), and the credential PATTERNS are ASCII, so scanning
 * through a latin1 view — one char per byte — cannot rewrite a byte it did not match.
 * The previous version decoded the WHOLE buffer as UTF-8 and re-encoded it, which
 * destroyed every non-UTF-8 byte in the same buffer (`ff fe` became `ef bf bd`), a
 * correctness regression on any binary payload that merely embedded a credential.
 */
function scanBytes(view: Uint8Array, secrets: Secret[], hits: Set<string>): Buffer | null {
  let buf = Buffer.from(view.buffer, view.byteOffset, view.byteLength);
  let changed = false;
  for (const s of secrets) {
    if (!s.value) continue;
    const needle = Buffer.from(s.value, "utf8");
    if (needle.length === 0) continue;
    let idx = buf.indexOf(needle);
    while (idx !== -1) {
      hits.add(s.label);
      changed = true;
      const marker = Buffer.from(`[REDACTED:${s.label}]`, "utf8");
      buf = Buffer.concat([buf.subarray(0, idx), marker, buf.subarray(idx + needle.length)]);
      idx = buf.indexOf(needle, idx + marker.length);
    }
  }
  let text = buf.toString("latin1");
  for (const [label, re] of PATTERNS) {
    const fresh = new RegExp(re.source, re.flags);
    if (!fresh.test(text)) continue;
    hits.add(label);
    changed = true;
    text = text.replace(new RegExp(re.source, re.flags), `[REDACTED:${label}]`);
  }
  if (!changed) return null;
  return Buffer.from(text, "latin1");
}

/**
 * Redact every string reachable from a value, with a memo so that an aliased or
 * cyclic value cannot re-emit the UNREDACTED original through a second path (it did:
 * `{a: leaf, b: leaf}` redacted only `a`). Each container is seeded into the memo
 * BEFORE its children are visited, so a back-edge resolves to the redacted copy.
 */
function redactDeep<T>(node: T, secrets: Secret[], hits: Set<string>, memo = new WeakMap<object, unknown>()): T {
  if (typeof node === "string") return redactString(node, secrets, hits) as unknown as T;
  if (typeof node !== "object" || node === null) return node;
  const obj = node as object;
  if (memo.has(obj)) return memo.get(obj) as T;

  if (Array.isArray(node)) {
    const out: unknown[] = [];
    memo.set(obj, out);
    let changed = false;
    for (const n of node) {
      const r = redactDeep(n, secrets, hits, memo);
      if (r !== n) changed = true;
      out.push(r);
    }
    if (!changed) {
      memo.set(obj, node);
      return node;
    }
    Object.setPrototypeOf(out, Object.getPrototypeOf(node)); // keep Array subclasses working
    return out as unknown as T;
  }

  // Byte containers: a secret encoded as bytes is data, not a string property.
  if (ArrayBuffer.isView(node) && !(node instanceof DataView)) {
    const view = node as unknown as Uint8Array;
    const redacted = scanBytes(view, secrets, hits);
    if (redacted === null) {
      memo.set(obj, node);
      return node;
    }
    if (view.BYTES_PER_ELEMENT !== 1) {
      // Uint16Array/Float64Array cannot represent a redacted byte run of a different
      // length without changing their element count; withhold rather than leak.
      throw new Error("secret-redactor: cannot redact a non-8-bit typed array");
    }
    // Preserve the container type: a Buffer must come back a Buffer, a Uint8Array a
    // Uint8Array (the old code returned a plain Uint8Array for both). Memoise the
    // copy BEFORE returning so an aliased Buffer resolves to ONE redacted copy (the
    // branch used to return ahead of `memo.set`, giving a distinct copy per alias).
    const bytes = new Uint8Array(redacted.buffer, redacted.byteOffset, redacted.byteLength);
    if (Buffer.isBuffer(view)) {
      const out = Buffer.from(bytes) as unknown as T;
      memo.set(obj, out);
      return out;
    }
    const Ctor = view.constructor as new (src: Uint8Array) => Uint8Array;
    let rebuilt: Uint8Array;
    try {
      rebuilt = new Ctor(bytes);
    } catch {
      rebuilt = new Uint8Array(bytes);
    }
    memo.set(obj, rebuilt);
    return rebuilt as unknown as T;
  }

  if (node instanceof Map) {
    const out = new Map<unknown, unknown>();
    memo.set(obj, out);
    let changed = false;
    for (const [k, v] of node) {
      const rk = typeof k === "string" ? redactString(k, secrets, hits) : k;
      const rv = redactDeep(v, secrets, hits, memo);
      if (rk !== k || rv !== v) changed = true;
      out.set(rk, rv);
    }
    if (!changed) {
      memo.set(obj, node);
      return node;
    }
    Object.setPrototypeOf(out, Object.getPrototypeOf(node));
    return out as unknown as T;
  }

  if (node instanceof Set) {
    const out = new Set<unknown>();
    memo.set(obj, out);
    let changed = false;
    for (const v of node) {
      const r = redactDeep(v, secrets, hits, memo);
      if (r !== v) changed = true;
      out.add(r);
    }
    if (!changed) {
      memo.set(obj, node);
      return node;
    }
    Object.setPrototypeOf(out, Object.getPrototypeOf(node));
    return out as unknown as T;
  }

  // Every other object shape, including class instances (skipping them entirely was a
  // leak path). A CHANGED non-plain instance becomes plain data — see KNOWN LIMITATIONS.
  const entries = Object.entries(obj as Record<string, unknown>);
  if (entries.length === 0) {
    memo.set(obj, node); // Date, empty typed arrays, objects with only symbol props
    return node;
  }
  const rebuilt: Record<string, unknown> = {};
  memo.set(obj, rebuilt);
  let changed = false;
  for (const [k, v] of entries) {
    // Keys are values too: a secret used as a plain-object key was copied through
    // unredacted and the handler then saw no hit at all (review finding). Redacting
    // the key renames it — the entry survives under `[REDACTED:…]`.
    const rk = redactString(k, secrets, hits);
    const r = redactDeep(v, secrets, hits, memo);
    if (rk !== k || r !== v) changed = true;
    // `defineProperty`, NOT `rebuilt[rk] = r`: an own `__proto__` key (which
    // `JSON.parse` produces) would hit the inherited prototype setter instead — the
    // entry was SILENTLY DROPPED and the rebuilt object's prototype was replaced by
    // its value (review round 7).
    Object.defineProperty(rebuilt, rk, { value: r, enumerable: true, writable: true, configurable: true });
  }
  if (!changed) {
    memo.set(obj, node);
    return node;
  }
  return rebuilt as unknown as T;
}

const WITHHELD =
  "[secret-redactor] Redaction could not complete on a result that contains a configured " +
  "credential, so the output is withheld. Read the value at its source and pass it directly " +
  "to the consumer instead of printing it.";

/** The exact detector could not read a configured store, so it cannot certify "no secret".
 *  Withhold (never proceed on a partial set) and NAME the store so the state is not
 *  silent — an unreadable store used to drop its own secrets from the set with no warning. */
function withheldDegraded(stores: string[]): string {
  return (
    `[secret-redactor] The configured secret store(s) ${stores.join(", ")} could not be read or parsed, ` +
    `so the exact-value detector is incomplete and this result is withheld. Repair the store ` +
    `(readable, valid JSON) or remove it, then retry.`
  );
}

export default function (pi: ExtensionAPI): void {
  refresh();
  const timer = setInterval(refresh, CACHE_MS);
  (timer as unknown as { unref?: () => void }).unref?.();

  pi.on("tool_result", async (event) => {
    const content = (event as { content?: unknown }).content;
    if (!Array.isArray(content)) return; // not ours to touch; a string here breaks downstream

    if (degradedStores.length > 0) {
      // A store EXISTS but could not be read or parsed, so the exact detector is
      // INCOMPLETE: over a partial set, "no hit" is not evidence of absence. Fail closed
      // (the same doctrine as a traversal throw) and name the store — dropping an
      // unreadable store was silent before (review finding). The 30s refresh clears this
      // once the store is readable again; an ABSENT store is not a degradation.
      return { content: [{ type: "text", text: withheldDegraded(degradedStores) }], details: {}, isError: true } as never;
    }

    const hits = new Set<string>();
    try {
      const redactedContent = redactDeep(content, secrets(), hits, new WeakMap());
      const details = redactDeep((event as { details?: unknown }).details, secrets(), hits, new WeakMap());
      if (hits.size === 0) return; // nothing secret: do not touch the result

      const labels = [...hits].join(", ");
      const name = (event as { toolName?: string }).toolName ?? "tool";
      const warning =
        `\n[secret-redactor] ${hits.size} secret pattern(s) REDACTED from this ${name} result: ${labels}.` +
        ` The command tried to emit a configured credential; it was replaced with [REDACTED:…] before being shown or persisted.` +
        ` Read the value at its source and pass it directly to the consumer instead of printing it.`;

      const parts = (redactedContent as Array<Record<string, unknown>>).slice();
      parts.push({ type: "text", text: warning });
      return { content: parts, details } as never;
    } catch {
      // FAIL CLOSED. A thrown traversal means the scan was INCOMPLETE, so "hits is
      // empty" does not mean "no secret" — the previous version returned the original
      // result in that case, re-emitting a secret in any sibling that came after the
      // throw (review finding). `details` is cleared EXPLICITLY: an omitted field keeps
      // its current value, and details is where tool payloads live.
      return { content: [{ type: "text", text: WITHHELD }], details: {}, isError: true } as never;
    }
  });
}
