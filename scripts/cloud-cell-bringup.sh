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
#  (4) THE OPERATIONAL LAYER IS NOT ON THE CELL (agent-infra#1723).  Measured 2026-10-15 on the
#      live cell pi-lane-1 / vm-efa6cc8fdb974e61b5c054acf41d8846: $CELL_HOME/.pi/agent held only
#      models.json, auth.json, .ai-review-gate-key, reviews/, state/, audit/ and shims/ — no
#      scripts/ (the directory did not exist), no extensions/, no skills/, no AGENTS.md, no
#      settings.json. So a cell lane ran with NO review-enforcer, verification-gate,
#      main-worktree-guard, search-guard or audit-logger — not the same guards as a laptop lane —
#      and its merge path died rc=127 on the missing $HOME/.pi/agent/scripts/record-review.sh,
#      the exact path merge-one.sh:240 executes.
#      FIX: install it BY CONSTRUCTION — pi-bootstrap/cell-install.sh, run from the --check path
#      below, from an agent-infra checkout that is already on the cell. A cell that cannot
#      receive the layer is REFUSED rather than certified: a green `CELL READY` over an
#      unguarded cell is the false PASS this whole script exists to remove.

set -uo pipefail

CELL_HOME="${CELL_HOME:-/tmp/cell-home}"
REPO_SLUG="${REPO_SLUG:-daniel-ospina/tortoise}"
WORKDIR="${WORKDIR:-/tmp/cell}"
ENV_FILE="${ENV_FILE:-$CELL_HOME/keys.env}"
MODE="${1:---check}"

say()  { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }
die()  { say "FATAL: $*" >&2; exit 1; }
ok()   { say "ok: $*"; }
warn() { say "warn: $*"; }

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
# cmd_check covers only record-review.sh + diff-normalize.py (2 of the 24 declared farm
# files), so if this step is skipped nothing else ever installs the guards. A "CELL READY"
# over an unguarded cell is exactly the false PASS this repo keeps removing, and the remedy
# is one env var (`INFRA_ROOT=<checkout>`) — so refuse.
check_operational_layer() {
  local cand root="" installer os_release
  # A cell keeps its agent-infra checkout in any of a few places (this script is normally
  # pushed STANDALONE, so its own directory proves nothing). Identical candidate list to
  # cell-install.sh's own resolver, plus ${BASH_SOURCE[0]}/.. for a run from the checkout.
  for cand in "${INFRA_ROOT:-}" "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)" \
              "${AGENT_INFRA_PATH:-}" "${HARNESS:+$HARNESS/..}" \
              "$CELL_HOME/agent-infra" /tmp/cell-ai; do
    [ -n "$cand" ] || continue
    if [ -f "$cand/pi-bootstrap/cell-install.sh" ]; then root="$cand"; break; fi
  done
  if [ -z "$root" ]; then
    die "no agent-infra checkout on this cell (looked at \$INFRA_ROOT, $(dirname "${BASH_SOURCE[0]}")/.., \$AGENT_INFRA_PATH, \${HARNESS}/.., $CELL_HOME/agent-infra, /tmp/cell-ai).
       The operational layer (guards, skills, the merge-path record-review.sh) cannot be installed,
       so this cell would run unguarded with a rc=127 merge path. Clone agent-infra onto the cell
       and re-run:  INFRA_ROOT=<checkout> bash $0 --check"
  fi
  installer="$root/pi-bootstrap/cell-install.sh"
  ok "installing the operational layer from $root"
  # The installer both installs AND verifies (--install ends in verify_layer). Its exit status
  # is captured from the COMMAND, never from a `| sed` pipeline — a decoration that swallows a
  # failure is how a false PASS gets minted. Its output is indented so the layer's own
  # failures never read as bring-up chatter.
  local out rc=0
  out="$(CELL_HOME="$CELL_HOME" INFRA_ROOT="$root" bash "$installer" --install 2>&1)" || rc=$?
  printf '%s\n' "$out" | sed 's/^/    /'
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
      say "CELL READY — all links verified (home, tools, network, provider, gh auth, push, clone, dispatch pre-flight, operational layer)"
      ;;
    *)
      say "unknown mode: $MODE (use --check)"; exit 2 ;;
  esac
}
main "$@"
