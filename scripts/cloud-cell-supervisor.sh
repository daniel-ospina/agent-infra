#!/bin/bash
# cloud-cell-supervisor.sh — run the orchestrator harness on a Linux cloud cell.
#
# The harness's macOS-specific parts WERE (a) how the CONTROLLER is started — install.sh
# renders a launchd plist — and (b) three OS primitives inside orch-loop.sh (stat -f, sysctl
# vm.loadavg, sysctl vm.swapusage) that are BSD-only. (b) is GONE: agent-infra#1702 made the
# helpers portable (`stat -c '%Y'` first with `stat -f '%m'` as the macOS shape, `/proc/loadavg`,
# `/proc/meminfo` SwapFree), so the cell controller no longer aborts on its first cycle once a
# worker log exists and the load/swap gates bind on Linux — `worker-terminal.test.sh` §H drives
# both platform shapes. (a) remains, and is what this supervisor is for.
#
# The lanes were never launchd's, and they are no longer tmux's either: both controllers spawn
# through `worker-terminal.sh`, which asks the cmux daemon for a DURABLE TERMINAL on a cell and
# uses tmux only on macOS (the launchd surface). A tmux window — or a `setsid` child of a
# transient `cloud exec` — dies at ~21 log lines (measured on all three cells, 2026-10-20). Where
# neither surface exists the launcher REFUSES loudly rather than falling back; there is no env
# override, because a gate an agent can defeat with an export is not a gate.
#
# Runs ON THE CELL (Linux). Usage:
#   bash cloud-cell-supervisor.sh check|start|stop|status|logs|apply|prune
#                                  |doctor|merge|reap|hygiene
#
#   apply   fetch agent-infra main and PIN this cell's harness to it (agent-infra#1745). This is the
#           whole of "apply the proper harness"; `start` runs it before every launch, so it is
#           normally not needed by hand — it exists for a cell you want to fix without starting.
#   prune   reclaim the regenerable disk the lanes leave behind and report the review scratch that
#           accumulates under /tmp. --scratch[=DAYS] also deletes scratch checkouts older than DAYS.
#           A full disk is what breaks a cell FIRST.
#           ⛔ A per-worktree `.venv` is NOT removed here any more (agent-infra#1932). This sweep used
#           to `rm -rf` it at every worktree root, with no idea whether the lane using it was alive;
#           the only guard on the unattended path was a tmux NAME regex (`^(lane|fix|merge)-`) that
#           the sessions this fleet actually runs (`ai1932`, `merge-8708` — measured on cell-2) do not
#           match, and a manual `prune` had no guard at all. A `.venv` belongs to a RUNNING lane, so
#           its ONLY deleter is now scripts/reap-lane-venvs.sh, which requires positive evidence that
#           no live holder remains (a tmux pane inside the worktree, a process cwd or argv inside it)
#           and FAILS CLOSED when it cannot prove it. `prune` runs that reaper's GC.
#
# ── THE ROLES, AND WHY `status` HAD TO STOP LYING (agent-infra#1989) ─────────────────────────────
# The supervisor used to launch exactly one thing (`orch-loop.sh`) and answer "is its tmux session
# up?". A cell whose loop had died and a cell that was idle printed the SAME `controller: RUNNING /
# lanes: 0`, and nothing recorded whether a repair pass, a merge attempt or a reap had ever run. So
# `start` now also launches the cell doctor (`cloud-cell-doctor.sh loop`, tmux session
# `$DOCTOR_SESSION`), and `status` reads the per-role last-pass records it writes. A started cell
# whose roles never ran is NOT healthy, and `status` exits non-zero for it.
#
#   doctor  one pass: reap + keep the ONE dispatcher running (`start` when its session is gone; a
#           stale-but-present controller is REPORTED, never killed — that is a P0 action)
#   reap    one wedged-session pass, gated (namespace, log, two observations, human ancestry)
#   merge   land PRs with a clean attestation at head, through `admin-merge.sh`, and record every
#           refusal with its reason (never an override; never a blind retry at the same head)
#   hygiene `uv cache prune`, worktree-root caches (only when no worker is live), stale worktrees
#           via the shipped `pi-reap-worktrees.sh` (armed only under disk pressure by default)
#
# The verbs run ONE pass and are idempotent; `start` runs the loop that schedules them. Both write
# the same `$O/state/roles/<role>.state` records, so "configured" and "ran a pass at HH:MM:SSZ" are
# different lines in `status` rather than the same green tick.
#
# ── THE QUEUE TARGET IS THE CHECKOUT (agent-infra#1901) ──────────────────────────────────────────
# `REPO` (a path) and `OR` (an owner/repo) used to be two independent facts that nothing compared, so
# a cell could stand in one repo and dispatch against another. Measured on `pi-cell-2`: an
# agent-infra checkout whose queue was tortoise — the pre-flight tool could not run there, every
# candidate came back unqueryable, and 2,641 refresh passes judged nothing while the capacity line
# read `lanes=0/16` (the box EMPTY, not full). `OR` is now DERIVED from `git -C "$REPO" remote
# get-url origin`; an explicit `OR` is an override that must MATCH that remote; and a pair that
# cannot be read is never blessed (cannot-verify is not a pass). `start`/`check` REFUSE with both
# values, the remote, and the repo the machine needs; `status` prints the pair on one line.
# ⛔ The refresh loop's own retry/starvation behaviour is #1729 and is NOT changed here.
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
# The doctor loop's tmux session (agent-infra#1989). A NAME of its own, never a prefix of `$SESSION`.
# ⛔ Every tmux target that names the DOCTOR uses `=name` exact matching, for the reason orch-loop's
# reaper documents (`-t merge-82` resolved to `merge-821` and killed an in-flight worker): a session
# called `cell-doctor-old` must not be mistaken for this cell's doctor. The controller's targets
# (`has-session -t "$SESSION"`, `kill-session -t "$SESSION"`) still use tmux's default prefix
# matching — pre-existing, unchanged here, and noted so this comment does not overclaim.
DOCTOR_SESSION="${DOCTOR_SESSION:-cell-doctor}"
# This file's own path, resolved ONCE and handed to the doctor loop, so a restart from inside the
# loop runs the SAME supervisor the operator started (not a `$PATH` guess).
SUP_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && printf '%s/%s' "$PWD" "$(basename "${BASH_SOURCE[0]}")")"
[ -n "$SUP_SELF" ] || SUP_SELF="${BASH_SOURCE[0]}"
# OR (the queue's owner/repo) is interpolated into the session command string, so it must always be
# DEFINED — the guard below reads it with `${!v}` under `set -u`, which errors on an unset name.
# ⛔ It is deliberately NOT defaulted to a repo any more (agent-infra#1901). A default here is a
# SECOND fact that nothing compares to the checkout, and that is the measured defect: the cell stood
# in an agent-infra tree, defaulted the queue to tortoise, and judged nothing for 2,641 passes. The
# effective value is RESOLVED after $ENV_FILE is sourced (see the queue-target section below), so a
# keys.env `OR=` — including an empty one — is read as the operator wrote it, not as a default.
# ⛔ `${OR:-}` and NOT `OR=""`: this script's own assignment runs AFTER the environment is inherited,
# so a bare reset would DISCARD the very value the section below has to validate (measured here —
# `OR=daniel-ospina/tortoise` in the environment read as "not declared", which would have made every
# explicit-override refusal vacuous). It sets OR DEFINED, which is all `set -u` needs.
OR="${OR:-}"

# ── the worker census (agent-infra#2210) ────────────────────────────────────────────────────────
# ⛔ THE TMUX NAME MATCH IS DEAD ON A CELL. The harness spawns workers into cmux DURABLE TERMINALS
# there (worker-terminal.sh's header records the measurement), so `tmux ls | grep -c '^lane-'` answers
# 0 while lanes run — and this file used that answer to decide whether it may delete caches under a
# live lane, and to report `lanes:` in `status`. Both read a confident 0 for a busy box.
# The count comes from the launcher module's own census, and UNKNOWN (exit 3) is NOT zero: every
# caller treats it as "workers may be live", which is the direction that cannot destroy a live lane.
worker_census() { # stdout: the live worker count; exit 3 when no answer can be had
  local m="" here
  here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)"
  for m in "${HARNESS:-}/worker-terminal.sh" "${O:-}/worker-terminal.sh" "$here/orchestrator-harness/worker-terminal.sh"; do
    [ -f "$m" ] && break
  done
  [ -n "${m:-}" ] && [ -f "$m" ] || { printf 'census: no worker-terminal.sh beside the supervisor, in $HARNESS or in $O\n' >&2; return 3; }
  ( # shellcheck disable=SC1090
    . "$m" >/dev/null 2>&1 || { printf 'census: %s did not source\n' "$m" >&2; exit 3; }
    # ⛔ NO MEMO ON THIS PATH. The module memoizes its census for WT_TABLE_TTL seconds (that is right
    # for a controller asking a dozen questions per cycle), but these callers decide whether to DELETE
    # a live lane's caches and what `status` reports — a decision that must not be answered from a read
    # up to 10s old, across processes. Measured in cloud-cell-supervisor.test.sh: the case that runs
    # right after "a worker is live" inherited the memo and stood down with no worker running.
    WT_TABLE_TTL=0
    command -v wt_count >/dev/null 2>&1 || { printf 'census: %s defines no wt_count (a stale/empty copy?)\n' "$m" >&2; exit 3; }
    _c="$(wt_count lane- fix- merge- 2>/dev/null)" || { printf 'census: wt_count failed in %s\n' "$m" >&2; exit 3; }
    case "${_c:-}" in ''|*[!0-9]*) printf 'census: wt_count printed [%s] (not a number)\n' "${_c:-}" >&2; exit 3 ;; esac
    printf '%s\n' "$_c" )
}

# "workers may be LIVE" — 0 when the census cannot answer, so a broken read can never authorise a
# destructive action (the polarity worker-terminal.sh states, applied to an unattended prune).
workers_maybe_live() {
  local c
  c="$(worker_census)" || return 0
  [ "${c:-0}" -gt 0 ]
}

# ── the SECOND tmux boundary (agent-infra#1711) ─────────────────────────────────────────────────
# A tmux session is served from the SERVER's environment, so the controller's shell does NOT reach
# the workers it spawns. Until worker-terminal.sh, orch-loop.sh reviewed and merged through
# `tmux new-session -d -s merge-<PR> "bash '$O/merge-one.sh' …"`, and that session was built from the
# server's environment plus the names in tmux's `update-environment`; without publishing them the
# merge key stopped at the controller (which re-sources $ENV_FILE): merge-one.sh → record-review.sh
# resolves its key as $AI_REVIEW_GATE_KEY, else $HOME/.pi/agent/.ai-review-gate-key.
#
# ⛔ SCOPE NOTE (agent-infra#1702): WORKERS no longer cross this boundary. `worker-terminal.sh`
# carries a worker's environment explicitly (`state/env-<worker>.sh`, mode 0600, sourced by the run
# script), because a cmux durable terminal inherits nothing from the caller either. The publication
# below still covers everything THIS supervisor starts through tmux, and macOS workers on a tmux
# surface — but a cell's merge/fix/lane workers do not depend on it.
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
#   PATH               — the gh-limit layer (#1988) lives FIRST on the controller's PATH, and the
#                        sessions the controller spawns are created by a client holding THAT PATH, so
#                        publishing the name is what puts the layer in front of every lane's and
#                        worker's `gh` too. Without it only the controller would be serialised.
WORKER_ENV_NAMES="AI_REVIEW_GATE_KEY HOME O DEEPSEEK_API_KEY PATH"

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
  # (`update-environment` is a "these come from the client" list, not an allow-list). Authority is
  # therefore PER NAME, and both exceptions are load-bearing:
  #   * `HOME` — this shell, never the file: `export HOME="$CELL_HOME"` runs AFTER the source, so a
  #     `HOME=` line in keys.env is deliberately discarded (everything below runs under the cell home).
  #   * `AI_REVIEW_GATE_KEY` — the FILE only: `cmd_start`'s `unset` (which runs BEFORE this call) drops
  #     it from this shell unless `$ENV_FILE` carries it, so an ambient export cannot shadow the key
  #     file and falsify `cmd_check`'s verdict.
  # Every OTHER name (`O`, `DEEPSEEK_API_KEY`, `PATH`) is authoritative in `$ENV_FILE` or this shell.
  # A value living ONLY in the tmux server is not a supported configuration: the issue's
  # `tmux set-environment -g` workaround reads its value FROM `keys.env`, so the `start` shell (which
  # sources it) holds it and no strip can fire.
  # ⛔ RECORDED RESIDUAL, deferred on purpose (#1852 candidate fix 3, NOT claimed by this change): a
  # name NOBODY holds a value for is still a dead state `check` does not refuse. `start` publishes the
  # NAME and tmux STRIPS a listed name the creating client lacks, so `DEEPSEEK_API_KEY` absent from
  # both `$ENV_FILE` and the ambient shell leaves a worker with no provider credential while `check`
  # still prints "CELL CAN RUN A CONTROLLER". Delivering the name (this function) removes the
  # measured cause — the name was never published at all — but proving a VALUE exists is a separate
  # probe with its own false-block risk (a value that lives only in the key FILE, or a provider other
  # than deepseek), so it is tracked on agent-infra#1852 rather than smuggled in here. (#1896 review)
  for n in $WORKER_ENV_NAMES; do
    case " $list " in *" $n "*) ;; *) list="$list $n" ;; esac
  done
  tmux set-option -g update-environment "$list" \
    || die "cannot publish tmux update-environment ('$WORKER_ENV_NAMES') — every review and fixer would run with no provider credential and every merge worker keyless"
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
# Recomputed AFTER $ENV_FILE is sourced (it may repoint $O), exactly like $LOCK above.
ROLES_DIR="$O/state/roles"

# ── controller ownership (agent-infra#1761) ───────────────────────────────────────────────────────
# ONE authority for "does a controller own this state dir?". The lock names the owner; a SCOPED
# process read catches a controller whose lock was REMOVED while it was live — the measured mechanism
# behind #1761's duplicate ("the launcher DELETES the lock, so the lock cannot prevent a duplicate").
# `status`/`start`/`stop`/`apply` all read THIS, never the tmux session alone: a controller launched
# outside the `orch` session (a leftover harness copy — #1761 contradiction 4) is invisible to
# `tmux has-session`, so the old read reported STOPPED while a controller was merging, and `start`
# would launch a second one.
#
# ⛔ SCOPED to THIS cell's own orch-loop.sh paths, never a bare `pgrep -f orch-loop.sh`: a dev box
# runs PEER lanes' fixtures, and an unscoped match read FOUR controllers on 2026-10-15 (a real Mac
# controller, a leaked test fixture, and two of a peer lane's test), none of them ours. A path scope
# is what makes acting on these processes safe; an unscoped one is how a `stop` kills a peer's work.
# ⛔ DESCENDANTS ARE EXCLUDED. `orch-loop.sh` spawns short-lived CHILDREN whose command line also
# matches (measured `93150 53696 … orch-loop.sh`), so a naive count reports a duplicate that is not
# there — the false positive the #1761 thread warns a per-box read must avoid.
_controller_ps_awk='
  { ppid[$1]=$2; c=$0; sub(/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+/,"",c)
    n=split(c,tok," ")
    if (n>=2 && tok[2]!="-" && index(tok[2],"orch-loop.sh") && (tok[2]==a || (h!="" && tok[2]==h)) && tok[1] ~ /(bash|sh)$/) m[$1]=1 }
  END { for (p in m) { q=p; d=0
          for (i=0;i<64;i++) { if (!(q in ppid) || ppid[q]<=1) break; q=ppid[q]; if (q in m) { d=1; break } }
          if (!d) print p } }'
# ⛔ Match the INVOCATION, not the string. A process whose command line merely CONTAINS
# `$O/orch-loop.sh` is not a controller — the caller itself is the measured false positive (a
# `bash -c` whose script text mentions the path matches a `index(c,path)` test; the same shape made a
# bare `pgrep -f` read the test fixture as a live controller). The controller's argv is exactly
# `<shell> <path>` (orch-loop.sh takes no arguments), so require tok[2] == the path and a shell tok[1].
# ⛔ A FAILED READ IS NOT "NO CONTROLLER" (#1856 review). `ps` piped into awk cannot report its own
# failure, so a box whose `ps` is broken read as STOPPED — and `stop` then reported "not running" and
# released the lock over a live controller, which is the false pass this whole block exists to remove.
# An empty table is treated the same way: the probing process itself must appear in any real table
# (`scripts/lib/pid-identity.sh`'s #1178 C3 rule), so empty means unreadable, never absent.
_controller_pids_path() { # <primary-path> <extra-path-or-empty>
  local t
  t="$(ps -eo pid=,ppid=,command= 2>/dev/null)" || return 1
  case "$t" in *[![:space:]]*) ;; *) return 1 ;; esac
  printf '%s\n' "$t" | awk -v a="$1" -v h="$2" "$_controller_ps_awk"
}
# proc_start_epoch <pid> — when the process began, from `ps -o etime=`, whose [[dd-]hh:]mm:ss shape is
# the SAME on BSD and GNU ps (unlike etimes/lstart, which are not). rc 1 when it cannot be read.
#
# ⛔ THIS BODY IS A PINNED MIRROR OF `pid_start_epoch` IN scripts/lib/pid-identity.sh, which is the
# fleet's ONE process-identity rule (#1178) and which `scripts/lib/orchestrator-registry.sh` sources.
# The copy exists because THIS file must run standalone — it is farmed into a runtime dir and a suite
# arm copies it outside any checkout — so it cannot source a sibling library. Two copies of an
# identity rule that may DRIFT are the #1178 defect ("two contracts for one safety rule",
# docs/ops/fleet-liveness.md §3), so the pair is pinned by a drift arm in
# cloud-cell-supervisor.test.sh (§(p)): a divergence reddens CI instead of becoming a kill.
_proc_start_epoch() {
  local p="${1:-}" e d h m s r
  case "$p" in ''|*[!0-9]*) return 1 ;; esac
  e="$("${PS_BIN:-/bin/ps}" -o etime= -p "$p" 2>/dev/null | tr -d '[:space:]')" || return 1
  [ -n "$e" ] || return 1
  d=0
  case "$e" in *-*) d="${e%%-*}"; r="${e#*-}" ;; *) r="$e" ;; esac
  case "$d" in ''|*[!0-9]*) return 1 ;; esac
  case "$r" in
    *:*:*) h="${r%%:*}"; r="${r#*:}"; m="${r%%:*}"; s="${r##*:}" ;;
    *:*)   h=0;                 m="${r%%:*}"; s="${r##*:}" ;;
    *) return 1 ;;
  esac
  case "$h$m$s" in ''|*[!0-9]*) return 1 ;; esac
  # ⛔ `10#`, NOT a bare `$(( ))`. etime ZERO-PADS its fields, and bash reads a leading zero as
  # OCTAL: `$((08 * 3600))` is an ERROR ("value too great for base"). So every process whose age has
  # an `08`/`09` in its fields made this function fail, and a failed age reads as "began before the
  # fence" = "this pid IS the lock's owner" (#1856 review, reproduced with a PS_BIN stub printing
  # `08:31`). Same fix in scripts/lib/pid-identity.sh; §(p) pins the two copies together.
  h=$((10#${h:-0})); m=$((10#${m:-0})); s=$((10#${s:-0})); d=$((10#${d:-0}))
  printf '%s\n' "$(( $(date +%s) - (d * 86400 + h * 3600 + m * 60 + s) ))"
}
# _proc_began_after <pid> <epoch> — the pinned twin of pid_began_after (see the note above).
_proc_began_after() {
  local pe="${2:-}" ps
  case "$pe" in ''|*[!0-9]*) return 2 ;; esac
  ps="$(_proc_start_epoch "${1:-}")" || return 2
  [ "$ps" -gt "$((pe + LOCK_START_SLACK_SECONDS))" ]
}

# The pid $O/.orch.lock names, when it is alive and IS an orch-loop.sh INVOCATION.
#
# ⛔ ITS PATH IS NOT CHECKED — the lock is per-$O and the leftover-copy case must still be stoppable —
# BUT ITS SHAPE AND ITS AGE ARE, and both are load-bearing:
#   * SHAPE: argv must be `<shell> <.../orch-loop.sh>`. Matching the string anywhere in the command
#     line is how a `tmux` client, a `bash -c` launcher or an editor picks up the pattern (the same
#     measured false positive the scoped reads above exist to avoid).
#   * AGE: the lock is data on disk and outlives a `kill -9`/OOM/reboot. If the OS RECYCLED that pid
#     to a peer lane's controller — the exact shape of the processes this box runs — then the pid is
#     alive, its argv matches, and `stop` would TERM/KILL another repo's controller. A controller
#     always writes $LOCK after it starts, so a process that BEGAN after the lock was written cannot
#     be its owner. Unprovable age (a `ps`/`date` that cannot answer) is treated as NOT ours: an
#     unasserted target is not ours to kill, and `seen_controller_pids` still reports it.
lock_controller_pid() {
  local p c t lt ps
  p="$(tr -dc '0-9' 2>/dev/null < "$LOCK")"
  [ -n "$p" ] || return 0
  kill -0 "$p" 2>/dev/null || return 0
  c="$(ps -o command= -p "$p" 2>/dev/null)" || return 0
  # shellcheck disable=SC2086
  set -- $c
  [ "$#" -ge 2 ] || return 0
  case "${1##*/}" in bash|sh|dash|zsh) ;; *) return 0 ;; esac
  case "${2##*/}" in orch-loop.sh) ;; *) return 0 ;; esac
  lt="$(date -r "$LOCK" +%s 2>/dev/null)" || return 0
  [ -n "$lt" ] || return 0
  # ⛔ THREE OUTCOMES, and 2 is NOT 1: folding "cannot tell" into "began before" made an unreadable
  # age the strongest evidence of ownership, so `stop` signalled whatever a stale lock named on any
  # box where the etime read fails (#1856 review, reproduced). 2 is propagated as cannot-determine.
  _proc_began_after "$p" "$lt"
  case $? in
    0) return 0 ;;
    1) ;;
    *) return 2 ;;
  esac
  printf '%s\n' "$p"
}
# The ONE slack for "this process began after the record was written, so it cannot be the owner".
# Same value as scripts/lib/pid-identity.sh:PID_START_SLACK_SECONDS; the drift arm pins the pair.
LOCK_START_SLACK_SECONDS=5
# Controllers this cell may SIGNAL: the lock owner, plus any process running THIS state dir's own
# orch-loop.sh (a launcher that removed the lock). Never a $HARNESS-path match: that path is shared
# with peer lanes on a dev box, and signalling it is the failure this scope exists to avoid.
#
# ⛔ rc 1 = THE PROCESS TABLE COULD NOT BE READ. Every caller must treat that as cannot-determine:
# an empty answer is what a broken `ps` returns, and acting on it is how a live controller gets
# reported STOPPED.
owned_controller_pids() {
  local a b rc
  a="$(_controller_pids_path "$O/orch-loop.sh" "")" || return 1
  # ⛔ `|| return 1` would fold lock_controller_pid's rc 2 (age unreadable) into "cannot read the
  # process table" — a DIFFERENT cause, right verdict by luck. Propagate the code so the message a
  # caller prints is true, and so a future caller cannot silently read 2 as "no owner".
  b="$(lock_controller_pid)"; rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  printf '%s\n%s\n' "$a" "$b" | awk 'NF && !s[$0]++'
}
# Every controller this cell can SEE — the signalable set plus a $HARNESS-path match. Reported, and
# used to REFUSE a start/apply; never signalled (an unasserted target is not ours to kill).
#
# ⛔ THE $HARNESS LEG IS NOT AN OWNERSHIP CLAIM. HARNESS_PIN_DIR defaults to ONE directory per cell
# home (`$CELL_HOME/harness`), so two repos on one machine pin the same harness path and this read
# returns repo A's controller to repo B (#1856 review, reproduced). That is why `status` separates
# OWNED from SEEN, why `stop` proves the SESSION's owner before killing it, and why only
# `owned_controller_pids` may witness "still alive after stop".
seen_controller_pids() {
  local h="" a b rc
  [ -n "$HARNESS" ] && h="$HARNESS/orch-loop.sh"
  a="$(_controller_pids_path "$O/orch-loop.sh" "$h")" || return 1
  b="$(lock_controller_pid)"; rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  printf '%s\n%s\n' "$a" "$b" | awk 'NF && !s[$0]++'
}
# The pids in <seen> that are NOT in <owned>: a controller another repo is running from the shared
# harness path. Reported, never signalled, never fatal.
_pids_minus() { # <seen> <owned>
  comm -23 <(printf '%s\n' "$1" | awk 'NF' | sort -u) <(printf '%s\n' "$2" | awk 'NF' | sort -u)
}
_pids_join() { printf '%s' "$1" | tr '\n' ' ' | sed 's/ *$//'; }
# ── the QUEUE's repo and the CHECKOUT are ONE fact (agent-infra#1901) ────────────────────────────
# MEASURED 2026-10-15 on `pi-cell-2`: harness pin `a4a1249794e7` standing in an AGENT-INFRA checkout
# (`git -C $REPO remote get-url origin` → https://github.com/daniel-ospina/agent-infra.git) while the
# controller's queue was TORTOISE, because `$OR` defaulted to `daniel-ospina/tortoise` and nothing
# ever compared the two. The controller then named tortoise PRs from an agent-infra tree; the
# candidate pre-flight is a Python/uv tool that must run INSIDE the target repo, so it was skipped and
# every candidate came back unqueryable:
#
#   [refresh] no pyproject.toml in … — not a uv/Python project; skipping the scout venv step
#   [refresh] ?#5109 COLLISION is DEGRADED (the pre-flight could not query every surface)
#   [refresh] ABORT: none of the 6 candidate(s) the pre-flight ran produced a usable verdict
#
# …2,641 times, while the capacity line read `lanes=0/16 load=0/80` — the box EMPTY, not full — and
# `[dispatch] backlog empty` on every pass. The parked PRs were unreachable by this path, not merely
# unworked, and every observable except the work itself was green.
#
# So $OR is not a default any more: it is DERIVED from the checkout's `origin` remote — the one fact
# the machine actually has — and an explicit $OR ($ENV_FILE or the environment) is an OVERRIDE that
# must MATCH it, never a second independent fact. A pair that cannot be READ is not blessed either:
# cannot-verify is never a pass in this file, and the whole failure mode above was a cell that ran
# happily on a queue it could not query. `start`/`check` REFUSE on any of those states; `status`
# reports the pair (it is the verb an operator runs to find out the pair is wrong).
#
# ⛔ NOT fixed here, deliberately: the refresh loop's own retry/starvation behaviour (#1729). Making
# the mismatch impossible is this change; making the retry loop smarter is that one.

# owner/repo out of a git remote URL. Takes the shapes a clone actually records —
#   https://github.com/<owner>/<repo>.git · http://github.com/<owner>/<repo>.git ·
#   ssh://git@github.com/<owner>/<repo>.git · git@github.com:<owner>/<repo>.git
#                                                         (and any of them without `.git`)
# …and REFUSES everything else, INCLUDING a bare local path: a filesystem remote does not name a repo
# on a git host, so deriving a queue target from it would be an invention, not a read. The SCHEME is an
# allow-list for the same reason (see the review catch below).
# ⛔ The accepted charset is deliberately narrow. The value is interpolated into the tmux session
# command string, so `safe_argv` must be true of it BY CONSTRUCTION rather than by a later check that
# could be refactored away.
queue_repo_from_url() {
  local url="${1:-}" host path owner name
  case "$url" in
    https://*|http://*|ssh://*)
      # scheme URL: host[:port]/<path>. `${url#*://*/}` removes the SHORTEST prefix ending in `:///`
      # (the leading slash of the path), so it yields the path for every scheme form.
      # ⛔ The scheme is an ALLOW-LIST, not `*"://"*` (review catch): a filesystem/foreign scheme
      # names no repo on a git HOST, and the form `git clone file://localhost/<owner>/<repo>` — a
      # REAL clone — records `file://localhost/<owner>/<repo>` as origin, which passed every other
      # check here and was DERIVED into a queue target: a local path read as a host/repo pair, i.e.
      # an invention, and it failed OPEN in a gate whose whole contract is fail-closed.
      path="${url#*://*/}"
      [ "$path" != "$url" ] || return 1                   # no slash after the host: nothing to parse
      host="${url#*://}"; host="${host%%/*}"; host="${host#*@}"; host="${host%%:*}"
      ;;
    *@*:*)
      # scp-like: [user@]host:<path>. ⛔ The part before the `:` must be a HOST, so it may not carry
      # a `/`: a LOCAL PATH can contain both `@` and `:` (`/home/u@srv:o/r.git`) and was otherwise
      # read as a host/repo pair that nothing said was one — the same invention as the scheme case.
      case "${url%%:*}" in */*) return 1 ;; esac
      host="${url%%:*}"; host="${host#*@}"
      path="${url#*:}"
      ;;
    *) return 1 ;;
  esac
  [ -n "$host" ] || return 1
  # ⛔ A LEADING EMPTY PATH SEGMENT IS REFUSED, NOT REPAIRED (cross-parser lockstep, review round 2, P2).
  # This used to be `path="${path#/}"`, which DROPPED an empty first segment — so `git@host:/owner/name.git`
  # (git accepts that ssh form) and a doubled slash after the host (`https://host//owner/name.git`) derived
  # a queue HERE while `scripts/orchestrator-harness/repo-slug.sh` REFUSED the same origin (`/*` in its
  # shape case). Same box, two entry points, two answers — and this parser's answer is the value that
  # reaches the controller as an explicit `OR`, which `orch-loop.sh` uses AS GIVEN (OR_EXPLICIT wins).
  # Refusing makes both derivations say "not a slug", which is the fail-closed side. The family is pinned
  # mechanically by test-gates.sh's CROSS-PARSER LOCKSTEP table and by §(7c) below, so the next edit to
  # either parser reddens instead of being described.
  case "$path" in /*) return 1 ;; esac
  path="${path%/}"; path="${path%.git}"
  case "$path" in */*) ;; *) return 1 ;; esac                 # `<owner>/<repo>`, not `repo`
  owner="${path%%/*}"; name="${path#*/}"
  case "$owner" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  case "$name"  in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac     # also rejects a 3-segment path
  printf '%s/%s\n' "$owner" "$name"
}

QUEUE_REMOTE=""      # the origin URL we READ from the checkout (empty = nothing to read)
QUEUE_DERIVED=""     # owner/repo parsed out of it (empty = underivable)
QUEUE_REPO=""        # the EFFECTIVE queue target the controller session will receive
QUEUE_DECLARED=""    # what the operator/keys.env asked for (empty = not declared)
QUEUE_STATE=""       # derived|explicit = usable · mismatch|invalid|unreadable|underivable = refuse

# Read the pair. NEVER dies: `status` must still answer when the pair cannot be read — it is the verb
# an operator runs to discover that it cannot — and every other verb keeps its own preconditions. The
# verbs that cannot do their job call assert_queue_target() below.
resolve_queue_target() {
  QUEUE_DECLARED="${OR:-}"
  QUEUE_REMOTE="$(git -C "$REPO" remote get-url origin 2>/dev/null)"
  QUEUE_DERIVED=""
  [ -n "$QUEUE_REMOTE" ] && QUEUE_DERIVED="$(queue_repo_from_url "$QUEUE_REMOTE")"
  if [ -z "$QUEUE_REMOTE" ]; then
    QUEUE_REPO="$QUEUE_DECLARED"; QUEUE_STATE="unreadable"; return 1
  fi
  if [ -z "$QUEUE_DERIVED" ]; then
    QUEUE_REPO="$QUEUE_DECLARED"; QUEUE_STATE="underivable"; return 1
  fi
  if [ -z "$QUEUE_DECLARED" ]; then
    QUEUE_REPO="$QUEUE_DERIVED"; QUEUE_STATE="derived"; return 0
  fi
  # An EXPLICIT override is held to the same `<owner>/<repo>` shape the derivation guarantees, so a
  # typo cannot become a queue target that no `gh --repo` call can resolve.
  case "$QUEUE_DECLARED" in
    */*/*)             QUEUE_STATE="invalid" ;;
    *[!A-Za-z0-9._/-]*) QUEUE_STATE="invalid" ;;
    */*)               QUEUE_STATE="" ;;
    *)                 QUEUE_STATE="invalid" ;;
  esac
  if [ -n "$QUEUE_STATE" ]; then QUEUE_REPO="$QUEUE_DECLARED"; return 1; fi
  QUEUE_REPO="$QUEUE_DECLARED"
  # ⛔ FOLD CASE, exactly as `repo_matches_checkout` does: GitHub owner/repo names are case-
  # insensitive, so `Daniel-Ospina/Tortoise` and `daniel-ospina/tortoise` are ONE repo. A verbatim
  # comparison refused a pair the entry point's `check` had just passed — the #1745 shape (check says
  # "this machine can run it", start then dies) on the one fact the design calls single-sourced
  # (#1856 review, reproduced).
  if [ "$(printf '%s' "$QUEUE_DECLARED" | tr '[:upper:]' '[:lower:]')" = \
       "$(printf '%s' "$QUEUE_DERIVED" | tr '[:upper:]' '[:lower:]')" ]; then
    QUEUE_STATE="explicit"; return 0
  fi
  QUEUE_STATE="mismatch"
  return 1
}
resolve_queue_target || true
# The session command string interpolates this, so it must be the RESOLVED value — not the raw $OR a
# keys.env happened to carry, and not a default.
OR="$QUEUE_REPO"

# The named REFUSAL, in the shape `apply` uses when it declines because a controller is running — not
# a warning. A wrong pair must not be a cell that starts and looks healthy; it must be a cell that
# does not start, with an error naming BOTH values, the remote that was read, and the repo this
# machine needs so provisioning is unambiguous.
assert_queue_target() {
  case "$QUEUE_STATE" in
    derived|explicit) return 0 ;;
  esac
  local needs="the queue's repo is READ from \$REPO's 'origin' remote, so $REPO MUST BE a checkout of the repo whose pull requests this cell is supposed to work — 'git -C $REPO remote get-url origin' => <host>/<owner>/<repo>.git"
  case "$QUEUE_STATE" in
    mismatch)
      die "the QUEUE and the CHECKOUT name DIFFERENT repos: the queue targets '$QUEUE_DECLARED' (OR) but $REPO is a checkout of '$QUEUE_DERIVED' (origin $QUEUE_REMOTE). A controller on this pair dispatches $QUEUE_DECLARED PRs from a $QUEUE_DERIVED tree: its candidate pre-flight cannot run there, every candidate comes back unqueryable, and the queue never advances while every other observable reads green (agent-infra#1901). Fix ONE of them — $needs — or remove the OR line from $ENV_FILE so it derives from the checkout, which would target $QUEUE_DERIVED."
      ;;
    invalid)
      die "OR='$QUEUE_DECLARED' is not an <owner>/<repo> (want e.g. daniel-ospina/tortoise) — a queue target must name a repo on a git host, and a typo here is a cell that dispatches nothing. $needs."
      ;;
    unreadable)
      die "cannot read the QUEUE this cell would target: 'git -C $REPO remote get-url origin' returned no URL${QUEUE_DECLARED:+, so OR='$QUEUE_DECLARED' cannot be verified against the checkout}. Starting anyway is the measured agent-infra#1901 failure — the controller runs, reports lanes and a loaded queue, and judges nothing. $needs."
      ;;
    underivable)
      die "cannot derive the QUEUE from $REPO's origin remote '$QUEUE_REMOTE' — it does not name <owner>/<repo> in an accepted form (https://, http://, ssh://, or scp-like git@host:owner/repo.git, with no empty path segment: 'git@host:/owner/repo.git' is refused), so there is no repo on a git host to target. $needs."
      ;;
    *)
      die "cannot determine the QUEUE this cell would target (state '${QUEUE_STATE:-unknown}') — refusing to run a controller that cannot judge the queue it names. $needs."
      ;;
  esac
}

# The one-line answer `status` prints: is this cell pointed at what it is standing in?
queue_state_text() {
  case "$QUEUE_STATE" in
    derived)     printf 'ok — derived from the checkout' ;;
    explicit)    printf 'ok — OR matches the checkout' ;;
    mismatch)    printf 'MISMATCH — start/check refuse (agent-infra#1901)' ;;
    unreadable)  printf 'UNREADABLE — the checkout has no origin remote; start/check refuse' ;;
    underivable) printf 'UNDERIVABLE — origin is not https/http/ssh/scp-like naming <owner>/<repo>; start/check refuse' ;;
    invalid)     printf 'INVALID — OR is not <owner>/<repo>; start/check refuse' ;;
    *)           printf 'unknown' ;;
  esac
}

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
# ⛔ DEFINED HERE SO THE INJECTION GUARD'S `${!v}` CANNOT ABORT ON IT. The guard below reads each name
# with `${!v}` under `set -u`, which ERRORS on an UNSET name instead of allowing its `|| continue` —
# so every name in that list must have a defining assignment (same reason as `OR="${OR:-}"` above).
# `HARNESS_MATERIALISER` is consumed by the controller's per-cycle self-refresh (agent-infra#2215): it
# names the ONE engine allowed to materialise a pin, and an operator may pin it; this box's own `start`
# defaults it to empty (the loop passes `$SUP_SELF` explicitly to the controller it launches).
HARNESS_MATERIALISER="${HARNESS_MATERIALISER:-}"
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
# worktree of $HARNESS_REPO, an empty directory, a pin ROOT holding only hex-named pin dirs, or a root
# whose only other entries are OS droppings (`​.DS_Store` / `._*` REGULAR files — one Finder visit to the
# default root must not brick the cell; a hidden DIRECTORY or a dangling symlink is still refused).
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

# The PHYSICAL form of a path, resolved even when the path does not exist YET: the deepest existing
# ancestor is resolved with `pwd -P` (symlinks, `//` and trailing slashes collapsed) and the missing
# tail is then appended and collapsed LEXICALLY — those components do not exist, so none of them can be
# a symlink and lexical `..` is the only correct reading. Resolving only the existing part was not
# enough: `$CELL_HOME/nonexistent/..` names the cell home, `-e` on it is false (the `..` cannot be
# resolved through a missing component), and the root therefore CONFORMED (review round 3, measured).
# ⛔ Why this exists: a raw string compare of paths is defeated by SPELLING. Measured —
# `HARNESS_PIN_DIR=$CELL_HOME` was refused, the SAME directory written `$CELL_HOME/` (one trailing
# slash) CONFORMED, and `$CELL_HOME/../cell` conformed too: the containment deny-list is the only
# guard against `rm -rf` over the cell home, so one operator-typed slash disarmed it. On macOS the
# mirror-image problem is a `$TMPDIR`-derived `//` making two spellings of one directory disagree.
pin_norm_lex() { # collapse `.`/`..`/empty segments in an ABSOLUTE path; no filesystem access
  local out="" seg
  local IFS=/
  for seg in $1; do
    case "$seg" in
      ''|.) continue ;;
      ..) out="${out%/*}"; continue ;;
    esac
    out="$out/$seg"
  done
  printf '%s\n' "${out:-/}"
}
pin_path_real() {
  local d="${1:-}" tail="" phys
  [ -n "$d" ] || return 1
  # ⛔ RELATIVE spellings are resolved too, never rejected: rejecting them made the deny-list FAIL
  # OPEN — `pin_root_conformance` would fall back to the spelled `cell`, no absolute deny-list entry
  # could match it, and a relative root reached the sweep's `rm -rf` (VGATE round 4, reproduced:
  # `HARNESS_PIN_DIR=cell` conformed while the same directory absolute was refused). `cd` resolves a
  # relative path as well as an absolute one; only `pwd -P`'s absolute output is trusted.
  while [ ! -d "$d" ]; do
    if [ "$d" = "/" ] || [ "$d" = "." ] || [ -z "$d" ]; then return 1; fi
    tail="/$(basename "$d")$tail"
    d="$(dirname "$d")"
  done
  # ⛔ A FAILED `cd` must not yield an EMPTY answer: an empty result turns the deny-list pattern
  # `"$dir_real"/*` into `/*`, which matches EVERY absolute path — so an unreadable root was refused
  # for the wrong reason ("CONTAINS …") instead of naming the read failure. `$d` must be a directory
  # AND `pwd -P` must return an absolute path, or this returns 1 and the caller falls back to the
  # spelled path (which the `ls` step refuses when the root is unreadable).
  phys="$(cd "$d" 2>/dev/null && pwd -P)" || return 1
  case "$phys" in /?*) ;; *) return 1 ;; esac
  pin_norm_lex "$phys$tail"
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
# entry, and each one must be a hex-named directory — EXCEPT an OS-droppings regular file
# (`.DS_Store` / `._*`), which is skipped: refusing it bricked all four verbs after a single Finder
# visit to the default root on the operators' macOS server (see the header above, which states the
# whole allow-list; this line is the one it is easiest to contradict by accident).
# ⛔ Deliberately NOT a per-entry `git worktree list` path comparison: on macOS a `$TMPDIR`-derived
# path carries a `//` that git normalizes in its listing output, so a literal comparison reports our
# OWN pin as foreign and the guard becomes a false block.
pin_root_conformance() {
  local dir="${1:-}" p listing entries=0 harmless=0 dir_real p_real
  PIN_ROOT_BAD=""; PIN_ROOT_REMEDY=""
  # ⛔ THE REMEDY IS CARRIED PER CAUSE, like the reason. One shared footer is how the guard came to
  # tell an operator "Remove it by hand if you are sure it holds nothing" for a root that CONTAINS the
  # cell home — i.e. it advised deleting keys.env and the orchestrator state, the very action the
  # denial exists to prevent (review round 5, measured against the shipped script).
  local remedy_dedicated='Point HARNESS_PIN_DIR at a dedicated worktree path (default $CELL_HOME/harness).'
  case "$dir" in
    ""|"/"|".") PIN_ROOT_BAD="is '$dir'"; PIN_ROOT_REMEDY="$remedy_dedicated"; return 1 ;;
  esac
  # A root that CONTAINS anything this cell needs cannot be reclaimed, and every sibling verb refuses
  # it — so `check` must refuse it too, not certify a cell whose own `apply`/`start`/`prune` die here.
  # ⛔ Compare PHYSICAL paths (`pin_path_real`), never the spelled ones: `$CELL_HOME/` and
  # `$CELL_HOME/../cell` are the same directory and must get the same answer.
  dir_real="$(pin_path_real "$dir")" || dir_real="$dir"   # unreadable root: the `ls` below refuses it
  for p in "$CELL_HOME" "$HOME" "$O" "$REPO" "$HARNESS_REPO" "$(dirname "$ENV_FILE")"; do
    [ -n "$p" ] || continue
    p_real="$(pin_path_real "$p")" || p_real="$p"
    case "$p_real" in "$dir_real"|"$dir_real"/*) PIN_ROOT_BAD="CONTAINS $p, which this cell needs"; PIN_ROOT_REMEDY="$remedy_dedicated"; return 1 ;; esac
  done
  [ -e "$dir" ] || [ -L "$dir" ] || return 0               # nothing there: nothing to refuse
  linked_worktree_of "$HARNESS_REPO" "$dir" && return 0    # the legacy flat pin (root IS one worktree)
  [ -d "$dir" ] || { PIN_ROOT_BAD="is not a directory"; PIN_ROOT_REMEDY="Remove that entry, or point HARNESS_PIN_DIR at a directory."; return 1; }
  listing="$(ls -A "$dir" 2>/dev/null)" || return 2         # ⛔ a failed read is NOT an empty read
  [ -n "$listing" ] || return 0                             # genuinely empty (`ls -A` drops . and ..)
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    # A sibling verb can mutate the root between `ls -A` and this test. An entry that VANISHED is not
    # a nonconformity (it would name a directory that no longer exists); a dangling symlink still is
    # (`-L` true, `-d` false → refused), which is the property `ls -A` exists for.
    [ -e "$dir/$p" ] || [ -L "$dir/$p" ] || continue
    # ⛔ An OS droppings FILE is not an operator's directory, and refusing the root for one bricked all
    # four verbs: a single Finder visit to the pin root creates `.DS_Store` (`._<name>` appears beside
    # a file copied from HFS+), which is what the operators' macOS server does to `$CELL_HOME/harness`.
    # Measured in review round 3: `check`, `apply`, `start` AND `prune` all refused, and the diagnose
    # line sent the operator looking for a pin directory that was not there. ONLY regular, non-symlink
    # files with these exact names are skipped — a hidden DIRECTORY, a dangling symlink or any other
    # entry is still refused, which is the false pass `ls -A` exists to catch. `harmless` keeps such a
    # root from reaching the cannot-verify branch below: there is nothing of ours in it to protect.
    case "$p" in
      .DS_Store|._*) if [ -f "$dir/$p" ] && [ ! -L "$dir/$p" ]; then harmless=1; continue; fi ;;
    esac
    entries=$((entries + 1))
    if [ ! -d "$dir/$p" ] || ! pin_name_ok "$p"; then
      PIN_ROOT_BAD="holds '$p', which is not a pin directory"
      PIN_ROOT_REMEDY="Remove that entry by hand if you are sure it holds nothing."
      return 1
    fi
  done <<<"$listing"
  [ "$entries" -gt 0 ] && return 0
  [ "$harmless" = 1 ] && return 0                          # only OS droppings: nothing of ours to protect
  # ⛔ rc 2 is TWO states and the callers must not describe one of them as the other: `ls -A` failed
  # (permission/IO), or it succeeded and every entry vanished under a concurrent `apply`/`prune`. The
  # remedy differs, so the reason is carried out the way rc 1's is.
  PIN_ROOT_BAD="was listed as non-empty but every entry vanished while it was read (a concurrent 'apply' or 'prune'?) — nothing to inspect"
  return 2
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
  local n="${1:-}" out
  PIN_OWNED_ERR=""
  pin_name_ok "$n" || return 1
  [ -n "$HARNESS_REPO" ] || return 2
  git -C "$HARNESS_REPO" rev-parse --git-dir >/dev/null 2>&1 || return 2
  if out="$(git -C "$HARNESS_REPO" cat-file -e "${n}^{commit}" 2>&1)"; then
    return 0
  fi
  # ⛔ A CLEAN ABSENCE is rc 1 ("not a commit of ours"); anything else is rc 2. The first version
  # collapsed every failure into 1, so an object store that could not be READ — EACCES on a loose
  # object, a corrupt pack, a partial-clone lazy fetch that cannot reach its remote — printed the
  # affirmative "does not resolve to a commit". That is the instrument that cannot answer its own
  # question, and it also reported a legitimately-blocked reclaim as "not a pin" (review round 3,
  # reproduced: `error: unable to open …: Permission denied` was discarded by a `2>/dev/null`).
  # Both values still SKIP the reclaim — only the diagnosis differs.
  # ⛔ A DIAGNOSTIC is checked FIRST, because git prints BOTH lines when it cannot READ an object:
  # `error: unable to open …/objects/f0: Permission denied` followed by `fatal: Not a valid object
  # name …`. Matching the absence phrase alone would therefore classify the read failure as a clean
  # absence — the exact bug this split exists to remove.
  case "$out" in
    *"error:"*|*"unable to open"*|*"Permission denied"*|*"corrupt"*|*"fatal: unable to"*|*"failed to"*)
      PIN_OWNED_ERR="$out"; return 2 ;;
  esac
  case "$out" in
    *"Not a valid object name"*|*"Could not find"*|*"not a valid commit name"*|*"bad object"*|*"Invalid object name"*) return 1 ;;
  esac
  PIN_OWNED_ERR="$out"
  return 2
}

# The check-side caller: the SAME conformance question, with a message about the cell being unusable
# rather than about deleting a directory `check` never deletes.
cmd_check_pin_dir() {
  local rc
  pin_root_conformance "$HARNESS_PIN_DIR"; rc=$?
  case "$rc" in
    0) return 0 ;;
    2) # rc 2 has TWO causes and each gets its own remedy — never assert the unobserved one.
       if [ -n "$PIN_ROOT_BAD" ]; then
         die "HARNESS_PIN_DIR='$HARNESS_PIN_DIR' $PIN_ROOT_BAD — so whether it is a pin root is UNKNOWN, and cannot-verify is never a pass. Re-run '$0 check' once nothing else is touching it   (agent-infra#1852)"
       fi
       die "HARNESS_PIN_DIR='$HARNESS_PIN_DIR' cannot be READ (permission denied or an I/O error), so whether it is a pin root is UNKNOWN — and cannot-verify is never a pass. Fix its permissions, or point HARNESS_PIN_DIR at a readable path, then re-run: $0 check   (agent-infra#1852)" ;;
  esac
  die "HARNESS_PIN_DIR='$HARNESS_PIN_DIR' $PIN_ROOT_BAD — 'apply' AND 'start' both refuse here, so this cell can neither be updated nor started. $PIN_ROOT_REMEDY Then re-run: $0 apply   (agent-infra#1852)"
}

# The delete-side caller, used by `harness_apply` and `cmd_prune`.
assert_pin_dir_safe() {
  local dir="$1" rc
  pin_root_conformance "$dir"; rc=$?
  case "$rc" in
    0) return 0 ;;
    2) if [ -n "$PIN_ROOT_BAD" ]; then
         die "refusing to rm -rf HARNESS_PIN_DIR='$dir': $PIN_ROOT_BAD — so this is not a root we can reclaim right now, and cannot-verify is not a pass here either."
       fi
       die "refusing to rm -rf HARNESS_PIN_DIR='$dir': it cannot be READ (permission denied or an I/O error), so whether it is a pin root is UNKNOWN — and cannot-verify is not a pass here either." ;;
  esac
  die "refusing to rm -rf HARNESS_PIN_DIR='$dir': it $PIN_ROOT_BAD. $PIN_ROOT_REMEDY"
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
  # ── the gh-limit layer (#1988) ────────────────────────────────────────────────────────────────
  # Four boxes act as ONE GitHub account, so an unserialised, un-backoff'd box spends everyone's
  # quota. The layer is a `gh` shim on the controller's PATH plus the ONE python helper the Mac
  # adapter uses — same bytes, same backoff, so it cannot drift between the box with the REST
  # adapter and the boxes without it. Seeded with the SAME stage-then-rename as the *.sh files: a
  # running lane's `gh` may be executed at any moment, and a truncated shim would be a broken `gh`.
  if [ -f "$HARNESS/gh-limit/gh" ] && [ -f "$HARNESS/gh-limit.py" ]; then
    mkdir -p "$O/gh-limit" || die "cannot create $O/gh-limit"
    seed_one() {  # <src> <dest>
      local _src="$1" _dst="$2" _tmp="$O/.seed-$(basename "$2").$$"
      cp -p "$_src" "$_tmp" || die "cannot stage $(basename "$_dst") into $O — free space ($0 prune)"
      chmod +x "$_tmp"     || { rm -f "$_tmp"; die "cannot chmod $(basename "$_dst")"; }
      mv -f "$_tmp" "$_dst" || { rm -f "$_tmp"; die "cannot install $_dst into $O"; }
    }
    seed_one "$HARNESS/gh-limit/gh" "$O/gh-limit/gh"
    seed_one "$HARNESS/gh-limit.py" "$O/gh-limit.py"
  else
    # ⛔ MIRROR the stale pair away (the same rule the *.sh loop below applies). A `$O/gh-limit/gh` left
    # by an earlier harness would stay on the controller PATH with its helper gone — a shim that can
    # serialise nothing; the cell's documented fail-open (PATH's real gh, with a warning) is the correct
    # state, not a half-installed layer.
    if [ -e "$O/gh-limit/gh" ] || [ -e "$O/gh-limit.py" ]; then
      rm -f "$O/gh-limit/gh" "$O/gh-limit.py" || die "cannot remove the stale gh-limit layer from $O"
      rmdir "$O/gh-limit" 2>/dev/null || true
      say "seed: removed the stale gh-limit layer — the harness no longer ships it"
    fi
    say "WARN: $HARNESS ships no gh-limit layer — this cell's gh calls will NOT be serialised or backed off (#1988)"
  fi
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
  # PARTIAL, and the difference is deliberate: install.sh's fatal gate is `for bin in tmux gh pi jq`
  # (install.sh:136), and it never probes git or python3. (jq joined that gate with #1962 — every
  # listing is assembled with it, so a box without it reports UNREADABLE forever; the cell's own
  # toolchain gate names it too, cloud-cell-bringup.sh check_tools.) The requirement here is this
  # script's own, not a mirrored one.
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
  # ── the QUEUE's repo is the CHECKOUT's remote (agent-infra#1901) ────────────────────────────
  # BEFORE the dispatch-provisioning probe: that probe runs INSIDE $REPO with this $OR, so a pair
  # naming two different repos makes the probe answer about a repo the cell is not standing in —
  # which is exactly how the measured cell passed every gate and then judged nothing. `check` is the
  # question "can this cell run a controller?", so it must REFUSE what `start` refuses; a verdict of
  # YES here while `start` dies on the same config is a FALSE PASS on that question (same rule as
  # validate_scope).
  assert_queue_target
  say "ok: queue $QUEUE_REPO == checkout $REPO (origin $QUEUE_REMOTE) — $QUEUE_STATE"
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
  # ⛔ repo-slug.sh IS IN THIS LIST (review round 3, finding 1). orch-loop.sh SOURCES it from $O and
  # `exit 78`s without it, and refresh-candidates.sh refuses without it — so a $O missing it is a
  # controller that crash-loops under KeepAlive. Omitting it here made `check` — the verb an operator
  # runs BECAUSE the box looks stuck — print "CELL CAN RUN A CONTROLLER" for exactly that box. Same
  # reasoning as repo-authority.sh: a sourced-at-startup dependency is a required worker.
  # cloud-cell-doctor.sh is launched from $O by `start` (the doctor loop), so its absence is the same
  # false "CELL CAN RUN A CONTROLLER" the rest of this list exists to prevent: the controller would
  # run, `start` would report success, and the cell would never reap or land anything.
  # reviewer-preflight.sh is SOURCED by lane.sh, which `exit 78`s without it (agent-infra#2148) — same
  # class as repo-slug.sh: on a $O missing it every lane dies at startup, which is precisely the
  # false "CELL CAN RUN A CONTROLLER" this list exists to prevent.
  for w in orch-loop.sh harness-refresh.sh claims.sh repo-authority.sh repo-slug.sh reviewer-preflight.sh dispatch-merge.sh lane.sh chain-merge.sh merge-one.sh fix-one.sh refresh-candidates.sh adopt-fix.sh cloud-cell-doctor.sh; do
    [ -f "$O/$w" ] || missing="$missing $w"
  done
  [ -z "$missing" ] || die "worker scripts missing from $O:$missing — run 'start' (it seeds $O) or: cp '$HARNESS'/*.sh '$O'/"
  # ── the gh-limit layer (#1988): present, AND able to run ──────────────────────────────────────
  # Presence alone is the false-green this file refuses everywhere else: a shim that cannot find the
  # real gh exits 127 on EVERY call, which would stop merges altogether. So resolve `gh` through the
  # very PATH the session will get and require it to answer.
  if [ -f "$O/gh-limit/gh" ] && [ -f "$O/gh-limit.py" ]; then
    # ⛔ `NO_WAIT` ON THE PROBE. Without it a box with one gh hanging in flight makes `check` wait up
    # to the layer's 600 s lock budget — and `check` is the diagnostic an operator runs BECAUSE the
    # box looks stuck. `gh --version` needs no lock at all, but the lock is taken before the child is
    # classified (review round 9).
    PATH="$O/gh-limit:$PATH" GH_LIMIT_NO_WAIT=1 GH_LIMIT_NO_WAIT_LOCK_S=2 gh --version >/dev/null 2>&1 \
      || die "the gh-limit layer at $O/gh-limit cannot run gh — every gh call in the session would fail. Fix the layer or remove it before starting (a cell without it MERGES but is not serialised, #1988)."
  else
    say "WARN: no gh-limit layer in $O — this cell's gh calls are NOT serialised/backed off (#1988); run 'start' to seed it"
  fi

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
  local pv pvrc
  pv=""
  pvrc=0
  pv="$(REPO="$REPO" OR="$OR" O="$O" bash "$HARNESS/refresh-candidates.sh" --check 2>&1)" || pvrc=$?
  if [ "$pvrc" -ne 0 ]; then
    printf '%s\n' "$pv" >&2
    # ⛔ THE DIAGNOSIS FOLLOWS THE REASON, NOT JUST THE CODE (review cycles 5-6). `--check` returns rc=3
    # for PERMANENT provisioning defects and rc=1 for things an operator clears in a minute — but rc=1
    # also covers causes that are not the scout at all (`FAIL repo not found`, `'uv' is not runnable`),
    # and telling an operator with a broken `uv` to "clear the scout" sends them the wrong way. Only a
    # TRANSIENT refusal that names the scout gets the scout wording.
    if [ "$pvrc" -eq 3 ]; then
      die "this repo cannot be provisioned for dispatch (a cell started on it could only MERGE) — see the reason above (agent-infra#1736)"
    fi
    case "$pv" in
      *"TRANSIENT: scout"*) die "the scout worktree cannot be refreshed right now (see the reason above): clear it, then re-run — nothing would be dispatched until then (agent-infra#2174)" ;;
      *) die "this cell cannot start: a precondition above is not met — see the reason above (agent-infra#1736)" ;;
    esac
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

# Does the `cell-doctor` session belong to THIS state dir? Its command string embeds this cell's log
# path (`tee -a '$O/logs/cell-doctor.log'`) and `O='$O'`, so the pane's start command is a per-cell
# proof — the only one available, since a session name is machine-scoped.
# 0 = the session is PROVABLY another cell's (its pane command names a different state dir).
# 1 = ours, or unknown (no pane answer at all): the caller heals rather than refusing a session it
#     cannot prove is foreign — refusing on "unknown" would make `start` unable to repair its own
#     leftover on a box whose `list-panes` is unavailable.
doctor_session_foreign() {
  local cmd
  cmd="$(tmux list-panes -t "=$DOCTOR_SESSION" -F '#{pane_start_command}' 2>/dev/null)" || return 1
  [ -n "$cmd" ] || return 1
  case "$cmd" in
    *"O='$O'"*|*"$O/logs/"*) return 1 ;;
  esac
  case "$cmd" in
    *"O='"*|*"/logs/cell-doctor.log"*) return 0 ;;
  esac
  return 1
}

# Is the recorded doctor loop process alive and STILL the same incarnation? (The doctor applies the
# same test to its own record; the supervisor needs it to keep `start` idempotent when the tmux session
# is gone but the loop is not.)
sup_loop_alive() {
  local lpid lident
  lpid="$(cat "$ROLES_DIR/loop.pid" 2>/dev/null)"
  lident="$(cat "$ROLES_DIR/loop.ident" 2>/dev/null)"
  case "${lpid:-}" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$lpid" 2>/dev/null || return 1
  [ -n "$lident" ] && [ "$lident" = "$lpid|$(sup_pid_ident "$lpid")" ] || return 1
  return 0
}

# End the doctor-LOOP process, identity-fenced (agent-infra#1989). Used by `stop` AND by a start's
# supersede teardown: `tmux kill-session` HUPs the pane's `sh -c` wrapper, but the loop is the far side
# of a `bash loop | tee` pipeline and can survive as an orphan that keeps running reap/merge/hygiene —
# so removing `loop.pid` without ending the process destroys the only handle a later `stop`/`status`
# has on it.
#   rc 0 — the loop is not running (ended, already gone, or a DIFFERENT incarnation abstained on)
#   rc 1 — a live pid matching the recorded identity survived TERM and KILL
#   rc 2 — CANNOT VERIFY: the pid is live but its identity cannot be read, so nothing here can say
#          whether ending it is safe. Never a pass: both callers report "could not end the loop".
end_loop_pid() { # [<pid> <ident>]
  local lpid="${1:-}" lident="${2:-}" i
  if [ -z "$lpid" ]; then
    lpid="$(cat "$ROLES_DIR/loop.pid" 2>/dev/null)"
    lident="$(cat "$ROLES_DIR/loop.ident" 2>/dev/null)"
    case "${lpid:-}" in ''|*[!0-9]*) lpid="" ;; esac
  fi
  [ -n "$lpid" ] || return 0
  kill -0 "$lpid" 2>/dev/null || return 0
  # ⛔ THREE OUTCOMES, NOT TWO (#1989 review). A live pid whose identity does NOT match is a RECYCLED
  # pid: abstain (never signal an innocent process) and report the loop gone — rc 0. But an identity
  # that cannot be READ is not evidence of a recycled pid: folding it into "gone" let a loop that
  # could not be verified survive a `stop` that returned success, and an unstopped doctor keeps
  # landing PRs. rc 2 = cannot-verify; both callers treat any non-zero as "could not end the loop".
  local lcur
  lcur="$(sup_pid_ident "$lpid")"
  [ -n "$lcur" ] || return 2
  [ -n "$lident" ] && [ "$lident" = "$lpid|$lcur" ] || return 0
  kill -TERM "$lpid" 2>/dev/null || true
  for i in 1 2 3 4 5; do kill -0 "$lpid" 2>/dev/null || break; sleep 1; done
  kill -0 "$lpid" 2>/dev/null && kill -KILL "$lpid" 2>/dev/null || true
  sleep 1
  kill -0 "$lpid" 2>/dev/null && return 1
  return 0
}

# ── start: controller under tmux (the launchd substitution) ─────────────────────
cmd_start() {
  # Refuse a bad SCOPE before anything starts or is written (validate_scope is also the first thing
  # cmd_check does below — this call is what keeps the refusal ahead of the $O seed).
  validate_scope
  # The stop generation this start is acting under (see the note above `stop_generation`). A caller
  # that LAUNCHED this start (the doctor's restart) passes the generation it observed, so a stop that
  # lands between the launch and this snapshot is still visible: without it, `cmd_start` would read the
  # POST-stop value as its baseline and never tear down — the window spans bash startup and the whole
  # source, not one instruction.
  local gen0; gen0="${STOP_GENERATION_AT_LAUNCH:-$(stop_generation)}"
  case "$gen0" in ''|*[!0-9]*) gen0="$(stop_generation)" ;; esac
  superseded() {
    [ "$(stop_generation)" = "$gen0" ] && return 1
    say "a STOP arrived while this start was running — aborting and leaving nothing running"
    tmux has-session -t "=$DOCTOR_SESSION" 2>/dev/null && tmux kill-session -t "=$DOCTOR_SESSION" 2>/dev/null || true
    tmux has-session -t "$SESSION" 2>/dev/null && tmux kill-session -t "$SESSION" 2>/dev/null || true
    # The loop this start just created is the only kill handle there is: end the PROCESS first, then
    # drop the record. (A `stop` racing us may already have read the record; either side ending it is
    # enough, and the fence makes a double-kill safe.)
    end_loop_pid || say "warn: the doctor loop survived the abort and could not be ended"
    rm -f "$ROLES_DIR/.desired" "$ROLES_DIR/loop.pid" "$ROLES_DIR/loop.ident"
    return 0
  }
  # Every value below is interpolated into the session command string, so every one must be
  # metacharacter-free — refuse loudly here rather than let tmux's sh -c parse it. Empty values
  # are skipped (cmd_check reports an unresolvable HARNESS with its own message).
  # ⛔ Ahead of both the queue-target gate and the `has-session` return: this is the INJECTION guard,
  # and its refusal is the one that must win for a value that reaches a shell string.
  local v
  # ⛔ SESSION is in this list because the DOCTOR's command string interpolates it (the controller's
  # does not — it only ever reaches tmux as an argv), so before #1989 it was never in a shell string.
  for v in O REPO CELL_HOME ENV_FILE HARNESS OR HARNESS_REPO HARNESS_PIN_DIR HARNESS_PIN_FILE HARNESS_REF SESSION SCOPE DOCTOR_SESSION SUP_SELF HARNESS_MATERIALISER; do
    [ -n "${!v}" ] || continue
    safe_argv "${!v}" || die "\$$v must not contain a quote or shell metacharacter: ${!v}"
  done
  # ── the QUEUE's repo is the CHECKOUT's remote (agent-infra#1901) ─────────────────────────────
  # A cell whose queue and checkout name different repos must not start at all, and the `has-session`
  # branch below is NOT a licence to bless it: on the measured cell a controller was ALREADY RUNNING,
  # so `start` would have returned rc=0 "already running" — the one answer an operator must never get
  # for a pair that is wrong. Placed here, ahead of the return and of every write below, so nothing
  # is seeded and no session is created on a refusal.
  assert_queue_target
  # Guard BEFORE seeding. $O is the controller's working copy and `start` on a live cell would
  # otherwise replace the worker scripts its next spawn executes (and race a half-copied script).
  # Nothing is started or written on this path, so a bad value below cannot hurt it.
  #
  # ⛔ A SESSION IS A MACHINE-SCOPED NAME (`orch`), NOT A PER-REPO ONE, and a pinned harness path is
  # shared by every repo on this cell: "a session exists" and "something is running for this repo"
  # are therefore different questions (#1856 review). Answer both, from the ownership read, and
  # never bless "already running" for a repo whose controller is somebody else's.
  if tmux has-session -t "$SESSION" 2>/dev/null; then
    local down seen0
    down="$(owned_controller_pids)" \
      || die "cannot read the process table (ps) — refusing to answer 'already running' from an unreadable read"
    seen0="$(seen_controller_pids)" \
      || die "cannot read the process table (ps) — refusing to answer 'already running' from an unreadable read"
    if [ -n "$down" ]; then
      say "already running (controller pid $(_pids_join "$down")) — use: status | logs | stop"
      # agent-infra#1989: a live controller with no doctor is exactly the measured state (one loop on
      # the box). `start` is the idempotent launch verb, so it heals that half too rather than
      # answering "already running" about a cell that cannot reap or land.
      start_doctor_loop
      # ⛔ ...and that heal is fenced like every other path in this function: a `stop` that lands while
      # `start_doctor_loop` runs must not be undone by the `.desired` marker / doctor session it just
      # created.
      superseded && return 1
      return 0
    fi
    # Nothing of ours holds it. Either this repo's loop has not written its lock yet (the seconds
    # `start` spends in check/seed — report it, do not refuse), or the session belongs to ANOTHER
    # repo sharing this cell's harness path (then it is not evidence about $OR at all).
    if [ -z "$seen0" ]; then
      say "already running (tmux session '$SESSION', no controller pid observed yet) — use: status | logs | stop"
      start_doctor_loop
      superseded && return 1
      return 0
    fi
    die "session '$SESSION' is held by a controller that is NOT provably this state dir's (pid $(_pids_join "$seen0"), no $LOCK owner, no $O/orch-loop.sh) — a session name is shared across repos, so it is not evidence that $OR is running; attach with: tmux attach -t $SESSION, or pin a distinct SESSION per repo in $ENV_FILE"
  fi
  # A controller can be running OUTSIDE the session (a leftover harness copy, or one whose lock a
  # launcher removed). Refuse, naming it: a second controller either exits on the lock (leaving a
  # confusing "controller exited immediately") or, with the lock gone, drains the SAME queue as the
  # first (#1761). The read is scoped to this cell's own paths — see the ownership block above.
  local live own
  live="$(seen_controller_pids)" \
    || die "cannot read the process table (ps) — refusing to start on an unreadable read"
  own="$(owned_controller_pids)" \
    || die "cannot read the process table (ps) — refusing to start on an unreadable read"
  if [ -n "$own" ]; then
    say "already running (controller pid $(_pids_join "$own")) — use: status | logs | stop"
    # agent-infra#1989: heal the doctor half on THIS path too — it returns "already running" about a
    # live controller exactly like the session branch above, and a cell with a controller but no
    # doctor still cannot reap, land or prune. Fenced like every other path in this function.
    start_doctor_loop
    superseded && return 1
    return 0
  fi
  if [ -n "$live" ]; then
    # ⛔ NOT "already running", and NOT rc=0. This state dir started NOTHING: the pid runs the harness
    # path this MACHINE shares, so it is unprovably another repo's controller. Answering 0 said "$OR is
    # up" when it was not, and named `stop` as the remedy — which this same state dir refuses in this
    # exact state (#1856 review, reproduced). Starting here would put a second controller on one
    # queue, which is what #1761 forbids, so refuse and say exactly what is and is not known.
    die "a controller runs from this machine's shared harness path (pid $(_pids_join "$live")) and is not provably this state dir's — refusing to start a second controller; it is left alone. Give this repo its own SESSION in $ENV_FILE, or stop it from the state dir that owns it"
  fi
  # ── the harness this cell will run, fixed BEFORE anything is seeded (agent-infra#1745) ────────
  # `start` is the one command that applies the proper harness: fetch, pin to $HARNESS_REF in a
  # detached worktree, seed, record. A cell therefore cannot be started on a stale or hand-copied
  # tree, and the operator's manual copy step is gone. A live session already returned at the guard
  # above, so the cache prune below cannot pull a cache out from under a running lane.
  # agent-infra#1932: `cmd_prune` no longer touches a per-worktree `.venv` at all — that delete is now
  # the reaper's, gated on positive proof that no lane is alive — so this unattended path is safe
  # whatever the session names are.
  local mb; mb="$(free_mb "$CELL_HOME")"
  case "${mb:-}" in
    ''|*[!0-9]*) ;;
    *) if [ "$mb" -lt "$((MIN_FREE_MB * 2))" ]; then
         # ⛔ The controller session is NOT the only thing running: orch-loop.sh spawns its workers
         # into their OWN detached sessions (`fix-<PR>`, `merge-<PR>`), and `stop` kills only the
         # controller — so after a `stop` a worker can still be mid-review. `cmd_prune --caches`
         # deletes `node_modules` and `__pycache__` at every worktree root, and a lane's dev server can
         # be holding the first of those. Skip the unattended delete while any worker session is alive,
         # and report the low-space state instead of acting.
         # ⛔ THIS NAME MATCH IS NOT THE VENV GUARD (agent-infra#1932). It never was a sound one: it
         # matches `lane-|fix-|merge-` and the sessions this fleet actually runs on a cell are `ai1932`
         # and `merge-8708` (measured on cell-2, 2026-10-17), so it reads "no workers" for a box full of
         # them. The `.venv` half of the sweep no longer depends on it; the remaining entries do.
         # ⛔ `grep -c`, NOT `grep -q`. An early exit down a pipe lets the producer take SIGPIPE, and
         # under `set -o pipefail` the pipeline then reports the producer's failure — so a MATCH read
         # as "no workers" and the unattended prune deleted a LIVE worker's .venv. `-c` consumes all
         # input. (`tmux ls | grep -c` below is already the safe form.)
         if workers_maybe_live; then
           say "warn: only ${mb}MB free, but workers may still be running — NOT auto-pruning caches (a pruned cache breaks the live lane). Run '$0 prune' once they finish."
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
  # which already holds every name in $WORKER_ENV_NAMES — so publish_worker_env() only acts on an
  # EXISTING one.
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
  # ⛔ THE SAME CONFIGURATION THE DOCTOR'S STRING CARRIES, FOR THE SAME REASON (agent-infra#2215). The
  # controller now re-pins ITSELF once per cycle (`harness-refresh.sh`), and the ONLY materialiser it may
  # call is this supervisor — so `HARNESS_MATERIALISER` names this very file, and the pin root/ref it
  # must act on are the OPERATOR'S, not whatever the child would re-derive from defaults. Without them
  # the child would default HARNESS_PIN_DIR to $CELL_HOME/harness: with CELL_HOME unset in the session
  # that default is `/tmp/cell-home/harness` (this file's own default), so the re-pin would create a
  # worktree nobody reads and write a pin pointing at it — a re-pin that advances nothing while reporting
  # success. The doctor's own note (see `start_doctor_loop`) records the measured cost of this same
  # omission for SCOPE. Every value here is already in the injection guard's list below (:1697).
  # ⛔ THE RECEIPT IS CLEARED FIRST, AND ONLY A RECEIPT FROM THIS LAUNCH COUNTS. Reading it after a
  # fixed sleep with no freshness guard is a FAIL-OPEN: a receipt left by a PREVIOUS start (or one
  # written before a tmux server start under load, which is the measured normal here) satisfies the
  # check while THIS session has not reached its own printf — so the check cannot fire for the case it
  # exists for, and the loop goes back to dying `FATAL REPO is not set`. Deleting it here makes any
  # file present later provably this launch's; the stamp is the belt to that braces.
  rm -f "$O/state/session-env"
  local _launch_at
  _launch_at="$(date +%s)"
  # ⛔ AND THE REPO A COMMAND ACTS ON IS PER-INVOCATION STATE, NEVER A GLOBAL EXPORT (measured
  # 2026-10-21, ported from the sibling lane's PR #2250). A pushed `keys.env` on a cell carried
  # `GH_REPO=daniel-ospina/tortoise`; `gh` honours `GH_REPO` as its default repo for EVERY command, so
  # an agent-infra rail on that box graded the TORTOISE repo and printed `ALREADY MERGED` for a
  # September tortoise PR — success over zero work, on the wrong repo, with nothing in the output saying
  # so (the same class #2235 fixes inside the rail). The session RE-SOURCES $ENV_FILE, so unsetting it
  # out here would be undone a few characters later: the `unset` lives INSIDE the command string,
  # immediately after the source, and the receipt then records what the session actually holds.
  tmux new-session -d -s "$SESSION" -c "$HARNESS" \
    "set -a; [ ! -f '$ENV_FILE' ] || . '$ENV_FILE'; set +a; unset GH_REPO; export PATH='$O/gh-limit':\"\$PATH\" HOME='$CELL_HOME' CELL_HOME='$CELL_HOME' REPO='$REPO' O='$O' OR='$OR' SCOPE='$SCOPE' HARNESS_REPO='$HARNESS_REPO' HARNESS_REF='$HARNESS_REF' HARNESS_PIN_DIR='$HARNESS_PIN_DIR' HARNESS_PIN_FILE='$HARNESS_PIN_FILE' HARNESS_MATERIALISER='${SUP_SELF:-}'; mkdir -p '$O/state'; printf 'at=%s\\nREPO=%s\\nHOME=%s\\nOR=%s\\nO=%s\\nGH_REPO=%s\\n' \"\$(date +%s)\" \"\$REPO\" \"\$HOME\" \"\$OR\" \"\$O\" \"\${GH_REPO:-<unset>}\" > '$O/state/session-env'; bash '$HARNESS/orch-loop.sh' 2>&1 | tee -a '$O/logs/controller.log'"
  # ⛔ THE SESSION RECEIPTS ITS OWN ENVIRONMENT, AND `start` READS IT (measured 2026-10-21). A tmux
  # session's environment comes from the tmux SERVER, not from the shell that called `new-session`: an
  # `export REPO=…` in this shell reaches nothing, and the controller died `FATAL REPO is not set` while
  # the launch line looked correct and the only trace was a log nobody reads. The assignments INSIDE the
  # command string are the fix; the receipt is the PROOF — printed by the session itself, before the
  # loop starts, so a value that did not survive is a named variable at launch instead of a dead loop.
  sleep 3
  if [ -r "$O/state/session-env" ]; then
    local _se_repo _se_at
    _se_at="$(sed -n 's/^at=//p' "$O/state/session-env" 2>/dev/null | head -1)"
    case "$_se_at" in ''|*[!0-9]*) _se_at=0 ;; esac
    # ⛔ THE STAMP IS READ, NOT JUST WRITTEN. A stamp nothing reads is decoration, and the next lane that
    # deletes the `rm -f` above "because the stamp guards it" restores the fail-open. This receipt must be
    # from THIS launch: anything older than the moment before `new-session` is a leftover.
    if [ "$_se_at" -lt "$((_launch_at - 1))" ]; then
      die "the environment receipt at $O/state/session-env is STALE (at=$_se_at, this launch began $_launch_at) — it is a leftover from an earlier start, so it cannot say what THIS session holds. Refusing rather than reporting a receipt that proves nothing"
    fi
    _se_repo="$(sed -n 's/^REPO=//p' "$O/state/session-env" 2>/dev/null | head -1)"
    [ -n "$_se_repo" ] || die "the controller's session holds an EMPTY REPO (receipt: $O/state/session-env) — the launcher passes it inside the session command, so an empty value here means REPO was empty in THIS shell (or keys.env unset it). Refusing: the loop would die 'FATAL REPO is not set'. Set REPO in $ENV_FILE (the session sources it) or in this command's own environment"
  else
    say "warn: the controller session wrote no environment receipt ($O/state/session-env) — cannot verify what REPO it holds"
  fi
  if tmux has-session -t "$SESSION" 2>/dev/null; then
    say "controller started (tmux '$SESSION'), state=$O"
    superseded && return 1
  else
    die "controller exited immediately — read $O/logs/controller.log"
  fi
  # The SECOND role. `start` is not successful unless the repair/merge loop is also up: a cell that
  # dispatches but cannot land is the measured #1989 state, and a start that reported success over
  # it would be the same false green this file refuses everywhere else.
  start_doctor_loop
  superseded && return 1
  return 0
}

# ── a stop SUPERSEDES an in-flight start (agent-infra#1989) ────────────────────────────────────────
# A `stop` that arrives while a `start` is running (notably the doctor's own `supervisor start`, which
# can take CONTROLLER_START_TIMEOUT) must WIN: without this, the restart completes after the stop,
# rewrites `.desired` and re-creates the controller and the doctor session — silently undoing the
# operator's stop. Process-group signalling cannot be relied on here (the restart runs under `timeout`,
# and killing its wrapper only orphans the real child), so the guarantee is a GENERATION COUNTER:
# `stop` bumps it as its first action; `start` snapshots it on entry and refuses to leave anything
# running if it moved. The restart pid is still recorded and killed as a fast path, best-effort.
STOP_GEN_FILE_REL="state/roles/.stop-generation"
stop_generation() {
  local f="$O/$STOP_GEN_FILE_REL" v
  v="$(cat "$f" 2>/dev/null)"
  case "${v:-}" in ''|*[!0-9]*) printf '0\n' ;; *) printf '%s\n' "$v" ;; esac
}
bump_stop_generation() {
  local f="$O/$STOP_GEN_FILE_REL" v
  # ⛔ NOT swallowed: the stop-wins guarantee rests on THIS write. On a full or read-only state dir
  # (the very condition the hygiene role exists to prevent) a silent no-op leaves the generation
  # unchanged, so an in-flight `start` sees no movement and completes after the stop — undoing it with
  # no signal at all. `cmd_stop` turns a non-zero return into a warning and a failed stop.
  mkdir -p "$O/state/roles" 2>/dev/null || return 1
  v="$(stop_generation)"
  printf '%s\n' "$((v + 1))" > "$f" 2>/dev/null || return 1
  return 0
}

# A process's identity, for the fenced backstop below. Deliberately LOCAL (the same rule as the
# doctor's `pid_ident`): `stop` must be able to end an orphaned loop WITHOUT the doctor being present.
# `/proc/<pid>/stat` field 22 is start time in clock ticks — one-second `lstart` cannot tell a pid
# recycled inside the same second from its predecessor.
sup_pid_ident() {
  local st f22
  st="$(cat "/proc/$1/stat" 2>/dev/null)"
  if [ -n "$st" ]; then
    f22="$(printf '%s' "$st" | sed 's/.*) //' | awk '{print $20}')"
    case "$f22" in ''|*[!0-9]*) ;; *) printf 'proc:%s\n' "$f22"; return 0 ;; esac
  fi
  ps -p "$1" -o lstart= 2>/dev/null
}

cmd_stop() {
  local rc=0 lpid lident rpid rident i
  # FIRST: drop the desired-state marker, THEN bump the generation. Both orders matter:
  #  * `.desired` gone before anything else means a pass that starts in the window below sees a
  #    "not started" cell (the doctor supervises nothing and launches no restart), and a pass already
  #    running sees the marker disappear (`cell_stopped_midpass`).
  #  * the bump is what an in-flight `start` re-checks; a bump that could not be recorded means that
  #    guarantee did NOT hold for this stop, so say so and fail the verb rather than report a stop
  #    that an in-flight start can still undo.
  # ⛔ Neither signal alone is sufficient: the generation is a counter, so a pass that snapshots it
  # AFTER the bump sees "no change" — the marker is the non-snapshotable half.
  # ⛔ A DOCTOR SESSION NAME IS MACHINE-SCOPED TOO (`cell-doctor` is the default for every cell on the
  # box), so "a session with this name exists" is NOT evidence that it is this cell's — the #1856
  # hazard, one layer out. Record the claim before the marker goes away: a started cell owns its
  # doctor, and the loop's own identity record proves it directly.
  rm -f "$ROLES_DIR/.desired" 2>/dev/null || { say "warn: could not remove $ROLES_DIR/.desired — an in-flight restart may re-arm this cell"; rc=1; }
  bump_stop_generation || { say "warn: could not record the stop generation in $O/$STOP_GEN_FILE_REL — an in-flight start may still complete and undo this stop"; rc=1; }
  # ORDER: the desired-state marker is dropped first (with the generation bump, above — the two stop
  # signals), then the restart child, then the doctor loop, then its pid backstop, then the marker is
  # removed again defensively, and only then the controller. If the marker outlived the loop, a
  # surviving pass would restart the controller the operator just stopped; if the loop outlived the
  # marker, its next pass reports "cell not started" and stops acting — harmless, but the session
  # would linger. `stop` is a REQUEST the operator makes once, and the marker is what makes it stick.
  # ⛔ KILLING THE SESSION IS NOT PROOF THE LOOP IS GONE. tmux HUPs the pane's `sh -c` wrapper, and
  # the loop is the far side of a `bash … | tee` pipeline: the wrapper dies, the loop can survive as
  # an orphan (its trap never fires) and keep LANDING PRs and pruning caches after an explicit
  # `stop`. So the recorded pid is the backstop — read and fenced REGARDLESS of whether the session is
  # still there (after a tmux server restart it is not, and that is exactly when an orphan is most
  # likely). `stop` is only successful when that pid is actually gone.
  lpid="$(cat "$ROLES_DIR/loop.pid" 2>/dev/null)"
  lident="$(cat "$ROLES_DIR/loop.ident" 2>/dev/null)"
  case "${lpid:-}" in ''|*[!0-9]*) lpid="" ;; esac
  # A restart child (run_doctor's backgrounded `supervisor start`) is killed FIRST as a FAST PATH.
  # ⛔ This is best-effort and NOT the guarantee: the restart runs under `timeout`, so the recorded pid
  # is a wrapper, and killing it can orphan the real child. The guarantee is the generation bump
  # above — `start` re-checks it before it finishes and tears down whatever it created.
  if [ -f "$ROLES_DIR/restart.ident" ]; then
    rident="$(cat "$ROLES_DIR/restart.ident" 2>/dev/null)"
    rpid="${rident%%|*}"
    case "${rpid:-}" in ''|*[!0-9]*) rpid="" ;; esac
    if [ -n "$rpid" ] && kill -0 "$rpid" 2>/dev/null && [ "$rident" = "$rpid|$(sup_pid_ident "$rpid")" ]; then
      kill -TERM "$rpid" 2>/dev/null || true
      sleep 1
      kill -0 "$rpid" 2>/dev/null && kill -KILL "$rpid" 2>/dev/null || true
      say "stopped an in-flight controller restart (pid $rpid)"
    fi
    rm -f "$ROLES_DIR/restart.ident"
  fi
  if tmux has-session -t "=$DOCTOR_SESSION" 2>/dev/null; then
    # ⛔ THE LIVE, IDENTITY-MATCHED LOOP RECORD IS THE ONLY PROOF (#1989 review b). This branch used
    # to also accept `had_desired`, and `$ROLES_DIR/.desired` OUTLIVES a SIGKILLed doctor: the marker
    # says this cell was started once, never that the session holding the machine-scoped name right
    # now is ours. So a stale marker plus a peer repo's doctor turned `stop` into a kill of the peer's
    # doctor. Ours-but-stale is the `else` arm below: reported, left alone, and healed by `start`.
    if sup_loop_alive; then
      tmux kill-session -t "=$DOCTOR_SESSION" || { say "warn: could not stop the doctor loop '$DOCTOR_SESSION'"; rc=1; }
      say "doctor loop stopped (tmux '$DOCTOR_SESSION')"
    else
      # No loop record and this cell was never started: the session is somebody else's doctor. Leave
      # it alone and say so — the same direction `stop` takes for a foreign CONTROLLER.
      say "note: doctor session '$DOCTOR_SESSION' exists but is not provably this cell's (no loop record, cell not started) — left alone"
    fi
  fi
  # ⛔ The "survived" verdict is FENCED too: a live pid whose recorded identity no longer matches is
  # a RECYCLED pid, not our loop — warning about it (and returning rc=1) would tell the operator that
  # a successful stop failed.
  if ! end_loop_pid "$lpid" "$lident"; then
    say "warn: the doctor loop (pid $lpid) survived the stop and could not be ended"; rc=1
  fi
  rm -f "$ROLES_DIR/.desired" "$ROLES_DIR/loop.pid"
  if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    own="$(owned_controller_pids)" \
      || die "cannot read the process table (ps) — refusing to report 'stopped' from an unreadable read"
    if [ -z "$own" ]; then
      # NOT "not running" while a $HARNESS-path controller is alive: reporting STOPPED over a live
      # controller is the false pass this read exists to remove (#1761). Report it; do not signal an
      # unasserted target.
      live="$(seen_controller_pids)" \
        || die "cannot read the process table (ps) — refusing to report 'stopped' from an unreadable read"
      [ -z "$live" ] || die "a controller is running outside session '$SESSION' (pid $(_pids_join "$live")) and does not hold $LOCK — refusing to report 'stopped'; stop it by hand"
      # Nothing of ours is running, but $LOCK is data on disk and outlives a kill/OOM/reboot. A lock
      # naming a DEAD pid is left behind by exactly that, and the harness's own `acq()` then reads
      # `kill -0` → gone → removes it, so it is only noise — but a lock naming a RECYCLED pid makes
      # `acq()` see a live process and exit 0 SILENTLY: the next start does nothing, and no surface
      # says why. Release the provably-dead case here and say so; a lock whose pid is alive but is
      # not an owner is reported above and never removed (we cannot prove it is not a controller we
      # simply cannot see).
      if [ -f "$LOCK" ]; then
        local lp; lp="$(tr -dc '0-9' 2>/dev/null < "$LOCK")"
        if [ -n "$lp" ] && ! kill -0 "$lp" 2>/dev/null; then
          rm -f "$LOCK" && say "released a stale lock $LOCK (its owner pid $lp is gone)"
        fi
      fi
      say "not running"
      # A doctor-loop stop failure recorded above still fails the verb: "not running" is about the
      # CONTROLLER, and this branch used to return 0 over it.
      [ "$rc" -eq 0 ] || return 1
      return 0
    fi
    say "no tmux session '$SESSION', but a controller is live (pid $(_pids_join "$own")) — stopping it"
  else
    # ⛔ A TMUX SESSION IS A MACHINE-SCOPED NAME (`orch` by default), NOT A PER-REPO ONE. Two repos on
    # one machine share it, so "a session with this name exists" is not evidence that THIS repo's
    # controller is in it — and killing it on that evidence is how repo B's `stop` TERMs repo A's
    # controller (#1856 review; measured with a tmux stub: B's stop killed A's live loop and reported
    # success). Prove the session holds something this state dir owns BEFORE killing; otherwise
    # report and refuse.
    own="$(owned_controller_pids)" \
      || die "cannot read the process table (ps) — refusing to kill a session on an unreadable read"
    if [ -z "$own" ]; then
      live="$(seen_controller_pids)" \
        || die "cannot read the process table (ps) — refusing to kill a session on an unreadable read"
      if [ -n "$live" ]; then
        die "session '$SESSION' is held by a controller that does NOT belong to this state dir (pid $(_pids_join "$live")) — refusing to kill another repo's controller; stop it from its own state dir, or pin a distinct SESSION per repo in $ENV_FILE"
      fi
      die "session '$SESSION' exists but nothing in it can be proven to be this state dir's controller (no $LOCK owner, no $O/orch-loop.sh) — refusing to kill a session this state dir cannot prove it owns; inspect it with: tmux attach -t $SESSION"
    fi
    # A failed kill must NOT fall through to the lock release and a 0 exit: `stop` would report
    # success while the controller is still running (the same "failed precondition as success" shape).
    tmux kill-session -t "$SESSION" || die "tmux kill-session failed for '$SESSION' — the controller may still be running"
    say "controller stopped (tmux '$SESSION')"
  fi
  # Terminate the owners this cell may signal, and PROVE they are gone BEFORE releasing the lock. A
  # lock removed while its owner lives is #1761's duplicate: the next `start` acquires it and runs a
  # second controller on the same queue.
  local i=0
  own="$(owned_controller_pids)" \
    || die "cannot read the process table (ps) — refusing to release $LOCK on an unreadable read"
  if [ -n "$own" ]; then
    for p in $own; do kill "$p" 2>/dev/null || true; done
    while [ "$i" -lt 15 ]; do
      sleep 1; i=$((i + 1))
      [ -z "$(owned_controller_pids)" ] && break
    done
    for p in $(owned_controller_pids); do kill -9 "$p" 2>/dev/null || true; done
    sleep 1
  fi
  # ⛔ THE POST-KILL ASSERTION IS OVER *OWNED*, NOT *SEEN*: a peer repo's controller running from the
  # shared harness path can never be stopped from here, so asserting on it would make this state
  # dir's `stop` fail forever while another repo runs — the owner's second half, broken (#1856
  # review). A leftover SEEN controller is REPORTED and left alone.
  own="$(owned_controller_pids)" \
    || die "cannot read the process table (ps) — NOT releasing $LOCK on an unreadable read"
  [ -z "$own" ] || die "controller(s) still alive after stop (pid $(_pids_join "$own")) — NOT releasing $LOCK"
  live="$(seen_controller_pids)" \
    || die "cannot read the process table (ps) — NOT releasing $LOCK on an unreadable read"
  foreign="$(_pids_minus "$live" "$own")"
  [ -z "$foreign" ] || say "note: a controller for ANOTHER repo is still running from the shared harness path (pid $(_pids_join "$foreign")) — left alone"
  rm -f "$LOCK" && say "released lock $LOCK"
  [ "$rc" -eq 0 ] || return 1
  return 0
}
cmd_status() {
  local cpids own foreign
  cpids="$(seen_controller_pids)" \
    || die "cannot read the process table (ps) — refusing to report a controller state from an unreadable read"
  own="$(owned_controller_pids)" \
    || die "cannot read the process table (ps) — refusing to report a controller state from an unreadable read"
  foreign="$(_pids_minus "${cpids:-}" "${own:-}")"
  if [ -n "$own" ]; then
    # Name the owner and the scope (#1761's per-box read): the answer to "which box owns this queue",
    # from the lock and this cell's own process scope — never the tmux session alone.
    say "controller: RUNNING (pid $(_pids_join "$own")) — scope=$SCOPE repo=$OR"
  elif [ -n "$cpids" ]; then
    # ⛔ SEEN BUT NOT OWNED. HARNESS_PIN_DIR is one directory per cell home, so a controller for a
    # DIFFERENT repo on this machine runs the SAME harness path and this read returns it (#1856
    # review, reproduced). Naming it as this state dir's owner would attribute another repo's work
    # to this queue, so say exactly what was read and which part is not ours.
    say "controller: RUNNING (pid $(_pids_join "$cpids")) — NOT this state dir's (another repo sharing the harness path); scope=$SCOPE repo=$OR"
  elif tmux has-session -t "$SESSION" 2>/dev/null; then
    # The session exists but no orch-loop.sh pid is visible yet: `start` spends seconds in
    # check/seed before the loop execs, so report starting — NOT the false STOPPED.
    say "controller: RUNNING (tmux '$SESSION', no orch-loop.sh pid observed yet) — scope=$SCOPE repo=$OR"
  else
    say "controller: STOPPED"
  fi
  [ -z "$foreign" ] || say "also seen:  pid $(_pids_join "$foreign") runs this machine's harness but does not hold $LOCK — another repo's controller; reported, never signalled"
  say "state dir: $O"
  # agent-infra#1901: does this cell stand where it is pointed? ONE line — the repo the queue targets,
  # the checkout it is standing in, and the remote that fact was read from. Reported, never refused:
  # `status` is the verb an operator runs to DISCOVER that the pair is wrong.
  say "queue: ${QUEUE_REPO:-<unknown>} @ $REPO — origin ${QUEUE_REMOTE:-<none>} [$(queue_state_text)]"
  # agent-infra#1745: the answer to "which commit is this cell running?", from the record `start`
  # wrote. Printed even when the controller is stopped — a stale cell is a stale cell.
  if [ -f "$STAMP" ]; then
    say "harness: $(stamp_field commit | cut -c1-12) [$(stamp_field relation)] from $(stamp_field harness)"
  elif [ -n "$HARNESS" ]; then
    say "harness: UNRECORDED at $HARNESS ($(harness_commit | cut -c1-12)) — run: $0 apply"
  fi
  # ── the PIN and the last self-refresh verdict (agent-infra#2215) ────────────────────────────────
  # MEASURED 2026-10-20: three cells ran 27 commits behind origin/main with an EMPTY pin. The stamp
  # above names the commit `start`/`apply` last SEEDED; the pin names what the cell is DEPLOYED to
  # now (the controller re-pins itself every cycle). They can legitimately disagree for one cycle
  # after a re-pin, which is why both are printed — but an EMPTY pin is never a quiet absence: its
  # own state, with the remedy, because it is the state the fleet sat in for hours.
  local _pin _pv _hrf _k _rel _run _act _at _age _fet
  _pin="${HARNESS_PIN:-$CELL_HOME/.pi/agent/state/HARNESS-PIN}"
  _pv="$(head -1 "$_pin" 2>/dev/null | tr -d '[:space:]')"
  if [ -n "$_pv" ]; then
    say "pin: ${_pv:0:12} ($_pin)"
  else
    say "⛔ PIN EMPTY ($_pin) — nothing here records which harness this cell is deployed to; that is the measured 2026-10-20 state of all three cells. The controller's next cycle records it (harness-refresh.sh); '$0 apply' additionally re-seeds from $HARNESS_REF."
  fi
  _hrf="$O/state/harness-refresh"
  if [ -f "$_hrf" ]; then
    for _k in $(cat "$_hrf" 2>/dev/null); do
      case "$_k" in
        relation=*) _rel="${_k#relation=}" ;; running=*) _run="${_k#running=}" ;;
        action=*)   _act="${_k#action=}" ;;   at=*)      _at="${_k#at=}" ;;
        fetch=*)    _fet="${_k#fetch=}" ;;
      esac
    done
    _age=""
    case "${_at:-}" in ''|*[!0-9]*) _age="age unknown (no usable at= — cannot-verify is not fresh)" ;;
      *) _age="$(( ( $(date +%s) - _at ) / 60 ))m ago" ;; esac
    say "self-refresh: ${_rel:-unknown} (runs ${_run:-unknown}, action=${_act:-none}, fetch=${_fet:-unknown}) — $_age"
    # ⛔ A RELATION IS ONLY AS GOOD AS THE COMPARISON IT WAS MADE FROM. `current` against a ref this cycle
    # could not fetch (or did not fetch) is cannot-verify, and the state record says so — but only if
    # `status` prints it, or the operator reads `current` and stops there.
    case "${_fet:-ok}" in
      ok) : ;;
      *) say "⛔ self-refresh comparison was NOT fresh (fetch=$_fet) — a 'current' above means 'current against the ref as of the last successful fetch', not against origin now" ;;
    esac
    # A verdict older than two cycles is not this cycle's answer: the controller has stopped
    # refreshing, so the pin above is a fact about the PAST. Same age-bound rule as the funnel, and the
    # SAME DEFAULT the loop coerces to (`orch-loop.sh` uses `CYC=240`) — `status` usually runs from an
    # operator shell where CYC is unset, so a 900 default here would fire ~8 cycles late while still
    # claiming "two".
    case "${_at:-}" in
      ''|*[!0-9]*) : ;;
      *) if [ $(( $(date +%s) - _at )) -gt $(( ${CYC:-240} * 2 + 300 )) ]; then
           say "⛔ self-refresh STALE (>${_age:-?}) — the controller is not re-pinning; the pin above describes an older cycle"
         fi ;;
    esac
  else
    say "self-refresh: NO RECORD at $_hrf — no cycle has recorded a self-refresh verdict yet (started before this check existed, or the loop cannot write state)"
  fi
  # agent-infra#1736: a PERMANENT dispatch-provisioning failure makes the cell MERGE-ONLY, and
  # nothing else in this output says so — `lanes: 0` is also what a healthy idle cell prints.
  # orch-loop.sh records the reason in .refresh-blocked; surface it instead of leaving it in a log.
  if [ -f "$O/.refresh-blocked" ]; then
    say "⛔ MERGE-ONLY: dispatch provisioning is BLOCKED — no implementation lane will be dispatched"
    sed 's/^/    /' "$O/.refresh-blocked"
  fi
  # agent-infra#1987: the cache bound runs on this cell's clock as a BACKGROUND job, so its exit
  # status is discarded at the call site (orch-loop.sh). A pass that fail-closes every hour — an
  # unmeasurable cache, an entry that cannot be sized, a shrink it could not verify — would
  # otherwise read exactly like a healthy cell, which is the blind spot #1987 was filed for.
  if [ -f "$O/state/.cache-reap-blocked" ]; then
    # NOT "fail-closed": exit 5 (a cache over bound on the shipped dry-run stance) is the common
    # case on an unarmed box, and the reaper's exit vocabulary calls only 3 fail-closed. The record
    # below already names the cause (5 = unarmed, 3 = the pass failed) — do not contradict it.
    say "⛔ CACHE BOUND NOT ENFORCED — the package-cache reaper's last pass:"
    sed 's/^/    /' "$O/state/.cache-reap-blocked"
  fi
  # agent-infra#2032: the scheduled DISK reaper. Its pass record is the only place that answers
  # "did the last unattended run succeed, and how much did it free" — a failed or STALE pass is
  # therefore a ⛔ line here, never an absence that reads like health. Disk exhaustion is the second
  # reason cells stopped working: at ~97% a controller still beats and every dispatch is refused.
  local _dr _drs _drc _dst _det cand
  _dr=""
  for cand in "${DISK_REAPER:-}" \
              "${HOME:-}/.pi/agent/scripts/disk-reaper.sh" \
              "$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/disk-reaper.sh"; do
    [ -n "$cand" ] && [ -f "$cand" ] && { _dr="$cand"; break; }
  done
  if [ -z "$_dr" ]; then
    say "⛔ DISK REAPER NOT INSTALLED — no disk-reaper.sh found (\$DISK_REAPER, \$HOME/.pi/agent/scripts, beside this script); the uv caches, dead lane venvs and merged worktrees are unbounded"
  else
    _drs="$(bash "$_dr" --print-status 2>/dev/null)"; _drc=$?
    _dst="$(printf '%s\n' "$_drs" | sed -n 's/^status=//p' | head -1)"
    _det="$(printf '%s\n' "$_drs" | sed -n 's/^detail=//p' | head -1)"
    if [ "$_drc" -eq 0 ]; then
            # ⛔ THE UNIT IS CONDITIONAL. A per-class field may read `unmeasured` (df could not answer),
            # and the old format appended a hardcoded MB to it — `uv=unmeasuredMB` reads as a byte count
            # to every consumer. Numeric values keep their unit; the sentinel is printed as it stands.
            _dr_mb() { case "${1:-}" in ''|*[!0-9]*) printf '%s' "${1:-?}" ;; *) printf '%sMB' "$1" ;; esac; }
            say "disk reaper: last pass $(printf '%s\n' "$_drs" | sed -n 's/^iso=//p' | head -1) ($(printf '%s\n' "$_drs" | sed -n 's/^age_seconds=//p' | head -1)s ago) mode=$(printf '%s\n' "$_drs" | sed -n 's/^mode=//p' | head -1) freed $(_dr_mb "$(printf '%s\n' "$_drs" | sed -n 's/^freed_mb=//p' | head -1)") (uv=$(_dr_mb "$(printf '%s\n' "$_drs" | sed -n 's/^freed_mb_uv=//p' | head -1)") venv=$(_dr_mb "$(printf '%s\n' "$_drs" | sed -n 's/^freed_mb_venv=//p' | head -1)") worktree=$(_dr_mb "$(printf '%s\n' "$_drs" | sed -n 's/^freed_mb_worktree=//p' | head -1)"))"
    elif [ "$_dst" = "never" ]; then
      say "⛔ DISK REAPER HAS NEVER RUN — installed but no pass recorded ($_det); start it: sudo systemctl start eldato-disk-reaper.service (Linux) / launchctl kickstart gui/$(id -u)/com.eldato.disk-reaper (macOS)"
    elif [ "$(printf '%s\n' "$_drs" | sed -n 's/^rc=//p' | head -1)" = "6" ] \
         && _dage="$(printf '%s\n' "$_drs" | sed -n 's/^age_seconds=//p' | head -1)" \
         && [ -n "$_dage" ] && [ "$_dage" -ge 0 ] 2>/dev/null \
         && [ "$_dage" -le "${DISK_REAPER_STALE_SECONDS:-7200}" ]; then
      # ⛔ A DEFERRAL IS NOT A FAILURE, AND THE HEADLINE IS WHAT AN OPERATOR READS. rc=6 means a delegate
      # ran and declined (a live tool holds a cache) — the routine state of a busy cell, and the exact
      # condition the unit's `SuccessExitStatus=0 6` and the armed prune's benign set were widened for.
      # ⛔ BUT ONLY WHILE THE RECORD IS FRESH. rc=6 implies ok=0, and `print_status` only computes
      # `stale` when ok=1 — so without this bound a reaper whose timer DIED after one deferred pass
      # would print "⏸ deferred" for ever, and the ⏸ is exactly the symbol an operator has been trained
      # to skip. A stale deferral falls through to the ⛔ arm, which names the age.
      # (⚠️ This verb's exit code comes from the doctor's status, not the reaper's, so the headline IS
      # the channel here — which is why it must not go quiet.)
      say "⏸ DISK REAPER DEFERRED — status=failed rc=6 last=$(printf '%s\n' "$_drs" | sed -n 's/^iso=//p' | head -1) (${_dage}s ago): ${_det:-no detail} (a delegate declined; nothing was claimed)"
      say "    per class: uv=$(printf '%s\n' "$_drs" | sed -n 's/^verdict_uv=//p' | head -1) venv=$(printf '%s\n' "$_drs" | sed -n 's/^verdict_venv=//p' | head -1) worktree=$(printf '%s\n' "$_drs" | sed -n 's/^verdict_worktree=//p' | head -1)"
    else
      say "⛔ DISK REAPER NOT HEALTHY — status=${_dst:-unknown} rc=$(printf '%s\n' "$_drs" | sed -n 's/^rc=//p' | head -1) last=$(printf '%s\n' "$_drs" | sed -n 's/^iso=//p' | head -1): ${_det:-no detail}"
      say "    per class: uv=$(printf '%s\n' "$_drs" | sed -n 's/^verdict_uv=//p' | head -1) venv=$(printf '%s\n' "$_drs" | sed -n 's/^verdict_venv=//p' | head -1) worktree=$(printf '%s\n' "$_drs" | sed -n 's/^verdict_worktree=//p' | head -1)"
    fi
  fi
  # the loop's own view of itself
  tail -3 "$O/logs/orch-loop.log" 2>/dev/null | sed 's/^/  /' || say "  (no orch-loop.log yet)"
  # ⛔ NOT `tmux ls | grep -c '^lane-'`: a cell's lanes are durable terminals now, so that answered 0
  # for a busy box. An unreadable census prints UNKNOWN, never 0.
  say "lanes: $(worker_census 2>/dev/null || echo UNKNOWN)"
  # agent-infra#1989: CONFIGURED vs RAN. Each role's own last-pass record is printed, and a started
  # cell whose role never ran / went stale fails this verb — the issue's validation requirement, and
  # the fix for the measured "a dead loop looks identical to an idle cell".
  local d rl rrc=0
  if d="$(doctor_path)"; then
    rl="$(CELL_HOME="$CELL_HOME" O="$O" REPO="$REPO" OR="$OR" SESSION="$SESSION" bash "$d" status 2>&1)"
    rrc=$?
    printf '%s\n' "$rl" | sed 's/^/  /'
  else
    say "  roles: UNKNOWN — cloud-cell-doctor.sh not found (run: $0 apply)"
    [ -f "$ROLES_DIR/.desired" ] && rrc=1
  fi
  return "$rrc"
}

cmd_logs() { tail -30 "$O/logs/orch-loop.log" 2>/dev/null || say "no log yet at $O/logs/orch-loop.log"; }

# ── the cell doctor's roles (agent-infra#1989) ──────────────────────────────────────────────────
# `cloud-cell-doctor.sh` owns the passes; this file owns the launch and the report. The seeded copy
# in $O is preferred because $O is what the harness provenance record describes (cmd_check pins the
# payload hash), and falling back to the copy beside this supervisor keeps `doctor`/`merge`/`reap`
# usable on a cell that has not been started yet.
doctor_path() {
  local c
  for c in "$O/cloud-cell-doctor.sh" "$(dirname "$SUP_SELF")/orchestrator-harness/cloud-cell-doctor.sh" \
           "$(dirname "$SUP_SELF")/cloud-cell-doctor.sh"; do
    [ -n "$c" ] && [ -f "$c" ] && { printf '%s\n' "$c"; return 0; }
  done
  return 1
}

# One role pass, in this cell's own environment. `doctor` and `merge` resolve the queue target first
# (assert_queue_target) and pass the RESOLVED OR, so the doctor never re-derives a second one; `reap`
# and `hygiene` do not need OR — they touch tmux sessions, $O and $REPO only.
run_role() {
  local role="$1" d; shift
  d="$(doctor_path)" || die "cloud-cell-doctor.sh not found (looked in $O, then beside $SUP_SELF in orchestrator-harness/, then beside $SUP_SELF) — run '$0 start' (it seeds $O) or '$0 apply'"
  # ⛔ THE SAME configuration the loop's command string carries, for the same reason: a role that
  # restarts the controller (`doctor` -> run_doctor -> `$SUPERVISOR start`) must not re-derive the
  # operator's values from defaults. Without SCOPE an ambient-only `SCOPE=own` pin comes back as
  # `auto` (BROAD above 10 open PRs drains the shared queue — #5052), and without DOCTOR_SESSION the
  # restart spawns a SECOND loop under the default name (two loops on one state dir, and a `stop` on
  # the custom name cannot end the duplicate).
  CELL_HOME="$CELL_HOME" O="$O" REPO="$REPO" OR="$OR" SESSION="$SESSION" \
    SCOPE="$SCOPE" ENV_FILE="$ENV_FILE" DOCTOR_SESSION="$DOCTOR_SESSION" \
    HARNESS_REPO="$HARNESS_REPO" HARNESS_REF="$HARNESS_REF" \
    HARNESS_PIN_DIR="$HARNESS_PIN_DIR" HARNESS_PIN_FILE="$HARNESS_PIN_FILE" \
    MIN_FREE_MB="$MIN_FREE_MB" DOCTOR_SUPERVISOR="$SUP_SELF" \
    bash "$d" "$role" "$@"
}

# The loop `start` runs. Idempotent by tmux session name: a second `start` (or a restart driven from
# inside the loop) finds it and returns, so the cell never grows two doctors. The desired-state
# marker is what tells the doctor that the cell is SUPPOSED to be up — without it a `stop` would be
# undone by the next pass, and an operator's stop would never stick.
start_doctor_loop() {
  local d
  mkdir -p "$ROLES_DIR" "$O/logs" || die "cannot create $ROLES_DIR"
  : > "$ROLES_DIR/.desired" || die "cannot record the desired running state at $ROLES_DIR/.desired"
  d="$(doctor_path)" || die "cloud-cell-doctor.sh not found (looked in $O, then beside $SUP_SELF in orchestrator-harness/, then beside $SUP_SELF) — the cell cannot run its repair/merge roles"
  if tmux has-session -t "=$DOCTOR_SESSION" 2>/dev/null; then
    # ⛔ A DOCTOR SESSION NAME IS MACHINE-SCOPED (`cell-doctor` is the default for EVERY cell on a
    # box), so "a session with this name exists" is not evidence that it is OURS — the same hazard the
    # controller's shared `SESSION` branch resolves, one layer out. Blessing a foreign session would
    # leave this cell with no doctor at all (its reap/merge/hygiene roles silently never run) while
    # `start` printed "already running".
    if sup_loop_alive; then
      say "doctor loop already running (tmux '$DOCTOR_SESSION', pid $(cat "$ROLES_DIR/loop.pid" 2>/dev/null))"
      return 0
    fi
    if doctor_session_foreign; then
      die "doctor session '$DOCTOR_SESSION' belongs to another state dir — a session name is shared across cells, so it is not evidence that $OR has a doctor; pin a distinct DOCTOR_SESSION per cell in $ENV_FILE, or stop the cell that owns it"
    fi
    # Ours-but-stale (its loop record is gone) or unprovable: replacing it is the heal `start` exists
    # for, and the alternative — reporting "already running" — would leave this cell with no doctor at
    # all while printing success.
    say "doctor session '$DOCTOR_SESSION' has no live loop record — replacing it with a fresh loop"
    tmux kill-session -t "=$DOCTOR_SESSION" 2>/dev/null || true
  fi
  # ⛔ A LIVE LOOP RECORD COUNTS AS RUNNING even with no session. After a tmux server restart the
  # session is gone while the loop survives as an orphan — the state `cmd_stop`'s own note calls the
  # likeliest one. That orphan's next pass sees the controller session absent and calls
  # `supervisor start`; a session-only idempotency check would create a SECOND loop, which overwrites
  # `loop.pid` and hides the orphan from `stop`/`status` (and every later `start` adds another).
  if sup_loop_alive; then
    say "doctor loop already running (pid $(cat "$ROLES_DIR/loop.pid" 2>/dev/null) — no tmux session, likely a tmux server restart)"
    return 0
  fi
  # ⛔ The command string interpolates only values cmd_start has already validated (see the note on
  # the two exceptions below). The loop re-sources $ENV_FILE for the same reason the controller does:
  # a tmux session is served
  # from the SERVER's environment on a pre-existing server, so this shell's exports would be dropped.
  # ⛔ CARRY THE OPERATOR'S CONFIGURATION, not the defaults: this loop RESTARTS the controller
  # (`run_doctor` -> `$SUPERVISOR start`), so a value that is only ambient at the original `start`
  # (SCOPE=own, a non-default ENV_FILE, a pinned HARNESS_REF/pin dir) would be re-derived from
  # defaults on that restart — a cell pinned to OWN scope would come back as AUTO, which takes BROAD
  # above 10 open PRs and drains the shared queue (the measured #5052 behaviour this pin exists to
  # avoid), and a custom keys.env would silently drop the merge key. Same allow-list as the
  # controller's command string. `safe_argv` covers every value EXCEPT two, which are safe by other
  # means and are named here so this note is not an overclaim: MIN_FREE_MB is normalised to a base-10
  # integer above, and `$d` (the doctor path) is derived from the guarded `$O`/`$SUP_SELF`.
  # ⛔ AND `unset GH_REPO` IS IN THIS STRING TOO: the doctor can restart the controller, and it
  # re-sources $ENV_FILE itself, so a pushed global GH_REPO would come back with it (ported from the
  # sibling lane's PR #2250 — one string without the unset is the half-fix).
  tmux new-session -d -s "$DOCTOR_SESSION" -c "$HARNESS" \
    "set -a; [ ! -f '$ENV_FILE' ] || . '$ENV_FILE'; set +a; unset GH_REPO; HOME='$CELL_HOME' CELL_HOME='$CELL_HOME' O='$O' REPO='$REPO' OR='$OR' SESSION='$SESSION' SCOPE='$SCOPE' ENV_FILE='$ENV_FILE' DOCTOR_SESSION='$DOCTOR_SESSION' HARNESS_REPO='$HARNESS_REPO' HARNESS_REF='$HARNESS_REF' HARNESS_PIN_DIR='$HARNESS_PIN_DIR' HARNESS_PIN_FILE='$HARNESS_PIN_FILE' MIN_FREE_MB='$MIN_FREE_MB' DOCTOR_SUPERVISOR='$SUP_SELF' bash '$d' loop 2>&1 | tee -a '$O/logs/cell-doctor.log'"
  sleep 2
  if tmux has-session -t "=$DOCTOR_SESSION" 2>/dev/null; then
    say "doctor loop started (tmux '$DOCTOR_SESSION')"
  else
    # NOT fatal: cloud-cell-doctor.sh was retired (#2160) and is no longer shipped, so a
    # missing doctor must not take the CONTROLLER down with it. Measured 2026-10-20: `start`
    # reported FATAL one second after the controller began dispatching correctly, on every
    # cell that used the shipped start path.
    say "warning: the doctor loop is unavailable (cloud-cell-doctor.sh not shipped) — the controller runs, but reaping/hygiene is NOT automatic; read $O/logs/cell-doctor.log"
    return 0
  fi
}

cmd_doctor()  { assert_queue_target; run_role doctor "$@"; }
cmd_merge()   { assert_queue_target; run_role merge "$@"; }
cmd_reap()    { run_role reap "$@"; }
cmd_hygiene() { run_role hygiene "$@"; }

# ── apply: put the PROPER harness on this cell (agent-infra#1745) ─────────────────────────────────
# The owner's complaint was that "apply our harness to the cell" should be one simple job and had
# taken days. It is this command, and `start` runs the same code — so it is normally not typed.
cmd_apply() {
  validate_scope
  local force=0 a live="" pin_only=0
  for a in "$@"; do
    case "$a" in
      --force) force=1 ;;
      --pin-only) pin_only=1 ;;
      *) die "usage: $0 apply [--force] [--pin-only]" ;;
    esac
  done
  # Only a NON-EMPTY value is a metacharacter question; `safe_argv` returns non-zero for '' too.
  # ⛔ THE LINE BELOW IS STILL BROKEN and the comment above it USED to claim otherwise: `A && B || C`
  # runs `C` when `A` FAILS, so an empty $HARNESS_REPO takes the `die` branch — and harness_apply()'s
  # accurate "no git checkout resolved" never prints. The two PIN lines below LOOK alike but are NOT
  # exposed to that misfire: both are defaulted at load (:646-647, after source_env_file), so they
  # cannot arrive empty and their message is only printed for a value that really is unsafe.
  # Filed with the measurement: agent-infra#2002; NOT changed here, because this PR's subject is
  # controller ownership and the behaviour is unchanged from origin/main.
  [ -n "$HARNESS_REPO" ] && { safe_argv "$HARNESS_REPO" || die "\$HARNESS_REPO must not contain a quote or shell metacharacter: $HARNESS_REPO"; }
  safe_argv "${HARNESS_PIN_DIR:-}" || die "\$HARNESS_PIN_DIR must not contain a quote or shell metacharacter"
  safe_argv "${HARNESS_PIN_FILE:-}" || die "\$HARNESS_PIN_FILE must not contain a quote or shell metacharacter"
  local before_c; before_c="$(harness_commit)"
  # Same authority as `start`/`status`: a controller outside the session still owns the harness tree
  # this verb is about to replace, so the tmux session is not sufficient (#1761).
  if [ "$force" != 1 ]; then
    live="$(seen_controller_pids)" \
      || die "cannot read the process table (ps) — refusing to replace the harness tree on an unreadable read"
    # ⛔ THE REFUSAL IS RIGHT EVEN WHEN THE CONTROLLER IS ANOTHER REPO'S, and the message says so:
    # the harness tree is SHARED across repos on one machine, so replacing it changes the code a peer
    # repo's controller is running. The false-block direction is a real cost (the owner's second
    # half), so name the pid, say it may not be yours, and give the remedy rather than implying
    # `stop` will clear it.
    [ -z "$live" ] || die "a controller is RUNNING (pid $(_pids_join "$live")) — possibly another repo's, from this cell's shared harness path — and apply would replace the harness tree under it; 'stop' it from its own state dir, or re-run with --force"
    tmux has-session -t "$SESSION" 2>/dev/null \
      && die "a controller is RUNNING (tmux '$SESSION') and apply would replace the harness tree under it — 'stop' first, or re-run with --force"
  fi
  harness_apply
  # ⛔ `--pin-only` IS THE PATH A RUNNING CELL USES TO ADVANCE WITHOUT VERSION SKEW (agent-infra#2215).
  # `harness_apply` pins per commit into $HARNESS_PIN_DIR/<sha12> and never removes the pin the running
  # controller executes from, so the PIN can advance while $O and the controller stay on the commit they
  # were launched with. Seeding $O underneath a LIVE controller is what the `--force` guard exists to
  # stop an operator doing by accident: it swaps helpers (`lane.sh`, `claims.sh`, …) while the loop that
  # calls them is the OLD `orch-loop.sh`, i.e. a version skew no other path in this repo produces.
  # So the per-cycle self-refresh advances the pin with `--pin-only`, and the next `start` seeds $O from
  # the NEW pin (start calls seed_and_stamp) — one cycle of "pinned ahead, running behind", disclosed
  # as `restart-pending`, and never a mixed pair of script versions in one loop.
  if [ "$pin_only" = 1 ]; then
    say "harness PINNED: ${before_c:0:12}${before_c:+ → }${HARNESS_COMMIT:0:12} (${HARNESS_REL})${HARNESS_APPLIED:+ [$HARNESS_APPLIED]}"
    say "  path:   $HARNESS"
    say "  ref:    $HARNESS_REF in $HARNESS_REPO"
    say "  record: $HARNESS_PIN_FILE (seed NOT updated: 'start' re-seeds \$O from this pin, so running code never mixes two harness commits)"
    return 0
  fi
  seed_and_stamp
  say "harness applied: ${before_c:0:12}${before_c:+ → }${HARNESS_COMMIT:0:12} (${HARNESS_REL})${HARNESS_APPLIED:+ [$HARNESS_APPLIED]}"
  say "  path:   $HARNESS"
  say "  ref:    $HARNESS_REF in $HARNESS_REPO"
  say "  record: $STAMP"
}

# ── the lane-venv reaper this cell delegates to (agent-infra#1932) ────────────────────────────────
# Resolved from the harness checkout (`$HARNESS/..` is the agent-infra `scripts/` dir), then the farm.
# Returns non-zero when it cannot be found, and the CALLER KEEPS the venv in that case: a fallback to
# `rm -rf` is exactly the defect this replaced, so there is deliberately no fallback.
venv_reaper_path() {
  local c
  for c in "$HARNESS/../reap-lane-venvs.sh" "${HOME:-}/.pi/agent/scripts/reap-lane-venvs.sh" \
           "${AGENT_INFRA_PATH:-}/scripts/reap-lane-venvs.sh"; do
    [ -n "$c" ] && [ -f "$c" ] && { printf '%s\n' "$c"; return 0; }
  done
  return 1
}

# reclaim_lane_venvs <repo> — run the GC over that repo's worktrees. Prints the reaper's own report
# (including the KEPT list and the evidence for each keep). Exit statuses are NOT propagated: a
# fail-closed abort (3) leaves every env in place, which is the safe outcome for `prune`, and a
# `prune` that died because one probe was unavailable would leave the rest of the reclaim undone.
reclaim_lane_venvs() {
  local repo="$1" reaper mb_before mb_after rc=0
  [ -n "$repo" ] && [ -d "$repo" ] || return 0
  mb_before="$(free_mb "$CELL_HOME")"
  if ! reaper="$(venv_reaper_path)"; then
    say "prune: warn: reap-lane-venvs.sh not found (harness \$HARNESS, ~/.pi/agent/scripts, \$AGENT_INFRA_PATH) — every worktree .venv is KEPT. A blind rm here would delete a live lane's env; that is what #1932 removed."
    return 0
  fi
  # ⛔ rc=5 is NOT a failed reap (review of PR #1949): the reaper exited 5 because free disk is below
  # REAP_VENV_FREE_FLOOR_MB AFTER a pass that did its job. The old one-line `||` message described every
  # non-zero as "env kept because it fails closed", which is the opposite of what happened and would send
  # an operator looking for a live-lane witness that was never the problem. Name the breach instead.
  bash "$reaper" --gc --repo "$repo" --apply || rc=$?
  case "$rc" in
    0) ;;
    # ⛔ rc=4 IS NOT THE FAIL-CLOSED CASE *AND NOT ONLY A FAILED REMOVAL EITHER* (review of PR #1949,
    # P2). The reaper exits 4 from `[ "$FAILED" -gt 0 ] && exit 4`, and `FAILED` is incremented by TWO
    # different outcomes: a removal that was ATTEMPTED and failed (REMOVE-FAILED — the env was proven
    # dead and is still on disk), AND a removal-time re-probe that failed CLOSED (`cwd_load`/`tmux_load`/
    # `ps_load` unavailable, or no scratch dir) where `remove_one` returns 1 and the env is deliberately
    # KEPT. Naming only the first told an operator the env "was proven dead" and to hunt a REMOVE-FAILED
    # line that does not exist on the second path; naming only the second (the previous wording) was the
    # same error inverted. The arm states both, because `4` carries both.
    4) say "prune: warn: a lane-venv removal did not complete (rc=4) — either it was proven dead and the delete FAILED (see the reaper's REMOVE-FAILED lines), or a removal-time re-probe failed closed and the env was KEPT (see FAIL-CLOSED); the reaper's own log says which" ;;
    5) say "prune: warn: free disk is BELOW REAP_VENV_FREE_FLOOR_MB after the lane-venv pass — the reap completed, but a lane starting now can fill the disk (rc=5; see the reaper's capacity line)" ;;
    *) say "prune: warn: the lane-venv reaper exited $rc — any env it could not prove dead was kept (it fails closed)" ;;
  esac
  mb_after="$(free_mb "$CELL_HOME")"
  [ -n "$mb_before" ] && [ -n "$mb_after" ] && say "prune: lane venvs: free ${mb_before}MB → ${mb_after}MB"
  return 0
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
# ⛔ `.venv` IS DELIBERATELY ABSENT (agent-infra#1932). It is not an anonymous cache: it belongs to the
# lane that ran `uv sync` in this worktree, and deleting a LIVE lane's env breaks it mid-test. Reclaiming
# it therefore needs a liveness proof, which this function does not have and must not approximate —
# `reclaim_lane_venvs()` above is the only caller of the only tool allowed to delete one. The remaining
# entries are pure build/test cache with no owner. `node_modules` is arguably in the SAME class as
# `.venv` once a lane's dev server holds it — but it is NOT on the measured 7.3 GB, and widening this
# change to cover it would need its own liveness proof and its own review; it stays as it was, visibly,
# rather than being silently folded in here.
sweep_root_caches() {
  local root="$1"
  [ -d "$root" ] || return 0
  rm_cache "$root/node_modules"; rm_cache "$root/.pytest_cache"
  find "$root" -maxdepth 5 -type d -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null || true
}

# The MACHINE-GLOBAL package caches (agent-infra#1987) — a sink sweep_root_caches can NEVER reach:
# every path above is resolved from a WORKTREE root, and the space that took `pi-cell-3` to 258MB
# free was `$HOME/.cache/uv` at 7.1GB, shared by every lane on the box. So `prune` (the low-disk
# remedy `start` calls unattended, and the verb an operator reaches for) must bound it too, or the
# remedy reports a freed-disk number while the largest consumer is untouched.
# The POLICY is not re-implemented here: it is delegated to scripts/pi-cache-reap.sh, its single
# owner (prune first; then evict only entries no live process is holding, stopping as soon as
# deletion stops reclaiming disk; exit 3 when a shrink it acted on is unverified). This function
# only finds that script.
cache_reaper_path() {
  local cand
  # ${CACHE_REAPER:-} FIRST, exactly like orchestrator-harness/orch-loop.sh: one override must not
  # be honoured by the clock and ignored by the only ARMED caller, or two copies of a deletion
  # policy run on one box, chosen by two different rules.
  # ONE chain, the same one orchestrator-harness/orch-loop.sh and cloud-cell-bringup.sh use:
  # ${CACHE_REAPER:-} -> the FARMED copy (what the launchd job and the cell clock execute) -> the
  # copy beside this script. Farmed BEFORE beside-this-script matters: this supervisor is never
  # farmed (pi-bootstrap/setup.sh's fleet_srcs does not list it), so a lane running it from a
  # checkout would otherwise arm a copy it is mid-edit on while the hourly bound the operator reads
  # about is a different file.
  for cand in "${CACHE_REAPER:-}" \
              "${HOME:-}/.pi/agent/scripts/pi-cache-reap.sh" \
              "$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/pi-cache-reap.sh"; do
    [ -n "$cand" ] || continue
    if [ -f "$cand" ]; then printf '%s' "$cand"; return 0; fi
  done
  return 1
}

reap_global_caches() {
  local reaper rc
  if ! reaper="$(cache_reaper_path)"; then
    # NEVER silent: a prune that leaves the biggest consumer alone because a script was missing is
    # the same false PASS this repo keeps removing. Named, with the remedy.
    say "warn: pi-cache-reap.sh not found (looked beside this script and in \$HOME/.pi/agent/scripts) — the machine-global uv/npm/pip caches were NOT bounded. Farm it: bash pi-bootstrap/setup.sh"
    return 0
  fi
  rc=0
  bash "$reaper" --apply || rc=$?
  # 4 = it did not run (another pass holds the lock); 5 = a cache is over its bound, which cannot
  # happen on this --apply path but is neutral by design; 7 = DEFERRED (a live uv/npm/pip holds the
  # cache, so the entries it keeps cannot be known). None is a failure, and warning about them would
  # train the reader to ignore the one line that matters. ⛔ 7 IS ON THIS LIST FOR A REASON: it is the
  # most common outcome on a busy cell, and this is the only ARMED call site — leaving it out would
  # print a warning every hour on a healthy box, which is the alarm-fatigue defect this code was
  # written to avoid (and the one `disk-reaper.sh` now maps to a green unit). 3 stays a warning.
  [ "$rc" -eq 0 ] || [ "$rc" -eq 4 ] || [ "$rc" -eq 5 ] || [ "$rc" -eq 7 ] || say "warn: the cache reaper exited $rc — see ${CACHE_REAP_LOG:-$HOME/.pi/agent/state/pi-cache-reap.log}"
  return 0
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
    # that is not an empty dir, a linked worktree, or a pin root of hex-named directories (plus a root
    # whose only other entries are `.DS_Store`/`._*` regular files — see its header for the allow-list).
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
          2) say "prune: NOT reclaiming $d — cannot VERIFY it is a pin: ${PIN_OWNED_ERR:-HARNESS_REPO is unresolved or not a git checkout}. Fix HARNESS_REPO (or the object store), then re-run '$0 prune'"
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
    # (0b) LANE VENVS (agent-infra#1932). Delegated, per repo, and the ONLY thing in this verb that
    # touches a `.venv`: the reaper needs the liveness proof this file cannot make, and it reports every
    # removal AND every keep with the evidence that decided it. It runs before the anonymous caches so a
    # fail-closed abort (unreadable probe) is visible in the same report.
    reclaim_lane_venvs "$r"
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
  reap_global_caches
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
  check)   cmd_check ;;
  start)   cmd_start ;;
  apply)   shift; cmd_apply "$@" ;;
  prune)   shift; cmd_prune "$@" ;;
  stop)    cmd_stop ;;
  status)  cmd_status ;;
  logs)    cmd_logs ;;
  doctor)  shift; cmd_doctor "$@" ;;
  merge)   shift; cmd_merge "$@" ;;
  reap)    shift; cmd_reap "$@" ;;
  hygiene) shift; cmd_hygiene "$@" ;;
  *)       say "usage: $0 check|start|stop|status|logs|apply|prune|doctor|merge|reap|hygiene"; exit 2 ;;
esac
