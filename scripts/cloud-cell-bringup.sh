#!/bin/bash
# cloud-cell-bringup.sh — prepare a cmux Cloud VM to run pi agent lanes.
#
# Runs ON THE VM (Linux). Push it, then:
#   cmux vm push <machine> cloud-cell-bringup.sh cloud-cell-bringup.sh
#   cmux vm exec <machine> -- sh -lc 'bash cloud-cell-bringup.sh --check'
#
# WHY THIS EXISTS. Validated 2026-10-12/13 on vm-efa6cc8fdb974e61b5c054acf41d8846
# (Pro, 8g/4vCPU). The devbox is far better than assumed — pi 0.85.1, docker (daemon
# UP), gh, git, node, python, uv, tmux are ALL preinstalled, and the network reaches
# github.com. But three frictions make a naive lane fail DEAD, and all three are
# silent-ish, so they are handled explicitly here rather than left to the operator:
#
#  (1) HOME DOES NOT EXIST.  cmux vm exec runs as user `cmux` with HOME=/home/ubuntu,
#      and /home/ubuntu is NOT created on the image. Anything that writes to $HOME
#      dies with `mkdir /home/ubuntu: permission denied` — gh cannot create its
#      config, git cannot store credentials, pi cannot write its session dir.
#      Measured: `gh auth login --with-token` then `gh auth status` still reported
#      "not logged in" AFTER a successful login, purely because of this.
#      FIX: use a writable HOME. /root is root-only; /tmp/<user> works.
#
#  (2) THE IMAGE'S PROVIDER KEY IS STALE.  ANTHROPIC_API_KEY is pre-set in the guest
#      env and pi picks it up, so pi LOOKS configured — and then every call returns
#      `401 {"type":"error","error":{"type":"authentication_error","message":"invalid
#      x-api-key"}}`. A lane would appear to run and produce nothing.
#      FIX: push a known-good key and verify it with a real call, not by inspection.
#
#  (3) `cmux vm env set` LIES.  It printed `OK set 1 variable`, but `cmux vm env ls`
#      then reported "no machine env yet", and the value never reached exec's login
#      shell (it is per-user, and exec is a different user). Do NOT rely on it.
#      FIX: `cmux vm push --secret` the dotenv file and source it.
#
# Also note: `cmux vm exec` does NOT forward stdin — `gh auth login --with-token`
# piped in HANGS until timeout (measured: exit 124). Push a secret file instead.
#
#  (4) THE PUSHED TOKEN FILE MUST NOT OUTLIVE THE RUN.  The operator pushes the token as a FILE, so
#      the file is a credential on the VM's disk until it is deleted — and deleting it on the
#      success branch alone left a push-capable token behind on every failed/aborted bring-up
#      (agent-infra#1718). Its lifetime is bounded by an EXIT trap; see SECRET LIFETIME below.
#
#  (5) THE OPERATIONAL LAYER IS NOT ON THE CELL (agent-infra#1723).  Measured 2026-10-15 on the
#      live cell pi-lane-1 / vm-efa6cc8fdb974e61b5c054acf41d8846: $CELL_HOME/.pi/agent held only
#      models.json, auth.json, .ai-review-gate-key, reviews/, state/, audit/ and shims/ — no
#      scripts/ (the directory did not exist), no extensions/, no skills/, no AGENTS.md, no
#      settings.json. So a cell lane ran with NO review-enforcer, verification-gate,
#      main-worktree-guard, search-guard or audit-logger — not the same guards as a laptop lane —
#      and its merge path died rc=127 on the missing $HOME/.pi/agent/scripts/record-review.sh,
#      the exact path merge-one.sh:240 executes.
#      FIX: install it BY CONSTRUCTION — pi-bootstrap/cell-install.sh, run from the --check path
#      below, from an agent-infra checkout that is already on the cell. That path VERIFIES first
#      and installs only when the read-back refuses, so a re-run on a provisioned cell costs a
#      read-back rather than a re-copy. A cell that cannot receive the layer is REFUSED rather
#      than certified: a green `CELL READY` over an unguarded cell is the false PASS this whole
#      script exists to remove.
#
#  (6) THE SCHEDULED LAYER NEVER REACHED THE CELLS AT ALL (agent-infra#1864).  Every recurring job
#      is declared once, as a launchd plist under templates/launchd/, and delivered by
#      scripts/install-launchd.sh — which needs launchd. Measured 2026-10-16 across the fleet:
#      scheduled jobs 24 on the Mac and 0 on each of the three cells; reap scripts 4 / 0 / 0 / 0;
#      heartbeat running / DEAD / DEAD / DEAD. So a cell ran lanes with no idle-session reaping,
#      no worktree reaping, no lane-liveness report and no canary — and, since the only instrument
#      that would have said so was itself one of the missing jobs, nothing announced it.
#      FIX: check_schedule() below, running scripts/fleet-schedule.py — a portable runtime that
#      reads the SAME plists (no hand-ported second copy) and, because a cell has no crontab
#      binary and no systemd user bus, runs them from a supervised in-session loop. It is part of
#      THIS documented path, so a fresh cell gets it; and it ends by verifying from the per-job
#      run stamps, so "scheduled" is asserted from a run rather than from a loaded unit.

set -uo pipefail

CELL_HOME="${CELL_HOME:-/tmp/cell-home}"
# The agent-infra checkout `check_operational_layer` trusted and installed the layer from. Global so
# later steps (the disk-reaper timer's TEMPLATES_DIR) use the SAME checkout, rather than resolving a
# second, possibly untrusted one.
LAYER_ROOT=""
REPO_SLUG="${REPO_SLUG:-daniel-ospina/tortoise}"
WORKDIR="${WORKDIR:-/tmp/cell}"
ENV_FILE="${ENV_FILE:-$CELL_HOME/keys.env}"
# The pushed gh token. Overridable for the same reason every other path here is (a hermetic test
# must never touch the REAL /tmp/.gh-tok) — see the secret-lifetime block below.
GH_TOKEN_FILE="${GH_TOKEN_FILE:-/tmp/.gh-tok}"
# ── the harness PIN, in the SAME three names the supervisor uses (#1745/#2215) ────────────────────
# `check_harness_pin` below materialises/validates it. The defaults are deliberately identical to
# cloud-cell-supervisor.sh:777-779 and to `status`'s reader (:2237), so a box brought up here is a box
# the supervisor agrees with — two different defaults for one pin is how a cell reads `pinned=none`
# with three pin files on disk.
HARNESS_REF="${HARNESS_REF:-origin/main}"
HARNESS_PIN_DIR="${HARNESS_PIN_DIR:-$CELL_HOME/harness}"
HARNESS_PIN_FILE="${HARNESS_PIN_FILE:-$CELL_HOME/.harness-path}"
HARNESS_PIN_RECORD="${HARNESS_PIN_RECORD:-$CELL_HOME/.pi/agent/state/HARNESS-PIN}"
MODE="${1:---check}"
# Set by `check_disk_reaper` and read by `check_reaping_armed`, so the two checks name the SAME reaper
# and the same last-pass reading (#2916 check 5).
DISK_REAPER_RESOLVED=""
DISK_REAPER_LAST=""
# ── swap seams (agent-infra#2390) — every path and knob overridable, for the same reason the token
# path is: a hermetic suite must never create swap (or edit /etc) on the host that runs it.
SWAPFILE="${SWAPFILE:-/swapfile}"
SWAP_MB="${SWAP_MB:-}"                 # empty = derive from MemTotal (the predicate below)
SWAP_PROC="${SWAP_PROC:-/proc/swaps}"  # the kernel's own swap record: the state, not a claim about it
SWAP_FSTAB="${SWAP_FSTAB:-/etc/fstab}"
SWAP_SYSCTL_CONF="${SWAP_SYSCTL_CONF:-/etc/sysctl.d/99-cell-swap.conf}"
SWAP_SYSCTL_FILE="${SWAP_SYSCTL_FILE:-/proc/sys/vm/swappiness}"
SWAP_SWAPPINESS="${SWAP_SWAPPINESS:-30}"
# The privilege seam. Word-split ON PURPOSE: `sudo -n` is TWO argv entries. Empty = run as we are
# (the suite's seam); `false` is how a case reproduces a cell that cannot escalate.
SWAP_SUDO="${SWAP_SUDO-sudo -n}"

log_line()  { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }
die()  { log_line "FATAL: $*" >&2; exit 1; }
ok()   { log_line "ok: $*"; }
warn() { log_line "warn: $*"; }

# ── SECRET LIFETIME — a secret file must not outlive the bring-up (agent-infra#1718) ────────────
# The gh token is PUSHED to the cell as a FILE by the operator, and the pre-fix cleanup sat AFTER
# the guard it was paired with:
#
#     gh auth login --with-token < "$tokfile" || die "gh auth failed from $tokfile"   # ← exits here
#     rm -f "$tokfile" && ok "token file removed"                                     # ← success only
#
# So `die` exited first and left a PUSH-CAPABLE token on the VM whenever the login failed (a
# stale/revoked token, a network fault) or the script aborted anywhere in between — measured: a
# cell brought up with a rejected token still carried /tmp/.gh-tok on disk afterwards. The same
# `rm -f … && ok …` also made a FAILED removal invisible: it printed nothing, and bring-up went on
# to its CELL READY banner with the token still there. The cleanup is therefore bound to the
# RESOURCE's lifetime, not to one branch of the auth result: every secret file is registered here
# and removed by an EXIT trap that is re-asserted after $ENV_FILE is sourced, so no `exit` — a `die`,
# the unknown-mode exit, or a signal — can skip it, and an accidental `trap - EXIT` line in keys.env
# cannot disarm it. (A keys.env is arbitrary code with this shell's privileges, so it can defeat any
# in-shell cleanup — this defends against the accident, not against a hostile file.)
#
# SECRET INVENTORY (the grep this fix owes: every secret the bring-up touches, and its disposition)
#   * $GH_TOKEN_FILE (default /tmp/.gh-tok) — the pushed push-capable gh token. TRANSIENT: pushed
#     only to seed `gh auth login`, so it is REGISTERED here and removed on every exit.
#   * $ENV_FILE (keys.env) — operator-pushed, and NOT a bring-up byproduct: the cell's own session
#     re-sources it (cloud-cell-supervisor.sh) for the provider keys and, for a merging cell,
#     AI_REVIEW_GATE_KEY. Removing it would take the cell's keys away, so it is deliberately left
#     in place — its lifetime is the CELL's, not this run's.
#   * $HOME/.config/gh/hosts.yml — written by `gh auth login`, and the credential the cell is
#     SUPPOSED to keep: cloud-cell-supervisor.sh's cmd_check refuses to run a controller without
#     `gh auth status`. Not a leftover, so not removed.
#   * $CELL_HOME/.pi/agent/.ai-review-gate-key — written by the operator/harness, never by this
#     script; not touched.
# Register below the moment this script starts handling another secret.
SECRET_FILES=()

# register_secret <path> — bound a file's lifetime to this process. Idempotent.
register_secret() {
  [ -n "${1:-}" ] || return 0
  local f
  for f in ${SECRET_FILES[@]+"${SECRET_FILES[@]}"}; do
    [ "$f" = "$1" ] && return 0
  done
  SECRET_FILES+=("$1")
}

# remove_secret_now <path> — remove ONE registered secret right now. Non-zero if it SURVIVES, so a
# caller can refuse to report success while a credential is still on disk.
#
# ⛔ The removal attempt is NEVER gated on a stat. `[ -e ]`/`[ -f ]` are FALSE both for an absent
# file AND for one whose PARENT DIRECTORY denies traversal (measured: mode 400 on the parent →
# `[-e]`/`[-f]` exit 1 while `ls` still lists the file), so a stat-gated cleanup reports "nothing to
# do" for a credential that IS on disk — the exact silent leftover this fix exists to prevent. `rm
# -f`'s own status is the only reliable signal: 0 iff the path is gone (an absent file is success by
# design), non-zero for EACCES/EPERM — which is the direction that must fail closed. The stat is
# kept for the LOG LINE only.
remove_secret_now() {
  local f="${1:-}" present=0
  [ -n "$f" ] || return 0
  [ -e "$f" ] && present=1
  rm -f -- "$f" 2>/dev/null || return 1
  [ "$present" = 1 ] && ok "secret file removed: $f"
  return 0
}

# SECRET_REPORTED — paths whose failure has already been announced. Both the pre-banner refusal and
# the EXIT trap run remove_secrets, and reporting the same credential twice leaves the operator
# counting credentials that are not there.
SECRET_REPORTED=()
report_survivor() {
  local f="$1" seen
  for seen in ${SECRET_REPORTED[@]+"${SECRET_REPORTED[@]}"}; do
    [ "$seen" = "$f" ] && return 0
  done
  SECRET_REPORTED+=("$f")
  # No CAUSE is claimed, deliberately: `rm -f` fails for a denied parent directory, but equally for
  # EROFS, an immutable file, EBUSY on a mount point, or EISDIR (the path is a directory). Naming
  # one would send an operator to `chmod` a directory on a read-only filesystem. "or even inspected":
  # a denied parent also hides the file from the stat above, so the honest claim is that we could
  # neither remove nor verify — not that a credential is definitely on disk. The direction is
  # deliberately fail-closed, and the operator is told to verify by hand.
  log_line "SECURITY: $f could not be removed (or even inspected); delete it by hand before handing this VM on" >&2
}

# remove_secrets — remove every registered secret. Non-zero if ANY survived.
remove_secrets() {
  local f survived=0
  for f in ${SECRET_FILES[@]+"${SECRET_FILES[@]}"}; do
    [ -n "$f" ] || continue
    remove_secret_now "$f" || { report_survivor "$f"; survived=1; }
  done
  return "$survived"
}

# install_secret_traps — (re)assert the secret-lifetime handler. Called at start-up AND again once
# $ENV_FILE has been sourced: that file is arbitrary shell, so a single `trap - EXIT` in it would
# DISARM the cleanup for the rest of the run (measured: with `trap - EXIT` as a keys.env line, a
# rejected login left the token on disk). The #1713 guard below cannot see this — it refuses a file
# that cannot be parsed or that ends with a top-level exit/exec, not one that edits our traps.
#
# ⚠️ There is deliberately NO INT/TERM/HUP handler, and adding one "so the EXIT trap runs" rests on a
# FALSE premise: an UNTRAPPED fatal signal already runs an EXIT trap. Measured on bash 3.2.57 and
# 5.3.15 — with only `trap … EXIT` set, an untrapped TERM/HUP ran the cleanup and the parent saw
# 143/129, whether the shell was waiting on a child, spinning in a builtin loop, or inside a `$( )`;
# bash re-raises the signal status after the trap, so 128+signo survives a trap that does not call
# `exit`. A handler would add a second, untestable path to the same cleanup (deleting the three it
# replaced left this suite green), so it is not carried.
install_secret_traps() {
  # `trap - EXIT` first stops a re-entry from the demotion below; signals are then IGNORED
  # (`trap "" …`, NOT `trap - …`, which would merely restore the fatal default) so a SECOND signal
  # cannot kill the shell half-way through the cleanup and leave the rest of the list behind.
  # PIPE is in that list for the same reason, and it is the one that actually bites: the cleanup LOGS
  # each removal, so when stdout is a pipe whose reader is gone the log write itself raises SIGPIPE.
  # Measured on bash 3.2.57 with only INT/TERM/HUP ignored — two registered secrets and a dead
  # stdout left the SECOND on disk, because the shell died on the first entry's log line before the
  # loop reached it. ⛔ The silence is scoped to this trap: outside it SIGPIPE keeps its default.
  # The handler is DEMOTE-ONLY: it never invents a status. A surviving secret turns a would-be 0 into
  # 1 (so `CELL READY` can never accompany a leftover credential); anything else FALLS THROUGH,
  # leaving bash's own status untouched. An explicit `exit "$?"` here would be wrong — `$?` inside
  # an EXIT trap after a fatal signal is 0, not 128+signo.
  trap 'rc=$?; trap - EXIT; trap "" INT TERM HUP PIPE; if ! remove_secrets && [ "$rc" -eq 0 ]; then exit 1; fi' EXIT
}

install_secret_traps
# The operator pushes the token BEFORE this script starts, so the file can already exist on the
# FIRST line: register the configured path here rather than only in check_gh, or an abort in
# check_tools/check_network re-opens exactly the window the pre-fix code left open.
register_secret "$GH_TOKEN_FILE"

# ── $ENV_FILE is SOURCED, so a top-level `exit`/`exec` in it ENDS THIS SCRIPT (agent-infra#1713) ──
# The same root measured in cloud-cell-supervisor.sh reproduces here: sourced directly with no
# `set -e`, a `keys.env` containing `exit 0` makes `--check` return 0 having printed NO `CELL
# READY` — bring-up "succeeds" by never reporting, and the operator reads the 0 as readiness. The
# assignments must still land in THIS shell (keys.env may set HOME and the provider keys), so the
# file is parsed, then evaluated in a throwaway subshell whose LAST action is a sentinel — the
# sentinel's ABSENCE means the file terminated its shell, `exit 0` included — and only then sourced
# for real. `set -e` is no help: `exit 0` IS a success status. Duplicated rather than shared:
# both scripts are pushed standalone onto a cell, with no library to source.
ENV_SENTINEL='__ai1713_env_sourced__'
source_env_file() {
  [ -f "$ENV_FILE" ] || return 0
  # A file bash cannot PARSE never terminates the shell: `.` fails and the script carries on, so
  # every variable it meant to set is missing while bring-up reports healthy. Refuse it here.
  bash -n "$ENV_FILE" || die "$ENV_FILE cannot be parsed (or read) as shell — sourcing it would silently drop every variable it sets"
  local probe
  probe="$(set -a; . "$ENV_FILE" >/dev/null 2>&1; set +a; printf '%s' "$ENV_SENTINEL")" || true
  [ "$probe" = "$ENV_SENTINEL" ] || die "$ENV_FILE did not finish sourcing — it contains a top-level 'exit'/'exec' (or a command that fails under its own 'set -e'), which ends this script and reports success (rc=0) having verified nothing. Remove it."
  set -a; . "$ENV_FILE"; set +a
  # ⛔ IMMEDIATELY AFTER THE SOURCE, BEFORE ANY CHECK READS A REPO: the pushed file can carry a GLOBAL
  # `GH_REPO`, and gh treats that as the default repo for EVERY command on the box (measured 2026-10-21:
  # agent-infra rails graded a tortoise PR and printed ALREADY MERGED over zero work). Dropped here, so
  # no step below — and no controller started later — inherits it.
  neutralise_gh_repo
}

# ── (1) a writable HOME ──────────────────────────────────────────────────────────
setup_home() {
  if [ ! -d "$CELL_HOME" ]; then
    mkdir -p "$CELL_HOME" 2>/dev/null || die "cannot create HOME=$CELL_HOME"
  fi
  [ -w "$CELL_HOME" ] || die "HOME=$CELL_HOME is not writable (uid=$(id -u))"
  export HOME="$CELL_HOME"
  ok "HOME=$HOME (writable)"
  if [ "${HOME_ORIG:-}" = "/home/ubuntu" ] && [ ! -d /home/ubuntu ]; then
    warn "the image's default HOME=/home/ubuntu does not exist — this script overrides it"
  fi
}

# ── ONE HOME (agent-infra#2916 check 1) ─────────────────────────────────────────────────────────
# MEASURED 2026-10-27, provisioning three cells: a cell ran with TWO homes — `/home/cmux` (the
# checkout) and `/tmp/cell-home` (the farm, the state, `keys.env`) — and everything below followed
# from that one fact, each of them reported as success somewhere:
#   `REPO is not set and no single checkout could be derived`;
#   17 jobs `broken target: /home/cmux/.pi/agent/scripts/… does not resolve — the farm is INCOMPLETE`
#     while the farm WAS installed (under the other home);
#   units hand-written with `ExecStart=/tmp/cell-home/...`, which each installer's `--status` then
#     certified as "installed" for 109 h.
# So the state is not detectable downstream: a check has to REFUSE it, at the gate, before a lane.
#
# ⛔ THE PREDICATE IS `CELL_HOME == the account's home`, NOT `HOME == CELL_HOME`. `setup_home` below
# EXPORTS `HOME=$CELL_HOME`, so by the time any later check runs the two are equal BY ASSIGNMENT and
# an equality test between them can never fail — a vacuous gate. The comparison therefore uses
# `HOME_ORIG` (captured before `setup_home`) when that directory exists, else the passwd record. On
# a cell `cmux vm exec` hands over `HOME=/home/ubuntu`, which does NOT exist (header (1)), so the
# passwd home is the honest answer there; on a laptop the two agree.
# Nothing repairs this: a second home is not a state any role can merge back — the remedy is to
# start the cell with `CELL_HOME=$HOME` and re-run. Named, not invented: no doctor role is added.
#
# FIXTURE SEAM, declared rather than hidden: `CELL_VOLATILE_ROOTS` is the list of roots a cell's
# state must not live in. Its shipped default (`/tmp:/var/tmp`) is what the red arm runs against; a
# hermetic suite sets it because ITS OWN home is under the host's temp dir, exactly like
# `SYSTEMD_UNIT_DIR` / `SWAP_SUDO` / `GH_TOKEN_FILE` — the alternative is a suite that cannot have a
# good cell at all.
CELL_VOLATILE_ROOTS="${CELL_VOLATILE_ROOTS:-/tmp:/var/tmp}"

_one_home_want() { # the account's own home — what CELL_HOME must BE
  local acct=""
  if [ -n "${HOME_ORIG:-}" ] && [ -d "${HOME_ORIG}" ]; then printf '%s\n' "$HOME_ORIG"; return 0; fi
  acct="$(getent passwd "$(id -un)" 2>/dev/null | awk -F: 'NR==1{print $6}')"
  [ -n "$acct" ] || acct="$(cd ~"$(id -un)" 2>/dev/null && pwd -P)"
  printf '%s\n' "${acct:-${HOME_ORIG:-${HOME:-}}}"
}

# is <path> under a volatile root AND outside the one home? (see the block above: a volatile path
# that IS under CELL_HOME is the volatile-home question, answered by the equality test, not here)
_one_home_under_volatile() {
  local p="${1:-}" root
  case "$p" in /*) ;; *) return 1 ;; esac
  case "$p" in "${CELL_HOME:-/nonexistent}"|"${CELL_HOME:-/nonexistent}"/*) return 1 ;; esac
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    case "$p" in "$root"|"$root"/*) return 0 ;; esac
  done <<EOF
$(printf '%s' "$CELL_VOLATILE_ROOTS" | tr ':' '\n')
EOF
  return 1
}

# The unit directories this cell's installers WRITE to, in the order they try them — the same
# read-side seams the supervisor uses (`CONTROLLER_SYSTEM_UNIT_DIR` / `…_USER_UNIT_DIR`, the reason
# its suite pins both sides), plus the installers' own `SYSTEMD_UNIT_DIR` write seam.
_one_home_unit_dirs() {
  local d
  for d in "${SYSTEMD_UNIT_DIR:-}" "${CONTROLLER_SYSTEM_UNIT_DIR:-/etc/systemd/system}" \
           "${CONTROLLER_USER_UNIT_DIR:-${HOME:-}/.config/systemd/user}"; do
    [ -n "$d" ] && printf '%s\n' "${d%/}"
  done | awk 'NF && !s[$0]++'
}

# Path-SHAPED tokens in one unit line. Splitting on `=` too is what makes `Environment=REPO=/tmp/x`
# yield `/tmp/x` rather than `REPO=/tmp/x`, and splitting on quotes/semicolons is what makes a path
# inside `ExecStart=/bin/bash -lc 'cd /tmp/x && …'` visible at all.
_one_home_scan_unit() { # <unit file> -> "<offending value>\t<file>" per hit
  local f="$1" line p
  while IFS= read -r line; do
    case "$line" in
      Environment=*|EnvironmentFile=*|ExecStart=*|WorkingDirectory=*) ;;
      *) continue ;;
    esac
    while IFS= read -r p; do
      case "$p" in /*) ;; *) continue ;; esac
      _one_home_under_volatile "$p" && printf '%s\t%s\n' "$p" "$f"
    done <<EOF
$(printf '%s' "$line" | tr ' \t"\047;,=' '\n')
EOF
  done < "$f"
}

check_one_home() { # <env|units>
  local leg="${1:-env}" want got bad="" line val dirs f n=0
  want="$(_one_home_want)"; want="$(cd "$want" 2>/dev/null && pwd -P || printf '%s' "$want")"
  got="$(cd "${CELL_HOME:-/nonexistent}" 2>/dev/null && pwd -P || printf '%s' "${CELL_HOME:-}")"
  if [ -z "${CELL_HOME:-}" ] || [ "$got" != "$want" ]; then
    die "CHECK FAILED [one home]: CELL_HOME ('${CELL_HOME:-<unset>}') is not this box's home ('${want:-<unknown>}') — the cell would run with TWO homes, which is the measured root of 'REPO is not set and no single checkout could be derived', of scheduled jobs whose farmed targets do not resolve because they look under the OTHER home, and of installers certifying a hand-written /tmp unit as their own. FIX: start the cell with CELL_HOME=\$HOME (measured-good: CELL_HOME=/home/cmux REPO=/home/cmux/tortoise), then re-run: HOME=\$HOME CELL_HOME=\$HOME bash $0 --check"
  fi
  if [ "$leg" = "env" ]; then
    # The paths THIS run will hand the cell. A /tmp one that is not under the one home is a second
    # tree no instrument is pointed at — the state the check exists to refuse.
    for line in ENV_FILE WORKDIR HARNESS_PIN_DIR HARNESS_PIN_FILE HARNESS_PIN_RECORD TEMPLATES_DIR; do
      eval "val=\${$line:-}"
      _one_home_under_volatile "$val" && bad="$bad${bad:+
}$val\t\$$line"
    done
    # …and the file the cell's own session will source. Its ASSIGNMENTS, not its path.
    if [ -f "${ENV_FILE:-}" ]; then
      while IFS= read -r line; do
        case "$line" in ''|'#'*) continue ;; *=*) ;; *) continue ;; esac
        val="${line#*=}"; val="${val%\"}"; val="${val#\"}"; val="${val%\'}"; val="${val#\'}"
        case "$val" in /*) ;; *) continue ;; esac
        _one_home_under_volatile "$val" && bad="$bad${bad:+
}$val\t$ENV_FILE"
      done < "$ENV_FILE"
    fi
    if [ -n "$bad" ]; then
      die "CHECK FAILED [one home]: a cell-state path lives outside the ONE home ($got) in a volatile root — this cell's farm, pin or checkout would be a second tree that a reboot deletes and no instrument looks at (measured: ENV_FILE=/tmp/cell-home/keys.env, REPO=/tmp/cell-t3, HARNESS_PIN_DIR=/tmp/cell-home/harness-next):
$(printf '%s\n' "$bad" | sed 's/^/    /')
FIX: move the state under \$HOME (CELL_HOME=\$HOME, and point WORKDIR/ENV_FILE/HARNESS_PIN_DIR there), then re-run this --check."
    fi
    ok "one home: CELL_HOME=$got (this box's home) — the env this run hands the cell carries no path outside it"
    return 0
  fi
  # ── units leg — runs LAST in --check, because the installers RENDER the units (scanning earlier
  # would certify an empty directory: the vacuity trap this fleet has been bitten by).
  # macOS renders NO systemd unit, so there is nothing to scan there — but "the platform has none"
  # stops being true the moment a run NAMES a unit directory (`SYSTEMD_UNIT_DIR` /
  # `CONTROLLER_SYSTEM_UNIT_DIR` are the same seams the suite and the supervisor use), and a leg that
  # refused to look whenever it was pointed at one could never be tested on a dev box. So the skip is
  # scoped to "Darwin AND no explicit unit dir".
  if [ "$(uname -s 2>/dev/null)" = "Darwin" ] \
     && [ -z "${SYSTEMD_UNIT_DIR:-}${CONTROLLER_SYSTEM_UNIT_DIR:-}${CONTROLLER_USER_UNIT_DIR:-}" ]; then
    warn "one home: the RENDERED UNITS were NOT scanned on macOS — the cell's systemd units are a Linux surface and launchd is out of scope here. Verify with: grep -HnE '^(Environment|ExecStart)=' \${CONTROLLER_USER_UNIT_DIR:-\$HOME/.config/systemd/user}/*.plist 2>/dev/null | grep /tmp"
    return 0
  fi
  dirs="$(_one_home_unit_dirs)"
  while IFS= read -r dir; do
    [ -n "$dir" ] && [ -d "$dir" ] || continue
    for f in "$dir"/eldato-*.service "$dir"/eldato-*.timer; do
      [ -f "$f" ] || continue
      n=$((n + 1))
      val="$(_one_home_scan_unit "$f")"
      [ -z "$val" ] || bad="$bad${bad:+
}$val"
    done
  done <<EOF
$dirs
EOF
  if [ "$n" -eq 0 ]; then
    die "CHECK FAILED [one home]: no rendered eldato-*.service|timer was found in any unit directory ($(printf '%s' "$dirs" | tr '\n' ' ')) — this leg cannot scan anything, and 'nothing to scan' is NOT a pass. Either the installers above did not render, or they rendered somewhere this check does not read: re-run with SYSTEMD_UNIT_DIR/CONTROLLER_SYSTEM_UNIT_DIR naming the real directory."
  fi
  if [ -n "$bad" ]; then
    die "CHECK FAILED [one home]: a RENDERED UNIT carries a path outside the ONE home ($got) in a volatile root — the measured state is a hand-written unit (`ExecStart=/tmp/cell-home/...`) that each installer's --status then certifies as 'installed', because a hand-written unit is indistinguishable from a rendered one:
$(printf '%s\n' "$bad" | sed 's/^/    /')
FIX: re-render it from the one home — 'cloud-cell-supervisor.sh apply' (or the owning installer's --install) — then re-run this --check."
  fi
  ok "one home: $n rendered unit(s) in $(printf '%s' "$dirs" | tr '\n' ' ') — no Environment=/ExecStart= path outside $got"
}

# ── toolchain — all preinstalled, but verify rather than assume ──────────────────
check_tools() {
  local missing=""
  # ⛔ jq IS A RUNTIME DEPENDENCY OF THE HARNESS ITSELF since the listings moved to REST (#1962):
  # `rest_list` assembles and projects every page with the jq BINARY, on the DISPATCH path — and it
  # probes for it rather than assuming it, so a cell without it is refused instead of reading
  # `queue=UNREADABLE` for ever. (jq was already used by the gh-rest adapter, `gh-rest/gh:229,238`,
  # but install.sh never resolved it into DAEMON_PATH, so that dependence was silently unmet on a
  # host without jq on the launchd PATH.) The entry in this list is what turns that into a REFUSAL at
  # bring-up: without it the cell would be certified and then read `queue=UNREADABLE` on every
  # refresh — merge-only — which `check_dispatch` can only catch one step later.
  for c in git gh node python3 uv tmux jq; do
    command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
  done
  [ -z "$missing" ] || die "missing required tools:$missing"
  if command -v pi >/dev/null 2>&1; then
    ok "pi $(pi --version 2>/dev/null | head -1)"
  else
    missing="$missing pi"
    die "pi is not installed (the devbox normally ships it)"
  fi
  if docker info >/dev/null 2>&1; then ok "docker daemon UP"; else warn "docker daemon not running — in-lane tests will fail"; fi
  ok "tools: git $(git --version | awk '{print $3}'), gh $(gh --version 2>/dev/null | head -1 | awk '{print $3}'), node $(node --version)"
}

# ── network ─────────────────────────────────────────────────────────────────────
check_network() {
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 https://github.com 2>/dev/null)"
  [ "$code" = "200" ] && ok "network: github.com 200" || die "cannot reach github.com (http=$code)"
}

# ── (2) provider key, verified by a REAL call ───────────────────────────────────
# answer_line <text> — the provider's answer, if the text carries one. LINE-based over the WHOLE
# output, never `tail`: on the cells the last three lines were a capture banner while the answer sat
# above them (#2100). The ONE exclusion is a byte-identical `Reply with exactly: LANE_READY` line —
# output that PRINTS THE INSTRUCTION LINE ITSELF would otherwise "answer" with no model call.
# Two declared limits of keeping it narrow (`-xF`): a model that wraps the token in the instruction
# has still answered and MUST count (the earlier `grep -vF 'Reply with exactly'` discarded any line
# containing the phrase and turned a verbose-but-correct answer into a false `provider probe
# failed`), and any OTHER line that happens to carry the token counts too — a wrapper echoing the
# prompt inside a longer line would answer for the model. The second is accepted rather than closed:
# closing it means matching the token exactly, which re-opens the first.
answer_line() {
  printf '%s\n' "$1" | grep -F 'LANE_READY' | grep -vxF 'Reply with exactly: LANE_READY' | head -1
}

check_provider() {
  if [ -f "$ENV_FILE" ]; then
    source_env_file
    # $ENV_FILE is arbitrary shell: re-assert the secret-lifetime handlers now that it has run, so a
    # `trap - EXIT` in it cannot leave the pushed credential on disk (agent-infra#1718).
    install_secret_traps
    ok "sourced $ENV_FILE"
    # ⛔ keys.env may carry a HOME= line, and every check below (check_gh reads $HOME/.config/gh,
    # check_repo resolves paths) must run under the same home the cell will use — the session
    # forces HOME=$CELL_HOME after its own source. Without this, a repointed home could make the
    # bring-up report "CELL READY" for a home the cell never uses.
    export HOME="$CELL_HOME"
  else
    warn "no $ENV_FILE — push one with: cmux vm push --secret <m> <local> $ENV_FILE --mode 600"
  fi
  if [ -z "${DEEPSEEK_API_KEY:-}" ] && [ -z "${ANTHROPIC_API_KEY:-}" ]; then
    die "no provider key set; a lane would run and return nothing"
  fi
  # Probe by EXECUTION. The image's ANTHROPIC key is present-but-invalid, so the
  # presence of the variable proves nothing.
  #
  # ⛔ SPLIT INTO TWO CHECKS ON PURPOSE (#2100). The cell's provider question and the cell's LAYER
  # question are answered at different points in `main()`: the provider verdict here, and the layer
  # verdict in `check_provider_layer` AFTER `check_operational_layer` has installed/verified the
  # layer. Measuring the layer here would probe an EMPTY extension set on a first bring-up — the
  # install lands afterwards — and then certify a layer it never saw.
  #
  # This function used to run ONE probe — `pi -p … 2>&1 | tail -3` with the WHOLE extension layer
  # loaded — so whatever an extension wrote became "the provider's answer". Measured 2026-10-19
  # (#2100, one box unusable while two ran lanes; the extension was present on all three and the
  # probe defect applied on all three): the affected cell's `tortoise-capture` consumed the turn
  # with banner lines only (259-262 B), the last three lines were the banner, and the bring-up
  # reported `FATAL: provider probe failed` for a box whose provider was healthy (`pi` returned
  # LANE_READY as soon as the extension was gone).
  #
  # THE PROVIDER VERDICT comes from the ISOLATED probe (`--no-extensions`) — the only probe the
  # layer cannot answer for, because a spool-replaying or banner-printing extension that emits the
  # token would otherwise satisfy a layer-loaded probe and certify a cell over a dead key. An
  # answer here proves the key; NO answer here is a provider verdict, and the classification below
  # (spawn-gate refusal / 401 / timeout / generic) owns it.
  # `--no-extensions` also excludes `clamp-output-floor.ts` and `reflect-hook.ts`, which ship on
  # cells and print registration-time banners by design — two more writers in this very channel.
  # It does NOT disable the spawn-point gate: that is `$CELL_HOME/.pi/agent/bin/pi` on PATH, not an
  # extension, so the #1884 refusal still fires.
  local out answer detail rc=0
  out="$(timeout 120 pi -p --no-session --no-extensions --provider deepseek --model deepseek-flash \
          'Reply with exactly: LANE_READY' 2>&1)" || rc=$?
  answer="$(answer_line "$out")"
  if [ -z "$answer" ]; then
    # Diagnostics only — the classification below decides.
    detail="$(printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | tail -5)"
    case "$out" in
      # ⛔ agent-infra#1884: `pi` is the SPAWN POINT now, and it refuses above the box's load ceiling —
      # which is NOT a provider failure. Without this arm the refusal lands in the catch-all below and
      # the bring-up reports "provider probe failed" for a call that never reached a provider, sending
      # an operator to re-push a perfectly good key. The remedy for a refusal is capacity, so say that.
      *'[pi-gate] REFUSED'*)
        die "provider probe NOT RUN: the pi spawn point refused the launch (1-min load is at or above MAX_LOAD on this box). That is CAPACITY, not the provider — quieten the box (or raise MAX_LOAD deliberately) and re-run. Last output: $detail" ;;
      *authentication_error*|*invalid*x-api-key*|*401*)
        die "provider key REJECTED (401). The image's pre-set key is stale — push a valid one." ;;
    esac
    # `timeout` reports a killed child as 124; that is NOT "the provider answered nothing", and
    # collapsing the two (the exit status was discarded before #2100's review) sends the operator
    # after a key that may be perfectly good.
    [ "$rc" -eq 124 ] && die "provider probe TIMED OUT after 120s (no answer, and no provider error). That is the CALL not completing — check the box's outbound network and load, then re-run. Last output: $detail"
    die "provider probe failed. Last output: $detail"
  fi
  ok "provider call works (pi returned LANE_READY)"
}

# ── (2b) the layer, verified by a LANE-SHAPED turn ─────────────────────────────
# Called from `main()` AFTER `check_operational_layer`, so what it measures is the layer the cell
# will actually run. A provider-only probe would let a layer that swallows every turn certify a
# cell that cannot run a lane — the mirror of the #2100 false FATAL — so this stays, and it is
# tried TWICE: one cold-start miss is not proof of a broken layer. When it does fail it FAILS,
# naming the layer and stating that the provider answered, rather than warning beside a
# `CELL READY` banner: a green readiness line over a box whose turns produce no answer is exactly
# the false PASS this script exists to remove.
check_provider_layer() {
  local layer_out layer_detail layer_rc attempt layer_tries=0 layer_timeouts=0 layer_rcs='' layer_evidence=''
  for attempt in 1 2; do
    layer_rc=0
    layer_out="$(timeout 120 pi -p --no-session --provider deepseek --model deepseek-flash \
                  'Reply with exactly: LANE_READY' 2>&1)" || layer_rc=$?
    [ -n "$(answer_line "$layer_out")" ] && { ok "the extension layer answers a lane-shaped turn (attempt $attempt)"; return 0; }
    # A spawn-gate refusal is CAPACITY, not the layer — classify it before blaming the layer, or the
    # operator is sent to bisect extensions on a box whose only problem is that it is busy (#1884).
    case "$layer_out" in
      *'[pi-gate] REFUSED'*)
        die "provider probe NOT RUN: the pi spawn point refused the LAYER-LOADED probe (1-min load is at or above MAX_LOAD on this box). That is CAPACITY, not the provider and not an extension — quieten the box (or raise MAX_LOAD deliberately) and re-run. Last output: $(printf '%s\n' "$layer_out" | grep -v '^[[:space:]]*$' | tail -5)" ;;
    esac
    # PER-ATTEMPT bookkeeping, not just the last one: a mix (one attempt banner-only, one killed at
    # 120 s) must not be reported as "timed out on both attempts" — that would discard the banner
    # evidence from the completed attempt and re-create the mis-attribution this PR removes.
    layer_tries=$((layer_tries + 1))
    [ "$layer_rc" -eq 124 ] && layer_timeouts=$((layer_timeouts + 1))
    layer_rcs="$layer_rcs${layer_rcs:+,}$layer_rc"
    layer_evidence="${layer_evidence}[attempt $attempt exit $layer_rc] $(printf '%s\n' "$layer_out" | grep -v '^[[:space:]]*$' | tail -3 | tr '\n' ' ') "
  done
  layer_detail="$(printf '%s\n' "$layer_out" | grep -v '^[[:space:]]*$' | tail -5)"
  # A killed probe is NOT the layer's fault. The provider already answered in isolation, so the key
  # is good: EVERY attempt killed by `timeout` (124) means the CALL did not complete (network/load),
  # and blaming an extension would send the operator to delete a healthy one — the same
  # mis-attribution the provider-side classification above exists to prevent. Said only when it is
  # true of every attempt.
  if [ "$layer_timeouts" -eq "$layer_tries" ]; then
    die "the LAYER-LOADED probe TIMED OUT after 120s on BOTH attempts (exits $layer_rcs) — that is the CALL not completing (outbound network or box load), NOT an extension: the provider answered with extensions disabled, so the key is good. Quieten the box, check the network, then re-run. Last output: $layer_detail"
  fi
  die "the PROVIDER is healthy (it answered with extensions disabled) but the EXTENSION LAYER produced no answer in two attempts (exits $layer_rcs) — a lane turn on this box would produce no answer, which is #2100's shape. Find the extension that writes to stdout at registration or session start, or remove it from the cell. Per attempt: $layer_evidence"
}

# ── (3) gh auth, via a pushed token file ────────────────────────────────────────
# The token file's lifetime is owned by the EXIT trap in the secret-lifetime block above; this
# function only reads it and drops it as soon as it has been consumed (agent-infra#1718).
check_gh() {
  local tokfile="${1:-$GH_TOKEN_FILE}"
  # Register BEFORE the read: from here on the token is bounded by the process, whatever happens
  # to the login below — the failure branch included.
  register_secret "$tokfile"
  if [ -f "$tokfile" ]; then
    gh auth login --with-token < "$tokfile" >/dev/null 2>&1 \
      && ok "gh authenticated from $tokfile" \
      || die "gh auth failed from $tokfile"
    # Consumed — drop it NOW so it does not sit on disk for the rest of the run, and do NOT let a
    # failed removal pass silently: the pre-fix `rm -f … && ok …` printed nothing when rm failed,
    # so a token that could not be removed still produced the CELL READY banner.
    remove_secret_now "$tokfile" \
      || die "could not remove the token file $tokfile — it is a push-capable credential; delete it by hand before using this VM"
  fi
  gh auth status >/dev/null 2>&1 || die "gh is not authenticated (push $GH_TOKEN_FILE via --secret)"
  local login; login="$(gh api user --jq .login 2>/dev/null)"
  [ -n "$login" ] && ok "gh login: $login" || die "gh cannot read the API"
  gh api "repos/$REPO_SLUG" --jq '.permissions.push' 2>/dev/null | grep -q true \
    && ok "push permission: true" || die "no push permission on $REPO_SLUG — lanes cannot open PRs"
}

# ── repo clone ──────────────────────────────────────────────────────────────────
check_repo() {
  if [ -d "$WORKDIR/.git" ]; then
    ok "repo present: $WORKDIR ($(git -C "$WORKDIR" rev-parse --short HEAD))"
  else
    mkdir -p "$(dirname "$WORKDIR")"
    git clone --depth 1 -q "https://github.com/$REPO_SLUG.git" "$WORKDIR" \
      && ok "cloned $REPO_SLUG -> $WORKDIR" || die "clone failed"
  fi
  # ── #2235: `GH_REPO` MUST NOT BE EXPORTED BY A CELL'S ENV ────────────────────
  # gh resolves its repo as flag > `GH_REPO` > the local checkout, so a GLOBAL
  # `GH_REPO` in `keys.env` makes every call that omits `--repo` answer for another
  # repo. Measured 2026-10-20/21 on every cell (`GH_REPO=daniel-ospina/tortoise`):
  #
  #   $ bash scripts/admin-merge.sh 2232
  #   admin-merge: ✅ PR #2232 is ALREADY MERGED (state=MERGED, mergedAt=2026-09-04T09:11:01Z)
  #                — duplicate execution is a NO-OP: no CI work, no evidence comment, no merge attempt
  #
  # a SEPTEMBER tortoise PR, exit 0, over an OPEN agent-infra one; and
  # `GraphQL: Could not resolve to a PullRequest with the number of 2231` for real open PRs.
  #
  # THE SUBJECT IS THE CHECKOUT THE CONTROLLER RUNS IN (`$WORKDIR`'s own origin), which is what
  # the requirement names. TWO OUTCOMES, deliberately different:
  #   * DISAGREEMENT ⇒ `die`. The env is actively wrong: every rail on the box would grade and
  #     report another repo's PRs, and that is the failure this check exists to make loud.
  #   * AGREEMENT ⇒ `warn` + `unset`. Nothing is wrong today, but a global export is still the
  #     DEFECT (it answers for every gh call that omits --repo, so the next checkout or renamed
  #     repo on this box turns it into a wrong answer with no signal). Refusing a cell whose env
  #     is merely redundant would be a false block with no safety gain — so it is stripped and
  #     reported instead. (The strip is local: the controller session re-sources keys.env, which
  #     is why `cloud-cell-supervisor.sh` strips it there too.)
  if [ -n "${GH_REPO:-}" ]; then
    local want have got
    want="$(git -C "$WORKDIR" remote get-url origin 2>/dev/null)" || want=""
    # Derive `<owner>/<name>` from the checkout's own origin — the same evidence the
    # controller's queue gate reads, with the same accepted shapes. ⛔ `.git` is stripped
    # AFTER the trailing slash (`…agent-infra.git/` is a shape the fleet's lockstep table
    # supports; stripping `.git` first left the dot-suffix in place and this check then DIED
    # with "names a DIFFERENT repository" for two spellings of the SAME repo — a false block
    # on the provisioning path, #2235 review P1).
    case "$want" in
      https://*|http://*|ssh://*) got="${want#*://}"; got="${got#*/}" ;;
      *@*:*)                      got="${want#*:}" ;;
      *)                          got="" ;;
    esac
    case "$got" in /*) got="" ;; esac          # empty path segment — refuse, never repair
    got="${got%/}"; got="${got%.git}"
    case "$got" in */*/*) got="" ;; esac
    if [ -z "$want" ]; then
      die "GH_REPO is exported by this cell's env ($GH_REPO) but $WORKDIR has no readable 'origin' remote, so the export cannot be verified against the checkout the controller runs in. A global GH_REPO is what produced the #2235 fail-open (a rail printing 'ALREADY MERGED' for a tortoise PR while grading agent-infra). Remove the GH_REPO line from $ENV_FILE — it is per-invocation state, never cell state."
    fi
    if [ -z "$got" ]; then
      # A READABLE origin that is not a slug (a local path, `file://`, a bare mirror…): the
      # export cannot be checked, so it is stripped rather than refused. Stripping is the safe
      # half — an unverifiable global export is exactly the defect — and dying here would block
      # provision on a legitimate non-GitHub origin with a diagnosis that does not apply.
      warn "GH_REPO is set to '$GH_REPO' but $WORKDIR's origin ($want) is not an <owner>/<name> slug, so the export cannot be verified against this checkout. Stripping it from this shell: gh gives GH_REPO precedence over the checkout for every call that omits --repo, so leaving it set lets a rail grade another repo (#2235)."
      unset GH_REPO
    fi
    if [ -n "${GH_REPO:-}" ]; then
      have="$(printf '%s' "$GH_REPO" | tr '[:upper:]' '[:lower:]')"
      # `[HOST/]OWNER/REPO` is the documented GH_REPO form (`gh help environment`), so
      # `github.com/o/r` names the SAME repo as `o/r` — comparing it verbatim died with
      # 'a DIFFERENT repository' on a correct cell (§2235 review P2). Drop a leading segment
      # only when it IS a host (dotted).
      case "$have" in
        */*/*)
          case "${have%%/*}" in *.*|*:*) have="${have#*/}" ;; esac ;;
      esac
      got="$(printf '%s' "$got" | tr '[:upper:]' '[:lower:]')"
      if [ "$have" != "$got" ]; then
        die "GH_REPO names a DIFFERENT repository than this cell's checkout: GH_REPO='$GH_REPO' but $WORKDIR is a checkout of '$got' (origin $want). gh gives GH_REPO precedence over the checkout for every call that omits --repo, so every rail on this cell would grade and report '$GH_REPO' PRs while believing it graded '$got' — measured as '✅ PR #2232 is ALREADY MERGED' (a September tortoise PR) over an open agent-infra one, exit 0 (#2235). FIX: remove the GH_REPO line from $ENV_FILE — it is per-invocation state; a command that needs another repo passes --repo."
      fi
      warn "GH_REPO is set to '$GH_REPO' (from $ENV_FILE or the ambient shell) and matches this checkout ($got) — nothing is wrong today, but the export is the DEFECT (#2235): it silently answers for every gh call that omits --repo, so the next checkout, clone or renamed repo on this box makes it a wrong answer with no signal. Remove the GH_REPO line from $ENV_FILE (per-invocation state; a command that needs another repo passes --repo). Stripping it from this shell."
      unset GH_REPO
    fi
  fi
  git -C "$WORKDIR" config user.email "cloud-lane@premiselabs.co"
  git -C "$WORKDIR" config user.name  "cmux cloud lane"
}

# ── dispatch provisioning: can this repo be pre-flighted? (agent-infra#1736) ─────
# A cell that cannot provision its dispatch scout merges forever with `lanes: 0`, and the
# controller stays RUNNING while it does — the refresh runs in a BACKGROUNDED subshell, so its
# abort cannot fail the loop. `--check` is the last gate before a cell is started; refuse here.
# Best-effort: bring-up is normally pushed standalone, so the harness is only present when the
# whole repo was cloned — cloud-cell-supervisor.sh `check` (which `start` calls) is the enforcing
# gate; this one makes the failure visible earlier, on the bare VM.
check_dispatch() {
  local harness out
  harness="${HARNESS:-$(cd "$(dirname "${BASH_SOURCE[0]}")/orchestrator-harness" 2>/dev/null && pwd)}"
  if [ ! -f "$harness/refresh-candidates.sh" ]; then
    warn "harness not found at $harness — cannot pre-verify dispatch provisioning here;"
    warn "  cloud-cell-supervisor.sh check (which 'start' calls) enforces it before the controller runs"
    return 0
  fi
  local out outrc
  out=""
  outrc=0
  # ── THE LANE ROSTER (agent-infra#1935) ─────────────────────────────────────────────────────
  # The pre-flight's holder surface is built FROM `$HOME/.pi/agent/state/lane-registry.tsv`
  # (tortoise `tools/fleet_state.py`), and the only thing that ever wrote it was the RETIRED cmux
  # dispatcher — so a cell has no roster, `load_registry` reports `measured=False`, the board
  # cannot answer, and EVERY candidate is INCOMPLETE. Measured on cell 1, 2026-10-28:
  #     issue assignee/holder INCOMPLETE … the roster was NEVER PROVISIONED in this cell
  #     [refresh] ABORT: none of the 12 candidate(s) … judged NOTHING
  # Provisioned HERE, from this box's OWN population, so "never provisioned" cannot recur.
  # ⛔ THIS `--check` PATH WRITES, DELIBERATELY AND IN THE OPEN (#3032 review F7). A `--check` that
  # silently mutated state would be a contract change; this one is stated instead: the roster is a
  # PREREQUISITE of dispatch, `--check` is the last gate before a cell is started, and a check that
  # only REPORTED an unprovisioned roster would leave the cell dispatching nothing — the defect
  # (#1935) this whole change removes. The write is idempotent (a second run writes nothing) and
  # non-destructive (a hand-maintained roster is never replaced, and an existing derived roster is
  # never shrunk by an arm that measured nothing).
  # ⛔ rc=3 is a WARNING, not a death: it means the population could not be MEASURED on this box,
  # and the harness's reduced-surface path (refresh-candidates.sh, #2848) can still dispatch by
  # handing the holder question to the cross-box claim registry. Killing a cell over an
  # unmeasurable roster would be a false block; refusing to write an empty one is the rule that
  # matters (#8175), and that lives in the provisioner.
  if [ -f "$harness/provision-lane-registry.py" ] && command -v python3 >/dev/null 2>&1; then
    local provout provrc
    provout=""; provrc=0
    provout="$(HOME="${CELL_HOME:-$HOME}" python3 "$harness/provision-lane-registry.py" --apply 2>&1)" || provrc=$?
    printf '%s\n' "$provout" | sed 's/^/    /'
    if [ "$provrc" -eq 3 ]; then
      warn "the LANE ROSTER could not be provisioned (the population was unmeasurable — see above);"
      warn "  the pre-flight's holder surface stays INCOMPLETE until it can be (agent-infra#1935)"
    elif [ "$provrc" -ne 0 ]; then
      # ⛔ A CRASH IS NOT A PROVISION (review finding 2): the provisioner's documented exits are
      # 0/2/3, so any other non-zero is a failure of the tool itself, never "provisioned".
      warn "the LANE ROSTER provisioning FAILED (rc=$provrc — not the tool's own refusal, so it crashed);"
      warn "  the roster is in an UNKNOWN state and the holder surface may stay INCOMPLETE (agent-infra#1935)"
    else
      ok "lane roster: this box's own population (agent-infra#1935)"
    fi
  else
    # ⛔ TWO CAUSES, TWO DIAGNOSES. The guard above has two halves (the tool is present AND an
    # interpreter exists), and naming only the first made an absent `python3` read as a missing
    # harness file — sending the operator to re-pull a file that is already there (review round 2,
    # minor). The supervisor needs no twin here: its `cmd_check` dependency loop
    # (cloud-cell-supervisor.sh:2101) dies on a missing python3 before this line is reached.
    if [ ! -f "$harness/provision-lane-registry.py" ]; then
      warn "provision-lane-registry.py not found at $harness — the lane roster is not provisioned here;"
    else
      warn "python3 is not on PATH — the lane roster provisioner cannot run here;"
    fi
    warn "  the pre-flight's holder surface will refuse every candidate (agent-infra#1935)"
  fi
  out="$(REPO="$WORKDIR" OR="$REPO_SLUG" O="$CELL_HOME/orchestrator" bash "$harness/refresh-candidates.sh" --check 2>&1)" || outrc=$?
  if [ "$outrc" -ne 0 ]; then
    printf '%s\n' "$out" >&2
    # Same split as the run path (review cycles 5-6): rc=3 is a permanent provisioning defect; among
    # the rest, only a TRANSIENT refusal that names the SCOUT gets the scout wording — rc=1 also covers
    # causes that are not the scout at all (`FAIL repo not found`, `'uv' is not runnable`).
    if [ "$outrc" -eq 3 ]; then
      die "this repo cannot be provisioned for dispatch — the cell would merge only (agent-infra#1736)"
    fi
    case "$out" in
      *"TRANSIENT: scout"*) die "the scout worktree cannot be refreshed right now (see the reason above): clear it, then re-run (agent-infra#2174)" ;;
      *) die "this cell cannot start: a precondition above is not met — see the reason above (agent-infra#1736)" ;;
    esac
  fi
  printf '%s\n' "$out" | sed 's/^/    /'
  ok "dispatch provisioning pre-flight passed"
}

# ── the operational layer (agent-infra#1723) ─────────────────────────────────────
# WHY, in one line: without this, a cell lane runs with no review-enforcer, no
# verification-gate, no main-worktree-guard, no search-guard, no audit-logger and no skills,
# and its merge path dies rc=127 on the missing scripts/record-review.sh — the exact path
# merge-one.sh:240 executes. See the header's (4).
#
# FATAL, not best-effort, and deliberately unlike check_dispatch above: the supervisor's
# cmd_check tests NEITHER record-review.sh NOR lib/diff-normalize.py — the first is
# agent-infra#1717 (orchestrator-harness/README.md §7.5, "Still open"), the second is read
# from cmd_check itself (cloud-cell-supervisor.sh:234-345, no reference to either file) —
# and nothing else installs any of the other 22 declared farm files. So if this step is
# skipped, nothing else ever installs the guards. (A "CELL CAN RUN A CONTROLLER" from
# cloud-cell-supervisor.sh start is therefore NOT evidence that the layer is present: it
# reads a cell that never received it.) A "CELL READY" over an unguarded cell is exactly the
# false PASS this repo keeps removing, and the remedy is one env var
# (`INFRA_ROOT=<checkout>`) — so refuse.
# gh_shim_disarmed <layer --verify output> — TRUE when the shim is installed but the kill switch has it
# DISARMED. A named predicate, not an inline test, so the suite can DRIVE the shipped decision: an
# inversion here certifies a degraded cell as armed, which is the whole defect #2164 records.
# ⛔ IT MATCHES THE ACTIVATION LINE, NOT ITS ABSENCE. `--verify` always prints the line when the shim
# is present, so "no DISARMED line" is a POSITIVE arming statement — and it is only read as one after
# rc=0 proved the shim exists (the caller reaches here only after that check).
gh_shim_disarmed() {
  grep -q 'gh shim PRESENT .*DISARMED' <<<"$1"
}

check_operational_layer() {
  local cand root="" installer os_release self_root trusted=0
  # A cell keeps its agent-infra checkout in any of a few places (this script is normally
  # pushed STANDALONE, so its own directory proves nothing — and neither does its parent, which
  # for a bare `bash cloud-cell-bringup.sh` is whatever directory it was run from, e.g. /tmp).
  # ONLY $INFRA_ROOT is an unconditional declaration by the operator. Every other candidate,
  # INCLUDING this script's own parent, must be owned by this user: the cell's HOME is a fixed
  # path under a world-writable /tmp (/tmp/cell-home), and this step RUNS the installer it
  # finds, with the cell's keys.env already exported — so a checkout-shaped tree planted at any
  # of those paths would both choose and execute the code.
  #
  # Bound, stated rather than implied: the check is on the candidate ROOT's owner. It does not
  # inspect the mode of the subdirectories on the way to pi-bootstrap/cell-install.sh, so a
  # root we own but whose pi-bootstrap/ is group/other-writable would still let another local
  # uid drop an installer in it. That requires a second local uid on the cell — the cell's home
  # is created for the single account that runs it — and it is why two accounts must never
  # share a cell.
  self_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
  for cand in "${INFRA_ROOT:-}" "$self_root" \
              "${AGENT_INFRA_PATH:-}" "${HARNESS:+$HARNESS/..}" \
              "$CELL_HOME/agent-infra"; do
    [ -n "$cand" ] || continue
    [ -f "$cand/pi-bootstrap/cell-install.sh" ] || continue
    trusted=1
    case "$cand" in
      "${INFRA_ROOT:-}") ;;
      *) [ -O "$cand" ] || trusted=0 ;;
    esac
    if [ "$trusted" -eq 1 ]; then root="$cand"; break; fi
    log_line "  refusing $cand: checkout-shaped but not owned by $(id -un) — pass INFRA_ROOT=<checkout> to use it deliberately"
  done
  if [ -z "$root" ]; then
    die "no agent-infra checkout on this cell (looked at \$INFRA_ROOT, $self_root, \$AGENT_INFRA_PATH, \${HARNESS}/.., $CELL_HOME/agent-infra).
       The operational layer (guards, skills, the merge-path record-review.sh) cannot be installed,
       so this cell would run unguarded with a rc=127 merge path. Clone agent-infra onto the cell
       and re-run:  INFRA_ROOT=<checkout> bash $0 --check"
  fi
  LAYER_ROOT="$root"
  installer="$root/pi-bootstrap/cell-install.sh"
  # VERIFY FIRST: a re-run against a cell that already carries the layer is a READ-BACK (the
  # installer's --verify writes nothing, so it cannot repair anything either), and only a cell
  # that is missing the layer — or behind the checkout — pays for an install. Both halves are the
  # installer's own decisions; this function re-implements neither.
  # The exit status is captured from the COMMAND, never from a `| sed` pipeline — a decoration
  # that swallows a failure is how a false PASS gets minted. The install's output is indented so
  # the layer's own failures never read as bring-up chatter.
  local out rc=0
  out="$(CELL_HOME="$CELL_HOME" INFRA_ROOT="$root" bash "$installer" --verify 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    # SURFACE the read-back's own refusal before repairing. It used to be discarded — the
    # variable is overwritten by the install below — so an operator saw "the cell does not carry a
    # current layer" and never WHICH artifact was wrong. Measured (#2100): a cell carrying
    # `tortoise-capture` had its verify failure silently swallowed while the next bringup
    # re-installed the extension, so the reason the box kept re-breaking itself appeared nowhere
    # in the log. The installer's named line ("capture extension present on a cell: …") is the
    # evidence; print it, indented like the rest of the layer output.
    log_line "  the cell does not carry a current layer (verify rc=$rc) — installing it from $root. The read-back's own reasons:"
    printf '%s\n' "$out" | sed 's/^/    /'
    rc=0
    out="$(CELL_HOME="$CELL_HOME" INFRA_ROOT="$root" bash "$installer" --install 2>&1)" || rc=$?
    printf '%s\n' "$out" | sed 's/^/    /'
  else
    # The read-back is quiet: the installer's mode banner and its verdict line. The banner is
    # what keeps the FAST path observable — a `--check` that silently re-copied instead would
    # print no mode at all, and cloud-cell-bringup.test.sh asserts on exactly that. (The verdict
    # is printed indented by the installer's own `say`, so do not anchor these patterns.)
    printf '%s\n' "$out" | grep -E 'mode=--verify|LAYER VERIFIED' | sed 's/^/    /'
  fi
  if [ "$rc" -ne 0 ]; then
    die "the operational layer FAILED to install from $root (rc=$rc) — a cell without it is unguarded (no review-enforcer/verification-gate/main-worktree-guard/search-guard/audit-logger, no skills) and its merge path dies rc=127. Fix the failure above, or install it by hand: CELL_HOME=$CELL_HOME INFRA_ROOT=$root bash $installer --install"
  fi
  ok "operational layer present and verified ($CELL_HOME/.pi/agent)"
  # THE MERGE GATE'S SECOND LAYER, NAMED AT THE READY MOMENT (#2164). A cell reported CELL READY
  # while every lane on it logged `#984 argv-level gh shim not found — only the string scanner is
  # active`: two definitions of ready, and only one of them measured the merge gate. `--verify` is
  # the AUTHORITY (it fails BY NAME when the shim is absent, non-executable, or missing its evidence
  # verifier), so reaching this line already implies the layer carries one. ⛔ NO PATH HERE: the
  # resolved shim may legitimately live elsewhere (AGENT_GH_SHIM_DIR is a candidate the extension
  # tries first), and a literal path on this line would be a second copy of the layout that nothing
  # derives — a datum an operator would read as measured when it is only typed.
  # ⛔ INSTALLED AND VERIFIED IS NOT ARMED (fresh review of this PR, P2). `--verify`'s activation
  # line is REPORT-ONLY: with `AGENT_GH_SHIM=0` the shim is present and `guard_gh_shim` passes, so
  # rc=0 and the line above was reached while the DISARMED note sat in `$out` — and the ready path
  # then stated the opposite of what it had measured. The claim is now conditional on the measured
  # state. The kill switch stays honoured (it is a documented, audited hatch): a cell that carries
  # it simply must not also read as "NOT degraded", and the degraded state is named where an
  # operator greps for readiness.
  # ⛔ NOT A PIPE, AND NOT AN INLINE TEST (#841/#864). `printf … | grep -q` is the SIGPIPE
  # false-negative idiom — under `set -o pipefail` a first-match `grep -q` kills the writer and the
  # PIPELINE reports the writer's failure, so a DISARMED cell could read as "no match" and certify
  # NOT degraded: the exact inversion this branch exists to prevent. The here-string form lives in
  # `gh_shim_disarmed` (named so this suite DRIVES it rather than re-deriving it below).
  if gh_shim_disarmed "$out"; then
    warn "merge gate DEGRADED — the argv-level gh shim is installed, but AGENT_GH_SHIM=0 disarms it: the review-enforcer injects nothing and the string scanner is the only layer the gate has (#984/#2164). Fix the env to arm it, or keep this box out of the landing path."
  else
    ok "merge gate NOT degraded — the argv-level gh shim is installed, enabled and verified (#984)"
  fi
  # check_schedule() below reads the job DECLARATIONS from this same checkout (templates/launchd),
  # exactly as launchd's installer reads them from $AGENT_INFRA_PATH on the Mac — one source of
  # truth, never a hand-ported second list. It uses LAYER_ROOT, which is set above (#1864).
  # A cell is Linux. Say which one, because the layer's own selection is surface-aware (no
  # cmux desktop app, no launchd) and a reviewer reading a cell log should see the surface.
  if [ -r /etc/os-release ]; then
    os_release="$(. /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-unknown}")"
    ok "cell surface: ${os_release:-unknown} (Linux — cmux-session.ts and launchd are not installed)"
  fi
}

# ── the HARNESS PIN: the box is born pointing at a LINKED WORKTREE, and refuses a look-alike ────────
# MEASURED 2026-10-21, on two freshly brought-up boxes: `$CELL_HOME/harness` was a DIRECTORY OF
# SHA-NAMED SUBDIRECTORIES — copies someone had made, not git worktrees — so the pin file named a path
# with no `.git` and no `orch-loop.sh`, and every consumer read `pinned=none` WHILE a pin file existed.
# The box certified clean and could not run a controller; the operator's next move depends on WHICH of
# the two paths is wrong, which is why this step names it.
#
# ⛔ WHY THIS BELONGS IN BRING-UP AT ALL. `cloud-cell-supervisor.sh start` re-pins per commit (#1745 /
# #2215), so a cell that is STARTED on the same box that ran bring-up mends itself. A NEW box has no
# pin at all until something materialises one, and the operator's fallback is exactly the hand-copy
# that produced the measured trap — so bring-up creates it, from the checkout it already trusted for
# the operational layer.
#
# ⛔ THE SHAPE IS THE SUPERVISOR'S, DELIBERATELY — `<pin root>/<sha12>`, a linked `git worktree`
# (`harness_apply`). A FLAT worktree at the pin ROOT is also accepted (that is the documented legacy
# shape, `pin_root_conformance`'s "root IS one worktree" arm), but creating one here would make the
# supervisor's next re-pin add a worktree INSIDE a worktree, so this never creates one.
# Both records the readers use are written: `.harness-path` (the path `start` reads) and
# `state/HARNESS-PIN` (sha on line 1 — `status` reads exactly that — plus the timestamp on line 2).
# `_pin_is_worktree_of <path> <repo>` — is <path> a LINKED worktree of the checkout at <repo>?
# ⛔ BY GIT'S OWN ANSWER, NOT BY STRING-MATCHING `worktree list`. The supervisor already paid for this
# lesson (`linked_worktree_of`, cloud-cell-supervisor.sh:950-968): git NORMALISES the paths it records
# (a `$TMPDIR`-derived `//`, a symlink, a differently-spelled but identical path), so a literal compare
# reports a cell's OWN worktree as foreign and refuses a good pin root — the #1852 false block. Comparing
# `--git-common-dir` asks git whether the two paths are the same REPOSITORY, which is the actual question.
# The MAIN working tree is excluded on purpose: it is a worktree of itself, and a pin must never be one.
_pin_is_worktree_of() {
  local _p="$1" _r="$2" _pc _rc _main
  _main="$(cd "$_r" 2>/dev/null && pwd -P)" || return 1
  [ "$(cd "$_p" 2>/dev/null && pwd -P)" = "$_main" ] && return 1      # the main checkout is not a pin
  _pc="$(cd "$_p" 2>/dev/null && cd "$(git -C "$_p" rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P)" || return 1
  _rc="$(cd "$_r" 2>/dev/null && cd "$(git -C "$_r" rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P)" || return 1
  [ -n "$_pc" ] && [ "$_pc" = "$_rc" ]
}

check_harness_pin() {
  local repo want sha dir got pin_py root_ok=0
  repo="${HARNESS_REPO:-${LAYER_ROOT:-}}"
  # ⛔ ALL THREE EXITS BELOW ARE REFUSALS, NOT WARNINGS (#2916 check 2, correcting #2909). They used to
  # `warn … return 0`, so `check_harness_pin` could DECLINE TO PIN and bring-up still reached
  # `CELL READY` — and the measured signature is a cell where `cell-install.sh --install` printed
  # `LAYER VERIFIED` and ended with NO PIN AT ALL (a `bash -x` trace stops right there), which is a
  # success message over a cell whose controller has no harness to run from and silently falls back to
  # a hand-copied tree (§11's defect). "Cannot pin" is not "nothing to pin".
  if [ -z "$repo" ]; then
    die "CHECK FAILED [harness pin]: no agent-infra checkout to pin the harness from (the operational-layer step found none) — a cell with no pin runs whatever tree it was handed (the hand-copied harness §11 exists to remove). FIX: put an agent-infra checkout on the cell and re-run with INFRA_ROOT=<checkout> (cell-install.sh --install records the LAYER only; THIS check is what pins the harness)"
  fi
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || {
    die "CHECK FAILED [harness pin]: \$HARNESS_REPO=$repo is not a git checkout, so nothing can be pinned and no commit can be recorded. FIX: point HARNESS_REPO/INFRA_ROOT at a real checkout and re-run"
  }
  want="$(git -C "$repo" rev-parse --verify --quiet "$HARNESS_REF^{commit}" 2>/dev/null)"
  if [ -z "$want" ]; then
    die "CHECK FAILED [harness pin]: cannot resolve $HARNESS_REF in $repo — a cell with no pin starts on whatever tree it was handed, and nothing records which commit that was. FIX: fetch the ref on the cell's checkout (git -C $repo fetch origin) or set HARNESS_REF to a commit it carries, then re-run"
  fi
  sha="$(printf '%s' "$want" | cut -c1-12)"
  # A pin ROOT that exists must BE (or CONTAIN) a real worktree of this checkout. The measured trap is
  # a directory of sha-named COPIES: it exists, it looks provisioned, and it points at nothing.
  if [ -e "$HARNESS_PIN_DIR" ]; then
    if _pin_is_worktree_of "$HARNESS_PIN_DIR" "$repo"; then
      dir="$HARNESS_PIN_DIR"                  # legacy flat pin: the ROOT is the worktree
      root_ok=1
    else
      # Its children: a pin root is proper when it holds a linked worktree of THIS checkout. The child
      # named after $sha is preferred, so the choice is DETERMINISTIC and, where possible, is the ref the
      # box is supposed to be on — picking "whichever comes first in a glob" made the pin depend on
      # lexicographic order, and it silently re-pointed the records at an arbitrary older pin.
      [ -d "$HARNESS_PIN_DIR/$sha" ] && _pin_is_worktree_of "$HARNESS_PIN_DIR/$sha" "$repo" && {
        dir="$HARNESS_PIN_DIR/$sha"; root_ok=1
      }
      if [ "$root_ok" -ne 1 ]; then
        for pin_py in "$HARNESS_PIN_DIR"/*; do
          [ -d "$pin_py" ] || continue
          if _pin_is_worktree_of "$pin_py" "$repo"; then
            dir="$pin_py"; root_ok=1; break
          fi
        done
      fi
    fi
    if [ "$root_ok" -ne 1 ]; then
      die "$HARNESS_PIN_DIR exists but is NOT a git worktree of $repo and holds no linked worktree — a pin file can name it while pointing at NOTHING (the measured 'pinned=none although a pin file exists' state, 2026-10-21). Move it aside and re-run: mv '$HARNESS_PIN_DIR' '$HARNESS_PIN_DIR'.not-a-worktree && INFRA_ROOT=$repo bash $0 --check"
    fi
  else
    mkdir -p "$(dirname "$HARNESS_PIN_DIR")" || die "cannot create $(dirname "$HARNESS_PIN_DIR")"
    dir="$HARNESS_PIN_DIR/$sha"
    git -C "$repo" worktree remove --force "$dir" >/dev/null 2>&1 || true
    git -C "$repo" worktree add --detach "$dir" "$want" >/dev/null 2>&1 \
      || die "git worktree add --detach $dir $want failed — free space and re-run (a cell whose harness is a hand-copy is the state this step removes)"
  fi
  [ -f "$dir/scripts/orchestrator-harness/orch-loop.sh" ] \
    || die "the harness pin at $dir carries no scripts/orchestrator-harness/orch-loop.sh — this is not a harness tree, and a controller started from it would exit at once"
  # ⛔ TEMP-THEN-RENAME, the same rule the pin record below states: an in-place write truncates
  # the one artifact that answers "which harness is this box on?" before its replacement exists, so
  # a concurrent `status`/`start` can `head -1` an EMPTY pin, and a write that fails after the
  # redirect leaves a previously valid pin EMPTY instead of keeping the box on the harness it was
  # already running (the measured `pinned=none`-with-a-pin-file state).
  printf '%s\n' "$dir/scripts/orchestrator-harness" > "$HARNESS_PIN_FILE.tmp.$$" \
    && mv -f "$HARNESS_PIN_FILE.tmp.$$" "$HARNESS_PIN_FILE" \
    || { rm -f "$HARNESS_PIN_FILE.tmp.$$"; die "cannot record the harness pin path in $HARNESS_PIN_FILE"; }
  mkdir -p "$(dirname "$HARNESS_PIN_RECORD")" || die "cannot create $(dirname "$HARNESS_PIN_RECORD")"
  # ⛔ THE RECORD CARRIES THE COMMIT THE PIN IS ACTUALLY ON — never `$want` by assumption. An ACCEPTED
  # existing pin may sit on an older commit than $HARNESS_REF (the supervisor re-pins per commit and the
  # previous pin survives until `prune`), and recording `$want` there makes `status` print a sha the box
  # is NOT deployed to: the restarted false PASS this step exists to remove, one level down. Read the
  # worktree's own HEAD, and say out loud when it is behind (a `--check` must not redeploy the box, so it
  # does not silently retarget the pin either — it reports and names the verb that advances it).
  got="$(git -C "$dir" rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null)"
  [ -n "$got" ] || die "cannot read the commit at the harness pin $dir — the pin record would be a guess, which is the false PASS this step removes"
  # TEMP-THEN-RENAME (the same rule harness-refresh.sh:380 states): an in-place write truncates the one
  # artifact that answers "which harness is this box on?" before its replacement exists.
  printf '%s\n%s\n' "$got" "$(date -u +%FT%TZ)" > "$HARNESS_PIN_RECORD.tmp.$$" \
    && mv -f "$HARNESS_PIN_RECORD.tmp.$$" "$HARNESS_PIN_RECORD" \
    || { rm -f "$HARNESS_PIN_RECORD.tmp.$$"; die "cannot record the harness pin (sha+timestamp) at $HARNESS_PIN_RECORD"; }
  ok "harness pin: $(printf '%s' "$got" | cut -c1-12) (linked worktree) at $dir — recorded in $HARNESS_PIN_FILE and $HARNESS_PIN_RECORD"
  if [ "$got" != "$want" ]; then
    warn "the harness pin at $dir is NOT at $HARNESS_REF ($(printf '%s' "$want" | cut -c1-12)) — the box is deployed to $(printf '%s' "$got" | cut -c1-12). This check does not redeploy: run 'cloud-cell-supervisor.sh apply' (or 'start', which applies first) to advance it"
  fi
}

# ── cell env: the repo is PER-INVOCATION state, never a global export (agent-infra#2235's class) ──
# MEASURED 2026-10-21: a cell's `keys.env` exported `GH_REPO=daniel-ospina/tortoise` GLOBALLY. `gh`
# honours `GH_REPO` as its default repo, so every agent-infra rail on that box graded TORTOISE and
# printed `ALREADY MERGED` for a September tortoise PR — success over zero work, on the wrong repo,
# with nothing in the output that said so. The repo a command acts on is per-invocation state: it is
# passed by the caller (`--repo`, or the checkout's own remote), never inherited from the cell.
# So bring-up DROPS it after sourcing and SAYS SO. A pushed keys.env that carries it keeps working in
# the operator's own shell; what it cannot do is silently become every later command's repo.
neutralise_gh_repo() {
  if [ -n "${GH_REPO:-}" ]; then
    warn "dropping GH_REPO='$GH_REPO' (from $ENV_FILE or the operator's shell): gh treats it as the DEFAULT repo for EVERY command, so agent-infra rails on this cell graded another repo and printed ALREADY MERGED over zero work (measured 2026-10-21). Repo is per-invocation state — pass --repo <owner/name>, or let the checkout's remote decide"
    unset GH_REPO
  fi
  # reported, never unset: `REPO` is a PATH (the cell's checkout) and the controller legitimately needs
  # it. The test is ABSOLUTE PATH, not "contains a slash": an owner/name slug DOES contain a slash,
  # so a `*/*` test accepted the one shape this guard exists for (the measured keys.env carried
  # `GH_REPO=daniel-ospina/tortoise`, and `REPO` set the same way is the same mistake one variable
  # over), and the warning that did fire described a bare name as a slug. Both wrong shapes warn.
  case "${REPO:-}" in
    ''|/*) : ;;
    *) warn "REPO='$REPO' is not an absolute path — the controller reads REPO as the CHECKOUT PATH, so '$REPO' resolves to nothing (an owner/name slug here is the keys.env GH_REPO mistake one variable over: the repo a command acts on is per-invocation state, never an inherited global)" ;;
  esac
  return 0
}
# ── the cross-box review-record registry (agent-infra#2374) ─────────────────────
# WHY THIS RUNS DURING BRING-UP. `~/.pi/agent/reviews/` is per-box, and a freshly booted cell that
# has never minted a record would refuse every PR another box reviewed — the box is not "unable to
# review", it is BLIND, and nothing on it said so (#2349 measured 142 such blocks on one box; 134
# records existed nowhere but the box that minted them). `registry-sync.sh union` converges this
# box's registry with the fleet's through the one store every box shares — the repository — so a
# cell starts with the records that already exist instead of with none.
#
# NOT A REFUSAL, and deliberately. A box that cannot reach the store can still REVIEW (and record)
# locally, so failing bring-up here would trade a blind box for a dead cell — the same
# over-blocking the A/B test calls category B. What must not happen is SILENCE: an unreachable
# store is reported as UNKNOWN (never "empty"), and the cell is told to re-run the verb.
# The sync is bounded (registry-sync.sh --timeout) and its exit status is captured from the
# COMMAND, never from a `| sed` decoration.
check_review_registry() {
  local sync="$CELL_HOME/.pi/agent/scripts/registry-sync.sh" out rc=0 store=""
  # The farmed copy is what a lane will run, and the checkout that installed the layer is the one
  # whose remote carries the refs — the farmed copy has no repo above it, so name the store.
  [ -f "$sync" ] || sync="$LAYER_ROOT/scripts/registry-sync.sh"
  if [ ! -f "$sync" ]; then
    warn "registry-sync.sh is not on this cell (neither the farmed copy nor \$LAYER_ROOT) — the review-record"
    warn "  registry stays LOCAL-ONLY here, so a PR reviewed on another box will read as unreviewed (#2374)."
    return 0
  fi
  for store in "$LAYER_ROOT" "${AGENT_INFRA_PATH:-}"; do
    [ -n "$store" ] && [ -d "$store" ] && break
    store=""
  done
  # The store is passed as an ARRAY, not `${store:+--repo "$store"}`: the quotes inside that
  # expansion are LITERAL words, so a $LAYER_ROOT containing a space arrived as two arguments and
  # registry-sync.sh exited 2 — a cell reporting "the registry is unsynced" for a quoting bug.
  local -a store_args=()
  [ -n "$store" ] && store_args=(--repo "$store")
  # `--dir` is passed EXPLICITLY, and the registry is named from CELL_HOME rather than assumed:
  # `HOME` is repointed to $CELL_HOME by setup_home/check_provider, but that invariant lives in
  # OTHER functions and this check must not silently certify a registry the cell's lanes never
  # read. (The old `CELL_HOME="$CELL_HOME" bash …` prefix was inert — registry-sync.sh resolves
  # REGISTRY_SYNC_DIR or $HOME and never reads CELL_HOME, which asserted a redirect that does not
  # exist.)
  out="$(bash "$sync" union --dir "$CELL_HOME/.pi/agent/reviews" "${store_args[@]+"${store_args[@]}"}" --timeout 30 2>&1)" || rc=$?
  printf '%s\n' "$out" | sed 's/^/    /'
  case "$rc" in
    0) ok "review-record registry synced with the fleet ($(printf '%s\n' "$out" | grep -E '^union:' | tail -1))"
       # rc 0 is CONVERGED, not "nothing to say": a per-record notice (a store this cell could not
       # use, a local legacy record kept local by rule 3) must still reach the operator.
       printf '%s\n' "$out" | grep -E '⚠️|DIVERGES' | sed 's/^/    /' >&2 || true ;;
    3) warn "the review-record registry DIVERGES from the fleet at the same reviewed_at — neither side was"
       warn "  overwritten (#2374 rule 4); this cell keeps what it has. Reconcile by hand if this is not two"
       warn "  boxes recording one revision." ;;
    4) warn "the fleet's registry holds records this cell could NOT use (unreadable ref or stamp, or a"
       warn "  mis-keyed record) — they were skipped and nothing was overwritten, but this is NOT a converged"
       warn "  state. Re-run: bash $sync union ${store:+--repo \"$store\"}" ;;
    *) warn "the cross-box review-record registry could NOT be synced (rc=$rc) — see the lines above for"
       warn "  WHICH SIDE failed: a failed PULL leaves the fleet's records UNKNOWN here (not empty), a failed"
       warn "  PUSH means this cell read them but its own are still LOCAL. Re-run:"
       warn "  bash $sync union ${store:+--repo \"$store\"}" ;;
  esac
  return 0
}

# ── disk: the machine-global package caches (agent-infra#1987) ─────────────────────
# REPORT ONLY, and deliberately not a refusal: a cache over its bound is the state the box is
# in BEFORE it stops dispatching, and this check exists so that state is VISIBLE while there is
# still room to fix it. The refusal lives where the consequence is (cloud-cell-supervisor.sh
# cmd_check_disk's MIN_FREE_MB floor); binding a cache SIZE into `--check` would fail a cell
# that is working fine on a large disk. Measured on pi-cell-3: 258MB free, `~/.cache/uv` alone
# 7.1GB — every dispatch refused, and nothing on the box reported the cache as the cause.
check_caches() {
  local d kb total=0 listed="" maxmb=2048 bound over=0 measured du_rc cfg line reaper real_d
  # A NEWLINE-SEPARATED list, not an array: bash 3.2 (the macOS default) treats `${#arr[@]}` on an
  # empty array as an unbound-variable error under `set -u`.
  local dirs_list="" bound_source=default
  # The reaper is the ONE place that knows WHERE the caches are and WHAT the bound is. Two reasons
  # (agent-infra#1987): `uv cache dir` honours XDG_CACHE_HOME, so a literal `$HOME/.cache/uv` here
  # can report "absent" for a box whose uv cache is 3GB elsewhere; and a tuned bound must not leave
  # this report describing a different policy than the one enforced.
  reaper=""
  # ${CACHE_REAPER:-} FIRST: the same override the cell clock and the supervisor honour, so the
  # report cannot describe a different copy than the one that runs.
  # The same chain as the supervisor and the cell clock: ${CACHE_REAPER:-} -> the FARMED copy ->
  # the copy beside this script, so the report describes the script that actually runs.
  for d in "${CACHE_REAPER:-}" \
           "${HOME:-}/.pi/agent/scripts/pi-cache-reap.sh" \
           "$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/pi-cache-reap.sh"; do
    [ -n "$d" ] && [ -f "$d" ] && { reaper="$d"; break; }
  done
  cfg=""
  if [ -n "$reaper" ]; then
    cfg="$(bash "$reaper" --print-config 2>/dev/null)" || cfg=""
    line="$(printf '%s\n' "$cfg" | sed -n 's/^bound_mb=//p' | head -1)"
    case "$line" in
      ''|*[!0-9]*|0*) ;;
      *) maxmb="$line" ;;
    esac
    # WHERE the bound came from, reported next to it: a bound tuned in the launchd plist does not
    # reach a bring-up shell's environment, so the two numbers can legitimately differ — and a
    # report that hides its source reads as the policy the armed job enforces (#1987 review).
    bound_source="$(printf '%s\n' "$cfg" | sed -n 's/^bound_source=//p' | head -1)"
    case "$bound_source" in env|default) ;; *) bound_source=unknown ;; esac
    while IFS= read -r line; do
      case "$line" in cache=*) dirs_list="$dirs_list${dirs_list:+
}${line#cache=*:}" ;; esac
    done <<<"$cfg"
  fi
  # No farmed resolver yet (a fresh box, or the script is not farmed): report the documented
  # locations rather than nothing — a check that silently reports no caches is the blind spot this
  # function exists to remove.
  if [ -z "$dirs_list" ]; then
    # The npm sink is the cache ROOT the tool reports (`npm config get cache`), not its `_cacache`
    # child: `_npx` and `_logs` sit beside it, so naming the child reported "absent / total 0MB"
    # for a box whose npm cache was the sink — on exactly the fresh box that has no reaper farmed.
    dirs_list="$(printf '%s\n' "$HOME/.cache/uv" "$HOME/.npm" "$HOME/.cache/pip" "$HOME/Library/Caches/pip")"
  fi
  case "$maxmb" in ''|*[!0-9]*|0*) maxmb=2048 ;; esac
  bound=$(( 10#$maxmb * 1024 ))
  while IFS= read -r d; do
    if [ ! -d "$d" ]; then
      listed="$listed, $(basename "$(dirname "$d")")/$(basename "$d")=absent"
      continue
    fi
    # A cache dir that is itself a SYMLINK (the "move it to a bigger disk" idiom) measures 0:
    # `du -sk <link>` stats the link, not the tree. Resolve it first, or this report reads
    # "0MB on a 7.1GB cache" — the very blind spot the check exists to remove.
    if [ -L "$d" ]; then
      real_d="$(cd "$d" 2>/dev/null && pwd -P)" || real_d=""
      if [ -z "$real_d" ]; then
        warn "cache $d: is a symlink that cannot be resolved — the size cannot be measured"
        listed="$listed, $d=unresolvable"
        continue
      fi
      d="$real_d"
    fi
    # A cache that cannot be measured is REPORTED as unmeasurable — never as 0, which would read
    # as "nothing to see" for the one number this check exists to surface. `du`'s STATUS decides:
    # a partially unreadable cache still prints a numeric partial total (measured: a 3016KB tree
    # with one mode-000 subdir prints `16` and exits 1).
    measured=1
    kb="$(du -sk "$d" 2>/dev/null)"; du_rc=$?
    kb="${kb%%[[:space:]]*}"
    [ "$du_rc" -eq 0 ] || measured=0
    case "${kb:-}" in ''|*[!0-9]*) measured=0 ;; esac
    if [ "$measured" -eq 0 ]; then
      warn "cache $d: cannot be measured (du failed) — a full disk reads healthy when nothing is measured"
      listed="$listed, $d=unmeasurable"
      continue
    fi
    total=$(( total + kb ))
    if [ "$kb" -gt "$bound" ]; then
      over=$(( over + 1 ))
      listed="$listed, $d=$(( kb / 1024 ))MB OVER"
    else
      listed="$listed, $d=$(( kb / 1024 ))MB"
    fi
  done <<<"$dirs_list"
  listed="${listed#, }"
  ok "caches: $listed — total $(( total / 1024 ))MB (bound ${maxmb}MB per cache, source ${bound_source})"
  if [ "$over" -gt 0 ]; then
    warn "  $over package cache(s) exceed the ${maxmb}MB bound — this is the sink that took pi-cell-3"
    warn "  from 7.1GB in ~/.cache/uv to 258MB free and refused every dispatch (#1987). Reclaim it now:"
    warn "    bash ${reaper:-$HOME/.pi/agent/scripts/pi-cache-reap.sh} --apply"
  fi
}

# ── (6) swap: a memory spike must PAGE, not OOM-kill the lanes (agent-infra#2390) ───────────────
# The cells ship with NO swap: /proc/swaps is empty, and `swapon` is not even on the non-root PATH.
# Measured 2026-10-23T00:15Z on cell-3: 8011M total, 7665M used, **345M AVAILABLE** with 17 pi lanes,
# 13 FalkorDB redis-servers and two pytest runs (1748M + 746M) resident. The next allocation is
# therefore not slow — it is an OOM kill, and a killed lane's uncommitted work is gone. Swap is the
# only thing that turns a spike into paging, and only root can create it, so it belongs HERE: the
# bring-up is the one step on a cell that can escalate.
#
# SIZING IS A PREDICATE, not a magic number: `max(4 GiB, MemTotal/4)`, capped at 16 GiB — 4 GiB on
# the measured 8 GiB cell (25% of RAM is below the floor), 4 GiB at 16 GiB, 8 GiB at 32 GiB.
# `SWAP_MB` overrides it for a hand-tuned cell.
#
# IDEMPOTENT BY CONSTRUCTION: the state is read from the KERNEL's swap record, so a re-run on a
# provisioned cell activates nothing and just re-reports the reading, and an existing area that is
# already large enough is never rewritten (rewriting live swap would be an outage for its pages).
# The fstab line keeps it across a reboot — a cell that reboots into no swap is this same defect one
# power cycle later.
#
# SWAPPINESS IS PINNED DELIBERATELY at 30, not left to the image default: idle lanes hold a lot of
# cold anonymous memory, and reclaiming that to the swapfile (instead of keeping it resident until
# the OOM killer picks a victim) is what converts a spike into paging. It stays under the kernel's
# 60 so a cell doing real work is not thrashing its hot pages.
#
# ⛔ A CELL THAT CANNOT GET SWAP IS REFUSED, AND THE REFUSAL PRINTS THE READING. The failure mode
# this removes is a box that looks healthy at 345M available and then silently loses lanes.
swap_mb_from_proc() {
  local f="${SWAP_PROC:-/proc/swaps}" kb
  [ -r "$f" ] || return 1
  kb="$(awk 'NR > 1 { s += $3 } END { printf "%d", s + 0 }' "$f" 2>/dev/null)" || return 1
  case "${kb:-}" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$(( kb / 1024 ))"
}

# swap_target_mb <mem_total_mb> — the sizing predicate, in one place.
swap_target_mb() {
  local mem="${1:-0}" t
  case "${SWAP_MB:-}" in
    ''|*[!0-9]*|0) ;;
    *) printf '%s' "$SWAP_MB"; return 0 ;;
  esac
  t=$(( mem / 4 ))
  [ "$t" -lt 4096 ] && t=4096
  [ "$t" -gt 16384 ] && t=16384
  printf '%s' "$t"
}

# sr <cmd…> — run through the privilege seam. Unquoted on purpose (see SWAP_SUDO).
sr() {
  if [ -n "${SWAP_SUDO:-}" ]; then
    ${SWAP_SUDO} "$@"
  else
    "$@"
  fi
}

# fstab_covers <path> — the entry is present in the FIRST field, so a commented-out or differently
# optioned entry is read correctly (an `grep -F` anywhere in the file counts a comment as a mount).
# fstab_covers <path> — a REAL boot mount, not just a line that names the file: field 1 is the
# device, field 3 must be `swap`, and the options must not carry `noauto` (an entry that explicitly
# does NOT mount at boot must not read as "survives a reboot"). A commented-out line simply does not
# have the path in field 1, so it is not a mount either.
fstab_covers() {
  local f="${SWAP_FSTAB:-/etc/fstab}"
  [ -r "$f" ] || return 1
  awk -v p="$1" \
      '$1 == p && $3 == "swap" && ("," $4 ",") !~ /,noauto,/ { found = 1 } END { exit !found }' \
      "$f" 2>/dev/null
}

# ensure_swap_fstab — persist the area across a reboot, idempotently, and READ THE ENTRY BACK.
# ⛔ Called from EVERY path that leaves swap active, INCLUDING "already provisioned": an area that
# is active but unpersisted (a hand `swapon`, or a first run whose append failed) is certified
# otherwise, and the cell returns from a reboot with no swap — this same defect, one power cycle
# later. The append's exit status is not the proof; the read-back is.
ensure_swap_fstab() {
  if fstab_covers "$SWAPFILE"; then
    ok "swap: $SWAP_FSTAB already mounts $SWAPFILE (survives a reboot)"
  elif printf '%s none swap sw 0 0\n' "$SWAPFILE" | sr tee -a "$SWAP_FSTAB" >/dev/null 2>&1; then
    fstab_covers "$SWAPFILE" \
      && ok "swap: $SWAP_FSTAB entry added (survives a reboot)" \
      || warn "swap: wrote to $SWAP_FSTAB but cannot read the entry back — the swap is active now and will not survive a reboot"
  else
    warn "swap: could not persist an entry in $SWAP_FSTAB — the swap is active NOW and will not survive a reboot"
  fi
}

# pin_swappiness — pin the BOOT-TIME value and the RUNTIME one, and verify each INDEPENDENTLY.
# ⛔ The report never claims one on the strength of the other: saying "pinned at boot" because the
# RUNTIME value happens to read 30 is how a cell silently reverts to the image default at the next
# reboot, with the one line an operator greps reading as success.
pin_swappiness() {
  local want="${SWAP_SWAPPINESS:-30}" now pinned=0
  if grep -qxF "vm.swappiness=$want" "$SWAP_SYSCTL_CONF" 2>/dev/null; then
    pinned=1
  elif printf 'vm.swappiness=%s\n' "$want" | sr tee "$SWAP_SYSCTL_CONF" >/dev/null 2>&1 \
       && grep -qxF "vm.swappiness=$want" "$SWAP_SYSCTL_CONF" 2>/dev/null; then
    pinned=1
  fi
  [ "$pinned" = 1 ] \
    || warn "swap: could not write $SWAP_SYSCTL_CONF — swappiness will revert to the image default on the next reboot"

  now="$(cat "$SWAP_SYSCTL_FILE" 2>/dev/null)"
  case "${now:-}" in ''|*[!0-9]*) now=unknown ;; esac
  if [ "$now" != "$want" ]; then
    sr sysctl -w "vm.swappiness=$want" >/dev/null 2>&1
    now="$(cat "$SWAP_SYSCTL_FILE" 2>/dev/null)"
    case "${now:-}" in ''|*[!0-9]*) now=unknown ;; esac
  fi
  if [ "$now" = "$want" ] && [ "$pinned" = 1 ]; then
    ok "swap: vm.swappiness=$want (runtime and pinned at boot in $SWAP_SYSCTL_CONF)"
  elif [ "$now" = "$want" ]; then
    warn "swap: vm.swappiness=$want at runtime, but the boot-time pin is NOT in $SWAP_SYSCTL_CONF — it will revert on the next reboot"
  else
    warn "swap: vm.swappiness is ${now} at runtime, wanted $want (boot-time pin in $SWAP_SYSCTL_CONF)"
  fi
}

# swap_avail_kb — free space on the filesystem that would hold the swapfile. Overridable so a suite
# can exercise the refusal without filling a disk.
swap_avail_kb() {
  local dir kb
  case "${SWAP_AVAIL_KB:-}" in
    ''|*[!0-9]*) : ;;
    *) printf '%s' "$SWAP_AVAIL_KB"; return 0 ;;
  esac
  dir="$(cd "$(dirname "$SWAPFILE")" 2>/dev/null && pwd)" || return 1
  kb="$(df -Pk "$dir" 2>/dev/null | awk 'NR == 2 { printf "%d", $4 }')" || return 1
  case "${kb:-}" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$kb"
}

check_swap() {
  local mem_mb cur target reading missing active=0 tol limit avail_kb need_kb
  mem_mb="$(awk '/^MemTotal:/ { printf "%d", $2 / 1024 }' /proc/meminfo 2>/dev/null)"
  case "${mem_mb:-}" in ''|*[!0-9]*) mem_mb=0 ;; esac
  cur="$(swap_mb_from_proc)" || cur=""
  target="$(swap_target_mb "$mem_mb")"
  # A few megabytes of slack, because the kernel rounds the area DOWN to whole pages and drops the
  # swap header: measured on a cell, a 4096M file reports 4194300K = **4095M**. Without the slack
  # every healthy cell would warn on each run, and the below-target branch would fire on a healthy
  # cell. The slack is 1% (floor 8M) so it scales with the target and never hides a real shortfall.
  tol=$(( target / 100 )); [ "$tol" -lt 8 ] && tol=8
  limit=$(( target - tol ))
  reading="MemTotal=${mem_mb}M SwapTotal=${cur:-UNREADABLE}M target=${target}M swapfile=$SWAPFILE"

  # A reading we cannot take is NOT zero swap: an unreadable record decides nothing.
  [ -n "$cur" ] || die "swap: cannot read the kernel swap record ($SWAP_PROC) — refusing to certify a cell whose swap state is unknown. READING: $reading"
  grep -qF "$SWAPFILE" "$SWAP_PROC" 2>/dev/null && active=1

  if [ "$active" = 1 ] && [ "$cur" -ge "$limit" ]; then
    ok "swap: ${cur}M active, target ${target}M (${mem_mb}M RAM) — already provisioned"
    ensure_swap_fstab
    pin_swappiness
    return 0
  fi
  if [ "$active" = 1 ]; then
    # ⛔ NEVER resize a LIVE area from this check. `swapoff` faults every swapped page back into RAM,
    # and this step runs on a box ALREADY measured short of it (345M available was the observed
    # shape): resizing here can OOM-kill exactly the lanes the swap exists to protect, and a failed
    # re-allocation after a removal would leave NO swap at all where there was some. So the live area
    # is KEPT, the shortfall is REPORTED with the reading, and the convergence is the operator's, on
    # a quiet box.
    warn "swap: ${cur}M active at $SWAPFILE, below the ${target}M target — NOT resizing a live area: swapping it off faults its pages back into RAM on a cell short of it, and a failed re-allocation would leave NO swap. READING: $reading"
    warn "  converge by hand when the box is quiet: sudo swapoff $SWAPFILE && sudo rm -f $SWAPFILE, then re-run this check"
    ensure_swap_fstab
    pin_swappiness
    return 0
  fi

  # (2) CAN WE ACT AT ALL? Escalation first, because a missing tool under `sudo -n` may be present
  # under root's secure PATH (measured: `swapon`/`mkswap` live in /sbin, which is not on a cell's
  # non-root PATH — probing them as the caller would refuse a box that can in fact provision swap).
  if ! sr true >/dev/null 2>&1; then
    die "swap: cannot escalate to root (SWAP_SUDO='${SWAP_SUDO:-<direct>}' failed) — swap can only be created by root, so a memory spike on this cell OOM-kills lanes. READING: $reading"
  fi
  missing="$(sr sh -c 'for t in mkswap swapon fallocate sysctl; do command -v "$t" >/dev/null 2>&1 || printf "%s " "$t"; done' 2>/dev/null)"
  [ -z "$missing" ] || die "swap: missing required tool(s):${missing}— cannot provision swap. READING: $reading"

  # (3) FREE DISK IS THE SAME DEFECT FROM THE OTHER SIDE. This box reaps disk on a timer because a
  # cell at ~97% cannot `git worktree add` or `uv sync`, and a swapfile is UNRECLAIMABLE by that
  # reaper. Allocating up to 16 GiB on a cell near the threshold would trade an OOM kill for a dead
  # cell, so the free-space reading decides BEFORE anything is written.
  avail_kb="$(swap_avail_kb)" || avail_kb=""
  case "${avail_kb:-}" in ''|*[!0-9]*) avail_kb="" ;; esac
  need_kb=$(( (target + 512) * 1024 ))
  if [ -z "$avail_kb" ] || [ "$avail_kb" -lt "$need_kb" ]; then
    die "swap: not enough free disk for a ${target}M swapfile (free ${avail_kb:-UNREADABLE}K, need ${need_kb}K = the area plus a 512M margin) — a swapfile is NOT reclaimable by the disk reaper, so this cell is refused rather than pushed past the threshold where worktree/uv fail. READING: $reading"
  fi

  # (4) ALLOCATE — safe on this path whatever is already there, because the area is NOT active:
  # `fallocate -l` sets the length of an EXISTING file too, so an inactive undersized file converges
  # on the predicate instead of being activated at whatever size it happened to have. `dd` truncates
  # by default, so the fallback cannot leave the old length behind either. Nothing is removed before
  # the replacement is known to exist.
  if ! sr fallocate -l "${target}M" "$SWAPFILE" >/dev/null 2>&1; then
    # fallocate is refused on some filesystems (and on a sparse root): dd is the correct fallback,
    # slow but real. A swap REGION of zeros would be a lie, so a sparse file is never used.
    sr dd if=/dev/zero of="$SWAPFILE" bs=1M count="$target" status=none >/dev/null 2>&1 \
      || die "swap: could not allocate ${target}M at $SWAPFILE (fallocate and dd both failed). READING: $reading"
  fi
  sr chmod 600 "$SWAPFILE" >/dev/null 2>&1 \
    || die "swap: chmod 600 $SWAPFILE failed — an insecure swapfile is refused rather than activated. READING: $reading"
  sr mkswap "$SWAPFILE" >/dev/null 2>&1 \
    || die "swap: mkswap $SWAPFILE failed. READING: $reading"
  sr swapon "$SWAPFILE" >/dev/null 2>&1 \
    || die "swap: swapon $SWAPFILE failed. READING: $reading"

  # (5) READ IT BACK FROM THE KERNEL — `swapon`'s exit status is not the state.
  cur="$(swap_mb_from_proc)" || cur=""
  reading="MemTotal=${mem_mb}M SwapTotal=${cur:-UNREADABLE}M target=${target}M swapfile=$SWAPFILE"
  case "${cur:-}" in
    ''|*[!0-9]*|0) die "swap: swapon succeeded but the kernel record ($SWAP_PROC) still shows no swap. READING: $reading" ;;
  esac
  if [ "$cur" -lt "$limit" ]; then
    warn "swap: ${cur}M active, below the ${target}M target (beyond the ${tol}M page-rounding slack) — the kernel accepted a smaller area than requested. READING: $reading"
  else
    ok "swap: ${cur}M active (target ${target}M, ${mem_mb}M RAM) at $SWAPFILE"
  fi

  ensure_swap_fstab
  pin_swappiness
}

# ── disk: the SCHEDULED reaper (agent-infra#2032) ────────────────────────────────────────────────
# Disk exhaustion is the second reason the cloud cells stopped working, and it arrives as a THRESHOLD:
# at ~97%% used a `git worktree add` or `uv sync` fails and a healthy controller cannot spawn a lane.
# `check_caches` below REPORTS the package caches; reporting is not reclaiming, and on a cell nobody
# is logged into the only thing that reclaims is a scheduler. So the bring-up INSTALLS the timer (the
# installer is idempotent and renders from this box's HOME/PATH/repos) and then reads back its state.
# A cell that cannot schedule the pass is REFUSED rather than certified: `CELL READY` over a box one
# full disk away from refusing every dispatch is the false PASS this script exists to remove.
check_disk_reaper() {
  local installer="" reaper="" cand out rc next last
  for cand in "${DISK_REAPER_TIMER_INSTALLER:-}" \
              "${HOME:-}/.pi/agent/scripts/install-disk-reaper-timer.sh" \
              "$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/install-disk-reaper-timer.sh"; do
    [ -n "$cand" ] && [ -f "$cand" ] && { installer="$cand"; break; }
  done
  for cand in "${DISK_REAPER:-}" \
              "${HOME:-}/.pi/agent/scripts/disk-reaper.sh" \
              "$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/disk-reaper.sh"; do
    [ -n "$cand" ] && [ -f "$cand" ] && { reaper="$cand"; break; }
  done
  [ -n "$reaper" ] || die "disk-reaper.sh not found (looked at \$DISK_REAPER, \$HOME/.pi/agent/scripts, and beside this script) — a cell whose disk is never reaped stops dispatching at ~97%% used"
  [ -n "$installer" ] || die "install-disk-reaper-timer.sh not found — cannot schedule the disk reaper, and an unscheduled reaper never runs unattended"

  # ⛔ TELL THE INSTALLER WHICH REPO TO SCAN (measured on a fresh CI runner, 2026-10-24). The installer's
  # own fallback list is AMBIENT ($REPO / $TORTOISE_REPO / $WORKDIR / $AGENT_INFRA_PATH) and, on a box
  # carrying none of them, it REFUSES — "no repo resolved on this box — the venv and worktree classes
  # would fail closed every pass" — so this check died and the cell could NEVER be certified, on exactly
  # the box that had just cloned its checkout. The refusal is right; the silence was not: this script
  # already KNOWS the checkout ($WORKDIR, verified or cloned by check_repo), so it says so.
  # WHAT IT SCANS: the operator's explicit list if there is one, else THIS cell's verified checkout.
  # NEVER an ambient $REPO / $AGENT_INFRA_PATH, which name the HARNESS or a developer's checkout: a
  # reaper scoped at a repo the cell does not own deletes work the cell is not responsible for.
  # ⛔ AND AN EMPTY LIST IS NOT "THE INSTALLER WILL REFUSE" (measured by review, 2026-10-24): the
  # installer treats an EMPTY `DISK_REAPER_REPOS` exactly like an unset one and falls through to ITS
  # OWN ambient list (`$REPO`, `$TORTOISE_REPO`, `$WORKDIR`, `$AGENT_INFRA_PATH`), so passing "" would
  # have handed it the operator's shell — the adoption this check exists to prevent, on the one path
  # where the cell could not name a repo for itself (an interrupted clone that leaves a `.git`
  # `check_repo`'s `[ -d ]` accepts but git does not). So this REFUSES instead, by name.
  local rp_repos rp_cand
  if [ -n "${DISK_REAPER_REPOS:-}" ]; then
    rp_repos="$DISK_REAPER_REPOS"                 # the operator's list, verbatim (colon-joined; the installer parses it)
  else
    rp_repos="${WORKDIR:-}"
    case "$rp_repos" in
      /*) git -C "$rp_repos" rev-parse --git-dir >/dev/null 2>&1 || rp_repos="" ;;
      *) rp_repos="" ;;
    esac
    [ -n "$rp_repos" ] || die "the cell's checkout (${WORKDIR:-<unset>}) is not a usable git repository, and no DISK_REAPER_REPOS was given — refusing to schedule a reaper whose scan list would fall back to an AMBIENT repo (\$REPO / \$AGENT_INFRA_PATH name the harness or a developer's checkout, not this cell). Fix the checkout at that path, or set DISK_REAPER_REPOS explicitly."
  fi

  rc=0
  # TEMPLATES_DIR from the SAME checkout the layer came from: the farmed installer copy lives at
  # $HOME/.pi/agent/scripts, whose ../templates does not exist, so without this the templates are
  # "missing" on exactly the cell that was just provisioned.
  out="$(DISK_REAPER="$reaper" DISK_REAPER_REPOS="$rp_repos" TEMPLATES_DIR="${LAYER_ROOT:+$LAYER_ROOT/templates/systemd}" \
         bash "$installer" --install 2>&1)" || rc=$?
  printf '%s\n' "$out" | sed 's/^/    /'
  [ "$rc" -eq 0 ] || die "the disk reaper timer could not be installed (rc=$rc) — fix the reason above (a passwordless-sudo system unit, or a working systemd user manager) before this cell is used"

  rc=0
  out="$(DISK_REAPER="$reaper" DISK_REAPER_REPOS="$rp_repos" TEMPLATES_DIR="${LAYER_ROOT:+$LAYER_ROOT/templates/systemd}" \
         bash "$installer" --status 2>&1)" || rc=$?
  [ "$rc" -eq 0 ] || die "the disk reaper timer is not healthy after install (rc=$rc): $(printf '%s' "$out" | tr '\n' ' ')"
  next="$(printf '%s\n' "$out" | sed -n 's/^next_run=//p' | head -1)"
  last="$(printf '%s\n' "$out" | sed -n 's/^  status=//p' | head -1)"
  # Globals, for `check_reaping_armed` below: the SAME resolved reaper and last-pass reading, so the
  # two checks cannot disagree about which reaper is armed or when it last ran.
  DISK_REAPER_RESOLVED="$reaper"; DISK_REAPER_LAST="${last:-never}"
  ok "disk reaper scheduled — timer next=${next:-?} last_pass=${last:-never} (state: ${DISK_REAPER_STATE_DIR:-$HOME/.pi/agent/state}/disk-reaper.status)"
}

# ── reaping ARMED, not merely installed (#2916 check 5) ─────────────────────────────────────────
# MEASURED (row 8): a cell that had printed `CELL READY` died with
# `claims.sh: line 1205: printf: write error: No space left on device` — the controller gone, no
# reaping. The reaper that would have prevented it comes from the scheduler that would not start
# (#2908), so "a timer is installed" was true and irrelevant: BYTES are the precondition.
#
# ⛔ IT REUSES THE FLEET'S ONE FLOOR, IT DOES NOT INVENT A SECOND. `disk-floor.sh` is the shared
# pre-dispatch floor (orch-loop.sh and refresh-candidates.sh source it; its header carries the two
# measured 100% cells), so the number and the always-safe reclaim pass are the same ones the
# controller applies on every cycle. A second threshold here would be the "two contracts for one
# safety rule" defect docs/ops/fleet-liveness.md §3 names.
# WHO REPAIRS IT: the pass itself (the cheap always-safe subset), and after that the armed timer
# `check_disk_reaper` just installed — the measured remaining classes (lane worktrees, lane venvs,
# duplicate installs) are `disk-reaper.sh`'s. What NEITHER can free needs a human, and the refusal
# says so instead of dispatching lanes onto a full disk.
check_reaping_armed() {
  local floor="" cand rc=0 out
  for cand in "${DISK_FLOOR_LIB:-}" \
              "${HOME:-}/.pi/agent/scripts/orchestrator-harness/disk-floor.sh" \
              "${LAYER_ROOT:-}/scripts/orchestrator-harness/disk-floor.sh" \
              "$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/orchestrator-harness/disk-floor.sh" \
              "$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/disk-floor.sh"; do
    [ -n "$cand" ] && [ -f "$cand" ] && { floor="$cand"; break; }
  done
  [ -n "$floor" ] || die "CANNOT VERIFY [reaping armed before lanes]: disk-floor.sh not found (looked at \$DISK_FLOOR_LIB, \$HOME/.pi/agent/scripts/orchestrator-harness, \$LAYER_ROOT/scripts/orchestrator-harness, and beside this script) — the disk floor and its reclaim pass cannot be run, and a cell certified without them stops dispatching at ~97% used with 'No space left on device' (row 8). FIX: re-run the operational-layer step (it farms the harness scripts) and re-run this check"
  # shellcheck source=/dev/null
  . "$floor"
  out="$(disk_floor_gate "${CELL_HOME:-$HOME}" 2>&1)"; rc=$?
  [ -z "$out" ] || printf '%s\n' "$out" | sed 's/^/    /'
  case "$rc" in
    0) ok "reaping armed before lanes: free disk meets the floor (DISK_FLOOR_MB=${DISK_FLOOR_MB:-?}), reaper last_pass=${DISK_REAPER_LAST:-?}" ;;
    2) die "CANNOT VERIFY [reaping armed before lanes]: df did not answer, so the floor could not be measured — refusing a cell whose free space is unknown (a full disk is the state row 8 measured, and it arrives without any other signal). FIX: repair the mount/df read on this box, then re-run" ;;
    *) die "CHECK FAILED [reaping armed before lanes]: the filesystem is below the disk floor even after the safe reclaim pass — lanes dispatched onto this cell write until 'No space left on device' kills the controller (measured).${out:+ The pass said: $out} Reaper last_pass=${DISK_REAPER_LAST:-?}. FIX: free bytes now — the remaining classes are disk-reaper.sh's: bash ${DISK_REAPER_RESOLVED:-<disk-reaper.sh>} --apply --repo ${WORKDIR:-<checkout>} — or lower DISK_FLOOR_MB deliberately; then re-run this check" ;;
  esac
}

# check_harness_apply — put ACTIVATION on the clock too (#2416), through the SAME one-install-verb
# split as the disk reaper above. The pass calls the box's existing verbs (`cloud-cell-supervisor.sh
# apply`, or the checkout's `./sync.sh`) and owns only the safety predicates; this function owns WHERE
# and HOW the schedule lives, and REFUSES rather than skipping — a cell that runs whatever code it had
# when it was last started is the drift the pass exists to stop, and "no timer" must never be quiet.
check_harness_apply() {
  local installer="" pass="" cand out rc next repo
  for cand in "${HARNESS_APPLY_TIMER_INSTALLER:-}" \
              "${HOME:-}/.pi/agent/scripts/install-harness-apply-timer.sh" \
              "$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/install-harness-apply-timer.sh"; do
    [ -n "$cand" ] && [ -f "$cand" ] && { installer="$cand"; break; }
  done
  for cand in "${HARNESS_APPLY_PASS:-}" \
              "${HOME:-}/.pi/agent/scripts/harness-apply-pass.sh" \
              "$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/harness-apply-pass.sh"; do
    [ -n "$cand" ] && [ -f "$cand" ] && { pass="$cand"; break; }
  done
  [ -n "$installer" ] || die "install-harness-apply-timer.sh not found — cannot schedule harness activation, and an unscheduled activation never happens (the measured state: a cell 91 commits behind main with every signal reading auto)"
  [ -n "$pass" ] || die "harness-apply-pass.sh not found — the timer would have nothing to run"
  # ⛔ THE CHECKOUT IS RESOLVED HERE, NOT INHERITED FROM ONE VARIABLE. The farmed installer has no
  # checkout beside it ($HOME/.pi/agent is not a git repo), so leaving it to that default would refuse
  # on every cell — or, worse, be defaulted onto a directory that is not a checkout and fail every tick
  # while list-timers showed the job healthy. `LAYER_ROOT` alone is not enough either: measured on this
  # suite's own fixture, it was empty at this point and the install REFUSED on a perfectly good box.
  # Same candidate order the installer and harness-refresh use, and the MAIN worktree is what is taken.
  repo=""
  # ⛔ THE TREE THE LAYER CAME FROM OUTRANKS AN AMBIENT `$AGENT_INFRA_PATH`. Measured: with a stale
  # ambient path in the environment, the timer was rendered from a DIFFERENT checkout than the layer
  # this run just installed — and that checkout had no harness-apply templates at all, so the whole
  # bring-up died on a box that was perfectly healthy.
  for cand in "${HARNESS_APPLY_REPO:-}" "${LAYER_ROOT:-}" "${INFRA_ROOT:-}" "${AGENT_INFRA_PATH:-}" \
              "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"; do
    [ -n "$cand" ] && [ -d "$cand" ] || continue
    # `rev-parse --git-dir` is the TEST that this is a checkout; `worktree list` only PREFERS the main
    # worktree (so a pin is never taken for the repo). A listing that cannot be read must not turn a
    # confirmed checkout into "no checkout on this box" — that false refusal is measured, under this
    # very suite's functional `git` stub.
    git -C "$cand" rev-parse --git-dir >/dev/null 2>&1 || continue
    repo="$(git -C "$cand" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print substr($0,10); exit}')"
    repo="${repo:-$cand}"
    break
  done
  [ -n "$repo" ] || die "no agent-infra checkout resolved for the harness-apply timer (looked at \$HARNESS_APPLY_REPO, \$AGENT_INFRA_PATH, \$LAYER_ROOT, \$INFRA_ROOT, and this script's own checkout) — set HARNESS_APPLY_REPO=<checkout>"
  # The templates come from the tree that SHIPS this installer when that tree carries them (the farmed
  # copy at $HOME/.pi/agent/scripts has no ../templates, so it falls back to the resolved checkout).
  # Without this split the unit and the pass it runs can come from two different versions of the repo.
  local inst_root tpl_sys tpl_launchd
  inst_root="$(cd "$(dirname "$installer")/.." 2>/dev/null && pwd)"
  tpl_sys="$repo/templates/systemd"
  [ -n "$inst_root" ] && [ -f "$inst_root/templates/systemd/eldato-harness-apply.timer" ] && tpl_sys="$inst_root/templates/systemd"
  tpl_launchd="${tpl_sys%/systemd}/launchd/harness-apply"

  rc=0
  out="$(HARNESS_APPLY_PASS="$pass" HARNESS_APPLY_REPO="$repo" \
         TEMPLATES_DIR="$tpl_sys" LAUNCHD_TEMPLATES_DIR="$tpl_launchd" \
         bash "$installer" --install 2>&1)" || rc=$?
  printf '%s\n' "$out" | sed 's/^/    /'
  [ "$rc" -eq 0 ] || die "the harness-apply timer could not be installed (rc=$rc) — fix the reason above (a passwordless-sudo system unit, or a working systemd user manager) before this cell is used"

  rc=0
  out="$(HARNESS_APPLY_PASS="$pass" HARNESS_APPLY_REPO="$repo" \
         TEMPLATES_DIR="$tpl_sys" LAUNCHD_TEMPLATES_DIR="$tpl_launchd" \
         bash "$installer" --status 2>&1)" || rc=$?
  printf '%s\n' "$out" | sed 's/^/    /'
  [ "$rc" -eq 0 ] || die "the harness-apply timer is not healthy after install (rc=$rc): $(printf '%s' "$out" | tr '\n' ' ')"
  next="$(printf '%s\n' "$out" | sed -n 's/^next_run=//p' | head -1)"
  ok "harness activation scheduled — timer next=${next:-?} (record: ${HARNESS_APPLY_STATE_DIR:-$HOME/.pi/agent/state}/harness-apply.status)"
}
# ── the two periodic passes: objective reminder + controller watchdog (agent-infra#2691) ────────
# Both were built on the operator's Mac and stayed there. On a cell they are systemd timers (the same
# mechanism the disk reaper uses), rendered by install-cell-timers.sh. This check RUNS that install verb
# and READS IT BACK, exactly as check_disk_reaper and check_controller_service do — a cell that cannot
# schedule them is REFUSED, because a reminder that never fires is the failure mode with no signal (it
# exits 0 and writes one log line nobody reads), and a watchdog with no clock protects nothing.
check_cell_timers() {
  local installer="" out rc
  for cand in "${CELL_TIMERS_INSTALLER:-}" \
              "${LAYER_ROOT:-}/scripts/install-cell-timers.sh" \
              "$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/install-cell-timers.sh"; do
    [ -n "$cand" ] && [ -f "$cand" ] && { installer="$cand"; break; }
  done
  [ -n "$installer" ] || die "install-cell-timers.sh not found (looked at \$CELL_TIMERS_INSTALLER, \$LAYER_ROOT/scripts, and beside this script) — the objective reminder and the controller watchdog would never run on this cell, and neither absence reds anything"
  # The env is built as an ARRAY, not a string: a checkout path with a space in it would otherwise split
  # into two assignments and render units pointing at the wrong tree (the same failure the disk reaper's
  # installer refuses at install time; this avoids producing it at all).
  local -a cenv=(CELL_HOME="${CELL_HOME:-$HOME}" O="${O:-${CELL_HOME:-$HOME}/orchestrator}")
  [ -n "${LAYER_ROOT:-}" ] && cenv+=("TEMPLATES_DIR=$LAYER_ROOT/templates/systemd")

  rc=0
  out="$(env "${cenv[@]}" bash "$installer" --install 2>&1)" || rc=$?
  printf '%s\n' "$out" | sed 's/^/    /'
  [ "$rc" -eq 0 ] || die "the cell timers could not be installed (rc=$rc) — fix the reason above (a passwordless-sudo system unit, or a working systemd user manager with linger) before this cell is used; an unscheduled reminder and watchdog are silent by construction"
  rc=0
  out="$(env "${cenv[@]}" bash "$installer" --status 2>&1)" || rc=$?
  [ "$rc" -eq 0 ] || die "the cell timers are not healthy after install (rc=$rc): $(printf '%s' "$out" | tr '\n' ' ')"
  ok "periodic passes scheduled — objective reminder (10 min) and controller watchdog (5 min) are enabled and active"
}

# ── controller: the SERVICE that keeps the dispatcher alive (agent-infra#2402) ──────────────────
# The controller lived and died as a tmux SESSION, and a tmux session has nothing above it: when the box
# emptied, the last session closed, the tmux server exited and the dispatcher was gone — the cell read as
# a healthy idle box (measured 2026-10-23 on cell-1). `install-controller-service.sh` puts it under a
# systemd unit with `Restart=always`; this check RUNS that verb and READS IT BACK, exactly as
# `check_disk_reaper` does for the timer. ⛔ A CELL WHOSE CONTROLLER HAS NOTHING ABOVE IT IS REFUSED, not
# certified: `CELL READY` over a box that stops dispatching the moment it empties is the false PASS this
# script exists to remove — and the installer is never invoked anywhere else, so without this the fix is
# inert on every cell the bring-up provisions.
check_controller_service() {
  local installer="" cand out rc
  # macOS is REFUSED by the installer ON PURPOSE: the launchd agent already has `KeepAlive`, so a second
  # supervisor there would be a second dispatcher on one queue. Running the installer would only produce
  # a false red against a healthy Mac.
  # ⛔ BUT "REFUSED THE INSTALLER" IS NOT "VERIFIED SUPERVISED" (review P2, #2402). This arm used to
  # print `ok "controller supervised by the launchd agent"` without reading anything at all — an
  # assertion, not a check, which is the same "a claim nobody measured" shape #2402 exists to remove.
  # It is NOT made a hard refusal: launching a `launchctl print gui/$UID/com.eldato.orchestrator-loop`
  # read here would refuse a healthy Mac on any context where that read is unavailable, and this PR's
  # scope deliberately excludes the macOS path. So the claim is withdrawn and the gap is NAMED instead
  # of hidden — the bring-up certifies the cell, and it says exactly what it did not look at.
  # ⛔ `warn`, NOT `ok` (review P2, #2402): `ok "…NOT VERIFIED…"` printed a GREEN line for something no read
  # produced, so the pass tally counted a pass over an unread surface — the "claim nobody measured" shape in
  # miniature, on the one arm whose whole point is that nothing was measured.
  if [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then
    warn "controller supervision on macOS is NOT VERIFIED by this check — the launchd agent (com.eldato.orchestrator-loop) is out of scope here and nothing in this run read launchctl; verify with: launchctl print gui/\$UID/com.eldato.orchestrator-loop"
    return 0
  fi
  for cand in "${CONTROLLER_SERVICE_INSTALLER:-}" \
              "${HOME:-}/.pi/agent/scripts/install-controller-service.sh" \
              "${LAYER_ROOT:-}/scripts/install-controller-service.sh" \
              "$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/install-controller-service.sh"; do
    [ -n "$cand" ] && [ -f "$cand" ] && { installer="$cand"; break; }
  done
  [ -n "$installer" ] || die "install-controller-service.sh not found (looked at \$CONTROLLER_SERVICE_INSTALLER, \$HOME/.pi/agent/scripts, \$LAYER_ROOT/scripts, and beside this script) — the controller would stay a tmux session with nothing above it (#2402): it survives until the box empties, and then it is gone with no signal"
  # ⛔ THE LAYER THE BRING-UP ALREADY TRUSTS IS THE ONE TO RUN (review P1, #2402). This script is normally
  # pushed STANDALONE into /tmp, so "beside this script" proves nothing, and the installer is not in the
  # farm list — a cell provisioned the documented way therefore found nothing here and DIED at this check
  # (killing every bring-up). $LAYER_ROOT/scripts is the checkout check_operational_layer just installed.
  # The supervisor is resolved from the SAME checkout: the installer prefers $HOME/.pi/agent/scripts, and a
  # stale copy there predating ORCH_FOREGROUND would hand the unit a launcher that exits 0.
  local layer_sup="${LAYER_ROOT:+$LAYER_ROOT/scripts/cloud-cell-supervisor.sh}"
  [ -n "$layer_sup" ] && [ -f "$layer_sup" ] || layer_sup=""
  local -a cenv=(TEMPLATES_DIR="${LAYER_ROOT:+$LAYER_ROOT/templates/systemd}")
  [ -n "$layer_sup" ] && cenv+=("ORCH_SUPERVISOR=$layer_sup")

  rc=0
  # TEMPLATES_DIR from the SAME checkout the layer came from (the farmed installer copy lives at
  # $HOME/.pi/agent/scripts, whose ../templates does not exist) — same rule as check_disk_reaper.
  out="$(env "${cenv[@]}" bash "$installer" --install 2>&1)" || rc=$?
  printf '%s\n' "$out" | sed 's/^/    /'
  [ "$rc" -eq 0 ] || die "the controller service could not be installed (rc=$rc) — fix the reason above (a passwordless-sudo system unit, or a working systemd user manager with linger) before this cell is used; an unsupervised controller dies with the last lane"

  rc=0
  out="$(env "${cenv[@]}" bash "$installer" --status 2>&1)" || rc=$?
  [ "$rc" -eq 0 ] || die "the controller service is not healthy after install (rc=$rc): $(printf '%s' "$out" | tr '\n' ' ')"
  ok "controller supervised — eldato-orchestrator.service is enabled and active (Restart=always: a dead controller comes back without a human; stop it with 'cloud-cell-supervisor.sh stop')"
}

# ── the SCHEDULED layer (agent-infra#1864) ────────────────────────────────────────────────────
# WHY, in one line: the repo declares every recurring job ONCE as a launchd plist and delivered it
# with a launchd-only installer, so the cells — which are Linux and have no launchd — received NONE
# of the ten jobs. Measured 2026-10-16: scheduled jobs 24 (Mac) / 0 / 0 / 0 (cells), reap scripts 4
# / 0 / 0 / 0, heartbeat running / DEAD / DEAD / DEAD. Nothing announced it, because a schedule that
# is absent looks exactly like a schedule with nothing to do.
#
# The mechanism is decided ONCE, in scripts/fleet-schedule.py: a supervised in-session loop that
# reads the SAME plists. It is not cron and not systemd timers because a cmux cloud cell has
# neither available: `command -v crontab` → absent, and `systemctl --user status` → "Failed to
# connect to bus: No medium found" (systemd is pid 1 in SYSTEM mode, with no user bus). A crontab
# entry or an enabled user timer there would be installed-and-inert, which is exactly the false
# PASS this issue is about.
#
# FATAL, like check_operational_layer above and for the same reason: nothing else installs this.
# `--install` converges the loop, RUNS the due jobs now, and reads the result back from the per-job
# stamps — so "scheduled" is asserted from a run (a fresh log line and an rc), never from the
# presence of a file or a loaded unit.
check_schedule() {
  local sched="$CELL_HOME/.pi/agent/scripts/fleet-schedule.py" root="${LAYER_ROOT:-}" out rc=0
  # The FARMED copy, not the checkout's: it is what the loop will execute on every tick, and
  # cell-install.sh has just byte-verified it against the checkout. A checkout copy here would
  # certify one file while a different one runs.
  if [ ! -f "$sched" ]; then
    die "the scheduled layer is MISSING: $sched does not exist, so no reap job, no liveness report and no canary would ever run on this cell (agent-infra#1864). The operational layer above was supposed to install it — re-run:  CELL_HOME=$CELL_HOME INFRA_ROOT=$root bash $root/pi-bootstrap/cell-install.sh --install"
  fi
  if [ -z "$root" ]; then
    die "cannot locate the agent-infra checkout the job declarations come from (templates/launchd) — without it this cell has NO scheduled layer (#1864)"
  fi
  # The job declarations are the checkout's (one source of truth, like $AGENT_INFRA_PATH on the
  # Mac). INFRA_ROOT is passed explicitly so the farmed script does not have to guess.
  #
  # ⛔ `TEMPLATES_DIR` IS NOT PINNED HERE, AND THAT IS DELIBERATE. fleet-schedule.py resolves it as
  # `TEMPLATES_DIR or <INFRA_ROOT>/templates/launchd`, so an ambient value outranks the checkout we
  # just pinned. Pinning it unconditionally is NOT available: it is the ONLY seam the hermetic
  # suites have (they point it at fixture plists precisely so the shipped templates — armed
  # reapers — never run against the host that runs the tests), and hard-coding the checkout here
  # would make `scripts/cloud-cell-bringup.test.sh` execute the REAL reapers on the test box.
  # So the override stays and the DIVERGENCE IS NAMED instead of silent: an operator reading the
  # cell's log sees which declaration set was installed. A cell that is armed from a foreign dir
  # by accident is then one grep away, not invisible.
  if [ -n "${TEMPLATES_DIR:-}" ] && [ "${TEMPLATES_DIR%/}" != "$root/templates/launchd" ]; then
    warn "the scheduled job declarations come from $TEMPLATES_DIR, NOT from this cell's checkout ($root/templates/launchd) — TEMPLATES_DIR is set in this environment"
  fi
  # FLEET_SCHEDULE_STATE IS pinned: the loop started here must be the one the cell's later --start
  # supervises, and a foreign state dir would put two loops over one job set.
  out="$(HOME="$CELL_HOME" CELL_HOME="$CELL_HOME" INFRA_ROOT="$root" \
         FLEET_SCHEDULE_STATE="$CELL_HOME/.pi/agent/state/fleet-schedule" \
         python3 "$sched" --install 2>&1)" || rc=$?
  printf '%s\n' "$out" | sed 's/^/    /'
  if [ "$rc" -ne 0 ]; then
    die "the scheduled layer FAILED to install or verify (rc=$rc) — this cell would run with no reaping, no liveness detection and no canary, and NOTHING else installs them (#1864). Fix the failure above."
  fi
  # The verdict line is the proof: it counts the jobs that actually RAN on this machine and names
  # the ones that cannot run here. Burying it in the indented block would make "deployed" a claim.
  local verdict; verdict="$(printf '%s\n' "$out" | grep -E '^SCHEDULE VERIFIED' | head -1)"
  [ -n "$verdict" ] || die "the scheduler printed no SCHEDULE VERIFIED verdict — refusing to report a cell ready on an unverified schedule (#1864)"

  check_schedule_verify "$sched" "$root" "$verdict"
}

# ── the schedule LOADS IN FULL, asserted by the verify verb (#2916 check 4) ────────────────────
# `--install` ends by calling cmd_verify(), so its rc covers most of this — but the measured signature
# is "`fleet-schedule.py --verify` non-zero, OR ANY `FAIL` line", and a gate that only greps for the
# success line accepts a log that carries BOTH (the pre-fix code did exactly that: it grepped for
# `SCHEDULE VERIFIED` and never looked at `FAIL`).
# The controller's `--start` shares these declarations (`load_jobs`), so a set that verifies here is
# the set `--start` will accept; a set that does not is #2908 — `FAIL com.eldato.ai-drainer:
# placeholder(s) this runtime does not know: {{AI_DRAINER_O}}`, no reaping, no liveness, controller
# rc=1 on every restart.
# WHO REPAIRS IT: nobody automatic. The DECLARATION is the defect (a shipped template against the
# shipped runtime), and neither the watchdog nor the loop can start on a set they cannot read — so
# this refuses and names the FAIL lines, instead of leaving a cell that prints `CELL READY` and then
# cannot keep a controller alive.
check_schedule_verify() { # <farmed fleet-schedule.py> <checkout root> <verdict line>
  local sched="$1" root="$2" verdict="$3" out rc=0 fails
  out="$(HOME="$CELL_HOME" CELL_HOME="$CELL_HOME" INFRA_ROOT="$root" \
         FLEET_SCHEDULE_STATE="$CELL_HOME/.pi/agent/state/fleet-schedule" \
         python3 "$sched" --verify 2>&1)" || rc=$?
  printf '%s\n' "$out" | sed 's/^/    /'
  fails="$(printf '%s\n' "$out" | grep -E '^ *FAIL')"
  [ -z "$fails" ] || die "CHECK FAILED [scheduled layer]: fleet-schedule.py --verify printed FAIL (rc=$rc) — the declared job set does not load in full, so this cell would run with no reaping, no liveness detection and no canary AND the controller would refuse to start on it (#1864/#2908). The FAIL lines:
$(printf '%s\n' "$fails" | sed 's/^/    /')
FIX: repair the declaration each line names in $root/templates/launchd (a placeholder this runtime does not know, or a job with no StartInterval) and re-run this check — a template/vs-runtime skew is a repo fix, not a cell fix"
  [ "$rc" -eq 0 ] || die "CHECK FAILED [scheduled layer]: fleet-schedule.py --verify exited $rc and printed no FAIL line — refusing a cell whose schedule cannot be verified (CANNOT-VERIFY is never a pass)"
  ok "scheduled layer live: $verdict; --verify rc=0 with no FAIL line"
}

main() {
  export HOME_ORIG="${HOME:-}"
  log_line "cloud-cell bringup — mode=$MODE uid=$(id -u)"
  setup_home
  # ⛔ UNCONDITIONALLY, BEFORE ANY CHECK READS A REPO — not only after `$ENV_FILE` is sourced. A
  # MISSING keys.env is a supported, non-fatal path (`check_provider` only warns), and every check
  # below then runs against an operator shell that may itself carry `GH_REPO` (it is sticky
  # per-shell): the guard would skip exactly the run that has no file to restore it from, and
  # `check_gh`/`check_repo`/`check_dispatch` would grade another repo while printing `CELL READY`.
  # `source_env_file` repeats it AFTER sourcing, because the file can set it too; both calls are
  # idempotent, so the pair covers both carriers.
  neutralise_gh_repo
  check_tools
  check_network
  case "$MODE" in
    --check)
      check_provider
      # IMMEDIATELY after the env is sourced and HOME is forced: the ONE-home predicate reads the
      # paths this run will hand the cell, so it must run while they are still the run's own values
      # (later steps rewrite WORKDIR/HARNESS_PIN_DIR, and a check that reads them afterwards grades
      # its own repair).
      check_one_home env
      check_gh
      check_repo
      check_dispatch
      check_operational_layer
      # AFTER the layer: this needs the checkout `check_operational_layer` trusted (LAYER_ROOT) as the
      # repo to pin FROM, and a NEW box otherwise has no pin at all — the state in which the operator's
      # fallback is the hand-copy that made `$HOME/harness` a directory of sha-named copies.
      check_harness_pin
      # AFTER the layer exists: registry-sync.sh arrives WITH it (the farm), and the checkout that
      # installed the layer is the store whose remote carries the refs.
      check_review_registry
      # AFTER the layer exists: this measures the cluster of extensions the cell will actually run.
      # Measuring it earlier would probe an empty set on a first bring-up and certify a layer that
      # had not been installed yet (#2100 review).
      check_provider_layer
      check_schedule
      check_caches
      # Before the reaper's install step: a cell that cannot get swap must be refused EARLY, not
      # after the scheduler work — and the reading is what the operator needs from the refusal.
      check_swap
      check_disk_reaper
      # AFTER the reaper is armed and its state recorded: BYTES are the precondition for lanes, and
      # the measured failure (row 8) was a cell that had printed CELL READY and then filled its disk
      # with no reaping. Reuses the fleet's one floor (disk-floor.sh), not a second threshold.
      check_reaping_armed
      # Both schedulers/supervisors are installed AFTER the layer exists: each installer is resolved
      # FROM that layer (the harness-apply one from #2416, the controller one from #2402), so measuring
      # either earlier would probe a directory that has not been populated yet.
      check_harness_apply
      check_controller_service
      # AFTER the controller service: the two periodic passes (objective reminder, controller watchdog)
      # are systemd timers on the SAME manager this box just proved it has. Without this check they are
      # "reachable" only in the sense that a template exists — which is the inert-enforcer shape.
      check_cell_timers
      # ⛔ LAST, and only here: the units leg scans what the installers above RENDERED. Running it
      # earlier would scan an empty (or previous state dir's) directory and certify nothing — the
      # vacuity trap. It reads the rendered files, never the installer's intent.
      check_one_home units
      # `CELL READY` is a claim about the cell, and "no pushed credential left on disk" is part of
      # it. The EXIT trap covers every other exit path; this makes the banner's own path fail-closed
      # too, so the banner is never printed while a registered secret is still there.
      remove_secrets \
        || die "a secret file could not be removed — refusing to report readiness; delete it by hand before using this VM"
      log_line "CELL READY — all links verified (one home, tools, network, provider, gh auth, push, clone, dispatch pre-flight, operational layer, harness pin, scheduled layer, caches reported, swap active, harness activation scheduled, controller supervised, cell timers, rendered units)"
      ;;
    *)
      log_line "unknown mode: $MODE (use --check)"; exit 2 ;;
  esac
}
main "$@"
