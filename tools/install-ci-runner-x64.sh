#!/usr/bin/env bash
# install-ci-runner-x64.sh — the ADD path of runner_autoscale.py, delegating to the ONE pool tool.
#
# WHY THIS FILE EXISTS
#   `scripts/orchestrator-harness/runner_autoscale.py` resolves a provisioner and refuses to add a
#   runner without one ("improvising a provisioner here is how a second, divergent registration path
#   is born" — #9639). It looks for exactly this path (candidate 2 of `resolve_provisioner`, then
#   PINNED into the unit's `Environment=` by `--install-unit`). The path was never committed — `git
#   log --all -- '*install-ci-runner-x64.sh'` is empty — so on every box the add arm recorded
#   `no provisioner` → action-failed on every pass where live < target, and the pool could only ever
#   shrink back to whatever installs history left behind (measured 2026-11-05: agent-infra#3469,
#   cells capped at 20-21 slots for 46 open PRs).
#
#   The CAPABILITY was not missing. `scripts/ci_runner_pool.sh` already provisions runners: it does
#   the `config.sh` registration, holds the owner's memory-floor predicate (#2344: refuse to add
#   below a stated floor AND print the reading used), reclaims registrations GitHub deleted, and
#   sweeps dead listeners. What was missing is that the two tools never spoke: the python tool cannot
#   add, the bash tool has no caller. THIS FILE IS THE JOIN, NOT A THIRD IMPLEMENTATION.
#
#   ⛔ No download, no sha256, no `config.sh` argv, no registration-token handling lives here. Every
#   one of those belongs to ci_runner_pool.sh, which is the only thing in this repo that may touch a
#   live registration. An adapter that grew its own install logic would rebuild #9639 in a new file.
#
# CONTRACT — READ FROM THE CALLER, NOT INVENTED HERE (runner_autoscale.py, cited by symbol because
# line numbers rot). Four facts decide everything below; each one was wrong in an earlier draft of
# this file, and each one is a way to provision runners the caller cannot count.
#
#   1. ARGV — `provision()` runs exactly:
#        bash install-ci-runner-x64.sh --count <N> --fallback auto        (timeout 1800)
#
#   2. `--count N` IS A SLOT INDEX, NOT A TOTAL. The caller computes `_next_free_slot(root)` — "the
#      first free slot in the provisioner's own numbering: base, base-2, base-3, …" — and passes THAT
#      NUMBER. "Occupied" is `.runner` present, not the path existing, precisely so that "one call =
#      one addition" holds for the ceiling arithmetic. So this file adds AT MOST ONE install: the one
#      `N` names. Sweeping a range would put several runners on a box whose per-step memory/disk
#      re-read the caller performs between calls was budgeted for one; filling gaps is `reconcile`'s
#      job, not this adapter's.
#
#   3. THE INSTALL MUST BE VISIBLE TO THE CALLER: `discover()` enumerates `<root>/gh-runner*` holding
#      a `.runner`, `--root` defaults to `/opt` (or `RUNNER_AUTOSCALE_RUNNER_ROOT`), and the numbering
#      base is `RUNNER_AUTOSCALE_BASE` or `<root>/gh-runner-x64`. `provision()` passes NO root, so
#      this file must land on the same root AND the same base the caller reads. A different root, or
#      a name outside `gh-runner*`, is a FALSE PASS: every pass reports `provisioned …` while `live`
#      never moves and the box never grows. (Also why `RUNNER_ROOT` is EXPORTED below: the pool tool
#      is a child and reads it from its env.)
#
#   4. EXIT CODES, in the caller's own words — and the pool tool's are NOT this file's:
#        rc 0  → `provisioned to <N>: <last line of the merged stream>` — the pass RECORD's text is
#                the LAST LINE OF STDOUT+STDERR MERGED (`_run` concatenates stdout then stderr), so
#                ⛔ NOTHING MAY BE WRITTEN TO STDERR ON THE SUCCESS PATH, or the record quotes an
#                advisory instead of the accounting. (That is the defect `_run_split`'s docstring
#                records: one stderr warning turned a successful read into a rejected value.)
#        rc 2  → `ProvisionerRefused` — "GUARD REFUSED, nothing attempted". An ANSWER, reported as
#                the box's own deliberate no, not as a failure on a 10-minute timer.
#        other → `ActionFailed`, with this file's output as the reason.
#      The pool tool reports its gate verdicts as rc 3 (`REFUSED add … nothing added`: the memory
#      floor and the core-aware ceiling), rc 2 for `cannot-measure`/`cannot-act`, rc 4 for a taken
#      name, rc 5 for a name that could not be registered. So BOTH 2 AND 3 are refusals to this
#      file — mapping only 2 was the bug that recorded a correct memory-floor refusal from a box at
#      its ceiling (the #3469 shape, the COMMON case) as a hard failure every pass. 4 and 5 stay
#      failures: a box state and a name condition are things the caller's repair path must see.
#
#   `--fallback auto` is accepted and is the ONLY accepted value: it means "let ci_runner_pool.sh
#   resolve its own template/kernel/arch", which is what it already does. Passing anything else is
#   refused rather than silently ignored, because a caller that asked for a specific strategy and got
#   `auto` has been lied to.
set -uo pipefail

HERE=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd) || exit 1
POOL_TOOL=${CI_RUNNER_POOL_TOOL:-$HERE/../scripts/ci_runner_pool.sh}
COUNT=""
FALLBACK=""
DRY=0

err() { printf 'install-ci-runner-x64: %s\n' "$*" >&2; }

usage() {
  cat >&2 <<'EOF'
usage: install-ci-runner-x64.sh --count <N> --fallback auto [--dry-run]
  --count N        the SLOT INDEX to add (runner_autoscale.py's _next_free_slot: 1 -> <base>,
                   N>1 -> <base>-N). At most ONE install is added; existing slots are skipped.
  --fallback auto  the only accepted strategy: the pool tool resolves template/arch itself
  --dry-run        report what would be added, change nothing
Root/base default to the caller's own (RUNNER_AUTOSCALE_RUNNER_ROOT or /opt; RUNNER_AUTOSCALE_BASE
or <root>/gh-runner-x64) because that is where runner_autoscale.py looks for installs.
exit 2 is a GUARD REFUSAL (nothing attempted), not a failure — see the header of
scripts/ci_runner_pool.sh for the predicates that decline.
EOF
  exit 1
}

# is_uint — the same operand guard the pool tool applies, for the same reason: an unvalidated count
# reaches arithmetic, and under `set -u` (no -e) a bash arithmetic ERROR inside an `if` reads as
# FALSE, so a typo would silently disable the loop instead of failing it. Leading zeros are refused:
# `08` is fatal to bash arithmetic and `010` means eight.
is_uint() {
  local v="${1:-}"
  case "$v" in ''|*[!0-9]*|0|0?*) return 1 ;; esac
  [ "${#v}" -le 6 ] || return 1
  return 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --count)    shift; COUNT="${1:-}" ;;
    --count=*)  COUNT="${1#*=}" ;;
    --fallback) shift; FALLBACK="${1:-}" ;;
    --fallback=*) FALLBACK="${1#*=}" ;;
    --dry-run)  DRY=1 ;;
    -h|--help)  usage ;;
    *) err "unknown argument: $1"; usage ;;
  esac
  shift
done

[ -n "$COUNT" ] || { err "--count is required"; usage; }
is_uint "$COUNT" || { err "cannot-measure why=count-not-a-positive-integer value=${COUNT}"; exit 2; }
[ -n "$FALLBACK" ] || { err "--fallback is required (only 'auto' is accepted)"; usage; }
[ "$FALLBACK" = auto ] || { err "unsupported --fallback '$FALLBACK' (only 'auto')"; usage; }

# ⛔ THE POOL TOOL MUST BE READABLE, and its absence is a REFUSAL, never a silent success. This is
# the failure mode that started it all: a provisioner path that does not resolve, on a box whose
# caller then believes it provisioned. Exit 2 puts it in the caller's `provisioner-refused` arm with
# this sentence as the reason, so the next reader sees WHICH path was missing.
if [ ! -r "$POOL_TOOL" ]; then
  err "cannot-measure why=pool-tool-unreadable path=$POOL_TOOL (point CI_RUNNER_POOL_TOOL at scripts/ci_runner_pool.sh)"
  exit 2
fi

# ── the root: the CALLER's, or the install is invisible (contract fact 3) ────────────────────────
ROOT_CALLER=${RUNNER_AUTOSCALE_RUNNER_ROOT:-/opt}
if [ -n "${RUNNER_ROOT:-}" ] && [ "${RUNNER_ROOT%/}" != "${ROOT_CALLER%/}" ]; then
  err "cannot-measure why=root-disagreement RUNNER_ROOT=$RUNNER_ROOT RUNNER_AUTOSCALE_RUNNER_ROOT=$ROOT_CALLER — the caller inventories <root>/gh-runner*, so an install under one root while the caller reads the other can never be counted; set both to the same path (or unset one)"
  exit 2
fi
RUNNER_ROOT=${RUNNER_ROOT:-$ROOT_CALLER}
RUNNER_ROOT=${RUNNER_ROOT%/}; [ -n "$RUNNER_ROOT" ] || RUNNER_ROOT=/
# EXPORTED: ci_runner_pool.sh is a CHILD and reads RUNNER_ROOT from its env — unexported, it falls
# back to its own `/tmp/actions-runner` default and installs somewhere this file never looks.
export RUNNER_ROOT

# ── the base and the slot NAME: `_next_free_slot`'s numbering, not ours (contract facts 2 and 3) ──
BASE=${RUNNER_AUTOSCALE_BASE:-$RUNNER_ROOT/gh-runner-x64}
BASE=${BASE%/}
case "$BASE" in
  /*) ;;
  *) err "cannot-measure why=base-not-absolute base=$BASE (RUNNER_AUTOSCALE_BASE must be an absolute path)"; exit 2 ;;
esac
BASE_PARENT=${BASE%/*}; [ -n "$BASE_PARENT" ] || BASE_PARENT=/
[ "$BASE_PARENT" = "$RUNNER_ROOT" ] || {
  err "cannot-measure why=base-outside-root base=$BASE root=$RUNNER_ROOT — the caller inventories <root>/gh-runner*, so an install outside that root is uncountable; set RUNNER_AUTOSCALE_BASE under RUNNER_ROOT"
  exit 2
}
BASE_NAME=${BASE##*/}
case "$BASE_NAME" in
  gh-runner*) ;;
  *) err "cannot-measure why=base-not-discoverable base=$BASE — the caller inventories <root>/gh-runner* (discover()), so an install named '$BASE_NAME' would never be counted; name it gh-runner-<something>"; exit 2 ;;
esac

if [ "$COUNT" -eq 1 ]; then NAME=$BASE_NAME; else NAME=$BASE_NAME-$COUNT; fi
DIR=$RUNNER_ROOT/$NAME

# The caller's OWN occupancy predicate is `(<slot>/.runner).exists()`, so it is `-e` here too (a
# symlinked install counts as present to the caller). Skipping is a SUCCESS: the slot the caller asked
# for is already there, and adding a second install over it is the #9639 over-fill.
if [ -e "$DIR/.runner" ]; then
  printf 'provisioned slot=%s name=%s root=%s added=0 skipped=1 already-registered\n' \
    "$COUNT" "$NAME" "$RUNNER_ROOT"
  exit 0
fi

args=(add --name "$NAME")
[ "$DRY" -eq 1 ] && args+=(--dry-run)
out=$(bash "$POOL_TOOL" "${args[@]}" 2>&1); rc=$?
case "$rc" in
  0) ;;
  2|3) # The pool tool declined and changed nothing: rc 2 = cannot-measure/cannot-act, rc 3 = its own
       # gate verdict (memory floor, core-aware ceiling). Both are ANSWERS — propagate the refusal
       # WITH its reading, so the caller's record carries `why=memory-floor value=…`, not a bare rc,
       # and reports `provisioner-refused` instead of a failure on every 10-minute pass.
       printf '%s\n' "$out" | tail -3 >&2
       err "guard-refused by pool tool for slot $COUNT name=$NAME (nothing further attempted)"
       exit 2 ;;
  *)   # rc 4 (name taken), rc 5 (this name could not be registered) and anything unexpected are real
       # failures: the caller's repair/reclaim path must see them, not a refusal it would sit on.
       printf '%s\n' "$out" | tail -5 >&2
       err "pool tool failed for slot $COUNT name=$NAME rc=$rc"
       exit "$rc" ;;
esac

# ⛔ THIS ONE LINE IS THE PASS RECORD. The caller copies the LAST line of the MERGED stdout+stderr
# into `provisioned to <N>: <that line>`, so it must state the reading (slot, name, root, whether
# anything was added) rather than a verdict adjective — a reader six hours later needs the number and
# the path. The pool tool's own final line is folded IN here, never written to stderr after this
# printf, because stderr sorts after stdout in the merged stream and would become the recorded text.
last=$(printf '%s' "$out" | tail -1 | cut -c1-90)
if [ "$DRY" -eq 1 ]; then
  printf 'would-provision slot=%s name=%s root=%s added=0 pool=%s\n' \
    "$COUNT" "$NAME" "$RUNNER_ROOT" "$last"
else
  printf 'provisioned slot=%s name=%s root=%s added=1 skipped=0 pool=%s\n' \
    "$COUNT" "$NAME" "$RUNNER_ROOT" "$last"
fi
exit 0
