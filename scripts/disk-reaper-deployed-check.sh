#!/usr/bin/env bash
# disk-reaper-deployed-check.sh — "is the copy that RUNS the copy we think it is?" (#1932 follow-up)
#
# WHY THIS EXISTS. The disk reaper is one entry point plus six pinned delegates that live in
# `$HOME/.pi/agent/scripts/` — a FARM COPY, derived from an agent-infra checkout by the bootstrap.
# Measured on this box (2026-11-03): the deployed `pi-reap-worktrees.sh` was byte-identical to
# `origin/main`, while the agent-infra CHECKOUT beside it sat **153 commits behind** `origin/main`.
# Every artifact was fine and a reader diffing "deployed vs the checkout I can see" would have
# concluded the reaper was stale — or, in the other direction (a checkout AHEAD of what was farmed),
# would have concluded a fix was live that had never been deployed. Both readings are wrong, and
# neither is visible to `systemctl status`, which reports that a pass RAN, never what ran.
#
# So the deployed set is STAMPED (a digest per file, plus the source commit it came from) and can be
# re-checked without any checkout at all:
#
#   disk-reaper-deployed-check.sh --stamp --source ~/agent-infra   # after any farm/install
#   disk-reaper-deployed-check.sh                                  # 0 = deployed == stamp
#   disk-reaper-deployed-check.sh --source ~/agent-infra            # ...and == that checkout
#
# EXIT CODES: 0 every deployed file matches the stamp (and the source, when given)
#             1 DRIFT — a deployed file changed since the stamp, is missing, or (with --source)
#               differs from the checkout. Nothing is fixed: the remedy is re-farm + re-stamp.
#             2 usage / the record cannot be read or written
#             3 UNSTAMPED — there is no record, so "deployed is what we think" is UNPROVEN.
#               Deliberately distinct from 1: an absent record is a set-up gap, not a change.
#
# The set is the same set the systemd unit pins (Environment=*_REAPER=), so a file the unit executes
# cannot be outside the check: adding a delegate to the unit without adding it here would be the
# same "silent copy" defect one level up, so the list is written once, here, and named in the docs.
set -uo pipefail

PROG="$(basename "${0:-disk-reaper-deployed-check.sh}")"
DIR_DEFAULT="${HOME:-/tmp}/.pi/agent/scripts"
RECORD_DEFAULT="${HOME:-/tmp}/.pi/agent/state/disk-reaper.deployed"
# The entry point the timer executes, the wrapper it goes through, the seven pinned delegates, AND the
# bounded-execution library the delegates source (pinned by `Environment=BOUNDED_LIB=`, and the reaper
# fails closed at startup without it — so a stale or absent copy means no class runs at all, which the
# checker must not certify as ok; review of #3405 round 2, P2).
# ⛔ `reap-runner-work.sh` IS THE ONE THAT MATTERS MOST HERE, and it was the only delegate outside the
# set. It holds the `rm -rf` rule for the runners' `_work` sink, and it is pinned in BOTH units
# (`Environment=RUNNER_WORK_REAPER=` / `RUNNER_WORK_REAPER` in the plist). A cell still carrying an
# EARLIER farmed copy is therefore a live delete-policy nobody hashes — and an earlier revision of that
# very file shipped a retain set that deleted a LIVE job's `_work/_temp`, which is exactly the shape
# this check exists to make impossible to miss. `--source <checkout>` reported `deployed ok` for it
# because `grep -c reap-runner-work` here was 0: the checker could not see the file at all.
# `lib/live-paths.sh` is here for the same reason as `lib/bounded.sh`, only MORE so: two pinned
# delegates resolve it from `$(dirname $0)/lib/` and `exit 3` without it (the installer's own farmed set
# carries it — "a missing library breaks TWO classes"), and it is the shared process-census code every
# KEEP live-process/live-cwd verdict comes from. It was outside the set until review round 3 (P1), so
# `--source <checkout>` could report `deployed ok` while the census ran a different library than the
# checkout's.
# ⛔ `lib/cell-home.sh` IS THE THIRD LIBRARY AND THE SAME CLASS (agent-infra#3453, review F2).
# `reap-abandoned-worktrees.sh` resolves it from `$SELF_DIR/lib/` and `exit 3`
# (`SKIP reason=cell-home-library-missing`) without it, so with the library outside this census the
# deployment gate certified `deployed ok` over a set in which the abandoned-worktree class was DEAD on
# every pass — the exact "`deployed ok` while a delegate cannot run" defect this list exists to make
# impossible to miss, one library later. It is also the one library whose absence silently changes a
# DELETE policy (it supplies `CELL_HOME_LEGACY`, the home the gitless guard protects), which is the
# #3278 shape.
FILES="disk-reaper.sh disk-reaper-run.sh pi-cache-reap.sh reap-lane-venvs.sh pi-reap-worktrees.sh
reap-abandoned-worktrees.sh reap-duplicate-installs.sh reap-runner-work.sh lib/bounded.sh
lib/cell-home.sh lib/live-paths.sh"

usage() {
    cat <<EOF
$PROG — prove the DEPLOYED disk-reaper set is the set that was farmed (and optionally, is the
checkout's).

Usage: $PROG [--stamp] [--dir DIR] [--record FILE] [--source DIR] [--quiet]
  --stamp          write the record from --dir (default $DIR_DEFAULT)
  --dir DIR        deployed scripts directory (default $DIR_DEFAULT)
  --record FILE    the stamp file (default $RECORD_DEFAULT)
  --source DIR     also compare each deployed file to DIR/scripts/<name>
  --quiet          print only problems and the summary line
  --help           this text

Exit: 0 matches · 1 drift · 2 usage/unreadable · 3 unstamped (never checked)
EOF
}

# sha256 — GNU coreutils on a Linux cell, `shasum` on macOS. No other dependency.
sha256() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
    else return 1
    fi
}

# ⛔ NOT `say` (agent-infra #2910): on macOS that is /usr/bin/say, so a missed definition is a
# voice on the speaker rather than a log line. `emit` cannot collide with a system binary.
emit() { [ "${QUIET:-0}" = 1 ] || printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }

MODE=check
DIR="$DIR_DEFAULT"
DIR_EXPLICIT=0
RECORD="$RECORD_DEFAULT"
SOURCE=""
QUIET=0
while [ $# -gt 0 ]; do
    case "$1" in
        --stamp) MODE=stamp ;;
        --dir) shift; DIR="${1:-}"; DIR_EXPLICIT=1 ;;
        --record) shift; RECORD="${1:-}" ;;
        --source) shift; SOURCE="${1:-}" ;;
        --quiet) QUIET=1 ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
    shift
done
[ -n "$DIR" ] && [ -n "$RECORD" ] || { usage >&2; exit 2; }
command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 || {
    warn "$PROG: no sha256sum and no shasum — cannot measure anything, refusing to report OK"; exit 2; }

if [ "$MODE" = stamp ]; then
    [ -d "$DIR" ] || { warn "$PROG: --stamp needs an existing --dir (got '$DIR')"; exit 2; }
    src_commit="-"
    if [ -n "$SOURCE" ] && [ -d "$SOURCE/.git" ] || [ -n "$SOURCE" ] && git -C "$SOURCE" rev-parse --git-dir >/dev/null 2>&1; then
        src_commit="$(git -C "$SOURCE" rev-parse HEAD 2>/dev/null)" || src_commit="-"
    fi
    tmp="$RECORD.tmp.$$"
    # `set -u` + a group whose stderr is redirected = a SILENT exit on the first unhashable file
    # (unbound variable, killed by the very redirect meant to quiet the hash). Initialise it.
    unmeasured=""
    mkdir -p "$(dirname "$RECORD")" 2>/dev/null || { warn "$PROG: cannot create $(dirname "$RECORD")"; exit 2; }
    {
        printf '# disk-reaper deployed set — written by %s --stamp\n' "$PROG"
        printf 'stamped_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'dir=%s\n' "$DIR"
        printf 'source=%s\n' "${SOURCE:--}"
        printf 'source_commit=%s\n' "$src_commit"
        for f in $FILES; do
            if [ -f "$DIR/$f" ]; then
                # ⛔ A DIGEST THAT COULD NOT BE TAKEN IS `unmeasured`, NEVER AN EMPTY FIELD (review of
                # #3405 round 3, P2). `printf '%s  %s' "" x` writes `  x` — two spaces and no digest —
                # which the check loop discarded before counting it AND the reconciliation matched as
                # recorded, so an unreadable file was permanently outside the check while the summary
                # read ok. stamp exits 1 so the operator cannot mistake it for a measurement either.
                d="$(sha256 "$DIR/$f" 2>/dev/null)" || d=""
                if [ -n "$d" ]; then
                    printf '%s  %s\n' "$d" "$f"
                else
                    printf 'unmeasured  %s\n' "$f"
                    unmeasured="$unmeasured $f"
                fi
            else
                printf 'missing  %s\n' "$f"
            fi
        done
    } >"$tmp" 2>/dev/null || { warn "$PROG: cannot write $tmp"; rm -f "$tmp"; exit 2; }
    mv -f "$tmp" "$RECORD" 2>/dev/null || { warn "$PROG: cannot replace $RECORD"; rm -f "$tmp"; exit 2; }
    if [ -n "${unmeasured:-}" ]; then
        warn "INCOMPLETE stamp: could not hash${unmeasured} — recorded as unmeasured, and the check treats that as drift"
        warn "  remedy: fix the read/permission problem, then: $PROG --stamp --source <agent-infra checkout>"
        exit 1
    fi
    emit "STAMPED $RECORD (dir=$DIR source=${SOURCE:--} commit=$src_commit)"
    exit 0
fi

[ -f "$RECORD" ] || {
    warn "UNSTAMPED: no record at $RECORD — the deployed set has never been measured, so 'the copy that runs is the copy we think' is UNPROVEN."
    warn "  remedy: $PROG --stamp --source <agent-infra checkout>"
    exit 3
}

# ⛔ AN UNREADABLE RECORD IS 2, NOT 3 (review of #3405, P2). A permissions problem is not "nobody
# stamped it", and steering the operator to re-stamp over it is the wrong remedy.
[ -r "$RECORD" ] || {
    warn "REFUSING: $RECORD exists but cannot be read — this is a permissions/ownership problem, not an unstamped box."
    exit 2
}

# ⛔ THE RECORD OWNS THE DIRECTORY. The reaper's unit runs with HOME=/tmp/cell-home while an operator's
# shell has HOME=/home/<user>, so `--dir` defaulting to the CALLER's HOME would check a directory the
# timer never executes (measured: a stamp written against /tmp/cell-home verified as seven MISSING
# files from an interactive shell). So the stamped `dir=` is authoritative unless --dir was given
# explicitly, which makes the check answer the question for the set that was actually stamped.
if [ "$DIR_EXPLICIT" = 0 ]; then
    stamped_dir="$(sed -n 's/^dir=//p' "$RECORD" 2>/dev/null | head -1)"
    [ -n "$stamped_dir" ] && DIR="$stamped_dir"
fi

drift=0
checked=0
appeared=""
# ⛔ ONE PARSE RULE FOR THE LOOP AND THE RECONCILIATION (review of #3422). The round-5 draft parsed
# with an explicit "two spaces" separator while the reconciliation split on ANY whitespace, so the two
# disagreed about what a record line IS. The split is now plain whitespace (the shell's own, exactly
# what awk does) and the FIELDS are validated instead: a malformed token is DRIFT, never a skip. The
# remaining divergence is the unterminated last line, closed by the loop tail below.
while read -r digest name _rest || [ -n "${digest:-}${name:-}" ]; do
    case "$digest" in ''|'#'*|*=*) continue ;; esac
    if [ -z "${name:-}" ]; then
        warn "DRIFT     (malformed record line, no name field): $digest"
        drift=1; continue
    fi
    case "$digest" in
        missing|unmeasured) : ;;
        *[!0-9a-f]*) warn "DRIFT     (malformed record line, digest is not hex): $digest $name"
                     drift=1; continue ;;
        *) [ ${#digest} -eq 64 ] || {
               warn "DRIFT     (malformed record line, digest is not a sha256): $digest $name"
               drift=1; continue; } ;;
    esac
    checked=$((checked + 1))
    if [ "$digest" = unmeasured ]; then
        # ⛔ AN UNMEASURED RECORD LINE IS DRIFT (review of #3405 round 3, P2). A digest that could not
        # be taken at stamp time must never read as verified.
        warn "DRIFT     $name — recorded as UNMEASURED (no digest could be taken); it has never been verified"
        drift=1; continue
    fi
    if [ "$digest" = missing ]; then
        # ⛔ "STAMPED MISSING AND STILL ABSENT" IS MISSING, NOT OK (review of #3405 round 2, P1). The
        # first fix only caught "farmed after the stamp"; a file the stamp recorded absent and that is
        # STILL absent fell through to a green summary — so `--stamp` over an empty directory printed
        # `deployed ok (N files)` and exited 0 with every pinned file, including the entry point, gone.
        # A missing pinned file is the exit-1 arm this script's own header documents.
        if [ -f "$DIR/$name" ]; then
            warn "APPEARED  $name — farmed after the stamp and never measured; re-stamp to make it accountable"
            appeared="$appeared $name"
            drift=1
        else
            warn "DRIFT     $name — stamped MISSING and still absent from $DIR (the unit pins it)"
            drift=1
        fi
        continue
    fi
    if [ ! -f "$DIR/$name" ]; then
        warn "DRIFT     $name — MISSING from $DIR (the unit pins it; the pass would fail closed)"
        drift=1; continue
    fi
    now="$(sha256 "$DIR/$name")"
    if [ "$now" != "$digest" ]; then
        warn "DRIFT     $name — deployed digest $now != stamped $digest"
        drift=1; continue
    fi
    if [ -n "$SOURCE" ]; then
        if [ ! -f "$SOURCE/scripts/$name" ]; then
            warn "SOURCE?   $name — $SOURCE/scripts does not have it, so the checkout cannot explain it"
            drift=1; continue
        fi
        theirs="$(sha256 "$SOURCE/scripts/$name")"
        if [ "$theirs" != "$now" ]; then
            warn "SOURCE-DRIFT $name — deployed $now != source $theirs ($SOURCE/scripts/$name)"
            drift=1; continue
        fi
    fi
    emit "same      $name $now"
# ⛔ `read` DOES NOT RUN ITS BODY FOR A FINAL LINE WITHOUT A TRAILING NEWLINE (review of #3422, P2).
# A truncated record — the delta's own stated threat model — therefore dropped its last line here while
# the awk reconciliation read it normally: `deployed ok (8 files)`, exit 0, with a pinned delegate
# DELETED. The `|| [ -n ... ]` tail makes the unterminated last line measure like any other.
done < "$RECORD"

# ⛔ THE RECORD IS RECONCILED WITH THE PINNED SET (review of #3405, P2). The loop above iterates the
# record's OWN lines, so a delegate added to $FILES (and to the unit's `Environment=*_REAPER=`) after
# the stamp was taken was never checked while the summary still read ok — which is exactly the "a file
# the unit executes cannot sit outside the check" promise this script's header makes. A pinned file
# with no record line is therefore a drift.
for f in $FILES; do
    # ⛔ ANCHORED ON A REAL DIGEST FIELD, not on any line ending in the name: the old pattern matched a
    # malformed `  <name>` line, so a file could be "recorded" and never measured (round 5, P2).
    if ! awk -v f="$f" '
            length($1) == 64 && $1 ~ /^[0-9a-f]+$/ || $1 == "missing" || $1 == "unmeasured" { if ($2 == f) found = 1 }
            END { exit !found }' "$RECORD" 2>/dev/null; then
        warn "UNRECORDED $f — pinned in this checker but absent from $RECORD; it has never been measured"
        drift=1
    fi
done

if [ "$checked" = 0 ]; then
    warn "UNSTAMPED: $RECORD names no file — an empty record verifies nothing."
    exit 3
fi
if [ "$drift" != 0 ]; then
    warn "SUMMARY deployed drift detected — the copy that RUNS is not the copy that was farmed (or not the checkout's). Re-farm, then: $PROG --stamp --source <checkout>"
    exit 1
fi
emit "SUMMARY deployed ok ($checked files${SOURCE:+; matches $SOURCE})"
exit 0
