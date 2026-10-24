#!/usr/bin/env bash
# refresh-provision.test.sh — the regression contract for agent-infra#2229.
#
# ⛔ THE DEFECT, MEASURED 2026-10-24. The live tortoise controller reported, every cycle for 26 hours:
#
#     [dispatch] BLOCKED: refresh failed — stage=provision: exit rc=1 at stage=provision while
#                running: provisioning (state dir, gh environment, scout worktree, interpreter)
#                — the failing step recorded no cause
#
# Two things were wrong and only the first was visible:
#
#   1. `scout_sync`'s `git checkout -B chore/dispatch-scout <origin/main>` exited 128 in
#      `/Users/home/eldato/tortoise/.worktrees/dispatch-scout` with
#          fatal: Unable to create '…/.git/worktrees/dispatch-scout/index.lock': File exists.
#      — a zero-byte `index.lock` left behind by a git process killed on 22 Oct 19:03. The stderr was
#      swallowed by `>/dev/null 2>&1`, and the refusal then PREDICTED a cause it had never measured
#      ("an UNTRACKED file is in the way of the new revision") that was simply FALSE on that box: the
#      scout carried no untracked files and no commits ahead. The remedy it printed — "move or commit
#      it" — was unactionable.
#   2. Every `exit "$SCOUT_REFUSE_RC"` in the provision stage exited WITHOUT calling `refresh_fail`,
#      so the EXIT trap wrote `why=… the failing step recorded no cause` into `state/refresh-last`.
#      `orch-loop.sh` builds its `[dispatch] BLOCKED` line from THAT FILE, not from the log, so the
#      one sentence an operator reads carried no cause while the real one sat one log line above it.
#
# WHAT THIS SUITE PINS, one arm each:
#   (a) a FAILING provision records its sub-step, its rc, and the measured cause (not a prediction);
#   (b) a HEALTHY provision proceeds — the pass reaches the pool and exits 0;
#   (c) a STALE scout (an orphaned lock) is REPAIRED and the report names the lock by PATH;
#   (d) NON-VACUITY: with the cause-recording reverted, (a) goes red — the record says "no cause".
#   (a2) an index.lock whose AGE cannot be read is REFUSED, never repaired (#2688 review, P1).
#
# HOW. Every arm drives the SHIPPED script inside a sandbox: a real git repo with a real (local, bare)
# origin and a real `git worktree` scout, so `scout_is_worktree`/`fetch`/`checkout` all run for real
# and no network is touched. `gh` is a stub, the pre-flight tool is a stub python file TRACKED at
# origin/main (so `scout_verify_tool` has a real blob to compare), and the pass is run with
# `HOME`/`REPO`/`O` overridden into the sandbox.
#
# Run:  bash scripts/orchestrator-harness/refresh-provision.test.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REFRESH="$HERE/refresh-candidates.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ❌ $1"; }
ck()  { if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1"; fi; }
# ⛔ RESOLVED, not the raw mktemp string: $TMPDIR on macOS ends in `/`, so `mktemp -d "$TMPDIR/x.XXXXXX"`
# yields a path with a DOUBLED slash (`…/T//refresh-provision.X`). git answers `--absolute-git-dir`
# with its own normalised form, so a raw-$T comparison of the lock path against the script's own
# message is a string mismatch that has nothing to do with the behaviour under test (measured: 3 reds).
T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/refresh-provision.XXXXXX")" && pwd -P)"
trap 'rm -rf "$T"' EXIT
echo "==> refresh-candidates provision-stage contract ($HERE)"
[ -f "$REFRESH" ] || { echo "  ❌ missing $REFRESH"; exit 1; }

# mk_case <name> — sandbox with a real repo, a real bare origin, and a real scout WORKTREE parked on
# an OLD commit (so every arm starts from the STALE condition the live box was in).
D=""
mk_case() {
  D="$T/$1"
  mkdir -p "$D/home" "$D/bin" "$D/o"
  git init -q --bare "$D/origin.git"
  git init -q -b main "$D/repo"
  # the scout worktree lives INSIDE the repo, so exclude it or `git add -A` below commits an embedded
  # repository and the fixture's own commits stop matching what the script fetches.
  mkdir -p "$D/repo/.git/info"; printf '.worktrees/\n' > "$D/repo/.git/info/exclude"
  git -C "$D/repo" config user.email t@t; git -C "$D/repo" config user.name t
  git -C "$D/repo" remote add origin "$D/origin.git"
  # commit 1 = the OLD revision the scout sits on; commit 2 = origin/main, and it ADDS the tool.
  mkdir -p "$D/repo/tools"
  printf 'old\n' > "$D/repo/README.md"
  git -C "$D/repo" add -A; git -C "$D/repo" commit -qm one
  git -C "$D/repo" worktree add -q "$D/repo/.worktrees/dispatch-scout" -b chore/dispatch-scout
  cat > "$D/repo/tools/collision_preflight.py" <<'PY'
#!/usr/bin/env python3
import sys
print("VERDICT: CLEAN")
PY
  printf 'new\n' > "$D/repo/README.md"
  git -C "$D/repo" add -A; git -C "$D/repo" commit -qm two
  git -C "$D/repo" push -q origin main
  # a `gh` that answers every box-level precondition: a stored credential, a healthy core bucket, and
  # READABLE EMPTY collections (so the pool is empty but never unreadable).
  # ⛔ `gh api -i` MUST ANSWER IN THE RESPONSE SHAPE THE SHIPPED HELPER PARSES (headers + body), or the
  # listing stage reads an empty body as UNREADABLE and the arm measures the wrong stage (measured).
  cat > "$D/bin/gh" <<'SH'
#!/bin/bash
case "$1 $2" in
  "auth token") exit 0 ;;
  "api -i") shift 2
            case "$*" in *" rate_limit"*) body='{"resources":{"core":{"remaining":4321},"graphql":{"remaining":4000}}}' ;; *) body='[]' ;; esac
            printf 'HTTP/2.0 200 OK\r\ncontent-type: application/json\r\n\r\n%s\n' "$body" ;;
  *" rate_limit"*) printf '%s\n' '{"resources":{"core":{"remaining":4321},"graphql":{"remaining":4000}}}' ;;
  *) printf '[]\n' ;;
esac
SH
  chmod +x "$D/bin/gh"
}

# rp <case-dir> — run the SHIPPED script; $OUT/$RC. Provisioning knobs are cleared so an operator's
# exported TORTOISE_REPO/SCOUT_* cannot leak in and make a case pass for the wrong reason.
OUT=""; RC=0
rp() {
  local dir="$1" script="${2:-$REFRESH}"
  OUT="$(env -u TORTOISE_REPO -u TORTOISE -u SCOUT_UV -u SCOUT_PY -u SCOUT_UV_EXTRAS \
          HOME="$dir/home" PATH="$dir/bin:$PATH" REPO="$dir/repo" O="$dir/o" \
          bash "$script" 6 2>&1)"
  RC=$?
}
rec() { sed -n "s/^$1=//p" "${2:-$D/o/state/refresh-last}" 2>/dev/null | head -1; }
age_lock() {   # <path> <seconds-in-the-past> — mtime is the only evidence of staleness git has
  touch -t "$(date -v-"$2"S +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$(( $(date +%s) - $2 ))" +%Y%m%d%H%M.%S)" "$1"
}

# ── (b) A HEALTHY PROVISION PROCEEDS ────────────────────────────────────────────────────────────────
# No lock, scout behind origin/main: the pass must refresh it and reach the pool — rc 0, no provision
# failure on the record. This is the control that stops (a)/(c) passing for a script that simply dies.
mk_case healthy
rp "$D"
ck "(b) healthy provision proceeds (rc=$RC)" "$([ "$RC" -eq 0 ]; echo $?)"
ck "(b) the pass recorded an outcome PAST provision (stage=$(rec stage))" \
   "$([ "$(rec stage)" != provision ]; echo $?)"
ck "(b) no provision failure was recorded (result=$(rec result))" \
   "$([ "$(rec result)" != fail ] || [ "$(rec stage)" != provision ]; echo $?)"
ck "(b) the scout was actually moved to origin/main" \
   "$(git -C "$D/repo/.worktrees/dispatch-scout" diff --quiet origin/main --; echo $?)"

# ── (a) A FAILING PROVISION RECORDS ITS SUB-STEP AND ITS RC ─────────────────────────────────────────
# A LIVE lock (younger than the staleness bound) is the case the pass must NOT repair: a writer may
# hold it, so it refuses. That is a provision failure, and it must land on the record with a cause.
mk_case live-lock
LOCK="$D/repo/.git/worktrees/dispatch-scout/index.lock"
: > "$LOCK"
rp "$D"
ck "(a) the failing pass exits non-zero (rc=$RC)" "$([ "$RC" -ne 0 ]; echo $?)"
ck "(a) result=fail recorded (result=$(rec result))" "$([ "$(rec result)" = fail ]; echo $?)"
ck "(a) stage=provision recorded (stage=$(rec stage))" "$([ "$(rec stage)" = provision ]; echo $?)"
ck "(a) rc recorded on the record (rc=$(rec rc))" "$([ "$(rec rc)" = "$RC" ]; echo $?)"
WHY="$(rec why)"
case "$WHY" in *"sub-step=scout-sync"*) r=0 ;; *) r=1 ;; esac
ck "(a) the cause NAMES the failing sub-step (why=${WHY:0:120})" "$r"
case "$WHY" in *"recorded no cause"*) r=1 ;; *) r=0 ;; esac
ck "(a) the cause is NOT the 'recorded no cause' fallback" "$r"
case "$WHY" in *"$LOCK"*) r=0 ;; *) r=1 ;; esac
ck "(a) the cause NAMES the blocking lock path" "$r"
ck "(a) the live lock was NOT deleted" "$([ -e "$LOCK" ]; echo $?)"

# ── (c) A STALE SCOUT IS REPAIRED, AND THE REPORT NAMES THE PATH ────────────────────────────────────
mk_case stale-lock
LOCK="$D/repo/.git/worktrees/dispatch-scout/index.lock"
: > "$LOCK"; age_lock "$LOCK" 3600
rp "$D"
case "$OUT" in *"REPAIR: removed an ORPHANED git lock at $LOCK"*) r=0 ;; *) r=1 ;; esac
ck "(c) the orphaned lock is reported BY PATH and repaired" "$r"
ck "(c) the orphaned lock is gone" "$([ ! -e "$LOCK" ]; echo $?)"
ck "(c) the repair let the pass PROCEED (rc=$RC)" "$([ "$RC" -eq 0 ]; echo $?)"
ck "(c) the scout reached origin/main after the repair" \
   "$(git -C "$D/repo/.worktrees/dispatch-scout" diff --quiet origin/main --; echo $?)"

# ── (a2) AN UNREADABLE LOCK AGE IS A REFUSAL, NOT A REPAIR ──────────────────────────────────────────
# The only DESTRUCTIVE path in this diff (#2688 review, P1). When `stat` cannot answer, the pass cannot
# tell an ORPHANED lock from a LIVE WRITER'S, so it must REFUSE and leave the lock alone. Before the
# fix, both unknown-age arms (`|| echo 0` and the `-1` sentinel) reached `rm -f` and printed a
# `REPAIR:` line asserting an age the code did not have — deleting a live writer's lock is index
# corruption, so the arm that proves the refusal is the arm that keeps the fix honest.
mk_case unknown-age
LOCK="$D/repo/.git/worktrees/dispatch-scout/index.lock"
: > "$LOCK"
REAL_STAT="$(command -v stat)"
cat > "$D/bin/stat" <<SH
#!/bin/bash
case "\$*" in *index.lock*) exit 1 ;; esac
exec "$REAL_STAT" "\$@"
SH
chmod +x "$D/bin/stat"
rp "$D"
ck "(a2) an unreadable lock age REFUSES (rc=$RC)" "$([ "$RC" -ne 0 ]; echo $?)"
ck "(a2) the lock was NOT deleted" "$([ -e "$LOCK" ]; echo $?)"
case "$OUT" in *"REPAIR: removed"*) r=1 ;; *) r=0 ;; esac
ck "(a2) no REPAIR line claims it removed a lock it could not age" "$r"
WHY="$(rec why)"
case "$WHY" in *"$LOCK"*) r=0 ;; *) r=1 ;; esac
ck "(a2) the cause NAMES the lock path (why=${WHY:0:120})" "$r"
case "$WHY" in *"AGE COULD NOT BE DETERMINED"*) r=0 ;; *) r=1 ;; esac
ck "(a2) the cause says the AGE is unknown, not that the lock is orphaned" "$r"

# ── (d) NON-VACUITY: revert the cause-recording, and (a) MUST go red ────────────────────────────────
# A copy of the SHIPPED script with ONE line reverted to the pre-fix shape (`|| exit "$SCOUT_REFUSE_RC"`
# instead of `|| refresh_fail provision …`). Nothing else differs, so any difference in the outcome is
# attributable to the cause-recording itself.
mk_case nonvacuity
PRE="$T/refresh-candidates.prefix.sh"
python3 - "$REFRESH" "$PRE" <<'PY'
import sys
src = open(sys.argv[1]).read()
needle = 'scout_sync || provision_fail "$SCOUT_REFUSE_RC" "sub-step=scout-sync: ${SCOUT_REFUSE_WHY:-scout_sync refused without a recorded reason}"'
assert needle in src, "the cause-recording line is missing — this control would be vacuous"
open(sys.argv[2], "w").write(src.replace(needle, 'scout_sync || exit "$SCOUT_REFUSE_RC"'))
PY
ck "(d) the pre-fix control was actually produced (one line reverted)" "$([ -s "$PRE" ]; echo $?)"
LOCK="$D/repo/.git/worktrees/dispatch-scout/index.lock"
: > "$LOCK"
rp "$D" "$PRE"
WHY="$(rec why)"
case "$WHY" in *"recorded no cause"*) r=0 ;; *) r=1 ;; esac
ck "(d) WITHOUT the fix the record says 'recorded no cause' (why=${WHY:0:100})" "$r"
case "$WHY" in *"sub-step=scout-sync"*) r=1 ;; *) r=0 ;; esac
ck "(d) WITHOUT the fix the sub-step is NOT named" "$r"

echo
echo "==> $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
