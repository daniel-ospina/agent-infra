#!/usr/bin/env bash
# lane-report-gate.sh — the CONSUMER of the mandatory lane report (#2977, owner ruling 2026-10-28).
#
#   . lane-report-gate.sh
#   lane_report_gate <repo-path> <branch> <head>      # prints one line, returns the decision table's code
#   bash lane-report-gate.sh --check <repo> <branch> <head>   # the same, as a command
#
# ── WHY THIS FILE EXISTS ─────────────────────────────────────────────────────────────────────────
# `lane.sh`/`merge-one.sh`/`fix-one.sh` keep push/PR authority with the session gates bypassed BY
# DESIGN (owner ruling 2026-10-28: "formalise the substitution"), and the substitution's evidence half
# is a durable per-lane report (`WORKTREE-REPORT.md`, tortoise#10220) that a VERIFIER reads before
# merge. Measured 2026-11-07 on the deployed tree: NOTHING read it —
#
#     rg -n 'WORKTREE-REPORT|worktree_report' scripts/orchestrator-harness/merge-one.sh   -> 0 hits
#
# while the consumer repos' docs asserted the refusal existed. A doc that promises a gate the code does
# not have is itself the bypass: a lane reading the doc believes it is verified. This file is the
# missing consumer.
#
# ── WHAT IT ADDS OVER THE WRITER'S OWN `check` (measured twice in one lane, 2026-11-07) ─────────
# The report already carries the one signal that was ignored: `head_moved_since_write`. The writer
# deliberately makes it a WARNING and not a failure — a RECORDED DECISION, pinned by
# `tests/test_worktree_report.py::test_a_moved_head_is_a_warning_not_a_failure`, whose docstring names
# the party who owns the judgement: the CONSUMER. Two of four review rounds that day had to be
# re-run because a report described a tree one commit behind the head being merged (round 4 wrote at
# `2e96d9475` for head `1babcf76d`, round 6 at `1babcf76d` for head `899541008`) — and `check` exited 0
# for both. A consumer keying on `$?` would have merged both as green evidence for trees they do not
# describe. So this gate is STRICTER THAN `$?`: a moved head REFUSES here. That is the consumer-side
# judgement the writer left to us, not a reversal of the writer's decision.
#
# ⛔ AND STRICTER THAN THE RECORDED HEAD TOO, because `write_report` re-stamps `head_at_write` on every
# `write`/`note`/idempotent `init` — so the recorded head is a witness a bare re-render can MOVE. The
# one witness it cannot move is the newest suite's `finished_at` (written only by `run`): evidence that
# finished before the merging commit was created cannot describe it, and that is refused as STALE.
#
# ── THE DECISION TABLE (the code IS the contract; `lane-report-gate.test.sh` pins every row) ─────
#   0  PASS            report present, evidence valid, every recorded suite exit 0, head-bound
#   1  ABSENT          a lane worktree for this branch exists and has NO report — silence
#   2  INVALID         the evidence does not hold up (broken log hash, missing section, malformed state)
#   3  RED             valid evidence that records a NON-ZERO suite exit — a lane saying its own tests
#                      failed is not a pass
#   4  STALE           the report does not describe the tree being merged: it was written at a
#                      different head, the worktree is not at that head, or its suites finished
#                      BEFORE the merging commit was created (a re-render re-stamps the recorded
#                      head without re-running anything — see the laundering arm)
#   5  NO-CONSUMER     the repo ships no `tools/worktree_report.py`, so no report of this format exists
#                      to verify; NOT ENFORCED here, and said out loud (see the audit note below)
#   6  NO-WORKTREE     no worktree for this branch on this box, so the lane's evidence is not reachable
#                      from here; UNMEASURED, never "fine"
#   7  UNMEASURABLE    a worktree exists but the check could not be RUN (no interpreter, tool crashed,
#                      unparseable output). An unreadable verification is not a pass.
#
# ⛔ 5 AND 6 ARE ABSTENTIONS, NOT GREEN. They are returned as distinct codes so a caller can print the
#   reason and so a fleet-wide census can see how much of the queue is actually covered. Neither may
#   ever be reported as "the report is fine".
# ⛔ WHY 6 CANNOT SIMPLY REFUSE WHENEVER IT IS RETURNED: measured on the hub checkout 2026-11-08 —
#   13 of 13 open tortoise PRs have NO worktree on that box (the lanes live on the cell). A gate that
#   refused on "I am not the box that has the evidence" would stop every cross-box merge in the fleet,
#   which is the over-blocking failure the A/B rule calls a B-item. The lane's own box always resolves
#   its worktree, so the enforcement binds exactly where the lane is, and the abstention is recorded.
#
# ── THE TRUST BOUNDARY (stated, not implied) ────────────────────────────────────────────────────
# This gate reads the artifact the WRITER produced and re-verifies its own consistency: each recorded
# suite's log FILE must exist and hash to the recorded sha256, and the counts the writer recorded must
# be the counts derivable from that log. It does not, and cannot, prove the command in the log was the
# suite that matters — that judgement stays with the reviewer. Its job is the one the ruling names:
# a stale, absent, empty, or self-contradicting report must not be mergeable.
#
# NO ENV SEAM SELECTS THE VERIFIER (fresh review, P1 — the "disable it by ambient env" bypass). An
# earlier version read `LANE_REPORT_GATE_TOOL` / `LANE_REPORT_GATE_PY`, and both are reachable in
# production: a lane runs `lane-merge.sh` itself, which forks the chain (`nohup bash -c`) and
# `chain-merge.sh` forks the `$O`-pinned `merge-one.sh`, all under plain environment inheritance. One
# `export LANE_REPORT_GATE_TOOL=/tmp/fake.py` therefore made every RED/INVALID report PASS, including
# through the carrier the scoping decision relied on as the backstop. The seams bought nothing — the
# suite plants its consumer at `$REPO/tools/worktree_report.py`, which is the honest route — so they
# are GONE rather than gated behind a second variable.
set -u

# ⛔ `git -C "$repo"` DOES NOT OVERRIDE AN AMBIENT `GIT_DIR` (round-6 review, P0). Git prefers `GIT_DIR`
# / `GIT_WORK_TREE` over the `-C` directory, so every enumeration below — the branch's worktree and the
# main-worktree resolution the consumer is read from — could be answered by a DIFFERENT repository while
# the gate reported a verdict about the named one: measured, `GIT_DIR=<other>/.git` made the gate grade
# another repo's worktree (a PASS) for a branch and head belonging to the named repo. Same class as the
# `PATH`/`PYTHONPATH` seams: an inherited variable choosing the subject of the verdict. The gate never
# needs either — it always names its repo explicitly — so they are dropped once, at entry.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR
# ⛔ `refs/replace/*` REWRITES THE OBJECTS THE GATE READS, SO IT FORGES THE SAME WITNESS WITHOUT AN
# ENVIRONMENT VARIABLE (round-9 review, P1). The unsets above stop a repo being RELOCATED; a
# `refs/replace/<head>` ref does not relocate anything — it makes `git log -1 --format=%cI <head>` below
# return a SUBSTITUTED commit's date, so the `predates` (laundering) arm reads a forged commit time. The
# ref lives in the common gitdir, is not on the branch, and is invisible in the reviewed diff. Measured:
# with `state.json` byte-identical (`cmp` = IDENTICAL), planting one replace ref turned `VERDICT=STALE
# rc=4` into `VERDICT=PASS rc=0`, and `GIT_NO_REPLACE_OBJECTS=1` turned it back. One variable, no fixture
# impact (no fixture creates a replace ref).
export GIT_NO_REPLACE_OBJECTS=1
# ⛔ `GIT_COMMON_DIR` IS THE SAME SEAM AND WAS MISSED (round-8 review, P1). It retargets BOTH `worktree
# list` enumerations — the branch's worktree AND the main-worktree the consumer is read from — and it also
# retargets `resolve_trusted_checkout` in lane-merge.sh, i.e. the function this gate's provenance
# disposition relies on. Measured: with a governed repo whose branch worktree had NO report, and a clone
# holding a digest-valid report at the same head, `GIT_COMMON_DIR=<clone>/.git` turned
# `VERDICT=ABSENT rc=1` into `VERDICT=PASS rc=0` — graded tree and verifier both from the other repo.
# The list below then covers every documented git variable that relocates the repository.

# _lrg_emit <code> <verdict> <key=value>… — one machine-readable line on stdout, then the code.
_lrg_emit() {
  local code="$1" verdict="$2"; shift 2
  printf 'lane-report: VERDICT=%s %s\n' "$verdict" "$*"
  return "$code"
}

# _lrg_py — the interpreter that runs the consumer. The consumer is stdlib-only by design (it must run
# on a cell with no venv), so `python3` is the first choice and `python` the fallback. ⛔ NO
# `LANE_REPORT_GATE_PY` OVERRIDE: an ambient variable that chooses the program which computes the
# verdict replaces both python passes, INCLUDING the laundering witness — a bypass, not a seam.
# ⛔ AND `PATH` IS THE SAME AMBIENT VARIABLE UNDER ANOTHER NAME (fresh review, P1). The no-seam rule
# above was stated while this function resolved the interpreter with `command -v`, which walks the
# INHERITED `PATH` — and a lane runs `lane-merge.sh` itself, which forks the chain (`nohup bash -c`)
# and `chain-merge.sh` forks the `$O`-pinned `merge-one.sh`, all under plain environment inheritance.
# `PATH=/tmp/shim:$PATH` with a two-branch `python3` therefore made every RED/INVALID report PASS
# through BOTH python passes, i.e. exactly the bypass the override removal was meant to close — the
# class was unchanged and only the spelling moved. So the candidates are ABSOLUTE and the inherited
# `PATH` is never consulted. A box that has python only somewhere exotic gets code 7 UNMEASURABLE
# (an unreadable verification is not a pass), which is the honest answer, not a silent downgrade.
# ⛔ VERSION-GATED, NOT FIRST-FOUND (round-8 review, P1). The consumer this gate exists to run
# (`tools/worktree_report.py`, tortoise) REFUSES an interpreter below 3.12 by design and writes NOTHING
# to stdout when it does, so the gate saw "no JSON" and returned 7 UNMEASURABLE — a refusal the lane
# cannot remedy — on every box whose FIRST candidate is older. `/usr/bin/python3` is Apple's 3.9 on
# macOS (and 3.9 on Debian 11 / Ubuntu 20.04), while the 3.12+ build sits at `/opt/homebrew/bin` or
# `/usr/local/bin`, which were consulted AFTER it. The order is now irrelevant: each candidate is probed
# for the floor and the first that SATISFIES it wins. The harness already solves this shape for
# `collision_preflight.py`; this is the same rule (probe, refuse by name), and 7 is only returned when
# NO candidate meets the floor.
_lrg_py() {
  local c
  # ⛔ ROOT-OWNED FIRST, now that the probe makes the order irrelevant (round-9 review, P2). The
  # pre-probe version had to put homebrew first so a 3.12 build could be found; with the floor checked
  # per candidate that reason is gone, and `/opt/homebrew/bin` + `/usr/local/bin` are USER-owned on the
  # macOS layouts this list exists for — preferring them would put the verdict-computing program in a
  # directory the lane's own user can replace. `/usr/bin/python3` is SIP/root-owned on macOS and root on
  # Debian/Ubuntu, so it is preferred wherever it satisfies the floor.
  # ⛔ AND THAT PREFERENCE IS NOT A CLOSURE ON THE macOS SHAPES THIS LIST EXISTS FOR (round-13 review, MED,
  # measured). Where `/usr/bin/python3` is 3.9 it FAILS the probe, so the FIRST SATISFYING candidate is the
  # homebrew/`/usr/local` build — the user-owned directory this comment just called replaceable. Absolute
  # paths therefore close "which PATH entry" but not "which program": a lane that replaces that file
  # chooses the program that computes every arm of the verdict. ⛔ IT IS DISCLOSED RATHER THAN SILENTLY
  # ACCEPTED, and it is NOT fixed here on purpose: refusing a user-writable interpreter refuses EVERY merge
  # on a dev Mac / a cell with no root-owned 3.12, which is a larger outage than the bypass it closes (the
  # harness's own rule: a false block is repaired, not shipped). The durable fix is a pinned, root-owned
  # runtime for the gate, tracked with the `git` half of the same class — agent-infra#3789, whose note
  # covers "a lane that sets PATH can substitute the git that reports the head"; this is that class one
  # program over, and the same 66-fixture bar applies. Do not read `_lrg_py`'s absolute candidates as
  # closing the self-supplied-verifier class.
  for c in /usr/bin/python3 /usr/bin/python /opt/homebrew/bin/python3 /usr/local/bin/python3 \
           /opt/homebrew/bin/python /usr/local/bin/python; do
    [ -x "$c" ] || continue
    "$c" -I -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 12) else 1)' 2>/dev/null \
      && { printf '%s' "$c"; return 0; }
  done
  return 1
}

# ⛔ THE GIT SEAM: ONE HALF IS CLOSED HERE, THE OTHER IS RECORDED AND FILED (#2977 review round 7).
# The program that answers "which worktree, which HEAD, which commit date" decides WHICH REPO IS GRADED,
# so it is as load-bearing as the interpreter. Two vectors:
#   (1) AN EXPORTED BASH FUNCTION — `git() { … }; export -f git` propagates as `BASH_FUNC_git%%` into the
#       child `bash` hops a lane's carrier forks and shadows the binary with NO PATH change. CLOSED:
#       unset here, at source time, before any call.
#   (2) A `git` EARLIER ON THE INHERITED `PATH`. ⛔ NOT CLOSED, DELIBERATELY AND VISIBLY. Pinning this to
#       absolute paths (as `_lrg_py` does) was implemented and REVERTED: the merge-one fixtures drive
#       the gate with a stubbed `git` on PATH over a SYNTHETIC repo and head, so an absolute pin
#       bypasses the stub and took 66 of that suite's rows red. Closing it needs those fixtures rebuilt
#       around a real repository, which is its own change — not a silent omission here. Until then a
#       lane that sets `PATH` can substitute the git that reports the head. That is FILED (agent-infra
#       #3789, which carries the measurement and the 66-row bar any fix must clear), and disclosed HERE
#       so nobody reads the seam class as closed.
#   (3) NO OTHER PROGRAM IN THE DECISION PATH IS PATH-RESOLVED (fresh review, MED). That is a claim a
#       reader is entitled to check, so it is asserted below and pinned by a suite row: everything that
#       computes or compares a field runs the pinned interpreter (`_lrg_py`) or a bash BUILTIN. The
#       `sed -n … | tail -1` + `cut` that extracted the sealed stamp and the state's 12-hex prefix were
#       the one exception, and a `sed` shim on PATH switched the sealed cross-check off (a two-field
#       edit then PASSed) — they are gone, folded into the isolated JSON pass. `grep`/`sed`/`awk` are
#       not used on any value that decides a code. Treat any NEW PATH-resolved program here as a breach
#       of this disclosure, not as a detail.
unset -f git 2>/dev/null || true

# _lrg_worktree <repo> <branch> — the worktree of <repo> checked out on <branch>, or nothing.
# ⛔ EXACT BRANCH MATCH ONLY. `refs/heads/<branch>` compared whole: a prefix match would hand the gate
# a DIFFERENT lane's report (`feat/297-tm` for `feat/2977-tm`), which verifies a tree nobody is
# merging — the same false-green class this file exists to close.
_lrg_worktree() {
  local repo="$1" branch="$2" wt="" br="" line="" listing=""
  [ -n "$repo" ] && [ -n "$branch" ] || return 1
  # Captured FIRST, then walked: a `while read` fed by a process substitution would run in a SUBSHELL,
  # so the `printf`/`return 0` below would exit the subshell and the caller would see an empty result
  # on a branch that IS there — a gate that silently abstains on every real lane.
  listing="$(git -C "$repo" worktree list --porcelain 2>/dev/null)" || listing=""
  [ -n "$listing" ] || return 1
  while IFS= read -r line; do
    case "$line" in
      'worktree '*) wt="${line#worktree }" ;;
      'branch refs/heads/'*)
        br="${line#branch refs/heads/}"
        if [ "$br" = "$branch" ] && [ -n "$wt" ]; then printf '%s' "$wt"; return 0; fi
        ;;
      '') wt="" ;;
    esac
  done <<< "$listing"
  return 1
}

# _lrg_stanza_at_head <repo> <head> — a worktree stanza whose HEAD is <head>.
# ⛔ THIS IS WHAT SEPARATES A CROSS-BOX ABSTENTION FROM A SELF-INFLICTED ONE (round-10 review, P0).
# `git worktree list --porcelain` prints `HEAD <sha>` in every stanza, including a DETACHED one that has no
# branch line — so a lane that detaches its own worktree is still visible here, and its evidence with it.
# ⛔ WHAT THIS DELIBERATELY DOES *NOT* DO: IT DOES NOT CHECK THE BRANCH. Round 11 removed the
# `-f WORKTREE-REPORT.md` conjunct from the FIRING condition on purpose (a lane turned off its own
# precondition by deleting the report), so the only lane-independent fact left is "a stanza of this repo
# sits at the merging head" — that is what fires, and what the stanza HOLDS decides only the wording.
# (The earlier comment here claimed a branch check this function never performed; the branch-attribution
# arm lives in `_lrg_evidence_off_branch` below, which is where it can actually be evaluated.)
_lrg_stanza_at_head() {
  local repo="$1" head="$2" wt="" hd="" line="" listing=""
  [ -n "$repo" ] && [ -n "$head" ] || return 1
  listing="$(git -C "$repo" worktree list --porcelain 2>/dev/null)" || listing=""
  [ -n "$listing" ] || return 1
  while IFS= read -r line; do
    case "$line" in
      'worktree '*) wt="${line#worktree }"; hd="" ;;
      'HEAD '*) hd="${line#HEAD }"
                if [ "$hd" = "$head" ] && [ -n "$wt" ]; then
                  printf '%s' "$wt"; return 0
                fi ;;
    esac
  done <<< "$listing"
  return 1
}

# _lrg_stanza_paths <repo> — every worktree path in `git worktree list --porcelain`, one per line.
_lrg_stanza_paths() {
  local repo="$1" line="" listing=""
  [ -n "$repo" ] || return 1
  listing="$(git -C "$repo" worktree list --porcelain 2>/dev/null)" || listing=""
  [ -n "$listing" ] || return 1
  while IFS= read -r line; do
    case "$line" in 'worktree '*) printf '%s\n' "${line#worktree }" ;; esac
  done <<< "$listing"
  return 0
}

# _lrg_evidence_off_branch <repo> <branch> <head> — a worktree that NAMES this branch's evidence while NOT
# being registered on the branch (a detached HEAD, or a scratch branch), or nothing.
# ⛔ DETACHING AT A MERGING HEAD WAS ONLY HALF THE BYPASS (fresh review, P0). The arm above fires when a
# stanza sits at the MERGING head, so the SAME one command with one different argument —
# `git switch --detach HEAD~1`, or `git switch -c scratch HEAD~1` — left every artefact untouched and
# answered 6 NO-WORKTREE, the code BOTH carriers log as "NOT ENFORCED" and merge on. RED/INVALID/STALE/
# UNMEASURABLE are all downstream of that resolution, so the whole table was defeated by one argument.
# The discriminator is still "does this box NAME the evidence", just not only "at this head": the writer
# state keeps the lane's `branch` (detaching changes the ref, not the lane) and `head_at_write` (the head
# the evidence claims to describe). Either matching this branch or this head makes the box the holder of
# the evidence, and a holder that cannot be graded is UNMEASURABLE, never an abstention.
# ⛔ THE RESIDUAL IS DISCLOSED, NOT IMPLIED: a lane that detaches at another commit AND deletes
# `.worktree-report/state.json` from that worktree leaves nothing that attributes the worktree to this
# branch, and this arm answers 6 as it does for a genuine cross-box merge. Closing that needs a
# lane-independent attribution (the same class as #3789's `git` seam), not another lane-owned file.
# Returns 0 and prints the path when attributed, 1 when no stanza holds a writer state at all (the
# caller then keeps its ABSTENTION), 2 when a holder exists but no interpreter can read it.
# ⛔ THE INTERPRETER IS RESOLVED ONLY AFTER A HOLDER IS FOUND (round-13 review, MED). Resolving it first
# turned the CROSS-BOX abstention into a hard refusal on every box below the 3.12 floor — macOS
# `/usr/bin/python3` is 3.9 — because `_lrg_py` failing short-circuited to 2 before any state was even
# looked for. That is a refusal the box cannot remedy (its printed remedy is "re-run the suites") applied
# to the 13-of-13 cross-box shape this file exists to keep mergeable. "An unreadable attribution is not an
# abstention" applies to a box that HOLDS the evidence, not to one that holds nothing.
_lrg_evidence_off_branch() {
  local repo="$1" branch="$2" head="$3" p="" py="" kv="" b="" hw="" holders=""
  [ -n "$repo" ] || return 1
  # Pass 1 — bash builtins only: which stanzas hold a writer state, and does any of them even MENTION this
  # branch or this head? Both questions are answered without an interpreter, and both are what code 6 turns
  # on. ⛔ A HOLDER IS NOT AN ATTRIBUTION (round-13 review, MED): a multi-lane box has worktrees for OTHER
  # branches holding their own state, and refusing on the bare existence of one turned every cross-box merge
  # into a hard refusal on any box below the 3.12 floor — while the same repo WITH an interpreter answers 6.
  # The substring test is a heuristic, and it is allowed to be one: when an interpreter IS available the
  # exact parse in pass 2 decides, and when it is not, the cheapest alternative for the lane is the
  # already-disclosed residual (delete the state, answer 6) — so it hands the graded party nothing new.
  local named=0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    [ -f "$p/.worktree-report/state.json" ] || continue
    holders="$holders$p
"
    if [ "$named" = 0 ]; then
      while IFS= read -r _lrg_raw; do
        case "$_lrg_raw" in
          *"$branch"*|*"$head"*) [ -n "$branch" ] || [ -n "$head" ] && named=1; break ;;
        esac
      done < "$p/.worktree-report/state.json"
    fi
  done <<< "$(_lrg_stanza_paths "$repo")"
  [ -n "$holders" ] || return 1
  py="$(_lrg_py)" || { [ "$named" = 1 ] && return 2; return 1; }
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    [ -f "$p/.worktree-report/state.json" ] || continue
    # The two fields are read in ONE isolated pass, with the SAME pinned interpreter the verdict uses:
    # a `grep`/`sed` over JSON here would be a PATH-resolved program computing part of the decision.
    kv="$("$py" -I -c 'import json, sys
# ⛔ THE KEYS ARE READ FROM THE UNDIGESTED WRITER STATE AND ARE LANE-WRITABLE. That is why they may only
# NAME the evidence ("this box holds a report for this branch/head"), never whether the arm fires on
# their absence: a lane that deletes them is answering the OTHER spelling of this bypass, which the
# disclosure above states plainly instead of pretending this file can close it.
try:
    with open(sys.argv[1], encoding="utf-8", errors="replace") as _fh:
        _d = json.load(_fh)
except Exception:
    sys.exit(3)
if not isinstance(_d, dict):
    sys.exit(3)
# ⛔ CONTROL CHARACTERS ARE STRIPPED FROM THE TWO LANE-WRITABLE FIELDS (round-23 review, P1): the pair is
# joined on \x1f, so a `branch` containing the separator shifted `hw` into the branch and made this scan
# attribute evidence the lane chose. Neither field is a control-character string in any honest state.
_dc = lambda _v: (_v if isinstance(_v, str) else "").replace("\x1f", "").replace("\n", "").replace("\r", "")
print("%s\x1f%s" % (_dc(_d.get("branch")), _dc(_d.get("head_at_write"))))' "$p/.worktree-report/state.json" 2>/dev/null)" || kv=""
    b="${kv%%$'\x1f'*}"
    hw="${kv#*$'\x1f'}"
    [ "$hw" = "$kv" ] && hw=""
    if [ -n "$branch" ] && [ "$b" = "$branch" ]; then printf '%s' "$p"; return 0; fi
    if [ -n "$head" ] && [ -n "$hw" ] && [ "$hw" = "$head" ]; then printf '%s' "$p"; return 0; fi
  done <<< "$(_lrg_stanza_paths "$repo")"
  return 1
}

# lane_report_gate <repo-path> <branch> <head> — the decision table above.
lane_report_gate() {
  local repo="${1:-}" branch="${2:-}" head="${3:-}" wt="" tool="" py="" out="" rc=0
  local ok="" stale="" rules="" rec_head="" live_head="" sealed12="" rec12="" sealed_n="" seal_split="" suite_ev="" _lrg_ev="" _lrg_ev_rc=0

  # ⛔ `head` IS THE WHOLE POINT OF THE GATE, SO AN EMPTY ONE CANNOT PASS ANY ARM (fresh review, P1).
  # The first version took it as documentation: `head=` appeared in every message and in NO comparison,
  # so the gate answered "is there a self-consistent report anywhere in this repo" rather than "does
  # the report describe the tree being merged". Checked BEFORE the worktree arm so that a caller with
  # no head cannot fall into an abstention that reads as tolerable.
  if [ -z "$head" ]; then
    _lrg_emit 7 UNMEASURABLE "branch=$branch reason=no-head-supplied-cannot-bind-the-report-to-a-commit"
    return 7
  fi
  # ⛔ THE SAME RULE APPLIES TO `repo` AND `branch`, AND IT WAS MISSING (fresh review, P1). An empty
  # branch made `_lrg_worktree` return 1, so `wt` was empty and the gate answered **6 NO-WORKTREE** —
  # the code the carriers log as "an abstention, not a green" and then MERGE ON. That is an ingress
  # that cannot name the branch getting the gate's most tolerant outcome, which is the same fail-open
  # the empty-head guard three lines up exists to close (merge-one.sh never validates `$BR`, and
  # chain-merge.sh / fix-one.sh pass it straight from their own argv). An input the gate cannot use is
  # UNMEASURABLE, never an abstention.
  if [ -z "${branch// /}" ]; then
    _lrg_emit 7 UNMEASURABLE "reason=no-branch-supplied-cannot-resolve-a-worktree head=$head"
    return 7
  fi
  if [ -z "$repo" ]; then
    _lrg_emit 7 UNMEASURABLE "branch=$branch reason=no-repo-supplied-cannot-resolve-a-worktree head=$head"
    return 7
  fi
  # ⛔ AN UNUSABLE repo IS NOT A 6 ABSTENTION EITHER (fresh review, P2). `_lrg_worktree` cannot tell
  # "this repo has no such worktree" from "this path is not a repo I can read", so a plain directory, a
  # nonexistent path, or a FILE all fell through to 6 — the code the carriers treat as "this box
  # cannot carry the check" and merge on. 6 stays for a READABLE repo that genuinely lists no matching
  # branch; an unusable argument is 7.
  if ! git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
    _lrg_emit 7 UNMEASURABLE "branch=$branch repo=$repo reason=repo-is-not-a-usable-git-work-tree head=$head"
    return 7
  fi

  wt="$(_lrg_worktree "$repo" "$branch")" || wt=""
  if [ -z "$wt" ]; then
    # ⛔ ABSTAINING HERE WAS LANE-CONTROLLED, AND IT WAS THE CHEAPEST BYPASS IN THE FILE (round-10
    # review, P0). 6 is justified as a property of the BOX ("the lane's evidence is not reachable from
    # here"), but `_lrg_worktree` only recognises a stanza that is ON the branch: one `git checkout
    # --detach` in the lane's own worktree leaves the report, the writer state and the commit in place at
    # exactly the merging head and makes the gate answer 6 — which BOTH carriers log as "NOT ENFORCED"
    # and then merge on (`lane-merge.sh:1339`, `merge-one.sh:1221`). Measured: PASS on a valid report,
    # then `git checkout --detach`, then `VERDICT=NO-WORKTREE rc=6` with every artefact untouched — and
    # that one command defeats RED/INVALID/STALE/UNMEASURABLE at once, because they are all downstream of
    # this resolution.
    # The two cases are distinguishable from the listing already in hand: a CROSS-BOX abstention has no
    # stanza at this head, while a self-detached lane has one. ⛔ THE `WORKTREE-REPORT.md` TEST DOES NOT
    # GATE THE ARM — IT CHOOSES THE WORDING (round-13 review, LOW: an earlier comment here claimed it was
    # "LOAD-BEARING" and that a bare `HEAD == $head` test would over-block the hub-at-head case; both were
    # false — this arm answers 7 with or without a report). Round 11 removed the conjunct from the FIRING
    # condition on purpose, because a lane switched its own precondition off by deleting the report. So a
    # stanza at the merging head fires, report or not, and what it holds decides only the reason; the
    # over-block the old comment named is LIVE and accepted, because the alternative is the delete-the-
    # report bypass that round 11 closed.
    # ⛔ THE LANE-OWNED FACTS MAY CHOOSE THE REASON, NEVER WHETHER THE ARM FIRES (round-11 review, P0).
    # Round 10 keyed the refusal on `-f WORKTREE-REPORT.md` and a `grep` of the state branch, so a lane
    # defeated the arm by turning off ITS OWN PRECONDITION: deleting the report, or dropping the `branch`
    # key from the (undigested) state, restored the mergeable 6 with every other artefact untouched. A
    # stanza at the merging head is the fact that this box NAMES the evidence; what that stanza holds
    # decides the wording.
    if _lrg_sh="$(_lrg_stanza_at_head "$repo" "$head" 2>/dev/null)"; then
      if [ -n "$_lrg_sh" ] && [ -f "$_lrg_sh/WORKTREE-REPORT.md" ]; then
        _lrg_emit 7 UNMEASURABLE "branch=$branch repo=$repo stanza=$_lrg_sh reason=evidence-present-on-this-box-but-no-worktree-is-registered-on-this-branch head=$head hint=check-the-branch-out-in-the-worktree-that-holds-the-report-detach-is-not-an-abstention"
      else
        _lrg_emit 7 UNMEASURABLE "branch=$branch repo=$repo stanza=$_lrg_sh reason=worktree-at-this-head-is-not-registered-on-this-branch-and-holds-no-report head=$head hint=restore-the-branch-in-that-worktree-or-run-the-suites-there"
      fi
      return 7
    fi
    # ⛔ AND DETACHING AT ANY *OTHER* COMMIT IS THE SAME BYPASS ONE ARGUMENT OVER (fresh review, P0).
    # `git switch --detach HEAD~1` / `git switch -c scratch HEAD~1` are not covered by the stanza-at-head
    # arm above, and they answered 6 — the abstention both carriers merge on — with every artefact intact.
    # The box still NAMES the evidence (the writer state keeps `branch` and `head_at_write`), so it must
    # answer 7, not 6. A genuine cross-box merge has no such state on this box and still gets 6.
    _lrg_ev="$(_lrg_evidence_off_branch "$repo" "$branch" "$head" 2>/dev/null)"; _lrg_ev_rc=$?
    if [ "$_lrg_ev_rc" = 2 ]; then
      _lrg_emit 7 UNMEASURABLE "branch=$branch repo=$repo reason=cannot-attribute-this-repos-lane-evidence-without-a-python-3-12-interpreter head=$head hint=install-a-python-3-12-interpreter-an-unreadable-attribution-is-not-an-abstention"
      return 7
    fi
    if [ -n "$_lrg_ev" ]; then
      _lrg_emit 7 UNMEASURABLE "branch=$branch repo=$repo stanza=$_lrg_ev reason=this-box-holds-the-report-for-this-branch-in-a-worktree-that-is-not-at-the-merging-head head=$head hint=check-the-branch-out-at-the-merging-head-and-re-run-the-suites-there-detach-is-not-an-abstention"
      return 7
    fi
    _lrg_emit 6 NO-WORKTREE "branch=$branch reason=no-worktree-for-branch-on-this-box head=$head"
    return 6
  fi
  # ⛔ A PRUNABLE REGISTRATION IS NOT EVIDENCE (fresh review, P2). `git worktree list --porcelain` keeps
  # a stanza after the DIRECTORY is deleted (`prunable gitdir file points to non-existent location`), so
  # the resolver returns a dead path and the gate then refused ABSENT on a file that cannot exist — with
  # a remedy (`write one`) that is impossible in a worktree that is gone. The physical fact is the same
  # one code 6 exists for: the lane's evidence is not reachable from this box. Checked HERE, once, for
  # both the absent and the consumer arms.
  # ⛔ NAMED BUT UNREADABLE IS 7, NOT 6 (round-11 review, P0). `mv`-ing the lane worktree away left the
  # stanza registered ON THE BRANCH at the merging head with the report and state intact, and this arm
  # answered 6 — the code BOTH carriers merge on. The distinction that matters is not "does the directory
  # exist" (lane-controlled) but "does this box NAME the evidence at all": a stanza on this branch names
  # it, so it is UNMEASURABLE with a remedy that can succeed, never the mergeable abstention.
  if [ ! -d "$wt" ]; then
    _lrg_emit 7 UNMEASURABLE "branch=$branch worktree=$wt reason=worktree-registered-but-unreadable head=$head hint=the-branch-is-registered-here-but-its-directory-is-gone-restore-or-recreate-it"
    return 7
  fi

  # ⛔ THE CONSUMER IS RESOLVED BEFORE ABSENCE IS JUDGED, AND THIS ORDER IS LOAD-BEARING. The report's
  # FORMAT is the writer's (`tools/worktree_report.py`, shipped by the consumer repo). A repo that ships
  # no writer cannot produce one, so "absent" there is not silence — it is a repo that does not
  # participate, and refusing it would be an UNSATISFIABLE gate blocking every merge in every such repo
  # (measured: agent-infra and eldato ship no writer today). Decide coverage first, then judge evidence.
  #
  # ⛔ `$repo` ONLY — THE `$wt` FALLBACK IS GONE (fresh review, P1). `$wt` is the LANE worktree on the
  # branch under review, so it is the one tree the lane can edit: keeping it as a second candidate let
  # a lane ADD `tools/worktree_report.py` in its own PR and lift the very refusal that a non-participant
  # repo (5/7) would otherwise get — `$repo` ships no writer there, so the `$wt` branch fired on
  # exactly the repos this decision names. A repo that ships the writer ships it in its checkout; a lane
  # that adds one is asking the graded tree to grade itself.
  tool="$repo/tools/worktree_report.py"
  # ⛔ THE CONSUMER COMES FROM THE REPO'S MAIN WORKTREE, NOT FROM WHATEVER TREE THE CALLER NAMED
  # (fresh review, P2). `lane-merge.sh` resolves this itself (`resolve_trusted_checkout`) and passes
  # main, but `merge-one.sh` passes `$REPO` straight from argv, and a lane that runs the deployed
  # `merge-one.sh` with its OWN worktree would then hand the gate the graded tree's own copy of the
  # writer — the same self-grading escape the `$wt` fallback removal above closed, reached through the
  # `$repo` half instead. Resolving it HERE makes the property hold for every carrier that is handed a
  # LINKED worktree of the governed repo. Falls back to `$repo` only when it cannot enumerate worktrees
  # (a plain/non-git fixture, where `$repo` IS the tree).
  # ⛔ WHAT THIS DOES *NOT* BUY, STATED SO THE COMMENT IS NOT AN OVERCLAIM (round-7 review, P1): it does
  # not make `$repo` trustworthy. A caller that hands the gate an INDEPENDENT CLONE gets that clone's
  # own main worktree as "main" — measured: a lane clone plus three files returned VERDICT=PASS over a
  # graded repo that was RED. main-of-a-clone is not main-of-the-governed-repo, and the gate has no
  # trusted notion of which repo is the subject: that binding belongs to the CALLER. `lane-merge.sh`
  # discharges it by resolving its own trusted checkout; `merge-one.sh` CANNOT — it takes `$REPO` from
  # argv and has no origin/identity check of its own (round-8 review, P1: an earlier version of this
  # comment claimed an "origin-slug guard" in merge-one.sh that does not exist; it was never written,
  # and a disclosure that promises a control the code lacks is itself the bypass). The harness DOES ship
  # the resolver this would need (`repo-target.sh`: `remote get-url origin` -> slug,
  # `--git-common-dir` -> which checkout); wiring it into merge-one.sh is tracked, not done here.
  if _lrg_wl="$(git -C "$repo" worktree list --porcelain 2>/dev/null)" && [ -n "$_lrg_wl" ]; then
    while IFS= read -r _lrg_line; do
      case "$_lrg_line" in
        "worktree "*) _lrg_main="${_lrg_line#worktree }"; break ;;
      esac
    done <<< "$_lrg_wl"
    [ -n "${_lrg_main:-}" ] && tool="$_lrg_main/tools/worktree_report.py"
  fi
  # ⛔ THE GRADER'S PROVENANCE IS A CALLER OBLIGATION, AND IT IS WRITTEN DOWN HERE (round-7 review, P1).
  # Resolving main closes the LINKED-worktree escape but NOT the INDEPENDENT-CLONE one: a clone's own
  # main worktree IS the clone, so a caller that hands the gate a clone supplies the graded tree's own
  # `tools/worktree_report.py`. The gate cannot fix that alone — it has no trusted notion of which repo
  # is the subject — so the disposition is stated rather than silently implied:
  #   * `lane-merge.sh` discharges it for a LINKED WORKTREE ONLY: it resolves `resolve_trusted_checkout`
  #     (the first `git worktree list` stanza) and passes that as MAIN. For a linked worktree the first
  #     stanza is the hub, so the instrument comes from the tree nobody is merging. ⛔ IT DOES NOT
  #     DISCHARGE THE CLONE CASE, and the earlier wording here claimed it did (round-19 review, P1): a
  #     lane that runs `lane-merge.sh` from an independent clone resolves its OWN tree, so `$tool` is
  #     again the graded tree's consumer and a lane could edit it uncommitted. Measured end-to-end on
  #     that wording: `trusted checkout == the lane's clone`, the lane's own 7-line `ok:true` consumer
  #     returned PASS while the committed consumer returned INVALID.
  #   * `merge-one.sh` takes `$REPO` from argv; it is the `$O`-pinned backstop reached by chain-merge.sh
  #     (harness code), so the path is not lane-authored on the normal route. A lane that runs the
  #     deployed `merge-one.sh` itself with its own clone is NOT covered either.
  # ⛔ SO NEITHER CARRIER CLOSES THE SELF-SUPPLIED-INSTRUMENT CLASS; both DISCLOSE it, and it is tracked
  # with its siblings in agent-infra#3789 (which measures the `git` spelling of the same class). A
  # disclosure that promises a control the code lacks IS the bypass, which is why the clone half is
  # stated as uncovered instead of being implied away.
  # ⛔ A PATH-SHAPE TEST WAS TRIED AND REVERTED: refusing when `$tool` sits under `$wt` looks right but
  # OVER-BLOCKS the ordinary case — a lane working directly in the repository root has `$wt` == the
  # checkout, so its consumer is legitimately inside it. Measured: 66 merge-one rows red. An
  # over-blocking gate that refuses honest merges is the failure this file exists to prevent, so the
  # property is documented and the caller's binding is the enforcement point, not a guess about paths.
  [ -f "$tool" ] && [ -s "$tool" ] || tool=""
  if [ -z "$tool" ] || [ ! -f "$tool" ]; then
    # ⛔ AN AUDITED ABSTENTION, the same shape `gate-policy.sh` uses for the gate-policy probe: the
    # state is DATED and ATTRIBUTED instead of being an invisible default, so this gate's coverage can
    # be counted rather than assumed, and it flips to ENFORCED the day the repo adopts the writer.
    if [ -f "$wt/WORKTREE-REPORT.md" ]; then
      _lrg_emit 7 UNMEASURABLE "branch=$branch worktree=$wt report=$wt/WORKTREE-REPORT.md reason=report-present-but-repo-ships-no-consumer head=$head"
      return 7
    fi
    _lrg_emit 5 NO-CONSUMER "branch=$branch worktree=$wt reason=repo-ships-no-tools/worktree_report.py-so-no-report-of-this-format-exists head=$head"
    return 5
  fi

  # ⛔ ABSENCE IS CHECKED BY FILE TEST, not inferred from the consumer's exit code: the consumer also
  # exits 1 for a broken hash or a missing section, and collapsing "the lane wrote nothing" into "the
  # lane's evidence is malformed" loses the exact fact the ruling is about (silence). The code is the
  # same refusal; the MESSAGE is what a human acts on.
  if [ ! -f "$wt/WORKTREE-REPORT.md" ]; then
    _lrg_emit 1 ABSENT "branch=$branch worktree=$wt report=$wt/WORKTREE-REPORT.md reason=no-report-was-written head=$head"
    return 1
  fi

  py="$(_lrg_py)" || { _lrg_emit 7 UNMEASURABLE "branch=$branch worktree=$wt tool=$tool reason=no-interpreter-at-or-above-python-3.12 head=$head"; return 7; }

  # ⛔ `-I` (ISOLATED MODE) IS PART OF THE SAME TRUST BOUNDARY AS THE ABSOLUTE INTERPRETER (round-6
  # review, P0). Pinning the interpreter path closes "which PROGRAM", not "which MODULES": `python3 -c`
  # puts `''` (the process CWD) at `sys.path[0]` and honours `PYTHONPATH`, and BOTH are lane-controlled —
  # a lane runs `lane-merge.sh` itself with cwd = its own worktree, so an UNTRACKED `json.py` (or one
  # `export PYTHONPATH`) made the verdict pass return whatever the graded party wanted: measured
  # RED (`ok:false`, rc 3) → PASS (rc 0) with a shim that only had to define `loads()`. `-I` implies
  # `-E -s` and drops the cwd/script-dir entry, so neither PYTHONPATH nor a cwd `json.py`,
  # `datetime.py` or `sitecustomize.py` can supply a module. Both programs are stdlib-only by design
  # (`_lrg_py`'s note), so `-I` costs nothing.
  out="$("$py" -I "$tool" check --json --worktree "$wt" 2>/dev/null)"; rc=$?
  case "$out" in
    *'{'*) : ;;
    *) _lrg_emit 7 UNMEASURABLE "branch=$branch worktree=$wt tool=$tool reason=consumer-produced-no-json check_rc=$rc head=$head"; return 7 ;;
  esac

  # The merging commit's own creation time, read from the WORKTREE (which the head-binding arms below
  # prove is AT the merging head by the time the predates arm is reached). Used as the one witness a
  # bare re-render cannot move — see `predates` in the JSON pass.
  commit_iso="$(git -C "$wt" log -1 --format=%cI "$head" 2>/dev/null)" || commit_iso=""

  # One python pass, because a hand-rolled grep over JSON is how a gate starts reading a nested key as
  # a top-level one. Prints `<ok>|<stale>|<rules>|<recorded head>`; empty fields are meaningful.
  # ⛔ `-c`, NOT A NESTED HEREDOC: a heredoc body is literal text, so a `<<PY` inside a `<<EOF` body
  # never runs as a program — it is the outer heredoc's DATA, the reader then gets garbage and this gate
  # would abstain on every lane that has a perfectly good report (found before it shipped).
  _LRG_JSON_PY='import datetime, json, os, re, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    sys.exit(3)
if not isinstance(d, dict):
    sys.exit(3)
# ⛔ EVERY FIELD PRINTED BELOW IS SEPARATOR-SAFE (round-23 review, P1). The tuple is joined on a pipe and
# read with IFS splitting on that same pipe, so a pipe inside a LANE-WRITABLE field did not merely corrupt
# one value: it SHIFTED every later field, and lane-written text then supplied rec_head, live_head,
# predates, skew and state_ok to the verdict. Measured: a state head_at_write of "<head>|<head>|0|0|ok"
# re-assigned the whole witness row (the printed sealed-vs-state comparison then compared live_head to
# predates), and a variant returned a false PASS on a report whose seal named a different head. _ishex is
# the sha shape the binding must have; _flat strips separators and control characters from free text.
def _ishex(_v):
    return isinstance(_v, str) and 7 <= len(_v) <= 64 and all(_c in "0123456789abcdefABCDEF" for _c in _v)
def _flat(_v):
    return (_v if isinstance(_v, str) else ("" if _v is None else str(_v))).replace("|", " ").replace("\n", " ").replace("\r", " ")
rules = d.get("rules") or []
if not isinstance(rules, list):
    rules = [str(rules)]
# ⛔ `head_at_write`, NOT `head`. The consumer prints `head` = the CURRENT head of the worktree, so using it
# as "the head the report describes" printed the same sha twice on both sides of a STALE line — a
# message that reads as a contradiction and names nothing (found by driving the gate at a real
# worktree). `head_at_write` lives in the writer state; it is the head the evidence actually
# describes.
rec = ""
newest = None
_any_ts = []
# ⛔ AN UNREADABLE WRITER STATE IS UNMEASURABLE, NOT A PASS. `rec` (the recorded head) and `newest`
# (the newest suite) are BOTH read from this file, and both arms that consume them are `[ -n … ]`-guarded,
# so an unreadable state silently switches BOTH head witnesses off and leaves `ok:true` alone as the
# verdict. The lane owns this worktree, so the cheapest action available to the graded party was to
# remove the witness. Three spellings of that removal are now all refused with 7 UNMEASURABLE:
#   * ABSENT  — `rm state.json` (round-6 review, P1: `rm` is cheaper than damaging the file, so an
#               absent state could not be the one that still passed);
#   * CORRUPT — truncated / unparseable / not a dict;
#   * NO WITNESS — VALID JSON that has simply had `head_at_write` (or every `finished_at`) deleted
#               (round-7 review, P0: `{}` parsed fine and yielded `state_ok = "ok"` with both witnesses
#               dark, so the witness could be removed with a one-line edit instead of a `rm` — the
#               round-6 hole one spelling over). The `run` writer always stamps both, so their absence
#               is tampering on exactly the same argument.
# The reasons are distinguished because the remedies differ; the CODE is the same, because the effect is.
state_ok = "absent"
try:
    with open(sys.argv[2], encoding="utf-8", errors="replace") as fh:
        st = json.load(fh)
    if isinstance(st, dict):
        state_ok = "ok"
        rec = st.get("head_at_write") or ""
        _suites = st.get("suites")
        # ⛔ A PARSING STATE IS NOT A WITNESS. Require `head_at_write`, and require a parseable
        # `finished_at` whenever the state records suites at all (a report with suites and no timestamps
        # has had the laundering witness deleted, not legitimately omitted).
        _have_suites = isinstance(_suites, list) and len(_suites) > 0
        if isinstance(_suites, list):
            for _s in _suites:
                _ts = _s.get("finished_at") if isinstance(_s, dict) else None
                if not _ts:
                    continue
                try:
                    _t = datetime.datetime.fromisoformat(str(_ts).replace("Z", "+00:00"))
                except Exception:
                    continue
                _any_ts.append(_t)
                if newest is None or _t > newest:
                    newest = _t
        if not rec:
            state_ok = "missing-witness"
        elif not _ishex(rec):
            # ⛔ A HEAD BINDING THAT IS NOT A SHA CANNOT BIND A HEAD (round-23 review, P1). This value comes
            # from the writer state (head_at_write) and is LANE-WRITTEN, and it is interpolated into the
            # pipe-delimited field line below. A value containing a pipe therefore SHIFTED every downstream
            # field, so lane-written text supplied rec_head, live_head, predates, skew and state_ok itself,
            # and the sealed cross-check compared garbage to garbage (measured: a false PASS on a report
            # whose seal named a different head). Refusing here closes the shift at its source; a non-hex
            # value is not merely unsafe, it is unusable, so this is not a loosened check.
            state_ok = "missing-witness"
            rec = ""
        elif not _have_suites:
            # ⛔ DELETING EVERY SUITE IS THE SAME TAMPERING AS DELETING EVERY TIMESTAMP (round-27
            # review, P1 — measured). `_have_suites` means "is a non-empty list", so a `suites` value of
            # `[]`, `{}`, `null`, `0` or `"x"` — or no `suites` key at all — made all THREE downstream
            # arms go dark at once: `state_ok` stayed "ok", `newest` stayed None so `predates` was never
            # computed (the laundering arm at `newest is not None`), and the no-output arm skipped out at
            # its own `isinstance(_recs, list) and _recs` guard. Measured against the suite fixture,
            # merging head bound, conforming consumer: one suite with `finished_at=2020` gives STALE
            # rc=4, and the SAME state with the list emptied gives PASS rc=0 (`{}` and `null` likewise).
            # Emptying the list is the CHEAPER edit of the two, so the tampering round 7 closed was
            # refused when spelled "delete every timestamp" and ACCEPTED when spelled "clear the list".
            # The writer records this key with one entry per `run`, so its absence (or an empty or
            # non-list value) is a witness that was DELETED, never one legitimately omitted — and a lane
            # that ran no suite has no evidence to merge on, which is the whole subject of this gate.
            state_ok = "missing-witness"
        elif newest is None:
            state_ok = "missing-witness"
    else:
        state_ok = "corrupt"
except FileNotFoundError:
    state_ok = "absent"
except Exception:
    state_ok = "corrupt"
    rec = ""
# ⛔ THE WITNESS A RE-RENDER CANNOT MOVE (fresh review, P0). `write_report` re-stamps `head_at_write`
# on every `write`/`note`/idempotent `init`, so a lane that runs its suites at A, commits B, and then
# runs any of those three commands presents `head_at_write = B` with evidence taken at A — and both
# of the gate head witnesses then agree with the merge. The newest suite `finished_at` is NOT
# re-stamped by a render, so "the newest suite finished BEFORE the merging commit was created" is the
# one witness that survives a RE-RENDER.
# ⛔ AND THE OTHER SIDE OF THAT COMPARISON IS LANE-AUTHORED TOO (round-10 review, P1). "%cI" is the
# COMMITTER date of the commit under review, which the party making the commit writes: backdating it
# (`GIT_COMMITTER_DATE=2020-01-01 git commit`) makes evidence from the PREVIOUS tree look newer than the
# head, so the arm PASSes a report describing a tree one commit behind — measured end-to-end with the real
# writer, every file honest, no artifact edited; the control (a normally-dated commit) returns STALE. The
# harness already treats commit headers as peer-writable elsewhere (`claims.sh`: a lease body is
# PEER-WRITABLE and "committer Evil <e@x> 1 +0000 used to supply the age"). A local-only gate has no
# lane-independent clock to order against — the trustworthy source would be the host record of the head
# transition (an API timestamp) or a stamp the lane cannot write, both of which are design changes, not
# wiring. So: this arm is a STALENESS SIGNAL, not proof, in BOTH of its inputs. Filed as agent-infra
# #3791 (the writer-side half is daniel-ospina/tortoise#11551).
# ⛔ IT DOES NOT SURVIVE AN EDIT, AND THAT IS DISCLOSED RATHER THAN IMPLIED (round-9 review, P0).
# `finished_at` lives ONLY in `state.json`, which carries no digest — the sealed `WORKTREE-REPORT.md`
# renders `Started:`/`Written:` and each suite command/exit, but NEVER the finish time of a suite (tortoise
# `tools/worktree_report.py` render() ~:380-410; `finished_at` is only ever WRITTEN, at :575, and never
# read back by `cmd_check`). So the consumer returns VALID on a fabricated timestamp BY CONSTRUCTION, and
# the graded party owns that file: measured, changing this ONE value (`2020-01-01` -> `2099-01-01`) turned
# `VERDICT=STALE rc=4` into `VERDICT=PASS rc=0` with the markdown sha256 unchanged. The round-8 sealed
# cross-check covers `head_at_write` only, so what remains is: **`state.json` is attacker-owned except for
# the fields cross-checked against the sealed report** (`head_at_write` today).
# ⛔ THE DURABLE FIX IS WRITER-SIDE (render each suite finish time into the digest-covered markdown) and
# is tracked in tortoise (#11551); a gate-side comparison against the sealed `Written:` stamp does NOT close it (a
# value forged between the commit and the render passes). Until then this arm is a STALENESS signal that
# is honest about being forgeable, not a tamper-proof witness — do not read the phrase "witness" above as
# saying otherwise. ⛔ IT IS A SINGLE-CLOCK COMPARISON ONLY WHEN THE HEAD WAS
# COMMITTED ON THIS BOX (fresh review, P2): a `fix-<PR>`/`adopt-fix` push or another box can stamp the
# commit with a DIFFERENT clock, which is exactly the scenario the `live_head` arm exists for — so the
# skew is measured and NAMED rather than assumed away (see `skew`). It adds no false positive of its
# own: `rec_head != head` ALREADY refuses the ordinary test-then-commit order, because a lane that
# never re-renders keeps `head_at_write` at the pre-commit head. `predates` is empty when either side
# is unreadable, and an empty witness never refuses (the exact head bindings already do).
# ⛔ `<=`, NOT `<`, AND THE EQUALITY IS THE POINT: both clocks are recorded at SECOND resolution, so a
# commit made in the same second the last suite finished is indistinguishable between the honest
# "ran after the commit" case and the laundering case (measured end-to-end: a commit at 06:54:17 and
# a suite finished at 06:54:17 slipped a `<` comparison as a PASS). An ambiguous witness is never read
# as green here — the same rule the writer applies to contradictory counts. The cost is one re-run
# round for a lane whose suite happens to finish in the SAME second as the commit.
predates = ""
skew = ""
if newest is not None and sys.argv[3]:
    try:
        _c = datetime.datetime.fromisoformat(str(sys.argv[3]).replace("Z", "+00:00"))
        # ⛔ EVERY RECORD, NOT JUST THE NEWEST (round-10 review, P2). The remedy text below tells a lane to
        # re-run THE SUITES at the head, and says "only `run` produces evidence for the head you are
        # merging" — a PER-SUITE semantic. A `max` let ONE post-commit suite legitimise every older record
        # riding in the same report, with no editing at all: measured, an honest `run` at the old head plus
        # one trivial `run --cmd true` after the commit PASSed, and so did an explicitly 2020-dated record
        # sitting beside a 2099 one. Comparison is now `any()`: a single pre-commit record makes the
        # evidence predate the merge. The cost is that a lane re-running only the failing suite is refused
        # until it re-runs all of them — which is exactly what the code-4 remedy already instructs.
        predates = "1" if _any_ts and any(_t <= _c for _t in _any_ts) else "0"
        # ⛔ A FUTURE-DATED MERGING HEAD IS A DIFFERENT FAULT WITH A DIFFERENT REMEDY (fresh review, P2).
        # If the commit was stamped by a box whose clock is ahead of this one, an honest run at that head
        # is ALWAYS "older" than it, and the printed remedy (re-run the suites) can never converge — a
        # lane would spend its fix rounds on an action that cannot succeed. Detected here so the caller
        # can name it and give the remedy that actually works (re-push / wait for the skew).
        _n = datetime.datetime.now(datetime.timezone.utc)
        skew = "1" if _c > _n + datetime.timedelta(seconds=60) else "0"
    except Exception:
        predates = ""
        skew = ""
# ⛔ THE SEALED-REPORT STAMP IS EXTRACTED HERE, IN THE PASS THAT IS ALREADY PINNED (fresh review, MED).
# It used to be `sed -n … | tail -1` plus a `cut`: TWO PATH-RESOLVED PROGRAMS COMPUTING PART OF THE
# VERDICT, while the PATH disclosure scoped the open PATH residual to `git` alone and `_lrg_py` states
# that the inherited PATH is never consulted. The graded party owns PATH and runs the carrier itself, so a
# `sed` shim that exits 0 and prints nothing blanked the stamp, switched the sealed cross-check off, and
# let a two-field-edited `state.json` PASS (measured against the shipped script). Extraction now happens
# with the same absolute, `-I`-isolated interpreter as every other field; the only PATH-resolved program
# left in the decision path is `git` (the disclosed #3789 seam).
# THE STAMP LIVES IN THE REPORT HEADER, AND ONLY THE HEADER IS READ.
# ⛔ "THE LAST MATCH IS THE REAL ONE" WAS NEVER TRUE AND IS GONE (round-13 review, LOW). The writer renders
# the real stamp in the header and then renders `## Suites run` (suite commands AND log tails, verbatim)
# and `## Could not do` (lane-supplied `note --not-done` text, verbatim) BELOW it, so position cannot
# separate the writer stamp from lane-authored text: a body line can reproduce the shape. Counting over
# the whole document also refused an UNTAMPERED report whose own suite log tail contained the shape
# (measured, real writer: two matches, rc=2, remedy unsatisfiable). So the split is structural — the
# header ends at the first `## ` heading — and only header lines are counted.
# ⛔ AND A SPLIT BASE LINE IS REFUSED, because the writer renders `state["base_sha"]` VERBATIM, so a
# newline in it splits the anchored line and NOTHING matches: a forged `head_at_write` then sailed past
# the cross-check with the tool re-sealing its own digest honestly (measured, real writer: rc=4 STALE ->
# rc=0 PASS, at a cost of two JSON fields — cheaper than the disclosed stamp-rewrite residual). A header
# line that STARTS a Base stamp but is not the full shape is therefore tampering, not an older writer:
# an older writer has no Base line at all.
_sealed12 = ""
_sealed_n = 0
_seal_split = 0
try:
    with open(sys.argv[4], encoding="utf-8", errors="replace") as _rf:
        _rlines = _rf.read().splitlines()
except Exception:
    _rlines = []
_seal_pat = re.compile(r"^- \*\*Base:\*\* .*head at write:\*\* `([0-9a-f]{12})`.*$")
_hdr = []
_first_heading = -1
for _i, _rl in enumerate(_rlines):
    if _rl.startswith("## "):
        _first_heading = _i
        break
    _hdr.append(_rl)
for _rl in _hdr:
    _sm = _seal_pat.match(_rl)
    if _sm:
        _sealed_n += 1
        _sealed12 = _sm.group(1)
    elif _rl.startswith("- **Base:**"):
        _seal_split = 1
# ⛔ THE HEADER IS VALIDATED POSITIONALLY AGAINST WHAT `render()` EMITS, NOT BY SHAPE-MATCHING LINES
# (round-17 review, HIGH). Every earlier attempt asked "is there a Worktree line / a Branch line / a stamp
# here", and every one of them was defeated by injecting a line that satisfied the shape: `render()` renders
# `state["issue"]`, `["worktree"]` and `["branch"]` VERBATIM, and the writer supplies the Worktree line from a
# lane-writable value, so the lane could position its OWN block above the real one and fence the real one off
# (measured with the real writer through the `issue` slot: rc=0 PASS at evidence from a different tree, with
# no clock forgery and no markdown edit). Shapes cannot fix that, because the injected lines ARE exactly the
# shapes. POSITION can: the writer emits a FIXED layout — title, blank, three comment lines, blank,
# [`- **Issue:** #N`], `- **Worktree:**`, `- **Branch:**`, the Base stamp, `- **Started:**`, one verdict line,
# blank — and then the `## Files changed` heading. Any surplus line breaks the indices, and an injected block,
# fence or heading is surplus BY CONSTRUCTION. The Worktree/Branch lines are compared to the values in the
# writer state (string equality, never a character class: a branch may legally contain a backtick), and the
# Base line is matched by its rendered shape at that exact index.
_base_any = any(_rl.startswith("- **Base:**") for _rl in _rlines)
if _base_any:
    _bd = {}
    try:
        with open(sys.argv[2], encoding="utf-8", errors="replace") as _bf:
            _tmp = json.load(_bf)
        if isinstance(_tmp, dict):
            _bd = _tmp
    except Exception:
        _bd = {}
    _wt_v = _bd.get("worktree")
    _br_v = _bd.get("branch")
    _okblk = True
    if _first_heading < 0 or _rlines[_first_heading].rstrip() != "## Files changed":
        _okblk = False
    if len(_hdr) not in (12, 13):
        _okblk = False
    else:
        if not (_hdr[0].startswith("# WORKTREE-REPORT `") or _hdr[0].startswith("# WORKTREE-REPORT — `")):
            _okblk = False
        if _hdr[1] != "" or _hdr[5] != "":
            _okblk = False
        if not _hdr[2].startswith("<!-- #10220: generated by"):
            _okblk = False
        if not _hdr[3].startswith("     cited logs and are re-derived"):
            _okblk = False
        if not _hdr[4].endswith("instead. -->"):
            _okblk = False
        _i = 6
        if _hdr[_i].startswith("- **Issue:** #"):
            _i += 1
        _expect = ["- **Worktree:** `", "- **Branch:** `"]
        for _k in range(2):
            _line = _hdr[_i + _k] if _i + _k < len(_hdr) else ""
            _val = _wt_v if _k == 0 else _br_v
            _pfx = _expect[_k]
            if not _line.startswith(_pfx):
                _okblk = False
            elif isinstance(_val, str) and _line != (_pfx + _val + "`"):
                _okblk = False
        _base_line = _hdr[_i + 2] if _i + 2 < len(_hdr) else ""
        if not (_base_line.startswith("- **Base:** `")
                and "→ **head at write:** `" in _base_line
                and _base_line.endswith("`")):
            _okblk = False
        if not (_hdr[_i + 3] if _i + 3 < len(_hdr) else "").startswith("- **Started:** "):
            _okblk = False
        if not (_hdr[_i + 4] if _i + 4 < len(_hdr) else "").startswith("- **"):
            _okblk = False
        if (_hdr[_i + 5] if _i + 5 < len(_hdr) else "x") != "":
            _okblk = False
        if len(_hdr) != _i + 6:
            _okblk = False
    if not _okblk:
        _seal_split = 1
# ⛔ A HEADER TRUNCATED BEFORE THE BASE LINE IS THE SAME ATTACK AS A SPLIT BASE LINE (round-14 review, HIGH).
# The writer renders `state["issue"]`, `state["worktree"]` and `state["branch"]` VERBATIM on their own header
# lines ABOVE the Base line, so a newline plus `## ` inside ANY of them makes the FIRST heading land before
# the stamp: the header stops early, `_sealed_n` is 0, `_seal_split` never sees a Base line at all, and the
# cross-check — guarded on a non-empty stamp — is skipped while the tool re-seals its own digest. Measured
# with the real writer: one extra JSON field and a `write` turned a forged `head_at_write` from rc=4 STALE
# into rc=0 PASS, i.e. exactly the class the split-Base rule above closes, one field over.
# The invariant that covers all three fields at once: THIS REPORT FORMAT HAS ITS Base LINE IN THE HEADER.
# A document that carries a Base line at all, but whose first `## ` heading precedes it, has had its header
# cut short by a lane-writable value. A report with NO Base line anywhere is an older writer (the arm keeps
# abstaining, as it does for an absent stamp). A Base-shaped line in a suite log tail is BELOW the heading
# and does not move the real one, so the honest flow is untouched.
if _first_heading >= 0 and not any(_rl.startswith("- **Base:**") for _rl in _hdr):
    if any(_rl.startswith("- **Base:**") for _rl in _rlines[_first_heading:]):
        _seal_split = 1
# ⛔ NO RECORDED OUTPUT AT ALL IS NOT EVIDENCE (round-13 review, MED). The owner ruling this gate implements
# refuses a report that "claims tests without output", and `run --cmd true` records a suite with exit 0, no
# counts and a 0-byte log — which the consumer itself calls VALID, so the gate is the only refusal point
# (measured, real writer: the whole substitution was satisfiable with `init; run --cmd true; write`).
# A suite whose log is non-empty OR whose counts parsed is evidence; if NO recorded suite has either, the
# report claims tests without output.
_suite_ev = ""
try:
    with open(sys.argv[2], encoding="utf-8", errors="replace") as _sf:
        _st2 = json.load(_sf)
    _recs = _st2.get("suites") if isinstance(_st2, dict) else None
    if isinstance(_recs, list) and _recs:
        _bytes = 0
        _counted = 0
        _logged = 0
        for _rec in _recs:
            if not isinstance(_rec, dict):
                continue
            if isinstance(_rec.get("counts"), dict) and _rec.get("counts"):
                _counted += 1
            _lp = str(_rec.get("log") or "")
            # ⛔ A RECORD WITH NO `log` KEY IS NOT THE BUSINESS OF THIS ARM: the writer always records one, and a
            # state that omits it is what the consumer refuses on its own (`suite-log-missing`, so `ok:false`
            # -> INVALID before this arm is reached). Only the WRITER shape — a log path that EXISTS and is
            # EMPTY (`run --cmd true`) — is the "tests without output" hole, so only that shape is measured.
            if not _lp:
                continue
            _logged += 1
            # a path from the state is lane-written: absolute paths and `..` are never joined.
            if _lp.startswith("/") or ".." in _lp.split("/"):
                continue
            try:
                _bytes += os.path.getsize(os.path.join(sys.argv[5], _lp))
            except Exception:
                pass
        _suite_ev = "no-output" if (_logged > 0 and _bytes <= 0 and _counted == 0) else "ok"
except Exception:
    _suite_ev = ""
print("%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s" % (
    "1" if d.get("ok") is True else "0",
    "1" if d.get("head_moved_since_write") is True else "0",
    _flat(",".join(str(r) for r in rules))[:400],
    rec,
    _flat(d.get("head") or ""),
    predates,
    skew,
    state_ok,
    _sealed12,
    rec[:12],
    _sealed_n,
    _seal_split,
    _suite_ev,
))'
  if ! IFS='|' read -r ok stale rules rec_head live_head predates skew state_ok sealed12 rec12 sealed_n seal_split suite_ev <<< "$("$py" -I -c "$_LRG_JSON_PY" "$out" "$wt/.worktree-report/state.json" "$commit_iso" "$wt/WORKTREE-REPORT.md" "$wt" 2>/dev/null)"; then
    _lrg_emit 7 UNMEASURABLE "branch=$branch worktree=$wt tool=$tool reason=consumer-json-unusable check_rc=$rc head=$head"
    return 7
  fi
  # An empty parse is the SAME witness as a failed one: the python exits 0 having printed nothing only
  # when it could not read the object, and `read` on an empty string SUCCEEDS on bash 3.2.
  case "$ok" in 0|1) : ;; *) _lrg_emit 7 UNMEASURABLE "branch=$branch worktree=$wt tool=$tool reason=consumer-json-unusable check_rc=$rc head=$head"; return 7 ;; esac
  if [ "$ok" != "1" ]; then
    if [ "$rc" = "3" ]; then
      _lrg_emit 3 RED "branch=$branch worktree=$wt report=$wt/WORKTREE-REPORT.md reason=recorded-suites-did-not-pass rules=${rules:-none} stale=$stale head=$head"
      return 3
    fi
    _lrg_emit 2 INVALID "branch=$branch worktree=$wt report=$wt/WORKTREE-REPORT.md reason=evidence-invalid rules=${rules:-none} head=$head"
    return 2
  fi

  # ⛔ AN ABSENT WRITER STATE IS THE SAME FAILURE AS A CORRUPT ONE, AND THE SAME REFUSAL (round-6 review,
  # P1 — the round-5 fix left this asymmetric, which was indefensible). `rec_head` (the
  # `report-bound-to-another-head` arm) and `predates` (the laundering arm) are BOTH read out of this
  # file and both arms are `[ -n … ]`-guarded, so absence kills the identical two witnesses corruption
  # does — and `rm` is CHEAPER to type than a truncation, so leaving absence as a PASS made the deleted
  # witness the cheapest action available to the graded party while the damaged one was refused. The
  # lane owns this worktree; a witness it can remove is not a witness. Both are therefore 7
  # UNMEASURABLE, with the reason naming which, because the remedies differ.
  # ⛔ ORDERED AFTER the `ok != 1` refusal ON PURPOSE: a report whose suites DID NOT PASS must read RED /
  # INVALID — those are verdicts about the evidence and are the more actionable answer. Only once the
  # consumer has said "the evidence passes" does an unreadable head binding become the deciding fault.
  # ⛔ `reason=` IS THE LAST LANE-INFLUENCED FIELD ON THIS LINE, ON PURPOSE (round-22 review, P1). This
  # is the ONE emit that rendered a lane-chosen value AFTER the token (`state=$wt/…`, and `$wt` is a
  # worktree path the lane creates), and the carrier extracts the reason with `##*reason=` — the LAST
  # occurrence. So a worktree path containing `reason=no-interpreter-…` made the extracted token the PATH
  # TAIL: it matched no arm, fell to the box arm, and a lane-owned `writer-state-absent` refused with 14 /
  # no round / "nothing you can push" instead of 10 / round 1. Measured end-to-end: identical fault, only
  # the worktree path differing → 14/round-0 vs 10/round-1. The path is still named (twice), it just
  # precedes the token now.
  if [ "$state_ok" != "ok" ]; then
    _lrg_emit 7 UNMEASURABLE "branch=$branch worktree=$wt state=$wt/.worktree-report/state.json tool=$tool head=$head reason=writer-state-$state_ok"
    return 7
  fi

  # ⛔ THE ROW THE WRITER DELIBERATELY LEAVES TO ITS CONSUMER. `check` exits 0 here.
  if [ "$stale" = "1" ]; then
    _lrg_emit 4 STALE "branch=$branch worktree=$wt report=$wt/WORKTREE-REPORT.md reason=head-moved-since-write report_head=${rec_head:-unknown} merging_head=$head"
    return 4
  fi
  # ⛔ AND THE DIRECTION `head_moved_since_write` CANNOT SEE (fresh review, P1 — this is the finding
  # that made the gate real). The writer compares the report against ITS OWN worktree. If the BRANCH
  # advanced from somewhere else — a `fix-<PR>` or `adopt-fix.sh` push, or another box — the lane
  # worktree stays at the older commit, `head_moved_since_write` stays FALSE, and the gate would PASS a
  # report describing a tree one commit behind the head being merged: exactly the false green this file
  # exists to refuse (measured twice on 2026-11-07). So the head is BOUND, in both directions:
  #   * `rec_head` (the head the evidence was written at) must BE the head being merged;
  #   * `live_head` (where the worktree actually is) must be too, or the evidence describes a tree that
  #     is not the one on the branch.
  # ⛔ THE STATE'S HEAD MUST AGREE WITH THE SEALED REPORT'S HEAD (round-8 review, P1). Everything above
  # reads `head_at_write` from `state.json` — which carries NO digest; only `WORKTREE-REPORT.md` is
  # sealed. So the "witness a re-render cannot move" was protected against RE-RENDERING but not against a
  # two-field EDIT: changing `head_at_write` and the newest `finished_at` turned a measured
  # `VERDICT=STALE rc=4` into `VERDICT=PASS rc=0` with the consumer still reporting VALID, while the
  # sealed report went on naming the OLD head — a self-contradicting artifact, which this file's own
  # header says must not be mergeable. The rendered report stamps the same fact (`- **head at write:**`
  # `<12 hex>`), so the two halves are cross-checked here. An ABSENT stamp on either side does not
  # refuse (an older writer, and "an empty witness never refuses" is this file's existing rule); a
  # DISAGREEMENT is a falsified state and refuses.
  # ⛔ THE STAMP IS READ BY ITS FULL RENDERED SHAPE, NOT BY `head -1` OVER ANY OCCURRENCE (round-10
  # review, P1). `head -1` matched the FIRST `head at write:` anywhere in the file, and the writer renders
  # the lane-owned `state["worktree"]` value VERBATIM in its own line ABOVE the real stamp — so a lane
  # could have the tool itself print a forged `head at write: <target12>` and the cross-check would read
  # that one while the real stamp kept naming the old head (measured: PASS on a report whose sealed line
  # still said the previous commit). Anchoring on the rendered line `- **Base:** \`…\` → **head at
  # write:** \`<12hex>\`` makes the position unambiguous. \u26d4 THE DIGEST IS NOT A SEAL AGAINST THE GRADED
  # PARTY EITHER (unkeyed sha256 stored in the same file): this cross-check is a SPEED BUMP that costs two
  # lane-owned files instead of one, not tamper-proofing — see the disclosure above, which says so.
  # ⛔ POSITION IS NOT THE CONTROL, AND THE OLD COMMENT THAT SAID IT WAS IS FALSE (round-13 review, LOW).
  # The writer renders the real stamp in the Base line and then renders `## Suites run` (suite commands,
  # verbatim) and `## Could not do` (lane-supplied `note --not-done` text, verbatim) BELOW it — so a lane
  # can append a line that reproduces the anchored shape and, with the unkeyed digest re-sealed, make a
  # stale real stamp agree with a forged `state.json`. "The LAST match is the real one" was never true of
  # the writer's output. The control is COUNT, not order: an honest report carries EXACTLY ONE stamp, and
  # a second one is refused as a self-contradicting artifact (INVALID) instead of being resolved by
  # position. ⛔ WHAT REMAINS IS THE DIGEST'S LIMIT, NOT THIS ARM'S: the sha256 is unkeyed and stored in
  # the same file, so a caller who rewrites the one real stamp line (or hand-writes the whole report) is
  # at the same cost as forging two — the disclosure above says so, and this arm is a speed bump, not
  # tamper-proofing. Both the stamp and the state head's 12-hex prefix come out of the pinned interpreter
  # pass (round-12 review, MED: `sed`/`tail`/`cut` were PATH-resolved programs computing this verdict).
  # ⛔ A COUNT OVER THE HEADER, NOT OVER THE DOCUMENT (round-13 review, LOW): a body stamp is lane-authored
  # prose (a suite command, a log tail, a `note --not-done` item) and refusing it made an UNTAMPERED report
  # INVALID with a remedy that re-runs the same suite and reproduces the duplicate. Only a SECOND header
  # stamp is a self-contradicting artifact — that is the round-10/11 injection through `state["worktree"]`.
  if [ "${sealed_n:-0}" -gt 1 ] 2>/dev/null; then
    _lrg_emit 2 INVALID "branch=$branch worktree=$wt report=$wt/WORKTREE-REPORT.md reason=report-carries-more-than-one-head-at-write-stamp stamps=$sealed_n head=$head"
    return 2
  fi
  # ⛔ A HEADER BASE LINE THAT CANNOT CARRY ITS STAMP IS TAMPERING, NOT AN OLDER WRITER (round-13 review,
  # HIGH). The writer interpolates `state["base_sha"]` VERBATIM, so a newline in it splits the anchored
  # line and NOTHING matches — the cross-check is skipped, the tool re-seals its own digest honestly, and a
  # forged `head_at_write` PASSes (measured with the real writer: rc=4 STALE -> rc=0 PASS for two JSON
  # fields). `0` stamps WITH a Base line present is that split; `0` stamps with NO Base line is an older
  # writer and keeps abstaining from this arm, as before.
  if [ "${seal_split:-0}" = "1" ]; then
    _lrg_emit 2 INVALID "branch=$branch worktree=$wt report=$wt/WORKTREE-REPORT.md reason=report-header-base-line-was-split-or-malformed head=$head"
    return 2
  fi
  # ⛔ A REPORT WHOSE RECORDED SUITES PRODUCED NO OUTPUT AT ALL IS "tests without output" — the exact shape
  # the owner ruling says the verifier must refuse (round-13 review, MED). `init; run --cmd true; write`
  # records exit 0, no counts and a 0-byte log, and the consumer calls that VALID, so the gate is the only
  # refusal point. One recorded suite with a non-empty log OR parsed counts is enough: a silent lint run
  # beside a real one is not refused.
  if [ "$suite_ev" = "no-output" ]; then
    _lrg_emit 2 INVALID "branch=$branch worktree=$wt report=$wt/WORKTREE-REPORT.md reason=recorded-suites-produced-no-output head=$head"
    return 2
  fi
  if [ -n "$sealed12" ] && [ -n "$rec12" ] && [ "$rec12" != "$sealed12" ]; then
    _lrg_emit 4 STALE "branch=$branch worktree=$wt report=$wt/WORKTREE-REPORT.md reason=state-disagrees-with-the-sealed-report sealed_head=$sealed12 state_head_at_write=$rec_head merging_head=$head"
    return 4
  fi
  if [ -n "$rec_head" ] && [ "$rec_head" != "$head" ]; then
    _lrg_emit 4 STALE "branch=$branch worktree=$wt report=$wt/WORKTREE-REPORT.md reason=report-bound-to-another-head report_head=$rec_head merging_head=$head"
    return 4
  fi
  if [ -n "$live_head" ] && [ "$live_head" != "$head" ]; then
    _lrg_emit 4 STALE "branch=$branch worktree=$wt report=$wt/WORKTREE-REPORT.md reason=worktree-is-not-at-the-merging-head worktree_head=$live_head merging_head=$head"
    return 4
  fi
  # ⛔ THE LAUNDERING ARM (fresh review, P0). `head_at_write` is re-stamped by a bare re-render, so the
  # two arms above can both be satisfied by a report whose SUITES ran at an older commit. The newest
  # suite's `finished_at` is written only by `run` and is never touched by a render, so evidence that
  # finished before the merging commit existed cannot describe it.
  # ⛔ THE REFUSAL LINE MUST NOT NAME TWO IDENTICAL SHAS (round-19 review, P2; round-20 review, P2).
  # This arm fires when a suite's `finished_at` is `<=` the merging commit's date, and that includes the
  # SAME-HEAD case — a report correctly bound to the merging head whose suite finished in the commit's
  # OWN second (both clocks are second-resolution). At this point `rec_head` is always non-empty and
  # equal to `head` (the `report-bound-to-another-head` arm above returns first, and an `ok` state
  # requires a recorded head), so `report_head=X merging_head=X` printed the SAME 40-hex twice — which
  # reads as a contradiction and names nothing: measured end-to-end with the real writer,
  # `commit=…T14:06:04+00:00 finished=…T14:06:04Z -> rc=4` with both fields equal, and the code-4 remedy
  # then sent the lane hunting for a push that never happened. The head pair is therefore printed ONLY
  # on the defensive branch where it genuinely differs; both live arms name `head` + `head_date`.
  # ⛔ THE SKEW ARM IS PART OF THIS RULE TOO: it emitted the identical pair until round 20.
  if [ "$predates" = "1" ]; then
    if [ "$skew" = "1" ]; then
      _lrg_emit 4 STALE "branch=$branch worktree=$wt report=$wt/WORKTREE-REPORT.md reason=merging-head-is-dated-ahead-of-this-box head=$head head_date=$commit_iso"
      return 4
    fi
    if [ -n "$rec_head" ] && [ "$rec_head" != "$head" ]; then
      # DEFENSIVE, and stated as such rather than implied reachable: no arm above can currently leave a
      # differing `rec_head` in place. Kept total so a future reordering cannot silently print one sha
      # twice again (the round-19 defect this arm exists for).
      _lrg_emit 4 STALE "branch=$branch worktree=$wt report=$wt/WORKTREE-REPORT.md reason=evidence-not-produced-after-the-merging-commit report_head=$rec_head merging_head=$head head_date=$commit_iso"
    else
      _lrg_emit 4 STALE "branch=$branch worktree=$wt report=$wt/WORKTREE-REPORT.md reason=evidence-not-produced-after-the-merging-commit head=$head head_date=$commit_iso"
    fi
    return 4
  fi

  # ⛔ THE VERIFIER IS NAMED ON THE PASS LINE (fresh review, P2): without it the merge log records
  # "verified" with no provenance, so a consumer drawn from the wrong tree is invisible even after it
  # has made a difference.
  _lrg_emit 0 PASS "branch=$branch worktree=$wt report=$wt/WORKTREE-REPORT.md head=$head report_head=${rec_head:-unknown} state=${state_ok:-absent} tool=$tool"
  return 0
}

# lane_report_remedy <code> — the ONE place the fix is spelled, so both carriers give the lane the
# same instruction instead of two paraphrases of it.
# ⛔ THE REMEDY FOR A STALE REPORT IS A RE-RUN, NOT A REWRITE. `write` only re-renders the report from
# the state that already exists; if the head moved, the suites did not run against the tree being
# merged and re-rendering it would launder old evidence into a new head — which is precisely the
# false-green this gate exists to refuse (measured 2026-11-07: two rounds were spent on reports one
# commit behind their head, and both `check` calls exited 0).
lane_report_remedy() {
  case "${1:-}" in
    1) printf '  The lane wrote no report. Write one BEFORE the next merge attempt: %s\n' \
         'python3 tools/worktree_report.py init --issue <N>, then run every suite through it (run --cmd <cmd>), then write.' ;;
    2) printf '  The evidence in the report does not hold up (a recorded log is missing, its hash does not\n  match, or a promised section is absent). Re-run the affected suite through the tool so the record\n  matches its log.\n  Three reasons cannot be fixed by re-running the SAME suite, because the report itself is malformed:\n  • `reason=recorded-suites-produced-no-output` — the report claims suites whose logs are empty and\n    whose counts did not parse (`run --cmd true` is the minimal case). Run a suite that produces output.\n  • `reason=report-carries-more-than-one-head-at-write-stamp` — two header stamps. Do NOT hand-edit the\n    markdown: rewrite the report from the writer (`run` each suite again, then `write`).\n  • `reason=report-header-base-line-was-split-or-malformed` — the seal is not where the writer puts it:\n    a lane-writable value split the Base line, or ended the header before it, or left a second Base line\n    outside a code fence. Same remedy: rewrite it from the writer, do not patch the markdown.\n' ;;
    3) printf '  The report RECORDS A FAILING SUITE. A green report is a precondition of merge: fix the failure and\n  re-run that suite through the tool (a lane whose own evidence says red may not merge).\n' ;;
    4) printf '  The report does not describe the tree being merged (it was written at another head, the\n  lane worktree is not at the head on the branch, or its evidence finished before that head was\n  created — a push from another worktree/box moves the branch and leaves your worktree behind).\n  Re-run the suites AT THE HEAD ON THE BRANCH through the tool (do NOT just re-render):\n     git -C <your worktree> status ; git log --oneline -1   # confirm you are at the PR head\n     python3 tools/worktree_report.py run --cmd <the exact command>   # for each suite\n  ⛔ `write`, `note` and a plain `init` re-render the report AND re-stamp the recorded head WITHOUT\n  re-running anything, so they turn a stale report into a green-looking one. Only `run` produces\n  evidence for the head you are merging.\n  ⛔ If the reason is `merging-head-is-dated-ahead-of-this-box`, RE-RUNNING WILL NOT HELP: the head\n  was committed on a box whose clock is ahead, so no run here can ever be newer than it. Re-push the\n  head from a correctly-clocked box, or wait for the skew to pass.\n  ⛔ If the reason is `evidence-not-produced-after-the-merging-commit` AND the line carries no
  `report_head=`, the report IS bound to this head and only the TIMESTAMPS are ambiguous: a suite
  finished in the same second as the merging commit (both clocks are second-resolution), so the
  witness cannot tell an honest run from a laundered one. Nothing was pushed and no other box is
  involved — just re-run the suites. (⛔ KEYED ON THE REASON, NOT ON THE FIELD SHAPE: removing
  `report_head=` from the clock-skew arm made the two arms shape-identical, so a shape test here told
  a clock-skewed lane to do the one thing that can never converge. round-21 review.)\n' ;;
    7) printf '  The report exists but could not be VERIFIED. Two distinct causes, with different remedies:\n     • no interpreter, or the consumer failed / printed no parseable JSON — repair the consumer, then re-run;\n     • the writer state is missing or damaged (`reason=writer-state-absent|corrupt`) — the head binding\n       lives there, so the report cannot be tied to the head being merged. Do NOT hand-edit or delete\n       it: re-run the suites through the tool (`python3 tools/worktree_report.py run --cmd <cmd>`),\n       which rewrites the state. A state file you removed is a witness you removed.\n  An unreadable verification is not a pass.\n  ⛔ `lane-merge.sh` SPLITS rc=7 BY REASON, AND THE LINE ABOVE SAYS WHICH ARM YOU ARE IN: the reasons a
  lane action clears (`writer-state-absent|corrupt|missing-witness`, `worktree-registered-but-unreadable`,
  or a report held in a worktree that is not registered/checked out at the merging head) spend a normal
  fix round; the reasons NOTHING a lane pushes can change (`no-interpreter-at-or-above-python-3.12`, the
  attribution sibling, `report-present-but-repo-ships-no-consumer`, `consumer-produced-no-json`,
  `consumer-json-unusable`, or a caller fault such as a missing repo/branch/head argument) hand off with
  NO round spent on this run — because burning the cap on pushes that cannot converge would leave the
  lane no round once the box WAS repaired. Read `reason=` on the verdict line before acting.\n' ;;
    *) : ;;
  esac
}

# Run as a command (a lane, an operator, a census): `lane-report-gate.sh --check <repo> <branch> <head>`
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  case "${1:-}" in
    --check)
      shift
      lane_report_gate "${1:-}" "${2:-}" "${3:-}"
      exit $?
      ;;
    --remedy)
      lane_report_remedy "${2:-}"
      exit 0
      ;;
    *)
      cat >&2 <<'EOF'
usage: lane-report-gate.sh --check <repo-path> <branch> <head>
       lane-report-gate.sh --remedy <exit-code>
       . lane-report-gate.sh ; lane_report_gate <repo-path> <branch> <head>

Exit: 0 PASS · 1 ABSENT · 2 INVALID · 3 RED · 4 STALE · 5 NO-CONSUMER · 6 NO-WORKTREE · 7 UNMEASURABLE
      Only 0 is a pass; 5 and 6 are ABSTENTIONS (the gate did not run here) and are never green.
EOF
      exit 64
      ;;
  esac
fi
