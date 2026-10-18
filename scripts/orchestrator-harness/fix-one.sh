#!/usr/bin/env bash
# fix-one.sh <repo-path> <owner/repo> <pr> <branch>
# fix-one.sh --argv <file>            (4 lines: repo, owner/repo, pr, branch)
# Runs a fixer on the PR's worktree to address the reviewer's findings, pushes, then re-runs the merge chain.
set -u
if [ "${1:-}" = "--argv" ]; then
  ARGV="${2:-}"
  [ -f "$ARGV" ] || { echo "[fix] missing argv file: $ARGV" >&2; exit 1; }
  { read -r REPO; read -r OR; read -r PR; read -r BR; } < "$ARGV"
  rm -f "$ARGV"
  # Only a CONTROLLER dispatch books an attempt in fixcount-<PR>. See the refund in the load-refusal
  # path below: a manual run must not decrement a counter it never incremented.
  CTRL=1
else
  REPO="$1"; OR="$2"; PR="$3"; BR="$4"; CTRL=0
fi
case "${PR:-}" in ''|*[!0-9]*) echo "[fix] refusing non-numeric PR: ${PR:-<empty>}" >&2; exit 1 ;; esac
# Guard-before-use for env tunables (same P1 class as merge-one.sh): FIX_TIMEOUT feeds ARITHMETIC
# below to derive the lease, and on /bin/bash 3.2.57 a failed arithmetic assignment aborts the rest
# of the enclosing `if` body with status 0 — silently disabling the claim.
# ⛔ REJECT LEADING ZEROS (P2, second review round, 2026-10-14): `''|*[!0-9]*` ACCEPTED `08`, so
# `FIX_LEASE=$(( 08 + 1200 ))` still reached the arithmetic and aborted the claim block with status
# 0. `$(( ))` parses base 0 (leading 0 = octal) and `08`/`09` are not octal. Accept only `0` or
# `[1-9][0-9]*`.
is_num() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; 0) return 0 ;; 0*) return 1 ;; *) return 0 ;; esac; }
# ⛔ MAGNITUDE, NOT JUST SHAPE (P2, third review round, 2026-10-14). `is_num` is UNBOUNDED, so it
# accepted `9223372036854775807`; `FIX_LEASE=$(( FIX_TIMEOUT + 1200 ))` then wrapped NEGATIVE, the
# lease failed to parse (`_lease_of`'s `[0-9]*` cannot match a minus sign), and an unparseable lease
# is read as LIVE — so the head was frozen across ALL boxes and `claim_prune` could never reap it.
# FAIL-CLOSED, the opposite of the design's fail-open policy. `is_limit` (is_num AND at most 9
# digits) is the predicate orch-loop.sh applies to every other tunable for exactly this reason.
is_limit() { is_num "${1:-}" && [ "${#1}" -le 9 ]; }
KIND=fixer; TAG="$PR"
O="${O:-$HOME/orchestrator}"; mkdir -p "$O/logs" "$O/state"
L="$O/logs/fix-$PR"
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
# ⛔ THE gh SHIM MUST STAY FIRST (#1988). The line above prepends the tool dirs, so a REAL gh in
# either of them outranks the seeded `$O/gh-rest` (Mac REST adapter) / `$O/gh-limit` (cell
# serialiser) — and a shim that is never resolved is an INERT layer: it reports protection and
# provides none. Re-assert both here, adapter last so `$O/gh-rest` (which itself calls the same
# helper) wins where it exists. Guarded by `-d`, so a box that ships neither is unchanged.
if [ -d "$O/gh-limit" ]; then PATH="$O/gh-limit:$PATH"; fi
if [ -d "$O/gh-rest" ]; then PATH="$O/gh-rest:$PATH"; fi
# The wall-clock limit AND the load gate both live in the shared helper, so this script has no
# `pi` invocation of its own to forget to gate (agent-infra#1720). NB: L above is a LOG PATH, not a
# load reading — the gate takes its reading as an argument for exactly that reason.
# Fail LOUD if the helper is missing: an unsourced helper leaves `run_agent` undefined, and that must
# never degrade into "the fixer ran" — see README §9 on syncing $O.
# ⛔ SOURCED AFTER THE PATH EXPORT: spawn-gate.sh derives `_NCPU` at SOURCE time, so sourcing it
# under the pre-export PATH pins _NCPU=4 / MAX_LOAD=40 for every cell (the #1702 failure).
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF/spawn-gate.sh" || { echo "[fix $PR] FATAL: $SELF/spawn-gate.sh missing — refusing to run an ungated fixer" >&2; exit 78; }
export AGENT_SKIP_REVIEW_GATE=1 ELDATO_SKIP_VGATE=1 AGENT_ALLOW_MAIN_EDITS=1 ELDATO_ALLOW_MAIN_EDITS=1
export PI_MCP_SERVERS=none   # headless fixer uses no MCP servers — saves ~25 processes/run
export PI_SKIP_VERSION_CHECK=1 SKILL_ENFORCER_DISABLED=1 LOOP_ENFORCER_DISABLED=1 SLACK_BRIDGE_DISABLE=1 VISION_INTERCEPTOR_DISABLED=1
cd "$REPO" || exit 1

# locate the branch's worktree
WT="$(git worktree list --porcelain | awk -v b="refs/heads/$BR" 'BEGIN{p=""} /^worktree /{p=$2} /^branch /{if($2==b) print p}')"
echo "[fix $PR] start $(date) worktree=$WT branch=$BR" > "$L.log"
[ -z "$WT" ] && {
  # Foreign (other-machine) branch: materialise a local worktree so the fixer has somewhere to work.
  if git rev-parse --verify -q "refs/heads/$BR" >/dev/null; then
    git worktree add ".worktrees/fix-$PR" "$BR" >> "$L.log" 2>&1
  else
    git fetch origin "$BR" --quiet >> "$L.log" 2>&1
    git worktree add ".worktrees/fix-$PR" -b "$BR" "origin/$BR" >> "$L.log" 2>&1
  fi
  WT="$(git worktree list --porcelain | awk -v b="refs/heads/$BR" 'BEGIN{p=""} /^worktree /{p=$2} /^branch /{if($2==b) print p}')"
  [ -z "$WT" ] && { echo "[fix $PR] ABORT: could not materialise a worktree for $BR" >> "$L.log"; exit 1; }
  echo "[fix $PR] materialised worktree=$WT" >> "$L.log"
}

# ── cross-box claim for the FIXER (P3.3, 2026-10-14 adversarial review) ───────
# merge-one.sh claims before reviewing, but fix-one.sh ran the fixer FIRST and only then called
# merge-one.sh (the sole claim_acquire caller), so two boxes could each spawn a fixer for the same
# PR/head. Same key and lease shape as merge-one.sh's — the claim is on the PR's CURRENT head, so a
# fixer and a reviewer never race each other for the same content version.
HEAD="$(gh pr view "$PR" --repo "$OR" --json headRefOid --jq .headRefOid 2>/dev/null)"
CROSS_OWN=""; CROSS_RC=0
release_fix_claim() { # bounded, like merge-one.sh's — it runs on the EXIT path
  # ⛔ THE 20s BOUND IS A DELIBERATE TRADE (P3, second review round, 2026-10-14): it CAN kill a
  # release that would eventually have succeeded — a `git push` slower than 20s is TERM'd, the
  # fenced push leaves the ref intact, and every box then refuses that head until the lease expires
  # (FIX_TIMEOUT+1200, up to ~1 h). Accepted because an UNBOUNDED exit path is strictly worse: it
  # holds the process open with the local lock already dropped, so the controller can spawn a second
  # fixer for the same head. DO NOT remove the bound; move the release OFF the exit path instead.
  local p w rc
  [ -n "${CROSS_OWN:-}" ] || return 1
  claim_release "$REPO" "$PR" "$HEAD" "$CROSS_OWN" >/dev/null 2>&1 &
  p=$!
  ( sleep 20; kill -TERM "$p" 2>/dev/null; sleep 5; kill -KILL "$p" 2>/dev/null ) >/dev/null 2>&1 &
  w=$!
  wait "$p" 2>/dev/null; rc=$?
  kill "$w" 2>/dev/null
  return "$rc"
}
trap 'release_fix_claim' EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
if [ -n "${HEAD:-}" ] && [ -f "$O/claims.sh" ]; then
  # shellcheck source=/dev/null
  . "$O/claims.sh"
  if ! is_limit "${FIX_TIMEOUT:-2400}"; then
    echo "[fix $PR] FIX_TIMEOUT='${FIX_TIMEOUT:-}' is not an integer in range (at most 9 digits) — using 2400 (the cross-box lease needs a number that cannot overflow)" >> "$L.log"
    FIX_TIMEOUT=2400
  fi
  # Overflow-safe by construction: the guard above leaves FIX_TIMEOUT <= 999999999, so this sum is
  # < 2**31. claims.sh clamps the ttl a second time at its own arithmetic site.
  FIX_LEASE=$(( ${FIX_TIMEOUT:-2400} + 1200 ))
  claim_acquire "$REPO" "$PR" "$HEAD" "$FIX_LEASE" >/dev/null
  CROSS_RC=$?
  case "$CROSS_RC" in
    0) CROSS_OWN="$CLAIM_COMMIT"
       echo "[fix $PR] cross-box fixer claim: $CLAIM_RESULT" >> "$L.log" ;;
    1) echo "[fix $PR] cross-box fixer claim REFUSED: $CLAIM_RESULT — another box is already fixing head $HEAD; recording a bail marker and exiting" >> "$L.log"
       # ⛔ BAIL MARKER (P2, second review round, 2026-10-14). The controller books the attempt
       # (fixcount+1) and DELETES the reviewer's findings marker at SPAWN, so this refusal — which
       # did no work at all — used to burn one of MAX_FIX_TRIES and leave the findings unrecorded.
       # Three refusals PARK the PR as needs-a-human although no fixer ever ran. orch-loop.sh reads
       # this marker and refunds both.
       : > "$O/state/fixbail-$PR-$HEAD"
       exit 0 ;;
    *) echo "[fix $PR] cross-box fixer claim UNAVAILABLE (rc=$CROSS_RC: $CLAIM_RESULT) — proceeding (fail-open on purpose)" >> "$L.log"
       if [ -n "${CLAIM_COMMIT:-}" ]; then
         CROSS_OWN="$CLAIM_COMMIT"
         release_fix_claim && CROSS_OWN=""
       fi ;;
  esac
fi

# Capture the FAILING REQUIRED CHECK and its log. The fixer is also dispatched for CI failures
# that are not a reviewer finding (docs lint, a committed conflict marker, legal-e2e,
# test-isolation, license-surface, pricing-artifact). Without this it would read only the review
# comment — which for such a PR may not exist at all — and fix blind.
: > "$L-failing.txt"
FAILING_CHECKS="$(gh pr checks "$PR" --repo "$OR" --json name,state 2>/dev/null | python3 -c "
import sys,json
try: d=json.load(sys.stdin)
except Exception: raise SystemExit
# The SAME allow-list polarity the loop's classifier and admin-merge.sh use (agent-infra#1714): a
# check is FAILING only when its state is neither a NAMED in-flight spelling nor one of the NON-RED
# conclusions. CANCELLED/STALE are non-red by that rule - a superseded run
# (cancel-in-progress: true) is normal, and handing one to a fixer burns a capped attempt on a PR
# that is not red, while the old deny-list named CANCELLED as failing.
INFLIGHT=('queued','in_progress','waiting','requested','pending')
NONRED=('success','neutral','skipped','cancelled','stale')
red=[]
for c in (d if isinstance(d,list) else []):
    s=str(c.get('state') or '').lower()
    if s in INFLIGHT or s in NONRED: continue
    red.append(str(c.get('name') or ''))
print(' '.join(red))
" 2>/dev/null)"
for c in $FAILING_CHECKS; do
  echo "=== failing required check: $c ===" >> "$L-failing.txt"
  RID="$(gh pr checks "$PR" --repo "$OR" --json name,link --jq ".[]|select(.name==\"$c\")|.link" 2>/dev/null | sed -nE 's#.*/runs/([0-9]+).*#\1#p' | head -1)"
  if [ -n "${RID:-}" ]; then gh run view "$RID" --repo "$OR" --log-failed 2>/dev/null | tail -80 >> "$L-failing.txt"; fi
done

# capture the reviewer's findings (the latest code-review comment on the PR)
gh pr view "$PR" --repo "$OR" --comments > "$L-comments.txt" 2>&1

# ⛔ agent-infra-SPECIFIC, and NOT in the tortoise original: the NO-SEARCH bound in the test bullet
# below. The fixer's worktree normally HAS a `.venv`, but when it does not the agent used to hunt for
# an interpreter across the filesystem — a `find` over $HOME blocks for minutes and has consumed whole
# agent budgets with nothing produced. Point it at `uv sync` instead. Do NOT drop it in a re-port.
cat > "$L-fixer.txt" <<EOF
You are a FIX agent for branch \`$BR\` (PR #$PR in $OR). A fresh-context reviewer found real issues; the full review is the LAST comment in this file: $L-comments.txt — read it in full

If $L-failing.txt is non-empty, REQUIRED CI CHECKS ARE ALSO FAILING and their failing logs are in that file — read it and fix the cause as well. That is not a reviewer finding: it is the build. A committed conflict marker (<<<<<<< / >>>>>>>) anywhere is one such cause and must be resolved, not deleted wholesale. (find every "### N. Px" / "[P0|P1|P2]" section and its "Fix:" line).

Work ONLY in this worktree: \`$WT\` (its cwd). NEVER touch the repo's main checkout. You are already on \`$BR\`.
    cd $WT && git status -sb && git log --oneline -3
If \`.venv\` is missing in the worktree, run \`uv sync --extra embeddings --extra parity\` once before testing.
If the branch is behind \`origin/main\`, integrate it first (\`git fetch origin main\` then a plain merge of origin/main) and resolve any conflicts so the PR stays mergeable.
**If this PR is CONFLICTING (mergeable=CONFLICTING), resolving the conflict IS the task** — GitHub reports it as unmergeable right now, so integrate \`origin/main\`, resolve every conflict hunk keeping both sides' intent, run the targeted tests, commit and push. If there are no review findings, the conflict is the whole job.

Apply a fix for EVERY finding (P3 notes: address or record explicitly). Requirements:
- Make the fix at the stated location, and add/adjust tests so they genuinely FAIL on the pre-fix code (prove non-vacuity where you can).
- Register any new test file in \`config/ci-surfaces.yml\` (correct surface) — verify with \`TORTOISE_TEST_CARVE_OUT=1 .venv/bin/python tools/ci_selection.py --integrity\`.
- Run the targeted tests: \`TORTOISE_TEST_CARVE_OUT=1 .venv/bin/python -m pytest <paths> -q -p no:cacheprovider\` (plus the sibling suites the review names). Never run the whole suite. Your worktree has its own \`.venv\` — use THAT one. ⛔ Never search the filesystem for an interpreter: no \`find\`/\`rg\`/\`du\` outside this worktree (a \`find\` under \`$HOME\` blocks for many minutes and has consumed whole agent budgets, producing no result). If \`.venv\` is genuinely missing here, run \`uv sync --extra embeddings --extra parity\` once.
- Stage specific files (never \`git add -A\`); commit with \`git commit -F <message-file>\`; push: \`git push origin $BR\`.
- Do NOT merge. Do NOT amend already-pushed commits — add a new commit.

FINAL MESSAGE (<=15 lines): which findings you fixed, files changed, exact test commands + pass/fail counts, and any finding you deliberately did not fix with the reason.
EOF
# ⛔ THE VOLUME IS THE WORKTREE, AND IT MUST BE PASSED EXPLICITLY (review round 2, P2). This script
# does `cd "$REPO"` (above) and only NAMES the worktree inside the agent's prompt, so `$PWD` here is
# the MAIN CHECKOUT — the gate's `DISK_GATE_PATH:-$PWD` default would measure a directory the agent
# never writes to. That is latent on a cell ($WT lives under $REPO/.worktrees, one volume) and real on
# a box that splits them: a healthy main checkout would let the fixer start onto a full worktree
# volume, which is the precise "cannot name the volume that actually fills" failure #1765 exists to
# remove. `uv sync` writes the venv in $WT, so $WT is the reading that matters.
DISK_GATE_PATH="$WT" run_agent "${FIX_TIMEOUT:-2400}" "$L.log" "$L-fixer.txt" "fixer for PR #$PR"
# ⛔ THE GATE'S OWN CODE, captured immediately. It is the ONLY thing that distinguishes the two
# refusals below, and `$?` read after any later command would be that command's status (§7.4).
ar=$?
# ⛔ AGENT_STARTED (set by run_agent) is the authority, NOT the exit code: `pi` shares the 0–255
# status namespace, so a pi that exited 75 for its own reason must not be read as a load refusal —
# that would silently skip the merge-chain re-run below (#1720 advisory).
if [ "$AGENT_STARTED" = "0" ]; then
  # Nothing was fixed, so re-running the merge chain would be a fresh-context review of an
  # unchanged head — pure cost on an already-overloaded box, and the re-review would be refused by
  # the same gate anyway. Exit and let the controller's next cycle re-dispatch.
  #
  # ⛔ WHICH GATE REFUSED DECIDES THE REMEDY, and the two are OPPOSITE (#1765). A load refusal
  # clears when the box quietens and the controller re-dispatches next cycle; a DISK refusal never
  # clears on its own — no amount of waiting frees a filesystem. Naming a disk refusal "load gate"
  # sends the operator to wait for an event that cannot fix it, which is the instrument false
  # positive this file's callers exist to avoid.
  # ⛔ TOLERANT REFERENCE, AND THE REASON IS A REAL SKEW (review round 2, P2 — REPRODUCED). The daemon
  # executes `$O/<script>` and $O is seeded file by file (cloud-cell-supervisor.sh's seed_and_stamp),
  # so a NEW caller can run against an OLD `$O/spawn-gate.sh` — the pre-#1765 helper defines
  # AGENT_LOAD_REFUSED but NOT AGENT_DISK_REFUSED. Under `set -u` that reference aborts HERE, BEFORE
  # the refund below: measured `bash: AGENT_DISK_REFUSED: unbound variable`, rc=1, fixcount unchanged —
  # three such refusals park a PR "needs a human" having never run a fixer, exactly the
  # agent-infra#1720 failure the refund exists to prevent. The default is CORRECT, not merely safe: a
  # pre-#1765 helper can never return 77, so 77 falls through to the load branch on the tree it came
  # from. install.sh's DRIFTED list now carries spawn-gate.sh, so the skew is DETECTED as well as
  # survived.
  if [ "$ar" = "${AGENT_DISK_REFUSED:-77}" ]; then
    why="disk gate: the filesystem is below DISK_MIN_FREE_MB — reclaim space (cloud-cell-supervisor.sh prune); this will NOT clear by waiting"
  else
    why="load gate: re-dispatched when 1-min load falls below MAX_LOAD"
  fi
  echo "[fix $PR] fixer NOT started ($why) — merge chain NOT re-run" >> "$L.log"
  if [ "${CTRL:-0}" = "1" ]; then
    # ⛔ REFUND, AND ONLY ON THE CONTROLLER PATH. orch-loop.sh books the attempt (fixcount+1) when
    # it CREATES the session, which is UPSTREAM of the gate inside run_agent(); this worker is the
    # only party that knows no agent ran. Without the refund, three refusals reach MAX_FIX_TRIES and
    # the PR is PARKED "needs a human" having never had a single fixer run (agent-infra#1720). A
    # manual (positional) run booked nothing, so it must refund nothing.
    CF="$O/state/fixcount-$PR"
    if [ -f "$CF" ]; then
      NF="$(cat "$CF" 2>/dev/null || echo 0)"
      # `is_num`, not a hand-rolled `case`: the predicate is already in scope (spawn-gate.sh defines
      # it, and this script uses it for its own tunables), and a second, weaker copy is exactly how
      # `08` grew an octal read in the first place.
      is_num "$NF" || NF=0
      if [ "$NF" -gt 0 ]; then
        echo $((NF - 1)) > "$CF"
        echo "[fix $PR] a gate refusal is not an attempt — fixcount refunded $NF -> $((NF - 1))" >> "$L.log"
      fi
    fi
  fi
  # Exit with the gate's OWN code, not a normalised 75: the caller (adopt-fix.sh, an operator) reads
  # it to choose the remedy, and 77 is the only thing that says "this one will not clear by waiting".
  exit "$ar"
fi
echo "[fix $PR] fixer done $(date) — re-running merge chain" >> "$L.log"
# Release BEFORE the merge chain. If the fixer pushed, merge-one.sh claims the NEW head. If it did
# NOT push, the SAME head is still claimed by us and merge-one.sh would refuse it as "another box
# owns head" — so the release is mandatory, not tidiness.
# ⛔ ONLY clear the latch when the release actually succeeded. A failed release (rc=1: fenced/torn
# push) must leave CROSS_OWN set so the EXIT trap (`trap 'release_fix_claim' EXIT`) retries it at
# process exit — otherwise the claim strands on the remote for the whole fixer lease
# (FIX_TIMEOUT+1200, up to ~1 h) and the controller, reading the live lease as data, stops
# re-dispatching that head. Same latch in merge-one.sh's claim block.
# The failure is also LOGGED (P3, second review round, 2026-10-14): a retained latch that leaves no
# trace is indistinguishable from a released claim to anyone reading the log afterwards.
if [ -n "${CROSS_OWN:-}" ]; then
  if release_fix_claim >/dev/null 2>&1; then
    CROSS_OWN=""
  else
    echo "[fix $PR] cross-box fixer claim: could not release ${CROSS_OWN:0:12} — the EXIT trap will retry" >> "$L.log"
  fi
fi
# re-run the full chain at the new head
bash "$O/merge-one.sh" "$REPO" "$OR" "$PR" "$BR" >> "$L.log" 2>&1
echo "[fix $PR] end $(date)" >> "$L.log"
