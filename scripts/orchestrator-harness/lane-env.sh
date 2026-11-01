#!/usr/bin/env bash
# lane-env.sh — the lane's own credentials (agent-infra#3060). ⛔ SOURCE THIS AT TOP LEVEL; it is a snippet,
# not a function-callable library, and that is the whole point (see WHY, below).
#
# Callers set two variables and dot it:
#     LANE_ENV_LOG="$O/logs/lane-$N.log" LANE_ENV_LABEL="lane $N" . "$SELF/lane-env.sh"
#
# WHY THIS EXISTS
# ───────────────
# Measured on a cell, 2026-10-29. A hand-dispatched lane passed every gate — `[repo-target] … check=ok`,
# `[land-backlog] EXEMPT … P0 work`, `[capability-gate] LANE_CAPABILITY=ok answered_ms=6027
# returned_ms=6030`, `[health-check] 31/31 extensions loaded` — started `pi`, and died in SEVEN SECONDS:
#
#     No API key found for deepseek.
#
# The keys were on the box the whole time (`keys.env`), because that is where the CONTROLLER reads them:
# `cloud-cell-supervisor.sh` sources `${ENV_FILE:-$CELL_HOME/keys.env}` and every lane it spawns inherits
# them. A lane started any other way — an operator, a repair script, a re-dispatch after a restart —
# inherits NOTHING. And the capability gate cannot catch it: that gate sources the key file itself to make
# its probe call, so it reports `key=env`/`ok` while the lane it is gating has no key at all.
#
# ⛔ WHY A TOP-LEVEL SNIPPET AND NOT A FUNCTION — three verifier rounds, three defects, one root
# ──────────────────────────────────────────────────────────────────────────────────────────────────
# Wrapping this in a FUNCTION and then trying to make its effect survive the return produced a new defect
# each round, because `. file` inside a function is not `. file`:
#   1. `declare -x NAME=value` — exactly what `export -p > keys.env` writes — is FUNCTION scoped and
#      evaporated on return. A keys file in that shape was emptied while the log said "sourced".
#   2. Fixing that by rewriting the file's lines with sed was QUOTE-BLIND: `LANE_DSN="host=x; OPTS=1"`
#      became `host=x; export OPTS=1` — the value corrupted.
#   3. Fixing THAT by replaying `export -p` with a line-start transform (`declare -x ` → `export `) still
#      rewrote values, because `export -p` prints a MULTI-LINE value as several physical lines: a
#      continuation line that happens to start with `declare -x NAME=` got an `export` spliced into the
#      value.
# The lesson is not "find a cleverer rewrite". It is that **any** rewrite of the shell's own
# serialisation is a source of divergence from the controller, which simply does `. file`. So this does
# exactly what the controller does, at the only scope where it means the same thing: TOP LEVEL. No
# rewriting, no temp file, no quoting to get wrong, no divergence.
#
# PRECEDENCE: the file wins, exactly as on the controller path (it sources the file after inheriting its
# environment). An override belongs in the file, or after the lane has sourced it.
#
# ⛔ EXCEPTION — THE DISPATCH-OWNED SET: `OR` (the target repo), `N` (the issue), `BR` (the branch),
# `LANE_REPO_DIR` and `O` (where the lane records). Those are ARGUMENTS the lane was dispatched with, not
# credentials, and `lane.sh` saves and restores them around this sourcing. A cell's `keys.env` carries the
# CONTROLLER's `export OR=<owner/name>` — written for loops that mean it — and sourced here it silently
# replaced the target the LANE was dispatched for, so the repo assertion compared the worktree against
# the wrong repo and refused a correct dispatch (agent-infra#3174). The precedent is
# `scripts/pr-repair-loop.sh`: "`keys.env` remains authoritative for CREDENTIALS … it may not move WHAT
# this box repairs or WHERE it records that". ⛔ Do NOT "simplify" the save/restore in `lane.sh` away as
# redundant — this paragraph is the only record that the exception is deliberate.

_lane_env_file="${ENV_FILE:-${HOME:-/nonexistent}/keys.env}"
_lane_env_log="${LANE_ENV_LOG:-}"
_lane_env_label="${LANE_ENV_LABEL:-lane}"

_lane_env_emit() { # <line>
  # ⛔ A DRY RUN WRITES NOTHING TO STDERR — `lane.sh`'s own contract, stated at its `GP_QUIET` line and
  # asserted by `reviewer-preflight.test.sh` §C. This snippet is dotted in UNCONDITIONALLY, so writing
  # the status line to stderr here broke that contract for every dry run (#3060 reddened the shard with
  # `the dry run writes nothing to stderr`). The line is still RECORDED — it is a credential disclosure
  # an operator needs, so it goes to the lane LOG — only the human-facing stderr copy is suppressed, the
  # same way `gate-policy.sh`'s decision line is suppressed under `GP_QUIET`.
  if [ "${LANE_DRY_RUN:-0}" = "1" ]; then
    [ -n "$_lane_env_log" ] && printf '%s\n' "$1" >> "$_lane_env_log"
    return 0
  fi
  if [ -n "$_lane_env_log" ]; then
    printf '%s\n' "$1" | tee -a "$_lane_env_log" >&2
  else
    printf '%s\n' "$1" >&2
  fi
}

if [ ! -f "$_lane_env_file" ] || [ ! -r "$_lane_env_file" ]; then
  # Not fatal: a box whose credentials arrive from the ambient environment is legitimate (that is how a
  # controller-spawned lane works). Named, so the 7-second death above is a grep and not an investigation.
  _lane_env_emit "[$_lane_env_label] env: no readable $_lane_env_file — relying on the inherited environment for credentials"
else
  _lane_env_pairs="$(grep -cE '^[[:space:]]*(export|declare([[:space:]]+-[a-zA-Z]+)*|readonly|typeset([[:space:]]+-[a-zA-Z]+)*)?[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=' "$_lane_env_file" 2>/dev/null || true)"
  # the caller's own allexport state is restored, because turning it OFF is as much a side effect as on
  case "$-" in *a*) _lane_env_had_a=1 ;; *) _lane_env_had_a=0 ;; esac
  set -a
  # shellcheck disable=SC1090
  . "$_lane_env_file"
  _lane_env_rc=$?
  [ "$_lane_env_had_a" = "1" ] || set +a
  _lane_env_after="$(export -p 2>/dev/null | grep -c '^[[:space:]]*\(export\|declare -x\)[[:space:]]' || true)"
  if [ "$_lane_env_rc" -ne 0 ]; then
    # ⛔ A FILE THAT DOES NOT PARSE MUST NOT REPORT SUCCESS. `.` returns non-zero on a syntax error, and
    # everything after the failing line is MISSING — a lane that then dies 7 seconds later would send the
    # reader to the provider instead of to the file.
    _lane_env_emit "[$_lane_env_label] env: SOURCED WITH ERRORS from $_lane_env_file (rc=$_lane_env_rc, ${_lane_env_pairs:-0} assignment(s) in the file, ${_lane_env_after:-0} exported now) — everything after the failing line is MISSING; fix the file or the lane runs without those credentials"
  else
    _lane_env_emit "[$_lane_env_label] env: sourced $_lane_env_file (${_lane_env_pairs:-0} assignment(s) in the file, ${_lane_env_after:-0} exported now) — a lane started outside the controller otherwise inherits no credentials"
  fi
fi
unset _lane_env_file _lane_env_log _lane_env_label _lane_env_pairs _lane_env_after _lane_env_rc _lane_env_had_a
