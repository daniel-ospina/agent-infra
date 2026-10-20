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
#    The deny list is entries whose operation needs a surface a Linux cell does not have:
#
#      * `cmux-session.ts` — the bridge to the **cmux desktop app** (`cmux hooks pi install`
#        owns and upgrades this file in place, and it `spawn`s the `cmux` CLI on every
#        lifecycle hook). A cell is a headless VM: there is no app, and no `cmux` binary to
#        spawn, so every hook would fail. Hand-copying it is additionally the #1760
#        duplicate-payload defect — the live laptop file is v4 (+18.8 KB, #1138) while the
#        repo snapshot is v2, so a copied one is stale the moment it lands.
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
#        tortoise-capture/, slack-bridge/. These read keys/surfaces the operator may set in
#        the cell's keys.env, and each is documented to degrade gracefully. `carousel-designer.ts`
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
#      * `.mcp.json` is deliberately NOT installed. `templates/.mcp.base.json`'s only
#        NON-lazy server is `tortoise` ("always (core)"), and it resolves
#        `${TORTOISE_HOME:-$HOME/Documents/GitHub/tortoise}/.venv/bin/python3` — a checkout
#        and venv a cell does not have. Installing it would make every cell session start
#        spawn a core server that cannot exist. `mcp-client/` IS installed, so a cell may
#        add its own `.mcp.json`; the dispatch→review→merge cycle needs no MCP surface.
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
say()  { printf '  %s\n' "$*"; }

# ── the deny list: surfaces a Linux cell does not have ───────────────────────
# Kept as data so the deny is readable and testable, and so the DEFAULT for a new
# manifest entry is "install" — the direction that cannot lose a guard.
DENY_EXTENSIONS=(
  cmux-session.ts        # bridge to the cmux DESKTOP APP (and spawns the `cmux` CLI per hook)
)

# ── the farm layout (#1723) ──────────────────────────────────────────────────
# <array name in setup.sh><TAB><source root under $INFRA_ROOT><TAB><destination under $DEST>
# An array in setup.sh that is NOT named here is a loud failure (see read_farm_set).
FARM_LAYOUT="$(printf '%s\n' \
  $'fleet_srcs\tscripts\tscripts' \
  $'merge_gate_srcs\tscripts\tscripts' \
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
  say "scripts farm: $n file(s) installed (declared by pi-bootstrap/setup.sh)"
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
  local base="$1" d
  for d in "${DENY_EXTENSIONS[@]}"; do
    [ "$d" = "$base" ] && return 0
  done
  return 1
}

install_extensions() {
  local entries base src dst n=0 removed=0 total=0
  entries="$(read_manifest_entries)" || die "the extension ship-list could not be read from manifest.json (see above)"
  total="$(printf '%s\n' "$entries" | grep -c . || true)"
  if [ "$total" -lt "$MIN_SHIP_LIST" ]; then
    die "manifest.json's extension ship-list parsed to only $total entr(y|ies) (floor: $MIN_SHIP_LIST) — the ship-list key moved and this parse would install almost nothing"
  fi
  while IFS= read -r base; do
    [ -n "$base" ] || continue
    src="$INFRA_ROOT/extensions/$base"
    dst="$DEST/extensions/$base"
    if denied_extension "$base"; then
      # enforce the deny, including against a previous hand-push
      if [ -e "$dst" ] || [ -L "$dst" ]; then
        rm -rf "$dst"
        say "removed denied extension: $base (its surface is absent on a Linux cell)"
        removed=$((removed + 1))
      fi
      continue
    fi
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
  say "extensions: $n installed from manifest.json (ship-list: $total), $((${#DENY_EXTENSIONS[@]})) denied by surface, $removed removed"
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
      say "deps installed: $base"
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
  say "skills: $(find "$DEST/skills" -name SKILL.md 2>/dev/null | wc -l | tr -d ' ') SKILL.md file(s) installed"
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
  [ "$cfg_fail" -eq 0 ] && say "agents + behavior-control + small config files installed" || true

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
      say "settings.json merged (local extras preserved)"
    elif [ -f "$DEST/settings.json" ]; then
      fail "python3 is missing and settings.json already exists — refusing to clobber it; merge by hand or install python3"
    else
      install_file "$src" "$DEST/settings.json" || fail "could not install settings.json"
      say "settings.json copied (python3 not found — plain copy)"
    fi
  fi

  # AGENTS.md — installed when ABSENT, never overwritten.
  local base_agents="$INFRA_ROOT/templates/AGENTS.base.md"
  if [ -f "$base_agents" ]; then
    if [ ! -e "$DEST/AGENTS.md" ]; then
      install_file "$base_agents" "$DEST/AGENTS.md" || fail "could not install AGENTS.md"
      say "AGENTS.md installed from templates/AGENTS.base.md"
    elif ! cmp -s "$base_agents" "$DEST/AGENTS.md"; then
      say "AGENTS.md already present and DIFFERS from templates/AGENTS.base.md — left alone (a global rules file is hand-edited state). Reconcile by hand."
    else
      say "AGENTS.md already matches templates/AGENTS.base.md"
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
    say "migrated the legacy tools/fleet/ out of pi's boot-blocking namespace (#1277)"
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
  say "pi spawn-point gate installed at $dst (#1884)"
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
    say "verified $farm_n declared farm file(s) against the checkout"
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
        say "verified $retired_n declared retirement(s) absent from the cell"
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
          say "verified the farm declaration snapshot against the checkout's declared set"
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

  local entries
  entries="$(read_manifest_entries)" || { fail "the extension ship-list could not be re-read from manifest.json"; return 0; }
  if [ "$(printf '%s\n' "$entries" | grep -c . || true)" -lt "$MIN_SHIP_LIST" ]; then
    fail "manifest.json's extension ship-list re-read as fewer than $MIN_SHIP_LIST entries — verify would be checking a truncated list"
    return 0
  fi
  while IFS= read -r base; do
    [ -n "$base" ] || continue
    if denied_extension "$base"; then
      # Same predicate as the install half: `-e` follows a symlink, so a DANGLING link at this
      # path is invisible to it and the deny would certify exactly what it exists to refuse.
      if [ -e "$DEST/extensions/$base" ] || [ -L "$DEST/extensions/$base" ]; then
        fail "denied extension is PRESENT on the cell: extensions/$base"
      fi
      continue
    fi
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
    say "verified $seen_dep extension(s) that declare runtime deps"
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
      0) say "verified the skills tree against the checkout" ;;
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

  guard_tools_dir
  guard_spawn_gate

  if [ "$FAILURES" -eq 0 ]; then
    say "LAYER VERIFIED — $DEST carries the farmed scripts, the guards, the skills and the config"
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
