#!/usr/bin/env bash
# lane-container-reap.test.sh — hermetic self-check for lane-container-reap.sh (#2868).
#
# WHY THIS SUITE EXISTS. The reaper DELETES containers, so a green suite that only proves "it runs"
# is worthless. Each leg below pins one deletion gate, in BOTH directions where it can — so a gate
# reverted (deleted) REDDENS the leg that needs it:
#
#   AGE          a container younger than MIN_AGE is KEPT (too-recent), however orphaned it looks;
#                the SAME container past MIN_AGE is reaped — so dropping the age arm breaks both.
#   PROCESS      a foreign process whose argv names the container (or its PR token) KEEPS it
#                (live-process); a name held ONLY by the reaper's own row is EXCLUDED (self-exclusion
#                — a witness that reads its own reader would report every container as live).
#   CLAIM        a live claim ref in the snapshot KEEPS the PR container (claim-live); an absent
#                ref reaps it.
#   WORKTREE     a `fdb-lane-<slug>` whose slug is listed in git worktree KEEPS it (worktree-live);
#                an absent slug reaps it.
#   PROTECTED    the shared instances are never candidates, whatever their age.
#   OUTSIDE      a name outside the managed patterns is not a row at all.
#   FAIL-CLOSED  an unreadable ps / docker aborts the WHOLE pass (exit 3), never "kept".
#
# Hermetic by construction: stub `docker`/`ps`/`git`/`date`/`timeout` shims on a fake PATH, a fake
# claim snapshot and worktree list, a pinned clock. No real container is ever removed.
#
# Run: bash scripts/orchestrator-harness/lane-container-reap.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAPER="$HERE/lane-container-reap.sh"
PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  ✅ %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  ❌ %s\n' "$1"; }
eq()   { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got: $1, want: $2)"; fi; }
has()  { case "$1" in *"$2"*) ok "$3" ;; *) bad "$3 (missing: $2)"; esac; }
hasnt(){ case "$1" in *"$2"*) bad "$3 (unexpected: $2)" ;; *) ok "$3" ;; esac; }

REAL_SHA1="$(command -v sha1sum || echo sha1sum)"
T="$(mktemp -d "${TMPDIR:-/tmp}/lane-container-reap-test.XXXXXX")"
cleanup() { rm -rf "$T"; }
trap cleanup EXIT
mkdir -p "$T/bin" "$T/state"

NOW=1790000000                      # pinned clock; the suite never reads the real one
MIN_AGE=14400
REPO="/repo"
SNAP="$T/state/claims-snapshot"
RM_LOG="$T/rm.log"
export NOW MIN_AGE REPO SNAP RM_LOG

# two distinct Created timestamps: OLD (past MIN_AGE) and NEW (inside MIN_AGE)
RFC_OLD="2026-09-14T10:00:00Z"; EPOCH_OLD=$(( NOW - 86400 ))
RFC_NEW="2026-09-20T10:00:00Z"; EPOCH_NEW=$(( NOW - 60 ))
export RFC_OLD EPOCH_OLD RFC_NEW EPOCH_NEW

# ── the shims ─────────────────────────────────────────────────────────────────────────────────────
# `timeout` is a passthrough that `exec`s the command, so the `ps` stub's $PPID IS the reaper's own
# pid — which is what lets the self-exclusion leg place a row on the reaper itself.
cat > "$T/bin/timeout" <<'SH'
#!/bin/sh
shift
exec "$@"
SH

# `date` answers two shapes: `+%s` (now) and `-u -d <rfc3339> +%s` (a container's Created epoch).
cat > "$T/bin/date" <<'SH'
#!/bin/sh
case " $* " in
  *" -d "*)
    # the rfc3339 is the 3rd arg (after -u -d); map it back to an epoch
    for a in "$@"; do case "$a" in -u|-d|+%s) ;; *) rfc="$a" ;; esac; done
    if [ "$rfc" = "$RFC_NEW" ]; then printf '%s\n' "$EPOCH_NEW"; else printf '%s\n' "$EPOCH_OLD"; fi
    ;;
  *) printf '%s\n' "$NOW" ;;
esac
SH

# `docker` answers: ps -a (2 columns: name state), inspect (one Created per name), rm -f (recorded).
cat > "$T/bin/docker" <<'SH'
#!/bin/sh
case " $* " in
  *" ps -a "*)
    awk -F'\t' '{print $1 "\t" $2}' "$DOCKER_LIST"
    ;;
  *" inspect "*)
    name=""
    for a in "$@"; do case "$a" in -*) ;; *) name="$a" ;; esac; done
    if [ -n "${NEW_NAMES:-}" ] && grep -Fxq "$name" "$NEW_NAMES" 2>/dev/null; then
        printf '%s\n' "$RFC_NEW"
    else
        printf '%s\n' "$RFC_OLD"
    fi
    ;;
  *" rm -f "*)
    name=""
    for a in "$@"; do case "$a" in -f|rm) ;; *) name="$a" ;; esac; done
    printf '%s\n' "$name" >> "$RM_LOG"
    exit 0
    ;;
esac
exit 0
SH

# `ps` emits the fixture table (space-separated pid ppid args), plus the reaper's own row at $PPID.
cat > "$T/bin/ps" <<'SH'
#!/bin/sh
printf '%s %s %s\n' "$PPID" "1" "/bin/bash lane-container-reap.sh"
printf '%s %s %s\n' "1" "0" "/sbin/init"
cat "$PS_FIXTURE"
SH

# `git` answers only `worktree list --porcelain`.
cat > "$T/bin/git" <<'SH'
#!/bin/sh
case " $* " in
  *" worktree list "*)
    cat "$WORKTREE_LIST"
    ;;
esac
exit 0
SH
chmod +x "$T/bin"/*

# ── helpers ──────────────────────────────────────────────────────────────────────────────────────
slug_for() { printf '%s' "$1" | "$REAL_SHA1" | cut -c1-10; }

# run_reaper <env…> — one pass with the stub PATH and seams.
run_reaper() {
    (
        PATH="$T/bin:$PATH"
        export LANE_CONTAINER_DOCKER_BIN="$T/bin/docker"
        export LANE_CONTAINER_PS_BIN="$T/bin/ps"
        export LANE_CONTAINER_GIT_BIN="$T/bin/git"
        export LANE_CONTAINER_SHA1_BIN="$REAL_SHA1"
        export LANE_CONTAINER_DATE_BIN="$T/bin/date"
        export LANE_CONTAINER_TIMEOUT_BIN="$T/bin/timeout"
        export LANE_CONTAINER_REPO="$REPO"
        export LANE_CONTAINER_CLAIM_SNAPSHOT="$SNAP"
        export LANE_CONTAINER_MIN_AGE="$MIN_AGE"
        export LANE_CONTAINER_NOW="$NOW"
        export LANE_CONTAINER_LOG=""
        bash "$REAPER" "$@"
    )
}

SLUG_OLD="$(slug_for "/repo/.worktrees/fix-8888")"
SLUG_LIVE="$(slug_for "/repo/.worktrees/fix-7777")"
SLUG_PROC="$(slug_for "/repo/.worktrees/fix-6666")"

: > "$SNAP"
printf 'refs/claims/9665-abc123def456\tbox1:123\t%s\n' "$(( NOW + 3600 ))" > "$SNAP"
printf 'refs/claims/pr-9666\tbox1:123\t%s\n' "$(( NOW + 3600 ))" >> "$SNAP"
: > "$RM_LOG"

# DOCKER_LIST: name  state (2 columns; Created comes from `docker inspect`, not here)
cat > "$T/docker.list" <<EOF
cap9664-pg	running
fdb-lane-$SLUG_OLD	running
fdb-lane-$SLUG_LIVE	running
fix9665-pg	running
pr9666pg	running
fix9667-pg	running
falkordb	running
randombox	running
new9668-pg	running
EOF
export DOCKER_LIST="$T/docker.list"
printf 'new9668-pg\n' > "$T/new.names"
export NEW_NAMES="$T/new.names"

# PS_FIXTURE: live processes that name some containers (space-separated pid ppid args).
cat > "$T/ps.fixture" <<EOF
55555 1 /bin/bash -c docker exec fix9667-pg psql
66666 1 /bin/bash -c docker run --name fdb-lane-$SLUG_PROC redis-server
EOF
export PS_FIXTURE="$T/ps.fixture"

# WORKTREE_LIST: the live slug is listed; the old slug is gone.
cat > "$T/worktree.list" <<EOF
worktree /repo
worktree /repo/.worktrees/fix-7777
EOF
export WORKTREE_LIST="$T/worktree.list"

echo " A. a container past MIN_AGE with no process and no claim is WOULD-REMOVE"
out="$(run_reaper --dry-run)"
has "$out" "WOULD-REMOVE cap9664-pg" "old orphaned PR container is reaped"
has "$out" "WOULD-REMOVE fdb-lane-$SLUG_OLD" "old fdb-lane container whose worktree is gone is reaped"

echo " B. AGE: a container younger than MIN_AGE is KEPT too-recent (revert the age arm ⇒ it is reaped)"
out="$(run_reaper --dry-run)"
has "$out" "KEEP new9668-pg — too-recent" "young container is never a candidate"
hasnt "$out" "WOULD-REMOVE new9668-pg" "young container is not reaped"

echo " C. PROCESS: a foreign process naming the container KEEPS it live-process (revert ⇒ reaped)"
printf 'fdb-lane-%s\trunning\n' "$SLUG_PROC" >> "$T/docker.list"
out="$(run_reaper --dry-run)"
has "$out" "KEEP fix9667-pg — live-process" "a live argv witness refuses"
has "$out" "KEEP fdb-lane-$SLUG_PROC — live-process" "a live argv witness refuses a fdb-lane container too"
hasnt "$out" "WOULD-REMOVE fix9667-pg" "never reaped under a live witness"

echo " D. CLAIM: a live claim ref KEEPS the PR container claim-live (revert ⇒ reaped)"
out="$(run_reaper --dry-run)"
has "$out" "KEEP fix9665-pg — claim-live" "refs/claims/<pr>-* refuses"
has "$out" "KEEP pr9666pg — claim-live" "refs/claims/pr-<pr> refuses"

echo " E. WORKTREE: a listed slug KEEPS the fdb-lane container worktree-live (revert ⇒ reaped)"
out="$(run_reaper --dry-run)"
has "$out" "KEEP fdb-lane-$SLUG_LIVE — worktree-live" "a live worktree refuses"

echo " F. PROTECTED: the shared instance is never a candidate (revert ⇒ reaped)"
out="$(run_reaper --dry-run)"
has "$out" "KEEP falkordb — protected-shared" "shared falkordb is protected"
hasnt "$out" "WOULD-REMOVE falkordb" "shared falkordb is never reaped"

echo " G. OUTSIDE: a name outside the managed patterns is not a row at all"
out="$(run_reaper --dry-run)"
hasnt "$out" "randombox" "an unmanaged name is never touched"

echo " H. SELF-EXCLUSION: a name held by the REAPER'S OWN row is not a live witness (revert ⇒ live-process)"
# the reaper's own row (ps stub's $PPID) carries the container name; it must be excluded.
cat > "$T/bin/ps" <<'SH'
#!/bin/sh
printf '%s %s %s\n' "$PPID" "1" "/bin/bash lane-container-reap.sh docker run --name self9999-pg"
printf '%s %s %s\n' "1" "0" "/sbin/init"
cat "$PS_FIXTURE"
SH
chmod +x "$T/bin/ps"
: > "$T/ps.fixture"
printf 'self9999-pg\trunning\n' > "$T/docker.list"
: > "$T/new.names"
out="$(run_reaper --dry-run)"
has "$out" "WOULD-REMOVE self9999-pg" "the reaper's own row does not read as a live lane"

echo " I. FAIL-CLOSED: an unreadable ps aborts the whole pass (exit 3), never 'kept'"
cat > "$T/bin/ps" <<'SH'
#!/bin/sh
exit 1
SH
chmod +x "$T/bin/ps"
out="$(run_reaper --dry-run)"; rc=$?
eq "$rc" "3" "unreadable ps exits 3"
has "$out" "CANNOT-VERIFY" "the abort is named"
hasnt "$out" "WOULD-REMOVE" "nothing is reaped on a blind pass"

echo " J. --apply actually removes the candidates (docker rm -f is recorded)"
cat > "$T/bin/ps" <<'SH'
#!/bin/sh
printf '%s %s %s\n' "$PPID" "1" "/bin/bash lane-container-reap.sh"
printf '%s %s %s\n' "1" "0" "/sbin/init"
cat "$PS_FIXTURE"
SH
chmod +x "$T/bin/ps"
: > "$T/ps.fixture"
printf 'cap9664-pg\trunning\n' > "$T/docker.list"
: > "$RM_LOG"
out="$(run_reaper --apply)"
has "$out" "REMOVED cap9664-pg" "apply removes the proven-gone container"
eq "$(cat "$RM_LOG")" "cap9664-pg" "docker rm -f was the exact removal"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ] || exit 1
exit 0
