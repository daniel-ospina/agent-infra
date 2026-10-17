#!/usr/bin/env bash
# orchestrator-bringup.sh — ONE entry point for the orchestrator stack on THIS machine.
#
#   bash scripts/orchestrator-bringup.sh check            # is this machine configured for this repo?
#   bash scripts/orchestrator-bringup.sh start            # bring the whole stack up
#   bash scripts/orchestrator-bringup.sh stop
#   bash scripts/orchestrator-bringup.sh status
#   bash scripts/orchestrator-bringup.sh --reseed [verb]  # regenerate the machine-local config, then verb
#
# Exit codes, for every verb:
#   0  ok
#   1  REFUSED — one actionable line on stderr; nothing was started
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

say()  { printf '%s\n' "$*"; }
ok()   { printf 'ok: %s\n' "$*"; }
warn() { printf 'warn: %s\n' "$*" >&2; }
# A refusal is ONE line: the actionable sentence, on stderr, with rc=1. Anything the operator needs
# beyond that is printed by the caller before it refuses (never after — a message after the refusal
# is a message nobody reads, because the tool has already exited).
refuse()  { printf 'bringup: REFUSED: %s\n' "$1" >&2; exit 1; }
unknown() { printf 'bringup: CANNOT DETERMINE: %s\n' "$1" >&2; exit 2; }

usage() {
  sed -n '2,/^set -uo pipefail$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; $d'
  exit 0
}

VERB=""; RESEED=0
for a in "$@"; do
  case "$a" in
    check|start|stop|status) VERB="$a" ;;
    --reseed)               RESEED=1 ;;
    -h|--help)              usage ;;
    *) printf 'bringup: unknown argument %s\n' "$a" >&2; usage ;;
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
else
  ENV_FILE="${ENV_FILE:-$HOME/.config/orchestrator/bringup.env}"
  O="${O:-$HOME/orchestrator}"
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
  if [ -z "${O_FROM_ENV:-}" ]; then v="$(env_file_value O "$ENV_FILE")"; [ -n "$v" ] && O="$v"; fi
  return 0
}
O_FROM_ENV="$O"   # set before load_config_file: the platform default is a fallback, not an override
O_DEFAULT="$O"
load_config_file

# The repo identity this machine is configured for, as `<owner>/<repo>`.
SLUG=""; SLUG_REPO=""

# ── SCOPED process reads ───────────────────────────────────────────────────────────────────────
# ⛔ Every read below is scoped to THIS state dir's own orch-loop.sh path, and never a bare
# `pgrep -f orch-loop.sh`. Measured 2026-10-15: an unscoped read matched FOUR controllers on a dev
# box — this box's real controller, a leaked test fixture, and two of a peer lane's own test — and a
# destructive verb driven by that read would have killed a peer's work. Descendants are excluded for
# the same measured reason (`orch-loop.sh` spawns children whose command line also matches).
local_controller_pids() {
  ps -eo pid=,ppid=,command= 2>/dev/null | awk -v want="$O/orch-loop.sh" '
    { ppid[$1]=$2; c=$0; sub(/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+/,"",c)
      n=split(c,tok," ")
      if (n>=2 && tok[2]==want && tok[1] ~ /(bash|sh|dash|zsh)$/) m[$1]=1 }
    END { for (p in m) { q=p; d=0
            for (i=0;i<64;i++) { if (!(q in ppid) || ppid[q]<=1) break; q=ppid[q]; if (q in m) { d=1; break } }
            if (!d) print p } }'
}
lock_pid() {
  local p c
  p="$(tr -dc '0-9' 2>/dev/null < "$O/.orch.lock")"
  [ -n "$p" ] || return 0
  kill -0 "$p" 2>/dev/null || return 0
  c="$(ps -o command= -p "$p" 2>/dev/null)" || return 0
  case "$c" in *orch-loop.sh*) printf '%s\n' "$p" ;; esac
}
pids_join() { printf '%s' "$1" | tr '\n' ' ' | sed 's/ *$//'; }

# ── repo identity ───────────────────────────────────────────────────────────────────────────────
# The queue's repo and the checkout are ONE fact (agent-infra#1901): the checkout's `origin` is what
# the machine can actually read, and an explicit OR is an override that must MATCH it. This file
# refuses the pair, and cloud-cell-supervisor.sh refuses it again on the start path — the duplication
# is deliberate on a REFUSAL (each surface must be safe on its own); what must never be duplicated is
# a PASS.
resolve_repo_identity() {
  [ -n "${REPO:-}" ] || return 1
  if [ -n "${OR:-}" ]; then
    repo_matches_checkout "$OR" "$REPO"; local rc=$?
    case "$rc" in
      0) SLUG_REPO="$OR"; return 0 ;;
      1) refuse "the queue repo and the checkout name DIFFERENT repos: OR=$OR but $REPO is a checkout of '$(repo_of_checkout "$REPO" 2>/dev/null || printf '?')' (origin $(git -C "$REPO" remote get-url origin 2>/dev/null)) — set OR to the checkout's repo, or point REPO at an $OR checkout" ;;
      *) refuse "cannot read the 'origin' remote of $REPO, so OR=$OR cannot be verified against it — a queue target that cannot be checked is never a pass (agent-infra#1901); fix the checkout's remote or unset OR to derive it" ;;
    esac
  fi
  SLUG_REPO="$(repo_of_checkout "$REPO")" \
    || refuse "cannot derive the repo identity from $REPO — its 'origin' remote is missing or does not name <owner>/<repo> in an accepted form (https://, http://, ssh://, or git@host:owner/repo.git), so this machine cannot say which repo it would control"
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
  say "==> reseed: deriving the machine-local config from the checkouts on this disk"
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
    1) :: ;;
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
  [ -z "$bak" ] || say "   previous config preserved at $bak"
  say "   untouched: $O/.orch.lock, $O/state, the candidate files, and the repo's claim refs"
}

# ── check ──────────────────────────────────────────────────────────────────────────────────────
# Every arm answers ONE question, and every arm that cannot answer says so with rc=2 rather than
# letting the next line pass. Nothing here starts, writes or signals anything.
cmd_check() {
  say "==> check ($PLATFORM) — repo=${REPO:-<unset>} (${REPO_SRC:-<unset>})  state=$O"

  # 1. the configured repo path exists on THIS machine — the measured cell failure (see header).
  if [ -z "${REPO:-}" ]; then
    refuse "no repo is configured for this machine — the harness default is another machine's path, and a controller started on it refreshes nothing; pass REPO=<checkout> or run: $0 --reseed"
  fi
  if [ ! -d "$REPO" ]; then
    refuse "the configured repo path does not exist on THIS machine: $REPO (from: $REPO_SRC) — a controller on it aborts every refresh cycle while looking alive; pass REPO=<checkout> or run: $0 --reseed"
  fi
  git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 \
    || refuse "$REPO is not a git checkout (no .git directory or linked-worktree .git file) — pass REPO=<a real checkout>"
  resolve_repo_identity
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
  if [ -f "$ENV_FILE" ]; then
    bash -n "$ENV_FILE" 2>/dev/null \
      || refuse "$ENV_FILE cannot be parsed as shell — sourcing it would silently drop every key it sets; fix it (or move the keys to a file that is only assignments)"
    local k count=0
    for k in $(bash -c 'set -a; . "$1" >/dev/null 2>&1; for v in $(compgen -v); do case "$v" in *_API_KEY) printf "%s\n" "$v";; esac; done' _ "$ENV_FILE" 2>/dev/null); do
      [ -n "$(env_file_value "$k" "$ENV_FILE")" ] && count=$((count + 1))
    done
    if [ "$count" -gt 0 ]; then
      ok "keys: $count provider key(s) load from $ENV_FILE"
    else
      refuse "no provider key (*_API_KEY) with a value loads from $ENV_FILE — every lane would fail its first model call; add one to that file"
    fi
  elif [ "$PLATFORM" = "cell" ]; then
    refuse "no config file at $ENV_FILE — a cell lane has no provider key and no HOME; push one or run: $0 --reseed"
  else
    warn "no config file at $ENV_FILE — this Mac's keys must come from the shell that runs 'install.sh'"
  fi

  # 4. the harness pin is exactly one and owned (cell) / the deployed copy is on the repo's line (Mac).
  check_harness_pin

  # 5. the lock: free, or owned by a live controller.
  local lp live
  lp="$(lock_pid)"
  live="$(local_controller_pids)"
  if [ -n "$lp" ]; then
    ok "lock $O/.orch.lock owned by live controller pid $lp"
  elif [ -f "$O/.orch.lock" ]; then
    warn "$O/.orch.lock names no live controller — stale, and 'start' replaces it"
  else
    ok "lock free ($O/.orch.lock absent)"
  fi
  [ -z "$live" ] || ok "controller running for this state dir: pid $(pids_join "$live")"

  # 6. the per-repo registry: at most ONE live controller per (machine, repo).
  check_registry

  say ""
  say "BRINGUP CHECK OK — this machine can run a controller for $SLUG_REPO"
  return 0
}

check_harness_pin() {
  if [ "$PLATFORM" = "cell" ]; then
    [ -n "${HARNESS:-}" ] || HARNESS=""
    local recorded=""
    [ -f "$HARNESS_PIN_FILE" ] && recorded="$(head -1 "$HARNESS_PIN_FILE" 2>/dev/null)"
    if [ -z "$recorded" ]; then
      ok "no harness pin recorded yet ($HARNESS_PIN_FILE) — 'start' applies one from $HARNESS_REPO_DESC"
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
      warn "the deployed harness at $O has drifted from $src_repo ($(printf '%s' "$out" | grep -c '^DRIFT:' ) finding(s); first: $(printf '%s' "$out" | head -1)) — 'start' redeploys $O from $src_repo before launching"
      ;;
    *) unknown "the deployed harness at $O cannot be verified against $src_repo ($(printf '%s' "$out" | head -1)) — refusing to certify an unknown identity" ;;
  esac
}

# deploy_harness — put THIS checkout's harness into $O, atomically, before the daemon is loaded.
#
# ⛔ load-bearing: the launchd plist runs `__O__/orch-loop.sh`, and `install.sh` does NOT copy the
# scripts there — it only WARNS when $O differs from the shipped copy. So a `start` that skipped this
# step would launch whatever bytes happen to be in $O (on this box: a tree four weeks behind, with a
# post-install hand edit) and the stamp written afterwards would describe a harness nobody runs. Same
# discipline as cloud-cell-supervisor.sh's seed_and_stamp: temp file in the same directory, then
# rename — a running controller's lanes execute `bash $O/<worker>.sh`, and a plain `cp` TRUNCATES the
# live script before rewriting it, so a spawn landing in that window would run half a worker.
deploy_harness() {
  [ -d "$HARNESS_BRINGUP" ] || unknown "no harness at $HARNESS_BRINGUP — nothing to deploy into $O"
  mkdir -p "$O/logs" "$O/state" "$O/wip" || refuse "cannot create the state dir $O"
  local src f tmp n=0
  for src in "$HARNESS_BRINGUP"/*.sh; do
    [ -f "$src" ] || continue
    f="$(basename "$src")"; tmp="$O/.seed-$f.$$"
    cp -p "$src" "$tmp" || { rm -f "$tmp"; refuse "cannot stage $f into $O — check free space"; }
    mv -f "$tmp" "$O/$f" || { rm -f "$tmp"; refuse "cannot install $f into $O"; }
    n=$((n + 1))
  done
  [ "$n" -gt 0 ] || unknown "no *.sh in $HARNESS_BRINGUP — refusing to load a daemon with nothing to run"
  # MIRROR, not overlay: a worker RENAMED upstream would otherwise stay live in $O and invocable.
  for f in "$O"/*.sh; do
    [ -f "$f" ] || continue
    [ -f "$HARNESS_BRINGUP/$(basename "$f")" ] || { rm -f "$f"; say "deploy: removed stale $(basename "$f") — the harness no longer ships it"; }
  done
  if [ -f "$HARNESS_BRINGUP/gh-rest/gh" ]; then
    mkdir -p "$O/gh-rest" || refuse "cannot create $O/gh-rest"
    tmp="$O/gh-rest/.gh.$$"
    cp -p "$HARNESS_BRINGUP/gh-rest/gh" "$tmp" && chmod +x "$tmp" && mv -f "$tmp" "$O/gh-rest/gh" \
      || { rm -f "$tmp"; refuse "cannot install $O/gh-rest/gh"; }
  fi
  ok "deployed $n harness script(s) into $O from $HARNESS_BRINGUP"
}

check_registry() {
  local f verdict kind pid ro st
  f="$(registry_file "$SLUG_REPO")" || unknown "the repo identity '$SLUG_REPO' cannot be turned into a registry key"
  verdict="$(registry_verdict "$f")"
  # shellcheck disable=SC2086
  set -- $verdict; kind="${1:-}"; pid="${2:-}"; ro="${3:-}"; st="${4:-}"
  case "$kind" in
    absent)
      ok "registry: no controller recorded for $SLUG_REPO on this machine"
      ;;
    live)
      if [ "$st" = "starting" ] && [ "$pid" = "$$" ]; then
        ok "registry: this process is starting $SLUG_REPO"
      elif [ "$ro" = "$O" ]; then
        ok "registry: $SLUG_REPO is held by pid $pid at this state dir ($st)"
      else
        # ⛔ THE MEASURED DUPLICATE. A live controller for the SAME repo in a DIFFERENT state dir is
        # exactly the redundancy this registry exists to refuse, and each $O reads healthy alone.
        refuse "a controller for $SLUG_REPO is ALREADY RUNNING on this machine: pid $pid at O=$ro ($st) — one controller per repo; stop it first ($0 stop with O=$ro) or work a different repo here"
      fi
      ;;
    stale)
      ok "registry: a stale entry for $SLUG_REPO (pid $pid is gone) — 'start' reclaims it"
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
  resolve_repo_identity
  SLUG="$(registry_slug "$SLUG_REPO")" || unknown "the repo identity '$SLUG_REPO' is not usable as a registry key"
  local f; f="$(registry_file "$SLUG_REPO")" || unknown "cannot compute the registry path for $SLUG_REPO"

  registry_claim_or_refuse "$f"
  trap 'release_pending' EXIT INT TERM

  # The full verification, AFTER the claim: a refusal must leave no phantom owner, and `check` is the
  # one place the questions are asked (running them twice would create the second authority this file
  # exists to avoid).
  cmd_check >/dev/null || { local rc=$?; release_pending; return "$rc"; }

  say "==> starting $PLATFORM controller for $SLUG_REPO"
  local pid
  case "$PLATFORM" in
    cell) start_cell ;;
    mac)  start_mac ;;
  esac
  pid="$STARTED_PID"
  [ -n "$pid" ] || unknown "the controller was launched but its pid could not be read — the registry is left unclaimed so a second start is not blocked by a phantom; check: $0 status"
  registry_write "$f" "$SLUG_REPO" "$O" "$pid" running \
    || refuse "the controller is RUNNING as pid $pid but the registry record at $f could not be written — a second start for $SLUG_REPO would not be refused; fix the permissions on $(dirname "$f")"
  PENDING_FILE=""
  ok "controller RUNNING pid $pid ($PLATFORM, state dir $O)"
  say "   stop it with: $0 stop"
  return 0
}

registry_claim_or_refuse() { # <file>
  local f="${1:?}" verdict kind pid ro st
  verdict="$(registry_verdict "$f")"
  # shellcheck disable=SC2086
  set -- $verdict; kind="${1:-}"; pid="${2:-}"; ro="${3:-}"; st="${4:-}"
  case "$kind" in
    live)
      if [ "$ro" = "$O" ]; then
        # Same state dir: the platform verb's own read is the authority, and it reports "already
        # running" — but say which process, because that is the question an operator is asking.
        refuse "$SLUG_REPO is already running on this machine (pid $pid at this state dir) — use: $0 status | stop"
      fi
      refuse "a controller for $SLUG_REPO is ALREADY RUNNING on this machine: pid $pid at O=$ro ($st) — one controller per repo; stop it first"
      ;;
    stale)
      # Say which happened. A silent reclaim teaches nobody that the box had a crashed controller.
      warn "reclaiming a STALE registry entry for $SLUG_REPO (pid $pid is gone, O=$ro) — it is not blocking this start"
      ;;
    unreadable)
      unknown "the registry record $f cannot be read ($st) — it may name a live controller for $SLUG_REPO; refusing to start a possible duplicate"
      ;;
  esac
  registry_write "$f" "$SLUG_REPO" "$O" "$$" starting \
    || unknown "cannot write the registry record at $f — without it a concurrent start could not be refused; fix the permissions on $(dirname "$f")"
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
    refuse "the harness could not be pinned to $HARNESS_REF in $HARNESS_REPO (see the apply output above) — no controller was started"
  fi
  if ! bash "$SUPERVISOR" start; then
    refuse "cloud-cell-supervisor.sh start failed (see its output above) — no registry entry was recorded"
  fi
  STARTED_PID="$(await_pid roster_pid_from_status)"
  if [ -z "$STARTED_PID" ]; then
    STARTED_PID="$(lock_pid)"
  fi
  [ -n "$STARTED_PID" ] || STARTED_PID="$(local_controller_pids | head -1)"
}
# The pid, read from the platform's OWN status verb rather than re-derived here: one authority per
# question, and `status` is the verb whose answer an operator will also see.
roster_pid_from_status() {
  bash "$SUPERVISOR" status 2>/dev/null | sed -n 's/.*controller: RUNNING (pid \([0-9][0-9]*\).*/\1/p' | head -1
}

plist_path() { printf '%s\n' "$HOME/Library/LaunchAgents/$LABEL.plist"; }

start_mac() {
  [ -f "$HARNESS_BRINGUP/install.sh" ] || unknown "no install.sh at $HARNESS_BRINGUP — this machine cannot render the launchd agent"
  # install.sh renders AND validates the plist (plutil, unrendered-token check, daemon PATH probe) and
  # deliberately does not load it. Everything it needs is passed explicitly, so a value in this
  # machine's config file cannot be silently ignored by a launchd process that never sees the file.
  deploy_harness
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
  launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | sed -n 's/^[[:space:]]*pid = \([0-9][0-9]*\).*/\1/p' | head -1
}

# ── stop ──────────────────────────────────────────────────────────────────────────────────────
cmd_stop() {
  if [ -n "${REPO:-}" ] && [ -d "${REPO:-}" ]; then
    if resolve_repo_identity 2>/dev/null; then
      SLUG="$(registry_slug "$SLUG_REPO" 2>/dev/null)" || SLUG=""
    fi
  fi
  case "$PLATFORM" in
    cell)
      [ -f "$SUPERVISOR" ] || unknown "no cloud-cell-supervisor.sh at $SUPERVISOR — cannot stop a cell controller from here"
      bash "$SUPERVISOR" stop || refuse "cloud-cell-supervisor.sh stop failed (see its output above) — the controller may still be running"
      ;;
    mac)
      local plist; plist="$(plist_path)"
      if [ ! -f "$plist" ]; then
        say "not running (no agent at $plist)"
      else
        launchctl unload -w "$plist" || refuse "launchctl unload -w $plist failed — the controller may still be running"
        say "controller stopped (launchd $LABEL)"
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
  return 0
}

# ── status ────────────────────────────────────────────────────────────────────────────────────
# The one screen an operator reads. It answers, in order: what repo, which harness, is it running,
# who owns it, and — the question every other observable lies about — IS IT DISPATCHING. The
# candidate file's mtime is the read that catches the measured failure: a controller with a fresh
# heartbeat and a candidates.txt that has not moved is a controller doing nothing.
cmd_status() {
  say "platform:  $PLATFORM"
  say "repo:      ${SLUG_REPO:-<unresolved>}  @ ${REPO:-<unset>}${REPO_SRC:+  (${REPO_SRC})}"
  say "state dir: $O"
  say "config:    $ENV_FILE$([ -f "$ENV_FILE" ] && printf ' (present)' || printf ' (absent)')"
  if [ "$PLATFORM" = "cell" ]; then
    local recorded=""; [ -f "$HARNESS_PIN_FILE" ] && recorded="$(head -1 "$HARNESS_PIN_FILE" 2>/dev/null)"
    say "harness:   ${recorded:-<no pin recorded>}"
    [ -f "$O/.agent-infra-stamp.json" ] && say "stamp:     commit $(sed -n 's/.*"commit": *"\([^"]*\)".*/\1/p' "$O/.agent-infra-stamp.json" | head -1) relation $(sed -n 's/.*"relation": *"\([^"]*\)".*/\1/p' "$O/.agent-infra-stamp.json" | head -1)"
  else
    [ -f "$O/.agent-infra-stamp.json" ] && say "harness:   $(sed -n 's/.*"harness": *"\([^"]*\)".*/\1/p' "$O/.agent-infra-stamp.json" | head -1)"
  fi
  local lp live
  lp="$(lock_pid)"; live="$(local_controller_pids)"
  if [ -n "$live" ]; then
    say "controller: RUNNING  pid $(pids_join "$live")  (lock: ${lp:-none})"
  elif tmux has-session -t "${SESSION:-orch}" 2>/dev/null; then
    say "controller: RUNNING  (tmux session, no orch-loop.sh pid observed yet)"
  else
    say "controller: STOPPED"
  fi
  if [ -n "${SLUG:-}" ]; then
    local f v; f="$(registry_file "$SLUG_REPO")"; v="$(registry_verdict "$f")"
    say "registry:   $v$([ -f "$f" ] && printf '  (%s)' "$f")"
  else
    say "registry:   not consulted (repo identity unresolved)"
  fi
  if [ -f "$O/candidates.txt" ]; then
    local n mt age
    n="$(wc -l < "$O/candidates.txt" 2>/dev/null | tr -d ' ')"
    mt="$(date -r "$O/candidates.txt" -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$(stat -c %Y "$O/candidates.txt" 2>/dev/null || echo 0)" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
    age=$(( $(date +%s) - $(date -r "$O/candidates.txt" +%s 2>/dev/null || stat -c %Y "$O/candidates.txt" 2>/dev/null || date +%s) ))
    say "candidates: ${n:-0} line(s), mtime ${mt:-?} (${age}s ago)"
    # ⛔ The read that catches "alive but dispatching nothing": refresh aborts leave this file at 0
    # lines, and the controller's cycle line keeps being fresh. Reported, never auto-repaired.
    if [ "${n:-0}" -eq 0 ]; then
      warn "the candidate file is EMPTY — a running controller with an empty backlog is the measured 'alive but dispatching nothing' state; check $O/logs/orch-loop.log for a refresh abort"
    fi
  else
    say "candidates: <no file at $O/candidates.txt>"
  fi
  [ -f "$O/heartbeat" ] && say "heartbeat:  $(( $(date +%s) - $(cat "$O/heartbeat" 2>/dev/null || echo 0) ))s ago"
  return 0
}

# ── main ──────────────────────────────────────────────────────────────────────────────────────
[ "$RESEED" = 1 ] && cmd_reseed
case "$VERB" in
  check)  cmd_check ;;
  start)  cmd_start ;;
  stop)   cmd_stop ;;
  status) cmd_status ;;
esac
