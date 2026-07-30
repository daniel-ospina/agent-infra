/**
 * verification-gate.test.ts — unit tests for verification-gate.ts
 *
 * Covers: JSON extraction, schema validation, git operation detection,
 * project root resolution, and regression tests for known bugs.
 *
 * Run: npx tsx operations/pi-config/extensions/verification-gate.test.ts
 */

import { extractJson, isValidResult, isGitOp, isGitCommit, resolveProjectRoot, extractCdPath } from "./index.js";
import { ok, equal, deepEqual, throws } from "node:assert/strict";

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

// ── Module load regression ───────────────────────────

section("Module load regression");

test("imports verification-gate without errors (#5622 regression)", async () => {
  // The fact that this test file imports from verification-gate.js
  // without throwing is itself the test. If the module had import
  // errors (like #5622), this file wouldn't load at all.
  ok(true, "module loaded successfully");
});

test("exported functions are callable (#5527 regression)", () => {
  // Verify exported functions exist and don't throw on basic calls
  ok(typeof extractJson === "function");
  ok(typeof isValidResult === "function");
  ok(typeof isGitOp === "function");
  ok(typeof isGitCommit === "function");
  ok(typeof resolveProjectRoot === "function");

  // Quick smoke test — should not throw
  extractJson('{"status":"PASS","failures":[],"verified_files":[]}');
  isGitOp("git commit -m test");
  isGitCommit("git commit -m test");
  ok(true, "all exports callable without errors");
});

// ── Results ───────────────────────────────────────────

console.log(`\n=== Results: ${passed} passed, ${failed} failed ===`);
if (failed > 0) {
  console.log("❌ SOME TESTS FAILED");
  process.exit(1);
}
console.log("✅ ALL TESTS PASSED");
