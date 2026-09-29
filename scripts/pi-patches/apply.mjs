#!/usr/bin/env node
// apply.mjs — apply / verify / revert the pi patches in this directory against the INSTALLED
// pi tree, then VERIFY the patched outcome behaviourally.
//
// This exists because a fix inside node_modules is reverted by the next install. Nothing here
// is silent: a version that moved, an anchor that no longer matches, or a verify step that
// does not hold all produce a LOUD non-zero exit and change nothing further.
//
// Usage:
//   node scripts/pi-patches/apply.mjs             # apply (idempotent) + verify
//   node scripts/pi-patches/apply.mjs --check     # report status only; 0 applied, 1 not applied, 3 drift
//   node scripts/pi-patches/apply.mjs --revert    # restore the last backup for this version
//   PI_ROOT=<pi coding-agent dir> node …          # override the resolved install
//
// Exit codes: 0 ok · 1 patch not applied (--check) · 2 bad manifest/anchors ·
//             3 installed version drift · 4 verification failed
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { chmodSync, copyFileSync, existsSync, mkdirSync, readFileSync, readdirSync, realpathSync, renameSync, statSync, writeFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";

const HERE = import.meta.dirname;
const args = process.argv.slice(2);
const MODE = args.includes("--check") ? "check" : args.includes("--revert") ? "revert" : "apply";

function resolvePiRoot() {
	const explicit = args.includes("--pi-root") ? args[args.indexOf("--pi-root") + 1] : process.env.PI_ROOT;
	if (explicit) return explicit;
	const candidates = [];
	try {
		const real = realpathSync(execFileSync("bash", ["-lc", "command -v pi"], { encoding: "utf8" }).trim());
		candidates.push(join(dirname(dirname(dirname(real))), "lib", "node_modules", "@earendil-works", "pi-coding-agent"));
	} catch {
		/* fall through */
	}
	for (const prefix of ["/Users/danielospina/.local/share/pi-node/node-v22.23.2-darwin-arm64"]) {
		candidates.push(join(prefix, "lib", "node_modules", "@earendil-works", "pi-coding-agent"));
	}
	for (const c of candidates) if (existsSync(join(c, "package.json"))) return c;
	fail(2, ["could not locate the installed @earendil-works/pi-coding-agent tree", "pass --pi-root <dir>"]);
}

function fail(code, lines) {
	console.error("");
	console.error("╔══════════════════════════════════════════════════════════════════════════════");
	console.error("║  ⛔  PI PATCH FAILED — THE CLAMP DEATH FIX IS NOT IN PLACE");
	console.error("╚══════════════════════════════════════════════════════════════════════════════");
	for (const l of lines) console.error(`   ${l}`);
	console.error("");
	process.exit(code);
}

const MANIFEST_DIR = join(HERE, "manifests");

/**
 * A manifest matches only when its `writtenAgainst` pin equals the installed version for EVERY
 * package either side names. Selecting by this pin — rather than by "exactly one directory
 * exists" — is what makes the NORMAL post-upgrade state work: after `make-manifest.mjs` the old
 * version's directory is still on disk alongside the newly derived one, and the match picks the
 * manifest for the version that is actually installed instead of refusing because there are two.
 * A manifest the pin does not reach is never selected — the refusal below is the fail-closed loud
 * path, and the version pin immediately after this function is the belt to this suspenders.
 */
function manifestMatches(manifest, current) {
	const pinned = manifest?.writtenAgainst;
	if (!pinned || typeof pinned !== "object") return false;
	const keys = new Set([...Object.keys(pinned), ...Object.keys(current)]);
	for (const key of keys) if (pinned[key] !== current[key]) return false;
	return true;
}

function loadManifest(current) {
	// A missing manifests/ directory is a broken CHECKOUT, not a version mismatch: say so plainly
	// instead of letting an empty readdir masquerade as "found 0 version directories", which would
	// send the reader to re-derive a manifest that cannot fix a missing directory. (#1214)
	if (!existsSync(MANIFEST_DIR)) {
		fail(2, [
			`the manifest directory is MISSING: ${MANIFEST_DIR}`,
			"this is a broken checkout of scripts/pi-patches — restore it, e.g. `git checkout -- scripts/pi-patches/manifests`",
			"do NOT re-derive: make-manifest.mjs writes INTO this directory and cannot repair a missing one",
		]);
	}
	const dirs = readdirSync(MANIFEST_DIR, { withFileTypes: true })
		.filter((d) => d.isDirectory())
		.map((d) => d.name)
		.sort();
	const candidates = [];
	for (const dir of dirs) {
		const path = join(MANIFEST_DIR, dir, "manifest.json");
		if (!existsSync(path)) continue;
		try {
			candidates.push({ dir, path, manifest: JSON.parse(readFileSync(path, "utf8")) });
		} catch (error) {
			candidates.push({ dir, path, error: error.message });
		}
	}

	const wanted = process.env.PI_PATCH_VERSION;
	if (wanted) {
		const forced = candidates.find((c) => c.dir === wanted);
		if (!forced) {
			fail(2, [
				`PI_PATCH_VERSION=${wanted} was set, but there is no manifest at ${join(MANIFEST_DIR, wanted, "manifest.json")}`,
				`version directories found: ${dirs.join(", ") || "(none)"}`,
				"unset PI_PATCH_VERSION to let apply.mjs select the manifest by the INSTALLED version",
			]);
		}
		if (forced.error) fail(2, [`could not parse ${forced.path}: ${forced.error}`]);
		return { manifest: forced.manifest, path: forced.path };
	}

	const readable = candidates.filter((c) => !c.error);
	if (readable.length === 0) {
		fail(2, [
			`no readable manifest under ${MANIFEST_DIR}`,
			`version directories found: ${dirs.join(", ") || "(none)"}`,
			...candidates.map((c) => `${c.dir}/manifest.json could not be parsed: ${c.error}`),
			"this is a BROKEN CHECKOUT of scripts/pi-patches, not a version mismatch — restore it,",
			"e.g. `git checkout -- scripts/pi-patches/manifests`",
			"do NOT re-derive: make-manifest.mjs writes INTO this directory and cannot repair a missing manifest",
		]);
	}

	const installedLine = Object.entries(current)
		.map(([pkg, version]) => `${pkg} ${version}`)
		.join(" / ");
	const matches = readable.filter((c) => manifestMatches(c.manifest, current));
	if (matches.length === 0) {
		const issue = readable.map((c) => c.manifest?.issue).find(Boolean) ?? "#1214";
		fail(3, [
			"INSTALLED PI VERSION HAS MOVED — no manifest matches this install; nothing was written.",
			"",
			`installed:  ${installedLine}`,
			`manifests: ${dirs.join(", ") || "(none)"}  (under ${MANIFEST_DIR})`,
			...candidates
				.filter((c) => c.error)
				.map((c) => `⚠ ${c.dir}/manifest.json could not be parsed, and it may be the match: ${c.error}`),
			"",
			"No directory under manifests/ pins that installed version in `writtenAgainst`, so none can be",
			"PROVEN to fit this tree. Refusing beats applying a stale or foreign patch set: the anchors are",
			"byte-exact for the version they were derived from.",
			"",
			"To re-arm the fix for the installed version:",
			`  1. read upstream ${issue} and confirm the defect is still present`,
			`  2. node ${join(HERE, "make-manifest.mjs")}   # re-derives manifests/<installed version>/`,
			`  3. node ${join(HERE, "apply.mjs")}          # applies + verifies`,
			`  4. re-run the evidence tests listed in ${join(HERE, "README.md")}`,
			"",
			`to force one of the directories above anyway: PI_PATCH_VERSION=<dir> node ${join(HERE, "apply.mjs")}`,
			"(forcing re-checks the pin and still refuses — with the drift table — if it does not match, so it",
			" can never turn into a silent apply of the wrong patch set)",
		]);
	}
	if (matches.length > 1) {
		fail(2, [
			`${matches.length} manifests match the installed version (${installedLine}): ${matches.map((c) => c.dir).join(", ")}`,
			"ambiguous — remove the duplicate, or select one explicitly with PI_PATCH_VERSION=<dir>",
		]);
	}
	return { manifest: matches[0].manifest, path: matches[0].path };
}

const PI_ROOT = resolvePiRoot();

const installed = {
	"pi-coding-agent": JSON.parse(readFileSync(join(PI_ROOT, "package.json"), "utf8")).version,
	"pi-ai": JSON.parse(readFileSync(join(PI_ROOT, "node_modules", "@earendil-works", "pi-ai", "package.json"), "utf8")).version,
};

const { manifest, path: manifestPath } = loadManifest(installed);

// ── 1. VERSION PIN — an upgrade must be LOUD, never a silent revert ──────────────────────────
const drift = Object.entries(manifest.writtenAgainst).filter(([pkg, version]) => installed[pkg] !== version);
if (drift.length > 0) {
	const lines = [
		"INSTALLED PI VERSION HAS MOVED — the patch was NOT applied and nothing was written.",
		"",
		...drift.map(([pkg, version]) => `${pkg}: patch written against ${version}, installed ${installed[pkg]}`),
		"",
		"Why this is a hard stop: the replacement anchors below are byte-exact against the version",
		"they were derived from. A moved version means the code may have changed shape — silently",
		"applying a stale anchor would either do nothing or corrupt the bundle.",
		"",
		"To re-arm the fix after an upgrade:",
		`  1. read upstream ${manifest.issue} and confirm the defect is still present`,
		`  2. node ${join(HERE, "make-manifest.mjs")}   # re-derives manifests/<new version>/`,
		`  3. node ${join(HERE, "apply.mjs")}`,
		`  4. re-run the evidence tests listed in ${join(HERE, "README.md")}`,
			"(absolute paths on purpose: the reader is often not in this directory, and a relative",
			" path here is a command that silently cannot be run — use the whole line as printed)",
	];
	fail(3, lines);
}

// The backup is keyed by the pi ROOT as well as the version: two installs can sit on the same
// version (a second node prefix, or a synthetic tree used to re-derive the manifest), and a
// version-only key would make `--revert` restore one install's files over another's (#1214).
const backupRoot = join(
	process.env.HOME ?? "/tmp",
	".pi",
	"agent",
	"state",
	"pi-patches",
	`backup-${installed["pi-coding-agent"]}-${createHash("sha256").update(PI_ROOT).digest("hex").slice(0, 8)}`,
);

// ── 2. REVERT ────────────────────────────────────────────────────────────────────────────────
if (MODE === "revert") {
	if (!existsSync(backupRoot)) fail(2, [`no backup at ${backupRoot}`, "nothing to revert — the tree may never have been patched"]);
	let restored = 0;
	const seen = new Set();
	for (const entry of manifest.entries) {
		const backup = join(backupRoot, entry.file);
		if (!existsSync(backup)) {
			console.warn(`   ! no backup for ${entry.file} — left as-is`);
			continue;
		}
		copyFileSync(backup, join(PI_ROOT, entry.file));
		seen.add(entry.file);
	}
	restored = seen.size;
	console.log(`✅ reverted ${restored} file(s) from ${backupRoot}`);
	console.log("   ⚠ the clamp death fix is now ABSENT — re-apply before running long sessions.");
	process.exit(0);
}

// ── 3. APPLY (idempotent) ────────────────────────────────────────────────────────────────────
const perFile = new Map();
for (const entry of manifest.entries) {
	if (!perFile.has(entry.file)) perFile.set(entry.file, []);
	perFile.get(entry.file).push(entry);
}

// TWO PASSES on purpose. Pass 1 plans every file and may refuse; pass 2 writes. A single pass that
// wrote as it went would leave a HALF-PATCHED tree when a later file refused — some files carrying
// the fix, others not, which is worse than not patching at all and is exactly the kind of silent
// inconsistency this patch set exists to prevent (#1214).
const plan = [];
const report = [];
for (const [file, entries] of perFile) {
	const abs = join(PI_ROOT, file);
	if (!existsSync(abs)) fail(2, [`${file} does not exist in ${PI_ROOT}`, "the manifest does not match this install"]);
	const original = readFileSync(abs, "utf8");
	let next = original;

	for (const entry of entries) {
		const occurrences = next.split(entry.find).length - 1;
		if (occurrences === 0) {
			// The proof that the patched form is present is the entry's OWN replacement payload,
			// verbatim — NEVER the scattered `verifyPresent` substrings. A substring test answers a
			// different question ("does this text appear anywhere?"), so a comment that merely QUOTES
			// the needles satisfied it and read as "already applied" over a tree whose fix code was
			// gone — a false PASS. A comment cannot supply the payload.
			const verified = next.includes(entry.replace);
			if (verified) {
				report.push(`  = ${entry.id} — already applied`);
				continue;
			}
			fail(2, [
				`${entry.id} (${file}): the anchor is absent AND the patched payload is absent.`,
				"The tree is neither pristine nor patched — this file has been modified by something else.",
				`expected one of: ${entry.verifyPresent.join(" | ")}`,
				"NOTHING WAS WRITTEN — no file in this tree has been touched. Restore from backup, or re-derive the manifest.",
			]);
		}
		if (occurrences !== 1) {
			fail(2, [
				`${entry.id} (${file}): anchor matched ${occurrences} times, expected exactly 1.`,
				"NOTHING WAS WRITTEN — no file in this tree has been touched.",
			]);
		}
		if (MODE === "apply") {
			next = next.replace(entry.find, entry.replace);
			report.push(`  + ${entry.id}`);
		} else {
			report.push(`  - ${entry.id} — NOT applied`);
		}
	}

	plan.push({ file, abs, original, next });
}

// ── 3b. WRITE — pass 2, and only now can anything on disk change ─────────────────────────────
let changedFiles = 0;
if (MODE === "apply") {
	for (const { abs, file, original, next } of plan) {
		if (next === original) continue;
		mkdirSync(dirname(join(backupRoot, file)), { recursive: true });
		// Back up the PRISTINE file once, before the first write to it.
		if (!existsSync(join(backupRoot, file))) copyFileSync(abs, join(backupRoot, file));
		// Atomic replace: a crash mid-write must not leave a truncated 4 MB bundle on disk, and a
		// reader (a pi process starting up) must never see a half-written file.
		const tmp = `${abs}.pi-patch-${process.pid}.tmp`;
		writeFileSync(tmp, next);
		chmodSync(tmp, statSync(abs).mode);
		renameSync(tmp, abs);
		changedFiles++;
	}
}

// ── 4. VERIFY — source shape ─────────────────────────────────────────────────────────────────
// The patched REGION must be present verbatim. A `verifyPresent` substring loop here is the same
// scattered-substring false PASS the already-applied branch above was hardened against: a comment
// quoting the needles would satisfy it over a tree with no fix code.
const shapeErrors = [];
for (const entry of manifest.entries) {
	const text = readFileSync(join(PI_ROOT, entry.file), "utf8");
	if (!text.includes(entry.replace)) {
		shapeErrors.push(`${entry.id}: the patched payload is not present verbatim in ${entry.file}`);
	}
}

// ── 5. VERIFY — the clamp behaviour, against the LIVE runtime ────────────────────────────────
const chunk = join(PI_ROOT, "dist", "bundle", "chunks", "chunk-AXIIZGTV.js");
const esm = join(PI_ROOT, "node_modules", "@earendil-works", "pi-ai", "dist", "api", "simple-options.js");
const SAFETY = 4096;

function contextWithTokens(tokens) {
	return { messages: [{ role: "user", content: "x".repeat(tokens * 4), timestamp: 1 }] };
}
/**
 * A model+context pair whose clamp input `available` is exactly the requested value.
 * The estimate grows when `available` is deeply negative, so `contextWindow` never goes
 * non-positive — otherwise the clamp's `contextWindow <= 0` escape hatch (not the floor)
 * would be the branch under test and the probe would grade the wrong code path.
 */
function modelFor(available, maxTokens) {
	const estimate = Math.max(1000, SAFETY - available + 1);
	return { contextWindow: estimate + SAFETY + available, maxTokens, id: "probe", api: "openai-responses", provider: "probe" };
}

const behaviourErrors = [];
async function probe(path, label) {
	let clamp;
	try {
		clamp = (await import(path)).clampMaxTokensToContext;
	} catch (error) {
		behaviourErrors.push(`${label}: could not import ${path} — ${error.message}`);
		return;
	}
	if (typeof clamp !== "function") {
		behaviourErrors.push(`${label}: clampMaxTokensToContext is not exported by ${path}`);
		return;
	}
	const cases = [
		{ available: 0, maxTokens: 8000, want: 1024, why: "no budget left -> must NOT be 1" },
		{ available: -50_000, maxTokens: 8000, want: 1024, why: "estimate overran the window -> must NOT be 1" },
		{ available: 1023, maxTokens: 100_000, want: 1024, why: "just below the floor" },
		{ available: 1024, maxTokens: 100_000, want: 1024, why: "at the floor" },
		{ available: 1025, maxTokens: 100_000, want: 1025, why: "just above the floor — unfloored" },
		{ available: 20_000, maxTokens: 8000, want: 8000, why: "healthy turn — negative control" },
		{ available: 0, maxTokens: 100, want: 100, why: "caller cap below the floor is honoured" },
	];
	for (const c of cases) {
		const model = modelFor(c.available, c.maxTokens);
		const context = contextWithTokens(Math.max(1000, SAFETY - c.available + 1));
		const got = clamp(model, context, c.maxTokens);
		if (got !== c.want) {
			behaviourErrors.push(`${label}: available=${c.available} maxTokens=${c.maxTokens} → ${got}, expected ${c.want} (${c.why})`);
		}
	}
	// The SAME context the `available = 0` case above uses. `modelFor(0, 8000)` builds a window whose
	// clamp input is 0 (contextWindow 8193), so the probe must hold 4097 tokens — NOT the 1000-token
	// `estimate` this once passed, which left `available` at 3097 and made the assertion INERT: the
	// clamp could never return 1 on this input, so the line was green on a pristine tree too. (#1214)
	const death = clamp(modelFor(0, 8000), contextWithTokens(Math.max(1000, SAFETY - 0 + 1)), 8000);
	if (death === 1) behaviourErrors.push(`${label}: STILL ASKS FOR max_tokens: 1 — the fix is not in effect`);
}

await probe(chunk, "bundled runtime");
await probe(esm, "pi-ai ESM");

// ── 6. REPORT ────────────────────────────────────────────────────────────────────────────────
console.log(`pi-patches ${MODE} — pi-coding-agent ${installed["pi-coding-agent"]} / pi-ai ${installed["pi-ai"]}`);
console.log(`  manifest: ${manifestPath}`);
console.log(`  pi root:  ${PI_ROOT}`);
for (const line of report) console.log(line);

if (shapeErrors.length > 0 || behaviourErrors.length > 0) {
	if (MODE === "check") {
		console.log("❌ NOT APPLIED — the fix is not in effect:");
		for (const e of [...shapeErrors, ...behaviourErrors]) console.log(`   - ${e}`);
		process.exit(1);
	}
	fail(4, ["verification FAILED after applying:", ...shapeErrors.map((e) => `shape: ${e}`), ...behaviourErrors.map((e) => `behaviour: ${e}`)]);
}

if (MODE === "check") {
	const notApplied = report.filter((l) => l.includes("NOT applied")).length;
	console.log(notApplied === 0 ? "✅ all replacements present — the fix is in place" : `❌ ${notApplied} replacement(s) MISSING — run apply.mjs to re-arm the fix`);
	process.exit(notApplied === 0 ? 0 : 1);
}

console.log(changedFiles === 0 ? "✅ already applied — nothing to write (idempotent)" : `✅ applied to ${changedFiles} file(s); backups in ${backupRoot}`);
console.log("✅ verified: clamp floor behaviour holds in BOTH the bundled runtime and the pi-ai ESM");
console.log("");
console.log("   ⚠ EXPIRY: this patch is pinned to pi-coding-agent/pi-ai 0.85.1. Any upgrade reverts it");
console.log("     and apply.mjs will refuse LOUDLY (exit 3) until the manifest is re-derived.");
