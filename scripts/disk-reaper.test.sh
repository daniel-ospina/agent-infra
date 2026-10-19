#!/usr/bin/env bash
# disk-reaper.test.sh — self-check for scripts/disk-reaper.sh and its scheduling contract (#2032).
#
# Run: bash scripts/disk-reaper.test.sh
# Exits 0 when ALL assertions pass, 1 on any failure.
#
# ⛔ WHAT THIS SUITE EXISTS TO PROVE, and why its shape is what it is. disk-reaper.sh owns NO delete
# rule: it orchestrates three owners. A test that only shows "bytes went down" would prove nothing
# about the thing that can actually hurt — so every removal case is paired with a REFUSAL built from
# the SAME fixture, and the load-bearing one (T2) uses a REAL process cwd'd into a REAL linked
# worktree. A live holder must never be selected, and its `.venv` must survive the same pass that
# reaps a dead neighbour's.
#
# COVERAGE
#   T1 dry-run removes nothing, and prints every candidate WITH a byte count.
#   T2 a live-cwd worktree is never selected — and its .venv survives too (both classes).
#      The SAME fixture is then reaped once the holder is gone: the pair is the proof.
#   T3 a MERGED worktree is selected without waiting out the 7-day floor (the exemption), and the
#      branch ref survives.
#   T4 the size budget is honoured: the uv class ends under the configured cap, and status reports it.
#   T5 a missing delegate is FAIL-CLOSED, never a silent skip — and it is recorded as failed.
#   T6 the entry point deletes nothing itself (static pin: its only `rm -rf` is the lock).
#   T7 the pass record answers "did it succeed, and how much did it free" without a log.
#   T8 the schedule is installable, idempotent and ARMED.
#   T9 a pass that LOSES the lock does not release the live owner's lock.
#   T10 an --only list naming nothing is refused (never a healthy no-op / false PASS).
#   T11 a dry run records 0 bytes freed (it removed nothing). Guard, not a pre-change failure: in an
#       idle fixture the old code also recorded 0, because df happened not to move.
#   T12 the installer's --dry-run changes nothing, and a SET-but-missing $DISK_REAPER is refused.
#   T13 the bounded-execution resolver's ORDER is pinned: `timeout` -> `gtimeout` -> the internal
#       watchdog, proven with a PATH that contains only the case's own stub.
#   T14 a host with NEITHER binary still CLASSIFIES (candidates found, rc=5) and names the fallback;
#       the same pass with a stub `timeout` on PATH proves resolution prefers the binary (#2046).
#   T15 a missing library, or an unusable TB_TIMEOUT_BIN, is a REFUSAL AT STARTUP (exit 3, no
#       per-class line) — never a pass whose classes each report fail-closed and then complete.
#
# PRE-CHANGE BEHAVIOUR. Each assertion below fails before this change, for the reason the section
# names: there is no entry point at all, so `bash scripts/disk-reaper.test.sh` on the pre-change tree
# aborts at "REAPER missing" and every section is red. That was verified by running this suite
# against `origin/main` (see the PR body) — the suite is not vacuous by construction.
#
# Hermetic: every fixture is under $T, HOME is redirected, the delegates' state dirs are $T, and the
# only real tools are git/ps/lsof/tmux plus real processes. The private repo has NO GitHub remote, so
# the worktree owner's open-PR gate is not-applicable and this suite never calls gh.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAPER="$HERE/disk-reaper.sh"
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }
assert_eq()       { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got: $1, want: $2)"; fi; }
assert_contains() { if grep -qF -- "$2" <<<"$1"; then ok "$3"; else bad "$3 (missing: $2)"; fi; }
assert_absent()   { if grep -qF -- "$2" <<<"$1"; then bad "$3 (unexpected: $2)"; else ok "$3"; fi; }
assert_dir()      { if [ -d "$1" ]; then ok "$2"; else bad "$2 (missing dir: $1)"; fi; }
assert_nodir()    { if [ -d "$1" ]; then bad "$2 (still present: $1)"; else ok "$2"; fi; }
assert_file()     { if [ -f "$1" ]; then ok "$2"; else bad "$2 (missing file: $1)"; fi; }

[ -f "$REAPER" ] || { echo "FATAL: $REAPER missing — this suite tests the entry point, and there is none"; exit 1; }
# Templates are NOT farmed (only scripts are), so a farmed copy of the suite has no ../templates.
# Assert the precondition by its OWN name: without this, T8/T13 fail as "missing: REFUSING", which
# reads as a broken guard rather than a missing fixture.
REPO_ROOT="$(cd "$HERE/.." && pwd)"
[ -d "$REPO_ROOT/templates/systemd" ] || { echo "FATAL: $REPO_ROOT/templates/systemd missing — the suite renders units from it"; exit 1; }

T="$(mktemp -d "${TMPDIR:-/tmp}/disk-reaper-test.XXXXXX")"
T="$(cd "$T" && pwd -P)"
SLEEPERS=""
cleanup() {
    local p
    for p in $SLEEPERS; do kill "$p" 2>/dev/null; done
    rm -rf "$T"
}
trap cleanup EXIT

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
REAL_GIT="$(command -v git)"

# ── fixtures ────────────────────────────────────────────────────────────────────────────────────
mk_repo() { # mk_repo <name> -> a repo with one commit and NO GitHub remote
    local r="$T/$1"
    mkdir -p "$r"
    "$REAL_GIT" -C "$r" init -q -b main >/dev/null 2>&1 || "$REAL_GIT" -C "$r" init -q
    printf 'base\n' >"$r/f.txt"
    "$REAL_GIT" -C "$r" add f.txt
    "$REAL_GIT" -C "$r" commit -qm init
    printf '%s\n' "$r"
}

mk_wt() { # mk_wt <repo> <name> <branch> -> linked worktree path (as git records it)
    local r="$1" n="$2" b="$3"
    "$REAL_GIT" -C "$r" worktree add -q "$r/.worktrees/$n" -b "$b" >/dev/null 2>&1
    "$REAL_GIT" -C "$r" worktree list --porcelain | awk -v b="refs/heads/$b" '
        /^worktree / { p = substr($0, 10) }
        /^branch /   { if (substr($0, 8) == b) { print p; exit } }'
}

commit_in() { # commit_in <wt> <date> <label>
    local wt="$1" d="$2" n="$3"
    printf 'wip %s\n' "$n" >"$wt/f-$n.txt"
    "$REAL_GIT" -C "$wt" add "f-$n.txt"
    GIT_AUTHOR_DATE="$d" GIT_COMMITTER_DATE="$d" "$REAL_GIT" -C "$wt" commit -qm "wip $n"
}

mk_venv() { # mk_venv <worktree> <mb> — a real .venv-shaped tree with real bytes, and an OLD mtime
    local wt="$1" mb="${2:-8}"
    mkdir -p "$wt/.venv/bin" "$wt/.venv/lib/python3.11/site-packages"
    printf '#!/bin/sh\necho 3.11.9\n' >"$wt/.venv/bin/python"; chmod +x "$wt/.venv/bin/python"
    printf 'home = /usr/bin\n' >"$wt/.venv/pyvenv.cfg"
    dd if=/dev/zero of="$wt/.venv/lib/python3.11/site-packages/blob.so" bs=1M count="$mb" >/dev/null 2>&1
    # The venv GC has its own 30-minute floor; age the probe set into 2020 so the fixture is a
    # DEAD lane rather than a freshly-synced one (the floor is the venv owner's test subject).
    touch -t 202001010000 "$wt/.venv" "$wt/.venv/pyvenv.cfg" "$wt/.venv/bin" "$wt/.venv/lib" 2>/dev/null || true
}

OLD_DATE="2026-07-01T12:00:00+00:00"
RECENT_DATE="2026-09-13T12:00:00+00:00"

# ── runner ──────────────────────────────────────────────────────────────────────────────────────
# ONE rung: the pass runs with HOME redirected, its state under $T, the uv cache seam pointed at a
# fixture, and the owner state dirs under $T. Nothing here can read or write the real box's state.
ENVNAME=""
run_reaper() { # run_reaper <args...>
    HOME="$T/home" \
    DISK_REAPER_STATE_DIR="$T/$ENVNAME/state" \
    DISK_REAPER_LOG="$T/$ENVNAME/state/disk-reaper.log" \
    CACHE_REAP_MAX_MB="${CACHE_REAP_MAX_MB:-2048}" \
    CACHE_REAP_UV_DIR="${CACHE_REAP_UV_DIR:-$T/nocache-uv}" \
    CACHE_REAP_NPM_DIR="${CACHE_REAP_NPM_DIR:-$T/nocache-npm}" \
    CACHE_REAP_PIP_DIR="${CACHE_REAP_PIP_DIR:-$T/nocache-pip}" \
    CACHE_REAP_LOG="$T/$ENVNAME/state/pi-cache-reap.log" \
    CACHE_REAP_LOCK="$T/$ENVNAME/state/pi-cache-reap.lock" \
    REAP_WT_STATE_DIR="$T/$ENVNAME/state" \
    REAP_WT_LOG="$T/$ENVNAME/state/pi-reap-worktrees.log" \
    REAP_VENV_LOG="$T/$ENVNAME/state/reap-lane-venvs.log" \
    REAP_WT_BUDGET_SECONDS="${REAP_WT_BUDGET_SECONDS:-300}" \
    VENV_REAPER="${VENV_REAPER:-}" \
    WORKTREE_REAPER="${WORKTREE_REAPER:-}" \
    CACHE_REAPER="${CACHE_REAPER:-}" \
    bash "$REAPER" "$@"
}

echo "── disk-reaper.test.sh ──────────────────────────────────────────────"

# ── T1: dry-run removes nothing, and names every candidate with a byte count ────────────────────
ENVNAME=t1
REPO="$(mk_repo t1)"
WT="$(mk_wt "$REPO" dead feat/t1-dead)"      # unmerged, aged -> worktree candidate
mk_venv "$WT" 8                                # aged -> venv candidate
commit_in "$WT" "$OLD_DATE" dead
mkdir -p "$T/t1/cache-uv/entry-a" "$T/t1/cache-uv/entry-b"
dd if=/dev/zero of="$T/t1/cache-uv/entry-a/blob" bs=1M count=3 >/dev/null 2>&1
dd if=/dev/zero of="$T/t1/cache-uv/entry-b/blob" bs=1M count=3 >/dev/null 2>&1
CACHE_BEFORE="$(du -sm "$T/$ENVNAME/cache-uv" | awk '{print $1}')"
OUT="$(CACHE_REAP_MAX_MB=1 CACHE_REAP_UV_DIR="$T/$ENVNAME/cache-uv" run_reaper --dry-run --repo "$REPO" --min-age 0 2>&1)"; RC=$?
assert_eq "$RC" "5" "T1 dry-run with work found exits 5 (informative, not a failure)"
assert_dir "$WT" "T1 dry-run removed NOTHING (worktree still present)"
assert_dir "$WT/.venv" "T1 dry-run removed NOTHING (venv still present)"
assert_eq "$(du -sm "$T/$ENVNAME/cache-uv" | awk '{print $1}')" "$CACHE_BEFORE" "T1 dry-run left the cache untouched"
assert_contains "$OUT" "NOTHING was removed" "T1 the pass says so in words"
assert_contains "$OUT" "WOULD-REMOVE class=worktree" "T1 every worktree candidate is named"
assert_contains "$OUT" "WOULD-REMOVE class=venv" "T1 every venv candidate is named"
assert_contains "$OUT" "WOULD-PRUNE class=uv" "T1 the over-bound cache is named"
assert_contains "$OUT" "du estimate" "T1 the byte counts are labelled as the over-count they are"
assert_contains "$(cat "$T/$ENVNAME/state/disk-reaper.status")" "mode=dry-run" "T1 the pass record names the mode"
assert_contains "$(cat "$T/$ENVNAME/state/disk-reaper.status")" "ok=1" "T1 a dry run that did its job is ok"

# ── T2: a LIVE-CWD worktree is never selected — the safety property ─────────────────────────────
ENVNAME=t2
REPO="$(mk_repo t2)"
WT_LIVE="$(mk_wt "$REPO" live feat/t2-live)"
mk_venv "$WT_LIVE" 8
commit_in "$WT_LIVE" "$OLD_DATE" live
# A REAL process whose cwd is inside the worktree: the witness an argv scan would miss.
( cd "$WT_LIVE" && exec sleep 300 ) &
LIVE_PID=$!
SLEEPERS="$SLEEPERS $LIVE_PID"
sleep 1
OUT="$(run_reaper --apply --repo "$REPO" --min-age 0 --aged-days 0 2>&1)"; RC=$?
assert_eq "$RC" "0" "T2 an apply pass with only a live candidate is not a failure"
[ "$RC" = 0 ] || printf '%s\n' "$OUT" | grep -E 'class=|FAIL|warn' | sed 's/^/      /' 
assert_dir "$WT_LIVE" "T2 the worktree of a LIVE holder is never removed"
assert_dir "$WT_LIVE/.venv" "T2 its .venv survives the same pass (both classes agree)"
assert_contains "$OUT" "reason=live-cwd" "T2 the worktree owner names the deciding witness"
assert_contains "$OUT" "KEEP live-cwd" "T2 the venv owner names it too"
# The distinguishing half: the SAME fixture reaps once the holder is gone.
kill "$LIVE_PID" 2>/dev/null; wait "$LIVE_PID" 2>/dev/null
sleep 1
OUT="$(run_reaper --apply --repo "$REPO" --min-age 0 --aged-days 0 2>&1)"; RC=$?
assert_eq "$RC" "0" "T2 the follow-up pass exits 0"
assert_nodir "$WT_LIVE" "T2 with no holder the same worktree IS reclaimed"
assert_absent "$OUT" "reason=live-cwd" "T2 and it is no longer reported as live"

# ── T3: a MERGED worktree is selected without waiting out the 7-day floor ───────────────────────
ENVNAME=t3
REPO="$(mk_repo t3)"
WT_M="$(mk_wt "$REPO" merged feat/t3-merged)"
commit_in "$WT_M" "$RECENT_DATE" merged
"$REAL_GIT" -C "$REPO" merge -q --no-edit feat/t3-merged            # the PR is MERGED
OUT="$(run_reaper --dry-run --repo "$REPO" --aged-days 7 2>&1)"
assert_contains "$OUT" "refs=merged" "T3 the fixture really is merged (the assertion is not vacuous)"
assert_contains "$OUT" "remove   $WT_M" "T3 a MERGED, clean, holder-free checkout is SELECTED"
OUT="$(run_reaper --apply --repo "$REPO" --aged-days 7 --only worktree 2>&1)"; RC=$?
assert_eq "$RC" "0" "T3 the apply pass exits 0"
assert_nodir "$WT_M" "T3 --apply removed the merged checkout (pass said: $(printf '%s' "$OUT" | grep -E 'remove |REMOVED|FAILED' | tr '\n' ' '))"
assert_eq "$("$REAL_GIT" -C "$REPO" rev-parse --verify -q feat/t3-merged | wc -l | tr -d ' ')" "1" \
    "T3 the branch ref survives (a checkout is removed, never a branch)"

# ── T4: the size budget is honoured ─────────────────────────────────────────────────────────────
ENVNAME=t4
REPO="$(mk_repo t4)"
mkdir -p "$T/t4/cache-uv/e1" "$T/t4/cache-uv/e2" "$T/t4/cache-uv/e3"
dd if=/dev/zero of="$T/t4/cache-uv/e1/blob" bs=1M count=3 >/dev/null 2>&1
dd if=/dev/zero of="$T/t4/cache-uv/e2/blob" bs=1M count=3 >/dev/null 2>&1
dd if=/dev/zero of="$T/t4/cache-uv/e3/blob" bs=1M count=3 >/dev/null 2>&1
OUT="$(CACHE_REAP_MAX_MB=2 CACHE_REAP_UV_DIR="$T/t4/cache-uv" run_reaper --apply --only uv 2>&1)"; RC=$?
assert_eq "$RC" "0" "T4 an apply pass that bounded the cache exits 0"
assert_contains "$OUT" "max=2MB per cache" "T4 the configured cap is what the owner enforced"
AFTER_MB="$(du -sm "$T/t4/cache-uv" | awk '{print $1}')"
if [ "$AFTER_MB" -le 2 ]; then ok "T4 the cache ends UNDER the 2MB cap (${AFTER_MB}MB)"
else bad "T4 the cache is still over the cap (${AFTER_MB}MB > 2MB)"; fi
assert_contains "$OUT" "class=uv rc=0" "T4 the class reports success"
assert_contains "$(cat "$T/$ENVNAME/state/disk-reaper.status")" "ok=1" "T4 the pass record says ok"

# ── T5: a missing delegate is FAIL-CLOSED, never a silent skip ──────────────────────────────────
ENVNAME=t5
REPO="$(mk_repo t5)"
OUT="$(VENV_REAPER=/nonexistent/reap-lane-venvs.sh run_reaper --dry-run --repo "$REPO" --only venv 2>&1)"; RC=$?
assert_eq "$RC" "3" "T5 a missing venv delegate exits 3 (a skip is never a pass)"
assert_contains "$OUT" "FAIL-CLOSED" "T5 the class says so, loud enough to grep"
assert_contains "$(cat "$T/t5/state/disk-reaper.status")" "ok=0" "T5 and the pass record does NOT read healthy"
ST="$(HOME="$T/home" DISK_REAPER_STATE_DIR="$T/$ENVNAME/state" bash "$REAPER" --print-status 2>&1)"; SRC=$?
assert_eq "$SRC" "3" "T5 --print-status exits 3 for a failed pass"
assert_contains "$ST" "status=failed" "T5 --print-status names it failed"

# ── T6: the entry point owns NO delete rule (static pin) ────────────────────────────────────────
# A fourth copy of the policy is the failure mode this consolidation exists to prevent, so the
# absence of deletion is asserted, not assumed.
RMS="$(grep -nE '(^|[^a-zA-Z_])rm -rf' "$REAPER" || true)"
NOT_LOCK="$(printf '%s\n' "$RMS" | grep -v 'LOCK_DIR' | grep -v '^$' || true)"
assert_absent "$NOT_LOCK" 'rm -rf' "T6 the entry point never recursively deletes a PATH (only its own lock)"
assert_contains "$RMS" 'LOCK_DIR' "T6 and the lock it does remove is named"

# ── T7: the pass record answers "did it succeed, and how much did it free" ──────────────────────
ENVNAME=t7
REPO="$(mk_repo t7)"
mkdir -p "$T/t7/cache-uv/e1"; dd if=/dev/zero of="$T/t7/cache-uv/e1/blob" bs=1M count=4 >/dev/null 2>&1
CACHE_REAP_MAX_MB=1 CACHE_REAP_UV_DIR="$T/t7/cache-uv" run_reaper --apply --only uv >/dev/null 2>&1
ST="$(HOME="$T/home" DISK_REAPER_STATE_DIR="$T/$ENVNAME/state" bash "$REAPER" --print-status 2>&1)"; SRC=$?
assert_eq "$SRC" "0" "T7 --print-status exits 0 for a good pass"
assert_contains "$ST" "status=ok" "T7 the status is ok"
assert_contains "$ST" "mode=apply" "T7 the mode is recorded"
assert_contains "$ST" "freed_mb_uv=" "T7 the bytes freed per class are recorded"
assert_contains "$ST" "candidates_worktree=0" "T7 classes that did not run are recorded, not implied"
assert_contains "$ST" "verdict_uv=ok" "T7 the per-class verdict is readable without the log"

# ── T8: the SCHEDULE is installable, idempotent, and armed ──────────────────────────────────────
# A reaper nobody runs is the defect. The unit is rendered from machine state, so "it installs" is
# asserted on the RENDERED FILE (armed, with the repos), not on the template's existence; the second
# install must be a no-op (a bring-up runs this on every check).
INST="$HERE/install-disk-reaper-timer.sh"
ENVNAME=t8
REPO="$(mk_repo t8repo)"
mkdir -p "$T/t8/units" "$T/t8/bin" "$T/t8/home"
cat >"$T/t8/bin/systemctl" <<'SC'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${SYSTEMCTL_CALLS:-/dev/null}"
case "$*" in
  *is-enabled*) echo enabled ;;
  *is-active*) echo "${SYSTEMCTL_ACTIVE:-active}" ;;
  *list-timers*) echo "Mon 2026-10-19 00:30:00 UTC 1h left Sun 2026-10-18 23:30:00 UTC 3h ago eldato-disk-reaper.timer eldato-disk-reaper.service" ;;
  *show*) echo 0 ;;
esac
exit 0
SC
chmod +x "$T/t8/bin/systemctl"
inst() { # inst <args...>
    HOME="$T/t8/home" DISK_REAPER="$REAPER" DISK_REAPER_REPOS="$REPO" \
    DISK_REAPER_STATE_DIR="$T/t8/home/.pi/agent/state" \
    SYSTEMD_UNIT_DIR="$T/t8/units" SYSTEMCTL="$T/t8/bin/systemctl" SYSTEMCTL_CALLS="$T/t8/calls.log" \
    bash "$INST" "$@"
}
OUT="$(inst --install 2>&1)"; RC=$?
assert_eq "$RC" "0" "T8 the installer succeeds against the test's own unit dir"
assert_file "$T/t8/units/eldato-disk-reaper.timer" "T8 the timer unit is installed"
assert_file "$T/t8/units/eldato-disk-reaper.service" "T8 the service unit is installed"
assert_contains "$(cat "$T/t8/units/eldato-disk-reaper.service")" "--apply" \
    "T8 the scheduled pass is ARMED (this feature was instructed to run unattended)"
assert_contains "$(cat "$T/t8/units/eldato-disk-reaper.service")" "DISK_REAPER_REPOS=$REPO" \
    "T8 the rendered unit carries this box's repo (the venv/worktree classes need one)"
assert_contains "$(cat "$T/t8/calls.log")" "enable --now eldato-disk-reaper.timer" \
    "T8 the timer is ENABLED, not just written"
OUT="$(inst --install 2>&1)"
assert_contains "$OUT" "changed=0" "T8 a second install is a no-op (the bring-up re-runs it every check)"
assert_contains "$(cat "$T/t8/units/eldato-disk-reaper.service")" "SuccessExitStatus=0 5 6" \
    "T8 the unit treats exactly 0/5/6 as success: 3 (misconfigured) and 4 (a removal FAILED) stay RED (#2036)"
assert_absent "$(cat "$T/t8/units/eldato-disk-reaper.service")" "{{" \
    "T8 every placeholder is resolved, including the arming flag"
assert_contains "$(cat "$T/t8/units/eldato-disk-reaper.service")" "Environment=BOUNDED_LIB=" \
    "T8 the bounded-execution library is PINNED (the beside-script arm is empty under a piped start)"
OUT="$(inst --dry-run 2>&1)"
assert_contains "$OUT" "would install" "T8 --dry-run reports without writing"
OUT="$(inst --status 2>&1)"; RC=$?
assert_eq "$RC" "0" "T8 --status exits 0 for a healthy install"
assert_contains "$OUT" "installed=yes" "T8 --status reports the install"
assert_contains "$OUT" "enabled=enabled" "T8 --status reports the timer as enabled"

# ── T9: a contender that LOSES the lock does not release it ────────────────────────────────────
# The EXIT trap is installed before acquire_lock runs, so the contention exit passes THROUGH it. If
# release_lock fired on a pass that never held the lock, the live owner's lock would be deleted and a
# third pass would enter — two passes computing df deltas over one filesystem, crediting each other.
ENVNAME=t9
REPO="$(mk_repo t9)"
mkdir -p "$T/t9/state/disk-reaper.lock"
printf 'pid=%s started=%s\n' "$$" "$(date +%s)" >"$T/t9/state/disk-reaper.lock/token"
OUT="$(run_reaper --dry-run --repo "$REPO" 2>&1)"; RC=$?
assert_eq "$RC" "5" "T9 a pass that loses the lock exits 5 (benign — the other pass is doing this hour's work)"
assert_file "$T/t9/state/disk-reaper.lock/token" \
    "T9 the contender left the LIVE owner's lock in place (it never held it)"
# ⛔ AND A BENIGN SKIP MUST NOT PAINT THE UNIT. 4 meant "a human must look" to every reader, so the
# hourly tick that happened to overlap a long manual pass failed readiness on a healthy box.
assert_absent "$(cat "$T/$ENVNAME/state/disk-reaper.status" 2>/dev/null || true)" "ok=0" \
    "T9 ... and it writes no failure record (the previous record stands)"
rm -rf "$T/t9/state/disk-reaper.lock"

# ── T10: an --only list that names nothing is REFUSED, never a healthy no-op ────────────────────
# A typo would otherwise run zero classes, exit 0 and record ok=1 — a false PASS on a disk sink.
ENVNAME=t10
REPO="$(mk_repo t10)"
OUT="$(run_reaper --dry-run --only bogus --repo "$REPO" 2>&1)"; RC=$?
assert_eq "$RC" "2" "T10 an unknown --only class exits 2"
assert_contains "$OUT" "unknown --only class" "T10 and it names the offending token"
assert_absent "$(cat "$T/t10/state/disk-reaper.status" 2>/dev/null || true)" "ok=1" \
    "T10 a refused class list never writes a healthy record"
OUT="$(run_reaper --dry-run --only 'uv,venv' --repo "$REPO" 2>&1)"; RC=$?
assert_contains "$OUT" "class=venv" "T10 a valid list still runs the classes it names"

# ── T11: a DRY RUN claims no bytes (it removed nothing) ─────────────────────────────────────────
# df moves for reasons that are not this pass (lanes write continuously). Recording a df delta from a
# pass that deleted nothing would print freed_mb>0 next to "NOTHING was removed".
ENVNAME=t11
REPO="$(mk_repo t11)"
run_reaper --dry-run --repo "$REPO" >/dev/null 2>&1
ST="$(cat "$T/t11/state/disk-reaper.status" 2>/dev/null || true)"
assert_contains "$ST" "freed_mb=0" "T11 a dry-run pass records 0 bytes freed"
assert_contains "$ST" "mode=dry-run" "T11 and it says it was a dry run"

# ── T12: the installer's dry run is a dry run, and a missing pinned reaper is refused ───────────
ENVNAME=t12
REPO="$(mk_repo t12)"
inst() {
    HOME="$T/t12/home" DISK_REAPER="$T/t12/reaper.sh" DISK_REAPER_REPOS="$REPO" \
    SYSTEMD_UNIT_DIR="$T/t12/units" SYSTEMCTL="$T/t8/bin/systemctl" SYSTEMCTL_CALLS="$T/t12/calls.log" \
    bash "$INST" "$@"
}
mkdir -p "$T/t12/unused"
cp "$REAPER" "$T/t12/reaper.sh"
: >"$T/t12/calls.log"
OUT="$(inst --dry-run --uninstall 2>&1)"; RC=$?
assert_eq "$RC" "0" "T12 --dry-run --uninstall succeeds"
assert_absent "$(cat "$T/t12/calls.log")" "disable" \
    "T12 --dry-run --uninstall disables NOTHING (flag order must not change the verb)"
assert_absent "$(cat "$T/t12/calls.log")" "stop" "T12 and it stops nothing"
OUT="$(DISK_REAPER="$T/t12/not-here.sh" HOME="$T/t12/home" DISK_REAPER_REPOS="$REPO" \
    SYSTEMD_UNIT_DIR="$T/t12/units" SYSTEMCTL="$T/t8/bin/systemctl" SYSTEMCTL_CALLS="$T/t12/calls2.log" \
    bash "$INST" --install 2>&1)"; RC=$?
assert_eq "$RC" "2" "T12 a SET but missing \$DISK_REAPER is refused (never a silent different copy)"

# ── T13: the bounded-execution resolver's ORDER is pinned (#2046) ───────────────────────────────
# `timeout` is GNU coreutils; macOS ships neither it nor `gtimeout`. ONE helper
# (scripts/lib/bounded.sh) resolves `timeout` -> `gtimeout` -> the internal watchdog, and both
# reapers call it. This is a UNIT test of that helper with a PATH holding ONLY what the case needs,
# so it cannot pass by accident on a host that happens to have coreutils installed.
LIB="$HERE/lib/bounded.sh"
assert_file "$LIB" "T13 the shared bounded-execution library exists (both reapers source it)"
for d in core with-timeout with-gtimeout bare; do mkdir -p "$T/t13/$d"; done
for b in mktemp sleep rm; do ln -sf "$(command -v "$b")" "$T/t13/core/$b"; done
for d in with-timeout with-gtimeout bare; do
    for b in mktemp sleep rm; do ln -sf "$T/t13/core/$b" "$T/t13/$d/$b"; done
done
mk_stub() { # mk_stub <dir> <name> — records its argv and exits 7 (a chosen-binary witness)
    cat >"$1/$2" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"${T13_CALLS:-/dev/null}"
shift   # drop the interval: the stub PROVES it was chosen, it does not enforce the bound
exit 7
SH
    chmod +x "$1/$2"
}
mk_stub "$T/t13/with-timeout" timeout
mk_stub "$T/t13/with-gtimeout" gtimeout
# The control: the "bare" PATH really carries neither binary (or the case proves nothing).
assert_eq "$(PATH="$T/t13/bare" "${BASH:-/bin/bash}" -c 'command -v timeout || command -v gtimeout || echo ABSENT')" \
    "ABSENT" "T13 the bare PATH really has neither timeout nor gtimeout (the case is not vacuous)"
OUT="$(PATH="$T/t13/with-timeout" T13_CALLS="$T/t13/calls-a" "${BASH:-/bin/bash}" -c \
    '. "$1"; echo "kind=$TB_TIMEOUT_KIND"; tb_timeout 5 true; echo "rc=$?"' _ "$LIB" 2>&1)"
assert_contains "$OUT" "kind=timeout" "T13 with timeout present, timeout is the mechanism chosen (first in order)"
assert_contains "$OUT" "rc=7" "T13 the chosen binary's exit status is what the caller sees (not remapped)"
assert_contains "$(cat "$T/t13/calls-a" 2>/dev/null)" "5" "T13 and it is the one that actually RAN, with the bound"
OUT="$(PATH="$T/t13/with-gtimeout" T13_CALLS="$T/t13/calls-b" "${BASH:-/bin/bash}" -c \
    '. "$1"; echo "kind=$TB_TIMEOUT_KIND"; tb_timeout 5 true; echo "rc=$?"' _ "$LIB" 2>&1)"
assert_contains "$OUT" "kind=gtimeout" "T13 with no timeout but a gtimeout, gtimeout is chosen (second)"
assert_contains "$OUT" "rc=7" "T13 gtimeout's exit status likewise reaches the caller unchanged"
assert_contains "$(cat "$T/t13/calls-b" 2>/dev/null)" "5" "T13 gtimeout is the binary that ran"
OUT="$(PATH="$T/t13/bare" "${BASH:-/bin/bash}" -c \
    '. "$1"; echo "kind=$TB_TIMEOUT_KIND"; SECONDS=0; tb_timeout 1 sleep 10; echo "rc=$? elapsed=$SECONDS"' \
    _ "$LIB" 2>&1)"
assert_contains "$OUT" "kind=internal" "T13 with neither binary the internal watchdog is the fallback"
assert_contains "$OUT" "rc=124" "T13 a timeout is 124 through the fallback too (the callers' fail-closed code)"
ELAPSED="$(printf '%s' "$OUT" | sed -n 's/.*elapsed=\([0-9]*\).*/\1/p')"
if [ -n "$ELAPSED" ] && [ "$ELAPSED" -le 5 ]; then ok "T13 the fallback RETURNS in ~1s instead of waiting out the 10s command"
else bad "T13 the fallback did not bound the command (elapsed=${ELAPSED:-unknown}s)"; fi

# ── T14: a host with NO binary still CLASSIFIES — it never silently no-ops (#2046) ──────────────
# The measured defect: every class died with `timeout: command not found`, rc=127 -> fail-closed, and
# the pass still completed as if it had run. The assertion is that the class now FINDS its candidate.
ENVNAME=t14
REPO="$(mk_repo t14)"
mkdir -p "$T/t14/bin"
# ⛔ A STUB DELEGATE, NOT THE REAL ONE. Driving this with `pi-reap-worktrees.sh` made the case measure
# the DELEGATE's own bounded probes: under load 2 of 8 runs went red with `got 6, want 5` because the
# delegate's `git worktree list` hit its 20s watchdog and refused — a real behaviour, but not the thing
# this case exists to pin (that a host with no GNU `timeout` still CLASSIFIES). The stub prints one
# `remove` row, so the only thing under test is the entry point's bounding mechanism.
cat >"$T/t14/bin/wt-stub.sh" <<'SH'
#!/usr/bin/env bash
echo "remove   /tmp/not-a-real-worktree"
exit 0
SH
chmod +x "$T/t14/bin/wt-stub.sh"
WT="$T/not-a-real-worktree"
mkdir -p "$WT"
OUT="$(WORKTREE_REAPER="$T/t14/bin/wt-stub.sh" TB_TIMEOUT_FORCE_INTERNAL=1 run_reaper --dry-run --repo "$REPO" --only worktree --aged-days 7 2>&1)"; RC=$?
assert_eq "$RC" "5" "T14 with no timeout/gtimeout the pass still finds work (5), not fail-closed (3)"
assert_contains "$OUT" "watchdog=internal" "T14 the pass NAMES the fallback it used"
assert_contains "$OUT" "WOULD-REMOVE class=worktree" "T14 the worktree class CLASSIFIED instead of failing closed"
assert_absent "$OUT" "verdict=fail-closed" "T14 no class reports fail-closed on a host with neither binary"
assert_contains "$(cat "$T/$ENVNAME/state/disk-reaper.status" 2>/dev/null)" "watchdog=internal" \
    "T14 the pass record names the mechanism"
assert_contains "$(cat "$T/$ENVNAME/state/disk-reaper.status" 2>/dev/null)" "ok=1" \
    "T14 and the record is not a failure (the pass did its job)"
# The other half of the order: a `timeout` on PATH is preferred over the working fallback.
mkdir -p "$T/t14/passbin"
cat >"$T/t14/passbin/timeout" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"${T14_CALLS:-/dev/null}"
shift
exec "$@"
SH
chmod +x "$T/t14/passbin/timeout"
OUT="$(WORKTREE_REAPER="$T/t14/bin/wt-stub.sh" PATH="$T/t14/passbin:$PATH" T14_CALLS="$T/t14/calls" run_reaper --dry-run --repo "$REPO" --only worktree --aged-days 7 2>&1)"; RC=$?
assert_eq "$RC" "5" "T14 with a timeout on PATH the same pass finds the same work"
assert_contains "$(cat "$T/$ENVNAME/state/disk-reaper.status" 2>/dev/null)" "watchdog=timeout" \
    "T14 resolution prefers timeout over the internal fallback (recorded)"
assert_absent "$OUT" "watchdog=" "T14 with a real timeout binary the report gains NO provenance line (pre-change output)"
assert_contains "$(cat "$T/t14/calls" 2>/dev/null)" "1800" \
    "T14 the binary that ran received the class watchdog (1800s default)"

# ── T15: an unusable helper is a STARTUP REFUSAL, never per-class fail-closed (#2046) ───────────
# A partial deploy that loses scripts/lib/bounded.sh must NOT reproduce the defect it fixes: with no
# helper, no probe is bounded. Refusing at startup is the only shape that cannot read as a pass.
ENVNAME=t15
REPO="$(mk_repo t15)"
OUT="$(BOUNDED_LIB=/nonexistent/bounded.sh run_reaper --dry-run --repo "$REPO" 2>&1)"; RC=$?
assert_eq "$RC" "3" "T15 a missing bounded-execution library exits 3 at startup"
assert_contains "$OUT" "FAIL-CLOSED at startup" "T15 the refusal says it is a startup failure"
assert_contains "$OUT" "bounded-execution library is missing" "T15 and names what is missing"
assert_absent "$OUT" "class=" "T15 it emits NO per-class line, so it cannot read as a completed pass"
assert_absent "$(cat "$T/t15/state/disk-reaper.status" 2>/dev/null || true)" "ok=" \
    "T15 and it writes no pass record at all"
OUT="$(TB_TIMEOUT_BIN=/nonexistent/timeout run_reaper --dry-run --repo "$REPO" 2>&1)"; RC=$?
assert_eq "$RC" "3" "T15 an unusable TB_TIMEOUT_BIN is REFUSED, not silently ignored"
assert_contains "$OUT" "TB_TIMEOUT_BIN" "T15 and the refusal names the pin"
assert_absent "$OUT" "class=" "T15 no per-class line for a refused pass"

# ── T16: a delegate's exit 5 is NOT swallowed — below-floor is recorded, never `ok` (#2156) ─────
# `worst_rc` discarded 5 (`0|5) printf cur`), so a venv pass that ended BELOW its owner's floor was
# recorded rc=0 verdict=ok — the exact condition the floor exists to make visible read `healthy` on
# the fleet. Measured before the fix: `status: ok=1 rc=0 verdict_venv=ok detail=... exited 5`.
ENVNAME=t16
REPO="$(mk_repo t16)"
mkdir -p "$T/t16/bin"
cat >"$T/t16/bin/below-floor.sh" <<'SH'
#!/usr/bin/env bash
echo "REAP-VENV fixture: free disk is below the stated floor"
exit 5
SH
chmod +x "$T/t16/bin/below-floor.sh"
OUT="$(VENV_REAPER="$T/t16/bin/below-floor.sh" run_reaper --apply --repo "$REPO" --only venv 2>&1)"; RC=$?
assert_eq "$RC" "5" "T16 an APPLY pass whose delegate reports exit 5 exits 5, not 0"
ST="$(cat "$T/$ENVNAME/state/disk-reaper.status" 2>/dev/null || true)"
assert_contains "$ST" "ok=0" "T16 ... and the record does NOT read healthy (the false PASS #2156 measured)"
assert_contains "$ST" "verdict_venv=below-floor" "T16 the class verdict names the condition (apply-mode 5 is BELOW floor, not 'over-bound')"
assert_contains "$ST" "ended BELOW its owner" "T16 and the detail says it in words, not as 'exited 5'"
ST_OUT="$(HOME="$T/home" DISK_REAPER_STATE_DIR="$T/$ENVNAME/state" bash "$REAPER" --print-status 2>&1)"; SRC=$?
assert_eq "$SRC" "3" "T16 --print-status exits 3, so the supervisor cannot read this pass as fine"
assert_contains "$ST_OUT" "status=failed" "T16 ... and names it failed"
# The OTHER meaning of 5 must survive: in dry-run it is 'work present', which IS a healthy pass.
OUT="$(VENV_REAPER="$T/t16/bin/below-floor.sh" run_reaper --dry-run --repo "$REPO" --only venv 2>&1)"; RC=$?
assert_eq "$RC" "5" "T16 the same delegate in DRY-RUN is still informative (5)"
assert_contains "$(cat "$T/$ENVNAME/state/disk-reaper.status")" "ok=1" \
    "T16 ... and a dry run that did its job is still ok (5 has two meanings, decided per mode)"

# ── T17: a delegate REFUSAL is not a misconfiguration — the unit must not be painted red (#2036) ─
# Exit 3 was used for both "this reaper is broken" and "a delegate refused because the box is busy",
# so the scheduled unit went RED every hour on a healthy cell (measured: `status=3/NOTIMPLEMENTED` on
# a pass that had reclaimed 441 MB). A refusal is 6 (unit success, record not healthy); a MISSING
# delegate is still 3 (unit red) — see T5, and the pair is asserted together here.
ENVNAME=t17
REPO="$(mk_repo t17)"
mkdir -p "$T/t17/bin"
cat >"$T/t17/bin/refuse.sh" <<'SH'
#!/usr/bin/env bash
echo "FAIL-CLOSED abort: a live uv process holds the cache (exit 3)" >&2
exit 3
SH
chmod +x "$T/t17/bin/refuse.sh"
OUT="$(VENV_REAPER="$T/t17/bin/refuse.sh" run_reaper --apply --repo "$REPO" --only venv 2>&1)"; RC=$?
assert_eq "$RC" "6" "T17 a delegate refusal exits 6 — the code the unit file lists as success"
ST="$(cat "$T/$ENVNAME/state/disk-reaper.status" 2>/dev/null || true)"
assert_contains "$ST" "ok=0" "T17 ... while the RECORD stays not-healthy (the record is the alarm channel)"
assert_contains "$ST" "verdict_venv=refused" "T17 the class verdict names the refusal"
assert_contains "$ST" "refused / failed closed (exit 3" "T17 the detail points at the delegate's own log"
OUT="$(VENV_REAPER=/nonexistent/reap-lane-venvs.sh run_reaper --apply --repo "$REPO" --only venv 2>&1)"; RC=$?
assert_eq "$RC" "3" "T17 a MISSING delegate is still 3 (misconfigured) — the distinction #2036 asks for"
assert_contains "$(cat "$T/$ENVNAME/state/disk-reaper.status")" "cannot run: venv-delegate-missing" \
    "T17 and the record names WHAT cannot run, not just that something failed"

# ── T18: the age floor is VALIDATED — a typo refuses instead of disabling the floor (#2158) ─────
# `REAP_VENV_MIN_AGE_SECONDS=30m` makes `[ "$age" -lt "$30m" ]` error and fall through to the ELSE
# branch, so EVERY holder-free env becomes reapable regardless of age — silently, in the direction
# that loses work. The argv form was validated; the env seam an operator/unit actually sets was not.
ENVNAME=t18
REPO="$(mk_repo t18)"
WT="$(mk_wt "$REPO" fresh feat/t18-fresh)"
mk_venv "$WT" 4
OUT="$(REAP_VENV_MIN_AGE_SECONDS=30m REAP_VENV_LOG="$T/t18/state/venv.log" \
    bash "${VENV_REAPER:-$HERE/reap-lane-venvs.sh}" --dry-run --repo "$REPO" 2>&1)"; RC=$?
assert_eq "$RC" "3" "T18 a non-numeric REAP_VENV_MIN_AGE_SECONDS is REFUSED (exit 3), not silently ignored"
assert_contains "$OUT" "REAP_VENV_MIN_AGE_SECONDS='30m' is not a whole number" \
    "T18 the refusal names the variable AND the value"
assert_absent "$OUT" "integer expression expected" "T18 and the shell never reaches the broken comparison"
OUT="$(REAP_VENV_MIN_AGE_SECONDS=30m run_reaper --dry-run --repo "$REPO" --only venv 2>&1)"; RC=$?
# ⛔ THE PASS DOES NOT INHERIT THE OWNER'S ENV SEAM. It passes its own validated `--min-age`, so an
# ambient typo cannot LOWER the floor (the fail-open #2158 measured) — and the pass says which floor it
# used, so an operator can see that their env var was not the one in force.
assert_contains "$OUT" "venv_min_age=1800s" "T18 the scheduled pass's floor is its OWN validated value, never an unvalidated ambient env"
assert_absent "$OUT" "integer expression expected" "T18 and the ambient typo never reaches a comparison"
assert_dir "$WT/.venv" "T18 NOTHING was reaped while the floor is unreadable"
OUT="$(DISK_REAPER_VENV_MIN_AGE=30m run_reaper --dry-run --repo "$REPO" --only venv 2>&1)"; RC=$?
assert_eq "$RC" "3" "T18 the pass REFUSES a non-numeric DISK_REAPER_VENV_MIN_AGE at startup (misconfigured, not usage)"
assert_contains "$OUT" "DISK_REAPER_VENV_MIN_AGE must be a whole number" "T18 ... and names the variable"
assert_absent "$OUT" "class=" "T18 no per-class line for a refused pass, so it cannot read as a completed one"
OUT="$(run_reaper --dry-run --repo "$REPO" --only venv --min-age 30m 2>&1)"; RC=$?
assert_eq "$RC" "2" "T18 the argv form is still refused too (one rule on all three seams)"

# ── T19: a DEAD lane's .venv is reclaimed and a LIVE lane's is NEVER (#2159/#1932) ──────────────
# The property the whole feature rests on, asserted IN APPLY MODE through the scheduled entry point
# (T1/T2 assert it in dry-run): one pass, two worktrees, one holder. The distinguishing half is not
# optional — a suite that only shows "a dead venv is removed" cannot tell this reaper from `rm -rf`.
ENVNAME=t19
REPO="$(mk_repo t19)"
WT_DEAD="$(mk_wt "$REPO" dead feat/t19-dead)"; mk_venv "$WT_DEAD" 6; commit_in "$WT_DEAD" "$OLD_DATE" dead
WT_LIVE="$(mk_wt "$REPO" live feat/t19-live)"; mk_venv "$WT_LIVE" 6; commit_in "$WT_LIVE" "$OLD_DATE" live
( cd "$WT_LIVE" && exec sleep 300 ) &
LIVE_PID=$!
SLEEPERS="$SLEEPERS $LIVE_PID"
sleep 1
OUT="$(run_reaper --apply --repo "$REPO" --only venv --min-age 0 2>&1)"; RC=$?
assert_eq "$RC" "0" "T19 an apply pass that reaped the dead lane and kept the live one exits 0"
assert_nodir "$WT_DEAD/.venv" "T19 a DEAD lane's .venv IS reclaimed by the scheduled pass"
assert_dir "$WT_LIVE/.venv" "T19 a LIVE lane's .venv is NEVER reclaimed in the same pass"
assert_dir "$WT_LIVE" "T19 and the live worktree itself survives"
assert_contains "$OUT" "KEEP live-cwd" "T19 the owner names the witness that kept it"
kill "$LIVE_PID" 2>/dev/null; wait "$LIVE_PID" 2>/dev/null
SLEEPERS=""

# ── T19b: an ABSENT liveness artefact FAILS CLOSED — absence is not evidence of staleness ───────
# "No holder found" must never be what a BROKEN probe looks like. With the process witness unusable
# (`ps` cannot run) the pass may reap nothing at all, and must say so rather than reap.
ENVNAME=t19b
REPO="$(mk_repo t19b)"
WT_X="$(mk_wt "$REPO" dead feat/t19b-dead)"; mk_venv "$WT_X" 4; commit_in "$WT_X" "$OLD_DATE" dead
OUT="$(PS_BIN=/nonexistent/ps run_reaper --apply --repo "$REPO" --only venv --min-age 0 2>&1)"; RC=$?
assert_eq "$RC" "6" "T19b an unreadable process witness fails the class closed (6 at the pass level)"
assert_dir "$WT_X/.venv" "T19b ... and removes NOTHING on a probe it could not read"
assert_contains "$(cat "$T/$ENVNAME/state/disk-reaper.status" 2>/dev/null || true)" "ok=0" \
    "T19b ... and the pass record is not healthy"

# ── T20: ONE install verb, BOTH platforms (#2048/#2058) ────────────────────────────────────────
# The consolidated pass was scheduled on Linux only, so the Mac had no consolidated pass and the venv
# class had no periodic owner there at all. Asserted on the RENDERED launchd artifact with a
# `launchctl` shim, so it holds on a Linux CI box.
ENVNAME=t20
REPO="$(mk_repo t20repo)"
mkdir -p "$T/t20/agents" "$T/t20/bin" "$T/t20/home/.pi/agent/state"
cat >"$T/t20/bin/launchctl" <<'LC'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${LAUNCHCTL_CALLS:-/dev/null}"
case "$1" in
  list) [ -f "${LAUNCHCTL_LOADED:-/nonexistent}" ] && cat "$LAUNCHCTL_LOADED"; exit 0 ;;
  bootstrap) printf '4242\t0\t%s\n' "$(basename "$3" .plist)" >"${LAUNCHCTL_LOADED:-/dev/null}"; exit 0 ;;
  *) exit 0 ;;
esac
LC
chmod +x "$T/t20/bin/launchctl"
PY_HERE="$(command -v python3 2>/dev/null || printf '/bin/sh')"
LAUNCHER_HERE="$HERE/pi-reap-worktrees-launchd.py"
inst20() { # inst20 <args...>
    HOME="$T/t20/home" DISK_REAPER="$REAPER" DISK_REAPER_REPOS="$REPO" \
    DISK_REAPER_STATE_DIR="$T/t20/home/.pi/agent/state" \
    ELDATO_PLATFORM=Darwin LAUNCHD_AGENTS_DIR="$T/t20/agents" \
    LAUNCHCTL="$T/t20/bin/launchctl" LAUNCHCTL_CALLS="$T/t20/calls.log" \
    LAUNCHCTL_LOADED="$T/t20/loaded" \
    ELDATO_LAUNCHER_PY="$PY_HERE" ELDATO_LAUNCHER="$LAUNCHER_HERE" \
    bash "$INST" "$@"
}
OUT="$(inst20 --install 2>&1)"; RC=$?
assert_eq "$RC" "0" "T20 the same verb installs the launchd agent on Darwin"
assert_file "$T/t20/agents/com.eldato.disk-reaper.plist" "T20 the consolidated pass is scheduled on macOS"
PLIST="$(cat "$T/t20/agents/com.eldato.disk-reaper.plist" 2>/dev/null || true)"
assert_contains "$PLIST" "<string>com.eldato.disk-reaper</string>" "T20 the agent carries its label"
assert_contains "$PLIST" "<string>--apply</string>" "T20 and it is ARMED, exactly like the systemd unit"
assert_contains "$PLIST" "<integer>3600</integer>" "T20 hourly, matching the systemd timer's cadence"
assert_contains "$PLIST" "<string>$REPO</string>" "T20 the agent carries this box's repo"
assert_contains "$PLIST" "VENV_REAPER</key>" "T20 the delegates are PINNED (as in the systemd unit)"
assert_contains "$PLIST" "pi-reap-worktrees-launchd.py" "T20 it launches through the TCC launcher, not bash"
assert_contains "$PLIST" "BOUNDED_LIB</key>" "T20 the bounded library is PINNED for the piped (bash -s) start"
assert_absent "$PLIST" "{{" "T20 every placeholder is resolved"
assert_contains "$(cat "$T/t20/calls.log")" "bootstrap gui/" "T20 the agent is BOOTSTRAPPED, not just written"
OUT="$(inst20 --status 2>&1)"; RC=$?
assert_contains "$OUT" "installed=yes" "T20 --status reports the agent"
assert_contains "$OUT" "loaded=yes" "T20 --status reports it loaded"
OUT="$(inst20 --install 2>&1)"
assert_contains "$OUT" "changed=0" "T20 a second install is a no-op on macOS too"
OUT="$(inst20 --report-only --install 2>&1)"
assert_contains "$(cat "$T/t20/agents/com.eldato.disk-reaper.plist")" "<string>--dry-run</string>" \
    "T20 --report-only DISARMS the same artifact (the reversible owner step, #1678)"
# ⛔ The bad-interpreter case is invoked DIRECTLY, not through inst20(): a `VAR=value funcname`
# prefix assignment is visible inside the function but is NOT exported to the `bash "$INST"` it spawns
# (measured — the first draft passed for the wrong reason), so the case would have tested the default
# interpreter search instead of the pin.
OUT="$(HOME="$T/t20/home" DISK_REAPER="$REAPER" DISK_REAPER_REPOS="$REPO" \
    DISK_REAPER_STATE_DIR="$T/t20/home/.pi/agent/state" \
    ELDATO_PLATFORM=Darwin LAUNCHD_AGENTS_DIR="$T/t20/agents" \
    LAUNCHCTL="$T/t20/bin/launchctl" LAUNCHCTL_CALLS=/dev/null \
    ELDATO_LAUNCHER="$LAUNCHER_HERE" ELDATO_LAUNCHER_PY=/nonexistent/python \
    bash "$INST" --install 2>&1)"; RC=$?
assert_eq "$RC" "1" "T20 no usable interpreter is a REFUSAL, never a degraded bash job that fails closed hourly"
assert_contains "$OUT" "not executable" "T20 and the refusal names the interpreter"

# ── T21: the installer refuses a unit rendered from transient scratch (the 127-unit defect) ────
# MEASURED: a harness ran the installer with HOME=/tmp/tmp.XXXX/bg/home, so the unit's ExecStart
# pointed into a directory deleted before the first tick — every pass exited 127 while `list-timers`
# showed the job scheduled. Nothing but a refusal at INSTALL time can see that.
ENVNAME=t21
REPO="$(mk_repo t21)"
D="$(mktemp -d /tmp/tmp.XXXXXXXX)"
mkdir -p "$D/home/.pi/agent/scripts" "$D/home/.pi/agent/state"
cp "$REAPER" "$D/home/.pi/agent/scripts/disk-reaper.sh"
for d in pi-cache-reap.sh reap-lane-venvs.sh pi-reap-worktrees.sh; do
    cp "$HERE/$d" "$D/home/.pi/agent/scripts/$d" 2>/dev/null || true
done
# ⛔ NO SYSTEMD_UNIT_DIR: that override deliberately bypasses this heuristic (the suite's own fixtures
# live under mktemp dirs too), so passing it here would make the case test the bypass instead.
OUT="$(HOME="$D/home" DISK_REAPER="$D/home/.pi/agent/scripts/disk-reaper.sh" \
    DISK_REAPER_REPOS="$REPO" \
    bash "$INST" --install 2>&1)"; RC=$?
assert_eq "$RC" "1" "T21 a unit rendered from transient scratch is REFUSED"
assert_contains "$OUT" "transient scratch space" "T21 and the refusal names the defect (127 every tick)"
assert_absent "$OUT" "installed:" "T21 nothing was installed"
rm -rf "$D"

# ── T22: an install that cannot take effect is a FAILURE, never a silent skip ───────────────────
# The whole defect class is "installed but never fires". A `launchctl list` that does not carry the
# label after bootstrap must be reported, not assumed.
ENVNAME=t22
REPO="$(mk_repo t22)"
cat >"$T/t20/bin/launchctl-nodeaf" <<'LC'
#!/usr/bin/env bash
case "$1" in list) exit 0 ;; *) exit 0 ;; esac
LC
chmod +x "$T/t20/bin/launchctl-nodeaf"
OUT="$(HOME="$T/t20/home" DISK_REAPER="$REAPER" DISK_REAPER_REPOS="$REPO" \
    DISK_REAPER_STATE_DIR="$T/t20/home/.pi/agent/state" \
    ELDATO_PLATFORM=Darwin LAUNCHD_AGENTS_DIR="$T/t22/agents" \
    LAUNCHCTL="$T/t20/bin/launchctl-nodeaf" LAUNCHCTL_CALLS=/dev/null \
    ELDATO_LAUNCHER_PY="$PY_HERE" ELDATO_LAUNCHER="$LAUNCHER_HERE" \
    bash "$INST" --install 2>&1)"; RC=$?
assert_eq "$RC" "1" "T22 an agent that is not loaded after install is a FAILURE"
assert_contains "$OUT" "NOT loaded" "T22 and it says the reaper will not run unattended"

# ── T23: the uv family's exit 4 is "lock held", NOT "a removal failed" (PR #2173 review P1) ─────
# pi-cache-reap.sh's own contract says 4 = "did not run: another pass holds the lock", and the
# controller's hourly cache pass takes the SAME lock — so mapping 4 to removal-failed put the unit RED
# on a healthy box: the #2036 shape, reintroduced for the one class that shares a lock with the
# controller. The vocabularies genuinely disagree (venv/worktree 4 = removal failed), so this pins the
# uv arm SPECIFICALLY rather than trusting a shared number.
ENVNAME=t23
REPO="$(mk_repo t23)"
mkdir -p "$T/t23/bin"
cat >"$T/t23/bin/lock-held.sh" <<'SH'
#!/usr/bin/env bash
echo "pi-cache-reap: another pass holds the lock — did not run (exit 4)" >&2
exit 4
SH
chmod +x "$T/t23/bin/lock-held.sh"
OUT="$(CACHE_REAPER="$T/t23/bin/lock-held.sh" run_reaper --apply --only uv 2>&1)"; RC=$?
assert_eq "$RC" "6" "T23 a cache pass that did not run (lock held, exit 4) is not a removal failure — the unit stays green"
ST="$(cat "$T/$ENVNAME/state/disk-reaper.status" 2>/dev/null || true)"
assert_contains "$ST" "verdict_uv=refused" "T23 ... recorded as refused, not removal-failed"
assert_contains "$ST" "another pass holds the lock" "T23 ... and the detail names the lock, not a failed removal"
# The sibling classes keep their own mapping: for the venv owner 4 IS a removal failure.
cat >"$T/t23/bin/removal-failed.sh" <<'SH'
#!/usr/bin/env bash
echo "FAILED to remove (exit 4)" >&2
exit 4
SH
chmod +x "$T/t23/bin/removal-failed.sh"
OUT="$(VENV_REAPER="$T/t23/bin/removal-failed.sh" run_reaper --apply --repo "$REPO" --only venv 2>&1)"; RC=$?
assert_eq "$RC" "4" "T23 the venv owner's exit 4 IS a removal failure (the vocabularies are not flattened)"
assert_contains "$(cat "$T/$ENVNAME/state/disk-reaper.status")" "verdict_venv=removal-failed" \
    "T23 ... and its verdict says so"

# ── T24: the TCC launcher's `bash -s` start still resolves the bounded library (review P1) ───────
# The macOS agent pipes the script into `bash -s` (a launchd-spawned bash cannot read the file), where
# there is NO BASH_SOURCE: a bare reference aborts the substitution under `set -u`, SELF_DIR becomes
# empty, the beside-script arm searches /lib/bounded.sh, and the pass refuses at startup EVERY hour
# while launchctl shows a healthy job. Measured before the fix: rc=3 + "unbound variable".
ENVNAME=t24
REPO="$(mk_repo t24)"
PY="$(command -v python3 2>/dev/null || true)"
if [ -n "$PY" ] && [ -f "$HERE/pi-reap-worktrees-launchd.py" ]; then
    # THE ENV IS THE INSTALLED ARTIFACT'S ENV: the plist pins BOUNDED_LIB and all three delegates
    # ({{REAPER_DIR}}/…), because under `bash -s` there is no script path to derive any of them from.
    # A test that pins only some of them measures a shape the installer never produces.
    OUT="$(HOME="$T/home" DISK_REAPER_STATE_DIR="$T/t24/state" \
        BOUNDED_LIB="$HERE/lib/bounded.sh" \
        CACHE_REAPER="$HERE/pi-cache-reap.sh" VENV_REAPER="$HERE/reap-lane-venvs.sh" \
        WORKTREE_REAPER="$HERE/pi-reap-worktrees.sh" \
        CACHE_REAP_UV_DIR="$T/t24/nocache-uv" CACHE_REAP_LOG="$T/t24/state/cache.log" \
        "$PY" "$HERE/pi-reap-worktrees-launchd.py" --script "$REAPER" \
        -- --dry-run --repo "$REPO" --only uv 2>&1)"; RC=$?
    assert_absent "$OUT" "unbound variable" "T24 a bash -s launch (no BASH_SOURCE) does not abort under set -u"
    assert_absent "$OUT" "bounded-execution library is missing" \
        "T24 ... and the PINNED bounded library resolves, so the installed macOS agent is not inert"
    assert_absent "$OUT" "not found" "T24 ... and the pinned delegates resolve"
    if [ "$RC" = 3 ]; then bad "T24 the pass refused at startup under bash -s (rc=3)";
    else ok "T24 the pass runs under bash -s (rc=$RC)"; fi
    # WITHOUT the pin there is no script path to fall back to, so it must FAIL CLOSED — loudly, naming
    # the seam — rather than run with an unbounded probe.
    OUT="$(HOME="$T/t24nopin/home" DISK_REAPER_STATE_DIR="$T/t24nopin/state" \
        CACHE_REAPER="$HERE/pi-cache-reap.sh" VENV_REAPER="$HERE/reap-lane-venvs.sh" \
        WORKTREE_REAPER="$HERE/pi-reap-worktrees.sh" \
        CACHE_REAP_UV_DIR="$T/t24nopin/nocache" CACHE_REAP_LOG="$T/t24nopin/state/c.log" \
        "$PY" "$HERE/pi-reap-worktrees-launchd.py" --script "$REAPER" \
        -- --dry-run --repo "$REPO" --only uv 2>&1)"; RC=$?
    assert_eq "$RC" "3" "T24 unpinned under bash -s, the pass refuses instead of running an unbounded probe"
    assert_contains "$OUT" "BOUNDED_LIB" "T24 ... and the refusal names the seam the installed artifact pins"
else
    ok "T24 skipped — no python3 or no launcher on this host"
fi

# ── T25: --status exits 1 when the agent is NOT installed (review P1) ─────────────────────────
# cloud-cell-bringup.sh gates CELL READY on this exit code; returning 0 for "not installed" answers
# "is this box scheduled?" with a success — the false PASS this installer exists to remove.
ENVNAME=t25
mkdir -p "$T/t25/agents"
OUT="$(HOME="$T/t20/home" ELDATO_PLATFORM=Darwin LAUNCHD_AGENTS_DIR="$T/t25/agents" \
    LAUNCHCTL="$T/t20/bin/launchctl" LAUNCHCTL_LOADED="$T/t25/never" LAUNCHCTL_CALLS=/dev/null \
    bash "$INST" --status 2>&1)"; RC=$?
assert_eq "$RC" "1" "T25 --status exits 1 when the launchd agent is not installed"
assert_contains "$OUT" "installed=no" "T25 ... and says so"

# ── T26: an install whose reaper has no sibling lib/bounded.sh is REFUSED (review P1) ────────
# Both artifacts PIN the library, and without it the WHOLE pass refuses at startup every hour — no
# class runs at all. That is worse than one class failing closed, so it is a refusal, not a warning.
ENVNAME=t26
REPO="$(mk_repo t26)"
D="$T/t26/reaperdir"
mkdir -p "$D" "$T/t26/home/.pi/agent/state" "$T/t26/units"
cp "$REAPER" "$D/disk-reaper.sh"
for f in pi-cache-reap.sh reap-lane-venvs.sh pi-reap-worktrees.sh; do cp "$HERE/$f" "$D/$f" 2>/dev/null || true; done
OUT="$(HOME="$T/t26/home" DISK_REAPER="$D/disk-reaper.sh" DISK_REAPER_REPOS="$REPO" \
    SYSTEMD_UNIT_DIR="$T/t26/units" SYSTEMCTL="$T/t8/bin/systemctl" SYSTEMCTL_CALLS=/dev/null \
    bash "$INST" --install 2>&1)"; RC=$?
assert_eq "$RC" "1" "T26 a reaper with no sibling lib/bounded.sh is refused at install time"
assert_contains "$OUT" "lib/bounded.sh is missing" "T26 ... and the refusal names the library"
assert_absent "$OUT" "installed:" "T26 nothing was installed"

# ── T27: fleet-health reports the PASS RECORD everywhere, and the launchd table only on a Mac ────
# The record is written by the consolidated pass on BOTH platforms, so returning early when `launchctl`
# is absent never read it on the Linux cells this feature exists for. The launchd EXIT TABLE is the
# only thing that is inapplicable there; that distinction is what this pins.
ENVNAME=t27
mkdir -p "$T/t27/empty" "$T/t27/home/.pi/agent/state"
if command -v python3 >/dev/null 2>&1; then
    PY_ABS="$(command -v python3)"
    # (a0) NO SCHEDULE + NO RECORD = NO ALARM. fleet-health runs on every lane box; most carry no reaper
    # on a clock, and an alarm that fires where nothing was configured can never be cleared. This leg is
    # HERMETIC: it pins HOME at a fresh dir and pins the "no schedule" message, so it holds on a CI runner
    # that has no reaper unit.
    _fh() { # _fh <home> <scheduled-0|1> -> run reaper_section() and print its alarms
        # ⛔ THE SECOND ARGUMENT MUST REACH THE TOOL. It pins DISK_REAPER_SCHEDULE_ASSERT, the seam that
        # makes BOTH branches of `_reaper_is_scheduled()` reachable on any host — without it the probe reads
        # the machine, so the "no schedule" leg passes on a dev box that carries a reaper unit and fails on
        # a CI runner that does not.
        PATH="$T/t27/empty" HOME="$1" DISK_REAPER_SCHEDULE_ASSERT="${2:-}" \
            "$PY_ABS" - "$REPO_ROOT/tools/fleet/fleet-health.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("fh", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print("ALARMS=%r" % (m.reaper_section(),))
PY
    }
    OUT="$(_fh "$T/t27/home" 0 2>&1)"; RC=$?
    assert_eq "$RC" "0" "T27 the section runs without launchd"
    assert_contains "$OUT" "not applicable on this host" "T27 the launchd EXIT TABLE reports itself inapplicable"
    assert_contains "$OUT" "no disk-reaper schedule on this box" "T27 with NO schedule and no record it says so"
    assert_contains "$OUT" "ALARMS=[]" "T27 ... and does NOT alarm (an unclearable alarm is wallpaper)"
    # (a) A SCHEDULE WITH NO RECORD **IS** AN ALARM. Made hermetic by creating the user-unit artifact the
    # probe looks for — the CI runner has no reaper, so relying on the box's own state made this pass
    # locally and fail on ubuntu-latest.
    OUT="$(_fh "$T/t27/home" 1 2>&1)"; RC=$?
    assert_contains "$OUT" "UNREADABLE" "T27 a SCHEDULED box with no pass record IS an alarm"
    assert_absent "$OUT" "ALARMS=[]" "T27 ... and the alarm is raised"
    # (b) a healthy record: read, printed, and NOT an alarm — on a host with no launchd at all.
    printf 'epoch=%s\nok=1\nrc=0\nfreed_mb=12\nfreed_mb_uv=12\nfreed_mb_venv=0\nfreed_mb_worktree=0\n' "$(date +%s)" \
        >"$T/t27/home/.pi/agent/state/disk-reaper.status"
    OUT="$(_fh "$T/t27/home" 1 2>&1)"; RC=$?
    assert_contains "$OUT" "record ok=1" "T27 a HEALTHY record is read on a Linux-shaped host"
    assert_contains "$OUT" "ALARMS=[]" "T27 ... and contributes no alarm"
else
    ok "T27 skipped — no python3 on this host"
fi

# ── T28: a LIVE lock holder is never displaced, however old the lock LOOKS (review cycle 2, P1) ─
# The token is `pid=<pid> started=<epoch>`; the old parser took the whole tail as the pid, so
# `kill -0` was always "invalid pid" and the live-holder arm was dead code — only the age bound stood
# between a live pass and a contender deleting its lock. A single class may run for CLASS_TIMEOUT
# (1800s) with no heartbeat, which is exactly LOCK_STALE_SECONDS, so that bound alone is not enough.
ENVNAME=t28
REPO="$(mk_repo t28)"
mkdir -p "$T/t28/state/disk-reaper.lock"
printf 'pid=%s started=%s\n' "$$" "$(date +%s)" >"$T/t28/state/disk-reaper.lock/token"
# Age the lock PAST the staleness bound while its owner is still alive.
touch -t 202001010000 "$T/t28/state/disk-reaper.lock"
OUT="$(DISK_REAPER_LOCK_STALE_SECONDS=60 run_reaper --dry-run --repo "$REPO" --only venv 2>&1)"; RC=$?
assert_eq "$RC" "5" "T28 a LIVE lock holder blocks the pass (exit 5: benign, the holder is working) even when the lock is ancient"
assert_contains "$OUT" "another pass holds the lock" "T28 ... and the pass says a live holder is why"
assert_file "$T/t28/state/disk-reaper.lock/token" "T28 ... and it did NOT break the live owner's lock"
assert_absent "$OUT" "removing STALE lock" "T28 ... and never reports a stale reclaim for a live pid"
# The other half: a DEAD pid past the bound IS reclaimed (the age bound still does its job).
printf 'pid=999999 started=1\n' >"$T/t28/state/disk-reaper.lock/token"
touch -t 202001010000 "$T/t28/state/disk-reaper.lock"
OUT="$(DISK_REAPER_LOCK_STALE_SECONDS=60 run_reaper --dry-run --repo "$REPO" --only venv 2>&1)"; RC=$?
assert_eq "$RC" "0" "T28 a DEAD pid past the bound is reclaimed and the pass runs"
assert_contains "$OUT" "removing STALE lock" "T28 ... and the reclaim is said out loud"

# ── T29: `$0` is NOT this script under the agent's `/bin/bash -s -- …` start (cycle 2 P1, fixed in 5) ─
# The launcher execs `["/bin/bash", "-s", "--", …]`, so `$0` is the bash BINARY and
# ${BASH_SOURCE[0]} is empty. Two probes keyed off `$0` broke there, and they broke in OPPOSITE
# directions: `usage()` printed a shell's header rather than this script's; `file_mtime` took BSD's `-f`
# arm (right flavour) but measured BASH'S OWN mtime instead of the lock's, pinning the lock's age to the
# interpreter's install date — so a lock seconds old could be declared stale and a LIVE owner's lock
# broken. The discriminating assertion is therefore the one below: a lock JUST under the bound must
# survive a piped start (a `$0`-derived age makes it look decades old and reclaims it).
ENVNAME=t29
REPO="$(mk_repo t29)"
if [ -n "$PY" ] && [ -f "$HERE/pi-reap-worktrees-launchd.py" ]; then
    OUT="$(HOME="$T/home" DISK_REAPER_STATE_DIR="$T/t29/state" \
        BOUNDED_LIB="$HERE/lib/bounded.sh" \
        CACHE_REAPER="$HERE/pi-cache-reap.sh" VENV_REAPER="$HERE/reap-lane-venvs.sh" \
        WORKTREE_REAPER="$HERE/pi-reap-worktrees.sh" \
        "$PY" "$HERE/pi-reap-worktrees-launchd.py" --script "$REAPER" -- --help 2>&1)"; RC=$?
    assert_eq "$RC" "0" "T29 --help under bash -s exits 0"
    assert_contains "$OUT" "usage:" "T29 ... and prints this script's synopsis, not a shell's header"
    assert_absent "$OUT" "can't open file" "T29 ... never an awk failure on the interpreter binary"

    # (a) A DEAD pid past the staleness bound is reclaimed — the mtime WAS read.
    mkdir -p "$T/t29/state/disk-reaper.lock"
    printf 'pid=999999 started=1\n' >"$T/t29/state/disk-reaper.lock/token"
    touch -t 202001010000 "$T/t29/state/disk-reaper.lock"
    OUT="$(HOME="$T/home" DISK_REAPER_STATE_DIR="$T/t29/state" DISK_REAPER_LOCK_STALE_SECONDS=60 \
        BOUNDED_LIB="$HERE/lib/bounded.sh" \
        CACHE_REAPER="$HERE/pi-cache-reap.sh" VENV_REAPER="$HERE/reap-lane-venvs.sh" \
        WORKTREE_REAPER="$HERE/pi-reap-worktrees.sh" \
        "$PY" "$HERE/pi-reap-worktrees-launchd.py" --script "$REAPER" \
        -- --dry-run --repo "$REPO" --only venv 2>&1)"; RC=$?
    assert_contains "$OUT" "removing STALE lock" "T29 a dead-pid lock is reclaimed under bash -s (the mtime WAS read)"

    # (b) THE LIVE-HOLDER REGRESSION CASE: the same lock, FRESH (now), with a LIVE pid, is a live holder.
    # ⛔ This is NOT the discriminator for the `file_mtime` `$0` fix (review cycle 6 corrected an earlier
    # label here): the pre-fix probe took its VALUE from the target and used `$0` only to pick the stat
    # FLAVOUR, so on this host it behaved, and the live-pid arm returns before the age bound is reached
    # anyway. It stays as a regression case for the (pid, start-time) fence; the `file_mtime` fix is a
    # latent fail-open removal, documented in its own comment, with no Linux-reachable fixture.
    mkdir -p "$T/t29/state/disk-reaper.lock"
    printf 'pid=%s started=1 lstart=%s\n' "$$" "$(LC_ALL=C ps -o lstart= -p $$ 2>/dev/null | sed 's/^ *//;s/ *$//')" \
        >"$T/t29/state/disk-reaper.lock/token"
    OUT="$(HOME="$T/home" DISK_REAPER_STATE_DIR="$T/t29/state" DISK_REAPER_LOCK_STALE_SECONDS=3600 \
        BOUNDED_LIB="$HERE/lib/bounded.sh" \
        CACHE_REAPER="$HERE/pi-cache-reap.sh" VENV_REAPER="$HERE/reap-lane-venvs.sh" \
        WORKTREE_REAPER="$HERE/pi-reap-worktrees.sh" \
        "$PY" "$HERE/pi-reap-worktrees-launchd.py" --script "$REAPER" \
        -- --dry-run --repo "$REPO" --only venv 2>&1)"; RC=$?
    assert_eq "$RC" "5" "T29 a FRESH lock with a LIVE holder is NOT reclaimed under bash -s (exit 5: benign; the age came from the lock, not from $0)"
    assert_absent "$OUT" "removing STALE lock" "T29 ... and it is never called stale"
else
    ok "T29 skipped — no python3 or no launcher on this host"
fi

# ── T30: launchctl that EXISTS but cannot answer is an abstention alarm (review cycle 2, P1) ────
# Without this, a non-zero `launchctl list` (e.g. "Could not find domain" on a headless box) left no
# rows, printed every label as NOT INSTALLED and raised NO alarm — the section abstaining silently on
# a box it could not see.
ENVNAME=t30
mkdir -p "$T/t30/bin"
cat >"$T/t30/bin/launchctl" <<'LC'
#!/usr/bin/env bash
echo "Could not find domain for" >&2
exit 113
LC
chmod +x "$T/t30/bin/launchctl"
if command -v python3 >/dev/null 2>&1; then
    PY_ABS="$(command -v python3)"
    OUT="$(PATH="$T/t30/bin:$PATH" HOME="$T/t30/home" "$PY_ABS" - "$REPO_ROOT/tools/fleet/fleet-health.py" <<'PY' 2>&1
import importlib.util, sys
spec = importlib.util.spec_from_file_location("fh", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print("ALARMS=%r" % (m.reaper_section(),))
PY
)"; RC=$?
    assert_eq "$RC" "0" "T30 the section runs"
    assert_contains "$OUT" "CANNOT READ launchctl" "T30 a launchctl that fails is reported as unreadable"
    assert_absent "$OUT" "ALARMS=[]" "T30 ... and raises an alarm rather than reporting no reapers"
else
    ok "T30 skipped — no python3 on this host"
fi

# ── T31: the installed plist is WELL-FORMED XML, and a malformed template is refused (cycle 3, P1) ─
# Measured on this PR: a placeholder inside an XML COMMENT rendered `--apply` into it, and `--` is
# forbidden inside a comment, so the artifact was not well-formed — launchd would refuse it and the box
# would silently have no reaper while the installer said OK. The repo already refuses this class
# elsewhere (orchestrator-harness/install.sh runs `plutil -lint`).
ENVNAME=t31
REPO="$(mk_repo t31)"
if command -v python3 >/dev/null 2>&1; then
    PY_ABS="$(command -v python3)"
    assert_file "$T/t20/agents/com.eldato.disk-reaper.plist" "T31 the installed plist exists (from T20)"
    if "$PY_ABS" -c 'import sys,xml.etree.ElementTree as ET; ET.parse(sys.argv[1])' \
            "$T/t20/agents/com.eldato.disk-reaper.plist" 2>/dev/null; then
        ok "T31 the INSTALLED plist parses as XML (launchd would accept it)"
    else
        bad "T31 the installed plist is NOT well-formed XML"
    fi
else
    ok "T31 skipped — no python3 to parse XML"
fi
# A template whose comment carries a `--`-rendering placeholder must be REFUSED, not installed.
mkdir -p "$T/t31/tpl" "$T/t31/agents"
cat >"$T/t31/tpl/com.eldato.disk-reaper.plist" <<'PL'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
    <!-- bad: a placeholder inside an XML comment renders --apply -->
    <key>Label</key><string>{{LABEL}}</string>
    <key>ProgramArguments</key><array><string>{{REAPER}}</string><string>{{MODE_FLAG}}</string></array>
    <key>EnvironmentVariables</key><dict><key>HOME</key><string>{{HOME}}</string></dict>
    <key>StartInterval</key><integer>3600</integer>
</dict>
</plist>
PL
OUT="$(HOME="$T/t20/home" DISK_REAPER="$REAPER" DISK_REAPER_REPOS="$REPO" \
    ELDATO_PLATFORM=Darwin LAUNCHD_AGENTS_DIR="$T/t31/agents" LAUNCHD_TEMPLATES_DIR="$T/t31/tpl" \
    LAUNCHCTL="$T/t20/bin/launchctl" LAUNCHCTL_LOADED="$T/t31/loaded" LAUNCHCTL_CALLS=/dev/null \
    ELDATO_LAUNCHER_PY="$PY_HERE" ELDATO_LAUNCHER="$LAUNCHER_HERE" \
    bash "$INST" --install 2>&1)"; RC=$?
assert_eq "$RC" "1" "T31 a rendered plist that is not well-formed is REFUSED"
assert_contains "$OUT" "not well-formed" "T31 ... and the refusal says why"
assert_absent "$(ls "$T/t31/agents" 2>/dev/null || true)" "disk-reaper" "T31 nothing was installed"

# ── T32: the ARMING seam is validated — a typo must not arm a deletion pass (cycle 3, P1) ────────
# `is_dry` tests for exactly "1", so DISK_REAPER_DRY_RUN=true/yes/01 ran the pass ARMED. That is the
# deleted-file direction, one export away — and it is the same rule this PR added for the age floor.
ENVNAME=t32
REPO="$(mk_repo t32)"
OUT="$(DISK_REAPER_DRY_RUN=true run_reaper --repo "$REPO" --only venv 2>&1)"; RC=$?
assert_eq "$RC" "2" "T32 DISK_REAPER_DRY_RUN=true is REFUSED (not silently armed)"
assert_contains "$OUT" "DISK_REAPER_DRY_RUN must be 0 or 1" "T32 ... and the refusal names the seam"
assert_absent "$(cat "$T/$ENVNAME/state/disk-reaper.status" 2>/dev/null || true)" "ok=" \
    "T32 a refused arming writes no pass record"
OUT="$(DISK_REAPER_DRY_RUN=0 run_reaper --repo "$REPO" --only venv 2>&1)"; RC=$?
assert_contains "$OUT" "mode=apply" "T32 an explicit 0 still arms (the seam is validated, not disabled)"
OUT="$(DISK_REAPER_DRY_RUN=1 run_reaper --repo "$REPO" --only venv 2>&1)"; RC=$?
assert_contains "$OUT" "mode=dry-run" "T32 an explicit 1 still dry-runs"

# ── T33: a DISARM is verified, not assumed (cycle 3, P2) ─────────────────────────────────────
# The plist file can be gone while the LOADED job keeps firing hourly until logout — and --status would
# then answer installed=no about a reaper that is still deleting.
ENVNAME=t33
mkdir -p "$T/t33/agents"
cp "$T/t20/agents/com.eldato.disk-reaper.plist" "$T/t33/agents/" 2>/dev/null || true
printf '4242\t0\tcom.eldato.disk-reaper\n' >"$T/t33/loaded"
OUT="$(HOME="$T/t20/home" ELDATO_PLATFORM=Darwin LAUNCHD_AGENTS_DIR="$T/t33/agents" \
    LAUNCHCTL="$T/t20/bin/launchctl" LAUNCHCTL_LOADED="$T/t33/loaded" LAUNCHCTL_CALLS=/dev/null \
    bash "$INST" --uninstall 2>&1)"; RC=$?
assert_eq "$RC" "1" "T33 an uninstall that leaves the agent LOADED fails"
assert_contains "$OUT" "STILL LOADED" "T33 ... and says the job will keep firing hourly"

# ── T34: a STALE pass record is an alarm, not a healthy one (cycle 3, P2) ──────────────────────
# A loaded job that stopped writing its record keeps the last `ok=1` for ever; the pass's own reader
# (--print-status) and the supervisor treat that as stale, so fleet-health must too.
ENVNAME=t34
mkdir -p "$T/t34/state" "$T/t34/home/.pi/agent/state"
printf 'epoch=1\nok=1\nrc=0\nfreed_mb=0\n' >"$T/t34/home/.pi/agent/state/disk-reaper.status"
if command -v python3 >/dev/null 2>&1; then
    PY_ABS="$(command -v python3)"
    OUT="$(HOME="$T/t34/home" "$PY_ABS" - "$REPO_ROOT/tools/fleet/fleet-health.py" <<'PY' 2>&1
import importlib.util, sys
spec = importlib.util.spec_from_file_location("fh", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print("REC=%r" % (m.disk_reaper_record(),))
PY
)"; RC=$?
    assert_contains "$OUT" "STALE" "T34 a record whose epoch is past the staleness bound is reported STALE"
    assert_contains "$OUT" "STALE: last pass" "T34 ... with the age named"
    assert_contains "$OUT" "True)" "T34 ... and it is an ALARM (True), not a healthy read"
else
    ok "T34 skipped — no python3"
fi

# ── T35: a bad env floor does not block invocations that never use it (cycle 3, P2) ─────────────
ENVNAME=t35
REPO="$(mk_repo t35)"
run_reaper --dry-run --repo "$REPO" --only venv >/dev/null 2>&1   # seed a record
OUT="$(DISK_REAPER_VENV_MIN_AGE=30m run_reaper --print-status 2>&1)"; RC=$?
assert_contains "$OUT" "status=" "T35 --print-status still prints the record with a bad env floor set"
assert_absent "$OUT" "DISK_REAPER_VENV_MIN_AGE must be" "T35 ... and is not blocked by it"
OUT="$(DISK_REAPER_VENV_MIN_AGE=30m run_reaper --dry-run --repo "$REPO" --only venv --min-age 1800 2>&1)"; RC=$?
assert_absent "$OUT" "DISK_REAPER_VENV_MIN_AGE must be" "T35 a valid --min-age overrides a bad env floor"
assert_contains "$OUT" "venv_min_age=1800s" "T35 ... and the argv value is the one in force"
OUT="$(DISK_REAPER_VENV_MIN_AGE=30m run_reaper --dry-run --repo "$REPO" --only venv 2>&1)"; RC=$?
assert_eq "$RC" "3" "T35 with no override the bad env floor is a startup refusal (misconfigured, not usage)"
assert_absent "$OUT" "class=" "T35 ... and no class runs"

# ── T36: an EMPTY --only list is refused, not a healthy no-op (cycle 4, P1) ────────────────────
# The guard was `if [ -n "$ONLY" ]`, so `--only ""` (and an empty DISK_REAPER_ONLY) skipped it: ZERO
# classes ran and the pass exited 0 with `ok=1 classes=` — the false PASS the guard exists to prevent.
ENVNAME=t36
REPO="$(mk_repo t36)"
OUT="$(run_reaper --apply --only "" --repo "$REPO" 2>&1)"; RC=$?
assert_eq "$RC" "2" "T36 --only with an EMPTY value is refused"
assert_contains "$OUT" "empty list" "T36 ... and the refusal says why"
assert_absent "$(cat "$T/$ENVNAME/state/disk-reaper.status" 2>/dev/null || true)" "ok=1" \
    "T36 ... and no healthy record is written"
OUT="$(DISK_REAPER_ONLY="" run_reaper --apply --repo "$REPO" 2>&1)"; RC=$?
# ⛔ AN EMPTY ENV VALUE IS NOT AN EMPTY CLASS LIST: `ONLY="${DISK_REAPER_ONLY:-uv,venv,worktree}"` uses
# `:-`, which substitutes the DEFAULT for an empty value — so the env seam can never produce the
# "reap nothing forever" state. Asserting a refusal here would assert a behaviour the shell's own
# expansion makes unreachable (measured: the first draft of this case expected exit 2 and got 0).
assert_contains "$OUT" "only=uv,venv,worktree" "T36 an EMPTY DISK_REAPER_ONLY falls back to the default class list, never a silent no-op"
assert_absent "$OUT" "only= " "T36 ... so the pass never runs zero classes because of an empty env value"
# ── T37: the numeric seams are validated, and an unageable record is STALE (cycle 4, P1/P2) ────
# `[ "$age" -gt "$STALE_SECONDS" ]` errors on a non-number and the ELSE arm ran — so a 56-year-old
# record printed `status=ok`, exit 0, and the supervisor gates its ⛔ line on exactly that rc.
ENVNAME=t37
REPO="$(mk_repo t37)"
OUT="$(DISK_REAPER_STALE_SECONDS=30m run_reaper --dry-run --repo "$REPO" --only venv 2>&1)"; RC=$?
assert_eq "$RC" "3" "T37 a non-numeric DISK_REAPER_STALE_SECONDS is refused at startup"
assert_contains "$OUT" "DISK_REAPER_STALE_SECONDS must be a whole number" "T37 ... and the refusal names the seam"
assert_absent "$OUT" "integer expression expected" "T37 ... before any comparison is attempted"
OUT="$(DISK_REAPER_LOCK_STALE_SECONDS=1h run_reaper --dry-run --repo "$REPO" --only venv 2>&1)"; RC=$?
assert_eq "$RC" "3" "T37 the lock-staleness seam is validated on the same rule"
# A record whose epoch cannot be read must NOT read healthy.
mkdir -p "$T/t37/state"
printf 'epoch=\nok=1\nrc=0\n' >"$T/t37/state/disk-reaper.status"
OUT="$(HOME="$T/home" DISK_REAPER_STATE_DIR="$T/t37/state" bash "$REAPER" --print-status 2>&1)"; RC=$?
assert_eq "$RC" "3" "T37 an unageable record is not a healthy one (--print-status rc 3)"
assert_contains "$OUT" "status=stale" "T37 ... it is reported stale"

# ── T38: a RECYCLED lock pid is not a live holder (cycle 4, P1) ────────────────────────────────
# The token is (pid, start time). A dead pass's pid can be taken by an unrelated process; treating that
# as a live holder makes every future pass exit 4 for ever, and the stale reclaim is never reached.
ENVNAME=t38
REPO="$(mk_repo t38)"
mkdir -p "$T/t38/state/disk-reaper.lock"
# Our own $$ is alive, but the token records a DIFFERENT start time for it ⇒ recycled.
printf 'pid=%s started=1 lstart=Thu Jan  1 00:00:00 1970\n' "$$" >"$T/t38/state/disk-reaper.lock/token"
touch -t 202001010000 "$T/t38/state/disk-reaper.lock"
OUT="$(DISK_REAPER_LOCK_STALE_SECONDS=60 run_reaper --dry-run --repo "$REPO" --only venv 2>&1)"; RC=$?
assert_eq "$RC" "0" "T38 a RECYCLED pid does not block the pass when the lock is past the bound"
assert_contains "$OUT" "RECYCLED pid" "T38 ... and the reclaim says the pid was recycled"
# The other half: a token whose lstart MATCHES this live process is a live holder.
mkdir -p "$T/t38/state/disk-reaper.lock"
LS="$(LC_ALL=C ps -o lstart= -p $$ 2>/dev/null | sed 's/^ *//;s/ *$//')"
printf 'pid=%s started=1 lstart=%s\n' "$$" "$LS" >"$T/t38/state/disk-reaper.lock/token"
touch -t 202001010000 "$T/t38/state/disk-reaper.lock"
OUT="$(DISK_REAPER_LOCK_STALE_SECONDS=60 run_reaper --dry-run --repo "$REPO" --only venv 2>&1)"; RC=$?
assert_eq "$RC" "5" "T38 a matching start time IS a live holder (exit 5: benign), even past the bound"
assert_absent "$OUT" "RECYCLED" "T38 ... and it is never called recycled"

# ── T39: an enabled-but-INACTIVE timer does not certify readiness (cycle 4, P2) ───────────────
# `cloud-cell-bringup.sh --check` dies only on a non-zero rc, so a timer that will never fire must not
# answer 0.
env39() { HOME="$T/t8/home" DISK_REAPER="$REAPER" DISK_REAPER_REPOS="$T/t8repo" \
    DISK_REAPER_STATE_DIR="${STATE39:-$T/t8/home/.pi/agent/state}" \
    SYSTEMD_UNIT_DIR="$T/t8/units" SYSTEMCTL="$T/t8/bin/systemctl" SYSTEMCTL_CALLS=/dev/null \
    SYSTEMCTL_ACTIVE="${1:-active}" bash "$INST" --status; }
OUT="$(env39 active 2>&1)"; RC=$?
assert_eq "$RC" "0" "T39 --status exits 0 for an ACTIVE timer"
OUT="$(env39 inactive 2>&1)"; RC=$?
assert_eq "$RC" "1" "T39 --status exits 1 for an enabled-but-INACTIVE timer"
assert_contains "$OUT" "timer_active=inactive" "T39 ... and says which state it saw"

# ⛔ THE RECORD-RC GATE IS THE READINESS CONTRACT THIS PR EXISTS TO FIX, and nothing pinned it: the
# fixture wrote its record where the verb does not read, so every leg saw `status=never`. rc 3/4 are
# "a human must look"; 5/6 are the documented benign states and MUST NOT fail readiness.
mkdir -p "$T/t39/state"
STATE39="$T/t39/state"
for case39 in "3:1" "4:1" "5:0" "6:0"; do
    rrc="${case39%%:*}"; want="${case39##*:}"
    printf 'epoch=%s\nok=0\nrc=%s\nfreed_mb=0\n' "$(date +%s)" "$rrc" >"$T/t39/state/disk-reaper.status"
    OUT="$(STATE39="$T/t39/state" env39 active 2>&1)"; RC=$?
    assert_eq "$RC" "$want" "T39 a record rc=$rrc gives --status rc $want (3/4 fail readiness, 5/6 do not)"
done
printf 'epoch=%s\nok=0\nrc=6\nfreed_mb=0\n' "$(date +%s -d '3 days ago' 2>/dev/null || echo 1)" >"$T/t39/state/disk-reaper.status"
OUT="$(STATE39="$T/t39/state" env39 active 2>&1)"; RC=$?
assert_eq "$RC" "1" "T39 a STALE record fails readiness even with a benign rc"

# ── T40: fleet-health survives an unreadable seam and an unageable record (cycle 4, P2) ────────
ENVNAME=t40
if command -v python3 >/dev/null 2>&1; then
    PY_ABS="$(command -v python3)"
    OUT="$(HOME="$T/t34/home" DISK_REAPER_STALE_SECONDS=30m "$PY_ABS" - "$REPO_ROOT/tools/fleet/fleet-health.py" <<'PY' 2>&1
import importlib.util, sys
spec = importlib.util.spec_from_file_location("fh", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print("REC=%r" % (m.disk_reaper_record(),))
PY
)"; RC=$?
    assert_eq "$RC" "0" "T40 an unreadable DISK_REAPER_STALE_SECONDS does not crash the scan"
    assert_contains "$OUT" "not a whole number" "T40 ... it is reported as an alarm"
    mkdir -p "$T/t40/home/.pi/agent/state"
    printf 'epoch=\nok=1\nrc=0\n' >"$T/t40/home/.pi/agent/state/disk-reaper.status"
    OUT="$(HOME="$T/t40/home" "$PY_ABS" - "$REPO_ROOT/tools/fleet/fleet-health.py" <<'PY' 2>&1
import importlib.util, sys
spec = importlib.util.spec_from_file_location("fh", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print("REC=%r" % (m.disk_reaper_record(),))
PY
)"; RC=$?
    assert_contains "$OUT" "no readable epoch" "T40 an unageable record is an alarm here too (both readers agree)"
else
    ok "T40 skipped — no python3"
fi

# ── T41: --print-status is a READER, so its seam is validated FIRST (cycle 6, P0) ──────────────
# Validated with the other seams (after the --print-status early exit), a non-numeric
# DISK_REAPER_STALE_SECONDS made `[ "$age" -gt "$30m" ]` error and the ELSE arm set status=ok — so a
# 56-year-old record read healthy and --print-status exited 0, which is exactly the rc
# cloud-cell-supervisor gates its ⛔ line on.
ENVNAME=t41
mkdir -p "$T/t41/state"
printf 'epoch=1\nok=1\nrc=0\nfreed_mb=0\n' >"$T/t41/state/disk-reaper.status"
OUT="$(HOME="$T/home" DISK_REAPER_STATE_DIR="$T/t41/state" DISK_REAPER_STALE_SECONDS=30m \
    bash "$REAPER" --print-status 2>&1)"; RC=$?
assert_eq "$RC" "3" "T41 --print-status REFUSES a non-numeric staleness bound (it must not answer 0)"
assert_contains "$OUT" "DISK_REAPER_STALE_SECONDS must be a whole number" "T41 ... and names the seam"
assert_absent "$OUT" "status=ok" "T41 ... and never reports the record as ok"
# The same record with a VALID bound is judged on its age.
OUT="$(HOME="$T/home" DISK_REAPER_STATE_DIR="$T/t41/state" bash "$REAPER" --print-status 2>&1)"; RC=$?
assert_eq "$RC" "3" "T41 a very old record with a valid bound is stale"
assert_contains "$OUT" "status=stale" "T41 ... and says so"

# ── T42: an UNMEASURABLE reclaim is labelled in the record, not written as a measured 0 ────────
# `freed_mb=0 freed_mb_uv=unmeasured … detail=ok` made "could not measure" and "measured zero" the same
# record, while the console line said "not a measured zero".
ENVNAME=t42
REPO="$(mk_repo t42)"
OUT="$(DF_BIN=/nonexistent/df run_reaper --apply --repo "$REPO" --only venv --min-age 0 2>&1)"; RC=$?
ST="$(cat "$T/$ENVNAME/state/disk-reaper.status" 2>/dev/null || true)"
assert_contains "$ST" "freed_mb_unmeasured=venv" "T42 the record names the class whose reclaim was not measured"
assert_contains "$ST" "df could not measure" "T42 ... and its detail says so instead of 'ok'"
assert_contains "$ST" "freed_mb_venv=unmeasured" "T42 ... while still refusing to print a measured 0 for it"
OUT="$(HOME="$T/home" DISK_REAPER_STATE_DIR="$T/$ENVNAME/state" bash "$REAPER" --print-status 2>&1)"
assert_contains "$OUT" "freed_mb_unmeasured=venv" "T42 --print-status surfaces it too"

# ── T43: a worktree checkout under a path with a SPACE is measured at its real path (cycle 6, P2) ─
ENVNAME=t43
REPO="$(mk_repo 't43 space')"
WT_SP="$(mk_wt "$REPO" spaced feat/t43-spaced)"
commit_in "$WT_SP" "$OLD_DATE" spaced
OUT="$(run_reaper --dry-run --repo "$REPO" --only worktree --aged-days 7 2>&1)"; RC=$?
assert_contains "$OUT" "WOULD-REMOVE class=worktree" "T43 a checkout under a spaced path is still selected"
assert_contains "$OUT" "${WT_SP}" "T43 ... and is named by its FULL path, not truncated at the space"
assert_absent "$OUT" "du could not read it" "T43 ... so its size is measured rather than blamed on a missing path"

# ── T44: --status fails when the RECORD CANNOT BE READ at all (cycle 8, P0) ─────────────────────
# A startup refusal (a numeric seam, a missing library) writes NO record, so `--print-status` prints no
# `status=` line and exits 3. A text-only match on failed/stale/never certified health on exactly that
# state — and cloud-cell-bringup gates CELL READY on this rc. Both platforms.
ENVNAME=t44
REPO="$(mk_repo t44)"
mkdir -p "$T/t44/state" "$T/t44/units"
printf 'epoch=1\nok=1\nrc=0\nfreed_mb=0\n' >"$T/t44/state/disk-reaper.status"
OUT="$(HOME="$T/t8/home" DISK_REAPER="$REAPER" DISK_REAPER_REPOS="$T/t8repo" \
    DISK_REAPER_STATE_DIR="$T/t44/state" DISK_REAPER_STALE_SECONDS=30m \
    SYSTEMD_UNIT_DIR="$T/t8/units" SYSTEMCTL="$T/t8/bin/systemctl" SYSTEMCTL_CALLS=/dev/null \
    bash "$INST" --status 2>&1)"; RC=$?
assert_eq "$RC" "1" "T44 systemd --status fails when --print-status cannot produce a status line"
assert_contains "$OUT" "without a status line" "T44 ... and says the record could not be judged"
# The same on the launchd arm.
mkdir -p "$T/t44/agents"
printf '4242\t0\tcom.eldato.disk-reaper\n' >"$T/t44/loaded"
OUT="$(HOME="$T/t20/home" ELDATO_PLATFORM=Darwin DISK_REAPER="$REAPER" DISK_REAPER_REPOS="$T/t8repo" \
    DISK_REAPER_STATE_DIR="$T/t44/state" DISK_REAPER_STALE_SECONDS=30m \
    LAUNCHD_AGENTS_DIR="$T/t44/agents" LAUNCHCTL="$T/t20/bin/launchctl" \
    LAUNCHCTL_LOADED="$T/t44/loaded" LAUNCHCTL_CALLS=/dev/null \
    bash "$INST" --status 2>&1)"; RC=$?
assert_eq "$RC" "1" "T44 launchd --status fails on an unjudgeable record too"
assert_contains "$OUT" "without a status line" "T44 ... with the same reason"

# ── T45: fleet-health reads the record at DISK_REAPER_STATE_DIR, not a hardcoded HOME path ─────
# Both artifacts render that seam and both other readers honour it; a hardcoded path made
# fleet-health alarm on a box whose state dir is elsewhere while the other two said ok.
ENVNAME=t45
mkdir -p "$T/t45/alt" "$T/t45/home/.pi/agent/state"
printf 'epoch=%s\nok=1\nrc=0\nfreed_mb=5\nfreed_mb_uv=5\nfreed_mb_venv=0\nfreed_mb_worktree=0\n' "$(date +%s)" \
    >"$T/t45/alt/disk-reaper.status"
if command -v python3 >/dev/null 2>&1; then
    PY_ABS="$(command -v python3)"
    OUT="$(HOME="$T/t45/home" DISK_REAPER_STATE_DIR="$T/t45/alt" "$PY_ABS" - "$REPO_ROOT/tools/fleet/fleet-health.py" <<'PY' 2>&1
import importlib.util, sys
spec = importlib.util.spec_from_file_location("fh", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print("REC=%r" % (m.disk_reaper_record(),))
PY
)"; RC=$?
    assert_contains "$OUT" "record ok=1" "T45 fleet-health reads the record at DISK_REAPER_STATE_DIR"
    assert_absent "$OUT" "UNREADABLE" "T45 ... and does not look only at the default HOME path"
else
    ok "T45 skipped — no python3"
fi

# ── T46: an UNCREATABLE lock dir is a filesystem problem (4, RED), not "the lock is held" (5) ────
# With no token, `file_mtime` on the missing dir is empty so `age=0`, and the contention arm reported it
# BENIGN — a box that can never reap, certified. The lock dir's ABSENCE is the discriminator.
ENVNAME=t46
REPO="$(mk_repo t46)"
mkdir -p "$T/t46/state"
chmod 500 "$T/t46/state"
OUT="$(HOME="$T/home" DISK_REAPER_STATE_DIR="$T/t46/state" DISK_REAPER_REPOS="$REPO" \
    bash "$REAPER" --dry-run --repo "$REPO" --only venv 2>&1)"; RC=$?
chmod 700 "$T/t46/state"
assert_eq "$RC" "4" "T46 a state dir whose lock cannot be created is a FAILURE (4), not a benign skip"
assert_contains "$OUT" "cannot create" "T46 ... and the refusal names the filesystem problem"
assert_absent "$OUT" "benign" "T46 ... and never calls it contention"

# ── T47: a class that could not be SET UP records `misconfigured` + `not-run`, not `refused` + 0 ──
# `refused` is defined as "the delegate RAN and said no"; a missing delegate never ran, and recording
# `freed_mb=<class>=0` claimed a measured zero for a class that did nothing.
ENVNAME=t47
REPO="$(mk_repo t47)"
OUT="$(VENV_REAPER=/nonexistent/reap-lane-venvs.sh run_reaper --apply --repo "$REPO" --only venv 2>&1)"; RC=$?
ST="$(cat "$T/$ENVNAME/state/disk-reaper.status" 2>/dev/null || true)"
assert_eq "$RC" "3" "T47 a missing delegate is a misconfiguration (pass rc 3)"
assert_contains "$ST" "verdict_venv=misconfigured" "T47 the class verdict says misconfigured, not 'refused'"
assert_contains "$ST" "freed_mb_venv=not-run" "T47 ... and its reclaim is not-run, not a measured 0"
assert_absent "$ST" "df could not measure" "T47 ... and the detail does not blame df for a class that never ran"

# ── T48: the arming floor's numeric guard runs on BOTH install platforms ───────────────────────
# It lived only in the systemd arm, so the Darwin arm rendered `--aged-days 7d`, which can never work.
ENVNAME=t48
REPO="$(mk_repo t48)"
mkdir -p "$T/t48/agents"
OUT="$(HOME="$T/t20/home" DISK_REAPER="$REAPER" DISK_REAPER_REPOS="$REPO" \
    DISK_REAPER_WT_AGED_DAYS=7d ELDATO_PLATFORM=Darwin LAUNCHD_AGENTS_DIR="$T/t48/agents" \
    LAUNCHCTL="$T/t20/bin/launchctl" LAUNCHCTL_LOADED="$T/t48/loaded" LAUNCHCTL_CALLS=/dev/null \
    ELDATO_LAUNCHER_PY="$PY_HERE" ELDATO_LAUNCHER="$LAUNCHER_HERE" \
    bash "$INST" --install 2>&1)"; RC=$?
assert_eq "$RC" "1" "T48 a non-numeric worktree floor is refused on the Darwin path too"
assert_contains "$OUT" "DISK_REAPER_WT_AGED_DAYS must be a whole number" "T48 ... naming the variable"
assert_absent "$(ls "$T/t48/agents" 2>/dev/null || true)" "disk-reaper" "T48 nothing was installed"

# ── T49: the pass leaves NO probe scratch behind (including on a STARTUP refusal) ───────────────
# The leak fix (create the scratch in the PARENT, before any command substitution, and install the EXIT
# trap before the scratch exists) is only correct if this ordering holds — and nothing pinned it.
ENVNAME=t49
REPO="$(mk_repo t49)"
mkdir -p "$T/t49/tmp" "$T/t49/tmp2" "$T/t49/ro"
OUT="$(HOME="$T/home" TMPDIR="$T/t49/tmp" TB_TIMEOUT_FORCE_INTERNAL=1 \
    DISK_REAPER_STATE_DIR="$T/t49/state" DISK_REAPER_REPOS="$REPO" \
    CACHE_REAP_UV_DIR="$T/t49/nc" CACHE_REAP_LOG="$T/t49/state/c.log" \
    REAP_WT_LOG="$T/t49/state/w.log" REAP_VENV_LOG="$T/t49/state/v.log" \
    bash "$REAPER" --dry-run --repo "$REPO" --only venv 2>&1)"; RC=$?
assert_eq "$(ls -d "$T/t49/tmp"/bounded.* 2>/dev/null | wc -l | tr -d ' ')" "0" \
    "T49 a completed pass leaves no bounded.* scratch dir (the probe scratch is created in the parent)"
# And a STARTUP refusal must not leak either: the trap is installed before the scratch is created.
OUT="$(HOME="$T/home" TMPDIR="$T/t49/tmp2" TB_TIMEOUT_BIN=/nonexistent/timeout \
    DISK_REAPER_STATE_DIR="$T/t49/state" bash "$REAPER" --dry-run 2>&1)"; RC=$?
assert_eq "$RC" "3" "T49 the unusable-watchdog startup refusal still exits 3"
assert_eq "$(ls -d "$T/t49/tmp2"/bounded.* 2>/dev/null | wc -l | tr -d ' ')" "0" \
    "T49 ... and leaves no scratch dir behind (the trap precedes the scratch)"

echo
echo "──────────────────────────────────────────────────────────────────────"
if [ "$FAIL" -eq 0 ]; then
    echo "ALL PASS ($PASS assertions)"
    exit 0
fi
echo "FAILURES: $FAIL of $PASS assertions"
exit 1
