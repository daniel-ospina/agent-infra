/**
 * verification-gate.test.ts — unit tests for verification-gate.ts
 *
 * Covers: JSON extraction, schema validation, git operation detection,
 * project root resolution, and regression tests for known bugs.
 *
 * Run: npx tsx extensions/verification-gate.test.ts
 */

import { extractJson, isValidResult, isGitOp, isGitCommit, resolveProjectRoot, resolveMergeRoot, scopeFiles, extractCdPath, normalizeRegistryPath, mergeVerifiedFiles, hashAndMergeFiles, extractRepoFlag, extractGhRepoEnv, extractPrNumber, repoNameFromRemote, evaluateMergeScope, isMergeCommand, mergeCommandWindow, hashMatchesDisk, buildSubAgentBlockMessage, isTaskSubAgent, SHAPE_EXEMPT_EXTENSIONS, BUILD_OUTPUT_SEGMENTS, isShapeExemptFile, isDeletionPush, isBareCommitShape } from "./index.js";
import { createHash } from "node:crypto";
import { ok, equal, deepEqual, throws } from "node:assert/strict";
import { mkdtempSync, symlinkSync, writeFileSync, rmSync, realpathSync, readFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

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
    isShapeExemptFile, isDeletionPush, isBareCommitShape,
  ] as const;
  for (const fn of callables) ok(typeof fn === "function", "export must be callable");
  equal(extractJson('{"status":"PASS","failures":[],"verified_files":[]}')!.status, "PASS", "extractJson smoke");
  equal(isGitOp("git commit -m test"), true, "isGitOp smoke");
  equal(isGitCommit("git commit -m test"), true, "isGitCommit smoke");
  ok(isShapeExemptFile("README.md"), "isShapeExemptFile smoke");
  ok(isDeletionPush("git push origin --delete feat/x"), "isDeletionPush smoke");
  ok(isBareCommitShape("git commit -m x"), "isBareCommitShape smoke");
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
const FULL_05_CLEANUP_BLOCK = `# BRANCH = the merged PR branch (from the session's worktree, or resolve via gh):
BRANCH=$(git branch --show-current)
[ -n "$BRANCH" ] || BRANCH=$(gh pr view <PR_NUMBER> --json headRefName -q '.headRefName')

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
  git branch -D "$BRANCH" 2>&1 || echo "⚠️ local branch $BRANCH could not be deleted — delete manually: git branch -D $BRANCH"
fi`;

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
  // Copied VERBATIM from skills/commit-workflow/workflow/04-merge-deploy.md:91.
  const literal = `git push origin --delete "$PR_BRANCH" 2>&1 || echo "⚠️ remote delete failed — delete manually: gh api -X DELETE repos/{owner}/{repo}/git/refs/heads/$PR_BRANCH"`;
  ok(isDeletionPush(literal), "merge-deploy ceremony delete must classify pure");
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
  // FULL_05_CLEANUP_BLOCK claims VERBATIM fidelity to
  // skills/commit-workflow/workflow/05-cleanup.md but is a hand-maintained
  // copy — a doc edit (e.g. a maintainer adding a content push or a commit
  // invocation to the ceremony) would silently desync the pinned
  // classification surface from the command agents actually run. Mirror the
  // 01-preflight drift guard: enforce from an agent-infra source checkout,
  // soft-skip deployed copies (isSourceCheckout).
  if (!isSourceCheckout()) {
    console.log("  ↪ skip (deployed copy — not an agent-infra source checkout)");
    return;
  }
  const docText = resolveRepoDoc(
    "../../skills/commit-workflow/workflow/05-cleanup.md",
    "../../skills/commit-workflow/workflow/05-cleanup.md",
    "skills/commit-workflow/workflow/05-cleanup.md",
  );
  if (docText === null) {
    ok(false, "05-cleanup.md unreachable from the agent-infra source tree — FULL_05_CLEANUP_BLOCK fixture drift guard would pass vacuously; restore the doc or fix the resolution");
    return;
  }
  // Extract the merged-branch ceremony ```bash fence (starts with the BRANCH
  // resolution line; closes at the ``` after the branch -D fallback).
  const fenceOpen = docText.indexOf("```bash\n# BRANCH = the merged PR branch");
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

// ── Shared doc-resolution for the two #472 drift guards ──
// Enforcement target: the agent-infra SOURCE CHECKOUT. A deployed extension
// copy (~/.pi/agent/extensions/… — the pi agent layout) has no .git marker
// above it, and the skills/ tree next to it is an INDEPENDENTLY-SYNCED
// artifact: doc↔exports enforcement against that pair is meaningless (a doc
// that predates the fence would red-flag as drift). Source runs resolve the
// doc and fail loudly if it is missing or drifted; deployed runs soft-skip.
function isSourceCheckout(): boolean {
  return existsSync(new URL("../../.git", import.meta.url)); // dir in a clone, file in a worktree
}
function resolveRepoDoc(relFromHere: string, ...cwdRels: string[]): string | null {
  const viaUrl = new URL(relFromHere, import.meta.url);
  if (existsSync(viaUrl)) return readFileSync(viaUrl, "utf8");
  for (const rel of cwdRels) {
    if (existsSync(rel)) return readFileSync(rel, "utf8");
  }
  return null;
}

// ── #472 — doc drift test: 01-preflight VGATE-SHAPE-RULE fence ↔ exports ──

section("doc drift test — 01-preflight VGATE-SHAPE-RULE fence ↔ exports");

test("#472 drift guard: 01-preflight VGATE-SHAPE-RULE fence == SHAPE_EXEMPT_EXTENSIONS + BUILD_OUTPUT_SEGMENTS", () => {
  // Enforcement runs only from an agent-infra source checkout (isSourceCheckout
  // — .git marker above this file). Deployed extension copies soft-skip: their
  // sibling skills/ doc is an independently-synced artifact, and comparing this
  // copy's exports against a doc that may simply predate the fence would be a
  // spurious red, not drift detection.
  if (!isSourceCheckout()) {
    console.log("  ↪ skip (deployed copy — not an agent-infra source checkout)");
    return;
  }
  const docText = resolveRepoDoc(
    "../../skills/commit-workflow/workflow/01-preflight.md",
    "../../skills/commit-workflow/workflow/01-preflight.md",
    "skills/commit-workflow/workflow/01-preflight.md",
  );
  if (docText === null) {
    ok(false, "01-preflight.md unreachable from the agent-infra source tree — VGATE-SHAPE-RULE drift guard would pass vacuously; restore the doc or fix the resolution");
    return;
  }

  // Extract rows between the opener and closer comment lines.
  const open = docText.indexOf("<!-- VGATE-SHAPE-RULE");
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

// ── Results ───────────────────────────────────────────

console.log(`\n=== Results: ${passed} passed, ${failed} failed ===`);
if (failed > 0) {
  console.log("❌ SOME TESTS FAILED");
  process.exit(1);
}
console.log("✅ ALL TESTS PASSED");
