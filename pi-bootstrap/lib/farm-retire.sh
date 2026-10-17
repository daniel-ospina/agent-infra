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
#   farm_unfarm "$DEST" "$(dirname "$0")/farm-retired.txt" "${farm_declared_rel[@]}"
#
# SAFETY — an unfarm is a deletion, so every guard below is load-bearing:
#   * DECLARED, never inferred from absence: only a name written in
#     pi-bootstrap/farm-retired.txt is removed. A name that is merely absent from the
#     repo and the farm arrays is LEFT ALONE — absence cannot distinguish "retired"
#     from "the farm file failed to land" (the #1931 blindness class), and the farm
#     deliberately keeps local extras.
#   * CONTRADICTION REFUSED: a name that a farm array still declares is never removed
#     (the copy leg has just re-created it); the run fails non-zero instead, so
#     "removed from the array but not declared" and "declared but not removed from the
#     array" both surface loudly.
#   * NO GLOBBING, NO TRAVERSAL: an entry must start with `scripts/`, may not contain
#     `..`, a glob, a shell metacharacter or whitespace, and its parent directory must
#     resolve INSIDE $DEST/scripts — a symlinked directory cannot be used to escape.
#   * FILES AND SYMLINKS ONLY: a directory is refused (never `rm -rf`), as is any
#     non-regular target. `rm -f` on a symlink removes the LINK, never its target.
#   * IDEMPOTENT and LOUD: an absent entry is a silent no-op on the second run, every
#     removal is printed, and a missing/unreadable retirement list is an ERROR — never
#     a silent skip, because a retirement list that cannot be read is a retirement that
#     is not applied.
#   * ARTIFACT ONLY: runtime state ($DEST/state/<name>.lock|.log) is NOT touched. A
#     lock or a log is not a retirement, and deleting one is not recoverable.
# ============================================================

# ── entry validation ────────────────────────────────────────────────────────
# farm_retire_entry_problem <rel> — print why <rel> cannot be an unfarm entry and
# return 1; return 0 (printing nothing) when it is acceptable.
farm_retire_entry_problem() {
    local rel="$1" comp
    case "$rel" in
        scripts/*) ;;
        *) printf 'must start with scripts/ (got: %s)' "$rel"; return 1 ;;
    esac
    case "$rel" in
        *' '*)   printf 'contains whitespace (a line of this list is one path, and whitespace cannot be represented unambiguously): %s' "$rel"; return 1 ;;
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
    # `scripts/` alone is the farm's root, not an artifact.
    if [ "$rel" = "scripts" ]; then
        printf 'names the farm root itself, not a farmed artifact: %s' "$rel"
        return 1
    fi
    return 0
}

# farm_retired_entries <manifest> — print the declared retirements, one per line,
# blank lines and `#` comments skipped. Returns non-zero (loudly) when the manifest is
# missing or an entry is not a safe single artifact path. Callers MUST treat that
# non-zero as fatal: an unreadable retirement list is not "nothing to retire".
farm_retired_entries() {
    local manifest="$1" line problem rc=0
    if [ ! -f "$manifest" ]; then
        printf 'ERROR: the farm retirement list is missing: %s\n' "$manifest" >&2
        printf '       A retirement that cannot be read is a retirement that is NOT applied,\n' >&2
        printf '       so nothing was removed. Restore the file (pi-bootstrap/farm-retired.txt).\n' >&2
        return 1
    fi
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
    done < "$manifest"
    return "$rc"
}

# ── the farm's declared set ────────────────────────────────────────────────
# farm_rel_declared <rel> <declared-list> — 0 when <rel> is one of the paths a farm
# DECLARES. <declared-list> is a NEWLINE-separated list of paths relative to $DEST
# (`scripts/<name>`, `scripts/lib/<name>`, …), NOT an argv list: the caller that owns the
# farm declaration (setup.sh) must not add a top-level `name=(...)` array, because
# cell-install.sh reads every such array in that file as a FARM. THE membership rule,
# used by the removal leg and the read-back so the two cannot drift.
farm_rel_declared() {
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
        if farm_rel_declared "$rel" "$declared"; then
            printf '%s\n' "$rel"
            rc=1
        fi
    done <<<"$entries"
    return "$rc"
}

# ── the removal leg ────────────────────────────────────────────────────────
# farm_unfarm <dest-root> <manifest> <declared-list>
# <dest-root> is $DEST (the retirement paths are relative to it, e.g. scripts/x.py);
# <declared-list> is the NEWLINE-separated set the farm declared THIS run
# (setup.sh: farm_declared_rel; cell-install.sh: read_declared_farm_rel_paths).
# Prints one REMOVED line per artifact and a summary. Returns non-zero when anything
# was refused or could not be removed — never silently.
#
# A CONTRADICTION ABORTS THE WHOLE LEG, before anything is removed: if any declared
# retirement is still declared by a farm array, the declaration and the farm disagree
# about the repo's own state, and a half-applied deletion set is a state nobody
# reviewed. Nothing is deleted; the caller fails loudly.
farm_unfarm() {
    local dest="$1" manifest="$2" declared="${3:-}"
    local entries conflicts rel path parent resolved_dest removed=0 rc=0 conflict_rc=0

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
               printf '       Remove it from every farm array in pi-bootstrap/setup.sh in the SAME commit.\n' >&2
           done <<<"$conflicts"
           return 1 ;;
    esac

    while IFS= read -r rel; do
        [ -n "$rel" ] || continue

        path="$dest/$rel"
        # Absent = already applied. This is what makes a re-run idempotent and quiet.
        if [ ! -e "$path" ] && [ ! -L "$path" ]; then
            continue
        fi

        # Containment: the PARENT must resolve inside <dest-root>, so a symlinked
        # directory (scripts/lib -> /etc) cannot be used to reach outside the farm.
        parent="$(cd "$(dirname "$path")" 2>/dev/null && pwd -P)" || parent=""
        resolved_dest="$(cd "$dest" 2>/dev/null && pwd -P)" || resolved_dest=""
        if [ -z "$parent" ] || [ -z "$resolved_dest" ] || [ "$parent" = "$resolved_dest" ]; then
            printf 'ERROR: cannot resolve the parent directory of %s — refusing to remove it\n' "$rel" >&2
            rc=1
            continue
        fi
        case "$parent/" in
            "$resolved_dest"/*) : ;;
            *) printf 'ERROR: %s resolves OUTSIDE %s (parent: %s) — refusing to remove it\n' \
                       "$rel" "$resolved_dest" "$parent" >&2
               rc=1
               continue ;;
        esac

        if [ -L "$path" ]; then
            :   # a farm symlink is a farm artifact: rm -f removes the LINK, not its target
        elif [ -d "$path" ]; then
            printf 'ERROR: %s is a DIRECTORY — an unfarm removes a file, never a directory (refusing; remove it by hand if that is really the intent)\n' "$rel" >&2
            rc=1
            continue
        elif [ ! -f "$path" ]; then
            printf 'ERROR: %s is not a regular file — refusing to remove it\n' "$rel" >&2
            rc=1
            continue
        fi

        if rm -f -- "$path"; then
            printf '    unfarm: REMOVED %s (retired — it is no longer farmed)\n' "$rel"
            removed=$((removed + 1))
        else
            printf 'ERROR: could not remove %s\n' "$path" >&2
            rc=1
        fi
    done <<<"$entries"

    printf '    unfarm: %d removed\n' "$removed"
    return "$rc"
}
