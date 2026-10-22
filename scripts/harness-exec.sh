#!/usr/bin/env bash
# harness-exec — exec the harness THE PIN NAMES, or refuse. One entry for macOS and Linux.
#
#   ./scripts/harness-exec [--print] [--entry <rel>] [--pin-dir D] [--pin-file F] [--pin-sha-file F]
#
#   --print        resolution only: print the program and argv that WOULD run, exec nothing
#   --entry        entrypoint relative to the harness dir (default: orch-loop.sh)
#
# Exit: 0 exec'd/printed · 78 REFUSED (the pin could not be resolved, or the tree it names is not
#       the pin) · 64 usage.
#
# ── WHY THIS EXISTS (agent-infra#2231 / #2271) ───────────────────────────────────────────────────
# MEASURED on this Mac 2026-10-22: the launchd job `com.eldato.orchestrator-loop` execs
# `/Users/danielospina/orchestrator/launchd-controller.sh`, whose controller program is a COPY at
# `~/orchestrator/orch-loop.sh` — a directory that answers `git rev-parse --show-toplevel` with
# `fatal: not a git repository`. The cells exec `<pin root>/<sha12>/scripts/orchestrator-harness/…`,
# a detached worktree at the pinned commit. Three fixes made in one evening existed only in copies of
# the Mac's shape, and every instrument read the box as fine because nothing compared the directory
# the controller actually runs.
#
# ⛔ THE REFUSAL *IS* THE FEATURE. There is deliberately NO fallback: not `$O`, not `$HOME/orchestrator`,
# not "the checkout beside this script", not `origin/main`. A box whose pin cannot be resolved is a box
# that cannot say which commit it runs, and running an unpinned copy INSTEAD is the divergence this
# file exists to end. #2271 puts the same refusal at INSTALL time (refuse to render a plist whose
# program is not inside the pin); this is the RUNTIME half, so a box that later loses its pin stops
# instead of silently reverting to a copy.
#
# ⛔ ONE RESOLUTION, THE CELLS' OWN. The two records are the supervisor's (`HARNESS-PIN` names a
# COMMIT, `HARNESS_PIN_FILE` names the DIRECTORY the controller execs) and the layout check is the
# same one `harness-up`'s identity gate applies: the directory must be
# `<pin root>/<sha12>/scripts/orchestrator-harness`, where sha12 is the first 12 of the pinned commit.
# A re-pin that writes a worktree nobody reads (#2216) is therefore refused here rather than reported
# as success by the refresh.
#
# ⛔ PORTABILITY IS PART OF THE CONTRACT. No `timeout`/`gtimeout`, no `pgrep -c`, no `sed -i`, no
# `date -r`: every primitive that differs between macOS and Linux comes from `scripts/lib/box.sh`,
# which is the one shim both platforms use.

set -u
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/box.sh
. "$SELF/lib/box.sh" || { printf '[harness-exec] FATAL: %s/lib/box.sh missing — refusing to resolve a pin without the portability shim\n' "$SELF" >&2; exit 78; }

PRINT=0
ENTRY="orch-loop.sh"
PIN_DIR_ROOT="${HARNESS_PIN_DIR:-}"
PIN_DIR_FILE_OPT=""
PIN_SHA_FILE_OPT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --print) PRINT=1; shift ;;
    --entry) ENTRY="${2:-}"; shift 2 ;;
    --pin-dir) PIN_DIR_ROOT="${2:-}"; shift 2 ;;
    --pin-file) PIN_DIR_FILE_OPT="${2:-}"; shift 2 ;;
    --pin-sha-file) PIN_SHA_FILE_OPT="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf '[harness-exec] REFUSED — unknown argument %s\n' "$1" >&2; exit 64 ;;
  esac
done

refuse() { box_refuse 78 "$@"; exit 78; }

# ── the two records. Defaults are the supervisor's; `$HOME` is the box's own home, which is why this
# works unchanged on a cell (`HOME=$CELL_HOME`) and on the Mac.
PIN_SHA_FILE="${PIN_SHA_FILE_OPT:-${HARNESS_PIN:-$HOME/.pi/agent/state/HARNESS-PIN}}"
PIN_DIR_FILE="${PIN_DIR_FILE_OPT:-${HARNESS_PIN_FILE:-$HOME/.harness-path}}"

sha_state="$( [ -f "$PIN_SHA_FILE" ] && { [ -r "$PIN_SHA_FILE" ] && echo present || echo unreadable; } || echo absent )"
dir_state="$( [ -f "$PIN_DIR_FILE" ] && { [ -r "$PIN_DIR_FILE" ] && echo present || echo unreadable; } || echo absent )"

case "$sha_state" in
  unreadable) refuse "the pin COMMIT record $PIN_SHA_FILE exists but cannot be read, so which commit this box runs is UNKNOWN — nothing was executed. (Fix the record, or re-pin with harness-refresh.sh.)" ;;
esac
case "$dir_state" in
  unreadable) refuse "the pin DIR record $PIN_DIR_FILE exists but cannot be read, so WHICH TREE this box reads is unknown — nothing was executed." ;;
esac
if [ "$sha_state" = absent ] || [ "$dir_state" = absent ]; then
  refuse "this box has no pin: sha record=$PIN_SHA_FILE ($sha_state), dir record=$PIN_DIR_FILE ($dir_state). There is NO unpinned fallback by design (it is how a copy that main never received ran for weeks). Materialise the pin first: scripts/cloud-cell-supervisor.sh apply   (or scripts/harness-refresh.sh on a box that already has one)."
fi

PIN_SHA="$(head -1 "$PIN_SHA_FILE" 2>/dev/null | tr -d ' \t\r\n')"
PIN_DIR="$(head -1 "$PIN_DIR_FILE" 2>/dev/null | tr -d '\r\n')"
[ -n "$PIN_SHA" ] || refuse "the pin COMMIT record $PIN_SHA_FILE is EMPTY — an empty pin is not 'current', it is unanswerable. Re-pin it."
[ -n "$PIN_DIR" ] || refuse "the pin DIR record $PIN_DIR_FILE is EMPTY — the controller would have no tree to exec. Re-pin it."
PIN_DIR="${PIN_DIR%/}"

case "$PIN_SHA" in
  *[!0-9a-f]*) refuse "the pin COMMIT record $PIN_SHA_FILE holds '$PIN_SHA', which is not a commit id (a record holding something else is not a pin)." ;;
esac
[ "${#PIN_SHA}" -ge 7 ] || refuse "the pin COMMIT record $PIN_SHA_FILE holds '$PIN_SHA', too short to identify a commit."

SHA12="$(printf '%s' "$PIN_SHA" | cut -c1-12)"
[ -d "$PIN_DIR" ] || refuse "the pin DIR record $PIN_DIR_FILE names '$PIN_DIR', which is not a directory (pruned worktree, or a stale record). Re-materialise it: scripts/cloud-cell-supervisor.sh apply --pin-only"
[ -r "$PIN_DIR" ] && [ -x "$PIN_DIR" ] || refuse "the pin DIR record names '$PIN_DIR', which cannot be entered — cannot-verify is not a pass here."

# ⛔ NOT A CHECKOUT IS THE MEASURED FAILURE, not a nicety: `~/orchestrator` answers
# `git rev-parse --show-toplevel` with `fatal: not a git repository`, so a copy is indistinguishable
# from a pin unless this is asked.
# ⛔ THE DIR RECORD NAMES THE HARNESS DIRECTORY, NOT THE PIN TREE ROOT. On a cell it is
# `<pin root>/<sha12>/scripts/orchestrator-harness` (the supervisor's own record), so the checkout is
# an ANCESTOR of it: resolving `--show-toplevel` from the recorded dir is what makes the record
# self-checking — a record pointing at a home-dir copy answers "not a git repository".
TOP="$(git -C "$PIN_DIR" rev-parse --show-toplevel 2>/dev/null)"
[ -n "$TOP" ] \
  || refuse "the pin DIR record names '$PIN_DIR', which is NOT a git checkout — that is the 'copy of a script this repo carries' shape (#2231's worst row), never a pin."
TOP="$(cd "$TOP" && pwd -P)" || refuse "the checkout containing '$PIN_DIR' cannot be resolved to a real path — cannot-verify is not a pass."
PIN_DIR_REAL="$(cd "$PIN_DIR" && pwd -P)" || refuse "the pin DIR record names '$PIN_DIR', which cannot be resolved to a real path."
case "$PIN_DIR_REAL" in
  "$TOP"|"$TOP"/*) : ;;
  *) refuse "the pin DIR record names '$PIN_DIR' but its checkout is '$TOP' — the record does not live inside the tree it claims, so the pin is not what would run." ;;
esac

HEAD_SHA="$(git -C "$TOP" rev-parse HEAD 2>/dev/null)"
[ -n "$HEAD_SHA" ] \
  || refuse "the checkout at '$TOP' has a HEAD that cannot be read — cannot-verify is never a pass."
case "$HEAD_SHA" in
  "$PIN_SHA"*) : ;;
  *) refuse "the two pin records DISAGREE: $PIN_SHA_FILE says commit $PIN_SHA, $PIN_DIR_FILE names a tree at $HEAD_SHA. A refresh that wrote one and not the other is #2216's shape; nothing was executed." ;;
esac

# The layout check, identical to harness-up's identity gate: the checkout IS <pin root>/<sha12> and
# the harness dir is its scripts/orchestrator-harness.
if [ -n "$PIN_DIR_ROOT" ]; then
  ROOT="${PIN_DIR_ROOT%/}"
  ROOT="$(cd "$ROOT" 2>/dev/null && pwd -P)"
  [ -n "$ROOT" ] || refuse "the pin root '$PIN_DIR_ROOT' cannot be resolved, so whether the recorded tree belongs to it is UNKNOWN — nothing was executed."
  WANT="$ROOT/$SHA12"
  [ "$TOP" = "$WANT" ] \
    || refuse "the tree the pin DIR record names is '$TOP' but the pin root resolves commit $SHA12 to '$WANT' — a re-pin into a worktree nobody reads (#2216). Nothing was executed."
  [ "$PIN_DIR_REAL" = "$WANT/scripts/orchestrator-harness" ] \
    || refuse "the pin DIR record names '$PIN_DIR_REAL', which is not the harness directory '$WANT/scripts/orchestrator-harness' of the pinned tree — the record and the layout disagree."
fi

ENTRY_PATH="$PIN_DIR/${ENTRY#./}"
[ -f "$ENTRY_PATH" ] || refuse "the pin (commit $SHA12, tree $PIN_DIR) does NOT carry '$ENTRY'. The tree that would run is not the harness the pin names."
[ -r "$ENTRY_PATH" ] || refuse "the pin carries '$ENTRY' at $ENTRY_PATH but it cannot be read — cannot-verify is not a pass."

if [ "$PRINT" = "1" ]; then
  printf 'pin_sha=%s\npin_dir=%s\nprogram=%s\nprovenance=%s\n' \
    "$PIN_SHA" "$PIN_DIR" "$ENTRY_PATH" "$(box_provenance)"
  exit 0
fi

# ⛔ `exec`, so the pid a supervisor holds IS the harness — a wrapper that forked would make the pid
# a lie to every liveness reader, and liveness here is a process-table reading.
exec /bin/bash "$ENTRY_PATH"
