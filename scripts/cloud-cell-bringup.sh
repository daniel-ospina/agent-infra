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

set -uo pipefail

CELL_HOME="${CELL_HOME:-/tmp/cell-home}"
REPO_SLUG="${REPO_SLUG:-daniel-ospina/tortoise}"
WORKDIR="${WORKDIR:-/tmp/cell}"
ENV_FILE="${ENV_FILE:-/tmp/cell-home/keys.env}"
MODE="${1:---check}"

say()  { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }
die()  { say "FATAL: $*" >&2; exit 1; }
ok()   { say "ok: $*"; }
warn() { say "warn: $*"; }

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
    set -a; . "$ENV_FILE"; set +a
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
check_gh() {
  local tokfile="${1:-/tmp/.gh-tok}"
  if [ -f "$tokfile" ]; then
    gh auth login --with-token < "$tokfile" >/dev/null 2>&1 \
      && ok "gh authenticated from $tokfile" \
      || die "gh auth failed from $tokfile"
    rm -f "$tokfile" && ok "token file removed"
  fi
  gh auth status >/dev/null 2>&1 || die "gh is not authenticated (push /tmp/.gh-tok via --secret)"
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
      say "CELL READY — all links verified (home, tools, network, provider, gh auth, push, clone)"
      ;;
    *)
      say "unknown mode: $MODE (use --check)"; exit 2 ;;
  esac
}
main "$@"
