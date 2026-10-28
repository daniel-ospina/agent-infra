#!/usr/bin/env bash
# harness-refresh.sh — once per cycle, keep this box's harness PIN truthful with origin/main.
#
#   ./harness-refresh.sh [--no-fetch] [--quiet] [--repo <path>] [--ref <git-ref>] [--pin <file>]
#                        [--self <harness-dir>] [--no-adopt] [--re-seed] [--force]
#   ./harness-refresh.sh --print-restart     # what became of the last restart request (no git, no net)
#
# Exit (one verdict per run; a refusal is never a success):
#    0  current          pin already names the ref tip (no-op)
#   10  repinned         the materialiser ran and its result is recorded: `action=repinned` when the pin
#                        advanced old -> new sha, `action=reseeded` when `--re-seed` re-seeded $O from a
#                        pin that ALREADY named the tip (nothing moved, so the record must not claim it did)
#   11  mended           the pin was missing/empty/not-a-commit; recorded what this box runs
#   20  REFUSED dirty    the harness surface has uncommitted changes — nothing was touched
#   21  REFUSED ahead    local commits are not on the ref's line — nothing was touched
#   22  REFUSED diverged the running commit is neither ancestor nor descendant
#   23  REFUSED unknown  the ref/repo/running commit cannot be resolved (cannot-verify is not a pass),
#                        or the materialiser failed — the pin was NOT written and nothing was re-seeded
#   25  behind           on the ref's line but older, and this box has NO materialiser to advance it
#   26  REFUSED blocked  the advance asked for (--re-seed) would change the code UNDER a running
#                        controller/lane — nothing was touched; the non-destructive advance is the
#                        default, and `--force` is the deliberate override
#
# Plus ONE relation that is not a verdict about freshness at all:
#   restart-pending  the PIN names the ref tip and the running controller still executes an older tree.
#                    Reported (exit 0, nothing re-deployed): the pin advances the NEXT launch, and calling
#                    it `current` would be a false PASS about code that is not running yet.
#
# ── `restart-pending` IS A STATE WITH A TRANSITION (agent-infra#2641), NOT A WORD PRINTED ──────────
# MEASURED 2026-10-26: on every cell the relation was `restart-pending` on EVERY cycle for ever, because
# the running identity could not be read at all on a cell (whose $O is a flat seed with no git
# identity) — so the token rode on every spawn line and carried no information. And when it was TRUE
# the only way to act was a hand `systemctl restart`, which (a) kills in-flight lanes, (b) left `pi`,
# `bash`, `python3` and a `tmux: server` running after the unit stopped, and (c) then refused to start
# again (`StartLimitBurst=3`). Every harness change that night needed one. The orphan/restart half is
# agent-infra#2315's, NOT this file's.
# So the word is replaced by a STATE with a defined transition, in three parts:
#   1. THE IDENTITY IS READ FROM THE PROCESS, NOT FROM A RECORD, where a cell is concerned — the live
#      controller's argv names the tree it executes (see `controller_identity` below). That makes
#      `current` reachable on a cell, which is the only thing that can ever END the state honestly.
#   2. THE PENDING STATE IS CLASSIFIED, and the classification rides in the record as `pending=`:
#        inert       no live controller — nothing runs, so nothing is stale; the next launch runs the pin.
#        unprovable  a controller IS live and its identity is a CLAIM (the stamp) — no restart is
#                    requested, because we cannot say one is needed.
#        deferred    a restart IS needed and something would be interrupted — a REQUEST is recorded,
#                    naming the population that blocks it, and nothing is applied.
#        safe        a restart IS needed and every population this box can measure is EMPTY — a REQUEST
#                    is recorded with `actuation=safe`.
#   3. THE TRANSITION IS RECORDED AND OBSERVABLE. A request carries `requested_at`/`requested_by`, and
#      the next cycle that sees the process move records `request=honoured … after=<n>s`; a request whose
#      premise disappears records `request=cleared`. Read it with `--print-restart`, or in
#      `cloud-cell-supervisor.sh status`. ⛔ THIS SCRIPT CONTAINS NO ACTUATOR, DELIBERATELY: a loop that
#      restarts itself is the one path that cannot be made safe, and the fleet already has THREE restart
#      paths (`systemctl restart`, `cloud-cell-supervisor.sh stop/apply/start`, merge-reminder.py's
#      deploy arm). A fourth is the duplication the owner ruled against; this one ASKS and RECORDS.
#
# ── WHY THIS EXISTS (agent-infra#2215) ───────────────────────────────────────────────────────────
# MEASURED 2026-10-20: three cells sat on a checkout 27 commits behind origin/main with an EMPTY
# harness pin, so fixes that had landed hours earlier were running nowhere. Nothing fetched. Nothing
# compared. The pin — the one artifact that answers "which harness is this box on?" — was empty, and
# an empty pin was indistinguishable from a current one because no reader ever refused it.
# ── WHAT IT DOES NOT DO, AND WHY (each one is a recorded decision, not an omission) ───────────────
# ⛔ IT DOES NOT FAST-FORWARD THE TREE IT IS RUNNING FROM. The obvious reading of
# "fast-forward the controller's tree" is the one this repo already rejected twice:
#   • cloud-cell-supervisor.sh's header: "The mend is a detached `git worktree add` ON PURPOSE:
#     `git checkout <branch>` and `git reset --hard` are BLOCKED inside the cell's main checkout";
#     (quoted verbatim from that file — it is the decision being honoured here, and its own reader
#     will find it by search rather than trusting this paraphrase)
#   • `harness_apply`'s own note: creating the new pin BEFORE removing the old one is what stops an
#     ENOSPC window (agent-infra#1805) from leaving the cell with NO harness at all;
#   • the seeding contract (`seed_and_stamp`): a live script must be replaced ATOMICALLY (temp-file +
#     `mv`), because a `cp` truncates the file a spawn is about to execute.
# A mid-flight in-place checkout of the tree a running controller is executing is the same hazard one
# level up, and no atomic rename can fix it. So the ADVANCE is: materialise the new commit through the
# box's existing materialiser (`cloud-cell-supervisor.sh apply --pin-only`, which creates the
# per-commit worktree and leaves $O alone), and only then write the pin. `--pin-only` matters: re-seeding
# $O here would swap the helpers this loop calls while the loop itself is the OLD `orch-loop.sh`, and
# the next `start` seeds $O from the new pin instead. This script never deletes, never checks out, and
# never writes a pin for a tree that does not exist.
# ⛔ A PIN ADVANCE KILLS NOTHING, AND THAT IS WHY IT MAY RUN WHILE LANES ARE MID-TURN. Pin-per-commit
# means the advance is a NEW worktree plus an atomic pin write: a running lane keeps executing the tree
# and commit it started with, and the only thing deferred is the RESTART (the `restart-pending` relation
# below). MEASURED while writing this on a live cell: two lanes were minutes into a turn
# (`$O/run-fix-9508.sh -> fix-one.sh`, `…-9512`), which is exactly the state that made every operator
# skip the refresh — the fear being that a refresh replaces the merge queue with a fresh pin. So this
# script enumerates what is in flight and DISCLOSES it (`lanes=` in the record), it never signals any of
# it, and the only advance that COULD disturb it — `--re-seed`, the `apply` that swaps $O under a live
# loop — refuses by default (exit 26) and needs an explicit `--force`. `--force` changes nothing else:
# it never overrides a dirty/ahead/diverged refusal, and it never turns the current-pin no-op into work.
# ⛔ THE MATERIALISER IS AUTO-RESOLVED ONLY FOR A PIN-PER-COMMIT CELL, NEVER FROM AN AMBIENT SCRIPT.
# The launcher exports HARNESS_MATERIALISER (cloud-cell-supervisor.sh, the `start` path); a controller
# started BY HAND does not inherit it, and that is not a corner case — it is the measured state of all
# three cells (2026-10-21: `HARNESS_PIN_DIR`/`HARNESS_PIN_FILE`/`CELL_HOME` in the controller's env, no
# HARNESS_MATERIALISER), where every cycle therefore exited 25 `unmaterialised` and the pin could never
# advance, no matter who ran it. Those two variables are what a cell IS (install.sh on a laptop sets
# neither), so their presence — not the existence of a supervisor script in some checkout — is the
# posture that licenses `$REPO/scripts/cloud-cell-supervisor.sh`. The record's prose names that the
# materialiser was auto-resolved rather than configured.
# ⛔ IT IS NOT A SECOND SEEDER AND NOT A SECOND STAMP WRITER. `seed_and_stamp` (cell) and
# `install.sh`'s provenance block (laptop) own those artifacts, and `check-deployed-drift.sh` reads the
# stamp they write. Forking either format here is the divergence #2160 exists to end, so adoption is
# DELEGATED to the materialiser (`HARNESS_MATERIALISER`, set by cloud-cell-supervisor.sh when it
# launches the controller) and this script only records the result.
# ⛔ NO COMMIT COUNTS, EVER. Hash equality or `merge-base --is-ancestor` only — measured 2026-10-14,
# `rev-list --count e8d5ce29..origin/main` printed 1 while `--is-ancestor` printed NO (a tree off the
# line reads as "1 behind"), and the count MOVES as main advances without the tree changing.
#
# ── THE FOUR RELATIONS, AND WHY `dirty` AND `ahead` ARE REFUSALS ──────────────────────────────────
# The same class the supervisor's provenance block defines (current/behind/diverged/untracked/unknown)
# plus the two states this job must NAME rather than swallow:
#   dirty   the harness surface ($HARNESS_DIRTY_SCOPE, default scripts/orchestrator-harness) carries
#           uncommitted changes. MEASURED: a live-tested patch existed only as a working-tree edit and
#           was lost to the next pull. Adopting over it would run the commit INSTEAD of that patch —
#           the fleet would silently stop running the fix an operator had just proved. Refuse; name
#           the files.
#   ahead   the running commit carries work not on the ref's line (a hand-cherry-pick, a local commit).
#           Advancing would drop it. Refuse; name the sha.
# Both mutate NOTHING, so the refusal is always recoverable by the operator who owns the edit.
#
# WHAT A CALLER SHOULD DO WITH 25: it is truth, not a failure. This box is on the ref's line but older
# and has no materialiser (a laptop whose $O is operator-synced by install.sh — deliberately non-copying,
# see its own comment). The caller must put it on the spawn line, not swallow it.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUIET=0; FETCH=1; ADOPT=1; RESEED=0; FORCE=0; PRINT_RESTART=0
# ⛔ DEFINED BEFORE ANY `refuse`, because a refusal that happens before the fetch decision (no repo, no
# ref tip) still prints a record — and `${FETCH_STATE:-ok}` in `record()` would then stamp `fetch=ok` on it,
# i.e. the one field that means "this comparison was fresh" would be asserted by a run that never compared.
FETCH_STATE="notfetched"
# The disclosure half of the lane contract (see the header): `unknown` until something actually counted
# what is in flight, so a record can never claim `lanes=0` from a run that never looked.
LANES_DISC="unknown"
# Why `restart-pending` is pending, when it is (#2641). `none` for every other relation; the record
# always carries the field so a reader never has to infer it from the prose.
PENDING="none"
REPO=""; REF=""; PIN=""; SELF="$HERE"
DEFAULT_REF="${HARNESS_REF:-origin/main}"
# The surface whose uncommitted edits block adoption. Scoped DELIBERATELY: an unrelated WIP file
# elsewhere in a shared checkout must not false-block a deployment (the #1140 class — a warning that
# always fires is not a warning), while a hand-edit to the harness itself is exactly what must block.
DIRTY_SCOPE="${HARNESS_DIRTY_SCOPE:-scripts/orchestrator-harness}"

while [ $# -gt 0 ]; do
  case "$1" in
    --no-fetch) FETCH=0; shift ;;
    --no-adopt) ADOPT=0; shift ;;
    # ⛔ THE DESTRUCTIVE FORM IS OPT-IN, AND IT IS THE ONLY THING `--force` OVERRIDES. A re-seed swaps
    # the helper scripts under a RUNNING loop (`apply` without `--pin-only`), which is a version skew no
    # other path in this repo produces and would change the code under a lane that is mid-turn.
    --re-seed)  RESEED=1; shift ;;
    --force)    FORCE=1; shift ;;
    --quiet)    QUIET=1; shift ;;
    --repo)     [ $# -ge 2 ] || { echo "harness-refresh: --repo needs a path" >&2; exit 23; }
                REPO="$2"; shift 2 ;;
    --ref)      [ $# -ge 2 ] || { echo "harness-refresh: --ref needs a git ref" >&2; exit 23; }
                REF="$2"; shift 2 ;;
    --pin)      [ $# -ge 2 ] || { echo "harness-refresh: --pin needs a path" >&2; exit 23; }
                PIN="$2"; shift 2 ;;
    --self)     [ $# -ge 2 ] || { echo "harness-refresh: --self needs a path" >&2; exit 23; }
                SELF="$2"; shift 2 ;;
    --print-restart) PRINT_RESTART=1; shift ;;
    -h|--help)  awk 'NR>1 && /^set -u$/{exit} NR>1{print}' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)          echo "harness-refresh: unknown argument: $1" >&2; exit 23 ;;
  esac
done
[ -n "$REF" ] || REF="$DEFAULT_REF"
# `$HOME/.pi/agent/state/HARNESS-PIN` is the sha record THIS script writes and `cloud-cell-supervisor.sh
# status` reads — one spelling, one file. ⛔ `CELL_HOME` FIRST, and `$HOME` only as the fallback: the
# controller's `HOME` IS the cell home, but an OPERATOR running this by hand from a login shell on the
# same host has HOME = their account, so a bare `$HOME` mend wrote a file nothing reads, printed
# "pin MENDED", exited 11, and `status` still showed an empty pin — a false PASS on the mend itself.
# (The pin the OTHER tools consume is `HARNESS_PIN_FILE`, a path to the materialised tree; different
# record, and neither is a fallback for the other.)
[ -n "$PIN" ] || PIN="${HARNESS_PIN:-${CELL_HOME:-${HOME:-}}/.pi/agent/state/HARNESS-PIN}"

log_line() { [ "$QUIET" -eq 1 ] || echo "$@"; }
# ── `--print-restart`: THE READER FOR THE TRANSITION (#2641) ─────────────────────────────────────
# It needs no git, no network and no repo, so it works on a box whose checkout is broken — which is
# exactly when an operator asks "did my restart get honoured?". It PRINTS THE RECORD VERBATIM; deriving
# a verdict here would create a second opinion about a state this script already decided once.
# ⛔ AN ABSENT RECORD IS NOT `none`: nothing has ever recorded a request, which is a different fact
# from "nothing is pending" — the same absence-vs-empty rule the whole file follows.
if [ "$PRINT_RESTART" = 1 ]; then
  if [ -z "${O:-}" ]; then
    printf 'restart request=unknown reason=no-O-set\n'; exit 0
  fi
  if [ -f "$O/state/restart-request" ]; then cat "$O/state/restart-request"
  else printf 'restart request=none reason=no-cycle-has-recorded-one\n'; fi
  exit 0
fi
# ── bounded execution, because this runs at the top of the controller's cycle ──────────────────────
# ⛔ `timeout` IS GNU COREUTILS AND macOS SHIPS IT NOWHERE (`gtimeout` only with Homebrew coreutils), so a
# bare `timeout` call is rc=127 on the Mac half of the fleet — which the `if !` below would read as a
# FAILED FETCH, i.e. it would never fetch at all and would warn on every single cycle. That is the exact
# defect this script exists to remove, re-created by its own fix. THREE ARMS, resolved in the same order as
# `scripts/lib/bounded.sh` (`timeout` -> `gtimeout` -> an in-shell watchdog), which every long-lived `$O`
# script has to carry itself because that library is not seeded into `$O`.
# HARNESS_TIMEOUT_BIN pins the FIRST arm (a test drives the fallback with it); an unusable pin falls through
# to `gtimeout`, then the watchdog — it never runs the command unbounded.
HARNESS_FETCH_TIMEOUT_DEFAULT=20
# The FIRST arm, defaulted (not `${…-}` at the use site): an unset name here aborts the whole script under
# `set -u` on every fetch — the same class of bug this function exists to prevent, one level up.
HARNESS_TIMEOUT_BIN="${HARNESS_TIMEOUT_BIN-timeout}"
bounded_fetch() { # <secs> <cmd...>; the command's own status, 124/137/143 when the bound fired
  local s="$1"; shift
  local p w rc bin=""
  # `0` (or anything unparseable) is NOT "no bound": `timeout 0` runs with no timeout at all, and the
  # watchdog arm would kill instantly — two different meanings for one value is how a typo becomes either a
  # hang or a dead fetch. A non-positive/unparseable value takes the default, so the bound always exists.
  case "$s" in ''|*[!0-9]*) s="$HARNESS_FETCH_TIMEOUT_DEFAULT" ;; esac
  [ "$s" -gt 0 ] 2>/dev/null || s="$HARNESS_FETCH_TIMEOUT_DEFAULT"
  for _c in "$HARNESS_TIMEOUT_BIN" gtimeout; do
    [ -n "$_c" ] || continue
    command -v "$_c" >/dev/null 2>&1 && { bin="$_c"; break; }
  done
  if [ -n "$bin" ]; then "$bin" -k 5 "$s" "$@"; return $?; fi
  # Both streams go to /dev/null INSIDE the child: a killed fetch can leave a grandchild behind, and any
  # inherited descriptor of the caller's pipe would hold it open for the hang's full length.
  "$@" >/dev/null 2>&1 &
  p=$!
  ( sleep "$s"; kill -TERM "$p" 2>/dev/null; sleep 1; kill -KILL "$p" 2>/dev/null ) >/dev/null 2>&1 &
  w=$!
  wait "$p"; rc=$?
  kill -TERM "$w" 2>/dev/null || true; kill -KILL "$w" 2>/dev/null || true
  return "$rc"
}
# The machine-readable half. EVERY verdict prints exactly one of these FIRST, so a caller (the
# controller's per-cycle block) parses a record instead of the prose below it.
# `pending=` is additive and always present (#2641): a reader that ignores it sees the old record.
record() { printf 'harness relation=%s running=%s ref=%s pin=%s action=%s fetch=%s lanes=%s pending=%s\n' \
  "$1" "${2:-unknown}" "${3:-unknown}" "${4:-none}" "${5:-none}" "${FETCH_STATE:-ok}" "${LANES_DISC:-unknown}" "${PENDING:-none}"; }
short() { [ -n "${1:-}" ] && printf '%s' "$1" | cut -c1-12; }
refuse() { # <relation> <exit> <running> <pin> <prose…>
  local rel="$1" rc="$2" run="$3" pn="$4"; shift 4
  record "$rel" "$run" "$(short "${TIP:-}")" "$pn" refused
  echo "REFUSE $rel: $*" >&2
  log_line "REFUSE $rel: $*"
  exit "$rc"
}

command -v git >/dev/null 2>&1 || refuse unknown 23 "${RUNNING:-unknown}" none "git is not on PATH"

# ── resolve the checkout that carries the ref ────────────────────────────────────────────────────
# ⛔ THE MAIN WORKTREE, never `--show-toplevel`. A pinned harness IS a linked worktree, so deriving the
# repo from it makes the pin its own repo — `harness_apply` would then operate on (and could remove)
# the tree it is running from. Same expression as cloud-cell-supervisor.sh and install.sh.
main_worktree() {
  git -C "$1" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print substr($0,10); exit}'
}
if [ -z "$REPO" ]; then
  for cand in "${HARNESS_REPO:-}" "$(dirname "${HARNESS_MATERIALISER:-/nonexistent}")/.." \
              "$SELF" "${O:-}"; do
    [ -n "$cand" ] && [ -d "$cand" ] || continue
    cand="$(main_worktree "$cand")"
    [ -n "$cand" ] && { REPO="$cand"; break; }
  done
fi
# The laptop's deployed $O is NOT a checkout at all (install.sh's own measured case), so identity can
# only come from the record install.sh/stamp_write leaves beside it.
STAMP="${O:-}/.agent-infra-stamp.json"
stamp_field() {
  [ -f "$STAMP" ] || return 0
  sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$STAMP" | head -1
}
if [ -z "$REPO" ]; then
  _sd="$(stamp_field harness)"
  [ -n "$_sd" ] && [ -d "$_sd" ] && REPO="$(main_worktree "$_sd")"
fi
[ -n "$REPO" ] && [ -d "$REPO" ] || refuse unknown 23 "${RUNNING:-unknown}" none \
  "no checkout carrying $REF resolved (tried \$HARNESS_REPO, the materialiser's checkout, $SELF, \$O, and the stamp) — set HARNESS_REPO"
git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 \
  || refuse unknown 23 "${RUNNING:-unknown}" none "$REPO is not a git checkout"

# ── THE CONTROLLER'S LOCK: liveness AND identity, read ONCE, before the RUNNING commit ────────
# ⛔ IT MOVED ABOVE THE RUNNING READ (#2641) because the same pid now answers TWO questions: is a
# controller live (the discriminator that stops the stamp certifying a running process), and WHICH TREE
# is it executing (the third RUNNING source). Two reads of one record can disagree with themselves; one
# cannot.
# ⛔ THE STAMP IS NOT EVIDENCE OF WHAT IS RUNNING, AND A LIVE CONTROLLER IS THE DISCRIMINATOR.
# `apply --force` is allowed under a live controller and runs `seed_and_stamp`, so the next cycle sees the
# stamp naming the NEW commit while the process still executes the old `orch-loop.sh` — `current`, empty
# token, and no spawn line discloses it. The controller's own lock answers what the stamp cannot: is
# anything running? With no live controller nothing executes and the stamp is the honest answer (laptop).
CONTROLLER_PID=""; CONTROLLER_LIVE=0; CTRL_TREE=""; CTRL_HEAD=""
if [ -n "${O:-}" ] && [ -f "$O/.orch.lock" ]; then
  CONTROLLER_PID="$(head -1 "$O/.orch.lock" 2>/dev/null | tr -dc '0-9')"
  if [ -n "$CONTROLLER_PID" ] && kill -0 "$CONTROLLER_PID" 2>/dev/null; then CONTROLLER_LIVE=1; fi
fi

# ── RUNNING, source 3: the CONTROLLER's OWN ARGV (agent-infra#2641) ─────────────────────────────
# `self:` resolves on a laptop ($O is a checkout) and NEVER on a cell, whose $O is a flat seed with no
# git identity. On a cell the only source left was the STAMP — a claim `apply` wrote, not a fact about
# the running process — so the `stamp:*` arm downgraded `current` to `restart-pending` on EVERY cycle of
# EVERY cell, for ever. MEASURED 2026-10-24 on pi-cell-3: running == pin == ref == 848ba4b1 and the
# record still said `restart-pending`, while `cloud-cell-supervisor.sh status` printed `[current]` for the
# same box two lines away. An always-on token is a token nobody reads.
# The truthful answer needs NO new artifact and NO new knob: the live controller's argv names the tree it
# executes, and its lock names the pid — the primitive `check-deployed-drift.sh` already uses. Every
# bound below REFUSES rather than guesses, because the failure that matters here is a false `current`:
# a box certified as executing code it is not. (Each bound has a driven case: A36, A36b, A36c, A36d.)
#   • ONE pid from $O/.orch.lock — never a scan for `orch-loop.sh`. #1745 measured up to four such trees
#     on one cell, and a scan picks the wrong one silently (the issue's rejected arm D).
#   • the shape is `<shell> <path>` with basename `orch-loop.sh` — an INVOCATION, not a mention, so a
#     `tail -f`, `sed -n …p` or `diff` of the path cannot answer. The rule this repo settled twice
#     (cloud-cell-supervisor.sh's `_controller_ps_awk`, check-deployed-drift.sh).
#   • an ABSOLUTE operand only: a relative one resolves against the CONTROLLER's cwd, which is not
#     readable here, and resolving it against OURS is the wrong-tree defect `box-status.sh` fixed.
#   • the harness dir must be THIS tree's `scripts/orchestrator-harness` (its OWN toplevel), so a tree
#     whose `.git` was removed cannot ascend into an enclosing worktree and report THAT head.
#   • the tree must sit under a RECORDED root — `HARNESS_PIN_FILE`'s tree, `HARNESS_PIN_DIR` itself
#     (the legacy flat pin) or exactly one per-commit child of it. A peer repo's controller answers
#     nothing about this box.
#   • anything unreadable falls through to the stamp: fail closed, never a new `current`.
pin_root_member() { # <tree>; 0 only when a pin record on THIS box can name that tree
  local t="$1" want r rest
  if [ -n "${HARNESS_PIN_FILE:-}" ] && [ -f "$HARNESS_PIN_FILE" ]; then
    want="$(head -1 "$HARNESS_PIN_FILE" 2>/dev/null)"
    if [ -n "$want" ] && [ -d "$want" ]; then
      want="$(cd "$want" 2>/dev/null && pwd -P)" || want=""
      case "$want" in */scripts/orchestrator-harness) want="${want%/scripts/orchestrator-harness}" ;; esac
      if [ -n "$want" ] && [ "$t" = "$want" ]; then return 0; fi
    fi
  fi
  if [ -n "${HARNESS_PIN_DIR:-}" ] && [ -d "${HARNESS_PIN_DIR}/" ]; then
    r="$(cd "$HARNESS_PIN_DIR" 2>/dev/null && pwd -P)" || r=""
    if [ -n "$r" ]; then
      [ "$t" = "$r" ] && return 0                        # the legacy flat pin: the ROOT is the worktree
      case "$t" in
        "$r"/*) rest="${t#"$r"/}"
                case "$rest" in */*) return 1 ;; esac     # exactly one level: the per-commit child
                return 0 ;;
      esac
    fi
  fi
  return 1
}
controller_identity() { # sets CTRL_HEAD/CTRL_TREE from the LIVE controller. rc 1 = no answer.
  # ⛔ IT ASSIGNS RATHER THAN ECHOING, for the same reason `set_pending` does: `$(controller_identity)`
  # runs in a subshell, so CTRL_TREE was set in a process that then exited and every record printed
  # `from controller:pid=…@` with an EMPTY tree — a record naming the source but not the tree (measured).
  local pid cmd dir top head
  [ "$CONTROLLER_LIVE" = 1 ] || return 1
  pid="$CONTROLLER_PID"
  cmd="$("${PS_BIN:-ps}" -p "$pid" -o command= 2>/dev/null)" || return 1
  [ -n "$cmd" ] || return 1
  # shellcheck disable=SC2086  # word-splitting is the point: argv elements ARE the argument
  set -- $cmd
  [ "$#" -ge 2 ] || return 1
  case "${1##*/}" in bash|sh|dash|zsh) ;; *) return 1 ;; esac
  case "$2" in /*) ;; *) return 1 ;; esac
  [ "${2##*/}" = orch-loop.sh ] || return 1
  dir="$(cd "$(dirname "$2")" 2>/dev/null && pwd -P)" || return 1
  [ -n "$dir" ] || return 1
  top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || return 1
  [ -n "$top" ] || return 1
  top="$(cd "$top" 2>/dev/null && pwd -P)" || return 1
  [ "$dir" = "$top/scripts/orchestrator-harness" ] || return 1
  pin_root_member "$top" || return 1
  head="$(git -C "$top" rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null)" || return 1
  [ -n "$head" ] || return 1
  CTRL_TREE="$top"; CTRL_HEAD="$head"
  return 0
}

# ── the two facts: what this box DEPLOYS, and what it is currently RUNNING ──────────────────────
# ⛔ THEY ARE NOT THE SAME FACT, AND CONFLATING THEM IS WHAT MAKES A REFRESH STORM. This deployment is
# PIN-PER-COMMIT: adopting a new commit creates a NEW worktree and leaves the running controller's own
# tree untouched (see the header — an in-place checkout of a live tree is the hazard this design
# refuses). So after a re-pin, the tree this script sits in is LEGITIMATELY still the old commit until
# the controller restarts. Classifying on the running tree alone would therefore re-adopt the same
# commit EVERY cycle, forever.
#
#   DEPLOYED  = the commit the pin names (the tree `apply` left behind, else the sha record). This is
#               what "which harness is this box on?" means for a pin-per-commit deployment, and it is
#               the basis the relation is computed from.
#   RUNNING   = the commit the controller process actually executes. Disclosed, never compared: a
#               difference is `restart-pending`, not a reason to redeploy what is already deployed.
RUNNING="$(git -C "$SELF" rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null)"
RUNNING_FROM="self:$SELF"
if [ -z "$RUNNING" ]; then
  # ── source 3, the controller's own argv (#2641) — see `controller_identity` above for its bounds.
  # It sits BETWEEN `self:` and `stamp:` on purpose: `self:` is still the strongest evidence where it
  # resolves, and a claim written to disk is still the weakest.
  if controller_identity; then
    RUNNING="$CTRL_HEAD"
    RUNNING_FROM="controller:pid=$CONTROLLER_PID@$CTRL_TREE"
  else
    RUNNING="$(stamp_field commit)"
    RUNNING_FROM="stamp:$STAMP"
    case "${RUNNING:-}" in ''|UNKNOWN) RUNNING="" ;; esac
  fi
fi
PIN_SHA=""
if [ -f "$PIN" ]; then
  PIN_SHA="$(head -1 "$PIN" 2>/dev/null | tr -d '[:space:]')"
  # A pin that is not a commit is NOT a pin. `--verify --quiet` is the test: a bare `rev-parse <junk>`
  # ECHOES its argument to stdout while failing, so a plain capture reads junk as a resolved commit.
  [ -n "$PIN_SHA" ] && [ "$(git -C "$REPO" rev-parse --verify --quiet "${PIN_SHA}^{commit}" 2>/dev/null)" ] \
    || PIN_SHA=""
fi
# The PATH pin is the stronger evidence where it exists (a cell): it names the actual tree `apply`
# created, so its HEAD is what is deployed even when the sha record is stale or was never written.
# ⛔ NO DEFAULT FOR $HARNESS_PIN_FILE, deliberately: defaulting it to `$HOME/.harness-path` would make
# this script read a file it was never configured with on any box that happens to have one.
DEPLOYED=""; DEPLOYED_FROM=""
if [ -n "${HARNESS_PIN_FILE:-}" ] && [ -f "$HARNESS_PIN_FILE" ]; then
  _pd="$(head -1 "$HARNESS_PIN_FILE" 2>/dev/null)"
  if [ -n "$_pd" ] && [ -d "$_pd" ]; then
    DEPLOYED="$(git -C "$_pd" rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null)"
    [ -n "$DEPLOYED" ] && DEPLOYED_FROM="pin-tree:$_pd"
  fi
fi
if [ -z "$DEPLOYED" ]; then
  DEPLOYED="$PIN_SHA"; DEPLOYED_FROM="pin-record:$PIN"
fi
if [ -z "$DEPLOYED" ]; then
  DEPLOYED="$RUNNING"; DEPLOYED_FROM="$RUNNING_FROM (no pin recorded)"
fi

# ── what is IN FLIGHT, so the advance can be PROVEN not to touch it ─────────────────────────────────
# A lane is a process this cell's controller spawned and is still running: it executes a script in $O
# (the seeded runtime dir), so one of its argv tokens is exactly `$O/<name>.sh`. MEASURED on the live
# cell this was written on: `run-fix-9508.sh -> fix-one.sh --argv state/argv-9508` and `…-9512`, both
# minutes into a turn — the state every operator was afraid to refresh under.
# ⛔ NOTHING HERE IS EVER SIGNALLED, and this script gains no kill: the advance is a NEW per-commit
# worktree (see the header), so a lane keeps the tree it started with. The list exists to (a) put
# `lanes=N` in the record, so "the restart is deferred, N lanes keep their code" is readable, and
# (b) let the ONE destructive form (`--re-seed`) refuse instead of swapping $O under a lane mid-turn.
# ⛔ MATCH THE TOKEN, NOT A SUBSTRING OF THE LINE: the tmux launcher's own argv names
# `$O/logs/orch-loop.log`, and a substring match counts it as a lane on every cycle. The controller and
# this script are excluded by name because both live in $O when it is seeded.
in_flight_pids() {
  local t
  t="$(ps -eo pid=,ppid=,command= 2>/dev/null)" || return 1
  case "$t" in *[![:space:]]*) ;; *) return 1 ;; esac
  printf '%s\n' "$t" | awk -v o="$O/" -v me="$$" '
    {
      if ($1 == me) next
      for (i = 3; i <= NF; i++) {
        f = $i
        if (index(f, o) != 1) continue
        n = substr(f, length(o) + 1)
        if (index(n, "/") != 0) continue      # a subdirectory ($O/logs/…) is not a lane script
        if (n !~ /\.sh$/) continue
        if (n == "orch-loop.sh" || n == "harness-refresh.sh") continue
        print $1; next
      }
    }'
}
LANE_N=0
LANE_LIST=""
_lane_short() { printf '%s' "$LANE_LIST" | awk 'NF{printf "%s%s", (n++?" ":""), $0}'; }
if [ -n "${O:-}" ]; then
  if _lanes="$(in_flight_pids)"; then
    LANE_LIST="$_lanes"
    LANE_N="$(printf '%s\n' "$_lanes" | awk 'NF' | wc -l | tr -d ' ')"
    case "$LANE_N" in ''|*[!0-9]*) LANE_N=0 ;; esac
    LANES_DISC="$LANE_N"
  else
    # Cannot-verify is never a pass: an unreadable process table must not be recorded as "no lanes".
    LANES_DISC="unknown"
  fi
fi

# ── THE IN-FLIGHT GATE: what a RESTART would interrupt (#2641) ────────────────────────────────
# ⛔ WHY THREE POPULATIONS AND NOT ONE. A controller restart kills everything the box started, and
# each of these readers is blind to something the others see:
#   argv   `$O/<name>.sh` lane wrappers (`lane.sh`, `fix-one.sh`, `merge-one.sh`) — the existing read.
#   roles  `$O/state/roles/.*.lock` with a LIVE owner pid — the reap/merge/hygiene passes
#          merge-reminder.py already refuses to restart under.
#   tree   live DESCENDANTS of the controller pid — the population that actually answers "what would a
#          restart kill", and the only one that can contain a `pi -p --no-session` lane child.
# ⛔ THE POPULATION TRAP, NAMED RATHER THAN PAPERED OVER. An orchestrator lane runs
# `pi -p --no-session`: no session file, no worker-* record, so every session-store reader in the fleet
# is blind to it (measured: processes alive 69 h, invisible to every liveness reader). `argv` alone
# therefore CANNOT prove idleness — which is why `tree` is consulted, and why `argv` alone is never
# accepted as `safe`. THE DECLARED BLIND SPOT, which NONE of the three covers: a lane process that was
# reparented away from the controller AND runs no `$O/*.sh` (its wrapper died, the child kept working).
# It is not silently omitted — the request record carries `checked=argv,roles,tree` and
# `blind=reparented-no-wrapper`, so an actuator reads the EDGE of what was measured instead of reading
# `safe` as a guarantee. Unreadable in ANY population is `unknown`, and unknown is BLOCKED: the direction
# that costs a wait is always preferred to the one that costs a lane's turn.
role_pids() { # live role-lock owners on stdout; rc 1 when the population exists but cannot be read
  local d own pid out=""
  [ -n "${O:-}" ] || return 1
  [ -d "$O/state/roles" ] || { printf '\n'; return 0; }   # never created = never taken: EMPTY, not unknown
  for d in "$O/state/roles"/.*.lock; do
    [ -d "$d" ] || continue
    own="$(cat "$d/own" 2>/dev/null)" || return 1
    pid="${own%%|*}"
    case "${pid:-}" in ''|*[!0-9]*) continue ;; esac
    kill -0 "$pid" 2>/dev/null || continue
    out="$out $pid"
  done
  printf '%s\n' "${out# }"
}
controller_tree_pids() { # live descendants of the controller, minus this refresh and its own chain
  local t
  [ "$CONTROLLER_LIVE" = 1 ] || return 1
  t="$("${PS_BIN:-ps}" -eo pid=,ppid=,command= 2>/dev/null)" || return 1
  case "$t" in *[![:space:]]*) ;; *) return 1 ;; esac
  printf '%s\n' "$t" | awk -v c="$CONTROLLER_PID" -v me="$$" '
    { ppid[$1]=$2; seen[$1]=1 }
    END {
      if (!(c in seen)) exit 1
      # THIS refresh must not count itself. Its own subtree AND the chain of parents above it are
      # excluded: the loop runs us as `out="$(bash "$rr")`", which puts a command-substitution shell
      # between us and the controller — counting that would make EVERY cycle read "one child of the
      # controller still running" and turn this gate into a permanent block (the always-on alarm).
      ex[me]=1
      q=me; for (i=0;i<64;i++) { if (!(q in ppid) || ppid[q]<=1) break; q=ppid[q]; if (q==c) break; ex[q]=1 }
      for (p in seen) {
        q=p
        for (i=0;i<64;i++) { if (!(q in ppid) || ppid[q]<=1) break; q=ppid[q]; if (q==me) { ex[p]=1; break } }
      }
      for (p in seen) {
        if (p==c || (p in ex)) continue
        q=p
        for (i=0;i<64;i++) { if (!(q in ppid) || ppid[q]<=1) break; q=ppid[q]; if (q==c) { print p; break } }
      }
    }'
}
ROLE_N=0; ROLE_LIST=""; ROLES_DISC="unknown"
TREE_N=0; TREE_LIST=""; TREE_DISC="unknown"
REQ=""
[ -n "${O:-}" ] && REQ="$O/state/restart-request"
if [ -n "${O:-}" ]; then
  if _roles="$(role_pids)"; then
    ROLE_LIST="$_roles"
    ROLE_N="$(printf '%s\n' "$_roles" | awk 'NF' | wc -l | tr -d ' ')"
    case "$ROLE_N" in ''|*[!0-9]*) ROLE_N=0 ;; esac
    ROLES_DISC="$ROLE_N"
  else
    ROLES_DISC="unknown"
  fi
fi
if [ "$CONTROLLER_LIVE" = 1 ]; then
  if _tree="$(controller_tree_pids)"; then
    TREE_LIST="$_tree"
    TREE_N="$(printf '%s\n' "$_tree" | awk 'NF' | wc -l | tr -d ' ')"
    case "$TREE_N" in ''|*[!0-9]*) TREE_N=0 ;; esac
    TREE_DISC="$TREE_N"
  else
    TREE_DISC="unknown"
  fi
else
  # No live controller = no tree to read, and nothing for a restart to kill. `none` is a measurement
  # here, not an abstention: a controller that does not exist cannot have live children.
  TREE_DISC="none"
fi

# ── WHAT `restart-pending` MEANS, AND WHERE IT GOES (agent-infra#2641) ──────────────────────
# THE DEFECT: it was a WORD PRINTED INTO A REASON STRING — a fact with no transition. On a cell it was
# permanent (identity unreadable, so always "not provably on the pin"), so the token rode on every spawn
# line for ever; and when it was TRUE the only way to act was a hand restart that reaps WIP. So the state
# is DECIDED here and the decision is recorded:
#   inert       no live controller — nothing is running to restart; the next launch runs the pin.
#   unprovable  a controller IS live and its identity is a CLAIM (the stamp), not a fact. NO restart is
#               requested: we cannot say one is needed, and acting on an unproven premise is how a
#               refresh becomes an incident.
#   deferred    a restart IS needed and something would be interrupted — a REQUEST is recorded naming
#               the blocking population, and NOTHING is applied.
#   safe        a restart IS needed and every population above measured EMPTY — a REQUEST is recorded
#               with `actuation=safe` for the actuator.
# ⛔ THERE IS NO ACTUATOR IN THIS FILE, AND THAT IS THE DECISION. A loop that restarts ITSELF is the one
# path that cannot be made safe: the thing being killed is the supervisor of the work it would kill (and
# of this very cycle). The fleet already has THREE restart paths — the unit (`systemctl restart
# eldato-orchestrator`), `cloud-cell-supervisor.sh stop -> apply -> start`, and merge-reminder.py's deploy
# arm, which already gates on role locks and refuses by name. A fourth would be the duplication the owner
# ruled against (FA5). So this script ASKS, records who was asked and what it would cost, and leaves the
# transition to the actuator and its confirmation to the next cycle.
inflight_gate() { # 0 = a restart would interrupt nothing MEASURED; 1 = it would, or cannot be known
  GATE_CODE=none; GATE_WHY=""
  case "${LANES_DISC:-unknown}" in
    unknown) GATE_CODE=lanes-unreadable
             GATE_WHY="the lane population is UNREADABLE (no \$O, or ps failed) — cannot-verify is never idle"
             return 1 ;;
  esac
  if [ "$LANE_N" -gt 0 ]; then
    GATE_CODE=lanes; GATE_WHY="$LANE_N lane process(es) in flight in \$O ($(_lane_short))"; return 1
  fi
  case "${ROLES_DISC:-unknown}" in
    unknown) GATE_CODE=roles-unreadable
             GATE_WHY="state/roles is UNREADABLE, so a reap/merge/hygiene pass cannot be excluded"
             return 1 ;;
  esac
  if [ "$ROLE_N" -gt 0 ]; then
    GATE_CODE=roles; GATE_WHY="$ROLE_N role pass(es) in flight (pids $(printf '%s' "$ROLE_LIST" | tr ' ' ','))"; return 1
  fi
  case "${TREE_DISC:-unknown}" in
    unknown) GATE_CODE=tree-unreadable
             GATE_WHY="the controller's process tree is UNREADABLE, so a lane child cannot be excluded (a 'pi -p --no-session' child leaves no other trace)"
             return 1 ;;
  esac
  if [ "$TREE_N" -gt 0 ]; then
    GATE_CODE=tree
    GATE_WHY="$TREE_N live child process(es) of the controller other than this refresh ($(printf '%s' "$TREE_LIST" | tr '\n' ',' | sed 's/,$//'))"
    return 1
  fi
  return 0
}
set_pending() { # sets PENDING=inert|unprovable|deferred|safe, and GATE_CODE/GATE_WHY for the record
  # ⛔ IT ASSIGNS RATHER THAN ECHOING, DELIBERATELY. `PENDING="$(pending_reason)"` runs the function in a
  # COMMAND-SUBSTITUTION SUBSHELL, so GATE_CODE/GATE_WHY were set in a process that then exited and the
  # record reported `blocked=` from an unset variable (an unbound-variable abort under `set -u`, measured:
  # it broke A22's lane disclosure). One function, one shell, three globals.
  GATE_CODE=none; GATE_WHY=""
  if [ "$CONTROLLER_LIVE" != 1 ]; then GATE_CODE=none-live; PENDING=inert; return 0; fi
  case "${RUNNING_FROM:-}" in
    stamp:*) GATE_CODE=identity
             GATE_WHY="the running identity comes from the STAMP ($STAMP), which records what was SEEDED — not what is executing"
             PENDING=unprovable; return 0 ;;
  esac
  if inflight_gate; then PENDING=safe; else PENDING=deferred; fi
}

# ── THE RESTART REQUEST: who asked, what it would interrupt, and what became of it ────────────
# One record, ONE line, token-shaped like every other record in this repo, at `$O/state/restart-request`.
# ⛔ IT IS A SECOND FILE AND NOT MORE FIELDS ON `state/harness-refresh` BECAUSE IT OUTLIVES THAT RECORD:
# the per-cycle verdict is overwritten every cycle (and is not written at all on a box whose refresh is
# off or absent), while a REQUEST has to survive until it is honoured or cleared to be readable at all.
# The transition it defines:
#   request=pending    a restart is needed and was ASKED FOR. `requested_at` is the FIRST ask (later
#                     cycles update `waited=` and never reset the clock); `actuation=` says whether the
#                     populations allow it and `blocked=`/`lanes=` name what would be interrupted.
#   request=honoured   the RUNNING IDENTITY MOVED away from the one the request named — the restart
#                     happened, and `after=<n>s` is how long it took. Only the process moving can
#                     honour a request; a pin or a stamp changing cannot (that is the #2641 defect).
#   request=cleared    the premise disappeared without the process moving (the box re-pinned, the
#                     identity became readable, or the controller went away) — said as its own word,
#                     because "not pending any more" and "the restart happened" are different facts.
#   request=refused    the loop REFUSES to request one, with the reason: unprovable identity, or no
#                     live controller to restart. Nothing is asked of any actuator.
# `--print-restart` prints it; `cloud-cell-supervisor.sh status` prints it beside the self-refresh line.
req_field() { # <name> -> value from the last request record (empty when the record or the field is absent)
  [ -n "$REQ" ] && [ -f "$REQ" ] || return 0
  sed -n "s/.*[[:space:]]$1=\([^[:space:]]*\).*/\1/p" "$REQ" 2>/dev/null | awk 'NF{print; exit}'
}
restart_request_record() { # <relation>  (reads PENDING/GATE_CODE/GATE_WHY/RUN_SHORT/TIP/LANES_DISC)
  local rel="$1" now prev_req prev_at prev_run prev_by prev_act prev_block act line
  local was at waited after
  now="$(date +%s)"
  [ -n "$REQ" ] || return 0
  prev_req="$(req_field request)"; prev_at="$(req_field requested_at)"
  prev_run="$(req_field running)";  prev_by="$(req_field requested_by)"
  prev_act="$(req_field actuation)"; prev_block="$(req_field blocked)"
  case "${prev_at:-}" in ''|*[!0-9]*) prev_at="" ;; esac
  # `after=` only ever claims a real interval: an unparseable/absent stamp yields `after=unknown`, never 0.
  after=unknown; [ -n "$prev_at" ] && after=$(( now - prev_at ))s
  # ── a request is still outstanding only while the relation is pending AND the box has something to
  # restart (`inert` means no controller: nothing to honour, so it is not an outstanding request).
  if [ "$rel" != restart-pending ] || [ "$PENDING" = inert ]; then
    case "$prev_req" in
      pending|refused) : ;;
      *) return 0 ;;   # nothing outstanding, nothing to write (a box that was never pending)
    esac
    if [ "$rel" = restart-pending ]; then          # inert: the controller went away
      was="${prev_run:-unknown}"; at="${prev_at:-$now}"
      line="restart request=cleared requested_at=$at cleared_at=$now after=$after requested_by=${prev_by:-unknown} was=$was now=${RUN_SHORT:-unknown} reason=no-live-controller"
    elif [ -n "${prev_run:-}" ] && [ "$prev_run" != "${RUN_SHORT:-unknown}" ]; then
      was="$prev_run"
      line="restart request=honoured requested_at=${prev_at:-$now} honoured_at=$now after=$after requested_by=${prev_by:-unknown} was=$was now=${RUN_SHORT:-unknown} pending=none actuation=${prev_act:-unknown} blocked=${prev_block:-unknown} actuator=stop+apply+start"
    else
      line="restart request=cleared requested_at=${prev_at:-$now} cleared_at=$now after=$after requested_by=${prev_by:-unknown} was=${prev_run:-unknown} now=${RUN_SHORT:-unknown} reason=no-longer-pending"
    fi
  elif [ "$PENDING" = unprovable ]; then
    # NOT a request: we cannot say a restart is needed, so asking for one would be an action on an
    # unproven premise — the exact shape that turns a refresh into an incident.
    at="${prev_at:-$now}"
    line="restart request=refused reason=running-identity-unprovable requested_at=$at refused_at=$now requested_by=harness-refresh.sh@${RUN_SHORT:-unknown} running=${RUN_SHORT:-unknown} pin=${TIP_SHORT:-unknown} pending=unprovable actuation=blocked blocked=identity actuator=none"
  else
    # A PENDING request. The FIRST ask owns `requested_at`; a later cycle that still sees the same state
    # only advances `waited=` — a clock that resets every cycle would make "pending for three days"
    # indistinguishable from "asked 3 minutes ago", which is the whole point of the record.
    if [ "$prev_req" = pending ] && [ -n "$prev_at" ]; then at="$prev_at"; waited=$(( now - prev_at ))s
    else at="$now"; waited=0s; prev_by=""; fi
    act=safe; [ "$PENDING" = safe ] || { act=blocked; }
    line="restart request=pending requested_at=$at waited=$waited requested_by=${prev_by:-harness-refresh.sh@${RUN_SHORT:-unknown}} running=${RUN_SHORT:-unknown} pin=${TIP_SHORT:-unknown} pending=$PENDING actuation=$act blocked=$GATE_CODE lanes=${LANES_DISC:-unknown} checked=argv,roles,tree blind=reparented-no-wrapper actuator=stop+apply+start"
  fi
  ( mkdir -p "$(dirname "$REQ")" 2>/dev/null
    printf '%s\n' "$line" > "$REQ.tmp.$$" 2>/dev/null && mv -f "$REQ.tmp.$$" "$REQ" ) 2>/dev/null \
    || { rm -f "$REQ.tmp.$$" 2>/dev/null; echo "harness-refresh: WARNING — could not record $REQ; the restart request above is this cycle's only copy" >&2; }
}

# ── fetch, then resolve the ref tip ──────────────────────────────────────────────────────────────
TIP=""
# ⛔ A WARNING IS NOT A DISCLOSURE, AND PROSE IS NOT A RECORD. Measured in review: with origin
# unreachable (the realistic network/auth blip) this script warned on stderr, printed
# `relation=current`, and the controller — which keeps only the LAST non-record line — dropped the
# warning entirely. Every surface (LOG, state/harness-refresh, status, and the EMPTY spawn-line token)
# then said "current" about a box one commit behind. So the staleness RIDES IN THE RECORD (`fetch=`)
# and the controller turns it into a token; the prose stays for a human reading the script's output.
FETCH_STATE="notfetched"
if [ "$FETCH" -eq 1 ]; then
  FETCH_STATE="ok"
  case "$REF" in
    origin/*)
      # ⛔ BOUNDED, BECAUSE THIS RUNS AT THE TOP OF THE CONTROLLER'S CYCLE. A hung connection is exactly
      # the "network blip" this code is written for, and every other external call in this fleet is
      # wrapped (`cloud-cell-doctor.sh`); an unbounded fetch would stall the whole controller on it.
      # ⛔ THE TIP COMES FROM A REF THIS SCRIPT ALONE WRITES, NOT FROM `FETCH_HEAD`. Two independent
      # reasons, both measured in review:
      #   1. `git fetch <remote> <branch>` writes FETCH_HEAD but only moves
      #      `refs/remotes/<remote>/<branch>` when the remote's refspec maps into it — so under any other
      #      refspec the fetch exits 0, the local ref stays put, and reading the tip from it publishes a
      #      STALE comparison as `fetch=ok` + `relation=current` with an EMPTY spawn-line token.
      #   2. `FETCH_HEAD` is ONE file per .git, shared by every worktree and rewritten by ANY concurrent
      #      fetch (`refresh-candidates.sh` runs a bare `git fetch origin`, which writes one line per
      #      branch). Reading its first line picked up an unrelated branch and reported a behind box as
      #      current — or as a false `ahead`, whose remedy text tells a healthy operator to rebase.
      # A private destination ref (`refs/harness-refresh/<branch>`, forced) is written by this script and
      # nobody else, so the tip is exactly what this fetch produced.
      _fb="${REF#origin/}"
      if ! bounded_fetch "${HARNESS_FETCH_TIMEOUT:-$HARNESS_FETCH_TIMEOUT_DEFAULT}" \
           git -C "$REPO" fetch --quiet origin "+refs/heads/$_fb:refs/harness-refresh/$_fb"; then
        # A failed fetch is NOT fatal while the ref still resolves locally — pinning a commit needs no
        # network — but it must not be reported as freshness either (check-deployed-drift.sh's rule).
        FETCH_STATE="stale"
        log_line "harness-refresh: WARNING — could not fetch $REF (network, auth or a timeout); comparing the LOCAL ref, which may be stale" >&2
      else
        _fh="$(git -C "$REPO" rev-parse --verify --quiet "refs/harness-refresh/$_fb^{commit}" 2>/dev/null)"
        if [ -n "$_fh" ]; then
          FETCH_TIP="$_fh"
        else
          # The fetch succeeded and wrote nothing this script can read. Falling back to the local ref while
          # claiming `ok` is the stale-comparison-as-fresh shape all of this exists to refuse.
          FETCH_STATE="stale"
          log_line "harness-refresh: WARNING — $REF fetched but refs/harness-refresh/$_fb could not be read back; comparing the LOCAL ref, which may be stale" >&2
        fi
      fi ;;
    *)
      # ⛔ A REF THIS SCRIPT DID NOT FETCH IS A LOCAL REF, AND A LOCAL REF IS NOT A FRESHNESS ANSWER.
      # `HARNESS_REF` and `--ref` are operator-settable and need only be a resolvable git ref, so a bare
      # `main` (or a tag) is legal — and comparing it silently reports `current` on a box that is behind.
      # Measured in review: local main one commit behind origin/main -> `relation=current`, while the
      # same box read through origin/main printed BEHIND. Same rule as a failed fetch: say it, and carry
      # it in the record.
      FETCH_STATE="local"
      log_line "harness-refresh: WARNING — '$REF' is not an origin/* ref, so nothing was fetched for it: comparing the LOCAL ref, which may be stale (use origin/main)" >&2 ;;
  esac
fi
TIP=""
[ -n "${FETCH_TIP:-}" ] && TIP="$FETCH_TIP"
[ -n "$TIP" ] || TIP="$(git -C "$REPO" rev-parse --verify --quiet "${REF}^{commit}" 2>/dev/null)"
[ -n "$TIP" ] || refuse unknown 23 "${RUNNING:-unknown}" "${PIN_SHA:+$(short "$PIN_SHA")}" \
  "cannot resolve '$REF' in $REPO — without the tip there is nothing to be current WITH (cannot-verify is never a pass)"
RUN_SHORT="$(short "$RUNNING")"; [ -n "$RUN_SHORT" ] || RUN_SHORT=unknown
PIN_SHORT="$(short "$PIN_SHA")"; [ -n "$PIN_SHORT" ] || PIN_SHORT=none
DEP_SHORT="$(short "$DEPLOYED")"; [ -n "$DEP_SHORT" ] || DEP_SHORT=unknown
# The tip, shortened, for the restart-request record: `pin=` there must name the DEPLOYED TIP (the side
# the process should already be on), never the sha record — the two are different records and #2216 is
# the measured shape where they disagree.
TIP_SHORT="$(short "$TIP")"; [ -n "$TIP_SHORT" ] || TIP_SHORT=unknown

# ── classify ────────────────────────────────────────────────────────────────────────────────────
# dirty is checked FIRST and over the harness surface only: it is a fact about the SOURCE this box
# would adopt, and it outranks every relation because adopting over it is the measured data loss.
DIRT="$(git -C "$REPO" status --porcelain -- "$DIRTY_SCOPE" 2>/dev/null)"
_drc=$?
if [ "$_drc" -ne 0 ]; then
  refuse unknown 23 "$RUN_SHORT" "$PIN_SHORT" \
    "cannot read 'git status' in $REPO for $DIRTY_SCOPE (git failed) — cannot-verify is never clean"
fi
if [ -n "$DIRT" ]; then
  _n="$(printf '%s\n' "$DIRT" | wc -l | tr -d ' ')"
  _first="$(printf '%s\n' "$DIRT" | head -3 | awk '{print $NF}' | tr '\n' ' ')"
  refuse dirty 20 "$RUN_SHORT" "$PIN_SHORT" \
    "$REPO/$DIRTY_SCOPE has $_n uncommitted change(s) ($(printf '%s' "$_first" | sed 's/ *$//')) — adopting $REF would run the commit INSTEAD of that work, which is how a live-tested patch is lost. Commit or discard it; nothing was touched."
fi

# rel_of <sha> -> current | behind | ahead | diverged | unverifiable. Hash equality or
# `merge-base --is-ancestor`, NEVER a commit count (the recorded rule — see the header).
rel_of() {
  local s="$1"
  [ -n "$s" ] || { printf 'unverifiable\n'; return 0; }
  # ⛔ AN UNRESOLVABLE COMMIT IS `unverifiable`, NOT `diverged`. `merge-base --is-ancestor` exits 128 for an
  # object this repo does not have, and a non-zero result was read as "neither ancestor nor descendant" —
  # so a stale stamp naming a commit the checkout lacks was reported as the 2026-10-14 off-line shape and
  # told to re-pin a tree that may be perfectly fine. Provenance is checked before the verdict.
  git -C "$REPO" cat-file -e "$s^{commit}" 2>/dev/null || { printf 'unverifiable\n'; return 0; }
  [ "$s" = "$TIP" ] && { printf 'current\n'; return 0; }
  if git -C "$REPO" merge-base --is-ancestor "$s" "$TIP" 2>/dev/null; then printf 'behind\n'; return 0; fi
  if git -C "$REPO" merge-base --is-ancestor "$TIP" "$s" 2>/dev/null; then printf 'ahead\n'; return 0; fi
  printf 'diverged\n'
}
REL_RUN="$(rel_of "$RUNNING")"
REL_DEP="$(rel_of "$DEPLOYED")"

# ⛔ THE RUNNING TREE IS CHECKED FIRST, AND AHEAD/DIVERGED REFUSE EVEN WHEN THE PIN IS FINE. The pin
# decides what the NEXT launch runs; the running tree decides what is happening NOW. A controller
# executing commits that are not on $REF's line is the measured 2026-10-14 incident (#1745: a tree off
# main's line merged real PRs off the shared queue while `check` called the cell healthy), and local
# commits would be dropped by any advance. Both are the operator's to reconcile, so nothing is touched.
case "$REL_RUN" in
  ahead)
    refuse ahead 21 "$RUN_SHORT" "$PIN_SHORT" \
      "the harness this box RUNS ($RUN_SHORT, from $RUNNING_FROM) carries commits that are NOT on $REF's line — advancing would drop them. Rebase/merge them onto $REF (or discard them), then re-run; nothing was touched." ;;
  diverged)
    refuse diverged 22 "$RUN_SHORT" "$PIN_SHORT" \
      "the harness this box RUNS ($RUN_SHORT, from $RUNNING_FROM) is neither an ancestor nor a descendant of $REF ($(short "$TIP")) — this is the measured 2026-10-14 shape: a tree off main's line that nothing could compare. Re-pin it deliberately (cloud-cell-supervisor.sh apply); nothing was touched." ;;
esac

REL="$REL_DEP"
case "$REL" in
  ahead)
    refuse ahead 21 "$RUN_SHORT" "$PIN_SHORT" \
      "the harness this box is PINNED to ($DEP_SHORT, from $DEPLOYED_FROM) carries commits that are NOT on $REF's line — advancing would drop them. Rebase/merge them onto $REF (or discard them), then re-run; nothing was touched." ;;
  diverged)
    refuse diverged 22 "$RUN_SHORT" "$PIN_SHORT" \
      "the harness this box is pinned to ($DEP_SHORT, from $DEPLOYED_FROM) is neither an ancestor nor a descendant of $REF ($(short "$TIP")) — this is the measured 2026-10-14 shape: a tree off main's line that nothing could compare. Re-pin it deliberately (cloud-cell-supervisor.sh apply); nothing was touched." ;;
  unverifiable)
    refuse unknown 23 unknown "$PIN_SHORT" \
      "cannot establish which commit this box DEPLOYS (no git identity at $SELF, no usable pin at $PIN, and no usable commit in $STAMP) — an absent identity is UNKNOWN, and cannot-verify is never a pass (#1745)" ;;
esac

# ── the pin writer ───────────────────────────────────────────────────────────────────────────────
# TEMP-THEN-RENAME, never `> "$PIN"` in place: an in-place write truncates the real record first, so
# an ENOSPC in that window destroys the one artifact that answers "which harness is this box on?".
write_pin() { # <sha>
  local dir tmp
  dir="$(dirname "$PIN")"
  mkdir -p "$dir" 2>/dev/null || { echo "harness-refresh: cannot create $dir — the pin cannot be recorded" >&2; return 1; }
  tmp="$PIN.tmp.$$"
  printf '%s\n' "$1" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$PIN" 2>/dev/null || { rm -f "$tmp"; return 1; }
}

if [ "$REL" = current ]; then
  # `restart-pending` is NOT a failure and NOT a reason to redeploy: the pin names the tip and the
  # controller still executes the tree it was launched with (pin-per-commit; see the header). It is
  # named because the alternative — printing `current` — is the false PASS this whole job exists to
  # end: an operator would read "current" about a controller running last week's code.
  _rel=current
  if [ -n "$RUNNING" ] && [ "$RUNNING" != "$TIP" ]; then _rel=restart-pending; fi
  # Cannot-verify is not a pass: a live controller whose identity comes only from the stamp (because a
  # `self:` read did not resolve) may be executing anything, including the pre-apply harness.
  case "$RUNNING_FROM" in
    stamp:*) [ "${CONTROLLER_LIVE:-0}" = 1 ] && [ "$_rel" = current ] && _rel=restart-pending ;;
  esac
  # ── THE STATE, DECIDED ONCE, AND THE REQUEST RECORDED (#2641) ────────────────────────────────
  # ⛔ BEFORE THE EARLY EXITS BELOW, DELIBERATELY. This is the path a restart LANDS on: after
  # `stop -> apply -> start` the pin is already the tip and the controller now executes it, so the
  # branch that falls through to `exit 0` is exactly where a pending request must be seen to become
  # `honoured`. Recording it after the exits would leave every request permanently un-honoured.
  [ "$_rel" = restart-pending ] && set_pending
  restart_request_record "$_rel"
  # ⛔ AN EXPLICIT `--re-seed` IS NOT A NO-OP, EVEN WHEN THE PIN IS CURRENT (review finding: the
  # short-circuit used to answer a re-seed request with `action=none` and exit 0, dropping the one
  # action asked for in exactly the state this script creates on every advance — `restart-pending`,
  # where the pin is the tip and `$O` is still on the old tree). So a current pin WITHOUT --re-seed is
  # the no-op; a current pin WITH it falls through to the SAME exit-26 gate and materialiser below,
  # where `apply --force` (no `--pin-only`) re-seeds `$O` from the pin — and still refuses while a
  # controller/lane is in flight.
  if [ "$PIN_SHA" = "$TIP" ] && [ "$RESEED" = 0 ]; then
    record "$_rel" "$RUN_SHORT" "$(short "$TIP")" "$PIN_SHORT" none
    if [ "$_rel" = restart-pending ]; then
      # ONE LINE, because the controller keeps only the LAST non-record line (`orch-loop.sh`) and writes
      # it to $LOG — a second sentence would displace the verdict itself. So the state, the reason and
      # where the request went are all in this one, and the record on `--print-restart` carries the rest.
      case "$PENDING" in
        inert) _pn="no controller is live, so there is NOTHING to restart — the next launch runs the pin" ;;
        unprovable) _pn="the running identity is a CLAIM ($RUNNING_FROM), not a fact, so NO restart was requested — $GATE_WHY" ;;
        # `pending=` is the REASON and `actuation=` is the verdict the actuator reads; they are two
        # different fields (a `deferred` request is `actuation=blocked`) and printing one as the other
        # was wrong in the first draft of this line — measured in the suite's own output.
        *) if [ "$PENDING" = safe ]; then _act=safe; else _act=blocked; fi
           _pn="a restart IS needed and was REQUESTED (pending=$PENDING, actuation=$_act, blocked=${GATE_CODE}${GATE_WHY:+ — $GATE_WHY}); nothing is applied by this script — see '--print-restart'. Actuator: stop+apply+start" ;;
      esac
      log_line "harness RESTART-PENDING ($PENDING, running=$RUN_SHORT from $RUNNING_FROM): the pin names $REF ($(short "$TIP")) — $_pn"
    else
      log_line "harness current: $RUN_SHORT == $REF ($(short "$TIP")) — pin already names it"
    fi
    exit 0
  fi
  if [ "$PIN_SHA" != "$TIP" ] && [ "$RESEED" = 0 ]; then
    # PIN EMPTY (or stale) while the DEPLOYED commit IS the tip — the measured state on all three cells.
    # Nothing is wrong with what is deployed; the record simply cannot say it. Mend it, and say so: an
    # empty pin was previously indistinguishable from a current one because no reader refused it.
    # ⛔ A `--re-seed` REQUEST DOES NOT GET ANSWERED BY A MEND (review finding): this arm runs BEFORE the
    # flag is looked at, so it used to record `action=mended` / exit 11 — a quiet success — with the
    # materialiser never called, on exactly the state the PR's own measurement found (`empty pin`). The
    # pin write is not lost by falling through: the advance path writes APPLIED below.
    write_pin "$TIP" || refuse unknown 23 "$RUN_SHORT" "$PIN_SHORT" \
      "this box deploys $DEP_SHORT (== $REF) but the pin at $PIN cannot be written — the record would stay unusable"
    record "$_rel" "$RUN_SHORT" "$(short "$TIP")" "$(short "$TIP")" mended
    # ⛔ `${PIN_SHA:+$PIN_SHORT}${PIN_SHA:-empty/absent}` was a CORRUPT RECORD READER: with a STALE (non-empty)
    # pin it printed the short sha CONCATENATED with the full one (`was 3efaead5178433efaead517…`), in the
    # one operator-facing line that says what the record used to hold. Pick ONE of the two, never both.
    _prev="empty/absent"; [ -n "$PIN_SHA" ] && _prev="$PIN_SHORT"
    log_line "harness pin MENDED: $PIN was $_prev; this box deploys $DEP_SHORT, which IS $REF — recorded it"
    exit 11
  fi
  # current pin + --re-seed (or a stale/absent pin + --re-seed): NOT a no-op and NOT a mend. Fall
  # through to the gate + materialiser below, which writes the pin and performs the re-seed.
fi

# ── behind: advance through the box's materialiser, then record ──────────────────────────────────
# Resolution order is explicit-first. ⛔ NOTHING IS CALLED WHEN THE POSTURE IS UNKNOWN: an ambient
# "a supervisor script happens to sit in this checkout" is not a licence to run a cell verb on a
# laptop (it would create pin worktrees under $CELL_HOME and stamp a cell-shaped record onto $O).
MAT="${HARNESS_MATERIALISER:-${HARNESS_ADOPT:-0}}"
MAT_FROM="HARNESS_MATERIALISER"
case "$MAT" in
  ''|0)
    MAT=""
    # ⛔ THE AUTO ARM IS THE FIX FOR "THE PIN NEVER ADVANCES", AND IT IS SCOPED BY POSTURE, NOT BY
    # LUCK. MEASURED 2026-10-21 on all three cells: the controller's env carries HARNESS_PIN_DIR,
    # HARNESS_PIN_FILE and CELL_HOME but NOT HARNESS_MATERIALISER, because it was launched by hand
    # rather than by `start` (which exports the materialiser). Every cycle therefore took the
    # `unmaterialised` branch below and exited 25 — a pin-per-commit cell that could never advance its
    # pin, however often the refresh ran. That is the whole five-hour undeployed fix, and the reason it
    # looked like a kill problem: nobody could run the advance, so nobody could watch it not kill.
    #
    # A PIN-PER-COMMIT CELL IS EXACTLY A BOX WITH HARNESS_PIN_FILE + CELL_HOME: `HARNESS_PIN_FILE` is the
    # path of the tree `apply` materialised (the cell launcher's own contract, cloud-cell-supervisor.sh
    # ~:1995) and install.sh — the laptop path — sets neither it nor CELL_HOME. So this arm can never
    # fire on a laptop, which is the hazard the previous "an ambient supervisor script is not a licence"
    # rule existed for: the presence of the script alone still licenses nothing.
    if [ -n "${HARNESS_PIN_FILE:-}" ] && [ -n "${CELL_HOME:-}" ] \
       && [ -f "$REPO/scripts/cloud-cell-supervisor.sh" ]; then
      MAT="$REPO/scripts/cloud-cell-supervisor.sh"; MAT_FROM="auto:pin-per-commit-cell"
    fi ;;
  1)
    MAT="$REPO/scripts/cloud-cell-supervisor.sh"; MAT_FROM="HARNESS_ADOPT=1" ;;
esac
if [ "$ADOPT" = 0 ]; then MAT=""; MAT_FROM="--no-adopt"; fi
[ -n "$MAT" ] && [ ! -f "$MAT" ] && { log_line "harness-refresh: WARNING — the materialiser '$MAT' ($MAT_FROM) does not exist; treating this box as unmaterialisable" >&2; MAT=""; }

if [ -z "$MAT" ]; then
  # ⛔ A RE-SEED REQUEST THAT CANNOT BE CARRIED OUT IS A REFUSAL ON EVERY RELATION, NOT JUST `current`
  # (review finding: the guard used to be `[ "$REL" = current ]`, so a `behind` box with no materialiser
  # answered `--re-seed` with the ordinary `behind`/`unmaterialised` verdict and said nothing about the
  # flag — the exact "the flag is answered, not ignored" invariant this arm states for itself). Relabelling
  # the box to fit the exit table is not an option either: the record says what IS, and the refusal says
  # what was NOT done.
  if [ "$RESEED" = 1 ]; then
    if [ "$REL" = current ]; then
      # ⛔ `relation=current` WITH `pin=none` IS A REAL ROW (an empty sha record whose deployed tree IS the
      # tip). "The pin is already current" contradicted its own `pin=` field on the same line, so the
      # sentence is built from the record's actual state.
      if [ -n "$PIN_SHA" ] && [ "$PIN_SHA" = "$TIP" ]; then
        _relnote="The pin record already names $(short "$TIP"); the next 'start' re-seeds \$O from it."
      elif [ -z "$PIN_SHA" ]; then
        _relnote="Nothing is recorded in $PIN and the deployed tree already IS $(short "$TIP"), so there is nothing for a re-seed to advance; the next 'start' seeds \$O from it and mends the record."
      else
        # STALE RECORD, CURRENT DEPLOYMENT — a third state, and the sentence above would be false here:
        # the record holds a sha, so the truthful and actionable fact is that a flagless run MENDS it.
        _relnote="The pin record names $PIN_SHORT while the deployed tree already IS $(short "$TIP") — the record is STALE, and re-running WITHOUT --re-seed mends it (exit 11); the next 'start' also re-seeds \$O from the pin."
      fi
    else
      _relnote="This box is $REL ($DEP_SHORT -> $(short "$TIP")); the pin was NOT advanced either."
    fi
    # ⛔ RECORD WHAT IS (review finding): `relation` is the record's authoritative freshness field and the
    # contract is "the controller parses the record, never the wording" — stamping `unknown` while the
    # prose on the same line names the computed relation is a cannot-verify the script never had.
    refuse "$REL" 23 "$RUN_SHORT" "$PIN_SHORT" \
      "--re-seed was requested, but this box has NO materialiser (set HARNESS_MATERIALISER, or leave it unset on a pin-per-commit cell that sets HARNESS_PIN_FILE + CELL_HOME), so \$O was NOT re-seeded and nothing was touched. $_relnote"
  fi
  record behind "$RUN_SHORT" "$(short "$TIP")" "$PIN_SHORT" unmaterialised
  log_line "harness BEHIND: deploys $DEP_SHORT (from $DEPLOYED_FROM), $REF is $(short "$TIP") — on $REF's line but older, and this box has NO materialiser (set HARNESS_MATERIALISER, e.g. cloud-cell-supervisor.sh, which pins per commit and re-seeds \$O atomically; or, on a pin-per-commit cell — HARNESS_PIN_FILE + CELL_HOME — leave it unset and the supervisor in \$REPO is used). The pin was NOT advanced: a pin naming a tree that does not exist reads as current to everything downstream."
  exit 25
fi

# ── an advance that would change the code UNDER a running lane refuses by default ─────────────────
# THE ONE DESTRUCTIVE FORM. `--pin-only` (the default below) creates a NEW worktree and writes the pin;
# it removes nothing a live process executes. Without `--pin-only`, `apply` re-seeds $O — atomically per
# file, but into the directory a RUNNING `orch-loop.sh` calls its helpers from, so a lane mid-turn starts
# seeing a different `lane.sh`/`claims.sh` than the loop that dispatched it. That is the version skew the
# `--force` guard on `apply` exists to stop an operator causing by accident, and it is the only advance
# here that a refresh could not do under live work.
# ⛔ SO IT REFUSES, AND IT NAMES WHAT BLOCKS IT: the controller pid, the in-flight lane pids, and the
# remedy. `--force` is the deliberate override. `--force` overrides NOTHING ELSE in this script: a dirty
# tree, an ahead/an offline tree and a current pin all keep their verdicts above.
if [ "$RESEED" = 1 ]; then
  _why=""
  [ "$CONTROLLER_LIVE" = 1 ] && _why="a controller is RUNNING (pid $(head -1 "$O/.orch.lock" 2>/dev/null | tr -dc '0-9'))"
  if [ "$LANES_DISC" = unknown ]; then
    # ⛔ NO BACKTICKS IN THIS MESSAGE. It is built inside double quotes, so `ps` would be EXECUTED and
    # its whole process table (hundreds of lines) spliced into the one actionable line this refusal is
    # supposed to be — measured by review in exactly the laptop/hand-fired state (`$O` absent) where
    # this arm is reachable. The prose names the command; it must not run it.
    _why="${_why:+$_why; }how many lanes are in flight cannot be read (no \$O, or ps failed) — cannot-verify is not a pass"
  elif [ "$LANE_N" -gt 0 ]; then
    _why="${_why:+$_why; }$LANE_N lane process(es) are IN FLIGHT ($(_lane_short))"
  fi
  if [ -n "$_why" ] && [ "$FORCE" != 1 ]; then
    # ⛔ THE REMEDY MUST BE TRUE FOR THIS BOX (review finding). This gate is reachable with the pin
    # ALREADY at the tip (`restart-pending`, the state this script creates on every advance) — and there
    # "re-run WITHOUT --re-seed and the pin moves to …" is false: that path is a no-op. The clause is
    # chosen from the fact already in scope.
    # ⛔ THE DISCRIMINATOR IS WHAT DROPPING THE FLAG WOULD CHANGE, WHICH IS THE DEPLOYED TREE — not the sha
    # record (review finding): a pin whose sha record is already at the tip but whose PATH record names an
    # older tree is the two-records-disagree state, and there re-running without the flag DOES advance the
    # deployed tree. Keying on `PIN_SHA` told that operator "nothing would change", about the one action
    # that repairs the box.
    if [ "$DEPLOYED" = "$TIP" ]; then
      if [ "$PIN_SHA" = "$TIP" ]; then
        _remedy="The deployed tree ALREADY IS $(short "$TIP") and the pin record names it, so dropping the flag would change nothing (the deferred restart is the remaining step): a re-seed here needs --force (deliberate), or the next 'start', which re-seeds \$O from the pin."
      else
        # A STALE/ABSENT RECORD WITH A CURRENT DEPLOYMENT still has something for a flagless run to do —
        # MEND it — so "change nothing" would be false here.
        # ⛔ ONE SHA, NEVER TWO (the defect the mend line fixed, reintroduced here — review finding):
        # `${PIN_SHA:+$PIN_SHORT}${PIN_SHA:-empty/absent}` prints the short sha CONCATENATED with the full
        # one whenever the record is non-empty. Pick one spelling.
        _pinstate="empty/absent"; [ -n "$PIN_SHA" ] && _pinstate="was $PIN_SHORT"
        _remedy="The deployed tree ALREADY IS $(short "$TIP") but the pin RECORD does not name it ($_pinstate): re-run WITHOUT --re-seed to mend the record, and keep --re-seed only if you really need \$O re-seeded — that still needs --force (deliberate), or the next 'start'."
      fi
    elif [ "$PIN_SHA" = "$TIP" ]; then
      # The sha record ALREADY names the tip and only the PATH record is stale (the two-records state):
      # "the pin moves to <tip>" would be false — what a flagless run advances is the deployed tree.
      _remedy="The pin RECORD already names $(short "$TIP"); the deployed tree ($DEP_SHORT) is what a flagless run advances via a new per-commit worktree — dropping the flag does that, leaving every lane on the tree it started with. Use --force only for a deliberate re-seed."
    else
      _remedy="The pin advance does not need it: re-run WITHOUT --re-seed and the pin moves to $(short "$TIP") via a new per-commit worktree, leaving every lane on the tree it started with (the restart is then deferred and disclosed as restart-pending). Use --force only for a deliberate re-seed."
    fi
    refuse blocked 26 "$RUN_SHORT" "$PIN_SHORT" \
      "--re-seed would re-seed \$O (swapping the helper scripts) while $_why. $_remedy"
  fi
fi

# `HARNESS_FETCH=0` because THIS script already fetched: a second fetch would resolve a MOVING tip
# between the comparison and the pin, i.e. record one sha over a different materialised tree.
# ⛔ `--pin-only`, DELIBERATELY, AND IT IS THE WHOLE SAFETY ARGUMENT. `apply` without it also re-seeds
# $O — swapping the helper scripts a RUNNING controller calls while that controller is still the old
# `orch-loop.sh`: a version skew no other path in this repo produces, and the reason `apply` refuses
# under a live controller without `--force`. `--pin-only` advances the PIN (a new per-commit worktree;
# the tree being executed is never removed) and leaves $O alone, so the next `start` seeds $O from the
# new pin and the box moves as one piece. `--force` is still passed because the pin IS being advanced
# under a live controller — that is this feature's job, not an accident.
# The `--pin-only` / re-seed choice, decided in ONE place: `--pin-only` is the non-destructive advance
# (new per-commit worktree, $O untouched) and is the default; `--re-seed` is the destructive one, already
# gated above. `--force` is passed either way because the pin IS being advanced under a live controller —
# that is this feature's job, not an accident.
if [ "$RESEED" = 1 ]; then _mat_args="apply --force"
else                        _mat_args="apply --force --pin-only"; fi
# shellcheck disable=SC2086  # word-splitting is the point: the verb and its flags ARE two arguments
out="$(HARNESS_FETCH=0 bash "$MAT" $_mat_args 2>&1)"; mrc=$?
if [ "$mrc" -ne 0 ]; then
  refuse unknown 23 "$RUN_SHORT" "$PIN_SHORT" \
    "the materialiser $MAT failed (exit $mrc) while adopting $(short "$TIP"), so nothing was recorded as deployed — the pin was NOT advanced. Its own last lines: $(printf '%s' "$out" | tail -3 | tr '\n' ' ')"
fi
# Re-read what the materialiser actually pinned. The pin must name the materialised tree, not the tip
# we hoped for: `apply` pins $HARNESS_REF, and recording a different sha than the tree it left behind
# is the false record this whole script exists to prevent.
APPLIED="$TIP"
_cur="$(git -C "$REPO" rev-parse --verify --quiet "${HARNESS_REF:-$REF}^{commit}" 2>/dev/null)"
# ⛔ A RE-READ THAT FAILED MUST NOT FALL BACK TO THE TIP WE HOPED FOR. `apply` may resolve HARNESS_REF in
# $HARNESS_REPO, while this re-read resolves it in $REPO; if that yields nothing, silently keeping $TIP
# makes the guard below un-fireable and writes a pin asserting the materialiser pinned a commit this
# script never read — the false record this whole script exists to prevent.
[ -n "$_cur" ] || refuse unknown 23 "$RUN_SHORT" "$PIN_SHORT" \
  "the materialiser reported success but the commit it pinned cannot be re-read in $REPO (${HARNESS_REF:-$REF} did not resolve) — what was materialised is UNKNOWN, so no pin was written"
APPLIED="$_cur"
# ⛔ A PIN THAT DOES NOT NAME THE COMPARED TIP IS NOT `current`, AND NOTHING IS RECORDED. Reachable on a
# real box: `apply` re-resolves $HARNESS_REF itself (cloud-cell-supervisor.sh's harness_apply) and any
# concurrent fetch on the box can move that ref between this script's comparison and the pin. Recording
# the relation as `current` here would empty HARNESS_TOKEN and spawn every lane from a box that is
# behind, with no disclosure at all — the false PASS this whole script exists to prevent.
if [ "$APPLIED" != "$TIP" ]; then
  refuse unknown 23 "$RUN_SHORT" "$PIN_SHORT" \
    "the materialiser pinned $(short "$APPLIED") but $REF is now $(short "$TIP") — the ref moved between the comparison and the pin (a concurrent fetch on this box, or HARNESS_REF resolving to a different ref than --ref/$REF). NOTHING was recorded as deployed and the relation is unknown, not current; re-run once the ref is quiet."
fi
write_pin "$APPLIED" || refuse unknown 23 "$RUN_SHORT" "$PIN_SHORT" \
  "the materialiser pinned $(short "$APPLIED") but the pin at $PIN cannot be written — the record would still name the old harness"
# WHAT THE BOX IS NOW is `restart-pending`, not `current`: the pin names the tip, the materialised tree
# exists, and the process still executes the previous commit until it is relaunched. Saying `behind`
# here would keep a stale token on every spawn line for a controller that is simply one restart away;
# saying `current` would be the false PASS (an operator reads "current" about last week's code).
_rel=restart-pending
[ "$RUNNING" = "$TIP" ] && _rel=current
# The same decision the current-pin path makes, for the cycle where the pin JUST moved: the advance does
# not restart anything, so a repin is exactly a request that has not been honoured yet.
[ "$_rel" = restart-pending ] && set_pending
restart_request_record "$_rel"
# ⛔ THE ACTION IS KEYED TO WHAT THE BOX DEPLOYS, NOT TO THE SHA RECORD (review finding: a pin is TWO
# records — `harness-up:41-46` exists because they disagree, and #2216's measured shape is a sha record at
# the tip while the PATH record (`$HARNESS_PIN_FILE`) still names the older tree, which `apply` then
# rewrites). Deciding from `PIN_SHA` alone recorded that real advance as `reseeded` and printed
# `c1 == c2` — a false equality between two different commits, in the one line an operator reads.
# So: `reseeded` only when BOTH records already named APPLIED (nothing moved, anywhere); and the
# separator/ clauses come from the same facts, so the sentence can be true in every combination.
_act=repinned
if [ "$RESEED" = 1 ] && [ "$PIN_SHA" = "$APPLIED" ] && [ "$DEPLOYED" = "$APPLIED" ]; then _act=reseeded; fi
# `ref=` is the TIP, `pin=` is what was materialised — the record's contract (see the header). Filling
# `ref=` with APPLIED mislabels a commit and would hide exactly the divergence refused above.
record "$_rel" "$RUN_SHORT" "$(short "$TIP")" "$(short "$APPLIED")" "$_act"
# ⛔ ONE PROSE LINE, NOT TWO, AND IT IS DELIBERATE (review finding): the controller's per-cycle block
# keeps only the LAST non-record line (`orch-loop.sh`: awk '!/^harness relation=/ && NF' | tail -1) and
# writes it to `$LOG` — the file an operator reads. A second `say` after this one therefore DISPLACED
# the verdict, so the old->new sha, the materialiser path and the `[auto:pin-per-commit-cell]`
# disclosure this PR adds never reached `$LOG`. Folded into the verdict sentence instead, so the one
# surviving line carries the pin move AND what was in flight.
_lanes_phrase() {
  if [ "$LANES_DISC" = unknown ]; then printf 'unknown (ps/$O unreadable)'
  else printf '%s lane process(es)' "$LANE_N"; fi
}
# The separator is an ASSERTION, so it may only claim a move that happened: `==` iff the deployed tree
# already named APPLIED, `->` only on a real move (two identical shas never get an arrow).
_sep='->'; [ "$DEPLOYED" = "$APPLIED" ] && _sep='=='
# The pin clause names what the RECORD did, which is a different question from what the tree did.
if [ -z "$PIN_SHA" ]; then
  _pin_clause="pin $PIN was empty/absent and now names $(short "$APPLIED")"
elif [ "$PIN_SHA" = "$APPLIED" ]; then
  _pin_clause="pin $PIN already named $(short "$APPLIED") — the pin did NOT move"
else
  _pin_clause="pin $PIN now names $(short "$APPLIED") (was $PIN_SHORT)"
fi
if [ "$DEPLOYED" = "$APPLIED" ]; then
  _dep_clause="the deployed tree already named $(short "$APPLIED")"
else
  _dep_clause="the deployed tree NOW names $(short "$APPLIED") (was $DEP_SHORT)"
fi
if [ "$RUNNING" = "$APPLIED" ]; then
  _rest_clause="the running controller is already on $RUN_SHORT"
else
  _rest_clause="the running controller stays on $RUN_SHORT until it is restarted ('start' re-seeds \$O from the new pin), so this is restart-pending, not current"
fi
if [ "$_act" = reseeded ]; then _word=RESEEDED; else _word=REPINNED; fi
# ⛔ THE NON-DESTRUCTION SENTENCE BELONGS TO THE `--pin-only` ARM ONLY (review finding). A re-seed calls
# `apply` WITHOUT `--pin-only`, and `seed_and_stamp` then mirrors `$HARNESS/*.sh` over `$O/*.sh` AND
# removes every `$O/*.sh` the harness does not ship — a lane's own `$O/run-fix-<n>.sh` is exactly such a
# file. Claiming "no lane tree was touched" there is a false assurance in the one line an operator reads,
# about the arm that IS destructive.
if [ "$RESEED" = 1 ]; then
  _inflight="IN-FLIGHT at the advance: $(_lanes_phrase) — nothing was SIGNALLED, but this run RE-SEEDED \$O (no --pin-only): the helpers there now come from $(short "$APPLIED"), and any \$O/*.sh the harness does not ship was removed by seed_and_stamp, so a lane still running from such a script will fail on its next invocation"
else
  _inflight="IN-FLIGHT at the advance: $(_lanes_phrase) — nothing was signalled and no lane tree was touched, each finishes on the harness commit it started with"
fi
log_line "harness $_word: $DEP_SHORT $_sep $(short "$APPLIED") ($REF) via $MAT${MAT_FROM:+ [$MAT_FROM]}; $_pin_clause; $_dep_clause — $_rest_clause; $_inflight"
exit 10
