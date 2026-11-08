#!/usr/bin/env bash
# cell-home.sh — THE one derivation of a cell's home (agent-infra#3453). One rule, one reader.
#
# ⛔ THE FAILURE THIS PREVENTS, MEASURED TWICE. A cell ran with TWO homes and the units disagreed
# about which one a process gets:
#
#   /etc/systemd/system/eldato-orchestrator.service   HOME=/home/cmux        <- the unit that SPAWNS lanes
#   /etc/systemd/system/cell-self-pin.service.d/…     HOME=/tmp/cell-home    <- every other cell service
#
# `gh` resolves its credential `GH_TOKEN` -> `GITHUB_TOKEN` -> `$HOME/.config/gh/hosts.yml`, and `git`
# inherits that through `credential.helper = !gh auth git-credential`, so the two conventions resolved
# two DIFFERENT credentials and a 17-lane wave produced **0 landings**: every lane got a fine-grained
# PAT with `contents=read`, so `git push` answered `403 … X-Accepted-Github-Permissions: contents=write`
# while `gh` READS still worked — which reads like an account problem and sent lanes hunting for a token
# to mint while a working credential was already on the box.
#
# The second consequence is capacity: `/tmp/cell-home` was the `HOME=` of 9 unit files on cell-4 and 7 on
# cell-3 and holds ~23 GB on each, on the SAME filesystem as `/` (measured 2026-11-06: 213G used, 28G
# free). `runner_autoscale.py` budgets 8 GB per runner against a 20 GB reserve, so those cells sit at
# `by_disk=1` and the ceiling cannot rise while the second home holds the space.
#
# ── THE RULE ────────────────────────────────────────────────────────────────────────────────────
# A cell has ONE home. It is the DURABLE one — the account's own home directory — and it is DERIVED,
# never spelled out at each call site. In precedence order:
#
#   1. `${CELL_HOME}` — an explicit override always wins (operator, unit Environment=, installer).
#   2. the account's home from the passwd record (`/home/cmux` on a cell, `/Users/<you>` on a laptop).
#      This is the honest answer even when `$HOME` is not: `cmux vm exec` hands over `HOME=/home/ubuntu`,
#      a directory that does not exist on the image. Same ordering `cloud-cell-bringup.sh::_one_home_want`
#      already uses for its `--check` gate — this file is that derivation given ONE home instead of two.
#   3. `${HOME_ORIG}` / `${HOME}` — only when the value is absolute and NOT under a volatile root.
#   4. `CELL_HOME_FLEET_DEFAULT` — the fleet's durable cell home. ⛔ THIS IS THE ONLY PLACE THE LITERAL
#      LIVES. A second copy of it is the defect this file exists to remove, so a consumer that needs a
#      default CONSUMES this resolver (see the pin in scripts/cell-home.test.sh).
#
# `/tmp/cell-home` is NEVER derived. It is the LEGACY volatile home: kept (never deleted by this change),
# reported, and reclaimable only after every unit repoints AND a lane proves `push=OK` + `provider=OK`
# from a clean shell with nothing sourced. `CELL_HOME_LEGACY` names it so the migration can speak about
# it without a second literal in every script.
#
# ── WHAT A CONSUMER DOES ────────────────────────────────────────────────────────────────────────
#   . "$(dirname "${BASH_SOURCE[0]}")/lib/cell-home.sh" || exit 78
#   CELL_HOME="$(cell_home_resolve)"          # 0 = resolved; it always prints one line
#   ENV_FILE="${ENV_FILE:-$CELL_HOME/keys.env}"
#
# Exit 78 (EX_CONFIG) on a missing sibling is deliberate: a script that cannot find this file must not
# invent a home, because inventing one is the defect. The file is declared in `pi-bootstrap/setup.sh`'s
# `lib_srcs`, so a farm delivers it to `$HOME/.pi/agent/scripts/lib/cell-home.sh` next to every consumer
# that is farmed, and a checkout or a pinned harness worktree carries it at `<repo>/scripts/lib/`.
#
# ── NOT A GATE ──────────────────────────────────────────────────────────────────────────────────
# This file does not decide whether a box is compliant, and it repairs nothing. The gate that REFUSES a
# two-home box is `cloud-cell-bringup.sh::check_one_home` (`--check`), the repointing/migration tool is
# `cell-home-migrate.sh`, and the `--status` report of what a box currently runs is
# `cloud-cell-supervisor.sh status`. One question, one reader.

# The fleet's durable cell home. ⛔ The single literal (see the header).
CELL_HOME_FLEET_DEFAULT="${CELL_HOME_FLEET_DEFAULT:-/home/cmux}"

# The LEGACY volatile home. Named, never derived, never deleted by this change.
CELL_HOME_LEGACY="${CELL_HOME_LEGACY:-/tmp/cell-home}"

# Roots a cell's DURABLE state must not live in. Overridable so a hermetic suite can grade its own
# temp-dir home without grading the host (the same fixture seam `cloud-cell-bringup.sh` declares).
CELL_HOME_VOLATILE_ROOTS="${CELL_HOME_VOLATILE_ROOTS:-/tmp:/var/tmp}"

# cell_home_under_volatile <path> — 0 iff <path> is absolute AND under one of $CELL_HOME_VOLATILE_ROOTS.
cell_home_under_volatile() {
  local p="${1:-}" root
  case "$p" in /*) ;; *) return 1 ;; esac
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    case "$p" in "$root"|"$root"/*) return 0 ;; esac
  done <<EOF
$(printf '%s' "$CELL_HOME_VOLATILE_ROOTS" | tr ':' '\n')
EOF
  return 1
}

# cell_home_account_home — the passwd record's home for the account running this code.
# `getent` is Linux; `dscl`-less macOS answers via `cd ~user`. Both are tried, in that order: `cd ~user`
# is the portable fallback `cloud-cell-bringup.sh` already uses for the same question.
cell_home_account_home() {
  local u acct=""
  u="$(id -un 2>/dev/null || printf '%s' "${USER:-}")"
  [ -n "$u" ] || return 1
  if command -v getent >/dev/null 2>&1; then
    acct="$(getent passwd "$u" 2>/dev/null | awk -F: 'NR==1{print $6}')"
  fi
  [ -n "$acct" ] || acct="$(cd ~"$u" 2>/dev/null && pwd -P)"
  [ -n "$acct" ] || return 1
  printf '%s\n' "$acct"
}

# cell_home_resolve — print the ONE home for this box. Always prints exactly one line; never fails.
# The precedence is the header's list, in the header's order — including the two checks that make it
# a DERIVATION rather than a preference: a value that is not absolute, or that sits under a volatile
# root, is not a durable home and is skipped rather than trusted.
cell_home_resolve() {
  local v=""
  # 1. explicit override — always wins, even if it is under a volatile root (an operator running a
  #    fixture or a migration on a scratch home must get the home they named, not a correction).
  if [ -n "${CELL_HOME:-}" ]; then
    printf '%s\n' "$CELL_HOME"; return 0
  fi
  # 2. the account's home — the durable answer, and the reason this file exists.
  v="$(cell_home_account_home || true)"
  if [ -n "$v" ]; then printf '%s\n' "$v"; return 0; fi
  # 3. HOME_ORIG (the pre-override value) then HOME, each only when it is a plausible durable home.
  for v in "${HOME_ORIG:-}" "${HOME:-}"; do
    case "$v" in /*) ;; *) continue ;; esac
    cell_home_under_volatile "$v" && continue
    printf '%s\n' "$v"; return 0
  done
  # 4. the fleet default — the last resort, and the only literal.
  printf '%s\n' "$CELL_HOME_FLEET_DEFAULT"
}

# cell_home_project <home> — the home a value BELONGS to when it is re-based onto <home>.
# Prints the re-based path when <value> is under $CELL_HOME_LEGACY, else prints <value> unchanged.
# This is what the migration uses, so "which paths move" is answered here and not in the rewriter.
cell_home_project() { # <home> <value>
  local home="${1:-}" val="${2:-}"
  [ -n "$home" ] && [ -n "$val" ] || { printf '%s\n' "$val"; return 0; }
  case "$val" in
    "$CELL_HOME_LEGACY") printf '%s\n' "$home" ;;
    "$CELL_HOME_LEGACY"/*) printf '%s\n' "$home${val#"$CELL_HOME_LEGACY"}" ;;
    *) printf '%s\n' "$val" ;;
  esac
}
