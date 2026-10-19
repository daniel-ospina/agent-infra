#!/usr/bin/env bash
# lane-merge.test.sh — offline suite for lane-merge.sh (the bounded merge loop).
#
# HERMETIC: throwaway $O, throwaway HOME, a stub `gh`, a stub chain. No network, no tmux, no git.
# The two API reads are injected with the script's own documented seams (--pr-tsv / --checks-tsv),
# so every verdict in the state machine is exercised WITHOUT a live pull request. The stubs exist
# for the write paths (the handoff comment) and for the chain launch.
#
# ⛔ WHAT THESE CHECKS ARE FOR. A naive "the script exits 0" test passes on a broken copy. Each case
# below asserts the ARTIFACT the lane acts on: the verdict token, the round counter, the failing
# names, the posted comment, and — for the property that matters most — that the script can never
# merge without the chain (no `gh pr merge`, no `record-review.sh`, no self-attestation).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/lane-merge.sh"
pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
ck()  { if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1"; fi; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
[ -s "$SCRIPT" ] || { bad "lane-merge.sh is missing or empty"; exit 1; }

# ── stubs ────────────────────────────────────────────────────────────────────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"
# `gh` records every invocation's argv, and answers the handoff-comment read with "none yet".
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GH_LOG:-/dev/null}"
case " $* " in
  *"check-runs"*) [ -n "${CHECKS_STUB:-}" ] && cat "$CHECKS_STUB"; exit 0 ;;
  *"pulls/"*)
    # TWO different reads hit this URL, and they must not be confused: the script's own PR read
    # carries `join(`, the detached wrapper's merge CONFIRMATION (F3) is a bare merged_at jq. If the
    # confirmation fell through to the queue it would consume a queued PR line and answer nothing.
    case " $* " in
      *"join("*)     # one line per call, so "a good read then a failing read" is expressible
        q="${PR_QUEUE:-}"
        if [ -n "$q" ] && [ -s "$q" ]; then
          l="$(head -1 "$q")"; tail -n +2 "$q" > "$q.tmp" 2>/dev/null && mv "$q.tmp" "$q"
          printf '%s\n' "$l"
        fi ;;
      *)  # set-but-empty MERGED_AT_STUB = "the API says this PR is not merged"
        # MERGED_API_FAIL=1 = "the READ FAILED" (rate limit / DNS): exit non-zero, print nothing. The
        # two are DIFFERENT facts and the loop must not collapse them.
        if [ "${MERGED_API_FAIL:-0}" = 1 ]; then exit 1; fi
        [ -n "${MERGED_AT_STUB+x}" ] && printf '%s\n' "$MERGED_AT_STUB" ;;
    esac
    exit 0 ;;
  *" comments?per_page"*) exit 0 ;;         # the dedup read: no comments on the PR
  *" -X POST "*)
    # Record the POSTED BODY too (the file is removed by the caller right after), so a suite can
    # assert what the next holder would actually read.
    for a in "$@"; do
      case "$a" in body=@*) f="${a#body=@}"; [ -f "$f" ] && printf '%s\n' "BODY-BEGIN" >> "${GH_LOG:-/dev/null}" && cat "$f" >> "${GH_LOG:-/dev/null}" && printf '%s\n' "BODY-END" >> "${GH_LOG:-/dev/null}" ;; esac
    done
    exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$BIN/gh"
# A stub chain: it "merges" by flipping the PR fixture to closed+merged and posting the rail line.
mk_chain() { # mk_chain <fixture-path>   (writes into the CURRENT case's $OT)
  cat > "$OT/merge-one.sh" <<EOF
#!/usr/bin/env bash
printf 'rail: MERGED via the rail (stub)\\n'
printf 'closed|2026-10-18T00:00:00Z|head123|clean\\n' > "$1"
# MK_MERGED makes this stub behave like merge-one.sh on a real merge: it writes the marker the
# detached wrapper reads. Without it the wrapper takes its "did not merge" branch.
if [ "\${MK_MERGED:-}" = "1" ]; then printf 'mergedsha\\n' > "$OT/state/merged-\$3.done"; fi
EOF
  chmod +x "$OT/merge-one.sh"
}

CASE=0; OT=""
new_o() { CASE=$((CASE + 1)); OT="$T/o$CASE"; rm -rf "$OT"; mkdir -p "$OT/state" "$OT/logs"; mk_chain "$1"; }
run() { # run <pr> <args…>  → sets RC, OUT
  OUT="$(PATH="$BIN:$PATH" GH_LOG="$T/gh.log" O="$OT" HOME="$T/home" \
        LANE_MERGE_INTERVAL=5 LANE_MERGE_WAIT="${WAIT_S:-0}" LANE_MERGE_POLL="${POLL_S:-0}" \
        bash "$SCRIPT" "$@" 2>&1)"; RC=$?
}
verdict_of() { cat "$OT/state/lanemerge-$1.verdict" 2>/dev/null; }

mkdir -p "$T/home"
echo "==> lane-merge.sh offline suite"

# ── 1. --status with no state is honest about it (no fabrication of a verdict) ───────────────────
new_o "$T/pr.tsv"
run 7 --status
ck "--status with no record prints NONE + round 0 (got: $OUT)" \
   $([ "$(printf '%s' "$OUT" | tr -d '\n')" = "NONE round=0/3" ] && echo 0 || echo 1)

# ── 2. a MERGED PR is reported with its sha and exits 0 ─────────────────────────────────────────
printf 'closed|2026-10-18T00:00:00Z|abc123|clean\n' > "$T/pr.tsv"
new_o "$T/pr.tsv"
run 7 --issue 42 --repo o/r --pr-tsv "$T/pr.tsv"
ck "a merged PR → exit 0, verdict MERGED, sha printed" \
   $([ "$RC" = 0 ] && [ "$(verdict_of 7 | cut -d' ' -f1)" = MERGED ] && grep -q abc123 <<<"$OUT" && echo 0 || echo 1)
ck "the ISSUE-keyed verdict exists (that is what chain-merge waits on)" \
   $([ "$(cat "$OT/state/lanemerge-issue-42.verdict" 2>/dev/null | cut -d' ' -f1)" = MERGED ] && echo 0 || echo 1)

# ── 3. a CLOSED-but-unmerged PR is BLOCKED, never reported as merged ────────────────────────────
printf 'closed||abc123|clean\n' > "$T/pr2.tsv"
new_o "$T/pr2.tsv"
run 8 --repo o/r --pr-tsv "$T/pr2.tsv"
ck "a closed, unmerged PR → exit 14 BLOCKED_CLOSED (never a false MERGED)" \
   $([ "$RC" = 14 ] && [ "$(verdict_of 8 | cut -d' ' -f1)" = BLOCKED_CLOSED ] && echo 0 || echo 1)

# ── 4. a DIRTY PR is a conflict round, and the instruction is the right one ─────────────────────
printf 'open||abc123|dirty\n' > "$T/pr3.tsv"
new_o "$T/pr3.tsv"
run 9 --repo o/r --pr-tsv "$T/pr3.tsv"
ck "dirty → exit 15 FIX_CONFLICT, round 1 spent" \
   $([ "$RC" = 15 ] && [ "$(verdict_of 9 | cut -d' ' -f1)" = FIX_CONFLICT ] && [ "$(cat "$OT/state/lanemerge-9.round")" = 1 ] && echo 0 || echo 1)
ck "…and it says re-apply onto main / force-push own branch, never pick a side on a generated file" \
   $(grep -q "re-apply THIS lane's own change" <<<"$OUT" && grep -q "Never resolve a GENERATED file" <<<"$OUT" && echo 0 || echo 1)

# ── 5. RED checks → FIX_REQUIRED naming them, and the names are recorded for the handoff ────────
printf 'open||abc123|clean\n' > "$T/pr4.tsv"
printf 'lint\tcompleted\tfailure\t11\nunit\tcompleted\tsuccess\t12\n' > "$T/checks-red.tsv"
new_o "$T/pr4.tsv"
run 10 --repo o/r --pr-tsv "$T/pr4.tsv" --checks-tsv "$T/checks-red.tsv"
ck "red check → exit 10 FIX_REQUIRED naming 'lint' (and NOT the green one)" \
   $([ "$RC" = 10 ] && grep -qE "checks are RED: lint$" <<<"$OUT" && [ "$(cat "$OT/state/lanemerge-10.last")" = lint ] && echo 0 || echo 1)

# ── 6. POLARITY: an undocumented conclusion is RED; cancelled/stale are not ─────────────────────
printf 'a\tcompleted\tsuccess\t1\nb\tcompleted\tfailure\t2\nc\tcompleted\tsuccess\t3\nc\tcompleted\twatchamacallit\t4\nd\tcompleted\tcancelled\t5\ne\tcompleted\tstale\t6\nf\tcompleted\t\t7\n' > "$T/checks-pol.tsv"
new_o "$T/pr5.tsv"
run 11 --repo o/r --pr-tsv "$T/pr4.tsv" --checks-tsv "$T/checks-pol.tsv"
ck "unknown conclusion + null conclusion are RED; cancelled/stale are not; newest attempt by id wins (c → red)" \
   $(grep -q "RED: b c f" <<<"$OUT" && echo 0 || echo 1)

# ── 6b. TWO WORKFLOWS SHARING A JOB NAME must not mask each other (group by app+name) ──────────
printf 'packaging-smoke\tcompleted\tfailure\t10\tgithub-actions\npackaging-smoke\tcompleted\tsuccess\t11\tother-app\n' > "$T/checks-apps.tsv"
new_o "$T/pr19.tsv"
run 27 --repo o/r --pr-tsv "$T/pr4.tsv" --checks-tsv "$T/checks-apps.tsv"
ck "the same job name from two apps is TWO groups — the newer green of one does not mask the red of the other" \
   $(grep -q "github-actions:packaging-smoke" <<<"$OUT" && echo 0 || echo 1)

# ── 7. in-flight at the bound is NOT a green and NOT a failure of the lane ──────────────────────
printf 'slow\tin_progress\t\t21\n' > "$T/checks-inflight.tsv"
new_o "$T/pr6.tsv"
run 12 --repo o/r --pr-tsv "$T/pr4.tsv" --checks-tsv "$T/checks-inflight.tsv"
ck "in-flight at the wait bound → exit 11 WAITING_CHECKS (no merge, no round spent)" \
   $([ "$RC" = 11 ] && [ "$(verdict_of 12 | cut -d' ' -f1)" = WAITING_CHECKS ] && [ ! -f "$OT/state/lanemerge-12.round" ] && echo 0 || echo 1)

# ── 8. "no red" from a head with NO completed run is not evidence of green ──────────────────────
printf 'q\tqueued\t\t31\n' > "$T/checks-queued.tsv"
new_o "$T/pr7.tsv"
run 13 --repo o/r --pr-tsv "$T/pr4.tsv" --checks-tsv "$T/checks-queued.tsv"
ck "queued-only head → exit 11 IN FLIGHT, and the chain is NOT launched (a queued run is not green)" \
   $([ "$RC" = 11 ] && grep -q "still IN FLIGHT" <<<"$OUT" && [ ! -f "$OT/logs/lane-merge-13.log" ] && echo 0 || echo 1)

# ── 9. GREEN → the harness chain is launched (never a hand-rolled gh merge) ─────────────────────
printf 'allgood\tcompleted\tsuccess\t41\n' > "$T/checks-green.tsv"
printf 'open||abc123|clean\n' > "$T/pr8.tsv"
new_o "$T/pr8.tsv"
run 14 --repo o/r --pr-tsv "$T/pr8.tsv" --checks-tsv "$T/checks-green.tsv"
sleep 1
ck "green → exit 11 WAITING and the chain log shows it ran (the lane does not merge itself)" \
   $([ "$RC" = 11 ] && grep -q "launched the merge chain" <<<"$OUT" && grep -q "MERGED via the rail" "$OT/logs/lane-merge-14.log" 2>/dev/null && echo 0 || echo 1)
# …and once the chain has merged, the next invocation reports MERGED from the PR state (the artifact
# is authoritative, not the chain's exit code).
run 14 --repo o/r --pr-tsv "$T/pr8.tsv"
ck "after the chain merged, the next run reports MERGED from the PR's own state" \
   $([ "$RC" = 0 ] && [ "$(verdict_of 14 | cut -d' ' -f1)" = MERGED ] && echo 0 || echo 1)

# ── 10. THE CAP IS SPENT WHERE IT IS SPENT — and a RED head at the cap blocks with FRESH names ──
# ⛔ The first implementation refused at the cap BEFORE reading the checks, so the LAST allowed fix
# was never verified and the handoff quoted STALE names from an earlier head (reviewer P1). The cap
# now lives in emit_fix, which sees the CURRENT red set.
new_o "$T/pr9.tsv"
printf '3\n' > "$OT/state/lanemerge-16.round"
: > "$T/gh.log"
run 16 --repo o/r --pr-tsv "$T/pr4.tsv" --checks-tsv "$T/checks-red.tsv"
ck "round 3 spent + still red → exit 13 BLOCKED_ATTEMPTS, no 4th round, no chain, fresh names recorded" \
   $([ "$RC" = 13 ] && [ "$(verdict_of 16 | cut -d' ' -f1)" = BLOCKED_ATTEMPTS ] && [ "$(cat "$OT/state/lanemerge-16.round")" = 4 ] && [ ! -f "$OT/logs/lane-merge-16.log" ] && [ "$(cat "$OT/state/lanemerge-16.last")" = lint ] && echo 0 || echo 1)
ck "…and a handoff comment WAS posted (the next holder inherits a diagnosis, not a mystery)" \
   $(grep -q "issues/16/comments" "$T/gh.log" && grep -q "body=@" "$T/gh.log" && echo 0 || echo 1)

# ── 11. …and a GREEN head with the cap spent VERIFIES the last fix and proceeds to the chain ────
new_o "$T/pr10.tsv"
printf '3\n' > "$OT/state/lanemerge-17.round"
run 17 --repo o/r --pr-tsv "$T/pr4.tsv" --checks-tsv "$T/checks-green.tsv"; RC1=$RC
ck "round 3 spent + GREEN → the last fix is verified and the chain is launched (convergence, not a cap breach)" \
   $([ "$RC1" = 11 ] && grep -q "launched the merge chain" <<<"$OUT" && [ "$(cat "$OT/state/lanemerge-17.round")" = 3 ] && echo 0 || echo 1)

# ── 11b. a PARTIAL classification must never read as green (fail closed) ───────────────────────
new_o "$T/pr16.tsv"
mkdir -p "$T/bin2"
printf '#!/usr/bin/env bash\nprintf "INFLIGHT 0\\n"\n' > "$T/bin2/python3"; chmod +x "$T/bin2/python3"
OUT="$(PATH="$T/bin2:$BIN:$PATH" O="$OT" HOME="$T/home" LANE_MERGE_WAIT=0 \
      bash "$SCRIPT" 24 --repo o/r --pr-tsv "$T/pr4.tsv" --checks-tsv "$T/checks-red.tsv" 2>&1)"; RC=$?
ck "a classifier that printed INFLIGHT but no RED line → exit 2, NO chain launched (a red head is never green)" \
   $([ "$RC" = 2 ] && [ ! -f "$OT/logs/lane-merge-24.log" ] && echo 0 || echo 1)

# ── 11c. a reviewer ISSUES outcome is FIX_REQUIRED, not a terminal BLOCK ───────────────────────
# ⛔ THE FIXTURE IS THE ARTIFACT THE WRITER ACTUALLY PRODUCES. merge-one.sh writes its verdict to
# `$O/logs/merge-<PR>.log` (`ISSUES <n>`, `NOT CLEAN or reviewer failed`, `MERGED via the rail`,
# `PARKED`) and the head-keyed marker `state/needsfix-<PR>-<head>`; the CHAIN log only carries
# `merge-one rc=…`. A fixture written to the chain log proves nothing about the real loop.
new_o "$T/pr17.tsv"
printf '%s deadbeef %s\n' 999998 "$OT/logs/lane-merge-25.log" > "$OT/state/lanemerge-25.chain"
printf '[merge 25] reviewer verdict: ISSUES 3 at head abc123\n' > "$OT/logs/merge-25.log"
OUT="$(PATH="$BIN:$PATH" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 \
      bash "$SCRIPT" 25 --watch --repo o/r --pr-tsv "$T/pr4.tsv" 2>&1)"; RC=$?
ck "a finished chain whose reviewer said ISSUES → exit 10 FIX_REQUIRED with a round spent (the fix list is the review)" \
   $([ "$RC" = 10 ] && [ "$(verdict_of 25 | cut -d' ' -f1)" = FIX_REQUIRED ] && [ "$(cat "$OT/state/lanemerge-25.round")" = 1 ] && echo 0 || echo 1)

# ── 11c-bis. the DURABLE marker wins even when the log has been rotated away ─────────────────────
new_o "$T/pr21.tsv"
printf '%s deadbeef %s\n' 999998 "$OT/logs/lane-merge-30.log" > "$OT/state/lanemerge-30.chain"
: > "$OT/logs/merge-30.log"
: > "$OT/state/needsfix-30-abc123"
OUT="$(PATH="$BIN:$PATH" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 \
      bash "$SCRIPT" 30 --watch --repo o/r --pr-tsv "$T/pr4.tsv" 2>&1)"; RC=$?
ck "a head-keyed needsfix marker alone → FIX_REQUIRED (the durable marker, not log prose, decides)" \
   $([ "$RC" = 10 ] && [ "$(verdict_of 30 | cut -d' ' -f1)" = FIX_REQUIRED ] && echo 0 || echo 1)

# ── 11c-ter. a "MERGED via the rail" LOG LINE is a HINT, never proof (reviewer P0) ───────────────
# ⛔ `$O/logs/merge-<PR>.log` is keyed by PR NUMBER ONLY and `$O/state` is shared by every repo on the
# box, so a merge of `tortoise#<same n>` used to make this loop print "✅ MERGED — PR #<n>" for an
# UNMERGED PR and record a verdict that makes chain-merge.sh skip BOTH the review and the merge — a
# lane reporting done over a PR nobody merged. Measured, not inferred. The arms below are the pair:
# unconfirmed log → NOT merged (and the handoff NAMES it); confirmed merged_at → MERGED.
new_o "$T/pr22.tsv"
printf '%s deadbeef %s\n' 999998 "$OT/logs/lane-merge-31.log" > "$OT/state/lanemerge-31.chain"
printf '[merge 31] MERGED via the rail (attempt 1)\n' > "$OT/logs/merge-31.log"
OUT="$(PATH="$BIN:$PATH" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 \
      bash "$SCRIPT" 31 --watch --repo o/r --pr-tsv "$T/pr4.tsv" 2>&1)"; RC=$?
ck "an UNCONFIRMED 'MERGED via the rail' line is NOT a merge: exit 14 BLOCKED, and the reason names the API read" \
   $([ "$RC" = 14 ] && [ "$(verdict_of 31 | cut -d' ' -f1)" = BLOCKED ] \
      && grep -q 'reports no merged_at' "$OT/state/lanemerge-31.verdict" && echo 0 || echo 1)
# …and the positive control: the SAME log line WITH a confirmed merged_at IS a merge.
new_o "$T/pr22.tsv"
printf '%s deadbeef %s\n' 999998 "$OT/logs/lane-merge-31.log" > "$OT/state/lanemerge-31.chain"
printf '[merge 31] MERGED via the rail (attempt 1)\n' > "$OT/logs/merge-31.log"
OUT="$(PATH="$BIN:$PATH" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 MERGED_AT_STUB='2026-10-19T00:00:00Z' \
      bash "$SCRIPT" 31 --watch --repo o/r --pr-tsv "$T/pr4.tsv" 2>&1)"; RC=$?
ck "the SAME log line WITH a confirmed merged_at → MERGED exit 0 (the confirmation is what decides)" \
   $([ "$RC" = 0 ] && [ "$(verdict_of 31 | cut -d' ' -f1)" = MERGED ] && echo 0 || echo 1)

# ── 11c-quater. the confirmation READ FAILED → WAITING_API, not BLOCKED (reviewer P2) ───────────
# An unreadable API is not a fact about the PR: exit 11 (re-runnable), no PR comment, no fix round, and
# the supervision chunk is REFUNDED (a chunk that established nothing must not spend budget).
new_o "$T/junk-q.tsv"
printf 'open||newhead1|clean\n' > "$T/pr-open.tsv"
printf '%s deadbeef %s\n' 999996 "$OT/logs/lane-merge-31.log" > "$OT/state/lanemerge-31.chain"
printf '[merge 31] MERGED via the rail (attempt 1)\n' > "$OT/logs/merge-31.log"
printf '3\n' > "$OT/state/lanemerge-31.watch"
printf '3\n' > "$OT/state/lanemerge-31.round"
: > "$T/gh.log"   # this case's own log: an earlier case's BODY-BEGIN must not be counted as "a comment"
OUT="$(PATH="$BIN:$PATH" GH_LOG="$T/gh.log" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 MERGED_API_FAIL=1 \
      bash "$SCRIPT" 31 --watch --repo o/r --pr-tsv "$T/pr-open.tsv" 2>&1)"; RC=$?
ck "a FAILED confirmation read is WAITING_API (exit 11), spends no chunk and no round, and posts no comment" \
   $([ "$RC" = 11 ] && [ "$(verdict_of 31 | cut -d' ' -f1)" = WAITING_API ] \
      && [ "$(cat "$OT/state/lanemerge-31.watch")" = 3 ] && [ "$(cat "$OT/state/lanemerge-31.round")" = 3 ] \
      && ! grep -q BODY-BEGIN "$T/gh.log" 2>/dev/null && echo 0 || echo 1)

# ── 11c-quinquies. the head-moved bound bounds THIS CHAIN, and the second pass is terminal ─────
new_o "$T/junk-q2.tsv"
printf 'open||newhead1|clean\n' > "$T/pr-open2.tsv"
sleep 60 & CH_PID=$!
printf '%s oldhead %s\n' "$CH_PID" "$OT/logs/lane-merge-40.log" > "$OT/state/lanemerge-40.chain"
printf 'nothing here\n' > "$OT/logs/lane-merge-40.log"
OUT="$(PATH="$BIN:$PATH" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 \
      bash "$SCRIPT" 40 --watch --repo o/r --pr-tsv "$T/pr-open2.tsv" 2>&1)"; RC1=$?
OUT2="$(PATH="$BIN:$PATH" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 \
      bash "$SCRIPT" 40 --watch --repo o/r --pr-tsv "$T/pr-open2.tsv" 2>&1)"; RC2=$?
kill "$CH_PID" 2>/dev/null || true
ck "a head-moved chain: pass 1 re-runs (11), pass 2 is TERMINAL (14) and names the pid — not an endless re-arm" \
   $([ "$RC1" = 11 ] && [ "$RC2" = 14 ] && [ "$(verdict_of 40 | cut -d' ' -f1)" = BLOCKED ] \
      && grep -q 'still bound to head oldhead' "$OT/state/lanemerge-40.verdict" && echo 0 || echo 1)

# ── 11c-sexies. a LIVE lock is adopted: the record gets the LIVE pid and KEEPS the recorded head ─
new_o "$T/junk-q3.tsv"
printf 'open||newhead1|clean\n' > "$T/pr-open3.tsv"
sleep 60 & LIVEPID=$!
printf '999999 oldhead %s\n' "$OT/logs/lane-merge-41.log" > "$OT/state/lanemerge-41.chain"
printf '%s\n' "$LIVEPID" > "$OT/state/mergeclaim-41.lock"
printf '1\n' > "$OT/state/lanemerge-41.headmoved"   # stale counters from an EARLIER cycle
printf '1\n' > "$OT/state/lanemerge-41.apiretry"
# ⛔ THE ADOPTION LIVES ON THE LAUNCH PATH (`launch_chain`), not in --watch — that is where a lane
# decides whether to start a competitor. So drive the shipped entry point that reaches it, with a green
# check fixture so it gets that far.
OUT="$(PATH="$BIN:$PATH" GH_LOG="$T/gh.log" O="$OT" HOME="$T/home" \
      LANE_MERGE_WAIT=0 LANE_MERGE_POLL=0 \
      bash "$SCRIPT" 41 --repo o/r --pr-tsv "$T/pr-open3.tsv" --checks-tsv "$T/checks-green.tsv" 2>&1)"; RC=$?
kill "$LIVEPID" 2>/dev/null || true
ck "…and adopting a live chain RESETS the per-chain counters (a cumulative head-moved counter would block the PR for ever)" \
   $([ ! -f "$OT/state/lanemerge-41.headmoved" ] && [ ! -f "$OT/state/lanemerge-41.apiretry" ] && echo 0 || echo 1)
ck "a live merge lock is adopted: the record carries the LIVE pid and the RECORDED head (not the current one)" \
   $([ "$RC" = 11 ] && [ "$(awk '{print $1}' "$OT/state/lanemerge-41.chain")" = "$LIVEPID" ] \
      && [ "$(awk '{print $2}' "$OT/state/lanemerge-41.chain")" = oldhead ] && echo 0 || echo 1)

# ── 11c-septies. the WAITING_API refund is CAPPED, so the spin has a terminal state ────────────
new_o "$T/junk-q4.tsv"
printf 'open||newhead1|clean\n' > "$T/pr-open4.tsv"
printf '%s deadbeef %s\n' 999994 "$OT/logs/lane-merge-51.log" > "$OT/state/lanemerge-51.chain"
printf '[merge 51] MERGED via the rail (attempt 1)\n' > "$OT/logs/merge-51.log"
printf '%s\n' "15" > "$OT/state/lanemerge-51.watch"          # AT the budget: this pass must be charged
printf '%s\n' "15" > "$OT/state/lanemerge-51.apiretry"       # …and the refunds are exhausted
printf '%s\n' "WAITING_API the read failed" > "$OT/state/lanemerge-51.lastdisp"   # the last chunk
OUT="$(PATH="$BIN:$PATH" GH_LOG="$T/gh.log" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 LANE_MERGE_MAX_WATCH=15 MERGED_API_FAIL=1 \
      bash "$SCRIPT" 51 --watch --repo o/r --pr-tsv "$T/pr-open4.tsv" 2>&1)"; RC=$?
ck "an EXHAUSTED refund allowance CHARGES the chunk, so the budget is reachable (exit 13) — and it says the PR may be merged" \
   $([ "$RC" = 13 ] && [ "$(verdict_of 51 | cut -d' ' -f1)" = BLOCKED_ATTEMPTS ] \
      && grep -q 'may be merged' "$OT/state/lanemerge-51.verdict" && echo 0 || echo 1)

# ── 11c-octies. past the refund allowance the chunk is CHARGED (the cap has teeth) ─────────────
# ⛔ THE PREVIOUS CASE COULD NOT SEE THIS: it seeded watch AT the budget, so the budget check fired
# before the refund branch was ever reached and removing the cap left the suite green (measured by the
# verifier). This fixture stays UNDER the budget (watch=3) with the allowance spent, so the only thing
# that decides w is the cap itself: charged → 4, capped-refund-removed → 3.
new_o "$T/junk-q5.tsv"
printf 'open||newhead1|clean\n' > "$T/pr-open5.tsv"
printf '%s deadbeef %s\n' 999993 "$OT/logs/lane-merge-52.log" > "$OT/state/lanemerge-52.chain"
printf '[merge 52] MERGED via the rail (attempt 1)\n' > "$OT/logs/merge-52.log"
printf '%s\n' "3" > "$OT/state/lanemerge-52.watch"
printf '%s\n' "15" > "$OT/state/lanemerge-52.apiretry"
OUT="$(PATH="$BIN:$PATH" GH_LOG="$T/gh.log" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 MERGED_API_FAIL=1 \
      bash "$SCRIPT" 52 --watch --repo o/r --pr-tsv "$T/pr-open5.tsv" 2>&1)"; RC=$?
ck "past the refund allowance the chunk is CHARGED (watch 3 → 4, not refunded) and the run says so" \
   $([ "$RC" = 11 ] && [ "$(verdict_of 52 | cut -d' ' -f1)" = WAITING_API ] \
      && [ "$(cat "$OT/state/lanemerge-52.watch")" = 4 ] \
      && grep -q 'STILL cannot be read' <<<"$OUT" && echo 0 || echo 1)

# ── 11c-nonies. the exhausted-budget hand-off names what the LAST chunk actually found ─────────
# ⛔ THE PREVIOUSLY-SHIPPED BEHAVIOUR WAS A MEASURED FALSEHOOD (verifier finding, P2): the disposition
# was written only on WAITING_API, so after ONE unreadable read followed by fifteen `WAITING_LOAD`
# chunks the hand-off still said "the LAST chunk could not READ the merge confirmation: the PR may well
# be merged" — about fifteen chunks that had read the PR fine and been refused by the load gate, with
# the real cause never named. Every wait exit now overwrites the disposition, and the hand-off branches
# on it. This case drives the sequence: WAITING_API chunk, then LOAD chunks, then the budget.
new_o "$T/junk-q6.tsv"
printf 'open||newhead1|clean\n' > "$T/pr-open6.tsv"
printf '%s deadbeef %s\n' 999994 "$OT/logs/lane-merge-53.log" > "$OT/state/lanemerge-53.chain"
: > "$OT/logs/merge-53.log"
printf 'reviewer NOT started (load gate)\n' > "$OT/logs/lane-merge-53.log"
printf '%s\n' "1" > "$OT/state/lanemerge-53.watch"
printf '%s\n' "WAITING_API the read failed" > "$OT/state/lanemerge-53.lastdisp"
PATH="$BIN:$PATH" GH_LOG="$T/gh.log" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 MERGED_API_FAIL=1 \
  bash "$SCRIPT" 53 --watch --repo o/r --pr-tsv "$T/pr-open6.tsv" >/dev/null 2>&1
ck "a LOAD chunk OVERWRITES an older WAITING_API disposition (the hand-off may only describe the last chunk)" \
   $([ "$(cat "$OT/state/lanemerge-53.lastdisp" 2>/dev/null)" = "WAITING_LOAD" ] && echo 0 || echo 1)
printf '%s\n' "15" > "$OT/state/lanemerge-53.watch"
# ⛔ A CASE-LOCAL gh LOG: `$T/gh.log` ACCUMULATES every earlier case's comments, so a negative
# assertion on it ("must not say the read failed") is polluted by a PREVIOUS case's legitimate
# unreadable-read hand-off — measured here as a false FAIL.
OMIT_LOG="$T/gh-nonies.log"; : > "$OMIT_LOG"
OUT="$(PATH="$BIN:$PATH" GH_LOG="$OMIT_LOG" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 MERGED_API_FAIL=1 \
      bash "$SCRIPT" 53 --watch --repo o/r --pr-tsv "$T/pr-open6.tsv" 2>&1)"; RC=$?
# the BODY goes to gh, not to stdout — assert on the recorded comment, not on the run's output
ck "…and the budget hand-off names the LOAD gate instead of claiming the merge read failed" \
   $([ "$RC" = 13 ] && ! grep -q 'could not READ the merge confirmation' "$OMIT_LOG" \
      && grep -q 'LOAD GATE' "$OMIT_LOG" && echo 0 || echo 1)

# ── 11c-decies. a reviewer that produced NO verdict is NOT a fix round ──────────────────────────
# ⛔ MEASURED DEFECT (reviewer finding, P2): the chain log's `NOT CLEAN or reviewer failed` was read as
# "the reviewer recorded ISSUES", so a reviewer that hit its cap, or whose tool failed, was handed to the
# lane as "read the review comment on PR #N and fix every finding": a fix round spent, and a pointer to
# a comment that does not exist. That class is 43 of 124 runs in this file's own header.
new_o "$T/junk-q7.tsv"
printf 'open||newhead1|clean\n' > "$T/pr-open7.tsv"
printf '%s deadbeef %s\n' 999995 "$OT/logs/lm-54.log" > "$OT/state/lanemerge-54.chain"
printf '[chain] reviewer NOT CLEAN or reviewer failed (no ISSUES count)\n' > "$OT/logs/merge-54.log"
NOVERDICT_LOG="$T/gh-decies.log"; : > "$NOVERDICT_LOG"
OUT="$(PATH="$BIN:$PATH" GH_LOG="$NOVERDICT_LOG" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 \
      bash "$SCRIPT" 54 --watch --repo o/r --pr-tsv "$T/pr-open7.tsv" 2>&1)"; RC=$?
ck "a reviewer with NO verdict → exit 11 WAITING_NO_VERDICT, NO fix round spent, and nothing sends the lane to a review that does not exist" \
   $([ "$RC" = 11 ] && [ "$(cut -d' ' -f1 "$OT/state/lanemerge-54.verdict" 2>/dev/null)" = WAITING_NO_VERDICT ] \
      && [ ! -s "$OT/state/lanemerge-54.round" ] && ! grep -q 'read the review comment' "$NOVERDICT_LOG" \
      && grep -qi 'no verdict' <<<"$OUT" && echo 0 || echo 1)


# ── 11c-decies-bis. …AND THE PRODUCTION SHAPE, where the head-keyed marker exists too ──────────
# ⛔ THE CASE ABOVE COULD NOT SEE THE REAL DEFECT (reviewer finding, P1, measured): merge-one.sh writes
# `needsfix-<PR>-<head>` for a real `ISSUES n` AND for "reviewer failed", and the classifier tested the
# marker BEFORE the log — so a cap-hit reviewer still came back as a fix list with a pointer to a comment
# that was never posted. The marker must be present for this case to mean anything.
new_o "$T/junk-q10.tsv"
printf 'open||newhead1|clean\n' > "$T/pr-open10.tsv"
printf '%s deadbeef %s\n' 999996 "$OT/logs/lm-57.log" > "$OT/state/lanemerge-57.chain"
printf '[chain] reviewer NOT CLEAN or reviewer failed (no ISSUES count)\n' > "$OT/logs/merge-57.log"
: > "$OT/state/needsfix-57-newhead1"          # ← the marker merge-one writes in BOTH outcomes
MARKED_LOG="$T/gh-decies-bis.log"; : > "$MARKED_LOG"
OUT="$(PATH="$BIN:$PATH" GH_LOG="$MARKED_LOG" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 \
      bash "$SCRIPT" 57 --watch --repo o/r --pr-tsv "$T/pr-open10.tsv" 2>&1)"; RC=$?
ck "the PRODUCTION shape (marker + 'reviewer failed', no ISSUES count) → WAITING_NO_VERDICT, no fix round, no phantom review pointer" \
   $([ "$RC" = 11 ] && [ "$(cut -d' ' -f1 "$OT/state/lanemerge-57.verdict" 2>/dev/null)" = WAITING_NO_VERDICT ] \
      && [ ! -s "$OT/state/lanemerge-57.round" ] && ! grep -q 'read the review comment' "$MARKED_LOG" && echo 0 || echo 1)
# …and the DURABLE marker still wins when the log was rotated away (no reviewer outcome in it at all)
new_o "$T/junk-q11.tsv"
printf 'open||newhead1|clean\n' > "$T/pr-open11.tsv"
printf '%s deadbeef %s\n' 999997 "$OT/logs/lm-58.log" > "$OT/state/lanemerge-58.chain"
: > "$OT/logs/merge-58.log"
: > "$OT/state/needsfix-58-newhead1"
OUT="$(PATH="$BIN:$PATH" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 \
      bash "$SCRIPT" 58 --watch --repo o/r --pr-tsv "$T/pr-open11.tsv" 2>&1)"; RC=$?
ck "a ROTATED log (no reviewer outcome at all) still trusts the durable marker → FIX_REQUIRED" \
   $([ "$RC" = 10 ] && [ "$(cut -d' ' -f1 "$OT/state/lanemerge-58.verdict" 2>/dev/null)" = FIX_REQUIRED ] && echo 0 || echo 1)

# ── 11c-quaterdecies. …and --watch with NOTHING to supervise says so instead of handing off ────
# ⛔ MEASURED (reviewer finding, P2): a fresh $O has no chain record and no claim lock, and this chunk
# posted "no signed review record exists … and the chain did not merge" with rc=12 — a hand-off about a
# chain that was never launched, reachable because WAITING shares exit 11 with WAITING_CHECKS.
new_o "$T/junk-q12.tsv"
printf 'open||newhead1|clean\n' > "$T/pr-open12.tsv"
ABSENT_LOG="$T/gh-absent.log"; : > "$ABSENT_LOG"
OUT="$(PATH="$BIN:$PATH" GH_LOG="$ABSENT_LOG" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 \
      bash "$SCRIPT" 59 --watch --repo o/r --pr-tsv "$T/pr-open12.tsv" 2>&1)"; RC=$?
ck "no chain record and no claim lock → WAITING_CHAIN_ABSENT (exit 11), NO comment on the PR, and it says how to launch" \
   $([ "$RC" = 11 ] && [ "$(cut -d' ' -f1 "$OT/state/lanemerge-59.verdict" 2>/dev/null)" = WAITING_CHAIN_ABSENT ] \
      && [ "$(cat "$OT/state/lanemerge-59.lastdisp" 2>/dev/null)" = "WAITING_CHAIN_ABSENT" ] \
      && ! grep -q BODY-BEGIN "$ABSENT_LOG" && echo 0 || echo 1)

# ── 11c-undecies. a chain still running at the deadline stamps ITS disposition too ─────────────
new_o "$T/junk-q8.tsv"
printf 'open||newhead1|clean\n' > "$T/pr-open8.tsv"
printf 'allgood\tcompleted\tsuccess\t41\n' > "$T/checks-ok.tsv"
sleep 60 & CH_PID55=$!
printf '%s newhead1 %s\n' "$CH_PID55" "$OT/logs/lm-55.log" > "$OT/state/lanemerge-55.chain"
# ⛔ A LIVE CHAIN IS RECOGNISED BY ITS CLAIM LOCK, NOT ONLY BY THE RECORD (the launcher probes
# mergeclaim-<PR>.lock before it decides to spawn a competitor); without it this case measured the
# LAUNCH path instead of the watch path and proved nothing about the disposition.
printf '%s\n' "$CH_PID55" > "$OT/state/mergeclaim-55.lock"
echo "still working" > "$OT/logs/lm-55.log"
OUT="$(PATH="$BIN:$PATH" GH_LOG="$T/gh.log" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 LANE_MERGE_WAIT=1 \
      bash "$SCRIPT" 55 --watch --repo o/r --pr-tsv "$T/pr-open8.tsv" --checks-tsv "$T/checks-ok.tsv" 2>&1)"; RC=$?
kill "$CH_PID55" 2>/dev/null || true
ck "a live chain at the deadline → WAITING and it STAMPS WAITING_CHAIN_RUNNING (not a stale earlier reason)" \
   $([ "$RC" = 11 ] && [ "$(cat "$OT/state/lanemerge-55.lastdisp" 2>/dev/null)" = "WAITING_CHAIN_RUNNING" ] && echo 0 || echo 1)

# ── 11c-tredecies. the head-moved budget hand-off RENDERS the pid (not the placeholder) ────────
# ⛔ MEASURED (reviewer finding, P2): the arm exists to NAME the chain, and it shipped the literal
# "check pid $(chain_pid)" to the PR — because the substitution had been escaped to survive a review
# gate and nothing asserted the rendered body. Both halves are asserted here.
new_o "$T/junk-q9.tsv"
printf 'open||newhead1|clean\n' > "$T/pr-open9.tsv"
sleep 60 & CH_PID56=$!
printf '%s newhead1 %s\n' "$CH_PID56" "$OT/logs/lm-56.log" > "$OT/state/lanemerge-56.chain"
echo "still working" > "$OT/logs/lm-56.log"
printf '%s\n' "15" > "$OT/state/lanemerge-56.watch"
printf '%s\n' "WAITING_HEAD_MOVED" > "$OT/state/lanemerge-56.lastdisp"
HEADMOVED_LOG="$T/gh-tredecies.log"; : > "$HEADMOVED_LOG"
OUT="$(PATH="$BIN:$PATH" GH_LOG="$HEADMOVED_LOG" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 \
      bash "$SCRIPT" 56 --watch --repo o/r --pr-tsv "$T/pr-open9.tsv" 2>&1)"; RC=$?
kill "$CH_PID56" 2>/dev/null || true
ck "the head-moved budget hand-off names the REAL pid and never ships the literal placeholder" \
   $([ "$RC" = 13 ] && ! grep -qF '$(chain_pid)' "$HEADMOVED_LOG" \
      && grep -qF "pid $CH_PID56" "$HEADMOVED_LOG" && echo 0 || echo 1)

# ── 11c-quindecies. the OTHER two dispositions are pinned too (R7: deleting either left 58/58) ─
# ⛔ "EVERY WAIT EXIT STAMPS WHAT IT FOUND" IS ONLY TRUE WHERE IT IS ASSERTED (reviewer finding, P2,
# measured): deleting the checks-in-flight write or the classifier write left the whole suite green.
new_o "$T/junk-q13.tsv"
printf 'open||abc123|clean\n' > "$T/pr-open13.tsv"
# an UNFINISHED check: status not `completed`, so there is no conclusion to read — that is "in flight"
printf 'lint\trunning\t\t11\n' > "$T/checks-inflight.tsv"
OUT="$(PATH="$BIN:$PATH" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 LANE_MERGE_WAIT=0 \
      bash "$SCRIPT" 60 --repo o/r --pr-tsv "$T/pr-open13.tsv" --checks-tsv "$T/checks-inflight.tsv" 2>&1)"; RC=$?
echo "DBG-C1 rc=$RC disp=[$(cat "$OT/state/lanemerge-60.lastdisp" 2>/dev/null)] out=[$(printf '%s' "$OUT" | tail -2 | tr '\n' '|')]"
ck "checks still in flight at the deadline → it STAMPS WAITING_CHECKS (so the budget hand-off can name it)" \
   $([ "$RC" = 11 ] && [ "$(cat "$OT/state/lanemerge-60.lastdisp" 2>/dev/null)" = "WAITING_CHECKS" ] && echo 0 || echo 1)

# a classifier that cannot run: python3 is not on PATH in this subshell
new_o "$T/junk-q14.tsv"
printf 'open||abc123|clean\n' > "$T/pr-open14.tsv"
printf 'lint\tcompleted\tsuccess\t11\n' > "$T/checks-any.tsv"
# ⛔ A BROKEN python3, not a missing one: macOS ships /usr/bin/python3, so dropping it from PATH proves
# nothing. A stub that FAILS is the honest way to reproduce "the classifier could not run".
NOPY="$T/nopy"; mkdir -p "$NOPY"
printf '#!/bin/sh\nexit 127\n' > "$NOPY/python3"; chmod +x "$NOPY/python3"
OUT="$(PATH="$NOPY:$BIN:/usr/bin:/bin" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 \
      bash "$SCRIPT" 61 --repo o/r --pr-tsv "$T/pr-open14.tsv" --checks-tsv "$T/checks-any.tsv" 2>&1)"; RC=$?
echo "DBG-C2 rc=$RC disp=[$(cat "$OT/state/lanemerge-61.lastdisp" 2>/dev/null)] out=[$(printf '%s' "$OUT" | tail -2 | tr '\n' '|')]"
# the exit code is 2 (usage/env: the tool it needs is not there), which the brief already treats as
# "fix the environment"; the assertion that matters is that the DISPOSITION is recorded rather than a
# verdict about the PR being minted.
ck "a classifier that cannot run → it STAMPS WAITING_CLASSIFIER (an unjudged head is not a verdict)" \
   $([ "$RC" = 2 ] && [ "$(cat "$OT/state/lanemerge-61.lastdisp" 2>/dev/null)" = "WAITING_CLASSIFIER" ] \
      && [ "$(cut -d' ' -f1 "$OT/state/lanemerge-61.verdict" 2>/dev/null)" = WAITING_CLASSIFIER ] && echo 0 || echo 1)

# ── 11c-sedecies. the budget hand-off has an arm per disposition it can actually find ──────────
# ⛔ WITHOUT THIS the `WAITING_NO_VERDICT` arm was dead text: deleting it left ALL 63 green (measured),
# so the hand-off still said "the merge chain has not resolved this PR" about chunks that had resolved
# the question (nothing to fix) — and the same catch-all swallowed CHECKS/CLASSIFIER.
new_o "$T/junk-q15.tsv"
printf 'open||newhead1|clean\n' > "$T/pr-open15.tsv"
printf '%s deadbeef %s\n' 999999 "$OT/logs/lm-62.log" > "$OT/state/lanemerge-62.chain"
: > "$OT/logs/merge-62.log"
printf '%s\n' "15" > "$OT/state/lanemerge-62.watch"
printf '%s\n' "WAITING_NO_VERDICT" > "$OT/state/lanemerge-62.lastdisp"
ARM_LOG="$T/gh-sedecies.log"; : > "$ARM_LOG"
OUT="$(PATH="$BIN:$PATH" GH_LOG="$ARM_LOG" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 \
      bash "$SCRIPT" 62 --watch --repo o/r --pr-tsv "$T/pr-open15.tsv" 2>&1)"; RC=$?
ck "an exhausted budget whose last chunk found NO verdict says 'nothing to fix', not 'unresolved'" \
   $([ "$RC" = 13 ] && grep -q 'NO reviewer verdict' "$ARM_LOG" && ! grep -q 'has not resolved' "$ARM_LOG" && echo 0 || echo 1)

# ── 11d. the handoff marker is HEAD-BOUND even from --watch ────────────────────────────────────
new_o "$T/pr18.tsv"
printf '%s deadbeef %s\n' 999997 "$OT/logs/lane-merge-26.log" > "$OT/state/lanemerge-26.chain"
printf 'nothing useful here\n' > "$OT/logs/lane-merge-26.log"
OUT="$(PATH="$BIN:$PATH" GH_LOG="$T/gh.log" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 \
      bash "$SCRIPT" 26 --watch --repo o/r --pr-tsv "$T/pr4.tsv" 2>&1)"; RC=$?
# The stub gh answers the dedup read with "no comments", so the handoff body is written and posted;
# assert the marker/heading carry the REAL head, not "unknown" (a constant marker suppresses every
# later handoff at a new head).
ck "a head-bound handoff with NO signed review → exit 12 BLOCKED_ATTESTATION, and the body names the REAL head" \
   $([ "$RC" = 12 ] && [ "$(verdict_of 26 | cut -d' ' -f1)" = BLOCKED_ATTESTATION ] \
      && grep -q 'lane-merge-handoff: abc123' "$T/gh.log" && grep -q 'at head `abc123`' "$T/gh.log" \
      && ! grep -q 'handoff: unknown' "$T/gh.log" && echo 0 || echo 1)
# A REAL 40-char head: the record store keys on full commit shas, and a 6-char fixture would make
# the match test vacuous (it would "pass" by never matching anything).
HSHA=0123456789abcdef0123456789abcdef01234567
printf 'open||%s|clean\n' "$HSHA" > "$T/pr40.tsv"
mkdir -p "$T/home/.pi/agent/reviews"
printf '{"head_sha":"%s"}\n' "$HSHA" > "$T/home/.pi/agent/reviews/o-r-32.json"
new_o "$T/pr40.tsv"
printf '%s deadbeef %s\n' 999996 "$OT/logs/lane-merge-32.log" > "$OT/state/lanemerge-32.chain"
printf 'nothing useful\n' > "$OT/logs/lane-merge-32.log"
OUT="$(PATH="$BIN:$PATH" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 bash "$SCRIPT" 32 --watch --repo o/r --pr-tsv "$T/pr40.tsv" 2>&1)"; RC=$?
ck "…and a signed review record AT the head changes the outcome to the generic BLOCK (14), not the attestation block (12)" \
   $([ "$RC" = 14 ] && [ "$(verdict_of 32 | cut -d' ' -f1)" = BLOCKED ] && echo 0 || echo 1)

# ── 12. THE PROPERTY THAT MATTERS MOST: no self-attestation, no hand-rolled merge ───────────────
# No EXECUTABLE line may invoke the recorder: an attestation is minted only by merge-one.sh from a
# verified fresh-context reviewer comment. (Comment lines are excluded — the file explains the rule.)
_attest_calls="$(grep -nE '^[[:space:]]*[^#[:space:]].*record-review' "$SCRIPT" 2>/dev/null | wc -l | tr -d ' ')"
ck "lane-merge.sh has ZERO executable calls to record-review.sh (a lane cannot attest its own review)" \
   $([ "${_attest_calls:-0}" = 0 ] && echo 0 || echo 1)
ck "lane-merge.sh never runs 'gh pr merge' or 'admin-merge.sh' itself — it drives merge-one.sh" \
   $(if grep -qE '^[[:space:]]*[^#]*gh pr merge' "$SCRIPT"; then echo 1
     elif grep -qE '^[[:space:]]*[^#]*admin-merge\.sh [0-9]' "$SCRIPT"; then echo 1
     else echo 0; fi)
# The one merge entry point it does use must be merge-one.sh, and it must be DETACHED (a lane that
# blocks on a 20-minute review call reads as wedged to every liveness instrument we have).
ck "the chain is launched nohup/detached (a blocking reviewer call would look like a wedge)" \
   $(grep -q 'nohup bash -c' "$SCRIPT" && echo 0 || echo 1)
# E6: the outcome must OUTLIVE the lane. The detached chain is launched precisely so it survives the
# lane's wall clock, so the wrapper — not a live supervisor — has to record a merge it finishes alone.
ck "the detached launch records its own MERGED from state/merged-<PR>.done (no supervisor needed)" \
   $(grep -q 'state/merged-\$4.done' "$SCRIPT" && grep -q 'LM_VERDICT' "$SCRIPT" && echo 0 || echo 1)

# ── 12b. a PARTIAL read (state present, head empty) is refused — an empty head is a default-branch read
# Measured live: a rate-limited read returned `open|||behind`, and the loop then polled
# `commits//check-runs`, which GitHub resolves against the DEFAULT BRANCH — so the verdict would have
# been about main, not this PR, and the next step it gates is launching the merge chain. That is a
# FALSE PASS, not a cosmetic gap.
new_o "$T/pr24.tsv"
printf 'open|||clean\n' > "$T/pr24.tsv"
printf 'allgood\tcompleted\tsuccess\t41\tgithub-actions\n' > "$T/checks-headless.tsv"
run 37 --repo o/r --pr-tsv "$T/pr24.tsv" --checks-tsv "$T/checks-headless.tsv"
ck "a read with an EMPTY head is refused (exit 2) and never polls commits//check-runs" \
   $([ "$RC" = 2 ] && grep -q "HEAD SHA is EMPTY" <<<"$OUT" && [ ! -f "$OT/logs/lane-merge-37.log" ] && echo 0 || echo 1)

# ── 13. a bad PR id, and an unreadable PR, are refused WITHOUT attempting anything ──────────────
new_o "$T/pr11.tsv"
run '12;rm -rf /' --repo o/r --pr-tsv "$T/pr4.tsv"
ck "a non-numeric PR id is refused (exit 2) — the id reaches an API URL" \
   $([ "$RC" = 2 ] && grep -q "non-numeric" <<<"$OUT" && echo 0 || echo 1)
new_o "$T/pr12.tsv"
run 18 --repo o/r
ck "an unreadable PR (no fixture, stub gh answers empty) → exit 2 and it says nothing was attempted" \
   $([ "$RC" = 2 ] && grep -q "Nothing was attempted" <<<"$OUT" && [ ! -f "$OT/state/lanemerge-18.round" ] && echo 0 || echo 1)

# ── 15. --watch is BOUNDED too (a pid probe cannot prove the chain is still working) ────────────
new_o "$T/pr14.tsv"
printf '20\n' > "$OT/state/lanemerge-22.watch"
: > "$T/gh.log"
OUT="$(PATH="$BIN:$PATH" GH_LOG="$T/gh.log" O="$OT" HOME="$T/home" LANE_MERGE_MAX_WATCH=20 \
      bash "$SCRIPT" 22 --watch --repo o/r --pr-tsv "$T/pr4.tsv" 2>&1)"; RC=$?
ck "watch budget spent → exit 13 BLOCKED_ATTEMPTS + a handoff comment (supervision cannot loop forever)" \
   $([ "$RC" = 13 ] && [ "$(verdict_of 22 | cut -d' ' -f1)" = BLOCKED_ATTEMPTS ] && grep -q "issues/22/comments" "$T/gh.log" && echo 0 || echo 1)

# ── 16. a chain bound to an OLDER head is not supervision of the current one ────────────────────
new_o "$T/pr15.tsv"
sleep 120 & SPID=$!
printf '%s oldsha %s\n' "$SPID" "$OT/logs/lane-merge-23.log" > "$OT/state/lanemerge-23.chain"
OUT="$(PATH="$BIN:$PATH" O="$OT" HOME="$T/home" LANE_MERGE_POLL=0 \
      bash "$SCRIPT" 23 --watch --repo o/r --pr-tsv "$T/pr4.tsv" 2>&1)"; RC=$?
disown "$SPID" 2>/dev/null; kill "$SPID" 2>/dev/null; wait "$SPID" 2>/dev/null
ck "a live chain working an OLDER head → exit 11 WAITING_HEAD_MOVED (its verdict cannot be applied to the tip)" \
   $([ "$RC" = 11 ] && [ "$(verdict_of 23 | cut -d' ' -f1)" = WAITING_HEAD_MOVED ] && echo 0 || echo 1)
# ⛔ AND IT MUST STAMP WHAT IT FOUND (reviewer finding): deleting `disposition WAITING_HEAD_MOVED` left
# the whole suite green, so the arm the exhausted-budget hand-off branches on was unpinned.
ck "…and the head-moved exit STAMPS its disposition (the budget hand-off has something true to say)" \
   $([ "$(cat "$OT/state/lanemerge-23.lastdisp" 2>/dev/null)" = "WAITING_HEAD_MOVED" ] && echo 0 || echo 1)

# ── 13b. a STALE merge lock must be cleared, not obeyed (it is a pid file, not an owner) ───────
new_o "$T/pr20.tsv"
printf '999999\n' > "$OT/state/mergeclaim-29.lock"
run 29 --repo o/r --pr-tsv "$T/pr4.tsv" --checks-tsv "$T/checks-green.tsv"
sleep 1
ck "a stale lock (dead pid) is cleared and the chain IS launched (a lock's existence is not a holder)" \
   $([ "$RC" = 11 ] && grep -q "STALE merge lock" <<<"$OUT" && grep -q "MERGED via the rail" "$OT/logs/lane-merge-29.log" 2>/dev/null && echo 0 || echo 1)

# ── 14. an absurd/impossible cap is coerced, not obeyed (it feeds arithmetic) ───────────────────
new_o "$T/pr13.tsv"
OUT="$(PATH="$BIN:$PATH" O="$OT" HOME="$T/home" LANE_MERGE_MAX_ROUNDS=9223372036854775807 \
      bash "$SCRIPT" 19 --status 2>&1)"; RC=$?
ck "an out-of-range LANE_MERGE_MAX_ROUNDS falls back to 3 and says so" \
   $([ "$RC" = 0 ] && grep -q "using 3" <<<"$OUT" && grep -q "/3" <<<"$OUT" && echo 0 || echo 1)

# ── 17. the POLL must be eligible for the conditional (ETag/304) layer (E3) ────────────────────
# `gh-limit.py` leaves every argv containing --paginate COMPLETELY alone, so a paginated poll is never
# made conditional and costs primary quota on every tick — 45 polls per invocation across 22 landers,
# on the one account that has already refused GraphQL. Asserted on the WIRE (the recorded argv), not
# on the source text, because the source is what a reader would believe.
new_o "$T/pr21.tsv"
printf 'open||head123|clean\n' > "$T/pr21.tsv"
printf 'TOTAL\t1\nlonely\tcompleted\tsuccess\t51\tgithub-actions\n' > "$T/checks-total.tsv"
: > "$T/gh.log"
OUT="$(PATH="$BIN:$PATH" GH_LOG="$T/gh.log" CHECKS_STUB="$T/checks-total.tsv" O="$OT" HOME="$T/home" \
      LANE_MERGE_WAIT=0 LANE_MERGE_INTERVAL=0 bash "$SCRIPT" 30 --repo o/r --pr-tsv "$T/pr21.tsv" 2>&1)"; RC=$?
ck "the check-run poll sends NO --paginate (so a repeat can answer 304 and cost nothing)" \
   $(grep -q "check-runs" "$T/gh.log" && ! grep -q "paginate" "$T/gh.log" && echo 0 || echo 1)
ck "a TOTAL-only response is NOT a green head (0 check-runs = nothing measured, not success)" \
   $(printf 'TOTAL\t0\n' > "$T/checks-empty.tsv"; \
     printf 'open||head123|clean\n' > "$T/pr31.tsv"; new_o "$T/pr31.tsv" >/dev/null; \
     PATH="$BIN:$PATH" GH_LOG=/dev/null CHECKS_STUB="$T/checks-empty.tsv" O="$OT" HOME="$T/home" \
       LANE_MERGE_WAIT=0 LANE_MERGE_INTERVAL=0 bash "$SCRIPT" 31 --repo o/r --pr-tsv "$T/pr31.tsv" >/dev/null 2>&1; RC2=$?; \
     [ "$RC2" = 11 ] && [ "$(verdict_of 31 | cut -d' ' -f1)" = WAITING_CHECKS ] && echo 0 || echo 1)

# ── 18. the SUPERVISION BUDGET is sized to one documented cycle AND re-armed (E1) ───────────────
ck "the watch budget (15 x 120s) plus the check wait (WAIT_S) fits INSIDE lane.sh's 3300s wall clock" \
   $(grep -q 'LANE_MERGE_MAX_WATCH:-15}' "$SCRIPT" && ! grep -q 'LANE_MERGE_MAX_WATCH:-35}' "$SCRIPT" && ! grep -q 'LANE_MERGE_MAX_WATCH:-25}' "$SCRIPT" && echo 0 || echo 1)
# ⛔ THE ARITHMETIC, not the literal: the shipped default x the shipped chunk length must be strictly
# less than LANE_TIMEOUT in lane.sh, or the bound is unreachable by the lane that owns it and is only
# ever spent by a LATER lane (the "budget spent" handoff for a budget it never had).
_mw="$(sed -n 's/.*LANE_MERGE_MAX_WATCH:-\([0-9]*\)}.*/\1/p' "$SCRIPT" | head -1)"
_ps="$(sed -n 's/.*LANE_MERGE_POLL:-\([0-9]*\)}.*/\1/p' "$SCRIPT" | head -1)"
# lane.sh invokes it as `run_agent "${LANE_TIMEOUT:-3300}" …`, so read the default out of THAT call.
_lt="$(grep -o 'LANE_TIMEOUT:-[0-9]*' "$HERE/lane.sh" | head -1 | tr -dc '0-9')"
# ⛔ THE INVARIANT IS `WAIT_S + MAX_WATCH x POLL <= LANE_TIMEOUT`, not `MAX_WATCH x POLL <
# LANE_TIMEOUT`: the check wait spends WAIT_S of the SAME wall clock, so a budget that ignores it leaves
# most of the chunks unreachable and the rest is inherited by a LATER lane — the "budget spent for a
# budget it never had" symptom, narrowed rather than closed (reviewer finding, verified).
_ws="$(sed -n 's/.*LANE_MERGE_WAIT:-"\([0-9]*\)".*/\1/p' "$SCRIPT" | head -1)"
[ -n "$_ws" ] || _ws="$(grep -o 'LANE_MERGE_WAIT:-[0-9]*' "$SCRIPT" | head -1 | tr -dc '0-9')"
ck "WAIT_S ($_ws) + MAX_WATCH x POLL ($_mw x $_ps) = $(( ${_ws:-0} + ${_mw:-0} * ${_ps:-0} )) ≤ lane.sh LANE_TIMEOUT ($_lt) — by ARITHMETIC across the two files" \
   $([ -n "$_mw" ] && [ -n "$_ps" ] && [ -n "$_lt" ] && [ -n "$_ws" ] && [ $((_ws + _mw * _ps)) -le "$_lt" ] && echo 0 || echo 1)
new_o "$T/pr4.tsv"
printf '20\n' > "$OT/state/lanemerge-32.watch"
printf '15\n' > "$OT/state/lanemerge-32.apiretry"
printf '%s\n' "WAITING_API the read failed" > "$OT/state/lanemerge-32.lastdisp"
printf '1\n' > "$OT/state/lanemerge-32.headmoved"
run 32 --repo o/r --pr-tsv "$T/pr4.tsv" --checks-tsv "$T/checks-red.tsv"
ck "a NEW fix round RE-ARMS the supervision budget (a spent counter must not refuse the next cycle)" \
   $([ "$RC" = 10 ] && [ ! -s "$OT/state/lanemerge-32.watch" ] && echo 0 || echo 1)
# ⛔ AND IT RE-ARMS THE PER-CHAIN COUNTERS TOO (verifier finding): a surviving `lastdisp` let a later
# chunk post "the LAST chunk could not READ the merge confirmation" about a chunk that read it fine.
ck "a NEW fix round also clears apiretry / headmoved / lastdisp (a stale disposition must not drive the hand-off)" \
   $([ ! -f "$OT/state/lanemerge-32.apiretry" ] && [ ! -f "$OT/state/lanemerge-32.headmoved" ] \
      && [ ! -f "$OT/state/lanemerge-32.lastdisp" ] && echo 0 || echo 1)

# ── 19. an EMPTY PR read must not blank the head or read as merged (E7) ────────────────────────
new_o "$T/pr25.tsv"
sleep 120 & SPID2=$!
printf '%s %s %s\n' "$SPID2" "head123" "$OT/logs/lane-merge-33.log" > "$OT/state/lanemerge-33.chain"
OUT="$(PATH="$BIN:$PATH" GH_LOG=/dev/null O="$OT" HOME="$T/home" \
      LANE_MERGE_MAX_WATCH=2 LANE_MERGE_POLL=1 bash "$SCRIPT" 33 --watch --repo o/r 2>&1)"; RC=$?
disown "$SPID2" 2>/dev/null; kill "$SPID2" 2>/dev/null; wait "$SPID2" 2>/dev/null
# The chunk deadline exits 11 WITHOUT a verdict on purpose (nothing was concluded), so the assertion
# is "it did not conclude MERGED and it stayed in supervision", not a verdict token.
ck "an UNREADABLE PR is not 'closed and merged' (unreadable ≠ MERGED; it stays supervising)" \
   $([ "$RC" = 11 ] && [ "$(verdict_of 33 | cut -d' ' -f1)" != MERGED ] && echo 0 || echo 1)
# A chunk reads the PR once, so the guard's job is to keep that true for any future re-read rather
# than to fix a present double-read — asserted structurally, and labelled as such.
ck "the read is applied only on a NON-EMPTY read (so a failed read cannot blank the head)" \
   $(grep -q 'if \[ -n "${read_up:-}" \]; then' "$SCRIPT" && echo 0 || echo 1)

# ── 20. the DETACHED wrapper records MERGED from the chaid's own marker — and ONLY on confirmation ──
# F5: without this the wrapper's MERGED branch is dead code as far as the suite is concerned, and the
# whole point of the delta (a lane killed at its wall clock still leaves its merge visible) is
# unprotected. Two runs: one where the API confirms the merge, one where only a stale-numbered marker
# exists (the other-repo collision F3 names).
wait_for_file() { # wait_for_file <path> <seconds>
  local i=0; while [ "$i" -lt "$(( $2 * 10 ))" ]; do [ -s "$1" ] && return 0; sleep 0.1; i=$((i+1)); done; return 1
}
new_o "$T/pr41.tsv"
printf 'open||head123|clean\n' > "$T/pr41.tsv"
printf 'allgood\tcompleted\tsuccess\t41\tgithub-actions\n' > "$T/checks-ok.tsv"
MK_MERGED=1 MERGED_AT_STUB="2026-10-18T00:00:00Z" \
  PATH="$BIN:$PATH" O="$OT" HOME="$T/home" LANE_MERGE_WAIT=0 LANE_MERGE_INTERVAL=0 \
  bash "$SCRIPT" 41 --issue 941 --repo o/r --pr-tsv "$T/pr41.tsv" --checks-tsv "$T/checks-ok.tsv" >/dev/null 2>&1
wait_for_file "$OT/state/lanemerge-41.verdict" 8
ck "a CONFIRMED merge is recorded by the DETACHED wrapper, PR- and issue-keyed (the lane may be gone)" \
   $([ "$(verdict_of 41 | cut -d' ' -f1)" = MERGED ] && [ "$(cut -d' ' -f1 "$OT/state/lanemerge-issue-941.verdict" 2>/dev/null)" = MERGED ] && echo 0 || echo 1)
new_o "$T/pr42.tsv"
printf 'open||head123|clean\n' > "$T/pr42.tsv"
MK_MERGED=1 MERGED_AT_STUB="" \
  PATH="$BIN:$PATH" O="$OT" HOME="$T/home" LANE_MERGE_WAIT=0 LANE_MERGE_INTERVAL=0 \
  bash "$SCRIPT" 42 --issue 942 --repo o/r --pr-tsv "$T/pr42.tsv" --checks-tsv "$T/checks-ok.tsv" >/dev/null 2>&1
sleep 2
ck "a marker with NO merged_at is NOT recorded as MERGED (another repo's PR of the same number)" \
   $([ "$(verdict_of 42 | cut -d' ' -f1)" != MERGED ] && echo 0 || echo 1)

# ── 21. a later chunk that cannot read the PR still posts a HEAD-BOUND marker (F4) ──────────────
# Chunk 1 reads the head and persists it; chunk 2's read fails and the budget is already spent, so the
# handoff happens with NO current read. Without the persisted head the marker degenerates to
# `unknown` and every later handoff at a new head is suppressed as a duplicate.
new_o "$T/pr43.tsv"
sleep 120 & SPID3=$!
printf '%s head123 %s\n' "$SPID3" "$OT/logs/lane-merge-43.log" > "$OT/state/lanemerge-43.chain"
printf 'open||head123|clean\n' > "$T/pq43"
PATH="$BIN:$PATH" GH_LOG=/dev/null PR_QUEUE="$T/pq43" O="$OT" HOME="$T/home" \
  LANE_MERGE_MAX_WATCH=3 LANE_MERGE_POLL=0 bash "$SCRIPT" 43 --watch --repo o/r >/dev/null 2>&1
ck "a good read PERSISTS the head (state/lanemerge-<PR>.head) for a later failing chunk" \
   $([ "$(cat "$OT/state/lanemerge-43.head" 2>/dev/null)" = head123 ] && echo 0 || echo 1)
printf '3\n' > "$OT/state/lanemerge-43.watch"
: > "$T/gh2.log"
PATH="$BIN:$PATH" GH_LOG="$T/gh2.log" O="$OT" HOME="$T/home" LANE_MERGE_MAX_WATCH=3 \
  bash "$SCRIPT" 43 --watch --repo o/r --issue 943 >/dev/null 2>&1
disown "$SPID3" 2>/dev/null; kill "$SPID3" 2>/dev/null; wait "$SPID3" 2>/dev/null
marker2="$(sed -n 's/.*lane-merge-handoff: \([^ ]*\) -->.*/\1/p' "$T/gh2.log" 2>/dev/null | tail -1)"
ck "…and the handoff marker still names that head, not 'unknown' (per-head dedup survives)" \
   $([ "$marker2" = head123 ] && echo 0 || echo 1)

echo
if [ "$fail" -eq 0 ]; then
  printf '\033[32mALL %d lane-merge checks passed\033[0m\n' "$pass"
else
  printf '\033[31m%d passed, %d FAILED\033[0m\n' "$pass" "$fail"
fi
[ "$fail" -eq 0 ]

