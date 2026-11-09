---
name: cmux-cells
description: "Operate the cmux cloud cells (Linux VMs) as part of the fleet — provision and activate them, measure their real capacity, recover a wedged one, dispatch lanes, and land work unattended. Read this before touching a cell."
domain: operations
subjects.team: organisation-design-team
type: reference
status: live
tags: [fleet, cmux, cells, dispatch, capacity, recovery, harness]
summary: "How to provision, measure, recover, and dispatch on cmux cloud cells, and how work actually lands from them."
created: 2026-10-19
updated: 2026-11-05
---

> ⛔ **This skill MUST be read in full — not skimmed.** Every section below is a measurement that cost a lost lane, a
> wasted hour, or a wrong conclusion. The traps are the content.

# Operating the cmux cloud cells

The fleet runs on the macOS laptop (launchd) plus the Linux cells the provider currently allocates — `cmux vm ls` on
2026-10-27 showed **three**: `pi-cell-1`, `pi-cell-3`, `pi-cell-4`. (`pi-lane-1` is an **earlier label of the same VM now
labelled `pi-cell-1`** — `vm-efa6cc8f…`; `cloud-cell-bringup.sh:42` pairs them — a relabel, not a lost box. **cell-2** is the
one that is genuinely absent. `docs/ops/ACTIVATION-MATRIX.md` still speaks in the OLD labels (`pi-lane-1`, `pi-cell-2`), so read
it with this mapping in hand. Treat any inventory, including this one, as a reading: re-run `cmux vm ls` before acting on
it.) ⚠️ **`pi-cell-N` is the LABEL column; on the Mac every `cmux vm <verb>` that takes a machine takes the
NAME column (`vm-<hex>`; from inside a cell the peer grammar accepts the peer slug, the LABEL and the NAME alike — see §3)**
— `cmux vm stats pi-cell-4` returns a 404 whose own advice is "start a new one", a spend-flavoured remedy for a box that is
already running. Read the NAME from `cmux vm ls`. Cells are Linux, so **any
harness change must work on both platforms** — one source of truth with a platform branch, never two drifting copies.

Canonical harness home: **`agent-infra/scripts/orchestrator-harness/`**. `tortoise/operations/orchestrator-harness/` and
`~/orchestrator/` are historic forks; treat agent-infra as the authority.

---

## 1. Provisioning a cell — and the step the installer forgets

The documented path, run ON the cell:

```bash
git clone https://github.com/daniel-ospina/agent-infra.git /tmp/cell-ai
cd /tmp/cell-ai && git checkout main
bash pi-bootstrap/cell-install.sh            # the operational layer: scripts farm, guards, skills, config
bash scripts/cloud-cell-bringup.sh --check   # → should end: CELL READY
```

⛔ **NO HOME OVERRIDE — the layer and the credential now live in the SAME home (agent-infra#3453, measured 2026-11-05).**
This block used to say `HOME=/tmp/cell-home` was mandatory, because the operational layer (`record-review.sh`, the `gh` shim,
the extensions) was installed under `/tmp/cell-home/.pi/agent`. That put the LAYER in `/tmp/cell-home` and the model
CREDENTIAL in the account home (`/home/cmux/keys.env`), so a 17-lane wave produced **0 landings**: every `git push` answered
`403 … contents=write` while `gh` READS still worked, and it read as a token problem. One home now: `scripts/lib/cell-home.sh`
DERIVES it (`$CELL_HOME`, else the passwd record's home — `/home/cmux` on a cell), every unit renderer consumes that resolver,
and `cloud-cell-bringup.sh --check` REFUSES a box whose `CELL_HOME` is not the account home. Do not set `HOME` or `CELL_HOME`
by hand; a box still on `/tmp/cell-home` is converged with `bash scripts/cell-home-migrate.sh --check`, then `--apply`.

⛔ **AND THE SAME REDIRECTION IS WHAT HIDES THE CREDENTIAL — the half of this fact that bites (agent-infra#3331, measured
2026-11-02).** The model credential normally lives in the **ACCOUNT** home's `keys.env` (`/home/cmux/keys.env`), i.e. *not*
under the `HOME` a lane runs with; and the harness's own `lane-env.sh` sources `${ENV_FILE:-$HOME/keys.env}`, the redirected
one. So the one setting that makes the operational layer work is the setting that hides the credential: `pi` starts, finds no
key, and exits having done nothing. Since #3331 `lane.sh` REFUSES that shape before spawning `pi` — `[key-gate] … check=fail
result=REFUSED var=<NAME> model=<id>` naming the variable, the provider, the model, `models.json` and every candidate file,
exit **82** — and every lane log now ends with `outcome=<done|refused|failed|died> reason=<token>`. ⛔ **AND SINCE #3443 IT
ANSWERS ON THIS EXACT SHAPE, WITH NO `models.json` AT ALL**: a provider `pi` ships is provisioned from its OWN variable
(`dist/env-api-keys.js`; `deepseek` → `DEEPSEEK_API_KEY`, and a multi-variable provider passes on ANY of its variables), so
the refusal names the real variable instead of saying `cannot-resolve-provider-credential` — that silence WAS the #3443
report. ⛔ **AND A REFUSAL REQUIRES EVERY DOCUMENTED PATH TO BE CLOSED, not just the variable** (measured): the vendor code
beside its own env table accepts a NON-VARIABLE credential for two providers we use — `google-vertex` from Application
Default Credentials plus a project and a location (`env-api-keys.js:136-142`), `anthropic` from workload-identity
federation (`providers/anthropic.js:40-57`), whose token-file member must be READABLE — measured, a set `ANTHROPIC_IDENTITY_TOKEN_FILE`
pointing at no file makes `pi -p` die `Failed to read identity token file at <p>` — and with neither variable set those boxes still reach the provider
(`invalid_client` / a federation token-exchange error). The gate mirrors those paths, so such a box PASSES
(`check=ok path=vertex-adc …`) and a refusal lists the paths it also checked and found closed (`paths=vertex-adc`).
⛔ **`google-vertex` SITS IN THE CANNOT-SAY SET FOR A DIFFERENT REASON** (measured): with only `GOOGLE_CLOUD_API_KEY` set,
`pi -p` signs the call and Vertex answers 401 *"API keys are not supported by this API"* — so the key makes a credential
EXIST and the lane's first model call still fails. It therefore warns (`reason=provider-credential-unverifiable`, naming
the path it also checked) unless ADC actually provisions the box, which prints `check=ok path=vertex-adc`.
⛔ **A PATH MEMBER IS TESTED THE WAY THE REQUEST TESTS IT** (measured): the provider's `resolve` gets `auth/context.js`'s
env accessor, which answers `undefined` when the value's `.trim()` is empty — so a whitespace-only `GOOGLE_CLOUD_PROJECT`,
`GCLOUD_PROJECT` or federation id is ABSENT and `pi -p` answers `No API key found`. (The vendor's JS-truthiness test in
`env-api-keys.js` belongs to the listing/compat surface, not the request path.) An explicit `GOOGLE_APPLICATION_CREDENTIALS` is
the exception: the file test sees the RAW value with no tilde expansion, and the ADC loader then opens that literal path — measured,
`GOOGLE_APPLICATION_CREDENTIALS='~/config.json'` dies with `ENOENT ... open '<cwd>/~/config.json'` even when `$HOME/config.json` exists.
⛔ **AND A `models.json` `radius` GRANT SWAPS THE VARIABLE** (measured): a provider body with `oauth: "radius"` + a `baseUrl`
gets `radiusProvider`, so with NO `apiKey` declared the credential is `RADIUS_API_KEY` (not the provider's own) and with one declared the
template still wins - `RADIUS_API_KEY` does not substitute for it. A `models` entry with no `api` does NOT drop a granted
provider on the default gateway (pi composes it from `RADIUS_MODELS`, measured: it reached the gateway), only on a custom one — where pi answers
`Error: Unknown provider` and no credential can rescue it, so that shape is REFUSED (`reason=models-json-provider-dropped`)
with a model-level remedy instead of a variable to export. The vendor strips a trailing `/v1` before normalizing
the gateway, so `https://radius.pi.dev/v1` IS the default one (measured: pi reaches it); and it only ADDS a scheme, never
rewrites one — `http://radius.pi.dev` and `https:/radius.pi.dev` are CUSTOM gateways, where an api-less definition is
measured `Error: Unknown provider` (provider DELETED) and therefore refused, not `check=ok`; and an UNSHIPPED provider
with an unbuildable definition is refused too, because pi deletes it (`Error: Unknown provider`) — only on a COMPLETED
read of the table, though: an unread table is cannot-say, and an oauth-only provider pi ships (`openai-codex`) has no
env entry at all, so neither is mistaken for "pi does not ship it". A model definition whose effective `baseUrl` — its
own, else the one on the provider body — is not an absolute URL is refused as well, for a different measured reason: the
composed model carries that raw value and pi builds the request from it, so `pi -p` answers `Invalid URL` and exits 1
(`reason=models-json-bad-gateway`) — write an absolute `https://...` on the definition or the provider body. ⛔ THE TEST IS
PER **PINNED** DEFINITION (a sibling's broken `baseUrl` is never requested, measured), AND THREE SHAPES ARE DELIBERATELY
**NOT** REFUSED because pi runs them (each measured): a grant with NO
`models` array (the gateway normalizes its own config URL; 401 from Radius), a definition carrying its OWN absolute
`baseUrl` (it wins), and a NON-radius provider body with no `models` array is refused only when that body's own `baseUrl`
is unbuildable — because only there does every base model inherit it. The test itself is "would `new URL()` throw", not a
spelling: `https:/host` and surrounding whitespace are accepted by the vendor, so a `^https?://` test refused boxes that
run, while the AUTHORITY is part of it — `https://:8080/v1` and `https:// gw.example/v1` answer `Invalid URL` (refused),
and `https:///host` / a bare `https://` PARSE and reach the network (not refused). ⛔ That test mirrors the parser's rules for
those MEASURED shapes (userinfo split off first, empty host / empty or unclosed IPv6 literal / forbidden code point / bad
`%` escape refused, tab-NL-CR removed rather than refused, C0-or-space trim, `\` ending the authority like `/`, port
empty or all-decimal ≤65535 with leading zeros read as the value) — it is NOT a URL-parser emulation: the IPV6 INTERIOR
is not validated, so `[zzz]`/`[:::]` pass here although node throws, neither the IPv4-number rule nor the
IDNA/punycode pipeline is reproduced, and a NON-`http(s)` SCHEME is not inspected at all (`ftp://[zzz]/v1` throws in
node and passes here — pre-existing, unchanged by this change). That gap can only ever be a false PASS, and that is measured: three independent
fuzz passes against node (~72,000 generated authorities) found ZERO false blocks, with every false pass confined to
that unemulated surface. Such a provider also has an oauth
handler, so the store refusal below never applies to it.
⛔ **AND ONE STORE SHAPE IS REFUSED, NOT SKIPPED** (measured): an `oauth` entry in `auth.json` for a provider `pi` ships NO
oauth handler for. The handler set is static — `anthropic github-copilot kimi-coding meta openai-codex openai openrouter radius xai`
(`pi-ai/dist/providers/`) — and a stored entry SHADOWS the environment, so `pi -p` answers `No API key found for <provider>.` even with the key
exported. That prints `check=fail result=REFUSED reason=auth-store-oauth-unusable` with the handler list and the shadowing in the
sentence; the same shape on a handler provider stays `check=skipped`, because the token may simply be stale.
Two shapes still cannot be decided and refuse nothing: a provider whose variable is not the whole answer
(`azure` needs `AZURE_OPENAI_BASE_URL`/`_RESOURCE_NAME`; `cloudflare-workers-ai`/`cloudflare-ai-gateway` report `not_ready`
on the key alone; `typesafe` ships CLASSIFIER models only, so `pi -p` answers `Unknown provider`; `amazon-bedrock` takes
the AWS SDK chain — each measured, each `check=warn reason=provider-credential-unverifiable` naming the variable to
check), and a provider `pi` does not ship and `models.json` does not declare. ⛔ **BUT THE KEY IS ONE OF
FOUR FALSIFIED CAUSES, NOT THE CAUSE** (see “the launch directory” below): the same issue's record shows `keys.env` sourced,
`api-key-errors=0`, and the lane STILL dying silently. Do not conclude “a key fixed it” from a green key gate — that gate
closes the *reporting* half, it does not make a lane run.
⛔ **AND ON A CELL THE KEYS FILE OFTEN CONTAINS NO KEY AT ALL — the fix is the MODEL FLAG (agent-infra#3443, measured
2026-11-04 on cell-5).** `/home/cmux/keys.env` there held **only `GH_TOKEN`**; `pi` resolved NO usable model/provider and printed
`No API key found for the selected model.` — ⛔ and read
that sentence exactly: `pi` says *"the selected model"* only when the provider is `unknown` (`auth-guidance.js`), i.e. when no
model resolved at all. An unprovisioned pin on a box that has SOME provisioned provider says something else and instead runs
that model silently. What worked was the invocation — `pi -p --no-session --model deepseek/deepseek-flash` (with no
`--provider`, spell the model as `provider/id`, which resolves unambiguously) — so **pin the pair; do not go looking for a keys file to
source.** Since #3443 the gate also emits `check=warn reason=box-default-not-provisioned box_default=… model=… var=…` when the box's
STARTUP model (`settings.json` `defaultProvider`/`defaultModel`) has no credential: that is about a bare `pi`, and it does
not stop the lane, which pins its own pair. The standalone `key-gate.sh --probe --box-default` REFUSES 82 for the same pin,
but only when the variable can be NAMED (a `models.json` template, or pi's built-in table for a provider it ships); with
neither it abstains with `check=skipped` and says so, so read the line rather than assuming a green/skip means provisioned. If the box sets `enabledModels`, `pi` picks the startup model from that SCOPE
first — unless the pinned pair is itself in the scope — so the probe says `check=skipped reason=enabled-models-scoped` instead of answering from the pin — unset it (or
launch with `--provider … --model …`) before trusting a green pin reading. **If the terminal line is absent**, three things produce that: a box that predates #3331, a
lane the kernel or `lane-bound.sh` KILLed (no trap runs after SIGKILL), or a cleanup that outran the TERM→KILL grace — so
check `[lane-bound] KILL` and `dmesg | grep -ci 'killed process'` before blaming provisioning. And never use
`pgrep -f "pi -p"` for liveness: it matches your own command line. **And what actually made cell lanes run is the launch
directory — see below.**

**⚠️ Still missing after a verified install — plus a trap for boxes installed before the fix:**

| missing | symptom | fix |
|---|---|---|
| **`gh` shim** | every lane logs `#984 argv-level gh shim not found — only the string scanner is active`; the merge gate runs degraded and cannot verify the evidence it demands | **fixed in `pi-bootstrap/cell-install.sh` (agent-infra#2164, closed 2026-10-24)**: it installs the shim at `$HOME/.pi/agent/scripts/gh-shim/gh` and **fails the install** if it is missing. A manual `ln -sf … $HOME/.pi/agent/shims/gh` is a *legacy* workaround for a box installed before that — do not present it as the plan |
| **`auth.json` — the provider credential store** | every lane dies in ~8 s printing `Use /login to log into a provider via OAuth or API key` / `No API key found for deepseek`: a **~300-byte log and no process**, which a launch verifier reads as "ran" (measured 2026-11-05 on **all five cells: `auth.json` was `{}`, 2 bytes**; seven lanes on one box were all recorded as launched and all dead) | **`scripts/cloud-cell-bringup.sh --check` (agent-infra#2024)**: when the store is missing/empty and `keys.env` carries a provider key it **materialises it from that box's own `keys.env`** (`{"deepseek":{"type":"api_key",…}}`, mode 600) in **both** the cell home and the account home, and **reports it as a REPAIR by name**. It **REFUSES** (never guesses) when `keys.env` carries no provider key, and it never takes a key from the repo or a template — `cell-install.sh` still does not touch the store (`cell-install.sh:125`) and nothing syncs (`auto-sync.ts:20`), so this is *materialisation of a secret already on the box*, not a copy. `cloud-cell-supervisor.sh check` **refuses to print `CELL CAN RUN A CONTROLLER`** on a box with no store credential and no `keys.env` key. Verify by artifact, from a clean shell: `HOME=$CELL_HOME pi -p "reply with exactly PROVIDER_OK"` → `PROVIDER_OK` and nothing else |
| **capture extension** (and every suffixed copy of it) | `capture: BLOCKED (N queued, 402 quota)` / `paused N (attempts; continues in the background)` on stdout blocks turns and corrupts the bringup probe (a healthy box reports `FATAL: provider probe failed`) | **denied by name PATTERN in BOTH homes (agent-infra#2147)**: `cell-install.sh` removes `tortoise-capture*` from `$HOME/.pi/agent/extensions` **and** from every home `cloud-cell-bringup.sh` declares as this cell's (`CELL_ALT_HOMES`), and `--verify` fails naming each copy. Measured 2026-11-05: **1 / 0 / 7 / 3 / 2 copies survived** an exact-name, one-home deny. `TORTOISE_CAPTURE=0` does **not** disable it |

Verify activation by **artifact**, never by a banner:

```bash
for f in .pi/agent/scripts/record-review.sh .pi/agent/scripts/gh-shim/gh; do [ -e $HOME/$f ] && echo "ok $f" || echo "MISSING $f"; done
echo "scripts=$(ls $HOME/.pi/agent/scripts|wc -l) ext=$(ls $HOME/.pi/agent/extensions|wc -l) skills=$(ls $HOME/.pi/agent/skills|wc -l)"
git -C /tmp/cell-ai rev-parse --short HEAD    # the version, not the claim
```

⛔ **AND VERIFY THE BOX CAN ACTUALLY ANSWER — from a shell that sources NOTHING** (+#2024). Every check above
reads an installed FILE; none of them proves a lane can get a token. This is the one that does, and it must print
exactly one line:

```bash
env -i HOME=/home/cmux PATH="$PATH" pi -p "reply with exactly PROVIDER_OK"   # → PROVIDER_OK, no trailing noise
```

⛔ **`/home/cmux`, not the legacy `/tmp/cell-home`** (agent-infra#3453): the durable account home is the one cell home, derived
by `scripts/lib/cell-home.sh`. A clean shell pointed at the legacy volatile home proves nothing about the box a lane runs on.

⛔ **`env -i` IS THE POINT, not decoration.** An operator shell on a cell already carries
`DEEPSEEK_API_KEY`, so a plain `HOME=… pi -p …` answers even when the store is `{}` — the exact false
pass #2024 is about. The clean shell is what proves the STORE supplies the credential; if this fails
while the plain form succeeds, the store is the thing that is missing.

An empty `auth.json` (`{}`, 2 bytes) makes that command exit in ~8 s with `No API key found for deepseek` and a
~300-byte log — which a verifier that only checks the log exists reads as a successful launch. `cloud-cell-bringup.sh
--check` materialises the store from the box's own `keys.env` (§1 table) and refuses if it cannot.

A cell is "on main" only if `git -C /tmp/cell-ai rev-list --count HEAD..origin/main` is **0**.

## 2. Capacity is RAM and DISK — load is a distant third

⛔ **Corrected 2026-10-27 — the numbers below used to REFUSE healthy dispatches.** Read them before
quoting any ceiling:

| resource | cost (measured) | note |
|---|---|---|
| **analysis / doc lane** (`pi` tree: wrapper + pi + bash) | **0.06–0.5 GB** whole tree (a bare `pi` alone reaches ~0.28 GB) | RSS summed over each process tree, 14–22 sampled, cell-4, 2026-10-27 — a planning BAND, not a fixed cost |
| **test-running lane** (pi tree + pytest workers + per-lane FalkorDB) | **~0.4–0.7 GB** peak | a FalkorDB/PG sidecar is **~5–105 MB in a normal sample**, with **peaks seen at 207.9 MB (cell-3) and 313 MB (cell-1)** — `docker stats --no-stream`, per sidecar container, cells **1, 3 and 4**, 2026-10-27 (the 313 MB peak is **cell-1's**, so a cells-3–4 re-sample will not reproduce it); plan on the peak, not on ~150 MB, and re-measure per box. The scheduler budgets 512 MB (`ai-drainer.sh` `LANE_MEM_MB`) |
| plan each lane at | **~1 GB** (test) / **~0.5 GB** (analysis) | the PEAK, not the idle |
| worktree `.venv` | **`du` 5.6 GB, but only ~316 MB marginal** under a warm hardlinked cache — the gate reserves **6144 MB** | the figures are `spawn-gate.sh`'s own measurement block (`du` 5,625 MB, ~316 MB marginal, RESERVE 6144); agent-infra#2721 is the incident that made the gate reserve it. #2159 recorded ~1.1 GB per **venv-bearing** worktree (134 MB for one without) — all right about different quantities |
| CPU | **load up to 8–10× the CPU count is normal — a load of 80 on 10 CPUs is neither a wedge nor grounds to reap a lane** (owner, 2026-11-02). Measured reference: load 4.3 with 23 lanes | Two instruments encode this at different lines and **neither is to be tightened**: **spawn** admits up to `MAX_LOAD` = `nproc × 10` (`spawn-gate.sh:119`); **placement** refuses at `CAP_LPC_CEILING` = 8.00 load-per-cpu (nicknamed "DO NOT PLACE HERE" at `capacity.sh:100`, default `:235`, enforced `:890`), mirrored by `ai-drainer.sh:175` `LPC_CEILING=8` (rejection at `:866`). ⛔ Both comparisons are **`>=`**, so **exactly 8.00 is already refused for ADDING work** — the tolerance covers work already RUNNING (do not call the box wedged, do not reap a live lane), and is never a licence to place more |

**⛔ Why a load of 8–10× the core count is fine on a CELL — and why that number must not travel:** these boxes
run I/O-heavy work — git, container churn, disk, network — so the runnable/`D`-state task count stacks far
above the core count while the box still makes real progress. A cell at load 80 on 10 CPUs is working, not
wedged — **though at that exact reading the placement gate already refuses to ADD work**, so this is
tolerance for what is already running, not headroom for more. **This is a CELLS rule, and it is the OPPOSITE
of the rule the laptop obeys.** `~/.pi/agent/AGENTS.md`
carries the global line *"Keep concurrent workstreams ≤ ~12; load above ~12 on 10 CPUs makes sessions
unreachable"* **with no platform qualifier**, so a cell session reading only that file would treat a load of
20 as a wedge. **This skill owns that split — the global file does not make it.** On the laptop the load IS
the fleet competing for attention, and the remedy is fewer concurrent workstreams; on a cell the load is
largely I/O wait, and the remedy is to read RAM and disk (below) instead. Do not carry this tolerance back
to the laptop, and do not read a laptop load of 80 as healthy.

The old row read "`pi` process ~0.6–1 GB RSS per lane". Measured, that is a **test-running peak**; an idle
lane's whole tree is ~0.2 GB. The old arithmetic applied that peak to EVERY lane and then stacked a flat
3 GB reserve on top, so on an 8 GB cell with **3 GB available it returned 0 lanes** — it told an agent a
box with room for two more lanes was full, and the agent believed it and reported "no capacity". Filling a
cell to 23 lanes **OOM-killed 37 processes and the tmux server** (agent-infra#2159), so the reserve is not
the thing to delete — the PER-LANE number is the thing to get right.

**Reserve, honestly stated:** keep **~1.5 GB** for the box itself (`cmux-tui` alone measured **1.1 GB**,
plus docker and kernel slack) — not a flat 3 GB, which dominates a small box and is what produced the false
zero. If a box has already OOM-killed (`dmesg | grep -ci 'killed process'`), raise the reserve for THAT
box instead of pretending a fleet-wide constant is a measurement.

```bash
# a JUDGEMENT AID — the gate below is the authority. The answer is HEADROOM ("more lanes"), not a ceiling:
# add it to the LIVE lane count, never read it as "this box holds N".
# bash-3.2 clean (no `case` inside $( ) — macOS /bin/bash): runnable as a script OR pasted into $().
TARGET=${TARGET:-.}                       # the worktree you are dispatching into, not /
# the gate's own override names are DISK_LANE_TREE_MB / DISK_LANE_RESERVE_MB — if you set those on a cell,
# set these to the same pair, or the aid and the gate disagree by construction. EXCEPT 0: the gate honours
# an explicit 0 and this aid refuses it on purpose (a zero tree makes the ratio meaningless, not infinite)
if [ -f "$TARGET/uv.lock" ]; then TREE_MB=${TREE_MB:-350}; RESERVE_MB=${RESERVE_MB:-6144}
else TREE_MB=${TREE_MB:-64}; RESERVE_MB=${RESERVE_MB:-1024}; fi   # agent-infra lane: 48 MB tree
PER_MB=${PER_MB:-1000}                    # plan on the PEAK below; the scheduler budgets 512 (ai-drainer)
for v in "$TREE_MB" "$RESERVE_MB" "$PER_MB"; do
  [ "$v" -ge 0 ] 2>/dev/null || { printf 'seeds: non-numeric (%s) — refusing\n' "$v"; exit 0; }
done
if [ "$TREE_MB" -le 0 ] || [ "$PER_MB" -le 0 ]; then printf 'seeds: zero tree/PER — refusing\n'; exit 0; fi
free_mb=$(df -Pm "$TARGET" 2>/dev/null | awk 'NR==2{print $4}')                  # MB, no unit parsing
avail_mb=$(command -v free >/dev/null 2>&1 && free -m | awk 'NR==2{print $7}') || true   # Linux only
# an unreadable/garbage probe is NOT "zero room" and NOT room — this aid ABSTAINS. That is a DELIBERATE
# DEPARTURE from the gate, which fails OPEN on an unreadable probe (it admits and WARNs): an aid with no reading
# should not answer at all.
if [ "$free_mb" -ge 0 ] 2>/dev/null; then disk_more=$(( (free_mb - RESERVE_MB) / TREE_MB ))
  [ "$disk_more" -lt 0 ] && disk_more=0 || true; else disk_more=UNREADABLE; fi
if [ "$avail_mb" -ge 0 ] 2>/dev/null; then ram_more=$(( (avail_mb - 1500) / PER_MB ))
  [ "$ram_more" -lt 0 ] && ram_more=0 || true; else ram_more=UNREADABLE; fi
more=UNKNOWN
if [ "$disk_more" != UNREADABLE ] && [ "$ram_more" != UNREADABLE ]; then
  more=$(( ram_more < disk_more ? ram_more : disk_more )); fi
printf 'more_lanes=%s (ram=%s disk=%s, target=%s)\n' "$more" "$ram_more" "$disk_more" "$TARGET"
# 0 means MEASURE BEFORE DISPATCHING. It is never "this box can do no work" — and never a licence to
# clamp the disk term to 1: a disk-zero is the state that does NOT clear by waiting (see §3).
# `free` is Linux-only; on the macOS laptop this prints ram=UNREADABLE by design — use `vm_stat` there.
# EXIT STATUS: every path exits 0, including the two `seeds:` refusals and the UNKNOWN/UNREADABLE abstentions.
# The ANSWER is the printed `more_lanes=` value — read stdout, never the exit code (a caller that tests `$?`
# sees a refusal as success).
```

⚠️ **WHAT THE GATE ACTUALLY REFUSES** (read 2026-10-27) — **brief admission answers first**, then the capacity refusals in
this order (fork → disk → load). The brief gate (`AGENT_BRIEF_REFUSED`, exit **80**) fires **before fork** and before any
disk or load reading (agent-infra#2258), and a **brief refusal is deterministic**: it cannot clear by waiting, and
re-dispatching the same brief on another box refuses there too — re-author the brief, do not retry. (A missing or
incomplete validator returns **78** instead — `CANNOT VERIFY`; that one *is* repairable, by fixing the install rather than
the brief.) The gate's own comments disagree about the order — the comment above `AGENT_DISK_REFUSED` calls the disk refusal
"evaluated FIRST" (search that phrase) while the fork-gate block says "fork -> disk -> load"; cite the phrase, not a line
number, because these anchors moved within hours of being written. The exit codes and the code agree with the second: 80 before
73 before 77.

1. **fork** — `AGENT_FORK_REFUSED`, exit **73**. A process-bound box refuses a spawn that would fork-bomb it; the remedy is
   a restart/drain, **not** waiting;
2. **disk floor** — `DISK_MIN_FREE_MB`, default **500**, exit 77;
3. **disk headroom** — `DISK-NOHEADROOM`, **the binding one**, exit 77: requires `free_mb ≥ tree + reserve`, with per-lane
   costs **350 + 6144 MB** for a target containing `uv.lock` and **64 + 1024 MB** otherwise. One spawn on a uv worktree
   needs **6,494 MB** free, so the floor is not the number that decides (agent-infra#2721);
4. **load** — `MAX_LOAD`, default `nproc × 10` (exit 75; `PI_GATE_REFUSED` 76 is translated into 75).

The creation back-pressure gate (`AGENT_LAND_BACKLOG`, exit **74**) runs last, and only for creation workers. **Only
`MAX_LOAD` (75) clears because the box quietens on its own.** The rest clear when their **resource is released** or their
**input changes** — a lane finishes or drains (73), disk is reclaimed or a lane finishes (77), the brief is re-authored (80),
the install is repaired (78 — which also covers a bad invocation: an `unknown role` is a typo in the call, not a broken
install, so read the emitted line), the repo's open-PR queue actually lands (74). **74 has three arms and they do not share a
remedy:** the ratio (`land_backlog_verdict` rc=1 — repo-wide, so land the queue and re-dispatching it elsewhere refuses too);
the slug (`land_backlog_repo` cannot derive one: that worktree's `origin` is not an `owner/name` slug, **or `repo-slug.sh` is
missing** — per-worktree or an install fault; `land_backlog_verdict` carries a **second copy** of that message, `UNREADABLE
repo … (not an owner/name slug)`, emitted by its OWN slug-shape check and **unreachable through `run_agent`** — the slug is
derived first and refuses there — so it is the test seam's twin of this arm, same remedy, and it is not a `gh` fault); and
**rc=2, a read that did not resolve** (`UNREADABLE open-PR count` / `UNREADABLE landing rate` — each carries "(the gh read
failed)"; a third line, `UNREADABLE landing counts for …`, guards counts that do not parse, but `land_backlog_lands` returns
1 on any read failure and otherwise prints two integers it built itself, so that guard **cannot fire today** — do not
diagnose a 74 as a parse problem) — **env-local, NOT box-local, and the gate now names which cause it is.** Two arms: (a) the gh chain failed while the
lane's gh IS credentialed — fix that box's chain; (b) **no credential at all resolved for the lane**, because nothing set
`GH_CONFIG_DIR` while `HOME` is redirected to the cell home (agent-infra#2509) — measured on `pi-cell-4` and `pi-cell-5`,
**byte-identical refusals**, so **a re-dispatch to another healthy box does NOT clear it**: every cell redirects `HOME` the
same way. Since #2509 `spawn-gate.sh` resolves the config dir BEFORE the gate (`gh-auth.sh`: `GH_CONFIG_DIR`, then
`$XDG_CONFIG_HOME/gh`, then the lane's `keys.env`, then the ACCOUNT home's `~/.config/gh`, per gh's own documented order) and
the refusal prints the CREDENTIAL remedy instead of the ratio one when that is the cause — do not act on `land/fix the open
PRs` for it. If it still refuses, read the lane's `[gh-auth] state=…` line against `gh auth status` under the lane's `HOME`. A P0-blocker or a base-red repair is **exempt by evidence** and dispatches under the hold — **when the exemption read
itself succeeds**; on the rc=2 arm it fails with the same gh chain, so a P0 *is* held until the chain is fixed (the
gate's refusal line says so). **Idling on its own changes none of them**: for 73
and 77 the release *is* a lane draining, so the drain has to actually complete rather than just pass time — which is why the
gate's own two messages read "does NOT clear by waiting" (fork) and "This is NOT a load refusal: waiting does not clear it"
(headroom) while both still offer "or let its lanes drain" / "or let a lane finish". So diagnosing a 73, 77, 74, 78 or 80 as
"the box is busy" and idling is the trap.

**RAM is read by two other instruments — `spawn-gate.sh` reads NO memory at all.** The two floors live in `orch-loop.sh`
(`MIN_MEM_FREE_MB`, default 512) and `capacity.sh` (`CAP_MIN_MEM_MB`, 512). The **scheduler** does budget per lane: `ai-drainer.sh`
uses `LANE_MEM_MB` (default **512**) against `MEM_BUDGET_PCT` (default **75**) of the pool. So there are two numbers —
scheduler 512, planning ~1000 for a test-running lane (the table above) — and this file deliberately uses the larger.
Reconcile against `docs/ops/ai-drainer.md` before raising either. Where the gate speaks, the gate is right.

`MAX_LANES` is **derived** (`2.5 × cores`) when nothing sets it — **and repaired to the derivation when a set value is not a
valid limit** (`is_limit`) — and on every cell something does set it: `keys.env` pins `export MAX_LANES=20`, and a valid
explicit value wins over the derivation. The controller still enforces it, but the number knows
neither disk nor RAM, so it is an upper bound, never the answer (§7).

⛔ **DO NOT RE-INVENT THE CAPACITY GATE — `scripts/orchestrator-harness/spawn-gate.sh` ALREADY IS IT** (checked
2026-10-27). It derives `MAX_LOAD` from `nproc × 10` when unset, refuses on a non-empty disk band (`disk_free_mb` vs
`DISK_MIN_FREE_MB`/`MIN_FREE_MB`, exit 77), **refuses again on per-lane headroom** (`DISK-NOHEADROOM`, tree + reserve,
exit 77 — see above), and validates its own probes against wrap/garbage readings. Its capacity behaviour is asserted in
`spawn-gate.test.sh` (its disk, headroom and load sections); read that rather than trusting a count quoted in prose. The
failure it already names is the one worth reading: the band where `scripts/cloud-cell-supervisor.sh check` prints
`CELL CAN RUN A CONTROLLER` while every lane spawn is refused 77. (`scripts/orchestrator-harness/cloud-cell-doctor.sh` has
no `--check` mode; `--check` is `scripts/cloud-cell-bringup.sh`'s flag, while the banner is the supervisor's `check`
subcommand.)

The formula above is therefore a **diagnostic, not an implementation**: if a number disagrees with the gate, the gate is
right and the number is a curiosity. Any new refusal belongs inside `spawn-gate.sh` with a test — never in a brief, a
wrapper, or a skill.

**Disk and RAM resize draw on a shared plan pool, and the pool is the total ceiling — not the per-VM shape.** Measured
2026-10-19: `cmux vm resize <cell-3> --memory 12` was refused with *"only 4 vCPUs and 8 GiB are free in your plan pool"*
while three VMs were running. Disk grew twice (+8 GiB each) but **RAM had 8 GiB left in total**. So:

- the fleet's real RAM ceiling is the **plan pool**, and it is **fully** allocated (measured 2026-10-27: `usedMemoryMb`
  40,960 of 40,960, `usedVcpus` 20 of 20) — per-cell memory cannot be raised by wanting it;
- a cell's lane ceiling must be computed from **its current free RAM**, and never assumed to be expandable;
- to raise one cell's memory you must first shrink or pause another box — that is an owner-level capacity decision, not a
  dispatch-time workaround;
- disk used to be the cheaper lever (separate pool, grew on demand) — but all three boxes are now at the per-VM cap
  (`maxDiskMb` 131,072 = 128 GB each, measured 2026-10-27), so **reclaim is the only lever left** until the plan changes.

## 3. "Unreachable" is a claim about the CHANNEL, not the box

| read | means |
|---|---|
| `cloud exec` timeout / 502 / silent empty | **the channel failed. Not the box.** Retry minutes apart |
| `cmux vm ls` → `running` | the provider sees the VM alive |
| **`cmux vm stats <vm>`** | the provider's own liveness read, and the cheapest — `CPU n% · Mem x/y GB · Disk a/b GB`. Two caveats that matter: it cannot tell you the guest is **unusable** (a full guest still reads `awake` while every `exec` times out), and its `Disk a` term is the guest's `df` **used**, in GiB — `df -Pm` reports MiB, so divide by 1024 to compare — while `/b` is the **provisioned** size, not `df`'s total. Compare `used`; take headroom from `df`'s `Available`. The provider side can also lag **high** after a reclaim, so if the two disagree, trust `df -Pm /`. Pair it with `vm terminal read` — **the row below** |
| `vm terminal read` → `No space left on device` | the guest is alive and full |

A **disk-full** cell behaves exactly like a dead one: the control agent cannot write its socket, so every `exec` times out
while the provider insists `running`. Measured 2026-10-19: cell-3 sat at 29.9/32 GB, CPU 77%, exec failing for an hour,
having submitted nothing for 141–226 minutes.

Recovery ladder, cheapest first. **Establish a channel before anything else.** Two of the three readings below are *not*
channel verdicts — the first one **is**, and it is listed with them only to say what it settles:

- **A real refusal kills steps 1-2 outright**, whatever its cause — that one *is* a verdict. The channel that then answers is
  `cmux vm exec <vm> -- <cmd>` (it needs no `cmux-tui` daemon) — **unless `/` is nearly full**: a guest at 93 % has already
  been measured with `exec` failing for an hour (above), so treat a nearly-full box as no-channel, not only a 100 % one. With
  **both** of those gone, the surface left is the **display** the same render prints (`cmux surface open
  <vm>/display/display:1` — a noVNC console that was live on cell-4 while its `cmux-tui` port was refused; that is **Mac-CLI
  syntax**, and from inside a cell `cmux surface …` is `unknown resource scope "surface"` — the guest-side equivalent is the
  `cmux layout apply` noted below — **and only where the guest CLI runs at all: on the shape described two bullets down,
  where it does not, `tmux` is what starts a worker, not any guest `cmux` verb**). Beyond that the
  levers are provider-level (step 3) and owner-level (a plan change or a **recreate** — and a recreate is the one step here
  that can destroy unpushed work, so run the work-at-risk check below first).
- **`cmux vm tree` printing `(no terminals)` is not a reading of the box** when the same render shows a link error or a null
  workspace list — cell-4 today reports `link_error: "The Cloud hub could not reach the VM port: connection refused."` and
  `remote_workspaces: null` while its own registry holds **945** terminals. `null` means *unknown*, not *zero*: fall back to
  `exec` — and note that `--refresh`, which the tool's own render suggests, **can itself time out** (measured: 120 s, exit 1, no
  catalog at all on a box whose link is refused) and reports "VM request timed out". That is the channel failing, not the box.
  Only a **connected** link that genuinely enumerates zero terminals justifies creating one
  (`cmux surface new-terminal --machine <vm> --no-open -- <cmd>` — **Mac-CLI syntax**; the CLI that ships INSIDE a cell has no
  `surface` scope at all (`cmux surface ls` → `cmux: unknown resource scope "surface"`), and the guest-side equivalent is
  `cmux layout apply` with a one-surface layout, which produces the same artifact — a shell in the cwd plus a command typed
  into it. `scripts/orchestrator-harness/worker-terminal.sh:30-32` carries that correction with its own measurement).
- **⛔ "`cloud agent` fails while `cloud exec` works" is a GUEST-DAEMON verdict, and the volume is not necessarily why.**
  Measured from the Mac, 2026-10-27/28 (agent-infra#2946): `cmux cloud agent … --machine <vm>` and
  `cmux surface new-terminal --machine <vm>` answered only `Error: The Cloud VM request failed. Retry, or check the
  machine's status with cmux vm ls.`, while `cloud exec` and `cloud push` succeeded on the same box in the same minute. On the guest,
  in that same minute: `cmux server status` → `cannot connect to the local server`; `cmux tree --json` → rc 3, `cannot connect
  to session socket /tmp/cmux-tui-1000/cloud.sock: No such file or directory (os error 2)`; `cmux self --json` → `"route":
  null, "reachable": false` **for the box itself**. The cause is in the box's own journal — `sudo journalctl -u
  cmux-tui-daemon | grep -c 'cannot be recovered atomically'` → **56,053**, first line `2026-10-26T03:51:02Z` (a day BEFORE the
  Mac-side symptom, so a local app restart is not the cause) — a fresh server pid every ~3 s, each dying with `cmux-tui: flush
  terminal journal during mux drop: session journal stopped` + `cmux-tui: multiple interrupted resource creations cannot be
  recovered atomically`. So the session daemon never stays up, nothing answers on `:1337`, and **every spawn verb fails while
  the PROVIDER-CHANNEL verbs (`cloud exec`, `cloud push`) keep working — the guest's own read path does NOT** (`cmux tree --json`
  → rc 3, measured above) — which is why the error's own advice ("check the machine's status") sends the reader
  to a healthy machine. ⛔ **The space lever does NOT apply here:** that volume read `3996 MB · 1892 used · 2089 free · 48 %`
  holding a **1.9 GB** `workspace-registry.sqlite3`, so growing the loop file (step 5 below) changes nothing — this refusal is
  **state** ("interrupted resource creations"), not a full volume. The **candidate** repair is the owner-gated registry reset
  tracked in **agent-infra#2312** — **NOT measured against this state**: that issue's own repro is a FULL volume
  (`database or disk is full`, `0 bytes free`), and step 5 below frames the reset as the space-reclaim fallback. Take it only
  as an owner decision, and treat it as unverified for spawn until `cmux cloud agent … -- "reply OK"` returns a `terminal_id`
  on that box afterwards. Until it is taken, **`tmux` is the surface that still starts a worker** on that box, and `cmux vm ls`
  reading `reachable linked` for a peer says nothing about whether its link opens (#2345).
  ⛔ **The guest-CLI advice in this bullet and every bullet above assumes the guest CLI RUNS AT ALL, and on a measured cell shape it does
  not:** `cmux: cmux-tui daemon binary not found at /root/.cmux/bin/cmux-tui` — the `cmux-tui` symlink dangling and no daemon
  process (agent-infra#2368; the same measurement as `worker-terminal.sh:168-171` and `scripts/orchestrator-harness/README.md:568`).
  On such a box every guest verb below is unavailable, and that error reads as a broken box rather than the known install shape
  it is — the surface that still works is **`tmux`**, started with an EXPLICIT environment (`HOME` pointing at the HOME that
  holds the credential, that HOME's `keys.env` sourced when present, `O` exported — `wt_launcher`'s `tmux` arm is the
  reference); README:568 records it as the ONLY surface that can start a worker there.
- **A usage error is not a channel verdict, and neither is a wrong-but-valid argument.** From the Mac, `cmux vm tree` with
  **no machine** prints the whole fleet; `terminal read/send` without an id prints the usage block. And because §7's table is
  keyed by LABEL, `cmux vm tree pi-cell-4` renders **`No cloud machines. Try: cmux vm new`** from the Mac — a false empty, not
  a missing box — so use the NAME. **From inside a cell — when the guest CLI runs at all; see the #2368 ⛔ above — the grammar is the PEER one and it answers the same arguments
  differently:** `cmux vm` there carries only the remote verbs (`ls`, `connect`, `exec`, `tree`, `terminal`,
  `send`/`send-key`/`read-screen`, `workspace`, `push`, `agent`, `layout`, `env`, and the mirrored resources) — `resize`,
  `pause`, `resume` and `stats` are **`unknown vm subcommand`**, so step 3, step 4 and every `stats` reading in this file have
  to be run **from the Mac**; a missing argument prints `usage: cmux vm tree <machine> [args…]`; and `<machine>` is matched
  against `cmux self peers`, whose entries carry all three names side by side — `name` (the peer slug, e.g.
  `early-ivory-moth`), `display_name` (the LABEL) and `provider_vm_id` (the NAME) — so **any** of the three is accepted, and a
  link that cannot be established renders `link to '<arg>' exited; see <log>`. ⛔ **Three renders from a cell are not verdicts
  about a box:** `no link for machine '<arg>': reflection lists no such machine; reachable machines: <slug>, <slug>` means the
  argument matched **nothing** — and the box you are on is not its own peer, so `cmux vm tree <this box's LABEL>` lands here,
  a correct argument on the wrong target; `terminal read` with no id prints `a terminal id is required (see cmux terminal
  list)` while `terminal send` with no payload prints `give text and/or --keys (e.g. --keys enter)` — one render per verb, not
  a usage block.

And if the volume that is full is the **`cmux-tui` state volume** described under step 5, read that paragraph before the steps
below — **grow the loop file first** (cheapest, destroys nothing); the reset there is the owner-level fallback. None of the
reclaim steps below touch it.

1. `cmux vm terminal read <vm> <terminal-id>` — get terminal ids from `cmux vm tree <vm>`. The screen tells you the truth.
2. `cmux vm terminal send <vm> <term-id> '<command>' --keys enter` — runs a command when `exec` cannot. The **send** verb
   prints nothing back; read the result with `vm terminal read` (step 1).
3. `cmux vm pause <vm>` then `cmux vm resume <vm>` — provider-level reset. Fixes a wedged agent, does **not** fix a full disk.
4. **`cmux vm resize <vm> --disk <GiB>`** — grows in place, 4 GiB steps, **cannot shrink**, and only helps while the VM is
   **below `maxDiskMb`**. Measured 2026-10-27, all three boxes are AT the per-VM cap (128 GB of a 131,072 MB ceiling), so
   today this lever refuses: the remedy for a full guest is step 5 (reclaim), and real growth needs a plan change
   (owner-level). When a box *is* below the cap, 32 → 40 GiB has made a dead-looking box respond immediately.
5. Then, inside: kill stale lanes, `git gc --prune=now` on the clones, clear caches, re-run the update.
   ⚠️ **`/` is not the only volume that fills.** On a cell also read the **`cmux-tui` state volume** — a loop mount of
   `cmux-tui-state.ext4` on **`/home/cmux/.local/state/cmux-tui`**. Use that **absolute** path: a cell's login shell may have
   `HOME=/tmp/cell-home`, where a plain *directory* of the same name exists, so `df -Pm ~/.local/state/cmux-tui` answers about
   **`/`** and reports a healthy percentage — a false PASS on exactly the box you are checking. If the path moves, derive it:
   `df -Pm "$(mount | awk '/cmux-tui-state/{print $3}')"`. It fills independently of `/` and holds the terminal state the
   ladder depends on — `df` reported **99 % capacity, 947 MB of 974 MB used, 11 MiB free** on cell-3 (measured 2026-10-27,
   while `/` was at 60 %), the consumer being a `workspace-registry.sqlite3` of ~900 MB in that volume's `sessions/`. This
   volume moves — observed 31 → 11 MiB free within a single day — so **re-read it**; do not trust the figure above. None of
   the reclaim steps above touch it, and **no `cmux vm` verb resizes it** — it is a per-box loop file (`cmux-tui-state.ext4` —
   974 MB on cell-3, 3,996 MB on cell-4). **Two levers exist, and growing the file comes first because it destroys nothing.**
   It costs space from `/` (read `df -Pm /` first — cell-4 had 41 GB free at 66 % when this was measured, cell-3 60 %), and it
   runs **online**, so the daemon keeps running and the box keeps its terminal inventory:
   `sudo truncate -s +2G /var/lib/cmux/cmux-tui-state.ext4` → `LD=$(sudo losetup -j /var/lib/cmux/cmux-tui-state.ext4 | cut
   -d: -f1) && sudo losetup -c "$LD"` → `sudo resize2fs "$LD"` → re-read `df -Pm /home/cmux/.local/state/cmux-tui`.
   The mechanism is the kernel's on-line ext3/ext4 resize (`man 8 resize2fs`), and `losetup -c` is the separate step that makes
   the loop device's new size visible to it (`man 8 losetup`: `-c, --set-capacity`); verified on pi-cell-4 (2026-10-27) on a
   scratch 64 → 96 MB loop file, which `df` read as 56 → 88 MB **while mounted**. ⚠️ **Not yet run against this volume
   itself** — and the failure this recipe can silently have is NOT a refusal: with the backing file grown but `losetup -c`
   skipped, `resize2fs` **exits 0** and prints **“Nothing to do!”** while the device is still the old size. So re-read
   `df -Pm /home/cmux/.local/state/cmux-tui` and require it to MOVE: an unchanged figure means the device size was not
   refreshed, so re-run `losetup -c` and then `resize2fs` — and only if it still will not grow, or the daemon stops
   answering, stop there and fall back to the reset. A **reset** is the owner-level action, and it is
   not just an unlink: the `cmux-tui` daemon holds that registry **open** (6 fds on cell-3 — 4 read-write, one of them the
   `-shm`, and 2 read-only; *any* of them pins the inode), so deleting the file frees nothing until those fds close. ⛔ **And stopping it is not a
   small act:** the unit is `KillMode=control-group`, so `sudo systemctl stop cmux-tui-daemon.service` SIGTERMs **every process
   in it** — and it needs `sudo` (an unprivileged `systemctl stop` is "Access denied"). That cgroup held **45 processes at zero
   lanes and 124–207 with the box full** on 2026-10-27 (re-counts since: 30–38, so it moves with the lanes) — **re-count first** with
   `cat /sys/fs/cgroup/system.slice/cmux-tui-daemon.service/cgroup.procs | wc -l` (there is no `-p Tasks` property; `TasksCurrent`
   counts *threads* — 315 vs 35 processes on cell-3 — so do not substitute it). What it holds is not all lanes: on cell-3 about
   two thirds were orphaned `redislite` sidecars reparented to `ppid 1` from **dead** worktrees, the rest the daemon, one live
   lane and its `pytest`. So read the number as "open each one before you stop" — the ones you cannot re-create are the lanes.
   You are also deleting the box's **terminal inventory** — the registry that steps 1-2 are the channel *through* (the display is
   `cmux-desktop.service`, its own cgroup, and outlives the daemon) — so afterwards `exec` or the console is the only way back.
   Run the work-at-risk check below across every repo on the box first, and list the registries you expect to delete
   (`ls -d /home/cmux/.local/state/cmux-tui/sessions/*/workspace-registry.sqlite3*` — with more than one session dir,
   deleting one under-reclaims while `df` still shows an improvement). Then: `sudo systemctl stop` the unit and **confirm it actually stopped before deleting
   anything** — `systemctl is-active cmux-tui-daemon.service` must read `inactive` or `failed`; if it still reads `active`, stop
   there, because a denied `sudo`, a non-interactive lane, or `Job for … canceled` leaves the daemon holding the very fds this is
   for: the unlink frees nothing, `df` does not move, and the box loses its terminal inventory anyway. Only then delete every
   match of that glob — the `-wal` is a separate ~43 MB file and one of the pinned fds, so it goes too and regenerates smaller —
   `sudo systemctl start` it, and check **both** `systemctl is-active --quiet
   cmux-tui-daemon.service` **and** a fresh registry under `sessions/` **and** the `df` you came for — `df` alone cannot
   tell "reclaimed" from "reclaimed and now dead", and a failed start is the moment to escalate, not to recreate. A **recreate**
   is the bigger hammer and takes the whole guest: every worktree (the unpushed commits that check exists for), `keys.env`, the
   harness pin, `orchestrator/logs` + `orchestrator/state` (`merge-*.log`, `orch-loop.log`, the `state/` series), **the
   `orchestrator/*.txt` ledgers that sit directly under it** — `dispatched.txt`, `landed.txt`, `checked.txt`,
   `candidates.txt`: `install.sh:649-650` puts them BESIDE `logs/` and `state/` and `wip/`, not inside them — `:650`
   creates `candidates.txt`, `dispatched.txt` and `checked.txt`, and `install.sh` never creates `landed.txt`: that one
   arrives from `refresh-candidates.sh` (`:2951`), on any pass that gets that far — so a check that reads only `state/`
   and `logs/` misses the queue and landing ledgers — and **`orchestrator/wip/`**, the cap-killed lanes' dirty-work captures.

## 4. Liveness of a LANE, and the reaping rule

A lane's log **mtime** is the strongest *transcript-derived* signal a **harness lane** has — those run `pi -p
--no-session` (`spawn-gate.sh`, `lane-exec.sh`, `merge-one.sh` all pass it), so a lane leaves no `.jsonl`. Other `pi` on a
cell (interactive sessions, `task` children) **do** write `~/.pi/agent/sessions/*/*.jsonl` — and the count depends on WHICH home
you count (`/home/cmux` and `$CELL_HOME` held very different populations, with very different newest-mtimes, on the same box) — so never conclude "no transcript exists on a cell"; conclude "no
transcript exists *for this lane*". mtime is **necessary, not sufficient**: pair it with a CPU delta (reaping gate 1) and
an ancestry check. Size alone is not a signal, and a spinner is not.

- **0-byte lane log** = the lane could not start (usually disk full). It reads as "quiet", not broken — always check.
- A *thinking* lane and a dead one are indistinguishable **by activity readings** — zero CPU delta, frozen mtime, no size
  change. Only the **length** of the quiet window separates them, which is why the reaping gate needs a zero-CPU window
  **and** a 2 h idle bound before it acts. A live `pi` row proves **existence**, never progress.

Reap only when **all three** hold (prose → code: agent-infra#1244, #2163):

1. zero CPU delta over a sample window, summed across the wrapper **and every descendant**;
2. **no human/terminal ancestor** — walk the chain to the top; `ppid 1` proves nothing;
3. stale: log untouched ≥ 2 h, **or** no log at all **and** up ≥ 12 h.

⛔ **Never treat "no log found" as "stale."** A first dry run flagged 69 lanes and would have killed a 7-minute-old lane,
because the worktree slug parsed from shell text (`ciwatch\012[`) matched nothing. An absent artefact fails closed.

Also: `ps -eo args | grep -c '[p]i --model'` returns **0 on a box with `pi` live** — and not because of flag order. (Unbracketed, that pattern returns **1**: the grep's own argv contains it — the self-match trap §5 states as "never
`pkill -f` / `ps | grep` a pattern that appears in your own command line".)
`pi` is a Node script that **rewrites its process title**, so every live `pi` shows `args` = `pi` alone (`/proc/<pid>/cmdline`
is `pi` + NULs). The only rows carrying `--provider … --model …` are the launcher wrappers — **never a `pi` row** — so
"fixing" that pattern's flag order counts **wrapper shells**, not lanes. Enumerate with
`ps -eo comm= | grep -c '^pi$'` (or `lane-reap.sh`'s census): a low count is not a quiet box, and a high one is not lanes.
A box's `dmesg | grep -ci 'killed process'` is worth reading beside that — as context, never as a gate: the reaping gate
below decides on a CPU delta, ancestry and log staleness, and reads no OOM count at all.

## 5. Dispatching a lane

**Dispatch through the gated path — that is the only form of this section to copy:**

```bash
scripts/orchestrator-harness/nonblocking-dispatch.sh <name> <worktree> <prompt-file>
```

It backgrounds `run_agent()` from `spawn-gate.sh`, so the worker gets the **load gate, the disk headroom gate, the
wall-clock watchdog and the walltime row**. `lane.sh` and `fix-one.sh` are the same shape.

⛔ **NEVER LAUNCH A RAW `pi`.** The block below is kept only as the shape **NOT** to write — `spawn-gate.test.sh` calls
"a fourth launch path nobody routed", and its invoker census asserts the invoker SET as an equality. Note the guard's
population: it scans `git ls-files 'scripts/*'` and **skips `*.md`** — so this block cannot red it from here, and a lane
brief cannot either; only a `.sh` under `scripts/` can. The hazard is copy-paste, not CI:

```bash
tmux new-session -d -s <slug> \
  "HOME=/tmp/cell-home bash -lc 'cd <worktree>; . /tmp/cell-home/keys.env; \
   nohup pi --provider deepseek --model deepseek-flash -p \"\$(cat <brief>)\" > /tmp/cell-home/L-<slug>.log 2>&1 < /dev/null'"
```

Measured 2026-10-19: driving the cells this way is how 23 lanes landed on one box (8 cores, **32 GB**) and the kernel
killed 37 processes *and the tmux server*, losing every lane. The gate would have refused that spawn.

- Model form is split: a launch with no `--provider` may use `provider/model` (`deepseek/deepseek-v4-flash`), while the
  harness passes `--provider` and a bare `--model` (`deepseek-flash`) as two separate halves — pass BOTH, because the
  gate asserts nothing about a model NAMED on the invocation when nothing names a provider (prefixed or not): pi infers a
  prefix only when it names a provider that HAS models, otherwise it matches the whole string as a model id across every
  provider (`model-resolver.js:322-345,388-420`), so `--model deepseek/x` can run under a DIFFERENT provider than the slash
  spells, and a bare id can be ambiguous. A model INHERITED from `$PI_LANE_MODEL` is the exception the lane path relies on:
  that is asserted under `deepseek`, because `run_agent` passes exactly that as `--provider`.
- ⛔ **`keys.env` IS NOT GUARANTEED TO CONTAIN AN API KEY — AND ON A CELL IT USUALLY DOES NOT.** Measured
  2026-10-19: cell-1's file exported only `REPO CYC MAX_FIX MIN_SWAP_FREE PATH …` and **no provider key at all**; measured
  again 2026-11-04 on cell-5 (agent-infra#3443): `/home/cmux/keys.env` held **`GH_TOKEN` and nothing else**. The lanes that
  worked had their key in the *ambient* environment (inherited from the tmux server), so a lane launched through `keys.env`
  alone died instantly with `No API key found…` and its log stopped at the banner. Before dispatching on any box:
  ```bash
  [ -n "$DEEPSEEK_API_KEY" ] && echo key-ok || echo KEY-MISSING          # the AMBIENT env, which is what pi reads
  ( unset DEEPSEEK_API_KEY; . "$HOME/keys.env"; [ -n "$DEEPSEEK_API_KEY" ] && echo file-has-key || echo FILE-HAS-NONE )
  ```
  ⛔ **AND THAT SECOND LINE NEEDS ITS SUBSHELL** (measured, agent-infra#3443 review round 2). `env … . file` cannot work —
  `.` is a shell builtin, so `env` reports `env: '.': Permission denied` (exit 126) and the test then prints
  **`FILE-HAS-NONE` for a file that DOES hold the key**. That is the same false negative this section exists to remove,
  printed by the check meant to catch it; the parenthesised subshell both isolates the sourced variables and returns the
  right answer.
  and 60 s after launch check `grep -c 'No API key found' /tmp/cell-home/L-<slug>.log` — **0 is the pass condition**. A
  lane log that sits at ~5 KB without a tool call is almost always this, not a slow model.
- ⛔ **AND THE FIX IS THE MODEL FLAG, NOT THE KEYS FILE — the half #3331 got wrong (agent-infra#3443, measured 2026-11-04 on
  cell-5).** `pi` printed `No API key found for the selected model.` — a sentence that names **no provider**, which is what
  `pi` says only when nothing was available to that process — so **sourcing `keys.env` cannot fix a file that holds no model
  key at all**, and a key visible in *your* shell proves nothing about the lane's own environment. What worked on the same box was the
  invocation, not the credential:
  ```bash
  pi -p --no-session --model deepseek/deepseek-flash …        # or --provider deepseek --model deepseek-flash
  ```
  So pin the pair — and read that sentence carefully, because the two id forms are not interchangeable: with **no**
  `--provider`, spell the model as `provider/id` (`deepseek/deepseek-flash`), which is unambiguous; a bare id resolves unreservedly only when exactly one provider exposes it, and
  with several matches it relies on exactly one of them being authenticated — otherwise it is rejected as ambiguous
  (`resolveCliModel`'s exact-match fallback). The harness passes the two
  halves separately (`--provider deepseek --model deepseek-flash`). Verify with `pi --list-models` before dispatch.
  ⛔ **AND AN UNPROVISIONED PIN IS A SILENT SUBSTITUTION, NOT A DEATH — do not diagnose it as one.** `pi` uses the
  `settings.json` startup pair ONLY when that provider is provisioned (`findInitialModel` step 3 requires
  `hasConfiguredAuth`) and otherwise falls through to step 4 of `findInitialModel` — the first model with a valid key, preferring the known default model of that provider — so a box pinned to an unprovisioned
  model runs a model nobody pinned, silently, and spends tokens on it. Since #3443 `lane.sh` prints the model it asserted
  (`[key-gate] … model=<id> …`) and emits `check=warn reason=box-default-not-provisioned model=… var=…` when the box's
  STARTUP pair is unusable — that line is about a **bare `pi`** (one with no model flag) and it does not stop the lane,
  which pins its own pair. Also note `No API key found for the selected model.` and `No API key found for <provider>.` are
  two different sentences: only the second names the provider whose credential is missing, and #3443 is the record of how
  much was inferred from the first.
- ⛔ **THE REDIRECTED `HOME` IS WHAT HID THE CREDENTIAL — closed on a converged box, still the trap on one that is not**
  (agent-infra#3331, measured 2026-11-02 on two cells; unified by agent-infra#3453). A lane runs with `HOME=$CELL_HOME`, and
  `$CELL_HOME` is **DERIVED** by `scripts/lib/cell-home.sh` — the ACCOUNT home (`/home/cmux`) on a converged cell, never the
  legacy `/tmp/cell-home` — so do not set either by hand. On a box that has NOT been converged the operational layer
  (`record-review.sh`, the gh shim, the extensions) lives under the legacy home while the model credential lives in the
  **ACCOUNT** home's `keys.env` (`/home/cmux/keys.env`), and `lane-env.sh` sources `${ENV_FILE:-$HOME/keys.env}` — the
  *redirected* one. So **the single setting that made the operational layer work was the setting that hid the credential**,
  and the lane died in seconds having done nothing. Check the box with `bash scripts/cell-home-migrate.sh --check` before
  diagnosing a credential. Three consequences for an operator:
  launch with the harness (`lane.sh`/`lane-exec.sh`, which pin the pair) rather than a hand-written `pi` line; read the
  lane's LAST log line before concluding anything — since #3331 `lane.sh` refuses a keyless environment **before** spawning
  `pi` (`[key-gate] … result=REFUSED var=<NAME>`, exit **82**) and every lane log ends with
  `outcome=<done|refused|failed|died> reason=<token>`; and ⛔ **do not treat "source `keys.env`" as the remedy** — that was
  #3331's text and #3443 falsified it (the file can hold no key at all; the fix was the model flag, above). A log that
  STOPS is not proof of a key problem either: the #3331 record falsified that, and the cause it VALIDATED is the launch
  directory (next bullet).
- ⛔ **`pgrep -f "pi -p"` IS NOT A LIVENESS TEST — IT MATCHES THE DIAGNOSTIC'S OWN COMMAND LINE.** Measured during the
  #3331 investigation: `pgrep -fc "pi -p|pi --"` returned **3 for a dead lane**, because the pattern appears in the
  command the operator just typed (and in any monitor that greps for it). It reported "alive" until the read was
  re-measured with a CPU-time delta. Liveness comes from a POSITIVE read of the lane's own artifact — the
  **run-scoped** verdict `cat $O/logs/lane-<N>.outcome` (written by the lane's exit trap, removed AND re-owned by the
  next dispatch of the same issue, so its absence means "no verdict for this run"), a
  transcript mtime/size delta, or a CPU-time delta (`lane-status.py`, `lane-bound.sh`'s
  `cpu_cs`) — never from a process-name match. ⛔ **and the run-scoped file is not absolute either**: a previous attempt
  that is still ALIVE can write its line into the new run's file in the dispatch handover window (read → re-stamp →
  write is three steps, stated as a residual in `lane.sh`), and the log is append-only, so `grep '^outcome=' <log> |
  tail -1` can hand you the PREVIOUS attempt's verdict. Cross-check the timestamp and `lane=`/`rc=` fields rather than
  trusting either source alone. See `docs/ops/fleet-liveness.md` (agent-infra) for the one verdict
  function, and prefer a bracket (`pi [-]-model`) or a script file run detached when a kill pattern is unavoidable.
- ⛔ **LAUNCH A CELL LANE WITH ITS CWD INSIDE A GIT REPOSITORY OR WORKTREE — NEVER A BARE DIRECTORY LIKE `/tmp`.** This is the
  cause the #3331 record VALIDATED after four falsified hypotheses: a lane launched from a non-repo directory dies on the first
  git-dependent hook (`fatal: not a git repository (or any of the parent directories): .git`), and the *only* difference between
  a 6,180-byte log that died mid-work and a 16,812-byte log that reached `agent_end → session_shutdown` was the launch
  directory. The probes that "worked" from `/tmp` (a PONG, a local read) were runs that never triggered a git call. So: `cd`
  into the checkout (or the lane's worktree) before launching, and treat "worked from /tmp" as evidence of the opposite.
- A 0-byte lane log with a live `bash` pane means **`pi` was killed inside the session** — check `dmesg | grep -ci 'killed
  process'` and `free -m`: that is the OOM cliff, and the fix is fewer lanes, not a restart.
- Ship a brief by base64+gzip (`printf %s '<b64>' | base64 -d | gunzip > brief.md`) — a 113 KB inline heredoc times out,
  and shell quoting inside `cloud exec` mangles multi-line text.
- Never `pkill -f` / `ps | grep` a pattern that appears in your own command line: it matches the caller. Use a bracket
  (`pi [--]model`) or ship the kill as a script file and run it detached.
- One lane = one worktree = one branch. Give the lane the exact issue number and tell it to measure before changing.
- ⛔ **A LANE LAUNCHED WITH `pi -p` CANNOT BE STEERED.** `-p` (print mode) takes its prompt from argv, runs one turn and
  exits; it does not read stdin. So `tmux send-keys -t <lane> "…new orders…"` types text that **nothing consumes** — the
  log never shows it and the lane keeps doing what its original brief said. Measured 2026-10-19: 9 lanes ordered to stop
  producing and start landing, `order-seen=0` on every one. To change what a lane is doing you must **kill the session and
  relaunch it with a new brief** — which also means a brief must be right when it is written, because there is no
  mid-flight correction available. (For a steerable session, launch interactive and dispatch with tortoise's
  `tools/cmux_dispatch.py` — it confirms the message became a turn. That tool is not installed on the cells; there,
  use `nonblocking-dispatch.sh` and a new brief.)

## 6. Landing work from a lane — the five-step contract

The single biggest waste measured: lanes doing the work and then failing to land it. `record-review.sh` **requires
`--evidence`**, and that evidence must be a real PR comment that postdates the diff. Five steps, in this order:

```bash
scripts/record-review.sh --print-diff-hash <pr>              # 1. what the gate sees
#                                                            2. ONE fresh-context review of the diff
# 3. post the review as a comment on the PR, keep its id (REST: POST /repos/<o>/<r>/issues/<n>/comments)
scripts/record-review.sh <pr> <head_sha> clean <owner/repo> --evidence comment:<id>   # 4. bind to the head
bash scripts/admin-merge.sh <pr>                                                      # 5. land it, via the rail
```

- `--evidence` missing ⇒ no `clean` record can be minted. A lane that skips step 3 **loops forever**: the gate says "no
  reviewers dispatched", the lane dispatches another reviewer, nothing is recorded, the gate refuses again (agent-infra#2148).
- A record for a non-current head is **refused (exit 3)**. Never `--force-stale`.
- **Never edit the PR body after recording** — it wipes the attestation.
- One reviewer child per PR; two rail attempts. A refusal while an attestation exists at the head is a **harness defect to
  record**, not a loop to retry. ⛔ **Scope: that rule is about refusals of the EVIDENCE** — the gate rejecting an
  attestation that exists. It does **not** cover the rail refusing because the **base tree** is red; that is the rail
  working correctly, and it names its own remedy (see §6.5). `queued` / `in progress` is neither a failure nor a stall.

### 6.5 Batching several reviewed PRs into one landing

**Measure first — batching is a fix for a queue that may not exist.** Before building a batch, measure whether CI
concurrency is actually binding. If there are free GitHub-hosted slots and runs finish in single-digit minutes,
batching buys nothing. Measured 2026-11-02 on this account: **12 of 40 hosted slots in use, 28 free, 1 job queued,
runs finishing in 1–8 minutes** — the waits were elsewhere. Quote the reading you took, not this one.

**What a batch does and does not save.** It saves **(a)** CI runs — one run instead of N — and **(b)** base-drift
re-reviews, because N PRs are judged against one base instead of each being re-reviewed as `main` moves under it.
It does **NOT** remove the review of a **changed diff**: if a PR gained commits after its review, someone must read
those changes whether they land alone or in a batch. One review of the union, not zero reviews.

**⛔ Eligibility — ask `--check-carry`, never "it is probably still fine".** A record is bound to a head *and* to a
`diff_sha256`. "Slightly stale" is not something you can judge by eye: a moved **base** and a PR's own **content
changing** look identical from the outside, and only one of them is safe.

```bash
scripts/record-review.sh --check-carry <pr> <owner/repo>   # prints: <verdict> TAB <record digest|-> TAB <live digest|fetch-status>
```

⚠️ **The verdicts are not three, and THREE of them cost you a review cycle if you misread them** (`carry-patch`,
`nodigest`, `unreadable`). The columns are **not uniform** — `norecord`/`nodigest` print `-` in column 2, and
`unreadable` prints the **fetch status** in column 3 instead of a digest — so **branch on the verdict, never parse the
columns**. Read all of
them off the tool's own output/exit code — never off this table alone, and never off "it looks stale":

| verdict | meaning | what to DO |
|---|---|---|
| `head` | bound to the CURRENT head | ✅ land it |
| `carry` | the reviewed **DIFF is unchanged** — only the base moved | ✅ the gate carries it — land, do not re-review |
| `carry-patch` | the reviewed **PATCH is byte-identical** but the rendered diff moved (a rebase/base move). The gate will NOT carry it as-is | ⚠️ **re-record at the current head — do NOT run a review cycle** |
| `nodigest` | the record carries no usable diff digest (legacy, or minted during a degraded read) | ⚠️ re-record at the current head — that is a **CARRY, not a fresh review** |
| `fresh` | **the DIFF CHANGED** — the record does not cover what would merge | ⛔ run a review, or drop it from the batch |
| `norecord` | no record in **this box's** store | ⛔ a review — **but take the cheaper paths the tool prints first**: `scripts/registry-sync.sh pull` (it may have run on another box) and `record-review.sh --recover-body <pr> <owner/repo>` (the PR body carries a signed marker). An absence here is **not** evidence no review happened |
| `unreadable` | the PR's live diff **could not be READ** (transport, shared gate queue, rate limit) | ⚠️ **RETRY** — this is NOT a changed diff and NOT a carry |
| `red-surface` | **the head's check surface is RED** and the red is **not** base-owned (#3440). The head judged is the one that would MERGE: on the `carry` arm that is the LIVE head, not the recorded one | ⛔ **NOT mergeable** — fix or re-run the failing checks. A **re-review is not the remedy for a broken build** |
| `red-base-owned` | the head is RED but **every red group also reproduces on the base** (#3440) — the groups are **named** on stderr | ⚠️ the record **does** cover the artifact, so no review is owed. **On a rail repo** the rail re-measures base reds against its own reproduction and that is the merge decision; **in gate mode nothing else verifies it**, so treat this as a *named residual*, not a green light. Never report the head as green — say which groups |
| `surface-unknown` | the head's check surface **could not be READ** (#3440) — a refused API read, or no repo resolved to scope the query | ⚠️ **RETRY** — a failed read is its own answer, never a green one |

`carry-patch`, `nodigest` and `unreadable` are the expensive mistakes: each one *looks* like "needs re-review" and
isn't. `unreadable` in particular is a transient read failure, and a lane that re-reviews on it burns a full review
cycle for nothing. **`red-surface` is the mirror-image mistake**: it *looks* like a reason to re-review, and it is
not — a red build needs a fix or a re-run, and a review of a red tree tells you nothing about the tree.

⛔ **`head` is NOT a statement that the tree is green** (#3440). `head`/`carry` certify the **record's identity**
with the diff that would merge; the check surface is reported separately (and `red-surface`/`surface-unknown`
refuse). A head whose surface is **empty** or **in flight** still answers `head`, loudly, because an absent
surface is not evidence of anything — so if you need "is this head green", **read the checks yourself**; do not
read it off a carry verdict.

**A conflict resolved at batch time does NOT repair `fresh`.** Resolving a conflict reconciles a moved base; it says
nothing about an unreviewed diff. Measured 2026-11-02 to show how sharp this is: of six open PRs carrying a *clean*
record, **five returned `fresh`** — the batch was two PRs, not six.

**⛔ `main` must be green before the batch means anything.** A batch branch is cut from `main`, so it inherits every
red on `main`, and a batch is then red for a reason that has nothing to do with its contents. **Read `main`'s own sha**
(never a rollup, never `/status`), and group check-runs by **(app, workflow, job name)**, taking the newest attempt by
**`id`** — because **a re-run ADDS a red, it does not clear one**. `~/.pi/agent/AGENTS.md` holds that rule and the reason
it is not just "by job name": two workflows can publish the same job name, so a name-only grouping lets the newest of
one mask the other and yields a **FALSE GREEN on `main`**. Do not simplify the key.

**⛔ Do NOT paraphrase the rail's red-base refusals — read them off the rail.** It has several (an already-red base the
PR does not repair; a base red the PR has not measured; a merge ref lagging a red base; a merge-ref base parent it
could not read), **each printing its own message**, and this skill is not their source of truth. A paraphrase written
from review findings was wrong in a new way on five consecutive rounds, which is the signal to stop writing it: run the
rail and read what it prints.
Two things worth knowing before you guess a remedy — **the remedy differs per step** (one step says fix the failing
check; two re-measure and re-run; one says check auth/network), and when a review record is bound to the PR head the
rail will **not** move that head (`refresh_pr_branch`), so "just re-run it until it passes" is not a remedy for every
step.

**Fixing `main` is the higher-leverage move: one green `main` makes EVERY PR attestable, while batching makes only the
handful in the batch.**

**Build it**

```bash
git fetch origin            # ALL branches: merging origin/<branch> refs this clone never refreshed silently lands
                            #   stale tips — a different commit set than --check-carry approved above
git worktree add .worktrees/batch-<date> -b batch/<date> origin/main
cd .worktrees/batch-<date>
for b in <branch1> <branch2> ...; do git merge --no-ff "origin/$b" -m "batch: $b"; done   # resolve conflicts HERE
git push origin batch/<date>
gh pr create --base main --title "batch(<date>): N reviewed PRs" --body-file <file>
```

Then treat it as ONE PR under §6 above: **one** fresh review of the **union** diff, **one** `record-review.sh` at the
batch head, **one** rail. The constituents' own records justify *inclusion*; the attestation that lands is the
batch's. ⛔ **The constituents will NOT close as merged.** The rail defaults to `--squash`
(`scripts/admin-merge.sh:558-566`, applied at `:7754`), and a squash lands a **NEW** commit — the constituents' tips
never become ancestors of `main`, so GitHub has no ancestry to close them on, and they stay **open**, closable only as
"closed". So do exactly one of two things, and say which you did: **close them by hand** after confirming their
content is in the batch commit, or land the batch with an explicit method —
`bash scripts/admin-merge.sh <pr> -- --merge` (the pass-through is an allow-list, `:550-556`) — and only then may you
rely on ancestry. **Verify which actually happened; do not assume either.**

**Traps**

- **Blast radius.** One bad commit in a batch blocks N changes and makes the revert N-wide. Prefer small batches of
  related work over one grand bundle.
- **A conflict resolution is an unreviewed change.** It produces a NEW diff on the batch branch that nobody has read.
  If a constituent conflicted during the build, the batch review must cover that resolution explicitly.
- **`fresh` is not "slightly stale".** The check exists precisely because the safe and unsafe cases are
  indistinguishable to the eye.
- **Never edit a PR body after recording** (§6) — and the batch body is the one people forget, because it naturally
  wants updating as members land. Put new information in a comment.

## 7. Fleet roles and what "full capacity" means

The shape below is durable; the **numbers are a reading** — re-read `cmux vm stats` (RAM) and the guest's own `df -Pm /` (disk) at
dispatch time, because both move.

| box | role | shape (measured 2026-10-27; re-read it) |
|---|---|---|
| `pi-cell-1` | product work | 16 GB / 8 vCPU / 128 GB — the **same shape as cell-4**, and **activated in the operative home** (`/tmp/cell-home`: `record-review.sh` + the `gh` shim, merge lanes ran on it 2026-10-27). Its `/home/cmux` home has **no `gh` shim**, so check which `HOME` a lane will get before expecting it to land |
| `pi-cell-3` | product work | 8 GB RAM / **4 vCPU** / 128 GB — the fleet's lowest-core box, but the **same pinned `MAX_LANES=20` as the 16 GB ones** (the `keys.env` pin, §7 below): 20 is twice the core-derived 10, on a box §2's arithmetic puts nearer 6 lanes and whose own aid now answers 2–3. It has OOM-killed too (`dmesg`: 2), so **§2's rule is the same as cell-4's: reserve UP, fewer lanes** |
| `pi-cell-4` | product + CI-cost work | 16 GB / 8 vCPU / 128 GB — the current default dispatch target, and **the box with the most OOM kills of the three (5)**: per §2 that means its reserve goes UP, i.e. fewer lanes here, not more |
| laptop | product + orchestration | the only box that can reach every channel; do not overfill it |

⛔ **TWO DIFFERENT CEILINGS — DO NOT CONFUSE THEM, AND DO NOT TREAT EITHER AS THE WHOLE ANSWER.** The owner ruled on
2026-10-17 (`docs/ops/fleet-capacity.md`) that **between boxes** dispatch is gated on capacity, not a lane count — that is
`cap_place`, and the objection is to a count standing in for capacity **across a fleet**. **Inside one box there IS a real
ceiling**: `MAX_LANES` — `2.5 × cores` when unset (`orch-loop.sh`: `10#$_NCPU * 5 / 2`; **on the laptop it is rendered into the
launchd plist** by `install.sh` from `scripts/orchestrator-harness/launchd.plist.template`'s `__MAX_LANES__`), **but the cells pin it** (`keys.env`:
`export MAX_LANES=20` — operator-pushed, so re-read it), and all three enforce 20 today regardless of core count:
cell-3 (8 GB, 4 vCPU) and cell-4 (16 GB, 8 vCPU) both refuse at `lanes >= 20` (`GATE_WHY=lanes=N>=max_lanes=M`). That is
exactly why the number cannot be trusted as capacity — on cell-3 it admits 20 lanes into 8 GB. It is real — and the *number* knows
**neither disk nor RAM**. The controller's own refusals (`mem_avail <= MIN_MEM_FREE_MB`, default 512; the swap gate, which
arms only when RAM is tight; and the load gate) sit in the same `GATE_WHY` chain — but they are floors and gates, **not a
per-lane budget**, so `MAX_LANES` remains an upper bound rather than the answer. The binding constraint is **free disk vs one lane's
`tree + reserve`** (§2), then free RAM against the per-lane peak, then load. So this table names a box's ROLE, never a
number of lanes.

⚠️ **`docs/ops/fleet-capacity.md` states the contrary twice** — `:157` *"there is deliberately no lane ceiling
tied to cpu count"*, and `:283` restating it as "§4's ruling" (the doc's own cross-reference is stale: that text sits at
`:157`, inside §5) — while the code has the 2.5× rule. **Two recorded positions, unresolved** — this skill reports what
the code does and does not claim the doc is wrong. Whoever settles it should mark the resolution `OVERRIDES:` in the doc:
silently letting a reader pick one is how a ruling gets tidied away.

A dispatch decision is only honest if it names: the box's **free disk**, its **free RAM**, its **live lane count**, and the
**lane's expected cost**. If a box is not dispatching by itself and is not at capacity, that is the signal to intervene —
not a load average measured earlier.

## 8. Traps that produced wrong conclusions today

- `ls -d harness/*/ | tail -1` picks the **alphabetically last** dir, not the newest — use `ls -dt ... | head -1`.
- A readiness banner (`CELL READY`, `up`) is a claim; `git rev-parse`, `ls` of the artifact, and `record-review.sh` existing
  are facts.
- An `exec` timeout is not evidence about a box; a silent exit 0 from `cmux cloud ls` is **unreachable**, never "no fleet".
- A stale heartbeat file does not mean the loop is dead (`orch-loop.log` mtime does).
- Killing a controller is futile when launchd `KeepAlive` + a 20 s watchdog recreate it — and a lane can spawn one.
- `TERM`/`INT` traps that swallow signals leave the script running: a stop/restart appears to hang (agent-infra#2085).
- Deleting a worktree to make space must never destroy unpushed work, and the guard has to **read the right trees, in a
  population sized to what you are destroying, and fail closed.** Six traps, each measured on a cell:
  - `git -C "$wt" rev-list --count '@{u}..HEAD'` **exits 128 with empty stdout** on a branch with no upstream — often the
    branch holding the unpushed work — so an error is UNSAFE, never clean.
  - **`--not` negates every revision after it**, so `rev-list --count --not --remotes HEAD` counts nothing and prints `0` for a
    worktree that has unpushed commits (measured `0` as written, `1` corrected, same tree). Positive end first.
  - **`awk '{print $2}'` truncates a path containing a space** — and if another worktree exists at the truncated path the guard
    measures *that* tree and prints a clean line **twice**, saying nothing about the real one. Read the porcelain stream
    (`sed -n 's/^worktree //p'`, then `while IFS= read -r`), never a field.
  - **A pipeline ending in `wc -l` (or `grep -c`) cannot fail**, so `d=$(… | wc -l) || d=UNKNOWN` never fires and a *failed*
    `git status` prints `dirty=0`. Test `git status` itself, then count.
  - **The population depends on the destruction.** Deleting a *worktree* needs its repo's trees; a **recreate** or the
    `cmux-tui` reset takes the whole guest — on cell-3 that was **five repos**, with unpushed commits in trees outside `$REPO`. Count them,
    never quote a count: the tree total moved 22 -> 29 within a day of readings, so a number written here becomes a wrong
    number that the next reader plans against. ⛔ **The fifth member is the ai-drainer's SEED_REPO, and it is not necessarily where the
    documentation says.** `ai-drainer.sh` creates `$AI/wt-drainer-<lane>` with `git -C "$SEED_REPO" worktree add` (search
    that phrase; `AI` defaults to `$HOME/orchestrator-ai`), and `install-drainer-timer.sh:72` defaults
    **`DRAINER_SEED_REPO`** to `$HOME/agent-infra-main` at **install** time — the unit-side name `SEED_REPO` is only what the
    template renders that value into (`:129`), so exporting `SEED_REPO` yourself and re-running the installer changes nothing. ⛔ **Do not carry a value from this page: the unit itself moves.** The
    template always renders the knob (`templates/systemd/eldato-ai-drainer.service:36` → `Environment=SEED_REPO={{SEED_REPO}}`),
    so the value in force is a `systemctl cat eldato-ai-drainer.service` reading — and on `pi-cell-4` the **same box gave two
    different answers the same day**: an earlier reading had a wrapper (`ExecStart=/bin/bash $CELL_HOME/run-ai-drainer.sh`,
    whose own `SEED_REPO=/tmp/cell-ai-main`) with **no** `Environment=SEED_REPO=` at all, while the 2026-10-27 14:08Z reading
    had `ExecStart=/bin/bash /home/cmux/agent-infra/scripts/orchestrator-harness/ai-drainer.sh` with
    `Environment=SEED_REPO=/home/cmux/agent-infra` — the unit had been reinstalled between the two, and
    `$CELL_HOME/agent-infra-main` does not exist in either. So **read it, then derive the seed checkout from the trees** —
    `git -C <any $AI/wt-drainer-*> rev-parse --git-common-dir` names the repo that owns them (at 14:08Z it answered
    `/home/cmux/agent-infra/.git`, the unit's value, not the wrapper's). Naming a
    `wt-drainer-*` path itself *does* work (`git worktree list` inside a linked checkout lists the whole repository,
    measured) — the reason not to is that `ai-drainer.sh` **reaps** those trees as soon as a lane dies (`_rm_wt`,
    `_reap_leftovers`), so a path named now is gone later, and a missing path turns that repo into an `AT-RISK-UNKNOWN`
    exit 1 instead of a reading. And `HEAD` is not the box's work: a local branch that no worktree holds as `HEAD` dies in a
    recreate too — the block's `BRANCH-AT-RISK` lines are that reading, so count them there, never from a number here.
  - **`git status --porcelain` omits ignored state**, so the block reports it in a third column: the ignored paths **inside
    each worktree of `$REPO`** (`.venv/`, `__pycache__/`, `.worktrees/`, caches). An ignored **count** never moves the exit
    code (an unreadable one sets `1`, like every other UNKNOWN), so a `0` never means "nothing here matters" for a recreate.
    ⛔ **The two things a recreate actually destroys are in no worktree at all**: `keys.env` and `orchestrator/{state,logs}/`
    live in `$CELL_HOME`, which is not a git repo (`git check-ignore` in the cell repos returns nothing for `keys.env`), so no
    `!!` line can ever report them and `ignored=0` says nothing about them. The guest block checks those separately, and
    their **presence sets `2`** — a printed `BOX-AT-RISK` with `rc=0` would be the false PASS this section exists to prevent.
  Run it as a loop over the stream, and let the **exit status** carry the verdict (`0` every tree read, no unpushed commits, no
  dirty or untracked paths · `1` something could not be read · `2` work at risk). `continue` outside a loop is a no-op, and a block
  whose stdout says "at risk" while it exits 0 teaches the caller to ignore it:
  ```bash
  # EXIT: 0 = read clean · 1 = something could not be read · 2 = work at risk (read the lines)
  if ! { [ -n "${REPO:-}" ] && git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; }; then
    echo "AT-RISK-UNKNOWN repo=${REPO:-<unset>}"; exit 1
  fi
  # BOTH population reads are asserted first: an enumeration that fails must not read as a clean box.
  WTS=$(git -C "$REPO" worktree list --porcelain 2>/dev/null) || { echo "AT-RISK-UNKNOWN worktree-list $REPO"; exit 1; }
  [ -n "$WTS" ] || { echo "AT-RISK-UNKNOWN worktree-list-empty $REPO"; exit 1; }
  BR=$(git -C "$REPO" for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null) \
    || { echo "AT-RISK-UNKNOWN for-each-ref $REPO"; exit 1; }
  rc=0
  while IFS= read -r wt; do            # sed, not awk: keep paths that contain spaces whole
    if ! { [ -d "$wt" ] && git -C "$wt" rev-parse --git-dir >/dev/null 2>&1; }; then
      echo "AT-RISK-UNKNOWN $wt"; [ "$rc" = 0 ] && rc=1; continue
    fi
    n=$(git -C "$wt" rev-list --count HEAD --not --remotes 2>/dev/null) || n=UNKNOWN
    if d=$(git -C "$wt" status --porcelain 2>/dev/null); then
      d=$(printf '%s' "$d" | grep -c '^' || true)
    else d=UNKNOWN; fi
    if o=$(git -C "$wt" status --porcelain --ignored 2>/dev/null); then
      ig=$(printf '%s' "$o" | grep -c '^!!' || true)
    else ig=UNKNOWN; fi
    case "$n" in UNKNOWN|"") n=UNKNOWN; [ "$rc" = 2 ] || rc=1 ;; 0) ;; *) rc=2 ;; esac
    case "$d" in UNKNOWN|"") d=UNKNOWN; [ "$rc" = 2 ] || rc=1 ;; 0) ;; *) rc=2 ;; esac
    [ "$ig" = UNKNOWN ] && { [ "$rc" = 2 ] || rc=1; }
    echo "WT $wt unpushed=$n dirty=$d ignored=$ig"
  done < <(printf '%s\n' "$WTS" | sed -n 's/^worktree //p')
  if s=$(git -C "$REPO" stash list 2>/dev/null); then        # refs-wide: once per repo, never per tree
    if [ -n "$s" ]; then echo "$s" | sed 's/^/STASH-AT-RISK /'; rc=2; else echo "STASHES 0"; fi
  else echo "STASH-UNKNOWN $REPO"; [ "$rc" = 2 ] || rc=1; fi
  while IFS= read -r br; do                                  # a recreate also loses local branches
    [ -n "$br" ] || continue
    bn=$(git -C "$REPO" rev-list --count "$br" --not --remotes 2>/dev/null) || bn=UNKNOWN
    case "$bn" in UNKNOWN|"") bn=UNKNOWN; echo "BRANCH-UNREADABLE $br"; [ "$rc" = 2 ] || rc=1 ;; 0) ;; *) echo "BRANCH-AT-RISK $br $bn"; rc=2 ;; esac
  done < <(printf '%s\n' "$BR")
  echo "VERDICT $rc"; exit "$rc"
  ```
  `UNKNOWN` is an error, not a zero. **For anything that takes the whole guest — a recreate, the `cmux-tui` reset — save the
  block to a file and run it once per repo, keeping the worst status.** Inlining it in a loop cannot work: it ends with
  `exit`, so the first repo would end the loop.
  ```bash
  W="${W:-/tmp/work-at-risk.sh}"      # the block above, saved; named explicitly so it runs from any cwd
  [ -f "$W" ] || { echo "AT-RISK-UNKNOWN work-at-risk-missing $W"; exit 1; }
  [ -d "${CELL_HOME:-}" ] || { echo "AT-RISK-UNKNOWN CELL_HOME=${CELL_HOME:-<unset>}"; exit 1; }
  rc_all=0
  # The seed checkout is whatever repo owns the drainer's trees — DERIVED, never assumed. On pi-cell-4 it was
  # /tmp/cell-ai-main under one install of the unit and /home/cmux/agent-infra under the next (2026-10-27), while
  # install-drainer-timer.sh:72's DRAINER_SEED_REPO default ($HOME/agent-infra-main) exists in neither — which is why this DERIVES instead of
  # reading the unit: `systemctl cat` is the value in force, the trees are the value that matters.
  seed=""
  for w in "${AI:-$HOME/orchestrator-ai}"/wt-drainer-*; do
    [ -d "$w" ] || continue
    seed=$(git -C "$w" rev-parse --git-common-dir 2>/dev/null | sed 's|/\.git$||')
    [ -n "$seed" ] && break
  done
  # The population is the roots this block can SEE, one level deep: $REPO, the derived seed, /tmp/cell-*, "$CELL_HOME"/*, and
  # /home/*/*. That last root is not optional: exec's HOME is /home/cmux while the login shell's is $CELL_HOME, so the two
  # homes are different trees — measured on pi-cell-4 (2026-10-27), /home/cmux/agent-infra and /home/cmux/tortoise are repos
  # this root reaches and the $CELL_HOME glob never does. A repo parked anywhere else is INVISIBLE here, and a `0` does not
  # speak for it, so add its root before trusting the verdict. A path you only BELIEVE is there is not a floor either — it is
  # a permanent exit 1 on every run, which trains the reader to discount the stop signal; a path that exists and is not a repo
  # still reports AT-RISK-UNKNOWN. Streamed one path per line so a path with a space survives, for the same reason the block
  # above reads the porcelain stream instead of awk fields.
  # `$REPO` is asserted HERE, not left to the glob below: an unset one emits an EMPTY line, `sort -u` keeps it, the
  # `[ -n "$POP" ]` floor passes on any other root that matched, and the loop's `[ -n "$R" ] || continue` drops it — so the
  # one repo the caller named is the one never read. Block 1 fails closed on exactly this input; this half must not be weaker.
  [ -n "${REPO:-}" ] || { echo "AT-RISK-UNKNOWN REPO=<unset>"; exit 1; }
  POP=$( { printf '%s\n' "$REPO"
            [ -n "$seed" ] && printf '%s\n' "$seed"
            for d in /tmp/cell-* "$CELL_HOME"/* /home/*/*; do [ -e "$d/.git" ] && printf '%s\n' "$d"; done
          } | sort -u )
  [ -n "$POP" ] || { echo "AT-RISK-UNKNOWN no-repos $CELL_HOME"; exit 1; }   # nothing enumerated is not "clean"
  while IFS= read -r R; do
    [ -n "$R" ] || continue
    ( REPO=$R bash "$W" ) || { s=$?; [ "$s" -gt "$rc_all" ] && rc_all=$s; }
  done <<< "$POP"
  # ⛔ `orchestrator/wip/` and the `orchestrator/*.txt` ledgers are NOT optional extras on this list. `install.sh:649-650`
  # creates `logs/ state/ wip/` plus `candidates.txt dispatched.txt checked.txt` SIDE BY SIDE under `$O`, and `wip/` holds the
  # only copy of a cap-killed lane's dirty work (`spawn-gate.sh:844` writes `wip/capwip-<stamp>-<pid>/`; the README's state
  # table documents it). A list of three named paths was the list that lost them.
  for f in "$CELL_HOME"/keys.env "$CELL_HOME"/orchestrator/state "$CELL_HOME"/orchestrator/logs \
           "$CELL_HOME"/orchestrator/wip "$CELL_HOME"/orchestrator/*.txt; do
    # outside every repo, so no worktree read can see these. Their PRESENCE is work at risk and must move the CODE: printed
    # alone with rc=0 the caller proceeds with the recreate and destroys exactly the paths this line names — which is
    # the "stdout says at risk while it exits 0" failure stated three paragraphs up. The `*.txt` arm is a GLOB on purpose:
    # the next ledger the harness adds is then covered without an edit here, and a transcribed list is how one goes missing.
    [ -e "$f" ] && { echo "BOX-AT-RISK $f"; rc_all=2; }
  done
  echo "GUEST VERDICT $rc_all"; exit "$rc_all"
  ```
  **Nothing above is a list you carry**: the seed comes from the trees and the rest from a glob, every run. A transcribed list
  is the list that omits the repo holding the work — the version of this block that hardcoded four paths printed
  `GUEST VERDICT 0` on cell-3 while a repo it never opened held `unpushed=8` and `unpushed=2`. So confirm the enumeration before
  trusting a `0`: it must name a `VERDICT` line per repo, and an empty population is not a clean box — if the glob and `$REPO`
  yield nothing, treat the run as unreadable, not as permission. Preserve, then remove only the regenerable parts.
- **Capacity is a MEASUREMENT, not a constant.** Every earlier version of §2 substituted one number for the lane type and one
  for the reserve, and both errors ran in the direction that **refuses** dispatches it should allow. The figures in §2 carry
  their date and method so the next reader can re-derive them instead of inheriting them.

> Continue following the workflow as mandated by this skill. Do not skip steps.
