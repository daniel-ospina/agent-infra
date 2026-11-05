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
#    script PARSES its array declarations — the four it declares today (`fleet_srcs`,
#    `lib_srcs`, `fleet_tools`, `merge_gate_srcs`) PLUS the two #1552/#1553 adds
#    (`lane_root_srcs`, `lane_srcs`), so the mapping is already complete when that lands —
#    plus its `scripts_dir` checkout-hygiene farm, and copies exactly those, preserving the
#    relative layout setup.sh documents (`scripts/lib/`, `scripts/fleet/`). A farm array
#    this script does not know how to lay out is a LOUD failure, never a silent skip: an
#    unparsed farm would leave a cell with a partial layer that still reports success.
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
# Only a real entry with no `Authorization` key at all is the self-host shape.
graph_mcp_var() {
  [ -f "$DEST/.mcp.json" ] || { printf 'NOENTRY'; return 0; }
  # no python3 means this file cannot be READ — "UNKNOWN", never "needs no key"
  command -v python3 >/dev/null 2>&1 || { printf 'NOENTRY'; return 0; }
  python3 -c '
import json, sys
try:
    t = json.load(open(sys.argv[1]))["mcpServers"]["tortoise"]
    if not isinstance(t, dict):
        raise ValueError("tortoise entry is not an object")
    auth = (t.get("headers") or {}).get("Authorization") or ""
except Exception:
    print("NOENTRY")                # unreadable / no such entry — NOT "declares no Authorization"
    sys.exit(0)
if not auth.strip():
    sys.exit(0)                     # no Authorization AT ALL: the documented self-host shape
if "${" not in auth:
    print("LITERAL")                # a literal credential --verify refuses (LITERAL_AUTH)
    sys.exit(0)
name = auth.split("${", 1)[1].split("}", 1)[0].split(":-", 1)[0]
print(name)
' "$DEST/.mcp.json" 2>/dev/null
}

# ONE resolver, two renderings. `graph_credential_note` prints the long explanation; the
# `LAYER VERIFIED` line prints the one-word state. Two independent resolutions of the same question
# is how a cell gets certified "credential: OK" while the note below it says NOT resolvable.
graph_key_resolve() {
  GRAPH_VAR="$(graph_mcp_var)"
  GRAPH_KEY=""
  GRAPH_KEY_SRC="the environment"
  GRAPH_NOAUTH=0
  GRAPH_NOENTRY=0
  GRAPH_LITERAL=0
  case "$GRAPH_VAR" in
    NOENTRY)
      # no readable tortoise entry at all — a DIFFERENT state from "an entry that needs no key",
      # and reporting it as the latter asserts an entry that is not there (see graph_mcp_var).
      GRAPH_NOENTRY=1
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
  local val
  val="$(printenv "$GRAPH_VAR" 2>/dev/null || true)"
  if [ -n "$val" ]; then
    GRAPH_KEY="$val"
    GRAPH_KEY_SRC="the environment ($GRAPH_VAR)"
    return 0
  fi
  # HOME first: that is the home a live lane on a cell actually runs in (measured on cell-3
  # and cell-4: HOME=/home/cmux), and the launcher sources $HOME/keys.env. CELL_HOME follows
  # because it is where THIS script installs, and on some images the two differ.
  local f
  # ⛔ `${HOME:-}`, NOT `$HOME`. This function runs under `set -uo pipefail` (line 205), so a
  # HOME-less context — systemd/launchd units, `sudo -u`, `env -i`, a CI step — aborted the WHOLE
  # verifier here with `HOME: unbound variable`, skipping `guard_tools_dir`, `guard_spawn_gate`,
  # `guard_gh_shim` and the `LAYER VERIFIED` verdict: a correctly-installed cell could not be
  # certified, and the abort lands AFTER `.mcp.json verify: OK` so the log looks like a graph
  # problem. `${CELL_HOME:-}` too — it is assigned from `${CELL_HOME:-$HOME}` elsewhere, but this
  # loop must not depend on that. An empty candidate is skipped, not stat'd as `""`.
  for f in "${HOME:-}/keys.env" "${CELL_HOME:-}/keys.env"; do
    [ -n "$f" ] && [ "$f" != "keys.env" ] || continue
    [ -f "$f" ] || continue
    val="$(graph_key_from_env_file "$f" "$GRAPH_VAR")"
    GRAPH_KEY_SRC="$f ($GRAPH_VAR)"
    if [ -n "$val" ]; then
      GRAPH_KEY="$val"
      break
    fi
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
    printf 'LITERAL — the tortoise entry carries a literal credential in the shared file; --verify refuses it (LITERAL_AUTH)'
    return 0
  fi
  if [ "$GRAPH_NOAUTH" -eq 1 ]; then
    printf 'none required — the tortoise entry declares no Authorization (self-hosted daemon)'
    return 0
  fi
  case "$GRAPH_KEY" in
    tt_*|tk_*) printf 'resolves from %s' "$GRAPH_KEY_SRC" ;;
    "")        printf 'UNRESOLVED — the entry expands ${%s}, so the tortoise MCP sends an empty Bearer and the server answers 401' "$GRAPH_VAR" ;;
    *)         printf 'resolves from %s but is not tt_/tk_-shaped (401 likely)' "$GRAPH_KEY_SRC" ;;
  esac
}

graph_credential_note() {
  graph_key_resolve
  local key="$GRAPH_KEY" src="$GRAPH_KEY_SRC"
  if [ "$GRAPH_NOENTRY" -eq 1 ]; then
    log_line "⚠️  graph credential: UNKNOWN — there is no readable tortoise entry at $DEST/.mcp.json, so there is no credential to resolve (the failure above names the reason). ⛔ A MISSING entry is not a self-host and must not be reported as one"
    return 0
  fi
  if [ "$GRAPH_LITERAL" -eq 1 ]; then
    log_line "⚠️  graph credential: the tortoise entry carries a LITERAL credential in .mcp.json — a shared config file must be env-indirect (\${TORTOISE_MCP_API_KEY}), and --verify REFUSES this file (LITERAL_AUTH); move the key to \$HOME/keys.env (mode 600) and leave the file env-indirect"
    return 0
  fi
  if [ "$GRAPH_NOAUTH" -eq 1 ]; then
    log_line "graph credential: the tortoise entry declares no Authorization — a self-hosted daemon needs none, so there is nothing to resolve"
    return 0
  fi
  case "$key" in
    tt_*|tk_*)
      log_line "graph credential: resolves from $src (len ${#key}) — the hosted MCP will authenticate" ;;
    "")
      log_line "⚠️  graph credential: NOT resolvable — the tortoise MCP entry expands \${$GRAPH_VAR} to the EMPTY"
      log_line "    string, the server answers 401 'invalid or missing Bearer token', and every lane writes"
      log_line "    GRAPH-UNREACHABLE. Remedy: put the hosted key in $CELL_HOME/keys.env (mode 600) as"
      log_line "    $GRAPH_VAR, or alias the name an older box carries: export TORTOISE_MCP_API_KEY=\"\$TORTOISE_API_KEY\" (#5153)."
      if [ "$GRAPH_VAR" = "TORTOISE_MCP_API_KEY" ] && { [ -n "${TORTOISE_API_KEY:-}" ] \
         || { [ -n "${HOME:-}" ] && [ -n "$(graph_key_from_env_file "${HOME}/keys.env" TORTOISE_API_KEY 2>/dev/null)" ]; } \
         || [ -n "$(graph_key_from_env_file "${CELL_HOME:-}/keys.env" TORTOISE_API_KEY 2>/dev/null)" ]; }; then
        log_line "    ⚠️  the LEGACY name TORTOISE_API_KEY IS set — add the alias line above and it resolves"
      fi ;;
    *)
      log_line "⚠️  graph credential: $GRAPH_VAR in $src does not look like a hosted key (expected tt_/tk_ prefix);"
      log_line "    the MCP will send whatever it holds and the server may answer 401 (#5153)." ;;
  esac
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

p = sys.argv[1]
tpl = json.load(open(sys.argv[2])) if len(sys.argv) > 2 else {}
want_url = ((tpl.get("mcpServers") or {}).get("tortoise") or {}).get("url") or ""
raw = open(p).read()
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
    print("SECRET_IN_FILE:%s" % (leak_path(servers) or "(unlocatable)"))
    sys.exit(1)


def redact(value):
    """Mask anything shaped like a credential — a marker is ECHOED into operator-facing logs."""
    return tok.sub("<redacted>", value if isinstance(value, str) else str(value))


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
    print("INSECURE_URL:%s" % url)
    sys.exit(1)
# ⛔ "contains ${" IS NOT ENOUGH FOR THE HOSTED ENDPOINT. The client sends headers VERBATIM
# (extensions/mcp-client/index.ts:819-821), so `Authorization: ${TORTOISE_MCP_API_KEY}` (no scheme) is
# delivered as `Authorization: tt_…` and the server answers 401 — yet it contains "${" and used to
# be certified. Nor is any variable acceptable: the resolver reads TORTOISE_MCP_API_KEY (and the
# LEGACY alias TORTOISE_API_KEY), so an entry naming a third variable would expand to the EMPTY STRING
# while `LAYER VERIFIED` printed a green credential line beside it. Both names are allowed, nothing
# else is, and the scheme is required.
HOSTED_AUTH = re.compile(r"^Bearer\s+\$\{TORTOISE_(API|MCP_API)_KEY(:-[^}]*)?\}$")
# ⛔ A DIFFERING url is not automatically fine, and a MISSING Authorization is not automatically
# broken: the two questions are linked. Accepting any non-empty http url let a cell whose endpoint
# was a typo (or copied from another box) be certified LAYER VERIFIED while pointing at nothing — a
# false green of exactly the class this function exists to close. And demanding an env-indirect
# header unconditionally refuses the DOCUMENTED self-host config (a local daemon needs no key,
# tortoise docs/quickstart-selfhosted.md), which merge-mcp.py then "repairs" by repointing it.
# So: the hosted default REQUIRES the env-indirect header; any other url requires the operator to
# have said so with `_selfHosted: true`, and is then reported BY NAME rather than silently passed.
if want_url and url != want_url:
    if not t.get("_selfHosted"):
        print("URL_NOT_DEFAULT:%s" % url)
        sys.exit(1)
    # ⛔ `_selfHosted` IS AN EXEMPTION, NOT A LICENCE TO CERTIFY ANY STRING (#3374 review P2). The
    # branch used to print SELFHOSTED and exit 0 for ANY marked url — including a SCHEME-LESS one
    # (`localhost:8000/mcp`), which `new URL()` in the client reads with protocol `localhost:` and no
    # host, so a cell pointing at nothing was certified LAYER VERIFIED with a green credential line.
    # An absolute http(s) url is the minimum this exemption can honestly certify.
    _su = re.match(r"^([a-z][a-z0-9+.\-]*)://([^/?#]+)", url or "", re.I)
    if not _su or _su.group(1).lower() not in ("http", "https"):
        print("BADURL:%s" % url)
        sys.exit(1)
    # A self-hosted entry is certified BY NAME, and its own transport spelling is part of what the
    # operator chose: the client selects StreamableHTTP from `url` alone and never reads `type`, so
    # refusing `sse` here would refuse a config that WORKS (and that install preserves on purpose).
    print("SELFHOSTED:%s" % url)
else:
    if t.get("type") not in (None, "http"):
        print("NOTHTTP:%s" % t.get("type"))
        sys.exit(1)
    if not auth:
        print("NOAUTH")
        sys.exit(1)
    if not HOSTED_AUTH.match(auth.strip()):
        print("WRONG_AUTH:%s" % auth)
        sys.exit(1)
    print("OK:%s:%s" % (url, auth))
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
        fail ".mcp.json's tortoise Authorization is not 'Bearer \${TORTOISE_MCP_API_KEY}' (or the legacy 'Bearer \${TORTOISE_API_KEY}') — the client sends headers VERBATIM, so anything else reaches the server as a 401 (got: ${out#WRONG_AUTH:})" ;;
      INSECURE_URL:*)
        fail ".mcp.json's tortoise url (${out#INSECURE_URL:}) carries a credential over a NON-https scheme — the client expands the header, so the live key would cross the wire in cleartext while this cell reported LAYER VERIFIED. Use https, or drop the Authorization for a local daemon (which needs none)" ;;
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

# denied_extension_note <base> — WHY a denied entry must be absent, worded ONCE. Both halves
# consume it: the install half's removal line and the verify half's failure line, so they can
# never describe different reasons for the same entry (a removal note that says "surface absent"
# about the capture extension would send an operator looking for a desktop app that is not the
# problem).
# ⛔ The capture wording is the INCIDENT'S, not a description of this checkout's file, and it is
# pinned verbatim by BOTH suites: "it blocks session_start and corrupts the provider probe". The
# cell ran a copy that differs from the repo (see the deny-list comment above), and an operator
# greps a bring-up log for exactly this sentence — so re-word it only together with the tests that
# assert it (pi-bootstrap/tests/test-cell-install.sh, scripts/cloud-cell-bringup.test.sh).
denied_extension_note() {
  case "${1%/}" in
    tortoise-capture) printf 'it blocks session_start and corrupts the provider probe' ;;
    cmux-session.ts)  printf 'its surface is absent on a Linux cell' ;;
    *)                printf 'the cell must not run it' ;;
  esac
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
  local entries base src dst n=0 removed=0 total=0 d dbase
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
  for d in "${DENY_EXTENSIONS[@]}"; do
    dbase="${d%/}"
    # `-e` follows a symlink, so a DANGLING link at this path is invisible to it; `-L` catches it.
    { [ -e "$DEST/extensions/$dbase" ] || [ -L "$DEST/extensions/$dbase" ]; } || continue
    # An unchecked `rm -rf` would log "removed" over a survivor. `verify_layer` runs at the end of
    # `--install` and would still refuse the cell, so this is not a false PASS — but a log that
    # contradicts itself two lines later is exactly what sends an operator down the wrong path.
    rm -rf "$DEST/extensions/$dbase" || die "could not remove the denied extension at $DEST/extensions/$dbase — the cell would keep running it"
    log_line "removed denied extension: $dbase ($(denied_extension_note "$dbase"))"
    removed=$((removed + 1))
  done
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

# merge_tortoise_is_hosted <merged .mcp.json> <template .mcp.base.json>
#   True only when the file that was JUST WRITTEN points its `tortoise` entry at the template's
#   (hosted) url and does not carry the `_selfHosted` marker. The merge may legitimately keep a
#   machine's own url, so this is what the install summary line reports — the ARTIFACT, never the
#   intent of having run a merge. A file that cannot be read is NOT the hosted default: the
#   caller's other line is the honest one, and the verifier refuses such a cell by name.
merge_tortoise_is_hosted() {
  python3 - "$1" "$2" <<'MCPHOSTED' >/dev/null 2>&1
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        have = (json.load(fh).get("mcpServers") or {}).get("tortoise") or {}
    with open(sys.argv[2], encoding="utf-8") as fh:
        want = (json.load(fh).get("mcpServers") or {}).get("tortoise") or {}
except Exception:
    sys.exit(1)
if not isinstance(have, dict) or not isinstance(want, dict):
    sys.exit(1)
sys.exit(
    0
    if (have.get("url") or "").strip() == (want.get("url") or "").strip()
    and (want.get("url") or "").strip()
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
      if merge_tortoise_is_hosted "$DEST/.mcp.json" "$mcp_src"; then
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
GUARD_EXTENSIONS=(review-enforcer verification-gate main-worktree-guard search-guard audit-logger.ts shared)

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
  local dname
  for dname in "${DENY_EXTENSIONS[@]}"; do
    dname="${dname%/}"
    # Same predicate as the install half: `-e` follows a symlink, so a DANGLING link at this
    # path is invisible to it and the deny would certify exactly what it exists to refuse.
    { [ -e "$DEST/extensions/$dname" ] || [ -L "$DEST/extensions/$dname" ]; } || continue
    # The capture entry gets its own NAMED line, because its failure mode is not "a surface is
    # missing" — it is "the box stops running lanes and the bring-up probe lies about it". An
    # operator grepping the log for the dead-lane cause must find that sentence; the generic
    # "denied extension" wording would read as a cosmetic surface mismatch.
    case "$dname" in
      tortoise-capture)
        fail "capture extension present on a cell: $(denied_extension_note "$dname")" ;;
      *)
        fail "denied extension is PRESENT on the cell: extensions/$dname ($(denied_extension_note "$dname"))" ;;
    esac
  done

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
