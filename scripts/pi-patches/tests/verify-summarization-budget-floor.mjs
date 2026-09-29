#!/usr/bin/env node
// verify-summarization-budget-floor.mjs — change (d) of #1263, proved end to end:
// "The summarization request must never ask for LESS output than the previous summary it is
//  being told to preserve."
//
// The update prompt (`UPDATE_SUMMARIZATION_PROMPT`) instructs the model to PRESERVE the whole
// previous summary. The old budget was a flat `floor(0.8 * reserveTokens)`; when the previous
// summary was larger than that, the generation ran to the cap, came back `stopReason: "length"`,
// `getSummarizationFailure()` discarded the partial summary and the whole compaction failed —
// then failed identically on the overflow path, so the session could never compact again.
//
// This test drives the REAL code path (`generateSummaryWithUsage`) with a stub `streamFn` that
// records the options it is called with, and asserts the budget HANDED TO THE STREAM FUNCTION —
// the PRE-CLAMP value. The real clamp (`clampMaxTokensToContext`) runs later, inside
// `buildBaseOptions`, so this probe never exercises it (README §(e) — the residual (d) left open,
// since closed by change (e)); it observes what the
// summarizer asks for, not what a provider finally receives. It is
// hermetic: it builds its own pristine tree and its own patched tree by copying the INSTALLED
// `dist/` into a temp dir (with a symlinked `node_modules`), then reverting / applying the exact
// manifest anchors. The installed tree is never modified.
//
// Both legs are required:
//   RED  — the unpatched code must produce the old cap exactly (13,107), and the green assertion
//          must be FALSE against it. A test that passes because it could not observe the
//          condition is forbidden: "no-repro → green" is explicitly unacceptable.
//   GREEN — the patched code must produce a budget at least the size of the summary it must
//          preserve (and not the old cap).
//
// It also runs `apply.sh --check` against trees the check must reject: the PRISTINE temp tree
// (anchors present → "(d) NOT applied", exit 1), a MARKER-ONLY tree per (d) entry (patched code
// gone, marker kept, no pristine anchor → the neither-pristine-nor-patched refusal, exit 2), and a
// QUOTED-NEEDLE tree (the needles survive only inside a comment → the same refusal, never
// "already applied"). The check must never claim the fix is present when it is not.
//
// Run: NODE_ENV=test node scripts/pi-patches/tests/verify-summarization-budget-floor.mjs
import { spawnSync } from "node:child_process";
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
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
const D_ENTRIES = manifest.entries.filter((e) => e.change === "d");
const D_ESM = D_ENTRIES.find((e) => e.id === "d1-summarization-budget-esm");
const D_BUNDLE = D_ENTRIES.find((e) => e.id === "d2-summarization-budget-bundle");
if (!D_ESM || !D_BUNDLE) {
	throw new Error(
		`the manifest is missing a change-(d) entry (d1-summarization-budget-esm / d2-summarization-budget-bundle); found: ${D_ENTRIES.map((e) => e.id).join(", ") || "(none)"}`,
	);
}

// The real measured regime from #1263: reserveTokens 16384 ⇒ old cap floor(0.8 × 16384) = 13,107,
// against a 56,077-char previous summary (≈13,452 output tokens as measured).
const RESERVE_TOKENS = 16_384;
const OLD_CAP = 13_107;
const PREVIOUS_SUMMARY = "x".repeat(56_077);
const PRIOR_TOKENS = Math.ceil(PREVIOUS_SUMMARY.length / 2);
const MODEL = {
	id: "deepseek-flash",
	provider: "deepseek",
	api: "openai-completions",
	contextWindow: 300_000,
	maxTokens: 384_000,
};

// The assertion the GREEN leg must satisfy when the budget must preserve this previous summary.
const GREEN_ASSERTION = (maxTokens) => maxTokens >= PRIOR_TOKENS && maxTokens !== OLD_CAP;

const results = [];
let failures = 0;
function check(name, ok, detail = "") {
	results.push(`${ok ? "  ✅" : "  ❌"} ${name}${detail ? `  — ${detail}` : ""}`);
	if (!ok) failures++;
}

const TMP = mkdtempSync(join(tmpdir(), "pi-patch-d-"));
process.on("exit", () => rmSync(TMP, { recursive: true, force: true }));

/** A copy of the installed tree's `dist/` (plus package.json and a symlinked node_modules). */
function buildTree(label) {
	const root = join(TMP, label);
	mkdirSync(root, { recursive: true });
	cpSync(join(PI_ROOT, "dist"), join(root, "dist"), { recursive: true });
	cpSync(join(PI_ROOT, "package.json"), join(root, "package.json"));
	symlinkSync(join(PI_ROOT, "node_modules"), join(root, "node_modules"), "dir");
	return root;
}

/**
 * Force the (d) files into their PRISTINE (unpatched) shape. Works whether the installed tree we
 * copied was already patched or not, so the RED leg can never silently become a green tree.
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

/** Drive the REAL `generateSummaryWithUsage` and return the `maxTokens` the provider was asked for. */
async function observeMaxTokens(root, label, previousSummary, reserveTokens = RESERVE_TOKENS) {
	const mod = await import(pathToFileURL(join(root, "dist", "core", "compaction", "compaction.js")).href);
	let recorded;
	const streamFn = (model, context, options) => {
		recorded = options;
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
	await mod.generateSummaryWithUsage(
		[],
		MODEL,
		reserveTokens,
		"probe-key",
		{},
		undefined,
		undefined,
		previousSummary,
		undefined,
		streamFn,
		{},
		undefined,
		undefined,
		undefined,
	);
	if (!recorded || typeof recorded.maxTokens !== "number") {
		throw new Error(`${label}: the streamFn was never reached (or carried no maxTokens) — the probe cannot observe the condition, so it must not report success`);
	}
	return recorded.maxTokens;
}

console.log("VERIFY (d) — the summarization budget never sits below the summary it must preserve");
console.log(`  pi root:  ${PI_ROOT}`);
console.log(`  manifest: ${MANIFEST_PATH}`);
console.log(`  reserveTokens ${RESERVE_TOKENS} → old cap ${OLD_CAP}; previous summary ${PREVIOUS_SUMMARY.length} chars → ${PRIOR_TOKENS} tokens (chars/2 estimate)\n`);

const redRoot = buildTree("pristine");
revertToPristine(redRoot, D_ENTRIES);
const greenRoot = buildTree("patched");
revertToPristine(greenRoot, D_ENTRIES);
applyEntries(greenRoot, D_ENTRIES);

// ── Preconditions: the two trees really are pristine / patched, in BOTH representations ─────
for (const [label, root, wantPatched] of [
	["pristine", redRoot, false],
	["patched", greenRoot, true],
]) {
	for (const e of D_ENTRIES) {
		const text = readFileSync(join(root, e.file), "utf8");
		const hasFind = text.includes(e.find);
		const hasReplace = text.includes(e.replace);
		check(
			`${label}: ${e.id} is ${wantPatched ? "PATCHED" : "PRISTINE"} in both shape checks`,
			wantPatched ? !hasFind && hasReplace : hasFind && !hasReplace,
			`find=${hasFind} replace=${hasReplace}`,
		);
	}
}

// ── RED: the unpatched code must collapse to the old cap, and the green assertion must FAIL ──
const redMaxTokens = await observeMaxTokens(redRoot, "pristine", PREVIOUS_SUMMARY);
check("RED: the UNPATCHED summarization budget is exactly the old cap", redMaxTokens === OLD_CAP, `recorded maxTokens=${redMaxTokens}`);
check(
	"RED: the green assertion FAILS against the unpatched code (it is not vacuously passing)",
	GREEN_ASSERTION(redMaxTokens) === false,
	`GREEN_ASSERTION(${redMaxTokens}) = ${GREEN_ASSERTION(redMaxTokens)}`,
);

// ── `apply.sh --check` on the pristine tree must report (d) ABSENT and exit 1 ────────────────
const checkRun = spawnSync("bash", [APPLY_SH, "--check"], {
	encoding: "utf8",
	env: { ...process.env, PI_ROOT: redRoot, NODE_ENV: "test" },
});
const checkOut = `${checkRun.stdout ?? ""}${checkRun.stderr ?? ""}`;
console.log(`\n  RAW apply.sh --check OUTPUT (PI_ROOT=<pristine temp tree>), exit ${checkRun.status}:\n`);
console.log(checkOut.split("\n").map((l) => `  | ${l}`).join("\n"));
check("--check on the pristine tree exits 1 (not applied)", checkRun.status === 1, `exit=${checkRun.status}`);
for (const id of D_ENTRIES.map((e) => e.id)) {
	check(`--check reports ${id} as NOT applied`, checkOut.includes(id) && /NOT applied/.test(checkOut), "");
}
check("--check does NOT claim the fix is in place", !checkOut.includes("the fix is in place"), "");

// ── GREEN: the patched code must satisfy the assertion ───────────────────────────────────────
const greenMaxTokens = await observeMaxTokens(greenRoot, "patched", PREVIOUS_SUMMARY);
check(
	"GREEN: the summarization budget PRESERVES the previous summary (>= its own estimate)",
	greenMaxTokens >= PRIOR_TOKENS,
	`recorded maxTokens=${greenMaxTokens} vs prior ${PRIOR_TOKENS}`,
);
check("GREEN: the summarization budget is NOT the old cap", greenMaxTokens !== OLD_CAP, `recorded maxTokens=${greenMaxTokens}`);
check("GREEN: the green assertion holds", GREEN_ASSERTION(greenMaxTokens) === true, `GREEN_ASSERTION(${greenMaxTokens}) = true`);
check(
	"GREEN: the budget exceeded the old cap rather than merely matching it",
	greenMaxTokens > redMaxTokens,
	`patched ${greenMaxTokens} > pristine ${redMaxTokens}`,
);

// The bundle anchor sits inside a comma chain, so a misplaced semicolon would be a syntax error
// rather than a wrong number. Parse BOTH patched files with node to prove the payload is valid JS.
for (const e of D_ENTRIES) {
	const file = join(greenRoot, e.file);
	const parsed = spawnSync(process.execPath, ["--check", file], { encoding: "utf8" });
	check(
		`GREEN: the patched ${e.id} still parses as JavaScript`,
		parsed.status === 0,
		`node --check exit=${parsed.status}${parsed.stderr ? `: ${parsed.stderr.trim()}` : ""}`,
	);
}

// ── The floor must NOT leak into the initial-summary path (no previous summary) ────────────
// The VGATE verifier found that the UNCONDITIONAL form moved this budget whenever
// floor(0.8 * reserveTokens) < 4096 (i.e. reserveTokens < 5120): `max(summaryCap, 4096)`. The
// budget is only ever raised, so it was never a death risk — but it is a real behaviour change
// this patch must not have, so the two trees are compared directly, at the shipped reserve AND at
// a small one that exposes the divergence.
for (const reserve of [RESERVE_TOKENS, 2048]) {
	const red = await observeMaxTokens(redRoot, `pristine/no-prev@${reserve}`, undefined, reserve);
	const green = await observeMaxTokens(greenRoot, `patched/no-prev@${reserve}`, undefined, reserve);
	check(
		`NO-PREVIOUS-SUMMARY: budget unchanged at reserveTokens=${reserve} (pristine == patched)`,
		red === green,
		`pristine=${red} patched=${green}`,
	);
}

// ── False-PASS guard: the provenance marker is NOT evidence that the floor is installed ──────
// `verifyPresent` must be CODE-shaped, and "code-shaped" must mean something falsifiable: a needle
// is code-shaped IFF it does NOT appear in the marker-only rendering of its OWN payload. The
// earlier predicate stripped only the two EXACT marker spellings, so a FRAGMENT of the marker
// ("pi-patch", "1263", "#1263(d)") survived the strip, was classified code-shaped, and was
// present on a marker-only stub — passing both assertions vacuously (#1314 review). This extracts
// the provenance marker comment and asks whether the needle survives its removal.
const MARKER_RE = /(\/\/\s*pi-patch[^\n]*|\/\*\s*pi-patch[^*]*\*\/)/g;
const markerStub = (s) => (s.match(MARKER_RE) || []).join("\n");
const isCodeShaped = (entry, needle) => !markerStub(entry.replace).includes(needle);

// Fixture, parameterized over EVERY (d) entry: a fully-patched tree with THAT entry's payload
// replaced by its marker-only stub — patched code GONE, provenance marker KEPT, pristine anchor
// ABSENT. `--check` must refuse the tree (it is neither pristine nor patched), must never report
// the entry as applied, and must never print the in-place message. The file is rebuilt from the
// pristine copy on every iteration, so entries that share a file (d2/d3) cannot contaminate one
// another.
for (const e of D_ENTRIES) {
	const markerOnlyRoot = buildTree(`marker-only-${e.id}`);
	revertToPristine(markerOnlyRoot, D_ENTRIES);
	applyEntries(markerOnlyRoot, D_ENTRIES);
	const file = join(markerOnlyRoot, e.file);
	let text = readFileSync(file, "utf8");
	const before = text.split(e.replace).length - 1;
	if (before !== 1) {
		throw new Error(`marker-only fixture for ${e.id}: expected its patched payload exactly once in ${e.file}, found ${before}`);
	}
	// The TRUE false-PASS shape: patched code gone, provenance marker retained, NO pristine anchor.
	text = text.replace(e.replace, markerStub(e.replace));
	writeFileSync(file, text);
	const markerOnly = readFileSync(file, "utf8");
	check(
		`FALSE-PASS FIXTURE (${e.id}): the marker is present, that entry's floor code is gone, and its pristine anchor is ABSENT`,
		markerOnly.includes(markerStub(e.replace)) && !markerOnly.includes(e.replace) && !markerOnly.includes(e.find),
		`marker=${markerOnly.includes(markerStub(e.replace))} floor=${!markerOnly.includes(e.replace)} pristineAnchor=${markerOnly.includes(e.find)}`,
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

// ── Scattered-substring guard: quoting the needles in a comment is NOT the fix ───────────────
// Even code-shaped needles are only a diagnostic. The old "already applied" branch was
// `entry.verifyPresent.every(n => next.includes(n))` — a substring test over the whole file — so a
// comment that merely QUOTES the needles read as applied and `--check` exited 0 over a tree whose
// floor code was gone. The decision now requires the entry's OWN replacement payload verbatim,
// which a comment cannot supply. Same per-entry parameterization and fresh-tree-per-iteration rule.
for (const e of D_ENTRIES) {
	const quotedRoot = buildTree(`quoted-needles-${e.id}`);
	revertToPristine(quotedRoot, D_ENTRIES);
	applyEntries(quotedRoot, D_ENTRIES);
	const file = join(quotedRoot, e.file);
	let text = readFileSync(file, "utf8");
	const before = text.split(e.replace).length - 1;
	if (before !== 1) {
		throw new Error(`quoted-needle fixture for ${e.id}: expected its patched payload exactly once in ${e.file}, found ${before}`);
	}
	// A comment that quotes every needle while containing none of the floor code.
	text = text.replace(e.replace, `// quoted needles: ${e.verifyPresent.join(" ")}\n`);
	writeFileSync(file, text);
	const quoted = readFileSync(file, "utf8");
	check(
		`SCATTERED-SUBSTRING FIXTURE (${e.id}): every verifyPresent needle is quoted in a comment while the floor code is gone`,
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

// ── The needles themselves are the guard — this is what makes the assertions non-vacuous ─────
// A direct unit table over the classifier, so the predicate ITSELF is falsifiable: every known
// FRAGMENT of the provenance marker must classify as NOT code-shaped, and every real code needle
// must classify as code-shaped. The old predicate failed the fragment rows ("pi-patch" was called
// code-shaped) — that is exactly how the marker-only bypass was reproduced.
{
	const byId = new Map(D_ENTRIES.map((e) => [e.id, e]));
	const markerFragments = [
		[D_ESM.id, "pi-patch"],
		[D_ESM.id, "1263"],
		[D_ESM.id, "#1263(d)"],
		[D_ESM.id, "1263(d)"],
		[D_ESM.id, "// pi-patch #1263(d)"],
		[D_BUNDLE.id, "pi-patch"],
		[D_BUNDLE.id, "1263"],
		[D_BUNDLE.id, "#1263(d)"],
		[D_BUNDLE.id, "1263(d)"],
		[D_BUNDLE.id, "/*pi-patch:#1263(d)*/"],
	];
	for (const [id, needle] of markerFragments) {
		const entry = byId.get(id);
		check(
			`MARKER-CLASSIFIER UNIT: "${needle}" is NOT code-shaped in ${id}`,
			entry !== undefined && !isCodeShaped(entry, needle),
			`isCodeShaped=${entry ? isCodeShaped(entry, needle) : "(missing entry)"}`,
		);
	}
	const realCodeNeedles = D_ENTRIES.flatMap((e) => e.verifyPresent.map((n) => [e.id, n]));
	realCodeNeedles.push(
		[D_ESM.id, "summaryCap"],
		[D_ESM.id, "priorTokens"],
		[D_BUNDLE.id, "Math.ceil(previousSummary.length/2)"],
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

for (const e of D_ENTRIES) {
	const codeShaped = e.verifyPresent.filter((n) => isCodeShaped(e, n));
	check(
		`FALSE-PASS GUARD (non-vacuous): EVERY ${e.id} verifyPresent needle is code-shaped (found in the entry's code, absent from its marker-only rendering)`,
		codeShaped.length === e.verifyPresent.length,
		`code-shaped ${codeShaped.length}/${e.verifyPresent.length}: ${codeShaped.join(" | ") || "(none)"}`,
	);
}

console.log(results.join("\n"));
console.log(
	failures === 0
		? `\n✅ (d) VERIFIED — pristine ${redMaxTokens} → patched ${greenMaxTokens} (old cap ${OLD_CAP}, summary needs ≥ ${PRIOR_TOKENS})`
		: `\n❌ (d) FAILED — ${failures} assertion(s)`,
);
process.exit(failures === 0 ? 0 : 1);
