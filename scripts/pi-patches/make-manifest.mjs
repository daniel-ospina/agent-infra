#!/usr/bin/env node
// pi-patches manifest generator — derives scripts/pi-patches/manifests/<version>/manifest.json
// from the INSTALLED pi tree, so the `find` strings are byte-exact for that version.
//
// It fails loudly if any anchor is missing or ambiguous: a manifest that silently matched
// nothing would make apply.sh report "applied" over an unpatched tree — a false PASS.
//
// Usage: node scripts/pi-patches/make-manifest.mjs [--pi-root <dir>] [--out <file>]
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
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

// ---- (c) bounded overflow recovery ------------------------------------------------------
const SESS_ERROR_FIND = [
	"            if (this._overflowRecoveryAttempted) {",
	"                const errorMessage = contextOverflow",
	'                    ? "Context overflow recovery failed after one compact-and-retry attempt. Try reducing context or switching to a larger-context model."',
	'                    : "Truncated response recovery failed after one compact-and-retry attempt.";',
].join("\n");

const SESS_ERROR_REPLACE = [
	"            if (this._overflowRecoveryAttempt >= 3) {",
	"                const errorMessage = contextOverflow",
	'                    ? "Context overflow recovery failed after 3 compact-and-retry attempts. Try reducing context or switching to a larger-context model."',
	'                    : "Truncated response recovery failed after 3 compact-and-retry attempts.";',
].join("\n");

const BUNDLE_ERROR_FIND =
	'if(this._overflowRecoveryAttempted){let errorMessage2=contextOverflow?"Context overflow recovery failed after one compact-and-retry attempt. Try reducing context or switching to a larger-context model.":"Truncated response recovery failed after one compact-and-retry attempt.";';

const BUNDLE_ERROR_REPLACE =
	'if(this._overflowRecoveryAttempt>=3){/*pi-patch:#1214(c)*/let errorMessage2=contextOverflow?"Context overflow recovery failed after 3 compact-and-retry attempts. Try reducing context or switching to a larger-context model.":"Truncated response recovery failed after 3 compact-and-retry attempts.";';

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
	// (c) the recovery latch -> bounded attempt counter, in both representations.
	{
		id: "c1-recovery-field-esm",
		change: "c",
		file: "dist/core/agent-session.js",
		find: "    _autoCompactionAbortController = undefined;\n    _overflowRecoveryAttempted = false;\n",
		replace:
			"    _autoCompactionAbortController = undefined;\n    // pi-patch #1214(c): a COUNT, not a latch. As a boolean this was never cleared by a\n    // `length` stop, so the one compact-and-retry a session was allowed could not be re-armed.\n    _overflowRecoveryAttempt = 0;\n",
		verifyPresent: ["    _overflowRecoveryAttempt = 0;"],
	},
	{
		id: "c2-recovery-reset-user-esm",
		change: "c",
		file: "dist/core/agent-session.js",
		find: '        if (event.type === "message_start" && event.message.role === "user") {\n            this._overflowRecoveryAttempted = false;\n',
		replace:
			'        if (event.type === "message_start" && event.message.role === "user") {\n            this._overflowRecoveryAttempt = 0;\n',
		verifyPresent: ["            this._overflowRecoveryAttempt = 0;"],
	},
	{
		id: "c3-recovery-reset-success-esm",
		change: "c",
		file: "dist/core/agent-session.js",
		find: '                if (assistantMsg.stopReason !== "error" && assistantMsg.stopReason !== "length") {\n                    this._overflowRecoveryAttempted = false;\n                }',
		replace:
			'                if (assistantMsg.stopReason !== "error" && assistantMsg.stopReason !== "length") {\n                    this._overflowRecoveryAttempt = 0;\n                }',
		verifyPresent: ["                    this._overflowRecoveryAttempt = 0;"],
	},
	{
		id: "c4-recovery-cap-esm",
		change: "c",
		file: "dist/core/agent-session.js",
		find: SESS_ERROR_FIND,
		replace: SESS_ERROR_REPLACE,
		verifyPresent: ["if (this._overflowRecoveryAttempt >= 3) {"],
	},
	{
		id: "c5-recovery-increment-esm",
		change: "c",
		file: "dist/core/agent-session.js",
		find: "            // retry once. The message remains in session history but is excluded from retry context.\n            this._overflowRecoveryAttempted = true;",
		replace:
			"            // retry. The message remains in session history but is excluded from retry context.\n            // Bounded by the attempt cap above (#1214(c)).\n            this._overflowRecoveryAttempt++;",
		verifyPresent: ["            this._overflowRecoveryAttempt++;"],
	},
	{
		id: "c6-recovery-field-bundle",
		change: "c",
		file: "dist/bundle/chunks/chunk-JVUZSMYM.js",
		find: "_autoCompactionAbortController=void 0;_overflowRecoveryAttempted=!1;_branchSummaryAbortController",
		replace: "_autoCompactionAbortController=void 0;_overflowRecoveryAttempt=0;_branchSummaryAbortController",
		verifyPresent: ["_autoCompactionAbortController=void 0;_overflowRecoveryAttempt=0;"],
	},
	{
		id: "c7-recovery-reset-user-bundle",
		change: "c",
		file: "dist/bundle/chunks/chunk-JVUZSMYM.js",
		find: "this._overflowRecoveryAttempted=!1;let messageText",
		replace: "this._overflowRecoveryAttempt=0;let messageText",
		verifyPresent: ["this._overflowRecoveryAttempt=0;let messageText"],
	},
	{
		id: "c8-recovery-reset-success-bundle",
		change: "c",
		file: "dist/bundle/chunks/chunk-JVUZSMYM.js",
		find: "&&(this._overflowRecoveryAttempted=!1),assistantMsg",
		replace: "&&(this._overflowRecoveryAttempt=0),assistantMsg",
		verifyPresent: ["&&(this._overflowRecoveryAttempt=0),assistantMsg"],
	},
	{
		id: "c9-recovery-cap-bundle",
		change: "c",
		file: "dist/bundle/chunks/chunk-JVUZSMYM.js",
		find: BUNDLE_ERROR_FIND,
		replace: BUNDLE_ERROR_REPLACE,
		verifyPresent: ["if(this._overflowRecoveryAttempt>=3)"],
	},
	{
		id: "c10-recovery-increment-bundle",
		change: "c",
		file: "dist/bundle/chunks/chunk-JVUZSMYM.js",
		find: "!1}this._overflowRecoveryAttempted=!0;let messages=this.agent.state.messages",
		replace: "!1}this._overflowRecoveryAttempt++;let messages=this.agent.state.messages",
		verifyPresent: ["!1}this._overflowRecoveryAttempt++;let messages="],
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
	const patched =
		entry.patched !== undefined
			? text.includes(entry.patched)
			: (entry.verifyPresent ?? []).length > 0 && entry.verifyPresent.every((v) => text.includes(v));
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
