/**
 * The read-path failure contract of `scripts/tortoise-memory.mjs`
 * (tortoise#3805 / #3832, agent-infra#1182).
 *
 * WHY THIS FILE EXISTS. The `.mjs` client used to report *never configured* as
 * `tortoise_unavailable` and exit 0 in every direction, and its default base URL
 * was the DASHBOARD host while the API lives on `api.premiselabs.co`. A guard
 * for those two properties written as a source-text scan is a false PASS: a
 * behaviour-identical reformat changes the text and must not move the verdict.
 * These tests therefore EXECUTE the real script as a subprocess against a real
 * local HTTP stub and assert the RESOLVED outcome — the process exit code and
 * the base URL the run actually used.
 *
 * The contract, pinned here in both directions:
 *   - `status` (the PROBE):  ok -> exit 0 · can't reach it -> 3 · not set up -> 4
 *   - data subcommands:      report the SAME vocabulary, keep the skip-cleanly
 *                            exit 0 so an absent optional dependency never
 *                            becomes a hard failure (agent-infra#1182)
 *   - an EMPTY store is `ok` (count 0), never `tortoise_unavailable`
 *   - the default base URL is the API host, and a down daemon is NOT the
 *     never-configured case
 *
 * Run: node --test scripts/tortoise-memory.test.mjs
 */
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

import {
  probeExitCode,
  resolveBaseUrl,
  resolveTimeoutMs,
  STATUS_NOT_CONFIGURED,
  STATUS_OK,
  STATUS_UNAVAILABLE,
  EXIT_NOT_CONFIGURED,
  EXIT_OK,
  EXIT_UNAVAILABLE,
  EXIT_USAGE,
} from "./tortoise-memory.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const SCRIPT = path.join(HERE, "tortoise-memory.mjs");
const API_HOST = "https://api.premiselabs.co";

const execFileAsync = promisify(execFile);

/** Start a local stub for the hosted API; returns { server, url }. */
function startStub(handler) {
  return new Promise((resolve) => {
    const server = http.createServer(handler);
    server.listen(0, "127.0.0.1", () => {
      resolve({ server, url: `http://127.0.0.1:${server.address().port}` });
    });
  });
}

/** A stub that answers an EMPTY store (reachable, nothing in it). */
function emptyStoreStub() {
  return startStub((req, res) => {
    res.setHeader("content-type", "application/json");
    if (req.url.startsWith("/v1/team")) {
      res.end(JSON.stringify({ point_count: 0, tier: "free" }));
    } else if (req.url.startsWith("/v1/search")) {
      res.end(JSON.stringify({ count: 0, results: [] }));
    } else if (req.url.startsWith("/v1/points")) {
      res.end(JSON.stringify({ count: 0, points: [] }));
    } else {
      res.end(JSON.stringify({}));
    }
  });
}

/**
 * A stub that ACCEPTS the TCP connection and then never answers. The only way
 * the client can terminate is its own request timeout, so this is the fixture
 * that distinguishes a bounded client from a hanging one.
 */
function silentStub() {
  return new Promise((resolve) => {
    const sockets = new Set();
    const server = net.createServer((socket) => {
      sockets.add(socket);
      socket.on("close", () => sockets.delete(socket));
      // Deliberately write nothing and never end the response.
    });
    server.listen(0, "127.0.0.1", () => {
      resolve({
        server,
        url: `http://127.0.0.1:${server.address().port}`,
        close: () => {
          for (const s of sockets) s.destroy();
          server.close();
        },
      });
    });
  });
}

/**
 * Run the real script in a controlled env; parse the JSON payload.
 *
 * ASYNC on purpose: several tests answer the child from an HTTP stub running in
 * THIS process. A synchronous spawn would block this process's event loop, so the
 * stub could never reply while the parent waited on the child — a real deadlock,
 * and the one that wedged the first run of this suite. `spawn` must yield.
 *
 * `opts.timeout` is a PARENT-SIDE kill, used only to bound a test so an
 * unbounded child fails the assertion instead of hanging the suite. A
 * parent-killed child reports `killed: true` and `code: null` — never a
 * fabricated exit code.
 */
async function run(args, env = {}, script = SCRIPT, opts = {}) {
  const childEnv = {
    PATH: process.env.PATH,
    HOME: process.env.HOME,
    // Deliberately DO NOT inherit TORTOISE_* — the test controls every one.
    ...env,
  };
  let stdout = "";
  let stderr = "";
  let code = null;
  try {
    ({ stdout, stderr } = await execFileAsync(process.execPath, [script, ...args], {
      env: childEnv,
      encoding: "utf8",
      ...(opts.timeout ? { timeout: opts.timeout } : {}),
    }));
    code = 0;
  } catch (e) {
    if (typeof e.code !== "number") {
      if (e.killed === true) {
        return { code: null, payload: null, stdout: e.stdout || "", stderr: e.stderr || "", killed: true };
      }
      throw e; // spawn failure (ENOENT), not an exit code
    }
    code = e.code;
    stdout = e.stdout || "";
    stderr = e.stderr || "";
  }
  let payload = null;
  try {
    payload = JSON.parse(stdout);
  } catch {
    payload = null;
  }
  return { code, payload, stdout, stderr, killed: false };
}

// ── the resolver (executed, not grepped) ────────────────────────────────────

test("default base URL is the API host, never the dashboard", () => {
  assert.equal(resolveBaseUrl({}), API_HOST);
  // Trailing slashes on the override are normalised away.
  assert.equal(resolveBaseUrl({ TORTOISE_BASE_URL: "http://localhost:9000/" }), "http://localhost:9000");
  // The override always wins.
  assert.equal(resolveBaseUrl({ TORTOISE_BASE_URL: "https://api.example.test" }), "https://api.example.test");
});

test("the request timeout is bounded and cannot be disabled by ambient env", () => {
  assert.equal(resolveTimeoutMs({}), 10_000);
  assert.equal(resolveTimeoutMs({ TORTOISE_TIMEOUT_MS: "300" }), 300);
  // Out-of-clamp / non-finite values FALL BACK — never a zero or NaN timeout.
  assert.equal(resolveTimeoutMs({ TORTOISE_TIMEOUT_MS: "0" }), 10_000);
  assert.equal(resolveTimeoutMs({ TORTOISE_TIMEOUT_MS: "-1" }), 10_000);
  assert.equal(resolveTimeoutMs({ TORTOISE_TIMEOUT_MS: "nope" }), 10_000);
  assert.equal(resolveTimeoutMs({ TORTOISE_TIMEOUT_MS: "Infinity" }), 10_000);
  assert.equal(resolveTimeoutMs({ TORTOISE_TIMEOUT_MS: "999999999" }), 10_000);
  // FRACTIONAL values fall back too. `AbortSignal.timeout()` throws
  // `delay … must be an integer`, and in `api()` that throw is caught and mapped
  // to `tortoise_unavailable` — a healthy store reported as down.
  assert.equal(resolveTimeoutMs({ TORTOISE_TIMEOUT_MS: "300.5" }), 10_000);
  assert.equal(resolveTimeoutMs({ TORTOISE_TIMEOUT_MS: "2500.25" }), 10_000);
});

test("a fractional TORTOISE_TIMEOUT_MS does not turn a healthy store into tortoise_unavailable", async () => {
  // Resolver-level proof above; this is the end-to-end shape an operator sees.
  // Only the INTEGER guard keeps a healthy stub green here.
  const { server, url } = await emptyStoreStub();
  try {
    const r = await run(["status"], {
      TORTOISE_API_KEY: "tt_test",
      TORTOISE_BASE_URL: url,
      TORTOISE_TIMEOUT_MS: "300.5",
    });
    assert.equal(r.code, EXIT_OK, `stderr: ${r.stderr}`);
    assert.equal(r.payload.status, STATUS_OK);
    assert.equal(r.payload.point_count, 0);
  } finally {
    server.close();
  }
});

test("the probe exit-code map is the contract", () => {
  assert.equal(probeExitCode(STATUS_OK), EXIT_OK);
  assert.equal(probeExitCode(STATUS_NOT_CONFIGURED), EXIT_NOT_CONFIGURED);
  assert.equal(probeExitCode(STATUS_UNAVAILABLE), EXIT_UNAVAILABLE);
  assert.equal(EXIT_NOT_CONFIGURED, 4);
  assert.equal(EXIT_UNAVAILABLE, 3);
  assert.equal(EXIT_USAGE, 2);
});

// ── RED direction: the three states must be DISTINCT ────────────────────────

test("probe: an EMPTY store is ok (exit 0), not unavailable", async () => {
  const { server, url } = await emptyStoreStub();
  try {
    const r = await run(["status"], { TORTOISE_API_KEY: "tt_test", TORTOISE_BASE_URL: url });
    assert.equal(r.code, EXIT_OK, `stderr: ${r.stderr}`);
    assert.equal(r.payload.status, STATUS_OK);
    assert.equal(r.payload.point_count, 0);
    assert.equal(r.payload.base_url, url);
  } finally {
    server.close();
  }
});

test("probe: a reachable host answering 200 with a non-JSON content-type is tortoise_unavailable, not ok", async () => {
  // The exact false PASS the reviewer reproduced: any HTTP 200 used to read as
  // `{status: ok, available: true}` with no point_count, so a captive portal or
  // the dashboard host at the API address looked healthy.
  //
  // The body is VALID JSON on purpose. An `<html>` body would make `res.json()`
  // throw, so the probe would degrade even with the content-type guard DELETED —
  // that test cannot distinguish the guard from a parse failure. A JSON-parsable
  // body under `text/plain` can: only the content-type guard rejects it (the
  // payload carries a numeric point_count, so no shape check fires either).
  const { server, url } = await startStub((req, res) => {
    res.statusCode = 200;
    res.setHeader("content-type", "text/plain");
    res.end(JSON.stringify({ point_count: 3, tier: "pro" }));
  });
  try {
    const r = await run(["status"], { TORTOISE_API_KEY: "tt_test", TORTOISE_BASE_URL: url });
    assert.equal(r.code, EXIT_UNAVAILABLE, `stderr: ${r.stderr}`);
    assert.equal(r.payload.status, STATUS_UNAVAILABLE);
    assert.notEqual(r.payload.status, STATUS_OK);
    assert.equal(r.payload.point_count, undefined);
  } finally {
    server.close();
  }
});

test("probe: a reachable JSON host with no point_count is tortoise_unavailable, not ok", async () => {
  // Belt-and-braces over the non-JSON case: a JSON 200 that is not a team
  // payload must also degrade, never report `ok` without a point_count.
  const { server, url } = await startStub((req, res) => {
    res.setHeader("content-type", "application/json");
    res.end(JSON.stringify({ hello: "not the API" }));
  });
  try {
    const r = await run(["status"], { TORTOISE_API_KEY: "tt_test", TORTOISE_BASE_URL: url });
    assert.equal(r.code, EXIT_UNAVAILABLE, `stderr: ${r.stderr}`);
    assert.equal(r.payload.status, STATUS_UNAVAILABLE);
    assert.notEqual(r.payload.status, STATUS_OK);
    assert.equal(r.payload.point_count, undefined);
  } finally {
    server.close();
  }
});

test("probe: an UNREACHABLE store is tortoise_unavailable (exit 3)", async () => {
  const r = await run(["status"], { TORTOISE_API_KEY: "tt_test", TORTOISE_BASE_URL: "http://127.0.0.1:1" });
  assert.equal(r.code, EXIT_UNAVAILABLE, `stderr: ${r.stderr}`);
  assert.equal(r.payload.status, STATUS_UNAVAILABLE);
  assert.equal(r.payload.error, STATUS_UNAVAILABLE);
});

test("probe: a host that accepts TCP and never answers is tortoise_unavailable, bounded", async () => {
  // The `unreachable` cases above are all immediate ECONNREFUSED, which cannot
  // distinguish a bounded client from a hanging one. An accept-but-silent host
  // can: without a request timeout the child waits out undici's ~5-minute
  // default and produces NO verdict (the parent-side kill below then fails the
  // assertion rather than hanging the suite).
  const { url, close } = await silentStub();
  try {
    const started = Date.now();
    const r = await run(
      ["status"],
      { TORTOISE_API_KEY: "tt_test", TORTOISE_BASE_URL: url, TORTOISE_TIMEOUT_MS: "300" },
      SCRIPT,
      { timeout: 6000 },
    );
    const elapsed = Date.now() - started;
    assert.equal(r.killed, false, "the child must terminate on its own, not be killed by the test");
    assert.equal(r.code, EXIT_UNAVAILABLE, `stderr: ${r.stderr}`);
    assert.equal(r.payload.status, STATUS_UNAVAILABLE);
    assert.ok(elapsed < 5000, `bounded by the client's own timeout, took ${elapsed}ms`);
  } finally {
    close();
  }
});

test("probe: NEVER CONFIGURED is not_configured (exit 4) — not tortoise_unavailable", async () => {
  const r = await run(["status"], {});
  assert.equal(r.code, EXIT_NOT_CONFIGURED, `stderr: ${r.stderr}`);
  assert.equal(r.payload.status, STATUS_NOT_CONFIGURED);
  assert.equal(r.payload.error, STATUS_NOT_CONFIGURED);
  // The setup gap must not be blamed on the service.
  assert.notEqual(r.payload.status, STATUS_UNAVAILABLE);
});

test("probe: the resolved default base URL is reported when no override is set", async () => {
  // No network is required to see the resolved URL: a never-configured run still
  // reports the address the client would use.
  const r = await run(["status"], {});
  assert.equal(r.payload.base_url, API_HOST);
});

// ── the three states are pairwise distinct at the probe boundary ────────────

test("probe: empty / unreachable / never-configured are three distinct outcomes", async () => {
  const { server, url } = await emptyStoreStub();
  try {
    const empty = await run(["status"], { TORTOISE_API_KEY: "tt_test", TORTOISE_BASE_URL: url });
    const down = await run(["status"], { TORTOISE_API_KEY: "tt_test", TORTOISE_BASE_URL: "http://127.0.0.1:1" });
    const never = await run(["status"], {});
    assert.notEqual(empty.code, down.code);
    assert.notEqual(empty.code, never.code);
    assert.notEqual(down.code, never.code);
    assert.equal(new Set([empty.payload.status, down.payload.status, never.payload.status]).size, 3);
  } finally {
    server.close();
  }
});

// ── data subcommands: same vocabulary, skip-cleanly exit 0 ──────────────────

test("data read: reachable EMPTY store reports ok and exits 0", async () => {
  const { server, url } = await emptyStoreStub();
  try {
    const r = await run(["search", "--query", "anything"], { TORTOISE_API_KEY: "tt_test", TORTOISE_BASE_URL: url });
    assert.equal(r.code, EXIT_OK, `stderr: ${r.stderr}`);
    assert.equal(r.payload.status, STATUS_OK);
    assert.equal(r.payload.count, 0);
    assert.deepEqual(r.payload.results, []);
  } finally {
    server.close();
  }
});

test("data read: a non-JSON content-type 200 degrades to tortoise_unavailable and still skips cleanly", async () => {
  // Same shared `api()` guard as the probe: a data subcommand must not read a
  // captive-portal body as `{count: undefined, results: []}` and report ok.
  //
  // Again the body is VALID JSON under `text/plain` (a well-formed list
  // envelope, so the shape check cannot be what fires) — otherwise `res.json()`
  // would throw and the guard could be deleted with this test still green.
  const { server, url } = await startStub((req, res) => {
    res.statusCode = 200;
    res.setHeader("content-type", "text/plain");
    res.end(JSON.stringify({ count: 1, results: [{ id: "pt_1", content: "prior claim" }] }));
  });
  try {
    const r = await run(["search", "--query", "x"], { TORTOISE_API_KEY: "tt_test", TORTOISE_BASE_URL: url });
    assert.equal(r.code, EXIT_OK); // skip-cleanly is preserved
    assert.equal(r.payload.status, STATUS_UNAVAILABLE);
  } finally {
    server.close();
  }
});

test("data read: a JSON 200 that is not a list envelope degrades to tortoise_unavailable", async () => {
  // `api()` already rejects a non-JSON content-type, but a stub/proxy answering
  // `200 application/json` with a JSON object that is NOT an envelope used to
  // read as `{status: "ok", count: undefined, results: []}` — a healthy-looking
  // EMPTY store, which a skill reads as "first research on this topic". Every
  // data read requires the payload's OWN shape before it may emit `ok`.
  const { server, url } = await startStub((req, res) => {
    res.setHeader("content-type", "application/json");
    res.end(JSON.stringify({ hello: "not the API" }));
  });
  try {
    for (const args of [
      ["search", "--query", "x"],
      ["query-prior-research", "--domain", "x"],
      ["query-strategies"],
      ["query-visions"],
    ]) {
      const r = await run(args, { TORTOISE_API_KEY: "tt_test", TORTOISE_BASE_URL: url });
      assert.equal(r.code, EXIT_OK, `${args[0]} must still skip cleanly (stderr: ${r.stderr})`);
      assert.equal(r.payload.status, STATUS_UNAVAILABLE, `${args[0]} read a non-envelope as ok`);
      assert.notEqual(r.payload.status, STATUS_OK);
    }
  } finally {
    server.close();
  }
});

test("data read: never-configured reports not_configured but still skips cleanly", async () => {
  const r = await run(["search", "--query", "anything"], {});
  assert.equal(r.code, EXIT_OK); // skip-cleanly is preserved (agent-infra#1182)
  assert.equal(r.payload.status, STATUS_NOT_CONFIGURED);
});

test("data read: unreachable reports tortoise_unavailable but still skips cleanly", async () => {
  const r = await run(["search", "--query", "anything"], { TORTOISE_API_KEY: "tt_test", TORTOISE_BASE_URL: "http://127.0.0.1:1" });
  assert.equal(r.code, EXIT_OK);
  assert.equal(r.payload.status, STATUS_UNAVAILABLE);
});

test("data read: a populated store reports ok with the results", async () => {
  const { server, url } = await startStub((req, res) => {
    res.setHeader("content-type", "application/json");
    res.end(JSON.stringify({ count: 1, results: [{ id: "pt_1", content: "prior claim" }] }));
  });
  try {
    const r = await run(["search", "--query", "prior"], { TORTOISE_API_KEY: "tt_test", TORTOISE_BASE_URL: url });
    assert.equal(r.code, EXIT_OK);
    assert.equal(r.payload.status, STATUS_OK);
    assert.equal(r.payload.count, 1);
  } finally {
    server.close();
  }
});

test("usage errors keep exit 2 (argparse-free, but the code is reserved)", async () => {
  const missing = await run(["search"], { TORTOISE_API_KEY: "tt_test" });
  assert.equal(missing.code, EXIT_USAGE);
  const unknown = await run(["definitely-not-a-command"], { TORTOISE_API_KEY: "tt_test" });
  assert.equal(unknown.code, EXIT_USAGE);
});

test("usage errors carry no store-state word (mock and real paths)", async () => {
  // The mock's unknown-command branch used to emit `{status: "tortoise_unavailable"}`
  // at EXIT_USAGE — a USAGE error labelled with a STORE-STATE word. `main` now
  // routes the unknown command through the mock (making the branch reachable),
  // and neither path may name a store state.
  const mocked = await run(["definitely-not-a-command"], { TORTOISE_API_KEY: "tt_test", TORTOISE_MOCK: "1" });
  assert.equal(mocked.code, EXIT_USAGE, `stderr: ${mocked.stderr}`);
  assert.ok(mocked.payload, `expected a JSON usage payload, got: ${JSON.stringify(mocked.stdout)}`);
  assert.equal(mocked.payload.status, undefined);
  assert.equal(mocked.payload.error, "unknown_command");
  assert.doesNotMatch(mocked.stdout, /tortoise_unavailable|not_configured/);

  const real = await run(["definitely-not-a-command"], { TORTOISE_API_KEY: "tt_test" });
  assert.equal(real.code, EXIT_USAGE);
  assert.doesNotMatch(real.stdout, /tortoise_unavailable|not_configured/);
  assert.doesNotMatch(real.stderr, /tortoise_unavailable|not_configured/);
});

// ── usage errors are NEVER labelled with a store state ──────────────────────

test("usage: a --points-json that is not an array is a usage error, never a store state", async () => {
  // Parsing succeeds for all of these, so the OLD code reached `for (const p of
  // points)` and threw "points is not iterable"; the catch-all then reported
  // `tortoise_unavailable` — telling an operator who passed one object instead
  // of an array that the store was DOWN, so they skip instead of fixing the
  // argument. A usage error must emit no `status` at all. None of these reach
  // the network (the throw/OBSERVED gap is local), so no stub is needed.
  for (const bad of ["{}", "null", "5", "true"]) {
    const r = await run(["write-points", "--kind", "statement", "--points-json", bad], { TORTOISE_API_KEY: "tt_test" });
    assert.equal(r.code, EXIT_USAGE, `--points-json ${bad} must be a usage error (stderr: ${r.stderr})`);
    assert.match(r.stderr, /--points-json must be a JSON array/);
    assert.equal(r.payload, null, `--points-json ${bad} must not emit a JSON payload, got: ${r.stdout}`);
    assert.doesNotMatch(r.stdout, /tortoise_unavailable|not_configured/);
  }
});

test("usage: a non-numeric --limit is a usage error, never a store state", async () => {
  // Against a HEALTHY stub: unvalidated, `Number("abc")` is NaN; the request
  // still succeeds, so the run reported `ok` exit 0 — a bad invocation dressed
  // as a healthy read (and, against a non-2xx server, dressed as the store
  // being down).
  const { server, url } = await emptyStoreStub();
  try {
    const r = await run(["search", "--query", "x", "--limit", "abc"], {
      TORTOISE_API_KEY: "tt_test",
      TORTOISE_BASE_URL: url,
    });
    assert.equal(r.code, EXIT_USAGE, `stderr: ${r.stderr}`);
    assert.match(r.stderr, /--limit must be a number/);
    assert.equal(r.payload, null, `expected no JSON payload, got: ${r.stdout}`);
  } finally {
    server.close();
  }
});

test("usage: a non-numeric --confidence is a usage error, never a store state", async () => {
  // `Number("abc")` is NaN; unvalidated it went into the POST body as
  // `confidence: null` and a healthy write reported `ok` exit 0.
  const { server, url } = await startStub((req, res) => {
    res.setHeader("content-type", "application/json");
    res.end(JSON.stringify({ id: "pt_1", content: "c", kind: "statement" }));
  });
  try {
    const r = await run(
      ["write-claim", "--content", "c", "--kind", "statement", "--confidence", "abc"],
      { TORTOISE_API_KEY: "tt_test", TORTOISE_BASE_URL: url },
    );
    assert.equal(r.code, EXIT_USAGE, `stderr: ${r.stderr}`);
    assert.match(r.stderr, /--confidence must be a number/);
    assert.equal(r.payload, null, `expected no JSON payload, got: ${r.stdout}`);
  } finally {
    server.close();
  }
});

// ── entry-point guard: the client RUNS through a symlinked route (#708) ─────
// Platform-independent on purpose. `os.tmpdir()` is `/var/folders` (a symlink
// into `/private/var`) on macOS but a REAL `/tmp` on ubuntu-latest, so the
// existing reformat leg only exercises the guard incidentally and only on macOS.
// Building the fixture under the REALPATH of the temp dir and then symlinking a
// directory ON TOP of it makes the invocation route's only symlink ours on every
// platform — and the raw `import.meta.url === "file://" + process.argv[1]`
// idiom then skips main() and exits 0 with NO output (payload null) instead of
// the not-configured verdict.
test("entry-point guard: `status` runs when invoked through a symlinked ancestor", async () => {
  const realBase = fs.realpathSync(os.tmpdir()); // strip any platform symlink (/var → /private/var)
  const real = fs.mkdtempSync(path.join(realBase, "tortoise-memory-entry-"));
  const linkParent = fs.mkdtempSync(path.join(realBase, "tortoise-memory-entry-link-"));
  const link = path.join(linkParent, "linked");
  fs.copyFileSync(SCRIPT, path.join(real, "tortoise-memory.mjs"));
  // The client imports the shared entry-point guard (`./is-main.mjs`, #708), so
  // the standalone fixture needs it beside it.
  fs.copyFileSync(path.join(HERE, "is-main.mjs"), path.join(real, "is-main.mjs"));
  fs.symlinkSync(real, link, "dir");
  const asInvoked = path.join(link, "tortoise-memory.mjs");
  try {
    // Pin the mechanism: the invocation path really does traverse a symlink, so
    // the fixture cannot silently become a no-op.
    assert.notEqual(asInvoked, fs.realpathSync(asInvoked), "fixture must traverse a symlink");
    const r = await run(["status"], {}, asInvoked);
    assert.equal(r.code, EXIT_NOT_CONFIGURED, `stderr: ${r.stderr}`);
    assert.ok(r.payload, `expected a JSON verdict, got: ${JSON.stringify(r.stdout)}`);
    assert.equal(r.payload.status, STATUS_NOT_CONFIGURED);
    // The guard resolved DEFINITIVELY (realpath match) — it did not merely
    // fail-closed into running, which would mask a regressed comparison.
    assert.doesNotMatch(r.stderr, /\[is-main\]/, "expected a definitive realpath match, not a fail-closed fallback");
  } finally {
    fs.rmSync(real, { recursive: true, force: true });
    fs.rmSync(linkParent, { recursive: true, force: true });
  }
});

// ── GREEN under a behaviour-identical reformat ──────────────────────────────
// The same three states, driven through a REFORMATTED copy of the client. If
// any assertion above were really a source-text scan, these would flip: the
// reformats change the literal spellings a scan would match while the runtime
// values stay byte-identical.

const REFORMATS = {
  "split the canonical literals": (src) =>
    src
      .replaceAll('"https://api.premiselabs.co"', '"https://api.premiselabs" + ".co"')
      .replaceAll('"not_configured"', '"not_" + "configured"')
      .replaceAll('"tortoise_unavailable"', '"tortoise_" + "unavailable"'),
  "strip line comments and collapse blank runs": (src) =>
    src.replace(/^[ \t]*\/\/.*$/gm, "").replace(/\n{3,}/g, "\n\n"),
};

/** The core verdicts, executed against an arbitrary copy of the client. */
async function coreVerdicts(script) {
  const { server, url } = await emptyStoreStub();
  try {
    const empty = await run(["status"], { TORTOISE_API_KEY: "tt_test", TORTOISE_BASE_URL: url }, script);
    const down = await run(["status"], { TORTOISE_API_KEY: "tt_test", TORTOISE_BASE_URL: "http://127.0.0.1:1" }, script);
    const never = await run(["status"], {}, script);
    const search = await run(["search", "--query", "x"], {}, script);
    return {
      empty: { code: empty.code, status: empty.payload.status, point_count: empty.payload.point_count },
      down: { code: down.code, status: down.payload.status },
      never: { code: never.code, status: never.payload.status, base_url: never.payload.base_url },
      search: { code: search.code, status: search.payload.status },
    };
  } finally {
    server.close();
  }
}

test("behaviour-identical reformats keep every verdict (the guard is not a text scan)", async () => {
  const original = fs.readFileSync(SCRIPT, "utf8");
  const baseline = await coreVerdicts(SCRIPT);
  for (const [name, reformat] of Object.entries(REFORMATS)) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "tortoise-memory-reformat-"));
    const copy = path.join(dir, "tortoise-memory.mjs");
    fs.writeFileSync(copy, reformat(original));
    // The client imports the shared entry-point guard (`./is-main.mjs`, #708),
    // so the standalone copy needs it beside it — unchanged, since only the
    // client's own text is what the reformats vary.
    fs.copyFileSync(path.join(HERE, "is-main.mjs"), path.join(dir, "is-main.mjs"));
    try {
      assert.deepEqual(await coreVerdicts(copy), baseline, `reformat "${name}" moved the verdict`);
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  }
});

// ── the skills that READ this client speak the SAME vocabulary ───────────────
// The three-state contract is useless if the skill text tells an agent to act on
// a word the client no longer emits (agent-infra#1182). These are the docs the
// reviewer found still carrying the retired vocabulary (`tortoise unavailable`)
// and a literal `\"` inside an inline code span, which renders verbatim and
// drifts from the other two skills.

const SKILLS_DIR = path.join(HERE, "..", "skills");
const MEMORY_SKILLS = ["research", "define-strategy", "define-vision"];

function readSkill(name) {
  return fs.readFileSync(path.join(SKILLS_DIR, name, "SKILL.md"), "utf8");
}

/**
 * Code spans that render a backslash escape inside a STATUS context.
 *
 * A backslash escape is consumed in markdown PROSE but rendered VERBATIM inside
 * a code span, so `` `status: \"not_configured\"` `` reads to an agent as a
 * literal backslash. The detector is scoped by the SPAN'S OWN CONTENT — a status
 * token — NOT by requiring the literal `` `status: `` prefix, which let a status
 * span without that exact token (`` `\"not_configured\"` ``) slip through. The
 * corpus's own `` `\"` `` escape-sequence documentation carries no status token,
 * so it is not a false positive.
 *
 * Factored out (rather than inlined into the scan below) so a synthetic sample
 * can pin the SCOPING itself; the shipped skills are clean, so a reverted scope
 * would otherwise stay green.
 */
const STATUS_SPAN_TOKEN = /status|not_configured|tortoise_unavailable|\bok\b/;
function backslashEscapedStatusSpans(src) {
  return (src.match(/`[^`\n]*`/g) || []).filter(
    (span) => span.includes('\\"') && STATUS_SPAN_TOKEN.test(span),
  );
}

test("every memory skill names BOTH canonical states, never the retired 'tortoise unavailable'", () => {
  for (const name of MEMORY_SKILLS) {
    const src = readSkill(name);
    assert.ok(src.includes('"not_configured"'), `${name}: missing the quoted "not_configured" state`);
    assert.ok(src.includes('"tortoise_unavailable"'), `${name}: missing the quoted "tortoise_unavailable" state`);
    // CASE-INSENSITIVE: the retired phrasing is a prose phrase, so it survives
    // an `unavailable` sentence at the start of a line. A case-sensitive probe
    // left `skills/research/SKILL.md` (`(skip if Tortoise unavailable)`) green.
    assert.doesNotMatch(src, /\btortoise unavailable\b/i, `${name}: retired 'tortoise unavailable' vocabulary`);
  }
});

test("no memory skill carries backslash-escaped quotes inside a status code span", () => {
  for (const name of MEMORY_SKILLS) {
    const offenders = backslashEscapedStatusSpans(readSkill(name));
    assert.deepEqual(
      offenders,
      [],
      `${name}: escaped quote inside a status code span: ${offenders.join(" ")}`,
    );
  }
});

test("the status-span detector catches an escaped span with NO literal `status:` prefix", () => {
  // The reviewer's scoping gap pinned as a unit: keying on the literal
  // `` `status: `` prefix left an escaped status span WITHOUT that token
  // undetected. Reverting the scope to the prefix match fails here even though
  // the shipped skills are clean.
  assert.deepEqual(backslashEscapedStatusSpans('a `\\"not_configured\\"` b'), ['`\\"not_configured\\"`']);
  assert.deepEqual(backslashEscapedStatusSpans('a `\\"tortoise_unavailable\\"` b'), ['`\\"tortoise_unavailable\\"`']);
  assert.deepEqual(backslashEscapedStatusSpans('a `\\"ok\\"` b'), ['`\\"ok\\"`']);
  // ...and the corpus's own escape-sequence documentation is NOT a status span.
  assert.deepEqual(backslashEscapedStatusSpans('replace `"` with `\\"` before interpolation'), []);
});
