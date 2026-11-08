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
# ── THE DECISION TABLE (the code IS the contract; `lane-report-gate.test.sh` pins every row) ─────
#   0  PASS            report present, evidence valid, every recorded suite exit 0, head-bound
#   1  ABSENT          a lane worktree for this branch exists and has NO report — silence
#   2  INVALID         the evidence does not hold up (broken log hash, missing section, malformed state)
#   3  RED             valid evidence that records a NON-ZERO suite exit — a lane saying its own tests
#                      failed is not a pass
#   4  STALE           the report was written at a different head than the one being merged
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
# SEAMS (tests): LANE_REPORT_GATE_TOOL=<path> (consumer to use instead of the repo's own),
# LANE_REPORT_GATE_PY=<interpreter>.
set -u

# _lrg_emit <code> <verdict> <key=value>… — one machine-readable line on stdout, then the code.
_lrg_emit() {
  local code="$1" verdict="$2"; shift 2
  printf 'lane-report: VERDICT=%s %s\n' "$verdict" "$*"
  return "$code"
}

# _lrg_py — the interpreter that runs the consumer. The consumer is stdlib-only by design (it must run
# on a cell with no venv), so `python3` is the first choice and `python` the fallback.
_lrg_py() {
  local c
  for c in "${LANE_REPORT_GATE_PY:-}" python3 python; do
    [ -n "$c" ] || continue
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
  if [ -n "${LANE_REPORT_GATE_TOOL:-}" ]; then
    tool="$LANE_REPORT_GATE_TOOL"
  else
    tool=""
    for _cand in "$wt/tools/worktree_report.py" "$repo/tools/worktree_report.py"; do
      [ -f "$_cand" ] && [ -s "$_cand" ] && { tool="$_cand"; break; }
    done
  fi
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

  # One python pass, because a hand-rolled grep over JSON is how a gate starts reading a nested key as
  # a top-level one. Prints `<ok>|<stale>|<rules>|<recorded head>`; empty fields are meaningful.
  # ⛔ `-c`, NOT A NESTED HEREDOC: a heredoc body is literal text, so a `<<PY` inside a `<<EOF` body
  # never runs as a program — it is the outer heredoc's DATA, the reader then gets garbage and this gate
  # would abstain on every lane that has a perfectly good report (found before it shipped).
  _LRG_JSON_PY='import json, sys
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
try:
    with open(sys.argv[2], encoding="utf-8", errors="replace") as fh:
        st = json.load(fh)
    if isinstance(st, dict):
        rec = st.get("head_at_write") or ""
except Exception:
    rec = ""
print("%s|%s|%s|%s|%s" % (
    "1" if d.get("ok") is True else "0",
    "1" if d.get("head_moved_since_write") is True else "0",
    ",".join(str(r) for r in rules)[:400],
    rec,
    d.get("head") or "",
))'
  if ! IFS='|' read -r ok stale rules rec_head live_head <<< "$("$py" -c "$_LRG_JSON_PY" "$out" "$wt/.worktree-report/state.json" 2>/dev/null)"; then
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

  _lrg_emit 0 PASS "branch=$branch worktree=$wt report=$wt/WORKTREE-REPORT.md head=$head report_head=${rec_head:-$head}"
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
    4) printf '  The report does not describe the tree being merged (it was written at another head, or the\n  lane worktree is not at the head on the branch — a push from another worktree/box moves the branch\n  and leaves your worktree behind). Re-run the suites AT THE HEAD ON THE BRANCH through the tool\n  (do NOT just re-render):\n     git -C <your worktree> status ; git log --oneline -1   # confirm you are at the PR head\n     python3 tools/worktree_report.py run --cmd <the exact command>   # for each suite\n' ;;
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
