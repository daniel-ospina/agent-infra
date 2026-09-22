#!/usr/bin/env node
// verify-summarization-clamp-exemption.mjs — change (e) of #1316, proved end to end:
// "The summarization request must never have its output budget reduced by
//  clampMaxTokensToContext, and a prompt that cannot fit must fail loudly."
//
// The summarization prompt is the serialized conversation — the thing being summarized — so it is
// large by construction. `clampMaxTokensToContext` computes `available = contextWindow -
// estimateContextTokens(prompt) - 4096` and cuts the budget to it; as the prompt approaches the
// window, `available` falls below the summary `UPDATE_SUMMARIZATION_PROMPT` is told to PRESERVE,
// so the generation hits the cap, comes back `stopReason: "length"`, and
// `getSummarizationFailure()` discards it — the #1263(d) failure again, through the clamp.
//
// Change (e) is two-sided and lives at ONE seam: `createSummarizationOptions` marks the request,
// and `buildBaseOptions` (the shared choke point, ~10 call sites) honours the marker and throws an
// explicit error naming the prompt size and the window when the prompt cannot fit at all.
//
// This test drives the REAL caller (`generateSummaryWithUsage`) in BOTH representations — the
// pi-ai ESM and the bundle chunk the running CLI loads — with a stub `streamFn` that then calls
// the REAL `buildBaseOptions` on (i) a fabricated context whose `available` is 5,000 — below the
// requested 32,135 budget but above zero — and (ii) a context that cannot fit the window at all. Both legs are required:
//   RED   — pre-change, the marked request is still CLAMPED to 5,000, and the too-big prompt does
//           not throw (it silently collapses to the 1024 floor). A test that passes because it
//           could not observe the condition is forbidden: "no-repro → green" is unacceptable.
//   GREEN — post-change, the same request carries its full 32,135 budget, and the too-big prompt
//           throws an error naming the prompt tokens and the window, distinguishable from the
//           token-cap truncation error.
//   CONTROL — with no marker (the normal-turn path), `buildBaseOptions` is STILL clamped in BOTH
//           trees, and still does NOT throw on a too-big prompt. This is what proves the exemption
//           is caller-scoped rather than a blanket clamp removal.
//
// `buildBaseOptions` is not the only place the budget can be reduced: the anthropic-messages and
// bedrock adapters clamp AGAIN inside their own streamSimple, after it, for the budget-based
// thinking branch — reachable for a summarization request whenever the model reasons and the
// session thinking level is on. Driving those adapters end-to-end needs a live provider client, so
// the gate there is proven the same way `apply.mjs` proves every entry: the patched REGION
// verbatim in the post-change tree, and the UNGATED call present only in the pre-change tree.
//
// It also runs `apply.sh --check` against trees the check must reject: the pre-change temp tree
// (anchors present → every (e) entry NOT applied, exit 1), a MARKER-ONLY tree per (e) entry
// (patched code gone, marker kept, no pristine anchor → the neither-pristine-nor-patched refusal),
// and a QUOTED-NEEDLE tree (the needles survive only inside a comment → the same refusal, never
// "already applied"). The check must never claim the fix is present when it is not.
//
// Run: NODE_ENV=test node scripts/pi-patches/tests/verify-summarization-clamp-exemption.mjs
import { spawnSync } from "node:child_process";
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const PI_ROOT =
	process.env.PI_ROOT ??
	"/Users/danielospina/.local/share/pi-node/node-v22.23.2-darwin-arm64/lib/node_modules/@earendil-works/pi-coding-agent";

const HERE = import.meta.dirname;
const PATCH_DIR = join(HERE, "..");
const APPLY_SH = join(PATCH_DIR, "apply.sh");

const INSTALLED_VERSION = JSON.parse(readFileSync(join(PI_ROOT, "package.json"), "utf8")).version;
const MANIFEST_PATH = join(PATCH_DIR, "manifests", INSTALLED_VERSION, "manifest.json");
if (!existsSync(MANIFEST_PATH)) {
	throw new Error(`no manifest for the installed pi ${INSTALLED_VERSION}: ${MANIFEST_PATH}`);
}
const manifest = JSON.parse(readFileSync(MANIFEST_PATH, "utf8"));
const E_ENTRIES = manifest.entries.filter((e) => e.change === "e");
const E_ESM_MARKER = E_ENTRIES.find((e) => e.id === "e1-summarization-clamp-esm");
const E_BUNDLE_MARKER = E_ENTRIES.find((e) => e.id === "e2-summarization-clamp-bundle");
const E_ESM_OPTIONS = E_ENTRIES.find((e) => e.id === "e3-clamp-exemption-esm");
const E_BUNDLE_OPTIONS = E_ENTRIES.find((e) => e.id === "e4-clamp-exemption-bundle-http");
if (!E_ESM_MARKER || !E_BUNDLE_MARKER || !E_ESM_OPTIONS || !E_BUNDLE_OPTIONS) {
	throw new Error(
		`the manifest is missing a change-(e) entry; found: ${E_ENTRIES.map((e) => e.id).join(", ") || "(none)"}`,
	);
}

// The real measured regime: reserveTokens 16384 ⇒ summaryCap floor(0.8 × 16384) = 13,107; a
// 56,077-char previous summary (≈13,452 output tokens) floors the budget to 32,135 via #1263(d).
const RESERVE_TOKENS = 16_384;
const PREVIOUS_SUMMARY = "x".repeat(56_077);
const EXPECTED_BUDGET = Math.max(13_107, Math.min(Math.ceil(PREVIOUS_SUMMARY.length / 2) + 4096, 384_000));
const MODEL = {
	id: "deepseek-flash",
	provider: "deepseek",
	api: "openai-completions",
	contextWindow: 300_000,
	maxTokens: 384_000,
};
const SAFETY = 4096;
// `available = contextWindow - estimate - SAFETY`. 5,000 sits BELOW the requested 32,135 budget and
// ABOVE the 1,024 floor — the clamp-starvation window this issue exists for.
const BIG_AVAILABLE = 5_000;
const BIG_CONTEXT = contextWithTokens(MODEL.contextWindow - SAFETY - BIG_AVAILABLE);
const CLAMPED_TO = BIG_AVAILABLE;
// A prompt that cannot fit the window at all: available = -1,096.
const TOO_BIG_TOKENS = MODEL.contextWindow - SAFETY + 1_096;
const TOO_BIG_CONTEXT = contextWithTokens(TOO_BIG_TOKENS);
const CAP_TRUNCATION = "failed: generation hit the token cap and the summary is incomplete";

// The provider-adapter re-clamp probe: a reasoning model on a deliberately small window, so
// `available = window - prompt - 4096` is far below `budget + thinkingBudget` and the adapter's
// second clamp would bind if it were not gated. `RECLAMP_CONTEXT` is ~10,000 tokens.
const RECLAMP_WINDOW = 20_000;
const RECLAMP_THINKING = 8_192;
const RECLAMP_CONTEXT = contextWithTokens(10_000);

function contextWithTokens(tokens) {
	return { messages: [{ role: "user", content: [{ type: "text", text: "x".repeat(tokens * 4) }], timestamp: 1 }] };
}

const results = [];
let failures = 0;
function check(name, ok, detail = "") {
	results.push(`${ok ? "  ✅" : "  ❌"} ${name}${detail ? `  — ${detail}` : ""}`);
	if (!ok) failures++;
}

const TMP = mkdtempSync(join(tmpdir(), "pi-patch-e-"));
process.on("exit", () => rmSync(TMP, { recursive: true, force: true }));

/**
 * A self-contained copy of the installed tree: `dist/` and `package.json` copied, and a REAL
 * `node_modules/@earendil-works/pi-ai` (also copied) so the fixture can patch the pi-ai ESM
 * WITHOUT writing through a symlink into the installed tree. Every other `node_modules` entry is
 * symlinked (read-only) so external deps still resolve. This is stricter than the (d) test's
 * symlinked-`node_modules` tree on purpose: change (e) patches a file UNDER `node_modules/`, and a
 * symlinked `node_modules` would make `revertToPristine`/`applyEntries`/the false-PASS fixtures
 * mutate the live install. (Reproduced the hard way the first time this test ran.)
 */
function buildTree(label) {
	const root = join(TMP, label);
	mkdirSync(root, { recursive: true });
	cpSync(join(PI_ROOT, "dist"), join(root, "dist"), { recursive: true });
	cpSync(join(PI_ROOT, "package.json"), join(root, "package.json"));
	const nm = join(root, "node_modules");
	const scoped = join(nm, "@earendil-works");
	mkdirSync(scoped, { recursive: true });
	cpSync(join(PI_ROOT, "node_modules", "@earendil-works", "pi-ai"), join(scoped, "pi-ai"), { recursive: true });
	for (const name of readdirSync(join(PI_ROOT, "node_modules"))) {
		if (name === "@earendil-works" || name.startsWith(".")) continue;
		symlinkSync(join(PI_ROOT, "node_modules", name), join(nm, name), "dir");
	}
	for (const name of readdirSync(join(PI_ROOT, "node_modules", "@earendil-works"))) {
		if (name === "pi-ai") continue;
		symlinkSync(join(PI_ROOT, "node_modules", "@earendil-works", name), join(scoped, name), "dir");
	}
	return root;
}

/**
 * Force the (e) files into their PRE-change shape. Works whether the installed tree we copied was
 * already patched or not, so the RED leg can never silently become a green tree.
 */
function revertToPristine(root, entries) {
	for (const e of entries) {
		const file = join(root, e.file);
		let text = readFileSync(file, "utf8");
		if (text.includes(e.replace)) text = text.replace(e.replace, e.find);
		const n = text.split(e.find).length - 1;
		if (n !== 1) {
			throw new Error(`could not obtain ONE pristine anchor for ${e.id} in ${e.file} (found ${n}) — refusing to run a leg that cannot observe the condition`);
		}
		if (text.includes(e.replace)) throw new Error(`${e.id}: patched form survived the revert in ${e.file}`);
		writeFileSync(file, text);
	}
}

/** Apply the manifest's exact find→replace payload to a pristine tree. */
function applyEntries(root, entries) {
	for (const e of entries) {
		const file = join(root, e.file);
		const text = readFileSync(file, "utf8");
		const n = text.split(e.find).length - 1;
		if (n !== 1) throw new Error(`expected ONE pristine anchor for ${e.id} in ${e.file}, found ${n}`);
		writeFileSync(file, text.replace(e.find, e.replace));
	}
}

// The two representations pi ships the summarization path in: the unbundled pi-ai ESM, and the
// bundle chunks the running CLI loads (`bin` → `dist/bundle/cli.js`). Both `createSummarizationOptions`
// and `buildBaseOptions` exist in each; a fix carried in only one is a fix carried in half.
const REPS = [
	{
		id: "esm",
		label: "pi-ai ESM",
		compaction: "dist/core/compaction/compaction.js",
		options: "node_modules/@earendil-works/pi-ai/dist/api/simple-options.js",
	},
	{
		id: "bundle",
		label: "bundle chunks",
		compaction: "dist/bundle/chunks/chunk-JVUZSMYM.js",
		options: "dist/bundle/chunks/chunk-AXIIZGTV.js",
	},
];

/**
 * Drive the REAL `generateSummaryWithUsage` for one representation and return what the clamp did
 * with the REAL options the caller produced:
 *   agentMaxTokens — the pre-clamp budget handed to the stream function
 *   marker         — whether the caller marked the request for the exemption
 *   clampedBig     — buildBaseOptions(model, available=5,000, <the real options>).maxTokens
 *   clampedReal    — buildBaseOptions(model, <the real prompt context>, <the real options>).maxTokens
 *   tooBigThrew    — did buildBaseOptions throw on the un-fittable prompt
 *   tooBigValue    — the value it returned instead of throwing (pre-change)
 *   tooBigMessage  — the thrown message (post-change)
 *   controlBig     — buildBaseOptions(model, available=5,000, {maxTokens}) — no marker, the NORMAL turn
 *   controlTooBig  — the same normal turn against the un-fittable prompt
 */
async function observe(root, rep) {
	const compactionMod = await import(pathToFileURL(join(root, rep.compaction)).href);
	const optionsMod = await import(pathToFileURL(join(root, rep.options)).href);
	const generate = compactionMod.generateSummaryWithUsage;
	const buildBaseOptions = optionsMod.buildBaseOptions;
	if (typeof generate !== "function") throw new Error(`${rep.id}: generateSummaryWithUsage is not exported by ${rep.compaction}`);
	if (typeof buildBaseOptions !== "function") throw new Error(`${rep.id}: buildBaseOptions is not exported by ${rep.options}`);

	const recorded = {};
	const streamFn = (model, context, options) => {
		// The REAL options the caller built — this is where `createSummarizationOptions` is observed.
		recorded.agentMaxTokens = options.maxTokens;
		recorded.marker = options.skipContextClamp === true;
		// The clamp the provider adapter would apply. (i) `available` fabricated below the budget,
		// (ii) the un-fittable prompt.
		recorded.clampedBig = buildBaseOptions(model, BIG_CONTEXT, options, "probe-key").maxTokens;
		recorded.clampedReal = buildBaseOptions(model, context, options, "probe-key").maxTokens;
		try {
			recorded.tooBigValue = buildBaseOptions(model, TOO_BIG_CONTEXT, options, "probe-key").maxTokens;
			recorded.tooBigThrew = false;
			recorded.tooBigMessage = null;
		} catch (error) {
			recorded.tooBigThrew = true;
			recorded.tooBigMessage = error.message;
		}
		// The NORMAL-turn control: the exact options ~10 call sites pass, with no marker at all.
		recorded.controlBig = buildBaseOptions(model, BIG_CONTEXT, { maxTokens: EXPECTED_BUDGET }, "probe-key").maxTokens;
		recorded.controlTooBig = buildBaseOptions(model, TOO_BIG_CONTEXT, { maxTokens: EXPECTED_BUDGET }, "probe-key").maxTokens;
		return {
			result: async () => ({
				content: [{ type: "text", text: "previous-summary preserved" }],
				stopReason: "stop",
				usage: {
					input: 0,
					output: 0,
					cacheRead: 0,
					cacheWrite: 0,
					totalTokens: 0,
					cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
				},
			}),
		};
	};
	await generate(
		[],
		MODEL,
		RESERVE_TOKENS,
		"probe-key",
		{},
		undefined,
		undefined,
		PREVIOUS_SUMMARY,
		undefined,
		streamFn,
		{},
		undefined,
		undefined,
		undefined,
	);
	if (typeof recorded.agentMaxTokens !== "number") {
		throw new Error(`${rep.id}: the streamFn was never reached (or carried no maxTokens) — the probe cannot observe the condition, so it must not report success`);
	}
	return recorded;
}

/**
 * A real anthropic-messages model, taken from the installed registry so the adapter sees the real
 * `compat` surface. The context window is shrunk and `maxTokens` left large, so the provider
 * adapter's SECOND clamp is guaranteed to bind — i.e. it is the clamp, not the model cap, that
 * would move the request. `forceAdaptiveThinking` models are skipped: they take a different
 * thinking branch than the one that re-clamps.
 */
async function anthropicProbeModel(root) {
	const { MODELS } = await import(
		pathToFileURL(join(root, "node_modules/@earendil-works/pi-ai/dist/models.generated.js")).href,
	);
	const found = [];
	const walk = (value) => {
		if (!value || typeof value !== "object") return;
		if (value.api && value.id) {
			found.push(value);
			return;
		}
		for (const child of Object.values(value)) walk(child);
	};
	walk(MODELS);
	const model = found.find(
		(m) => m.api === "anthropic-messages" && m.reasoning && !(m.compat && m.compat.forceAdaptiveThinking),
	);
	if (!model) {
		throw new Error(
			"no reasoning anthropic-messages model without forced adaptive thinking is registered — the re-clamp probe cannot observe the condition, so it must not report success",
		);
	}
	return { ...model, provider: "anthropic", baseUrl: "https://api.anthropic.com", contextWindow: RECLAMP_WINDOW, maxTokens: 64000 };
}

/**
 * Drive the REAL `streamSimple` and read the `max_tokens` that actually lands in the request body
 * the adapter hands to `fetch`. This is end-to-end for the adapter's second clamp: the adapter
 * calls `buildBaseOptions` itself, then — because the model reasons and `options.reasoning` is set
 * — computes `adjusted = adjustMaxTokensForThinking(...)` and clamps THAT.
 *   marked   — `skipContextClamp: true`, i.e. the options `createSummarizationOptions` produces
 *   unmarked — the same request without the marker, i.e. the NORMAL-turn path
 * The two must diverge POST-change (the marker gates the adapter's clamp) and must be IDENTICAL
 * PRE-change (the marker is ignored, so the exemption is undone inside the adapter).
 */
async function observeReclamp(root, rep) {
	const model = await anthropicProbeModel(root);
	const mod = await import(pathToFileURL(join(root, rep.file)).href);
	if (typeof mod.streamSimple !== "function") throw new Error(`${rep.id}: streamSimple is not exported by ${rep.file}`);
	const run = async (extra) => {
		let seen = null;
		const fetchStub = async (_url, init) => {
			try {
				seen = JSON.parse(init.body).max_tokens;
			} catch {
				seen = "unparsable-request-body";
			}
			return new Response(JSON.stringify({ type: "error", error: { type: "overloaded_error", message: "probe" } }), {
				status: 200,
				headers: { "content-type": "application/json" },
			});
		};
		const stream = mod.streamSimple(model, RECLAMP_CONTEXT, {
			apiKey: "sk-ant-probe",
			reasoning: "high",
			thinkingBudgets: { high: RECLAMP_THINKING },
			maxTokens: EXPECTED_BUDGET,
			fetch: fetchStub,
			...extra,
		});
		await stream.result();
		return seen;
	};
	return { marked: await run({ skipContextClamp: true }), unmarked: await run({}) };
}

console.log("VERIFY (e) — the summarization request is exempt from clampMaxTokensToContext (#1316)");
console.log(`  pi root:  ${PI_ROOT}`);
console.log(`  manifest: ${MANIFEST_PATH}`);
console.log(
	`  budget ${EXPECTED_BUDGET} (reserveTokens ${RESERVE_TOKENS}); fabricated available ${CLAMPED_TO}; too-big prompt ${TOO_BIG_TOKENS} tokens\n`,
);

const preRoot = buildTree("pre-change");
revertToPristine(preRoot, E_ENTRIES);
const postRoot = buildTree("post-change");
revertToPristine(postRoot, E_ENTRIES);
applyEntries(postRoot, E_ENTRIES);

// ── Preconditions: the two trees really are pre-change / post-change, in EVERY representation ──
for (const [label, root, wantPatched] of [
	["pre-change", preRoot, false],
	["post-change", postRoot, true],
]) {
	for (const e of E_ENTRIES) {
		const text = readFileSync(join(root, e.file), "utf8");
		const hasFind = text.includes(e.find);
		const hasReplace = text.includes(e.replace);
		check(
			`${label}: ${e.id} is ${wantPatched ? "PATCHED" : "PRE-CHANGE"} in both shape checks`,
			wantPatched ? !hasFind && hasReplace : hasFind && !hasReplace,
			`find=${hasFind} replace=${hasReplace}`,
		);
	}
	// The bedrock copy is not driven behaviourally (its buildBaseOptions payload is byte-identical
	// to the shared chunk's, checked by shape above); parse both patched bundle files so a misplaced
	// delimiter cannot hide behind a text-only check.
	if (wantPatched) {
		for (const e of [E_BUNDLE_MARKER, E_BUNDLE_OPTIONS, E_ENTRIES.find((x) => x.id === "e5-clamp-exemption-bundle-bedrock")]) {
			const parsed = spawnSync(process.execPath, ["--check", join(root, e.file)], { encoding: "utf8" });
			check(
				`post-change: the patched ${e.id} still parses as JavaScript`,
				parsed.status === 0,
				`node --check exit=${parsed.status}${parsed.stderr ? `: ${parsed.stderr.trim()}` : ""}`,
			);
		}
	}
}

const pre = {};
const post = {};
for (const rep of REPS) {
	pre[rep.id] = await observe(preRoot, rep);
	post[rep.id] = await observe(postRoot, rep);
}

for (const rep of REPS) {
	const r = pre[rep.id];
	const p = post[rep.id];

	// ── RED — pre-change, the marked request is STILL clamped, and the too-big prompt is silent ──
	check(`${rep.label} RED: the real caller's pre-clamp budget is the #1263(d) floor`, r.agentMaxTokens === EXPECTED_BUDGET, `agentMaxTokens=${r.agentMaxTokens} expected ${EXPECTED_BUDGET}`);
	check(`${rep.label} RED: the caller does NOT mark the request pre-change`, r.marker === false, `marker=${r.marker}`);
	check(
		`${rep.label} RED: available=${CLAMPED_TO} < budget ${EXPECTED_BUDGET} → the request IS clamped`,
		r.clampedBig === CLAMPED_TO,
		`clamped maxTokens=${r.clampedBig} expected ${CLAMPED_TO}`,
	);
	check(
		`${rep.label} RED: the green assertion would FAIL pre-change (not vacuously passing)`,
		p.clampedBig !== r.clampedBig,
		`pre=${r.clampedBig} post=${p.clampedBig}`,
	);
	check(
		`${rep.label} RED: an un-fittable prompt does NOT fail loudly — it collapses to the 1024 floor`,
		r.tooBigThrew === false && r.tooBigValue === 1024,
		`threw=${r.tooBigThrew} value=${r.tooBigValue}`,
	);
	check(
		`${rep.label} RED: at the real prompt size the clamp is not binding either way (the measured margin)`,
		r.clampedReal === EXPECTED_BUDGET,
		`clampedReal=${r.clampedReal}`,
	);

	// ── GREEN — post-change, the marked request keeps its budget and fails loudly when it must ──
	check(`${rep.label} GREEN: the caller marks the request`, p.marker === true, `marker=${p.marker}`);
	check(
		`${rep.label} GREEN: available=${CLAMPED_TO} < budget ${EXPECTED_BUDGET} → the request is NOT clamped`,
		p.clampedBig === EXPECTED_BUDGET,
		`clamped maxTokens=${p.clampedBig} expected ${EXPECTED_BUDGET}`,
	);
	check(
		`${rep.label} GREEN: at the real prompt size the budget is unchanged`,
		p.clampedReal === EXPECTED_BUDGET,
		`clampedReal=${p.clampedReal}`,
	);
	check(`${rep.label} GREEN: an un-fittable prompt FAILS LOUDLY`, p.tooBigThrew === true, `threw=${p.tooBigThrew} value=${p.tooBigValue}`);
	check(
		`${rep.label} GREEN: the error names the prompt size and the window`,
		typeof p.tooBigMessage === "string" && p.tooBigMessage.includes(`prompt ~${TOO_BIG_TOKENS} tokens`) && p.tooBigMessage.includes(`${MODEL.contextWindow}-token window`),
		`message=${p.tooBigMessage}`,
	);
	check(
		`${rep.label} GREEN: the error is distinguishable from the token-cap truncation error`,
		typeof p.tooBigMessage === "string" && /NOT the "generation hit the token cap"/.test(p.tooBigMessage) && !p.tooBigMessage.includes(CAP_TRUNCATION),
		"names the cap-truncation error as a different failure",
	);
	check(`${rep.label}: the budget is genuinely higher than the clamped value`, p.clampedBig > r.clampedBig, `post ${p.clampedBig} > pre ${r.clampedBig}`);

	// ── CONTROL — the exemption is caller-scoped: a normal turn is still clamped in BOTH trees ──
	for (const [label, obs] of [["pre-change", r], ["post-change", p]]) {
		check(
			`${rep.label} CONTROL (${label}): a NORMAL turn at available=${CLAMPED_TO} is STILL clamped`,
			obs.controlBig === CLAMPED_TO,
			`control maxTokens=${obs.controlBig} expected ${CLAMPED_TO}`,
		);
		check(
			`${rep.label} CONTROL (${label}): a NORMAL turn with an un-fittable prompt does NOT throw (it takes the 1024 floor)`,
			obs.controlTooBig === 1024,
			`controlTooBig=${obs.controlTooBig}`,
		);
	}
}

// ── The provider adapters' SECOND clamp (budget-based thinking branch) ────────────────────────
// The re-clamp sites are the ones a reasoning model on anthropic-messages / bedrock reaches AFTER
// buildBaseOptions. They carry the same marker gate. For anthropic-messages BOTH representations
// are driven behaviourally (the `max_tokens` that lands in the request body); for
// bedrock-converse-stream the adapter authenticates through the AWS SDK, which cannot be driven
// with a fetch stub, so it is proven the way `apply.mjs` proves every entry — the patched REGION
// verbatim (never a scattered needle), plus the negative that the pre-change tree still holds the
// UNGATED call, plus a parse of the patched file.
const RECLAMP = E_ENTRIES.filter((e) => e.id.includes("reclamp"));
check(
	"the manifest carries all four provider-adapter re-clamp entries",
	RECLAMP.length === 4,
	`found ${RECLAMP.map((e) => e.id).join(", ") || "(none)"}`,
);

const RECLAMP_REPS = [
	{ id: "esm", label: "anthropic-messages ESM", file: "node_modules/@earendil-works/pi-ai/dist/api/anthropic-messages.js" },
	{ id: "bundle", label: "anthropic-messages bundle", file: "dist/bundle/chunks/anthropic-messages-VWZZOSJQ.js" },
];
for (const rep of RECLAMP_REPS) {
	let r;
	let p;
	try {
		r = await observeReclamp(preRoot, rep);
		p = await observeReclamp(postRoot, rep);
	} catch (error) {
		check(`RECLAMP ${rep.label}: the re-clamp probe can observe the condition`, false, String(error && error.message));
		continue;
	}
	check(
		`RECLAMP ${rep.label} RED: pre-change the marker is IGNORED by the adapter's second clamp`,
		r.marked === r.unmarked,
		`marked=${r.marked} unmarked=${r.unmarked}`,
	);
	check(
		`RECLAMP ${rep.label} RED: the green divergence would FAIL pre-change (not vacuously passing)`,
		p.marked !== r.marked,
		`pre marked=${r.marked} post marked=${p.marked}`,
	);
	check(
		`RECLAMP ${rep.label} GREEN: the marker exempts the adapter's second clamp — the FULL adjusted budget is sent`,
		p.marked === EXPECTED_BUDGET + RECLAMP_THINKING && p.marked > p.unmarked,
		`marked=${p.marked} expected ${EXPECTED_BUDGET + RECLAMP_THINKING} unmarked=${p.unmarked}`,
	);
	check(
		`RECLAMP ${rep.label} GREEN: the second clamp really was binding (unmarked < marked, and below the budget)`,
		typeof p.unmarked === "number" && p.unmarked > 0 && p.unmarked < EXPECTED_BUDGET,
		`unmarked=${p.unmarked} budget=${EXPECTED_BUDGET}`,
	);
	check(
		`RECLAMP ${rep.label} CONTROL: a NORMAL turn is clamped IDENTICALLY pre- and post-change`,
		p.unmarked === r.unmarked,
		`pre=${r.unmarked} post=${p.unmarked}`,
	);
}

for (const e of RECLAMP) {
	const preText = readFileSync(join(preRoot, e.file), "utf8");
	const postText = readFileSync(join(postRoot, e.file), "utf8");
	const ungated = e.id.includes("bundle")
		? ",maxTokens=clampMaxTokensToContext(model,context,adjusted.maxTokens);"
		: "const maxTokens = clampMaxTokensToContext(model, context, adjusted.maxTokens);";
	check(
		`RECLAMP ${e.id}: the pre-change tree carries the UNGATED second clamp`,
		preText.includes(ungated) && !preText.includes(e.replace),
		`ungated=${preText.includes(ungated)} patched=${preText.includes(e.replace)}`,
	);
	check(
		`RECLAMP ${e.id}: the post-change tree carries the marker-gated second clamp verbatim`,
		postText.includes(e.replace) && !postText.includes(ungated),
		`patched=${postText.includes(e.replace)} ungated=${postText.includes(ungated)}`,
	);
	const parsed = spawnSync(process.execPath, ["--check", join(postRoot, e.file)], { encoding: "utf8" });
	check(
		`RECLAMP ${e.id}: the patched file still parses as JavaScript`,
		parsed.status === 0,
		`node --check exit=${parsed.status}${parsed.stderr ? `: ${parsed.stderr.trim()}` : ""}`,
	);
}

// ── `apply.sh --check` on the pre-change tree must report every (e) entry ABSENT and exit 1 ────
const checkRun = spawnSync("bash", [APPLY_SH, "--check"], {
	encoding: "utf8",
	env: { ...process.env, PI_ROOT: preRoot, NODE_ENV: "test" },
});
const checkOut = `${checkRun.stdout ?? ""}${checkRun.stderr ?? ""}`;
console.log(`\n  RAW apply.sh --check OUTPUT (PI_ROOT=<pre-change temp tree>), exit ${checkRun.status}:\n`);
console.log(checkOut.split("\n").map((l) => `  | ${l}`).join("\n"));
check("--check on the pre-change tree exits 1 (not applied)", checkRun.status === 1, `exit=${checkRun.status}`);
for (const e of E_ENTRIES) {
	check(`--check reports ${e.id} as NOT applied`, checkOut.includes(e.id) && /NOT applied/.test(checkOut), "");
}
check("--check does NOT claim the fix is in place", !checkOut.includes("the fix is in place"), "");

// ── False-PASS guard: the provenance marker is NOT evidence that the exemption is installed ───
// A needle is code-shaped IFF it does NOT appear in the marker-only rendering of its OWN payload.
// The (d) guard's first version stripped only the exact marker spellings, so a FRAGMENT ("pi-patch",
// "1263", "#1263(d)") survived the strip, was called code-shaped, and was present on a marker-only
// stub — passing both assertions vacuously (#1314 review). Same predicate, same falsifiability.
const MARKER_RE = /(\/\/\s*pi-patch[^\n]*|\/\*\s*pi-patch[^*]*\*\/)/g;
const markerStub = (s) => (s.match(MARKER_RE) || []).join("\n");
const isCodeShaped = (entry, needle) => !markerStub(entry.replace).includes(needle);

// Fixture, parameterized over EVERY (e) entry: a fully-patched tree with THAT entry's payload
// replaced by its marker-only stub — patched code GONE, provenance marker KEPT, pristine anchor
// ABSENT. `--check` must refuse, must never report the entry as applied, and must never print the
// in-place message. The file is rebuilt from the pre-change copy on every iteration, so entries
// that share a file (e2 with d2/d3) cannot contaminate one another.
for (const e of E_ENTRIES) {
	const markerOnlyRoot = buildTree(`marker-only-${e.id}`);
	revertToPristine(markerOnlyRoot, E_ENTRIES);
	applyEntries(markerOnlyRoot, E_ENTRIES);
	const file = join(markerOnlyRoot, e.file);
	let text = readFileSync(file, "utf8");
	const before = text.split(e.replace).length - 1;
	if (before !== 1) {
		throw new Error(`marker-only fixture for ${e.id}: expected its patched payload exactly once in ${e.file}, found ${before}`);
	}
	text = text.replace(e.replace, markerStub(e.replace));
	writeFileSync(file, text);
	const markerOnly = readFileSync(file, "utf8");
	check(
		`FALSE-PASS FIXTURE (${e.id}): the marker is present, that entry's code is gone, and its pristine anchor is ABSENT`,
		markerOnly.includes(markerStub(e.replace)) && !markerOnly.includes(e.replace) && !markerOnly.includes(e.find),
		`marker=${markerOnly.includes(markerStub(e.replace))} code=${!markerOnly.includes(e.replace)} pristineAnchor=${markerOnly.includes(e.find)}`,
	);
	const markerRun = spawnSync("bash", [APPLY_SH, "--check"], {
		encoding: "utf8",
		env: { ...process.env, PI_ROOT: markerOnlyRoot, NODE_ENV: "test" },
	});
	const markerOut = `${markerRun.stdout ?? ""}${markerRun.stderr ?? ""}`;
	console.log(`\n  RAW apply.sh --check OUTPUT (PI_ROOT=<marker-only temp tree: ${e.id}>), exit ${markerRun.status}:\n`);
	console.log(markerOut.split("\n").map((l) => `  | ${l}`).join("\n"));
	check(
		`FALSE-PASS GUARD (${e.id}): --check on a marker-only tree exits NON-ZERO (expect the neither-pristine-nor-patched refusal, exit 2)`,
		markerRun.status !== 0,
		`exit=${markerRun.status}`,
	);
	check(
		`FALSE-PASS GUARD (${e.id}): --check never claims the fix is in place on a marker-only tree`,
		!markerOut.includes("the fix is in place"),
		"",
	);
	check(
		`FALSE-PASS GUARD (${e.id}): --check never reports that entry as applied on a marker-only tree`,
		!markerOut.includes(`= ${e.id} — already applied`),
		"",
	);
}

// ── Scattered-substring guard: quoting the needles in a comment is NOT the fix ────────────────
// The applied-check proves the entry's OWN replacement payload verbatim (`next.includes(entry.replace)`),
// so a comment that merely QUOTES the needles cannot satisfy it. Reproduced for every (e) entry.
for (const e of E_ENTRIES) {
	const quotedRoot = buildTree(`quoted-needles-${e.id}`);
	revertToPristine(quotedRoot, E_ENTRIES);
	applyEntries(quotedRoot, E_ENTRIES);
	const file = join(quotedRoot, e.file);
	let text = readFileSync(file, "utf8");
	const before = text.split(e.replace).length - 1;
	if (before !== 1) {
		throw new Error(`quoted-needle fixture for ${e.id}: expected its patched payload exactly once in ${e.file}, found ${before}`);
	}
	text = text.replace(e.replace, `// quoted needles: ${e.verifyPresent.join(" ")}\n`);
	writeFileSync(file, text);
	const quoted = readFileSync(file, "utf8");
	check(
		`SCATTERED-SUBSTRING FIXTURE (${e.id}): every verifyPresent needle is quoted in a comment while the code is gone`,
		e.verifyPresent.every((n) => quoted.includes(n)) && !quoted.includes(e.replace),
		`quoted=${e.verifyPresent.every((n) => quoted.includes(n))} payloadGone=${!quoted.includes(e.replace)}`,
	);
	const quotedRun = spawnSync("bash", [APPLY_SH, "--check"], {
		encoding: "utf8",
		env: { ...process.env, PI_ROOT: quotedRoot, NODE_ENV: "test" },
	});
	const quotedOut = `${quotedRun.stdout ?? ""}${quotedRun.stderr ?? ""}`;
	console.log(`\n  RAW apply.sh --check OUTPUT (PI_ROOT=<quoted-needles temp tree: ${e.id}>), exit ${quotedRun.status}:\n`);
	console.log(quotedOut.split("\n").map((l) => `  | ${l}`).join("\n"));
	check(
		`SCATTERED-SUBSTRING GUARD (${e.id}): --check on a quoted-needle tree does NOT exit 0`,
		quotedRun.status !== 0,
		`exit=${quotedRun.status}`,
	);
	check(
		`SCATTERED-SUBSTRING GUARD (${e.id}): --check never claims the fix is in place on a quoted-needle tree`,
		!quotedOut.includes("the fix is in place"),
		"",
	);
	check(
		`SCATTERED-SUBSTRING GUARD (${e.id}): --check never reports that entry as applied on a quoted-needle tree`,
		!quotedOut.includes(`= ${e.id} — already applied`),
		"",
	);
}

// ── The needles themselves are the guard — this is what makes the assertions non-vacuous ──────
{
	const byId = new Map(E_ENTRIES.map((e) => [e.id, e]));
	const markerFragments = [
		[E_ESM_MARKER.id, "pi-patch"],
		[E_ESM_MARKER.id, "1316"],
		[E_ESM_MARKER.id, "#1316(e)"],
		[E_ESM_MARKER.id, "// pi-patch #1316(e)"],
		[E_BUNDLE_MARKER.id, "pi-patch"],
		[E_BUNDLE_MARKER.id, "1316"],
		[E_BUNDLE_MARKER.id, "#1316(e)"],
		[E_BUNDLE_MARKER.id, "/*pi-patch:#1316(e)*/"],
		[E_ESM_OPTIONS.id, "pi-patch"],
		[E_ESM_OPTIONS.id, "#1316(e)"],
		[E_BUNDLE_OPTIONS.id, "pi-patch"],
		[E_BUNDLE_OPTIONS.id, "/*pi-patch:#1316(e)*/"],
	];
	for (const [id, needle] of markerFragments) {
		const entry = byId.get(id);
		check(
			`MARKER-CLASSIFIER UNIT: "${needle}" is NOT code-shaped in ${id}`,
			entry !== undefined && !isCodeShaped(entry, needle),
			`isCodeShaped=${entry ? isCodeShaped(entry, needle) : "(missing entry)"}`,
		);
	}
	const realCodeNeedles = E_ENTRIES.flatMap((e) => e.verifyPresent.map((n) => [e.id, n]));
	realCodeNeedles.push(
		[E_ESM_OPTIONS.id, "summarizationMaxTokens"],
		[E_ESM_OPTIONS.id, "options?.skipContextClamp"],
		[E_BUNDLE_OPTIONS.id, "?summarizationMaxTokens(model,context"],
	);
	for (const [id, needle] of realCodeNeedles) {
		const entry = byId.get(id);
		check(
			`MARKER-CLASSIFIER UNIT: "${needle}" IS code-shaped in ${id}`,
			entry !== undefined && isCodeShaped(entry, needle),
			`isCodeShaped=${entry ? isCodeShaped(entry, needle) : "(missing entry)"}`,
		);
	}
}

for (const e of E_ENTRIES) {
	const codeShaped = e.verifyPresent.filter((n) => isCodeShaped(e, n));
	check(
		`FALSE-PASS GUARD (non-vacuous): EVERY ${e.id} verifyPresent needle is code-shaped (found in the entry's code, absent from its marker-only rendering)`,
		codeShaped.length === e.verifyPresent.length,
		`code-shaped ${codeShaped.length}/${e.verifyPresent.length}: ${codeShaped.join(" | ") || "(none)"}`,
	);
}

console.log(results.join("\n"));
const summary = REPS.map((rep) => `${rep.label}: pre ${pre[rep.id].clampedBig} → post ${post[rep.id].clampedBig}`).join("; ");
console.log(
	failures === 0
		? `\n✅ (e) VERIFIED — the summarization request keeps its ${EXPECTED_BUDGET}-token budget when the clamp would cut it to ${CLAMPED_TO}, normal turns stay clamped, an un-fittable prompt fails loudly, and all four provider-adapter re-clamp sites are marker-gated (${summary})`
		: `\n❌ (e) FAILED — ${failures} assertion(s)`,
);
process.exit(failures === 0 ? 0 : 1);
