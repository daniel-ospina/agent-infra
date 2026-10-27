#!/usr/bin/env bash
# lane-container-reap.sh — remove a lane's private test-DB container ONLY when the lane is provably gone (#2868).
#
# WHY THIS EXISTS (measured 2026-10-26, pi-cell-4)
# A lane mints private test databases — `tools/test_lane.py`'s `fdb-lane-*` FalkorDB isolation
# container (tortoise#5084) and hand-made `*-pg`/`*-fdb` Postgres/FalkorDB instances — and NOTHING
# removes them when the lane dies. The tortoise tool's own `reap_orphans()` runs only from inside a
# live worktree's `start()`/`uri()`, so a lane whose worktree is removed never triggers it; the
# hand-made `*-pg`/`*-fdb` databases have no reaper at all. Measured on this box: 27 leaked containers
# (up to 4 days) survived a hand reap, each holding a published port (a full port range refuses every
# new lane) and disk (ENOSPC kills lanes mid-work). A hand-kill is not a fix.
#
# THE POLICY — a container is removed ONLY when its owning lane is provably gone, by THREE proofs,
# ALL required and each re-read at the moment of removal (fail-closed: any uncertainty ⇒ report, do
# not reap):
#   1. AGE        the container is older than MIN_AGE (default 14400s = 4h, the issue-claim TTL
#                 ceiling — a lane inside one full working period must never read as dead).
#   2. NO LIVE PROCESS   no process's command line names the container (its exact name, or the owning
#                 token derived from it), after EXCLUDING the reaper's own process tree (its invoking
#                 agent, its probes, and its greps all carry the names on their own command lines —
#                 see `self_pids`). An unreadable `ps` removes NOTHING.
#   3. OWNERSHIP GONE    the ownership record for the lane is absent:
#        * `fdb-lane-<slug>`      → the slug is ABSENT from `git worktree list` (the owning worktree
#                                   is gone). Same ownership proof as tortoise's reap_orphans (#8180).
#        * a name carrying a PR N  → no claim ref for that PR in the claims snapshot
#                                   (`refs/claims/N-*` or `refs/claims/pr-N`).
#        * any other name          → ownership is UNKNOWN; reported, never reaped.
#
# WHAT IS NOT A CANDIDATE AT ALL
#   * the shared long-lived instances (`falkordb`, `falkordb-16379`, `fdb-6599`, `w6213-fdb`) are
#     PROTECTED — same list as tortoise's PROTECTED_NAMES — and never matched by a managed pattern.
#   * a name outside the managed patterns (`fdb-lane-*`, `*-pg`/`pg`/`*-fdb`/`fdb`/`*-postgres`/
#     `*-falkordb`, `falkordb-<N>-*`, `tortoise-ci-*`) is not a lane database and is never touched.
#
# --dry-run is the DEFAULT; --apply arms deletion. A claim that is present (even expired) KEEPS the
# container — expiry is claim-reaper.sh's job, not this tool's; a stale snapshot is a KEEP, never a
# permission to delete.
#
# Usage:
#   lane-container-reap.sh [--dry-run|--apply] [--repo PATH] [--min-age S] [--json]
#
# Env seams (tests use them; operators rarely should):
#   LANE_CONTAINER_DOCKER_BIN   docker  (default: docker)
#   LANE_CONTAINER_PS_BIN       ps      (default: ps)
#   LANE_CONTAINER_GIT_BIN      git     (default: git)
#   LANE_CONTAINER_SHA1_BIN     sha1sum (default: sha1sum)
#   LANE_CONTAINER_DATE_BIN     date    (default: date)
#   LANE_CONTAINER_REPO         repo whose worktrees own `fdb-lane-*` (default: $REPO, else $PWD)
#   LANE_CONTAINER_CLAIM_SNAPSHOT   path to the claims snapshot TSV (default: $O/state/claims-snapshot)
#   LANE_CONTAINER_MIN_AGE      age floor, seconds (default 14400)
#   LANE_CONTAINER_DRY_RUN      1 = report only (default), 0 = armed
#   LANE_CONTAINER_NOW          epoch seconds (tests pin the clock)
#   LANE_CONTAINER_LOG          durable pass log
#   LANE_CONTAINER_TIMEOUT_BIN  timeout(1) (default: timeout)
#   LANE_CONTAINER_READ_TIMEOUT bound for one external read, seconds (default 60)
#
# Exit codes: 0 pass completed, 2 usage, 3 fail-closed abort (a read failed; nothing removed),
#             4 pass completed but at least one removal FAILED.
set -uo pipefail

SCRIPT_NAME="lane-container-reap.sh"
ISSUE_REF="#2868"

DOCKER_BIN="${LANE_CONTAINER_DOCKER_BIN:-docker}"
PS_BIN="${LANE_CONTAINER_PS_BIN:-ps}"
GIT_BIN="${LANE_CONTAINER_GIT_BIN:-git}"
SHA1_BIN="${LANE_CONTAINER_SHA1_BIN:-sha1sum}"
DATE_BIN="${LANE_CONTAINER_DATE_BIN:-date}"
TIMEOUT_BIN="${LANE_CONTAINER_TIMEOUT_BIN:-timeout}"
READ_TIMEOUT="${LANE_CONTAINER_READ_TIMEOUT:-60}"
MIN_AGE="${LANE_CONTAINER_MIN_AGE:-14400}"
DRY="${LANE_CONTAINER_DRY_RUN:-1}"
NOW="${LANE_CONTAINER_NOW:-}"
REPO="${LANE_CONTAINER_REPO:-${REPO:-$PWD}}"
CLAIM_SNAP="${LANE_CONTAINER_CLAIM_SNAPSHOT:-${O:-$HOME/orchestrator}/state/claims-snapshot}"
LOG="${LANE_CONTAINER_LOG:-${HOME:-/tmp}/.pi/agent/state/lane-container-reap.log}"

# The shared instances that must never be removed (tortoise tools/test_lane.py::PROTECTED_NAMES).
PROTECTED="falkordb falkordb-16379 fdb-6599 w6213-fdb"

DRY_RUN=1
APPLY=0
JSON=0
REMOVED=0
KEPT=0
ABSTAINED=0
FAILED=0
SELF_PID="$$"

log_line() { printf '%s\n' "$*"; log "$*"; }
log() { [ -n "$LOG" ] && { d="$(dirname "$LOG")"; [ -d "$d" ] || mkdir -p "$d" 2>/dev/null; printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG" 2>/dev/null; } || true; }

usage() {
    cat <<EOF
$SCRIPT_NAME — remove a lane's private test-DB container only when the lane is provably gone ($ISSUE_REF)

Usage:
  $SCRIPT_NAME [--dry-run] [--repo PATH] [--min-age S] [--json]   report what WOULD be removed
  $SCRIPT_NAME --apply [--repo PATH] [--min-age S] [--json]       armed pass

  --dry-run     report only (the default)
  --apply       arm deletion (or env LANE_CONTAINER_DRY_RUN=0)
  --repo PATH   repo whose worktrees own fdb-lane-* containers (default: \$REPO, else \$PWD)
  --min-age S   age floor in seconds (default 14400)

A container is removed ONLY when ALL three proofs hold: it is older than the age floor; no process's
command line names it (or its owning token), after excluding the reaper's own process tree; and its
owner is gone — the fdb-lane-* slug is absent from git worktree list, or the PR its name carries has
no claim in the claims snapshot. Fail-closed: an unreadable ps / git / snapshot removes NOTHING
(exit 3). A protected shared instance is never a candidate. A name outside the managed patterns is
never touched.
EOF
}

is_num() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; return 0; }
now_epoch() { if is_num "$NOW"; then printf '%s' "$NOW"; else "$DATE_BIN" +%s; fi; }

bound() { # bound <seconds> <cmd...>
    local s="$1"; shift
    if [ -n "$TIMEOUT_BIN" ] && command -v "$TIMEOUT_BIN" >/dev/null 2>&1; then
        "$TIMEOUT_BIN" "$s" "$@"; return $?
    fi
    "$@"
}

# ── managed-name classification ─────────────────────────────────────────────────────────────────
is_protected() {
    case " $PROTECTED " in *" $1 "*) return 0 ;; esac
    return 1
}

# pr_from_name <name> — the FIRST run of 3+ consecutive digits, or "" when there is none.
# 3 digits is the floor for a PR number: a single digit ("r5edges") is a lane SLUG, not a PR, and
# must not be mistaken for a claim key. ⛔ FIRST, not last: a `falkordb-6673-…-2007164-25543` name
# carries the PR (6673) AND trailing run-ids/seeds/pids, and a greedy `.*([0-9]{3,})` captures the
# TRAILING digits — so the claim key would be the pid, never the PR.
pr_from_name() {
    printf '%s\n' "$1" | sed -nE 's/^[^0-9]*([0-9]{3,}).*/\1/p' | head -1
}

# population <name> — "worktree<TAB>slug" | "pr<TAB>pr" | "" (outside). Never returns "protected":
# the caller checks is_protected first.
population() {
    local n="$1" tok
    case "$n" in
        fdb-lane-*) printf 'worktree\t%s\n' "${n#fdb-lane-}" ;;
        *-pg|*-fdb|*-postgres|*-falkordb|*pg|*fdb)
            tok="$(pr_from_name "$n")"
            [ -n "$tok" ] && printf 'pr\t%s\n' "$tok" ;;
        falkordb-[0-9]*|tortoise-ci-*)
            tok="$(pr_from_name "$n")"
            [ -n "$tok" ] && printf 'pr\t%s\n' "$tok" ;;
    esac
    return 0
}

# ── the three proofs ────────────────────────────────────────────────────────────────────────────
# proof_age <created-epoch> <now> — 0 when the container is OLD enough to judge (>= MIN_AGE).
proof_age() {
    local created="$1" now="$2" age
    age=$(( now - created ))
    [ "$age" -ge "$MIN_AGE" ]
}

# proof_no_process <name> <token> <pstable-file> — 0 when NO process command line names either.
# ⛔ The table passed here is ALREADY cleaned of the reaper's own tree, and the caller has already
# proven `ps` readable (main aborts the whole pass otherwise). An EMPTY cleaned table therefore
# means "no foreign process" — the proof PASSES — and must not read as a failed read.
proof_no_process() {
    local name="$1" token="$2" table="$3"
    if [ -n "$token" ]; then
        grep -F -e "$name" -e "$token" "$table" >/dev/null 2>&1 && return 1
    else
        grep -F -e "$name" "$table" >/dev/null 2>&1 && return 1
    fi
    return 0
}

# proof_owner_gone_worktree <slug> <worktree-file> — 0 when no worktree lists this slug.
# ⛔ A MISSING/EMPTY LIST IS A FAILED PROOF (rc 1): an unreadable list is not "owner gone".
proof_owner_gone_worktree() {
    local slug="$1" list="$2"
    [ -s "$list" ] || return 1
    awk -F'\t' -v s="$slug" '$1 == s { found=1 } END { exit !found }' "$list" >/dev/null 2>&1 && return 1
    return 0
}

# proof_no_claim <pr> <snapshot-file> — 0 when the snapshot holds NO claim ref for this PR.
# ⛔ A MISSING/EMPTY SNAPSHOT IS A FAILED PROOF (rc 1): the claim gate is fail-closed.
proof_no_claim() {
    local pr="$1" snap="$2"
    [ -s "$snap" ] || return 1
    awk -F'\t' -v p="$pr" '
        $1 ~ ("refs/claims/" p "-") { found = 1 }
        $1 == ("refs/claims/pr-" p) { found = 1 }
        END { exit !found }' "$snap" >/dev/null 2>&1 && return 1
    return 0
}

# ── readers (each writes a scratch FILE; rc 1 = the read FAILED) ───────────────────────────────
# docker_list <outfile> — "name<TAB>state<TAB>created_epoch" per container.
docker_list() {
    local out="$1" list rc name state created epoch
    list="$(bound "$READ_TIMEOUT" "$DOCKER_BIN" ps -a --format '{{.Names}}\t{{.State}}' 2>/dev/null)"; rc=$?
    [ "$rc" = 0 ] && [ -n "$list" ] || return 1
    : > "$out"
    while IFS=$'\t' read -r name state; do
        [ -n "$name" ] || continue
        created="$(bound "$READ_TIMEOUT" "$DOCKER_BIN" inspect -f '{{.Created}}' "$name" 2>/dev/null)"
        epoch=""
        if [ -n "$created" ]; then
            epoch="$("$DATE_BIN" -u -d "$created" +%s 2>/dev/null)"
            is_num "${epoch:-}" || epoch=""
        fi
        printf '%s\t%s\t%s\n' "$name" "$state" "$epoch" >> "$out"
    done <<< "$list"
    return 0
}

# ps_table <outfile> — "pid<TAB>ppid<TAB>args" per process, NORMALISED to tabs. rc 1 when the read failed.
# ⛔ `ps -o pid=,ppid=,args=` is SPACE-separated, and args itself contains spaces, so the table must be
# normalised the same way lane-reap.sh's read_table does — peel the first two fields by regex — or a
# tab-splitting reader (`self_pids`, `clean_table`) sees one field and never matches a pid.
# ⛔ THE PS CALL RUNS AS A DIRECT CHILD (redirection to a temp file, NO pipe, NO command substitution)
# so that the reader's own process is the ps child's parent: `self_pids` walks `$$`'s ancestry through
# this very table, and a command-substitution/piped ps would report the SUBSHELL as the reader's
# parent — the self-exclusion would then exclude the wrong pid and a witness would read its own
# reader as a live lane.
ps_table() {
    local out="$1" raw
    raw="$out.raw"
    bound "$READ_TIMEOUT" "$PS_BIN" -axo pid=,ppid=,args= > "$raw" 2>/dev/null || { rm -f "$raw"; return 1; }
    [ -s "$raw" ] || { rm -f "$raw"; return 1; }
    awk '
        { pid = $1; ppid = $2; cmd = $0; sub(/^[ \t]*[^ \t]+[ \t]+[^ \t]+[ \t]*/, "", cmd); printf "%s\t%s\t%s\n", pid, ppid, cmd }
    ' "$raw" > "$out"
    rm -f "$raw"
    [ -s "$out" ] || return 1
    return 0
}

# worktree_slugs <outfile> — "slug<TAB>path" per worktree of $REPO. rc 1 when the read failed.
worktree_slugs() {
    local out="$1" raw rc line path slug
    raw="$(bound "$READ_TIMEOUT" "$GIT_BIN" -C "$REPO" worktree list --porcelain 2>/dev/null)"; rc=$?
    [ "$rc" = 0 ] && [ -n "$raw" ] || return 1
    : > "$out"
    while IFS= read -r line; do
        case "$line" in
            worktree\ *) path="${line#worktree }" ;;
            *) continue ;;
        esac
        [ -n "$path" ] || continue
        slug="$(printf '%s' "$path" | "$SHA1_BIN" | cut -c1-10)"
        [ -n "$slug" ] && printf '%s\t%s\n' "$slug" "$path" >> "$out"
    done <<< "$raw"
    return 0
}

# ── the reaper's OWN process tree, excluded from the process witness ───────────────────────────
# ⛔ LOAD-BEARING, not tidiness. The reaper's own command line — and, more importantly, the command
# line of the agent/controller that INVOKED it — can carry the container names and tokens under
# investigation (measured: an interactive agent running the reaper held every container name on its
# own argv, so the witness reported `live-process` for containers no lane process touched). Every
# probe the reaper forks (`docker inspect <name>`, `grep -e <name>`) carries them the same way. A
# witness that sees its own reader is measuring itself, so the reaper's ancestors AND descendants are
# excluded exactly as reap-lane-venvs.sh's `self_load` does. In production the invoker is a
# cron/systemd unit whose argv carries nothing, and the exclusion costs one table walk — it is the
# difference between a witness and a mirror.
self_pids() { # <pstable-file> <outfile> — one pid per line ($$, its ancestors, its descendants)
    local table="$1" out="$2" pid ppid depth=0 more
    : > "$out"
    printf '%s\n' "$$" >> "$out"
    [ -s "$table" ] || return 0
    # ancestors
    pid="$$"
    while [ -n "$pid" ] && [ "$pid" != "0" ] && [ "$depth" -lt 64 ]; do
        ppid="$(awk -F'\t' -v p="$pid" '$1 == p { print $2; exit }' "$table" 2>/dev/null)"
        [ -n "$ppid" ] && [ "$ppid" != "$pid" ] || break
        printf '%s\n' "$ppid" >> "$out"
        pid="$ppid"; depth=$((depth + 1))
    done
    # descendants (the reaper's probes/greps)
    more="$(awk -F'\t' -v root="$$" '
        { ppid[$1] = $2 }
        END {
            seen[root] = 1
            q[1] = root; n = 1
            for (i = 1; i <= n; i++) {
                p = q[i]
                for (c in ppid) if (ppid[c] == p && !(c in seen)) { seen[c] = 1; n++; q[n] = c; print c }
            }
        }' "$table" 2>/dev/null)"
    while IFS= read -r pid; do
        [ -n "$pid" ] && printf '%s\n' "$pid" >> "$out"
    done <<< "$more"
    return 0
}

# clean_table <raw> <selfpids> <outfile> — the ps table minus the reaper's own rows.
clean_table() {
    local raw="$1" self="$2" out="$3"
    awk -F'\t' 'NR==FNR { self[$1] = 1; next } !($1 in self) { print }' "$self" "$raw" > "$out" 2>/dev/null
    return 0
}

# ── classify ────────────────────────────────────────────────────────────────────────────────────
# Emits "<verdict>\t<reason>\t<name>" (verdict: reap | keep | abstain); empty for a non-candidate.
classify() {
    local name="$1" created="$2" pstable="$3" wtfile="$4" snap="$5"
    local now kind token age
    now="$(now_epoch)"
    if is_protected "$name"; then
        printf 'keep\tprotected-shared\t%s\n' "$name"; return 0
    fi
    kind="$(population "$name")"
    [ -n "$kind" ] || return 0
    token="${kind#*$'\t'}"; kind="${kind%%$'\t'*}"

    if ! is_num "$created"; then
        printf 'keep\tunreadable-age\t%s\n' "$name"; return 0
    fi
    age=$(( now - created ))
    if ! proof_age "$created" "$now"; then
        printf 'keep\ttoo-recent\t%s\n' "$name"; return 0
    fi
    # OWNERSHIP first (the strongest proof; an unreadable record removes nothing).
    case "$kind" in
        worktree)
            if ! proof_owner_gone_worktree "$token" "$wtfile"; then
                printf 'keep\tworktree-live\t%s\n' "$name"; return 0
            fi
            ;;
        pr)
            if ! proof_no_claim "$token" "$snap"; then
                printf 'keep\tclaim-live\t%s\n' "$name"; return 0
            fi
            ;;
    esac
    # NO LIVE PROCESS (an unreadable table removes nothing).
    if ! proof_no_process "$name" "$token" "$pstable"; then
        printf 'keep\tlive-process\t%s\n' "$name"; return 0
    fi
    printf 'reap\towner-gone age=%ss no-process no-claim\t%s\n' "$age" "$name"
    return 0
}

# ── removal (re-reads every proof immediately before `docker rm -f`) ────────────────────────────
remove_one() {
    local name="$1" created pstable wtfile snap row kind token raw self
    created="$(bound "$READ_TIMEOUT" "$DOCKER_BIN" inspect -f '{{.Created}}' "$name" 2>/dev/null)"
    created="$("$DATE_BIN" -u -d "${created:-}" +%s 2>/dev/null)"
    is_num "${created:-}" || { printf 'KEEP %s — unreadable age at removal; NOT removed\n' "$name"; ABSTAINED=$((ABSTAINED + 1)); return 0; }
    kind="$(population "$name")"; token="${kind#*$'\t'}"; kind="${kind%%$'\t'*}"
    [ -n "$kind" ] || { printf 'KEEP %s — no longer a managed name at removal; NOT removed\n' "$name"; ABSTAINED=$((ABSTAINED + 1)); return 0; }
    raw="$(mktemp "${TMPDIR:-/tmp}/lcr.XXXXXX")"
    self="$(mktemp "${TMPDIR:-/tmp}/lcs.XXXXXX")"
    pstable="$(mktemp "${TMPDIR:-/tmp}/lcp.XXXXXX")"
    wtfile="$(mktemp "${TMPDIR:-/tmp}/lcw.XXXXXX")"
    snap="$(mktemp "${TMPDIR:-/tmp}/lcg.XXXXXX")"
    # ⛔ A BLIND RE-READ MUST REFUSE THE REMOVAL, not merely fall through to an empty witness: an
    # empty cleaned table reads as "no process", so a ps that failed at the moment of removal would
    # otherwise license the delete.
    if ! ps_table "$raw"; then
        printf 'KEEP %s — ps unreadable at removal; NOT removed\n' "$name"
        rm -f "$raw" "$self" "$pstable" "$wtfile" "$snap"
        ABSTAINED=$((ABSTAINED + 1))
        return 0
    fi
    self_pids "$raw" "$self"
    clean_table "$raw" "$self" "$pstable"
    worktree_slugs "$wtfile" 2>/dev/null || : > "$wtfile"
    cat "$CLAIM_SNAP" > "$snap" 2>/dev/null || : > "$snap"
    row="$(classify "$name" "$created" "$pstable" "$wtfile" "$snap")"
    rm -f "$raw" "$self" "$pstable" "$wtfile" "$snap"
    case "$row" in
        reap*)
            if bound "$READ_TIMEOUT" "$DOCKER_BIN" rm -f "$name" >/dev/null 2>&1; then
                printf 'REMOVED %s\n' "$name"
                REMOVED=$((REMOVED + 1))
            else
                printf 'FAILED %s — docker rm -f refused; NOT removed\n' "$name"
                FAILED=$((FAILED + 1))
            fi
            ;;
        abstain*)
            printf 'KEEP %s — %s (re-check refused)\n' "$name" "${row#abstain$'\t'}"
            ABSTAINED=$((ABSTAINED + 1))
            ;;
        keep*)
            printf 'KEEP %s — %s (re-check refused)\n' "$name" "${row#keep$'\t'}"
            KEPT=$((KEPT + 1))
            ;;
        *)
            printf 'KEEP %s — could not re-classify at removal; NOT removed\n' "$name"
            ABSTAINED=$((ABSTAINED + 1))
            ;;
    esac
    return 0
}

# ── main pass ───────────────────────────────────────────────────────────────────────────────────
main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --apply) DRY_RUN=0; APPLY=1 ;;
            --dry-run) DRY_RUN=1; APPLY=0 ;;
            --repo) REPO="${2:-}"; shift ;;
            --min-age) MIN_AGE="${2:-$MIN_AGE}"; shift ;;
            --json) JSON=1 ;;
            -h|--help) usage; return 0 ;;
            *) printf '%s: unknown argument %s\n' "$SCRIPT_NAME" "$1" >&2; return 2 ;;
        esac
        shift
    done
    is_num "$MIN_AGE" || { printf '%s: --min-age must be a positive integer\n' "$SCRIPT_NAME" >&2; return 2; }
    [ "$DRY" = "0" ] && { DRY_RUN=0; APPLY=1; }

    local dlist raw self pstable wtfile snap
    dlist="$(mktemp "${TMPDIR:-/tmp}/lcd.XXXXXX")"
    raw="$(mktemp "${TMPDIR:-/tmp}/lcr.XXXXXX")"
    self="$(mktemp "${TMPDIR:-/tmp}/lcs.XXXXXX")"
    pstable="$(mktemp "${TMPDIR:-/tmp}/lcp.XXXXXX")"
    wtfile="$(mktemp "${TMPDIR:-/tmp}/lcw.XXXXXX")"
    snap="$(mktemp "${TMPDIR:-/tmp}/lcg.XXXXXX")"

    if ! docker_list "$dlist"; then
        printf '%s: CANNOT-VERIFY — docker ps could not be read; nothing was judged\n' "$SCRIPT_NAME"
        rm -f "$dlist" "$raw" "$self" "$pstable" "$wtfile" "$snap"
        log "cannot-verify docker-unreadable"
        return 3
    fi
    # ⛔ A BLIND `ps` MUST ABORT THE WHOLE PASS, not merely keep every container: "kept" over a
    # population it could not see would read as "the reaper found nothing reapable", which is exactly
    # how a blind instrument licenses the leak it cannot see.
    if ! ps_table "$raw"; then
        printf '%s: CANNOT-VERIFY — ps could not be read; nothing was judged\n' "$SCRIPT_NAME"
        rm -f "$dlist" "$raw" "$self" "$pstable" "$wtfile" "$snap"
        log "cannot-verify ps-unreadable"
        return 3
    fi
    self_pids "$raw" "$self"
    clean_table "$raw" "$self" "$pstable"
    worktree_slugs "$wtfile" 2>/dev/null || : > "$wtfile"
    cat "$CLAIM_SNAP" > "$snap" 2>/dev/null || : > "$snap"

    local name state created row candidates=0 verdict reason cname
    while IFS=$'\t' read -r name state created; do
        [ -n "$name" ] || continue
        row="$(classify "$name" "$created" "$pstable" "$wtfile" "$snap")"
        [ -n "$row" ] || continue
        candidates=$((candidates + 1))
        verdict="${row%%$'\t'*}"; rest="${row#*$'\t'}"; reason="${rest%%$'\t'*}"; cname="${rest#*$'\t'}"
        case "$verdict" in
            reap)
                if [ "$DRY_RUN" = "1" ]; then
                    printf 'WOULD-REMOVE %s — %s\n' "$cname" "$reason"
                else
                    remove_one "$cname"
                fi
                ;;
            keep)
                KEPT=$((KEPT + 1)); printf 'KEEP %s — %s\n' "$cname" "$reason" ;;
            abstain)
                ABSTAINED=$((ABSTAINED + 1)); printf 'KEEP %s — %s (abstained: never reap on uncertainty)\n' "$cname" "$reason" ;;
        esac
    done < "$dlist"

    rm -f "$dlist" "$raw" "$self" "$pstable" "$wtfile" "$snap"

    if [ "$JSON" = "1" ]; then
        printf '{"candidates":%d,"removed":%d,"kept":%d,"abstained":%d,"failed":%d,"mode":"%s"}\n' \
            "$candidates" "$REMOVED" "$KEPT" "$ABSTAINED" "$FAILED" "$([ "$APPLY" = "1" ] && echo apply || echo dry-run)"
    else
        printf '%s: candidates=%d removed=%d kept=%d abstained=%d failed=%d mode=%s\n' \
            "$SCRIPT_NAME" "$candidates" "$REMOVED" "$KEPT" "$ABSTAINED" "$FAILED" \
            "$([ "$APPLY" = "1" ] && echo apply || echo dry-run)"
    fi
    log "pass candidates=$candidates removed=$REMOVED kept=$KEPT abstained=$ABSTAINED failed=$FAILED mode=$([ "$APPLY" = "1" ] && echo apply || echo dry-run)"
    [ "$ABSTAINED" -gt 0 ] && return 3
    [ "$FAILED" -gt 0 ] && return 4
    return 0
}

main "$@"
