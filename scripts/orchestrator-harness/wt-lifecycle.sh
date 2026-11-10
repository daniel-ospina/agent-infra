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

# ── disk admission: the ONE predicate, asked BEFORE a worktree is created (agent-infra#3395) ────
# THE DEFECT THIS EXISTS FOR (measured, cell-3, 98% used / 3.5 GB free):
#   dispatch -> fatal: cannot create directory at 'tools/ts': No space left on device
# The gate that should have refused existed and was correct — it just ran INSIDE `run_agent`, one
# step AFTER this file had already called `git worktree add`. So a full volume presented as a dead
# lane instead of a named refusal, and the dispatcher that produced it (an ad-hoc pusher) printed a
# `df` reading and asserted nothing, because nothing existed for it to call.
#
# ⛔ NOT A SECOND PREDICATE. `disk_admit` is spawn-gate.sh's, and it reads through the same
# `disk_free_mb` / `disk_readable` / `disk_worktree_terms` / `disk_worktree_need` the live arm's
# `disk_lane_costs` / `disk_lane_need` are built on; this file only decides WHEN to ask it (before the
# write) and how to surface the answer (WT_RESULT + rc 4). ⚠️ The two seams feed the same `disk_lane_need`
# with different TERMS: the live arm CLASSIFIES the checkout and charges the marginal `tree` while the
# shared cache holds, and this one charges `self` — the stated worst case — plus the cell reserve,
# because at this point the install step the brief will ask for is not known yet (a `tree` the operator
# states for the cell is honoured on both sides, which is what keeps the bounds identical, review
# round 5 P2). Same functions, same bound, different — stated — term.
#
# ⛔ THE SOURCE IS LAZY, AND THAT IS MEASURED, NOT STYLISTIC (#1702). spawn-gate.sh derives
# `_NCPU`/`MAX_LOAD` at SOURCE time from `sysctl`/`nproc`/`getconf`. This file is sourced EARLY by
# every caller (dispatch-merge.sh, fix-one.sh, adopt-fix.sh, lane.sh) — before some of them finish
# setting PATH — so sourcing the gate here would pin `_NCPU=4`/`MAX_LOAD=40` on a box that has not
# yet exported the PATH those probes need, and the LOAD gate would then refuse every spawn on a
# busy cell. At the call site, PATH is whatever the dispatch runs with, and the probe is where the
# dispatch is.
#
# ⛔ AND A MISSING GATE IS A REFUSAL, NEVER A SKIP. A `$O` seeded file-by-file can carry this file
# without spawn-gate.sh; the unverifiable direction must be the safe one (the #2033 skew rule: a
# caller that cannot complete the check must not create anything). WT_RESULT carries the reason, so
# the operator sees a named UNKNOWN rather than a worktree that appeared anyway.
WTL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || WTL_DIR=""

# wt_disk_admit <repo-checkout> <worktree-path> -> 0 ADMITTED · 1 REFUSED (WT_RESULT says which arm)
# The checkout is accepted for its SIGNATURE (this is the seam every creation path shares) even though
# the seam's bound does not vary by checkout: see `disk_admit`'s note and README §7.2i — the bound is
# the lane's worst case, stated once, rather than a per-repo guess that the cache can invalidate.
wt_disk_admit() {
    local repo="$1" path="$2" rc=0
    WT_RESULT=""
    if ! command -v disk_admit >/dev/null 2>&1; then
        if [ -n "$WTL_DIR" ] && [ -f "$WTL_DIR/spawn-gate.sh" ]; then
            # shellcheck source=/dev/null
            . "$WTL_DIR/spawn-gate.sh" || :
        fi
    fi
    if ! command -v disk_admit >/dev/null 2>&1; then
        # ⛔ SANITISE THE HOSTNAME FALLBACK TOO (review cycle 10, P2 — MEASURED). `disk_box_id`
        # REPLACES an illegal box id with UNIDENTIFIED (`spawn-gate.sh`), but this arm cannot call it —
        # by definition `spawn-gate.sh` is the file that is MISSING or TOO OLD to carry the predicate —
        # so it used a bare `hostname -s`
        # and emitted a nodename containing a space or a comma verbatim, splitting `box=` into two
        # tokens in a line whose contract says that cannot happen, and stashing it in `WT_RESULT`,
        # which all three callers quote into their own logs. Same rule, applied inline: an id with a
        # character outside the legal set is REPLACED, never printed raw, and never merely defaulted.
        _wtl_box="$(hostname -s 2>/dev/null || printf '')"
        case "$_wtl_box" in ''|*[!A-Za-z0-9._:-]*) _wtl_box="UNIDENTIFIED" ;; esac
        # ⛔ NAME BOTH CAUSES (review, P2 — MEASURED). This arm is reached whenever `disk_admit` is not
        # callable, which is NOT the same state as "the file is absent": a `spawn-gate.sh` that PREDATES
        # #3395 defines `disk_free_mb` and still has no `disk_admit`, so a `[ -f ]` probe says the file is
        # there. Saying "is missing" sent the operator to a check a stale-but-present file PASSES, i.e. the
        # #2721 wrong-cause class this seam exists to remove, one file over. A depth-1 `cp` that drops a
        # file and discards its rc is a documented real mechanism (README §7.2e, cloud-cell-quiesce.sh).
        WT_RESULT="REFUSED-UNKNOWN disk-admit(free=?, need=?, box=$_wtl_box): ${WTL_DIR:-<unresolved>}/spawn-gate.sh is missing OR PREDATES the disk predicate (it does not define disk_admit), so the ONE disk predicate cannot be loaded and this worktree's headroom CANNOT be verified — refusing to create $path on an unverifiable volume. Nothing was created (fail-closed; a box whose state dir is missing the disk gate, or carries a copy too old to define it, cannot be trusted to have room)"
        wt_log provision "$WT_RESULT"
        return 1
    fi
    disk_admit "$path" "worktree $(basename "$path")" || rc=$?
    if [ "$rc" != 0 ]; then
        # `disk_admit` already printed its named line; WT_RESULT carries the same text so the CALLER's
        # log (a different file) can quote it without the reader having to join two logs.
        WT_RESULT="${DISK_ADMIT_LINE:-}"
        # ⛔ AN UN-NAMED REFUSAL IS `REFUSED-UNKNOWN`, NOT `REFUSED-DISK` (review round 6, P3 —
        # MEASURED). ALL THREE callers choose their remedy from THIS token (`fix-one.sh`,
        # `adopt-fix.sh` and `dispatch-merge.sh` match `*REFUSED-UNKNOWN*`, everything else gets
        # "reclaim space"), so labelling the one branch that exists BECAUSE the measurement is
        # unavailable as a DISK refusal sent the operator to reclaim space for a probe failure or a
        # version skew — the #2721 wrong-cause class, arriving through the fallback this time.
        # ⛔ THE COUNT IN THIS COMMENT IS LOAD-BEARING (review round 8, P2 — MEASURED). It said "Both
        # callers", so when the remedy was made verdict-selected it was fixed in the two files the
        # comment named and `dispatch-merge.sh` — a real `wt_provision` caller, listed as one in this
        # PR's own description — kept hardcoding "reclaim space" for a version skew. A comment that
        # states a POPULATION must name it exhaustively or derive it.
        # ⛔ AND THE FIRST VERSION OF THIS NOTE POINTED AT THE WRONG GUARD (review cycle 9, P2 —
        # MEASURED). It said `disk-admission.test.sh`'s "arm I" derives this population. Arm I is the
        # `DISK_LANE_*_MB` neutralisation census: it reads no caller and no remedy selector. What
        # actually guards this, and what to keep in step, are three surfaces: arm H's `arm_of` token
        # census (`AGENT_DISK_REFUSED` / `exit 77` / the arm terminator), the DERIVED
        # `arm_selects_remedy` census over `census_pop`'s output that reds on any caller whose rc-4
        # arm does not mention `REFUSED-UNKNOWN`, and the two behaviour-driven selector blocks plus
        # H3 that execute the shipped selector with `$WT_RESULT` injected. A pointer to a guard that
        # does not exist is worse than none: it is what stops the next reviewer looking.
        [ -n "$WT_RESULT" ] || WT_RESULT="REFUSED-UNKNOWN(free=?, need=?, box=$(disk_box_id 2>/dev/null || printf 'UNIDENTIFIED')): disk_admit refused without naming its numbers — a gate that refuses without stating what it measured is indistinguishable from a bug, so the caller is told the measurement is MISSING (and is NOT told to reclaim space: an unmeasured volume is not a full one)"
        wt_log provision "$WT_RESULT"
        return 1
    fi
    return 0
}

# ── provisioning ────────────────────────────────────────────────────────────────────────────────
# wt_provision <repo> <worktree-path> <branch> [base]
#   0 = a USABLE worktree exists at <path> on <branch>           (WT_RESULT says which way)
#   1 = nothing was created and nothing was left behind          (WT_RESULT says why)
#   2 = a pre-existing state this function refuses to touch      (nothing changed)
#   3 = ROLLBACK FAILED — residue remains, and the caller must surface it (WT_RESULT names it)
#   4 = REFUSED-DISK — the volume cannot hold one lane, so nothing was ATTEMPTED: no `worktree add`,
#       no branch ref, no directory (WT_RESULT is the named refusal line, agent-infra#3395)
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

    # 3. DISK ADMISSION, BEFORE ANY CREATION (agent-infra#3395) ───────────────────────────────
    # This is the seam the measured failure went through. It sits after the reuse answers (which create
    # nothing) and BEFORE the first step that CREATES or CONSUMES space — the ghost-branch CAS delete
    # and the `worktree add` below:
    #
    #   git worktree add -> fatal: cannot create directory at 'tools/ts': No space left on device
    #
    # ⛔ THE `interrupted add` / `unusable worktree` ARMS ABOVE ALREADY MUTATED THE TREE, AND THE
    # REFUSAL TEXT MUST NOT PRETEND OTHERWISE (review round 1, P2). They call `wt_rollback`, which
    # unlocks, force-removes and prunes residue. That is the RIGHT order — a repair RELEASES space, so
    # running it before the admission can only help later lanes — but the line therefore says
    # "nothing was CREATED by this attempt" rather than "nothing was created": the reader of a refusal
    # must be able to trust it, and the earlier wording asserted more than this function can know.
    #
    # A dispatch that dies in the add costs a whole cycle and leaves nothing to attribute: the harness's
    # own disk gate lives inside `run_agent`, i.e. AFTER this function has already materialised the
    # checkout, so on a full volume it was never reached. The predicate is spawn-gate.sh's (one
    # implementation); what is new is only that it is asked BEFORE the write instead of after.
    # An admission that is not taken cannot be undone, so the refusal consumes nothing: no branch, no
    # directory, no claim held (callers release it on a non-zero rc).
    wt_disk_admit "$repo" "$path" || return 4

    # 3b. Branch present?
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
#   0 = a holder was found · 1 = no holder (both witnesses read) · 2 = a witness ran and could not be
#   evaluated (the argv probe failed, OR the cwd census produced nothing usable — unparsable, quoted,
#   or timed out) · 3 = no holder by argv, and the cwd witness is UNAVAILABLE on this host
# The caller must NOT read 3 as "nothing is here": it means the probe that would have caught a process
# sitting in the checkout invisibly — the #2744 shape — did not run. Both witnesses are silent before
# anything is removed:
#   argv  — a process whose command line names the checkout (a `bash -c "cd <wt> && …"`, a
#           `pytest <wt>/…`), and
#   cwd   — a process whose working directory is inside the checkout, read from the kernel's own
#           `/proc/<pid>/cwd` on Linux and from `lsof` where there is no /proc (see `wt_cwd_rows`).
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
# degraded-tolerant ONLY where NEITHER `/proc` NOR `lsof` exists — a combination no real box has, and
# it is reported as 3 rather than as a clean "no holder" so the caller can say the probe half-ran.
# Turning an unreadable witness into a permanent refusal would keep every worktree for ever (the
# deliberate choice recorded here); what was NOT deliberate, and is #2744, is that a box with `/proc`
# and no `lsof` — every slim Linux image, and the cells — used to land on that tolerance instead of
# reading the table it already had.
# Bounded: `lsof` over a loaded box is not free, and an unbounded probe on the exit path is the
# "reaper that hangs the fleet" failure this whole family of scripts exists to avoid.
wt_live_holders() {
    local path="$1" chain out tmp ignore pid line cwd rows_rc=0
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
    # ── witness 2: cwd ──────────────────────────────────────────────────────────────────────────
    # ⛔ IT IS NOT OPTIONAL ON LINUX, AND TREATING IT AS OPTIONAL IS THE #2744 DEFECT.
    # This arm used to be `lsof`-only, and an absent `lsof` RETURNED 1 — "no holder" — so on a box
    # without it the cwd witness did not degrade, it silently said "nobody is here". Measured on this
    # file, 2026-11-10, on the take-back path the dispatcher runs:
    #   ( cd "$WT" && exec sleep 45 ) &            # cwd IS the checkout, argv does NOT name it
    #   WT_LSOF=/nonexistent wt_reap_if_empty …    # a slim Linux cell, exactly
    #   -> rc=0  WT_RESULT=reaped … (probe produced no commits)     and the directory was GONE
    # while pid still read `sleep 45`. That is agent-infra#2744 verbatim: the same box, in the same
    # minute, had the REAPER classify the same path `preserve reason=live-cwd` — because the reaper
    # reads `/proc/<pid>/cwd` (`scripts/lib/live-paths.sh`, `live-ownership.sh::lo_cwd_rows`) and this
    # probe did not. The liveness predicate the defect needs was already in the repo; the dispatch
    # path simply did not apply it. `docs/ops/lane-venv-reaper-policy.md:55` states the contract this
    # line broke: "`live-cwd` | `lsof -a -d cwd` (or `/proc/*/cwd` where lsof is absent)".
    # `wt_cwd_rows` therefore reads the kernel's own table where it exists and lsof only where it does
    # not — the SAME two arms, in the SAME order, as `live-ownership.sh` in this directory.
    out="$tmpbase.cwd"
    wt_cwd_rows "$out" || rows_rc=$?
    if [ "$rows_rc" != 0 ]; then
        rm -f "$out" "$ignore"
        # ⛔ 3 IS FOR THE TOLERATED STATE, 2 IS FOR "WE COULD NOT TELL" — never the same code (#2744
        # review, measured). 3 means this box has NEITHER a /proc table nor lsof, the documented
        # degrade-and-disclose state the caller reaps through. 2 means a census RAN and its output
        # cannot be trusted, and the only safe reading of that is fail-closed: "we cannot say nobody
        # is here". Returning 3 for the second case is exactly the fail-open #2744 is about, one level
        # up — with `QUOTING_STYLE=c` in the environment every row was unparsable, this line called it
        # "unavailable", and the caller deleted a live lane's checkout.
        if [ "$rows_rc" = 1 ]; then
            return 3
        fi
        return 2
    fi
    # ⛔ THE PROBE LISTS ITSELF, AND THAT IS THE MEASUREMENT THAT MADE THIS GATE REFUSE EVERY REAP
    # (found while verifying #2033, 2026-10-18). `lsof -d cwd` includes the `lsof` process in its own
    # output, and this helper runs it with the CWD INHERITED FROM THE LANE — i.e. the worktree. So the
    # cwd witness found exactly one "holder": the probe, pid N, cwd-inside-the-worktree. By the time
    # anything looked, that pid was gone (measured: `ps -p N` empty for every reported holder), which
    # is the tell — a genuine holder does not evaporate in a millisecond. It is not in `$chain`
    # (ancestors only) and its command line is not one of ours, so neither existing rule could catch it.
    # The probe pid is therefore excluded EXPLICITLY, from the pid wt_run_bounded actually forked.
    local probe_pid="${WT_PROBE_PID:-}"
    while IFS="$(printf '\t')" read -r pid cwd; do
        [ -n "$pid" ] && [ -n "$cwd" ] || continue
        case "$cwd" in
            "$path"|"$path"/*) ;;
            *) continue ;;
        esac
        case "$chain" in *" $pid "*) continue ;; esac
        [ -n "$probe_pid" ] && [ "$pid" = "$probe_pid" ] && continue
        if grep -qxF -- "$pid" "$ignore" 2>/dev/null; then continue; fi
        printf '%s\tcwd-inside-the-worktree\n' "$pid"
        rm -f "$out" "$ignore"
        return 0
    done <"$out"
    rm -f "$out" "$ignore"
    return 1
}

# ── the cwd table: the kernel's own links on Linux, `lsof` where there is no /proc ─────────────
# wt_cwd_rows <outfile> -> writes "<pid>\t<cwd>" rows.
#   0 = a real census was written   ·   1 = NO witness is available on this host
#   2 = a witness RAN but produced nothing usable (unparsable, quoted/escaped, or timed out)
# ⛔ 1 AND 2 ARE DIFFERENT FACTS AND THE CALLER MUST NOT COLLAPSE THEM (measured fail-open, 2026-11-10).
# 1 is "this box has neither a /proc table nor lsof" — the tolerated state where the argv witness is
# all there is and the reap DISCLOSES it. 2 is "the probe did run and its output cannot be trusted",
# which must fail CLOSED. Returning 1 for 2 is how a live checkout got deleted: with
# `QUOTING_STYLE=c` in the ambient environment every row was unparsable, the census read as "no
# witness", and the reap proceeded — checkout GONE, holder pid still alive.
# ⛔ ONE PROBE FOR THE WHOLE TABLE, NEVER ONE PER PID. A per-pid `readlink` is ~50 ms x N (this box:
# 594 pids) and the caller is the lane's EXIT path — the "reaper that hangs the fleet" shape this
# family exists to avoid. So: ONE `ls` over the table on Linux, ONE `lsof` elsewhere, both bounded by
# the same watchdog the other witnesses use.
# ⛔ THE SEMANTICS ARE NOT INVENTED HERE. `/proc/<pid>/cwd` + ` (deleted)` is the parse
# `live-ownership.sh::lo_cwd_rows` and `scripts/lib/live-paths.sh` already ship, and it is pinned by
# `orchestrator-harness/claim-cwd.test.sh`. If the three ever disagree, those two are right: this one
# only asks, it never deletes. ` (deleted)` is STRIPPED because a process whose cwd was removed STILL
# names the path we are about to reuse, and matching the stripped form is the safe direction.
# ⛔ AN EMPTY TABLE IS NOT A CENSUS. `cmd | awk` reports AWK's status, so an absent or broken probe
# looks exactly like a successful scan that found nobody — the one reading that must never be
# invented. Every arm therefore CAPTURES FIRST and is judged on its own bytes.
# Seams (tests set them; production never needs them): WT_PROC_ROOT, WT_LS, WT_LSOF.
wt_cwd_rows() {
    local out="$1" raw="$1.raw" bad="$1.bad" proc="${WT_PROC_ROOT:-/proc}" rc=0 saw=0
    : >"$out" 2>/dev/null || return 2
    : >"$bad" 2>/dev/null || return 2
    # Linux, and anything else exposing the kernel's per-process links. `/proc/self/cwd` is a symlink
    # only where the link kind actually exists, so a bare `/proc` directory is not taken as evidence.
    if [ -L "$proc/self/cwd" ] && command -v "${WT_LS:-ls}" >/dev/null 2>&1; then
        saw=1
        # ⛔ ITS EXIT STATUS IS NOT THE VERDICT (measured 2026-11-10). `ls -l /proc/[0-9]*/cwd` exits 2
        # on any shared box — another uid's links cannot be read — WHILE LISTING EVERY ONE IT COULD.
        # Requiring rc=0 here threw that partial-but-real census away and fell through to "no witness",
        # i.e. the very fail-open this function exists to close, reintroduced one line lower. So:
        # CAPTURE FIRST, JUDGE THE BYTES. (A watchdog timeout yields no file at all, so it is empty.)
        # ⛔ FORCE THE QUOTING STYLE (measured 2026-11-10). `ls` quotes names according to the AMBIENT
        # `QUOTING_STYLE` environment variable, and BOTH useful styles destroyed this parse in the two
        # ways that a safety probe can fail: `c` wrapped the link name AND the target (`"/proc/N/cwd"
        # -> "/wt"`), so NO row was produced; `escape` produced a row whose target read `…/re\ po\ wt`,
        # which can never equal the checkout path, so the row silently matched nothing. Reproduced on
        # a fixture: rc=0 `WT_RESULT=reaped …`, the directory GONE, the holder pid still alive. The
        # command-line option overrides the environment variable, so the census stops depending on how
        # the caller's shell happens to be configured — an ambient env var must not be able to disarm
        # a gate (the `bypass by ambient env` class).
        wt_run_bounded "$WT_PROBE_SECONDS" "$raw" "${WT_LS:-ls}" -l --quoting-style=literal "$proc"/[0-9]*/cwd; rc=$?
        if [ "$rc" != 124 ] && [ ! -s "$raw" ]; then
            # An `ls` that does not know the option (busybox, BSD) produced NO bytes at all: retry
            # WITHOUT it rather than declaring the census unusable. Neither of those builds quotes
            # non-tty output, so the parse is sound there — and the judgement below is on the BYTES
            # either way, so a retry cannot turn a bad census good.
            wt_run_bounded "$WT_PROBE_SECONDS" "$raw" "${WT_LS:-ls}" -l "$proc"/[0-9]*/cwd; rc=$?
        fi
        if [ "$rc" = 124 ]; then
            # ⛔ A PROBE THAT NEVER FINISHED IS NOT "NO WITNESS ON THIS BOX". The watchdog DELETES the
            # partial table, so leaving this rc unchecked reads as "empty" → 1 → a reap licensed by a
            # probe that never completed (reproduced with a slow `ls`: rc 3 "unavailable", and the
            # checkout was deleted while its holder was alive).
            rm -f "$raw" "$out" "$bad"; return 2
        fi
        if [ -s "$raw" ]; then
            awk -v proc="$proc" -v bad="$bad" '
                {
                  # the link NAME is the first `<proc>/<pid>/cwd` on the line; the TARGET is
                  # everything after the first " -> ", so a target containing " -> " or a space
                  # is still read whole.
                  i = index($0, proc "/")
                  if (i == 0) next
                  rest = substr($0, i + length(proc) + 1)
                  pid = rest; sub(/\/cwd.*$/, "", pid)
                  if (pid !~ /^[0-9]+$/) next
                  j = index($0, " -> ")
                  if (j == 0) next          # an unreadable link (another uid) prints no target
                  t = substr($0, j + 4)
                  # `ls` echoes a failed readlink INLINE on some builds (`<name> -> <name>
                  # (readlink: Permission denied)`); that is not a cwd and must not become a row.
                  if (t ~ / \(readlink: /) next
                  # ⛔ A QUOTED OR ESCAPED TARGET IS NOT A PATH WE CAN COMPARE, AND IT MUST NOT BE
                  # SILENTLY DROPPED. A row that is PRESENT but can never equal $path is the quietest
                  # fail-open there is: no holder, no disclosure, and the reap proceeds. Mark the whole
                  # census UNUSABLE instead (the caller turns that into a fail-closed preserve) — this
                  # is the residue defence for an `ls` whose quoting cannot be switched off.
                  if (t ~ /^["\047]/ || t ~ /\\ /) { print $0 >> bad; next }
                  sub(/ \(deleted\)$/, "", t)
                  if (t ~ /^\//) printf "%s\t%s\n", pid, t
                }' "$raw" >>"$out" 2>/dev/null
        fi
        rm -f "$raw"
        [ -s "$bad" ] && { rm -f "$out" "$bad"; return 2; }
        [ -s "$out" ] && { rm -f "$bad"; return 0; }
        : >"$out" 2>/dev/null || return 2
    fi
    # macOS / a container with no /proc: `lsof -F` emits "<field><value>" lines — p<pid>, then n<path>.
    # Same rule: a non-empty table is the answer whatever lsof's status says about the rows it skipped.
    if command -v "${WT_LSOF:-lsof}" >/dev/null 2>&1; then
        saw=1
        wt_run_bounded "$WT_PROBE_SECONDS" "$raw" "${WT_LSOF:-lsof}" -nP -d cwd -Fpn; rc=$?
        if [ "$rc" = 124 ]; then rm -f "$raw" "$out" "$bad"; return 2; fi
        [ -s "$raw" ] && awk '/^p/ { p = substr($0, 2); next }
             /^n/ { t = substr($0, 2); if (p ~ /^[0-9]+$/ && t ~ /^\//) printf "%s\t%s\n", p, t }' \
            "$raw" >>"$out" 2>/dev/null
        rm -f "$raw"
    fi
    [ -s "$out" ] && { rm -f "$bad"; return 0; }
    rm -f "$out"
    # A witness was attempted and yielded nothing usable: fail CLOSED, never "unavailable".
    [ "$saw" = 1 ] && { rm -f "$bad"; return 2; }
    rm -f "$bad"
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
    local canon cwd_reg a oid holder holder_rc dirt verdict detail upstream cur_br head_sha survivors degraded
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
    degraded=""
    holder="$(wt_live_holders "$canon")" || holder_rc=$?
    if [ "$holder_rc" = 0 ]; then
        WT_RESULT="a live process still holds the checkout (pid ${holder%%$'\t'*}, ${holder#*$'\t'}) — kept"
        return 1
    fi
    if [ "$holder_rc" = 3 ]; then
        # Both witnesses are still applied — this only records that ONE of them did not run, so a
        # reap that proceeds says so instead of reporting a clean bill of health it did not earn.
        # ⛔ THIS TEXT IS NOW TRUE BY CONSTRUCTION: 3 is reachable ONLY when neither a /proc table nor
        # lsof exists (an unusable census is 2, fail-closed). The previous version printed these same
        # words on a box whose /proc worked and whose `ls` had just produced 573 rows, because the
        # unparsable case was mislabelled as "unavailable".
        degraded=" (⚠️ the cwd witness is UNAVAILABLE on this host — no /proc and no lsof — so the live-holder probe rested on argv alone; a process whose cwd is this checkout and whose command line does not name it would not have been seen, agent-infra#2744)"
    elif [ "$holder_rc" != 1 ]; then
        # rc 2: a witness ran and produced nothing usable. Fail-closed, and say WHICH probes could be
        # at fault — an operator reading a refused reap needs the arm, not a generic phrase.
        WT_RESULT="the live-holder probe could not be evaluated (an argv probe failed, or the cwd census produced nothing usable — unparsable, quoted, or timed out) — kept (fail-closed)$degraded"
        return 1
    fi

    dirt="$(wt_dirt "$path")"
    verdict="${dirt%%$'\t'*}"
    detail="${dirt#*$'\t'}"
    case "$verdict" in
        clean) ;;   # `detail` holds the disposable ROOT entries, used by the pre-delete below
        dirty)
            WT_RESULT="the tree is DIRTY ($detail) — the work is preserved for the reaper's backup-then-reap policy, not deleted here$degraded"
            return 1 ;;
        ignored)
            WT_RESULT="the tree holds ignored, non-regenerable data ($detail) — preserved (git worktree remove would delete it silently)$degraded"
            return 1 ;;
        *)
            WT_RESULT="the clean gate could not be evaluated ($detail) — preserved (fail-closed)$degraded"
            return 1 ;;
    esac

    oid="$(wt_branch_oid "$repo" "$br")"
    if [ -z "$oid" ]; then
        WT_RESULT="branch refs/heads/$br does not resolve — refusing to reap a checkout whose branch is already gone$degraded"
        return 2
    fi
    a="$(wt_ahead_count "$repo" "$base" "$oid")"
    if [ -z "$a" ]; then
        WT_RESULT="cannot count commits ahead of $base — preserved (fail-closed)$degraded"
        return 1
    fi
    if [ "$a" != "0" ]; then
        WT_RESULT="the branch is $a commit(s) ahead of $base — that work is kept$degraded"
        return 1
    fi
    # A pushed branch means a PR may exist (or be about to): the remote ref is the durable copy, so
    # the local one is not ours to delete while it is someone else's review anchor.
    if upstream="$(wt_git -C "$repo" rev-parse --verify -q "refs/remotes/origin/$br" 2>/dev/null)" \
        && [ -n "$upstream" ]; then
        WT_RESULT="origin/$br exists — the branch was pushed, so it may back an open PR; kept$degraded"
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
        WT_RESULT="git worktree remove refused $path — left in place for the reaper (run: bash scripts/pi-reap-worktrees.sh --repo '$repo')$degraded"
        return 2
    fi
    if ! wt_git -C "$repo" update-ref -d "refs/heads/$br" "$oid" >/dev/null 2>&1; then
        WT_RESULT="worktree removed but refs/heads/$br could not be deleted (it moved, or git refused) — the reaper's next pass reports it$degraded"
        return 2
    fi
    wt_git -C "$repo" config --remove-section "branch.$br" >/dev/null 2>&1 || true
    WT_RESULT="reaped $path and refs/heads/$br ($label produced no commits)$degraded"
    return 0
}
