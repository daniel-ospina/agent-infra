#!/usr/bin/env bash
# scan-orphans.sh — flag and (with --apply) remove worktrees/branches left by
# aborted dispatches (issue #195). The teardown manifest written by
# scripts/record-worktree.sh is the source of truth; classification:
#
#   ORPHANED (safe to remove)  — recorded, record stale (older than the cutoff),
#                                branch local-only (never pushed), worktree clean
#                                (or absent)
#   ORPHANED BUT DIRTY         — same, but the tree's state is NOT clean: it has
#                                uncommitted changes, or its state could not be
#                                READ at all (`unmeasurable`), or the recorded dir
#                                exists without being a registered worktree
#                                (--apply refuses all three without --force-dirty,
#                                and refuses the unregistered one even WITH it)
#   RECENT                     — recorded but not yet stale (still tracked)
#   LIVE                       — branch exists on origin (real work, never touched)
#   GHOST RECORDS              — recorded but branch/dir never existed (pruned)
#   UNRECORDED                 — worktree/branch exists without a record
#                                (informational — --apply NEVER touches these)
#
# Notification-first: dry-run by default. --apply removes confirmed orphans +
# prunes their records. NEVER deletes remote branches or force-pushes.
#
# ── ⛔ THE DESTRUCTIVE GATES (#1393) ─────────────────────────────────────────
# #1393 is the fleet's one recorded instance of *silent destruction of work*: a LIVE worktree and its
# branch were deleted mid-session and the uncommitted work in it existed nowhere else. The report's
# requested outcome (2) — "refuse worktree/branch deletion when the worktree is dirty" — is the rule
# below. This script is the last reaper on the box that could still destroy uncommitted work, and it
# did so on FOUR paths, each closed here:
#
#   G1  A FAILED MEASUREMENT IS NOT A CLEAN TREE. `git -C <dir> status --porcelain` exits 128 (and
#       prints nothing) whenever <dir> is not a readable checkout — a directory that is not a git
#       worktree at all, or a linked worktree whose `.git/worktrees/<name>` admin dir was pruned
#       (measured: `fatal: not a git repository`). The old `worktree_clean()` read that EMPTY OUTPUT
#       as "clean", so "I could not look" became "there is nothing there" — the fail-open shape the
#       Product-Over-Process rule classes A. State is now one of `absent | clean | dirty |
#       unmeasurable`, and `unmeasurable` is preserved exactly like `dirty`.
#       ⛔ AND `absent` IS DECIDED BY EVIDENCE TOO (#3799 review, Findings 2 and round-2 1). It used
#       to be `[ -d ]`, which is false for ANY stat failure — EACCES on an unreadable parent,
#       ENOTDIR, ELOOP, ESTALE on a dropped mount — so an unreachable tree read as "gone" and its ref
#       was deleted while the tree sat on disk. `path_absent()` walks UP to a parent it can SEARCH;
#       a stat of a child needs search (`x`) permission on its parent, so a searchable parent plus a
#       failed stat on the name is ENOENT. An unsearchable parent proves nothing, so its own absence
#       is what gets established next. ⛔ SEARCHABLE, NOT LISTABLE: `ls -A` succeeds on READ alone,
#       and a `444` ancestor is listable while its children are unstatable — that inference (the
#       first attempt at this fix) deleted the ref of a tree that was sitting right there, which is
#       why the listing is now only a CROSS-CHECK (name visible + stat failed ⇒ cannot decide) and
#       not the licence. Anything undecidable is `unmeasurable`, never `absent`. The same test
#       decides GHOST, so an unreachable tree's record is not pruned as "never existed".
#
#   G2  THE DIRT CHECK WAS GATED ON REGISTRATION. It only ran when git still confirmed the dir was a
#       registered worktree of THIS repo — so a record whose registration was pruned (precisely what
#       #1393 observed: `.git/worktrees/` had no entry for it) skipped the check entirely and landed
#       in "safe to remove". Every existing dir is now measured, registered or not.
#
#   G3  `git branch -D` IS AN UNCOMPARED DELETE. It removes whatever the ref points at NOW, and it
#       runs on a value read a moment earlier — so a tip that moved in that window (another lane
#       committing) is destroyed with no record. Every other reaper in this repo deletes a branch
#       with `git update-ref -d <ref> <expected-oid>` (`orchestrator-harness/wt-lifecycle.sh`,
#       `pi-reap-worktrees.sh`, `cleanup-stale-branches.sh`); this one now matches. A refused CAS
#       (moved tip, held lock) KEEPS the record and says so.
#       ⛔ AND THE CAS IS ONLY HALF OF WHY THE SIBLING IS SAFE (#3799 review, Finding 1). `-D` was
#       ALSO carrying git's CHECKED-OUT refusal, which `update-ref -d` does not have: measured on git
#       2.43, `-D` answered `cannot delete branch … used by worktree at …` (rc 1) while
#       `update-ref -d` returned 0 and left that live lane on an UNBORN branch with the ref's reflog
#       gone. Reachable here without contrivance: a record's `worktree` is an absolute path and the
#       record file is per-USER, not per-box, so `dir=/old/path` (gone) + the branch checked out at a
#       live `/new/path` (a lane that recreated its worktree, or two stale records for one branch)
#       reaches the swap. The refusal is therefore re-asserted from a FRESH
#       `git worktree list --porcelain` immediately before the swap, and a FAILED enumeration is a
#       refusal — never an assumed "not checked out" (the sibling's shape,
#       `cleanup-stale-branches.sh:2073-2099`). ⛔ AND EVERY REFUSAL NAMES ITS OWN CAUSE (round-2
#       Finding 2): one shared message said "the tip moved, or the ref is locked" even when the
#       CHECKED-OUT guard was what fired, so the operator was told to hunt a competing committer
#       instead of being told the branch belongs to a live lane — on a destructive path the message
#       is the diagnosis the next actor inherits, so it names the worktree holding the branch.
#
#   G4  THE REF WAS DELETED EVEN WHEN THE TREE SURVIVED. The old --apply deleted the branch no
#       matter what happened to the directory — including the `dir is not a registered worktree`
#       arm, which deliberately leaves the tree in place. A surviving tree may hold the only
#       uncommitted copy of what that ref points at, and for an unregistered tree we cannot even
#       read its state. So the ref is deleted ONLY once the directory is provably gone; otherwise
#       both are kept and the record is kept so the next pass re-reports it.
#       ⛔ "PROVABLY GONE" IS THE DIRECTORY, AND THE REGISTRATION IS NOT PROOF EITHER WAY (round-6 F1,
#       measured on git 2.43; this supersedes the round-4 text that used to live here). A worktree
#       directory removed with `rm -rf` — and ALSO one MOVED with a raw `mv` — leaves the same
#       REGISTRATION behind, which `git worktree list --porcelain` keeps reporting at the OLD path,
#       flagged `prunable`. git cannot tell the two apart, and they are not symmetric: clearing a
#       stale registration saves an operator one registration cleanup, while clearing a moved one
#       SEVERS A LIVE LANE — `git worktree remove --force` returns 0 and the lane's `git status`
#       then fails rc=128 (`not a git repository: …/.git/worktrees/<name>`), its unpushed commit
#       goes unreachable, and the pruned record means nothing re-reports it. So the `absent` arm
#       does NOT deregister, and the checked-out guard treats a `prunable`/absent-path entry as
#       AMBIGUOUS: it keeps the ref, the record and the tree state, and tells the operator to LOOK
#       FOR THE TREE FIRST (`.git/worktrees/<name>/gitdir` names the path it expects, and
#       `git worktree repair <new path>` is the moved case's remedy), clearing a registration only
#       when its tree is genuinely gone and only that one path-scoped via `git worktree remove
#       --force <path>`. ⛔ NEVER `git worktree prune`: this repo forbids it (#1141) — it has no
#       path filter, so it deregisters EVERY worktree whose directory is missing, and on the moved
#       case it destroys the recovery the operator was about to perform. A `locked`
#       entry is live even when its directory is gone, because `git branch -D` refuses it too. A
#       worktree that might still exist — `unmeasurable` — still refuses.
#
#   G5  (in-window) The classification's `clean` read describes a moment that has PASSED by the time
#       --apply acts, and `git worktree remove --force` does not refuse — `--force` suppresses git's
#       own dirty guard, which is the only guard left. So the state is re-measured IMMEDIATELY before
#       the removal and a tree that changed since classification is kept (the #1105 window shape).
#       ⛔ AND THE POST-FAILURE TEST IS THE SAME QUESTION (round-3 F1). A failed `worktree remove`
#       followed by a bare `[ -e "$dir" ]` is the third instance of "a failed stat is not absence":
#       a directory that lost its `x` parent, or sits on a dropped mount, INSIDE that window reads
#       as gone and its only ref is deleted. It asks `worktree_state` too, so `absent` is still
#       decided on evidence.
#
# ⛔ WHAT --force-dirty DOES AND DOES NOT AUTHORIZE. It authorizes destroying UNCOMMITTED WORK in a
# registered worktree — that is the documented cost of the flag and the operator asked for it. It
# does NOT authorize removing a directory git does not vouch for (an unregistered dir is left alone,
# with its branch, and the record is kept for a human), it does not authorize removing a tree whose
# state could not be READ (`unmeasurable` is "unknown", not "the cost you agreed to"), and it does
# not bypass G3/G4.
#
# ⚠️ STILL NOT CHECKED, said plainly: `git worktree remove --force` also deletes IGNORED
# (`!!`) entries, and `git status --porcelain` cannot see them. That gap is a DIFFERENT root with its
# own issue (#1141 records it; `scripts/stale-worktrees.sh` and `scripts/cleanup-worktree.sh` carry
# the `--ignored=traditional` arm that closes it locally). It is not closed here.
#
# Usage:
#   bash scripts/scan-orphans.sh [--apply] [--force-dirty] [--cutoff N] [--repo /path]
#   WORKTREES_RECORD=... bash scripts/scan-orphans.sh   (tests: isolate the record)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPLY=false
FORCE_DIRTY=false
CUTOFF_HOURS=24
REPO_ROOT=""
RECORD_FILE="${WORKTREES_RECORD:-$HOME/.pi/agent/worktrees.jsonl}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --apply) APPLY=true; shift ;;
        --force-dirty) FORCE_DIRTY=true; shift ;;
        --cutoff) CUTOFF_HOURS="$2"; shift 2 ;;
        --repo) REPO_ROOT="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: bash scripts/scan-orphans.sh [--apply] [--force-dirty] [--cutoff N] [--repo /path]"
            exit 0 ;;
        *) echo "Unknown arg: $1 (use --help)" >&2; exit 1 ;;
    esac
done

if ! [[ "$CUTOFF_HOURS" =~ ^[0-9]+$ ]] || [ "$CUTOFF_HOURS" -lt 1 ]; then
    echo "ERROR: --cutoff must be a positive integer (hours)" >&2; exit 1
fi
[ -z "$REPO_ROOT" ] && REPO_ROOT="$(pwd)"
cd "$REPO_ROOT"

# ── Helpers ────────────────────────────────────────────────────
now_epoch() { date +%s; }
ts_epoch() { # <ISO8601> → epoch (GNU or BSD date)
    local t="$1"
    date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$t" +%s 2>/dev/null || date -d "$t" +%s 2>/dev/null || echo 0
}
branch_local() { git show-ref --verify --quiet "refs/heads/$1" 2>/dev/null; }
branch_remote() { git show-ref --verify --quiet "refs/remotes/origin/$1" 2>/dev/null; }
branch_tip() { git rev-parse --verify --quiet "refs/heads/$1^{commit}" 2>/dev/null; }

# path_there <path> — the entry exists as SOMETHING (dir, file, or a symlink however broken).
# `[ -e ]` alone is not that test: it is FALSE for a dangling symlink, and false again for any stat
# failure (Finding 2 of the #3799 review).
path_there() { [ -e "$1" ] || [ -L "$1" ]; }

# path_absent <path> — 0 ONLY on positive evidence of non-existence (#3799 review, Findings 2 and
# round-2 Finding 1).
# ⛔ `[ -d "$p" ]` IS NOT AN ABSENT TEST. It is false for ANY stat failure — EACCES on an unreadable
# parent, ENOTDIR, ELOOP, ESTALE on a dropped network mount — and treating that as "nothing is there"
# is the same "I could not look => there is nothing there" reasoning G1 removes, one layer earlier:
# the ref would be deleted while the tree it belongs to is still on disk. So walk UP to a parent we
# can SEARCH; a stat of a child needs only search (`x`) permission on its parent, so with a
# searchable parent a failed stat on the name means the name is not there. An unsearchable parent
# proves nothing about itself, so its own absence (recursively) is the next thing to establish.
# ⛔ SEARCHABLE, NOT LISTABLE (round-2 Finding 1, measured). `ls -A` succeeds on **read** permission
# alone, and a `444` (or `chmod a-x`, or `r`-without-`x` ACL) parent is listable while its children
# are UNSTATABLE — so "listable" concluded ENOENT for a tree that was sitting right there, and the
# ref was deleted under it. `[ -x ]` is the permission that actually licenses the inference. The
# listing is kept only as a CROSS-CHECK: where it is readable and the name is right there, the stat
# failure is something else (ESTALE on a dropped mount answers readdir while failing stat) and the
# answer is "cannot decide".
path_absent() {
    local p="$1" parent base listing
    case "$p" in /*) ;; *) p="$PWD/$p" ;; esac
    while :; do case "$p" in */) p="${p%/}" ;; *) break ;; esac; done
    [ -n "$p" ] || return 1
    while :; do
        path_there "$p" && return 1          # reachable: not absent
        parent="$(dirname -- "$p")"
        [ "$parent" = "$p" ] && return 1     # walked to "/" and still unreachable: cannot decide
        if [ -x "$parent" ]; then            # SEARCHABLE => a failed stat of the child is ENOENT
            base="$(basename -- "$p")"
            if listing="$(ls -A -- "$parent" 2>/dev/null)"; then
                # readable as well: if the name IS in the listing while stat failed, something other
                # than ENOENT is going on and we cannot decide.
                # ⛔ NOT `printf … | grep -q`: under `pipefail` a `grep -q` exits at the first
                # match and the writer takes SIGPIPE, so the pipeline reports 141 and the guard
                # reads as a FALSE NEGATIVE (scripts/check-no-sigpipe-grep.sh, #841/#864). The
                # here-string form feeds the same lines with no pipe to break.
                if grep -qxF -- "$base" <<<"$listing"; then return 1; fi
            fi
            return 0
        fi
        p="$parent"                           # parent unsearchable: its absence would prove ours
    done
}

# worktree_state <dir> -> absent | clean | dirty | unmeasurable
# ⛔ A FAILED MEASUREMENT IS NEVER `clean` (#1393 G1). `git status` exits non-zero and prints nothing
# when <dir> is not a readable checkout (a plain directory, or a linked worktree whose
# `.git/worktrees/<name>` admin dir was pruned), and reading that empty output as "clean" turns
# "I could not look" into "there is nothing there". The exit status decides, never the output.
# ⛔ AND `absent` IS DECIDED BY EVIDENCE, NOT BY A FAILED STAT (#3799 review, Finding 2).
worktree_state() {
    local dir="$1" out rc=0
    [ -n "$dir" ] || { printf 'absent'; return 0; }
    if ! path_there "$dir"; then
        if path_absent "$dir"; then printf 'absent'; else printf 'unmeasurable'; fi
        return 0
    fi
    out="$(git -C "$dir" status --porcelain 2>/dev/null)" || rc=$?
    if [ "$rc" -ne 0 ]; then printf 'unmeasurable'; return 0; fi
    if [ -n "$out" ]; then printf 'dirty'; else printf 'clean'; fi
    return 0
}

# ambiguous_remedy — the ONE definition of the operator's next action for a registration that still
# claims a branch whose directory is gone. Used by BOTH the classifier's DIRTY line and
# delete_branch_cas's refusal (round-9 F2): the classifier is what a plain `--apply` prints, so the
# remedy must not be reachable only behind `--force-dirty` — the two sentences drifted apart once and
# the plain run withheld exactly the two that stop an operator clearing a MOVED lane's registration.
ambiguous_remedy() {
    printf '%s' "Look for the tree BEFORE clearing anything: .git/worktrees/<name>/gitdir names the path it expects, and 'git worktree repair <new path>' recovers a moved one. Clear a registration only when its tree is genuinely gone, and only THAT one, path-scoped: 'git worktree remove --force <path>'. ⛔ Once the registration is cleared the next --apply WILL reclaim the ref, so do not clear it until you are sure."
}

# delete_branch_cas <branch> <expected-oid> — atomic compare-and-delete, NEVER `git branch -D`
# (#1393 G3). `update-ref -d <ref> <old>` has GIT compare the ref's current value to <old> and remove
# it in the SAME operation, so a tip that moved between classification and delete is refused rather
# than destroyed. An empty <old> is an UNCONDITIONAL delete (verified, git 2.43 and re-measured in
# round 2), so a tip that could not be read refuses instead of degrading to one. `update-ref -d`
# leaves `branch.<name>.*` config behind where `-D` would drop it, so that is removed explicitly.
#
# ⛔ `update-ref -d` IS NOT `git branch -D`, SO IT DOES NOT INHERIT -D's CHECKED-OUT REFUSAL
# (#3799 review, Finding 1 — measured on git 2.43: `-D` refused "used by worktree at …", `update-ref -d`
# returned 0 and left that worktree on an UNBORN branch with the ref's reflog gone). -D was carrying a
# guard the swap does not, so the guard is re-asserted here, from a FRESH enumeration immediately
# before the swap — the branch could have been checked out in the window since classification. A
# FAILED enumeration is a REFUSAL, never an assumed "not checked out". This is the sibling reaper's
# shape (`cleanup-stale-branches.sh:2073-2099`).
#
# ⛔ EVERY REFUSAL NAMES ITS OWN CAUSE (round-2 Finding 2, measured). One shared message ("the tip
# moved, or the ref is locked") told the operator two causes that were NOT the cause when the guard
# that fired was the CHECKED-OUT one — on a destructive path the message IS the diagnosis the next
# actor inherits, and "this branch belongs to a live lane" is the one thing it must say.
#
# Returns: 0 deleted (or already gone) · 1 the classified tip was unreadable · 2 the branch is
# CHECKED OUT in a live worktree · 3 the CAS was refused / the worktree list was unreadable.
# On non-zero, $DCAS_REASON carries the sentence reap_record prints.
delete_branch_cas() {
    local br="$1" oid="$2" wt_now="" wt_hits="" wt_live="" wt_locked="" wt_stale="" p pr lk
    DCAS_REASON=""
    branch_local "$br" || return 0          # already gone — nothing to delete, nothing lost
    if [ -z "$oid" ]; then
        DCAS_REASON="its classified tip could not be read (<unread-tip>), and an empty <old> turns 'update-ref -d' into an UNCONDITIONAL delete"
        return 1
    fi
    if ! wt_now="$(git worktree list --porcelain 2>/dev/null)"; then
        DCAS_REASON="the worktree list could not be read, so 'not checked out anywhere' cannot be established"
        return 3
    fi
    # The path is parsed per line, so command substitution's stripped trailing newlines cannot hide
    # the LAST entry of the listing (a `case` over the whole string needed two patterns for that).
    # ⛔ EVERY MATCHING ENTRY IS EXAMINED, NOT JUST THE FIRST (round-6 F3). `git worktree add --force
    # <path> <branch>` really does register TWO worktrees on one branch (measured rc=0), so exiting
    # on the first block let a live second entry go unseen behind a stale first one.
    # ⛔ AND A `prunable` OR ABSENT-PATH ENTRY IS *NOT* PROOF THE LANE IS DEAD (round-6 F1, measured
    # on git 2.43). Deleting a worktree directory and MOVING one with a raw `mv` leave the SAME
    # `prunable gitdir file points to non-existent location` entry at the OLD path — while a moved
    # lane is fully live at its new path (`git -C <new> status` rc=0). git cannot tell these apart,
    # and the two outcomes are not symmetric: clearing a stale registration saves effort, while
    # clearing a moved one severs a live lane (its `status` then fails rc=128 with
    # "not a git repository: …/.git/worktrees/<name>") and makes its unpushed commit unreachable.
    # Category A beats the friction, so this refuses BOTH and names the explicit remedy.
    # ⛔ A `locked` WORKTREE IS LIVE EVEN WHEN ITS DIRECTORY IS GONE (round-6 F2). `lock` exists for
    # trees that may be moved or offline, and the listing shows `locked` with no `prunable` line.
    # `git branch -D` REFUSES these and this repo preserves them (`pi-reap-worktrees.sh` emits
    # `preserve worktree-locked`), so deleting the ref here would be strictly broader than the call
    # being replaced. The `locked` flag also arrives AFTER `branch`, so it is read at block end.
    wt_hits="$(printf '%s\n' "$wt_now" | awk -v b="refs/heads/$br" '
        /^worktree / { p = substr($0, 10); pr = 0; lk = 0; hit = 0 }
        /^prunable/  { pr = 1 }
        /^locked/    { lk = 1 }
        /^branch /   { if (substr($0, 8) == b) hit = 1 }
        /^[[:space:]]*$/ { if (hit) print p "\t" pr "\t" lk; p = ""; pr = 0; lk = 0; hit = 0 }
        END { if (hit) print p "\t" pr "\t" lk }')"
    if [ -n "$wt_hits" ]; then
        while IFS=$'\t' read -r p pr lk; do
            [ -n "$p" ] || continue
            if [ "$lk" = 1 ]; then
                wt_locked="${wt_locked:-$p}"
            elif path_absent "$p"; then
                # ⛔ THE EVIDENCE IS `path_absent`, NOT THE `prunable` FLAG (round-8 F1). `prunable`
                # fires while the DIRECTORY IS PRESENT — removing just its `.git` file does it —
                # and the stale arm then told the operator "that directory is gone" about a
                # directory that is right there, prescribing a `worktree remove --force` that
                # fails rc=128 in that state. Asking the path instead sends that case to the
                # `wt_live` arm, which refuses with the accurate diagnosis.
                wt_stale="${wt_stale:-$p}"
            else
                wt_live="${wt_live:-$p}"
            fi
        done <<<"$wt_hits"
        if [ -n "$wt_live" ]; then
            DCAS_REASON="it is CHECKED OUT in a live worktree ($wt_live), and deleting the ref would leave that lane on an unborn branch"
            return 2
        fi
        if [ -n "$wt_locked" ]; then
            DCAS_REASON="it is CHECKED OUT in a LOCKED worktree ($wt_locked), and a lock exists to protect a tree that may be moved or offline — a plain branch delete refuses this too"
            return 2
        fi
        if [ -n "$wt_stale" ]; then
            DCAS_REASON="a worktree registration ($wt_stale) still claims it while that directory is gone — git cannot tell a STALE registration from a worktree MOVED with 'mv', and the moved case is a live lane, so the ref is kept. $(ambiguous_remedy)"
            return 2
        fi
    fi
    if ! git update-ref -d "refs/heads/$br" "$oid" 2>/dev/null; then
        DCAS_REASON="the compare-and-delete at $oid was refused — the tip moved since classification, or the ref is locked"
        return 3
    fi
    git config --remove-section "branch.$br" 2>/dev/null || true
    return 0
}

# reap_record <branch> <dir> <dispatch> <is_registered_worktree> <forced> <reg_claims>
# Prints one `     …` outcome line per decision. Returns 0 only when the record may be PRUNED, i.e.
# the directory is provably gone AND the branch ref is gone; 1 when anything was kept (#1393 G4).
# <reg_claims> is true|false|unknown — `unknown` means the worktree list could not be READ, which is
# a different cause from "no registration claims it" and must not be reported as one (round-11 F1).
reap_record() {
    local br="$1" dir="$2" dispatch="$3" is_wt="$4" forced="$5" reg_claims="${6:-false}" oid st dcas=0

    oid="$(branch_tip "$br")" || oid=""

    if [ -n "$dir" ]; then
        # ⛔ MEASURED HERE, AT THE REMOVAL WINDOW — not inherited from classification (#1393 G5). The
        # classification's read describes a moment that has already passed by the time --apply acts,
        # and the `--force` below suppresses git's own dirty guard, which is the only guard left.
        st="$(worktree_state "$dir")"
        case "$st" in
            absent)
                # ⛔ DO NOT DEREGISTER HERE (round-6 F1, measured on git 2.43 — this reverses the
                # round-4 fix, which destroyed work). The directory is provably gone, but its STILL-
                # REGISTERED worktree entry is ambiguous: `rm -rf` of a worktree and a raw `mv` of a
                # live one leave the SAME `prunable` entry at the OLD path. `git worktree remove
                # --force` on it returns 0 in BOTH cases — and in the moved case it severs the live
                # lane (`git -C <new path> status` then fails rc=128 "not a git repository:
                # …/.git/worktrees/<name>") and its unpushed commit goes unreachable, while the
                # record is pruned so nothing re-reports it. That is #1393's own failure class, so
                # the ref is left to `delete_branch_cas`, which refuses an ambiguous registration and
                # tells the operator to look for the tree first rather than guessing.
                : ;;
            unmeasurable)
                printf '%b' "     ⚠️ KEPT tree+ref+record: '${dir}' cannot be reached or read (state 'unmeasurable'), so whether a tree is there — and what is in it — cannot be ruled out.\n"
                return 1 ;;
            *)
                if [ "$is_wt" != true ]; then
                    if [ "$reg_claims" = unknown ]; then
                        printf '%b' "     ⚠️ KEPT tree+ref+record: '${dir}' is '${st}', but the worktree list could not be read — so whether git vouches for it as a worktree of this repo cannot be established, and nothing was removed. This is a READ failure, not a poisoned record: fix 'git worktree list' and re-run rather than clearing the record.\n"
                        return 1
                    fi
                    printf '%b' "     ⚠️ KEPT tree+ref+record: '${dir}' exists but git does not vouch for it as a worktree of this repo, so its contents cannot be reaped safely and this branch may be the only ref to them. Inspect it, then clear the record by hand (record-worktree.sh done --dispatch '${dispatch}').\n"
                    return 1
                fi
                if [ "$st" != clean ] && [ "$forced" != true ]; then
                    printf '%b' "     ⚠️ KEPT tree+ref+record: '${dir}' is '${st}' at the removal window — refusing to remove an uncommitted-work tree without --force-dirty. Re-run once nothing is writing there.\n"
                    return 1
                fi
                if ! git worktree remove --force "$dir" 2>/dev/null; then
                    # ⛔ THE POST-FAILURE TEST IS NOT A BARE `path_there` (round-3 F1, third instance of
                    # the same root): it is FALSE for any stat failure, so a directory that lost its
                    # `x` parent or sits on a dropped mount INSIDE this window would read as "gone"
                    # and the only ref to it would be deleted. Ask the state machine, which decides
                    # `absent` on evidence.
                    st="$(worktree_state "$dir")"
                    if [ "$st" != absent ]; then
                        printf '%b' "     ⚠️ KEPT tree+ref+record: 'git worktree remove' failed and the directory is not provably gone (state '${st}') — the branch is kept because the tree may be the only copy of what it points at.\n"
                        return 1
                    fi
                fi ;;
        esac
    fi

    delete_branch_cas "$br" "$oid" || dcas=$?
    if [ "$dcas" -ne 0 ]; then
        printf '%b' "     ⚠️ KEPT ref+record: 'refs/heads/$br' was NOT deleted — ${DCAS_REASON:-the delete was refused}.\n"
        return 1
    fi
    bash "$SCRIPT_DIR/record-worktree.sh" done --dispatch "$dispatch" --branch "$br" --worktree "$dir" >/dev/null 2>&1 || true
    if [ "$forced" = true ]; then
        printf '%b' "     removed (--force-dirty: uncommitted work was destroyed by request).\n"
    else
        printf '%b' "     removed.\n"
    fi
    return 0
}

CUTOFF_EPOCH=$(( $(now_epoch) - CUTOFF_HOURS * 3600 ))

ORPHANS=0
LIVE=0
RECENT=0
DIRTY=0
GHOSTS=0
UNRECORDED=0
KEPT=0
LIVE_OUT=""
RECENT_OUT=""
GHOST_OUT=""
DIRTY_OUT=""
ORPHAN_OUT=""

echo "=== Orphan scan: $(pwd) (cutoff ${CUTOFF_HOURS}h) $( [ "$APPLY" = true ] && echo '[--apply]' ) ==="

# ── Pass 1: records ────────────────────────────────────────────
RECORDED_DIRS="" # space-separated dir list (bash 3.2 — no associative arrays)
if [ -f "$RECORD_FILE" ]; then
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        BRANCH="$(printf '%s' "$line" | sed -n 's/.*"branch":"\([^"]*\)".*/\1/p')"
        DIR="$(printf '%s' "$line" | sed -n 's/.*"worktree":"\([^"]*\)".*/\1/p')"
        TS="$(printf '%s' "$line" | sed -n 's/.*"ts":"\([^"]*\)".*/\1/p')"
        DISPATCH="$(printf '%s' "$line" | sed -n 's/.*"dispatch":"\([^"]*\)".*/\1/p')"
        [ -n "$BRANCH" ] || continue
        REC_EPOCH="$(ts_epoch "$TS")"
        STALE=false
        [ "$REC_EPOCH" -gt 0 ] && [ "$REC_EPOCH" -lt "$CUTOFF_EPOCH" ] && STALE=true
        [ -n "$DIR" ] && RECORDED_DIRS="$RECORDED_DIRS $DIR"

        # GHOST: neither the branch nor the worktree dir ever existed.
        # ⛔ `[ ! -d ]` IS NOT "never existed" (round-2 Finding 1, same root at a second site): under an
        # r-without-x ancestor an EXISTING dir is unstatable, so a real tree's record was classified
        # "never existed" and PRUNED — erasing the trail for a tree that may hold uncommitted work.
        # GHOST now requires the dir to be PROVABLY absent, not merely unreadable.
        if ! branch_local "$BRANCH" && ! branch_remote "$BRANCH" &&
           [ -n "$DIR" ] && ! path_there "$DIR" && path_absent "$DIR"; then
            GHOSTS=$((GHOSTS + 1))
            GHOST_OUT="${GHOST_OUT}  👻 GHOST RECORDS: branch=$BRANCH dispatch=$DISPATCH (never existed)\n"
            if [ "$APPLY" = true ]; then
                bash "$SCRIPT_DIR/record-worktree.sh" done --dispatch "$DISPATCH" --branch "$BRANCH" --worktree "$DIR" >/dev/null 2>&1 || true
                GHOST_OUT="${GHOST_OUT}     pruned record.\n"
            fi
            continue
        fi

        if branch_remote "$BRANCH"; then
            LIVE=$((LIVE + 1))
            LIVE_OUT="${LIVE_OUT}  🔵 LIVE: branch=$BRANCH (on origin — real work, never touched)\n"
            continue
        fi

        if [ "$STALE" = false ]; then
            RECENT=$((RECENT + 1))
            RECENT_OUT="${RECENT_OUT}  🕐 ── RECENT (recorded, not yet stale — tracked): branch=$BRANCH dir=$DIR\n"
            continue
        fi

        # Stale + local-only: orphan (dirty or clean). SAFETY: a recorded dir
        # only counts as a worktree when git confirms it is registered to THIS
        # repo — a crafted/poisoned record must never turn --apply into an
        # arbitrary-directory rm -rf (review #216).
        IS_WT=false
        WT_LIST=""
        REG_CLAIMS=false
        if [ -n "$DIR" ]; then
            # Canonicalize both sides: macOS /var → /private/var symlink; the
            # porcelain prints realpaths while the record may hold the /var form.
            WT_CANON="$(cd "$DIR" 2>/dev/null && pwd -P || echo "$DIR")"
            # Capture, then classify in the SHELL — never `… | grep -qF`, whose false
            # negative under `pipefail` would make a REGISTERED worktree look
            # unregistered on the destructive --apply path (#864).
            WT_LIST="$(git worktree list --porcelain 2>/dev/null)" || REG_CLAIMS=unknown
            # ⛔ BOTH MATCHES BELOW ARE IDENTITY PINS, AND THE NEWLINE IS APPENDED OUTSIDE `$( )`
            # (#1393 R12-F2). Two independent traps, both measured:
            #
            # (1) PREFIX vs IDENTITY. An unpinned `*"worktree $WT_CANON"*` is a SUBSTRING test, so a
            #     record naming a directory that is a strict prefix of a registered worktree
            #     (`…/fix-801` vs `…/fix-801-slug`) read as REGISTERED — and IS_WT is exactly what
            #     makes the DEFAULT run call it "ORPHANED (safe to remove)", the false PASS the
            #     paragraph below forbids.
            # (2) THE NEWLINE MUST COME FROM OUTSIDE THE SUBSTITUTION. `$(printf '%s\n' "$WT_LIST")`
            #     RE-STRIPS the newline it just added, so that form cannot match any line that is
            #     LAST in the listing. The `branch` line IS last for the final block
            #     (`git worktree list --porcelain` ends `branch …\n\n`, measured), so the
            #     `printf`-inside form silently dropped REG_CLAIMS for the one worktree most likely
            #     to be holding the branch: the dry run printed `ORPHANED (safe to remove)` while the
            #     same sweep reported `KEPT by --apply` — a self-contradicting report, and a false
            #     PASS (the ref itself survived, because `delete_branch_cas` re-enumerates).
            #     `worktree <path>` is never last (HEAD/bare always follows), so one form serves both.
            case "$WT_LIST"$'\n' in
                *"worktree $WT_CANON"$'\n'*) IS_WT=true ;;
            esac
            # ⛔ A FAILED READ IS NOT "NOTHING CLAIMS IT" (round-8 F2, the G1 rule one layer up).
            # `|| true` left REG_CLAIMS=false, so a record `--apply` refuses (because the list could
            # not be read) was advertised by the DRY run as "ORPHANED (safe to remove)". The
            # classifier must agree with the destruction path — that is round-3 F3's rule, applied
            # to the read that can also fail.
            # Trailing newline pinned so `refs/heads/t` cannot match `refs/heads/t/sub` — and
            # appended OUTSIDE `$( )` for the reason spelled out above: the `printf`-inside form
            # re-strips its own newline and then misses the LAST block's `branch` line.
            case "$WT_LIST"$'\n' in
                *"branch refs/heads/$BRANCH"$'\n'*) REG_CLAIMS=true ;;
            esac
        fi
        # ⛔ Dirt is measured for EVERY existing directory, whether or not git still registers it as
        # a worktree of this repo (#1393 G2). A record whose `.git/worktrees/<name>` admin dir was
        # pruned — exactly what #1393 observed — used to skip the check entirely and be classed
        # "safe to remove". `worktree_state` never infers `clean` from a failed read (#1393 G1).
        WT_STATE="$(worktree_state "$DIR")"
        DIRTY_B=0
        case "$WT_STATE" in
            # ⛔ ABSENT IS ONLY "SAFE TO REMOVE" WHEN NOTHING STILL CLAIMS THE BRANCH (round-7 F2).
            # A surviving registration means stale-or-moved, which `--apply` refuses.
            absent) case "$REG_CLAIMS" in true|unknown) DIRTY_B=1 ;; *) DIRTY_B=0 ;; esac ;;
            # ⛔ AN EXISTING DIRECTORY GIT DOES NOT VOUCH FOR IS NOT "safe to remove" (round-3 F3).
            # `--apply` refuses it (the `is_wt` arm), but the DEFAULT run — the one an operator and
            # `extensions/auto-sync.ts` actually read — printed it as ORPHANED and said nothing to
            # contradict that. The classification has to agree with the destruction path.
            clean) [ "$IS_WT" = true ] && DIRTY_B=0 || DIRTY_B=1 ;;
            *) DIRTY_B=1 ;;
        esac
        if [ "$DIRTY_B" = 1 ]; then
            DIRTY=$((DIRTY + 1))
            case "$WT_STATE" in
                unmeasurable)
                    DIRTY_OUT="${DIRTY_OUT}  ⚠️  ORPHANED BUT DIRTY: branch=$BRANCH dir=$DIR — state UNMEASURABLE, not a readable checkout, so uncommitted work there cannot be ruled out\n" ;;
                clean)
                    if [ "$REG_CLAIMS" = unknown ]; then
                        # ⛔ A FAILED LIST READ IS NOT "git does not vouch for it" (round-11 F1). The
                        # cause is the unreadable listing, not a non-registration, and the two have
                        # different remedies — naming the wrong one told the operator to retire the
                        # trail of a tree git DOES vouch for.
                        DIRTY_OUT="${DIRTY_OUT}  ⚠️  ORPHANED BUT DIRTY: branch=$BRANCH dir=$DIR — clean, but the worktree list could not be read, so whether git vouches for it as a worktree of this repo cannot be established\n"
                    else
                        DIRTY_OUT="${DIRTY_OUT}  ⚠️  ORPHANED BUT DIRTY: branch=$BRANCH dir=$DIR — clean, but git does not vouch for it as a worktree of this repo, so its contents cannot be reaped safely\n"
                    fi ;;
                absent)
                    if [ "$REG_CLAIMS" = unknown ]; then
                        DIRTY_OUT="${DIRTY_OUT}  ⚠️  ORPHANED BUT DIRTY: branch=$BRANCH dir=$DIR — state ABSENT, but the worktree list could not be read, so whether a registration still claims this branch cannot be established. --apply refuses it\n"
                    else
                        DIRTY_OUT="${DIRTY_OUT}  ⚠️  ORPHANED BUT DIRTY: branch=$BRANCH dir=$DIR — state ABSENT, but a worktree registration still claims this branch: either a STALE registration or a worktree that was MOVED and is live, so --apply refuses it. $(ambiguous_remedy)\n"
                    fi ;;
                *)
                    DIRTY_OUT="${DIRTY_OUT}  ⚠️  ORPHANED BUT DIRTY: branch=$BRANCH dir=$DIR (uncommitted changes — review manually)\n" ;;
            esac
            if [ "$APPLY" = true ]; then
                if [ "$FORCE_DIRTY" = true ]; then
                    if reap_record "$BRANCH" "$DIR" "$DISPATCH" "$IS_WT" true "$REG_CLAIMS"; then :; else KEPT=$((KEPT + 1)); fi
                else
                    # --apply was asked to remove it and refused (no --force-dirty): that is a KEEP,
                    # and a sweep that kept things must not read as a clean sweep (#1393).
                    KEPT=$((KEPT + 1))
                fi
            fi
        else
            ORPHANS=$((ORPHANS + 1))
            ORPHAN_OUT="${ORPHAN_OUT}  🧹 ORPHANED (safe to remove): branch=$BRANCH dir=$DIR dispatch=$DISPATCH\n"
            if [ "$APPLY" = true ]; then
                if reap_record "$BRANCH" "$DIR" "$DISPATCH" "$IS_WT" false "$REG_CLAIMS"; then :; else KEPT=$((KEPT + 1)); fi
            fi
        fi
    done < "$RECORD_FILE"
else
    echo "  (no teardown records at $RECORD_FILE)"
fi

# ── Pass 2: unrecorded worktrees/branches (informational) ──────
if command -v git >/dev/null 2>&1; then
    UNREC=0
    while IFS= read -r wtline; do
        case "$wtline" in
            worktree\ *) WT="$(printf '%s' "$wtline" | sed 's/^worktree //')" ;;
            branch\ *) WB="$(printf '%s' "$wtline" | sed 's/^branch refs\/heads\///')"
                case " $RECORDED_DIRS " in *" $WT "*) continue ;; esac
                if branch_local "$WB" && ! branch_remote "$WB"; then
                    UNREC=$((UNREC + 1))
                    [ "$UNREC" -eq 1 ] && echo "  📋 UNRECORDED (informational — --apply never touches):"
                    echo "     worktree=$WT branch=$WB"
                fi
                ;;
        esac
    done < <(git worktree list --porcelain 2>/dev/null)
    UNRECORDED=$UNREC
fi

# ── Emit classification (LIVE/RECENT first — the orphan block must be pure) ──
printf '%b' "$LIVE_OUT" "$RECENT_OUT" "$GHOST_OUT" "$DIRTY_OUT" "$ORPHAN_OUT"

# ── Summary ────────────────────────────────────────────────────
echo "── Summary ──"
echo "  Orphaned: $ORPHANS | Dirty: $DIRTY | Recent: $RECENT | Live: $LIVE | Ghosts: $GHOSTS | Unrecorded: $UNRECORDED"
if [ "$APPLY" = true ] && [ "$KEPT" -gt 0 ]; then
    # ⛔ A sweep that KEPT things must not read as a clean sweep (#1393): the operator has to know
    # that --apply was asked to remove something and refused.
    echo "  KEPT by --apply: $KEPT record(s) — see the ⚠️ lines above for the reason each was preserved"
fi
if [ "$APPLY" = false ]; then
    echo "  DRY-RUN: nothing removed (re-run with --apply to remove confirmed orphans)"
fi
if [ "$ORPHANS" -eq 0 ] && [ "$DIRTY" -eq 0 ] && [ "$GHOSTS" -eq 0 ] && [ "$UNRECORDED" -eq 0 ]; then
    echo "  No orphaned worktrees/branches found"
fi
