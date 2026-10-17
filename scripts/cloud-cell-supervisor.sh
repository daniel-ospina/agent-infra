#!/bin/bash
# cloud-cell-supervisor.sh — run the orchestrator harness on a Linux cloud cell.
#
# The harness's macOS-specific parts are (a) how the CONTROLLER is started — install.sh
# renders a launchd plist — and (b) three OS primitives inside orch-loop.sh (stat -f, sysctl
# vm.loadavg, sysctl vm.swapusage) that are BSD-only. The lanes themselves were never
# launchd's: orch-loop.sh spawns them with `tmux new-session`, and tmux is on the devbox
# already. So a Linux cell needs this supervisor for (a), plus the portable-primitive fix
# tracked by agent-infra#1702 for (b). Until #1702 lands the cell controller aborts on its
# first cycle once a worker log exists, and the load/swap gates never bind — treat a cell as
# a MERGE ACTOR with incomplete back-pressure, not as a full peer of the laptop.
#
# Runs ON THE CELL (Linux). Usage:
#   bash cloud-cell-supervisor.sh check|start|stop|status|logs|apply|prune
#
#   apply   fetch agent-infra main and PIN this cell's harness to it (agent-infra#1745). This is the
#           whole of "apply the proper harness"; `start` runs it before every launch, so it is
#           normally not needed by hand — it exists for a cell you want to fix without starting.
#   prune   reclaim the regenerable disk the lanes leave behind (.venv per worktree, caches) and
#           report the review scratch that accumulates under /tmp. --scratch[=DAYS] also deletes
#           scratch checkouts older than DAYS. A full disk is what breaks a cell FIRST.
#
# Prereqs on the cell (see cloud-cell-bringup.sh --check):
#   HOME writable · repo cloned · gh authenticated with push · provider key valid
#   + git/python3/pi on PATH, ~/.pi/agent/scripts/record-review.sh ('start' provisions it)
#   + the merge authority key (AI_REVIEW_GATE_KEY) if this cell is to MERGE.
# 'check' refuses to certify a cell missing any of the above: each one, absent, turns a loop step
# into a silent no-op or an unbounded paid retry (#1717).
#
# ⛔ MEASURED 2026-10-13 — A CELL WITHOUT THE MERGE KEY IS **NOT** MERGE-INERT.
# An earlier draft of this file claimed a keyless cell was a safe "producer cell"
# that "will refuse every merge". That is FALSE, and the first run disproved it:
# within ~25s the controller armed AUTO-MERGE on #8425 and #8420 (`gh pr merge --auto`),
# which does NOT go through the gate key. So removing the key does not confine a cell
# to producing — it can still cause merges. Treat every started cell as a MERGE ACTOR.
#
# ── HARNESS PROVENANCE (agent-infra#1745) ────────────────────────────────────────────────────────
# MEASURED 2026-10-14, on these two cells: each ran up to FOUR `orch-loop.sh` trees at once, and the
# one copy carrying a git identity was commit `e8d5ce29` — which `git merge-base --is-ancestor
# e8d5ce29 origin/main` says is NOT on main's line — while the copy whose BYTES matched main sat in
# `/home/cmux/scripts/orchestrator-harness` with no git identity at all. `check` printed `CELL CAN RUN
# A CONTROLLER` through all of it: it asked whether a harness EXISTED, never WHICH one. "Which commit
# did this cell install?" had no answer, and a hand-copy was indistinguishable from a clone.
#
# WHAT IS RECORDED, AND WHY EACH HALF IS NEEDED
#   commit  — the harness tree's own HEAD, written to $O/.agent-infra-stamp.json by `apply`/`start`.
#             Answers "which code will run", and is the only thing comparable to the repo. A tree
#             with no git identity reads `untracked` (the hand-copy case) and is NEVER read as
#             current.
#   payload — a sha256 over the *.sh this script seeded into $O. The commit cannot see a POST-SEED
#             edit to the running copy (the class #1760 measured on a sibling surface: a deployed
#             file 18.8 KB larger than the repo's); the hash cannot say whether the commit is on
#             main's line. Together they answer the question.
#
# ⛔ THE COMPARISON IS HASH EQUALITY OR `merge-base --is-ancestor` — NEVER A COMMIT COUNT. Measured
# 2026-10-14: `git rev-list --count e8d5ce29..origin/main` printed 1 while `--is-ancestor` printed
# NO. A tree that is not on main's line at all reads as "1 behind" to a counter, and the count MOVES
# as main advances without the tree changing. The relation is therefore one of exactly:
#   current   HEAD == the ref
#   behind    HEAD is an ancestor of the ref (older, but on the line)
#   diverged  HEAD is NOT an ancestor of the ref — the measured incident, and the one that merged
#             real PRs off the shared queue while `check` called the cell healthy
#   untracked the tree has no git identity, or HEAD cannot be resolved (a hand-placed copy)
#   unknown   the ref itself does not resolve — cannot verify, and cannot-verify is never a pass
#
# WHAT EACH VERB DOES WITH IT
#   start   MENDS: fetches, pins $HARNESS_REF into a detached worktree, then seeds $O. A cell
#           therefore cannot be started on a stale or hand-copied tree, and `start` is one command.
#   apply   the same, without starting.
#   check   reports the relation, and REFUSES `untracked`/`diverged`/`unknown` outright. `behind` is
#           reported as DRIFT and does NOT refuse: main advances between any two operator commands,
#           so refusing `behind` would FALSE-BLOCK an honest restart on a tree that IS on main's
#           line — the refusal belongs to the two states that cannot be mended by getting fresher.
#   The mend is a detached `git worktree add` ON PURPOSE: `git checkout <branch>` and `git reset
#   --hard` are BLOCKED inside the cell's main checkout by the same guard the laptop runs (measured
#   on both cells), which is why every hand-fix so far ended as a second copy under
#   /home/cmux/scripts. `git fetch` and `worktree add --detach` are permitted.

set -uo pipefail

CELL_HOME="${CELL_HOME:-/tmp/cell-home}"
REPO="${REPO:-/tmp/cell}"
ENV_FILE="${ENV_FILE:-$CELL_HOME/keys.env}"
O="${O:-$CELL_HOME/orchestrator}"
# The harness is a SIBLING of this script inside agent-infra (scripts/orchestrator-harness/),
# not inside the target repo ($REPO) — but an explicit `$HARNESS` (env) is the only thing that
# outranks the path `apply` pinned, so the default is resolved in the provenance block below (pin
# file, then this script's sibling, then $REPO's own tree) rather than here. ⛔ A non-empty default
# HERE makes every later `[ -z "$HARNESS" ]` fallback dead — that is how a fresh `check` came to read
# the sibling while `start` ran the pin, the divergence #1745 is about. It moved out of tortoise's
# operations/ on 2026-10-13; the old $REPO/operations/orchestrator-harness path becomes a stub pointer
# in a follow-up tortoise PR (agent-infra#1700 / tortoise#8432), so it is no longer a valid default
# here. An unresolvable path fails loudly in cmd_check, never silently.
HARNESS="${HARNESS:-}"
# The record step (#1717). merge-one.sh EXECUTES this path to mint the signed marker that
# ai-review-gate verifies, so it is a hard dependency of the ONLY merge path — but a fresh cell does
# not have it (the file ships in the agent-infra checkout, not in the target repo). Two functions,
# not two variables, because $ENV_FILE is sourced later in this file and may repoint $CELL_HOME: the
# consumers must resolve it at call time. NO environment override — a knob that points the record
# step at another file is a way to defeat the gate, not a configuration.
recorder_path() { printf '%s\n' "$CELL_HOME/.pi/agent/scripts/record-review.sh"; }
recorder_src()  { printf '%s\n' "$HARNESS/../record-review.sh"; }
# The recorder's DECLARED SIBLING (#1362/#1717). record-review.sh resolves its diff normalizer from
# its OWN directory (`$(dirname "${BASH_SOURCE[0]}")/lib/diff-normalize.py`), so the two must be
# provisioned together, preserving the relative position — exactly as pi-bootstrap/setup.sh's lib
# farm pins it. Without it the recorder degrades to the RAW pre-#1362 digest (no false accept, but
# every base-only `gh pr update-branch` refuses carry-forward and buys a FRESH PAID review), which is
# the same paid-loop class as the missing recorder itself. Resolved from the harness checkout.
recorder_lib_path() { printf '%s\n' "$(dirname "$(recorder_path)")/lib/diff-normalize.py"; }
recorder_lib_src()  { printf '%s\n' "$HARNESS/../lib/diff-normalize.py"; }
SESSION="${SESSION:-orch}"
# OR is interpolated into the session command string, so it is defaulted here — the guard below reads
# it with `${!v}` under `set -u`, which errors on an unset name, and the string must not depend on
# the guard running first. `${OR:-…}` keeps today's default. (The merge key is NOT interpolated — a
# secret in an argv string is visible to ps/tmux; see the session command below.)
OR="${OR:-daniel-ospina/tortoise}"

# ── the SECOND tmux boundary (agent-infra#1711) ─────────────────────────────────────────────────
# A tmux session is served from the SERVER's environment, so the controller's shell does NOT reach
# the workers it spawns. orch-loop.sh reviews and merges through `tmux new-session -d -s merge-<PR>
# "bash '$O/merge-one.sh' …"`, and that session is built from the server's environment plus the
# names in tmux's `update-environment`. Without publishing them, the merge key stops at the
# controller (which re-sources $ENV_FILE): merge-one.sh → record-review.sh resolves its key as
# $AI_REVIEW_GATE_KEY, else $HOME/.pi/agent/.ai-review-gate-key.
# Measured on a PRE-EXISTING server (an operator's own session on the VM, a server that survived
# `stop`, a key rotated into keys.env after the server started) the worker received neither the key
# nor the right HOME, so `cmd_check` printed ok while every review was recorded UNSIGNED — the false
# PASS this constant exists to remove.
# `update-environment` carries NAMES ONLY: tmux copies their VALUES out of the creating client's
# environment at `new-session` time (empirically confirmed on tmux 3.4 — the cloud cell's version —
# and 3.8). That is what keeps this clear of the exposure the comment above the session command
# warns about: the secret is never an element of a tmux argv, unlike `set-environment -g KEY
# "$value"` or `new-session -e KEY=value`, which both put it there (visible to ps/tmux).
#   AI_REVIEW_GATE_KEY — the keys.env route; the controller's env carries it, so a worker created by
#                        the controller can too
#   HOME               — the key-FILE route: the worker reads $HOME/.pi/agent/.ai-review-gate-key and
#                        runs $HOME/.pi/agent/scripts/record-review.sh. The server's HOME may be the
#                        operator's (measured: /home/ubuntu), so a worker must be handed $CELL_HOME
#   O                  — the worker's log/state dir. A worker defaulting `$HOME/orchestrator` splits
#                        the per-PR claim file from the controller's, which is how one head gets two
#                        concurrent reviewers
#   DEEPSEEK_API_KEY   — the WORKER RUNTIME's credential (agent-infra#1852). Measured 2026-10-16 on
#                        all three cells: without this name a cell still MERGES (the rail needs no
#                        agent) while EVERY review and fixer dies `No API key found for deepseek`, so
#                        `merge-<PR>` ends `verdict: <none>` forever. That cell reports RUNNING,
#                        burns its whole dispatch capacity, and can never review, fix or dispatch —
#                        the same false "CELL CAN RUN A CONTROLLER" this script already guards for a
#                        stale `$O`. The controller sources keys.env, so its env carries the value
#                        and a worker it creates can inherit it; nothing is written to a file.
WORKER_ENV_NAMES="AI_REVIEW_GATE_KEY HOME O DEEPSEEK_API_KEY"

say() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }
die() { say "FATAL: $*" >&2; exit 1; }

# A quote or shell metacharacter in any value interpolated into the session command string would
# break out of it — the string is handed to tmux, which runs it with sh -c. The harness applies
# exactly this guard to $O before every spawn; apply it here to EVERY interpolated value, so the
# supervisor cannot be the weak link. (Same class as orch-loop.sh:39-41 and install.sh:65-67.)
safe_argv() {
  case "${1:-}" in
    ''|*"'"*|*'"'*|*'`'*|*'$'*|*';'*|*'|'*|*'&'*|*' '*) return 1 ;;
  esac
  return 0
}

# The key FILE is authoritative (install.sh treats it so) — but test its CONTENT, not its size:
# record-review.sh strips whitespace and treats an empty result as absent, so a 1-byte newline file
# (exactly what `echo "$KEY" > file` writes for an unset var) would be blessed and then fail the
# gate. Same class as the empty keys.env assignment the ENV_FILE branch rejects.
# ⛔ Read $CELL_HOME, NOT $HOME: keys.env is sourced above and may set HOME, while the session
# forces HOME back to $CELL_HOME AFTER that source — so the verdict would inspect a home the
# session will never use (false present, or false absent, either way).
keyfile_has_key() {
  local kf="$CELL_HOME/.pi/agent/.ai-review-gate-key"
  [ -s "$kf" ] || return 1
  # `2>/dev/null` FIRST: redirections apply left to right, so with the input redirect first an
  # existing-but-UNREADABLE key file (chmod 000) failed at the shell's own open and printed
  # "Permission denied" to the shell's stderr — the verdict the preflight exists to deliver then
  # arrived under a raw bash error. Swapping the order is what actually suppresses it; `2>/dev/null`
  # after the `<` does not.
  [ -n "$(tr -d '[:space:]' 2>/dev/null < "$kf")" ]
}

# LOCK is recomputed AFTER $ENV_FILE is sourced (below): keys.env may set $O, and a lock derived
# from a stale $O makes `stop` release and announce the wrong path.
export HOME="$CELL_HOME"

# Publish WORKER_ENV_NAMES into the tmux server's `update-environment`, APPENDING to whatever is
# already there — tmux's default list carries SSH_AUTH_SOCK and friends, and replacing it would
# silently drop them on this cell. (The append is asserted: the §7 double seeds a default list and
# requires it to survive.)
# ⛔ The first read is guarded by a server-existence probe, and that is MEASURED, not assumed: with no
# server running, `show-options` AND `set-option` both fail ("error connecting … No such file or
# directory") rather than starting one — so an unguarded `set-option` here would make `start` die on
# EVERY cold cell, the common path, which this fix must not break. A cold start needs no publication:
# the `new-session` below CREATES the server from THIS shell's environment, and that already covers
# the delivery — HOME is exported above, a keys.env key is exported by the `set -a` source, and `O`
# arrives when it came from keys.env or the caller and otherwise coincides with the worker's own
# `$HOME/orchestrator` fallback (the "works only by accident" path the issue names, and the reason a
# cold start was never the broken one). Returning early also leaves the server's own compiled-in
# `update-environment` default intact.
# ⛔ A `show-options` failure is READ as "no server". That is the one case it is meant to catch (the
# cold path, measured above), but the read is not selective: a `show-options` that failed for any
# OTHER reason on a live server would also skip publication, and `start` would proceed. On tmux that
# state is not reachable — the socket either answers or the server is gone — so the residual is
# stated rather than papered over, and it is NOT closed by a read-back: the early return happens
# before one. The alternatives that would remove the ambiguity (`set-environment -g`, `-e`) put the
# secret on a tmux argv, which is the exposure this whole route exists to avoid.
publish_worker_env() {
  local list n
  if ! list="$(tmux show-options -gqv update-environment 2>/dev/null)"; then
    return 0
  fi
  list="$(printf '%s' "$list" | tr '\n' ' ')"
  # ⛔ A listed name is STRIPPED from the new session when the creating client lacks it
  # (`update-environment` is a "these come from the client" list, not an allow-list) — the same
  # deliberate rule the `AI_REVIEW_GATE_KEY` unset above relies on. So `$ENV_FILE` (or this shell) is
  # the authoritative source for every name here: a value living ONLY in the tmux server is not a
  # supported configuration — the issue's `tmux set-environment -g` workaround reads its value FROM
  # `keys.env`, so the `start` shell (which sources it) holds it and no strip can fire. A name with no
  # value anywhere is the dead state #1852's residual records; `check` does not yet refuse it.
  for n in $WORKER_ENV_NAMES; do
    case " $list " in *" $n "*) ;; *) list="$list $n" ;; esac
  done
  tmux set-option -g update-environment "$list" \
    || die "cannot publish tmux update-environment ('$WORKER_ENV_NAMES') — every merge worker would run keyless"
}

# ── $ENV_FILE is SOURCED, so a top-level `exit`/`exec` in it ended THIS SCRIPT (agent-infra#1713) ──
# keys.env is operator-authored and is sourced into this shell, with no `set -e`, so `. "$ENV_FILE"`
# does NOT return to its caller when the file exits — the FILE's status becomes the SCRIPT's.
# Measured (`keys.env` = `exit 0`): `status`, `check` AND `start` each printed NOTHING and returned
# 0, so `start` reported success having created no session — a false green on the one command that
# launches a cell. `set -e` cannot see this: `exit 0` IS a success status. The assignments must
# still land in THIS shell (keys.env may set $O), so the file is parsed, then evaluated in a
# throwaway subshell whose LAST action is a sentinel — the sentinel's ABSENCE is the signal that
# the file terminated its shell, `exit 0` included — and only then sourced for real. The file is
# evaluated more than once (the key probes below already did this): it must be a plain
# assignment file, since its side effects run once per evaluation.
ENV_SENTINEL='__ai1713_env_sourced__'
source_env_file() {
  [ -f "$ENV_FILE" ] || return 0
  # A file bash cannot PARSE never terminates the shell: `.` fails at the open/parse and the script
  # carries on, so every variable the file meant to set is missing while the cell still reports
  # healthy (a fail-open of the same class). Refuse it here instead.
  bash -n "$ENV_FILE" || die "$ENV_FILE cannot be parsed (or read) as shell — sourcing it would silently drop every variable it sets"
  local probe
  probe="$(set -a; . "$ENV_FILE" >/dev/null 2>&1; set +a; printf '%s' "$ENV_SENTINEL")" || true
  [ "$probe" = "$ENV_SENTINEL" ] || die "$ENV_FILE did not finish sourcing — it contains a top-level 'exit'/'exec' (or a command that fails under its own 'set -e'), which would end this script and report success (rc=0) having done nothing. Remove it; put the work in a script, not in keys.env."
  set -a; . "$ENV_FILE"; set +a
}
source_env_file
# ⛔ Re-assert HOME AFTER the source: keys.env may carry a HOME= line, and everything BELOW here —
# the gh-credential lookup in cmd_check (gh reads $HOME/.config/gh), and the session itself, which
# forces HOME=$CELL_HOME — must run under the cell's home. Sourcing first left cmd_check validating
# a home the session never uses: with credentials in the repointed home the preflight said "ok:
# gh auth" and the cell started, and then every gh call in the session failed.
export HOME="$CELL_HOME"
LOCK="$O/.orch.lock"
# Does the ENV FILE itself carry a NON-EMPTY merge key? cmd_check must judge what the SESSION will
# see, not what this shell holds: the session re-sources $ENV_FILE (so a keys.env key reaches it)
# while an ambient-only export does not (tmux serves a session from the server's environment).
# ⛔ Compute SET *inside* the subshell, never from the captured string: `$( )` strips trailing
# newlines, so a value of exactly "\n" would capture as EMPTY and be read as "no env value" —
# while the consumer's own raw test (`[ -z "$GATE_KEY"`) sees a non-empty value, takes the env
# branch, and never falls back to the file. That divergence blessed a keyless cell. The value is
# captured only for the NORMALIZED test, which does not care about its trailing newlines.
KEY_IN_FILE_RAW=""
KEY_IN_FILE_SET=0
if [ -f "$ENV_FILE" ]; then
  # The `&& printf x` (and the capture it needs) is the SAME completion guard as source_env_file()
  # above: without it, a top-level `exit` in $ENV_FILE ends this probe having evaluated NOTHING, and
  # its status (0 for `exit 0`) is read as "key present" — a false PASS. Unreachable today because
  # source_env_file() dies first, but kept sound so a later refactor of that guard cannot re-open it.
  [ "$(env -u AI_REVIEW_GATE_KEY bash -c 'set -a; . "$1" >/dev/null 2>&1; [ -n "${AI_REVIEW_GATE_KEY:-}" ] && printf x' _ "$ENV_FILE" 2>/dev/null)" = x ] && KEY_IN_FILE_SET=1
  KEY_IN_FILE_RAW="$(env -u AI_REVIEW_GATE_KEY bash -c 'set -a; . "$1" >/dev/null 2>&1; printf %s "${AI_REVIEW_GATE_KEY:-}"' _ "$ENV_FILE" 2>/dev/null || true)"
fi
KEY_IN_FILE="$(printf '%s' "$KEY_IN_FILE_RAW" | tr -d '[:space:]')"
# Raw-non-empty means the consumer takes the ENV value and never falls back to the key FILE (its
# fallback is `[ -z "$GATE_KEY" ]` on the raw value). If that value normalizes to empty, the file
# check is SHADOWED — so this state must be judged absent-and-dead, never present.

# Does $ENV_FILE itself carry a tortoise checkout (the pre-flight tool's fallback source)? Same
# delivery reasoning as the key probe above: the controller session re-sources $ENV_FILE (so a value
# it carries reaches the session) while an ambient-only export does not — the session command line
# carries only HOME REPO O OR SCOPE, and tmux serves a session the SERVER's environment, which on a
# pre-existing server is the normal relaunch after `stop`. cmd_check uses this to warn about a
# dispatch-provisioning verdict that holds only in THIS shell (agent-infra#1748 review).
TORTOISE_IN_FILE=0
if [ -f "$ENV_FILE" ]; then
  [ "$(env -u TORTOISE_REPO -u TORTOISE bash -c 'set -a; . "$1" >/dev/null 2>&1; { [ -n "${TORTOISE_REPO:-}" ] || [ -n "${TORTOISE:-}" ]; } && printf x' _ "$ENV_FILE" 2>/dev/null)" = x ] && TORTOISE_IN_FILE=1
fi

# SCOPE (see orch-loop.sh): UNSET -> auto; anything SET, including a set-but-EMPTY value, is
# validated by validate_scope() and forwarded verbatim. Presence, not emptiness — `${SCOPE:-auto}`
# here would coerce a blank keys.env entry to auto and evaporate the pin this override exists for.
[ -z "${SCOPE+x}" ] && SCOPE=auto

# Refuse a bad SCOPE wherever the cell is judged or started. `check` MUST run this too: its verdict is
# "CELL CAN RUN A CONTROLLER", and a cell whose preflight says YES while its `start` dies on the same
# config is a FALSE PASS on exactly the question that verdict answers. A typo, or a set-but-BLANK
# keys.env entry, must not silently become `auto` (the default applies only when SCOPE is UNSET).
validate_scope() {
  case "$SCOPE" in
    auto|own|broad) ;;
    *) die "SCOPE must be auto|own|broad (got '$SCOPE')" ;;
  esac
}

# Does the TARGET repo carry its own pre-flight tool? When it does, the provisioning verdict does
# not depend on a tortoise checkout at all, so an operator's TORTOISE_REPO is irrelevant and must not
# draw the ambient-only warning below. Mirrors resolve_preflight() in refresh-candidates.sh (the
# scout worktree wins when it exists, else the main checkout).
repo_vendors_tool() {
  [ -f "$REPO/tools/collision_preflight.py" ] \
    || [ -f "$REPO/.worktrees/dispatch-scout/tools/collision_preflight.py" ]
}

# ── harness provenance (agent-infra#1745) ────────────────────────────────────────────────────────
# See the header block for the measured failure and why both halves of the record are needed.
HARNESS_REPO="${HARNESS_REPO:-}"
HARNESS_REF="${HARNESS_REF:-origin/main}"
HARNESS_PIN_DIR="${HARNESS_PIN_DIR:-$CELL_HOME/harness}"
HARNESS_PIN_FILE="${HARNESS_PIN_FILE:-$CELL_HOME/.harness-path}"
HARNESS_FETCH="${HARNESS_FETCH:-1}"
HARNESS_APPLIED=""
MIN_FREE_MB="${MIN_FREE_MB:-500}"
SCRATCH_DAYS="${SCRATCH_DAYS:-3}"
# Where review scratch checkouts accumulate. Parameterized so the destructive `--scratch` path can be
# driven hermetically by the test suite; a cell uses the default.
SCRATCH_ROOT="${SCRATCH_ROOT:-/tmp}"
STAMP="$O/.agent-infra-stamp.json"
# ⛔ A non-numeric floor silently disables the ONE check that exists because a full disk read healthy:
# `[ "$mb" -lt "$MIN_FREE_MB" ]` prints `integer expression expected` and evaluates FALSE, so the
# branch is never taken and the cell is blessed. Validated at load, where the operator still sees it.
case "$MIN_FREE_MB" in ''|*[!0-9]*|?????????*) die "MIN_FREE_MB must be a positive whole number of megabytes (got '$MIN_FREE_MB')" ;; esac
# ⛔ `00`, `000` and `010` are all digits, so a `case` allow-list cannot see that they evaluate to 0 —
# or, in arithmetic context, to OCTAL 8. Require a non-zero floor and normalise to base 10, so the one
# check that exists because a full disk read healthy cannot be disarmed by a spelling of zero. The
# digit cap matters too: bash arithmetic wraps at 2^63, so `18446744073709551617` (2^64+1) normalises
# to 1 — a huge floor silently became 1 MiB. 9 digits is ~1 PB, beyond any real cell.
[ "$((10#$MIN_FREE_MB))" -gt 0 ] || die "MIN_FREE_MB must be a positive whole number of megabytes (got '$MIN_FREE_MB')"
MIN_FREE_MB="$((10#$MIN_FREE_MB))"

# Resolution order, most explicit first: an operator's $HARNESS (env, and never overridden), then the
# path `apply` pinned, then this script's sibling harness, then the target repo's own scripts/ tree.
# Only an EMPTY $HARNESS reaches the fallbacks here.
if [ -z "$HARNESS" ] && [ -r "$HARNESS_PIN_FILE" ]; then
  HARNESS="$(head -1 "$HARNESS_PIN_FILE" 2>/dev/null)"
fi
if [ -z "$HARNESS" ]; then
  HARNESS="$(cd "$(dirname "${BASH_SOURCE[0]}")/orchestrator-harness" 2>/dev/null && pwd)"
fi
if [ -z "$HARNESS" ] && [ -d "$REPO/scripts/orchestrator-harness" ]; then
  HARNESS="$REPO/scripts/orchestrator-harness"
fi

# The checkout the ref resolves IN — one that carries `origin/main`. Preferred in this order so the
# usual operator path (`bash <clone>/scripts/cloud-cell-supervisor.sh …`) needs nothing extra set.
if [ -z "$HARNESS_REPO" ]; then
  for _cand in "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)" "$HARNESS" "$REPO"; do
    [ -n "$_cand" ] || continue
    # ⛔ The MAIN worktree, not `--show-toplevel`. `$HARNESS` may be a PIN, and a linked worktree's
    # own toplevel IS the pin — deriving HARNESS_REPO from it makes the pin its own repo, so
    # `harness_apply` would operate on (and could remove) the tree it is running from. The main
    # worktree is listed first and is the checkout that carries `origin/main`; for a plain checkout
    # the two answers are identical, so the usual operator path is unchanged.
    _cand_repo="$(git -C "$_cand" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print substr($0,10); exit}')"
    if [ -n "$_cand_repo" ]; then HARNESS_REPO="$_cand_repo"; break; fi
  done
  unset _cand _cand_repo
fi

# coreutils on the cell; shasum on a BSD userland. Both print `<hash>  <name>`.
SHA_CMD="sha256sum"
command -v sha256sum >/dev/null 2>&1 || SHA_CMD="shasum -a 256"

# Available MEBIBYTES. `df -Pk` reports 1KiB blocks, so its raw 4th column is KiB while every
# consumer here (`MIN_FREE_MB`, the `*2` auto-prune trigger, the `free …MB` reports) means MiB — and
# that mismatch made the 500 "MB" floor 500 KiB, so the measured 111 MiB cell read HEALTHY (the exact
# false pass this floor exists to remove). Convert once, here. Empty when df cannot answer — read as
# "cannot judge", never as "enough".
free_mb() { df -Pk "$1" 2>/dev/null | awk 'NR==2 && $4 ~ /^[0-9]+$/ {print int($4 / 1024)}'; }

# ⛔ `--verify --quiet` is load-bearing, not tidiness: a bare `git rev-parse <unknown>` ECHOES its
# argument to stdout (`git rev-parse origin/nope` prints `origin/nope`) while exiting non-zero — so a
# plain capture reads an unresolvable ref as a resolved one and the `unknown` verdict can never fire.
harness_commit() { git -C "$HARNESS" rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null; }
harness_subject() { git -C "$HARNESS" log -1 --format=%s 2>/dev/null | cut -c1-68; }

# HEAD's relation to $HARNESS_REF. Sets HARNESS_COMMIT / REF_COMMIT / HARNESS_REL (see the header).
classify_harness() {
  HARNESS_COMMIT=""; REF_COMMIT=""; HARNESS_REL=""
  [ -n "$HARNESS_REPO" ] || { HARNESS_REL="unknown"; return 0; }
  if [ "$HARNESS_FETCH" = 1 ]; then
    git -C "$HARNESS_REPO" fetch --quiet origin main >/dev/null 2>&1 || true
  fi
  REF_COMMIT="$(git -C "$HARNESS_REPO" rev-parse --verify --quiet "$HARNESS_REF^{commit}" 2>/dev/null)"
  [ -n "$REF_COMMIT" ] || { HARNESS_REL="unknown"; return 0; }
  HARNESS_COMMIT="$(harness_commit)"
  [ -n "$HARNESS_COMMIT" ] || { HARNESS_REL="untracked"; return 0; }
  [ "$HARNESS_COMMIT" = "$REF_COMMIT" ] && { HARNESS_REL="current"; return 0; }
  if git -C "$HARNESS_REPO" merge-base --is-ancestor "$HARNESS_COMMIT" "$REF_COMMIT" 2>/dev/null; then
    HARNESS_REL="behind"
  else
    HARNESS_REL="diverged"
  fi
}

# sha256 over the *.sh this script SEEDED into $O — the "did the running copy change after seeding"
# half. Empty when $O is absent (pre-start), and an empty digest is never read as a match: callers
# compare it against a recorded non-empty hash, and `[ "$recorded" != "$live" ]` is true for it.
o_payload_hash() {
  local f
  # ⛔ The `[ -d ]` guard is OUTSIDE the pipeline now. It used to sit inside a `{ …; } |` group, so its
  # `return` ended a SUBSHELL and `sha256sum` still hashed empty input — an absent $O returned the
  # well-known e3b0c442… digest instead of the empty string the comment (and the `-z "$live"`
  # cannot-verify guard in cmd_check_provenance) assume.
  [ -d "$O" ] || return 0
  (
    cd "$O" || exit 0
    for f in *.sh; do [ -f "$f" ] || continue; $SHA_CMD "$f"; done
  ) | $SHA_CMD | awk '{print $1}'
}

# One field out of the stamp. Anchored on the quoted KEY, so `commit` cannot match `refCommit`
# (there is no quote before the `c` inside it).
stamp_field() {
  [ -f "$STAMP" ] || return 0
  sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$STAMP" | head -1
}

# The same, for an UNQUOTED JSON value (a boolean). `stamp_field` is anchored on a quoted value, so
# it returns '' for a bare `true` — which would read a DIRTY record as "field absent" and, either
# way, be read as clean.
stamp_field_raw() {
  [ -f "$STAMP" ] || return 0
  sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\([^,}]*\).*/\1/p" "$STAMP" | tr -d ' "' | head -1
}

stamp_write() {
  local payload dirty tmp
  classify_harness
  payload="$(o_payload_hash)"
  # The dirty bit is READ LIVE and must not fail open: a `git status` that cannot run (corrupt index,
  # ENOSPC, EACCES, safe.directory) is CANNOT-VERIFY, never "clean" — the same rule the unreadable
  # `df` follows in cmd_check_disk.
  harness_dirty; local dirty_rc=$?
  case "$dirty_rc" in
    0) dirty=true ;;
    1) dirty=false ;;
    *) die "cannot verify whether the harness at ${HARNESS:-<unresolved>} is clean (git status failed) — refusing to record a provenance stamp that cannot be trusted" ;;
  esac
  # ⛔ TEMP-THEN-RENAME, never `cat > "$STAMP"`. An in-place write truncates the real stamp FIRST, so a
  # failure in that window (ENOSPC — the exact condition this whole change exists for) destroys the one
  # artifact that makes the surface checkable, where a valid record used to be. `seed_and_stamp` below
  # already stages its own writes for the same reason.
  tmp="$STAMP.tmp-$$"
  cat > "$tmp" <<STAMPEOF
{
  "version": 1,
  "surface": "cloud-cell",
  "harness": "$HARNESS",
  "commit": "${HARNESS_COMMIT:-}",
  "ref": "$HARNESS_REF",
  "refCommit": "${REF_COMMIT:-}",
  "relation": "${HARNESS_REL:-}",
  "agentInfraDirty": $dirty,
  "payloadSha256": "$payload",
  "recordedAt": "$(date -u +%FT%TZ)"
}
STAMPEOF
  mv -f "$tmp" "$STAMP" || { rm -f "$tmp"; die "cannot record the harness provenance at $STAMP"; }
}

# The harness's WORKING-TREE state, read live from $HARNESS. HEAD can equal the ref while the tree
# carries hand edits, and the recorded commit would then describe bytes that are not the ones seeded.
#   0 = DIRTY   1 = CLEAN   2 = CANNOT VERIFY (`git status` itself failed)
# ⛔ A caller MUST NOT read 2 as clean — cannot-verify is never a pass in this file, and the likeliest
# trigger is the full disk this change exists for (git status refreshing the index fails, rev-parse
# still succeeds).
harness_dirty() {
  local out
  out="$(git -C "$HARNESS" status --porcelain -- . 2>/dev/null)" || return 2
  [ -n "$out" ]
}

# Is <path> a LINKED worktree of <repo> — i.e. may this script `rm -rf` it? The MAIN working tree is
# deliberately excluded: `git worktree list` names it too, and it is the checkout that must never be
# deleted.
linked_worktree_of() {
  local repo="$1" p="$2" real main w list
  [ -n "$repo" ] && [ -n "$p" ] || return 1
  real="$(cd "$p" 2>/dev/null && pwd -P)" || return 1
  main="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" || return 1
  main="$(cd "$main" 2>/dev/null && pwd -P)"
  [ "$real" != "$main" ] || return 1
  # ⛔ MATERIALIZE the listing before comparing, and NORMALIZE each recorded path. A $TMPDIR-derived
  # path carries a `//` that git collapses in `worktree list` output, so a literal `grep -qxF`
  # reports our OWN worktree as foreign — the false block `assert_pin_dir_safe`'s comment names.
  # Here a false NEGATIVE is worse still: `cmd_prune` skips its reclaim sweep only because this
  # answers yes for a flat pin, so answering no would `rm -rf` the live harness's own directories.
  # ⛔ Not `… | grep -qxF`: an early exit down a pipe lets the producer take SIGPIPE, and under
  # `set -o pipefail` a MATCH would then be read as no match (measured in this file already).
  list="$(git -C "$repo" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print substr($0,10)}')" || return 1
  while IFS= read -r w; do [ "$(cd "$w" 2>/dev/null && pwd -P)" = "$real" ] && return 0; done <<<"$list"
  return 1
}

# `harness_apply` is about to `rm -rf` this path, and it is operator-settable — the silent-destruction
# class this file refuses everywhere else. The old guard refused only `""`, `/` and `.`: the three
# values an operator cannot plausibly set, while `HARNESS_PIN_DIR=$CELL_HOME` (or $HOME, or $O) drove
# `rm -rf` over the cell home — keys.env, the gate key, the orchestrator state dir. Require a POSITIVE
# allow instead: never an ancestor of anything this cell needs, and if it exists it must be a linked
# worktree of $HARNESS_REPO, an empty directory, or a pin ROOT holding only hex-named pin dirs.
#
# Is $1 a NAME `apply` could have produced for a pin directory? `apply` names each pin by the hex of
# the commit it pins to (`cut -c1-12` below), but the LENGTH is a MOVING CONVENTION, not a property
# of a commit id: git's own abbreviation length varies with repo size, and a revision of this script
# that used `git rev-parse --short` produced 8-character names. Measured 2026-10-16: three cells had
# been seeded by such a revision, and ONE 8-character directory made `apply` AND `start` both refuse
# ("Remove it by hand") while `check` still certified the cell — zero capacity behind a green
# verdict. So accept any unambiguous git abbreviation (7..40 hex chars) and leave the INTENT — "only
# pin directories" — intact: an operator's `notes/` or `backup-2026/` is still refused, not being hex.
#
# ⛔ THIS ANSWERS "COULD apply HAVE NAMED IT", NEVER "MAY I DELETE IT". An all-digit name (`20260116`
# — a date; `1718000000` — an epoch) is valid hex and satisfies this predicate while being no pin
# `apply` ever named. Only `pin_entry_owned` (a CONTENT test against $HARNESS_REPO) authorizes the
# `rm -rf`.
pin_name_ok() {
  local n="${1:-}"
  case "$n" in
    ???????*) ;;                   # at least 7 characters — git's minimum abbreviation
    *) return 1 ;;
  esac
  case "$n" in *[!0-9a-f]*) return 1 ;; esac   # hex only
  [ "${#n}" -le 40 ] || return 1               # at most a full sha
  return 0
}

# The pin-root CONFORMANCE question, asked ONCE — the answer `check`, `apply`, `start` and `prune`
# must all agree on. `check`'s verdict is "this cell can run a controller", and every sibling verb
# refuses a non-conforming root, so a `check` that skips this question certifies a cell its own verbs
# reject: the false PASS of agent-infra#1852, measured 2026-10-16 on all three cells.
# Returns 0 = conforms, 1 = does NOT conform (PIN_ROOT_BAD names why), 2 = CANNOT VERIFY.
#
# ⛔ CANNOT VERIFY IS NOT A PASS, on EITHER caller. An unreadable root used to read as an EMPTY (safe)
# one, because `ls -A`'s failure was swallowed by `2>/dev/null`; here the failure is surfaced as 2 and
# every caller refuses. The two callers fail closed to different things, and that direction is
# deliberate: for `check` a refusal IS the verdict (a root that cannot be read is not certified), and
# for `assert_pin_dir_safe` a refusal is a refusal to `rm -rf` (never reclaim blind).
# ⛔ The enumeration is `ls -A`, not a `"$dir"/*` glob: a glob skips HIDDEN entries and dangling
# symlinks, so a root whose only entry was `.DS_Store` read as EMPTY-AND-SAFE on the check side while
# the delete side refused the same root — the same false pass, one branch over. `ls -A` sees every
# entry, and each one must be a hex-named directory.
# ⛔ Deliberately NOT a per-entry `git worktree list` path comparison: on macOS a `$TMPDIR`-derived
# path carries a `//` that git normalizes in its listing output, so a literal comparison reports our
# OWN pin as foreign and the guard becomes a false block.
pin_root_conformance() {
  local dir="${1:-}" p listing entries=0
  PIN_ROOT_BAD=""
  case "$dir" in
    ""|"/"|".") PIN_ROOT_BAD="is '$dir'"; return 1 ;;
  esac
  # A root that CONTAINS anything this cell needs cannot be reclaimed, and every sibling verb refuses
  # it — so `check` must refuse it too, not certify a cell whose own `apply`/`start`/`prune` die here.
  for p in "$CELL_HOME" "$HOME" "$O" "$REPO" "$HARNESS_REPO" "$(dirname "$ENV_FILE")"; do
    [ -n "$p" ] || continue
    case "$p" in "$dir"|"$dir"/*) PIN_ROOT_BAD="CONTAINS $p, which this cell needs"; return 1 ;; esac
  done
  [ -e "$dir" ] || [ -L "$dir" ] || return 0               # nothing there: nothing to refuse
  linked_worktree_of "$HARNESS_REPO" "$dir" && return 0    # the legacy flat pin (root IS one worktree)
  [ -d "$dir" ] || { PIN_ROOT_BAD="$dir is not a directory"; return 1; }
  listing="$(ls -A "$dir" 2>/dev/null)" || return 2         # ⛔ a failed read is NOT an empty read
  [ -n "$listing" ] || return 0                             # genuinely empty (`ls -A` drops . and ..)
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    # A sibling verb can mutate the root between `ls -A` and this test. An entry that VANISHED is not
    # a nonconformity (it would name a directory that no longer exists); a dangling symlink still is
    # (`-L` true, `-d` false → refused), which is the property `ls -A` exists for.
    [ -e "$dir/$p" ] || [ -L "$dir/$p" ] || continue
    entries=$((entries + 1))
    if [ ! -d "$dir/$p" ] || ! pin_name_ok "$p"; then
      PIN_ROOT_BAD="holds '$p', which is not a pin directory"
      return 1
    fi
  done <<<"$listing"
  [ "$entries" -gt 0 ] && return 0
  return 2    # listed non-empty yet enumerated nothing: cannot verify
}

# The AUTHORITY TO DELETE one harness pin. `pin_name_ok` is a SPELLING test and cannot tell a pin from
# an operator's date-named directory: `20260116` and `1718000000` are valid hex. `apply` names a pin
# after a COMMIT in $HARNESS_REPO, so the only proof an entry is ours is a CONTENT test that its name
# resolves there. Returns 0 = provably ours, 1 = provably not, 2 = CANNOT VERIFY.
# ⛔ Fail-closed direction, stated and tested: `cmd_prune` — called UNATTENDED by `cmd_start` — must
# treat BOTH 1 and 2 as "do not reclaim". An invented-but-hex name was never ours (the widened 7..40
# pattern is what admitted `20260116`); and a blind reclaim against an unresolved $HARNESS_REPO is the
# silent-destruction class this file refuses. `check` never consults this, so an unresolved
# $HARNESS_REPO cannot turn a legitimate `check` into a false block.
# ⛔ This cannot reintroduce the per-entry path-comparison false block named above: it asks whether a
# NAME resolves in the repo and never compares a path, so a `$TMPDIR`-spelled pin still answers yes.
# ⛔ ACCEPTED RESIDUAL (the fail-closed direction): a pin whose commit object is gone (its detached
# worktree was removed by an `rm_cache` fallback and a later `gc` collected the object) can never be
# reclaimed — the sweep is not an authority for a name it cannot resolve. The `say` line in cmd_prune
# makes it visible rather than silent; the alternative (delete on an unprovable name) is the
# silent-destruction class this file refuses.
pin_entry_owned() {
  local n="${1:-}"
  pin_name_ok "$n" || return 1
  [ -n "$HARNESS_REPO" ] || return 2
  git -C "$HARNESS_REPO" rev-parse --git-dir >/dev/null 2>&1 || return 2
  git -C "$HARNESS_REPO" cat-file -e "${n}^{commit}" 2>/dev/null && return 0
  return 1
}

# The check-side caller: the SAME conformance question, with a message about the cell being unusable
# rather than about deleting a directory `check` never deletes.
cmd_check_pin_dir() {
  local rc
  pin_root_conformance "$HARNESS_PIN_DIR"; rc=$?
  case "$rc" in
    0) return 0 ;;
    2) die "HARNESS_PIN_DIR='$HARNESS_PIN_DIR' cannot be READ (permission denied or an I/O error), so whether it is a pin root is UNKNOWN — and cannot-verify is never a pass. Fix its permissions, or point HARNESS_PIN_DIR at a readable path, then re-run: $0 check   (agent-infra#1852)" ;;
  esac
  die "HARNESS_PIN_DIR='$HARNESS_PIN_DIR' $PIN_ROOT_BAD — 'apply' AND 'start' both refuse here, so this cell can neither be updated nor started. Quarantine it (move it aside; do not delete a directory you cannot account for) and re-run: $0 apply   (agent-infra#1852)"
}

# The delete-side caller, used by `harness_apply` and `cmd_prune`.
assert_pin_dir_safe() {
  local dir="$1" rc
  pin_root_conformance "$dir"; rc=$?
  case "$rc" in
    0) return 0 ;;
    2) die "refusing to rm -rf HARNESS_PIN_DIR='$dir': it cannot be READ (permission denied or an I/O error), so whether it is a pin root is UNKNOWN — and cannot-verify is not a pass here either." ;;
  esac
  die "refusing to rm -rf HARNESS_PIN_DIR='$dir': it $PIN_ROOT_BAD. Remove it by hand if you are sure it holds nothing."
}

# Pin the cell's harness to $HARNESS_REF in a detached worktree and record where it is. Idempotent:
# a $HARNESS already AT the ref is left exactly where it is (so an operator's `/tmp/harness-main` is
# never disturbed), and only a stale/hand-copied tree is replaced. This is the whole of "apply the
# proper harness" — `start` runs it before every launch, so no manual copy step exists any more.
harness_apply() {
  [ -n "$HARNESS_REPO" ] || die "cannot apply a harness: no git checkout resolved (set HARNESS_REPO=<agent-infra checkout>)"
  git -C "$HARNESS_REPO" rev-parse --git-dir >/dev/null 2>&1 || die "HARNESS_REPO=$HARNESS_REPO is not a git checkout — nothing to apply from"
  # ⛔ A failed fetch is NOT fatal while $HARNESS_REF still resolves locally, and that is what keeps
  # `check` and `start` from disagreeing on the same config (the measured divergence: `check` rc=0
  # while `apply`/`start` died during a transient outage, with nothing stale and nothing to fetch).
  # The fetch is about how FRESH the local ref is; `want` is what gets pinned, and pinning a local
  # commit needs no network. Only an unresolvable ref is fatal.
  local want dir cur fetch_failed=0
  if [ "$HARNESS_FETCH" = 1 ]; then
    git -C "$HARNESS_REPO" fetch --quiet origin main >/dev/null 2>&1 || fetch_failed=1
  fi
  want="$(git -C "$HARNESS_REPO" rev-parse --verify --quiet "$HARNESS_REF^{commit}" 2>/dev/null)"
  [ -n "$want" ] || die "cannot resolve $HARNESS_REF in $HARNESS_REPO$( [ "$fetch_failed" = 1 ] && printf ' after a failed git fetch — check the network' ) — cannot pin a harness to verify against"
  [ "$fetch_failed" = 1 ] && say "warn: git fetch failed in $HARNESS_REPO — cannot refresh $HARNESS_REF; using the local ref"
  # ⛔ THE CONFORMANCE GUARD RUNS ON EVERY PATH, INCLUDING THE NO-OP ONE. It used to sit inside the
  # re-pin `else` below, so `apply` on a cell whose harness was already at the ref returned 0
  # ("unchanged") without ever asking whether the pin root conforms — while `check`, `start` and
  # `prune` all refused it, and `check`'s message asserted that `apply` refused too. Same false PASS
  # class as #1852, on the verb whose job is "put the proper harness on this cell". The guard asks
  # about `$HARNESS_PIN_DIR` (the root), never about `$HARNESS`, so the documented "an operator's
  # /tmp/harness-main is never disturbed" behaviour is untouched.
  assert_pin_dir_safe "$HARNESS_PIN_DIR"
  cur="$(harness_commit)"
  # A DIRTY tree at the ref is NOT `unchanged`: its commit does not describe its bytes, and seeding it
  # records the ref over hand-edited worker code. A tree whose cleanliness cannot be VERIFIED is
  # treated the same way — re-pinning a clean worktree is always safe, reading an unverifiable tree as
  # clean is not. Pin a clean detached worktree instead — which also repairs the operator's
  # hand-maintained tree without disturbing it in place.
  harness_dirty; local hd_apply=$?
  if [ "$cur" = "$want" ] && [ -f "$HARNESS/orch-loop.sh" ] && [ "$hd_apply" = 1 ]; then
    HARNESS_APPLIED=unchanged
  else
    # ⛔ PIN PER COMMIT, and create-new rather than destroy-then-create. Pinning into ONE shared
    # $HARNESS_PIN_DIR meant `rm -rf` of the very tree the cell is running from, with the replacement
    # only created afterwards: a crash in that window (ENOSPC is exactly when it happens) leaves the
    # cell with NO harness at all, and the operator's only clue is a controller that will not start.
    # The previous pin now survives until `prune` reclaims it.
    dir="$HARNESS_PIN_DIR/$(printf '%s' "$want" | cut -c1-12)"
    # ⛔ The BASE is validated (the call is HOISTED above, so it covers the no-op path too), not the
    # per-commit child. Passing the child made the deny-list compare the wrong way round —
    # `HARNESS_PIN_DIR=$CELL_HOME` would put the child BELOW the cell home, so "does this path contain
    # the cell home" was false and the guard that exists to stop `rm -rf` over the cell home silently
    # stopped firing. The child is strictly under a validated root by construction.
    # ⛔ No bare `git worktree prune`. It has no path filter and deregisters EVERY record whose working
    # directory is missing, unrelated siblings included — and for a DETACHED worktree the admin HEAD is
    # the commit's last durable handle, so a later `gc` collects it (#1141; this repo forbids the call).
    # Only the single path being reused is removed.
    git -C "$HARNESS_REPO" worktree remove --force "$dir" >/dev/null 2>&1 || rm -rf "$dir"
    mkdir -p "$(dirname "$dir")" || die "cannot create $(dirname "$dir")"
    git -C "$HARNESS_REPO" worktree add --detach "$dir" "$want" >/dev/null 2>&1 \
      || die "git worktree add --detach $dir $want failed — free space ($0 prune) and retry"
    HARNESS="$dir/scripts/orchestrator-harness"
    [ -f "$HARNESS/orch-loop.sh" ] || die "the applied worktree carries no harness at $HARNESS"
    printf '%s\n' "$HARNESS" > "$HARNESS_PIN_FILE" || die "cannot record the applied harness path in $HARNESS_PIN_FILE"
    HARNESS_APPLIED=changed
  fi
  classify_harness
}

# Seed $O and record what was seeded. Kept separate from harness_apply() so `check` always runs
# AFTER a record exists on the start path — an unstamped cell must mean "nobody applied/started
# yet", never "start ran and failed to record".
#
# ⛔ SEEDING IS ATOMIC PER FILE (copy to a temp name, then `mv -f`), and that is load-bearing, not
# tidiness: a running controller's lanes execute `bash '$O/<worker>.sh'`, and a plain `cp` TRUNCATES
# the live script before rewriting it — so a spawn landing in that window runs a truncated worker.
# That window is what would make `apply --force` unsafe on the live cell it is meant to repair. A
# rename within one filesystem is atomic, so a spawn sees the old bytes or the new ones, never half.
seed_and_stamp() {
  local src f tmp n=0
  mkdir -p "$O/logs" "$O/state" || die "cannot create state dir $O"
  [ -d "$HARNESS" ] || die "no harness at $HARNESS to seed \$O from"
  for src in "$HARNESS"/*.sh; do
    [ -f "$src" ] || continue
    f="$(basename "$src")"; tmp="$O/.seed-$f.$$"
    cp -p "$src" "$tmp" || die "cannot stage $f into $O — free space ($0 prune)"
    mv -f "$tmp" "$O/$f" || { rm -f "$tmp"; die "cannot install $f into $O"; }
    n=$((n + 1))
  done
  [ "$n" -gt 0 ] || die "no *.sh scripts in $HARNESS — nothing to seed into $O"
  # ⛔ MIRROR, do not merely overlay. `orch-loop.sh`/`merge-one.sh` invoke workers BY NAME from $O, so a
  # script RENAMED upstream would leave its old copy live in $O and still invocable — the record would
  # describe the harness while the cell ran a worker the harness no longer ships.
  for f in "$O"/*.sh; do
    [ -f "$f" ] || continue
    [ -f "$HARNESS/$(basename "$f")" ] || { rm -f "$f"; say "seed: removed stale $(basename "$f") — the harness no longer ships it"; }
  done
  stamp_write || die "cannot record the harness provenance at $STAMP"
}

# A full disk is not a warning on a cell. MEASURED 2026-10-15: at 111MB free the controller log
# filled with `No space left on device` from claims.sh and orch-loop.sh while the loop kept running
# and reporting lanes — the same "failed precondition as success" shape this file refuses elsewhere,
# with the added cost that `git` writes fail too (so nothing can be reviewed, recorded or merged).
cmd_check_disk() {
  local mb; mb="$(free_mb "$CELL_HOME")"
  # ⛔ An unreadable df is NOT a pass. `free_mb` prints nothing when df is missing/unreadable, and
  # returning 0 here read that as "enough" — the opposite of what its own comment claims and of this
  # file's rule that cannot-verify is never a pass. A cell whose floor cannot be measured must not be
  # blessed as able to run a controller.
  case "${mb:-}" in
    ''|*[!0-9]*) die "cannot read the free space on $(dirname "$CELL_HOME") — df gave no usable answer, so the ${MIN_FREE_MB}MB floor cannot be enforced. Fix df/PATH before starting a cell." ;;
  esac
  if [ "$mb" -lt "$MIN_FREE_MB" ]; then
    die "only ${mb}MB free on $(dirname "$CELL_HOME") — below the ${MIN_FREE_MB}MB floor. At this level git writes and the controller's own state writes fail with I/O errors and the loop keeps reporting lanes. Free space first: $0 prune"
  fi
  if [ "$mb" -lt "$((MIN_FREE_MB * 4))" ]; then
    say "warn: ${mb}MB free on $(dirname "$CELL_HOME") — under $((MIN_FREE_MB * 4))MB. 'prune' reclaims the regenerable caches."
  fi
}

# The provenance half of `check`. Three refusals that CANNOT be mended by getting fresher (untracked,
# diverged, unknown) and one that can (behind) — see the header block for why.
cmd_check_provenance() {
  classify_harness
  local sc sp sr live sd hd_rc
  case "$HARNESS_REL" in
    current)
      say "ok: harness commit ${HARNESS_COMMIT:0:12} == $HARNESS_REF (${REF_COMMIT:0:12}) — $(harness_subject)" ;;
    behind)
      say "DRIFT — harness commit ${HARNESS_COMMIT:0:12} is BEHIND $HARNESS_REF (${REF_COMMIT:0:12}). It is on"
      say "       main's line, so 'start' would mend it — but a cell running it is a cell running old code."
      say "       Remedy: $0 apply" ;;
    diverged)
      say "DRIFT — harness commit ${HARNESS_COMMIT:0:12} is NOT an ancestor of $HARNESS_REF (${REF_COMMIT:0:12})."
      say "       This is the measured 2026-10-14 incident: a tree off main's line merged real PRs off the"
      say "       shared queue while check called the cell healthy. Refusing."
      say "       Remedy: $0 apply   (pins to $HARNESS_REF in $HARNESS_PIN_DIR)" ;;
    untracked)
      say "DRIFT — the harness at ${HARNESS:-<unresolved>} has NO git identity, so 'which commit is this cell"
      say "       running?' has no answer. A hand-placed copy is this cell's oldest failure mode (#1745)."
      say "       Remedy: $0 apply   (pins to $HARNESS_REF in $HARNESS_PIN_DIR)" ;;
    *)
      say "DRIFT — cannot verify the harness: $HARNESS_REF does not resolve in ${HARNESS_REPO:-<no checkout resolved>}."
      say "       Cannot-verify is never a pass. Remedy: set HARNESS_REPO to an agent-infra checkout, then $0 apply" ;;
  esac
  case "$HARNESS_REL" in
    current|behind) ;;
    *) die "harness provenance: DRIFT ($HARNESS_REL) — nothing was started; see the lines above";;
  esac
  # ⛔ A DIRTY working tree at the ref is NOT `current`. HEAD can equal the ref while the tree carries
  # hand edits, and `harness_apply` deliberately leaves such a tree where it is — so the commit is
  # recorded over bytes it does not describe, and `start` seeds exactly those bytes. This is read LIVE
  # (catches an edit made AFTER the record; the payload hash only covers $O). Before this,
  # `agentInfraDirty` was written by stamp_write and never read by anything.
  harness_dirty; hd_rc=$?
  case "$hd_rc" in
    0) die "DRIFT — the harness working tree at ${HARNESS:-<unresolved>} has UNCOMMITTED changes, so commit ${HARNESS_COMMIT:0:12} does not describe the bytes that will run. Commit or discard them, then $0 apply" ;;
    2) die "cannot verify whether the harness at ${HARNESS:-<unresolved>} is clean (git status failed) — cannot-verify is never a pass. Remedy: repair git (disk, index, ownership), then $0 check" ;;
  esac
  if [ -f "$STAMP" ]; then
    sc="$(stamp_field commit)"; sp="$(stamp_field payloadSha256)"; sr="$(stamp_field relation)"
    live="$(o_payload_hash)"
    if [ -z "$sp" ] || [ -z "$live" ] || [ "$sp" != "$live" ]; then
      die "DRIFT — the seeded copy at $O changed AFTER it was recorded (recorded payload ${sp:0:12} vs live ${live:0:12}). Something edited the running harness by hand; a copy that differs from its own record is the failure #1745 exists to expose. Remedy: $0 apply"
    fi
    if [ -n "$HARNESS_COMMIT" ] && [ -n "$sc" ] && [ "$sc" != "$HARNESS_COMMIT" ]; then
      die "DRIFT — $O was recorded from ${sc:0:12} but the harness now at $HARNESS is ${HARNESS_COMMIT:0:12}: the tree moved under the record. Remedy: $0 apply"
    fi
    # The RECORDED dirty bit, consulted at last — a dirty SEED whose source was cleaned afterwards is
    # still a seeded copy whose commit does not describe its bytes. A field that is absent or blank is
    # CANNOT-VERIFY and never clean: a record that does not say whether its source was clean cannot
    # answer whether its commit describes its payload (the same rule check-version-stamp.mjs applies
    # to the sibling stamp).
    sd="$(stamp_field_raw agentInfraDirty)"
    [ "$sd" = false ] || die "DRIFT — the record at $STAMP does not say its source was CLEAN (agentInfraDirty=${sd:-<absent>}); a dirty record's commit does not describe the seeded bytes. Remedy: $0 apply"
    say "ok: recorded install — commit ${sc:0:12}, relation '${sr}', payload ${sp:0:12}"
  elif tmux has-session -t "$SESSION" 2>/dev/null; then
    die "a controller is RUNNING (tmux '$SESSION') with NO harness provenance recorded at $STAMP — 'which commit is this cell running?' has no answer for a live merge actor. Remedy: stop, then $0 apply"
  else
    say "ok: no install recorded yet (pre-start) — 'start' or 'apply' writes $STAMP"
  fi
}

# ── check: can this cell actually run a controller? ─────────────────────────────
cmd_check() {
  validate_scope
  [ -d "$CELL_HOME" ] && [ -w "$CELL_HOME" ] || die "HOME=$CELL_HOME missing or not writable"
  if [ ! -d "$HARNESS" ]; then
    # The remedy depends on WHY the path is absent. When `$HARNESS` is the path the RECORD names,
    # "clone the repo first" is the one action that cannot help — the record is stale and `apply` is
    # the repair. (Reachable since the pin became authoritative: the sibling default no longer masks a
    # pin that was reclaimed or deleted by hand.)
    if [ -n "$(head -1 "$HARNESS_PIN_FILE" 2>/dev/null)" ] && [ "$HARNESS" = "$(head -1 "$HARNESS_PIN_FILE" 2>/dev/null)" ]; then
      die "harness not found at $HARNESS — that is the path RECORDED in $HARNESS_PIN_FILE and it no longer exists. Remedy: $0 apply"
    fi
    die "harness not found at $HARNESS (clone the repo first)"
  fi
  [ -f "$HARNESS/orch-loop.sh" ] || die "$HARNESS/orch-loop.sh missing"
  # ⛔ `check`'s verdict IS "this cell can run a controller", and `apply`/`start` both refuse on a
  # non-conforming pin root. Asking every OTHER question in this function while skipping this one is
  # a FALSE PASS on exactly the question the verdict answers — measured 2026-10-16: `check` printed
  # every ok line and "CELL CAN RUN A CONTROLLER" on cells whose `apply` and `start` both died on an
  # 8-character pin directory (agent-infra#1852).
  cmd_check_pin_dir
  command -v tmux >/dev/null 2>&1 || die "tmux missing (the lanes depend on it)"
  # ⛔ RUNTIME DEPENDENCIES, not just the binaries this block already named (#1717). Each one is
  # INVOKED by the loop, and each one absent turns a step into a silent no-op or an unbounded paid
  # retry — so a cell missing one must not be certified:
  #   git     → worktree/fetch/push in fix-one.sh, dispatch-merge.sh, adopt-fix.sh. Nothing else
  #             tests it: the `-d $REPO/.git` check below passes on a box with no git at all.
  #   python3 → orch-loop.sh's check classifier and fix-one.sh's FAILING_CHECKS. Absent, the
  #             classifier's $V is EMPTY, NO case arm matches, and every PR is skipped in silence —
  #             a dead sweep that is indistinguishable from a quiet queue.
  #   pi      → the worker runtime (lane.sh, fix-one.sh, merge-one.sh). Absent, every review and
  #             every fixer fails 127 and the cell produces nothing.
  # All three are fatal HERE because a cell invokes each directly (above). Parity with install.sh is
  # true for `pi` only: install.sh's fatal gate is `for bin in tmux gh pi` (install.sh:84), and it
  # never probes git or python3. The requirement is this script's own, not a mirrored one.
  local dep
  for dep in git python3 pi; do
    command -v "$dep" >/dev/null 2>&1 || die "$dep missing on PATH — the loop invokes it (harness README §3)"
  done
  # uv is the ONE non-fatal dependency (its absence only stops a lane syncing its worktree venv),
  # and install.sh warns rather than dying for it — so the two surfaces agree.
  command -v uv >/dev/null 2>&1 || say "warn: uv missing — lane.sh cannot sync a worktree venv, so in-lane tests will fail (non-fatal, as in install.sh)"
  gh auth status >/dev/null 2>&1 || die "gh not authenticated — run cloud-cell-bringup.sh --check"
  [ -d "$REPO/.git" ] || [ -f "$REPO/.git" ] || die "no git repo at $REPO"
  # ⛔ A LINKED WORKTREE HAS A `.git` FILE, NOT A DIRECTORY (agent-infra#1745). The old `-d` test
  # refused a worktree with "FATAL: no git repo at <path>" even though every git command in it works
  # — a false block that forced operators to keep a full clone around for `REPO` while running the
  # harness from a worktree. `rev-parse --git-dir` is the real question; ask it instead.
  git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 \
    || die "$REPO is not a git checkout (no .git directory or linked-worktree .git file)"
  cmd_check_disk
  mkdir -p "$O/logs" "$O/state" || die "cannot create state dir $O"
  # orch-loop.sh spawns its workers as `bash '$O/<script>'` (fix-one.sh, merge-one.sh, …), NOT
  # from $HARNESS. cmd_start seeds $O from $HARNESS; assert it, so a stale/empty $O is a loud
  # failure rather than a controller that runs the inline sweep but can never review, fix or
  # dispatch — a false "CELL CAN RUN A CONTROLLER".
  # claims.sh and repo-authority.sh are included because orch-loop.sh and merge-one.sh SOURCE
  # them from $O: without them the cross-box claim silently degrades to the fail-open path
  # (logged, but not the design), and the controller dies with exit 78 on the per-repo merge
  # contract — a false "CELL CAN RUN A CONTROLLER" (repo-authority.sh, review round 4).
  say "ok: HOME, harness, tmux, gh auth, repo, state dir"
  local missing="" w
  for w in orch-loop.sh claims.sh repo-authority.sh dispatch-merge.sh lane.sh chain-merge.sh merge-one.sh fix-one.sh refresh-candidates.sh adopt-fix.sh; do
    [ -f "$O/$w" ] || missing="$missing $w"
  done
  [ -z "$missing" ] || die "worker scripts missing from $O:$missing — run 'start' (it seeds $O) or: cp '$HARNESS'/*.sh '$O'/"

  # ── which commit is this cell running? (agent-infra#1745) ────────────────────────────────────
  # Placed BEFORE the dispatch-provisioning probe: a tree off main's line can pass every later
  # check, and this is the one that says the code itself is not the code we think it is.
  cmd_check_provenance

  # ── dispatch provisioning: can this repo be pre-flighted? (agent-infra#1736) ──────────────────
  # The refresh step refills the dispatch backlog, and orch-loop.sh runs it in a BACKGROUNDED
  # subshell — so a refresh that aborts every cycle cannot fail the loop: the controller reports
  # RUNNING with `lanes: 0` forever and the cell is MERGE-ONLY (measured 2026-10-14 on the first
  # cmux cloud cell, pointed at agent-infra). This is the last gate before a cell is started, so a
  # repo that cannot be provisioned for dispatch is refused HERE, with the reason, instead of
  # being discovered later as silence. The probe is refresh-candidates.sh's own read-only `--check`.
  [ -f "$HARNESS/refresh-candidates.sh" ] \
    || die "$HARNESS/refresh-candidates.sh missing — cannot judge whether this repo can be provisioned for dispatch"
  local pv
  if ! pv="$(REPO="$REPO" OR="$OR" O="$O" bash "$HARNESS/refresh-candidates.sh" --check 2>&1)"; then
    printf '%s\n' "$pv" >&2
    die "this repo cannot be provisioned for dispatch (a cell started on it could only MERGE) — see the reason above (agent-infra#1736)"
  fi
  printf '%s\n' "$pv" | sed 's/^/    /'
  say "ok: dispatch provisioning — this repo can be pre-flighted, so lanes will be dispatched"
  # ⛔ The probe above runs in THIS shell, so an AMBIENT TORTOISE_REPO makes it pass — but the
  # controller session will NOT receive it: the session re-sources $ENV_FILE and its command line
  # carries only HOME REPO O OR SCOPE, and on a PRE-EXISTING tmux server a session is served the
  # SERVER's environment (measured on tmux 3.4). The refresh would then resolve no checkout, exit
  # rc=3, and the cell would be MERGE-ONLY — after `check` and `start` both blessed it. This is the
  # same trap cmd_check already guards for the gate key (an ambient-only key is named as NOT
  # delivered); the provisionability verdict had no equivalent guard. Warn while the operator can
  # still fix it, and only when the verdict actually DEPENDED on that checkout: a repo that vendors
  # its own tool does not care, and a value $ENV_FILE carries is delivered by the session's own
  # source. (agent-infra#1748 review)
  if ! repo_vendors_tool && [ "$TORTOISE_IN_FILE" != 1 ]; then
    local ambient=""
    [ -n "${TORTOISE_REPO:-}" ] && ambient="TORTOISE_REPO"
    [ -n "${TORTOISE:-}" ] && ambient="${ambient:+$ambient and }TORTOISE"
    if [ -n "$ambient" ]; then
      say "warn: the dispatch-provisioning probe passed using this shell's ambient $ambient, which"
      say "      $ENV_FILE does not carry. The controller session re-sources $ENV_FILE and does not"
      say "      receive an ambient export on a pre-existing tmux server, so it would resolve no"
      say "      tortoise checkout, refuse with rc=3, and leave the cell MERGE-ONLY."
      say "      Fix: put TORTOISE_REPO=<a tortoise checkout> in $ENV_FILE, or vendor tools/collision_preflight.py into the repo."
    fi
  fi
  # ⛔ THE RECORD STEP IS A HARD DEPENDENCY OF THE ONLY MERGE PATH (#1717). merge-one.sh mints the
  # signed marker ai-review-gate verifies by RUNNING this file, and neither cell script used to
  # check or provision it. The pre-fix failure: cmd_check printed "CELL CAN RUN A CONTROLLER", the
  # cell ran a full fresh-context review (up to REVIEW_TIMEOUT = 1800 s, PAID), record-review.sh
  # then returned 127, and merge-one.sh exited BEFORE writing a parked marker — so the next cycle
  # saw an unmarked FAILED:ai-review-gate and spawned another review. One paid review per cycle,
  # forever, with no terminal state. Refuse the certification instead.
  # Judge the path the CONSUMER uses: the session forces HOME=$CELL_HOME after sourcing keys.env.
  # Presence + executability are NOT enough: the file must be a non-empty REGULAR file. `[ -x ]` is
  # true for a directory (`merge-one.sh` then buys the paid review and fails 126), and an EMPTY file
  # is executable too — bash runs a shebang-less empty script and it exits 0, minting no marker. So
  # an empty recorder would be certified, the gate would never go green, nothing would be parked,
  # and the loop would re-pay for a fresh review every cycle: the same #1717 loop, one input over.
  # The sibling check below already reasons about the zero-byte shape; judge the recorder the same way.
  local rec; rec="$(recorder_path)"
  if [ ! -e "$rec" ]; then
    die "record-review.sh MISSING at $rec — it is the only merge path, so every review would be re-paid for and never recorded. 'start' provisions it from $(recorder_src), or: cp '$(recorder_src)' '$rec' && chmod +x '$rec'"
  elif [ ! -f "$rec" ]; then
    die "record-review.sh at $rec is NOT A REGULAR FILE — merge-one.sh runs it directly, so a directory (or any other non-regular file) fails (126) AFTER a paid review. Remove it and re-run 'start', or: rm -rf '$rec' && cp '$(recorder_src)' '$rec' && chmod +x '$rec'"
  elif [ ! -s "$rec" ]; then
    die "record-review.sh at $rec is EMPTY (0 bytes) — an empty file is executable and exits 0 WITHOUT minting the signed marker, so the gate could never go green, nothing would be parked, and the loop would re-pay for a fresh review every cycle. Re-provision it: 'start', or: cp '$(recorder_src)' '$rec' && chmod +x '$rec'"
  elif [ ! -x "$rec" ]; then
    die "record-review.sh at $rec is NOT EXECUTABLE — merge-one.sh runs it directly, so the record step would fail (126) AFTER a paid review. Fix: chmod +x '$rec'"
  fi
  # The recorder's OWN runtime dependency (#1362/#1717): it resolves lib/diff-normalize.py from its
  # sibling directory. Absent, the recorder still runs — but it takes the RAW pre-#1362 digest arm
  # (`⚠️ #1362` warning in its output), the marker's diff_sha256 stops matching what the consumer
  # computes live, and EVERY base-only head move (`gh pr update-branch`) refuses carry-forward and
  # buys a fresh PAID review. Certifying a cell in that state is the same false PASS this block
  # exists to remove, one step down the cost ladder. Judge it beside the recorder it belongs to.
  local reclib; reclib="$(recorder_lib_path)"
  if [ ! -f "$reclib" ] || [ ! -s "$reclib" ]; then
    die "diff-normalize.py MISSING (or not a regular file, or empty) at $reclib — record-review.sh resolves it as its own sibling, and without it every base-only update re-pays for a fresh review. 'start' provisions it from $(recorder_lib_src), or: mkdir -p '$(dirname "$reclib")' && cp '$(recorder_lib_src)' '$reclib' && chmod +x '$reclib'"
  fi
  say "ok: record step present and executable ($rec, with $(recorder_lib_path))"

  # Judge the key by what the SESSION will receive, not by what this shell happens to hold: the key
  # FILE is authoritative, and a key in $ENV_FILE reaches the session because the session re-sources
  # it. An ambient-only export does NOT — tmux serves a new session from the server's environment —
  # so it is named rather than silently counted as present.
  # ⛔ ORDER MATTERS. The consumer is env-FIRST: it takes $ENV_FILE's value when non-empty and only
  # then falls back to the key file. A whitespace-only value in keys.env therefore SHADOWS a valid
  # key file (the raw value is non-empty, so the fallback never runs, and the normalized value is
  # empty) — so that case must be checked BEFORE the file, and reported as a failure, not a "present".
  if [ -n "$KEY_IN_FILE" ]; then
    say "ok: merge authority key present in $ENV_FILE — the controller re-sources it. On the"
    say "    'start' path (the only supported launch) the MERGE WORKERS it spawns across the second"
    say "    tmux boundary get it too: 'start' publishes $WORKER_ENV_NAMES into tmux update-environment"
    say "    and dies rather than start a cell where that publication fails."
  elif [ "$KEY_IN_FILE_SET" = 1 ]; then
    say "warn: AI_REVIEW_GATE_KEY in $ENV_FILE is WHITESPACE-ONLY. The consumer strips whitespace,"
    say "      so it resolves to EMPTY — and because the env value wins, it will NOT fall back to"
    say "      $CELL_HOME/.pi/agent/.ai-review-gate-key. Every review would be recorded UNSIGNED."
    say "      Fix: remove the key line from $ENV_FILE, or give it a real value."
  elif keyfile_has_key; then
    say "ok: merge authority key present ($CELL_HOME/.pi/agent/.ai-review-gate-key) — the MERGE"
    say "    WORKERS read it at \$HOME: 'start' carries HOME as one of $WORKER_ENV_NAMES into tmux"
    say "    update-environment, and a server it CREATES inherits it, so \$HOME is $CELL_HOME in every"
    say "    spawned worker."
  else
    local kfpath="$CELL_HOME/.pi/agent/.ai-review-gate-key"
    if [ -n "${AI_REVIEW_GATE_KEY:-}" ]; then
      say "warn: AI_REVIEW_GATE_KEY is set in THIS shell but not in $ENV_FILE — the controller"
      say "      session will NOT receive it: tmux serves a new session the SERVER's environment, and"
      say "      'start' drops this shell's export before creating the session, so it cannot be delivered."
      say "      Write it to $ENV_FILE, or to $kfpath."
    elif [ -e "$kfpath" ] && [ ! -r "$kfpath" ]; then
      # EXISTING but UNREADABLE is neither missing nor empty, and the remedy differs: prescribing
      # "write a key file" for a file that may already hold a valid key reproduces the fault.
      say "warn: $kfpath exists but is NOT READABLE — treated as absent."
      say "      It may already hold a valid key: check its mode and its parent directories (want 600)."
    else
      say "warn: no AI_REVIEW_GATE_KEY and no $kfpath."
    fi
    say "      ⛔ This does NOT make the cell safe to co-run: absence of the key does not stop"
    say '         `gh pr merge --auto` (measured: it armed auto-merge on #8425/#8420). A started'
    say "         cell is a MERGE ACTOR regardless of the key."
  fi
  say "⛔ COLLISION: orch-loop.sh takes BROAD scope above 10 open PRs, so an UNPINNED cell drains"
  say "   the SHARED queue. Measured 2026-10-13: a fresh cell logged '[scope] open=14 -> BROAD' and"
  say "   began re-recording/auto-arming within ~25s. Fix: pin every cell but ONE with SCOPE=own"
  say "   (orch-loop.sh's SCOPE override), or fix #5052, BEFORE starting a second controller."
  say "   ⛔ The pin is a PARTITION, not a fix for the root: ownership is still inferred from LOCAL"
  say "      branches/worktrees (#4256), invisible across machines, so two OWN-pinned cells can still"
  say "      race the same PR."
  say "CELL CAN RUN A CONTROLLER"
}

# ── start: controller under tmux (the launchd substitution) ─────────────────────
cmd_start() {
  # Refuse a bad SCOPE before anything starts or is written (validate_scope is also the first thing
  # cmd_check does below — this call is what keeps the refusal ahead of the $O seed).
  validate_scope
  # Guard BEFORE seeding. $O is the controller's working copy and `start` on a live cell would
  # otherwise replace the worker scripts its next spawn executes (and race a half-copied script).
  # Nothing is started or written on this path, so a bad value below cannot hurt it.
  if tmux has-session -t "$SESSION" 2>/dev/null; then
    say "already running (tmux session '$SESSION') — use: status | logs | stop"
    return 0
  fi
  # Every value below is interpolated into the session command string, so every one must be
  # metacharacter-free — refuse loudly here rather than let tmux's sh -c parse it. Empty values
  # are skipped (cmd_check reports an unresolvable HARNESS with its own message).
  local v
  for v in O REPO CELL_HOME ENV_FILE HARNESS OR HARNESS_REPO HARNESS_PIN_DIR HARNESS_PIN_FILE; do
    [ -n "${!v}" ] || continue
    safe_argv "${!v}" || die "\$$v must not contain a quote or shell metacharacter: ${!v}"
  done
  # ── the harness this cell will run, fixed BEFORE anything is seeded (agent-infra#1745) ────────
  # `start` is the one command that applies the proper harness: fetch, pin to $HARNESS_REF in a
  # detached worktree, seed, record. A cell therefore cannot be started on a stale or hand-copied
  # tree, and the operator's manual copy step is gone. A live session already returned at the guard
  # above, so the cache prune below cannot pull a venv out from under a running lane — which is why
  # it is safe to run unattended here and not on the explicit `prune` path.
  local mb; mb="$(free_mb "$CELL_HOME")"
  case "${mb:-}" in
    ''|*[!0-9]*) ;;
    *) if [ "$mb" -lt "$((MIN_FREE_MB * 2))" ]; then
         # ⛔ The controller session is NOT the only thing running: orch-loop.sh spawns its workers
         # into their OWN detached sessions (`fix-<PR>`, `merge-<PR>`), and `stop` kills only the
         # controller — so after a `stop` a worker can still be mid-review. `cmd_prune --caches`
         # deletes `.venv` at every worktree root, which makes the lane using it re-resolve its deps
         # (the manual `prune` path warns about exactly this). Skip the unattended delete while any
         # worker session is alive, and report the low-space state instead of acting.
         # ⛔ `grep -c`, NOT `grep -q`. An early exit down a pipe lets the producer take SIGPIPE, and
         # under `set -o pipefail` the pipeline then reports the producer's failure — so a MATCH read
         # as "no workers" and the unattended prune deleted a LIVE worker's .venv. `-c` consumes all
         # input. (`tmux ls | grep -c` below is already the safe form.)
         if [ "$(tmux ls 2>/dev/null | grep -cE '^(lane|fix|merge)-')" -gt 0 ]; then
           say "warn: only ${mb}MB free, but worker sessions are still running — NOT auto-pruning caches (a pruned venv breaks the lane using it). Run '$0 prune' once they finish."
         else
           cmd_prune --caches
         fi
       fi ;;
  esac
  harness_apply
  seed_and_stamp
  say "harness: ${HARNESS_COMMIT:0:12} (${HARNESS_REL}) at $HARNESS${HARNESS_APPLIED:+ [applied]}"
  # Re-check the value harness_apply() may have REPLACED: the loop above validated the one that was
  # set when the shell started, and an unreplaced-but-unsafe derived path would otherwise reach the
  # tmux command string unguarded.
  safe_argv "$HARNESS" || die "\$HARNESS must not contain a quote or shell metacharacter: $HARNESS"
  # Provision the record step (#1717). The seed itself is main's `seed_and_stamp` above (#1745), so
  # only the recorder is added here: a hard dependency of the ONLY merge path, and absent on a fresh
  # cell. Provisioned when ABSENT OR EMPTY (never merely because an `-e` test failed), so an
  # operator's complete newer copy is never clobbered — while a partial/zero-byte one cannot persist
  # across restarts. NEVER overwritten by whatever a keys.env points at. Resolved AFTER harness_apply:
  # recorder_src() follows $HARNESS, which harness_apply may have repointed at the pinned worktree.
  local rec rsrc rlib rlibsrc rtmp ltmp
  rec="$(recorder_path)"; rsrc="$(recorder_src)"
  rlib="$(recorder_lib_path)"; rlibsrc="$(recorder_lib_src)"
  # `[ ! -s ]`, not `[ ! -e ]`: a ZERO-BYTE recorder (a copy killed mid-write, or a full disk) is
  # the same fault as an absent one and must not survive a retry — it is worse than absent, because
  # it exits 0 without minting a marker, so nothing is parked and the loop re-pays (#1717).
  if [ ! -s "$rec" ]; then
    [ -e "$rec" ] && [ ! -f "$rec" ] && die "$rec exists but is not a regular file — remove it, then re-run 'start'"
    mkdir -p "$(dirname "$rec")" || die "cannot create $(dirname "$rec")"
    # Atomic: write a sibling tmp then rename into place, so a concurrent reader can never observe a
    # half-written recorder (the same reason pi-bootstrap/setup.sh farms its libs to a tmp + mv).
    rtmp="${rec}.tmp.$$"
    cp -p "$rsrc" "$rtmp" 2>/dev/null || { rm -f "$rtmp"; die "record-review.sh missing at $rec and cannot provision it from $rsrc — the harness checkout must be a full agent-infra checkout"; }
    chmod +x "$rtmp" || { rm -f "$rtmp"; die "cannot make $rec executable"; }
    mv -f "$rtmp" "$rec" || { rm -f "$rtmp"; die "cannot install the provisioned recorder at $rec"; }
    say "provisioned record step: $rsrc -> $rec"
  fi
  # …and its declared sibling, ALWAYS (not only when the recorder was absent): an operator's older
  # recorder copy can sit beside a missing lib, and cmd_check below refuses that cell. Preserve the
  # relative position (scripts/record-review.sh <-> scripts/lib/diff-normalize.py) and refresh only
  # when ABSENT, so a newer operator copy is never clobbered — same rule as the recorder above.
  if [ ! -f "$rlib" ] || [ ! -s "$rlib" ]; then
    [ -e "$rlib" ] && [ ! -f "$rlib" ] && die "$rlib exists but is not a regular file — remove it, then re-run 'start'"
    mkdir -p "$(dirname "$rlib")" || die "cannot create $(dirname "$rlib")"
    ltmp="${rlib}.tmp.$$"
    cp -p "$rlibsrc" "$ltmp" 2>/dev/null || { rm -f "$ltmp"; die "diff-normalize.py missing at $rlib and cannot provision it from $rlibsrc — the harness checkout must be a full agent-infra checkout"; }
    chmod +x "$ltmp" || { rm -f "$ltmp"; die "cannot make $rlib executable"; }
    mv -f "$ltmp" "$rlib" || { rm -f "$ltmp"; die "cannot install the provisioned normalizer at $rlib"; }
    say "provisioned record-step library: $rlibsrc -> $rlib"
  fi
  # The key verdict must NOT be swallowed on the only path that starts a cell: an operator who
  # exported the key ambiently (or left an empty assignment in keys.env) would otherwise get a
  # keyless cell with no signal. Run the check once, fail loudly, and surface its output on stderr.
  local chk
  if ! chk="$(cmd_check 2>&1)"; then printf '%s\n' "$chk" >&2; exit 1; fi
  # A probe that just PASSED makes a stale MERGE-ONLY marker wrong: clear it here, so an operator
  # who fixed the repo (or the TORTOISE path) is not left blocked by a flag recording a past state
  # until they remember to delete it. (agent-infra#1736)
  rm -f "$O/.refresh-blocked"
  # ⛔ Print the WHOLE verdict — do NOT filter it by matching the verdict prose. Line-matching was
  # tried and failed three times: each verdict is several lines, and any pattern keyed on the first
  # line silently drops the continuation — the remedy ("Fix: remove the key line…") and the warning
  # that a keyless cell is still a MERGE ACTOR. The block is printed verbatim; `die` already does the
  # same on the failure path.
  printf '%s\n' "$chk" >&2
  # The harness's own single-instance lock is per-cell ($O/.orch.lock), so this tmux guard
  # is what stops two controllers on THIS cell; cross-cell duplication is a separate
  # problem (#5052) and is NOT solved here.
  # ⛔ The tmux SERVER supplies a new session's environment, not this shell: once a server exists
  # (normal after `stop`, or while lanes run) an exported HOME/key/tunable is silently dropped —
  # measured for SCOPE, and the same mechanism applies to every other variable (a rotated
  # key in $ENV_FILE would be ignored, and a pinned MAX_LANES would revert to its default). So the
  # session re-sources $ENV_FILE itself and the values below are set inside the session, AFTER it.
  # The merge key is NOT passed on this command line: a secret in an argv string is visible to
  # `ps`/tmux, and it would have to be interpolated unguarded. It reaches the session through
  # $ENV_FILE instead — which is why cmd_check judges the key by the file, not by this shell's env.
  # ⛔ The worker hop is the SECOND boundary and this command line is the FIRST: re-sourcing $ENV_FILE
  # here gets the key only as far as orch-loop.sh. publish_worker_env() below publishes the NAMES
  # into tmux's update-environment, so the sessions orch-loop.sh spawns copy the VALUES out of the
  # controller's environment. (Names, never values, on every tmux command line.) On a cold start
  # there is no server to publish into — the `new-session` just below creates it from this shell,
  # which already holds the same names — so publish_worker_env() only acts on an EXISTING one.
  # Put any other tunable in $ENV_FILE rather than exporting it in an operator shell.
  # The session re-sources $ENV_FILE in ITS shell (same uncontrolled file). The `[ -f ]` guard keeps
  # an absent file from printing an open error, and `2>/dev/null` is GONE: suppressing it also hid
  # a keys.env that fails to parse, so the controller ran on a partially-set environment with no
  # signal in the log. A top-level `exit` here still ends the session, which the `sleep 3`
  # has-session check below already turns into a loud failure.
  # ⛔ Drop an AMBIENT-ONLY key from THIS shell before anything is published or created. Publishing
  # the NAME makes whatever this shell holds copyable into the session — the creating client here is
  # this very shell — so an export `cmd_check` has just called a misconfiguration ("set in THIS shell
  # but not in $ENV_FILE") would be delivered anyway, falsifying that verdict. Worse,
  # `record-review.sh` resolves the key env-FIRST, so a stale ambient export would SHADOW an
  # authoritative key FILE in every worker and sign reviews with the wrong value while the preflight
  # printed ok — a false PASS of exactly the class this fix exists to remove. keys.env was ALREADY
  # sourced above, so a key IT carries — a real value, or a whitespace-only one — is KEPT, and is
  # what makes `cmd_check`'s verdict true. Only a key `$ENV_FILE` does NOT carry is dropped: the key
  # FILE is deliberately NOT consulted in this condition, because an ambient export would shadow that
  # very file in every worker. The `unset` also strips the name from a session whose SERVER still
  # carries an older value: `update-environment` REMOVES a listed name the creating client lacks.
  # A whitespace-only keys.env value is deliberately NOT dropped — it is a state `cmd_check` names
  # explicitly, and leaving it is what makes that warning true.
  if [ -z "$KEY_IN_FILE" ] && [ "$KEY_IN_FILE_SET" != 1 ]; then
    unset AI_REVIEW_GATE_KEY
  fi
  # BEFORE the controller exists, so every worker it later spawns reads the published names when
  # there is a server to publish into. The controller's own session inherits them too (harmless —
  # the command string sets them again). This is the path that actually launches a cell, which is
  # what the preflight's delivery claim is about; the publish itself dies on a failed `set-option`.
  publish_worker_env
  tmux new-session -d -s "$SESSION" -c "$HARNESS" \
    "set -a; [ ! -f '$ENV_FILE' ] || . '$ENV_FILE'; set +a; HOME='$CELL_HOME' REPO='$REPO' O='$O' OR='$OR' SCOPE='$SCOPE' bash '$HARNESS/orch-loop.sh' 2>&1 | tee -a '$O/logs/controller.log'"
  sleep 3
  if tmux has-session -t "$SESSION" 2>/dev/null; then
    say "controller started (tmux '$SESSION'), state=$O"
  else
    die "controller exited immediately — read $O/logs/controller.log"
  fi
}

cmd_stop() {
  tmux has-session -t "$SESSION" 2>/dev/null || { say "not running"; return 0; }
  # A failed kill must NOT fall through to the lock release and a 0 exit: `stop` would report
  # success while the controller is still running (the same "failed precondition as success" shape).
  tmux kill-session -t "$SESSION" || die "tmux kill-session failed for '$SESSION' — the controller may still be running"
  say "controller stopped (tmux '$SESSION')"
  rm -f "$LOCK" && say "released lock $LOCK"
}

cmd_status() {
  if tmux has-session -t "$SESSION" 2>/dev/null; then say "controller: RUNNING (tmux '$SESSION')"
  else say "controller: STOPPED"; fi
  say "state dir: $O"
  # agent-infra#1745: the answer to "which commit is this cell running?", from the record `start`
  # wrote. Printed even when the controller is stopped — a stale cell is a stale cell.
  if [ -f "$STAMP" ]; then
    say "harness: $(stamp_field commit | cut -c1-12) [$(stamp_field relation)] from $(stamp_field harness)"
  elif [ -n "$HARNESS" ]; then
    say "harness: UNRECORDED at $HARNESS ($(harness_commit | cut -c1-12)) — run: $0 apply"
  fi
  # agent-infra#1736: a PERMANENT dispatch-provisioning failure makes the cell MERGE-ONLY, and
  # nothing else in this output says so — `lanes: 0` is also what a healthy idle cell prints.
  # orch-loop.sh records the reason in .refresh-blocked; surface it instead of leaving it in a log.
  if [ -f "$O/.refresh-blocked" ]; then
    say "⛔ MERGE-ONLY: dispatch provisioning is BLOCKED — no implementation lane will be dispatched"
    sed 's/^/    /' "$O/.refresh-blocked"
  fi
  # the loop's own view of itself
  tail -3 "$O/logs/orch-loop.log" 2>/dev/null | sed 's/^/  /' || say "  (no orch-loop.log yet)"
  say "lanes: $(tmux ls 2>/dev/null | grep -c '^lane-')"
}

cmd_logs() { tail -30 "$O/logs/orch-loop.log" 2>/dev/null || say "no log yet at $O/logs/orch-loop.log"; }

# ── apply: put the PROPER harness on this cell (agent-infra#1745) ─────────────────────────────────
# The owner's complaint was that "apply our harness to the cell" should be one simple job and had
# taken days. It is this command, and `start` runs the same code — so it is normally not typed.
cmd_apply() {
  validate_scope
  local force=0 a
  for a in "$@"; do
    case "$a" in
      --force) force=1 ;;
      *) die "usage: $0 apply [--force]" ;;
    esac
  done
  # Only a NON-EMPTY value is a metacharacter question; `safe_argv` returns non-zero for '' too, so
  # the old unconditional call replaced harness_apply()'s accurate "no git checkout resolved" with a
  # misleading "must not contain a quote or shell metacharacter: " (message-only, but a wrong remedy).
  [ -n "$HARNESS_REPO" ] && { safe_argv "$HARNESS_REPO" || die "\$HARNESS_REPO must not contain a quote or shell metacharacter: $HARNESS_REPO"; }
  safe_argv "${HARNESS_PIN_DIR:-}" || die "\$HARNESS_PIN_DIR must not contain a quote or shell metacharacter"
  safe_argv "${HARNESS_PIN_FILE:-}" || die "\$HARNESS_PIN_FILE must not contain a quote or shell metacharacter"
  local before_c; before_c="$(harness_commit)"
  if tmux has-session -t "$SESSION" 2>/dev/null && [ "$force" != 1 ]; then
    die "a controller is RUNNING (tmux '$SESSION') and apply would replace the harness tree under it — 'stop' first, or re-run with --force"
  fi
  harness_apply
  seed_and_stamp
  say "harness applied: ${before_c:0:12}${before_c:+ → }${HARNESS_COMMIT:0:12} (${HARNESS_REL})${HARNESS_APPLIED:+ [$HARNESS_APPLIED]}"
  say "  path:   $HARNESS"
  say "  ref:    $HARNESS_REF in $HARNESS_REPO"
  say "  record: $STAMP"
}

# ── prune: reclaim the disk the lanes regenerate (agent-infra#1745) ───────────────────────────────
# MEASURED 2026-10-15: the live cell's /dev/root was 30G/32G used with 111MB free, and the controller
# log carried `No space left on device` from claims.sh and orch-loop.sh. The single largest consumer
# was a 5.6G `.venv` in ONE worktree (`uv sync`) plus a 969M `.venv` at the clone root; ~50 review
# scratch checkouts filled the rest of /tmp. This deletes only what is REGENERABLE by definition.
rm_cache() {
  [ -e "$1" ] || return 0
  local mb; mb="$(du -sm "$1" 2>/dev/null | awk '{print $1}')"
  if rm -rf "$1" 2>/dev/null; then say "prune: -${mb:-?}MB $1"; else say "warn: could not remove $1"; fi
}

# Regenerable caches at ONE worktree root. `--maxdepth 5` keeps the pycache sweep bounded.
sweep_root_caches() {
  local root="$1"
  [ -d "$root" ] || return 0
  rm_cache "$root/.venv"; rm_cache "$root/node_modules"; rm_cache "$root/.pytest_cache"
  find "$root" -maxdepth 5 -type d -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null || true
}

# Is <path> a worktree of $REPO or $HARNESS_REPO? Scratch deletion must never touch one — a worktree
# may hold unmerged work, and that is the one thing this verb must not destroy.
registered_worktree() {
  local p="$1" r real w list
  real="$(cd "$p" 2>/dev/null && pwd -P)" || real="$p"
  for r in "$REPO" "$HARNESS_REPO"; do
    [ -n "$r" ] || continue
    git -C "$r" rev-parse --git-dir >/dev/null 2>&1 || continue
    # ⛔ NORMALIZE both sides, and materialize the listing rather than piping into `grep -qxF`.
    # `git worktree list` prints canonicalized paths, so a literal compare answers "not one of ours"
    # for the cell's OWN checkout whenever the spelling differs — and on macOS it ALWAYS differs for
    # the default SCRATCH_ROOT=/tmp, a symlink to /private/tmp, and for a $TMPDIR-derived path
    # carrying `//`. `prune --scratch` then `rm -rf`'d the main checkout and the unmerged work in it;
    # `linked_worktree_of` cannot be reused here because it deliberately EXCLUDES the main worktree,
    # which is exactly the path this guard must protect. Not `| grep -q`: an early exit down a pipe
    # lets the producer take SIGPIPE, and under `set -o pipefail` a MATCH then reads as no match.
    list="$(git -C "$r" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print substr($0,10)}')"
    while IFS= read -r w; do [ "$(cd "$w" 2>/dev/null && pwd -P)" = "$real" ] && return 0; done <<<"$list"
  done
  return 1
}

cmd_prune() {
  local caches_only=0 do_scratch=0 days="$SCRATCH_DAYS" a
  for a in "$@"; do
    case "$a" in
      --caches) caches_only=1 ;;
      --scratch) do_scratch=1 ;;
      --scratch=*) do_scratch=1; days="${a#*=}" ;;
      *) die "usage: $0 prune [--caches] [--scratch[=DAYS]]" ;;
    esac
  done
  case "$days" in ''|*[!0-9]*) die "prune: DAYS must be a number (got '$days')";; esac
  local before after mb r root d active_pin d_real live_root pin_root skip
  # (0) Harness pins superseded by the current one. `apply` names each pin by its commit, so a main
  # advance leaves the previous pin behind; only the path $HARNESS_PIN_FILE names is kept. Without this
  # per-commit pinning is a disk LEAK — the very thing `prune` exists to stop. An empty pin file means
  # "which pin is live" is NOT KNOWN, and an unknown is an abstention: nothing is deleted.
  active_pin="$(head -1 "$HARNESS_PIN_FILE" 2>/dev/null)"
  if [ -n "$active_pin" ]; then
    # ⛔ The SAME guard `harness_apply` runs, run here too. `HARNESS_PIN_DIR` is operator/`keys.env`
    # settable, and without this `prune` — which `cmd_start` calls UNATTENDED — `rm -rf`s every
    # subdirectory of a misconfigured root: `HARNESS_PIN_DIR=$CELL_HOME` deleted the cell home and its
    # state dir BEFORE the guard in `harness_apply` could fire. `assert_pin_dir_safe` refuses any root
    # that is not an empty dir, a linked worktree, or a pin root of hex-named directories.
    assert_pin_dir_safe "$HARNESS_PIN_DIR"
    if linked_worktree_of "$HARNESS_REPO" "$HARNESS_PIN_DIR"; then
      # The legacy FLAT PIN: the root IS the live worktree, so `"$HARNESS_PIN_DIR"/*/` would enumerate
      # the harness's OWN source directories and reclaim them. There are no superseded siblings here.
      say "prune: HARNESS_PIN_DIR is a single worktree — no superseded pins to reclaim"
    else
      for d in "$HARNESS_PIN_DIR"/*/; do
        d="${d%/}"
        [ -d "$d" ] || continue
        # ⛔ Compare NORMALIZED roots, and consult the harness actually IN USE — not only the pin FILE.
        # The file and this loop can disagree: an explicit `$HARNESS` outranks the file, `HARNESS_PIN_DIR`
        # can be respelled through a symlink between runs, and a pin file can be left from another
        # `HARNESS_PIN_DIR`. In each of those the literal `case` reclaimed the LIVE harness — the same
        # literal-path class already fixed in `linked_worktree_of` and `registered_worktree`, here with
        # the tree the cell is running from as the casualty. `prune` runs UNATTENDED from `cmd_start`.
        d_real="$(cd "$d" 2>/dev/null && pwd -P)"
        live_root="$(cd "$(dirname "$(dirname "$HARNESS")")" 2>/dev/null && pwd -P)"
        pin_root="$(cd "$(dirname "$(dirname "$active_pin")")" 2>/dev/null && pwd -P)"
        skip=0
        case "$active_pin" in "$d"|"$d"/*) skip=1 ;; esac
        [ -n "$d_real" ] || skip=1                                   # unresolvable: never reclaim blind
        [ -n "$d_real" ] && [ "$d_real" = "$live_root" ] && skip=1
        [ -n "$d_real" ] && [ "$d_real" = "$pin_root" ] && skip=1
        [ "$skip" = 1 ] && continue
        # ⛔ AUTHORITY TO DELETE. `assert_pin_dir_safe` above only answered whether the ROOT conforms,
        # and its name check is a SPELLING test. `apply` names a pin after a COMMIT in $HARNESS_REPO,
        # so the only proof an entry is ours is a CONTENT test that its name resolves there — without
        # it the widened 7..40 pattern let this UNATTENDED sweep (cmd_start calls prune) reclaim an
        # operator's date-named directory (`20260116`, `1718000000` — valid hex, not commits).
        # ⛔ Fail-closed on BOTH non-answers: 1 (provably not ours) and 2 (cannot verify — an
        # unresolved $HARNESS_REPO or a git failure) both SKIP the reclaim. Reconciling the two
        # directions: the delete side refuses on an unknown, and `check` never consults this test, so
        # an unresolved $HARNESS_REPO cannot turn a legitimate `check` into a false block.
        pin_entry_owned "$(basename "$d")"
        # ⛔ Branch the DIAGNOSIS on the return value: 1 and 2 both skip the reclaim, but they mean
        # different things, and telling an operator "does not resolve to a commit" when the repo could
        # not be consulted at all is this file's own "instrument that cannot answer its own question".
        case "$?" in
          0) ;;
          2) say "prune: NOT reclaiming $d — cannot VERIFY it is a pin: HARNESS_REPO is unresolved or not a git checkout. Fix HARNESS_REPO, then re-run '$0 prune'"
             continue ;;
          *) say "prune: NOT reclaiming $d — its name does not resolve to a commit in ${HARNESS_REPO:-<unresolved>}, so it is not provably a pin of ours"
             continue ;;
        esac
        say "prune: reclaiming superseded harness pin $d"
        # Deregister as well as delete. A bare `git worktree prune` is banned (#1141), so the removal
        # must be PATH-SCOPED — but a removal that only `rm -rf`'d left a phantom `worktree list`
        # entry plus its admin dir behind, one per pin forever, on the very verb that exists to stop a
        # disk leak. `worktree remove --force` handles both; `rm_cache` is the fallback when the
        # record is already gone or this is not a registered worktree.
        git -C "$HARNESS_REPO" worktree remove --force "$d" >/dev/null 2>&1 || rm_cache "$d"
      done
    fi
  fi
  before="$(free_mb "$CELL_HOME")"
  tmux has-session -t "$SESSION" 2>/dev/null && say "warn: a controller is running — a pruned venv makes the lane using it re-resolve its deps"
  for r in "$REPO" "$HARNESS_REPO"; do
    [ -n "$r" ] || continue
    git -C "$r" rev-parse --git-dir >/dev/null 2>&1 || continue
    # (1) ⛔ NO bare `git worktree prune` — the call this repo forbids (#1141) and this very file
    # states the ban against ~500 lines above. It has no path filter and deregisters EVERY record
    # whose working directory is missing, unrelated siblings included; for a DETACHED worktree the
    # admin HEAD is the commit's last durable handle, so a later `gc` collects it. A record whose
    # directory is already gone is reported by `worktree list`, not deregistered from here.
    # (2) regenerable caches at each worktree root. ⛔ The list is read LINE BY LINE — the old
    # `for root in "$(git … worktree list …)" "$r"` quoted the whole list into ONE word, so
    # `[ -d "$root" ]` skipped it and only the main checkout was ever swept: the incident's single
    # largest consumer was a 5.6G `.venv` in ONE LINKED worktree, which this loop could never reach.
    while IFS= read -r root; do sweep_root_caches "$root"; done \
      < <(git -C "$r" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print substr($0,10)}')
    sweep_root_caches "$r"
  done
  [ "$caches_only" = 1 ] && { after="$(free_mb "$CELL_HOME")"; [ -n "$before" ] && [ -n "$after" ] && say "prune: free ${before}MB → ${after}MB"; return 0; }
  # (3) /tmp review scratch. REPORTED, never deleted implicitly: a scratch checkout is source, and
  # the brief is explicit that source may be unmerged work. --scratch deletes only what is (a) a git
  # checkout, (b) NOT a registered worktree, and (c) older than DAYS.
  local kept="" freed_scratch=0
  for d in "$SCRATCH_ROOT"/*/; do
    d="${d%/}"
    [ -d "$d" ] || continue
    case "$d" in "$SCRATCH_ROOT/cell"|"$SCRATCH_ROOT/cell-"*|"$SCRATCH_ROOT/harness"*|"$SCRATCH_ROOT/cell-home") continue ;; esac
    [ -e "$d/.git" ] || continue
    registered_worktree "$d" && continue
    # ⛔ A linked worktree's `.git` is a FILE, not a directory. It is checked-out source that may hold
    # unmerged work, so it is never scratch — `registered_worktree` alone misses it for a repo this
    # cell does not happen to have registered ($REPO/$HARNESS_REPO).
    [ -f "$d/.git" ] && continue
    if [ "$do_scratch" = 1 ] && [ -n "$(find "$d" -maxdepth 0 -mtime +"$days" 2>/dev/null)" ]; then
      rm_cache "$d"; freed_scratch=1
    else
      mb="$(du -sm "$d" 2>/dev/null | awk '{print $1}')"
      kept="$kept
  ${mb:-?}M  $d"
    fi
  done
  if [ -n "$kept" ]; then
    say "prune: scratch checkouts still on disk (source — NOT deleted; use --scratch[=DAYS] to reclaim):"
    printf '%s\n' "$kept"
  fi
  [ "$freed_scratch" = 1 ] || true
  after="$(free_mb "$CELL_HOME")"
  [ -n "$before" ] && [ -n "$after" ] && say "prune: free ${before}MB → ${after}MB"
}

case "${1:-status}" in
  check)  cmd_check ;;
  start)  cmd_start ;;
  apply)  shift; cmd_apply "$@" ;;
  prune)  shift; cmd_prune "$@" ;;
  stop)   cmd_stop ;;
  status) cmd_status ;;
  logs)   cmd_logs ;;
  *)      say "usage: $0 check|start|stop|status|logs|apply|prune"; exit 2 ;;
esac
