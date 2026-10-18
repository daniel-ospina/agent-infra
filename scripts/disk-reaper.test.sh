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
CACHE_REAP_MAX_MB=1 CACHE_REAP_UV_DIR="$T/$ENVNAME/cache-uv"
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
CACHE_REAP_MAX_MB=1 CACHE_REAP_UV_DIR="$T/t7/cache-uv"
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
  *is-active*) echo active ;;
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
OUT="$(inst --dry-run 2>&1)"
assert_contains "$OUT" "would install" "T8 --dry-run reports without writing"
OUT="$(inst --status 2>&1)"; RC=$?
assert_eq "$RC" "0" "T8 --status exits 0 for a healthy install"
assert_contains "$OUT" "installed=yes" "T8 --status reports the install"
assert_contains "$OUT" "enabled=enabled" "T8 --status reports the timer as enabled"

echo
echo "──────────────────────────────────────────────────────────────────────"
if [ "$FAIL" -eq 0 ]; then
    echo "ALL PASS ($PASS assertions)"
    exit 0
fi
echo "FAILURES: $FAIL of $PASS assertions"
exit 1
