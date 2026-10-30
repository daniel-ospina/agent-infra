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
# The lanes were never launchd's, and they belong to neither launcher camp: both controllers spawn
# through `worker-terminal.sh`, which asks the cmux daemon for a DURABLE TERMINAL wherever it answers
# and otherwise uses tmux (the launchd Mac, and a cell whose guest CLI cannot run) **with an explicit
# HOME + keys.env environment contract**. A tmux worker started without that contract is the measured
# `~21 log lines` death (agent-infra#2210, reopened: the credential is HOME-bound, so a worker with the
# wrong HOME has none). Where NO surface exists the launcher REFUSES loudly; there is no env override,
# because a gate an agent can defeat with an export is not a gate.
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
#           A full disk is what breaks a cell FIRST. --exclude-root=PATH (repeatable, absolute) skips
#           the per-worktree cache sweep at PATH — the seam the doctor's hygiene role uses to leave a
#           worktree a LIVE process is sitting in alone while still reclaiming the idle ones
#           (agent-infra#2573; the exclusion is reported by path, never applied silently).
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
#   hygiene `uv cache prune`, the `cloud-cell-*` temp dirs (agent-infra#2573), idle docker
#           images/volumes, worktree-root caches (a root a live process holds is EXCLUDED and named,
#           never a reason to skip every root), stale worktrees via the shipped
#           `pi-reap-worktrees.sh` (armed only under disk pressure by default). Every pass reports a
#           `df` delta and never a `du` sum.
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
# ⛔ REPO HAS NO PATH DEFAULT (agent-infra#1935). This line used to be `REPO="${REPO:-/tmp/cell}"`,
# and that path does not exist on the cloud cell: `start` died with `FATAL: no git repo at /tmp/cell`
# — a controller that will not start, for a directory the operator never chose and nothing creates.
# (The sibling defect is worse, in refresh-candidates.sh: ITS default was one developer's HOME
# DIRECTORY, baked into every machine's harness.) A default is only safe if it is TRUE ON EVERY
# BOX, so there is none — the value is REQUIRED, and resolve_repo() below may DERIVE it from a path
# that really is a git checkout. The derivation is timid on purpose and never guesses between two
# repos: this checkout decides the QUEUE (resolve_queue_target reads its `origin`), so adopting the
# wrong one dispatches the wrong repo's work — the measured agent-infra#1901 defect.
REPO="${REPO:-}"
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
# ⛔ THE TMUX NAME MATCH IS DEAD WHERE THE CMUX DAEMON ANSWERS. There the harness spawns workers into
# cmux DURABLE TERMINALS (worker-terminal.sh's header records the measurement), so
# `tmux ls | grep -c '^lane-'` answers 0 while lanes run — and this file used that answer to decide
# whether it may delete caches under a live lane, and to report `lanes:` in `status`. Both read a
# confident 0 for a busy box. (tmux IS the launch surface where the daemon does NOT answer — on a
# launchd Mac and on a cell alike, agent-infra#2210 — so the defect is the single surface, not tmux.)
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
    # ⛔ `chain-` IS COUNTED HERE TOO (review finding on #2210's fix). `dispatch-merge.sh` spawns
    # `chain-<N>` workers that live up to ~90 min, and the census filter in worker-terminal.sh counts
    # them — but this list did not, so a chain-only box read "no workers" and `workers_maybe_live()`
    # (which gates the destructive cache/disk sweep) stood DOWN to "safe to delete" under a live
    # chain. The population this decision reads and the population the census reports must be one list.
    _c="$(wt_count lane- fix- merge- chain- 2>/dev/null)" || { printf 'census: wt_count failed in %s\n' "$m" >&2; exit 3; }
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

log_line() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }

# ══════════════════════════════════════════════════════════════════════════════════════════════
# LANE CEILING — DERIVED on this delivery path too, and a PIN THAT DISAGREES IS LOUD (#3171)
# ══════════════════════════════════════════════════════════════════════════════════════════════
# THE RULING IS NOT CHANGED HERE. `MAX_LANES` is DERIVED, not configured: floor(ncpu × 5/2), the
# fleet's 2026-10-17 lane ruling (docs/ops/ai-drainer.md:49, docs/ops/fleet-harness-baseline.md:137
# — "Do not 'fix' a per-box MAX_LANES"). Memory is the drainer's SEPARATE second ceiling
# (target = min(cpu_ceiling, mem_ceiling)); it is REPORTED here and never applied here, because a
# memory floor quietly narrowing the lane count would reverse that ruling as a side effect.
#
# WHY THIS FILE NEEDED IT AT ALL. Every other delivery path DERIVES the number: install.sh:87
# renders it into the mac plist, orch-loop.sh:243 and spawn-gate.sh:91 derive it at start. This one
# — the CELL path — derived it ZERO times: the cell's number is a hand-pushed `keys.env` constant,
# sourced into this shell, so nothing ever compared it to the derivation. Measured 2026-10-30:
# cell-3 is 4 cores (derives 10) and its keys.env carried 20, while its memory ceiling was 3 — it
# ran 10 lanes, thrashed, and killed lanes with ENOSPC. Two delivery paths, one of which could
# drift with nothing going red. This block is the missing comparison and the missing one-line
# report (`cpus=N MAX_LANES=M mem_ceiling=K`), so a box whose lane count exceeds its memory ceiling
# is visible rather than inferred from a thrash.
#
# ⛔ PINNED MIRROR, NOT A SOURCE. This file is farmed into a runtime dir and copied outside any
# checkout (see the note above `_proc_start_epoch`), so it cannot source scripts/lib/lane-ceiling.sh.
# The derivation below is that library's, mirrored. ⛔ THE DRIFT ARM IS IN
# orchestrator-harness/selftest.sh (§ "LANE CEILING"), which runs BOTH under the same stubbed probes
# and reddens on any divergence — name it exactly: a comment that points at a suite which does not
# contain the arm leaves the next editor pinning nothing. (It is behavioural rather than the
# byte-identity `pin_dirty` uses because the two bodies legitimately differ in naming; what must not
# differ is what they ANSWER, which is what the five probe scenarios assert.)
_lane_is_num() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; 0) return 0 ;; 0*) return 1 ;; *) return 0 ;; esac; }
_lane_is_limit() { _lane_is_num "${1:-}" && [ "${#1}" -le 9 ]; }
# Sets LANE_CPU_N / LANE_CPU_MECH in this shell. Order is install.sh:46's, unchanged: sysctl (macOS)
# → nproc (GNU) → getconf (POSIX; present on both, and the only one a minimal Linux userland keeps).
_lane_probe_raw() {
  local n
  LANE_CPU_MECH=""; LANE_CPU_N=""
  n="$(sysctl -n hw.ncpu 2>/dev/null)" && [ -n "$n" ] && _lane_is_limit "$n" && { LANE_CPU_MECH=sysctl; LANE_CPU_N="$((10#$n))"; }
  if [ -z "$LANE_CPU_MECH" ]; then
    n="$(nproc 2>/dev/null)" && [ -n "$n" ] && _lane_is_limit "$n" && { LANE_CPU_MECH=nproc; LANE_CPU_N="$((10#$n))"; }
  fi
  if [ -z "$LANE_CPU_MECH" ]; then
    n="$(getconf _NPROCESSORS_ONLN 2>/dev/null)" && [ -n "$n" ] && _lane_is_limit "$n" && { LANE_CPU_MECH=getconf; LANE_CPU_N="$((10#$n))"; }
  fi
  if [ -z "$LANE_CPU_MECH" ]; then
    # ⛔ LOUD FALLBACK — a constant is never reported as a measurement.
    log_line "WARN: the CPU count could not be read (sysctl hw.ncpu, nproc and getconf all failed) — falling back to 4 cores, so MAX_LANES derives to 10. This is a CONSTANT, not a measurement." >&2
    LANE_CPU_MECH=fallback; LANE_CPU_N=4
  fi
  [ "$LANE_CPU_N" -ge 1 ] || {
    log_line "WARN: the CPU probe ($LANE_CPU_MECH) answered 0 — a 0-valued probe is a FAILED probe, not 'no cores'. Falling back to 4 cores." >&2
    LANE_CPU_MECH=fallback; LANE_CPU_N=4
  }
  return 0
}
# floor(ncpu × 5/2): 10 cores → 25, 8 → 20, 4 → 10. The fallback of 10 covers a FAILED or absurd
# derivation only — never a pin.
_lane_derive() { # $1 = ncpu
  local n="${1:-}" d
  _lane_is_limit "$n" || return 1
  d=$(( 10#$n * 5 / 2 ))
  [ "$d" -ge 1 ] && [ "$d" -le 999999999 ] || d=10
  printf '%s\n' "$d"
}
# The drainer's own formula and the drainer's own env names (ai-drainer.sh:44), so a pin on one box
# is honoured by both. REPORTED, never applied: application belongs to the drainer.
_lane_mem_avail_mb() {
  local p="${LC_PROC_MEMINFO:-/proc/meminfo}" mb
  if [ -n "${MEM_AVAIL_MB:-}" ]; then
    case "$MEM_AVAIL_MB" in ''|*[!0-9]*) ;; *) printf '%s\n' "$((10#$MEM_AVAIL_MB))"; return 0 ;; esac
  fi
  if [ -r "$p" ]; then
    mb="$(awk '/^MemAvailable:/ {a=$2} /^MemFree:/ {f=$2} /^Cached:/ {c=$2}
              END {if (a!="") v=a; else if (f!="" && c!="") v=f+c; else exit 1
                   printf "%d", v/1024}' "$p" 2>/dev/null)" || return 1
  else
    mb="$(vm_stat 2>/dev/null | awk '/page size of/ {ps=$8} /Pages free/ {gsub(/[.]/,"",$3); f=$3}
          /Pages inactive/ {gsub(/[.]/,"",$3); i=$3}
          END {if (ps=="") ps=16384; if (f=="" || i=="") exit 1
               printf "%d", (f+i)*ps/1048576}')" || return 1
  fi
  case "$mb" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$mb"
}
_lane_mem_ceiling() { # $1 = mem_avail_mb → "?" when unreadable
  local avail="${1:-}" floor_mb budget lane_mb usable
  _lane_is_num "${avail:-}" || { printf '?\n'; return 1; }
  floor_mb="${MIN_MEM_FREE_MB:-512}"; budget="${MEM_BUDGET_PCT:-75}"; lane_mb="${LANE_MEM_MB:-512}"
  _lane_is_num "$floor_mb" || floor_mb=512
  _lane_is_num "$budget"   || budget=75
  _lane_is_num "$lane_mb"  || lane_mb=512
  [ "$lane_mb" -ge 1 ] || lane_mb=512
  usable=$(( (10#$avail - 10#$floor_mb) * 10#$budget / 100 ))
  [ "$usable" -ge 0 ] || usable=0
  printf '%s\n' "$(( usable / 10#$lane_mb ))"
}
# The ONE line, at every start. `pinned=`/`drift=` appear only when a pin exists, and drift is
# named with the file that carries it. ⛔ A pin is NEVER rewritten here: it is the operator's, and a
# tool that overwrites it turns a visible disagreement into a silent one.
lane_ceiling_report() {
  local pin="${MAX_LANES:-}" ncpu derived avail memceil
  _lane_probe_raw; ncpu="$LANE_CPU_N"
  derived="$(_lane_derive "$ncpu")" || derived=10
  avail="$(_lane_mem_avail_mb 2>/dev/null)" || avail=""
  memceil="$(_lane_mem_ceiling "$avail" 2>/dev/null)" || memceil="?"
  if [ -z "$pin" ]; then
    log_line "capacity: cpus=$ncpu MAX_LANES=$derived mem_ceiling=$memceil cpu_probe=$LANE_CPU_MECH (derived: 2.5 x cores — no pin)"
    return 0
  fi
  case "$pin" in
    ''|*[!0-9]*)
      log_line "capacity: cpus=$ncpu MAX_LANES=$derived mem_ceiling=$memceil cpu_probe=$LANE_CPU_MECH pinned=$pin DRIFT — the pin is not a whole number, so it cannot be the lane ceiling it names. Fix the MAX_LANES line in ${ENV_FILE:-keys.env}."
      return 0 ;;
  esac
  # ⛔ A DIGIT STRING IS NOT A MAGNITUDE (the `is_limit` rule this repo applies to every other limit).
  # `$((10#$pin))` on a 20-digit pin WRAPS rather than erroring, so the report would print a wrapped
  # number as fact and the memory comparison below would compute a garbage slot count — the same
  # class install.sh:1176 names ("passed the class test, and … lost the lane cap").
  if ! _lane_is_limit "$pin"; then
    log_line "capacity: cpus=$ncpu MAX_LANES=$derived mem_ceiling=$memceil cpu_probe=$LANE_CPU_MECH pinned=$pin DRIFT — the pin is not a magnitude (more than nine digits), so it cannot be the lane ceiling it names; it is NOT evaluated and NOT applied. Fix the MAX_LANES line in ${ENV_FILE:-keys.env}."
    return 0
  fi
  if [ "$((10#$pin))" = "$derived" ]; then
    log_line "capacity: cpus=$ncpu MAX_LANES=$derived mem_ceiling=$memceil cpu_probe=$LANE_CPU_MECH pinned=$pin (agrees with the derivation)"
  else
    log_line "capacity: cpus=$ncpu MAX_LANES=$derived mem_ceiling=$memceil cpu_probe=$LANE_CPU_MECH pinned=$pin DRIFT — the pin disagrees with 2.5 x $ncpu cores (=$derived) and stays in force; the ruling is that MAX_LANES is DERIVED, not configured, so remove the MAX_LANES line from ${ENV_FILE:-keys.env} unless this box is deliberately carved out (docs/ops/fleet-harness-baseline.md:137). Reported, never overwritten."
  fi
  if [ "$memceil" != "?" ] && [ "$memceil" -lt "$((10#$pin))" ]; then
    log_line "WARN: the pinned MAX_LANES=$pin EXCEEDS this box's memory ceiling ($memceil lanes — (MemAvailable - ${MIN_MEM_FREE_MB:-512}MB) x ${MEM_BUDGET_PCT:-75}% / ${LANE_MEM_MB:-512}MB): the drainer holds the real target at $memceil, so the extra $((10#$pin - memceil)) lane slot(s) are a thrash risk, not capacity (measured: cell-3 ran 10 lanes against a ceiling of 3 and was killed with ENOSPC, agent-infra#3171)"
  fi
  return 0
}
cmd_capacity() { lane_ceiling_report; }
die() { log_line "FATAL: $*" >&2; exit 1; }

# ── the TARGET checkout: the operator's value, else DERIVED from a real checkout ───────────────
# Adoption rule, in order: $REPO as given; else exactly ONE candidate that is a git checkout; else,
# when several are, the ones whose `origin` names the declared $OR — and if that is still not exactly
# one, REFUSE. Two distinct checkouts on one box is precisely the case where a guess is unrecoverable
# (the derivation feeds OR, and OR decides which queue the controller works), so the refusal names
# both and asks. The candidate list is the harness's own provisioning locations — nothing walks the
# filesystem — and `run`/`git` are the only tools this needs: no network, no config, no agent.
REPO_SEEN=""       # what the derivation looked at, for the refusal
resolve_repo() {
  local cand url hits="" n=0
  [ -n "$REPO" ] && return 0
  REPO_SEEN=""
  for cand in "${WORKDIR:-}" "$CELL_HOME/cell" "/tmp/cell" \
              "${OR:+$CELL_HOME/${OR##*/}}" "${OR:+/tmp/cell-${OR##*/}}" "${OR:+/tmp/${OR##*/}}"; do
    [ -n "$cand" ] || continue
    case " $REPO_SEEN " in *" $cand "*) continue ;; esac
    REPO_SEEN="${REPO_SEEN:+$REPO_SEEN }$cand"
    [ -d "$cand" ] || continue
    git -C "$cand" rev-parse --git-dir >/dev/null 2>&1 || continue
    if [ -n "${OR:-}" ]; then
      url="$(git -C "$cand" config --get remote.origin.url 2>/dev/null || true)"
      case "$url" in
        "$OR"|"$OR.git"|*":$OR"|*":$OR.git"|*"/$OR"|*"/$OR.git") ;;
        *) continue ;;
      esac
    fi
    hits="$hits$cand\n"
  done
  n="$(printf '%b' "$hits" | grep -c .)"
  case "$n" in
    1) REPO="$(printf '%b' "$hits" | head -1)"; REPO="$(cd "$REPO" && pwd -P)" || { REPO=""; return 1; }
       log_line "REPO was not set — using $REPO (a checkout from the provisioning candidates${OR:+, origin $OR})"
       return 0 ;;
    0) return 1 ;;
  esac
  log_line "REPO was not set and ${n} candidate checkouts match${OR:+ $OR}:"
  printf '%b' "$hits" | sed 's/^/       /' >&2
  return 1
}

# ONE actionable line, on the verbs that cannot work without a checkout. `status` deliberately does
# not call it: it is the verb an operator runs to DISCOVER this, so it must still answer.
assert_repo() {
  if ! resolve_repo; then
    die "REPO is not set and no single checkout could be derived from ${REPO_SEEN:-the provisioning candidates} — set REPO=<a checkout of the repo this cell should work> (e.g. in $ENV_FILE), or clone it to /tmp/cell"
  fi
  # ⛔ THE GUARD MUST SEE THE VALUE THAT IS INTERPOLATED, not only the one the OPERATOR passed
  # (agent-infra#1935 review). `cmd_start` validates REPO before this derives it — and skips an
  # EMPTY value — so a DERIVED path was the one interpolated value that reached the tmux command
  # string unvalidated: a checkout directory named with a quote would close the quote in
  # `REPO='$REPO'` and the rest would be parsed as shell. This is the same class as the `$HARNESS`
  # re-check below, which exists for exactly this reason (a value that changes after the guard).
  safe_argv "$REPO" || die "\$REPO must not contain a quote or shell metacharacter: $REPO"
  # A DERIVED checkout changes the queue target (resolve_queue_target reads its origin), so re-derive
  # OR before anything asserts the pair.
  resolve_queue_target || true; OR="$QUEUE_REPO"
}

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
# ⛔ THE INVOKER'S HOME IS CAPTURED BEFORE THE RE-POINT (review P2, #2402). The USER unit directory is the
# INSTALLER's `$HOME/.config/systemd/user` (the installer writes there), but everything below re-points
# `HOME` to `$CELL_HOME`. With CELL_HOME != HOME (a `CELL_HOME=` line in keys.env, or an installer invoked
# as `CELL_HOME=… bash install-controller-service.sh`) every verb looked in `$CELL_HOME/.config/systemd/user`
# while the unit sat in the operator's own home: `status` printed `supervision: NONE` over an ENABLED unit
# and `stop` never issued the `systemctl stop` — the "reported stopped, still running" shape, one layer in.
# Writer and readers must agree on ONE directory, so the pre-re-point value is kept deliberately.
CONTROLLER_INVOKER_HOME_IN="${CONTROLLER_INVOKER_HOME:-${HOME:-}}"
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
# ⛔ ORCH_FOREGROUND DESCRIBES THE CALLER, NOT THE BOX (review P2, #2402). It decides whether `start`
# `exec`s the loop in THIS process or delegates to the unit, so keys.env must not be able to set it: the
# doctor pins ORCH_FOREGROUND=0 in its session string, and an `ORCH_FOREGROUND=1` line in keys.env would
# then be re-applied here and reparent the controller into the DOCTOR's tmux pane instead of the unit's
# cgroup (#2402's defect, one indirection out). Snapshotted BEFORE the source, put back AFTER it — the
# same shape as the HOME re-assert below.
ORCH_FOREGROUND_IN="${ORCH_FOREGROUND:-0}"
# ⛔ AN AUTOMATED RESTART IS NOT AN OPERATOR'S START (review P1, #2402), and keys.env must not be able to
# say otherwise — the same caller-describes-the-caller rule as ORCH_FOREGROUND above. The doctor's restart
# arm sets it; `cmd_start` refuses to re-arm a unit the service manager reports NOT ACTIVE under it (see
# the service branch), so a `keys.env` line carrying it would make every operator `start` inert over a
# stopped or failed unit.
ORCH_AUTOMATED_RESTART_IN="${ORCH_AUTOMATED_RESTART:-0}"
# ⛔ THE BOUNDS THE INSTALLER VALIDATED MUST BE THE BOUNDS IN FORCE (review P1, #2402). The unit renders
# `CONTROLLER_*_TIMEOUT` into the ENVIRONMENT precisely so the supervisor reads the values the installer
# proved fit StartLimitBurst inside StartLimitIntervalSec. But `source_env_file` runs with `set -a`, so a
# `CONTROLLER_ORPHAN_TIMEOUT=3600` line in keys.env silently replaced the validated 60 — and at 3600 the
# burst can never fill (3 x (3600+15) >> 300 s), so the unit restarted forever and every surface read
# supervised: exactly the pre-fix state the arithmetic exists to remove, with the artifact the operator
# reads still printing 60. Only a value the CALLER/unit actually provided is re-asserted; an unset one
# legitimately comes from the env file (tmux mode has no unit to provide it).
CONTROLLER_ORPHAN_TIMEOUT_IN="${CONTROLLER_ORPHAN_TIMEOUT:-}"
CONTROLLER_HANDOVER_TIMEOUT_IN="${CONTROLLER_HANDOVER_TIMEOUT:-}"
# ⛔ AND THE UNIT NAME ITSELF IS THE FOURTH MEMBER OF THAT FAMILY (review P1 round 14, #2402). The template
# renders `Environment=CONTROLLER_UNIT={{UNIT_NAME}}` so the name is ONE fact; but `source_env_file` runs with
# `set -a`, so a `keys.env` line `CONTROLLER_UNIT=other.service` re-pointed `controller_unit_copies` at a unit
# that does not exist. Measured consequence on this checkout: `stop` printed "released lock" with NOT ONE
# `systemctl` call (the installed unit invisible), and `Restart=always` brought the controller back inside
# RestartSec — the "reported stopped, still running" false pass this PR exists to remove; `start` read
# `is-enabled other.service` → `not-found` → "a real DISABLED answer" → launched a TMUX controller beside the
# ENABLED unit (#1761). Snapshotted before the source and put back after it, like its three siblings.
CONTROLLER_UNIT_IN="${CONTROLLER_UNIT:-}"
# ⛔ AND THE THREE THAT DECIDE WHERE THE UNIT IS LOOKED FOR, AND WITH WHAT (review P1 round 18, #2402).
# `SYSTEMCTL` and the two unit DIRECTORIES are read AFTER `source_env_file` and were the last unfenced
# siblings of the family above, so a `keys.env` line still reached the same measured pair of false passes:
# `CONTROLLER_USER_UNIT_DIR=/nowhere` made the installed unit invisible (`status` → "nothing supervises
# this cell"; `stop` → zero systemctl calls while `Restart=always` re-created the controller seconds
# later), and `SYSTEMCTL=/bin/true` let `stop` print "controller stopped (systemd …)" and exit 0 without
# issuing the verb. Snapshotted before the source, put back after it.
SYSTEMCTL_IN="${SYSTEMCTL:-}"
CONTROLLER_SYSTEM_UNIT_DIR_IN="${CONTROLLER_SYSTEM_UNIT_DIR:-}"
CONTROLLER_USER_UNIT_DIR_IN="${CONTROLLER_USER_UNIT_DIR:-}"
# ⛔ AND `PS_BIN` BELONGS TO THE FAMILY TOO (review P1 round 19, #2402 / B). It is read at CALL time by
# `_proc_start_epoch`, and its answer (`_proc_began_after`) is what decides which pids `stop` may signal.
# A pushed `PS_BIN` stub forges the age rule: a recycled pid that merely LOOKS like `<shell> <…/orch-loop.sh>`
# is then classified as the lock owner and gets TERM/KILL — the peer-repo controller that rule exists to
# protect. Absent a caller value the restored state is "unset" = the real `/bin/ps` default.
PS_BIN_IN="${PS_BIN:-}"
source_env_file
ORCH_FOREGROUND="$ORCH_FOREGROUND_IN"
ORCH_AUTOMATED_RESTART="$ORCH_AUTOMATED_RESTART_IN"
[ -z "$CONTROLLER_ORPHAN_TIMEOUT_IN" ]   || CONTROLLER_ORPHAN_TIMEOUT="$CONTROLLER_ORPHAN_TIMEOUT_IN"
[ -z "$CONTROLLER_HANDOVER_TIMEOUT_IN" ] || CONTROLLER_HANDOVER_TIMEOUT="$CONTROLLER_HANDOVER_TIMEOUT_IN"
[ -z "$CONTROLLER_UNIT_IN" ]             || CONTROLLER_UNIT="$CONTROLLER_UNIT_IN"
# ⛔ AND THE INVOKER'S HOME CARRIES THE SAME OVERRIDE FENCE AS THE FOUR ABOVE (review P2 round 17, #2402):
# `set -a; . "$ENV_FILE"` would otherwise let a pushed `CONTROLLER_INVOKER_HOME=` re-point the USER unit
# directory every reader uses — reproducing the exact "reported stopped, still running" defect the capture
# exists to prevent, now reachable from keys.env instead of from the caller's shell.
[ -z "$CONTROLLER_INVOKER_HOME_IN" ]     || CONTROLLER_INVOKER_HOME="$CONTROLLER_INVOKER_HOME_IN"
SYSTEMCTL="$SYSTEMCTL_IN"
# ⛔ THESE TWO ARE RE-ASSERTED UNCONDITIONALLY, WHICH IS THE WHOLE POINT (review P1 round 19, #2402 / B).
# The timeout siblings above use `[ -z "$_IN" ] ||` because an UNSET one legitimately comes from the env
# file (tmux mode has no unit to provide it). A unit DIRECTORY has no such reading: its default is computed
# downstream (`${CONTROLLER_SYSTEM_UNIT_DIR:-/etc/systemd/system}`), so "unset" is the CORRECT restored
# state, and the conditional form left the keys.env value in force — the fence was inert in production,
# where the unit renders no such variable and every caller supplies nothing. Reproduced: a keys.env line
# `CONTROLLER_SYSTEM_UNIT_DIR=/tmp/nowhere` hid the installed unit with 0 systemctl calls and `stop`
# printing "not running", which is the exact false pass the fence was added to close.
CONTROLLER_SYSTEM_UNIT_DIR="$CONTROLLER_SYSTEM_UNIT_DIR_IN"
CONTROLLER_USER_UNIT_DIR="$CONTROLLER_USER_UNIT_DIR_IN"
PS_BIN="$PS_BIN_IN"
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
# ── the refusal an operator can ACT on (#2916 check 6, rows 6-7) ────────────────────────────────
# Both refusals below used to say "…give this repo its own SESSION, or stop it from the state dir that
# owns it" — which names neither the state dir nor the command, and BOTH measured cases cost a manual
# step on a live cell: a stale `cell-doctor` tmux session minted by a PREVIOUS state dir blocked the
# doctor role, and a leftover inner-chain member (`tmux → bash -c → orch-loop.sh`) blocked the first
# start and was cleared by hand. So the message carries what the box already knows: the pid, the
# state dir the pid actually runs from, and the exact command.
# ⛔ MESSAGE ONLY — nothing here signals anything. Auto-clearing a pid/session this state dir cannot
# prove it owns is the #1856 hazard; the remedy is PRINTED for the operator, never executed.
_pids_join_with_dirs() { # <pids-newline-separated> -> "pid <p> (state dir <d>)" …
  local t p d out=""
  t="$(ps -eo pid=,command= 2>/dev/null)" || t=""
  for p in $1; do
    d=""
    [ -n "$t" ] && d="$(printf '%s\n' "$t" | awk -v pp="$p" '$1==pp' | tr ' \t' '\n\n' \
                       | sed -n 's|^\(.*\)/orch-loop\.sh$|\1|p' | head -1)"
    if [ -n "$d" ]; then out="$out, pid $p (state dir $d)"; else out="$out, pid $p"; fi
  done
  printf '%s' "${out#, }"
}
# The state dir a FOREIGN doctor session runs from, read from its own pane command (the same evidence
# `doctor_session_foreign` uses). Empty when the pane does not name one — printed as <unreadable>
# rather than guessed.
doctor_session_state_dir() {
  local cmd
  cmd="$(tmux list-panes -t "=$DOCTOR_SESSION" -F '#{pane_start_command}' 2>/dev/null)" || return 1
  [ -n "$cmd" ] || return 1
  printf '%s\n' "$cmd" | sed -n "s/.*O='\([^']*\)'.*/\1/p" | head -1
}

# ── the controller SERVICE (agent-infra#2402) ───────────────────────────────────────────────────
# A cell's controller used to live and die as a tmux session, with nothing above it: when the last
# session closed the server exited and no surface restarted the controller, so an empty box lost its
# dispatcher and read as a healthy idle cell (measured 2026-10-23 on cell-1).
# `install-controller-service.sh` installs `eldato-orchestrator.service` (Restart=always) whose ExecStart
# is `cloud-cell-supervisor.sh start` with ORCH_FOREGROUND=1 — so `start` `exec`s the loop in this very
# process instead of creating a session, and systemd's cgroup owns the controller's lifetime.
# ⛔ THESE HELPERS EXIST BECAUSE THE OTHER VERBS MUST COOPERATE WITH THAT, and both directions are
# false-pass shapes if they do not: a `stop` that only kills the pid is undone by Restart=always within
# RestartSec ("stopped" over a dispatcher that is back seconds later), and a `start` that launches a
# tmux session beside an ENABLED unit is two dispatchers on one queue (#1761).
CONTROLLER_UNIT="${CONTROLLER_UNIT:-eldato-orchestrator.service}"
# The scopes the unit may live in, in the order install-controller-service.sh tries them (system first:
# that is the cell's shape, because the cells have passwordless sudo and no queryable user manager).
# A unit file's PRESENCE answers "is this box service-managed?"; whether it is ENABLED is a second
# question, and only "enabled" means the manager will bring the controller back.
# ⛔ A UNIT FILE'S PRESENCE IS NOT AN OWNERSHIP CLAIM (review P1, #2402), and this file refuses that
# inference everywhere else — by the SYMBOL the rule lives in, not by a line number (a number here went
# stale the moment this comment grew the file): `seen_controller_pids`'s "$HARNESS LEG IS NOT AN
# OWNERSHIP CLAIM", `cmd_stop`'s "refusing to kill a session this state dir cannot prove it owns", and
# `doctor_session_foreign` for the doctor session. The unit name
# is MACHINE-scoped, so "the first copy found" can be another cell's — measured with two state dirs: B's
# `stop` stopped A's unit, reported `controller stopped`, and B's `--status` called A's unit "installed but
# NOT ACTIVE — nothing will restart a dead controller". The rendered unit CARRIES its owner
# (`Environment=O=`), so ownership is a READ, not a guess.
controller_unit_copies() { # every copy on the box, system then user
  local d seen=" "
  for d in "${CONTROLLER_SYSTEM_UNIT_DIR:-/etc/systemd/system}"; do
    [ -n "$d" ] && [ -f "$d/$CONTROLLER_UNIT" ] && printf '%s\n' "$d/$CONTROLLER_UNIT"
  done
  # ⛔ THE USER UNIT'S DIRECTORY HAS NO RECORDED OWNER, SO THE READ TRIES EVERY HONEST CANDIDATE (review P1
  # round 18, #2402). `$HOME` at read time is the INVOKER's, and the invoker is deliberately NOT the
  # installer: the doctor's session string forces `HOME=$CELL_HOME`, while the operator's standalone
  # `install-controller-service.sh --install` wrote the unit under the OPERATOR's home. With
  # `CELL_HOME != $HOME` — the shape this file's own round-16 note names — the doctor looked in
  # `$CELL_HOME/.config/systemd/user`, found nothing, skipped the ENTIRE service branch (the NOT-ACTIVE
  # fence included) and launched a tmux controller BESIDE the enabled unit: #1761's duplicate dispatcher,
  # which is the invariant this PR exists to close. The passwd home is what `systemctl --user` itself
  # resolves (the user manager takes HOME from the database, not from our environment), so it is the
  # authoritative candidate; the invoker's HOME stays because the bring-up installs under it. Widening the
  # SEARCH cannot make a foreign unit look ours — every copy is still ownership-checked by `unit_owner_dir`.
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    case "$seen" in *" $d "*) continue ;; esac
    seen="$seen$d "
    [ -f "$d/$CONTROLLER_UNIT" ] && printf '%s\n' "$d/$CONTROLLER_UNIT"
  done < <(controller_user_unit_dirs)
  return 0
}
# The home the passwd database names for a user — NEVER `$HOME`, which the caller re-points.
passwd_home() {
  [ -n "${1:-}" ] || return 0
  getent passwd "$1" 2>/dev/null | cut -d: -f6
}
controller_user_unit_dirs() {
  local h
  [ -n "${CONTROLLER_USER_UNIT_DIR:-}" ] && printf '%s\n' "$CONTROLLER_USER_UNIT_DIR"
  h="${CONTROLLER_INVOKER_HOME:-${HOME:-}}"; [ -n "$h" ] && printf '%s\n' "$h/.config/systemd/user"
  # ⛔ A MISSING `getent` MUST NOT FAIL SILENTLY (review P2 round 19, #2402 / B). The passwd home is the
  # candidate the doctor's `HOME=$CELL_HOME` session depends on; without `getent` it would simply disappear
  # from the list and re-open the duplicate-dispatcher defect with no diagnostic anywhere. stderr only —
  # stdout is a list.
  command -v getent >/dev/null 2>&1 \
    || printf '%s\n' "cloud-cell-supervisor: getent not found — the passwd-home unit lookup is unavailable on this box, so a reader whose HOME is not the installer's may miss the unit" >&2
  h="$(passwd_home "$(id -u)")"; [ -n "$h" ] && printf '%s\n' "$h/.config/systemd/user"
  h="$(passwd_home "${SUDO_USER:-}")"; [ -n "$h" ] && printf '%s\n' "$h/.config/systemd/user"
  return 0
}
# The state dir a rendered unit ACTUALLY supervises, and the one it CLAIMS.
#
# ⛔ OWNERSHIP IS TWO READS, AND A UNIT IS OURS IF EITHER SAYS SO (review P1 round 9, #2402). The unit
# carries its owner TWICE — the `Environment=O=` it RENDERS (what `verify_unit` pins to the installing state
# dir) and what it RESOLVES to (`ENV_FILE` re-sourced, and `keys.env` may repoint `O`) — and the two
# legitimately differ in BOTH directions. Reading renders only classified this cell's OWN installed, enabled
# unit as ANOTHER state dir's as soon as keys.env repointed `O`: `stop` fell through to the pid teardown (a
# kill `Restart=always` undoes within RestartSec), printed "released lock" with no `systemctl stop` behind it
# — the „reported stopped, still running" false pass this file exists to remove — while `status` printed
# "nothing will restart it" over a supervised cell and `start` fell through to the tmux path beside an
# enabled unit (#1761's duplicate). Reading RESOLUTIONS only does the mirror damage to the INSTALLER, whose
# `$O` is the rendered value: `verify_unit` guarantees its own copies render it, so a `keys.env` `O=` line
# made its own unit look foreign — a status that never asks the manager, and an uninstall that reports "not
# installed" over an ENABLED unit. Either answer is the unit's own claim about itself, so ownership is the
# UNION (see `unit_is_ours`); a unit that provably matches NEITHER is still foreign, so §L's negative
# control and #1761's "never arm a second supervisor" both hold.
#
# `unit_owner_dir` answers the RESOLUTION: evaluate the unit's own env file the way the controller will
# (`set -a; . file`), with the unit's own CELL_HOME/O in scope, and print the `O` that results. Only the
# copy's own declared file is evaluated, and only in a throwaway subshell whose output is captured — the
# same posture and the same completion guard `source_env_file` uses (a file with a top-level `exit` ends the
# subshell silently, and an EMPTY answer here falls back to the rendered value rather than reading as "no
# owner"). `env -u` is load-bearing: an inherited O/CELL_HOME must not shadow the unit's own.
# Prints nothing when the unit carries neither a resolvable `Environment=O=` nor a readable env file, which
# is a HAND-WRITTEN unit: unprovable either way, and treated as this state dir's (the pre-#2402 behaviour —
# the fail-safe side for #1761 is "assume it may be ours, never launch a session beside it").
#
# ⛔ AND ROOT MUST NEVER EXECUTE AN OPERATOR-WRITABLE FILE (review P2 round 9, #2402). `keys.env` is the
# operator's file and `sudo bash … stop`/`--status` is a documented invocation, so evaluating it AS ROOT lets
# any account that can write that file execute with root's authority. As root the file is therefore
# evaluated as the account that OWNS it (the account that could have written it, and the account the
# controller runs as), via `runuser`; when that cannot be arranged — no `runuser`, or an owner that cannot be
# read — it is NOT evaluated at all and the caller falls back to the RENDERED owner, which the unit carries
# in cleartext. That fallback is lossless for ownership because ownership is the union above.
unit_rendered_owner() { # <unit file> -> the owner the unit RENDERS; nothing when it carries no O= line
  local v
  [ -f "$1" ] || return 1
  v="$(sed -n 's/^Environment=O=//p' "$1" 2>/dev/null | head -1)"
  [ -n "${v:-}" ] || return 1
  # A trailing slash is a spelling difference, not a different state dir.
  printf '%s\n' "${v%/}"
}
env_file_owner_o() { # <envf> <unit_cell_home> <rendered_o> [<unit_home>] -> resolved O; nothing when not evaluated
  local f="$1" home="$2" rendered="$3" unit_homeenv="${4:-}" owner="" runner=() out=""
  [ -n "${f:-}" ] && [ -r "$f" ] || return 1
  if [ "$(id -u)" = "0" ]; then
    # ⛔ THE TEST IS "WHO CAN WRITE IT", NOT "WHO OWNS IT" (review P2 round 9, #2402). Ownership alone missed
    # the shape `sudo tee`/`sudo cp` leaves behind: a `keys.env` OWNED by root and group- or other-WRITABLE
    # (`-rw-rw-r-- root:staff`, umask 002 in a shared group) was used as its own "owner", ran as root, and
    # executed with root's authority — the escalation this guard exists to close, one permission bit away.
    # Two changes, both fail-closed: do not evaluate the file AT ALL when any account but its owner can write
    # it, so the caller falls back to the RENDERED `O=` — cleartext in the unit, and lossless for ownership
    # because ownership is the UNION; and derive the RUNNER FROM THE FILE (see below). Keep this body identical
    # to the installer's.
    local fmode fowner
    fmode="$(stat -c %A -- "$f" 2>/dev/null)" || return 1
    [ -n "${fmode:-}" ] || return 1
    # Group/other WRITE on the file itself. (The directory is deliberately not tested: if another account
    # can REPLACE the file, the replacement's owner is that account — which the runner rule below covers — so
    # a directory test would only cause false refusals on shared-group cells without closing anything.)
    case "${fmode:5:1}${fmode:8:1}" in *w*) return 1 ;; esac
    # ⛔ THE RUNNER IS DERIVED FROM THE FILE, NEVER FROM THE CALLER (review P1 round 11, #2402). Preferring
    # `SUDO_USER` ran the file as the INVOKING operator rather than as the account that can write it: a
    # `keys.env` owned by account A, read through a documented `sudo bash … --status`, executed A's code with
    # the SUDOER's authority — the same escalation this guard closes for the group-writable shape, one
    # ownership bit away (the mode test only rejects group/other WRITE, so a `0644` file owned by another
    # account passes it). The file's OWNER is the account that can write it, so that is who it runs as;
    # `SUDO_USER` is only the non-root stand-in for the one case ownership cannot answer — the owner IS root,
    # and root can write anything, so "owned by root" says nothing about who could have written it. No
    # stand-in ⇒ do not evaluate at all (fall back to the rendered `O=`).
    fowner="$(stat -c %U -- "$f" 2>/dev/null)" || return 1
    [ -n "${fowner:-}" ] || return 1
    if [ "$fowner" = "root" ]; then
      owner="${SUDO_USER:-}"
      [ -n "${owner:-}" ] || return 1
      [ "$owner" != "root" ] || return 1
    else
      owner="$fowner"
    fi
    if [ "$owner" != "root" ]; then
      command -v runuser >/dev/null 2>&1 || return 1
      runner=(runuser -u "$owner" --)
    fi
  fi
  # ⛔ THE UNIT'S OWN `HOME` IS PART OF THE EVALUATION (review P2, #2402). A `keys.env` may spell the state
  # dir in terms of `$HOME` (`O=$HOME/orchestrator`), and the unit carries `Environment=HOME=` precisely
  # because the controller resolves it that way. With HOME inherited from the CALLER, the same unit file
  # resolved to the caller's home — measured: caller HOME=/tmp/cell-home -> /tmp/cell-home/orchestrator,
  # caller HOME=/home/cellA -> /home/cellA/orchestrator — so cell B read cell A's unit as its OWN and
  # `stop`/`--status`/`--uninstall` acted on another state dir's dispatcher. Set it from the unit, exactly
  # like CELL_HOME/O above; an empty value means "the unit states no HOME", which keeps the caller's.
  # ⛔ `-u HOME` MUST NOT BE ADDED (review P2 round 17, #2402): unsetting it made the documented fallback
  # impossible — with no `Environment=HOME=` in the unit, `O=$HOME/o` resolved to `/o` (an empty-variable
  # expansion), a path no cell has, and `unit_owner_dir` fed that to every "supervises <dir>" answer. The
  # inherited value IS the caller's HOME, which is the documented fallback.
  out="$(${runner[@]:+"${runner[@]}"} env -u O -u CELL_HOME -u ENV_FILE bash -c '
      [ -z "$4" ] || HOME="$4"
      CELL_HOME="$2"; O="$3"; ENV_FILE="$1"
      set -a; . "$1" >/dev/null 2>&1
      printf "%s" "${O:-}"
    ' _ "$f" "${home:-}" "${rendered:-}" "${unit_homeenv:-}" 2>/dev/null || true)"
  [ -n "${out:-}" ] || return 1
  printf '%s\n' "$out"
}
unit_owner_dir() { # <unit file>
  local f="$1" rendered_o envf unit_home unit_homeenv eff
  [ -f "$f" ] || return 1
  rendered_o="$(unit_rendered_owner "$f")" || rendered_o=""
  envf="$(sed -n 's/^Environment=ENV_FILE=//p' "$f" 2>/dev/null | head -1)"
  unit_home="$(sed -n 's/^Environment=CELL_HOME=//p' "$f" 2>/dev/null | head -1)"
  # the HOME the unit itself runs with — see env_file_owner_o's note: `O=$HOME/...` must resolve against the
  # INSTALLING cell's home, not the caller's.
  unit_homeenv="$(sed -n 's/^Environment=HOME=//p' "$f" 2>/dev/null | head -1)"
  eff=""
  if [ -n "${envf:-}" ]; then
    eff="$(env_file_owner_o "$envf" "${unit_home:-}" "${rendered_o:-}" "${unit_homeenv:-}")" || eff=""
  fi
  [ -n "${eff:-}" ] || eff="${rendered_o:-}"
  [ -n "${eff:-}" ] || return 1
  printf '%s\n' "${eff%/}"
}
# May this verb address <unit file>? YES for our own copy by EITHER read, and YES for an UNPROVABLE one (no
# O= line and no readable env file — a hand-written or pre-#2402 unit), the fail-safe side of #1761. NO only
# when BOTH reads name a DIFFERENT state dir, and then nothing here may disable, delete, or report on it.
unit_is_ours() { # <unit file>
  local own rendered
  own="$(unit_owner_dir "$1")" || own=""
  rendered="$(unit_rendered_owner "$1")" || rendered=""
  [ -n "$own" ] || [ -n "$rendered" ] || return 0
  [ "$own" = "${O%/}" ] && return 0
  [ "$rendered" = "${O%/}" ]
}
# The copy the VERBS address, resolved once and remembered: `_UNIT_PATH` (empty = none of ours), plus the
# FIRST copy that is NOT this state dir's (`_UNIT_FOREIGN`, provably another state dir) and the FIRST that
# proves nothing (`_UNIT_UNPROVABLE`, no O= line). One report line each — a box carries at most one copy per
# scope (system, user) — and the reports need them to be truthful.
_UNIT_PATH=""; _UNIT_FOREIGN=""; _UNIT_UNPROVABLE=""
controller_unit_path() {
  local f own="" rendered="" first="" unp="" act="" en=""
  _UNIT_PATH=""; _UNIT_FOREIGN=""; _UNIT_UNPROVABLE=""
  while IFS= read -r f; do
    own="$(unit_owner_dir "$f")" || own=""
    rendered="$(unit_rendered_owner "$f")" || rendered=""
    if [ -z "$own" ] && [ -z "$rendered" ]; then
      [ -n "$unp" ] || unp="$f"
      [ -n "$_UNIT_UNPROVABLE" ] || _UNIT_UNPROVABLE="$f"
      continue
    fi
    if [ "$own" != "${O%/}" ] && [ "$rendered" != "${O%/}" ]; then
      [ -n "$_UNIT_FOREIGN" ] || _UNIT_FOREIGN="$f"
      continue
    fi
    [ -n "$first" ] || first="$f"
    # ⛔ ADDRESS THE COPY THE MANAGER WILL BRING BACK (review P1, #2402). With two of OUR copies — the
    # state the code's own note names, "an image-baked disabled system unit plus the live user unit" —
    # addressing the first made every read answer "disabled", so `stop` took the pid-teardown shortcut,
    # printed success, and the enabled unit's Restart=always re-created the controller within RestartSec.
    _UNIT_PATH="$f"
    # ⛔ AND `ACTIVE` OUTRANKS MERELY `ENABLED` (review P1, #2402). Returning on the first copy that is
    # EITHER active OR enabled let an ENABLED-but-`failed` system copy (an image-baked unit that hit its
    # StartLimit, or one whose supervisor already died — the measured #2402 shape) win over the LIVE user
    # copy, because the copies are walked system-first. The verb then stopped the dead manager and left the
    # running controller alone, and its "stopped" was only caught by a pid watch whose window is shorter
    # than the surviving unit's own restart path. The copy that is RUNNING NOW is the one a stop must
    # address; an enabled copy is only the fallback (it is what will come back when nothing is up).
    # ⛔ THE ACTIVE TIER IS THE LITERAL WORD (review P2, #2402). `controller_unit_active_state` maps
    # `activating` to 0, and `activating` is the auto-restart window of a unit whose controller just exited —
    # so ranking on it let an auto-restarting copy outrank the copy that is actually RUNNING, which is the
    # exact mis-resolution the tiering was added to fix, one state wider. `reloading`/`activating` fall to the
    # ENABLED tier; `--status` keeps the three-word mapping, which it needs for its own verdict.
    if [ -z "$act" ] && [ "$(sup_systemctl is-active "$CONTROLLER_UNIT" 2>/dev/null)" = active ]; then act="$f"; continue; fi
    if [ -z "$en" ] && controller_unit_state >/dev/null 2>&1; then en="$f"; fi
  done < <(controller_unit_copies)
  # ACTIVE, else ENABLED, else the first of ours (a unit that is neither is still the one installed here).
  local chosen=""
  if [ -n "$act" ]; then chosen="$act"; elif [ -n "$en" ]; then chosen="$en"; elif [ -n "$first" ]; then chosen="$first"; fi
  if [ -n "$chosen" ]; then _UNIT_PATH="$chosen"; printf '%s\n' "$chosen"; return 0; fi
  # ⛔ AN UNPROVABLE COPY IS ADDRESSED, NOT IGNORED (review P1, #2402). A hand-written unit with no
  # `Environment=O=` line proves nothing either way, and the fail-safe side for #1761 is "assume it may be
  # ours": treating it as foreign would launch a tmux controller beside the very unit that may be
  # enabled and will start at boot — the duplicate this file refuses everywhere else. `_UNIT_UNPROVABLE`
  # carries it so `status`/`stop` can say the ownership was NOT proven.
  if [ -n "$unp" ]; then _UNIT_PATH="$unp"; printf '%s\n' "$unp"; return 0; fi
  _UNIT_PATH=""
  return 1
}
# The scope is decided by WHERE the unit lives, never by $EUID: the cell's unit is a SYSTEM unit owned by
# the operator's sudo, while the controller runs as the operator. SYSTEMCTL is the test seam (a shim),
# exactly as install-disk-reaper-timer.sh spells it.
# ⛔ THE SCOPE FOLLOWS THE COPY THE VERB RESOLVED (review P1, #2402). Re-deriving it by "does a SYSTEM copy
# exist" addressed the wrong manager whenever two copies existed: a disabled system copy made every read
# answer for the system scope and the enabled USER unit was never asked — the wrong-unit stop above.
sup_systemctl() { # <systemctl verb…>
  local sc user_scope=0
  if [ -n "${_UNIT_PATH:-}" ]; then
    # Where the RESOLVED copy lives decides the manager, for ANY candidate user directory — not just the
    # one this invocation would have guessed (see `controller_user_unit_dirs`).
    [ "$(dirname "$_UNIT_PATH")" != "${CONTROLLER_SYSTEM_UNIT_DIR:-/etc/systemd/system}" ] && user_scope=1
  elif [ ! -f "${CONTROLLER_SYSTEM_UNIT_DIR:-/etc/systemd/system}/$CONTROLLER_UNIT" ]; then
    user_scope=1
  fi
  # ⛔ THE SCOPE IS A WORD ON THE SHIM TOO (review P1, #2402). `SYSTEMCTL` replaces the whole command string,
  # so dropping the scope with it made a scope-aware shim answer for the SYSTEM manager even when the copy the
  # verb resolved lives in the USER one — the wrong-unit read/stop, hidden from every test whose stub keys on
  # `--user`. Independent of whether the scope was resolved or inferred (the `elif` above).
  if [ -n "${SYSTEMCTL:-}" ]; then
    if [ "$user_scope" -eq 1 ]; then sc="$SYSTEMCTL --user"; else sc="$SYSTEMCTL"; fi
  elif [ "$user_scope" -eq 1 ]; then sc="systemctl --user"
  else sc="sudo -n systemctl"
  fi
  # shellcheck disable=SC2086  # deliberate word splitting: $sc may be "sudo -n systemctl"
  $sc "$@"
}
# ⛔ THREE ANSWERS, NOT TWO (review P1, #2402). `is-enabled --quiet` collapses "DISABLED" and "CANNOT
# READ" into one false value, and the start branch reads that value as "this box is not service-managed"
# — so a `sudo -n systemctl` that fails (no NOPASSWD entry, a locked sudo, a transient failure) would
# launch a tmux controller beside a unit that IS enabled and WILL start at boot: two dispatchers on one
# queue, which is the #1761 duplicate this branch exists to prevent. Everywhere else in this file an
# unreadable read is fatal, and here it must be too.
#   0 = enabled (the manager brings it back) · 1 = a real disabled/masked/static answer · 3 = cannot read
# The state WORDS are systemd's own (`man systemctl`: enabled, enabled-runtime, linked, linked-runtime,
# alias, masked, masked-runtime, static, indirect, disabled, generated, transient), so a real answer is
# never mistaken for an unreadable one; anything else printed, or nothing at all, is unreadable.
controller_unit_state() {
  local out
  out="$(sup_systemctl is-enabled "$CONTROLLER_UNIT" 2>/dev/null)"
  case "$out" in
    # ⛔ THE WHOLE TABLE, not the words that came to mind (review P2). `not-found` and `bad` are DEFINITE
    # answers ("this manager does not have a usable unit"), and folding them into "cannot read" made
    # `start` refuse on a box that is simply not service-managed — the case a failed `daemon-reload`
    # during install leaves behind (file on disk, manager has not loaded it). `alias` is exit 0 in
    # systemd's table (the unit IS enabled through an alias); scoring it as "disabled" would start a tmux
    # controller beside a boot-enabled unit, the #1761 duplicate. `generated`/`transient`/`indirect` are
    # not enabled-by-unit-file, so they stay on the "not service-managed" side.
    enabled|enabled-runtime|alias) return 0 ;;
    disabled|masked|masked-runtime|linked|linked-runtime|static|indirect|generated|transient|not-found|bad) return 1 ;;
  esac
  return 3
}
# Active is the same question one layer in, and the same trap: `is-active --quiet` answers "no" for both
# `inactive` and `cannot read`. The status row uses this to say which one it saw.
controller_unit_active()  { sup_systemctl is-active --quiet "$CONTROLLER_UNIT" 2>/dev/null; }
controller_unit_active_state() {
  local out
  out="$(sup_systemctl is-active "$CONTROLLER_UNIT" 2>/dev/null)"
  case "$out" in
    active|reloading|activating) return 0 ;;
    inactive|failed|deactivating|maintenance|unknown|not-found|bad) return 1 ;;
  esac
  return 3
}


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
QUEUE_STATE=""       # derived|explicit = usable · mismatch|invalid|unreadable|underivable|nocheckout = refuse

# Read the pair. NEVER dies: `status` must still answer when the pair cannot be read — it is the verb
# an operator runs to discover that it cannot — and every other verb keeps its own preconditions. The
# verbs that cannot do their job call assert_queue_target() below.
resolve_queue_target() {
  QUEUE_DECLARED="${OR:-}"
  # ⛔ AN EMPTY $REPO IS NOT "read the queue from the CURRENT DIRECTORY". `git -C ""` silently means
  # no `-C` at all, so the pre-#1935 load-time call derived the queue from whatever directory the
  # operator happened to be standing in — and then held the REAL checkout against it. A controller's
  # queue must follow the checkout it names, never the caller's cwd.
  if [ -z "$REPO" ]; then
    # ⛔ ITS OWN STATE, NOT `unreadable` (#1977 review, P2). With no checkout there is no origin
    # remote to be unreadable, and rendering it as one sent the operator hunting an origin problem on
    # a repo that does not exist — while `status`, the verb that is supposed to DISCOVER this, printed
    # an empty path. The cause is the missing checkout, so the state names it.
    QUEUE_REMOTE=""; QUEUE_DERIVED=""; QUEUE_REPO="$QUEUE_DECLARED"; QUEUE_STATE="nocheckout"; return 1
  fi
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

# ── #2235: `GH_REPO` IS PER-INVOCATION STATE, NEVER CELL STATE ─────────────────────────────────
# `keys.env` on every cell exported `GH_REPO=daniel-ospina/tortoise` GLOBALLY. gh's own resolution is
# flag > `GH_REPO` > the local checkout, so EVERY call that did not pass `--repo` answered for
# tortoise while the cell graded agent-infra: measured twice in one session (2026-10-20/21), a rail
# printed
#   admin-merge: ✅ PR #2232 is ALREADY MERGED (state=MERGED, mergedAt=2026-09-04T09:11:01Z)
#                — duplicate execution is a NO-OP: no CI work, no evidence comment, no merge attempt
# for a SEPTEMBER tortoise PR, exit 0, over an open agent-infra PR — and the same leak produced
# `GraphQL: Could not resolve to a PullRequest with the number of 2231` for real open PRs. Four
# agent-infra PRs looked "already merged" while unmerged on origin/main.
#
# TWO INDEPENDENT EDITS, because either one alone leaves the defect reachable:
#   1. THIS CHECK — a cell whose env carries a GH_REPO naming a DIFFERENT repo than the checkout the
#      controller runs in is a STOP-WORK condition (the same class and shape as the queue/checkout
#      mismatch above: a wrong pair must not be a cell that starts and looks healthy). It is checked
#      against $QUEUE_DERIVED — the repo READ FROM the checkout's own origin — which is exactly the
#      subject #2235 names, and against $QUEUE_REPO when the origin could not be read.
#   2. THE SESSION COMMANDS below carry `unset GH_REPO` AFTER `$ENV_FILE` is sourced. The check alone
#      would be bypassed by any path that creates a session without calling it, and keys.env is
#      re-sourced INSIDE the session command — so the strip has to live where the sourcing happens.
#      A correct value is stripped too: the rail resolves its own repo by evidence now, so a global
#      export buys nothing and only arms the next leak.
assert_gh_repo_conformance() {
  [ -n "${GH_REPO:-}" ] || return 0
  local want="${QUEUE_DERIVED:-$QUEUE_REPO}" have got got_src _h="" _whost=""
  got_src="the checkout's origin remote"
  if [ -z "$want" ]; then
    die "GH_REPO is set ($GH_REPO) but this cell's CHECKOUT repo could not be read, so it cannot be verified against the tree the controller would grade ('git -C $REPO remote get-url origin' => '${QUEUE_REMOTE:-<none>}'). A global GH_REPO is what produced the #2235 fail-open — gh gives it precedence over the checkout for every call that does not pass --repo, so the rail graded daniel-ospina/tortoise PRs while reporting on agent-infra ones. Remove the GH_REPO line from $ENV_FILE (it is per-invocation state, not cell state); the controller resolves its repo from the checkout."
  fi
  [ "$want" = "$QUEUE_REPO" ] || got_src="the queue target"
  have="$(printf '%s' "$GH_REPO" | tr '[:upper:]' '[:lower:]')"
  # ⛔ `[HOST/]OWNER/REPO` IS THE DOCUMENTED FORM (`gh help environment`), so `github.com/o/r`
  # names the SAME repo as `o/r` and must not be graded as a different one — comparing verbatim
  # made `check` FATAL on a cell whose keys.env used the documented spelling (§2235 review P2).
  # The leading segment is dropped only when it IS a host (dotted, or this checkout's host).
  case "$have" in
    */*/*)
      _h="${have%%/*}"
      case "$_h" in
        *.*|*:*)
          # ⛔ THE CHECKOUT'S OWN HOST IS PARSED FROM `$QUEUE_REMOTE`, NOT FROM A VARIABLE THAT
          # IS NEVER ASSIGNED (#2235 review round 3, P2): the first cut referenced
          # `${QUEUE_HOST:-}`, which appears nowhere else in the repo — so `[ "$_h" = "" ]` was
          # always false and a GHE checkout could not accept `GH_REPO=ghe.corp/o/r`, while the
          # RAIL (which does read its own remote host) accepted it. Two authorities grading one
          # input two ways is the #1856 shape; the evidence is the remote this cell already read.
          _whost="${QUEUE_REMOTE:-}"
          case "$_whost" in
            *://*) _whost="${_whost#*://}" ;;
            *@*:*) _whost="${_whost%%:*}" ;;
            *)     _whost="" ;;
          esac
          _whost="${_whost%%/*}"; _whost="${_whost#*@}"; _whost="${_whost%%:*}"
          _whost="$(printf '%s' "$_whost" | tr '[:upper:]' '[:lower:]')"
          if [ "$_h" = "github.com" ] || { [ -n "$_whost" ] && [ "$_h" = "$_whost" ]; }; then
            have="${have#*/}"
          fi ;;
      esac ;;
  esac
  got="$(printf '%s' "$want" | tr '[:upper:]' '[:lower:]')"
  if [ "$have" != "$got" ]; then
    die "GH_REPO names a DIFFERENT repository than $got_src: GH_REPO='$GH_REPO' but $got_src='$want'. gh gives GH_REPO precedence over the checkout for EVERY call that does not pass --repo, so a cell carrying this line grades and reports '$GH_REPO' PRs while believing it is grading '$want' — measured as a rail printing '✅ PR #2232 is ALREADY MERGED' (a September tortoise PR) over an open agent-infra one, exit 0 (#2235). FIX: remove the GH_REPO line from $ENV_FILE — it is per-invocation state, never a cell-wide export; a command that genuinely needs another repo passes --repo. Then re-run. (The session strip would neutralise the leak anyway; this refusal exists to force the keys.env EDIT, because a global export re-arms on the next checkout, clone or rename — but note the ordering: this refuses BEFORE the harness refresh, so a box mid-deploy is left stopped until the line is removed, as documented in docs/ops/fleet-harness-baseline.md.)"
  fi
  log_line "ok: GH_REPO ('$GH_REPO', from $ENV_FILE or the ambient shell) names this checkout's repo ($want, case-insensitively) — it is stripped from the controller session anyway (#2235)"
  return 0
}

# The named REFUSAL, in the shape `apply` uses when it declines because a controller is running — not
# a warning. A wrong pair must not be a cell that starts and looks healthy; it must be a cell that
# does not start, with an error naming BOTH values, the remote that was read, and the repo this
# machine needs so provisioning is unambiguous.
assert_queue_target() {
  # ⛔ REPO first: with no checkout, every QUEUE_STATE below is a SYMPTOM, and the old message read
  # `cannot read the QUEUE … 'git -C  remote get-url origin' returned no URL` — an error about an
  # empty path. The cause is the missing checkout, so name it.
  [ -n "$REPO" ] || assert_repo
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
    nocheckout)  printf 'NO CHECKOUT — REPO is not set; start/check derive one or refuse (agent-infra#1935)' ;;
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
#
# ⛔ THE PREDICATE IS `pin_dirty` BELOW, A PINNED MIRROR of `pin_dirty` in scripts/lib/box.sh (this file is
# deployed STANDALONE, so it cannot source a sibling library — the same constraint the pid-identity mirror
# at `_proc_start_epoch` documents). It is not re-typed by hand: the body is copied byte-for-byte and a
# drift arm (cloud-cell-supervisor.test.sh §(p3)) reddens CI if the two ever diverge. Round 4 found the
# divergence this prevents: the resolver refused a pin on an IGNORED file while THIS function read the
# weaker `--porcelain`, so `check` reported the pin CLEAN and `apply` took HARNESS_APPLIED=unchanged over
# a tree the controller would not start — an instrument that certified the state it existed to catch.
harness_dirty() {
  local out rc
  out="$(pin_dirty "$HARNESS" .)"; rc=$?
  [ "$rc" -eq 2 ] && return 2
  [ "$rc" -eq 1 ] && return 0
  return 1
}

pin_dirty() {
  local repo="$1" scoped="$2" top out line path keep=""
  # ⛔ THE TOPLEVEL, because porcelain prints paths relative to the REPOSITORY ROOT even when `repo` is a
  # subdirectory — and two of the three callers pass the harness SUBDIR (the production convention). A
  # first version resolved entries against `$repo`, so its tolerance was unreachable there and a
  # `.DS_Store` read DIRTY to the instruments while the runtime read CLEAN: the round-4 divergence again,
  # with the fail direction inverted (found by review, round 5).
  top="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" || return 2
  out="$(git -C "$repo" status --porcelain --ignored=matching -- "$scoped" 2>/dev/null)" || return 2
  [ -n "$out" ] || return 0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    path="${line:3}"
    case "$path" in '"'*'"') path="${path#\"}"; path="${path%\"}" ;; esac
    # ⛔ TOLERATE ONLY **UNTRACKED/IGNORED** DROPPINGS. A TRACKED file named `._x` is part of the pin, so a
    # MODIFICATION to it must read DIRTY — the name is not the property (found by review, round 5: a
    # rewritten tracked `._x` read CLEAN). `!!` = ignored, `??` = untracked.
    case "$line" in
      '!!'*|'??'*) case "${path##*/}" in
        .DS_Store|._*) [ -f "$top/$path" ] && [ ! -L "$top/$path" ] && continue ;;
      esac ;;
    esac
    keep="$keep$line
"
  done <<<"$out"
  [ -n "$keep" ] || return 0
  printf '%s' "$keep"
  return 1
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
# whose only other entries are ONE OF TWO ENUMERATED classes of REGULAR, NON-SYMLINK file: OS droppings
# (​`.DS_Store` / `._*` — one Finder visit to the default root must not brick the cell) and the harness's
# OWN named records (`.agent-infra-version`, `AGENTS.md`, `MEMORY.md`, `README.md`, `VENDOR.md`,
# `HARNESS-PIN`, `manifest.json`, `package.json` — agent-infra#2812: a shipped sibling component writes
# into this root, so refusing them kept the cell unstartable for ever, once per 10-minute tick).
# ⛔ Both classes are NAMED, never "any file", and THIS header is the whole allow-list: a hidden
# DIRECTORY, a dangling symlink, a symlink wearing an allowed NAME, and any unlisted entry are refused.
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
# entry, and each one must be a hex-named directory — EXCEPT two ENUMERATED classes of regular,
# NON-SYMLINK file: OS droppings (`.DS_Store` / `._*`) and the harness's OWN named records (below).
# Refusing the first bricked all four verbs after a single Finder visit to the default root on the
# operators' macOS server; refusing the second bricked the cell permanently against a shipped sibling
# component. (See the header above, which states the whole allow-list; this line is the one it is
# easiest to contradict by accident.) ⛔ Both classes are NAMED, never "any file": an unlisted entry
# is still refused, which is the whole point of the guard.
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
      # ⛔ HARNESS METADATA IS NOT A STRAY (#2812): `harness-apply` records the commit it converged
      # this box to INSIDE the pin root, so the guard refused forever and the entry returns on every
      # 10-minute tick — "remove it by hand" is not a remedy. Named explicitly, so an UNKNOWN entry is
      # still refused.
      .agent-infra-version|AGENTS.md|MEMORY.md|README.md|VENDOR.md|HARNESS-PIN|manifest.json|package.json)
        if [ -f "$dir/$p" ] && [ ! -L "$dir/$p" ]; then harmless=1; continue; fi ;;
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
  [ "$fetch_failed" = 1 ] && log_line "warn: git fetch failed in $HARNESS_REPO — cannot refresh $HARNESS_REF; using the local ref"
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
      log_line "seed: removed the stale gh-limit layer — the harness no longer ships it"
    fi
    log_line "WARN: $HARNESS ships no gh-limit layer — this cell's gh calls will NOT be serialised or backed off (#1988)"
  fi
  # ⛔ MIRROR, do not merely overlay. `orch-loop.sh`/`merge-one.sh` invoke workers BY NAME from $O, so a
  # script RENAMED upstream would leave its old copy live in $O and still invocable — the record would
  # describe the harness while the cell ran a worker the harness no longer ships.
  for f in "$O"/*.sh; do
    [ -f "$f" ] || continue
    [ -f "$HARNESS/$(basename "$f")" ] || { rm -f "$f"; log_line "seed: removed stale $(basename "$f") — the harness no longer ships it"; }
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
    log_line "warn: ${mb}MB free on $(dirname "$CELL_HOME") — under $((MIN_FREE_MB * 4))MB. 'prune' reclaims the regenerable caches."
  fi
}

# The provenance half of `check`. Three refusals that CANNOT be mended by getting fresher (untracked,
# diverged, unknown) and one that can (behind) — see the header block for why.
cmd_check_provenance() {
  classify_harness
  local sc sp sr live sd hd_rc
  case "$HARNESS_REL" in
    current)
      log_line "ok: harness commit ${HARNESS_COMMIT:0:12} == $HARNESS_REF (${REF_COMMIT:0:12}) — $(harness_subject)" ;;
    behind)
      log_line "DRIFT — harness commit ${HARNESS_COMMIT:0:12} is BEHIND $HARNESS_REF (${REF_COMMIT:0:12}). It is on"
      log_line "       main's line, so 'start' would mend it — but a cell running it is a cell running old code."
      log_line "       Remedy: $0 apply" ;;
    diverged)
      log_line "DRIFT — harness commit ${HARNESS_COMMIT:0:12} is NOT an ancestor of $HARNESS_REF (${REF_COMMIT:0:12})."
      log_line "       This is the measured 2026-10-14 incident: a tree off main's line merged real PRs off the"
      log_line "       shared queue while check called the cell healthy. Refusing."
      log_line "       Remedy: $0 apply   (pins to $HARNESS_REF in $HARNESS_PIN_DIR)" ;;
    untracked)
      log_line "DRIFT — the harness at ${HARNESS:-<unresolved>} has NO git identity, so 'which commit is this cell"
      log_line "       running?' has no answer. A hand-placed copy is this cell's oldest failure mode (#1745)."
      log_line "       Remedy: $0 apply   (pins to $HARNESS_REF in $HARNESS_PIN_DIR)" ;;
    *)
      log_line "DRIFT — cannot verify the harness: $HARNESS_REF does not resolve in ${HARNESS_REPO:-<no checkout resolved>}."
      log_line "       Cannot-verify is never a pass. Remedy: set HARNESS_REPO to an agent-infra checkout, then $0 apply" ;;
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
    log_line "ok: recorded install — commit ${sc:0:12}, relation '${sr}', payload ${sp:0:12}"
  elif tmux has-session -t "$SESSION" 2>/dev/null; then
    die "a controller is RUNNING (tmux '$SESSION') with NO harness provenance recorded at $STAMP — 'which commit is this cell running?' has no answer for a live merge actor. Remedy: stop, then $0 apply"
  else
    log_line "ok: no install recorded yet (pre-start) — 'start' or 'apply' writes $STAMP"
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
  command -v uv >/dev/null 2>&1 || log_line "warn: uv missing — lane.sh cannot sync a worktree venv, so in-lane tests will fail (non-fatal, as in install.sh)"
  # ── the RESOLVED LANE MODEL, and whether THIS box's catalog lists it (agent-infra#2208) ─────
  # `spawn-gate.sh`'s and `merge-one.sh`'s `run_agent` default to `deepseek/deepseek-flash`
  # (env-overridable). A box's model list is its OWN — `pi-bootstrap/cell-install.sh` deliberately
  # does not manage `models.json` ("the cell's identity") — so a drifted cell can hand every lane an
  # id its provider entry does not list, and pi answers that with
  # `Warning: Model "…" not found … Using custom model id`: a lane that STARTS, spends tokens and
  # degrades silently. The failure is silent, so a certification command is where it should be
  # named.
  #
  # ⛔ THIS IS AN INSTRUMENT, NOT A GATE, AND THE DISTINCTION IS THE WHOLE DESIGN (review cycle 2).
  # pi's resolution is a UNION — its built-in catalog, MERGED with the box's `models` array and with
  # `modelOverrides` — so absence from the box's array does NOT prove the id fails to resolve.
  # Measured: the shipped catalog lists `deepseek-v4-flash-vision-exp` only under `modelOverrides`,
  # and it IS a pi built-in, so `PI_LANE_MODEL=` it resolves cleanly while a `die` here would have
  # refused a healthy cell. A refusal set out of a question this file cannot answer is a false block.
  # So: "listed" is reported as listed; anything else is reported as NOT VERIFIED, with the reason,
  # and nothing refuses. (If it must become a gate, ask pi itself — `pi --list-models` — not this
  # file's guess at pi's merge rules.)
  #
  # ⛔ AND THE PAIR MUST BE THE ONE THE SESSIONS WILL SEE (same review). `cmd_check` runs in the
  # operator's shell, but the controller and doctor sessions are launched with an explicit env
  # allow-list and re-source `$ENV_FILE` — they do NOT inherit ambient `PI_LANE_*`. So the pair is
  # resolved the way a session resolves it (from `$ENV_FILE` when it carries one, defaults
  # otherwise), and an ambient-only value is named as NOT reaching the lanes rather than reported as
  # if it governed them.
  local lane_provider lane_model models_json lane_state lane_chan
  lane_provider="${PI_LANE_PROVIDER:-deepseek}"
  lane_model="${PI_LANE_MODEL:-deepseek-flash}"
  lane_chan="ambient shell (does NOT reach the tmux sessions — put it in $ENV_FILE)"
  if [ -f "$ENV_FILE" ]; then
    local lane_in_file
    lane_in_file="$(env -u PI_LANE_PROVIDER -u PI_LANE_MODEL bash -c 'set -a; . "$1" >/dev/null 2>&1; printf "%s\t%s" "${PI_LANE_PROVIDER:-}" "${PI_LANE_MODEL:-}"' _ "$ENV_FILE" 2>/dev/null || true)"
    if [ -n "$lane_in_file" ]; then
      lane_provider="${lane_in_file%%	*}"; lane_provider="${lane_provider:-deepseek}"
      lane_model="${lane_in_file##*	}"; lane_model="${lane_model:-deepseek-flash}"
      lane_chan="$ENV_FILE (re-sourced by the controller and doctor sessions)"
    fi
  fi
  models_json="$CELL_HOME/.pi/agent/models.json"
  if ! command -v jq >/dev/null 2>&1; then
    log_line "      lane model: $lane_provider/$lane_model — NOT VERIFIED (jq missing, so $models_json cannot be read; channel: $lane_chan)"
  elif [ ! -f "$models_json" ]; then
    log_line "      lane model: $lane_provider/$lane_model — NOT VERIFIED (no $models_json on this box; channel: $lane_chan)"
  else
    lane_state="$(jq -r --arg p "$lane_provider" --arg m "$lane_model" '
        (.providers[$p]) as $pv
        | if $pv == null then "no-provider"
          else
            (($pv.models // {}) | (if type == "array" then ([.[] | .id]) else (keys) end)) as $ids
            | (($pv.modelOverrides // {}) | keys) as $ovr
            | if ($ids | index($m)) != null or ($ovr | index($m)) != null then "listed" else "absent" end
          end' "$models_json" 2>/dev/null)" || lane_state="unreadable"
    case "$lane_state" in
      listed) log_line "      lane model: $lane_provider/$lane_model (listed by providers.$lane_provider in $models_json; channel: $lane_chan)" ;;
      absent) log_line "      lane model: $lane_provider/$lane_model — NOT RESOLVABLE FROM $models_json, and this id has no pi BUILT-IN: providers.$lane_provider there does not list it, and pi's built-in catalog carries only deepseek-v4-flash / deepseek-v4-flash-vision-exp / deepseek-v4-pro. pi MERGES the built-in catalog, so a PI_LANE_MODEL that IS built in still resolves from here — the SHIPPED DEFAULT ('deepseek-flash') is not, and on this box every harness lane would start on pi's 'Using custom model id' fallback: it runs, spends tokens, and degrades silently, which is the defect #2208 exists to remove. Remedy: add providers.$lane_provider.models.$lane_model to $models_json (pi-bootstrap/pi-config/models.json ships it, so a provisioned box is not affected — this fires on a box whose models.json was trimmed), or set PI_LANE_MODEL to a built-in id. Verify with the unfiltered: pi --list-models   [channel: $lane_chan]" ;;
      *) log_line "      lane model: $lane_provider/$lane_model — NOT VERIFIED (providers.$lane_provider unreadable/absent in $models_json; channel: $lane_chan)" ;;
    esac
  fi
  gh auth status >/dev/null 2>&1 || die "gh not authenticated — run cloud-cell-bringup.sh --check"
  # ⛔ RESOLVE THE CHECKOUT BEFORE ANYTHING READS IT. Every verdict below is about THIS repo, and an
  # unresolved $REPO used to reach `die "no git repo at "` — an error naming an empty path, for a
  # value the operator never set. assert_repo() derives it or refuses with one actionable line, and
  # re-derives OR when it derived the checkout (the queue follows the checkout's origin).
  assert_repo
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
  log_line "ok: queue $QUEUE_REPO == checkout $REPO (origin $QUEUE_REMOTE) — $QUEUE_STATE"
  assert_gh_repo_conformance
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
  log_line "ok: HOME, harness, tmux, gh auth, repo, state dir"
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
  # lane.sh's prompt EXECUTES lane-merge.sh for the merge phase and merge-rate.sh for the
  # before/after measurement (#2029), so a $O missing either makes every lane's merge phase exit 127
  # while this check still printed "CELL CAN RUN A CONTROLLER" — the false PASS this list exists to
  # prevent. Keep this list in step with install.sh's DRIFTED list (which seeds $O from it).
  # ⛔ lane-reap.sh IS IN THIS LIST (#2163): orch-loop.sh calls it for the `[cap]` census and the doctor
  # calls it for the process pass. A $O without it still runs (the census falls back to the launch
  # surface's own worker count — `wt_count lane-`, which answers for every launcher: durable cmux
  # terminals AND tmux sessions (launchd Mac or cell, #2210); `tmux ls` alone sees one of the two
  # surfaces and reads 0 on a busy cmux box, #2163 review r8) and the doctor says so in its pass line —
  # which is exactly the "leaked lanes are not judged" state this list exists to refuse before `start`
  # reports success.
  # UNION of both sides of this merge (neither is a superset): lane-merge.sh + merge-rate.sh from this
  # branch (#2029), lane-reap.sh from origin/main (#2163). Taking either alone leaves a worker the
  # controller executes unseeded, which is the false PASS above.
  # repo-target.sh (#2724/#2694) is SOURCED by lane.sh, dispatch-merge.sh, fix-one.sh and adopt-fix.sh;
  # all four `exit 78` without it, so its absence would make every dispatch refuse at startup while
  # `check` still certified the cell — the same false PASS one layer down.
  # gate-policy.sh (#2319) is SOURCED by every pi-spawning carrier on this box, which `exit 78`s without
  # it — the same class: a $O missing it is a cell whose every lane dies at startup while `check` says
  # "CELL CAN RUN A CONTROLLER".
  # ⛔ spawn-gate.sh is the SAME class and was MISSING (review round 5): lane.sh:29 and fix-one.sh:54 both
  # `. "$SELF/spawn-gate.sh" || exit 78`, and dispatch-merge.sh runs `bash '$O/lane.sh'`, so `$SELF` is
  # `$O` — a cell without it has its every lane die at startup while `check` printed the green banner.
  # install.sh:812 already required it; this list did not.
  for w in orch-loop.sh harness-refresh.sh claims.sh repo-authority.sh repo-slug.sh repo-target.sh spawn-gate.sh gate-policy.sh reviewer-preflight.sh dispatch-merge.sh lane.sh chain-merge.sh merge-one.sh fix-one.sh refresh-candidates.sh adopt-fix.sh cloud-cell-doctor.sh lane-merge.sh merge-rate.sh lane-reap.sh; do
    [ -f "$O/$w" ] || missing="$missing $w"
  done
  [ -z "$missing" ] || die "worker scripts missing from $O:$missing — run 'start' (it seeds $O) or, for a verified redeploy: bash '$HARNESS'/deploy-harness.sh --src '$HARNESS' --o '$O'"
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
    log_line "WARN: no gh-limit layer in $O — this cell's gh calls are NOT serialised/backed off (#1988); run 'start' to seed it"
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
  # ── the LANE ROSTER, provisioned from THIS box's own population (agent-infra#1935) ────────
  # The probe below answers "can this repo be pre-flighted?" and its holder surface is built FROM
  # `$HOME/.pi/agent/state/lane-registry.tsv` — written only by the RETIRED cmux dispatcher, so a
  # cell had none and EVERY candidate came back INCOMPLETE while the controller reported RUNNING
  # (measured on cell 1, 2026-10-28). `check` is the last gate before a cell is started, so the
  # roster is provisioned HERE, from the box's own lane population, and the arm it took is printed.
  # ⛔ THIS `check` VERB WRITES, DELIBERATELY AND IN THE OPEN (#3032 review F7). It is the last gate
  # before a cell is started, so a check that only REPORTED an unprovisioned roster would leave the
  # cell dispatching nothing — the #1935 defect. The write is idempotent and non-destructive (a
  # hand-maintained roster is never replaced; an existing derived roster is never shrunk by an arm
  # that measured nothing) — the provisioner's own rules, pinned in its suite.
  # ⛔ Idempotent and non-destructive: a hand-maintained roster is never replaced, and a second run
  # on an unchanged box writes nothing (the provisioner's own rules, pinned in its suite).
  # ⛔ A REFUSAL (rc 3) is REPORTED, not fatal: it means this box's population could not be
  # MEASURED, which the harness's reduced-surface path (#2848) can still dispatch through. Failing
  # the cell here would be a false block; writing an empty roster instead would be the fail-open
  # that #8175 exists to prevent, and the provisioner refuses to do it.
  # ⛔ NO INTERPRETER GUARD HERE, and that is not an omission: `cmd_check`'s dependency loop above
  # (`for dep in git python3 pi`) has already died when `python3` is missing, so a `127` from the
  # provisioner at this point can only mean the tool itself failed — which is what the arm below
  # says. The BRING-UP site needs the guard because its check_dispatch has no such loop.
  if [ -f "$HARNESS/provision-lane-registry.py" ]; then
    local rv rvrc
    rv=""; rvrc=0
    rv="$(HOME="$CELL_HOME" python3 "$HARNESS/provision-lane-registry.py" --apply 2>&1)" || rvrc=$?
    printf '%s\n' "$rv" | sed 's/^/    /'
    if [ "$rvrc" -eq 3 ]; then
      log_line "warn: lane roster NOT provisioned — the population is unmeasurable on this box (see above); the pre-flight's holder surface will refuse candidates until it is (agent-infra#1935)"
    elif [ "$rvrc" -ne 0 ]; then
      # ⛔ A CRASH IS NOT A PROVISION (review finding 2). The provisioner's documented exits are
      # 0/2/3; anything else (rc 1 from an uncaught OSError in the atomic write on a full disk or
      # a read-only $HOME — exactly what MIN_FREE_MB exists for, a traceback, rc 127) used to land
      # in the arm below and print `ok: provisioned`, i.e. a false PASS on the one line this
      # change adds to the start gate. Same shape as scheduler_ensure below: rc 3 is the tool's
      # OWN refusal, any other non-zero is reported as what it is.
      log_line "warn: lane roster provisioning FAILED (rc=$rvrc — not the tool's own refusal, so it crashed); the roster is in an UNKNOWN state and the pre-flight's holder surface may stay INCOMPLETE (agent-infra#1935)"
    else
      log_line "ok: lane roster — provisioned from this box's own population (agent-infra#1935)"
    fi
  else
    log_line "warn: $HARNESS/provision-lane-registry.py missing — the lane roster cannot be provisioned, so the pre-flight's holder surface will refuse every candidate (agent-infra#1935)"
  fi
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
  log_line "ok: dispatch provisioning — this repo can be pre-flighted, so lanes will be dispatched"
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
      log_line "warn: the dispatch-provisioning probe passed using this shell's ambient $ambient, which"
      log_line "      $ENV_FILE does not carry. The controller session re-sources $ENV_FILE and does not"
      log_line "      receive an ambient export on a pre-existing tmux server, so it would resolve no"
      log_line "      tortoise checkout, refuse with rc=3, and leave the cell MERGE-ONLY."
      log_line "      Fix: put TORTOISE_REPO=<a tortoise checkout> in $ENV_FILE, or vendor tools/collision_preflight.py into the repo."
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
  log_line "ok: record step present and executable ($rec, with $(recorder_lib_path))"

  # Judge the key by what the SESSION will receive, not by what this shell happens to hold: the key
  # FILE is authoritative, and a key in $ENV_FILE reaches the session because the session re-sources
  # it. An ambient-only export does NOT — tmux serves a new session from the server's environment —
  # so it is named rather than silently counted as present.
  # ⛔ ORDER MATTERS. The consumer is env-FIRST: it takes $ENV_FILE's value when non-empty and only
  # then falls back to the key file. A whitespace-only value in keys.env therefore SHADOWS a valid
  # key file (the raw value is non-empty, so the fallback never runs, and the normalized value is
  # empty) — so that case must be checked BEFORE the file, and reported as a failure, not a "present".
  if [ -n "$KEY_IN_FILE" ]; then
    log_line "ok: merge authority key present in $ENV_FILE — the controller re-sources it. On the"
    log_line "    'start' path (the only supported launch) the MERGE WORKERS it spawns across the second"
    log_line "    tmux boundary get it too: 'start' publishes $WORKER_ENV_NAMES into tmux update-environment"
    log_line "    and dies rather than start a cell where that publication fails."
  elif [ "$KEY_IN_FILE_SET" = 1 ]; then
    log_line "warn: AI_REVIEW_GATE_KEY in $ENV_FILE is WHITESPACE-ONLY. The consumer strips whitespace,"
    log_line "      so it resolves to EMPTY — and because the env value wins, it will NOT fall back to"
    log_line "      $CELL_HOME/.pi/agent/.ai-review-gate-key. Every review would be recorded UNSIGNED."
    log_line "      Fix: remove the key line from $ENV_FILE, or give it a real value."
  elif keyfile_has_key; then
    log_line "ok: merge authority key present ($CELL_HOME/.pi/agent/.ai-review-gate-key) — the MERGE"
    log_line "    WORKERS read it at \$HOME: 'start' carries HOME as one of $WORKER_ENV_NAMES into tmux"
    log_line "    update-environment, and a server it CREATES inherits it, so \$HOME is $CELL_HOME in every"
    log_line "    spawned worker."
  else
    local kfpath="$CELL_HOME/.pi/agent/.ai-review-gate-key"
    if [ -n "${AI_REVIEW_GATE_KEY:-}" ]; then
      log_line "warn: AI_REVIEW_GATE_KEY is set in THIS shell but not in $ENV_FILE — the controller"
      log_line "      session will NOT receive it: tmux serves a new session the SERVER's environment, and"
      log_line "      'start' drops this shell's export before creating the session, so it cannot be delivered."
      log_line "      Write it to $ENV_FILE, or to $kfpath."
    elif [ -e "$kfpath" ] && [ ! -r "$kfpath" ]; then
      # EXISTING but UNREADABLE is neither missing nor empty, and the remedy differs: prescribing
      # "write a key file" for a file that may already hold a valid key reproduces the fault.
      log_line "warn: $kfpath exists but is NOT READABLE — treated as absent."
      log_line "      It may already hold a valid key: check its mode and its parent directories (want 600)."
    else
      log_line "warn: no AI_REVIEW_GATE_KEY and no $kfpath."
    fi
    log_line "      ⛔ This does NOT make the cell safe to co-run: absence of the key does not stop"
    log_line '         `gh pr merge --auto` (measured: it armed auto-merge on #8425/#8420). A started'
    log_line "         cell is a MERGE ACTOR regardless of the key."
  fi
  log_line "⛔ COLLISION: orch-loop.sh takes BROAD scope above 10 open PRs, so an UNPINNED cell drains"
  log_line "   the SHARED queue. Measured 2026-10-13: a fresh cell logged '[scope] open=14 -> BROAD' and"
  log_line "   began re-recording/auto-arming within ~25s. Fix: pin every cell but ONE with SCOPE=own"
  log_line "   (orch-loop.sh's SCOPE override), or fix #5052, BEFORE starting a second controller."
  log_line "   ⛔ The pin is a PARTITION, not a fix for the root: ownership is still inferred from LOCAL"
  log_line "      branches/worktrees (#4256), invisible across machines, so two OWN-pinned cells can still"
  log_line "      race the same PR."
  log_line "CELL CAN RUN A CONTROLLER"
}

# ── the scheduled layer (agent-infra#1864) ──────────────────────────────────────────────────────
# A cell has no launchd, no crontab binary and no systemd user bus, so the repo's recurring jobs
# (declared once, as templates/launchd/*.plist) run from a supervised loop: scripts/fleet-schedule.py.
# `cloud-cell-bringup.sh --check` installs and proves it; THIS is where it is brought back up
# whenever the cell is started again — `start` is the cell's own "the cell is now alive" signal, so
# a loop that died while the controller kept running must not need a whole bring-up to recover.
#
# ⛔ IDEMPOTENT AND ON THE ALREADY-RUNNING PATH, both deliberately: the early return below is hit
# by the common `start`-after-`stop`, and placing this after it is how the loop would stay dead.
# ⛔ A MISSING SCRIPT IS A WARN, NOT A DIE: a cell whose layer predates this line must still be
# startable (that cell's gap is what bring-up reports). A script that EXISTS and refuses to start
# IS fatal — a cell running lanes with no reaping and no liveness detection is the defect.
scheduler_ensure() {
  local sched="$CELL_HOME/.pi/agent/scripts/fleet-schedule.py" out rc=0
  if [ ! -f "$sched" ]; then
    log_line "warn: no scheduled layer on this cell ($sched is absent) — no reap/liveness/canary job will run; re-run cloud-cell-bringup.sh --check"
    return 0
  fi
  out="$(HOME="$CELL_HOME" CELL_HOME="$CELL_HOME" python3 "$sched" --start 2>&1)" || rc=$?
  # rc=3 is the scheduler's own "no job declarations found" (its documented contract): the layer's
  # script is present but nothing tells it WHERE the declarations are, i.e. this cell was never
  # installed by the current bring-up. That must NOT brick the controller — bring-up is the gate
  # that installs and proves the layer — but it must never pass quietly either.
  if [ "$rc" -eq 3 ]; then
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    log_line "warn: the scheduled layer has no job declarations on this cell — no reap/liveness/canary job will run; re-run cloud-cell-bringup.sh --check"
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    die "the scheduled layer would not start (rc=$rc) — this cell would run with no reaping, no liveness detection and no canary (#1864)"
  fi
  # One line, so `start` never becomes the place a scheduler is assumed rather than seen.
  log_line "scheduled layer: $(printf '%s\n' "$out" | head -1)"
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
  # ⛔ THE BOX'S LANE CEILING, IN ONE LINE, BEFORE ANYTHING STARTS (#3171). `$ENV_FILE` is already
  # sourced into this shell by this point, so a `keys.env` MAX_LANES pin is visible here — and this
  # is the ONLY place a cell's ceiling is ever compared to the derivation. A warning at start is the
  # whole point: cell-3's 20-against-a-derivation-of-10 was invisible until it thrashed.
  lane_ceiling_report
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
    log_line "a STOP arrived while this start was running — aborting and leaving nothing running"
    tmux has-session -t "=$DOCTOR_SESSION" 2>/dev/null && tmux kill-session -t "=$DOCTOR_SESSION" 2>/dev/null || true
    tmux has-session -t "$SESSION" 2>/dev/null && tmux kill-session -t "$SESSION" 2>/dev/null || true
    # The loop this start just created is the only kill handle there is: end the PROCESS first, then
    # drop the record. (A `stop` racing us may already have read the record; either side ending it is
    # enough, and the fence makes a double-kill safe.)
    end_loop_pid || log_line "warn: the doctor loop survived the abort and could not be ended"
    rm -f "$ROLES_DIR/.desired" "$ROLES_DIR/loop.pid" "$ROLES_DIR/loop.ident"
    # ⛔ A UNIT THIS START STARTED IS NOT KILLED BY ANY OF THE ABOVE (review P1, #2402). The delegated start
    # hands the controller to the service manager, so the teardown above ends nothing — and under
    # `Restart=always` ANY kill would be undone within RestartSec anyway. The only way to leave nothing
    # running, which is what this function promises, is to stop the unit. Best-effort: a failure is said
    # out loud, because the operator's `stop` has already returned successfully.
    if controller_unit_path >/dev/null 2>&1; then
      sup_systemctl stop "$CONTROLLER_UNIT" >/dev/null 2>&1 \
        || log_line "warn: a STOP arrived, but $CONTROLLER_UNIT could not be stopped — it may restart the controller within RestartSec (systemctl stop $CONTROLLER_UNIT)"
    fi
    return 0
  }
  # ── SERVICE MODE ADOPTS A RUNNING CONTROLLER (agent-infra#2402) ─────────────────────────────────
  # ⛔ THIS IS THE MIGRATION PATH, NOT AN EDGE CASE: the box being upgraded is running a controller in
  # a tmux session right now. Every "already running" branch below returns 0, and under
  # `Restart=always` that is a start/exit/start loop — three immediate orderly exits inside the start
  # window and systemd leaves the unit `failed`. The unit installed to catch an empty box is then
  # `failed` exactly when the box empties, so the defect survives the fix (and now has a failed unit to
  # explain). So the unit WAITS for the controller that is already running and takes over when it goes;
  # the live controller keeps landing its PRs in the meantime.
  # ⛔ IT WAITS ON THE SESSION TOO, NOT JUST ON A PID (review P2). The wait's first version broke as soon
  # as `owned_controller_pids` went empty, so a lingering tmux session with no owned pid — the orphaning
  # `cmd_stop` documents, where the pane's `bash … | tee` outlives the loop — fell through to the
  # "already running" branches below and returned 0. Under `Restart=always` that is three orderly exits
  # and a `failed` unit, i.e. the P1 this wait exists to remove, in the state the migration itself
  # produces. The branch-level returns are therefore not reachable in service mode (they hand over).
  # ⛔ TWO BOUNDS, BECAUSE THE TWO WAITS ARE NOT THE SAME WAIT (review P1, #2402). An earlier revision of
  # this comment said the unit's `TimeoutStartSec` bounded this loop. It does not: for `Type=simple` the
  # start job completes when the main process is forked (systemd.service(5)), so `ExecStart` was bounded
  # only by the default below — a parks-forever start read `active (running)` for an hour. The bounds are
  # the process's own now, and install-controller-service.sh renders BOTH into the unit's environment:
  #   CONTROLLER_HANDOVER_TIMEOUT — an owned controller is still running. That is the MIGRATION path and it
  #     is landing work, so the bound is long by default; the loop exists so the upgrade does not shoot it.
  #   CONTROLLER_ORPHAN_TIMEOUT — nothing owns the loop, but the session outlived it. An orphan never exits,
  #     so that start can NEVER succeed: the ceiling is short, and the installer refuses a value whose
  #     attempts cannot fill StartLimitIntervalSec=300, so the unit converges to `failed` instead of
  #     looking supervised forever.
  foreground_handover() {
    local _own _seen _saidd=0 _waited=0 _bound="${CONTROLLER_HANDOVER_TIMEOUT:-3600}"
    local _orphan_bound="${CONTROLLER_ORPHAN_TIMEOUT:-60}"
    while :; do
      _own="$(owned_controller_pids 2>/dev/null)" \
        || die "cannot read the process table (ps) — refusing to start on an unreadable read"
      if [ -z "$_own" ] && ! tmux has-session -t "$SESSION" 2>/dev/null; then break; fi
      # ⛔ A SESSION THAT IS NOT OURS IS NOT A HANDOVER, IT IS A DUPLICATE (review P2, #2402). `$SESSION`
      # names one machine-scoped session (`orch` by default), so a PEER repo's controller holds the same
      # name — the #1856 shape this file refuses loudly everywhere else ("not provably this state dir's").
      # Waiting on it parks the unit's ExecStart forever: start never returns, nothing reaches cmd_check or
      # that refusal, and `--status` reads the unit as enabled+active with a live MainPID while the cell
      # dispatches nothing. So: no owned controller + a SEE-able one that is not ours = die, as the
      # non-service path does.
      if [ -z "$_own" ]; then
        _seen="$(seen_controller_pids 2>/dev/null)" || _seen=""
        if [ -n "$_seen" ]; then
          die "a controller runs from this machine's shared harness path ($(_pids_join_with_dirs "$_seen")) and is not provably this state dir's ($OR) — refusing to wait for it (that would supervise nothing while reporting an active unit). FIX: kill $(_pids_join "$_seen") — a pid whose state dir is not $OR is a leftover inner-chain member from a previous state dir (the measured row-7 case) and it blocks this cell's first start until it is gone; if it IS this repo's, give this repo its own SESSION in $ENV_FILE instead"
        fi
      fi
      # ⛔ THE CEILING DEPENDS ON WHICH WAIT THIS IS. An owned pid is a controller doing its work — long
      # bound. No owned pid but a session that is still there is an ORPHAN, and an orphan never exits: the
      # short bound is what turns "impossible start" into a filled start limit instead of an active unit.
      local _bound_now="$_bound" _who=""
      [ -z "$_own" ] && _bound_now="$_orphan_bound"
      # ⛔ ONE PHRASE, COMPOSED ONCE (review P3 round 9, #2402): `${_own:-word}` yields `_own`'s VALUE when it
      # is non-empty, so the two halves below concatenated — "pid 15562491556249", a pid `ps -p` cannot
      # resolve, handed to the operator inside the FATAL that tells them what to wait for.
      if [ -n "$_own" ]; then _who="pid $(_pids_join "$_own")"; else _who="tmux session '$SESSION'"; fi
      # ⛔ THE BOUND IS A CEILING ON THE WHOLE ATTEMPT, AND THE SLEEP IS 5 s GRANULAR (review P1 round 12,
      # #2402). Testing BEFORE the sleep let a bound of T cost T+5 s of wall time, and the installer's
      # start-limit arithmetic (`burst × (ceiling + RestartSec) < window`) assumed the ceiling was the cost:
      # at the accepted maximum the burst could never fill, so `Restart=always` restarted for ever while
      # `--status` read the unit supervised. Check the NEXT step, not the last one.
      [ "$((_waited + 5))" -le "$_bound_now" ] || die "still waiting, ${_waited}s after this start began, for $_who — refusing to become a second dispatcher; ${_own:+raise CONTROLLER_HANDOVER_TIMEOUT if this box is genuinely draining a long merge}${_own:-nothing owns that session, so it will never exit: stop it from the state dir that owns it}"
      [ "$_saidd" = 1 ] || log_line "controller already running ($_who) — this unit supervises the cell now: waiting for it to go, then taking over (a stop or a restart ends this wait)"
      _saidd=1
      sleep 5; _waited=$((_waited + 5))
      superseded && return 1
    done
    return 0
  }
  if [ "${ORCH_FOREGROUND:-0}" = 1 ]; then foreground_handover || return 1; fi
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
  # #2235: a global GH_REPO is a wrong-pair config of the same class as the queue/checkout mismatch,
  # and it must refuse START (not merely be stripped) so the misconfiguration is surfaced rather than
  # silently absorbed. The session commands below strip it either way.
  assert_gh_repo_conformance
  # BEFORE the already-running early return: see scheduler_ensure's header.
  # ⛔ AND AFTER assert_queue_target, deliberately: --start CLEARS the OFF switch, so running this
  # earlier meant a `start` that then REFUSED its queue target had already cleared an operator's
  # deliberate --stop — un-stopping a schedule on a start that never started anything.
  # ⛔ ALSO AFTER #2235'S GH_REPO REFUSAL, the same rule one refusal later: a start that refuses must
  # not have cleared the OFF switch on its way to refusing.
  scheduler_ensure
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
      # ⛔ SERVICE MODE NEVER ANSWERS "ALREADY RUNNING" (see foreground_handover): an orderly exit is a
      # start/exit loop under `Restart=always`, and the handover is what makes the unit converge instead.
      # ⛔ AND IT MUST NOT FALL THROUGH TO THE `say` EITHER (review P2 round 11, #2402). `foreground_handover`
      # returns 0 when the controller it waited for is GONE — so running the tail after it announced
      # "already running (controller pid <the dead pid>)" and returned 0 WITHOUT launching anything: a
      # documented `CELL READY` over a cell with no dispatcher, and under Restart=always another orderly
      # exit. In service mode the handover IS the whole answer: the predecessor is gone, so execution falls
      # through to the launch path below.
      if [ "${ORCH_FOREGROUND:-0}" = 1 ]; then
        foreground_handover || return 1
      else
      log_line "already running (controller pid $(_pids_join "$down")) — use: status | logs | stop"
      # agent-infra#1989: a live controller with no doctor is exactly the measured state (one loop on
      # the box). `start` is the idempotent launch verb, so it heals that half too rather than
      # answering "already running" about a cell that cannot reap or land.
      start_doctor_loop; local drc=$?
      # ⛔ ...and that heal is fenced like every other path in this function: a `stop` that lands while
      # `start_doctor_loop` runs must not be undone by the `.desired` marker / doctor session it just
      # created.
      # ⛔ THE FENCE RUNS WHETHER THE HEAL SUCCEEDED OR NOT (#2306 review): `start_doctor_loop || return 1`
      # ran BEFORE it, so a launch failure — and a `stop` that killed the last tmux session is exactly
      # what makes `new-session` fail — returned with the `.desired` marker the failed heal had just
      # written still on disk, i.e. it left the cell reading as STARTED after the operator's stop. The
      # rc is carried past the fence, never used instead of it.
      superseded && return 1
      [ "$drc" -eq 0 ] || return 1
      return 0
      fi
    fi
    # Nothing of ours holds it. Either this repo's loop has not written its lock yet (the seconds
    # `start` spends in check/seed — report it, do not refuse), or the session belongs to ANOTHER
    # repo sharing this cell's harness path (then it is not evidence about $OR at all).
    if [ -z "$seen0" ]; then
      # Same rule as above: in service mode the handover replaces the answer, because a session with no
      # controller of ours is an ORPHAN the handover waits out (short bound) and then falls through to.
      if [ "${ORCH_FOREGROUND:-0}" = 1 ]; then
        foreground_handover || return 1
      else
      log_line "already running (tmux session '$SESSION', no controller pid observed yet) — use: status | logs | stop"
      start_doctor_loop; local drc=$?
      superseded && return 1
      [ "$drc" -eq 0 ] || return 1
      return 0
      fi
    fi
    if [ "${ORCH_FOREGROUND:-0}" = 1 ]; then
      # The handover waits on the SESSION too, so a completed one means $seen0 is stale: re-read before
      # deciding, and never die on the pid list the wait just outlived (review P2 round 12, #2402).
      foreground_handover || return 1
      seen0="$(seen_controller_pids)" \
        || die "cannot read the process table (ps) — refusing to start on an unreadable read"
    fi
    [ -z "$seen0" ] || die "session '$SESSION' is held by a controller that is NOT provably this state dir's (pid $(_pids_join "$seen0"), no $LOCK owner, no $O/orch-loop.sh) — a session name is shared across repos, so it is not evidence that $OR is running; attach with: tmux attach -t $SESSION, or pin a distinct SESSION per repo in $ENV_FILE"
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
  # ⛔ A COMPLETED HANDOVER INVALIDATES THESE READS (review P2 round 12, #2402). They are taken BEFORE it,
  # and the handover waits for exactly the controller they name — so falling through with them intact sent
  # control into the `die` below ("a controller runs from this machine's shared harness path … refusing")
  # on a controller that had just exited: a FATAL after a successful wait, burning a start against
  # `StartLimitBurst`. In service mode the handover is the answer; the facts are re-read after it, and the
  # non-foreground tail (which must still answer "already running") is fenced to the operator path.
  if [ "${ORCH_FOREGROUND:-0}" = 1 ] && { [ -n "$own" ] || [ -n "$live" ]; }; then
    foreground_handover || return 1
    own="$(owned_controller_pids)" \
      || die "cannot read the process table (ps) — refusing to start on an unreadable read"
    live="$(seen_controller_pids)" \
      || die "cannot read the process table (ps) — refusing to start on an unreadable read"
  fi
  if [ -n "$own" ] && [ "${ORCH_FOREGROUND:-0}" != 1 ]; then
    log_line "already running (controller pid $(_pids_join "$own")) — use: status | logs | stop"
    # agent-infra#1989: heal the doctor half on THIS path too — it returns "already running" about a
    # live controller exactly like the session branch above, and a cell with a controller but no
    # doctor still cannot reap, land or prune. Fenced like every other path in this function.
    start_doctor_loop; local drc=$?
    superseded && return 1
    [ "$drc" -eq 0 ] || return 1
    return 0
  fi
  if [ -n "$live" ]; then
    # ⛔ NOT "already running", and NOT rc=0. This state dir started NOTHING: the pid runs the harness
    # path this MACHINE shares, so it is unprovably another repo's controller. Answering 0 said "$OR is
    # up" when it was not, and named `stop` as the remedy — which this same state dir refuses in this
    # exact state (#1856 review, reproduced). Starting here would put a second controller on one
    # queue, which is what #1761 forbids, so refuse and say exactly what is and is not known.
    die "a controller runs from this machine's shared harness path ($(_pids_join_with_dirs "$live")) and is not provably this state dir's ($OR) — refusing to start a second controller; it is left alone. FIX: kill $(_pids_join "$live") — a pid whose state dir is not $OR is a leftover inner-chain member from a previous state dir (the measured row-7 case) and it blocks this cell's first start until it is gone; if it IS this repo's, give this repo its own SESSION in $ENV_FILE instead"
  fi
  # ── a box whose controller is a SERVICE is started BY the service manager (agent-infra#2402) ────
  # Reaching this line means nothing of this cell's is running (every branch above returned or died), so
  # an ENABLED unit means the controller is DOWN. Launching a tmux controller here would put a second
  # dispatcher on this queue the moment the unit's `Restart=always` fires — the #1761 duplicate, produced
  # by the fix for #2402. An INSTALLED-but-NOT-enabled unit deliberately falls through to the tmux path:
  # "disabled" is an operator saying this box's controller is not service-managed.
  # ⛔ NOT in the foreground: that IS the unit's own ExecStart, and delegating from there would ask the
  # service manager to start the job this process is already running.
  if [ "${ORCH_FOREGROUND:-0}" != 1 ] && controller_unit_path >/dev/null 2>&1; then
    local ust
    controller_unit_state; ust=$?
    # ⛔ rc 3 must NOT read as "not service-managed": see controller_unit_state's note. Continuing would
    # start a tmux controller beside a unit that may be enabled, and that unit starts itself at boot.
    [ "$ust" -eq 3 ] && die "cannot read whether $CONTROLLER_UNIT is enabled — refusing to start a tmux controller beside a unit that may be enabled and start at boot (two dispatchers on one queue, #1761). Read it yourself: systemctl is-enabled $CONTROLLER_UNIT"
    # rc 1 is a real DISABLED answer: the operator said this box's controller is not service-managed, so
    # fall through to the tmux path below.
    # ⛔ AND A DISABLED-BUT-STILL-RUNNING UNIT IS THE DECISION, NOT AN OVERSIGHT (review P2 round 10, #2402,
    # NOT adopted). `systemctl disable` without `--now` keeps the loaded unit and its `Restart=always`, so a
    # `start` landing inside that RestartSec window can put a tmux controller beside a unit the manager is
    # about to bring back. A round-10 reviewer proposed deciding from the ACTIVE read instead. That reverses
    # the rule this PR states twice and pins with arms — "disabled is an OPERATOR saying this box is not
    # service-managed", so `start` uses tmux and never starts the unit — and a review round is not the place
    # to reverse it: the reopen argument lives in #2607, with the measured window and the cost of both
    # directions.
    if [ "$ust" -eq 0 ]; then
      # ⛔ A UNIT THAT HIT ITS START LIMIT IS FAILED BY DESIGN, AND `start` REFUSES IT (review P1, #2402).
      # StartLimitBurst=3 is what turns a configuration fault into an operator-visible `failed`; systemd then
      # refuses every later start until `reset-failed`. An operator who fixes the key/repo/pin and runs
      # `start` is asking for exactly one more attempt, so the counter is cleared first — a no-op on a
      # healthy unit, and the start plus the controller proof below still decide.
      # ⛔ AN AUTOMATED RESTART MUST NOT RE-ARM WHAT THE SERVICE MANAGER HAS STOPPED OR FAILED (review P1,
      # #2402). Every branch above establishes that no controller of this cell is RUNNING, which is NOT the
      # same fact as "the cell should be running": after a deliberate `systemctl stop` (the stop the unit's
      # own doc tells an operator to use) the marker `.desired` survives, so the doctor's next pass 120 s
      # later reaches this line — and `reset-failed` + `start` both (a) undoes the operator's stop, so the
      # manager reports `inactive` over a live dispatcher (the "reported stopped, still running" shape this
      # PR removes), and (b) CLEARS the start-limit counter that is supposed to converge a configuration
      # fault to `failed` — measured against a keyless cell, which retried forever with every surface
      # reading supervised. A HUMAN running `$0 start` is asking for exactly one more attempt, so the fence
      # is scoped to the automated caller and reported as its own outcome (rc 4), never as a failure.
      if [ "${ORCH_AUTOMATED_RESTART:-0}" = 1 ]; then
        local ast=0 _ast_word=""
        _ast_word="$(sup_systemctl is-active "$CONTROLLER_UNIT" 2>/dev/null || true)"
        controller_unit_active_state || ast=$?
        # ⛔ rc 3 IS CANNOT-READ, NOT "STOPPED" (review P1, #2402). `is-active` answers with an empty or
        # unrecognised word when it could not ASK — an expired `sudo -n` timestamp, a user-scope manager with
        # no DBus from inside the doctor's session, a transient — and folding that into the rc-4 outcome made
        # the doctor record a CLEAN pass over a cell with no dispatcher, for ever: the #2402 false green this
        # whole change removes, one layer in. It also contradicts the rule ~70 lines above, which treats the
        # same unreadable answer to `is-enabled` as fatal. Only a READ answer of not-active skips the re-arm.
        if [ "$ast" -eq 3 ]; then
          die "cannot read whether $CONTROLLER_UNIT is active — refusing to re-arm it on a guess (systemctl is-active $CONTROLLER_UNIT)"
        fi
        # ⛔ `activating` IS THE RESTART WINDOW, NOT A RUNNING CONTROLLER (review P2 round 9, #2402).
        # `controller_unit_active_state` maps `active|reloading|ACTIVATING` to 0, and `activating` is exactly
        # what `Restart=always` reports inside its RestartSec — the state a configuration-faulting unit spends
        # its life in. Scoring that as "running" let the fence fall through to the `reset-failed` below, which
        # ALSO ZEROES the per-unit start rate limit, and the doctor runs this every DOCTOR_INTERVAL (120 s)
        # against a 300 s window: two passes inside one window cleared the counter twice, so convergence to
        # `failed` became probabilistic instead of guaranteed — the endless retry the arithmetic exists to
        # stop. Only a literal `active`/`reloading` (a process that exists) takes the re-arm path.
        if [ "$ast" -eq 1 ] || [ "$_ast_word" = "activating" ]; then
          # ⛔ A FAILED UNIT IS NOT AN OPERATOR DECISION (review P1 round 11, #2402). This branch folded every
          # not-active word — `inactive`, `deactivating`, `failed` — into rc 4, which the doctor records as a
          # CLEAN pass. But `failed` is systemd's own throttle, not a human's decision: a `Restart=always` unit
          # whose controller keeps exiting converges to `failed` in ~45 s (3 attempts at RestartSec=15) with
          # `.desired` still present, and folding it into rc 4 made `doctor status` exit 0 over a STARTED cell
          # with NO dispatcher — the false green this whole change removes, one layer in. The distinction the
          # word already carries is now reported: rc 4 only for the states a manager stop leaves, and rc 5 for
          # a unit that has given up, which the doctor scores as a NON-clean pass.
          if [ "$_ast_word" = "failed" ]; then
            log_line "REFUSING: $CONTROLLER_UNIT is FAILED — its start limit converged and this state dir has NO dispatcher. The service manager will not bring it back without a human: run '$0 start' to re-arm it."
            return 5
          fi
          log_line "note: NOT re-arming $CONTROLLER_UNIT — the service manager owns this controller and reports it $(sup_systemctl is-active "$CONTROLLER_UNIT" 2>/dev/null || printf unknown): a deliberate stop is the operator's decision. Run '$0 start' to re-arm it."
          return 4
        fi
      fi
      # ⛔ AND AN AUTOMATED RESTART NEVER CLEARS THE COUNTER (review P2, #2402). The fence above only exits
      # for `inactive`/`failed`, while an auto-restarting unit is `activating`/`active` for almost all of its
      # life — so `reset-failed` ran on exactly the state whose burst is still filling, and a slow-failing
      # configuration fault (each attempt costing CONTROLLER_ORPHAN_TIMEOUT) restarted forever with `--status`
      # reading `supervised`: the pre-fix state the StartLimit block, the doc and the installer's arithmetic
      # all assert is gone. A HUMAN running `$0 start` is asking for one more attempt and keeps the reset.
      [ "${ORCH_AUTOMATED_RESTART:-0}" = 1 ] || sup_systemctl reset-failed "$CONTROLLER_UNIT" >/dev/null 2>&1 || true
      sup_systemctl start "$CONTROLLER_UNIT" \
        || die "could not start $CONTROLLER_UNIT — this box's controller is service-managed, so no tmux controller was launched (systemctl status $CONTROLLER_UNIT)"
      # The same proof the tmux path gives: a PROCESS this state dir can see, within the start timeout.
      # Reporting success on an is-active alone is the false green this file refuses elsewhere — a unit can
      # be `active` while its controller died before it took the lock.
      # ⛔ 600 s, NOT THE 60 s THE REST OF THIS FILE USES (review P2, #2402). The unit's ExecStart runs the
      # WHOLE of `start` — harness_apply (a git fetch into a detached worktree) and cmd_check (network
      # reads) — BEFORE the loop takes the lock, and cloud-cell-doctor.sh already defaults this same call
      # to 600 s. At 60 s a healthy service-managed start was reported as FATAL while its controller came
      # up a minute later, and the doctor recorded the restart as failed.
      local waited=0
      while [ "$waited" -lt "${CONTROLLER_SERVICE_START_TIMEOUT:-${CONTROLLER_START_TIMEOUT:-600}}" ]; do
        if [ -n "$(owned_controller_pids 2>/dev/null)" ]; then break; fi
        sleep 1; waited=$((waited + 1))
      done
      [ -n "$(owned_controller_pids 2>/dev/null)" ] \
        || die "$CONTROLLER_UNIT is active but no controller of this state dir is running after ${waited}s — read: journalctl -u $CONTROLLER_UNIT -n 40"
      log_line "controller started (systemd $CONTROLLER_UNIT, pid $(_pids_join "$(owned_controller_pids)")) — service-managed: use '$0 stop', not a session"
      # ⛔ THE FENCE APPLIES TO THIS PATH TOO (#2402 review P2). Every other launch in this function
      # re-checks the stop generation; without it a STOP that landed between the pid read above and the
      # unit start is UNDONE — `stop` prints "controller stopped (systemd …)" and returns 0, and the
      # controller comes up seconds later. That is the "reported stopped, still running" shape this verb
      # exists to remove, on the one path that controls a unit.
      superseded && return 1
      return 0
    fi
  fi
  # ⛔ A UNIT THAT IS ANOTHER STATE DIR'S IS NOT THIS CELL'S SUPERVISOR (review P1, #2402), so the tmux
  # path below is the RIGHT answer — but silently ignoring it would hide the only unit on the box from the
  # operator whose cell has just lost its controller. Say it, once, and start this cell normally.
  if [ "${ORCH_FOREGROUND:-0}" != 1 ] && [ -z "${_UNIT_PATH:-}" ] && [ -n "$_UNIT_FOREIGN" ]; then
    log_line "note: $_UNIT_FOREIGN supervises state dir '$(unit_owner_dir "$_UNIT_FOREIGN" 2>/dev/null)', NOT this one ($O) — starting this cell's controller as a session; nothing on this box will restart IT (#2402). Install a unit for this state dir: bash $(dirname "$SUP_SELF")/install-controller-service.sh --install"
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
           log_line "warn: only ${mb}MB free, but workers may still be running — NOT auto-pruning caches (a pruned cache breaks the live lane). Run '$0 prune' once they finish."
         else
           cmd_prune --caches
         fi
       fi ;;
  esac
  harness_apply
  seed_and_stamp
  log_line "harness: ${HARNESS_COMMIT:0:12} (${HARNESS_REL}) at $HARNESS${HARNESS_APPLIED:+ [applied]}"
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
    log_line "provisioned record step: $rsrc -> $rec"
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
    log_line "provisioned record-step library: $rlibsrc -> $rlib"
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
  # ── SERVICE MODE: this process IS the controller (agent-infra#2402) ──────────────────────────────
  # ⛔ THERE IS NO SECOND BOUNDARY HERE, SO THERE IS NO SECOND COPY OF THE ENVIRONMENT. The tmux command
  # string just below exists because a session is served the SERVER's environment, not this shell's —
  # which is why it re-sources $ENV_FILE and re-sets every value inside the session. In this process
  # there is no server: `start` already sourced $ENV_FILE at load, cmd_check has just proved the merge
  # key arrives, and these exports ARE the controller's environment. `exec` (not a child) is what makes
  # the service manager's cgroup the owner of the controller — and the argv is the SAME
  # `<bash> $HARNESS/orch-loop.sh` the tmux path runs, so every existing pid/ownership read still works.
  if [ "${ORCH_FOREGROUND:-0}" = 1 ]; then
    mkdir -p "$ROLES_DIR" 2>/dev/null && : > "$ROLES_DIR/.desired" 2>/dev/null || log_line "warn: could not record the desired running state at $ROLES_DIR/.desired"
    export HOME="$CELL_HOME" CELL_HOME O REPO OR SCOPE ENV_FILE SESSION
    export HARNESS_REPO HARNESS_REF HARNESS_PIN_DIR HARNESS_PIN_FILE HARNESS_MATERIALISER="${SUP_SELF:-}"
    # ⛔ AND THE GLOBAL REPO IS DROPPED ON THIS PATH TOO (review P1 round 18, #2402). The tmux path below
    # unsets it inside its command string, and the doctor's string unsets its own copy — this branch had
    # neither, so a `keys.env` carrying `GH_REPO=` (which `set -a; . "$ENV_FILE"` exports into THIS process)
    # was inherited by the `exec`ed controller: every gh-driven rail on a service-managed cell then graded
    # whatever repo keys.env named, printing `ALREADY MERGED` over zero work on the wrong repo (measured
    # 2026-10-21, and the same class the rail's own #2235 fixes). `exec` REPLACES this process, so the unset
    # has to happen before it — a later statement never runs. `unset` works whether or not the variable is
    # exported, and the unit renders no `UnsetEnvironment=`.
    unset GH_REPO
    # ⛔ THE gh-limit LAYER IS PART OF THE ENVIRONMENT, NOT OF THE TMUX PATH (#1988). The session string
    # below puts `$O/gh-limit` FIRST on PATH; in service mode there is no session string, so the same
    # export has to happen HERE or the controller silently loses the gh wrapper — every gh call
    # unserialised and unbacked-off, on the one box shape this unit creates. `start` has already seeded
    # it (cmd_check refuses a cell whose layer cannot run), so this only ever prepends a real directory;
    # the guard keeps a cell that legitimately ships no layer (the "NOT serialised" warning above) from
    # gaining a PATH entry that does not exist.
    [ -d "$O/gh-limit" ] && export PATH="$O/gh-limit:$PATH"
    # ⛔ THE DOCTOR ROLE IS NOT OPTIONAL ON THIS PATH EITHER (#2402 review P1). The tmux path launches it a
    # few lines below; `exec` REPLACES this process, so anything placed after it never runs. Without this
    # call a service-managed cell dispatches but never reaps, lands, repairs or prunes — the "dispatches
    # but cannot land" shape `start` refuses to report as started everywhere else. The fence is re-checked
    # after it, for the same reason every other launch in this function re-checks it.
    # ⛔ AND ITS FAILURE IS REFUSED HERE TOO (review P2, #2402). `exec` replaces this process, so a doctor
    # that could not start is invisible a character later: the unit reads `active`, `--status` reports the
    # cell supervised, and nothing reaps, lands, repairs or merges — the "dispatches but cannot land" state
    # `start` refuses to report as started on every other launch path in this function (the tmux path two
    # dozen lines below captures `drc` for exactly this reason). Returning non-zero also lets StartLimit
    # converge to `failed` instead of hiding the fault behind a running-looking unit.
    start_doctor_loop || return 1
    superseded && return 1
    log_line "controller: FOREGROUND — this process is the controller (pid $$); its lifetime belongs to the service manager"
    exec bash "$HARNESS/orch-loop.sh"
  fi
  # ⛔ AND THE REPO A COMMAND ACTS ON IS PER-INVOCATION STATE, NEVER A GLOBAL EXPORT (measured
  # 2026-10-21). A pushed `keys.env` on a cell carried `GH_REPO=daniel-ospina/tortoise`; `gh` honours
  # `GH_REPO` as its default repo for EVERY command, so an agent-infra rail on that box graded the
  # TORTOISE repo and printed `ALREADY MERGED` for a September tortoise PR — success over zero work, on
  # the wrong repo, with nothing in the output saying so (the same class #2235 fixes in the rail itself).
  # The session RE-SOURCES $ENV_FILE, so unsetting it out here would be undone a few characters later;
  # the `unset` therefore lives INSIDE the command string, immediately after the source, and the same
  # `unset` is in the doctor's string because that loop can restart the controller.
  # ⛔ THE SESSION IS SERVED THE TMUX SERVER'S ENV, NOT THIS SHELL'S — so the `unset` cannot be done
  # here and must be part of the string, exactly like every other value below.
  tmux new-session -d -s "$SESSION" -c "$HARNESS" \
    "set -a; [ ! -f '$ENV_FILE' ] || . '$ENV_FILE'; set +a; unset GH_REPO; PATH='$O/gh-limit':\"\$PATH\" HOME='$CELL_HOME' CELL_HOME='$CELL_HOME' REPO='$REPO' O='$O' OR='$OR' SCOPE='$SCOPE' HARNESS_REPO='$HARNESS_REPO' HARNESS_REF='$HARNESS_REF' HARNESS_PIN_DIR='$HARNESS_PIN_DIR' HARNESS_PIN_FILE='$HARNESS_PIN_FILE' HARNESS_MATERIALISER='${SUP_SELF:-}' bash '$HARNESS/orch-loop.sh' 2>&1 | tee -a '$O/logs/controller.log'"
  sleep 3
  if tmux has-session -t "$SESSION" 2>/dev/null; then
    log_line "controller started (tmux '$SESSION'), state=$O"
    superseded && return 1
  else
    die "controller exited immediately — read $O/logs/controller.log"
  fi
  # The SECOND role. `start` is not successful unless the repair/merge loop is also up: a cell that
  # dispatches but cannot land is the measured #1989 state, and a start that reported success over
  # it would be the same false green this file refuses everywhere else.
  start_doctor_loop; local drc=$?
  superseded && return 1
  [ "$drc" -eq 0 ] || return 1
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

# ⛔ THE EFFECT OF A UNIT STOP IS READ AFTER THE TEARDOWN, AND ON **BOTH** EXITS OF `stop` (#2402 review,
# cycle 2). Reading it at the `systemctl stop` call cannot separate the two states that look identical
# there: (a) the migration state — a unit installed but DISABLED, where the unit stop is a deliberate
# no-op and the PID TEARDOWN stops the controller; and (b) the wrong-scope case — the stop landed on `
# the other manager and the live unit's `Restart=always` brings a controller back. (a) must be a clean
# stop (reading early failed it, and `harness-down` turned that into a refusal over a quiet box); (b) must
# fail. Only a POST-teardown observation distinguishes them, and gating on the unit's own state cannot:
# in (b) the ADDRESSED unit is equally disabled+inactive. The window is held OPEN for the manager —
# breaking on the first empty read would let a controller whose RestartSec is 15 s return after this
# function had printed success.
# 0 = nothing of this state dir came back · 1 = a controller is alive after the teardown.
unit_stop_effect_verdict() { # <unit>
  [ -n "${1:-}" ] || return 0
  local w=0 own
  while [ "$w" -lt "${CONTROLLER_STOP_TIMEOUT:-20}" ]; do
    [ -z "$(owned_controller_pids 2>/dev/null)" ] || break
    sleep 1; w=$((w + 1))
  done
  own="$(owned_controller_pids)" \
    || die "cannot read the process table (ps) — refusing to report a stop from an unreadable read"
  [ -n "$own" ] || return 0
  log_line "warn: $1 was stopped but a controller of this state dir (pid $(_pids_join "$own")) is STILL running ${w}s AFTER the teardown — either it is the OTHER scope's unit under Restart=always, or something restarted it; not reporting a stop"
  return 1
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
  rm -f "$ROLES_DIR/.desired" 2>/dev/null || { log_line "warn: could not remove $ROLES_DIR/.desired — an in-flight restart may re-arm this cell"; rc=1; }
  bump_stop_generation || { log_line "warn: could not record the stop generation in $O/$STOP_GEN_FILE_REL — an in-flight start may still complete and undo this stop"; rc=1; }
  # ── a SERVICE-MANAGED controller is stopped by its service manager (agent-infra#2402) ─────────
  # ⛔ THIS IS NOT AN OPTIMISATION. `Restart=always` re-creates the controller within RestartSec of ANY
  # kill this function performs (the session kill, the pid TERM, the -9 sweep), so a stop that skips the
  # unit returns success over a dispatcher that is back seconds later — the "reported stopped, still
  # running" shape this whole verb exists to remove. Done BEFORE the pid logic so the reads below see the
  # controller already gone instead of racing its restart; an INSTALLED-but-not-written-down unit is
  # stopped anyway (stopping an inactive unit is a no-op), because the durable state must be "stopped"
  # whatever the job was doing.
  local stop_unit="" have_unit=0
  controller_unit_path >/dev/null 2>&1 && have_unit=1
  # ⛔ OWNERSHIP IS REPORTED WHETHER OR NOT A COPY WAS ADDRESSED (verification P1, #2402). The resolver
  # ADDRESSES an unprovable copy (a hand-written unit with no `Environment=O=` line) instead of ignoring it,
  # so the warnings below used to live in the `else` of the stop block — a branch an unprovable copy can
  # never reach, because resolving it returns 0. They were therefore dead code, and `stop` quietly stopped a
  # unit whose ownership it could not prove: the report has to sit beside the DECISION, not beside a
  # non-zero rc.
  if [ -n "$_UNIT_UNPROVABLE" ] && [ "${_UNIT_PATH:-}" = "$_UNIT_UNPROVABLE" ]; then
    log_line "warn: $_UNIT_UNPROVABLE carries no Environment=O= line, so it cannot be proven to be this state dir's ($O) — it is addressed because treating it as foreign would launch a second dispatcher beside it (#1761); re-render it (install-controller-service.sh --install) so ownership is readable"
  fi
  # ⛔ A UNIT THAT IS ANOTHER STATE DIR'S IS NOT THIS CELL'S SUPERVISOR (review P1, #2402), so it is never
  # stopped on this cell's behalf — but it is NAMED: before ownership was read, this verb stopped whatever
  # copy the box happened to carry, so B's `stop` stopped A's unit and reported `controller stopped` for a
  # controller it never touched.
  if [ -n "$_UNIT_FOREIGN" ]; then
    if [ "$have_unit" -eq 1 ]; then
      log_line "note: also installed: $_UNIT_FOREIGN supervises state dir '$(unit_owner_dir "$_UNIT_FOREIGN" 2>/dev/null)', NOT this one ($O) — left alone"
    else
      log_line "note: $_UNIT_FOREIGN supervises state dir '$(unit_owner_dir "$_UNIT_FOREIGN" 2>/dev/null)', NOT this one ($O) — it is not this cell's supervisor, so this stop leaves it alone; the pid teardown below is what stops this cell"
    fi
  fi
  if [ "$have_unit" -eq 1 ]; then
    if sup_systemctl stop "$CONTROLLER_UNIT" 2>/dev/null; then
      stop_unit="$CONTROLLER_UNIT"
      # ⛔ A SUCCESSFUL `stop` ON THE UNIT WE ADDRESSED IS NOT PROOF THE CONTROLLER IS GONE (review P3,
      # #2402). The scope is the unit FILE this verb RESOLVED — a copy proven to be this state dir's, and
      # the enabled/active one when two of ours exist (`controller_unit_path`) — which is not necessarily
      # "the unit that is running": with two unit files on the box (an image-baked disabled system unit
      # plus the live user unit) the stop can land on the wrong manager, the live unit's `Restart=always`
      # brings the controller straight back, and the pid reads below can conclude before the new
      # controller writes its lock — so this verb would print "controller stopped (systemd …)" over a live
      # dispatcher. The EFFECT is therefore read — but AT THE END, AFTER THE TEARDOWN (see the note at the
      # post-kill assertion), never here. Reading it here cannot work: in the state the migration doc
      # calls normal (a unit installed but DISABLED, controller in tmux) the stop above is a deliberate
      # NO-OP, so this read would sleep the whole window over a controller this function has not killed
      # yet and fail a stop that then succeeds. Gating on the unit's own state does not separate the two
      # cases either, because in the wrong-scope case the ADDRESSED unit is equally disabled+inactive.
    else
      log_line "warn: could not stop $CONTROLLER_UNIT — the service manager may restart the controller after this stop"; rc=1
    fi
  fi
  if [ -n "$_UNIT_UNPROVABLE" ] && [ "${_UNIT_PATH:-}" != "$_UNIT_UNPROVABLE" ]; then
    log_line "warn: a second copy, $_UNIT_UNPROVABLE, carries no Environment=O= line — its ownership is UNKNOWN, not proven; this verb addressed $_UNIT_PATH"
  fi
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
      log_line "stopped an in-flight controller restart (pid $rpid)"
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
      tmux kill-session -t "=$DOCTOR_SESSION" || { log_line "warn: could not stop the doctor loop '$DOCTOR_SESSION'"; rc=1; }
      log_line "doctor loop stopped (tmux '$DOCTOR_SESSION')"
    else
      # No loop record and this cell was never started: the session is somebody else's doctor. Leave
      # it alone and say so — the same direction `stop` takes for a foreign CONTROLLER.
      log_line "note: doctor session '$DOCTOR_SESSION' exists but is not provably this cell's (no loop record, cell not started) — left alone"
    fi
  fi
  # ⛔ The "survived" verdict is FENCED too: a live pid whose recorded identity no longer matches is
  # a RECYCLED pid, not our loop — warning about it (and returning rc=1) would tell the operator that
  # a successful stop failed.
  if ! end_loop_pid "$lpid" "$lident"; then
    log_line "warn: the doctor loop (pid $lpid) survived the stop and could not be ended"; rc=1
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
          rm -f "$LOCK" && log_line "released a stale lock $LOCK (its owner pid $lp is gone)"
        fi
      fi
      # A stop that went through the SERVICE MANAGER says so: "not running" is true but reads as "there
      # was nothing to stop", which is the opposite of what happened and hides the unit from the operator
      # who is about to check that the box stays stopped.
      # ⛔ AND THE UNIT'S EFFECT IS VERIFIED HERE TOO (this branch returns before the common tail): a
      # clean "stopped (systemd …)" must not be printed over a controller that came back after the
      # teardown — nor a failure over one that is genuinely gone.
      if [ -n "$stop_unit" ]; then
        unit_stop_effect_verdict "$stop_unit" || rc=1
        [ "$rc" -eq 0 ] || return 1
      fi
      if [ -n "$stop_unit" ]; then log_line "controller stopped (systemd $stop_unit)"; else log_line "not running"; fi
      # A doctor-loop stop failure recorded above still fails the verb: "not running" is about the
      # CONTROLLER, and this branch used to return 0 over it.
      [ "$rc" -eq 0 ] || return 1
      return 0
    fi
    log_line "no tmux session '$SESSION', but a controller is live (pid $(_pids_join "$own")) — stopping it"
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
    log_line "controller stopped (tmux '$SESSION')"
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
  # ⛔ The unit's effect, read AFTER the teardown (see unit_stop_effect_verdict). A controller that
  # reappeared here makes the verb fail, and the lock below is NOT released — its owner is alive, and a
  # lock removed while its owner lives is #1761's duplicate.
  if [ -n "$stop_unit" ]; then
    unit_stop_effect_verdict "$stop_unit" || return 1
  fi
  live="$(seen_controller_pids)" \
    || die "cannot read the process table (ps) — NOT releasing $LOCK on an unreadable read"
  foreign="$(_pids_minus "$live" "$own")"
  [ -z "$foreign" ] || log_line "note: a controller for ANOTHER repo is still running from the shared harness path (pid $(_pids_join "$foreign")) — left alone"
  rm -f "$LOCK" && log_line "released lock $LOCK"
  [ "$rc" -eq 0 ] || return 1
  return 0
}
cmd_status() {
  local cpids own foreign
  # The ceiling goes in the STATUS report too: `status` is what an operator (and the doctor) reads
  # when a box is misbehaving, and the answer to "is it over its memory ceiling" belongs there.
  lane_ceiling_report
  cpids="$(seen_controller_pids)" \
    || die "cannot read the process table (ps) — refusing to report a controller state from an unreadable read"
  own="$(owned_controller_pids)" \
    || die "cannot read the process table (ps) — refusing to report a controller state from an unreadable read"
  foreign="$(_pids_minus "${cpids:-}" "${own:-}")"
  if [ -n "$own" ]; then
    # Name the owner and the scope (#1761's per-box read): the answer to "which box owns this queue",
    # from the lock and this cell's own process scope — never the tmux session alone.
    log_line "controller: RUNNING (pid $(_pids_join "$own")) — scope=$SCOPE repo=$OR"
  elif [ -n "$cpids" ]; then
    # ⛔ SEEN BUT NOT OWNED. HARNESS_PIN_DIR is one directory per cell home, so a controller for a
    # DIFFERENT repo on this machine runs the SAME harness path and this read returns it (#1856
    # review, reproduced). Naming it as this state dir's owner would attribute another repo's work
    # to this queue, so say exactly what was read and which part is not ours.
    log_line "controller: RUNNING (pid $(_pids_join "$cpids")) — NOT this state dir's (another repo sharing the harness path); scope=$SCOPE repo=$OR"
  elif tmux has-session -t "$SESSION" 2>/dev/null; then
    # The session exists but no orch-loop.sh pid is visible yet: `start` spends seconds in
    # check/seed before the loop execs, so report starting — NOT the false STOPPED.
    log_line "controller: RUNNING (tmux '$SESSION', no orch-loop.sh pid observed yet) — scope=$SCOPE repo=$OR"
  else
    log_line "controller: STOPPED"
  fi
  [ -z "$foreign" ] || log_line "also seen:  pid $(_pids_join "$foreign") runs this machine's harness but does not hold $LOCK — another repo's controller; reported, never signalled"
  # agent-infra#2402: is there anything ABOVE the controller that restarts it? A dead controller and an
  # idle box print the same `controller: STOPPED` / `lanes: 0`, so "who would restart this" belongs in
  # this output and not in an operator's memory. Reported, never refused: `status` must stay answerable
  # on a box that has no service at all — that is exactly the box this line is for.
  local _svc=""
  # ⛔ A DIRECT CALL, NOT `_svc="$(controller_unit_path)"` (review P1, #2402): a command substitution
  # runs in a SUBSHELL, so the resolved `_UNIT_PATH`/`_UNIT_FOREIGN`/`_UNIT_UNPROVABLE` would be lost in
  # this shell — and `sup_systemctl` below derives its SCOPE from `_UNIT_PATH`. The row would then be
  # read through the wrong manager and report the copy this verb did not resolve.
  controller_unit_path >/dev/null 2>&1 && _svc="$_UNIT_PATH"
  if [ -n "$_svc" ]; then
    # ⛔ THE ROW NAMES WHICH ANSWER IT GOT (review P2, #2402). `is-active --quiet` says "no" for both
    # `inactive` and "could not read", and printing "nothing will restart a dead controller" over an
    # unreadable read is a false verdict about the one thing this row exists to be true about.
    local _ast
    controller_unit_active_state; _ast=$?
    case "$_ast" in
      0) log_line "supervision: $CONTROLLER_UNIT ACTIVE ($(basename "$(dirname "$_svc")") scope) — Restart=always; a dead controller comes back without a human" ;;
      1) log_line "supervision: ⛔ $CONTROLLER_UNIT installed but NOT ACTIVE — nothing will restart a dead controller: systemctl start $CONTROLLER_UNIT" ;;
      *) log_line "supervision: ⚠ $CONTROLLER_UNIT is installed but its STATE COULD NOT BE READ ($(sup_systemctl is-active "$CONTROLLER_UNIT" 2>&1 | head -1)) — whether anything restarts a dead controller is UNKNOWN, not 'no'" ;;
    esac
    # ⛔ AND THE ROW SAYS WHETHER OWNERSHIP WAS PROVEN (review P1, #2402): a unit of ANOTHER state dir's
    # must never be reported as this cell's supervision, and a unit that declares no owner at all is
    # UNKNOWN rather than either answer.
    [ "${_UNIT_UNPROVABLE:-}" != "$_svc" ] || log_line "supervision: ⚠ ownership NOT proven — $_svc carries no Environment=O= line, so whether it supervises this state dir ($O) is UNKNOWN; the row above describes the copy this verb addressed"
    [ -z "$_UNIT_FOREIGN" ] || log_line "supervision: also installed: $_UNIT_FOREIGN supervises state dir '$(unit_owner_dir "$_UNIT_FOREIGN" 2>/dev/null)' — NOT this one ($O)"
  else
    log_line "supervision: ⛔ NONE — the controller is a tmux session and nothing restarts it (#2402); install the service: bash $(dirname "$SUP_SELF")/install-controller-service.sh --install"
    # ⛔ "NONE" IS A CLAIM ABOUT THIS STATE DIR, not about the box (review P1, #2402). A unit for another
    # cell is not this cell's supervision, and printing only NONE left an operator with no way to see
    # that the box DOES have a unit — pointed at a different state dir.
    [ -z "$_UNIT_FOREIGN" ] || log_line "supervision: also installed: $_UNIT_FOREIGN supervises state dir '$(unit_owner_dir "$_UNIT_FOREIGN" 2>/dev/null)' — NOT this one ($O), so it will not restart this cell's controller"
    [ -z "$_UNIT_UNPROVABLE" ] || log_line "supervision: ⚠ $_UNIT_UNPROVABLE carries no Environment=O= line — whether it supervises this state dir ($O) is UNKNOWN, not 'no'"
  fi
  log_line "state dir: $O"
  # agent-infra#1901: does this cell stand where it is pointed? ONE line — the repo the queue targets,
  # the checkout it is standing in, and the remote that fact was read from. Reported, never refused:
  # `status` is the verb an operator runs to DISCOVER that the pair is wrong.
  log_line "queue: ${QUEUE_REPO:-<unknown>} @ ${REPO:-<unset>} — origin ${QUEUE_REMOTE:-<none>} [$(queue_state_text)]"
  # agent-infra#1745: the answer to "which commit is this cell running?", from the record `start`
  # wrote. Printed even when the controller is stopped — a stale cell is a stale cell.
  if [ -f "$STAMP" ]; then
    log_line "harness: $(stamp_field commit | cut -c1-12) [$(stamp_field relation)] from $(stamp_field harness)"
  elif [ -n "$HARNESS" ]; then
    log_line "harness: UNRECORDED at $HARNESS ($(harness_commit | cut -c1-12)) — run: $0 apply"
  fi
  # ── the PIN and the last self-refresh verdict (agent-infra#2215) ────────────────────────────────
  # MEASURED 2026-10-20: three cells ran 27 commits behind origin/main with an EMPTY pin. The stamp
  # above names the commit `start`/`apply` last SEEDED; the pin names what the cell is DEPLOYED to
  # now (the controller re-pins itself every cycle). They can legitimately disagree for one cycle
  # after a re-pin, which is why both are printed — but an EMPTY pin is never a quiet absence: its
  # own state, with the remedy, because it is the state the fleet sat in for hours.
  local _pin _pv _hrf _k _rel _run _act _at _age _fet _rq
  _pin="${HARNESS_PIN:-$CELL_HOME/.pi/agent/state/HARNESS-PIN}"
  _pv="$(head -1 "$_pin" 2>/dev/null | tr -d '[:space:]')"
  if [ -n "$_pv" ]; then
    log_line "pin: ${_pv:0:12} ($_pin)"
  else
    log_line "⛔ PIN EMPTY ($_pin) — nothing here records which harness this cell is deployed to; that is the measured 2026-10-20 state of all three cells. The controller's next cycle records it (harness-refresh.sh); '$0 apply' additionally re-seeds from $HARNESS_REF."
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
    log_line "self-refresh: ${_rel:-unknown} (runs ${_run:-unknown}, action=${_act:-none}, fetch=${_fet:-unknown}) — $_age"
    # ⛔ A RELATION IS ONLY AS GOOD AS THE COMPARISON IT WAS MADE FROM. `current` against a ref this cycle
    # could not fetch (or did not fetch) is cannot-verify, and the state record says so — but only if
    # `status` prints it, or the operator reads `current` and stops there.
    case "${_fet:-ok}" in
      ok) : ;;
      *) log_line "⛔ self-refresh comparison was NOT fresh (fetch=$_fet) — a 'current' above means 'current against the ref as of the last successful fetch', not against origin now" ;;
    esac
    # A verdict older than two cycles is not this cycle's answer: the controller has stopped
    # refreshing, so the pin above is a fact about the PAST. Same age-bound rule as the funnel, and the
    # SAME DEFAULT the loop coerces to (`orch-loop.sh` uses `CYC=240`) — `status` usually runs from an
    # operator shell where CYC is unset, so a 900 default here would fire ~8 cycles late while still
    # claiming "two".
    case "${_at:-}" in
      ''|*[!0-9]*) : ;;
      *) if [ $(( $(date +%s) - _at )) -gt $(( ${CYC:-240} * 2 + 300 )) ]; then
           log_line "⛔ self-refresh STALE (>${_age:-?}) — the controller is not re-pinning; the pin above describes an older cycle"
         fi ;;
    esac
  else
    log_line "self-refresh: NO RECORD at $_hrf — no cycle has recorded a self-refresh verdict yet (started before this check existed, or the loop cannot write state)"
  fi
  # ── the restart DECISION, and what became of it (agent-infra#2641) ──────────────────────────
  # `restart-pending` used to be a word printed into a reason string. On a cell it was also PERMANENT
  # (the running identity could not be read there at all), so the same box printed `[current]` on the
  # `harness:` line above and `restart-pending` here, for ever. The per-cycle record now carries the
  # REASON and a request; printing it beside the verdict is what makes "requested at T … honoured at
  # T+n / refused because Y" readable from the one verb an operator runs.
  # ⛔ AN ABSENT RECORD IS NOT "NOTHING PENDING": no cycle has recorded a request, which is a different
  # fact, and the same absence-vs-empty rule the rest of this file follows.
  _rq="$O/state/restart-request"
  if [ -f "$_rq" ]; then
    log_line "restart: $(sed 's/^restart //' "$_rq" 2>/dev/null)"
    case "$(cat "$_rq" 2>/dev/null)" in
      # ⛔ `blocked=identity` IS ITS OWN CAUSE, AND IT COMES FIRST. The generic blocked arm below says
      # "something this box can see would be interrupted" — but on the `blocked=identity` path
      # `harness-refresh.sh` returns from `set_pending` BEFORE `inflight_gate` is ever consulted, so no
      # population was measured as the BLOCKER: the record's `lanes=` is still written (it is measured
      # separately and may be non-zero) but it is not why the request is blocked. The identity is. So the
      # generic sentence names a cause that does not exist and tells the operator to wait for a population
      # that may never be the thing holding the restart back — the misdirection this change exists to remove.
      *'request=pending'*'blocked=identity'*)
        log_line "a restart is PENDING but was NOT certified needed — the running identity cannot be PROVEN (it comes from the stamp/claim, not from the live controller), and acting on an unproven premise is how a refresh becomes an incident. The block is the IDENTITY, not a busy population: nothing was measured as the blocker, and no population is waiting on this. Re-check once the controller's argv/lock is readable." ;;
      *'request=pending'*'actuation=blocked'*)
        log_line "⛔ a restart is PENDING and was NOT applied — something this box can see would be interrupted (named in blocked=/lanes= above). Actuator: '$0 stop && $0 apply && $0 start', or merge-reminder.py's deploy arm, once that population is idle." ;;
      *'request=pending'*'actuation=safe'*)
        log_line "a restart is PENDING and was NOT applied — every population this box can measure was empty (checked=argv,roles,tree; blind=reparented-no-wrapper). Actuator: '$0 stop && $0 apply && $0 start', or merge-reminder.py's deploy arm." ;;
    esac
  else
    log_line "restart: NO REQUEST RECORD at $_rq (no cycle has recorded one — that is not the same as 'nothing pending')"
  fi
  # agent-infra#1736: a PERMANENT dispatch-provisioning failure makes the cell MERGE-ONLY, and
  # nothing else in this output says so — `lanes: 0` is also what a healthy idle cell prints.
  # orch-loop.sh records the reason in .refresh-blocked; surface it instead of leaving it in a log.
  if [ -f "$O/.refresh-blocked" ]; then
    log_line "⛔ MERGE-ONLY: dispatch provisioning is BLOCKED — no implementation lane will be dispatched"
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
    log_line "⛔ CACHE BOUND NOT ENFORCED — the package-cache reaper's last pass:"
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
    log_line "⛔ DISK REAPER NOT INSTALLED — no disk-reaper.sh found (\$DISK_REAPER, \$HOME/.pi/agent/scripts, beside this script); the uv caches, dead lane venvs and merged worktrees are unbounded"
  else
    _drs="$(bash "$_dr" --print-status 2>/dev/null)"; _drc=$?
    _dst="$(printf '%s\n' "$_drs" | sed -n 's/^status=//p' | head -1)"
    _det="$(printf '%s\n' "$_drs" | sed -n 's/^detail=//p' | head -1)"
    if [ "$_drc" -eq 0 ]; then
            # ⛔ THE UNIT IS CONDITIONAL. A per-class field may read `unmeasured` (df could not answer),
            # and the old format appended a hardcoded MB to it — `uv=unmeasuredMB` reads as a byte count
            # to every consumer. Numeric values keep their unit; the sentinel is printed as it stands.
            _dr_mb() { case "${1:-}" in ''|*[!0-9]*) printf '%s' "${1:-?}" ;; *) printf '%sMB' "$1" ;; esac; }
            log_line "disk reaper: last pass $(printf '%s\n' "$_drs" | sed -n 's/^iso=//p' | head -1) ($(printf '%s\n' "$_drs" | sed -n 's/^age_seconds=//p' | head -1)s ago) mode=$(printf '%s\n' "$_drs" | sed -n 's/^mode=//p' | head -1) freed $(_dr_mb "$(printf '%s\n' "$_drs" | sed -n 's/^freed_mb=//p' | head -1)") (uv=$(_dr_mb "$(printf '%s\n' "$_drs" | sed -n 's/^freed_mb_uv=//p' | head -1)") venv=$(_dr_mb "$(printf '%s\n' "$_drs" | sed -n 's/^freed_mb_venv=//p' | head -1)") worktree=$(_dr_mb "$(printf '%s\n' "$_drs" | sed -n 's/^freed_mb_worktree=//p' | head -1)"))"
    elif [ "$_dst" = "never" ]; then
      log_line "⛔ DISK REAPER HAS NEVER RUN — installed but no pass recorded ($_det); start it: sudo systemctl start eldato-disk-reaper.service (Linux) / launchctl kickstart gui/$(id -u)/com.eldato.disk-reaper (macOS)"
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
      log_line "⏸ DISK REAPER DEFERRED — status=failed rc=6 last=$(printf '%s\n' "$_drs" | sed -n 's/^iso=//p' | head -1) (${_dage}s ago): ${_det:-no detail} (a delegate declined; nothing was claimed)"
      log_line "    per class: uv=$(printf '%s\n' "$_drs" | sed -n 's/^verdict_uv=//p' | head -1) venv=$(printf '%s\n' "$_drs" | sed -n 's/^verdict_venv=//p' | head -1) worktree=$(printf '%s\n' "$_drs" | sed -n 's/^verdict_worktree=//p' | head -1)"
    else
      log_line "⛔ DISK REAPER NOT HEALTHY — status=${_dst:-unknown} rc=$(printf '%s\n' "$_drs" | sed -n 's/^rc=//p' | head -1) last=$(printf '%s\n' "$_drs" | sed -n 's/^iso=//p' | head -1): ${_det:-no detail}"
      log_line "    per class: uv=$(printf '%s\n' "$_drs" | sed -n 's/^verdict_uv=//p' | head -1) venv=$(printf '%s\n' "$_drs" | sed -n 's/^verdict_venv=//p' | head -1) worktree=$(printf '%s\n' "$_drs" | sed -n 's/^verdict_worktree=//p' | head -1)"
    fi
  fi
  # the loop's own view of itself
  tail -3 "$O/logs/orch-loop.log" 2>/dev/null | sed 's/^/  /' || log_line "  (no orch-loop.log yet)"
  # ⛔ NOT `tmux ls | grep -c '^lane-'`: where the cmux daemon answers a cell's lanes are durable
  # terminals, so that answered 0 for a busy box. (The `grep -c` form is SIGPIPE-safe — it consumes all
  # input — but it is still the wrong SOURCE: where the launcher is tmux (#2210) it lists only that
  # surface, and the census is the one read that is right on both.) An unreadable census prints
  # UNKNOWN, never 0.
  log_line "lanes: $(worker_census 2>/dev/null || echo UNKNOWN)"
  # agent-infra#1989: CONFIGURED vs RAN. Each role's own last-pass record is printed, and a started
  # cell whose role never ran / went stale fails this verb — the issue's validation requirement, and
  # the fix for the measured "a dead loop looks identical to an idle cell".
  local d rl rrc=0
  if d="$(doctor_path)"; then
    rl="$(CELL_HOME="$CELL_HOME" O="$O" REPO="$REPO" OR="$OR" SESSION="$SESSION" bash "$d" status 2>&1)"
    rrc=$?
    printf '%s\n' "$rl" | sed 's/^/  /'
  else
    log_line "  roles: UNKNOWN — cloud-cell-doctor.sh not found (run: $0 apply)"
    [ -f "$ROLES_DIR/.desired" ] && rrc=1
  fi
  return "$rrc"
}

cmd_logs() { tail -30 "$O/logs/orch-loop.log" 2>/dev/null || log_line "no log yet at $O/logs/orch-loop.log"; }

# ── the cell doctor's roles (agent-infra#1989) ──────────────────────────────────────────────────
# `cloud-cell-doctor.sh` owns the passes; this file owns the launch and the report. The seeded copy
# in $O is preferred because $O is what the harness provenance record describes (cmd_check pins the
# payload hash), and falling back to the copy beside this supervisor keeps `doctor`/`merge`/`reap`
# usable on a cell that has not been started yet.
doctor_path() {
  local c
  # ⛔ THE PINNED HARNESS IS CONSULTED TOO (#2306). $O is the seed and stays first — it is what the
  # provenance record describes — but a cell whose $O seed is incomplete while the harness it is
  # actually running still ships the doctor must not be told the doctor "does not exist": the file was
  # measured present in the pinned harness dir while this lookup answered not-found.
  for c in "$O/cloud-cell-doctor.sh" "$(dirname "$SUP_SELF")/orchestrator-harness/cloud-cell-doctor.sh" \
           "$(dirname "$SUP_SELF")/cloud-cell-doctor.sh" \
           "${HARNESS:-}/scripts/orchestrator-harness/cloud-cell-doctor.sh" \
           "${HARNESS_PIN_DIR:-}/scripts/orchestrator-harness/cloud-cell-doctor.sh"; do
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
  local d _lrc=0 _launch_err _why _i
  mkdir -p "$ROLES_DIR" "$O/logs" || die "cannot create $ROLES_DIR"
  : > "$ROLES_DIR/.desired" || die "cannot record the desired running state at $ROLES_DIR/.desired"
  # ⛔ AN ABSENT DOCTOR IS #2211's POPULATION AND KEEPS ITS RULING: a retired/absent doctor must not
  # take the CONTROLLER down with it, so this is a NAMED warning and rc 0. A PRESENT doctor that fails
  # to LAUNCH is a different fact entirely and must never be reported this way (#2306).
  if ! d="$(doctor_path)"; then
    log_line "warning: the doctor is not shipped (cloud-cell-doctor.sh absent — #2160 retired the forks, and no copy was found in $O, beside $SUP_SELF, or in the pinned harness) — the controller runs, but reaping/hygiene/merge is NOT automatic; read $O/logs/cell-doctor.log"
    return 0
  fi
  if tmux has-session -t "=$DOCTOR_SESSION" 2>/dev/null; then
    # ⛔ A DOCTOR SESSION NAME IS MACHINE-SCOPED (`cell-doctor` is the default for EVERY cell on a
    # box), so "a session with this name exists" is not evidence that it is OURS — the same hazard the
    # controller's shared `SESSION` branch resolves, one layer out. Blessing a foreign session would
    # leave this cell with no doctor at all (its reap/merge/hygiene roles silently never run) while
    # `start` printed "already running".
    if sup_loop_alive; then
      log_line "doctor loop already running (tmux '$DOCTOR_SESSION', pid $(cat "$ROLES_DIR/loop.pid" 2>/dev/null))"
      return 0
    fi
    if doctor_session_foreign; then
      die "doctor session '$DOCTOR_SESSION' belongs to another state dir ($(doctor_session_state_dir || true)) — a session name is shared across cells, so it is not evidence that $OR has a doctor. FIX: tmux kill-session -t '$DOCTOR_SESSION' (that ends the OTHER cell's doctor; its own supervisor/start re-creates it), or pin a distinct DOCTOR_SESSION for $OR in $ENV_FILE"
    fi
    # Ours-but-stale (its loop record is gone) or unprovable: replacing it is the heal `start` exists
    # for, and the alternative — reporting "already running" — would leave this cell with no doctor at
    # all while printing success.
    log_line "doctor session '$DOCTOR_SESSION' has no live loop record — replacing it with a fresh loop"
    tmux kill-session -t "=$DOCTOR_SESSION" 2>/dev/null || true
  fi
  # ⛔ A LIVE LOOP RECORD COUNTS AS RUNNING even with no session. After a tmux server restart the
  # session is gone while the loop survives as an orphan — the state `cmd_stop`'s own note calls the
  # likeliest one. That orphan's next pass sees the controller session absent and calls
  # `supervisor start`; a session-only idempotency check would create a SECOND loop, which overwrites
  # `loop.pid` and hides the orphan from `stop`/`status` (and every later `start` adds another).
  if sup_loop_alive; then
    log_line "doctor loop already running (pid $(cat "$ROLES_DIR/loop.pid" 2>/dev/null) — no tmux session, likely a tmux server restart)"
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
  _launch_err="$O/logs/.cell-doctor-launch.$$"
  : > "$_launch_err" 2>/dev/null || _launch_err=/dev/null
  # ⛔ AND ORCH_FOREGROUND MUST NOT REACH THE DOCTOR (review P1, #2402). A tmux session is served from
  # the SERVER's environment (this file documents that twice above), and on a service-managed cell the
  # SERVER is first started by the unit's own `start`, which carries ORCH_FOREGROUND=1. Inherited here,
  # the doctor's restart (`run_doctor` → `$SUPERVISOR start`) would take the FOREGROUND branch and `exec`
  # the loop inside the doctor's tmux session — outside the unit's cgroup, with the start fence killing
  # it at CONTROLLER_START_TIMEOUT. Pin it to 0 for the loop and everything it launches.
  # ⛔ AND IT IS `export`ED, not merely assigned (review P2, #2402). A bare `ORCH_FOREGROUND=0` works only
  # by two accidents: when the value came in EXPORTED (the case this pin exists for) bash keeps the export
  # attribute, and when it did not, the child reads its own `:-0` default. Neither is the pin — the first
  # re-arms the very inheritance the paragraph above says must not reach the doctor, the second is a no-op.
  # An explicit export makes the guarantee the child actually needs.
  _launch_err="$O/logs/.cell-doctor-launch.$$"
  : > "$_launch_err" 2>/dev/null || _launch_err=/dev/null
  tmux new-session -d -s "$DOCTOR_SESSION" -c "$HARNESS" \
    "set -a; [ ! -f '$ENV_FILE' ] || . '$ENV_FILE'; set +a; export ORCH_FOREGROUND=0; unset GH_REPO; HOME='$CELL_HOME' CELL_HOME='$CELL_HOME' O='$O' REPO='$REPO' OR='$OR' SESSION='$SESSION' SCOPE='$SCOPE' ENV_FILE='$ENV_FILE' DOCTOR_SESSION='$DOCTOR_SESSION' HARNESS_REPO='$HARNESS_REPO' HARNESS_REF='$HARNESS_REF' HARNESS_PIN_DIR='$HARNESS_PIN_DIR' HARNESS_PIN_FILE='$HARNESS_PIN_FILE' MIN_FREE_MB='$MIN_FREE_MB' DOCTOR_SUPERVISOR='$SUP_SELF' bash '$d' loop 2>&1 | tee -a '$O/logs/cell-doctor.log'" \
    2>"$_launch_err" || _lrc=$?
  # ⛔ A FLAT `sleep 2` WAS A GUESS AT HOW LONG TMUX NEEDS, AND IT DISCARDED THE EVIDENCE (#2306):
  # `new-session`'s rc and stderr were dropped, so the only signal left was "a session appeared", and
  # its absence was blamed on a retired artifact. Poll the same wall time instead, and keep the file.
  _i=0
  while [ "$_i" -lt 20 ]; do
    tmux has-session -t "=$DOCTOR_SESSION" 2>/dev/null && break
    sleep 0.1
    _i=$((_i + 1))
  done
  # ⛔ ONE OBSERVATION IS NOT "STARTED" (#2306 review): the old flat `sleep 2` gave a doctor that died
  # on its first line time to disappear before the check, and the poll above breaks on the FIRST
  # sighting — so an unrunnable seed would be reported started. Require the session to still be there
  # after the launch settles: strictly stronger than before, and the same total wall time.
  if tmux has-session -t "=$DOCTOR_SESSION" 2>/dev/null; then
    sleep 0.5
    if ! tmux has-session -t "=$DOCTOR_SESSION" 2>/dev/null; then
      log_line "FATAL: the doctor session came up and then EXITED (tmux '$DOCTOR_SESSION', doctor $d) —" >&2
      log_line "       no role is scheduling. Read $O/logs/cell-doctor.log${_why:+ (tmux said: ${_why% })}" >&2
      [ "$_launch_err" = /dev/null ] || rm -f "$_launch_err"
      return 1
    fi
    log_line "doctor loop started (tmux '$DOCTOR_SESSION', doctor $d)"
    [ "$_launch_err" = /dev/null ] || rm -f "$_launch_err"
  else
    # ⛔ THE MESSAGE IS DECIDED BY THE FILE, NOT BY THE SESSION (#2306). This branch used to print
    # "cloud-cell-doctor.sh not shipped" — comment and all — for ANY failed launch, including one
    # where `doctor_path` had succeeded two lines above (it would have warned otherwise). Measured on
    # pi-cell-4: the file was at $O/cloud-cell-doctor.sh the whole time, `tmux new-session` had printed
    # "server exited unexpectedly" into a discarded stderr, and `start` returned 0 — so the operator
    # was told a false cause for a real failure. A present doctor that will not launch is FATAL for
    # this verb: the controller is up, but reap/merge/hygiene will never run.
    _why="$(head -3 "$_launch_err" 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g')"
    [ "$_launch_err" = /dev/null ] || rm -f "$_launch_err"
    log_line "FATAL: the doctor loop did NOT start (tmux new-session rc=${_lrc:-0}${_why:+: ${_why% }})" >&2
    if [ ! -s "$d" ]; then
      # A file that exists but is EMPTY is neither absent nor a launch failure (#2306 review): it is a
      # seed killed mid-write or a full disk, and the remedy is a re-seed, not a retry.
      log_line "       $d is present but EMPTY — a copy killed mid-write or a full disk, which is worse than" >&2
      log_line "       absent. Re-seed it: $0 apply" >&2
      return 1
    fi
    log_line "       the doctor IS present at $d — this is a LAUNCH failure, NOT a retired artifact (#2160" >&2
    log_line "       retired the forks; the doctor survived). The controller is up but reap/merge/hygiene" >&2
    log_line "       are NOT automatic until a doctor loop runs. Read $O/logs/cell-doctor.log, then retry:" >&2
    log_line "       $0 start   (replacing a stale session: tmux kill-session -t '=$DOCTOR_SESSION')" >&2
    return 1
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
    log_line "harness PINNED: ${before_c:0:12}${before_c:+ → }${HARNESS_COMMIT:0:12} (${HARNESS_REL})${HARNESS_APPLIED:+ [$HARNESS_APPLIED]}"
    log_line "  path:   $HARNESS"
    log_line "  ref:    $HARNESS_REF in $HARNESS_REPO"
    log_line "  record: $HARNESS_PIN_FILE (seed NOT updated: 'start' re-seeds \$O from this pin, so running code never mixes two harness commits)"
    return 0
  fi
  seed_and_stamp
  log_line "harness applied: ${before_c:0:12}${before_c:+ → }${HARNESS_COMMIT:0:12} (${HARNESS_REL})${HARNESS_APPLIED:+ [$HARNESS_APPLIED]}"
  log_line "  path:   $HARNESS"
  log_line "  ref:    $HARNESS_REF in $HARNESS_REPO"
  log_line "  record: $STAMP"
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
    log_line "prune: warn: reap-lane-venvs.sh not found (harness \$HARNESS, ~/.pi/agent/scripts, \$AGENT_INFRA_PATH) — every worktree .venv is KEPT. A blind rm here would delete a live lane's env; that is what #1932 removed."
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
    4) log_line "prune: warn: a lane-venv removal did not complete (rc=4) — either it was proven dead and the delete FAILED (see the reaper's REMOVE-FAILED lines), or a removal-time re-probe failed closed and the env was KEPT (see FAIL-CLOSED); the reaper's own log says which" ;;
    5) log_line "prune: warn: free disk is BELOW REAP_VENV_FREE_FLOOR_MB after the lane-venv pass — the reap completed, but a lane starting now can fill the disk (rc=5; see the reaper's capacity line)" ;;
    *) log_line "prune: warn: the lane-venv reaper exited $rc — any env it could not prove dead was kept (it fails closed)" ;;
  esac
  mb_after="$(free_mb "$CELL_HOME")"
  [ -n "$mb_before" ] && [ -n "$mb_after" ] && log_line "prune: lane venvs: free ${mb_before}MB → ${mb_after}MB"
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
  if rm -rf "$1" 2>/dev/null; then log_line "prune: -${mb:-?}MB $1"; else log_line "warn: could not remove $1"; fi
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
    log_line "warn: pi-cache-reap.sh not found (looked beside this script and in \$HOME/.pi/agent/scripts) — the machine-global uv/npm/pip caches were NOT bounded. Farm it: bash pi-bootstrap/setup.sh"
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
  [ "$rc" -eq 0 ] || [ "$rc" -eq 4 ] || [ "$rc" -eq 5 ] || [ "$rc" -eq 7 ] || log_line "warn: the cache reaper exited $rc — see ${CACHE_REAP_LOG:-$HOME/.pi/agent/state/pi-cache-reap.log}"
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

# ⛔ THE CALLER'S PER-ROOT EXCLUSION (agent-infra#2573) — an EXCLUSION list, never an INCLUSION one.
# The doctor's hygiene role can prove, PER WORKTREE ROOT, whether a live process is sitting in it
# (the shipped `orchestrator-harness/live-ownership.sh` cwd census), so it excludes exactly the roots
# a worker is in and lets the rest be swept. An INCLUSION list ("sweep only these") would silently
# drop every root the caller did not enumerate — including $HARNESS_REPO's, which the doctor does not
# even know about — so the sweep would lose coverage while still reporting success. Newline-separated
# (a path can contain spaces), canonicalised at COMPARE time so a symlinked spelling cannot slip
# past, and matched as a PATH PREFIX in ONE direction only (#2573 review, P1):
#   * a held root is excluded EXACTLY, and
#   * every ANCESTOR of it is excluded too — `sweep_root_caches` at an ancestor runs
#     `find -maxdepth 5 -name __pycache__`, which reaches INTO the held worktree.
# ⛔ The prefix must NOT run the other way. `case "$root" in "$cand"/*)` would make one held root
# exclude every SIBLING under it — and on the fleet layout (`<repo>/.worktrees/<lane>`) a single live
# lane holds `<repo>`, so ALL other lanes' roots would be skipped while the caller reported N roots
# swept. That is the same self-disable shape #2573 exists to remove, one level down; measured
# 2026-10-19 on the two-worktree fixture.
EXCLUDE_ROOTS=""
root_excluded() { # <root> -> 0 when the caller proved a LIVE process holds it
  local root cand
  [ -n "${EXCLUDE_ROOTS:-}" ] || return 1
  root="$(cd "$1" 2>/dev/null && pwd -P)" || return 1   # unresolvable: nothing of ours to spare
  [ "$root" != "/" ] || return 1
  while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    # A root that no longer exists cannot be held by anything: nothing to exclude (and nothing to
    # sweep either — `sweep_root_caches` skips a missing root).
    cand="$(cd "$cand" 2>/dev/null && pwd -P)" || continue
    [ "$root" = "$cand" ] && return 0
    # The held path protects itself and the roots whose sweep would recurse INTO it — never its
    # siblings (see the header).
    case "$cand" in "$root"/*) return 0 ;; esac
  done <<< "$EXCLUDE_ROOTS"
  return 1
}

exclude_root_add() { # <absolute path>
  if [ -n "${EXCLUDE_ROOTS:-}" ]; then EXCLUDE_ROOTS="$EXCLUDE_ROOTS"$'\n'"$1"; else EXCLUDE_ROOTS="$1"; fi
}

cmd_prune() {
  local caches_only=0 do_scratch=0 days="$SCRATCH_DAYS" a
  EXCLUDE_ROOTS=""
  for a in "$@"; do
    case "$a" in
      --caches) caches_only=1 ;;
      --exclude-root=*) case "${a#*=}" in
                          /*) exclude_root_add "${a#*=}" ;;
                          *) die "prune: --exclude-root needs an ABSOLUTE path (got '${a#*=}'): a relative one would be resolved against whatever directory the caller happened to be in" ;;
                        esac ;;
      --scratch) do_scratch=1 ;;
      --scratch=*) do_scratch=1; days="${a#*=}" ;;
      *) die "usage: $0 prune [--caches] [--exclude-root=PATH]… [--scratch[=DAYS]]" ;;
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
    # whose only other entries are `.DS_Store`/`._*` regular files or the harness's OWN named records —
    # see its header for the whole allow-list).
    assert_pin_dir_safe "$HARNESS_PIN_DIR"
    if linked_worktree_of "$HARNESS_REPO" "$HARNESS_PIN_DIR"; then
      # The legacy FLAT PIN: the root IS the live worktree, so `"$HARNESS_PIN_DIR"/*/` would enumerate
      # the harness's OWN source directories and reclaim them. There are no superseded siblings here.
      log_line "prune: HARNESS_PIN_DIR is a single worktree — no superseded pins to reclaim"
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
          2) log_line "prune: NOT reclaiming $d — cannot VERIFY it is a pin: ${PIN_OWNED_ERR:-HARNESS_REPO is unresolved or not a git checkout}. Fix HARNESS_REPO (or the object store), then re-run '$0 prune'"
             continue ;;
          *) log_line "prune: NOT reclaiming $d — its name does not resolve to a commit in ${HARNESS_REPO:-<unresolved>}, so it is not provably a pin of ours"
             continue ;;
        esac
        log_line "prune: reclaiming superseded harness pin $d"
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
  tmux has-session -t "$SESSION" 2>/dev/null && log_line "warn: a controller is running — a pruned venv makes the lane using it re-resolve its deps"
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
    while IFS= read -r root; do
      # ⛔ A HELD ROOT IS NAMED, NOT SILENTLY DROPPED. The caller excluded it because a live process
      # has a cwd inside it; a skip nobody can see is the same defect as the clamp this replaces
      # (the doctor declining to reclaim precisely when the box is busiest).
      if root_excluded "$root"; then
        log_line "prune: caches NOT swept at $root — a LIVE process holds it (excluded by the caller, agent-infra#2573)"
        continue
      fi
      sweep_root_caches "$root"
    done \
      < <(git -C "$r" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print substr($0,10)}')
    if root_excluded "$r"; then
      log_line "prune: caches NOT swept at $r — a LIVE process holds it (excluded by the caller, agent-infra#2573)"
    else
      sweep_root_caches "$r"
    fi
  done
  reap_global_caches
  [ "$caches_only" = 1 ] && { after="$(free_mb "$CELL_HOME")"; [ -n "$before" ] && [ -n "$after" ] && log_line "prune: free ${before}MB → ${after}MB"; return 0; }
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
    log_line "prune: scratch checkouts still on disk (source — NOT deleted; use --scratch[=DAYS] to reclaim):"
    printf '%s\n' "$kept"
  fi
  [ "$freed_scratch" = 1 ] || true
  after="$(free_mb "$CELL_HOME")"
  [ -n "$before" ] && [ -n "$after" ] && log_line "prune: free ${before}MB → ${after}MB"
}

case "${1:-status}" in
  capacity) cmd_capacity ;;
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
  *) log_line "usage: $0 check|start|stop|status|capacity|logs|apply|prune|doctor|merge|reap|hygiene"; exit 2 ;;
esac
