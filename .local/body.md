## What this fixes

The owner's mandate is that **every lane reads and writes the graph through the MCP**. On the cmux cloud cells it was **unobeyable, not disobeyed**:

| box | `~/.pi/agent/.mcp.json` | tortoise entry | `TORTOISE_MCP_API_KEY` | fallback script |
|---|---|---|---|---|
| cell-3 | absent | — | absent | absent |
| cell-4 | absent | — | absent | present only under a stale `/tmp/cell-home` |

`pi-bootstrap/cell-install.sh` deliberately skipped `.mcp.json` on cells, and the reason was sound **for the entry the template shipped**: `tortoise` was **stdio** (`${TORTOISE_HOME}/.venv/bin/python3 -m tortoise.mcp_server` + `TORTOISE_DB_URI=docker://…:16379`) — a checkout, a venv and a FalkorDB a cell does not have. So the fix is not "stop skipping"; it is **make the entry installable on a cell**, then install it.

The hosted entry (what `daniel-ospina/tortoise`'s committed `.mcp.json` has shipped since #3601):

```json
{"type": "http", "url": "https://api.premiselabs.co/mcp/",
 "headers": {"Authorization": "Bearer ${TORTOISE_MCP_API_KEY}"},
 "lazy": true, "idleTimeoutMs": 900000, "timeoutMs": 60000}
```

No checkout, no venv, no local DB — the DB target is resolved **server-side**. `lazy: true` is deliberate: the hosted cold handshake exceeds pi's default connect budget, and this now lands on memory-constrained cells where a core server would block every session start.

## The blank-key trap this closes

A plain `${VAR}` expands to the **empty string** when unset, so an unprovisioned cell reaches the server, sends `Bearer ` and gets a 401 — which reads as an auth bug, not the set-up gap it is (#5153). `--verify` now reports which file the key resolved from, or names the remedy. It **warns** rather than fails on absence: the credential is operator-pushed state (`cloud-cell-bringup.sh`: keys.env is "operator-pushed, and NOT a bring-up byproduct"), so refusing to certify an otherwise-complete layer over a key nobody pushed yet would be a false block.

The alias form the fleet actually uses — `export TORTOISE_API_KEY="$TORTOISE_MCP_API_KEY"` — is resolved the way a lane resolves it (**source in a subshell**). A line-parser reads that as the literal string `$TORTOISE_MCP_API_KEY` and calls a perfectly good key malformed; that mistake was measured while building this.

## Two breakages in the peer's shipped fallback client

#3256 landed `scripts/tortoise-graph.sh` + `scripts/tortoise_graph_client.py`, but nothing farmed them (so they were never **delivered** — the file was hand-pushed onto two boxes and missing on the third), and two call sites do not match the served surface:

| call | was | served signature | effect |
|---|---|---|---|
| `tortoise_get_point` | `{"point_id": …}` | retired in #3883 — the advertised handler is `tortoise_get_entity(id, type)` | `get` fails argument validation; after the first correction, it printed its JSON *plus* a `RETIRED TOOL:` notice (see round 5) |
| `tortoise_create_operator` | `"label": pred` | `def …(op_type, source_id, target_ids, direction, semantics)` | predicate dropped, or rejected **after** the point was written |

Both corrected here, and `graph_srcs` now farms the pair so they land in `~/.pi/agent/scripts/` on every box.
A third defect of the same class was found by review and fixed in round 5: three of the verbs called handlers the
surface has since **retired** (#3883). The client now calls only **advertised** tools, and
`tests/tortoise-graph-client/run.sh` states that as data — every recorded `tools/call` must be a member of the served
`tools/list`.

## Review Scope Contract

- **Class:** `gate-enforcement` + `ops-infra` — the artifact decides (a) whether a lane's MCP surface exists on a cell and (b) whether a missing credential is visible or silent.
- **R1** — the hosted tortoise entry is installed on a cell and is the **only** shape accepted (`--verify` refuses stdio-shaped and literal-key entries by name).
- **R2** — no credential is ever written into a shared config file; a literal `tt_`/`tk_` in `.mcp.json` fails verification.
- **R3** — a cell-local MCP server survives a re-install (merge, not clobber).
- **R4** — the fallback scripts are declared once and delivered to the artifact a lane actually runs (`~/.pi/agent/scripts/`).
- **R5** — the fallback client's calls match the **served** tool signatures, not an assumed one.

## Verification

`bash pi-bootstrap/tests/test-cell-install.sh` → **216 assertions, `FAILURES=0`** on Linux (a MEASUREMENT, not a constant: the count moves whenever a concurrent commit on this branch adds an arm — it has gone 183 → 191 → 195 → 197 → 200 → 216 during this PR, and each earlier number in the round notes is the count at *that* head). `bash tests/tortoise-graph-client/run.sh` → **15 arms, green** (hermetic stub of the served surface, loopback only). On macOS the same suite reports **3 `FAIL`** in the gh-shim arms (`test-cell-install.sh:887`, `…ovr-nosib`, `…verifier path`), which fail **identically at base `1f69ab544`**: each compares an unresolved `/var/folders/…/T//` `$TMP` against the verifier's physical `/private/var/folders/…` path — a macOS `/var` symlink artifact, not this change. They are declared, not chased; `FAILURES=0` is the Linux result. The graph arms, in full:
```
ok: .mcp.json carries the HOSTED tortoise entry (http + env-indirect Bearer, no literal key)
ok: the hosted-graph fallback landed executable (scripts/tortoise-graph.sh)
ok: --verify refuses a .mcp.json with the stdio tortoise entry (the cell must not be started)
ok: --verify refuses a .mcp.json with the literal tortoise entry (the cell must not be started)
```

Plus, directly:

```
$ HOME=<scratch> bash pi-bootstrap/setup.sh
    scripts graph farm: 2 copied (tortoise-graph.sh, tortoise_graph_client.py)
    .mcp.json merged (base servers win; local extras preserved)
$ CELL_HOME=<scratch> bash pi-bootstrap/cell-install.sh --install
    .mcp.json merged (hosted tortoise entry installed, cell-local servers preserved)
    graph credential: resolves from ~/keys.env (len 35) — the hosted MCP will authenticate
    LAYER VERIFIED — ... carries the farmed scripts, the guards, the skills and the config
```

## Not in this PR (deliberate)

- **Credential distribution stays `~/keys.env` (0600), operator-pushed.** Moving to a secret store is a credentials decision, not a bootstrap edit. The migration gap is real and is stated on the issue rather than half-done here.
- **The graph itself is unreachable right now, for a reason outside this change:** `https://api.premiselabs.co` answered `/health` 200 at 14:34Z, then 6/6 timeouts through 14:59Z (TLS completes in 35 ms, zero bytes after). Tracked as #10750 (open), with the cell-side measurement added as a comment. This PR is what makes the *client* side correct so that, when the server answers, a lane authenticates instead of sending an empty Bearer.

## Issue references

Refs #3275 — the hosted tortoise entry must carry a real credential; a 19-char unexpanded
`${TORTOISE_MCP_API_KEY}` placeholder is what made every `initialize` a 401. `--verify` here refuses a
literal-key and a stdio entry by name and reports which file the credential resolved from.

Refs #3289 — an unset `${VAR}` in a header expands to `Bearer ` silently; the resolver this PR ships
names the remedy instead of sending an empty Bearer.

Both are traceability references — this PR closes neither.

## Review round 2 — four open findings from the review at `0a1a6970`, fixed at `78277dd7`

* **The `LAYER VERIFIED` credential arm had no teeth.** It grepped the whole log for a phrase
  `graph_credential_note` prints on the same run, so moving the state off the certification line —
  the exact regression the code comment names — stayed green. It now greps the `LAYER VERIFIED` line.
* **`_loopback` refused a legal loopback spelling.** Its bracketed-IPv6 arm string-matched `::1`, so
  `[0:0:0:0:0:0:0:1]` was called remote and refused as `INSECURE_URL` — a false block on the
  documented local self-host. Both files ask `ipaddress` now.
* **Four comments named the wrong variable** (cell-install.sh x2, setup.sh, mcp-client/README.md):
  they said the entry declares the legacy `${TORTOISE_API_KEY}`; the artifact declares
  `${TORTOISE_MCP_API_KEY}`. An operator provisioning the name those lines gave lands on the
  empty-Bearer 401 this PR exists to close.
* **A docstring described the opposite of the code.** `near_miss` said comparing the scheme is what
  keeps a `http://` typo out of the self-host exemption; the comparison is on the authority alone,
  deliberately, and that IS what keeps it out. Restated, with a note not to "fix" it.
* `ensure_ascii=False` in the merge (the default re-encoded a literal em dash in a line this PR has
  no reason to touch, and `.mcp.json` is restored to the literal); the plan doc's F1 row and External
  Research paragraph corrected — the client DOES expand headers (`expandEnvVars`, index.ts:819), so
  the 19-char placeholder reached the wire as `Bearer `, not as a literal; the assertion count above
  is re-measured.

## Review round 3 — seven findings from the review at `78277dd7`

* **P1 — a `headers` that is not an object made the entry unrepairable.** `"headers": "Bearer …"`
  (a hand-edit, or a curl-style paste) made `usable()` raise `AttributeError` *before* the write, so
  `--install` — the repair path — exited 1 having changed nothing, and `--verify` printed an empty
  marker beside a traceback. The merge now refuses that shape (`reason: headers`) and REPLACES the
  entry; the verifier names it (`BADDERS:str`). Reproduced before the fix, green after, with an arm
  that asserts the repair converges.
* **No regression arm existed for the IPv6 loopback fix** (nor for `ensure_ascii`). Reverting
  `ipaddress` to the `h[1:end] == "::1"` string match would have reddened nothing. Both now have
  arms: a fully-expanded `[0:0:0:0:0:0:0:1]` must be PRESERVED and certified `SELFHOSTED:`, and a
  literal em dash in a cell-local entry must survive an install byte-for-byte.
* **Three docstrings/comments described the opposite of the code** (rule 3's "an explicit non-http
  transport is REPLACED" vs a self-hosted `sse` entry being preserved; `usable()`'s "`sse`/`stdio`
  … is refused"; `skills/research/SKILL.md` still naming `fleet_srcs` now that the pair lives in
  `graph_srcs`; `mcp-client/README.md` still promising "a small eager core is pre-loaded" when every
  shipped server is `lazy: true`). Restated to match the code.
* **`--cell` was silent about base servers the cell already declared.** A merge never clobbers, so a
  hand-installed `seo-intelligence` survives — but the NOTE listed only the servers that were
  *missing*, which reads as "the base catalog is not installed" while an unspawnable entry sat in
  the file, certified. It is now printed as `already declares … KEPT`.
* **`graph_key_from_env_file` sourced an unvalidated file** — including `$CELL_HOME/keys.env` under
  `/tmp/cell-home`, a world-writable parent — so a planted file would be *executed* as the
  provisioning user, in a script whose every comment says the file is operator-pushed and 0600. It
  now requires the file to be owned by the running user (`-O`) and free of group/other write bits,
  and reports a refused file instead of sourcing it.

## Review round 4 — five findings from the review at `4210c213`

* **P1 — a FAIL message I had just added could abort the verifier and print the tenant key.** The
  `BADDERS` sentence was double-quoted with `\\${TORTOISE_MCP_API_KEY}`; `\\` collapses to `\` and
  the expansion ran. On a keyless cell (`set -u`) `--verify` aborted with "unbound variable",
  skipping every check after it; on a provisioned cell (`cloud-cell-bringup.sh` sources `keys.env`
  with `set -a`) it printed the live key into the bring-up log. Fixed to `\${…}`, and the arm now
  asserts the FAIL sentence itself — a marker is echoed before the case arm, so asserting only the
  marker was green over both outcomes.
* **The graph predicate was not total over arbitrary JSON.** `"Authorization": 12345` raised
  `TypeError`, `"url": 123` raised `AttributeError` — both BEFORE the write, so the merge exited 1
  with the file unchanged and `--install` (the repair path) could never converge. Refused as
  `auth`/`url` on the merge side and named `BADAUTH:`/`URLTYPE:` by `--verify`.
* **`_no_group_world_write` did not follow symlinks**, so a symlinked `~/keys.env` (target 0600, same
  owner — a normal dotfiles setup) reported the link's 0777 and was refused with an untrue statement
  about the file. `stat -L` on both arms.
* **Two fixes had no arm** (the class this PR keeps re-learning): the ownership/mode gate and the
  `--cell` `already declares … KEPT` note. Both have one now, in both directions.
* **The UNRESOLVED arm still grepped the whole log** — a revert to a separate `log_line` stayed
  invisible. Scoped to the `LAYER VERIFIED` line like its positive twin.

## Review round 5 — the two findings rounds 1-4 left open, fixed at `1045d3880`

Both are from the review at `0a1a6970`; both are about an assertion that could not go RED.

* **P1 — install and `--verify` contradict each other, and the test that pins the agreement could not
  fail.** The `type` refusal was hoisted above the url branch, so `merge-mcp.py` preserved a
  self-hosted entry spelling `type: "sse"` and marked it `_selfHosted` (rc=0) while `--verify`
  refused ANY non-http `type` (rc=1, `NOTHTTP:sse`). `--install` runs that same verify and exits 1 on
  it, and `cloud-cell-bringup.sh` turns a non-zero install rc into a `die`, so the repair loop
  re-created the refusal and the cell could NEVER converge — a false block, whose cost was
  convergence, not certification. The rule is now one rule on both sides: a non-http `type`
  disqualifies the HOSTED default, and a self-host is certified BY NAME. The exact bytes
  `{"type": "sse", "url": "http://localhost:8000/mcp", "_selfHosted": true}` are now written
  literally and driven against `--verify` **alone** (no install in the arm, so nothing the merge does
  can satisfy it), plus a companion arm requiring a re-install to leave those bytes untouched.
  Run against the pre-fix rule it prints `NOTHTTP:sse` and exits 1.

* **P1 — the credential-state assertion could not detect its own regression.** It grepped the whole
  log for a phrase `graph_credential_note` prints unconditionally on the same run, so a revert to a
  second `log_line` — the exact regression the code comment names — stayed green. Round 4 scoped it
  to the `LAYER VERIFIED` line, which asks the right question but proves nothing about itself: a
  later edit could widen the pattern back and no arm would notice. Both directions now share ONE
  named pattern (`CRED_ON_CERT`), and that pattern is itself asserted against a fixture two-line log
  (cert line without the state, state on its own line) it must NOT match. Measured: the old
  whole-log grep matches that fixture; `CRED_ON_CERT` does not; and it still matches the real line in
  both directions (`resolves from …`, `UNRESOLVED`).

Also corrected here: this body told an operator that the hosted entry declares
`Bearer ${TORTOISE_API_KEY}`. The shipped artifact (`templates/.mcp.base.json:23`) declares
`${TORTOISE_MCP_API_KEY}` — the same defect round 2 fixed in four code comments, which survived in
the prose. An operator provisioning the name this body gave lands on the empty-Bearer 401 the PR
exists to close.



## Review round 6 — six findings from the review at `46e93fcd`, all six reproduced and fixed

Every item below was re-measured against the primary source before it was applied (a review finding is a
claim, not a fact). Two were P1s of the class this PR exists to close: **the repair path unable to repair**,
and **a contract asserted in prose but falsified by the served surface**.

* **P1 — the fallback client called three RETIRED tools (#3883).** `tortoise_get_point`, `tortoise_health`
  and `tortoise_list_pointkinds` are no longer advertised (measured: `tools/list` at
  `https://api.premiselabs.co/mcp/` returns **69** tools, none of them these). They still *answer*, and
  every answer carries a **second text content block** — a `RETIRED TOOL: …` notice — which `tool()`
  folded into the payload with `"\n".join`. So `get`/`health`/`stats` printed their JSON **plus** a
  paragraph, exit 0, and the file's own documented contract (*"Prints the tool result as JSON on stdout"*)
  stopped holding: `… get <id> | python3 -c 'json.load(sys.stdin)'` dies. R5 was falsified in prose.
  - `get` → `tortoise_get_entity(id, type="point")` — same payload, no notice (measured).
  - `health` → `tortoise_overview(section="health")`; `stats` → `(section="pointkinds")` — identical
    payloads (measured).
  - A retirement notice is now a **refusal** (`GRAPH-RETIRED-TOOL`, exit 4), matched at a **line start**
    so a point whose *content* discusses retirement still reads. Failing closed rather than stripping the
    notice is deliberate: stripping hides the NEXT retirement behind a clean exit 0.
  - `{}` is the server's not-found convention, so `get` on a mistyped id is `GRAPH-EMPTY-RESULT` (exit 4),
    never a green — scoped to the read-one-entity verb, because a LIST verb may legally answer `[]`.
  - **New suite** `tests/tortoise-graph-client/run.sh` (15 arms, hermetic loopback stub, no network, no
    key) makes R5 *data*: every recorded `tools/call` must be a member of the served `tools/list`.
* **P1 — an UNPARSEABLE `.mcp.json` was the one container shape the repair path could not repair.**
  `json.load` raised *before* the write, so `--install` (which `cloud-cell-bringup.sh` runs on a verify
  failure) exited 1 with the file unchanged and no `.bak` — every bring-up died, and `setup.sh` aborted
  mid-install behind an unreadable config. **Reachable**: the pre-PR merge wrote truncate-in-place (the
  very race the write path documents), so an interrupted legacy run left a truncated file on an
  already-provisioned box. Same rule as the two container shapes fixed at `46e93fcd`, one level up:
  **REPLACED**, and the discarded bytes **KEPT** as `.mcp.json.bak`.
* **P2 — a credential preserved in ANOTHER server was preserved SILENTLY.** The token scan only ever saw
  the tortoise entry, so a literal `tt_` elsewhere was rewritten with rc=0 and a log reading `hosted
  tortoise entry installed` — while `--verify` then refused the file just written, so the layer failed and
  the operator was never told which entry held it. The merge now **names the path**. It does not refuse:
  the bytes are already in the destination, a merge never clobbers, and `setup.sh` merges on laptops where
  no verifier runs — refusing would add a block without removing a secret. The sentence was the missing half.
* **P3 — `$HOME` was unbound, and the abort landed LATE.** Under `set -uo pipefail` the abort happens
  *after* `.mcp.json verify: OK`, so the log reads as a graph problem while `guard_tools_dir`,
  `guard_spawn_gate`, `guard_gh_shim` and the verdict are all **skipped** — from systemd, `sudo -u`,
  `env -i` or CI. Two sites (`${HOME:-}`, `${CELL_HOME:-}`), arm added: `--verify` with `HOME` unset now
  reaches `LAYER VERIFIED`.
* **P3 — the assertion count was stale in three places** (191 vs measured). Removed as a constant: it is
  now stated as a measurement with its machine, and the plan doc's tool-signature row no longer names a
  retired handler.

Six arms were added for these, in both directions where a false block was plausible (a retired-tool notice
refuses; a *point whose content mentions retirement* still reads; `{}` fails on `get`; `[]` still succeeds
on a list verb).

## Review round 7 — four findings from the review at `efe08437` (fresh context, after a forward merge of `main`)

A reviewer that did not write this code found four shapes the merge got wrong. Each was **re-measured on the
real repair path** (`cloud-cell-bringup.sh` runs verify → install → verify) before it was applied — the
reproduction is quoted with each item, because three of the four are only visible when you run the loop
rather than read one function.

* **P1 — a USERINFO url was a CERTIFIED host-spoof.** `near_miss`/`host_typo` read the authority VERBATIM,
  so `https://api.premiselabs.co@evil.example/mcp/` — whose real host is **`evil.example`** — read as "a
  genuine self-host". Measured: the merge PRESERVED it with its `Bearer ${TORTOISE_MCP_API_KEY}`, marked it
  `_selfHosted`, and `--verify` then printed `SELFHOSTED:https://api.premiselabs.co@evil.example/mcp/` **rc=0**.
  The tenant key goes to the attacker's host with this repo's blessing. `_loopback` in the *same file* already
  encoded the right rule (*"userinfo is NOT the host"*); the two predicates now share one definition
  (`host_of()`), and the shape is **REPLACED** rather than certified — a credential belongs in `headers`,
  never in the authority.
* **P2 — install preserved what verify refuses, so the repair could not converge.** `usable()` had no
  absolute-http(s) floor, so a scheme-less url (`localhost:8000/mcp`) was preserved **and** marked
  `_selfHosted` — while `--verify` refuses exactly that by name (`BADURL:`, the client's `new URL()` reads it
  as protocol `localhost:` with no host). Measured: verify rc=1 → install rc=0 → verify rc=1, for ever. The
  cell could never come up, and its own installer had re-created the refusal. `usable()` now carries the
  verifier's floor instead of a second opinion about it.
* **P2 — a non-object `tortoise` entry vanished silently.** A hand-written `["/x/python3","-m","tortoise.mcp_server"]`
  was replaced with **no `NOTE:` and no `.bak`** — against this file's own "nothing here is silent" contract, and
  unlike every sibling container shape, which name the replacement and keep the bytes. Measured: rc=0, no
  line, no backup, and `--verify` then reported `NOENTRY:` over a file the installer had just rewritten. Named
  and backed up now.
* **P2 — the template was the one input whose failure was a Python traceback.** A missing or corrupt template
  raised straight out of `main` (`FileNotFoundError:` / `JSONDecodeError:`, rc=1) — off the documented 0/2/3
  contract — and `setup.sh` guards only `[ -f ]`, so a *corrupt* template printed Python internals under
  `set -e`. Named `FATAL:` at exit 3 now, the code the docstring already reserves for "a template this file
  cannot use".

Six arms pin all four, including the one that actually matters for the loop: **the file install wrote is one
`--verify` certifies** (convergence, not just a replacement), plus an assertion that the `.bak` really holds
the replaced entry.
