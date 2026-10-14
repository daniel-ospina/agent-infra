#!/usr/bin/env bash
# merge-one.sh <repo-path> <owner/repo> <pr> <branch>
# merge-one.sh --argv <file>            (4 lines: repo, owner/repo, pr, branch)
# Full chain for ONE PR: fresh-context review -> evidence comment -> record-review -> wait green -> merge.
# This box holds the AI_REVIEW_GATE_KEY, so it owns the merge authority for its own PRs.
#
# ⛔ TERMINAL STATE (#1717). Every failure that leaves the signed marker absent — the record step
# cannot run, the reviewer posted no evidence comment, the record itself failed — writes
# `$O/state/parked-<PR>` (the head a human must look at) BEFORE exiting, instead of exiting
# silently. That file is what the controller's parked guard reads, so the loop stops instead of
# spawning another review; and this script refuses to re-review an already-parked head itself, so
# the chain-<N> and fix-one.sh paths (which never consult the controller) cannot re-pay either.
# A later push changes the head and re-arms the PR by construction.
set -u
# --argv exists because these values are attacker-influenced (a PR branch name may contain quotes,
# semicolons, $ and backticks) and the controller must launch us from a tmux `sh -c` string.
# Passing them through a file keeps every PR-derived value out of that string entirely.
if [ "${1:-}" = "--argv" ]; then
  ARGV="${2:-}"
  [ -f "$ARGV" ] || { echo "[merge] missing argv file: $ARGV" >&2; exit 1; }
  { read -r REPO; read -r OR; read -r PR; read -r BR; } < "$ARGV"
  rm -f "$ARGV"
else
  REPO="$1"; OR="$2"; PR="$3"; BR="$4"
fi
case "${PR:-}" in ''|*[!0-9]*) echo "[merge] refusing non-numeric PR: ${PR:-<empty>}" >&2; exit 1 ;; esac
O="${O:-$HOME/orchestrator}"; mkdir -p "$O/logs" "$O/state"
L="$O/logs/merge-$PR"
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
export AGENT_SKIP_REVIEW_GATE=1 ELDATO_SKIP_VGATE=1 AGENT_ALLOW_MAIN_EDITS=1 ELDATO_ALLOW_MAIN_EDITS=1
export PI_MCP_SERVERS=none   # headless reviewer uses no MCP servers — saves ~25 processes/run
export PI_SKIP_VERSION_CHECK=1 SKILL_ENFORCER_DISABLED=1 LOOP_ENFORCER_DISABLED=1 SLACK_BRIDGE_DISABLE=1 VISION_INTERCEPTOR_DISABLED=1
cd "$REPO" || exit 1

# Portable wall-clock timeout for the agent invocation. `pi -p` has no internal limit, so one hung
# model call holds a concurrency slot forever — and the caps count SESSIONS, so a single hang
# silently halves throughput. macOS ships no `timeout`/`gtimeout`, so implement it in bash: run the
# agent in the background with a watchdog subshell that kills it after N seconds. The stale-worker
# reaper in orch-loop.sh is the second line of defence.
run_agent() { # run_agent <seconds> <logfile> <promptfile>
  local t="$1" log="$2" prompt="$3" pid w rc
  pi -p --provider deepseek --model deepseek-v4-flash --no-session "$(cat "$prompt")" >> "$log" 2>&1 &
  pid=$!
  ( sleep "$t"; kill -TERM "$pid" 2>/dev/null; sleep 15; kill -KILL "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  w=$!
  wait "$pid" 2>/dev/null; rc=$?
  kill "$w" 2>/dev/null
  echo "[timeout] agent pid=$pid wall_limit=${t}s rc=$rc" >> "$log"
  return "$rc"
}
git fetch origin "$BR" --quiet 2>/dev/null || true   # external (other-machine) branches may not be fetched locally

# ── single-owner claim ────────────────────────────────────────────────────────
# Three paths reach this script: chain-<N> (waits for a lane's PR), fix-<PR>, and the
# controller's merge sweep. Only the last two are visible to the controller by session name,
# so without a shared claim a freshly opened PR gets TWO concurrent reviewers racing the same
# head: duplicate evidence comments, duplicate record-review writes, and an
# ISSUES/CLEAN interleaving where one worker's needsfix marker lands after the other merged.
# Atomic noclobber create is the lock; the controller also tests this file.
CLAIM="$O/state/mergeclaim-$PR.lock"
claim() { ( set -o noclobber; echo $$ > "$CLAIM" ) 2>/dev/null; }
if ! claim; then
  OPID="$(cat "$CLAIM" 2>/dev/null || echo 0)"
  if [ "${OPID:-0}" -gt 0 ] && kill -0 "$OPID" 2>/dev/null; then echo "[merge $PR] pid $OPID already owns this PR — exiting" >> "$L.log"; exit 0; fi
  rm -f "$CLAIM"
  claim || { echo "[merge $PR] claim race — exiting" >> "$L.log"; exit 0; }
fi
# ⛔ Same defect as orch-loop.sh, on the per-PR claim (§5.1b): a RETURNING INT/TERM handler
# resumes the interrupted command loop, so a TERM removed the claim while this worker kept
# reviewing and merging, and the controller could spawn a second worker for the same head. The
# handlers TERMINATE; the claim is released by the EXIT trap alone. Measured on /bin/bash 3.2.57:
# `exit 143` from a TERM handler still runs the EXIT trap (rc=143); an untrapped INT is ignored
# outright (still alive after 3s), so INT is trapped rather than dropped. (agent-infra#1715)
trap 'exit 143' TERM
trap 'exit 130' INT
trap 'rm -f "$CLAIM"' EXIT

HEAD="$(gh pr view "$PR" --repo "$OR" --json headRefOid --jq .headRefOid 2>/dev/null)"
echo "[merge $PR] start $(date) head=$HEAD branch=$BR" > "$L.log"

# ── 0) terminal state and the record dependency — BEFORE the paid review (#1717) ──────────────
# `park` records the terminal state at the head that was reviewed. It is deliberately the SAME
# marker the controller's own park paths write (`parked-<PR>` = the head, so a new push re-arms),
# plus a `parkreason-<PR>` that names WHY — the controller cannot say why, and "PARKED" with no
# reason is a state nobody can act on.
park() { # park <reason…>
  local why="$*"
  # ⛔ THE REASON BELONGS TO THE HEAD THIS PARK IS KEYED TO. An EMPTY HEAD means the
  # unresolvable-head branch below (a transient `gh` blip) reached park() while an earlier park at a
  # real head is still in place: it writes no marker, and re-writing the reason there would replace
  # the real, actionable cause with the transient one — so when gh recovers the worker matches the
  # park, exits 5, and the exit-5 log (the only in-band remedy on the chain-<N>/fix-one.sh paths)
  # would name the wrong cause. With no head there is no new park to describe, so the first reason
  # wins. A NON-EMPTY HEAD is a fresh park — a moved head re-arms the PR and the already-parked
  # guard cannot have fired for it — so its reason must REPLACE a stale one from an earlier head.
  if [ -n "${HEAD:-}" ] || [ ! -s "$O/state/parked-$PR" ]; then
    printf '%s\n' "$why" > "$O/state/parkreason-$PR"
  fi
  [ -n "${HEAD:-}" ] && printf '%s\n' "$HEAD" > "$O/state/parked-$PR"
  echo "[merge $PR] PARKED head=${HEAD:-?} — $why" >> "$L.log"
}

# ⛔ THE HEAD IS THE SAME CLASS OF PRE-REVIEW DEPENDENCY AS THE RECORDER (#1717). The `gh pr view`
# above swallows its own failure (2>/dev/null), so one transient API/network/rate-limit blip leaves
# HEAD empty — and the PRE-FIX flow still ran the WHOLE fresh-context review (up to REVIEW_TIMEOUT =
# 1800 s, PAID), only for record-review.sh to refuse an empty sha ("head_sha must be a full 40-char
# hex sha — refusing to record"). park() then could not write `parked-<PR>` AT ALL (there is no head
# to key it to, and the controller's guard requires a non-empty head too), so the controller saw no
# park at its HEAD_N, re-spawned a worker, and paid again every cycle — the exact unbounded paid
# loop #1717 removes. Refuse BEFORE the paid step, against the same 40-char hex shape
# record-review.sh enforces, and leave the actionable terminal reason.
head_ok=0
case "${HEAD:-}" in '' | *[!0-9a-f]*) head_ok=1 ;; esac
[ "${#HEAD}" -eq 40 ] || head_ok=1
if [ "$head_ok" -ne 0 ]; then
  park "could not resolve PR #$PR head (gh pr view returned '${HEAD:-<empty>}') — the record step needs a full 40-char hex sha, so a review paid for here could never be recorded or merged. Re-run once gh is reachable, then: rm -f '$O/state/parked-$PR' '$O/state/parkreason-$PR'"
  echo "[merge $PR] ABORT: unresolvable head '${HEAD:-<empty>}' — not paying for a review whose record step could never sign" >> "$L.log"
  exit 3
fi

# Honour the park HERE, not only in the controller. chain-<N> and fix-one.sh invoke this script
# directly, and the controller's parked guard is invisible to them; without this the park would
# hold only the path that was already fixed. Exit 5 = "refused, already parked at this head".
if [ -n "${HEAD:-}" ] && [ "$(cat "$O/state/parked-$PR" 2>/dev/null)" = "$HEAD" ]; then
  echo "[merge $PR] PARKED at head=$HEAD — refusing to re-review (reason: $(cat "$O/state/parkreason-$PR" 2>/dev/null)). A push re-arms it, or: rm -f '$O/state/parked-$PR' '$O/state/parkreason-$PR'" >> "$L.log"
  exit 5
fi

# ⛔ THE RECORD STEP IS THE ONLY MERGE PATH, AND IT USED TO BE PAID TO DISCOVER IT WAS MISSING
# (#1717). record-review.sh mints the signed marker ai-review-gate verifies; on a fresh cell the
# file is absent. The pre-fix flow ran the WHOLE fresh-context review (up to REVIEW_TIMEOUT = 1800 s,
# PAID) and only then failed — and its `exit 3` skipped the `*)` arm that writes the fixer marker,
# so the next cycle saw an unmarked FAILED:ai-review-gate and spawned another review. One paid
# review per cycle, forever. Refuse BEFORE the paid step, and leave the terminal marker.
# The probe must require a NON-EMPTY REGULAR FILE, not merely presence + executability: `[ -x ]` is
# true for a directory (the paid review is then bought, and the record step fails 126), and an EMPTY
# file is executable and exits 0 WITHOUT minting the marker — so nothing is parked and the loop
# re-pays, which is the #1717 loop one input over. Same shape cmd_check enforces.
RECORDER="$HOME/.pi/agent/scripts/record-review.sh"
if [ ! -e "$RECORDER" ]; then
  park "record-review.sh MISSING at $RECORDER — the record step cannot run, so this PR can never be signed or merged. Provision it (cp it into \$HOME/.pi/agent/scripts/ and chmod +x), then: rm -f '$O/state/parked-$PR' '$O/state/parkreason-$PR'"
  echo "[merge $PR] ABORT: $RECORDER missing — not paying for a review whose record step cannot run" >> "$L.log"
  exit 3
fi
if [ ! -f "$RECORDER" ]; then
  park "record-review.sh at $RECORDER is NOT A REGULAR FILE — merge-one.sh runs it directly, so a directory (or any other non-regular file) fails (126) after a PAID review. Remove it and re-provision (start, or cp into \$HOME/.pi/agent/scripts/ and chmod +x), then: rm -f '$O/state/parked-$PR' '$O/state/parkreason-$PR'"
  echo "[merge $PR] ABORT: $RECORDER not a regular file — not paying for a review whose record step cannot run" >> "$L.log"
  exit 3
fi
if [ ! -s "$RECORDER" ]; then
  park "record-review.sh at $RECORDER is EMPTY (0 bytes) — an empty file is executable and exits 0 WITHOUT minting the signed marker, so ai-review-gate can never go green and the loop would re-pay for a fresh review every cycle. Re-provision it (start, or cp into \$HOME/.pi/agent/scripts/ and chmod +x), then: rm -f '$O/state/parked-$PR' '$O/state/parkreason-$PR'"
  echo "[merge $PR] ABORT: $RECORDER is empty — not paying for a review whose record step cannot sign" >> "$L.log"
  exit 3
fi
if [ ! -x "$RECORDER" ]; then
  park "record-review.sh at $RECORDER is NOT EXECUTABLE — the record step would fail (126) after a PAID review. Fix: chmod +x '$RECORDER', then: rm -f '$O/state/parked-$PR' '$O/state/parkreason-$PR'"
  echo "[merge $PR] ABORT: $RECORDER not executable — not paying for a review whose record step cannot run" >> "$L.log"
  exit 3
fi

# ── 1) fresh-context review, POSTED as a PR comment (the audit artifact) ──────
cat > "$L-reviewer.txt" <<EOF
You are a FRESH-CONTEXT code reviewer for $OR. Review PR #$PR (branch $BR). Report only — do not fix code.
    cd $REPO && git fetch origin main --quiet
    gh pr view $PR --repo $OR --json title,body,files
    gh pr diff $PR --repo $OR
Read the changed files IN FULL at the PR head (\`git show origin/$BR:<path>\`), not just the diff hunks. Read skills/code-review/SKILL.md for the discipline.
Report ONLY HIGH-confidence real issues: correctness bugs; security (injection/auth bypass/secrets); VACUOUS tests (would pass on the pre-fix code — prove it); scope/claim mismatch; regressions; fail-open paths; repo-rule violations — especially a NEW test file missing from config/ci-surfaces.yml (the manifest-integrity leg fails and the file is never selected).
If you need to run tests, use your own throwaway checkout: \`TORTOISE_TEST_CARVE_OUT=1 .venv/bin/python -m pytest <paths> -q -p no:cacheprovider\`. Bound every command; never run the whole suite.

## REQUIRED: post your review as a PR comment (this is the merge-gate audit artifact)
Write your review to a file, then:
    gh pr comment $PR --repo $OR --body-file <your-review-file>
Your comment MUST state the outcome plainly and MUST NOT contain an unresolved assertion. Forbidden phrases in a CLEAN comment: "issues remain", "NOT CLEAN", "requires human attention", "auto-fix stalled/failed/reached cap".

## FINAL MESSAGE — exactly one line:
    CLEAN <the comment URL that gh pr comment printed>
  or, if you found real issues:
    ISSUES <n>
Do NOT modify code, commit, or merge.
EOF
run_agent "${REVIEW_TIMEOUT:-1800}" "$L.log" "$L-reviewer.txt"
LAST="$(grep -aE '^(CLEAN|ISSUES) ' "$L.log" | tail -1 | tr -d '\r')"
echo "[merge $PR] verdict: ${LAST:-<none>}" >> "$L.log"

case "$LAST" in
  CLEAN*)
    URL="$(printf '%s' "$LAST" | grep -oE 'https?://[^ ]+' | head -1)"
    CID="$(printf '%s' "$URL" | grep -oE '[0-9]+$')"
    echo "[merge $PR] evidence comment id=${CID:-?} url=$URL" >> "$L.log"
    if [ -z "${CID:-}" ]; then
      # The reviewer said CLEAN but named no comment, so there is no artifact to sign — the gate can
      # NEVER go green at this head. Park it: the pre-fix bare `exit 2` left no marker, so the loop
      # re-paid for a fresh review every cycle (#1717).
      park "reviewer reported CLEAN but posted no comment URL — no evidence artifact to sign, so ai-review-gate can never go green at this head. The comment usually EXISTS (the reviewer posts it before the verdict): find it on PR #$PR and record it by hand (record-review.sh $PR $HEAD clean $OR --evidence comment:<id>), then: rm -f '$O/state/parked-$PR' '$O/state/parkreason-$PR'"
      echo "[merge $PR] ABORT: no comment id" >> "$L.log"; exit 2
    fi
    # ── 2) record the review (writes the signed marker into the PR body) ──
    "$RECORDER" "$PR" "$HEAD" clean "$OR" --evidence "comment:$CID" >> "$L.log" 2>&1
    rc=$?
    echo "[merge $PR] record-review rc=$rc" >> "$L.log"
    if [ $rc -ne 0 ]; then
      # No signed marker exists, so the gate cannot pass and the PR cannot merge. The pre-fix
      # `exit 3` left no marker at ALL, so the next cycle saw an unmarked FAILED:ai-review-gate and
      # spawned another fresh (paid) review — forever (#1717). Park, and name the failing rc.
      park "record-review.sh failed rc=$rc at head=$HEAD — the signed marker is NOT in the PR body, so the loop would re-pay for a fresh review every cycle. Re-record by hand (record-review.sh $PR $HEAD clean $OR --evidence comment:$CID), then: rm -f '$O/state/parked-$PR' '$O/state/parkreason-$PR'"
      echo "[merge $PR] ABORT: record failed" >> "$L.log"; exit 3
    fi
    # ⛔ `rc=0` IS NOT PROOF THE SIGNED MARKER REACHED THE PR BODY (#1717, fail-open).
    # record-review.sh posts the marker into the PR body BEST-EFFORT and never fails the record, so
    # it has reachable rc=0 paths with NO post at all: the body GET failed ("evidence post skipped;
    # record still saved"), the body PATCH failed ("could not post review evidence … record still
    # saved"), or gh is missing / the repo is undetectable ("the ai-review-gate required check will
    # fail until evidence is posted manually"). Trusting rc=0 there means the gate can NEVER go
    # green, the `gate != SUCCESS` arm below exits 4 WITHOUT a park, and the controller re-spawns a
    # fresh PAID review every cycle — the exact #1717 loop, one state over. So verify the artifact
    # the gate actually reads: the SIGNED marker for THIS head in the PR body. Absence (or an
    # unsigned marker, which the gate also rejects) is the same terminal failure as a non-zero rc.
    LIVE_HEAD="$(gh pr view "$PR" --repo "$OR" --json headRefOid --jq .headRefOid 2>/dev/null)"
    # record-review.sh re-binds a carried record to the LIVE head, so the artifact is keyed to the
    # head the gate will judge; fall back to the reviewed head when that read itself fails.
    [ -n "$LIVE_HEAD" ] || LIVE_HEAD="$HEAD"
    BODY="$(gh pr view "$PR" --repo "$OR" --json body --jq .body 2>/dev/null)"
    if ! printf '%s\n' "$BODY" \
         | grep -qE "review recorded: reviews/${PR}[.]json verdict=clean @ ${LIVE_HEAD} .*sig=[0-9a-f]{64}"; then
      park "record-review.sh returned rc=0 but NO signed marker for head=$LIVE_HEAD reached the PR body — its evidence post is best-effort and skips silently when the body read/PATCH fails or gh/repo is unavailable, so ai-review-gate can never go green at this head and the loop would re-pay for a fresh review every cycle. If the reviewer's comment exists, record it by hand (record-review.sh $PR $HEAD clean $OR --evidence comment:$CID), then: rm -f '$O/state/parked-$PR' '$O/state/parkreason-$PR'"
      echo "[merge $PR] ABORT: rc=0 but no signed marker in the PR body" >> "$L.log"; exit 3
    fi
    # ── 3) wait for the required ai-review-gate to go green (read the LATEST check row) ──
    gate=""
    for i in $(seq 1 30); do
      gate="$(gh pr checks "$PR" --repo "$OR" --json name,state --jq '[.[]|select(.name=="ai-review-gate")][0].state' 2>/dev/null)"
      echo "[merge $PR] gate=$gate (try $i)" >> "$L.log"
      [ "$gate" = "SUCCESS" ] && break
      sleep 30
    done
    # ⛔ NOT parked, deliberately (verified by reading the controller, not assumed): the signed
    # marker IS in the PR body by here (the check above proved it, rather than trusting rc=0), so
    # this head can still merge. A park would make the loop's
    # top-of-cycle parked guard `continue` past a PR whose gate turns green a minute later — a
    # stranded merge, strictly worse than the cost of the retry. A record failure cannot be
    # stranded, which is why THAT is parked.
    if [ "$gate" != "SUCCESS" ]; then echo "[merge $PR] ABORT: gate=$gate (not green)" >> "$L.log"; exit 4; fi
    # ── 4) merge ──
    if gh pr merge "$PR" --repo "$OR" --squash >> "$L.log" 2>&1; then
      echo "[merge $PR] MERGED $(date)" >> "$L.log"
      touch "$O/state/merged-$PR.done"
    else
      echo "[merge $PR] merge command failed" >> "$L.log"
    fi
    ;;
  *)
    # The reviewer found real issues (or the reviewer failed) at this exact head. Leave a
    # marker so the loop knows to spawn a FIXER (not another re-record) on its next cycle.
    echo "[merge $PR] NOT CLEAN or reviewer failed — needs a fixer at head=$HEAD" >> "$L.log"
    [ -n "${HEAD:-}" ] && touch "$O/state/needsfix-$PR-$HEAD"
    ;;
esac
echo "[merge $PR] end $(date)" >> "$L.log"
