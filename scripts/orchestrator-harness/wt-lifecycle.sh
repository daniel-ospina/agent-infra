#!/usr/bin/env bash
# wt-lifecycle.sh — the ONE place a LANE worktree/branch is created, and the ONE place a lane that
# produced nothing takes its own worktree and branch back (agent-infra#2033).
#
# SOURCED (never executed) by every harness entry point that materialises a lane checkout:
# `dispatch-merge.sh` (the lane creation site), `lane.sh` (the lane's own exit), `fix-one.sh` and
# `adopt-fix.sh` (the foreign-branch fixer path).
#
# THE DEFECT THIS EXISTS FOR (measured 2026-10-18 on the laptop)
# --------------------------------------------------------------
# A failed or aborted lane leaves a worktree and/or a branch behind, and the collision pre-flight
# infers "in flight" from exactly those two surfaces. So the residue does not merely waste disk: it
# makes a FREE issue permanently undispatchable, on every box, with no owner and no expiry:
#
#   #8090 -> VERDICT: COLLISION
#     [local branches] refs/heads/feat/8090-tm — matched issue-number (8090) — 0 commit(s) ahead
#     [local worktrees] /Users/home/eldato/tortoise/.worktrees/tm-8090 [refs/heads/feat/8090-tm]
#
# ZERO commits ahead: the branch holds no work at all. It is the artifact of a `worktree add` whose
# lane never started. Repo-wide at the same moment: 69 worktrees, 330 local branches — 2 pure ghosts
# (0 ahead, clean), 24 abandoned WIP (0 ahead, dirty: uncommitted work, no commit ever made).
#
# WHY A FAILED `git worktree add` LEAVES THIS, MEASURED rather than assumed (SIGKILL mid-checkout,
# reproducible on any repo big enough to take >0.2 s):
#
#   $ git worktree add -b feat/9001-tm /tmp/wt9001 origin/main   # killed -9 after 0.2 s
#   records: …/wt9001  fad6ece [feat/9001-tm] locked
#   branch:  +feat/9001-tm          (created FIRST; git creates the ref, then populates)
#   dir:     …/wt9001  entries=150  (of 200 — a PARTIAL materialisation)
#   admin:   .git/worktrees/wt9001  (registered, with `locked` containing `initializing`)
#   status:  D d000/f0.txt | D d000/f1.txt …   (every not-yet-checked-out file reads as DELETED)
#
# Three consequences, all of which this file and the reaper's policy have to answer:
#   1. the branch exists and is 0 commits ahead → the pre-flight matches the issue number;
#   2. the directory is REGISTERED, so `dispatch-merge.sh`'s old `worktree list` probe decided the
#      worktree was fine and spawned the lane into a partial checkout;
#   3. the partial tree is DIRTY (deleted files) and its record is LOCKED, so the reviewed reaper
#      (`scripts/pi-reap-worktrees.sh`) preserved it forever — `dirty` and `worktree-locked` are
#      both PRESERVE verdicts, correctly, because neither test can tell this apart from real work.
#      That is why the lock's `initializing` reason is the self-identifying marker (see the reaper's
#      `interrupted-add` class), and why this file's rollback removes the record as well as the ref.
#
# POLICY (every property below is pinned by a test in `wt-lifecycle.test.sh`)
#   * A failed `worktree add` leaves EITHER a usable worktree OR nothing — never a half-materialised
#     directory plus a branch. On failure the record, the directory and (only when THIS call created
#     it and it holds no commits) the branch are removed, and the final state is VERIFIED.
#   * A branch is never left behind with 0 commits ahead when its worktree is gone. A brand-new
#     branch is exactly at the base commit, so its removal can lose nothing; the delete is an ATOMIC
#     compare-and-delete (`update-ref -d <ref> <expected-oid>`), never `git branch -D` and never
#     `--force` — if the ref MOVED, the delete is refused and the branch is kept.
#   * An existing branch is RE-USED, never deleted, when it holds commits: a previous lane's work is
#     resumed instead of the issue being skipped for ever ("worktree add failed (branch exists?)" was
#     the old behaviour, and it is the second way a free issue became permanently undispatchable).
#   * A lane that exits without producing anything removes its OWN worktree and branch — no commits
#     ahead, no upstream branch, clean tree, no live holder. Anything else is PRESERVED, and the
#     dirty case is explicitly NOT this function's to reap: backup-then-remove is the reaper's
#     policy (`reaped-patches`), and a lane that died dirty keeps its work until that policy runs.
#
# ⛔ VERSION SKEW. `$O` (=~/orchestrator) is seeded file by file, so a NEW caller can run against an
# OLD `$O/wt-lifecycle.sh` — and a caller that proceeds with a half-implemented helper is exactly the
# ungated-creation case this file removes. Callers therefore FATAL on a missing helper (78, the same
# code `spawn-gate.sh` uses), and `install.sh`'s DRIFTED list names a mismatch. A deploy that fails
# halfway MUST stop dispatching: continuing would create worktrees whose rollback does not exist.
#
# Env seams (tests set them; production never needs them):
#   WT_GIT   git binary            (default `git`)
#   WT_PS    ps binary             (default `/bin/ps`)
#   WT_LSOF  lsof binary           (default `lsof`)
#   WT_BASE  default base ref      (default `origin/main`)
set -u

# The declared-disposable allowlist, ROOT-ONLY, exactly as `pi-reap-worktrees.sh` declares it — and
# deliberately re-stated rather than sourced: the reaper must remain runnable as a standalone tool
# from launchd (its plist hands it to bash on stdin), so it cannot depend on being sourced beside
# this file. If the two lists ever disagree, the REAPER is authoritative: it is the one that deletes.
WT_EPHEMERAL=" .venv node_modules __pycache__ .pytest_cache .mypy_cache .ruff_cache .tox .cache .DS_Store "
# Ignored (`!!`) entries tolerated one step further, again mirroring the reaper: only pure
# build/test caches any checkout reproduces from its own manifests.
WT_IGNORED_REGENERABLE=" __pycache__ .pytest_cache .mypy_cache .ruff_cache .tox .DS_Store node_modules .venv .ci-selection .longmemeval_cache .wrangler .playwright-mcp .ipynb_checkpoints htmlcov :memory: "

wt_git() { "${WT_GIT:-git}" "$@"; }

# wt_log <label> <message> — callers' logs differ; this only guarantees the message is never lost.
wt_log() { printf '[wt-lifecycle] %s: %s\n' "${1:-?}" "${2:-}"; }

# wt_iso_ephemeral <basename> — 0 when the ROOT entry is declared disposable.
wt_ephemeral_name() {
    case "$WT_EPHEMERAL" in *" $1 "*) return 0 ;; esac
    return 1
}
wt_regenerable_ignored() { # <path relative to the worktree root>
    local p="$1" base="${1%/}"
    base="${base##*/}"
    case "$WT_IGNORED_REGENERABLE" in *" $base "*) return 0 ;; esac
    case "$base" in *.egg-info) return 0 ;; esac
    return 1
}

# wt_worktree_path_for_branch <repo> <branch> -> the registered path, or ""
# One bounded `git worktree list --porcelain`; the branch is compared as a REF, never as a label
# (`worktree list` keeps printing `branch refs/heads/X` after X is force-deleted).
wt_worktree_path_for_branch() {
    local repo="$1" br="$2" out
    out="$(wt_git -C "$repo" worktree list --porcelain 2>/dev/null)" || { printf ''; return 0; }
    printf '%s\n' "$out" | awk -v b="refs/heads/$br" '
        /^worktree / { p = substr($0, 10) }
        /^branch /   { if (substr($0, 8) == b) { print p; exit } }'
}

# wt_canon_any <path> — the physical form of a path that MAY NOT EXIST YET.
# `cd … && pwd -P` needs the path to exist, which is exactly NOT the case for a worktree the caller is
# asking to provision. Resolve the deepest EXISTING ancestor with `pwd -P` and append the remainder,
# so `/tmp/x/.worktrees/tm-9` compares equal to `/private/tmp/x/.worktrees/tm-9` on macOS. A path that
# cannot be resolved returns non-zero (the caller refuses, never silently reuses).
wt_canon_any() {
    local p="$1" tail="" c
    case "$p" in /*) ;; *) p="$PWD/$p" ;; esac
    while :; do
        if [ -d "$p" ]; then
            c="$(cd "$p" 2>/dev/null && pwd -P)" || return 1
            [ -n "$c" ] || return 1
            printf '%s%s\n' "$c" "$tail"
            return 0
        fi
        if [ "$p" = "/" ] || [ -z "$p" ]; then return 1; fi
        tail="/${p##*/}$tail"
        p="${p%/*}"
        [ -n "$p" ] || p="/"
    done
}

# wt_path_registered <repo> <path> -> 0 when a record exists for this path (canonical compare).
# git records RESOLVED paths (`/tmp/x` is stored as `/private/tmp/x`), so the comparison is made on
# the canonical form of both sides — a raw string compare silently misses a /tmp fixture.
wt_path_registered() {
    local repo="$1" want="$2" out canon p
    out="$(wt_git -C "$repo" worktree list --porcelain 2>/dev/null)" || return 1
    canon="$(cd "$want" 2>/dev/null && pwd -P)" || canon=""
    while IFS= read -r p; do
        p="${p#worktree }"
        [ -n "$p" ] || continue
        if [ -n "$canon" ] && [ "$(cd "$p" 2>/dev/null && pwd -P)" = "$canon" ]; then return 0; fi
        [ "$p" = "$want" ] && return 0
    done <<EOF
$(printf '%s\n' "$out" | grep '^worktree ')
EOF
    return 1
}

# wt_branch_oid <repo> <branch> -> prints the ref's oid, or "" when it does not resolve.
# The repo is an EXPLICIT first argument (the callers all pass it): a helper that reads a caller's
# `local repo` works only inside functions and silently breaks from a top-level context.
wt_branch_oid() {
    wt_git -C "$1" rev-parse --verify -q "refs/heads/$2" 2>/dev/null
}

# wt_ahead_count <repo> <base> <sha> -> commits in <sha> not in <base>, or "" when unevaluable.
# FAIL-CLOSED: an unevaluable count is "", and every caller treats "" as "assume there is work".
wt_ahead_count() {
    local repo="$1" base="$2" sha="$3" n
    n="$(wt_git -C "$repo" rev-list --count "$base..$sha" 2>/dev/null)" || return 0
    case "$n" in ''|*[!0-9]*) return 0 ;; esac
    printf '%s' "$n"
}

# wt_lock_reason <path> -> the text of this record's `locked` file, or "" when there is none.
# git writes `<gitdir>/worktrees/<name>/locked` containing `initializing` for the duration of
# `worktree add`, and REMOVES it when the checkout completes. So a surviving `initializing` lock is
# positive evidence that the add did not complete — the one signal that separates a partial
# materialisation (no work can exist in it) from a checkout an operator marked locked on purpose.
wt_lock_reason() {
    local path="$1" gd f reason
    # The admin directory is resolved FROM THE CHECKOUT (`-C <path> rev-parse --git-dir`), never by
    # guessing `<common>/worktrees/<basename>` and never by scanning every record: a scan would
    # answer for the WRONG worktree, and "repair" one this call has no business touching.
    gd="$(wt_git -C "$path" rev-parse --path-format=absolute --git-dir 2>/dev/null)" || gd=""
    [ -n "$gd" ] || { printf ''; return 0; }
    f="$gd/locked"
    [ -f "$f" ] || { printf ''; return 0; }
    reason="$(cat "$f" 2>/dev/null)" || reason=""
    printf '%s' "$reason"
}

# wt_lock_is_initializing <path> — 0 when this record is an add that has not completed. The ONE probe
# of the lock; the two predicates below both read it, so the "is there a lock" question and the "is it
# old enough to be dead" question can never disagree about what the lock SAYS.
wt_lock_is_initializing() {
    [ "$(wt_lock_reason "$1")" = "initializing" ]
}

# wt_lock_initializing_age <path> — the lock's age in seconds, or "" when it is not an initializing
# lock or the age cannot be read. Numeric or nothing: a garbled value is "cannot judge", never a number.
WT_INIT_LOCK_MIN_AGE="${WT_INIT_LOCK_MIN_AGE:-300}"
wt_lock_initializing_age() {
    local path="$1" gd f age
    wt_lock_is_initializing "$path" || { printf ''; return 0; }
    gd="$(wt_git -C "$path" rev-parse --path-format=absolute --git-dir 2>/dev/null)" || gd=""
    [ -n "$gd" ] || { printf ''; return 0; }
    f="$gd/locked"
    # ⛔ GNU `stat -c %Y` FIRST, then BSD `stat -f %m` — NEVER the reverse (agent-infra#1702, whose
    # note lives in orch-loop.sh beside every other copy of this ladder). GNU coreutils reads `-f` as
    # "filesystem status" and `%m` as a second FILENAME: it prints a whole filesystem block to stdout
    # and exits 0, so a BSD-first `||` fallback NEVER RUNS and `age` is that block. This file had the
    # BSD-first form, so on Linux `age` was non-numeric, the predicate returned 1 on every input, and
    # the interrupted-add repair below — the whole reason this function exists — was DEAD CODE in the
    # one environment (ubuntu CI / the cloud cells) where it would matter. The suite never caught it
    # because it was not wired into run-bash-shards.sh; spawn-gate.test.sh's wiring guard now fails
    # on that, which is how it surfaced. Both probes are validated numerically.
    age="$(stat -c %Y "$f" 2>/dev/null || true)"
    case "$age" in ''|*[!0-9]*) age="" ;; esac
    if [ -z "$age" ]; then
        age="$(stat -f %m "$f" 2>/dev/null || true)"
        case "$age" in ''|*[!0-9]*) age="" ;; esac
    fi
    [ -n "$age" ] || { printf ''; return 0; }
    printf '%s' "$(( $(date +%s) - age ))"
}

# wt_lock_is_stale_initializing <path> — 0 when this record is an add that never finished.
# The age floor only excludes an add that is in progress RIGHT NOW; it is not the safety.
wt_lock_is_stale_initializing() {
    local age
    age="$(wt_lock_initializing_age "$1")"
    [ -n "$age" ] || return 1
    [ "$age" -ge "$WT_INIT_LOCK_MIN_AGE" ]
}


# ── rollback ─────────────────────────────────────────────────────────────────────────────────────
# wt_rollback <repo> <path> <branch> <created_branch 0|1> <base>
# Remove everything this creation attempt made, then VERIFY. Never touches a branch that existed
# before the attempt, and never deletes a branch whose commits are not provably on <base>.
# 0 = nothing left · 1 = residue remains (named in WT_RESULT)
wt_rollback() {
    local repo="$1" path="$2" br="$3" created="$4" base="$5" oid n on_br
    WT_RESULT=""
    if wt_path_registered "$repo" "$path"; then
        # Refuse to force-remove a record that belongs to ANOTHER branch: a registered worktree at
        # this path on a different branch is somebody's checkout, not our residue.
        on_br="$(wt_git -C "$path" symbolic-ref --short HEAD 2>/dev/null)"
        if [ -n "$on_br" ] && [ "$on_br" != "$br" ]; then
            WT_RESULT="refusing to roll back $path: it is checked out on $on_br, not $br"
            return 1
        fi
        # Unlock first: an interrupted add leaves the record locked and `worktree remove` refuses it.
        wt_git -C "$repo" worktree unlock "$path" >/dev/null 2>&1 || true
        wt_git -C "$repo" worktree remove --force "$path" >/dev/null 2>&1 || true
    fi
    if wt_path_registered "$repo" "$path"; then
        # The record survived (a half-written admin dir, or the path was already gone): the record
        # is OUR residue either way, so deregister it — `prune` only drops records whose checkout
        # is absent, which is exactly the remaining case here.
        wt_git -C "$repo" worktree prune >/dev/null 2>&1 || true
    fi
    # A directory git could not remove (an interrupted add can leave one git never registered).
    if [ -e "$path" ] && ! wt_path_registered "$repo" "$path"; then
        rm -rf -- "$path" 2>/dev/null || true
    fi
    if [ "$created" = 1 ]; then
        oid="$(wt_branch_oid "$repo" "$br")"
        if [ -n "$oid" ]; then
            n="$(wt_ahead_count "$repo" "$base" "$oid")"
            # "" = unevaluable => KEEP. Only a proven 0-ahead ref is deleted, by CAS on the oid we
            # read: if the ref moved (someone committed between the read and the delete) git refuses.
            if [ "$n" = "0" ]; then
                wt_git -C "$repo" update-ref -d "refs/heads/$br" "$oid" >/dev/null 2>&1 || true
            fi
        fi
    fi
    # VERIFY the end state — a rollback that reports success without checking is the defect again.
    if wt_path_registered "$repo" "$path" || [ -e "$path" ]; then
        WT_RESULT="rollback-incomplete: $path is still present/registered"
        return 1
    fi
    if [ "$created" = 1 ] && [ -n "$(wt_branch_oid "$repo" "$br")" ]; then
        # ⛔ SAY WHICH DATUM WAS READ. This line used to be `[ -n "$(wt_ahead_count …)" = 0 ]` — a
        # malformed test (3+ arguments), so it was ALWAYS false AND printed `[: too many arguments`,
        # and the message below therefore claimed "it holds commits" about a ref whose ahead-count
        # had never been compared to 0. A kept ref is kept either way (fail-closed); the READ is what
        # the operator acts on.
        local surv_ahead
        surv_ahead="$(wt_ahead_count "$repo" "$base" "$(wt_branch_oid "$repo" "$br")")"
        if [ "$surv_ahead" = 0 ]; then
            WT_RESULT="rollback-incomplete: refs/heads/$br survives with 0 commits ahead"
        elif [ -z "$surv_ahead" ]; then
            WT_RESULT="rollback-incomplete: refs/heads/$br survives and its commits-ahead count could not be read — kept (fail-closed)"
        else
            WT_RESULT="rollback-incomplete: refs/heads/$br survives (it holds $surv_ahead commit(s) — kept deliberately)"
        fi
        return 1
    fi
    WT_RESULT="rolled back: no worktree, no branch, no directory"
    return 0
}

# ── provisioning ────────────────────────────────────────────────────────────────────────────────
# wt_provision <repo> <worktree-path> <branch> [base]
#   0 = a USABLE worktree exists at <path> on <branch>           (WT_RESULT says which way)
#   1 = nothing was created and nothing was left behind          (WT_RESULT says why)
#   2 = a pre-existing state this function refuses to touch      (nothing changed)
#   3 = ROLLBACK FAILED — residue remains, and the caller must surface it (WT_RESULT names it)
# Idempotent: a second call for the same (path, branch) is a no-op.
wt_provision() {
    local repo="$1" path="$2" br="$3" base="${4:-${WT_BASE:-origin/main}}"
    local created=0 oid existing_oid ahead rc wt_registered cur_canon want_canon
    WT_RESULT=""

    [ -d "$repo" ] || { WT_RESULT="repo does not exist: $repo"; return 1; }
    case "$br" in ''|*[!a-zA-Z0-9._/-]*) WT_RESULT="refusing unsafe branch name: ${br:-<empty>}"; return 1 ;; esac
    case "$path" in /*) ;; *) path="$repo/$path" ;; esac

    # 1. Already registered on THIS branch?
    wt_registered="$(wt_worktree_path_for_branch "$repo" "$br")"
    if [ -n "$wt_registered" ]; then
        if wt_lock_is_stale_initializing "$wt_registered"; then
            # The measured residue: a record whose add never finished. It cannot hold work, so it is
            # rolled back rather than trusted — the old caller spawned a lane into it.
            wt_log provision "repairing an INTERRUPTED add at $wt_registered (lock reads 'initializing')"
            wt_rollback "$repo" "$wt_registered" "$br" 0 "$base" || return 3
            WT_RESULT="repaired interrupted add"
        elif wt_lock_is_initializing "$wt_registered"; then
            # ⛔ A **YOUNG** `initializing` LOCK IS NOT A USABLE WORKTREE (#2102 review P1, MEASURED).
            # This arm used to fall through to the `elif` below, which asks the checkout two questions
            # — does `symbolic-ref --short HEAD` name the branch, and does `rev-parse --verify HEAD`
            # resolve — and BOTH are already true in a killed `worktree add`, because git creates the
            # ref and writes HEAD BEFORE it populates the tree (the measured ordering quoted in this
            # file's header). So for the first `${WT_INIT_LOCK_MIN_AGE}s` after an add died, the
            # "reuse" answer was rc=0 against a half-materialised checkout: measured, a tree with
            # every file missing answered `rc=0  WT_RESULT=reused existing worktree …`, and the caller
            # spawned a lane into it — consequence #2 of the header, in the window the floor does not
            # cover. `rc=0` MUST mean "a USABLE worktree exists at <path>", and a record git still
            # marks `initializing` cannot prove that, whether the add is running or dead.
            #
            # rc=2 is the callers' documented "refuses to touch, nothing changed": dispatch-merge.sh
            # releases the claim and the issue is retried on the next cycle, by which time the lock is
            # either gone (a real add finished) or past the floor (a dead one is repaired above).
            # Reaping it here instead would be a recursive delete of a checkout another process may
            # be writing RIGHT NOW — that is what the floor exists to prevent.
            WT_RESULT="record at $wt_registered is locked 'initializing' and younger than ${WT_INIT_LOCK_MIN_AGE}s — an add is either still running or died moments ago, and neither leaves a checkout that can be PROVEN usable (git writes the ref and HEAD before it populates the tree). Refusing to reuse it; nothing was changed — retry next cycle"
            return 2
        elif [ "$(wt_git -C "$wt_registered" symbolic-ref --short HEAD 2>/dev/null)" = "$br" ] \
             && wt_git -C "$wt_registered" rev-parse --verify -q HEAD >/dev/null 2>&1; then
            # ⛔ rc=0 MUST MEAN "A USABLE WORKTREE EXISTS AT <path>" — THE PATH THE CALLER NAMED
            # (agent-infra#2102 review §3). This branch resolves the worktree BY BRANCH, ANYWHERE, and
            # returned success for it without comparing `$wt_registered` to `$path`. The caller then
            # hard-codes its own path: `dispatch-merge.sh` runs `tmux new-session -d -s lane-$N
            # "cd '$REPO/.worktrees/$WT' && …"` with WT=`tm-$N`, and when the branch was already
            # checked out at `.worktrees/fix-<PR>` (fix-one.sh) or `.worktrees/adopt-<PR>`
            # (adopt-fix.sh) — both keyed on the SAME `feat/<N>-tm` head branch — the `cd` failed, the
            # `&&` short-circuited and the session exited instantly, while `tmux new-session -d`
            # returned 0. The dispatcher printed "lane-N (implement+PR)", deliberately did NOT release
            # the claim, and chain-N waited out its 90-minute bound for a PR nothing was working on.
            # Pre-PR this input FAILED CLOSED (`worktree add -b` errors "branch exists" → release +
            # continue), so silently succeeding here is a REGRESSION, not a pre-existing gap.
            # Both sides are canonicalized before the compare — and for a path that does not exist yet:
            # `git worktree list` reports the RESOLVED path (/tmp → /private/tmp), so a raw string
            # compare would refuse a legitimate reuse on macOS.
            cur_canon="$(wt_canon_any "$wt_registered" 2>/dev/null)" || cur_canon=""
            want_canon="$(wt_canon_any "$path" 2>/dev/null)" || want_canon=""
            if [ -n "$want_canon" ] && [ "$cur_canon" = "$want_canon" ]; then
                WT_RESULT="reused existing worktree $wt_registered"
                return 0
            fi
            # rc=2 is the caller's documented "refuses to touch, nothing changed" answer, which every
            # caller turns into skip + release-claim — the pre-PR fail-closed behaviour.
            WT_RESULT="branch $br is already checked out at $wt_registered, NOT at the requested $path — refusing to report a usable worktree at a path that does not exist"
            return 2
        else
            # Registered, on this branch's record, but the checkout is not usable (HEAD unresolvable
            # or another branch checked out). Repair rather than reuse a broken tree.
            wt_log provision "repairing an UNUSABLE worktree at $wt_registered"
            wt_rollback "$repo" "$wt_registered" "$br" 0 "$base" || return 3
            WT_RESULT="repaired unusable worktree"
        fi
    fi

    # 2. The path is taken by something else (a directory this function did not create, or a record
    #    for a DIFFERENT branch). Never delete it: that would be a blind recursive delete of a
    #    checkout someone else owns.
    if [ -e "$path" ] && ! wt_path_registered "$repo" "$path"; then
        WT_RESULT="path exists but is not a registered worktree: $path — refusing to touch it"
        return 2
    fi
    if wt_path_registered "$repo" "$path"; then
        WT_RESULT="path is a worktree of a DIFFERENT branch: $path — refusing to reuse it"
        return 2
    fi

    # 3. Branch present?
    oid="$(wt_branch_oid "$repo" "$br")"
    if [ -n "$oid" ]; then
        ahead="$(wt_ahead_count "$repo" "$base" "$oid")"
        if [ "$ahead" = "0" ]; then
            # A ghost: the branch is exactly at the base, so it holds NO work. It is the residue the
            # pre-flight counts, and it is the reason a re-dispatch of the same issue could never
            # succeed ("worktree add failed (branch exists?)"). CAS-delete, then create fresh.
            wt_git -C "$repo" update-ref -d "refs/heads/$br" "$oid" >/dev/null 2>&1 || true
            if [ -n "$(wt_branch_oid "$repo" "$br")" ]; then
                WT_RESULT="refs/heads/$br is a 0-ahead ghost but could not be removed (ref moved?) — refusing to reuse"
                return 2
            fi
            wt_log provision "removed 0-commit ghost branch refs/heads/$br (no work in it)"
            oid=""
            created=1
        fi
    else
        created=1
    fi

    if [ -n "$oid" ]; then
        # An existing branch WITH commits: attach it. Resuming beats skipping, and the work is the
        # previous lane's — deleting it is the one thing this file must never do.
        wt_git -C "$repo" worktree add "$path" "$br" >/dev/null 2>&1
    else
        wt_git -C "$repo" worktree add -b "$br" "$path" "$base" >/dev/null 2>&1
    fi
    rc=$?
    if [ "$rc" != 0 ]; then
        # THE failure path. The branch may already exist (created by git before the checkout
        # failed), the directory may be partial, and the record may be registered and locked.
        wt_rollback "$repo" "$path" "$br" "$created" "$base" || return 3
        WT_RESULT="worktree add failed (rc=$rc) — $WT_RESULT"
        return 1
    fi

    # 4. VERIFY the thing the caller is about to spawn a lane into. A `worktree add` that exits 0
    #    but leaves an unusable checkout must not read as success.
    if [ "$(wt_git -C "$path" symbolic-ref --short HEAD 2>/dev/null)" != "$br" ] \
        || ! wt_git -C "$path" rev-parse --verify -q HEAD >/dev/null 2>&1; then
        wt_rollback "$repo" "$path" "$br" "$created" "$base" || return 3
        WT_RESULT="worktree add reported success but the checkout is not usable — $WT_RESULT"
        return 1
    fi
    WT_RESULT="created $path on $br from $base"
    return 0
}

# ── the lane's own exit path ────────────────────────────────────────────────────────────────────
WT_PROBE_SECONDS="${WT_PROBE_SECONDS:-15}"
# The pid of the LAST child wt_run_bounded forked ("" when none). Callers need it because a probe
# process is not a holder of anything, and one of them lists ITSELF in its own output — see the cwd
# witness in wt_live_holders for the measurement.
WT_PROBE_PID=""
# The done-flag is what tells "the watchdog killed it" from "the command finished a moment before
# the watchdog fired": without it the marker is written for BOTH, so every probe reports 124 and the
# live-holder gate preserves for ever (the exact defect a first draft of this function had).
#
# ⛔ EVERY FORK HERE RUNS FROM A NEUTRAL CWD, AND THAT IS A CORRECTNESS REQUIREMENT (measured while
# verifying #2033). This helper is called from `wt_live_holders`, which runs with the LANE's cwd —
# the worktree — and a forked child with no `exec` inherits it. So `lsof -d cwd` listed ITSELF (cwd =
# the worktree), and its own watchdog `sleep` did too, and the cwd witness reported each of them as
# "a live process still holds the checkout". The consequence was total: EVERY reap refused, with a
# pid that was gone by the time anything looked at it (`ps -p N` empty for every reported holder —
# the tell). Neither the chain rule (ancestors only) nor the inherited-argv rule could catch it.
# `cd /` before both forks removes the whole class: a probe process is never IN the tree it inspects.
wt_run_bounded() { # <secs> <outfile> <cmd...> -> 0 ok · 124 timeout · else the command's status
    local secs="$1" out="$2" pid wd rc=0
    shift 2
    WT_PROBE_PID=""
    : >"$out"; rm -f "$out.timeout" "$out.done"
    ( cd / 2>/dev/null || cd "${TMPDIR:-/tmp}" || :; exec "$@" ) >"$out" 2>/dev/null &
    pid=$!
    WT_PROBE_PID="$pid"
    (
        cd / 2>/dev/null || cd "${TMPDIR:-/tmp}" || :
        trap 'kill "$s" 2>/dev/null; exit 0' TERM INT
        sleep "$secs" & s=$!
        wait "$s" 2>/dev/null
        [ -f "$out.done" ] && exit 0
        if kill -0 "$pid" 2>/dev/null; then
            : >"$out.timeout"
            kill -9 "$pid" 2>/dev/null
        fi
    ) >/dev/null 2>&1 &
    wd=$!
    wait "$pid" 2>/dev/null || rc=$?
    : >"$out.done"
    kill -TERM "$wd" 2>/dev/null
    wait "$wd" 2>/dev/null
    if [ -f "$out.timeout" ]; then rm -f "$out" "$out.timeout" "$out.done"; return 124; fi
    rm -f "$out.done"
    return "$rc"
}

# wt_own_pid — the pid of the process RUNNING this function, not the pid of the shell that started.
# ⛔ `$$` IS WRONG HERE, MEASURED: bash keeps `$$` constant across a `$( )` subshell, so inside
# `holder="$(wt_live_holders …)"` every process in that subshell reports the PARENT's pid — and
# macOS `/bin/bash` 3.2 has no `$BASHPID`. The consequence was not cosmetic: the subshell itself
# carries the caller's argv (no exec happens), so when that argv names the checkout — which it does
# for every `bash -c "cd <wt> && …"` — the probe found ITSELF and refused every reap.
# ⛔ IT MUST SET A VARIABLE, NOT PRINT: called as `p="$(wt_own_pid)"` it reports the pid of ITS OWN
# command-substitution subshell, which exits immediately, so the ancestor walk then starts at a dead
# pid and stops (measured: a chain of ONE entry, i.e. nothing excluded).
# ⛔ AND THE INTERNALS ARE `_wt_*`: `local p` here would SHADOW the caller's `p` under bash's dynamic
# scoping, so `printf -v "$1"` wrote to this frame and the caller's variable stayed empty (measured:
# an EMPTY chain — the same self-match, reached a third way).
wt_own_pid_to() { # <varname>
    local _wt_c _wt_p
    sleep 0.2 & _wt_c=$! 2>/dev/null
    # `${WT_PS:-/bin/ps}`, like the argv probe below: the header documents WT_PS as the seam, and a
    # hard-coded path here meant a test could not shim the ancestor walk (agent-infra#2102 review, minor).
    _wt_p="$("${WT_PS:-/bin/ps}" -o ppid= -p "$_wt_c" 2>/dev/null | tr -d ' ')"
    wait "$_wt_c" 2>/dev/null
    printf -v "$1" '%s' "${_wt_p:-$$}"
}
wt_own_pid() { local v; wt_own_pid_to v; printf '%s' "$v"; }

wt_self_chain() { # pids of this process and its ancestors, space-prefixed/terminated
    local p chain=" " i=0
    wt_own_pid_to p
    while [ -n "$p" ] && [ "$p" != 0 ] && [ "$i" -lt 64 ]; do
        chain="$chain$p "
        p="$("${WT_PS:-/bin/ps}" -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
        i=$((i + 1))
    done
    printf '%s' "$chain"
}

# wt_live_holders <canon-path> -> prints "pid<TAB>reason" for a live holder.
#   0 = a holder was found · 1 = no holder · 2 = the argv probe could not be evaluated
# Two witnesses, both silent before anything is removed:
#   argv  — a process whose command line names the checkout (a `bash -c "cd <wt> && …"`, a
#           `pytest <wt>/…`), and
#   cwd   — a process whose working directory is inside the checkout, where `lsof` is available.
#
# ⛔ THE WITNESSES MUST EXCLUDE OUR OWN FORKS, AND THAT IS NOT A DETAIL — IT IS THE BUG THAT MADE
# THIS PROBE REFUSE EVERY SINGLE REAP WHILE I CLAIMED IT WORKED. A forked subshell does NOT exec, so
# it inherits its parent's argv AND cwd verbatim: the watchdog subshell inside `wt_run_bounded`, the
# `$( )` around this very call, and every command substitution in the caller all look exactly like
# "a process holding the checkout" whenever any process in our chain happens to name the path in its
# argv. Measured, three times in a row, before the rule below existed. The rule: a pid is OURS — and
# so is any process whose command line is byte-identical to a process in our chain — because that is
# precisely the signature of an inherited argv. A genuine holder (a `bash -c "cd <wt> …"` client, a
# `pytest` started in the tree) has a DIFFERENT command line and is still seen.
# The argv witness must be evaluable (a failure there is fail-closed, 2). The cwd witness is
# degraded-tolerant, exactly as the reviewed reaper treats it (`CWD_PROBE=degraded`): a box whose
# `lsof` is slow or absent has one witness fewer, which is the state every lane lived in before this
# file existed — turning that into a permanent refusal would keep every worktree for ever.
# Bounded: `lsof` over a loaded box is not free, and an unbounded probe on the exit path is the
# "reaper that hangs the fleet" failure this whole family of scripts exists to avoid.
wt_live_holders() {
    local path="$1" chain out tmp ignore pid line cwd
    local tmpbase
    chain="$(wt_self_chain)"
    tmpbase="${TMPDIR:-/tmp}/wt-lifecycle.$$"
    ignore="$tmpbase.ignore"
    : >"$ignore" 2>/dev/null || { printf '2
'; return 2; }
    # ── witness 1: argv ─────────────────────────────────────────────────────────────────────────
    out="$tmpbase.ps"
    wt_run_bounded "$WT_PROBE_SECONDS" "$out" "${WT_PS:-/bin/ps}" -Ao pid=,command= || { rm -f "$ignore"; return 2; }
    line="$(awk -v chain="$chain" -v path="$path" -v ign="$ignore" '
        FNR == NR {
            # Pass 1: our own chain, and the command lines they show. `-o pid=,command=` pads the
            # pid column, so the line is re-split rather than trusting a single space.
            pid = $1
            cmd = $0
            sub(/^[ \t]*[0-9]+[ \t]*/, "", cmd)
            if (index(" " chain " ", " " pid " ")) own[cmd] = 1
            next
        }
        {
            pid = $1
            cmd = $0
            sub(/^[ \t]*[0-9]+[ \t]*/, "", cmd)
            if (index(" " chain " ", " " pid " ")) { print pid > ign; next }
            if (cmd in own) { print pid > ign; next }
            if (index(cmd, path) > 0) { print pid "\targv-lists-the-worktree"; exit }
        }' "$out" "$out")"
    rm -f "$out"
    if [ -n "$line" ]; then printf '%s\n' "$line"; rm -f "$ignore"; return 0; fi
    # ── witness 2: cwd (optional) ──────────────────────────────────────────────────────────────
    command -v "${WT_LSOF:-lsof}" >/dev/null 2>&1 || { rm -f "$ignore"; return 1; }
    out="$tmpbase.lsof"
    wt_run_bounded "$WT_PROBE_SECONDS" "$out" "${WT_LSOF:-lsof}" -nP -d cwd -Fpn || { rm -f "$out" "$ignore"; return 1; }
    # ⛔ THE PROBE LISTS ITSELF, AND THAT IS THE MEASUREMENT THAT MADE THIS GATE REFUSE EVERY REAP
    # (found while verifying #2033, 2026-10-18). `lsof -d cwd` includes the `lsof` process in its own
    # output, and this helper runs it with the CWD INHERITED FROM THE LANE — i.e. the worktree. So the
    # cwd witness found exactly one "holder": the probe, pid N, cwd-inside-the-worktree. By the time
    # anything looked, that pid was gone (measured: `ps -p N` empty for every reported holder), which
    # is the tell — a genuine holder does not evaporate in a millisecond. It is not in `$chain`
    # (ancestors only) and its command line is not one of ours, so neither existing rule could catch it.
    # The probe pid is therefore excluded EXPLICITLY, from the pid wt_run_bounded actually forked.
    local probe_pid="${WT_PROBE_PID:-}"
    pid=""; cwd=""
    while IFS= read -r line; do
        case "$line" in
            p*) pid="${line#p}"; cwd="" ;;
            n*)
                cwd="${line#n}"
                case "$cwd" in
                    "$path"|"$path"/*) ;;
                    *) continue ;;
                esac
                case "$chain" in *" $pid "*) continue ;; esac
                [ -n "$probe_pid" ] && [ "$pid" = "$probe_pid" ] && continue
                if grep -qxF -- "$pid" "$ignore" 2>/dev/null; then continue; fi
                printf '%s\tcwd-inside-the-worktree\n' "$pid"
                rm -f "$out" "$ignore"
                return 0 ;;
        esac
    done <"$out"
    rm -f "$out" "$ignore"
    return 1
}

# wt_dirt <path> -> prints "clean" | "dirty<TAB>paths" | "ignored<TAB>paths" | "error<TAB>reason"
# Mirrors the reaper's clean gate: ROOT-level declared-ephemeral entries are tolerated, ignored
# entries only when they are pure regenerable cache, everything else preserves.
wt_dirt() {
    local path="$1" out buf line xy rel base eph="" n=0 bad="" ign=""
    out="${TMPDIR:-/tmp}/wt-lifecycle.$$.status"
    wt_run_bounded "$WT_PROBE_SECONDS" "$out" \
        "${WT_GIT:-git}" -C "$path" status --porcelain --ignored=traditional --untracked-files=normal -z \
        || { rm -f "$out"; printf 'error\tstatus-probe-failed-or-timed-out\n'; return 0; }
    buf="$(tr '\0' '\n' <"$out")"
    rm -f "$out"
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        if [ "${line:2:1}" != " " ]; then bad="$bad(unparseable)"; continue; fi
        xy="${line:0:2}"
        rel="${line:3}"
        base="${rel%/}"; base="${base##*/}"
        case "$xy" in
            '??'|'!!')
                if [ "${rel%/}" = "$base" ] && wt_ephemeral_name "$base"; then
                    eph="$eph$rel "            # declared disposable — pre-deleted before removal
                elif [ "$xy" = '!!' ] && wt_regenerable_ignored "$rel"; then
                    :                          # regenerable cache: does not block, needs no delete
                elif [ "$xy" = '!!' ]; then
                    # Ignored DATA (`git worktree remove` does NOT refuse it, so this gate is the
                    # only thing between a gitignored .env and silent destruction).
                    n=$((n + 1)); [ "$n" -le 3 ] && ign="$ign$rel "
                else
                    # ⛔ AN UNTRACKED NON-EPHEMERAL FILE IS **DIRT**, NOT AN IGNORED ARTIFACT.
                    # Measured: this branch was the `else` above, so the only copy of a lane's
                    # never-committed work was reported as `ignored` — which reads as "operator data,
                    # nothing to do" instead of "this is the work". Still a PRESERVE either way, but
                    # the reason is what the operator acts on.
                    n=$((n + 1)); [ "$n" -le 3 ] && bad="$bad$rel "
                fi ;;
            *) n=$((n + 1)); [ "$n" -le 3 ] && bad="$bad$rel " ;;
        esac
    done <<<"$buf"
    if [ -n "$bad" ]; then printf 'dirty\t%s\n' "$(printf '%s' "$bad" | sed 's/ $//')"; return 0; fi
    if [ -n "$ign" ]; then printf 'ignored\t%s\n' "$(printf '%s' "$ign" | sed 's/ $//')"; return 0; fi
    # `clean` carries the declared-disposable ROOT entries: the caller must delete THEM before
    # `git worktree remove`, which refuses an untracked `.venv` (measured — the removal failed with
    # "contains modified or untracked files" and the record was left behind).
    printf 'clean\t%s\n' "$(printf '%s' "$eph" | sed 's/ $//')"
}

# wt_reap_if_empty <repo> <worktree-path> <branch> <label> [base]
#   0 = reaped (worktree AND branch gone)      WT_RESULT says so
#   1 = PRESERVED (real work / a live holder)  WT_RESULT names the reason and the remedy
#   2 = refused or failed (residue may remain) WT_RESULT names it — the caller must log it loudly
# Safe to call from the lane's own EXIT trap: the removal runs from a subshell whose cwd is the
# REPO, never from the checkout being deleted.
wt_reap_if_empty() {
    local repo="$1" path="$2" br="$3" label="${4:-lane}" base="${5:-${WT_BASE:-origin/main}}"
    local canon cwd_reg a oid holder holder_rc dirt verdict detail upstream cur_br head_sha survivors
    WT_RESULT=""
    case "$path" in /*) ;; *) path="$repo/$path" ;; esac
    [ -d "$repo" ] || { WT_RESULT="repo does not exist"; return 1; }

    if ! wt_path_registered "$repo" "$path"; then
        WT_RESULT="no registered worktree at $path — nothing to reap"
        return 0
    fi
    canon="$(cd "$path" 2>/dev/null && pwd -P)" || canon="$path"
    cwd_reg="$(cd "$PWD" 2>/dev/null && pwd -P)" || cwd_reg="$PWD"
    case "$cwd_reg" in
        # Never remove a directory that CONTAINS our cwd (only the lane's own checkout is ours).
        "$canon"/*) WT_RESULT="refusing to remove $canon: it contains the caller's cwd ($cwd_reg)"; return 2 ;;
    esac

    # ⛔ THE CHECKOUT'S OWN HEAD IS THE ONE FACT THIS FUNCTION NEVER ASKED (#2102 review P1, MEASURED).
    # Every gate below asks about `refs/heads/$br` — does it resolve, how far ahead of the base is it,
    # was it pushed — and NOT ONE of them asks what the checkout is actually checked out ON. A lane
    # that left HEAD DETACHED (an agent's `git checkout --detach`, a bisect, a rebase that died) and
    # committed its work there passes all of them: the tree is clean (nothing to preserve), `$br` is
    # still at the base (0 ahead), and there is no `origin/$br` (never pushed) — so the checkout was
    # removed, the branch deleted by CAS, and the lane's commit left reachable from NOTHING.
    # MEASURED before this guard: `rc=0  WT_RESULT=reaped … (lane 9 produced no commits)`, and
    # `git for-each-ref --contains <sha>` then listed no ref at all — silent destruction of work,
    # reported as "produced no commits". The reviewed reaper already treats this class as PRESERVE
    # (`detached-unreachable`, above every remove class); this is the same rule at the earlier seam.
    cur_br="$(wt_git -C "$path" symbolic-ref --short HEAD 2>/dev/null)" || cur_br=""
    if [ "$cur_br" != "$br" ]; then
        if [ -n "$cur_br" ]; then
            WT_RESULT="the checkout is on refs/heads/$cur_br, NOT on refs/heads/$br — the work it holds is on another branch, so nothing here is provably this lane's empty work; kept"
            return 1
        fi
        # Detached. Removing the checkout cannot orphan anything ONLY when the commit HEAD names is
        # already held by a ref that survives this call. `refs/heads/$br` is excluded because this
        # function deletes it — "it survives" must mean a ref we are not about to delete.
        head_sha="$(wt_git -C "$path" rev-parse --verify -q HEAD 2>/dev/null)" || head_sha=""
        survivors=""
        if [ -n "$head_sha" ]; then
            survivors="$(wt_git -C "$repo" for-each-ref --contains "$head_sha" --format='%(refname)' 2>/dev/null \
                         | grep -vx "refs/heads/$br" || true)"
        fi
        if [ -z "$survivors" ]; then
            WT_RESULT="the checkout's HEAD is DETACHED at ${head_sha:-an unreadable commit} and no ref that survives this call holds that commit — removing the checkout would orphan the lane's commits; kept (the reaper's detached-unreachable policy is bash scripts/pi-reap-worktrees.sh --repo '$repo')"
            return 1
        fi
        # Detached at a commit a surviving ref already holds (typically the base tip): nothing can be
        # lost by removing the checkout, so fall through — every gate below is unchanged.
    fi

    holder=""; holder_rc=0
    holder="$(wt_live_holders "$canon")" || holder_rc=$?
    if [ "$holder_rc" = 0 ]; then
        WT_RESULT="a live process still holds the checkout (pid ${holder%%$'\t'*}, ${holder#*$'\t'}) — kept"
        return 1
    fi
    if [ "$holder_rc" != 1 ]; then
        WT_RESULT="the live-holder probe could not be evaluated (fail-closed) — kept"
        return 1
    fi

    dirt="$(wt_dirt "$path")"
    verdict="${dirt%%$'\t'*}"
    detail="${dirt#*$'\t'}"
    case "$verdict" in
        clean) ;;   # `detail` holds the disposable ROOT entries, used by the pre-delete below
        dirty)
            WT_RESULT="the tree is DIRTY ($detail) — the work is preserved for the reaper's backup-then-reap policy, not deleted here"
            return 1 ;;
        ignored)
            WT_RESULT="the tree holds ignored, non-regenerable data ($detail) — preserved (git worktree remove would delete it silently)"
            return 1 ;;
        *)
            WT_RESULT="the clean gate could not be evaluated ($detail) — preserved (fail-closed)"
            return 1 ;;
    esac

    oid="$(wt_branch_oid "$repo" "$br")"
    if [ -z "$oid" ]; then
        WT_RESULT="branch refs/heads/$br does not resolve — refusing to reap a checkout whose branch is already gone"
        return 2
    fi
    a="$(wt_ahead_count "$repo" "$base" "$oid")"
    if [ -z "$a" ]; then
        WT_RESULT="cannot count commits ahead of $base — preserved (fail-closed)"
        return 1
    fi
    if [ "$a" != "0" ]; then
        WT_RESULT="the branch is $a commit(s) ahead of $base — that work is kept"
        return 1
    fi
    # A pushed branch means a PR may exist (or be about to): the remote ref is the durable copy, so
    # the local one is not ours to delete while it is someone else's review anchor.
    if upstream="$(wt_git -C "$repo" rev-parse --verify -q "refs/remotes/origin/$br" 2>/dev/null)" \
        && [ -n "$upstream" ]; then
        WT_RESULT="origin/$br exists — the branch was pushed, so it may back an open PR; kept"
        return 1
    fi

    # The declared-disposable ROOT entries (a `.venv`, a `node_modules`) go first: `git worktree
    # remove` refuses an untracked directory, so without this an empty lane's checkout could never be
    # reaped — the removal would fail every time and the residue would survive the fix.
    for entry in $detail; do
        target="$path/${entry%/}"
        [ -e "$target" ] || [ -L "$target" ] || continue
        rm -rf -- "$target" 2>/dev/null || true
    done

    # Remove the CHECKOUT first (from the repo, not from inside it), then the branch. `-d`-style
    # deletion is not used at all: the ref is 0 commits ahead of <base>, so nothing can be lost, and
    # the CAS is what makes that claim checkable at the instant of deletion.
    if ! ( cd "$repo" && "${WT_GIT:-git}" worktree remove "$path" ) >/dev/null 2>&1; then
        WT_RESULT="git worktree remove refused $path — left in place for the reaper (run: bash scripts/pi-reap-worktrees.sh --repo '$repo')"
        return 2
    fi
    if ! wt_git -C "$repo" update-ref -d "refs/heads/$br" "$oid" >/dev/null 2>&1; then
        WT_RESULT="worktree removed but refs/heads/$br could not be deleted (it moved, or git refused) — the reaper's next pass reports it"
        return 2
    fi
    wt_git -C "$repo" config --remove-section "branch.$br" >/dev/null 2>&1 || true
    WT_RESULT="reaped $path and refs/heads/$br ($label produced no commits)"
    return 0
}
