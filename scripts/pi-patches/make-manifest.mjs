#!/usr/bin/env node
// pi-patches manifest generator — derives scripts/pi-patches/manifests/<version>/manifest.json
// from the INSTALLED pi tree, so the `find` strings are byte-exact for that version.
//
// This set carries two changes:
//   (b) the clamp output floor (#1214) — never ask for a single token.
//   (d) the summarization budget floor (#1263) — never ask the update prompt to preserve more
//       than it can emit. The update prompt instructs the model to PRESERVE the entire previous
//       summary, so a budget below that summary's own size is unsatisfiable: the generation runs
//       to the cap, returns stopReason "length", and the partial summary is discarded. The floor
//       is applied ONLY when a previous summary exists, so the initial-summary budget is
//       unchanged; it covers three copies (the ESM, and both inlined copies in the bundle chunk
//       the CLI loads).
// Change (c) (bounding the overflow-recovery latch in agent-session.js) is deliberately NOT in
// this set: it contradicts four upstream tests that encode a one-shot recovery design, and (b)
// alone closes the silent death because with a usable floor the 1-token turn cannot occur.
//
// It fails loudly if any anchor is missing or ambiguous: a manifest that silently matched
// nothing would make apply.sh report "applied" over an unpatched tree — a false PASS.
//
// Usage: node scripts/pi-patches/make-manifest.mjs [--pi-root <dir>] [--out <file>]
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, readdirSync, realpathSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

const args = process.argv.slice(2);
function arg(name, fallback) {
	const i = args.indexOf(name);
	return i === -1 ? fallback : args[i + 1];
}

function resolvePiRoot() {
	const explicit = arg("--pi-root", process.env.PI_ROOT);
	if (explicit) return explicit;
	const candidates = [];
	// <prefix>/bin/pi -> <prefix>/lib/node_modules/@earendil-works/pi-coding-agent
	try {
		const real = realpathSync(execFileSync("bash", ["-lc", "command -v pi"], { encoding: "utf8" }).trim());
		candidates.push(
			join(dirname(dirname(dirname(real))), "lib", "node_modules", "@earendil-works", "pi-coding-agent"),
		);
	} catch {
		/* fall through */
	}
	for (const prefix of ["/Users/danielospina/.local/share/pi-node/node-v22.23.2-darwin-arm64"]) {
		candidates.push(join(prefix, "lib", "node_modules", "@earendil-works", "pi-coding-agent"));
	}
	for (const c of candidates) if (existsSync(join(c, "package.json"))) return c;
	throw new Error("could not locate the installed @earendil-works/pi-coding-agent tree; pass --pi-root");
}

const PI_ROOT = resolvePiRoot();
const AGENT_PKG = join(PI_ROOT, "package.json");
const AI_PKG = join(PI_ROOT, "node_modules", "@earendil-works", "pi-ai", "package.json");
const CODING_VERSION = JSON.parse(readFileSync(AGENT_PKG, "utf8")).version;
const AI_VERSION = JSON.parse(readFileSync(AI_PKG, "utf8")).version;
if (CODING_VERSION !== AI_VERSION) {
	throw new Error(`pi-coding-agent ${CODING_VERSION} and pi-ai ${AI_VERSION} disagree; re-derive before pinning`);
}

const BUNDLE = join(PI_ROOT, "dist", "bundle", "chunks");

// ---- (b) output floor -------------------------------------------------------------------
const CLAMP_ESM_FIND = [
	"const CONTEXT_SAFETY_TOKENS = 4096;",
	"const MIN_MAX_TOKENS = 1;",
	"export function clampMaxTokensToContext(model, context, maxTokens) {",
	"    if (model.contextWindow <= 0)",
	"        return Math.max(MIN_MAX_TOKENS, maxTokens);",
	"    const available = model.contextWindow - estimateContextTokens(context).tokens - CONTEXT_SAFETY_TOKENS;",
	"    return Math.min(maxTokens, Math.max(MIN_MAX_TOKENS, available));",
	"}",
].join("\n");

const CLAMP_ESM_REPLACE = [
	"const CONTEXT_SAFETY_TOKENS = 4096;",
	"const MIN_MAX_TOKENS = 1;",
	"// pi-patch #1214(b): never clamp below a usable output budget. Asking for a single token",
	"// turns \"no output budget left\" into stopReason \"length\" with output 1 - a turn that looks",
	"// normal and leaves the session unable to ever reply again. Ask for a usable floor instead",
	"// and let the provider reject a request that is genuinely over its limit (loud, and the",
	"// overflow path already handles it) rather than dying silently.",
	"const MIN_USABLE_MAX_TOKENS = 1024;",
	"export function clampMaxTokensToContext(model, context, maxTokens) {",
	"    if (model.contextWindow <= 0)",
	"        return Math.max(MIN_MAX_TOKENS, maxTokens);",
	"    const available = model.contextWindow - estimateContextTokens(context).tokens - CONTEXT_SAFETY_TOKENS;",
	"    if (available < MIN_USABLE_MAX_TOKENS)",
	"        return Math.max(MIN_MAX_TOKENS, Math.min(maxTokens, MIN_USABLE_MAX_TOKENS));",
	"    return Math.min(maxTokens, available);",
	"}",
].join("\n");

const CLAMP_BUNDLE_FIND =
	'var CONTEXT_SAFETY_TOKENS=4096,MIN_MAX_TOKENS=1;function clampMaxTokensToContext(model,context,maxTokens){if(model.contextWindow<=0)return Math.max(MIN_MAX_TOKENS,maxTokens);let available=model.contextWindow-estimateContextTokens(context).tokens-CONTEXT_SAFETY_TOKENS;return Math.min(maxTokens,Math.max(MIN_MAX_TOKENS,available))}';

const CLAMP_BUNDLE_REPLACE =
	'var CONTEXT_SAFETY_TOKENS=4096,MIN_MAX_TOKENS=1,MIN_USABLE_MAX_TOKENS=1024;function clampMaxTokensToContext(model,context,maxTokens){/*pi-patch:#1214(b)*/if(model.contextWindow<=0)return Math.max(MIN_MAX_TOKENS,maxTokens);let available=model.contextWindow-estimateContextTokens(context).tokens-CONTEXT_SAFETY_TOKENS;return available<MIN_USABLE_MAX_TOKENS?Math.max(MIN_MAX_TOKENS,Math.min(maxTokens,MIN_USABLE_MAX_TOKENS)):Math.min(maxTokens,available)}';

// ---- (d) summarization budget floor (#1263) ----------------------------------------------
// The update-summarization prompt tells the model to PRESERVE the entire previous summary, so a
// budget below that summary's own size can never be satisfied: the generation runs to the cap,
// comes back stopReason "length", and getSummarizationFailure() throws the partial summary away
// and fails the whole compaction — which then fails identically on the overflow path, so the
// session can never compact again. Floor the budget at the size of the summary it must preserve,
// bounded by the model's own ceiling. An upper bound costs nothing unless the model emits it.
const SUMMARIZATION_BUDGET_ESM_FIND =
	"    const maxTokens = Math.min(Math.floor(0.8 * reserveTokens), model.maxTokens > 0 ? model.maxTokens : Number.POSITIVE_INFINITY);";

const SUMMARIZATION_BUDGET_ESM_REPLACE = [
	"    // pi-patch #1263(d): the update prompt (UPDATE_SUMMARIZATION_PROMPT) instructs the model to",
	"    // PRESERVE the previous summary, so a budget below that summary's own size is unsatisfiable:",
	'    // the generation runs to the cap, returns stopReason "length", and getSummarizationFailure()',
	"    // discards the partial summary and fails the whole compaction - which then fails identically",
	"    // on the overflow path, so the session can never compact again. Measured on this fleet when",
	"    // reserveTokens was 16384 (cap 13,107) against a 56,077-char previous summary (13,452 output",
	"    // tokens): 21 session files were over the cap. Floor the budget at what we are asking it to",
	"    // preserve. An upper bound costs nothing unless the model actually emits it. chars/2 is a",
	"    // deliberately conservative token estimate: pi's own estimateTextTokens uses chars/4, and the",
	"    // densest summary measured on this fleet is 3.19 chars per summary token (81,542 chars / 25,534",
	"    // output tokens net of reasoning) - so chars/2 over-estimates the summary's own token count.",
	"    const modelCeiling = model.maxTokens > 0 ? model.maxTokens : Number.POSITIVE_INFINITY;",
	"    const summaryCap = Math.min(Math.floor(0.8 * reserveTokens), modelCeiling);",
	"    const priorTokens = previousSummary ? Math.ceil(previousSummary.length / 2) : 0;",
	"    // Applied ONLY when there IS a previous summary to preserve. With none, the budget stays",
	"    // exactly min(floor(0.8 * reserveTokens), model.maxTokens), so the initial-summary path is",
	"    // provably unchanged — a residual the VGATE verifier proved for the unconditional form.",
	"    const maxTokens = previousSummary ? Math.max(summaryCap, Math.min(priorTokens + 4096, modelCeiling)) : summaryCap;",
].join("\n");

// The bundle copy sits INSIDE the existing `let a=..., b=...` comma chain: the replacement must
// introduce no semicolon before `,basePrompt`. The find string therefore starts at `let` and ends
// before the comma, and the replacement re-declares the same single `let` statement.
const SUMMARIZATION_BUDGET_BUNDLE_FIND =
	"let maxTokens=Math.min(Math.floor(.8*reserveTokens),model.maxTokens>0?model.maxTokens:Number.POSITIVE_INFINITY)";

const SUMMARIZATION_BUDGET_BUNDLE_REPLACE =
	"/*pi-patch:#1263(d)*/let modelCeiling=model.maxTokens>0?model.maxTokens:Number.POSITIVE_INFINITY,summaryCap=Math.min(Math.floor(.8*reserveTokens),modelCeiling),priorTokens=previousSummary?Math.ceil(previousSummary.length/2):0,maxTokens=previousSummary?Math.max(summaryCap,Math.min(priorTokens+4096,modelCeiling)):summaryCap";

// A SECOND, independent copy of the same computation is inlined in the same bundle chunk as
// `generateSummaryWithRequest` (the pi-agent-core facade, bundled). It is not reachable from pi's
// own auto-compaction paths — `generateSummaryWithUsage2` has no live caller — but an SDK or
// extension consumer importing pi-agent-core's `compact` would reach it, so it carries the same
// floor rather than leaving a copy that can still fail. Its anchor is disambiguated by the
// destructuring that precedes it: the other copy declares `let maxTokens=...`, this one continues
// an existing `let {…}=options,` chain.
const SUMMARIZATION_BUDGET_REQUEST_FIND =
	"previousSummary,thinkingLevel}=options,maxTokens=Math.min(Math.floor(.8*reserveTokens),model.maxTokens>0?model.maxTokens:Number.POSITIVE_INFINITY)";

const SUMMARIZATION_BUDGET_REQUEST_REPLACE =
	"previousSummary,thinkingLevel}=options,/*pi-patch:#1263(d)*/modelCeiling=model.maxTokens>0?model.maxTokens:Number.POSITIVE_INFINITY,summaryCap=Math.min(Math.floor(.8*reserveTokens),modelCeiling),priorTokens=previousSummary?Math.ceil(previousSummary.length/2):0,maxTokens=previousSummary?Math.max(summaryCap,Math.min(priorTokens+4096,modelCeiling)):summaryCap";

const entries = [
	// (b) the clamp — one copy in the unbundled ESM, one inlined copy per bundle chunk.
	{
		id: "b1-clamp-floor-esm",
		change: "b",
		file: "node_modules/@earendil-works/pi-ai/dist/api/simple-options.js",
		find: CLAMP_ESM_FIND,
		replace: CLAMP_ESM_REPLACE,
		verifyPresent: ["const MIN_USABLE_MAX_TOKENS = 1024;", "if (available < MIN_USABLE_MAX_TOKENS)"],
	},
	{
		id: "b2-clamp-floor-bundle-http",
		change: "b",
		file: "dist/bundle/chunks/chunk-AXIIZGTV.js",
		find: CLAMP_BUNDLE_FIND,
		replace: CLAMP_BUNDLE_REPLACE,
		verifyPresent: ["MIN_USABLE_MAX_TOKENS=1024", "available<MIN_USABLE_MAX_TOKENS?"],
	},
	{
		id: "b3-clamp-floor-bundle-bedrock",
		change: "b",
		file: "dist/bundle/chunks/bedrock-converse-stream.js",
		find: CLAMP_BUNDLE_FIND,
		replace: CLAMP_BUNDLE_REPLACE,
		verifyPresent: ["MIN_USABLE_MAX_TOKENS=1024", "available<MIN_USABLE_MAX_TOKENS?"],
	},
	// (d) the summarization budget floor — the unbundled ESM copy, and the inlined copy in the
	// bundle chunk the running CLI actually loads (#1263).
	{
		id: "d1-summarization-budget-esm",
		change: "d",
		file: "dist/core/compaction/compaction.js",
		find: SUMMARIZATION_BUDGET_ESM_FIND,
		replace: SUMMARIZATION_BUDGET_ESM_REPLACE,
		// CODE-shaped needles, never the marker comment. With a marker-only needle, a tree where the
		// comment survived and the floor was reverted read as "already applied": `apply.sh --check`
		// exited 0 over an unpatched tree. That is a false PASS, and it was found by the VGATE
		// verifier — the marker is provenance, not evidence the code is installed.
		verifyPresent: ["maxTokens = previousSummary ? Math.max(summaryCap", "const priorTokens = previousSummary"],
	},
	{
		id: "d2-summarization-budget-bundle",
		change: "d",
		file: "dist/bundle/chunks/chunk-JVUZSMYM.js",
		find: SUMMARIZATION_BUDGET_BUNDLE_FIND,
		replace: SUMMARIZATION_BUDGET_BUNDLE_REPLACE,
		verifyPresent: ["maxTokens=previousSummary?Math.max(summaryCap", "/*pi-patch:#1263(d)*/let modelCeiling="],
	},
	{
		id: "d3-summarization-budget-bundle-request",
		change: "d",
		file: "dist/bundle/chunks/chunk-JVUZSMYM.js",
		find: SUMMARIZATION_BUDGET_REQUEST_FIND,
		replace: SUMMARIZATION_BUDGET_REQUEST_REPLACE,
		verifyPresent: ["thinkingLevel}=options,/*pi-patch:#1263(d)*/modelCeiling=", "maxTokens=previousSummary?Math.max(summaryCap"],
	},
];

// Resolve every anchor against the installed tree; refuse to emit a manifest that does not match.
//
// A tree that is ALREADY PATCHED has no pristine anchors left, and that is not a reason to refuse:
// re-deriving from a patched install is exactly what you do when you want to reproduce the patch
// elsewhere or record what is in place. So an entry is satisfied by EITHER the pristine anchor
// appearing exactly once OR the patched form already being present. The false-manifest guard is
// preserved, because a file that is NEITHER pristine NOR patched still fails — which is the case
// that matters (a version bump that moved or deleted the code).
const problems = [];
let alreadyPatched = 0;
for (const entry of entries) {
	const abs = join(PI_ROOT, entry.file);
	if (!existsSync(abs)) {
		problems.push(`${entry.id}: missing file ${entry.file}`);
		continue;
	}
	const text = readFileSync(abs, "utf8");
	const count = text.split(entry.find).length - 1;
	if (count === 1) continue;
	// The "already patched" decision verifies the patched REGION verbatim, never scattered
	// substring needles: a comment that merely QUOTES the needles satisfies a substring test, so a
	// needle-based proof would emit a manifest over a tree with no patched code (#1263 review,
	// adversarial finding 2 — the same hardening `apply.mjs` carries).
	const patched =
		entry.patched !== undefined
			? text.includes(entry.patched)
			: entry.replace !== undefined && text.includes(entry.replace);
	if (patched) {
		alreadyPatched += 1;
		continue;
	}
	problems.push(`${entry.id}: anchor matched ${count} times in ${entry.file} (expected exactly 1)`);
}
if (problems.length > 0) {
	console.error("FATAL: the installed pi tree does not match this patch set — refusing to emit a manifest.");
	for (const p of problems) console.error(`  - ${p}`);
	process.exit(2);
}

const manifest = {
	schema: 1,
	issue: "#1214",
	writtenAgainst: { "pi-coding-agent": CODING_VERSION, "pi-ai": AI_VERSION },
	note:
		"Derived by scripts/pi-patches/make-manifest.mjs from the installed tree. Re-derive (do not hand-edit) after a pi upgrade, then re-run the verification suite.",
	entries,
};

const out = arg("--out", join(import.meta.dirname, "manifests", `${CODING_VERSION}`, "manifest.json"));
mkdirSync(dirname(out), { recursive: true });
writeFileSync(out, `${JSON.stringify(manifest, null, 2)}\n`);
console.log(`wrote ${out}`);
console.log(`  pi-coding-agent ${CODING_VERSION} / pi-ai ${AI_VERSION} — ${entries.length} replacements`);
if (alreadyPatched > 0) {
	console.log(
		`  note: ${alreadyPatched}/${entries.length} anchors were ALREADY in their patched form (this tree is patched); the manifest still carries the pristine anchor for each, so it applies correctly to an unpatched tree.`,
	);
}
console.log(`  manifest sha256 ${createHash("sha256").update(readFileSync(out)).digest("hex").slice(0, 16)}`);

// Stale version directories are KEPT ON PURPOSE. `apply.mjs` selects the manifest by matching the
// installed pi version against `writtenAgainst`, so a second directory is the normal post-upgrade
// state and cannot confuse it. The old manifest is also the only thing that can still apply or
// revert this patch set on an install that has not yet upgraded — deleting it would strand that
// install. So this generator never prunes; it only says what it left behind.
const manifestRoot = dirname(dirname(out));
const kept = readdirSync(manifestRoot, { withFileTypes: true })
	.filter((d) => d.isDirectory() && d.name !== CODING_VERSION)
	.map((d) => d.name)
	.sort();
if (kept.length > 0) {
	console.log(
		`  note: keeping ${kept.length} other version directory(ies): ${kept.join(", ")} — apply.mjs selects by the INSTALLED version, so they are harmless, and they are the only way to apply or revert this patch set on those installs. Delete one only if you are sure no install still needs it.`,
	);
}
