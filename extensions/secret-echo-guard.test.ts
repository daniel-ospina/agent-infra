// secret-echo-guard.test.ts — #5109
// Run: npx tsx extensions/secret-echo-guard.test.ts
//
// Zero-dep, stdlib-only: the extension imports `@earendil-works/pi-coding-agent` as a TYPE only
// (erased by tsx), so this suite needs no mocks, no pi runtime and no `npm ci`. Every filesystem
// sink (config reads, the fleet log, the durable session entry) runs through the NODE_ENV=test hook
// seam, so the suite never touches the real ~/.pi and never reads a real secret.
//
// The registry is driven by a CONTROLLED env (`hooks.env`), not the test process's own environment,
// so the suite is deterministic and does not depend on which API keys happen to be exported.
//
// Negative controls are first-class here: an ordinary tool result must be returned BY REFERENCE
// (the handler answers `undefined`, i.e. "no patch") and must record nothing. A test that only
// proves the redaction path proves nothing about the cost of being wrong in the other direction.
//
// PRINT MODE (#5109 requirement 6) is pinned structurally: the extension never consults `PI_MODE`
// or argv, and the two tests under "print mode" assert that the handler is registered and redacts
// with `PI_MODE=print` set and with `-p` in argv. Re-introducing a print-mode gate turns them RED.

process.env.NODE_ENV = "test";
delete process.env.SECRET_ECHO_GUARD;
delete process.env.SECRET_ECHO_GUARD_MIN_LENGTH;
delete process.env.PI_MODE;

import { deepEqual, equal, ok, strictEqual } from "node:assert/strict";
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import secretEchoGuard, {
	CONTENT_PART_LIMITS,
	LABEL_VALUE_REPLACEMENT,
	MAX_DETAILS_DEPTH,
	MAX_SOURCE_FILE_BYTES,
	MIN_SECRET_LENGTH,
	REDACTION_MARKER_BASE,
	SECRET_ECHO_GUARD_ENTRY_TYPE,
	SECRET_ECHO_GUARD_LOG,
	_secretEchoGuardCounters,
	_setSecretEchoGuardHooksForTest,
	_resetSecretEchoGuardAnnouncementsForTest,
	_resetSecretEchoGuardCacheForTest,
	collectAllStringValues,
	collectDetailsStrings,
	collectEnvSecrets,
	collectJsonSecrets,
	getRegistryValues,
	harvestDotenvSecrets,
	hitsTotal,
	identifierTokens,
	envSourceFromInput,
	isSecretValueKey,
	isUsableSecretValue,
	loadStaticRegistry,
	normalizeSecretValues,
	parseEnvFile,
	redactContent,
	redactDetails,
	redactString,
	redactionMarker,
	secretEchoGuardActive,
} from "./secret-echo-guard.ts";

// ── Assertion plumbing (stdlib only, no test runner) ────────────────────────────────────────
let passed = 0;
const failures: string[] = [];
function test(name: string, fn: () => void | Promise<void>): Promise<void> | void {
	try {
		const result = fn();
		if (result && typeof (result as Promise<void>).then === "function") {
			return (result as Promise<void>).then(
				() => {
					passed++;
					console.log(`  ✅ ${name}`);
				},
				(error: unknown) => {
					failures.push(`${name}: ${error instanceof Error ? error.message : String(error)}`);
					console.log(`  ❌ ${name} — ${error instanceof Error ? error.message : String(error)}`);
				},
			);
		}
		passed++;
		console.log(`  ✅ ${name}`);
	} catch (error) {
		failures.push(`${name}: ${error instanceof Error ? error.message : String(error)}`);
		console.log(`  ❌ ${name} — ${error instanceof Error ? error.message : String(error)}`);
	}
	return undefined;
}

// ── Fixture home + controlled env ───────────────────────────────────────────────────────────
const HOME = mkdtempSync(join(tmpdir(), "secret-echo-guard-"));
const AGENT_DIR = join(HOME, ".pi", "agent");
const ENVFILE = join(HOME, "fixtures", "app.env");
mkdirSync(AGENT_DIR, { recursive: true });
mkdirSync(join(HOME, "fixtures"), { recursive: true });

const TORTOISE_KEY = "TORTOISE-KEY-0123456789ABCDEF";
const MODELS_LITERAL_KEY = "MODELS-LITERAL-KEY-0123456789";
const MODELS_REFERENCE = "$DEEPSEEK_API_KEY";
const AUTH_KEY = "AUTH-STORED-KEY-0123456789XYZ";
const AUTH_REFRESH = "AUTH-REFRESH-TOKEN-0123456789";
const JEV_KEY = "JEV-KEY-0123456789ABCDEF";
const ENVFILE_KEY = "ENVFILE-JEV-KEY-0123456789";
const PROCESS_ENV_KEY = "PROCESS-ENV-DEEPSEEK-0123456789";
const MODELS_STORE_KEY = "MODELS-STORE-KEY-MUST-NOT-REGISTER";
const SHORT_SECRET = "zzq"; // deliberately under MIN_SECRET_LENGTH
const POINTER_VALUE = "/tmp/not/a/secret/pointer/path/abcdefgh";

writeFileSync(
	join(AGENT_DIR, "tortoise-config.json"),
	JSON.stringify({ autoCapture: true, cloud: false, apiUrl: "https://tortoise.example", apiKey: TORTOISE_KEY }),
);
writeFileSync(
	join(AGENT_DIR, "models.json"),
	JSON.stringify({
		providers: {
			deepseek: { baseUrl: "https://api.deepseek.com", apiKey: MODELS_REFERENCE },
			openrouter: { apiKey: MODELS_LITERAL_KEY, models: [{ id: "x", maxTokens: 4096, maxTokensField: "max_tokens" }] },
		},
	}),
);
writeFileSync(join(AGENT_DIR, "auth.json"), JSON.stringify({ deepseek: { type: "api_key", key: AUTH_KEY }, anthropic: { type: "oauth", refresh: AUTH_REFRESH, access: "AUTH-ACCESS-0123456789", expires: 1 } }));
writeFileSync(join(AGENT_DIR, "jev-config.json"), JSON.stringify({ apiKey: JEV_KEY, model: "gpt-x" }));
writeFileSync(join(AGENT_DIR, "settings.json"), JSON.stringify({ theme: "dark", compaction: { reserveTokens: 4096 } }));
// models-store.json is on the skip list — a secret-shaped field here MUST NOT enter the registry.
writeFileSync(join(AGENT_DIR, "models-store.json"), JSON.stringify({ providers: { x: { apiKey: MODELS_STORE_KEY } } }));
writeFileSync(ENVFILE, `# fixture env\nJEV_API_KEY=${ENVFILE_KEY}\nSORT_KEY=ENVFILE-SORT-KEY-NOT-A-SECRET\nAGENT_SYNC_MODE=auto\n`);

const controlledEnv: Record<string, string | undefined> = {
	PATH: "/usr/bin:/bin",
	DEEPSEEK_API_KEY: PROCESS_ENV_KEY,
	ZAI_API_KEY: "$A-REFERENCE-NOT-A-SECRET", // a reference, not a value
	TINY_PASSWORD: SHORT_SECRET, // under the floor
	CMUX_CUA_AUTH_TOKEN_FILE: POINTER_VALUE, // a pointer, not a secret
	SECRET_ECHO_GUARD_ENV_FILES: ENVFILE,
};

let readFileCount = 0;
const appendFileLines: string[] = [];
const appendEntryCalls: Array<{ type: string; data: unknown }> = [];
const notifications: Array<{ msg: string; type?: string }> = [];
const consoleErrors: string[] = [];
const realConsoleError = console.error;

const baseHooks = {
	homedir: () => HOME,
	cwd: () => join(HOME, "no-cwd-env-file"),
	env: () => controlledEnv,
	// Explicitly present-but-undefined so a test that overrides it is reset by
	// `_setSecretEchoGuardHooksForTest(baseHooks)` (Object.assign does not delete keys).
	detailsHarvestLimits: undefined,
	readFile: ((path: string) => {
		readFileCount++;
		return readFileSync(path, "utf8");
	}) as never,
	appendFile: ((path: string, data: string) => {
		if (String(path).endsWith(SECRET_ECHO_GUARD_LOG)) appendFileLines.push(data);
	}) as never,
	mkdir: (() => undefined) as never,
};
_setSecretEchoGuardHooksForTest(baseHooks);
console.error = (...args: unknown[]) => {
	consoleErrors.push(args.map((arg) => String(arg)).join(" "));
};

function resetEverything(): void {
	_resetSecretEchoGuardCacheForTest();
	_resetSecretEchoGuardAnnouncementsForTest();
	appendFileLines.length = 0;
	appendEntryCalls.length = 0;
	notifications.length = 0;
	consoleErrors.length = 0;
}

function fakeCtx(sessionId = "session-1") {
	return {
		sessionManager: { getSessionId: () => sessionId, getSessionFile: () => `${sessionId}.jsonl` },
		ui: { notify: (msg: string, type?: string) => notifications.push({ msg, type }) },
	};
}

function fakePi() {
	const handlers = new Map<string, (event: unknown, ctx: unknown) => unknown>();
	return {
		handlers,
		on: (name: string, fn: (event: unknown, ctx: unknown) => unknown) => handlers.set(name, fn),
		appendEntry: (type: string, data: unknown) => appendEntryCalls.push({ type, data }),
	};
}

function toolResultEvent(overrides: Record<string, unknown> = {}) {
	// A NEUTRAL input path by default: harvesting is gated on env-like sources, so registry tests
	// must not accidentally exercise the harvest path (and the harvest tests set their own input).
	return { type: "tool_result", toolName: "read", toolCallId: "call-1", input: { path: "/repo/notes.txt" }, content: [], isError: false, ...overrides };
}

function runHandler(event: Record<string, unknown>, ctx: unknown = fakeCtx()) {
	const pi = fakePi();
	secretEchoGuard(pi as never);
	const handler = pi.handlers.get("tool_result");
	if (!handler) throw new Error("tool_result was not registered");
	return { returned: handler(event, ctx), pi };
}

// ── Field-name classification ───────────────────────────────────────────────────────────────
console.log("\nfield-name classification (the explicit list, both directions)");
test("identifierTokens splits separators AND camelCase", () => {
	deepEqual(identifierTokens("ANTHROPIC_API_KEY"), ["anthropic", "api", "key"]);
	deepEqual(identifierTokens("maxTokensField"), ["max", "tokens", "field"]);
	deepEqual(identifierTokens("openaiApiKey"), ["openai", "api", "key"]);
	deepEqual(identifierTokens("MONKEY"), ["monkey"]);
});
test("POSITIVE: secret-bearing names are recognised (env and field)", () => {
	for (const name of ["ANTHROPIC_API_KEY", "apiKey", "GH_TOKEN", "PASSWORD", "refreshToken", "clientSecret", "privateKey"]) {
		strictEqual(isSecretValueKey(name, "field"), true, `${name} must be a field secret`);
		strictEqual(isSecretValueKey(name, "env"), true, `${name} must be an env secret`);
	}
});
test("POSITIVE (env only): a trailing _KEY with no qualifier — BLOG_AGENT_KEY is a real secret", () => {
	strictEqual(isSecretValueKey("BLOG_AGENT_KEY", "env"), true);
	// but the STRICT field rule refuses the same shape, so camelCase JSON `sortKey` stays safe
	strictEqual(isSecretValueKey("sortKey", "field"), false);
});
test("NEGATIVE: ordinary config/output names are NOT secrets", () => {
	for (const name of ["maxTokensField", "maxTokens", "model", "baseUrl", "apiUrl", "theme", "count", "id", "expires", "truncatedBy", "autoCapture", "heartbeat"]) {
		strictEqual(isSecretValueKey(name, "field"), false, `${name} must not be a field secret`);
	}
});
test("NEGATIVE: a pointer name is not the secret (*_FILE / *_PATH / *_URL)", () => {
	strictEqual(isSecretValueKey("CMUX_CUA_AUTH_TOKEN_FILE", "env"), false);
	strictEqual(isSecretValueKey("SECRET_ECHO_GUARD_ENV_FILES", "env"), false);
	strictEqual(isSecretValueKey("MY_TOKEN_URL", "env"), false);
});
test("NEGATIVE: a client ID is not a client secret", () => {
	strictEqual(isSecretValueKey("SUPABASE_AUTH_EXTERNAL_GOOGLE_CLIENT_ID", "env"), false);
	strictEqual(isSecretValueKey("SUPABASE_AUTH_EXTERNAL_GOOGLE_SECRET", "env"), true);
});

// ── Value filter / floor ────────────────────────────────────────────────────────────────────
console.log("\nthe length floor and reference filter");
test(`floor: ${MIN_SECRET_LENGTH - 1} chars is rejected, ${MIN_SECRET_LENGTH} chars is accepted`, () => {
	strictEqual(isUsableSecretValue("a".repeat(MIN_SECRET_LENGTH - 1)), false);
	strictEqual(isUsableSecretValue("a".repeat(MIN_SECRET_LENGTH)), true);
	strictEqual(isUsableSecretValue(SHORT_SECRET), false);
});
test("a config REFERENCE ($VAR / !cmd) is not registered as a value", () => {
	strictEqual(isUsableSecretValue("$DEEPSEEK_API_KEY"), false);
	strictEqual(isUsableSecretValue("!security find-generic-password -w"), false);
});
test("non-strings are skipped (a numeric PIN is not registered)", () => {
	strictEqual(isUsableSecretValue(123456789012), false);
	strictEqual(isUsableSecretValue(null), false);
	strictEqual(isUsableSecretValue(undefined), false);
});

// ── normalize / redact primitives ───────────────────────────────────────────────────────────
console.log("\nnormalize + redact primitives");
test("normalizeSecretValues dedupes by value and sorts LONGEST-FIRST", () => {
	const values = normalizeSecretValues([
		{ value: "abcdef", label: "short" },
		{ value: "abcdefghij", label: "long" },
		{ value: "abcdefghij", label: "dupe" },
	]);
	strictEqual(values.length, 2);
	strictEqual(values[0].label, "long", "the longest value must be replaced first");
});
test("a secret that is a substring of another is not broken into marker debris", () => {
	const values = normalizeSecretValues([
		{ value: "ABCDEFGHIJKL", label: "inner" },
		{ value: "XXXXXXABCDEFGHIJKLYYYY", label: "outer" },
	]);
	const hits = new Map<string, number>();
	const out = redactString(`v=XXXXXXABCDEFGHIJKLYYYY w=ABCDEFGHIJKL`, values, hits);
	equal(out, `v=[REDACTED-SECRET:outer] w=[REDACTED-SECRET:inner]`);
	strictEqual(hitsTotal(hits), 2);
});
test("redactString counts every occurrence", () => {
	const values = normalizeSecretValues([{ value: "SECRETVALUE1234", label: "l" }]);
	const hits = new Map<string, number>();
	redactString("SECRETVALUE1234 and SECRETVALUE1234", values, hits);
	strictEqual(hits.get("l"), 2);
});
test("parseEnvFile: export prefix, quotes, trailing comments, malformed lines", () => {
	deepEqual(parseEnvFile(`export A_KEY="v1"\nB_TOKEN='v2' # note\nC=plain # note\n# comment\nnot a line\nD_EMPTY=\n`), [
		{ key: "A_KEY", value: "v1" },
		{ key: "B_TOKEN", value: "v2" },
		{ key: "C", value: "plain" },
		{ key: "D_EMPTY", value: "" },
	]);
});
test("harvestDotenvSecrets takes ONLY secret-named assignments", () => {
	const into: Array<{ value: string; label: string }> = [];
	const added = harvestDotenvSecrets(`AGENT_SYNC_MODE=auto\nJEV_API_KEY=${JEV_KEY}\nmaxTokens=4096\n`, into, "app.env");
	strictEqual(added, 1);
	strictEqual(into.length, 1);
	strictEqual(into[0].label, "read:app.env#JEV_API_KEY");
});
test("harvestDotenvSecrets is a no-op on ordinary output (cheap pre-check)", () => {
	const into: Array<{ value: string; label: string }> = [];
	strictEqual(harvestDotenvSecrets("const a=1\nfunction f(){return 2}\n", into, "x.ts"), 0);
	strictEqual(into.length, 0);
});
test("envSourceFromInput gates the harvest on an env-like SOURCE (read path and bash command)", () => {
	strictEqual(envSourceFromInput({ path: "/repo/.env" }), ".env");
	strictEqual(envSourceFromInput({ path: "/repo/.env.production" }), ".env.production");
	strictEqual(envSourceFromInput({ path: "/repo/app.env" }), "app.env");
	strictEqual(envSourceFromInput({ path: "/repo/environment.md" }), undefined);
	strictEqual(envSourceFromInput({ path: "/repo/notes.txt" }), undefined);
	strictEqual(envSourceFromInput({ command: "cat /repo/.env | head -5" }), ".env");
	strictEqual(envSourceFromInput({ command: "ls -la" }), undefined);
	strictEqual(envSourceFromInput(undefined), undefined);
});

// ── The registry from the fixture sources ───────────────────────────────────────────────────
console.log("\nthe registry (fixture home + controlled env)");

function optionsFor(home = HOME, env = controlledEnv) {
	return {
		homedir: home,
		cwd: join(home, "no-cwd-env-file"),
		env,
		readFile: (path: string) => readFileSync(path, "utf8"),
		readdir: (path: string) => readdirSync(path) as string[],
		stat: (path: string) => {
			const info = statSync(path);
			return { mtimeMs: info.mtimeMs, size: info.size };
		},
	};
}

test("collects every documented source, and NOTHING else", () => {
	const values = loadStaticRegistry(optionsFor());
	const byValue = new Map(values.map((v) => [v.value, v.label]));
	strictEqual(byValue.get(TORTOISE_KEY), "tortoise-config.json#apiKey");
	strictEqual(byValue.get(MODELS_LITERAL_KEY), "models.json#providers.openrouter.apiKey");
	strictEqual(byValue.get(AUTH_KEY), "auth.json#deepseek.key");
	strictEqual(byValue.get(AUTH_REFRESH), "auth.json#anthropic.refresh", "auth.json is ALL-values-secret");
	strictEqual(byValue.get(JEV_KEY), "jev-config.json#apiKey");
	strictEqual(byValue.get(ENVFILE_KEY), `env-file:app.env#JEV_API_KEY`);
	strictEqual(byValue.get(PROCESS_ENV_KEY), "env:DEEPSEEK_API_KEY");
});
test("NEGATIVE: references, pointers, short values, ordinary fields and skipped files stay OUT", () => {
	const values = loadStaticRegistry(optionsFor()).map((v) => v.value);
	for (const forbidden of [
		MODELS_REFERENCE,
		"$A-REFERENCE-NOT-A-SECRET",
		SHORT_SECRET,
		POINTER_VALUE,
		"https://tortoise.example",
		"gpt-x",
		"dark",
		MODELS_STORE_KEY,
	]) {
		ok(!values.includes(forbidden), `${forbidden} must NOT be registered`);
	}
});
test("collectJsonSecrets recurses into nested objects and arrays", () => {
	const out: Array<{ value: string; label: string }> = [];
	collectJsonSecrets({ a: { b: [{ apiToken: JEV_KEY, keep: "x" }] } }, "f", out);
	deepEqual(out, [{ value: JEV_KEY, label: "f#a.b[0].apiToken" }]);
});
test("collectAllStringValues takes every string (auth.json rule)", () => {
	const out: Array<{ value: string; label: string }> = [];
	collectAllStringValues({ p: { key: AUTH_KEY, refresh: AUTH_REFRESH } }, "auth.json", out);
	strictEqual(out.length, 2);
});
test("collectEnvSecrets takes secret-named vars only", () => {
	const out: Array<{ value: string; label: string }> = [];
	collectEnvSecrets({ FOO_API_KEY: PROCESS_ENV_KEY, PATH: "/usr/bin:/bin:/long", NOPE: "notsecretvalue" }, "env:", out);
	deepEqual(out, [{ value: PROCESS_ENV_KEY, label: "env:FOO_API_KEY" }]);
});

// ── Cache ───────────────────────────────────────────────────────────────────────────────────
console.log("\nregistry cache (stat-refreshed, not re-read per call)");
test("the registry is read ONCE and reused while the sources are unchanged", () => {
	resetEverything();
	readFileCount = 0;
	const first = getRegistryValues();
	const readsAfterFirst = readFileCount;
	ok(readsAfterFirst > 0, "the first call must read the sources");
	for (let i = 0; i < 25; i++) getRegistryValues();
	strictEqual(readFileCount, readsAfterFirst, "no further reads while the signature is unchanged");
	ok(first.length > 0);
});
test("a CHANGED source file is picked up on the next call (mtime/size refresh)", () => {
	resetEverything();
	const target = join(AGENT_DIR, "jev-config.json");
	const original = readFileSync(target, "utf8");
	try {
		const before = getRegistryValues().map((v) => v.value);
		const rotated = "JEV-ROTATED-KEY-0123456789";
		writeFileSync(target, JSON.stringify({ apiKey: rotated, model: "gpt-x" }));
		const future = new Date(Date.now() + 5000);
		utimesSync(target, future, future);
		const after = getRegistryValues().map((v) => v.value);
		ok(after.includes(rotated), "the rotated value must be registered after the source changes");
		ok(!after.includes(JEV_KEY), "the old value must be gone from the static set");
		ok(before.includes(JEV_KEY));
	} finally {
		writeFileSync(target, original);
		resetEverything();
	}
});

// ── The handler: redaction of BOTH persisted fields ─────────────────────────────────────────
console.log("\ntool_result handler — content");
test("ARRAY content (the verified read/bash shape) is redacted", () => {
	resetEverything();
	const event = toolResultEvent({ content: [{ type: "text", text: `key=${TORTOISE_KEY} done` }] });
	const { returned } = runHandler(event);
	ok(returned, "a patch is required");
	const content = (returned as { content: Array<{ text: string }> }).content;
	equal(content[0].text, `key=[REDACTED-SECRET:tortoise-config.json#apiKey] done`);
	ok(!JSON.stringify(returned).includes(TORTOISE_KEY));
});
test("STRING content (defensive shape) is CONVERTED to the array shape pi can consume", () => {
	resetEverything();
	const { returned } = runHandler(toolResultEvent({ content: `key=${TORTOISE_KEY}` }));
	ok(returned);
	const content = (returned as { content: Array<{ type: string; text: string }> }).content;
	ok(Array.isArray(content), "pi's normalizeToolResultImages calls content.some(...) — a bare string would crash it");
	equal(content[0].text, `key=[REDACTED-SECRET:tortoise-config.json#apiKey]`);
});
test("non-text content parts and extra fields are preserved BY REFERENCE", () => {
	resetEverything();
	const image = { type: "image", data: "AAAA", mimeType: "image/png" };
	const text = { type: "text", text: TORTOISE_KEY, extra: 7 };
	const { returned } = runHandler(toolResultEvent({ content: [text, image] }));
	ok(returned);
	const content = (returned as { content: Array<unknown> }).content;
	strictEqual(content[1], image, "an untouched part keeps its identity");
	strictEqual((content[0] as { extra: number }).extra, 7, "sibling fields survive");
});

console.log("\ntool_result handler — details (both persisted, recursively)");
test("details.truncation.content is redacted (the read/bash truncation shape)", () => {
	resetEverything();
	const { returned } = runHandler(
		toolResultEvent({ content: [{ type: "text", text: "truncated preview" }], details: { truncation: { content: `x ${MODELS_LITERAL_KEY}`, truncated: true } } }),
	);
	ok(returned, "a patch is required for a details-only hit");
	const patch = returned as { content?: unknown; details?: { truncation: { content: string } } };
	strictEqual(patch.content, undefined, "content is omitted so the runner keeps the current value");
	equal(patch.details?.truncation.content, `x [REDACTED-SECRET:models.json#providers.openrouter.apiKey]`);
});
test("deeply nested details (subagent-shape messages) are redacted", () => {
	resetEverything();
	const details = {
		mode: "parallel",
		results: [{ agent: "x", messages: [{ role: "toolResult", content: [{ type: "text", text: `read ${PROCESS_ENV_KEY}` }] }] }],
	};
	const { returned } = runHandler(toolResultEvent({ content: [{ type: "text", text: "no secret here" }], details }));
	ok(returned);
	const serialized = JSON.stringify((returned as { details: unknown }).details);
	ok(!serialized.includes(PROCESS_ENV_KEY), "the nested value must be gone");
	ok(serialized.includes("[REDACTED-SECRET:env:DEEPSEEK_API_KEY]"));
});
test("an edit-shape diff/patch string is redacted", () => {
	resetEverything();
	const { returned } = runHandler(toolResultEvent({ toolName: "edit", content: [], details: { diff: `+ ${AUTH_KEY}`, patch: AUTH_KEY } }));
	ok(returned);
	ok(!JSON.stringify(returned).includes(AUTH_KEY));
});

// ── The handler: no-op on ordinary output (proved, not asserted) ────────────────────────────
console.log("\ntool_result handler — NEGATIVE CONTROLS (the guard must be invisible when clean)");
test("ordinary output returns UNDEFINED, is BYTE-IDENTICAL, and records NOTHING", () => {
	resetEverything();
	const content = [{ type: "text", text: "total 12\ndrwxr-xr-x  3 user staff 96 Sep 27 12:00 src\n" }];
	const details = { truncation: { content: "the same ordinary text", truncated: false } };
	const event = toolResultEvent({ content, details });
	const before = structuredClone(event);
	const sinkCounts = { entries: appendEntryCalls.length, logs: appendFileLines.length, notes: notifications.length, errors: consoleErrors.length };
	const { returned } = runHandler(event);
	strictEqual(returned, undefined, "a clean result must not be replaced");
	deepEqual(event, before, "the event must be byte-identical after the handler");
	strictEqual(event.content, content, "the content array keeps its identity");
	strictEqual(event.details, details, "the details object keeps its identity");
	strictEqual(appendEntryCalls.length, sinkCounts.entries);
	strictEqual(appendFileLines.length, sinkCounts.logs);
	strictEqual(notifications.length, sinkCounts.notes);
	strictEqual(consoleErrors.length, sinkCounts.errors);
});
test(`the length floor: a ${SHORT_SECRET.length}-char registered value is NOT redacted`, () => {
	resetEverything();
	const event = toolResultEvent({ content: [{ type: "text", text: `value=${SHORT_SECRET} (the short env var)` }] });
	const { returned } = runHandler(event);
	strictEqual(returned, undefined, "a sub-floor value must never be redacted");
});
test("a value present only as a REFERENCE is not redacted as if it were the secret", () => {
	resetEverything();
	const event = toolResultEvent({ content: [{ type: "text", text: `apiKey: ${MODELS_REFERENCE}` }] });
	const { returned } = runHandler(event);
	strictEqual(returned, undefined);
});

// ── The guard never writes the secret anywhere ──────────────────────────────────────────────
console.log("\nthe guard must not leak what it redacted");
test("NO sink carries the value; the durable record carries labels + counts", () => {
	resetEverything();
	const event = toolResultEvent({ content: [{ type: "text", text: `${JEV_KEY}` }], details: { truncation: { content: `${JEV_KEY}` } } });
	const { returned } = runHandler(event);
	ok(returned);
	const sinks = [
		...appendEntryCalls.map((call) => JSON.stringify(call)),
		...appendFileLines,
		...notifications.map((note) => note.msg),
		...consoleErrors,
	];
	for (const secret of [JEV_KEY, TORTOISE_KEY, MODELS_LITERAL_KEY, AUTH_KEY, PROCESS_ENV_KEY, ENVFILE_KEY]) {
		for (const sink of sinks) ok(!sink.includes(secret), `a sink leaked ${secret}`);
	}
	const entry = appendEntryCalls.find((call) => call.type === SECRET_ECHO_GUARD_ENTRY_TYPE);
	ok(entry, "a durable session entry is required");
	const data = entry.data as { kind: string; hits: Array<{ label: string; count: number }>; total: number; toolName: string };
	strictEqual(data.kind, "secret-echo-guard-redaction");
	strictEqual(data.total, 2);
	strictEqual(data.hits[0].label, "jev-config.json#apiKey");
	strictEqual(appendFileLines.length, 1, "one fleet-log line");
	strictEqual(notifications.length, 1, "one notice");
	strictEqual(notifications[0].type, "warning");
	ok(notifications[0].msg.includes("NOT in this session transcript"));
	ok(notifications[0].msg.includes("jev-config.json#apiKey"));
});
test("an internal failure is reported WITHOUT the value and leaves the result unredacted", () => {
	resetEverything();
	const hostile = {} as Record<string, unknown>;
	Object.defineProperty(hostile, "boom", {
		enumerable: true,
		get() {
			throw new Error(`exploded while holding ${JEV_KEY}`);
		},
	});
	const event = toolResultEvent({ content: [{ type: "text", text: "ordinary" }], details: hostile });
	const { returned } = runHandler(event);
	strictEqual(returned, undefined, "FAIL OPEN on the turn: no patch, no corruption");
	for (const line of consoleErrors) ok(!line.includes(JEV_KEY), "the error diagnostic must itself be redacted");
	ok(consoleErrors.some((line) => line.includes("UNREDACTED")), "a silent failure is not allowed");
});

// ── A bounded details walk is LOUD, not silent ──────────────────────────────────────────────
console.log("\nthe bounded details walk");
test("a walk that exceeds the depth bound is RECORDED and ANNOUNCED, never silent", () => {
	resetEverything();
	let deep: Record<string, unknown> = { leaf: AUTH_KEY };
	for (let i = 0; i < MAX_DETAILS_DEPTH + 5; i++) deep = { next: deep };
	const { returned } = runHandler(toolResultEvent({ content: [{ type: "text", text: "clean" }], details: deep }));
	strictEqual(returned, undefined, "nothing was redacted, so no patch");
	const entry = appendEntryCalls.find((call) => call.type === SECRET_ECHO_GUARD_ENTRY_TYPE);
	ok(entry, "the incomplete walk must be recorded");
	strictEqual((entry.data as { detailsWalkBounded: boolean }).detailsWalkBounded, true);
	ok(notifications.some((note) => note.msg.includes("WARNING")));
});

// ── Once per session ────────────────────────────────────────────────────────────────────────
console.log("\nnotice discipline");
test("the notice fires ONCE per session while every redaction is still recorded durably", () => {
	resetEverything();
	for (let i = 0; i < 4; i++) runHandler(toolResultEvent({ toolCallId: `call-${i}`, content: [{ type: "text", text: `k=${TORTOISE_KEY}` }] }));
	strictEqual(notifications.length, 1, "no notice spam");
	strictEqual(appendEntryCalls.length, 4, "but every redaction is recorded");
	strictEqual(appendFileLines.length, 4);
});
test("a new session re-arms the notice", () => {
	resetEverything();
	const pi = fakePi();
	secretEchoGuard(pi as never);
	const handler = pi.handlers.get("tool_result")!;
	handler(toolResultEvent({ content: [{ type: "text", text: TORTOISE_KEY }] }), fakeCtx("session-A"));
	strictEqual(notifications.length, 1);
	handler(toolResultEvent({ content: [{ type: "text", text: TORTOISE_KEY }] }), fakeCtx("session-B"));
	strictEqual(notifications.length, 2, "a different session gets its own notice");
});
test("session_start clears the announcement set", () => {
	resetEverything();
	const pi = fakePi();
	secretEchoGuard(pi as never);
	const handler = pi.handlers.get("tool_result")!;
	const sessionStart = pi.handlers.get("session_start")!;
	handler(toolResultEvent({ content: [{ type: "text", text: TORTOISE_KEY }] }), fakeCtx());
	strictEqual(notifications.length, 1);
	sessionStart({ type: "session_start", reason: "new" }, fakeCtx());
	handler(toolResultEvent({ content: [{ type: "text", text: TORTOISE_KEY }] }), fakeCtx());
	strictEqual(notifications.length, 2);
});

// ── Harvesting closes the un-sourced .env read ──────────────────────────────────────────────
console.log("\nharvesting from the result being redacted");
test("a .env assignment that is in NO source is registered and redacted in the same result", () => {
	resetEverything();
	const fresh = "UNSOURCED-ENV-KEY-0123456789";
	const text = `# app config\nJEV_API_KEY=${JEV_KEY}\nOPENROUTER_API_KEY=${fresh}\nAGENT_SYNC_MODE=a-long-non-secret-mode-string\n`;
	const { returned } = runHandler(toolResultEvent({ input: { path: "/repo/app.env" }, content: [{ type: "text", text }] }));
	ok(returned);
	const out = (returned as { content: Array<{ text: string }> }).content[0].text;
	ok(!out.includes(fresh), "the freshly-harvested value must be gone from the same result");
	ok(!out.includes(JEV_KEY), "a registry value must also be gone");
	ok(out.includes("AGENT_SYNC_MODE=a-long-non-secret-mode-string"), "a NON-secret assignment with a LONG value is untouched");
	ok(out.includes("[REDACTED-SECRET:read:app.env#OPENROUTER_API_KEY]"), "the label names the source key");
});
test("a `cat .env` bash result is gated the same way", () => {
	resetEverything();
	const fresh = "BASH-CAT-ENV-KEY-0123456789";
	const { returned } = runHandler(toolResultEvent({ toolName: "bash", input: { command: "cat /repo/sub/.env" }, content: [{ type: "text", text: `OPENROUTER_API_KEY=${fresh}\n` }] }));
	ok(returned);
	ok(!JSON.stringify(returned).includes(fresh));
});
test("a harvested value is redacted from LATER, unrelated results too", () => {
	resetEverything();
	const fresh = "LATER-RESULT-ONLY-KEY-0123456789";
	runHandler(toolResultEvent({ input: { path: "/repo/app.env" }, content: [{ type: "text", text: `BLOG_AGENT_KEY=${fresh}` }] }));
	const { returned } = runHandler(toolResultEvent({ content: [{ type: "text", text: `echo ${fresh}` }] }));
	ok(returned, "the retained harvested value must apply to subsequent results");
	ok(!JSON.stringify(returned).includes(fresh));
});
test("a PROSE line that merely looks like an assignment in a non-env file is NOT harvested whole", () => {
	resetEverything();
	// Regression pin for the over-harvest bug: this exact shape once registered
	// "TORTOISE-KEY-... done" (prose swallowed into the value) and redacted the trailing word.
	const { returned } = runHandler(
		toolResultEvent({ input: { path: "/repo/notes.txt" }, content: [{ type: "text", text: `key=${TORTOISE_KEY} done` }] }),
	);
	ok(returned);
	const out = (returned as { content: Array<{ text: string }> }).content[0].text;
	equal(out, "key=[REDACTED-SECRET:tortoise-config.json#apiKey] done", "the trailing prose must survive");
});
test("an unsourced .env is still harvested when the STATIC registry is empty", () => {
	resetEverything();
	const fresh = "EMPTY-REGISTRY-ENV-KEY-0123456789";
	try {
		_setSecretEchoGuardHooksForTest({ homedir: () => join(HOME, "nowhere"), env: () => ({}) });
		_resetSecretEchoGuardCacheForTest();
		const { returned } = runHandler(
			toolResultEvent({ input: { path: "/repo/app.env" }, content: [{ type: "text", text: `OPENROUTER_API_KEY=${fresh}\n` }] }),
		);
		ok(returned, "the harvest path must not depend on the static registry being non-empty");
		ok(!JSON.stringify(returned).includes(fresh));
	} finally {
		_setSecretEchoGuardHooksForTest(baseHooks);
		resetEverything();
	}
});

// ── Mode + gate ─────────────────────────────────────────────────────────────────────────────
console.log("\nmode and gate");
test("the handler registers and redacts in PRINT mode (both signals)", () => {
	resetEverything();
	// Signal 1: the env marker sub-agents set.
	process.env.PI_MODE = "print";
	try {
		const envEvent = toolResultEvent({ content: [{ type: "text", text: `k=${TORTOISE_KEY}` }] });
		const fromEnv = runHandler(envEvent);
		ok(fromEnv.returned, "PI_MODE=print must still redact");
	} finally {
		delete process.env.PI_MODE;
	}
	// Signal 2: the bare `pi -p` argv form.
	const argv = process.argv;
	process.argv = [argv[0], "pi", "-p", "hello"];
	try {
		const argvEvent = toolResultEvent({ content: [{ type: "text", text: `k=${TORTOISE_KEY}` }] });
		const fromArgv = runHandler(argvEvent);
		ok(fromArgv.returned, "`pi -p` must still redact");
	} finally {
		process.argv = argv;
	}
});
test("gate: SECRET_ECHO_GUARD=0 registers NOTHING; default is ON", () => {
	strictEqual(secretEchoGuardActive({}), true);
	strictEqual(secretEchoGuardActive({ SECRET_ECHO_GUARD: "1" }), true);
	strictEqual(secretEchoGuardActive({ SECRET_ECHO_GUARD: "0" }), false);
	const previous = process.env.SECRET_ECHO_GUARD;
	process.env.SECRET_ECHO_GUARD = "0";
	try {
		const pi = fakePi();
		secretEchoGuard(pi as never);
		strictEqual(pi.handlers.size, 0, "a disabled extension must register no handlers");
	} finally {
		if (previous === undefined) delete process.env.SECRET_ECHO_GUARD;
		else process.env.SECRET_ECHO_GUARD = previous;
	}
});

// ── Adversarial review regressions (#5109, PR #1502) ─────────────────────────────────────────────

/** Cycle-safe "does this structure still hold the raw value?" scan. */
function deepContains(node: unknown, needle: string, seen = new Set<object>()): boolean {
	if (typeof node === "string") return node.includes(needle);
	if (node === null || typeof node !== "object") return false;
	if (seen.has(node)) return false;
	seen.add(node);
	for (const value of Object.values(node as Record<string, unknown>)) if (deepContains(value, needle, seen)) return true;
	return false;
}

console.log("\nP1 — the harvest must read `details` (details-ONLY text, e.g. an `edit` diff)");
test("an unsourced .env secret that lives ONLY in details.diff is harvested and redacted", () => {
	resetEverything();
	const fresh = "UNSOURCED-DOTENV-SECRET-0123456789";
	const { returned } = runHandler(
		toolResultEvent({
			toolName: "edit",
			input: { path: "/repo/sub/.env" },
			content: [{ type: "text", text: "Successfully edited /repo/sub/.env" }],
			details: { diff: `+OPENROUTER_API_KEY=${fresh}`, patch: `+OPENROUTER_API_KEY=${fresh}`, firstChangedLine: 1 },
		}),
	);
	ok(returned, "a details-only unsourced value must produce a patch");
	ok(!JSON.stringify(returned).includes(fresh), "the details-only value must be gone");
	ok(!deepContains(returned, fresh));
});
test("a truncated `read` mirrors its (truncated) text in `details` — redacted from `content`, details NOT load-bearing", () => {
	resetEverything();
	const fresh = "TRUNCATED-READ-ENV-KEY-0123456789";
	const line = `JEV_API_KEY=${fresh}`;
	// VERIFIED installed shape (`dist/core/tools/read.js`): `outputText = truncation.content` (plus a
	// continuation notice) AND `details = { truncation }`, so `details.truncation.content` is the SAME
	// already-TRUNCATED text `content` carries — NOT the full file (an earlier version of this test
	// pinned a shape pi never produces, and the header overstated it; both are corrected). The
	// details HARVEST is load-bearing for `edit`/nested details, which the test below this one covers.
	const { returned } = runHandler(
		toolResultEvent({
			input: { path: "/repo/tortoise/.env" },
			content: [{ type: "text", text: `${line}\n\n[Showing lines 1-1 of 500. Use offset=2 to continue.]` }],
			details: { truncation: { content: line, truncated: true, truncatedBy: "lines", totalLines: 500 } },
		}),
	);
	ok(returned);
	ok(!deepContains(returned, fresh), "the value is redacted (from `content`, which mirrors it)");
});

console.log("\nP2 — aliasing and cycles (the WeakSet guard leaked the second reference)");
test("an ALIASED subtree is redacted in EVERY reference, and both resolve to one replacement", () => {
	resetEverything();
	const shared = [{ type: "text", text: `inner ${TORTOISE_KEY}` }];
	const details = { a: shared, b: shared };
	const { returned } = runHandler(toolResultEvent({ content: [{ type: "text", text: "clean" }], details }));
	ok(returned);
	const out = returned as { details: { a: Array<{ text: string }>; b: Array<{ text: string }> } };
	ok(!out.details.a[0].text.includes(TORTOISE_KEY), "first reference");
	ok(!out.details.b[0].text.includes(TORTOISE_KEY), "second reference must be redacted too");
	strictEqual(out.details.a, out.details.b, "the memoized replacement is shared by both references");
});
test("a CYCLIC details containing a secret redacts the back-edge and preserves the cycle", () => {
	resetEverything();
	// A TWO-node cycle matters: `b` has no string of its own, so without cycle detection pass 1
	// marks it CLEAN and pass 2 would return the ORIGINAL `b` (whose `next` is the original,
	// still-secret `a`) — the back-edge is where the value escapes. A self-cycle does not exercise
	// this, because the node carrying the value is already marked dirty.
	const a: Record<string, unknown> = { name: "a", text: `x ${AUTH_KEY}` };
	const b: Record<string, unknown> = { name: "b", next: a };
	a.self = b;
	const { returned } = runHandler(toolResultEvent({ content: [{ type: "text", text: "clean" }], details: { root: a } }));
	ok(returned, "a cyclic details must not hang and must produce a patch");
	const out = returned as { details: { root: Record<string, unknown> } };
	ok(!deepContains(out.details, AUTH_KEY), "no reachable path may still hold the value");
	strictEqual((out.details.root.self as Record<string, unknown>).next, out.details.root, "the cycle is preserved through rebuilt containers");
});
test("a shallow cycle is terminated by the cycle guard, NOT mis-reported as depth-bounded (M2)", () => {
	// Deleting the `visiting` registration does not leak here (depth-bounding still terminates the
	// recursion), so the observable difference is that a shallow cycle is walked 32 times and falsely
	// trips the DEPTH bound. This pins the guard by its real effect.
	const values = normalizeSecretValues([{ value: AUTH_KEY, label: "l" }]);
	const a: Record<string, unknown> = { text: `x ${AUTH_KEY}` };
	a.self = a;
	const out = redactDetails({ root: a }, values, new Map());
	strictEqual(out.bounded, false, "a cycle must not be mistaken for deep nesting");
	ok(!deepContains(out.value, AUTH_KEY));
});

test("a throwing `details` walk must NOT discard the already-successful `content` redaction", () => {
	resetEverything();
	const hostile = {} as Record<string, unknown>;
	Object.defineProperty(hostile, "boom", {
		enumerable: true,
		get() {
			throw new Error("details walk exploded");
		},
	});
	const { returned } = runHandler(toolResultEvent({ content: [{ type: "text", text: `k=${TORTOISE_KEY}` }], details: hostile }));
	ok(returned, "the content patch was computed and must be emitted even though details failed");
	const patch = returned as { content?: Array<{ text: string }>; details?: unknown };
	strictEqual(patch.details, undefined, "details are left as the tool produced them (fail open)");
	ok(!JSON.stringify(patch.content).includes(TORTOISE_KEY), "the content redaction survived");
	const entry = appendEntryCalls.find((call) => call.type === SECRET_ECHO_GUARD_ENTRY_TYPE);
	ok(entry, "the partial failure is recorded, never silent");
	strictEqual((entry.data as { detailsRedactionFailed: boolean }).detailsRedactionFailed, true);
	for (const line of consoleErrors) ok(!line.includes(TORTOISE_KEY), "the diagnostic must be redacted");
});

test("the error NAME is preserved in the diagnostic (M3)", () => {
	resetEverything();
	const custom = new Error("ordinary message");
	custom.name = "CustomGuardError";
	const hostile = {} as Record<string, unknown>;
	Object.defineProperty(hostile, "boom", {
		enumerable: true,
		get() {
			throw custom;
		},
	});
	runHandler(toolResultEvent({ content: [{ type: "text", text: "clean" }], details: hostile }));
	ok(consoleErrors.some((line) => line.includes("CustomGuardError")), "errName must return the real name");
});
test("a secret carried in error.name is redacted from the diagnostic", () => {
	resetEverything();
	const named = new Error("ordinary message");
	named.name = TORTOISE_KEY;
	const hostile = {} as Record<string, unknown>;
	Object.defineProperty(hostile, "boom", {
		enumerable: true,
		get() {
			throw named;
		},
	});
	runHandler(toolResultEvent({ content: [{ type: "text", text: "clean" }], details: hostile }));
	for (const line of consoleErrors) ok(!line.includes(TORTOISE_KEY), "error.name must be inside the redaction");
});

console.log("\nP2 — labels must not carry a value into the record or the in-band marker (M6)");
test("a value appearing in a label is scrubbed from the label, the marker and the hits", () => {
	const leaky = normalizeSecretValues([
		{ value: TORTOISE_KEY, label: "tortoise-config.json#apiKey" },
		{ value: AUTH_KEY, label: `config.json#${TORTOISE_KEY}.clientSecret` },
	]);
	const auth = leaky.find((entry) => entry.value === AUTH_KEY)!;
	ok(auth.label.includes(LABEL_VALUE_REPLACEMENT), "the label carries the scrub token");
	ok(!auth.label.includes(TORTOISE_KEY), "the label must not carry the value");
	ok(!redactionMarker(auth.label).includes(TORTOISE_KEY), "the in-band marker must not carry it either");
	const hits = new Map<string, number>();
	const out = redactString(`v=${TORTOISE_KEY} w=${AUTH_KEY}`, leaky, hits);
	ok(!out.includes(TORTOISE_KEY) && !out.includes(AUTH_KEY), "no value survives the redaction text");
	for (const label of hits.keys()) ok(!label.includes(TORTOISE_KEY), "no recorded hit label may carry a value");
});

console.log("\nP2 — the details walk is a RUNTIME bound, not just a redaction bound (M4)");
test("the NODE budget is a real bound (a small maxNodes marks the walk bounded)", () => {
	const values = normalizeSecretValues([{ value: TORTOISE_KEY, label: "l" }]);
	const details = { items: Array.from({ length: 50 }, (_, i) => `plain text ${i}`) };
	const out = redactDetails(details, values, new Map(), { maxNodes: 5, maxMs: 60_000 });
	strictEqual(out.bounded, true, "exhausting the node budget must set bounded");
	strictEqual(out.changed, false);
});
test("a pathological details completes quickly and is REPORTED as bounded, never silently full", () => {
	const values = normalizeSecretValues([{ value: TORTOISE_KEY, label: "l" }]);
	// 400k keys is well under the node budget, so ONLY the wall-clock guard can bound this walk —
	// the test measures the real runtime guard, not the size guard. (V8's `Object.keys` enumeration
	// is itself O(n) and uninterruptible; this asserts the guard does not then walk every key.)
	const wide: Record<string, string> = {};
	for (let i = 0; i < 400_000; i++) wide["k" + i] = "ordinary value " + i;
	const started = Date.now();
	const out = redactDetails(wide, values, new Map(), { maxMs: 100 });
	const elapsed = Date.now() - started;
	// ⛔ The wall-clock assertion this used to carry (`elapsed < 1500`) was a load detector: at fleet
	// load average 87 the uninterruptible `Object.keys` enumeration ALONE exceeds it, so the test
	// flaked red on a machine that was merely busy. What is deterministic — and is the actual
	// guarantee — is that the guard TRIPPED and said so. `elapsed` is reported for diagnosis only.
	strictEqual(out.bounded, true, `a bounded walk must be reported, never silently presented as full (elapsed=${elapsed}ms)`);
});

test("the fleet log written to REAL disk bytes carries no value", () => {
	resetEverything();
	const logPath = join(HOME, ".pi", "agent", "state", SECRET_ECHO_GUARD_LOG);
	try {
		_setSecretEchoGuardHooksForTest({
			appendFile: ((path: string, data: string) => writeFileSync(path, data, { flag: "a" })) as never,
			mkdir: ((path: string) => mkdirSync(path, { recursive: true })) as never,
		});
		_resetSecretEchoGuardCacheForTest();
		runHandler(toolResultEvent({ content: [{ type: "text", text: `${JEV_KEY} ${AUTH_KEY}` }], details: { truncation: { content: `${JEV_KEY}` } } }));
		const bytes = readFileSync(logPath, "utf8");
		ok(bytes.includes("jev-config.json#apiKey"), "the record did get written to disk");
		for (const secret of [JEV_KEY, AUTH_KEY, TORTOISE_KEY, PROCESS_ENV_KEY]) {
			ok(!bytes.includes(secret), `the on-disk fleet log leaked ${secret}`);
		}
	} finally {
		_setSecretEchoGuardHooksForTest(baseHooks);
		resetEverything();
	}
});

console.log("\nThe 9 previously-uncaught mutations (round 1 — distinct numbering from round 2 below)");
test("M8: the empty-registry fast path writes NOTHING even for a bounded-depth details", () => {
	resetEverything();
	try {
		_setSecretEchoGuardHooksForTest({ homedir: () => join(HOME, "nowhere"), env: () => ({}) });
		_resetSecretEchoGuardCacheForTest();
		let deep: Record<string, unknown> = { leaf: "ordinary" };
		for (let i = 0; i < MAX_DETAILS_DEPTH + 5; i++) deep = { next: deep };
		const { returned } = runHandler(toolResultEvent({ content: [{ type: "text", text: "ordinary" }], details: deep }));
		strictEqual(returned, undefined);
		strictEqual(appendEntryCalls.length, 0, "an empty registry must short-circuit before the bounded-details record");
	} finally {
		_setSecretEchoGuardHooksForTest(baseHooks);
		resetEverything();
	}
});
test("M9: a source file larger than MAX_SOURCE_FILE_BYTES is SKIPPED without being read", () => {
	const oversize = "OVERSIZE-SOURCE-SECRET-0123456789";
	let readCalls = 0;
	const options = {
		homedir: HOME,
		cwd: join(HOME, "no-cwd-env-file"),
		env: controlledEnv,
		readFile: (() => {
			readCalls++;
			return JSON.stringify({ apiKey: oversize });
		}) as never,
		readdir: (() => []) as never,
		stat: (() => ({ mtimeMs: 1, size: MAX_SOURCE_FILE_BYTES + 1 })) as never,
	};
	const values = loadStaticRegistry(options as never);
	ok(!values.some((entry) => entry.value === oversize), "an over-size source must be skipped");
	strictEqual(readCalls, 0, "the size check must skip the file BEFORE reading it");
});
test("M10: the harvest cap stops after maxHarvested values", () => {
	const into: Array<{ value: string; label: string }> = [];
	const text = Array.from({ length: 5 }, (_, i) => `API_KEY_${i}=HARVEST-CAP-SECRET-${i}-0123456789`).join("\n");
	const added = harvestDotenvSecrets(text, into, "app.env", MIN_SECRET_LENGTH, 2);
	strictEqual(added, 2, "the cap must stop the harvest");
	strictEqual(into.length, 2);
});
test("M11: the dotenv pre-check short-circuits ordinary text (observed, not inferred)", () => {
	_secretEchoGuardCounters.dotenvPrecheckSkips = 0;
	const into: Array<{ value: string; label: string }> = [];
	strictEqual(harvestDotenvSecrets("const a=1\nfunction f(){return 2}\n", into, "x.ts"), 0);
	strictEqual(_secretEchoGuardCounters.dotenvPrecheckSkips, 1, "the cheap pre-check must have fired");
});
test("the harvest reads ADDED and REMOVED dotenv lines out of a unified diff", () => {
	const into: Array<{ value: string; label: string }> = [];
	const added = harvestDotenvSecrets(`@@ -1 +1 @@\n-OLD_KEY=OLD-DIFF-SECRET-0123456789\n+NEW_KEY=NEW-DIFF-SECRET-0123456789\n`, into, "app.env");
	strictEqual(added, 2);
	ok(into.some((entry) => entry.value === "OLD-DIFF-SECRET-0123456789"));
	ok(into.some((entry) => entry.value === "NEW-DIFF-SECRET-0123456789"));
});

// ── Round-2 adversarial review (#5109, PR #1502) ─────────────────────────────────────────────
// NOTE ON NUMBERING: the M-numbers below are from the ROUND-2 reviewer's mutation set and are
// DISTINCT from the round-1 set pinned above ("The 9 previously-uncaught mutations" uses M8–M11 for
// different mutants). Each test below is proven to FAIL without its fix — see the mutation ledger in
// the PR/report: P1a, P1b, P2a, P2b×2, P2c, M07, M22×2, M09, M09b, M10, M15, P3b all caught.
//
// ROUND-3 MUTATION LEDGER (corrects the earlier "semantics-preserving" claim, which was not
// reproducible — the round-3 reviewer found only THREE of the nine genuinely equivalent):
//   • GENUINELY SEMANTICS-PRESERVING, no test can (or should) catch them:
//       - `harvestFailed-OR-remove` — removing `detailsHarvestFailed` from `detailsWalkBounded` is a
//         no-op because the details-harvest catch sets `harvestBudget.bounded = true` in the same
//         block, so the OR operand is already true.
//       - `record-hits-raw-labels` — the hits key IS already a string (the label passed to
//         `addHit`); `String(label)` is the identity.
//       - `merge-hits-always` — merging a walk's hit map when that walk did not `change` is a no-op
//         because `redactString` only adds a hit when it actually replaces something.
//   • REAL BEHAVIOUR CHANGES, now pinned (each test fails without its fix):
//       - `harvested-not-normalized` → the harvested-label normalization tests below (the primary
//         round-3 fix: without it a registered secret in an env-like BASENAME leaks into the marker
//         and the record/fleet-log `hits` label).
//       - `failgate-{content,details}Harvest-drop` + `anyFailure-contentHarvest-drop` → the
//         "harvest failure with an EMPTY registry still writes a record" tests below.
//       - `harvest-string-content-drop` → the bare-STRING content harvest test below.
//       - `minlength-off-by-one` → the `SECRET_ECHO_GUARD_MIN_LENGTH` override test below.

console.log("\nP1 — the harvest/details walk must not discard a content redaction");
test("a throwing `details` getter on an ENV-LIKE read: content is redacted AND the failure is durably recorded", () => {
	// The reviewer's exact repro: the harvest walk used to run unguarded, so this threw out of the
	// harvest into the OUTER catch → `returned=undefined` → the registered secret in `content` was
	// persisted verbatim, with no durable record. (The older test above uses a NON-env-like input,
	// which skips the harvest entirely — this is the case that actually exercises the walk.)
	resetEverything();
	const hostile = {} as Record<string, unknown>;
	Object.defineProperty(hostile, "boom", {
		enumerable: true,
		get() {
			throw new Error("kaboom");
		},
	});
	const { returned } = runHandler(
		toolResultEvent({
			input: { path: "/repo/app.env" },
			content: [{ type: "text", text: `OPENROUTER_API_KEY=${TORTOISE_KEY}\n` }],
			details: hostile,
		}),
	);
	ok(returned, "the content redaction must be emitted even though the harvest threw");
	const patch = returned as { content?: Array<{ text: string }>; details?: unknown };
	strictEqual(patch.details, undefined, "details are left as the tool produced them (fail open)");
	ok(!JSON.stringify(patch.content).includes(TORTOISE_KEY), "the secret in `content` must be gone");
	const entry = appendEntryCalls.find((call) => call.type === SECRET_ECHO_GUARD_ENTRY_TYPE);
	ok(entry, "a durable record must be written even though the harvest threw");
	const data = entry.data as { harvestFailed: boolean; detailsRedactionFailed: boolean; detailsWalkBounded: boolean };
	strictEqual(data.harvestFailed, true, "the failed harvest is recorded");
	strictEqual(data.detailsRedactionFailed, true, "the failed redaction is recorded");
	strictEqual(data.detailsWalkBounded, true, "a failed walk is never presented as complete");
	strictEqual(appendFileLines.length, 1, "the fleet log gets the record too");
	for (const secret of [TORTOISE_KEY, JEV_KEY, AUTH_KEY, PROCESS_ENV_KEY]) {
		ok(!appendFileLines[0].includes(secret), `the fleet log leaked ${secret}`);
		for (const line of consoleErrors) ok(!line.includes(secret), `stderr leaked ${secret}`);
	}
});
test("a HOSTILE content part must not stop a SIBLING part from being redacted", () => {
	// Reviewer repro: `content: [hostileProxyPart, { type: "text", text: "k="+SECRET }]` returned
	// `undefined`, so the registered secret in the sibling part was persisted. Each part is inspected
	// under its own guard now, and the un-inspectable part is recorded rather than aborting the walk.
	resetEverything();
	const hostilePart = new Proxy(
		{},
		{
			get(_target, property) {
				if (property === "type") throw new Error("boom-type");
				return undefined;
			},
		},
	);
	const { returned } = runHandler(toolResultEvent({ content: [hostilePart, { type: "text", text: `k=${TORTOISE_KEY}` }] }));
	ok(returned, "the sibling part must still be redacted");
	const content = (returned as { content: Array<{ text?: string }> }).content;
	ok(!JSON.stringify(content).includes(TORTOISE_KEY), "the registered secret must be gone");
	const entry = appendEntryCalls.find((call) => call.type === SECRET_ECHO_GUARD_ENTRY_TYPE);
	ok(entry, "the partial walk must be recorded, not silent");
	strictEqual((entry.data as { contentRedactionFailed: boolean }).contentRedactionFailed, true);
	ok(consoleErrors.some((line) => line.includes("detail harvest") || line.includes("UNREDACTED")), "the partial walk is announced on stderr");
});

console.log("\nP2 — the record/fleet-log identity fields are redacted like everything else");
test("a secret in toolCallId / toolName / sessionId / sessionFile reaches NO sink", () => {
	resetEverything();
	runHandler(
		toolResultEvent({ toolName: TORTOISE_KEY, toolCallId: AUTH_KEY, content: [{ type: "text", text: `k=${JEV_KEY}` }] }),
		fakeCtx(PROCESS_ENV_KEY),
	);
	const sinks = [
		...appendEntryCalls.map((call) => JSON.stringify(call)),
		...appendFileLines,
		...notifications.map((note) => note.msg),
		...consoleErrors,
	];
	for (const secret of [TORTOISE_KEY, AUTH_KEY, JEV_KEY, PROCESS_ENV_KEY]) {
		for (const sink of sinks) ok(!sink.includes(secret), `a sink leaked ${secret}`);
	}
	const entry = appendEntryCalls.find((call) => call.type === SECRET_ECHO_GUARD_ENTRY_TYPE);
	ok(entry, "the record is written");
	const data = entry.data as { toolName: string; toolCallId: string; sessionId: string; sessionFile: string };
	for (const field of [data.toolName, data.toolCallId, data.sessionId, data.sessionFile]) {
		ok(field.includes(REDACTION_MARKER_BASE), `identity field must carry the redaction marker: ${field}`);
	}
});

console.log("\nP2 — a secret in a JSON KEY is transcript text too");
test("a secret used as an ANCESTOR KEY of details is redacted, not copied into the patch", () => {
	resetEverything();
	// Case 1 — the pass-1 KEY check. The ONLY dirt is the key: every VALUE is clean, so without the
	// key check the container is never marked dirty, pass 2 skips it, and the key survives with NO
	// patch at all. (The reviewer's repro has a dirty nested value, which makes the container dirty
	// for an unrelated reason and would mask the key check — this case isolates it.)
	const keyOnly = runHandler(
		toolResultEvent({ content: [{ type: "text", text: "clean" }], details: { [TORTOISE_KEY]: "clean value" } }),
	);
	ok(keyOnly.returned, "a key-ONLY hit must still produce a patch");
	ok(!JSON.stringify(keyOnly.returned).includes(TORTOISE_KEY), "the key must be redacted, not copied");
	ok(!deepContains(keyOnly.returned, TORTOISE_KEY));

	// Case 2 — the reviewer's exact repro: a secret key AND a secret nested value.
	resetEverything();
	const { returned } = runHandler(
		toolResultEvent({
			content: [{ type: "text", text: "clean" }],
			details: { [TORTOISE_KEY]: { clientSecret: AUTH_KEY } },
		}),
	);
	ok(returned, "a key hit must still produce a patch");
	ok(!JSON.stringify(returned).includes(TORTOISE_KEY), "the secret must not survive as a key");
	ok(!JSON.stringify(returned).includes(AUTH_KEY), "the nested value must be redacted too");
	ok(!deepContains(returned, TORTOISE_KEY));
	const entry = appendEntryCalls.find((call) => call.type === SECRET_ECHO_GUARD_ENTRY_TYPE);
	ok(entry, "the key hit is recorded");
	for (const sink of [...appendFileLines, ...notifications.map((note) => note.msg), ...consoleErrors]) {
		ok(!sink.includes(TORTOISE_KEY) && !sink.includes(AUTH_KEY), "no sink may carry the key/value");
	}
});

console.log("\nP2 — a bounded walk is announced per-result, not only on the first notice");
test("EVERY bounded walk of a session is announced (a bounded walk is a per-result fact)", () => {
	resetEverything();
	const ctx = fakeCtx();
	// First result consumes the once-per-session redaction summary.
	runHandler(toolResultEvent({ content: [{ type: "text", text: `k=${TORTOISE_KEY}` }] }), ctx);
	strictEqual(notifications.length, 1);
	let deep: Record<string, unknown> = { leaf: "ordinary" };
	for (let i = 0; i < MAX_DETAILS_DEPTH + 5; i++) deep = { next: deep };
	// A bounded walk with nothing redacted must NOT ride on (and be suppressed by) the summary.
	runHandler(toolResultEvent({ toolCallId: "call-2", content: [{ type: "text", text: "clean" }], details: deep }), ctx);
	ok(notifications.length > 1, "the bounded walk must be announced even after the summary fired");
	ok(notifications.some((note) => note.msg.includes("WARNING")), "the bounded warning must appear");
	const afterSecond = notifications.length;
	// The corrected invariant: the SECOND bounded walk after the first is ALSO announced. The previous
	// `warnedBounded` latch silently dropped it, so the pane could present a bounded (incomplete) walk
	// as if it were nothing special from the second onward — the header's "never silent" was false.
	runHandler(toolResultEvent({ toolCallId: "call-3", content: [{ type: "text", text: "clean" }], details: deep }), ctx);
	ok(notifications.length > afterSecond, "a SECOND bounded walk must still be announced, not silently dropped");
	ok(notifications[notifications.length - 1].msg.includes("WARNING"));
	// And the durable record is written on EVERY bounded result, not only the announced one.
	strictEqual(appendEntryCalls.length, 3, "every bounded result is recorded");
	const boundedRecords = appendEntryCalls.filter(
		(call) => (call.data as { detailsWalkBounded: boolean }).detailsWalkBounded === true,
	);
	strictEqual(boundedRecords.length, 2, "both bounded results are recorded as bounded");
});

test("P3a: a credential-bearing URL is NOT registered (documented gap, pinned as deliberate)", () => {
	// `NON_SECRET_TAIL_TOKENS` treats a trailing `url`/`uri` as a POINTER, so these never register.
	// The header's NOT COVERED list documents it; this pins the behaviour so a future change is a
	// deliberate decision, not an accident.
	for (const name of ["DATABASE_URL", "REDIS_URL", "SENTRY_DSN", "SUPABASE_DB_URL"]) {
		strictEqual(isSecretValueKey(name, "env"), false, `${name} is deliberately not registered`);
	}
});

test("P3b: a dirty non-plain object is rebuilt with its PROTOTYPE preserved", () => {
	class Holder {
		text: string;
		constructor(text: string) {
			this.text = text;
		}
		method(): string {
			return "kept";
		}
	}
	const values = normalizeSecretValues([{ value: TORTOISE_KEY, label: "l" }]);
	const out = redactDetails({ root: new Holder(`x ${TORTOISE_KEY}`) }, values, new Map());
	const rebuilt = (out.value as { root: Holder }).root;
	ok(rebuilt instanceof Holder, "the prototype must survive the rebuild");
	strictEqual(rebuilt.method(), "kept");
	ok(!deepContains(rebuilt, TORTOISE_KEY));
});

console.log("\nM07 / M22 — the bound flags on the BOUNDED paths");
test("M07: a BOUNDED source-5 harvest is recorded incomplete even though the redaction walk completed", () => {
	resetEverything();
	try {
		// Force ONLY the harvest budget to bound (maxNodes: 0); the redaction walk keeps its default
		// budget and completes. Without the harvest-bound OR, the record would claim a COMPLETE walk
		// while part of `details` was never inspected for source-5 values.
		_setSecretEchoGuardHooksForTest({ detailsHarvestLimits: () => ({ maxNodes: 0, maxMs: 60_000 }) });
		_resetSecretEchoGuardCacheForTest();
		const { returned } = runHandler(
			toolResultEvent({
				input: { path: "/repo/app.env" },
				content: [{ type: "text", text: `k=${TORTOISE_KEY}` }],
				details: { truncation: { content: "clean details", truncated: false } },
			}),
		);
		ok(returned, "the content redaction is unaffected by the bounded harvest");
		const entry = appendEntryCalls.find((call) => call.type === SECRET_ECHO_GUARD_ENTRY_TYPE);
		ok(entry, "the record is written");
		const data = entry.data as { detailsWalkBounded: boolean; detailsRedacted: boolean };
		strictEqual(data.detailsRedacted, false, "the redaction walk had nothing to change — it completed");
		strictEqual(data.detailsWalkBounded, true, "a bounded HARVEST is an incomplete walk");
		ok(notifications.some((note) => note.msg.includes("WARNING")), "and it is announced");
	} finally {
		_setSecretEchoGuardHooksForTest(baseHooks);
		resetEverything();
	}
});
test("M22: a DIRTY walk that also hit the bound reports bounded (the dirty path must not reset it)", () => {
	const values = normalizeSecretValues([{ value: TORTOISE_KEY, label: "l" }]);
	const details = { secret: TORTOISE_KEY, items: Array.from({ length: 50 }, (_, i) => `plain ${i}`) };
	const out = redactDetails(details, values, new Map(), { maxNodes: 5, maxMs: 60_000 });
	strictEqual(out.changed, true, "the walk must be dirty (a secret was found)");
	strictEqual(out.bounded, true, "the dirty path must CARRY the bound, not reset it to false");
	ok(!deepContains(out.value, TORTOISE_KEY));
});
test("M22 (handler): a dirty+bounded details is recorded AND announced as bounded", () => {
	resetEverything();
	// A SHALLOW secret (so the walk is dirty) plus a deep sibling chain (so the walk also hits the
	// depth bound). Both facts must reach the record.
	const deep: Record<string, unknown> = { secret: TORTOISE_KEY };
	let cursor: Record<string, unknown> = deep;
	for (let i = 0; i < MAX_DETAILS_DEPTH + 5; i++) {
		const next: Record<string, unknown> = {};
		cursor.next = next;
		cursor = next;
	}
	const { returned } = runHandler(toolResultEvent({ content: [{ type: "text", text: "clean" }], details: deep }));
	ok(returned, "the shallow secret is redacted");
	const entry = appendEntryCalls.find((call) => call.type === SECRET_ECHO_GUARD_ENTRY_TYPE);
	ok(entry, "the bounded dirty walk is recorded");
	const data = entry.data as { detailsRedacted: boolean; detailsWalkBounded: boolean };
	strictEqual(data.detailsRedacted, true);
	strictEqual(data.detailsWalkBounded, true);
	ok(notifications.some((note) => note.msg.includes("WARNING")));
});

console.log("\nM09 / M10 / M15 — the lower-priority round-2 mutation gaps");
test("M09: a FAILED details walk with nothing to redact STILL writes a durable record, marked bounded", () => {
	resetEverything();
	const hostile = {} as Record<string, unknown>;
	Object.defineProperty(hostile, "boom", {
		enumerable: true,
		get() {
			throw new Error("boom");
		},
	});
	const { returned } = runHandler(toolResultEvent({ content: [{ type: "text", text: "clean" }], details: hostile }));
	strictEqual(returned, undefined, "nothing was redacted, so no patch");
	const entry = appendEntryCalls.find((call) => call.type === SECRET_ECHO_GUARD_ENTRY_TYPE);
	ok(entry, "a failure with nothing to redact must STILL write the record (it was skipped before)");
	const data = entry.data as { detailsRedactionFailed: boolean; detailsWalkBounded: boolean; total: number };
	strictEqual(data.detailsRedactionFailed, true);
	strictEqual(data.detailsWalkBounded, true, "a failed walk is not a complete walk");
	strictEqual(data.total, 0);
	strictEqual(appendFileLines.length, 1);
});
test("M09b: a CONTENT failure with nothing redacted still writes a durable record", () => {
	// This isolates the `&& !anyFailure` in the record gate: a details failure is ALREADY marked
	// bounded (so it would record anyway), but a content-only failure leaves every other flag false —
	// without the failure gate the handler returns before writing, and the failure is undetectable.
	resetEverything();
	const hostilePart = new Proxy(
		{},
		{
			get(_target, property) {
				if (property === "type") throw new Error("boom-type");
				return undefined;
			},
		},
	);
	const { returned } = runHandler(toolResultEvent({ content: [hostilePart, { type: "text", text: "clean" }] }));
	strictEqual(returned, undefined, "nothing was redacted, so no patch");
	const entry = appendEntryCalls.find((call) => call.type === SECRET_ECHO_GUARD_ENTRY_TYPE);
	ok(entry, "a content failure with nothing redacted must STILL write the durable record");
	const data = entry.data as { contentRedactionFailed: boolean; detailsWalkBounded: boolean; total: number };
	strictEqual(data.contentRedactionFailed, true);
	strictEqual(data.detailsWalkBounded, false, "this failure is on the CONTENT walk, not the details walk");
	strictEqual(data.total, 0);
	strictEqual(appendFileLines.length, 1);
});
test("M10: a throwing `name` getter on a thrown error does not break the failure path", () => {
	resetEverything();
	const hostileError = Object.create(Error.prototype) as Error;
	Object.defineProperty(hostileError, "name", {
		get() {
			throw new Error("name-boom");
		},
	});
	const hostile = {} as Record<string, unknown>;
	Object.defineProperty(hostile, "boom", {
		enumerable: true,
		get() {
			throw hostileError;
		},
	});
	const { returned } = runHandler(toolResultEvent({ content: [{ type: "text", text: `k=${TORTOISE_KEY}` }], details: hostile }));
	ok(returned, "the content redaction must survive a hostile error `name`");
	ok(!JSON.stringify(returned).includes(TORTOISE_KEY));
	ok(consoleErrors.some((line) => line.includes("UNREDACTED")), "the failure is still reported");
	for (const line of consoleErrors) ok(!line.includes(TORTOISE_KEY));
});
test("M15: the detail-harvest walk enforces MAX_DETAILS_DEPTH and stops collecting", () => {
	let deep: Record<string, unknown> = { leaf: "DEEP-LEAF-SECRET-0123456789" };
	for (let i = 0; i < MAX_DETAILS_DEPTH + 5; i++) deep = { next: deep };
	const out: string[] = [];
	const budget = { nodes: 1_000_000, deadline: Date.now() + 60_000, bounded: false };
	collectDetailsStrings(deep, out, budget, new WeakSet<object>(), 0);
	strictEqual(budget.bounded, true, "the depth bound must mark the walk bounded");
	ok(!out.includes("DEEP-LEAF-SECRET-0123456789"), "a string past the depth bound must NOT be collected");
});

// ── Round-3 adversarial review (#5109, PR #1502) ─────────────────────────────────────────────

console.log("\nRound-3 — harvested labels must be normalized against the REGISTERED set");
test("a registered secret in the env-like BASENAME is scrubbed from the marker, record, fleet log and notice", () => {
	// The leak this closes: the harvested value's label is `read:<basename>#<key>`, and `<basename>` is
	// attacker-influencable (an agent picks the path). Without normalizeSecretValues over the harvested
	// set, a registered secret in the basename is embedded in the in-band marker persisted in the
	// transcript AND in the record/fleet-log `hits` label. JEV_KEY is registered via jev-config.json.
	resetEverything();
	const fresh = "HARVESTED-LABEL-SECRET-0123456789";
	const { returned } = runHandler(
		toolResultEvent({
			input: { path: `/repo/${JEV_KEY}.env.local` },
			content: [{ type: "text", text: `OPENROUTER_API_KEY=${fresh}\n` }],
		}),
	);
	ok(returned, "the harvested value must be redacted");
	const out = (returned as { content: Array<{ text: string }> }).content[0].text;
	ok(!out.includes(fresh), "the harvested value must be gone from this result");
	ok(!out.includes(JEV_KEY), "the registered basename secret must NOT survive in the marker");
	ok(out.includes(LABEL_VALUE_REPLACEMENT), "the basename secret is replaced by the scrub token");
	const sinks = [
		...appendEntryCalls.map((call) => JSON.stringify(call)),
		...appendFileLines,
		...notifications.map((note) => note.msg),
		...consoleErrors,
	];
	for (const sink of sinks) {
		ok(!sink.includes(JEV_KEY), "a sink carried the registered basename secret");
		ok(!sink.includes(fresh), "a sink carried the harvested value");
	}
	const entry = appendEntryCalls.find((call) => call.type === SECRET_ECHO_GUARD_ENTRY_TYPE);
	ok(entry, "the record is written");
	const data = entry.data as { hits: Array<{ label: string }> };
	ok(data.hits[0].label.includes(LABEL_VALUE_REPLACEMENT), "the record label is scrubbed");
	ok(!data.hits[0].label.includes(JEV_KEY), "the record label must not carry the basename secret");
});
test("a registered secret in a bash command TOKEN is scrubbed from the harvested label too", () => {
	resetEverything();
	const fresh = "BASH-TOKEN-HARVEST-SECRET-0123456789";
	const { returned } = runHandler(
		toolResultEvent({
			toolName: "bash",
			input: { command: `cat /repo/${AUTH_KEY}.env` },
			content: [{ type: "text", text: `OPENROUTER_API_KEY=${fresh}\n` }],
		}),
	);
	ok(returned, "the harvested value must be redacted");
	const all = JSON.stringify([returned, ...appendEntryCalls, ...appendFileLines, ...notifications, ...consoleErrors]);
	ok(!all.includes(fresh), "the harvested value must reach no sink");
	ok(!all.includes(AUTH_KEY), "the bash-token secret must reach no sink");
	ok(all.includes(LABEL_VALUE_REPLACEMENT), "the bash-token secret is replaced by the scrub token");
});

test("a harvested value retained in the CACHE keeps a scrubbed label on later results", () => {
	// `retainHarvested` stores the RAW label; `getRegistryValues` must normalize on the way out, so a
	// later, unrelated result is redacted under the scrubbed label rather than the raw basename.
	resetEverything();
	const fresh = "RETAINED-LABEL-SECRET-0123456789";
	runHandler(
		toolResultEvent({
			input: { path: `/repo/${TORTOISE_KEY}.env.local` },
			content: [{ type: "text", text: `OPENROUTER_API_KEY=${fresh}\n` }],
		}),
	);
	const { returned } = runHandler(toolResultEvent({ content: [{ type: "text", text: `echo ${fresh}` }] }));
	ok(returned, "the retained harvested value is redacted on a later result");
	const out = JSON.stringify(returned);
	ok(!out.includes(TORTOISE_KEY), "the later marker must not carry the basename secret");
	ok(out.includes(LABEL_VALUE_REPLACEMENT), "the later label is scrubbed");
	ok(!out.includes(fresh), "the harvested value itself is redacted");
});

console.log("\nRound-3 — an unreadable event field must not discard a completed redaction");
test("an UNREADABLE `toolCallId` still returns the computed patch and writes a durable record", () => {
	resetEverything();
	const event = toolResultEvent({ content: [{ type: "text", text: `k=${TORTOISE_KEY}` }] });
	Object.defineProperty(event, "toolCallId", {
		configurable: true,
		get() {
			throw new Error("tcId-boom");
		},
	});
	const { returned } = runHandler(event);
	ok(returned, "the redaction must NOT be discarded by an unreadable identity field");
	ok(!JSON.stringify(returned).includes(TORTOISE_KEY));
	const entry = appendEntryCalls.find((call) => call.type === SECRET_ECHO_GUARD_ENTRY_TYPE);
	ok(entry, "a durable record must still be written");
	const data = entry.data as { eventReadFailed: boolean; toolCallId: unknown };
	strictEqual(data.eventReadFailed, true, "the unreadable field is recorded");
	strictEqual(data.toolCallId, null, "the unreadable identity field is left null, never invented");
	strictEqual(appendFileLines.length, 1, "the fleet log gets the record too");
	for (const sink of [JSON.stringify(appendEntryCalls), ...appendFileLines, ...notifications.map((n) => n.msg), ...consoleErrors]) {
		ok(!sink.includes(TORTOISE_KEY), "no sink may carry the value");
	}
});
test("an UNREADABLE `toolName` does not abort the redaction or the record", () => {
	resetEverything();
	const event = toolResultEvent({ content: [{ type: "text", text: `k=${TORTOISE_KEY}` }] });
	Object.defineProperty(event, "toolName", {
		configurable: true,
		get() {
			throw new Error("tn-boom");
		},
	});
	const { returned } = runHandler(event);
	ok(returned, "the redaction must survive an unreadable tool name");
	ok(!JSON.stringify(returned).includes(TORTOISE_KEY));
	const entry = appendEntryCalls.find((call) => call.type === SECRET_ECHO_GUARD_ENTRY_TYPE);
	ok(entry, "the record is written");
	const data = entry.data as { eventReadFailed: boolean; toolName: unknown };
	strictEqual(data.eventReadFailed, true);
	strictEqual(data.toolName, "tool", "an unreadable tool name falls back to a fixed placeholder");
});
test("an UNREADABLE `input` does not abort the redaction or the record", () => {
	resetEverything();
	const event = toolResultEvent({ content: [{ type: "text", text: `k=${TORTOISE_KEY}` }] });
	Object.defineProperty(event, "input", {
		configurable: true,
		get() {
			throw new Error("in-boom");
		},
	});
	const { returned } = runHandler(event);
	ok(returned, "the redaction must survive an unreadable input");
	ok(!JSON.stringify(returned).includes(TORTOISE_KEY));
	const entry = appendEntryCalls.find((call) => call.type === SECRET_ECHO_GUARD_ENTRY_TYPE);
	ok(entry, "the record is written");
	strictEqual((entry.data as { eventReadFailed: boolean }).eventReadFailed, true);
	ok(consoleErrors.some((line) => line.includes("reading input failed")), "the unreadable input is announced");
});
test("an event-read failure with an EMPTY registry still writes a durable record", () => {
	resetEverything();
	try {
		_setSecretEchoGuardHooksForTest({ homedir: () => join(HOME, "nowhere"), env: () => ({}) });
		_resetSecretEchoGuardCacheForTest();
		const event = toolResultEvent({ content: [{ type: "text", text: "clean" }] });
		Object.defineProperty(event, "toolCallId", {
			configurable: true,
			get() {
				throw new Error("tcId-boom");
			},
		});
		const { returned } = runHandler(event);
		strictEqual(returned, undefined, "nothing was redacted, so no patch");
		ok(
			appendEntryCalls.some((call) => call.type === SECRET_ECHO_GUARD_ENTRY_TYPE),
			"an event-read failure must still be recorded even when the registry is empty",
		);
	} finally {
		_setSecretEchoGuardHooksForTest(baseHooks);
		resetEverything();
	}
});

console.log("\nRound-3 — the harvest-failure gates and the bare-STRING content harvest");
test("a CONTENT-harvest failure with an EMPTY registry still writes a durable record", () => {
	// A single throw in the CONTENT HARVEST walk with nothing changed. The harvest iterates with
	// `Symbol.iterator`, so a content array whose ITERATOR throws fails ONLY the harvest while `.map`
	// (the redaction walk) still succeeds and finds nothing to change. The part is a plain data object
	// (no own accessor), so the redaction walk does NOT rebuild it and `changed` stays false. This
	// isolates `contentHarvestFailed` in BOTH the early return and `anyFailure`.
	resetEverything();
	try {
		_setSecretEchoGuardHooksForTest({ homedir: () => join(HOME, "nowhere"), env: () => ({}) });
		_resetSecretEchoGuardCacheForTest();
		const content = new Proxy([{ type: "text", text: "ordinary output" }], {
			get(target, property, receiver) {
				if (property === Symbol.iterator) throw new Error("iterator-boom");
				return Reflect.get(target, property, receiver);
			},
		});
		const { returned } = runHandler(toolResultEvent({ input: { path: "/repo/app.env" }, content }));
		strictEqual(returned, undefined, "nothing was redacted, so no patch");
		const entry = appendEntryCalls.find((call) => call.type === SECRET_ECHO_GUARD_ENTRY_TYPE);
		ok(entry, "a content-harvest-only failure must STILL write the durable record");
		const data = entry.data as { harvestFailed: boolean; contentRedactionFailed: boolean; total: number };
		strictEqual(data.harvestFailed, true);
		strictEqual(data.contentRedactionFailed, false, "the redaction walk itself did not fail");
		strictEqual(data.total, 0);
		strictEqual(appendFileLines.length, 1);
		ok(consoleErrors.some((line) => line.includes("content harvest failed")));
	} finally {
		_setSecretEchoGuardHooksForTest(baseHooks);
		resetEverything();
	}
});
test("a DETAILS-harvest failure with an EMPTY registry still writes a durable record", () => {
	// Same shape at the details level: an object whose `ownKeys` trap throws on the FIRST enumeration
	// (the harvest) and succeeds on the second (the redaction walk). The redaction walk therefore
	// completes with nothing to change, so `detailsHarvestFailed`/`harvestBudget.bounded` are the ONLY
	// reason a record is written — the property this test protects.
	resetEverything();
	try {
		_setSecretEchoGuardHooksForTest({ homedir: () => join(HOME, "nowhere"), env: () => ({}) });
		_resetSecretEchoGuardCacheForTest();
		let keyReads = 0;
		const details = new Proxy(
			{ clean: "ordinary" } as Record<string, unknown>,
			{
				ownKeys(target) {
					keyReads++;
					if (keyReads === 1) throw new Error("ownKeys-boom");
					return Reflect.ownKeys(target);
				},
			},
		);
		const { returned } = runHandler(
			toolResultEvent({ input: { path: "/repo/app.env" }, content: [{ type: "text", text: "clean" }], details }),
		);
		strictEqual(returned, undefined);
		const entry = appendEntryCalls.find((call) => call.type === SECRET_ECHO_GUARD_ENTRY_TYPE);
		ok(entry, "a details-harvest failure must still write the record");
		const data = entry.data as { harvestFailed: boolean; detailsWalkBounded: boolean };
		strictEqual(data.harvestFailed, true);
		strictEqual(data.detailsWalkBounded, true);
	} finally {
		_setSecretEchoGuardHooksForTest(baseHooks);
		resetEverything();
	}
});
test("a bare-STRING content (defensive shape) IS harvested when the input is env-like", () => {
	resetEverything();
	const fresh = "STRING-CONTENT-HARVEST-SECRET-0123456789";
	const { returned } = runHandler(
		toolResultEvent({ input: { path: "/repo/app.env" }, content: `OPENROUTER_API_KEY=${fresh}\n` }),
	);
	ok(returned, "the string-content harvest must register and redact the value");
	ok(!JSON.stringify(returned).includes(fresh));
});

console.log("\nRound-3 — the length-floor override and the crafted-shape residuals");
test("SECRET_ECHO_GUARD_MIN_LENGTH is honored end-to-end (the override is not silently ignored)", () => {
	resetEverything();
	try {
		_setSecretEchoGuardHooksForTest({
			env: () => ({ ...controlledEnv, SECRET_ECHO_GUARD_MIN_LENGTH: "100" }),
		});
		_resetSecretEchoGuardCacheForTest();
		// PROCESS_ENV_KEY is 30 chars, over the default 12 but under the 100 override.
		const { returned } = runHandler(toolResultEvent({ content: [{ type: "text", text: `key=${PROCESS_ENV_KEY}` }] }));
		strictEqual(returned, undefined, "the 100-char floor must exclude a 30-char value");
	} finally {
		_setSecretEchoGuardHooksForTest(baseHooks);
		resetEverything();
	}
});
test("R3: an own `__proto__` key survives the details rebuild (not dropped by the inherited setter)", () => {
	const values = normalizeSecretValues([{ value: TORTOISE_KEY, label: "l" }]);
	// JSON.parse materializes an OWN `__proto__` key; the rebuild must keep it (and redact its value),
	// rather than hitting the inherited `__proto__` setter and dropping the key entirely.
	const source = JSON.parse(`{"__proto__":"x ${TORTOISE_KEY}","nested":1}`) as Record<string, unknown>;
	deepEqual(Object.keys(source).sort(), ["__proto__", "nested"], "precondition: own __proto__ key exists");
	const out = redactDetails(source, values, new Map());
	strictEqual(out.changed, true);
	const rebuilt = out.value as Record<string, unknown>;
	ok(Object.prototype.hasOwnProperty.call(rebuilt, "__proto__"), "the own __proto__ key must survive");
	strictEqual(rebuilt["__proto__"], `x ${redactionMarker("l")}`, "and its value must be redacted");
	strictEqual(Object.getPrototypeOf(rebuilt), Object.prototype, "the prototype must not be replaced by the value");
	ok(!deepContains(rebuilt, TORTOISE_KEY));
});
test("R3 (documented residual): a BOXED String content part is NOT redacted (exact-match only)", () => {
	const values = normalizeSecretValues([{ value: TORTOISE_KEY, label: "l" }]);
	const out = redactContent([{ type: "text", text: new String(`k=${TORTOISE_KEY}`) }], values, new Map());
	strictEqual(out.changed, false, "a boxed String slips the primitive-string exact-match check");
});
test("R3 (documented residual): a whitespace-inserted or split secret is NOT redacted", () => {
	const values = normalizeSecretValues([{ value: TORTOISE_KEY, label: "l" }]);
	const hits = new Map<string, number>();
	const spaced = TORTOISE_KEY.split("").join(" ");
	strictEqual(redactString(spaced, values, hits), spaced, "inserted whitespace is not exact-matched");
	const parts = redactContent(
		[{ type: "text", text: `k=${TORTOISE_KEY.slice(0, 10)}` }, { type: "text", text: TORTOISE_KEY.slice(10) }],
		values,
		hits,
	);
	strictEqual(parts.changed, false, "a secret split across two parts is not joined");
});

// ── Round-4 adversarial review (#5109, PR #1502) ────────────────────────────────────────────
//
// ROUND-4 MUTATION LEDGER (each new test below is proven to FAIL without its fix):
//   • ACCESSOR PROPERTIES (own enumerable getters) — the two-pass `details` rebuild memoized a
//     CLEAN verdict and returned the node BY REFERENCE, so a getter that read clean in-walk and a
//     secret at serialization passed through with no patch, no flag and no record. The identical hole
//     existed for a `content` part's `text` (and for the content ARRAY). Fix: any own enumerable
//     accessor marks its container dirty (details) / is rebuilt from a single read (content).
//     Tests R4-A1..A4, plus `redactContent`/`redactDetails` unit pins.
//   • THE EARLY-RETURN GATE dropped `contentRedactionFailed`, `detailsRedactionFailed` and
//     `harvestBudget.bounded`: with an EMPTY registry each was announced on stderr (or not at all)
//     but left NO durable record. Tests R4-B1..B3. NOTE (mutation-verified): dropping
//     `detailsHarvestFailed` from the gate is SEMANTICS-PRESERVING because the details-harvest catch
//     sets `harvestBudget.bounded = true` in the same block, so that OR operand is already true —
//     that mutant survives BY DESIGN and is recorded here rather than papered over.
//   • THE THREE ROUND-3 MUTATION SURVIVORS:
//       - `else if (detailsWalkBounded || anyFailure)` → `else if (detailsWalkBounded)` (R4-C1);
//       - swallowing the content-redaction `catch` (dropping `contentRedactionFailed = true`) (R4-C2);
//       - dropping `detailsRedactionFailed` from `anyFailure` (degrades the notice wording) (R4-C3).
//   • `toJSON`/private-field residual pinned so it cannot drift silently (R4-RESIDUAL).
//   • The per-result bounded/failure announcement has NO latch; the deliberate decision is PER-RESULT
//     (not rate-limited) and is pinned at the documented 20-results shape (R4-SPAM).

console.log("\nRound-4 — own ACCESSOR properties are live reads and must not escape by reference");
test("R4-A1: a TOP-LEVEL details getter (clean in-walk, secret at serialization) is neutralized", () => {
	resetEverything();
	let reads = 0;
	const details: Record<string, unknown> = {};
	Object.defineProperty(details, "payload", {
		enumerable: true,
		configurable: true,
		get() {
			reads++;
			return reads >= 3 ? `key=${TORTOISE_KEY}` : "ordinary";
		},
	});
	const event = toolResultEvent({ input: { path: "/repo/app.env" }, content: [{ type: "text", text: "clean" }], details });
	const { returned } = runHandler(event);
	const persisted = returned ? (returned as { details: unknown }).details : event.details;
	const bytes = JSON.stringify(persisted);
	ok(!bytes.includes(TORTOISE_KEY), `the accessor must be neutralized; got ${bytes}`);
	const entry = appendEntryCalls.find((call) => call.type === SECRET_ECHO_GUARD_ENTRY_TYPE);
	ok(entry, "the rebuild is recorded (an unstable read was neutralized)");
	for (const sink of [...appendEntryCalls.map((call) => JSON.stringify(call)), ...appendFileLines, ...notifications.map((note) => note.msg), ...consoleErrors]) {
		ok(!sink.includes(TORTOISE_KEY), "no sink may carry the value");
	}
});
test("R4-A2: a nested getter inside a DIRTY parent is rebuilt, not returned by reference", () => {
	resetEverything();
	let reads = 0;
	const inner: Record<string, unknown> = {};
	Object.defineProperty(inner, "x", {
		enumerable: true,
		configurable: true,
		get() {
			reads++;
			return reads >= 3 ? `leak=${AUTH_KEY}` : "ordinary";
		},
	});
	const event = toolResultEvent({
		input: { path: "/repo/app.env" },
		content: [{ type: "text", text: "clean" }],
		details: { secret: TORTOISE_KEY, inner },
	});
	const { returned } = runHandler(event);
	const persisted = returned ? (returned as { details: unknown }).details : event.details;
	const bytes = JSON.stringify(persisted);
	ok(!bytes.includes(AUTH_KEY), `the nested getter must not survive; got ${bytes}`);
	ok(returned, "the dirty parent is patched");
});
test("R4-A3: a `content` part whose `text` getter is clean in-walk is rebuilt from a single read", () => {
	resetEverything();
	let reads = 0;
	const part: Record<string, unknown> = { type: "text" };
	Object.defineProperty(part, "text", {
		enumerable: true,
		configurable: true,
		get() {
			reads++;
			// The content walk reads `text` THREE times in-walk (the harvest once + the redaction's
			// `typeof` check and `original` read), so the getter must stay clean through read 3 and only
			// return the secret on read 4 — the serializer's read. That is exactly the shape the accessor
			// rebuild neutralizes: without it, the part is returned BY REFERENCE and read 4 leaks.
			return reads >= 4 ? `k=${TORTOISE_KEY}` : "ordinary";
		},
	});
	const event = toolResultEvent({ input: { path: "/repo/app.env" }, content: [part] });
	const { returned } = runHandler(event);
	const persisted = returned ? (returned as { content: unknown }).content : event.content;
	const bytes = JSON.stringify(persisted);
	ok(!bytes.includes(TORTOISE_KEY), `the content accessor must be neutralized; got ${bytes}`);
	const entry = appendEntryCalls.find((call) => call.type === SECRET_ECHO_GUARD_ENTRY_TYPE);
	ok(entry, "the rebuilt content part is recorded");
	ok(
		notifications.some((note) => note.msg.includes("no secret value was redacted")),
		"an accessor-only rebuild must not claim it redacted a value (total=0)",
	);
	for (const sink of [...appendEntryCalls.map((call) => JSON.stringify(call)), ...appendFileLines, ...notifications.map((note) => note.msg), ...consoleErrors]) {
		ok(!sink.includes(TORTOISE_KEY), "no sink may carry the value");
	}
});
test("R4-A4: a harvest-REGISTERED value is not leaked by a later serializer read (nastiest variant)", () => {
	resetEverything();
	const fresh = "R4-HARVEST-GETTER-SECRET-0123456789";
	let reads = 0;
	const details: Record<string, unknown> = {};
	Object.defineProperty(details, "payload", {
		enumerable: true,
		configurable: true,
		get() {
			reads++;
			// Read 1 is the harvest (registers `fresh`); read 2 is pass 1 (clean, so the old code wrote no
			// record); read 3 is pass 2 (or, without the fix, the serializer).
			return reads === 2 ? "ordinary" : `OPENROUTER_API_KEY=${fresh}\n`;
		},
	});
	const event = toolResultEvent({ input: { path: "/repo/app.env" }, content: [{ type: "text", text: "clean" }], details });
	const { returned } = runHandler(event);
	const persisted = returned ? (returned as { details: unknown }).details : event.details;
	const bytes = JSON.stringify(persisted);
	ok(!bytes.includes(fresh), `the just-registered value must not leak; got ${bytes}`);
	const entry = appendEntryCalls.find((call) => call.type === SECRET_ECHO_GUARD_ENTRY_TYPE);
	ok(entry, "the rebuild writes an attestation record");
	for (const sink of [...appendEntryCalls.map((call) => JSON.stringify(call)), ...appendFileLines, ...notifications.map((note) => note.msg), ...consoleErrors]) {
		ok(!sink.includes(fresh), "no sink may carry the harvested value");
	}
});
test("R4-A5 (unit): `redactDetails` marks an accessor-bearing node dirty and rebuilds it as data", () => {
	const values = normalizeSecretValues([{ value: TORTOISE_KEY, label: "l" }]);
	const node: Record<string, unknown> = { stable: "ordinary" };
	Object.defineProperty(node, "live", { enumerable: true, configurable: true, get: () => "ordinary" });
	const out = redactDetails(node, values, new Map());
	strictEqual(out.changed, true, "an own accessor forces a rebuild even with no registered value");
	const rebuilt = out.value as Record<string, unknown>;
	const descriptor = Object.getOwnPropertyDescriptor(rebuilt, "live");
	ok(descriptor && descriptor.get === undefined, "the getter is replaced by a DATA property");
	strictEqual(rebuilt.live, "ordinary");
});
test("R4-A6 (unit): `redactContent` rebuilds an accessor-bearing part and the array", () => {
	const values = normalizeSecretValues([{ value: TORTOISE_KEY, label: "l" }]);
	const part: Record<string, unknown> = { type: "text", text: "ordinary" };
	Object.defineProperty(part, "extra", { enumerable: true, configurable: true, get: () => "ordinary" });
	const out = redactContent([part], values, new Map());
	strictEqual(out.changed, true, "a part with an own accessor is rebuilt");
	const rebuilt = (out.value as Array<Record<string, unknown>>)[0];
	const descriptor = Object.getOwnPropertyDescriptor(rebuilt, "extra");
	ok(descriptor && descriptor.get === undefined, "the getter is replaced by a DATA property");
	// The content ARRAY itself can carry an own accessor index; `map` snapshots it once and the array
	// must be returned as that snapshot, not by reference.
	const arrContent: unknown[] = [{ type: "text", text: "ordinary" }];
	Object.defineProperty(arrContent, "1", { enumerable: true, configurable: true, get: () => "ordinary" });
	arrContent.length = 2;
	const arrOut = redactContent(arrContent, values, new Map());
	strictEqual(arrOut.changed, true, "an accessor array index in content is snapshotted");
});
test("R4-A7 (unit): an accessor ARRAY index in details is rebuilt as a data index", () => {
	const values = normalizeSecretValues([{ value: TORTOISE_KEY, label: "l" }]);
	const arr: unknown[] = ["ordinary"];
	Object.defineProperty(arr, "1", { enumerable: true, configurable: true, get: () => "ordinary" });
	arr.length = 2;
	const out = redactDetails({ arr }, values, new Map());
	strictEqual(out.changed, true, "an accessor array index forces a rebuild");
	const rebuilt = (out.value as { arr: unknown[] }).arr;
	const descriptor = Object.getOwnPropertyDescriptor(rebuilt, "1");
	ok(descriptor && descriptor.get === undefined, "the getter is replaced by a DATA index");
});

console.log("\nRound-4 — a failure/bound with an EMPTY registry must still leave a durable record");
test("R4-B1: an UNREADABLE `content` with an EMPTY registry still writes a durable record", () => {
	resetEverything();
	try {
		_setSecretEchoGuardHooksForTest({ homedir: () => join(HOME, "nowhere"), env: () => ({}) });
		_resetSecretEchoGuardCacheForTest();
		const event = toolResultEvent({ details: { truncation: { content: "clean", truncated: false } } });
		Object.defineProperty(event, "content", {
			configurable: true,
			get() {
				throw new Error("content-boom");
			},
		});
		const { returned } = runHandler(event);
		strictEqual(returned, undefined);
		const entry = appendEntryCalls.find((call) => call.type === SECRET_ECHO_GUARD_ENTRY_TYPE);
		ok(entry, "a content-read failure must be recorded even with an empty registry");
		strictEqual((entry.data as { contentRedactionFailed: boolean }).contentRedactionFailed, true);
		strictEqual(appendFileLines.length, 1, "the fleet log gets it too");
	} finally {
		_setSecretEchoGuardHooksForTest(baseHooks);
		resetEverything();
	}
});
test("R4-B2: an UNREADABLE `details` with an EMPTY registry still writes a durable record", () => {
	resetEverything();
	try {
		_setSecretEchoGuardHooksForTest({ homedir: () => join(HOME, "nowhere"), env: () => ({}) });
		_resetSecretEchoGuardCacheForTest();
		const event = toolResultEvent({ content: [{ type: "text", text: "clean" }] });
		Object.defineProperty(event, "details", {
			configurable: true,
			get() {
				throw new Error("details-boom");
			},
		});
		const { returned } = runHandler(event);
		strictEqual(returned, undefined);
		const entry = appendEntryCalls.find((call) => call.type === SECRET_ECHO_GUARD_ENTRY_TYPE);
		ok(entry, "a details-read failure must be recorded even with an empty registry");
		strictEqual((entry.data as { detailsRedactionFailed: boolean }).detailsRedactionFailed, true);
	} finally {
		_setSecretEchoGuardHooksForTest(baseHooks);
		resetEverything();
	}
});
test("R4-B3: a BOUNDED source-5 harvest with an EMPTY registry is recorded and announced", () => {
	resetEverything();
	try {
		_setSecretEchoGuardHooksForTest({
			homedir: () => join(HOME, "nowhere"),
			env: () => ({}),
			detailsHarvestLimits: () => ({ maxNodes: 0, maxMs: 60_000 }),
		});
		_resetSecretEchoGuardCacheForTest();
		const { returned } = runHandler(
			toolResultEvent({
				input: { path: "/repo/app.env" },
				content: [{ type: "text", text: "clean" }],
				details: { truncation: { content: "clean", truncated: false } },
			}),
		);
		strictEqual(returned, undefined);
		const entry = appendEntryCalls.find((call) => call.type === SECRET_ECHO_GUARD_ENTRY_TYPE);
		ok(entry, "a bounded harvest must be recorded even with an empty registry");
		strictEqual((entry.data as { detailsWalkBounded: boolean }).detailsWalkBounded, true);
		ok(notifications.some((note) => note.msg.includes("WARNING")), "and announced");
	} finally {
		_setSecretEchoGuardHooksForTest(baseHooks);
		resetEverything();
	}
});

console.log("\nRound-4 — the three round-3 mutation survivors");
test("R4-C1: a per-result FAILURE (not bounded) is announced after the summary has fired", () => {
	resetEverything();
	const ctx = fakeCtx();
	runHandler(toolResultEvent({ content: [{ type: "text", text: `k=${TORTOISE_KEY}` }] }), ctx);
	strictEqual(notifications.length, 1, "the once-per-session summary fires first");
	const hostilePart = new Proxy(
		{},
		{
			get(_target, property) {
				if (property === "type") throw new Error("boom-type");
				return undefined;
			},
		},
	);
	runHandler(toolResultEvent({ toolCallId: "call-2", content: [hostilePart, { type: "text", text: "clean" }] }), ctx);
	ok(notifications.length > 1, "a failure-only result must be announced per-result");
	ok(notifications[notifications.length - 1].msg.includes("FAILED"), "the failure warning must appear");
});
test("R4-C2: a THROWING content-redaction walk is recorded and announced (never silent)", () => {
	resetEverything();
	// The throw is wired to the walk's FIRST access. It used to be `"map"` (the walk was a
	// `content.map`); round 11 replaced that with an indexed loop gated on the deadline, so the same
	// intent now rides `"length"` — a hostile part list that cannot even be MEASURED must still be
	// recorded and announced rather than passed through silently.
	const content = new Proxy([{ type: "text", text: "clean" }], {
		get(target, property, receiver) {
			if (property === "length") throw new Error("length-boom");
			return Reflect.get(target, property, receiver);
		},
	});
	const { returned } = runHandler(toolResultEvent({ content }));
	strictEqual(returned, undefined);
	const entry = appendEntryCalls.find((call) => call.type === SECRET_ECHO_GUARD_ENTRY_TYPE);
	ok(entry, "a throwing content-redaction walk must write a record");
	strictEqual((entry.data as { contentRedactionFailed: boolean }).contentRedactionFailed, true);
	ok(consoleErrors.some((line) => line.includes("content redaction failed")), "the failure is announced on stderr");
});
test("R4-C3: a details REDACTION failure announces BOTH the bounded and the failure warning", () => {
	resetEverything();
	const hostile: Record<string, unknown> = {};
	Object.defineProperty(hostile, "boom", {
		enumerable: true,
		configurable: true,
		get() {
			throw new Error("boom");
		},
	});
	runHandler(toolResultEvent({ content: [{ type: "text", text: "clean" }], details: hostile }));
	const note = notifications.find((entry) => entry.msg.includes("WARNING"));
	ok(note, "a warning is announced");
	ok(note!.msg.includes("FAILED"), "the FAILURE warning must accompany the bounded warning");
});

console.log("\nRound-4 — the pinned residual and the per-result announcement decision");
test("R4-RESIDUAL: a `toJSON`/private-field encoding is NOT redacted (pinned so it cannot drift)", () => {
	const values = normalizeSecretValues([{ value: TORTOISE_KEY, label: "l" }]);
	// The walk sees own enumerable DATA properties only; `toJSON` materializes an encoding at
	// serialization time, AFTER the guard's last read. Documented in the header's NOT COVERED list.
	const source = { safe: "ordinary", toJSON: () => ({ leaked: `k=${TORTOISE_KEY}` }) };
	const out = redactDetails(source, values, new Map());
	strictEqual(out.changed, false, "nothing in the enumerable data properties matched");
	ok(JSON.stringify(out.value).includes(TORTOISE_KEY), "the documented residual: toJSON materializes at serialization");
});
test("R4-RESIDUAL2: a Proxy whose `get` trap changes while it reports a stable data property is NOT neutralized (pinned)", () => {
	const values = normalizeSecretValues([{ value: TORTOISE_KEY, label: "l" }]);
	let reads = 0;
	const proxy = new Proxy(
		{ live: "ordinary" },
		{
			get(target, property, receiver) {
				if (property === "live") {
					reads++;
					return reads >= 2 ? `k=${TORTOISE_KEY}` : "ordinary";
				}
				return Reflect.get(target, property, receiver);
			},
		},
	);
	const out = redactDetails(proxy, values, new Map());
	strictEqual(out.changed, false, "pass 1 sees a stable data property and returns the proxy by reference");
	ok(JSON.stringify(out.value).includes(TORTOISE_KEY), "the documented residual: the hidden live read materializes at serialization");
});
test("R4-SPAM (documented decision): 20 bounded results announce 20 times — deliberate per-result, not rate-limited", () => {
	resetEverything();
	const ctx = fakeCtx();
	let deep: Record<string, unknown> = { leaf: "ordinary" };
	for (let i = 0; i < MAX_DETAILS_DEPTH + 5; i++) deep = { next: deep };
	for (let i = 0; i < 20; i++) {
		runHandler(toolResultEvent({ toolCallId: `call-${i}`, content: [{ type: "text", text: "clean" }], details: deep }), ctx);
	}
	strictEqual(notifications.length, 20, "one notice per bounded result — the documented per-result decision");
	strictEqual(appendEntryCalls.length, 20, "and one durable record per bounded result");
});

// ── Round 5: the content SNAPSHOT leak and the pass-2 runtime bound ──────────────────────────
//
// Two review findings. Both are "a previously-invisible read reaches a sink", which is what this
// guard exists to stop, so both are pinned from the SINK SIDE (the serialized value) rather than
// from the flag it happens to set.
console.log("\ntool_result handler — round 5 (snapshot leak + pass-2 bound)");

test("R5-SNAPSHOT: a content-array accessor INDEX cannot persist a secret behind a clean attestation", () => {
	const SNAPSHOT_SECRET = "SNAPSHOT-SECRET-0123456789ABCD";
	const values = normalizeSecretValues([{ value: SNAPSHOT_SECRET, label: "tortoise-config.json#apiKey" }]);
	// The array carries an own enumerable ACCESSOR index. `Array.prototype.map` reads it once into
	// `parts`, and `hasOwnEnumerableAccessor(content)` sets `changed`, so `parts` is what persists —
	// including the getter's returned string. Before this fix that string fell straight through
	// `return part`, so the record read `contentRedacted: true, total: 0` and the notice said no value
	// had been redacted, while the secret sat in the transcript.
	const content: unknown[] = [{ type: "text", text: "ordinary output" }];
	Object.defineProperty(content, "1", {
		enumerable: true,
		configurable: true,
		get: () => `OPENROUTER_API_KEY=${SNAPSHOT_SECRET}`,
	});
	content.length = 2;
	const out = redactContent(content, values, new Map());
	const serialized = JSON.stringify(out.value);
	ok(!serialized.includes(SNAPSHOT_SECRET), `the snapshot must not carry the value: ${serialized}`);
	ok(serialized.includes(REDACTION_MARKER_BASE), "the value is REPLACED, not merely dropped");
	strictEqual(out.changed, true, "and the result is attested as changed");
});

test("R5-BARE-STRING: a bare string content element is redacted (previously leaked with no record)", () => {
	const BARE_SECRET = "BARE-STRING-SECRET-0123456789";
	const values = normalizeSecretValues([{ value: BARE_SECRET, label: "l" }]);
	const out = redactContent([`OPENROUTER_API_KEY=${BARE_SECRET}`], values, new Map());
	const serialized = JSON.stringify(out.value);
	ok(!serialized.includes(BARE_SECRET), `a string element is outbound text too: ${serialized}`);
	strictEqual(out.changed, true);
});

test("R5-UNSTABLE-PART: an unstable NON-text part's accessor value is redacted, not copied raw", () => {
	const PART_SECRET = "UNSTABLE-PART-SECRET-0123456789";
	const values = normalizeSecretValues([{ value: PART_SECRET, label: "l" }]);
	// Non-text, so the text branch never runs; `unstable` makes it rebuild, and the rebuild READ the
	// getter — so the value it copied was the live one and had to be redacted on the way in.
	const part: Record<string, unknown> = { type: "image" };
	Object.defineProperty(part, "caption", { enumerable: true, configurable: true, get: () => `k=${PART_SECRET}` });
	const out = redactContent([part], values, new Map());
	ok(!JSON.stringify(out.value).includes(PART_SECRET), "the rebuilt part must not carry the live value");
	strictEqual(out.changed, true);
});

test("R5-BOUND: the details walk never SILENTLY overruns its budget (contract, load-independent)", () => {
	const BOUND_SECRET = "BOUND-SECRET-0123456789ABCDEF";
	const values = normalizeSecretValues([{ value: BOUND_SECRET, label: "l" }]);
	const big: Record<string, string> = {};
	for (let i = 0; i < 200_000; i++) big[`k${i}`] = "v";
	big["zzlast"] = `x-${BOUND_SECRET}`; // dirty only at the very END of pass 1 — the worst case
	const BUDGET = 2_000;
	const started = Date.now();
	const out = redactDetails(big, values, new Map(), { maxMs: BUDGET });
	const elapsed = Date.now() - started;
	// THE GUARANTEE, deliberately a DISJUNCTION: either the walk finished inside its budget, or it
	// says it did not. What must never happen is an overrun reported as COMPLETE — the round-5
	// defect (3310ms against a 2s budget with `bounded` FALSE).
	//
	// ⛔ Deliberately NOT `elapsed <= BUDGET + slack` on its own, and deliberately not a wall-clock
	// number pinned to this machine. This box runs a fleet: at load average 87 a duration assertion
	// is a LOAD DETECTOR, not a test, and an earlier version of this test asserted the duration and
	// flaked RED — a flaky red is worse than a weaker assertion, because it teaches callers to
	// ignore the suite. Green is deterministic; catching the mutation is best-effort. The interval
	// check can overshoot by up to DETAILS_BUDGET_CHECK_INTERVAL nodes, hence the slack.
	ok(
		out.bounded === true || elapsed <= BUDGET + 250,
		`an overrun must be REPORTED, never presented as a complete walk (bounded=${out.bounded} elapsed=${elapsed}ms budget=${BUDGET}ms)`,
	);
	if (!out.bounded) {
		// Only claimed when the walk genuinely finished: on a bounded walk the un-walked tail is
		// returned BY REFERENCE (the documented fail-open posture), so this cannot be asserted there.
		ok(!JSON.stringify(out.value).includes(BOUND_SECRET), "a COMPLETED walk must have redacted the secret");
	}
});

// ⛔ There is deliberately NO test here that asserts pass 2's budget in isolation by timing it.
// Two versions were written and both were removed: the first used `maxMs: 1`, which made PASS 1
// exhaust and set `bounded` (so it passed with the pass-2 check disabled — it pinned the wrong
// thing), and the second measured pass 1's cost in-test to pick a budget between the two passes,
// which is still a wall-clock assertion and flaked RED under fleet load. A load-independent test of
// a WALL-CLOCK bound is not reachable through the public surface, because the only deterministic
// budget it exposes (`maxNodes`) is per-pass by design and so cannot distinguish the passes.
// The guarantee is pinned instead by R5-BOUND above (never a silent overrun), by R5-NO-STARVE
// (pass 2 runs and is not starved), and by the mutation recorded in this commit's message:
// disabling the pass-2 check reproduces the round-5 signature (1547ms against a 758ms budget,
// `bounded` false) — proven at low load, where the timing is meaningful.

test("R5-NO-STARVE: pass 2 gets its own node allowance, so pass 1's count cannot redact nothing", () => {
	// With a SHARED counter, a tree above pass 1's allowance makes pass 2 exit immediately, returning
	// every dirty node BY REFERENCE — i.e. it would redact nothing. The count is therefore per-pass and
	// only the clock is shared. This pins that a tree which exhausts pass 1's COUNT but not the CLOCK
	// still redacts, which is the difference between "bounded" and "redacted nothing".
	const STARVE_SECRET = "STARVE-SECRET-0123456789ABCDE";
	const values = normalizeSecretValues([{ value: STARVE_SECRET, label: "l" }]);
	const small: Record<string, unknown> = { a: { b: `k=${STARVE_SECRET}` } };
	// An allowance too small for pass 1 to finish the key list, but a healthy clock: pass 2 must still
	// rebuild the dirty subtree it knows about.
	const out = redactDetails(small, values, new Map(), { maxNodes: 3, maxMs: 60_000 });
	ok(!JSON.stringify(out.value).includes(STARVE_SECRET), "the dirty subtree is still redacted");
});

test("R5-TEXT-FALLBACK: a non-enumerable `text` field survives the rebuild (mutant M19)", () => {
	// `rebuildContentPart` walks `Object.keys(part)`, which SKIPS non-enumerable keys — so a part whose
	// `text` is non-enumerable would lose it entirely unless the explicit fallback re-adds it. The
	// rebuild is reached because the value had to be redacted. Dropping that fallback is silent content
	// loss (no leak, but the text disappears from the transcript), and nothing else pinned it.
	const FE_SECRET = "FE-SECRET-0123456789ABCDEF";
	const values = normalizeSecretValues([{ value: FE_SECRET, label: "l" }]);
	const part: Record<string, unknown> = { type: "text" };
	Object.defineProperty(part, "text", {
		value: `k=${FE_SECRET}`,
		enumerable: false, // invisible to Object.keys -> only the fallback can preserve it
		configurable: true,
		writable: true,
	});
	const out = redactContent([part], values, new Map());
	const first = (out.value as Record<string, unknown>[])[0] as Record<string, unknown>;
	strictEqual(typeof first.text, "string", "the field must still be present after the rebuild");
	ok(!String(first.text).includes(FE_SECRET), "and it must be the REDACTED value");
});

// ── #5109 review round 6 ────────────────────────────────────────────────────────────────────
//
// Round 5 closed the STRING element of the content-array accessor snapshot. Round 6 found the same
// attestation lie for every OTHER shape: a non-text object part, a nested value, a nested accessor,
// and a registered value used as a KEY all passed through while `changed` was set — so the record
// read `contentRedacted: true, total: 0` and the notice said nothing had been redacted. A rebuilt
// part now delegates its object/array values to the SAME deep walker `details` uses.

test("R6-PART-NESTED-VALUE: a non-text part's nested string is redacted, not copied by reference", () => {
	const S = "R6-NESTED-SECRET-0123456789ABCD";
	const values = normalizeSecretValues([{ value: S, label: "l" }]);
	// No own accessor and not a text part, so before this fix it fell straight through `return part`.
	// The array accessor makes the SNAPSHOT what persists, so the nested value reached the transcript.
	const content: unknown[] = [{ type: "image" }];
	Object.defineProperty(content, "1", {
		enumerable: true,
		configurable: true,
		get: () => ({ note: `k=${S}` }),
	});
	content.length = 2;
	const out = redactContent(content, values, new Map());
	const serialized = JSON.stringify(out.value);
	ok(!serialized.includes(S), `a nested value is outbound text too: ${serialized}`);
	ok(serialized.includes(REDACTION_MARKER_BASE), "the value is REPLACED, not merely dropped");
	strictEqual(out.changed, true, "and the result is attested as changed");
});

test("R6-PART-NESTED-ARRAY: a nested array value is redacted too", () => {
	const S = "R6-NESTED-ARRAY-SECRET-0123456789";
	const values = normalizeSecretValues([{ value: S, label: "l" }]);
	const part: Record<string, unknown> = { type: "image", blocks: [`k=${S}`] };
	const out = redactContent([part], values, new Map());
	ok(!JSON.stringify(out.value).includes(S), "an array inside a part is outbound too");
	strictEqual(out.changed, true);
});

test("R6-PART-KEY: a registered value used as a part KEY is redacted, not written verbatim", () => {
	const S = "R6-KEY-SECRET-0123456789ABCDEF";
	const values = normalizeSecretValues([{ value: S, label: "l" }]);
	// A clean text part: the text does not change, so before this fix it returned BY REFERENCE with
	// the secret still sitting as a key. `redactDetails` treats a key match as dirtying the container.
	const out = redactContent([{ type: "text", text: "clean", [S]: "v" }], values, new Map());
	const serialized = JSON.stringify(out.value);
	ok(!serialized.includes(S), `a KEY lands in the transcript: ${serialized}`);
	strictEqual(out.changed, true);
});

test("R6-PART-NESTED-ACCESSOR: a nested accessor inside a part is rebuilt to data properties", () => {
	const S = "R6-DEEP-GETTER-SECRET-0123456789";
	const values = normalizeSecretValues([{ value: S, label: "l" }]);
	const inner: Record<string, unknown> = {};
	Object.defineProperty(inner, "deep", { enumerable: true, configurable: true, get: () => `k=${S}` });
	const out = redactContent([{ type: "image", meta: inner }], values, new Map());
	ok(!JSON.stringify(out.value).includes(S), "a nested getter is a live read too");
	strictEqual(out.changed, true);
});

test("R6-TEXT-SIBLING: a CLEAN text part with a dirty SIBLING field is not attested clean", () => {
	const S = "R6-SIBLING-SECRET-0123456789ABCD";
	const values = normalizeSecretValues([{ value: S, label: "l" }]);
	const out = redactContent([{ type: "text", text: "ordinary", meta: { nested: `k=${S}` } }], values, new Map());
	const serialized = JSON.stringify(out.value);
	ok(!serialized.includes(S), `a sibling field is outbound too: ${serialized}`);
	strictEqual(out.changed, true);
});

test("R6-PART-KEY-DIRTY: a key is redacted even when the part is rebuilt for ANOTHER reason", () => {
	const S = "R6-KEY-DIRTY-SECRET-0123456789AB";
	const K = "R6-KEYNAME-SECRET-0123456789ABC";
	const values = normalizeSecretValues([{ value: S, label: "l" }, { value: K, label: "l" }]);
	// The TEXT is dirty, so the part is rebuilt from the RAW part and the deep scan never ran on it —
	// this is the path where `rebuildContentPart`'s own key redaction is the only thing standing
	// between the transcript and a secret used as a key.
	const out = redactContent([{ type: "text", text: `k=${S}`, [K]: "v" }], values, new Map());
	const serialized = JSON.stringify(out.value);
	ok(!serialized.includes(S), serialized);
	ok(!serialized.includes(K), `a key must be redacted on the rebuild path too: ${serialized}`);
	strictEqual(out.changed, true);
});

test("R6-UNSTABLE-NESTED: a rebuilt part's NESTED field is deep-redacted", () => {
	const S = "R6-UNSTABLE-NESTED-SECRET-012345678";
	const values = normalizeSecretValues([{ value: S, label: "l" }]);
	// An own accessor on the part routes it to the forced rebuild; its NESTED VALUES are covered by
	// `rebuildNested`, which invokes the deep walk per value (the walk is not run on the PART itself on
	// this path).
	const part: Record<string, unknown> = { type: "image", meta: { nested: `k=${S}` } };
	Object.defineProperty(part, "caption", { enumerable: true, configurable: true, get: () => "clean" });
	const out = redactContent([part], values, new Map());
	ok(!JSON.stringify(out.value).includes(S), "a nested field of a rebuilt part must be redacted");
	strictEqual(out.changed, true);
});

// ── #5109 review round 7 ────────────────────────────────────────────────────────────────────
//
// Round 6 made the deep walk the single redaction path for `content` parts, but `rebuildContentPart`
// — the walker still used for the TEXT paths — swallowed `redactDetails(...).bounded`. A nested walk
// that hit its budget then returned the tail BY REFERENCE while `incomplete` stayed false: the record
// read `contentRedacted: true, total: 0`, `contentRedactionFailed: false`, and the notice said no
// value had been redacted, over a persisted secret. `bounded` is now threaded out; these pin it.
//
// The trigger is `MAX_DETAILS_DEPTH`: a part nested deeper than it stops pass 1 (setting `bounded`)
// without marking anything dirty, which is deterministic — no clock, no host speed.

function deepEnoughToBound(secret: string): Record<string, unknown> {
	let node: Record<string, unknown> = { leaf: `k=${secret}` };
	for (let i = 0; i < 40; i++) node = { nest: node };
	return node;
}

test("R7-UNSTABLE-DEEP-BOUND: an unstable part's bounded deep walk is INCOMPLETE (round-7 [P1])", () => {
	const S = "R7-UNSTABLE-DEEP-SECRET-0123456789";
	const values = normalizeSecretValues([{ value: S, label: "l" }]);
	const part: Record<string, unknown> = { type: "image", payload: deepEnoughToBound(S) };
	Object.defineProperty(part, "caption", { enumerable: true, configurable: true, get: () => "clean" });
	const out = redactContent([part], values, new Map());
	// Before the fix this was the DEDICATED `rebuildContentPart` call, which dropped `bounded` —
	// `incomplete` was false and the record attested a clean redaction over the persisted secret.
	strictEqual(out.incomplete, true, "a bounded walk must never be attested as clean");
});

test("R7-TEXT-DEEP-BOUND: a bounded SIBLING scan on a clean text part is INCOMPLETE", () => {
	const S = "R7-TEXT-DEEP-SECRET-0123456789AB";
	const values = normalizeSecretValues([{ value: S, label: "l" }]);
	const out = redactContent(
		[{ type: "text", text: "ordinary", payload: deepEnoughToBound(S) }],
		values,
		new Map(),
	);
	strictEqual(out.incomplete, true, "a bounded scan must never be attested as clean");
});

test("R7-REBUILD-DEEP-BOUND: the rebuild path reports its nested walk's bound too", () => {
	const S = "R7-REBUILD-DEEP-SECRET-0123456789";
	const values = normalizeSecretValues([{ value: S, label: "l" }]);
	// The TEXT is dirty, so the part is rebuilt from the RAW part through `rebuildContentPart` — this
	// is the path whose nested `bounded` was discarded (the other half of the round-7 [P1]).
	const out = redactContent(
		[{ type: "text", text: `k=${S}`, payload: deepEnoughToBound(S) }],
		values,
		new Map(),
	);
	strictEqual(out.incomplete, true, "the rebuild path must surface its nested bound");
	strictEqual(out.changed, true);
});

test("R7-BOXED-STRING-RESIDUAL: a boxed `String` is NOT redacted (documented residual — pinned, but SILENT at runtime)", () => {
	const S = "R7-BOXED-STRING-SECRET-01234567";
	const values = normalizeSecretValues([{ value: S, label: "l" }]);
	// `typeof` is "object" for a boxed String and `Object.keys` yields character INDICES, so
	// `containsRegisteredValue` never sees the value. `JSON.stringify` DOES serialize a boxed String,
	// so this is a live (contrived) leak on both the top-level `text` field (the pre-existing R3
	// residual) and, as round 7 noted, a NESTED one. Pinned deliberately: the deep walk must not be
	// described as covering a shape it does not.
	// eslint-disable-next-line no-new-wrappers
	const boxed = new String(`k=${S}`);
	const out = redactContent([{ type: "image", meta: { s: boxed } }], values, new Map());
	ok(JSON.stringify(out.value).includes(S), "pinned: the boxed value survives — see this test's name");
});

test("R6-BOUND-DETERMINISTIC: pass 2 consults the budget — pinned on a SCRIPTED CLOCK", () => {
	// Round 5 gave pass 2 a per-node budget check, but NOTHING pinned it: on this box's usual load the
	// 200k-key walk finishes in ~0.4s against a 2s budget, so deleting the check left the suite GREEN
	// four runs in a row. A duration assertion cannot fix that — a wall-clock test is a load detector,
	// which is exactly what round 6 removed — so the clock is INJECTED.
	//
	// Reads: #1 construction, #2 pass 1's first node (its allowance is a multiple of the check
	// interval, so the deadline is consulted there) — both t=0, so pass 1 stays inside its budget.
	// Every read after that is far past the deadline, and pass 2's allowance is RESET before it runs,
	// so its first node consults the clock again. `bounded` can therefore only have come from PASS 2.
	//
	// ⛔ THE LEAVES ARE NUMBERS AND `values` IS EMPTY, DELIBERATELY (#5109 review round 8).
	// Round 7 made `redactString` AND `containsRegisteredValue` budget-aware, so a STRING leaf — or even
	// a string KEY, since pass 1 checks every key — can set `bounded` by itself, which silently un-pinned
	// this test: removing pass 2's check left it GREEN again. With no registered values there is nothing
	// for either scan to iterate, so pass 1 performs no clock read beyond its first node, and the only
	// way `bounded` can be set is PASS 2 consulting the clock. Dirtiness comes from an own ACCESSOR, so
	// pass 2 runs at all without any registered value present.
	const values = normalizeSecretValues([]);
	let reads = 0;
	const now = () => (reads++ < 2 ? 0 : 1_000_000);
	const tree: Record<string, unknown> = {};
	for (let i = 0; i < 100; i++) tree[`k${i}`] = i;
	Object.defineProperty(tree, "trap", { enumerable: true, configurable: true, get: () => 1 });
	const out = redactDetails(tree, values, new Map(), { maxNodes: 1024, maxMs: 1_000, now });
	strictEqual(out.bounded, true, "pass 2 must RECORD that it hit the budget");
	// Selectivity: deleting `if (detailsBudgetExhausted(state)) return node;` from `rebuildDetails`
	// stops the clock ever being read on pass 2 — nothing else on this tree can set `bounded` — so
	// this assertion reds.
});

test("R8-STRING-BOUND: a string scan stops at the deadline and SAYS SO", () => {
	const S = "R8-STRING-BOUND-SECRET-0123456789";
	// 100 values, the registered secret LAST in scan order. The deadline is already past on the first
	// sample, so the scan stops immediately and reports `bounded` — the string scan is bounded by the
	// advertised budget instead of running per-value over a multi-megabyte string.
	const values = normalizeSecretValues([
		...Array.from({ length: 100 }, (_, i) => ({ value: `filler-${i}-VALUE`, label: `f${i}` })),
		{ value: S, label: "l" },
	]);
	const budget = { nodes: 1, nodeAllowance: 1, deadline: 0, bounded: false, now: () => 0 };
	const out = redactString(`start ${S} end`, values, new Map(), budget);
	strictEqual(budget.bounded, true, "an early stop must be reported, never silent");
	ok(out.includes(S), "pinned: the values after the stop are left UNSCANNED — the fail-open posture");
	// And with no budget (every non-content caller) the scan is complete and unchanged.
	const full = redactString(`start ${S} end`, values, new Map());
	ok(!full.includes(S), "the default path must still redact");
});

test("R8-UNSTABLE-FORCED-REBUILD: a live getter is rebuilt even when the deep walk's budget is spent", () => {
	const S = "R8-FORCED-REBUILD-SECRET-012345678";
	const values = normalizeSecretValues([{ value: S, label: "l" }]);
	// The accessor is LAST and the nested payload exceeds `CONTENT_PART_LIMITS.maxNodes`, so a bare deep
	// walk returns `changed: false, bounded: true` and the part would go back BY REFERENCE with a LIVE
	// getter (round 8 refuted the claim that the accessor case was subsumed by that walk). The forced
	// rebuild reads the getter ONCE and writes a data property; its nested value walk is the part that
	// hits the budget, and that must be announced rather than silently presented as complete.
	const nested: Record<string, unknown> = {};
	for (let i = 0; i < 260_000; i++) nested[`k${i}`] = i;
	const part: Record<string, unknown> = { type: "image", payload: nested };
	Object.defineProperty(part, "caption", { enumerable: true, configurable: true, get: () => `k=${S}` });
	const out = redactContent([part], values, new Map());
	const first = (out.value as unknown[])[0] as Record<string, unknown>;
	const descriptor = Object.getOwnPropertyDescriptor(first, "caption");
	ok(descriptor !== undefined && descriptor.get === undefined,
		"the live getter must be replaced by a data property");
	ok(!JSON.stringify(out.value).includes(S), "and the value it returned must be redacted");
	strictEqual(out.incomplete, true, "the bounded nested walk must be announced");
});

test("R8-PASS1-STRING-BOUND: pass 1's string scan is bounded and reported too", () => {
	const S = "R8-PASS1-STRING-SECRET-0123456789";
	const values = normalizeSecretValues([
		...Array.from({ length: 100 }, (_, i) => ({ value: `filler-${i}-VALUE`, label: `f${i}` })),
		{ value: S, label: "l" },
	]);
	// A PLAIN STRING root that does NOT contain a registered value: pass 1 reaches it through
	// `containsRegisteredValue` (same per-VALUE cost as `redactString`, same need for a bound), and
	// because nothing matches, pass 2 NEVER RUNS — so `bounded` can only have come from pass 1's scan.
	// ⛔ If the probe string contained the secret, pass 1 would return dirty, pass 2 would run and read
	// the clock, and the test would pass with `containsRegisteredValue`'s check deleted.
	let reads = 0;
	const now = () => (reads++ < 2 ? 0 : 1_000_000);
	const out = redactDetails("start no-secret-here end", values, new Map(), { maxNodes: 1024, maxMs: 1_000, now });
	strictEqual(out.bounded, true, "pass 1's string scan must report its bound, never scan silently");
});

test("R8-TEXT-PATH-BUDGET: the text path really passes a budget to its string scan", () => {
	// `read`/`bash` deliver their payload as a TEXT part, so this is the shape that most needs the
	// bound. The deadline is made immediate through the exported limits (rather than a wall-clock sleep)
	// so the assertion is deterministic and does not depend on the host.
	const S = "R8-TEXT-PATH-SECRET-0123456789ABCD";
	const values = normalizeSecretValues([{ value: S, label: "l" }]);
	const saved = CONTENT_PART_LIMITS.maxMs;
	try {
		CONTENT_PART_LIMITS.maxMs = 0; // deadline == now, so the first sample is already expired
		const part = redactContent([{ type: "text", text: `k=${S}` }], values, new Map());
		strictEqual(part.incomplete, true, "a text part's bounded scan must be announced");
		const bare = redactContent(`k=${S}`, values, new Map());
		strictEqual(bare.incomplete, true, "a bare string element's bounded scan must be announced too");
		// A STRING ELEMENT of an ARRAY (not a `{type:"text"}` part): its scan has NO secondary coverage —
		// unlike the text-part branch, which the deep walk re-checks — so the final
		// `budget.bounded -> incomplete` propagation is the ONLY thing that reports it. Without that line
		// the handler's early-return gate is satisfied and the result returns `undefined` with the secret
		// persisted and NO record and NO notice (round 9, mutation S5). Dropping the budget argument at
		// that scan (S6) is caught here for the same reason.
		const arr = redactContent([`k=${S}`], values, new Map());
		strictEqual(arr.incomplete, true, "an array string element's bounded scan must be announced");
		// The REBUILD path's own key/value scans (round-10 [P2]) must be bounded too. An UNSTABLE part is
		// the shape that reaches `rebuildContentPart` without any earlier budgeted `redactString` call, so
		// this is the assertion that binds those scans rather than the text path's.
		const unstablePart: Record<string, unknown> = { type: "image", blob: "A".repeat(4000) };
		Object.defineProperty(unstablePart, "trap", { enumerable: true, configurable: true, get: () => 1 });
		const rebuilt = redactContent([unstablePart], values, new Map());
		strictEqual(rebuilt.incomplete, true, "the rebuild path's own scans must be bounded too");
	} finally {
		CONTENT_PART_LIMITS.maxMs = saved;
	}
});

test("R8-NONTEXT-DEEP-BOUND: a NON-text, NON-accessor part's bounded deep walk is announced", () => {
	const S = "R8-NONTEXT-DEEP-SECRET-0123456789";
	const values = normalizeSecretValues([{ value: S, label: "l" }]);
	// The shape the round-8 comment cites: a PLAIN object part whose nested payload bottoms out at
	// `MAX_DETAILS_DEPTH`. All three round-7 bound pins cover OTHER branches (an accessor part, and text
	// parts), so this branch's `deep.bounded -> incomplete` was unpinned until round 9's mutation check.
	const out = redactContent([{ type: "image", payload: deepEnoughToBound(S) }], values, new Map());
	strictEqual(out.incomplete, true, "a bounded deep walk on a plain part must be announced");
});

test("R8-ARRAY-PART: a rebuilt ARRAY part stays an array", () => {
	const S = "R8-ARRAY-PART-SECRET-0123456789";
	const values = normalizeSecretValues([{ value: S, label: "l" }]);
	// `Object.create(Object.getPrototypeOf([]))` is NOT an array, so a rebuilt array part lost
	// `Array.isArray`, `length` and iteration. The named accessor forces the rebuild.
	const part: unknown[] = [{ type: "text", text: "ordinary" }];
	Object.defineProperty(part, "named", { enumerable: true, configurable: true, get: () => `k=${S}` });
	const out = redactContent([part], values, new Map());
	const first = (out.value as unknown[])[0];
	ok(Array.isArray(first), "a rebuilt array part must stay an array");
	ok(!JSON.stringify(first).includes(S), "and its named accessor must be redacted");
});

test("R9-ALIAS-RESIDUAL: the forced rebuild counts per REFERENCE and breaks the alias (pinned residual)", () => {
	const S = "R9-ALIAS-SECRET-0123456789ABCDEF";
	const values = normalizeSecretValues([{ value: S, label: "l" }]);
	const hits = new Map<string, number>();
	const inner = { caption: `k=${S}` };
	const part: Record<string, unknown> = { type: "image", a: inner, b: inner };
	Object.defineProperty(part, "trap", { enumerable: true, configurable: true, get: () => 1 });
	const out = redactContent([part], values, hits);
	const first = (out.value as Record<string, unknown>[])[0] as Record<string, unknown>;
	ok(!JSON.stringify(out.value).includes(S), "the secret must still be redacted");
	// PINNED RESIDUAL (round 9, now recorded in the TREE rather than only in a commit message, so it
	// cannot drift): the forced rebuild walks each value with a FRESH memo, so one underlying
	// occurrence is counted once per REFERENCE and the rebuilt copies are no longer the same object.
	// The `details` deep path reports 1 and preserves the alias. No leak, no under-count — but `total`
	// is not comparable between the two paths, so pin both facts explicitly.
	strictEqual(hitsTotal(hits), 2, "pinned: one underlying occurrence is counted TWICE here");
	ok(first.a !== first.b, "pinned: the alias is broken on this path (the deep path preserves it)");
});

test("R9-NO-STARVE-SHARED: a shared budget must NOT starve pass 2 into losing a redaction", () => {
	const S = "R9-NO-STARVE-SHARED-SECRET-012345";
	const values = normalizeSecretValues([{ value: S, label: "l" }]);
	const savedNodes = CONTENT_PART_LIMITS.maxNodes;
	try {
		// A node allowance small enough that pass 1 spends it, with the secret EARLY so pass 1 marks it
		// dirty. Round 9 also shared the NODE counter, so pass 2's first check fired and every dirty node
		// came back BY REFERENCE — the secret the parent commit redacted was persisted. Sharing only the
		// clock (round 10) keeps this redaction. Losing a redaction is worse than being slow.
		CONTENT_PART_LIMITS.maxNodes = 1000;
		const tree: Record<string, unknown> = { first: `k=${S}` };
		for (let i = 0; i < 5000; i++) tree[`k${i}`] = "v";
		const out = redactContent([{ type: "image", payload: tree }], values, new Map());
		ok(!JSON.stringify(out.value).includes(S), "the secret must still be REDACTED, not abandoned");
		// ⛔ MULTI-PART (review round 11). The single-part case above distinguishes only the pass-2
		// RESET, so sharing the node counter alone survived it — while a multi-part payload leaked parts
		// 1..9 with the suite still green. Every part must be redacted.
		const parts = Array.from({ length: 10 }, () => {
			const t: Record<string, unknown> = { first: `k=${S}` };
			for (let i = 0; i < 5000; i++) t[`k${i}`] = "v";
			return { type: "image", payload: t };
		});
		const multi = redactContent(parts, values, new Map());
		const bytes = JSON.stringify(multi.value);
		ok(!bytes.includes(S), "NO part may be left unredacted — a shared budget starves pass 2 per part");
		strictEqual((bytes.match(/REDACTED/g) ?? []).length, 10, "every one of the ten parts is redacted");
	} finally {
		CONTENT_PART_LIMITS.maxNodes = savedNodes;
	}
});

test("R11-GLOBAL-BOUND: the walk stops at the deadline instead of scanning every part", () => {
	const S = "R11-GLOBAL-BOUND-SECRET-0123456789";
	const values = normalizeSecretValues([{ value: S, label: "l" }]);
	const saved = { ...CONTENT_PART_LIMITS };
	try {
		// Deterministic clock: advance every sample so the deadline is crossed partway through the walk.
		// This pins the GLOBAL bound — before round 11 the walk ran `content.map` to completion regardless
		// of the deadline, so 10M numeric parts cost 27.4s and reported `incomplete: false` (nothing ever
		// sampled the clock; the first version of this gate used `detailsBudgetExhausted`, which only
		// reads the clock when `nodes % 1024 === 0`, and this loop does not advance `nodes`).
		let tick = 0;
		let nowCalls = 0;
		CONTENT_PART_LIMITS.now = () => {
			nowCalls++;
			return (tick += 200);
		};
		CONTENT_PART_LIMITS.maxMs = 700;
		// The CLOCK-CALL COUNT is the observable that isolates the walk's reach. A late secret cannot be
		// used: once the deadline is spent `redactString` early-stops, so a reached element and an
		// unreached one are byte-identical — and the stop's copy loop reads every late index anyway. With
		// the gate the walk ends at ~index 64 (each scanned string samples the clock too); without it all
		// 1000 parts are visited.
		const content: unknown[] = Array.from({ length: 1000 }, () => "plain");
		const out = redactContent(content, values, new Map());
		strictEqual(out.incomplete, true, "stopping early MUST be announced, never attested clean");
		strictEqual((out.value as unknown[]).length, 1000, "every element is preserved — no shape regression");
		ok(nowCalls < 200, `the walk must stop at the deadline; sampled the clock ${nowCalls} times over 1000 parts`);
	} finally {
		Object.assign(CONTENT_PART_LIMITS, saved);
	}
});

test("R11-PRESCAN-BOUND: a huge key enumeration stops at the deadline and reports UNSTABLE", () => {
	const values = normalizeSecretValues([{ value: "R11-PRESCAN-SECRET-0123456789", label: "l" }]);
	const saved = { ...CONTENT_PART_LIMITS };
	try {
		// `hasOwnEnumerableAccessor` used `Object.keys` — one string allocation per key BEFORE the first
		// budget check could run (a 2M-key part from a custom/MCP tool). It now enumerates with `for...in`
		// and stops at the deadline, reporting UNSTABLE, which is the fail-SAFE direction: the caller
		// rebuilds from a single read instead of passing a possibly-live getter through.
		//
		// The PROBE COUNT isolates it: with the budget the enumeration stops mid-way, without it every key
		// is probed. (Timing cannot pin this — it is a performance guard.) Each key is probed ~3-4x
		// (`for...in`'s enumerability check, `hasOwnProperty`, then the descriptor read), so the absolute
		// numbers are inflated; the threshold sits between the two measured arms rather than at a round
		// number.
		let tick = 0;
		CONTENT_PART_LIMITS.now = () => (tick += 200);
		CONTENT_PART_LIMITS.maxMs = 250;
		// Calibration note: the clock must NOT already be spent at index 0, or the ARRAY gate stops before
		// the part is looked at and the pre-scan never runs (this test read a seductive 0 probes that way,
		// then survived its own mutation). construction -> 200, deadline 450; index 0 -> 400 (admitted);
		// the pre-scan's first sample -> 600, which crosses 450 and stops at 256 keys.
		let probes = 0;
		const target: Record<string, unknown> = {};
		for (let i = 0; i < 2000; i++) target[`k${i}`] = i;
		const proxy = new Proxy(target, {
			getOwnPropertyDescriptor(t, property) {
				probes++;
				return Reflect.getOwnPropertyDescriptor(t, property);
			},
		});
		const out = redactContent([proxy], values, new Map());
		ok(probes < 3000, `the enumeration must stop at the deadline; probed ${probes} (stop ≈ 1200, no-budget ≈ 8300)`);
		strictEqual(out.incomplete, true, "the stopped pre-scan must be announced");
	} finally {
		Object.assign(CONTENT_PART_LIMITS, saved);
	}
});

// ── Summary ─────────────────────────────────────────────────────────────────────────────────
console.error = realConsoleError;
console.log(`\n${failures.length === 0 ? "✅" : "❌"} ${passed} passed, ${failures.length} failed`);
if (failures.length > 0) {
	for (const failure of failures) console.log(`   - ${failure}`);
	rmSync(HOME, { recursive: true, force: true });
	process.exit(1);
}
rmSync(HOME, { recursive: true, force: true });
