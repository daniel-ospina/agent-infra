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
#   (h3) the RECORDED cause names what the resolver actually read, instead of predicting one mechanism
#       for all of them: the no-`$REPO` candidate SEARCH (no origin is recorded there at all), an
#       unreadable origin, a `file://` local mirror, a URL naming another repo, and a local path that
#       cannot prove a DECLARED target — the five shapes `_pair` can name;
#   (h4) an origin that NAMES the queue target with a trailing slash is the same repo: it PROCEEDS, so
#       the cause can never report a "DIFFERENT repo" mismatch it did not measure.
#
# #3584 — THE GH PRECONDITION MUST NAME ITSELF IN THE RECORD, one arm each:
#   (g)  the gh precondition refuses LOCALLY (rc=75) and the RECORD names the specific precondition,
#        instead of the old pointer `(the refusal line above names which one)` — and claims NO quota
#        exhaustion that 75 does not establish. ⛔ IT QUOTES THE FIRST CAPTURED LINE, which on this arm is
#        `wait_for_cooldown`'s PACING note, not the `gh-contended` verdict three lines down: production's
#        capture is three notes and `gh_probe_evidence` takes the first, so the row pins the pacing note
#        IN and the `gh-contended` line OUT (#3701 review round 7, P2);
#   (g2) NON-VACUITY: reverting ONLY the call-site interpolation in a copy puts the pointer back and
#        drops the evidence — so (g) measures the record, not the probe's log line;
#   (g3) the clause is MEASURED, not constant: a REJECTED credential (HTTP 401) is still rc=3 and is
#        recorded as rejected, claiming no budget refusal;
#   (g4) rc=75 with a ZERO-BYTE capture is named off the EXIT CODE, and the empty capture is named as
#        such — the branch a text classifier could not reach at all;
#   (g5) the DEFAULT shape: the probe's own 20 s bound fires first (a stub that really sleeps), and the
#        record says NON-ANSWER — claiming neither a rejected credential NOR anything about the budget
#        ("not a spent budget" was an over-claim: the shim sleeps 120 s on a shared window before 75);
#   (g6) the OTHER default shape — rc=1 with a rate-limit stderr. Without this row that arm's
#        interpolation could be deleted green. (Provenance NOT claimed: it is a plausible refusal
#        shape, not a string quoted from the issue — see the row's own comment.);
#   (g7) THE BEAT'S OWN LINE — not just the record. `refresh_cause_brief` cuts `why=` at 400 BYTES
#        (`orch-loop.sh:2559`), so a clause can be complete in the record and still reach the operator
#        severed. This arm drives the REAL `refresh_cause_brief` and pins the invariant the clause is
#        now ordered by: the cut may land inside the EVIDENCE, never inside the verdict;
#   (g8) the evidence TAKE is BOUNDED — a 1010-byte stderr is cut at the cap, the marker is visible and
#        the tail beyond it is absent, so deleting the truncation reds three ways;
#   (g9) the DEFAULT (rate-limit timeout) arm carries an evidence SLOT — the row pins the
#        interpolation, not a production byte count, because a killed shim may flush nothing;
#   (g10) the CREDENTIAL-LOOKUP timeout arm carries one too — the arm whose own `fix:` line names a
#        hung credential helper, so the dropped stderr was exactly the diagnosis it recommends.
#   (g11)/(g12) EVERY interpolating arm places `evidence=` LAST, checked in the SOURCE across all of
#        them with a pinned floor, plus a per-arm row for the `credential lookup returned no token` arm;
#   (g16) a credential lookup that FAILS is NOT an absence — `gh auth token` exits non-zero for a stored
#        credential its helper cannot decrypt, so the record says UNKNOWN and carries the helper's line
#        (the old clause asserted "nothing is stored" and quoted that very line in the same sentence);
#   (g15) the ENV TOKEN must not reroute the stage from outside: an ambient `GH_TOKEN` in the runner's
#        environment is cleared by `RP_CLEAR`, and the same name handed to the invocation IS used —
#        measured before the clear existed: `GH_TOKEN=dummy` reddened both `(g10)` record rows;
#   (g13) the `gh is not on PATH` arm names its OWN cause — driven by extracting the shipped
#        `gh_probe_env` and running it in a bash whose PATH holds no `gh`, the one environment a seeded
#        sandbox cannot produce (deleting that arm's clause left the suite green before this row);
#   (g14) a capture that fell back to the `/dev/null` sentinel is named UNAVAILABLE, never
#        `no stderr written` — driven BOTH as a unit (the extracted `gh_probe_evidence`) and through the
#        whole pass with an unwritable `TMPDIR`, so the sentinel is proven reachable in production.
#   ⛔ The stub feeds the SHIM's string, not `gh-core-floor`: this call cannot receive a floor line
#   (`gh-limit.py`'s `reaches_api()` is False for the meter), and a fixture asserting one would grade
#   the label against evidence production cannot emit (#3701 review, P2). ALL THREE captured notes are
#   DERIVED from `scripts/gh-shim/gh` itself (with only the runtime figures substituted), so "verbatim"
#   is a fact rather than a transcription.
#   ⛔ AND THE CONSEQUENCE OF DERIVING IS THAT A REWORD CAN LEAVE THE SUITE GREEN — WHICH IS THE POINT,
#   NOT A TRIPWIRE (#3701 review rounds 18-19, P2, mutation-tested). A reword that does not move a pinned
#   figure or an anchor keeps fixture and assertion in step, so nothing reds and nothing SHOULD: a
#   hand-typed copy is the only way this fixture can go stale. (An earlier cut of this paragraph said
#   "a reword of any of them reds a row", and its replacement said the two untaken notes were "correctly
#   ungraded" — both were wider than the mechanism, and the list below is the accurate version.)
#   WHAT *IS* PINNED — three kinds of wording, and the list is exhaustive of what the rows touch:
#     * the PACING note's words, because `(g)` asserts BY CONTENT that the record quotes them —
#       rewording `gh:1479` reds `(g) …the record quotes the FIRST captured line`;
#     * the figure `outlived this call's Nms wait budget` inside `gh:1874`, which the budget-agreement
#       row extracts — rewording it reds `(g) …ONE wait budget`;
#     * the derivation ANCHORS this suite greps for (`the account is in a shared rate-limit window —
#       waiting`, `if the account BUDGET is what refused`, `gh-contended`) — moving one reds the
#       capture-derivation rows outright.
#   Anything else is free: rewording `a shared gh throttle` or `(no API call)` leaves the suite green,
#   because the fixture moves with the shim. So the accurate claim is the one that matters — the fixture
#   can NEVER silently go stale, which is why it is derived — not that no reword can red a row.
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

# mk_gh_budget_stub <case-dir> <rc> <stderr-line> [<sleep-seconds>] — the same `gh`, answering `auth
# token` from a STORED credential but REFUSING the `api rate_limit` validation read with the given rc,
# stderr and (optional) delay. An EMPTY <stderr-line> writes NOTHING AT ALL — a ZERO-BYTE capture, which
# is the shape a probe killed before the shim flushes leaves behind, so that is the one this stub emits.
# ⛔ AND AN EARLIER JUSTIFICATION HERE WAS WRONG (#3701 review round 16, P2): it said `printf '%s\n' ""`
# would "leave the `no stderr written` branch unexercised". It does not — `gh_probe_evidence` takes the
# first NON-EMPTY line (`awk 'NF{print; exit}'`), so a lone newline yields the same empty take and the
# same branch (measured: forcing the one-newline form leaves the suite green). The zero-byte stub is
# kept because it is the real shape, not because a newline would change the arm.
# ⛔ WHAT CAN ACTUALLY REFUSE THIS CALL (#3701 review, P2 — measured, not assumed). `gh api rate_limit`
# IS THE METER: `gh-limit.py`'s `reaches_api()` answers False for it and the CORE floor is gated behind
# `reaches_api`, so `gh-limit: gh-core-floor …` can NEVER appear on this probe's stderr — it comes from
# the CORE reads the same pass makes.
# ⛔ AND THE DEFAULT SHAPE IS THE PROBE'S OWN BOUND, NOT A 75 (#3701 review round 2, P2).
# `scripts/gh-shim/gh`'s `wait_for_cooldown` sleeps out `AGENT_GH_GATE_WAIT_BUDGET` (default 120 s)
# before it exits 75 with `gh-contended`; this probe bounds the same call at `GH_PROBE_TIMEOUT`
# (default 20 s) and kills its process group, so what an operator actually sees at default knobs is
# the TIMEOUT arm. `(g5)` drives THAT shape with a real sleep; `(g)` drives the 75 verdict contract,
# which is reachable when the wait budget is set below the probe bound.
mk_gh_budget_stub() {
  local D="$1" rc="$2" line="$3" nap="${4:-0}"
  case "$nap" in ''|*[!0-9]*) nap=0 ;; esac
  cat > "$D/bin/gh" <<SH
#!/bin/bash
case "\$1 \$2" in
  "auth token") exit 0 ;;
  *" rate_limit"*) [ "$nap" -le 0 ] || sleep "$nap"; [ -z "$line" ] || printf '%s\\n' "$line" >&2; exit $rc ;;
  *) printf '[]\\n' ;;
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
# ⛔ `GH_TOKEN`/`GITHUB_TOKEN` ARE ON THIS LIST BECAUSE THEY REROUTE THE WHOLE PROVISION STAGE (#3701
# review round 24, P2). `gh_probe_env` short-circuits the credential lookup when either is set
# (`presence=env`), which SKIPS the `gh auth token` probe and every clause row that measures it — so on
# a box that exports either one, `(g10)` measures the SUCCESS path and reports "a hung credential LOOKUP
# is TRANSIENT" about a lookup that never ran. MEASURED before the clear was added: 179/16 in a
# bash-5.2 container, and `GH_TOKEN=dummy` gave 177/18 with both `(g10)` record rows red. `(g15)` pins
# the pair in both directions: an ambient token handed to the RUNNER must not reach the pass, and the
# same token handed to the INVOCATION must be used (it is a credential gh itself honours).
RP_CLEAR=(-u TORTOISE_REPO -u TORTOISE -u SCOUT_UV -u SCOUT_PY -u SCOUT_UV_EXTRAS
          -u SCOUT_LOCK_STALE_SECS -u OR -u OR_OPERATOR_DECLARED -u GH_TOKEN -u GITHUB_TOKEN)
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
# `resolve_repo` refuses a REPO-set pair for FOUR different measured reasons (an unreadable origin, a
# `file://` mirror that names no repo identity, a URL naming ANOTHER repo, a local path that cannot prove
# a DECLARED target). The carried cause asserted the local-path wording for all four — a refusal that predicts a mechanism it never measured, the #2229
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
# (stated at the top of this file — cited by name, not by line: this PR has moved line numbers twice) and made the arm's outcome depend on egress. `insteadOf` rewrites the transport while
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
# …and the UNREADABLE-origin shape — the FIRST arm of `_pair`'s case (`''`), not the third. Without it, a
# URL naming `$OR` and an origin that cannot be read are indistinguishable in the record.
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

# ── (g) THE GH PRECONDITION MUST NAME ITSELF IN THE RECORD (#3584) ────────────────────────────────
# ⛔ THE DEFECT. The call site recorded
#
#     why=TRANSIENT: the gh environment precondition refused (the refusal line above names which one) …
#
# — a POINTER into the log, written into `state/refresh-last`, which is the artifact `orch-loop.sh`
# builds `[dispatch] BLOCKED: refresh failed — stage=provision` from. (`.refresh-blocked` is a SEPARATE
# surface: it quotes the LOG, never this file — `orch-loop.sh:8801` greps `$LOG` for `NOT
# PROVISIONABLE`, and it is written on the rc=3 and rc=78 arms only; see `refresh-candidates.sh`'s own
# paragraph.) A reader
# of the RECORD therefore got no cause at all: "refused
# because auth", "refused because the gh layer would not let the call out" and "refused because the
# box could not reach GitHub" were indistinguishable in the one sentence an operator reads. That is
# #3584's own acceptance criterion for the provision stage, and the reason a week of `TRANSIENT`
# refusals presented with "no visible cause".
#
# The rows below drive the SHIPPED pass against a stub whose `gh` refuses exactly that read, and read
# the RECORD (not the log) — the record is what the beat prints.
# ⛔ THE STUB FEEDS THE SHIM'S REAL STRING, NOT A FLOOR LINE (#3701 review, P2). `gh api rate_limit` is
# the METER: `gh-limit.py`'s `reaches_api()` answers False for it, so the CORE floor — which is gated
# behind `reaches_api` — can never refuse this call, and a `gh-core-floor` line on its stderr is a
# shape production cannot emit. What DOES refuse it is the shared-cooldown layer in
# `scripts/gh-shim/gh:1874`, and this is that layer's own wording.
mk_case gh_budget
# ⛔ THE FIXTURE IS THE SHIM'S CAPTURE, IN THE ORDER THE SHIM WRITES IT (#3701 review rounds 3, 6, 7).
# It has been wrong twice and each time in the same direction — a hand-shaped copy instead of the bytes:
#   * round 3: ASCII hyphens where the shim writes em dashes (240 bytes against the real 244);
#   * round 6: the note WITHOUT `gate_note`'s own `gh-gate: ` prefix (`scripts/gh-shim/gh:679`), which
#     made the line 253 bytes rather than the 244 of the note alone;
#   * round 7 (P2): the wrong LINE ENTIRELY. `wait_for_cooldown` appends TWO notes to `$NOTEF` before the
#     refusal is written — `gh:1479` the shared-window/pacing note, `gh:1485` the budget-read note — and
#     `flush_notes 75` (`gh:1876`) then cats all three to stderr. `gh_probe_evidence` takes the FIRST
#     non-empty line, so the record quotes the PACING note and the 244-byte `gh-contended` verdict is
#     line 3, which the probe never reaches. A fixture emitting only `gh-contended` therefore asserted a
#     shape production cannot emit for this arm — the same defect class as the round-3 `gh-core-floor`
#     finding, one layer down. The stub now emits all three lines in production's order.
# ⛔ ALL THREE ARE DERIVED FROM `scripts/gh-shim/gh` (#3701 review round 8, P2). Pinning the pacing and
# budget-read notes as hand-typed literals would leave the two lines that ACTUALLY reach the record
# undrifted by nothing — a reword of `gh:1479` would change no row — so they are extracted with the same
# grep/sed as the verdict line, with only the runtime figures substituted (`$(( (rem + 999) / 1000 ))`
# → `5`, `${WAIT_BUDGET_MS}` → `1000` in BOTH notes, `$GATE_DIR` → `/gate`). A residual `$` in ANY of
# the three is a FAILURE, not a silently stale fixture.
# ⛔ TWO THINGS THIS GOT WRONG FIRST TIME, both caught by the rows below rather than by reading:
#   * `gate_note`'s `gh-gate: ` prefix is added by `gate_note` ITSELF (`gh:679`), so it is NOT part of the
#     extracted argument — the first two capture lines were built without it while the third had it;
#   * `gh:1485` interpolates `$GATE_DIR` with NO braces, so a `${GATE_DIR}` pattern matched nothing.
SHIM="$HERE/../../scripts/gh-shim/gh"
shim_note_line() {  # <grep-anchor> <sed-expr>… — the gate_note ARGUMENT, from the shipped shim
  local anchor="$1"; shift
  grep -m1 "^ *gate_note \"$anchor" "$SHIM" \
    | sed -e 's/^ *gate_note "//' -e 's/"$//' "$@"
}
# ⛔ ONE gh CALL HAS ONE `WAIT_BUDGET_MS`, AND IT IS ONE VARIABLE HERE (#3701 review rounds 10-11, P2).
# `scripts/gh-shim/gh:1764` assigns it once per call and BOTH notes interpolate that same value, so a
# capture showing `(budget 1000ms)` on line 1 and `120000ms wait budget` on line 3 is a shape no single
# call can emit — the same defect class as emitting the wrong line. The round-10 fix wrote `1000` in two
# places by hand, which is HOW the divergence happened, and nothing asserted the two agreed: reverting
# one of them left the suite green. So the figure is a single variable, and a row below compares the two
# rendered figures against it. 1000 is also the value that makes this arm REACHABLE: a wait budget below
# the probe's 20 s bound is the only way the 75 arm is hit at all.
SHIM_WAIT_MS=1000
SHIM_NOTE="$(shim_note_line 'gh-contended' -e "s/\${WAIT_BUDGET_MS}/$SHIM_WAIT_MS/")"
SHIM_PACE="$(shim_note_line 'the account is in a shared rate-limit window — waiting' \
  -e 's/\$(( (rem + 999) \/ 1000 ))/5/' -e "s/\${WAIT_BUDGET_MS}/$SHIM_WAIT_MS/")"
SHIM_BUDGET="$(shim_note_line 'if the account BUDGET is what refused' -e 's|\$GATE_DIR|/gate|')"
# every line is `gh-gate: ` + its argument, which is what `flush_notes` cats to stderr
SHIM_CAPTURE="$(printf '%s\n%s\n%s' "gh-gate: $SHIM_PACE" "gh-gate: $SHIM_BUDGET" "gh-gate: $SHIM_NOTE")"
# ⛔ THE CAPTURE'S SHAPE IS ASSERTED, NOT ASSUMED (#3701 review round 8, P2). The rows below are only
# meaningful if the stub really captures THREE lines in production's order — the round-7 fixture was
# green under a mutation that dropped both later lines, because nothing counted them.
SHIM_BAD=''
case "$SHIM_NOTE" in *'gh-contended'*) ;; *) SHIM_BAD='the shim no longer emits a gh-contended note' ;; esac
case "$SHIM_PACE" in *'shared rate-limit window'*) ;; *) SHIM_BAD='the shim no longer emits a pacing note' ;; esac
case "$SHIM_BUDGET" in *'BUDGET is what refused'*) ;; *) SHIM_BAD='the shim no longer emits a budget-read note' ;; esac
case "$SHIM_NOTE$SHIM_PACE$SHIM_BUDGET" in
  *'$'*) SHIM_BAD='a derived line still carries an unexpanded shell reference' ;;
esac
ck "(g) the stub emits production's 3-note capture, ALL derived from the shim" \
   "$([ -z "$SHIM_BAD" ]; echo $?)"
[ -n "$SHIM_BAD" ] && bad "(g) …could not be derived: $SHIM_BAD (a hand-typed copy is what these rows exist to stop)"
# ⛔ AND THE TWO NOTES MUST AGREE ON THE BUDGET FIGURE — the property the round-10 commit fixed and
# nothing pinned (#3701 review round 11, P2): with one hand-written `1000` in each, reverting either
# left the suite green on the exact shape that commit calls impossible.
cap_budget_shown() { printf '%s' "$1" | sed -n 's/.*(budget \([0-9]*\)ms).*/\1/p'; }
cap_budget_waited() { printf '%s' "$1" | sed -n "s/.*outlived this call's \([0-9]*\)ms wait budget.*/\1/p"; }
ck "(g) …and ONE wait budget: line 1's (budget N ms) and line 3's N ms agree, both $SHIM_WAIT_MS" \
   "$([ "$(cap_budget_shown "$SHIM_PACE")" = "$SHIM_WAIT_MS" ] \
      && [ "$(cap_budget_waited "$SHIM_NOTE")" = "$SHIM_WAIT_MS" ]; echo $?)"
ck "(g) …in production's order: pacing, budget-read, gh-contended (line count=$(printf '%s' "$SHIM_CAPTURE" | grep -c ''))" \
   "$([ "$(printf '%s' "$SHIM_CAPTURE" | grep -c '')" -eq 3 ] \
      && [ "$(printf '%s' "$SHIM_CAPTURE" | sed -n 1p)" = "gh-gate: $SHIM_PACE" ] \
      && [ "$(printf '%s' "$SHIM_CAPTURE" | sed -n 3p)" = "gh-gate: $SHIM_NOTE" ]; echo $?)"
mk_gh_budget_stub "$D" 75 "$SHIM_CAPTURE"
rp "$D"
G_WHY="$(rec why)"
ck "(g) a locally-refused gh precondition is TRANSIENT (rc=$RC)" "$([ "$RC" -eq 1 ]; echo $?)"
ck "(g) …and the failure is recorded at the provision stage (stage=$(rec stage))" \
   "$([ "$(rec stage)" = provision ]; echo $?)"
ck "(g) …and the RECORD names the PRECONDITION, not a pointer to a log line" \
   "$(case "$G_WHY" in *'refusal line above names which one'*) echo 1 ;; *'question='*) echo 0 ;; *) echo 1 ;; esac)"
# ⛔ AND IT QUOTES THE LINE THE PROBE ACTUALLY TAKES — the FIRST one (#3701 review round 7, P2). The
# pair below is the point: the pacing note is IN and the `gh-contended` verdict is OUT, so a fixture (or a
# take) that changed which line is read reddens here instead of silently grading a shape production
# cannot emit.
ck "(g) …and the record quotes the FIRST captured line, which is the PACING note" \
   "$(case "$G_WHY" in *'shared rate-limit window — waiting 5s before this call'*) echo 0 ;; *) echo 1 ;; esac)"
ck "(g) …and does NOT carry the gh-contended verdict, which is line 3 and never taken" \
   "$(case "$G_WHY" in *'gh-contended'*) echo 1 ;; *) echo 0 ;; esac)"
# ⛔ AND IT MUST NOT CLAIM A CAUSE 75 DOES NOT ESTABLISH (#3701 review, P1). 75 is EX_TEMPFAIL —
# "refused LOCALLY, nothing was sent" — which is ALSO single-flight BUSY and the shared-window verdict;
# `gh-limit.py:3439` records "a contended verdict is NOT a limit" as a defect it fixed. A clause saying
# "quota" here would publish, in the one sentence this change exists to make true, a diagnosis the
# evidence beside it contradicts.
# ⛔ A TWO-PHRASE NEGATIVE IS NOT A CONTROL (#3701 review round 14, P2). These rows matched only
# `quota/throttling` and `out of quota`, so a clause claiming `budget exhausted` — the exact over-claim
# class they exist to catch — passed: measured, the mutated rc=75 arm kept the suite at 186/0. The
# predicate below matches ANY affirmative exhaustion wording, on a lower-cased copy so case cannot hide
# it. ⛔ DECLARED RESIDUAL: this is a TOKEN LIST, not a proof — a novel phrasing that contains none of
# these stems would still pass. It is a floor, and it is the floor the two mutations that beat the old
# version now fail.
claims_exhaustion() {  # <text> — 0 when it asserts an affirmative budget/quota cause
  local t
  t="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$t" in
    *exhaust*|*'out of quota'*|*'out of budget'*|*'quota/throttling'*|*'spent budget'*|\
    *'budget exceeded'*|*'quota exceeded'*|*'budget is'*|*'quota is'*|*'no budget left'*|\
    *'budget gone'*|*'throttl'*|*'rate limit exceeded'*)
      return 0 ;;
  esac
  return 1
}
# ⛔ POLARITY, AND I GOT IT BACKWARDS FIRST TIME (#3701: caught on this row, not by me). `claims_exhaustion`
# returns 0 ON A MATCH, like `grep`, so `"$(claims_exhaustion "$x"; echo $?)"` passed when the clause DID
# claim exhaustion and reddened the correct clause — a fail-open control, plus a false red on the shipped
# code. The `if` form below inverts it into `ck`'s 0-means-pass convention, and the mutation that beats
# the old two-phrase row (`… NOT an outage, budget exhausted`) now reds.
ck "(g) …and claims NO quota/budget exhaustion that rc=75 does not establish" \
   "$(if claims_exhaustion "$G_WHY"; then echo 1; else echo 0; fi)"
ck "(g) …and DOES say nothing was sent, so neither credential nor budget was tested" \
   "$(case "$G_WHY" in *'nothing was sent, so NEITHER the credential NOR the budget was tested'*) echo 0 ;; *) echo 1 ;; esac)"
# ⛔ NON-VACUITY: revert ONLY the call-site interpolation in a copy and re-run the SAME fixture. If the
# record still named the clause, these rows would be measuring the probe's log line rather than what
# the record carries — i.e. they would be green for a fix that was never applied.
GM="$T/mut-gh-pointer.sh"
if mut "$GM" <<'PY'
import sys
src = open(sys.argv[1]).read()
new = src.replace(
  'provision_fail "$_ghev" "the gh environment precondition refused [${GH_PROBE_CAUSE:-NO CLAUSE RECORDED by gh_probe_env — the specific precondition was not named}] — no candidate can be judged from this box"',
  'provision_fail "$_ghev" "the gh environment precondition refused (the refusal line above names which one) — no candidate can be judged from this box"')
assert new != src, "the call-site anchor drifted — nothing was reverted"
open(sys.argv[2], "w").write(new)
PY
then
  rp "$D" "$GM"; GM_WHY="$(rec why)"
  ck "(g2) with the call-site interpolation reverted the pass STILL refuses (rc=$RC)" "$([ "$RC" -eq 1 ]; echo $?)"
  ck "(g2) …and its record falls back to the POINTER, so (g) is not vacuous" \
     "$(case "$GM_WHY" in *'refusal line above names which one'*) echo 0 ;; *) echo 1 ;; esac)"
  # ⛔ AND THE ONE ROW THAT CAN RED IS THE LIVE RECORD'S (#3701 review round 24, P3). A row reading the
  # REVERTED record for the `evidence=` slot looked like coverage and was DEAD WEIGHT: the mutant
  # replaces the whole interpolation with a compile-time literal, so no capture content and no
  # `evidence=` can reach that record by ANY route — if the anchor drifts instead, `mut()` fails and the
  # `bad` branch above runs, so the `ck` rows are never evaluated at all. It is the LIVE record's slot
  # that is the thing the interpolation adds and the pointer lacks, and deleting the interpolation
  # reddens THIS row (measured).
  ck "(g2) …and the LIVE record carries the evidence= slot the reverted pointer lacks" \
     "$(case "$G_WHY" in *'evidence='*) echo 0 ;; *) echo 1 ;; esac)"
else
  bad "(g2) the non-vacuity control could not be produced"
fi
# ⛔ THE CLAUSE MUST BE THE MEASURED ONE, NOT A CONSTANT. A genuine REJECTED credential must not be
# recorded as a budget refusal — otherwise "always say quota" would satisfy (g) while telling an
# operator to wait out a window that will never fix an expired token.
mk_case gh_401
mk_gh_budget_stub "$D" 1 'gh: Bad credentials (HTTP 401)'
rp "$D"
G401_WHY="$(rec why)"
ck "(g3) a REJECTED credential is still NOT PROVISIONABLE (rc=$RC, expected 3)" "$([ "$RC" -eq 3 ]; echo $?)"
ck "(g3) …and the record names the credential as REJECTED, from the evidence it measured" \
   "$(case "$G401_WHY" in *'REJECTED'*) echo 0 ;; *) echo 1 ;; esac)"
ck "(g3) …and claims NO budget refusal it did not measure" \
   "$(case "$G401_WHY" in *'gh-core-floor'*|*'budget'*|*'quota'*) echo 1 ;; *) echo 0 ;; esac)"
# ⛔ rc=75 IS READ OFF THE EXIT CODE, NOT OFF PROSE. This arm's stub writes a ZERO-BYTE capture, so a
# text classifier would have nothing at all to match — the shape `printf '%s\n' ""` does NOT produce
# (that writes one newline; #3701 review, P2). The record must still name the verdict, and name the
# empty capture as an empty capture rather than rendering an empty parenthetical.
mk_case gh_75
mk_gh_budget_stub "$D" 75 ''
rp "$D"
G75_WHY="$(rec why)"
ck "(g4) a locally-refused validation read is TRANSIENT (rc=$RC)" "$([ "$RC" -eq 1 ]; echo $?)"
ck "(g4) …and rc=75 ALONE is named as a local refusal, with a zero-byte capture to grep" \
   "$(case "$G75_WHY" in *'REFUSED LOCALLY'*) echo 0 ;; *) echo 1 ;; esac)"
ck "(g4) …and the empty capture is NAMED as such, not rendered as an empty parenthetical" \
   "$(case "$G75_WHY" in *'no stderr written'*) echo 0 ;; *) echo 1 ;; esac)"
ck "(g4) …and it still claims no quota exhaustion" \
   "$(case "$G75_WHY" in *'quota/throttling'*|*'out of quota'*) echo 1 ;; *) echo 0 ;; esac)"
# ⛔ (g5) THE DEFAULT SHAPE IS THE PROBE'S OWN BOUND, NOT A 75 (#3701 review round 2, P2).
# `scripts/gh-shim/gh`'s `wait_for_cooldown` sleeps out `AGENT_GH_GATE_WAIT_BUDGET` (default 120 s)
# before returning 75, while this probe bounds the same call at `GH_PROBE_TIMEOUT` (default 20 s) and
# kills its process group. So on an untouched box a shared throttle window reaches the record through
# the TIMEOUT arm. The stub really sleeps here (`GH_PROBE_TIMEOUT=1` makes the bound fire in a second),
# because a fixture that returned instantly would not exercise the arm the bound produces.
mk_case gh_bound
mk_gh_budget_stub "$D" 1 'gh: could not reach GitHub' 5
rp "$D" "" GH_PROBE_TIMEOUT=1
GB_WHY="$(rec why)"
ck "(g5) a probe killed by its own bound is TRANSIENT (rc=$RC)" "$([ "$RC" -eq 1 ]; echo $?)"
ck "(g5) …and the record names a NON-ANSWER, not a cause" \
   "$(case "$GB_WHY" in *'NON-ANSWER'*) echo 0 ;; *) echo 1 ;; esac)"
# ⛔ THE OVER-CLAIM THIS ROW EXISTS FOR: the arm once said "not a spent budget", which a shim sleeping
# out a shared throttle window falsifies — that IS the budget being slept out.
# ⛔ AND IT MUST KEEP `nothing was sent`, WHICH THE SHARED PREDICATE CANNOT CARRY (#3701 review round 15,
# P2). The pre-change row forbade that phrase here and the broadened predicate does not match it, so this
# row NARROWED while the change's whole purpose was to broaden: the timeout arm could say "nothing was
# sent" — which its own comment says it cannot establish — and stay green. It cannot move into
# `claims_exhaustion`, because the rc=75 arm says `nothing was sent, so NEITHER the credential NOR the
# budget was tested` legitimately; the two arms need DIFFERENT forbidden sets.
ck "(g5) …and claims NOTHING about the budget, in either direction, and not that nothing was sent" \
   "$(if claims_exhaustion "$GB_WHY"; then echo 1; else case "$GB_WHY" in *'nothing was sent'*) echo 1 ;; *) echo 0 ;; esac; fi)"
# ⛔ (g6) THE OTHER DEFAULT SHAPE — rc=1 with a rate-limit stderr. Without this row, deleting the
# `$(gh_probe_evidence "$prc")` interpolation from that arm left every other arm green.
# ⛔ AND ITS PROVENANCE IS NOT CLAIMED ANY MORE (#3701 review round 12, `unverifiable`). This comment
# used to say the string was "#3584's own measured scenario", and a reviewer could not confirm that from
# the issue: #3584's measured provision refusal was a `gh-core-floor` BUDGET line, which by this file's
# own reasoning cannot reach this probe at all. The fixture is a plausible rate-limit refusal, not a
# quoted one, and it says so.
mk_case gh_default
mk_gh_budget_stub "$D" 1 'gh: HTTP 403: API rate limit exceeded for user ID 81560491'
rp "$D"
GD_WHY="$(rec why)"
ck "(g6) the default failing arm is TRANSIENT (rc=$RC)" "$([ "$RC" -eq 1 ]; echo $?)"
ck "(g6) …and the record QUOTES the measured refusal verbatim" \
   "$(case "$GD_WHY" in *'API rate limit exceeded for user ID 81560491'*) echo 0 ;; *) echo 1 ;; esac)"
ck "(g6) …and still names the precondition rather than pointing at the log" \
   "$(case "$GD_WHY" in *'refusal line above names which one'*) echo 1 ;; *'question='*) echo 0 ;; *) echo 1 ;; esac)"
ck "(g6) …and does NOT reuse another arm's verdict (no REJECTED, no NON-ANSWER)" \
   "$(case "$GD_WHY" in *'REJECTED'*|*'NON-ANSWER'*) echo 1 ;; *) echo 0 ;; esac)"

# ── (g7) THE BEAT'S 400-BYTE CUT MUST NOT SEVER THE VERDICT (#3701 review round 3, P2) ────────────
# ⛔ EVERY ROW ABOVE READS `rec why`, AND `why=` IS UNBOUNDED — `refresh_record_write` writes it whole.
# The line an OPERATOR sees is `refresh_cause_brief`'s, which cuts it at 400 BYTES (`orch-loop.sh:2559`;
# `cut -c1-400`, byte-wise), and `provision_fail` has already spent 52 of those on
# `TRANSIENT: the gh environment precondition refused [` plus 46 on the trailing
# `] — no candidate can be judged from this box`. So a suite that reads only the record stays GREEN
# while the beat prints half a sentence — which is exactly what happened: with the evidence first, the
# real 101-byte capture loses `, source=stored)` off the end of `question=` (which is absent whole from a
# 160-byte capture), and from 171 bytes the cut reaches the verdict's last byte (all measured through the
# real renderer; see the script's own block for the full table).
# The invariant pinned here: the cut may land inside the EVIDENCE (variable-length, and whole in the
# record), never inside the VERDICT (fixed-size, and the thing that names the precondition).
LOOP="${LOOP:-$HERE/orch-loop.sh}"
BRIEF="$T/refresh-cause-brief.sh"
if [ -f "$LOOP" ]; then
  {
    awk '/^refresh_record_field\(\)/{f=1} f{print} f&&/^}$/{exit}' "$LOOP"
    awk '/^refresh_cause_brief\(\)/{f=1} f{print} f&&/^}$/{exit}' "$LOOP"
  } > "$BRIEF"
fi
if [ -s "$BRIEF" ] && grep -q '^refresh_cause_brief()' "$BRIEF" && grep -q 'cut -c1-400' "$BRIEF"; then
  mk_case gh_beat
  mk_gh_budget_stub "$D" 75 "$SHIM_CAPTURE"
  rp "$D"
  GBEAT_WHY="$(rec why)"
  # The REAL renderer, over the REAL record — not a re-implementation of the cut. ⛔ THE SNAPSHOT IS THE
  # WHOLE RECORD, not `rec why`: `refresh_cause_brief` parses `why=` back out of the snapshot, so handing
  # it the bare VALUE renders "no cause recorded" and every row below would grade a line with no clause.
  GBEAT="$(REC="$(cat "$D/o/state/refresh-last")" bash -c '. "$1"; refresh_cause_brief "$REC"' _ "$BRIEF" 2>&1)"
  ck "(g7) the beat line still names the precondition COMPLETE (REFUSED LOCALLY, NOT auth/outage)" \
     "$(case "$GBEAT" in *'REFUSED LOCALLY'*'NOT auth and NOT an outage'*) echo 0 ;; *) echo 1 ;; esac)"
  ck "(g7) …and still says WHICH question was asked, uncut" \
     "$(case "$GBEAT" in *'question=can the stored credential answer at all (gh api rate_limit, source='*) echo 0 ;; *) echo 1 ;; esac)"
  # ⛔ NON-VACUITY, AND THE REASON THIS ARM IS NOT A TAUTOLOGY: the cut must GENUINELY HAVE FIRED, and the
  # two rows above must not be passing on a clause short enough to fit whole. The test is a BYTE
  # COMPARISON because that is the event itself; the earlier substring form only went absent once the cut
  # had eaten the whole 40-byte trailing phrase. (The two happen to agree — the phrase IS the tail — which
  # is why the byte form is the honest way to say it: it states the event instead of inferring it from a
  # phrase whose length must then be kept in step with the suffix.)
  ck "(g7) …with the cut genuinely FIRED (why=… exceeds the 400-byte window)" \
     "$([ "$(printf '%s' "$GBEAT_WHY" | wc -c)" -gt 400 ]; echo $?)"
  # ⛔ AND THE CUT LANDS IN THE EVIDENCE — the assertion is the PAIR, so neither half can pass vacuously:
  # the beat KEEPS the quoted line's head and LOSES its tail, while the RECORD keeps the whole line.
  ck "(g7) …and the cut lands INSIDE the evidence (its head survives: the layer names itself)" \
     "$(case "$GBEAT" in *'evidence=rc=75: gh-gate: the account is in a shared rate-limit window'*) echo 0 ;; *) echo 1 ;; esac)"
  ck "(g7) …proving the cut severed the QUOTED line's tail (…(budget 1000ms) is outside the beat)" \
     "$(case "$GBEAT" in *'(budget 1000ms)'*) echo 1 ;; *) echo 0 ;; esac)"
  # ⛔ AND THE RECORD KEEPS THE WHOLE QUOTED LINE. Since round 8 the pacing note is DERIVED from
  # `scripts/gh-shim/gh:1479`, so a reword there now reds the `(g)` derivation rows first; this row reds
  # only if the RECORD stops carrying the line the beat severed, which is the property it names.
  ck "(g7) …while the RECORD still carries the quoted line WHOLE, so nothing is lost where it is read less often" \
     "$(case "$GBEAT_WHY" in *'(budget 1000ms)'*) echo 0 ;; *) echo 1 ;; esac)"
else
  bad "(g7) the real refresh_cause_brief could not be extracted from $LOOP — the beat's cut is ungraded"
fi

# ── (g11) EVERY ARM PLACES `evidence=` LAST — checked in the SOURCE, not one arm at a time ─────────
# ⛔ `(g7)` proves the ordering by DRIVING the real renderer — on the rc=75 arm only. That is one arm,
# and the gap was live for eight rounds: the `gh auth token` rc≠0 arm kept `evidence=` mid-clause with
# `question=` last, so a long enough capture reached the record with the half that names the
# precondition cut away — and reverting the ordering on that arm, or on the `*)` fallback `(g6)`
# drives, left this suite green (verified: 184/0 both ways). A per-arm row cannot close that; the
# invariant is a property of the SOURCE, so this row reads the source.
# It asserts: any `GH_PROBE_CAUSE=` assignment that interpolates `gh_probe_evidence` must have nothing
# but the closing quote after that interpolation.
# ⛔ AND THE SWEEP ITSELF WAS VACUOUS WHEN FIRST WRITTEN — the pattern ended at `gh_probe_evidence`
# with no trailing `*`, so it required the ASSIGNMENT TO END there and matched ZERO lines; the
# offender row then passed on an empty set (measured: `found 0`, the vacuity row red). The trailing
# `*` is what makes the match, and the vacuity row below is what makes an empty sweep loud rather
# than green — the lesson this whole file keeps re-learning about controls that cannot red.
GEV_ARMS=0; GEV_BAD=0; GEV_TAIL=''
while IFS= read -r gev_line; do
  case "$gev_line" in
    *'GH_PROBE_CAUSE='*'gh_probe_evidence'*) ;;
    *) continue ;;
  esac
  GEV_ARMS=$((GEV_ARMS+1))
  gev_after="${gev_line##*'gh_probe_evidence "$prc")'}"
  # A `case` arm closes with ` ;;` after the assignment's closing quote; anything else after that
  # quote is a continuation of the clause, i.e. the datum is NOT last.
  case "$gev_after" in
    '"'|'" ;;') ;;
    *) GEV_BAD=$((GEV_BAD+1)); GEV_TAIL="${GEV_TAIL}${GEV_TAIL:+; }…$(printf '%s' "$gev_after" | cut -c1-40)" ;;
  esac
done < <(grep -F 'GH_PROBE_CAUSE=' "$REFRESH")
# ⛔ THE FLOOR IS THE CURRENT COUNT, DELIBERATELY (#3701 review round 15, P2). It was relaxed to `-ge 4`
# "so a legitimate arm merge should not red it" — but at 5 arms that makes ONE arm's evidence slot
# indistinguishable from a merge: deleting the interpolation from the `nothing is stored` arm dropped the
# count to 4 and the suite stayed green, which is the (g9)/(g10) class this sweep was added to close. A
# red here is a prompt to update the number, which is a cheap, visible cost; an undetected loss is not.
GEV_EXPECT=5
ck "(g11) the sweep is not vacuous — it found $GEV_ARMS arm(s) interpolating evidence= (expected $GEV_EXPECT; bump this when arms merge or split)" \
   "$([ "$GEV_ARMS" -eq "$GEV_EXPECT" ]; echo $?)"
ck "(g11) every one of them places evidence= LAST (after it: $(printf '%s' "$GEV_BAD") offender(s)${GEV_TAIL})" \
   "$([ "$GEV_BAD" -eq 0 ]; echo $?)"

# ⛔ AND THE `credential lookup returned no token` ARM'S SLOT GETS ITS OWN ROW (#3701 review round 15,
# P2). `(g9)` and `(g10)` pin the two timeout arms; this arm had no row at all, so deleting its
# interpolation was invisible — the class those rows exist for, one arm over. The anchor is the arm's
# own VERDICT text, not its old `nothing is stored` wording: that wording WAS the round-24 P2, and
# pinning the phrase would have made the over-claim look intended. `(g16)` is what forbids its return.
GSTORE_LINE="$(grep -F 'the credential lookup returned no token, which does NOT establish absence' "$REFRESH" | head -1)"
ck "(g12) the credential-lookup-failed arm interpolates evidence= LAST" \
   "$(case "$GSTORE_LINE" in *'evidence=$(gh_probe_evidence "$prc")"') echo 0 ;; *) echo 1 ;; esac)"

# ⛔ (g13) THE `gh IS NOT ON PATH` ARM NAMES ITS OWN CAUSE (#3701 review round 23, P2). This arm had NO
# row at all: `rp`/`rpc` always prepend a seeded `$dir/bin` carrying a `gh` stub, so `command -v gh`
# succeeded in every sandbox, the arm was never entered, and deleting its `GH_PROBE_CAUSE=` assignment
# left the suite at 187/0 — while the record degraded to the `NO CLAUSE RECORDED …` fallback, i.e. the
# pointer-shaped outcome this whole change exists to delete, on the arm whose own log line says a cell
# "could only MERGE (#1736)". Same class as (g12), one arm over — and (g11)'s sweep correctly does not
# cover it (that arm carries no `evidence=` slot), which is exactly why it needs a row of its own.
# The row drives the SHIPPED function body (EXTRACTED, not re-implemented) inside a bash whose PATH holds
# no `gh` at all — the one environment a seeded sandbox cannot produce. No repo run, so it is hermetic.
GNOPATH_FN="$T/gh-probe-env.fn"
awk '/^gh_probe_env\(\)/{f=1} f{print} f&&/^}$/{exit}' "$REFRESH" > "$GNOPATH_FN"
BASH_ABS="$(command -v bash)"
mkdir -p "$T/no-gh-path"
if [ -s "$GNOPATH_FN" ] && grep -q '^gh_probe_env()' "$GNOPATH_FN" && [ -n "$BASH_ABS" ]; then
  GN_OUT="$(env -u GH_TOKEN -u GITHUB_TOKEN PATH="$T/no-gh-path" "$BASH_ABS" -c '
    EXIT_NOT_PROVISIONABLE=3
    . "$1" || exit 99
    gh_probe_env >/dev/null 2>&1
    printf "%s\n%s\n" "$?" "$GH_PROBE_CAUSE"
  ' _ "$GNOPATH_FN" 2>&1)"
  GN_RC="$(printf '%s\n' "$GN_OUT" | sed -n 1p)"
  GN_CAUSE="$(printf '%s\n' "$GN_OUT" | sed -n 2p)"
  ck "(g13) a box with no gh on PATH still refuses as NOT PROVISIONABLE (rc=${GN_RC:-none})" \
     "$([ "$GN_RC" = 3 ]; echo $?)"
  ck "(g13) …and the clause NAMES the precondition rather than falling to NO CLAUSE RECORDED" \
     "$(case "$GN_CAUSE" in *'gh is not on PATH'*) echo 0 ;; *) echo 1 ;; esac)"
else
  bad "(g13) the gh_probe_env arm could not be extracted from $REFRESH (or bash was not resolvable) — the arm's clause is UNPINNED"
fi

# ⛔ (g14) A CAPTURE THAT FELL BACK TO `/dev/null` IS "UNAVAILABLE", NOT "no stderr written" (#3701
# review round 23, P2). `gh_probe_bounded` sets `GH_PROBE_ERR=/dev/null` when `mktemp` fails, and
# `[ -s /dev/null ]` is FALSE BY CONSTRUCTION — so before this row the clause said `no stderr written`
# about a capture that never existed. That is a positive claim about the PRODUCER, and it is false: the
# refusal wrote its stderr into the device node and it was discarded. The difference is the whole point
# of a clause that claims only what its arm establishes.
# The row drives the shipped `gh_probe_evidence` (extracted) with the sentinel, then the SAME function
# with a real capture — the pair is what makes the branch discriminating rather than always-on.
GEV_FN="$T/gh-probe-evidence.fn"
awk '/^gh_probe_evidence\(\)/{f=1} f{print} f&&/^}$/{exit}' "$REFRESH" > "$GEV_FN"
if [ -s "$GEV_FN" ] && grep -q '^gh_probe_evidence()' "$GEV_FN" && [ -n "$BASH_ABS" ]; then
  GDEV_OUT="$(GH_PROBE_ERR=/dev/null "$BASH_ABS" -c '. "$1"; gh_probe_evidence 75' _ "$GEV_FN" 2>&1)"
  printf 'gh: HTTP 403: API rate limit exceeded\n' > "$T/gev-capture"
  GCONV_OUT="$(GH_PROBE_ERR="$T/gev-capture" "$BASH_ABS" -c '. "$1"; gh_probe_evidence 1' _ "$GEV_FN" 2>&1)"
  ck "(g14) a /dev/null capture is named UNAVAILABLE (got: ${GDEV_OUT:0:40}…)" \
     "$(case "$GDEV_OUT" in *'UNAVAILABLE'*) echo 0 ;; *) echo 1 ;; esac)"
  ck "(g14) …and does NOT claim the refusal wrote no stderr" \
     "$(case "$GDEV_OUT" in *'no stderr written'*) echo 1 ;; *) echo 0 ;; esac)"
  ck "(g14) …and still carries the rc it was handed" \
     "$(case "$GDEV_OUT" in *'rc=75'*) echo 0 ;; *) echo 1 ;; esac)"
  ck "(g14) …while a REAL capture still quotes its line, so the branch discriminates (control)" \
     "$(case "$GCONV_OUT" in *'HTTP 403'*) case "$GCONV_OUT" in *'UNAVAILABLE'*) echo 1 ;; *) echo 0 ;; esac ;; *) echo 1 ;; esac)"
  # ⛔ AND THE SENTINEL IS REACHABLE IN PRODUCTION, not only by extraction. An unwritable `TMPDIR` makes
  # `gh_probe_bounded`'s `mktemp` fail, which is the exact path that sets the sentinel — so this arm
  # drives the WHOLE pass and reads the clause out of the real record. Without it the three rows above
  # would be a unit test of a state production could never enter.
  mk_case gh_capture_unavailable
  mk_gh_budget_stub "$D" 75 "$SHIM_CAPTURE"
  rp "$D" "" TMPDIR="$D/no-such-tmpdir-on-purpose"
  GCU_WHY="$(rec why)"
  ck "(g14) an unwritable TMPDIR reaches the sentinel in the REAL record (rc=$RC)" \
     "$(case "$GCU_WHY" in *'stderr capture UNAVAILABLE'*) echo 0 ;; *) echo 1 ;; esac)"
  ck "(g14) …and the record does not claim a silent producer on that path" \
     "$(case "$GCU_WHY" in *'no stderr written'*) echo 1 ;; *) echo 0 ;; esac)"
else
  bad "(g14) gh_probe_evidence could not be extracted from $REFRESH — the /dev/null sentinel is UNPINNED"
fi

# ── (g8) THE EVIDENCE TAKE IS BOUNDED (#3701 round 4, P2) ─────────────────────────────────────────
# ⛔ `GH_PROBE_CAUSE_MAX` is the ONLY bound on the stderr take, and NOTHING exercised it: deleting the
# truncation left this suite green. `why=` is a single-line key in a file every beat reads, and a
# `--paginate` refusal can replay a whole error body into it — so an unexercised cap is a bound nobody
# would notice disappearing. The row fails three independent ways when the cap goes: the length, the
# marker, and the tail.
LONGNOTE="$(printf 'A%.0s' $(seq 1 1000))TAILMARKER"
mk_case gh_cap
mk_gh_budget_stub "$D" 1 "$LONGNOTE"
rp "$D"
GC_WHY="$(rec why)"
ck "(g8) a 1010-byte stderr (1000 A's + TAILMARKER) does not reach the record unbounded (why len=${#GC_WHY})" \
   "$([ "${#GC_WHY}" -lt 700 ]; echo $?)"
ck "(g8) …and the take is closed with the ASCII marker, so the cut is visible" \
   "$(case "$GC_WHY" in *'...'*) echo 0 ;; *) echo 1 ;; esac)"
ck "(g8) …and the head of the refusal survives the cut" \
   "$(case "$GC_WHY" in *'AAAA'*) echo 0 ;; *) echo 1 ;; esac)"
ck "(g8) …and the tail beyond the cap is NOT in the record" \
   "$(case "$GC_WHY" in *'TAILMARKER'*) echo 1 ;; *) echo 0 ;; esac)"

# ── (g9) THE TIMEOUT ARM WIRES ITS EVIDENCE SLOT (#3701 round 4; round 7 corrected the claim) ──────
# Both TIMEOUT arms compute the captured stderr and print it to the LOG only. At default knobs the
# rate-limit timeout is the shape that actually fires (this probe bounds at 20 s; the shim sleeps
# 120 s before returning 75), so the record previously had no evidence field at all on that path.
# ⛔ WHAT THE ROW PINS IS THE INTERPOLATION, NOT A PRODUCTION BYTE COUNT. On the default path the
# probe usually kills the call before the shim flushes, so the capture is often EMPTY and the record
# says `rc=142, no stderr written` — a NAMED NON-ANSWER. ⛔ But which arm of `gh_probe_bounded` ran
# decides: perl SIGKILLs (`$SIG{ALRM}=sub{ kill("KILL", -$pid) }` — cited by content, because a
# line number is moved by any edit above it), the `timeout --kill-after=2` fallback sends SIGTERM and the
# shim traps it and flushes (`scripts/gh-shim/gh:1828`, `:740-749`), measured `rc=124` with 233 bytes.
# The stub writes stderr BEFORE sleeping precisely because a killed shim cannot — the row proves the
# wiring is live, and the arm's own comment declares both production paths.
mk_case gh_bound_evidence
cat > "$D/bin/gh" <<'SH'
#!/bin/bash
case "$1 $2" in
  "auth token") exit 0 ;;
  *) printf 'gh: connection reset by peer\n' >&2; sleep 5; exit 1 ;;
esac
SH
chmod +x "$D/bin/gh"
rp "$D" "" GH_PROBE_TIMEOUT=1
GBE_WHY="$(rec why)"
ck "(g9) a probe killed by its own bound is TRANSIENT (rc=$RC)" "$([ "$RC" -eq 1 ]; echo $?)"
ck "(g9) …and the RECORD carries the captured stderr, not just the log" \
   "$(case "$GBE_WHY" in *'connection reset by peer'*) echo 0 ;; *) echo 1 ;; esac)"
ck "(g9) …and the VERDICT still leads the evidence, so the beat can never cut it" \
   "$(case "$GBE_WHY" in *'NON-ANSWER'*'evidence='*) echo 0 ;; *) echo 1 ;; esac)"

# ── (g10) THE OTHER TIMEOUT ARM CARRIES ITS EVIDENCE TOO (#3701 round 5, P2) ───────────────────────┐
# (g9) drives only the `gh api rate_limit` timeout arm — its stub answers `auth token` with exit 0 —
# so the `gh auth token` timeout arm's interpolation was pinned by NOTHING, and deleting it left the
# suite at 177/0. That arm is the one whose `fix:` line names a hung gpg/keyring helper as the usual
# cause, so the dropped stderr is exactly the diagnosis an operator needs. The stub hangs on the
# credential lookup itself and writes its stderr first.
mk_case gh_token_bound_evidence
cat > "$D/bin/gh" <<'SH'
#!/bin/bash
case "$1 $2" in
  "auth token") printf 'gh: gpg: decryption failed: No secret key\n' >&2; sleep 5; exit 1 ;;
  *) printf '[]\n' ;;
esac
SH
chmod +x "$D/bin/gh"
rp "$D" "" GH_PROBE_TIMEOUT=1
GBT_WHY="$(rec why)"
ck "(g10) a hung credential LOOKUP is TRANSIENT (rc=$RC)" "$([ "$RC" -eq 1 ]; echo $?)"
ck "(g10) …and the RECORD carries the stderr naming the hung helper" \
   "$(case "$GBT_WHY" in *'No secret key'*) echo 0 ;; *) echo 1 ;; esac)"
ck "(g10) …and names the question it could NOT answer (presence, not validity)" \
   "$(case "$GBT_WHY" in *'gh auth token'*) echo 0 ;; *) echo 1 ;; esac)"

# ── (g16) A CREDENTIAL LOOKUP THAT FAILS IS NOT AN ABSENCE (#3701 review round 24, P2) ─────────────
# ⛔ THE ARM'S OLD CLAUSE WAS `answer=NO — nothing is stored for the host gh is configured for`, AND THE
# EXIT STATUS DOES NOT ESTABLISH THAT. `gh auth token` fails with a 1 for a credential that IS stored and
# cannot be READ (gpg/keyring with no tty, a malformed `hosts.yml`, a denying keyring) just as it does
# for an empty store. This fixture is `(g10)`'s stub failing FAST instead of hanging — the SAME evidence
# (`gpg: decryption failed: No secret key`), one arm over — so the pre-fix record asserted an absence and
# quoted, in one sentence, proof that a credential exists. MEASURED: this arm's absence row is ❌ on
# `b48c727ae` and ✅ after the clause was corrected to UNKNOWN; the other three rows are reach/evidence
# rows that stay green both ways and exist so the discriminator is read in the arm it names.
mk_case gh_token_lookup_failed
cat > "$D/bin/gh" <<'SH'
#!/bin/bash
case "$1 $2" in
  "auth token") printf 'gh: gpg: decryption failed: No secret key\n' >&2; exit 1 ;;
  *) printf '[]\n'; exit 0 ;;
esac
SH
chmod +x "$D/bin/gh"
rp "$D"
GTF_WHY="$(rec why)"
ck "(g16) a credential lookup that FAILS FAST still refuses as NOT PROVISIONABLE (rc=$RC, expected 3)" \
   "$([ "$RC" -eq 3 ]; echo $?)"
ck "(g16) …and the record does NOT assert an absence its exit status cannot establish" \
   "$(case "$GTF_WHY" in *'nothing is stored'*|*'no credential is stored'*|*'answer=NO — nothing'*) echo 1 ;; *) echo 0 ;; esac)"
ck "(g16) …and the record carries the helper's own line, which names the real fault" \
   "$(case "$GTF_WHY" in *'No secret key'*) echo 0 ;; *) echo 1 ;; esac)"
ck "(g16) …and names the question it could NOT answer (presence, not validity)" \
   "$(case "$GTF_WHY" in *'gh auth token'*) echo 0 ;; *) echo 1 ;; esac)"

# ── (g15) THE ENV TOKEN IS THE AMBIENT KNOB THAT REROUTES THE WHOLE STAGE (#3701 round 24, P2) ────
# ⛔ `gh_probe_env` treats GH_TOKEN/GITHUB_TOKEN as PRESENCE and returns before the credential lookup, so
# an ambient token in the RUNNER's environment silently converts every `(g*)` arm that drives the
# `gh auth token` path into a measurement of the SUCCESS path — measured before `RP_CLEAR` cleared the
# pair: `GH_TOKEN=dummy` turned both `(g10)` record rows red while the rc row still said
# "a hung credential LOOKUP is TRANSIENT" about a lookup that never ran. The pair below is two-way, like
# `(h)`/`(h2)`: handed to the RUNNER it must NOT reach the pass, and handed to the INVOCATION it must be
# used — so neither side can pass by the mechanism being dead. The clause names `source=` on the rc=75
# arm, which is what makes the path observable at all.
mk_case gh_env_token_ambient
mk_gh_budget_stub "$D" 75 "$SHIM_CAPTURE"
GH_TOKEN=ambient-token rp "$D"
GET_WHY="$(rec why)"
ck "(g15) an AMBIENT exported GH_TOKEN does not reach the pass (rc=$RC)" "$([ "$RC" -eq 1 ]; echo $?)"
ck "(g15) …so presence is still read from the CREDENTIAL STORE, not from the runner's ambient env" \
   "$(case "$GET_WHY" in *'source=env'*) echo 1 ;; *'source=stored'*) echo 0 ;; *) echo 1 ;; esac)"
mk_case gh_env_token_handed
mk_gh_budget_stub "$D" 75 "$SHIM_CAPTURE"
rp "$D" "" GH_TOKEN=handed-token
GETH_WHY="$(rec why)"
ck "(g15) …while the same name handed to the INVOCATION IS used, so the row above is not vacuous" \
   "$(case "$GETH_WHY" in *'source=env'*) echo 0 ;; *) echo 1 ;; esac)"

# ── (h5) THE FOURTH COPY OF THE ACCEPT LIST MUST NOT DRIFT ────────────────────────────────────────
# ⛔ THE DRIFT THIS PINS WAS LIVE (review of #3188, P2). The predicate has FOUR copies: three here
# (the REPO-set arm, the candidate loop, and `_pair`'s cause classifier) and a fourth in
# `scripts/cloud-cell-supervisor.sh`'s OWN `resolve_repo`, which is the auto-derive path a cell with no
# exported `$REPO` takes. The trailing-slash spellings were added to these three and NOT to that one,
# so the two entry points disagreed on a URL-shaped origin — `refresh --check` derived the checkout,
# `cloud-cell-supervisor.sh check` died "REPO is not set and no single checkout could be derived" —
# which also made this file's DECLARED RESIDUAL paragraph ("the two verbs agree wherever the origin is
# URL-shaped") false as written. That paragraph is the thing a future lane trusts when deciding the
# entry points agree, and a per-copy behavioural arm in the supervisor's own suite (its `(7d)`) pins
# the BEHAVIOUR; this row pins the LOCKSTEP, so the next spelling added to one copy and not the others
# reddens here instead of shipping a second divergence.
# ⛔ STATED RESIDUAL: if a future change SINGLE-SOURCES the predicate (both files calling one helper),
# the supervisor's copy disappears and this row reds. That is a deliberate over-block — re-pin the row
# consciously, because the cheap alternative (an absence-tolerant comparison) is green in exactly the
# case this arm exists to catch.
RP_ROOT="$(cd "$HERE/../.." && pwd -P)"
RP_SUP="$RP_ROOT/scripts/cloud-cell-supervisor.sh"
# The arm list itself, whitespace-normalised and with a trailing ` ;;` dropped: the three `case` copies
# end in `;;`, `_pair`'s copied list does not, and that difference is a syntax detail — not the
# predicate. Anything else (a missing or extra spelling here) is the drift.
h5_lines() { grep -n '"\$OR"|"\$OR\.git"' "$1" 2>/dev/null | sed 's/^[0-9]*://' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/[[:space:]]*;;$//'; }
H5_REF="$(h5_lines "$REFRESH" | head -1)"
H5_SUP="$(h5_lines "$RP_SUP")"
ck "(h5) the supervisor carries its own copy of resolve_repo's accept list (found in $RP_SUP)" "$([ -n "$H5_SUP" ]; echo $?)"
ck "(h5) …and the SHIPPED refresh-candidates.sh carries at least one (found here)" "$([ -n "$H5_REF" ]; echo $?)"
H5_EXPECT="$([ -n "$H5_REF" ] && echo "$H5_REF" || echo "$H5_SUP")"
H5_DISTINCT="$( { h5_lines "$REFRESH"; h5_lines "$RP_SUP"; } | sort -u | grep -c . )"
ck "(h5) every copy lists the SAME spellings (distinct arm lists: $H5_DISTINCT — 1 means no drift)" "$([ "$H5_DISTINCT" -eq 1 ]; echo $?)"
H5_TS=0
for h5_spelling in '*"/$OR/"' '*"/$OR.git/"' '*":$OR/"' '*":$OR.git/"'; do
  case "$H5_EXPECT" in *"$h5_spelling"*) H5_TS=$((H5_TS+1)) ;; esac
done
ck "(h5) …and the shared list carries all four trailing-slash spellings ($H5_TS of 4)" "$([ "$H5_TS" -eq 4 ]; echo $?)"
# ⛔ NAMING THE DRIFT, not just counting it: when a copy diverges, this row prints the outlier so the
# operator sees WHICH file to edit instead of being sent to re-derive four case arms by hand.
H5_OUTLIERS="$( { h5_lines "$REFRESH"; h5_lines "$RP_SUP"; } | sort | uniq -u | head -3 )"
case "$H5_OUTLIERS" in
  "") r=0 ;;
  *) printf '  (h5) divergent arm list(s):\n%s\n' "$(printf '%s\n' "$H5_OUTLIERS" | sed 's/^/         /')"; r=1 ;;
esac
ck "(h5) …and no copy's list is an outlier" "$r"

echo
echo "==> $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
