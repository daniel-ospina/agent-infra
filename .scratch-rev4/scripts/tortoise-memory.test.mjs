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
 *   - TOTAL response validation: `ok` requires the ENDPOINT's OWN payload — a
 *     per-endpoint list key (`results` / `points`) whose length matches `count`,
 *     and for a write a created Point with a non-empty string `id`. An `ok` on
 *     any other body is the false PASS this suite exists to stop.
 *   - ONE argument table, applied before any call: a bad flag, a missing value,
 *     a wrong type or a non-`{content}` `--points-json` element is a USAGE error
 *     (exit 2, no `status` field), never a store-state word.
 *   - an ANSWERED 4xx is never `tortoise_unavailable`: 401/403 (the credential
 *     was refused, or lacks scope) is `not_configured`; any other 4xx carries NO
 *     `status` field (the frozen vocabulary has no word for it) — the probe exits
 *     2, a data subcommand keeps exit 0 with `{error: "request_rejected"}`; a 5xx
 *     keeps the outage word.
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
  parseArgs,
  probeExitCode,
  readBodyText,
  resolveBaseUrl,
  resolveTimeoutMs,
  stateStatus,
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
      res.end(JSON.stringify({ point_count: 0, org_id: "org_test", tier: "free" }));
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
 * A stub that answers with response HEADERS, then a PARTIAL body, then DESTROYS
 * the connection. `Content-Length` promises more bytes than are sent, so the
 * client's body read rejects with an untyped `TypeError: terminated`.
 *
 * This is the fixture that separates a TYPED body-read failure from the
 * fail-closed default: the HTTP STATUS is already known when the read fails, so
 * a typed guard must still map it (401/403 -> `not_configured`, 5xx -> outage,
 * non-JSON -> outage) instead of letting the raw throw reach `stateStatus`.
 */
function truncatedStub(head) {
  return new Promise((resolve) => {
    const sockets = new Set();
    const server = net.createServer((socket) => {
      sockets.add(socket);
      socket.on("close", () => sockets.delete(socket));
      socket.once("data", () => {
        // Send the partial head, then abort once the bytes are flushed — a
        // socket that sends headers plus a partial body and then destroys the
        // connection. `Content-Length` still promises the full body.
        socket.write(head, () => socket.destroy());
      });
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

/** A `Content-Length` head promising more bytes than `partial` carries. */
function truncatedHead(status, contentType, partial) {
  return (
    `HTTP/1.1 ${status} X\r\n` +
    `Content-Type: ${contentType}\r\n` +
    `Content-Length: 4096\r\n` +
    `Connection: close\r\n\r\n` +
    partial
  );
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

test("the catch-all status default is fail-closed: an UNEXPECTED throw is tortoise_unavailable, never ok", () => {
  // `api()` now types the malformed-base-URL throw, so this pins the BACKSTOP
  // itself: any throw that is not a `MemoryStateError` must still degrade to
  // `tortoise_unavailable`. Mutating the default to `STATUS_OK` reds this.
  assert.equal(stateStatus(new TypeError("Invalid URL")), STATUS_UNAVAILABLE);
  assert.equal(stateStatus(new Error("anything unforeseen")), STATUS_UNAVAILABLE);
  assert.notEqual(stateStatus(new TypeError("Invalid URL")), STATUS_OK);
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
  // body under `text/plain` can, but ONLY if it would otherwise be ACCEPTED: the
  // body must be a complete `OrgInfoResponse` (`org_id`, `tier`, numeric
  // `point_count`), because a body missing those is rejected by
  // `assertTeamPayload` whether or not the guard exists — which would make this
  // test pass for the wrong reason. So: only the content-type guard can
  // degrade the run below.
  const { server, url } = await startStub((req, res) => {
    res.statusCode = 200;
    res.setHeader("content-type", "text/plain");
    res.end(JSON.stringify({ point_count: 3, org_id: "org_test", tier: "pro" }));
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

test("probe: /v1/team requires the WHOLE OrgInfoResponse shape, not just a numeric point_count", async () => {
  // A `200 {"point_count": 0}` (no `org_id`, no `tier`) is not an
  // `OrgInfoResponse`; reporting `ok` for it would hand back `tier: undefined`,
  // exactly the green verdict on a `undefined` field this contract forbids.
  const bodies = [
    { point_count: 0 },
    { point_count: 0, tier: "free" },
    { point_count: 0, org_id: "org_test" },
    { point_count: 0, org_id: "", tier: "free" },
    { point_count: 0, org_id: "org_test", tier: "" },
    // The `typeof point_count === "number"` clause needs a negative that is
    // otherwise a VALID OrgInfoResponse: without it every body above fails on
    // `org_id`/`tier` anyway, so replacing the clause with `true` stayed green.
    { org_id: "org_test", tier: "free" },
    { point_count: "0", org_id: "org_test", tier: "free" },
    // CYCLE-7: the `typeof org_id === "string"` and `typeof tier === "string"`
    // clauses had NO negative that pinned them. A missing/`undefined` field
    // throws on `.length` and degrades ANYWAY, so deleting either `typeof`
    // clause alone stayed green. A non-string field whose `.length` is truthy
    // (an array) is otherwise a complete OrgInfoResponse and is ACCEPTED once
    // the clause is gone — that is the body that reds it.
    { point_count: 0, org_id: ["org_test"], tier: "free" },
    { point_count: 0, org_id: "org_test", tier: ["free"] },
  ];
  for (const body of bodies) {
    const { server, url } = await startStub((req, res) => {
      res.setHeader("content-type", "application/json");
      res.end(JSON.stringify(body));
    });
    try {
      const r = await run(["status"], { TORTOISE_API_KEY: "tt_test", TORTOISE_BASE_URL: url });
      assert.equal(r.code, EXIT_UNAVAILABLE, `body ${JSON.stringify(body)} must degrade (stderr: ${r.stderr})`);
      assert.equal(r.payload.status, STATUS_UNAVAILABLE, `body ${JSON.stringify(body)}`);
    } finally {
      server.close();
    }
  }
});

test("probe: a 200 application/json with a MALFORMED body is tortoise_unavailable (exit 3) — a TYPED state, not a fallback", async () => {
  // The content-type guard is satisfied and `res.json()` is what fails, so this
  // is the parse half of the same contract: a `content-type: application/json`
  // HEADER is a claim, not a proof. The body is a TRUNCATED OrgInfoResponse on
  // purpose — if it parsed it would be a complete team payload, so nothing but
  // the parse guard can be the cause of the degradation.
  //
  // Unguarded, the raw `SyntaxError` reached `main()`'s catch and took the state
  // word from `stateStatus`'s DEFAULT, so the correct `tortoise_unavailable`
  // rested entirely on that default staying `STATUS_UNAVAILABLE`: mutating it to
  // `STATUS_OK` turned this exact stub into exit 0 `{"status":"ok",...}` — a
  // reachable false PASS no test caught. The MESSAGE assertion is what makes
  // this test RED if the guard is deleted (the fallback would emit the raw
  // SyntaxError text, not this diagnostic).
  const malformed = '{"point_count": 0, "org_id": "org_test", "tier": "free"';
  const { server, url } = await startStub((req, res) => {
    res.statusCode = 200;
    res.setHeader("content-type", "application/json");
    res.end(malformed);
  });
  try {
    const r = await run(["status"], { TORTOISE_API_KEY: "tt_test", TORTOISE_BASE_URL: url });
    assert.equal(r.code, EXIT_UNAVAILABLE, `stderr: ${r.stderr}`);
    assert.equal(r.payload.status, STATUS_UNAVAILABLE);
    assert.equal(r.payload.error, STATUS_UNAVAILABLE);
    assert.notEqual(r.payload.status, STATUS_OK);
    assert.match(r.payload.message, /MALFORMED JSON/);
  } finally {
    server.close();
  }
});

test("probe: a TRUNCATED body is a TYPED verdict, never the fail-closed default", async () => {
  // POST-CAP (agent-infra#1182). Round 9 typed the `res.json()` read; the two
  // `res.text()` reads stayed unguarded. A socket that sends headers plus a
  // PARTIAL body and then destroys the connection makes `res.text()` reject
  // with a raw `TypeError: terminated`. Unguarded that reached `main()`'s catch
  // and took the state word from `stateStatus`'s DEFAULT:
  //   · a truncated 401/403 was `tortoise_unavailable` (exit 3) instead of
  //     folding into `not_configured` (exit 4) — a documented-contract breach;
  //   · with that default flipped to `STATUS_OK`, truncated 401 / 500 /
  //     200-non-JSON ALL became a green `{"status":"ok"}` exit 0.
  // Every body read now goes through ONE best-effort helper, so the STATUS
  // decides the verdict and a truncated body only degrades the diagnostic.
  // These assertions are exactly what the RED-mutation test below reds.

  // A truncated 401/403 is STILL a rejected credential: exit 4, not an outage.
  for (const code of [401, 403]) {
    const { url, close } = await truncatedStub(
      truncatedHead(code, "application/json", '{"detail":"inval'),
    );
    try {
      const r = await run(["status"], { TORTOISE_API_KEY: "tt_test", TORTOISE_BASE_URL: url });
      assert.equal(r.code, EXIT_NOT_CONFIGURED, `truncated ${code} must exit 4 (stderr: ${r.stderr})`);
      assert.equal(r.payload.status, STATUS_NOT_CONFIGURED, `truncated ${code}`);
      // The diagnostic is the typed one, not the raw `terminated`.
      assert.match(r.payload.message, /REFUSED the request/);
      assert.notEqual(r.payload.status, STATUS_UNAVAILABLE);
    } finally {
      close();
    }
  }

  // A truncated 5xx / non-JSON body keeps the outage word — exit 3, never ok.
  for (const [name, status, ct, partial, re] of [
    ["500 json", 500, "application/json", '{"detail":"boom', /HTTP 500/],
    ["503 json", 503, "application/json", '{"detail":"later', /HTTP 503/],
    ["200 text/html", 200, "text/html", "<html>partial", /non-JSON body/],
    // A 2xx JSON body cut mid-write is the read+parse half of the same class.
    ["200 application/json", 200, "application/json", '{"point_count":0,', /could not be read/],
  ]) {
    const { url, close } = await truncatedStub(truncatedHead(status, ct, partial));
    try {
      const r = await run(["status"], { TORTOISE_API_KEY: "tt_test", TORTOISE_BASE_URL: url });
      assert.equal(r.code, EXIT_UNAVAILABLE, `${name} must exit 3 (stderr: ${r.stderr})`);
      assert.equal(r.payload.status, STATUS_UNAVAILABLE, name);
      assert.notEqual(r.payload.status, STATUS_OK, name);
      assert.match(r.payload.message, re, name);
    } finally {
      close();
    }
  }

  // The DATA subcommands share the same reader: the same status words, still
  // at the skip-cleanly exit 0.
  for (const [status, ct, partial, expected] of [
    [401, "application/json", '{"detail":"inval', STATUS_NOT_CONFIGURED],
    [503, "application/json", '{"detail":"later', STATUS_UNAVAILABLE],
  ]) {
    const { url, close } = await truncatedStub(truncatedHead(status, ct, partial));
    try {
      const r = await run(["search", "--query", "x"], {
        TORTOISE_API_KEY: "tt_test",
        TORTOISE_BASE_URL: url,
      });
      assert.equal(r.code, EXIT_OK, `data truncated ${status} keeps exit 0 (stderr: ${r.stderr})`);
      assert.equal(r.payload.status, expected, `data truncated ${status}`);
    } finally {
      close();
    }
  }
});

test("the ONE body reader never throws: a rejecting body read returns the error", async () => {
  // The structural half of the same guard: `readBodyText` is the only place a
  // response body is read, and its contract is to return `{text: null, error}`
  // on a failed read rather than rethrow. Replacing its catch-return with
  // `throw e;` is the RED mutation (see the next test).
  const ok = await readBodyText({ text: async () => "body" });
  assert.deepEqual(ok, { text: "body", error: null });
  const boom = new TypeError("terminated");
  const failed = await readBodyText({
    text: async () => {
      throw boom;
    },
  });
  assert.equal(failed.text, null);
  assert.equal(failed.error, boom);
});

test("the ONE body reader is the ONLY body read (no unguarded read can be added)", () => {
  // A structural tripwire, NOT a verdict guard (behaviour is pinned above):
  // every body read must go through the single helper, so `res.text(` occurs
  // exactly once and `res.json(` not at all. A future `await res.json()` or a
  // second `res.text()` reds this. Comments are stripped first so documenting
  // the pattern does not count.
  const code = fs
    .readFileSync(SCRIPT, "utf8")
    .replace(/\/\*[\s\S]*?\*\//g, "")
    .replace(/^[ \t]*\/\/.*$/gm, "");
  assert.equal((code.match(/\bres\.text\s*\(/g) || []).length, 1, "res.text() must appear only in readBodyText");
  assert.equal((code.match(/\bres\.json\s*\(/g) || []).length, 0, "res.json() must not be used; JSON.parse(readBodyText(...)) instead");
  assert.equal((code.match(/\breadBodyText\s*\(/g) || []).length, 4, "the helper must be defined once and called at all three read sites");
});

test("RED MUTATION: removing the body-read guard AND flipping the default reds every truncated verdict", async () => {
  // Mutation testing, executed: take the shipped client, restore the untyped
  // escape (`throw e;`) and flip `stateStatus`'s default to `STATUS_OK`, then
  // run the SAME truncated-body scenarios. Every one must come out WRONG — the
  // false PASS the integration test above forbids. That is what makes those
  // assertions non-vacuous: if the guard were deleted, they would fail.
  const original = fs.readFileSync(SCRIPT, "utf8");
  const mutatedSrc = original
    .replace("return { text: null, error: e };", "throw e;")
    .replace(
      "return e instanceof MemoryStateError ? e.status : STATUS_UNAVAILABLE;",
      "return e instanceof MemoryStateError ? e.status : STATUS_OK;",
    );
  assert.ok(!mutatedSrc.includes("return { text: null, error: e };"), "the fixture must remove the body-read guard");
  assert.ok(
    mutatedSrc.includes("return e instanceof MemoryStateError ? e.status : STATUS_OK;"),
    "the fixture must flip the fail-closed default",
  );
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "tortoise-memory-mutation-"));
  const copy = path.join(dir, "tortoise-memory.mjs");
  fs.writeFileSync(copy, mutatedSrc);
  fs.copyFileSync(path.join(HERE, "is-main.mjs"), path.join(dir, "is-main.mjs"));
  try {
    for (const [name, status, ct, partial] of [
      ["401", 401, "application/json", '{"detail":"inval'],
      ["403", 403, "application/json", '{"detail":"forb'],
      ["500", 500, "application/json", '{"detail":"boom'],
      ["200 text/html", 200, "text/html", "<html>partial"],
    ]) {
      const { url, close } = await truncatedStub(truncatedHead(status, ct, partial));
      try {
        const r = await run(["status"], { TORTOISE_API_KEY: "tt_test", TORTOISE_BASE_URL: url }, copy);
        // The guard-removed + default-flipped build reports a GREEN store for
        // an unreadable body — exactly the outcome the shipped tests reject.
        assert.equal(r.code, EXIT_OK, `mutated ${name} must be the false PASS (exit 0)`);
        assert.equal(r.payload.status, STATUS_OK, `mutated ${name} must be the false PASS (ok)`);
      } finally {
        close();
      }
    }
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("probe: an UNREACHABLE store is tortoise_unavailable (exit 3)", async () => {
  const r = await run(["status"], { TORTOISE_API_KEY: "tt_test", TORTOISE_BASE_URL: "http://127.0.0.1:1" });
  assert.equal(r.code, EXIT_UNAVAILABLE, `stderr: ${r.stderr}`);
  assert.equal(r.payload.status, STATUS_UNAVAILABLE);
  assert.equal(r.payload.error, STATUS_UNAVAILABLE);
  // The fetch catch's throw is TYPED: the diagnostic names the typed path.
  // Replacing it with `throw e;` leaves the verdict `tortoise_unavailable` via
  // the default (so exit/status stay green) but the message becomes the raw
  // undici error — this assertion is what reds that refactor.
  assert.match(r.payload.message, /cannot reach the Tortoise API at/);
});

test("probe: a MALFORMED base URL is tortoise_unavailable (exit 3), never a healthy store", async () => {
  // `::::` and a scheme-less host both make `new URL()` throw BEFORE any fetch.
  // Built outside every guard that throw was a raw TypeError reaching the
  // catch-all default, so the verdict rested on that default happening to be
  // `tortoise_unavailable`. It must be a typed, self-describing state error.
  for (const base of ["::::", "api.example.test"]) {
    const r = await run(["status"], { TORTOISE_API_KEY: "tt_test", TORTOISE_BASE_URL: base });
    assert.equal(r.code, EXIT_UNAVAILABLE, `base=${base} stderr: ${r.stderr}`);
    assert.equal(r.payload.status, STATUS_UNAVAILABLE, `base=${base}`);
    assert.equal(r.payload.error, STATUS_UNAVAILABLE, `base=${base}`);
    assert.notEqual(r.payload.status, STATUS_OK, `base=${base}`);
    // The diagnostic names the offending address — never a bare "Invalid URL".
    assert.match(r.payload.message, /not a usable API address/, `base=${base}`);
  }
});

test("data: a MALFORMED base URL reports tortoise_unavailable and never ok", async () => {
  for (const args of [
    ["search", "--query", "x"],
    ["query-prior-research", "--domain", "d"],
    ["write-claim", "--content", "c", "--kind", "statement"],
  ]) {
    const r = await run(args, { TORTOISE_API_KEY: "tt_test", TORTOISE_BASE_URL: "::::" });
    assert.equal(r.code, EXIT_OK, `${args[0]} stderr: ${r.stderr}`);
    assert.equal(r.payload.status, STATUS_UNAVAILABLE, args[0]);
    assert.equal(r.payload.error, STATUS_UNAVAILABLE, args[0]);
    assert.notEqual(r.payload.status, STATUS_OK, args[0]);
  }
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
  // The inert host makes the LOCAL set-up guard the ONLY possible source of
  // `not_configured`: with the guard deleted this run reaches a dead host and
  // degrades to `tortoise_unavailable` (exit 3), so the exit-code assertion
  // below is RED. Pointing at the live API let a real 401 masquerade as the
  // guard's verdict, because a 401 also maps to `not_configured`.
  const r = await run(["status"], { TORTOISE_BASE_URL: "http://127.0.0.1:1" });
  assert.equal(r.code, EXIT_NOT_CONFIGURED, `stderr: ${r.stderr}`);
  assert.equal(r.payload.status, STATUS_NOT_CONFIGURED);
  assert.equal(r.payload.error, STATUS_NOT_CONFIGURED);
  // Name the LOCAL reason — not a server response ("REFUSED ... HTTP 401").
  assert.match(r.payload.message, /TORTOISE_API_KEY not set/);
  // The setup gap must not be blamed on the service.
  assert.notEqual(r.payload.status, STATUS_UNAVAILABLE);
});

test("probe: the resolved default base URL is reported when no override is set", async () => {
  // No network is required to see the resolved URL: a never-configured run still
  // reports the address the client would use. This is the one never-configured
  // case that CANNOT carry an inert `TORTOISE_BASE_URL` — that would stop it
  // testing the default — so it pins the LOCAL guard by its message instead: a
  // live-API 401 reads "REFUSED the request", so the assertion below is RED
  // without the guard even though the base_url assertion would still pass.
  const r = await run(["status"], {});
  assert.equal(r.payload.base_url, API_HOST);
  assert.match(r.payload.message, /TORTOISE_API_KEY not set/);
});

// ── the three states are pairwise distinct at the probe boundary ────────────

test("probe: empty / unreachable / never-configured are three distinct outcomes", async () => {
  const { server, url } = await emptyStoreStub();
  try {
    const empty = await run(["status"], { TORTOISE_API_KEY: "tt_test", TORTOISE_BASE_URL: url });
    const down = await run(["status"], { TORTOISE_API_KEY: "tt_test", TORTOISE_BASE_URL: "http://127.0.0.1:1" });
    // Inert host for the never-configured leg too: without the LOCAL guard it
    // would resolve to `tortoise_unavailable` and stop being distinct from
    // `down`, so the pairwise assertions below guard the guard.
    const never = await run(["status"], { TORTOISE_BASE_URL: "http://127.0.0.1:1" });
    assert.match(never.payload.message, /TORTOISE_API_KEY not set/);
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

test("data subcommands: a 200 application/json with a MALFORMED body is tortoise_unavailable, never ok", async () => {
  // The parse half of the guard is SHARED by every command, so a data read or
  // write must degrade on a malformed body exactly as the probe does — never
  // read it as a healthy empty store (`{status: "ok", count: undefined,
  // results: []}`), which a skill reads as "first research on this topic".
  const malformed = '{"count": 1, "results": [';
  const { server, url } = await startStub((req, res) => {
    res.statusCode = 200;
    res.setHeader("content-type", "application/json");
    res.end(malformed);
  });
  try {
    for (const args of [
      ["search", "--query", "x"],
      ["query-prior-research", "--domain", "x"],
      ["query-strategies"],
      ["query-visions"],
      ["write-claim", "--content", "c"],
      ["write-points", "--kind", "statement", "--points-json", '[{"content":"c"}]'],
    ]) {
      const r = await run(args, { TORTOISE_API_KEY: "tt_test", TORTOISE_BASE_URL: url });
      assert.equal(r.code, EXIT_OK, `${args[0]} must still skip cleanly (stderr: ${r.stderr})`);
      assert.equal(r.payload.status, STATUS_UNAVAILABLE, `${args[0]} read a malformed body as ok`);
      assert.notEqual(r.payload.status, STATUS_OK);
      assert.match(r.payload.message, /MALFORMED JSON/, `${args[0]} did not report the typed parse failure`);
    }
  } finally {
    server.close();
  }
});

test("data read: never-configured reports not_configured but still skips cleanly", async () => {
  // Inert host so only the LOCAL guard can produce `not_configured`; a deleted
  // guard would reach the dead host and report `tortoise_unavailable`.
  const r = await run(["search", "--query", "anything"], { TORTOISE_BASE_URL: "http://127.0.0.1:1" });
  assert.equal(r.code, EXIT_OK); // skip-cleanly is preserved (agent-infra#1182)
  assert.equal(r.payload.status, STATUS_NOT_CONFIGURED);
  assert.match(r.payload.message, /TORTOISE_API_KEY not set/);
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

test("the outbound query string carries each subcommand's own params", async () => {
  // Every other stub matches only `startsWith("/v1/search")`, so deleting a
  // `url.searchParams.set` (or sending a wrong key) stayed green. Capture the
  // request URL and assert the exact param map per subcommand — including the
  // ARG table's DEFAULT for `--limit` and `--point-kind`, which is easy to drop.
  // Deterministic and local (a stub, never the network), so this pins the
  // client's OWN outbound contract rather than a server behaviour.
  const reqs = [];
  const { server, url } = await startStub((req, res) => {
    reqs.push(req.url);
    res.setHeader("content-type", "application/json");
    if (req.url.startsWith("/v1/search")) res.end(JSON.stringify({ count: 0, results: [] }));
    else res.end(JSON.stringify({ count: 0, points: [] }));
  });
  const parsed = (raw) => {
    const u = new URL(raw, "http://stub");
    return { path: u.pathname, params: Object.fromEntries(u.searchParams) };
  };
  try {
    const env = { TORTOISE_API_KEY: "tt_test", TORTOISE_BASE_URL: url };
    await run(["search", "--query", "hello", "--limit", "5"], env);
    await run(["query-prior-research", "--domain", "d1"], env);
    await run(["query-strategies"], env);
    await run(["query-visions"], env);
    await run(["query-visions", "--point-kind", "strategy"], env);
    assert.deepEqual(parsed(reqs[0]), { path: "/v1/search", params: { q: "hello", limit: "5" } });
    assert.deepEqual(parsed(reqs[1]), { path: "/v1/search", params: { q: "d1", limit: "10" } });
    assert.deepEqual(parsed(reqs[2]), { path: "/v1/points", params: { kind: "strategy", limit: "50" } });
    assert.deepEqual(parsed(reqs[3]), { path: "/v1/points", params: { kind: "vision", limit: "50" } });
    assert.deepEqual(parsed(reqs[4]), { path: "/v1/points", params: { kind: "strategy", limit: "50" } });
  } finally {
    server.close();
  }
});

// ── TOTAL response validation: every read, both endpoints, empty AND full ────
// The contract sentence is "empty ≠ unavailable". It has to hold for BOTH
// endpoints and EVERY read subcommand — `/v1/points` had zero positive
// coverage, so a `points`-shaped regression there stayed green.

test("data read: EVERY read is ok on an EMPTY store (empty ≠ unavailable on all four reads)", async () => {
  const { server, url } = await emptyStoreStub();
  try {
    for (const args of [
      ["search", "--query", "x"],
      ["query-prior-research", "--domain", "x"],
      ["query-strategies"],
      ["query-visions"],
    ]) {
      const r = await run(args, { TORTOISE_API_KEY: "tt_test", TORTOISE_BASE_URL: url });
      assert.equal(r.code, EXIT_OK, `${args[0]} must exit 0 (stderr: ${r.stderr})`);
      assert.equal(r.payload.status, STATUS_OK, `${args[0]} read an empty store as not-ok`);
      assert.equal(r.payload.count, 0, args[0]);
      assert.deepEqual(r.payload.results, [], args[0]);
    }
  } finally {
    server.close();
  }
});

test("data read: EVERY read is ok on a POPULATED store of its own endpoint's shape", async () => {
  const { server, url } = await startStub((req, res) => {
    res.setHeader("content-type", "application/json");
    if (req.url.startsWith("/v1/search")) {
      res.end(JSON.stringify({ count: 1, results: [{ id: "pt_search", content: "prior claim" }] }));
    } else {
      res.end(JSON.stringify({
        count: 2,
        points: [
          { id: "pt_a", content: "a", kind: "strategy" },
          { id: "pt_b", content: "b", kind: "vision" },
        ],
      }));
    }
  });
  try {
    const search = await run(["search", "--query", "x"], { TORTOISE_API_KEY: "tt_test", TORTOISE_BASE_URL: url });
    assert.equal(search.payload.status, STATUS_OK, `stderr: ${search.stderr}`);
    assert.equal(search.payload.count, 1);
    assert.equal(search.payload.results[0].id, "pt_search");

    for (const args of [["query-strategies"], ["query-visions"]]) {
      const r = await run(args, { TORTOISE_API_KEY: "tt_test", TORTOISE_BASE_URL: url });
      assert.equal(r.payload.status, STATUS_OK, `${args[0]} must be ok on a points envelope (stderr: ${r.stderr})`);
      assert.equal(r.payload.count, 2, args[0]);
      assert.equal(r.payload.results.length, 2, args[0]);
      assert.equal(r.payload.results[0].id, "pt_a", args[0]);
    }
  } finally {
    server.close();
  }
});

test("data read: /v1/points REQUIRES the `points` key — a `results` envelope is NOT a points answer", async () => {
  // CYCLE-3 P1 pinned. `assertReadPayload` used to accept `results` OR `points`
  // at ANY endpoint, so the `points` branch could be deleted (`res.points ||`
  // `[]`) with the suite green while `/v1/points` read a foreign envelope. Only
  // the per-endpoint key rejects this body.
  const { server, url } = await startStub((req, res) => {
    res.setHeader("content-type", "application/json");
    res.end(JSON.stringify({ count: 1, results: [{ id: "pt_1", content: "prior claim" }] }));
  });
  try {
    for (const args of [["query-strategies"], ["query-visions"]]) {
      const r = await run(args, { TORTOISE_API_KEY: "tt_test", TORTOISE_BASE_URL: url });
      assert.equal(r.code, EXIT_OK, `${args[0]} still skips cleanly`);
      assert.equal(r.payload.status, STATUS_UNAVAILABLE, `${args[0]} read a \`results\` body as its own envelope`);
      assert.notEqual(r.payload.status, STATUS_OK);
    }
  } finally {
    server.close();
  }
});

test("data read: /v1/search REQUIRES the `results` key — a `points` envelope is NOT a search answer", async () => {
  const { server, url } = await startStub((req, res) => {
    res.setHeader("content-type", "application/json");
    res.end(JSON.stringify({ count: 1, points: [{ id: "pt_1", content: "prior claim" }] }));
  });
  try {
    for (const args of [["search", "--query", "x"], ["query-prior-research", "--domain", "x"]]) {
      const r = await run(args, { TORTOISE_API_KEY: "tt_test", TORTOISE_BASE_URL: url });
      assert.equal(r.code, EXIT_OK, `${args[0]} still skips cleanly`);
      assert.equal(r.payload.status, STATUS_UNAVAILABLE, `${args[0]} read a \`points\` body as its own envelope`);
    }
  } finally {
    server.close();
  }
});

test("data read: a `count` that does not match the list length is not an envelope", async () => {
  // The other half of the shape: a count that disagrees with the list is a
  // truncated or padded body, not the API's own answer.
  const { server, url } = await startStub((req, res) => {
    res.setHeader("content-type", "application/json");
    if (req.url.startsWith("/v1/search")) {
      res.end(JSON.stringify({ count: 5, results: [{ id: "pt_1", content: "one" }] }));
    } else {
      res.end(JSON.stringify({ count: 0, points: [{ id: "pt_1", content: "one" }] }));
    }
  });
  try {
    for (const args of [["search", "--query", "x"], ["query-strategies"]]) {
      const r = await run(args, { TORTOISE_API_KEY: "tt_test", TORTOISE_BASE_URL: url });
      assert.equal(r.payload.status, STATUS_UNAVAILABLE, `${args[0]} accepted a count/length mismatch`);
    }
  } finally {
    server.close();
  }
});

test("data read: a non-ARRAY body whose `.length` equals `count` is NOT an envelope", async () => {
  // CYCLE-7 P1. `Array.isArray(list)` was unpinned: replacing it with `true`
  // left the suite 59/59 green. A `200 application/json` + `{"count":1,
  // "results":"a"}` is then emitted VERBATIM as `{status:"ok",count:1,
  // results:"a"}` — and `res.count === list.length` cannot stand in for the
  // clause, because a STRING `"a"` also has `.length` 1. A non-array is the
  // exact non-envelope false PASS this validator exists to stop.
  const { server, url } = await startStub((req, res) => {
    res.setHeader("content-type", "application/json");
    if (req.url.startsWith("/v1/search")) {
      res.end(JSON.stringify({ count: 1, results: "a" }));
    } else {
      res.end(JSON.stringify({ count: 1, points: "a" }));
    }
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
      assert.equal(r.payload.status, STATUS_UNAVAILABLE, `${args[0]} read a non-array body as its envelope`);
      assert.notEqual(r.payload.status, STATUS_OK);
    }
  } finally {
    server.close();
  }
});

// ── TOTAL response validation: a WRITE reports ok only for a created Point ──

test("write: a non-API 200 JSON body is NEVER reported as a successful write", async () => {
  // CYCLE-3. Against `200 application/json` + `{"hello":"not the API"}`,
  // `write-claim` returned `{"status":"ok","written":true}` and `write-points`
  // `{"status":"ok","written":1,"results":[…]}` — an agent recording a memory
  // write that never happened. A write may report ok ONLY for a created Point
  // with a non-empty string `id`.
  const { server, url } = await startStub((req, res) => {
    res.setHeader("content-type", "application/json");
    res.end(JSON.stringify({ hello: "not the API" }));
  });
  try {
    const claim = await run(["write-claim", "--content", "c", "--kind", "statement"], {
      TORTOISE_API_KEY: "tt_test",
      TORTOISE_BASE_URL: url,
    });
    assert.equal(claim.code, EXIT_OK);
    assert.equal(claim.payload.status, STATUS_UNAVAILABLE, `stderr: ${claim.stderr}`);
    assert.notEqual(claim.payload.written, true);

    const points = await run(
      ["write-points", "--kind", "statement", "--points-json", '[{"content":"c"}]'],
      { TORTOISE_API_KEY: "tt_test", TORTOISE_BASE_URL: url },
    );
    assert.equal(points.code, EXIT_OK);
    assert.equal(points.payload.status, STATUS_UNAVAILABLE, `stderr: ${points.stderr}`);
    assert.equal(points.payload.written, undefined, "a failed write must not report a written count");
  } finally {
    server.close();
  }
});

test("write: an `id` that is missing, empty, or not a string is not a created Point", async () => {
  for (const body of [
    { content: "c", kind: "statement" },
    { id: "", content: "c", kind: "statement" },
    { id: 7, content: "c", kind: "statement" },
    { id: null, content: "c", kind: "statement" },
  ]) {
    const { server, url } = await startStub((req, res) => {
      res.setHeader("content-type", "application/json");
      res.end(JSON.stringify(body));
    });
    try {
      const r = await run(["write-claim", "--content", "c"], { TORTOISE_API_KEY: "tt_test", TORTOISE_BASE_URL: url });
      assert.equal(r.payload.status, STATUS_UNAVAILABLE, `body ${JSON.stringify(body)} read as a successful write`);
      assert.notEqual(r.payload.written, true);
    } finally {
      server.close();
    }
  }
});

test("write: a created Point (a non-empty string id) reports ok with the id", async () => {
  const { server, url } = await startStub((req, res) => {
    res.setHeader("content-type", "application/json");
    res.end(JSON.stringify({ id: "pt_created", content: "c", kind: "statement" }));
  });
  try {
    const claim = await run(["write-claim", "--content", "c", "--kind", "statement"], {
      TORTOISE_API_KEY: "tt_test",
      TORTOISE_BASE_URL: url,
    });
    assert.equal(claim.code, EXIT_OK);
    assert.equal(claim.payload.status, STATUS_OK, `stderr: ${claim.stderr}`);
    assert.equal(claim.payload.id, "pt_created");
    assert.equal(claim.payload.written, true);
  } finally {
    server.close();
  }
});

test("write: the client sends authoredBy and confidence in the /v1/points body (server drops them today — tortoise#4032)", async () => {
  // The hosted API's `PointCreateBody` declares neither `authoredBy` nor
  // `confidence`, and the route forwards neither, so both are dropped
  // SERVER-SIDE today. That is a server-side question tracked in tortoise#4032,
  // NOT a license for this client to silently stop sending them: deleting
  // either assignment used to leave the whole suite green. This test pins the
  // EXACT body the client actually puts on the wire — the CLIENT's request, not
  // the server's persistence — so neither assignment can be removed or drift
  // unnoticed while #4032 is open. (Do not "fix" this by dropping the fields
  // here; that decision belongs to #4032.)
  const seen = [];
  const { server, url } = await startStub((req, res) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => {
      seen.push({
        method: req.method,
        path: req.url,
        body: JSON.parse(Buffer.concat(chunks).toString("utf8")),
      });
      res.setHeader("content-type", "application/json");
      res.end(JSON.stringify({ id: `pt_${seen.length}`, content: "c", kind: "statement" }));
    });
  });
  try {
    const claim = await run(
      [
        "write-claim",
        "--content",
        "c",
        "--kind",
        "statement",
        "--authored-by",
        "research-skill",
        "--confidence",
        "0.5",
      ],
      { TORTOISE_API_KEY: "tt_test", TORTOISE_BASE_URL: url },
    );
    assert.equal(claim.code, EXIT_OK, `stderr: ${claim.stderr}`);
    assert.equal(claim.payload.status, STATUS_OK, `stderr: ${claim.stderr}`);

    const points = await run(
      [
        "write-points",
        "--kind",
        "statement",
        "--points-json",
        '[{"content":"a","authoredBy":"research-skill","confidence":0.5}]',
      ],
      { TORTOISE_API_KEY: "tt_test", TORTOISE_BASE_URL: url },
    );
    assert.equal(points.code, EXIT_OK, `stderr: ${points.stderr}`);
    assert.equal(points.payload.status, STATUS_OK, `stderr: ${points.stderr}`);

    assert.equal(seen.length, 2, `expected one POST per write, got ${seen.length}`);
    for (const { method, path, body } of seen) {
      assert.equal(method, "POST");
      assert.equal(path, "/v1/points");
      // EXACT keys: a deleted assignment changes this SET, not just a value.
      assert.deepEqual(Object.keys(body).sort(), ["authoredBy", "confidence", "content", "kind"]);
      assert.equal(body.authoredBy, "research-skill");
      assert.equal(body.confidence, 0.5);
    }
    assert.equal(seen[0].body.content, "c");
    assert.equal(seen[1].body.content, "a");
  } finally {
    server.close();
  }
});

test("write-points: each created Point must carry its own id (a partial batch is not a green verdict)", async () => {
  let n = 0;
  const { server, url } = await startStub((req, res) => {
    res.setHeader("content-type", "application/json");
    n += 1;
    if (n === 1) res.end(JSON.stringify({ id: "pt_1", content: "a", kind: "statement" }));
    else res.end(JSON.stringify({ hello: "not the API" }));
  });
  try {
    const r = await run(
      ["write-points", "--kind", "statement", "--points-json", '[{"content":"a"},{"content":"b"}]'],
      { TORTOISE_API_KEY: "tt_test", TORTOISE_BASE_URL: url },
    );
    assert.equal(r.code, EXIT_OK);
    assert.equal(r.payload.status, STATUS_UNAVAILABLE, `stderr: ${r.stderr}`);
    assert.notEqual(r.payload.status, STATUS_OK);
  } finally {
    server.close();
  }
});

test("write-points: a batch of created Points reports each returned id", async () => {
  let n = 0;
  const { server, url } = await startStub((req, res) => {
    res.setHeader("content-type", "application/json");
    n += 1;
    res.end(JSON.stringify({ id: `pt_${n}`, content: `c${n}`, kind: "statement" }));
  });
  try {
    const r = await run(
      ["write-points", "--kind", "statement", "--points-json", '[{"content":"a"},{"content":"b"}]'],
      { TORTOISE_API_KEY: "tt_test", TORTOISE_BASE_URL: url },
    );
    assert.equal(r.code, EXIT_OK);
    assert.equal(r.payload.status, STATUS_OK, `stderr: ${r.stderr}`);
    assert.equal(r.payload.written, 2);
    assert.deepEqual(r.payload.results.map((p) => p.id), ["pt_1", "pt_2"]);
  } finally {
    server.close();
  }
});

// ── an ANSWERED 4xx is NOT an outage ────────────────────────────────────────

test("probe: a REJECTED credential (401/403) is not_configured (exit 4), never tortoise_unavailable", async () => {
  // CYCLE-3. The store WAS reached and answered; "could not be reached" is
  // false, and the skills then tell the operator to check the address when the
  // fault is the key. A rejected credential is a SET-UP gap, not an outage.
  for (const code of [401, 403]) {
    const { server, url } = await startStub((req, res) => {
      res.statusCode = code;
      res.setHeader("content-type", "application/json");
      res.end(JSON.stringify({ detail: "invalid api key" }));
    });
    try {
      const r = await run(["status"], { TORTOISE_API_KEY: "tt_test", TORTOISE_BASE_URL: url });
      assert.equal(r.code, EXIT_NOT_CONFIGURED, `HTTP ${code} must exit 4 (stderr: ${r.stderr})`);
      assert.equal(r.payload.status, STATUS_NOT_CONFIGURED, `HTTP ${code}`);
      assert.notEqual(r.payload.status, STATUS_UNAVAILABLE);
    } finally {
      server.close();
    }
  }
});

test("data read: a REJECTED credential (401/403) reports not_configured and still skips cleanly", async () => {
  for (const code of [401, 403]) {
    const { server, url } = await startStub((req, res) => {
      res.statusCode = code;
      res.setHeader("content-type", "application/json");
      res.end(JSON.stringify({ detail: "invalid api key" }));
    });
    try {
      const r = await run(["search", "--query", "x"], { TORTOISE_API_KEY: "tt_test", TORTOISE_BASE_URL: url });
      assert.equal(r.code, EXIT_OK, `stderr: ${r.stderr}`);
      assert.equal(r.payload.status, STATUS_NOT_CONFIGURED, `HTTP ${code}`);
    } finally {
      server.close();
    }
  }
});

test("an ANSWERED 4xx other than 401/403 is a rejected request, never a store state", async () => {
  // The frozen vocabulary is three words and none is true of a 400/404/422/429 —
  // the store WAS reached and answered. The PROBE exits EXIT_USAGE (2) with no
  // `status` field; a DATA subcommand keeps the skip-cleanly exit 0 but emits
  // `{error: "request_rejected", http_status}` — no store-state word either way.
  for (const code of [400, 404, 422, 429]) {
    const { server, url } = await startStub((req, res) => {
      res.statusCode = code;
      res.setHeader("content-type", "application/json");
      res.end(JSON.stringify({ detail: "bad request" }));
    });
    try {
      const probe = await run(["status"], { TORTOISE_API_KEY: "tt_test", TORTOISE_BASE_URL: url });
      assert.notEqual(probe.code, EXIT_UNAVAILABLE, `probe HTTP ${code} must not exit 3 (stderr: ${probe.stderr})`);
      assert.equal(probe.code, EXIT_USAGE, `probe HTTP ${code}`);
      assert.equal(probe.payload, null, `probe HTTP ${code} must carry no status field, got: ${probe.stdout}`);
      assert.match(probe.stderr, new RegExp(`HTTP ${code}`));
      assert.doesNotMatch(probe.stdout, /tortoise_unavailable|not_configured/);

      const read = await run(["search", "--query", "x"], { TORTOISE_API_KEY: "tt_test", TORTOISE_BASE_URL: url });
      assert.notEqual(read.code, EXIT_UNAVAILABLE, `read HTTP ${code} must not exit 3`);
      assert.equal(read.code, EXIT_OK, `read HTTP ${code} keeps the skip-cleanly exit 0`);
      assert.equal(read.payload.error, "request_rejected", `read HTTP ${code}`);
      assert.equal(read.payload.http_status, code);
      assert.equal(read.payload.status, undefined, `read HTTP ${code} must carry NO store-state word`);
      assert.doesNotMatch(read.stdout, /tortoise_unavailable|not_configured/);
    } finally {
      server.close();
    }
  }
});

test("a 5xx means the service answered but is failing: tortoise_unavailable is still the true word", async () => {
  // The counterpart to the 4xx rule: only a 5xx keeps the outage word — the
  // service declares it cannot serve, which is an availability failure rather
  // than a rejected request.
  const { server, url } = await startStub((req, res) => {
    res.statusCode = 503;
    res.setHeader("content-type", "application/json");
    res.end(JSON.stringify({ detail: "unavailable" }));
  });
  try {
    const probe = await run(["status"], { TORTOISE_API_KEY: "tt_test", TORTOISE_BASE_URL: url });
    assert.equal(probe.code, EXIT_UNAVAILABLE, `stderr: ${probe.stderr}`);
    assert.equal(probe.payload.status, STATUS_UNAVAILABLE);

    const read = await run(["search", "--query", "x"], { TORTOISE_API_KEY: "tt_test", TORTOISE_BASE_URL: url });
    assert.equal(read.code, EXIT_OK);
    assert.equal(read.payload.status, STATUS_UNAVAILABLE);
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
  for (const [bad, pattern] of [
    ["{}", /--points-json must be a JSON array/],
    ["null", /--points-json must be a JSON array/],
    ["5", /--points-json must be a JSON array/],
    ["true", /--points-json must be a JSON array/],
    // Malformed JSON takes the PARSE branch, BEFORE the array/shape checks.
    // Without these the try/catch around `JSON.parse` is unpinned: a bare
    // `JSON.parse(raw)` left the suite green while `--points-json '[{'` emitted
    // `{"status":"tortoise_unavailable"}` at exit 0 — a usage error wearing a
    // store-state word, the exact defect class this contract forbids.
    ["[{", /--points-json must be valid JSON/],
    ["{,}", /--points-json must be valid JSON/],
    ['"unterminated', /--points-json must be valid JSON/],
  ]) {
    const r = await run(["write-points", "--kind", "statement", "--points-json", bad], { TORTOISE_API_KEY: "tt_test" });
    assert.equal(r.code, EXIT_USAGE, `--points-json ${bad} must be a usage error (stderr: ${r.stderr})`);
    assert.match(r.stderr, pattern);
    assert.equal(r.payload, null, `--points-json ${bad} must not emit a JSON payload, got: ${r.stdout}`);
    assert.doesNotMatch(r.stdout, /tortoise_unavailable|not_configured/);
  }
});

test("usage: an EMPTY --points-json array is a usage error, never a green no-op write", async () => {
  // CYCLE-4 (P1). `write-points ... --points-json '[]'` never entered `for (const
  // p of points)`, so `out({status:"ok",written:0})` fired even with NO key and
  // an unreachable host — a green "I wrote nothing" that touched no store.
  // Synthetic positive AND negative, so the guard cannot depend on the corpus:
  // every empty spelling is EXIT_USAGE with no payload, and a one-point array
  // is the positive control that still parses.
  for (const bad of ["[]", "[] ", " []"]) {
    const r = await run(["write-points", "--kind", "statement", "--points-json", bad], { TORTOISE_API_KEY: "tt_test" });
    assert.equal(r.code, EXIT_USAGE, `--points-json ${JSON.stringify(bad)} must be a usage error (stderr: ${r.stderr})`);
    assert.match(r.stderr, /--points-json must be a non-empty JSON array/);
    assert.equal(r.payload, null, `--points-json ${JSON.stringify(bad)} must not emit a payload, got: ${r.stdout}`);
  }
  assert.deepEqual(parseArgs("write-points", ["--kind", "statement", "--points-json", '[{"content":"c"}]']), {
    "--kind": "statement",
    "--points-json": [{ content: "c" }],
  });
});

test("usage: a non-numeric --limit is a usage error, never a store state", async () => {
  // Against a HEALTHY stub: unvalidated, `Number("abc")` is NaN; the request
  // still succeeded, so the run reported `ok` exit 0 — a bad invocation dressed
  // as a healthy read (and, against a non-2xx server, dressed as the store
  // being down). The type is `positiveInteger`, so this message is the table's.
  const { server, url } = await emptyStoreStub();
  try {
    const r = await run(["search", "--query", "x", "--limit", "abc"], {
      TORTOISE_API_KEY: "tt_test",
      TORTOISE_BASE_URL: url,
    });
    assert.equal(r.code, EXIT_USAGE, `stderr: ${r.stderr}`);
    assert.match(r.stderr, /--limit must be a positive integer/);
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

// ── TOTAL argument validation (one table, before ANY network call) ──────────

test("usage: a --points-json element that is not `{content: <non-empty string>}` is a usage error", async () => {
  // CYCLE-3. `[null]` reached `p.content` and threw `Cannot read properties of
  // null`, which the catch-all reported as `tortoise_unavailable` — a usage
  // error wearing a store-state word. Each element must be a NON-NULL OBJECT
  // with a non-empty string `content`. None of these reach the network.
  for (const [bad, re] of [
    ["[null]", /--points-json\[0\] must be a non-null object with a non-empty string content/],
    ["[5]", /--points-json\[0\] must be a non-null object/],
    ["[[]]", /--points-json\[0\] must be a non-null object/],
    ["[\"str\"]", /--points-json\[0\] must be a non-null object/],
    ["[{}]", /--points-json\[0\] must be a non-null object with a non-empty string content/],
    ['[{"content":""}]', /--points-json\[0\]\.content requires a non-empty value/],
    ['[{"content":123}]', /--points-json\[0\] must be a non-null object with a non-empty string content/],
    ['[{"content":"ok"},null]', /--points-json\[1\] must be a non-null object/],
  ]) {
    const r = await run(["write-points", "--kind", "statement", "--points-json", bad], {
      TORTOISE_API_KEY: "tt_test",
    });
    assert.equal(r.code, EXIT_USAGE, `--points-json ${bad} must be a usage error (stderr: ${r.stderr})`);
    assert.match(r.stderr, re, `--points-json ${bad}`);
    assert.equal(r.payload, null, `--points-json ${bad} must not emit a payload, got: ${r.stdout}`);
    assert.doesNotMatch(r.stdout, /tortoise_unavailable|not_configured/);
  }
});

test("usage: a REQUIRED flag that is absent is a usage error, never the string \"undefined\"", async () => {
  // CYCLE-3. `write-points` with no `--kind` sent the LITERAL string
  // "undefined" as the kind, from `args.indexOf()` reading past the end.
  const cases = [
    [["write-points", "--points-json", '[{"content":"c"}]'], /--kind required/],
    [["write-points", "--kind", "statement"], /--points-json required/],
    [["search"], /--query required/],
    [["query-prior-research"], /--domain required/],
    [["write-claim"], /--content required/],
    [["write-claim", "--content", "c", "--kind"], /--kind requires a value/],
  ];
  for (const [args, re] of cases) {
    const r = await run(args, { TORTOISE_API_KEY: "tt_test" });
    assert.equal(r.code, EXIT_USAGE, `${args.join(" ")} must be a usage error (stderr: ${r.stderr})`);
    assert.match(r.stderr, re, args.join(" "));
    assert.equal(r.payload, null, `${args.join(" ")} must not emit a payload, got: ${r.stdout}`);
    assert.doesNotMatch(r.stdout, /tortoise_unavailable|not_configured/);
  }
});

test("usage: a VALUE-LESS flag is a usage error, never the string \"undefined\"", async () => {
  // CYCLE-3. `query-visions --point-kind` (nothing after it) sent the literal
  // string "undefined" as the kind: `opt()` read past the end of argv. A token
  // that is itself a flag is not a value either (`--limit --kind`).
  for (const [args, flag] of [
    [["query-visions", "--point-kind"], "--point-kind"],
    [["search", "--query", "x", "--limit"], "--limit"],
    [["search", "--query"], "--query"],
    [["search", "--limit", "--query", "x"], "--limit"],
    [["write-points", "--kind", "--points-json", "[]"], "--kind"],
  ]) {
    const r = await run(args, { TORTOISE_API_KEY: "tt_test" });
    assert.equal(r.code, EXIT_USAGE, `${args.join(" ")} must be a usage error (stderr: ${r.stderr})`);
    assert.match(r.stderr, new RegExp(`${flag} requires a value`), args.join(" "));
    assert.equal(r.payload, null, `${args.join(" ")} must not emit a payload, got: ${r.stdout}`);
    assert.doesNotMatch(r.stdout, /tortoise_unavailable|not_configured/);
  }
});

test("usage: an out-of-range or non-numeric --limit is a usage error, never a healthy read", async () => {
  // CYCLE-3: `--limit 0` used to be accepted and sent. CYCLE-4: `/v1/search`
  // requires 1..100, so `--limit 5000` passed local validation, the API 422'd,
  // and the data subcommand exited 0 with `{error:"request_rejected"}` — a bad
  // invocation indistinguishable from a clean skip. The cap is a LOCAL type rule.
  const { server, url } = await emptyStoreStub();
  try {
    for (const bad of ["0", "-3", "2.5", "abc", "101", "5000"]) {
      const r = await run(["search", "--query", "x", "--limit", bad], {
        TORTOISE_API_KEY: "tt_test",
        TORTOISE_BASE_URL: url,
      });
      assert.equal(r.code, EXIT_USAGE, `--limit ${bad} must be a usage error (stderr: ${r.stderr})`);
      assert.match(r.stderr, /--limit must be a positive integer/);
      assert.equal(r.payload, null, `--limit ${bad} must not emit a payload, got: ${r.stdout}`);
    }
    // ...and valid limits reach the API and are ok — including the 100 boundary.
    for (const good of ["5", "100"]) {
      const ok = await run(["search", "--query", "x", "--limit", good], {
        TORTOISE_API_KEY: "tt_test",
        TORTOISE_BASE_URL: url,
      });
      assert.equal(ok.code, EXIT_OK, `stderr: ${ok.stderr}`);
      assert.equal(ok.payload.status, STATUS_OK);
    }
  } finally {
    server.close();
  }
});

test("usage: an unknown flag is a usage error, never a store state", async () => {
  const r = await run(["search", "--query", "x", "--bogus", "1"], { TORTOISE_API_KEY: "tt_test" });
  assert.equal(r.code, EXIT_USAGE);
  assert.match(r.stderr, /unknown argument "--bogus"/);
  assert.equal(r.payload, null, `got: ${r.stdout}`);
  assert.doesNotMatch(r.stdout, /tortoise_unavailable|not_configured/);
});

test("usage: a BLANK --confidence is rejected, not silently coerced to 0", async () => {
  // `Number("")` and `Number(" ")` are both 0, so a blank value used to become
  // a real number — and `--confidence ""` was previously treated as ABSENT.
  for (const bad of ["", " ", "\t"]) {
    const r = await run(["write-claim", "--content", "c", "--confidence", bad], {
      TORTOISE_API_KEY: "tt_test",
    });
    assert.equal(r.code, EXIT_USAGE, `--confidence ${JSON.stringify(bad)} must be a usage error (stderr: ${r.stderr})`);
    assert.match(r.stderr, /--confidence must be a number/);
    assert.equal(r.payload, null, `got: ${r.stdout}`);
  }
});

test("usage: a WHITESPACE-ONLY string argument is a usage error, class-wide", async () => {
  // CYCLE-4. `string` rejected only `length === 0`, so `write-claim --content
  // '   '` wrote a blank Point and reported `ok`; the nested `--points-json`
  // `content` had the same hole. The SAME `string` entry is exercised for the
  // flag AND for the nested element, so the two cannot drift. Synthetic
  // positive control: a string with real content still parses unchanged.
  for (const blank of ["   ", "\t", "\n", " \t "]) {
    const flag = await run(["write-claim", "--content", blank], { TORTOISE_API_KEY: "tt_test" });
    assert.equal(flag.code, EXIT_USAGE, `--content ${JSON.stringify(blank)} must be a usage error (stderr: ${flag.stderr})`);
    assert.match(flag.stderr, /--content requires a non-empty value/);
    assert.equal(flag.payload, null, `got: ${flag.stdout}`);

    const nested = await run(
      ["write-points", "--kind", "statement", "--points-json", JSON.stringify([{ content: blank }])],
      { TORTOISE_API_KEY: "tt_test" },
    );
    assert.equal(nested.code, EXIT_USAGE, `nested content ${JSON.stringify(blank)} must be a usage error`);
    assert.match(nested.stderr, /--points-json\[0\]\.content requires a non-empty value/);
    assert.equal(nested.payload, null, `got: ${nested.stdout}`);

    const authored = await run(
      ["write-points", "--kind", "statement", "--points-json", JSON.stringify([{ content: "c", authoredBy: blank }])],
      { TORTOISE_API_KEY: "tt_test" },
    );
    assert.equal(authored.code, EXIT_USAGE, `authoredBy ${JSON.stringify(blank)} must be a usage error`);
    assert.match(authored.stderr, /--points-json\[0\]\.authoredBy requires a non-empty value/);
    assert.equal(authored.payload, null, `got: ${authored.stdout}`);
  }
  assert.equal(parseArgs("write-claim", ["--content", "  real  "])["--content"], "  real  ");
});

test("usage: a --points-json element carries the SAME types as the flag of the same name", async () => {
  // The table validated the top-level `--confidence`/`--authored-by` but not the
  // identical value nested in `--points-json`: `confidence: "abc"` was sent as
  // `null`, `authoredBy: 5` sailed through, and (CYCLE-4) a JSON NATIVE coerced
  // silently — `confidence: true` -> 1, `[]` -> 0, `[0.5]` -> 0.5 — while the
  // flag form rejected the same shape. Synthetic negative set below; the
  // positive control proves a numeric STRING normalizes through the SAME entry
  // the flag uses (so the two cannot drift).
  for (const [bad, re] of [
    ['[{"content":"c","confidence":"abc"}]', /--points-json\[0\]\.confidence must be a number/],
    ['[{"content":"c","confidence":""}]', /--points-json\[0\]\.confidence must be a number/],
    ['[{"content":"c","confidence":true}]', /--points-json\[0\]\.confidence must be a number/],
    ['[{"content":"c","confidence":false}]', /--points-json\[0\]\.confidence must be a number/],
    ['[{"content":"c","confidence":[]}]', /--points-json\[0\]\.confidence must be a number/],
    ['[{"content":"c","confidence":[0.5]}]', /--points-json\[0\]\.confidence must be a number/],
    ['[{"content":"c","authoredBy":""}]', /--points-json\[0\]\.authoredBy requires a non-empty value/],
    ['[{"content":"c","authoredBy":5}]', /--points-json\[0\]\.authoredBy requires a non-empty value/],
  ]) {
    const r = await run(["write-points", "--kind", "statement", "--points-json", bad], {
      TORTOISE_API_KEY: "tt_test",
    });
    assert.equal(r.code, EXIT_USAGE, `--points-json ${bad} must be a usage error (stderr: ${r.stderr})`);
    assert.match(r.stderr, re);
    assert.equal(r.payload, null, `got: ${r.stdout}`);
  }
  // Positive control: the nested `confidence` goes through the SAME `number`
  // entry as the flag, so the numeric string is normalized exactly once and the
  // normalized value (a number, not the raw string) is what the parser returns.
  assert.deepEqual(
    parseArgs("write-points", [
      "--kind",
      "statement",
      "--points-json",
      '[{"content":"c","confidence":"0.5","authoredBy":"research-skill"}]',
    ]),
    {
      "--kind": "statement",
      "--points-json": [{ content: "c", confidence: 0.5, authoredBy: "research-skill" }],
    },
  );
});

test("a value that STARTS WITH `--` is a value, not a missing one", async () => {
  // Fixing the value-less-flag case with a bare `startsWith("--")` would refuse
  // a legitimate claim whose text begins with two dashes. Only a KNOWN flag is
  // "not a value".
  const { server, url } = await startStub((req, res) => {
    res.setHeader("content-type", "application/json");
    res.end(JSON.stringify({ id: "pt_1", content: "c", kind: "statement" }));
  });
  try {
    const r = await run(["write-claim", "--content", "--force skips the check"], {
      TORTOISE_API_KEY: "tt_test",
      TORTOISE_BASE_URL: url,
    });
    assert.equal(r.code, EXIT_OK, `stderr: ${r.stderr}`);
    assert.equal(r.payload.status, STATUS_OK, `stderr: ${r.stderr}`);
  } finally {
    server.close();
  }
});

test("data write: NEVER CONFIGURED still skips cleanly (exit 0) for the WRITE subcommands", async () => {
  for (const args of [
    ["write-claim", "--content", "c"],
    ["write-points", "--kind", "statement", "--points-json", '[{"content":"c"}]'],
  ]) {
    // Inert host so only the LOCAL guard can produce `not_configured`; a
    // deleted guard would reach the dead host and report `tortoise_unavailable`.
    const r = await run(args, { TORTOISE_BASE_URL: "http://127.0.0.1:1" });
    assert.equal(r.code, EXIT_OK, `${args[0]} must still skip cleanly (stderr: ${r.stderr})`);
    assert.equal(r.payload.status, STATUS_NOT_CONFIGURED, args[0]);
    assert.match(r.payload.message, /TORTOISE_API_KEY not set/);
  }
});

test("data write: an UNREACHABLE store still skips cleanly (exit 0) for the WRITE subcommands", async () => {
  for (const args of [
    ["write-claim", "--content", "c"],
    ["write-points", "--kind", "statement", "--points-json", '[{"content":"c"}]'],
  ]) {
    const r = await run(args, { TORTOISE_API_KEY: "tt_test", TORTOISE_BASE_URL: "http://127.0.0.1:1" });
    assert.equal(r.code, EXIT_OK, `${args[0]} must still skip cleanly (stderr: ${r.stderr})`);
    assert.equal(r.payload.status, STATUS_UNAVAILABLE, args[0]);
  }
});

test("mock mode answers every data subcommand in the SAME shape as the API", async () => {
  // `TORTOISE_MOCK=1` mirrors the shape contract this suite pins for the real
  // client, so a mock-only drift (a write that reports no `id`) cannot stay green.
  const mock = { TORTOISE_API_KEY: "tt_test", TORTOISE_MOCK: "1" };
  const search = await run(["search", "--query", "x"], mock);
  assert.equal(search.payload.status, STATUS_OK);
  // `search` falls back to `params.query` for `domain`; without the fallback
  // this is `undefined` — an unasserted mock-drift (CYCLE-7 P2).
  assert.equal(search.payload.domain, "x");
  assert.ok(Number.isInteger(search.payload.count) && Array.isArray(search.payload.results));

  // CYCLE-7 P2: `query-prior-research` IS a data subcommand, and this test
  // claims "every" one. Deleting its `case` label in `mockCall` made it fall
  // through to `{error:"unknown_command"}` (exit 2) with the suite green.
  const prior = await run(["query-prior-research", "--domain", "x"], mock);
  assert.equal(prior.payload.status, STATUS_OK, `stderr: ${prior.stderr}`);
  assert.equal(prior.payload.domain, "x");
  assert.ok(Number.isInteger(prior.payload.count) && Array.isArray(prior.payload.results));

  const strategies = await run(["query-strategies"], mock);
  assert.equal(strategies.payload.status, STATUS_OK);
  assert.ok(Array.isArray(strategies.payload.results));

  const visions = await run(["query-visions"], mock);
  assert.equal(visions.payload.status, STATUS_OK);
  assert.ok(Array.isArray(visions.payload.results));

  const claim = await run(["write-claim", "--content", "c"], mock);
  assert.equal(claim.payload.status, STATUS_OK);
  assert.ok(typeof claim.payload.id === "string" && claim.payload.id.length > 0);

  const points = await run(
    ["write-points", "--kind", "statement", "--points-json", '[{"content":"a"},{"content":"b"}]'],
    mock,
  );
  assert.equal(points.payload.status, STATUS_OK);
  assert.equal(points.payload.written, 2);
  assert.ok(points.payload.results.every((p) => typeof p.id === "string" && p.id.length > 0));

  const status = await run(["status"], mock);
  assert.equal(status.payload.status, STATUS_OK);
  assert.equal(typeof status.payload.point_count, "number");
});

test("the argument table defaults every optional flag and rejects before any call", () => {
  // Executed against the real exported parser: the DEFAULTS are part of the
  // table, so `query-visions` with no flag still asks for `vision`, and
  // `search` still asks for 10 — without either flag being passed.
  assert.deepEqual(parseArgs("query-visions", []), { "--point-kind": "vision" });
  assert.deepEqual(parseArgs("query-visions", ["--point-kind", "strategy"]), { "--point-kind": "strategy" });
  assert.deepEqual(parseArgs("search", ["--query", "x"]), { "--query": "x", "--limit": 10 });
  assert.deepEqual(parseArgs("search", ["--query", "x", "--limit", "25"]), { "--query": "x", "--limit": 25 });
  assert.deepEqual(parseArgs("write-claim", ["--content", "c"]), { "--content": "c", "--kind": "statement" });
  assert.deepEqual(parseArgs("write-claim", ["--content", "c", "--confidence", "0.5"]), {
    "--content": "c",
    "--kind": "statement",
    "--confidence": 0.5,
  });
  assert.deepEqual(parseArgs("status", []), {});
  // A `null` nested value means ABSENT (the body builder skips it), not an error.
  assert.deepEqual(
    parseArgs("write-points", ["--kind", "statement", "--points-json", '[{"content":"c","confidence":null,"authoredBy":null}]']),
    { "--kind": "statement", "--points-json": [{ content: "c", confidence: null, authoredBy: null }] },
  );
  // A command with NO required flags is not vacuous — it still refuses an
  // unknown flag, which is what keeps the table the single door.
  assert.throws(() => parseArgs("query-strategies", ["--nope", "1"]), /unknown argument "--nope"/);
  // ...and an inherited `Object.prototype` key is not a command (the lookup is
  // hasOwnProperty, not a bare index).
  assert.throws(() => parseArgs("toString", []), /unknown command "toString"/);
  for (const [cmd, args] of [
    ["query-prior-research", []],
    ["write-points", ["--kind", "statement", "--points-json", "[null]"]],
    ["query-visions", ["--point-kind"]],
    ["search", ["--query", "x", "--limit", "0"]],
  ]) {
    assert.throws(() => parseArgs(cmd, args), /./, `${cmd} ${args.join(" ")} must be rejected locally`);
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
 *
 * The `ok` alternative matches the QUOTED status token (escaped or plain),
 * NOT the bare English word: a `\bok\b` flagged a legitimate escaped JSON
 * example such as `` `{\"ok\":true}` `` (the word "ok" as a KEY). The
 * negative lookahead `(?!\s*:)` keeps a quoted `ok` that is a JSON key out,
 * while a quoted `ok` VALUE — the status the client actually emits — still
 * matches in both its plain (`` `"ok"` ``) and escaped (`` `\"ok\"` ``) forms.
 */
const STATUS_SPAN_TOKEN = /status|not_configured|tortoise_unavailable|\\?"ok\\?"(?!\s*:)/;
function backslashEscapedStatusSpans(src) {
  return (src.match(/`[^`\n]*`/g) || []).filter(
    (span) => span.includes('\\"') && STATUS_SPAN_TOKEN.test(span),
  );
}

/**
 * The retired PROSE phrasing ("tortoise unavailable"), factored to module level
 * so the regex itself is pinned by a synthetic sample. No shipped skill carries
 * a mixed-case sample any more (`skills/research/SKILL.md:384` was rewritten),
 * so DROPPING the `i` flag would keep the scan above green while prose such as
 * `(skip if Tortoise unavailable)` ships.
 *
 * The separator is `[\s-]+` — whitespace OR a hyphen, so a WRAPPED or
 * HYPHENATED reintroduction (`"Tortoise is\nunavailable"`,
 * `"tortoise-unavailable"`) is caught. It still cannot match the canonical
 * `tortoise_unavailable`: `_` is neither whitespace nor a hyphen, so the token
 * has no separator and never matches (a `.` class WOULD match that `_`, a false
 * positive on every correct skill). The samples below pin both directions.
 */
const RETIRED_PHRASE = /\btortoise[\s-]+(is[\s-]+)?unavailable\b/i;

test("every memory skill names BOTH canonical states, never the retired 'tortoise unavailable'", () => {
  for (const name of MEMORY_SKILLS) {
    const src = readSkill(name);
    assert.ok(src.includes('"not_configured"'), `${name}: missing the quoted "not_configured" state`);
    assert.ok(src.includes('"tortoise_unavailable"'), `${name}: missing the quoted "tortoise_unavailable" state`);
    // CASE-INSENSITIVE: the retired phrasing is a prose phrase, so it survives
    // an `unavailable` sentence at the start of a line. A case-sensitive probe
    // left `skills/research/SKILL.md` (`(skip if Tortoise unavailable)`) green.
    assert.doesNotMatch(src, RETIRED_PHRASE, `${name}: retired 'tortoise unavailable' vocabulary`);
  }
});

test("the retired-phrase probe is case-insensitive and never matches the canonical token", () => {
  // The synthetic half of the pin: the shipped skills are clean, so this is the
  // ONLY assertion that fails if the `i` flag is dropped, or if the separator is
  // narrowed until a real phrasing slips through.
  for (const sample of [
    "tortoise unavailable",
    "(skip if Tortoise unavailable)",
    "Tortoise  Unavailable",
    "Tortoise is unavailable",
    "TORTOISE\tIS\tUNAVAILABLE",
    "the store is tortoise  is unavailable",
    // CYCLE-4: a WRAPPED or HYPHENATED reintroduction is still the retired
    // phrase — the old `[ \t]+` (and its must-NOT-match pin) let it ship.
    "tortoise\nunavailable",
    "Tortoise is\nunavailable",
    "tortoise-unavailable",
    "Tortoise-is-unavailable",
  ]) {
    assert.match(sample, RETIRED_PHRASE, `${JSON.stringify(sample)} must be flagged`);
  }
  // The CANONICAL token is NOT the retired phrase: `_` is deliberately not a
  // separator, so a correct skill is never a false positive.
  for (const sample of [
    '"tortoise_unavailable"',
    "status: `tortoise_unavailable`",
    "tortoise_unavailable is the outage word",
    "tortoiselike unavailable",
    "tortoise_unavailable",
  ]) {
    assert.doesNotMatch(sample, RETIRED_PHRASE, `${JSON.stringify(sample)} must NOT be flagged`);
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
  // CYCLE-4 (`ok` scoping): an unescaped quoted `ok` VALUE in a span that also
  // carries an escaped quote is a status span; a quoted `ok` used as a JSON KEY
  // (followed by `:`) is NOT.
  assert.deepEqual(backslashEscapedStatusSpans('a `"ok" \\"x\\"` b'), ['`"ok" \\"x\\"`']);
  assert.deepEqual(backslashEscapedStatusSpans('a `{\\"ok\\":true}` b'), []);
  // ...and the corpus's own escape-sequence documentation is NOT a status span.
  assert.deepEqual(backslashEscapedStatusSpans('replace `"` with `\\"` before interpolation'), []);
});
