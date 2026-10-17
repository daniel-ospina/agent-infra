#!/bin/bash
# ============================================================
# farm-retire.sh — the UNFARM leg of the pi-bootstrap farm (#1924)
#
# The farm in pi-bootstrap/setup.sh is COPY-ONLY. `cp -f` writes every name a farm
# array lists and does nothing at all to a name that is not listed, so a script that
# left the repo (or a name that left `fleet_srcs`) keeps its deployed copy in
# $DEST/scripts — executable, in the directory the fleet launches from — while the repo
# says it is gone. Nothing reported it: install-launchd's broken-target check only sees
# a plist whose target is MISSING, and check-deployed-drift.sh compares $O harness
# *.sh only.
#
# This file is the delete leg. It is SOURCEABLE (setup.sh for a laptop, cell-install.sh
# for a Linux cell) so both machines apply the SAME rule, and so the rule is testable
# without running either installer:
#
#   . "$(dirname "$0")/lib/farm-retire.sh"
#   farm_check_declared_shrink "$DEST" "$(dirname "$0")/farm-retired.txt" "$farm_declared_rel"
#   farm_unfarm "$DEST" "$(dirname "$0")/farm-retired.txt" "$farm_declared_rel"
#   farm_record_declared "$DEST" "$farm_declared_rel"
#
# SAFETY — an unfarm is a deletion, so every guard below is load-bearing:
#   * DECLARED, never inferred from absence: only a name written in
#     pi-bootstrap/farm-retired.txt is removed. A name that is merely absent from the
#     repo and the farm arrays is LEFT ALONE — absence cannot distinguish "retired"
#     from "the farm file failed to land" (the #1931 blindness class), and the farm
#     deliberately keeps local extras.
#   * A CONTRADICTION IS REFUSED: a name that a farm array still declares is never
#     removed (the copy leg has just re-created it) and the caller fails non-zero. The
#     OTHER direction — a name dropped from a farm array and NOT declared — is
#     invisible here by construction (it is then in neither list); that is what
#     farm_check_declared_shrink is for, using the snapshot the last apply recorded.
#   * NO GLOBBING, NO TRAVERSAL: an entry must start with `scripts/`, may not contain
#     `..`, a glob, a shell metacharacter or any whitespace, and its parent directory
#     must resolve to EXACTLY the directory the relative path names — not merely
#     somewhere inside $DEST. A symlinked farm subdirectory (`scripts/lib -> ../state`,
#     `scripts/fleet -> scripts`) therefore cannot redirect a removal onto a different
#     file; it is refused.
#   * FILES AND SYMLINKS ONLY: a directory is refused (never `rm -rf`), as is any
#     non-regular target. `rm -f` on a symlink removes the LINK, never its target.
#   * IDEMPOTENT and LOUD: an absent entry is a silent no-op on the second run, every
#     removal is printed, and a retirement list that is missing OR UNREADABLE is an
#     ERROR — never a silent skip, because a retirement list nobody can read is a
#     retirement that is not applied.
#   * ARTIFACT ONLY: runtime state ($DEST/state/<name>.lock|.log) is NOT touched. A
#     lock or a log is not a retirement, and deleting one is not recoverable. (The
#     snapshot this leg keeps lives under $DEST/state/ for the same reason: it is
#     state, and an unfarm never removes it.)
#   * AN ENTRY REMOVES WHATEVER IS AT THAT PATH — there is no content check, so a
#     local extra that happens to sit on a path the farm later retires is removed too.
#     That is the cost of "declared, never inferred" (a hash manifest would need
#     per-box state that can itself drift); operators are told it explicitly in
#     pi-bootstrap/farm-retired.txt.
# ============================================================

# ── entry validation ────────────────────────────────────────────────────────
# farm_retire_entry_problem <rel> — print why <rel> cannot be an unfarm entry and
# return 1; return 0 (printing nothing) when it is acceptable.
farm_retire_entry_problem() {
    local rel="$1" comp
    case "$rel" in
        scripts)   printf 'names the farm root itself, not a farmed artifact: %s' "$rel"; return 1 ;;
        scripts/*) ;;
        *) printf 'must start with scripts/ (got: %s)' "$rel"; return 1 ;;
    esac
    case "$rel" in
        *[[:space:]]*)
                 printf 'contains whitespace (a line of this list is one path, so whitespace cannot be represented unambiguously): %s' "$rel"; return 1 ;;
        *'\'*)   printf 'contains a backslash: %s' "$rel"; return 1 ;;
        *'$'*|*'`'*|*'"'*|*"'"*|*'|'*|*';'*|*'&'*|*'('*|*')'*|*'<'*|*'>'*)
                 printf 'contains a shell metacharacter: %s' "$rel"; return 1 ;;
        *'*'*|*'?'*|*'['*|*']'*)
                 printf 'is a GLOB, not a path: %s (an unfarm names one artifact; it never globs)' "$rel"; return 1 ;;
        *//*)    printf 'has an empty path component: %s' "$rel"; return 1 ;;
        */)      printf 'ends with / — name the FILE to retire, not a directory: %s' "$rel"; return 1 ;;
    esac
    # Component check: no `.`, `..`, and nothing that could be read as an option.
    local IFS=/
    for comp in $rel; do
        case "$comp" in
            ''|.|..) printf 'has a %s path component: %s' "$comp" "$rel"; return 1 ;;
            -*)      printf 'has a component beginning with "-": %s' "$rel"; return 1 ;;
        esac
    done
    return 0
}

# farm_artifact_state <dest-root> <rel> — print EXACTLY one of:
#   present       the path exists (or is a symlink)
#   absent        it does not exist AND its location was readable, so "already retired" is a
#                 verifiable answer
#   indeterminate it could not be decided: a component of the path exists but is not
#                 searchable (mode 000, a parent owned by another user, an ACL, root-squash on
#                 NFS). `[ -e path ]` answers FALSE for THIS case exactly as it does for
#                 absence, so a caller that reads "not -e" as "gone" reports a retirement that
#                 was never applied — and `--verify` then certifies the cell. That is the
#                 #1924 failure with a green tick on it, so the three states must never be
#                 collapsed into two.
farm_artifact_state() {
    local dest="$1" rel="$2" cur comp
    local IFS=/
    cur="$dest"
    for comp in $rel; do
        if [ -e "$cur/$comp" ] || [ -L "$cur/$comp" ]; then
            cur="$cur/$comp"
            continue
        fi
        if [ -x "$cur" ]; then
            printf 'absent\n'
        else
            printf 'indeterminate\n'
        fi
        return 0
    done
    printf 'present\n'
}

# farm_retired_entries <manifest> — print the declared retirements, one per line,
# blank lines and `#` comments skipped. Returns non-zero (loudly) when the manifest is
# missing, CANNOT BE READ, or holds an entry that is not a safe single artifact path.
# Callers MUST treat that non-zero as fatal: an unreadable retirement list is not
# "nothing to retire" — that reading is the exact failure this leg exists to remove.
farm_retired_entries() {
    local manifest="$1" line problem rc=0 read_rc=0
    if [ ! -f "$manifest" ]; then
        printf 'ERROR: the farm retirement list is missing: %s\n' "$manifest" >&2
        printf '       A retirement that cannot be read is a retirement that is NOT applied,\n' >&2
        printf '       so nothing was removed. Restore the file (pi-bootstrap/farm-retired.txt).\n' >&2
        return 1
    fi
    # The redirect's OWN status is what proves the list was read: a present-but-unreadable
    # file (mode/ACL/IO error) otherwise runs an empty loop and reports "nothing to retire"
    # with rc 0 — the same silent no-op, through a different door.
    while IFS= read -r line || [ -n "$line" ]; do
        # strip surrounding whitespace, so an indented entry is still one path
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        case "$line" in
            ''|'#'*) continue ;;
        esac
        if ! problem="$(farm_retire_entry_problem "$line")"; then
            printf 'ERROR: %s: %s\n' "$manifest" "$problem" >&2
            rc=1
            continue
        fi
        printf '%s\n' "$line"
    done < "$manifest" || read_rc=$?
    if [ "$read_rc" -ne 0 ]; then
        printf 'ERROR: the farm retirement list could not be READ: %s — nothing was removed\n' "$manifest" >&2
        printf '       (an unreadable list is NOT "nothing to retire": the retirement would not be applied)\n' >&2
        return 1
    fi
    return "$rc"
}

# ── membership + the farm's declared set ───────────────────────────────────
# farm_rel_listed <rel> <listed> — 0 when <rel> appears in the NEWLINE-separated
# <listed> set. THE membership rule, used for the declared set and for the retirement
# list, so the two cannot drift apart.
#
# <listed> is a NEWLINE-separated list of paths relative to $DEST (`scripts/<name>`,
# `scripts/lib/<name>`, …), NOT an argv list: the caller that owns the farm declaration
# (setup.sh) must not add a top-level `name=(...)` array, because cell-install.sh reads
# every such array in that file as a FARM. cell-install.sh passes the same shape.
farm_rel_listed() {
    local want="$1" line
    while IFS= read -r line; do
        [ "$line" = "$want" ] && return 0
    done <<<"${2:-}"
    return 1
}

# farm_retired_conflicts <manifest> <declared-list> — print every entry that a farm
# STILL declares. 0 = no conflict, 1 = conflicts, 2 = the list could not be read.
farm_retired_conflicts() {
    local manifest="$1" declared="${2:-}" entries rel rc=0
    entries="$(farm_retired_entries "$manifest")" || return 2
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        if farm_rel_listed "$rel" "$declared"; then
            printf '%s\n' "$rel"
            rc=1
        fi
    done <<<"$entries"
    return "$rc"
}

# ── the removal leg ────────────────────────────────────────────────────────
# farm_removal_problem <dest-root> <rel> <declared-list>
# Prints why <rel> cannot be removed (and returns 1), or prints nothing and returns 0. It
# is asked TWICE per run: once to validate the whole set before anything is touched, and
# again immediately before the `rm` (a file can be replaced between the two passes).
farm_removal_problem() {
    local dest="$1" rel="$2" declared="${3:-}"
    local path="$dest/$2" rel_dir parent resolved_dest expected drel

    case "$(farm_artifact_state "$dest" "$rel")" in
        present) : ;;
        absent)  printf 'nothing is installed at that path'; return 1 ;;
        *)       printf 'its location cannot be read (a directory on its path is not searchable), so it can be neither verified nor removed'
                 return 1 ;;
    esac

    # CONTAINMENT — the parent must resolve to EXACTLY the directory the relative path
    # names, not merely to somewhere inside $DEST. "Inside $DEST" would let a symlinked
    # farm subdirectory redirect the removal: `scripts/lib -> ../state` turns
    # `scripts/lib/x.lock` into a delete inside $DEST/state, and `scripts/fleet -> scripts`
    # makes `scripts/fleet/liveness.py` unlink the still-farmed `scripts/liveness.py`.
    # Both are silent and exit 0, so the comparison is exact rather than a prefix.
    rel_dir="$(dirname -- "$rel")"
    parent="$(cd "$dest/$rel_dir" 2>/dev/null && pwd -P)" || parent=""
    resolved_dest="$(cd "$dest" 2>/dev/null && pwd -P)" || resolved_dest=""
    if [ -z "$parent" ] || [ -z "$resolved_dest" ]; then
        printf 'its parent directory cannot be resolved'
        return 1
    fi
    expected="$resolved_dest/$rel_dir"
    if [ "$parent" != "$expected" ]; then
        printf 'its parent directory resolves to %s, not %s — a symlinked farm subdirectory could redirect this removal' \
               "$parent" "$expected"
        return 1
    fi

    # SAME-FILE GUARD. farm_retired_conflicts compares STRINGS; `rm` resolves the name
    # through the FILESYSTEM, and those differ in two ways that delete a live file:
    #   * case-insensitive volume (macOS APFS/HFS+, the primary target of setup.sh):
    #     `scripts/Record-Review.sh` and `scripts/record-review.sh` are ONE file, so an
    #     entry differing only in case passes the string check and removes the still-farmed
    #     artifact — on every sync, since the copy leg re-creates it;
    #   * a hardlink alias reaches the same inode on ANY filesystem.
    # So compare identity, not spelling. Only for a non-symlink target: unlinking a symlink
    # never harms the file it points at, so a farm link to another farmed script is a
    # legitimate retirement rather than a false block.
    if [ ! -L "$path" ]; then
        while IFS= read -r drel; do
            [ -n "$drel" ] || continue
            if [ "$path" -ef "$dest/$drel" ]; then
                printf 'it is the SAME FILE as the still-farmed %s (a case-only or hardlink alias)' "$drel"
                return 1
            fi
        done <<<"${declared:-}"
    fi

    # REMOVABILITY, as far as it can be known up front. Validation is what makes the set
    # all-or-nothing, so a target this run provably cannot unlink (a read-only parent
    # directory — a read-only mount, a locked-down farm subdir) must be refused HERE, before
    # any entry is removed, rather than discovered by a failing `rm` after others are gone.
    # What cannot be known in advance (an immutable flag, a permission change mid-run) is
    # handled by stopping at the first failed removal and reporting the exact partial state.
    # ...and it applies to a SYMLINK as well: unlinking a link needs write permission on its
    # parent just as a regular file does. Carving symlinks out here let a link in a read-only
    # directory pass validation and fail at the `rm`, after earlier entries were removed.
    if [ ! -w "$(dirname -- "$path")" ]; then
        printf 'its parent directory is not writable, so it cannot be removed'
        return 1
    fi

    if [ -L "$path" ]; then
        return 0   # a farm symlink is a farm artifact: rm -f removes the LINK, not its target
    elif [ -d "$path" ]; then
        printf 'it is a DIRECTORY — an unfarm removes a file, never a directory (remove it by hand if that is really the intent)'
        return 1
    elif [ ! -f "$path" ]; then
        printf 'it is not a regular file'
        return 1
    fi
    return 0
}

# farm_unfarm <dest-root> <manifest> <declared-list>
# <dest-root> is $DEST (the retirement paths are relative to it, e.g. scripts/x.py).
# Prints one REMOVED line per artifact and a summary. Returns non-zero when anything was
# refused — never silently.
#
# TWO PASSES, and the order is the safety property: the WHOLE set is validated before the
# FIRST removal. An unfarm is a deletion, so a refusal on entry seven must not leave
# entries one to six already gone: that is a half-applied retirement — a state nobody
# reviewed — and in setup.sh it also aborts the run before launchd convergence, so the
# box keeps a plist whose target the partial deletion just removed. Same rule as a
# contradiction (which is checked first).
#
# Everything validation CAN know is decided before the first `rm`: path legality, parent
# containment, same-file identity, target type, and removability (a read-only parent). What
# it cannot know in advance — a permission change mid-run, an immutable flag, a read-only
# mount appearing under it — is handled by STOPPING at the first failed removal and printing
# the exact partial state (HALF-APPLIED: which entry) instead of continuing to delete.
farm_unfarm() {
    local dest="$1" manifest="$2" declared="${3:-}"
    local entries conflicts rel path problem
    local removed=0 rc=0 refused=0 conflict_rc=0 absent=0

    entries="$(farm_retired_entries "$manifest")" || return 1
    if [ -z "$entries" ]; then
        printf '    unfarm: no retirements declared (%s)\n' "$manifest"
        return 0
    fi

    conflicts="$(farm_retired_conflicts "$manifest" "$declared")" || conflict_rc=$?
    case "$conflict_rc" in
        0) : ;;
        2) printf 'ERROR: the retirement list %s could not be read — nothing was removed\n' "$manifest" >&2
           return 1 ;;
        *) while IFS= read -r rel; do
               [ -n "$rel" ] || continue
               printf 'ERROR: %s is declared RETIRED but a farm array still declares it — the copy leg re-creates it, so the UNFARM leg removed NOTHING.\n' "$rel" >&2
               printf '       The two lists disagree about the SAME name; exactly one of them is stale:\n' >&2
               printf '        (1) the retirement is intended: remove the name from every farm array in\n' >&2
               printf '            pi-bootstrap/setup.sh in the SAME commit;\n' >&2
               printf '        (2) the retirement entry is the mistake: delete its line from\n' >&2
               printf '            pi-bootstrap/farm-retired.txt — the name stays farmed.\n' >&2
               printf '       Do not do both blindly: (1) retires it everywhere, (2) keeps it everywhere.\n' >&2
           done <<<"$conflicts"
           return 1 ;;
    esac

    # PASS 1 — validate every entry. Nothing is removed here.
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        if [ "$(farm_artifact_state "$dest" "$rel")" = absent ]; then
            absent=$((absent + 1))      # already applied (or never landed): idempotent, not a problem
            continue
        fi
        if ! problem="$(farm_removal_problem "$dest" "$rel" "$declared")"; then
            printf 'ERROR: %s cannot be removed — %s\n' "$rel" "$problem" >&2
            refused=$((refused + 1))
        fi
    done <<<"$entries"
    if [ "$refused" -gt 0 ]; then
        printf 'ERROR: %s of the declared retirement(s) cannot be applied safely, so NOTHING was removed —\n' "$refused" >&2
        printf '       a half-applied retirement is a state nobody reviewed, and the caller then aborts\n' >&2
        printf '       before launchd convergence. Fix or remove the path(s) named above and re-run.\n' >&2
        printf '    unfarm: 0 removed (%s refused)\n' "$refused"
        return 1
    fi

    # PASS 2 — remove. farm_removal_problem is asked again: a file can be replaced between
    # the passes, and the second answer is the one that precedes the `rm`.
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        path="$dest/$rel"
        [ "$(farm_artifact_state "$dest" "$rel")" = absent ] && continue
        if ! problem="$(farm_removal_problem "$dest" "$rel" "$declared")"; then
            # STOP, for the same reason as a failed `rm` below: the set is already known to be
            # un-appliable, so continuing would delete MORE after that was established.
            printf 'ERROR: %s changed while retiring and cannot be removed — %s\n' "$rel" "$problem" >&2
            printf '    unfarm: HALF-APPLIED — %d removed, then %s became unremovable; the remaining\n' "$removed" "$rel" >&2
            printf '           entries were NOT attempted (the target changed between validation and\n' >&2
            printf '           removal). Re-run after fixing it: absent entries are skipped.\n' >&2
            return 1
        fi
        if rm -f -- "$path"; then
            printf '    unfarm: REMOVED %s (retired — it is no longer farmed)\n' "$rel"
            removed=$((removed + 1))
        else
            # STOP, do not continue: carrying on would delete MORE while the set is already
            # known to be un-appliable, and the caller reports this run as failed either way.
            # Say exactly what happened rather than a bare count.
            printf 'ERROR: could not remove %s\n' "$path" >&2
            printf '    unfarm: HALF-APPLIED — %d removed, then %s could NOT be removed; the remaining\n' "$removed" "$rel" >&2
            printf '           entries were NOT attempted. The set was validated first, so this is a\n' >&2
            printf '           change between validation and removal (permissions, read-only mount,\n' >&2
            printf '           immutable flag): fix it and re-run — the already-removed entries are\n' >&2
            printf '           absent, so the re-run continues from the first one still present.\n' >&2
            return 1
        fi
    done <<<"$entries"

    printf '    unfarm: %d removed' "$removed"
    if [ "$absent" -gt 0 ]; then printf ' (%s already absent)' "$absent"; fi
    printf '\n'
    return "$rc"
}

# ── the snapshot: what THIS box's farm declared last time ──────────────────
# farm_snapshot_path <dest-root> — print the snapshot path. It lives under state/ for
# the same reason locks and logs do: it is state, and the unfarm leg never removes it.
farm_snapshot_path() {
    printf '%s/state/farm-declared.txt\n' "$1"
}

# farm_check_declared_shrink <dest-root> <manifest> <declared-list>
# Refuse a SILENT shrink: any path the PREVIOUS apply recorded, that this run neither
# declares nor retires, is an error. This is the only detector for the "natural
# mistake" of the two-edit rule — drop a name from a farm array without declaring it —
# which leaves the name in NEITHER list, so no set comparison can see it; it is
# visible only against what was actually installed here last time.
# Read-only: the caller records the snapshot AFTER the unfarm leg succeeds, so a failed
# run never moves the baseline. 0 = consistent (or first run), 1 = shrink or unreadable.
farm_check_declared_shrink() {
    local dest="$1" manifest="$2" declared="${3:-}"
    local snapshot prev entries rc=0 read_rc=0
    snapshot="$(farm_snapshot_path "$dest")"
    # THREE STATES HERE TOO. `[ -f ]` is false for a genuine first apply AND for a snapshot
    # path that is a directory, a dangling symlink, or under a non-searchable state/ — and
    # reading those as "first apply" silently disables the ONLY detector for a name dropped
    # from a farm array without being declared. Absent is a fact; anything else that is not a
    # readable regular file is an anomaly and must refuse.
    case "$(farm_artifact_state "$dest" "state/farm-declared.txt")" in
        absent) return 0 ;;     # first apply on this box: nothing to compare against
        *) if [ ! -f "$snapshot" ]; then
               printf 'ERROR: %s exists but is not a readable regular file — refusing to treat that as "first apply"\n' "$snapshot" >&2
               printf '       (with no usable baseline, a name dropped from a farm array and left undeclared\n' >&2
               printf '       would stay installed and unreported: the #1924 gap)\n' >&2
               return 1
           fi ;;
    esac
    entries="$(farm_retired_entries "$manifest")" || return 1
    while IFS= read -r prev; do
        [ -n "$prev" ] || continue
        farm_rel_listed "$prev" "$declared" && continue     # still farmed
        farm_rel_listed "$prev" "$entries" && continue      # retired on purpose
        # NOTHING DEPLOYED HERE = NOTHING TO ORPHAN. The snapshot records what the previous
        # run DECLARED, and a declaration is appended before the copy leg decides whether the
        # file exists (`[ -f "$f" ] || continue`; a MISSING lib leg only warns), so a box
        # whose checkout was incomplete has snapshot entries with no artifact behind them —
        # the #1931 "farm file failed to land" class this list must never confuse with a
        # retirement. Reporting those would block every later sync over a file that is not on
        # disk, and its prescribed remedy (declare it retired) would remove nothing.
        case "$(farm_artifact_state "$dest" "$prev")" in
            absent) continue ;;      # nothing deployed = nothing to orphan
            indeterminate)
                printf 'ERROR: cannot tell whether %s is still installed — a directory on its path is\n' "$prev" >&2
                printf '       not searchable, so "not installed" is not a verifiable answer. Refusing to\n' >&2
                printf '       guess: a guess here either blocks the sync or orphans a live artifact.\n' >&2
                rc=1
                continue ;;
        esac
        printf 'ERROR: %s was DECLARED and INSTALLED here by a previous run, and is now NEITHER farmed NOR retired.\n' "$prev" >&2
        printf '       TWO causes are possible, with OPPOSITE remedies — pick the right one:\n' >&2
        printf '        (1) the name really LEFT the farm: add its deployed path to\n' >&2
        printf '            pi-bootstrap/farm-retired.txt in the same commit.\n' >&2
        printf '        (2) this checkout is OLDER than what was installed here (a partial clone, an old\n' >&2
        printf '            branch, or a run pointed at a different checkout): do NOT declare it. Apply\n' >&2
        printf '            from the checkout that still farms it. Declaring it would DELETE an artifact\n' >&2
        printf '            the repo still ships, and since the farm re-creates it every later run would\n' >&2
        printf '            then fail on a retirement the farm still declares.\n' >&2
        rc=1
    done < "$snapshot" || read_rc=$?
    if [ "$read_rc" -ne 0 ]; then
        printf 'ERROR: the farm declaration snapshot could not be READ: %s — refusing to treat that as "nothing shrank"\n' "$snapshot" >&2
        return 1
    fi
    return "$rc"
}

# farm_record_declared <dest-root> <declared-list> — record what this apply declared,
# atomically (a concurrent reader must never see a half-written list).
farm_record_declared() {
    local dest="$1" declared="${2:-}"
    local snapshot tmp body
    snapshot="$(farm_snapshot_path "$dest")"
    mkdir -p "$dest/state" || return 1
    tmp="$snapshot.tmp.$$"
    # Callers hand over a newline-TERMINATED list (every farm loop appends `…$'\n'`), so
    # strip the trailing newlines before printing: `printf '%s\n'` would add a second one
    # and record a BLANK line, which is not a path in any set the leg compares against.
    body="$declared"
    while [ "${body%$'\n'}" != "$body" ]; do body="${body%$'\n'}"; done
    # `mv -f file existing-directory` MOVES INTO it and exits 0, so the write is proved by
    # reading the destination back — never by mv's status alone.
    if { if [ -n "$body" ]; then printf '%s\n' "$body"; fi; } | LC_ALL=C sort -u > "$tmp" 2>/dev/null \
       && mv -f "$tmp" "$snapshot" 2>/dev/null \
       && [ -f "$snapshot" ]; then
        printf '    farm declared set recorded: %s\n' "${snapshot#"$dest"/}"
        return 0
    fi
    rm -f "$tmp"
    printf 'ERROR: could not record the farm declaration snapshot at %s\n' "$snapshot" >&2
    return 1
}
