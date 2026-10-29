#!/usr/bin/env bash
# multi-repo-controller.sh — launch a SECOND orchestrator controller bound to another repo.
#
# ⛔ WHY (measured 2026-10-23). The running controller is bound to ONE repo
# (`OR=daniel-ospina/tortoise`), because the harness's PR path (pr-doctor / objective / lander) only
# ever sees the repo its controller is bound to. So `agent-infra`'s ~70 open PRs received **no
# automatic dispatch at all** — every lane that worked them was started by hand. That is agent-infra
# #2281 ("a machine that runs SEVERAL repos needs one dispatch…"), still open; this is the minimal
# workaround: a second controller with its OWN state dir, so the two never share a lock, a candidate
# list or a worker registry.
#
# ⛔ A SEPARATE STATE DIR IS NOT A CONVENIENCE, AND THIS SCRIPT REFUSES TO PRETEND OTHERWISE.
# Two controllers on one `$O` fight over `.orch.lock`, `candidates.txt` and the lane registry: each
# reads the other's candidates, one blocks the other's dispatch, and every subsequent reading of the
# box is wrong about which controller owns what. Same for `HARNESS_PIN`: two controllers advancing one
# pin file rewrite each other's harness provenance mid-flight. So the four values below are REQUIRED,
# and the two ways of silently sharing the first controller's identity are refused by name:
#   * `O` equal to the primary controller's state dir          → refuse
#   * `HARNESS_PIN` equal to the primary pin, or absent        → refuse
#   * `REPO` not a git checkout, or `OR` not `owner/name`      → refuse
#   * the state dir absent                                      → refuse (with the `--init` remedy)
#
# ── USAGE ─────────────────────────────────────────────────────────────────────────────────────
#   OR=daniel-ospina/agent-infra REPO=$HOME/agent-infra-main O=$HOME/orchestrator-ai \
#     HARNESS_PIN=$HOME/orchestrator-ai/state/HARNESS-PIN multi-repo-controller.sh
#   multi-repo-controller.sh --init        create the state dir + pin ONCE, then launch
#   multi-repo-controller.sh --check       print the resolved configuration and the refusals, launch nothing
#
# Env (each has a documented default EXCEPT the four identity values, which have none on purpose):
#   OR            owner/name of the repo this controller serves        REQUIRED
#   REPO          a CURRENT checkout of it (git worktree root)         REQUIRED
#   O             this controller's state dir (≠ the primary's)        REQUIRED
#   HARNESS_PIN   this controller's own pin file (≠ the primary's)     REQUIRED
#   HARNESS_REPO  the checkout the harness refresh resolves from        default: REPO
#   O_PRIMARY     the primary controller's state dir, refused for O     default: $HOME/orchestrator
#   PIN_PRIMARY   the primary pin file, refused for HARNESS_PIN         default: $HOME/.pi/agent/state/HARNESS-PIN
#   REQ / REVIEW_GATE   the repo's required evidence gate               default: pipeline-compliance
#   MAX_LANES / MAX_LOAD / MERGE_PRIORITY_AT                            defaults: 4 / 40 / 25
#   LOOP          the controller loop to exec      default: $O/orch-loop.sh, else $HARNESS_REPO/scripts/orchestrator-harness/orch-loop.sh
#
# Exit: 0 = launched (exec'd) or --check passed · 1 = a refusal (the reason is printed and logged)
#       2 = usage error.
set -uo pipefail

usage() { sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
case "${1:-}" in -h | --help) usage ;; esac
MODE="${1:-launch}"
case "$MODE" in launch | --init | --check) ;; *) usage ;; esac

OR="${OR:-}"
REPO="${REPO:-}"
O="${O:-}"
HARNESS_PIN="${HARNESS_PIN:-}"
O_PRIMARY="${O_PRIMARY:-${HOME:?HOME is required}/orchestrator}"
PIN_PRIMARY="${PIN_PRIMARY:-${HOME:?HOME is required}/.pi/agent/state/HARNESS-PIN}"
HARNESS_REPO="${HARNESS_REPO:-$REPO}"
REQ="${REQ:-pipeline-compliance}"
REVIEW_GATE="${REVIEW_GATE:-pipeline-compliance}"
MAX_LANES="${MAX_LANES:-4}"
MAX_LOAD="${MAX_LOAD:-40}"
MERGE_PRIORITY_AT="${MERGE_PRIORITY_AT:-25}"

LOG_DIR="${O:-/tmp}/logs"
# ⛔ A REFUSAL MUST NOT CREATE WHAT IT REFUSES. The first version of this function did
# `mkdir -p "$O/logs"` and thereby brought the state dir into existence — so the very next check
# (`[ -d "$O" ]`) passed and the launcher went on to refuse for a LATER, unrelated reason. A refused
# launch leaves no trace on disk: it logs only into a state dir that ALREADY exists and is writable,
# and otherwise speaks only on stderr.
refuse() {
  printf 'multi-repo-controller: REFUSED — %s\n' "$*" >&2
  if [ -n "${O:-}" ] && [ -d "$O" ] && [ -w "$O" ]; then
    mkdir -p "$LOG_DIR" 2>/dev/null \
      && printf '%s REFUSED %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >>"$LOG_DIR/controller.log" 2>/dev/null
  fi
  exit 1
}

# ── the four identity values, each refused by NAME (never defaulted) ───────────────────────────
[ -n "$OR" ] || refuse "OR is unset — this launcher has no default repo. It exists to serve a SECOND repo; a default would silently serve the first one."
[ -n "$REPO" ] || refuse "REPO is unset — the checkout to run. Refusing to guess: a controller bound to the wrong checkout dispatches the wrong repo's work."
[ -n "$O" ] || refuse "O is unset — this controller's state dir. Refusing to default it: the default is the PRIMARY controller's dir, and two controllers on one \$O fight over .orch.lock, candidates.txt and the lane registry."
[ -n "$HARNESS_PIN" ] || refuse "HARNESS_PIN is unset — this controller's own pin file. The default pin belongs to the primary controller, and two controllers advancing one pin rewrite each other's harness provenance mid-flight."

case "$OR" in
  */*) ;;
  *) refuse "OR='$OR' is not owner/name" ;;
esac

# Compare PHYSICAL paths, not the strings: `~/orchestrator`, `/Users/x/orchestrator` and a trailing
# slash are the same state dir, and a string comparison would bless the collision this exists for.
_canon() { ( CDPATH= cd -- "$1" 2>/dev/null && pwd -P ) || printf '%s' "$1"; }
O_real="$(_canon "$O")"
O_primary_real="$(_canon "$O_PRIMARY")"
[ "$O_real" != "$O_primary_real" ] \
  || refuse "O ($O_real) IS the primary controller's state dir — a second controller there shares .orch.lock, candidates.txt and the lane registry with the first, so both dispatch into one queue and neither can tell whose work is whose. Give this repo its own dir: O=\$HOME/orchestrator-<repo>"
# ⛔ THE PIN GETS THE SAME PHYSICAL-PATH TREATMENT AS `O`. A string compare blessed
# `$HOME/.pi/agent/state/./HARNESS-PIN`, `…/state//HARNESS-PIN` and a plist rendering
# `{{AI_MULTI_REPO_STATE}}/state/HARNESS-PIN` with a doubled slash — all the PRIMARY's pin, i.e. exactly the
# silent sharing this refusal exists for.
PIN_real="$(_canon "$(dirname "$HARNESS_PIN")")/$(basename "$HARNESS_PIN")"
PIN_primary_real="$(_canon "$(dirname "$PIN_PRIMARY")")/$(basename "$PIN_PRIMARY")"
[ "$PIN_real" != "$PIN_primary_real" ] \
  || refuse "HARNESS_PIN ($HARNESS_PIN) IS the primary controller's pin — two controllers advancing one pin rewrite each other's harness provenance. Give this repo its own: HARNESS_PIN=$O/state/HARNESS-PIN"

# ── the state dir and the pin: absent is a REFUSAL, not something to conjure mid-launch ───────
if [ "$MODE" = "--init" ]; then
  mkdir -p "$O/state" "$O/logs" || refuse "cannot create $O/state"
  [ -s "$HARNESS_PIN" ] || {
    head="$(git -C "$HARNESS_REPO" rev-parse HEAD 2>/dev/null)" \
      || refuse "cannot read a commit from HARNESS_REPO=$HARNESS_REPO — is it a git checkout?"
    printf '%s\n' "$head" >"$HARNESS_PIN" || refuse "cannot write the pin at $HARNESS_PIN"
    printf 'multi-repo-controller: seeded %s with %s\n' "$HARNESS_PIN" "$head"
  }
fi
[ -d "$O" ] || refuse "state dir $O does not exist — a controller cannot start with no state dir (it would create one mid-cycle in whatever cwd it had). Create it ONCE, deliberately: O=$O $0 --init"
[ -w "$O" ] || refuse "state dir $O is not writable by $(id -un) — every cycle would fail closed"
[ -s "$HARNESS_PIN" ] || refuse "harness pin $HARNESS_PIN is absent or empty — the controller would resolve a harness commit from nothing. Create it: O=$O $0 --init"
[ -d "$REPO" ] || refuse "REPO=$REPO does not exist — a controller needs a CURRENT checkout (a stale clone silently reviews old code)"
git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 \
  || refuse "REPO=$REPO is not a git work tree"

# ── the loop: this repo's copy first, then the pinned harness's ────────────────────────────────
LOOP="${LOOP:-}"
if [ -z "$LOOP" ]; then
  for _c in "$O/orch-loop.sh" "$HARNESS_REPO/scripts/orchestrator-harness/orch-loop.sh"; do
    [ -f "$_c" ] && { LOOP="$_c"; break; }
  done
fi
[ -n "$LOOP" ] && [ -f "$LOOP" ] \
  || refuse "no orch-loop.sh found (looked at \$LOOP, $O/orch-loop.sh, $HARNESS_REPO/scripts/orchestrator-harness/orch-loop.sh) — nothing to run"

if [ "$MODE" = "--check" ]; then
  printf 'multi-repo-controller: OK\n'
  printf '  O=%s\n  REPO=%s\n  OR=%s\n  HARNESS_REPO=%s\n  HARNESS_PIN=%s (%s)\n  LOOP=%s\n  gate=%s\n  MAX_LANES=%s MAX_LOAD=%s\n' \
    "$O" "$REPO" "$OR" "$HARNESS_REPO" "$HARNESS_PIN" "$(head -1 "$HARNESS_PIN")" "$LOOP" "$REVIEW_GATE" "$MAX_LANES" "$MAX_LOAD"
  exit 0
fi

mkdir -p "$O/state" "$O/logs" || refuse "cannot create $O/state"
printf '[multi-repo-controller] %s O=%s REPO=%s OR=%s MAX_LANES=%s LOOP=%s\n' \
  "$(date -u +%FT%TZ)" "$O" "$REPO" "$OR" "$MAX_LANES" "$LOOP" >>"$O/logs/controller.log"

# Everything the loop reads is EXPORTED, because exec'd children inherit this environment and nothing
# here re-sources a shell rc file (that is the whole point of a scheduled launcher).
export O REPO OR HARNESS_REPO HARNESS_PIN REQ REVIEW_GATE MAX_LANES MAX_LOAD MERGE_PRIORITY_AT
export PATH="${PATH:-/usr/local/bin:/usr/bin:/bin}:/opt/homebrew/bin:/usr/local/bin"
exec bash "$LOOP"
