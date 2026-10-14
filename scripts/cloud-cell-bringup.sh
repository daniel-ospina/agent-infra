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
  # "or even inspected": `rm -f` also fails when the PARENT denies traversal and the file was never
  # there, so the honest claim is that we could neither remove nor verify — not that a credential is
  # definitely on disk. The direction is deliberately fail-closed.
  say "SECURITY: $f could not be removed (or even inspected — its directory denies access); delete it by hand before handing this VM on" >&2
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
  # The handler is DEMOTE-ONLY: it never invents a status. A surviving secret turns a would-be 0 into
  # 1 (so `CELL READY` can never accompany a leftover credential); anything else FALLS THROUGH,
  # leaving bash's own status untouched. An explicit `exit "$?"` here would be wrong — `$?` inside
  # an EXIT trap after a fatal signal is 0, not 128+signo.
  trap 'rc=$?; trap - EXIT; trap "" INT TERM HUP; if ! remove_secrets && [ "$rc" -eq 0 ]; then exit 1; fi' EXIT
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
  for c in git gh node python3 uv tmux; do
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
      # `CELL READY` is a claim about the cell, and "no pushed credential left on disk" is part of
      # it. The EXIT trap covers every other exit path; this makes the banner's own path fail-closed
      # too, so the banner is never printed while a registered secret is still there.
      remove_secrets \
        || die "a secret file could not be removed — refusing to report readiness; delete it by hand before using this VM"
      say "CELL READY — all links verified (home, tools, network, provider, gh auth, push, clone)"
      ;;
    *)
      say "unknown mode: $MODE (use --check)"; exit 2 ;;
  esac
}
main "$@"
