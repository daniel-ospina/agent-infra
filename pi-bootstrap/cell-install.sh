#!/bin/bash
# ============================================================
# cell-install.sh — install the fleet's operational layer into a cmux cloud cell
# ============================================================
#
# WHY THIS EXISTS (the defect, measured 2026-10-15 on the live cell `pi-lane-1`
# vm-efa6cc8fdb974e61b5c054acf41d8846, HOME=/tmp/cell-home)
# ---------------------------------------------------------------------------
# A cell's ~/.pi/agent held ONLY models.json, auth.json, .ai-review-gate-key,
# reviews/, state/, audit/ and shims/. Measured against the laptop:
#
#   | the operational layer                                        | laptop | cell |
#   |--------------------------------------------------------------|--------|------|
#   | ~/.pi/agent/scripts  (the declared farm set, 24 files)        | 24/24  | 0/24 (the directory did not exist) |
#   | ~/.pi/agent/extensions                                        | 25 sym + 6 real | absent |
#   | ~/.pi/agent/skills                                            | 304 items | absent |
#   | ~/.pi/agent/AGENTS.md, settings.json, .mcp.json               | present | absent |
#
# The consequence is not cosmetic: a cell's pi runs with **no review-enforcer, no
# verification-gate, no main-worktree-guard, no search-guard, no audit-logger, no
# auto-sync, and no skills** — so a cell lane is NOT under the same guards as a laptop
# lane — and its merge path died `rc=127` because `~/.pi/agent/scripts/record-review.sh`
# did not exist (`scripts/orchestrator-harness/merge-one.sh:240` executes that exact path).
#
# This script is the installer half: a Linux cell gets the layer the same way a Mac does —
# by running the installer against an agent-infra checkout that is ALREADY on the cell.
# It deliberately does NOT invent a download path (no tarball, no `git clone`): the cell
# clones agent-infra (the harness lives there), and this script reads that checkout.
#
# ── SURFACE-AWARE SELECTION (why this is not a blanket `cp -R`) ───────────────
# A cell is a headless Linux VM: no cmux desktop app, no launchd, no ~/Documents, no
# eldato design checkout, no human at the console. Three of those are real selection
# criteria; the rest of the layer is installed verbatim, because the whole point is that
# a cell lane runs under the SAME guards as a laptop lane.
#
# 1. FARMED SCRIPTS — copied from the DECLARED farm set, never from a glob.
#    `pi-bootstrap/setup.sh` is the single declaration of what the farm carries; this
#    script PARSES its array declarations and lays each one out per `FARM_LAYOUT` below —
#    today `fleet_srcs`, `merge_gate_srcs`, `graph_srcs` (#3374: the hosted-graph fallback
#    has its OWN array; it is NOT also in `fleet_srcs`, because a file declared twice is
#    copied twice and appears twice in the farm's declared set), `lane_root_srcs`,
#    `lane_srcs`, `lib_srcs` and `fleet_tools` — plus its `scripts_dir` checkout-hygiene
#    farm, and copies exactly those, preserving the
#    relative layout setup.sh documents (`scripts/lib/`, `scripts/fleet/`). A farm array
#    this script does not know how to lay out is a LOUD failure, never a silent skip: an
#    unparsed farm would leave a cell with a partial layer that still reports success.
#    ⛔ `FARM_LAYOUT` IS THE AUTHORITY FOR THAT LIST — this sentence is the prose reading of
#    it, and it went stale the moment #3374 added a 7th row (#3374 review, round 10 P2).
#    The parse is the same shape as `scripts/run-bash-shards.sh --list`, which reads its
#    own shard lines rather than keeping a second copy of them.
#    NOTE the dest is `scripts/fleet/`, never `tools/fleet/`: pi's startup migration treats
#    ANY entry under ~/.pi/agent/tools/ other than fd/rg as a legacy custom-tools directory
#    and then BLOCKS every interactive boot on an untimed keypress prompt (#1277).
#
# 2. EXTENSIONS — every entry of `manifest.json` `files.extensions/.entries` (the consumer
#    ship-list, which `scripts/check-pi-config-extensions.sh` check 4 keeps in exact parity
#    with `extensions/`), MINUS a declared deny list. The default is parity, on purpose:
#    a new guard extension must reach a cell without anyone remembering to add it here.
#    The deny list is entries that must not run ON A CELL — one whose operation needs a
#    surface a Linux cell does not have, and one that can make the cell unusable:
#
#      * `cmux-session.ts` — the bridge to the **cmux desktop app** (`cmux hooks pi install`
#        owns and upgrades this file in place, and it `spawn`s the `cmux` CLI on every
#        lifecycle hook). A cell is a headless VM: there is no app, and no `cmux` binary to
#        spawn, so every hook would fail. Hand-copying it is additionally the #1760
#        duplicate-payload defect — the live laptop file is v4 (+18.8 KB, #1138) while the
#        repo snapshot is v2, so a copied one is stale the moment it lands.
#
#      * `tortoise-capture` — measured 2026-10-19 (#2100): on the AFFECTED cell the spool reached
#        3.9 MB / 357 queued uploads against an exhausted 25,000-point quota, the extension's
#        synchronous work consumed the turn, and every turn ended with banner-only output
#        (259-262 B) — a box that looked dead while its provider was healthy. The extension was
#        present on all three cells and the provider-probe half of the defect applied on all three;
#        which box lost its turns depended on its own spool/quota state. Its banner also lands on
#        stdout/stderr, so `cloud-cell-bringup.sh --check`'s provider probe read the capture banner
#        instead of the provider's answer and refused a healthy box.
#        ⛔ THE CELL'S COPY IS NOT THIS CHECKOUT'S COPY. It emitted `[tortoise-capture] install
#        probe recorded`, and that string exists in no file under `extensions/tortoise-capture/`
#        — so the cell ran a payload that differs from the repo, the duplicate-payload class the
#        `cmux-session.ts` entry above already documents (#1138). The deny is therefore BY NAME
#        and not by file content: it must hold whatever version a cell happens to carry. This
#        checkout's copy is not innocent either — it writes `[tortoise-capture] created/appended
#        …` to stdout from `agent_end` (`index.ts:729,734`) plus egress status lines, the very
#        channel the provider probe used to read.
#        It is NOT a cell feature: a cell's job is to run lanes, and capture is observability
#        that happened to be able to consume the whole turn. This is a DENY, not a default: the
#        entry stays in the ship-list and still ships to a laptop.
#
#    Everything else is installed. That IS the per-entry decision:
#      * the five guards — review-enforcer, verification-gate, main-worktree-guard,
#        search-guard, audit-logger.ts — plus `shared/`, which every grouped extension
#        imports at load time (without it the guards do not load at all);
#      * the dispatch path a cell lane uses — builtin-tools/, subagent/, task-cwd-guard/,
#        task-heartbeat.ts, provider-exhaustion.ts;
#      * the skill layer — skill-enforcer.ts, skill-registry.ts, sequence-enforcer/,
#        loop-enforcer/ (a cell lane reads the skills this same script installs);
#      * survivability — clamp-output-floor.ts, compaction-watchdog.ts, http-pool-hygiene/
#        (a headless lane must not die silently on a context clamp or a killed socket);
#      * convergence + observability — auto-sync.ts, repo-freshness.ts, session-checks.ts,
#        health-check/;
#      * inert-without-a-credential, installed anyway — mcp-client/, the provider
#        registrations (custom-provider-openrouter/, custom-provider-qwen/), reflect-hook.ts,
#        slack-bridge/. These read keys/surfaces the operator may set in
#        the cell's keys.env, and each is documented to degrade gracefully. (reflect-hook.ts
#        shares `tortoise-capture`'s hosted-capture path but does no work on the turn path — its
#        only hook is `session_shutdown`, with the POST bounded at 10 s — so it keeps its
#        documented no-op; the deny is by measured failure mode, not by directory name, and a
#        registration-time banner alone is not one.) `carousel-designer.ts`
#        and `design-reviewer.ts` are also installed: recorded decision #45 KEEPS them in
#        agent-infra as canonical with a graceful no-op when ELDATO_ROOT is unset, so
#        env-gating them here would be adopting over a decision.
#
# 3. SKILLS + AGENTS.md + settings.json — installed, because a cell lane reads `skills/…`
#    from its cwd (fragile: the target repo need not carry them) and gets no AGENTS.md at
#    all today.
#      * `AGENTS.md` comes from `templates/AGENTS.base.md`, the repo's declared
#        universal-rules artifact ("copy to your repo as AGENTS.md"). The repo's own
#        `AGENTS.md` is agent-infra's *repo-scoped* materialization (base + an agent-infra
#        tail) and would mis-scope a cell lane working in another repo. It is installed
#        only when ABSENT and never overwritten: a machine-global file is hand-edited
#        state, and silently replacing it is how live rules would be lost. ⛔ The laptop's
#        live `~/.pi/agent/AGENTS.md` ("Global agent instructions" — fleet state & recovery,
#        the lane-partition rule, the reaping gates, JEV) exists in NO repo file, so a cell
#        receives the universal base WITHOUT that overlay; that gap is issue #1193, not
#        something this script can close by inventing a file.
#      * `settings.json` is MERGED (source wins per key, local extras survive; `retry`
#        deep-merged), the same contract as setup.sh — a cell's local tuning must survive
#        a re-run.
#      * `models.json` and `auth.json` are NOT touched. They are the cell's identity and
#        keys, the measured cell already has them, and the defect table above names only
#        AGENTS.md / settings.json / .mcp.json as absent.
#      * `.mcp.json` IS installed (graph-mcp-provision), from `templates/.mcp.base.json`,
#        MERGED so a cell-local server survives. It was deliberately NOT installed while that
#        template's only non-lazy server was `tortoise` **stdio** — it resolved
#        `${TORTOISE_HOME:-$HOME/Documents/GitHub/tortoise}/.venv/bin/python3`, a checkout and
#        venv a cell does not have, so installing it would have made every cell session start
#        spawn a core server that could not exist. The template now declares the HOSTED http
#        entry (`https://api.premiselabs.co/mcp/`, `Bearer ${TORTOISE_MCP_API_KEY}`, lazy), which
#        needs neither — and the old skip cost more than it saved: every lane on a cell ran
#        with ZERO MCP servers and wrote `GRAPH-UNREACHABLE` into its report, so the owner's
#        "every lane reads and writes the graph through the MCP" mandate was UNOBEYABLE on a
#        cell rather than disobeyed (measured 2026-11-03: cell-3 and cell-4 had no `.mcp.json`,
#        no key, and no fallback script). Credentials stay OUT of this file by construction:
#        the header is env-indirect, and `--verify` FAILS if a literal `tt_`/`tk_` value ever
#        appears in it. The credential itself is operator-pushed into `~/keys.env` (0600) —
#        `cloud-cell-bringup.sh` documents keys.env as "operator-pushed, and NOT a bring-up
#        byproduct" — so `--verify` WARNS (it never fails) on a cell whose `TORTOISE_MCP_API_KEY`
#        does not resolve to something a server would accept, because a config with an unresolved
#        `${VAR}` sends `Bearer ` (empty) and the server answers 401; that failure reads as
#        an auth problem rather than the set-up gap it is (#5153). ⛔ WARN, not fail, on purpose: the
#        key is operator state, so refusing to certify an otherwise-complete LAYER over a key nobody
#        pushed is a false block — the one thing that teaches an operator to ignore the verifier.
#        Exit 0 with an unmissable `⚠️  graph credential: NOT resolvable` line (and the same state in
#        the `LAYER VERIFIED` verdict line) instead. Only a LITERAL credential in the file FAILS.
#
# 4. ⛔ NOTHING is written under `~/.pi/agent/tools/` except pi's own fd/rg. See the #1277
#    note above; this script installs nothing there, removes a legacy `tools/fleet/` if it
#    finds one, and FAILS LOUDLY if any other entry exists — a machine that cannot boot an
#    interactive pi is not a machine that can run a lane.
#
# ── CONTRACT ─────────────────────────────────────────────────────────────────
#   bash pi-bootstrap/cell-install.sh [--install|--verify|--help]
#
#   --install (default)  install the layer, then VERIFY it; non-zero if either fails.
#   --verify             check an already-installed layer against the checkout; no writes.
#                        It compares CONTENT, not existence: the farmed scripts, the extensions
#                        (files byte-compared, directories file-by-file), the config set, the whole
#                        `skills/` tree, and settings.json's keys — and it refuses (non-zero) when
#                        a comparison cannot be made IN FULL. That matters beyond this script:
#                        cloud-cell-bringup.sh --check runs `--verify` BEFORE it installs, so this
#                        read-back is what decides whether a cell's existing layer is REPAIRED or
#                        CERTIFIED.
#   --help               print this header.
#
#   ENV  CELL_HOME    the cell home (default /tmp/cell-home; the cell's real HOME)
#        INFRA_ROOT  the agent-infra checkout to install FROM. When unset it is resolved
#                    from this script's own checkout, then AGENT_INFRA_PATH, $HARNESS/..
#                    and $CELL_HOME/agent-infra, and the script FAILS if none of them is a
#                    checkout — a cell that cannot receive the layer must not be certified.
#                    An AMBIENT candidate must also be OWNED BY THIS USER: the cell's HOME is
#                    a fixed path under a world-writable /tmp (/tmp/cell-home), so
#                    'checkout-shaped' is not a trust signal by itself — whoever can
#                    pre-create that path would choose the extensions and farmed scripts
#                    that pi then EXECUTES. Pass INFRA_ROOT explicitly to override.
#        AGENT_GH_SHIM_DIR  a PREFERENCE, not an override, and it decides ONE HALF of a
#                    two-part contract. --verify checks (1) the INSTALLED copy
#                    ($CELL_HOME/.pi/agent/scripts/gh-shim), on its own and unconditionally:
#                    it is what a lane started WITHOUT this variable resolves, so it must be
#                    present and executable whether or not the variable is set — a valid
#                    preference never stands in for it. This variable decides only (2) WHOSE
#                    `../verify-admin-merge-evidence.sh` sibling is required: the FIRST
#                    candidate holding an EXECUTABLE `gh` — [this variable, then the installed
#                    copy], mirroring the review-enforcer's resolveGhShimDir(), so an unusable
#                    value falls back rather than failing a healthy cell — is the winner, and
#                    the sibling is resolved through symlinks (a symlinked shim AND a symlinked
#                    candidate directory alike).
#
#   Idempotent and refresh-on-rerun, exactly like setup.sh's farms: installed files are
#   real copies (not symlinks — a cell's checkout can live under /tmp, and #427 is the
#   same reason links are not used for launchd-invoked scripts), so a re-run overwrites a
#   cell-local mutation to a farmed/guard file. Local EXTRAS survive (nothing is deleted
#   except a denied extension, a legacy tools/fleet/, and a farm artifact DECLARED retired
#   in pi-bootstrap/farm-retired.txt — #1924).
#
# Exit: 0 = installed + verified, 1 = a failure (details on stdout/stderr), 2 = usage.
# ============================================================
# shellcheck disable=SC2016,SC2250

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CELL_HOME="${CELL_HOME:-/tmp/cell-home}"
DEST="$CELL_HOME/.pi/agent"
MODE="${1:---install}"

FAILURES=0
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }
die()  { printf 'FATAL: %s\n' "$*" >&2; exit 1; }
log_line()  { printf '  %s\n' "$*"; }

# ── the hosted-graph credential (graph-mcp-provision) ────────────────────────
# `.mcp.json`'s tortoise header is `Bearer ${TORTOISE_MCP_API_KEY}`. A plain `${VAR}` expands to the
# EMPTY STRING when unset, so an unprovisioned cell reaches the server, sends `Bearer ` and gets
# a 401 that reads as an auth failure rather than the set-up gap it is (#5153). The credential is
# OPERATOR state (cloud-cell-bringup.sh: keys.env is "operator-pushed, and NOT a bring-up
# byproduct"), so its absence is a WARNING with an exact remedy — never a certification failure,
# which would refuse to certify a working layer over a key nobody pushed yet.
graph_key_from_env_file() { # <file> [<variable>] -> its value
  local f="$1" v="${2:-TORTOISE_MCP_API_KEY}"
  [ -f "$f" ] || return 1
  # ⛔ SOURCING A FILE IS CODE EXECUTION, SO THE FILE MUST BELONG TO THE USER RUNNING THIS. One
  # candidate is `$CELL_HOME/keys.env`, and `CELL_HOME` defaults to `/tmp/cell-home` — a path under
  # a WORLD-WRITABLE parent. Without this gate an unprivileged local user could plant that file and
  # get arbitrary shell run as whoever provisions the cell (root, on a fresh box), from a script
  # whose every comment says the file is operator-pushed and mode 600. `-O` is the portable owner
  # test (bash 3.2/macOS: `stat -c` does not exist there); the mode test refuses anything group- or
  # other-writable. A refused file is NOT a credential source — it is reported, and never sourced.
  if [ ! -O "$f" ] || ! _no_group_world_write "$f"; then
    printf '  ⚠️  %s is NOT a credential source: it is not owned by this user, or it is group/other-writable — refusing to source it\n' "$f" >&2
    return 1
  fi
  # Resolve the way the LANE does — source it in a subshell (set -a) — because a box provisioning
  # the LEGACY name spells it as an alias `export TORTOISE_MCP_API_KEY="$TORTOISE_API_KEY"`, which
  # a line-parser reads as the literal string `$TORTOISE_API_KEY` and then reports as a malformed
  # key. The subshell discards every other assignment it makes.
  KEYFILE="$f" KEYVAR="$v" bash -c 'set -a; . "$KEYFILE" >/dev/null 2>&1; set +a; printf "%s" "${!KEYVAR:-}"' 2>/dev/null
}

# True when <file> has no WRITE bit for group or other. GNU `stat -c %a` first, BSD/macOS
# `stat -f %Lp` second — the repo's tests run on both — and "cannot determine" is a REFUSAL (the
# caller treats a non-zero return as 'not a credential source'), never an assumed "fine".
# ⛔ `-L`: the TARGET's mode is the one that matters (a symlinked `~/keys.env` → dotfiles is a
# legitimate setup), and `stat` without it reports the LINK's 0777 — which refused a perfectly safe
# file and told the operator it was group-writable when it was not. `-O` in the caller already
# follows, so the gate follows too rather than inventing a different notion of "the file".
_no_group_world_write() {
  local m go
  m="$(stat -L -c '%a' "$1" 2>/dev/null || stat -L -f '%Lp' "$1" 2>/dev/null)" || return 1
  [ -n "$m" ] || return 1
  go="$(printf '%s' "$m" | sed 's/.*\(..\)$/\1/')"    # the last two digits: group, other
  case "$go" in *[2367]*) return 1 ;; esac             # 2/3/6/7 all carry the write bit
  return 0
}

# ⛔ RESOLVE THE VARIABLE THE ARTIFACT NAMES, NOT A FAMILY OF NAMES. The installed entry expands
# exactly ONE variable (`Authorization: Bearer ${TORTOISE_MCP_API_KEY}`), and pi's mcp-client resolves
# `process.env[NAME]` VERBATIM — there is no alias mapping anywhere in it. So a resolver that
# also accepted the LEGACY alias `TORTOISE_API_KEY` as a substitute certified "the hosted MCP will
# authenticate" on a box whose entry expands `${TORTOISE_MCP_API_KEY}` to the EMPTY STRING: it
# printed the exact OPPOSITE of what the artifact does. The alias is a REMEDY (the #5153 line
# `export TORTOISE_MCP_API_KEY="$TORTOISE_API_KEY"`), never a substitute for the standard name.
# graph_mcp_var — the one variable the INSTALLED **tortoise** entry expands, or empty when that entry
# declares no Authorization at all.
#
# ⛔ IT MUST READ THE TORTOISE ENTRY, NOT THE FILE. Two whole-file reads were both wrong, silently:
#   * the first `${…}` in the file is `${TORTOISE_HOME}` inside `_comment` — a variable that is never
#     a key, so a correctly provisioned box reported UNRESOLVED;
#   * the first `"Authorization"` in the file is ANY server's header — a cell may declare its own
#     servers (`merge-mcp.py` preserves them on purpose), so an `acme` entry ahead of `tortoise`
#     made `LAYER VERIFIED` say "will authenticate" about a VARIABLE THE TORTOISE ENTRY DOES NOT
#     EXPAND, while the tortoise entry expanded an unset one and the lane got a 401. A verdict that
#     describes a different server than the one it certifies is the false green this PR exists to
#     close.
# An EMPTY result is meaningful, not a fallback: the documented self-host entry
# (`{"url":"http://localhost:8000/mcp"}`) declares no header, and a local daemon needs no key — so
# there is nothing to resolve and nothing may be reported as missing.
# ⛔ THE MARKERS ARE A FOURTH QUESTION, and collapsing them into "empty" was a lie in the run log:
#   NOENTRY — no readable `.mcp.json`/`tortoise` entry at all (missing template, missing lib, no
#             python3, a merge that failed). The caller used to render that as "the tortoise entry
#             declares no Authorization — a self-hosted daemon needs none", a sentence asserting the
#             existence of an entry that is not there.
#   LITERAL — an `Authorization` that is NOT env-indirect: a credential written into the shared file,
#             which `--verify` refuses (LITERAL_AUTH). It is not "no authorization" either.
#   BADSHAPE — the entry EXISTS and the file reads fine, but its SHAPE is one `--verify` refuses: a
#             non-string `Authorization` (BADAUTH:int), a `headers` value that is not an object
#             (BADDERS:str/list/…). The marker carries the name the VERIFIER prints, so the two
#             renderers cannot contradict each other about the same file. Reporting these as NOENTRY
#             ("there is no readable tortoise entry") was the mirror of the bug above: it told an
#             operator that a perfectly healthy `.mcp.json` could not be read, and pointed at
#             recreating the file instead of at the line that is wrong (#3374 review, rounds 8-10).
#             The carried name is the resolver's OWN finding (headers/Authorization only) — `--verify`
#             may name an EARLIER rung of its own precedence (SECRET_IN_FILE, STDIO, …), which is why
#             the note says "the shape it names" rather than promising a specific marker.
# Only a real entry with no `Authorization` key at all is the self-host shape.
graph_mcp_var() {
  [ -f "$DEST/.mcp.json" ] || { printf 'NOENTRY'; return 0; }
  # no python3 means this file cannot be READ — "UNKNOWN", never "needs no key"
  command -v python3 >/dev/null 2>&1 || { printf 'NOENTRY'; return 0; }
  python3 -c '
import json, sys
# ⛔ READ vs SHAPE ARE TWO QUESTIONS, AND EACH SHAPE ERROR MUST CARRY THE MARKER `--verify` USES
# (#3374 review, round 9). The previous pass gave a non-string Authorization its own state but left
# its SIBLINGS borrowing one: `"headers": "Bearer …"` fell through to NOENTRY ("there is no readable
# tortoise entry" about a file that reads perfectly, while --verify said BADDERS:str), and a
# whitespace-only Authorization fell through to NOAUTH ("this entry declares no Authorization" about
# an entry that declares one, while --verify said LITERAL_AUTH). The two renderers contradicted each
# other about the SAME file — the exact class this marker set exists to close, one line over. So a
# shape error now prints `BADSHAPE:<the marker verify will print>`, and the note quotes it.
try:
    with open(sys.argv[1], encoding="utf-8") as _f:
        entry = json.load(_f)["mcpServers"]["tortoise"]
except Exception:
    print("NOENTRY")           # the FILE or the entry cannot be READ at all — never "needs no key"
    sys.exit(0)
if not isinstance(entry, dict):
    print("NOENTRY")           # same marker the verifier prints for this shape: the two agree
    sys.exit(0)
headers = entry.get("headers")
if headers is not None and not isinstance(headers, dict):
    print("BADSHAPE:BADDERS:%s" % type(headers).__name__)
    sys.exit(0)
auth = ((headers or {}).get("Authorization") or "")
if not isinstance(auth, str):
    print("BADSHAPE:BADAUTH:%s" % type(auth).__name__)
    sys.exit(0)
if not auth:
    sys.exit(0)                 # no Authorization AT ALL: the documented self-host shape
if "${" not in auth:
    # present but not env-indirect — INCLUDING whitespace-only, which is truthy: --verify refuses
    # it (LITERAL_AUTH), so it must not be reported as "needs no key".
    print("LITERAL")
    sys.exit(0)
name = auth.split("${", 1)[1].split("}", 1)[0].split(":-", 1)[0]
print(name)
' "$DEST/.mcp.json" 2>/dev/null
}

# ⛔ THE SECRET MUST NOT OUTLIVE THE READ (#3374 review, round 14 P1 — round 13's own fix was
# INCOMPLETE, and its arm could not see that). `set -x` prints the SUBSTITUTED VALUE not only of the
# assignment that reads the key but of EVERY expansion of it afterwards: `+ '[' -n tt_… ']'`,
# `+ GRAPH_KEY=tt_…`, `+ case tt_… in`, `+ local key=tt_…`. Round 13 guarded only the file-read
# substitution, so a `bash -x` bring-up STILL printed the tenant key — measured with the real
# `graph_key_resolve` under `bash -x`, twice, two lines below the new `set -x` restore — and the
# environment path (`printenv`) was never guarded at all, nor were the two renderings. Patching each
# sink with its own `set +x` is a rule every future edit has to remember; a sink that is never
# CREATED cannot be forgotten. So the value is read once, inside one guarded region, and immediately
# reduced to what the rest of this file actually uses — presence, the `tt_`/`tk_` shape, and the
# LENGTH (the note prints the length, never the key). No variable that holds the secret survives the
# call, so there is nothing left for any later trace, log line, or error path to expand.
# The caller sees only `GRAPH_KEY_SET`/`GRAPH_KEY_SHAPED`/`GRAPH_KEY_LEN`; the exit status is "we got
# one". The xtrace state is preserved, because a caller debugging this layer depends on it.
_graph_key_read() { # <env|file> <path-or-empty> <variable> -> SET/SHAPED/LEN; rc=0 when non-empty
  local src="$1" path="$2" var="$3" _xt=0 raw="" shaped=0 got=0
  case $- in *x*) _xt=1 ;; esac
  set +x
  if [ "$src" = env ]; then
    raw="$(printenv "$var" 2>/dev/null || true)"
  else
    raw="$(graph_key_from_env_file "$path" "$var")"
  fi
  GRAPH_KEY_LEN=${#raw}
  case "$raw" in tt_*|tk_*) shaped=1 ;; esac
  if [ "$GRAPH_KEY_LEN" -gt 0 ]; then got=1; fi
  GRAPH_KEY_SET="$got"
  GRAPH_KEY_SHAPED="$shaped"
  unset raw
  if [ "$_xt" = 1 ]; then set -x; fi
  [ "$GRAPH_KEY_SET" = 1 ]
}

# ⛔ "IS A KEY PRESENT AT ALL?" MUST NOT EXPAND ONE EITHER (#3374 review, round 15 P1 — the same class
# as `_graph_key_read`, in the one place it was left). `graph_credential_note`'s legacy-alias hint read
# the ALIAS through `[ -n "${TORTOISE_API_KEY:-}" ]` and `[ -n "$(graph_key_from_env_file …)" ]`, and
# `set -x` traces both with the VALUE — measured: `+ '[' -n tt_… ']'` for a box whose primary name is
# unset and whose legacy alias is set, which is EXACTLY the population the hint exists for. It prints
# nothing and sets nothing: callers ask it a yes/no question in a `||` chain, so a boolean of the
# secret never reaches a variable that a later line could expand.
_graph_key_present() { # <env|file> <path-or-empty> <variable> -> rc=0 when a non-empty key resolves
  local src="$1" path="$2" var="$3" _xt=0 raw="" got=0
  case $- in *x*) _xt=1 ;; esac
  set +x
  if [ "$src" = env ]; then
    # indirect expansion, not `printenv`: the original test was `${TORTOISE_API_KEY:-}` and it must
    # keep matching a shell variable that was set without being exported.
    raw="${!var:-}"
  else
    raw="$(graph_key_from_env_file "$path" "$var")"
  fi
  if [ -n "$raw" ]; then got=1; fi
  unset raw
  if [ "$_xt" = 1 ]; then set -x; fi
  [ "$got" = 1 ]
}

# ONE resolver, two renderings. `graph_credential_note` prints the long explanation; the
# `LAYER VERIFIED` line prints the one-word state. Two independent resolutions of the same question
# is how a cell gets certified "credential: OK" while the note below it says NOT resolvable.
graph_key_resolve() {
  GRAPH_VAR="$(graph_mcp_var)"
  # NOT the key itself — see `_graph_key_read`. Presence, shape and length are all any caller needs.
  GRAPH_KEY_SET=0
  GRAPH_KEY_SHAPED=0
  GRAPH_KEY_LEN=0
  GRAPH_KEY_SRC="the environment"
  GRAPH_NOAUTH=0
  GRAPH_NOENTRY=0
  GRAPH_LITERAL=0
  GRAPH_BADSHAPE=0
  GRAPH_BADSHAPE_WHY=""
  case "$GRAPH_VAR" in
    NOENTRY)
      # no readable tortoise entry at all — a DIFFERENT state from "an entry that needs no key",
      # and reporting it as the latter asserts an entry that is not there (see graph_mcp_var).
      GRAPH_NOENTRY=1
      GRAPH_VAR=""
      return 0 ;;
    BADSHAPE*)
      # the entry READS, but its shape is one --verify refuses; the marker it will print travels with
      # the state so the note quotes the same name. NOT a missing entry, and NOT "needs no key".
      GRAPH_BADSHAPE=1
      GRAPH_BADSHAPE_WHY="${GRAPH_VAR#BADSHAPE:}"
      GRAPH_VAR=""
      return 0 ;;
    LITERAL)
      # an Authorization that is not env-indirect: a credential in the shared file, refused by
      # --verify (LITERAL_AUTH) — also NOT "needs no key"
      GRAPH_LITERAL=1
      GRAPH_VAR=""
      return 0 ;;
  esac
  if [ -z "$GRAPH_VAR" ]; then
    # the tortoise entry declares no env-indirect Authorization: a self-hosted daemon needs none
    GRAPH_NOAUTH=1
    return 0
  fi
  if _graph_key_read env "" "$GRAPH_VAR"; then
    GRAPH_KEY_SRC="the environment ($GRAPH_VAR)"
    return 0
  fi
  # HOME first: that is the home a live lane on a cell actually runs in (measured on cell-3
  # and cell-4: HOME=/home/cmux), and the launcher sources $HOME/keys.env. CELL_HOME follows
  # because it is where THIS script installs, and on some images the two differ.
  local f base
  # ⛔ `${HOME:-}`, NOT `$HOME`. This function runs under `set -uo pipefail` (line 209), so a
  # HOME-less context — systemd/launchd units, `sudo -u`, `env -i`, a CI step — aborted the WHOLE
  # verifier here with `HOME: unbound variable`, skipping `guard_tools_dir`, `guard_spawn_gate`,
  # `guard_gh_shim` and the `LAYER VERIFIED` verdict: a correctly-installed cell could not be
  # certified, and the abort lands AFTER `.mcp.json verify: OK` so the log looks like a graph
  # problem. `${CELL_HOME:-}` too — it is assigned from `${CELL_HOME:-$HOME}` elsewhere, but this
  # loop must not depend on that.
  # ⛔ AN EMPTY BASE YIELDS NO CANDIDATE AT ALL (#3374 review P3). The loop used to be
  # `for f in "${HOME:-}/keys.env" "${CELL_HOME:-}/keys.env"` with `[ "$f" != "keys.env" ] || continue`
  # beside it — a clause that can NEVER fire (both candidates are absolute), while the state it was
  # written for (an unset base) produced `/keys.env`, which WAS stat'd. Iterate the BASES and skip the
  # empty one: no candidate, nothing stat'd, and no dead condition in a security-relevant loop.
  for base in "${HOME:-}" "${CELL_HOME:-}"; do
    [ -n "$base" ] || continue
    f="$base/keys.env"
    [ -f "$f" ] || continue
    # ⛔ THE READ IS GUARDED INSIDE `_graph_key_read`, NOT HERE (#3374 review, round 14 P1). Round 13
    # scoped `set +x` to this substitution and left the `[ -n "$val" ]` test and the `GRAPH_KEY="$val"`
    # assignment below it traced — measured: the key printed twice, with the suite green, because the
    # arm asserted the guard on a COPY of it. Nothing secret is assigned, tested or expanded here now.
    _graph_key_read file "$f" "$GRAPH_VAR"
    GRAPH_KEY_SRC="$f ($GRAPH_VAR)"
    if [ "$GRAPH_KEY_SET" = 1 ]; then break; fi
  done
  return 0
}

# The state as it belongs in a certification line — a cell is never reported VERIFIED without it.
graph_credential_state() {
  graph_key_resolve
  if [ "$GRAPH_NOENTRY" -eq 1 ]; then
    printf 'UNKNOWN — no readable tortoise entry at %s/.mcp.json to resolve (the failure above says why)' "$DEST"
    return 0
  fi
  if [ "$GRAPH_LITERAL" -eq 1 ]; then
    printf 'LITERAL — the tortoise entry carries a NON-ENV-INDIRECT Authorization (no ${…} to expand; a literal token, or a whitespace-only one), which --verify refuses (LITERAL_AUTH)'
    return 0
  fi
  if [ "$GRAPH_BADSHAPE" -eq 1 ]; then
    printf 'UNKNOWN — the tortoise entry is malformed (%s), so there is no variable to resolve; --verify refuses it by the shape it names' "${GRAPH_BADSHAPE_WHY:-shape}"
    return 0
  fi
  if [ "$GRAPH_NOAUTH" -eq 1 ]; then
    printf 'none required — the tortoise entry declares no Authorization (self-hosted daemon)'
    return 0
  fi
  # ⛔ A `case "$key" in tt_*…` HERE WOULD PRINT THE KEY UNDER `bash -x` (#3374 review, round 14 P1):
  # the dispatcher traces the word it matches. The shape was decided inside the guarded read, so the
  # renderings only ever touch FLAGS that cannot contain the secret.
  if [ "$GRAPH_KEY_SET" = 0 ]; then
    printf 'UNRESOLVED — the entry expands ${%s}, so the tortoise MCP sends an empty Bearer and the server answers 401' "$GRAPH_VAR"
  elif [ "$GRAPH_KEY_SHAPED" = 1 ]; then
    printf 'resolves from %s' "$GRAPH_KEY_SRC"
  else
    printf 'resolves from %s but is not tt_/tk_-shaped (401 likely)' "$GRAPH_KEY_SRC"
  fi
}

graph_credential_note() {
  graph_key_resolve
  local src="$GRAPH_KEY_SRC" _legacy=0
  if [ "$GRAPH_NOENTRY" -eq 1 ]; then
    log_line "⚠️  graph credential: UNKNOWN — there is no readable tortoise entry at $DEST/.mcp.json, so there is no credential to resolve (the failure above names the reason). ⛔ A MISSING entry is not a self-host and must not be reported as one"
    return 0
  fi
  if [ "$GRAPH_LITERAL" -eq 1 ]; then
    log_line "⚠️  graph credential: the tortoise entry's Authorization is not env-indirect (no \${…} to expand) — nothing can be resolved from it, and --verify REFUSES this file (LITERAL_AUTH); write it as \"Bearer \${TORTOISE_MCP_API_KEY}\" and put the key in \$HOME/keys.env (mode 600)"
    return 0
  fi
  if [ "$GRAPH_BADSHAPE" -eq 1 ]; then
    # ⛔ NO PROMISE ABOUT THE REPAIR (#3374 review, round 10). "--install replaces the entry" is FALSE on
    # the only path this note prints on: it is reached on --install when the MERGE FAILED (rc!=0, file
    # unchanged), so the entry is still malformed precisely BECAUSE nothing could replace it. Say what
    # is true — verify refuses it, by the shape it names.
    log_line "⚠️  graph credential: UNKNOWN — the tortoise entry is malformed (${GRAPH_BADSHAPE_WHY:-shape}), so there is no variable to resolve; --verify REFUSES this file by the shape it names (which may be an earlier check than this one). The provenance line above says whether the merge wrote the entry or left it as it found it"
    return 0
  fi
  if [ "$GRAPH_NOAUTH" -eq 1 ]; then
    log_line "graph credential: the tortoise entry declares no Authorization — a self-hosted daemon needs none, so there is nothing to resolve"
    return 0
  fi
  # ⛔ NEVER `case "$key"`: the dispatcher traces the word it matches (#3374 review, round 14 P1).
  # The length is printed, not the key.
  if [ "$GRAPH_KEY_SET" = 0 ]; then
      log_line "⚠️  graph credential: NOT resolvable — the tortoise MCP entry expands \${$GRAPH_VAR} to the EMPTY"
      log_line "    string, the server answers 401 'invalid or missing Bearer token', and every lane writes"
      log_line "    GRAPH-UNREACHABLE. Remedy: put the hosted key in $CELL_HOME/keys.env (mode 600) as"
      log_line "    $GRAPH_VAR, or alias the name an older box carries: export TORTOISE_MCP_API_KEY=\"\$TORTOISE_API_KEY\" (#5153)."
      # `if/elif`, not a `{ …; } || { …; }` chain: `}` followed by `; then` is a syntax error (measured),
      # and the chain read worse than the thing it replaced.
      _legacy=0
      if [ "$GRAPH_VAR" = "TORTOISE_MCP_API_KEY" ]; then
        if _graph_key_present env "" TORTOISE_API_KEY; then
          _legacy=1
        elif [ -n "${HOME:-}" ] && _graph_key_present file "${HOME}/keys.env" TORTOISE_API_KEY; then
          _legacy=1
        elif [ -n "${CELL_HOME:-}" ] && _graph_key_present file "${CELL_HOME}/keys.env" TORTOISE_API_KEY; then
          _legacy=1
        fi
      fi
      if [ "$_legacy" = 1 ]; then
        log_line "    ⚠️  the LEGACY name TORTOISE_API_KEY IS set — add the alias line above and it resolves"
      fi
  elif [ "$GRAPH_KEY_SHAPED" = 1 ]; then
      log_line "graph credential: resolves from $src (len $GRAPH_KEY_LEN) — the hosted MCP will authenticate"
  else
      log_line "⚠️  graph credential: $GRAPH_VAR in $src does not look like a hosted key (expected tt_/tk_ prefix);"
      log_line "    the MCP will send whatever it holds and the server may answer 401 (#5153)."
  fi
}

# verify_graph_mcp — checks the config this script INSTALLS ($DEST/.mcp.json), on the artifact.
# ⛔ It does NOT claim to describe what pi resolves: mcp-client takes the FIRST `.mcp.json` found
# walking up from the lane's cwd (then falls back to $DEST/.mcp.json), so a lane working inside a
# repo that carries its own `.mcp.json` uses THAT file. This is why the tracked repo configs must
# carry the hosted entry too — a stale repo-local copy wins over a correctly installed base.
verify_graph_mcp() {
  local f="$DEST/.mcp.json"
  if [ ! -f "$f" ]; then
    fail ".mcp.json is missing — this cell has ZERO MCP servers, so no lane can read or write the hosted graph (the exact gap graph-mcp-provision closed)"
    return 1
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    fail ".mcp.json exists but cannot be checked (no python3) — refusing to certify an unread config"
    return 1
  fi
# graph_mcp_marker — the verifier's python, in ITS OWN FUNCTION BODY.
#
# ⛔ The heredoc must NOT be lexically inside `$( )`: the bash 3.2 scanner desynchronises and the
# whole file stops parsing — on the `bash32-parse` CI gate, not on this box's bash 5, where
# `bash -n` happily passes it (measured: `scripts/check-bash32-parse.sh` reported
# "line 676: syntax error near unexpected token `('" for a defect on line 352; #2248/#2930).
# A heredoc in a FUNCTION body called from the substitution parses correctly in both.
graph_mcp_marker() { # <config.json> <template.json> -> marker on stdout; non-zero = not certifiable
  python3 - "$1" "$2" <<'PY'
import ipaddress
import json
import re
import sys
import unicodedata

p = sys.argv[1]
# ⛔ THE TEMPLATE READ WAS THE ONE REMAINING RAW TRACEBACK ON THE VERIFY SIDE (#3374 review P3).
# `merge-mcp.py` was hardened to a named FATAL for a template that is missing, unparseable, or the
# wrong SHAPE — but the marker kept `json.load(open(...))` then `tpl.get(...)`, so all three raised
# straight out and left stdout EMPTY. `verify_graph_mcp` then printed `verify failed (marker: none)`
# above Python internals instead of naming the cause, which is the exact "marker: none beside a
# traceback" shape this file's own BADDERS/URLTYPE arms exist to prevent. It fails closed (rc is
# still non-zero), but a checker that cannot say WHY is the instrument defect, not the audit.
# Reachable: `is_infra_checkout` does not require `templates/.mcp.base.json` to exist.
tpl = {}
if len(sys.argv) > 2:
    try:
        # ⛔ EXPLICIT utf-8 (see the config read below): the template carries `—`, and a
        # locale-encoding read turns a healthy template into a BADTPL on a box that pins UTF-8 off.
        with open(sys.argv[2], encoding="utf-8") as _tf:
            tpl = json.load(_tf)
    except (OSError, ValueError) as exc:
        print("BADTPL:%s: %s" % (type(exc).__name__, exc))
        sys.exit(1)
if not isinstance(tpl, dict) or not isinstance(tpl.get("mcpServers"), (dict, type(None))):
    print("BADTPL:shape: root is %s, mcpServers is %s" % (
        type(tpl).__name__,
        type(tpl.get("mcpServers") if isinstance(tpl, dict) else None).__name__))
    sys.exit(1)
_want = (tpl.get("mcpServers") or {}).get("tortoise")
if _want is not None and not isinstance(_want, dict):
    print("BADTPL:shape: mcpServers.tortoise is %s, not an object" % type(_want).__name__)
    sys.exit(1)
want_url = (_want or {}).get("url") or ""
# ⛔ THE MIRROR OF THE MERGE'S TEMPLATE-url TYPE GUARD (#3374 review, round 2 P3). A non-string
# template `url` made `want_url` an int, so the `url != want_url` branch fired and this verifier
# printed `URL_NOT_DEFAULT:` against the cell's CORRECT hosted entry — a refusal sentence asserting
# the right config is wrong. Unreadable template = nothing can be certified, named as such.
if not isinstance(want_url, str):
    print("BADTPL:shape: mcpServers.tortoise.url is %s, not a string" % type(want_url).__name__)
    sys.exit(1)
# ⛔ NORMALIZE THE TEMPLATE SIDE TOO — `url` is stripped below and `want_url` was NOT (#3374 review,
# round 11 P2). The two comparisons in the entry arm therefore disagreed about whitespace: with a
# template url carrying any surrounding space (`…/mcp/ ` — a hand-edit, or a copy that kept the
# pad), `url != want_url` was TRUE against a cell pointing at exactly the same endpoint, so this
# verifier refused `URL_NOT_DEFAULT:` and asserted the cell points somewhere the operator did not
# ask for — while the merge's `usable()` strips, so install PRESERVED the value it could not
# certify. `--install` ends in this same verify, so verify → install → verify never converged and
# `cloud-cell-bringup.sh` died on every attempt: the same FALSE BLOCK class round 9 fixed on the
# destination side. WHATWG strips leading/trailing space in `new URL()`, so the padded spelling IS
# the endpoint; one normalization, both sides, applied here so every branch below reads the same
# value (and `want_url.strip()` just below is then non-empty exactly when the url is).
want_url = want_url.strip()
# ⛔ AN EMPTY TEMPLATE url IS NOT "NO OPINION" — IT IS "NOTHING TO COMPARE AGAINST", and that
# comparison is the ONLY arm that refuses a wrong endpoint. With `want_url` empty, `if want_url and
# url != want_url` is False, so URL_NOT_DEFAULT/BADURL/NOHOST/USERINFO are ALL skipped and the entry
# falls through to the hosted-default `else`, which certifies ANY url as `OK:<url>:<auth>` rc=0 — the
# tenant key attached to whatever host the file happens to name. Measured against a template whose
# `tortoise` entry carries no `url` (the pre-#3374 stdio shape, and any hand-edited/forked template):
#   cell url `https://api.premiselab.co/mcp/` (one-letter typo) -> `OK:https://api.premiselab.co/mcp/:…` rc=0
#   cell url `https://evil.example/mcp/`                        -> `OK:https://evil.example/mcp/:…` rc=0
# `merge-mcp.py:807` already REFUSES this same template (`FATAL: … declares no usable tortoise
# entry`, exit 3), so install and verify DISAGREED about one file; this converges them in the safe
# direction — a template that cannot establish the default certifies NOTHING, it never certifies
# everything. Named, so the operator is told which file is the broken one.
if not want_url.strip():
    print("BADTPL:no-url: mcpServers.tortoise declares no url in %s" % (sys.argv[2] if len(sys.argv) > 2 else "(no template given)"))
    sys.exit(1)
# ⛔ THIS READ WAS THE ONE CONFIG READ ON THE VERIFY SIDE WITH NO GUARD (#3374 review, round 10 P2).
# `graph_mcp_var`/this marker's own template read are both wrapped; this one was bare, so an
# unreadable `.mcp.json` (an EACCES, a directory, a non-UTF-8 byte) raised straight out and left
# stdout EMPTY — `FAIL … (marker: none)` over Python internals, the exact "marker: none beside a
# traceback" shape BADROOT/BADDERS/NOTJSON exist to prevent. Fails closed either way; the point is
# that a checker which cannot say WHY is the instrument defect, not the audit.
# The explicit `encoding` is the second half: `templates/.mcp.base.json` carries non-ASCII (`—`) in
# `_comment`/`purpose`, and `open()` in text mode uses the LOCALE encoding — `PYTHONUTF8=0` with a C
# locale is `ascii`, and the read then dies on its own byte 503. Modern CPython coerces a C locale,
# so this does not bite a default host; it bites an environment that pins UTF-8 off, which is the
# one a service unit can hand you. The fix costs one keyword and removes the class.
try:
    with open(p, encoding="utf-8") as _cf:
        raw = _cf.read()
except (OSError, UnicodeDecodeError) as exc:
    print("UNREADABLE:%s: %s" % (type(exc).__name__, exc))
    sys.exit(1)
try:
    cfg = json.loads(raw)
except ValueError as exc:
    print("NOTJSON:%s" % exc)
    sys.exit(1)
if not isinstance(cfg, dict):
    # ⛔ THE CONTAINER, NOT ONLY THE ENTRY. `.get` on a non-object ROOT (a JSON array, a string, a
    # number) raised here, so stdout stayed EMPTY and the operator got `FAIL: … (marker: none)`
    # above a traceback — while the merge raised on its own copy of the same assumption, so
    # `--install` could never clear it and every bring-up died. REFUSED BY NAME; a re-install
    # replaces the container (keeping a `.bak`).
    print("BADROOT:%s" % type(cfg).__name__)
    sys.exit(1)
servers = cfg.get("mcpServers")
if servers is None:
    servers = {}
if not isinstance(servers, dict):
    # ⛔ SAME RULE ONE LEVEL DOWN: `dict(...)`/`.get` on a `mcpServers` that is a number, a string or
    # a list raised on both sides. Named, so the refusal says what is wrong and a re-install can fix it.
    print("BADSERVERS:%s" % type(servers).__name__)
    sys.exit(1)
t = servers.get("tortoise")
# ⛔ A LEAK IS NOT A TORTOISE PROBLEM. The token scan below covers the WHOLE file, so a literal
# pasted into any other server's entry (or into a `_comment`) is found there — and reporting it as
# "tortoise entry is not the hosted shape" points the operator at the one entry that is correct.
# The marker therefore carries the PATH of the first offending value.
tok = re.compile(r"\b(t[tk])_[A-Za-z0-9]{10,}")


def leak_path(node, trail=""):
    if isinstance(node, dict):
        for k, v in node.items():
            got = leak_path(v, "%s.%s" % (trail, k) if trail else str(k))
            if got:
                return got
    elif isinstance(node, list):
        for i, v in enumerate(node):
            got = leak_path(v, "%s[%d]" % (trail, i))
            if got:
                return got
    elif isinstance(node, str) and tok.search(node):
        return trail
    return ""

# ⛔ THE LEAK SCAN RUNS FIRST — BEFORE EVERY SHAPE EXIT (#3374 review P2). It used to sit AFTER
# the STDIO/URLTYPE/NOURL/BADDERS/… early exits, so a legacy stdio entry carrying a literal key in
# its `command` (or in `args`/`env`, the plausible place — the old template shipped the variable
# there) returned `STDIO:<the whole command, key included>`: the secret was ECHOED into the run log
# by the marker, and `verify_graph_mcp` prints that marker into the bring-up log, while the leak was
# never NAMED as a leak and the operator was told "not the hosted shape" instead. A literal must be
# reported as `SECRET_IN_FILE:<path>` whatever shape the entry has, and no marker may carry it.
if tok.search(raw):
    # report the path UNDER `mcpServers` — `mcpServers.tortoise._comment` is noise when the whole
    # file is already known to be that object, and `tortoise._comment` is what an operator greps.
    # ⛔ BUT THE SCAN IS THE WHOLE FILE (`raw`), so the PATH must be looked for there too (#3374
    # review, round 11 P1). It was searched under `servers` alone, so a literal pasted into a
    # TOP-LEVEL key — a `_noteboard`, a hand-added `"token"`, the shape a curl-style paste actually
    # produces — was found by the scan and then reported as `(unlocatable)`: the operator was told a
    # secret exists and given nowhere to look, and NOTHING on the install side named it either, so
    # the repair loop never converged. The under-`mcpServers` spelling is preserved exactly (the
    # prefix is stripped, not the path), so every existing marker a suite greps keeps its shape.
    _leak = leak_path(cfg)
    if _leak.startswith("mcpServers."):
        _leak = _leak[len("mcpServers."):]
    print("SECRET_IN_FILE:%s" % (_leak or "(unlocatable)"))
    sys.exit(1)


def redact(value):
    """Mask anything shaped like a credential — a marker is ECHOED into operator-facing logs."""
    return tok.sub("<redacted>", value if isinstance(value, str) else str(value))


# ⛔ A USERINFO IS A CREDENTIAL, AND `redact()` DOES NOT CATCH IT (#3374 review, round 2 P3).
# `tok` matches `tt_`/`tk_` shapes only, so `INSECURE_URL:http://user:hunter2@evil.example/mcp/`
# put a PASSWORD in the bring-up log — a log that gets pasted into issues and PRs fleet-wide. Every
# url-echoing marker goes through this: the userinfo is replaced wholesale, because its whole content
# is secret-or-irrelevant, and nothing after it is touched (the host is the actionable part).
# ⛔ "EVERY" WAS FALSE WHEN IT WAS WRITTEN (#3374 review, round 12 P2): `URL_NOT_DEFAULT` — the marker
# that fires for the COMMON case, an entry that differs from the template — printed the raw url, so
# `URL_NOT_DEFAULT:https://alice:hunter2@evil.example/mcp/` put the password in the run log while the
# `USERINFO` and `INSECURE_URL` arms, on the *same* url, printed `<redacted>`. It goes through here
# now, and `WRONG_AUTH` (a header, not a url) does NOT go through either one — see the note at its
# branch: `redact()` masks only `tt_`/`tk_` shapes, so a header is WITHHELD down to the `${VAR}` name it
# names, or to a sentence that withholds it. If you add a marker that echoes a url or a header, it is
# your job to route it through `shown_url`/`redact`, or to withhold — nothing enforces it.
def shown_url(u):
    u = u if isinstance(u, str) else str(u)
    head, sep, tail = u.partition("://")
    if sep and "@" in tail.split("/", 1)[0]:
        rest = tail.split("/", 1)
        authority = rest[0].rsplit("@", 1)[1]
        u = "%s://<redacted>@%s%s" % (head, authority, ("/" + rest[1]) if len(rest) > 1 else "")
    return redact(u)


if not isinstance(t, dict):
    print("NOENTRY")
    sys.exit(1)
if t.get("command"):
    print("STDIO:%s" % redact(t.get("command")))
    sys.exit(1)
url = t.get("url") or ""
if not isinstance(url, str):
    print("URLTYPE:%s" % type(url).__name__)
    sys.exit(1)
# ⛔ NORMALIZE THE url EXACTLY AS THE MERGE'S `usable()` DOES, BEFORE ANY PREDICATE READS IT
# (#3374 review, round 9 P2). `usable()` runs every floor on `url.strip()`, so the merge PRESERVES a
# whitespace-padded self-host; this verifier read the RAW value, so a leading pad failed the
# `^scheme://` match below and it refused `INSECURE_URL:` (or `BADURL:` with no key) — sentences that
# are FALSE about the artifact, because the client's own parser builds a working transport from
# exactly those bytes (`new URL(" https://localhost:8000/mcp")` → host `localhost:8000`, measured;
# WHATWG strips leading/trailing C0 and space). `--install` ends in this same verify, so the repair
# re-created the refusal for ever: verify → install → verify never converged. A FALSE BLOCK on a
# working config, which is the one direction this file must never take. One rule, one call, both
# sides — the same `.strip()` — so a shape one side preserves is a shape the other certifies.
# The pad is stripped, NOT the entry rewritten: `--verify` classifies, it never writes.
url = url.strip()
if not url:
    print("NOURL")
    sys.exit(1)
# `type` is OPTIONAL, deliberately: the client's `McpServerConfig` has no `type` field and picks
# the HTTP transport from `url` alone, so requiring it would refuse a config that works.
#
# ⛔ BUT THE `type` JUDGEMENT BELONGS WITH THE URL, NOT BEFORE IT — and this arm used to run first,
# unconditionally, which made INSTALL and VERIFY disagree about the SAME preserved entry: the merge
# (`merge-mcp.py` `usable()`) deliberately preserves a self-hosted entry that spells `type: "sse"`
# for its own daemon, marks it `_selfHosted`, and rc=0; this verifier then refused `sse` and rc=1.
# ⛔ THE MECHANISM WAS A FALSE **BLOCK**, NOT A FALSE PASS — and the difference decides whether a
# reader goes looking for the right hole. `cloud-cell-bringup.sh` repairs a verify failure by running
# INSTALL, and INSTALL ends in this same verify (`verify_layer` runs for `--install` too, and any
# recorded failure exits 1) — so the repair re-created the refusal and exited non-zero, which that
# script turns into a `die`. The cell could therefore NEVER converge: every bringup failed loudly, on
# a config the installer had itself just preserved, and no repair could clear it. Certification is not
# the hole (it comes from the INSTALL's rc, which already carries this verdict); convergence is. The
# rule is ONE rule, applied by both sides: a non-http `type` disqualifies the HOSTED default (where
# `http` is the contract) and is the operator's business on their own daemon. See the url branch below.
# ⛔ A `headers` THAT IS NOT A MAPPING IS REFUSED BY NAME, not by traceback. `"headers": "Bearer …"`
# (a hand-edit, or a curl-style paste) made this `.get` raise: stdout stayed empty, so the operator
# got `FAIL: … verify failed (marker: none)` above a python traceback and nothing that named the
# shape — and the INSTALLER's `usable()` raised on the same line, so the repair path could not fix
# it either. Both sides now treat it as what it is: an unusable entry (replaced on install, refused
# here by name).
# ⛔ AND `usable()` MUST BE TOTAL OVER ARBITRARY JSON — the same predicate, one level down: a
# non-STRING `url` made `.strip()` (and `re.match`) raise, and a non-string `Authorization` made
# `"${" not in auth` raise `TypeError`. Both left the merge rc=1 with the file unchanged and the
# verifier with an empty marker, i.e. the "config nothing can repair" state, for a shape a hand-edit
# produces in one keystroke. A `$TYPE` marker is what makes that legible.
_headers = t.get("headers")
if _headers is not None and not isinstance(_headers, dict):
    print("BADDERS:%s" % type(_headers).__name__)
    sys.exit(1)
auth = ((_headers or {}).get("Authorization") or "")
if not isinstance(auth, str):
    print("BADAUTH:%s" % type(auth).__name__)
    sys.exit(1)
if auth and "${" not in auth:
    print("LITERAL_AUTH")
    sys.exit(1)
# ⛔ A CREDENTIAL OVER CLEARTEXT IS NOT CERTIFIABLE, and `_selfHosted` must never become the
# exemption that says otherwise. `merge-mcp.py` preserves a genuine self-host (a DIFFERENT HOST) and
# this verifier reports it BY NAME; a SCHEME-only difference is a typo — and it is the one typo whose
# cost is not just a 401: the client expands the header and sends `Bearer <tt_…>` over that transport,
# so the live tenant key crosses the wire in cleartext while the cell prints LAYER VERIFIED and a
# green `graph credential: resolves from …` beside it (measured: `http://api.premiselabs.co/mcp/`
# was marked `_selfHosted` by the merge and then certified here, rc=0). `https` is therefore the FLOOR
# for any url carrying a credential to a destination that can leave the box. ⛔ LOOPBACK IS EXEMPT ON
# PURPOSE: a key sent to `localhost`/`127.0.0.0/8`/`::1` never crosses a network, and the repo's own
# documented self-host fixture is exactly that shape with the template's header still attached —
# refusing it would be the false block that teaches an operator to ignore this gate. A self-host that
# needs a key off-box must serve it over https.
# ⛔ THE LOOPBACK TEST IS AN IP-LITERAL TEST, NOT A PREFIX TEST — a prefix test is a BYPASS, measured:
# `127.attacker.example` is an ordinary DNS name its owner can point anywhere, and `127.0.0.1@evil.example`
# is the loopback spelling going on to an attacker's HOST (userinfo, not authority). Both skip a
# `startswith("127.")` exemption and then certified `SELFHOSTED:` rc=0 with the tenant key attached.
# So: strip userinfo, refuse anything with trailing labels, and ask ipaddress whether the literal is
# loopback. `merge-mcp.py`'s `usable()` applies the SAME predicate (marked MUST MATCH there).
def _loopback(authority):
    h = (authority or "").strip().lower()
    if "@" in h:                                  # userinfo is NOT the host
        h = h.rsplit("@", 1)[1]
    if h.startswith("["):                          # an IPv6 literal: `[<addr>]`, optionally `:port`
        end = h.find("]")
        if end < 0:
            return False
        rest = h[end + 1:]
        if rest and not rest.startswith(":"):
            return False
        # ⛔ ASK ipaddress, DO NOT STRING-MATCH `::1` — the same rule as the IPv4 arm below, and for
        # the same reason: `[0:0:0:0:0:0:0:1]` IS loopback and `== "::1"` called it remote, so a
        # legal spelling of the documented local self-host was refused as INSECURE_URL (a false
        # block on a config that cannot leave the box). `merge-mcp.py`'s `_loopback` MUST MATCH.
        try:
            return ipaddress.ip_address(h[1:end]).is_loopback
        except ValueError:
            return False
    host = h.rsplit(":", 1)[0] if h.count(":") == 1 else h
    if host == "localhost":
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False                             # a DNS name is never loopback, whatever it says


_m = re.match(r"^([a-z][a-z0-9+.\-]*)://([^/]+)", url, re.I)
if auth and (_m.group(1).lower() if _m else "") != "https" \
   and not _loopback(_m.group(2) if _m else ""):
    print("INSECURE_URL:%s" % shown_url(url))
    sys.exit(1)


# ⛔ `_selfHosted` IS AN EXEMPTION, AND AN EXEMPTION MAY ONLY CERTIFY SOMETHING REACHABLE (#3374 P3).
# The floor below was "one character after //", so `https://:8443/mcp/` (NO host), `https://my
# daemon:8000/mcp` (a space in the host) and `https://api.premiselabs.co:8443x/mcp/` (a non-numeric
# port) all printed SELFHOSTED and exited 0 — LAYER VERIFIED over an entry pointing at nothing, the
# same false green the scheme-less BADURL arm closes. The rule is the CLIENT's parser, not a guess:
# every shape refused here is one `new URL(u)` THROWS on (measured ERR_INVALID_URL), so refusing it
# cannot over-block a config that works — no request could be built from it either. The shapes URL
# ACCEPTS stay accepted: a bare trailing `host:`, a trailing root dot, an underscore, an IDN, and
# `[<ipv6>]:port`. Empty-labeled and alnum-free forms the client parses but DNS cannot resolve
# (`.`, `-`, `a..b`) are refused too: typos, never a configured endpoint.
# ⛔ `merge-mcp.py`'s `authority_names_a_host` is the SAME predicate under the SAME name — a shape
# refused here must be refused there and vice versa, so the repair always converges.
def _port_ok(port):
    if port is None or port == "":              # absent, or the bare-`host:` spelling URL accepts
        return True
    if not port.isdigit():
        return False
    return 1 <= int(port) <= 65535


# ⛔ WHATWG URL's forbidden HOST code points, and the IDNA rule for non-ASCII labels. A host
# containing one is refused by the client's parser outright, so certifying it is a false PASS —
# `api.premiselabs.co|evil.example` passed an "every label has an alnum" test and printed
# `SELFHOSTED:` rc=0 (#3374 review, round 2 P3). `merge-mcp.py` carries the SAME helpers.
_HOST_FORBIDDEN = set("\x00\t\n\r #/:<>?@[\\]^|")

# ⛔ DOT-EQUIVALENT CODE POINTS SPLIT ONE LABEL INTO TWO (#3374 review, round 13 P1). `new URL` applies
# UTS46, which maps U+3002/U+FF0E/U+FF61/U+FE52/U+2024 to `.`, so
# `https://api.premiselabs.co。evil.example/mcp/` resolves in the CLIENT to
# `api.premiselabs.co.evil.example` — an attacker's host — while this predicate read it as one harmless
# label and printed `SELFHOSTED:` rc=0 with `Bearer ${TORTOISE_MCP_API_KEY}` still attached. Checked on
# the NFKC form and BEFORE the idna branch: a box with no `idna` accepts every non-ASCII label, so an
# idna-only guard would leave it open. `merge-mcp.py` carries the SAME rule.
_DOT_EQUIVALENT = "\u3002\uff0e\uff61\ufe52\u2024"


try:                                          # IDNA2008/UTS46 — the standard the client applies
    import idna as _idna
except ImportError:                           # pragma: no cover — stdlib-only box
    _idna = None


def _dns_identity(label):
    """The label as DNS compares it: NFC-composed, then case-folded to its canonical form.

    The unit of the spoof rule in `_label_ok`. Two spellings are the SAME host when they are
    Unicode-equivalent apart from case — `MÜNCHEN` / `münchen` / `mu\u0308nchen`, and also
    `a\ufb00b` / `affb`, which UTS46 maps as a compatibility DECOMPOSITION — and a DIFFERENT host
    when the client's mapping DELETES a code point (`co\xad` -> `co`) or introduces a separator
    (`co\u3002evil` -> `co.evil`, caught earlier by the NFKC/dot check).

    ⛔ WHY `casefold` AND NOT `lower`. `casefold` is FULL case folding, so it also absorbs the
    compatibility renames UTS46 itself performs (`ﬁ` -> `fi`, `ſ` -> `s`, `µ` -> `μ`). That is
    deliberate, not an oversight, and it is the whole point: the rule asks "is this the same
    HOST", and a UTS46 compatibility decomposition is the same character by Unicode's definition,
    not a substitution. Narrowing this to `lower` would REFUSE `a\ufb00b` / `affb` — i.e.
    re-introduce the false block on legitimate IDNs that this rule exists to remove.

    Measured over all 0x110000 code points, so the justification above is a number and not a
    belief: UTS46 renames 6465 of them to a non-empty string, 2531 of those are invisible to this
    predicate — 1241 `Lu` + 27 `Lt` + 166 `Ll` case, plus 1097 non-case of which 1096 satisfy
    `NFKD(ch) == uts46_remap(ch)` (a compatibility decomposition) and the 1 exception, U+0345
    COMBINING GREEK YPOGEGRAMMENI, satisfies `casefold(ch) == uts46_remap(ch)` — its remap IS its
    case fold. So no hidden rename is a substitution: every one is another spelling of the SAME
    character. And **0 of the UTS46 DELETIONS are erased by `casefold`** — so the deleting class
    this rule exists to catch can never hide here. (Earlier text claimed NFC-not-NFKC avoided the
    `ﬁ` fold; that was false, `casefold` performs it too. The fold is intended; the claim was not.)
    """
    return unicodedata.normalize("NFC", label).casefold()


def _label_ok(lab):
    if not lab or not any(ch.isalnum() for ch in lab):
        return False
    if any(ch in _HOST_FORBIDDEN for ch in lab):
        return False
    # (1) DOT-EQUIVALENTS SPLIT ONE LABEL INTO TWO. Checked on the NFKC form, in stdlib, so it holds
    # on a box with no `idna` too.
    if any(ch in _DOT_EQUIVALENT for ch in lab) or "." in unicodedata.normalize("NFKC", lab):
        return False
    if lab.isascii():
        return True
    if _idna is None:
        # (2) STDLIB-ONLY FALLBACK — REFUSE EVERY NON-ASCII LABEL, because the question this branch
        # has to answer ("did the client's UTS46 mapping RENAME this label?") CANNOT be answered
        # without the mapping. Two attempts at approximating it by Unicode general category were both
        # wrong, and the second was still a false PASS:
        #   * `co\xad` (Cf) IS deleted, so a Cf/Mn/Me refusal blocks that one;
        #   * but U+115F, U+1160, U+3164 and U+FFA0 (the HANGUL FILLERS) are category `Lo` and are ALL
        #     UTS46-ignored, i.e. DELETED too — measured: with `_idna = None`,
        #     `api.premiselabs.co\u3164.evil.example` was CERTIFIED as the hosted host with the key
        #     attached, because they are Lo;
        #   * and 1737 of the 2027 Cf/Mn/Me code points are NOT deleted (U+0300 COMBINING GRAVE is
        #     `Mn` and maps to itself), so the same test false-BLOCKED legitimate combining-mark IDNs.
        # No general category answers this question, and a category list is a BLOCKLIST — rounds 12-14
        # are three proofs that the next spelling is one edit away. So this branch does not enumerate,
        # it DECLINES. A non-ASCII self-host here is REPLACED by the hosted default (an unusable
        # entry, which the merge repairs and `--verify` then accepts), the same declared over-block
        # class as `:0` and the percent-encoded host above: a refusal an operator can see beats a
        # false PASS that mails the tenant key to an attacker's host.
        return False
    try:
        # (3) ⛔ THE MAPPING MUST NOT RENAME THE HOST — and "renamed" is DNS IDENTITY, not byte
        # equality. Rounds 12 and 13 each closed one SPELLING (`%2e`, then the five dot-equivalents)
        # and each time the next spelling through the same mapping was still certified. Compare what
        # we READ with what the CLIENT RESOLVES, under the rule DNS itself uses (NFC, case-folded):
        #   * `co\xad` -> `co` and `co\u3164` -> `co` rename the label      → REFUSED;
        #   * `co\u3002evil` -> `co.evil` adds a separator, caught above by `_DOT_EQUIVALENT` → REFUSED;
        #   * `münchen` -> `münchen`, `MÜNCHEN` -> `münchen`, `mu\u0308nchen` -> `münchen` (NFC),
        #     `xn--mnchen-3ya`, `my_host`, `localhost` are all the SAME host → CERTIFIED.
        # ⛔ BYTE EQUALITY (`uts46_remap(lab) != lab`) was the previous spelling of this rule, and it
        # false-BLOCKED `MÜNCHEN.example` and `mu\u0308nchen.example`: measured, `--install` then
        # REPLACED the operator's IDN self-host with the hosted default, silently repointing their own
        # daemon at the hosted graph — while the ASCII fast path above accepted the identical case
        # change. The rule is the host's identity, not the string's.
        if _dns_identity(_idna.uts46_remap(lab, std3_rules=False, transitional=False)) != _dns_identity(lab):
            return False
        encoded = _idna.encode(lab, uts46=True)
    except Exception:
        return False
    # Cheap belt-and-braces, and say so honestly: with the checks above in place this can no longer
    # fire — a punycode label cannot contain a dot, and a mapping that introduced one is caught by the
    # NFKC/`_DOT_EQUIVALENT` check and by `_dns_identity`. It is kept as a last-resort assertion on the
    # bytes we would actually send, NOT as the thing that catches a separator.
    return b"." not in encoded


def authority_names_a_host(authority):
    a = (authority or "").strip()
    if not a or any(c.isspace() for c in a):
        return False
    if "@" in a:                                  # userinfo is NOT the host (refused elsewhere)
        a = a.rsplit("@", 1)[1]
    if a.startswith("["):                          # `[<ipv6>]`, optionally `:port`
        m = re.match(r"^\[([0-9A-Fa-f:.]+)\](?::(.*))?$", a)
        if not m or not _port_ok(m.group(2)):
            return False
        try:
            ipaddress.IPv6Address(m.group(1))
        except ValueError:
            return False
        return True
    if a.count(":") > 1:                          # an unbracketed IPv6 is not a legal authority
        return False
    host, sep, port = a.partition(":")
    if sep and port and not _port_ok(port):
        return False
    if not host or "%" in host:                    # empty, or pct-encoded (the client throws)
        return False
    labels = host[:-1].split(".") if host.endswith(".") else host.split(".")
    return all(_label_ok(lab) for lab in labels)
# ⛔ "contains ${" IS NOT ENOUGH FOR THE HOSTED ENDPOINT. The client DOES expand `${VAR}`
# (extensions/mcp-client/index.ts:819-821) and then sends the value as-is — it adds no scheme — so
# `Authorization: ${TORTOISE_MCP_API_KEY}` (no scheme) is delivered as `Authorization: tt_…` and the
# server answers 401, yet it contains "${" and used to
# be certified. Nor is any variable acceptable: the resolver reads TORTOISE_MCP_API_KEY (and the
# LEGACY alias TORTOISE_API_KEY), so an entry naming a third variable would expand to the EMPTY STRING
# while `LAYER VERIFIED` printed a green credential line beside it. Both names are allowed, nothing
# else is, and the scheme is required.
HOSTED_AUTH = re.compile(r"^Bearer\s+\$\{TORTOISE_(API|MCP_API)_KEY(:-[^}]*)?\}$")
# ⛔ THE HOSTED DEFAULT IS A FIXED FACT, NOT "WHATEVER THE TEMPLATE HAPPENS TO SAY" — and getting
# this wrong is a false BLOCK on the one configuration the docs tell self-host operators to write.
# This marker asks two different questions and they must not be answered from one value:
#   (i)  "is this the HOSTED endpoint?" — then it needs the env-indirect credential and its `type`
#        must be `http` (that endpoint answers 401 without a key); and
#   (ii) "does this cell point where the operator wants?" — the template's own `url`, which a
#        self-host operator is DOCUMENTED to point at their own daemon (SETUP-NEW-MACHINE.md:181-183,
#        tortoise's `docs/quickstart-selfhosted.md`).
# Using the template's url for (i) made it a tautology: a self-host template installed the operator's
# own entry and this marker then demanded the hosted credential for it (`NOAUTH`) — install wrote a
# file verify refused, so `verify → install → verify` could never converge. merge-mcp.py answers the
# same two questions from the same two values (its own HOSTED_DEFAULT_URL). (#3374 review P1.)
# ⛔ KEEP IN SYNC WITH `merge-mcp.py` — an arm in pi-bootstrap/tests/test-cell-install.sh pins BOTH
# constants to the SHIPPED template, so neither can drift away from the endpoint it names.
HOSTED_DEFAULT_URL = "https://api.premiselabs.co/mcp/"


def _endpoint_key(u):
    """`scheme://host[:non-default-port]` + the rest — the IDENTITY of an endpoint (MUST MATCH
    `merge-mcp.py`'s `endpoint_key`, which carries the full rationale).

    ⛔ BYTE EQUALITY IS NOT ENDPOINT IDENTITY (#3374 review, round 12 P2). The client's parser drops
    a DEFAULT port, so `https://api.premiselabs.co:443/mcp/` and `…co:/mcp/` are the SAME endpoint as
    `HOSTED_DEFAULT_URL`; comparing bytes made them "somewhere the operator did not ask for", which
    routed them to the `_selfHosted` exemption and SKIPPED the hosted credential requirement
    entirely. Measured: the canonical spelling is refused `WRONG_AUTH`, the `:443` spelling of the
    same entry is certified `SELFHOSTED:` rc=0 and the note then says "a self-hosted daemon needs
    none" about the hosted host. Only 443/https and 80/http are dropped — a non-default port is the
    documented self-host shape and stays distinct.
    """
    s = (u or "").strip()
    m = re.match(r"^([a-z][a-z0-9+.\-]*)://(?:[^/?#]*@)?(\[[^\]]*\]|[^/?#:]*)(?::(\d*))?", s, re.I)
    if not m:
        return s                       # an unparseable url compares by its own bytes
    scheme, host, port = m.group(1).lower(), m.group(2).lower(), m.group(3)
    # ⛔ A TRAILING ROOT DOT IS THE SAME DNS NAME (#3374 review, round 13 P1 — MUST MATCH
    # `merge-mcp.py`, which carries the full rationale and the measurement). `api.premiselabs.co.`
    # is the FQDN spelling of the hosted host: the client's parser keeps the dot and DNS resolves it
    # to the same server, so a request there reaches the LIVE hosted endpoint and needs the hosted
    # key. Measured before this rule: `https://api.premiselabs.co./mcp/` plus `_selfHosted: true`
    # and `Bearer ${SOME_OTHER_VAR}` was certified `SELFHOSTED:` rc=0 — the empty-Bearer 401 this
    # change exists to close, blessed as "a self-hosted daemon needs none". Stripping the root dot
    # narrows NO exemption: a genuine self-host is a different HOST, and `:8443` stays distinct.
    if host.endswith("."):
        host = host[:-1]
    # ⛔ USERINFO FORCES THE KEY TO DIFFER — never let a spoof url key to the hosted endpoint by
    # DROPPING it (MUST MATCH `merge-mcp.py`). Otherwise `https://user:pw@api.premiselabs.co/mcp/`
    # takes the hosted path and skips the arm that refuses userinfo outright.
    authority = s.split("://", 1)[1].split("/", 1)[0].split("?", 1)[0].split("#", 1)[0]
    prefix = "userinfo@" if "@" in authority else ""
    # ⛔ A LEADING ZERO IS NOT A DIFFERENT PORT — `:0443` IS `:443` (MUST MATCH `merge-mcp.py`,
    # which carries the full rationale and the measurement: the client's own parser normalises all
    # three spellings to the canonical hosted url). Without this a leading-zero default port took
    # the self-host exemption and was certified without any credential check.
    if port:
        port = port.lstrip("0") or "0"
    if port == "" or (port is not None and ((scheme == "https" and port == "443")
                                            or (scheme == "http" and port == "80"))):
        port = None
    return "%s%s://%s%s%s" % (prefix, scheme, host, (":" + port) if port else "", s[m.end():])


def _authority_key(u):
    """`scheme://host[:non-default-port]` — `_endpoint_key` with the PATH, QUERY and FRAGMENT cut off.

    ⛔ "IS THIS THE HOSTED ENDPOINT?" IS A QUESTION ABOUT THE AUTHORITY, NOT ABOUT THE PATH (#3374
    review, round 12 P1 — a FALSE PASS, and the most reachable one in this file). `_endpoint_key`
    appends `s[m.end():]` VERBATIM, so every spelling the client normalises in the PATH — and the
    FRAGMENT, which is never even sent — keyed DIFFERENTLY from `HOSTED_DEFAULT_URL` and escaped the
    hosted branch entirely. Measured at the head that introduced `_endpoint_key`, with a self-host
    template and `Bearer ${SOME_OTHER_VAR}` (an EMPTY Bearer, #3275/#3289):
        https://api.premiselabs.co/mcp            → SELFHOSTED: rc=0
        https://api.premiselabs.co/foo/../mcp/    → SELFHOSTED: rc=0
        https://api.premiselabs.co/mcp/?x=1       → SELFHOSTED: rc=0
        https://api.premiselabs.co/mcp/#x         → SELFHOSTED: rc=0
    and `node -e 'new URL(u).href'` normalises ALL FOUR onto the canonical hosted url, which answers
    HTTP 401 to an unauthenticated POST — i.e. each one is the live hosted endpoint, certified with
    no credential at all. The reachable-by-accident form needs no marker and no hand-edit: a TEMPLATE
    whose own url is the hosted host spelled without the trailing slash installed an entry carrying
    `headers: null` and `--verify` certified it `SELFHOSTED:`, so install and verify CONVERGED on the
    false pass this entire change exists to close.

    No path, query or fragment on the hosted AUTHORITY can make an entry a self-host, because the
    credential requirement is about the HOST the key is sent to. A genuine self-host is a DIFFERENT
    authority — another host, or the same host on a non-default port (`:8443`) — and `_endpoint_key`
    keeps the port, so this does not narrow the exemption at all.

    ⛔ DERIVED FROM `_endpoint_key`, NOT A SECOND PARSER. The host/port/userinfo/leading-zero rules
    (and their measurements) live in exactly one place above; re-deriving the authority from `s`
    would be another regex for the same question in a repo where the drift between such copies is
    what rounds 10-12 kept closing.
    """
    k = _endpoint_key(u)
    m = re.match(r"^((?:userinfo@)?[a-z][a-z0-9+.\-]*://[^/?#]*)", k, re.I)
    return m.group(1) if m else k

# ⛔ A DIFFERING url is not automatically fine, and a MISSING Authorization is not automatically
# broken: the two questions are linked. Accepting any non-empty http url let a cell whose endpoint
# was a typo (or copied from another box) be certified LAYER VERIFIED while pointing at nothing — a
# false green of exactly the class this function exists to close. And demanding an env-indirect
# header unconditionally refuses the DOCUMENTED self-host config (a local daemon needs no key,
# tortoise docs/quickstart-selfhosted.md), which merge-mcp.py then "repairs" by repointing it.
# So: the hosted default REQUIRES the env-indirect header; any other url requires the operator to
# have said so with `_selfHosted: true`, and is then reported BY NAME rather than silently passed.
# ⛔ "THE HOSTED DEFAULT" IS `HOSTED_DEFAULT_URL`, NOT `want_url` (#3374 review P1). With `want_url`
# there, a template that points at the operator's OWN daemon made (ii) and (i) the same value, so the
# cell's correctly-installed self-host entry fell to the hosted branch and was refused `NOAUTH` — a
# false block, and a repair loop that could never converge. The two questions now have two answers:
#   `url != want_url`                      → the cell points somewhere the operator did not ask for
#                                            (needs `_selfHosted`); and
#   `want_url != HOSTED_DEFAULT_URL`       → the operator asked for a NON-hosted endpoint, so the
#                                            entry they got is that endpoint, certified BY NAME.
# ⛔ A HOSTED URL IS NOT "SOMEWHERE THE OPERATOR DID NOT ASK FOR" (#3374 round 12, found by
# measurement: the arm printed `URL_NOT_DEFAULT:https://api.premiselabs.co/mcp/` — a refusal whose
# own NAME the payload falsifies). With a SELF-HOST template the first arm fired on the cell's
# HOSTED entry, so `merge-mcp.py`'s correct new behaviour (keep the hosted entry, never mark it)
# produced a file this verifier then REFUSED: `verify -> install -> verify` could never converge on
# the one endpoint the shipped template installs. The template says what the operator asked for; it
# cannot make the hosted endpoint stop being the hosted endpoint. So a hosted url skips this arm
# (`_url_is_hosted` below) and is judged by the hosted branch — WHICH STILL DEMANDS THE HOSTED
# CREDENTIAL. That is the point: the bypass this closes is the *exemption*, not the endpoint.
# ⛔ AND THE QUESTION IS ASKED OF THE AUTHORITY (`_authority_key`), NOT THE WHOLE KEY (#3374 review,
# round 12 P1). With `_endpoint_key` here, a hosted url spelled `/mcp` (no trailing slash),
# `/foo/../mcp/`, `/mcp/?x=1` or `/mcp/#x` keyed DIFFERENTLY, took the exemption, and was certified
# `SELFHOSTED:` rc=0 over an EMPTY Bearer — see `_authority_key`'s docstring for the measurement.
# The two questions are now distinct on purpose:
#   `_url_is_hosted`    — is this the hosted AUTHORITY? Then the hosted credential is REQUIRED, and
#                         no marker and no template can exempt it.
#   `_url_is_canonical` — is it the hosted endpoint spelled EXACTLY as `HOSTED_DEFAULT_URL`? Only
#                         that spelling is certified; every other hosted spelling is a typo the
#                         installer normalises, so it is refused by the same name `URL_NOT_DEFAULT`
#                         and `merge-mcp.py` canonicalisation makes the repair converge.
# ⛔ CLEARTEXT TO THE HOSTED HOST IS NOT A SELF-HOST, AND IT NEEDS NO CREDENTIAL TO BE WRONG (#3374
# review, round 14 P2 — a FALSE PASS, measured). The INSECURE_URL floor above fires only when `auth` is
# present, so a `http://api.premiselabs.co/mcp/` entry with NO Authorization skipped it, keyed by SCHEME
# as a different endpoint, took the `_selfHosted`/template arms below, and printed `SELFHOSTED:` rc=0 —
# LAYER VERIFIED over the LIVE hosted host in cleartext, with the sentence "a self-hosted daemon needs
# none". The endpoint is https-only, so this is not an operator's daemon: the request either fails or is
# answered by whatever the host serves in the clear, and the cell reports green either way.
# `merge-mcp.py`'s `usable()` REFUSES this shape too (same rule, same reasoning), so install and verify
# agree and `verify -> install -> verify` converges by refusal rather than looping.
# The test is the endpoint identity with the scheme swapped for `https` — `_endpoint_key` owns the
# default-port, leading-zero and root-dot rules, so this cannot drift from them, and a genuine self-host
# on a different port (`http://localhost:8000/mcp`, `http://api.premiselabs.co:8443/mcp/`) is untouched.
# It sits HERE, not beside the floor above, because `_endpoint_key` is defined further down this program
# and calling it earlier raises NameError (caught by the arms below, which is why they run).
if (url or "").lower().startswith("http://") \
   and "://" in url \
   and _endpoint_key("https://" + url.split("://", 1)[1]) == _endpoint_key(HOSTED_DEFAULT_URL):
    print("INSECURE_URL:%s" % shown_url(url))
    sys.exit(1)
_url_is_hosted = _authority_key(url) == _authority_key(HOSTED_DEFAULT_URL)
_url_is_canonical = _endpoint_key(url) == _endpoint_key(HOSTED_DEFAULT_URL)
_selfhosted_shape = False
if _url_is_hosted:
    if not _url_is_canonical:
        # The hosted host, spelled some other way: NOT a self-host (so never exempt), and NOT the
        # default, so `--verify` refuses it by name and `--install` normalises it to
        # `HOSTED_DEFAULT_URL`. Before this arm existed these spellings were CERTIFIED as self-hosts.
        print("URL_NOT_DEFAULT:%s" % shown_url(url))
        sys.exit(1)
elif want_url and _endpoint_key(url) != _endpoint_key(want_url):
    if not t.get("_selfHosted"):
        print("URL_NOT_DEFAULT:%s" % shown_url(url))
        sys.exit(1)
    _selfhosted_shape = True
elif want_url and _endpoint_key(want_url) != _endpoint_key(HOSTED_DEFAULT_URL):
    # The TEMPLATE requests a non-hosted endpoint and the cell points exactly there: the operator
    # declared it once, in the file this cell was built from, so no per-box `_selfHosted` is owed.
    _selfhosted_shape = True
# ⛔ THE EXEMPTION MAY NOT REACH THE HOSTED ENDPOINT (#3374 review, round 12 P2 — a FALSE PASS).
# Both arms above ask about the TEMPLATE and the marker; neither asked whether the url IS the hosted
# endpoint. So a `_selfHosted`-marked entry AT the hosted url (which `merge-mcp.py` minted itself when
# the template named a self-host — it marked "this machine's own url" on the hosted one) was certified
# `SELFHOSTED:` WITHOUT EVER LOOKING AT ITS CREDENTIAL. Measured: `.mcp.json` = hosted url +
# `Bearer ${SOME_OTHER_VAR}` (an EMPTY Bearer, #3275/#3289) + `_selfHosted: true`, template url
# `https://192.168.1.5/mcp` → `SELFHOSTED:https://api.premiselabs.co/mcp/` rc=0 and LAYER VERIFIED,
# while the SAME file against the shipped template is refused `WRONG_AUTH:${SOME_OTHER_VAR}` rc=1. The
# endpoint that needs the key cannot be exempted from needing it by a marker or a template; the hosted
# path is decided by the ENDPOINT, so it is decided here by key and the hosted credential is required.
# …and it is stated as ONE invariant over BOTH arms above rather than repeated in each, so a later
# edit to either arm cannot reintroduce the false pass by forgetting it (this file's round-12
# pattern: the rule was written per-branch and one branch was missed). UNREACHABLE BY CONSTRUCTION
# today — `_url_is_hosted` returns before either arm can set the flag — and kept deliberately as the
# invariant it encodes, so the guarantee is restated where the exemption is granted rather than only
# implied by the control flow above.
if _selfhosted_shape and _url_is_hosted:
    _selfhosted_shape = False
if _selfhosted_shape:
    # ⛔ `_selfHosted` IS AN EXEMPTION, NOT A LICENCE TO CERTIFY ANY STRING (#3374 review P2). The
    # branch used to print SELFHOSTED and exit 0 for ANY marked url — including a SCHEME-LESS one
    # (`localhost:8000/mcp`), which `new URL()` in the client reads with protocol `localhost:` and no
    # host, so a cell pointing at nothing was certified LAYER VERIFIED with a green credential line.
    # An absolute http(s) url is the minimum this exemption can honestly certify.
    _su = re.match(r"^([a-z][a-z0-9+.\-]*)://([^/?#]+)", url or "", re.I)
    if not _su or _su.group(1).lower() not in ("http", "https"):
        print("BADURL:%s" % shown_url(url))
        sys.exit(1)
    # ⛔ AND "ABSOLUTE" IS NOT "REACHABLE" (#3374 review P3): `https://:8443/mcp/` is absolute-
    # looking with NO host, and it was certified SELFHOSTED rc=0. The predicate is shared by name
    # with `merge-mcp.py`, which REFUSES the shape, so the repair replaces it and this verifies the
    # result — converge, in both directions.
    if not authority_names_a_host(_su.group(2)):
        print("NOHOST:%s" % shown_url(url))
        sys.exit(1)
    # ⛔ USERINFO IN THE AUTHORITY IS NOT A SELF-HOST, IT IS A SPOOF SPELLING (#3374 review P1). The
    # real host is the part AFTER the `@` — `https://api.premiselabs.co@evil.example/mcp/` is
    # **evil.example** — and this branch used to certify it `SELFHOSTED:` with the entry's
    # `Bearer ${TORTOISE_MCP_API_KEY}` still attached, i.e. LAYER VERIFIED over the tenant key going to
    # an attacker's host. It is also NOT a config that works: the client cannot even build a request
    # from a url with credentials (`new Request('http://u:p@h/')` throws "Request cannot be constructed
    # from a URL that includes credentials"). `merge-mcp.py`'s `usable()` refuses the same shape, so
    # the repair REPLACES it — verify and install must not disagree in either direction.
    if re.match(r"^[a-z][a-z0-9+.\-]*://[^/?#]*@", url or "", re.I):
        print("USERINFO:%s" % shown_url(url))
        sys.exit(1)
    # A self-hosted entry is certified BY NAME, and its own transport spelling is part of what the
    # operator chose: the client selects StreamableHTTP from `url` alone and never reads `type`, so
    # refusing `sse` here would refuse a config that WORKS (and that install preserves on purpose).
    print("SELFHOSTED:%s" % shown_url(url))
else:
    if t.get("type") not in (None, "http"):
        print("NOTHTTP:%s" % t.get("type"))
        sys.exit(1)
    if not auth:
        print("NOAUTH")
        sys.exit(1)
    if not HOSTED_AUTH.match(auth.strip()):
        # ⛔ THE HEADER IS NOT PRINTED, AND `redact()` WAS NOT ENOUGH (#3374 review, round 12 P2).
        # `redact()` masks `tt_`/`tk_` SHAPES only, so `WRONG_AUTH:Bearer ${TORTOISE_MCP_API_KEY}
        # hunter2NOTATOKEN` — a trailing literal on an otherwise-correct header, which is what a bad
        # paste or a merge of two headers produces — went into a bring-up log that gets pasted into
        # issues fleet-wide. ⛔ A BARE LITERAL NEVER REACHES HERE (it is `LITERAL_AUTH`, one branch up,
        # which prints no value at all), so that is NOT the shape this arm is for: measured on the
        # PRE-FIX marker, this header printed in full, and this block prints the variable alone.
        # What an operator actually needs is WHICH VARIABLE was named, and a `${VAR}` name is not a
        # secret; anything else is withheld, because a literal in that position IS the secret.
        # Measured: the arm that pins this asserts the secret is ABSENT from the log, not that the
        # marker is present.
        _m = re.match(r"^Bearer\s+\$\{([A-Za-z_][A-Za-z0-9_]*)", (auth or "").strip())
        print("WRONG_AUTH:%s" % (("${%s}" % _m.group(1)) if _m
                                 else "<a literal, not a ${VAR} reference — value withheld>"))
        sys.exit(1)
    # ⛔ THE SUCCESS MARKER PRINTED THE HEADER VERBATIM, SO THE LEAK SURVIVED ONE BRANCH OVER (#3374
    # review, round 12 P2). `HOSTED_AUTH` admits `${VAR:-<anything>}` — a spelling the client DOES
    # support (`extensions/mcp-client/index.ts`: `${VAR:-default}`, expanded recursively) — so a
    # literal default is a value that reaches the wire, and it went into BOTH the `--verify` and the
    # `--install` log on the branch that fires for a CORRECT config: measured,
    # `Bearer ${TORTOISE_MCP_API_KEY:-hunter2NOTATOKEN}` printed in full, `rc=0`. An operator needs
    # WHICH VARIABLE, and a name is not a secret; a default is a value, so it is withheld.
    # ⛔ AND THE NAME MUST BE THE WHOLE NAME (#3374 round 12, found by measurement). The first cut
    # used `\$\{[A-Za-z_][A-Za-z0-9_]*` with NO closing brace, so the marker printed
    # `OK:<url>:${TORTOISE_MCP_API_KEY` — a TRUNCATED variable name that no reader can paste back,
    # and which made the arm asserting the certified marker fail on a correct config. Taking the name
    # from `HOSTED_AUTH`'s own match is what makes that impossible: the name printed here is by
    # construction one the refusal branch above accepts, so the marker can never name a variable the
    # verifier would have rejected. Only the NAME is printed — a `${VAR:-default}` default is a
    # literal value that reaches the wire, so it is DROPPED rather than reproduced.
    _am = HOSTED_AUTH.match((auth or "").strip())
    print("OK:%s:%s" % (shown_url(url),
                        ("${TORTOISE_%s_KEY}" % _am.group(1)) if _am
                        else "<a header this verifier did not recognise — withheld>"))
PY
}

  # The marker is CAPTURED, not just sniffed from $?: the FAIL sentence must name the thing that is
  # actually wrong (a leak in another server's entry is not a broken tortoise entry), and $? cannot
  # tell the two apart. The line is still echoed into the run log — the self-host case is reported
  # BY NAME there, deliberately.
  local out=""
  out="$(graph_mcp_marker "$f" "$INFRA_ROOT/templates/.mcp.base.json")"
  local rc=$?
  [ -n "$out" ] && log_line ".mcp.json verify: $out"
  if [ "$rc" -eq 0 ]; then
    :
  else
    case "$out" in
      SECRET_IN_FILE:*)
        fail "a credential LITERAL is written into .mcp.json at ${out#SECRET_IN_FILE:} — a shared config file must be env-indirect (\${TORTOISE_MCP_API_KEY}); remove the literal and put the key in \$HOME/keys.env (mode 600)" ;;
      LITERAL_AUTH*)
        fail ".mcp.json's tortoise entry carries a LITERAL bearer token instead of \${TORTOISE_MCP_API_KEY} — the shared file is the leak" ;;
      WRONG_AUTH:*)
        fail ".mcp.json's tortoise Authorization is not 'Bearer \${TORTOISE_MCP_API_KEY}' (or the legacy 'Bearer \${TORTOISE_API_KEY}') — the client expands the variable and sends the value as-is (it adds no scheme), so anything else reaches the server as a 401 (got: ${out#WRONG_AUTH:})" ;;
      INSECURE_URL:*)
        fail ".mcp.json's tortoise url (${out#INSECURE_URL:}) is CLEARTEXT (non-https) and not loopback, in one of two shapes and both refused: it carries a credential over a NON-https scheme — the client expands the header, so the live key would cross the wire in cleartext while this cell reported LAYER VERIFIED — or it names the HOSTED host, which is https-only whether or not a credential is attached, so the cell would be certified over an endpoint that cannot answer. Use https, or point at your own local daemon (a self-host needs no key)" ;;
      BADDERS:*)
        fail ".mcp.json's tortoise entry declares its headers value as a ${out#BADDERS:}, not an object — the Authorization cannot be read from it, so nothing can be certified. Make it an object: {\"Authorization\": \"Bearer \${TORTOISE_MCP_API_KEY}\"} — a re-install does this for you" ;;
      BADROOT:*|BADSERVERS:*)
        fail ".mcp.json's ${out%%:*} is a JSON ${out#*:}, not an object — nothing can be read from it, so nothing can be certified. A re-install REPLACES it and keeps the old file as .mcp.json.bak" ;;
      BADAUTH:*)
        fail ".mcp.json's tortoise Authorization is a ${out#BADAUTH:}, not a string — a config the client cannot expand, and a shape no merge can repair. Make it \"Bearer \${TORTOISE_MCP_API_KEY}\" (a re-install replaces it)" ;;
      URLTYPE:*)
        fail ".mcp.json's tortoise url is a ${out#URLTYPE:}, not a string — nothing can be resolved from it, so nothing can be certified (a re-install replaces the entry)" ;;
      BADURL:*)
        fail ".mcp.json's tortoise entry is marked _selfHosted but its url (${out#BADURL:}) is not an absolute http(s) url — the client builds a transport from it, so this cell points at nothing. Write the full url (e.g. http://localhost:8000/mcp)" ;;
      USERINFO:*)
        fail ".mcp.json's tortoise url (${out#USERINFO:}) carries USERINFO in its authority — the host that answers is the part AFTER '@', so an entry spelled like the hosted endpoint with '@evil.example' after it sends \${TORTOISE_MCP_API_KEY} to evil.example. The client cannot even build a request from a url with credentials. Write a plain url and keep the key in \$HOME/keys.env" ;;
      NOHOST:*)
        fail ".mcp.json's tortoise url (${out#NOHOST:}) is marked _selfHosted but its authority names no usable host — the client cannot build a request from it (an empty host, a space, a non-numeric or out-of-range port, a percent-encoded host, or a host DNS cannot resolve). Write the real endpoint, e.g. http://localhost:8000/mcp" ;;
      BADTPL:*)
        fail "the template (\$INFRA_ROOT/templates/.mcp.base.json) could not be read, so nothing can be certified — ${out#BADTPL:}. A cell without a usable template is a broken checkout; re-run install from a complete one" ;;
      UNREADABLE:*)
        fail ".mcp.json could not be READ at all (${out#UNREADABLE:}) — nothing can be certified from a file the verifier cannot open, and this is NOT the same fault as a wrong shape. Check the file's permissions/owner (it must be readable by the installing user) or re-install, which writes it through temp+rename" ;;
      NOAUTH*|NOURL*|NOENTRY*|NOTHTTP:*|URL_NOT_DEFAULT:*|STDIO:*|NOTJSON:*)
        fail ".mcp.json's tortoise entry is not the hosted shape the layer installs (marker: ${out%%:*}) — a hand-edited or stale cell copy, a checkout that still ships the legacy stdio entry, or a non-default url that is not marked _selfHosted" ;;
      *)
        fail ".mcp.json verify failed (marker: ${out:-none}) — the hosted entry could not be certified" ;;
    esac
    return 1
  fi
  graph_credential_note
  return 0
}

# ── the deny list: what must not run ON A CELL ──────────────────────────────
# Kept as data so the deny is readable and testable, and so the DEFAULT for a new
# manifest entry is "install" — the direction that cannot lose a guard. It is NOT a second
# list of files to copy: the manifest's ship-list is still the only source of what gets
# installed, and a denied row is simply skipped. The deny is then enforced against what is
# ACTUALLY ON THE CELL, in BOTH halves — `install_extensions` removes a present copy, and
# `verify_layer` fails a cell that still carries one — so a regression cannot report LAYER
# VERIFIED for the artifact that breaks the box. Deliberately not scoped to the manifest
# rows: bound to them, a deny would go inert the moment an entry was dropped from the
# ship-list, and a copy left on the cell would be certified clean.
DENY_EXTENSIONS=(
  cmux-session.ts        # bridge to the cmux DESKTOP APP (and spawns the `cmux` CLI per hook)
  tortoise-capture       # consumed the whole turn and wrote its banner into the channel
                         # cloud-cell-bringup.sh's provider probe reads (#2100, measured 2026-10-19
                         # on all three cells). Denied BY NAME: the deployed cell copy differed
                         # from this checkout's (`install probe recorded` exists in no repo file),
                         # so a content-keyed deny would have missed it. Written without the
                         # manifest's trailing slash because read_manifest_entries strips it.
)

# denied_extension_stem <base> — the NAME STEM every variant of a denied entry shares. The deny is
# enforced BY PATTERN (#2147), because `pi` discovers extensions by RULE, not by exact name:
# `dist/core/extensions/loader.js` loads any top-level `extensions/*.ts` / `*.js` and any
# `extensions/<dir>` holding `index.ts` or `index.js`. So `tortoise-capture.bak.ts`,
# `tortoise-capture.disabled.js` and `tortoise-capture.old/index.ts` are LOADED, one level down from
# the exact path an exact-name test looks at.
denied_extension_stem() {
  local b="${1%/}"
  b="${b%.ts}"; b="${b%.js}"
  printf '%s\n' "$b"
}

# denied_extension_note <base> — WHY a denied entry must be absent, worded ONCE. Both halves
# consume it: the install half's removal line and the verify half's failure line, so they can
# never describe different reasons for the same entry (a removal note that says "surface absent"
# about the capture extension would send an operator looking for a desktop app that is not the
# problem). The match is by NAME PREFIX (`tortoise-capture*`), so a SUFFIXED copy — the shapes that
# were surviving on the measured cells — gets the same diagnosis as the entry it is a copy of.
# ⛔ The capture wording is the INCIDENT'S, not a description of this checkout's file, and it is
# pinned verbatim by BOTH suites: "it blocks session_start and corrupts the provider probe". The
# cell ran a copy that differs from the repo (see the deny-list comment above), and an operator
# greps a bring-up log for exactly this sentence — so re-word it only together with the tests that
# assert it (pi-bootstrap/tests/test-cell-install.sh, scripts/cloud-cell-bringup.test.sh).
denied_extension_note() {
  case "${1%/}" in
    tortoise-capture*) printf 'it blocks session_start and corrupts the provider probe' ;;
    cmux-session*)     printf 'its surface is absent on a Linux cell' ;;
    *)                 printf 'the cell must not run it' ;;
  esac
}

# ── the homes a CELL can run a `pi` under (#2147's half) ────────────────────────────────────────
# MEASURED 2026-11-05, five cells: the deny was NAME-scoped (one exact path) and PER-HOME (only
# $DEST), and denied copies survived BOTH ways — 1 / 0 / 7 / 3 / 2 per box. The per-home half is
# #2916's two-home state: where CELL_HOME=$HOME was measured, the OPERATING home (/tmp/cell-home)
# kept its copies while the installer scanned the account home. Those copies injected
# `paused N (attempts; continues in the background)` (250+ bytes) onto the turn path — the very
# dead-lane shape the deny exists to stop.
#
# ⛔ THE EXTRA HOMES ARE DECLARED, NEVER GUESSED. Scanning the ambient `$HOME` unconditionally would
# make this installer DELETE a developer's own `~/.pi/agent/extensions/tortoise-capture` on a LAPTOP,
# where capture is a working feature and the box is not a cell — a destructive false positive, and
# exactly the class of over-reach this repo treats as its own kind of defect. `cloud-cell-bringup.sh`
# is the path that CERTIFIES a cell and it knows both homes (CELL_HOME and the account home), so it
# passes them here. Empty by default: a bare `bash pi-bootstrap/cell-install.sh` touches only the
# CELL_HOME it was given, as it always has.
CELL_ALT_HOMES="${CELL_ALT_HOMES:-}"

# cell_agent_dirs — every `<home>/.pi/agent` this cell can launch `pi` under, one per line, deduped.
# $DEST first (the home the installer writes and the session forces), then each declared alt home.
cell_agent_dirs() {
  {
    printf '%s\n' "${DEST%/}"
    local rest="${CELL_ALT_HOMES:-}" one
    while [ -n "$rest" ]; do
      one="${rest%%:*}"
      case "$rest" in *:*) rest="${rest#*:}" ;; *) rest="" ;; esac
      [ -n "$one" ] || continue
      printf '%s\n' "${one%/}/.pi/agent"
    done
  } | awk 'NF && !s[$0]++'
}

# loadable_extension_entry <path> — 0 iff `pi` would LOAD this entry. The rule is pi's own
# (`dist/core/extensions/loader.js`, `discoverExtensionsInDir`): a top-level `*.ts` / `*.js` file, or a
# directory holding `index.ts` / `index.js`, or a directory with a `package.json` naming its own
# entries. ⛔ THIS IS WHAT KEEPS THE DENY FROM OVER-BLOCKING: a `tortoise-capture-notes.txt` sitting
# beside the extension is NOT a copy of it (pi never reads it), and refusing OR DELETING it would be
# the false-positive direction — the sweep below can `rm -rf`, so the predicate has to be exact.
has_pi_manifest() { # <package.json> — 0 iff it declares pi.extensions (pi's own entry list)
  [ -f "${1:-}" ] || return 1
  python3 - "$1" <<'PYEOF' 2>/dev/null
import json, os, sys
try:
    doc = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
pi = doc.get("pi")
ext = pi.get("extensions") if isinstance(pi, dict) else None
if not isinstance(ext, list) or not ext:
    sys.exit(1)
# pi's `resolveExtensionEntries` also requires at least one DECLARED path that RESOLVES — a
# package.json naming a file that is not there falls through to the index check and loads nothing,
# so such a directory is not a copy of anything and must not be swept.
base = os.path.dirname(os.path.abspath(sys.argv[1]))
sys.exit(0 if any(isinstance(e, str) and e and os.path.exists(os.path.join(base, e)) for e in ext) else 1)
PYEOF
}

loadable_extension_entry() {
  local f="${1:-}"
  if [ -L "$f" ] && [ ! -e "$f" ]; then
    # A DANGLING symlink: `-e` follows the link and sees nothing, but pi would still try to resolve
    # it, so it is judged by the name it PRETENDS to be.
    case "$f" in *.ts|*.js) return 0 ;; esac
    return 1
  fi
  if [ -d "$f" ]; then
    [ -f "$f/index.ts" ] || [ -f "$f/index.js" ] || has_pi_manifest "$f/package.json"
    return
  fi
  case "$f" in *.ts|*.js) return 0 ;; esac
  return 1
}

# denied_shipped_names — the extension ship-list, normalised (trailing slash stripped), one name per
# line. Cached for the run: the manifest does not change under us, and `read_manifest_entries` is
# python-backed. Read in a SUBSHELL so its own `die` cannot end the caller.
# ⛔ WHY THE SWEEP NEEDS IT: without an exemption, a manifest entry whose name merely shares a denied
# STEM (e.g. `<stem>-helper.ts`) would be INSTALLED by the ship-list loop and then DELETED by the
# sweep below — `--verify` would then fail `extension MISSING` on every run, and the cell could never
# be provisioned. A name the repo actually SHIPS is not a copy of the denied entry.
DENIED_SHIPPED_CACHE=""
denied_shipped_names() {
  if [ -z "$DENIED_SHIPPED_CACHE" ]; then
    DENIED_SHIPPED_CACHE="$(read_manifest_entries 2>/dev/null | sed 's:/$::')"
    [ -n "$DENIED_SHIPPED_CACHE" ] || DENIED_SHIPPED_CACHE="__unreadable__"
  fi
  printf '%s\n' "$DENIED_SHIPPED_CACHE"
}

# denied_extension_copies <agent-dir> — every copy of a DENIED extension in that home that `pi`
# would actually LOAD, one absolute path per line.
# The name match is a PREFIX of the entry's stem (`tortoise-capture*`), which is what covers every
# variant a copy can take: `<stem>`, `<stem>.bak.ts`, `<stem>.disabled.js`, `<stem>.old/index.ts`,
# `<stem>-old/`. It is combined with `loadable_extension_entry` so the match is the SHAPES pi loads,
# not "any file whose name starts with the stem" — the difference is the arm that proves a
# `<stem>-notes.txt` beside the extension is neither refused nor deleted.
denied_copy_variant() {
  local base="${1%/}" stem="${2%/}" rest seg
  rest="${base#"$stem"}"
  [ "$rest" = "$base" ] && return 1          # does not start with the stem at all
  rest="${rest//.ts/}"; rest="${rest//.js/}"  # an extension suffix is not a marker
  # SEGMENTS, NOT ONE REMAINDER. A copy's name can compound (`-old-v2`, `.bak.1`, ` copy 2`), and each
  # of those parts is a marker on its own — a single-segment match missed them while pi loads every one
  # (they end in `.ts`). Split on the separators real names use, lower-case, and require EVERY remaining
  # part to be a copy marker or a version/number.
  local segs
  # `-` FIRST in the tr set. It is literal only first-or-last, and LAST is the space here:
  # GNU tr reads `._ -` as the range `_`-` ` and dies with "range-endpoints … in reverse
  # collating sequence order" (measured on a cell), while BSD tr accepts it — so the arm
  # passed locally and the sweep silently matched nothing on Linux.
  segs="$(printf '%s' "$rest" | tr 'A-Z' 'a-z' | tr -- '-._ ' '\n\n\n\n' | sed '/^$/d')"
  [ -z "$segs" ] && return 0                 # the entry itself, or the entry re-spelled `.ts`/`.js`
  while IFS= read -r seg; do
    case "$seg" in
      bak|backup|old|orig|copy|save|keep|dist|local|tmp|disabled|off) continue ;;
      # a marker carrying a version/number (`bak2`, `disabled3`) — but not an arbitrary word
      bak[0-9]*|backup[0-9]*|old[0-9]*|orig[0-9]*|copy[0-9]*|save[0-9]*|keep[0-9]*|dist[0-9]*|local[0-9]*|tmp[0-9]*|disabled[0-9]*|off[0-9]*) continue ;;
      v[0-9]*|[0-9]*) continue ;;
      *) return 1 ;;
    esac
  done <<EOF
$segs
EOF
  return 0
}

denied_extension_copies() { # <agent-dir>
  local dir="${1%/}/extensions" d stem f fbase shipped
  [ -d "$dir" ] || return 0
  # ⛔ READ ONCE. This function is always used on the left of a pipe, so its own assignments die with
  # the subshell — a cache INSIDE denied_shipped_names therefore re-ran the python-backed manifest
  # reader for every candidate (measured: the "cached for the run" comment was simply untrue).
  shipped="$(denied_shipped_names)"
  for d in "${DENY_EXTENSIONS[@]}"; do
    stem="$(denied_extension_stem "$d")"
    for f in "$dir/$stem"*; do
      # ⛔ TWO CLAUSES, because the deny has two subjects.
      # (1) THE DENIED ENTRY ITSELF, at its own name, however it currently resolves. `-e` follows a
      # symlink, so `-L` is what catches a DANGLING link at exactly this path — and a dangling link
      # must still be removed/refused even though pi would not load it TODAY: it is the deny path, it
      # costs one `ln -sf` to become a loaded extension again, and the install half removing it is
      # what keeps verify from looping (refuse -> install-that-cannot-repair -> refuse forever).
      { [ -e "$f" ] || [ -L "$f" ]; } || continue
      fbase="$(basename "$f")"
      if denied_extension "$fbase"; then printf '%s\n' "$f"; continue; fi
      # (2) ANY OTHER COPY pi would LOAD — the suffixed/dir shapes an exact-name deny cannot see.
      # ⛔ AND ONLY A COPY: a bare name PREFIX is not enough. `<stem>-helper.ts` is a DIFFERENT,
      # loadable extension, and deleting it would be the over-block direction (the sweep can
      # `rm -rf`) — and if the repo SHIPS such a name, install would ship it and this sweep delete
      # it, so `--verify` would fail `extension MISSING` on every run and the cell could never be
      # provisioned. So the remainder must be a copy MARKER, and a ship-list row is never a copy.
      if grep -Fxq -- "$fbase" <<<"$shipped"; then continue; fi
      denied_copy_variant "$fbase" "$stem" || continue
      loadable_extension_entry "$f" || continue
      printf '%s\n' "$f"
    done
  done | awk 'NF && !s[$0]++'
}

# ── the farm layout (#1723) ──────────────────────────────────────────────────
# <array name in setup.sh><TAB><source root under $INFRA_ROOT><TAB><destination under $DEST>
# An array in setup.sh that is NOT named here is a loud failure (see read_farm_set).
FARM_LAYOUT="$(printf '%s\n' \
  $'fleet_srcs\tscripts\tscripts' \
  $'mcp_harness_srcs\tscripts/orchestrator-harness\tscripts' \
  $'merge_gate_srcs\tscripts\tscripts' \
  $'graph_srcs\tscripts\tscripts' \
  $'lane_root_srcs\tscripts\tscripts' \
  $'lane_srcs\tscripts/lane\tscripts' \
  $'lib_srcs\tscripts/lib\tscripts/lib' \
  $'fleet_tools\ttools/fleet\tscripts/fleet')"

# Files pi itself auto-extracts into ~/.pi/agent/tools/ and therefore tolerates (#1277).
# pi's own rule, matched EXACTLY (dist/migrations.js `checkDeprecatedExtensionDirs`: it
# lowercases the entry and allows only these four, plus any hidden entry). An exact match is
# load-bearing: a PREFIX match would certify `rgfoo.py` — a non-fd/rg entry pi blocks every
# interactive boot on — which is precisely the false PASS this installer exists to remove.
TOOLS_ALLOWED_NAMES=( fd rg fd.exe rg.exe )

# A FLOOR on the declared farm set, and the minimum ship-list size. These are not the list —
# setup.sh and manifest.json are — they are the guard against a parse that SILENTLY SHRINKS
# (a regex that stops at the wrong `)`, a renamed array, a manifest key that moved): such a
# parse would install less and then verify clean against its own truncated reading. 24 farm
# files and 31 ship-list entries exist at the time of writing; the floors leave room for
# legitimate growth while a collapse is loud.
MIN_FARM_FILES=20
MIN_SHIP_LIST=10

# ── locating the checkout to install FROM ────────────────────────────────────
# A candidate "is a checkout" only if it carries EVERY file this script reads: the farm
# declaration (pi-bootstrap/setup.sh), the extension ship-list (manifest.json), and — since
# #1924 — the UNFARM leg and its retirement list. Anything weaker lets a shape-valid but
# incomplete tree win the resolution and then die mid-install: measured, a candidate with
# setup.sh + manifest.json but no pi-bootstrap/lib/ installed the whole farm and THEN failed
# the unfarm leg, leaving a cell with $DEST/scripts and no guards/extensions/skills (#1723's
# half-installed state). Requiring them here makes the resolver fall through to a complete
# checkout and refuses a partial one BEFORE any mutation.
is_infra_checkout() {
  [ -n "${1:-}" ] \
    && [ -f "$1/pi-bootstrap/setup.sh" ] \
    && [ -f "$1/manifest.json" ] \
    && [ -f "$1/pi-bootstrap/lib/farm-retire.sh" ] \
    && [ -f "$1/pi-bootstrap/farm-retired.txt" ]
}

resolve_infra_root() {
  local cand explicit=1
  # Order matters: an explicit INFRA_ROOT wins, then the checkout this script itself was
  # shipped in — the script IS a file inside that checkout, so whoever put it there already
  # chose what runs; a writer at that path could replace this script outright.
  for cand in "${INFRA_ROOT:-}" "$SELF_DIR/.."; do
    [ -n "$cand" ] || continue
    if is_infra_checkout "$cand"; then
      (cd "$cand" && pwd)
      return 0
    fi
    # An explicitly NAMED checkout that is not one must not be replaced in silence: the next
    # candidate wins and its farm arrays are then paired with a DIFFERENT checkout than the
    # operator named (and, since #1924, with that other checkout's retirement list — a
    # removal rule nobody wrote down). The resolved root is also printed in the banner, but a
    # swap has to be visible where it happens. Only INFRA_ROOT is reported: `$SELF_DIR/..` is
    # the ambient default and the ownership branch below already reports what it refuses.
    if [ "$explicit" = 1 ] && [ -n "${INFRA_ROOT:-}" ]; then
      printf '  refused (INFRA_ROOT is not a checkout — needs pi-bootstrap/setup.sh, manifest.json, pi-bootstrap/lib/farm-retire.sh and pi-bootstrap/farm-retired.txt): %s\n' "$cand" >&2
    fi
    explicit=0
  done
  # The AMBIENT candidates must additionally be owned by the user running this script. The
  # cell's HOME is a fixed path under a world-writable /tmp (/tmp/cell-home), so a
  # checkout-shaped tree appearing there may have been planted by another local user — and
  # everything under it is installed and then EXECUTED by pi (merge-one.sh runs the farmed
  # record-review.sh directly). The two paths above are the ones the operator chose to run
  # from.
  #
  # The check is on the LEAF we resolved, which is sufficient here: a leaf can only be
  # replaced by another uid if its PARENT is writable by that uid, and if $CELL_HOME itself is
  # writable by another user then the cell's whole HOME — auth.json, .ai-review-gate-key,
  # settings.json — is attacker-writable and nothing this layer installs is safe. That
  # precondition is the VM's (a single-tenant cell), and it is stated, not assumed. The same
  # bound applies one level down: a subdirectory of a root we own that is group/other-writable
  # is not detected either, and a second local uid could swap a shipped file inside it.
  local refused=""
  for cand in "${AGENT_INFRA_PATH:-}" "${HARNESS:+$HARNESS/..}" "$CELL_HOME/agent-infra"; do
    [ -n "$cand" ] || continue
    if is_infra_checkout "$cand"; then
      if [ -O "$cand" ]; then
        (cd "$cand" && pwd)
        return 0
      fi
      refused="$refused $cand"
    fi
  done
  if [ -n "$refused" ]; then
    # STDERR, not `say`: the only caller assigns this function's STDOUT to a variable
    # (`INFRA_ROOT="$(resolve_infra_root)"`), so a diagnostic printed on stdout is captured
    # into that variable and never reaches the operator — dead code that also poisons the
    # value. Nothing but the resolved path may go to stdout here.
    printf '  refused (a checkout-shaped tree NOT owned by %s):%s — pass INFRA_ROOT=<checkout> to use one deliberately\n' "$(id -un)" "$refused" >&2
  fi
  return 1
}

# ── the declared farm set, read out of setup.sh (ONE declaration) ────────────
# Prints `srcrel<TAB>destrel<TAB>base` rows. Fails loudly (non-zero) when setup.sh
# declares a farm array this script has no layout for — the alternative is silently
# installing a partial layer.
read_farm_set() {
  python3 - "$INFRA_ROOT/pi-bootstrap/setup.sh" "$FARM_LAYOUT" <<'PY'
import os
import re
import sys

setup_path, layout = sys.argv[1], sys.argv[2]
layout_map = {}
for row in layout.splitlines():
    row = row.strip()
    if not row:
        continue
    name, src, dest = row.split("\t")
    layout_map[name] = (src, dest)

try:
    src = open(setup_path).read()
except OSError as exc:
    sys.exit("FATAL: cannot read %s (%s)" % (setup_path, exc))

# Every top-level `name=(...)` array in setup.sh. Continuations are joined because the
# regex spans newlines (DOTALL) and a backslash continuation is dropped as a token below.
arrays = {}
for m in re.finditer(r'^([A-Za-z_][A-Za-z0-9_]*)=\((.*?)\)\s*$', src, re.M | re.S):
    arrays[m.group(1)] = re.findall(r'[^\s\\]+', m.group(2))

if not arrays:
    sys.exit(
        "FATAL: no farm arrays found in %s — setup.sh's shape changed, so this parse would "
        "install an EMPTY layer and still verify clean" % setup_path
    )

unknown = sorted(n for n in arrays if n not in layout_map)
if unknown:
    sys.exit(
        "FATAL: pi-bootstrap/setup.sh declares farm array(s) this installer does not know: "
        + ", ".join(unknown)
        + "\n       A farm added to setup.sh must be added to FARM_LAYOUT in cell-install.sh"
        + "\n       (<name><TAB><source-root><TAB><destination>), or a cell silently gets a PARTIAL layer."
    )

for name in sorted(arrays):
    src_root, dest_root = layout_map[name]
    for base in arrays[name]:
        if not base:
            continue
        print("\t".join((src_root, dest_root, base)))

# The checkout-hygiene farm is a directory glob, not an array: setup.sh iterates
# `$scripts_dir/*` and skips *.plist and *.test.*. Same rule, same destination.
m = re.search(r'^scripts_dir="\$INFRA_ROOT/([^"]+)"', src, re.M)
if not m:
    sys.exit("FATAL: setup.sh no longer declares scripts_dir=$INFRA_ROOT/... — the checkout-hygiene farm cannot be located")
hyg_rel = m.group(1)
hyg_dir = os.path.normpath(os.path.join(os.path.dirname(setup_path), "..", hyg_rel))
if not os.path.isdir(hyg_dir):
    sys.exit("FATAL: %s is not a directory — the checkout-hygiene farm is missing" % hyg_dir)
hyg_rows = 0
for base in sorted(os.listdir(hyg_dir)):
    if base.endswith(".plist") or ".test." in base:
        continue
    if os.path.isfile(os.path.join(hyg_dir, base)):
        print("\t".join((hyg_rel, "scripts/checkout-hygiene", base)))
        hyg_rows += 1
if hyg_rows == 0:
    # A PRESENT but EMPTY farm directory delivers less than the leg declares, and MIN_FARM_FILES
    # is satisfied by the other farms — so this would install an empty leg and certify it
    # (a false PASS). setup.sh refuses the same shape; the two must agree.
    sys.exit(
        "FATAL: %s holds no farmable file — the checkout-hygiene farm would install as EMPTY, "
        "so this checkout is incomplete (nothing was installed)" % hyg_dir
    )
PY
}

# ── the extension ship-list, read out of manifest.json (ONE declaration) ─────
read_manifest_entries() {
  python3 - "$INFRA_ROOT/manifest.json" <<'PY'
import json
import sys

# The key carries a trailing slash ("extensions/"), and this read mirrors the canonical
# one in scripts/check-pi-config-extensions.sh check 4 — the gate that keeps this list in
# exact parity with the extensions/ tree. A divergence between the two reads would be a
# second, silently-different ship-list.
try:
    manifest = json.load(open(sys.argv[1]))
except (OSError, ValueError) as exc:
    sys.exit("FATAL: cannot read %s as JSON (%s)" % (sys.argv[1], exc))
entries = ((manifest.get("files") or {}).get("extensions/") or {}).get("entries")
if not isinstance(entries, list) or not entries:
    sys.exit("FATAL: %s has no files.extensions/.entries list — the consumer ship-list cannot be read" % sys.argv[1])
for entry in entries:
    print(entry.rstrip("/"))
PY
}

# install_file <src> <dest> — real copy via a sibling temp + rename, so a concurrent
# reader (record-review.sh can run during a merge while this installs) never sees a
# truncated file.
install_file() {
  local src="$1" dest="$2"
  mkdir -p "$(dirname "$dest")" || return 1
  rm -f "$dest.tmp.$$"
  cp -f "$src" "$dest.tmp.$$" \
    && chmod +x "$dest.tmp.$$" 2>/dev/null \
    && mv -f "$dest.tmp.$$" "$dest" \
    && return 0
  rm -f "$dest.tmp.$$"
  return 1
}

# ── 1. farmed scripts ────────────────────────────────────────────────────────
install_farms() {
  local rows src_rel dest_rel base src dst n=0
  rows="$(read_farm_set)" || die "the declared farm set could not be read from setup.sh (see above)"
  while IFS=$'\t' read -r src_rel dest_rel base; do
    [ -n "${base:-}" ] || continue
    src="$INFRA_ROOT/$src_rel/$base"
    dst="$DEST/$dest_rel/$base"
    if [ ! -f "$src" ]; then
      die "declared farm file $src is MISSING from the checkout — refusing to install a partial layer"
    fi
    if [ -L "$dst" ]; then rm -f "$dst"; fi   # never install through a stale/foreign link
    install_file "$src" "$dst" || die "could not install $dst"
    n=$((n + 1))
  done <<<"$rows"
  if [ "$n" -lt "$MIN_FARM_FILES" ]; then
    die "the declared farm set parsed to only $n file(s) (floor: $MIN_FARM_FILES) — setup.sh's shape changed and this parse would install a PARTIAL layer, then verify clean against its own truncated reading. Nothing was certified."
  fi
  log_line "scripts farm: $n file(s) installed (declared by pi-bootstrap/setup.sh)"
  # Observability for the layer that decides whether a landing is evidence-bound (#984). `--verify`
  # is the authority (`guard_gh_shim`), but an INSTALL log should say out loud whether the cell now
  # carries an argv layer at all — install silence is how a cell ran degraded while looking green.
  if [ -x "$DEST/scripts/gh-shim/gh" ]; then
    log_line "argv-level gh shim: $DEST/scripts/gh-shim/gh (merge gate not degraded — #984)"
  else
    fail "the argv-level gh shim did not land at $DEST/scripts/gh-shim/gh — this cell's merge gate would run DEGRADED (#984)"
  fi
}

# ── 1b. the UNFARM leg (#1924) ───────────────────────────────────────────────
# Every copy leg above is COPY-ONLY: `cp`/`install_file` writes the names the farm
# DECLARES and does nothing at all to a name it does not declare. So a script that left
# the repo — or a name that left a farm array — keeps its deployed copy on the cell,
# executable, while the repo says it is retired. Nothing reported it: install-launchd's
# broken-target check only sees a plist whose target is MISSING, and
# check-deployed-drift.sh compares $O harness *.sh only.
#
# The retirement is DECLARED in pi-bootstrap/farm-retired.txt — never inferred from
# absence, because a cell whose checkout was incomplete would otherwise read as a
# retirement and lose scripts that are still shipped — and it is applied by the SAME
# code the laptop runs (pi-bootstrap/lib/farm-retire.sh). A laptop-only fix would leave
# every cell executing the retired artifact, which is precisely the divergence this leg
# closes.
#
# The retirement list and its implementation are read from $INFRA_ROOT — the checkout the
# LAYER is installed from, which is also where read_farm_set() reads the farm arrays — and
# never from $SELF_DIR. This script can be run against a different checkout
# (`INFRA_ROOT=<path>` exists for exactly that), and pairing one checkout's farm arrays
# with another checkout's retirement list would be a removal rule nobody wrote down.
load_farm_retire() {
  local lib="$INFRA_ROOT/pi-bootstrap/lib/farm-retire.sh"
  if [ ! -f "$lib" ]; then
    printf 'the farm UNFARM leg is missing from the checkout being installed (%s)\n' "$lib" >&2
    return 1
  fi
  # shellcheck source=lib/farm-retire.sh
  . "$lib"
}

# FARM_DECLARED_REL — the paths the farm DECLARES, relative to $DEST
# (`scripts/<name>` and the farm subdirectories), newline-separated. This is the set the
# retirement list is checked against: a name in BOTH is a contradiction (the copy leg
# re-creates it), not a removal. Same shape setup.sh records, so farm-retire.sh takes
# one kind of value from both callers.
FARM_DECLARED_REL=""
read_declared_farm_rel_paths() {   # $1 = rows, as emitted by read_farm_set
  local rows="$1" src_rel dest_rel base
  FARM_DECLARED_REL=""
  while IFS=$'\t' read -r src_rel dest_rel base; do
    [ -n "${base:-}" ] || continue
    case "$dest_rel" in
      scripts)   FARM_DECLARED_REL+="scripts/$base"$'\n' ;;
      scripts/*) FARM_DECLARED_REL+="$dest_rel/$base"$'\n' ;;
      # A farm destination OUTSIDE scripts/ cannot be expressed in the retirement list
      # (`scripts/…` only), so it must be a loud failure rather than a silently dropped
      # row: the contradiction guard would then pass vacuously and --verify would certify
      # a cell against a truncated declared set — the same silent-shrink class this file
      # already guards with MIN_FARM_FILES / MIN_SHIP_LIST and read_farm_set's unknown-array
      # refusal. There is no such farm today; this is the branch that keeps that true.
      *) printf 'FATAL: the farm declares %s under %s, which is not under scripts/ — the retirement check cannot cover it (add it to the retirement list format or move the farm)\n' \
                "$base" "$dest_rel" >&2
         return 1 ;;
    esac
  done <<<"$rows"
  # NO "parsed N of M" GUARD HERE, deliberately. The loop appends exactly one line per row
  # and returns 1 on the only row shape it cannot express (a destination outside scripts/),
  # so a count comparison would be computed twice from the same loop and could never fire —
  # an inert gate that reads as protection. Truncation of the DECLARED SET is caught where it
  # can be seen: install_farms/verify_layer's MIN_FARM_FILES floor on what is installed, and
  # the snapshot comparison below (a truncated declaration no longer equals the set the last
  # install recorded).
  return 0
}

install_unfarm() {
  local rows
  rows="$(read_farm_set)" || die "the declared farm set could not be read from setup.sh (see above)"
  load_farm_retire || die "the UNFARM leg cannot run — a retirement would not reach this cell, and certifying it anyway is the #1924 gap"
  read_declared_farm_rel_paths "$rows" \
    || die "the declared path set could not be built in full — refusing to run the retirement check against a truncated set"
  # The snapshot check catches the "dropped from a farm array without being declared"
  # direction, which no set comparison can see (the name is then in neither list).
  if ! farm_check_declared_shrink "$DEST" "$INFRA_ROOT/pi-bootstrap/farm-retired.txt" "$FARM_DECLARED_REL"; then
    die "the farm retirement check failed (see above). Two causes are possible and the remedies are OPPOSITE: (a) a name farmed by a previous install is now neither farmed nor retired — it would be ORPHANED on this cell, so declare it in pi-bootstrap/farm-retired.txt; or (b) this checkout is OLDER than the layer already installed here — then do NOT declare it, install from the newer checkout (declaring it would delete an artifact the repo still ships and wedge every later --install on the contradiction check); or (c) the retirement list could not be read"
  fi
  if ! farm_unfarm "$DEST" "$INFRA_ROOT/pi-bootstrap/farm-retired.txt" "$FARM_DECLARED_REL"; then
    die "the UNFARM leg failed (see above) — a retirement the farm cannot apply is NOT applied"
  fi
  farm_record_declared "$DEST" "$FARM_DECLARED_REL" \
    || die "could not record the farm declaration snapshot — the next install could not detect a name dropped from a farm array without being declared"
}

# ── 2. extensions ────────────────────────────────────────────────────────────
denied_extension() {
  local base="${1%/}" d
  for d in "${DENY_EXTENSIONS[@]}"; do
    # Normalised on BOTH sides: the manifest writes `foo/` and `read_manifest_entries` strips it,
    # while the sweeps below also accept either form. Without this, a deny entry written the way
    # the manifest spells it (`tortoise-capture/`) matches NOTHING here — the install half ships
    # the copy, the sweep then deletes it, and `verify_layer`'s content loop fails a CLEAN cell
    # with `extension MISSING` on every bring-up (fails closed, but bricks provisioning).
    [ "${d%/}" = "$base" ] && return 0
  done
  return 1
}

install_extensions() {
  local entries base src dst n=0 removed=0 total=0 adir f
  entries="$(read_manifest_entries)" || die "the extension ship-list could not be read from manifest.json (see above)"
  total="$(printf '%s\n' "$entries" | grep -c . || true)"
  if [ "$total" -lt "$MIN_SHIP_LIST" ]; then
    die "manifest.json's extension ship-list parsed to only $total entr(y|ies) (floor: $MIN_SHIP_LIST) — the ship-list key moved and this parse would install almost nothing"
  fi
  while IFS= read -r base; do
    [ -n "$base" ] || continue
    src="$INFRA_ROOT/extensions/$base"
    dst="$DEST/extensions/$base"
    denied_extension "$base" && continue   # enforced below, against the CELL and not the ship-list
    [ -e "$src" ] || die "manifest lists extensions/$base but it is absent from the checkout"
    if [ -L "$dst" ]; then rm -f "$dst"; fi   # a link into a checkout can dangle on a cell
    if [ -f "$src" ]; then
      install_file "$src" "$dst" || die "could not install $dst"
    else
      # `SRC/. DEST/` is the only cp form that does not NEST when DEST exists (#93).
      mkdir -p "$dst" && cp -R "$src/." "$dst/" || die "could not install $dst"
    fi
    n=$((n + 1))
  done <<<"$entries"
  # The deny is enforced against what is ON THE CELL, not only across the manifest rows — for the
  # same reason the verify half does it: if an entry is ever dropped from manifest.json, a
  # deny bound to the ship-list stops reaching it, and a copy left by a hand-push or by an older
  # checkout would survive every bringup. That is exactly the #2100 re-break with a quieter cause.
  # And it sweeps BY PATTERN across EVERY home the cell runs under (#2147): the exact-name form is
  # blind to a suffixed copy, and the one-home form is blind to the second home a cell keeps its
  # operating state in. Both were measured on live boxes (1 / 0 / 7 / 3 / 2 copies per cell).
  while IFS= read -r adir; do
    [ -n "$adir" ] || continue
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      # Never remove outside the directory we just enumerated: a glob that escaped would otherwise
      # turn a deny sweep into a delete.
      case "$f" in "$adir"/*) ;; *) die "refusing to remove $f — it is not under the scanned home $adir" ;; esac
      # An unchecked `rm -rf` would log "removed" over a survivor. `verify_layer` runs at the end of
      # `--install` and would still refuse the cell, so this is not a false PASS — but a log that
      # contradicts itself two lines later is exactly what sends an operator down the wrong path.
      rm -rf -- "$f" || die "could not remove the denied extension at $f — the cell would keep running it"
      log_line "removed denied extension: $(basename "$f") ($(denied_extension_note "$(basename "$f")")) — $f"
      removed=$((removed + 1))
    done <<EOF
$(denied_extension_copies "$adir")
EOF
  done <<EOF
$(cell_agent_dirs)
EOF
  log_line "extensions: $n installed from manifest.json (ship-list: $total), $((${#DENY_EXTENSIONS[@]})) denied on a cell, $removed removed"
}

# Extension runtime dependencies. Four shipped extensions import bare packages
# (builtin-tools/typebox, mcp-client/@modelcontextprotocol/sdk+typebox,
# loop-enforcer/@sinclair/typebox, custom-provider-qwen/undici) resolved from THEIR OWN
# node_modules — pi's loader does not provide them. Without this step the cell gets the
# files and none of the tools: `builtin-tools` IS the `task` dispatcher a lane uses.
#
# The npm child runs with a SCRUBBED environment, an explicit proxy/registry allowlist, and
# package scripts disabled, and the loop uses the SAME predicate as verify_layer (a non-empty
# `dependencies`). All three are load-bearing:
#   * bring-up sources the cell's keys.env (`set -a; . keys.env; set +a`) BEFORE calling this
#     installer, so every secret in it — the provider keys AND AI_REVIEW_GATE_KEY, the merge
#     authority `ai-review-gate` verifies — is in this process's environment. `npm install`
#     runs each dependency's lifecycle scripts with that environment inherited, and these
#     extensions resolve floating ranges, so a compromised published version or any
#     transitive dep could read the merge key and mint review markers for arbitrary code.
#     --ignore-scripts is the control that blocks the READ; `env -i` removes the environment
#     COPY, which is defence in depth, not the control — the key is ALSO on disk at
#     $HOME/.pi/agent/.ai-review-gate-key (written there by the OPERATOR, or pushed in
#     keys.env; pi itself does not write it), with auth.json alongside it. Do not delete
#     either flag believing the other covers it.
#   * the allowlist keeps a cell behind a mirror or an HTTP proxy able to install at all: the
#     previous invocation inherited the operator's npm configuration from keys.env, and
#     `env -i` would otherwise drop it.
#   * the predicate mismatch made install announce `deps installed: X` for extensions npm
#     installed nothing for, and sent 5 needless network round-trips.
install_extension_deps() {
  local d base npm_home v
  local npm_env=()
  command -v npm >/dev/null 2>&1 \
    || die "npm is missing: the shipped extensions that declare runtime deps cannot load without it (builtin-tools alone is the 'task' dispatcher)"
  for v in HTTP_PROXY HTTPS_PROXY http_proxy https_proxy NO_PROXY no_proxy \
           npm_config_registry NPM_CONFIG_REGISTRY npm_config_cafile npm_config_strict_ssl; do
    [ -n "${!v:-}" ] && npm_env+=("$v=${!v}")
  done
  npm_home="$(mktemp -d "${TMPDIR:-/tmp}/cell-install-npm-home.XXXXXX")" || die "cannot create an npm HOME"
  for d in "$DEST"/extensions/*/; do
    [ -f "$d/package.json" ] || continue
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get("dependencies") else 1)' \
      "$d/package.json" 2>/dev/null || continue
    base="$(basename "$d")"
    if (cd "$d" && env -i PATH="$PATH" HOME="$npm_home" TMPDIR="${TMPDIR:-/tmp}" \
          ${npm_env[@]+"${npm_env[@]}"} \
          npm install --omit=dev --ignore-scripts --no-audit --no-fund >/dev/null 2>&1); then
      log_line "deps installed: $base"
    else
      fail "npm install failed for $base — that extension will not load (re-run with network, or: cd '$d' && npm install --omit=dev)"
    fi
  done
  rm -rf "$npm_home"
}

# ── 3. skills + config ───────────────────────────────────────────────────────
install_skills() {
  [ -d "$INFRA_ROOT/skills" ] || die "no skills/ directory in $INFRA_ROOT"
  mkdir -p "$DEST/skills" && cp -R "$INFRA_ROOT/skills/." "$DEST/skills/" \
    || die "could not install skills"
  log_line "skills: $(find "$DEST/skills" -name SKILL.md 2>/dev/null | wc -l | tr -d ' ') SKILL.md file(s) installed"
}

# copy_repo_path <rel> — install a repo file or directory at its basename under $DEST.
copy_repo_path() {
  local rel="$1" src="$INFRA_ROOT/$1" dst="$DEST/$(basename "$1")"
  [ -e "$src" ] || return 1
  if [ -L "$dst" ]; then rm -f "$dst"; fi
  if [ -f "$src" ]; then
    install_file "$src" "$dst"
  else
    mkdir -p "$dst" && cp -R "$src/." "$dst/"
  fi
}

# ⛔ THE BASH SIDE OF THE SAME CONSTANT, FOR THE ONE CALLER THAT CANNOT SEE THE MARKER'S PYTHON
# (#3374 review, round 12 P3). Bash and the marker's python are two languages in one file, so
# `$HOSTED_DEFAULT_URL` — a PYTHON name — is unbound in the shell (`set -u` then aborts the whole
# install). MUST MATCH the marker's `HOSTED_DEFAULT_URL` above and `merge-mcp.py`'s; the pin arm in
# pi-bootstrap/tests/test-cell-install.sh checks EVERY assignment in all of those files against the
# SHIPPED template, so this spelling cannot drift from the endpoint it names.
GRAPH_HOSTED_DEFAULT_URL="https://api.premiselabs.co/mcp/"


# merge_tortoise_is_hosted <merged .mcp.json> <template .mcp.base.json> <hosted-default-url>
#   True only when the file that was JUST WRITTEN points its `tortoise` entry at the HOSTED endpoint
#   and does not carry the `_selfHosted` marker. The merge may legitimately keep a machine's own url,
#   so this is what the install summary line reports — the ARTIFACT, never the intent of having run a
#   merge. A file that cannot be read is NOT the hosted default: the caller's other line is the honest
#   one, and the verifier refuses such a cell by name.
#   ⛔ THE THIRD ARGUMENT IS WHY THE SENTENCE CAN BE TRUE (#3374 review, round 12 P3). The predicate
#   compared the written file against the TEMPLATE's url, so with a self-hosting template a cell that
#   correctly matched its own `localhost` daemon satisfied it and the summary printed "hosted tortoise
#   entry installed" over an entry pointing at localhost — the same "a sentence that calls a LAN
#   address 'the hosted host'" defect round 11 fixed one file over. `merge-mcp.py` asks this question
#   against `HOSTED_DEFAULT_URL`, never the template, and so does this now; a non-hosted endpoint
#   falls to the caller's "NOT the hosted default" line, which is the true one.
merge_tortoise_is_hosted() {
  python3 - "$1" "$2" "$3" <<'MCPHOSTED' >/dev/null 2>&1
import json, re, sys
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        have = (json.load(fh).get("mcpServers") or {}).get("tortoise") or {}
    with open(sys.argv[2], encoding="utf-8") as fh:
        want = (json.load(fh).get("mcpServers") or {}).get("tortoise") or {}
except Exception:
    sys.exit(1)
if not isinstance(have, dict) or not isinstance(want, dict):
    sys.exit(1)

def key(u):
    # MUST MATCH `_endpoint_key` above — a default port is not part of an endpoint's identity.
    s = (u or "").strip()
    m = re.match(r"^([a-z][a-z0-9+.\-]*)://(?:[^/?#]*@)?(\[[^\]]*\]|[^/?#:]*)(?::(\d*))?", s, re.I)
    if not m:
        return s
    scheme, host, port = m.group(1).lower(), m.group(2).lower(), m.group(3)
    # ⛔ A TRAILING ROOT DOT IS THE SAME DNS NAME (#3374 review, round 13 P1 — MUST MATCH
    # `_endpoint_key` above and `merge-mcp.py`). `api.premiselabs.co.` IS the hosted host, so this
    # key must not separate it from the canonical spelling; without it, `merge_tortoise_is_hosted`
    # would report a correctly-installed hosted cell as "NOT the hosted default".
    if host.endswith("."):
        host = host[:-1]
    # ⛔ USERINFO FORCES THE KEY TO DIFFER — never let a spoof url key to the hosted endpoint by
    # DROPPING it (MUST MATCH `merge-mcp.py`). Otherwise `https://user:pw@api.premiselabs.co/mcp/`
    # takes the hosted path and skips the arm that refuses userinfo outright.
    authority = s.split("://", 1)[1].split("/", 1)[0].split("?", 1)[0].split("#", 1)[0]
    prefix = "userinfo@" if "@" in authority else ""
    # ⛔ A LEADING ZERO IS NOT A DIFFERENT PORT — `:0443` IS `:443` (MUST MATCH `merge-mcp.py`,
    # which carries the full rationale and the measurement: the client's own parser normalises all
    # three spellings to the canonical hosted url). Without this a leading-zero default port took
    # the self-host exemption and was certified without any credential check.
    if port:
        port = port.lstrip("0") or "0"
    if port == "" or (port is not None and ((scheme == "https" and port == "443")
                                            or (scheme == "http" and port == "80"))):
        port = None
    return "%s%s://%s%s%s" % (prefix, scheme, host, (":" + port) if port else "", s[m.end():])

def akey(u):
    # MUST MATCH `_authority_key` above — "is the template the hosted endpoint?" is an AUTHORITY
    # question (#3374 review, round 12 P1). A template spelled `/mcp` without the trailing slash IS
    # the hosted default, and the merge now writes that default, so a byte key here reported the
    # truth backwards: a correctly-installed hosted cell was summarised as "NOT the hosted default".
    k = key(u)
    m = re.match(r"^((?:userinfo@)?[a-z][a-z0-9+.\-]*://[^/?#]*)", k, re.I)
    return m.group(1) if m else k

sys.exit(
    0
    if key(have.get("url")) == key(sys.argv[3])
    and akey(want.get("url")) == akey(sys.argv[3])
    and not have.get("_selfHosted")
    else 1
)
MCPHOSTED
}

install_config() {
  local rel cfg_fail=0
  # settings.json is the SIXTH config source, and it is checked FIRST so that the step's
  # success line below cannot print after its failure. (It used to be checked after the
  # `say`, which is how `--install` could record "settings.json is MISSING" and then print
  # "small config files installed" in the same breath.)
  local src="$INFRA_ROOT/pi-bootstrap/pi-config/settings.json"
  if [ ! -f "$src" ]; then
    fail "pi-bootstrap/pi-config/settings.json is MISSING from $INFRA_ROOT — the cell would keep whatever settings it already had"
    cfg_fail=1
  fi
  for rel in pi-bootstrap/pi-config/agents \
             pi-bootstrap/pi-config/behavior-control \
             pi-bootstrap/pi-config/coding-rules.md \
             pi-bootstrap/pi-config/response-rules-reminder.md \
             pi-bootstrap/pi-config/skills-repos.yaml; do
    # An absent source is a FAILURE, not a skip. `copy_repo_path` used to return 0 here, so
    # a checkout missing (say) pi-config/agents installed nothing, printed success, and then
    # verified clean — a cell with no sub-agent definitions at all, which is the exact
    # partial-layer-reports-success case this script exists to remove.
    if [ ! -e "$INFRA_ROOT/$rel" ]; then
      fail "declared config path $rel is MISSING from $INFRA_ROOT — the cell would get no agents/behavior-control (pi resolves user-scope sub-agents from ~/.pi/agent/agents)"
      cfg_fail=1
      continue
    fi
    # A copy that FAILS must be COUNTED: `copy_repo_path` returns non-zero when the destination
    # cannot take what the checkout has (a file where the source is a directory, say), and the
    # read-back below is what a lane actually gets vouched for — a copy that failed and was not
    # counted would leave this path reporting success.
    copy_repo_path "$rel" || { fail "could not install $rel (a dest that is not the same shape as the source?)"; cfg_fail=1; }
  done
  # The step's own narrative may not contradict its FAIL line: an unconditional `say` here
  # used to print 'installed' straight after a recorded failure.
  [ "$cfg_fail" -eq 0 ] && log_line "agents + behavior-control + small config files installed" || true

  # settings.json — MERGED, never clobbered (same contract as setup.sh: source wins per
  # key, local extras survive, `retry` deep-merged per key so a local
  # `retry.enabled: false` kill switch cannot be reset by a re-run). The source's existence
  # was checked (and recorded) at the top of this function.
  if [ -f "$src" ]; then
    if command -v python3 >/dev/null 2>&1; then
      python3 - "$src" "$DEST/settings.json" <<'PY' || fail "settings.json merge failed"
import json
import os
import sys

src = json.load(open(sys.argv[1]))
dst = json.load(open(sys.argv[2])) if os.path.exists(sys.argv[2]) else {}
merged = {**dst, **src}
if isinstance(src.get("retry"), dict) and isinstance(dst.get("retry"), dict):
    retry = {**dst["retry"], **src["retry"]}
    if isinstance(src["retry"].get("provider"), dict) and isinstance(dst["retry"].get("provider"), dict):
        retry["provider"] = {**dst["retry"]["provider"], **src["retry"]["provider"]}
    merged["retry"] = retry
json.dump(merged, open(sys.argv[2], "w"), indent=2)
PY
      log_line "settings.json merged (local extras preserved)"
    elif [ -f "$DEST/settings.json" ]; then
      fail "python3 is missing and settings.json already exists — refusing to clobber it; merge by hand or install python3"
    else
      install_file "$src" "$DEST/settings.json" || fail "could not install settings.json"
      log_line "settings.json copied (python3 not found — plain copy)"
    fi
  fi

  # .mcp.json — the HOSTED graph entry, plus whatever server the cell already declared
  # (graph-mcp-provision). The merge RULES live in ONE place, `pi-bootstrap/lib/merge-mcp.py`,
  # shared with setup.sh: the two callers merging inline is how they drift, and this exact drift
  # (both source-wins) is what silently repointed a self-hosted tortoise url on every re-sync.
  # In a cell's case that script installs the graph server ONLY — the template's other base
  # servers cannot spawn here: `seo-intelligence` needs mcp-servers/…/node_modules (a cell ships
  # extensions/ only), brave/gemini need keys, playwright pulls an npx package onto a
  # memory-constrained box. A catalog that advertises an unspawnable tool is worse than a short one.
  local mcp_src="$INFRA_ROOT/templates/.mcp.base.json"
  local mcp_lib="$INFRA_ROOT/pi-bootstrap/lib/merge-mcp.py"
  if [ ! -f "$mcp_src" ]; then
    fail "templates/.mcp.base.json is MISSING from $INFRA_ROOT — the cell would keep ZERO MCP servers (every lane then writes GRAPH-UNREACHABLE instead of reading the graph)"
  elif [ ! -f "$mcp_lib" ]; then
    fail "pi-bootstrap/lib/merge-mcp.py is MISSING from $INFRA_ROOT — refusing to merge .mcp.json with a second, private implementation"
  elif ! command -v python3 >/dev/null 2>&1; then
    fail "python3 is missing — refusing to write .mcp.json by plain copy (it would drop a cell-local server); install python3 or merge by hand"
  else
    # NOTE: lines are surfaced verbatim — a preserved self-hosted url, a replaced unusable entry,
    # and the servers deliberately not installed here must be visible, not inferred. The merge's
    # exit status is captured FIRST: a `while read < <(...)` loop cannot report it, so a failing
    # merge would print its error as a note and then log success.
    mcp_out=""
    mcp_rc=0
    mcp_out="$(python3 "$mcp_lib" "$mcp_src" "$DEST/.mcp.json" --cell 2>&1)" || mcp_rc=$?
    printf '%s\n' "$mcp_out" | while IFS= read -r note; do [ -n "$note" ] && log_line ".mcp.json $note"; done
    if [ "$mcp_rc" -ne 0 ]; then
      fail ".mcp.json merge failed (merge-mcp.py rc=$mcp_rc) — the cell would keep whatever config it already had"
    else
      # ⛔ THE SUMMARY LINE DESCRIBES THE FILE, NOT THE INTENT (#3374 review P2). The merge may
      # legitimately KEEP this machine's own tortoise url — it prints a NOTE saying so — and on
      # rc=0 alone this line then told the operator the HOSTED entry was installed, the opposite of
      # what the artifact says. Reading the merged file back is the same discipline the layer
      # verification below uses: a claim about an artifact is checked against the artifact.
      if merge_tortoise_is_hosted "$DEST/.mcp.json" "$mcp_src" "$GRAPH_HOSTED_DEFAULT_URL"; then
        log_line ".mcp.json: hosted tortoise entry installed (cell-local servers preserved)"
      else
        log_line ".mcp.json: merged, but the tortoise entry is NOT the hosted default (see the NOTE above) — cell-local servers preserved"
      fi
    fi
  fi
  graph_credential_note

  # AGENTS.md — installed when ABSENT, never overwritten.
  local base_agents="$INFRA_ROOT/templates/AGENTS.base.md"
  if [ -f "$base_agents" ]; then
    if [ ! -e "$DEST/AGENTS.md" ]; then
      install_file "$base_agents" "$DEST/AGENTS.md" || fail "could not install AGENTS.md"
      log_line "AGENTS.md installed from templates/AGENTS.base.md"
    elif ! cmp -s "$base_agents" "$DEST/AGENTS.md"; then
      log_line "AGENTS.md already present and DIFFERS from templates/AGENTS.base.md — left alone (a global rules file is hand-edited state). Reconcile by hand."
    else
      log_line "AGENTS.md already matches templates/AGENTS.base.md"
    fi
  else
    fail "templates/AGENTS.base.md is missing from $INFRA_ROOT — a cell would get no global rules"
  fi
}

# ── 4. the ~/.pi/agent/tools/ constraint (#1277) ─────────────────────────────
# Migration (INSTALL only — `--verify` writes nothing, so neither this nor the empty-dir
# cleanup below may be REACHED from it). The farm used to write here: pi's startup scan
# rejects ANY non-fd/rg entry and then blocks every interactive boot on an untimed keypress
# prompt — the fleet's entire dispatch path.
migrate_legacy_tools_farm() {
  if [ -d "$DEST/tools/fleet" ]; then
    rm -rf "$DEST/tools/fleet"
    log_line "migrated the legacy tools/fleet/ out of pi's boot-blocking namespace (#1277)"
  fi
  # A tools/ left empty by the removal above is not a boot-blocker (pi's scan ignores an
  # empty dir) but it is noise, and setup.sh removes it too — same surface, same output.
  if [ -d "$DEST/tools" ] && [ -z "$(ls -A "$DEST/tools" 2>/dev/null)" ]; then
    rmdir "$DEST/tools" 2>/dev/null || true
  fi
}

# ── the pi spawn-point gate (#1884) ───────────────────────────────────────────
# Installed as `$DEST/bin/pi`, because the gate must be where `pi` is BORN rather than where a caller
# remembers to source it: `spawn-gate.sh` is ALSO an executable whose invoked identity is the gate
# (see "THE SPAWN POINT" in that file), and it is installed under the name a caller types. PATH on a
# cell begins with `$CELL_HOME/.pi/agent/bin`, so every `pi` a cell starts — lane.sh, fix-one.sh,
# merge-one.sh, a hand-written runner, an interactive session — resolves here.
# WHY THIS IS SPECIFICALLY A CELL PROBLEM (the measured incident): a cell controller started three
# lanes from a hand-written runner (`tmux new-session -d -s <name> "… pi -p …"`), which never sources
# spawn-gate.sh. The box was at load 258 on 10 cores against MAX_LOAD=100 and NOTHING refused,
# because nothing consulted the ceiling — no refusal, no log line, no count.
# ONE COPY from ONE source (the file the harness callers source), so the ceiling a caller applies and
# the ceiling the spawn point applies cannot drift. A real copy, not a symlink, for the #427 reason
# (cell HOME is under a world-writable /tmp, and a symlink into a checkout dangles when a worktree is
# reaped — a dangling `pi` on PATH breaks every lane on the box).
# ⛔ THE TWO PATHS ARE DERIVED INSIDE EACH FUNCTION, NOT AT TOP LEVEL. `$INFRA_ROOT` and `$DEST` are
# resolved by `main()` and the paths are unset before it (a copy of this script outside a checkout is
# one of the states under test: `set -u` would abort at load with "INFRA_ROOT: unbound variable"
# before the installer's own "no checkout" refusal could print — the exact false reason run 6 of
# pi-bootstrap/tests/test-cell-install.sh exists to catch).
install_spawn_gate() {
  local src="$INFRA_ROOT/scripts/orchestrator-harness/spawn-gate.sh" dst="$DEST/bin/pi"
  if [ ! -f "$src" ]; then
    die "$src is missing from the checkout — the pi spawn-point gate (#1884) cannot be installed, so a hand-written runner's \`pi\` would be ungated and silent"
  fi
  install_file "$src" "$dst" || die "could not install $dst"
  log_line "pi spawn-point gate installed at $dst (#1884)"
}

# Check (both modes; READ-ONLY). Byte-compared, not `[ -e ]`: a stale or hand-edited copy of a GATE
# is worse than a missing one, because the missing one is loud while the stale one certifies a
# ceiling it no longer applies.
guard_spawn_gate() {
  local src="$INFRA_ROOT/scripts/orchestrator-harness/spawn-gate.sh" dst="$DEST/bin/pi"
  if [ ! -f "$src" ]; then
    fail "$src is missing from the checkout — verify cannot vouch for the spawn-point gate it did not read"
    return 0
  fi
  if [ ! -f "$dst" ]; then
    fail "pi spawn-point gate MISSING: $dst — every \`pi\` started by a caller that does not source spawn-gate.sh (a hand-written runner, a tmux one-liner) would be UNGATED AND SILENT, which is #1884"
  elif ! cmp -s "$src" "$dst"; then
    fail "pi spawn-point gate DIFFERS from the checkout: $dst (a stale or hand-edited copy — the ceiling it applies is not the one this install reviewed)"
  elif [ ! -x "$dst" ]; then
    fail "pi spawn-point gate is NOT EXECUTABLE: $dst — PATH would resolve past it to the real pi, silently"
  fi
}

# ── the argv-level `gh` shim (#984) — the merge gate's SECOND layer ─────────────
# The review-enforcer answers "will this command text make gh perform an admin merge?" from
# STRING rules, and that class is not closable in a scanner: resolving `$VAR`/`$(…)` requires
# EVALUATING a shell, which a gate cannot do without running the command it exists to refuse. So
# the extension prepends `EXTENSION_DIR/../../scripts/gh-shim` to PATH on every bash call and
# lets the shim decide from its OWN argv, where the shell has already finished (the scanner stays
# as the fast first layer and produces the better messages; the shim is the layer that does not
# share its ceiling).
#
# ⛔ THE TWO PLATFORMS DIFFER ONLY IN WHAT THAT EXPRESSION RESOLVES TO, and the difference is
# invisible in code: on a laptop the extensions are kept as farm SYMLINKS into the checkout, so
# `../..` IS the checkout and the shim is found without ever being installed; on a CELL they are
# real COPIES, so `../..` is `$DEST` and the shim must exist at `$DEST/scripts/gh-shim/gh`.
# Nothing farmed that directory, so every cell lane logged
#   `#984 argv-level gh shim not found — only the string scanner is active`
# and the merge gate ran DEGRADED — no argv inspection at all — while `--verify` printed LAYER
# VERIFIED. The gate that must certify a landing could not do its job on the boxes doing the work.
#
# ⛔ RESOLVED THE WAY THE EXTENSION RESOLVES IT, not written as `$DEST/scripts/gh-shim`: the
# WIRING is the claim. If the installer ever puts extensions somewhere else, this must fail LOUDLY
# instead of certifying a shim the extension will never look at.
# ⛔ `AGENT_GH_SHIM_DIR` IS A **PREFERENCE**, NOT AN OVERRIDE, AND IT GOVERNS **ONE HALF ONLY**.
# The two halves are verified SEPARATELY because they fail in OPPOSITE directions:
#   (1) THE INSTALLED COPY, `EXTENSION_DIR/../../scripts/gh-shim/gh`, is required on its own, whether
#       or not a preference is exported. It is the gate a lane started WITHOUT the variable runs, so
#       a cell that lacks it — or holds it NON-EXECUTABLE, where bash SKIPS the PATH entry and the
#       real gh runs with nothing on any stream — is DEGRADED no matter what the operator's shell
#       exports. Letting the candidate loop decide this was a FALSE PASS: a valid preference made
#       `--verify` print LAYER VERIFIED over a 644 installed shim, certifying exactly the silent
#       fail-open the shim exists to prevent.
#   (2) THE VERIFIER SIBLING belongs to whichever candidate WINS — mirror `resolveGhShimDir()`'s
#       candidate list and order literally: `[AGENT_GH_SHIM_DIR, installed]`, first one holding an
#       EXECUTABLE `gh`. An unusable override FALLS BACK there (pinned by
#       extensions/review-enforcer/index.test.ts for a nonexistent AND a non-executable override),
#       so verifying only the named directory would FAIL a cell whose gate the extension is
#       enforcing correctly — and because `--install` ends by verifying, that false block would make
#       `cloud-cell-bringup.sh --check` die on a healthy box and prescribe `--install` as the remedy
#       for a failure `--install` just produced. The shim that RUNS is the one whose
#       `../verify-admin-merge-evidence.sh` matters.
# ⛔ THE SIBLING IS FOUND BY FOLLOWING THE LINK, PHYSICALLY — NOT BY A LEXICAL `$dir/../`. The
# normal state is `~/.pi/agent/shims/gh` as a SYMLINK into the farmed shim (the harness injects
# that neutral entry), and `scripts/gh-shim/gh` resolves its own directory by walking its links
# for exactly this reason. A lexical join looked for `$DEST/verify-admin-merge-evidence.sh`, which
# nothing installs, so a HEALTHY cell was REFUSED and the prescribed `--install` could never
# repair it. THE SAME DEFECT HAS A SECOND FACE: a symlinked CANDIDATE DIRECTORY
# (`AGENT_GH_SHIM_DIR=$TMP/ghshim` with `$TMP/ghshim -> $DEST/scripts/gh-shim`). Walking only the
# FINAL component does not help there, because bash's `cd` is LOGICAL: `cd -- $link/..` strips a
# component of the LEXICAL path, so the guard tested `<the link's lexical parent>/verify-…`, which
# nothing installs either — and refused a healthy cell whose shim resolves that sibling fine (the
# kernel's stat follows the link). Every `..` below is therefore taken PHYSICALLY (`cd -P`/`pwd -P`),
# so the path TESTED is the path the KERNEL resolves.
# ⛔ EXECUTE BIT: required on the SHIM (see (1)), but NOT on the verifier: the shim invokes it as
# `bash "$VERIFY"`, so `-x` there would be a false block. It must merely be PRESENT and non-empty
# — the shim fails CLOSED when it cannot find it, which refuses every admin merge on the cell
# rather than certifying one.
# Resolve a path's FINAL component through any symlinks, as `scripts/gh-shim/gh` does for itself
# (`while [ -L … ]`, portable — no `readlink -f`, which BSD/macOS readlink lacks), and resolve each
# hop's DIRECTORY PHYSICALLY (`cd -P`). Only the last component is walked here, which is the shape
# this guard meets: the harness injects `~/.pi/agent/shims/gh` as a LINK to the farmed shim, and
# the shim itself walks its own chain — while a DIRECTORY that is a link is handled by the caller's
# physical `..` (walking the final component cannot see it, and must not: it would move the path).
# ⛔ THE WALK IS BOUNDED. `[ -L ]` on a link CYCLE is TRUE FOREVER (a self-link never stops being a
# symlink), so an unbounded walk HANGS the caller instead of failing it — and `--install` ends by
# verifying, so the hang would land on `cloud-cell-bringup.sh --check`. Over the bound the function
# prints NOTHING and returns 1, and the caller REFUSES: it never hands back a path it did not
# resolve, because a guessed path can name a real `../verify-…` and thereby certify a shim that
# cannot be executed at all.
# (Same treatment for a hop whose directory or link cannot be read: unresolvable ⇒ return 1.)
GH_SHIM_MAX_LINK_HOPS=40
gh_shim_realpath() {
  local p="$1" d hops=0 max="${GH_SHIM_MAX_LINK_HOPS:-40}"
  # ⛔ THE BOUND MUST BE A NUMBER BEFORE IT IS USED. `[ N -gt abc ]` is an ERROR (rc 2), not a
  # false, so `&& return 1` NEVER FIRES and the loop goes on to resolve the next hop — with a
  # self-referential link that is an infinite walk, i.e. exactly the hang this bound exists to
  # prevent, reached through the bound itself. (MEASURED with this guard removed: a self-link
  # under a non-numeric bound was still spinning at 10s and printing `integer expression
  # expected`.) The fallback is the same 40 the script-level constant holds, so a caller that
  # sources this function with a corrupted value still gets a bounded resolver.
  case "$max" in ''|*[!0-9]*) max=40 ;; esac
  while [ -L "$p" ]; do
    hops=$((hops + 1))
    [ "$hops" -gt "$max" ] && return 1
    d="$(CDPATH= cd -P -- "$(dirname "$p")" 2>/dev/null && pwd -P)" || return 1
    p="$(readlink "$p")" || return 1
    case "$p" in /*) ;; *) p="$d/$p" ;; esac
  done
  printf '%s' "$p"
}

# The directory `review-enforcer` puts on PATH: `${EXTENSION_DIR}/../../scripts/gh-shim`.
# ⛔ THE EXTENSION'S `EXTENSION_DIR` IS A **REALPATH**. It is `dirname(fileURLToPath(import.meta.url))`
# — node resolves a symlinked module to its target before `import.meta.url` exists — so the SAME
# expression names two DIFFERENT directories by platform: on a cloud cell the extensions are real
# COPIES and it is `$DEST`; on a laptop setup.sh deliberately keeps them as farm SYMLINKS into the
# checkout, and it is `<checkout>`. A guard that normalises the LEXICAL `$DEST/extensions/review-
# enforcer/../../scripts/gh-shim` (a plain `cd && pwd` does: it strips `..` by string, never by
# inode) therefore certifies `$DEST/scripts/gh-shim` on BOTH platforms — which on the symlink
# platform is not the directory the gate reads: it is (a) a false PASS, where deleting the
# CHECKOUT's shim leaves `LAYER VERIFIED` while every lane logs `#984 … not found`, the exact
# defect this check exists to close, or the farmed copy can be deleted and the guard still refuses;
# and (b) a false BLOCK, naming a path the extension never looks at, on a healthy symlink platform.
# Taking the EXTENSION DIRECTORY physically first is what makes `../../scripts/gh-shim` on its
# result the REALPATH form on both platforms — the path the kernel would resolve for the module.
# The `dirname` pair (rather than a literal `..`) only removes the `..` from the message: on an
# already-physical path the two forms name the same directory.
gh_shim_extension_dir() {
  local ext
  ext="$(CDPATH= cd -P -- "$DEST/extensions/review-enforcer" 2>/dev/null && pwd -P)"
  if [ -n "$ext" ]; then
    printf '%s' "$(dirname "$(dirname "$ext")")/scripts/gh-shim"
  else
    # No extension on the cell at all — the MISSING-extension guard reports that separately. Name
    # the path it WOULD have resolved, with the `../..` form, so the message stays actionable.
    printf '%s' "$DEST/extensions/review-enforcer/../../scripts/gh-shim"
  fi
}

guard_gh_shim() {
  local override="${AGENT_GH_SHIM_DIR:-}" installed norm cand chosen="" verifier real
  installed="$(gh_shim_extension_dir)"
  # Normalised PHYSICALLY (`cd -P`, not `cd`): the extension directory was already taken
  # physically above, so this is a no-op for the normal case and the authority on any platform
  # where the physical form and the lexical form disagree. When the directory does not exist the
  # unnormalised form is kept — the missing-shim message has to name the path the extension would
  # have used.
  if norm="$(CDPATH= cd -P -- "$installed" 2>/dev/null && pwd -P)"; then installed="$norm"; fi
  # (1) the installer-owned copy, verified INDEPENDENTLY of the preference. The `also` clause says
  # out loud that a readable override does not stand in for it, so an operator whose fix is to
  # point AGENT_GH_SHIM_DIR somewhere sane is not left guessing why the cell is still refused.
  local also=""
  [ -n "$override" ] && also=" (AGENT_GH_SHIM_DIR=$override is a PREFERENCE and does not stand in for the installed copy, which is what this cell's lanes resolve)"
  if [ ! -f "$installed/gh" ]; then
    fail "the argv-level gh SHIM is MISSING: $installed/gh$also — the review-enforcer puts exactly that directory on PATH for every bash call and finds no executable \`gh\` in it, so this cell would run the merge gate DEGRADED (the string scanner only — the documented limit #984 exists to get past) while reporting itself ready. Re-run --install"
    return 0
  fi
  if [ ! -x "$installed/gh" ]; then
    fail "the argv-level gh SHIM is NOT EXECUTABLE: $installed/gh$also — bash SKIPS a non-executable PATH entry, so the real gh runs and the merge gate is DEGRADED with nothing on any stream (#984). Re-run --install"
    return 0
  fi
  # (2) whose verifier sibling has to exist: the same candidate list/order as `resolveGhShimDir()`.
  for cand in ${override:+"$override"} "$installed"; do
    if [ -f "$cand/gh" ] && [ -x "$cand/gh" ]; then chosen="$cand"; break; fi
  done
  [ -n "$chosen" ] || chosen="$installed"   # unreachable: (1) just proved the installed copy qualifies
  # FOLLOW THE LINK the shim follows, then take ITS `../` PHYSICALLY: a symlinked shim, or a
  # symlinked candidate DIRECTORY, would otherwise point the check at a path nothing installs.
  if ! real="$(gh_shim_realpath "$chosen/gh")" || [ -z "$real" ]; then
    fail "the argv-level gh SHIM cannot be RESOLVED through its symlinks: $chosen/gh — the chain is a CYCLE, longer than ${GH_SHIM_MAX_LINK_HOPS:-40} hops, or unreadable, so this cell's shim cannot be executed and its admin-merge verifier sibling cannot be located. Refusing rather than guessing a path (#984). Re-run --install"
    return 0
  fi
  verifier="$(dirname "$real")/../verify-admin-merge-evidence.sh"
  # Normalise for the message (the field is read by whoever has to act on it); an unreadable
  # directory keeps the unnormalised form rather than printing an empty path. `-P`/`pwd -P` is
  # what makes this PHYSICAL: with a logical `cd`, `$symlinked-dir/..` strips a component of the
  # LEXICAL path and the guard tests a path nothing installs, refusing a healthy cell.
  if norm="$(CDPATH= cd -P -- "$(dirname "$real")/.." 2>/dev/null && pwd -P)"; then
    verifier="$norm/verify-admin-merge-evidence.sh"
  fi
  if [ ! -s "$verifier" ]; then
    # The resolved path is named in the message (and, when a LINK moved it, so is what it was
    # resolved FROM) so the operator can see which artifact the gate actually looked for.
    # ⛔ KEYED ON WHAT THE KERNEL HAD TO FOLLOW, never on a string comparison between the
    # normalised and the lexical form. Those differ textually for EVERY candidate whose path
    # contains a `..`, so the clause fired on plain directories too and told the operator a link
    # was involved when none was — on the very message an operator reads to find the artifact
    # (MEASURED on this PR's own `ovr-nosib` fixture, a plain directory two levels deep).
    local via=""
    if [ "$real" != "$chosen/gh" ]; then
      via=" (resolved from $chosen/gh through its symlinks)"
    elif [ -L "$chosen" ]; then
      via=" (the candidate DIRECTORY $chosen is a SYMLINK, so its ../ is taken PHYSICALLY to $(dirname "$verifier"))"
    fi
    # ⛔ WHO CAN REPAIR IT DECIDES WHAT TO PRESCRIBE. `--install` writes the INSTALLED pair only, so
    # "Re-run --install" is the remedy ONLY when the failing candidate's verifier IS the installed
    # one (the same directory, named through a symlink or not — arm 3c/3d's healthy states). When
    # the failing candidate is an `AGENT_GH_SHIM_DIR` override, `--install` cannot touch it: the
    # extension PREFERS that directory, so the operator would re-run the install, watch it succeed,
    # and find the cell still refused — a wrong prescription in the diagnostic is its own false
    # trail. Keyed on the RESOLVED verifier's directory (not on `$chosen` being textually equal to
    # `$installed`), because a symlinked candidate directory that points AT the installed shim is
    # still repaired by re-installing.
    local fixit=" Re-run --install"
    if [ "$(dirname "$verifier")" != "$(dirname "$installed")" ]; then
      fixit=" ⛔ Re-running --install will NOT repair this: the candidate missing its verifier is not the installed copy, it is AGENT_GH_SHIM_DIR=$chosen, which the extension PREFERS over the installed shim — fix or unset that override."
    fi
    fail "the admin-merge EVIDENCE VERIFIER is missing or empty: $verifier$via — scripts/gh-shim/gh resolves it as its own ../verify-admin-merge-evidence.sh and fails CLOSED without it, so every admin merge through the shim this cell resolves ($chosen) would be refused (#984).$fixit"
  fi
}

# Check (both modes; READ-ONLY — it must not even remove an empty directory, because
# `--verify` is documented as writing nothing and a reader may run it on a live cell).
guard_tools_dir() {
  [ -d "$DEST/tools" ] || return 0
  local entry lower stray=""
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    case "$entry" in .*) continue ;; esac   # pi ignores hidden entries too (.DS_Store)
    lower="$(printf '%s' "$entry" | tr '[:upper:]' '[:lower:]')"
    local allowed=0 a
    for a in "${TOOLS_ALLOWED_NAMES[@]}"; do
      [ "$lower" = "$a" ] && { allowed=1; break; }
    done
    [ "$allowed" -eq 1 ] || stray="$stray $entry"
  done <<<"$(ls -A "$DEST/tools" 2>/dev/null)"
  if [ -n "$stray" ]; then
    fail "$DEST/tools/ contains non-fd/rg entries:$stray — pi blocks EVERY interactive boot on these (#1277)"
  fi
}

# ── verify ───────────────────────────────────────────────────────────────────
# A cell is certified only by reading the ARTIFACT back. Every declared farm file must be
# present AND byte-identical to the checkout (the repo copy is the copy that must run),
# every guard must have landed, the deny must hold, and the tools/ namespace must be clean.
GUARD_EXTENSIONS=(review-enforcer verification-gate main-worktree-guard search-guard gui-device-guard audit-logger.ts shared)

# shipped_content_matches <src-dir> <dst-dir> — every file in the SOURCE tree (minus
# node_modules) must exist at the same relative path under the destination and be
# byte-identical. Deliberately ONE-DIRECTIONAL: the installer never deletes a cell-local extra
# (the header's contract — nothing is removed except a denied extension, a legacy tools/fleet/,
# and a declared retirement), so a file that exists only on the cell is not a failure. A two-way `diff -rq`
# refused such a cell and the installer could not repair it — a false block, not a finding.
# A MISSING or EDITED shipped file still fails: that is drift.
#
# The list is enumerated with `find -H`, so a SOURCE whose own final path component is a
# symlink to a directory (an operator's symlinked checkout, or a fixture that links the real
# extension dirs in) is followed — `find` without -H descends into nothing there and the tree
# would read as empty. `cp -R` on the install side already resolved that case, so verify has to
# agree with install about the same input.
#
# Returns 1 on drift, 2 when the source tree yields NOTHING to compare (an emptied checkout
# must not read as a match), and 3 when the tree could not be compared IN FULL — an unreadable
# subtree, a name the line-based list cannot represent, or an entry that is not a regular file.
# 3 is a refusal rather than a guess: in each of those cases the missing file would otherwise
# go uncompared while the call still reported a match, and every file this installs is later
# executed.
shipped_content_matches() {
  local src="$1" dst="$2" f rel n=0 files nl nonreg
  [ -d "$src" ] || return 2
  [ -r "$src" ] || return 3
  # A NAME containing a newline cannot survive the line-based list below: the entry is lost, or
  # a sibling's line is duplicated in its place, so that file may never be compared at all.
  # Refuse the tree; no shipped tree in this repo has such a name.
  nl="$(find -H "$src" ! -path '*/node_modules' ! -path '*/node_modules/*' -type f -print0 2>/dev/null | tr -cd '\n' | wc -c | tr -d ' ')"
  [ "$nl" = "0" ] || return 3
  # A shipped entry that is neither a directory nor a regular file (a symlink, fifo, device)
  # cannot be byte-compared — `cp -R` copies a symlink AS a symlink, so a retargeted link on
  # the cell would compare equal to nothing and could never be caught. The node_modules
  # namespace is excluded including the entry itself: a LINKED node_modules (a hoisted or
  # shared dep store) is legitimate and is not compared by construction.
  nonreg="$(find -H "$src" ! -path '*/node_modules' ! -path '*/node_modules/*' ! -type d ! -type f 2>/dev/null | head -1)"
  [ -z "$nonreg" ] || return 3
  files="$(find -H "$src" -type f 2>/dev/null)" || return 3
  # An empty list is the emptied-tree case, and must be told apart from the refusals above: the
  # loop below would otherwise see one empty line and report a lossy list instead.
  [ -n "$files" ] || return 2
  while IFS= read -r f; do
    [ -n "$f" ] || return 3   # an empty entry can only mean a lossy list — refuse, never skip
    rel="${f#"$src"/}"
    case "$rel" in node_modules/*) continue ;; esac
    cmp -s "$f" "$dst/$rel" || return 1
    n=$((n + 1))
  done <<<"$files"
  [ "$n" -gt 0 ] || return 2
  return 0
}

verify_layer() {
  local rows src_rel dest_rel base src dst farm_n=0 farm_bad=0
  rows="$(read_farm_set)" || { fail "the declared farm set could not be re-read from setup.sh"; return 0; }
  while IFS=$'\t' read -r src_rel dest_rel base; do
    [ -n "${base:-}" ] || continue
    farm_n=$((farm_n + 1))
    src="$INFRA_ROOT/$src_rel/$base"
    dst="$DEST/$dest_rel/$base"
    if [ ! -f "$dst" ]; then
      farm_bad=1
      fail "farmed script MISSING: $dest_rel/$base"
    elif ! cmp -s "$src" "$dst"; then
      farm_bad=1
      fail "farmed script DIFFERS from the checkout: $dest_rel/$base (a stale or hand-edited copy)"
    fi
  done <<<"$rows"
  if [ "$farm_n" -lt "$MIN_FARM_FILES" ]; then
    farm_bad=1
    fail "the declared farm set re-read as only $farm_n file(s) (floor: $MIN_FARM_FILES) — verify would be checking a truncated list"
  fi
  # A success line must not appear in a log whose own verdict is FAIL: a reader who greps for
  # "verified N farm file(s)" would otherwise take a failed leg as clean.
  if [ "$farm_bad" -eq 0 ]; then
    log_line "verified $farm_n declared farm file(s) against the checkout"
  fi

  # ── the UNFARM leg (#1924) ────────────────────────────────────────────────
  # A declared retirement must be GONE from this cell, and the two lists must not
  # intersect. Without this read-back the certificate said "layer verified" about a cell
  # that still executes a script the repo declares retired — the exact false PASS the
  # leg exists to close, and the reason the cell half cannot be skipped: a laptop-only
  # unfarm leaves every cell behind.
  if load_farm_retire; then
    local retired_list="" retired_rel conflict_out="" conflict_rc=0 retired_n=0 declared_ok=1
    if retired_list="$(farm_retired_entries "$INFRA_ROOT/pi-bootstrap/farm-retired.txt")"; then
      if ! read_declared_farm_rel_paths "$rows"; then
        declared_ok=0
        fail "the declared path set could not be built in full — verify cannot vouch for a retirement check against a truncated set"
      fi
      conflict_out="$(farm_retired_conflicts "$INFRA_ROOT/pi-bootstrap/farm-retired.txt" "$FARM_DECLARED_REL")" || conflict_rc=$?
      case "$conflict_rc" in
        0) ;;
        2) fail "the retirement list pi-bootstrap/farm-retired.txt could not be read — verify cannot vouch that any declared retirement was applied (an unreadable list removes nothing)" ;;
        *) while IFS= read -r retired_rel; do
             [ -n "$retired_rel" ] || continue
             fail "RETIREMENT CONTRADICTION: $retired_rel is declared RETIRED but a farm array still declares it — the copy leg re-creates it, so the retirement can never be applied"
           done <<<"$conflict_out" ;;
      esac
      local retired_present=0
      while IFS= read -r retired_rel; do
        [ -n "$retired_rel" ] || continue
        retired_n=$((retired_n + 1))
        # THREE states, never two (#1924): `[ -e ]` answers false both for "absent" and for
        # "cannot be read", and reading the second as the first certifies a cell that is
        # still executing the retired artifact.
        case "$(farm_artifact_state "$DEST" "$retired_rel")" in
          present)
            retired_present=$((retired_present + 1))
            fail "RETIRED ARTIFACT STILL PRESENT: $retired_rel — the repo declares it retired and this cell would keep executing it (#1924); re-run --install, or remove it by hand if the checkout is the stale side" ;;
          absent) : ;;
          *)
            retired_present=$((retired_present + 1))
            fail "CANNOT VERIFY the retired artifact $retired_rel is absent — a directory on its path is not searchable, so 'absent' is not a verifiable answer; fix the permissions and re-run --verify" ;;
        esac
      done <<<"$retired_list"
      # The success line is only true when nothing above failed: an operator reading the log
      # must never see "verified … absent" next to a FAIL about the same leg. `declared_ok` is
      # part of that: a truncated declared set makes the contradiction check vacuous (every
      # still-farmed retired name is invisible), so its clean answer proves nothing — and
      # `retired_n` would count entries read from a list the run could not fully build from.
      if [ "$retired_present" -eq 0 ] && [ "$conflict_rc" -eq 0 ] && [ "$declared_ok" = 1 ]; then
        log_line "verified $retired_n declared retirement(s) absent from the cell"
      fi

      # ...and that the leg RAN against THIS declaration. With an empty retirement list the
      # loop above is vacuous — it cannot distinguish "nothing to retire" from "the leg never
      # ran on this cell". The snapshot the last install recorded is the evidence, and it also
      # catches a name that a previous install farmed and that has since been dropped from a
      # farm array without being declared (invisible in neither set, so the retired-list
      # read-back above is blind to it).
      local snap snap_rel want_out
      snap="$(farm_snapshot_path "$DEST")"
      snap_rel="${snap#"$DEST"/}"
      if [ ! -f "$snap" ]; then
        if [ "$(farm_artifact_state "$DEST" "state/farm-declared.txt")" = absent ]; then
          fail "the UNFARM leg never recorded a farm declaration snapshot ($snap_rel) — this cell's layer predates #1924 or the unfarm leg did not run; re-run --install"
        else
          fail "$snap_rel exists but is not a readable regular file (a directory? a dangling symlink? a non-searchable state/?) — that is NOT 'the layer predates #1924'; fix it and re-run --install"
        fi
      else
        # The snapshot can differ in TWO directions, and they need DIFFERENT advice — the
        # remedies are not interchangeable:
        #   * declared here but not installed: this cell's layer is older than its checkout, so
        #     `--install` is exactly the remedy (it re-farms what the checkout declares).
        #   * recorded by the last install but no longer farmed: if that was a retirement it
        #     must be declared, because `--install` does not delete what it no longer farms
        #     (that is the gap this leg closes) — and if it was NOT a retirement, this checkout
        #     is older than the installed layer and `--install` from it will REFUSE (the
        #     orphan/shrink check), so the answer is to install from the newer checkout.
        # Saying "declare it retired" in the second case, or "just re-run --install", is how an
        # operator deletes an artifact the repo still ships or walks into a refusal loop.
        local uninstalled='' gone='' p snap_sorted msg snap_ok=1
        # `sort`'s OWN status is what proves the snapshot was read: discarding it turns an
        # unreadable snapshot into an EMPTY one, which reads as "this cell is missing every
        # farmed file" — the right verdict for the wrong reason, pointing the operator at a
        # rebuild instead of at permissions. Same rule as the retirement list above. And when
        # either list could not be read, the directional comparison is skipped entirely: a
        # message built from a truncated set is worse than the one failure that names it.
        if ! snap_sorted="$(LC_ALL=C sort -u "$snap")"; then
          snap_ok=0
          snap_sorted=""
          fail "the farm declaration snapshot ($snap_rel) could not be READ — that is not 'the cell is missing files'; fix its permissions and re-run --verify"
        fi
        if [ "$snap_ok" = 1 ] && [ "$declared_ok" = 1 ]; then
          want_out="$(printf '%s' "$FARM_DECLARED_REL")"     # already newline-terminated
          while IFS= read -r p; do
            [ -n "$p" ] || continue
            farm_rel_listed "$p" "$snap_sorted" || uninstalled="$uninstalled $p"
          done <<<"$want_out"
          while IFS= read -r p; do
            [ -n "$p" ] || continue
            farm_rel_listed "$p" "$want_out" || gone="$gone $p"
          done <<<"$snap_sorted"
        fi
        if [ "$snap_ok" = 1 ] && [ "$declared_ok" = 1 ] && [ -z "$uninstalled" ] && [ -z "$gone" ]; then
          log_line "verified the farm declaration snapshot against the checkout's declared set"
        elif [ "$snap_ok" = 1 ] && [ "$declared_ok" = 1 ]; then
          msg="the farm declaration snapshot ($snap_rel) is not this checkout's declared set — re-run --install."
          if [ -n "$uninstalled" ]; then
            msg="$msg Declared by this checkout but NOT installed here:$uninstalled."
          fi
          if [ -n "$gone" ]; then
            msg="$msg Recorded by the last install but no longer farmed by this checkout:$gone — if that was a retirement it must ALSO be declared in pi-bootstrap/farm-retired.txt (otherwise --install refuses to orphan it, and the artifacts stay installed); if it was NOT a retirement, this checkout is OLDER than the layer installed here: install from the newer checkout, do not declare it (declaring would delete what the repo still ships)."
          fi
          fail "$msg"
        fi
      fi
    else
      fail "the retirement list pi-bootstrap/farm-retired.txt could not be read — nothing could be vouched for on the UNFARM leg"
    fi
  else
    fail "pi-bootstrap/lib/farm-retire.sh is missing from the checkout — the UNFARM leg cannot be verified, so a retired farm script on this cell would go unreported"
  fi

  local rec="$DEST/scripts/record-review.sh"
  if [ ! -s "$rec" ] || [ ! -x "$rec" ]; then
    fail "record-review.sh is missing, empty or not executable at $rec — merge-one.sh runs it directly, so every review would be re-paid for and never recorded (#1717)"
  fi
  if [ ! -s "$DEST/scripts/lib/diff-normalize.py" ]; then
    fail "lib/diff-normalize.py is missing or empty — record-review.sh resolves it as its own sibling and degrades to the raw pre-#1362 digest"
  fi

  # ── the argv-level gh shim (docs/ops/ACTIVATION-MATRIX.md, row 1) ────────────
  # The shim (`scripts/gh-shim/gh`) is the only layer a shell TOKEN SPLICE cannot defeat (`--ad""min`,
  # `$'--admin'`) — a discarded PATH entry still defeats it, which is the shim's own declared limit.
  # It IS farmed now (`setup.sh` · `merge_gate_srcs`, which this installer PARSES — one declaration,
  # both platforms), and `guard_gh_shim` — not this line — is the AUTHORITY on whether the cell is
  # armed: it fails BY NAME when the shim the extension resolves is absent, non-executable, or
  # missing its evidence-verifier sibling, and it runs in `--verify` and at the end of `--install`.
  # Before the farm, the cell carried no `scripts/gh-shim` AT ALL and every lane logged
  #   `#984 argv-level gh shim not found — only the string scanner is active`
  # while reporting LAYER VERIFIED; that is why this line exists as a readable report of the
  # activation state (armed / disarmed / absent) at the moment a reader looks — silence would have
  # left a green layer and a degraded gate indistinguishable in the log.
  #
  # The candidates below are the extension's OWN list (`resolveGhShimDir`), in its order, and the
  # default candidate is the directory the extension actually RESOLVES (`gh_shim_extension_dir`:
  # physically, so a farm-SYMLINKED extension reports the checkout it resolves into, not a lexical
  # path the gate never reads) — so this report cannot drift from what the gate will do.
  # ⛔ `$DEST/shims` is NOT a third candidate even though the extension materialises there:
  # `resolveGhShimDir` never READS it, so a neutral link with no resolvable source is a link the
  # gate ignores — which is exactly the false comfort this line exists to break. (Measured on the
  # laptop this fleet runs: `~/.pi/agent/shims/gh` was a healthy-looking symlink while the extension
  # resolved null, because its source candidate, `~/.pi/agent/scripts/gh-shim`, did not exist yet.)
  local shim_state="absent" shim_at="" shim_cand shim_installed
  shim_installed="$(gh_shim_extension_dir)"
  for shim_cand in "${AGENT_GH_SHIM_DIR:-}" "$shim_installed"; do
    [ -n "$shim_cand" ] || continue
    if [ -f "$shim_cand/gh" ] && [ -x "$shim_cand/gh" ]; then
      shim_state="present"
      shim_at="$shim_cand"
      break
    fi
  done
  if [ "$shim_state" = present ] && [ "${AGENT_GH_SHIM:-}" = 0 ]; then
    # ⛔ RESUMING THE SHIM IS NOT ARMING IT. `withGhShim` returns null when AGENT_GH_SHIM=0 and
    # `ghShimWillEnforce` requires the same variable not to be 0, so a box with an executable shim
    # and this kill switch in its env injects nothing and enforces nothing. Reporting "armed" there
    # would invert the purpose of this block (a green line a reader trusts more than `LAYER VERIFIED`).
    log_line "activation: gh shim PRESENT at $shim_at but DISARMED — AGENT_GH_SHIM=0, so the review-enforcer injects nothing and the string scanner is the only layer the GATE itself has (#984). A `gh` already resolved through PATH is not measured by this line — see docs/ops/ACTIVATION-MATRIX.md row 2."
  elif [ "$shim_state" = present ]; then
    log_line "activation: gh shim PRESENT at $shim_at (argv-level admin-merge guard armed)"
  else
    local stale=""
    if [ -e "$DEST/shims/gh" ] || [ -L "$DEST/shims/gh" ]; then
      stale=" ⛔ $DEST/shims/gh exists but it is never a resolution CANDIDATE: it is a mirror the extension writes from a RESOLVED source and then injects (materializeGhShim → withGhShim), so with no resolvable source it is never armed — do not read it as armed."
    fi
    log_line "activation: gh shim ABSENT — looked at \${AGENT_GH_SHIM_DIR:-} and $shim_installed; the review-enforcer then runs the string scanner only (#984), which is all the GATE itself has. A `gh` already resolved through PATH is not measured by this line — see docs/ops/ACTIVATION-MATRIX.md row 2.$stale"
  fi

  local entries
  entries="$(read_manifest_entries)" || { fail "the extension ship-list could not be re-read from manifest.json"; return 0; }
  if [ "$(printf '%s\n' "$entries" | grep -c . || true)" -lt "$MIN_SHIP_LIST" ]; then
    fail "manifest.json's extension ship-list re-read as fewer than $MIN_SHIP_LIST entries — verify would be checking a truncated list"
    return 0
  fi
  while IFS= read -r base; do
    [ -n "$base" ] || continue
    denied_extension "$base" && continue   # checked below, against the CELL and not the ship-list
    # EXISTENCE IS NOT ENOUGH. The farm loop above byte-compares every file, but this loop
    # used to accept a bare `[ -e ]` — so a stale, truncated or hand-edited guard extension
    # verified clean, and a guard that is not the reviewed one is worse than a missing one
    # (the missing one is loud; this one reports LAYER VERIFIED). Compare the content.
    local esrc="$INFRA_ROOT/extensions/$base" edst="$DEST/extensions/$base"
    if [ ! -e "$edst" ]; then
      fail "extension MISSING: extensions/$base"
    elif [ ! -e "$esrc" ]; then
      fail "extension $base is in manifest.json's ship-list but absent from the checkout ($esrc) — verify cannot vouch for what it did not read"
    elif [ -f "$esrc" ]; then
      cmp -s "$esrc" "$edst" \
        || fail "extension DIFFERS from the checkout: extensions/$base (a stale or hand-edited copy)"
    elif [ ! -d "$edst" ]; then
      fail "extension SHAPE CHANGED: extensions/$base is a directory in the checkout and not one on the cell"
    else
      shipped_content_matches "$esrc" "$edst"
      case $? in
        0) ;;
        2) fail "extension $base ships NO files in the checkout ($esrc) — verify cannot vouch for an empty tree" ;;
        3) fail "extension $base could not be compared IN FULL ($esrc) — refusing to certify a subset: an unreadable tree, a non-regular entry, or a name the file list cannot represent" ;;
        *) fail "extension CONTENT DIFFERS from the checkout: extensions/$base (a stale, truncated or hand-edited copy)" ;;
      esac
    fi
  done <<<"$entries"

  # The deny is enforced against the CELL, not only across the manifest rows. Bound to the
  # ship-list it would go INERT the moment an entry is dropped from manifest.json, and a copy left
  # on the cell (a hand-push, or an install from an older checkout) would then be certified clean.
  # A deny that stops denying when the ship-list changes is the same fail-open it exists to catch.
  # (#2147) BY PATTERN, across EVERY home the cell runs under: `pi` loads `extensions/*.ts|*.js` and
  # any `extensions/<dir>` holding an index, so a `tortoise-capture.bak.ts` or a
  # `tortoise-capture.old/index.ts` WAS being loaded while an exact-name test certified the box —
  # measured 1 / 0 / 7 / 3 / 2 surviving copies across the five cells, injecting 250+ bytes of
  # `paused N (attempts; continues in the background)` onto the turn path.
  local adir dname f
  while IFS= read -r adir; do
    [ -n "$adir" ] || continue
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      dname="$(basename "$f")"
      # The capture entry gets its own NAMED line, because its failure mode is not "a surface is
      # missing" — it is "the box stops running lanes and the bring-up probe lies about it". An
      # operator grepping the log for the dead-lane cause must find that sentence; the generic
      # "denied extension" wording would read as a cosmetic surface mismatch.
      case "$dname" in
        tortoise-capture*)
          fail "capture extension present on a cell: $(denied_extension_note "$dname") — $f" ;;
        *)
          fail "denied extension is PRESENT on the cell: extensions/$dname ($(denied_extension_note "$dname")) — $f" ;;
      esac
    done <<EOF
$(denied_extension_copies "$adir")
EOF
  done <<EOF
$(cell_agent_dirs)
EOF

  local g
  for g in "${GUARD_EXTENSIONS[@]}"; do
    [ -e "$DEST/extensions/$g" ] \
      || fail "GUARD MISSING: extensions/$g — the cell would run with fewer guards than a laptop lane"
  done

  # Every extension that DECLARES runtime deps must have the node_modules npm would have
  # produced. The install path is gated on npm's exit code; verify cannot see that history,
  # and a cell whose deps have since vanished (a wiped HOME, an aborted install) would
  # otherwise certify clean while `builtin-tools` — the `task` dispatcher itself — fails to
  # load. STRUCTURAL check, and stated as such: it proves the directory is POPULATED, not that
  # the tree inside it is intact. Non-empty is the half that `-d` alone got wrong — a tree
  # that was WIPED is the same failure one step later, and with `--check` verifying before it
  # installs, a certified-yet-unloadable extension is never re-installed.
  local d seen_dep=0
  for d in "$DEST"/extensions/*/; do
    [ -f "$d/package.json" ] || continue
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get("dependencies") else 1)' \
      "$d/package.json" 2>/dev/null || continue
    seen_dep=$((seen_dep + 1))
    if [ ! -d "$d/node_modules" ]; then
      fail "DEPENDENCIES MISSING: extensions/$(basename "$d")/node_modules — that extension declares runtime deps and cannot load without them (cd '$d' && npm install --omit=dev)"
    elif [ -z "$(ls -A "$d/node_modules" 2>/dev/null)" ]; then
      fail "DEPENDENCIES EMPTY: extensions/$(basename "$d")/node_modules — the directory exists but holds nothing, so the extension cannot load; the install path repopulates it (cd '$d' && npm install --omit=dev)"
    fi
  done
  if [ "$seen_dep" -eq 0 ]; then
    fail "no extension in $DEST/extensions declared any dependencies — the dependency check proved nothing (a truncated or hand-made extensions/ tree)"
  else
    log_line "verified $seen_dep extension(s) that declare runtime deps"
  fi

  # skills/. The install is a `cp -R` of the WHOLE tree, so the read-back compares the whole tree.
  # A walk that visits only the 124 SKILL.md entry points certifies a cell missing every
  # `references/`, `workflow/`, `templates/` and `scripts/` file a skill tells a lane to read —
  # ~180 files — and a skill whose entry point survived is not the skill. This is the same
  # one-directional comparison the extension and config loops use, so the refusals come with it:
  # an emptied tree (2), and a tree it cannot compare IN FULL (3) — an unreadable subtree, a
  # non-regular entry (a symlink is copied as a link), or a name the file list cannot represent.
  # No count floor here, unlike the farm set and the ship-list: those are PARSES, which can
  # truncate silently, while this walk's truncation is a non-zero `find` status that is refused
  # as uncomparable rather than counted.
  if [ ! -d "$DEST/skills" ]; then
    fail "skills/ is missing"
  else
    shipped_content_matches "$INFRA_ROOT/skills" "$DEST/skills"
    case $? in
      0) log_line "verified the skills tree against the checkout" ;;
      2) fail "skills/ ships NO files in the checkout ($INFRA_ROOT/skills) — verify cannot vouch for an empty tree" ;;
      3) fail "skills/ could not be compared IN FULL ($INFRA_ROOT/skills) — refusing to certify a subset: an unreadable tree, a non-regular entry, or a name the file list cannot represent" ;;
      *) fail "SKILLS CONTENT DIFFERS from the checkout: skills/ (a stale, truncated or hand-edited copy)" ;;
    esac
  fi
  # The config set. These five were installed blind and never read back, so a checkout
  # missing one produced a cell that verified clean with no sub-agent definitions at all —
  # pi resolves user-scope sub-agents from ~/.pi/agent/agents, so a lane could not dispatch
  # a reviewer, and extensions/subagent reports `Agents: none` without an error. Read back
  # the CONTENT too: a hand-edited agents/verifier.md is the same class as a hand-edited
  # guard — it is the artifact a lane dispatches reviewers with.
  local cfg csrc cdst
  for cfg in agents behavior-control coding-rules.md response-rules-reminder.md skills-repos.yaml; do
    csrc="$INFRA_ROOT/pi-bootstrap/pi-config/$cfg"
    cdst="$DEST/$cfg"
    if [ ! -e "$cdst" ]; then
      fail "config artifact MISSING: $cfg (installed from $csrc)"
    elif [ ! -e "$csrc" ]; then
      fail "config artifact $cfg is not in the checkout ($csrc) — verify cannot vouch for it"
    elif [ -f "$csrc" ]; then
      # SHAPE first: a cell whose `agents` is a FILE where the checkout has a directory used to
      # fall through every branch of this chain and be certified (the extension loop has had
      # this check; the config loop did not).
      if [ ! -f "$cdst" ]; then
        fail "config artifact SHAPE CHANGED: $cfg is a file in the checkout and not one on the cell"
      else
        cmp -s "$csrc" "$cdst" \
          || fail "config artifact DIFFERS from the checkout: $cfg (a hand-edited cell copy — re-apply it as a checkout change)"
      fi
    elif [ ! -d "$cdst" ]; then
      fail "config artifact SHAPE CHANGED: $cfg is a directory in the checkout and not one on the cell"
    else
      shipped_content_matches "$csrc" "$cdst"
      case $? in
        0) ;;
        2) fail "config artifact $cfg ships NO files in the checkout ($csrc) — verify cannot vouch for an empty tree" ;;
        3) fail "config artifact $cfg could not be compared IN FULL ($csrc) — refusing to certify a subset: an unreadable tree, a non-regular entry, or a name the file list cannot represent" ;;
        *) fail "config artifact CONTENT DIFFERS from the checkout: $cfg (a hand-edited or stale cell copy)" ;;
      esac
    fi
  done
  # `-f` alone certified an EMPTY AGENTS.md — "no global rules" reported as verified. A cell-local
  # AGENTS.md is legitimate (the install writes one only when it is absent), so this checks that
  # there is something in it, not that it matches the checkout.
  [ -s "$DEST/AGENTS.md" ] || fail "AGENTS.md is missing or empty (a cell lane gets no global rules)"
  [ -f "$DEST/settings.json" ] || fail "settings.json is missing"
  # settings.json is MERGED, so it can never be byte-compared — but every key the checkout
  # declares must still be present and equal on the cell (the merge is source-wins, per key,
  # with cell-local extras surviving). Without this, a checkout whose settings.json went
  # missing certified a cell running the STALE settings it already had.
  local ssrc="$INFRA_ROOT/pi-bootstrap/pi-config/settings.json"
  if [ ! -f "$ssrc" ]; then
    fail "pi-bootstrap/pi-config/settings.json is missing from $INFRA_ROOT — settings were never installed from this checkout"
  elif [ -f "$DEST/settings.json" ] && command -v python3 >/dev/null 2>&1; then
    python3 - "$ssrc" "$DEST/settings.json" <<'PY' || fail "settings.json does not carry the checkout's keys (it kept a stale cell copy)"
import json, sys

def subset(src, dst, path=""):
    if isinstance(src, dict):
        if not isinstance(dst, dict):
            return [path or "<root>"]
        return [p for k, v in src.items() for p in subset(v, dst.get(k), path + "/" + k)]
    return [] if src == dst else [path or "<root>"]

bad = subset(json.load(open(sys.argv[1])), json.load(open(sys.argv[2])))
sys.exit(1 if bad else 0)
PY
  fi
  if command -v python3 >/dev/null 2>&1 && [ -f "$DEST/settings.json" ]; then
    python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$DEST/settings.json" >/dev/null 2>&1 \
      || fail "settings.json is not valid JSON"
  fi

  # .mcp.json — the hosted graph entry (graph-mcp-provision). Verified on the ARTIFACT: the
  # entry present, HTTP (not the legacy stdio command that needed a checkout+venv a cell does
  # not have), an env-indirect Authorization, and NO literal credential in the shared file.
  verify_graph_mcp || true

  guard_tools_dir
  guard_spawn_gate
  guard_gh_shim

  if [ "$FAILURES" -eq 0 ]; then
    # ⛔ The credential state rides ON the certification line, not in a warning above it. A
    # `--verify` that prints LAYER VERIFIED while the graph key does not resolve certifies a cell
    # whose every lane writes GRAPH-UNREACHABLE — and nothing else catches it: the key is not part
    # of the layer, cloud-cell-bringup.sh does not check it, and the warning above scrolls away.
    # The exit code stays 0 on purpose (a missing key is not a broken layer, and refusing here
    # would leave an operator unable to certify a correctly-installed cell over a key nobody has
    # pushed yet), so the STATE is what must be unmissable.
    # ⛔ THE STATE GOES ON THE CERTIFICATION LINE ITSELF. It was a second line, and the only
    # programmatic consumer (`scripts/cloud-cell-bringup.sh`) filters this output with
    # `grep -E 'mode=--verify|LAYER VERIFIED'` — so a separate line was DROPPED, and a cell whose
    # graph key does not resolve was reported as certified with nothing about the credential. The
    # comment above claimed the state "rides ON the certification line"; now it does.
    log_line "LAYER VERIFIED — $DEST carries the farmed scripts, the guards, the skills and the config — graph credential: $(graph_credential_state)"
    # ⛔ THE LAYER IS NOT THE CELL (agent-infra#2916 check 2, correcting #2909). This line used to be
    # the last thing an operator saw before starting lanes, and `--install` can end here with NO
    # HARNESS PIN — measured: a `bash -x` trace STOPS at exactly this `log_line`, and the pin was then
    # recorded by a DIFFERENT script (`cloud-cell-bringup.sh::check_harness_pin`), i.e. the work that
    # made the cell usable was done by something other than the thing that reported success.
    # The pin is created in exactly ONE place, and a second copy here would be the duplicated-mechanism
    # defect the #2916 mandate forbids — so this NAMES it instead of duplicating it, and the cell is
    # not ready until that gate has run. Nothing here writes or checks the pin: the gate is the
    # authority and this is the pointer to it.
    log_line "the LAYER only — the harness PIN is not recorded by this script: a cell is NOT ready to start a controller until 'cloud-cell-bringup.sh --check' has pinned the harness (that gate REFUSES without one; a hand-copied harness is the §11 defect)"
  fi
}

# ── main ─────────────────────────────────────────────────────────────────────
main() {
  case "$MODE" in
    --help|-h) awk 'NR>1 { if ($0 ~ /^set -uo pipefail$/) exit; if ($0 ~ /^# shellcheck/) next; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"; exit 0 ;;
    --install|--verify) ;;
    *) printf 'usage: %s [--install|--verify|--help]\n' "$(basename "$0")" >&2; exit 2 ;;
  esac

  if ! INFRA_ROOT="$(resolve_infra_root)"; then
    die "no agent-infra checkout found (looked at: \$INFRA_ROOT, \$AGENT_INFRA_PATH, $SELF_DIR/.., \${HARNESS}/.., $CELL_HOME/agent-infra).
       Without one a cell runs UNGUARDED (no review-enforcer, verification-gate, main-worktree-guard,
       search-guard, audit-logger, and no skills) and its merge path dies rc=127 on the missing
       scripts/record-review.sh. Clone agent-infra onto the cell and re-run with INFRA_ROOT=<path>."
  fi
  printf 'cell-install — mode=%s cell_home=%s infra_root=%s\n' "$MODE" "$CELL_HOME" "$INFRA_ROOT"

  if [ "$MODE" = "--install" ]; then
    mkdir -p "$DEST" || die "cannot create $DEST"
    install_farms
    install_extensions
    install_extension_deps
    install_skills
    install_config
    install_spawn_gate
    migrate_legacy_tools_farm
    # LAST: the UNFARM leg can refuse (a contradiction, an unremovable artifact, a checkout
    # without the leg). Running it here means a refusal follows a COMPLETE install, so the
    # cell keeps its guards/extensions/skills and `--verify` reports the one remaining
    # problem — instead of a die at this point leaving a guard-less half-installed cell.
    install_unfarm
  elif [ ! -d "$DEST" ]; then
    # `--verify` writes NOTHING — not even the directory it would check. A cell home with
    # no ~/.pi/agent is a cell without the layer; say that, rather than creating it and
    # then reporting thirty missing files.
    die "nothing is installed at $DEST — --verify checks an EXISTING layer and writes nothing; run --install first"
  fi
  verify_layer

  if [ "$FAILURES" -gt 0 ]; then
    printf 'FAILED: %d problem(s) — the cell must NOT be started\n' "$FAILURES" >&2
    exit 1
  fi
}

main "$@"
