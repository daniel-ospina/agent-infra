#!/usr/bin/env bash
# ── the portability shim (#2048) ────────────────────────────────────────────────────────────────
# ONE shim for the four platform differences that made components install and then fail to EXECUTE
# on one platform (#2046: macOS ships no `timeout`; `nproc`, `stat -c` and `date -d` are GNU-only).
# Every scheduled component sources it, so a helper used here cannot be a GNU-only spelling. A shim
# that cannot be loaded is a REFUSAL AT STARTUP (exit 3): running on with no helper is exactly the
# #2046 shape — the work silently does not happen while the component reports a considered result.
_PORTABLE_LIB="${PORTABLE_LIB:-}"
if [ -z "$_PORTABLE_LIB" ]; then
    _portable_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
    # `<script dir>/lib` covers `scripts/*.sh`; `<script dir>/../lib` covers a component that lives
    # in a subdirectory (`scripts/checkout-hygiene/`, `scripts/fleet/`); the farm copy is what a cell
    # actually has after `pi-bootstrap/setup.sh`.
    for _portable_cand in "$_portable_self_dir/lib/portable.sh" \
                          "$_portable_self_dir/../lib/portable.sh" \
                          "${HOME:-}/.pi/agent/scripts/lib/portable.sh"; do
        [ -n "$_portable_cand" ] && [ -f "$_portable_cand" ] && { _PORTABLE_LIB="$_portable_cand"; break; }
    done
fi
if [ ! -f "${_PORTABLE_LIB:-}" ]; then
    printf '%s: FAIL-CLOSED at startup — the portability shim is missing (%s)\n' \
        "${0##*/}" "${_PORTABLE_LIB:-not beside this script and not in ${HOME:-}/.pi/agent/scripts/lib/}" >&2
    exit 3
fi
# shellcheck source=lib/portable.sh
. "$_PORTABLE_LIB"

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
#               then committed to locally, and the force-delete fallback would
#               destroy that post-merge commit (it would survive only in the
#               reflog). So the tip is compared, and a tip that has moved past
#               the merged revision is KEPT and reported as `merged-tip-moved`.
#               A PR merged
#               into a base other than `main` (a stacked PR) proves only that
#               the content is in THAT base — it is KEPT and reported as
#               `merged-base-not-main` UNLESS another gate (redundant or
#               remotecopy) carries it on its own evidence. A force-delete is
#               never used for it: the off-base reason authorizes nothing, it
#               only declines to pre-empt the other gates.
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
#               remotecopy gate is DISABLED (fail-closed, and said loudly).
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
# KEPT (never selected) unless noted, each reported with its reason:
#   * any branch checked out in the main checkout or ANY worktree
#     (`git worktree list --porcelain`)
#   * `main` itself
#   * a branch with an OPEN pull request
#   * a MERGED PR whose local tip has moved past the merged revision
#     (`merged-tip-moved`)
#   * a MERGED PR whose base is not `main` AND which no other gate carries
#     (`merged-base-not-main`) — an off-base MERGED PR may still be SELECTED as
#     `redundant` or `remotecopy`, since those gates prove deletion-safety from
#     main/upstream alone and the off-base reason is not a verdict against them.
#   * anything matching none of the three gates (`localonly`)
#
# Deletion mechanics (local): `git branch -d` first. It falls back — ONLY for
# the `merged` class — to `git update-ref -d refs/heads/<br> <classified-tip>`.
# A branch squash-merged at a tip that has NOT moved is not an ancestor of main,
# so `-d` legitimately refuses, and the atomic fallback is correct there and ONLY
# there. The other classes never use it: `-d` is required to succeed on the
# branch's own evidence, or the branch stays put and is reported as failed.
#
# ⛔ THE FALLBACK IS THE COMPARE-AND-SWAP ITSELF, exactly as the remote leg's
# delete is guarded by `--force-with-lease` (checked by the receiving
# repository): `git update-ref -d <ref> <old>` has GIT compare the ref's current
# value to <old> and remove it in the SAME operation, so it refuses unless the
# ref is still exactly the revision the `merged` gate proved. The `merged` gate
# proves the tip only at CLASSIFICATION time, so a read-then-delete would have a
# window: a commit landing between the read and the delete is invisible to the
# read and destroyed by the delete (the local leg's data-loss window — F12).
# `update-ref` closes that window because there is no second process to race.
#
# ⛔ THE PRE-CHECK (read the current tip, compare to the classified tip) IS NOT
# THE SAFETY MECHANISM. It is two separate git processes, so a tip that moves
# between them is missed; it exists to produce a good `moved` message. A refusal
# from `update-ref` (a moved tip, or a held ref lock) is reported as `moved`,
# counted, and makes the sweep exit non-zero — never as a delete. `-d` needs no
# guard: git itself refuses when the tip is not merged, so it cannot force-delete.
#
# ⛔ `update-ref -d` is NOT `git branch -D`, so the delete path does NOT inherit
# `-D`'s CHECKED-OUT refusal. It does NOT refuse a CHECKED-OUT branch (`-D`
# does; verified: `update-ref -d` removes the checked-out branch and leaves HEAD
# dangling), so the delete path re-enumerates the worktrees immediately before
# the swap and refuses on its own — the classification's `worktree:` keep rule is
# not relied on across the window. In every other respect the path now matches
# `-D`: it removes `logs/refs/heads/<br>` itself, and after a SUCCESSFUL swap it
# removes the `branch.<br>.*` config section too (F16), so a branch recreated
# with the same name does not inherit a stale upstream.
#
# ⛔ AN EMPTY `<old>` IS AN UNCONDITIONAL DELETE (F15). `git update-ref -d <ref>
# <old>` compares and refuses — but ONLY when <old> is non-empty: with an empty
# <old> git performs NO comparison and removes the ref unconditionally (verified
# on git 2.50.1: rc=0, ref gone). The compare-and-swap argument above therefore
# assumes a non-empty classified tip. `$sha` comes from the classification's
# `%(objectname)` field, and the pre-check that would otherwise reject an empty
# value is — by its own comment above — NOT the safety mechanism, so the guard
# lives WITH the swap and refuses the force-delete when `$sha` is empty.
#
# Deletion mechanics (remote): the classification reads
# refs/remotes/origin/<br>, but the destructive action targets origin's REAL
# refs/heads/<br>, so before each delete THREE things are proved, and the delete
# is REFUSED — loudly, and with a non-zero exit — on any failure:
#   1. the MERGE PREMISE against the DELETE TARGET's REAL main (`git ls-remote
#      <origin's resolved push url> refs/heads/<main>` + `git merge-base
#      --is-ancestor`). The classification used the LOCAL origin/<main>, which a
#      narrowed refspec can leave stale; if main was rewritten, a branch whose
#      commits are no longer in main must not be deleted. An unknown object (a
#      locally absent rewritten main) is a refusal, never a pass. ⛔ The proof
#      is read from the PUSH url, never the FETCH url: the delete lands on the
#      former, so a merge premise proved in the latter is proved against a
#      repository the delete never touches (F26). ⛔ F29: `git ls-remote` is
#      itself a FETCH, so it re-applies `url.<base>.insteadOf` ON TOP OF the
#      resolved push url while `git push origin` does not; the sweep therefore
#      REFUSES before classifying unless `git ls-remote --get-url` expands that
#      single push url to ITSELF — the proof endpoint must be provably the
#      delete endpoint, not merely intended to be.
#   2. the target ref: origin's real refs/heads/<br> equals the OID captured
#      from the tracking ref (`git ls-remote <origin's resolved push url>` vs
#      that OID). This is an early, loud DIAGNOSTIC — NOT the safety mechanism:
#      ls-remote is a FETCH, so it applies `url.<base>.insteadOf` to the
#      ALREADY-RESOLVED push url, while the push applies `pushInsteadOf` to
#      origin's fetch url and never then applies `insteadOf`. When the resolved
#      push url is itself an `insteadOf` base the two disagree and this
#      comparison proves repository C while the delete lands on repository B.
#      ⛔ F29: that divergence is now REFUSED before classification by the
#      endpoint guard below, so this check runs only once the two endpoints are
#      provably one URL; it remains as an early diagnostic for the residual
#      fetch→push race.
#   3. the delete LEASE: `git push origin --delete --force-with-lease=…:<oid>`
#      sends the classified OID as the expected old value through the SAME
#      resolution as the delete, so the receiving repository itself refuses
#      unless its ref is exactly what the sweep classified. This is what closes
#      the class; a lease rejection (`stale info`) is a REFUSAL.
# ALL of origin's push urls are resolved first (`git remote get-url --push
# --all`); zero is a refusal, and MORE THAN ONE is a refusal as well, because
# `git push origin` reaches every one of them and no single URL can pin the
# proof to the delete. The delete itself is `git push origin --delete`, never a
# push to the resolved URL: the resolution applies `pushInsteadOf`/`pushurl`
# ONCE, and pushing to its result would apply the rewrite a SECOND time, landing
# the delete on a repository the verification never proved. The remote sweep's
# classification IS its delete list, so freshness of the tracking ref is a
# safety property, not a nicety: a NEGATIVE refspec (`^…`, caught early by a
# config guard), a NARROWED POSITIVE refspec (`+refs/heads/main:refs/remotes/
# origin/main`, what `git remote set-branches` and `clone --single-branch` leave
# behind) and the plain fetch→push race can all make it stale while the fetch
# exits 0. The fetch itself is status-checked explicitly, because errexit is not
# a backstop here: the opt-in report log runs the pass under `set +e` (see the
# dispatch tail), AND under `--scope both` `run_remote_scope || rc=1` suppresses
# errexit for the WHOLE function body, log or no log (F37). The config guards are
# early, loud, and strictly additional; the three proofs above are what close the
# class.
#
# The exit status means "everything the sweep selected was reaped": a REFUSAL and
# any other non-zero push exit (a generic `Failed`) both make it non-zero, so a
# scheduler that reads only the status never mistakes a partial sweep for success.
#
# ── PR-state injection (the test seam) ────────────────────────────
# The branch→PR-state map is read ONCE, from the first source that resolves:
#   1. --pr-map-file <path>            a file holding the RAW `gh pr list --json
#                                      headRefName,state,headRefOid,baseRefName`
#                                      payload (a JSON array of objects)
#   2. CLEANUP_BRANCH_PR_MAP_JSON      the same payload inline (env)
#   3. `gh pr list --repo github.com/<owner/repo> --state all --limit N --json
#      headRefName,state,headRefOid,baseRefName`   (N = --pr-limit, default 10000)
#      --repo is passed EXPLICITLY, WITH the host pinned, so neither an exported
#      GH_REPO nor an ambient GH_HOST can redirect the map to another repository
#      or host (see load_pr_map).
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
# file, which is capped by recreating it before a pass once it exceeds
# CLEANUP_BRANCH_LOG_MAX_BYTES (default 1048576). The recreation is `mktemp` in
# the log's own directory + `mv` over the path (the pattern pi-reap-idle.sh uses
# for its log cap), NOT `: >"$f"`: the redirect FOLLOWS a symlink and truncates
# its TARGET, so a benign `ln -s` of the log into a shared log directory would
# have that target silently destroyed. Unset (the terminal default, and the
# suite's) means print only. (pi-reap-worktrees.sh, whose REAP_WT_LOG was cited
# here as precedent, never truncates its log at all; pi-reap-idle.sh is the
# sibling that does, and it does so symlink-safely.)
#
# ── why the lookup is not per-branch ──────────────────────────────
# The map is parsed once with a single `jq` pass into four TAB-delimited
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
DEFAULT_LOG_MAX_BYTES=1048576
CLEANUP_BRANCH_LOG_MAX_BYTES="${CLEANUP_BRANCH_LOG_MAX_BYTES:-$DEFAULT_LOG_MAX_BYTES}"

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
                     both — remote, then local; BOTH legs always run, and a
                        refusal or a failed delete in either one makes the exit
                        status non-zero (the status means "everything selected
                        was reaped").
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

# require_value <flag> <remaining-arg-count> — a two-token flag with its value
# missing must fail LOUDLY. `shift 2` on a single remaining argument returns
# non-zero, and under `set -e` the shell exits BEFORE any usage text: the
# operator sees only "shift: shift count out of range", never which flag was
# malformed or that a value was owed.
require_value() {
    if [ "$2" -lt 2 ]; then
        echo "ERROR: $1 requires a value, but none was given" >&2
        exit 1
    fi
}

# quote_argv <arg>... — render an argv as ONE shell line that a human can paste
# and have the shell re-parse to EXACTLY that argv. The dry-run plan is printed
# for copy-paste, so the printed text is a SHELL line, not a mere display: a ref
# name may legally contain `"`, `$()`, a backtick or `|` (`git check-ref-format`
# permits them), and a hand-built `--force-with-lease="...$branch..."` echo lets
# those run as commands when pasted. `%q` is bash's own re-input-safe quoting, so
# the round-trip is the shell's property, not a hand-kept escaping table. The
# printer and the execute path consume the SAME array for every line the plan
# prints AS A COMMAND, so those cannot diverge. The LOCAL plan’s force-delete
# fallback is deliberately NOT one of them: it is printed as a COMMENT (F17),
# because printing it as a second command made the plan advertise two commands
# where execution runs one, and a verbatim paste under `set -e` aborted on the
# first (see the plan block below).
quote_argv() {
    local _qa_sep="" _qa_arg _qa_q
    for _qa_arg in "$@"; do
        printf -v _qa_q '%q' "$_qa_arg"
        printf '%s%s' "$_qa_sep" "$_qa_q"
        _qa_sep=" "
    done
    printf '\n'
}

# ── Parse args ────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --cutoff)
            require_value "$1" "$#"
            CUTOFF_DAYS="$2"
            shift 2
            ;;
        --scope)
            require_value "$1" "$#"
            SCOPE="$2"
            shift 2
            ;;
        --pr-map-file)
            require_value "$1" "$#"
            PR_MAP_FILE="$2"
            # Absolutize AT PARSE TIME, BEFORE the `cd "$REPO_ROOT"` below: args
            # are parsed before the cd but the file is read after it, so a
            # relative path would be resolved against the SWEPT checkout instead
            # of the caller's cwd and the supplied map would silently "not exist".
            case "$PR_MAP_FILE" in
                ""|/*) ;;
                *) PR_MAP_FILE="$(pwd)/$PR_MAP_FILE" ;;
            esac
            shift 2
            ;;
        --pr-limit)
            require_value "$1" "$#"
            PR_LIMIT="$2"
            shift 2
            ;;
        --repo)
            require_value "$1" "$#"
            REPO_ROOT="$2"
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

# ⛔ A value that matches ^[0-9]+$ can still OVERFLOW bash's integer range:
# `[ 99999999999999999999 -lt 1 ]` returns status 2 ("integer expression
# expected"), the `if` reads FALSE, and a validation meant to refuse the value
# silently passes it. Every later comparison errors the same way, so e.g. the log
# cap NEVER fires — the exact silent no-op the validation exists to close. Bound
# the DIGIT count too, and put that test BEFORE any arithmetic: 15 digits
# (< 2^53) is far above any legitimate cutoff, limit or cap, and short-circuits
# before the overflow can be reached.

# Validate cutoff is a positive integer
if ! [[ "$CUTOFF_DAYS" =~ ^[0-9]+$ ]] || [ "${#CUTOFF_DAYS}" -gt 15 ] || [ "$CUTOFF_DAYS" -lt 1 ]; then
    echo "ERROR: --cutoff must be a positive integer, got '$CUTOFF_DAYS'" >&2
    exit 1
fi

# Validate the PR-map limit is a positive integer
if ! [[ "$PR_LIMIT" =~ ^[0-9]+$ ]] || [ "${#PR_LIMIT}" -gt 15 ] || [ "$PR_LIMIT" -lt 1 ]; then
    echo "ERROR: --pr-limit must be a positive integer, got '$PR_LIMIT'" >&2
    exit 1
fi

# Validate the report-log cap is a positive integer. A non-numeric value makes
# `[ "$size" -ge "$max" ]` return status 2, the `if` read false, and the cap
# silently NEVER fire — no error, no warning — defeating the header's "cannot
# grow without bound" claim. Warn and fall back to the default instead.
if ! [[ "$CLEANUP_BRANCH_LOG_MAX_BYTES" =~ ^[0-9]+$ ]] || [ "${#CLEANUP_BRANCH_LOG_MAX_BYTES}" -gt 15 ] || [ "$CLEANUP_BRANCH_LOG_MAX_BYTES" -lt 1 ]; then
    echo "WARNING: CLEANUP_BRANCH_LOG_MAX_BYTES must be a positive integer, got '$CLEANUP_BRANCH_LOG_MAX_BYTES' — falling back to $DEFAULT_LOG_MAX_BYTES" >&2
    CLEANUP_BRANCH_LOG_MAX_BYTES="$DEFAULT_LOG_MAX_BYTES"
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

# cutoff_epoch — the cutoff as epoch seconds, or the EMPTY STRING when this
# host's `date` cannot express it.
#
# ⛔ F31: `date -v-<N>d +%s` fails on macOS for 6-11 digit N ("Cannot apply date
# adjustment") and that host has NO GNU `date -d` fallback, so BOTH arms fail and
# the function prints nothing. `2>/dev/null` on BOTH arms keeps BSD date's usage
# text out of the report; `|| true` makes the function's STATUS 0 so a failing
# `date` is ruled on by the validator below, never by `set -e`: errexit exits
# before any diagnostic, and it does NOT fire at all under CLEANUP_BRANCH_LOG's
# `set +e` (the shipped launchd configuration) NOR in `--scope both`, where
# `run_remote_scope || rc=1` suppresses it for the whole function body (F37). The
# explicit validator is therefore the ONLY thing ruling on this value, in every
# mode.
cutoff_epoch() {
    # ONE portable spelling (#2048): the shim resolves `-N days ago` on both platforms and returns
    # EMPTY + non-zero when it cannot, which is exactly what the validator below rules on.
    _date --parse "${CUTOFF_DAYS} days ago" 2>/dev/null || true
}

# validate_cutoff_epoch <value> — return 0 (printing nothing) for a cutoff epoch
# this sweep can compare every commit date with, and return 1 with a diagnostic
# NAMING --cutoff for an EMPTY, NON-NUMERIC or OVER-15-DIGIT value.
#
# ⛔ F31: THE CUTOFF EPOCH WAS THE ONE SAFETY INPUT WITH NO EXPLICIT STATUS
# CHECK. Every other safety input is guarded (the `git fetch` call site states
# the rule; validate_commit_date applies it to the commit dates), but the cutoff
# epoch was consumed UNGUARDED by BOTH scopes. In `--scope remote` without
# CLEANUP_BRANCH_LOG, the failing `date` tripped `set -e` (loud, but with a raw BSD
# `date` usage message that never mentions the flag). Under CLEANUP_BRANCH_LOG,
# AND in `--scope both` (where `run_remote_scope || rc=1` suppresses errexit for
# the whole function body — F37), the pass runs without `set -e`: `CUTOFF_EPOCH`
# stayed EMPTY, and every integer comparison returned status 2, which `if`/`||`
# reads as FALSE. That INVERTS the staleness predicate on BOTH legs: the remote
# scope dropped its candidate list behind `✅ No stale merged branches found`
# (exit 0 — a false PASS a scheduler cannot see) while the local scope treated a
# FRESH branch as STALE and DELETED it (exit 0). One guard, called by BOTH
# scopes, is what keeps the two from diverging. The accepted `--cutoff` RANGE is
# unchanged: this rules on whether the cutoff is COMPUTABLE, not on which N is
# allowed.
validate_cutoff_epoch() {
    local value="${1:-}"
    case "$value" in
        ''|*[!0-9]*)
            echo "ERROR: could not compute the epoch for --cutoff $CUTOFF_DAYS days (got '${value:-<empty>}')," >&2
            echo "ERROR: so no commit date can be compared with the cutoff. An uncomputable cutoff is an" >&2
            echo "ERROR: internal error, not a staleness verdict: unchecked it empties the remote candidate" >&2
            echo "ERROR: list behind a success status and reads a FRESH branch as stale on the local one." >&2
            echo "ERROR: Refusing the sweep." >&2
            return 1
            ;;
    esac
    # Same normalised-value bound as validate_commit_date (F25/F27): strip the
    # leading zeros so the 15-digit policy bound tests the VALUE, not its
    # spelling.
    value="${value#"${value%%[!0]*}"}"
    [ -n "$value" ] || value=0
    if [ "${#value}" -gt 15 ]; then
        echo "ERROR: --cutoff $CUTOFF_DAYS days resolves to an epoch with more than 15 digits ('$value')," >&2
        echo "ERROR: outside this sweep's 15-digit policy bound. Refusing the sweep rather than letting" >&2
        echo "ERROR: an out-of-policy cutoff invert the staleness comparison." >&2
        return 1
    fi
    return 0
}

# ── Shared: the PR-state seam ─────────────────────────────────────
# github_slug <url> — owner/repo for a github.com origin, else empty.
# ⛔ The HOST is parsed EXPLICITLY and compared for EXACT equality. A substring
# test (`*github.com[:/]*`) accepts `https://notgithub.com/owner/repo.git` and
# `git@mygithub.com:owner/repo.git`, stripping the embedded `github.com/` and
# yielding a FOREIGN but syntactically valid `owner/repo`. `gh` reads a 2-segment
# value as `github.com/<owner>/<repo>`, so a foreign repository's map silently
# displaces this one's and the OPEN-PR keep rule protects the wrong branches. Any
# host that is not exactly `github.com` returns EMPTY, which the caller treats as
# "cannot read PR state" and fails closed on.
github_slug() {
    local url="${1:-}" rest="" host="" path=""
    [ -n "$url" ] || return 0
    case "$url" in
        # scheme://[user@]host[:port]/path — https, http, ssh, git, ...
        *://*)
            rest="${url#*://}"
            rest="${rest#*@}"
            host="${rest%%/*}"
            path="${rest#*/}"
            ;;
        # scp-like: [user@]host:path
        *@*:*)
            rest="${url#*@}"
            host="${rest%%:*}"
            path="${rest#*:}"
            ;;
        # scp-like with NO user: host:path. git hands this form to ssh, so
        # `github.com:owner/repo.git` is a GENUINE github.com origin. Without
        # this arm the URL fell through to the bare-path branch below, where
        # `${url%%/*}` split on the FIRST `/` INSIDE the path — yielding
        # host=`github.com:owner` (a host that is not `github.com`) and a
        # single-segment path, so a legitimate origin was REFUSED and the whole
        # PR-state seam (and hence the local scope) stood down.
        *:*)
            host="${url%%:*}"
            path="${url#*:}"
            ;;
        # bare host/owner/repo, or a filesystem path (no scheme, no user@host:)
        */*)
            host="${url%%/*}"
            path="${url#*/}"
            ;;
        *) printf ''; return 0 ;;
    esac
    # the host may carry a port; the path a leading slash, a trailing slash, .git
    host="${host%%:*}"
    # ⛔ The host comparison below is EXACT, so it must be CASE-NORMALISED first:
    # git accepts `https://GitHub.com/owner/repo.git` (URL host names are
    # case-insensitive), but `[ "$host" != "github.com" ]` would refuse that
    # valid origin — a false negative that fails closed and disables the whole
    # PR-state seam for a legitimate remote. Bash 3.2-safe (no `${var,,}`).
    # ⛔ `LC_ALL=C` PINS the fold. `tr '[:upper:]' '[:lower:]'` is LOCALE-DEPENDENT:
    # under a Turkish locale it folds `İ` (U+0130) to `i`, so the foreign host
    # `GİTHUB.COM` became exactly `github.com` and PASSED the exact-host guard
    # below — a foreign repository's PR map silently displacing this one's, which
    # is the very defect the exact comparison exists to stop. C makes the fold
    # ASCII-only, and ASCII case-insensitivity is all a host name needs.
    host="$(printf '%s' "$host" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
    path="${path#/}"
    path="${path%/}"
    path="${path%.git}"
    if [ "$host" != "github.com" ] || [ -z "$path" ]; then
        printf ''
        return 0
    fi
    # ⛔ EXACTLY two non-empty path segments. A 1-segment path
    # (`https://github.com/onlyowner`) previously yielded the slug `onlyowner`,
    # so the pinned `--repo github.com/$slug` was the 2-segment
    # `github.com/onlyowner`, which `gh` resolves as OWNER/REPO against the
    # ambient `$GH_HOST` — the host pin did not hold for an input the parser
    # accepted. Requiring owner AND repo makes `github.com/$slug` always 3
    # segments, which `gh` reads as host/owner/repo. More than two segments (a
    # deep URL such as `.../owner/repo/tree/main`) is refused for the same reason.
    case "$path" in
        */*) ;;
        *) printf ''; return 0 ;;
    esac
    local owner="${path%%/*}" repo_part="${path#*/}"
    if [ -z "$owner" ] || [ -z "$repo_part" ] || [ "${repo_part#*/}" != "$repo_part" ]; then
        printf ''
        return 0
    fi
    printf '%s\n' "$path"
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
        #
        # ⛔ --repo is passed EXPLICITLY to BOTH invocations, and WITH the host
        # pinned (`github.com/$slug`), never as a bare `owner/repo`. `gh` reads a
        # 2-segment --repo as resolved against $GH_HOST, so an ambient GH_HOST
        # would redirect the whole map to another host — the same class as the
        # GH_REPO defect below. `gh` parses the 3-segment form as host/owner/repo.
        # Without any --repo at all, `gh pr list` honours an exported GH_REPO, so
        # the whole PR map would be fetched for a DIFFERENT repository: the
        # OPEN-PR keep rule would silently protect that repository's branches and
        # this one's OPEN PRs would vanish from the map (in the merged path the
        # force-delete fallback could then remove local-only commits).
        local errf="" gh_rc=0
        errf="$(mktemp "${TMPDIR:-/tmp}/cleanup-branch-gh.XXXXXX" 2>/dev/null)" || errf=""
        if [ -n "$errf" ]; then
            src="$(gh pr list --repo "github.com/$slug" --state all --limit "$PR_LIMIT" \
                    --json headRefName,state,headRefOid,baseRefName 2>"$errf")" || gh_rc=$?
        else
            src="$(gh pr list --repo "github.com/$slug" --state all --limit "$PR_LIMIT" \
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
    #
    # ⛔ The test is a `case` GLOB, never `[ -z "${src//[[:space:]]/}" ]`. On
    # macOS's /bin/bash 3.2.57 the pattern substitution is SUPERLINEAR in the
    # input: a real `gh pr list` payload (~88 KB) does not return in >30 s, so
    # the whole LOCAL scope stops here — it neither classifies nor fails closed.
    # The glob answers the same question in O(n) and matches exactly the same
    # set (POSIX `[:space:]`: space, tab, newline, CR, FF, VT). A NUL cannot
    # reach here (command substitution strips it), so "empty or whitespace-only"
    # is complete.
    case "$src" in
        *[![:space:]]*) ;;
        *)
            echo "PR map is EMPTY — refusing: an empty map is not an empty PR rule" >&2
            return 1
            ;;
    esac

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

# ── Shared: commit-date validation (F18/F22/F24/F25) ──────────────
# validate_commit_date <ref> <value> — return 0 (printing nothing) for a value
# this sweep can compare with $CUTOFF_EPOCH, and return 1 with a diagnostic on
# stderr NAMING <ref> for an EMPTY, NON-NUMERIC or OVER-15-DIGIT value.
#
# ⛔ ONE implementation, called by BOTH the remote and the local scope. The two
# scopes each grew their own copy of this check and then DRIFTED: the remote
# guard refused an empty/non-numeric value but passed an over-long all-digit one
# (`''|*[!0-9]*` does not match `9223372036854775808`), while the local guard
# bound the digit count and refused it. A failed numeric comparison returns
# status 2, the `if` reads FALSE, and the candidate is then dropped or
# misclassified with no diagnostic — on the remote scope behind
# `✅ No stale merged branches found`, exit 0 (a FALSE PASS a scheduler cannot
# see). F18, F22 and F24 are the same defect at the two call sites; the single
# helper is what keeps them from diverging a third time.
#
# ⛔ THE BOUND IS ON THE NORMALISED NUMERIC VALUE, NEVER ON THE RAW STRING (F25).
# `git log --format='%ct'` prints a timestamp VERBATIM, so a commit object can
# carry `0000000009` or `0000000000000009` — the SAME numeric value (9) spelled
# with a different digit count. Bounding the raw string split that one root into
# two OPPOSITE failures:
#   * `0000000009` (10 raw characters) PASSED the bound, and then
#     `date -r 0000000009` FAILED on macOS — it parses that argument as a DATE,
#     not as seconds, and macOS has no `date -d` fallback. In `--scope remote`
#     without CLEANUP_BRANCH_LOG that aborted the whole sweep under `set -e`, with
#     a raw `date` usage message, rc=1, NO plan and NO delete. Under
#     CLEANUP_BRANCH_LOG, AND in `--scope both` (where `run_remote_scope || rc=1`
#     suppresses errexit for the whole function body — F37), the pass runs without
#     `set -e`, so the same value instead printed the branch with an EMPTY date.
#   * `0000000000000009` (16 raw characters, numeric value 9) was FALSELY refused
#     by a RAW-LENGTH bound, and the refusal misnamed its own rule as "outside
#     bash's integer range". That reason is FALSE on bash 3.2.57: `[
#     0000000000000009 -lt 100 ]` is 0, and so is `[ 1000000000000000 -lt
#     1700000000 ]` — no error, numerically fine; only a value past 2^63 (e.g.
#     9223372036854775808) makes the comparison return status 2. The bound is a
#     deliberate 15-DIGIT POLICY, and the diagnostic says so (F27).
# Leading zeros are therefore stripped BEFORE the bound is tested. 15 DIGITS is
# the file's own bound — the same one `--cutoff`, `--pr-limit` and
# CLEANUP_BRANCH_LOG_MAX_BYTES are validated with — and it is now tested on the
# value every later arithmetic and `date` call actually sees. A genuine all-digit
# date with ANY number of leading zeros (including epoch 0, which IS stale) is
# ACCEPTED and evaluated normally by the caller — this helper rules on
# READABILITY, never on staleness. It REFUSES exactly an EMPTY, a NON-NUMERIC, or
# a genuinely OVER-15-DIGIT numeric value.
validate_commit_date() {
    local ref="$1" value="${2:-}"
    case "$value" in
        ''|*[!0-9]*)
            echo "ERROR: could not read the commit date of $ref, so it cannot be shown to be" >&2
            echo "ERROR: stale. An unreadable date is an internal error, not a staleness verdict;" >&2
            echo "ERROR: refusing the sweep so an unproven branch is never treated as a candidate." >&2
            return 1
            ;;
    esac
    # ⛔ F25: strip the leading zeros so the bound tests the VALUE, not its
    # spelling. `%%[!0]*` removes the longest suffix whose FIRST character is a
    # non-zero digit — that suffix starts at the first non-zero digit — so the
    # prefix it leaves behind is EXACTLY the leading zeros. An all-zero value has
    # no such suffix, so it normalises to the empty string and is mapped to `0`.
    # The expansion is quoted, so the pattern is never globbed against the
    # filesystem, and it cannot fail under `set -e`/`set -u` on bash 3.2.57
    # (the non-numeric case above already guaranteed a non-empty all-digit value).
    value="${value#"${value%%[!0]*}"}"
    [ -n "$value" ] || value=0
    if [ "${#value}" -gt 15 ]; then
        echo "ERROR: the commit date of $ref ($value) has more than 15 digits, so it is" >&2
        echo "ERROR: outside this sweep's 15-digit policy bound and is not compared with the" >&2
        echo "ERROR: cutoff. Refusing the sweep rather than letting an out-of-policy value read" >&2
        echo "ERROR: as a verdict — a false 'not stale' on the remote scope and a false 'stale'" >&2
        echo "ERROR: on the local one." >&2
        return 1
    fi
    return 0
}

# ── delete-time target verification (R3-1) ────────────────────────
# verify_remote_target <push_url> <local_branch> <classified_oid>
#
# Returns 0 (printing nothing) only when origin's REAL push target serves a ref
# named EXACTLY refs/heads/<br> at exactly the OID this sweep classified from
# refs/remotes/origin/<br>. On anything else it prints a one-line reason and
# returns 1 — the caller REFUSES that delete.
#
# ⛔ The target is the PUSH url, not the fetch url. `git ls-remote origin` reads
# remote.origin.url, but `git push origin` honours remote.origin.pushurl AND
# `url.<base>.pushInsteadOf` — so when they diverge a fetch-side verification
# proves repository A while the delete lands on repository B and reports success.
# The caller resolves origin's push urls ONCE with
# `git remote get-url --push --all origin`, refuses unless there is EXACTLY one,
# and passes that single URL here. The delete then goes through git's own remote
# resolution (`git push origin --delete`) so the rewrite is applied the SAME
# number of times — once — as it was to produce this URL.
#
# Why this is not redundant with the `^` refspec guard: that guard greps the
# CONFIG for a negative refspec, which is only ONE way refs/remotes/origin/<br>
# goes stale. A NARROWED positive refspec (what `git remote set-branches` and
# `clone --single-branch` leave behind: `+refs/heads/main:refs/remotes/origin/main`)
# omits `refs/heads/*`, so the fetch exits 0 and the guard finds nothing, yet the
# tracking ref is never refreshed and never pruned. Comparing against origin's
# real ref is what actually closes the class — including the fetch→push race,
# which no config inspection can see.
verify_remote_target() {
    local push_url="$1" local_branch="$2" tracking_oid="$3" ls_out="" real_oid="" n=""
    if ! ls_out="$(git ls-remote "$push_url" "refs/heads/$local_branch" 2>/dev/null)"; then
        printf '%s' "git ls-remote $push_url refs/heads/$local_branch FAILED, so origin's real ref cannot be verified"
        return 1
    fi
    if [ -z "$ls_out" ]; then
        printf '%s' "origin has NO refs/heads/$local_branch — the classified refs/remotes/origin/$local_branch is stale"
        return 1
    fi
    # ⛔ `ls-remote <pattern>` matches path-component SUFFIXES, NOT the exact
    # ref: with only refs/heads/refs/heads/foo present, `ls-remote refs/heads/foo`
    # RETURNS it. Counting lines and taking the first OID is therefore not a name
    # check — it can pass for the wrong ref, and it FALSELY REFUSES a legitimate
    # branch whenever a same-suffix ref exists alongside it. Select the line whose
    # post-TAB ref name is EXACTLY refs/heads/<br>; refuse on zero (no exact ref,
    # however many suffix matches there were) or more than one (impossible for a
    # single remote, but a guess here is exactly what this guard exists to stop).
    n=0
    local line
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        [ "${line#*$'\t'}" = "refs/heads/$local_branch" ] || continue
        n=$((n + 1))
        real_oid="${line%%$'\t'*}"
    done <<<"$ls_out"
    if [ "$n" != "1" ]; then
        printf '%s' "git ls-remote $push_url matched $n ref(s) named exactly refs/heads/$local_branch — refusing to guess which one was classified"
        return 1
    fi
    if [ "$real_oid" != "$tracking_oid" ]; then
        printf '%s' "origin's real refs/heads/$local_branch is $real_oid but this sweep classified $tracking_oid from refs/remotes/origin/$local_branch"
        return 1
    fi
    return 0
}

# ── merge-premise re-proof against the DELETE TARGET's REAL main (F2/F26) ──
# verify_merged_into_real_main <real_main_oid> <resolve_reason> <classified_oid>
#
# Returns 0 (printing nothing) only when the DELETE TARGET's REAL main line
# provably contains the tip this sweep classified. On anything else it prints a
# one-line reason and returns 1 — the caller REFUSES that delete. The oid is read
# by read_remote_main_oid and passed in; HOW OFTEN the caller reads it is the
# caller's decision, and BOTH callers now read it ONCE PER ENTRY — the plan (F36)
# and the execute leg (F34). No caller may snapshot it for the sweep.
#
# ⛔ The classification is `git branch -r --merged origin/main`, which reads the
# LOCAL remote-tracking ref. That ref is only as fresh as the fetch refspec lets
# it be: a NARROWED POSITIVE refspec (what `git remote set-branches` and
# `clone --single-branch` leave behind) may omit `refs/heads/main` entirely, so
# `git fetch origin --prune` exits 0 and leaves `origin/main` at an OLD value.
# If main has since been REWRITTEN, a branch whose commits are no longer in real
# main is still classified `--merged` and destroyed. `verify_remote_target` does
# NOT close this: it proves the branch's real ref equals the TRACKED oid, never
# that the oid is in main. Re-reading main STRAIGHT FROM THE DELETE TARGET
# (ls-remote ignores the fetch refspec) and requiring the classified tip to be
# an ancestor of it does.
#
# ⛔ THE MERGE PREMISE IS READ FROM THE PUSH URL, NOT THE FETCH URL (F26). The
# `refs/remotes/origin/*` the classification used are built from
# remote.origin.url — the FETCH url — but the delete lands wherever
# `git push origin` resolves, which honours remote.origin.pushurl and
# `url.<base>.pushInsteadOf`. With pushurl pointing at repository B, proving the
# merge against A's main proves the premise in a repository the delete never
# touches: B can serve the same branch at the same OID (the ordinary mirror
# shape) while B's main does NOT contain it, so every gate passes and the delete
# removes a branch that is not merged in the repository it lands on. Re-reading
# main from the resolved PUSH url follows the delete: when the two URLs are the
# same repository this is behaviourally identical, and when they differ the
# proof must follow the delete, never the fetch.
#
# ⛔ An UNKNOWN object is a REFUSAL, never a pass: when main was rewritten, its
# new commit may not exist locally, and `git merge-base --is-ancestor` then
# fails. Failure — of any kind — is a refusal.
#
# This reads the DELETE TARGET's refs. The target is pinned separately — by
# verify_remote_target and by the delete's force-with-lease — and the caller
# resolves the single push url first (zero or >1 is a refusal). It ALSO refuses
# the whole sweep before this function runs unless `git ls-remote --get-url`
# expands that single push url to ITSELF (F29), so a `url.<base>.insteadOf`
# rewrite cannot make this FETCH-side proof read a repository other than the one
# `git push origin` deletes from. What this function guarantees is therefore
# that the merge premise holds in the repository the caller has already PROVED
# is the delete endpoint — not merely in the one it intended.
#
# ⛔ F34/F36: NO LEG SNAPSHOTS THE REAL MAIN — THE PLAN AND THE EXECUTE LEG BOTH
# RE-READ IT ONCE PER ENTRY, IMMEDIATELY BEFORE THEY EVALUATE THAT ENTRY. (The
# plan and the execute loop both call the per-entry CHECK; each call used to run
# its own `git ls-remote <push_url> refs/heads/<main>`, which is N identical
# network round trips.) main is NOT constant across a sweep: a force-push to it
# between candidate N and N+1 invalidates the premise for every LATER candidate,
# so a once-per-sweep snapshot keeps validating them against a main that no
# longer contains their tips — deleting precisely the unmerged branches this gate
# exists to protect. That is F34 (execute) and F36 (the plan).
#
# ⛔ F36: THE PLAN IS NOT EXEMPT, AND THE "EXECUTE RE-GATES A PASTED LINE"
# JUSTIFICATION WAS FALSE. The plan's output is a RAW, PASTE-SAFE
# `git push origin --delete --force-with-lease=…` — `quote_argv` exists precisely
# so the printed line re-parses to the executed argv. NOTHING re-gates a PASTED
# line except re-running `--execute`: the lease pins the BRANCH OID and cannot
# check the MERGE PREMISE. A snapshot therefore made the plan print an EXECUTABLE
# delete for an entry the plan itself would have REFUSED had it read main like
# execute does, and pasting that line destroyed the branch's unique commits. The
# plan must evaluate the SAME premise at the SAME time as execute; a call count is
# not a safety argument. (This is the second time the once-per-sweep optimisation
# has been reversed — it was reverted on execute as F34 and is now reverted here.)
# If a snapshot were ever kept, the plan could not print executable commands at
# all; the per-entry read is what lets it print them honestly.
#
# Measured with a `git` shim over 6 candidates: BOTH legs cost 2N+1 = 13
# `ls-remote` calls (1 endpoint proof + N real-main reads + N target checks). The
# plan and execute counts are IDENTICAL — that equality is the parity property
# this gate wants, and the freshness is the whole point.
#
# ⛔ The read is split from the check because the callers CAPTURE the check's
# refusal reason through `$(...)`, i.e. in a SUBSHELL: a memo written inside the
# check is discarded the moment the subshell exits, so "memoise inside the
# function" is not available here. Splitting the read from the check and PASSING
# the oid in keeps ONE implementation of the check (forked implementations are
# this branch's recurring defect) and keeps every refusal message in one place.
# The re-read that is GENUINELY per-entry (`verify_remote_target`) is untouched,
# as is the delete's force-with-lease, which is the real compare-and-swap.
#
# read_remote_main_oid <push_url> — resolve the DELETE TARGET's REAL
# refs/heads/<main>. BOTH callers invoke it ONCE PER ENTRY — the plan here (F36)
# and the execute leg immediately before its delete (F34). Prints the oid and
# returns 0, or prints the one-line reason and returns 1.
read_remote_main_oid() {
    local push_url="$1" ls_out="" real_main_oid="" n=0 line=""
    if ! ls_out="$(git ls-remote "$push_url" "refs/heads/$MAIN_BRANCH" 2>/dev/null)"; then
        printf '%s' "git ls-remote $push_url refs/heads/$MAIN_BRANCH FAILED, so the DELETE TARGET's REAL $MAIN_BRANCH cannot be resolved"
        return 1
    fi
    # Same exact-name discipline as verify_remote_target: `ls-remote <pattern>`
    # matches path-component SUFFIXES, so a count-and-take-first would accept a
    # differently named ref. Require exactly one line whose ref name is EXACTLY
    # refs/heads/main.
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        [ "${line#*$'\t'}" = "refs/heads/$MAIN_BRANCH" ] || continue
        n=$((n + 1))
        real_main_oid="${line%%$'\t'*}"
    done <<<"$ls_out"
    if [ "$n" != "1" ]; then
        printf '%s' "git ls-remote $push_url matched $n ref(s) named exactly refs/heads/$MAIN_BRANCH — the DELETE TARGET's real $MAIN_BRANCH is not provable"
        return 1
    fi
    printf '%s' "$real_main_oid"
    return 0
}

# verify_merged_into_real_main <real_main_oid> <resolve_reason> <classified_oid>
# — the per-entry CHECK against the main oid the CALLER read. <real_main_oid> is
# what read_remote_main_oid printed; when that read FAILED it is EMPTY and
# <resolve_reason> carries the reason, which is printed verbatim so the refusal
# is the SAME one a per-entry read would have produced.
verify_merged_into_real_main() {
    local real_main_oid="$1" resolve_reason="$2" tracking_oid="$3"
    if [ -z "$real_main_oid" ]; then
        printf '%s' "$resolve_reason"
        return 1
    fi
    if ! git merge-base --is-ancestor "$tracking_oid" "$real_main_oid" >/dev/null 2>&1; then
        printf '%s' "the DELETE TARGET's REAL refs/heads/$MAIN_BRANCH is $real_main_oid, which does NOT provably contain the classified tip $tracking_oid"
        return 1
    fi
    return 0
}

# ── remote scope (unchanged behaviour, #74) ───────────────────────
run_remote_scope() {
    # ── Sanity check: on main, up to date ─────────────────────────
    local CURRENT_BRANCH
    # ⛔ F18: `--no-color` on every `git branch` READ. `branch` is the one git
    # subcommand here that colourises a ref name it prints, and a colourised name
    # poisons every downstream parse (see the classification call site for the
    # full audit and the false PASS it produced).
    CURRENT_BRANCH="$(git branch --no-color --show-current)"
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
    # ⛔ THIS STATUS IS CHECKED EXPLICITLY, never via errexit. errexit is NOT a
    # backstop for this read: the opt-in report log runs the whole pass inside
    # `set +e` (see the dispatch tail: it must read PIPESTATUS through the tee),
    # AND under `--scope both` `run_remote_scope || rc=1` suppresses errexit for
    # the ENTIRE function body, log or no log (F37). Without the explicit check a
    # bare `git fetch` that FAILS falls through: the stale tracking refs are
    # classified, and `git push origin --delete` then destroys the real branch.
    # `CLEANUP_BRANCH_LOG` is set by
    # templates/launchd/com.tortoise.branch-reaper.plist, i.e. by the normal
    # operator invocation, so this is the DEFAULT path, not an edge case.
    if ! git fetch origin --prune --quiet; then
        echo "ERROR: git fetch origin --prune --quiet FAILED — remote-tracking refs may be STALE." >&2
        echo "ERROR: refs/remotes/origin/<br> can hold an OLD merged tip while origin's real" >&2
        echo "ERROR: refs/heads/<br> has advanced to an UNMERGED commit, so deleting on that" >&2
        echo "ERROR: stale tip would destroy commits that exist nowhere else." >&2
        echo "ERROR: Refusing the remote sweep because the fetch failed. Re-run once origin is" >&2
        echo "ERROR: reachable (or point origin at a reachable URL) — this pass will not delete" >&2
        echo "ERROR: anything on refs it could not refresh." >&2
        return 1
    fi

    # ⛔ Even a fetch that EXITS 0 does not prove the refs were refreshed. A
    # NEGATIVE refspec in remote.origin.fetch (an entry beginning with `^`) makes
    # the fetch succeed while `--prune` SKIPS the excluded ref: refs/remotes/
    # origin/<br> keeps an OLD merged tip while origin's real refs/heads/<br> has
    # advanced to an UNMERGED commit. `git branch -r --merged origin/main` then
    # classifies the STALE tip, and `git push origin --delete` destroys commits
    # that exist nowhere else. Unlike the local scope (which only stands its
    # remotecopy gate down), here the classification IS the delete list, so the
    # sweep is REFUSED. The refspec belongs to the OPERATOR — this pass will not
    # rewrite it. A here-string, not `printf ... | grep -q` (#841).
    # ⛔ The `^` guard alone covers ONE staleness mechanism: a NARROWED POSITIVE
    # refspec (`+refs/heads/main:refs/remotes/origin/main`, what
    # `git remote set-branches` / `clone --single-branch` leaves behind) omits
    # `refs/heads/*`, so the fetch exits 0 and the grep finds nothing while
    # refs/remotes/origin/<br> is never refreshed and never pruned. The
    # DELETE-TIME VERIFICATION in the execute loop closes the whole class (and the
    # fetch→push race) independently of the config.
    local remote_scope_refspecs=""
    remote_scope_refspecs="$(git config --get-all remote.origin.fetch 2>/dev/null || true)"
    if grep -q '^\^' <<<"$remote_scope_refspecs"; then
        echo "ERROR: remote.origin.fetch carries a NEGATIVE refspec (an entry beginning with '^')." >&2
        echo "ERROR: 'git fetch origin --prune' exits 0 but SKIPS the excluded ref, so" >&2
        echo "ERROR: refs/remotes/origin/<br> can hold an OLD merged tip while origin's real" >&2
        echo "ERROR: refs/heads/<br> has advanced to an UNMERGED commit. Deleting on that" >&2
        echo "ERROR: stale tip would destroy commits that exist nowhere else." >&2
        echo "ERROR: Refusing the remote sweep. Remove the negative refspec and re-run;" >&2
        echo "ERROR: this pass will not rewrite remote.origin.fetch." >&2
        return 1
    fi

    # ⛔ RESOLVE EVERY PUSH TARGET, and refuse unless there is EXACTLY ONE.
    # `git ls-remote origin` reads the FETCH url (remote.origin.url), but
    # `git push origin` honours remote.origin.pushurl (ALL of them) AND
    # `url.<base>.pushInsteadOf`, which can point at a DIFFERENT repository. When
    # they diverge, a fetch-side verification proves repository A while the
    # destructive delete lands on repository B -- and the sweep reports success.
    # `git remote get-url --push --all origin` is git's own resolution and
    # applies BOTH rewrite channels, so it is the only URL the verification may
    # use.
    #
    # ⛔ MULTIPLE PUSH URLS ARE A REFUSAL. `--all` names every one, and
    # `git push origin` reaches ALL of them (it is one push per pushurl). No
    # single URL covers the set, so a verification against the first tells us
    # nothing about the others: with two mirrors both holding the branch, the
    # sweep would prove M1, delete M1, report `Deleted: 1`, and leave M2's copy
    # in place -- and if M2's copy were the unmerged one, an unverified delete.
    # There is no single target the proof and the delete can both be pinned to,
    # so the sweep stands down and names each URL.
    #
    # ⛔ THE DELETE IS `git push origin --delete`, NEVER a push to the resolved
    # URL. `git remote get-url --push origin` applies the rewrite ONCE; a delete
    # that pushed to that RESOLVED url would apply it a SECOND time, so a CHAINED
    # rewrite (`url.B.pushInsteadOf=A` + `url.C.pushInsteadOf=B`) proves repo B
    # while the delete lands on repo C -- an unverified repository whose unique
    # UNMERGED branch is destroyed, reported as success. `git push origin`
    # resolves the remote and applies the rewrite exactly once, which is the same
    # single application that produced the verified URL. An empty resolution is a
    # refusal: there is nothing to verify and nothing safe to push to.
    local push_urls="" push_url="" push_url_count=0 _push_u
    push_urls="$(git remote get-url --push --all origin 2>/dev/null || true)"
    while IFS= read -r _push_u; do
        [ -n "$_push_u" ] || continue
        push_url_count=$((push_url_count + 1))
        push_url="$_push_u"
    done <<<"$push_urls"
    if [ "$push_url_count" -eq 0 ]; then
        echo "ERROR: could not resolve origin's PUSH url (git remote get-url --push --all origin)." >&2
        echo "ERROR: 'git ls-remote origin' reads the FETCH url, which is NOT necessarily the" >&2
        echo "ERROR: delete target — 'pushurl'/'pushInsteadOf' can redirect it. Refusing the sweep." >&2
        return 1
    fi
    if [ "$push_url_count" -gt 1 ]; then
        echo "ERROR: origin has $push_url_count PUSH urls, so there is no single delete target:" >&2
        while IFS= read -r _push_u; do
            [ -n "$_push_u" ] || continue
            echo "ERROR:   $_push_u" >&2
        done <<<"$push_urls"
        echo "ERROR: 'git push origin' reaches ALL of them, so verifying one proves nothing about the" >&2
        echo "ERROR: others — the delete would report success while leaving the rest in place (and an" >&2
        echo "ERROR: unverified copy could be the one holding unmerged commits). Refusing the sweep." >&2
        return 1
    fi

    # ⛔ F29: PROVE THE PROOF ENDPOINT IS THE DELETE ENDPOINT, or REFUSE.
    #
    # `$push_url` is `git remote get-url --push origin` — git's own resolution of
    # the DELETE endpoint (`git push origin` lands exactly there). The merge
    # premise and the target check below, however, read it with
    # `git ls-remote "$push_url"`, and ls-remote is a FETCH: it applies
    # `url.<base>.insteadOf` ON TOP OF the already-resolved push url. When
    # `$push_url` is itself the base of an `insteadOf` mapping, the proof reads a
    # DIFFERENT repository than the delete lands on. Measured: with
    # `url.B.pushInsteadOf=A` and `url.C.insteadOf=B`, `get-url --push` → B,
    # `git ls-remote B` → C, and `git push origin` → B; C's main contained the
    # classified tip, B's never did, and B's unique ref was destroyed with rc=0.
    #
    # `git ls-remote --get-url "$push_url"` is git's own FETCH-side expansion of
    # the same URL the proof uses, and it contacts nothing. Equal to `$push_url`
    # ⇒ the proof and the delete name the SAME URL. Anything else ⇒ an
    # `insteadOf` rewrite (or a resolution failure, which yields empty)
    # separates them, and the sweep stands down. The refusal is at SWEEP level
    # because no single repository can be pinned at all: the premise is
    # unprovable, not merely unproven. This also covers the multi-hop case
    # (`pushurl=B` + `insteadOf B→C` + `insteadOf C→D`), where the fetch-side
    # read re-rewrites the resolved url even though `pushurl` IS set — so the
    # guard is NOT conditioned on `pushurl` being unset.
    local proof_url=""
    proof_url="$(git ls-remote --get-url "$push_url" 2>/dev/null || true)"
    if [ "$proof_url" != "$push_url" ]; then
        echo "ERROR: the merge proof and the delete resolve to DIFFERENT repositories, so no" >&2
        echo "ERROR: premise can be proved about the repository the delete lands on:" >&2
        echo "ERROR:   delete endpoint (git push origin):  $push_url" >&2
        echo "ERROR:   proof endpoint  (git ls-remote):    ${proof_url:-<unresolvable>}" >&2
        echo "ERROR: git ls-remote is a FETCH, so it re-applies url.<base>.insteadOf on top of" >&2
        echo "ERROR: origin's resolved push url; 'git push origin' does not. Refusing the sweep" >&2
        echo "ERROR: rather than prove a merge premise in a repository the delete never touches." >&2
        return 1
    fi
    echo ""

    # ⛔ RESOLVE THE MERGE BASE BEFORE CLASSIFYING AGAINST IT. `git branch -r
    # --merged "origin/$MAIN_BRANCH"` exits non-zero with NO output when that ref
    # does not resolve; the `|| true` this loop used to carry hid the status, the
    # candidate list stayed EMPTY, and the pass printed "No stale merged branches
    # found" and exited 0. That is under-deletion, but it is a FALSE PASS: a
    # scheduler reading only the status concludes the estate is clean while every
    # stale merged branch is still on the remote. This is exactly the "an
    # unreadable map is not an empty one" rule the LOCAL scope already enforces
    # with `main_ref_ok` — and here the classification IS the delete list, so an
    # unresolvable base must REFUSE, not silently select nothing. (A narrowed
    # positive refspec — `clone --single-branch --branch <other>`, `git remote
    # set-branches` — leaves exactly this state: the fetch exits 0 and
    # refs/remotes/origin/$MAIN_BRANCH is never created.)
    # ⛔ F18: THE CLASSIFICATION RUNS `--no-color` — the sweep's own plumbing must
    # not inherit the caller's git colour config. `git branch -r` COLOURISES the
    # ref names it prints when `color.ui=always` or `color.branch=always` is set,
    # so `$branch` became `\e[31morigin/foo\e[m`; every downstream read then got
    # an unreadable ref (`git log -1 --format='%ct'` exits 0 with EMPTY output,
    # `git rev-parse refs/remotes/$branch` fails), the candidate was dropped with
    # NO diagnostic, and the sweep printed `✅ No stale merged branches found` and
    # exited 0 — a FALSE PASS on the destructive path. `--no-color` is the
    # command-line override, so it beats `color.ui`/`color.branch` wherever they
    # are set (repo, global or `-c`); the script must never depend on the caller
    # turning colour off. Setting `color.ui=false` alone would NOT be enough —
    # `color.branch=always` still wins over it (verified on git 2.50.1).
    #
    # AUDIT of every OTHER git invocation whose OUTPUT IS PARSED (F18). Only a
    # ref-NAME render can be colourised; the rest are non-colourable by
    # construction, so they need no flag:
    #   * git branch --no-color --show-current  carries the flag (call site above)
    #   * git for-each-ref --no-color --format=...
    #                                           carries the flag (call site below);
    #                                           no flag would also do (a custom
    #                                           --format is not colourised), but
    #                                           the flag is free and uniform
    #   * git log --no-color -1 --format='%ct'  carries the flag (call site below)
    #   * git rev-list --count / rev-parse / merge-base
    #                                           numeric/OID/status output, never
    #                                           colourised. ⛔ `rev-parse` must NOT
    #                                           be given `--no-color`: it is parsed
    #                                           as a REVISION and PRINTED as one
    #   * git worktree list --porcelain         porcelain, never colourised
    #   * git ls-remote / config --get-all / remote get-url --push --all
    #                                           value/URL reads, plain text
    #   * git fetch / update-ref -d             status-only, no output parsed
    #   * git push                              OUTPUT IS PARSED, so this entry
    #                                           does NOT belong in a
    #                                           status-only list (F23). The
    #                                           execute path captures the push
    #                                           output and substring-greps it for
    #                                           `stale info` to tell a
    #                                           force-with-lease refusal from a
    #                                           real failure. No `--no-color` is
    #                                           needed: the rejection text is not
    #                                           colourised, so the substring still
    #                                           matches under `color.ui=always`
    #                                           (verified).
    local merged_list=""
    if ! merged_list="$(git branch --no-color -r --merged "origin/$MAIN_BRANCH" 2>/dev/null)"; then
        echo "ERROR: origin/$MAIN_BRANCH does not resolve, so no branch can be shown to be" >&2
        echo "ERROR: merged into main. 'git branch -r --merged origin/$MAIN_BRANCH' fails with" >&2
        echo "ERROR: no output in that state, which reads as 'nothing is stale' — an unreadable" >&2
        echo "ERROR: merge base is NOT an empty selection. Refusing the remote sweep; fetch" >&2
        echo "ERROR: refs/remotes/origin/$MAIN_BRANCH (a narrowed remote.origin.fetch refspec is the" >&2
        echo "ERROR: usual cause) and re-run." >&2
        return 1
    fi

    # ── Find stale merged branches ────────────────────────────────
    # Strategy:
    #   1. git branch -r --merged origin/main → all remote branches merged into main
    #   2. Exclude origin/main and origin/HEAD
    #   3. Check committer-date of last commit on each branch (< CUTOFF_DAYS ago)
    #   4. Collect stale candidates

    local STALE_BRANCHES=()
    # Refs belonging to a remote OTHER than origin. They are never deletion
    # candidates: deletion is always `git push origin --delete`, and
    # `${branch#origin/}` strips nothing from `upstream/foo`, so the pass would
    # tell ORIGIN to delete `refs/heads/upstream/foo` — a branch nothing has shown
    # to be merged into anything. They are reported, never silently skipped.
    local NON_ORIGIN_REMOTE=()
    local CUTOFF_EPOCH
    # ⛔ F31: THE CUTOFF EPOCH IS A SAFETY INPUT — refuse loudly when it cannot be
    # computed. Under CLEANUP_BRANCH_LOG, AND in `--scope both` (where
    # `run_remote_scope || rc=1` suppresses errexit for the whole function body —
    # F37), the pass runs without `set -e`, so an empty epoch made every
    # comparison below return status 2, which `if` reads as FALSE: the candidate
    # was dropped behind `✅ No stale merged branches found`.
    CUTOFF_EPOCH="$(cutoff_epoch)"
    if ! validate_cutoff_epoch "$CUTOFF_EPOCH"; then
        return 1
    fi

    while IFS= read -r branch; do
        # Strip leading whitespace, skip origin/main and origin/HEAD
        branch="$(echo "$branch" | sed 's/^[[:space:]]*//')"
        [ -z "$branch" ] && continue
        [ "$branch" = "origin/$MAIN_BRANCH" ] && continue
        # ⛔ Match the SYMREF's RENDERED FORM, not `origin/HEAD*`. `git branch -r`
        # renders the symref as `origin/HEAD -> origin/main`, and the glob
        # `origin/HEAD*` also matched every real remote branch whose name merely
        # BEGINS with `HEAD` (`origin/HEADfoo`), which was then `continue`d with
        # no selection line and no keep line — a SILENT skip, contradicting this
        # scope's rule that non-candidates are reported (F13). A space is illegal
        # in a ref name (`git check-ref-format` rejects it), so a rendered
        # `origin/HEAD -> ` prefix can never be a real branch and cannot collide.
        case "$branch" in
            "origin/HEAD -> "*) continue ;;
        esac

        # Check if branch commit date is before cutoff
        local COMMIT_DATE
        COMMIT_DATE="$(git log --no-color -1 --format='%ct' "$branch" 2>/dev/null || true)"
        # ⛔ F18/F24: AN UNREADABLE OR OVER-LONG DATE IS AN INTERNAL ERROR, NOT A
        # NON-CANDIDATE. Every ref reaching here was LISTED by the merge
        # classification, so it must have a readable commit date. The old
        # `|| echo "0"` + `= "0"` guard missed the ONE shape that mattered: with
        # `color.ui=always` (or `color.branch=always`) the classification's ref
        # names came back wrapped in SGR escapes, `git log -1 --format='%ct'
        # "\e[31morigin/foo\e[m"` exits 0 with EMPTY output (verified on git
        # 2.50.1), the `= "0"` guard did not fire, and `[ "" -lt "$CUTOFF_EPOCH" ]`
        # returned status 2, which the `if` reads as FALSE. The ref was dropped
        # with NO diagnostic while the sweep printed `✅ No stale merged branches
        # found` and exited 0. F24: the SAME false PASS came back for an
        # OVER-LONG all-digit value — `''|*[!0-9]*` accepts `9223372036854775808`,
        # `[ "$COMMIT_DATE" -lt "$CUTOFF_EPOCH" ]` returns status 2, the `if`
        # reads FALSE, and the candidate is dropped behind a success status again.
        # ⛔ ONE implementation, called from BOTH scopes (F24). The local scope
        # carried its own copy with the file's own 15-digit bound, so the two had
        # already drifted twice: a value this guard let through as a silent
        # non-candidate was refused there. validate_commit_date is now the single
        # bound for both, and this guard makes ANY future route LOUD — an empty,
        # non-numeric or over-long value REFUSES the whole sweep instead of
        # silently shrinking the candidate set behind a success status.
        if ! validate_commit_date "$branch" "$COMMIT_DATE"; then
            return 1
        fi

        # ⛔ DELIMITER IS TAB, NOT `|`: `|` is a LEGAL git branch-name character
        # (`git check-ref-format --branch 'a|b'` accepts it), so a remote branch
        # named `release|2020-01-01` parsed with `${entry%%|*}` yielded
        # `origin/release` and `--execute` deleted a branch that was never
        # selected (`release` need not be stale or merged). TAB is a control
        # character git ref names cannot contain (same sentinel the local
        # scope's `delete_list` uses), so it cannot collide. Each record is read
        # back with `IFS=$'\t' read`, as the local scope already does.
        if [ "$COMMIT_DATE" -lt "$CUTOFF_EPOCH" ]; then
            local COMMIT_DATE_HR
            # ⛔ F25: `date -r` reads its argument as a DATE STRING on macOS, so a
            # zero-padded `%ct` such as `0000000009` is rejected (`illegal option
            # -- d`, no `date -d` on macOS); in `--scope remote` without the log that
            # aborted the whole sweep under `set -e` with rc=1 before any plan was
            # printed, and in the modes where errexit is suppressed (F37) the same
            # value instead emptied the date. `$((10#$...))`
            # re-reads the digit string as base 10, so `date` ALWAYS receives plain
            # seconds — the helper above already bounded the normalised value to
            # ≤15 digits, so this arithmetic cannot overflow.
            COMMIT_DATE_HR="$(_date --fmt "$((10#$COMMIT_DATE))" '%Y-%m-%d')"
            # ⛔ `git branch -r --merged` lists EVERY remote's tracking refs, but
            # deletion is ALWAYS `git push origin --delete ${branch#origin/}`. For
            # a non-origin ref that prefix-strip removes nothing, so the premise
            # would be evaluated on `upstream/foo` while the destructive action
            # landed on origin's `refs/heads/upstream/foo` — a branch never shown
            # to be merged anywhere. Confine the scope to `origin/*`.
            # ⛔ TAB is the separator, NOT `|`: `|` is a legal ref-name
            # character (`git check-ref-format 'refs/heads/foo|bar'` is OK), so a
            # `|`-delimited entry decoded with `${entry%%|*}` truncated
            # `origin/foo|bar` to `origin/foo` — the premise was evaluated on one
            # ref and the delete landed on ANOTHER. `check-ref-format` REJECTS a
            # TAB in a ref name, so the sentinel cannot collide.
            if [[ "$branch" != origin/* ]]; then
                NON_ORIGIN_REMOTE+=("$branch"$'\t'"$COMMIT_DATE_HR")
                continue
            fi
            # The tip THIS pass classified, captured now so the delete-time
            # verification compares origin's real ref against what was actually
            # classified (not against a re-read taken later).
            local TRACKING_OID
            TRACKING_OID="$(git rev-parse --verify -q "refs/remotes/$branch" 2>/dev/null || true)"
            STALE_BRANCHES+=("$branch"$'\t'"$COMMIT_DATE_HR"$'\t'"$TRACKING_OID")
        fi
    done <<<"$merged_list"

    # ⛔ DELETE ORDER: longest local branch first. `git push --delete --
    # refs/heads/foo` fails with "dst refspec refs/heads/foo matches more than
    # one" while refs/heads/refs/heads/foo exists, because refspec matching is
    # SUFFIX based (the same mechanism the delete-time verifier now checks by
    # NAME). Deleting the longer (nested) ref FIRST removes the ambiguity, so the
    # shorter one becomes deletable. Length-descending, not reversal: the nesting
    # holds for ANY `X` / `refs/heads/X` pair, whatever X's first character is.
    # (`sort`/`awk`/`cut` are POSIX; no Bash 3.2 arrays tricks.)
    if [ "${#STALE_BRANCHES[@]}" -gt 1 ]; then
        # ⛔ F35: THIS IS THE ONE REMOTE-SCOPE INPUT THAT FEEDS THE DELETE LIST
        # AND IS NOT A `git` COMMAND, AND IT WAS UNGUARDED. Every sibling (`git
        # fetch`, the ref listings, `ls-remote`, the PR map, the commit dates,
        # the cutoff) is status-checked. Under CLEANUP_BRANCH_LOG — the shipped
        # launchd configuration — the whole pass runs `set +e`, so a pipeline
        # failure left `_stale_sorted` EMPTY, `STALE_BRANCHES` an empty array,
        # and the sweep printed `✅ No stale merged branches found` and exited 0:
        # a CLEAN sweep over candidates it had already found and then silently
        # discarded. ⛔ F37: `set -e` IS NOT A BACKSTOP HERE, AND IT MUST NOT BE
        # CITED AS ONE. Bash suppresses errexit for the ENTIRE function body when
        # the function is the LEFT OPERAND of `||`, and `run_scopes` calls
        # `run_remote_scope || rc=1` under `--scope both` — so with or WITHOUT the
        # log a failing `sort` did NOT abort: the run printed `✅ No stale merged
        # branches found` and continued into the local leg. (Measured with this
        # guard removed, `--scope both`, no log.) THIS guard is therefore the ONLY
        # protection, it must fail CLOSED in EVERY mode, and nothing in the remote
        # scope may lean on errexit. `pipefail` is set globally and is NOT undone
        # by `set +e`, so the assignment's status below sees a failing
        # `printf`/`awk`/`sort`/`cut` even though the pipeline's LAST stage
        # succeeded. Refuse loudly — a pipeline failure is not an empty candidate
        # list, and reporting one as the other is the false PASS.
        local _stale_sorted="" _stale_order_rc=0
        _stale_sorted="$(printf '%s\n' "${STALE_BRANCHES[@]}" \
            | awk -F'\t' '{ print length($1) "\t" $0 }' \
            | sort -rn -k1,1 \
            | cut -f2-)" || _stale_order_rc=$?
        if [ "$_stale_order_rc" -ne 0 ]; then
            echo "ERROR: could not order the stale branch list (printf | awk | sort | cut FAILED, rc=$_stale_order_rc)." >&2
            echo "ERROR: ${#STALE_BRANCHES[@]} candidate(s) WERE classified and then discarded, so this pass" >&2
            echo "ERROR: cannot report a clean sweep. A pipeline failure is NOT an empty candidate list." >&2
            echo "ERROR: Refusing the remote sweep; re-run once awk/sort/cut are usable." >&2
            return 1
        fi
        STALE_BRANCHES=()
        local _stale_entry
        while IFS= read -r _stale_entry; do
            [ -n "$_stale_entry" ] || continue
            STALE_BRANCHES+=("$_stale_entry")
        done <<<"$_stale_sorted"
    fi

    # ── non-origin remotes are reported, never deleted ────────────
    if [ ${#NON_ORIGIN_REMOTE[@]} -gt 0 ]; then
        echo "Kept ${#NON_ORIGIN_REMOTE[@]} stale merged ref(s) on a NON-origin remote (origin is the only remote this pass can delete through):"
        local nonorigin_entry
        for nonorigin_entry in "${NON_ORIGIN_REMOTE[@]}"; do
            printf '  keep   %-18s %s\n' "non-origin-remote" "${nonorigin_entry%%$'\t'*}"
        done
        echo ""
    fi

    # ── Output ────────────────────────────────────────────────────
    if [ ${#STALE_BRANCHES[@]} -eq 0 ]; then
        echo "✅ No stale merged branches found (cutoff: $CUTOFF_DAYS days)."
        return 0
    fi

    echo "Found ${#STALE_BRANCHES[@]} stale merged branch(es):"
    echo ""
    local entry branch commit_date_hr rest
    for entry in "${STALE_BRANCHES[@]}"; do
        branch="${entry%%$'\t'*}"
        rest="${entry#*$'\t'}"
        commit_date_hr="${rest%%$'\t'*}"
        printf "  %-55s last commit: %s\n" "$branch" "$commit_date_hr"
    done
    echo ""

    # ⛔ `real_main_oid`/`real_main_resolve_reason` hold the DELETE TARGET's real
    # main for the entry ABOUT TO BE EVALUATED. The read is split from the check
    # because the check's refusal reason is captured through `$(...)` — a
    # subshell — so a memo written inside the check would be discarded with the
    # subshell. ⛔ F34/F36: BOTH legs re-read it ONCE PER ENTRY; neither snapshots
    # it for the sweep. A failed read yields an EMPTY oid plus the reason, which
    # the check reports per entry with the SAME message a per-entry read would
    # have produced. Nothing is read when there is no candidate (the empty arm
    # returns above).
    local real_main_oid="" real_main_resolve_reason=""

    if [ "$EXECUTE" = false ]; then
        echo "── DRY-RUN: no branches deleted ──"
        echo "To delete: bash scripts/cleanup-stale-branches.sh --execute"
        echo ""
        echo "Deletion commands that would run:"
        # ⛔ F20: THE PLAN MUST RUN THE SAME TWO GATES `--execute` RUNS, per
        # entry, and MARK an entry they would refuse. Printing a delete for an
        # entry execute refuses is a data-loss path by paste: the lease pins the
        # OID, but it cannot check the MERGE PREMISE. A branch classified
        # `--merged` from a stale `origin/$MAIN_BRANCH` (narrowed positive
        # refspec) whose commits are no longer in REWRITTEN real main passes the
        # lease and is deleted by a pasted line, while `--execute` REFUSES it.
        # So the plan calls the SAME verify_merged_into_real_main /
        # verify_remote_target the execute loop calls — never a second
        # implementation that can drift (the defect class this branch has been
        # closing) — and a refused entry is printed ONLY as a comment, never as
        # an executable command, and its premise is read PER ENTRY (F36) — so the
        # two legs evaluate the same premise at the same time: the commands the
        # plan shows are exactly the ones `--execute` would run at plan time.
        for entry in "${STALE_BRANCHES[@]}"; do
            branch="${entry%%$'\t'*}"
            # ⛔ Build the command ONCE, as an array, and PRINT it through
            # `quote_argv`. The dry-run exists to tell the operator what
            # `--execute` WOULD run, so the printed form and the executed argv
            # must be the SAME array — two hand-kept copies drift, and the
            # printed copy is the one a human pastes into a shell. `%q` quoting
            # in `quote_argv` makes pasting re-parse to exactly this argv even
            # when the ref name carries `"`, `$()`, a backtick or `|` (all legal
            # in a git ref name); the raw `--force-with-lease="...$branch..."`
            # echo let those run as commands on paste.
            # ⛔ The decoded oid is the SAME one the execute loop leases, and the
            # `--force-with-lease` clause IS the safety mechanism: it sends the
            # classified oid through the SAME resolution as the delete, so a
            # pushInsteadOf/pushurl divergence is refused by the receiving
            # repository instead of deleting unconditionally.
            local tracking_oid="${entry##*$'\t'}"
            local local_branch="${branch#origin/}"
            # ⛔ F36: RE-READ the DELETE TARGET's real main FOR THIS ENTRY, exactly
            # as the execute loop does (F34) — the plan must evaluate the SAME
            # premise at the SAME time. A once-per-sweep snapshot made the plan
            # print an EXECUTABLE `git push origin --delete` for an entry it would
            # itself have REFUSED had it read main per entry: a mid-sweep rewrite
            # left the later candidate validated against a main that no longer
            # contained its tip. Because the printed line is a raw, paste-safe
            # command, NOTHING re-gates it except re-running --execute, and the
            # lease pins the BRANCH ref, never main — so a paste destroyed the
            # branch's unique commits. `read_remote_main_oid` is the SAME function
            # the execute loop calls — one implementation, one message set, and
            # the two legs' call counts are now IDENTICAL (2N+1).
            if ! real_main_oid="$(read_remote_main_oid "$push_url")"; then
                real_main_resolve_reason="$real_main_oid"
                real_main_oid=""
            fi
            # F20: the SAME two gates the execute loop applies, at plan time.
            local plan_refusal=""
            if ! plan_refusal="$(verify_merged_into_real_main "$real_main_oid" "$real_main_resolve_reason" "$tracking_oid")"; then
                printf '  # REFUSED — --execute will not run this: %s\n' "$plan_refusal"
                continue
            fi
            if ! plan_refusal="$(verify_remote_target "$push_url" "$local_branch" "$tracking_oid")"; then
                printf '  # REFUSED — --execute will not run this: %s\n' "$plan_refusal"
                continue
            fi
            local cmd=(git push origin --delete \
                "--force-with-lease=refs/heads/$local_branch:$tracking_oid" \
                -- "refs/heads/$local_branch")
            printf '  %s\n' "$(quote_argv "${cmd[@]}")"
        done
        return 0
    fi

    # ── Execute: delete stale branches ────────────────────────────
    echo "── EXECUTE: deleting ${#STALE_BRANCHES[@]} stale branches ──"
    echo ""
    local DELETED=0
    local FAILED=0
    local REFUSED=0

    for entry in "${STALE_BRANCHES[@]}"; do
        branch="${entry%%$'\t'*}"
        local tracking_oid="${entry##*$'\t'}"
        local local_branch="${branch#origin/}"

        # ⛔ DELETE-TIME VERIFICATION. The classification above reads
        # refs/remotes/origin/<br>, but the destructive action targets origin's
        # real refs/heads/<br>. Nothing has proved they are the SAME ref: a
        # NARROWED positive refspec (or a negative one) leaves the tracking ref
        # stale while the fetch exits 0, and origin can change between the fetch
        # and this push. So compare them immediately before the delete and REFUSE
        # this one on any mismatch — or when ls-remote yields nothing, which is
        # not evidence the classification was right.
        #
        # ⛔ FIRST re-prove the MERGE premise itself against origin's REAL main.
        # The classification was `git branch -r --merged origin/main` — the LOCAL
        # tracking ref, which a narrowed fetch refspec can leave stale while the
        # fetch exits 0. A branch classified `--merged` from a stale main may
        # have NO commits in real main (main rewritten), and deleting it destroys
        # them. That is a different question from "is origin's real ref the ref
        # we classified", so it is a separate gate, not a weaker one.
        # ⛔ F34/F36: RE-READ the DELETE TARGET's real main FOR THIS ENTRY,
        # immediately before the delete. main is NOT constant across a sweep: a
        # force-push to it between the previous candidate and this one invalidates
        # the merge premise for every LATER candidate, so a once-per-sweep
        # snapshot would keep validating them against a main that no longer
        # contains their tips and delete precisely the unmerged branches this gate
        # exists to protect. The lease pins the BRANCH ref, never main, so THIS
        # read is the only thing that can catch the rewrite. The plan performs the
        # IDENTICAL per-entry read (F36) — neither leg snapshots — so the plan and
        # execute evaluate the same premise at the same time. `read_remote_main_oid`
        # is the SAME function the plan calls — one implementation, one message set.
        if ! real_main_oid="$(read_remote_main_oid "$push_url")"; then
            real_main_resolve_reason="$real_main_oid"
            real_main_oid=""
        fi
        local refusal=""
        if ! refusal="$(verify_merged_into_real_main "$real_main_oid" "$real_main_resolve_reason" "$tracking_oid")"; then
            echo "  ⛔ REFUSING to delete origin/$local_branch" >&2
            echo "     $refusal" >&2
            echo "     The branch was classified merged from the LOCAL refs/remotes/origin/$MAIN_BRANCH," >&2
            echo "     but the DELETE TARGET's REAL refs/heads/$MAIN_BRANCH does not provably contain the" >&2
            echo "     classified tip. A narrowed positive refspec leaves refs/remotes/origin/$MAIN_BRANCH stale" >&2
            echo "     while the fetch exits 0, or the push target's main is not the fetch target's — if main was" >&2
            echo "     rewritten (or the push url names another repository) the branch's commits are no longer in" >&2
            echo "     main and deleting it would destroy the only copy." >&2
            REFUSED=$((REFUSED + 1))
            continue
        fi
        if ! refusal="$(verify_remote_target "$push_url" "$local_branch" "$tracking_oid")"; then
            echo "  ⛔ REFUSING to delete origin/$local_branch" >&2
            echo "     $refusal" >&2
            echo "     origin's real ref is not provably the ref this sweep classified. A narrowed" >&2
            echo "     or negative fetch refspec leaves refs/remotes/$branch STALE while the fetch" >&2
            echo "     exits 0, or origin changed between the fetch and this delete. Deleting on" >&2
            echo "     the stale tip would destroy commits that exist nowhere else." >&2
            REFUSED=$((REFUSED + 1))
            continue
        fi

        echo "  Deleting origin/$local_branch..."
        # ⛔ `--` before the refspec: without it a remote branch named `-x` or
        # `--version` is parsed by `git push` as an OPTION, the delete always
        # fails, and such a ref could never be reaped. The same `--` is mirrored
        # in the dry-run command echo above.
        # ⛔ The ref must be FULLY QUALIFIED (`refs/heads/<br>`). A bare name is
        # NOT always a legal refspec: `@` is a legal ref name but also a revision
        # shorthand, so `git push origin --delete @` fails with `fatal: invalid
        # refspec ':@'` and the branch could never be reaped. A bare `foo` is
        # also ambiguous when origin carries both `foo` and `refs/heads/foo`
        # ('matches more than one'), while the qualified form targets exactly one
        # ref. The delete goes through GIT'S OWN REMOTE RESOLUTION
        # (`git push origin`), which applies pushInsteadOf/pushurl EXACTLY ONCE.
        #
        # ⛔ That is NOT the resolution verify_remote_target used. `git ls-remote
        # <resolved push url>` is a FETCH, so it applies `url.<base>.insteadOf` to
        # the ALREADY-RESOLVED push url; the push applies `pushInsteadOf` to
        # origin's FETCH url and never then applies `insteadOf`. When the resolved
        # push url is itself the base of an `insteadOf` mapping the two disagree:
        # the verification proves repository C while the delete lands on repo B —
        # and, because the fetch and push targets differ, git applies NO
        # compare-and-swap and deletes B unconditionally (measured: the sweep
        # reported `Deleted: 1 / Refused: 0` and B's unique UNMERGED branch was
        # gone). Pushing to the RESOLVED URL instead would apply the rewrite a
        # SECOND time and land on yet another unverified repository (R5-1).
        #
        # The verification is kept as an early, loud diagnostic; what makes the
        # delete SAFE is GIT'S OWN LEASE. `--force-with-lease` sends the
        # classified oid as the expected old value through the SAME resolution as
        # the delete, so the receiving repository itself REFUSES unless its ref is
        # exactly the oid this sweep classified. An unresolvable classified oid
        # leaves the lease's expected value EMPTY, and git then requires the ref
        # not to exist — a refusal, never an unguarded delete (fail-closed).
        # ⛔ The delete runs the SAME array the dry-run plan prints (built just
        # below), so the printed plan and the executed argv cannot diverge.
        local push_out="" push_rc=0
        local cmd=(git push origin --delete \
            "--force-with-lease=refs/heads/$local_branch:$tracking_oid" \
            -- "refs/heads/$local_branch")
        push_out="$("${cmd[@]}" 2>&1)" || push_rc=$?
        if [ "$push_rc" -eq 0 ]; then
            if [ -n "$push_out" ]; then printf '%s\n' "$push_out"; fi
            echo "    ✅ deleted"
            DELETED=$((DELETED + 1))
        elif grep -qF 'stale info' <<<"$push_out"; then
            echo "  ⛔ REFUSING to delete origin/$local_branch" >&2
            echo "     the delete lease rejected: origin/$local_branch is not at the classified tip $tracking_oid" >&2
            printf '%s\n' "$push_out" >&2
            echo "     The ls-remote verification above reads the resolved push url as a FETCH, which can" >&2
            echo "     prove a DIFFERENT repository than the one pushInsteadOf/pushurl actually deletes from." >&2
            echo "     The lease is the compare-and-swap: nothing is deleted unless the target ref is exactly" >&2
            echo "     what this sweep classified." >&2
            REFUSED=$((REFUSED + 1))
        else
            if [ -n "$push_out" ]; then printf '%s\n' "$push_out"; fi
            echo "    ❌ failed (may already be deleted or protected)"
            FAILED=$((FAILED + 1))
        fi
    done

    echo ""
    echo "── Summary ──"
    echo "  Deleted: $DELETED"
    echo "  Failed:  $FAILED"
    echo "  Refused: $REFUSED"
    echo "  Total:   ${#STALE_BRANCHES[@]}"

    if [ "$REFUSED" -gt 0 ]; then
        echo "ERROR: $REFUSED remote delete(s) were REFUSED: origin's real ref could not be shown to" >&2
        echo "ERROR: be the ref this sweep classified. The sweep does NOT report success." >&2
        return 1
    fi
    # ⛔ A non-zero push exit that is NOT a lease refusal (`stale info`) is counted
    # `Failed` — an ambiguous target, a protected ref, a transport failure. The
    # EXIT STATUS must say so: it is the only signal a scheduler reads, and
    # `Failed: 1` with rc=0 reports "the sweep succeeded" while a selected branch
    # was never reaped. So the status means "everything the sweep selected was
    # reaped", and any leftover makes it non-zero.
    if [ "$FAILED" -gt 0 ]; then
        echo "ERROR: $FAILED remote delete(s) FAILED (not a lease refusal): a selected branch was" >&2
        echo "ERROR: not reaped. The sweep does NOT report success." >&2
        return 1
    fi

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

    # The map is folded into four `case`-matchable membership strings (Bash 3.2
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
    # fresh": this gate is DISABLED instead, loudly.
    # ⚠️ That stands down the REMOTECOPY gate ONLY — not the `redundant` gate
    # below, which is ref-LOCAL: it compares the branch against the local
    # refs/remotes/origin/main tracking ref, and a failed fetch leaves that ref
    # resolvable (merely stale), so `main_ref_ok` stays 1 and the gate still
    # fires. Deliberate, and pinned by tests (a `redundant` branch needs no
    # remote). It is safe for reachability — a `redundant` selection is by
    # construction an ancestor of that tracking ref, so `-d` leaves the commits
    # reachable — but it is NOT the same shape as a missing origin/main.
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
    # ⛔ F31: same guard, same polarity here — an empty epoch made
    # `[ "$cdate" -ge "$CUTOFF_EPOCH" ]` return status 2, the `if` read FALSE, and
    # a FRESH branch was classified STALE and deleted.
    CUTOFF_EPOCH="$(cutoff_epoch)"
    if ! validate_cutoff_epoch "$CUTOFF_EPOCH"; then
        return 1
    fi

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
    if ! branches="$(git for-each-ref --no-color \
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
        # ⛔ F22/F24: AN UNREADABLE OR OVER-LONG COMMITTER DATE IS AN INTERNAL
        # ERROR, NEVER A STALENESS VERDICT. `git for-each-ref` can read objects
        # `git log` cannot format, and `%(committerdate:unix)` prints a value
        # ABOVE bash's integer range as an all-digit wrapped number. A bare
        # `[ "$cdate" -ge "$CUTOFF_EPOCH" ]` then returns status 2, the `||` reads
        # FALSE, and the branch is treated as STALE — so on THIS scope the
        # failure GROWS the candidate set, the OPPOSITE polarity to the remote
        # scope above, where the same failure SHRINKS it and hides the candidate
        # behind a clean sweep. Both are internal errors, so both refuse.
        # ⛔ ONE bound for BOTH scopes (F24): validate_commit_date carries the
        # file's own 15-digit bound (the same bound `--cutoff` is validated with),
        # so an empty, non-numeric or over-long date REFUSES the whole local sweep
        # and names the ref, instead of falling through as "stale". Calling the
        # SAME helper the remote scope calls is the fix for the drift: the local
        # guard used to refuse an over-long value while the remote one did not,
        # because the check was written twice.
        if ! validate_commit_date "$br" "$cdate"; then
            return 1
        fi
        # 3. not stale
        if [ "$cdate" -ge "$CUTOFF_EPOCH" ]; then
            keep_list="${keep_list}not-stale"$'\t'"$br"$'\n'
            keep_notstale=$((keep_notstale + 1)); keep_total=$((keep_total + 1)); continue
        fi
        # 4. OPEN PR
        if is_member "$open_lookup" "$br"; then
            keep_list="${keep_list}open-pr"$'\t'"$br"$'\n'
            keep_openpr=$((keep_openpr + 1)); keep_total=$((keep_total + 1)); continue
        fi

        # 5. the three gates — first match wins (merged first: it is the only
        #    class that authorizes the force-delete fallback, and it is the
        #    strongest evidence).
        cls=""
        local offbase=0
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
            # Merged into a base that is not main (a stacked PR): that proves the
            # content is in THAT base, not in main — so it is NOT by itself
            # authority to delete. But it is also NOT a verdict: an off-base
            # merged PR whose local tip is already contained in origin/main is
            # provably redundant, and the old unconditional `continue` gave such a
            # branch a permanent false negative — no pass ever selected it. Record
            # the off-base reason and FALL THROUGH to the redundant/remotecopy
            # gates; only if neither carries the branch is it kept.
            offbase=1
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

        if [ -z "$cls" ] && [ "$offbase" = 1 ]; then
            # Off-base MERGED PR and no other gate carries the branch: keep it,
            # named. This is the fall-through destination for the off-base reason
            # above — it must NOT pre-empt the redundant/remotecopy gates.
            keep_list="${keep_list}merged-base-not-main"$'\t'"$br"$'\n'
            keep_offbase=$((keep_offbase + 1)); keep_total=$((keep_total + 1)); continue
        fi

        if [ -z "$cls" ]; then
            keep_list="${keep_list}localonly"$'\t'"$br"$'\n'
            keep_localonly=$((keep_localonly + 1)); keep_total=$((keep_total + 1)); continue
        fi

        # Third column: the classified TIP. The `merged` force-delete uses it as
        # the old value of the atomic `update-ref -d`; `-d` never needs it.
        delete_list="${delete_list}${cls}"$'\t'"$br"$'\t'"$sha"$'\n'
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
        while IFS=$'\t' read -r cls br sha; do
            [ -n "$cls" ] || continue
            printf '  delete %-10s %s\n' "$cls" "$br"
        done <<<"$delete_list"
    fi
    echo ""

    # ── EXECUTE or DRY-RUN ────────────────────────────────────────
    local deleted=0 failed=0 moved=0
    if [ "$EXECUTE" = true ] && [ "$sel_total" -gt 0 ]; then
        echo "── EXECUTE: deleting $sel_total stale local branch(es) ──"
        echo ""
        # Columns: cls<TAB>br<TAB>sha. `sha` is the tip the classified gate
        # PROVED (for `merged`, the PR's headRefOid it equalled). It is the OLD
        # value passed to the atomic `update-ref -d` below.
        while IFS=$'\t' read -r cls br sha; do
            [ -n "$cls" ] || continue
            # ⛔ `--` before the ref: without it a branch whose name begins with
            # `-` (`-x`, `--version`) is parsed by git as an OPTION, the delete
            # always fails, and such a ref could never be reaped. The same `--`
            # must be mirrored in the dry-run command echo below.
            if git branch -d -- "$br" >/dev/null 2>&1; then
                printf '  deleted %-10s %s\n' "$cls" "$br"
                deleted=$((deleted + 1))
            elif [ "$cls" = "merged" ]; then
                # ⛔ COMPARE-AND-SWAP (F12): `git update-ref -d <ref> <old>` is
                # the atomically-checked delete. git itself compares the ref's
                # CURRENT value to <old> and removes it in the SAME operation,
                # refusing unless they match — exactly as the remote leg's
                # `--force-with-lease` is checked by the receiving repository.
                # The `merged` gate proved the tip only at CLASSIFICATION time,
                # so a commit landing after that proof must never be destroyed.
                #
                # ⛔ THE PRE-CHECK BELOW (read cur_tip, compare to sha) IS NOT THE
                # SAFETY MECHANISM. The read and the delete are two separate git
                # processes, so a commit landing BETWEEN them is invisible to the
                # check; the pre-check exists only to produce a good `moved`
                # message. The `update-ref -d` old-value argument is what makes
                # that window harmless.
                local cur_tip=""
                cur_tip="$(git rev-parse -q --verify "refs/heads/$br" 2>/dev/null || true)"
                if [ "$cur_tip" != "$sha" ]; then
                    printf '  moved   %-10s %s (tip advanced %s -> %s; update-ref refused)\n' \
                        "$cls" "$br" "$sha" "${cur_tip:-<deleted>}"
                    moved=$((moved + 1))
                else
                    # (a) `git update-ref -d` does NOT refuse a CHECKED-OUT
                    # branch (`git branch -D` does; verified 2026-10-15: it
                    # removes the checked-out branch and leaves HEAD pointing at
                    # the now-absent ref). The delete path must therefore be safe
                    # on its OWN rather than relying on the classification's
                    # `worktree:` keep rule — the branch could have been checked
                    # out in the window since. Re-enumerate the worktrees
                    # IMMEDIATELY before the swap. A failed enumeration is a
                    # REFUSAL (fail-closed), never an assumed "not checked out".
                    local wt_now=""
                    if ! wt_now="$(git worktree list --porcelain 2>/dev/null)"; then
                        printf '  failed  %-10s %s (could not enumerate worktrees; refused force-delete)\n' "$cls" "$br"
                        failed=$((failed + 1))
                        continue
                    fi
                    # ⛔ TWO patterns, not one: command substitution strips ALL
                    # trailing newlines, so when the target is the LAST entry in
                    # `git worktree list --porcelain` its `branch refs/heads/<br>`
                    # line is NOT followed by a newline in `$wt_now` and a lone
                    # `...$'\n'*` pattern MISSES the very branch being deleted. The
                    # second alternative anchors at end-of-string, so it matches
                    # the final entry; `*"..."` requires the string to END with
                    # the literal, so a longer name (`HEADfoo` vs `HEAD`) still
                    # does not match.
                    case "$wt_now" in
                        *"branch refs/heads/$br"$'\n'* | *"branch refs/heads/$br")
                            printf '  failed  %-10s %s (checked out in a worktree; update-ref refused)\n' "$cls" "$br"
                            failed=$((failed + 1))
                            continue ;;
                    esac
                    # ⛔ AN EMPTY `$sha` TURNS THE SWAP INTO AN UNCONDITIONAL
                    # DELETE (F15). `git update-ref -d <ref> <old>` refuses
                    # unless the ref's current value equals <old> — but with an
                    # EMPTY <old> git does NO comparison at all and removes the
                    # ref (verified on git 2.50.1: rc=0, ref deleted). Nothing
                    # here guarantees `$sha` is non-empty: it comes from the
                    # classification's `%(objectname)` field, and the pre-check
                    # above is — by its own comment — NOT the safety mechanism.
                    # The invariant must be LOCAL to the swap, so refuse the
                    # force-delete whenever the classified tip is empty rather
                    # than hand git an old value that disables the comparison.
                    # Reported `failed` (never `deleted`), so the sweep exits
                    # non-zero.
                    if [ -z "$sha" ]; then
                        printf '  failed  %-10s %s (classified tip was UNRESOLVABLE; refused an unconditional update-ref -d)\n' "$cls" "$br"
                        failed=$((failed + 1))
                        continue
                    fi
                    # (b) `git update-ref -d` DOES remove logs/refs/heads/<br>
                    # exactly as `git branch -D` does (verified), and after a
                    # SUCCESSFUL swap the `branch.<br>.*` config section is
                    # removed below (F16) — so the two agree on config as well as
                    # on the reflog. The ONE residual difference is that `-d`
                    # does not refuse a CHECKED-OUT branch, which the worktree
                    # guard above handles explicitly.
                    if git update-ref -d "refs/heads/$br" "$sha" >/dev/null 2>&1; then
                        # Squash-merged AND unmoved: the classification already
                        # proved the local tip IS the revision the PR merged (it
                        # equalled headRefOid), so `-d` refused only because the
                        # squash commit is not an ancestor of main. The atomic
                        # old-value check is correct ONLY here.
                        #
                        # (F16) `git branch -D` also drops the `branch.<br>.*`
                        # config section; `update-ref -d` does not. Remove it so
                        # a branch later recreated under the same name does not
                        # inherit a stale upstream that this sweep's own `-d`
                        # and its plan prediction would then consult. A MISSING
                        # section must not fail the run — `git branch -D` is
                        # equally silent when there is nothing to remove.
                        git config --remove-section "branch.$br" >/dev/null 2>&1 || true
                        printf '  deleted %-10s %s (via update-ref -d: squash-merged PR)\n' "$cls" "$br"
                        deleted=$((deleted + 1))
                    else
                        # ⛔ The swap REFUSED: the tip moved between the read
                        # above and the atomic update, or another writer holds
                        # the ref lock. Report `moved` (NEVER `deleted`) and fail
                        # the sweep, exactly as the pre-check's `moved` arm does.
                        # Re-read once for the diagnostic only; the value is used
                        # for no safety decision.
                        local new_tip=""
                        new_tip="$(git rev-parse -q --verify "refs/heads/$br" 2>/dev/null || true)"
                        if [ -z "$new_tip" ] || [ "$new_tip" = "$sha" ]; then
                            printf '  moved   %-10s %s (update-ref -d refused; tip still %s — concurrent update or ref lock)\n' \
                                "$cls" "$br" "$sha"
                        else
                            printf '  moved   %-10s %s (tip advanced %s -> %s; update-ref -d refused)\n' \
                                "$cls" "$br" "$sha" "$new_tip"
                        fi
                        moved=$((moved + 1))
                    fi
                fi
            else
                printf '  failed  %-10s %s (git branch -d refused; force-delete not allowed for this class)\n' "$cls" "$br"
                failed=$((failed + 1))
            fi
        done <<<"$delete_list"
        echo ""
    elif [ "$sel_total" -gt 0 ]; then
        echo "── DRY-RUN: no branches deleted (PREVIEW of --execute) ──"
        echo "To delete: bash scripts/cleanup-stale-branches.sh --scope local --execute"
        echo ""
        # ⛔ F19: THE HEADER MUST NOT IMPLY THIS BLOCK IS A PASTE-SAFE SCRIPT.
        # It is a PREVIEW. For a SQUASH-merged branch the printed `git branch -d`
        # REFUSES (its tip is not an ancestor of HEAD), so a verbatim paste under
        # `set -e` stops at that line and reaps only the branches printed before
        # it — while `--execute` falls back to the atomic `git update-ref -d` and
        # reaps every selected branch. The fallback stays a COMMENT: printing it
        # as a second command would advertise `-d || update-ref -d`, whose `||`
        # arm can dangle HEAD for a branch that became checked out, which
        # `--execute`'s worktree guard refuses. So the fix is to say plainly what
        # a paste of this list actually does, not to change what is printed — no
        # line below may claim a property the paste does not have.
        echo "⚠️  PREVIEW ONLY — this is NOT a paste-safe script."
        echo "    Run --execute to reap every selected branch: a squash-merged branch's"
        echo "    'git branch -d' REFUSES. Under 'set -e' a verbatim paste STOPS at that"
        echo "    line and reaps only the branches printed before it. WITHOUT 'set -e' the"
        echo "    paste CONTINUES past the refusal and reaps the later 'git branch -d' lines"
        echo "    too — leaving the refusing branch behind. Either way, use --execute to"
        echo "    reap everything."
        echo "Deletion commands that would run (force-delete fallback only for a merged branch that -d will refuse):"
        while IFS=$'\t' read -r cls br sha; do
            [ -n "$cls" ] || continue
            # ⛔ Build the command ONCE, as an array, and PRINT it through
            # `quote_argv` — the SAME primitive the remote plan uses. A local
            # branch name may legally contain `"`, `$()`, a backtick or `|`
            # (`git check-ref-format` permits them), so the old hand-built
            # `git branch -d -- "%s"` echo ran `$(id)` as a COMMAND and mangled
            # a `"`-bearing name when the operator pasted it. `%q` quoting makes
            # evaluating the printed line re-parse to exactly the argv the
            # execute path runs. The `# class=<cls>` annotation stays OUTSIDE the
            # quoted argv: it is informational and must not become an argument.
            local local_cmd=(git branch -d -- "$br")
            printf '  %s   # class=%s\n' "$(quote_argv "${local_cmd[@]}")" "$cls"
            # ⛔ THE FORCE-DELETE FALLBACK IS ADVERTISED IN THE PLAN FOR
            # `merged` — BUT ONLY WHEN `-d` WILL ACTUALLY REFUSE (F9), AND AS A
            # COMMENT, NEVER AS A SECOND COMMAND (F17). Omitting it entirely
            # made the plan a LIE for a squash-merged branch (the execute path
            # silently fell back). Printing it UNCONDITIONALLY made the plan a
            # strict SUPERSET for a branch merged with a MERGE COMMIT (or
            # fast-forwarded): the merged gate proves the PR's CONTENT landed and
            # the tip equalled headRefOid — it does NOT prove the tip is a
            # NON-ancestor of main. Such a tip IS an ancestor, so the execute
            # path's `git branch -d` SUCCEEDS and the fallback never runs; the
            # extra printed line then ran `git branch -D -- m-anc` (the pre-F12
            # form) → `error: branch 'm-anc' not found`, and under `set -e` that
            # aborted the rest of the paste — an UNDER-reap. So predict the SAME
            # test the outcome will apply: is the tip an ancestor of the ref `-d`
            # compares against? Ancestor → `-d` succeeds, print NO fallback;
            # not-an-ancestor → print the fallback as a COMMENT, through the
            # SAME `quote_argv`, annotated OUTSIDE the quoted argv.
            # ⛔ AND IT MUST PREDICT THE SAME REF `-d` WILL TEST (F11). `git
            # branch -d` tests the branch's UPSTREAM when it has one, and only
            # falls back to HEAD otherwise — NOT `origin/main`. Predicating on
            # `origin/main` mispredicted in BOTH directions: with a merge-commit
            # branch and HEAD off main it printed only `-d` while execute ran
            # the fallback (UNDER-describes), and with a branch tracking origin
            # it printed a spurious fallback while execute ran only `-d`
            # (OVER-describes). So resolve the comparison ref as
            # `<br>@{upstream}` when configured, else HEAD, and test ancestry
            # against EXACTLY that.
            if [ "$cls" = "merged" ]; then
                local dry_needs_force=0 dry_reason="" dry_tip="" dry_cmp_ref=""
                dry_tip="$(git rev-parse --verify -q "refs/heads/$br" 2>/dev/null || true)"
                if [ -z "$dry_tip" ]; then
                    # ⛔ Tip unresolvable at plan time (F14). The fallback is
                    # advertised as a COMMENT with a CONDITIONAL annotation, not
                    # suppressed, and NOT with the unqualified
                    # "(fallback if -d refuses)" used when the tip IS resolvable:
                    #   * `update-ref -d <ref> <old>` refuses unless the ref is
                    #     still exactly the classified tip, so pasting it can
                    #     never force-delete anything — the command is safe by
                    #     construction; and
                    #   * the annotation is literally accurate: execution reports
                    #     `moved` and does NOT run the fallback while the tip is
                    #     unresolved, and it would run it only if the ref
                    #     reappeared at exactly <sha>. Suppressing the line would
                    #     risk UNDER-advertising a delete execution may still
                    #     perform in that case.
                    # ⛔ EXCEPT when the CLASSIFIED tip itself is empty (F15).
                    # An empty <old> makes `update-ref -d` delete UNCONDITIONALLY,
                    # so pasting the advertised line would be a force-delete that
                    # is safe by NOTHING — and execution now refuses exactly that
                    # swap, so the plan must not advertise it either (the
                    # `[ -n "$sha" ]` on the print below).
                    dry_needs_force=1
                    dry_reason="only if the tip is still $sha when this runs (tip unresolvable at plan time), --execute runs:"
                elif [ "$dry_tip" != "$sha" ]; then
                    # Tip MOVED since classification: the execute gate's
                    # compare-and-swap will REFUSE the fallback, so the plan must
                    # not advertise one (F12).
                    dry_needs_force=0
                else
                    # `git branch -d` compares against the branch's configured
                    # upstream if it has one, else HEAD. `--symbolic-full-name`
                    # resolves that name; a failure means no upstream, so HEAD is
                    # the ref `-d` will use.
                    if dry_cmp_ref="$(git rev-parse --abbrev-ref --symbolic-full-name "$br@{upstream}" 2>/dev/null)"; then
                        :
                    else
                        dry_cmp_ref="HEAD"
                    fi
                    if git rev-parse --verify -q "$dry_cmp_ref" >/dev/null 2>&1 \
                        && git merge-base --is-ancestor "$dry_tip" "$dry_cmp_ref" 2>/dev/null; then
                        dry_needs_force=0
                    else
                        # Either the comparison ref does not resolve, or the tip
                        # is not merged into it: print the fallback. The
                        # annotation says certainty was not established rather
                        # than implying it.
                        dry_needs_force=1
                        dry_reason="if that refuses (squash-merged), --execute runs:"
                    fi
                fi
                if [ "$dry_needs_force" = 1 ] && [ -n "$sha" ]; then
                    # ⛔ THE FALLBACK IS PRINTED AS A COMMENT, NEVER AS A SECOND
                    # COMMAND (F17). It IS the SAME atomically-checked swap the
                    # execute path runs (`git update-ref -d <ref> <old>`), and
                    # its old-value argument makes the pasted command safe on its
                    # own — git refuses and deletes nothing once the tip has
                    # moved. But for a SQUASH-merged branch — the only shape this
                    # fallback exists for, because a squash tip is not an
                    # ancestor of main — the `-d` line above REFUSES. Printing
                    # the fallback as a SECOND executable line therefore made the
                    # plan advertise TWO commands where execution runs ONE, and a
                    # verbatim paste under `set -e` ran the failing `-d` first and
                    # ABORTED, reaping nothing. A comment cannot abort a paste,
                    # and it cannot be pasted into running something execution
                    # would refuse: a `git branch -d -- b || git update-ref -d …`
                    # one-liner would run the fallback for a branch that became
                    # CHECKED OUT and dangle HEAD, whereas the execute path’s
                    # worktree guard refuses that. So `-d` is the executable part
                    # and the fallback is information, rendered through the SAME
                    # `quote_argv` (it re-parses to the executed argv) with the
                    # conditional reason preserved.
                    local local_cmd_force=(git update-ref -d "refs/heads/$br" "$sha")
                    printf '  #   %s\n' "$dry_reason"
                    printf '  #   %s   [tip must still be %s; checked-out branches are refused]\n' \
                        "$(quote_argv "${local_cmd_force[@]}")" "$sha"
                fi
            fi
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
        if [ "$moved" -gt 0 ]; then
            echo "  Moved:     $moved (tip moved before delete; not force-deleted)"
        fi
    else
        echo "  Deleted:   0 (dry-run)"
        echo "  Failed:    0 (dry-run)"
    fi
    echo "  Kept:      $keep_total (worktree: $keep_worktree, main: $keep_main, open-pr: $keep_openpr, not-stale: $keep_notstale, merged-tip-moved: $keep_tipmoved, merged-base-not-main: $keep_offbase, non-origin-upstream: $keep_nonorigin, localonly: $keep_localonly)"
    echo ""

    # ⛔ The `Failed:` count is not decorative. `--help` promises the exit status
    # means "everything selected was reaped", and the status is the ONLY signal a
    # scheduler reads. A per-branch `git branch -d` that legitimately refuses was
    # reported and then discarded by `return 0`, so `--scope both` could report
    # success while a selected local branch was never reaped (under-deletion —
    # the branch is still there, so it is recoverable, but the sweep lied about
    # completing). Fail the pass whenever a selected branch was left behind; the
    # per-branch lines remain so the operator sees WHICH one.
    if [ "$EXECUTE" = true ] && { [ "$failed" -gt 0 ] || [ "$moved" -gt 0 ]; }; then
        if [ "$moved" -gt 0 ]; then
            echo "ERROR: $moved local branch(es) MOVED under the sweep: the classified tip was no longer current," >&2
            echo "ERROR: so the force-delete was REFUSED (a moved tip is never proven merged)." >&2
        fi
        if [ "$failed" -gt 0 ]; then
            echo "ERROR: $failed local branch delete(s) FAILED: a selected branch was not reaped." >&2
        fi
        echo "ERROR: The exit status means 'everything selected was reaped', so the sweep does NOT report success." >&2
        return 1
    fi

    return 0
}

# ── Dispatch ──────────────────────────────────────────────────────
run_scopes() {
    case "$SCOPE" in
        remote) run_remote_scope ;;
        local)  run_local_scope ;;
        both)
            # ⛔ Both legs must RUN. The status MUST be propagated explicitly,
            # because under the opt-in log path the whole pass runs inside
            # `set +e` (so PIPESTATUS can be read), and a bare `run_remote_scope`
            # returning 1 would be followed by `run_local_scope`, whose 0 then
            # becomes PIPESTATUS[0] — a REFUSED remote sweep reported as success
            # (exit 0).
            # ⛔ F37: `run_remote_scope || rc=1` — the `||` on the NEXT line -
            # ALSO suppresses errexit for the WHOLE `run_remote_scope` body, log or
            # no log, because a function that is the LEFT OPERAND of `||` runs with
            # errexit disabled for its entire body (measured: with the F35 guard
            # removed, `--scope both` and no log, a failing `sort` did not abort and
            # the sweep reported a clean pass). The remote scope must therefore
            # status-check every input EXPLICITLY and may never lean on `set -e` as
            # a backstop; the F35 ordering guard is the ONLY protection against a
            # false pass there, which is why it must fail closed in every mode.
            # ⛔ The two legs are INDEPENDENT: a refused remote sweep says nothing
            # about the local one, and `--help` promises "remote, then local".
            # Short-circuiting with `run_remote_scope || return 1` silently
            # skipped every local deletion whenever the remote leg refused
            # (under-deletion, but a surprise). Run BOTH and OR their statuses so
            # a refusal in either leg reaches the exit code without cancelling
            # the other leg's work.
            local rc=0
            run_remote_scope || rc=1
            run_local_scope || rc=1
            return "$rc"
            ;;
    esac
}

# ── opt-in capped report log (see the header) ─────────────────────
# Reset BEFORE a pass once the file has outgrown the cap, so the log holds the
# most recent passes and cannot grow without bound. `wc -c` (not `stat -f`)
# keeps this cross-platform.
#
# ⛔ RESET VIA `mktemp` + `mv`, NOT `: >"$f"` (symlink safety). Every one of
# `[ -e ]`, `wc -c <` and `: >` FOLLOWS a symlink, and CLEANUP_BRANCH_LOG is a
# fixed, predictable path (`~/.pi/agent/state/cleanup-stale-branches.log` in the
# shipped plist), so `: >"$f"` on an over-cap symlink would silently destroy the
# link's target (a shared log file, or one a local attacker pre-seeded). `mv`
# REPLACES the symlink with the fresh file instead of writing through it — the
# same defence pi-reap-idle.sh uses. A mktemp that cannot be created (read-only
# directory) skips the reset: the log grows rather than a file being destroyed.
cap_report_log() {
    local f="$1" max="$2" size dir tmp
    [ -e "$f" ] || return 0
    size="$(wc -c <"$f" 2>/dev/null | tr -d '[:space:]')" || return 0
    case "$size" in ''|*[!0-9]*) return 0 ;; esac
    if [ "$size" -ge "$max" ]; then
        dir="$(dirname -- "$f")"
        if tmp="$(mktemp "$dir/pi-cleanup-log-trunc.XXXXXX" 2>/dev/null)"; then
            if ! mv -f -- "$tmp" "$f" 2>/dev/null; then
                rm -f -- "$tmp" 2>/dev/null || true
            fi
        fi
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
