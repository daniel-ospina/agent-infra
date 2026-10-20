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
#   T16 the installer refuses a system unit rendered from transient scratch space (the cells' 127),
#       the installed unit's SuccessExitStatus is exactly {0, 6}, and the three delegate pins are
#       present and absolute.
#   T17 the VENV class ALONE clears a dead lane's .venv and never a live one's — same fixture, same
#       age, both floors out of the way, so the live holder is the only difference (#2159).
#   T18 a delegate's exit is neither swallowed nor mis-coloured, PER CLASS: its fail-closed 3 is RED
#       (never 6), uv's 4 and 7 are deferrals (pass 6, ok=0), venv's 4 is a red removal failure, 5 is
#       red in apply and informative in dry-run, 2 is red, 3 outranks 4 across repos in both orders,
#       and `detail=` names the DELEGATE's own code in every class (#2156, #2036).
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
# The record is this feature's verdict channel, so everything written into it must be reachable from
# the READER. `classes=` and `repos=` were written every pass and printed by nobody, so "which sinks and
# which checkouts did the last pass actually cover" — the first question after DISK_REAPER_REPOS
# changes — had no answer on any surface. Deleting these two lines used to keep all 162 assertions green.
assert_contains "$(HOME="$T/home" DISK_REAPER_STATE_DIR="$T/$ENVNAME/state" bash "$REAPER" --print-status 2>&1)" \
    "classes=" "T7 --print-status answers WHICH classes the last pass ran"
assert_contains "$(HOME="$T/home" DISK_REAPER_STATE_DIR="$T/$ENVNAME/state" bash "$REAPER" --print-status 2>&1)" \
    "repos=" "T7 --print-status answers WHICH checkouts it scanned"

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
# ⛔ AND IT WRITES NOTHING — asserted on a FRESH unit dir, because "would install" in the output is a
# claim, not a fact, and an operator who believes --dry-run disarms or installs anything is the failure
# this script's own header is about. T12 covers the --uninstall no-op; this is do_install's branch.
FRESH="$T/t8/fresh-units"; rm -rf "$FRESH"
OUT="$(HOME="$T/t8/home" DISK_REAPER="$REAPER" DISK_REAPER_REPOS="$REPO" \
    DISK_REAPER_STATE_DIR="$T/t8/home/.pi/agent/state" \
    SYSTEMD_UNIT_DIR="$FRESH" SYSTEMCTL="$T/t8/bin/systemctl" SYSTEMCTL_CALLS="$T/t8/calls-dry.log" \
    bash "$INST" --install --dry-run 2>&1)"; RC=$?
assert_eq "$RC" "0" "T8 --install --dry-run exits 0"
assert_contains "$OUT" "would install" "T8 --install --dry-run previews the install"
assert_eq "$(ls -A "$FRESH" 2>/dev/null | wc -l | tr -d ' ')" "0" \
    "T8 --install --dry-run wrote NOTHING into the unit dir (it is a preview, not a disarm or an install)"
assert_absent "$(cat "$T/t8/calls-dry.log" 2>/dev/null || true)" "enable" \
    "T8 nor did it enable anything"
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
assert_eq "$RC" "4" "T9 a pass that cannot take the lock exits 4"
assert_file "$T/t9/state/disk-reaper.lock/token" \
    "T9 the contender left the LIVE owner's lock in place (it never held it)"
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
WT="$(mk_wt "$REPO" dead feat/t14-dead)"
commit_in "$WT" "$OLD_DATE" dead
OUT="$(TB_TIMEOUT_FORCE_INTERNAL=1 run_reaper --dry-run --repo "$REPO" --only worktree --aged-days 7 2>&1)"; RC=$?
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
OUT="$(PATH="$T/t14/passbin:$PATH" T14_CALLS="$T/t14/calls" run_reaper --dry-run --repo "$REPO" --only worktree --aged-days 7 2>&1)"; RC=$?
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

# ── T16: the installer REFUSES a system unit rendered from transient scratch space ──────────────
# MEASURED (2026-10-18, pi-cell-2 and pi-cell-3). A harness ran the installer with
# HOME=/tmp/tmp.XXXX/bg/home and no SYSTEMD_UNIT_DIR, so `choose_target` took the SYSTEM target and
# wrote `ExecStart=/bin/bash /tmp/tmp.XXXX/bg/home/.pi/agent/scripts/disk-reaper.sh --apply` into
# /etc/systemd/system. The mktemp dir was deleted before the first tick, so every hourly pass has
# exited 127 (command not found) ever since, while `systemctl list-timers` kept showing the job as
# scheduled and healthy — the disks sat at 94-96% with a "reaper" on the clock. The installer is the
# only component that can see the path is transient by construction, so it must refuse it.
ENVNAME=t16
REPO="$(mk_repo t16)"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/tmp.XXXXXXXXXX")"
mkdir -p "$SCRATCH/bg/home/.pi/agent/scripts" "$T/t16/units"
cp "$REAPER" "$SCRATCH/bg/home/.pi/agent/scripts/disk-reaper.sh"
: >"$T/t16/calls.log"
OUT="$(HOME="$SCRATCH/bg/home" SUDO="true" SYSTEMCTL="$T/t8/bin/systemctl" \
      SYSTEMCTL_CALLS="$T/t16/calls.log" DISK_REAPER_REPOS="$REPO" \
      TEMPLATES_DIR="$HERE/../templates/systemd" \
      bash "$INST" --install 2>&1)"; RC=$?
assert_eq "$RC" "1" "T16 a system install rendered from a mktemp HOME is REFUSED"
assert_contains "$OUT" "REFUSING" "T16 and the refusal is loud, not a silent skip"
assert_absent "$(cat "$T/t16/calls.log" 2>/dev/null || true)" "enable --now" \
    "T16 nothing is ENABLED for a unit that could never run"
assert_absent "$(cat "$T/t16/calls.log" 2>/dev/null || true)" "daemon-reload" \
    "T16 and no unit directory is touched at all"
# The guard must not false-block: the documented test override (a scratch unit dir + fake systemctl)
# is exactly how this suite installs, so that path must still succeed.
OUT="$(HOME="$SCRATCH/bg/home" DISK_REAPER="$SCRATCH/bg/home/.pi/agent/scripts/disk-reaper.sh" \
      DISK_REAPER_REPOS="$REPO" SYSTEMD_UNIT_DIR="$T/t16/units" \
      TEMPLATES_DIR="$HERE/../templates/systemd" \
      SYSTEMCTL="$T/t8/bin/systemctl" SYSTEMCTL_CALLS="$T/t16/calls.log" \
      bash "$INST" --install 2>&1)"; RC=$?
assert_eq "$RC" "0" "T16 an explicit SYSTEMD_UNIT_DIR override still installs (no false block)"
assert_contains "$OUT" "target=override" "T16 and it reports the override target"
assert_contains "$(cat "$T/t16/calls.log")" "daemon-reload" \
    "T16 positive control: a real install DOES log daemon-reload (so its absence above is meaningful)"
assert_contains "$(cat "$T/t16/calls.log")" "enable --now" \
    "T16 positive control: a real install DOES enable the timer"
rm -rf "$SCRATCH"
# A unit that only reports WORK PENDING, a FAILED removal or a MISCONFIGURATION must not read green,
# and a delegate's stated REFUSAL must. The template's SuccessExitStatus is the thing that decides
# that, so assert on the rendered bytes.
# Directive-level, not literal-string: strip comments, take only `SuccessExitStatus=` lines, and require
# the token set to be EXACTLY {0, 6}. A substring grep would pass on `0 4 5`, miss `0 4`, and false-fail
# on a comment that quotes the old value.
SES_LINES="$(grep -h '^SuccessExitStatus=' "$T/t16/units/eldato-disk-reaper.service" | sed 's/^[^=]*=//')"
assert_eq "$(printf '%s\n' "$SES_LINES" | grep -c .)" "1" \
    "T16 the unit declares exactly one SuccessExitStatus directive"
SES_TOKENS="$(printf '%s\n' "$SES_LINES" | tr -s '[:space:]' '\n' | grep . | sort -n | tr '\n' ' ')"
assert_eq "$SES_TOKENS" "0 6 " \
    "T16 the accepted set is EXACTLY {0, 6}: a fully-clean pass, and a delegate's refusal"
assert_eq "$(printf '%s\n' "$SES_LINES" | tr -s '[:space:]' '\n' | grep -c '^0$')" "1" \
    "T16 only a fully-clean pass (0) is unconditionally success"
assert_eq "$(printf '%s\n' "$SES_LINES" | tr -s '[:space:]' '\n' | grep -c '^6$')" "1" \
    "T16 a uv-class DEFERRAL (6) is accepted, so a busy cell does not go red hourly (#2036)"
for masked in 3 4 5; do
    assert_absent "$SES_LINES" "$masked" \
        "T16 exit $masked is NOT masked as success (3 fail-closed, 4 removal failed, 5 over bound)"
done
assert_contains "SuccessExitStatus=0 4 5" "4" \
    "T16 positive control: the assert_absent above CAN match a code in a directive's value"
# The unit PINS the three delegates beside the installed entry point, so a unit that ran whatever sat in
# $HOME cannot come back. Nothing else asserts those three lines, and their measured defect was
# pi-cell-3 running a stale farmed delegate while the installed one was never consulted.
for d in pi-cache-reap.sh reap-lane-venvs.sh pi-reap-worktrees.sh; do
    LINE="$(grep -h "^Environment=.*_REAPER=" "$T/t16/units/eldato-disk-reaper.service" | grep -F "/$d")"
    assert_contains "$LINE" "/$d" "T16 the unit pins $d to the installed directory"
    case "${LINE##*=}" in
        /*) ok "T16 and $d's pin is an ABSOLUTE path (a relative one would resolve against the unit's cwd)" ;;
        *)  bad "T16 $d's pin is not absolute: $LINE" ;;
    esac
done

# ── T17: the VENV class alone clears a DEAD lane and never a LIVE one (#2159/#1949) ────────────────
# T2 proves both classes agree on one fixture, but its second pass removes the whole WORKTREE, so it
# cannot show that the venv class was the actor. This is the distinction #2159 asks to be proven on
# its own, because the venv is the sink that actually holds ~1.1 GB per live lane: a reaper that clears
# dead residue is necessary and must never touch a live lane's env. ONE fixture, TWO worktrees, both
# `.venv`s with a 2020 mtime and `--min-age 0`, so AGE and FLOOR are eliminated as explanations — the
# only remaining difference between the two rows is a live holder.
LSOF_T17="$(command -v lsof || true)"
if [ -z "$LSOF_T17" ] && [ ! -d /proc ]; then
    echo "  ⏭ SKIP T17: neither lsof nor /proc — this host cannot take a cwd reading at all"
else
    ENVNAME=t17
    REPO="$(mk_repo t17)"
    WT_DEAD="$(mk_wt "$REPO" vdead feat/t17-vdead)"
    WT_LIVE="$(mk_wt "$REPO" vlive feat/t17-vlive)"
    mk_venv "$WT_DEAD" 6
    mk_venv "$WT_LIVE" 6
    ( cd "$WT_LIVE" && exec sleep 300 ) &
    LIVE17=$!
    SLEEPERS="$SLEEPERS $LIVE17"
    sleep 1
    OUT="$(VENV_REAPER="$HERE/reap-lane-venvs.sh" run_reaper --apply --repo "$REPO" --only venv --min-age 0 2>&1)"; RC=$?
    assert_eq "$RC" "0" "T17 a venv-only apply pass is not a failure"
    [ "$RC" = 0 ] || printf '%s\n' "$OUT" | grep -E 'class=|FAIL|KEEP|REAP' | sed 's/^/      /'
    assert_nodir "$WT_DEAD/.venv" "T17 the GONE lane's .venv is cleared"
    assert_dir "$WT_DEAD" "T17 and only its .venv — the worktree is the worktree owner's, not ours"
    assert_dir "$WT_LIVE/.venv" "T17 the LIVE lane's .venv survives the same pass"
    assert_contains "$OUT" "KEEP live-cwd" "T17 and the surviving row names its deciding witness"
    assert_contains "$OUT" "reaped=1" "T17 exactly one env was reaped"
    # The distinguishing half: the SAME env is cleared once the holder is gone.
    kill "$LIVE17" 2>/dev/null; wait "$LIVE17" 2>/dev/null
    sleep 1
    OUT="$(VENV_REAPER="$HERE/reap-lane-venvs.sh" run_reaper --apply --repo "$REPO" --only venv --min-age 0 2>&1)"; RC=$?
    assert_eq "$RC" "0" "T17 the follow-up venv pass exits 0"
    assert_nodir "$WT_LIVE/.venv" "T17 with no holder the same .venv IS cleared"
    assert_absent "$OUT" "KEEP live-cwd" "T17 and it is no longer reported live"
fi

# ── T18: a delegate's EXIT CODE is neither swallowed nor painted red (#2156, #2036) ──
# Three codes, three different meanings, and the pass must keep them apart. The stubs are the
# DELEGATE, so this is the contract between the entry point and the three owners, not a policy test.
mkdir -p "$T/t18/repo-a" "$T/t18/repo-b"
for r in repo-a repo-b; do
    "$REAL_GIT" -C "$T/t18/$r" init -q -b main >/dev/null 2>&1 || "$REAL_GIT" -C "$T/t18/$r" init -q
    printf 'base\n' >"$T/t18/$r/f.txt"
    "$REAL_GIT" -C "$T/t18/$r" add f.txt
    "$REAL_GIT" -C "$T/t18/$r" commit -qm init
done
mk_code_stub() { # mk_code_stub <path> <exit code>
    printf '#!/bin/bash\nexit %s\n' "$2" >"$1"; chmod +x "$1"
}
# The three delegate vocabularies are NOT interchangeable, so the stubs are per CLASS:
#   venv/worktree: 3 = fail-closed (RED), 4 = a removal FAILED (RED)
#   uv:            3 = fail-closed (RED), 4 = did not run / 7 = DEFERRED (both GREEN, code 6)
mk_code_stub "$T/t18/failclosed.sh" 3
mk_code_stub "$T/t18/removal.sh" 4
mk_code_stub "$T/t18/over.sh" 5
mk_code_stub "$T/t18/badargs.sh" 2
mk_code_stub "$T/t18/cache-defer.sh" 7
ENVNAME=t18

# (a) A DELEGATE'S FAIL-CLOSED 3 STAYS RED. All three owners use 3 for "I could not do the work", so
#     flattening it into the green arm makes a permanently INERT reaper read as a succeeding hourly job
#     (measured: PS_BIN=/nonexistent → this exact exit). It must never become 6.
OUT="$(VENV_REAPER="$T/t18/failclosed.sh" run_reaper --apply --repo "$T/t18/repo-a" --only venv 2>&1)"; RC=$?
ST="$(cat "$T/t18/state/disk-reaper.status" 2>/dev/null || true)"
assert_eq "$RC" "3" "T18 a delegate's fail-closed 3 is a RED pass, never 6"
assert_contains "$ST" "ok=0" "T18 and the record is not healthy"
assert_contains "$ST" "rc=3" "T18 and it carries the red code"
assert_contains "$ST" "verdict_venv=fail-closed" "T18 the class verdict says fail-closed"
assert_contains "$ST" "exited 3" "T18 the detail names the DELEGATE's own code, not the pass's"
assert_absent "$ST" "deferred" "T18 a fail-closed class is never recorded as a deferral"
SRC2=0; HOME="$T/home" DISK_REAPER_STATE_DIR="$T/t18/state" bash "$REAPER" --print-status >/dev/null 2>&1 || SRC2=$?
assert_eq "$SRC2" "3" "T18 --print-status exits 3 for a failed pass"

# (a2) A DELEGATE'S DEFERRAL IS GREEN — BUT ONLY FOR THE CLASS THAT CAN DEFER. `pi-cache-reap.sh` 4
#      (another pass holds the lock) and 7 (a live tool holds the cache) mean "ran, declined, claimed
#      nothing": routine on a busy cell, so the unit must not redden (#2036) — while the RECORD still
#      says ok=0 / deferred. venv's 4 means "a removal FAILED" and is judged separately in (b2).
OUT="$(CACHE_REAPER="$T/t18/cache-defer.sh" run_reaper --apply --only uv 2>&1)"; RC=$?
ST="$(cat "$T/t18/state/disk-reaper.status" 2>/dev/null || true)"
assert_eq "$RC" "6" "T18 a uv DEFERRAL (a live tool holds the cache) is 6 — the one green non-zero code"
assert_contains "$ST" "ok=0" "T18 a deferral still records the pass as NOT healthy"
assert_contains "$ST" "rc=6" "T18 and the record carries the deferral code"
assert_contains "$ST" "verdict_uv=deferred" "T18 the class verdict says deferred, not ok and not failed"
assert_contains "$ST" "detail=pi-cache-reap.sh exited 7" "T18 the detail names the DELEGATE's own code (7), never the pass's (6)"
assert_absent "$ST" "pi-cache-reap.sh exited 6" "T18 never the mapped pass code"
SRC3=0; HOME="$T/home" DISK_REAPER_STATE_DIR="$T/t18/state" bash "$REAPER" --print-status >/dev/null 2>&1 || SRC3=$?
assert_eq "$SRC3" "3" "T18 --print-status still exits 3 for a deferral (the record is the verdict channel)"

# (a3) uv's LOCK-HELD code is 4, which means the OPPOSITE of 4 in the sibling owners: it is a benign
#      "did not run", not a failed removal. Getting this wrong reddens a healthy box once an hour.
OUT="$(CACHE_REAPER="$T/t18/removal.sh" run_reaper --apply --only uv 2>&1)"; RC=$?
ST="$(cat "$T/t18/state/disk-reaper.status" 2>/dev/null || true)"
assert_eq "$RC" "6" "T18 uv's 4 (another pass holds the lock) is a DEFERRAL, not a removal failure"
assert_contains "$ST" "verdict_uv=deferred" "T18 and the class says deferred"
assert_absent "$ST" "verdict_uv=removal-failed" "T18 never 'a removal FAILED' for a pass that attempted none"

# (b) OVER BOUND in an APPLY pass: the class reclaimed nothing for a real condition. Before #2156
#     `worst_rc` DROPPED 5, so this pass recorded `rc=0 verdict_venv=ok` — a false PASS at exactly
#     the condition the floor exists to make visible.
OUT="$(VENV_REAPER="$T/t18/over.sh" run_reaper --apply --repo "$T/t18/repo-a" --only venv 2>&1)"; RC=$?
ST="$(cat "$T/t18/state/disk-reaper.status" 2>/dev/null || true)"
assert_eq "$RC" "3" "T18 over-bound in APPLY mode is a red pass (nothing was reclaimed)"
assert_contains "$ST" "verdict_venv=fail-closed" "T18 and the class verdict says so"
assert_absent "$ST" "verdict_venv=ok" "T18 the exit 5 is NOT swallowed into an ok class"
assert_contains "$ST" "ok=0" "T18 the record does not read healthy"
# ... and in a DRY RUN the same code is INFORMATIVE: the pass removed nothing because it was asked not
# to, and there is no apply-mode condition to surface.
OUT="$(VENV_REAPER="$T/t18/over.sh" run_reaper --dry-run --repo "$T/t18/repo-a" --only venv 2>&1)"; RC=$?
ST="$(cat "$T/t18/state/disk-reaper.status" 2>/dev/null || true)"
assert_eq "$RC" "5" "T18 the SAME code in a dry run is 5 (informative)"
assert_contains "$ST" "verdict_venv=over-bound" "T18 and the class verdict says over-bound"
assert_contains "$ST" "ok=1" "T18 a dry run that found work is a successful dry run"

# (b2) A REMOVAL FAILURE for the class where 4 MEANS that. 4 must stay red and must be labelled for
#      what it is — the mirror of (a3), and the pair is what proves the mapping is per-class.
OUT="$(VENV_REAPER="$T/t18/removal.sh" run_reaper --apply --repo "$T/t18/repo-a" --only venv 2>&1)"; RC=$?
ST="$(cat "$T/t18/state/disk-reaper.status" 2>/dev/null || true)"
assert_eq "$RC" "4" "T18 venv's 4 (a removal FAILED) is 4 — red"
assert_contains "$ST" "verdict_venv=removal-failed" "T18 and the class verdict names the failed removal"
assert_absent "$ST" "deferred" "T18 a failed removal is never recorded as a deferral"

# (c) COULD NOT RUN AS ASKED: the delegate returned 2 (bad arguments / wrong invocation). This is 3 —
#     red — and it must NOT be mistaken for either a deferral or a delegate's own fail-closed 3.
OUT="$(VENV_REAPER="$T/t18/badargs.sh" run_reaper --apply --repo "$T/t18/repo-a" --only venv 2>&1)"; RC=$?
ST="$(cat "$T/t18/state/disk-reaper.status" 2>/dev/null || true)"
assert_eq "$RC" "3" "T18 a delegate that could not run (exit 2) is a red pass, never 6"
assert_contains "$ST" "exited 2" "T18 and the detail names the real code"

# (e) A DEFERRAL CANNOT MASK A REMOVAL FAILURE ACROSS CLASSES. uv defers (6) while venv fails a
#     removal (4): the pass must exit 4 — a green-ish class may never swallow a red one — and both
#     delegate codes must be named in `detail=`. The two-repo case in (d) proves it within ONE class;
#     this proves it across classes, which is the pair an operator actually sees when a cache is busy.
OUT="$(CACHE_REAPER="$T/t18/cache-defer.sh" VENV_REAPER="$T/t18/removal.sh" \
      run_reaper --apply --repo "$T/t18/repo-a" --only uv,venv 2>&1)"; RC=$?
ST="$(cat "$T/t18/state/disk-reaper.status" 2>/dev/null || true)"
assert_eq "$RC" "4" "T18 a deflected cache (6) cannot mask a failed venv removal (4)"
assert_contains "$ST" "verdict_uv=deferred" "T18 the uv deferral is still recorded"
assert_contains "$ST" "verdict_venv=removal-failed" "T18 and the venv failure is recorded too"
assert_contains "$ST" "ok=0" "T18 the pass does not read healthy"
assert_contains "$ST" "pi-cache-reap.sh exited 7" "T18 detail names the cache's own deferral code"
assert_contains "$ST" "reap-lane-venvs.sh exited 4" "T18 detail names the venv's own failure code"


# (d) SEVERITY ACROSS REPOS: one repo's FAIL-CLOSED must not mask another repo's REMOVAL FAILURE, and
#     `worst_rc` must be order-independent — otherwise which repo git lists first decides whether a
#     real failure is visible. The stub fails closed (3) on its first call and fails a removal (4) on
#     its second, so the two repos genuinely produce DIFFERENT codes. (An earlier version seeded this
#     state with `: >file`, an EMPTY file: `cat` succeeds, so both calls returned 4 and the assertion
#     could not fail — it passed against every possible severity table.)
TWOSTEP="$T/t18/twostep.count"
cat >"$T/t18/twostep.sh" <<SH
#!/bin/bash
n=\$(cat "$TWOSTEP" 2>/dev/null); n=\${n:-0}
if [ "\$n" = 0 ]; then printf '1' >"$TWOSTEP"; exit 3; fi
exit 4
SH
chmod +x "$T/t18/twostep.sh"
for order in ab ba; do
    printf '0' >"$TWOSTEP"
    if [ "$order" = ab ]; then RA="$T/t18/repo-a"; RB="$T/t18/repo-b"; else RA="$T/t18/repo-b"; RB="$T/t18/repo-a"; fi
    OUT="$(VENV_REAPER="$T/t18/twostep.sh" run_reaper --apply --repo "$RA" --repo "$RB" --only venv 2>&1)"; RC=$?
    ST="$(cat "$T/t18/state/disk-reaper.status" 2>/dev/null || true)"
    assert_eq "$RC" "3" "T18 --repo $order: a fail-closed class (3) outranks a removal failure (4) — order-independent"
    assert_contains "$ST" "verdict_venv=fail-closed" "T18 --repo $order: the class names the worst thing it saw"
    # BOTH codes are named in `detail=`, so it cannot contradict `rc=` by naming only the first.
    assert_contains "$ST" "exited 3" "T18 --repo $order: the fail-closed code is in the detail"
    assert_contains "$ST" "exited 4" "T18 --repo $order: and so is the failed removal"
done

echo
echo "──────────────────────────────────────────────────────────────────────"
if [ "$FAIL" -eq 0 ]; then
    echo "ALL PASS ($PASS assertions)"
    exit 0
fi
echo "FAILURES: $FAIL of $((PASS + FAIL)) assertions"
exit 1
