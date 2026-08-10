/**
 * verification-gate.test.ts — unit tests for verification-gate.ts
 *
 * Covers: JSON extraction, schema validation, git operation detection,
 * project root resolution, and regression tests for known bugs.
 *
 * Run: npx tsx extensions/verification-gate.test.ts
 */

import { extractJson, isValidResult, isGitOp, isGitCommit, resolveProjectRoot, extractCdPath, normalizeRegistryPath, mergeVerifiedFiles } from "./index.js";
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

console.log(`\n=== Results: ${passed} passed, ${failed} failed ===`);
if (failed > 0) {
  console.log("❌ SOME TESTS FAILED");
  process.exit(1);
}
console.log("✅ ALL TESTS PASSED");
