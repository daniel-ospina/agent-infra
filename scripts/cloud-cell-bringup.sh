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

set -uo pipefail

CELL_HOME="${CELL_HOME:-/tmp/cell-home}"
REPO_SLUG="${REPO_SLUG:-daniel-ospina/tortoise}"
WORKDIR="${WORKDIR:-/tmp/cell}"
ENV_FILE="${ENV_FILE:-$CELL_HOME/keys.env}"
# The pushed gh token. Overridable for the same reason every other path here is (a hermetic test
# must never touch the REAL /tmp/.gh-tok) — see the secret-lifetime block below.
GH_TOKEN_FILE="${GH_TOKEN_FILE:-/tmp/.gh-tok}"
MODE="${1:---check}"

say()  { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }
die()  { say "FATAL: $*" >&2; exit 1; }
ok()   { say "ok: $*"; }
warn() { say "warn: $*"; }

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
  say "SECURITY: $f could not be removed (or even inspected); delete it by hand before handing this VM on" >&2
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
  local out
  out="$(timeout 120 pi -p --no-session --provider deepseek --model deepseek-flash \
          'Reply with exactly: LANE_READY' 2>&1 | tail -3)"
  case "$out" in
    *LANE_READY*) ok "provider call works (pi returned LANE_READY)" ;;
    *authentication_error*|*invalid*x-api-key*|*401*)
      die "provider key REJECTED (401). The image's pre-set key is stale — push a valid one." ;;
    *) die "provider probe failed. Last output: $out" ;;
  esac
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
  if ! out="$(REPO="$WORKDIR" OR="$REPO_SLUG" O="$CELL_HOME/orchestrator" bash "$harness/refresh-candidates.sh" --check 2>&1)"; then
    printf '%s\n' "$out" >&2
    die "this repo cannot be provisioned for dispatch — the cell would merge only (agent-infra#1736)"
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
    say "  refusing $cand: checkout-shaped but not owned by $(id -un) — pass INFRA_ROOT=<checkout> to use it deliberately"
  done
  if [ -z "$root" ]; then
    die "no agent-infra checkout on this cell (looked at \$INFRA_ROOT, $self_root, \$AGENT_INFRA_PATH, \${HARNESS}/.., $CELL_HOME/agent-infra).
       The operational layer (guards, skills, the merge-path record-review.sh) cannot be installed,
       so this cell would run unguarded with a rc=127 merge path. Clone agent-infra onto the cell
       and re-run:  INFRA_ROOT=<checkout> bash $0 --check"
  fi
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
    say "  the cell does not carry a current layer (verify rc=$rc) — installing it from $root"
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
  # A cell is Linux. Say which one, because the layer's own selection is surface-aware (no
  # cmux desktop app, no launchd) and a reviewer reading a cell log should see the surface.
  if [ -r /etc/os-release ]; then
    os_release="$(. /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-unknown}")"
    ok "cell surface: ${os_release:-unknown} (Linux — cmux-session.ts and launchd are not installed)"
  fi
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

main() {
  export HOME_ORIG="${HOME:-}"
  say "cloud-cell bringup — mode=$MODE uid=$(id -u)"
  setup_home
  check_tools
  check_network
  case "$MODE" in
    --check)
      check_provider
      check_gh
      check_repo
      check_dispatch
      check_operational_layer
      check_caches
      # `CELL READY` is a claim about the cell, and "no pushed credential left on disk" is part of
      # it. The EXIT trap covers every other exit path; this makes the banner's own path fail-closed
      # too, so the banner is never printed while a registered secret is still there.
      remove_secrets \
        || die "a secret file could not be removed — refusing to report readiness; delete it by hand before using this VM"
      say "CELL READY — all links verified (home, tools, network, provider, gh auth, push, clone, dispatch pre-flight, operational layer, caches reported)"
      ;;
    *)
      say "unknown mode: $MODE (use --check)"; exit 2 ;;
  esac
}
main "$@"
