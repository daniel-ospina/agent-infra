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
# ⛔ WHEN THE PIN ROOT IS UNSET, CONTAINMENT IS STILL PROVEN — from the records' own layout. A
# conditional check was the defect a review caught: `HARNESS_PIN_DIR` is exported by `harness-up` and
# the cell supervisor, and NOTHING exports it on a Mac, so the default path skipped the one check that
# catches #2216's "re-pin into a worktree nobody reads". Absent the root, the tree must still be named
# after the pinned commit (`<anything>/<sha12>`), and a tree that is not is REFUSED rather than trusted.
WANT_ROOT=""
if [ -n "$PIN_DIR_ROOT" ]; then
  ROOT="${PIN_DIR_ROOT%/}"
  ROOT="$(cd "$ROOT" 2>/dev/null && pwd -P)"
  [ -n "$ROOT" ] || refuse "the pin root '$PIN_DIR_ROOT' cannot be resolved, so whether the recorded tree belongs to it is UNKNOWN — nothing was executed."
  WANT_ROOT="$ROOT/$SHA12"
else
  WANT_ROOT="$(dirname "$TOP")/$SHA12"
fi
[ "$TOP" = "$WANT_ROOT" ] \
  || refuse "the tree the pin DIR record names is '$TOP' but the pin layout for commit $SHA12 is '$WANT_ROOT' — a re-pin into a worktree nobody reads (#2216). Nothing was executed."
[ "$PIN_DIR_REAL" = "$WANT_ROOT/scripts/orchestrator-harness" ] \
  || refuse "the pin DIR record names '$PIN_DIR_REAL', which is not the harness directory '$WANT_ROOT/scripts/orchestrator-harness' of the pinned tree — the record and the layout disagree."

ENTRY_PATH="$PIN_DIR/${ENTRY#./}"
# ⛔ THE ENTRY MAY NOT ESCAPE THE PIN. `--entry ../../../evil.sh` used to resolve outside the tree and
# be accepted (found by review): the shim exists so the box runs THE PIN, and an entrypoint that walks
# out of it is not the pin. Rejected on shape first (a `..` segment or an absolute path), then by
# REALPATH containment, so a symlink inside the harness dir cannot redirect the exec either.
case "/$ENTRY/" in
  */../*) refuse "--entry '$ENTRY' contains a '..' segment — an entrypoint that leaves the pinned tree is not the pin." ;;
esac
case "$ENTRY" in
  /*) refuse "--entry '$ENTRY' is absolute — the entrypoint is relative to the pinned harness directory." ;;
esac
[ -f "$ENTRY_PATH" ] || refuse "the pin (commit $SHA12, tree $PIN_DIR) does NOT carry '$ENTRY'. The tree that would run is not the harness the pin names."
[ -r "$ENTRY_PATH" ] || refuse "the pin carries '$ENTRY' at $ENTRY_PATH but it cannot be read — cannot-verify is not a pass."
# ⛔ THE FILE'S OWN REALPATH, not `dirname` + basename: `cd`-ing to the parent resolves the DIRECTORY
# and then re-appends the (possibly symlinked) NAME, so a symlink in the harness dir sailed through
# (found by review, reproduced by arm 13). Perl's Cwd::abs_path resolves the FINAL component too, and
# perl is on both platforms (the repo already bounds commands with `perl -e 'alarm…'`).
command -v perl >/dev/null 2>&1 \
  || refuse "perl is not on PATH, so '$ENTRY_PATH' cannot be resolved to a real path — this is a MISSING TOOL, not a symlink bug (the pin itself may be fine). Install perl, or run the resolver on a box that has it."
ENTRY_REAL="$(perl -MCwd -e 'my $p = Cwd::abs_path($ARGV[0]); print defined $p ? $p : "";' "$ENTRY_PATH" 2>/dev/null)"
[ -n "$ENTRY_REAL" ] || refuse "'$ENTRY_PATH' cannot be resolved to a real path — cannot-verify is not a pass."
case "$ENTRY_REAL" in
  "$TOP"/*) : ;;
  *) refuse "'$ENTRY_PATH' resolves to '$ENTRY_REAL', which is OUTSIDE the pinned tree '$TOP' (a symlink out of the pin) — nothing was executed." ;;
esac

# ⛔ A DIRTY PIN IS NOT THE PIN. A clean detached worktree is what a cell materialises, and an
# uncommitted edit inside one runs bytes the record does not name — #2231's own failure mode, one layer
# in. Scoped to the harness directory so an unrelated dirty path elsewhere in the tree cannot block.
# Checked AFTER the entry containment so each refusal names its own cause (a symlink added for the
# containment arm must not report as "dirty" and hide which rule fired).
#
# ⛔ THE PREDICATE IS NOT WRITTEN HERE. `pin_dirty` in lib/box.sh is the ONE implementation, because the
# cell supervisor's DRIFT check and the provenance stamp read the same state and, for one review round,
# read it with a weaker predicate: `check` certified a pin CLEAN that this resolver refused and `apply`
# never repaired (round 4). It covers the gitignored hotfix (`--entry tmp/x.sh` used to pass: `tmp/`,
# `dist/`, `*.log` cannot be committed and plain `--porcelain` reports nothing for them) and tolerates
# the `​.DS_Store`/`._*` droppings the pin-root guard already ruled must not brick a cell.
DIRTY="$(pin_dirty "$TOP" "$PIN_DIR_REAL")"; DRCF=$?
case "$DRCF" in 0|1|2) : ;; *)
  refuse "pin_dirty answered rc=$DRCF on '$TOP' — an unexpected verdict is cannot-verify, which is never a pass. Nothing was executed." ;;
esac
[ "$DRCF" -ne 2 ] \
  || refuse "git status failed on '$TOP' (cannot-verify), so whether the pinned harness dir is clean is UNKNOWN — cannot-verify is never a pass here. Nothing was executed."
[ "$DRCF" -ne 1 ] \
  || refuse "the pinned tree at '$TOP' has UNCOMMITTED CHANGES under $(basename "$PIN_DIR_REAL") ($(printf '%s' "$DIRTY" | head -3 | tr '\n' ' ')) — the bytes that would run are not commit $SHA12. Nothing was executed."

if [ "$PRINT" = "1" ]; then
  printf 'pin_sha=%s\npin_dir=%s\nprogram=%s\nprovenance=%s\n' \
    "$PIN_SHA" "$PIN_DIR" "$ENTRY_PATH" "$(box_provenance)"
  exit 0
fi

# ⛔ `exec`, so the pid a supervisor holds IS the harness — a wrapper that forked would make the pid
# a lie to every liveness reader, and liveness here is a process-table reading.
exec /bin/bash "$ENTRY_PATH"
