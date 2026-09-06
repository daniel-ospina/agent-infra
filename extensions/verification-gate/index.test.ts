/**
 * verification-gate.test.ts — unit tests for verification-gate.ts
 *
 * Covers: JSON extraction, schema validation, git operation detection,
 * project root resolution, and regression tests for known bugs.
 *
 * Run: npx tsx extensions/verification-gate.test.ts
 */

import { extractJson, isValidResult, isGitOp, isGitCommit, resolveProjectRoot, resolveMergeRoot, scopeFiles, extractCdPath, normalizeRegistryPath, mergeVerifiedFiles, hashAndMergeFiles, extractRepoFlag, extractGhRepoEnv, extractPrNumber, repoNameFromRemote, evaluateMergeScope, isMergeCommand, mergeCommandWindow, hashMatchesDisk, buildSubAgentBlockMessage, isTaskSubAgent, SHAPE_EXEMPT_EXTENSIONS, BUILD_OUTPUT_SEGMENTS, isShapeExemptFile, isDeletionPush, isBareCommitShape, commitSweepClass, parsePushRefSpecs, resolvePushTier, buildPushRangeDiffCommand } from "./index.js";
import { createHash } from "node:crypto";
import { ok, equal, deepEqual, throws } from "node:assert/strict";
import { mkdtempSync, symlinkSync, writeFileSync, rmSync, realpathSync, readFileSync, existsSync } from "node:fs";
import { join, sep, dirname } from "node:path";
import { tmpdir, homedir } from "node:os";
import { fileURLToPath } from "node:url";

let passed = 0;
let failed = 0;

function test(name: string, fn: () => void) {
  try {
    fn();
    passed++;
    console.log(`  ✅ ${name}`);
  } catch (err: any) {
    failed++;
    console.log(`  ❌ ${name}: ${err.message}`);
  }
}

function section(name: string) {
  console.log(`\n${name}:`);
}

// ── extractJson ──────────────────────────────────────

section("extractJson — raw JSON");

test("parses valid PASS JSON", () => {
  const input = JSON.stringify({ status: "PASS", failures: [], verified_files: [{ path: "foo.ts", hash: "abc" }] });
  const result = extractJson(input);
  ok(result !== null);
  equal(result!.status, "PASS");
  equal(result!.verified_files.length, 1);
});

test("parses valid FAIL JSON", () => {
  const input = JSON.stringify({ status: "FAIL", failures: ["test failed"], verified_files: [] });
  const result = extractJson(input);
  ok(result !== null);
  equal(result!.status, "FAIL");
  equal(result!.failures[0], "test failed");
});

test("handles whitespace padding", () => {
  const input = `  \n  ${JSON.stringify({ status: "PASS", failures: [], verified_files: [] })}  \n`;
  const result = extractJson(input);
  ok(result !== null);
  equal(result!.status, "PASS");
});

section("extractJson — markdown fence");

test("extracts from ```json fence", () => {
  const input = 'Some text\n```json\n{"status":"PASS","failures":[],"verified_files":[]}\n```\nMore text';
  const result = extractJson(input);
  ok(result !== null);
  equal(result!.status, "PASS");
});

test("extracts from last fence when multiple", () => {
  const input = '```json\n{"status":"FAIL","failures":[],"verified_files":[]}\n```\n```json\n{"status":"PASS","failures":[],"verified_files":[]}\n```';
  const result = extractJson(input);
  ok(result !== null);
  equal(result!.status, "PASS");
});

section("extractJson — last-brace extraction");

test("extracts from last { to } pair", () => {
  const input = 'Here is the result: {"status":"PASS","failures":[],"verified_files":[]} and some trailing text';
  const result = extractJson(input);
  ok(result !== null);
  equal(result!.status, "PASS");
});

section("extractJson — stderr noise regression (#132)");

test("verdict JSON + trailing gate_bypass noise → returns the verdict (not the noise)", () => {
  const verdict = { status: "PASS", failures: [], verified_files: [{ path: "website/index.html", hash: "69c98952..." }] };
  const noise = '⚠️  REVIEW GATES DISABLED — all quality checks bypassed...\n' +
    '{"event":"gate_bypass","reason":"escape_hatch","timestamp":"2026-08-09T22:48:04.139Z"}';
  const result = extractJson(JSON.stringify(verdict) + "\n" + noise);
  ok(result !== null, "must extract the verdict, not return null");
  equal(result!.status, "PASS");
  equal(result!.verified_files[0].path, "website/index.html");
});

test("FAIL verdict + noise → FAIL verdict", () => {
  const verdict = { status: "FAIL", failures: ["lint error"], verified_files: [] };
  const noise = '{"event":"gate_bypass","reason":"escape_hatch"}';
  const result = extractJson(JSON.stringify(verdict) + "\n" + noise);
  ok(result !== null);
  equal(result!.status, "FAIL");
  equal(result!.failures[0], "lint error");
});

test("noise-only content → null", () => {
  equal(extractJson('{"event":"gate_bypass","reason":"escape_hatch"}'), null);
});

test("innermost-fragment regression: non-empty verified_files parses (no fence, no noise)", () => {
  const input = 'Here is the result: {"status":"PASS","failures":[],"verified_files":[{"path":"foo.ts","hash":"abc"}]} and some trailing text';
  const result = extractJson(input);
  ok(result !== null, "the trailing nested object must not anchor the slice");
  equal(result!.status, "PASS");
  equal(result!.verified_files.length, 1);
});

test("multiple fences: last fence schema-invalid → earlier valid fence wins", () => {
  const input = '```json\n{"status":"PASS","failures":[],"verified_files":[]}\n```\nthen\n```json\n{"event":"gate_bypass"}\n```';
  const result = extractJson(input);
  ok(result !== null);
  equal(result!.status, "PASS");
});

test("braces inside string values never anchor a candidate", () => {
  const verdict = { status: "PASS", failures: [], verified_files: [{ path: "src/a/{b}/c.ts", hash: "h1" }] };
  const input = 'Result: ' + JSON.stringify(verdict) + ' done';
  const result = extractJson(input);
  ok(result !== null, "must still extract despite { inside path string");
  equal(result!.verified_files[0].path, "src/a/{b}/c.ts");
});

test("} inside a string value never anchors a candidate", () => {
  const verdict = { status: "PASS", failures: [], verified_files: [{ path: "src/a}b/c.ts", hash: "h1" }] };
  const input = 'Result: ' + JSON.stringify(verdict) + ' done';
  const result = extractJson(input);
  ok(result !== null, "must still extract despite } inside path string");
  equal(result!.verified_files[0].path, "src/a}b/c.ts");
});

test("escaped quotes and backslash parity inside strings never corrupt candidates", () => {
  const verdict = { status: "PASS", failures: ["line \"quoted\" and \\\\ backslash"], verified_files: [{ path: "a.ts", hash: "h1" }] };
  const input = JSON.stringify(verdict) + '\ntrailing {"event":"x"}';
  const result = extractJson(input);
  ok(result !== null, "escaped-quote/backslash content must not mis-anchor");
  equal(result!.status, "PASS");
});

test("odd-count literal quote inside a failure string + trailing noise → verdict still extracted", () => {
  // A failure message containing a SINGLE unescaped quote (odd count) must not
  // flip the backward walk's string state and lose the verdict (P2).
  const verdict = { status: "PASS", failures: ["line \"x"], verified_files: [{ path: "a.ts", hash: "h1" }] };
  const input = JSON.stringify(verdict) + '\n{"event":"gate_bypass","reason":"escape_hatch"}';
  const result = extractJson(input);
  ok(result !== null, "odd-count literal quote must not break extraction");
  equal(result!.status, "PASS");
  equal(result!.verified_files[0].path, "a.ts");
});

test("lazy outer key {result: {...}} → inner valid verdict still enumerated", () => {
  // Unparseable outer slice (unquoted key) must not skip the inner valid
  // candidate — advance past the close brace on parse failure (P2).
  const inner = JSON.stringify({ status: "PASS", failures: [], verified_files: [{ path: "foo.ts", hash: "abc" }] });
  const result = extractJson('{result: ' + inner + '} trailing');
  ok(result !== null, "inner verdict inside lazy outer object must be found");
  equal(result!.status, "PASS");
  equal(result!.verified_files[0].path, "foo.ts");
});

test("unbalanced trailing prose is skipped, not fatal", () => {
  const input = '{"status":"PASS","failures":[],"verified_files":[]}\n\nAnd then: { just prose';
  const result = extractJson(input);
  ok(result !== null);
  equal(result!.status, "PASS");
});

test("trailing prose with } only (no balanced pair) → verdict still wins", () => {
  const verdict = { status: "PASS", failures: [], verified_files: [] };
  const result = extractJson(JSON.stringify(verdict) + "\ndone }");
  ok(result !== null);
  equal(result!.status, "PASS");
});

test("placeholder path/hash (…) → null", () => {
  equal(extractJson('{"status":"PASS","failures":[],"verified_files":[{"path":"...","hash":"..."}]}'), null);
});

test("placeholder __placeholder__ / empty values → null", () => {
  equal(extractJson('{"status":"PASS","failures":[],"verified_files":[{"path":"__placeholder__","hash":""}]}'), null);
});

test("empty verified_files stays valid even with trailing noise", () => {
  const input = '{"status":"PASS","failures":[],"verified_files":[]} trailing noise {"event":"x"}';
  const result = extractJson(input);
  ok(result !== null, "empty verified_files must remain a valid result");
  equal(result!.status, "PASS");
});

test("schema-incomplete FAIL (missing verified_files) → null (A.3b routes it at handler)", () => {
  equal(extractJson('{"status":"FAIL","failures":["lint error"]}'), null);
});

test("schema-incomplete FAIL with status in second key position → null (A.3b order-independent probe)", () => {
  equal(extractJson('{"failures":["lint error"],"status":"FAIL"}'), null);
});

test("schema-incomplete PASS (missing arrays) → null (A.4 equivalence input)", () => {
  equal(extractJson('{"status":"PASS"}'), null);
});

test("plain-text PASS line + trailing noise → null (A.3b plain-text merge path)", () => {
  equal(extractJson('PASS\n{"event":"gate_bypass","reason":"escape_hatch"}'), null);
});

test("verdict + placeholder echo AFTER verdict → verdict wins (reverse scan skip-and-continue)", () => {
  const verdict = { status: "PASS", failures: [], verified_files: [{ path: "foo.ts", hash: "abc" }] };
  const echo = '{"status":"PASS","failures":[],"verified_files":[{"path":"...","hash":"..."}]}';
  const result = extractJson(JSON.stringify(verdict) + "\n" + echo);
  ok(result !== null, "placeholder echo must be skipped, real verdict wins");
  equal(result!.verified_files[0].path, "foo.ts");
});

section("extractJson — invalid input");

test("returns null for empty string", () => {
  equal(extractJson(""), null);
});

test("returns null for non-JSON text", () => {
  equal(extractJson("This is just some text, no JSON here."), null);
});

test("returns null for malformed JSON", () => {
  equal(extractJson('{"status":"PASS", failures: [}'), null);
});

// ── isValidResult ────────────────────────────────────

section("isValidResult — valid results");

test("accepts valid PASS result", () => {
  ok(isValidResult({ status: "PASS", failures: [], verified_files: [] }));
});

test("accepts valid FAIL result", () => {
  ok(isValidResult({ status: "FAIL", failures: ["e1"], verified_files: [] }));
});

test("accepts result with verified files", () => {
  ok(isValidResult({
    status: "PASS",
    failures: [],
    verified_files: [{ path: "src/a.ts", hash: "sha256..." }, { path: "src/b.ts", hash: "sha256..." }],
  }));
});

section("isValidResult — invalid results");

test("rejects null", () => {
  equal(isValidResult(null), false);
});

test("rejects undefined", () => {
  equal(isValidResult(undefined), false);
});

test("rejects non-object", () => {
  equal(isValidResult("PASS"), false);
});

test("rejects missing status", () => {
  equal(isValidResult({ failures: [], verified_files: [] }), false);
});

test("rejects invalid status value", () => {
  equal(isValidResult({ status: "UNKNOWN", failures: [], verified_files: [] }), false);
});

test("rejects missing failures array", () => {
  equal(isValidResult({ status: "PASS", verified_files: [] }), false);
});

test("rejects failures not an array", () => {
  equal(isValidResult({ status: "PASS", failures: "none", verified_files: [] }), false);
});

test("rejects missing verified_files", () => {
  equal(isValidResult({ status: "PASS", failures: [] }), false);
});

test("rejects verified_files with invalid entry", () => {
  equal(isValidResult({ status: "PASS", failures: [], verified_files: [{ path: "x.ts" }] }), false);
});

test("rejects verified_files entry with wrong types", () => {
  equal(isValidResult({ status: "PASS", failures: [], verified_files: [{ path: 123, hash: 456 }] }), false);
});

section("isValidResult — placeholder rejection (#132)");

test("rejects '...' path", () => {
  equal(isValidResult({ status: "PASS", failures: [], verified_files: [{ path: "...", hash: "abc" }] }), false);
});
test("rejects '...' hash", () => {
  equal(isValidResult({ status: "PASS", failures: [], verified_files: [{ path: "a.ts", hash: "..." }] }), false);
});
test("rejects empty hash", () => {
  equal(isValidResult({ status: "PASS", failures: [], verified_files: [{ path: "a.ts", hash: "" }] }), false);
});
test("rejects __placeholder__ path", () => {
  equal(isValidResult({ status: "PASS", failures: [], verified_files: [{ path: "__placeholder__", hash: "abc" }] }), false);
});
test("empty verified_files remains valid", () => {
  ok(isValidResult({ status: "PASS", failures: [], verified_files: [] }));
});

// ── isGitOp ──────────────────────────────────────────

section("isGitOp — git operations");

test("detects git commit", () => {
  ok(isGitOp("git commit -m 'test'"));
});

test("detects git push", () => {
  ok(isGitOp("git push origin main"));
});

test("detects gh pr create", () => {
  ok(isGitOp("gh pr create --title 'test'"));
});

test("detects gh pr merge", () => {
  ok(isGitOp("gh pr merge 123 --squash"));
});

test("detects gh pr merge with global -R/--repo flag before the verb (P2-1 fix)", () => {
  ok(isGitOp("gh -R owner/name pr merge 123"));
  ok(isGitOp("gh --repo owner/name pr merge 123"));
});

test("detects git commit at start of line with prefix", () => {
  ok(isGitOp("cd /tmp && git commit -m 'test'"));
});

section("isGitOp — non-git operations");

test("rejects non-git command", () => {
  equal(isGitOp("echo hello"), false);
});

test("rejects npm command", () => {
  equal(isGitOp("npm test"), false);
});

test("rejects empty string", () => {
  equal(isGitOp(""), false);
});

test("detects git commit in inline string (#5571 — known edge case)", () => {
  // git commit inside single-quoted --body arg IS detected.
  // The regex correctly finds 'git commit' in the string;
  // it cannot distinguish command vs literal without a full bash parser.
  // #5571 fixed the heredoc case (multiline <<'EOF' blocks), not inline strings.
  ok(isGitOp("gh issue create --body 'run git commit after'"));
});

test("rejects git in heredoc (#5571 regression)", () => {
  // Commands with heredoc syntax where 'git commit' appears AFTER the heredoc
  // delimiter should not match when there's no real git command
  // The key test: pure documentation text should not trigger
  equal(isGitOp("cat << 'EOF'\necho done\nEOF"), false);
});

test("rejects gitcommit without space", () => {
  equal(isGitOp("gitcommit"), false);
});

test("rejects substring match in longer word", () => {
  equal(isGitOp("somegit commit"), false);
});

// ── resolveProjectRoot ───────────────────────────────

section("resolveProjectRoot");

test("uses blockedCwd when provided", () => {
  const result = resolveProjectRoot("/some/path", "verify files: a.ts");
  ok(result.endsWith("/some/path"));
});

test("extracts from prompt when no blockedCwd", () => {
  const result = resolveProjectRoot(null, "[VGATE] verify files: a.ts b.ts. Classification: UI. Project root: /project/root");
  ok(result.endsWith("/project/root"));
});

test("falls back to process.cwd() when neither available", () => {
  const result = resolveProjectRoot(null, "no project root here");
  // Should resolve to current directory
  ok(typeof result === "string");
  ok(result.length > 0);
});

// ── isGitCommit ──────────────────────────────────────

section("isGitCommit — commit-only detection (#7574)");

test("detects git commit", () => {
  ok(isGitCommit("git commit -m 'test'"));
});

test("does NOT detect git push", () => {
  // lint-staged runs as pre-commit, not pre-push. pendingRehash
  // should only be set on commit, not push.
  equal(isGitCommit("git push origin main"), false);
});

test("does NOT detect gh pr create", () => {
  equal(isGitCommit("gh pr create --title 'test'"), false);
});

test("does NOT detect gh pr merge", () => {
  equal(isGitCommit("gh pr merge 123 --squash"), false);
});

test("detects git commit at start of line with prefix", () => {
  ok(isGitCommit("cd /tmp && git commit -m 'test'"));
});

test("rejects non-git command", () => {
  equal(isGitCommit("echo hello"), false);
});

test("rejects gitcommit without space", () => {
  equal(isGitCommit("gitcommit"), false);
});

test("rejects substring match in longer word", () => {
  equal(isGitCommit("somegit commit"), false);
});

// ── isGitCommit — internal pendingRehash behavior notes ─────────────────
// These behaviors are tested at the exported function level:
//   ✓ pendingRehash is set when git commit is allowed    → isGitCommit("git commit ...") === true
//   ✓ pendingRehash is NOT set when gh pr create is allowed → isGitCommit("gh pr create ...") === false
//   ✓ pendingRehash is NOT set when git push is allowed   → isGitCommit("git push ...") === false
// Internal state transitions (re-hash fires, cleared after re-hash, cleared on
// session_start/session_shutdown) are tested via end-to-end integration, not unit
// tests — they depend on the plugin lifecycle callback chain.

// ── Module load regression ───────────────────────────

section("extractCdPath — worktree cwd detection");

test("extracts path from cd && pattern", () => {
  const result = extractCdPath("cd /some/worktree && git commit -m test");
  ok(result !== null);
  ok(result!.endsWith("/some/worktree"));
});

test("extracts path from cd ; pattern", () => {
  const result = extractCdPath("cd /tmp ; git push");
  ok(result !== null);
  ok(result!.endsWith("/tmp"));
});

test("extracts quoted path", () => {
  const result = extractCdPath("cd '/path with spaces' && git commit");
  ok(result !== null);
  ok(result!.endsWith("/path with spaces"));
});

test("returns null for non-cd command", () => {
  equal(extractCdPath("git commit -m test"), null);
});

test("returns null for cd without git op suffix", () => {
  // The regex requires && or ; after the cd path to avoid false positives
  equal(extractCdPath("cd /tmp"), null);
});

test("cd inside quoted prose does not poison cwd (P2-2 fix)", () => {
  equal(extractCdPath('gh pr merge 1 --comment "see cd /tmp && x"'), null);
  equal(extractCdPath("git commit -m 'run cd /tmp && fix'"), null);
});

test("cd after a command separator is still detected (P2-2 fix)", () => {
  ok(extractCdPath("echo x && cd /tmp && git commit")!.endsWith("/tmp"));
  ok(extractCdPath("cd /a && cd /b && git commit")!.endsWith("/a")); // first boundary-anchored cd wins
});

test("cd after a bare newline separator is detected (cycle-4 P2-1 fix)", () => {
  ok(extractCdPath("echo hello\ncd /tmp && git commit")!.endsWith("/tmp"));
});
test("review 230 P2-3: quoted prose cd shapes never poison cwd", () => {
  equal(extractCdPath('gh pr merge 1 --comment "see; cd /tmp && x"'), null);
  equal(extractCdPath('gh pr merge 1 --body "first\ncd /tmp && second"'), null);
  ok(extractCdPath('cd "/path with spaces" && git commit')!.endsWith("/path with spaces"));
});

test("review 230 P2-2: HOST/OWNER/REPO forms normalize to OWNER/REPO", () => {
  equal(extractGhRepoEnv("GH_REPO=github.com/owner/repo gh pr merge 123"), "owner/repo");
  equal(extractGhRepoEnv("GH_REPO=a/b/c/d gh pr merge 123"), null);
  equal(extractRepoFlag("gh pr merge 123 --repo github.com/owner/repo"), "owner/repo");
});

// ── Module load regression ───────────────────────────

section("Module load regression");

test("imports verification-gate without errors (#5622 regression)", async () => {
  // A static-import crash fails the whole file at load (the real #5622
  // signal), so an ok(true) body would be empty. What the static import does
  // NOT check is the module's primary export — the plugin factory the e2e
  // harness mounts via mod.default — so assert it is present and callable.
  const mod = (await import("./index.js")) as any;
  equal(typeof mod.default, "function", "plugin factory default export must be callable");
});

test("exported functions are callable (#5527 regression)", () => {
  // Smoke-verify the exported surface — INCLUDING the #472 predicates — with
  // concrete outcomes (not ok(true)): a regression that starts throwing or
  // drops an export fails here with a named diagnostic.
  const callables = [
    extractJson, isValidResult, isGitOp, isGitCommit, resolveProjectRoot,
    isShapeExemptFile, isDeletionPush, isBareCommitShape, commitSweepClass,
  ] as const;
  for (const fn of callables) ok(typeof fn === "function", "export must be callable");
  equal(extractJson('{"status":"PASS","failures":[],"verified_files":[]}')!.status, "PASS", "extractJson smoke");
  equal(isGitOp("git commit -m test"), true, "isGitOp smoke");
  equal(isGitCommit("git commit -m test"), true, "isGitCommit smoke");
  ok(isShapeExemptFile("README.md"), "isShapeExemptFile smoke");
  ok(isDeletionPush("git push origin --delete feat/x"), "isDeletionPush smoke");
  ok(isBareCommitShape("git commit -m x"), "isBareCommitShape smoke");
  ok(typeof commitSweepClass === "function", "commitSweepClass smoke (callable)");
});

// ── normalizeRegistryPath (#7595) ────────────────────

section("normalizeRegistryPath — path-key normalization (#7595)");

test("normalizes absolute path to repo-relative", () => {
  equal(normalizeRegistryPath("/proj", "/proj/src/a.ts"), "src/a.ts");
});

test("keeps already-relative path unchanged", () => {
  equal(normalizeRegistryPath("/proj", "src/a.ts"), "src/a.ts");
});

test("strips ./ prefix", () => {
  equal(normalizeRegistryPath("/proj", "./src/a.ts"), "src/a.ts");
});

test("handles nested roots without prefix stripping", () => {
  // project root itself has a prefix: /home/user/repo vs /home/user — must not strip "user/repo"
  equal(normalizeRegistryPath("/home/user/repo", "/home/user/repo/app/x.ts"), "app/x.ts");
  equal(normalizeRegistryPath("/home/user/repo", "/home/user/other.ts"), "../other.ts");
});

test("returns original when path is the root itself", () => {
  const p = "/proj";
  equal(normalizeRegistryPath(p, p), p);
});

test("symlinked FILE keeps the git-verbatim relative path (#305)", () => {
  // Regression: realpathSync(abs) used to resolve through the link to its
  // target, registering a committed symlink under the TARGET's path — a key
  // that never matches the block check's verbatim git path, so every commit
  // touching the symlink was blocked as "unverified" forever.
  const root = mkdtempSync(join(tmpdir(), "vgate-nrp-"));
  try {
    writeFileSync(join(root, "target.yml"), "target\n");
    symlinkSync("target.yml", join(root, "link.yml"));
    equal(normalizeRegistryPath(root, "link.yml"), "link.yml");
    equal(normalizeRegistryPath(root, join(root, "link.yml")), "link.yml");
    // regular file still normalizes through a symlinked PARENT dir
    equal(normalizeRegistryPath(root, "target.yml"), "target.yml");
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

// ── resolveMergeRoot (#190) ─────────────────────────

section("resolveMergeRoot — wrong-root guard (#190)");

test("prompt root that realpath-differs from blockedCwd → foreign (worktree B dispatch against worktree A block)", () => {
  const { root, foreign } = resolveMergeRoot("/worktrees/wt-A", "[VGATE] verify files: a.ts. Classification: UI. Project root: /worktrees/wt-B");
  equal(foreign, true, "stale block context must be flagged foreign");
  ok(root.endsWith("/worktrees/wt-B"), "prompt's explicit root is authoritative");
});

test("prompt root matching blockedCwd → not foreign", () => {
  const { root, foreign } = resolveMergeRoot("/worktrees/wt-A", "[VGATE] verify files: a.ts. Classification: UI. Project root: /worktrees/wt-A");
  equal(foreign, false);
  ok(root.endsWith("/worktrees/wt-A"));
});

test("no prompt root + blockedCwd → blockedCwd, not foreign", () => {
  const { root, foreign } = resolveMergeRoot("/worktrees/wt-A", "[VGATE] verify files: a.ts");
  equal(foreign, false);
  ok(root.endsWith("/worktrees/wt-A"));
});

test("no prompt root + no blockedCwd → git-root fallback", () => {
  const { root, foreign } = resolveMergeRoot(null, "[VGATE] verify files: a.ts");
  equal(foreign, false);
  ok(typeof root === "string" && root.length > 0);
});

// ── scopeFiles (#190) ────────────────────────────────

section("scopeFiles — diff-scoped merge pre-filter (#190)");

test("blocked-context filter: keeps files in the blocked diff, skips others", () => {
  const { kept, skipped } = scopeFiles(["src/a.ts", "src/b.ts"], "/proj", ["src/a.ts"], new Set());
  equal(kept.length, 1);
  equal(kept[0], "src/a.ts");
  equal(skipped, 1);
});

test("KNOWN path merges even with a stale blocked list (#38 — regression guard for e2e scenario 4)", () => {
  // #38: re-verification of an already-known path is authoritative. A stale
  // lastBlockedFiles (previous block covered different files) must NOT drop it.
  const known = new Set(["/proj::src/a.ts"]);
  const { kept, skipped } = scopeFiles(["src/a.ts"], "/proj", ["other/file.ts"], known);
  equal(kept.length, 1, "known path must survive the stale blocked filter");
  equal(kept[0], "src/a.ts");
  equal(skipped, 0);
});

test("absolute-path input normalizes to repo-relative before filtering", () => {
  const { kept, skipped } = scopeFiles(["/proj/src/a.ts"], "/proj", ["src/a.ts"], new Set());
  equal(kept.length, 1);
  equal(kept[0], "/proj/src/a.ts");
  equal(skipped, 0);
});

test("empty blocked list + known path → kept (staged-diff not consulted)", () => {
  const known = new Set(["/proj::src/a.ts"]);
  const { kept, skipped } = scopeFiles(["src/a.ts"], "/proj", [], known);
  equal(kept.length, 1);
  equal(skipped, 0);
});

// ── mergeVerifiedFiles (#7595 / #38 / #37) ─────────────────

section("mergeVerifiedFiles — registry merge on PASS");

test("merges absolute-path response under compound key (#37/#38)", () => {
  // #37: keys are now compound (worktree-root::repo-relative), not plain paths.
  const vs = new Map<string, string>();
  const ba = new Map<string, number>();
  const { merged, skipped } = mergeVerifiedFiles(
    vs, ba,
    [{ path: "/proj/src/a.ts", hash: "H2" }],
    "/proj",
    ["src/a.ts"]
  );
  equal(merged, 1);
  equal(skipped, 0);
  equal(vs.get("/proj::src/a.ts"), "H2", "must be stored under compound (worktree-root::repo-relative) key");
  equal(vs.has("/proj/src/a.ts"), false, "absolute key must not be stored");
  equal(vs.has("src/a.ts"), false, "plain relative key must not be stored");
});

test("re-verification of known path always updates even when not in last blocked diff (#38)", () => {
  // lastBlockedFiles is stale: it references a previous block on different files.
  // The known path must STILL be updated — the verifier is the authority.
  // #37: keys are compound.
  const vs = new Map<string, string>([["/proj::src/a.ts", "H1"]]);
  const ba = new Map<string, number>();
  const { merged, skipped } = mergeVerifiedFiles(
    vs, ba,
    [{ path: "/proj/src/a.ts", hash: "H2" }],
    "/proj",
    ["other/file.ts"] // stale blocked list — does NOT contain a.ts
  );
  equal(merged, 1, "known path must merge despite stale filter");
  equal(skipped, 0);
  equal(vs.get("/proj::src/a.ts"), "H2");
});

test("new path outside blocked diff is skipped (#5673 preserved)", () => {
  const vs = new Map<string, string>();
  const ba = new Map<string, number>();
  const { merged, skipped } = mergeVerifiedFiles(
    vs, ba,
    [{ path: "src/new.ts", hash: "H" }],
    "/proj",
    ["src/a.ts"]
  );
  equal(merged, 0);
  equal(skipped, 1, "unrelated new file must not be marked verified");
  equal(vs.has("/proj::src/new.ts"), false);
});

test("new path inside blocked diff merges", () => {
  const vs = new Map<string, string>();
  const ba = new Map<string, number>();
  const { merged, skipped } = mergeVerifiedFiles(
    vs, ba,
    [{ path: "/proj/src/new.ts", hash: "H" }],
    "/proj",
    ["src/new.ts"]
  );
  equal(merged, 1);
  equal(skipped, 0);
  equal(vs.get("/proj::src/new.ts"), "H");
});

test("empty lastBlockedFiles merges everything", () => {
  const vs = new Map<string, string>();
  const ba = new Map<string, number>();
  const { merged, skipped } = mergeVerifiedFiles(
    vs, ba,
    [{ path: "a.ts", hash: "H1" }, { path: "b.ts", hash: "H2" }],
    "/proj",
    []
  );
  equal(merged, 2);
  equal(skipped, 0);
});

test("resets block-attempt counters for merged files", () => {
  const vs = new Map<string, string>();
  const ba = new Map<string, number>([["/proj::src/a.ts", 2]]);
  mergeVerifiedFiles(vs, ba, [{ path: "src/a.ts", hash: "H" }], "/proj", ["src/a.ts"]);
  equal(ba.has("/proj::src/a.ts"), false);
});

// ── mergeVerifiedFiles — cross-worktree isolation (#37) ──

section("mergeVerifiedFiles — cross-worktree isolation (#37)");

test("same-named files in different worktrees get distinct records", () => {
  // Two worktrees in the same repo both have "tortoise/sdk.py".
  // Compound keys prevent cross-worktree hash contamination.
  const vs = new Map<string, string>();
  const ba = new Map<string, number>();

  // Worktree A verifies its sdk.py
  const resA = mergeVerifiedFiles(
    vs, ba,
    [{ path: "tortoise/sdk.py", hash: "hashA" }],
    "/worktrees/wt-A",
    ["tortoise/sdk.py"]
  );
  equal(resA.merged, 1);

  // Worktree B verifies its sdk.py
  const resB = mergeVerifiedFiles(
    vs, ba,
    [{ path: "tortoise/sdk.py", hash: "hashB" }],
    "/worktrees/wt-B",
    ["tortoise/sdk.py"]
  );
  equal(resB.merged, 1);

  // Both records exist independently
  equal(vs.get("/worktrees/wt-A::tortoise/sdk.py"), "hashA", "worktree A record intact");
  equal(vs.get("/worktrees/wt-B::tortoise/sdk.py"), "hashB", "worktree B record intact");
  equal(vs.size, 2, "two distinct records, not one overwriting the other");
});

test("re-verification in one worktree does not affect files in another", () => {
  const vs = new Map<string, string>([
    ["/wt-A::src/a.ts", "hashA1"],
    ["/wt-B::src/a.ts", "hashB1"],
  ]);
  const ba = new Map<string, number>();

  // Re-verify wt-A's a.ts
  mergeVerifiedFiles(
    vs, ba,
    [{ path: "src/a.ts", hash: "hashA2" }],
    "/wt-A",
    ["src/a.ts"]
  );

  // wt-A updated, wt-B untouched
  equal(vs.get("/wt-A::src/a.ts"), "hashA2", "wt-A updated");
  equal(vs.get("/wt-B::src/a.ts"), "hashB1", "wt-B untouched");
});

// ── mergeVerifiedFiles — VGATE PASS overwrite (#37) ──

section("mergeVerifiedFiles — VGATE PASS overwrite (#37)");

test("VGATE PASS with hash H1 then H2 → expected becomes H2", () => {
  // The verifier is the authority. A fresh PASS must overwrite the
  // expected hash unconditionally.
  const vs = new Map<string, string>();
  const ba = new Map<string, number>();

  // First verification — records H1
  mergeVerifiedFiles(
    vs, ba,
    [{ path: "src/a.ts", hash: "H1" }],
    "/proj",
    ["src/a.ts"]
  );
  equal(vs.get("/proj::src/a.ts"), "H1");

  // Second verification (e.g., after a fix) — records H2, overwrites H1
  mergeVerifiedFiles(
    vs, ba,
    [{ path: "src/a.ts", hash: "H2" }],
    "/proj",
    ["src/a.ts"]
  );
  equal(vs.get("/proj::src/a.ts"), "H2", "verifier's latest hash must overwrite previous");
});

test("VGATE PASS overwrites even when path not in lastBlockedFiles", () => {
  // Regression: if the blocked diff shifted between cycles, a known
  // path must still be updated on re-verification.
  const vs = new Map<string, string>([["/proj::src/a.ts", "H1"]]);
  const ba = new Map<string, number>();

  const { merged, skipped } = mergeVerifiedFiles(
    vs, ba,
    [{ path: "src/a.ts", hash: "H2" }],
    "/proj",
    [] // empty blocked list — but path is known, so must still merge
  );
  equal(merged, 1, "known path must merge even with empty lastBlockedFiles");
  equal(skipped, 0);
  equal(vs.get("/proj::src/a.ts"), "H2");
});

// ── Results ───────────────────────────────────────────

// ── #204: gh pr merge scope — PR repo resolution ─────

section("extractRepoFlag / extractGhRepoEnv — PR repo resolution (#204)");

test("extractRepoFlag: --repo owner/name", () => {
  equal(extractRepoFlag("gh pr merge 123 --repo acme/widget"), "acme/widget");
});

test("extractRepoFlag: -R owner/name", () => {
  equal(extractRepoFlag("gh pr merge 123 -R acme/widget --squash"), "acme/widget");
});

test("extractRepoFlag: --repo=owner/name (equals form)", () => {
  equal(extractRepoFlag("gh pr merge 123 --repo=acme/widget"), "acme/widget");
});

test("extractRepoFlag: absent → null", () => {
  equal(extractRepoFlag("gh pr merge 123"), null);
});

test("extractRepoFlag: does not match git remote args", () => {
  equal(extractRepoFlag("git remote add origin git@github.com:a/b.git"), null);
});

test("extractGhRepoEnv: GH_REPO=owner/name prefix", () => {
  equal(extractGhRepoEnv("GH_REPO=acme/widget gh pr merge 123"), "acme/widget");
});

test("extractGhRepoEnv: absent → null", () => {
  equal(extractGhRepoEnv("gh pr merge 123"), null);
});

test("repo priority: flag beats env when both present", () => {
  const command = "GH_REPO=env/repo gh pr merge 123 --repo flag/repo";
  const flag = extractRepoFlag(command);
  const env = extractGhRepoEnv(command);
  const resolved = flag ?? env;
  equal(resolved, "flag/repo", "flag must take priority over env");
});

// ── #204: repoNameFromRemote URL forms ────────────────

section("repoNameFromRemote — origin URL parsing (#204)");

test("SSH form git@github.com:owner/name.git", () => {
  equal(repoNameFromRemote("git@github.com:acme/widget.git"), "acme/widget");
});

test("SSH form without .git suffix", () => {
  equal(repoNameFromRemote("git@github.com:acme/widget"), "acme/widget");
});

test("HTTPS form https://github.com/owner/name.git", () => {
  equal(repoNameFromRemote("https://github.com/acme/widget.git"), "acme/widget");
});

test("git:// form", () => {
  equal(repoNameFromRemote("git://github.com/acme/widget.git"), "acme/widget");
});

test("ssh://git@ with colon separator", () => {
  equal(repoNameFromRemote("ssh://git@github.com:acme/widget.git"), "acme/widget");
});

test("HTTPS with port", () => {
  equal(repoNameFromRemote("https://github.com:8443/acme/widget.git"), "acme/widget");
});

test("HTTPS with credentials", () => {
  equal(repoNameFromRemote("https://user@github.com/acme/widget.git"), "acme/widget");
});

test("non-GitHub host parses (host-agnostic)", () => {
  equal(repoNameFromRemote("git@gitlab.com:acme/widget.git"), "acme/widget");
});

test("garbage / empty → null (fail-closed)", () => {
  equal(repoNameFromRemote(""), null);
  equal(repoNameFromRemote("not a url"), null);
});

test("trailing slash / .git forms never yield a garbage identity (P2 fix)", () => {
  equal(repoNameFromRemote("git@github.com:a/b.git/"), "a/b");
  equal(repoNameFromRemote("https://github.com/a/b.git/"), "a/b");
  equal(repoNameFromRemote("git@github.com:a/b/"), "a/b");
});

test("local path remote → null (fail-closed, no accidental skip)", () => {
  equal(repoNameFromRemote("/tmp/some/repo.git"), null);
  equal(repoNameFromRemote("relative/path"), null);
});

// ── #204: extractPrNumber ─────────────────────────────

section("extractPrNumber — PR number from merge command (#204)");

test("extracts PR number from gh pr merge", () => {
  equal(extractPrNumber("gh pr merge 123 --squash"), 123);
});

test("extracts PR number after cd prefix", () => {
  equal(extractPrNumber("cd /wt && gh pr merge 42"), 42);
});

test("extracts PR number when flags precede the number (P2 fix: gh pr merge --squash 123)", () => {
  equal(extractPrNumber("gh pr merge --squash 123"), 123);
});

test("extracts PR number with flags + cd prefix in either order", () => {
  equal(extractPrNumber("cd /wt && gh pr merge --repo x/y 42"), 42);
  equal(extractPrNumber("gh pr merge -R x/y --squash 7"), 7);
});

test("extracts PR number with global -R flag before the verb (P2-1 fix)", () => {
  equal(extractPrNumber("gh -R owner/name pr merge 123"), 123);
  equal(extractPrNumber("GH_REPO=a/b gh --repo=owner/name pr merge 456"), 456);
});

test("does not mistake flag values for the PR number", () => {
  // --repo owner/name never tokenizes as a bare integer.
  equal(extractPrNumber("gh pr merge --repo 123/owner"), null);
});

// ── #204: verb-anchored merge detection + command window ─

section("isMergeCommand / mergeCommandWindow — verb-anchored merge scoping (#204 P2 fixes)");

test("isMergeCommand: true for plain merge", () => {
  equal(isMergeCommand("gh pr merge 123 --squash"), true);
});

test("isMergeCommand: true after cd && prefix and inline env", () => {
  equal(isMergeCommand("cd /wt && gh pr merge 42"), true);
  equal(isMergeCommand("GH_REPO=x/y gh pr merge 42"), true);
  equal(isMergeCommand("cd /a && cd /b && GH_REPO=x/y gh pr merge 42"), true);
});

test("isMergeCommand: true with global -R/--repo before the verb (P2-1 fix)", () => {
  equal(isMergeCommand("gh -R owner/name pr merge 123"), true);
  equal(isMergeCommand("gh --repo=owner/name pr merge 123"), true);
  equal(isMergeCommand("GH_REPO=a/b gh -R owner/name pr merge 123"), true);
});

test("isMergeCommand: false when the merge verb is quoted prose in a create body (P2-2 regression)", () => {
  equal(isMergeCommand('gh pr create --body "run gh pr merge 42 now"'), false);
  equal(isMergeCommand("gh pr create --title 'gh pr merge 7'"), false);
});

test("isMergeCommand: false for non-merge commands", () => {
  equal(isMergeCommand("gh pr create --title x"), false);
  equal(isMergeCommand("git commit -m x"), false);
  equal(isMergeCommand("gh pr merge-queue 1"), false);
});

test("isMergeCommand: chained merge is fail-closed (not detected as merge → status quo verify)", () => {
  equal(isMergeCommand("gh issue create --repo x/y && gh pr merge 123"), false);
});

test("mergeCommandWindow: keeps the merge's own --repo flag", () => {
  ok(mergeCommandWindow("gh pr merge 123 --repo other/owner").includes("--repo other/owner"));
});

test("mergeCommandWindow: quoted prose --repo is stripped (P2-1 regression)", () => {
  const w = mergeCommandWindow('gh pr merge 123 --comment "see --repo fake/x docs"');
  equal(w.includes("--repo fake/x"), false, "--repo inside quotes must not reach the flag scan");
  ok(w.includes("--comment"), "the merge's own flags remain");
});

test("mergeCommandWindow: chained command's --repo is excluded (P2-1 regression)", () => {
  const w = mergeCommandWindow("gh pr merge 123 && gh pr create --repo other/x");
  equal(w.includes("other/x"), false, "chained command's repo flag must not decide this merge's scope");
});

test("mergeCommandWindow: pre-merge chained --repo is excluded", () => {
  const w = mergeCommandWindow("gh issue create --repo x/y && gh pr merge 123");
  equal(w.includes("--repo x/y"), false);
  equal(w.includes("gh pr merge"), true);
});

test("mergeCommandWindow: keeps GH_REPO= env prefix and global -R flag", () => {
  ok(mergeCommandWindow("GH_REPO=a/b gh pr merge 123").includes("GH_REPO=a/b"));
  ok(mergeCommandWindow("gh -R owner/name pr merge 123").includes("-R owner/name"));
});

test("extractPrNumber composes with mergeCommandWindow: chained-tail integers never misread as the PR number (cycle-4 P2-2 fix)", () => {
  // resolveMergeScope feeds the window to extractPrNumber; the window cuts the
  // tail at the first command separator, so `|| exit 1` never supplies a number.
  equal(extractPrNumber(mergeCommandWindow("gh pr merge --squash || exit 1")), null);
  equal(extractPrNumber(mergeCommandWindow("gh pr merge -s -d; exit 1")), null);
  equal(extractPrNumber(mergeCommandWindow("gh pr merge 123 --squash || exit 1")), 123, "the merge's OWN number still wins");
});


test("null when no number or not a merge", () => {
  equal(extractPrNumber("gh pr merge"), null);
  equal(extractPrNumber("gh pr create --title x"), null);
});

// ── #204: evaluateMergeScope 4-combo decision table ───

section("evaluateMergeScope — merge-scope decision table (#204)");

test("cross_repo: explicit repo ≠ cwd repo → skip, heads irrelevant", () => {
  const d = evaluateMergeScope("acme/self", "acme/other", "HEAD1", "HEAD2");
  equal(d.verify, false);
  equal(d.reason, "cross_repo");
});

test("cross_repo: even when heads happen to match", () => {
  const d = evaluateMergeScope("acme/self", "acme/other", "HEAD1", "HEAD1");
  equal(d.verify, false);
  equal(d.reason, "cross_repo");
});

test("same-repo head match → verify (worktree merge, no regression)", () => {
  const d = evaluateMergeScope("acme/self", "acme/self", "HEAD1", "HEAD1");
  equal(d.verify, true);
  equal(d.reason, "same_repo_head_match");
});

test("same-repo, no explicit repo, head match → verify", () => {
  const d = evaluateMergeScope("acme/self", null, "HEAD1", "HEAD1");
  equal(d.verify, true);
  equal(d.reason, "same_repo_head_match");
});

test("head_mismatch: same-repo stale checkout → skip", () => {
  const d = evaluateMergeScope("acme/self", null, "STALE", "PRHEAD");
  equal(d.verify, false);
  equal(d.reason, "head_mismatch");
});

test("head_mismatch: explicit repo == cwd repo, stale checkout → skip", () => {
  const d = evaluateMergeScope("acme/self", "acme/self", "STALE", "PRHEAD");
  equal(d.verify, false);
  equal(d.reason, "head_mismatch");
});

test("fail-closed: prHead unknown (gh/network failed) → verify, status quo", () => {
  const d = evaluateMergeScope("acme/self", null, "STALE", null);
  equal(d.verify, true);
  equal(d.reason, "same_repo_head_unknown");
});

test("fail-closed: localHead unknown → verify", () => {
  const d = evaluateMergeScope("acme/self", null, null, "PRHEAD");
  equal(d.verify, true);
  equal(d.reason, "same_repo_head_unknown");
});

test("fail-closed: unparseable cwdRepo never skips on REPO grounds", () => {
  // Unknown head + unparseable origin → verify (never an accidental
  // cross_repo skip). Known heads may still disagree → head_mismatch is an
  // independent, legitimate ground.
  const repoGround = evaluateMergeScope(null, "acme/other", "STALE", null);
  equal(repoGround.verify, true, "unparseable origin + unknown head must verify");
  equal(repoGround.reason, "same_repo_head_unknown");
  const headGround = evaluateMergeScope(null, "acme/other", "STALE", "PRHEAD");
  equal(headGround.reason, "head_mismatch", "known-head disagreement is still a valid skip ground");
});

test("repo identity comparison is case-insensitive (P2 fix)", () => {
  const d = evaluateMergeScope("Acme/Widget", "acme/widget", "HEAD1", "HEAD1");
  equal(d.verify, true, "GitHub repo names are case-insensitive — must not false-skip");
  equal(d.reason, "same_repo_head_match");
  const envCase = evaluateMergeScope("acme/widget", "ACME/WIDGET", "HEAD1", "HEAD1");
  equal(envCase.verify, true);
});

test("repo identity comparison tolerates .git / trailing-slash drift (P2 fix)", () => {
  const d = evaluateMergeScope("acme/widget.git", "acme/widget", "HEAD1", "HEAD1");
  equal(d.verify, true);
  const slash = evaluateMergeScope("acme/widget", "acme/widget/", "HEAD1", "HEAD1");
  equal(slash.verify, true);
});

test("evaluateMergeScope never returns undefined for any input shape", () => {
  const inputs: [string | null, string | null, string | null, string | null][] = [
    [null, null, null, null],
    [null, "a/b", null, null],
    ["a/b", null, null, null],
    ["a/b", "a/b", "X", "X"],
  ];
  for (const [cwdRepo, explicitRepo, localHead, prHead] of inputs) {
    const d = evaluateMergeScope(cwdRepo, explicitRepo, localHead, prHead);
    ok(d && typeof d.verify === "boolean" && typeof d.reason === "string", "must always return a decision");
  }
});

// ── hashMatchesDisk (#320) ───────────────────────────

section("hashMatchesDisk — sha1/sha256 acceptance (#320)");

test("sha1 stored hash matches unchanged disk file", () => {
  const root = mkdtempSync(join(tmpdir(), "vgate-hm-"));
  try {
    writeFileSync(join(root, "a.ts"), "content-a\n");
    const sha1 = createHash("sha1").update("content-a\n").digest("hex");
    equal(hashMatchesDisk(root, "a.ts", sha1), true);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("sha1 stored hash fails on edited disk file (anti-drift preserved)", () => {
  const root = mkdtempSync(join(tmpdir(), "vgate-hm-"));
  try {
    writeFileSync(join(root, "a.ts"), "content-a\n");
    const sha1 = createHash("sha1").update("content-a\n").digest("hex");
    writeFileSync(join(root, "a.ts"), "content-b\n");
    equal(hashMatchesDisk(root, "a.ts", sha1), false);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("sha256 stored hash matches unchanged disk file (status quo)", () => {
  const root = mkdtempSync(join(tmpdir(), "vgate-hm-"));
  try {
    writeFileSync(join(root, "a.ts"), "content-a\n");
    const sha256 = createHash("sha256").update("content-a\n").digest("hex");
    equal(hashMatchesDisk(root, "a.ts", sha256), true);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("uppercase hex stored hash matches (case-insensitive)", () => {
  const root = mkdtempSync(join(tmpdir(), "vgate-hm-"));
  try {
    writeFileSync(join(root, "a.ts"), "content-a\n");
    const sha1 = createHash("sha1").update("content-a\n").digest("hex").toUpperCase();
    equal(hashMatchesDisk(root, "a.ts", sha1), true);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("unknown-length hash (md5, 32-hex) fails closed", () => {
  const root = mkdtempSync(join(tmpdir(), "vgate-hm-"));
  try {
    writeFileSync(join(root, "a.ts"), "content-a\n");
    const md5 = createHash("md5").update("content-a\n").digest("hex");
    equal(hashMatchesDisk(root, "a.ts", md5), false);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("missing file throws (consistent with hashFile; callers fail closed)", () => {
  const root = mkdtempSync(join(tmpdir(), "vgate-hm-"));
  try {
    const sha1 = createHash("sha1").update("x").digest("hex");
    throws(() => hashMatchesDisk(root, "missing.ts", sha1));
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

// ── hashAndMergeFiles (#336) ─────────────────────────

section("hashAndMergeFiles — hash-less PASS records blocked files (#336)");

test("hashes blocked files into the registry under compound keys", () => {
  const root = mkdtempSync(join(tmpdir(), "vgate-ham-"));
  try {
    writeFileSync(join(root, "a.ts"), "content-a\n");
    writeFileSync(join(root, "b.ts"), "content-b\n");
    const vs = new Map<string, string>();
    const ba = new Map<string, number>();
    const merged = hashAndMergeFiles(vs, ba, ["a.ts", "b.ts"], root);
    equal(merged, 2, "both files must be recorded");
    const normRoot = realpathSync(root);
    equal(vs.get(`${normRoot}::a.ts`), createHash("sha256").update("content-a\n").digest("hex"), "a.ts recorded with its current disk hash");
    equal(vs.get(`${normRoot}::b.ts`), createHash("sha256").update("content-b\n").digest("hex"), "b.ts recorded with its current disk hash");
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("resets block-attempt counters for recorded files", () => {
  const root = mkdtempSync(join(tmpdir(), "vgate-ham2-"));
  try {
    writeFileSync(join(root, "a.ts"), "content-a\n");
    const vs = new Map<string, string>();
    const normRoot = realpathSync(root);
    const ba = new Map<string, number>([[`${normRoot}::a.ts`, 2]]);
    hashAndMergeFiles(vs, ba, ["a.ts"], root);
    equal(ba.has(`${normRoot}::a.ts`), false, "counter cleared for recorded file");
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("post-PASS edit flips the recorded hash (fail-closed re-block)", () => {
  const root = mkdtempSync(join(tmpdir(), "vgate-ham3-"));
  try {
    writeFileSync(join(root, "a.ts"), "v1\n");
    const vs = new Map<string, string>();
    const ba = new Map<string, number>();
    hashAndMergeFiles(vs, ba, ["a.ts"], root);
    const normRoot = realpathSync(root);
    const stored = vs.get(`${normRoot}::a.ts`)!;
    equal(stored, createHash("sha256").update("v1\n").digest("hex"), "hash recorded at PASS time");
    writeFileSync(join(root, "a.ts"), "v2\n"); // post-PASS edit
    equal(hashMatchesDisk(root, "a.ts", stored), false, "edited file must no longer match the recorded hash → re-block");
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

// ── #285 — task-tool-aware sub-agent block message + drift guard ──

section("buildSubAgentBlockMessage — task-tool-aware (#285 P1-A)");

test("task-capable (default argv): in-band self-dispatch instruction kept", () => {
  const msg = buildSubAgentBlockMessage(["  Unverified files:"], "/repo", ["a.ts"]);
  ok(msg.includes("This session is a task sub-agent"), "carries the sub-agent marker");
  ok(/Dispatch your own VGATE verification/.test(msg), "in-band self-dispatch instruction");
  ok(!/STOP — this block is final/.test(msg), "no final-block phrasing for task-capable");
});

test("#483: task-capable self-dispatch template keeps the literal task(prompt='[VGATE] verify files: … form verbatim", () => {
  // The tool_result handler identifies a verifier dispatch by prompt.includes("[VGATE]")
  // and the file-match regex reads "[VGATE] verify files: <paths>" — the template's
  // quoting/token form is load-bearing for the #264 in-band self-satisfaction ceremony.
  // Pre-#483 this exact copy was pinned ONLY at the e2e layer (scenarios 22/25); the
  // #483 relaxation moved e2e to semantic asserts, so the verbatim copy lives here.
  const msg = buildSubAgentBlockMessage(["  Unverified files:"], "/repo", ["a.ts"]);
  const template = `task(prompt='[VGATE] verify files: a.ts. Classification: <UI|backend|both>. Project root: /repo. Return ONLY JSON: {"status":"PASS","failures":[],"verified_files":[{"path":"<repo-relative>","hash":"<sha256>"}]}.', ...)`;
  ok(msg.includes(template), "task-capable dispatch template must keep the exact task(prompt='[VGATE] verify files: … form (tool_result merge contract)");
});

test("task-restricted (--tools allowlist without task): return-to-parent instruction", () => {
  const msg = buildSubAgentBlockMessage(["  Unverified files:"], "/repo", ["a.ts"], ["pi", "-p", "--tools", "read,bash,edit,write"]);
  ok(/STOP — this block is final; do not bypass; return to the parent\s+session/.test(msg), "final-block return-to-parent instruction");
  ok(!/Dispatch your own VGATE verification/.test(msg), "no in-band self-dispatch for restricted agents");
  ok(!/This session has the task tool/.test(msg), "must not claim the task tool");
});

test("--tools with task ∈ allowlist → task-capable", () => {
  const msg = buildSubAgentBlockMessage([], "/repo", ["a.ts"], ["pi", "-p", "--tools", "read,bash,edit,write,task"]);
  ok(/Dispatch your own VGATE verification/.test(msg));
});

test("--exclude-tools task → restricted", () => {
  const msg = buildSubAgentBlockMessage([], "/repo", ["a.ts"], ["pi", "-p", "--exclude-tools", "task"]);
  ok(/STOP — this block is final/.test(msg));
});

test("--no-tools → restricted", () => {
  const msg = buildSubAgentBlockMessage([], "/repo", ["a.ts"], ["pi", "-p", "--no-tools"]);
  ok(/STOP — this block is final/.test(msg));
});

test("block reason lines are diff-scoped exactly like the inline text (reasons + file list)", () => {
  const msg = buildSubAgentBlockMessage(["  Unverified files:", "    - x.ts"], "/repo", ["x.ts"]);
  ok(msg.includes("- x.ts"), "reasons preserved");
  ok(/verify files: x\.ts/.test(msg), "blocked files named in the dispatch template");
});

// #285/#483 drift guard (BEHAVIORAL): isTaskSubAgent must read the marker pair
// TASK_HEARTBEAT=1 ∧ PI_MODE=print — the SAME pair review-enforcer's
// isTaskSubAgent and task-heartbeat's taskHeartbeatActive/orphanWatchdogActive
// read (builtin-tools forces both markers on every task child, #172/#825).
// The three predicates can't import each other (extension-loader constraint —
// each extension file is standalone), so the pair is pinned per-extension.
// Behavioral (constructed env objects) rather than the pre-#483 source-text
// readFileSync: a cosmetic refactor (operand reorder, const extraction) must
// NOT fail the guard — only a semantic drift of the pair must. Includes the
// #825 discriminator half: PI_MODE=print WITHOUT TASK_HEARTBEAT
// (swarm_daemon worker) is NOT a task sub-agent.
test("#285 drift guard: isTaskSubAgent reads the marker pair the dispatchers force (behavioral, #483)", () => {
  ok(isTaskSubAgent({ TASK_HEARTBEAT: "1", PI_MODE: "print" }), "task-child marker pair → true (builtin-tools injects exactly these, #172/#825)");
  equal(isTaskSubAgent({ PI_MODE: "print" }), false, "PI_MODE=print alone (swarm_daemon worker) is NOT a task sub-agent (#825 discriminator)");
  equal(isTaskSubAgent({ TASK_HEARTBEAT: "1" }), false, "TASK_HEARTBEAT=1 alone is not print mode → false");
  equal(isTaskSubAgent({ TASK_HEARTBEAT: "0", PI_MODE: "print" }), false, "present-but-non-1 TASK_HEARTBEAT value must NOT satisfy the pair (strict === \"1\" on the heartbeat half)");
  equal(isTaskSubAgent({ TASK_HEARTBEAT: "1", PI_MODE: "print", TASK_HEARTBEAT_DISABLE: "1" }), true, "DISABLE flag must NOT affect the discriminator (builtin-tools forces the marker even under DISABLE, #264 P2/P3)");
  equal(isTaskSubAgent({}), false, "clean env → false");
  equal(isTaskSubAgent({ TASK_HEARTBEAT: "1", PI_MODE: "gate" }), false, "non-print PI_MODE value → false");
});

// ── #472 proportionality — content-shape exemption (mechanism a) ──

section("isShapeExemptFile — content-shape exemption (#472 mechanism a)");

test("exempt: docs/CSS/static content classes (top-level + nested docs, all four extensions)", () => {
  const exempt = [
    "docs/README.md",
    "README.md",
    "MEMORY.md",
    "docs/research/x.md",
    "website/index.html",
    "docs/guides/index.html",
    "theme.css",
    "theme.scss",
  ];
  for (const p of exempt) ok(isShapeExemptFile(p), `${p} must be exempt`);
});

test("denylist: ANY file under a build-output segment stays gated (all 4 extensions, any depth)", () => {
  const denied = [
    "public/index.html",
    "dist/bundle.css",
    "build/out.css",
    "website/public/index.html",
    "public/README.md",
    "assets/build/x.md",
  ];
  for (const p of denied) equal(isShapeExemptFile(p), false, `${p} must NOT be exempt (build output)`);
});

test("fail-closed: every other extension + extension-less files keep the gate ON", () => {
  const denied = ["src/app.ts", "Dockerfile", "LICENSE", "package.json", "supabase/migrations/x.sql", "docs/CHANGELOG", "website/README", ""];
  for (const p of denied) equal(isShapeExemptFile(p), false, `${p === "" ? "<empty>" : p} must NOT be exempt`);
});

test("case-insensitive match (path lowercased before compare — macOS default FS)", () => {
  equal(isShapeExemptFile("Public/index.html"), false, "uppercase build segment still denied");
  equal(isShapeExemptFile("DIST/bundle.css"), false, "uppercase build segment still denied");
  ok(isShapeExemptFile("docs/README.md"), "nested docs exempt");
  ok(isShapeExemptFile("README.MD"), "uppercase extension exempt");
});

test("exact-segment boundary: prefix lookalikes (build-guide/, public-assets/, dist-notes/) stay exempt", () => {
  // The build-output denylist matches EXACT path segments (index.ts:
  // "Exact-segment match: `build-guide/` is NOT `build/` and stays exempt").
  // A regression to substring/prefix matching would deny these while every
  // deny-pin above still denies — only an allow-side pin catches it.
  const exempt = [
    "build-guide/README.md",
    "public-assets/theme.css",
    "dist-notes/index.html",
    "docs/guides/build-guide/x.md",
  ];
  for (const p of exempt) ok(isShapeExemptFile(p), `${p} must stay exempt (prefix lookalike, not a build-output segment)`);
});

// ── #472 proportionality — delete-shaped push classification (mechanism b) ──

section("isDeletionPush — delete-shaped push classification (#472 mechanism b)");

// FULL 05-cleanup.md merged-branch cleanup ceremony block — the code body
// between the fences (skills/commit-workflow/workflow/05-cleanup.md:37-53),
// VERBATIM, and the real #470 incident shape: an agent pastes the whole doc
// block as ONE command. Carries full-line `#` comment scaffolding (incl. the
// apostrophe in "session's worktree" — plan D5: full-line comments must never
// poison the quote scan), a backslash-newline continuation, ℹ️/⚠️ echo
// fallbacks, and if/fi blocks. Shared by BOTH predicates so the full-block
// fixture stays in sync across the isDeletionPush and isBareCommitShape
// classification surfaces.
const FULL_05_CLEANUP_BLOCK = `# BRANCH = the merged PR branch — resolve via gh FIRST. Deriving from the current
# branch is ambiguous after the #376 Step C return: an in-main ceremony session
# now sits on main, and \`git branch --show-current\` would target the default
# branch. gh knows the PR's head branch regardless of local checkout state.
BRANCH=$(gh pr view <PR_NUMBER> --json headRefName -q '.headRefName' 2>/dev/null)
[ -n "$BRANCH" ] || BRANCH=$(git branch --show-current)

# Remote delete — server-side, always possible after merge; "remote ref does not
# exist" means deleteBranchOnMerge already removed it = success.
git push origin --delete "$BRANCH" 2>/dev/null \\
  || echo "ℹ️ remote branch $BRANCH already deleted or unavailable"

# Local delete — now safe IF the worktree was removed above (lock released).
# If the worktree removal FAILED, do not fail the ceremony: WARN + leave a teardown note.
if git worktree list --porcelain | grep -q "branch refs/heads/$BRANCH"; then
  echo "⚠️ branch $BRANCH is still checked out in a worktree — local delete deferred."
  echo "   TEARDOWN NOTE: remove the worktree and run: git branch -D $BRANCH"
else
  git branch -D "$BRANCH" 2>&1 || echo "⚠️ local branch $BRANCH not found or could not be deleted — delete manually: git branch -D $BRANCH"
fi`;

// ── #482 — shared drift-guard skip-arm messaging for the THREE guards (01-preflight,
// 05-cleanup, 04-merge-deploy) ──
// Declared here (before the guards that execute at module load) — consts are TDZ until
// initialized; the classifier FUNCTIONS below hoist instead. The deployed message covers
// both soft-skip shapes (rule 2 pi-home location, rule 5 fence-less sibling doc); the
// unknown message is LOUD + fail-closed (rule 6 — a code-only archive must never pass
// silently).
const DRIFT_GUARD_SKIP_DEPLOYED =
  "  ↪ skip (deployed pi-home layout or fence-less sibling doc — doc↔fixture enforcement requires a source checkout, CI, or a fence-carrying doc artifact; comparing against an independently-synced skills pair is meaningless)";
const DRIFT_GUARD_UNKNOWN_WARN =
  "  ⚠️ drift guard layout UNKNOWN (no .git marker, not under the pi home, no CI env, sibling skills doc unresolvable) — this looks like a code-only archive; refusing to pass vacuously (fail-closed). Run from an agent-infra source checkout or an artifact that carries the skills/ tree.";
const DRIFT_GUARD_UNKNOWN_FAIL =
  "drift guard layout UNKNOWN (no .git marker, not under the pi home, no CI env, sibling skills doc unresolvable) — code-only archive must not soft-skip the drift guards; run where the sibling skills doc is present";
// #482: shared 05-ceremony fence marker — SINGLE source of truth, consumed by the guard
// probe (fencePresent), the 05 guard's fence extraction, AND the activation canary
// (triplication drift class #482 removes). ⚠️ Slicing asymmetry: block BODY comparisons
// start at fenceOpen + "```bash\n".length, NOT at marker.length — the marker includes the
// "# BRANCH…" comment LINE, and the FULL_05_CLEANUP_BLOCK body starts AT that comment line.
const DRIFT_GUARD_05_FENCE_MARKER = "```bash\n# BRANCH = the merged PR branch";
// 04-merge-deploy.md Step B remote-delete line — the single classification-relevant line
// of the ceremony (skills/commit-workflow/workflow/04-merge-deploy.md:91), VERBATIM.
// Shared by the TRUE-fixture pin below and the #482 drift guard. Line-only surface: prose
// edits elsewhere in Step B (worktree-defer comments/echoes) must NOT red the guard.
const MERGE_DEPLOY_STEP_B_DELETE = `git push origin --delete "$PR_BRANCH" 2>&1 || echo "⚠️ remote delete failed — delete manually: gh api -X DELETE repos/{owner}/{repo}/git/refs/heads/$PR_BRANCH"`;

test("TRUE: delete-shaped forms (flag either position, :refspec, -d, multi-target, redirects, cd-prefix)", () => {
  const truePins = [
    "git push origin --delete feat/x",
    "git push --delete origin feat/x",
    "git push origin :feat/x",
    "git push origin :refs/heads/feat/x",
    "git push -d origin feat/x",
    "git push origin --delete a b c",
    // 05-cleanup incident literal — real backslash-newline continuation:
    `git push origin --delete "$BRANCH" 2>/dev/null \\
  || echo "remote branch $BRANCH already deleted"`,
    "cd /repo && git push origin --delete feat/x",
    "git push origin :feat/x 2>/dev/null || true",
  ];
  for (const c of truePins) ok(isDeletionPush(c), `must classify pure deletion: ${JSON.stringify(c)}`);
});

test("FALSE: vacuous-truth guard + any content refspec/flag/mixed/chain/commit/gh-op", () => {
  const falsePins = [
    "git push",
    "git push origin",
    "git push origin main",
    "git push -u origin x",
    "git push --force-with-lease origin main",
    "git push origin main --delete foo",
    "git push origin --delete a && git push origin main",
    "git push origin --delete a & git push origin main",
    "git commit -m x && git push origin --delete foo",
    "git push --tags",
    "git push --all",
    "git push --mirror origin",
    "git push origin --delete",
    'git push origin "main"',
    "gh -R daniel-ospina/agent-infra pr merge 5 && git push origin --delete foo",
  ];
  for (const c of falsePins) equal(isDeletionPush(c), false, `must stay gated: ${c}`);
});

test("review P1/P2-1 repros: bare-colon refspec and git-global-flag commit stay gated", () => {
  // P1: bare `:` is git's matching-push fallback (ships content) — must NOT
  // classify as pure deletion; `:$VAR` may expand empty at runtime.
  // P2-1: `-C repo` between git and commit made the old substring scan miss
  // the commit → the -a sweep would ride the docs exemption.
  equal(isDeletionPush("git push origin :"), false, "bare colon = matching-push fallback → ships content (P1 repro)");
  equal(isDeletionPush("git push origin :$BRANCH"), false, ":$VAR may expand empty at runtime");
  equal(isDeletionPush("git -C repo commit -am x && git push origin --delete foo"), false, "commit behind git global flag (P2-1 repro)");
  equal(isDeletionPush('git -c "user.name=A B" commit -am x && git push origin --delete foo'), false, "quoted-value global flag hides the content commit (P2-1 quote-aware repro)");
});

test("prefix-verb pins (classifier flip surface >= interception surface)", () => {
  equal(isDeletionPush("sudo git push origin main"), false, "prefixed content push stays gated");
  equal(isDeletionPush("env GIT_DIR=. git push origin main"), false, "env-prefixed content push stays gated");
  equal(isDeletionPush("nohup git push origin main"), false, "nohup-prefixed content push stays gated");
  ok(isDeletionPush("sudo git push origin --delete feat/x"), "prefix-stripped pure deletion classifies TRUE");
});

test("wrapper containment pins (fail-closed — substring scan symmetric with interception)", () => {
  const wrapperPins = [
    "sh -c 'git push origin main'",
    "sh -c 'git commit -am x' && git push origin --delete foo",
    "! git commit -am x && git push origin --delete foo",
    "! gh pr merge 5 && git push origin --delete foo",
    "! git push origin --delete foo",
    'GIT_SSH_COMMAND="ssh -o BatchMode=yes" git push origin --delete foo',
  ];
  for (const c of wrapperPins) equal(isDeletionPush(c), false, `must stay gated: ${c}`);
});

test("non-interception pins: git branch -D / git worktree remove / gh pr view are NOT git ops", () => {
  equal(isDeletionPush("git branch -D feat/x"), false);
  equal(isGitOp("git branch -D feat/x"), false);
  equal(isDeletionPush("git worktree remove feat/x"), false);
  equal(isGitOp("git worktree remove feat/x"), false);
  equal(isDeletionPush("gh pr view 5"), false);
});

test("04-merge-deploy.md Step B literal (TRUE ceremony fixture — 2>&1 drop, gh api prose, quote-strip)", () => {
  // MERGE_DEPLOY_STEP_B_DELETE — VERBATIM from
  // skills/commit-workflow/workflow/04-merge-deploy.md:91 (declared beside
  // FULL_05_CLEANUP_BLOCK above; pinned by the #482 drift guard below).
  ok(isDeletionPush(MERGE_DEPLOY_STEP_B_DELETE), "merge-deploy ceremony delete must classify pure");
});

test("05-cleanup.md FULL fenced block (TRUE fixture — whole-ceremony paste, #470 shape)", () => {
  // The #470 cleanup incident shape: the FULL 05-cleanup.md merged-branch
  // ceremony pasted as ONE command. Full-line `#` comments — including an
  // apostrophe ("session's worktree") and lines mentioning gated verbs — must
  // not poison the quote scan or flip purity (plan D5 conformance); the only
  // gated op in the block is the remote delete push → TRUE.
  ok(isDeletionPush(FULL_05_CLEANUP_BLOCK), "whole 05-cleanup ceremony block must classify as pure deletion");
});

test("#472 fixture drift guard: FULL_05_CLEANUP_BLOCK == the live 05-cleanup.md ceremony block", () => {
  // #482: gate on the tri-state layout. .git governance is PRIMARY (rule 1); the pi-home
  // LOCATION rule (rule 2) soft-skips deployed copies regardless of doc generation — a
  // deployed pi-home copy whose sibling doc is present AND fenced is still deployed (content
  // alone cannot separate it from a .git-less source artifact); CI + doc-unresolvable (rule
  // 3) and fence-carrying sibling docs (rule 4) route .git-less source artifacts into
  // enforcement — a doc PRESENT under CI defers to its fence state (fence-less → rule 5
  // deployed soft-skip); doc-less code-only archives FAIL CLOSED (unknown, loud).
  const { layout, docText } = probeGuardLayout(
    DRIFT_GUARD_05_FENCE_MARKER, // shared const — single source of truth with the extraction + canary
    "../../skills/commit-workflow/workflow/05-cleanup.md",
    "../../skills/commit-workflow/workflow/05-cleanup.md",
    "skills/commit-workflow/workflow/05-cleanup.md",
  );
  if (layout === "deployed") { console.log(DRIFT_GUARD_SKIP_DEPLOYED); return; }
  if (layout === "unknown") { console.warn(DRIFT_GUARD_UNKNOWN_WARN); ok(false, DRIFT_GUARD_UNKNOWN_FAIL); return; }
  // (doc-null hard-fail arm kept verbatim below — layout "source" does NOT imply the doc
  // exists: rule 1 (doc deleted in a git checkout) and rule 3 (CI + no sibling doc) both
  // reach this arm — the ok(false) below is the fail-closed red for those states, not dead code)
  if (docText === null) {
    ok(false, "05-cleanup.md unreachable from the agent-infra source tree — FULL_05_CLEANUP_BLOCK fixture drift guard would pass vacuously; restore the doc or fix the resolution");
    return;
  }
  // Extract the merged-branch ceremony ```bash fence (starts with the BRANCH
  // resolution line; closes at the ``` after the branch -D fallback).
  const fenceOpen = docText.indexOf(DRIFT_GUARD_05_FENCE_MARKER);
  ok(fenceOpen !== -1, "05-cleanup.md must contain the merged-branch ceremony ```bash fence");
  const bodyStart = fenceOpen + "```bash\n".length;
  const fenceClose = docText.indexOf("\n```", bodyStart);
  ok(fenceClose !== -1, "05-cleanup.md ceremony fence must close");
  equal(
    docText.slice(bodyStart, fenceClose).trimEnd(),
    FULL_05_CLEANUP_BLOCK,
    "05-cleanup.md ceremony block drifted from FULL_05_CLEANUP_BLOCK — re-copy VERBATIM (isDeletionPush and isBareCommitShape both pin it)"
  );
});

test("#482 drift guard: MERGE_DEPLOY_STEP_B_DELETE == the live 04-merge-deploy.md Step B delete line", () => {
  // Mirror the 05-cleanup drift guard for the 04-merge-deploy Step B delete line
  // (the fixture behind the TRUE pin). Same #482 tri-state gate. The anchor is the
  // Step B fence opener (PR_BRANCH resolution line) — UNIQUE to the fence: the
  // spoofable partial prose mention at doc L110 sits AFTER the fence close and is
  // never inside the bounded search region.
  const fenceMarker = "```bash\nPR_BRANCH=$(gh pr view <PR_NUMBER> --json headRefName -q '.headRefName')";
  const { layout, docText } = probeGuardLayout(
    fenceMarker,
    "../../skills/commit-workflow/workflow/04-merge-deploy.md",
    "../../skills/commit-workflow/workflow/04-merge-deploy.md",
    "skills/commit-workflow/workflow/04-merge-deploy.md",
  );
  if (layout === "deployed") { console.log(DRIFT_GUARD_SKIP_DEPLOYED); return; }
  if (layout === "unknown") { console.warn(DRIFT_GUARD_UNKNOWN_WARN); ok(false, DRIFT_GUARD_UNKNOWN_FAIL); return; }
  if (docText === null) {
    ok(false, "04-merge-deploy.md unreachable from the agent-infra source tree — MERGE_DEPLOY_STEP_B_DELETE fixture drift guard would pass vacuously; restore the doc or fix the resolution");
    return;
  }
  const fenceOpen = docText.indexOf(fenceMarker);
  ok(fenceOpen !== -1, "04-merge-deploy.md must contain the Step B ```bash fence (PR_BRANCH anchor)");
  const bodyStart = fenceOpen + fenceMarker.length;
  const fenceClose = docText.indexOf("\n```", bodyStart);
  ok(fenceClose !== -1, "04-merge-deploy.md Step B fence must close");
  // Locate the delete invocation inside the fence by its stable verb+target prefix
  // (a partial edit like 2>&1 → 2>/dev/null must still find the line, then fail the
  // FULL-LINE compare below with a readable diff); compare the full line (trimEnd).
  const delStart = docText.indexOf('git push origin --delete "$PR_BRANCH"', bodyStart);
  ok(delStart !== -1 && delStart < fenceClose, "04-merge-deploy.md Step B fence must contain the remote-delete push line");
  const lineStart = docText.lastIndexOf("\n", delStart) + 1;
  const lineEnd = docText.indexOf("\n", delStart);
  equal(
    docText.slice(lineStart, lineEnd === -1 ? undefined : lineEnd).trimEnd(),
    MERGE_DEPLOY_STEP_B_DELETE,
    "04-merge-deploy.md Step B delete line drifted from MERGE_DEPLOY_STEP_B_DELETE — re-copy VERBATIM (the isDeletionPush TRUE fixture pins it)"
  );
});

test("quote-aware comment strip: multi-line quoted values keep closing quotes (M1/B1/B2 fail-open regressions)", () => {
  // Review M1: a `#`-leading line INSIDE an open multi-line string is DATA, not
  // a comment — a blind pre-regex strip deleted its closing quote, collapsing
  // a REAL content push on the next line into the delete segment → false skip.
  // The strip is quote-aware (scanner state): the closing quote survives, the
  // content push is its own segment → gated.
  const m1 = `git push origin --delete feat/x "note:\n# end of note"\ngit push origin main`;
  equal(isDeletionPush(m1), false, "content push after a multi-line quoted value must stay gated (M1)");
  const m1c = `git push origin --delete feat/x "note: hi"\ngit push origin main`;
  equal(isDeletionPush(m1c), false, "control without #-line still gated");
  // Full-line comment mentioning a gated verb is stripped → does NOT flip purity.
  equal(isDeletionPush(`# then: git commit -am x\ngit push origin --delete feat/x`), true, "full-line comment verb-mention stripped (D5)");
  // Inline comment mentioning a gated verb (after real code) is NOT stripped →
  // flips purity (fail-closed, symmetric with the gate's own substring scan).
  equal(isDeletionPush(`echo hi # then: git commit -am x\ngit push origin --delete feat/x`), false, "inline comment verb-mention stays gated");
  // Review P1-1: a comment line ENDING in a backslash must not swallow the next
  // real line (the old global backslash-newline join erased the comment's
  // terminator; bash terminates comments at the newline regardless of a
  // trailing backslash). Content after a backslash-comment is its own segment.
  equal(isDeletionPush(`git push origin --delete feat/x\n# cleanup note \\\ngit push origin main`), false, "content push after a backslash-terminated comment stays gated (P1-1)");
  equal(isDeletionPush(`git push origin --delete feat/x\n# cleanup note \\\necho done`), true, "delete-only after a backslash-terminated comment stays pure");
  // Review deep-P2 (delete-target absorption): an absorbed "delete target"
  // must be a SINGLE LITERAL shell word — command substitution / backtick /
  // quote-swallowed prose with whitespace must keep the gate ON.
  equal(isDeletionPush(`git push origin --delete feat/x $(git push origin main)`), false, "command substitution after --delete stays gated (deep-P2)");
  equal(isDeletionPush("git push origin --delete feat/x $(git push origin main)"), false, "nested content push in $() stays gated");
  equal(isDeletionPush("git push origin --delete feat/x \u0060git push origin main\u0060"), false, "nested content push in backticks stays gated");
  equal(isDeletionPush(`git push origin --delete feat/x # session's note\ngit push origin main`), false, "inline-comment apostrophe absorbing a content-push line stays gated");
  equal(isDeletionPush(`git push origin --delete "$BRANCH" 2>/dev/null || echo done`), true, "blessed $BRANCH delete ceremony still pure");
});

// ── #472 proportionality — commit-form guard (D2) ──

section("isBareCommitShape — commit-form guard (#472 D2, FORALL semantics, fail-closed whitelist)");

test("BARE → true (whitelist value/boolean flags, cd-prefix, vacuous non-commit)", () => {
  const barePins = [
    "git commit -m x",
    "git commit -m x -s",
    "git commit -S -m x",
    "git commit --message x",
    "git commit -F msg.txt",
    "cd /repo && git commit -m x",
    "git push origin main",
  ];
  for (const c of barePins) ok(isBareCommitShape(c), `must be bare/vacuous: ${c}`);
  // Review 2a-2 (adjudicated known over-gate, NOT a pin): a trailing bash
  // comment (`git commit -m x # docs WIP`) reads as a pathspec → false →
  // VGATE runs. Fail-closed friction; a #-break fix opened fail-open
  // spellings (quoted "#file" pathspec, continued line after inline comment)
  // and was reverted. A QUOTED -m value containing # is consumed by -m and
  // stays bare:
  ok(isBareCommitShape('git commit -m "msg with # hash"'), "quoted -m value with # is bare");
});

test("review P2-1: bare commit behind git global flags is still bare", () => {
  // `-C repo` / `--no-pager` between `git` and `commit` — old substring scan
  // never registered these as commit segments (fail-open via vacuous allow).
  ok(isBareCommitShape("git -C repo commit -m x"), "bare commit behind git global flag");
  ok(isBareCommitShape("git --no-pager commit -m x"), "bare commit behind --no-pager");
});

test("NON-BARE → false (sweeps, attached spellings, pathspec, amend, only-mode, unknown long flags)", () => {
  const nonBarePins = [
    'git commit -am "x"',
    'git commit -am"x"',
    "git commit -amx",
    "git commit --all -m x",
    "git commit -m x path/to/file",
    "git commit --amend -m x",
    "git commit -o code.ts -m x",
    "git commit -m x --only",
    "git commit -mx",
    "git commit -a",
  ];
  for (const c of nonBarePins) equal(isBareCommitShape(c), false, `must NOT be bare: ${c}`);
});

test("review P2-1: -a sweep behind git global flags is non-bare", () => {
  // The whole point of containment: `git -C repo commit -am x` must register
  // as a commit so the -a sweep can never ride a docs-only staged set.
  equal(isBareCommitShape("git -C repo commit -am x"), false, "-a sweep behind git global flag");
  equal(isBareCommitShape('git --no-pager commit -am "x"'), false, "-am behind --no-pager");
});

test("∀ semantics: ANY non-bare commit invocation poisons the whole command", () => {
  equal(isBareCommitShape("git commit -am x && git commit -m y"), false, "first commit sweeps -a");
  equal(isBareCommitShape("git commit -m x && git commit --amend -m y"), false, "second commit amends");
  equal(isBareCommitShape('git commit -m x && git -c "user.name=A B" commit -am y'), false, "second commit behind quoted-value global option sweeps -a");
  ok(isBareCommitShape("git commit -m x && git commit -m y"), "all-bare chain must be allowed");
  // Review P1-1 (FORALL surface): an -a sweep after a backslash-terminated
  // comment line must stay visible (bash terminates comments at the newline;
  // the trailing backslash is inert comment text).
  equal(isBareCommitShape("git commit -m \"base\"\n# note \\\ngit commit -am x"), false, "-a sweep after a backslash-terminated comment stays gated (P1-1)");
});

test("wrapper containment pins (fail-closed — wrapper commits never ride a docs exemption)", () => {
  const wrapperPins = [
    "sh -c 'git commit -am x'",
    "! git commit -am x",
    "sudo -u me git commit -am x",
    "bash -c 'git commit -m x'",
  ];
  for (const c of wrapperPins) equal(isBareCommitShape(c), false, `must NOT be bare: ${c}`);
});

test("05-cleanup.md fenced block (TRUE fixture — no commit invocations → vacuously bare)", () => {
  // FULL_05_CLEANUP_BLOCK — the shared verbatim code body from
  // skills/commit-workflow/workflow/05-cleanup.md:37-53 (defined in the
  // isDeletionPush section above; the identical full-block literal is pinned
  // on BOTH predicates so they cannot drift apart).
  ok(isBareCommitShape(FULL_05_CLEANUP_BLOCK), "ceremony block with no commit invocations is vacuously bare");
});

// ── #489 — auto-sweep commit classification (diff-scope mirror of the D2 guard) ──
// isBareCommitShape decides the content-shape EXEMPTION; commitSweepClass decides the
// DIFF SURFACE. `git commit -a` / `--all` record the tracked WORKING TREE, not just the
// staged index — a gate scoped to `git diff --cached` lets a staged-docs verifier PASS
// unlock a commit that then sweeps dirty, never-verified code (the #489 hole). The
// classifier detects sweep-form commit invocations so the hook can diff `git diff HEAD`
// instead. Values: "sweep" (every head-anchored commit invocation in the command sweeps),
// "mixed" (≥1 sweep + ≥1 non-sweep head-anchored invocation — the non-sweep commit records
// index-only content, so the hook must verify staged ∪ worktree), "none" (no sweep —
// staged/index scope unchanged, #489 T2). Token model mirrors git's parser: required-value
// shorts m/F/C/c/t consume rest-of-cluster or the NEXT token (even dash-leading —
// `git commit -m --amend` is message "--amend", not an amend); optional-value shorts S/u
// consume ATTACHED cluster chars only, never the next token (`-Sa` = gpg keyid a,
// `-uall` = untracked mode all — neither sweeps; `-S -a` DOES sweep); required-value longs
// (--message --file --reedit-message --reuse-message --author --date --template --cleanup
// --fixup --squash --trailer --pathspec-from-file — --encoding is NOT a git commit option,
// verified) consume the next token; scanning continues past positional/pathspec and unknown
// tokens — only `--` (pathspec terminator) and end-of-stream end flag parsing; only
// HEAD-ANCHORED commit invocations classify (wrappers/prose stay "none" — unchanged staged
// scope, no under-gate, residual #539).

section("commitSweepClass — auto-sweep commit classification (#489)");

test("SWEEP → \"sweep\" (single pure-sweep invocation)", () => {
  const pins = [
    "git commit -a",
    "git commit --all -m x",
    "git commit -am x",
    'git commit -am "x"',
    "git commit -amx",                       // -a + -m(x attached)
    "git commit -vam x",                     // -v -a -m(x)
    "git commit -qam x",
    "git -C repo commit -am x",              // sweep behind git global flags (PURE-PREDICATE pin — hook interception gap tracked by #490)
    "git --no-pager commit -am x",
    "git commit --author \"Jane <j@d>\" -a -m x",  // scan continues past required-value longs
    "git commit --date 2024-01-01 -a -m x",
    "git commit --trailer \"A=b\" -a -m x",   // required-value long consumes its value, then -a
    "git commit --message=msg -a -m x",   // ATTACHED-equals value long must NOT swallow the trailing -a
    "git commit --file msg.txt -a",       // value-long member pin (--file)
    "git commit --cleanup strip -a -m x", // value-long member pin (--cleanup)
    "git commit --template tpl.txt -a",   // value-long member pin (--template)
    "git commit --reuse-message HEAD -a", // value-long member pin (--reuse-message)
    "git commit --fixup HEAD -a",         // value-long member pin (--fixup)
    "git commit --squash HEAD -a",        // value-long member pin (--squash)
    "git commit --no-verify -a -m x",     // BOOLEAN long before -a must NOT swallow it (guards against a wrongful SWEEP_VALUE_LONGS addition)
    "git commit --encoding -a -m x",      // --encoding is NOT a git commit option (verified: "error: unknown option `encoding'") — a wrongful SWEEP_VALUE_LONGS addition would swallow the -a → false-negative guard
    "git commit -t tpl.txt -a -m x",
    "git commit -S -a -m x",                  // optional-value -S never consumes the NEXT token → -a is real
    "git commit -u -a -m x",                  // same for -u
    "git commit --amend -a",                  // via the -a arm
    "git commit -a --amend",
    "git commit -a -m x && git commit --all -m y", // every head-anchored invocation sweeps → sweep
    "git commit -am x && git push origin main",    // push segment is vacuous (no commit invocation)
  ];
  for (const c of pins) equal(commitSweepClass(c), "sweep", `must be sweep: ${c}`);
});

test("MIXED (sweep + non-sweep commit in one command) → \"mixed\"", () => {
  const pins = [
    "git commit -m x && git commit --all -m y",   // bare then sweep
    "git commit -am x && git commit -m y",         // sweep then bare
    "git commit -m x f.txt && git commit -a -m y", // pathspec then sweep
    // wrapper/negation commit + head-anchored sweep: the wrapper's bare half ships
    // the whole index (staged-only content invisible to `git diff HEAD`) → must be
    // MIXED (union scope), never pure-sweep (reviewer finding, #489 round 2):
    "sh -c 'git commit -m y' && git commit -am x",
    "! git commit -m y && git commit --all -m x",
    "bash -lc 'git commit -m y' && git commit -am x",
  ];
  for (const c of pins) equal(commitSweepClass(c), "mixed", `must be mixed: ${c}`);
});

test("NONE (bare / amend-alone / pathspec / value-swallowed / vacuous) → \"none\"", () => {
  const pins = [
    "git commit -m x",
    "git commit -m x -s",
    "git commit -F msg.txt",
    "git commit -c HEAD -m x",
    "git commit -C HEAD -m x",
    "git commit -S -m x",
    "git commit -m -a",                  // message "-a"
    "git commit -m --amend",             // message "--amend"
    "git commit --message -a",           // subject "-a"
    "git commit --message --all",
    "git commit --message=--amend",      // attached value
    "git commit --message=-a",           // attached value never scanned for '-a' chars
    "git commit --reuse-message -a",      // required-value long consumes the dash-leading "-a" as its value (membership-observable pin)
    "git commit --file -a",               // same — --file value "-a" (membership-observable pin)
    "git commit --template -a",           // same — --template value "-a" (membership-observable pin)
    "git commit -ma x",                  // -m value "a" + pathspec x
    "git commit -mx",                    // -m value x
    "git commit -Sa -m x",               // -S optional keyid "a" (attached) — NOT a sweep
    "git commit -uall -m x",             // -u optional mode "all" (attached)
    "git commit -ta x",                  // -t template "a" + pathspec x
    "git commit --amend -m x",           // amend alone — index scope (#489 T1 letter; T2)
    "git commit -m x f.txt",             // pathspec
    "git commit -o code.ts -m x",        // only-mode pathspec
    "git commit -m x --only",
    "git commit -m x -- -a",             // `--` pathspec terminator → "-a" is a path, not a flag
    "git commit --all=true",             // invalid attached spelling — not the flag
    "sh -c 'git commit -am x'",          // wrapper — non-head-anchored → none (staged scope, unchanged; #539)
    "! git commit -am x",
    "git push origin main",              // vacuous — no commit invocation
    "gh pr create --body 'git commit -am x'",  // prose — never classified
  ];
  for (const c of pins) equal(commitSweepClass(c), "none", `must be none: ${c}`);
});

// ── #482 — shared drift-guard layout gate (replaces the two-#472-guard isSourceCheckout
// enforce-vs-skip decision). Enforcement target: the agent-infra SOURCE CHECKOUT plus any
// .git-less source artifact OUTSIDE the pi-home layout — CI env with an UNRESOLVABLE
// sibling doc (rule 3), or a sibling skills doc that still carries this guard's fence
// marker (rule 4; a doc present under CI defers to its fence state). A DEPLOYED extension
// copy (~/.pi/agent/extensions/… — the pi agent layout) is identified by LOCATION (module
// under join(homedir(), ".pi", "agent")) — content alone cannot separate it from a .git-less
// source artifact (a deployed skills tree can sync to a fenced rev, making the pair
// content-identical): ALL guards soft-skip there, regardless of doc generation
// (enforcement against the independently-synced pair is meaningless, not drift). A doc-less
// code-only archive (no git, no CI, not pi-home) is UNKNOWN and FAILS CLOSED (never
// silent). ──

type GuardLayout = "source" | "deployed" | "unknown";
interface GuardLayoutProbe {
  gitMarker: boolean;     // .git dir (clone) or file (worktree) above this module
  ci: boolean;            // CI env present (GITHUB_ACTIONS / CI)
  piHomeLayout: boolean;  // module lives under join(homedir(), ".pi", "agent") — deployed copy
  docResolvable: boolean; // sibling skills doc reachable via resolveRepoDoc
  fencePresent: boolean;  // sibling doc contains THIS guard's fence marker
}

// Pure decision core — table-tested exhaustively (32 rows). Rule order (binding — the
// pi-home LOCATION rule beats CI so a deployed copy soft-skips even in a shell that
// inherits CI=true/GITHUB_ACTIONS):
//   1. gitMarker → source          (git governance PRIMARY — fence-removal drift in a real
//                                   checkout still reaches the guards' hard-fail arms; a
//                                   fence-less doc in a git checkout REDS via the structural
//                                   asserts, never reaching rule 5)
//   2. piHomeLayout → deployed     (deployed physical copy — soft-skip unconditionally, any
//                                   doc generation, even under inherited CI env)
//   3. ci && !docResolvable → source   (CI + NO sibling doc — code-only archive under CI
//                                       fails closed on the guards' doc-null arms; never
//                                       under the pi home (rule 2). With a doc PRESENT, CI
//                                       DEFERS to the doc's fence state (rules 4-5): a
//                                       fence-less doc under CI is a pre-#472-generation
//                                       artifact — uncheckable, not a defect)
//   4. docResolvable && fencePresent → source   (.git-less source artifact — #482 headline;
//                                       also the CI+doc+fence tuple — rule 3 needs doc-null)
//   5. docResolvable → deployed    (fence-less doc — pre-#472-generation artifact for 01;
//                                  for 04/05 a fence-less doc means the ceremony block is
//                                  absent — soft-skip is defensible: a missing fence cannot
//                                  be drift-checked; env-independent contract)
//   6. else → unknown              (doc-less code-only archive — LOUD fail-closed)
function classifyGuardLayout(p: GuardLayoutProbe): GuardLayout {
  if (p.gitMarker) return "source";
  if (p.piHomeLayout) return "deployed";
  if (p.ci && !p.docResolvable) return "source";
  if (p.docResolvable && p.fencePresent) return "source";
  if (p.docResolvable) return "deployed";
  return "unknown";
}

function isCIEnv(): boolean {
  return process.env.GITHUB_ACTIONS === "true"
    || (typeof process.env.CI === "string" && process.env.CI.length > 0
        && process.env.CI !== "0" && process.env.CI.toLowerCase() !== "false");
}
function isSourceCheckout(): boolean {
  return existsSync(new URL("../../.git", import.meta.url)); // dir in a clone, file in a worktree
}
function isUnderOrAt(root: string, agentHome: string): boolean {
  // Pure boundary compare: root IS the agent home, or lives under it (exact-match arm
  // covers a module tree AT the agent home — a bare startsWith(agentHome + sep) misses it).
  return root === agentHome || root.startsWith(agentHome + sep);
}
function isPiHomeLayout(agentHomeArg?: string): boolean {
  // Location probe: is this module's AGENT ROOT (= two hops up from the file — the .git
  // sibling that isSourceCheckout probes) the pi agent home? import.meta.url resolves
  // symlinks by default, so a canonical SYMLINKED install reports the real agent-infra path
  // (→ git marker present → source); a physical copy stays under ~/.pi/agent → deployed.
  // new URL("../../", import.meta.url) from …/extensions/verification-gate/index.test.ts
  // resolves to the AGENT ROOT (~/.pi/agent for the deployed copy — EQUAL to agentHome, not
  // strictly under it), so the compare needs isUnderOrAt's exact-match arm.
  // Optional agentHomeArg (review F3, test-only): the module root is immutable in-process,
  // so the classifier-test rows drive the REAL URL/realpath plumbing with synthetic
  // agent-home inputs — default behavior (real homedir()) is unchanged and every existing
  // call site (probeGuardLayout and the canary activation gate — both no-arg) is
  // unaffected.
  try {
    const moduleDir = fileURLToPath(new URL("../../", import.meta.url)); // agent root
    const real = realpathSync(moduleDir);
    const agentHome = realpathSync(agentHomeArg ?? join(homedir(), ".pi", "agent"));
    return isUnderOrAt(real, agentHome);
  } catch { return false; }
}
function resolveRepoDoc(relFromHere: string, ...cwdRels: string[]): string | null {
  const viaUrl = new URL(relFromHere, import.meta.url);
  if (existsSync(viaUrl)) return readFileSync(viaUrl, "utf8");
  for (const rel of cwdRels) {
    if (existsSync(rel)) return readFileSync(rel, "utf8");
  }
  return null;
}

// Real-probe wrapper for ONE guard: resolves the doc FIRST (the fence OR-arm needs the
// doc text pre-decision), then classifies over the guard-specific fence marker. Returns
// the measured PROBE tuple too — the activation canary re-classifies it with gitMarker
// removed to pin rule 4's real wiring in git runs where rule 1 would otherwise shadow it.
// Guard call-sites destructure { layout, docText } — unaffected.
function probeGuardLayout(fenceMarker: string, relFromHere: string, ...cwdRels: string[]): { layout: GuardLayout; docText: string | null; probe: GuardLayoutProbe } {
  const docText = resolveRepoDoc(relFromHere, ...cwdRels);
  const probe: GuardLayoutProbe = {
    gitMarker: isSourceCheckout(),
    ci: isCIEnv(),
    piHomeLayout: isPiHomeLayout(),
    docResolvable: docText !== null,
    fencePresent: docText !== null && docText.includes(fenceMarker),
  };
  return { layout: classifyGuardLayout(probe), docText, probe };
}

section("drift-guard layout gate — classifyGuardLayout (#482)");

test("classifyGuardLayout: 32-row decision table — git → source; pi-home → deployed (beats CI/fence/doc); CI+doc-null → source fail-closed; fence-carrying doc → source; fence-less doc → deployed; doc-less → unknown", () => {
  // LITERAL named rows pin the BINDING decisions (a mirror-only table would pass if
  // classifier AND spec changed together): git governance dominance, the pi-home location
  // beats CI + doc generation, the #482 .git-less-source-artifact headline, CI's deferral
  // to a present doc's fence state, fence-less doc → deployed, doc-less → unknown.
  equal(classifyGuardLayout({ gitMarker: true, ci: false, piHomeLayout: false, docResolvable: false, fencePresent: false }), "source",
    "git marker alone → source (governance PRIMARY — a doc-less git checkout still reaches the guards' doc-null hard-fail arms)");
  equal(classifyGuardLayout({ gitMarker: true, ci: true, piHomeLayout: true, docResolvable: true, fencePresent: true }), "source",
    "git marker dominates every other signal (source worktree in CI, even under a pi-home-shaped path)");
  equal(classifyGuardLayout({ gitMarker: false, ci: true, piHomeLayout: true, docResolvable: true, fencePresent: true }), "deployed",
    "pi-home LOCATION beats inherited CI env (a deployed copy must soft-skip even in a shell exporting CI=true)");
  equal(classifyGuardLayout({ gitMarker: false, ci: false, piHomeLayout: true, docResolvable: true, fencePresent: true }), "deployed",
    "pi-home beats the fence (deployed fenced 04/05 pair → soft-skip, not enforce)");
  equal(classifyGuardLayout({ gitMarker: false, ci: false, piHomeLayout: true, docResolvable: false, fencePresent: false }), "deployed",
    "pi-home with a MISSING sibling doc is still deployed → green (never a spurious unknown-red)");
  equal(classifyGuardLayout({ gitMarker: false, ci: false, piHomeLayout: false, docResolvable: true, fencePresent: true }), "source",
    "#482 headline: .git-less SOURCE ARTIFACT outside pi-home with a fence-carrying doc → source (enforce)");
  equal(classifyGuardLayout({ gitMarker: false, ci: true, piHomeLayout: false, docResolvable: true, fencePresent: true }), "source",
    "CI + fence-carrying doc → source (rule 4 — rule 3 needs doc-null; a vendored fenced artifact under CI enforces)");
  equal(classifyGuardLayout({ gitMarker: false, ci: true, piHomeLayout: false, docResolvable: true, fencePresent: false }), "deployed",
    "CI + FENCE-LESS doc → deployed (rule 5 — CI defers to the doc's fence state; a pre-#472 fence-less doc under CI soft-skips like any other)");
  equal(classifyGuardLayout({ gitMarker: false, ci: true, piHomeLayout: false, docResolvable: false, fencePresent: false }), "source",
    "CI + doc-NULL code-only archive → source (rule 3 — the guards' doc-null arms red it; fail-closed under CI)");
  equal(classifyGuardLayout({ gitMarker: false, ci: false, piHomeLayout: false, docResolvable: true, fencePresent: false }), "deployed",
    "fence-less doc outside pi-home → deployed informative soft-skip (rule 5 — env-independent contract)");
  equal(classifyGuardLayout({ gitMarker: false, ci: false, piHomeLayout: false, docResolvable: false, fencePresent: false }), "unknown",
    "doc-less code-only archive (no git/CI/pi-home) → unknown (LOUD fail-closed)");
  // Pure boundary-compare rows for the location helper (the location signal is the one
  // discriminator that separates content-identical layouts; its compare must be
  // table-tested with synthetic paths, not only exercised by the manual sim).
  equal(isUnderOrAt("/Users/x/.pi/agent", "/Users/x/.pi/agent"), true, "exact agent-home match (deployed copy agent root)");
  equal(isUnderOrAt("/Users/x/.pi/agent/extensions", "/Users/x/.pi/agent"), true, "under the agent home");
  equal(isUnderOrAt("/Users/x/.pi/agent2", "/Users/x/.pi/agent"), false, "prefix collision (~/.pi/agent2) is NOT under ~/.pi/agent");
  equal(isUnderOrAt("/Users/x/.pi/agentsibling", "/Users/x/.pi/agent"), false, "sibling name is not under the agent home");
  equal(isUnderOrAt("/Users/x/repo", "/Users/x/.pi/agent"), false, "source checkout is not under the agent home");
  // isPiHomeLayout real-plumbing TRUE-branch rows (review F3): the module root is immutable
  // in-process, so these drive the REAL URL/realpath plumbing with SYNTHETIC agent-home
  // inputs — the same philosophy as the isUnderOrAt rows above but one level up (exercising
  // realpathSync + the arg plumbing + the compare). Every committed run of this suite
  // (source checkout, CI with actions/checkout) exercises the default-branch FALSE path; a
  // deployed physical copy (sim B) exercises the default TRUE path and is unpinnable in
  // committed runs — the machine-dependent default assert (equal(isPiHomeLayout(), false))
  // was deliberately dropped (R4-F4); these rows pin the realpath+compare+arg plumbing of
  // the deployed discriminator's TRUE branch instead.
  const moduleRootReal = realpathSync(fileURLToPath(new URL("../../", import.meta.url)));
  equal(isPiHomeLayout(moduleRootReal), true, "exact-match arm: agent home IS the module root (realpath plumbing live, TRUE branch)");
  equal(isPiHomeLayout(dirname(moduleRootReal)), true, "module root under its parent → TRUE branch via realpathSync");
  equal(isPiHomeLayout(realpathSync(join(moduleRootReal, "extensions"))), false, "existing child of the module root as agent home → not an ancestor → false via the real compare (extensions/ always exists where this suite runs)");
  equal(isPiHomeLayout(join(moduleRootReal, "__no_such_dir__")), false, "nonexistent agent-home arg → realpathSync throws → catch arm returns false");
  // isCIEnv pure env-parsing rows (review F8) — mirror the isUnderOrAt literal-row pattern
  // on the pure env-parse surface (GITHUB_ACTIONS === "true" wins outright; CI parses as
  // truthy = length>0, not "0", not case-insensitive "false"). Exact save/restore of the
  // two vars (presence + value): the harness is synchronous/sequential so mid-test mutation
  // is safe, but the tail ALWAYS restores so subsequent suite sections see the original env.
  const hadGA = Object.prototype.hasOwnProperty.call(process.env, "GITHUB_ACTIONS");
  const hadCI = Object.prototype.hasOwnProperty.call(process.env, "CI");
  const savedGA = process.env.GITHUB_ACTIONS;
  const savedCI = process.env.CI;
  const setEnv = (ga: string | undefined, ci: string | undefined): void => {
    if (ga === undefined) delete process.env.GITHUB_ACTIONS; else process.env.GITHUB_ACTIONS = ga;
    if (ci === undefined) delete process.env.CI; else process.env.CI = ci;
  };
  try {
    setEnv("true", undefined);
    equal(isCIEnv(), true, "GITHUB_ACTIONS=true, CI unset → true");
    setEnv(undefined, "");
    equal(isCIEnv(), false, "GITHUB_ACTIONS unset, CI=\"\" → false (empty string is not a CI marker)");
    setEnv(undefined, undefined);
    equal(isCIEnv(), false, "GITHUB_ACTIONS unset, CI unset → false");
    setEnv(undefined, "0");
    equal(isCIEnv(), false, "GITHUB_ACTIONS unset, CI=\"0\" → false");
    setEnv(undefined, "false");
    equal(isCIEnv(), false, "GITHUB_ACTIONS unset, CI=\"false\" → false");
    setEnv(undefined, "FALSE");
    equal(isCIEnv(), false, "GITHUB_ACTIONS unset, CI=\"FALSE\" → false (case-insensitive)");
    setEnv(undefined, "False");
    equal(isCIEnv(), false, "GITHUB_ACTIONS unset, CI=\"False\" → false (case-insensitive)");
    setEnv(undefined, "1");
    equal(isCIEnv(), true, "GITHUB_ACTIONS unset, CI=\"1\" → true");
    setEnv(undefined, "true");
    equal(isCIEnv(), true, "GITHUB_ACTIONS unset, CI=\"true\" → true");
    setEnv(undefined, "TRUE");
    equal(isCIEnv(), true, "GITHUB_ACTIONS unset, CI=\"TRUE\" → true");
    setEnv(undefined, "yes");
    equal(isCIEnv(), true, "GITHUB_ACTIONS unset, CI=\"yes\" → true");
    setEnv("true", "false");
    equal(isCIEnv(), true, "GITHUB_ACTIONS=\"true\" AND CI=\"false\" → true (GITHUB_ACTIONS arm wins)");
  } finally {
    // Restore the original env EXACTLY (presence + value) even if a row above redded —
    // subsequent suite sections must see the original env.
    if (hadGA) process.env.GITHUB_ACTIONS = savedGA; else delete process.env.GITHUB_ACTIONS;
    if (hadCI) process.env.CI = savedCI; else delete process.env.CI;
  }
  // Exhaustive sweep over the 5-boolean probe tuple (32 rows). The expected-value function
  // below mirrors the 6-rule spec — see the LITERAL named rows above this sweep for the
  // binding decisions; the sweep's job is 32-row COVERAGE (classifier ↔ spec divergence on
  // the named rows is caught by the literals, not by this mirror).
  const spec = (gitMarker: boolean, ci: boolean, piHomeLayout: boolean, docResolvable: boolean, fencePresent: boolean): GuardLayout => {
    if (gitMarker) return "source";
    if (piHomeLayout) return "deployed";
    if (ci && !docResolvable) return "source";   // rule 3 — CI + doc-null (doc present ⇒ CI defers to fence state)
    if (docResolvable && fencePresent) return "source";  // rule 4 — .git-less source artifact
    if (docResolvable) return "deployed";         // rule 5 — fence-less doc (pre-#472 artifact)
    return "unknown";                              // rule 6 — code-only archive, fail-closed
  };
  let checked = 0;
  for (const gitMarker of [false, true])
  for (const ci of [false, true])
  for (const piHomeLayout of [false, true])
  for (const docResolvable of [false, true])
  for (const fencePresent of [false, true]) {
    const key = `${gitMarker ? 1 : 0}${ci ? 1 : 0}${piHomeLayout ? 1 : 0}${docResolvable ? 1 : 0}${fencePresent ? 1 : 0}`;
    const want = spec(gitMarker, ci, piHomeLayout, docResolvable, fencePresent);
    equal(classifyGuardLayout({ gitMarker, ci, piHomeLayout, docResolvable, fencePresent }), want,
      `row ${key} (git=${gitMarker}, ci=${ci}, piHome=${piHomeLayout}, doc=${docResolvable}, fence=${fencePresent}) must classify ${want}`);
    checked++;
  }
  equal(checked, 32, "all 32 probe tuples exercised");
});

test("#482 activation canary: drift-guard gate classifies an enforcement run (git marker ∥ CI env) as source and the real probe resolves the fence", () => {
  // Fires only in an ENFORCEMENT layout (git marker present, or CI env outside the pi
  // home) — never reds a legitimate deployed run. Gate: skip when NOT git AND (no CI OR
  // pi-home) — the pi-home arm covers a deployed physical copy running in a shell that
  // inherits CI=true/GITHUB_ACTIONS (classifier rule 2 classifies it deployed; the canary
  // must not contradict the guards' soft-skip). Uses the SAME real probes as the guards
  // (probeGuardLayout), so a wiring regression that routes enforcement layouts into a skip
  // arm (silent drift-coverage death) reds here.
  // Additionally asserts the REAL probe's fence OR-arm preconditions (doc resolved AND
  // fencePresent computed true) so a doc-path or marker-string regression in the fence arm
  // is caught in every git/CI run whose doc resolves — not just by the synthetic table
  // test (enforcement layouts with NO resolvable doc log a consistency line instead — the
  // guards' doc-null arms own the red).
  if (!isSourceCheckout() && (!isCIEnv() || isPiHomeLayout())) {
    console.log("  ↪ canary skip (activation gate: no .git marker and no CI env outside the pi home — guards still classify by doc/fence (rules 4-6) and MAY enforce; the canary's asserts fire only on git/CI runs)");
    return;
  }
  const { layout, docText, probe } = probeGuardLayout(
    DRIFT_GUARD_05_FENCE_MARKER, // shared const — single source of truth with the 05 guard
    "../../skills/commit-workflow/workflow/05-cleanup.md",
    "../../skills/commit-workflow/workflow/05-cleanup.md",
    "skills/commit-workflow/workflow/05-cleanup.md",
  );
  // Consistency arm: reachable ONLY when the gate fired, i.e. !git AND ci AND !piHome — a
  // pi-home copy inheriting CI env is already skipped AT THE GATE (the `!isCIEnv() ||
  // isPiHomeLayout()` arm) and never reaches here. The arm agrees+returns ONLY when the
  // deployed verdict rests on a genuinely FENCE-LESS RESOLVABLE sibling doc (rule 5 — CI
  // defers to the doc's fence state; the guards soft-skip in agreement — a consistency
  // outcome, NOT a wiring failure). Both premises are load-bearing: the docText !== null
  // premise keeps a doc-NULL tuple in rule 3's territory — a doc-null deployed verdict is
  // ALWAYS a rule-3 regression (rule 5 requires a resolvable doc; rule 2 is false after
  // the gate) and must fall through so the equal(layout, "source") below reds it; the
  // fencePresent === false premise keeps a FENCED doc misclassified deployed (a
  // rule-4-under-CI regression) from returning here — it falls through so the
  // equal(layout, "source") below reds it too.
  if (!isSourceCheckout() && layout === "deployed" && docText !== null && probe.fencePresent === false) {
    console.log("  ↪ canary consistency: CI env + fence-less sibling doc classifies deployed (rule 5) — guards soft-skip in agreement; no enforcement expected");
    return;
  }
  // Reachable semantics of the equal below, stated honestly: in GIT runs rule 1 forces
  // "source" before rules 2-6, so the assert cannot fail there — its teeth in git runs are
  // the fence-precondition assert and the git-removal pin further down. The equal's genuine
  // failing surface is the GIT-LESS CI run (the #482 headline layout for future tarball
  // runs): there it detects a rule-4 regression (a FENCED doc classified deployed — the
  // consistency arm above refused to return on fencePresent === true) or a rule-3 regression
  // (CI + doc-null classified unknown instead of source — a doc-null tuple can never
  // classify deployed: rule 5 requires the doc to resolve and rule 2 is false after the
  // gate, so deployed is the fenced-doc rule-4 regression's surface and unknown is rule
  // 3's). A deployed/unknown verdict in an enforcement layout means the drift guards are
  // not enforcing.
  equal(layout, "source",
    "drift-guard gate must classify THIS run as source (git marker present — rule 1; git-less CI + doc-null — rule 3; git-less CI + fence-carrying doc — rule 4) — a deployed verdict with a FENCED doc (rule-4 regression) or doc-null (rule-3 regression → unknown), or an unknown verdict, means all three drift guards are not enforcing in an enforcement layout");
  // No-doc arm: an enforcement layout with NO resolvable doc (rule 3 under CI, or rule 1 in
  // a git checkout whose doc is missing) — reaching here means the equal above PASSED, i.e.
  // the doc-null state classified source correctly (a rule-3 regression reds at the equal);
  // the guards' doc-null hard-fail arms own the red; there is no fence to pin.
  if (docText === null) {
    console.log("  ↪ canary consistency: enforcement layout, no resolvable sibling doc — guards' doc-null arms fail closed; fence-precondition asserts skipped (no fence exists)");
    return;
  }
  ok(probe.fencePresent === true,
    "fence OR-arm preconditions must hold when the doc resolves in an enforcement layout: the real probe must compute fencePresent=true (either the doc lost its fence — the guards' structural asserts also red it — or a path/marker/tuple-key regression silently disabled the .git-less-source-artifact arm)");
  if (isSourceCheckout() && !probe.piHomeLayout && probe.fencePresent === true) {
    // Git-removal pin (rule-4 real wiring — rule 1 would otherwise shadow it in git runs):
    // re-classify THIS run's REAL measured tuple with the .git marker removed — with the
    // doc resolved AND fenced, rules 3-5 must still route it to source via the fence arm
    // (rule 4). The pin's own red surface is a CLASSIFIER-side rule-4 regression on a
    // correctly-measured fenced probe (a fenced doc re-classified deployed or unknown with
    // the git marker removed). A path/marker/tuple-key regression that makes the probe
    // ITSELF fencePresent-falsy (tsx strips types — no typecheck catches it) never reaches
    // this assert: it reds EARLIER at the fence-precondition ok(probe.fencePresent ===
    // true) above, whose message already names the path/marker/tuple-key surface.
    // Gate: skip when the doc is fence-less or missing (the guards red those states via
    // their own correctly-worded arms) or the checkout lives under the pi home (git-removal
    // → rule 2 deployed — exotic dev layout; rule 1 still enforces).
    equal(classifyGuardLayout({ ...probe, gitMarker: false }), "source",
      "removing THIS run's .git marker must still classify source via the fence OR-arm (rule 4) — real-probe wiring pin for the #482 headline layout");
  }
});

// ── #472 — doc drift test: 01-preflight VGATE-SHAPE-RULE fence ↔ exports ──

section("doc drift test — 01-preflight VGATE-SHAPE-RULE fence ↔ exports");

test("#472 drift guard: 01-preflight VGATE-SHAPE-RULE fence == SHAPE_EXEMPT_EXTENSIONS + BUILD_OUTPUT_SEGMENTS", () => {
  // #482: gate on the tri-state layout. .git governance is PRIMARY (rule 1 — a fence-less
  // doc in a git checkout REDS via the structural asserts below); the pi-home LOCATION rule
  // (rule 2) soft-skips deployed copies regardless of doc generation; CI + doc-unresolvable
  // fails closed (rule 3); a .git-less artifact whose sibling doc carries this guard's fence
  // enforces (rule 4); a fence-less doc soft-skips (rule 5 — cannot be drift-checked); a
  // doc-less code-only archive FAILS CLOSED (unknown, loud — rule 6).
  const vgateOpen = "<!-- VGATE-SHAPE-RULE"; // 01 fence opener — LOCAL const, sole source of truth for this test (probe AND parse extraction share it)
  const { layout, docText } = probeGuardLayout(
    vgateOpen,
    "../../skills/commit-workflow/workflow/01-preflight.md",
    "../../skills/commit-workflow/workflow/01-preflight.md",
    "skills/commit-workflow/workflow/01-preflight.md",
  );
  if (layout === "deployed") { console.log(DRIFT_GUARD_SKIP_DEPLOYED); return; }
  if (layout === "unknown") { console.warn(DRIFT_GUARD_UNKNOWN_WARN); ok(false, DRIFT_GUARD_UNKNOWN_FAIL); return; }
  // (doc-null hard-fail arm kept verbatim below — layout "source" does NOT imply the doc
  // exists: rule 1 (doc deleted in a git checkout) and rule 3 (CI + no sibling doc) both
  // reach this arm — the ok(false) below is the fail-closed red for those states, not dead code)
  if (docText === null) {
    ok(false, "01-preflight.md unreachable from the agent-infra source tree — VGATE-SHAPE-RULE drift guard would pass vacuously; restore the doc or fix the resolution");
    return;
  }

  // Extract rows between the opener and closer comment lines.
  const open = docText.indexOf(vgateOpen);
  const close = docText.indexOf("<!-- /VGATE-SHAPE-RULE", open);
  ok(open !== -1, "01-preflight.md must contain the VGATE-SHAPE-RULE opener comment");
  ok(close !== -1 && close > open, "01-preflight.md must contain the VGATE-SHAPE-RULE closer comment");

  const rows = docText
    .slice(open, close)
    .split("\n")
    .map((l) => l.trim())
    .filter((l) => l.startsWith("|"));
  ok(rows.length >= 3, "VGATE-SHAPE-RULE fence must contain a header row, a separator row, and ≥1 data row");
  // Content-validate the separator anchor so a layout edit (stray | line
  // inserted above the table, separator deleted/reworded) fails with a clear
  // structural error instead of leaking `---` tokens into the deepEqual diff.
  ok(/^\|[\s:|-]+\|$/.test(rows[1]),
     `VGATE-SHAPE-RULE fence layout changed — row 1 must be the --- separator: ${rows[1]}`);

  // Header + separator are anchored by POSITION (rows 0-1) — the fence is
  // machine-read, so a cosmetic reword of the header cell must not break the
  // parse. Any data row with ≠2 populated cells FAILS loudly: a malformed or
  // prose row inside the fence is drift and must never be silently ignored.
  const cellSplit = (rawLine: string): string[] =>
    rawLine.split("|").map((c) => c.trim()).filter((c) => c.length > 0);

  const fenceExts = new Set<string>();
  const fenceSegs = new Set<string>();
  for (const rawLine of rows.slice(2)) {
    const cells = cellSplit(rawLine);
    ok(cells.length === 2, `malformed VGATE-SHAPE-RULE data row (must be exactly 2 populated cells): ${rawLine}`);
    if (cells.length !== 2) continue;
    // Data row: col 1 = extension token(s); col 2 = code-span segment tokens.
    // NORMALIZE: strip surrounding backticks from every token, then strip a
    // trailing `/` from segment tokens (`public/` → `public`) for the compare.
    const tokens = (cell: string): string[] =>
      cell.split(/\s+/).map((t) => t.replace(/^`+/, "").replace(/`+$/, "")).filter((t) => t.length > 0);
    for (const ext of tokens(cells[0])) fenceExts.add(ext);
    for (const seg of tokens(cells[1])) fenceSegs.add(seg.replace(/\/+$/, ""));
  }

  const fenceExtList = [...fenceExts].sort();
  const fenceSegList = [...fenceSegs].sort();
  const extExports = [...SHAPE_EXEMPT_EXTENSIONS].sort();
  const segExports = [...BUILD_OUTPUT_SEGMENTS].sort();
  deepEqual(
    fenceExtList,
    extExports,
    `fence extensions {${fenceExtList.join(", ")}} != exports {${extExports.join(", ")}} — 01-preflight.md VGATE-SHAPE-RULE drifted from SHAPE_EXEMPT_EXTENSIONS`
  );
  deepEqual(
    fenceSegList,
    segExports,
    `fence segments {${fenceSegList.join(", ")}} != exports {${segExports.join(", ")}} — 01-preflight.md VGATE-SHAPE-RULE drifted from BUILD_OUTPUT_SEGMENTS`
  );
});

// ── #487: parsePushRefSpecs / resolvePushTier / buildPushRangeDiffCommand ──
// Pure content-push classifier (whole-command, isDeletionPush-section mirror),
// 4-combo tier resolver, and exact-argv builder. Stub-first (Task 2) so the
// suite never ESM-crashes on missing exports — bodies land in Task 3.

section("parsePushRefSpecs — content-push classifier (#487)");

// ── Eligible (content push) pins ──

test("simple explicit-refspec push → eligible", () => {
  const p = parsePushRefSpecs("git push origin main");
  ok(p.eligible === true, "must classify as eligible");
  if (p.eligible) {
    equal(p.remote, "origin");
    equal(p.bare, false);
    deepEqual(p.refspecs, [{ src: "main", dst: "main", colon: false }]);
  }
});

test("-u upstream ceremony spelling → eligible", () => {
  const p = parsePushRefSpecs("git push -u origin feat/487");
  ok(p.eligible === true && p.remote === "origin" && p.bare === false, "-u is whitelisted");
  if (p.eligible) deepEqual(p.refspecs, [{ src: "feat/487", dst: "feat/487", colon: false }]);
});

test("whitelisted flag set (bare-token equality)", () => {
  for (const flag of ["-u", "--set-upstream", "-f", "--force", "--force-with-lease"]) {
    const p = parsePushRefSpecs(`git push origin ${flag} main`);
    ok(p.eligible === true, `${flag} must be whitelisted`);
  }
});

test("remote + no refspecs → bare with remote fixed", () => {
  const p = parsePushRefSpecs("git push origin --force-with-lease");
  ok(p.eligible === true && p.bare === true && p.remote === "origin", "remote-fixed bare");
});

test("no positionals → bare with null remote", () => {
  const p = parsePushRefSpecs("git push --force-with-lease");
  ok(p.eligible === true && p.bare === true && p.remote === null, "config-upstream bare (04-merge-deploy ceremony)");
});

test("colon refspec split → colon: true", () => {
  const p = parsePushRefSpecs("git push origin main:feat");
  ok(p.eligible === true);
  if (p.eligible) deepEqual(p.refspecs, [{ src: "main", dst: "feat", colon: true }]);
});

test("HEAD accepted syntactically on either side", () => {
  const p = parsePushRefSpecs("git push origin HEAD");
  ok(p.eligible === true);
  if (p.eligible) deepEqual(p.refspecs, [{ src: "HEAD", dst: "HEAD", colon: false }]);
  const q = parsePushRefSpecs("git push origin main:HEAD");
  ok(q.eligible === true, "syntax-only: REF SEMANTICS are the resolver's probe job");
});

test("refs/heads/ spelling accepted", () => {
  const p = parsePushRefSpecs("git push origin refs/heads/main:refs/heads/feat");
  ok(p.eligible === true);
  if (p.eligible) deepEqual(p.refspecs, [{ src: "refs/heads/main", dst: "refs/heads/feat", colon: true }]);
});

test("prefix-verb and cd forms normalize (stripSegmentHead)", () => {
  ok(parsePushRefSpecs("sudo git push origin main").eligible === true);
  ok(parsePushRefSpecs("cd /tmp/x && git push origin main").eligible === true);
});

test("refspecs accumulate across multi-push segments", () => {
  const p = parsePushRefSpecs("git push origin a && git push origin b");
  ok(p.eligible === true && p.remote === "origin");
  if (p.eligible) deepEqual(p.refspecs, [
    { src: "a", dst: "a", colon: false },
    { src: "b", dst: "b", colon: false },
  ]);
});

test("bare + explicit-refspec mixing is order-independent → unmappable (review cycle-2: bare-first must not drop refspecs)", () => {
  const bareFirst = parsePushRefSpecs("git push && git push origin main");
  ok(!bareFirst.eligible && bareFirst.reason === "unmappable", "bare-first mixing must null the whole command, never silently drop the explicit refspec");
  const explicitFirst = parsePushRefSpecs("git push origin main && git push");
  ok(!explicitFirst.eligible && explicitFirst.reason === "unmappable", "explicit-first mixing must null identically (order-independent)");
  const remoteBareFirst = parsePushRefSpecs("git push origin --force-with-lease && git push origin main");
  ok(!remoteBareFirst.eligible && remoteBareFirst.reason === "unmappable", "remote-fixed bare + explicit mixing nulls too");
});

// ── Ineligible (fail-closed) pins ──

test("P0 guard: any git commit anywhere (bare, wrapper, chained) → has_commit", () => {
  const a = parsePushRefSpecs("git push origin main && git commit -m x");
  ok(!a.eligible && a.reason === "has_commit", "chained commit flips has_commit");
  const b = parsePushRefSpecs("sh -c 'git push origin main && git commit -am x'");
  ok(!b.eligible && b.reason === "has_commit", "wrapper commit containment (findGitCommit substring)");
  const c = parsePushRefSpecs("git commit -m x");
  ok(!c.eligible && c.reason === "has_commit", "commit-only command → has_commit (else-branch staged scope preserved)");
});

test("gh pr create|merge anywhere → has_gh", () => {
  const p = parsePushRefSpecs("gh pr create --title x && git push origin main");
  ok(!p.eligible && p.reason === "has_gh");
});

test("tag / --all / --tags / --mirror shapes → unmappable", () => {
  ok(parsePushRefSpecs("git push origin refs/tags/v1.0").reason === "unmappable");
  ok(parsePushRefSpecs("git push origin --tags").reason === "unmappable");
  ok(parsePushRefSpecs("git push --all").reason === "unmappable");
  ok(parsePushRefSpecs("git push --mirror origin").reason === "unmappable");
  ok(parsePushRefSpecs("git push origin main:refs/tags/v1.0").reason === "unmappable");
});

test("URL remote → unmappable", () => {
  const p = parsePushRefSpecs("git push git@github.com:o/r.git main");
  ok(!p.eligible && p.reason === "unmappable");
});

test("any non-whitelisted flag → unmappable (attached value included)", () => {
  for (const flag of ["--porcelain", "-q", "--prune", "--force-with-lease=expiry"]) {
    const p = parsePushRefSpecs(`git push origin ${flag} main`);
    ok(!p.eligible && p.reason === "unmappable", `${flag} must be unmappable (fail-closed)`);
  }
});

test("wrapper push (git push at offset > 0, no commit/gh) → wrapper", () => {
  const p = parsePushRefSpecs("sh -c 'git push origin main'");
  ok(!p.eligible && p.reason === "wrapper", "cannot prove shape — fail-closed, symmetric with isDeletionPush");
});

test("delete + content chain → mixed_delete (whole-command rule, scenario 44 legs 2-3)", () => {
  const p = parsePushRefSpecs("git push origin --delete a && git push origin main");
  ok(!p.eligible && p.reason === "mixed_delete", "mixed delete+content nulls the whole command → staged scope");
  const q = parsePushRefSpecs("git push origin --delete a & git push origin main");
  ok(!q.eligible && q.reason === "mixed_delete", "single-& background chain classifies identically");
});

test("pure scaffolding (no gated verb) → no_push", () => {
  const p = parsePushRefSpecs("echo hello");
  ok(!p.eligible && p.reason === "no_push");
});

// ── resolvePushTier 4-combo table ──

section("resolvePushTier — A/B/C decision table (#487)");

test("4-combo table: (T,·)→A, (F,T)→B, (F,F)→C", () => {
  equal(resolvePushTier(true, true), "A");
  equal(resolvePushTier(true, false), "A");
  equal(resolvePushTier(false, true), "B");
  equal(resolvePushTier(false, false), "C");
});

test("never undefined for any input (evaluateMergeScope-style fuzz)", () => {
  const inputs: [boolean, boolean][] = [
    [false, false], [false, true], [true, false], [true, true],
  ];
  for (const [t, b] of inputs) {
    const tier = resolvePushTier(t, b);
    ok(tier === "A" || tier === "B" || tier === "C", `must always return a tier, got ${tier}`);
  }
});

// ── buildPushRangeDiffCommand exact argv pins ──

section("buildPushRangeDiffCommand — exact argv (#487)");

test("tier A emits the 2-dot space form with the FULL tracking-ref base", () => {
  equal(
    buildPushRangeDiffCommand("A", "refs/remotes/origin/main", "feat/487"),
    "git diff --name-only refs/remotes/origin/main feat/487"
  );
});

test("tier B emits the 3-dot form against the origin main base", () => {
  equal(
    buildPushRangeDiffCommand("B", "refs/remotes/origin/main", "feat/487"),
    "git diff --name-only refs/remotes/origin/main...feat/487"
  );
});

test("tier B emits whatever base the resolver chose — NON-ORIGIN base flows through", () => {
  equal(
    buildPushRangeDiffCommand("B", "refs/remotes/upstream/main", "feat/487"),
    "git diff --name-only refs/remotes/upstream/main...feat/487"
  );
});

// ── Results ───────────────────────────────────────────

console.log(`\n=== Results: ${passed} passed, ${failed} failed ===`);
if (failed > 0) {
  console.log("❌ SOME TESTS FAILED");
  process.exit(1);
}
console.log("✅ ALL TESTS PASSED");
