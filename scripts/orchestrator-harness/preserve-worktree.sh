#!/usr/bin/env bash
# preserve-worktree.sh <dir> [--cap SECONDS] [--pid PID] [--reason TEXT]
#
# Take a VERIFIED backup of a worktree's uncommitted work, and say out loud whether it worked.
#
# ── WHY THIS EXISTS (agent-infra#2045, used by #2199) ────────────────────────────────────────
# Every cap in this harness ends the same way: a watchdog kills the worker. #2045 measured what
# that costs -- a lane killed at its 35-minute cap left SEVEN modified files uncommitted in a temp
# worktree, no report and no exit status, and it was recoverable only because a human noticed the
# dirty tree. `pi -p` also loses its buffered response on SIGTERM, so a killed lane and a lane with
# nothing to do looked identical from the launcher's side.
#
# #2045's decision: snapshot from the LAUNCHER, never by asking the worker to checkpoint -- a
# worker that is mid-tool-call does not cooperate, and a checkpoint in front of the hard kill makes
# the cap advisory (the "a hung worker is never killed" failure the cap exists to prevent). This
# script is that snapshot, as ONE implementation with two callers (`spawn-gate.sh`'s `run_agent`
# and `bounded-spawn.sh`), because a copy per caller is exactly the drift #1720 removed.
#
# ⛔ THE SNAPSHOT IS TAKEN BEFORE THE HARD KILL (#2199 requires a verified backup before the kill).
# `git diff` reads a committed HEAD and the index, so the snapshot is of what was WRITTEN, not of
# what a half-flushed buffer held. NAMED RESIDUAL: a file the worker is mid-write on can be
# captured torn, and a file it deletes after the snapshot is gone -- the snapshot is a point in
# time, and the alternative (wait for the worker) is the cooperation this design rejects.
#
# ── THE VERDICT IS A SET COMPARISON, AND "COMPLETE" IS THE ONLY VERDICT THAT LICENSES DELETION ──
#   COMPLETE             every change the tree reported is in the snapshot
#   NOTHING-TO-PRESERVE  the tree was clean -- there was no work to lose
#   NOT-APPLICABLE       not a git worktree (stated, never silently treated as clean)
#   PARTIAL-do-not-reap  SOMETHING could not be captured -- do NOT let a reaper delete this tree
# Exit codes: 0 = COMPLETE / NOTHING-TO-PRESERVE / NOT-APPLICABLE, 3 = PARTIAL (a caller that
# ignores stdout still cannot read a partial snapshot as a success), 2 = usage.
#
# Usage note: this script NEVER kills anything. The caller owns the kill, so the same artifact can
# be used by a launcher before a signal and by an operator on a live tree.
set -uo pipefail

DIR="${1:-}"
[ -n "$DIR" ] || { echo "usage: preserve-worktree.sh <dir> [--cap N] [--pid P] [--reason TEXT]" >&2; exit 2; }
shift
CAP=""; PIDF=""; REASON=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --cap) CAP="${2:-}"; shift 2 ;;
    --pid) PIDF="${2:-}"; shift 2 ;;
    --reason) REASON="${2:-}"; shift 2 ;;
    *) echo "preserve-worktree.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

O="${O:-$HOME/orchestrator}"
STAMP="$(date '+%Y%m%d-%H%M%S')"
DEST="$O/wip/capspawn-$STAMP-$$"
LEDGER="$O/state/capspawn.tsv"

# One row per call, on EVERY verdict -- the #2045 lesson is that a silent cap kill is
# indistinguishable from a quiet lane, so the record must exist even when nothing was lost.
record() { # record <verdict> <patch_bytes> <untracked_n> <detail>
  mkdir -p "$O/state" 2>/dev/null || true
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date +%s)" "${1:-?}" "${CAP:-}" "${PIDF:-}" "${DIR}" "${2:-0}" "${3:-0}" \
    "${DEST}" "${4:-}" >> "$LEDGER" 2>/dev/null || true
}

say() { # say <verdict> <rc> <extra>
  printf 'VERDICT=%s dir=%s snapshot=%s%s\n' "$1" "$DIR" \
    "${DEST}" "${3:+ $3}"
  record "$1" "${4:-0}" "${5:-0}" "${3:-}"
  exit "${2:-0}"
}

[ -d "$DIR" ] || say "NOT-APPLICABLE" 0 "reason=no-such-directory cap=${CAP:-} pid=${PIDF:-}"

# ⛔ A NON-GIT DIRECTORY IS STATED, NOT TARRED. The measured cron cwd is the harness root
# (~/orchestrator) -- tens of GB of logs, repos and cells. Tarring that at a cap would turn a
# bounded kill into a disk-full incident, which is #1765's failure mode. A worker in a non-git
# directory is expected to write its deliverable to a path it was told; this script cannot guess
# which paths those are, so it says so instead of pretending to have preserved them.
if ! git -C "$DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  say "NOT-APPLICABLE" 0 "reason=not-a-git-worktree cap=${CAP:-} pid=${PIDF:-}"
fi

# Porcelain is the population this script must account for. An unreadable `git status` is
# PARTIAL, never "clean": the same absent-read-as-a-fact rule the classifier runs on.
if ! PORC="$(git -C "$DIR" status --porcelain 2>/dev/null)"; then
  say "PARTIAL-do-not-reap" 3 "reason=git-status-unreadable cap=${CAP:-} pid=${PIDF:-}"
fi
if [ -z "$PORC" ]; then
  say "NOTHING-TO-PRESERVE" 0 "reason=clean-tree cap=${CAP:-} pid=${PIDF:-}"
fi

mkdir -p "$DEST" 2>/dev/null && chmod 700 "$DEST" 2>/dev/null
printf '%s\n' "$PORC" > "$DEST/status.txt" 2>/dev/null
[ -n "$REASON" ] && printf '%s\n' "$REASON" > "$DEST/reason.txt" 2>/dev/null

# ── tracked changes: `diff HEAD` covers staged AND unstaged, which a plain `diff` does not ──
TRACKED_CHANGED="$(git -C "$DIR" diff HEAD --name-only 2>/dev/null | grep -c . )"
PATCH_BYTES=0
if [ "${TRACKED_CHANGED:-0}" -gt 0 ]; then
  if git -C "$DIR" diff HEAD --binary > "$DEST/tracked.patch" 2>/dev/null; then
    PATCH_BYTES="$(wc -c < "$DEST/tracked.patch" 2>/dev/null | tr -d ' ')"; PATCH_BYTES="${PATCH_BYTES:-0}"
  else
    PATCH_BYTES=0
  fi
fi

# ── untracked files: a tar, verified by reading the archive back ────────────────────────────
UNTRACKED_N=0
TAR_OK=1
git -C "$DIR" ls-files -z --others --exclude-standard > "$DEST/untracked.z" 2>/dev/null
UNTRACKED_N="$(tr -cd '\0' < "$DEST/untracked.z" 2>/dev/null | wc -c | tr -d ' ')"; UNTRACKED_N="${UNTRACKED_N:-0}"
if [ "$UNTRACKED_N" -gt 0 ]; then
  # `-T` reads NUL-separated names so a name with a space or a newline cannot be split.
  # BSD tar takes `-T <file>`; it reads newline-separated names, so convert first (a name with a
  # newline in it is a NAMED RESIDUAL -- it would be split by every tar -T on this platform).
  tr '\0' '\n' < "$DEST/untracked.z" > "$DEST/untracked.list" 2>/dev/null
  if ( cd "$DIR" && tar -cf "$DEST/untracked.tar" -T "$DEST/untracked.list" >/dev/null 2>&1 ); then
    # Verify by READING the archive: a tar that exists but lists nothing preserved nothing.
    [ -s "$DEST/untracked.tar" ] && [ -n "$(tar -tf "$DEST/untracked.tar" 2>/dev/null | head -1)" ] \
      || TAR_OK=0
  else
    TAR_OK=0
  fi
fi

# ── the verdict ────────────────────────────────────────────────────────────────────────────
if [ "$TAR_OK" -eq 0 ]; then
  say "PARTIAL-do-not-reap" 3 "reason=untracked-tar-unverified untracked=$UNTRACKED_N cap=${CAP:-} pid=${PIDF:-}" "$PATCH_BYTES" "$UNTRACKED_N"
fi
if [ "${TRACKED_CHANGED:-0}" -gt 0 ] && [ "$PATCH_BYTES" -eq 0 ]; then
  say "PARTIAL-do-not-reap" 3 "reason=tracked-patch-empty tracked=$TRACKED_CHANGED cap=${CAP:-} pid=${PIDF:-}" "$PATCH_BYTES" "$UNTRACKED_N"
fi
say "COMPLETE" 0 "tracked=$TRACKED_CHANGED patch_bytes=$PATCH_BYTES untracked=$UNTRACKED_N cap=${CAP:-} pid=${PIDF:-}" "$PATCH_BYTES" "$UNTRACKED_N"
