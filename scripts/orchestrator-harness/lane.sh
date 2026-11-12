#!/usr/bin/env bash
# Runs ONE lane's pi inside its own worktree (cwd must already be the worktree).
#   lane.sh [--repo-dir <checkout>] [--repo <owner/name>] <issue> <branch> [<owner/name>]
#
# ⛔ THE TARGET REPO IS AN ARGUMENT, AND IT IS ASSERTED (agent-infra#2724/#2694). The positional
# `<owner/name>` is the legacy spelling; `--repo` and `--repo-dir` are the explicit ones. There is NO
# default: a lane with no target REFUSES (reason=no-target) rather than guessing from the brief.
# After the worktree exists (this cwd) the lane reads its OWN origin and checkout identity and
# refuses to start when they are not the target — a lattice of pre-build checks can only prove what
# was asked for. A refusal is exit 72 and is logged as one `[repo-target]` line naming the repo, the
# worktree and the result, so a wrong-repo lane is a grep rather than an investigation.
set -u
N=""; BR=""; OR=""; _or_pos=""; _lt_pos=0
# ⛔ THE KEY GATE'S ESCAPE IS **ARGV**, NEVER AN ENVIRONMENT VARIABLE (review, P1, measured 2026-11-04).
# The first cut of the escape was `LANE_KEY_GATE=0` read from this process's environment, and the previous
# commit tried to fence it by restoring the value CAPTURED BEFORE `lane-env.sh` sourced the box's file.
# That fence closes only the DIRECT route: on a cell the controller itself was started by
# `cloud-cell-supervisor.sh`, which does `set -a; . "$ENV_FILE"; set +a` (`:633`) — so a value in the box's
# `keys.env` arrives at this process as ORDINARY INHERITED ENVIRONMENT, indistinguishable from a dispatch
# that meant it, and the "dispatch-owned" restore faithfully re-applied it. Measured: with
# `export LANE_KEY_GATE=0` in the box's `keys.env`, a key-less lane ran to `outcome=done reason=agent-exit-0`
# — the silent death this issue exists to remove, re-openable with every check green.
# ⛔ NO ENVIRONMENT CAN INJECT AN ARGUMENT. That is the whole reason the switch moved here: argv is
# constructed by the caller's command line, not inherited by every descendant, so a fixture (or an
# operator debugging one) can turn the assertion off for ONE invocation and a box cannot turn it off for
# every lane it will ever dispatch. Nothing reads `LANE_KEY_GATE` any more; setting it is reported and
# IGNORED, so an operator whose habit it was gets a line rather than a silent change of behaviour.
KEY_GATE_ESCAPE=0
LANE_REPO_DIR=""; LANE_REPO_SLUG=""
while [ $# -gt 0 ]; do
  case "${1:-}" in
    --repo-dir)
      [ $# -ge 2 ] || { echo "[lane] refusing: --repo-dir needs a checkout path" >&2; exit 78; }
      LANE_REPO_DIR="$2"; shift 2 ;;
    --repo)
      [ $# -ge 2 ] || { echo "[lane] refusing: --repo needs an owner/name slug" >&2; exit 78; }
      LANE_REPO_SLUG="$2"; shift 2 ;;
    --key-gate-off)
      # The DECLARED escape, for a fixture that STUBS `pi` (so the credential is not what it measures).
      # It is argv-only on purpose: see the block at the top of this file.
      KEY_GATE_ESCAPE=1; shift ;;
    --)
      shift
      while [ $# -gt 0 ]; do
        _lt_pos=$((_lt_pos + 1))
        [ "$_lt_pos" -le 3 ] || { echo "[lane] refusing: too many positional arguments (expected <issue> <branch> [<owner/name>])" >&2; exit 78; }
        case "$_lt_pos" in 1) N="$1" ;; 2) BR="$1" ;; 3) _or_pos="$1" ;; esac
        shift
      done ;;
    -*) echo "[lane] refusing unknown option: $1" >&2; exit 78 ;;
    *)
      _lt_pos=$((_lt_pos + 1))
      [ "$_lt_pos" -le 3 ] || { echo "[lane] refusing: too many positional arguments (expected <issue> <branch> [<owner/name>])" >&2; exit 78; }
      case "$_lt_pos" in 1) N="$1" ;; 2) BR="$1" ;; 3) _or_pos="$1" ;; esac
      shift ;;
  esac
done
# A flag and a positional that disagree are a contradiction in the dispatch itself — refuse rather
# than let one silently win.
if [ -n "$LANE_REPO_SLUG" ] && [ -n "$_or_pos" ] && [ "$LANE_REPO_SLUG" != "$_or_pos" ]; then
  echo "[lane] refusing: --repo '$LANE_REPO_SLUG' contradicts the positional target '$_or_pos'" >&2
  exit 72
fi
OR="${LANE_REPO_SLUG:-$_or_pos}"
# Validate the two values every artifact below is built from. lane.sh is also invoked by hand, and
# `$N=../../x` would build a path outside $O/state (the same reason its capacity record is screened).
case "${N:-}" in
  ''|*[!0-9]*) echo "[lane] refusing non-numeric issue id: ${N:-<empty>}" >&2; exit 78 ;;
esac
[ -n "${BR:-}" ] || { echo "[lane] refusing: no branch named" >&2; exit 78; }
# ⛔ EXPORTED, not just set: the SPAWN POINT (`pi` itself, agent-infra#1884) is a CHILD process, and a
# shell variable it cannot see makes its refusal say "untagged" about the very item it just refused.
# An operator reading "[pi-gate] REFUSED … item NOT started: <x>" must be able to name the lane.
KIND=lane; TAG="$N"; export KIND TAG
# `$O/state` joins `$O/logs`: the capacity-transfer ledger (agent-infra#1909) lives there.
O="${O:-$HOME/orchestrator}"; mkdir -p "$O/logs" "$O/state"
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
# ⛔ THE gh SHIM MUST STAY FIRST (#1988). The line above prepends the tool dirs, so a REAL gh in
# either of them outranks the seeded `$O/gh-rest` (Mac REST adapter) / `$O/gh-limit` (cell
# serialiser) — and a shim that is never resolved is an INERT layer: it reports protection and
# provides none. Re-assert both here, adapter last so `$O/gh-rest` (which itself calls the same
# helper) wins where it exists. Guarded by `-d`, so a box that ships neither is unchanged.
# ⛔ AND THE ROOTS ARE TWO NAMES NOW (#2095; review of #3846). `O` is the controller's STATE dir and
# `O_WORK` is the harness root, so on an `ORC_STATE_DIR`/isolated instance the seeded adapters live
# under the WORK root — reading `$O` here would leave a lane unthrottled and without the REST adapter
# while every gate reports the layer present.
if [ -d "${O_WORK:-$O}/gh-limit" ]; then PATH="${O_WORK:-$O}/gh-limit:$PATH"; fi
if [ -d "${O_WORK:-$O}/gh-rest" ]; then PATH="${O_WORK:-$O}/gh-rest:$PATH"; fi
# ── THE TERMINAL LINE: EVERY LANE LOG ENDS BY SAYING WHAT HAPPENED (agent-infra#3331) ─────────────
# Measured 2026-11-02 on two cells: a lane's log simply STOPPED, and the dispatch record still said
# "launched". A print-mode `pi` buffers, so a log that ends silently is indistinguishable from a lane
# that is still working — and `pgrep -f "pi -p"` matched the diagnostic's own command line on top of it.
# So the ONE line an operator (or a scanner) reads to know a lane ended is written by a TRAP, which is
# the only construction that fires on EVERY exit a shell can trap: a normal end, a pre-flight refusal, a
# failing agent, a `set -u` abort, and (through the explicit handlers below) a `TERM`/`INT`/`HUP`.
# ⛔ THE UNTRAPPED EXITS, stated so nobody reads the sentence above as a guarantee: `SIGKILL` (the OOM
# killer), `exec`, and a kill that lands while `lane_exit_cleanup` runs (the TERM→KILL grace is 15 s)
# write NO line. An absent line is therefore not proof of a pre-#3331 box — see README's terminal-line
# section, which names all three causes and the artifact that tells them apart.
#
# THE CONTRACT — one physical line, PER RUN, last in `$O/logs/lane-<N>.log`:
#     outcome=<done|refused|failed|died> reason=<token> lane=<N> rc=<status> utc=<timestamp>
# ⛔ PER RUN, AND THE READ MUST BE RUN-SCOPED (review round 4/5, P2, measured). The lane log is
# APPEND-ONLY (`tee -a` / `>>`, nothing truncates it), so a re-dispatched issue leaves the PREVIOUS
# attempt's terminal line in the same file — and `grep '^outcome=' | tail -1` then answers "this lane has
# ended" with the EARLIER run's verdict while the current one is still working. That is the stale-flag
# class, in the very artifact shipped to answer "did this lane run". So the line is also written to a
# PER-RUN sibling that the next dispatch REMOVES before it starts: its ABSENCE means "no verdict for the
# current run" (still working, or never started), never a previous verdict.
# ⛔ REMOVING IS NOT ENOUGH ON ITS OWN (review round 5, P2): a previous run of the same issue can still be
# ALIVE (the stuck-lane shape this issue is about) and would overwrite the file with ITS verdict when its
# own trap fires. So each dispatch also stamps an OWNER token, and the trap writes the per-run file only
# while the token still names this process: the older run's line goes to the append-only log (its
# transcript) and cannot be mistaken for the current run's verdict.
#   the verdict of the current run:  cat "$O/logs/lane-<N>.outcome"      (absent = no verdict yet)
#   which lane logs never said anything, any run:
#       grep -L '^outcome=\(done\|refused\|failed\|died\) reason=' "$O"/logs/lane-[0-9]*.log
#   ⛔ THE PATTERN IS ANCHORED (review cycle 3, P2, measured): this line used to say a bare
#   `grep -L '^outcome='`, and that form counts a lane as REPORTED whenever ANY line in the file starts
#   with `outcome=` — including the agent transcript (`run_agent` appends pi's stdout to the same log) and
#   including the CONTRACT LINE this comment is part of, which a lane editing `lane.sh` will quote. Measured
#   on a dead lane whose transcript carries that quote: bare form → nothing listed (false pass), anchored
#   form → the lane listed. The README states the same rule and the end-scoped per-file form; this is the
#   containment reader and it must use the same pattern, because two artifacts answering one question with
#   different commands is how the wrong one gets run during an incident.
#   ⛔ `lane-[0-9]*` IS NOT COSMETIC (review round 2, P2, measured): `lane-*.log` ALSO matches
#   `lane-merge-<PR>.log`, which `lane-merge.sh` writes and which is NOT a lane (`merge-rate.sh` excludes
#   it by name for exactly that reason). Lane logs are `<issue>.log`, and `$N` is validated numeric above.
# ⛔ `reason` is a TOKEN, never prose: this line is read by instruments, and a free-text field is the
# field that re-stales. The long-form reason stays in the log's own `[lane N] NOT started: …` lines.
# ⛔ IT IS INSTALLED THIS EARLY ON PURPOSE. Every exit AFTER the log path exists gets the line,
# including the `78`s that refuse a half-synced `$O` before a single gate runs — those are exactly the
# lanes that vanished with nothing said. The exits ABOVE this point are argument validation (78/64),
# where no lane log exists yet and there is nothing to append to.
# ⛔ THE HANDOVER ORDER IS STAMP-THEN-REMOVE, AND THAT IS THE FIX (review round 6, P2, measured): the first
# cut removed the verdict file and THEN stamped the owner token, so a previous run whose trap fired in that
# window still matched its own (old) token and wrote ITS verdict back — and the new dispatch, having already
# removed the file, then stamped a token without clearing it. Readers saw the old run's verdict as the current
# one: the stale-flag failure this mechanism exists to close, surviving in the dispatch order rather than in
# the trap. Stamping first means any older trap that fires during the handover already fails the comparison.
LANE_RUN_TOKEN="${N:-0}.$$.$(date +%s 2>/dev/null || printf 0)"
printf '%s\n' "$LANE_RUN_TOKEN" > "$O/logs/lane-$N.owner" 2>/dev/null || true
rm -f "$O/logs/lane-$N.outcome" 2>/dev/null || true
LANE_OUTCOME=""; LANE_OUTCOME_REASON=""; LANE_TERMINAL_DONE=0; LANE_LAST_STATUS=0
lane_outcome() { # <done|refused|failed|died> <reason-token>  — FIRST writer wins
  [ -n "${LANE_OUTCOME:-}" ] && return 0
  case "${1:-}" in
    done|refused|failed|died) LANE_OUTCOME="$1" ;;
    # An unmapped word must never be silently written as a legitimate outcome: it is a FAILURE of the
    # writer, and the line says so (a vocabulary that accepts anything records nothing).
    *) LANE_OUTCOME="failed"; LANE_OUTCOME_REASON="unmapped-outcome:${1:-<empty>}"; return 0 ;;
  esac
  LANE_OUTCOME_REASON="${2:-unknown}"
  return 0
}
lane_terminal_line() {
  [ "${LANE_TERMINAL_DONE:-0}" = "1" ] && return 0
  LANE_TERMINAL_DONE=1
  local o r line
  o="${LANE_OUTCOME:-}"; r="${LANE_OUTCOME_REASON:-}"
  if [ -z "$o" ]; then
    # Nothing recorded an outcome. A lane that reaches its end with no refusal, no agent verdict and no
    # named cause DID NOT RUN — that is the defect class this line exists to make visible, so it is
    # `died` and the exit status is the only evidence left. (A signal handler sets `died` itself.)
    o=died; r="no-outcome-recorded:exit-${LANE_LAST_STATUS:-?}"
  fi
  # Collapse anything that would break the one-line contract (a reason is a caller's string).
  r="$(printf '%s' "$r" | tr '\n\r\t' '   ')"
  line="outcome=$o reason=$r lane=$N rc=${LANE_LAST_STATUS:-?} utc=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf 'unknown')"
  # The per-run verdict (see the contract above): re-owned at dispatch, so its ABSENCE — not a stale line, and
  # not an older live run's line — is what "no verdict yet" looks like.
  # ⛔ THE DECISION IS MADE FROM WHAT THE READ AT EXIT CAN SEE, AND ONLY WHEN IT CAN SEE SOMETHING (review
  # round 7, two P2s, both measured). The earlier shapes failed in opposite directions:
  #   • gating on a dispatch-time flag meant an ABSENT/UNREADABLE `lane-<N>.owner` produced an empty read,
  #     which compared unequal and took the DENY path — so an externally cleaned `logs/` made a lane that RAN
  #     publish nothing, reading as "still working" for ever;
  #   • an unconditional fail-open on a failed stamp was unbounded in time: a run whose stamp failed could
  #     wait hours, and once a LATER dispatch had stamped its own token this run still overwrote the verdict.
  # So: deny ONLY on a non-empty token that is not ours (that is the only case where an owner is observable
  # and it is not this process). An absent/unreadable token means nothing is authoritative — (re)stamp and
  # publish, which is also how a failed dispatch-side stamp heals.
  # ⛔ STATED RESIDUAL (review P2, not fixed here): read → re-stamp → write are three steps, so a PREVIOUS
  # run whose trap read the token BEFORE the new dispatch stamped it still passes this comparison and can
  # write ITS line into the NEW run's verdict file after the dispatch's `rm`. The window is the length of a
  # trap firing mid-handover, and closing it needs an atomic compare-and-swap the shell does not offer
  # (the honest remedies are `mkdir`-lock or an flock on the owner file). The dispatch-order note above is
  # therefore true only for a trap that STARTS after the stamp — this comment is the record of that limit,
  # so the next reader does not re-derive it as a guarantee that does not exist.
  # ⛔ THE OWNER READ COMES BEFORE THE WRITE, AND THE PROSE BEFORE THE LINE (review cycle 1, P2, measured).
  # The deny arm used to append its explanation AFTER the terminal line, so on that one arm the log's LAST
  # line was prose — breaking the contract stated 50 lines above and making `tail -1` (the documented
  # single-lane read) answer "nothing was recorded" for a lane that HAD recorded its outcome. The decision
  # does not depend on the line, so computing it first costs nothing and keeps the line last in every arm.
  LANE_OWNER_NOW="$(cat "$O/logs/lane-$N.owner" 2>/dev/null || true)"
  if [ -n "$LANE_OWNER_NOW" ] && [ "$LANE_OWNER_NOW" != "${LANE_RUN_TOKEN:-}" ]; then
    echo "[lane $N] (outcome not written to logs/lane-$N.outcome: a LATER dispatch of #$N owns that file — this line is the transcript, that file is the current run's verdict)" >> "$O/logs/lane-$N.log" 2>/dev/null || true
  else
    # Re-assert ownership (best effort; a failure here cannot make the verdict wrong — the write below is what
    # a reader uses, and this run is the newest one that could not be disproved).
    printf '%s\n' "${LANE_RUN_TOKEN:-}" > "$O/logs/lane-$N.owner" 2>/dev/null || true
    printf '%s\n' "$line" > "$O/logs/lane-$N.outcome" 2>/dev/null || true
  fi
  printf '%s\n' "$line" | tee -a "$O/logs/lane-$N.log" 2>/dev/null || printf '%s\n' "$line"
  return 0
}
# The EXIT trap dispatches, so ONE trap site covers both halves as they become available: the cleanup
# is defined further down (its libraries are sourced there), and a lane that exits before that has
# nothing to clean up but still owes a terminal line.
#
# ── ONLY THE LANE'S OWN SHELL MAY RUN THIS (the two P0s a forked child causes) ─────────────────
# Bash propagates an EXIT trap into some forked children, and this script forks for real work: the
# agent launch (`pi … &`) and the watchdogs below. A child that inherits the trap does TWO things the
# lane is still relying on:
#   • it runs `lane_exit_cleanup` WHILE THE LANE IS STILL RUNNING — reaping the very `.venv` the agent
#     is executing from, and reconciling a worktree the agent is still writing to;
#   • it writes a terminal line, and `lane_terminal_line` is idempotent only WITHIN a process (its
#     `LANE_TERMINAL_DONE` flag is a shell variable a fork COPIES). So the log ends up with the
#     child's verdict AND the lane's: the reader the whole change exists to give a single authoritative
#     last line gets two, and the earlier one is a `died reason=no-outcome-recorded` that is a lie
#     about a lane that then exited 0. Measured on Linux bash 5.2: three arms of lane-outcome.test.sh
#     carried `got: '2', want: '1'` lines, with the child's `subshell=1` and the lane's `subshell=0`.
#
# `BASHPID` identifies the process exactly and is the primary test; `BASH_SUBSHELL` (bash 3.0+, so it
# exists on the macOS 3.2 this harness also runs on) is the fallback. The SUBSHELL DEPTH IS CAPTURED
# AT START rather than compared to a literal 0, so a caller that sources this file inside a subshell
# still gets its line instead of being silently denied one.
LANE_OWNER_BASHPID="${BASHPID:-}"
LANE_OWNER_SUBSHELL="${BASH_SUBSHELL:-0}"
lane_trap_is_owner_shell() {
  if [ -n "${LANE_OWNER_BASHPID:-}" ] && [ -n "${BASHPID:-}" ]; then
    [ "$BASHPID" = "$LANE_OWNER_BASHPID" ]
    return $?
  fi
  [ "${BASH_SUBSHELL:-0}" -eq "${LANE_OWNER_SUBSHELL:-0}" ]
}
lane_exit_trap() {
  LANE_LAST_STATUS=$?
  # A forked child owes the lane nothing and may harm it: see the block above. Returning here costs the
  # child nothing (its own exit status is unaffected) and leaves the lane's run untouched.
  lane_trap_is_owner_shell || return 0
  if [ "${LANE_CLEANUP_DISABLED:-0}" != "1" ] && command -v lane_exit_cleanup >/dev/null 2>&1; then
    lane_exit_cleanup
  fi
  lane_terminal_line
}
trap 'lane_exit_trap' EXIT
# The wall-clock limit AND the load gate both live in the shared helper, so this script has no
# `pi` invocation of its own to forget to gate (agent-infra#1720). Fail LOUD if the helper is
# missing: an unsourced helper would leave `run_agent` undefined, and an undefined helper must never
# degrade into "the agent ran" or "the review failed" — see README §9 on syncing $O.
# ⛔ SOURCED AFTER THE PATH EXPORT, not before it (a deliberate departure from the tortoise
# original): spawn-gate.sh derives `_NCPU` at SOURCE time via `sysctl`/`nproc`/`getconf`, so sourcing
# it under the pre-export PATH pins `_NCPU=4` and MAX_LOAD=40 for every cell — the exact #1702
# failure the portable probe exists to prevent.
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF/spawn-gate.sh" || { echo "[lane $N] FATAL: $SELF/spawn-gate.sh missing — refusing to start an ungated agent" >&2; exit 78; }
# ⛔ THE REPO-IDENTITY GATE (agent-infra#2724/#2694). Required, not optional: a lane that cannot
# prove which repository its worktree is has no business starting an agent in it. Missing helper =
# FATAL, because a silently skipped assertion is exactly the "nothing refuses" failure being fixed.
. "$SELF/repo-target.sh" || { echo "[lane $N] FATAL: $SELF/repo-target.sh missing (or its repo-slug.sh parser is) — refusing to start a lane whose repo cannot be asserted (#2724)" >&2; exit 78; }
# ⛔ NAME EVERY SYMBOL THIS FILE REACHES, TRANSITIVELY (#2762 review, 4th cycle, P2). The assert alone
# is not enough: `repo_target_head_branch` GATES the branch half (`if [ -n "$HEAD_BRANCH" ]`), so a
# module that has the assertions but not the head read made `HEAD_BRANCH` empty — the branch
# assertion was SKIPPED SILENTLY, the one direction in which this gate can be defeated (the `prfixup`
# shape this file exists to refuse). `repo_target_slug`/`repo_target_refuse` happen to fail closed;
# `head_branch` does not, so the guard has to be the whole set, not the two obvious ones.
command -v repo_target_assert >/dev/null 2>&1 && command -v repo_target_branch_assert >/dev/null 2>&1 \
  && command -v repo_target_head_branch >/dev/null 2>&1 && command -v repo_target_slug >/dev/null 2>&1 \
  && command -v repo_target_refuse >/dev/null 2>&1 && [ -n "${REPO_TARGET_REFUSED:-}" ] \
  || { echo "[lane $N] FATAL: $SELF/repo-target.sh is stale (needs repo_target_assert/repo_target_branch_assert/repo_target_head_branch/repo_target_slug/repo_target_refuse and REPO_TARGET_REFUSED) — refusing to start a lane whose repo cannot be asserted (#2724)" >&2; exit 78; }
# ── THE MODEL-CREDENTIAL GATE (agent-infra#3331) ────────────────────────────────────────
# The third member of the pre-flight family this file already carries — `brief-gate.sh` (80) and
# `repo-target.sh` (72) — and the one whose absence was measured as three silent lane deaths on two
# cells (`No API key found for the selected model.`, then a log that just stops). It is CALLED later,
# immediately before the agent is spawned (the only point at which the env it will inherit is final);
# the module is LOADED here, fail-loud, so a half-synced `$O` refuses before doing any work rather than
# discovering the missing helper at the last gate.
[ -r "$SELF/key-gate.sh" ] || { echo "[lane $N] FATAL: $SELF/key-gate.sh missing — refusing to start a lane whose model credential nothing asserts (#3331)" >&2; exit 78; }
. "$SELF/key-gate.sh" || { echo "[lane $N] FATAL: $SELF/key-gate.sh could not be sourced — refusing to start a lane whose model credential nothing asserts (#3331)" >&2; exit 78; }
command -v key_gate_assert >/dev/null 2>&1 && [ -n "${KEY_GATE_REFUSED:-}" ] \
  || { echo "[lane $N] FATAL: $SELF/key-gate.sh is stale (needs key_gate_assert and KEY_GATE_REFUSED) — refusing to start a lane whose model credential nothing asserts (#3331)" >&2; exit 78; }
# ── THE LANE'S OWN CREDENTIALS (agent-infra#3060) ───────────────────────────────────────────────────
# A lane started OUTSIDE the controller inherits no keys and dies in ~7 s with "No API key found for
# deepseek" — after passing every gate, because the capability gate sources the key file for its own probe
# call and therefore cannot see that the lane has none. The sourcing lives in lane-env.sh so it is testable
# without a worktree, a pi binary or a provider (lane-env.test.sh), and it is a TOP-LEVEL snippet on
# purpose: `. file` inside a function means something different (see that file's header for the three
# defects that produced from wrapping it). Fail LOUD if it is missing — an unsourced snippet would silently
# restore the 7-second death this exists to remove.
[ -r "$SELF/lane-env.sh" ] || { echo "[lane $N] FATAL: $SELF/lane-env.sh missing — refusing to start a lane whose credentials nothing sourced (#3060)" >&2; exit 78; }
# ⛔ THE TARGET IS AN ARGUMENT, AND SOURCING AN ENV FILE MUST NOT BE ABLE TO REPLACE IT (measured
# 2026-11-01). `keys.env` on a cell carries `export OR=<owner/name>` (it is the CONTROLLER's default,
# written for loops that mean it). Sourced here as a top-level snippet, that line silently overwrote the
# target this lane was DISPATCHED for — so `repo_target_assert` compared the worktree against the
# ENV FILE's repo, and a correct dispatch was refused with `reason=slug-mismatch` naming a repo nobody
# asked for. The gate exists because the worktree must be the repo that was ASKED FOR; an ambient `OR`
# is exactly the "default two programs invented" #1974 removed. Save the parsed target across the
# sourcing and restore it, so the argument keeps the last word.
#
# ⛔ THE WHOLE DISPATCH-OWNED SET, NOT JUST THE TARGET (review of #3174, P2). `OR` was the variable the
# refusal happened to name, but the same file can carry `export N=…`, `export BR=…`, `export O=…` or
# `export LANE_REPO_DIR=…`, and each moves something the DISPATCH decided: which issue's brief is built,
# which branch is asserted, where the lane records, and which checkout is compared. This is the class
# `scripts/pr-repair-loop.sh` already settled — "`keys.env` remains authoritative for CREDENTIALS … it
# may not move WHAT this box repairs or WHERE it records that." So the file keeps the last word on
# CREDENTIALS (PATH, tokens, DSNs — see lane-env.test.sh A6) and the dispatch keeps it on these five.
LANE_TARGET_ARG="$OR"; LANE_ISSUE_ARG="$N"; LANE_BRANCH_ARG="$BR"
LANE_REPO_DIR_ARG="$LANE_REPO_DIR"; LANE_OUT_ARG="$O"
LANE_ENV_LOG="$O/logs/lane-$N.log" LANE_ENV_LABEL="lane $N" . "$SELF/lane-env.sh"
OR="$LANE_TARGET_ARG"; N="$LANE_ISSUE_ARG"; BR="$LANE_BRANCH_ARG"
LANE_REPO_DIR="$LANE_REPO_DIR_ARG"; O="$LANE_OUT_ARG"
# ⛔ `LANE_KEY_GATE` IS **NOT** IN THIS SET, AND ITS ABSENCE IS THE POINT (review, P1). It was a sixth
# member in the previous commit and the save/restore could not work: the value reaches this process as
# INHERITED environment from the controller (which sources `keys.env` under `set -a`), so "the value the
# caller had" and "the value the box's file had" are the same string and the restore re-applies the box's.
# The switch is argv-only now (`--key-gate-off`), which no file and no parent shell can set for us. See the
# block at the top of the file. `lane-env.sh:42` records the same fact from the file's side.
unset LANE_TARGET_ARG LANE_ISSUE_ARG LANE_BRANCH_ARG LANE_REPO_DIR_ARG LANE_OUT_ARG
# ⛔ THE ADAPTERS ARE RE-PREPENDED **AFTER** THE FILE IS SOURCED, AND THAT ORDER IS THE WHOLE POINT
# (review P1, measured 2026-11-04). `lane-env.sh` gives the file the last word on credentials, PATH
# included (lane-env.test.sh A6) — but the prepends happen at :64-65, ABOVE this line, so a `keys.env`
# carrying `PATH=…` silently DISPLACED `$O/gh-rest/gh` and `$O/gh-limit`:
#     BEFORE env sourcing: <box>/o/gh-rest/gh      AFTER: /usr/bin/gh
# Every gate that measures this repo (`spawn-gate.sh`'s #2409 land-backlog read is the one that bit)
# then queries GitHub with the REAL client, bypassing the pacing adapter #1988 requires to stay first,
# and — measured on a real box — returned `41 open / 0.9 landings per hour` where the box's own adapter
# answers `0`. The file still owns the REST of PATH (its entries keep their order and reach the child);
# only the two adapter directories are pinned back in front, which is the rule :64-65 already states.
# A6 is untouched: it drives `lane-env.sh` directly and never runs this file.
# The one substitution from :83-84 is the WORK ROOT (#2095, review of #3846): `O_WORK` when the
# controller names a state dir, `$O` otherwise.
if [ -d "${O_WORK:-$O}/gh-limit" ]; then PATH="${O_WORK:-$O}/gh-limit:$PATH"; fi
if [ -d "${O_WORK:-$O}/gh-rest" ]; then PATH="${O_WORK:-$O}/gh-rest:$PATH"; fi

# ── the reviewer requirement is disclosed BEFORE the work (#2148) ───────────────────────────────────
# The ≥1-dispatch rule and the merge-registry gate are correct and both spoke ONLY at the finish line
# (measured 2026-10-19: three lanes did the whole job, then were refused at the rail). A lane's gate is
# BYPASSED here (the parent enforces review), so nothing in the lane's own session ever says the
# requirement out loud — it is therefore printed here, once, before any work, AND carried into the
# generated brief below. Fail LOUD if the helper is missing: an unsourced helper would silently drop
# both halves, and a lane that never heard the requirement is the defect this exists to remove.
. "$SELF/reviewer-preflight.sh" || { echo "[lane $N] FATAL: $SELF/reviewer-preflight.sh missing — refusing to start a lane that is never told a reviewer is mandatory (#2148)" >&2; exit 78; }
# ── the RESEARCH contract is part of the brief, not the orchestrator's memory (#2258) ───────────────
# Measured twice in one day: a lane re-derived a root the tracker already held, and a lane opened a
# DUPLICATE PR (#2247 vs #2250). Both were brief defects. The block below is the ONE canonical text
# (`brief-gate.sh --section`), spliced into the generated brief, and the brief is then CHECKED with
# that same validator before the agent starts — so a heredoc regression that loses the block refuses
# the lane with exit 78 instead of dispatching a lane nobody asked to look first. Same discipline as
# #2148's reviewer section directly above, for the same reason: a requirement that lives only in the
# dispatcher's head is invisible to the lane.
brief_gate_sh="$(brief_gate_lib)" || {
  echo "[lane $N] FATAL: brief-gate.sh not found (looked in \$O, $SELF, \$AGENT_INFRA_PATH/scripts/orchestrator-harness, ~/.pi/agent/scripts) — refusing to start a lane whose brief nothing validated (#2258)" >&2; exit 78; }
RESEARCH_BRIEF="$(bash "$brief_gate_sh" --section lane)" || {
  echo "[lane $N] FATAL: brief-gate.sh --section failed — refusing to start a lane whose brief omits the research contract (#2258)" >&2; exit 78; }
RESEARCH_PREFLIGHT="$(bash "$brief_gate_sh" --line lane)"
printf '%s\n' "$RESEARCH_PREFLIGHT" | tee -a "$O/logs/lane-$N.log"
# ── the lane's own `.venv` is reaped on the way out (agent-infra#1932) ──────────────────────────────
# A venv is a build artifact that belongs to a RUNNING lane: `uv sync` writes it inside the worktree,
# and nothing removed it, so 5 lanes held 7.3 GB (~4 lanes, not 6, on a 32 GB box). The EXIT trap is
# the right place because at lane exit the lane is KNOWN to be done — no liveness has to be inferred —
# and it covers EVERY exit path, including a TERM'd session (bash runs EXIT traps on SIGTERM: verified).
# The reaper still re-probes for a live holder before deleting, so a worktree another lane is using,
# or a `pi`/pytest child still running after the agent returned, keeps its env. Best-effort and loud:
# `reap_lane_venv` never changes the lane's exit status, and logs every outcome to the lane log.
#
# ── and the WORKTREE + BRANCH go with it when the lane produced nothing (agent-infra#2033) ────────
# This is the other half of the same trap, and it is the half that keeps the ISSUE dispatchable. A
# lane that exits with no commit, no push and a clean tree leaves a branch that is 0 commits ahead of
# origin/main — and the collision pre-flight infers "in flight" from exactly that branch, so a free
# issue becomes permanently undispatchable on every box (measured: #8090, `feat/8090-tm`, 0 ahead).
# `wt_reap_if_empty` refuses on anything that could be work (commits ahead, a pushed branch, a dirty
# tree, a live holder, an unevaluable probe), and a dirty tree is deliberately NOT reaped here: the
# backup-then-remove policy (`reaped-patches`) belongs to the reaper, not to the dying lane.
# `SELF` is the ONE from above (the harness/$O directory that also holds spawn-gate.sh) — a second
# declaration here would be harmless today and a trap the day one of them changes.
# shellcheck source=/dev/null
. "$SELF/wt-lifecycle.sh" || { echo "[lane $N] FATAL: $SELF/wt-lifecycle.sh missing — refusing to run a lane whose empty worktree could never be reclaimed (#2033)" >&2; exit 78; }
LANE_WT="$PWD"
lane_exit_cleanup() {
  [ -n "${LANE_WT:-}" ] || return 0
  reap_lane_venv "$LANE_WT" "lane $N"
  local repo
  repo="$(cd "$LANE_WT" 2>/dev/null && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || repo=""
  case "$repo" in */.git) repo="${repo%/.git}" ;; esac
  [ -n "$repo" ] || return 0
  wt_reap_if_empty "$repo" "$LANE_WT" "$BR" "lane $N" || true
  echo "[lane $N] worktree: $WT_RESULT" >> "$O/logs/lane-$N.log" 2>/dev/null || true
  return 0
}
# ⛔ THE SIGNAL TRAPS ARE LOAD-BEARING, NOT TIDINESS (measured on /bin/bash 3.2.57, 2026-10-18): a
# shell killed by SIGHUP with only an EXIT trap installed does NOT run that trap. `tmux kill-session`
# — which `dispatch-merge.sh` uses on its no-chain path, and which an operator uses by hand — delivers
# SIGHUP, so the cleanup has to be reached by an explicit handler that `exit`s. Each handler clears
# the traps on entry so the `exit` cannot re-enter it (one cleanup, one exit, status matched to the
# signal).
# ⛔ AND EACH ONE RECORDS HOW IT DIED FIRST (agent-infra#3331). The handler clears the EXIT trap, so
# nothing else will write the terminal line: `died reason=signal:<SIG>` is the lane's record that it did
# not end, it was ended — which is the fact a log that simply stops cannot carry.
lane_terminate() { # <exit-status> <signal>
  trap - EXIT INT TERM HUP
  # ⛔ THE STATUS IS RECORDED BEFORE THE LINE IS WRITTEN, and the order is the point (review P1): the
  # EXIT trap — the only other writer of `LANE_LAST_STATUS` — was just CLEARED, so a line written from
  # here would carry the initialiser and report `rc=0` beside `outcome=died`. Measured: the TERM arm's
  # terminal line said `rc=0` while the process exited 143, i.e. the one artifact that distinguishes a
  # killed lane from a clean one disagreed with the exit status, on the fleet's most common death path.
  LANE_LAST_STATUS="${1:-1}"
  lane_outcome died "signal:${2:-?}"
  if [ "${LANE_CLEANUP_DISABLED:-0}" != "1" ] && command -v lane_exit_cleanup >/dev/null 2>&1; then
    lane_exit_cleanup
  fi
  lane_terminal_line
  exit "${1:-1}"
}
trap 'lane_terminate 143 TERM' TERM
trap 'lane_terminate 130 INT' INT
trap 'lane_terminate 129 HUP' HUP
# ⛔ ONE EXIT TRAP, INSTALLED EARLY (above) AND DISPATCHING — `lane_exit_cleanup` is defined below and
# `lane_exit_trap` runs it only when it exists. Re-assigning `trap … EXIT` here would REPLACE the early
# one, and the exits between the two sites (a half-synced `$O`) would lose their terminal line.
# ⛔ ...but the CLEANUP half is DISARMED on a DRY RUN (agent-infra#2148's `LANE_DRY_RUN` seam, below).
# No agent ran, so the worktree's `.venv` has no dead holder to reap — and a preview that DELETES a build
# artifact is exactly the destructive-side-effect class a dry run exists to avoid.
# ⛔ IT DISABLES THE CLEANUP, **NOT THE TRAPS**, AND THAT IS A CORRECTION (review P2, measured). Clearing
# all four traps here left every exit between this point and the dry-run seam writing NO terminal line —
# and the arms in that window (`repo-target:REFUSED` 72, the `target-underivable` 72, the branch 72, and
# seven `78` harness refusals) already record an `outcome` that nothing then wrote out. So the one shape
# this change exists to make visible — a lane that ends without saying what happened — was preserved
# exactly where a dry run is used to debug the harness. The line is cheap and it is not a side effect;
# the reaping is, and that is the half now gated.
if [ "${LANE_DRY_RUN:-0}" = "1" ]; then
  LANE_CLEANUP_DISABLED=1
fi
# ── THE GATE DECISION IS MEASURED, NOT ASSUMED (agent-infra#2319)
# This line used to export `AGENT_SKIP_REVIEW_GATE=1 ELDATO_SKIP_VGATE=1` UNCONDITIONALLY — a permanent
# bypass the canon calls emergency-only, on the one machine that lands the most work. The decision is
# now made by `gate-policy.sh`, which probes whether the lane path can SATISFY both gates and — when it
# cannot — records an audited line naming #2319 and the missing component. When the satisfier lands the
# export disappears by itself, with no second change and no forgotten flip.
. "$SELF/gate-policy.sh" 2>/dev/null || { echo "[lane $N] FATAL: $SELF/gate-policy.sh missing — refusing to start a carrier that cannot say whether its gates are on" >&2; exit 78; }
# ⛔ A DRY RUN WRITES NOTHING TO STDERR (it runs no agent, so a warning about a worker that never
# started is noise an operator would learn to ignore — `reviewer-preflight.test.sh` asserts this). The
# DECISION is still recorded; only the human-facing line is suppressed.
[ "${LANE_DRY_RUN:-0}" = "1" ] && export GP_QUIET=1
apply_gate_policy lane
# ⛔ A DIFFERENT HATCH, DELIBERATELY UNTOUCHED: main-edits is a declared escape for writing to a main
# checkout, not a review bypass, and #2319 does not rule on it.
export AGENT_ALLOW_MAIN_EDITS=1 ELDATO_ALLOW_MAIN_EDITS=1
export PI_MCP_SERVERS=none   # headless lanes use no MCP servers — saves ~25 processes/run
export PI_SKIP_VERSION_CHECK=1 SKILL_ENFORCER_DISABLED=1 LOOP_ENFORCER_DISABLED=1 SLACK_BRIDGE_DISABLE=1 VISION_INTERCEPTOR_DISABLED=1
echo "[lane $N] cwd=$(pwd) branch=$(repo_target_head_branch "$PWD") $(date)" >> "$O/logs/lane-$N.log"
# ── THE POST-BUILD ASSERTION, BEFORE ANY LANE ARTIFACT (agent-infra#2724/#2694) ─────────────────
# The worktree exists (it is cwd). Read WHAT IT IS and refuse when it is not the target. The line is
# written to the lane log AND echoed, so it is the one grep that answers "which repo did this lane
# run in, and did anything check?". A valid target is mandatory: an absent one is a REFUSAL, not a
# default (#1974: a shipped default is a path two programs invented).
REPO_ASSERT_LINE="$(repo_target_assert "lane $N" "$PWD" "$OR" "$LANE_REPO_DIR")"; REPO_ASSERT_RC=$?
printf '%s\n' "$REPO_ASSERT_LINE" | tee -a "$O/logs/lane-$N.log"
if [ "$REPO_ASSERT_RC" -ne 0 ]; then
  echo "[lane $N] NOT started: repo-target REFUSED (exit $REPO_ASSERT_RC) — no agent, no PR, nothing measured in the wrong repository" >> "$O/logs/lane-$N.log"
  lane_outcome refused "repo-target:REFUSED"
  exit "$REPO_ASSERT_RC"
fi
# ⛔ A `--repo-dir`-ONLY CALL MUST NOT LEAVE `$OR` EMPTY (#2762 review, P1). The module supports
# naming ONLY a directory, and it derives the target slug internally — but `$OR` is what the brief's
# `gh issue view … --repo $OR` and the branch assertion use. Left empty, the lane STARTS and writes a
# brief whose `--repo` argument is empty: `gh` then falls back to ambient `GH_REPO` (the #2235
# wrong-repo fail-open this change exists to close) or errors. The dir assertion has just PROVED this
# worktree is the target, so deriving the slug from it is not a guess; if it still cannot be read,
# refuse rather than start.
if [ -z "$OR" ]; then
  OR="$(repo_target_slug "$PWD" 2>/dev/null || true)"
  if [ -z "$OR" ]; then
    echo "$(repo_target_refuse "lane $N" target-underivable "the target directory passed the assertion but its origin slug cannot be read, so the lane has no repo to name in its brief or its gh calls")" | tee -a "$O/logs/lane-$N.log"
    echo "[lane $N] NOT started: no target slug could be derived from the asserted worktree" >> "$O/logs/lane-$N.log"
    lane_outcome refused "repo-target:target-underivable"
    exit "$REPO_TARGET_REFUSED"
  fi
fi
# The branch half: a worktree of the right repo checked out on a DIFFERENT named branch is the
# `prfixup` shape. A DETACHED HEAD is deliberately allowed — the cell template creates `worktree add
# --detach` and the lane creates its branch at push time — so the branch assertion applies only when
# HEAD is attached to a named branch.
HEAD_BRANCH="$(repo_target_head_branch "$PWD")"
if [ -n "${BR:-}" ] && [ -n "$HEAD_BRANCH" ]; then
  BRANCH_ASSERT_LINE="$(repo_target_branch_assert "lane $N" "$PWD" "$BR" "$OR")"; BRANCH_ASSERT_RC=$?
  printf '%s\n' "$BRANCH_ASSERT_LINE" | tee -a "$O/logs/lane-$N.log"
  if [ "$BRANCH_ASSERT_RC" -ne 0 ]; then
    echo "[lane $N] NOT started: branch assertion REFUSED (exit $BRANCH_ASSERT_RC) — no agent started" >> "$O/logs/lane-$N.log"
    lane_outcome refused "repo-target:branch-REFUSED"
    exit "$BRANCH_ASSERT_RC"
  fi
fi
# ONCE, up front, and to BOTH surfaces: the lane log (what an operator greps) and the lane's own
# stdout (what the controller reads). The brief carries the long form; this is the one-line reminder
# that the requirement exists at all, so no lane can discover it only by being refused at the rail.
REVIEWER_PREFLIGHT="$(reviewer_preflight_line harness)" || {
  echo "[lane $N] FATAL: reviewer_preflight_line failed — refusing to start a lane with no disclosure" >&2; exit 78; }
printf '%s\n' "$REVIEWER_PREFLIGHT" | tee -a "$O/logs/lane-$N.log"
# The brief's reviewer section, rendered ONCE here and spliced into the heredoc as a VARIABLE.
# ⛔ NOT a `$(...)` inside the heredoc: the heredoc is UNQUOTED, so a command substitution in it runs
# at prompt-build time — and selftest.sh's unescaped-backtick rig exists precisely because that bug
# class silently erases prompt text (agent-infra#1835). Precomputing keeps the expansion inert.
REVIEWER_BRIEF="$(reviewer_brief_section harness)" || {
  echo "[lane $N] FATAL: reviewer_brief_section failed — refusing to start a lane whose brief omits the reviewer step" >&2; exit 78; }
# ── the LANDING ARTIFACTS, disclosed for the same reason (#2325) ──────────────────────────────────
# `pipeline-compliance` blocked 36 of 40 open agent-infra PRs and the count GREW faster than lanes
# could be rescued (33 → 36 in one hour). The brief told a lane to READ the pipeline skills and
# never to PRODUCE what they exist to create, so each lane finished real work, opened a PR, and was
# refused — with its evidence retro-fitted afterwards. Same treatment as the reviewer step above:
# rendered ONCE, spliced as a VARIABLE (never a `$(...)` inside the unquoted heredoc — #1835), and
# FAIL LOUD if the helper cannot render it, because a brief that silently drops it is the defect.
LANDING_BRIEF="$(landing_artifacts_brief_section harness)" || {
  echo "[lane $N] FATAL: landing_artifacts_brief_section failed — refusing to start a lane whose brief omits the landing artifacts" >&2; exit 78; }
# ── COMMIT AS YOU GO, disclosed for the same reason (#2981) ──────────────────────────────────────
# Five `prfix` lanes were killed at their caps with ZERO commits and 144 KB of work that reached no
# PR, because every one of them held its single commit for the end and the end was a `kill -TERM`.
# This brief already stated the research contract, the reviewer step and the landing artifacts; the
# cheapest rule of all was missing. Same treatment as the two sections above: rendered ONCE, spliced
# as a VARIABLE (never a `$(...)` inside the unquoted heredoc — #1835), FAIL LOUD if the helper
# cannot render it, and CHECKED at build time below — a brief that silently drops it is the defect.
DELIVERY_BRIEF="$(delivery_brief_section lane)" || {
  echo "[lane $N] FATAL: delivery_brief_section failed — refusing to start a lane whose brief never tells it to commit as it goes (#2981)" >&2; exit 78; }
# ⛔ AN EMPTY RENDER IS A FAILED RENDER. The section is spliced below as a variable, so a helper that
# returns nothing would insert a blank line and every other assertion would stay green.
[ -n "$DELIVERY_BRIEF" ] || {
  echo "[lane $N] FATAL: delivery_brief_section rendered NOTHING — refusing to start a lane whose brief never tells it to commit as it goes (#2981)" >&2; exit 78; }

# ⛔ agent-infra-SPECIFIC, and NOT in the tortoise original: the NO-SEARCH bound in the test line
# below. A lane's worktree normally HAS a `.venv`, but when it does not the agent used to hunt for an
# interpreter across the filesystem — a `find` over $HOME blocks for minutes and has consumed whole
# agent budgets with nothing produced. Point it at `uv sync` instead. Do NOT drop it in a re-port.
# ⛔ THE BRIEF NAMES A COMMAND, SO IT MUST NAME ONE THAT EXISTS ON THIS BOX (A12). install.sh never
# copies — `$O` is synced by the operator — so on a cell that has not been re-synced `$O/lane-merge.sh`
# is absent while the shipped copy sits beside this script. Emitting the `$O` path unconditionally
# would tell the lane "use it, do not hand-roll a polling loop" and then hand it nothing (the lane's
# only remaining options are an invented loop or a handoff). Resolve once, here, and say so in the log.
LANE_MERGE_CMD="$O/lane-merge.sh"
# Always set (the brief interpolates it): empty means "the tool exists, say nothing extra".
MERGE_LOOP_NOTE=""
if [ ! -f "$LANE_MERGE_CMD" ]; then
  # ⛔ THE FALLBACK IS ONLY A FALLBACK IF IT IS A DIFFERENT PATH (reviewer finding, P2, verified). When
  # this script was itself loaded FROM `$O` (the shipped `dispatch-merge.sh` route) `$SELF == $O`, so
  # the "fallback" resolves to the very file that is missing: the log claimed a substitute was named
  # while the brief pointed at nothing. Say nothing rather than something false, and name the remedy.
  if [ "$SELF/lane-merge.sh" != "$LANE_MERGE_CMD" ] && [ -f "$SELF/lane-merge.sh" ]; then
    LANE_MERGE_CMD="$SELF/lane-merge.sh"
    echo "[lane $N] ⚠️ $O/lane-merge.sh is absent (this \$O predates the lane-owns-merge change) — the brief names $LANE_MERGE_CMD instead. Redeploy: bash scripts/orchestrator-harness/deploy-harness.sh --repo . --o $O/" >> "$O/logs/lane-$N.log"
  else
    # ⛔ THE BRIEF MUST SAY WHAT THIS LINE SAYS (landing-review finding 2): the merge-loop section below is
    # rendered from $MERGE_LOOP_NOTE, so this arm now really does tell the lane the tool is missing and
    # what to do instead — previously the log promised that and the brief named a path that did not exist
    # (exit 127, unmapped by the brief's own exit-code table).
    MERGE_LOOP_NOTE="⛔ THE MERGE LOOP IS NOT INSTALLED ON THIS BOX ($LANE_MERGE_CMD does not exist). Do NOT hand-roll a polling loop: if you cannot reach \`merged\`, report the exact blocker as a hand-off comment per **Handoff** below and stop. An operator can install it from the agent-infra checkout (NOT from this lane worktree) with: \`bash scripts/orchestrator-harness/deploy-harness.sh --repo <agent-infra> --o $O\`"
    echo "[lane $N] ⛔ $O/lane-merge.sh is ABSENT and this harness was loaded FROM $SELF — there is no other copy to name. The brief now says so and tells the lane to hand off instead of running a missing path; redeploy first FROM THE agent-infra CHECKOUT (not this lane worktree) with bash scripts/orchestrator-harness/deploy-harness.sh --repo <agent-infra> --o $O/" >> "$O/logs/lane-$N.log"
  fi
fi
cat > "$O/logs/prompt-$N.txt" <<EOF
Autonomous engineering lane. You are ALREADY inside your own worktree (that is your cwd, on branch \`$BR\`). Do NOT create, switch, or remove worktrees, and NEVER touch the repo's main checkout.

## Your issue
**#$N** — read it IN FULL including every comment (root-cause corrections live there):
    gh issue view $N --repo $OR --json title,body,labels
    gh issue view $N --repo $OR --comments --json comments --jq '.comments[].body'
The comment thread supersedes the body where they disagree. Several issues here are labelled provenance-stale — RE-MEASURE before trusting the body.

## Setup (you are already in the worktree)
    uv sync --extra embeddings --extra parity        # tortoise: installs the canonical dev env
Tests: \`TORTOISE_TEST_CARVE_OUT=1 .venv/bin/python -m pytest <paths> -q -p no:cacheprovider\`  (NEVER bare \`uv run\` — it strips the extras). If \`.venv\` is missing in YOUR worktree, run \`uv sync --extra embeddings --extra parity\` once — ⛔ never search the filesystem for an interpreter (no \`find\`/\`rg\`/\`du\` outside this worktree: a \`find\` under \`$HOME\` blocks for many minutes and has consumed whole agent budgets, producing no result).

## ⛔ ACCEPTANCE CRITERIA — the PR is not the finish line
**You are done when your PR is MERGED, or when you report the one thing that blocks the merge that nobody
else can supply.** A lane that stops at "PR opened" has NOT finished: the fleet measured 22 open PRs against
3 merged, because every lane treated the opened PR as success and left the merge work behind 16 running lanes.
So after the PR exists you must:
  1. drive YOUR OWN checks to terminal and fix what is red (lint, tests, a committed conflict marker);
  2. keep the PR mergeable — if it goes DIRTY, re-apply your own change onto current main and force-push
     YOUR branch (see Conflicts below);
  3. take it to the repo's merge path and stay until it is merged. Do not ask the parent to do the fixing
     you can do here.

## The merge loop is a TOOL, not an instruction — use it
${MERGE_LOOP_NOTE:+$MERGE_LOOP_NOTE
}
    bash $LANE_MERGE_CMD <PR> --issue $N --repo $OR --branch $BR
It is bounded BY CODE (3 fix rounds, then it refuses); do not hand-roll a polling loop and do not run
\`gh pr merge\` yourself. Its exit code IS your next action:
    0  MERGED              done — report the merge sha
    10 FIX_REQUIRED        the printed check names are red — fix, commit, push, run the tool again
    15 FIX_CONFLICT        PR is dirty — see Conflicts below, force-push, run again
    11 WAITING             the harness's merge chain owns the PR now; call
                           \`bash $LANE_MERGE_CMD <PR> --watch --issue $N --repo $OR\` (a bounded chunk —
                           repeat it). It is DETACHED on purpose, so it keeps running even if your wall
                           clock ends. ⛔ READ the printed line before repeating: a chunk that says the
                           PR head MOVED past the chain's head means run the loop again, not --watch.
    12 BLOCKED_ATTESTATION green and mergeable, but there is no signed review at this head and you may
                           not mint one — hand off (this is the one thing only a fresh reviewer supplies)
    13/14 BLOCKED_*        stop fixing and HAND OFF (see Handoff below)
The merge itself is \`$O/merge-one.sh\`, the harness's one per-PR chain: it resolves the repo's own merge
authority (a rail repo merges through its rail; a gate repo dispatches a FRESH-CONTEXT reviewer, records the
verdict, and only then merges). ⛔ **NEVER call \`record-review.sh\` yourself and never post a review verdict of
your own** — a lane attesting to its own review is a review that did not happen, and it is the one thing the
chain exists to make impossible.

## Conflicts
If the PR is DIRTY, re-apply YOUR OWN change onto current main (\`git fetch origin main\`, then rebase or
merge origin/main onto your branch), resolve conflicts keeping both sides' intent, re-run your tests, and
force-push YOUR OWN branch (\`git push --force-with-lease origin $BR\`). ⛔ **Never resolve a conflict in a
GENERATED file by picking a side** — regenerate it with its own generator (lockfile, snapshot, manifest, codegen).
Never force-push anyone else's branch, and never touch the repo's main checkout.

## Attestation — read this BEFORE you touch the PR body
Once a review has been recorded at your head, **any PR body edit WIPES the attestation the gate reads** (that
exact failure has happened twice on real PRs). So: write the body ONCE, before the merge loop starts; after
that, do not edit it. Put new information in a **comment**, never in the body. And never re-record a review
to "refresh" it.

## Handoff — a diagnosis, not a mystery
If you cannot merge, the exact blocking reason MUST be on the PR as a comment. \`lane-merge.sh\` posts it for
the terminal BLOCKED_* exits; for any other handoff you write it yourself:
    gh pr comment <PR> --repo $OR --body "<the exact blocker: the check name + its failure, the conflict, the missing precondition, and what you already tried>"
Then report it. "Blocked" with no reason forces the next lane to re-derive everything you learned.

## The mandatory lane report — it is now VERIFIED before merge (#2977)
The owner ruling of 2026-10-28 keeps your push/PR authority with the session gates bypassed and moves the
guarantee to the harness: a durable per-lane report plus a verifier that reads it. \`lane-merge.sh\` runs that
verifier BEFORE it launches the (paid) merge chain, and \`merge-one.sh\` runs it before the rail and the
reviewer. If the repo ships \`tools/worktree_report.py\`, then a report that is **absent, invalid, records a
FAILING suite, or was written at a different head than the one you are merging** is REFUSED, and you spend a
fix round (exit 10). The fix is usually free — no push:
    python3 tools/worktree_report.py run --cmd '<the exact command>'   # each suite, AT THIS HEAD
    python3 tools/worktree_report.py check                            # 0 green · 3 red-but-valid · 1 invalid
⛔ Re-rendering an old report is NOT the fix: it launders evidence taken from a different tree into the head
you are shipping, which is the false green the gate exists to refuse. A repo that ships no writer (or a box
with no worktree for your branch) is an ABSTENTION, logged in the merge log and never counted as a green.

## Rules
- The review/VGATE extensions are BYPASSED for you and you have NO "task" tool — do NOT dispatch. The PARENT runs the review gate (that is the chain in the merge loop above, not you).
- Commit with \`git commit -F <message-file>\` (repo-unique temp path per AGENTS.md "Editing Rules"). Stage specific files; never \`git add -A\`.
- Push (\`git push -u origin $BR\`), then open a PR against main: title "<type>(<scope>): <subject> (#$N)". The body MUST carry "Closes #$N" ON ITS OWN LINE — check [a] reads the LINE position, so a mid-sentence "(fixes #$N)" does not count. ⛔ Do NOT reach for "Refs #$N" on work you have finished: GitHub never closes an issue from a \`Refs\`, and NOTHING in this fleet re-reads an open issue whose PR merged — measured 2026-10-13, 25 of 36 open P0-blockers already had MERGED PRs on main while 48 PRs merged in one day and 0 blockers closed (#8468). Use "Refs #$N" ONLY when a specific acceptance indicator is genuinely unmet, and then name it on its own line as \`Still open: <indicator>\` — a bare \`Refs\` is a lane failing to take a position, not a partial delivery. Include what changed and exact test evidence.
- Do NOT change the MCP tool registry or the public TortoiseSDK surface (needs owner approval — STOP and report instead).
- REMEMBER what load is: 22 landers share one rate-limited GitHub account. Read the PR once per loop turn, use \`lane-merge.sh\` (REST + local state), and never poll in a tight loop.
- Read skills/issue-workflow/SKILL.md and skills/issue-scoping/SKILL.md first.
- If the defect is already fixed (in-repo or elsewhere) report ALREADY_FIXED / OUT-OF-REPO with file/line/commit evidence instead of forcing a PR. A no-change verdict with evidence is a good outcome.
- **If you add a test file, you MUST register it in \`config/ci-surfaces.yml\`** — an unregistered file is never selected on the relevant source diff and the unconditional \`manifest-integrity\` leg fails. Verify with \`python tools/ci_selection.py --integrity\`.
- Use the research skill for non-trivial research; never call web_search directly. Auto-file any pre-existing bug with no open issue. Never ask the human anything.
- Collision pre-flight is CLEAN for this issue.

$RESEARCH_BRIEF

$DELIVERY_BRIEF

$LANDING_BRIEF

$REVIEWER_BRIEF

## Deliverable (final message, <=25 lines)
issue #, status (**MERGED | BLOCKED_ATTESTATION | BLOCKED_ATTEMPTS | BLOCKED | ALREADY_FIXED | OUT-OF-REPO**),
branch + PR URL, the MERGE SHA when merged, files changed, exact test commands + pass/fail counts, and — if
not merged — the single blocking reason and the PR comment URL where you recorded it. Write the status token
EXACTLY as one of those words on its own line: the fleet's merge-rate instrument reads this line, and a lane
that ends "PR_OPENED" is counted as unfinished.
EOF
# ── THE GENERATED BRIEF IS CHECKED AT BUILD TIME (#2258) ───────────────────────────────────────
# Before the dry-run seam and before any capacity bookkeeping. `LANE_DRY_RUN=1` then proves the brief
# a lane would ACTUALLY receive (the #2148 suite drives that seam), and a heredoc regression that
# drops the research block refuses at BUILD time instead of being discovered by the gate inside
# `run_agent` minutes later. When this fires the author is not at fault — the brief is GENERATED
# here — so it is 78 (cannot run), never 80 (brief refused).
bash "$brief_gate_sh" --check "$O/logs/prompt-$N.txt" lane 2>>"$O/logs/lane-$N.log" || {
  echo "[lane $N] FATAL: the GENERATED brief fails brief-gate.sh — refusing to start a lane whose brief lost its research contract (a harness defect in the heredoc above, NOT a brief-authoring error) (#2258)" >&2
  exit 78
}
# ⛔ AND THE DELIVERY CONTRACT IS CHECKED HERE TOO (#2981). `brief-gate.sh` validates the RESEARCH
# contract only; a heredoc edit that drops this section would leave every other assertion green — the
# exact invisibility that cost 144 KB. Cheap, build-time, and it refuses BEFORE a lane is started.
# ⛔ THE `-n` IS PART OF THE GUARD, NOT DECORATION: `grep -F ""` matches EVERY line, so an emptied
# heading constant would make this check INERT while it still read as protection (a no-op gate).
[ -n "$DELIVERY_BRIEF_HEADING" ] && grep -qF -- "$DELIVERY_BRIEF_HEADING" "$O/logs/prompt-$N.txt" || {
  echo "[lane $N] FATAL: the GENERATED brief lost its COMMIT-AS-YOU-GO section — refusing to start a lane that would hold its work to the cap (a harness defect in the heredoc above) (#2981)" >&2
  exit 78
}
# ── CAPACITY TRANSFER: make the refusal a DURABLE, READABLE record (agent-infra#1909) ──────
# R8: "when a machine refuses an item for capacity, the item remains eligible for another
# machine." The refusal itself is fine and stays (R1); what made it fleet-wide idleness was that
# NOTHING downstream could tell a refused lane from a working one. Two consequences followed, and
# both are what `state/capacity-refused-<N>` now lets the rest of the harness fix:
#
#   • `chain-merge.sh` waited the full 90 minutes for a PR that could never appear, holding the
#     cross-box claim `refs/claims/issue-<N>` the whole time. Every peer's pre-flight reads a live
#     claim as COLLISION, so ONE box's load spike made the issue ineligible on ALL FIVE boxes for
#     90 min. Reading this record, the chain exits at once and its EXIT trap releases the claim.
#   • nothing stopped THIS box from re-winning the claim the next cycle and being refused again,
#     which starves the peers it just yielded to. The second field is the yield, read by
#     `orch-loop.sh`'s `capacity_yield_live()`.
#
# FORMAT — one line, three tab-separated fields, and the field ORDER is the contract with both
# readers: `<refused_epoch>\t<yield_until>\t<gate>`, where `gate` is one of the NINE refusal gates
# `cap_refusal_gate` below classifies: `load`, `disk`, `land`, `fork`, `capability`, `skew`, `key`, `mem`,
# `stale`.
# ⛔ THIS SENTENCE USED TO SAY "`load`, `disk` or `land`" AND THAT WAS A TRAP (review P2): the writer has
# emitted SIX since the fork/capability/skew/key gates were added — and it said SEVEN here because that
# stale count is exactly how this comment drifted the first time (review cycle 1, P2: it read "SIX"
# beside a list of seven). ⛔ IT DRIFTED THE SAME WAY TWICE MORE, AND THE SECOND TIME WAS THIS CHANGE:
# it read SEVEN beside eight names, then EIGHT beside eight names while `#3932` added a NINTH arm
# (`stale`) to `cap_refusal_gate` — so the count is the part that rots, not the list. The list and the
# count are asserted against `cap_refusal_gate` by `lane-outcome.test.sh` §4e, which is what turns the
# next gateway added without this line into a red test instead of a misled reader.
# `chain-merge.sh` folds an UNRECOGNISED third field to `load` — so a reader implemented from this
# sentence alone would report a credential stand-down as a load wait, which is the #2991 mislabelling
# this file is careful to avoid three lines above. The vocabulary lives in `cap_refusal_gate`; this
# comment names it rather than restating a list that can drift again.
# (`land` is the CREATION back-pressure refusal, agent-infra#2409 — see run_agent in spawn-gate.sh.
# It is written by the same line and read by the same two readers; chain-merge.sh maps it to exit 74
# and says in its own words that it is NOT a capacity transfer, because no peer box can clear a
# repo-wide backlog.) The epoch is
# what makes the record PER-DISPATCH: a chain compares it against its own start time, so a record
# left by an earlier run of the same issue can never make a live lane's chain exit early.
# ⛔ The gate is named, not implied, for the reason lane.sh's own reporting line below spells out: a
# load refusal clears when the box quietens, a disk refusal never does.
CAPACITY_YIELD_SECS="${CAPACITY_YIELD_SECS:-900}"
# Clamped with the shared `is_limit` (digits, at most nine) rather than a local predicate, so a
# typo cannot mint an unreadable record — and bounded at 24h because a larger yield is not a
# transfer but a permanent stand-down of this box: `0` is REFUSED rather than honoured, since a
# zero-length yield would silently restore the defect R8 exists to remove while looking configured.
if ! is_limit "${CAPACITY_YIELD_SECS:-}" || [ "${CAPACITY_YIELD_SECS:-0}" -lt 1 ] || [ "${CAPACITY_YIELD_SECS:-0}" -gt 86400 ]; then
  echo "[lane $N] WARN: CAPACITY_YIELD_SECS='${CAPACITY_YIELD_SECS:-}' is not a whole number of seconds in 1..86400 — using 900" >> "$O/logs/lane-$N.log"
  CAPACITY_YIELD_SECS=900
fi
# A path is built from $N, so it is validated HERE even though dispatch-merge.sh already refuses a
# non-numeric id: lane.sh is also invoked by hand, and `$N=../../x` would write outside $O/state.
case "${N:-}" in ''|*[!0-9]*) capacity_record= ;; *) capacity_record="$O/state/capacity-refused-$N" ;; esac
# LANE_DRY_RUN=1 stops HERE, after every artifact the lane would be given exists. It is the seam
# the #2148 regression test drives: the pre-flight line and the generated brief are asserted from the
# real artifacts a lane receives, not from a grep of this file's source (a source-shape assertion
# passes on a script whose runtime output lost the text — the "test that cannot fail" class).
if [ "${LANE_DRY_RUN:-0}" = "1" ]; then
  echo "[lane $N] DRY RUN — prompt written to $O/logs/prompt-$N.txt; no agent started" | tee -a "$O/logs/lane-$N.log"
  # `done` because the lane completed everything it was asked to: it REFUSED nothing and FAILED at
  # nothing — `reason=dry-run` is what tells a scan this log never had an agent. The LINE itself is
  # written by the EXIT trap (installed above and still armed: a dry run disables the CLEANUP, never the
  # terminal line — review P2), so there is deliberately no second write here.
  lane_outcome done dry-run
  exit 0
fi
# ⛔ THE WALL LIMIT GREW BECAUSE THE JOB DID (3300s, was 2400s). A lane now owns its merge: after the
# PR exists it waits for its own checks, fixes them, and supervises the merge chain — a merge phase that
# queues behind 24-minute CI. At 2400s the kill would land mid-merge on a lane that had done nothing
# wrong, and the lane log would end with no MERGED line even on a PR that merges (the chain is detached,
# so the merge itself still completes — which is exactly why the missing line would be silent). The
# bound is still a bound, and LANE_TIMEOUT overrides it as before.
# ⛔ AND SINCE agent-infra#2888 THAT BOUND IS THE ABSOLUTE BACKSTOP, NOT THE PRIMARY ONE: it no longer
# defaults to a number of its own. The bound that decides wedged-vs-slow is `lane-bound.sh`'s PROGRESS
# allowance (45 min, the fleet's own), and a lane that keeps working is no longer killed by elapsed
# time — this argument is the ceiling for a lane that creeps forward for ever. It therefore takes the
# ONE default (`LANE_BACKSTOP_S`, spawn-gate.sh) rather than a local literal, because three separate
# literals is how the flat 40-minute cap outlived the allowance that contradicted it.
#
# ── THE STAND-DOWN RECORD, WRITTEN BY ONE FUNCTION (agent-infra#1909's format; #3331 adds a caller) ──
# `state/capacity-refused-<N>` is one line, three tab-separated fields (`<refused_epoch>\t<yield_until>\t<gate>`)
# and its two readers are `chain-merge.sh::cap_refusal_gate` and `orch-loop.sh::capacity_yield_live` — see
# the CAPACITY TRANSFER block below for the contract and why each gate is named rather than folded.
# ⛔ IT IS A FUNCTION BECAUSE THERE ARE NOW TWO WRITERS (review round 3, P2). The post-`run_agent` arm has
# always written it; the KEY gate refuses 270 lines EARLIER, and a refusal that mints no record left
# `chain-merge.sh` waiting its full 90 minutes for a PR that could not appear while HOLDING
# `refs/claims/issue-<N>` — so a peer that could run the item saw COLLISION, which is precisely the R8
# defect the record exists to remove (`capability` writes one for the same reason: the credential is a
# property of THIS box). Two inline `printf`s of a three-field format is how a format drifts.
lane_standdown_write() { # <gate> <yield-seconds>
  [ -n "${capacity_record:-}" ] || return 1
  local now
  now="$(date +%s)"
  printf '%s\t%s\t%s\n' "$now" "$(( now + ${2:-0} ))" "$1" > "$capacity_record" 2>/dev/null
}
# ── THE KEY GATE (agent-infra#3331) — THE FIRST SPAWN GATE, IMMEDIATELY BEFORE `run_agent` ─────
# ⛔ IT IS *FIRST*, NOT LAST, AND THE EARLIER COMMENT HERE CLAIMED THE OPPOSITE (review, P2). `run_agent`
# runs 60 lines BELOW, and it is where the brief gate (80), the disk gate (77), the fork gate (73) and the
# load gate (75) live — so this gate decides BEFORE any of them. That is deliberate and it is not free: a
# dispatch with both an inadmissible brief and an unset credential reports the CREDENTIAL, yields the item
# to peers for `CAPACITY_YIELD_SECS`, and a peer refuses it with 80 — one wasted hop. It is still the right
# order, because a missing credential is the one condition that makes every later measurement meaningless
# (`pi` cannot run at all), and fixing it is a property of THIS box, which is exactly what the yield
# expresses. Recorded here rather than implied, so the next reader is not told a gate ordering the code
# contradicts.
# It asserts the exact environment `run_agent` is about to hand to `pi` — after `lane-env.sh` has sourced
# the box's file, after every export above, with nothing left in THIS SHELL that could change it. Measured
# 2026-11-02: two cells, `HOME=/tmp/cell-home` for the operational layer, the credential in the ACCOUNT
# home's `keys.env` — `pi` printed `No API key found for the selected model.`, exited, and the lane was
# gone with a log that simply stopped.
# ⛔ THE OTHER HALF IS `outcome=refused`, written by the trap. A refusal that only reaches stderr is the
# same silence one layer up: `dispatch-merge.sh` had already recorded "launched" from `nohup … &`.
if [ "${KEY_GATE_ESCAPE:-0}" = "1" ]; then
  # ⛔ THE DECLARED ESCAPE, AND IT ANNOUNCES ITSELF. It exists for fixtures that STUB `pi` (so the
  # credential is not what they measure) — a fixture that inherited the box's own key would be a false
  # GREEN on one box and a false RED on another. On a live box this line IS a bypass, and it says so in
  # the log rather than switching the gate off quietly.
  echo "[key-gate] lane $N check=skipped reason=--key-gate-off — the model-credential assertion is OFF for this invocation (declared escape: argv, for fixtures that stub pi; on a live box this line is a bypass and says so) (#3331)" >> "$O/logs/lane-$N.log"
else
  # ⛔ THE RETIRED ENVIRONMENT ROUTE IS REPORTED, NOT OBEYED (review, P1, measured). A box `keys.env` or a
  # controller's launchd environment can carry `LANE_KEY_GATE=0`, and the previous cut honoured it. It is
  # not honoured now — but it is not silently ignored either, because an operator whose fixture relied on
  # it would otherwise see a lane refuse 82 with no explanation of what changed.
  if [ -n "${LANE_KEY_GATE:-}" ]; then
    echo "[key-gate] lane $N check=ignored var=LANE_KEY_GATE=${LANE_KEY_GATE} — the escape is ARGV now (--key-gate-off). An environment variable can be inherited from the box (the cell supervisor sources keys.env under \`set -a\`, so its children carry it), which made it a fleet-wide off switch rather than a fixture-only one; this value was NOT honoured and the gate below still ran. Pass --key-gate-off to the invocation if you meant it." >> "$O/logs/lane-$N.log"
  fi
  # ⛔ NOT A `$(…)` CAPTURE, AND THAT IS LOAD-BEARING. A command substitution runs the gate in a
  # SUBSHELL, so the `KEY_GATE_VAR`/`KEY_GATE_REASON` it sets evaporate — and the lane then announces
  # the refusal with `var=unknown`, which is the very silence this issue removes (measured on this
  # change's first draft: `reason=key-gate:credential-missing:unknown`). The gate writes to a file the
  # caller owns, so its rc AND its state both reach this shell.
  # ⛔ A REDIRECT THAT FAILS IS NOT A REFUSAL (review round 4, P2, measured). `> "$KEY_GATE_OUT"` puts the
  # creation of a file in `$O/state` INSIDE the refusal decision: on a read-only or full `$O` bash never
  # runs the function, the status is 1, and the arm below announced a MISSING MODEL CREDENTIAL with
  # `var=?`, `rc=1`, and a credential remedy — for a disk condition the DISK gate (77) exists to name, a
  # gate that lives 200 lines LATER. So the file is created (and proved writable) first, and anything that
  # is not exactly KEY_GATE_REFUSED is reported as the gate being UNABLE TO RUN, with its own outcome and
  # no stand-down record (nothing was measured, so nothing is yielded).
  # ⛔ PER-RUN, NOT PER-ISSUE (review, P2, measured). The scratch path used to be `state/key-gate-<N>.line`,
  # keyed on the ISSUE — while the verdict written beside it is explicitly PER RUN for the same reason: a
  # previous run of the same issue can still be ALIVE. Two concurrent runs of #N then truncated, `tee`d and
  # `rm`ed the same file, so one run's log could carry `check=ok` while its own `outcome=` said
  # `refused reason=key-gate:…` — the reading and the verdict disagreeing, which is the
  # instrument-misstates-itself class this whole change exists to remove.
  KEY_GATE_OUT="$O/state/key-gate-$N-${LANE_RUN_TOKEN}.line"
  if ! { : > "$KEY_GATE_OUT"; } 2>/dev/null; then
    lane_outcome died "key-gate-not-run:no-outcome-file"
    echo "[lane $N] NOT started: the KEY gate could not be RUN ($O/state is not writable) — this is NOT a credential refusal and NOTHING was measured about the model, so nothing is yielded and the credential is not the suspect. Fix $O (free space / permissions; the DISK gate reports the same condition as 77) and re-dispatch." >> "$O/logs/lane-$N.log"
    echo "[lane $N] NOT started: the KEY gate could not be RUN ($O/state not writable) — see $O/logs/lane-$N.log" >&2
    exit 78
  fi
  # ⛔ THE MODEL PAIR IS PASSED EXPLICITLY, SO THE GATE AND THE SPAWN CANNOT DISAGREE (agent-infra#3443).
  # `run_agent` builds `pi -p --provider "${PI_LANE_PROVIDER:-deepseek}" --model "${PI_LANE_MODEL:-deepseek-flash}"`
  # — the provider is ALWAYS explicit there, even when the model id carries its own `provider/` prefix. A
  # gate that resolved the provider from the prefix would therefore assert one provider's credential while
  # `pi` was handed another: green gate, dead lane (the false-PASS polarity). Passing both halves here makes
  # the agreement structural instead of a coincidence of two defaults, and it is why the gate's own
  # prefix rule is reserved for a probe that names no provider.
  key_gate_assert "lane $N" "${HOME:-}" "${PI_LANE_PROVIDER:-deepseek}" "${PI_LANE_MODEL:-deepseek-flash}" > "$KEY_GATE_OUT" 2>&1; KEY_GATE_RC=$?
  tee -a "$O/logs/lane-$N.log" < "$KEY_GATE_OUT"
  rm -f "$KEY_GATE_OUT" 2>/dev/null || true
  if [ "$KEY_GATE_RC" -ne 0 ] && [ "$KEY_GATE_RC" != "$KEY_GATE_REFUSED" ]; then
    # The gate itself failed (not a verdict). 78 = cannot run, and the reason names it so an operator does
    # not go looking for a credential that was never the problem.
    lane_outcome died "key-gate-not-run:rc$KEY_GATE_RC"
    echo "[lane $N] NOT started: the KEY gate FAILED with status $KEY_GATE_RC — it did not measure the credential, so this is NOT a refusal about it and nothing is yielded. The '[key-gate]' output above is the reading; fix the harness ($SELF/key-gate.sh) and re-dispatch." >> "$O/logs/lane-$N.log"
    echo "[lane $N] NOT started: the KEY gate FAILED (status $KEY_GATE_RC) — see $O/logs/lane-$N.log" >&2
    exit 78
  fi
  if [ "$KEY_GATE_RC" -ne 0 ]; then
    # The reason token names the VARIABLE and the MODEL, so a fleet scan can count the missing names and
    # the model they were for without reading prose: `grep -h '^outcome=refused reason=key-gate'
    # $O/logs/lane-*.log`. ⛔ THE MODEL IS IN THE TOKEN BECAUSE THE FAILURE IS NAMED AFTER IT (agent-infra#3443:
    # `No API key found for the selected model.`) — a token carrying only the variable answers a question the
    # operator did not ask when the variable was the wrong one to look at.
    lane_outcome refused "key-gate:${KEY_GATE_REASON:-credential-missing}:${KEY_GATE_VAR:-unknown}:${KEY_GATE_MODEL:-unknown}"
    # ⛔ THE REFUSAL YIELDS THE ITEM (review round 3, P2). A key refusal is a property of THIS box, so a
    # peer that HAS the credential can take the work — and without this record `chain-merge.sh` has
    # nothing to read, so it waits out its 90 minutes holding the cross-box claim while every peer's
    # pre-flight sees COLLISION (the R8 defect the record exists to remove). `capability` writes one for
    # exactly this reason; the words below say what the stand-down buys, the way `land`/`skew` do.
    # ⛔ THE SENTENCE FOLLOWS THE REASON (round 22, P2, measured): a `store-invalid`/`auth-store-unreadable` refusal is a
    # verdict about `auth.json` — INCLUDING a JSON `null` document, which parses and still kills pi at read time
    # (round 29, P3, measured: without this arm the lane prescribed exporting a variable for a file pi cannot index) —
    # and telling the operator to "put the credential in the environment" sends them to the
    # one thing the refusal already measured as NOT the problem (`export $VAR` does not rescue either shape).
    case "${KEY_GATE_REASON:-credential-missing}" in
      store-invalid|auth-store-unreadable|auth-store-null)
        KEY_GATE_REMEDY="a property of THIS box's credential STORE — the [key-gate] line above names ${KEY_GATE_AGENT_DIR:-<agent dir>}/auth.json, which pi reads before anything else, and neither exporting the variable nor a models.json template rescues it; repair or delete that file" ;;
      *)
        KEY_GATE_REMEDY="a property of THIS box — the [key-gate] lines above name the variable and every candidate file. The remedy HERE is to put the credential in the environment lanes run with" ;;
    esac
    if lane_standdown_write key "$CAPACITY_YIELD_SECS"; then
      echo "[lane $N] capacity transfer: yielded to peers for ${CAPACITY_YIELD_SECS}s (gate=key) — the credential is ${KEY_GATE_REMEDY}." >> "$O/logs/lane-$N.log"
    else
      echo "[lane $N] WARN: could not write $capacity_record — the refusal still releases the claim via chain-merge.sh's timeout path, but not promptly" >> "$O/logs/lane-$N.log"
    fi
    # ⛔ THESE TWO LINES FOLLOW THE REASON TOO (round 23, P2, measured): round 22 fixed only the capacity-transfer
    # sentence above, so a `store-invalid`/`auth-store-unreadable` refusal still told the operator here that
    # "$VAR holds no value in the environment this lane would run with ... put the credential where this lane's own
    # env sources it" - the exact prescription the gate's own line in the SAME log refutes ("this is a verdict about
    # the FILE, not about a missing variable ... `export %s` cannot help"), and with no template the variable renders
    # as the non-existent `$<none>`. The suite missed it because the guard greps one fixed phrase.
    case "${KEY_GATE_REASON:-credential-missing}" in
      store-invalid|auth-store-unreadable|auth-store-null)
        # ⛔ NO `$<none>` IN AN INSTRUCTION (round 25, P3, measured): with no models.json template the gate sets
        # `KEY_GATE_VAR` to the literal `<none>`, so the `${VAR:-<none>}` form below rendered "exporting $<none>" — a
        # shell token that does not exist — inside a remedy the operator is meant to follow. The clause is dropped
        # entirely when there is no variable to name (the gate…s own line does the same, printing `var=<none>`).
        # ⛔ TWO WHOLE CLAUSES, NOT ONE CLAUSE WITH A HOLE (round 26, P3, measured): dropping just the export half left
        # "and neither a models.json template rescues that" — a dangling conjunction that also claims a template exists
        # on the shape where none does. Each branch is a sentence an operator can act on.
        case "${KEY_GATE_VAR:-}" in
          ""|"<none>"|"unknown")
            KEY_GATE_WHY="this box's credential STORE cannot answer for it — the [key-gate] line above names ${KEY_GATE_AGENT_DIR:-the agent dir}/auth.json, and no models.json template applies here; repair or delete that file and re-dispatch" ;;
          *)
            KEY_GATE_WHY="this box's credential STORE cannot answer for it — the [key-gate] line above names ${KEY_GATE_AGENT_DIR:-the agent dir}/auth.json, and neither a models.json template nor exporting \$${KEY_GATE_VAR} rescues that; repair or delete that file and re-dispatch" ;;
        esac ;;   # the outer arm needs its own terminator: the inner `esac` does not end it
      *)
        KEY_GATE_WHY="\$${KEY_GATE_VAR:-?} holds no value in the environment this lane would run with, so pi would have died at its first model call with nothing to show for it; put the credential where this lane's own env sources it and re-dispatch. The '[key-gate]' lines above name the provider, its models.json, and every candidate file" ;;
    esac
    echo "[lane $N] NOT started: KEY gate refused (exit $KEY_GATE_RC) — ${KEY_GATE_WHY}. NOT a capacity refusal and nothing was consumed." >> "$O/logs/lane-$N.log"
    echo "[lane $N] NOT started: KEY gate refused (exit $KEY_GATE_RC) — ${KEY_GATE_REASON:-credential-missing}: ${KEY_GATE_WHY}; see $O/logs/lane-$N.log" >&2
    exit "$KEY_GATE_RC"
  fi
fi
run_agent "${LANE_TIMEOUT:-$LANE_BACKSTOP_S}" "$O/logs/lane-$N.log" "$O/logs/prompt-$N.txt" "lane $N"
# Capture the status BEFORE anything else runs: `echo "… $?"` after another command reports that
# command's status, not the agent's (the defect §7.4 records for retired/do-merge.sh).
rc=$?
echo "[lane $N] exited $rc $(date)" >> "$O/logs/lane-$N.log"
# ⛔ A LANE THAT ENDS WITHOUT A MERGE-PHASE VERDICT IS A RECORDED FAILURE, NOT SILENCE (#2029).
# The merge phase is the lane's own job now, so its absence is the exact defect this change targets —
# and the only place it is visible is here. `merge-rate.sh` counts such a lane as UNKNOWN (it reads
# the log's last status token), so the line below is what lets an operator see WHY a lane is UNKNOWN
# without re-reading a 25-minute transcript. It never changes the exit status.
# ⛔ GATE ON "THIS LANE OPENED A PR" (E5). The bare verdict test fired for every lane that
# legitimately never reached a PR — ALREADY_FIXED and OUT-OF-REPO are documented GOOD outcomes in the
# same brief — and told the operator merge-rate would count them as UNKNOWN, which is false: its
# classifier includes both tokens, so they land in `other`, never `unknown`. An instrument that alarms
# on the healthy path and misstates its own measurement teaches the next reader to ignore it.
if grep -qE 'github\.com/[^ ]+/pull/[0-9]+|(^|[^A-Z_])PR_OPENED([^A-Z_]|$)' "$O/logs/lane-$N.log" 2>/dev/null \
   && [ ! -s "$O/state/lanemerge-issue-$N.verdict" ]; then
  echo "[lane $N] ⚠️ NO merge-phase verdict (state/lanemerge-issue-$N.verdict absent) — the lane ended without either reaching merged or naming a blocker; merge-rate.sh will count it as PR_OPENED (or UNKNOWN if the log carries no status token), never as MERGED." >> "$O/logs/lane-$N.log"
fi
# A gate refusal reports AGENT_FORK_REFUSED (73), AGENT_LOAD_REFUSED (75), AGENT_LAND_BACKLOG (74),
# AGENT_BRIEF_REFUSED (80), AGENT_CAPABILITY_REFUSED (71), AGENT_HARNESS_SKEW_REFUSED (83),
# AGENT_MEM_REFUSED (81)
# or AGENT_DISK_REFUSED (77);
# AGENT_STARTED is authoritative rather than the exit code, because `pi` shares the 0–255 status
# namespace and could exit 75 itself (#1720).
# ── THE OUTCOME, RECORDED ONCE, IN THE SAME BREATH AS THE STATUS IT IS DERIVED FROM (#3331) ──────
# The terminal line's `outcome=` is set HERE and nowhere else for these four cases, from the two facts
# the code above already measured: did an agent start (`AGENT_STARTED`, authoritative) and what did it
# return (`rc`). ⛔ EVERY REFUSAL CODE GETS A NAMED GATE, because `outcome=refused` alone would repeat
# the defect this line exists to remove: an operator told "refused" still cannot tell a brief the box
# can never satisfy (80) from a full disk (77) from a fork-exhausted box (73), and the remedies are
# mutually exclusive (#1765, #2293). The tolerant `:-` defaults are the same `$O`-skew guard the block
# below uses: a helper predating a code can never return it.
if [ "$AGENT_STARTED" = "0" ]; then
  case "$rc" in
    "${AGENT_BRIEF_REFUSED:-80}")        lane_outcome refused "brief-gate" ;;
    "${AGENT_LOAD_REFUSED:-75}")         lane_outcome refused "load-gate" ;;
    "${AGENT_FORK_REFUSED:-73}")         lane_outcome refused "fork-gate" ;;
    # ⛔ THE MEMORY GATE'S OWN OUTCOME NAME (#2387), for the reason the comment above gives: an
    # operator told "refused" still cannot tell a fork-exhausted box (73) from one whose memory floor
    # is gone (81), and the remedies are mutually exclusive — a fork needs an external restart, a
    # memory floor clears when resident lanes finish.
    "${AGENT_MEM_REFUSED:-81}")          lane_outcome refused "mem-gate" ;;
    "${AGENT_DISK_REFUSED:-77}")         lane_outcome refused "disk-gate" ;;
    "${AGENT_LAND_BACKLOG:-74}")         lane_outcome refused "land-backlog" ;;
    "${AGENT_HARNESS_SKEW_REFUSED:-83}") lane_outcome refused "harness-skew" ;;
    # ⛔ THE STALE-CHECKOUT REFUSAL GETS ITS OWN OUTCOME NAME TOO (this change's review, P1-2), for the
    # reason above and one more: `refused capability-gate` is what an operator greps to decide whether to
    # repair the box's pi/credential or move the item, and neither is right here.
    "${AGENT_STALE_CODE_REFUSED:-85}")   lane_outcome refused "stale-code" ;;
    "${AGENT_CAPABILITY_REFUSED:-71}")   lane_outcome refused "capability-gate" ;;
    # ⛔ NO `pi-gate` ARM: THE CODE CANNOT REACH HERE (review, P2, measured). `run_agent` translates the
    # spawn point's `PI_GATE_REFUSED` (76) into `AGENT_LOAD_REFUSED` (75) before returning
    # (`spawn-gate.sh:2460-2463`), precisely so no caller has to learn a second code — so an arm here for
    # 76 was dead code that advertised a `reason=pi-gate` token NO lane can produce, in the very vocabulary
    # an operator is told to grep. An instrument that answers with silence is the defect this issue is
    # about; removing the arm is the fix, not adding it to the docs.
    # ⛔ AN UNMAPPED STATUS FROM A GATE IS STILL A REFUSAL, NOT SILENCE: nothing was started, which is
    # a fact about the lane whatever the number means. It names the code so the next reader has the one
    # lead the vocabulary could not supply.
    *)                                    lane_outcome refused "agent-not-started:rc$rc" ;;
  esac
elif [ "$rc" = "0" ]; then
  lane_outcome done "agent-exit-0"
else
  lane_outcome failed "agent-exit-$rc"
fi
if [ "$AGENT_STARTED" = "0" ]; then
  # No agent ran and no PR was opened. The issue is not stranded: refresh-candidates.sh
  # un-blacklists a dispatched issue that has neither a PR nor a live lane session, so it returns
  # to the pool.
  #
  # ⛔ AND THE REFUSAL IS RECORDED, so "returns to the pool" is not merely claimed here — see the
  # CAPACITY TRANSFER block above for the format and its two readers. `fork`, `load`, `mem`, `disk`,
  # `capability`, `skew` and `land` are the seven values the gate can refuse on, and each is chosen by the
  # code its own caller already distinguishes, so the record can never disagree with the exit status.
  # `mem` (#2387) is transferable like `load` — a peer box with free RAM can run the work this box's
  # memory floor refused — which is why it takes the capacity-transfer branch below and not the `land`
  # stand-down one.
  # ⛔ THE BRIEF REFUSAL IS NOT A CAPACITY REFUSAL, AND SAYING SO IS THE WHOLE POINT (#2258). A
  # capacity refusal clears (load) or clears when the volume is reclaimed (disk), and both travel
  # with the BOX — so `capacity-refused-<N>` correctly yields the item to a peer, and
  # refresh-candidates.sh correctly returns it to the pool. A BRIEF refusal has neither property: it
  # is a property of the brief, it never clears by waiting or reclaiming, and re-dispatching the item
  # to another machine refuses there too. Recording it as `gate=load` would tell the whole fleet a
  # remedy that cannot arrive and would hide the one writer who CAN fix it. So: NO capacity record,
  # a loud line on both surfaces, and the item is NOT yielded — it stays this box's to re-author.
  # ⛔ AND IT IS DECIDED FIRST, ABOVE the capacity record, because that block's `else` is `load`:
  # falling through to it would mint the very capacity record this arm exists to prevent.
  if [ "$rc" = "${AGENT_BRIEF_REFUSED:-80}" ]; then
    echo "[lane $N] NOT started: THE BRIEF WAS REFUSED (brief gate, exit $rc) — no agent ran, nothing was consumed, and this is NOT a capacity refusal, so the issue is NOT yielded to a peer: re-author the brief (the [brief-gate] block above names every missing element and prints the canonical section), then re-dispatch." >> "$O/logs/lane-$N.log"
    echo "[lane $N] brief refused — see $O/logs/lane-$N.log; re-author and re-dispatch (not a capacity refusal)" >&2
    exit "$rc"
  fi
  if [ -n "${capacity_record:-}" ]; then
    # ⛔ FORK IS CONSUMED, NOT BUCKETED AS LOAD (review P1, agent-infra#2293). `run_agent` returns
    # AGENT_FORK_REFUSED for a box that is out of PROCESSES, and this branch used to fold every code
    # except disk into `load` — publishing the remedy "re-dispatched when 1-min load falls" for a box
    # that cannot even spawn the retry, which is exactly the rule spawn-gate.sh states at its own fork
    # code ("a caller that reads a fork refusal as a load refusal retries forever on a box that cannot
    # start a process to retry with"). The tolerant defaults keep an `$O/spawn-gate.sh` predating either
    # code — which can never return it — routing exactly as it did.
    # ⛔ FORK IS 73, NOT 74 (#2293 x #2409): 74 is the LAND-BACKLOG gate below, whose remedy is the
    # opposite of a fork refusal's, so one code for both made this very case statement label one gate
    # with the other's remedy (the integration batch's review caught it as a P0).
    # ⛔ CAPABILITY IS ITS OWN VALUE (review of #2991, P1), AND IT IS THE ONE THAT PROVES THE RULE: a
    # fifth refusal code was added to `spawn-gate.sh` with no reader anywhere, so a box that cannot
    # complete one call and RETURN published `gate=load` and the reason "issue returns to the queue" —
    # the line below the correct `[capability-gate] REFUSED` one. Waiting never clears it.
    # ⛔ IT STILL MINTS A CAPACITY RECORD, unlike the brief refusal above, and the difference is not an
    # oversight: a brief refusal follows the ITEM to any box, while a capability refusal is a property
    # of THIS box, so yielding the issue to a peer is exactly the right remedy (the brief-refusal
    # argument, read in the other direction). Tolerant default for the same $O-skew reason as the rest:
    # a helper predating the code can never return it.
    # ⛔ AND `mem` TAKES THE SAME YIELD PATH FOR THE SAME REASON (#2387): `mem` is transferable like
    # `load` — a peer box with free RAM can run the work this box's memory floor refused — which is
    # why it is a capacity value and NOT a `land` stand-down. Its code is 81, outside the band the
    # other gates occupy, so a future renumbering cannot quietly make this arm unreachable.
    if [ "$rc" = "${AGENT_FORK_REFUSED:-73}" ]; then _cap_gate=fork
    elif [ "$rc" = "${AGENT_DISK_REFUSED:-77}" ]; then _cap_gate=disk
    elif [ "$rc" = "${AGENT_MEM_REFUSED:-81}" ]; then _cap_gate=mem
    elif [ "$rc" = "${AGENT_LAND_BACKLOG:-74}" ]; then _cap_gate=land
    elif [ "$rc" = "${AGENT_HARNESS_SKEW_REFUSED:-83}" ]; then _cap_gate=skew
    # ⛔ A STALE CHECKOUT IS THE OTHER REFUSAL WHOSE CODE MUST NOT BE 71 (this change's review, P1-2).
    # The 71 arm below is the one that mints a capacity record, and its consumer in `orch-loop.sh`
    # stands this box down SO A PEER CAN TAKE THE ITEM — correct for a capability refusal (a property
    # of this box) and exactly wrong for a stale checkout, because the measured fleet state was EVERY
    # cell 496-7093 commits behind (#3932): the item circulates between boxes that refuse identically
    # and is never built. Its own code is what makes this file's words, and the controller's, publish
    # the checkout remedy instead of "dispatch the issue to another box".
    elif [ "$rc" = "${AGENT_STALE_CODE_REFUSED:-85}" ]; then _cap_gate=stale
    elif [ "$rc" = "${AGENT_CAPABILITY_REFUSED:-71}" ]; then _cap_gate=capability
    else _cap_gate=load; fi
    # ⛔ THE YIELD IS GATE-INDEPENDENT, AND THAT IS A RECORDED DECISION — NOT AN OVERSIGHT TO TIDY.
    # README §7.2 says it in as many words ("**The yield is gate-independent, deliberately**"), and
    # ARCHITECTURE repeats it. A `land` refusal looks like it wants a SHORT window: it is repo-wide,
    # so every box measures the same ratio and a long stand-down only circulates the same answer.
    # That reasoning is correct and it was still REFUSED here (review cycle 2, P2), because reversing
    # a recorded decision belongs in that decision's own home with the evidence in front of the owner
    # — not in a lane's commit. What the change DOES do about it: chain-merge.sh ends the chain on
    # exit 74 immediately (no 90-minute wait), and the refusal line below says plainly that waiting
    # will not clear it. The window itself stays uniform. A `fork` refusal is subject to the same
    # uniform window for the same reason, and the same non-claim: it does not clear by waiting.
    _cap_yield="$CAPACITY_YIELD_SECS"
    if lane_standdown_write "$_cap_gate" "$_cap_yield"; then
      # ⛔ THE WORDS MUST MATCH THE GATE (review cycle 3, P2). This line used to call EVERY refusal a
      # "capacity transfer ... yielded to peers", so a `land` lane log carried that claim three lines
      # above its own "This is NOT a capacity refusal" — and an operator grepping `capacity transfer`
      # found the false one first. The WINDOW stays uniform (README §7.2 records it as gate-independent);
      # only the description of what the stand-down buys changes.
      if [ "$_cap_gate" = "land" ]; then
        echo "[lane $N] stand-down recorded: gate=land, until +${_cap_yield}s — this stops THIS box re-claiming #$N while the ratio is re-read; it does NOT free the item for a peer to clear, because the backlog is repo-wide. chain-merge.sh releases refs/claims/issue-$N now instead of after 90 min; the drain is landing the open queue, not waiting." >> "$O/logs/lane-$N.log"
      elif [ "$_cap_gate" = "skew" ]; then
        # ⛔ A SIXTH VALUE, AND THE SECOND WHOSE RECORD IS NOT A CAPACITY CLAIM (follow-up review of
        # #2991, P2). The refusal is a helper/consumer VERSION SKEW or a corrupt helper: it is a property
        # of the PAIR, not of this box, so "yielded to peers" is false — a peer running the same pair
        # refuses identically, and the operator's remedy is a VERIFIED redeploy of the helper pair on
        # EVERY box. The record is still written (chain-merge.sh must stop waiting for a PR that
        # cannot appear), and the words say exactly what it buys, the same way `land` does.
        echo "[lane $N] stand-down recorded: gate=skew, until +${_cap_yield}s — this stops THIS box re-claiming #$N while the harness pair is synced; it does NOT free the item for a peer to clear, because a peer running the same caller/probe pair refuses identically. The remedy is a VERIFIED redeploy (bash scripts/orchestrator-harness/deploy-harness.sh --repo . --o \$O) wherever lanes run, not a capacity transfer." >> "$O/logs/lane-$N.log"
      elif [ "$_cap_gate" = "stale" ]; then
        # ⛔ A SEVENTH VALUE, AND THE THIRD WHOSE RECORD IS NOT A CAPACITY CLAIM (this change's review,
        # P1-2). The record is still written, for the `skew` reason: chain-merge.sh must stop waiting for
        # a PR that cannot appear, and this box must not re-claim the item while its checkout is being
        # advanced. What it must NOT do is tell the operator the item has moved to a peer — the peer
        # behind the same wave of stale cells refuses identically, so the words say what the stand-down
        # actually buys and where the remedy lives.
        echo "[lane $N] stand-down recorded: gate=stale, until +${_cap_yield}s — this stops THIS box re-claiming #$N while its checkout is advanced; it does NOT free the item for a peer to clear, because the measured fleet state was every cell hundreds of commits behind (#3932), so a peer is likely stale too. The remedy is on THIS box's checkout (git fetch, then cut the worktree from origin/main, or the cell's own sync path) — the repo and the distance are on the [capability-gate] REFUSED line in this log." >> "$O/logs/lane-$N.log"
      else
        echo "[lane $N] capacity transfer: yielded to peers for ${_cap_yield}s (gate=$_cap_gate) — chain-merge.sh releases refs/claims/issue-$N now instead of after 90 min, and orch-loop.sh will not re-claim it from this box while the yield is live" >> "$O/logs/lane-$N.log"
      fi
    else
      echo "[lane $N] WARN: could not write $capacity_record — the refusal will still release the claim via chain-merge.sh's timeout path, but not promptly" >> "$O/logs/lane-$N.log"
    fi
  fi
  # ⛔ NAME THE GATE THAT ACTUALLY REFUSED (#1765). They are not interchangeable: a load refusal is
  # cleared by the box quietening, a disk refusal only by reclaiming space, and a FORK refusal only
  # from OUTSIDE the box (agent-infra#2293). An operator told "load" on a full filesystem waits for a
  # remedy that cannot arrive; told "load" on a fork-exhausted box, the retry itself cannot start.
  # ⛔ TOLERANT REFERENCE (review round 2, P2). `$O` is seeded file by file, so a NEW lane.sh can run
  # against an OLD `$O/spawn-gate.sh` that does not define AGENT_DISK_REFUSED — and under `set -u`
  # that aborts ABOVE the "NOT started" line, so the operator sees neither the refusal nor its
  # remedy. A pre-#1765 helper cannot return 77, so the default routes correctly to the load branch;
  # a pre-#2293 one cannot return 73 (the fork code — 74 is the LAND-BACKLOG code), so the fork
  # default routes to the load branch too.
  if [ "$rc" = "${AGENT_FORK_REFUSED:-73}" ]; then
    echo "[lane $N] NOT started: FORK gate refused — this box is out of PROCESSES (agent-infra#2293). Waiting cannot clear it and this box cannot start the retry: restart or drain it from OUTSIDE, or let its lanes finish and the issue be re-dispatched elsewhere." >> "$O/logs/lane-$N.log"
  elif [ "$rc" = "${AGENT_DISK_REFUSED:-77}" ]; then
    # ⛔ TWO CONDITIONS SHARE CODE 77 (review round 1, P2): below `DISK_MIN_FREE_MB`, AND above it but
    # without the headroom for one lane's tree (`DISK-NOHEADROOM`, agent-infra#2721). This line used to
    # claim only the first, so the operator grepping it was told the filesystem was full when the floor
    # had been MET — a false cause, and the same #1765 class (a remedy for the wrong condition) this
    # block exists to prevent. Both are named, and the refusing line above carries the numbers.
    echo "[lane $N] NOT started: DISK gate refused — either the filesystem is below DISK_MIN_FREE_MB, or it is above the floor but has no headroom for one lane's dependency tree (DISK-NOHEADROOM, agent-infra#2721). The '[disk-gate] REFUSED' line above says which, with both terms. Reclaim space (cloud-cell-supervisor.sh prune --caches; --scratch for /tmp) before re-dispatching; this will NOT clear by waiting." >> "$O/logs/lane-$N.log"
  elif [ "$rc" = "${AGENT_MEM_REFUSED:-81}" ]; then
    # ⛔ THE MEMORY GATE'S OWN NAME (#2387), for the disk branch's reason: an operator told "load"
    # watches a 1-min average that is fine while the OOM killer takes their lanes. The reading, the
    # floor and the arithmetic are on the `[mem-gate] REFUSED` line in the same log.
    echo "[lane $N] NOT started: MEMORY gate refused — available memory is below MEM_MIN_AVAIL_MB. This clears when resident lanes FINISH and release their working set; it will NOT clear by waiting for load. Issue returns to the pool. (The reading, the floor and how the floor was derived — a measured reserve, or an operator-set MEM_MIN_AVAIL_MB — are on the [mem-gate] REFUSED line in this log.)" >> "$O/logs/lane-$N.log"
  elif [ "$rc" = "${AGENT_LAND_BACKLOG:-74}" ]; then
    # ⛔ NAMED, AND NAMEABLE AS SOMETHING OTHER THAN CAPACITY (#1765's rule, applied to a gate whose
    # remedy is not on this box at all). An operator told "load gate" here waits for a box that is
    # already idle; the reading they need is the repo's open-PR count against its landing rate, which
    # is on the `[land-backlog] REFUSED` line in the same log.
    echo "[lane $N] NOT started: LAND-BACKLOG — the repo holds more open PRs than its own measured landing rate can absorb (#2409), so new creation is held. This is NOT a capacity refusal: the box is fine and waiting will not clear it. The work is the PR queue — review, rebase or land an open PR; a P0-blocker or a base-red repair is exempt by evidence. Issue returns to the pool." >> "$O/logs/lane-$N.log"
  elif [ "$rc" = "${AGENT_HARNESS_SKEW_REFUSED:-83}" ]; then
    # ⛔ NAMED, AND NAMED AS NOT-A-BOX-FAULT (follow-up review of #2991, P2, measured). The refusal is a
    # VERSION SKEW between this caller and the deployed `cell-lane-preflight.sh`, or a corrupt copy of
    # it — the harness's own files, identical on every box. The capability arm below would send the
    # operator to "repair this box (installed pi/extension set, provider credential) or dispatch the
    # issue to another box", and both are wrong here: the extension set is fine and the peer refuses
    # identically. The fix is one verified redeploy on every box that runs lanes.
    echo "[lane $N] NOT started: HARNESS/MISMATCH gate refused — this box's caller and its deployed cell-lane-preflight.sh do not agree (a usage/argument skew, or a corrupt copy), so the probe could not measure anything (agent-infra#2991), OR the spawn gate could not resolve capacity.sh at all (the fork resolver's `nodeploy` arm, agent-infra#2293 follow-up). This is NOT a property of this box and load has nothing to do with it: every box running the same pair refuses identically, so do NOT dispatch the issue to another box. Sync the helper pair with a VERIFIED redeploy — bash scripts/orchestrator-harness/deploy-harness.sh --repo . --o \$O — then re-dispatch. Nothing was consumed; the issue does not need re-authoring." >> "$O/logs/lane-$N.log"
  elif [ "$rc" = "${AGENT_STALE_CODE_REFUSED:-85}" ]; then
    # ⛔ NAMED, AND NAMED AS A CHECKOUT PROBLEM RATHER THAN A CAPACITY ONE (this change's review, P1-2).
    # Before this arm a stale-code refusal landed on the CAPABILITY text below — "repair this box's
    # installed pi/extension set or its provider credential, or dispatch the issue to another box" —
    # and all three remedies are wrong for it: the model call SUCCEEDED (that is how the reading was
    # taken), and the fleet was measured stale on every cell, so the peer refuses identically. Two
    # surfaces publishing contradictory instructions for one refusal is the harm this arm removes.
    # ⛔ AND THE REMEDY NAMES THE ARTIFACT THE READING CAME FROM (this change's review, P2-4): the probe
    # measures `$PWD` on THIS path (`WIP_PATH` is unset in lane.sh), which is the lane's own WORKTREE — a
    # base cut from origin/main. So the base remedy is right here, but it must be the BASE's advice and
    # say so, because the same refusal text is published on the FIXER path where the measured artifact is
    # a PR branch and re-cutting it would discard the PR (fix-one.sh's arm carries that shape).
    echo "[lane $N] NOT started: STALE-CODE gate refused — this box completed the model call but the checkout it measured is more than CELL_PREFLIGHT_MAX_BEHIND commits behind origin/main (agent-infra#3932), so a lane cut from it produces a plausible log and a WRONG diff: it re-derives what main already fixed, or reverts it. Waiting will NOT clear it and load has nothing to do with it, and do NOT dispatch the issue to another box — the measured fleet state was every cell hundreds of commits behind, so a peer is likely stale too. The repo and the distance are on the [capability-gate] REFUSED line in this log, and it names the checkout that was measured: advance THAT one — for a BASE checkout (this lane's worktree, or the shared checkout) `git -C <repo> pull --ff-only origin main` or the cell's own sync path; for a PR-BRANCH worktree integrate origin/main INTO the branch (`git -C <repo> merge origin/main`) and never re-cut one that carries commits. Nothing was consumed; the issue does not need re-authoring." >> "$O/logs/lane-$N.log"
  elif [ "$rc" = "${AGENT_CAPABILITY_REFUSED:-71}" ]; then
    # ⛔ NAMED, BECAUSE THE REMEDY IS THE ONE THING WAITING CANNOT BUY (review of #2991, P1). Without
    # this arm a capability refusal fell into the `else` below and the operator read "load gate refused
    # — issue returns to the queue", one line under the `[capability-gate] REFUSED` line saying the
    # opposite. The `[capability-gate]` line above names WHICH reading refused (a hang, an unreadable
    # key, no pi, an empty model pair) and therefore which repair applies; this line's job is to stop
    # the reader concluding that the queue will fix it.
    echo "[lane $N] NOT started: CAPABILITY gate refused — this box could not complete one model call and RETURN (agent-infra#2935). Waiting will NOT clear it and load has nothing to do with it: the [capability-gate] line above carries the reading it refused on, so repair THAT on this box (its installed pi/extension set, its provider credential) or dispatch the issue to another box. Nothing was consumed; the issue does not need re-authoring." >> "$O/logs/lane-$N.log"
  else
    echo "[lane $N] NOT started: load gate refused (see the line above) — issue returns to the queue" >> "$O/logs/lane-$N.log"
  fi
elif [ -n "${capacity_record:-}" ] && [ -f "$capacity_record" ]; then
  # A lane that actually ran SUPERSEDES an earlier refusal for the same issue, so the record is
  # cleared rather than left to make a LATER chain exit early: the epoch bound already protects
  # that chain, and this keeps the state directory from accumulating one stale file per issue.
  rm -f "$capacity_record" 2>/dev/null || true
fi
exit "$rc"
