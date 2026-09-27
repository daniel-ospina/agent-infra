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
	MAX_DETAILS_DEPTH,
	MIN_SECRET_LENGTH,
	SECRET_ECHO_GUARD_ENTRY_TYPE,
	SECRET_ECHO_GUARD_LOG,
	_setSecretEchoGuardHooksForTest,
	_resetSecretEchoGuardAnnouncementsForTest,
	_resetSecretEchoGuardCacheForTest,
	collectAllStringValues,
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
	redactString,
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
test("STRING content (defensive shape) is redacted", () => {
	resetEverything();
	const { returned } = runHandler(toolResultEvent({ content: `key=${TORTOISE_KEY}` }));
	ok(returned);
	equal((returned as { content: string }).content, `key=[REDACTED-SECRET:tortoise-config.json#apiKey]`);
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

// ── Summary ─────────────────────────────────────────────────────────────────────────────────
console.error = realConsoleError;
console.log(`\n${failures.length === 0 ? "✅" : "❌"} ${passed} passed, ${failures.length} failed`);
if (failures.length > 0) {
	for (const failure of failures) console.log(`   - ${failure}`);
	rmSync(HOME, { recursive: true, force: true });
	process.exit(1);
}
rmSync(HOME, { recursive: true, force: true });
