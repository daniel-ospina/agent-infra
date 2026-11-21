# `mcp_load` diagnosability — the six probes from agent-infra#4189

**Status:** measured 2026-11-21 on the `cmux` box (Linux, `@modelcontextprotocol/sdk` 1.29.0).
**Symptom (from the issue):** `mcp_load orchestrator` fails with
`MCP error -32000: Connection closed` while the server itself starts and exits 0 on an EOF probe —
so nothing in the failure distinguishes *crashed*, *handshake timed out*, *never spawned*, or
*the loader gave up*.

This document records what each of the issue's six probes answered, and which could not be answered
here, **before** any code changed. It is the evidence the fix rests on. The first hypothesis was
wrong and the probes are what corrected it, so the refuted reading is recorded too.

---

## The one-paragraph answer

The orchestrator server is healthy; **the entry that launches it is not**, and the client's error
reporting hid that. Measured, in order:

1. **`args` are never `${VAR}`-expanded** — `command`, `cwd`, `env` and `headers` are, `args` are not
   (measured: a child declared with `args: ["${SOME_UNSET_VAR}/x"]` receives the **literal** string).
   The shipped entry (`templates/.mcp.base.json` and `.mcp.json`) declares
   `"args": ["${AGENT_INFRA_PATH}/mcp-servers/orchestrator/server.py"]`, so `python3` is handed a file
   named `${AGENT_INFRA_PATH}/…` and exits 2 immediately.
2. **`cwd: "${AGENT_INFRA_PATH}"` expands to `""`, and `""` is not "no cwd"** — measured, the child
   inherits the *parent's* cwd, which is why the error below resolves the placeholder against
   `extensions/mcp-client/`. (Native `spawnSync` with `cwd: ""` instead fails `ENOENT` **naming the
   command** — an error that accuses a present interpreter of being missing.)
3. **The child's stderr was discarded and no stage was named.** The SDK's `stderr` option defaults to
   `"inherit"`, which writes the child's output to the *parent process's* stderr — invisible to a tool
   result — so the only thing that reached the operator was the protocol's generic close message.

The fix is therefore **three** things: expand nothing new (see the decision note at the end), launch the
entry through a surface that *is* expanded (`cwd` + a relative script path), and make a failed connect
name its stage, its resolved command, and the child's own stderr.

## Probe 1 — is the spawn ever attempted?

**Answered: yes.** The child is spawned and runs; `python3` reaches its own argument parsing and exits 2
with a message. Driven through the client's own path with the repo's real `.mcp.json`:

```
$ npx tsx …/probe3.mjs          # McpServerManager.connectAll(".mcp.json") → loadServer("orchestrator")
catalog: { tier: 'lazy', status: 'sleeping' }
raw cwd: "${AGENT_INFRA_PATH}"  raw args: ["${AGENT_INFRA_PATH}/mcp-servers/orchestrator/server.py"]
python3: can't open file '/home/cmux/…/extensions/mcp-client/${AGENT_INFRA_PATH}/mcp-servers/orchestrator/server.py': [Errno 2] No such file or directory
ERR: MCP error -32000: Connection closed
```

Two facts in one line: the child **ran** (so the loader is not giving up), and it was given the
**literal** placeholder (so `args` are not expanded). A direct EOF probe confirms the server itself is
fine: `python3 mcp-servers/orchestrator/server.py < /dev/null` → `rc=0`.

## Probe 2 — is it a handshake failure?

**Answered: only in the protocol's degenerate sense.** The transport spawned, the child closed its end
without ever answering `initialize`, and the protocol layer raised its generic `-32000 Connection
closed`. The child's own explanation never reached the caller, because it was on a stream nobody read.
Measured with the SDK directly, same failing command, two stderr modes:

```
inherit(default): err.name=McpError err.code=-32000 msg="MCP error -32000: Connection closed"
inherit(default): captured stderr=""
pipe:             err.name=McpError err.code=-32000 msg="MCP error -32000: Connection closed"
pipe:             captured stderr="python3: can't open file '…': [Errno 2] No such file or directory"
```

The error object is identical in both cases — **only the capture differs**. That is the whole
observability defect, and it is why "make the error diagnosable" is a real fix and not a retry.

Distinguishing *never started* from *started then closed* is possible on the public API: the
transport's `start()` resolves on the `spawn` event and rejects on `error`, so wrapping `start()`
splits the two classes without touching the SDK's private `_process`.

## Probe 3 — is it the `cwd`?

**Answered: yes, as a second, independent defect.** `"cwd": "${AGENT_INFRA_PATH}"` expands to `""`,
and `""` is silently treated as "inherit the parent's cwd" (proven by probe 1: the placeholder resolved
against `extensions/mcp-client/`). The same empty value through native `spawnSync` instead fails:

```
$ node -e 'const{spawnSync}=require("node:child_process");console.log(spawnSync("python3",["-c","print(1)"],{cwd:""}).error.message)'
spawnSync python3 ENOENT
```

i.e. an unset variable in `cwd` reports *"python3 is missing"* when python3 is present. Either way an
empty expansion must not be passed through as a value.

## Probe 4 — why do the other servers load?

**Answered.** Of the six entries in the repo's `.mcp.json`, exactly **one** uses `${VAR}` in `args`:

| entry | `${VAR}` sites | loads? |
|---|---|---|
| `seo-intelligence` | `command`, `cwd` — both expanded | yes |
| `orchestrator` | `cwd` **and `args[0]`** — only `cwd` is expanded | **no** |
| the rest | none | yes |

The difference **is** the finding: every entry that survives only uses expansion surfaces the client
actually expands.

## Probe 5 — is it one box or every box?

**Not answered here.** No cloud cell was reachable from this box without a `cmux` link, and the fix does
not depend on the answer: the entry bug is in a **shipped template**
(`templates/.mcp.base.json` → installed to `~/.pi/agent/.mcp.json` by `pi-bootstrap/setup.sh`), so it is
every installation, not one box's state. Recorded as open rather than guessed.

## Probe 6 — does the documented authority answer the same question?

**Answered: partially, which is why this was filed as a diagnostics defect rather than an outage.**
`tools/fleet/liveness.py` (via `tools/fleet/claim_lanes.py`) answers *"which lanes exist / is this lane
alive"* from the ref-claim registry and does not go through MCP at all, so a lane census is **not**
blocked by this failure. What *is* lost is `box.exec`, `lane.dispatch`, `fleet.census` and the PR verbs,
which have no non-MCP equivalent — and `mcp_catalog` reports the entry as
`[lazy, sleeping (mcp_load to start)]`, i.e. **available**, which is what made the failure read as a
transient load problem for as long as it did.

---

## ⛔ The recorded decision this work had to route around

`agent-infra#696` — *"`${VAR}` is expanded in command/env/cwd/headers but NOT in args"* — was closed by
the owner as **category B** ("a functional config gap, not destruction or false PASS … reopen if this
classification is wrong"). **Expanding `args` would reverse that ruling**, so this lane does not.

Instead the entry is launched through a surface that is *already* expanded: `cwd` stays
`${AGENT_INFRA_PATH}` and `args` becomes the **relative** `mcp-servers/orchestrator/server.py`, which the
child resolves against its cwd. Measured proof that this restores the surface:

```
$ AGENT_INFRA_PATH=/home/cmux/agent-infra npx tsx …/probe4.mjs
[mcp-client] Loaded 'orchestrator' on demand
LOADED: + 0 tools        # 0 tools is the probe: no ExtensionAPI is bound, so registerServerTools returns []
```

`#696` is reopened with this evidence rather than reversed — that is the owner's call, not a lane's.

## What the fix does

`extensions/mcp-client/index.ts`:

1. **Captures the child's stderr** for every stdio connect (`stderr: "pipe"`, drained for the life of the
   connection, bounded to the last 8 KB) and puts it in the connect error. The capture is **additive**:
   the same bytes are forwarded to the parent's stderr, so a healthy server's runtime output is not
   swallowed by the pipe (the SDK's `"inherit"` default used to put the child's fd 2 on the parent's
   fd 2, and every already-installed server was written against that).
2. **Names the stage** — `config` / `spawn` / `handshake` / `timeout` — by wrapping the transport's
   public `start()`, so *never started* and *started then closed* are distinguishable.
3. **Attributes `${VAR}`s, separately per KIND of field.** `command` and `cwd` are expanded, so an entry
   there means "unset, and no default declared". `args` are NOT expanded (#696), so a `${VAR}` there
   reaches the child LITERALLY whether or not the variable is set — a different fact, rendered in its
   own block, and detected by "does the entry contain a `${…}`" rather than "is the variable unset"
   (the second predicate was silent in the normal, variable-**set** configuration).
4. **Stops passing `cwd: ""`**, which is what turned an unset variable into a false "interpreter
   missing" ENOENT (or a silent inheritance of the wrong directory), and reports the field as
   unresolved instead — truthfully: "the entry declares none", "declares one that expanded to
   nothing, so the child INHERITS the caller's cwd", and a resolved directory are three different
   facts and are rendered as three different facts.
5. **Refuses a relative argv whose `cwd` produced no usable directory** (`stage: config`, before any
   spawn). The condition is *"did the entry's `cwd` yield a directory"*, not *"was a `${VAR}` in it
   unresolved"*: `"cwd": "${VAR:-}"` (a declared default with no path) and `"cwd": ""` are reported by
   the expander as *resolved*, yet hand the transport nothing, so the narrower predicate let exactly
   those spellings through. `cwd: undefined` is an INHERITANCE, not a refusal, so with `cwd` unusable a
   relative `args[0]` would resolve against whatever directory pi happens to run in — inside an
   agent-infra checkout that silently loads *that* checkout's server (in a lane, possibly uncommitted
   code). The same misconfiguration that used to be a deterministic `ENOENT` would have become "it
   works, with someone else's code". An entry that declares **no** `cwd` keeps inheriting — it asked for
   nothing.

   Only args that name a **path** can trigger that refusal: a flag is not a path, and neither is a
   scoped **package specifier** (`@brave/brave-search-mcp-server`, `@playwright/mcp@latest` — shapes
   this repo's own `templates/.mcp.base.json` ships), because the launcher resolves those inside
   `node_modules` and never against the child's cwd. Reading `@scope/pkg` as a relative path would
   hard-refuse `{"command":"npx","args":["-y","@scope/pkg"],"cwd":"${UNSET}"}` — a false block on an
   entry that had always run. Residual, deliberate: an unscoped specifier with a subpath (`pkg/bin.js`)
   is still read as a path, because it is indistinguishable from a genuine relative path
   (`fixtures/server.mjs`).
6. **Never prints the argv.** `args` is the one field this repo documents as the place credentials get
   inlined in plaintext — that is the whole of #696 — and the rendered failure is returned as `mcp_load`
   tool output, i.e. into the model's context, the transcript, and routinely into PR/issue bodies. The
   message names the arg **count**, which entries are **relative**, and the `${VAR}` **spans**; it never
   names an argument's value.

`spawn`-stage failures carrying a deterministic errno (`ENOENT`/`EACCES`/`ENOTDIR`) are **not retried** by
the eager-connect retry: the cause is the config, and a retry only doubles the noise. A `config`-stage
refusal is never retried either — no process was started, so no retry can change the verdict.

`templates/.mcp.base.json` and `.mcp.json`: the `orchestrator` entry's `args[0]` becomes relative to its
(expanded) `cwd`, so the shipped entry spawns on any box where `AGENT_INFRA_PATH` is set. When the
variable is **not** set, `cwd` is unresolved and the entry is now refused as a config error rather than
inheriting pi's cwd — see item 5 above.
