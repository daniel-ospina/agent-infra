#!/usr/bin/env bash
# cleanup-stale-branches.sh — List (and optionally delete) stale branches.
# Notification-first: dry-run by default.
#
# Issue #74: Layer 4 server-side hygiene — deleteBranchOnMerge removes branches
# at merge time; the `remote` scope catches any stragglers.
#
# Issue #1787: the fleet SQUASH-MERGES, so a merged branch is NOT an ancestor of
# main and `git branch -r --merged origin/main` is nearly blind to this estate.
# Measured 2026-10-15: tortoise carries 1,153 branches with a MERGED PR while
# `--merged` reports only 199 — and the local branches pile up (2,125 in
# tortoise, 431 in agent-infra, 315 in DMeer, 135 in premise-labs). The
# `local` scope encodes the THREE gates a hand-sweep used to delete 2,236 of
# them, so the next sweep is not a fresh analysis.
#
# Usage:
#   bash scripts/cleanup-stale-branches.sh                        # remote dry-run
#   bash scripts/cleanup-stale-branches.sh --execute              # delete stale remote branches
#   bash scripts/cleanup-stale-branches.sh --scope local          # local dry-run
#   bash scripts/cleanup-stale-branches.sh --scope local --execute
#   bash scripts/cleanup-stale-branches.sh --scope both --execute
#   bash scripts/cleanup-stale-branches.sh --cutoff 21
#   bash scripts/cleanup-stale-branches.sh --scope local --pr-map-file /tmp/prs.json
#   bash scripts/cleanup-stale-branches.sh --scope local --pr-limit 20000
#   bash scripts/cleanup-stale-branches.sh --scope local --repo /path/to/checkout
#
# Default cutoff: 14 days. Default scope: remote (existing callers unchanged).
#
# ── local scope: the three gates ──────────────────────────────────
# A branch in refs/heads is selected for deletion ONLY when it is STALE (its
# tip commit is older than --cutoff) AND it matches one of:
#
#   merged      a MERGED pull request exists for that branch name, its base is
#               `main`, AND the local tip SHA equals that PR's `headRefOid` —
#               i.e. the local branch IS the revision that was merged. This is
#               the squash-merge-aware gate; without it the estate is nearly
#               invisible (above). The PR-state map is loaded ONCE.
#
#               A MERGED PR proves the PR's CONTENT landed; it does NOT prove
#               the local TIP is what landed. A branch can be squash-merged and
#               then committed to locally, and `-D` would destroy that
#               post-merge commit (it would survive only in the reflog). So the
#               tip is compared, and a tip that has moved past the merged
#               revision is KEPT and reported as `merged-tip-moved`. A PR merged
#               into a base other than `main` (a stacked PR) proves only that
#               the content is in THAT base — it is KEPT and reported as
#               `merged-base-not-main`, never force-deleted.
#   redundant   the branch has no commits outside origin/main
#               (`git rev-list --count origin/main..refs/heads/<br>` == 0).
#   remotecopy  the branch's upstream is on `origin` (ONLY origin), the
#               upstream ref RESOLVES, and the local branch has nothing the
#               upstream lacks
#               (`git rev-list --count <upstream>..refs/heads/<br>` == 0).
#               If the local branch is AHEAD of its upstream it is NOT safe:
#               those commits exist nowhere else. Local scope runs
#               `git fetch origin --prune` FIRST: without the prune, a branch
#               whose upstream was deleted server-side still has a local
#               refs/remotes/origin/<br> at the old tip, `rev-parse --verify`
#               succeeds, the ahead-count is 0, and `-d` removes the only
#               durable copy of those commits. If the fetch FAILS, the
#               remotecopy gate is DISABLED (fail-closed, and said loudly) —
#               exactly as a missing origin/main disables the redundant gate.
#               ⛔ An exit status of 0 is not proof the refs were refreshed: a
#               NEGATIVE refspec in origin's fetch config (an entry beginning
#               with `^`) makes `--prune` SKIP the excluded ref while the fetch
#               still succeeds, leaving the same stale ref behind. So a negative
#               refspec DISABLES the remotecopy gate too — the refspec is the
#               operator's to own, and the gate stands down rather than
#               rewriting it.
#               ⛔ The prune refreshes ONLY origin, so the gate is confined to
#               `origin/*`. A branch tracking any OTHER remote is NOT provably
#               fresh (a server-side delete there leaves a stale
#               refs/remotes/<other>/<br> that `rev-parse` still resolves), so
#               it is KEPT and reported as `non-origin-upstream` rather than
#               trusted. Fetching every branch's actual remote would be
#               per-branch network work with no bound.
#               ⚠️ That origin-confinement is a property of THIS gate ALONE,
#               not of the local scope. The `merged` and `redundant` gates are
#               evaluated BEFORE the upstream check, and when one of them
#               selects the branch it is deleted irrespective of its upstream:
#               neither premise reads the upstream ref. The
#               `non-origin-upstream` keep reason therefore means "no other
#               gate matched AND the upstream is not origin" — it does NOT mean
#               the branch was never selected.
#
# ALWAYS KEPT (never selected), each reported with its reason:
#   * any branch checked out in the main checkout or ANY worktree
#     (`git worktree list --porcelain`)
#   * `main` itself
#   * a branch with an OPEN pull request
#   * a MERGED PR whose local tip has moved past the merged revision
#     (`merged-tip-moved`)
#   * a MERGED PR whose base is not `main` (`merged-base-not-main`)
#   * anything matching none of the three gates (`localonly`)
#
# Deletion mechanics (local): `git branch -d` first. It falls back to
# `git branch -D` ONLY for the `merged` class — a branch squash-merged at a tip
# that has NOT moved is not an ancestor of main, so `-d` legitimately refuses,
# and `-D` is correct there and ONLY there. The other classes never use `-D`:
# `-d` is required to succeed on the branch's own evidence, or the branch stays
# put and is reported as failed.
#
# ── PR-state injection (the test seam) ────────────────────────────
# The branch→PR-state map is read ONCE, from the first source that resolves:
#   1. --pr-map-file <path>            a file holding the RAW `gh pr list --json
#                                      headRefName,state,headRefOid,baseRefName`
#                                      payload (a JSON array of objects)
#   2. CLEANUP_BRANCH_PR_MAP_JSON      the same payload inline (env)
#   3. `gh pr list --state all --limit N --json
#      headRefName,state,headRefOid,baseRefName`   (N = --pr-limit, default 10000)
#
# 1 and 2 are the injection seam: scripts/cleanup-stale-branches.test.sh uses a
# fixture file, so the suite needs no `gh`, no network and no real PRs. They are
# also the honest shape — the file IS what `gh` prints, so a fixture cannot
# drift from the real payload. If NO source resolves, local scope FAILS CLOSED
# (exit 1, nothing classified): the OPEN-PR keep rule cannot be evaluated, and
# an unreadable map is not an empty one.
#
# The payload is SHAPE-CHECKED before any of it is trusted: a JSON array, every
# element carrying a string `headRefName` and a `state` drawn from the enum
# `OPEN|CLOSED|MERGED`, and every MERGED element also carrying a string
# `headRefOid` and `baseRefName` (without them the merged gate cannot be
# evaluated). A non-array like `{}`, a non-empty array whose elements lack the
# fields, and a `state` outside the enum (e.g. a lowercase `"open"`, which
# matches neither fold arm and would silently bypass the OPEN-PR keep rule) are
# all REFUSED: `jq` iterating an empty OBJECT yields zero values and exits 0, so
# an unchecked `{}` silently disables the OPEN-PR keep rule — i.e. it deletes
# the branches of open PRs.
#
# An empty payload and an empty array are refused ONLY when they come from the
# injection seam (--pr-map-file / CLEANUP_BRANCH_PR_MAP_JSON): an injected `[]`
# is not evidence that the repository has no PRs. `gh` itself returning `[]` IS
# that evidence (the repository genuinely has zero PRs), so the gh source
# accepts it and the OPEN-PR rule holds vacuously — a repository with no PRs
# must still be able to run `--scope local`.
#
# The `gh` source is also checked for TRUNCATION: `gh` returns exactly --limit
# rows when more exist, so a full page is refused loudly rather than silently
# dropping the oldest PRs (a missing OPEN PR is an OPEN PR whose branch gets
# deleted). Raise --pr-limit above the repository's PR count.
#
# ── the opt-in report log ─────────────────────────────────────────
# The report is printed. Under launchd that output lands in the unified log and
# is not retrievable, so CLEANUP_BRANCH_LOG (set by
# templates/launchd/com.tortoise.branch-reaper.plist) also APPENDS it to that
# file, which is capped by TRUNCATING it before a pass once it exceeds
# CLEANUP_BRANCH_LOG_MAX_BYTES (default 1048576) — the same shape as
# pi-reap-worktrees.sh's REAP_WT_LOG. Unset (the terminal default, and the
# suite's) means print only.
#
# ── why the lookup is not per-branch ──────────────────────────────
# The map is parsed once with a single `jq` pass into two TAB-delimited
# membership strings. Bash 3.2 (macOS) has no associative arrays, so membership
# is `case` on those strings; git ref names cannot contain a TAB, so the
# sentinel cannot collide with a real branch. Calling jq (or gh) once per branch
# over a 3000-PR payload is quadratic and times out on the large repos above.
#
# ── --repo (why it exists) ────────────────────────────────────────
# Without it the checked-out tree is derived from ${BASH_SOURCE[0]}. The generic
# launchd launcher (scripts/pi-reap-worktrees-launchd.py) streams the script to
# `bash -s`, where BASH_SOURCE is EMPTY — so a scheduled pass must be told where
# the repo is. --repo (or CLEANUP_REPO_ROOT) is that seam, and it is what lets
# templates/launchd/com.tortoise.branch-reaper.plist use the shared launcher
# rather than a branch-reaper-specific one.

set -euo pipefail

SCRIPT_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
# REPO_ROOT precedence: --repo > CLEANUP_REPO_ROOT > the script's own checkout.
REPO_ROOT="${CLEANUP_REPO_ROOT:-}"
if [ -z "$REPO_ROOT" ] && [ -n "$SCRIPT_DIR" ]; then
    REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
fi

CUTOFF_DAYS=14
EXECUTE=false
SCOPE="remote"
PR_MAP_FILE=""
# 10000 is well above the largest estate measured (tortoise: 3,482 PRs on
# 2026-10-15). `gh` paginates internally up to --limit, and load_pr_map REFUSES
# a result whose count reaches the limit, so an estate that outgrows this is a
# loud refusal rather than a silently truncated map.
PR_LIMIT="${CLEANUP_PR_LIMIT:-10000}"
MAIN_BRANCH="main"
# Opt-in capped report log (unset = stdout only). See the header.
CLEANUP_BRANCH_LOG="${CLEANUP_BRANCH_LOG:-}"
CLEANUP_BRANCH_LOG_MAX_BYTES="${CLEANUP_BRANCH_LOG_MAX_BYTES:-1048576}"

help() {
    cat <<'EOF'
Usage: bash scripts/cleanup-stale-branches.sh [--scope remote|local|both]
                                              [--cutoff N] [--execute]
                                              [--pr-map-file PATH] [--pr-limit N]
                                              [--repo PATH]

  --scope SCOPE    Which branches to sweep:
                     remote (DEFAULT) — stale remote branches that are
                        ancestor-merged into origin/main (the #74 behaviour).
                     local — classify every branch in refs/heads and delete
                        only stale ones matching one of three gates: a MERGED
                        PR, redundant (no commits outside origin/main), or
                        remotecopy (nothing the upstream lacks).
                     both — remote, then local.
  --cutoff N       Days after which a branch is stale (default: 14).
  --execute        Delete stale branches (default: dry-run, list only).
  --pr-map-file P  local scope only: read the branch->PR-state map from P
                   instead of calling `gh`. P holds the raw `gh pr list --json
                   headRefName,state,headRefOid,baseRefName` payload (a JSON
                   array of {headRefName,state,headRefOid,baseRefName}). Env
                   CLEANUP_BRANCH_PR_MAP_JSON carries the same payload inline;
                   it has lower precedence. This is the seam the hermetic test
                   injects through.
  --pr-limit N     local scope only: max PRs `gh` may return (default 10000,
                   env CLEANUP_PR_LIMIT). Ignores injected maps. A result whose
                   count REACHES N is refused as truncated, never used.
  --repo PATH      Sweep the checkout at PATH instead of the tree this script
                   lives in. Required when the script is streamed to `bash -s`
                   (BASH_SOURCE is empty there). Env CLEANUP_REPO_ROOT works too.
  --help           Show this help.

Defaults: --scope remote, dry-run, 14-day cutoff.
EOF
}

# ── Parse args ────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --cutoff)
            CUTOFF_DAYS="${2:-}"
            shift 2
            ;;
        --scope)
            SCOPE="${2:-}"
            shift 2
            ;;
        --pr-map-file)
            PR_MAP_FILE="${2:-}"
            shift 2
            ;;
        --pr-limit)
            PR_LIMIT="${2:-}"
            shift 2
            ;;
        --repo)
            REPO_ROOT="${2:-}"
            shift 2
            ;;
        --execute)
            EXECUTE=true
            shift
            ;;
        --help|-h)
            help
            exit 0
            ;;
        *)
            echo "Unknown arg: $1 (use --help)" >&2
            exit 1
            ;;
    esac
done

# Validate cutoff is a positive integer
if ! [[ "$CUTOFF_DAYS" =~ ^[0-9]+$ ]] || [ "$CUTOFF_DAYS" -lt 1 ]; then
    echo "ERROR: --cutoff must be a positive integer, got '$CUTOFF_DAYS'" >&2
    exit 1
fi

# Validate the PR-map limit is a positive integer
if ! [[ "$PR_LIMIT" =~ ^[0-9]+$ ]] || [ "$PR_LIMIT" -lt 1 ]; then
    echo "ERROR: --pr-limit must be a positive integer, got '$PR_LIMIT'" >&2
    exit 1
fi

case "$SCOPE" in
    remote|local|both) ;;
    *)
        echo "ERROR: --scope must be remote, local or both, got '$SCOPE'" >&2
        exit 1
        ;;
esac

if [ -z "$REPO_ROOT" ] || [ ! -d "$REPO_ROOT" ]; then
    echo "ERROR: no checkout to sweep (REPO_ROOT='${REPO_ROOT:-}'). Use --repo PATH or CLEANUP_REPO_ROOT." >&2
    exit 1
fi
REPO_ROOT="$(cd "$REPO_ROOT" && pwd)"

cd "$REPO_ROOT"

cutoff_epoch() {
    date -v-${CUTOFF_DAYS}d +%s 2>/dev/null || date -d "${CUTOFF_DAYS} days ago" +%s
}

# ── Shared: the PR-state seam ─────────────────────────────────────
# github_slug <url> — owner/repo for a github.com origin, else empty.
github_slug() {
    case "${1:-}" in
        *github.com[:/]*)
            printf '%s\n' "$1" | sed -E 's#^[^/]*//##; s#^git@##; s#github\.com[:/]##; s#\.git$##'
            ;;
        *) printf '' ;;
    esac
}

# load_pr_map <file> — prints "STATE<TAB>branch<TAB>headRefOid<TAB>base" lines,
# ONE line per PR. Non-zero exit (and no output) when no source resolves, when
# the payload is EMPTY, when its SHAPE is wrong, or when the `gh` result is
# TRUNCATED at --pr-limit: the caller fails closed on every one of those.
load_pr_map() {
    local file="$1" src="" from_gh=0
    if [ -n "$file" ]; then
        if [ ! -r "$file" ]; then
            echo "PR map file not readable: $file" >&2
            return 1
        fi
        src="$(cat "$file")" || return 1
    elif [ -n "${CLEANUP_BRANCH_PR_MAP_JSON:-}" ]; then
        src="$CLEANUP_BRANCH_PR_MAP_JSON"
    else
        local url="" slug=""
        if url="$(git remote get-url origin 2>/dev/null)"; then
            slug="$(github_slug "$url")"
        fi
        if [ -z "$slug" ]; then
            echo "no github.com origin — cannot read PR state; pass --pr-map-file" >&2
            return 1
        fi
        if ! command -v gh >/dev/null 2>&1; then
            echo "gh not found on PATH" >&2
            return 1
        fi
        from_gh=1
        # gh's stderr is captured to its OWN file: merging it into $src would
        # corrupt the JSON, and discarding it (2>/dev/null) throws away the only
        # diagnosis of WHY the fetch failed. $? is read immediately after the
        # command — inside a `then` branch of `if ! cmd` it is the status of
        # `!`, which is always 0.
        local errf="" gh_rc=0
        errf="$(mktemp "${TMPDIR:-/tmp}/cleanup-branch-gh.XXXXXX" 2>/dev/null)" || errf=""
        if [ -n "$errf" ]; then
            src="$(gh pr list --state all --limit "$PR_LIMIT" \
                    --json headRefName,state,headRefOid,baseRefName 2>"$errf")" || gh_rc=$?
        else
            src="$(gh pr list --state all --limit "$PR_LIMIT" \
                    --json headRefName,state,headRefOid,baseRefName)" || gh_rc=$?
        fi
        if [ "$gh_rc" -ne 0 ]; then
            echo "gh pr list failed (rc=$gh_rc)" >&2
            if [ -n "$errf" ] && [ -s "$errf" ]; then
                sed 's/^/  gh: /' "$errf" >&2 || true
            fi
            [ -z "$errf" ] || rm -f "$errf"
            return 1
        fi
        [ -z "$errf" ] || rm -f "$errf"
    fi
    if ! command -v jq >/dev/null 2>&1; then
        echo "jq not found on PATH (needed to parse the PR map)" >&2
        return 1
    fi

    # ── fail closed on EMPTY input ────────────────────────────────
    # `printf '' | jq` reads no document, prints nothing and exits 0, so an
    # empty payload would silently become an empty keep-set — the OPEN-PR rule
    # disabled without a word.
    if [ -z "${src//[[:space:]]/}" ]; then
        echo "PR map is EMPTY — refusing: an empty map is not an empty PR rule" >&2
        return 1
    fi

    # ── fail closed on the SHAPE ──────────────────────────────────
    # `{}` is the trap this catches: `jq` iterates an empty OBJECT to zero
    # values and exits 0, which disables the OPEN-PR keep rule exactly as an
    # empty file does. ONE jq pass asserts every field the two rules read.
    #
    # `--argjson from_gh` carries the SOURCE distinction: an empty array from
    # `gh` is authoritative (the repository has no PRs, so the OPEN-PR rule is
    # vacuously satisfied and the pass may run), while an empty array injected
    # through the seam is not evidence of anything and is refused.
    local shape_err="" shape_rc=0
    shape_err="$(printf '%s' "$src" | jq -r --argjson from_gh "$from_gh" '
        if type != "array" then
          "not a JSON array (top-level type: \(type))"
        elif length == 0 then
          if $from_gh == 1 then empty
          else "an empty array — the OPEN-PR keep rule would silently not be applied" end
        else
          ([ .[] | select((.headRefName|type) != "string" or (.state|type) != "string") ] | length) as $bad
          | if $bad > 0 then
              "\($bad) element(s) lack a string headRefName and/or state"
            else
              ([ .[] | select(.state != "OPEN" and .state != "CLOSED" and .state != "MERGED") ] | length) as $badst
              | if $badst > 0 then
                  "\($badst) element(s) carry a state outside OPEN|CLOSED|MERGED (gh emits uppercase; a case variant such as \"open\" would silently bypass the OPEN-PR keep rule)"
                else
                  ([ .[] | select(.state == "MERGED")
                           | select((.headRefOid|type) != "string" or (.baseRefName|type) != "string") ] | length) as $badm
                  | if $badm > 0 then
                      "\($badm) MERGED element(s) lack a string headRefOid and/or baseRefName (the merged gate cannot be evaluated)"
                    else empty end
                end
            end
        end' 2>&1)" || shape_rc=$?
    if [ "$shape_rc" -ne 0 ] || [ -n "$shape_err" ]; then
        echo "PR map refused: ${shape_err:-malformed JSON}" >&2
        return 1
    fi

    # ── refuse a TRUNCATED gh result ──────────────────────────────
    # gh returns exactly --limit rows when more exist. The oldest PRs are then
    # absent from the map, and a MISSING OPEN PR is an OPEN PR whose branch gets
    # deleted — so a full page is a refusal, not a warning.
    if [ "$from_gh" = 1 ]; then
        local n
        n="$(printf '%s' "$src" | jq 'length' 2>/dev/null)" || return 1
        case "$n" in ''|*[!0-9]*) return 1 ;; esac
        if [ "$n" -ge "$PR_LIMIT" ]; then
            echo "PR map TRUNCATED: gh returned $n PR(s) and the --limit is $PR_LIMIT, so older PRs are missing" >&2
            echo "                 (an absent OPEN PR cannot keep its branch). Raise --pr-limit/CLEANUP_PR_LIMIT above the" >&2
            echo "                 repository's PR count, or pass --pr-map-file with a complete map." >&2
            return 1
        fi
    fi

    printf '%s' "$src" | jq -r '.[] | "\(.state)\t\(.headRefName)\t\(.headRefOid)\t\(.baseRefName)"'
}

# is_member <tab-delimited lookup> <name> — exact membership, no fork.
# Git ref names cannot contain a TAB (check-ref-format), so the sentinel cannot
# collide with a real branch name.
is_member() {
    case "$1" in
        *$'\t'"$2"$'\t'*) return 0 ;;
    esac
    return 1
}

# ── remote scope (unchanged behaviour, #74) ───────────────────────
run_remote_scope() {
    # ── Sanity check: on main, up to date ─────────────────────────
    local CURRENT_BRANCH
    CURRENT_BRANCH="$(git branch --show-current)"
    if [ "$CURRENT_BRANCH" != "$MAIN_BRANCH" ]; then
        echo "WARNING: not on $MAIN_BRANCH (currently on '$CURRENT_BRANCH') — pruning remote refs anyway" >&2
    fi

    echo "=== Stale Branch Cleanup ==="
    echo "Cutoff:  $CUTOFF_DAYS days"
    echo "Mode:    $([ "$EXECUTE" = true ] && echo 'EXECUTE (will delete)' || echo 'DRY-RUN (list only)')"
    echo "Repo:    $REPO_ROOT"
    echo ""

    # ── Fetch and prune remote tracking refs ──────────────────────
    echo "[$(date '+%H:%M:%S')] Fetching and pruning remote refs..."
    git fetch origin --prune --quiet
    echo ""

    # ── Find stale merged branches ────────────────────────────────
    # Strategy:
    #   1. git branch -r --merged origin/main → all remote branches merged into main
    #   2. Exclude origin/main and origin/HEAD
    #   3. Check committer-date of last commit on each branch (< CUTOFF_DAYS ago)
    #   4. Collect stale candidates

    local STALE_BRANCHES=()
    local CUTOFF_EPOCH
    CUTOFF_EPOCH="$(cutoff_epoch)"

    while IFS= read -r branch; do
        # Strip leading whitespace, skip origin/main and origin/HEAD
        branch="$(echo "$branch" | sed 's/^[[:space:]]*//')"
        [ -z "$branch" ] && continue
        [ "$branch" = "origin/$MAIN_BRANCH" ] && continue
        [[ "$branch" == origin/HEAD* ]] && continue

        # Check if branch commit date is before cutoff
        local COMMIT_DATE
        COMMIT_DATE="$(git log -1 --format='%ct' "$branch" 2>/dev/null || echo "0")"
        if [ "$COMMIT_DATE" = "0" ]; then
            echo "  ⚠️  Skipping $branch (unable to read commit date)" >&2
            continue
        fi

        if [ "$COMMIT_DATE" -lt "$CUTOFF_EPOCH" ]; then
            local COMMIT_DATE_HR
            COMMIT_DATE_HR="$(date -r "$COMMIT_DATE" '+%Y-%m-%d' 2>/dev/null || date -d "@$COMMIT_DATE" '+%Y-%m-%d')"
            STALE_BRANCHES+=("$branch|$COMMIT_DATE_HR")
        fi
    done < <(git branch -r --merged "origin/$MAIN_BRANCH" 2>/dev/null || true)

    # ── Output ────────────────────────────────────────────────────
    if [ ${#STALE_BRANCHES[@]} -eq 0 ]; then
        echo "✅ No stale merged branches found (cutoff: $CUTOFF_DAYS days)."
        return 0
    fi

    echo "Found ${#STALE_BRANCHES[@]} stale merged branch(es):"
    echo ""
    local entry branch commit_date_hr
    for entry in "${STALE_BRANCHES[@]}"; do
        branch="${entry%%|*}"
        commit_date_hr="${entry##*|}"
        printf "  %-55s last commit: %s\n" "$branch" "$commit_date_hr"
    done
    echo ""

    if [ "$EXECUTE" = false ]; then
        echo "── DRY-RUN: no branches deleted ──"
        echo "To delete: bash scripts/cleanup-stale-branches.sh --execute"
        echo ""
        echo "Deletion commands that would run:"
        for entry in "${STALE_BRANCHES[@]}"; do
            branch="${entry%%|*}"
            local local_branch="${branch#origin/}"
            echo "  git push origin --delete \"$local_branch\""
        done
        return 0
    fi

    # ── Execute: delete stale branches ────────────────────────────
    echo "── EXECUTE: deleting ${#STALE_BRANCHES[@]} stale branches ──"
    echo ""
    local DELETED=0
    local FAILED=0

    for entry in "${STALE_BRANCHES[@]}"; do
        branch="${entry%%|*}"
        local local_branch="${branch#origin/}"

        echo "  Deleting origin/$local_branch..."
        if git push origin --delete "$local_branch" 2>&1; then
            echo "    ✅ deleted"
            DELETED=$((DELETED + 1))
        else
            echo "    ❌ failed (may already be deleted or protected)"
            FAILED=$((FAILED + 1))
        fi
    done

    echo ""
    echo "── Summary ──"
    echo "  Deleted: $DELETED"
    echo "  Failed:  $FAILED"
    echo "  Total:   ${#STALE_BRANCHES[@]}"

    return 0
}

# ── local scope (#1787) ───────────────────────────────────────────
run_local_scope() {
    if ! git rev-parse --git-dir >/dev/null 2>&1; then
        echo "ERROR: $REPO_ROOT is not a git repository" >&2
        return 1
    fi

    echo "=== Stale Local Branch Cleanup ==="
    echo "Cutoff:  $CUTOFF_DAYS days"
    echo "Mode:    $([ "$EXECUTE" = true ] && echo 'EXECUTE (will delete)' || echo 'DRY-RUN (list only)')"
    echo "Repo:    $REPO_ROOT"
    echo ""

    # ── PR state, loaded ONCE ─────────────────────────────────────
    # Fail closed: if the map is unreadable, the OPEN-PR keep rule cannot be
    # evaluated and we refuse to classify anything. (An absent map is not an
    # empty one.)
    local pr_source
    if [ -n "$PR_MAP_FILE" ]; then
        pr_source="file:$PR_MAP_FILE"
    elif [ -n "${CLEANUP_BRANCH_PR_MAP_JSON:-}" ]; then
        pr_source="env:CLEANUP_BRANCH_PR_MAP_JSON"
    else
        pr_source="gh"
    fi
    echo "[$(date '+%H:%M:%S')] Loading PR state ($pr_source)..."

    local pr_lines
    if ! pr_lines="$(load_pr_map "$PR_MAP_FILE")"; then
        echo "ERROR: could not read the PR-state map — refusing to classify local branches." >&2
        echo "       The OPEN-PR keep rule needs it; an unreadable, EMPTY or wrong-shaped map is not an empty one." >&2
        return 1
    fi

    # The map is folded into three `case`-matchable membership strings (Bash 3.2
    # has no associative arrays, and one jq/gh call per branch is quadratic):
    #   open_lookup          \tbr\t            an OPEN PR — always kept
    #   merged_main_lookup   \tbr\t            a MERGED PR based on main
    #   merged_ok_lookup     \tbr:<sha>\t      ... at THAT merged revision
    #   merged_offbase_lookup\tbr\t            a MERGED PR based on something else
    # A git ref name cannot contain a TAB or a `:`, so neither sentinel can
    # collide with a real branch name.
    local merged_main_lookup="" merged_ok_lookup="" merged_offbase_lookup="" open_lookup=""
    local st br oid base
    while IFS=$'\t' read -r st br oid base; do
        [ -n "${br:-}" ] || continue
        case "$st" in
            OPEN)
                open_lookup="${open_lookup}"$'\t'"$br"$'\t' ;;
            MERGED)
                # A PR merged into a base other than main proves only that its
                # content is in THAT base. Treat it as "not merged into main".
                if [ "$base" = "$MAIN_BRANCH" ]; then
                    merged_main_lookup="${merged_main_lookup}"$'\t'"$br"$'\t'
                    merged_ok_lookup="${merged_ok_lookup}"$'\t'"$br:$oid"$'\t'
                else
                    merged_offbase_lookup="${merged_offbase_lookup}"$'\t'"$br"$'\t'
                fi ;;
        esac
    done <<<"$pr_lines"
    echo ""

    # ── refresh remote-tracking refs (the remotecopy gate depends on them) ──
    # The remote scope already prunes. Without it here, a branch whose upstream
    # was deleted server-side keeps a local refs/remotes/origin/<br> at the old
    # tip: `rev-parse --verify` succeeds, the ahead-count is 0, it is classed
    # `remotecopy`, and `-d` deletes the only durable copy of its commits. A
    # failure (offline, unreachable origin) must NOT be read as "the refs are
    # fresh": the gate is DISABLED instead, loudly, exactly as a missing
    # origin/main disables the redundant gate below.
    # ⛔ A fetch that EXITS 0 does not prove the refs were REFRESHED. A NEGATIVE
    # refspec in remote.origin.fetch (an entry beginning with `^`, e.g.
    # `^refs/heads/foo`) makes `--prune` SKIP the excluded ref while the fetch
    # still exits 0: the stale refs/remotes/origin/foo survives, `rev-parse
    # --verify` succeeds, the ahead-count is 0, the branch is classed
    # `remotecopy`, and `-d` deletes the only durable copy of its commits. The
    # refspec belongs to the OPERATOR — the gate stands down (it does not rewrite
    # the config), exactly as a failed fetch makes it stand down.
    local remote_refs_ok=0
    echo "[$(date '+%H:%M:%S')] Fetching origin --prune (the remotecopy gate reads its refs)..."
    if git fetch origin --prune --quiet; then
        local fetch_refspecs=""
        fetch_refspecs="$(git config --get-all remote.origin.fetch 2>/dev/null || true)"
        # A here-string, NOT `printf ... | grep -q`: under `pipefail` the producer
        # can die of SIGPIPE before grep reads a short payload, and the whole test
        # then reports 'no match' for input that DOES match. That false negative
        # here would read as "no negative refspec" and re-enable the very gate
        # this check exists to disable (#841).
        if grep -q '^\^' <<<"$fetch_refspecs"; then
            echo "WARNING: remote.origin.fetch carries a NEGATIVE refspec (an entry beginning with '^')." >&2
            echo "WARNING: 'git fetch origin --prune' exited 0 but SKIPS the excluded ref, so the" >&2
            echo "WARNING: remote-tracking refs are NOT provably fresh." >&2
            echo "WARNING: the remotecopy gate is DISABLED (fail-closed): a deleted server-side upstream would" >&2
            echo "WARNING: leave a local origin/<br> at the old tip, and deleting on it would remove the only" >&2
            echo "WARNING: durable copy of those commits. The negative refspec is the operator's to own —" >&2
            echo "WARNING: remove it and re-run; this pass will not rewrite it." >&2
        else
            remote_refs_ok=1
            echo "[$(date '+%H:%M:%S')] remote-tracking refs refreshed — remotecopy gate enabled."
        fi
    else
        echo "WARNING: git fetch origin --prune FAILED — remote-tracking refs may be STALE." >&2
        echo "WARNING: the remotecopy gate is DISABLED (fail-closed): a deleted server-side upstream would" >&2
        echo "WARNING: leave a local origin/<br> at the old tip, and deleting on it would remove the only" >&2
        echo "WARNING: durable copy of those commits. Re-run once origin is reachable." >&2
    fi

    # ── branches checked out anywhere (main checkout + every worktree) ──
    # ⛔ FAIL-CLOSED: an unguarded enumeration whose failure yields an EMPTY
    # wt_lookup silently defeats the worktree keep-rule (a checked-out branch
    # would then be classified as if no worktree held it). The rule's job is to
    # keep such a branch, so a failure to read the worktree list must abort the
    # pass, exactly like the refs/heads enumeration below.
    local wt_lookup="" wb wt_out
    if ! wt_out="$(git worktree list --porcelain)"; then
        echo "ERROR: could not enumerate worktrees (git worktree list --porcelain failed)" >&2
        return 1
    fi
    while IFS= read -r wb; do
        [ -n "$wb" ] || continue
        wt_lookup="${wt_lookup}"$'\t'"$wb"$'\t'
    done < <(printf '%s\n' "$wt_out" | sed -n 's|^branch refs/heads/||p')

    local main_ref_ok=0
    if git rev-parse --verify -q "origin/$MAIN_BRANCH" >/dev/null 2>&1; then
        main_ref_ok=1
        echo "[$(date '+%H:%M:%S')] origin/$MAIN_BRANCH resolves — redundant gate enabled."
    else
        echo "WARNING: origin/$MAIN_BRANCH does not resolve — the redundant gate is disabled (fail-closed)." >&2
    fi

    local CUTOFF_EPOCH
    CUTOFF_EPOCH="$(cutoff_epoch)"

    local branches
    # ⛔ FIELD ORDER MATTERS: `read` with IFS=TAB collapses a RUN of tabs and
    # strips trailing ones, so an EMPTY middle field shifts every field after it.
    # `%(upstream:short)` is empty for every branch with no upstream, so it MUST
    # be the LAST field — when it sat third, `sha` slid into `up` and an upstream
    # check ran against a commit SHA (`rev-parse` resolves a 40-hex string,
    # `rev-list --count <own-tip>..<br>` is 0, and the branch was classed
    # `remotecopy`). The test's `keep localonly` assertions are what caught it.
    #
    # ⛔ FIELD 1 IS `%(refname:lstrip=2)`, NOT `%(refname:short)`. `:short`
    # DISAMBIGUATES against tags: with a tag sharing a branch's name, git renders
    # the branch as `heads/<name>` (verified: a tag `foo` makes the branch print
    # `heads/foo`). Every keep-rule and gate keys on the PLAIN name, so such a
    # branch would miss the worktree and OPEN-PR rules and no gate could resolve
    # it (`refs/heads/heads/foo` does not exist) — a false selection reported as
    # a delete that then fails. `lstrip=2` strips `refs/heads/` unconditionally,
    # so the name is plain regardless of any same-named tag.
    if ! branches="$(git for-each-ref \
            --format='%(refname:lstrip=2)%09%(committerdate:unix)%09%(objectname)%09%(upstream:short)' \
            refs/heads)"; then
        echo "ERROR: could not enumerate refs/heads" >&2
        return 1
    fi

    local delete_list="" keep_list=""
    local sel_total=0 sel_merged=0 sel_redundant=0 sel_remotecopy=0
    local keep_total=0 keep_worktree=0 keep_main=0 keep_openpr=0 keep_notstale=0 keep_localonly=0
    local keep_tipmoved=0 keep_offbase=0 keep_nonorigin=0

    # cdate = committer date (seconds); sha = the tip's object name, compared
    # against a MERGED PR's headRefOid; up = the upstream ref (empty = none).
    local br cdate sha up cls cnt
    while IFS=$'\t' read -r br cdate sha up; do
        [ -n "$br" ] || continue

        # 1. main itself
        if [ "$br" = "$MAIN_BRANCH" ]; then
            keep_list="${keep_list}main"$'\t'"$br"$'\n'
            keep_main=$((keep_main + 1)); keep_total=$((keep_total + 1)); continue
        fi
        # 2. checked out in the main checkout or ANY worktree
        if is_member "$wt_lookup" "$br"; then
            keep_list="${keep_list}worktree"$'\t'"$br"$'\n'
            keep_worktree=$((keep_worktree + 1)); keep_total=$((keep_total + 1)); continue
        fi
        # 3. not stale
        if [ -z "$cdate" ] || [ "$cdate" -ge "$CUTOFF_EPOCH" ]; then
            keep_list="${keep_list}not-stale"$'\t'"$br"$'\n'
            keep_notstale=$((keep_notstale + 1)); keep_total=$((keep_total + 1)); continue
        fi
        # 4. OPEN PR
        if is_member "$open_lookup" "$br"; then
            keep_list="${keep_list}open-pr"$'\t'"$br"$'\n'
            keep_openpr=$((keep_openpr + 1)); keep_total=$((keep_total + 1)); continue
        fi

        # 5. the three gates — first match wins (merged first: it is the only
        #    class that authorizes `-D`, and it is the strongest evidence).
        cls=""
        if is_member "$merged_main_lookup" "$br"; then
            # A MERGED PR whose base is main proves the PR's CONTENT landed; it
            # does NOT prove the local TIP is the revision that landed. Only a
            # tip equal to the PR's headRefOid may be force-deleted — a tip that
            # has moved past it holds a post-merge commit that exists nowhere
            # durable, so the branch is KEPT with a distinct reason.
            if is_member "$merged_ok_lookup" "$br:$sha"; then
                cls="merged"
            else
                keep_list="${keep_list}merged-tip-moved"$'\t'"$br"$'\n'
                keep_tipmoved=$((keep_tipmoved + 1)); keep_total=$((keep_total + 1)); continue
            fi
        elif is_member "$merged_offbase_lookup" "$br"; then
            # Merged into a base that is not main (a stacked PR): the content is
            # in that base, not in main, so the redundant/remotecopy evidence
            # would have to carry it — and neither gate matches here.
            keep_list="${keep_list}merged-base-not-main"$'\t'"$br"$'\n'
            keep_offbase=$((keep_offbase + 1)); keep_total=$((keep_total + 1)); continue
        fi
        if [ -z "$cls" ] && [ "$main_ref_ok" = 1 ]; then
            cnt="$(git rev-list --count "origin/$MAIN_BRANCH..refs/heads/$br" 2>/dev/null || echo -1)"
            if [ "$cnt" = "0" ]; then
                cls="redundant"
            fi
        fi
        if [ -z "$cls" ] && [ "$remote_refs_ok" = 1 ] && [ -n "$up" ]; then
            # ⛔ The prune above refreshed ONLY origin, so the remotecopy premise
            # ("the upstream ref reflects the server") holds for `origin/*`
            # ALONE. A branch tracking any other remote may have a stale
            # refs/remotes/<other>/<br> left by a server-side delete there;
            # `rev-parse` still resolves it and the ahead-count is 0. Trusting
            # it would delete the only durable copy of those commits, so such a
            # branch is KEPT and named, never confined to `localonly` silently.
            case "$up" in
                origin/*)
                    # The upstream ref must RESOLVE before its count means
                    # anything: a branch whose remote counterpart was already
                    # deleted is not a `remotecopy` (rev-list would fail, and
                    # `-1` never equals 0). The prune above is what makes this
                    # true for a ref deleted SERVER-SIDE; if the prune could not
                    # run, the whole gate is off.
                    if git rev-parse --verify -q "$up" >/dev/null 2>&1; then
                        cnt="$(git rev-list --count "$up..refs/heads/$br" 2>/dev/null || echo -1)"
                        if [ "$cnt" = "0" ]; then
                            cls="remotecopy"
                        fi
                    fi ;;
                *)
                    keep_list="${keep_list}non-origin-upstream"$'\t'"$br"$'\n'
                    keep_nonorigin=$((keep_nonorigin + 1)); keep_total=$((keep_total + 1)); continue ;;
            esac
        fi

        if [ -z "$cls" ]; then
            keep_list="${keep_list}localonly"$'\t'"$br"$'\n'
            keep_localonly=$((keep_localonly + 1)); keep_total=$((keep_total + 1)); continue
        fi

        delete_list="${delete_list}${cls}"$'\t'"$br"$'\n'
        sel_total=$((sel_total + 1))
        case "$cls" in
            merged)    sel_merged=$((sel_merged + 1)) ;;
            redundant) sel_redundant=$((sel_redundant + 1)) ;;
            remotecopy) sel_remotecopy=$((sel_remotecopy + 1)) ;;
        esac
    done <<<"$branches"

    echo "[$(date '+%H:%M:%S')] Classified $((sel_total + keep_total)) local branch(es)."
    echo ""

    # ── SELECTED ──────────────────────────────────────────────────
    echo "── SELECTED: $sel_total stale local branch(es) match a deletion gate ──"
    if [ "$sel_total" -eq 0 ]; then
        echo "  (none)"
    else
        while IFS=$'\t' read -r cls br; do
            [ -n "$cls" ] || continue
            printf '  delete %-10s %s\n' "$cls" "$br"
        done <<<"$delete_list"
    fi
    echo ""

    # ── EXECUTE or DRY-RUN ────────────────────────────────────────
    local deleted=0 failed=0
    if [ "$EXECUTE" = true ] && [ "$sel_total" -gt 0 ]; then
        echo "── EXECUTE: deleting $sel_total stale local branch(es) ──"
        echo ""
        while IFS=$'\t' read -r cls br; do
            [ -n "$cls" ] || continue
            if git branch -d "$br" >/dev/null 2>&1; then
                printf '  deleted %-10s %s\n' "$cls" "$br"
                deleted=$((deleted + 1))
            elif [ "$cls" = "merged" ] && git branch -D "$br" >/dev/null 2>&1; then
                # Squash-merged AND unmoved: the classification already proved
                # the local tip IS the revision the PR merged (it equalled
                # headRefOid), so `-d` refuses only because the squash commit is
                # not an ancestor of main. `-D` is correct ONLY here.
                printf '  deleted %-10s %s (via -D: squash-merged PR)\n' "$cls" "$br"
                deleted=$((deleted + 1))
            else
                printf '  failed  %-10s %s (git branch -d refused; -D not allowed for this class)\n' "$cls" "$br"
                failed=$((failed + 1))
            fi
        done <<<"$delete_list"
        echo ""
    elif [ "$sel_total" -gt 0 ]; then
        echo "── DRY-RUN: no branches deleted ──"
        echo "To delete: bash scripts/cleanup-stale-branches.sh --scope local --execute"
        echo ""
        echo "Deletion commands that would run (-D fallback only for the merged class):"
        while IFS=$'\t' read -r cls br; do
            [ -n "$cls" ] || continue
            printf '  git branch -d "%s"   # class=%s\n' "$br" "$cls"
        done <<<"$delete_list"
        echo ""
    else
        # The header above already says EXECUTE (will delete); the nothing-to-
        # delete arm must not contradict it with a DRY-RUN label.
        if [ "$EXECUTE" = true ]; then
            echo "── EXECUTE: nothing to delete ──"
        else
            echo "── DRY-RUN: nothing to delete ──"
        fi
        echo ""
    fi

    # ── KEPT ──────────────────────────────────────────────────────
    echo "── KEPT: $keep_total branch(es) ──"
    while IFS=$'\t' read -r cls br; do
        [ -n "$cls" ] || continue
        printf '  keep   %-10s %s\n' "$cls" "$br"
    done <<<"$keep_list"
    echo ""

    echo "── Summary ──"
    echo "  Selected:  $sel_total (merged: $sel_merged, redundant: $sel_redundant, remotecopy: $sel_remotecopy)"
    if [ "$EXECUTE" = true ]; then
        echo "  Deleted:   $deleted"
        echo "  Failed:    $failed"
    else
        echo "  Deleted:   0 (dry-run)"
        echo "  Failed:    0 (dry-run)"
    fi
    echo "  Kept:      $keep_total (worktree: $keep_worktree, main: $keep_main, open-pr: $keep_openpr, not-stale: $keep_notstale, merged-tip-moved: $keep_tipmoved, merged-base-not-main: $keep_offbase, non-origin-upstream: $keep_nonorigin, localonly: $keep_localonly)"
    echo ""

    return 0
}

# ── Dispatch ──────────────────────────────────────────────────────
run_scopes() {
    case "$SCOPE" in
        remote) run_remote_scope ;;
        local)  run_local_scope ;;
        both)
            run_remote_scope
            run_local_scope
            ;;
    esac
}

# ── opt-in capped report log (see the header) ─────────────────────
# Truncate BEFORE a pass once the file has outgrown the cap, so the log holds
# the most recent passes and cannot grow without bound. `wc -c` (not `stat -f`)
# keeps this cross-platform.
cap_report_log() {
    local f="$1" max="$2" size
    [ -e "$f" ] || return 0
    size="$(wc -c <"$f" 2>/dev/null | tr -d '[:space:]')" || return 0
    case "$size" in ''|*[!0-9]*) return 0 ;; esac
    if [ "$size" -ge "$max" ]; then
        : >"$f" 2>/dev/null || true
    fi
}

if [ -n "$CLEANUP_BRANCH_LOG" ]; then
    mkdir -p "$(dirname "$CLEANUP_BRANCH_LOG")" 2>/dev/null || true
    if ! : >>"$CLEANUP_BRANCH_LOG" 2>/dev/null; then
        echo "WARNING: CLEANUP_BRANCH_LOG is not writable ($CLEANUP_BRANCH_LOG) — the report goes to stdout only." >&2
        run_scopes
        exit 0
    fi
    cap_report_log "$CLEANUP_BRANCH_LOG" "$CLEANUP_BRANCH_LOG_MAX_BYTES"
    {
        printf '── %s (scope=%s, mode=%s) ──\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" "$SCOPE" \
            "$([ "$EXECUTE" = true ] && echo EXECUTE || echo DRY-RUN)"
    } >>"$CLEANUP_BRANCH_LOG" 2>/dev/null || true
    # tee keeps the report on stdout (a terminal run stays identical) AND in the
    # log. PIPESTATUS[0] is the pass's own status: the fail-closed refusals must
    # keep their non-zero exit through the pipe.
    set +e
    run_scopes 2>&1 | tee -a "$CLEANUP_BRANCH_LOG"
    rc=${PIPESTATUS[0]}
    set -e
    exit "$rc"
fi

run_scopes

exit 0
