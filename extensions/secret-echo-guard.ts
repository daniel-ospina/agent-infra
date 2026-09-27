// secret-echo-guard.ts — #5109: redact CONFIGURED SECRET VALUES out of tool results before they
// are persisted into the session transcript.
//
// THE DEFECT
// ----------
// A live 35-character API key (the Tortoise `apiKey` in `~/.pi/agent/tortoise-config.json`) is
// written in PLAINTEXT into agent session transcripts. Re-measured 2026-09-27: 60 of 576 files
// under `~/.pi/agent/sessions/**/*.jsonl` contained the value, the oldest from 2026-09-07, and the
// count was still growing. The cause is not a bug in any one tool — it is the normal operation of
// every reading tool: an agent that reads a config file (via `read`, or `cat` in `bash`) gets the
// value in a tool result, and the tool result is persisted VERBATIM as a `toolResult` session
// entry. The session log is exactly the artifact that gets pasted into issues, shared for
// debugging, and swept into a support bundle, so the secret escapes the machine through the
// transcript rather than through the network.
//
// WHY THIS LAYER, AND NOT A TOOL-BY-TOOL FIX
// ------------------------------------------
// pi exposes `tool_result`, fired after tool execution and BEFORE the final tool result message is
// emitted and persisted (verified in the installed build: `dist/core/agent-session.js`
// `afterToolCall` → `runner.emitToolResult` → `createToolResultMessage` → `appendMessage`). A
// handler may return a PARTIAL PATCH (`content`, `details`, `isError`, `usage`) and omitted fields
// keep their current values, so this is the ONE place where a single tool-agnostic hook can reach
// every current and future tool's persisted output. Fixing `read` alone would miss `bash`, `grep`,
// MCP tools, `task`/`subagent` (whose `details` embed nested agent messages), and every custom
// tool. Fixing the transcript WRITER would be pi's own source, which a pi upgrade replaces.
//
// ⛔ THE ONE PROPERTY THAT MATTERS MOST: THE GUARD MUST NOT LEAK WHAT IT REDACTED
// ------------------------------------------------------------------------------
// A guard that logs the value it removed — to stderr, to a debug file, to a durable record, or in
// its own error handling — has MOVED the leak, not closed it, and has done so with the authority
// of a security control. Therefore, by construction:
//   • no code path receives a secret value for any purpose other than exact-match replacement;
//   • the durable record and the fleet log carry LABELS and COUNTS only (`env:DEEPSEEK_API_KEY`,
//     `tortoise-config.json#apiKey`) plus the tool/session identity fields, ALL of which are run
//     through the redactor before they are written — never a raw value. (Identity fields such as
//     `toolCallId` are provider-supplied and normally opaque, but the guard does not rely on that:
//     it redacts them like every other outbound string, because a guard that logs a value it
//     removed has moved the leak into its own proof artifact.)
//   • internal errors are reported by NAME plus a message, and the COMPOSED string (`name: message`)
//     is run back through the redactor before it is logged — the name is inside the redaction, not
//     outside it. A silent guard failure is indistinguishable from a working one, so we never
//     suppress the fact that a failure happened — only the possibility that the failure text carries
//     a value. If redaction itself fails, nothing but a fixed placeholder is logged.
//   • labels (the non-secret SOURCE names written to the record and embedded in the in-band
//     `[REDACTED-SECRET:<label>]` marker) are themselves scrubbed against the registered values, so a
//     secret that appears as a JSON KEY/ancestor (and therefore inside a label) is not written back
//     out through the label or the marker.
//
// FAIL CLOSED ON THE DECISION, FAIL OPEN ON THE TURN
// --------------------------------------------------
// When a string matches a registered secret it is ALWAYS replaced — there is no "probably" path.
// When the guard itself fails, the result is left exactly as the tool produced it rather than being
// corrupted, and the failure is announced. The residual is explicit and unavoidable: an internal
// failure means THAT result went to the transcript unredacted. That is why the failure is loud, and
// why the record carries no values to leak.
//
// EACH WALK IS GUARDED INDEPENDENTLY (hardening of the above). The content harvest, the `details`
// harvest, the `content` redaction and the `details` redaction are four separate walks; a throw in
// one must not discard the others' work. The failure mode this closes: a throwing `details` getter
// used to escape the (unguarded) harvest into the OUTER catch, which returned `undefined` — so a
// secret that was sitting in `content` was persisted VERBATIM and NOTHING durable was written. Now
// a failure in one walk is recorded (`*RedactionFailed`/`harvestFailed`), the other walk's
// successful redaction is still emitted as a partial patch, and the durable record is written
// whenever ANY failure left data unredacted — a failure is never undetectable after the fact. (The
// runner merges defined patch fields on this build, so a partial patch is safe.)
// The same guard applies to the event's own `toolName`/`input`/`toolCallId` reads: they are read
// through a try/catch and an unreadable one is a RECORDED failure (`eventReadFailed`), so it cannot
// escape into the outer catch and discard an already-computed redaction. (These are
// harness-supplied in the installed build, so this is defense-in-depth, not a tool-reachable path.)
//
// RESIDUAL, STATED PLAINLY: `content` is redacted PER PART, so one hostile part cannot hide a secret
// in a sibling part. `details` is NOT per-node tolerant — the rebuild is a coherent two-pass walk over
// aliased and cyclic structures, and a partially-rebuilt container is not obviously safe. A throwing
// `details` getter therefore leaves the WHOLE `details` unredacted; `content` is still redacted, the
// durable record carries `detailsRedactionFailed`/`detailsWalkBounded`, and the pane warns. This is the
// documented residual of fail-open-on-the-turn, not a silent one.
//
// SCOPE — WHAT IT DOES AND DOES NOT PROTECT (honest statement)
// -----------------------------------------------------------
// CLOSES: the WRITE path going forward. From the moment this extension is loaded, a tool result
// containing a registered secret value is redacted before it is persisted.
// DOES NOT: clean the transcripts that already exist (the 60 files — a separate sweep, and the
// owner's key rotation resets the clock but does not rewrite history); DOES NOT stop a secret
// reaching a NON-pi log (a shell history, a vendor's request log, a CI log, another agent's own
// session file if it runs outside this fleet); DOES NOT protect a value that is never registered
// (see the registry's documented gaps below); and DOES NOT redact the model's own REQUEST payload,
// the assistant's own text, or **tool-call ARGUMENTS** — an agent that types a secret into a
// `write`/`bash`/`edit` argument leaks it, because those arguments are persisted verbatim in the
// SAME transcript and this hook cannot patch them (the runner's patch contract carries only
// `content`/`details`/`isError`/`usage`; `input` is the executed call's argument object, not a
// patchable field). This is the tool-result persistence path only.
//
// REGISTRY — WHAT IS COVERED, AND WHAT IS NOT
// -------------------------------------------
// Values are collected from an EXPLICIT list of secret-bearing sources. An entropy heuristic was
// deliberately NOT added as a general fallback: measured behaviour of entropy filters is that they
// simultaneously over-redact (mangling legitimate output like hashes, UUIDs and base64 blobs) and
// under-redact (a low-entropy key, a token with a fixed prefix), so it buys uncertainty in both
// directions. The registry is instead FIELD-NAME driven, which is provable and testable.
//
//   1. `~/.pi/agent/*.json` (the pi agent config directory) — every JSON string whose KEY is a
//      secret-bearing FIELD name (see `isSecretValueKey`, kind "field"). This covers
//      `tortoise-config.json#apiKey`, `models.json#providers.<p>.apiKey`, `jev-config.json#apiKey`,
//      `settings.json`, and any future `*-config.json` dropped in that directory.
//      `models-store.json` is SKIPPED (an explicit denylist): it is a ~470 KB model CATALOG cache
//      with no secret-bearing field (verified: its only key matching /token/i is `maxTokensField`,
//      which the field rule rejects), and re-reading it on every refresh would be pure cost.
//   2. `~/.pi/agent/auth.json` — ALL string values are secret, regardless of key name. pi's
//      credential store shape (pi-ai `ApiKeyCredential | OAuthCredential`) uses a bare `key` and
//      bare `refresh`/`access` fields, which the field-name rule deliberately does NOT match (a
//      bare `key` is also `sortKey`/`cacheKey`); the file exists for no other purpose, so
//      whole-file secret treatment is the correct rule here.
//   3. `process.env` — every variable whose NAME is secret-bearing (kind "env").
//   4. `.env`-style files at a documented candidate list: `SECRET_ECHO_GUARD_ENV_FILES`
//      (colon-separated, overrides), `~/.pi/agent/.env`, `<cwd>/.env`, `$AGENT_INFRA_PATH/.env`,
//      `$TORTOISE_REPO/.env` (all relative to the seam values; only secret-named keys are taken).
//      ⚠️ `$TORTOISE_REPO/.env` is CONDITIONAL on `TORTOISE_REPO` being set — where it is unset
//      (the state on this machine) that candidate is INERT, and the file's values are covered ONLY
//      by the source-5 harvest from the result being inspected. That is why the harvest must read
//      `details` too. The load-bearing case is `edit`, whose whole change lives in
//      `details.diff`/`details.patch` and NEVER in `content`; the same is true of any tool that
//      puts text in `details` only (`task`/`subagent` nested messages, MCP tools, custom tools).
//      ⛔ CORRECTED PREMISE (an earlier draft of this header overstated it): for `read` and `bash`
//      the harvest from `details` adds NOTHING. The installed build sets `details = { truncation }`
//      and `outputText = truncation.content`, so `details.truncation.content` is the SAME already-
//      TRUNCATED text that `content` carries (and `truncateHead` returns `content: ""` when
//      `firstLineExceedsLimit`). `read`/`bash` are therefore covered entirely by the `content`
//      harvest; harvesting `details` is purely additive for tools whose text is details-only.
//   5. Anything that LOOKS like a dotenv assignment in the tool result being inspected
//      (`harvestDotenvSecrets`) — but ONLY when the tool was aimed at an env-like FILE (a `read`
//      whose `input.path` basenames to `.env`/`*.env`/`.env.*`, or a `bash` command that names such a
//      path). A `KEY=value` line whose key is secret-bearing. This exists because the most likely
//      remaining leak is an agent reading a repo `.env` that pi's own process never sourced
//      (`tortoise/.env` holds `JEV_API_KEY`, `OPENROUTER_API_KEY`,
//      `SUPABASE_AUTH_EXTERNAL_GOOGLE_SECRET` — none of which are in pi's process env). Harvesting
//      from the content being redacted closes that vector for the exact file being read, and the
//      collected values persist for the rest of the process so the SAME value is redacted from
//      every later result. The source GATE is load-bearing: a free-form line in ordinary output
//      that merely reads `key=<something> more text` is NOT a dotenv file, and harvesting from it
//      would register `"<something> more text"` and mangle the output (measured — this is what the
//      first draft did).
//
// NOT COVERED (stated rather than papered over):
//   • the length floor: values SHORTER than `MIN_SECRET_LENGTH` (see its doc comment);
//   • CRAFTED / NON-STRING SHAPES inside `content` (verified: all leave no patch, i.e. persist as
//     the tool produced them). Redaction is an EXACT-MATCH replacement over primitive strings, so a
//     `text` that is a BOXED `String` object (`typeof !== "string"`, and `JSON.stringify` emits the
//     secret), a secret SPLIT across two `text` parts, a secret with INSERTED whitespace, and a
//     `toJSON`/private-field encoding that only materializes at serialization time all pass through.
//     `details` is rebuilt by enumerable own keys, so a non-enumerable field is not copied (and not
//     serialized) either. These are hostile/custom-tool shapes, not pi's own `read`/`bash` shape;
//     they are stated rather than covered because the guard is deliberately exact-match (see the
//     REGISTRY section for why an entropy or normalization heuristic was rejected).
//   • ⛔ a CREDENTIAL EMBEDDED IN A URL, because `NON_SECRET_TAIL_TOKENS` treats a trailing
//     `url`/`uri` as a POINTER: `DATABASE_URL=postgres://user:pass@host/db`,
//     `REDIS_URL=redis://:pass@host`, `SENTRY_DSN=https://key@...` are therefore never registered,
//     and an `https://user:pass@host` in prose is not registered either. Latent on this machine
//     (no such variable is set), documented rather than special-cased: a URL is a pointer in the
//     ordinary case, and registering URL values wholesale would redact ordinary non-secret output
//     (the registry is field-driven on purpose — see REGISTRY). If a credential-bearing URL is ever
//     added to the fleet, give the variable a secret-named key (e.g. `DATABASE_PASSWORD`) or add a
//     dedicated rule here;
//   • a secret that is neither a value under a secret-named field, nor a secret-named env var, nor
//     a dotenv assignment — e.g. a bare token in a prose file, or a value in a `.env` that is never
//     read and never sourced;
//   • a secret that is itself a SUBSTRING of a registered value (only the exact configured value
//     is matched — a comma-separated multi-key env var is registered whole);
//   • non-string secrets (a numeric PIN in a JSON config is skipped);
//   • JSON-escaped forms of a value containing characters that escape differently in the output;
//     real provider keys are `[A-Za-z0-9._-]`, so this is theoretical in practice;
//   • the assistant's own prose, the model request payload, and non-pi logs;
//   • `@file` command-line attachments and `--append-system-prompt <file>`: VERIFIED that pi reads
//     those at CLI startup (`dist/main.js` → `processFileArguments`) and injects their text into the
//     INITIAL USER MESSAGE / system prompt — never through a tool result — so this hook cannot see
//     them. An agent must READ a secret-bearing file with `read`, or `cat` it in `bash`, for this
//     guard to apply. (A `!`/`!!` user bash execution is likewise not a tool result.)
//
// CACHE
// -----
// This handler fires on EVERY tool result, so the registry is loaded once and refreshed by a
// stat/mtime+size signature check (a handful of `statSync` calls), never by re-reading and
// re-parsing on every call. Environment variables are snapshotted once (they do not change inside a
// process). Content-harvested values (source 5) are appended in memory and are capped.
//
// Gate: `SECRET_ECHO_GUARD=0` disables it. Default ON, in BOTH interactive and print modes —
// deliberately no print-mode gate: `task`/`subagent` children are exactly where a secret read by a
// child becomes a parent's transcript entry, so an interactive-only guard would miss the
// highest-value case. (See the header of `secret-echo-guard.test.ts` for how the print-mode path is
// pinned: the extension never reads `PI_MODE` or argv at all, and a test asserts registration under
// both print-mode signals, so re-introducing a gate is a RED test.)
import { appendFileSync, mkdirSync, readdirSync, readFileSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { basename, join } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

// ── The length floor ───────────────────────────────────────────────────────────────────────────

/**
 * Values shorter than this are NEVER registered, so they are never redacted.
 *
 * This is a JUDGEMENT, NOT A MEASUREMENT. The tension: a floor that is too low turns ordinary
 * output into redaction confetti (a 4-character "secret" is a word, a number, a file extension),
 * and a floor that is too high leaves a genuinely short credential unprotected. 12 is the smallest
 * length at which we are willing to defend "this string is not ordinary prose": nothing in the
 * fleet's configs or env is both secret-named and under 12 characters, every credential class we
 * actually hold is far above it (the live Tortoise key is 35, provider keys 35-116, GitHub PATs 40,
 * Slack tokens 30+), and 12 is comfortably above every common short word/number/path fragment that
 * appears in normal tool output. The cost is real and is recorded in the NOT COVERED list above: a
 * shorter secret stays in the transcript. `SECRET_ECHO_GUARD_MIN_LENGTH` overrides it.
 */
export const MIN_SECRET_LENGTH = 12;

// ── The redaction marker ────────────────────────────────────────────────────────────────────────

export const REDACTION_MARKER_BASE = "[REDACTED-SECRET";

/**
 * The replacement for a redacted value. The label is the SOURCE of the value (`env:DEEPSEEK_API_KEY`,
 * `tortoise-config.json#apiKey`), never derived from the value itself — a reader can tell that
 * something was removed AND which configured secret it was, without the transcript carrying it.
 */
export function redactionMarker(label: string): string {
	return `${REDACTION_MARKER_BASE}:${label}]`;
}

export const SECRET_ECHO_GUARD_ENTRY_TYPE = "secret-echo-guard";
export const SECRET_ECHO_GUARD_LOG = "secret-echo-guard-redactions.log";

/** Runaway guards, not expected sizes. Hitting either is RECORDED and announced on EVERY result. */
export const MAX_DETAILS_DEPTH = 32;
export const MAX_DETAILS_NODES = 1_000_000;
/**
 * Wall-clock runaway guard for the `details` walk. The node budget alone still bounds the NUMBER of
 * visits, but a visit's cost scales with the string lengths it scans, so 1M visits measured ~7 s even
 * on short strings. This caps the synchronous event-loop block. It is the SECONDARY bound: a walk
 * that finishes inside the node budget under this deadline is fully redacted, and only a genuinely
 * pathological `details` trips it. Checked every `DETAILS_BUDGET_CHECK_INTERVAL` nodes so `Date.now()`
 * is not called per node. Hitting it sets `bounded`, which is RECORDED and announced on every
 * bounded result — not just the first of a session.
 */
export const MAX_DETAILS_WALK_MS = 2_000;
const DETAILS_BUDGET_CHECK_INTERVAL = 1_024;
/** Source files larger than this are skipped (a config is kilobytes; this is a sanity bound). */
export const MAX_SOURCE_FILE_BYTES = 512 * 1024;
/** Cap on content-HARVESTED values retained per process (sources 1-4 are not capped). */
export const MAX_HARVESTED_VALUES = 512;

/**
 * Cheap pre-check before the (line-by-line) dotenv harvest: does the text contain ANY assignment
 * whose KEY is secret-looking? Most tool output fails this, so the common path never splits lines.
 * A `SORT_KEY=...` hit is intentionally accepted here — the harvest's own key rule decides.
 */
export const DOTENV_PRECHECK_RE = /^[ \t]*(?:export[ \t]+)?[A-Za-z0-9_]*(?:key|token|secret|password|passwd|credential)[A-Za-z0-9_]*[ \t]*=/im;

// ── Field-name classification: the explicit list the brief asks for ─────────────────────────────

/**
 * Normalized token names that are secret ON THEIR OWN, in either kind.
 *
 * Deliberately excludes a bare `key` and a bare `token`-ish qualifier-only name so that
 * `sortKey`/`cacheKey` (JSON) are not treated as secrets; `key` is handled by the qualifier rule.
 */
export const SECRET_WORDS: ReadonlySet<string> = new Set([
	"apikey",
	"secret",
	"clientsecret",
	"privatekey",
	"secretkey",
	"signingkey",
	"encryptionkey",
	"token",
	"sessiontoken",
	"accesstoken",
	"authtoken",
	"refreshtoken",
	"idtoken",
	"password",
	"passwd",
	"passphrase",
	"pass",
	"credential",
	"credentials",
	"bearer",
	"authorization",
	"authorisation",
]);

/** A `key` token is treated as secret only alongside one of these qualifiers (`apiKey`, `SSH_KEY`). */
export const SECRET_KEY_QUALIFIERS: ReadonlySet<string> = new Set([
	"api",
	"access",
	"secret",
	"private",
	"signing",
	"encryption",
	"subscription",
	"consumer",
	"session",
	"auth",
	"client",
	"ssh",
	"oauth",
	"refresh",
	"id",
	"token",
	"service",
	"role",
]);

/**
 * A trailing token that means the value is a POINTER to a secret, not the secret: `*_FILE`, `*_URL`,
 * `*_PATH`. Measured false positive this closes: `CMUX_CUA_AUTH_TOKEN_FILE` (an 89-character temp
 * path) would otherwise be registered and redacted out of ordinary output.
 */
export const NON_SECRET_TAIL_TOKENS: ReadonlySet<string> = new Set([
	"file",
	"files",
	"path",
	"paths",
	"dir",
	"dirs",
	"directory",
	"url",
	"uri",
	"host",
	"port",
	"endpoint",
	"name",
	"id",
	"type",
	"kind",
	"format",
	"store",
	"manager",
	"provider",
	"env",
	"command",
	"cmd",
	"ref",
	"pattern",
	"prefix",
	"suffix",
	"version",
	"keyname",
]);

/**
 * Tokens the LOOSE (env-variable) rule accepts as a trailing token with no qualifier. SCREAMING_SNAKE
 * env names are a much stronger signal than camelCase JSON fields: `BLOG_AGENT_KEY` is a real
 * 77-character secret whose only signal is its trailing `_KEY`, and the accepted cost of catching it
 * is that a genuinely non-secret `SORT_KEY`/`CACHE_KEY` env var would also be registered. That
 * direction is correct for a security control (fail closed on the decision).
 */
export const ENV_SECRET_TAIL_TOKENS: ReadonlySet<string> = new Set([
	"key",
	"keys",
	"apikey",
	"secret",
	"secrets",
	"token",
	"tokens",
	"password",
	"passwd",
	"passphrase",
	"credential",
	"credentials",
	"privatekey",
	"secretkey",
	"clientsecret",
]);

/**
 * Split an identifier into lowercase tokens across BOTH separator (`_`/`-`/`.`) and camelCase
 * boundaries. `ANTHROPIC_API_KEY` → ["anthropic","api","key"]; `maxTokensField` →
 * ["max","tokens","field"]; `MONKEY` → ["monkey"] (NOT ["key"] — the all-caps run is one token).
 */
export function identifierTokens(name: string): string[] {
	const tokens: string[] = [];
	for (const part of name.split(/[^A-Za-z0-9]+/)) {
		if (!part) continue;
		for (const match of part.matchAll(/[A-Z]+(?![a-z])|[A-Z][a-z0-9]*|[a-z0-9]+/g)) {
			tokens.push(match[0].toLowerCase());
		}
	}
	return tokens;
}

/**
 * Is this key name a secret-bearing field? `kind` selects the rule:
 *   • "env"  — an environment variable / dotenv key (loose: a trailing `_KEY`/`_TOKEN` suffices);
 *   • "field" — a JSON object field (strict: a bare `key` needs a qualifier, so `sortKey` is safe).
 * A trailing pointer token (`*_FILE`, `*_URL`, `*_PATH`) always wins in the negative direction.
 */
export function isSecretValueKey(name: string, kind: "env" | "field"): boolean {
	const tokens = identifierTokens(name);
	if (tokens.length === 0) return false;
	const last = tokens[tokens.length - 1];
	if (NON_SECRET_TAIL_TOKENS.has(last)) return false;
	if (tokens.some((token) => SECRET_WORDS.has(token))) return true;
	if (kind === "env" && ENV_SECRET_TAIL_TOKENS.has(last)) return true;
	return tokens.includes("key") && tokens.some((token) => token !== "key" && SECRET_KEY_QUALIFIERS.has(token));
}

// ── Registry values ─────────────────────────────────────────────────────────────────────────────

/** One registered secret: the exact VALUE (never logged) plus a non-secret SOURCE label. */
export interface SecretValue {
	value: string;
	label: string;
}

/** A `$VAR` / `!command` config REFERENCE is not the secret — the real value comes from env. */
const CONFIG_REFERENCE_RE = /^[$!]/;

export function isUsableSecretValue(raw: unknown, minLength = MIN_SECRET_LENGTH): raw is string {
	if (typeof raw !== "string") return false;
	const value = raw.trim();
	if (value.length < minLength) return false;
	if (CONFIG_REFERENCE_RE.test(value)) return false;
	return true;
}

/** Recursively collect string values under secret-named JSON keys. Depth-bounded; never throws. */
export function collectJsonSecrets(
	node: unknown,
	labelPrefix: string,
	out: SecretValue[],
	path = "",
	depth = 0,
	minLength = MIN_SECRET_LENGTH,
): void {
	if (depth > MAX_DETAILS_DEPTH || node === null || typeof node !== "object") return;
	if (Array.isArray(node)) {
		for (let index = 0; index < node.length; index++) {
			collectJsonSecrets(node[index], labelPrefix, out, `${path}[${index}]`, depth + 1, minLength);
		}
		return;
	}
	for (const [key, value] of Object.entries(node as Record<string, unknown>)) {
		const childPath = path ? `${path}.${key}` : key;
		if (isSecretValueKey(key, "field")) {
			if (isUsableSecretValue(value, minLength)) out.push({ value: value.trim(), label: `${labelPrefix}#${childPath}` });
			// A secret-named key whose value is an object (unusual) is still walked below so a nested
			// `{ apiKey: "..." }` cannot be missed.
		}
		if (value !== null && typeof value === "object") {
			collectJsonSecrets(value, labelPrefix, out, childPath, depth + 1, minLength);
		}
	}
}

/** Collect EVERY string value in a whole-file credential store (`auth.json`). */
export function collectAllStringValues(
	node: unknown,
	labelPrefix: string,
	out: SecretValue[],
	path = "",
	depth = 0,
	minLength = MIN_SECRET_LENGTH,
): void {
	if (depth > MAX_DETAILS_DEPTH || node === null || typeof node !== "object") return;
	if (Array.isArray(node)) {
		for (let index = 0; index < node.length; index++) {
			collectAllStringValues(node[index], labelPrefix, out, `${path}[${index}]`, depth + 1, minLength);
		}
		return;
	}
	for (const [key, value] of Object.entries(node as Record<string, unknown>)) {
		const childPath = path ? `${path}.${key}` : key;
		if (isUsableSecretValue(value, minLength)) out.push({ value: value.trim(), label: `${labelPrefix}#${childPath}` });
		if (value !== null && typeof value === "object") {
			collectAllStringValues(value, labelPrefix, out, childPath, depth + 1, minLength);
		}
	}
}

/** Files whose every string value is a credential. */
export const ALL_VALUES_SECRET_FILES: ReadonlySet<string> = new Set(["auth.json"]);

/** Skipped source files, with the reason (see the registry section of the header). */
export function isSkippedConfigFile(name: string): boolean {
	return name.startsWith("models-store.json");
}

/** Parse `.env`-style text. Returns key → raw value; malformed lines are ignored, never thrown on. */
export function parseEnvFile(text: string): Array<{ key: string; value: string }> {
	const out: Array<{ key: string; value: string }> = [];
	for (const line of text.split(/\r?\n/)) {
		const trimmed = line.trim();
		if (!trimmed || trimmed.startsWith("#")) continue;
		const match = /^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/.exec(trimmed);
		if (!match) continue;
		let value = match[2];
		// Strip a matching pair of surrounding quotes (dotenv convention) and any trailing comment.
		const quoted = /^(["'])(.*)\1\s*(?:#.*)?$/.exec(value);
		if (quoted) value = quoted[2];
		else value = value.replace(/\s+#.*$/, "");
		out.push({ key: match[1], value: value.trim() });
	}
	return out;
}

/** Collect secret-named keys from a parsed env map. `labelPrefix` distinguishes the source. */
export function collectEnvSecrets(
	env: Record<string, string | undefined>,
	labelPrefix: string,
	out: SecretValue[],
	minLength = MIN_SECRET_LENGTH,
): void {
	for (const [key, value] of Object.entries(env)) {
		if (!isSecretValueKey(key, "env")) continue;
		if (isUsableSecretValue(value, minLength)) out.push({ value: value.trim(), label: `${labelPrefix}${key}` });
	}
}

// ── The source list ─────────────────────────────────────────────────────────────────────────────

export interface RegistryOptions {
	homedir: string;
	cwd: string;
	env: Record<string, string | undefined>;
	readFile: (path: string) => string;
	readdir: (path: string) => string[];
	stat: (path: string) => { mtimeMs: number; size: number };
}

const KNOWN_CONFIG_FILES = ["tortoise-config.json", "models.json", "jev-config.json", "auth.json", "settings.json"];

/**
 * JSON config files under `~/.pi/agent`. `SECRET_ECHO_GUARD_CONFIG_FILES` (colon-separated) replaces
 * the list entirely. The default enumerates the directory once (so a future `*-config.json` is
 * picked up) and unions the known names (so a `readdir` failure still probes what we know about).
 */
export function resolveConfigFilePaths(options: Pick<RegistryOptions, "homedir" | "env" | "readdir">): string[] {
	const override = (options.env.SECRET_ECHO_GUARD_CONFIG_FILES || "").split(":").filter(Boolean);
	if (override.length > 0) return [...new Set(override)];

	const dir = join(options.homedir, ".pi", "agent");
	const paths: string[] = [];
	try {
		for (const name of options.readdir(dir)) {
			if (!name.endsWith(".json") || isSkippedConfigFile(name)) continue;
			paths.push(join(dir, name));
		}
	} catch {
		/* unreadable directory — the known-file union below still probes the explicit list */
	}
	for (const name of KNOWN_CONFIG_FILES) {
		const path = join(dir, name);
		if (!paths.includes(path)) paths.push(path);
	}
	return paths.sort();
}

/** `.env`-style candidate files. `SECRET_ECHO_GUARD_ENV_FILES` (colon-separated) comes first. */
export function resolveEnvFilePaths(options: Pick<RegistryOptions, "homedir" | "cwd" | "env">): string[] {
	const paths: string[] = [];
	for (const path of (options.env.SECRET_ECHO_GUARD_ENV_FILES || "").split(":")) if (path) paths.push(path);
	paths.push(join(options.homedir, ".pi", "agent", ".env"));
	if (options.cwd) paths.push(join(options.cwd, ".env"));
	if (options.env.AGENT_INFRA_PATH) paths.push(join(options.env.AGENT_INFRA_PATH, ".env"));
	if (options.env.TORTOISE_REPO) paths.push(join(options.env.TORTOISE_REPO, ".env"));
	return [...new Set(paths)];
}

/**
 * Load the STATIC registry: sources 1-4 of the header. Every read is independently try/caught — one
 * unreadable or malformed source must never remove the protection of the others.
 */
export function loadStaticRegistry(options: RegistryOptions, minLength = MIN_SECRET_LENGTH): SecretValue[] {
	const values: SecretValue[] = [];

	for (const path of resolveConfigFilePaths(options)) {
		const name = basename(path);
		let text: string;
		try {
			const info = options.stat(path);
			if (info.size > MAX_SOURCE_FILE_BYTES) continue;
			text = options.readFile(path);
		} catch {
			continue; // absent/unreadable — not an error, and never a reason to abort the others
		}
		let parsed: unknown;
		try {
			parsed = JSON.parse(text);
		} catch {
			continue; // malformed JSON — skip this file only
		}
		if (ALL_VALUES_SECRET_FILES.has(name)) collectAllStringValues(parsed, name, values, "", 0, minLength);
		else collectJsonSecrets(parsed, name, values, "", 0, minLength);
	}

	collectEnvSecrets(options.env, "env:", values, minLength);

	for (const path of resolveEnvFilePaths(options)) {
		let text: string;
		try {
			const info = options.stat(path);
			if (info.size > MAX_SOURCE_FILE_BYTES) continue;
			text = options.readFile(path);
		} catch {
			continue;
		}
		for (const { key, value } of parseEnvFile(text)) {
			if (!isSecretValueKey(key, "env")) continue;
			if (isUsableSecretValue(value, minLength)) values.push({ value: value.trim(), label: `env-file:${basename(path)}#${key}` });
		}
	}

	return values;
}

/**
 * The label-safe replacement for a value found INSIDE a label. Deliberately contains no value and
 * no per-value detail: it only says "something registered appeared in this label".
 */
export const LABEL_VALUE_REPLACEMENT = "<redacted>";

/**
 * Scrub registered values out of a non-secret SOURCE label.
 *
 * A label is built from file/field NAMES (`tortoise-config.json#apiKey`), and a name is normally not
 * a value. But a JSON KEY can be a secret: `{ "<a registered value>": { "clientSecret": "..." } }`
 * yields the label `<file>#<value>.clientSecret`, which then (a) is embedded in the in-band
 * `[REDACTED-SECRET:<label>]` marker and (b) is written to the durable record and the fleet log. A
 * guard that does that has moved the leak into its own proof. Every label is therefore run through
 * an exact-match scrub against the full registered set before it is used.
 */
export function sanitizeLabel(label: string, values: readonly SecretValue[]): string {
	let out = label;
	for (const { value } of values) {
		if (value.length === 0 || !out.includes(value)) continue;
		out = out.split(value).join(LABEL_VALUE_REPLACEMENT);
	}
	return out;
}

/** Dedupe by value (first label wins) and sort LONGEST-FIRST so one secret can never break another. */
export function normalizeSecretValues(values: SecretValue[]): SecretValue[] {
	const byValue = new Map<string, SecretValue>();
	for (const { value, label } of values) {
		if (!value) continue;
		if (!byValue.has(value)) byValue.set(value, { value, label });
	}
	const normalized = [...byValue.values()].sort((a, b) => b.value.length - a.value.length);
	// Labels are scrubbed against the FULL set, so a value appearing in another value's label (or
	// its own) cannot be written back out through the record or the in-band marker.
	for (const entry of normalized) entry.label = sanitizeLabel(entry.label, normalized);
	return normalized;
}

// ── Redaction ───────────────────────────────────────────────────────────────────────────────────

export type HitCounts = Map<string, number>;

export function addHit(hits: HitCounts, label: string, count = 1): void {
	hits.set(label, (hits.get(label) ?? 0) + count);
}

export function hitsTotal(hits: HitCounts): number {
	let total = 0;
	for (const count of hits.values()) total += count;
	return total;
}

/** Exact-match replacement of every registered value. `split`/`join` = literal match, no regex. */
export function redactString(text: string, values: readonly SecretValue[], hits: HitCounts): string {
	let out = text;
	for (const { value, label } of values) {
		if (value.length === 0 || out.length < value.length) continue;
		if (!out.includes(value)) continue;
		const count = out.split(value).length - 1;
		if (count === 0) continue;
		out = out.split(value).join(redactionMarker(label));
		addHit(hits, label, count);
	}
	return out;
}

export interface RedactOutcome<T> {
	value: T;
	changed: boolean;
}

/**
 * Redact the tool-result `content`.
 *
 * VERIFIED SHAPE (installed pi build): for BOTH `read` and `bash`, `content` is
 * `[{ type: "text", text: "<string>" }]` — an array of `TextContent | ImageContent` parts, never a
 * plain string. The string branch below is defensive only (custom tools and future shapes): pi's own
 * `normalizeToolResultImages` calls `content.some(...)`, so a bare-string patch would CRASH pi. It
 * therefore CONVERTS a redacted string to the array shape pi can consume instead of returning one it
 * cannot. The array branch preserves every non-text part and every extra field BY REFERENCE, so an
 * unredacted result comes back as the SAME array object (`changed: false`) and the handler returns
 * `undefined`.
 */
export function redactContent(
	content: unknown,
	values: readonly SecretValue[],
	hits: HitCounts,
): RedactOutcome<unknown> & { incomplete: boolean } {
	if (typeof content === "string") {
		const redacted = redactString(content, values, hits);
		if (redacted === content) return { value: content, changed: false, incomplete: false };
		return { value: [{ type: "text", text: redacted }], changed: true, incomplete: false };
	}
	if (!Array.isArray(content)) return { value: content, changed: false, incomplete: false };

	let changed = false;
	let incomplete = false;
	const parts = content.map((part) => {
		// Each part is inspected INSIDE its own guard. A hostile part (a throwing `type` getter, a
		// Proxy) must not stop the OTHER parts from being redacted — otherwise one bad part made the
		// whole content walk throw and a registered secret in a SIBLING part was persisted verbatim.
		try {
			if (
				part !== null &&
				typeof part === "object" &&
				(part as { type?: unknown }).type === "text" &&
				typeof (part as { text?: unknown }).text === "string"
			) {
				const original = (part as { text: string }).text;
				const redacted = redactString(original, values, hits);
				if (redacted === original) return part;
				changed = true;
				return { ...(part as Record<string, unknown>), text: redacted };
			}
		} catch {
			// Keep the part by reference: the runner would have read it anyway, and dropping content is
			// worse than passing through a part this guard could not inspect. `incomplete` is recorded
			// by the caller so the result is never presented as a full redaction.
			incomplete = true;
		}
		return part;
	});
	return { value: changed ? parts : content, changed, incomplete };
}

/**
 * Redact `details`, recursively.
 *
 * VERIFIED SHAPES (installed pi build, read from real session entries):
 *   • `read`  → `undefined` when untruncated; `{ truncation: { content: string, truncated, … } }`
 *     when truncated. The truncation content is the SAME already-truncated text as `content` (see
 *     the header's corrected premise) — so `details` here adds no coverage a `content` pass lacks;
 *   • `bash`  → the same `TruncationResult` shape plus `{ fullOutputPath?: string }`;
 *   • `edit`  → `{ diff: string, patch: string, firstChangedLine: number }` — the whole change is
 *     details-ONLY, which is what makes the details walk load-bearing;
 *   • `task`  → `{ model, provider, stderr: string, sawTools }`;
 *   • `subagent` → `{ results: [{ …, messages: [{ role, content, timestamp }], stderr }] }` — NESTED
 *     agent messages, which is exactly how a child's read of a config becomes a parent's leak.
 * A shallow walk would miss `details.truncation.content` and the nested `subagent` messages, so the
 * walk is recursive.
 *
 * KEYS ARE OUTBOUND TEXT TOO: pass 1 treats a registered value found in an object KEY as dirtying the
 * container, and pass 2 rebuilds the key through the redactor, so `{ "<secret>": … }` cannot survive
 * in the transcript while the record and log stay clean.
 *
 * ALIASES AND CYCLES: a single-pass `WeakSet` guard that returns the ORIGINAL node on a repeat visit
 * redacts the first reference and leaves every other one raw (`{a: shared, b: shared}` leaked the
 * secret through `b`), and a cycle lost its back-edge redaction the same way. The walk is therefore
 * TWO-PASS: pass 1 marks every subtree that CONTAINS a registered value (cycle-safe, bounded), and
 * pass 2 REBUILDS only dirty subtrees while memoizing each rebuilt container (`Map<object, unknown>`),
 * so an aliased or cyclic reference resolves to the SAME rebuilt container. Clean subtrees are
 * returned BY REFERENCE so an ordinary result is byte-identical and `changed` stays false.
 *
 * BOUNDS: pass 1 stops iterating siblings the moment the node budget or the wall-clock budget is
 * spent (a `for` loop, never `.map`), so a pathological `details` cannot make the walk O(total nodes)
 * after the budget is exhausted. Hitting a bound sets `bounded: true`, which the caller RECORDS and
 * ANNOUNCES — a bounded walk is never silently presented as a full redaction.
 */
export interface DetailsWalkLimits {
	/** Override the node budget (tests). Default `MAX_DETAILS_NODES`. */
	maxNodes?: number;
	/** Override the wall-clock budget in ms (tests). Default `MAX_DETAILS_WALK_MS`. */
	maxMs?: number;
}

interface DetailsWalkBudget {
	nodes: number;
	deadline: number;
	bounded: boolean;
}

function newDetailsBudget(limits: DetailsWalkLimits = {}): DetailsWalkBudget {
	return {
		nodes: limits.maxNodes ?? MAX_DETAILS_NODES,
		deadline: Date.now() + (limits.maxMs ?? MAX_DETAILS_WALK_MS),
		bounded: false,
	};
}

/** True when the node or wall-clock budget is spent. Sets `bounded` so no caller can forget to. */
function detailsBudgetExhausted(budget: DetailsWalkBudget): boolean {
	if (budget.nodes <= 0) {
		budget.bounded = true;
		return true;
	}
	if (budget.nodes % DETAILS_BUDGET_CHECK_INTERVAL === 0 && Date.now() >= budget.deadline) {
		budget.bounded = true;
		return true;
	}
	return false;
}

function containsRegisteredValue(text: string, values: readonly SecretValue[]): boolean {
	for (const { value } of values) {
		if (value.length !== 0 && text.includes(value)) return true;
	}
	return false;
}

interface DetailsDirtyState extends DetailsWalkBudget {
	dirty: WeakSet<object>;
	clean: WeakSet<object>;
	visiting: WeakSet<object>;
	sawCycle: boolean;
}

/** Pass 1 — does this subtree contain any registered value? Cycle-safe; bounded; never throws by itself. */
function markDirtyDetails(node: unknown, values: readonly SecretValue[], state: DetailsDirtyState, depth: number): boolean {
	if (detailsBudgetExhausted(state)) return false;
	state.nodes--;
	if (typeof node === "string") return containsRegisteredValue(node, values);
	if (node === null || typeof node !== "object") return false;
	if (depth >= MAX_DETAILS_DEPTH) {
		state.bounded = true;
		return false;
	}
	if (state.dirty.has(node)) return true;
	if (state.clean.has(node)) return false;
	if (state.visiting.has(node)) {
		// Back-edge. `dirty` is still correct as an OR over every directly-inspected string (every
		// reachable node is visited before any back-edge to it), but the per-node CLEAN marking cannot
		// be trusted inside a cycle, so pass 2 rebuilds everything when a cycle was seen.
		state.sawCycle = true;
		return false;
	}
	state.visiting.add(node);
	let dirty = false;
	let complete = true;
	if (Array.isArray(node)) {
		for (let index = 0; index < node.length; index++) {
			if (detailsBudgetExhausted(state)) {
				complete = false;
				break;
			}
			if (markDirtyDetails(node[index], values, state, depth + 1)) dirty = true;
		}
	} else {
		const source = node as Record<string, unknown>;
		for (const key of Object.keys(source)) {
			if (detailsBudgetExhausted(state)) {
				complete = false;
				break;
			}
			// A registered value can sit in a JSON KEY as well as in a value:
			// `{ "<secret>": { clientSecret: … } }`. Keys cannot be rebuilt in place, so a key match
			// marks the whole container dirty and pass 2 rebuilds the key too — otherwise the
			// transcript (the artifact this guard exists to protect) keeps the secret as a key while the
			// record/log/marker stay clean, which is precisely the leak moved into the proof artifact.
			if (containsRegisteredValue(key, values)) dirty = true;
			if (markDirtyDetails(source[key], values, state, depth + 1)) dirty = true;
		}
	}
	state.visiting.delete(node);
	if (dirty) state.dirty.add(node);
	else if (complete) state.clean.add(node);
	return dirty;
}

/**
 * Pass 2 — rebuild only dirty subtrees (or all of them when a cycle was seen), memoizing each
 * rebuilt container BEFORE recursing so aliases and back-edges resolve to the same replacement.
 */
function rebuildDetails(
	node: unknown,
	values: readonly SecretValue[],
	hits: HitCounts,
	state: DetailsDirtyState,
	memo: Map<object, unknown>,
	depth: number,
): unknown {
	if (typeof node === "string") return redactString(node, values, hits);
	if (node === null || typeof node !== "object") return node;
	if (memo.has(node)) return memo.get(node);
	if (!state.sawCycle && !state.dirty.has(node)) return node;
	if (depth >= MAX_DETAILS_DEPTH) return node;
	if (Array.isArray(node)) {
		const next: unknown[] = new Array(node.length);
		memo.set(node, next);
		for (let index = 0; index < node.length; index++) {
			next[index] = rebuildDetails(node[index], values, hits, state, memo, depth + 1);
		}
		return next;
	}
	const source = node as Record<string, unknown>;
	// Preserve the prototype so a dirty class instance comes back as an instance rather than a bare
	// `{}`-shaped object. (pi's own `details` are plain, so this is defensive, but it is cheap and
	// keeps the rebuild faithful; a hostile `getPrototypeOf` trap falls back to a plain object and
	// marks the walk bounded instead of throwing the whole details redaction away.)
	let next: Record<string, unknown>;
	try {
		next = Object.create(Object.getPrototypeOf(source)) as Record<string, unknown>;
	} catch {
		next = {};
		state.bounded = true;
	}
	memo.set(node, next);
	for (const key of Object.keys(source)) {
		// The key is itself outbound text (it lands in the transcript), so a secret used as an
		// ancestor key is redacted here, exactly like a value.
		const rebuiltKey = redactString(key, values, hits);
		// `Object.defineProperty`, not `next[key] = …`: an own `__proto__` key on the source (JSON.parse
		// creates one) would hit the inherited `__proto__` SETTER on assignment and be silently DROPPED,
		// so the rebuild lost that key entirely. defineProperty makes it an ordinary own enumerable
		// property, so the key survives redaction like every other key.
		Object.defineProperty(next, rebuiltKey, {
			value: rebuildDetails(source[key], values, hits, state, memo, depth + 1),
			enumerable: true,
			writable: true,
			configurable: true,
		});
	}
	return next;
}

export function redactDetails(
	details: unknown,
	values: readonly SecretValue[],
	hits: HitCounts,
	limits: DetailsWalkLimits = {},
): RedactOutcome<unknown> & { bounded: boolean } {
	const state: DetailsDirtyState = {
		...newDetailsBudget(limits),
		dirty: new WeakSet<object>(),
		clean: new WeakSet<object>(),
		visiting: new WeakSet<object>(),
		sawCycle: false,
	};
	const dirty = markDirtyDetails(details, values, state, 0);
	if (!dirty) return { value: details, changed: false, bounded: state.bounded };
	const value = rebuildDetails(details, values, hits, state, new Map<object, unknown>(), 0);
	return { value, changed: true, bounded: state.bounded };
}

/**
 * Bounded walk collecting every string reachable in `node`. Used by the source-5 harvest to read
 * `details` — where an `edit` puts its whole change (`details.diff`/`details.patch`), which `content`
 * never carries — BEFORE the redaction pass, so the harvested values feed the same pass. (For `read`
 * and `bash` the details text duplicates `content`, so this walk is additive only for details-only
 * tools; see the header.) Hitting the bound sets `budget.bounded`, which is carried into the record.
 * EXPORTED FOR TESTS: the depth bound is a security-relevant coverage limit and is pinned directly.
 */
export function collectDetailsStrings(
	node: unknown,
	out: string[],
	budget: DetailsWalkBudget,
	visited: WeakSet<object>,
	depth: number,
): void {
	if (detailsBudgetExhausted(budget)) return;
	budget.nodes--;
	if (typeof node === "string") {
		out.push(node);
		return;
	}
	if (node === null || typeof node !== "object") return;
	if (depth >= MAX_DETAILS_DEPTH) {
		budget.bounded = true;
		return;
	}
	if (visited.has(node)) return;
	visited.add(node);
	if (Array.isArray(node)) {
		for (let index = 0; index < node.length; index++) {
			if (detailsBudgetExhausted(budget)) return;
			collectDetailsStrings(node[index], out, budget, visited, depth + 1);
		}
		return;
	}
	const source = node as Record<string, unknown>;
	for (const key of Object.keys(source)) {
		if (detailsBudgetExhausted(budget)) return;
		collectDetailsStrings(source[key], out, budget, visited, depth + 1);
	}
}

/**
 * Is this a path pi's `read` tool would expose the contents of an ENV file through?
 * `.env`, `.env.local`, `.env.production`, `app.env` — yes; `environment.md` — no.
 */
export function isEnvLikePath(path: string): boolean {
	let base: string;
	try {
		base = basename(path).toLowerCase();
	} catch {
		return false;
	}
	return base === ".env" || base.startsWith(".env.") || base.endsWith(".env") || base.includes(".env.");
}

/**
 * The env-like source of a tool call, or `undefined` when the tool was not aimed at one. This is the
 * GATE for harvesting: without it, a `KEY=<value> trailing prose` line in ordinary output is
 * registered whole. Returns a non-secret label fragment (the basename), never a value.
 */
export function envSourceFromInput(input: unknown): string | undefined {
	try {
		if (!input || typeof input !== "object") return undefined;
		const path = (input as { path?: unknown }).path;
		if (typeof path === "string" && isEnvLikePath(path)) return basename(path);
		const command = (input as { command?: unknown }).command;
		if (typeof command === "string") {
			for (const token of command.split(/[\s'"();|&<>]+/)) {
				if (token && isEnvLikePath(token)) return basename(token);
			}
		}
	} catch {
		/* unreadable input — no harvest, which is the safe direction (the registry still applies) */
	}
	return undefined;
}

/**
 * Test-only observability for the cheap pre-check. The pre-check is a pure OPTIMISATION — deleting
 * it changes no output, only cost — so its regression pin has to observe that it fired rather than
 * infer it from behaviour. See the `DOTENV_PRECHECK_RE` mutation test.
 */
export const _secretEchoGuardCounters = { dotenvPrecheckSkips: 0 };

/**
 * Strip a unified-diff line marker from each line before the dotenv parse. An `edit` result's
 * `details.diff`/`details.patch` are unified diffs, so an added or removed `.env` assignment arrives
 * as `+KEY=value` / `-KEY=value`; without this the parser (and the pre-check) see the leading `+`/`-`
 * and silently miss the assignment. Env keys cannot begin with `+`/`-`, and `parseEnvFile` already
 * trims spaces, so this is lossless for real `.env` text.
 */
function stripDiffMarkers(text: string): string {
	return text.replace(/^[+-]/gm, "");
}

/**
 * Harvest dotenv-shaped secret assignments out of the text being inspected (registry source 5).
 * Only a `KEY=value` line whose KEY is secret-bearing counts, so ordinary output that happens to
 * contain `=` is untouched. Values are appended to `into` (deduped by the caller's normalize step)
 * and capped by MAX_HARVESTED_VALUES. Returns the number added.
 */
export function harvestDotenvSecrets(
	text: string,
	into: SecretValue[],
	sourceName: string,
	minLength = MIN_SECRET_LENGTH,
	maxHarvested = MAX_HARVESTED_VALUES,
): number {
	const candidate = stripDiffMarkers(text);
	if (!DOTENV_PRECHECK_RE.test(candidate)) {
		_secretEchoGuardCounters.dotenvPrecheckSkips++;
		return 0;
	}
	let added = 0;
	for (const { key, value } of parseEnvFile(candidate)) {
		if (!isSecretValueKey(key, "env")) continue;
		if (!isUsableSecretValue(value, minLength)) continue;
		if (into.length >= maxHarvested) break;
		into.push({ value: value.trim(), label: `read:${sourceName}#${key}` });
		added++;
	}
	return added;
}

// ── Cache ───────────────────────────────────────────────────────────────────────────────────────

interface RegistryCache {
	signature: string;
	envLoaded: boolean;
	staticValues: SecretValue[];
	harvested: SecretValue[];
	minLength: number;
}

let cache: RegistryCache | undefined;

/** Test seam (#212 convention, mirroring clamp-output-floor.ts). */
export interface SecretEchoGuardHooks {
	readFile: typeof readFileSync;
	readdir: typeof readdirSync;
	stat: typeof statSync;
	homedir: typeof homedir;
	cwd: () => string;
	env: () => Record<string, string | undefined>;
	appendFile: typeof appendFileSync;
	mkdir: typeof mkdirSync;
	/**
	 * TEST-ONLY override for the source-5 `details` HARVEST budget (never set in production). It
	 * exists so a test can drive the real handler into the `harvestBudget.bounded &&
	 * !details.bounded` state — a bounded harvest whose redaction walk completed — without spending
	 * the production 2 s wall-clock deadline. See the M07 regression.
	 */
	detailsHarvestLimits?: () => DetailsWalkLimits;
}
const defaultHooks: SecretEchoGuardHooks = {
	readFile: ((path: string) => readFileSync(path, "utf8")) as unknown as typeof readFileSync,
	readdir: readdirSync as unknown as typeof readdirSync,
	stat: statSync,
	homedir,
	cwd: () => process.cwd(),
	env: () => process.env,
	appendFile: appendFileSync,
	mkdir: mkdirSync,
};
export const secretEchoGuardHooks: SecretEchoGuardHooks = { ...defaultHooks };
export function _setSecretEchoGuardHooksForTest(overrides: Partial<SecretEchoGuardHooks>): void {
	if (process.env.NODE_ENV !== "test") return;
	Object.assign(secretEchoGuardHooks, overrides);
}
export function _resetSecretEchoGuardCacheForTest(): void {
	if (process.env.NODE_ENV !== "test") return;
	cache = undefined;
}
export function _resetSecretEchoGuardAnnouncementsForTest(): void {
	if (process.env.NODE_ENV === "test") announced.clear();
}

function resolveMinLength(env: Record<string, string | undefined>): number {
	const raw = env.SECRET_ECHO_GUARD_MIN_LENGTH;
	const parsed = raw === undefined ? Number.NaN : Number.parseInt(raw, 10);
	return Number.isFinite(parsed) && parsed > 0 ? parsed : MIN_SECRET_LENGTH;
}

function readRegistryOptions(hooks: SecretEchoGuardHooks, env: Record<string, string | undefined>) {
	return {
		homedir: hooks.homedir(),
		cwd: safeCwd(hooks),
		env,
		readFile: ((path: string) => String(hooks.readFile(path, "utf8"))) as unknown as (path: string) => string,
		readdir: ((path: string) => hooks.readdir(path) as unknown as string[]) as unknown as (path: string) => string[],
		stat: ((path: string) => {
			const info = hooks.stat(path);
			return { mtimeMs: info.mtimeMs, size: info.size };
		}) as (path: string) => { mtimeMs: number; size: number },
	};
}

function safeCwd(hooks: SecretEchoGuardHooks): string {
	try {
		return hooks.cwd();
	} catch {
		return "";
	}
}

/** The stat/mtime+size signature of the source set: the ONLY thing done per invocation. */
export function sourceSignature(options: RegistryOptions): string {
	const parts: string[] = [];
	for (const path of [...resolveConfigFilePaths(options), ...resolveEnvFilePaths(options)]) {
		try {
			const info = options.stat(path);
			parts.push(`${path}:${info.mtimeMs}:${info.size}`);
		} catch {
			parts.push(`${path}:-`);
		}
	}
	return parts.join("|");
}

/**
 * The live registry: static sources refreshed only when a source's signature changes, plus the
 * process-lifetime harvested values. Sorted longest-first and deduped.
 */
export function getRegistryValues(hooks: SecretEchoGuardHooks = secretEchoGuardHooks): SecretValue[] {
	const env = hooks.env() ?? {};
	const minLength = resolveMinLength(env);
	const options = readRegistryOptions(hooks, env);
	const signature = sourceSignature(options);

	if (!cache || !cache.envLoaded || cache.minLength !== minLength || cache.signature !== signature) {
		const staticValues = loadStaticRegistry(options, minLength);
		cache = {
			signature,
			envLoaded: true,
			staticValues,
			harvested: cache?.harvested ?? [],
			minLength,
		};
	}
	return normalizeSecretValues([...cache.staticValues, ...cache.harvested]);
}

/** Append content-harvested values to the process-lifetime registry. Never logs the values. */
export function retainHarvested(values: SecretValue[], hooks: SecretEchoGuardHooks = secretEchoGuardHooks): void {
	if (values.length === 0) return;
	// Force a cache slot when the first call is a harvest (no source has been stat'ed yet).
	getRegistryValues(hooks);
	if (!cache) return;
	cache.harvested.push(...values);
	if (cache.harvested.length > MAX_HARVESTED_VALUES) cache.harvested.splice(0, cache.harvested.length - MAX_HARVESTED_VALUES);
}

// ── Gate ────────────────────────────────────────────────────────────────────────────────────────

export function secretEchoGuardActive(env: Record<string, string | undefined>): boolean {
	return env.SECRET_ECHO_GUARD !== "0";
}

// ── Durable record + notice ─────────────────────────────────────────────────────────────────────

function sessionInfo(ctx: unknown): { sessionId: string | null; sessionFile: string | null } {
	let sessionId: string | null = null;
	let sessionFile: string | null = null;
	try {
		const sm = (ctx as { sessionManager?: Record<string, unknown> } | null | undefined)?.sessionManager;
		if (sm && typeof sm === "object") {
			const id = sm.getSessionId;
			if (typeof id === "function") {
				const value = id.call(sm);
				if (typeof value === "string") sessionId = value;
			}
			const file = sm.getSessionFile;
			if (typeof file === "function") {
				const value = file.call(sm);
				if (typeof value === "string") sessionFile = value;
			}
		}
	} catch {
		/* unreadable identity — the record still fires with nulls, never invented values */
	}
	return { sessionId, sessionFile };
}

/** Sessions already announced; the redaction is loud but must not spam every tool result. */
const announced = new Set<string>();

function errName(error: unknown): string {
	try {
		if (error instanceof Error && typeof error.name === "string") return error.name;
	} catch {
		/* a hostile `name` getter — fall through to the fixed placeholder */
	}
	return "Error";
}

/**
 * Build a diagnostic string that CANNOT carry a registered value. The NAME is composed with the
 * MESSAGE FIRST and the COMPOSED string is run back through the redactor, so a value carried by the
 * `error.name` (not just the message) is removed before it can reach stderr. If redaction itself
 * fails, nothing but a fixed placeholder is returned.
 */
function safeDiagnostic(error: unknown, values: readonly SecretValue[]): string {
	const name = errName(error);
	let message = "";
	try {
		message = error instanceof Error ? error.message : String(error);
	} catch {
		message = "";
	}
	const composed = message ? `${name}: ${message}` : name;
	try {
		return redactString(composed, values, new Map());
	} catch {
		return "Error";
	}
}

/**
 * Run an outbound string (the record's identity fields, a tool name) through the redactor before it
 * reaches ANY sink. The record is the guard's own proof artifact, so a secret that appears in
 * `toolCallId`/`sessionId`/`sessionFile`/`toolName` must be redacted exactly like a value in
 * `content` — otherwise the guard has moved the leak into the artifact that documents the redaction.
 * A throwaway hit map keeps identity scrubs out of the record's redaction counts. Returns the input
 * unchanged when it is not a string (`null` included), and a fixed placeholder if redaction throws.
 */
function sanitizeOutboundString(value: unknown, values: readonly SecretValue[]): unknown {
	if (typeof value !== "string") return value;
	try {
		return redactString(value, values, new Map());
	} catch {
		return "<unreadable>";
	}
}

/**
 * Read a field off the `tool_result` event without letting a hostile getter abort the handler.
 * `content`/`details` are read this way already; `toolName`/`input`/`toolCallId` are read the same
 * way so an unreadable field becomes a RECORDED failure flag rather than an escape into the outer
 * catch. That escape was itself the bug: it discarded a redaction that had already succeeded (the
 * patch) and wrote no durable record, leaving the raw secret-bearing result to be persisted with
 * nothing to attest it. These fields are harness-supplied in the installed build, so this is
 * defense-in-depth for a hostile/Proxy event object, not a tool-reachable path.
 */
function readEventField(holder: unknown, field: string): { ok: boolean; value: unknown; error?: unknown } {
	try {
		return { ok: true, value: (holder as Record<string, unknown>)[field] };
	} catch (error) {
		return { ok: false, value: undefined, error };
	}
}

// ── The extension ───────────────────────────────────────────────────────────────────────────────

export default function secretEchoGuard(pi: ExtensionAPI): void {
	if (!secretEchoGuardActive(process.env)) return;

	pi.on("session_start", (event) => {
		const reason = (event as { reason?: unknown } | null | undefined)?.reason;
		if (reason === "reload") return;
		announced.clear();
	});

	pi.on("tool_result", (event, ctx) => {
		const hooks = secretEchoGuardHooks;
		let values: SecretValue[] = [];
		// Independent failure flags: each walk is guarded on its own so a throw in one never discards
		// another's successful redaction. `harvestFailed` covers both harvest walks.
		let contentHarvestFailed = false;
		let detailsHarvestFailed = false;
		let contentRedactionFailed = false;
		let detailsRedactionFailed = false;
		// An unreadable identity/argument field on the event. It is not one of the four redaction walks,
		// but it MUST be recorded: if it escaped to the outer catch it discarded an already-computed
		// redaction and wrote no durable record at all (the exact defect this hardening closes).
		let eventReadFailed = false;
		try {
			values = getRegistryValues(hooks);

			const e = event as {
				toolName?: unknown;
				toolCallId?: unknown;
				input?: unknown;
				content?: unknown;
				details?: unknown;
			};
			// Read the event fields ONCE each and guard every read: a throwing getter on the event object
			// must not escape to the outer catch (which would discard the redaction and the record).
			const toolNameField = readEventField(e, "toolName");
			if (!toolNameField.ok) {
				eventReadFailed = true;
				globalThis.console?.error?.(
					`[secret-echo-guard] reading toolName failed; the tool name is left UNREADABLE: ${safeDiagnostic(toolNameField.error, values)}`,
				);
			}
			const toolName = toolNameField.ok && typeof toolNameField.value === "string" ? toolNameField.value : "tool";
			// `toolCallId` is read HERE, before the early return, so an unreadable one is a recorded
			// failure that forces a record even when nothing else was redacted. Reading it later (after the
			// redactions) was the bug: a throw there escaped to the outer catch and discarded the patch.
			const toolCallIdField = readEventField(e, "toolCallId");
			if (!toolCallIdField.ok) {
				eventReadFailed = true;
				globalThis.console?.error?.(
					`[secret-echo-guard] reading toolCallId failed; the identity field is left UNREADABLE: ${safeDiagnostic(toolCallIdField.error, values)}`,
				);
			}

			// Read `content` and `details` ONCE each. The harvest walk and the redaction walk must see
			// the SAME object, or a getter-shaped field could be inspected one way and redacted another.
			// An unreadable field is treated as a walk failure (leave it unredacted, record it) rather
			// than aborting the whole handler — the other field is still redacted.
			let rawContent: unknown;
			let rawDetails: unknown;
			try {
				rawContent = e.content;
			} catch (error) {
				contentRedactionFailed = true;
				globalThis.console?.error?.(
					`[secret-echo-guard] reading content failed; content is left UNREDACTED: ${safeDiagnostic(error, values)}`,
				);
			}
			try {
				rawDetails = e.details;
			} catch (error) {
				detailsRedactionFailed = true;
				globalThis.console?.error?.(
					`[secret-echo-guard] reading details failed; details are left UNREDACTED: ${safeDiagnostic(error, values)}`,
				);
			}

			// Source 5: harvest dotenv-shaped assignments from the text about to be redacted, so a
			// `.env` that pi never sourced is still closed for the exact read that exposed it. GATED on
			// the tool having been aimed at an env-like file (see `envSourceFromInput`) — and attempted
			// even when the static registry is empty, because an unsourced `.env` is exactly the case
			// the config/env sources cannot see.
			const harvested: SecretValue[] = [];
			const harvestBudget = newDetailsBudget(hooks.detailsHarvestLimits?.() ?? {});
			const inputField = readEventField(e, "input");
			if (!inputField.ok) {
				eventReadFailed = true;
				globalThis.console?.error?.(
					`[secret-echo-guard] reading input failed; an unsourced .env value in this result may be UNREDACTED: ${safeDiagnostic(inputField.error, values)}`,
				);
			}
			const sourceName = inputField.ok ? envSourceFromInput(inputField.value) : undefined;
			if (sourceName) {
				// (1) The CONTENT harvest, guarded on its own. A hostile part must not abort the details
				// harvest or the redaction pass that follows.
				try {
					for (const part of asArray(rawContent)) {
						if (part && typeof part === "object" && (part as { type?: unknown }).type === "text") {
							const text = (part as { text?: unknown }).text;
							if (typeof text === "string") harvestDotenvSecrets(text, harvested, sourceName);
						}
					}
					if (typeof rawContent === "string") harvestDotenvSecrets(rawContent, harvested, sourceName);
				} catch (error) {
					contentHarvestFailed = true;
					globalThis.console?.error?.(
						`[secret-echo-guard] content harvest failed; an unsourced .env value in this result may be UNREDACTED: ${safeDiagnostic(error, values)}`,
					);
				}
				// (2) The DETAILS harvest, guarded on its own — this is the walk that used to run unguarded
				// and, on a throwing getter, escaped into the outer catch and discarded the content
				// redaction entirely (a real leak). `details` is where an `edit` keeps its whole change
				// (`details.diff`/`details.patch`), which `content` never carries, and where
				// `task`/`subagent` nested messages live. A throw here must NOT escape.
				try {
					const detailStrings: string[] = [];
					collectDetailsStrings(rawDetails, detailStrings, harvestBudget, new WeakSet<object>(), 0);
					for (const text of detailStrings) harvestDotenvSecrets(text, harvested, sourceName);
				} catch (error) {
					detailsHarvestFailed = true;
					harvestBudget.bounded = true; // part of `details` was not inspected for source-5 values
					globalThis.console?.error?.(
						`[secret-echo-guard] details harvest failed; an unsourced .env value in details may be UNREDACTED: ${safeDiagnostic(error, values)}`,
					);
				}
				if (harvested.length > 0) {
					retainHarvested(harvested, hooks);
					// Static-first concatenation: a value already known from a config/env source keeps its
					// more precise label (normalize does a first-wins dedupe by value).
					values = normalizeSecretValues([...values, ...harvested]);
				}
			}
			// Nothing registered and no harvest/event failure → the remainder would be pure cost on every result.
			// A FAILED harvest or unreadable event field still proceeds: it may have missed a value, so the
			// durable record must be written even when there is nothing to redact.
			if (values.length === 0 && !contentHarvestFailed && !detailsHarvestFailed && !eventReadFailed) return undefined;

			const contentHits: HitCounts = new Map();
			const detailsHits: HitCounts = new Map();
			// The CONTENT redaction, guarded on its own: a throw (a hostile content part, a Proxy array)
			// leaves content unredacted and RECORDED, while the details patch is still emitted below.
			let content: RedactOutcome<unknown> & { incomplete: boolean } = {
				value: rawContent,
				changed: false,
				incomplete: false,
			};
			if (!contentRedactionFailed) {
				try {
					content = redactContent(rawContent, values, contentHits);
					// A hostile PART does not abort the walk now, but the walk did not inspect everything —
					// record it so a partially-inspected result is never presented as a full redaction, and
					// say so on stderr (a silent guard failure is indistinguishable from a working one).
					if (content.incomplete) {
						contentRedactionFailed = true;
						globalThis.console?.error?.(
							"[secret-echo-guard] content redaction could not inspect every content part; any secret in an uninspected part is left UNREDACTED.",
						);
					}
				} catch (error) {
					contentRedactionFailed = true;
					content = { value: rawContent, changed: false, incomplete: false };
					globalThis.console?.error?.(
						`[secret-echo-guard] content redaction failed; the content is left UNREDACTED: ${safeDiagnostic(error, values)}`,
					);
				}
			}
			// The DETAILS redaction, guarded on its own. A throw must NEVER discard the content
			// redaction that already succeeded.
			let details: RedactOutcome<unknown> & { bounded: boolean } = {
				value: rawDetails,
				changed: false,
				bounded: false,
			};
			if (!detailsRedactionFailed) {
				try {
					details = redactDetails(rawDetails, values, detailsHits);
				} catch (error) {
					detailsRedactionFailed = true;
					details = { value: rawDetails, changed: false, bounded: true };
					globalThis.console?.error?.(
						`[secret-echo-guard] details redaction failed; ${
							content.changed
								? "the content redaction is still applied, but details are left UNREDACTED"
								: "details are left UNREDACTED"
						}: ${safeDiagnostic(error, values)}`,
					);
				}
			}
			// A bounded/failed HARVEST means part of `details` was never inspected for source-5 values
			// either. The two walks have SEPARATE budgets (the harvest's deadline is set before the
			// content-harvest loop, so it can bound while the redaction walk completes), so the harvest's
			// bound is ORed in explicitly — a bounded harvest is never presented as a complete walk.
			const detailsWalkBounded = details.bounded || harvestBudget.bounded || detailsHarvestFailed;
			const anyFailure =
				contentHarvestFailed ||
				detailsHarvestFailed ||
				contentRedactionFailed ||
				detailsRedactionFailed ||
				eventReadFailed;
			// A failure with nothing redacted STILL writes the record: a failure that discards data is
			// undetectable after the fact otherwise (the previous defect).
			if (!content.changed && !details.changed && !detailsWalkBounded && !anyFailure) return undefined;

			// Counts are merged ONLY from walks whose result is actually emitted, so the record cannot
			// claim a redaction that was discarded by a later throw.
			const hits: HitCounts = new Map();
			if (content.changed) for (const [label, count] of contentHits) addHit(hits, label, count);
			if (details.changed) for (const [label, count] of detailsHits) addHit(hits, label, count);

			const identity = sessionInfo(ctx);
			const record = {
				kind: "secret-echo-guard-redaction",
				// Identity fields are outbound text: run them through the redactor like everything else.
				// The record is the guard's own proof artifact — a secret in `toolCallId`/`sessionId`/
				// `sessionFile`/`toolName` must not reach it (nor the fleet log, nor `pi.appendEntry`).
				sessionId: sanitizeOutboundString(identity.sessionId, values),
				sessionFile: sanitizeOutboundString(identity.sessionFile, values),
				ts: Date.now(),
				toolName: sanitizeOutboundString(toolName, values),
				toolCallId: sanitizeOutboundString(
					toolCallIdField.ok && typeof toolCallIdField.value === "string" ? toolCallIdField.value : null,
					values,
				),
				// LABELS AND COUNTS ONLY. Never a value, and never derived from a value.
				hits: [...hits.entries()].map(([label, count]) => ({ label, count })),
				total: hitsTotal(hits),
				contentRedacted: content.changed,
				detailsRedacted: details.changed,
				contentRedactionFailed,
				detailsRedactionFailed,
				harvestFailed: contentHarvestFailed || detailsHarvestFailed,
				eventReadFailed,
				detailsWalkBounded,
			};

			// (a) durable session entry
			try {
				pi.appendEntry(SECRET_ECHO_GUARD_ENTRY_TYPE, record);
			} catch (error) {
				// The diagnostic is redacted before it is logged (see safeDiagnostic).
				globalThis.console?.error?.(`[secret-echo-guard] appendEntry sink failed: ${safeDiagnostic(error, values)}`);
			}
			// (b) fleet log
			try {
				const dir = join(hooks.homedir(), ".pi", "agent", "state");
				hooks.mkdir(dir, { recursive: true });
				hooks.appendFile(join(dir, SECRET_ECHO_GUARD_LOG), `${JSON.stringify(record)}\n`);
			} catch (error) {
				globalThis.console?.error?.(`[secret-echo-guard] fleet-log sink failed: ${safeDiagnostic(error, values)}`);
			}
			// (c) loud at the pane. The redaction summary fires ONCE per session; a BOUNDED walk or a FAILED
			// walk is a per-result fact, so EVERY such result is announced (not just the first — the earlier
			// `warnedBounded` latch announced only one bounded walk per session while the header claimed
			// otherwise). The durable record carries the same flags on every result, so the attestation is
			// per-result either way; the pane warning is the best-effort loud half.
			try {
				const { sessionId, sessionFile } = sessionInfo(ctx);
				const key = sessionId ?? sessionFile ?? "(unknown-session)";
				const labels = record.hits.map((hit) => hit.label).join(", ") || "unknown source";
				const boundedWarning =
					" WARNING: the result's `details` exceeded the redaction walk bound — part of it was NOT inspected, so it was NOT fully redacted.";
				const failureWarning =
					" WARNING: the guard FAILED on part of this result — that part is left UNREDACTED.";
				const isFirst = !announced.has(key);
				if (isFirst) announced.add(key);
				if (isFirst) {
					const summary =
						content.changed || details.changed
							? `redacted ${record.total} secret value(s) from a ${String(record.toolName)} result (${labels}). The value(s) are NOT in this session transcript.`
							: "no secret value was redacted from this result.";
					const text = `[secret-echo-guard] ${summary}${detailsWalkBounded ? boundedWarning : ""}${anyFailure ? failureWarning : ""}`;
					globalThis.console?.error?.(text);
					(ctx as { ui?: { notify?: (message: string, type?: string) => void } } | null | undefined)?.ui?.notify?.(
						text,
						"warning",
					);
				} else if (detailsWalkBounded || anyFailure) {
					// Per-result: a bounded OR failed walk never rides on the once-per-session summary.
					const text = `[secret-echo-guard]${detailsWalkBounded ? boundedWarning : ""}${anyFailure ? failureWarning : ""}`;
					globalThis.console?.error?.(text);
					(ctx as { ui?: { notify?: (message: string, type?: string) => void } } | null | undefined)?.ui?.notify?.(
						text,
						"warning",
					);
				}
			} catch (error) {
				globalThis.console?.error?.(`[secret-echo-guard] announce failed: ${safeDiagnostic(error, values)}`);
			}

			// FAIL OPEN ON THE TURN: a partial patch, so omitted fields keep their current values.
			// When a secret is found the failing-closed decision has already been made; the turn itself
			// is never broken. An empty patch (a bounded-but-clean walk, or a failure with nothing to
			// patch) returns undefined, which the runner treats as "no handler modified this result".
			const patch: { content?: unknown; details?: unknown } = {};
			if (content.changed) patch.content = content.value;
			if (details.changed) patch.details = details.value;
			return Object.keys(patch).length > 0 ? patch : undefined;
		} catch (error) {
			// FAIL OPEN ON THE TURN: no patch, so the tool result is left as the tool produced it. The
			// failure is announced (a silent guard failure is indistinguishable from a working one), and
			// the diagnostic is redacted before it is logged.
			globalThis.console?.error?.(`[secret-echo-guard] handler failed; result left UNREDACTED: ${safeDiagnostic(error, values)}`);
			return undefined;
		}
	});
}

function asArray(value: unknown): unknown[] {
	return Array.isArray(value) ? value : [];
}
