/**
 * lb-harness.mjs — deterministic model of an aggressive-TTL provider edge.
 *
 * Reproduces the #1110 / upstream "Issue B" failure class without depending on
 * the real network or on a flaky timing race:
 *
 *   upstream   a trivial HTTP server that answers every request 200 with a
 *              tiny JSON body and counts TCP connections (the provider).
 *   LB         a TCP-level middlebox in front of it (the load balancer). After
 *              `idleReapMs` of inactivity on a client connection the middlebox
 *              declares that connection reaped: it does NOT send the client a
 *              FIN (a real LB restart / conntrack eviction / lost FIN behaves
 *              this way), it just forgets it. The NEXT byte the client writes
 *              on that socket is answered with a TCP RST.
 *
 * That is the exact shape the keep-alive pool mis-handles: the socket still
 * looks reusable to undici, and the request written onto it dies with
 * ECONNRESET / "socket hang up".
 *
 * Deliberately zero-dependency and pure Node so it runs under `node <file>` in
 * CI (the `extensions/*\/test*.mjs` glob) with no install step.
 */

import http from "node:http";
import net from "node:net";
import { once } from "node:events";

/** Start the mock provider. Returns { port, connections, requests, close() }. */
export async function startUpstream({ sse = false, streamChunks = 3, chunkDelayMs = 5, delayMs = 0 } = {}) {
  const stats = { connections: 0, requests: 0, bodies: [], delayed: false };
  const server = http.createServer((req, res) => {
    let body = "";
    req.on("data", (c) => { body += c; });
    req.on("end", () => {
      stats.requests++;
      if (stats.bodies.length < 50) stats.bodies.push(body);
      // `delayMs` delays the RESPONSE HEADERS — the slow-endpoint case a
      // `headersTimeout` would abort, used to prove timeouts=0 means "no
      // timeout" rather than "abort immediately".
      if (delayMs > 0) {
        stats.delayed = true;
        setTimeout(respond, delayMs);
        return;
      }
      respond();
    });
    function respond() {
      if (!sse) {
        res.writeHead(200, { "content-type": "application/json" });
        res.end(JSON.stringify({ ok: true, request: stats.requests }));
        return;
      }
      res.writeHead(200, {
        "content-type": "text/event-stream",
        "cache-control": "no-cache",
        connection: "keep-alive",
      });
      let i = 0;
      const tick = () => {
        if (i < streamChunks) {
          res.write(`data: ${JSON.stringify({ delta: i })}\n\n`);
          i++;
          setTimeout(tick, chunkDelayMs);
        } else {
          res.write("data: [DONE]\n\n");
          res.end();
        }
      };
      tick();
    }
  });
  server.on("connection", (s) => {
    stats.connections++;
    s.on("error", () => {});
  });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  return {
    port: server.address().port,
    stats,
    close: () => new Promise((r) => server.close(r)),
  };
}

/**
 * Start the load balancer in front of `upstreamPort`.
 *
 * @param {object} opts
 * @param {number} opts.upstreamPort
 * @param {number} [opts.idleReapMs]   idle time after which a client connection
 *                                     is "reaped" (RST on next client byte).
 *                                     0/undefined = never reap.
 * @param {boolean}[opts.advertiseKeepAlive] send a `Keep-Alive: timeout=…`
 *                                     header, as an LB with a lying TTL does.
 * @returns {{ port:number, stats:object, close:()=>Promise<void> }}
 */
export async function startLoadBalancer({
  upstreamPort,
  idleReapMs = 0,
  advertiseKeepAlive = false,
} = {}) {
  /** @type {Map<net.Socket, {up:net.Socket|null, reaped:boolean, timer:NodeJS.Timeout|null, requestsOnSocket:number}>} */
  const conns = new Map();
  const stats = {
    clientConnections: 0,
    reaps: 0,
    rstOnReuse: 0,
    forwarded: 0,
  };

  const server = net.createServer((client) => {
    stats.clientConnections++;
    const state = { up: null, reaped: false, timer: null, requestsOnSocket: 0 };
    conns.set(client, state);
    client.on("error", () => {});
    client.on("close", () => {
      if (state.timer) clearTimeout(state.timer);
      state.up?.destroy();
      conns.delete(client);
    });

    const arm = () => {
      if (state.timer) clearTimeout(state.timer);
      if (!idleReapMs) return;
      state.timer = setTimeout(() => {
        // Reap silently: the client keeps believing the socket is healthy.
        state.reaped = true;
        stats.reaps++;
        state.up?.destroy();
        state.up = null;
      }, idleReapMs);
      state.timer.unref?.();
    };
    arm();

    client.on("data", (buf) => {
      if (state.reaped) {
        // The client reused a connection the edge had already discarded.
        stats.rstOnReuse++;
        state.up?.destroy();
        state.up = null;
        client.resetAndDestroy?.() ?? client.destroy();
        return;
      }
      if (!state.up) {
        state.up = net.connect(upstreamPort, "127.0.0.1");
        state.up.on("error", () => {});
        state.up.on("data", (d) => {
          // Response bytes are activity too: re-arm before forwarding so an
          // in-flight request is never reaped under the client's feet (which
          // would hang the request instead of producing a clean reuse error).
          arm();
          if (client.writable) {
            if (advertiseKeepAlive) {
              // A real edge often advertises a keep-alive TTL far longer than
              // the one it actually honours; undici trusts the hint up to
              // keepAliveMaxTimeout, which is how a socket outlives its peer.
              // Header rewriting is not the point of the harness, so the hint
              // is injected only on the first response headers block.
              const injected = injectKeepAlive(d);
              client.write(injected);
            } else {
              client.write(d);
            }
          }
        });
        state.up.on("close", () => {
          state.up = null;
          // Upstream closed but the client is left open on purpose: this is the
          // half-open socket the pool will offer to the next request.
        });
      }
      // Count requests forwarded on this socket (cheap HEAD-independent count).
      if (/^POST |^GET |^PUT /m.test(buf.toString("latin1"))) {
        state.requestsOnSocket++;
        stats.forwarded++;
      }
      arm();
      state.up.write(buf);
    });
  });

  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  return {
    port: server.address().port,
    stats,
    close: () =>
      new Promise((resolve) => {
        for (const [c, s] of conns) { s.up?.destroy(); c.destroy(); }
        server.close(() => resolve());
      }),
  };
}

/** Inject/append a long `Keep-Alive: timeout=` hint into a raw HTTP header block. */
function injectKeepAlive(chunk) {
  const text = chunk.toString("latin1");
  const idx = text.indexOf("\r\n\r\n");
  if (idx === -1) return chunk;
  const head = text.slice(0, idx);
  if (/^keep-alive:/im.test(head)) return chunk;
  return Buffer.concat([
    Buffer.from(text.slice(0, idx) + "\r\nKeep-Alive: timeout=3600" + text.slice(idx), "latin1"),
  ]);
}

/** Wait ms. */
export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** POST a JSON body to `url` using the supplied fetch; returns {ok, error}. */
export async function postJson(fetchImpl, url, body = { hello: "world" }) {
  // Shared POST+JSON helper for the real-transport arms: reports the transport
  // error code instead of throwing, so an arm can assert on recovery.
  try {
    const res = await fetchImpl(url, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
    });
    await res.text();
    return { ok: true, status: res.status };
  } catch (err) {
    return { ok: false, error: err, message: String(err?.message ?? err), code: err?.cause?.code ?? err?.code };
  }
}
