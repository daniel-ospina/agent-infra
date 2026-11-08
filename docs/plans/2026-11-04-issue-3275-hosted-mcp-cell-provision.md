---
title: "Plan: #3275 — the hosted Tortoise MCP entry must be installable on a cell (and the fallback client must be delivered)"
type: engineering
domain: operations
doc_status: implemented
subjects.team: organisation-design-team
created: 2026-11-04
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-3275, issue-3256, issue-3289, issue-5153, pr-3374, mcp-client, pi-bootstrap, graph-mcp-provision
---

<!-- research-path: none — in-repo references: `extensions/mcp-client/README.md` (header resolution), `pi-bootstrap/templates/.mcp.base.json`, `pi-bootstrap/cell-install.sh` LAYER VERIFIED block, `scripts/tortoise-graph.sh`, `scripts/tortoise_graph_client.py`, PR #3601 (tortoise: hosted entry), #3256 (fallback client), #3253 (first farm declaration). External rung: `web_fetch` on the MCP spec's `Authorization` transport section plus `extensions/mcp-client/index.ts:819` (`expandEnvVars(config.headers)`) — the spec carries `headers` as request init and the CLIENT expands `${VAR}` (`expandExpr` yields the EMPTY STRING for an unset variable); the client adds no scheme, so the whole value is sent as-is AFTER expansion — see `## External Research`. -->

# Hosted Tortoise MCP on every cell — implementation plan

> ## ⚠ STATUS — read before the tasks
>
> **This plan records work that is ALREADY IMPLEMENTED on PR #3374** (`fix/mcp-cell-provision`). It is
> written at merge time, not before the build: the build happened, its evidence is the test suite and
> the two measured boxes, and what was missing was this artifact (the required `pipeline-compliance`
> check refuses a `complexity:standard` issue with no plan doc and no scoping comment). Every claim
> below is checkable against the diff — none of it is a forward-looking promise.
>
> `doc_status: implemented` says exactly that. Tasks are marked DONE with the evidence inline; the
> `## Not in this PR` section is the honest boundary, and it is a boundary, not a footnote.

**Goal:** make the fleet's declared "always read the graph" rule **executable on a cmux cloud cell** — install the HOSTED Tortoise MCP entry there, and deliver the fallback client the fleet otherwise hand-copies — without ever writing a credential into a shared config file.

**Team:** organisation-design-team

**Architecture:** Two delivery channels, one entry shape each, no new server.
`pi-bootstrap/cell-install.sh` gains an MCP layer that merges (never clobbers) `~/.pi/agent/.mcp.json`
from a shared merge implementation (`pi-bootstrap/lib/merge-mcp.py`) and certifies it in `--verify`.
`pi-bootstrap/setup.sh` farms the fallback client into `~/.pi/agent/scripts/` from a dedicated
`graph_srcs` array. The entry itself is the **hosted** one — `type: http`, `lazy: true`, an
**env-indirect** `Authorization: Bearer ${TORTOISE_MCP_API_KEY}` — because a cell has no checkout, no
venv and no local FalkorDB, which is exactly why the previous stdio-shaped entry was deliberately
skipped rather than forgotten.

**Tech Stack:** bash (3.2-parseable), python3 stdlib (`merge-mcp.py`, the graph client), GitHub Actions bash-shard suites.

## Confirmed problem

#3275's own framing — *"the `.mcp.json` Authorization holds an unexpanded `${TORTOISE_API_KEY}`
placeholder"* — is true and is **not** the whole root. Measured across three boxes: cell-3 had **no**
`.mcp.json` at all, cell-4 had one on a stale `/tmp/cell-home` path, and the Mac had the placeholder.
Two distinct failures, one symptom (`Connection closed` / 401):

| # | Failure | Root | Evidence |
|---|---------|------|----------|
| F1 | the placeholder is 19 chars and the server wants `tt_` + 32 = 35 | the header is expanded by the CLIENT — `expandEnvVars(config.headers)` (`extensions/mcp-client/index.ts:819`, `expandExpr` `:548-562`) — and an UNSET variable expands to the EMPTY string, so the wire carried `Bearer ` and the server answered 401 | #3275 body; `index.ts:819`/`:548-562`; PR body "sends `Bearer `" |
| F2 | the cells had no MCP layer at all | the template's `tortoise` entry was **stdio** (`${TORTOISE_HOME}/.venv/bin/python3 -m tortoise.mcp_server` + `TORTOISE_DB_URI=docker://…:16379`) — uninstallable on a cell, so `cell-install.sh` skipped the layer on purpose | `cell-install.sh` pre-change `--verify`; cell-3/cell-4 inventory in the PR body |

So the fix is **not** "stop skipping the layer" (that would install an unspawnable server and a
credential into a 0644 file). It is: **make the entry installable**, then install and certify it.

## Decisions

| # | Decision | Rejected | Why |
|---|----------|----------|-----|
| D1 | **Install the HOSTED entry** (`http`, `lazy: true`, `idleTimeoutMs: 900000`, `timeoutMs: 60000`) | the stdio entry (needs checkout/venv/DB a cell does not have); eager load | a cell is memory-constrained and the hosted cold handshake exceeds pi's default connect budget — a `core` server here would block every session start |
| D2 | **The header is env-indirect and canonical**: `Bearer ${TORTOISE_MCP_API_KEY}`, and `--verify` refuses any *literal* `tt_`/`tk_` in the file | writing the resolved key into `.mcp.json` | R2: a credential in a shared 0644 config is not a provisioning fix; the client expands at process start |
| D3 | **ONE merge implementation** (`pi-bootstrap/lib/merge-mcp.py`), called by both `setup.sh` and `cell-install.sh` | two inline `{**dst, **src}` merges | the two callers had already drifted into the same bug: a source-wins merge **repoints a self-hosted `tortoise` url at the hosted endpoint** on every re-sync, invisibly — and the base template's own `_comment` tells self-host users to set that url |
| D4 | **A cell installs the graph server ONLY** (`--cell`) | the whole base catalog | `seo-intelligence` spawns `${AGENT_INFRA_PATH}/mcp-servers/…` and a cell ships `extensions/` only; `brave-search`/`gemini` spawn without keys; `playwright-browser` pulls an npx package onto a small box. A catalog advertising unspawnable tools is worse than a short one |
| D5 | **The fallback client gets its own farm array** (`graph_srcs`), not a second entry in `fleet_srcs` | declaring the pair in both; leaving it hand-copied | #3253 put both in `fleet_srcs`; a pair in two arrays is copied twice and appears twice in `farm_declared_rel` — two answers to "who delivers this file". A dedicated array is a farm loop that reports a **MISSING** entry loudly |
| D6 | **Missing credential WARNS, it does not fail `--verify`** | hard-fail the layer | the credential is *operator-pushed* state (`cloud-cell-bringup.sh`: keys.env is "operator-pushed, and NOT a bring-up byproduct"). Refusing to certify an otherwise-complete layer over a key nobody pushed is a false block — and a false block is what teaches operators to ignore the verifier |
| D7 | **The alias form is resolved the way a lane resolves it** — `source` in a subshell | parse the line for a literal value | a line-parser reads `export TORTOISE_API_KEY="$TORTOISE_MCP_API_KEY"` as the literal string `$TORTOISE_MCP_API_KEY` and calls a live key malformed. That exact mistake was measured while building this |

## Rejected alternatives (recorded, with when it would have won)

- **Populate the literal key into `.mcp.json`.** Would have won if the client did not expand env vars at all and no indirection were possible. It does expand, and a literal key in a shared file is a credential leak that `--verify` would then have to police forever.
- **Deliver `keys.env` from the bring-up itself.** Would have won if the fleet had no credential-ownership rule. It has one (`cloud-cell-bringup.sh`); moving to a secret store is a credentials decision, not a bootstrap edit — stated on the issue rather than half-done here.
- **Fix only the two broken tool calls (#3256) and leave the MCP layer alone.** Would have won if the cells had any MCP surface at all. They did not — that is F2.
- **Let `setup.sh` and `cell-install.sh` keep their own merges.** Would have won if the two were identical. They were identical *in the wrong direction*, which is the harder failure to see.

## Wiring Check

| Touch Point | Type | Covered By | Status |
|---|---|---|---|
| `~/.pi/agent/.mcp.json` on a cell (created/merged) | runtime config write | `pi-bootstrap/cell-install.sh` MCP layer → `pi-bootstrap/lib/merge-mcp.py` | ✅ test: `.mcp.json carries the HOSTED tortoise entry (http + env-indirect Bearer, no literal key)` |
| `~/.pi/agent/.mcp.json` on a laptop (re-sync) | runtime config write | `pi-bootstrap/setup.sh` `merge_mcp()` → the same lib | ✅ suite: `pi-bootstrap/tests/test-setup-no-nesting.sh` (setup path), `pi-bootstrap/tests/test-farm-unfarm.sh` |
| Hosted entry shape (`templates/.mcp.base.json`) | shipped data | the base template | ✅ test: `--verify` refuses a stdio-shaped entry **by name** |
| Credential resolution (`~/keys.env` → `TORTOISE_MCP_API_KEY`) | runtime read | `cell-install.sh --verify` resolver (subshell `source`) | ✅ test: `--verify` refuses a literal-key entry; resolver reports the file it read, or names the remedy |
| Fallback client delivery (`~/.pi/agent/scripts/tortoise-graph.sh` + python client) | shipped artifact | `pi-bootstrap/setup.sh` `graph_srcs` farm + `farm_declared_rel` | ✅ test: `the hosted-graph fallback landed executable (scripts/tortoise-graph.sh)` |
| Fallback client tool signatures | code contract | `scripts/tortoise-graph.sh` → `scripts/tortoise_graph_client.py` → served MCP surface | ✅ corrected **twice**: `tortoise_get_entity(id, type)` / `tortoise_create_operator(op_type, source_id, target_ids, direction, semantics)` — the first correction (`tortoise_get_point`, `id`) landed against a handler the surface RETIRED in #3883, so the client now calls only ADVERTISED tools, and `tests/tortoise-graph-client/run.sh` asserts every recorded `tools/call` name is a member of the served `tools/list` |
| `--verify` verdict surface (a cell must not start on a bad layer) | gate | `cell-install.sh verify_graph_mcp()` | ✅ test: both refusal arms above + the advisory (warn-not-fail) arm for a missing key |
| Producer pin (`LANE_PRODUCERS_CANONICAL`) for the newly farmed pair | test-gate data | `pi-bootstrap/tests/test-setup-no-nesting.sh` | ✅ re-pinned here. ⚠️ This row used to point at `## Known reds on main` for an "unrelated" producer drift; that drift is the SAME one — four of those eight files were exec'd by farmed consumers and delivered by nothing — and it is RESOLVED by #3531/#1938 (see that section) |

## Tasks (all DONE — this is the record, not a to-do list)

1. **DONE — the merge lib.** `pi-bootstrap/lib/merge-mcp.py`: rule order documented in its docstring (`exa` drop → destination servers preserved → `tortoise` follows `usable()` → `--cell` installs the graph server only); every decision printed as a `NOTE:`; exit 3 when the template has no usable tortoise entry. Refuses to run silently: `setup.sh` errors out if the lib is absent rather than falling back to a second private merge.
2. **DONE — cell-install MCP layer.** `graph_mcp_marker()` (the verifier, in its own function body so its `here-doc` survives bash 3.2), `graph_key_from_env_file()` / `graph_mcp_var()` / `graph_key_resolve()` / `graph_credential_state()` / `graph_credential_note()` (the credential resolver), wired into `--install` and `--verify`. Three refusal arms (stdio shape, literal key, unusable-but-preserved self-hosted entry) plus the advisory arm for an absent key. ⛔ There are **no `CELL_MCP_*` knobs** — the correction this entry needed: it named variables that exist nowhere but this sentence, which sends a lane looking for an edit surface instead of the layer that exists.
3. **DONE — the base template.** `templates/.mcp.base.json` carries the hosted entry as the committed shape, `lazy: true`.
4. **DONE — the farm.** `setup.sh graph_srcs=(tortoise-graph.sh tortoise_graph_client.py)`, one line, real copies + `chmod +x`, `farm_missing` on absence, and `farm_declared_rel` updated so `check-farm-drift.sh` can see them. `graph_srcs` is decoded in `pi-bootstrap/tests/test-setup-no-nesting.sh`'s `FARM_ARRAYS` and `check_producer_farm_declared`.
5. **DONE — the fallback client's two broken calls.** `tortoise_create_operator` now sends `op_type/source_id/target_ids/direction/semantics` (was `label`); `get` sends `id` (was `point_id`). Both were rejected by the server's argument validation; the second failed **after** the point was written.
   **DONE — the third defect, found by review after #3883.** `get`/`health`/`stats` called tools the surface **retired**: they still answer, so nothing failed, but each answer carries a second content block (a `RETIRED TOOL: …` notice) which the client folded into the payload with `"\n".join` — so those verbs printed their JSON *plus* a paragraph, exit 0, breaking the file's own documented contract. They now call `tortoise_get_entity(id, type="point")` and `tortoise_overview(section="health"|"pointkinds")` (the advertised handlers, verified to return the same payloads), a retirement notice is a fail-closed `GRAPH-RETIRED-TOOL` (exit 4) rather than a comment appended to the answer, and `{}` from the server — its not-found convention — is a failed read (exit 4), never a green.
6. **DONE — canonical credential name.** `scripts/tortoise-graph.sh` reads `TORTOISE_MCP_API_KEY` first, legacy `TORTOISE_API_KEY` second, and its abstention message names both plus the remedy.
7. **DONE — regression tests.** `pi-bootstrap/tests/test-cell-install.sh` → **297 `ok` arms, `FAIL: 0`** on Linux (measured 2026-11-05 at `ed0548bc0`; the count moves whenever a commit on this branch adds an arm — it has gone 183 → 191 → 195 → 197 → 200 → 209 → 211 → 215 → 229 → 277 → 283 → 291 → 297 during this PR, so treat every number here as a MEASUREMENT with its head, never a constant to quote back); `tests/tortoise-graph-client/run.sh` → **25 arms** against a hermetic stub of the served surface. On macOS the same cell-install suite reports 3 `FAIL` in the gh-shim arms — an unresolved `/var/folders/…/T//` `$TMP` compared against the verifier's physical `/private/var/folders/…`, identical at base `1f69ab544`, so it is **declared and not chased**. The graph arms are named in the PR body.
8. **DONE — measured end-to-end.** `HOME=<scratch> bash pi-bootstrap/setup.sh` and `CELL_HOME=<scratch> bash pi-bootstrap/cell-install.sh --install` both print the expected farm + merge + `LAYER VERIFIED` lines (transcript excerpt in the PR body).

## Verification

```
bash pi-bootstrap/tests/test-cell-install.sh        → 297 ok arms, FAIL: 0 (Linux, measured at ed0548bc0)
                                                      on macOS: 3 FAIL in the gh-shim arms (the `/var` →
                                                      `/private/var` comparison — a symlink artifact,
                                                      identical at base, declared not chased)
bash tests/tortoise-graph-client/run.sh             → `OK: 25 arms — …` (green; hermetic stub of the served surface)
bash pi-bootstrap/tests/test-farm-unfarm.sh         → green (graph_srcs declared, unfarm clean)
bash -n over every shipped script                   → clean (bash 3.2 parse gate is CI-enforced)
```

## External Research

Rung 3 (`web_fetch`) on the MCP transport specification's HTTP section, to settle the one question the
issue left open — *is `headers` interpolation supported?* Finding: the MCP spec's HTTP transport
carries `headers` as request init, and **this repo's client DOES interpolate them**: `index.ts:819`
(`expandEnvVars(config.headers)`), whose `expandExpr` (`:548-562`) yields the EMPTY STRING for an unset
variable. So the 19-character placeholder never reached the wire as a literal — it reached it as
`Bearer ` and the server answered 401. The 19 chars are a property of the FILE, not of the request;
an earlier draft of this finding said "verbatim, no expansion step" and was **wrong** (corrected
2026-11-04 in review — the diagnosis of the empty-Bearer trap is unchanged, and D2's env-indirect
shape is *what makes* the client expand a real key instead of nothing). It is why `--verify` reports
*which file the key resolved from* rather than trusting the file's text. (Contradiction test: no
recorded decision covers header interpolation; the relevant recorded decisions — owner mandate
2026-11-02 on graph reads, and the `cloud-cell-bringup.sh` credential-ownership rule — are both
**obeyed** here, not overridden.)

## Known reds on main (not caused by this PR, verified by re-running the same suites at `origin/main`)

- ⛔ **RESOLVED — do not read this as a current red.** `pi-bootstrap/tests/test-setup-no-nesting.sh` — 2
  failures, `producer-set` drift: `admin-merge.sh`, `cloud-cell-doctor.sh`, `cloud-cell-supervisor.sh`,
  `install-controller-service.sh`, `fleet-schedule.py`, `pi-cache-reap.sh`, `reap-lane-venvs.sh`,
  `registry-sync.sh` are exec'd by farmed consumers and delivered by nothing. Reproduced identically on
  `origin/main` at `9f7d20bd` in a clean worktree — it is a re-pin debt on main, tracked separately, and
  NOT this diff (this PR only *adds* a decode arm for `graph_srcs`).
  **Fixed by #3531 (#1938):** the four producers are now farm entries, the pin is re-cut, and the suite is
  `exit 0 / 237 ok / 0 FAIL` on the fixed tree. ⛔ And the list above was PARTLY WRONG even when written:
  `fleet-schedule.py`, `pi-cache-reap.sh`, `reap-lane-venvs.sh` and `registry-sync.sh` were `fleet_srcs`
  members on `main` and the producer gate credited them DELIVERED — only the four named first were actually
  delivered by nothing. A stale "main is red" record is what has already stalled work on a green tree, so
  this bullet stays as the record of what was believed, explicitly marked resolved, rather than deleted.
- `scripts/orchestrator-harness/uv-env.test.sh` (sigpipe-grep), `scripts/test_lane_watchdog.py::test_a_frozen_child_of_a_pi_parent_is_a_candidate` and the `lane-liveness`/`verify` suite are red on this
  head and touch **nothing** in this diff; none is a required check (the repo's only required context is
  `pipeline-compliance`).

## Not in this PR (deliberate)

- **Credential distribution stays `~/keys.env` (0600), operator-pushed.** A secret store is a credentials decision.
- **The graph itself was unreachable during the build for a reason outside this change** — `https://api.premiselabs.co` answered `/health` 200, then 6/6 timeouts (TLS completes in 35 ms, zero bytes after); tracked on the server side (#10750). This PR is what makes the *client* correct so that when the server answers, a lane authenticates instead of sending an empty Bearer.
