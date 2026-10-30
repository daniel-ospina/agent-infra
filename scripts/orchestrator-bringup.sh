#!/usr/bin/env bash
# orchestrator-bringup.sh — ONE entry point for the orchestrator stack on THIS machine.
#
#   bash scripts/orchestrator-bringup.sh check            # is this machine configured for this repo?
#   bash scripts/orchestrator-bringup.sh start            # bring the whole stack up
#   bash scripts/orchestrator-bringup.sh stop
#   bash scripts/orchestrator-bringup.sh restart          # stop, then start, then verify
#   bash scripts/orchestrator-bringup.sh status           # + the FLEET COMPONENT TABLE
#   bash scripts/orchestrator-bringup.sh --reseed [verb]  # regenerate the machine-local config, then verb
#   bash scripts/orchestrator-bringup.sh start --prune    # …and REMOVE unshipped files from $O. Never
#                                                        # one that something resolves BY PATH (#2059)
#   bash scripts/orchestrator-bringup.sh start --accept-discard
#                                                        # …even though $O carries UNCOMMITTED EDITS this
#                                                        # deploy would overwrite. Refused by default:
#                                                        # those bytes exist nowhere else (#3049)
#
# `start`/`stop`/`status` cover the WHOLE FLEET, not only the controller: the inventory (ONE declared
# list of components, each with its own liveness predicate) lives in lib/fleet-inventory.sh. `status`
# prints COMPONENT | EXPECTED | ACTUAL | STATE for every one of them and EXITS with the worst row's
# verdict, so a component that is off, missing or running twice cannot hide behind the controller
# being healthy (owner, 2026-10-18).
#
# ⛔ VERB CONTRACT, unchanged and now shared by the table: 0 ok · 1 refused / a component is not ok ·
# 2 cannot-determine. SKIPPED rows (a component that does not apply to this box) are a PASS with a
# reason — never silently OK.
#
# Exit codes, for every verb:
#   0  ok
#   1  REFUSED — one actionable line on stderr; nothing was started.
#      For `status` and `start` it ALSO means "a component is not OK" (`status`) or "a component this
#      verb ATTEMPTED did not come up, or a live one must be reconciled by hand" (`start`). The two
#      meanings are distinguishable from the output — a refusal is one line on stderr and starts
#      nothing; a component verdict is a table row — and `status` is the verb whose exit code is the
#      FLEET's verdict, while `start`'s is about what it attempted.
#   2  CANNOT DETERMINE — fail closed; the gate could not answer, which is never a pass
#
# ── WHY THIS FILE EXISTS (agent-infra#1761) ─────────────────────────────────────────────────────
# Bringing a box up was five commands in an order an operator had to remember, on two platforms with
# different mechanisms: on a Mac `install.sh` renders a launchd plist and the loop is started by
# `launchctl`; on a cloud cell `cloud-cell-supervisor.sh apply` pins the harness and `start` opens a
# tmux session. Every one of those commands had its own preconditions and its own failure vocabulary,
# and the failures they share are all SILENT: a controller that runs one cycle and dispatches nothing,
# a queue read from a repo the box is not standing in, a cell whose refresh aborts every cycle.
#
# Two things were missing, and both are about refusing rather than about launching:
#
#  1. ONE PLACE THAT ASKS "CAN THIS MACHINE RUN A CONTROLLER FOR THIS REPO?" and answers with an exit
#     code. `check` is that, and it starts nothing.
#
#  2. A REDUNDANCY GUARD KEYED ON THE REPO, NOT ON THE STATE DIR. `cloud-cell-supervisor.sh` keys
#     ownership on `$O`, which is necessary but not sufficient: two state dirs on one machine running
#     the SAME repo read perfectly healthy and both drain the same queue. The owner's requirement has
#     two halves and the second is easy to lose — "at some point I might want in the same machine an
#     orchestrator for repo A and an orchestrator for repo B, so that needs to be possible".
#     So the identity is the PAIR: (machine, repo) gets at most one live controller; different repos
#     on one machine never block each other. See lib/orchestrator-registry.sh.
#
# ── THE DEFECT THIS GATE MUST CATCH, MEASURED ──────────────────────────────────────────────────
# On a cell, `refresh-candidates.sh` aborted every cycle with:
#
#     cd: /Users/danielospina/Documents/GitHub/tortoise: No such file or directory
#     [refresh] ABORT: repo not found at /Users/danielospina/Documents/GitHub/tortoise
#
# …because the harness ships a MACHINE-SPECIFIC default for the repo path and nothing on the cell
# contradicted it. The controller kept a fresh heartbeat and one loop the whole time: it LOOKED alive
# and dispatched nothing, so every observable except the work itself was green. A configured repo
# path that does not exist on THIS machine is therefore a REFUSAL here, naming the path, and
# `--reseed` is the repair — it regenerates the machine-local config from the checkouts that are
# actually on this disk, and it touches nothing that holds state (the lock, $O/state, the claim refs
# under the repo, the candidate files).
#
# ── WHAT THIS FILE DELIBERATELY DOES NOT DO ────────────────────────────────────────────────────
#   * It does not re-implement the platform verbs. `install.sh` renders and validates the plist;
#     `cloud-cell-supervisor.sh` pins, seeds and starts. Those stay the authority for their platform,
#     and this file calls them. One authority per question is what keeps `check` and `start` from
#     disagreeing, which is the failure #1745 measured (`check` green while `start` died).
#   * It does not kill a process its registry does not own. A live pid whose command line is not an
#     `orch-loop.sh` is REPORTED and the start is refused; the record stays for a human to read.
#   * It does not decide anything about the OWNER (which repos exist, which $O is canonical): it
#     reads, refuses, and says which fact it could not read.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/orchestrator-registry.sh
. "$HERE/lib/orchestrator-registry.sh"

LABEL="com.eldato.orchestrator-loop"

log_line()  { printf '%s\n' "$*"; }
ok()   { printf 'ok: %s\n' "$*"; }
warn() { printf 'warn: %s\n' "$*" >&2; }
# A refusal is ONE line: the actionable sentence, on stderr, with rc=1. Anything the operator needs
# beyond that is printed by the caller before it refuses (never after — a message after the refusal
# is a message nobody reads, because the tool has already exited).
refuse()  { printf 'bringup: REFUSED: %s\n' "$1" >&2; exit 1; }
unknown() { printf 'bringup: CANNOT DETERMINE: %s\n' "$1" >&2; exit 2; }

usage() { # <exit-code>
  sed -n '2,/^set -uo pipefail$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; $d'
  # ⛔ NOT always 0: an unusable command line is a REFUSAL (exit 1) under this file's own contract
  # (0 ok · 1 refused · 2 cannot-determine). `usage` with a bad argument used to exit 0 after
  # printing the header — so `start --force` (a flag the SUPERVISOR's apply accepts, the natural
  # mistake) reported success having started nothing (#1856 review, reproduced).
  exit "${1:-0}"
}

VERB=""; RESEED=0; PRUNE=0; ACCEPT_DISCARD=0
for a in "$@"; do
  case "$a" in
    check|start|stop|restart|status) VERB="$a" ;;
    --reseed)               RESEED=1 ;;
    # ⛔ A FLAG, NOT AN ENV DEFAULT — deliberately, and unlike `deploy-mac-orchestrator.sh`, which reads
    # `ACCEPT_DISCARD=1` from the environment because its PHASE/WAIT/DRY_RUN are env too. This is the
    # verb an operator runs by hand on the box whose live tree carries a patch; a variable exported
    # once in a profile, or set by a wrapper that drives the mac deploy, must not quietly disarm the
    # refusal that protects that patch. `deploy-harness.sh` was fixed to the same rule for the same
    # reason: a gate that a stray `export` can switch off is not a gate.
    --accept-discard)       ACCEPT_DISCARD=1 ;;
    # ⛔ OFF unless asked for. A deploy no longer deletes anything from the live tree by default
    # (#2059): the mirror ran `rm -f` over every `$O/*.sh` the checkout does not ship, which is
    # exactly the files this box's launchd job and armed schedules resolve BY PATH.
    --prune)                PRUNE=1 ;;
    -h|--help)              usage 0 ;;
    *) printf 'bringup: unknown argument %s\n' "$a" >&2; usage 1 ;;
  esac
done
[ -n "$VERB" ] || VERB="check"

# ── platform ─────────────────────────────────────────────────────────────────────────────────────
# Two mechanisms, one entry point. Anything that is neither is refused rather than guessed: a third
# branch would have to invent a start mechanism, and a start mechanism nobody has validated is how a
# box ends up with a controller nothing can stop.
case "$(uname -s)" in
  Darwin) PLATFORM="mac" ;;
  Linux)  PLATFORM="cell" ;;
  *)      unknown "unsupported platform $(uname -s) — this entry point knows launchd (Darwin) and the tmux cell (Linux)" ;;
esac

# ⛔ `O` from the ENVIRONMENT, captured BEFORE the platform default below. The config file's `O=` may
# only fill a value NOBODY set: capturing it after the default makes the provenance test always true,
# so the arm is dead and this surface reads a state dir the controller never uses
# (cloud-cell-supervisor.sh DOES honour `O=` in keys.env) — two surfaces disagreeing about which
# directory holds the lock is the #1745 class, and it was found in review of #1856.
O_ENV="${O:-}"
CELL_HOME_ENV="${CELL_HOME:-}"                 # only the ENVIRONMENT value is evidence of a cell
CELL_HOME="${CELL_HOME:-/tmp/cell-home}"
if [ "$PLATFORM" = "cell" ]; then
  # The cell's own home. `cloud-cell-bringup.sh` documents why it is not /home/ubuntu (which does not
  # exist on the image), so the default here is the one that script provisions.
  ENV_FILE="${ENV_FILE:-$CELL_HOME/keys.env}"
  O="${O:-$CELL_HOME/orchestrator}"
  HARNESS_PIN_DIR="${HARNESS_PIN_DIR:-$CELL_HOME/harness}"
  HARNESS_PIN_FILE="${HARNESS_PIN_FILE:-$CELL_HOME/.harness-path}"
  SUPERVISOR="$HERE/cloud-cell-supervisor.sh"
  # ⛔ HOME MUST BE THE CELL'S HOME, for the same measured reason cloud-cell-supervisor.sh
  # re-asserts it after sourcing keys.env: `cmux vm exec` runs as a user whose $HOME (/home/ubuntu)
  # does not exist on the image, and gh keeps its credentials in $HOME/.config/gh — so a
  # `gh auth status` under the exec home answers "not logged in" while the CELL is logged in, and
  # `check` would refuse a perfectly good cell (or worse, a `start` would launch a controller whose
  # every gh call fails). Every read below — gh, git, the registry — must run under the cell's home.
  export HOME="$CELL_HOME"
  # A cell states its own identity for the inventory: the entry point is the ONE place that knows
  # whether it is running as a cell (`CELL_HOME` from the environment, or a provisioned cell home).
  # The default above is a fallback PATH, not proof — exporting it unconditionally made every Linux
  # box look like a cell and killed the inventory's identity branch (cycle-4 review).
  case "${CELL_HOME_ENV:-}" in
    '') : ;;                                     # defaulted: no evidence from the environment
    *) export FLEET_CELL_HOME="${FLEET_CELL_HOME:-$CELL_HOME}" ;;
  esac
else
  ENV_FILE="${ENV_FILE:-$HOME/.config/orchestrator/bringup.env}"
  O="${O:-$HOME/orchestrator}"
  # ── THE MAC'S PIN RECORDS (agent-infra#2231, mac pin parity) ────────────────────────────────────
  # These were CELL-ONLY, and that is the whole divergence this closes: `harness_ctl_path()` below
  # prefers `HARNESS_PIN_FILE` when it is set, so on a Mac it always fell back to
  # `$HARNESS_BRINGUP` — the checkout the operator happened to run this from — and `deploy_harness`
  # seeded `$O` from THAT. So the Mac had no pin record to read, reported `harness: <checkout>` in
  # `status`, and answered "which commit is this box on?" differently from every cell.
  # The same three spellings the cells use, under the Mac's own home: `~/.pi/agent/state/HARNESS-PIN`
  # (sha), `~/.harness-path` (the dir the controller execs) and `~/harness` (the per-commit worktrees).
  # ⛔ `~/harness`, NOT a path under `~/Documents`: launchd's bash is TCC-blocked from reading
  # ~/Documents (the recorded reason setup.sh COPIES instead of symlinking, #427), so a pin root there
  # would be unreadable by the very job that must exec it.
  HARNESS_PIN_DIR="${HARNESS_PIN_DIR:-$HOME/harness}"
  HARNESS_PIN_FILE="${HARNESS_PIN_FILE:-$HOME/.harness-path}"
  # What `deploy_harness` seeds `$O` FROM. A pin that exists and can be read wins, because the
  # controller execs THAT tree and the two surfaces must be one commit. An absent or unreadable record
  # is NOT a rebind: `deploy_harness` then falls back to `$HARNESS_BRINGUP` exactly as before, so a
  # box that has not been pinned yet still starts (and install.sh is what creates the pin).
  HARNESS_SEED=""
  if [ -f "$HARNESS_PIN_FILE" ] && [ -r "$HARNESS_PIN_FILE" ]; then
    _seed_pin="$(head -1 "$HARNESS_PIN_FILE" 2>/dev/null)"
    if [ -n "$_seed_pin" ] && [ -d "$_seed_pin" ]; then HARNESS_SEED="$_seed_pin"; fi
  fi
  SUPERVISOR=""
fi
# Which harness directory to consult. Defaults to the sibling `orchestrator-harness/` of this
# script — the layout both a checkout and a cell pin have — and is overridable so a box can be driven
# against another copy (a pinned worktree, or a hermetic fixture in the test suite). It is a READ
# source only: nothing is written there.
HARNESS_BRINGUP="${HARNESS_DIR:-$HERE/orchestrator-harness}"

# ── config resolution ───────────────────────────────────────────────────────────────────────────
# Each of REPO/OR/O can come from the environment, from this machine's config file, or from the
# harness's own default. WHICH ONE IT CAME FROM is part of the answer, because the harness default is
# another machine's absolute path: "REPO=/Users/danielospina/Documents/GitHub/tortoise" is not a typo
# an operator made, it is a value nobody set, and the refusal has to say so or the operator goes
# looking for the line that set it.
REPO_SRC="env"; [ -n "${REPO:-}" ] || REPO_SRC=""
OR_SRC="env";   [ -n "${OR:-}" ]   || OR_SRC=""

# env_file_value <key> — one variable as THIS machine's config file sets it. The file is evaluated in
# a SUBSHELL, and the value captured only for the named key: a config file that sets fifty variables
# must not reach this shell, and a file whose last line is `exit 0` must not end the bring-up (the
# same measured failure `source_env_file` in cloud-cell-supervisor.sh guards against).
env_file_value() {
  local k="${1:?}" f="${2:-}"
  [ -f "$f" ] || return 0
  bash -c 'set -a; . "$1" >/dev/null 2>&1; printf "%s" "${!2:-}"' _ "$f" "$k" 2>/dev/null || true
}

load_config_file() {
  [ -f "$ENV_FILE" ] || return 0
  local v
  if [ -z "${REPO:-}" ]; then v="$(env_file_value REPO "$ENV_FILE")"; [ -n "$v" ] && { REPO="$v"; REPO_SRC="config file $ENV_FILE"; }; fi
  if [ -z "${OR:-}" ];   then v="$(env_file_value OR   "$ENV_FILE")"; [ -n "$v" ] && { OR="$v";   OR_SRC="config file $ENV_FILE"; }; fi
  if [ -z "${O_ENV:-}" ]; then v="$(env_file_value O "$ENV_FILE")"; [ -n "$v" ] && { O="$v"; O_SRC="config file $ENV_FILE"; }; fi
  return 0
}
O_SRC="${O_ENV:+env}"; [ -n "$O_SRC" ] || O_SRC="platform default"
O_DEFAULT="$O"
load_config_file

# ── the fleet inventory (the ONE declared list of components) ────────────────────────────────────
# Sourced AFTER the config resolution above, so the seams below carry THIS machine's resolved answer
# rather than a second default: `FLEET_O` is the same `O` the controller's lock lives in, and
# `FLEET_PLATFORM` is the platform this file already refused-or-accepted. A library that re-derived
# either would be a second authority about which directory holds the lock — the #1745 class.
FLEET_O="${FLEET_O:-$O}"
FLEET_PLATFORM="${FLEET_PLATFORM:-$PLATFORM}"
FLEET_CELL_SUPERVISOR="${FLEET_CELL_SUPERVISOR:-$SUPERVISOR}"
# shellcheck source=lib/fleet-inventory.sh
. "$HERE/lib/fleet-inventory.sh"

# The repo identity this machine is configured for, as `<owner>/<repo>`.
SLUG=""; SLUG_REPO=""

# ── SCOPED process reads ───────────────────────────────────────────────────────────────────────
# ⛔ Every read below is scoped to THIS state dir's own orch-loop.sh path AND the harness path this
# machine actually runs it from, never a bare `pgrep -f orch-loop.sh`. Measured 2026-10-15: an
# unscoped read matched FOUR controllers on a dev box — this box's real controller, a leaked test
# fixture, and two of a peer lane's own test — and a destructive verb driven by that read would have
# killed a peer's work. Descendants are excluded for the same measured reason (`orch-loop.sh` spawns
# children whose command line also matches).
#
# ⛔ BOTH PATHS ARE REQUIRED, and that is not belt-and-braces: MEASURED 2026-10-17 on `pi-cell-2`, the
# controller's argv is
#   bash /tmp/bringup-1761/scripts/orchestrator-harness/orch-loop.sh
# — the HARNESS path, NOT `$O/orch-loop.sh`. `$O` is seeded so the WORKERS (fix-one.sh, merge-one.sh)
# can be invoked from it; the controller itself execs the harness it was started from. A read scoped
# to `$O` alone therefore found NO controller on a cell that was busy spawning lanes, and `status`
# reported "no orch-loop.sh pid observed yet" over a live loop (the same false-STOPPED class #1761 is
# about, one path further in).
harness_ctl_path() {
  local p="" pin="${HARNESS_PIN_FILE:-}"
  if [ -n "${HARNESS:-}" ]; then printf '%s\n' "$HARNESS"; return 0; fi
  # ⛔ `${HARNESS_PIN_FILE:-}`: the pin is a CELL concept and the variable is assigned only in the
  # cell branch, so on the Mac path a bare "$HARNESS_PIN_FILE" ABORTED this command substitution under
  # `set -u` — the harness-path scope silently vanished and every Mac run printed `unbound variable`
  # into a read that then reported STOPPED (#1856 review, reproduced).
  [ -n "$pin" ] && [ -f "$pin" ] && p="$(head -1 "$pin" 2>/dev/null)"
  [ -n "$p" ] || p="$HARNESS_BRINGUP"
  printf '%s\n' "$p"
}
# Controller pids, in two SCOPEs — the distinction is load-bearing (#1856 review).
#
# state_dir_pids — processes running THIS state dir's own `orch-loop.sh`. Nothing else is asserted.
# local_controller_pids — the REPORTING read: the above plus anything running the harness path this
#   machine executes the loop from. ⛔ That harness path is one directory per cell home
#   (`$CELL_HOME/harness`), so TWO REPOS ON ONE MACHINE SHARE IT and this read returns repo A's
#   controller to repo B. It may be reported; it may never witness "this repo is running".
# owned_pids — what this state dir may CLAIM and SIGNAL: the lock owner plus state_dir_pids.
# The scope predicate itself. A QUOTED heredoc, not a single-quoted variable: the program contains
# "" and $1, and re-expanding a variable would hand awk a mangled program (which fails the read and
# reads as "no controller" — a false STOPPED, the exact class this file exists to prevent).
_ps_scope_awk() {
  cat <<'AWK'
  { ppid[$1]=$2; c=$0; sub(/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+/,"",c)
    n=split(c,tok," ")
    if (n>=2 && (tok[2]==a || (b!="" && tok[2]==b)) && tok[1] ~ /(bash|sh|dash|zsh)$/) m[$1]=1 }
  END { for (p in m) { q=p; d=0
          for (i=0;i<64;i++) { if (!(q in ppid) || ppid[q]<=1) break; q=ppid[q]; if (q in m) { d=1; break } }
          if (!d) print p } }
AWK
}
_ps_scoped() { # <primary-path> <extra-path-or-empty>; rc 1 when ps cannot answer
  local t prog
  t="$(ps -eo pid=,ppid=,command= 2>/dev/null)" || return 1
  case "$t" in *[![:space:]]*) ;; *) return 1 ;; esac
  prog="$(_ps_scope_awk)"
  printf '%s\n' "$t" | awk -v a="$1" -v b="$2" "$prog" || return 1
}
state_dir_pids() { _ps_scoped "$O/orch-loop.sh" ""; }
local_controller_pids() {
  _ps_scoped "$O/orch-loop.sh" "$(harness_ctl_path)/orch-loop.sh"
}
owned_pids() {
  local a b rc
  a="$(state_dir_pids)" || return 2
  b="$(lock_pid)"; rc=$?
  case "$rc" in 0) ;; 1) b="" ;; *) return 2 ;; esac
  printf '%s\n%s\n' "$a" "$b" | awk 'NF && !s[$0]++'
}
# lock_pid — the pid $O/.orch.lock names, when it is alive, IS an orch-loop.sh INVOCATION, and cannot
# have begun after the lock was written.
#
# ⛔ THIS IS THE SUPERVISOR'S PREDICATE, NOT A SUBSTRING MATCH. The previous form (`case "$c" in
# *orch-loop.sh*`) was exactly the shape cloud-cell-supervisor.sh's `lock_controller_pid` documents as
# a P0 it just fixed — and this file then used it twice: `check` printed a FALSE PASS naming a foreign
# pid as the lock owner, and `start_cell`'s fallback could persist that pid into the registry, where
# it reads `live` forever and every later start refuses until a human hand-edits the record (the
# #8175 class). A predicate that feeds a durable record must be the strict one (#1856 review).
lock_pid() {
  local p lt
  p="$(tr -dc '0-9' 2>/dev/null < "$O/.orch.lock")"
  [ -n "$p" ] || return 0
  kill -0 "$p" 2>/dev/null || return 0
  registry_pid_is_controller "$p" || return 0
  lt="$(date -r "$O/.orch.lock" +%s 2>/dev/null)" || return 0
  [ -n "$lt" ] || return 0
  # ⛔ THREE OUTCOMES. 0 = began after the lock (a recycled pid — not ours), 1 = began before (ours),
  # 2 = the age CANNOT BE READ. Folding 2 into 1 made an unreadable age the strongest evidence of
  # ownership and `stop`/`check` then acted on a pid they could not date (#1856 review, reproduced
  # with an etime-failing PS_BIN); 2 is propagated so every caller fails closed.
  pid_began_after "$p" "$lt"
  case $? in
    0) return 0 ;;
    1) ;;
    *) return 2 ;;
  esac
  printf '%s\n' "$p"
}
pids_join() { printf '%s' "$1" | tr '\n' ' ' | sed 's/ *$//'; }

# ── repo identity ───────────────────────────────────────────────────────────────────────────────
# The queue's repo and the checkout are ONE fact (agent-infra#1901): the checkout's `origin` is what
# the machine can actually read, and an explicit OR is an override that must MATCH it. This file
# refuses the pair, and cloud-cell-supervisor.sh refuses it again on the start path — the duplication
# is deliberate on a REFUSAL (each surface must be safe on its own); what must never be duplicated is
# a PASS.
#
# ⛔ IT RETURNS; IT DOES NOT EXIT. `status` and `stop` call it too, and they must stay ANSWERABLE —
# the supervisor's own tested rule ("status: a MISMATCH is reported, not refused"). While this
# function refused by exiting, those two verbs died SILENTLY (the caller discarded stderr) and
# returned 1 printing nothing at all, so `status` — the one screen an operator reads — was a black
# hole on exactly the misconfigured machine it exists to explain (#1856 review, reproduced).
IDENTITY_MSG=""
resolve_repo_identity() { # 0 ok · 1 refused/cannot-derive, with IDENTITY_MSG set
  IDENTITY_MSG=""
  [ -n "${REPO:-}" ] || { IDENTITY_MSG="no repo is configured for this machine"; return 1; }
  if [ -n "${OR:-}" ]; then
    repo_matches_checkout "$OR" "$REPO"; local rc=$?
    case "$rc" in
      0) SLUG_REPO="$OR"; return 0 ;;
      1) IDENTITY_MSG="the queue repo and the checkout name DIFFERENT repos: OR=$OR but $REPO is a checkout of '$(repo_of_checkout "$REPO" 2>/dev/null || printf '?')' (origin $(git -C "$REPO" remote get-url origin 2>/dev/null)) — set OR to the checkout's repo, or point REPO at an $OR checkout"; return 1 ;;
      *) IDENTITY_MSG="cannot read the 'origin' remote of $REPO, so OR=$OR cannot be verified against it — a queue target that cannot be checked is never a pass (agent-infra#1901); fix the checkout's remote or unset OR to derive it"; return 1 ;;
    esac
  fi
  SLUG_REPO="$(repo_of_checkout "$REPO")" \
    || { IDENTITY_MSG="cannot derive the repo identity from $REPO — its 'origin' remote is missing or does not name <owner>/<repo> in an accepted form (https://, http://, ssh://, or git@host:owner/repo.git), so this machine cannot say which repo it would control"; return 1; }
  return 0
}

# ── the machine-local config (--reseed) ────────────────────────────────────────────────────────
# `--reseed` answers ONE failure: a config whose repo path belongs to another machine. It rewrites
# the machine-local lines from what is on THIS disk, and it is deliberately not a `reset`: the lock,
# $O/state, the candidate files and the repo's claim refs are untouched, because they are the state a
# restart is supposed to PRESERVE. Every other line of the config file — every secret in it — is
# carried over byte for byte.
reseed_candidates() {
  if [ "$PLATFORM" = "cell" ]; then
    printf '%s\n' "$CELL_HOME/clone" "$CELL_HOME/repo" "$CELL_HOME"/cell-* /tmp/cell-ai /tmp/cell-t /tmp/cell "$CELL_HOME"
  else
    printf '%s\n' "$HOME"/Documents/GitHub/*/ "$HOME"/GitHub/*/
  fi
}

cmd_reseed() {
  log_line "==> reseed: deriving the machine-local config from the checkouts on this disk"
  local found="" d n=0 want="${OR:-}"
  # An explicit REPO wins when it is genuinely usable here; discovery is the repair for the case where
  # nobody has a usable value (the measured one). Discovery is BOUNDED — a fixed list plus one
  # non-recursive glob — because a recursive search for checkouts is the fleet's most expensive habit.
  if [ -n "${REPO:-}" ] && git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
    found="$REPO"; n=1
  else
    while IFS= read -r d; do
      [ -n "$d" ] || continue
      d="${d%/}"
      git -C "$d" rev-parse --git-dir >/dev/null 2>&1 || continue
      if [ -n "$want" ]; then
        repo_matches_checkout "$want" "$d" || continue
      fi
      case " $found " in *" $d "*) continue ;; esac
      found="${found:+$found }$d"; n=$((n + 1))
    done <<EOF
$(reseed_candidates)
EOF
  fi
  case "$n" in
    0) unknown "no local checkout${want:+ of $want} found on this machine (looked at: $(reseed_candidates | tr '\n' ' ' | sed 's/ *$//')) — clone it first, or pass REPO=<path>" ;;
    1) : ;;   # exactly one checkout: nothing to decide (NOT `::`, which is a command and errors)
    *)
      # Two checkouts of the same repo is not a decision this script may make: they can be at
      # different commits, and picking one silently is how a box ends up running the wrong tree.
      unknown "more than one local checkout${want:+ of $want} matches (${found// /, }) — pass REPO=<path> to name the one this machine should control" ;;
  esac
  local repo_path="$found" derived
  derived="$(repo_of_checkout "$repo_path")" \
    || unknown "the checkout $repo_path has no readable 'origin' remote naming <owner>/<repo>, so its identity cannot be recorded"
  if [ -n "$want" ] && [ "$derived" != "$want" ]; then
    unknown "the checkout $repo_path is $derived but OR=$want — refusing to record a pair that names two repos"
  fi

  local bak="" tmp
  if [ -f "$ENV_FILE" ]; then
    bak="$ENV_FILE.bak-$(date +%s)"
    cp -p "$ENV_FILE" "$bak" || refuse "cannot back up $ENV_FILE to $bak — refusing to rewrite a config this machine cannot preserve"
  fi
  mkdir -p "$(dirname "$ENV_FILE")" || refuse "cannot create $(dirname "$ENV_FILE")"
  tmp="$ENV_FILE.tmp.$$"
  # Carry over everything that is not one of OUR lines. `REPO=` in a config file is a machine fact, so
  # it is regenerated; a key the operator added is not ours to touch.
  {
    if [ -f "$ENV_FILE" ]; then
      while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
          REPO=*|OR=*|O=*|CELL_HOME=*|HARNESS_PIN_DIR=*|HARNESS_PIN_FILE=*) continue ;;
        esac
        printf '%s\n' "$line"
      done < "$ENV_FILE"
    fi
    printf 'REPO=%s\n' "$repo_path"
    printf 'OR=%s\n' "$derived"
    printf 'O=%s\n' "$O"
    if [ "$PLATFORM" = "cell" ]; then
      printf 'CELL_HOME=%s\n' "$CELL_HOME"
      printf 'HARNESS_PIN_DIR=%s\n' "$HARNESS_PIN_DIR"
      printf 'HARNESS_PIN_FILE=%s\n' "$HARNESS_PIN_FILE"
    fi
  } > "$tmp" || { rm -f "$tmp"; refuse "cannot write the reseeded config to $tmp"; }
  # The config holds keys. Keep it private, and keep the BACKUP private too — a 0644 backup of a
  # 0600 secret file is a credential disclosure that looks like tidiness.
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$ENV_FILE" || { rm -f "$tmp"; refuse "cannot install the reseeded config at $ENV_FILE"; }
  [ -z "$bak" ] || chmod 600 "$bak" 2>/dev/null || true
  REPO="$repo_path"; REPO_SRC="config file $ENV_FILE (reseeded)"
  OR="$derived";    OR_SRC="config file $ENV_FILE (reseeded)"
  ok "config $ENV_FILE now names REPO=$repo_path OR=$derived O=$O"
  [ -z "$bak" ] || log_line "   previous config preserved at $bak"
  log_line "   untouched: $O/.orch.lock, $O/state, the candidate files, and the repo's claim refs"
}

# ── check ──────────────────────────────────────────────────────────────────────────────────────
# Every arm answers ONE question, and every arm that cannot answer says so with rc=2 rather than
# letting the next line pass. Nothing here starts, writes or signals anything.
cmd_check() {
  log_line "==> check ($PLATFORM) — repo=${REPO:-<unset>} (${REPO_SRC:-<unset>})  state=$O"

  # 1. the configured repo path exists on THIS machine — the measured cell failure (see header).
  if [ -z "${REPO:-}" ]; then
    refuse "no repo is configured for this machine — the harness default is another machine's path, and a controller started on it refreshes nothing; pass REPO=<checkout> or run: $0 --reseed"
  fi
  if [ ! -d "$REPO" ]; then
    refuse "the configured repo path does not exist on THIS machine: $REPO (from: $REPO_SRC) — a controller on it aborts every refresh cycle while looking alive; pass REPO=<checkout> or run: $0 --reseed"
  fi
  git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 \
    || refuse "$REPO is not a git checkout (no .git directory or linked-worktree .git file) — pass REPO=<a real checkout>"
  resolve_repo_identity || refuse "$IDENTITY_MSG"
  SLUG="$(registry_slug "$SLUG_REPO")" \
    || refuse "the repo identity '$SLUG_REPO' is not usable as a registry key — it must be <owner>/<repo>"
  ok "repo $SLUG_REPO at $REPO (origin $(git -C "$REPO" remote get-url origin 2>/dev/null))"

  # 2. gh answers. Two different failures, two different codes: absent is CANNOT DETERMINE (no probe
  # exists), unauthenticated is a refusal (the probe exists and said no).
  command -v gh >/dev/null 2>&1 \
    || unknown "gh is not on PATH — every queue read, review record and merge goes through it, so this machine's readiness cannot be determined"
  if gh auth status >/dev/null 2>&1; then
    ok "gh authenticated (HOME=$HOME)"
  else
    refuse "gh is not authenticated for HOME=$HOME — run: gh auth login --with-token <token> (or point HOME at the home that holds the credentials)"
  fi

  # 3. keys load. The cell reads them from the config file; the Mac's launchd plist has no
  # environment and install.sh exports them into it, so both paths ultimately need ONE provider key.
  # ⛔ ON THE MAC, A CONFIG FILE IS NOT THE KEY SOURCE — so a config with no `*_API_KEY` in it is not
  # a refusal there. The previous form refused on `-f "$ENV_FILE"` at every platform, which made
  # `--reseed` self-defeating: the documented repair CREATES that file (REPO/OR/O, no key), and every
  # later `check`/`start` then refused "no provider key" (#1856 review, reproduced).
  if [ -f "$ENV_FILE" ]; then
    bash -n "$ENV_FILE" 2>/dev/null \
      || refuse "$ENV_FILE cannot be parsed as shell — sourcing it would silently drop every key it sets; fix it (or move the keys to a file that is only assignments)"
    local k count=0
    for k in $(bash -c 'set -a; . "$1" >/dev/null 2>&1; for v in $(compgen -v); do case "$v" in *_API_KEY) printf "%s\n" "$v";; esac; done' _ "$ENV_FILE" 2>/dev/null); do
      [ -n "$(env_file_value "$k" "$ENV_FILE")" ] && count=$((count + 1))
    done
    if [ "$count" -gt 0 ]; then
      ok "keys: $count provider key(s) load from $ENV_FILE"
    elif [ "$PLATFORM" = "cell" ]; then
      refuse "no provider key (*_API_KEY) with a value loads from $ENV_FILE — every lane would fail its first model call; add one to that file"
    else
      warn "no provider key (*_API_KEY) in $ENV_FILE — fine on a Mac: this box's keys come from the shell that runs 'install.sh'"
    fi
  elif [ "$PLATFORM" = "cell" ]; then
    refuse "no config file at $ENV_FILE — a cell lane has no provider key and no HOME; push one or run: $0 --reseed"
  else
    warn "no config file at $ENV_FILE — this Mac's keys must come from the shell that runs 'install.sh'"
  fi

  # 4. the harness pin is exactly one and owned (cell) / the deployed copy is on the repo's line (Mac).
  check_harness_pin

  # 5. the lock: free, or owned by a live controller. AND the split that the whole #1761 review turns
  # on: what this state dir OWNS vs what merely runs this machine's harness (another repo's
  # controller, when two repos share the cell's harness path).
  # ⛔ EVERY READ HERE FAILS CLOSED. `|| VAR=""` turned "ps cannot answer" into an EMPTY read, which
  # is indistinguishable from "no controller": `check` printed `lock free`, and `stop` released the
  # durable one-per-(machine,repo) record over a controller that was still running — so the next
  # `start` (from any $O) read `absent` and was allowed: two controllers on one queue, the exact
  # #1761 defect (#1856 review, reproduced with a failing `ps` stub).
  local lp live own foreign
  lp="$(lock_pid)" || unknown "cannot determine the lock owner: the process table (ps) or the owning pid's age cannot be read — check cannot answer from an unreadable read"
  live="$(local_controller_pids)" || unknown "cannot read the process table (ps) — check cannot answer from an unreadable read"
  own="$(owned_pids)" || unknown "cannot determine which controllers belong to this state dir (ps/etime unreadable) — check cannot answer"
  foreign="$(comm -23 <(printf '%s\n' "$live" | awk 'NF' | sort -u) <(printf '%s\n' "$own" | awk 'NF' | sort -u))"
  if [ -n "$lp" ]; then
    ok "lock $O/.orch.lock owned by live controller pid $lp"
  elif [ -f "$O/.orch.lock" ]; then
    warn "$O/.orch.lock names no live controller — stale, and 'start' replaces it"
  else
    ok "lock free ($O/.orch.lock absent)"
  fi
  [ -z "$own" ] || ok "controller running for this state dir: pid $(pids_join "$own")"
  # ⛔ REPORTED, never blessed: a pid running the shared harness path with no lock here is the OTHER
  # repo's controller on a two-repo machine. Calling it "running for this state dir" is how repo B's
  # `status`/`check` would claim repo A's work (#1856 review, reproduced).
  [ -z "$foreign" ] || warn "also seen (NOT this state dir's): pid $(pids_join "$foreign") runs this machine's harness but holds no $O/.orch.lock — another repo's controller"

  # 6. the per-repo registry: at most ONE live controller per (machine, repo).
  check_registry

  log_line ""
  log_line "BRINGUP CHECK OK — this machine can run a controller for $SLUG_REPO"
  return 0
}

check_harness_pin() {
  if [ "$PLATFORM" = "cell" ]; then
    [ -n "${HARNESS:-}" ] || HARNESS=""
    local recorded=""
    [ -f "$HARNESS_PIN_FILE" ] && recorded="$(head -1 "$HARNESS_PIN_FILE" 2>/dev/null)"
    if [ -z "$recorded" ]; then
      ok "no harness pin recorded yet ($HARNESS_PIN_FILE) — 'start' applies one from ${HARNESS_REPO:-this checkout}"
      return 0
    fi
    if [ ! -d "$recorded" ] || [ ! -f "$recorded/orch-loop.sh" ]; then
      refuse "the harness pin this cell recorded no longer exists: $recorded — the cell has no controller to run; re-apply with: $0 start"
    fi
    case "$recorded" in
      "$HARNESS_PIN_DIR"/*) ;;
      *) refuse "the recorded harness pin $recorded is NOT under this machine's pin dir $HARNESS_PIN_DIR — it was seeded from another machine or by hand, so nothing here can maintain it; re-apply with: $0 start" ;;
    esac
    # "exactly one": the pin dir is per-commit, so several pins can coexist by design (prune reclaims
    # the ones no longer in use). What must be singular is the RECORD — the path the controller will
    # exec — and it must be one the pin dir owns. Both are asserted above; the count is reported so an
    # operator can see whether a prune is due, never refused on.
    local n; n="$(find "$HARNESS_PIN_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
    ok "harness pin $recorded (1 recorded; $n pin(s) on disk, prune reclaims the rest)"
    return 0
  fi
  # macOS: the question is not "which pin" but "is the DEPLOYED copy the repo's own bytes".
  [ -x "$HARNESS_BRINGUP/check-deployed-drift.sh" ] || [ -f "$HARNESS_BRINGUP/check-deployed-drift.sh" ] \
    || unknown "check-deployed-drift.sh is missing from $HARNESS_BRINGUP — the deployed harness's identity cannot be verified, and cannot-verify is never a pass"
  local out rc
  # ⛔ The drift check compares the DEPLOYED $O against the AGENT-INFRA checkout the harness ships
  # from — NOT against $REPO, which is the repo the controller works on. Passing $REPO here made the
  # comparison "is this tortoise checkout carrying the orchestrator harness", which is a different
  # question with a guaranteed-unknown answer.
  local src_repo
  src_repo="$(git -C "$HERE" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print substr($0,10); exit}')"
  [ -n "$src_repo" ] || unknown "cannot resolve the agent-infra checkout \$HERE ($HERE) lives in — the deployed harness's identity cannot be verified, and cannot-verify is never a pass"
  out="$(O="$O" bash "$HARNESS_BRINGUP/check-deployed-drift.sh" --o "$O" --repo "$src_repo" --rel scripts/orchestrator-harness --no-fetch 2>&1)"; rc=$?
  case "$rc" in
    0) ok "deployed harness matches $src_repo: $(printf '%s' "$out" | head -1)" ;;
    1)
      # ⛔ DRIFT DOES NOT REFUSE ON THIS PLATFORM, and that is deliberate — the same rule
      # cloud-cell-supervisor.sh applies to `behind`. `start` DEPLOYS the harness into $O before it
      # launches (see deploy_harness), so drift is the state `start` exists to repair; refusing it
      # here would false-block the only command that fixes it. What is NOT mendable is an identity
      # nobody can read — that is the rc=2 arm below.
      # ⛔ THE COUNT PATTERN CARRIES NO COLON, and that is the whole point: the checker labels each
      # finding with the QUESTION it failed — `DRIFT(identity):` / `DRIFT(record):` / `DRIFT(checkout):`
      # — since the two-question split. A pattern anchored on `^DRIFT:` matched only the unlabelled
      # remainder (`MISSING`, `STALE-RECORD`, the surface arms), so on exactly the box this warning
      # exists for (the deployed copy DIFFERS from the checkout — the common repair case, on the verb
      # that redeploys it) it printed `0 finding(s)` beside a live drift report. A count that
      # contradicts its own first line is worse than no count.
      warn "the deployed harness at $O has drifted from $src_repo ($(printf '%s' "$out" | grep -c '^DRIFT' ) finding(s); first: $(printf '%s' "$out" | head -1)) — 'start' redeploys $O from $src_repo before launching"
      ;;
    *)
      # ⛔ ABSENT AND UNREADABLE ARE DIFFERENT FACTS, and only one of them is this run's to refuse.
      # A box that was NEVER stamped has no identity record to contradict — and this verb is the one
      # that CREATES it: `start` deploys $O from $src_repo and install.sh writes the stamp. Refusing
      # here made the repair unreachable from the only entry point that performs it (measured on this
      # box 2026-10-21: $O carried no .agent-infra-stamp.json, so `start` exited 2 at check and never
      # reached its own deploy; the remaining route was a bare `install.sh` run, which is the SECOND
      # launchd job hazard 2 of this change exists to stop rendering). A stamp that EXISTS and cannot
      # be read or parsed is the opposite case — a real identity nobody can establish — and stays
      # rc=2: deploying over it would destroy the record rather than repair it.
      if [ ! -f "$O/.agent-infra-stamp.json" ]; then
        warn "the deployed harness at $O carries NO identity record ($O/.agent-infra-stamp.json is absent) — nothing can certify what $O ran BEFORE this run; 'start' deploys $O from $src_repo, which is the repair (#1745)"
      else
        unknown "the deployed harness at $O cannot be verified against $src_repo ($(printf '%s' "$out" | head -1)) — refusing to certify an unknown identity"
      fi
      ;;
  esac
}

# ── the RESOLVER SET — files something on this box resolves BY PATH (#2059) ─────────────────────
# A deploy is a MIRROR: it makes `$O` look like the checkout, and it used to `rm -f` every `$O/*.sh`
# the checkout does not ship. The predicate "not shipped" is not the same question as "stale".
#
# ⛔ MEASURED 2026-10-18: the six live disk reapers ship from `agent-infra:scripts/` — ONE DIRECTORY
# OVER — so the mirror classified them as "not shipped" and deleted all six, which broke the armed
# hourly pass and silently reverted every lane teardown to `SKIP … KEPT` (spawn-gate.sh resolves
# `$O/reap-lane-venvs.sh` FIRST). On THIS box the same loop's first victim is `supervisor.sh`, which
# ships from NOWHERE: it is the `ProgramArguments` of the loaded job `com.eldato.orchestrator-stack`,
# so `start` deleted it, then `launchctl unload` + `load` re-loaded a job whose program no longer
# existed.
#
# ⛔ So the rule is not "does the harness ship it" but "does SOMETHING RESOLVE `$O/<name>`": a job's
# ProgramArguments, an armed schedule, or a sibling that tries `$O/<tool>` before falling back. A file
# whose only fault is that the checkout does not carry it is DEPLOYED STATE, not a stale copy, and a
# deploy never removes one. Each entry names its RESOLVER — the thing that would break — not the
# file's purpose, because that is what an editor has to go and change.
RESOLVER_SET="\
supervisor.sh|the ProgramArguments of this box's controller job (com.eldato.orchestrator-stack → /bin/bash $O/supervisor.sh)
orchestrator-heartbeat.sh|the ProgramArguments of com.eldato.harness-heartbeat, and cadence-nudge.sh's TICK
disk-reaper.sh|resolved from $O before the shipped copy by cloud-cell-bringup.sh and cloud-cell-supervisor.sh, and the armed reaper schedule
pi-cache-reap.sh|the pi cache reaper run from $O by the armed schedule
pi-reap-worktrees.sh|resolved from $O by the worktree/branch reaper schedule
reap-lane-venvs.sh|resolved FIRST from $O by spawn-gate.sh (:413) — without it every lane teardown keeps its venv"

resolver_reason() { # <basename> → the resolver that names it, or empty
  local e
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    if [ "${e%%|*}" = "$1" ]; then printf '%s\n' "${e#*|}"; return 0; fi
  done <<RESOLVERS
$RESOLVER_SET
RESOLVERS
  return 0
}

# deploy_harness — put THIS checkout's harness into $O, atomically, before the daemon is loaded.
#
# ⛔ load-bearing: a launchd plist runs `__O__/orch-loop.sh`, and `install.sh` does NOT copy the
# scripts there — it only WARNS when $O differs from the shipped copy. So a `start` that skipped this
# step would launch whatever bytes happen to be in $O (on this box: a tree four weeks behind, with a
# post-install hand edit) and the stamp written afterwards would describe a harness nobody runs. Same
# discipline as cloud-cell-supervisor.sh's seed_and_stamp: temp file in the same directory, then
# rename — a running controller's lanes execute `bash $O/<worker>.sh`, and a plain `cp` TRUNCATES the
# live script before rewriting it, so a spawn landing in that window would run half a worker.
#
# ⛔ AND THE OTHER DIRECTION IS NOT A MIRROR UNLESS ASKED (#2059). Nothing is removed from `$O` unless
# `--prune` says so, the plan is printed BEFORE anything is written, and a resolver-set file is never
# removed at all — a `--prune` that would have taken one is a CONFLICT: the removals it CAN honour are
# performed, the resolver set is kept, and this returns non-zero naming what it refused to delete.
# Returns 1 only in that state — a plain deploy (or one with nothing to remove) returns 0.
deploy_harness() {
  # ⛔ SEED FROM THE PINNED TREE, NOT FROM THE CHECKOUT THIS WAS RUN FROM (agent-infra#2231). The
  # controller execs the pinned harness; the workers exec `$O`. Seeding `$O` from the operator's
  # checkout made those two DIFFERENT COMMITS on the Mac — the same version skew `--pin-only` exists
  # to avoid on a cell (`cloud-cell-supervisor.sh`'s `seed_and_stamp` seeds from `$HARNESS`, the pin).
  # `HARNESS_SEED` is set on the Mac branch of the platform block above; on a cell it stays empty and
  # this function is not the seeder at all (the supervisor's `seed_and_stamp` is).
  local SRC_HARNESS="${HARNESS_SEED:-$HARNESS_BRINGUP}"
  [ -d "$SRC_HARNESS" ] || unknown "no harness at $SRC_HARNESS — nothing to deploy into $O"
  mkdir -p "$O/logs" "$O/state" "$O/wip" || refuse "cannot create the state dir $O"
  local src f b tmp n=0 changed="" stale="" keep="" why conflict=0
  local dout="" drc=0
  # ── THE PLAN, before anything is written ────────────────────────────────────────────────────────
  # Two halves, because they are two different risks: a shipped file whose bytes DIFFER is about to be
  # overwritten (a hand edit in $O is lost), and a file $O carries and the checkout does not is what
  # the mirror used to delete. An operator reading a plan can stop it; nobody reads an `rm` in a loop.
  for src in "$SRC_HARNESS"/*.sh; do
    [ -f "$src" ] || continue
    b="$(basename "$src")"
    [ -f "$O/$b" ] || continue
    cmp -s "$src" "$O/$b" || changed="$changed $b"
  done
  [ -z "$changed" ] || log_line "deploy: plan — replacing $(printf '%s' "$changed" | wc -w | tr -d ' ') file(s) in $O whose bytes differ from the checkout:$changed"
  for f in "$O"/*.sh; do
    [ -f "$f" ] || continue
    b="$(basename "$f")"
    [ -f "$SRC_HARNESS/$b" ] && continue
    why="$(resolver_reason "$b")"
    if [ -n "$why" ]; then keep="$keep $b"; else stale="$stale $b"; fi
  done
  # ── WHAT THIS FUNCTION WRITES, STATED TO THE CHECKER — the write set, not the source tree ─────
  # ⛔ `harness-provenance.sh` inventories `--src` RECURSIVELY and treats "the source ships it, `$O` does
  # not" as a FAILED deploy. This function copies ONLY depth-1 `*.sh`, while a real harness directory
  # also ships `README.md`, `ARCHITECTURE.md`, `*.py`, `retired/`, `gh-rest/gh`, `gh-limit/gh` — so told
  # the whole directory, every `write` below refused ("the source ships README.md but $O has no such
  # file"), NO box was ever recorded by the verb operators actually run, and the refusal right below sat
  # on `drc=2` CANNOT-TELL forever — the gate was inert on exactly the population it was added for.
  # (`--skip` is the writer's own seam for this; `check` already had it, `write` now honours it too.)
  # A `find` that fails here collapses to "skip nothing", so the worst case is the old refusal, never a
  # manifest describing bytes this run did not write.
  local skip_args=()
  if [ -f "$SRC_HARNESS/harness-provenance.sh" ]; then
    while IFS= read -r _rel; do
      [ -n "$_rel" ] || continue
      case "$_rel" in
        */*) ;;          # nested — this function copies no subdirectory, so it writes none of these
        *.sh) continue ;; # depth-1 *.sh — exactly the set the copy loop below installs
      esac
      skip_args+=(--skip "$_rel")
    done < <( cd "$SRC_HARNESS" 2>/dev/null && find . -type f -print 2>/dev/null | sed 's|^\./||' )
  fi
  # ── THE REFUSAL, before anything is written ────────────────────────────────────────────────────
  # ⛔ THIS FUNCTION IS A THIRD WRITER OF `$O/*.sh`, and it was the only one with no gate. The two
  # deploy paths (`deploy-harness.sh`, `deploy-mac-orchestrator.sh`) refuse to overwrite a file whose
  # bytes no deploy wrote and exit 78 naming it — the 2026-10-28 incident, a hand patch to
  # `$O/merge-one.sh` reverted TWICE. But the Mac verb operators actually run is `start`, and this
  # function copied over the same files unconditionally: the patch was lost after a warning, and the
  # box carried bytes no record described. A refusal on two of three writers is a gate with a door
  # beside it. Same checker, same source, same three answers as `deploy-harness.sh`'s preflight (c).
  if [ "$ACCEPT_DISCARD" = 1 ]; then
    warn "deploy: --accept-discard — an uncommitted edit in $O (if any) WILL be overwritten by this run"
  elif [ -f "$SRC_HARNESS/harness-provenance.sh" ]; then
    # The checker is the SOURCE's copy: the `$O` copy may be the very thing under suspicion.
    dout="$(bash "$SRC_HARNESS/harness-provenance.sh" check --o "$O" --src "$SRC_HARNESS" ${skip_args[@]+"${skip_args[@]}"} 2>&1)" || drc=$?
    case "$drc" in
      0) : ;;
      1)
        # ⛔ PRINT THE FILE LIST BEFORE REFUSING. `refuse` is one line by contract, and the one line
        # cannot hold which files, which side is newer, and what to do — that is the whole diagnosis.
        printf '%s\n' "$dout" >&2
        refuse "the deploy would OVERWRITE uncommitted edits in $O that exist nowhere else — nothing was copied; land them in the repo (or copy them aside), then re-run, or re-run with 'start --accept-discard' to discard them deliberately"
        ;;
      *)
        # CANNOT-VERIFY (no readable record). The refusal cannot fire, but silence is how the next
        # redeploy quietly reverts a patch — said once, on the path that will overwrite. The run
        # below RECORDS the box, so every later deploy can tell an edit from its own bytes.
        warn "deploy: UNKNOWN whether $O carries uncommitted edits (no readable provenance record there) — files this run overwrites are NOT recoverable; this run records the box, so later deploys can name an edit"
        ;;
    esac
  else
    warn "deploy: the source ships no harness-provenance.sh, so this deploy cannot tell whether $O carries uncommitted edits — files it overwrites are NOT recoverable"
  fi
  for src in "$SRC_HARNESS"/*.sh; do
    [ -f "$src" ] || continue
    f="$(basename "$src")"; tmp="$O/.seed-$f.$$"
    cp -p "$src" "$tmp" || { rm -f "$tmp"; refuse "cannot stage $f into $O — check free space"; }
    mv -f "$tmp" "$O/$f" || { rm -f "$tmp"; refuse "cannot install $f into $O"; }
    n=$((n + 1))
  done
  [ "$n" -gt 0 ] || unknown "no *.sh in $HARNESS_BRINGUP — refusing to load a daemon with nothing to run"
  # ── THE RECORD: which commit this tree is, and which bytes this run wrote ─────────────────────────
  # ⛔ WRITTEN ONLY AFTER THE COPY COMPLETED: a record over a half-copied tree would be a claim about
  # bytes that are not all there. That is also why `install.sh`'s stamp alone was not enough — it
  # describes `$O` at install time, and every later `start` invalidated it without saying so.
  if [ -f "$SRC_HARNESS/harness-provenance.sh" ]; then
    local pcommit="" ppargs=()
    pcommit="$(git -C "$SRC_HARNESS" rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null)" || pcommit=""
    [ -n "$pcommit" ] && ppargs+=(--commit "$pcommit")
    # ⛔ `${arr[@]+…}` IS REQUIRED under `set -u` on bash 3.2: an EMPTY array expands to an unbound-
    # variable error there, so a source that is not a git checkout would abort the deploy AT THE
    # RECORD instead of writing commit=UNKNOWN.
    if bash "$SRC_HARNESS/harness-provenance.sh" write --o "$O" --src "$SRC_HARNESS" ${ppargs[@]+"${ppargs[@]}"} ${skip_args[@]+"${skip_args[@]}"}; then
      log_line "deploy: recorded $O/.harness-provenance (commit ${pcommit:-UNKNOWN}) — every later deploy can now tell an edit from its own bytes"
    else
      warn "deploy: could NOT write $O/.harness-provenance — the bytes above are deployed, but this run did not record which commit they came from, so the NEXT deploy cannot tell an edit from its own bytes"
    fi
  fi
  # ── the removal policy ─────────────────────────────────────────────────────────────────────────
  if [ -n "$stale" ]; then
    if [ "$PRUNE" = 1 ]; then
      log_line "deploy: plan — --prune: removing $(printf '%s' "$stale" | wc -w | tr -d ' ') unshipped file(s) from $O:$stale"
      for b in $stale; do rm -f "$O/$b" && log_line "deploy: removed $b"; done
    else
      log_line "deploy: $(printf '%s' "$stale" | wc -w | tr -d ' ') file(s) in $O are not shipped by the harness and are LEFT IN PLACE — a deploy does not delete from the live tree; 'start --prune' removes them:$stale"
    fi
  fi
  if [ -n "$keep" ]; then
    warn "deploy: KEPT $(printf '%s' "$keep" | wc -w | tr -d ' ') file(s) the harness does not ship, because something on this box resolves them BY PATH (#2059):"
    for b in $keep; do warn "  · $b — $(resolver_reason "$b")"; done
    if [ "$PRUNE" = 1 ]; then
      conflict=1
      warn "deploy: CONFLICT — --prune asked for a mirror, and a mirror would delete the resolver set named above; that removal was NOT performed. Retire one of those files by changing the resolver that names it, not by pruning $O"
    fi
  fi
  if [ -f "$SRC_HARNESS/gh-rest/gh" ]; then
    mkdir -p "$O/gh-rest" || refuse "cannot create $O/gh-rest"
    tmp="$O/gh-rest/.gh.$$"
    cp -p "$SRC_HARNESS/gh-rest/gh" "$tmp" && chmod +x "$tmp" && mv -f "$tmp" "$O/gh-rest/gh" \
      || { rm -f "$tmp"; refuse "cannot install $O/gh-rest/gh"; }
  fi
  ok "deployed $n harness script(s) into $O from $SRC_HARNESS"
  return "$conflict"
}

check_registry() {
  local f verdict kind pid ro st
  f="$(registry_file "$SLUG_REPO")" || unknown "the repo identity '$SLUG_REPO' cannot be turned into a registry key"
  verdict="$(registry_verdict "$f")"
  IFS=$'\t' read -r kind pid ro st <<<"$verdict"
  kind="${kind:-}"; pid="${pid:-}"; ro="${ro:-}"; st="${st:-}"
  case "$kind" in
    absent)
      ok "registry: no controller recorded for $SLUG_REPO on this machine"
      ;;
    live)
      if [ "$st" = "starting" ] && [ "$pid" = "$$" ]; then
        ok "registry: this process is starting $SLUG_REPO"
      elif [ "$st" = "foreign-process" ]; then
        # Alive, but not an orch-loop.sh, and not provably a reused pid (the wall-clock re-check in
        # registry_verdict already reclaimed that case). Refuse — and name the file, because the
        # remedy here is a human decision, not a `stop` (there is nothing of ours to stop).
        refuse "the registry record for $SLUG_REPO names pid $pid, which is alive but is NOT an orch-loop.sh (a pid may have been reused) — if you know the old controller is gone, remove $f; refusing to start a possible duplicate"
      elif [ "$ro" = "$O" ]; then
        ok "registry: $SLUG_REPO is held by pid $pid at this state dir ($st)"
      else
        # ⛔ THE MEASURED DUPLICATE. A live controller for the SAME repo in a DIFFERENT state dir is
        # exactly the redundancy this registry exists to refuse, and each $O reads healthy alone.
        refuse "a controller for $SLUG_REPO is ALREADY RUNNING on this machine: pid $pid at O=$ro ($st) — one controller per repo; stop it first ($0 stop with O=$ro) or work a different repo here"
      fi
      ;;
    stale)
      # Name WHICH staleness: a dead pid and a pid reused by an unrelated process are the same
      # verdict and different stories, and the operator has to be able to tell them apart.
      case "$st" in
        pid-reused) ok "registry: a stale entry for $SLUG_REPO — pid $pid is alive but was REUSED by an unrelated process (it began after the record was written) — 'start' reclaims it" ;;
        *)          ok "registry: a stale entry for $SLUG_REPO (pid $pid is gone, $st) — 'start' reclaims it" ;;
      esac
      ;;
    *)
      # A record we cannot parse might be naming a live controller we cannot read. Reclaiming it would
      # be acting on an unread fact, which is the failure this whole file is about.
      unknown "the registry record $f cannot be judged ($kind ${st:-}) — it may name a live controller for $SLUG_REPO; fix or remove it by hand"
      ;;
  esac
}

# ── start ─────────────────────────────────────────────────────────────────────────────────────
# The order is: claim -> verify -> launch -> confirm -> record. The claim comes FIRST so that two
# concurrent starts (the measured duplicate: an operator retries because the first looked slow) cannot
# both pass the gate; the pending record is removed on any failure, so a refused start never leaves a
# phantom owner behind.
PENDING_FILE=""
# Set by start_mac when the deploy could not honour --prune (a resolver-set file it was asked to
# remove). Read once, at the end of cmd_start, so the exit code carries it.
DEPLOY_CONFLICT=0
# Set by start_mac's ADOPT path: the recorded pid was proven from the strict scope (the lock plus this
# state dir's own process set) rather than read off the launchd job, whose pid may be a supervisor.
STARTED_PID_PROVEN=0
release_pending() {
  [ -n "$PENDING_FILE" ] || return 0
  # Only remove OUR record: if the record now names a real controller pid, a start got through and the
  # registry is recording the truth.
  local pid; pid="$(registry_get "$PENDING_FILE" pid)"
  if [ "$pid" = "$$" ]; then rm -f "$PENDING_FILE"; fi
  PENDING_FILE=""
}

cmd_start() {
  # Resolve enough to name the repo before touching anything.
  if [ -z "${REPO:-}" ] || [ ! -d "${REPO:-}" ]; then
    cmd_check   # produces the exact refusal (missing path / unset / not a checkout)
  fi
  resolve_repo_identity || refuse "$IDENTITY_MSG"
  SLUG="$(registry_slug "$SLUG_REPO")" || unknown "the repo identity '$SLUG_REPO' is not usable as a registry key"
  local f; f="$(registry_file "$SLUG_REPO")" || unknown "cannot compute the registry path for $SLUG_REPO"

  registry_claim_or_refuse "$f"
  trap 'release_pending' EXIT INT TERM

  # The full verification, AFTER the claim: a refusal must leave no phantom owner, and `check` is the
  # one place the questions are asked (running them twice would create the second authority this file
  # exists to avoid).
  cmd_check >/dev/null || { local rc=$?; release_pending; return "$rc"; }

  log_line "==> starting $PLATFORM controller for $SLUG_REPO"
  local pid
  case "$PLATFORM" in
    cell) start_cell ;;
    mac)  start_mac ;;
  esac
  pid="$STARTED_PID"
  [ -n "$pid" ] || unknown "start reported success but no controller pid could be read (neither its status nor this state dir's lock names a provable owner) — the registry is left unclaimed so a second start is not blocked by a phantom; check: $0 status"
  # ⛔ RECORD ONLY A PID THIS STATE DIR CAN PROVE. The fallback chain below can return the pid of a
  # controller running from the SHARED harness path, which on a machine with two repos is the OTHER
  # repo's controller — recording it would report "controller RUNNING" for a repo nothing started,
  # and the record would then refuse every later start as a duplicate (#1856 review). Membership in
  # the state dir's own process set is the only assertion available without a second authority.
  local owned; owned="$(owned_pids)" \
    || unknown "cannot verify that pid $pid is this state dir's controller (ps/etime unreadable) — refusing to record a pid that cannot be checked"
  case "$PLATFORM" in
    cell) ;; # a cell controller is started by the supervisor's tmux session and reported by its
            # `status`; the harness path it execs is NOT repo-scoped, so `owned` may legitimately be
            # empty here. The supervisor's own read is the authority on that platform.
    mac)
      # A here-string, never a pipe: under `pipefail` a builtin writer piped into a quiet grep is the
      # SIGPIPE false-negative idiom (#841/#864) — `grep -qx` exits at the first match, the writer
      # takes SIGPIPE, and the pipeline's status is the 141, not grep's 1. Caught by sigpipe-grep.
      # ⛔ AND IT IS NOT ASKED AT ALL when the pid was already PROVEN by the strict scope (start_mac's
      # ADOPT path): on an adopting box launchd's pid is the SUPERVISOR and this state dir's
      # controller is its child, so "is launchd's pid an orch-loop.sh" refuses a controller that is
      # demonstrably running.
      if [ "${STARTED_PID_PROVEN:-0}" != 1 ] && ! grep -qx "$pid" <<<"$owned"; then
        unknown "launchd reports pid $pid but no $O/orch-loop.sh process runs as it — refusing to record a pid this state dir cannot prove is its own controller; check: launchctl print gui/$(id -u)/${ACTIVE_LABEL:-$LABEL}"
      fi
      ;;
  esac
  registry_write "$f" "$SLUG_REPO" "$O" "$pid" running \
    || refuse "the controller is RUNNING as pid $pid but the registry record at $f could not be written — a second start for $SLUG_REPO would not be refused; fix the permissions on $(dirname "$f")"
  PENDING_FILE=""
  ok "controller RUNNING pid $pid ($PLATFORM, state dir $O)"
  log_line "   stop it with: $0 stop"

  # ── the REST of the fleet ────────────────────────────────────────────────────────────────────
  # Start is defined as "make every MISSING component present", driven by the same inventory the
  # table reads — so the controller coming up does not end the job while the heartbeat loop, the
  # cadence timer and the reapers are silently absent. A LATE component is left alone (it is alive;
  # killing a live process to "fix" lateness is a lane-killer) and a DUPLICATE is reported, never
  # reconciled by a kill.
  log_line ""
  log_line "==> ensuring the rest of the fleet"
  fleet_ensure_components "$(harness_ctl_path)"; local frc=$?
  # ⛔ A DEPLOY THAT COULD NOT HONOUR --prune IS A FACT ABOUT THE EXIT CODE. The conflict is about $O's
  # resolver set, not about the controller (which is up), so this reports rather than unwinds — but a
  # run whose mirror was only partly applied must not exit 0 as if nothing had been asked for.
  if [ "${DEPLOY_CONFLICT:-0}" != 0 ]; then
    warn "the deploy reported a CONFLICT (see above) — the fleet was still started; the conflict is $O's resolver set, not the controller"
    [ "$frc" = 0 ] && frc=1
  fi
  return "$frc"
}

registry_claim_or_refuse() { # <file>
  local f="${1:?}" verdict kind pid ro st
  verdict="$(registry_verdict "$f")"
  IFS=$'\t' read -r kind pid ro st <<<"$verdict"
  kind="${kind:-}"; pid="${pid:-}"; ro="${ro:-}"; st="${st:-}"
  case "$kind" in
    live)
      if [ "$st" = "foreign-process" ]; then
        refuse "the registry record for $SLUG_REPO names pid $pid, which is alive but is NOT an orch-loop.sh (a pid may have been reused) — if you know the old controller is gone, remove $f; refusing to start a possible duplicate"
      fi
      if [ "$ro" = "$O" ]; then
        # Same state dir: the platform verb's own read is the authority, and it reports "already
        # running" — but say which process, because that is the question an operator is asking.
        refuse "$SLUG_REPO is already running on this machine (pid $pid at this state dir) — use: $0 status | stop"
      fi
      refuse "a controller for $SLUG_REPO is ALREADY RUNNING on this machine: pid $pid at O=$ro ($st) — one controller per repo; stop it first"
      ;;
    stale)
      # Say which happened. A silent reclaim teaches nobody that the box had a crashed controller.
      case "$st" in
        pid-reused) warn "reclaiming a STALE registry entry for $SLUG_REPO (pid $pid was REUSED by an unrelated process, O=$ro) — it is not blocking this start" ;;
        *)          warn "reclaiming a STALE registry entry for $SLUG_REPO (pid $pid is gone, O=$ro) — it is not blocking this start" ;;
      esac
      # Reclaim, then claim: the removal is what makes the EXCLUSIVE create below possible. If another
      # start claims between the two, its create wins and ours is the one that loses — whichever
      # order, exactly one of them owns the record.
      rm -f "$f"
      ;;
    unreadable)
      unknown "the registry record $f cannot be read ($st) — it may name a live controller for $SLUG_REPO; refusing to start a possible duplicate"
      ;;
  esac
  # ⛔ THE CLAIM IS AN EXCLUSIVE CREATE, not a write. See registry_claim.
  registry_claim "$f" "$SLUG_REPO" "$O" "$$" starting
  case "$?" in
    0) ;;
    1)
      # Someone created the record between our verdict and our create: report the record that WON,
      # never overwrite it. This is the operator's double-tap, closed.
      verdict="$(registry_verdict "$f")"
      IFS=$'\t' read -r kind pid ro st <<<"$verdict"
      refuse "another start claimed $SLUG_REPO between the check and the claim (pid ${pid:-?} at O=${ro:-?}, state=${st:-?}) — refusing to run a second controller for one repo"
      ;;
    *) unknown "cannot create the registry record at $f — without it a concurrent start could not be refused; fix the permissions on $(dirname "$f")" ;;
  esac
  PENDING_FILE="$f"
}
# Waits for the platform to name its controller pid. Bounded: `start` returns as soon as tmux/the
# daemon is told to run, and the loop writes its lock a beat later. A pid we did NOT observe is never
# recorded — a registry entry naming a process we invented is worse than no entry.
await_pid() { # <reader-command...>
  local i=0 p=""
  while [ "$i" -lt 40 ]; do
    p="$("$@" 2>/dev/null)" || p=""
    [ -n "$p" ] && { printf '%s\n' "$p"; return 0; }
    sleep 0.5; i=$((i + 1))
  done
  return 0
}

start_cell() {
  [ -f "$SUPERVISOR" ] || unknown "no cloud-cell-supervisor.sh at $SUPERVISOR — this machine cannot start a cell controller"
  # `apply` pins the harness and seeds $O; `start` runs it anyway, so this is belt and braces at zero
  # cost (apply is idempotent and reports "unchanged"). Done explicitly so a pin failure is reported
  # as a pin failure rather than as a controller that exited immediately.
  if ! bash "$SUPERVISOR" apply; then
    # ⛔ `${VAR:-…}`, never `$VAR`: neither is assigned here (the ref is the supervisor's own config),
    # and under `set -u` an unset expansion inside the argument kills the shell BEFORE the refusal
    # prints — the failure mode where the refusal the whole file promises is replaced by a bash error
    # and the real cause (apply failed) is never stated. Measured by review of #1856.
    refuse "the harness could not be pinned to ${HARNESS_REF:-the configured ref} in ${HARNESS_REPO:-this checkout} (see the apply output above) — no controller was started"
  fi
  # ⛔ ORCH_FOREGROUND DESCRIBES THE CALLER, AND THIS CALLER IS NOT THE SERVICE MANAGER (review P1 round 18,
  # #2402). The unit exports `ORCH_FOREGROUND=1`, and a bring-up run from a lane shell inherits it through the
  # tmux server the controller created; without this pin the exec branch fires and `exec`s the loop INSIDE
  # this process — outside the unit's cgroup, so `systemctl stop` cannot end it, and the registry entry below
  # is never recorded because the process was replaced. `harness-up` carries the same fence.
  if ! env ORCH_FOREGROUND=0 bash "$SUPERVISOR" start; then
    refuse "cloud-cell-supervisor.sh start failed (see its output above) — no registry entry was recorded"
  fi
  STARTED_PID="$(await_pid roster_pid_from_status)"
  if [ -z "$STARTED_PID" ]; then
    STARTED_PID="$(lock_pid)" || STARTED_PID=""   # rc 2 (age unreadable) is not a pid
  fi
  # ⛔ NO THIRD FALLBACK. The old last resort (`local_controller_pids | head -1`) could return the pid
  # of a controller started from this cell's SHARED harness path — the other repo's controller on a
  # two-repo machine — and record it as this repo's owner (#1856 review). A pid we did not read from
  # the supervisor's own status or from the strict lock predicate is a pid we do not know.
}
# The pid, read from the platform's OWN status verb rather than re-derived here: one authority per
# question, and `status` is the verb whose answer an operator will also see.
#
# ⛔ ONLY a line that claims possession. `status` also prints `controller: RUNNING (pid N) — NOT this
# state dir's` when the process it sees belongs to another repo (they share this cell's harness path),
# and extracting N from THAT line would record a stranger as the owner — the false "controller RUNNING"
# the registry then acts on.
roster_pid_from_status() {
  bash "$SUPERVISOR" status 2>/dev/null \
    | grep -v "NOT this state dir's" \
    | sed -n 's/.*controller: RUNNING (pid \([0-9][0-9]*\).*/\1/p' | head -1
}

# ── which launchd job OWNS this state dir? ─────────────────────────────────────────────────────
# `start` used to render and load ONE hard-coded label, `com.eldato.orchestrator-loop`, on every box.
# That is one answer for a shape of box that does not include this one: here the loaded job is
# `com.eldato.orchestrator-stack` → `/bin/bash $O/supervisor.sh`, while `install.sh` renders
# `com.eldato.orchestrator-loop` → `$O/orch-loop.sh`. So `start` wrote a second plist and
# `launchctl load -w`'d it BESIDE the running stack: two jobs, one state dir, one of them an
# unsupervised controller — the duplicate-controller class (#1761), reached by running the canonical
# entry point (measured in a scratch $O on 2026-10-21: two plists, both loaded).
#
# ⛔ THE SAFE DIRECTION IS "OPERATE THE JOB THAT IS ALREADY HERE", never "load a new one": a box's
# supervision model is deployed state, and an entry point that renders over it is deciding an owner
# decision about the operating model in passing. So the question is asked FIRST:
#   none         → first install: render $LABEL and load it (the old, correct path).
#   exactly one  → ADOPT it: (re)start THAT job; never render $LABEL.
#   more than one → refuse. Two jobs both name a program in this $O; only a human can say which is
#                   stale, and starting the wrong one makes a second controller.
# The scan is textual on purpose: `plutil` is not guaranteed present, the two fields read here
# (Label, the last ProgramArguments <string>) are exactly the two both templates render, and a test can
# drive it with fixture plists.
launchd_job_for_state_dir() {
  local dir="${FLEET_LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}" p prog label job_o
  [ -d "$dir" ] || return 0
  for p in "$dir"/*.plist; do
    [ -f "$p" ] || continue
    # ⛔ BOTH FIELDS ARE READ FROM THE WHOLE FILE, joined to one line first: a plist may put
    # `<key>Label</key>` and its `<string>` on one line or on two (the live plists and a rendered
    # template differ), and a parser that only handles one layout silently reports a DIFFERENT label —
    # the first version of this function used `awk … {getline}` and produced the job's PROGRAM path as
    # its label against a one-line fixture, which is exactly the confusion this function exists to end.
    local flat args
    flat="$(tr '\n' ' ' < "$p" 2>/dev/null)"
    args="$(printf '%s' "$flat" | sed -n 's:.*<key>ProgramArguments</key>[[:space:]]*<array>\(.*\)</array>.*:\1:p')"
    # The LAST <string> of the array is the program: every job in this fleet is `/bin/bash <script>`,
    # and a job with no ProgramArguments is not one of ours.
    # ⛔ THE FIRST non-interpreter token (agent-infra#2231 follow-up): the program is now
    # `<pin>/<entry>`, which is NOT under $O, so a `case "$prog" in "$O"/*)` filter made the installer's
    # own job INVISIBLE to this scan — and the two-jobs ambiguity refusal below then never fired, so
    # `start` adopted the stack job and left the pin-programmed loop job loaded (a second controller).
    prog="$(printf '%s' "$args" | sed -n 's:.*<string>\([^<]*\)</string>.*:\1:p' \
      | awk 'BEGIN{FS=OFS=" "} {for(i=1;i<=NF;i++){ if ($i ~ /^-/) continue; if ($i ~ /(^|\/)(ba|z|k)?sh$/ || $i ~ /\/env$/) continue; print $i; exit }}')"
    # The ownership question is asked FIRST: a job that DECLARES this state dir (`O`) is this state
    # dir's job wherever its program lives. A job that merely lives under $O is not (the stack
    # supervisor, heartbeat, nightwatch, pr-doctor all do) — see the comment below.
    job_o="$(printf '%s' "$flat" | sed -n 's:.*<key>O</key>[[:space:]]*<string>\([^<]*\)</string>.*:\1:p')"
    # ⛔ AN AUXILIARY IS NEVER THIS STATE DIR'S CONTROLLER, WHATEVER IT DECLARES. The shipped watchdog
    # template declares EXACTLY this state dir (`templates/launchd/com.eldato.controller-watchdog.plist`
    # `O` = `{{HOME}}/orchestrator`, which IS the Mac's `$O`) while its program lives under
    # AGENT_INFRA_PATH — outside `$O`. So before this line, the `O` question alone counted the WATCHDOG
    # as a controller, and on a box where the documented activation path had installed it
    # (`install-launchd.sh`, ACTIVATION-MATRIX row 8) the scan returned TWO jobs and `start` refused
    # "TWO launchd jobs" — `harness-up up` could not run on the very box this pin work exists for, and
    # a watchdog is not a second controller (#2231 review).
    # ⛔ AND IT IS AN EXCLUSION LIST, NOT AN ALLOW-LIST OF CONTROLLER NAMES: the box's controller shapes
    # are open-ended — the stack supervisor (`$O/supervisor.sh`), an operator's renamed loop — and an
    # allow-list makes them stop owning their OWN state dir, which silently turns a duplicate-controller
    # refusal (#1761) into an adoption. The marker still has to be read from the DECLARATION (that is
    # what makes a PIN-programmed loop visible at all, #2231), so what this narrows is which PROGRAMS
    # may claim it.
    case "$(basename "${prog:-}")" in
      watchdog-loop.sh|orchestrator-heartbeat.sh|heartbeat-loop.sh|nightwatch.sh|pr-doctor.py) continue ;;
    esac
    if [ "$job_o" != "$O" ]; then
      case "$prog" in "$O"/*) ;; *) continue ;; esac
    fi
    # ⛔ A JOB THAT MERELY LIVES IN $O IS NOT THIS STATE DIR'S CONTROLLER JOB. On this box FOUR plists
    # run a program under $O — the stack supervisor, the heartbeat, `bg/nightwatch.sh`, pr-doctor — and
    # counting them all as owners made `start` refuse for ambiguity on the one box it has to work on
    # (measured 2026-10-21; the first version of this function did exactly that). The ownership marker
    # is the one the controller's own templates write: the job DECLARES this state dir (`O`), or it runs
    # the loop itself. An auxiliary installed under $O declares neither.
    [ "$job_o" = "$O" ] || [ "$prog" = "$O/orch-loop.sh" ] || continue
    label="$(printf '%s' "$flat" | sed -n 's:.*<key>Label</key>[[:space:]]*<string>\([^<]*\)</string>.*:\1:p')"
    [ -n "$label" ] || continue
    printf '%s\t%s\t%s\n' "$label" "$p" "$prog"
  done
  return 0
}

# ACTIVE_* — the job this run operates. ACTIVE_LABEL empty means "no job names a program in $O".
ACTIVE_LABEL=""; ACTIVE_PLIST=""; ACTIVE_PROG=""; ACTIVE_JOBS=""
launchd_active_job() { # 0 settled · 2 AMBIGUOUS (ACTIVE_JOBS lists them)
  local rows label plist prog n=0
  ACTIVE_LABEL=""; ACTIVE_PLIST=""; ACTIVE_PROG=""; ACTIVE_JOBS=""
  rows="$(launchd_job_for_state_dir)"
  while IFS="$(printf '\t')" read -r label plist prog; do
    [ -n "${label:-}" ] || continue
    n=$(( n + 1 ))
    ACTIVE_LABEL="$label"; ACTIVE_PLIST="$plist"; ACTIVE_PROG="$prog"
    ACTIVE_JOBS="$ACTIVE_JOBS${ACTIVE_JOBS:+, }$label ($plist)"
  done <<JOBS
$rows
JOBS
  [ "$n" -le 1 ] && return 0
  return 2
}

# launchd_job_state <label> → JOB_STATE in {yes,no,unknown}, with JOB_PID set when it is loaded.
# ⛔ IT WRITES GLOBALS INSTEAD OF PRINTING, and that is not style: a `$(...)` capture runs in a
# SUBSHELL, so the pid it read would never reach the caller — the first version printed the state and
# set JOB_PID inside the substitution, and the caller then died on `JOB_PID: unbound variable` (caught
# in this change's own scratch run).
# ⛔ Tri-state, and the same rule launchd-cycle.sh's `lc_probe` applies: ONLY launchd's own service-level
# "no such service" answer proves ABSENT. launchd prints the same `Bad request.` prefix for a
# DOMAIN-level rejection, which says nothing about the service — reading that as "not loaded" is how a
# broken domain becomes a confident answer. rc is NOT the verdict: `launchctl print` exits 113 for a
# missing service.
JOB_STATE=""; JOB_PID=""
launchd_job_state() {
  local out rc
  JOB_STATE="unknown"; JOB_PID=""
  out="$(launchctl print "gui/$(id -u)/$1" 2>&1)"; rc=$?
  if [ "$rc" = 0 ]; then
    JOB_STATE="yes"
    JOB_PID="$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*pid = \([0-9][0-9]*\).*/\1/p' | head -1)"
    return 0
  fi
  case "$out" in
    *"Could not find service"*|*"not find service"*|*"service not found"*) JOB_STATE="no" ;;
  esac
  return 0
}

# The CONTROLLER this state dir owns — the loop, never the JOB's pid. On a box whose job runs a
# supervisor, launchd's pid IS the supervisor: recording it would name a process whose argv is not
# `orch-loop.sh`, and `status` would then print an owner it cannot attribute. The proof of ownership is
# the same read `status` uses: the lock's owner plus this state dir's own process set.
controller_pid_owned() { owned_pids | head -1; }

plist_path() {
  # The ACTIVE job's plist once this box has one, else the path install.sh would render.
  printf '%s\n' "${ACTIVE_PLIST:-$HOME/Library/LaunchAgents/$LABEL.plist}"
}

start_mac() {
  [ -f "$HARNESS_BRINGUP/install.sh" ] || unknown "no install.sh at $HARNESS_BRINGUP — this machine cannot render the launchd agent"
  # install.sh renders AND validates the plist (plutil, unrendered-token check, daemon PATH probe) and
  # deliberately does not load it. Everything it needs is passed explicitly, so a value in this
  # machine's config file cannot be silently ignored by a launchd process that never sees the file.
  deploy_harness || DEPLOY_CONFLICT=1
  launchd_active_job || refuse "TWO launchd jobs name a program in $O: $ACTIVE_JOBS — one of them is stale and only a human can say which, and starting either can put a SECOND controller on $SLUG_REPO's queue. Remove the stale job (launchctl bootout gui/$(id -u)/<label>, then its plist) and re-run: $0 start"
  # ⛔ ADOPT ONLY WHEN THE JOB IS NOT THE ONE install.sh RENDERS. A box whose controller job IS $LABEL
  # keeps the old path exactly — install.sh re-renders it (limits, PATH, env) and we reload it — because
  # skipping the renderer there would freeze every loop box's plist at whatever it was installed with.
  if [ -n "$ACTIVE_LABEL" ] && [ "$ACTIVE_LABEL" != "$LABEL" ]; then
    # ── ADOPT the job this box already runs ───────────────────────────────────────────────────────
    [ -f "$ACTIVE_PROG" ] || unknown "the launchd job $ACTIVE_LABEL runs $ACTIVE_PROG, and that file is not in $O after the deploy — starting it would exec a missing program; restore the file (it is in this box's resolver set, so the deploy never removes it) or fix the job, then re-run: $0 start"
    log_line "==> launchd job $ACTIVE_LABEL already owns $O ($ACTIVE_PLIST) — starting THAT job; NOT rendering $LABEL, which would be a second job (and a second controller) for one state dir"
    local state
    launchd_job_state "$ACTIVE_LABEL"; state="$JOB_STATE"
    case "$state" in
      yes)
        if [ -n "$JOB_PID" ]; then
          ok "launchd job $ACTIVE_LABEL is already RUNNING (job pid $JOB_PID) — left alone: it owns this state dir, and cycling a healthy supervisor would only drop supervision for the moment it takes to come back"
        else
          launchctl kickstart "gui/$(id -u)/$ACTIVE_LABEL" \
            || refuse "launchctl kickstart gui/$(id -u)/$ACTIVE_LABEL failed — the job that owns $O is loaded but not running; check: launchctl print gui/$(id -u)/$ACTIVE_LABEL"
        fi
        ;;
      no)
        launchctl load -w "$ACTIVE_PLIST" \
          || refuse "launchctl load -w $ACTIVE_PLIST failed — the job that owns $O is installed but not running; check: launchctl print gui/$(id -u)/$ACTIVE_LABEL"
        ;;
      *)
        unknown "launchd's state for $ACTIVE_LABEL could not be read (${JOB_PID:-no pid}) — whether the job that owns $O is running cannot be determined, so nothing was loaded"
        ;;
    esac
    STARTED_PID="$(await_pid controller_pid_owned)"
    # ⛔ PROVEN, not inferred: this pid came from the lock plus this state dir's own process set, which
    # is the strict scope. The `grep -qx` proof in cmd_start asks a different question ("is launchd's
    # pid an orch-loop.sh"), and on an adopting box launchd's pid is the SUPERVISOR — asking it there
    # refuses a controller that is demonstrably running (measured: pid 32325 is an orch-loop.sh, the
    # job's pid is its parent).
    STARTED_PID_PROVEN=1
    return 0
  fi
  if ! env -i \
        HOME="$HOME" PATH="$PATH" \
        O="$O" REPO="$REPO" OR="$SLUG_REPO" \
        ${SCOPE:+SCOPE="$SCOPE"} \
        bash "$HARNESS_BRINGUP/install.sh"; then
    refuse "install.sh failed to render the launchd agent (see its output above) — no controller was started"
  fi
  local plist; plist="$(plist_path)"
  [ -f "$plist" ] || unknown "install.sh reported success but $plist does not exist — refusing to claim a controller that has nothing to load"
  launchctl unload -w "$plist" >/dev/null 2>&1 || true
  launchctl load -w "$plist" || refuse "launchctl load -w $plist failed — the agent is installed but not running; check: launchctl print gui/$(id -u)/$LABEL"
  STARTED_PID="$(await_pid launchd_pid)"
}

launchd_pid() {
  launchctl print "gui/$(id -u)/${ACTIVE_LABEL:-$LABEL}" 2>/dev/null | sed -n 's/^[[:space:]]*pid = \([0-9][0-9]*\).*/\1/p' | head -1
}

# ── stop ──────────────────────────────────────────────────────────────────────────────────────
cmd_stop() {
  if [ -n "${REPO:-}" ] && [ -d "${REPO:-}" ]; then
    # ⛔ REPORT, never die: `stop` is the verb an operator reaches for on a machine that is wrong,
    # and it must stay answerable (the supervisor's own tested rule for its `status`). A pair that
    # cannot be resolved costs the registry release below — and that is SAID, not silent.
    if resolve_repo_identity; then
      SLUG="$(registry_slug "$SLUG_REPO" 2>/dev/null)" || SLUG=""
    else
      warn "$IDENTITY_MSG — continuing; the registry record (if any) will be left in place"
    fi
  fi
  case "$PLATFORM" in
    cell)
      [ -f "$SUPERVISOR" ] || unknown "no cloud-cell-supervisor.sh at $SUPERVISOR — cannot stop a cell controller from here"
      bash "$SUPERVISOR" stop || refuse "cloud-cell-supervisor.sh stop failed (see its output above) — the controller may still be running"
      ;;
    mac)
      # ⛔ SAME QUESTION, SAME ANSWER AS `start`. This branch used to unload `com.eldato.orchestrator-loop`
      # unconditionally; on a box whose job is named differently that unloads nothing (or worse, a
      # stale second job), and `stop` then reports "not running" over the stack it never touched.
      # Ambiguity is a REFUSAL here rather than a silent pick: two jobs own one state dir, and
      # unloading the wrong one leaves a live controller behind an entry point that no longer knows it.
      launchd_active_job || refuse "TWO launchd jobs name a program in $O: $ACTIVE_JOBS — only a human can say which one is this state dir's; nothing was stopped. Reconcile by hand: launchctl bootout gui/$(id -u)/<label>"
      local plist live; plist="$(plist_path)"
      if [ -f "$plist" ]; then
        # ⛔ `launchctl unload -w` EXITS 0 WHILE PRINTING "Unload failed" (measured on macOS: a plist
        # that was never loaded gives `Unload failed: 5: Input/output error` and rc=0). Trusting that
        # exit code made `stop` report "controller stopped" over an agent it had not stopped — a false
        # PASS on the one verb whose whole job is to make "is it still running?" false (#1856 review).
        # The answer is the READ AFTER, never the command's status.
        launchctl unload -w "$plist" 2>/dev/null || true
        sleep 1
        # ⛔ THE READS ARE CAPTURED SEPARATELY. `$( { launchd_pid; owned_pids; } | awk )` keeps only
        # awk's status, so an unreadable `ps` produced an EMPTY `live`, and `stop` then said
        # "controller stopped" over a live agent and released the registry record (#1856 review,
        # reproduced with a failing `ps` stub).
        local lpid lowned
        lpid="$(launchd_pid)"
        lowned="$(owned_pids)" || unknown "cannot verify whether the agent is still running (ps/etime unreadable) — refusing to report 'stopped' from an unreadable read"
        live="$(printf '%s\n%s\n' "$lpid" "$lowned" | awk 'NF && !s[$0]++')"
        [ -z "$live" ] || refuse "launchctl unload returned success but the agent is STILL RUNNING (pid $(pids_join "$live")) — check: launchctl print gui/$(id -u)/$LABEL"
        log_line "controller stopped (launchd $LABEL)"
      else
        # No agent file does NOT mean no controller: a controller started outside launchd (or whose
        # plist was removed by hand) is still live, and #1761's contradiction 2 is exactly that
        # state. Report it; never claim "not running" over it, and never erase the record.
        live="$(owned_pids)" || unknown "cannot verify whether a controller is running (ps/etime unreadable) — refusing to report 'not running' from an unreadable read"
        if [ -n "$live" ]; then
          refuse "no launchd agent at $plist, but a controller IS running for this state dir (pid $(pids_join "$live")) — stop it by hand (kill $(pids_join "$live")), or give it an agent: $0 start"
        fi
        log_line "not running (no agent at $plist, no controller process for $O)"
      fi
      ;;
  esac
  # Release ONLY this state dir's record. A record for another $O is another controller's.
  if [ -n "${SLUG:-}" ]; then
    local f; f="$(registry_file "$SLUG_REPO")"
    if registry_release "$f" "$O"; then
      [ -f "$f" ] || ok "registry entry for $SLUG_REPO released"
    else
      warn "the registry entry for $SLUG_REPO names a DIFFERENT state dir ($(registry_get "$f" O)) — left in place"
    fi
  fi

  # ── the REST of the fleet ────────────────────────────────────────────────────────────────────
  # A stopped controller with a live heartbeat loop and a live pr-doctor is a HALF-stopped fleet: the
  # loops keep nudging a lane that nothing dispatches to, and the doctor keeps dispatching work with
  # no controller behind it.
  #
  # SCOPE (said out loud because it is easy to assume otherwise): the components below are
  # MACHINE-GLOBAL — the heartbeat loop and the cadence timer live in $HOME/.pi/agent/state, and
  # pr-doctor, the reapers and the watchdog are machine-wide launchd jobs. This entry point's identity
  # is the PAIR (machine, repo) (#1761), so `stop` on repo B also silences the box's heartbeat and
  # pr-doctor while repo A's controller keeps dispatching. That is intentional (a stopped controller
  # with a live doctor is worse) and it is printed by `fleet_stop_all`, not implied.
  #
  # ⛔ THE INVENTORY REMOVES JOBS WITH `bootout` — never `unload -w`/`enable`, which write a
  # persistent override; `start` puts every one of them back because nothing durable was written.
  # The CONTROLLER above is a different path: it is stopped by the platform verb (`stop_mac` uses
  # `launchctl unload -w`), which predates this change and is NOT made safe by it — see
  # `orchestrator-harness/launchd-cycle.sh`, the repo's one implementation of
  # stop/enable/(re)start that never writes a disable (#1975). Do not read this file's `bootout`
  # discipline as covering the controller's agent.
  log_line ""
  fleet_stop_all "$(harness_ctl_path)" || warn "one or more fleet components could not be stopped (see above)"
  return 0
}

# ── restart ──────────────────────────────────────────────────────────────────────────────────
# Stop, then start, then VERIFY — the cycle an operator wants when a component is LATE or was
# restarted under a stale environment. It is a composition of the two verbs above, deliberately: a
# third implementation of start would be the fourth copy this entry point exists to prevent.
cmd_restart() {
  log_line "==> restarting the $PLATFORM fleet"
  # The stop runs in a SUBSHELL: `cmd_stop` owns an EXIT-path (`unknown …` exits 2) and must not be
  # able to end the restart before the start has been attempted. Its verdict is reported, not obeyed:
  # a controller that was not running is not a reason to skip starting it.
  ( cmd_stop ) || warn "stop reported a problem — continuing to start anyway"
  # ⛔ AND WAIT FOR THE STREET TO CLEAR BEFORE STARTING. `kill -TERM` returning 0 says the signal was
  # queued, not that the process is gone; starting while a TERM'd loop is still alive makes `start`'s
  # read see the OLD component as OK (never restarting it), and lets cadence-timer's own pidfile guard
  # make the NEW timer a no-op against the still-dying one. Bounded: never hang a verb on a process
  # that refuses to die — say so instead.
  local i alive
  i=0
  while [ "$i" -lt 25 ]; do
    alive="$(fleet_pids_for "$(harness_ctl_path)/orch-loop.sh" "$O/orch-loop.sh" \
                               "$HOME/.pi/agent/scripts/heartbeat-loop.sh" \
                               "$HOME/.pi/agent/scripts/cadence-timer.sh" 2>/dev/null)" || alive=""
    alive="$(printf '%s' "$alive" | tr -d '[:space:]')"
    [ -z "$alive" ] && break
    sleep 0.2; i=$(( i + 1 ))
  done
  [ -z "${alive:-}" ] || warn "a fleet process was still alive after the stop (pid $alive) — starting anyway; if both old and new are live, 'status' reports a DUPLICATE row"
  log_line ""
  cmd_start
}

# ── status ────────────────────────────────────────────────────────────────────────────────────
# The one screen an operator reads. It answers, in order: what repo, which harness, is it running,
# who owns it, and — the question every other observable lies about — IS IT DISPATCHING. The
# candidate file's mtime is the read that catches the measured failure: a controller with a fresh
# heartbeat and a candidates.txt that has not moved is a controller doing nothing.
cmd_status() {
  # ⛔ RESOLVE the identity before reporting: `status` is the verb an operator runs to find out WHAT
  # this machine is doing, so printing `<unresolved>` for a perfectly readable checkout would make the
  # one screen they trust the least informative one. A pair that cannot be resolved is REPORTED (the
  # refusal is `check`'s job), never refused here — the same rule cloud-cell-supervisor.sh applies to
  # its `status`. While `resolve_repo_identity` refused by EXITING, this line killed the whole screen
  # and printed nothing at all (#1856 review, reproduced: rc=1, 0 bytes on both streams).
  local ident_err=""
  if [ -n "${REPO:-}" ] && [ -d "${REPO:-}" ]; then
    if resolve_repo_identity; then
      SLUG="$(registry_slug "$SLUG_REPO" 2>/dev/null)" || SLUG=""
    else
      ident_err="$IDENTITY_MSG"; SLUG_REPO=""
    fi
  fi
  log_line "platform:  $PLATFORM"
  log_line "repo:      ${SLUG_REPO:-<unresolved>}  @ ${REPO:-<unset>}${REPO_SRC:+  (${REPO_SRC})}"
  [ -z "$ident_err" ] || log_line "identity:  UNRESOLVED — $ident_err"
  log_line "state dir: $O"
  log_line "config:    $ENV_FILE$([ -f "$ENV_FILE" ] && printf ' (present)' || printf ' (absent)')"
  if [ "$PLATFORM" = "cell" ]; then
    local recorded=""; [ -f "$HARNESS_PIN_FILE" ] && recorded="$(head -1 "$HARNESS_PIN_FILE" 2>/dev/null)"
    log_line "harness:   ${recorded:-$(harness_ctl_path) (not pinned — running from the checkout)}"
    [ -f "$O/.agent-infra-stamp.json" ] && log_line "stamp:     commit $(sed -n 's/.*"commit": *"\([^"]*\)".*/\1/p' "$O/.agent-infra-stamp.json" | head -1) relation $(sed -n 's/.*"relation": *"\([^"]*\)".*/\1/p' "$O/.agent-infra-stamp.json" | head -1)"
  else
    [ -f "$O/.agent-infra-stamp.json" ] && log_line "harness:   $(sed -n 's/.*"harness": *"\([^"]*\)".*/\1/p' "$O/.agent-infra-stamp.json" | head -1)"
  fi
  local lp live own foreign undet=0 lp_set=0
  # ⛔ ONE UNREADABLE DATUM MUST NOT SUPPRESS THE WHOLE DELIVERABLE. `unknown` EXITS 2, and these three
  # reads used to call it BEFORE the fleet table — so when the lock owner's age could not be read, the
  # other nine component verdicts printed nothing exactly when one read failed, even though the
  # inventory has a first-class UNKNOWN state for that. The abstention is now REPORTED in place and
  # carries the exit code at the end; the table still prints. (Reviewer 2 measured the truncation, and
  # the mirror-image defect: this path abstained where the inventory invented an owner for the same
  # datum — `_fleet_lock_owner` now abstains too, so both surfaces answer alike.)
  lp_set=0
  if ! lp="$(lock_pid)"; then
    log_line "lock:      CANNOT DETERMINE (ps/etime unreadable)"
    undet=1; lp=""
  else
    lp_set=1
  fi
  if ! live="$(local_controller_pids)"; then
    log_line "controller: CANNOT DETERMINE (the process table could not be read — see the table below)"
    undet=1; live=""
  fi
  if ! own="$(owned_pids)"; then
    log_line "controller: CANNOT DETERMINE (which controllers belong to this state dir — see the table below)"
    undet=1; own=""
  fi
  foreign="$(comm -23 <(printf '%s\n' "$live" | awk 'NF' | sort -u) <(printf '%s\n' "$own" | awk 'NF' | sort -u))"
  # ⛔ ONE ANSWER PER QUESTION. When a read abstained the controller line above already said CANNOT
  # DETERMINE; no line below can be better, and `foreign` (= live minus own) is non-empty *because*
  # own is empty — so falling through reported this state dir's OWN controller as "NOT attributable to
  # this state dir" (#1856's misattribution) and asserted `lock: none` about a lock it could not read.
  local lptxt="${lp:-none}"
  [ "${lp_set:-0}" = 1 ] || lptxt="CANNOT DETERMINE"
  if [ "$undet" = 1 ]; then
    :   # reported above; the table below carries the inventory's own UNKNOWN row
  elif [ -n "$own" ]; then
    log_line "controller: RUNNING  pid $(pids_join "$own")  (lock: $lptxt)"
  elif [ -n "$foreign" ]; then
    # ⛔ SEEN IS NOT OWNED: this machine's harness is shared by every repo on it, so this pid may be
    # the other repo's controller. Naming it as this state dir's owner is the misattribution the
    # review reproduced (#1856).
    log_line "controller: RUNNING  pid $(pids_join "$foreign") — NOT attributable to this state dir (the harness path is shared per box, so this may be another repo's controller; lock: $lptxt)"
  elif tmux has-session -t "=${SESSION:-orch}" 2>/dev/null; then
    # ⛔ NOT "RUNNING". Reviewer C measured this exact screen carrying `controller: RUNNING` beside the
    # fleet table's `controller … MISSING` — two answers to one question, in one command. The table's
    # predicate is the authoritative one (it also carries the harness population and the heartbeat
    # age); a tmux session with no controller process under it is a DANGLING session, not a running
    # controller, and saying RUNNING here is how a reader concludes the table is broken instead of the
    # controller. `-t =name` forces an exact match: plain `-t orch` PREFIX-matched, and on this box it
    # was satisfied by a session called `orch-controller`.
    log_line "controller: NOT RUNNING  (tmux session ${SESSION:-orch} exists with no orch-loop.sh under it — see the table below; a supervisor that died can leave this)"
  else
    log_line "controller: STOPPED"
  fi
  # ⛔ AND REPORT THE OTHER REPO EVEN WHEN THIS ONE OWNS A CONTROLLER. The `elif` above published the
  # foreign population only when this state dir owned nothing, so on a two-repo machine B's `status` —
  # the one screen an operator reads — showed B's controller and never mentioned A's, although the
  # read had it. `check` prints both; two answers to one question is the defect, and an unreported
  # population is how a reader over-reads a verdict (#1856 review; docs/ops/fleet-liveness.md §5).
  [ -z "$own" ] || [ -z "$foreign" ] \
    || log_line "also seen:  pid $(pids_join "$foreign") — NOT attributable to this state dir (the harness path is shared per box); reported, never signalled"
  if [ -n "${SLUG:-}" ]; then
    local f v; f="$(registry_file "$SLUG_REPO")"; v="$(registry_verdict "$f" | tr '\t' ' ')"
    log_line "registry:   $v$([ -f "$f" ] && printf '  (%s)' "$f")"
  else
    log_line "registry:   not consulted (repo identity unresolved)"
  fi
  if [ -f "$O/candidates.txt" ]; then
    local n mt age
    n="$(wc -l < "$O/candidates.txt" 2>/dev/null | tr -d ' ')"
    mt="$(date -r "$O/candidates.txt" -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$(stat -c %Y "$O/candidates.txt" 2>/dev/null || echo 0)" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
    age=$(( $(date +%s) - $(date -r "$O/candidates.txt" +%s 2>/dev/null || stat -c %Y "$O/candidates.txt" 2>/dev/null || date +%s) ))
    log_line "candidates: ${n:-0} line(s), mtime ${mt:-?} (${age}s ago)"
    # ⛔ The read that catches "alive but dispatching nothing": refresh aborts leave this file at 0
    # lines, and the controller's cycle line keeps being fresh. Reported, never auto-repaired.
    if [ "${n:-0}" -eq 0 ]; then
      warn "the candidate file is EMPTY — a running controller with an empty backlog is the measured 'alive but dispatching nothing' state; check $O/logs/orch-loop.log for a refresh abort"
    fi
  else
    log_line "candidates: <no file at $O/candidates.txt>"
  fi
  [ -f "$O/heartbeat" ] && log_line "heartbeat:  $(( $(date +%s) - $(cat "$O/heartbeat" 2>/dev/null || echo 0) ))s ago"

  # ── THE FLEET TABLE ──────────────────────────────────────────────────────────────────────────
  # The screen above answers "is THE CONTROLLER alive". This answers the question the owner asked
  # and no surface answered: is EVERY fleet component alive, exactly once, and on this box at all.
  # The exit code is the worst row, so `status` stops being advice and becomes a verdict — the
  # controller can be perfectly healthy while `pr-doctor` has exited 2 for hours and no lander lands.
  log_line ""
  log_line "fleet components (declared in scripts/lib/fleet-inventory.sh):"
  local fleet_rc
  fleet_rows "$(harness_ctl_path)" | fleet_render_table
  fleet_rc=$?
  # An abstaining detail read is rc=2 even when every row is green: "cannot determine" outranks
  # "healthy", and it must not be lost because the table happened to be all-OK.
  if [ "$fleet_rc" -eq 0 ] && [ "${undet:-0}" = 1 ]; then return 2; fi
  return "$fleet_rc"
}

# ── main ──────────────────────────────────────────────────────────────────────────────────────
[ "$RESEED" = 1 ] && cmd_reseed
case "$VERB" in
  check)  cmd_check ;;
  start)  cmd_start ;;
  stop)   cmd_stop ;;
  restart) cmd_restart ;;
  status) cmd_status ;;
esac
