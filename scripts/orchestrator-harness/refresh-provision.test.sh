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
#   (a3) an UNEVALUABLE SCOUT_LOCK_STALE_SECS is refused, and a fresh lock survives it — including
#        the zero-equivalent (`00`, `000`) and out-of-range spellings a digits-only test admits.
#   (a4) a DANGLING SYMLINK at index.lock is refused and named, not mistaken for "no lock".
#   (a5) a DIRTY scout records WHY it refused — not the "no recorded reason" fallback.
#   (c2) a lock aged EXACTLY the staleness bound REFUSES — the ">" wording stays true.
#   (c3) the "comparison could not be performed" arm still refuses when the two form guards
#        are deleted in a copy — so the third guard is live, not dead code.
#
# #2953 — A SHALLOW GRAFT IS NOT LOCAL WORK, one arm each (the fixture is the CELL's shape:
# `--depth 2` so the trunk tip's parent becomes a graft root while the objects below it remain):
#   (s0) the fixture IS the defect shape — shallow, SEVERED (no merge base), count>1, tree CLEAN;
#   (s1) a CLEAN shallow scout PROCEEDS, reaches origin/main, and the log names the discarded number;
#   (s2) NON-VACUITY: with the old inference restored (one line), (s1) goes RED — a clean scout refused
#        with the false PRESERVE remedy;
#   (s3) a REAL local commit is STILL REFUSED, says "1 LOCAL commit(s)", and the commit survives;
#   (s4) an UNRELATED history (orphan branch, not shallow) is REFUSED and NOT reported as unfetched —
#        the arm that stops the new "fetch" wording becoming a hole for local work;
#   (s5) a scout whose `.git` link does not resolve is STILL rc=3 (#2217's refused shape);
#   (s6) `.git` REMOVED entirely is a DECLARED RESIDUAL (#2217): pinned as it IS (announced, proceeds),
#        not as it might be hoped to be;
#   (s7) `--check` does NOT fail a clean shallow scout — `cloud-cell-bringup.sh` DIES on a non-zero
#        `--check`, so that second copy of the comparison was a cell that could not START;
#   (s8) NON-VACUITY for (s7): the old `--check` arm still FAILS the same tree.
#   (h) HERMETICITY: ambient `$OR` AND `OR_OPERATOR_DECLARED` (both exported into the suite, so a drift
#       in either clear entry reddens it) do not reach the pass, and the
#       record carries no resolve-repo refusal — with a positive control that a DECLARED `$OR` handed to
#       the invocation IS still refused (rc=3);
#   (h2) the `--check` twin of (h), with the same two-way control;
#   (h3) the RECORDED cause names the origin SHAPE the resolver actually read (no `$REPO` set, an
#       unreadable origin, a URL naming another repo, a local path that cannot prove a DECLARED target)
#       instead of predicting one mechanism for all of them;
#   (h4) an origin that NAMES the queue target with a trailing slash is the same repo: it PROCEEDS, so
#       the cause can never report a "DIFFERENT repo" mismatch it did not measure.
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
# mut <out-path> — produce a MUTATION COPY of the shipped script by running the Python program on stdin
# (`python3 - "$REFRESH" <out-path>`), and say cleanly when it could not:
#   * the copy was WRITTEN  ⇒ 0;
#   * the anchor DRIFTED, the revert was a NO-OP, or anything else failed ⇒ print ONE line and remove
#     the partial file.
# ⛔ WHY THIS EXISTS (#2956 review, cosmetic). These controls used to guard themselves with bare
# `assert` statements, so a control whose anchor had moved died with a PYTHON TRACEBACK — and, worse, a
# `src.replace()` that matched nothing produced a copy IDENTICAL to the shipped script, i.e. a control
# that proves nothing while the suite still prints `ok`. A traceback is not a diagnosis, and a vacuous
# control is not a control: both now come out as one ❌ on the arm's own `ck` line.
mut() {
  local out="$1" err
  if err="$(python3 - "$REFRESH" "$out" 2>&1)"; then
    [ -s "$out" ] && return 0
    err="the mutation program wrote nothing"
  fi
  rm -f "$out"
  echo "  (control not produced: ${err//$'\n'/ })"
  return 1
}
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
  mk_gh_stub "$D"
  mk_claims_stub "$D"
}

# mk_claims_stub <case-dir> — seed the cross-box claim registry the shipped pass reads at `$O/claims.sh`.
# ⛔ A REAL `$O` HAS ONE (install.sh/deploy-harness.sh put it there), and the shipped `--check` refuses
# a cell whose registry is absent — deliberately, because the pre-flight would refuse every issue as
# INCOMPLETE and the cell could only merge (#2466). Without the seed, `(s7)`'s `--check` exited 3 on
# the MISSING REGISTRY rather than on anything about the shallow scout it exists to measure, so the
# arm could never turn green however correct the scout logic was. It copies the SHIPPED file (as
# refresh-scout.test.sh's `mk_case` does), so the sandbox cannot drift from the real claim format.
mk_claims_stub() {
  cp "$HERE/claims.sh" "$1/o/claims.sh"
}

# mk_gh_stub <case-dir> — the `gh` every arm's box-level preconditions are answered by.
# a `gh` that answers every box-level precondition: a stored credential, a healthy core bucket, and
# READABLE EMPTY collections (so the pool is empty but never unreadable).
# ⛔ `gh api -i` MUST ANSWER IN THE RESPONSE SHAPE THE SHIPPED HELPER PARSES (headers + body), or the
# listing stage reads an empty body as UNREADABLE and the arm measures the wrong stage (measured).
mk_gh_stub() {
  local D="$1"
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

# ── #2953: mk_shallow_case <name> — the CELL's shape, not a healthy tree ──────────────────────────────
# cell4's scout is a worktree of a HUB whose object database is SHALLOW: `.git/shallow` listed the trunk
# tip's OWN PARENT, so the walk from `origin/main` stopped one commit in while the walk from the scout's
# HEAD ran down every object the box held — and `origin/main..HEAD` answered 1634 for a CLEAN scout with
# zero local commits. A `--depth 2` fetch reproduces exactly that: the tip's parent becomes a graft root
# while the objects it used to connect to are still present below it.
# ⛔ THE SCOUT IS PARKED FIVE COMMITS INSIDE THE BODY, deliberately: the severed count is then 5, so no
# arm can confuse it with the ONE local commit arm (s3) plants — the two numbers an operator has to tell
# apart. And the trunk still ADDS the pre-flight tool (as in mk_case), so `scout_verify_tool` has a real
# blob and this fixture can measure the WHOLE provision stage rather than a shortened one.
mk_shallow_case() {
  local i
  D="$T/$1"
  mkdir -p "$D/home" "$D/bin" "$D/o"
  git init -q --bare "$D/origin.git"
  git init -q -b main "$D/repo"
  mkdir -p "$D/repo/.git/info"; printf '.worktrees/\n' > "$D/repo/.git/info/exclude"
  git -C "$D/repo" config user.email t@t; git -C "$D/repo" config user.name t
  git -C "$D/repo" remote add origin "$D/origin.git"
  mkdir -p "$D/repo/tools"
  printf '#!/usr/bin/env python3\nimport sys\nprint("VERDICT: CLEAN")\n' > "$D/repo/tools/collision_preflight.py"
  for i in 1 2 3 4 5; do echo "$i" > "$D/repo/f$i.txt"; git -C "$D/repo" add -A; git -C "$D/repo" commit -qm "body$i"; done
  git -C "$D/repo" worktree add -q "$D/repo/.worktrees/dispatch-scout" -b chore/dispatch-scout
  for i in 6 7 8 9 10; do echo "$i" > "$D/repo/f$i.txt"; git -C "$D/repo" add -A; git -C "$D/repo" commit -qm "c$i"; done
  git -C "$D/repo" push -q origin main
  mk_gh_stub "$D"
  mk_claims_stub "$D"
  git -C "$D/repo" fetch -q --depth 2 origin "+refs/heads/main:refs/remotes/origin/main"
}

# rp <case-dir> [<script>] [KEY=VAL ...] — run the SHIPPED script; $OUT/$RC. Provisioning knobs are
# cleared so an operator's exported TORTOISE_REPO/SCOUT_* cannot leak in and make a case pass for the
# wrong reason. A case that WANTS one sets it on its own invocation (e.g. `rp "$D" "" SCOUT_LOCK_STALE_SECS=5m`),
# so the clear list costs nothing and every arm's values are its own.
#
# ⛔ $OR IS CLEARED TOO, AND THAT IS THE WHOLE DIFFERENCE BETWEEN THIS SUITE AND ITS SIBLING
# (agent-infra#3174 lane, measured 2026-11-01). Every fixture here builds a bare LOCAL origin
# (`git init -q --bare "$D/origin.git"`), and the shipped `resolve_repo` tolerates a local-path origin
# only while the queue target is UNDECLARED (`OR_DECLARED=0`) — a DECLARED $OR cannot be proven by a
# path, so it refuses with rc=3 BEFORE the provision stage runs. This suite cleared every other
# ambient knob but NOT `$OR` (nor `OR_OPERATOR_DECLARED`, which forces the same refusal on its own), so
# on a box whose shell exports one (a cell's keys.env does; measured
# on this box: `OR=daniel-ospina/tortoise`) most of this suite went red for a reason that has
# nothing to do with provisioning:
#
#     [refresh] NOT PROVISIONABLE: $REPO is …/repo, whose 'origin' is the local path …/origin.git —
#       it cannot prove it is a checkout of $OR (daniel-ospina/tortoise), and $OR was DECLARED
#     [refresh] FAILED stage=provision rc=3 … — the failing step recorded no cause; the lines above
#       are this pass's last evidence (#2229)
#
# …and the arm then read that EXIT-TRAP sentence off `state/refresh-last` as though the scout had
# refused, which is why the cluster read as a cause-record defect. It is not: the record is RIGHT —
# no cause was recorded, because nothing below `resolve_repo` ever ran. `refresh-scout.test.sh` paid
# for this exact lesson in #1935 and its `rf` clears `-u OR`; this file's `rp` did not.
# The `(h)` arms below are the regression test for the clear list itself.
OUT=""; RC=0
# ⛔ THE CLEAR LIST IS WRITTEN ONCE, HERE (review cycle 1, P2). It was two verbatim copies — the shape
# that already cost this file most of its reds when one copy drifted from `refresh-scout.test.sh`'s. A new
# ambient knob goes in this array and nowhere else. `SCOUT_LOCK_STALE_SECS` is set per arm
# (`rp "$D" "" SCOUT_LOCK_STALE_SECS=5m`) because GNU `env` applies a KEY=VAL after `-u KEY`, so the
# arm's own value is the one the pass sees; `OR_OPERATOR_DECLARED` is exported by `(h)` into the
# suite's own environment precisely so its clear entry is load-bearing.
RP_CLEAR=(-u TORTOISE_REPO -u TORTOISE -u SCOUT_UV -u SCOUT_PY -u SCOUT_UV_EXTRAS
          -u SCOUT_LOCK_STALE_SECS -u OR -u OR_OPERATOR_DECLARED)
rp() {
  local dir="$1" script="${2:-$REFRESH}"
  if [ "$#" -ge 2 ]; then shift 2; else shift 1; fi
  OUT="$(env "${RP_CLEAR[@]}" \
          HOME="$dir/home" PATH="$dir/bin:$PATH" REPO="$dir/repo" O="$dir/o" "$@" \
          bash "$script" 6 2>&1)"
  RC=$?
}
# rpc <case-dir> [<script>] [KEY=VAL ...] — the `--check` twin of `rp`: SAME clear list (literally the
# same array, not a second copy), same argument handling, so the two cannot drift.
rpc() {
  local dir="$1" script="${2:-$REFRESH}"
  if [ "$#" -ge 2 ]; then shift 2; else shift 1; fi
  OUT="$(env "${RP_CLEAR[@]}" \
          HOME="$dir/home" PATH="$dir/bin:$PATH" REPO="$dir/repo" O="$dir/o" "$@" \
          bash "$script" --check 2>&1)"
  RC=$?
}
rec() { sed -n "s/^$1=//p" "${2:-$D/o/state/refresh-last}" 2>/dev/null | head -1; }
age_lock() {   # <path> <seconds-in-the-past> — mtime is the only evidence of staleness git has
  touch -t "$(date -v-"$2"S +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$(( $(date +%s) - $2 ))" +%Y%m%d%H%M.%S)" "$1"
}
abs_lock() {   # <path> <epoch> — pin an EXACT mtime
  touch -d "@$2" "$1" 2>/dev/null || touch -t "$(date -r "$2" +%Y%m%d%H%M.%S)" "$1"
}

# ── (b) A HEALTHY PROVISION PROCEEDS ────────────────────────────────────────────────────────────────
# No lock, scout behind origin/main: the pass must refresh it and reach the pool — rc 0, no provision
# failure on the record. This is the control that stops (a)/(c) passing for a script that simply dies.
mk_case healthy
rp "$D"
ck "(b) healthy provision proceeds (rc=$RC)" "$([ "$RC" -eq 0 ]; echo $?)"
ck "(b) the pass recorded an outcome PAST provision (stage=$(rec stage))" \
   "$([ -s "$D/o/state/refresh-last" ] && [ -n "$(rec stage)" ] && [ "$(rec stage)" != provision ]; echo $?)"
ck "(b) no provision failure was recorded (result=$(rec result))" \
   "$([ -s "$D/o/state/refresh-last" ] && [ -n "$(rec result)" ] && [ "$(rec result)" != fail ]; echo $?)"
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

# ── (a3) AN UNEVALUABLE STALENESS BOUND IS ALSO A REFUSAL, NOT A REPAIR ──────────────────────────────
# `[ "$age" -lt "5m" ]` exits 2 (`integer expression expected`) and `if` reads ANY non-zero as FALSE, so
# an operator's non-numeric SCOUT_LOCK_STALE_SECS skipped the live-writer arm and reached the `rm -f` —
# deleting a 0-second-old LIVE lock while printing a `REPAIR:` line (#2688 review cycle 2, P1).
BOUNDN=0
for bad in 5m abc 0 '300 ' 00 000 9223372036854775808; do
  BOUNDN=$((BOUNDN+1))
  mk_case "bound-$BOUNDN"
  LOCK="$D/repo/.git/worktrees/dispatch-scout/index.lock"
  : > "$LOCK"
  # ⛔ THROUGH `rp`, NOT A FIFTH COPY OF THE CLEAR LIST. This arm built its own `env -u …` line and so
  # inherited the ambient `$OR` the clear list exists to drop: measured on this box, all seven `(a3)`
  # arms refused at `resolve_repo` (rc=3) and recorded the EXIT TRAP's `the failing step recorded no
  # cause`, so the assertion read red for a reason the arm does not test (#3174).
  rp "$D" "" SCOUT_LOCK_STALE_SECS="$bad"
  ck "(a3) SCOUT_LOCK_STALE_SECS='$bad' refuses (rc=$RC)" "$([ "$RC" -ne 0 ]; echo $?)"
  ck "(a3) SCOUT_LOCK_STALE_SECS='$bad' did NOT delete a FRESH lock" "$([ -e "$LOCK" ]; echo $?)"
  case "$OUT" in *"REPAIR: removed"*) r=1 ;; *) r=0 ;; esac
  ck "(a3) SCOUT_LOCK_STALE_SECS='$bad' printed no REPAIR line" "$r"
  case "$(rec why)" in *"CANNOT BE EVALUATED"*) r=0 ;; *) r=1 ;; esac
  ck "(a3) SCOUT_LOCK_STALE_SECS='$bad' records that the bound cannot be evaluated" "$r"
done

# ── (a4) A DANGLING SYMLINK AT index.lock IS SEEN, NOT MISTAKEN FOR "NO LOCK" ─────────────────────────
# `[ -e ]` follows symlinks, so a dangling one read as "no lock": nothing aged, refused or repaired it,
# git still could not create the lock, and the checkout refusal promised a self-heal that cannot happen
# (#2688 review cycle 2, P2). The NON-REGULAR arm must refuse, name the path, and NOT delete it.
mk_case dangling-lock
LOCK="$D/repo/.git/worktrees/dispatch-scout/index.lock"
ln -s "$D/does-not-exist" "$LOCK"
rp "$D"
# ⛔ rc=3 + NON-REGULAR, not merely "non-zero and names the path" (review cycle 3, P2): WITHOUT the
# `[ -L ]` fix git's own `fatal: Unable to create '…/index.lock': File exists` refusal ALSO exits
# non-zero and ALSO names $LOCK, so the weaker assertions passed on the un-fixed code.
ck "(a4) a dangling index.lock symlink hits the NON-REGULAR arm (rc=$RC, want 3)" "$([ "$RC" -eq 3 ]; echo $?)"
ck "(a4) the symlink was NOT deleted (still present)" "$([ -L "$LOCK" ]; echo $?)"
WHY="$(rec why)"
case "$WHY" in *"$LOCK"*) r=0 ;; *) r=1 ;; esac
ck "(a4) the cause NAMES the lock path (why=${WHY:0:120})" "$r"
case "$WHY" in *"NON-REGULAR"*) r=0 ;; *) r=1 ;; esac
ck "(a4) the cause says NON-REGULAR — the arm the fix created, not git's later refusal" "$r"

# ── (a5) A DIRTY SCOUT RECORDS *WHY* IT REFUSED, NOT "refused without a recorded reason" ─────────────
# The two `scout_sync` refusal arms set the rc and printed their own lines but never `SCOUT_REFUSE_WHY`,
# so `state/refresh-last` — the file the controller's `[dispatch] BLOCKED` line quotes — said
# "scout_sync refused without a recorded reason" while the cause sat one log line above (#2688 review
# cycle 2, P2): #2229's own symptom, surviving in the change that exists to remove it.
mk_case dirty-scout
printf 'local edit\n' >> "$D/repo/.worktrees/dispatch-scout/README.md"
rp "$D"
ck "(a5) a dirty scout refuses (rc=$RC)" "$([ "$RC" -ne 0 ]; echo $?)"
WHY="$(rec why)"
case "$WHY" in *"UNCOMMITTED"*) r=0 ;; *) r=1 ;; esac
ck "(a5) the recorded cause names UNCOMMITTED work (why=${WHY:0:120})" "$r"
case "$WHY" in *"recorded no cause"*|*"without a recorded reason"*) r=1 ;; *) r=0 ;; esac
ck "(a5) the recorded cause is NOT the 'no recorded reason' fallback" "$r"

# ── (c2) THE BOUNDARY REFUSES: a lock aged EXACTLY SCOUT_LOCK_STALE_SECS ─────────────────────────────
# The comparison is `-le` and the repair line says ">": at equality the pass must REFUSE, or that line
# prints "300s old > 300s", an inequality the code does not hold (#2688 review cycle 4, P2). Nothing
# reached the boundary before — (a) ages 0s and (c) ages 3600s.
# ⛔ THE BOUNDARY NEEDS A FIXED CLOCK, OR IT IS NOT OBSERVABLE AT ALL. `age_lock` writes a real mtime,
# so by the time the pass reads `date +%s` the age has drifted to 301 and EQUALITY is never reached —
# the very arm this control exists for would silently test the wrong thing. So a `date` shim (test-only,
# this sandbox's PATH) answers `+%s` with a fixed epoch and delegates every other call to the real one.
mk_case boundary-lock
LOCK="$D/repo/.git/worktrees/dispatch-scout/index.lock"
: > "$LOCK"
REAL_DATE="$(command -v date)"
cat > "$D/bin/date" <<SH
#!/bin/bash
if [ "\$1" = "+%s" ]; then printf '%s\n' 1700000000; exit 0; fi
exec "$REAL_DATE" "\$@"
SH
chmod +x "$D/bin/date"
abs_lock "$LOCK" 1699999700   # exactly SCOUT_LOCK_STALE_SECS (300s) before the shimmed "now"
rp "$D"
ck "(c2) a lock aged EXACTLY the 300s bound refuses (rc=$RC)" "$([ "$RC" -ne 0 ]; echo $?)"
ck "(c2) the boundary lock was NOT deleted" "$([ -e "$LOCK" ]; echo $?)"
case "$(rec why)" in *"LIVE git lock"*) r=0 ;; *) r=1 ;; esac
ck "(c2) the cause calls the boundary lock LIVE (why=$(rec why | cut -c1-90))" "$r"

# ── (c3) THE STATUS ARM IS LIVE, NOT DEAD CODE ─────────────────────────────────────────────────────
# Cycle 3 added a check that refuses when the age comparison ERRORS (status > 1). With the canonical-form
# arm and the 9-digit guard in place that arm is unreachable BY CONSTRUCTION, so no ordinary case can pin
# it — a guard nothing can observe is a guard that rots. This is the suite's `(d)` control pattern
# applied to it: delete the two guards in a COPY and prove the third still refuses, keeping the lock.
# Verified discriminating — on that copy WITHOUT the status arm the pass exits 0 and DELETES the lock.
mk_case status-arm
LOCK="$D/repo/.git/worktrees/dispatch-scout/index.lock"
: > "$LOCK"
MUT="$D/refresh-no-guards.sh"
mut "$MUT" <<'PY2'
import sys
src = open(sys.argv[1]).read()
canon = "    ''|*[!0-9]*|0*)"
if canon not in src:
    sys.exit("canonical-form arm missing — this control would be vacuous")
out = src.replace(canon, "    ''|*[!0-9]*|0)")
if out == src:
    sys.exit("the canonical-form revert was a NO-OP — this control would prove nothing")
start = '  if [ "${#SCOUT_LOCK_STALE_SECS}" -gt 9 ]; then'
if start not in out:
    sys.exit("the length guard is missing — this control would be vacuous")
i = out.index(start)
end = out.find('  fi\n', i)
if end < 0:
    sys.exit("the length guard's 'fi' was not found — this control would be vacuous")
out = out[:i] + out[end + len('  fi\n'):]
if 'SCOUT_LOCK_STALE_SECS}" -gt 9' in out:
    sys.exit("length guard still present — control vacuous")
if '0*)' in out:
    sys.exit("canonical arm still present — control vacuous")
open(sys.argv[2], "w").write(out)
PY2
ck "(c3) the no-guards control was actually produced" "$([ -s "$MUT" ]; echo $?)"
if [ -s "$MUT" ]; then
rp "$D" "$MUT" SCOUT_LOCK_STALE_SECS=9223372036854775808
ck "(c3) with the two form guards deleted the STATUS arm still refuses (rc=$RC)" "$([ "$RC" -ne 0 ]; echo $?)"
ck "(c3) the lock SURVIVED — the comparison error was not read as 'stale'" "$([ -e "$LOCK" ]; echo $?)"
case "$(rec why)" in *"could not be compared"*) r=0 ;; *) r=1 ;; esac
ck "(c3) the cause says the comparison could not be performed (why=$(rec why | cut -c1-90))" "$r"
case "$OUT" in *"REPAIR: removed"*) r=1 ;; *) r=0 ;; esac
ck "(c3) no REPAIR line was printed on the uncomparable bound" "$r"
fi

# ── (d) NON-VACUITY: revert the cause-recording, and (a) MUST go red ────────────────────────────────
# A copy of the SHIPPED script with ONE line reverted to the pre-fix shape (`|| exit "$SCOUT_REFUSE_RC"`
# instead of `|| refresh_fail provision …`). Nothing else differs, so any difference in the outcome is
# attributable to the cause-recording itself.
mk_case nonvacuity
PRE="$T/refresh-candidates.prefix.sh"
mut "$PRE" <<'PY'
import sys
src = open(sys.argv[1]).read()
needle = 'scout_sync || provision_fail "$SCOUT_REFUSE_RC" "sub-step=scout-sync: ${SCOUT_REFUSE_WHY:-scout_sync refused without a recorded reason}"'
if needle not in src:
    sys.exit("the cause-recording line is missing — this control would be vacuous")
out = src.replace(needle, 'scout_sync || exit "$SCOUT_REFUSE_RC"')
if out == src:
    sys.exit("the cause-recording revert was a NO-OP — this control would prove nothing")
open(sys.argv[2], "w").write(out)
PY
ck "(d) the pre-fix control was actually produced (one line reverted)" "$([ -s "$PRE" ]; echo $?)"
if [ -s "$PRE" ]; then
LOCK="$D/repo/.git/worktrees/dispatch-scout/index.lock"
: > "$LOCK"
rp "$D" "$PRE"
WHY="$(rec why)"
case "$WHY" in *"recorded no cause"*) r=0 ;; *) r=1 ;; esac
ck "(d) WITHOUT the fix the record says 'recorded no cause' (why=${WHY:0:100})" "$r"
case "$WHY" in *"sub-step=scout-sync"*) r=1 ;; *) r=0 ;; esac
ck "(d) WITHOUT the fix the sub-step is NOT named" "$r"
fi

# ══ #2953: A SHALLOW GRAFT IS NOT LOCAL WORK ═══════════════════════════════════════════════════════
# MEASURED on cell4, 2026-10-27: a CLEAN scout with ZERO local commits was refused on every pass —
#     scout HEAD=fadb6334  dirty=0  local-only commits: 1634
# — while `refs/remotes/origin/main` was the FRESH trunk tip, TWO COMMITS AHEAD of HEAD. `.git/shallow`
# listed the tip's own parent, so the walk from origin/main stopped one commit in: the 1 634 were the
# checkout's OWN history. The guard could not say WHICH difference it had found (preserve vs fetch), so
# it printed an unactionable PRESERVE remedy — and nothing on a box moves a shallow boundary, so the
# refusal was a transient that could never clear. Every arm below runs against that shape.

# ── (s0) THE FIXTURE IS THE DEFECT SHAPE, NOT A HEALTHY TREE ─────────────────────────────────
# Asserted BEFORE the run: without this, every arm below would pass by measuring a tree that never had
# the defect (the fixture is the whole test here).
mk_shallow_case shallow-clean
SD="$D/repo/.worktrees/dispatch-scout"
SEVERED="$(git -C "$SD" rev-list --count refs/remotes/origin/main..HEAD 2>/dev/null)"
if git -C "$SD" merge-base HEAD refs/remotes/origin/main >/dev/null 2>&1; then r=1; else r=0; fi
ck "(s0) the fixture hub IS shallow" "$([ "$(git -C "$D/repo" rev-parse --is-shallow-repository)" = true ]; echo $?)"
ck "(s0) the scout's history is SEVERED from origin/main (no merge base)" "$r"
ck "(s0) the count the guard would read is ${SEVERED} (want >1, so it cannot be mistaken for (s3)'s ONE)" \
   "$([ "${SEVERED:-0}" -gt 1 ]; echo $?)"
ck "(s0) the scout tree is CLEAN — exactly the state cell4 refused" \
   "$([ -z "$(git -C "$SD" status --porcelain --untracked-files=no)" ]; echo $?)"

# ── (s1) A CLEAN SHALLOW SCOUT PROCEEDS ───────────────────────────────────────────────────────────
# THE ACCEPT CRITERION. The pass must repair the graph (deepen) and move the gate, and the log must NAME
# the number it discarded — an operator reading "scout STALE" for a tree that was never ahead has to be
# able to see why.
rp "$D"
ck "(s1) a CLEAN shallow scout PROCEEDS (rc=$RC)" "$([ "$RC" -eq 0 ]; echo $?)"
ck "(s1) the pass recorded an outcome PAST provision (stage=$(rec stage))" \
   "$([ -n "$(rec stage)" ] && [ "$(rec stage)" != provision ]; echo $?)"
ck "(s1) the scout was actually moved to origin/main" \
   "$(git -C "$SD" diff --quiet origin/main --; echo $?)"
case "$OUT" in *"REPAIR:"*"read ${SEVERED} "*) r=0 ;; *) r=1 ;; esac
ck "(s1) the repair NAMES the discarded number (${SEVERED}), so the log distinguishes the two readings" "$r"
case "$OUT" in *"carries ${SEVERED} commit(s) not in origin/main"*) r=1 ;; *) r=0 ;; esac
ck "(s1) the old 'carries N commit(s) not in origin/main' refusal is NOT printed" "$r"

# ── (s2) NON-VACUITY: with the OLD inference restored, (s1) goes RED ─────────────────────────────────
# A copy of the SHIPPED script with ONE line changed — the verdict call replaced by the pre-fix
# behaviour (read the raw count and call it local work). Nothing else differs, so any difference in the
# outcome is attributable to the verdict itself.
mk_shallow_case shallow-prefix
MUT="$T/refresh-ahead-prefix.sh"
mut "$MUT" <<'PY3'
import sys
src = open(sys.argv[1]).read()
needle = ('    scout_ahead_verdict refs/remotes/origin/main connect\n'
          '    case "$SCOUT_AHEAD_VERDICT" in')
if needle not in src:
    sys.exit("the verdict call is missing — this control would be vacuous")
pre = ('    SCOUT_AHEAD_COUNT="$(git -C "$SC" rev-list --count refs/remotes/origin/main..HEAD 2>/dev/null || echo 0)"\n'
       '    SCOUT_AHEAD_VERDICT=local\n'
       '    case "$SCOUT_AHEAD_VERDICT" in')
out = src.replace(needle, pre)
if out == src:
    sys.exit("the verdict revert was a NO-OP — this control would prove nothing")
open(sys.argv[2], "w").write(out)
PY3
ck "(s2) the pre-fix control was actually produced (one line reverted)" "$([ -s "$MUT" ]; echo $?)"
if [ -s "$MUT" ]; then
rp "$D" "$MUT"
ck "(s2) WITHOUT the fix the CLEAN shallow scout is REFUSED (rc=$RC)" "$([ "$RC" -ne 0 ]; echo $?)"
case "$(rec why)" in *"LOCAL commit(s)"*) r=0 ;; *) r=1 ;; esac
ck "(s2) WITHOUT the fix the cause calls the artifact 'LOCAL commit(s)' — the false PRESERVE remedy" "$r"
ck "(s2) and the scout was NOT moved (the refusal is the blocker)" \
   "$(git -C "$D/repo/.worktrees/dispatch-scout" diff --quiet origin/main -- 2>/dev/null; [ $? -ne 0 ]; echo $?)"
fi

# ── (s3) A REAL LOCAL COMMIT IS STILL REFUSED — the arm that must never weaken ───────────────────────
# The scout is the same severed shape, plus ONE commit of its own. After the repair the graph is
# connected, so the count is 1 and it MEANS 1: the refusal must say LOCAL and the commit must survive.
mk_shallow_case shallow-local
SD="$D/repo/.worktrees/dispatch-scout"
printf 'local work\n' > "$SD/local.txt"
git -C "$SD" add local.txt
git -C "$SD" -c user.email=t@t -c user.name=t commit -qm "local work"
LOCAL_SHA="$(git -C "$SD" rev-parse HEAD)"
rp "$D"
ck "(s3) a REAL local commit still REFUSES (rc=$RC)" "$([ "$RC" -ne 0 ]; echo $?)"
case "$(rec why)" in *"1 LOCAL commit(s)"*) r=0 ;; *) r=1 ;; esac
ck "(s3) the cause says '1 LOCAL commit(s)' — the PRESERVE wording (why=$(rec why | cut -c1-110))" "$r"
case "$(rec why)" in *"HAS NOT FETCHED"*) r=1 ;; *) r=0 ;; esac
ck "(s3) the cause does NOT offer the FETCH remedy for real local work" "$r"
ck "(s3) the local commit SURVIVED (HEAD unchanged)" \
   "$([ "$(git -C "$SD" rev-parse HEAD)" = "$LOCAL_SHA" ]; echo $?)"

# ── (s4) AN UNRELATED HISTORY IS NOT 'UNFETCHED' EITHER (the new arm is not a hole for (b)) ─────────────
# A scout on an ORPHAN branch is NOT shallow and shares no ancestor with the trunk, so "nothing needs
# preserving" would be a lie over commits that exist nowhere else. The prototype for this change DID
# fold it into the fetch arm; this arm is why `unrelated` exists.
mk_shallow_case unrelated
SD="$D/repo/.worktrees/dispatch-scout"
git -C "$SD" checkout -q --orphan orphan-work
git -C "$SD" -c user.email=t@t -c user.name=t commit -qm "orphan work"
ORPHAN_SHA="$(git -C "$SD" rev-parse HEAD)"
rp "$D"
ck "(s4) an unrelated (orphan) history still REFUSES (rc=$RC)" "$([ "$RC" -ne 0 ]; echo $?)"
case "$(rec why)" in *"NO common ancestor"*) r=0 ;; *) r=1 ;; esac
ck "(s4) the cause says the histories share NO common ancestor (why=$(rec why | cut -c1-110))" "$r"
case "$(rec why)" in *"HAS NOT FETCHED"*) r=1 ;; *) r=0 ;; esac
ck "(s4) it is NOT reported as unfetched history — the operator is told to PRESERVE" "$r"
ck "(s4) the orphan commit SURVIVED" "$([ "$(git -C "$SD" rev-parse HEAD)" = "$ORPHAN_SHA" ]; echo $?)"

# ── (s5) A SCOUT WHOSE .git LINK NO LONGER RESOLVES STILL REFUSES (#2217's shape) ─────────────────────
# The fix must not buy (s1) by loosening what the pass will judge. A pruned/stale worktree record is
# NOT PROVISIONABLE (rc=3) and must stay that way.
mk_shallow_case broken-link
rm -rf "$D/repo/.git/worktrees/dispatch-scout"
rp "$D"
ck "(s5) a scout whose .git link does not resolve REFUSES with rc=3 (rc=$RC)" "$([ "$RC" -eq 3 ]; echo $?)"
case "$(rec why)" in *"does not resolve"*) r=0 ;; *) r=1 ;; esac
ck "(s5) the cause names the unresolvable .git link (why=$(rec why | cut -c1-110))" "$r"

# ── (s6) DECLARED RESIDUAL: `.git` REMOVED ENTIRELY IS STILL NOT REFUSED (#2217) ──────────────────────
# ⛔ THIS ARM PINS THE OPPOSITE OF WHAT #2953 MIGHT BE READ TO PROMISE, and it is here so the state is
# RECORDED rather than assumed: with `.git` deleted the directory is no longer a worktree, so the pass
# announces it as unversioned and proceeds. That is #2217's known, declared residual — this change does
# not alter it in either direction, and an arm claiming it refuses would be asserting something false.
mk_shallow_case git-gone
rm -rf "$D/repo/.worktrees/dispatch-scout/.git"
rp "$D"
case "$OUT" in *"is not a worktree of"*) r=0 ;; *) r=1 ;; esac
ck "(s6) with .git REMOVED the pass ANNOUNCES the unversioned scout (#2217 residual, unchanged)" "$r"
ck "(s6) …and does not refuse it (rc=$RC — the residual is that it proceeds)" "$([ "$RC" -eq 0 ]; echo $?)"

# ── (s7) THE SECOND COPY: `--check` MUST NOT FAIL A CLEAN SHALLOW SCOUT ──────────────────────────────
# `cloud-cell-bringup.sh` DIES on a non-zero `--check`, so a false FAIL here refuses to START a cell.
# That mode is offline by design and cannot connect a severed history, so it must WARN, not FAIL.
mk_shallow_case check-shallow
rpc "$D"
ck "(s7) --check does NOT fail a CLEAN shallow scout (rc=$RC)" "$([ "$RC" -eq 0 ]; echo $?)"
case "$OUT" in *"check: WARN the scout"*"SHALLOW"*) r=0 ;; *) r=1 ;; esac
ck "(s7) it WARNS and names the shallow history as the reason it cannot judge" "$r"
case "$OUT" in *"check: FAIL the scout"*) r=1 ;; *) r=0 ;; esac
ck "(s7) it prints no 'check: FAIL the scout' line" "$r"

# ── (s8) NON-VACUITY FOR (s7): the OLD check arm still FAILS that same tree ─────────────────────────
# The same fixture, the same mode, and a copy whose `--check` arm is reverted to the pre-fix count. This
# is the arm that proves the second copy was a real blocker rather than a cosmetic edit.
mk_shallow_case check-prefix
MUT2="$T/refresh-check-prefix.sh"
mut "$MUT2" <<'PY4'
import sys
src = open(sys.argv[1]).read()
needle = ('        scout_ahead_verdict refs/remotes/origin/main noconnect\n'
          '        case "$SCOUT_AHEAD_VERDICT" in')
if needle not in src:
    sys.exit("the --check verdict call is missing — this control would be vacuous")
pre = ('        SCOUT_AHEAD_VERDICT=local\n'
       '        SCOUT_AHEAD_COUNT="$(git -C "$SC" rev-list --count refs/remotes/origin/main..HEAD 2>/dev/null || echo 0)"\n'
       '        case "$SCOUT_AHEAD_VERDICT" in')
out = src.replace(needle, pre)
if out == src:
    sys.exit("the --check revert was a NO-OP — this control would prove nothing")
open(sys.argv[2], "w").write(out)
PY4
ck "(s8) the pre-fix --check control was actually produced" "$([ -s "$MUT2" ]; echo $?)"
if [ -s "$MUT2" ]; then
rpc "$D" "$MUT2"
ck "(s8) WITHOUT the fix --check FAILS the clean shallow scout (rc=$RC)" "$([ "$RC" -ne 0 ]; echo $?)"
case "$OUT" in *"check: FAIL the scout"*) r=0 ;; *) r=1 ;; esac
ck "(s8) …and it is that FAIL line, so a cell would refuse to START" "$r"
fi

# ── (h) HERMETICITY: AN AMBIENT DECLARED `$OR` MUST NOT REACH THE PASS ───────────────────────────────
# ⛔ THE REGRESSION TEST FOR THE CLEAR LIST ITSELF (agent-infra#3174). The defect this pins is not in the
# shipped script at all: `rp`/`rpc` cleared every ambient provisioning knob EXCEPT `$OR`, and every
# fixtures that existed when it was measured all prove their target with a bare LOCAL origin — which
# `resolve_repo` refuses the moment `$OR` is DECLARED, before the provision stage runs. (The
# `(h3)`/`(h4*)` fixtures below came later and each keeps its OWN shape (bare local path / removed
# origin / URL naming another repo / file:// mirror / synthetic candidate); the `(h4*)`/`(h4d)` rows
# spell the origin as a URL and redirect that transport with `insteadOf`, and no `(h3)` row ever reaches
# a fetch — the resolver refuses above it.) Measured on a cell whose shell exports `OR`:
# most of the suite red, each recording the EXIT TRAP's `the failing step recorded no cause` because the
# refusal happened above `scout_sync` — which is why the cluster read as a cause-record defect.
# The arm EXPORTS the ambient value into the suite's own environment (not into the pass), so it fails
# on a tree where the clear list has drifted and passes only while `rp`/`rpc` keep `-u OR`.
# ⛔ IT ASSERTS BOTH DIRECTIONS so it cannot be satisfied by a pass that ignores `$OR` outright: the
# ambient-exported run must PROCEED (rc 0), and a DECLARED target handed to the pass EXPLICITLY must
# still REFUSE (rc 3) — the deliberate `resolve_repo` behaviour that made the ambient leak fatal.
mk_case hermetic
AMBIENT_OR_SAVE="${OR:-}"; AMBIENT_DECL_SAVE="${OR_OPERATOR_DECLARED:-}"
# ⛔ BOTH KNOBS, NOT ONE (review cycle 12, P2): the marker `OR_OPERATOR_DECLARED` alone forces the same
# refusal — `refresh-candidates.sh:27-31` reads it as "the operator named the target", and the local-path
# fixture then cannot prove it — but this arm used to UNSET the marker, so dropping
# `-u OR_OPERATOR_DECLARED` from `RP_CLEAR` left every `(h)` row green. Exported now, so a drift in
# either entry reddens the arm.
export OR="daniel-ospina/tortoise" OR_OPERATOR_DECLARED=1
rp "$D"
ck "(h) an AMBIENT exported \$OR does not reach the pass (rc=$RC — it must proceed)" "$([ "$RC" -eq 0 ]; echo $?)"
# ⛔ THE RECORD ASSERTION READS THE MARKER THE RECORD ACTUALLY CARRIES (review cycle 1, P1-ish). It used
# to look for `was DECLARED`, a string that exists ONLY on `resolve_repo`'s stdout (its local-path `$OR_DECLARED` arm — cited by ARM, not by line, because
# this diff has already moved that number twice) and never in
# `why=`, so it was green by construction: measured with `-u OR` removed from `RP_CLEAR`, the pass went
# rc=3 and this arm still printed ✅ while `why=` plainly held a `sub-step=resolve-repo` refusal.
case "$(rec why)" in *"sub-step=resolve-repo"*) r=1 ;; *) r=0 ;; esac
ck "(h) …and the record carries no resolve-repo refusal ($(rec why | cut -c1-90))" "$r"
# the positive control: the SAME value, handed over deliberately, IS refused — so (h) is not a fixture
# that has simply stopped testing the resolver.
rp "$D" "" OR="daniel-ospina/tortoise"
ck "(h) a DECLARED \$OR on the invocation is still REFUSED (rc=$RC)" "$([ "$RC" -eq 3 ]; echo $?)"
case "$(rec why)" in *"sub-step=resolve-repo"*"local-path"*) r=0 ;; *) r=1 ;; esac
ck "(h) …and the record NAMES the local-path origin it could not prove ($(rec why | cut -c1-90))" "$r"
OR="$AMBIENT_OR_SAVE"
if [ -n "$AMBIENT_DECL_SAVE" ]; then export OR_OPERATOR_DECLARED="$AMBIENT_DECL_SAVE"; else unset OR_OPERATOR_DECLARED 2>/dev/null || true; fi

# ── (h2) THE `--check` TWIN MUST BE INSURED THE SAME WAY ────────────────────────────────────────────
# `rpc` shares `RP_CLEAR` with `rp` now, so the drift this arm pins against is a future one: it EXPORTS
# the ambient value into the suite and requires `--check` to still answer for the same fixture.
mk_shallow_case hermetic-check
AMBIENT_OR_SAVE="${OR:-}"
export OR="daniel-ospina/tortoise"
rpc "$D"
ck "(h2) an AMBIENT exported \$OR does not reach \`--check\` (rc=$RC)" "$([ "$RC" -eq 0 ]; echo $?)"
case "$OUT" in *"was DECLARED"*) r=1 ;; *) r=0 ;; esac
ck "(h2) …and --check prints no 'declared \$OR' refusal" "$r"
# the positive control for the TWIN: the same value, handed over deliberately, is refused here too.
rpc "$D" "" OR="daniel-ospina/tortoise"
ck "(h2) a DECLARED \$OR on a --check invocation is still REFUSED (rc=$RC)" "$([ "$RC" -eq 3 ]; echo $?)"
# ⛔ NON-VACUITY FOR THE NEGATIVE ASSERTION ABOVE (review cycle 3, P2): a "this string is absent"
# check stays green if the string stops existing at all, so the control must PRINT it.
case "$OUT" in *"was DECLARED"*) r=0 ;; *) r=1 ;; esac
ck "(h2) …and that control DOES print the refusal (h2) must not see" "$r"
OR="$AMBIENT_OR_SAVE"

# ── (h3) THE RECORDED CAUSE NAMES THE ORIGIN SHAPE IT READ, NOT A PREDICTED ONE ──────────────────────
# `resolve_repo` refuses a REPO-set pair for THREE different measured reasons (an unreadable origin, a URL
# naming ANOTHER repo, a local path that cannot prove a DECLARED target). The carried cause asserted the
# local-path wording for all three — a refusal that predicts a mechanism it never measured, the #2229
# class this exit is being fixed to remove (review cycle 2, P2). These arms pin each arm's own words.
# ⛔ THE FAILURE THEY PREVENT IS NOT COSMETIC: `refresh_cause_brief` quotes `why=` into the controller's
# `[dispatch] BLOCKED` line, so a wrong mechanism sends the operator to a remedy that cannot work.
mk_case cause-url-mismatch
git -C "$D/repo" remote set-url origin https://github.com/someone/other.git
rp "$D" "" OR="daniel-ospina/tortoise"
ck "(h3) a URL origin naming another repo still REFUSES (rc=$RC)" "$([ "$RC" -eq 3 ]; echo $?)"
case "$(rec why)" in *"NOT the queue target"*) r=0 ;; *) r=1 ;; esac
ck "(h3) …and the recorded cause says it is a DIFFERENT repo ($(rec why | cut -c1-90))" "$r"
case "$(rec why)" in *"local-path"*) r=1 ;; *) r=0 ;; esac
ck "(h3) …and does NOT borrow the local-path sentence" "$r"
# …the local-path arm still names ITS shape, so (h3) cannot be satisfied by one generic sentence…
mk_case cause-local-path
rp "$D" "" OR="daniel-ospina/tortoise"
case "$(rec why)" in *"local-path"*"cannot prove a DECLARED"*) r=0 ;; *) r=1 ;; esac
ck "(h3) the local-path arm names the local path ($(rec why | cut -c1-90))" "$r"
# ── (h4) A TRAILING-SLASH ORIGIN THAT NAMES THE TARGET IS THE SAME REPO ─────────────────────────────
# ⛔ A FALSE BLOCK, NOT A WORDING NIT (review cycle 4, P2). `resolve_repo`'s accept list enumerated
# `"$OR"`, `"$OR.git"`, `*":$OR"`, `*":$OR.git"`, `*"/$OR"`, `*"/$OR.git"` — so a remote with a
# TRAILING SLASH (`https://github.com/<owner>/<repo>/`, which `git remote add` accepts and humans type)
# was refused as "NOT the queue target", and the cause this diff adds would have written "a DIFFERENT
# repo, and no retry can mend a mismatch" about the RIGHT repo. Both the accept list and the cause
# predicates now carry the trailing-slash spellings, and this arm pins that the pass PROCEEDS.
mk_case cause-trailing-slash
git -C "$D/repo" remote set-url origin "https://github.com/daniel-ospina/tortoise/"
# ⛔ THE TRANSPORT IS REDIRECTED, THE SPELLING IS NOT (review cycle 5, P1-shaped P2): without this line
# `scout_sync` FETCHES github.com for real — it broke this file's own "no network is touched" invariant
# (:66) and made the arm's outcome depend on egress. `insteadOf` rewrites the transport while
# `git config --get remote.origin.url` still answers the trailing-slash URL that `resolve_repo` reads,
# so the arm measures the accept list and nothing else.
git -C "$D/repo" config "url.$D/origin.git.insteadOf" "https://github.com/daniel-ospina/tortoise/"
rp "$D" "" OR="daniel-ospina/tortoise"
# ⛔ A POSITIVE ASSERTION, NOT TWO ABSENCES (review cycle 5, P2). "no 'NOT the queue target'" and "no
# resolve-repo in the record" are both green when the pass dies BEFORE the resolver — measured by
# injecting an unrelated early `provision_fail`, which left both lines ✅ while `resolve_repo` never ran.
# With the transport redirected the pass completes, so rc=0 pins the accept list directly.
ck "(h4) a trailing-slash origin naming the target is ACCEPTED and the pass proceeds (rc=$RC)" "$([ "$RC" -eq 0 ]; echo $?)"
case "$OUT" in *"NOT the queue target"*) r=1 ;; *) r=0 ;; esac
ck "(h4) …and it is not refused as a different repo" "$r"
case "$(rec why)" in *"sub-step=resolve-repo"*) r=1 ;; *) r=0 ;; esac
ck "(h4) …and the record carries no resolve-repo refusal ($(rec why | cut -c1-70))" "$r"
# NON-VACUITY: with the trailing-slash spellings removed from `resolve_repo`'s REPO-SET accept list this
# fixture prints `NOT the queue target` and the `(h4)` rows above go red. ⛔ NO INTEGER IS QUOTED HERE:
# the suite's arm count has moved three times while this block was written, and a stale `N passed`
# in a comment is re-derived by the next lane and found false. The stable, re-verifiable claim is the
# mechanism: strip an arm, the row that names that spelling reddens.
# ⛔ ALL FOUR TRAILING-SLASH SPELLINGS ARE PINNED, ONE ROW EACH (review cycles 6-8, P2). With only
# `*"/$OR/"` covered, removing any of the other three from ALL THREE lists still printed
# the whole suite green — i.e. what the change claims to fix rested on inspection. One row per spelling
# now, and the claim each row makes is the mechanism, not a count: strip that spelling from the accept
# lists and THAT row reddens. Every fixture redirects the transport with `insteadOf` (so the spelling
# stays realistic while nothing reaches the network) and asserts rc=0.
# ⛔ WHICH COPY EACH ROW PINS (review cycles 8-9, P2): the four spelling rows above run with `REPO=` set,
# so they pin `resolve_repo`'s REPO-SET list only. The same four arms are also carried by the
# CANDIDATE-LOOP predicate (the auto-derive path a cell without `REPO` uses) and by the `_pair` cause.
# `(h4d)` below runs the SAME four spellings through the candidate loop; stripping the arms from that
# copy reddens `(h4d)` and leaves every other row green. The `_pair` copy is DEFENSIVE and is pinned by
# nothing:
# `resolve_repo` returns 0 whenever that predicate matches, so its "names `$OR` yet the resolver refused
# it" arm is reachable only by a config race. Stated, not implied.
mk_case cause-trailing-slash-git
git -C "$D/repo" remote set-url origin "https://github.com/daniel-ospina/tortoise.git/"
git -C "$D/repo" config "url.$D/origin.git.insteadOf" "https://github.com/daniel-ospina/tortoise.git/"
rp "$D" "" OR="daniel-ospina/tortoise"
ck "(h4b) an https '…/tortoise.git/' origin is ACCEPTED (rc=$RC)" "$([ "$RC" -eq 0 ]; echo $?)"
mk_case cause-trailing-slash-scp
git -C "$D/repo" remote set-url origin "git@github.com:daniel-ospina/tortoise.git/"
git -C "$D/repo" config "url.$D/origin.git.insteadOf" "git@github.com:daniel-ospina/tortoise.git/"
rp "$D" "" OR="daniel-ospina/tortoise"
ck "(h4b) an scp-form '…:tortoise.git/' origin is ACCEPTED (rc=$RC)" "$([ "$RC" -eq 0 ]; echo $?)"
# …and the FOURTH arm, the scp form WITHOUT `.git` (review cycle 7, P2): stripping `*":$OR/"` from all
# three lists left the suite green — the comment above claimed every row was its own fixture while
# that one was covered by nothing. Each of the four is a row now, so every TRAILING-SLASH spelling is
# pinned. ⛔ THE SIX PRE-EXISTING ARMS ARE STILL PINNED BY NOTHING: deleting `"$OR"`, `"$OR.git"`,
# `*":$OR"`, `*":$OR.git"`, `*"/$OR"` and `*"/$OR.git"` from all three lists leaves the suite GREEN (no
# integer — the note above explains why: a count here was re-derived as false one round later). Stated
# rather than implied, so a future lane can pin them the same way.
mk_case cause-trailing-slash-scp-nogit
git -C "$D/repo" remote set-url origin "git@github.com:daniel-ospina/tortoise/"
git -C "$D/repo" config "url.$D/origin.git.insteadOf" "git@github.com:daniel-ospina/tortoise/"
rp "$D" "" OR="daniel-ospina/tortoise"
ck "(h4c) an scp-form '…:tortoise/' (no .git) origin is ACCEPTED (rc=$RC)" "$([ "$RC" -eq 0 ]; echo $?)"
# ── (h4d) THE CANDIDATE LOOP'S COPY OF THE SAME PREDICATE, ONE ROW PER SPELLING ─────────────────────
# ⛔ THE AUTO-DERIVE PATH IS WHAT A CELL WITHOUT `REPO=` USES (review cycles 8-9, P2), and it carries its
# own copy of the accept list — the same duplication this file's `RP_CLEAR` exists to stop. Stripping the
# arms from THAT copy alone left the suite green for three of the four, so the path a cell actually takes
# on a box with no exported checkout could lose them silently. The candidate list is derived from `$OR`'s
# last path segment (`$HOME/<name>`, `/tmp/<name>`), so a SYNTHETIC `$OR` names a candidate that cannot
# exist anywhere except where this arm puts it — that is what makes the arm hermetic (see `(h3)`).
# ONE ROW PER SPELLING: a single row covered only `*"/$OR/"`, and the other three stayed silent.
H4D_OR="no-such-org/tortoise-derived-3174"
H4D_N=0
for h4d_spelling in \
  "https://github.com/no-such-org/tortoise-derived-3174/" \
  "https://github.com/no-such-org/tortoise-derived-3174.git/" \
  "git@github.com:no-such-org/tortoise-derived-3174/" \
  "git@github.com:no-such-org/tortoise-derived-3174.git/"
do
  H4D_N=$((H4D_N+1))
  mk_case "cause-derived-$H4D_N"
  git clone -q "$D/origin.git" "$D/home/tortoise-derived-3174"
  git -C "$D/home/tortoise-derived-3174" config user.email t@t
  git -C "$D/home/tortoise-derived-3174" config user.name t
  git -C "$D/home/tortoise-derived-3174" remote set-url origin "$h4d_spelling"
  git -C "$D/home/tortoise-derived-3174" config "url.$D/origin.git.insteadOf" "$h4d_spelling"
  rp "$D" "" REPO= OR="$H4D_OR"
  ck "(h4d) a DERIVED candidate with the origin '$h4d_spelling' is ACCEPTED (rc=$RC)" "$([ "$RC" -eq 0 ]; echo $?)"
  case "$OUT" in *"REPO was not set — using"*) r=0 ;; *) r=1 ;; esac
  ck "(h4d) …and it was that candidate the pass chose ('$h4d_spelling')" "$r"
done
# ⛔ THE UNSET-`$REPO` ARM IS HERMETIC BECAUSE THE CANDIDATE LIST IS DERIVED FROM `$OR` (review cycle 3,
# P2 — this arm was briefly retired on a FALSE premise). `repo_candidates` builds `/tmp/${OR##*/}` and
# `$HOME/${OR##*/}`, so a SYNTHETIC `$OR` names candidates that cannot exist on any box, while every
# other candidate (`/tmp/cell`, `${TORTOISE_REPO}`, `${TORTOISE}`) is rejected by the origin check. The
# earlier version exported the real `OR` and this box's real `/tmp/tortoise` checkout made it proceed
# (rc=0), which pinned the box — that is a fixture problem, not a reason to leave `_pair`'s `else`
# branch with zero coverage.
mk_case cause-no-repo
rp "$D" "" REPO= OR="no-such-org/no-such-repo-3174"
ck "(h3) with no \$REPO set at all the pass still REFUSES (rc=$RC)" "$([ "$RC" -eq 3 ]; echo $?)"
case "$(rec why)" in *"no \$REPO was set"*"no candidate checkout"*) r=0 ;; *) r=1 ;; esac
ck "(h3) …and the cause says no checkout was FOUND, naming no origin ($(rec why | cut -c1-90))" "$r"
# …and the UNSET-origin shape, which is the THIRD refusal `_pair` names and which `(h3)`'s header claims
# is pinned. Without it, a URL naming `$OR` and an origin that cannot be read are indistinguishable in
# the record.
mk_case cause-no-origin
git -C "$D/repo" remote remove origin
rp "$D" "" OR="daniel-ospina/tortoise"
ck "(h3) a checkout with NO origin remote still REFUSES (rc=$RC)" "$([ "$RC" -eq 3 ]; echo $?)"
case "$(rec why)" in *"NO READABLE 'origin'"*) r=0 ;; *) r=1 ;; esac
ck "(h3) …and the cause says the origin is UNREADABLE ($(rec why | cut -c1-90))" "$r"
case "$(rec why)" in *"local-path"*) r=1 ;; *) r=0 ;; esac
ck "(h3) …and does not claim a local-path origin it never read" "$r"
# …and the FILE:// MIRROR, which is not evidence of a different repo (review cycle 13, P2): it matched
# the `*://*` classifier and was reported as "a DIFFERENT repo, and no retry can mend a mismatch" — an
# identity claim never measured, about the shape this repo calls a legitimate local mirror.
mk_case cause-file-url
git -C "$D/repo" remote set-url origin "file://$D/origin.git"
rp "$D"
ck "(h3) a file:// mirror origin REFUSES (rc=$RC)" "$([ "$RC" -eq 3 ]; echo $?)"
case "$(rec why)" in *"local-mirror"*) r=0 ;; *) r=1 ;; esac
ck "(h3) …and the cause calls it a LOCAL MIRROR, not a different repo ($(rec why | cut -c1-80))" "$r"
case "$(rec why)" in *"DIFFERENT repo"*) r=1 ;; *) r=0 ;; esac
ck "(h3) …and it makes no identity claim it did not measure" "$r"
# ⛔ THE LOG AND THE RECORD MUST AGREE (review cycle 14, P2): the record said "local mirror" while the
# log line one above it still said "NOT the queue target … another repo's tree is #1901". Both say the
# same thing now; these rows pin the LOG half.
case "$OUT" in *"local mirror"*) r=0 ;; *) r=1 ;; esac
ck "(h3) …and the LOG calls it a local mirror too" "$r"
case "$OUT" in *"another repo's tree"*) r=1 ;; *) r=0 ;; esac
ck "(h3) …and the log makes no #1901 identity claim about it" "$r"
# …and the remedy it offers is one that CAN work (review cycle 15, P2): the sibling local-path arm may
# say "or unset OR to use the harness default" because IT is gated on `OR_DECLARED`; this refusal is
# unconditional, and this fixture runs with the harness default already in force. Re-adding the clause
# to the `file://` arm reddens this row, and the sibling arm keeps printing the string elsewhere — so
# the row is not vacuous.
case "$OUT" in *"unset OR"*) r=1 ;; *) r=0 ;; esac
ck "(h3) …and offers no 'unset OR' remedy the refusal ignores" "$r"

echo
echo "==> $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
