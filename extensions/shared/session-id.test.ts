/**
 * session-id.test.ts — unit tests for shared/session-id.ts (#783 Task 1).
 * Run: npx tsx extensions/shared/session-id.test.ts
 *
 * Covers the id grammar (pi's own, re-implemented because assertValidSessionId
 * is not re-exported from the package index), per-spawn id minting, and the
 * 0700 session root (including the pre-existing-0755 case mkdirSync cannot fix).
 */

import {
  assertValidSessionId,
  degradedSessionArgs,
  ensureTaskSessionRoot,
  isValidSessionId,
  mintChildSessionId,
  newChildSession,
  resolveTaskSessionRoot,
  DEFAULT_TASK_SESSION_ROOT,
} from "./session-id.js";
import { ok, equal, notEqual, throws } from "node:assert/strict";
import { chmodSync, mkdtempSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

let passed = 0, failed = 0;
function test(name: string, fn: () => void | Promise<void>) {
  const run = async () => {
    try { await fn(); passed++; console.log(`  ✅ ${name}`); }
    catch (err: any) { failed++; console.log(`  ❌ ${name}: ${err.message}`); }
  };
  run();
}
function section(name: string) { console.log(`\n${name}:`); }

const TMP_DIRS: string[] = [];
function tmpDir(name: string): string {
  const d = mkdtempSync(join(tmpdir(), `sid-${name}-`));
  TMP_DIRS.push(d);
  return d;
}

// ── grammar ──────────────────────────────────────────────────────────────

section("id grammar — mirrors pi's assertValidSessionId (session-manager.js:15)");

test("accepts uuid v4 (the mint) and dot/underscore/hyphen interior", () => {
  ok(isValidSessionId(mintChildSessionId()), "minted uuid is in-grammar");
  ok(isValidSessionId("a"));
  ok(isValidSessionId("a1"));
  ok(isValidSessionId("0192a3f0-1b2c-7def-8abc-0123456789ab"));
  ok(isValidSessionId("A.b_c-D.9"));
});

test("rejects empty / leading / trailing punctuation / separators", () => {
  for (const bad of ["", "-abc", ".abc", "_abc", "abc-", "abc.", "abc_", "a/b", "a b", "a\nb"]) {
    equal(isValidSessionId(bad), false, `rejects ${JSON.stringify(bad)}`);
    let threw = false;
    try { assertValidSessionId(bad); } catch { threw = true; }
    equal(threw, true, `assertValidSessionId throws on ${JSON.stringify(bad)}`);
  }
});

// ── per-spawn minting ────────────────────────────────────────────────────

section("newChildSession — fresh id + dir PER CALL (the fbArgs-as-const defect)");

test("two calls mint distinct ids and distinct --session-dir values", () => {
  const root = "/tmp/task-sessions";
  const a = newChildSession(root);
  const b = newChildSession(root);
  notEqual(a.sessionId, b.sessionId, "ids differ across attempts");
  notEqual(a.dir, b.dir, "session dirs differ across attempts");
  equal(a.args[0], "--session-id");
  equal(a.args[1], a.sessionId);
  equal(a.args[2], "--session-dir");
  equal(a.args[3], join(root, a.sessionId), "dir is keyed on the CHILD id");
  equal(a.args.length, 4, "no --no-session in the happy path");
  ok(!a.args.includes("--no-session"), "fresh session never degrades");
});

test("newChildSession rejects a bad injected id BEFORE returning args", () => {
  let minted = 0;
  throws(
    () => newChildSession("/tmp/x", () => { minted++; return "-not-valid"; }),
    /Session id must be non-empty/,
    "an invalid id fails loudly at the arg-builder boundary",
  );
  equal(minted, 1);
});

test("degradedSessionArgs is a fresh array of the --no-session degrade vector", () => {
  const a = degradedSessionArgs();
  equal(a.length, 1);
  equal(a[0], "--no-session");
  notEqual(a, degradedSessionArgs(), "never a shared mutable constant");
});

// ── session root ─────────────────────────────────────────────────────────

section("task session root — env override + 0700 enforcement");

test("resolveTaskSessionRoot honours TASK_SESSION_ROOT and defaults to ~/.pi/agent/task-sessions", () => {
  equal(resolveTaskSessionRoot({}), DEFAULT_TASK_SESSION_ROOT);
  equal(resolveTaskSessionRoot({ TASK_SESSION_ROOT: "" }), DEFAULT_TASK_SESSION_ROOT);
  equal(resolveTaskSessionRoot({ TASK_SESSION_ROOT: "/tmp/tsr" }), "/tmp/tsr");
  ok(resolveTaskSessionRoot({ TASK_SESSION_ROOT: "~/tsr" }).endsWith("/tsr"), "tilde-expanded");
});

test("ensureTaskSessionRoot creates 0700 and re-chmods a pre-existing 0755 dir", () => {
  const base = tmpDir("root");
  const fresh = join(base, "fresh");
  const st1 = ensureTaskSessionRoot(fresh);
  ok(st1.ok, `fresh root created: ${st1.error ?? ""}`);
  equal(statSync(fresh).mode & 0o777, 0o700, "fresh root is 0700");

  const stale = join(base, "stale");
  ensureTaskSessionRoot(stale);
  chmodSync(stale, 0o755); // simulate an earlier run under a 0755 umask
  equal(statSync(stale).mode & 0o777, 0o755, "precondition: dir is 0755");
  const st2 = ensureTaskSessionRoot(stale);
  ok(st2.ok);
  equal(statSync(stale).mode & 0o777, 0o700, "explicit chmod fixes the pre-existing dir (mkdirSync mode is a no-op there)");
});

test("ensureTaskSessionRoot degrades (ok:false, never throws) when the path is unwritable", () => {
  const base = tmpDir("bad");
  const file = join(base, "not-a-dir");
  writeFileSync(file, "x");
  const st = ensureTaskSessionRoot(join(file, "child"));
  equal(st.ok, false, "unwritable root reports ok:false instead of throwing");
  ok(typeof st.error === "string" && st.error.length > 0, "error surfaced for the payload");
});

// ── Results ─────────────────────────────────────────────

// Wait for async tests
setTimeout(() => {
  for (const d of TMP_DIRS) { try { rmSync(d, { recursive: true, force: true }); } catch {} }
  console.log(`\n=== Results: ${passed} passed, ${failed} failed ===`);
  if (failed > 0) { console.log("❌ SOME TESTS FAILED"); process.exit(1); }
  console.log("✅ ALL TESTS PASSED");
}, 500);
