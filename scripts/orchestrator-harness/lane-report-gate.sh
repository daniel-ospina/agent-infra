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
_lrg_py() {
  local c
  for c in python3 python; do
    command -v "$c" >/dev/null 2>&1 && { printf '%s' "$c"; return 0; }
  done
  return 1
}

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

# lane_report_gate <repo-path> <branch> <head> — the decision table above.
lane_report_gate() {
  local repo="${1:-}" branch="${2:-}" head="${3:-}" wt="" tool="" py="" out="" rc=0
  local ok="" stale="" rules="" rec_head="" live_head=""

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
    _lrg_emit 6 NO-WORKTREE "branch=$branch reason=no-worktree-for-branch-on-this-box head=$head"
    return 6
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

  py="$(_lrg_py)" || { _lrg_emit 7 UNMEASURABLE "branch=$branch worktree=$wt tool=$tool reason=no-python-interpreter head=$head"; return 7; }

  out="$("$py" "$tool" check --json --worktree "$wt" 2>/dev/null)"; rc=$?
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
  _LRG_JSON_PY='import datetime, json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    sys.exit(3)
if not isinstance(d, dict):
    sys.exit(3)
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
try:
    with open(sys.argv[2], encoding="utf-8", errors="replace") as fh:
        st = json.load(fh)
    if isinstance(st, dict):
        rec = st.get("head_at_write") or ""
        _suites = st.get("suites")
        if isinstance(_suites, list):
            for _s in _suites:
                _ts = _s.get("finished_at") if isinstance(_s, dict) else None
                if not _ts:
                    continue
                try:
                    _t = datetime.datetime.fromisoformat(str(_ts).replace("Z", "+00:00"))
                except Exception:
                    continue
                if newest is None or _t > newest:
                    newest = _t
except Exception:
    rec = ""
# ⛔ THE WITNESS A RE-RENDER CANNOT MOVE (fresh review, P0). `write_report` re-stamps `head_at_write`
# on every `write`/`note`/idempotent `init`, so a lane that runs its suites at A, commits B, and then
# runs any of those three commands presents `head_at_write = B` with evidence taken at A — and both
# of the gate head witnesses then agree with the merge. The newest suite `finished_at` is NOT
# re-stamped by a render, so "the newest suite finished BEFORE the merging commit was created" is the
# one consumer-side witness that survives. ⛔ IT IS A SINGLE-CLOCK COMPARISON ONLY WHEN THE HEAD WAS
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
        predates = "1" if newest <= _c else "0"
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
print("%s|%s|%s|%s|%s|%s|%s" % (
    "1" if d.get("ok") is True else "0",
    "1" if d.get("head_moved_since_write") is True else "0",
    ",".join(str(r) for r in rules)[:400],
    rec,
    d.get("head") or "",
    predates,
    skew,
))'
  if ! IFS='|' read -r ok stale rules rec_head live_head predates skew <<< "$("$py" -c "$_LRG_JSON_PY" "$out" "$wt/.worktree-report/state.json" "$commit_iso" 2>/dev/null)"; then
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
  if [ "$predates" = "1" ]; then
    if [ "$skew" = "1" ]; then
      _lrg_emit 4 STALE "branch=$branch worktree=$wt report=$wt/WORKTREE-REPORT.md reason=merging-head-is-dated-ahead-of-this-box report_head=${rec_head:-$head} merging_head=$head head_date=$commit_iso"
      return 4
    fi
    _lrg_emit 4 STALE "branch=$branch worktree=$wt report=$wt/WORKTREE-REPORT.md reason=evidence-not-produced-after-the-merging-commit report_head=${rec_head:-$head} merging_head=$head"
    return 4
  fi

  # ⛔ THE VERIFIER IS NAMED ON THE PASS LINE (fresh review, P2): without it the merge log records
  # "verified" with no provenance, so a consumer drawn from the wrong tree is invisible even after it
  # has made a difference.
  _lrg_emit 0 PASS "branch=$branch worktree=$wt report=$wt/WORKTREE-REPORT.md head=$head report_head=${rec_head:-$head} tool=$tool"
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
    2) printf '  The evidence in the report does not hold up (a recorded log is missing, its hash does not\n  match, or a promised section is absent). Re-run the affected suite through the tool so the record\n  matches its log.\n' ;;
    3) printf '  The report RECORDS A FAILING SUITE. A green report is a precondition of merge: fix the failure and\n  re-run that suite through the tool (a lane whose own evidence says red may not merge).\n' ;;
    4) printf '  The report does not describe the tree being merged (it was written at another head, the\n  lane worktree is not at the head on the branch, or its evidence finished before that head was\n  created — a push from another worktree/box moves the branch and leaves your worktree behind).\n  Re-run the suites AT THE HEAD ON THE BRANCH through the tool (do NOT just re-render):\n     git -C <your worktree> status ; git log --oneline -1   # confirm you are at the PR head\n     python3 tools/worktree_report.py run --cmd <the exact command>   # for each suite\n  ⛔ `write`, `note` and a plain `init` re-render the report AND re-stamp the recorded head WITHOUT\n  re-running anything, so they turn a stale report into a green-looking one. Only `run` produces\n  evidence for the head you are merging.\n  ⛔ If the reason is `merging-head-is-dated-ahead-of-this-box`, RE-RUNNING WILL NOT HELP: the head\n  was committed on a box whose clock is ahead, so no run here can ever be newer than it. Re-push the\n  head from a correctly-clocked box, or wait for the skew to pass.\n' ;;
    7) printf '  The report exists but could not be VERIFIED (no interpreter, or the consumer failed / printed no\n  parseable JSON). An unreadable verification is not a pass: repair the consumer, then re-run.\n' ;;
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
