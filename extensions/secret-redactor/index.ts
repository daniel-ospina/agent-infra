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
 *     - an own ENUMERABLE ACCESSOR (a getter) IS handled: it is read exactly ONCE and
 *       replaced by a DATA property, because a getter that answered clean to the scan and
 *       the stored credential to the serializer used to pass through BY REFERENCE — no
 *       patch, no notice (review round 12). A clean accessor therefore still produces a
 *       patch, and the materialisation is announced. What is NOT covered, stated because
 *       the rule above can be misread as "unstable reads are handled":
 *         · `toJSON` (own or inherited) and `Proxy` traps materialise at SERIALIZATION and
 *           are never invoked here — `JSON.stringify` calls `toJSON` itself, so a
 *           `toJSON()` that returns a configured secret is not scanned. The sibling
 *           `secret-echo-guard.ts` draws its boundary in exactly the same place (it
 *           neutralises accessors and lists `toJSON`/private-field encodings as NOT
 *           COVERED). Covering it means REPLACING a node with the value `toJSON` returns,
 *           which changes the type of every legitimate `Date`/class instance; that is a
 *           separate change with its own review, not a bolt-on to this one. A PROTOTYPE
 *           accessor is not an own key, so it is neither inspected nor copied into a
 *           rebuild — and JSON/structuredClone serialization reads only OWN enumerable
 *           keys, so it is not a path to the transcript either;
 *         · an accessor on a BYTE container (a `Buffer`/`Uint8Array` expando) is not
 *           detected: a view's descriptor snapshot has one entry per BYTE, so the check
 *           would allocate a million descriptors on a 1 MB buffer for a shape no tool
 *           produces. An accessor on a `Map`/`Set` cannot be carried onto the rebuilt
 *           container, so it FAILS CLOSED (the result is withheld, naming the state)
 *           rather than being silently dropped;
 *     - a secret used as a STRING key (Map, Array or plain object) is redacted, which
 *       renames the key — the entry remains, under `[REDACTED:…]`. A NAMED own property
 *       of an Array/Map/Set (`arr.token`, `map.meta`, a subclass field) is traversed and
 *       carried onto a rebuild like any other property; the ONE exception is a BYTE
 *       container (a `Buffer`/`Uint8Array` expando), whose own properties are neither
 *       scanned nor carried — its descriptor snapshot has one entry per byte (see above);
 *     - the exact detector matches a store ENVIRONMENT value as written, and ALSO its
 *       JSON-escaped and `\uXXXX`-escaped spellings (a `cat`/`json.dumps` of the store
 *       renders those, not the literal), and it collects a NUMERIC leaf as its decimal
 *       string. It does NOT match base64, URL-encoded, or hex encodings of a value —
 *       those are separate encodings, not spellings of the text;
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
 *     - a store larger than 2 MB is NOT SCANNED, and it is therefore DEGRADED: it is
 *       recorded like an EACCES store, so the pass WITHHOLDS every tool result and names
 *       the store rather than reporting "no secret" over values it never read. The cap
 *       is reachable (`models-store.json` is ~240 KB in this fleet and grows with the
 *       provider catalogue), and the consequence is real: a large store that holds NO
 *       secret still withholds for the 30 s cache window. That is the deliberate trade
 *       — over-blocking, never a leak — and a bare `continue` here was a fail-open;
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

/** A value that is a REFERENCE to an env var, not a credential (tested trimmed).
 *  ⛔ A TEMPLATE WITH A DEFAULT IS STILL A TEMPLATE. The first form accepted only a bare
 *  `$VAR` / `${VAR}`, so `"apiKey": "${OPENAI_API_KEY:-no-such-default}"` — the
 *  Compose/shell spelling a config carries when it points at a variable that may be
 *  unset — was COLLECTED as a secret, and every output containing that literal was
 *  rewritten to a marker. That contradicts this file's own rule ("env REFERENCE
 *  templates are never secrets") and redacts ordinary config data (review P3). The
 *  modifier arms cover `${VAR:-d}`, `${VAR-d}`, `${VAR:=d}`, `${VAR:?msg}`,
 *  `${VAR:+alt}`, `${VAR#prefix}`, `${VAR%suffix}`. */
const REFERENCE_RE =
  /^(\$[A-Za-z_][A-Za-z0-9_]*|\$\{[A-Za-z_][A-Za-z0-9_]*(?::?[-=+?][^}]*|#+[^}]*|%+[^}]*)?\})$/;

/** The `\uXXXX` spelling an ASCII-escaping serializer emits (Python's `json.dumps`
 *  default, `jq -a`, `ensure_ascii=True`). A NON-ASCII secret was registered literally
 *  and JSON-escaped only, so `python3 -c 'json.dumps(...)'` — an ordinary way a JSON
 *  store gets dumped — rendered `é` as `\u00e9` and the value reached the model
 *  untouched while the literal form was redacted (review P3). */
function unicodeEscaped(value: string): string {
  let out = "";
  for (const ch of value) {
    const cp = ch.codePointAt(0) ?? 0;
    if (ch === '"') out += '\\"';
    else if (ch === "\\") out += "\\\\";
    else if (ch === "\n") out += "\\n";
    else if (ch === "\r") out += "\\r";
    else if (ch === "\t") out += "\\t";
    else if (ch === "\b") out += "\\b";
    else if (ch === "\f") out += "\\f";
    else if (cp < 0x20 || cp > 0x7e) {
      // JSON (`ensure_ascii`) emits a BMP escape, and a surrogate PAIR above it.
      if (cp > 0xffff) {
        const v = cp - 0x10000;
        out += `\\u${(0xd800 + (v >> 10)).toString(16).padStart(4, "0")}`;
        out += `\\u${(0xdc00 + (v & 0x3ff)).toString(16).padStart(4, "0")}`;
      } else {
        out += `\\u${cp.toString(16).padStart(4, "0")}`;
      }
    } else out += ch;
  }
  return out;
}

/** Credential shapes that survive rotation. LEFT-ANCHORED. */
const PATTERNS: Array<[string, RegExp]> = [
  ["tt_api_key", /(?<![A-Za-z0-9_])tt_[A-Za-z0-9]{20,}/g],
  ["github_pat", /(?<![A-Za-z0-9_])github_pat_[A-Za-z0-9_]{20,}/g],
  ["github_token", /(?<![A-Za-z0-9_])gh[pousr]_[A-Za-z0-9]{20,}/g],
  // ⛔ TWO ALTERNATIVES, and the FIRST one is anchor-only. An alnum-only tail after a
  // bounded cap is what keeps ordinary slugs out (`sk-learn-machine-learning-course-notes`:
  // the run after `sk-` is `learn`, 5 chars), but it also dropped every HYPHEN-CARRYING key
  // family this fleet actually ships — `sk-proj-…`, `sk-or-v1-…` (the OpenRouter provider in
  // `extensions/custom-provider-openrouter/`), `sk-ant-…` — i.e. the fix for an
  // over-redaction became a FAIL-OPEN on the post-rotation net (the exact-value detector
  // only covers CONFIGURED keys, so a rotated key has no other guard). The second
  // alternative names the real families explicitly. Both are UNBOUNDED at the tail: a
  // `{20,64}` cap truncated a long key and left the remainder in the output, which is worse
  // than not matching it at all.
  ["openai_key", /(?<![A-Za-z0-9_-])sk-(?:[A-Za-z0-9]{20,}|(?:proj|svcacct|admin|ant|or)-[A-Za-z0-9_-]{20,})/g],
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
    // A NUMBER IS A VALUE TOO. Only strings were collected, so `{"apiKey": 123456789012345}`
    // was never a secret and a `cat` of its own store emitted it verbatim (review P3). It
    // goes through the SAME leaf/path rules and the same MIN_LEN floor, so ordinary short
    // numbers stay out; booleans/null are not credentials and are skipped.
    if (typeof node === "string" || typeof node === "number") {
      if (typeof node === "number" && !Number.isFinite(node)) return;
      const value = typeof node === "string" ? node : String(node);
      const leaf = leafOf(path);
      // The relational veto applies to the widened `_key$` LEAF rule only: a path
      // match is an explicit secret marker and must not be cancelled by a leaf name
      // (`secrets.primary_key`, `credentials.key`, `apiKeys.key` were emitted
      // verbatim when the veto covered the whole disjunction; review round 7).
      const secretKey =
        (SECRET_LEAF_RE.test(leaf) && !NON_SECRET_KEY_RE.test(leaf)) || SECRET_PATH_RE.test(path);
      if (value.length >= MIN_LEN && !isReference(value) && secretKey && !PUBLIC_RE.test(leaf)) {
        // The label is POSITION-INDEPENDENT of the store's contents (`store#N`), never
        // `store:path`. The path is built from the store's KEYS and a key can itself BE
        // a secret that is never a collected VALUE (`{"auths": {"<secret>": {…}}}`), so
        // embedding the path re-emitted that secret in the marker AND in the appended
        // warning — the class this extension closes. `scrubLabels` could only scrub a key
        // that ALSO happened to be a value, which is why the old pin was vacuous (review
        // finding). The store NAME is kept (it says where the leak came from) and is
        // itself scrubbed; the ordinal keeps two secrets from the same store distinct.
        ordinal += 1;
        into.push({ label: `${label}#${ordinal}`, value });
        // ⛔ THE ESCAPED FORM IS A SEPARATE SECRET. A value containing `"` or `\` is
        // registered literally, but the store dump that is this extension's headline
        // scenario renders it JSON-ESCAPED — no literal match — so the escaped text
        // reached the model while the literal was redacted (reproduced: a collected
        // `p@ss"word\\123456` was not redacted from a `cat` of its own store).
        // Registered under the same label (the ordinal is not advanced: it is ONE
        // secret in two encodings, so two markers would misreport the count), and
        // skipped when escaping is a no-op so the common value is not registered twice.
        const escaped = JSON.stringify(value).slice(1, -1);
        if (escaped !== value && escaped.length >= MIN_LEN) {
          into.push({ label: `${label}#${ordinal}`, value: escaped });
        }
        // ⛔ ...AND THE `\uXXXX` SPELLING IS A THIRD ENCODING OF THE SAME SECRET, the
        // one an ASCII-escaping serializer emits (`json.dumps`' default `ensure_ascii`,
        // `jq -a`). It differs from the literal only for a NON-ASCII value, which is why
        // nine review rounds did not surface it: every fixture was ASCII. Same label and
        // ordinal — one secret in three encodings, so three markers would misreport the
        // count — and skipped when it equals the literal or the JSON-escaped form.
        const unicode = unicodeEscaped(value);
        if (unicode !== value && unicode !== escaped && unicode.length >= MIN_LEN) {
          into.push({ label: `${label}#${ordinal}`, value: unicode });
        }
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

/** The scratch form of a LABEL: the same substitutions as `scrubWith`, but every
 *  replacement is the bare word `REDACTED`. Running the marker-producing substitution
 *  inside a label produced a MARKER INSIDE A MARKER —
 *  `[REDACTED:[REDACTED:openai_key]#1]` — for a credential-shaped store file name, which
 *  is noise in the transcript and a second copy of a shape we are trying to remove
 *  (review P2). */
function scrubLabelText(text: string, secrets: Secret[]): string {
  let out = text;
  for (const s of secrets) {
    if (s.value && out.includes(s.value)) out = out.split(s.value).join("REDACTED");
  }
  for (const [, re] of PATTERNS) {
    out = out.replace(new RegExp(re.source, re.flags), "REDACTED");
  }
  return out;
}

/** A label is `store#N`, and the STORE NAME is filesystem-derived — a file named after
 *  a secret (`<apiKey>.json`) would put it in the marker and the warning. The path is no
 *  longer embedded at all (a path is built from the store's KEYS and a key can itself BE
 *  a secret that is never a collected value; review round 10), so this scrub is the
 *  belt-and-braces for the name.
 *  ⛔ WHAT THIS CAN AND CANNOT DO, stated because the old comment over-claimed: it removes
 *  a name that is ALSO a collected value or matches a credential shape. A file name that
 *  is neither is not identifiable as a secret — it is a file name — and that is the whole
 *  residual (review P2). */
function scrubLabels(secrets: Secret[]): void {
  for (const s of secrets) s.label = scrubLabelText(s.label, secrets);
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
  } catch (err) {
    // An ABSENT agent dir has no values to lose and is not a degradation. Anything else
    // (EACCES, ENOTDIR, EIO) means stores may exist and were never enumerated — the
    // SAME incomplete-scan case as an unreadable store, so it must degrade too, or the
    // fallback list below silently reports "no secret" over every store it did not name.
    if ((err as { code?: string }).code !== "ENOENT") degraded.push("agent-dir-unreadable");
    names = [];
  }
  if (names.length === 0) names = FALLBACK_STORES;
  for (const fn of names) {
    const p = join(AGENT_DIR, fn);
    const label = fn.replace(/\.json$/, "");
    try {
      // A store too large to scan is the SAME incomplete-scan case as EACCES and a
      // truncated JSON body, and it must not be the one silent arm: `continue` here
      // reported "no hit" over a store whose values were never read, so a secret in a
      // >2 MB store passed through UNREDACTED with no `degraded` entry — the exact
      // fail-open this file's header forbids ("an incomplete exact detector must not
      // report 'no hit' as 'no secret'"). The cap is reachable in practice
      // (models-store.json alone is ~240 KB and grows with session history).
      if (statSync(p).size > 2_000_000) {
        degraded.push(label);
        continue;
      }
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

/** Own ENUMERABLE accessor keys from an already-taken descriptor snapshot. An accessor is
 *  a LIVE read: it can return a clean value to this walk and a registered secret to the
 *  transcript serializer that reads it again a moment later.
 *  ⛔ Takes the DESCRIPTORS, not the object: the caller already needs them, and a second
 *  `getOwnPropertyDescriptors` pass would double the allocation on every payload. */
function enumerableAccessorKeys(descriptors: Record<string, PropertyDescriptor>): string[] {
  const found: string[] = [];
  for (const key of Object.keys(descriptors)) {
    const d = descriptors[key];
    if (d !== undefined && d.enumerable && (d.get !== undefined || d.set !== undefined)) found.push(key);
  }
  return found;
}

/** The walk's side channel: did it find a value it had to MATERIALISE because the read
 *  was not stable? A materialisation is not a redaction, so it must produce a patch on
 *  its own — with no hits the handler would otherwise return the original BY REFERENCE
 *  and leave the live read in place. */
type WalkState = { unstable: boolean };

/** Own enumerable properties that are NOT array indices — the named properties an
 *  Array, Map or Set can carry (`arr.token = …`, `map.meta = …`, a
 *  `class Row extends Array { batch = … }` field). */
const INDEX_KEY_RE = /^(0|[1-9][0-9]*)$/;
function extraOwnKeys(descriptors: Record<string, PropertyDescriptor>): string[] {
  return Object.keys(descriptors).filter((k) => descriptors[k].enumerable && !INDEX_KEY_RE.test(k));
}

/**
 * Visit a container's NAMED own properties as part of the node and copy them onto the
 * rebuild, redacting key and value exactly as the plain-object arm does. Returns true
 * when anything changed.
 *
 * ⛔ WHY THIS EXISTS (#1591 review): the Array/Map/Set arms iterate the CONTAINER
 * (`for…of`), which visits indices/entries only. A NAMED own property was therefore
 * never SCANNED — with no index changed the original node was returned by reference
 * with `arr.token = <secret>` sitting in it — and was silently DROPPED whenever the
 * container WAS rebuilt (`arr.keep`, `map.meta`, `set.label`, a subclass field). Both
 * directions are pinned in index.test.ts.
 *
 * An accessor here is MATERIALISED (read exactly once, written back as a DATA
 * property), the same rule as the plain-object arm: a getter that answers clean to this
 * walk and the credential to the serializer must not survive. For a `Map`/`Set` the
 * caller has already failed closed on accessors (`assertNoContainerAccessor`) because
 * its rebuild cannot carry them; an Array can, so it materialises. `defineProperty`,
 * not assignment, so a `__proto__` key stays an own key.
 */
function copyOwnExtras(
  source: object,
  descriptors: Record<string, PropertyDescriptor>,
  target: object,
  secrets: Secret[],
  hits: Set<string>,
  memo: WeakMap<object, unknown>,
  state: WalkState,
): boolean {
  let changed = false;
  for (const k of extraOwnKeys(descriptors)) {
    const descriptor = descriptors[k];
    if (descriptor.get !== undefined || descriptor.set !== undefined) {
      state.unstable = true;
      changed = true;
    }
    const v = descriptor.get !== undefined ? descriptor.get.call(source) : descriptor.value;
    const rk = redactString(k, secrets, hits);
    const r = redactDeep(v, secrets, hits, memo, state);
    if (rk !== k || r !== v) changed = true;
    Object.defineProperty(target, rk, { value: r, enumerable: true, writable: true, configurable: true });
  }
  return changed;
}

/**
 * Redact every string reachable from a value, with a memo so that an aliased or
 * cyclic value cannot re-emit the UNREDACTED original through a second path (it did:
 * `{a: leaf, b: leaf}` redacted only `a`). Each container is seeded into the memo
 * BEFORE its children are visited, so a back-edge resolves to the redacted copy.
 *
 * ⛔ AN OWN ENUMERABLE ACCESSOR IS MATERIALISED, NEVER RETURNED BY REFERENCE (#5109
 * review round 12). `Object.entries` reads a getter — but only ONCE, and the walk then
 * returned the ORIGINAL node when that one read looked clean. The serializer does not
 * read it once: `JSON.stringify`/`structuredClone` invoke the getter again, so a getter
 * that answered `"clean"` to the guard and the stored credential to the serializer
 * passed through with NO patch, NO warning and NO failure flag. Such a node is now
 * marked DIRTY and rebuilt with the value captured from a SINGLE read (`descriptor.get`
 * is called at most once, and the getter is replaced by a DATA property), so there is no
 * second read to disagree with. The same rule covers an accessor INDEX on an array.
 */
function redactDeep<T>(
  node: T,
  secrets: Secret[],
  hits: Set<string>,
  memo = new WeakMap<object, unknown>(),
  state: WalkState = { unstable: false },
): T {
  if (typeof node === "string") return redactString(node, secrets, hits) as unknown as T;
  if (typeof node !== "object" || node === null) return node;
  const obj = node as object;
  if (memo.has(obj)) return memo.get(obj) as T;

  if (Array.isArray(node)) {
    const out: unknown[] = [];
    memo.set(obj, out);
    // An accessor INDEX is the same live read as an accessor key; iterating reads it
    // once, so the rebuilt array is seeded with that single value as DATA.
    const descriptors = Object.getOwnPropertyDescriptors(obj) as Record<string, PropertyDescriptor>;
    const accessors = enumerableAccessorKeys(descriptors);
    if (accessors.length > 0) state.unstable = true;
    let changed = accessors.length > 0;
    for (const n of node) {
      const r = redactDeep(n, secrets, hits, memo, state);
      if (r !== n) changed = true;
      out.push(r);
    }
    // NAMED own properties are part of the node (`for…of` visits indices only) — see
    // `copyOwnExtras`; unscanned they leaked, and when the array was rebuilt they vanished.
    if (copyOwnExtras(obj, descriptors, out, secrets, hits, memo, state)) changed = true;
    if (!changed) {
      memo.set(obj, node);
      return node;
    }
    Object.setPrototypeOf(out, Object.getPrototypeOf(node)); // keep Array subclasses working
    return out as unknown as T;
  }

  // An accessor on a container this walk rebuilds from its INTERNALS (bytes, Map, Set)
  // cannot be materialised onto the rebuilt value without changing the container, so it
  // fails CLOSED like the non-8-bit typed-array arm below: withhold, never leak. A byte
  // view is exempt from the CHECK itself (its descriptor snapshot is one entry per BYTE —
  // a 1 MB Buffer would allocate a million descriptors to look for an expando no tool
  // produces); that residual is stated in KNOWN LIMITATIONS.
  const assertNoContainerAccessor = (descriptors: Record<string, PropertyDescriptor>): void => {
    const accessors = enumerableAccessorKeys(descriptors);
    if (accessors.length > 0) {
      throw new Error(
        `secret-redactor: cannot materialise an accessor (${accessors.join(", ")}) on a container`,
      );
    }
  };

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
    const descriptors = Object.getOwnPropertyDescriptors(obj) as Record<string, PropertyDescriptor>;
    assertNoContainerAccessor(descriptors);
    const out = new Map<unknown, unknown>();
    memo.set(obj, out);
    let changed = false;
    for (const [k, v] of node) {
      const rk = typeof k === "string" ? redactString(k, secrets, hits) : k;
      const rv = redactDeep(v, secrets, hits, memo, state);
      if (rk !== k || rv !== v) changed = true;
      out.set(rk, rv);
    }
    // A NAMED own property (`map.meta = …`) is not an ENTRY: unscanned it leaked, and a
    // rebuild dropped it (review P2). An accessor on one already failed closed above.
    if (copyOwnExtras(obj, descriptors, out, secrets, hits, memo, state)) changed = true;
    if (!changed) {
      memo.set(obj, node);
      return node;
    }
    Object.setPrototypeOf(out, Object.getPrototypeOf(node));
    return out as unknown as T;
  }

  if (node instanceof Set) {
    const descriptors = Object.getOwnPropertyDescriptors(obj) as Record<string, PropertyDescriptor>;
    assertNoContainerAccessor(descriptors);
    const out = new Set<unknown>();
    memo.set(obj, out);
    let changed = false;
    for (const v of node) {
      const r = redactDeep(v, secrets, hits, memo, state);
      if (r !== v) changed = true;
      out.add(r);
    }
    // A NAMED own property (`set.label = …`) is not a member — see the Map arm.
    if (copyOwnExtras(obj, descriptors, out, secrets, hits, memo, state)) changed = true;
    if (!changed) {
      memo.set(obj, node);
      return node;
    }
    Object.setPrototypeOf(out, Object.getPrototypeOf(node));
    return out as unknown as T;
  }

  // Every other object shape, including class instances (skipping them entirely was a
  // leak path). A CHANGED non-plain instance becomes plain data — see KNOWN LIMITATIONS.
  // ONE DESCRIPTOR PASS: the keys, the values AND which of them are live accessors come
  // from the same snapshot, so a getter is read exactly once and the value that is
  // scanned is the value that is written into the rebuild.
  const descriptors = Object.getOwnPropertyDescriptors(obj) as Record<string, PropertyDescriptor>;
  const accessors = enumerableAccessorKeys(descriptors);
  if (accessors.length > 0) state.unstable = true;
  // ENUMERABLE only, in `Object.entries` order. `getOwnPropertyDescriptors` also returns
  // NON-enumerable own props (`length`, class fields), which this walk has never
  // traversed — see KNOWN LIMITATIONS.
  const keys = Object.keys(descriptors).filter((k) => descriptors[k].enumerable);
  if (keys.length === 0) {
    memo.set(obj, node); // Date, empty typed arrays, objects with only symbol props
    return node;
  }
  const rebuilt: Record<string, unknown> = {};
  memo.set(obj, rebuilt);
  let changed = accessors.length > 0;
  for (const k of keys) {
    const descriptor = descriptors[k];
    // A data property's value is read straight off the descriptor (no live read). An
    // accessor is invoked ONCE here; a setter-only accessor has no value at all.
    const v = descriptor.get !== undefined ? descriptor.get.call(obj) : descriptor.value;
    // Keys are values too: a secret used as a plain-object key was copied through
    // unredacted and the handler then saw no hit at all (review finding). Redacting
    // the key renames it — the entry survives under `[REDACTED:…]`.
    const rk = redactString(k, secrets, hits);
    const r = redactDeep(v, secrets, hits, memo, state);
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
    // A BARE STRING is redacted, not skipped. `return` here let `content: "key=<secret>"`
    // through untouched — no patch, no notice (reproduced). The sibling boundary handles
    // the same shape the safe way (secret-echo-guard: a bare-string PATCH would crash
    // `normalizeToolResultImages`, but an ARRAY patch is safe), so the string is routed
    // through the same redactor and re-wrapped as one text part.
    const asString = typeof content === "string";
    if (!asString && !Array.isArray(content)) return; // not ours to touch

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
      // ⛔ TWO REASONS TO PATCH, and the second one is not a redaction: a node the walk had
      // to MATERIALISE (an own enumerable accessor) must be emitted even when it carried no
      // secret, because returning the original by reference leaves the live read in place
      // for the serializer to re-invoke. Zero hits alone is NOT "nothing to do" when the
      // walk found an unstable read (review round 12).
      const contentState: WalkState = { unstable: false };
      const detailsState: WalkState = { unstable: false };
      const redactedContent = redactDeep(content, secrets(), hits, new WeakMap(), contentState);
      const details = redactDeep((event as { details?: unknown }).details, secrets(), hits, new WeakMap(), detailsState);
      const unstable = contentState.unstable || detailsState.unstable;
      if (hits.size === 0 && !unstable) return; // nothing secret: do not touch the result

      const name = (event as { toolName?: string }).toolName ?? "tool";
      const notice =
        hits.size > 0
          ? `\n[secret-redactor] ${hits.size} secret pattern(s) REDACTED from this ${name} result: ${[...hits].join(", ")}.` +
            ` The command tried to emit a configured credential; it was replaced with [REDACTED:…] before being shown or persisted.` +
            ` Read the value at its source and pass it directly to the consumer instead of printing it.`
          : // A materialised accessor with no credential in it: the result is rewritten to plain
            // DATA, so say so — a silent rewrite of the model's input is its own harm.
            `\n[secret-redactor] An unstable (getter-backed) value in this ${name} result was resolved to plain data.` +
            ` No configured credential was found; the value was materialised so a later read cannot surface a different one.`;

      // The string arm is re-wrapped: a bare-string `content` patch would break
      // downstream image normalization, an ARRAY of one text part does not.
      const parts = (
        asString
          ? [{ type: "text", text: redactedContent as unknown as string }]
          : (redactedContent as Array<Record<string, unknown>>).slice()
      ) as Array<Record<string, unknown>>;
      parts.push({ type: "text", text: notice });
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
